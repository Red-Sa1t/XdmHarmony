/*
 * U2.1 分片调度器 PieceScheduler（设计书 §3.1/§3.5/§5.6；主线程单点，对照 HTTPDownloaderBase 调度面
 * + SingleSourceHTTPDownloader.PieceConnected/AssemblePieces）。
 *
 * ===================== 取消-重派安全三支柱（设计书 §3.6，审查必查项） =====================
 *  支柱① 窗口定长封顶写：worker 写盘量恒 ≤ 派发窗口长度（SegmentWorker.onChunk 封顶；开窗口整流
 *         模式除外——其无窗口概念且不可分裂）→ 取消中的 worker 永不越界写盘。
 *  支柱② 前缀覆盖幂等：重派起点 = max(attemptBaseRel, lastReportedRel)（DispatchRecord 维护；与
 *         piece.downloaded 同步不变量等价——progress 消息同步更新两者）；取消瞬间未回报的字节落在
 *         [恢复点, 真实写入点)，与重派请求提供的字节相同（同一绝对偏移同源内容），新 worker 从恢复
 *         点顺序写覆盖之，内容幂等无洞。
 *  支柱③ Length 精确切片拼装：assemblePieces 每片只读 piece.length 字节（SingleSourceHTTPDownloader
 *         :359/:386）→ 被取消 worker 留在分片文件内的陈旧尾部（超出收缩后 length）恒被忽略。
 *  推论：分裂取消无需等待 worker 退出（无 death-await，§0-5/D5），record 即删即重派；两 fd 短暂并存
 *  同一分片文件但其中之一不再写盘（isCanceled 先查后写，worker 回调体内原子）。
 * ==========================================================================================
 *
 * 线程模型（决策 2/约束⑦）：pieces/records/lastStatusById 三 Map 只在主线程触碰（无锁）——
 *  worker 经 Task.sendData 消息（connected/progress）与结果 Promise 回主线程，调度器单点消化。
 * 主线程单点与消息时序纪律：
 *  - record 必须先入 records Map 再 taskpool.execute（消息可能先于 execute 返回到达）；
 *  - 一切消息/结果处理先过 stopRequested + record.alive + attempt 三守卫（陈旧回执静默）；
 *  - connected 消息分派双轴：校验语义按 record.openWindow 分支（开窗收 200/206、闭窗 206 强检+
 *    Content-Range 三检）、探测值处理按 record.probeMode 分支——整流模式的合法 200 绝不可走
 *    206 强检分支（D12）；
 *  - execute reject（cancel，d.ts:1721 catch 分支）按 record 存在性/attempt 静默或连接期失败处理。
 *
 * 对照源码锚：
 *   start/resume/stop   ← SingleSourceHTTPDownloader.cs:71-104/:111-151 + HTTPDownloaderBase.cs:109-130
 *   probeConnected      ← PieceConnected(result!=null) :228-293（探测值落位 :238-244/盘检 :279-285/
 *                          CreatePiece 驱动 :292；文件名嗅探/OnProbed 不移植 D3/D7）
 *   resumeConnected     ← Connect :194-202 三检（206 强检/total==fileSize/start==请求偏移[U1.2 D9 加固]）
 *   createPiece         ← :307-332 逐行（MAX_COUNT 门/RetryFailedPieces 预算/FindMaxChunk/SplitPiece/
 *                          分裂命中在途分片 cancel+立即重派=§0-5/D5 有意差异）
 *   retryFailedPieces   ← :351-371（getInactiveChunkCount/getInactivePiece 纯函数委托 PieceAlgo）
 *   pieceDownloadFinished/Failed ← :243-266/:224-241（全完成→assemblePieces+onFinished；records 空→
 *                          onFailed；InvalidResponse+totalDownloaded>0→SessionExpired(9) 映射不移植 D11）
 *   assemblePieces      ← SortAndValidatePieces+AssemblePieces :295-483（排序/盘检 :318-325/5MB 缓冲
 *                          :346/EOF 早尽 :386-391/清 temp :544-555；AssemblingProgressChanged 不移植 D7）
 *   进度 500ms 门       ← UpdateDownloadedBytesCount :288-299（EngineMath 数学零改动复用，入口换消息聚合 D2）
 *   stop 即清 records   ← D9：原版死 grabber 滞留 grabberDict 致恢复卡死 Count==MAX_COUNT 的边界 bug 不复刻
 *   SaveChunkState      ← U2.2 已落盘（8 调用点逐锚，对照源码全调）：
 *                          ①absorbed 后（ContinueAdjacentPiece :183）②pieceDownloadFailed（:231）
 *                          ③pieceDownloadFinished 标记后（:252）④全完成拼装前双写（:255）
 *                          ⑤数据流 2000ms 独立游标门 lastStateSavedAt（:26 初始化/:281-284 先存后置，
 *                          挂 onProgressMsg/onWorkerResult 两处字节账本更新点、emitProgressIfDue 之前
 *                          ——绝不可塞进 500ms 进度门内，其早退会跳过保存，§0-7）
 *                          ⑥createPiece 末尾（:326）⑦splitPiece 后（:457 内嵌保存移至调用点 D3，
 *                          与 ⑥ 构成分裂轮双写）⑧probeConnected 探测落位后（SingleSource:275）
 *   RestoreState 恢复桥 ← U2.2（resume() pieces 空→stateStore.readChunks 注入 pieces/totalSize/
 *                          fileSize/splittingAllowed 四量；null/空→既有 start 全新下载；绝不抛）；
 *                          恢复路径补 mkdirSync（Resume :119，D7）；start() 先 clear() 残留状态文件（D4）；
 *                          同实例预探测窗口（pieces 非空+init=false）先探盘：盘空→全新 start（R1-F1——
 *                          防预探测 {length=-1} 片被锚②持久化后记录永久钉死 NonResumable）
 * 有意差异：D3 探测连接取头即 abort（下半区由 createPiece 内取消-重派逻辑补派）；D4 非 resumable/
 *  未知大小整流模式（splittingAllowed=false 使 findMaxChunk 恒 null）；D6 ContinueAdjacentPiece 保留
 *  完成路径原位调用（闭区间窗口数学上不可满足成功条件，运行时恒 false 的 parity）；D10 stop 单入口，
 *  onPaused 携带 Σdownloaded；D12 首请求分类 per-attempt；D15 "8 段并行"=8 个 Task 同时在途。
 * 日志：hilog domain 0x0000 tag 'PieceScheduler'（业务通道，绝不 [XDM_PROBE]）。
 */

import { util, taskpool } from '@kit.ArkTS';
import { fileIo, statfs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  EnginePiece,
  PieceSnapshot,
  RestoredPieces,
  SEG_NOT_STARTED,
  SEG_FINISHED,
  createInitialPiece,
  findMaxChunk,
  splitPiece,
  continueAdjacentPiece,
  allFinished,
  getInactiveChunkCount,
  getInactivePiece,
  sortPiecesByOffset,
  windowOf,
  totalDownloadedOf
} from './PieceAlgo';
import {
  segmentWorkerTask,
  WorkerParams,
  WorkerConnectedMsg,
  WorkerProgressMsg,
  WorkerResult,
  ThrottleStats
} from './SegmentWorker';
import { perWorkerLimitKBps } from './SpeedLimiter';
import {
  EngineError,
  ERR_GENERIC,
  ERR_NON_RESUMABLE,
  ERR_MAX_RETRY,
  ERR_INVALID_RESPONSE,
  ERR_DISK_ERROR,
  instantSpeedBps,
  avgSpeedBps,
  etaSeconds,
  shouldEmitProgress,
  exceedsMaxRetry
} from './EngineMath';
import {
  isSuccessStatus,
  parseContentRange,
  closedRangeHeader,
  ContentRangeParts
} from '../net/HttpProtocol';
import { composeDownloadHeaders } from '../../model/DownloadRequestContext';
import { parseHttpDate, resolveProxy } from '../net/TransportPolicy';
import { DownloadRunRequest } from '../../model/DownloadRunRequest';
import { resolveRunRequest } from './DownloadRequestState';
import { getUniqueFileName } from '../util/FileNames';
import { computeProgress, joinTempDir } from '../db/RecordMapping';
import { StateStore } from '../db/StateStore';
import { Config } from '../Config';
import { DownloadEvents, NoopDownloadEvents } from './Downloader';
import { DownloadRecord } from '../../model/DownloadRecord';

/** 拼装缓冲 5MB（AssemblePieces :346 Rent(5*1024*1024) 同值锚；主线程文件常量，非 worker 可达） */
const ASSEMBLE_BUF_BYTES: number = 5 * 1024 * 1024;

/** 派发记录（grabber 等价物，PieceGrabber.cs:13-35 实例字段映射，设计书 §2.2）。
 * timesRetried 为 record 粒度（约束③：每次（重）派发新建 record 即归零，对齐 :24 字段初始化 +
 * CreatePiece/RetryFailedPieces 每次新建实例；连接期/EOF 重试经 inheritRetry 跨 record 继承）。 */
/** 置共享取消标志（worker 下一个分块/睡眠切片即退出，不再写盘） */
function signalCancel(rec: DispatchRecord): void {
  Atomics.store(rec.cancelView, 0, 1);
}

interface DispatchRecord {
  pieceId: string;
  task: taskpool.Task;
  /** 与 worker 共享的取消标志（Int32[0]=1；见 WorkerParams.cancelFlag） */
  cancelView: Int32Array;
  /** 与 worker 共享的已写字节数（Float64@8；pollSharedProgress 读取） */
  writtenView: Float64Array;
  /** 本次尝试派发时刻 piece.downloaded（窗口写起点相对值） */
  attemptBaseRel: number;
  /** 闭区间绝对字节窗口 [start,end]；开窗口 [0,-1]（CreateRequest :387-395） */
  windowStart: number;
  windowEnd: number;
  /** 开窗口=探测类请求 bytes=0-（接受 200/206，per-attempt 分类 D12） */
  openWindow: boolean;
  /** 探测尝试（取头即 abort 不写盘，§0-3/D3） */
  probeMode: boolean;
  timesRetried: number;
  /** 最近一次 progress 消息的相对字节（取消重派恢复点观测；恢复点=attemptBaseRel+lastReportedRel） */
  lastReportedRel: number;
  /** 停止/分裂取消/替换后置 false，消息/结果一律丢弃 */
  alive: boolean;
  /** 派发序号（单调）：execute then/catch 回执与 record 的陈旧匹配守卫 */
  attempt: number;
}

export class PieceScheduler {
  private readonly record: DownloadRecord;
  private readonly events: DownloadEvents;
  private readonly maxSegments: number;
  private readonly maxRetry: number;
  private readonly retryDelay: number;
  private readonly timeoutMs: number;
  /** 分片临时目录 = tempDir/<recordId>（对照 SingleSourceHTTPDownloader.cs:33） */
  private readonly tempDirPath: string;
  /** U2.2 分片状态持久化（chunks.json 双槽，tempDir 内随 deleteTempDir 自然清理） */
  private readonly stateStore: StateStore;
  /** 2000ms 状态保存游标（:26 构造时初始化；start/resume **不重置**——源码仅构造初始化，
   * 久停后恢复首笔数据即触发保存，保真；与 500ms 进度游标 lastProgressUpdatedAt 互不相干，§0-7） */
  private lastStateSavedAt: number = Date.now();

  /** 主线程单点状态（无锁，约束⑦） */
  private pieces: Map<string, EnginePiece> = new Map<string, EnginePiece>();
  private records: Map<string, DispatchRecord> = new Map<string, DispatchRecord>();
  /** 每分片最近 connected 消息 status（PieceSnapshot.lastStatus 观测原料） */
  private lastStatusById: Map<string, number> = new Map<string, number>();
  private init: boolean = false;
  private splittingAllowed: boolean = false;
  private fileSize: number = -1;
  private totalSize: number = -1;
  private generation: number = 0;
  private stopRequested: boolean = false;
  /** 2026-11-22：任一分片响应的 Last-Modified（设置「从服务器获取时间戳」在组装后写回 mtime） */
  private serverLastModified: string = '';
  private running: boolean = false;
  /** 共享进度轮询定时器（-1=未启动；见 pollSharedProgress） */
  private sharedPollTimer: number = -1;
  /** Fixed for one start/resume, including every retry and split. Refresh affects the next run. */
  private runRequest: DownloadRunRequest | undefined = undefined;
  private attemptSeq: number = 0;
  /** 进度游标（UpdateDownloadedBytesCount :287-298 数学，EngineMath 复用） */
  private ticksAtStartOrResume: number = 0;
  private lastProgressUpdatedAt: number = 0;
  private lastDownloadedAt: number = 0;
  private bytesSinceStartOrResume: number = 0;
  /** stop 门：sleep 与其 race 防 stop 挂起（U1.2 pauseGate 同款） */
  private pauseGate: Promise<void> = Promise.resolve();
  private pauseResolve: (() => void) | undefined = undefined;
  /** U3.2 throttle 观测累积（onWorkerResult 无条件累加，attempt 无关——D18 平台行为观测面，
   * 非计费口径；探针 P3-U2 经 Downloader.throttleStats 消费） */
  private throttleSleepCount: number = 0;
  private throttleSleepTotalMs: number = 0;
  private peakQueuedBytes: number = 0;
  private burstReopenCount: number = 0;

  constructor(record: DownloadRecord, events?: DownloadEvents) {
    this.record = record;
    this.events = events !== undefined ? events : new NoopDownloadEvents();
    this.maxSegments = Config.getInstance().getMaxSegments();
    this.maxRetry = Config.getInstance().getMaxRetry();
    this.retryDelay = Config.getInstance().getRetryDelay();
    this.timeoutMs = Config.getInstance().getNetworkTimeout() * 1000;
    this.tempDirPath = joinTempDir(Config.getInstance().getTempDir(), record.id);
    this.stateStore = new StateStore(this.tempDirPath);
  }

  // ---------- 门面（Downloader 透传；签名与 U1.2 兼容） ----------

  /** 全新下载（对照 Start :71-104：mkdir tempDir → 清残留状态文件（U2.2 D4）→ 初始片
   * {0,-1,0,NotStarted} → onStarted → 探测派发） */
  start(): void {
    if (this.running) {
      return;
    }
    this.running = true;
    this.stopRequested = false;
    this.generation++;
    this.init = false;
    this.splittingAllowed = false;
    this.fileSize = -1;
    this.totalSize = -1;
    this.pieces.clear();
    this.records.clear();
    this.lastStatusById.clear();
    this.rebuildGate();
    if (!this.captureRunRequest()) {
      return;
    }
    try {
      fileIo.mkdirSync(this.tempDirPath, true);
    } catch (e) {
      // 已存在容忍（Directory.CreateDirectory 幂等等价）
    }
    // U2.2 D4：清残留状态文件（源码 Start 仅 mkdir 不清 chunks.db，崩溃窗口 [Start, 首次保存] 内
    // 重启会恢复上一会话残留 pieces——跨会话分片集歧义；本引擎关闭该窗口。孤儿分片文件仍不清，
    // 源码同貌，deleteTempDir 兜底）
    this.stateStore.clear();
    const initialId: string = util.generateRandomUUID();
    this.pieces.set(initialId, createInitialPiece(initialId));
    this.bytesSinceStartOrResume = 0;
    this.ticksAtStartOrResume = Date.now();
    this.lastProgressUpdatedAt = this.ticksAtStartOrResume;
    this.lastDownloadedAt = 0;
    // :99 OnStarted 先于 :102 Download（首连接；R2-F1：先于连接，连接失败不影响 Started 语义）
    this.events.onStarted(this.record.id);
    // :94/:102 grabber+Download——初始片探测派发（openWindow+probeMode，bytes=0-）
    this.dispatchPiece(initialId, true, true, 0);
  }

  /** 续传（对照 Resume :111-151）：pieces 空 → 恢复桥 restoreState()（U2.2，:118）→ 仍空 → 全新
   * start（:139-143，含 SaveForLater 等价语义 D6）；全 Finished → 直接拼装（:124-130）；否则
   * init=true+CreatePiece（:135-137）。同实例 stop→resume 用内存 pieces 不重读盘（D5：内存态恒
   * ≥盘上态，前缀覆盖幂等）——唯一例外是预探测窗口（init=false）先探盘：盘空→全新 start
   * （R1-F1）；跨进程 resume 走 RestoreState 等价路径。 */
  resume(): void {
    if (this.running) {
      return;
    }
    if (this.pieces.size === 0) {
      // U2.2 恢复桥（对照 :118 RestoreState）：读盘注入四量；无状态保持空
      this.restoreState();
      if (this.pieces.size === 0) {
        // :139-143 无 pieces → Start()
        this.start();
        return;
      }
    } else if (!this.init) {
      // R1-F1（审查修复）：同实例 pieces 非空但探测未落位（init=false，如启动后连接挂起/重试窗口内
      // 点暂停再点继续）——D5"内存态恒≥盘上态"未覆盖盘空→Start 的预探测分支：径直走既有体会把
      // {length=-1} 初始片闭窗重派 → dispatchPiece NonResumable → pieceDownloadFailed 锚②把预探测
      // 片写进 chunks.json，此后会话内每次 resume 与跨进程 restoreState 都得到同一终态（记录永久
      // 钉死）。对照源码 Resume 恒走 RestoreState(:111-151)，而此窗口 chunks.db 尚不存在（Start
      // :76-104 直派 grabber.Download() 不经 CreatePiece、Stop :109-130 无保存——本会话逐行核实），
      // 盘空语义=:139-143 全新 Start 可恢复。故先以 readChunks() 探测盘上真实状态：null/空 →
      // start()（start() :205-206 自带 pieces/records 全量重置）；非 null（=源码 :231 已持久化
      // length=-1 片的探测失败态，源码同样钉死）→ 保持现路径。readChunks 绝不抛，双槽全败即 null。
      const diskState: RestoredPieces | null = this.stateStore.readChunks();
      if (diskState === null || diskState.pieces.size === 0) {
        this.start();
        return;
      }
    }
    // U2.2 D7：恢复路径补 mkdir（对照 :119 Directory.CreateDirectory(state.TempDir)——跨进程恢复
    // temp 被清时 worker openSync 无父目录直接 DiskError 的前置预防；幂等吞异常）
    try {
      fileIo.mkdirSync(this.tempDirPath, true);
    } catch (e) {
      // 已存在容忍
    }
    this.running = true;
    this.stopRequested = false;
    this.generation++;
    this.rebuildGate();
    if (!this.captureRunRequest()) {
      return;
    }
    this.bytesSinceStartOrResume = 0;
    this.ticksAtStartOrResume = Date.now();
    this.lastProgressUpdatedAt = this.ticksAtStartOrResume;
    // :515-526 TicksAndSizeAtResume：Σdownloaded 作为速度基线
    this.lastDownloadedAt = totalDownloadedOf(this.pieces);
    this.events.onStarted(this.record.id);
    if (allFinished(this.pieces)) {
      // :124-130 全完成直接拼装
      this.assemblePieces();
      return;
    }
    // :135-137：init=true（已知大小）+ CreatePiece
    this.init = true;
    this.createPiece();
  }

  /** 停止（对照 Stop :109-130 + D9/D10）：防重入 → 代际自增 → 逐 record cancel（不等待退出）→
   * records 清空（死 grabber 滞留 bug 不复刻）→ stop 门放行 → onPaused(Σdownloaded)。temp 保留供续传。 */
  stop(): void {
    if (this.stopRequested) {
      return;
    }
    this.stopRequested = true;
    this.generation++;
    this.records.forEach((rec: DispatchRecord) => {
      rec.alive = false;
      signalCancel(rec);
      try {
        taskpool.cancel(rec.task);
      } catch (e) {
        // 已完成/不存在吞（cancel :1732 语义）
      }
    });
    this.records.clear();
    const resolve = this.pauseResolve;
    if (resolve !== undefined) {
      resolve();
    }
    this.running = false;
    this.events.onPaused(this.record.id, totalDownloadedOf(this.pieces));
  }

  isRunning(): boolean {
    return this.running;
  }

  // ---------- 状态持久化（U2.2，SaveChunkState/RestoreState 文件面；全部绝不抛） ----------

  /** SaveChunkState 等价（SingleSourceHTTPDownloader.cs:153-165）：**pieces 空静默门**（:158——
   * start 前清态/失败收尾后不再写空集）+ 委托 StateStore（staging→双槽轮换，IO 细节全在 db 层）。 */
  private saveChunks(): void {
    if (this.pieces.size === 0) {
      return;
    }
    this.stateStore.saveChunks(this.pieces, this.totalSize);
  }

  /** 数据流 2000ms 状态门（UpdateDownloadedBytesCount :281-284 逐序：**先 saveChunks 后置游标**；
   * 游标只增不重置——start/resume 均不动它）。只挂 onProgressMsg/onWorkerResult 两处字节账本
   * 更新点（piece.downloaded 赋值后、emitProgressIfDue 之前）——独立于 500ms 进度门（§0-7：
   * 进度门早退会跳过保存判定，两游标永不复用）。 */
  private saveChunksIfDue(): void {
    const ticks: number = Date.now();
    if (ticks - this.lastStateSavedAt > 2000) {
      this.saveChunks();
      this.lastStateSavedAt = ticks;
    }
  }

  /** 恢复桥（RestoreState :174-221 等价，只注入四量——请求构造/206 三检/lseek 覆盖写/拼接收尾
   * 全部复用既有代码零重写）：双槽读回 pieces Map + totalSize；fileSize/splittingAllowed 按
   * totalSize>0 推导（恢复集仅来自已探测会话；totalSize<=0 预探测/未知大小禁分裂，:169-170 闭窗口
   * 派发未知大小走 NonResumable 终态=源码同貌边界）。readChunks 双槽全败/结构门失败 → null →
   * pieces 保持空（对照 :214-219 读败吞→空，:139-143 退化为全新 start）。**绝不抛**。 */
  private restoreState(): void {
    try {
      const restored: RestoredPieces | null = this.stateStore.readChunks();
      if (restored === null || restored.pieces.size === 0) {
        return;
      }
      this.pieces = restored.pieces;
      this.totalSize = restored.totalSize;
      this.fileSize = restored.totalSize > 0 ? restored.totalSize : -1;
      this.splittingAllowed = restored.totalSize > 0;
    } catch (e) {
      // 吞：双槽读败=无状态（readChunks 自身不抛，此为防御外层）
    }
  }

  // ---------- 探针观测面（非事件面，Downloader 透传；P2-U1 消费） ----------

  /** 单行分片概览（ProbeKit 值白名单 [A-Za-z0-9_.:/|= -] 内）：
   * n=<片数> a=<在途数>/<id8>.<offset>.<length>.<downloaded>.<state>.<lastStatus> 片间 '/'。 */
  describePieces(): string {
    let line: string = 'n=' + String(this.pieces.size) + ' a=' + String(this.records.size);
    this.pieces.forEach((piece: EnginePiece, pid: string) => {
      const status: number = this.lastStatusById.get(pid) ?? 0;
      line += '/' + pid.slice(0, 8) + '.' + String(piece.offset) + '.' + String(piece.length) +
        '.' + String(piece.downloaded) + '.' + String(piece.state) + '.' + String(status);
    });
    return line;
  }

  /** 分片快照（设计书 §2.4；区间不重叠/覆盖观测原料） */
  getPieceSnapshots(): PieceSnapshot[] {
    const snaps: PieceSnapshot[] = [];
    this.pieces.forEach((piece: EnginePiece, pid: string) => {
      const rec = this.records.get(pid);
      const snap: PieceSnapshot = {
        id: pid,
        offset: piece.offset,
        length: piece.length,
        downloaded: piece.downloaded,
        state: piece.state,
        inflight: rec !== undefined,
        lastStatus: this.lastStatusById.get(pid) ?? 0,
        windowStart: rec !== undefined ? rec.windowStart : -1,
        windowEnd: rec !== undefined ? rec.windowEnd : -1
      };
      snaps.push(snap);
    });
    return snaps;
  }

  /** 在途分段数（"8 段并行"观测口径，D15：Task 同时在途数，OS 线程数系统调度） */
  activeSegmentCount(): number {
    return this.records.size;
  }

  /** throttle 观测聚合（Downloader 透传；探针 P3-U2 消费——D18 平台行为观测面；
   * peakQueuedBytes 取跨 attempt 峰值，计数类跨 attempt 累加） */
  throttleStats(): ThrottleStats {
    const stats: ThrottleStats = new ThrottleStats();
    stats.throttleSleepCount = this.throttleSleepCount;
    stats.throttleSleepTotalMs = this.throttleSleepTotalMs;
    stats.peakQueuedBytes = this.peakQueuedBytes;
    stats.burstReopenCount = this.burstReopenCount;
    return stats;
  }

  // ---------- 派发（唯一 Task 组装点） ----------

  private captureRunRequest(): boolean {
    try {
      this.runRequest = resolveRunRequest(this.record);
      return true;
    } catch (e) {
      this.runRequest = undefined;
      this.rejectRunRequest();
      return false;
    }
  }

  private rejectRunRequest(): void {
    this.stopRequested = true;
    this.generation++;
    this.cancelAllRecords();
    this.saveChunks();
    const resolve = this.pauseResolve;
    if (resolve !== undefined) {
      resolve();
    }
    this.failDownload(ERR_GENERIC, 'Invalid download request context');
  }

  /** 派发一次 worker 尝试：窗口组装+头合成+Task 构造+record 先入 Map 再 execute+回执挂接。
   * inheritRetry>0 = 预算继承重派（连接期/EOF 重试）；0 = 全新 record（预算归零，约束③）。
   * 既有 record 的替换（探测收尾/分裂取消/预算重派统一入口）：cancel 旧 task + 删旧 record——
   * 不等待 worker 退出（三支柱推论），新窗口自 piece.downloaded（=max(attemptBaseRel,lastReportedRel)
   * 的同步不变量等价，前缀覆盖恢复点）。 */
  private dispatchPiece(pieceId: string, openWindow: boolean, probeMode: boolean,
    inheritRetry: number): void {
    if (this.stopRequested) {
      return;   // :312 cancelFlag 守卫
    }
    const piece = this.pieces.get(pieceId);
    if (piece === undefined) {
      return;
    }
    const old = this.records.get(pieceId);
    if (old !== undefined) {
      this.cancelRecord(old);
    }
    // :169-170 逐行：闭窗口派发未知大小 → NonResumable 终态（U1.2 D21 不可达分支在此可达化；
    // 开窗口未知大小（整流模式首派/重派）不触发）
    if (!openWindow && piece.length <= 0) {
      this.pieceDownloadFailed(pieceId, ERR_NON_RESUMABLE, 'Resume not supported');
      return;
    }
    // 防御：闭窗口已写满（getInactivePiece 排除项保证不发生）→ 直接收尾
    if (!openWindow && piece.length > 0 && piece.downloaded >= piece.length) {
      this.pieceDownloadFinished(pieceId);
      return;
    }
    let windowStart: number = 0;
    let windowEnd: number = -1;
    if (!openWindow) {
      const win: number[] = windowOf(piece);
      windowStart = win[0];
      windowEnd = win[1];
    }
    const request: DownloadRunRequest | undefined = this.runRequest;
    if (request === undefined) {
      this.rejectRunRequest();
      return;
    }
    const url: string = request.url;
    // Range 纪律（§3.3）：开窗口 'bytes=0-'（AddRange(0) :389）；闭窗口闭区间（AddRange(start,end)
    // :393-394 → DotNetHttpSession.cs:46-52；约束⑤：U1.2 D19 open-ended 简化弃用）
    const range: string = openWindow ? 'bytes=0-' : closedRangeHeader(windowStart, windowEnd);
    let headers: Record<string, string>;
    try {
      headers = composeDownloadHeaders(url, request.context, range, this.record.authentication);
    } catch (e) {
      // Invalid credentials must terminate the session, not strand an admitted manager slot.
      // Do not include the context or exception message in logs.
      this.rejectRunRequest();
      return;
    }
    // U3.2 限速份额换算（GetGlobalSpeedLimit :33-44 双门逐字——EnableSpeedLimit &&
    // DefaltDownloadSpeed>0 才取限值，否则 0=不限速；lock(Config.Instance) 不复刻——主线程单点
    // D1 先例）+ perWorkerLimitKBps 均摊（D1）；share 派发时读、attempt 期间冻结（D2——源 3s
    // 缓存重读机制随 worker 禁 Config 纪律消亡，变更下次派发生效）。探测派发 share 传 0——
    // 取头即 abort 不涉限速（SegmentWorker throttleEnabled 门）。
    const globalKBps: number = Config.getInstance().getEnableSpeedLimit() &&
      Config.getInstance().getDefaultDownloadSpeed() > 0
      ? Config.getInstance().getDefaultDownloadSpeed()
      : 0;
    const shareKBps: number = perWorkerLimitKBps(globalKBps, this.maxSegments);
    const attempt: number = ++this.attemptSeq;
    const cancelFlag: SharedArrayBuffer = new SharedArrayBuffer(16);
    const params: WorkerParams = {
      pieceId: pieceId,
      url: url,
      start: windowStart,
      end: windowEnd,
      openWindow: openWindow,
      pieceFilePath: this.tempDirPath + '/' + pieceId,
      writeStartOffset: piece.downloaded,
      timeoutMs: this.timeoutMs,
      probeMode: probeMode,
      attempt: attempt,
      cancelFlag: cancelFlag,
      headers: headers,
      proxy: resolveProxy(this.record.proxy),
      speedLimitKBps: shareKBps
    };
    const task: taskpool.Task = new taskpool.Task(segmentWorkerTask, params);
    const rec: DispatchRecord = {
      pieceId: pieceId,
      task: task,
      cancelView: new Int32Array(cancelFlag, 0, 1),
      writtenView: new Float64Array(cancelFlag, 8, 1),
      attemptBaseRel: piece.downloaded,
      windowStart: windowStart,
      windowEnd: windowEnd,
      openWindow: openWindow,
      probeMode: probeMode,
      timesRetried: inheritRetry,
      lastReportedRel: 0,
      alive: true,
      attempt: attempt
    };
    // record 先入 Map 再 execute（消息可能先于 execute 返回到达——竞态安全，纪律②）；
    // onReceiveData 闭包捕获 rec 本体（设计 §5.6 原案，R2-F1）：onWorkerMessage 入口按本体比对
    // （rec.alive && records.get===rec）——被替换 record 的旧 worker 迟到消息（其 sendData 定时器
    // 不检查 isCanceled）一律静默丢弃，防止旧 written 落到新 attemptBaseRel 上虚增恢复点
    this.records.set(pieceId, rec);
    this.ensureSharedPollTimer();
    task.onReceiveData((value: Object) => {
      this.onWorkerMessage(rec, String(value));
    });
    taskpool.execute(task).then((out: Object) => {
      this.onWorkerResult(pieceId, attempt, String(out));
    }).catch((e: BusinessError) => {
      this.onWorkerExecuteRejected(pieceId, attempt, e);
    });
  }

  /** 取消单 record：alive=false + 删 Map（仅当仍是该 record）+ taskpool.cancel（吞）。 */
  private cancelRecord(rec: DispatchRecord): void {
    rec.alive = false;
    signalCancel(rec);
    const current = this.records.get(rec.pieceId);
    if (current === rec) {
      this.records.delete(rec.pieceId);
    }
    try {
      taskpool.cancel(rec.task);
    } catch (e) {
      // 已完成/不存在吞
    }
  }

  /** 全量取消（探测失败/盘检失败终态分支：原版 grabberDict 空 → OnFailed 链路）。 */
  private cancelAllRecords(): void {
    this.records.forEach((rec: DispatchRecord) => {
      rec.alive = false;
      signalCancel(rec);
      try {
        taskpool.cancel(rec.task);
      } catch (e) {
        // 吞
      }
    });
    this.records.clear();
  }

  /** 在途分片 id 集（grabberDict.Keys 等价；records 成员资格=活跃判定，研究 fact 2） */
  private activeIds(): Set<string> {
    const ids: Set<string> = new Set<string>();
    this.records.forEach((rec: DispatchRecord) => {
      ids.add(rec.pieceId);
    });
    return ids;
  }

  // ---------- 分裂调度（CreatePiece/RetryFailedPieces，:307-371 逐行） ----------

  /** 分裂派发（:307-332 逐行）：MAX_COUNT 门 → RetryFailedPieces 消耗预算 → FindMaxChunk/SplitPiece
   * → 分裂命中在途分片 cancel+立即重派下半区（§0-5/D5；探测 record 由 dispatchPiece 替换路径消化
   * =下半区补派，§0-3/D3）→ 派新上半片。保存锚⑦（:457 SplitPiece 内嵌保存移至调用点 D3）+锚⑥
   * （:326 末尾）双写。 */
  private createPiece(): void {
    if (this.stopRequested) {
      return;
    }
    // 分裂前先取各 worker 的实时写盘量（findMaxChunk 依据 piece.downloaded）
    this.pollSharedProgress();
    if (this.records.size === this.maxSegments) {
      return;   // :313
    }
    let rem: number = this.maxSegments - this.records.size;
    rem -= this.retryFailedPieces(rem);
    if (rem > 0 && !this.stopRequested) {
      // :318（splittingAllowed=false 恒 null——§0-4/D4 整流模式单点守卫）
      const maxId: string | null = findMaxChunk(this.pieces, this.splittingAllowed);
      const newId: string = util.generateRandomUUID();
      const createdId: string | null = splitPiece(this.pieces, maxId, newId);
      if (createdId !== null && !this.stopRequested) {
        // U2.2 锚⑦：分裂后保存（源码 :457 在 SplitPiece 算法函数内——纯函数层禁 IO，保存移至
        // 调用点 D3；与末尾锚⑥构成分裂轮双写，对齐源码 :457+:326 双保存）
        this.saveChunks();
        // §0-5：原片在途（含探测 record）→ cancel+立即重派下半区（不等待 worker 退出；原片保下半区
        // 且 downloaded 保留；重派起点=回报点前缀覆盖；timesRetried 因新 record 归零 D5）
        if (maxId !== null && this.records.has(maxId)) {
          this.dispatchPiece(maxId, false, false, 0);
        }
        // :322-323 新上半片
        this.dispatchPiece(createdId, false, false, 0);
      }
    }
    // U2.2 锚⑥：CreatePiece 末尾保存（原版 :326——:313 MAX_COUNT 早退在保存之前，同序保真）
    this.saveChunks();
  }

  /** 失败片重派（:351-371 逐行）：min(GetInactiveChunkCount, max) 轮，逐个 GetInactivePiece 派发；
   * 新 record=新预算（约束③）。 */
  private retryFailedPieces(max: number): number {
    let count: number = 0;
    const inactiveCount: number = getInactiveChunkCount(this.pieces, this.activeIds());
    for (let n: number = Math.min(inactiveCount, max); n > 0; n--) {
      if (this.stopRequested) {
        break;
      }
      const chunkId: string | null = getInactivePiece(this.pieces, this.activeIds());
      if (chunkId === null) {
        break;
      }
      this.dispatchPiece(chunkId, false, false, 0);
      count++;
    }
    return count;
  }

  // ---------- worker 消息面（Task.sendData → onReceiveData，主线程单点消化） ----------

  private onWorkerMessage(rec: DispatchRecord, text: string): void {
    if (this.stopRequested) {
      return;
    }
    if (!rec.alive) {
      return;
    }
    if (this.records.get(rec.pieceId) !== rec) {
      // 探测互逆次序放行（独立复核 medium）：sendData 消息与 execute 结果分属两条回传通道，
      // SDK 不保证到达次序——probe result 先到已收尾删 record 时，迟到的探测 connected 仍须
      // 驱动调度，否则 init 恒 false、无后续派发，引擎 running=true 永久挂起。
      // 放行条件收紧到唯一情形：探测 record（alive 未被 cancel 置 false）+ init 未置位
      // （probeConnected 从未执行；正常序列 connected 先到时 init 已 true，此门天然只开一次）
      if (rec.probeMode && !this.init) {
        try {
          const lateObj: Object = JSON.parse(text);
          const lateMsg: WorkerConnectedMsg = lateObj as WorkerConnectedMsg;
          if (lateMsg.kind === 'connected') {
            this.probeConnected(rec.pieceId, lateMsg);
          }
        } catch (e) {
          // 畸形消息静默吞（结果面兜底）
        }
      }
      return;
    }
    try {
      const obj: Object = JSON.parse(text);
      const generic: WorkerProgressMsg = obj as WorkerProgressMsg;
      if (generic.kind === 'progress') {
        this.onProgressMsg(rec, generic);
        return;
      }
      if (generic.kind === 'connected') {
        const msg: WorkerConnectedMsg = obj as WorkerConnectedMsg;
        this.onConnectedMsg(rec, msg);
      }
    } catch (e) {
      // 畸形消息静默吞（结果面兜底）
    }
  }

  /** 共享进度轮询（2026-11-19）：把各在途 worker 的共享写盘计数并入 piece.downloaded——等价于
   * 源码 UpdateDownloadedBytesCount 的共享内存计数；sendData 进度消息仍保留（可用时二者取大）。 */
  private pollSharedProgress(): void {
    if (this.stopRequested) {
      return;
    }
    this.records.forEach((rec: DispatchRecord) => {
      if (!rec.alive || rec.probeMode) {
        return;
      }
      const w: number = rec.writtenView[0];
      if (w > rec.lastReportedRel) {
        const msg: WorkerProgressMsg = { kind: 'progress', pieceId: rec.pieceId, bytesWritten: w };
        this.onProgressMsg(rec, msg);
      }
    });
  }

  /** 运行期间每 250ms 轮询一次共享进度（驱动进度显示与状态保存）；停止/结束后自清 */
  private ensureSharedPollTimer(): void {
    if (this.sharedPollTimer >= 0) {
      return;
    }
    this.sharedPollTimer = setInterval((): void => {
      if (this.stopRequested || !this.running) {
        clearInterval(this.sharedPollTimer);
        this.sharedPollTimer = -1;
        return;
      }
      this.pollSharedProgress();
    }, 250);
  }

  /** progress 消息（原版 UpdateDownloadedBytesCount 共享内存计数的消息化，D2）：record 键控防串片
   * （onReceiveData 挂接在特定 task 上）→ piece.downloaded 终局一致 → 500ms 门进度发射。 */
  private onProgressMsg(record: DispatchRecord, msg: WorkerProgressMsg): void {
    const piece = this.pieces.get(record.pieceId);
    if (piece === undefined) {
      return;
    }
    // 消息与共享计数两路并存：只接受单调前进的值（迟到的较小 sendData 值不回退账本）
    if (msg.bytesWritten <= record.lastReportedRel) {
      return;
    }
    record.lastReportedRel = msg.bytesWritten;
    const abs: number = record.attemptBaseRel + msg.bytesWritten;
    const delta: number = abs - piece.downloaded;
    if (delta > 0) {
      this.bytesSinceStartOrResume += delta;
    }
    piece.downloaded = abs;
    // U2.2 锚⑤a：数据流 2000ms 状态门（:281-284——两处字节账本更新点之一；必须在
    // emitProgressIfDue 之前：500ms 进度门早退会跳过保存判定，§0-7）
    this.saveChunksIfDue();
    this.emitProgressIfDue();
  }

  /** connected 消息分派（双轴纪律：校验语义按 openWindow、探测值处理按 probeMode）。 */
  /** 2026-11-22：「从服务器获取时间戳」——成品 mtime 设为服务器 Last-Modified（缺失/无效则保持当前时间） */
  private applyServerTimestamp(path: string): void {
    if (!Config.getInstance().getFetchServerTimeStamp()) {
      return;
    }
    const ms: number = parseHttpDate(this.serverLastModified);
    if (ms <= 0) {
      return;
    }
    try {
      fileIo.utimes(path, ms);
    } catch (e) {
      // 吞：时间戳是附加信息，不影响下载结果
    }
  }

  private onConnectedMsg(record: DispatchRecord, msg: WorkerConnectedMsg): void {
    this.lastStatusById.set(record.pieceId, msg.status);
    if (typeof msg.lastModified === 'string' && msg.lastModified.length > 0) {
      this.serverLastModified = msg.lastModified;
    }
    // :181-188 compressed 防御主线程落位：206 视作 200（总长-1/禁续传在 probeConnected 推导吸收）
    let effectiveStatus: number = msg.status;
    if (msg.compressed && msg.status === 206) {
      effectiveStatus = 200;
    }
    if (record.probeMode) {
      this.probeConnected(record.pieceId, msg);
      return;
    }
    if (record.openWindow) {
      // 整流模式连接（D12：开窗口=探测类请求，200/206 均过）——禁止走 206 强检分支
      if (!isSuccessStatus(effectiveStatus)) {
        this.cancelRecord(record);
        this.pieceDownloadFailed(record.pieceId, ERR_INVALID_RESPONSE,
          'Invalid response: ' + String(msg.status));
        return;
      }
      // R2-F2：非探测连接携带 (status,-1,206观测,'')
      this.events.onConnected(this.record.id, msg.status, -1, effectiveStatus === 206, '');
      // :292 对齐（splittingAllowed=false 时 createPiece 无为而返）
      this.createPiece();
      return;
    }
    // 闭窗口三检（:194-202 + U1.2 D9 加固）
    if (effectiveStatus !== 206) {
      this.cancelRecord(record);
      this.pieceDownloadFailed(record.pieceId, ERR_INVALID_RESPONSE, 'Resume not supported');
      return;
    }
    const parts: ContentRangeParts = parseContentRange(msg.contentRange);
    if (this.fileSize > 0 && parts.total !== this.fileSize) {
      this.cancelRecord(record);
      this.pieceDownloadFailed(record.pieceId, ERR_INVALID_RESPONSE,
        'Content length mismatch total=' + String(parts.total));
      return;
    }
    if (parts.start !== record.windowStart) {
      this.cancelRecord(record);
      this.pieceDownloadFailed(record.pieceId, ERR_INVALID_RESPONSE,
        'Content-Range start mismatch start=' + String(parts.start) +
        ' expected=' + String(record.windowStart));
      return;
    }
    this.events.onConnected(this.record.id, msg.status, -1, effectiveStatus === 206, '');
    // :205→:292 每连接一次分裂驱动（分裂节奏由 connected 承载，§0-1）
    this.createPiece();
  }

  /** 探测处理器（PieceConnected(result!=null) :228-293）：isSuccessStatus 门 → 探测值落位 →
   * onConnected(探测值) → 盘检 → 分裂派发（resumable）或整流重派（非 resumable）。 */
  private probeConnected(pieceId: string, msg: WorkerConnectedMsg): void {
    if (!isSuccessStatus(msg.status)) {
      // §0-1 拍板（EnsureSuccessStatusCode 等价）：删探测 record → records 清空 →
      // onFailed(InvalidResponse)（原版外层 catch → PieceDownloadFailed → grabberDict 空 → OnFailed）
      this.cancelAllRecords();
      this.failDownload(ERR_INVALID_RESPONSE, 'Invalid response: ' + String(msg.status));
      return;
    }
    // 探测值落位（:238-244 + CreateProbeResult :440-447 推导链；U1.2 Downloader :347-352 同推导）：
    // compressed → total=-1（:181-188 防御经消息 compressed 旗标等价落位）
    let totalSize: number = -1;
    if (!msg.compressed) {
      totalSize = msg.contentLength > 0 ? msg.contentLength
        : parseContentRange(msg.contentRange).total;
    }
    const piece = this.pieces.get(pieceId);
    if (piece === undefined) {
      return;
    }
    piece.length = totalSize;
    piece.offset = 0;
    piece.downloaded = 0;
    piece.state = SEG_NOT_STARTED;
    this.init = true;
    this.totalSize = totalSize;
    this.fileSize = totalSize > 0 ? totalSize : -1;
    this.splittingAllowed = !msg.compressed && msg.status === 206 && totalSize > 0;
    // U2.2 锚⑧：探测值落位后保存（对照 PieceConnected :272-275 SaveState+SaveChunkState——SaveState
    // 对应物=downloads 表由 Index 写，引擎侧只落分片态；此后 chunks.json 携带 totalSize 恢复自足）
    this.saveChunks();
    const resumable: boolean = !msg.compressed && msg.status === 206;
    // 探测连接携带探测值（约束①签名不变；totalSize>0 守卫由消费方 no-op 保持既有 size）
    this.events.onConnected(this.record.id, msg.status, totalSize, resumable, msg.contentType);
    // 盘空间预检（§0-11 照译 :279-285：凡 ResourceSize>0 即查，与 resumable 无关；
    // statvfs 抛错吞 → 跳过检查，等价 GetFreeSpace 返 false 时源码不检查）
    if (totalSize > 0) {
      try {
        if (statfs.getFreeSizeSync(this.tempDirPath) < totalSize) {
          this.cancelAllRecords();
          this.failDownload(ERR_DISK_ERROR, 'insufficient disk space');
          return;
        }
      } catch (e) {
        // 吞：跳过检查
      }
    }
    // 文件名嗅探/OnProbed 不移植（§4-D3/D7 系）
    if (!this.splittingAllowed) {
      // §0-4/D4 整流模式：单 worker 以探测类请求（bytes=0-，接受 200/206）整流下载
      this.dispatchPiece(pieceId, true, false, 0);
    } else if (this.records.size >= this.maxSegments ||
      findMaxChunk(this.pieces, this.splittingAllowed) === null) {
      // COLD-F1 引擎热修（跨 U2.3 红线④经主会话授权，主会话单独提交；缺陷属 U2.1 既有代码，
      // 归属提交 08cfc8a 未触及本文件）：可续传小文件（totalSize≤SPLIT_THRESHOLD=262144）或
      // maxSegments 满载时 createPiece 本轮零派发——:536 满载早退，或 findMaxChunk 严格 `>`
      // （PieceAlgo.ets:117，HB.cs:422 逐字保真）对小片无候选 → splitPiece(null)→null。此时
      // 探测 record 仍占位且随后被 onWorkerResult probe 分支（:800-803）静默删除，records 空、
      // 无定时器、无其他驱动（Downloader 门面无 watchdog）→ running=true 永挂，onFinished/
      // onFailed 永不触发。挂起链证据：本文件 :725/:752 + PieceAlgo.ets:117 +
      // SegmentWorker.ets:236-238（probe 取头即 abort）。原版不挂：探测连接继续流式下载
      // （PieceGrabber.cs:87 Download(response)→CopyWithFixedLength）。兜底=对探测片直派闭窗
      // 窗口：dispatchPiece 自替换同片 record（cancel 探测 record+新建闭窗 record，size 仍
      // ≤maxSegments）；piece.length=totalSize>0 保证 :431 NonResumable 守卫通过、:438 已写满
      // 防御不触发（downloaded=0<length）；单片路径经 pieceDownloadFinished→allFinished→
      // assemblePieces 收敛——与 onWorkerMessage 探测互逆次序守卫（:591-600）同族的挂起防线。
      this.dispatchPiece(pieceId, false, false, 0);
    } else {
      // :292 CreatePiece：分裂派上半区；下半区由 createPiece 的取消-重派逻辑补派（原片的探测
      // record 被替换为闭窗口常规派发，§0-3/D3：+1 次握手、零重复字节）
      this.createPiece();
    }
  }

  // ---------- worker 结果面（execute Promise then/catch 回执） ----------

  private onWorkerResult(pieceId: string, attempt: number, text: string): void {
    if (this.stopRequested) {
      return;
    }
    const record = this.records.get(pieceId);
    if (record === undefined || !record.alive || record.attempt !== attempt) {
      return;
    }
    let result: WorkerResult;
    try {
      result = JSON.parse(text) as WorkerResult;
    } catch (e) {
      this.records.delete(pieceId);
      this.pieceDownloadFailed(pieceId, ERR_GENERIC, 'bad worker result');
      return;
    }
    // U3.2 throttle 观测累积（parse 成功后无条件累加，attempt 无关——陈旧/取消回执的观测值
    // 同样入账；D18 观测面非计费口径）
    this.throttleSleepCount += result.throttleSleepCount;
    this.throttleSleepTotalMs += result.throttleSleepTotalMs;
    if (result.peakQueuedBytes > this.peakQueuedBytes) {
      this.peakQueuedBytes = result.peakQueuedBytes;
    }
    this.burstReopenCount += result.burstReopenCount;
    const piece = this.pieces.get(pieceId);
    if (piece === undefined) {
      this.records.delete(pieceId);
      return;
    }
    // DiskError 非重试终态最前（R3-F1，:296-299 IOException → NonRetriable(DiskError)）：worker
    // 开档/lseek 失败返回 phase='connect'（SegmentWorker 初始值）且 diskErrCode≠0——若 connect
    // 判定在前，此类终态盘错被误走 retryConnectPhase（10 次×10s 后 MAX_RETRY(4) 而非立即
    // DiskError(8)）；C# 语义盘错从不进入重试环。探测尝试不写盘（diskErrCode 恒 0），前置不
    // 影响 R2-F2 的探测 connect 重试语义
    if (result.diskErrCode !== 0) {
      this.records.delete(pieceId);
      this.pieceDownloadFailed(pieceId, ERR_DISK_ERROR,
        'Disk error code=' + String(result.diskErrCode));
      return;
    }
    // 连接期失败（status=0 传输异常）先行（R2-F2）：**探测尝试同样走重试**（retryConnectPhase 已
    // 保持 probeMode/openWindow 逻辑），对照 PieceGrabber.cs:107-124 连接期失败吞异常后
    // timesRetried++/sleep(RetryDelay×1000) 重试、超限 OnFailed(MaxRetryFailed)——若探测 connect
    // 失败被静默吞（connected 消息从未到达、无任何后续调度），引擎 running=true 永久挂起
    if (result.phase === 'connect') {
      this.retryConnectPhase(record, result.errCode);
      return;
    }
    // 探测收尾（body 期，取头即 abort 即回）：静默删 record（connected 消息已驱动调度；消息与
    // 结果到达次序互逆均安全——attempt 守卫拦截替换后的陈旧探测结果）
    if (result.probe) {
      this.records.delete(pieceId);
      return;
    }
    // 账本终值（progress 降级时的唯一更新点；record 键控）
    const abs: number = record.attemptBaseRel + result.bytesWritten;
    const delta: number = abs - piece.downloaded;
    if (delta > 0) {
      this.bytesSinceStartOrResume += delta;
    }
    piece.downloaded = abs;
    // U2.2 锚⑤b：数据流 2000ms 状态门（:281-284——两处字节账本更新点之二，progress 降级时的
    // 唯一保存点；emitProgressIfDue 之前，§0-7）
    this.saveChunksIfDue();
    // 降级承诺落地（R2-F3，§0-2/§8'降级为完成时一次性回报'）：worker sendData 定时器被平台拒绝
    // （10200023/24 reportDisabled）后 onProgress 全靠此处补发——结果面天然在主 body 回调外，
    // 500ms 门自然节流；否则 UI 进度停摆且探针 S5 暂停谓词（依赖 onProgress）拖满超时
    this.emitProgressIfDue();
    // body 期分类（§3.5 表）
    if (result.windowLen >= 0) {
      // 闭窗口
      if (result.bytesWritten >= result.windowLen) {
        // 窗口完成：ContinueAdjacentPiece 原位调用（:271-283 parity；闭区间窗口数学上不可满足
        // 成功条件——D6 运行时恒 false，算法本体由 U2.3 用例锁定）
        const absorbed: boolean = continueAdjacentPiece(this.pieces, pieceId, record.windowEnd + 1);
        if (absorbed) {
          // U2.2 锚①：吸收后保存（对照 ContinueAdjacentPiece :183——D6 运行时恒 false 的 parity
          // 调用点，算法本体由 U2.3 用例锁定）
          this.saveChunks();
          // D6 数学不可达的保真分支（原版吸收后续用同连接读 → 本引擎重派扩窗原片+分裂驱动）
          this.dispatchPiece(pieceId, false, false, 0);
          this.createPiece();
          return;
        }
        this.pieceDownloadFinished(pieceId);
        return;
      }
      // Unexpected EOF（:284-290 DownloadException(Generic) 被吞重试）：立即重派（不 sleep）
      this.retryImmediately(record);
      return;
    }
    // 开窗口（整流模式）：ended=true → dataEnd 即完整（CopyWithUnknownLength Read==0 → break →
    // OnComplete）；!ended（15s 空闲/取消观测）→ 立即重派（重派转闭窗口：length<=0 时由 dispatchPiece
    // 的 :169-170 分支终态 NonResumable）
    if (result.ended) {
      this.pieceDownloadFinished(pieceId);
      return;
    }
    this.retryImmediately(record);
  }

  /** execute reject（d.ts:1721 catch 分支）：cancel 路径已被 record 删除/替换守卫拦截；
   * 未拦截=worker 异常退出 → 按连接期失败处理（§3.5 表尾行）。 */
  private onWorkerExecuteRejected(pieceId: string, attempt: number, err: BusinessError): void {
    if (this.stopRequested) {
      return;
    }
    const record = this.records.get(pieceId);
    if (record === undefined || !record.alive || record.attempt !== attempt) {
      return;
    }
    this.retryConnectPhase(record, err.code);
  }

  /** body 期失败立即重试（不 sleep）：先 ++ 后判（:113-117 原序）；窗口转闭区间（原版重试非首请求
   * AddRange(offset+downloaded, end)——开窗口未知大小重派由 dispatchPiece 的 :169-170 终态化）。 */
  private retryImmediately(record: DispatchRecord): void {
    record.timesRetried++;
    if (exceedsMaxRetry(record.timesRetried, this.maxRetry)) {
      this.pieceDownloadFailed(record.pieceId, ERR_MAX_RETRY, 'Max retry exceeded');
      return;
    }
    hilog.info(0x0000, 'PieceScheduler', '%{public}s',
      'retry body piece=' + record.pieceId.slice(0, 8) + ' n=' + String(record.timesRetried));
    this.dispatchPiece(record.pieceId, false, false, record.timesRetried);
  }

  /** 连接期失败：先 ++ 后判 → sleep(RetryDelay×1000) 与 stop 门 race（:118-124 + :449-452）→
   * 同预算重派（窗口/探测分类保持——探测重试仍是探测，init 未置时对齐 IsFirstRequest=true）。 */
  private retryConnectPhase(record: DispatchRecord, errCode: number): void {
    record.timesRetried++;
    if (exceedsMaxRetry(record.timesRetried, this.maxRetry)) {
      this.pieceDownloadFailed(record.pieceId, ERR_MAX_RETRY, 'Max retry exceeded');
      return;
    }
    hilog.info(0x0000, 'PieceScheduler', '%{public}s',
      'retry connect piece=' + record.pieceId.slice(0, 8) + ' n=' + String(record.timesRetried) +
        ' errCode=' + String(errCode));
    const pieceId: string = record.pieceId;
    const openWindow: boolean = record.openWindow;
    const probeMode: boolean = record.probeMode;
    const timesRetried: number = record.timesRetried;
    const gen: number = this.generation;
    this.retryAfterDelay(pieceId, openWindow, probeMode, timesRetried, gen);
  }

  private async retryAfterDelay(pieceId: string, openWindow: boolean, probeMode: boolean,
    timesRetried: number, gen: number): Promise<void> {
    await Promise.race([this.sleepMs(this.retryDelay * 1000), this.pauseGate]);
    if (this.stopRequested || gen !== this.generation) {
      return;
    }
    this.dispatchPiece(pieceId, openWindow, probeMode, timesRetried);
  }

  // ---------- 分片完成/失败（:224-266） ----------

  /** 分片完成（:243-266）：state=Finished → record 删除 → 全完成则 assemble+onFinished，
   * 否则 createPiece（:265 锁外）。保存锚③（:252）+锚④（:255 拼装前双写）。 */
  private pieceDownloadFinished(pieceId: string): void {
    if (this.stopRequested) {
      return;   // :246 cancelFlag 守卫
    }
    const piece = this.pieces.get(pieceId);
    if (piece === undefined) {
      return;
    }
    piece.state = SEG_FINISHED;
    this.records.delete(pieceId);
    // U2.2 锚③：标记后保存（原版 :252）
    this.saveChunks();
    if (allFinished(this.pieces)) {
      // U2.2 锚④：全完成拼装前**双写**（原版 :255——字节无变化也写，源码同貌；此后 deleteTempDir
      // 连带清理 chunks.json 工件三件套）
      this.saveChunks();
      this.assemblePieces();
      return;
    }
    this.createPiece();
  }

  /** 分片失败（:224-241）：record 删除（分片留 pieces 待 RetryFailedPieces 捡起）；
   * records 空 → onFailed（:232-235）。保存锚②（:231）。InvalidResponse+totalDownloaded>0→
   * SessionExpired(9) 映射不移植（D11/U1.2 D20）。 */
  private pieceDownloadFailed(pieceId: string, code: number, message: string): void {
    if (this.stopRequested) {
      return;   // :226 cancelFlag 守卫
    }
    const rec = this.records.get(pieceId);
    if (rec !== undefined) {
      this.cancelRecord(rec);
    }
    // U2.2 锚②：失败保存（原版 :231——分片留 pieces 待 RetryFailedPieces 捡起，状态须持久化）
    this.saveChunks();
    if (this.records.size === 0) {
      this.failDownload(code, message);
    }
  }

  private failDownload(code: number, message: string): void {
    this.running = false;
    hilog.error(0x0000, 'PieceScheduler', '%{public}s',
      'download failed code=' + String(code) + ' message=' + message);
    this.events.onFailed(this.record.id, code, message);
  }

  // ---------- 进度节流（UpdateDownloadedBytesCount :288-299，EngineMath 数学零改动） ----------

  private emitProgressIfDue(): void {
    const ticks: number = Date.now();
    const elapsed: number = ticks - this.ticksAtStartOrResume;
    if (!shouldEmitProgress(ticks, this.lastProgressUpdatedAt) || elapsed <= 0) {
      return;
    }
    const size: number = this.fileSize > 0 ? this.fileSize : this.totalSize;
    const downloaded: number = totalDownloadedOf(this.pieces);
    const instant: number = instantSpeedBps(downloaded - this.lastDownloadedAt,
      ticks - this.lastProgressUpdatedAt);
    const avg: number = avgSpeedBps(this.bytesSinceStartOrResume, elapsed);
    const progress: number = computeProgress(downloaded, size);
    const eta: number = etaSeconds(size, downloaded, avg);
    this.lastProgressUpdatedAt = ticks;
    this.lastDownloadedAt = downloaded;
    this.events.onProgress(this.record.id, progress, instant, eta, downloaded);
  }

  // ---------- 多分片拼接收尾（SortAndValidatePieces+AssemblePieces :295-483，替代 U1.2 D10 单分片退化） ----------

  /** 排序+盘检+5MB 缓冲拼接+清 temp+onFinished。失败分类（D11 细化）：盘满/写盘 IO → DiskError
   * （:373-377/:396-400 AssembleFailedException(DiskError) 链路）；EOF 早尽 → Generic
   * （:386-391 裸 Exception → :473-477 扁平化）。AssembingProgressChanged 不移植（D7，毫秒级）。 */
  private assemblePieces(): void {
    const sorted: EnginePiece[] = sortPiecesByOffset(this.pieces);
    if (this.stopRequested) {
      return;
    }
    const targetDir: string = this.record.targetDir !== null && this.record.targetDir.length > 0
      ? this.record.targetDir
      : Config.getInstance().getDownloadDir();
    try {
      fileIo.mkdirSync(targetDir, true);
    } catch (e) {
      // 已存在容忍
    }
    const baseName: string = this.record.name !== null && this.record.name.length > 0
      ? this.record.name
      : 'file';
    const existsFn = (p: string): boolean => {
      try {
        return fileIo.accessSync(p);
      } catch (e) {
        return false;
      }
    };
    // 2026-11-22：设置「覆盖已有文件」勾选时直接覆盖同名文件，否则自动改名（name(1).ext）
    const uniqueName: string = Config.getInstance().getFileConflictResolution() === 1
      ? baseName : getUniqueFileName(baseName, targetDir, existsFn);
    const finalPath: string = targetDir + '/' + uniqueName;
    const sizeKnown: number = this.fileSize > 0 ? this.fileSize : this.totalSize;
    // 盘空间预检（§0-11 照译 :318-325；statvfs 抛错吞 → 跳过检查）
    if (sizeKnown > 0) {
      try {
        if (statfs.getFreeSizeSync(targetDir) < sizeKnown) {
          this.failDownload(ERR_DISK_ERROR, 'assemble failed: insufficient disk space');
          return;
        }
      } catch (e) {
        // 吞：跳过检查
      }
    }
    let outFd: number = -1;
    let totalBytes: number = 0;
    try {
      const outFile = fileIo.openSync(finalPath,
        fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      outFd = outFile.fd;
      const buf: ArrayBuffer = new ArrayBuffer(ASSEMBLE_BUF_BYTES);
      for (let i = 0; i < sorted.length; i++) {
        if (this.stopRequested) {
          return;
        }
        const pc: EnginePiece = sorted[i];
        let inFd: number = -1;
        try {
          const inFile = fileIo.openSync(this.tempDirPath + '/' + pc.id, fileIo.OpenMode.READ_ONLY);
          inFd = inFile.fd;
          if (sizeKnown < 1) {
            // :360-380 未知大小分支：读到 EOF（CopyWithUnknownLength 语义）
            while (true) {
              if (this.stopRequested) {
                return;
              }
              const x: number = fileIo.readSync(inFd, buf);
              if (x === 0) {
                break;
              }
              fileIo.writeSync(outFd, buf, { length: x });
              totalBytes += x;
            }
          } else {
            // :383-406 已知大小分支：按 pc.length 精确拷贝（安全支柱③：取消残留陈旧尾部忽略；
            // :359 len=pc.Length 精确读）
            let len: number = pc.length;
            while (len > 0) {
              if (this.stopRequested) {
                return;
              }
              const want: number = Math.min(buf.byteLength, len);
              const x: number = fileIo.readSync(inFd, buf, { length: want });
              if (x === 0) {
                // :386-391 EOF 早尽 → 裸 Exception → Generic（D11 分类）
                throw new EngineError(ERR_GENERIC, false, 'EOF :: File corrupted');
              }
              fileIo.writeSync(outFd, buf, { length: x });
              len -= x;
              totalBytes += x;
            }
          }
        } finally {
          if (inFd >= 0) {
            try {
              fileIo.closeSync(inFd);
            } catch (e) {
              // 吞（逐片释放）
            }
          }
        }
      }
      if (this.stopRequested) {
        return;
      }
      fileIo.closeSync(outFd);
      outFd = -1;
      this.deleteTempDir();
      this.applyServerTimestamp(finalPath);
      let finalSize: number = totalBytes;
      try {
        finalSize = fileIo.statSync(finalPath).size;
      } catch (e) {
        finalSize = totalBytes;
      }
      this.running = false;
      this.events.onFinished(this.record.id, finalSize, finalPath);
      return;
    } catch (e) {
      if (outFd >= 0) {
        try {
          fileIo.closeSync(outFd);
        } catch (e2) {
          // 吞
        }
      }
      if (e instanceof EngineError) {
        const engineErr: EngineError = e as EngineError;
        this.failDownload(engineErr.code, engineErr.message);
        return;
      }
      const err = e as BusinessError;
      this.failDownload(ERR_DISK_ERROR,
        'assemble failed errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
    }
  }

  /** 清 temp（DeleteFileParts :544-555 try/catch 吞）：逐文件 unlinkSync + rmdirSync。 */
  private deleteTempDir(): void {
    try {
      const names: string[] = fileIo.listFileSync(this.tempDirPath);
      for (let i = 0; i < names.length; i++) {
        try {
          fileIo.unlinkSync(this.tempDirPath + '/' + names[i]);
        } catch (e) {
          // 吞（对照 DeleteFileParts）
        }
      }
      try {
        fileIo.rmdirSync(this.tempDirPath);
      } catch (e) {
        // 吞
      }
    } catch (e) {
      // listFileSync 失败吞（目录可能已被移空/删除）
    }
  }

  // ---------- 工具 ----------

  private rebuildGate(): void {
    const gate: Promise<void> = new Promise<void>((resolve: () => void) => {
      this.pauseResolve = resolve;
    });
    this.pauseGate = gate;
  }

  private sleepMs(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => resolve(), ms);
    });
  }
}
