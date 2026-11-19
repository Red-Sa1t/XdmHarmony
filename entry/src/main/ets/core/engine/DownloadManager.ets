/*
 * U3.1 全局下载管理器单例（设计书 §2.1/§3/§5.3；对照 ApplicationCore.cs 双集合调度器）。
 * 职责：并发上限（Config.maxParallelDownloads，默认 3）+ FIFO 排队（优先级字段预留恒 0，D3）
 * + 三事件补位 + 停止/取消双分支——liveMap（运行实例）+ queueMap/queueIds（FIFO 队列，
 * =GenericOrderedDictionary.cs 的 Dict+List 双结构）+ stopIntent 簿记（§0-1）。
 * 事件面零破坏红线：Downloader.ets 三声明（DownloadEvents/Noop/Forward）逐字节不动；引擎事件经
 * 内部 ManagedEvents wrapper 按"簿记→delegate→补位"固定次序转发（对照源码 DownloadFinished/Failed/
 * Cancelled 三处理器 Remove→收尾→ProcessNextQueuedItem 的单线程不可观测相对次序，补位恒最后是
 * 唯一可观测不变量）；Index/探针消费方感知不到 wrapper 存在（事件面冻结手段=wrapper 包裹而非绕开）。
 * 入口语义（D7）：补位/恢复走 launchResume（downloader.resume()，对照 :322 liveDownloads[..].Key.Resume()）、
 * 新建即时走 launchStart（downloader.start()，对照 :180 download.Start()）——全新记录的 resume 经
 * U2.2 恢复桥自退化 start（PieceGrabber.ets pieces 空→start()），行为等价。
 * 线程模型（决策 2/D1）：C# lock(this) 不复刻——ArkTS 主线程事件循环天然串行；全方法同步无 await、
 * 无 Promise 分叉，门判定/入队/补位在单一调用栈内完成（§3.5 同步决策承诺，杜绝调度撕裂）。
 * 双集合一致性：queueMap+queueIds（插入序数组=keys List 同构）必经 enqueue/removeFromQueue 私有
 * 单点同步变更；liveMap 只 get/has/set/delete/size 不遍历（ArkTS 禁 for..in）。
 * 分层红线：零 DownloadStore（DB 写全在 Index 事件消费方）、零 probe import、
 * 业务日志 hilog domain 0x0000 tag 'DownloadManager'，绝不输出 [XDM_PROBE]。
 * U4.2 观测追加（事件面零破坏前提下的两处只读面）：isInteractive(id)（窗创建非对称原料）+
 * endedNonInteractive(id)（R2-F3：engineEchoEnded 摘除前快照的 nonInteractive 末态——
 * 完成窗门 ApplicationCore.cs:410-414 !nonInteractive 的消费原料；DownloadEvents 三声明、
 * ManagedEvents 转发逻辑、公开 API 签名与既有方法语义零改动）。
 */

import { Downloader, DownloadEvents } from './Downloader';
import { AdaptiveDownloader } from './AdaptiveDownloader';
import { isAdaptiveDownloadType } from '../../model/AdaptiveSource';
import { pickNextQueuedId, effectiveMaxParallel, QueueOrderEntry } from './QueueAlgo';
import { DownloadRecord } from '../../model/DownloadRecord';
import { DownloadStatus } from '../../model/DownloadTypes';
import { Config } from '../Config';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** 业务日志面（domain 0x0000 / tag 'DownloadManager'；只记异常路径） */
const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'DownloadManager';

/** 排队取消回声钩子（D9）：排队项经 stopOne 摘除后回调；DB 回声（源码 DownloadCanelled→
 * UpdateDownloadStatus(Stopped)）由消费方自行承担——manager 零 DB 写红线优先。
 * Index 本单元不传（UI 无排队取消触点），探针 P3-U1 传计数钩子。 */
export interface ManagerHooks {
  onQueuedCancelled?: (id: string) => void;
}

/** Common run surface of the Http (Downloader) and adaptive (AdaptiveDownloader) engines
 * (IBaseDownloader counterpart); both report through the same six DownloadEvents. */
export interface ManagedDownloader {
  start(): void;
  resume(): void;
  stop(): void;
  isRunning(): boolean;
}

/** Factory by persisted download type: Hls/Dash/Dual use the adaptive engine, everything else Http. */
export function createManagedDownloader(record: DownloadRecord, events: DownloadEvents): ManagedDownloader {
  if (isAdaptiveDownloadType(record.downloadType)) {
    return new AdaptiveDownloader(record, events);
  }
  return new Downloader(record, events);
}

/** 运行槽（对照 KeyValuePair<IBaseDownloader, bool>，ApplicationCore.cs:157/:303 值元组） */
class LiveSlot {
  downloader: ManagedDownloader;
  /** 预留（D2）：原版控制进度窗口显隐（CreateProgressWindow/ShowProgressWindow），Phase 4 消费 */
  nonInteractive: boolean = false;

  constructor(downloader: ManagedDownloader) {
    this.downloader = downloader;
  }
}

/** 排队项（对照 queuedDownloads 值 bool :144-147 + 优先级预留） */
class QueuedEntry {
  record: DownloadRecord;
  /** 预留（D3）：源码无优先级（grep 验证），U3.1 恒 0；pickNextQueuedId 按 priority DESC 消费 */
  priority: number = 0;
  /** 预留（D2）：ResumeDownload(nonInteractive) 第二参（:251） */
  nonInteractive: boolean = false;

  constructor(record: DownloadRecord) {
    this.record = record;
  }
}

/**
 * manager 内部事件 wrapper（§3.2）：implements DownloadEvents 持 delegate（Index 的
 * ForwardDownloadEvents 或探针事件袋），六回调固定次序"簿记→delegate→补位"。
 * onStarted/onConnected/onProgress 纯 delegate（manager 零簿记）；onPaused/onFinished/onFailed
 * 先摘 liveMap（返回 wasLive）再 delegate，wasLive 才补位——wasLive 守卫=去重锚（onFailed 与
 * onPaused 竞态双到只补位一次；孤儿事件不触发补位；队列空 dequeueOne 内 no-op）。
 * owner 通道经 DownloadManager 的 engine* 内部窄方法（同文件协作类不可见 private）。
 */
class ManagedEvents implements DownloadEvents {
  private readonly owner: DownloadManager;
  private delegate: DownloadEvents;

  constructor(owner: DownloadManager, delegate: DownloadEvents) {
    this.owner = owner;
    this.delegate = delegate;
  }

  setDelegate(delegate: DownloadEvents): void {
    this.delegate = delegate;
  }

  onStarted(id: string): void {
    this.delegate.onStarted(id);
  }

  onConnected(id: string, status: number, totalSize: number, resumable: boolean, contentType: string): void {
    this.delegate.onConnected(id, status, totalSize, resumable, contentType);
  }

  onProgress(id: string, progress: number, instantSpeed: number, etaSeconds: number,
    downloadedBytes: number): void {
    this.delegate.onProgress(id, progress, instantSpeed, etaSeconds, downloadedBytes);
  }

  onPaused(id: string, offsetBytes: number): void {
    const wasLive: boolean = this.owner.engineEchoPaused(id);
    this.delegate.onPaused(id, offsetBytes);
    this.owner.engineAfterEcho(wasLive);
  }

  onFinished(id: string, finalFileSize: number, filePath: string): void {
    const wasLive: boolean = this.owner.engineEchoEnded(id);
    this.delegate.onFinished(id, finalFileSize, filePath);
    this.owner.engineAfterEcho(wasLive);
  }

  onFailed(id: string, errorCode: number, errorMessage: string): void {
    const wasLive: boolean = this.owner.engineEchoEnded(id);
    this.delegate.onFailed(id, errorCode, errorMessage);
    this.owner.engineAfterEcho(wasLive);
  }
}

/**
 * 全局下载管理器（应用级单例；Index 与探针页共面）。
 * 调用时序红线（§3.1）：Index 先行 store.add+unshift（AddItemToTop :150 先于门后动作 :155-181）
 * 再调 admitNew——门判定与集合变更在 .then 内同步完成，两次快速新建的 .then 按提交序串行，
 * 门判定不会被并发新建穿透。
 */
export class DownloadManager {
  private static instance: DownloadManager | undefined = undefined;

  /** 运行实例（对照 liveDownloads :35；仅 get/has/set/delete/size，不遍历） */
  private liveMap: Map<string, LiveSlot> = new Map();
  /** 排队项成员资格（对照 queuedDownloads 的 Dict 半区） */
  private queueMap: Map<string, QueuedEntry> = new Map();
  /** 队列插入序（对照 keys List 半区；与 queueMap 经 enqueue/removeFromQueue 单点同步） */
  private queueIds: string[] = [];
  /** stop 已发起未回声簿记（§0-1：意图确认+onPaused fire-and-forget 异步时差吸收） */
  private stopIntent: Set<string> = new Set();
  /** 已结束下载的 nonInteractive 末态快照（U4.2/R2-F3 观测追加）：onFinished/onFailed 簿记
   * 先摘 liveMap，事后 isInteractive(id) 恒 true——完成窗门（ApplicationCore.cs:410-414
   * !nonInteractive）需要回声前的值。同 id 新回声覆盖旧值；有界=会话内下载 id 数。 */
  private endedNonInteractiveMap: Map<string, boolean> = new Map();
  /** Stable wrapper shared by all live downloads; undefined until first init. */
  private wrapper: ManagedEvents | undefined = undefined;
  private hooks: ManagerHooks | undefined = undefined;

  private constructor() {
  }

  static getInstance(): DownloadManager {
    if (DownloadManager.instance === undefined) {
      DownloadManager.instance = new DownloadManager();
    }
    return DownloadManager.instance;
  }

  /** Replace the page delegate while retaining the wrapper held by live downloads. */
  init(events: DownloadEvents, hooks?: ManagerHooks): void {
    this.hooks = hooks;
    if (this.wrapper === undefined) {
      this.wrapper = new ManagedEvents(this, events);
    } else {
      this.wrapper.setDelegate(events);
    }
  }

  /** 就绪观测（U3.2 独立复核 medium 修复）：Scheduler 定时恢复在 wrapper 未就绪时须回滚查重门
   * 留待下一 tick 重入，否则启动分钟竞态吞掉整个调度窗。 */
  isReady(): boolean {
    return this.wrapper !== undefined;
  }

  // ---------- 公开 API 面（全同步，无 await） ----------

  /** 新建入队/起跑（对照 StartDownload :126-186：startImmediately=true 且
   * liveDownloads.Count >= MaxParallelDownloads → queuedDownloads.Add(id,false)（:144-147），
   * 否则 liveDownloads.Add+Start（:157/:180）；门不含排队数——排队多深都不改变"运行=3"）。 */
  admitNew(record: DownloadRecord): void {
    if (this.wrapper === undefined) {
      hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s', 'admitNew ignored: init not called id=' + record.id);
      return;
    }
    if (this.liveMap.size >= effectiveMaxParallel(Config.getInstance().getMaxParallelDownloads())) {
      this.enqueue(new QueuedEntry(record));
      return;
    }
    this.launchStart(record);
  }

  /** 用户恢复（对照 ResumeDownload :250-324）：幂等守卫（:261 对已 live/queued 的 id 直接 return，
   * D8：源码批量遇重复项中止整批降为单点幂等 return）→ 门挡入队+record.status=Waiting（仅 UI
   * 内存不落库，SetDownloadStatusWaiting Application.cs:233-241 同貌，源码先 Add 后 RunOnUiThread）
   * → 门过 launchResume（:322 Resume）。
   * U3.2 nonInteractive 可选参落地（源 ResumeDownload 第二参 :251——Scheduler 定时启停 resume
   * 传 true；缺省 false 保持 Index 既有单参调用行为不变；经 QueuedEntry/LiveSlot 预留字段传播，
   * UI 效果（不建进度窗）Phase 4 消费，D13）。 */
  resumeOne(record: DownloadRecord, nonInteractive?: boolean): void {
    if (this.wrapper === undefined) {
      hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s', 'resumeOne ignored: init not called id=' + record.id);
      return;
    }
    if (this.liveMap.has(record.id) || this.queueMap.has(record.id)) {
      return;
    }
    if (this.liveMap.size >= effectiveMaxParallel(Config.getInstance().getMaxParallelDownloads())) {
      const entry: QueuedEntry = new QueuedEntry(record);
      entry.nonInteractive = nonInteractive === true;
      this.enqueue(entry);
      record.status = DownloadStatus.Waiting;
      return;
    }
    this.launchResume(record, nonInteractive);
  }

  /** 停止/取消双分支（对照 StopDownloads :347-380）：live 分支记 stopIntent 后 downloader.stop()
   * （liveMap 摘除交给 onPaused 回声——源码注释掉的 :356 liveDownloads.Remove 不复刻）；queued
   * 分支直接摘除**不补位**（:360-369 无 ProcessNextQueuedItem）+ 仅置内存 status=Stopped（D9，
   * DB 回声归 hooks 消费方）；两边未命中幂等 return（按钮双击/竞态无害）。stop 不等补位——
   * 补位在 onPaused 回声时点（§3.3）。 */
  stopOne(id: string): void {
    const slot: LiveSlot | undefined = this.liveMap.get(id);
    if (slot !== undefined) {
      this.stopIntent.add(id);
      slot.downloader.stop();
      return;
    }
    if (this.queueMap.has(id)) {
      const entry: QueuedEntry | undefined = this.queueMap.get(id);
      this.removeFromQueue(id);
      if (entry !== undefined) {
        entry.record.status = DownloadStatus.Stopped;
      }
      const hooks: ManagerHooks | undefined = this.hooks;
      if (hooks !== undefined) {
        const echo: ((id: string) => void) | undefined = hooks.onQueuedCancelled;
        if (echo !== undefined) {
          echo(id);
        }
      }
      return;
    }
  }

  // ---------- 观测面（探针/拨动按钮消费） ----------

  isLive(id: string): boolean {
    return this.liveMap.has(id);
  }

  isQueued(id: string): boolean {
    return this.queueMap.has(id);
  }

  liveCount(): number {
    return this.liveMap.size;
  }

  queuedCount(): number {
    return this.queueIds.length;
  }

  /** live+queued（对照 ActiveDownloadCount :40——排队也算活跃） */
  activeDownloadCount(): number {
    return this.liveMap.size + this.queueIds.length;
  }

  /** 队列插入序拷贝（=keys List 同构；探针 queuedOrder 观测） */
  queueOrder(): string[] {
    return this.queueIds.slice();
  }

  /** U4.2 观测追加（唯一引擎改动）：live/queued 槽的 nonInteractive 投影（ApplicationCore.cs:166-176
   * vs :305-319 的窗创建非对称原料——Start 路径只看 Config.ShowProgressWindow，Resume 路径额外
   * 要求 !nonInteractive）。未命中 id（含未 init/已结束）恒 true——Start 路径源码即无
   * nonInteractive 门。既有成员/事件面零改动。
   * R2-F3 追加 endedNonInteractive：已结束 id 的 nonInteractive 末态（回声后 isInteractive
   * 不可查的补面——完成窗门消费）；未命中恒 false（interactive，缺省保守）。 */
  isInteractive(id: string): boolean {
    const slot: LiveSlot | undefined = this.liveMap.get(id);
    if (slot !== undefined) {
      return !slot.nonInteractive;
    }
    const entry: QueuedEntry | undefined = this.queueMap.get(id);
    if (entry !== undefined) {
      return !entry.nonInteractive;
    }
    return true;
  }

  /** 已结束下载的 nonInteractive 末态（engineEchoEnded 摘除前快照）；未命中恒 false
   * （interactive——Scheduler 定时恢复外的常规完成路径缺省）。 */
  endedNonInteractive(id: string): boolean {
    const value: boolean | undefined = this.endedNonInteractiveMap.get(id);
    return value === true;
  }

  // ---------- wrapper 内部通道（仅 ManagedEvents 调用；同文件协作类不可见 private，故为
  // 非 private 窄通道——不属公开 API 面，业务/探针不得调用） ----------

  /** onPaused 前簿记：吸收 stopIntent + 摘 liveMap，返回 wasLive（去重守卫/孤儿判定原料）。 */
  engineEchoPaused(id: string): boolean {
    this.stopIntent.delete(id);
    return this.liveMap.delete(id);
  }

  /** onFinished/onFailed 前簿记：摘 liveMap，返回 wasLive。
   * U4.2/R2-F3 追加一行：摘除前快照 nonInteractive 末态（完成窗门原料——事后
   * isInteractive 恒 true 不可查，见 endedNonInteractiveMap 注）。 */
  engineEchoEnded(id: string): boolean {
    const slot: LiveSlot | undefined = this.liveMap.get(id);
    this.endedNonInteractiveMap.set(id, slot !== undefined && slot.nonInteractive);
    return this.liveMap.delete(id);
  }

  /** delegate 之后补位（wasLive 守卫：竞态双到只补位一次、孤儿事件不补位、队列空 no-op）。 */
  engineAfterEcho(wasLive: boolean): void {
    if (wasLive) {
      this.dequeueOne();
    }
  }

  // ---------- 私有实现 ----------

  /** 新建即时路径（对照 :155-181）：liveDownloads.Add（:157）先于 Start（:180，fire-and-forget）。 */
  private launchStart(record: DownloadRecord): void {
    const wrapper: ManagedEvents | undefined = this.wrapper;
    if (wrapper === undefined) {
      return;
    }
    const dl: ManagedDownloader = createManagedDownloader(record, wrapper);
    this.liveMap.set(record.id, new LiveSlot(dl));
    dl.start();
  }

  /** 补位/恢复路径（对照 :322）：liveDownloads 赋值先于 Resume；全新记录经 U2.2 恢复桥自退化
   * start（pieces 空→start()），曾暂停记录正确续传——两语义由一个 resume() 覆盖（D7）。
   * nonInteractive 经 LiveSlot 预留字段落地（D13——dequeueOne 补位从 QueuedEntry 透传）。 */
  private launchResume(record: DownloadRecord, nonInteractive?: boolean): void {
    const wrapper: ManagedEvents | undefined = this.wrapper;
    if (wrapper === undefined) {
      return;
    }
    const dl: ManagedDownloader = createManagedDownloader(record, wrapper);
    const slot: LiveSlot = new LiveSlot(dl);
    slot.nonInteractive = nonInteractive === true;
    this.liveMap.set(record.id, slot);
    dl.resume();
  }

  /** 入队（幂等）：queueMap.has 门保"已存在键不改位"（GenericOrderedDictionary.Add :48-58
   * if(!ContainsKey) keys.Add 同构）；尾插=keys List 追加序。 */
  private enqueue(entry: QueuedEntry): void {
    if (this.queueMap.has(entry.record.id)) {
      return;
    }
    this.queueIds.push(entry.record.id);
    this.queueMap.set(entry.record.id, entry);
  }

  /** 超门回队（=enqueue 尾插；源码 ProcessNextQueuedItem→ResumeDownload 超门时 Remove 后再
   * Add 的尾插 :264——双集合模型中两者同操作，保留双名对齐设计书接口面）。 */
  private enqueueBack(entry: QueuedEntry): void {
    this.enqueue(entry);
  }

  /** 双集合单点同步删除（对照 GenericOrderedDictionary.Remove :96-102）。 */
  private removeFromQueue(id: string): void {
    const idx: number = this.queueIds.indexOf(id);
    if (idx >= 0) {
      this.queueIds.splice(idx, 1);
    }
    this.queueMap.delete(id);
  }

  /** 补位（对照 ProcessNextQueuedItem :567-578：每次恰取 1 个——First→Remove→ResumeDownload
   * 单项，不递归不清空，3 个完成事件=3 次补位）；投影 queueIds→QueueOrderEntry[]（indexed for，
   * Map 不遍历）后交 QueueAlgo 纯函数选首；超门回队尾；关机/keep-alive 尾分支为降级项（D5）。 */
  private dequeueOne(): void {
    if (this.queueIds.length === 0) {
      return;
    }
    const wrapper: ManagedEvents | undefined = this.wrapper;
    if (wrapper === undefined) {
      return;
    }
    const entries: QueueOrderEntry[] = [];
    for (let i = 0; i < this.queueIds.length; i++) {
      const id: string = this.queueIds[i];
      const entry: QueuedEntry | undefined = this.queueMap.get(id);
      const priority: number = entry !== undefined ? entry.priority : 0;
      entries.push(new QueueOrderEntry(id, priority));
    }
    const nextId: string | null = pickNextQueuedId(entries);
    if (nextId === null) {
      return;
    }
    const entry: QueuedEntry | undefined = this.queueMap.get(nextId);
    this.removeFromQueue(nextId);
    if (entry === undefined) {
      return;
    }
    if (this.liveMap.size >= effectiveMaxParallel(Config.getInstance().getMaxParallelDownloads())) {
      this.enqueueBack(entry);
      return;
    }
    this.launchResume(entry.record, entry.nonInteractive);
  }
}
