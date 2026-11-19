/*
 * U3.2 限速纯逻辑层（设计书 §2.3/§3.1/§5.1；对照 SpeedLimiter.cs）。
 * 零 @kit import——Hypium 本地单测可直接加载（PieceAlgo/QueueAlgo 同口径），同时供
 * SegmentWorker（taskpool @Concurrent 体）经 import 引用（HttpClient 先例：top-level export）。
 *
 * 数学逐字铁律（SpeedLimiter.cs:46-82 ThrottleIfNeeded，一字不改）：
 *   :49  speedLimit<1 早退（不限速零开销——限速关闭=零回归承诺的纯函数半区）
 *   :50  首调（lastBytes==0 || lastTick==0）只初始化基线并返回 0
 *   :59  maxBytesPerMS = speedLimit*1024/1000（源 (double) 强转等价：number 即双精度）
 *   :62  actualTimeSpent<1 返回 0 且**不推进基线**（亚毫秒窗口并入下次测量）
 *   :64  diff 可为负（测量基准回落，如重连后基线重建场景）
 *   :65-66 基线先推进（无论是否睡眠）
 *   :69  仅 actualTimeSpent < expectedTimeSpent（严格 <）才睡——恰好等于不睡
 *   :73  Math.ceil 取整（源 (int)Math.Ceiling 逐字）
 *
 * 与源码的有意差异（设计书 D 系）：
 *   D1  作用域：源 per-download 共享 limiter（聚合=limit）→ per-worker 独立 + 主线程
 *       share=limit/maxSegments 静态均摊（perWorkerLimitKBps）——聚合恒 ≤limit（保守），
 *       满段并发=limit，单分段（maxSegments=1）与源码逐字等价。
 *   D2  热生效：源 3s 缓存重读 Config（:22-31 GetCachedSpeedLimit + -2 哨兵）消亡——
 *       share 派发时读、attempt 期间冻结，变更下次派发生效。
 *   D3  执行机制：源阻塞线程 sleep+ManualResetEvent（:84-87/:17-20）→ 本层只**算**睡眠
 *       毫秒，sleep 执行留在 worker 侧异步分片（可取消，SegmentWorker.sleepCancellable）。
 *   D15 时钟源：源 Helpers.TickCount()=Environment.TickCount64（含深睡）→ 调用方传
 *       systemDateTime.getUptime(TimeType.ACTIVE,false)（不含深睡，@ohos.systemDateTime.d.ts:238
 *       本会话核实）——活动下载场景等价；本层对时钟来源零耦合（nowMs 形参传入）。
 *   D16 测量基准：源 downloader.GetDownloaded() 聚合字节 → bytesNow=worker 自身 written
 *       （本 attempt 字节），resume/重派后基线自然重建（源每次 resume 新建 downloader 同构）。
 *
 * 分层红线：零 probe import、零 hilog、零 [XDM_PROBE] 输出（纯函数层静默）。
 */

/** 限速基线（对照 SpeedLimiter.cs:10 `private long lastTick, lastBytes` 实例字段）。
 * 源 :11 sleepHandle（ManualResetEvent）与 :12-13 lastChecked/cachedSpeedLimit（3s 缓存）
 * 无对应物——唤醒改 isCanceled 切片轮询（D4）、缓存机制消亡（D2）。 */
export class ThrottleState {
  lastTick: number = 0;
  lastBytes: number = 0;
}

/**
 * 限速睡眠计算（SpeedLimiter.cs:46-82 数学逐字，纯函数；mutate state.lastTick/lastBytes——
 * PieceAlgo 纯函数层 mutate pieces 的先例）。返回应睡眠毫秒数（0=不睡）；sleep 执行由调用方
 * 异步承担（D3）。
 */
export function computeThrottleSleepMs(state: ThrottleState, speedLimitKBps: number,
  bytesNow: number, nowMs: number): number {
  if (speedLimitKBps < 1) {
    // :49 不限速直接返回（不触碰基线）
    return 0;
  }
  if (state.lastBytes === 0 || state.lastTick === 0) {
    // :50-54 首调只初始化基线（测量基准=bytesNow，D16）
    state.lastBytes = bytesNow;
    state.lastTick = nowMs;
    return 0;
  }
  // :59 maxBytesPerMS（源 (double)speedLimit*1024/1000 逐字）
  const maxBytesPerMS: number = speedLimitKBps * 1024 / 1000;
  // :61 actualTimeSpent
  const actualTimeSpent: number = nowMs - state.lastTick;
  if (actualTimeSpent < 1) {
    // :62 亚毫秒窗口：不睡且不推进基线（并入下次测量）
    return 0;
  }
  // :63-64 diff（可为负）
  const diff: number = bytesNow - state.lastBytes;
  // :65-66 基线先推进（无论后续是否睡眠）
  state.lastBytes = bytesNow;
  state.lastTick = nowMs;
  // :67 expectedTimeSpent
  const expectedTimeSpent: number = diff / maxBytesPerMS;
  if (actualTimeSpent < expectedTimeSpent) {
    // :69-73 仅超速才睡；(int)Math.Ceiling 逐字（Math.ceil 返回 double，number 即之）
    return Math.ceil(expectedTimeSpent - actualTimeSpent);
  }
  return 0;
}

/**
 * D1 预算均摊：share = globalKBps / maxSegments（主线程派发时换算，worker 禁触 Config 的
 * 传值通道）。maxSegments<1 防御钳 1（effectiveMaxParallel 同族；源无此分支——派发侧
 * Config 值恒 >=1，防御面兜底）。单段（1）= 全额 limit，与源码逐字等价。
 */
export function perWorkerLimitKBps(globalKBps: number, maxSegments: number): number {
  if (maxSegments >= 1) {
    return globalKBps / maxSegments;
  }
  return globalKBps;
}

/**
 * worker 侧薄封装（设计书 §2.3）：持 speedLimit + 内部 ThrottleState，computeSleep 委托
 * 纯函数——sleep 执行留在 worker（可取消分片，D3）。每 attempt 新实例（源每次 resume 新建
 * downloader 同构，D16：attempt 生命周期自然界定，不复刻源 WakeIfSleeping 的"Set 后永不
 * Reset"永久失效态——D4）。
 */
export class SpeedLimiter {
  private readonly speedLimitKBps: number;
  private readonly state: ThrottleState = new ThrottleState();

  constructor(speedLimitKBps: number) {
    this.speedLimitKBps = speedLimitKBps;
  }

  /** :49 同判（speedLimit<1 早退）——限速关闭时调用方据此走零回归直写路径 */
  isEnabled(): boolean {
    return this.speedLimitKBps >= 1;
  }

  /** 委托纯函数（持内部 ThrottleState）；返回睡眠毫秒（0=不睡） */
  computeSleep(bytesNow: number, nowMs: number): number {
    return computeThrottleSleepMs(this.state, this.speedLimitKBps, bytesNow, nowMs);
  }
}
