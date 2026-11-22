/*
 * U2.1 @Concurrent 分段 worker（设计书 §2.3/§3.4/§5.5；TaskPool 侧，对照 PieceGrabber.cs 单连接尝试）。
 * U3.2 限速执行点（设计书 §3.2/§5.4）：主体重构为（重）开环——限速开启时 onChunk 入队 + 异步泵
 * 写盘 + 8MiB 水位 abort 原地重连（burst-chasing）+ sleepCancellable 取消协作；限速关闭时单次
 * 迭代与 U2.1 逐字节等价（零回归硬承诺——泵/队列/水位/重连只在 throttleEnabled 分支存在）。
 *
 * ===================== 取消-重派安全三支柱（设计书 §3.6，审查必查项） =====================
 *  支柱① 窗口定长封顶写：worker 写盘量恒 ≤ 派发窗口长度（onChunk/writeChunk 内 remain 封顶；
 *         开窗口整流模式除外——其无窗口概念且不可分裂）→ 取消中的 worker 永不越界写盘。
 *  支柱② 前缀覆盖幂等：重派起点 = max(attemptBaseRel, lastReportedRel)（主线程 PieceScheduler 决定）；
 *         取消瞬间未回报的字节落在 [恢复点, 真实写入点)，与重派请求提供的字节相同（同一绝对偏移
 *         同源内容），新 worker 从恢复点顺序写覆盖之，内容幂等无洞。
 *  支柱③ Length 精确切片拼装：assemblePieces 每片只读 piece.length 字节 → 被取消 worker 留在分片
 *         文件内的陈旧尾部（超出收缩后 length）恒被忽略。
 *  推论：分裂取消无需等待 worker 退出（无 death-await），record 即删即重派；两 fd 短暂并存同一
 *  分片文件但其中之一不再写盘（isCanceled 先查后写，worker 回调体内原子）。
 * ==========================================================================================
 *
 * @Concurrent 纪律（hvigor 编译期强制 + 人工复查）：
 *  - segmentWorkerTask 为模块级函数（非方法/非嵌套）；参数单对象全传值（WorkerParams 平面对象）；
 *  - 体内仅引用 top-level export（HttpClient/headerValueOf/isCompressed/sixDefaultHeaders/
 *    closedRangeHeader/SpeedLimiter 经 import 引入）与内联字面量（250ms progress 周期、
 *    8388608 水位、5ms 泵空转、100ms 睡眠切片、60000 无——数值常量内联，禁模块级常量，
 *    ProbeHttp.ets:82-83 先例）；
 *  - HttpClient/SpeedLimiter 构造显式传参（禁落 Config 单例——worker 线程 Config 未 init；
 *    限速参数唯一通道是 WorkerParams.speedLimitKBps）；
 *  - fd 只存在于本函数尝试栈帧（局部 let，finally closeSync；约束④禁入任何共享字段）；
 *    泵/队列/水位/计数同样全局部（fd 同纪律）——水位溢出重连不换 fd（追加写位置保持）；
 *  - taskpool.Task.sendData 仅两处：connected 在主 body（await open resolve 后，d.ts :283 NOTE
 *    合规）、progress 在定时器回调（形式上处于回调内，d.ts NOTE 限制——包 try/catch 捕获
 *    10200023/10200024 类即 reportDisabled=true 降级停报，D2：完成时以结果终值兜底）；
 *  - 禁 ProbeKit/probe import、禁 hilog（worker 静默，诊断全走结果 JSON——若实测 hilog 在 taskpool
 *    可用可另行增强，不作依赖）。
 *  - now 时钟唯一来源 systemDateTime.getUptime(TimeType.ACTIVE,false)（直连 @ohos.systemDateTime
 *    **default import**——d.ts:337 `export default systemDateTime` 无具名导出，hvigor 实测
 *    10505001 纠正；d.ts:238 getUptime API10+ 同步——Environment.TickCount64 等价物 D15，
 *    ACTIVE 不含深睡，活动下载场景等价）。
 *
 * 对照源码锚（PieceGrabber.cs）：
 *   开档/lseek     ← :233-236 FileStream(OpenOrCreate)+Seek(Downloaded,Begin)——openSync
 *                    READ_WRITE|CREATE 不带 TRUNC + lseek(writeStartOffset, SEEK_SET)
 *   定长封顶       ← :284-285 Math.Min(BUF.Length, remaining)——dataReceive 事件流等价
 *   写盘 IO 异常   ← :296-299 IOException→NonRetriable(DiskError)——diskErrCode 捕获存储，
 *                    主线程分类为非重试终态
 *   取消协作       ← :286 ThrowIfCancellationRequested——onChunk 入口先查 isCanceled 后写 + abort
 *   调用序保真     ← :301-304 Write→count+=x→UpdateDownloadedBytesCount→ThrottleIfNeeded——
 *                    泵内 writeChunk→written+=n→computeSleep→await sleep（§3.2 铁律）
 *   限速数学       ← SpeedLimiter.cs:46-82 经 SpeedLimiter 委托（数学逐字，本文件零复算）
 *   空闲语义门     ← HttpClient.waitStreamEnd（dataEnd 门 + 15s 空闲硬顶 + abort 三方 race，U1.2 复用）
 *   探测 abort     ← D3：原版同一条流续写下半区+活体吸收 → 本引擎取头即 abort 零落盘，
 *                    下半区由主线程普通闭区间重派（+1 次握手零重复字节）
 *   结果面         ← phase='connect'（status 未到手，重试前 sleep 10s 判据 :118-124）| 'body'
 *
 * U3.2 平台约束与机制（设计书 §0-4/D3）：@ohos.net.http requestInStream 无暂停/背压 API（本会话
 * grep d.ts 证实）——dataReceive 推送不可暂停，故接收与写盘解耦（onChunk 入队+异步泵消费）；
 * 内存有界靠 8388608（8MiB）队列水位：溢出即 abort 当前连接（TCP 窗口关闭=网络真实暂停），泵以
 * 限速排空后带新 Range 原地重连续传（burst-chasing）；attempt 不终结、不耗 timesRetried 预算。
 * 若平台实际提供背压则队列天然有界、水位永不触达（burstReopenCount=0），自然退化为纯睡眠补偿
 * （源码语义）——两种形态下限速均真实且内存有界，探针 P3-U2 以 peakQueuedBytes/burstReopenCount
 * 观测实际形态（D18 观测面，不写判定）。
 */

import { taskpool } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import systemDateTime from '@ohos.systemDateTime';
import { HttpClient, HttpResponseHead } from '../net/HttpClient';
import { TransportProxy } from '../net/TransportPolicy';
import {
  headerValueOf,
  isCompressed,
  copyHeadersWithRange,
  closedRangeHeader
} from '../net/HttpProtocol';
import { SpeedLimiter } from './SpeedLimiter';

/** taskpool.Task 构造参数（平面对象全传值，约束⑥）。end=-1 开窗口（'bytes=0-' 探测类请求）；
 * headers 由主线程合成（sixDefaultHeaders(url)+Range 键）；attempt 仅回声诊断。 */
export interface WorkerParams {
  pieceId: string;
  url: string;
  /** 窗口起点（绝对偏移）；开窗口恒 0 */
  start: number;
  /** 窗口终点（绝对偏移，闭区间上界）；-1=开窗口 */
  end: number;
  /** true=探测类请求 bytes=0-（接受 200/206，per-attempt 分类 D12） */
  openWindow: boolean;
  /** 分片文件绝对路径（tempDir/<pieceId>） */
  pieceFilePath: string;
  /** 写起点相对片首偏移（=派发时刻 piece.downloaded；0 时无需 lseek） */
  writeStartOffset: number;
  /** HttpClient 超时（毫秒；主线程 Config 换算后传入——worker 禁触 Config） */
  timeoutMs: number;
  /** true=探测尝试（取头即 abort 不写盘，§0-3/D3） */
  probeMode: boolean;
  attempt: number;
  /** 2026-11-19：worker 共享状态（SharedArrayBuffer 16B）：Int32[0]=取消标志（1=已取消），
   * Float64@8=已写字节数（每次写盘后更新，主线程轮询）。定时器回调内 Task.sendData 在本平台抛错
   * （reportDisabled，实测几乎每次尝试都降级），主线程因此看不到进度、按 downloaded=0 盲分裂——
   * 被分裂的片往往已近写满，造成大量重复下载与临时文件膨胀；共享计数让分裂与进度显示恢复实时。
   * 取消标志与 Task.isCanceled() 并用（任一为真即停写），缺省（单测直调）时仅依赖 isCanceled。 */
  cancelFlag?: SharedArrayBuffer;
  headers: Record<string, string>;
  /** 2026-11-22：代理决策（主线程按下载自带代理/设置页全局代理解析；缺省=直连） */
  proxy?: TransportProxy;
  /** U3.2 每 worker 限速份额（KB/s；主线程 perWorkerLimitKBps 均摊后注入——worker 禁触 Config
   * 单例纪律的唯一传值通道，D1/D2）。0/<1=不限速（默认——限速关闭走原直写路径，零回归承诺）；
   * 探测尝试派发时恒 0（探测取头即 abort 不涉限速）。 */
  speedLimitKBps: number;
}

/** connected 中途消息（Task.sendData；=原版 PieceConnected 每连接回调的消息化，§0-1）。
 * header Record 不跨消息传 → compressed 在 worker 侧判定（isCompressed）随消息携带
 * （CreateProbeResult :440-441 的消费方在主线程）。 */
export interface WorkerConnectedMsg {
  kind: string;
  pieceId: string;
  probe: boolean;
  status: number;
  /** Content-Length 头值（缺失/非正 → -1；Content-Range total 由主线程 parseContentRange 推导） */
  contentLength: number;
  contentRange: string;
  contentType: string;
  compressed: boolean;
  /** 2026-11-22：Last-Modified 原值（设置「从服务器获取时间戳」用；缺失为空串） */
  lastModified: string;
}

/** progress 中途消息（=原版 UpdateDownloadedBytesCount 共享内存计数的消息化，250ms 周期，D2） */
export interface WorkerProgressMsg {
  kind: string;
  pieceId: string;
  bytesWritten: number;
}

/** 并发函数返回值（结果 JSON 的类型面；主线程 onWorkerResult 分类消费）。
 * status=0 传输异常（errCode=BusinessError.code 原始码，D13）；windowLen=-1 开窗口；
 * diskErrCode≠0 → DiskError 非重试终态；ended=waitStreamEnd 空闲语义（约束②）。
 * U3.2 追加 4 个 throttle 观测字段（D18 平台行为观测面，无源码对应物；限速关闭恒 0——
 * JSON 消费方按字段名读取天然容忍）。 */
export interface WorkerResult {
  pieceId: string;
  attempt: number;
  probe: boolean;
  /** 'connect'=status 未到手（重试前 sleep 10s 判据）| 'body' */
  phase: string;
  status: number;
  errCode: number;
  bytesWritten: number;
  windowLen: number;
  ended: boolean;
  diskErrCode: number;
  contentRange: string;
  contentType: string;
  contentLength: number;
  canceled: boolean;
  /** 限速睡眠次数（attempt 级累计；关闭限速恒 0） */
  throttleSleepCount: number;
  /** 限速睡眠总毫秒（attempt 级累计；关闭限速恒 0） */
  throttleSleepTotalMs: number;
  /** 泵队列峰值字节（背压形态观测：≈0=有原生背压；接近水位=无背压走 burst-chasing，D3/D18） */
  peakQueuedBytes: number;
  /** 水位溢出原地重连次数（8MiB 水位触达计数；关闭限速恒 0） */
  burstReopenCount: number;
}

/** throttle 观测聚合载体（PieceScheduler 跨 attempt 累加 → Downloader.throttleStats 透传，
 * 探针 P3-U2 消费；D18）。字段面与 WorkerResult 追加四字段一一对应。 */
export class ThrottleStats {
  throttleSleepCount: number = 0;
  throttleSleepTotalMs: number = 0;
  peakQueuedBytes: number = 0;
  burstReopenCount: number = 0;
}

/** progress 回报周期（毫秒）——仅主线程引用（探针/UI 观测口径）；worker 函数体内联 250 字面量 */
export const PROGRESS_REPORT_INTERVAL_MS: number = 250;

/**
 * 单连接单窗口尝试（一次 taskpool.Task 调用 = 原版 PieceGrabber 一次 Connect+Download 循环轮次）。
 * probe 模式：open → connected 消息 → abort（零落盘，D3；speedLimitKBps 派发恒 0，不涉限速）。
 * 常规模式限速关闭（speedLimitKBps<1，默认态）：开档/lseek → onChunk 直写（U2.1 逐字节等价）→
 * open → connected 消息 → 定时 progress 回报 → waitStreamEnd → 结果 JSON——（重）开环恰一次迭代。
 * 常规模式限速开启：onChunk 入队（8MiB 水位溢出即 abort）+ 异步泵（writeChunk→限速数学→可取消
 * 分片睡眠）并行消费；waitStreamEnd 放行后（溢出→排空→原地重连 / 自然收尾→排空尾部）收束泵再
 * 返回。取消：isCanceled 协作（onChunk 先查后写 + abort；泵顶检查 + 睡眠 100ms 切片打断——
 * WakeIfSleeping :17-20 的异步等价物 D4）；execute Promise reject 由主线程 record.alive/generation
 * 静默（d.ts:1721）。
 */
@Concurrent
export async function segmentWorkerTask(params: WorkerParams): Promise<string> {
  const cancelView: Int32Array | null = params.cancelFlag !== undefined ? new Int32Array(params.cancelFlag) : null;
  const writtenView: Float64Array | null = params.cancelFlag !== undefined && params.cancelFlag.byteLength >= 16 ?
    new Float64Array(params.cancelFlag, 8, 1) : null;
  const isCancelled = (): boolean => taskpool.Task.isCanceled() ||
    (cancelView !== null && Atomics.load(cancelView, 0) === 1);
  const windowLen: number = params.end >= 0 ? params.end - params.start + 1 : -1;
  const result: WorkerResult = {
    pieceId: params.pieceId,
    attempt: params.attempt,
    probe: params.probeMode,
    phase: 'connect',
    status: 0,
    errCode: 0,
    bytesWritten: 0,
    windowLen: windowLen,
    ended: false,
    diskErrCode: 0,
    contentRange: '',
    contentType: '',
    contentLength: 0,
    canceled: false,
    throttleSleepCount: 0,
    throttleSleepTotalMs: 0,
    peakQueuedBytes: 0,
    burstReopenCount: 0
  };
  // 限速开关（§3.2）：share>=1 且非探测尝试才启用泵式路径（探测不写盘不挂 onChunk，现状保持）
  const throttleEnabled: boolean = params.speedLimitKBps >= 1 && !params.probeMode;
  // 每 attempt 新 limiter（D16：测量基准=本 attempt written，基线随 attempt 生命周期自然重建）
  const limiter: SpeedLimiter = new SpeedLimiter(params.speedLimitKBps);
  // HttpClient 显式传 timeoutMs（@Concurrent 纪律：禁落 Config 单例）；let 化支持水位溢出
  // 原地重连时换新实例（fd 跨重连保持——追加写位置不变，D3）
  let client: HttpClient = new HttpClient(params.timeoutMs, params.proxy);
  // 局部 fd 生命周期（约束④：只存在于本次尝试栈帧，finally closeSync）
  let fd: number = -1;
  let written: number = 0;
  let diskErrCode: number = 0;
  let canceledMark: boolean = false;
  let timerId: number = -1;
  let reportDisabled: boolean = false;
  // 泵式限速局部态（fd 同纪律：仅本尝试栈帧；水位 8388608/空转 5/切片 100 全部内联字面量——
  // @Concurrent 禁模块级常量）
  const queue: ArrayBuffer[] = [];
  let queuedBytes: number = 0;
  let peakQueuedBytes: number = 0;
  let overflow: boolean = false;
  let attemptOver: boolean = false;
  let burstReopenCount: number = 0;
  let throttleSleepCount: number = 0;
  let throttleSleepTotalMs: number = 0;
  // 泵收束句柄（finally 可见；限速关闭恒 resolved Promise——await 零开销，零回归承诺）
  let pumpPromise: Promise<void> = Promise.resolve();

  /** 原 onChunk 写盘体抽公共（逐字保留：窗口定长封顶（支柱①）、n<=0 超窗丢弃、writeSync、
   * written+=n、diskErrCode 捕获——调用序保真 PieceGrabber.cs:301-302 Write→count+=x）。
   * isCanceled 先查由调用方（chunkHandler）保证。 */
  const writeChunk = (chunk: ArrayBuffer): void => {
    let n: number = chunk.byteLength;
    if (windowLen > 0) {
      const remain: number = windowLen - written;
      n = chunk.byteLength > remain ? remain : chunk.byteLength;
    }
    if (n <= 0) {
      // 超窗静默丢弃（200 越界体防御：窗口完成后的残余分块）
      return;
    }
    try {
      fileIo.writeSync(fd, n === chunk.byteLength ? chunk : chunk.slice(0, n));
      written += n;
      if (writtenView !== null) {
        writtenView[0] = written;
      }
    } catch (e) {
      const err = e as BusinessError;
      if (diskErrCode === 0) {
        diskErrCode = err.code;
      }
    }
  };

  /** dataReceive 分块处理（闭包捕获 client 变量——重连换新实例后重挂，见主 body 重开分支）：
   * 取消协作原子点（支柱②前提）+ 限速分流（关闭=U2.1 原路径逐字节；开启=入队+水位）。 */
  const chunkHandler = (chunk: ArrayBuffer): void => {
    if (isCancelled()) {
      canceledMark = true;
      client.abort();
      return;
    }
    if (!throttleEnabled) {
      // ★限速关闭=U2.1 原路径逐字节（§0-7 零回归硬承诺）
      writeChunk(chunk);
      return;
    }
    queue.push(chunk);
    queuedBytes += chunk.byteLength;
    if (queuedBytes > peakQueuedBytes) {
      peakQueuedBytes = queuedBytes;
    }
    if (queuedBytes >= 8388608) {
      // 8MiB 水位（内联字面量）：溢出即断流（TCP 窗口关闭=网络真实暂停，§0-4/D3）——
      // 主 body waitStreamEnd 放行后走排空+原地重连分支
      overflow = true;
      client.abort();
    }
  };

  /** 可取消分片睡眠（WakeIfSleeping :17-20 的 isCanceled 轮询等价，D4）：100ms 切片内联——
   * taskpool cancel 打断长睡眠（stop 后睡眠至多 100ms 内退出）；返回 true=已被取消。 */
  const sleepCancellable = async (ms: number): Promise<boolean> => {
    let remain: number = ms;
    while (remain > 0) {
      if (isCancelled()) {
        return true;
      }
      const slice: number = remain > 100 ? 100 : remain;
      await new Promise<void>((resolve: () => void) => {
        setTimeout(() => resolve(), slice);
      });
      remain -= slice;
    }
    return isCancelled();
  };

  /** 异步泵（仅 throttleEnabled 启动；与主 body 同处 worker 事件循环——两个并发 async 续体，
   * 单线程续体交错无锁）。消费序=调用序保真（PieceGrabber.cs:301-305）：writeChunk（写盘→
   * written+=n）→ 限速数学（computeSleep）→ 异步睡眠补偿（ThrottleIfNeeded :73 的执行体）。 */
  const pump = async (): Promise<void> => {
    while (true) {
      if (isCancelled()) {
        canceledMark = true;
        client.abort();
        return;
      }
      if (queue.length === 0) {
        if (attemptOver) {
          return;
        }
        await new Promise<void>((resolve: () => void) => {
          setTimeout(() => resolve(), 5);   // 空转轮询 5ms 内联
        });
        continue;
      }
      const shifted: ArrayBuffer | undefined = queue.shift();   // shift 返回 ArrayBuffer|undefined 必须窄化
      if (shifted === undefined) {
        continue;
      }
      queuedBytes -= shifted.byteLength;
      writeChunk(shifted);
      if (diskErrCode !== 0) {
        client.abort();   // 盘错唤醒主 body（waitStreamEnd 放行→DiskError 终态）
        return;
      }
      const sleepMs: number = limiter.computeSleep(written,
        systemDateTime.getUptime(systemDateTime.TimeType.ACTIVE, false));
      if (sleepMs > 0) {
        throttleSleepCount++;
        throttleSleepTotalMs += sleepMs;
        if (await sleepCancellable(sleepMs)) {
          canceledMark = true;
          return;
        }
      }
    }
  };

  /** 排空等待（溢出/自然收尾共用）：轮询至队列空——泵继续限速排空（§3.2 burst-chasing）；
   * 取消/盘错旁路退出（泵已 return，主 body 即收尾，不空转）。 */
  const drainQueue = async (): Promise<void> => {
    while (queue.length > 0 && diskErrCode === 0 && !isCancelled()) {
      await new Promise<void>((resolve: () => void) => {
        setTimeout(() => resolve(), 5);
      });
    }
  };

  /** throttle 观测四字段统一回填（设计 §5.4⑦ 所有 return 点赋值——局部计数器天然可读；
   * 限速关闭时四值恒 0，JSON 与 U2.1 逐字节等价，零回归承诺） */
  const applyThrottleObservations = (): void => {
    result.throttleSleepCount = throttleSleepCount;
    result.throttleSleepTotalMs = throttleSleepTotalMs;
    result.peakQueuedBytes = peakQueuedBytes;
    result.burstReopenCount = burstReopenCount;
  };

  try {
    if (!params.probeMode) {
      // 开档 + 定位（PieceGrabber.cs:233-236：OpenOrCreate 等价 READ_WRITE|CREATE 不带 TRUNC +
      // Seek(downloaded, Begin) 等价 lseek(SEEK_SET)；失败 → DiskError 非重试终态 :296-299；
      // 嵌套 catch 内 return 仍触发外层 finally——fd/client/泵清理不遗漏；泵尚未启动零泄漏）
      try {
        const pieceFile = fileIo.openSync(params.pieceFilePath,
          fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
        fd = pieceFile.fd;
        if (params.writeStartOffset > 0) {
          fileIo.lseek(fd, params.writeStartOffset, fileIo.WhenceType.SEEK_SET);
        }
      } catch (e) {
        const err = e as BusinessError;
        result.diskErrCode = err.code;
        applyThrottleObservations();
        return JSON.stringify(result);
      }
      // 窗口定长封顶写 + isCanceled 先查后写（chunkHandler；U2.1 onChunk 体）
      client.onChunk = chunkHandler;
      // 泵启动（仅 throttleEnabled；fd 已就绪、队列此刻必空）——fire-and-forget，
      // finally 的 attemptOver=true + await pumpPromise 收束（单出口纪律）
      if (throttleEnabled) {
        pumpPromise = pump();
      }
    }

    // （重）开环（§3.2）：首迭代体与 U2.1 现网代码逐字一致（client let 化 / headers 首迭代返
    // params.headers 原引用——重开保留Cookie/Referer/所有调用者头，仅替换Range；
    // 溢出重连 attempt 不终结、不耗 timesRetried 预算（D3）
    let firstOpen: boolean = true;
    while (true) {
      let headers: Record<string, string> = params.headers;
      if (!firstOpen) {
        // 重开头：复制attempt的原始请求上下文，Range 自 params.start+written
        // （闭区间窗口终点不变；开窗口 'bytes=<written>-' 续流形态）
        const nextRange: string = params.end >= 0
          ? closedRangeHeader(params.start + written, params.end)
          : 'bytes=' + String(params.start + written) + '-';
        headers = copyHeadersWithRange(params.headers, nextRange);
      }
      const head: HttpResponseHead = await client.open(params.url, headers);
      result.status = head.status;
      result.errCode = head.errCode;
      result.contentRange = headerValueOf(head.header, 'content-range');
      result.contentType = headerValueOf(head.header, 'content-type');
      let contentLength: number = Number(headerValueOf(head.header, 'content-length'));
      if (!Number.isFinite(contentLength) || contentLength <= 0) {
        // GetContentLength 链：Content-Length 缺失/非正 → -1（Content-Range total 主线程侧解析，
        // WebRequestExtensions.cs:55-70 等价）
        contentLength = -1;
      }
      result.contentLength = contentLength;
      result.phase = head.status <= 0 ? 'connect' : 'body';

      if (isCancelled()) {
        result.canceled = true;
        applyThrottleObservations();
        return JSON.stringify(result);
      }
      if (head.status <= 0) {
        // 连接期失败（status=0 传输异常；errCode=原始码观测面 D13）——主线程按 connectPhase
        // sleep(RetryDelay×1000) 后重派（:118-124）；重开迭代传输失败同走此径（真实连接失败
        // 理应消费重试预算——与"水位重连不耗预算"边界互补）
        applyThrottleObservations();
        return JSON.stringify(result);
      }
      if (!firstOpen) {
        // 重开 206 强检（worker 自检，无 connected 消息）：重开体必须自 params.start+written
        // 续流才与 fd 追加写位置对齐——200 全量重流体与前缀重复落盘=数据损坏，故闭/开窗口
        // 统一要求 206；非 206 break 交主线程既有状态机（body 期 retryImmediately 重派全新
        // attempt → 闭窗口 206 强检收敛 InvalidResponse 终态 / 开窗口闭窗转换终态化）
        if (head.status !== 206) {
          break;
        }
      } else {
        // connected 中途消息：worker 并发函数主 body 内发送（d.ts :283 NOTE "Do not use this API
        // in a callback function" 合规——此处非任何回调内；仅首迭代——重开是同 attempt 内部
        // 续流，主线程无 per-连接消费面）
        const connectedMsg: WorkerConnectedMsg = {
          kind: 'connected',
          pieceId: params.pieceId,
          probe: params.probeMode,
          status: head.status,
          contentLength: contentLength,
          contentRange: result.contentRange,
          contentType: result.contentType,
          compressed: isCompressed(head.header),
          lastModified: headerValueOf(head.header, 'last-modified')
        };
        taskpool.Task.sendData(JSON.stringify(connectedMsg));

        if (params.probeMode) {
          // D3：探测取头即 abort（0 字节落盘，下半区由主线程普通闭区间显式重派）
          applyThrottleObservations();
          return JSON.stringify(result);
        }

        // progress 定时回报：250ms 周期内联字面量（@Concurrent 禁模块级常量）；attempt 级仅首
        // 迭代启动（重开不重起——bytesWritten 账本跨重连续算）；定时器回调内 sendData 包
        // try/catch——捕获 10200023/10200024 类即 reportDisabled=true 清除定时器降级停报
        // （D2：主线程字节账本退化为完成驱动，正确性不受影响——分裂节奏由 connected 消息承载）
        timerId = setInterval((): void => {
          if (reportDisabled) {
            return;
          }
          const progressMsg: WorkerProgressMsg = {
            kind: 'progress',
            pieceId: params.pieceId,
            bytesWritten: written
          };
          try {
            taskpool.Task.sendData(JSON.stringify(progressMsg));
          } catch (e) {
            reportDisabled = true;
            if (timerId >= 0) {
              clearInterval(timerId);
              timerId = -1;
            }
          }
        }, 250);
      }

      // 空闲语义门（约束②）：dataEnd 门 + 15s 空闲硬顶 + abort 三方 race（HttpClient.waitStreamEnd
      // 复用）；溢出 abort → false，自然 dataEnd → true
      const ended: boolean = await client.waitStreamEnd();
      if (overflow) {
        // 水位溢出分支：排空（泵继续限速消费）→ 原地重连（burst-chasing，§3.2）
        await drainQueue();
        overflow = false;
        if (canceledMark || diskErrCode !== 0) {
          break;
        }
        if (windowLen > 0 && written >= windowLen) {
          // 溢出与完成竞态：排空后已写满即收尾（主线程按窗口完成分支收敛，ended 不参与判定）
          break;
        }
        burstReopenCount++;
        // 旧 client 已 abort（abort 幂等，finally 再调无害）；fd 跨重连保持（追加写）
        client = new HttpClient(params.timeoutMs, params.proxy);
        client.onChunk = chunkHandler;
        firstOpen = false;
        continue;
      }
      // 自然收尾：排空尾部（泵消费最后入队分块后自退于 attemptOver——见 finally 收束）
      await drainQueue();
      result.ended = ended;
      break;
    }
    result.bytesWritten = written;
    result.diskErrCode = diskErrCode;
    result.canceled = canceledMark || isCancelled();
    applyThrottleObservations();
    return JSON.stringify(result);
  } catch (e) {
    const err = e as BusinessError;
    result.errCode = err.code;
    result.bytesWritten = written;
    result.diskErrCode = diskErrCode;
    result.canceled = canceledMark || isCancelled();
    applyThrottleObservations();
    return JSON.stringify(result);
  } finally {
    // 泵收束（单出口纪律的收尾半区）：attemptOver 置位后队列空即返（≤5ms 轮询节拍）；睡眠中
    // 至多等出当前一片睡眠（源码 ThrottleIfNeeded 末块同样睡后再返——语义保真）；取消路径泵
    // 已自退（顶检/切片检），await 立即放行。限速关闭恒 resolved Promise——零开销零回归。
    attemptOver = true;
    await pumpPromise;
    if (timerId >= 0) {
      clearInterval(timerId);
    }
    // 逐尝试释放（等价 Connect finally 的 request.Abort/response.Close；abort 幂等，探测路径
    // 在此承担 abort 断流，正常完成路径仅承担 destroy 释放）
    client.abort();
    if (fd >= 0) {
      try {
        fileIo.closeSync(fd);
      } catch (e) {
        // close 失败吞（终态路径无后续动作）
      }
    }
  }
}
