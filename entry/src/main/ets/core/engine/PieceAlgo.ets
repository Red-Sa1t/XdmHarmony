/*
 * U2.1 分片算法纯函数层（设计书 §3.2/§5.2）：零 @kit import——Hypium/U2.3 本地单测可直接加载；
 * 调度器（PieceGrabber.ets）主线程单点持有 Map，本层只做数学，无 I/O 无状态。
 * U2.2 追加（设计书 §2.1/§5.1）：chunks JSON 序列化/反序列化纯函数（buildChunksJson/
 * parseChunksJson/RestoredPieces）——SaveChunkState/ReadChunkState 二进制字段序的 JSON 化对照物，
 * 同样零 @kit（IO 全部隔在 db 层 StateStore，本层只做纯文本往返）。
 * 对照源码锚（HTTPDownloaderBase.cs，行号逐字）：
 *   常量        ← SegmentState.cs:3-7 枚举序（NotStarted,Finished,Downloading,Failed）与
 *                 Piece.cs:34-37 StreamType（Primary,Secondary）；SPLIT_THRESHOLD=256*1024
 *                 （HTTPDownloaderBase.cs:422 FindMaxChunk `max > 256 * 1024` 与 :439 SplitPiece
 *                 `rem < 256 * 1024` 两处同值——**两个不同边界**：rem==262144 时 Find 不选、Split 允许，
 *                 逐字保留并由 U2.3 用例锁定，禁"顺手统一"）。
 *   findMaxChunk         ← :405-428：遍历全部 pieces，rem=Length-Downloaded 取最大者（`rem > max`
 *                          严格比较，并列保留 Map 插入序首个=C# Dictionary 实践序）；返回
 *                          `max > 262144 ? pid : null`。splittingAllowed=false 恒 null（§0-4 单点守卫，
 *                          非 resumable 整流模式禁分裂——原版无此参，其分裂片在整流路径被失败风暴
 *                          隐式收敛，D4 等价映射）。
 *   splitPiece           ← :430-466：chunkId null→null；rem<262144→null；len=rem/2（C# long 整除
 *                          截断 → Math.floor）；offset=chunk.Offset+chunk.Length-len；**原片保下半区**
 *                          chunk.Length-=len（Downloaded 保留）；新片取上半区 {offset,len,0,NotStarted,
 *                          newId,StreamType 同源}。id 由调用方传入（newId 三参形态）——纯函数层禁
 *                          @kit，util.generateRandomUUID 留在调度器侧。
 *   continueAdjacentPiece← :157-195：position=chunk.Offset+chunk.Length；找 Downloaded==0 &&
 *                          Offset==position && StreamType 同 → (Offset+Length)<=maxByteRange 时删邻片、
 *                          chunk.Length+=邻片.Length、true。邻片唯一（pieces 为不交覆盖，Offset==position
 *                          至多一片命中）。原版停邻片 grabber/删 grabberDict/CreatePiece/SaveChunkState
 *                          由调用方调度器承担；原版 cancelFlag 条件映射为调度器侧 stopRequested 守卫。
 *                          D6：闭区间窗口下成功条件数学上不可满足（邻片 Offset+Length>maxByteRange=窗口
 *                          末端+1 恒成立），原版唯一成功路径（探测连接 maxByteRange=文件全长）被 D3 取代
 *                          ——纯函数保真供 U2.3 用例表锁定，运行时恒 false 的 parity 调用。
 *   allFinished          ← :334-349：逐片 State==Finished 全真才 true；空 Map → true（C# 空循环语义）。
 *   getInactiveChunkCount← :373-385：计数条件 **缺** Downloaded==Length 排除项（:378-379 与 :394 的差异
 *                          是源码原貌，逐字保留不"顺手修复"，其轻微多计由 GetInactivePiece 返 null 兜底，
 *                          D16）。
 *   getInactivePiece     ← :387-403：首个满足 !(在途 || Finished || Downloaded==Length) 的分片 id。
 *   sortPiecesByOffset   ← SingleSourceHTTPDownloader.cs:295-303 SortAndValidatePieces 排序器
 *                          （offset 升序；diff==0 保序=稳定排序）。
 *   windowOf             ← :393-394 CreateRequest 闭窗口数学 [Offset+Downloaded, Offset+Length-1]；
 *                          开窗口 [0,-1] 仅探测/整流首派（由调度器直接构造，不经本函数）。
 *   totalDownloadedOf    ← :515-526 TicksAndSizeAtResume 同式：Σ Downloaded（按需重算，≤16 片开销
 *                          可忽略；值与原版增量累计 totalDownloadedBytes 一致）。
 *   createInitialPiece   ← SingleSourceHTTPDownloader.cs:84-92 Start 初始片 {0,-1,0,NotStarted}。
 * U2.3 追加（设计书 §5.2）：恢复偏移数学纯函数——READ_BUF_LEN（PG.cs:259）、maxByteRangeOf
 *   （:203-204，运行时调用点用 windowEnd+1 等价论证 D23 不接线）、isNonResumableResume
 *   （:169-170+调度器 :426-427 泛化形，D20）、cappedReadLen（:284-285，worker 运行时对应物=
 *   窗口余量封顶 SegmentWorker.ets:178-179 机制映射）——调度器/worker 内联形的逐字抽离，
 *   运行时调用点不切换（红线④）。
 * ArkTS 合规：禁解构/正则字面量/对象字面量（EnginePiece 经 new+逐字段赋值）；Map/Set 遍历统一
 * forEach（禁 for...in）；全部显式返回类型。
 */

/** SegmentState（SegmentState.cs:3-7 枚举序位锚，禁重排） */
export const SEG_NOT_STARTED: number = 0;
export const SEG_FINISHED: number = 1;
export const SEG_DOWNLOADING: number = 2;
export const SEG_FAILED: number = 3;

/** StreamType（Piece.cs:34-37；单源恒 PRIMARY，字段保真供 DualHttp 远期） */
export const STREAM_PRIMARY: number = 0;
export const STREAM_SECONDARY: number = 1;

/** 分裂阈值 256*1024（:422/:439 两处同值锚） */
export const SPLIT_THRESHOLD: number = 262144;

/** 分片模型（Piece.cs:6-37）：C# Interlocked 字段 → 普通字段——主线程单点管理后无并发写者（约束⑦）。
 * state 只赋 NOT_STARTED/FINISHED 两值（研究 fact 2：全 Progressive 代码从未赋 Downloading/Failed；
 * "活跃"以 records 成员资格判定，对齐 grabberDict 语义）。 */
export class EnginePiece {
  id: string = '';
  /** 文件绝对区间起点（闭区间下界） */
  offset: number = 0;
  /** -1=未知（仅探测前的初始片） */
  length: number = -1;
  /** 相对片首的已落盘字节数 */
  downloaded: number = 0;
  state: number = SEG_NOT_STARTED;
  streamType: number = STREAM_PRIMARY;
}

/** 分片快照（设计书 §2.4 探针观测面）：本文件单点定义，Downloader 产出、探针消费（禁再造同形接口）。
 * inflight=records 成员资格；lastStatus=最近 connected 消息 status；window*=最近派发窗口（区间不重叠
 * 观测原料，开窗口 [0,-1]）。 */
export interface PieceSnapshot {
  id: string;
  offset: number;
  length: number;
  downloaded: number;
  state: number;
  inflight: boolean;
  lastStatus: number;
  windowStart: number;
  windowEnd: number;
}

/** 初始探测片（SingleSourceHTTPDownloader.cs:84-92：{Offset=0,Length=-1,Downloaded=0,NotStarted}） */
export function createInitialPiece(id: string): EnginePiece {
  const piece: EnginePiece = new EnginePiece();
  piece.id = id;
  piece.offset = 0;
  piece.length = -1;
  piece.downloaded = 0;
  piece.state = SEG_NOT_STARTED;
  piece.streamType = STREAM_PRIMARY;
  return piece;
}

/** 最大剩余分片（:405-428 逐字）：rem=Length-Downloaded 取最大（`>` 严格，并列取 Map 插入序首个）；
 * 返回 `max > 262144 ? pid : null`。splittingAllowed=false 恒 null（§0-4/D4 整流模式守卫）。 */
export function findMaxChunk(pieces: Map<string, EnginePiece>, splittingAllowed: boolean): string | null {
  if (!splittingAllowed) {
    return null;
  }
  let max: number = -1;
  let pid: string | null = null;
  pieces.forEach((piece: EnginePiece, pieceId: string) => {
    const rem: number = piece.length - piece.downloaded;
    if (rem > max) {
      pid = pieceId;
      max = rem;
    }
  });
  return max > SPLIT_THRESHOLD ? pid : null;
}

/** 对半分裂（:430-466 逐字）：chunkId null→null；rem=Length-Downloaded；**rem < 262144 → null**
 * （与 findMaxChunk 的 `>` 是两个不同边界：rem==262144 时 Find 不选、Split 允许——逐字保留）；
 * len=rem/2 整除下取整（C# long 截断 → Math.floor）；新片取上半区 offset=Offset+Length-len；
 * **原片保下半区** Length-=len 且 Downloaded 保留；新片 Downloaded=0/NotStarted/StreamType 同源。 */
export function splitPiece(pieces: Map<string, EnginePiece>, chunkId: string | null,
  newId: string): string | null {
  if (chunkId === null) {
    return null;
  }
  const chunk = pieces.get(chunkId);
  if (chunk === undefined) {
    return null;
  }
  const rem: number = chunk.length - chunk.downloaded;
  if (rem < SPLIT_THRESHOLD) {
    return null;
  }
  const len: number = Math.floor(rem / 2);
  const offset: number = chunk.offset + chunk.length - len;
  chunk.length -= len;
  const newPiece: EnginePiece = new EnginePiece();
  newPiece.id = newId;
  newPiece.offset = offset;
  newPiece.length = len;
  newPiece.downloaded = 0;
  newPiece.state = SEG_NOT_STARTED;
  newPiece.streamType = chunk.streamType;
  pieces.set(newId, newPiece);
  return newId;
}

/** 相邻分片吸收（:157-195 逐字）：position=chunk.Offset+chunk.Length；邻片（Downloaded==0 &&
 * Offset==position && StreamType 同）满足 (Offset+Length)<=maxByteRange → 删除邻片、chunk.Length+=
 * 邻片.Length、返回 true。不满足或无邻片 → false（原版 :186 仅记日志继续循环——Map 不交覆盖下
 * Offset==position 至多一片命中，循环继续语义等价）。 */
export function continueAdjacentPiece(pieces: Map<string, EnginePiece>, pieceId: string,
  maxByteRange: number): boolean {
  const chunk = pieces.get(pieceId);
  if (chunk === undefined) {
    return false;
  }
  const position: number = chunk.offset + chunk.length;
  const keys: string[] = [];
  pieces.forEach((piece: EnginePiece, pid: string) => {
    keys.push(pid);
  });
  for (let i = 0; i < keys.length; i++) {
    const val = pieces.get(keys[i]);
    if (val === undefined) {
      continue;
    }
    if (val.downloaded === 0 && val.offset === position && val.streamType === chunk.streamType) {
      if (val.offset + val.length <= maxByteRange) {
        pieces.delete(keys[i]);
        chunk.length += val.length;
        return true;
      }
    }
  }
  return false;
}

/** 全部完成（:334-349 逐字）：逐片 State==Finished 全真才 true；空 Map → true。 */
export function allFinished(pieces: Map<string, EnginePiece>): boolean {
  let all: boolean = true;
  pieces.forEach((piece: EnginePiece) => {
    if (piece.state !== SEG_FINISHED) {
      all = false;
    }
  });
  return all;
}

/** 非活跃分片计数（:373-385 逐字）：条件 **缺** Downloaded==Length 排除项——:378-379 与 :394 的
 * 差异是源码原貌，逐字保留不修复（D16；多计由 getInactivePiece 返 null 兜底）。 */
export function getInactiveChunkCount(pieces: Map<string, EnginePiece>, activeIds: Set<string>): number {
  let count: number = 0;
  pieces.forEach((piece: EnginePiece, pid: string) => {
    if (!(activeIds.has(pid) || piece.state === SEG_FINISHED)) {
      count++;
    }
  });
  return count;
}

/** 首个非活跃分片（:387-403 逐字）：排除 在途(activeIds) / Finished / Downloaded==Length；无 → null。 */
export function getInactivePiece(pieces: Map<string, EnginePiece>, activeIds: Set<string>): string | null {
  let found: string | null = null;
  pieces.forEach((piece: EnginePiece, pid: string) => {
    if (found !== null) {
      return;
    }
    if (!(activeIds.has(pid) || piece.state === SEG_FINISHED || piece.downloaded === piece.length)) {
      found = pid;
    }
  });
  return found;
}

/** 按偏移升序（SingleSourceHTTPDownloader.cs:295-303 排序器；稳定排序，offset 相等保插入序） */
export function sortPiecesByOffset(pieces: Map<string, EnginePiece>): EnginePiece[] {
  const list: EnginePiece[] = [];
  pieces.forEach((piece: EnginePiece) => {
    list.push(piece);
  });
  list.sort((a: EnginePiece, b: EnginePiece): number => a.offset - b.offset);
  return list;
}

/** 闭窗口派发区间（:393-CreateRequest 数学）：[Offset+Downloaded, Offset+Length-1]。
 * length<=downloaded 不可派发（getInactivePiece 排除项保证不发生）；开窗口 [0,-1] 仅探测/整流首派。 */
export function windowOf(piece: EnginePiece): number[] {
  const window: number[] = [piece.offset + piece.downloaded, piece.offset + piece.length - 1];
  return window;
}

/** 已下载总量（:515-526 TicksAndSizeAtResume 同式）：Σ downloaded */
export function totalDownloadedOf(pieces: Map<string, EnginePiece>): number {
  let total: number = 0;
  pieces.forEach((piece: EnginePiece) => {
    total += piece.downloaded;
  });
  return total;
}

// ===================== U2.3 恢复偏移数学纯函数（设计书 §5.2） =====================
// 零 @kit 保持（Hypium 直接加载）；调度器/worker 内联形的逐字抽离，运行时调用点不切换（红线④）。

/** 源码读缓冲（PieceGrabber.cs:259 `BUF = new byte[32 * 1024]`；非 NET35 走 ArrayPool.Rent(32*1024)
 * 同值） */
export const READ_BUF_LEN: number = 32768;

/** maxByteRange（PieceGrabber.cs:203-204 逐字 `contentLength <= 0 ? -1 : piece.Offset + contentLength`）：
 * 连接成功后的本片可达上界（开区间右界）。运行时调用点 PieceGrabber.ets:824 用 `windowEnd+1`
 * （=Offset+Length）。**两形相等仅当连接时 Downloaded==0**：206 响应体 contentLength=窗口长度
 * （Length-Downloaded连接时；DotNetHttpSession.cs:32 CL 头缺失时回落 ContentRange total=文件全长），
 * Downloaded>0（窗口中断重派后续完成）时源形=Offset+Length-Downloaded 严格小于运行形。行为等价
 * 不依赖两形相等：pieces 不交覆盖下运行形恰=邻片 Offset、源形更小，吸收条件
 * (邻片O+邻片L)<=maxByteRange 要求邻片 L<=0 恒假——两形下吸收均不可达（D23 修正论证，COLD-F2）；
 * 源码例外：CL 头缺失回落全长时源形=Offset+fileSize 可越过邻片末端，原版闭窗吸收可达
 * （D6 有意差异完整边界，不复刻）。本函数按源码公式锁定供 U2.3 用例表。 */
export function maxByteRangeOf(pieceOffset: number, contentLength: number): number {
  return contentLength <= 0 ? -1 : pieceOffset + contentLength;
}

/** 恢复 NonResumable 终态判据（PieceGrabber.cs:169-170 `piece.Length == -1 &&
 * !IsFirstRequest` → NonRetriable(NonResumable,"Resume not supported")；调度器泛化形
 * PieceGrabber.ets:426-427 `!openWindow && piece.length <= 0`，D12 首请求≈开窗口）：闭窗口派发
 * （!openWindow）且片长未知/非正 → true。length==0 仅恢复畸形数据可达（正常片 length=-1 或 >0），
 * 泛化更防御；用例两形都锁（D20）。 */
export function isNonResumableResume(openWindow: boolean, pieceLength: number): boolean {
  return !openWindow && pieceLength <= 0;
}

/** 每轮读长封顶（PieceGrabber.cs:284-285 `sourceStream.Read(BUF, 0, (int)Math.Min(BUF.Length,
 * remaining))`）：域内 remaining>0（:270-279 先行分支消化——remaining<=0 走吸收/收尾不达本式）；
 * remaining<=0 → 0 为 ArkTS 防御守卫。worker 运行时对应物=窗口余量封顶
 * （SegmentWorker.ets:178-179 `remain=windowLen-written`）——机制映射而非同式，矩阵标"架构等价
 * +纯函数锁源码形"。 */
export function cappedReadLen(bufLen: number, remaining: number): number {
  if (remaining <= 0) {
    return 0;
  }
  return Math.min(bufLen, remaining);
}

// ===================== U2.2 chunks JSON 序列化/反序列化（设计书 §2.1/§5.1） =====================
// 零 @kit 保持（Hypium 直接加载）；IO 全部隔在 db 层 StateStore——本层只做纯文本往返。

/** chunks.json 文档版本号（决策 10：JSON 化新增，无需兼容原二进制；D1/D2 前向兼容锚） */
const CHUNKS_SCHEMA: number = 1;

/** 逐片文档（WriteChunkState :557-570 写序 JSON 化：源码 key 与 Id 同值=片 id，只落一份；
 * **字段序=源码写序 id→downloaded→length→offset→state→streamType，禁重排**——类字段声明序即
 * JSON.stringify 输出序，探针 savedLine/restoredLine diff 的稳定锚）。 */
class PieceDoc {
  id: string = '';
  downloaded: number = 0;
  length: number = -1;
  offset: number = 0;
  state: number = SEG_NOT_STARTED;
  streamType: number = STREAM_PRIMARY;
}

/** chunks.json 顶层文档（对照 :559 count → pieces.length；totalSize 为 D1 恢复自足冗余：
 * 探测值落位后的 totalSize，-1=未知大小/预探测——省恢复路径一次异步 DB 读） */
class ChunksDoc {
  schema: number = CHUNKS_SCHEMA;
  totalSize: number = -1;
  pieces: PieceDoc[] = [];
}

/** 读回结果（RestoreState :200-206 注入原料）：pieces 按数组序插入（恢复后遍历序=保存序），
 * totalSize 供调度器恢复桥注入 fileSize/splittingAllowed。 */
export class RestoredPieces {
  pieces: Map<string, EnginePiece> = new Map<string, EnginePiece>();
  totalSize: number = -1;
}

/** 序列化（WriteChunkState :557-570 等价）：Map.forEach 按插入序产出数组（源码 Dictionary
 * 遍历实践序等价，D16）；逐字段 new PieceDoc() 装配（ArkTS 禁 untyped 对象字面量）。 */
export function buildChunksJson(pieces: Map<string, EnginePiece>, totalSize: number): string {
  const doc: ChunksDoc = new ChunksDoc();
  doc.totalSize = totalSize;
  pieces.forEach((piece: EnginePiece) => {
    const pd: PieceDoc = new PieceDoc();
    pd.id = piece.id;
    pd.downloaded = piece.downloaded;
    pd.length = piece.length;
    pd.offset = piece.offset;
    pd.state = piece.state;
    pd.streamType = piece.streamType;
    doc.pieces.push(pd);
  });
  return JSON.stringify(doc);
}

/** 反序列化+结构校验（ReadChunkState :573-590 + TransactedIO END. 完整性门 :129-133 的 JSON
 * 等价，D2）：JSON.parse 成功 + 类型门全过才装配；任一违规 → null **绝不抛**（截断/畸形/类型错/
 * 缺字段/空 id/schema≠1 同收）。空 pieces 数组合法（空 Map 返回，调用方按无状态处理——对照
 * pieces.Count==0 全新 start 语义）。state 不校验 0..3 范围（源码 (SegmentState)r.ReadInt32()
 * int 直转同貌，D8；结构门只验有限 number）。逐片 new EnginePiece() 六字段赋值入 Map
 * （ArkTS 禁 untyped 对象字面量直投 Map，研究 fact 4）。 */
export function parseChunksJson(text: string): RestoredPieces | null {
  try {
    const parsed: Object | null = JSON.parse(text);
    if (parsed === null) {
      return null;
    }
    const doc: ChunksDoc = parsed as ChunksDoc;
    if (typeof doc.schema !== 'number' || doc.schema !== CHUNKS_SCHEMA) {
      return null;
    }
    if (!isFiniteNumber(doc.totalSize)) {
      return null;
    }
    if (!Array.isArray(doc.pieces)) {
      return null;
    }
    const restored: RestoredPieces = new RestoredPieces();
    restored.totalSize = doc.totalSize;
    for (let i = 0; i < doc.pieces.length; i++) {
      const item: PieceDoc = doc.pieces[i];
      if (typeof item.id !== 'string' || item.id.length === 0) {
        return null;
      }
      if (!isFiniteNumber(item.downloaded) || !isFiniteNumber(item.length) ||
        !isFiniteNumber(item.offset) || !isFiniteNumber(item.state) ||
        !isFiniteNumber(item.streamType)) {
        return null;
      }
      const piece: EnginePiece = new EnginePiece();
      piece.id = item.id;
      piece.downloaded = item.downloaded;
      piece.length = item.length;
      piece.offset = item.offset;
      piece.state = item.state;
      piece.streamType = item.streamType;
      restored.pieces.set(item.id, piece);
    }
    return restored;
  } catch (e) {
    return null;
  }
}

/** 有限数门：typeof 先行排除 undefined/string 等错型；NaN/±Infinity（如 1e999）→ false。 */
function isFiniteNumber(v: Object): boolean {
  return typeof v === 'number' && Number.isFinite(v);
}
