/*
 * U2.2 探针单元：P2-U2 断点续传探针（设计书 §6 两段式步骤表）。
 * 会话模型：**A（自动 S1~S3）→ force-stop 杀进程 → B（手动 S4 单步会话）**。
 *   S1 源 206 预检（自建 requestInStream，不走引擎）｜ S2 慢源 /slow.bin?ms=600 下载到 2MiB 暂停
 *   +分片快照（暂停前 2000ms 数据门必触发：2MiB 阈值 ≈2.4s>2s，持久化值非零且滞后可观测）
 *   S3 状态文件体检（StateStore **只读** readChunks 直读 + 双槽存在性 + 逐片 statSync 对拍
 *   minFileOverPersisted 不变量 + staleBytes 容差观测）+ pending 落盘
 *   S4 重启续传（手动 runSingle：读 pending → DB 行重建 → StateStore 直读恢复输入 → Downloader.resume()
 *   恢复桥入口 → firstProgressDownloaded 恢复起点 → 等 onFinished → 5 点字节抽查含暂停邻域）
 * 探针驱动模型（P2-U1 同构）：只调业务公开 API（Downloader/DownloadStore/StateStore readChunks）；
 * 引擎零 [XDM_PROBE] 输出——事件经 ForwardDownloadEvents 事实袋采集，各步骤结束统一 emit。
 * pending 工件：<filesDir>/probe-P2-U2-persist.json（会话 A S3 写、会话 B S4 读；重跑覆盖）。
 * S4 会话门（ProbeDownload S9/ProbeStore R3-F1 同款）：自动会话触达 S4 时行缓冲 >1 行 → 跳过
 * （不发标记行）；runSingle 单步会话仅 BEGIN 1 行 → 执行。
 * 红线：观测值只写事实不写 PASS/FAIL（offsetsUnchanged/allSpotsMatch/minFileOverPersisted 均为
 * 观测事实的谓词编码，判定在 EXPECT/verify）；容差语义（§0-2 拍板）：stop 不补显式保存（源码
 * Stop :109-130 无 SaveChunkState），最旧持久化状态 ≤2s 陈旧——staleBytes≥0 不判上界，
 * firstProgressDownloaded≥restoredSum 才是"从断点继续而非从零"的判别式。
 * 字节抽查：expectedByteAt/spotOffsetAt（ProbeDownloadLogic 同源 import——确定性流锚
 * floor(offset/65536)%251，P1-U2-download-server.js makeSlice 同式）；点集含 pausedDownloaded 邻域。
 */

import { http } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ProbeKit, KeyValue, PROBE_DOMAIN } from '../core/ProbeKit';
import { ProbePage, ProbeStepDef } from '../core/ProbePage';
import { headerValueOf } from '../../core/net/HttpProtocol';
import { Downloader, DownloadEvents, ForwardDownloadEvents } from '../../core/engine/Downloader';
import { PieceSnapshot, EnginePiece, RestoredPieces } from '../../core/engine/PieceAlgo';
import { StateStore } from '../../core/db/StateStore';
import { joinTempDir } from '../../core/db/RecordMapping';
import { DownloadRecord, newDownloadRecord } from '../../model/DownloadRecord';
import { DownloadStore } from '../../core/db/DownloadStore';
import { Config } from '../../core/Config';
import { formatSnapshots, SEG_SOURCE_BYTES } from './ProbeSegmentLogic';
import { SPOT_OFFSET_COUNT, expectedByteAt, spotOffsetAt } from './ProbeDownloadLogic';

/** 非标记诊断行 tag：不含 "XDM_PROBE" 子串（同 ProbePage 惯例） */
const DIAG_TAG: string = 'XdmProbeResume';

/** 测试源缺省地址（手册"可替换参数"占位值；真机/模拟器填主机局域网 IP，禁 127.0.0.1） */
const DEFAULT_BASE_URL: string = 'http://127.0.0.1:8081';

/** 跨会话 pending 工件（<filesDir>/，会话 A S3 写会话 B S4 读；重跑覆盖为最新行） */
const PERSIST_FILE_NAME: string = 'probe-P2-U2-persist.json';

/** S2 暂停阈值 2MiB（慢源 ms=600 下 8 连接合计 ≈850KB/s，≈2.4s 到达——保证暂停前 2000ms
 * 数据门至少触发一次，持久化 downloaded 非零且滞后可观测，§5.6） */
const PAUSE_THRESHOLD_BYTES: number = 2097152;

/** S2 阈值等待上限 90s / S4 完成等待上限 120s */
const PAUSE_TIMEOUT_MS: number = 90000;
const FINISH_TIMEOUT_MS: number = 120000;

/** 轮询周期 */
const POLL_MS: number = 30;

/** 字节抽查窗口 */
const SPOT_WINDOW_BYTES: number = 16;

/** 步骤定义表：S1~S3 autoRun（会话 A），S4 手动（runSingle 单步会话 B） */
const RESUME_STEPS: ProbeStepDef[] = [
  { stepNo: 'S1', title: '源能力预检（206/Range）', autoRun: true },
  { stepNo: 'S2', title: '慢源下载到 2MiB 并暂停', autoRun: true },
  { stepNo: 'S3', title: '状态文件体检+pending 落盘', autoRun: true },
  { stepNo: 'S4', title: '重启续传+字节抽查（手动）', autoRun: false }
];

/** 引擎事实袋：Downloader 事件回调写入（主线程单写者），各步骤结束统一读取 emit */
class ResumeFacts {
  startedFired: boolean = false;
  progressCount: number = 0;
  /** 恢复起点判别式原料：首个 onProgress 的 downloadedBytes（fresh-restart 缺陷直接暴露） */
  firstProgressDownloaded: number = -1;
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

/** pending 逐片行（S2 暂停时 getPieceSnapshots 转储；S4 与 StateStore 读回值按 id 对拍 offset/length） */
class PersistPieceRow {
  id: string = '';
  offset: number = 0;
  length: number = -1;
  downloaded: number = 0;
}

/** 跨会话 pending 载荷（会话 A S3 写、会话 B S4 读；class 装配保 JSON 字段稳定） */
class ResumePending {
  recordId: string = '';
  name: string = '';
  targetDir: string = '';
  url: string = '';
  pausedDownloaded: number = 0;
  sourceBytes: number = 0;
  pieceRows: PersistPieceRow[] = [];
}

@Component
export struct ProbeResume {
  @State baseUrl: string = DEFAULT_BASE_URL;
  @State slowDelayInput: string = '600';
  private probeKit: ProbeKit = ProbeKit.getInstance();
  private facts: ResumeFacts = new ResumeFacts();
  /** S2 暂停时点分片快照（S3 pending 转储原料） */
  private s2PauseSnapshots: PieceSnapshot[] = [];
  /** S2 会话的 recordId/name/url（S3 StateStore 路径与 pending 载荷原料） */
  private s2RecordId: string = '';
  private s2Name: string = '';
  private s2Url: string = '';
  /** 最近一次字节抽查的总体匹配结果（runSpotChecks 回填） */
  private lastSpotAllMatch: boolean = false;

  /** 步骤分派 + S4 会话门（见文件头注释） */
  private async runStep(stepNo: string): Promise<void> {
    if (stepNo === 'S4') {
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
  }

  /** S1 源 206 预检：自建 requestInStream（不走引擎/业务栈，P2-U1 S1 同构）——S2~S4 判定前提 */
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

  /** S2 慢源下载到阈值并暂停：新建 record → store.add → Downloader.start → pollUntil(
   * lastDownloaded≥2MiB 或 failed, 90s) → stop() → pollUntil(!isRunning && activeSegmentCount===0)
   * （取消排空，U2.1 S5 锚复用）→ 快照转储（pending 原料）。 */
  private async runS2(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const ctx: common.Context = this.requireContext();
      const store: DownloadStore = DownloadStore.getInstance();
      await store.initialize(ctx);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const id: string = 'probe-p2u2-' + runId;
      const name: string = 'probe-p2u2-' + runId + '.bin';
      const slowDelayMs: number = Number(this.slowDelayInput.trim());
      if (this.slowDelayInput.trim().length === 0 || !Number.isSafeInteger(slowDelayMs) ||
        slowDelayMs < 0 || slowDelayMs > 60000) {
        throw new Error('slow delay must be an integer from 0 to 60000 ms');
      }
      const url: string = this.joinBase('/slow.bin?ms=' + String(slowDelayMs));
      const record: DownloadRecord = newDownloadRecord(name, Config.getInstance().getDownloadDir(), 0,
        'application/octet-stream', url, false, null, null);
      record.id = id;
      const addOk: boolean = await store.add(record);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      this.facts = new ResumeFacts();
      this.s2PauseSnapshots = [];
      this.s2RecordId = id;
      this.s2Name = name;
      this.s2Url = url;
      const engine: Downloader = new Downloader(record, this.buildListener());
      const beginTick: number = Date.now();
      engine.start();
      const reached = (): boolean => this.facts.lastDownloaded >= PAUSE_THRESHOLD_BYTES ||
        this.facts.failedFired;
      await this.pollUntil(reached, PAUSE_TIMEOUT_MS, POLL_MS);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      if (this.facts.failedFired) {
        this.emitEngineFailed('S2', runId, [
          new KeyValue('recordId', id),
          new KeyValue('addOk', String(addOk))
        ]);
        return;
      }
      engine.stop();
      await this.pollUntil((): boolean => !engine.isRunning() && engine.activeSegmentCount() === 0,
        10000, 20);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      this.s2PauseSnapshots = engine.getPieceSnapshots();
      const pausedOffset: number = this.facts.pausedOffset;
      const activeAfterStop: number = engine.activeSegmentCount();
      const elapsedToPauseMs: number = Date.now() - beginTick;
      const pauseLanded: boolean = this.facts.lastDownloaded >= PAUSE_THRESHOLD_BYTES;
      const kvs: KeyValue[] = [
        new KeyValue('recordId', id),
        new KeyValue('addOk', String(addOk)),
        new KeyValue('pauseLanded', String(pauseLanded)),
        new KeyValue('pausedDownloaded', String(pausedOffset)),
        new KeyValue('pausedPieces', formatSnapshots(this.s2PauseSnapshots)),
        new KeyValue('pausedPieceCount', String(this.s2PauseSnapshots.length)),
        new KeyValue('activeAfterStop', String(activeAfterStop)),
        new KeyValue('elapsedToPauseMs', String(elapsedToPauseMs)),
        new KeyValue('slowDelayMs', String(slowDelayMs))
      ];
      this.probeKit.emit('S2', kvs);
    } catch (e) {
      this.emitStepError('S2', runId, e as BusinessError);
    }
  }

  /** S3 状态文件体检+pending 落盘：new StateStore(joinTempDir(tempDir, recordId)) 只读 readChunks
   * 直读 + accessSync 两槽 + 逐片 statSync(tempDir/<id>).size 与持久化 downloaded 对拍
   * （minFileOverPersisted=§3.5 不变量直接观测：持久化 downloaded ≤ 分片文件实际字节）+
   * staleBytes 容差观测（pausedDownloaded−Σsaved.downloaded，≥0 不判上界——§0-2 拍板）。 */
  private async runS3(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const ctx: common.Context = this.requireContext();
      const recordId: string = this.s2RecordId;
      const tempDir: string = joinTempDir(Config.getInstance().getTempDir(), recordId);
      const stateStore: StateStore = new StateStore(tempDir);
      const restored: RestoredPieces | null = stateStore.readChunks();
      const slot1Exists: boolean = this.existsQuiet(tempDir + '/chunks.json.1');
      const slot2Exists: boolean = this.existsQuiet(tempDir + '/chunks.json.2');
      const savedPieces: number = restored !== null ? restored.pieces.size : 0;
      const savedTotal: number = restored !== null ? restored.totalSize : -1;
      const savedLine: string = restored !== null ? formatSnapshots(this.restoredToSnapshots(restored)) : '';
      const savedSum: number = restored !== null ? this.sumDownloaded(restored) : 0;
      const pausedDownloaded: number = this.facts.pausedFired ? this.facts.pausedOffset : 0;
      const staleBytes: number = restored !== null ? pausedDownloaded - savedSum : -1;
      const minFileOverPersisted: boolean = this.checkMinFileOverPersisted(tempDir, restored);
      const pending: ResumePending = new ResumePending();
      pending.recordId = recordId;
      pending.name = this.s2Name;
      pending.targetDir = Config.getInstance().getDownloadDir();
      pending.url = this.s2Url;
      pending.pausedDownloaded = pausedDownloaded;
      pending.sourceBytes = SEG_SOURCE_BYTES;
      for (let i = 0; i < this.s2PauseSnapshots.length; i++) {
        const snap: PieceSnapshot = this.s2PauseSnapshots[i];
        const row: PersistPieceRow = new PersistPieceRow();
        row.id = snap.id;
        row.offset = snap.offset;
        row.length = snap.length;
        row.downloaded = snap.downloaded;
        pending.pieceRows.push(row);
      }
      const pendingWritten: boolean = this.writePendingJson(ctx.filesDir, pending);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const kvs: KeyValue[] = [
        new KeyValue('slot1Exists', String(slot1Exists)),
        new KeyValue('slot2Exists', String(slot2Exists)),
        new KeyValue('savedPieces', String(savedPieces)),
        new KeyValue('savedTotal', String(savedTotal)),
        new KeyValue('savedLine', savedLine),
        new KeyValue('staleBytes', String(staleBytes)),
        new KeyValue('minFileOverPersisted', String(minFileOverPersisted)),
        new KeyValue('pendingWritten', String(pendingWritten))
      ];
      this.probeKit.emit('S3', kvs);
    } catch (e) {
      this.emitStepError('S3', runId, e as BusinessError);
    }
  }

  /** S4 重启续传+成品字节抽查（手动单步会话 B）：读 pending → getDownloadById 重建 record（DB 行
   * 跨重启存在性兼证）→ StateStore 直读观测恢复输入 → new Downloader(record) → **resume()**（恢复桥
   * 入口）→ 捕获首个 onProgress downloadedBytes → 等 onFinished → spotChecks（5 点含
   * pausedDownloaded 邻域）。offsetsUnchanged=pending.pieceRows 与 restored 按 id 对拍 offset/length
   * （分片结构跨重启不变——写入时机锚：分裂/完成/失败/探测均事件点即时保存，结构无 2s 滞后）。 */
  private async runS4(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const ctx: common.Context = this.requireContext();
      const store: DownloadStore = DownloadStore.getInstance();
      await store.initialize(ctx);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const payload: ResumePending | null = this.readPendingJson(ctx.filesDir);
      if (payload === null) {
        this.probeKit.emit('S4', [new KeyValue('pendingFound', 'false'),
          new KeyValue('rowFound', 'false')]);
        return;
      }
      const row: DownloadRecord | null = await store.getDownloadById(payload.recordId);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const tempDir: string = joinTempDir(Config.getInstance().getTempDir(), payload.recordId);
      const restored: RestoredPieces | null = new StateStore(tempDir).readChunks();
      const restoredPieces: number = restored !== null ? restored.pieces.size : 0;
      const restoredSum: number = restored !== null ? this.sumDownloaded(restored) : 0;
      const restoredLine: string = restored !== null ? formatSnapshots(this.restoredToSnapshots(restored)) : '';
      const offsetsUnchanged: boolean = this.offsetsMatch(payload, restored);
      if (row === null) {
        const noRowKvs: KeyValue[] = [
          new KeyValue('pendingFound', 'true'),
          new KeyValue('rowFound', 'false'),
          new KeyValue('restoredPieces', String(restoredPieces)),
          new KeyValue('restoredSum', String(restoredSum)),
          new KeyValue('restoredLine', restoredLine),
          new KeyValue('offsetsUnchanged', String(offsetsUnchanged))
        ];
        this.probeKit.emit('S4', noRowKvs);
        return;
      }
      this.facts = new ResumeFacts();
      const engine: Downloader = new Downloader(row, this.buildListener());
      engine.resume();
      const done = (): boolean => this.facts.finishedFired || this.facts.failedFired;
      await this.pollUntil(done, FINISH_TIMEOUT_MS, POLL_MS);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const kvs: KeyValue[] = [
        new KeyValue('pendingFound', 'true'),
        new KeyValue('rowFound', 'true'),
        new KeyValue('restoredPieces', String(restoredPieces)),
        new KeyValue('restoredSum', String(restoredSum)),
        new KeyValue('restoredLine', restoredLine),
        new KeyValue('offsetsUnchanged', String(offsetsUnchanged)),
        new KeyValue('resumed', String(this.facts.finishedFired)),
        new KeyValue('firstProgressDownloaded', String(this.facts.firstProgressDownloaded)),
        new KeyValue('finished', String(this.facts.finishedFired)),
        new KeyValue('finalSize', String(this.facts.finalFileSize))
      ];
      if (this.facts.failedFired) {
        // 引擎失败快速收束（不拖满超时）：errCode/errMessage 为观测事实——恢复集含 length=-1 片
        // → errCode=2 NonResumable 是源码同貌边界（:169-170），EXPECT 记 Known-behavior 分支
        kvs.push(new KeyValue('engineFailed', 'true'));
        kvs.push(new KeyValue('errCode', String(this.facts.failedCode)));
        kvs.push(new KeyValue('errMessage', this.facts.failedMessage));
        this.probeKit.emit('S4', kvs);
        return;
      }
      let tempDirGone: boolean = false;
      try {
        tempDirGone = !fileIo.accessSync(tempDir);
      } catch (e) {
        tempDirGone = true;
      }
      const spotReport: string = this.runSpotChecks(this.facts.finalFilePath, SEG_SOURCE_BYTES,
        payload.pausedDownloaded);
      const allMatch: boolean = this.lastSpotAllMatch;
      kvs.push(new KeyValue('tempDirGone', String(tempDirGone)));
      kvs.push(new KeyValue('spotChecks', spotReport));
      kvs.push(new KeyValue('allSpotsMatch', String(allMatch)));
      this.probeKit.emit('S4', kvs);
    } catch (e) {
      this.emitStepError('S4', runId, e as BusinessError);
    }
  }

  // ---------- 监听器（事件消费方，事实袋采集） ----------

  private buildListener(): DownloadEvents {
    // DownloadEvents 方法签名接口禁对象字面量装配（arkts-no-untyped-obj-literals）——
    // 经 ForwardDownloadEvents 实现类闭包转发（U1.2/P2-U1 同证）
    return new ForwardDownloadEvents(
      (id: string): void => {
        this.facts.startedFired = true;
      },
      (id: string, status: number, totalSize: number, resumable: boolean, contentType: string): void => {
        // 连接事实不入袋（S2/S4 判定不消费；恢复后请求构造观测走 server 控制台第二证据）
      },
      (id: string, progress: number, instantSpeed: number, etaSeconds: number,
        downloadedBytes: number): void => {
        this.facts.progressCount++;
        if (this.facts.progressCount === 1) {
          this.facts.firstProgressDownloaded = downloadedBytes;
        }
        this.facts.lastDownloaded = downloadedBytes;
      },
      (id: string, offsetBytes: number): void => {
        this.facts.pausedFired = true;
        this.facts.pausedOffset = offsetBytes;
      },
      (id: string, finalFileSize: number, filePath: string): void => {
        this.facts.finishedFired = true;
        this.facts.finalFileSize = finalFileSize;
        this.facts.finalFilePath = filePath;
      },
      (id: string, errorCode: number, errorMessage: string): void => {
        this.facts.failedFired = true;
        this.facts.failedCode = errorCode;
        this.facts.failedMessage = errorMessage;
      }
    );
  }

  // ---------- 工具 ----------

  /** Σ restored.downloaded（StateStore 读回值求和；totalDownloadedOf 等价，本文件内联避免
   * 引擎层函数跨层借用观测语义） */
  private sumDownloaded(restored: RestoredPieces): number {
    let sum: number = 0;
    restored.pieces.forEach((piece: EnginePiece) => {
      sum += piece.downloaded;
    });
    return sum;
  }

  /** §3.5 不变量直接观测：逐片 statSync(tempDir/<id>).size ≥ 持久化 downloaded 全真才 true
   * （restored null/片文件缺失 → false）。 */
  private checkMinFileOverPersisted(tempDir: string, restored: RestoredPieces | null): boolean {
    if (restored === null) {
      return false;
    }
    let all: boolean = true;
    restored.pieces.forEach((piece: EnginePiece) => {
      try {
        const size: number = fileIo.statSync(tempDir + '/' + piece.id).size;
        if (size < piece.downloaded) {
          all = false;
        }
      } catch (e) {
        all = false;
      }
    });
    return all;
  }

  /** pending.pieceRows 与 restored 按 id 对拍 offset/length（结构锚：分片 offset/length 跨重启不变） */
  private offsetsMatch(pending: ResumePending, restored: RestoredPieces | null): boolean {
    if (restored === null || pending.pieceRows.length === 0) {
      return false;
    }
    let all: boolean = true;
    for (let i = 0; i < pending.pieceRows.length; i++) {
      const row: PersistPieceRow = pending.pieceRows[i];
      const piece = restored.pieces.get(row.id);
      if (piece === undefined || piece.offset !== row.offset || piece.length !== row.length) {
        all = false;
      }
    }
    return all;
  }

  /** RestoredPieces Map → PieceSnapshot[]（formatSnapshots 复用的形态适配；窗口/状态列填 -1/0
   * 观测占位——持久化态无在途窗口概念） */
  private restoredToSnapshots(restored: RestoredPieces): PieceSnapshot[] {
    const snaps: PieceSnapshot[] = [];
    restored.pieces.forEach((piece: EnginePiece) => {
      const snap: PieceSnapshot = {
        id: piece.id,
        offset: piece.offset,
        length: piece.length,
        downloaded: piece.downloaded,
        state: piece.state,
        inflight: false,
        lastStatus: 0,
        windowStart: -1,
        windowEnd: -1
      };
      snaps.push(snap);
    });
    return snaps;
  }

  private writePendingJson(filesDir: string, pending: ResumePending): boolean {
    const path: string = filesDir + '/' + PERSIST_FILE_NAME;
    try {
      const file = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, JSON.stringify(pending));
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

  private readPendingJson(filesDir: string): ResumePending | null {
    const path: string = filesDir + '/' + PERSIST_FILE_NAME;
    try {
      const text: string = fileIo.readTextSync(path);
      const parsed: Object | null = JSON.parse(text);
      if (parsed === null) {
        return null;
      }
      const raw: ResumePending = parsed as ResumePending;
      if (typeof raw.recordId !== 'string' || raw.recordId.length === 0 ||
        !Array.isArray(raw.pieceRows)) {
        return null;
      }
      // 逐字段 class 装配（ArkTS 禁 untyped 对象字面量直投；JSON.parse 产物只经 as 后搬运）
      const pending: ResumePending = new ResumePending();
      pending.recordId = raw.recordId;
      pending.name = typeof raw.name === 'string' ? raw.name : '';
      pending.targetDir = typeof raw.targetDir === 'string' ? raw.targetDir : '';
      pending.url = typeof raw.url === 'string' ? raw.url : '';
      pending.pausedDownloaded = typeof raw.pausedDownloaded === 'number' ? raw.pausedDownloaded : 0;
      pending.sourceBytes = typeof raw.sourceBytes === 'number' ? raw.sourceBytes : 0;
      for (let i = 0; i < raw.pieceRows.length; i++) {
        const src: PersistPieceRow = raw.pieceRows[i];
        const row: PersistPieceRow = new PersistPieceRow();
        row.id = typeof src.id === 'string' ? src.id : '';
        row.offset = typeof src.offset === 'number' ? src.offset : 0;
        row.length = typeof src.length === 'number' ? src.length : -1;
        row.downloaded = typeof src.downloaded === 'number' ? src.downloaded : 0;
        pending.pieceRows.push(row);
      }
      return pending;
    } catch (e) {
      return null;
    }
  }

  /** 确定性字节抽查（P2-U1 runSpotChecks 同式，参数化 totalBytes/pauseOffset）：5 抽查点逐点
   * lseek+readSync 比对 expectedByteAt；点值 m<offset>=o|x 以 '/' 连接；
   * lastSpotAllMatch 同步回填（openFailed/任一点 x → false）。 */
  private runSpotChecks(finalPath: string, totalBytes: number, pauseOffset: number): string {
    let report: string = '';
    let allMatch: boolean = true;
    let fd: number = -1;
    try {
      const spotFile = fileIo.openSync(finalPath, fileIo.OpenMode.READ_ONLY);
      fd = spotFile.fd;
      for (let i = 0; i < SPOT_OFFSET_COUNT; i++) {
        const offset: number = spotOffsetAt(i, totalBytes, pauseOffset);
        const expectedLen: number = Math.min(SPOT_WINDOW_BYTES, totalBytes - offset);
        fileIo.lseek(fd, offset, fileIo.WhenceType.SEEK_SET);
        const buf: ArrayBuffer = new ArrayBuffer(expectedLen);
        let readLen: number = 0;
        try {
          readLen = fileIo.readSync(fd, buf);
        } catch (e) {
          readLen = -1;
        }
        const spotBytes: Uint8Array = new Uint8Array(buf);
        let match: boolean = readLen === expectedLen;
        for (let k = 0; match && k < expectedLen; k++) {
          if (spotBytes[k] !== expectedByteAt(offset + k)) {
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

  /** 谓词轮询（P2-U1 pollUntil 同式，无采样回调需求） */
  private async pollUntil(predicate: () => boolean, timeoutMs: number, pollMs: number): Promise<boolean> {
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

  private existsQuiet(path: string): boolean {
    try {
      return fileIo.accessSync(path);
    } catch (e) {
      return false;
    }
  }

  /** 引擎失败快速 emit（S2/S4 入口守卫；extraKvs 前置观测键，errCode/errMessage 为观测事实） */
  private emitEngineFailed(stepNo: string, runId: string, extraKvs: KeyValue[]): void {
    if (!this.probeKit.isCurrent(runId)) {
      return;
    }
    const kvs: KeyValue[] = extraKvs.slice();
    kvs.push(new KeyValue('engineFailed', 'true'));
    kvs.push(new KeyValue('errCode', String(this.facts.failedCode)));
    kvs.push(new KeyValue('errMessage', this.facts.failedMessage));
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

  private requireContext(): common.Context {
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      throw new Error('host context undefined');
    }
    return ctx;
  }

  /** 测试源拼接：TextInput 值去尾部斜杠 + 路由；空值回退缺省地址（ProbeHttp/ProbeDownload 同构） */
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

  private logDiag(op: string, err: BusinessError): void {
    hilog.error(PROBE_DOMAIN, DIAG_TAG, '%{public}s',
      op + ' errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
  }

  build() {
    Column({ space: 12 }) {
      Text($r('app.string.probe_p2u2_source_hint'))
        .fontSize(12)
        .opacity(0.7)
        .width('100%')
      TextInput({ text: this.baseUrl, placeholder: $r('app.string.probe_p2u2_source_hint') })
        .onChange((value: string) => {
          this.baseUrl = value;
        })
        .width('100%')
      Text($r('app.string.probe_p2u2_restart_hint'))
        .fontSize(12)
        .opacity(0.7)
        .width('100%')
      TextInput({ text: this.slowDelayInput, placeholder: '块间隔（毫秒）：80 / 600 / 2500' })
        .type(InputType.Number)
        .onChange((value: string) => {
          this.slowDelayInput = value;
        })
        .width('100%')
      ProbePage({
        unitId: 'P2-U2',
        pageTitle: $r('app.string.probe_p2u2_title'),
        steps: RESUME_STEPS,
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
