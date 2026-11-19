/*
 * U2.1 探针单元：P2-U1 分段并发探针（设计书 §6 步骤表）。
 * S1 源 206 预检（自建 requestInStream，不走引擎）｜ S2 8 分段并行下载+字节抽查
 * S3 区间完整性（逐瞬时快照 maxOverlap + 最终快照覆盖）｜ S4 吞吐对比（单连接基线）
 * S5 暂停-恢复（取消排空 activeAfterStop=0 + 恢复完成 + 二次字节抽查）
 * 探针驱动模型：只调业务公开 API（Downloader/HttpClient/DownloadStore）；引擎零 [XDM_PROBE]
 * 输出——分片事实经 Downloader 观测面（activeSegmentCount/getPieceSnapshots）与事件面由监听器
 * 采集进事实袋，各步骤结束统一 emit（事件在步骤中途到达，emit 会破坏"每步骤恰一行"）。
 * maxConcurrent 采集：awaitUntil 谓词轮询循环内每 30ms 附带取样（activeSegmentCount 取 max +
 * 同轮同步抓瞬时 getPieceSnapshots() 存序列供 S3——避免双计时器，设计书 §5.9）。
 * 会话代际守卫：每个 runner 入口捕获 runId，每个 await 恢复后、emit 前过 isCurrent，不一致静默 return。
 * autoStart=false + TextInput：测试源 URL 必须可替换（禁 127.0.0.1，手册可替换参数）。
 * 红线：观测值只写事实不写 PASS/FAIL（coverageComplete/rangeSupported/allSpotsMatch 均为观测
 * 事实的谓词编码，判定在 EXPECT/verify）。
 * 字节抽查：expectedByteAt/spotOffsetAt（ProbeDownloadLogic 同源 import——确定性流锚
 * floor(offset/65536)%251，P1-U2-download-server.js makeSlice 同式）。
 */

import { http } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ProbeKit, KeyValue } from '../core/ProbeKit';
import { ProbePage, ProbeStepDef } from '../core/ProbePage';
import { HttpClient, HttpResponseHead } from '../../core/net/HttpClient';
import { sixDefaultHeaders, headerValueOf } from '../../core/net/HttpProtocol';
import { Downloader, DownloadEvents, ForwardDownloadEvents } from '../../core/engine/Downloader';
import { PieceSnapshot } from '../../core/engine/PieceAlgo';
import { DownloadRecord, newDownloadRecord } from '../../model/DownloadRecord';
import { DownloadStore } from '../../core/db/DownloadStore';
import { Config } from '../../core/Config';
import {
  checkCoverage,
  formatSnapshots,
  throughputRatio,
  SEG_SOURCE_BYTES,
  CoverageResult
} from './ProbeSegmentLogic';
import { SPOT_OFFSET_COUNT, expectedByteAt, spotOffsetAt } from './ProbeDownloadLogic';

/** 测试源缺省地址（手册"可替换参数"占位值；真机/模拟器填主机局域网 IP，禁 127.0.0.1） */
const DEFAULT_BASE_URL: string = 'http://127.0.0.1:8081';

/** S2 等待完成上限（慢源 ms=40 下 4MiB ≈ 2.6s，宽裕 120s） */
const S2_TIMEOUT_MS: number = 120000;

/** 轮询采样周期（maxConcurrent 与快照序列采集粒度） */
const POLL_MS: number = 30;

/** S5 暂停阈值：262144B（1/16 总量，慢源 ms=80 下约 4 块即达） */
const PAUSE_THRESHOLD_BYTES: number = 262144;

/** 字节抽查窗口 */
const SPOT_WINDOW_BYTES: number = 16;

/** 步骤定义表：S1~S5 全 autoRun（会话由 ProbePage 编排，用户改完 URL 后点"运行全部"） */
const SEGMENT_STEPS: ProbeStepDef[] = [
  { stepNo: 'S1', title: '源能力预检（206/Range）', autoRun: true },
  { stepNo: 'S2', title: '8 分段并行下载+字节抽查', autoRun: true },
  { stepNo: 'S3', title: '区间完整性（逐瞬时快照）', autoRun: true },
  { stepNo: 'S4', title: '吞吐对比（单连接基线）', autoRun: true },
  { stepNo: 'S5', title: '暂停-恢复（取消排空）', autoRun: true }
];

/** 引擎事实袋：Downloader 事件回调写入（主线程单写者），各步骤结束统一读取 emit */
class SegmentFacts {
  startedFired: boolean = false;
  connectedCount: number = 0;
  firstStatus: number = 0;
  firstTotalSize: number = -1;
  firstResumable: boolean = false;
  progressCount: number = 0;
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

@Component
export struct ProbeSegment {
  @State baseUrl: string = DEFAULT_BASE_URL;
  private probeKit: ProbeKit = ProbeKit.getInstance();
  private facts: SegmentFacts = new SegmentFacts();
  /** S2 下载期间的瞬时快照序列（30ms 轮询同步采集，S3 逐帧消费） */
  private s2Snapshots: PieceSnapshot[][] = [];
  /** S2 完成时点最终快照（S3 覆盖/间隙校验对象） */
  private s2FinalSnapshots: PieceSnapshot[] = [];
  private s2MaxConcurrent: number = 0;
  private s2ElapsedMs: number = 0;
  private s2Bps: number = 0;
  private s5MaxConcurrentBefore: number = 0;
  /** 最近一次字节抽查的总体匹配结果（runSpotChecks 回填） */
  private lastSpotAllMatch: boolean = false;

  /** 步骤分派：各 runner 自行捕获 runId 并过会话守卫 */
  private async runStep(stepNo: string): Promise<void> {
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
  }

  /** S1 源 206 预检：自建 requestInStream（不走引擎/业务栈）——S2~S5 判定的环境前提 */
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

  /** S2 8 分段并行下载：新建 record → store.add → Downloader.start → 轮询采样
   * （activeSegmentCount 取 max + 瞬时快照序列）→ 等 onFinished → 5 抽查点字节比对。 */
  private async runS2(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const ctx: common.Context = this.requireContext();
      const store: DownloadStore = DownloadStore.getInstance();
      await store.initialize(ctx);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const id: string = 'probe-p2u1-' + runId;
      const name: string = 'probe-p2u1-' + runId + '.bin';
      const url: string = this.joinBase('/slow.bin?ms=40');
      const record: DownloadRecord = newDownloadRecord(name, Config.getInstance().getDownloadDir(), 0,
        'application/octet-stream', url, false, null, null);
      record.id = id;
      const addOk: boolean = await store.add(record);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      this.facts = new SegmentFacts();
      this.s2Snapshots = [];
      this.s2FinalSnapshots = [];
      this.s2MaxConcurrent = 0;
      const engine: Downloader = new Downloader(record, this.buildListener());
      const beginTick: number = Date.now();
      engine.start();
      const done = (): boolean => this.facts.finishedFired || this.facts.failedFired;
      const sample = (): void => {
        const active: number = engine.activeSegmentCount();
        if (active > this.s2MaxConcurrent) {
          this.s2MaxConcurrent = active;
        }
        this.s2Snapshots.push(engine.getPieceSnapshots());
      };
      await this.pollUntil(done, S2_TIMEOUT_MS, POLL_MS, sample);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      this.s2ElapsedMs = Date.now() - beginTick;
      this.s2FinalSnapshots = engine.getPieceSnapshots();
      if (this.facts.failedFired) {
        this.emitEngineFailed('S2', runId);
        return;
      }
      const spotReport: string = this.runSpotChecks(this.facts.finalFilePath, SEG_SOURCE_BYTES, 0);
      const allMatch: boolean = this.lastSpotAllMatch;
      const elapsed: number = this.s2ElapsedMs > 0 ? this.s2ElapsedMs : 1;
      this.s2Bps = Math.floor(this.facts.finalFileSize * 1000 / elapsed);
      const kvs: KeyValue[] = [
        new KeyValue('recordId', id),
        new KeyValue('addOk', String(addOk)),
        new KeyValue('finished', String(this.facts.finishedFired)),
        new KeyValue('piecesCount', String(this.s2FinalSnapshots.length)),
        new KeyValue('maxConcurrent', String(this.s2MaxConcurrent)),
        new KeyValue('connectedCount', String(this.facts.connectedCount)),
        new KeyValue('finalSize', String(this.facts.finalFileSize)),
        new KeyValue('elapsedMs', String(this.s2ElapsedMs)),
        new KeyValue('segBps', String(this.s2Bps)),
        new KeyValue('spotChecks', spotReport),
        new KeyValue('allSpotsMatch', String(allMatch))
      ];
      this.probeKit.emit('S2', kvs);
    } catch (e) {
      this.emitStepError('S2', runId, e as BusinessError);
    }
  }

  /** S3 区间完整性：对 S2 采集的每个瞬时快照分别 checkCoverage 取 maxOverlap（不变量：任一
   * 瞬时 pieces Map 均为 [0,total) 的不交覆盖）；对最终快照校验 gapCount/coveredBytes。
   * 不可对"全程快照并集"校验——历史大窗与其分裂半窗天然重叠（§6-S3 双口径）。 */
  private async runS3(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      let maxOverlap: number = 0;
      for (let i = 0; i < this.s2Snapshots.length; i++) {
        const cov: CoverageResult = checkCoverage(this.s2Snapshots[i]);
        if (cov.overlapCount > maxOverlap) {
          maxOverlap = cov.overlapCount;
        }
      }
      const finalCov: CoverageResult = checkCoverage(this.s2FinalSnapshots);
      const coverageComplete: boolean = finalCov.gapCount === 0 && finalCov.overlapCount === 0 &&
        finalCov.coveredBytes === SEG_SOURCE_BYTES;
      const snapshotLines: string = formatSnapshots(this.s2FinalSnapshots);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const kvs: KeyValue[] = [
        new KeyValue('snapshotLines', snapshotLines),
        new KeyValue('maxOverlapAcrossSnapshots', String(maxOverlap)),
        new KeyValue('finalGapCount', String(finalCov.gapCount)),
        new KeyValue('coveredBytes', String(finalCov.coveredBytes)),
        new KeyValue('sourceBytes', String(SEG_SOURCE_BYTES)),
        new KeyValue('coverageComplete', String(coverageComplete))
      ];
      this.probeKit.emit('S3', kvs);
    } catch (e) {
      this.emitStepError('S3', runId, e as BusinessError);
    }
  }

  /** S4 吞吐对比：单连接基线（业务 HttpClient 无 Range GET /slow.bin?ms=40 → waitStreamEnd
   * 计字节+耗时，abort 收尾）→ throughputRatio(S2.segBps, singleBps)。ratio 为观测值不判定
   * （慢源下期望 >1；快源/空载机器 ≈1，EXPECT 记 UNVERIFIED 分支）。 */
  private async runS4(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    const url: string = this.joinBase('/slow.bin?ms=40');
    const client: HttpClient = new HttpClient();
    let bytes: number = 0;
    try {
      client.onChunk = (chunk: ArrayBuffer): void => {
        bytes += chunk.byteLength;
      };
      const headers: Record<string, string> = sixDefaultHeaders(url);
      const beginTick: number = Date.now();
      const head: HttpResponseHead = await client.open(url, headers);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const ended: boolean = await client.waitStreamEnd();
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const elapsedMs: number = Date.now() - beginTick;
      const singleBps: number = elapsedMs > 0 ? Math.floor(bytes * 1000 / elapsedMs) : 0;
      const ratio: number = throughputRatio(this.s2Bps, singleBps);
      const kvs: KeyValue[] = [
        new KeyValue('requestUrl', url),
        new KeyValue('status', String(head.status)),
        new KeyValue('singleBytes', String(bytes)),
        new KeyValue('streamEnded', String(ended)),
        new KeyValue('singleElapsedMs', String(elapsedMs)),
        new KeyValue('singleBps', String(singleBps)),
        new KeyValue('segBps', String(this.s2Bps)),
        new KeyValue('ratio', String(ratio))
      ];
      this.probeKit.emit('S4', kvs);
    } catch (e) {
      this.emitStepError('S4', runId, e as BusinessError);
    } finally {
      client.abort();
    }
  }

  /** S5 暂停-恢复（取消语义核心）：start → awaitUntil(downloaded>=262144) → stop() →
   * awaitUntil(!isRunning && activeSegmentCount===0)（taskpool.cancel 协作取消排空锚）→
   * resume() → 等 onFinished → 二次字节抽查（暂停偏移处跨分片字节正确性）。 */
  private async runS5(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const ctx: common.Context = this.requireContext();
      const store: DownloadStore = DownloadStore.getInstance();
      await store.initialize(ctx);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const id: string = 'probe-p2u1-s5-' + runId;
      const name: string = 'probe-p2u1-s5-' + runId + '.bin';
      const url: string = this.joinBase('/slow.bin?ms=80');
      const record: DownloadRecord = newDownloadRecord(name, Config.getInstance().getDownloadDir(), 0,
        'application/octet-stream', url, false, null, null);
      record.id = id;
      await store.add(record);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      this.facts = new SegmentFacts();
      this.s5MaxConcurrentBefore = 0;
      const engine: Downloader = new Downloader(record, this.buildListener());
      engine.start();
      const reached = (): boolean => this.facts.lastDownloaded >= PAUSE_THRESHOLD_BYTES ||
        this.facts.failedFired;
      const sample = (): void => {
        const active: number = engine.activeSegmentCount();
        if (active > this.s5MaxConcurrentBefore) {
          this.s5MaxConcurrentBefore = active;
        }
      };
      await this.pollUntil(reached, 60000, POLL_MS, sample);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      if (this.facts.failedFired) {
        this.emitEngineFailed('S5', runId);
        return;
      }
      engine.stop();
      await this.pollUntil((): boolean => !engine.isRunning() && engine.activeSegmentCount() === 0,
        10000, 20, (): void => {
        });
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const pausedOffset: number = this.facts.pausedOffset;
      const activeAfterStop: number = engine.activeSegmentCount();
      engine.resume();
      const done5 = (): boolean => this.facts.finishedFired || this.facts.failedFired;
      await this.pollUntil(done5, S2_TIMEOUT_MS, POLL_MS, (): void => {
      });
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      if (this.facts.failedFired) {
        this.emitEngineFailed('S5', runId);
        return;
      }
      const spotReport: string = this.runSpotChecks(this.facts.finalFilePath, SEG_SOURCE_BYTES,
        pausedOffset);
      const allMatch2: boolean = this.lastSpotAllMatch;
      const kvs: KeyValue[] = [
        new KeyValue('recordId', id),
        new KeyValue('pausedOffset', String(pausedOffset)),
        new KeyValue('activeAfterStop', String(activeAfterStop)),
        new KeyValue('resumed', String(this.facts.finishedFired)),
        new KeyValue('finalSize', String(this.facts.finalFileSize)),
        new KeyValue('maxConcurrentBefore', String(this.s5MaxConcurrentBefore)),
        new KeyValue('spotChecks', spotReport),
        new KeyValue('allSpotsMatch2', String(allMatch2))
      ];
      this.probeKit.emit('S5', kvs);
    } catch (e) {
      this.emitStepError('S5', runId, e as BusinessError);
    }
  }

  // ---------- 监听器（事件消费方，事实袋采集） ----------

  private buildListener(): DownloadEvents {
    // DownloadEvents 方法签名接口禁对象字面量装配（arkts-no-untyped-obj-literals）——
    // 经 ForwardDownloadEvents 实现类闭包转发（U1.2 同证）
    return new ForwardDownloadEvents(
      (id: string): void => {
        this.facts.startedFired = true;
      },
      (id: string, status: number, totalSize: number, resumable: boolean, contentType: string): void => {
        this.facts.connectedCount++;
        if (this.facts.connectedCount === 1) {
          this.facts.firstStatus = status;
          this.facts.firstTotalSize = totalSize;
          this.facts.firstResumable = resumable;
        }
      },
      (id: string, progress: number, instantSpeed: number, etaSeconds: number,
        downloadedBytes: number): void => {
        this.facts.progressCount++;
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

  /** 确定性字节抽查（P1-U2 runSpotChecks 同式，参数化 totalBytes/pauseOffset）：5 抽查点逐点
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

  /** 谓词轮询 + 附带采样（每 pollMs 一轮：谓词先检，未达则采样后 sleep——统一单计时器） */
  private async pollUntil(predicate: () => boolean, timeoutMs: number, pollMs: number,
    sample: () => void): Promise<boolean> {
    const deadline: number = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (predicate()) {
        return true;
      }
      sample();
      await new Promise<void>((resolve: () => void) => {
        setTimeout(() => resolve(), pollMs);
      });
    }
    return predicate();
  }

  /** 引擎失败快速 emit（S2/S5 入口守卫；errCode/errMessage 为观测事实，分流 business-code/env） */
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

  build() {
    Column({ space: 12 }) {
      Text($r('app.string.probe_p2u1_source_hint'))
        .fontSize(12)
        .opacity(0.7)
        .width('100%')
      TextInput({ text: this.baseUrl, placeholder: $r('app.string.probe_p2u1_source_hint') })
        .onChange((value: string) => {
          this.baseUrl = value;
        })
        .width('100%')
      Text($r('app.string.probe_p2u1_pause_hint'))
        .fontSize(12)
        .opacity(0.7)
        .width('100%')
      ProbePage({
        unitId: 'P2-U1',
        pageTitle: $r('app.string.probe_p2u1_title'),
        steps: SEGMENT_STEPS,
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
