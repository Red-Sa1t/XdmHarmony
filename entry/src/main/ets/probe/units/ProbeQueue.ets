/*
 * U3.1 探针单元：P3-U1 队列调度+并发上限探针（设计书 §6 四步步骤表）。
 * 会话模型：**单会话自动 S1→S4**（四步全 autoRun；无人工设备侧动作——人工仅启动主机测试源+
 * 填 IP 后点"运行全部"）。
 *   S1 门参数+基线+源预检（读 Config 门默认值/manager 干净基线；自建 requestInStream GET
 *      /slow.bin?ms=0 + Range: bytes=0-0，不走引擎——P2-U2 S1 同构）
 *   S2 快速提交 6 个 /slow.bin?ms=300（确定性 id probe-p3u1-<runId>-<i>，store.add 前覆盖
 *      record.id——COLD-F1 约定；await 串行提交序=admitNew 门判定序）后立即读即时集合
 *      （liveAfterSubmit/queuedOrder——门判定在单一调用栈同步完成，健康分支确定性 3/3）
 *   S3 拥挤窗口轮询 maxConcurrent 峰值+补位对序列（POLL_MS=100 轮询 liveCount/queuedCount 直至
 *      live==0&&queued==0，90s 超时；事件袋记 onStarted/onFinished 序号流，onFinished 后紧邻的
 *      onStarted 记为补位对——补位 dequeue 在 onFinished 处理器内同步执行、launchResume→resume()→
 *      onStarted 同步派发（PieceGrabber.ets:281），事件流严格 finished(k)→started(补位) 交错）
 *   S4 停止/取消路径（再提交 4 个=3 live+1 queued → stopOne(#10) 排队分支取消不补位 → 依次
 *      stopOne(#7/#8/#9) live 分支（stopIntent 簿记）→ 轮询直至 live==0——队列空 stop 无补位）
 * 探针驱动模型（P2-U1/P2-U2 同构）：只调业务公开 API（DownloadManager/DownloadStore/Config）；
 * manager 零 [XDM_PROBE] 输出——事件经 ForwardDownloadEvents 事实袋采集，各步骤结束统一 emit。
 * manager.init 后到者接管（设计书 §0-9）：探针会话 S1 即 init（Index 在 page=probe 冷启动路由下
 * 不加载，无竞争；探针会话内不切页——手册注记）。
 * 观测值只写事实不写 PASS/FAIL（peakLive<=3/swapTargets=4/5/6 等判定在 EXPECT/verify）。
 * hooks：ManagerHooks.onQueuedCancelled 计数（排队取消回声唯一观测面——S4 queuedCancelledEcho）。
 * 重跑残留（设计书 §8-2）：单例集合基线由 S1 观测（liveBaseline/queuedBaseline 非零→EXPECT 分支
 * UNVERIFIED）；DB 行每轮 +10（probe-p3u1-<runId>-* 主键不冲突），与既有探针同口径不清理。
 */

import { http } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ProbeKit, KeyValue } from '../core/ProbeKit';
import { ProbePage, ProbeStepDef } from '../core/ProbePage';
import { DownloadEvents, ForwardDownloadEvents } from '../../core/engine/Downloader';
import { DownloadManager, ManagerHooks } from '../../core/engine/DownloadManager';
import { DownloadRecord, newDownloadRecord } from '../../model/DownloadRecord';
import { DownloadStore } from '../../core/db/DownloadStore';
import { Config } from '../../core/Config';

/** 测试源缺省地址（手册"可替换参数"占位值；真机/模拟器填主机局域网 IP，禁 127.0.0.1） */
const DEFAULT_BASE_URL: string = 'http://127.0.0.1:8081';

/** S2/S4 下载源慢参数（/slow.bin?ms=300——单下载 ≈3-5s，6 个提交后拥挤窗口 >2s，S2 即时集合
 * 确定性锚；ms 由探针 URL 参数携带，server 零改动） */
const SLOW_MS: number = 300;

/** S2 提交数（3 live + 3 queued） */
const SUBMIT_COUNT: number = 6;
/** S4 追加提交数（3 live + 1 queued） */
const MORE_COUNT: number = 4;

/** S3 拥挤窗口超时 / S4 停止排空超时 / 轮询周期 */
const WINDOW_TIMEOUT_MS: number = 90000;
const STOP_TIMEOUT_MS: number = 30000;
const POLL_MS: number = 100;

/** S1 源预检 dataEnd 兜底超时 */
const SOURCE_TIMEOUT_MS: number = 15000;

/** 步骤定义表：四步全 autoRun（单会话自动 S1→S4） */
const QUEUE_STEPS: ProbeStepDef[] = [
  { stepNo: 'S1', title: '门参数+基线+源预检', autoRun: true },
  { stepNo: 'S2', title: '快速提交 6 观测即时集合', autoRun: true },
  { stepNo: 'S3', title: '拥挤窗口轮询+补位序列', autoRun: true },
  { stepNo: 'S4', title: '停止/取消路径', autoRun: true }
];

/** 事件袋序流行（kind: 's'=onStarted / 'f'=onFinished；补位对扫描原料——仅序流入袋，
 * progress/paused/failed 只计数不入序防内存膨胀） */
class FactEvent {
  kind: string = '';
  id: string = '';

  constructor(kind: string, id: string) {
    this.kind = kind;
    this.id = id;
  }
}

/** 引擎事实袋：wrapper delegate 回调写入（主线程单写者），各步骤结束统一读取 emit */
class QueueFacts {
  eventSeq: FactEvent[] = [];
  startedCount: number = 0;
  finishedCount: number = 0;
  pausedCount: number = 0;
  failedCount: number = 0;
}

@Component
export struct ProbeQueue {
  @State baseUrl: string = DEFAULT_BASE_URL;
  private probeKit: ProbeKit = ProbeKit.getInstance();
  private facts: QueueFacts = new QueueFacts();
  /** 确定性 id→序号 Map（事件袋翻译 + queuedOrder/swapTargets 序号化） */
  private idSeq: Map<string, number> = new Map();
  private seqCounter: number = 0;
  /** 排队取消回声计数（hooks 消费面） */
  private queuedCancelledCount: number = 0;

  /** 步骤分派（四步全 autoRun，无单步会话门） */
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
  }

  /** S1 门参数+基线+源预检：重置会话态（重跑语义）→ manager.init 后到者接管 → 读门默认值与
   * 单例干净基线 → 自建 requestInStream 源预检（不走引擎/业务栈）。 */
  private async runS1(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      this.resetSessionState();
      const manager: DownloadManager = DownloadManager.getInstance();
      manager.init(this.buildListener(), this.buildHooks());
      const maxParallel: number = Config.getInstance().getMaxParallelDownloads();
      const liveBaseline: number = manager.liveCount();
      const queuedBaseline: number = manager.queuedCount();
      const url: string = this.joinBase('/slow.bin?ms=0');
      let status: number = 0;
      let chunks: number = 0;
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
        const rangeHeader: Record<string, string> = {};
        rangeHeader['Range'] = 'bytes=0-0';
        const options: http.HttpRequestOptions = { header: rangeHeader, connectTimeout: 10000, readTimeout: 10000 };
        status = await client.requestInStream(url, options);
        if (!this.probeKit.isCurrent(runId)) {
          return;
        }
        await Promise.race([endGate, new Promise<void>((resolve: () => void) => setTimeout(resolve, SOURCE_TIMEOUT_MS))]);
        if (!this.probeKit.isCurrent(runId)) {
          return;
        }
        const kvs: KeyValue[] = [
          new KeyValue('sourceUrl', url),
          new KeyValue('maxParallel', String(maxParallel)),
          new KeyValue('liveBaseline', String(liveBaseline)),
          new KeyValue('queuedBaseline', String(queuedBaseline)),
          new KeyValue('sourceStatus', String(status)),
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
          new KeyValue('maxParallel', String(maxParallel)),
          new KeyValue('liveBaseline', String(liveBaseline)),
          new KeyValue('queuedBaseline', String(queuedBaseline)),
          new KeyValue('sourceStatus', String(status)),
          new KeyValue('chunks', String(chunks)),
          new KeyValue('errCode', String(err.code)),
          new KeyValue('errMessage', err.message ?? '')
        ];
        this.probeKit.emit('S1', errKvs);
      } finally {
        client.off('dataReceive');
        client.off('dataEnd');
        client.destroy();
      }
    } catch (e) {
      this.emitStepError('S1', runId, e as BusinessError);
    }
  }

  /** S2 快速提交 6 个：确定性 id 序号 1..6（idSeq 登记翻译面）→ await store.add → admitNew；
   * 全部提交完（6 个 add 的 .then 均已执行）立即读集合——门判定在 admitNew 单调用栈内同步完成、
   * store.add 按提交序串行、/slow.bin?ms=300 首完成距提交 >2s，故 liveAfterSubmit/queuedAfterSubmit
   * 健康分支确定性 3/3（设计书 §6 确定性论证①）。 */
  private async runS2(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const ctx: common.Context = this.requireContext();
      const store: DownloadStore = DownloadStore.getInstance();
      await store.initialize(ctx);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const manager: DownloadManager = DownloadManager.getInstance();
      const url: string = this.joinBase('/slow.bin?ms=' + String(SLOW_MS));
      const submitOrder: number[] = [];
      for (let i = 0; i < SUBMIT_COUNT; i++) {
        const seq: number = this.nextSeq();
        const id: string = 'probe-p3u1-' + runId + '-' + String(seq);
        const record: DownloadRecord = newDownloadRecord('q' + String(seq) + '.bin',
          Config.getInstance().getDownloadDir(), 0, null, url, true, null, null);
        record.id = id;
        this.idSeq.set(id, seq);
        const addOk: boolean = await store.add(record);
        if (!this.probeKit.isCurrent(runId)) {
          return;
        }
        if (!addOk) {
          // DB 写失败仍继续提交链（与 Index 同口径记观测，不加判定）——EXPECT 按计数分流
          this.facts.failedCount++;
        }
        submitOrder.push(seq);
        manager.admitNew(record);
      }
      const liveAfterSubmit: number = manager.liveCount();
      const queuedAfterSubmit: number = manager.queuedCount();
      const activeAfterSubmit: number = manager.activeDownloadCount();
      const queuedOrder: string = this.ordinalsOf(manager.queueOrder());
      const kvs: KeyValue[] = [
        new KeyValue('submitted', String(submitOrder.length)),
        new KeyValue('submitOrder', this.joinNumbers(submitOrder)),
        new KeyValue('liveAfterSubmit', String(liveAfterSubmit)),
        new KeyValue('queuedAfterSubmit', String(queuedAfterSubmit)),
        new KeyValue('activeAfterSubmit', String(activeAfterSubmit)),
        new KeyValue('queuedOrder', queuedOrder)
      ];
      this.probeKit.emit('S2', kvs);
    } catch (e) {
      this.emitStepError('S2', runId, e as BusinessError);
    }
  }

  /** S3 拥挤窗口轮询+补位序列：POLL_MS=100 轮询 liveCount/queuedCount 直至 live==0&&queued==0
   * （90s 超时——超时也 emit 观测值由 EXPECT 分流）；补位对=步骤窗口内紧邻 finished→started 对
   * （窗口起点前的 S2 首发不计）；startedFirstOrder=首发序（全局序流前 3 个 start，S2 提交期）。 */
  private async runS3(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const manager: DownloadManager = DownloadManager.getInstance();
      const finishedBefore: number = this.facts.finishedCount;
      const pausedBefore: number = this.facts.pausedCount;
      const failedBefore: number = this.facts.failedCount;
      const seqBefore: number = this.facts.eventSeq.length;
      const beginTick: number = Date.now();
      const deadline: number = beginTick + WINDOW_TIMEOUT_MS;
      let samples: number = 0;
      let peakLive: number = 0;
      let queuedPeak: number = 0;
      while (Date.now() < deadline) {
        const live: number = manager.liveCount();
        const queued: number = manager.queuedCount();
        samples++;
        if (live > peakLive) {
          peakLive = live;
        }
        if (queued > queuedPeak) {
          queuedPeak = queued;
        }
        if (live === 0 && queued === 0) {
          break;
        }
        await this.sleep(POLL_MS);
      }
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const elapsedMs: number = Date.now() - beginTick;
      const swapTargets: number[] = [];
      const swapSources: number[] = [];
      for (let i = seqBefore; i < this.facts.eventSeq.length - 1; i++) {
        const cur: FactEvent = this.facts.eventSeq[i];
        const next: FactEvent = this.facts.eventSeq[i + 1];
        if (cur.kind === 'f' && next.kind === 's') {
          swapSources.push(this.seqOf(cur.id));
          swapTargets.push(this.seqOf(next.id));
        }
      }
      const startedFirstOrder: number[] = [];
      // 首发序=初始 live 三元组（门上限默认 3）的起跑次序（S2 提交期同步派发，序流前 3 个 's'）
      for (let i = 0; i < this.facts.eventSeq.length && startedFirstOrder.length < 3; i++) {
        const ev: FactEvent = this.facts.eventSeq[i];
        if (ev.kind === 's') {
          startedFirstOrder.push(this.seqOf(ev.id));
        }
      }
      const kvs: KeyValue[] = [
        new KeyValue('samples', String(samples)),
        new KeyValue('peakLive', String(peakLive)),
        new KeyValue('queuedPeak', String(queuedPeak)),
        new KeyValue('swapCount', String(swapTargets.length)),
        new KeyValue('swapTargets', this.joinNumbers(swapTargets)),
        new KeyValue('swapSources', this.joinNumbers(swapSources)),
        new KeyValue('startedFirstOrder', this.joinNumbers(startedFirstOrder)),
        new KeyValue('allFinished', String(this.facts.finishedCount - finishedBefore)),
        new KeyValue('failed', String(this.facts.failedCount - failedBefore)),
        new KeyValue('paused', String(this.facts.pausedCount - pausedBefore)),
        // started=全会话累计口径（首发 3+补位 3=6，EXPECT/手册"S2~S3 每下载恰 start 一次"；
        // R1-F2：S3 起点快照 delta 恒=3 与 expect 字面量 6 必假 FAIL）
        new KeyValue('started', String(this.facts.startedCount)),
        new KeyValue('elapsedMs', String(elapsedMs))
      ];
      this.probeKit.emit('S3', kvs);
    } catch (e) {
      this.emitStepError('S3', runId, e as BusinessError);
    }
  }

  /** S4 停止/取消路径：再提交 4 个（#7..#10：3 live+1 queued）→ stopOne(#10)（queued 分支：
   * 摘除+内存 Stopped+hooks 回声，不补位）→ 读集合 → 依次 stopOne(#7/#8/#9)（live 分支：
   * stopIntent 簿记+downloader.stop()）→ 轮询直至 live==0（30s 超时，onPaused 回声排空）。 */
  private async runS4(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const ctx: common.Context = this.requireContext();
      const store: DownloadStore = DownloadStore.getInstance();
      await store.initialize(ctx);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const manager: DownloadManager = DownloadManager.getInstance();
      const url: string = this.joinBase('/slow.bin?ms=' + String(SLOW_MS));
      // paused/failed 基线取在提交循环前（S4 内暂停/失败只源于停止循环后的回声，delta 口径不变）；
      // started 不设全会话基线——newStartsAfterCancel/Stop 各自在 stopOne 动作前取快照（R1-F1：
      // 提交期 3 个 onStarted 在 admitNew 内同步派发，若以提交前为基线两值恒=3 假 FAIL）
      const pausedBefore: number = this.facts.pausedCount;
      const failedBefore: number = this.facts.failedCount;
      const moreIds: string[] = [];
      for (let i = 0; i < MORE_COUNT; i++) {
        const seq: number = this.nextSeq();
        const id: string = 'probe-p3u1-' + runId + '-' + String(seq);
        const record: DownloadRecord = newDownloadRecord('q' + String(seq) + '.bin',
          Config.getInstance().getDownloadDir(), 0, null, url, true, null, null);
        record.id = id;
        this.idSeq.set(id, seq);
        await store.add(record);
        if (!this.probeKit.isCurrent(runId)) {
          return;
        }
        moreIds.push(id);
        manager.admitNew(record);
      }
      const liveAfterSubmit2: number = manager.liveCount();
      const queuedAfterSubmit2: number = manager.queuedCount();
      // 排队取消（queued 分支）：队尾项 #10——摘除不补位
      const queuedId: string = moreIds[moreIds.length - 1];
      const cancelledQueuedSeq: number = this.seqOf(queuedId);
      // "取消/停止之后无新起跑"口径：快照取在 stopOne 动作前（提交期 3 个 start 已在册）
      const startsAtCancel: number = this.facts.startedCount;
      manager.stopOne(queuedId);
      const queuedAfterCancel: number = manager.queuedCount();
      const liveAfterCancel: number = manager.liveCount();
      const newStartsAfterCancel: number = this.facts.startedCount - startsAtCancel;
      const queuedCancelledEcho: number = this.queuedCancelledCount;
      // 依次停止 3 个 live（live 分支：stopIntent 簿记；补位在 onPaused 回声时点且队列空 no-op）
      const startsAtStopLoop: number = this.facts.startedCount;
      for (let i = 0; i < moreIds.length - 1; i++) {
        manager.stopOne(moreIds[i]);
      }
      await this.pollUntil((): boolean => manager.liveCount() === 0, STOP_TIMEOUT_MS, POLL_MS);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const kvs: KeyValue[] = [
        new KeyValue('submittedMore', String(moreIds.length)),
        new KeyValue('liveAfterSubmit2', String(liveAfterSubmit2)),
        new KeyValue('queuedAfterSubmit2', String(queuedAfterSubmit2)),
        new KeyValue('cancelledQueued', String(cancelledQueuedSeq)),
        new KeyValue('queuedAfterCancel', String(queuedAfterCancel)),
        new KeyValue('liveAfterCancel', String(liveAfterCancel)),
        new KeyValue('newStartsAfterCancel', String(newStartsAfterCancel)),
        new KeyValue('queuedCancelledEcho', String(queuedCancelledEcho)),
        new KeyValue('pausedCount', String(this.facts.pausedCount - pausedBefore)),
        new KeyValue('liveAfterStop', String(manager.liveCount())),
        new KeyValue('newStartsAfterStop', String(this.facts.startedCount - startsAtStopLoop)),
        new KeyValue('failed', String(this.facts.failedCount - failedBefore))
      ];
      this.probeKit.emit('S4', kvs);
    } catch (e) {
      this.emitStepError('S4', runId, e as BusinessError);
    }
  }

  // ---------- 监听器（事件消费方，事实袋采集） ----------

  private buildListener(): DownloadEvents {
    // DownloadEvents 方法签名接口禁对象字面量装配（arkts-no-untyped-obj-literals）——
    // 经 ForwardDownloadEvents 实现类闭包转发（U1.2/P2-U1/P2-U2 同证）
    return new ForwardDownloadEvents(
      (id: string): void => {
        this.facts.startedCount++;
        this.facts.eventSeq.push(new FactEvent('s', id));
      },
      (id: string, status: number, totalSize: number, resumable: boolean, contentType: string): void => {
        // 连接事实不入袋（S2~S4 判定不消费；文件名/大小回写由业务消费方承担，manager 不新增）
      },
      (id: string, progress: number, instantSpeed: number, etaSeconds: number,
        downloadedBytes: number): void => {
        // 进度不入袋（观测面是 liveCount 轮询；事件量大记序会膨胀）
      },
      (id: string, offsetBytes: number): void => {
        this.facts.pausedCount++;
      },
      (id: string, finalFileSize: number, filePath: string): void => {
        this.facts.finishedCount++;
        this.facts.eventSeq.push(new FactEvent('f', id));
      },
      (id: string, errorCode: number, errorMessage: string): void => {
        this.facts.failedCount++;
      }
    );
  }

  private buildHooks(): ManagerHooks {
    const hooks: ManagerHooks = {
      onQueuedCancelled: (id: string): void => {
        this.queuedCancelledCount++;
      }
    };
    return hooks;
  }

  // ---------- 工具 ----------

  private resetSessionState(): void {
    this.facts = new QueueFacts();
    this.idSeq = new Map();
    this.seqCounter = 0;
    this.queuedCancelledCount = 0;
  }

  private nextSeq(): number {
    this.seqCounter++;
    return this.seqCounter;
  }

  private seqOf(id: string): number {
    const seq: number | undefined = this.idSeq.get(id);
    return seq !== undefined ? seq : 0;
  }

  private ordinalsOf(ids: string[]): string {
    const parts: string[] = [];
    for (let i = 0; i < ids.length; i++) {
      parts.push(String(this.seqOf(ids[i])));
    }
    return parts.join('/');
  }

  private joinNumbers(nums: number[]): string {
    const parts: string[] = [];
    for (let i = 0; i < nums.length; i++) {
      parts.push(String(nums[i]));
    }
    return parts.join('/');
  }

  /** 谓词轮询（P2-U2 pollUntil 同式，POLL_MS=100 不忙等） */
  private async pollUntil(predicate: () => boolean, timeoutMs: number, pollMs: number): Promise<boolean> {
    const deadline: number = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (predicate()) {
        return true;
      }
      await this.sleep(pollMs);
    }
    return predicate();
  }

  private async sleep(ms: number): Promise<void> {
    await new Promise<void>((resolve: () => void) => {
      setTimeout(() => resolve(), ms);
    });
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

  /** 测试源拼接：TextInput 值去尾部斜杠 + 路由；空值回退缺省地址（ProbeResume 同构） */
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
      Text($r('app.string.probe_p3u1_source_hint'))
        .fontSize(12)
        .opacity(0.7)
        .width('100%')
      TextInput({ text: this.baseUrl, placeholder: $r('app.string.probe_p3u1_source_hint') })
        .onChange((value: string) => {
          this.baseUrl = value;
        })
        .width('100%')
      ProbePage({
        unitId: 'P3-U1',
        pageTitle: $r('app.string.probe_p3u1_title'),
        steps: QUEUE_STEPS,
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
