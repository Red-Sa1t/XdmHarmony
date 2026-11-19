/*
 * U1.2 引擎纯规则层（设计书 §5.4）：零 @kit import——Hypium 本地单测可直接加载。
 * 对照源码锚：
 *   错误码常量 ← ErrorCode.cs:9-19 枚举序位：None=0, Generic=1, NonResumable=2, AssemblingFailed=3,
 *               MaxRetryFailed=4, InvalidResponse=5, FFmpegNotFound=6, FFmpegError=7, DiskError=8,
 *               SessionExpired=9——仅取 U1.2 引擎实际触达的五值（数值=序位锚，禁重排）。
 *   EngineError ← 单类承载原版三异常分类（DownloadException/NonRetriableException/AssembleFailedException）：
 *               retriable=false = NonRetriable/终态语义（§0-1 拍板 4xx/5xx → InvalidResponse 立即终态）；
 *               retriable=true = 连接期/EOF/断流重试类。ArkTS 有限 throw 合规：仅 Error 子类可 throw
 *               （arkts-limited-throw），BusinessError 是 interface 不可 throw。
 *   进度节流数学 ← HTTPDownloaderBase.cs:288-299 UpdateDownloadedBytesCount 1:1：
 *               instantSpeed = ((totalDownloadedBytes-lastDownloadedBytes)*1000)/(ticks-lastProgressUpdatedAt)
 *                 ——C# long 整除（截断向零）→ Math.floor（两操作数非负时等价，设计书 §3.2）；
 *               avgSpeed = (downloadedBytesSinceStartOrResume*1000.0)/ticksElapsed —— C# 浮点除；
 *               progress = computeProgress（U1.1 RecordMapping 同式，消费方组装）；
 *               eta = FileSize>0 ? (long)Math.Ceiling((FileSize-totalDownloadedBytes)/avgSpeed) : 0
 *                 —— D17：avgSpeed<=0 → 0 守卫（C# 对 0 除得 Infinity 再 (long) 强转行为未定义）；
 *               500ms 门 = ticks-lastProgressUpdatedAt>500 且 ticksElapsed>0（:288，门条件由调用方
 *               与 shouldEmitProgress/elapsed>0 组合）。
 *   重试上限 ← PieceGrabber.cs:113-117：先 timesRetried++ 后判 timesRetried>Config.MaxRetry
 *               （先增后判 = 第 MaxRetry+1 次尝试失败才 MaxRetryFailed，最多 11 次尝试）。
 *   D15：Helpers.TickCount → Date.now()（墙钟替单调钟，U1.1 D1 同口径）。
 */

/** 对照 ErrorCode.cs:9-19（序位锚） */
export const ERR_GENERIC: number = 1;
export const ERR_NON_RESUMABLE: number = 2;
export const ERR_MAX_RETRY: number = 4;
export const ERR_INVALID_RESPONSE: number = 5;
export const ERR_DISK_ERROR: number = 8;

/** 引擎错误（ArkTS 有限 throw 合规：仅 Error 子类；retriable=false = 非重试终态） */
export class EngineError extends Error {
  readonly code: number;
  readonly retriable: boolean;

  constructor(code: number, retriable: boolean, message: string) {
    super(message);
    this.code = code;
    this.retriable = retriable;
  }
}

/** 瞬时速度（C# long 整除 → floor）：deltaMs<=0 → 0（除零守卫） */
export function instantSpeedBps(deltaBytes: number, deltaMs: number): number {
  if (deltaMs <= 0) {
    return 0;
  }
  return Math.floor(deltaBytes * 1000 / deltaMs);
}

/** 平均速度（C# 浮点除）：elapsedMs<=0 → 0（除零守卫） */
export function avgSpeedBps(bytes: number, elapsedMs: number): number {
  if (elapsedMs <= 0) {
    return 0;
  }
  return bytes * 1000.0 / elapsedMs;
}

/** ETA 秒（(long)Math.Ceiling 向上取整 + D17 avgSpeed 守卫）：fileSize<=0 或 avgSpeed<=0 → 0 */
export function etaSeconds(fileSize: number, downloaded: number, avgSpeed: number): number {
  if (fileSize <= 0 || avgSpeed <= 0) {
    return 0;
  }
  return Math.ceil((fileSize - downloaded) / avgSpeed);
}

/** 500ms 进度门（HTTPDownloaderBase.cs:288 `ticks - lastProgressUpdatedAt > 500` 1:1） */
export function shouldEmitProgress(ticksNow: number, lastUpdatedAt: number): boolean {
  return ticksNow - lastUpdatedAt > 500;
}

/** 重试上限判定（PieceGrabber.cs:113-117 原序：调用方先 ++ 后判——第 maxRetry+1 次失败才 true） */
export function exceedsMaxRetry(timesRetried: number, maxRetry: number): boolean {
  return timesRetried > maxRetry;
}
