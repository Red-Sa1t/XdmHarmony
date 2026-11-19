/*
 * U1.2 探针单元：P1-U2 下载链路探针（设计书 §6 步骤表）。
 * S1 源 206 预检（自建请求，不走引擎）｜ S2 业务 HttpClient 重定向/headersReceive 3xx 观测
 * S3 新建+启动（206 探测）｜ S4 进度滚动（事件+落库+@Observed 同步）｜ S5 暂停（偏移与 temp 一致）
 * S6 恢复（206 三检链路）｜ S7 完成+字节抽查+落库 ｜ S8 列表快照 ｜ S9 重启核对（手动 runSingle）
 * 探针驱动模型（§0-8）：只调业务公开 API（HttpClient/Downloader/DownloadStore）；引擎零 [XDM_PROBE]
 * 输出——HTTP status/206/Content-Range 等引擎内部事实经 Downloader 事件接口由监听器采集进事实袋，
 * 各步骤结束统一从事实袋 emit（事件在步骤中途到达，emit 会破坏"每步骤恰一行"）。
 * 监听器即"事件消费方"（对照 Index 消费链）：onProgress→record 字段+updateProgress 落库、
 * onPaused→status=Stopped+updateStatus、onFinished→markAsFinished——S4/S7 的 db* 键观察消费链。
 * S6 观测路径（引擎事件面不携带 Content-Range）：①探针自证——业务 HttpClient 带 Range: bytes=N-
 * 请求同 URL 解析 Content-Range（start/total）；②引擎 resume 后经 facts.connectedCount>=2 采集
 * 二次 onConnected 状态；引擎三检不通过会走 onFailed 终态（facts.failedFired）——两路证据合并覆盖 206 链路。
 * S4 谓词取 AND（progressCount>=1 且 lastDownloaded>=262144）：设计表写"或"——OR 在快源下 progressTicks=0、
 * 慢源下 5 ticks≈整文件使 S5 暂停窗口消失，AND 才同时满足 EXPECT 锚（progressTicks>=1、dbProgress>0）
 * 与 S5 暂停确定性（~500ms 处暂停，剩余 ~3.6MiB/2.2s），差异记手册 §注。
 * S9 会话门（ProbeStore R3-F1 同款）：自动会话触达 S9 时行缓冲 >1 行 → 跳过；runSingle 单步会话仅 BEGIN 1 行 → 执行。
 * 会话代际守卫：每个 runner 入口捕获 runId，每个 await 恢复后、emit 前过 isCurrent，不一致静默 return。
 * autoStart=false + TextInput：测试源 URL 必须可替换（禁 127.0.0.1，手册可替换参数）。
 * 红线：观测值只写事实不写 PASS/FAIL（headersAtRedirect/pauseLanded/startMatches 均为观测事实，
 * 判定在 EXPECT/verify）。
 */

import { http } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ProbeKit, KeyValue } from '../core/ProbeKit';
import { ProbePage, ProbeStepDef } from '../core/ProbePage';
import { HttpClient, HttpResponseHead } from '../../core/net/HttpClient';
import { sixDefaultHeaders, resumeRangeHeader, parseContentRange, headerValueOf,
  ContentRangeParts } from '../../core/net/HttpProtocol';
import { Downloader, DownloadEvents, ForwardDownloadEvents } from '../../core/engine/Downloader';
import { PieceSnapshot } from '../../core/engine/PieceAlgo';
import { DownloadRecord, newDownloadRecord } from '../../model/DownloadRecord';
import { DownloadStatus } from '../../model/DownloadTypes';
import { DownloadStore, DownloadLists } from '../../core/db/DownloadStore';
import { Config } from '../../core/Config';
import { joinTempDir } from '../../core/db/RecordMapping';
import { DOWNLOAD_BYTES, SPOT_OFFSET_COUNT, expectedByteAt, spotOffsetAt } from './ProbeDownloadLogic';

/** 非标记诊断行 tag：不含 "XDM_PROBE" 子串（同 ProbePage 惯例） */
const DIAG_TAG: string = 'XdmProbeDownload';

/** 测试源缺省地址（手册"可替换参数"占位值；真机/模拟器填主机局域网 IP，禁 127.0.0.1） */
const DEFAULT_BASE_URL: string = 'http://127.0.0.1:8081';

/** S9 持久核对 pending JSON（落 <filesDir>/，S7 写 S9 读；重跑 S3~S7 覆盖为最新行） */
const PERSIST_FILE_NAME: string = 'probe-P1-U2-persist.json';

/** S4/S5 进度等待阈值：4 块 = 262144B（慢源 ~160ms 达到，配合首个 500ms 进度事件） */
const PAUSE_THRESHOLD_BYTES: number = 262144;

/** S7 字节抽查窗口 */
const SPOT_WINDOW_BYTES: number = 16;

/** 步骤定义表：S1~S8 autoRun（自动会话），S9 手动（runSingle 单步会话） */
const DOWNLOAD_STEPS: ProbeStepDef[] = [
  { stepNo: 'S1', title: '源能力预检（206/Range）', autoRun: true },
  { stepNo: 'S2', title: '重定向观测（headersReceive 3xx）', autoRun: true },
  { stepNo: 'S3', title: '新建+启动（206 探测）', autoRun: true },
  { stepNo: 'S4', title: '进度滚动（事件+落库）', autoRun: true },
  { stepNo: 'S5', title: '暂停（逐片账本与文件前缀）', autoRun: true },
  { stepNo: 'S6', title: '恢复（206 三检链路）', autoRun: true },
  { stepNo: 'S7', title: '完成+字节抽查+落库', autoRun: true },
  { stepNo: 'S8', title: '列表快照', autoRun: true },
  { stepNo: 'S9', title: '重启历史核对（手动）', autoRun: false }
];

/** 引擎事实袋：Downloader 事件回调写入（主线程单写者），各步骤结束统一读取 emit */
class EngineFacts {
  startedFired: boolean = false;
  connectedCount: number = 0;
  firstStatus: number = 0;
  firstTotalSize: number = -1;
  firstResumable: boolean = false;
  resumeStatus: number = 0;
  progressCount: number = 0;
  lastProgress: number = 0;
  lastInstantSpeed: number = 0;
  lastEta: number = 0;
  lastDownloaded: number = 0;
  pausedFired: boolean = false;
  pausedOffset: number = 0;
  finishedFired: boolean = false;
  finalFileSize: number = 0;
  finalFilePath: string = '';
  failedFired: boolean = false;
  failedCode: number = 0;
  failedMessage: string = '';
}

/** S7 落盘/S9 读回的 pending 载荷 */
interface PersistPayload {
  id: string;
  finalPath: string;
  finalSize: number;
}

@Component
export struct ProbeDownload {
  @State baseUrl: string = DEFAULT_BASE_URL;
  private probeKit: ProbeKit = ProbeKit.getInstance();
  private facts: EngineFacts = new EngineFacts();
  private activeRecord: DownloadRecord | undefined = undefined;
  private engine: Downloader | undefined = undefined;
  private pauseOffsetSeen: number = 0;
  /** 最近一次字节抽查的总体匹配结果（runSpotChecks 回填） */
  private lastSpotAllMatch: boolean = false;
  /** 消费方 DB 写追踪（fire-and-forget 链的最后一笔，步骤内读库前 await 保证可见） */
  private lastProgressWrite: Promise<boolean> = Promise.resolve(true);
  private lastStatusWrite: Promise<boolean> = Promise.resolve(true);
  private lastFinishWrite: Promise<boolean> = Promise.resolve(true);

  /** 步骤分派 + S9 会话门（见文件头注释） */
  private async runStep(stepNo: string): Promise<void> {
    if (stepNo === 'S9') {
      if (this.probeKit.getLines().length > 1) {
        // 自动会话按数组序触达手动步骤：跳过（不发标记行）
        return;
      }
    }
    if (stepNo === 'S1') {
      await this.runS1();
      return;
    }
    if (stepNo === 'S2') {
      await this.runS2();
      return;
    }
    if (stepNo === 'S3') {
      await this.runS3();
      return;
    }
    if (stepNo === 'S4') {
      await this.runS4();
      return;
    }
    if (stepNo === 'S5') {
      await this.runS5();
      return;
    }
    if (stepNo === 'S6') {
      await this.runS6();
      return;
    }
    if (stepNo === 'S7') {
      await this.runS7();
      return;
    }
    if (stepNo === 'S8') {
      await this.runS8();
      return;
    }
    if (stepNo === 'S9') {
      await this.runS9();
      return;
    }
  }

  /** S1 源 206 预检：自建 requestInStream（不走引擎/业务栈）——S5/S6 判定的环境前提 */
  private async runS1(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    const url: string = this.joinBase('/big.bin');
    let status: number = 0;
    let chunks: number = 0;
    let contentLength: number = -1;
    const client: http.HttpRequest = http.createHttp();
    try {
      const endGate: Promise<void> = new Promise<void>((resolve: () => void) => {
        client.on('dataEnd', () => {
          resolve();
        });
      });
      client.on('dataReceive', (data: ArrayBuffer) => {
        chunks++;
      });
      client.on('headersReceive', (headerObj: Object) => {
        const rec: Record<string, string> = headerObj as Record<string, string>;
        const cl: string = headerValueOf(rec, 'content-length');
        if (cl.length > 0) {
          contentLength = Number(cl);
        }
      });
      const rangeHeader: Record<string, string> = {};
      rangeHeader['Range'] = 'bytes=0-';
      const options: http.HttpRequestOptions = { header: rangeHeader, connectTimeout: 10000, readTimeout: 10000 };
      status = await client.requestInStream(url, options);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      await Promise.race([endGate, new Promise<void>((resolve: () => void) => setTimeout(resolve, 15000))]);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const kvs: KeyValue[] = [
        new KeyValue('sourceUrl', url),
        new KeyValue('status', String(status)),
        new KeyValue('contentLength', String(contentLength)),
        new KeyValue('rangeSupported', String(status === 206)),
        new KeyValue('chunks', String(chunks))
      ];
      this.probeKit.emit('S1', kvs);
    } catch (e) {
      const err = e as BusinessError;
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const errKvs: KeyValue[] = [
        new KeyValue('sourceUrl', url),
        new KeyValue('status', String(status)),
        new KeyValue('chunks', String(chunks)),
        new KeyValue('errCode', String(err.code)),
        new KeyValue('errMessage', err.message ?? '')
      ];
      this.probeKit.emit('S1', errKvs);
    } finally {
      client.off('dataReceive');
      client.off('dataEnd');
      client.off('headersReceive');
      client.destroy();
    }
  }

  /** S2 重定向观测（决策 9 降级补偿 D1）：业务 HttpClient（六默认头）open /redirect →
   * headsReceived 全量——headersAtRedirect 是 headersReceive 是否在 3xx 跳点触发的直接观测
   * （true→Phase 2 前可恢复 1:1 回写，openQuestion 1 判定输入，不计业务判定）。 */
  private async runS2(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    const url: string = this.joinBase('/redirect');
    const client: HttpClient = new HttpClient();
    try {
      const headers: Record<string, string> = sixDefaultHeaders(url);
      const head: HttpResponseHead = await client.open(url, headers);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      await client.waitStreamEnd();
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const heads: HttpResponseHead[] = client.getHeadsReceived();
      let locationSeen: string = 'absent';
      if (heads.length > 0) {
        const loc: string = headerValueOf(heads[0].header, 'location');
        locationSeen = loc.length > 0 ? loc : 'absent';
      }
      const kvs: KeyValue[] = [
        new KeyValue('requestUrl', url),
        new KeyValue('redirectFollowed', String(head.status === 200)),
        new KeyValue('finalStatus', String(head.status)),
        new KeyValue('headsReceivedCount', String(heads.length)),
        new KeyValue('locationSeen', locationSeen),
        new KeyValue('headersAtRedirect', String(heads.length >= 2))
      ];
      this.probeKit.emit('S2', kvs);
    } catch (e) {
      const err = e as BusinessError;
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const errKvs: KeyValue[] = [
        new KeyValue('requestUrl', url),
        new KeyValue('errCode', String(err.code)),
        new KeyValue('errMessage', err.message ?? '')
      ];
      this.probeKit.emit('S2', errKvs);
    } finally {
      client.abort();
    }
  }

  /** S3 新建+启动：工厂 → 覆盖确定性 id（COLD-F1 链路）→ add → Downloader+监听器 → start →
   * 等 onStarted+首次 onConnected。首请求带 Range: bytes=0- → echo 源回 206 → resumable=true。 */
  private async runS3(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const ctx: common.Context = this.requireContext();
      const store: DownloadStore = DownloadStore.getInstance();
      await store.initialize(ctx);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const id: string = 'probe-u2-' + runId;
      const name: string = 'probe-u2-' + runId + '.bin';
      const url: string = this.joinBase('/slow.bin?ms=40');
      const record: DownloadRecord = newDownloadRecord(name, Config.getInstance().getDownloadDir(), 0,
        'application/octet-stream', url, false, null, null);
      record.id = id;
      const addOk: boolean = await store.add(record);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      this.activeRecord = record;
      this.facts = new EngineFacts();
      this.pauseOffsetSeen = 0;
      this.engine = new Downloader(record, this.buildListener());
      this.engine.start();
      await this.awaitUntil((): boolean => this.facts.startedFired && this.facts.connectedCount >= 1,
        20000, 20);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const tempDirPath: string = joinTempDir(Config.getInstance().getTempDir(), id);
      let tempDirCreated: boolean = false;
      let pieceFileExists: boolean = false;
      try {
        fileIo.accessSync(tempDirPath);
        tempDirCreated = true;
        pieceFileExists = fileIo.listFileSync(tempDirPath).length > 0;
      } catch (e) {
        tempDirCreated = false;
      }
      const kvs: KeyValue[] = [
        new KeyValue('recordId', id),
        new KeyValue('addOk', String(addOk)),
        new KeyValue('started', String(this.facts.startedFired)),
        new KeyValue('firstRequestStatus', String(this.facts.firstStatus)),
        new KeyValue('totalSize', String(this.facts.firstTotalSize)),
        new KeyValue('resumable', String(this.facts.firstResumable)),
        new KeyValue('tempDirCreated', String(tempDirCreated)),
        new KeyValue('pieceFileExists', String(pieceFileExists))
      ];
      this.probeKit.emit('S3', kvs);
    } catch (e) {
      this.emitStepError('S3', runId, e as BusinessError);
    }
  }

  /** S4 进度滚动：等首个进度事件且字节过阈值（AND 谓词，见文件头注）→ 读库/读 @Observed 字段。
   * 引擎已失败（failedFired）则快速失败 emit，不拖满超时。 */
  private async runS4(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const store: DownloadStore = DownloadStore.getInstance();
      const record = this.activeRecord;
      if (record === undefined) {
        this.probeKit.emit('S4', [new KeyValue('errMessage', 'no active record')]);
        return;
      }
      if (this.facts.failedFired) {
        this.emitEngineFailed('S4', runId);
        return;
      }
      await this.awaitUntil((): boolean => this.facts.progressCount >= 1 &&
        this.facts.lastDownloaded >= PAUSE_THRESHOLD_BYTES, 30000, 20);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      await this.lastProgressWrite;
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const row: DownloadRecord | null = await store.getDownloadById(record.id);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const dbProgress: number = row !== null ? row.progress : -1;
      const recordSynced: boolean = record.progress === this.facts.lastProgress;
      const kvs: KeyValue[] = [
        new KeyValue('progressTicks', String(this.facts.progressCount)),
        new KeyValue('lastProgress', String(this.facts.lastProgress)),
        new KeyValue('lastInstantSpeed', String(this.facts.lastInstantSpeed)),
        new KeyValue('lastEta', String(this.facts.lastEta)),
        new KeyValue('lastDownloaded', String(this.facts.lastDownloaded)),
        new KeyValue('dbProgress', String(dbProgress)),
        new KeyValue('recordSynced', String(recordSynced))
      ];
      this.probeKit.emit('S4', kvs);
    } catch (e) {
      this.emitStepError('S4', runId, e as BusinessError);
    }
  }

  /** S5 暂停：阈值达成 → stop() → 等 onPaused+停转 → 暂停偏移与 temp 分片文件大小互证。 */
  private async runS5(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const record = this.activeRecord;
      const engine = this.engine;
      if (record === undefined || engine === undefined) {
        this.probeKit.emit('S5', [new KeyValue('errMessage', 'no active engine')]);
        return;
      }
      if (this.facts.failedFired) {
        this.emitEngineFailed('S5', runId);
        return;
      }
      await this.awaitUntil((): boolean => this.facts.progressCount >= 1 &&
        this.facts.lastDownloaded >= PAUSE_THRESHOLD_BYTES, 30000, 20);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      engine.stop();
      await this.awaitUntil((): boolean => this.facts.pausedFired && !engine.isRunning(), 10000, 20);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const pauseOffset: number = this.facts.pausedOffset;
      this.pauseOffsetSeen = pauseOffset;
      const tempDirPath: string = joinTempDir(Config.getInstance().getTempDir(), record.id);
      const snapshots: PieceSnapshot[] = engine.getPieceSnapshots();
      let ledgerSum: number = 0;
      let aggregateFileSize: number = 0;
      let filesCoverLedger: boolean = snapshots.length > 0;
      const detailRows: string[] = ['id offset length downloaded fileSize'];
      for (let i: number = 0; i < snapshots.length; i++) {
        const piece: PieceSnapshot = snapshots[i];
        let size: number = -1;
        try {
          size = fileIo.statSync(tempDirPath + '/' + piece.id).size;
        } catch (e) {
          // An unstarted zero-byte piece may have no file yet; never infer downloaded from stat.
        }
        ledgerSum += piece.downloaded;
        if (size >= 0) {
          aggregateFileSize += size;
        }
        if (piece.downloaded < 0 || (piece.length >= 0 && piece.downloaded > piece.length) ||
          (piece.downloaded > 0 && size < piece.downloaded)) {
          filesCoverLedger = false;
        }
        detailRows.push(piece.id + ' ' + String(piece.offset) + ' ' + String(piece.length) +
          ' ' + String(piece.downloaded) + ' ' + String(size));
      }
      const detailFile: string = 'probe-P1-U2-' + runId + '-s5-pieces.txt';
      const detail = fileIo.openSync(this.requireContext().filesDir + '/' + detailFile,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(detail.fd, detailRows.join('\n'));
      } finally {
        fileIo.closeSync(detail.fd);
      }
      const pauseLanded: boolean = this.facts.pausedFired && pauseOffset > 0 && pauseOffset < DOWNLOAD_BYTES;
      const kvs: KeyValue[] = [
        new KeyValue('pauseLanded', String(pauseLanded)),
        new KeyValue('pauseOffset', String(pauseOffset)),
        new KeyValue('pieceCount', String(snapshots.length)),
        new KeyValue('ledgerSum', String(ledgerSum)),
        new KeyValue('aggregateFileSize', String(aggregateFileSize)),
        new KeyValue('filesCoverLedger', String(filesCoverLedger)),
        new KeyValue('ledgerMatchesPause', String(ledgerSum === pauseOffset)),
        new KeyValue('onPausedFired', String(this.facts.pausedFired)),
        new KeyValue('detailFile', detailFile)
      ];
      this.probeKit.emit('S5', kvs);
    } catch (e) {
      this.emitStepError('S5', runId, e as BusinessError);
    }
  }

  /** S6 恢复（206 链路核心）：①探针自证——业务 HttpClient 带 Range: bytes=N- 解析 Content-Range；
   * ②引擎 resume → 二次 onConnected（facts.resumeStatus）。startMatches/totalMatches 为
   * §0-6 三检的可观测对应（start==请求偏移、total==4194304）。 */
  private async runS6(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const record = this.activeRecord;
      const engine = this.engine;
      if (record === undefined || engine === undefined) {
        this.probeKit.emit('S6', [new KeyValue('errMessage', 'no active engine')]);
        return;
      }
      if (this.facts.failedFired) {
        this.emitEngineFailed('S6', runId);
        return;
      }
      const pauseOffset: number = this.pauseOffsetSeen;
      const url: string = record.primaryUrl ?? '';
      let probeStatus: number = 0;
      const parts: ContentRangeParts = { start: -1, end: -1, total: -1 };
      const client: HttpClient = new HttpClient();
      try {
        const headers: Record<string, string> = sixDefaultHeaders(url);
        headers['Range'] = resumeRangeHeader(pauseOffset);
        const head: HttpResponseHead = await client.open(url, headers);
        if (!this.probeKit.isCurrent(runId)) {
          return;
        }
        probeStatus = head.status;
        const parsed: ContentRangeParts = parseContentRange(headerValueOf(head.header, 'content-range'));
        parts.start = parsed.start;
        parts.end = parsed.end;
        parts.total = parsed.total;
      } catch (e) {
        const err = e as BusinessError;
        this.logDiag('S6 probe request', err);
      } finally {
        client.abort();
      }
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      engine.resume();
      await this.awaitUntil((): boolean => this.facts.connectedCount >= 2 &&
        this.facts.lastDownloaded > pauseOffset, 30000, 20);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const startMatches: boolean = parts.start === pauseOffset;
      const totalMatches: boolean = parts.total === DOWNLOAD_BYTES;
      const kvs: KeyValue[] = [
        new KeyValue('resumeStatus', String(this.facts.resumeStatus)),
        new KeyValue('probeRequestStatus', String(probeStatus)),
        new KeyValue('contentRangeStart', String(parts.start)),
        new KeyValue('contentRangeTotal', String(parts.total)),
        new KeyValue('requestedOffset', String(pauseOffset)),
        new KeyValue('startMatches', String(startMatches)),
        new KeyValue('totalMatches', String(totalMatches)),
        new KeyValue('engineResumeConnected', String(this.facts.connectedCount >= 2))
      ];
      this.probeKit.emit('S6', kvs);
    } catch (e) {
      this.emitStepError('S6', runId, e as BusinessError);
    }
  }

  /** S7 完成+字节抽查+落库：等 onFinished（60s）→ 抽查点 lseek+readSync 比对确定性字节
   * （allSpotsMatch=true 是 206 续传字节级正确性证据）→ markAsFinished 落库读回 → pending 落盘。 */
  private async runS7(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const ctx: common.Context = this.requireContext();
      const store: DownloadStore = DownloadStore.getInstance();
      const record = this.activeRecord;
      if (record === undefined) {
        this.probeKit.emit('S7', [new KeyValue('errMessage', 'no active record')]);
        return;
      }
      if (this.facts.failedFired) {
        this.emitEngineFailed('S7', runId);
        return;
      }
      await this.awaitUntil((): boolean => this.facts.finishedFired, 60000, 50);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      await this.lastFinishWrite;
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const finalPath: string = this.facts.finalFilePath;
      let finalFileExists: boolean = false;
      try {
        finalFileExists = fileIo.accessSync(finalPath);
      } catch (e) {
        finalFileExists = false;
      }
      const tempDirPath: string = joinTempDir(Config.getInstance().getTempDir(), record.id);
      let tempDirGone: boolean = false;
      try {
        // accessSync returns false for a missing path (it does not throw)
        tempDirGone = !fileIo.accessSync(tempDirPath);
      } catch (e) {
        tempDirGone = true;
      }
      const spotChecks: string = this.runSpotChecks(finalPath);
      const allSpotsMatch: boolean = this.lastSpotAllMatch;
      const row: DownloadRecord | null = await store.getDownloadById(record.id);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const dbKind: number = row !== null ? row.kind : -1;
      const dbName: string = row !== null && row.name !== null ? row.name : 'null';
      const dbSize: number = row !== null ? row.size : -1;
      const dbProgress: number = row !== null ? row.progress : -1;
      const pendingWritten: boolean = this.writePendingJson(ctx.filesDir, record.id, finalPath,
        this.facts.finalFileSize);
      const kvs: KeyValue[] = [
        new KeyValue('finished', String(this.facts.finishedFired)),
        new KeyValue('finalSize', String(this.facts.finalFileSize)),
        new KeyValue('finalFileExists', String(finalFileExists)),
        new KeyValue('tempDirGone', String(tempDirGone)),
        new KeyValue('spotChecks', spotChecks),
        new KeyValue('allSpotsMatch', String(allSpotsMatch)),
        new KeyValue('dbKind', String(dbKind)),
        new KeyValue('dbName', dbName),
        new KeyValue('dbSize', String(dbSize)),
        new KeyValue('dbProgress', String(dbProgress)),
        new KeyValue('pendingFile', pendingWritten ? PERSIST_FILE_NAME : 'writeFailed')
      ];
      this.probeKit.emit('S7', kvs);
    } catch (e) {
      this.emitStepError('S7', runId, e as BusinessError);
    }
  }

  /** S8 列表快照：queryAll/queryFinished 计数 + 完成行 targetdir/name 拼接路径存在性 */
  private async runS8(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const store: DownloadStore = DownloadStore.getInstance();
      const record = this.activeRecord;
      if (record === undefined) {
        this.probeKit.emit('S8', [new KeyValue('errMessage', 'no active record')]);
        return;
      }
      const lists: DownloadLists = await store.queryAll();
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const finished: DownloadRecord[] = await store.queryFinished();
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const row: DownloadRecord | null = await store.getDownloadById(record.id);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      let finalPathInDb: string = 'absent';
      let fileAtPathExists: boolean = false;
      if (row !== null) {
        finalPathInDb = (row.targetDir ?? '') + '/' + (row.name ?? '');
        try {
          fileAtPathExists = fileIo.accessSync(finalPathInDb);
        } catch (e) {
          fileAtPathExists = false;
        }
      }
      const kvs: KeyValue[] = [
        new KeyValue('inProgressCount', String(lists.inProgress.length)),
        new KeyValue('finishedCount', String(finished.length)),
        new KeyValue('finalPathInDb', finalPathInDb),
        new KeyValue('fileAtPathExists', String(fileAtPathExists))
      ];
      this.probeKit.emit('S8', kvs);
    } catch (e) {
      this.emitStepError('S8', runId, e as BusinessError);
    }
  }

  /** S9 重启历史核对（手动单步会话）：读 S7 pending JSON → getDownloadById 核对 kind/size/文件仍在 */
  private async runS9(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const ctx: common.Context = this.requireContext();
      const store: DownloadStore = DownloadStore.getInstance();
      await store.initialize(ctx);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const payload: PersistPayload | null = this.readPendingJson(ctx.filesDir);
      if (payload === null) {
        this.probeKit.emit('S9', [new KeyValue('pendingFound', 'false'),
          new KeyValue('rowFound', 'false')]);
        return;
      }
      const row: DownloadRecord | null = await store.getDownloadById(payload.id);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      let fileStillExists: boolean = false;
      try {
        fileStillExists = fileIo.accessSync(payload.finalPath);
      } catch (e) {
        fileStillExists = false;
      }
      const kvs: KeyValue[] = [
        new KeyValue('pendingFound', 'true'),
        new KeyValue('id', payload.id),
        new KeyValue('rowFound', String(row !== null)),
        new KeyValue('kind', row !== null ? String(row.kind) : '-1'),
        new KeyValue('sizeMatches', String(row !== null && row.size === payload.finalSize)),
        new KeyValue('fileStillExists', String(fileStillExists))
      ];
      this.probeKit.emit('S9', kvs);
    } catch (e) {
      this.emitStepError('S9', runId, e as BusinessError);
    }
  }

  // ---------- 监听器（事件消费方，对照 Index 消费链） ----------

  private buildListener(): DownloadEvents {
    const store: DownloadStore = DownloadStore.getInstance();
    // hvigor 实测：DownloadEvents 方法签名接口不可用对象字面量装配（arkts-no-untyped-obj-literals）——
    // 改经 ForwardDownloadEvents 实现类做闭包转发。
    return new ForwardDownloadEvents(
      (id: string): void => {
        this.facts.startedFired = true;
        const startedRecord = this.activeRecord;
        if (startedRecord !== undefined) {
          startedRecord.status = DownloadStatus.Downloading;
        }
      },
      (id: string, status: number, totalSize: number, resumable: boolean, contentType: string): void => {
        this.facts.connectedCount++;
        if (this.facts.connectedCount === 1) {
          this.facts.firstStatus = status;
          this.facts.firstTotalSize = totalSize;
          this.facts.firstResumable = resumable;
        } else {
          this.facts.resumeStatus = status;
        }
        const record = this.activeRecord;
        if (record !== undefined && totalSize > 0) {
          record.size = totalSize;
        }
      },
      (id: string, progress: number, instantSpeed: number, etaSeconds: number,
        downloadedBytes: number): void => {
        this.facts.progressCount++;
        this.facts.lastProgress = progress;
        this.facts.lastInstantSpeed = instantSpeed;
        this.facts.lastEta = etaSeconds;
        this.facts.lastDownloaded = downloadedBytes;
        const record = this.activeRecord;
        if (record !== undefined) {
          record.status = DownloadStatus.Downloading;
          record.progress = progress;
          record.downloadedBytes = downloadedBytes;
          this.lastProgressWrite = store.updateProgress(record.id, progress);
        }
      },
      (id: string, offsetBytes: number): void => {
        this.facts.pausedFired = true;
        this.facts.pausedOffset = offsetBytes;
        const record = this.activeRecord;
        if (record !== undefined) {
          record.status = DownloadStatus.Stopped;
          record.downloadedBytes = offsetBytes;
          this.lastStatusWrite = store.updateStatus(record.id, DownloadStatus.Stopped);
        }
      },
      (id: string, finalFileSize: number, filePath: string): void => {
        this.facts.finishedFired = true;
        this.facts.finalFileSize = finalFileSize;
        this.facts.finalFilePath = filePath;
        const record = this.activeRecord;
        if (record !== undefined) {
          record.status = DownloadStatus.Finished;
          record.progress = 100;
          record.size = finalFileSize > 0 ? finalFileSize : record.size;
          record.name = this.baseNameOf(filePath);
          this.lastFinishWrite = store.markAsFinished(record.id, finalFileSize,
            this.baseNameOf(filePath), this.dirNameOf(filePath));
        }
      },
      (id: string, errorCode: number, errorMessage: string): void => {
        this.facts.failedFired = true;
        this.facts.failedCode = errorCode;
        this.facts.failedMessage = errorMessage;
        const record = this.activeRecord;
        if (record !== undefined) {
          record.status = DownloadStatus.Stopped;
          this.lastStatusWrite = store.updateStatus(record.id, DownloadStatus.Stopped);
        }
      }
    );
  }

  // ---------- 工具 ----------

  /** 确定性字节抽查：5 抽查点逐点 lseek+readSync（ReadOptions 的 offset 语义是 filePointer 相对量
   * 且 ReadOptions 未从 fileIo 命名空间导出——按期望长度定长分配 buffer 后无 options 读取）比对
   * expectedByteAt；点值 m<offset>=o|x 以 '/' 连接；lastSpotAllMatch 同步回填（openFailed/任一点 x → false）。 */
  private runSpotChecks(finalPath: string): string {
    let report: string = '';
    let allMatch: boolean = true;
    let fd: number = -1;
    try {
      // openSync 返回 File 对象（非 fd number）——取 .fd 存 number 供 lseek/readSync/closeSync 使用
      const spotFile = fileIo.openSync(finalPath, fileIo.OpenMode.READ_ONLY);
      fd = spotFile.fd;
      for (let i = 0; i < SPOT_OFFSET_COUNT; i++) {
        const offset: number = spotOffsetAt(i, DOWNLOAD_BYTES, this.pauseOffsetSeen);
        const expectedLen: number = Math.min(SPOT_WINDOW_BYTES, DOWNLOAD_BYTES - offset);
        fileIo.lseek(fd, offset, fileIo.WhenceType.SEEK_SET);
        const buf: ArrayBuffer = new ArrayBuffer(expectedLen);
        let readLen: number = 0;
        try {
          readLen = fileIo.readSync(fd, buf);
        } catch (e) {
          readLen = -1;
        }
        const bytes: Uint8Array = new Uint8Array(buf);
        let match: boolean = readLen === expectedLen;
        for (let k = 0; match && k < expectedLen; k++) {
          if (bytes[k] !== expectedByteAt(offset + k)) {
            match = false;
          }
        }
        if (!match) {
          allMatch = false;
        }
        if (report.length > 0) {
          report += '/';
        }
        report += 'm' + String(offset) + '=' + (match ? 'o' : 'x');
      }
    } catch (e) {
      report = 'openFailed';
      allMatch = false;
    } finally {
      if (fd >= 0) {
        try {
          fileIo.closeSync(fd);
        } catch (e) {
          // close 失败吞（抽查只读）
        }
      }
    }
    this.lastSpotAllMatch = allMatch;
    return report;
  }

  private async awaitUntil(predicate: () => boolean, timeoutMs: number, pollMs: number): Promise<boolean> {
    const deadline: number = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (predicate()) {
        return true;
      }
      await new Promise<void>((resolve: () => void) => {
        setTimeout(() => resolve(), pollMs);
      });
    }
    return predicate();
  }

  /** 引擎失败快速 emit（S4~S7 入口守卫；errCode/errMessage 为观测事实，分流 business-code/env） */
  private emitEngineFailed(stepNo: string, runId: string): void {
    if (!this.probeKit.isCurrent(runId)) {
      return;
    }
    const kvs: KeyValue[] = [
      new KeyValue('engineFailed', 'true'),
      new KeyValue('errCode', String(this.facts.failedCode)),
      new KeyValue('errMessage', this.facts.failedMessage)
    ];
    this.probeKit.emit(stepNo, kvs);
  }

  private emitStepError(stepNo: string, runId: string, err: BusinessError): void {
    if (!this.probeKit.isCurrent(runId)) {
      return;
    }
    const kvs: KeyValue[] = [
      new KeyValue('errCode', String(err.code)),
      new KeyValue('errMessage', err.message ?? '')
    ];
    this.probeKit.emit(stepNo, kvs);
  }

  private writePendingJson(filesDir: string, id: string, finalPath: string, finalSize: number): boolean {
    const path: string = filesDir + '/' + PERSIST_FILE_NAME;
    try {
      const payload: PersistPayload = { id: id, finalPath: finalPath, finalSize: finalSize };
      const file = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, JSON.stringify(payload));
      } finally {
        fileIo.closeSync(file);
      }
      return true;
    } catch (e) {
      const err = e as BusinessError;
      this.logDiag('pending write', err);
      return false;
    }
  }

  private readPendingJson(filesDir: string): PersistPayload | null {
    const path: string = filesDir + '/' + PERSIST_FILE_NAME;
    try {
      const text: string = fileIo.readTextSync(path);
      return JSON.parse(text) as PersistPayload;
    } catch (e) {
      return null;
    }
  }

  private requireContext(): common.Context {
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      throw new Error('host context undefined');
    }
    return ctx;
  }

  private logDiag(op: string, err: BusinessError): void {
    hilog.error(0xD001, DIAG_TAG, '%{public}s',
      op + ' errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
  }

  private baseNameOf(path: string): string {
    const idx: number = path.lastIndexOf('/');
    return idx >= 0 ? path.slice(idx + 1) : path;
  }

  private dirNameOf(path: string): string {
    const idx: number = path.lastIndexOf('/');
    return idx >= 0 ? path.slice(0, idx) : path;
  }

  /** 测试源拼接：TextInput 值去尾部斜杠 + 路由；空值回退缺省地址（ProbeHttp 同构） */
  private joinBase(path: string): string {
    let base: string = this.baseUrl.trim();
    if (base.length === 0) {
      base = DEFAULT_BASE_URL;
    }
    while (base.length > 0 && base.charAt(base.length - 1) === '/') {
      base = base.slice(0, base.length - 1);
    }
    return base + path;
  }

  build() {
    Column({ space: 12 }) {
      Text($r('app.string.probe_p1u2_source_hint'))
        .fontSize(12)
        .opacity(0.7)
        .width('100%')
      TextInput({ text: this.baseUrl, placeholder: $r('app.string.probe_p1u2_source_hint') })
        .onChange((value: string) => {
          this.baseUrl = value;
        })
        .width('100%')
      Text($r('app.string.probe_p1u2_restart_hint'))
        .fontSize(12)
        .opacity(0.7)
        .width('100%')
      ProbePage({
        unitId: 'P1-U2',
        pageTitle: $r('app.string.probe_p1u2_title'),
        steps: DOWNLOAD_STEPS,
        autoStart: false,
        runStep: (stepNo: string): Promise<void> => this.runStep(stepNo)
      })
        .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .padding(16)
  }
}
