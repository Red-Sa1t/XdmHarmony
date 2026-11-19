# U2.1 PieceGrabber+SegmentWorker 并发 · 模块设计书

> 单元：U2.1（Phase 2 第 1 单元；探针单元 ID `P2-U1`，slug `u2-1-piecegrabber-segmentworker`）。
> 来源：xdm-migrate 工作流"模块设计师"角色，2026-09-28（配额中断后续跑定稿）。
> 依据：MIGRATION_PLAN §5 结构 / §6 决策 1（ArkTS 主线）+ 决策 2（线程模型重构）+ 决策 3（分段算法精确翻译）+ 决策 4（分片落盘，多文件拼接部分归本单元）；UNIT_CATALOG U2.1 行（验证 [A]+[P]）；PROBE_SPEC v1；U1.2 既有面（DownloadEvents/HttpClient/EngineMath/HttpProtocol/Config，U1.2 设计书 §1/§5 锚）；前轮单元指令七项补充约束（①事件面兼容 ②空闲超时语义 ③timesRetried 每分片粒度 ④局部 fd 纪律 ⑤闭区间 Range ⑥worker 传值+JSON ⑦主线程单点——本轮【补充约束】为空，七项沿用作设计决定）；源码研究结论（12 facts + 2 openQuestions）。
> 对照源码（本会话只读核实，未改 resourses/ 下任何文件）：`PieceGrabber.cs`（:62-140 主循环/:142-157 Stop/:159-217 Connect/:219-255 Download/:257-312 CopyWithFixedLength/:314-325 CloseUnfinishedRequest/:327-366 CopyWithUnknownLength/:368-397 CreateRequest/:436-447 CreateProbeResult/:449-452 sleep）、`HTTPDownloaderBase.cs`（:21-41 字段/:109-130 Stop/:157-195 ContinueAdjacentPiece/:197-222 GetPiece·GetPieceFile·GetSharedHttpClient/:224-241 PieceDownloadFailed/:243-266 PieceDownloadFinished/:268-305 UpdateDownloadedBytesCount/:307-332 CreatePiece/:334-349 AllFinished/:351-371 RetryFailedPieces/:373-385 GetInactiveChunkCount/:387-403 GetInactivePiece/:405-428 FindMaxChunk/:430-466 SplitPiece/:496-507 OnFailed/:544-555 DeleteFileParts/:557-618 chunks 二进制序列化）、`SingleSourceHTTPDownloader.cs`（:33/:71-104 Start/:111-151 Resume/:228-293 PieceConnected/:295-328 SortAndValidatePieces/:330-483 AssemblePieces/:508-517/:519-530）、`Piece.cs:6-37`、`SegmentState.cs:3-7`、`IPieceCallback.cs:11-25`、`ErrorCode.cs:9-14`、`Config.cs:100/102/120/122`、`DotNetHttpSession.cs:46-52 AddRange 闭区间`、`WebRequestExtensions.cs:160-177 bytes={0}-{1}`。
> API 核实（本机 SDK 6.1.1(24)，本会话执行 grep/sed 于 `D:\Tools\DevEco Studio\sdk\default\openharmony\ets\api\@ohos.taskpool.d.ts`）：`class Task` :189、`constructor(func, ...args)` :222-236、`static isCanceled(): boolean` :262（注释 :253 "must be used together with taskpool.cancel"）、`static sendData(...args: Object[]): void` :283（NOTE "Do not use this API in a callback function"）、`setTransferList` :302-336、`onReceiveData(callback?: Function): void` :343（"If multiple callbacks are registered for the same task, only the last registration takes effect"）、`execute(task: Task, priority?): Promise<Object>` :1428、`cancel(task)` :1732（:1721 "If the task is canceled…is returned in the catch branch"）。
> U1.2 既有资产消费（本会话读文件核实）：`Downloader.ets:45-52` DownloadEvents 六方法签名、`HttpClient.ets:25` END_GATE 空闲语义/:74-128 open/:131-138 waitStreamEnd/:152-178 abort、`HttpProtocol.ets:23-33 sixDefaultHeaders/:76-100 parseContentRange/:136-138 resumeRangeHeader`、`EngineMath.ets:26-30 错误码/:33-42 EngineError/:45-76 进度数学`、`Config.ets:27-41 五键`、`RecordMapping.ets:167-182 computeProgress·joinTempDir`、`FileNames.ets getUniqueFileName`、`module.json5:7-10 deviceTypes 含 2in1/:14-18 INTERNET 已具备`、`Index.ets:114-150 Downloader 消费面（start/resume/stop/isRunning+事件）`、`ProbeHttp.ets:63-103 fetchSegment @Concurrent 形态/:82 worker 内不可引用模块常量先例`、`ProbeDownloadLogic.ets expectedByteAt/spotOffsetAt 字节锚`、`docs/probe/P1-U2-download-server.js:7-12 路由（/big.bin /slow.bin?ms=40 /redirect /final）`。
> **本轮（续跑）复核声明**：单元 args 三空，按 NIGHT-RUN.md:15 在飞单元与 UNIT_CATALOG.md:48 定位 U2.1（研究 openQuestion 1 同口径）。前轮设计书全文保留为本版基底；本轮逐锚复核——源码侧 HTTPDownloaderBase.cs（全文 636 行）、PieceGrabber.cs（全文 472 行）、SingleSourceHTTPDownloader.cs（全文 540 行）、Piece.cs/SegmentState.cs/IPieceCallback.cs/ErrorCode.cs/Exceptions.cs/Config.cs:100-122 逐行读；ArkTS 侧 Downloader/EngineMath/HttpProtocol/HttpClient/Config/ProbeKit/ProbeIndex/ProbeDownload/ProbeDownloadLogic/ProbeHttp/Index/List.test/module.json5/main_pages/string.json/P1-U2-download-server.js 读文件核实；SDK d.ts 侧 taskpool（:189/:225/:253/:262/:267/:283/:333/:343/:1428/:1721/:1732）与 statvfs（getFreeSizeSync :167 since 10 / getFreeSize Promise :79 since 20）grep 核实。结论：前轮锚点全部成立，**一处事实错误**（盘空间预检"无对应物"——statvfs 有对应物，§0-11 修正移植）；另修正 §6-S2 分裂收敛数学（16 片非 8 片）与 §2.3 消息面补 compressed 字段。

## 0. 冲突与拍板注记（必读）

1. **openQuestion 1 拍板：worker 升级为 `taskpool.Task`+`sendData`/`onReceiveData` 消息模式（照单全收研究建议）。** 论证：原版分裂节奏由"每次连接成功"驱动（`PieceGrabber.cs:205` PieceConnected 每连接回调 → `SingleSourceHTTPDownloader.cs:292` PieceConnected 末尾无条件 `CreatePiece()`——每个新连接恰好触发一次分裂、净增一个 grabber，直到 MAX_COUNT）。一次性单发 worker 只在完成时回报，4MiB 源上首个 worker 会独立下完整个文件才触发第一次分裂——**8 并行验收点结构性不可达**。故派发必须走 `new taskpool.Task(segmentWorkerTask, params)` + `task.onReceiveData(cb)` + `taskpool.execute(task)`（裸函数 execute 无 Task 上下文，`sendData` 不可用——d.ts :283 NOTE "you must create a Task instance"）。单元约束⑥允许此升级：参数仍全传值、结果仍 JSON 串、worker 内仍禁 ProbeKit/单例/闭包捕获——升级的只是"回传通道数"（connected/progress 中途消息 + 最终 result）。消息语义对齐：connected 消息 = 原版 PieceConnected，progress 消息 = 原版 UpdateDownloadedBytesCount 的跨线程化。
2. **sendData 的 d.ts 限制（:283 NOTE "Do not use this API in a callback function"）的落点**：connected 消息在 worker 并发函数**主 body**（`await client.open()` resolve 后、非任何回调内）发送——完全合规；progress 消息只能由**定时器回调**（worker 内 `setInterval`，timer 在 taskpool worker 可用——ProbeHttp.ets:86 setTimeout 先例）发送，形式上处于回调内。处置：progress 发送包 try/catch，捕获 BusinessError（10200023/10200024 类）即置 `reportDisabled=true` + 清除定时器，**降级为完成时一次 性回报**（主线程字节账本退化为完成驱动，正确性不受影响——分裂节奏由 connected 驱动，与 progress 无关）。此风险进设计书 §8，编码员实测记录降级是否触发。
3. **openQuestion 2 拍板：接受探测连接"取头即 abort"偏差并登记 §4-D3。** 原版探测连接同一条流续写下半区+活体吸收（`PieceGrabber.cs:271-283`）；ArkTS worker 窗口按值传参不可变，活体缩短 Length 无通道可通知。探测 worker 取头→sendData(connected)→abort→返回（**0 字节落盘**），下半区由主线程作为普通闭区间尝试重派（probe-connected 处理器：reset piece → CreatePiece() 分裂派上半区 → **额外派发下半区**——原版下半区由探测连接本体覆盖，本引擎缺此覆盖必须显式补派，否则下半区成无 worker 死片）。代价：+1 次握手，零重复字节。
4. **openQuestion 3 拍板：接受"非 resumable 显式单 worker 模式"并登记 §4-D4。** 探测 resumable=false（非 206 或 compressed）或 totalSize<=0 → `splittingAllowed=false`，`findMaxChunk` 恒返 null（单点守卫），单 worker 以探测类请求（`bytes=0-`，接受 200/206）整流下载。终态与原版"分裂片 200→NonRetriable→Downloaded==0→被主流吸收→再分裂"的收敛循环等价（最终都是单连接整流），且避免失败风暴。连带推论（本会话对照 :157-195 核实）：**原版 ContinueAdjacentPiece 对闭区间连接在数学上不可能成功**——条件 `(val.Offset+val.Length)<=maxByteRange`，闭区间连接的 maxByteRange=窗口末端+1，相邻非空片恒 `>maxByteRange`（:186 日志分支），原版唯一成功路径是探测连接（maxByteRange=文件全长，:203-204）。本引擎探测连接已 abort（拍板 3），故吸收的运行时成功路径为空——`continueAdjacentPiece` 仍按原版逐字实现为纯函数并在完成路径原位调用（保真 + U2.3 用例表对象），其"不可达成功"作为 §4-D6 登记。
5. **分裂命中在途分片 → cancel+立即重派（本引擎核心映射决策）**。原版分裂从不取消 grabber：活体缩短 `chunk.Length-=len`（:445）+ grabber 每轮读活体 `piece.Length`（:270）+ 吸收续连接。本引擎窗口按值不可变，若不取消在途 worker，它会写满旧窗口 → 与新上半片区间重叠（探针"区间不重叠"观测直接违反）且 `Downloaded>Length` 破坏 GetInactivePiece 判定（:394）。映射：**cancel + 立即删 record + 立即重派下半区**（不等待 worker 退出）。安全性论证（设计书 §3.6 三支柱）：①worker 写盘按窗口定长封顶，永不越过旧窗口末端；②取消后 worker 协作检测 `isCanceled`（dataReceive 回调入口先查后写，worker 单线程回调体内原子）不再写盘；③重派起点=该 record 最近一次 progress 回报值（前缀覆盖），未回报的少量字节按相同源字节重写下覆盖，内容幂等；④陈旧尾部（超出收缩后 Length 的旧字节）留在分片文件中被按 Length 切片的拼装忽略（`AssemblePieces` :359 `len=pc.Length` 精确读）。偏差登记 §4-D5。
6. **"首请求"分类从 per-download 改为 per-attempt（拍板 3 的派生决策）**。原版 `IsFirstRequest=!init` 是 per-download 旗标（`SingleSourceHTTPDownloader.cs:223-226`）；本引擎探测连接 abort 后，非 resumable 整流重派若按 per-download 分类会被判"非首请求"→ 要求 206 → 服务器回 200 → 立即 InvalidResponse 终态 → **非 resumable 下载整体不可用**。故分类改为 per-attempt：开窗口尝试（探测、整流首派）= 探测类请求 `bytes=0-` 接受 200/206；闭窗口尝试（其余全部）= 206 强检。登记 §4-D12。
7. **DownloadEvents 事件面冻结（单元约束①）**：六方法签名一字不改（`Downloader.ets:45-52`），ForwardDownloadEvents/NoopDownloadEvents/Index.ets/ProbeDownload.ets 四消费方零改动。分片级观测走 Downloader 新增快照 getter（`describePieces(): string` / `getPieceSnapshots(): PieceSnapshot[]` / `activeSegmentCount(): number`），不给事件面加方法（研究 fact 8 同口径）。onConnected 逐连接触发：探测连接携带 (status,totalSize,resumable,contentType)，续传连接携带 (status,-1,206观测,'')——U1.2 R2-F2 已锁语义，本引擎多分片下同一语义仅在更多连接上重复触发。
8. **P1-U2 探针归档不受本次重构影响（诚实注记）**：探针是一次性验收工具（PROBE_SPEC §1 节奏），P1-U2 已 PASS 归档。U2.1 后若重跑 P1-U2，其 S5 `tempFileSize=names[0]`（单分片假设，ProbeDownload.ets:404-407）与 S6 `connectedCount>=2` 语义在多分片引擎下不再成立（temp 目录多文件、连接数远大于 2）——不构成回归，接棒观测面是 P2-U1。
9. **module.json5 / main_pages.json 不动（有据，非遗漏）**：本会话复核 `entry/src/main/module.json5`——deviceTypes=["phone","2in1"]（:7-10）、requestPermissions=[ohos.permission.INTERNET]（:14-18）已由 U0.1 落地；TaskPool 为进程内能力非权限门控，本单元无新增系统能力（后台长时任务/剪贴板/深链分属 U5.x）。main_pages.json 现仅 `pages/Index`+`probe/ProbeIndex`（U1.2 §0-3 同口径），P2-U1 探针页经 ProbeIndex 嵌入不注册路由。两文件均**不列入 files 清单**（无改动不产无意义 diff）。
10. **Config 补键是本单元唯一配置文件改动**：grep 证实 `Config.ets` 现仅五键（KEY_DOWNLOAD_DIR/TEMP_DIR/NETWORK_TIMEOUT/MAX_RETRY/RETRY_DELAY，:28-32），无 maxSegments；对照 `Config.cs:122 MaxSegments=8` 补第六键（getter/setter/preferences 持久化，模式与其余数值键完全同构）。
11. **【本轮修正】盘空间预检移植（推翻前轮 D7 的"无对应物"论断）**：前轮 D7 称 `Helpers.GetFreeSpace` 无鸿蒙对应物——本轮 grep 本机 SDK 证实 **`@ohos.file.statvfs` 有 `getFreeSizeSync(path): number`（statvfs.d.ts:167，@since 10）与 Promise 形态（:79，@since 20）**，且 `@kit.CoreFileKit` 以 `statfs` 名再导出（kit d.ts:30）。故照译两处源码检查：①probeConnected 探测值落位后 `getFreeSizeSync(tempDir) < totalSize` → 终态 onFailed(DiskError)（PieceConnected :279-285 `AssembleFailedException(DiskError)` 传播链：外层 catch → PieceDownloadFailed → grabberDict 空 → OnFailed）；②assemblePieces 输出文件开档前 `getFreeSizeSync(targetDir) < fileSize` → 拼装失败 onFailed(DiskError)（SortAndValidatePieces :318-325）。statvfs 可抛（13900002 等）——try/catch 吞掉跳过检查，等价 `Helpers.GetFreeSpace` 返 false 时源码不检查的语义。D7 相应删去该项。
12. **EngineMath 不补 ERR_ASSEMBLING_FAILED(3)/ERR_SESSION_EXPIRED(9)（对研究 fact 8 建议的裁定）**：本轮 grep 全源码证实 `ErrorCode.AssemblingFailed` 仅在 `ErrorMessages.cs:20`（UI 文案映射表）出现、引擎侧**从未构造**——补常量即死码，不补。`SessionExpired(9)` 映射（:496-501）确为源码真实行为，但 U1.2 D20 已拍板"U3.x 接错误文案时补映射"（U1.2 已提交代码无此映射，探针/DB 无该码消费方）——本单元沿用不移植（D11），U3.x 落地时在 EngineMath 补常量+PieceScheduler 出口处补一行映射即可，届时无返工面。
13. **单元边界拍板（研究 openQuestion 2，维持前轮）**：多分片 assemblePieces（排序+5MB 缓冲拼接+清 temp）划入 **U2.1**，与 UNIT_CATALOG.md:49 字面范围（"完成按 Offset 排序 5MB 缓冲拼接"列在 U2.2）**有意不一致**：MIGRATION_PLAN 决策 4 把"分片落盘+拼接"作为同构整体，且 U2.1 验收点"大文件吞吐显著优于 U1.2"+"成品文件字节抽查"要求 AllFinished 后必须产出成品文件，否则探针闭环不成立。U2.2 聚焦进度 JSON 持久化+杀进程重启续传（决策 4 的另一半）。差异登记 D17。

## 1. 目标文件清单（按实现顺序）

| # | 文件 | 新/改 | 职责 | 对外导出 | 依赖 |
|---|---|---|---|---|---|
| 1 | `entry/src/main/ets/core/net/HttpProtocol.ets` | 改 | 纯传输协议函数层（既有，零 @kit）追加闭区间 Range 头纯函数；`resumeRangeHeader` 保留（P1-U2 探针 S6 在用，ProbeDownload.ets:32/448） | 追加 `closedRangeHeader(start: number, end: number): string`；既有导出不动 | 无 |
| 2 | `entry/src/main/ets/core/engine/PieceAlgo.ets` | 新 | **分片算法纯函数层（零 @kit import，Hypium/U2.3 直接加载）**：分片模型与调度数学——SegmentState/StreamType 常量、EnginePiece 类、createInitialPiece、findMaxChunk、splitPiece、continueAdjacentPiece、allFinished、getInactiveChunkCount、getInactivePiece、sortPiecesByOffset、windowOf、totalDownloadedOf；PieceSnapshot 快照类型 | `SEG_STATE_*`、`STREAM_PRIMARY`、`SPLIT_THRESHOLD`、`EnginePiece`、`PieceSnapshot`、`createInitialPiece`、`findMaxChunk`、`splitPiece`、`continueAdjacentPiece`、`allFinished`、`getInactiveChunkCount`、`getInactivePiece`、`sortPiecesByOffset`、`windowOf`、`totalDownloadedOf` | 无 |
| 3 | `entry/src/main/ets/core/Config.ets` | 改 | 配置骨架（既有）补第 6 键 maxSegments（对照 Config.cs:122 默认 8；getter/setter/preferences 持久化，同构既有数值键模式 :75/:121-124） | 追加 `DEFAULT_MAX_SEGMENTS`、`getMaxSegments()`、`setMaxSegments(v)`；既有导出不动 | 无 |
| 4 | `entry/src/main/ets/core/net/HttpClient.ets` | 改 | 纯传输层（既有）。唯一改动：`HttpResponseHead` 增 `errCode: number` 字段（传输异常原始码观测面——U1.2 只回 status=0 丢失 errCode，worker 结果需要它做 connectPhase 诊断与探针观测）；open() 内 4 处字面量构造同步补字段（:88/:117/:123/:126），catch 分支填 err.code、成功路径填 0 | 既有导出不动（`HttpClient`/`HttpResponseHead`/`END_GATE_TIMEOUT_MS`）；接口字段追加向后兼容（既有读取点只摸 status/header） | ../Config |
| 5 | `entry/src/main/ets/core/engine/SegmentWorker.ets` | 新 | **@Concurrent 分段 worker（TaskPool 侧）**：模块级 `@Concurrent segmentWorkerTask(params): Promise<string>`——单连接单窗口尝试：开 fd（局部，禁共享字段）→ lseek 定位 → HttpClient.open(六键头+Range) → probe 模式取头即 abort → 常规模式 dataReceive 定长封顶写盘 → connected JSON 经 `Task.sendData` 中途上报（progress 定时回报，失败降级）→ isCanceled 协作取消 → 空闲语义 waitStreamEnd → 结果 JSON 返回。消息/参数/结果类型定义同文件导出（主线程复用） | `segmentWorkerTask`、`WorkerParams`、`WorkerConnectedMsg`、`WorkerProgressMsg`、`WorkerResult`、`PROGRESS_REPORT_INTERVAL_MS` | #1 #4、../net/HttpClient、../net/HttpProtocol、@kit.ArkTS(taskpool)、@kit.CoreFileKit、@kit.BasicServicesKit |
| 6 | `entry/src/main/ets/core/engine/PieceGrabber.ets` | 新 | **分片调度器（主线程单点，对照 HTTPDownloaderBase 调度面）**：pieces: Map<string,EnginePiece> 与 records: Map<string,DispatchRecord> 的原子步调度——createPiece（:307-332 逐行）、retryFailedPieces（:351-371）、dispatchPiece（record 构造+Task 组装+onReceiveData 挂接+execute+reject 分类）、cancelRecord、onWorkerMessage（connected/progress 分派）、onWorkerResult（EOF/connectPhase/DiskError/完成分类）、probeConnected/resumeConnected 处理器、pieceDownloadFinished/pieceDownloadFailed、多分片 assemblePieces（:330-483 顺序拷贝+清 temp）、进度节流发射。纯数学全部委托 #2；worker 全部委托 #5 | `PieceScheduler`（类；由 Downloader 组合持有） | #2 #5、./EngineMath、./SegmentWorker、../net/HttpProtocol、@kit.ArkTS(taskpool/util)、@kit.CoreFileKit、@kit.PerformanceAnalysisKit |
| 7 | `entry/src/main/ets/core/engine/Downloader.ets` | 改（重写内部，冻结外壳） | 分段下载引擎门面：**DownloadEvents/NoopDownloadEvents/ForwardDownloadEvents 三导出原样保留**（:43-129）；Downloader 类保持 start/resume/stop/isRunning 签名，内部委托 PieceScheduler；新增探针观测面 describePieces/getPieceSnapshots/activeSegmentCount；摘除 U1.2 单分片私有态（pieceId/fd/currentClient 等——fd 纪律④：引擎层从此无 fd 字段） | `DownloadEvents`、`NoopDownloadEvents`、`ForwardDownloadEvents`、`Downloader`（+新观测方法）；签名全兼容 | #2 #6、./EngineMath、../net/HttpProtocol、../db/RecordMapping(joinTempDir)、../Config、../../model/DownloadRecord |
| 8 | `entry/src/main/ets/probe/units/ProbeSegmentLogic.ets` | 新 | P2-U1 纯函数层（零 @kit）：区间覆盖/重叠/间隙校验（快照数组→overlapCount/gapCount/coveredBytes）、快照行格式化（ProbeKit 白名单字符集内）、吞吐比值计算 | `checkCoverage`、`formatSnapshots`、`throughputRatio`、`SEG_SOURCE_BYTES` | ./…无业务依赖（PieceSnapshot 从 #2 import 类型） |
| 9 | `entry/src/main/ets/probe/units/ProbeSegment.ets` | 新 | P2-U1 探针页（S1~S5，§6 步骤表）：TextInput 测试源（autoStart=false）+ ProbePage 编排 + 会话代际守卫 + 事实袋采集（复用 ForwardDownloadEvents）+ activeSegmentCount 30ms 轮询取 maxConcurrent | `ProbeSegment`（struct） | #7 #8、../core/ProbeKit+ProbePage、../../core/db/DownloadStore、../../model/*、./ProbeDownloadLogic(expectedByteAt/spotOffsetAt 复用)、../../core/Config |
| 10 | `entry/src/main/ets/probe/ProbeIndex.ets` | 改 | PROBE_UNITS 注册表追加 `{unitId:'P2-U1'}` + else-if 分支追加 `ProbeSegment()`（U1.2 同款 :改动点） | —（@Entry 页） | #9 |
| 11 | `entry/src/main/resources/base/element/string.json` | 改 | 追加探针 3 键（§2.5；既有键不动，纯 JSON 禁尾逗号） | —（资源） | 无 |
| 12 | `entry/src/test/PieceAlgo.test.ets` | 新 | 分片算法纯函数 Hypium 用例（§7-[A]-3，14 条） | testsuite 注册函数 | #2 |
| 13 | `entry/src/test/List.test.ets` | 改 | testsuite 注册 pieceAlgoTest()（既有六条注册保留） | `testsuite` | #12 |
| 14 | `docs/probe/PROBE-u2-1-piecegrabber-segmentworker.md` | 新 | 探针运行手册：**P1-U2-download-server.js 复用指引**（node 启动/路由表/局域网 IP 纪律）+ 测试 URL 可替换参数 + 慢源说明 + 预期序列表 | —（文档） | #9 #14 |
| 15 | `docs/probe/EXPECT-u2-1-piecegrabber-segmentworker.json` | 新 | 机器可读预期表（BEGIN+S1~S5+SUMMARY+END 共 9 条目，JSON.parse 校验，schema 同 EXPECT-u1-2） | —（JSON） | #14 |

**显式不动的文件**：`module.json5`（§0-9）、`main_pages.json`（§0-9）、`entryability/EntryAbility.ets`、`pages/Index.ets`（消费面 :114-150 全兼容：start/resume/stop/isRunning+事件）、`components/NewDownloadDialog.ets`、`core/db/*`、`model/*`、`probe/core/*`、既有 probe/units/ 四文件（ProbeDownload.ets 归档不追改，§0-8）。**红线**：`core/**` import 图不得出现 `probe/`；`PieceAlgo.ets`/`SegmentWorker.ets`（worker 侧可达代码）不得 import `Config` 之外的业务单例——worker 内禁单例（约束⑥），`HttpClient` 在 worker 中构造时**必须显式传 timeoutMs**，避免构造默认值落到 `Config.getInstance()`（Config.ets:59-62；worker 线程 Config 未 init 虽只返默认值，仍以显式传参杜绝隐式依赖）。

## 2. 数据模型与表结构（对照源码逐一核对）

### 2.1 EnginePiece（对照 Piece.cs:6-37 + SegmentState.cs:3-7）

| 字段 | 类型 | 对照与说明 |
|---|---|---|
| id | string | Piece.Id（Guid）；util.generateRandomUUID() |
| offset | number | Piece.Offset（文件绝对区间起点，闭区间下界） |
| length | number | Piece.Length（-1=未知，仅初始探测前的初始片） |
| downloaded | number | Piece.Downloaded（相对片首的已落盘字节数；C# Interlocked 字段→普通字段：主线程单点管理后无并发写者，约束⑦） |
| state | number | SegmentState：`SEG_NOT_STARTED=0 / SEG_FINISHED=1 / SEG_DOWNLOADING=2 / SEG_FAILED=3`（SegmentState.cs:3-7 枚举序）。**只赋 0/1 两值**（研究 fact 2：全 Progressive 代码从未赋 Downloading/Failed；"活跃"以 records 成员资格判定，对齐 grabberDict 语义） |
| streamType | number | StreamType：`STREAM_PRIMARY=0 / STREAM_SECONDARY=1`（Piece.cs:34-37）；单源恒 PRIMARY，字段保真（DualHttp 属远期） |

### 2.2 DispatchRecord（grabber 等价物，PieceGrabber.cs:13-35 实例字段映射）

| 字段 | 类型 | 对照 |
|---|---|---|
| pieceId | string | PieceGrabber.pieceId :18 |
| task | taskpool.Task | Thread t :15（TaskPool 化） |
| attemptBaseRel | number | 本次尝试派发时刻 piece.downloaded（窗口写起点相对值） |
| windowStart / windowEnd | number | 闭区间绝对字节区间 [start,end]（end=-1 开窗口）；对照 CreateRequest :387-395 |
| openWindow | boolean | 开窗口（探测类请求 bytes=0-，接受 200/206）vs 闭窗口（206 强检）——§0-6 per-attempt 分类 |
| probeMode | boolean | 探测尝试（取头即 abort 不写盘，§0-3） |
| timesRetried | number | PieceGrabber.timesRetried :24——**record 粒度**：每次（重）派发新建 record 即归零（约束③，对齐 :24 字段初始化 + CreatePiece/RetryFailedPieces 每次新建实例） |
| lastReportedRel | number | 最近一次 progress 消息的相对字节（取消重派的恢复点，原版无对应物——原版共享内存活体计数，本引擎消息化，§4-D2） |
| alive | boolean | 停止/分裂取消后置 false，消息/结果一律丢弃 |

### 2.3 worker 消息协议（SegmentWorker.ets，全 JSON 字符串）

```
WorkerParams（taskpool.Task 构造参数，平面对象全传值，约束⑥）:
  pieceId: string; url: string; start: number; end: number;      // end=-1 开窗口 'bytes=0-'
  openWindow: boolean; pieceFilePath: string; writeStartOffset: number;
  timeoutMs: number; probeMode: boolean; attempt: number;        // attempt 仅回声诊断
  headers: Record<string, string>                                 // 主线程合成：sixDefaultHeaders(url)+Range 键

WorkerConnectedMsg（Task.sendData 中途消息，kind 判别）:
  kind: 'connected'; pieceId: string; probe: boolean; status: number;
  contentLength: number; contentRange: string; contentType: string;
  compressed: boolean        // worker 侧 isCompressed 判定（CreateProbeResult :440-441 消费方在主线程，
                             // 消息必须携带——header Record 不跨消息传）

WorkerProgressMsg:
  kind: 'progress'; pieceId: string; bytesWritten: number

WorkerResult（并发函数返回值）:
  pieceId: string; attempt: number; probe: boolean;
  phase: 'connect' | 'body';       // status 未到手=connect（重试前 sleep 10s 判据 :118-124）
  status: number; errCode: number; // status=0 传输异常；errCode=BusinessError.code（HttpClient.ets 本次新增字段）
  bytesWritten: number; windowLen: number;   // windowLen=-1 开窗口
  ended: boolean;                  // HttpClient.waitStreamEnd（空闲语义，约束②）
  diskErrCode: number;             // writeSync 失败码，非 0 → DiskError 非重试终态
  contentRange: string; contentType: string; contentLength: number;
  canceled: boolean                // isCanceled 观测（诊断）
```

### 2.4 PieceSnapshot（探针观测面，PieceAlgo.ets 定义、Downloader 产出、探针消费）

```
PieceSnapshot { id: string; offset: number; length: number; downloaded: number;
  state: number; inflight: boolean; lastStatus: number;   // lastStatus=最近 connected 消息 status（每分片 status 观测）
  windowStart: number; windowEnd: number }                 // 最近派发窗口（区间不重叠观测原料）
```

### 2.5 Config 第 6 键 / string.json 追加键

| 项 | 值 | 对照 |
|---|---|---|
| KEY_MAX_SEGMENTS / DEFAULT_MAX_SEGMENTS | 'maxSegments' / 8 | Config.cs:122 `public int MaxSegments { get; set; } = 8;`；MAX_COUNT 装载点 HTTPDownloaderBase.cs:25 |
| probe_p2u1_title | 下载链路探针（P2-U1） | 探针页标题 |
| probe_p2u1_source_hint | 测试源地址（主机局域网 IP，如 http://192.168.1.20:8080） | 同 probe_p1u2_source_hint 口径 |
| probe_p2u1_pause_hint | S5 使用慢速源 /slow.bin?ms=80 扩大暂停窗口；完成后可重跑 S2 | 慢源提示 |

### 2.6 数据层零改动

downloads 表 22 列/DownloadRecord 16 字段不动；引擎仍零 DB（事件消费方落库，D8/D12 沿用）。size 列由 onConnected totalSize>0 写入（探测连接携带）；downloadedBytes 由 onProgress/onPaused 携带（主线程聚合值=Σ piece.downloaded，语义与 U1.2 writtenBytes 兼容扩展）。分片状态持久化（chunks JSON，决策 4/原 chunks.db :557-618）属 U2.2——本单元 SaveChunkState 调用点（CreatePiece/SplitPiece/PieceConnected/Finished/UpdateDownloadedBytesCount 2s 门）以空注释锚占位不落盘。

## 3. 关键算法翻译说明

### 3.1 状态机总览（主线程单点，对照 HTTPDownloaderBase + SingleSourceHTTPDownloader）

```
start()                                     // SingleSourceHTTPDownloader.Start :71-104
  mkdir tempDir(recursion) → pieces = { createInitialPiece() }   // :84-92 {Offset=0,Length=-1,Downloaded=0,NotStarted}
  → init=false → dispatchPiece(初始片, probeMode=true, openWindow=true)   // :94/:102 grabber+Download
  → events.onStarted (:99，先于连接)

probeConnected(pieceId, msg)                // PieceConnected(result!=null) :228-293
  if (!isSuccessStatus(msg.status)): 删探测 record → records.clear() →
      onFailed(INVALID_RESPONSE, 'Invalid response: '+msg.status) → return        // §0-1 拍板（EnsureSuccessStatusCode 等价）
  piece.length=msg.totalSize; piece.offset=0; piece.downloaded=0; piece.state=NOT_STARTED (:238-244)
  init=true → fileSize = totalSize>0 ? totalSize : -1
  splittingAllowed = !msg.compressed && msg.status===206 && totalSize>0   // :441 Resumable 同式
  events.onConnected(id, status, totalSize, resumable, contentType)       // 探测值（约束①签名不变）
  if (totalSize>0 && statfs.getFreeSizeSync(tempDir)<totalSize):    // :279-285（§0-11；与 resumable 无关——
      删探测 record → records.clear() → onFailed(DISK_ERROR,'insufficient disk space') → return  // 源码凡 ResourceSize>0 即查）
  // 文件名嗅探/OnProbed 不移植（§4-D3/D7 系）；totalSize=compressed?-1:(contentLength>0?contentLength:
  // parseContentRange(contentRange).total)——U1.2 Downloader :347-352 同推导，compressed 防御 :181-188 经
  // 消息 compressed 字段等价落位（CreateProbeResult :440 消费该旗标）
  if (!splittingAllowed): dispatchPiece(pieceId, openWindow=true)          // §0-4 整流模式（整流首派=探测类请求）
  else: createPiece() → dispatchPiece(pieceId, openWindow=false)           // :292 CreatePiece 派上半区
        + 显式补派下半区（§0-3 拍板——原版由探测连接本体覆盖）
  （探测 record 本身待其 result 到达才静默删——probeConnected 时点它仍在 records（§3.5 首行），createPiece
   的 MAX_COUNT 记账瞬态 -1（微秒级）无害；不提前删，避免 RetryFailedPieces 先派整片又被分裂取消的空 churn）

resumeConnected(record, msg)                // PieceConnected(result==null) + Connect :194-202 校验
  if (msg.status !== 206): cancelRecord+pieceDownloadFailed(INVALID_RESPONSE,'Resume not supported')  // :194-197
  else if (fileSize>0 && parseContentRange(msg.contentRange).total !== fileSize): 同上 'Content length mismatch'  // :198-202
  else if (parseContentRange(msg.contentRange).start !== record.windowStart): 同上（U1.2 D9 加固保留）
  else: piece.lastStatus=msg.status → createPiece()                        // :205→:292 每连接一次分裂驱动
（connected 消息分派口径——编码防错点：**校验语义按 record.openWindow 分支、探测值处理按 record.probeMode 分支**。
 开窗口 && !probeMode（整流模式重派/首派，§0-4）：isSuccessStatus 门（200/206 均过）→ piece.lastStatus 记录 →
 createPiece()（:292 对齐；splittingAllowed=false 时 createPiece 无为而返——piece 在途被 getInactivePiece
 排除、findMaxChunk 恒 null）。**禁止**把整流连接当 resumeConnected 处理——206 强检会拒掉整流模式的合法 200。）

createPiece()                               // :307-332 逐行
  if (stopRequested) return; if (records.size === maxSegments) return      // :313
  rem = maxSegments - records.size
  rem -= retryFailedPieces(rem)                                            // :315
  if (rem > 0): maxId = findMaxChunk(pieces, splittingAllowed)             // :318（splittingAllowed=false 恒 null，§0-4）
    newId = splitPiece(pieces, maxId)                                      // :319
    if (newId !== null):
      if (原片在途): cancelRecord(原片)+record 删除 + dispatchPiece(原片)   // §0-5 取消重派（原片保下半区）
      dispatchPiece(newId)                                                 // :322-323 新上半片
  // saveChunkState() 占位锚（U2.2）

pieceDownloadFinished(pieceId)              // :243-266
  piece.state=FINISHED; record 删除; if (allFinished(pieces)): assemblePieces()+onFinished+cleanup
  else createPiece()                                                        // :265 锁外

pieceDownloadFailed(pieceId, code)          // :224-241
  record 删除（分片留在 pieces 待重试）; if (records.size===0): onFailed(code)   // :232-235
  （InvalidResponse+totalDownloaded>0→SessionExpired(9) 映射不移植，D20 沿用）

stop()                                      // HTTPDownloaderBase.Stop :109-130 映射
  stopRequested=true → generation++ → 逐 record: taskpool.cancel(task)（fire-and-forget，不等待退出）
  → records.clear() → running=false → events.onPaused(id, totalDownloadedOf(pieces))
  （原版死 grabber 条目滞留 bug 不复刻，§4-D9）
```

### 3.2 调度数学（PieceAlgo.ets 纯函数，逐行对照）

| 纯函数 | 对照 | 数学（逐字保留） |
|---|---|---|
| `findMaxChunk(pieces, splittingAllowed)` | :405-428 | `splittingAllowed===false → null`（§0-4 守卫点）；遍历全部 pieces（含 Finished rem=0、在途 rem 按主线程已知值），`rem=length-downloaded`，取 rem 最大者；**返回 `max > 256*1024 ? pid : null`**（262144 为 SPLIT_THRESHOLD 常量） |
| `splitPiece(pieces, chunkId)` | :430-466 | chunkId null→null；`rem=len-downloaded`；**`rem < 256*1024 → null`**（注意：与 findMaxChunk 的 `>` 是两个不同边界——rem==262144 时 Find 不选、Split 允许，逐字保留并单测锁定）；`len=rem/2`（整除下取整）；`offset=chunk.offset+chunk.length-len`；**原片保下半区** `chunk.length-=len`（downloaded 保留）；新片 `{offset, length:len, downloaded:0, state:NOT_STARTED, id:newUUID, streamType 同源}` 取上半区 |
| `retryFailedPieces(rem)` | :351-371 | `for (n = min(getInactiveChunkCount(), rem); n>0; n--)`: `id=getInactivePiece()`，null 即 break；否则 `dispatchPiece(id)`（新建 record=新 grabber=新预算）+ count++；返回 count |
| `getInactivePiece(pieces, activeIds)` | :387-403 | 首个满足 `!(activeIds.has(id) || state===FINISHED || downloaded===length)` 的分片（Map 插入序= C# Dictionary 实践序） |
| `getInactiveChunkCount(pieces, activeIds)` | :373-385 | 计数条件**缺** `downloaded===length` 排除项（:378-379 与 :394 的差异是源码原貌，逐字保留不"顺手修复"，单测锁定） |
| `continueAdjacentPiece(pieces, pieceId, maxByteRange)` | :157-195 | `position=chunk.offset+chunk.length`；找 `downloaded===0 && offset===position && streamType===chunk.streamType && (offset+length)<=maxByteRange` → 删邻片、`chunk.length+=邻片.length`、返回 true；否则 false。（原版停邻片 grabber/删 grabber/CreatePiece/SaveChunkState 由调用方调度器承担：吸收成功后 cancelRecord(邻片)+dispatchPiece(pieceId 扩窗)+createPiece()——本引擎运行时不可达成功，§0-4/D6，纯函数保真供 U2.3） |
| `allFinished(pieces)` | :334-349 | 逐片 `state===FINISHED`，全真才 true；空 Map → true（C# 空循环语义） |
| `windowOf(piece)` | :393-394 | `[piece.offset+piece.downloaded, piece.offset+piece.length-1]` 闭区间；`length<=downloaded` 不可派发（GetInactivePiece 排除项保证不发生）；开窗口 `[0,-1]` 仅探测/整流首派 |
| `totalDownloadedOf(pieces)` | :515-526 TicksAndSizeAtResume 同式 | Σ downloaded（按需重算，≤16 片开销可忽略；值与原版增量累计一致） |

### 3.3 请求构造与响应校验（主线程合成头，worker 只消费）

- 头合成（每次派发）：`sixDefaultHeaders(url)`（HttpProtocol.ets:23-33，含 `Accept-Encoding: identity` 决策 3）+ `Range` 键：开窗口 `'bytes=0-'`（AddRange(0) :389）；闭窗口 `closedRangeHeader(windowStart, windowEnd)` = `'bytes='+start+'-'+end`（AddRange(start,end) :393-394 → RangeHeaderValue(start,end)，DotNetHttpSession.cs:46-52；**约束⑤：U1.2 D19 的 open-ended 简化弃用**，resumeRangeHeader 仅探针保留）。Cookie 原始串注入点=header Record（U1.2 既有口径，本单元无 cookie 来源）。
- 响应校验（主线程，connected 消息处理时点，等价 Connect :179-202 在 PieceConnected :205 之前的时序）：`isSuccessStatus` 白名单（200/206，4xx/5xx→INVALID_RESPONSE 终态，§0-1 U1.2 拍板沿用）；compressed 判定 `isCompressed` **在 worker 侧完成**（header Record 不跨消息传），经 WorkerConnectedMsg.compressed 旗标到主线程后落 :181-188 防御（total=-1、禁 resumable、206 视作 200——探测路径经 §3.1 totalSize/splittingAllowed 推导吸收；闭窗口遇 compressed 同样按 status!==206 分支拒绝）；闭窗口三检：206 强检（:194-197）+ Content-Range total==fileSize（:198-202 IsFileChangedOnServer）+ start==windowStart（D9 加固）；开窗口（探测/整流）接受 200/206。
- 错误码沿 EngineMath.ets:26-30（Generic=1/NonResumable=2/MaxRetry=4/InvalidResponse=5/DiskError=8）。**ERR_NON_RESUMABLE(2) 在本引擎重新可达**：闭窗口重派时 `piece.length<=0`（未知大小）→ 派发前直接 pieceDownloadFailed(NonResumable)（:169-170 逐行——U1.2 D21 不可达分支在此可达化）。

### 3.4 worker 主流程（SegmentWorker.ets @Concurrent，一次连接尝试）

```
@Concurrent async function segmentWorkerTask(params: WorkerParams): Promise<string>
  probeMode 分支（§0-3）:
    client=new HttpClient(params.timeoutMs)                    // 显式超时，禁落 Config 单例
    head = await client.open(url, headers)                     // 'bytes=0-'
    if (Task.isCanceled()) → 返回 canceled 结果
    if (head.status<=0) → {phase:'connect', status:0, errCode:head.errCode}
    Task.sendData(JSON.stringify(connectedMsg))                // 主 body 内，d.ts NOTE 合规
    client.abort(); 返回 {phase:'body', probe:true, bytesWritten:0, ...}
  常规分支:
    fd 局部生命周期（约束④）: file = fileIo.openSync(pieceFilePath, READ_WRITE|CREATE)   // 不带 TRUNC（OpenOrCreate 等价 :233-236）
      if (writeStartOffset>0) fileIo.lseek(file.fd, writeStartOffset, SEEK_SET)            // Seek(downloaded,Begin) :236
      client.onChunk = (chunk) => {
        if (taskpool.Task.isCanceled()) { client.abort(); canceledMark; return; }          // 协作取消，先查后写
        const remain = windowLen - written;                                                // 窗口定长封顶（安全支柱①，§0-5）
        const n = chunk.byteLength > remain ? remain : chunk.byteLength;                   // min(32KB,remaining) :284-285 等价
        if (n<=0) return;                                                                  // 超窗静默丢弃（200 越界体防御）
        try { fileIo.writeSync(file.fd, n===chunk.byteLength ? chunk : chunk.slice(0, n)); written += n; }
        catch (e) { diskErrCode = (e as BusinessError).code; }                             // IOException→DiskError :296-299
      }
      head = await client.open(url, headers)
      Task.sendData(connectedMsg)                                                          // 主 body 内发送
      定时器 progress 回报: setInterval(() => { if (reportDisabled) return;
          try { Task.sendData(JSON.stringify(progressMsg)) }
          catch (e) { reportDisabled=true; clearInterval } }, PROGRESS_REPORT_INTERVAL_MS=250)
      ended = await client.waitStreamEnd()                                                 // 空闲语义门（约束②，HttpClient.ets:180-203）
    finally: clearInterval; client.abort(); if (fd>=0) fileIo.closeSync(fd)                // 局部 fd 关闭（约束④）
  结果 JSON: {phase: head.status<=0?'connect':'body', status, errCode, bytesWritten, windowLen,
             ended, diskErrCode, contentRange, contentType, contentLength, canceled, pieceId, attempt, probe}
  取消语义: taskpool.cancel 后 execute() Promise reject（d.ts:1721 catch 分支）——主线程按 record.alive/generation 静默
```

worker 内引用纪律（`arkts-sendable-imported-variables`：仅 top-level export 可引用）：可 import `HttpClient`（类）、`headerValueOf`（HttpProtocol 纯函数）；**数值常量内联字面量**（超时窗、250ms、15000ms 兜底——ProbeHttp.ets:82 先例）；禁捕获任何外部可变量。

### 3.5 结果分类与重试（record 循环，PieceGrabber.Download2 :68-140 映射）

onWorkerResult 分类（record 仍 alive 且 generation 未过期才处理）：

| 结果形态 | 分类 | 处置（对照） |
|---|---|---|
| probe 尝试结果 | 探测收尾 | 静默删 record（connected 消息已驱动调度；消息与结果到达次序互逆均安全——connected 处理按 pieceId+!init 守卫，不依赖 record 存在） |
| diskErrCode!==0 | DiskError 终态 | pieceDownloadFailed(DISK_ERROR)（:296-299 NonRetriable） |
| phase='connect'（status<=0） | 连接期失败 | sleep(RetryDelay×1000=10000ms)（与 stop 门 Promise.race）后同 record 重派（:118-124） |
| bytesWritten<windowLen（或开窗口 !ended） | Unexpected EOF | 立即重派（body 期不 sleep；:284-290 DownloadException(Generic) 被吞重试）；开窗口未知大小重派 → NonResumable 终态（:169-170） |
| bytesWritten>=windowLen（闭窗口）| 窗口完成 | continueAdjacentPiece(pieceId, windowEnd+1) 原位调用（:271-283 parity，运行时恒 false）→ false 即 pieceDownloadFinished |
| execute() reject（cancel） | 取消/异常 | record.alive=false 或 generation 过期 → 静默；否则按连接期失败处理 |
| timesRetried 预算 | — | 每次同 record 重派前 `++` 后判 `exceedsMaxRetry(>10)` → pieceDownloadFailed(MAX_RETRY)（:113-117 原序，最多 11 次尝试/record；约束③ record 粒度归零） |

进度发射：progress 消息与结果均更新 `piece.downloaded = attemptBaseRel + bytesWritten`（record 键控防串片）→ `throttleIfNeeded()` 空钩子（research fact 10，U3.2 SpeedLimiter 占位）→ 500ms 门（`shouldEmitProgress`+elapsed>0，EngineMath 原样）→ `events.onProgress(id, progress, instant, eta, Σdownloaded)`——数学零改动（EngineMath.ets:45-76），仅累计入口换为消息聚合。

### 3.6 取消-重派安全论证（§0-5 三支柱，编码与审查共同复查点）

1. **窗口封顶写**：worker 写盘量恒 ≤ 派发窗口长度 → 取消中的 worker 永不写进新上半片的文件（它只写自己 piece 文件）。
2. **前缀覆盖幂等**：重派起点 = `max(attemptBaseRel, lastReportedRel)`；取消瞬间未回报的字节落在 [恢复点, 真实写入点)——源字节与重派请求提供的字节相同（同一绝对偏移同内容），新 worker 从恢复点顺序写覆盖之，内容幂等无洞。
3. **Length 切片拼装**：assemblePieces 每片精确读 `pc.length` 字节（:359）→ 被取消 worker 留在文件内的陈旧尾部（超出收缩后 length）恒被忽略。
推论：分裂取消**无需等待 worker 退出**（无 death-await），record 即删即重派；两 fd 短暂并存同一文件但其中之一不再写盘（isCanceled 先查后写，worker 回调体内原子）。

### 3.7 多分片拼接收尾（AssemblePieces :330-483 落地，替代 U1.2 D10 renameSync 退化）

SortAndValidatePieces 等价：`sortPiecesByOffset`（:295-303）→ targetDir 空→Config.getDownloadDir() → mkdirSync(recursion) → `getUniqueFileName`（AutoRename 语义）→ **盘空间预检（§0-11 照译）**：`fileSize>0 && statfs.getFreeSizeSync(targetDir)<fileSize` → 拼装失败 onFailed(ERR_DISK_ERROR,'insufficient disk space')（:318-325 AssembleFailedException(DiskError) 链路；statvfs 抛错吞→跳过检查，等价 GetFreeSpace 返 false）。拼接：`fileIo.openSync(target, WRITE_ONLY|CREATE|TRUNC)`（FileMode.Create :352）→ 逐片 open piece file → `fileSize>0` 分支按 `pc.length` 精确拷贝（**5MB=5*1024*1024 缓冲，对照 Rent(5*1024*1024) :346**；EOF 早于 len → 'EOF :: File corrupted' → 拼装失败 :386-391）；`fileSize<=0` 分支读到 EOF（:360-380）→ 全片完成 → close → `deleteTempDir`（逐文件 unlinkSync+rmdirSync，catch 吞，:544-555）→ `events.onFinished(id, statSync(target).size, target)`。拼装失败错误码分类（对照源码 catch 链）：盘满/写盘 IO → `onFailed(ERR_DISK_ERROR,'assemble failed …')`（:373-377/:396-400 AssembleFailedException(DiskError)）；EOF 早尽 → `onFailed(ERR_GENERIC,'EOF :: File corrupted')`（:386-391 裸 Exception → :473-477 非 DownloadException 扁平化为 Generic）。原版 AssembingProgressChanged 不移植（DownloadEvents 无此事件，拼装毫秒级）。

### 3.8 线程模型映射总表（决策 2）

| 原版（C#） | 本引擎（ArkTS） |
|---|---|
| PieceGrabber 裸 Thread（:62-66） | taskpool.Task（每 record 一个，execute 后 OS 线程数由系统调度，不保证恰 8 线程——FAQ faqs-arkts-28；"8 并行"观测口径=同时在途 record 数） |
| 阻塞 sourceStream.Read(32KB)（:284） | requestInStream dataReceive 事件分块（HttpClient 复用） |
| ReaderWriterLockSlim + Piece Interlocked（:39/:14） | 主线程单点 pieces/records Map，无锁（约束⑦） |
| PieceConnected 回调（:205） | Task.sendData connected 消息 → task.onReceiveData（主线程） |
| UpdateDownloadedBytesCount 跨线程共享计数（:268） | Task.sendData progress 消息（250ms 周期+完成时终值） |
| request.Abort()（:146/:321） | taskpool.cancel(task) + worker isCanceled 协作 abort（d.ts:262/1732） |
| sleepHandle.WaitOne(10s)（:449-452） | 主线程 Promise.race[sleepMs(10000), stopGate] |
| cancelFlag + ThrowIfCancellationRequested | generation 守卫（五守卫点模式）+ isCanceled + record.alive |

## 4. 有意差异清单（对照源码/计划，含已定降级项）

| # | 差异 | 依据 |
|---|---|---|
| D1 | 裸 Thread+阻塞读+ReaderWriterLockSlim+Piece Interlocked → taskpool.Task+dataReceive 事件流+主线程单点无锁 | 决策 2（既定）；约束⑦ |
| D2 | worker 消息面：Task.sendData/onReceiveData 承载 connected（每连接）与 progress（250ms 周期+完成终值）；原版 progress 是共享内存逐块计数，本引擎消息化 → 进度更新粒度 250ms/次（UI 平滑度略降，数值语义不变） | OQ1 拍板（§0-1/§0-2）；d.ts :262/:283/:343 |
| D3 | 探测连接取头即 abort：原版同一条流续写下半区+活体吸收复用连接 → 本引擎 0 字节探测 + 下半区普通闭区间重派，**+1 次握手、零重复字节** | OQ2 拍板（§0-3） |
| D4 | 非 resumable/未知大小显式单 worker 整流模式（splittingAllowed=false）：替代原版"分裂片 200→NonRetriable→吸收→再分裂"隐式收敛循环；终态等价（单连接整流），避免失败风暴 | OQ3 拍板（§0-4） |
| D5 | 分裂命中在途分片 → cancel+立即重派下半区（原版活体缩短 Length+grabber 自适应+吸收续连接）；重派起点=最近 progress 回报，未回报前缀按同内容前缀覆盖重下（少量重复字节，界=派发到取消间的吞吐）；timesRetried 因新 record 归零（原版同 grabber 预算跨分裂保留） | §0-5/§3.6（窗口按值不可变的必然映射） |
| D6 | ContinueAdjacentPiece 保留纯函数+完成路径原位调用（parity），但闭区间窗口数学上不可满足（val.Offset+val.Length≤windowEnd+1 无解）——原版唯一成功路径（探测连接 maxByteRange=全长）被 D3 取代；运行时"恒 false 的 parity 调用"，算法本体由 U2.3 用例表锁定 | §0-4（:171 条件本会话推导核实） |
| D7 | 不移植：CloseUnfinishedRequest 连接复用禁令（:314-325，ArkTS 每请求新建/destroy 无连接池）、TextRedirect 分支（:190-193，SingleHttp IsTextRedirectionAllowed=false 恒死路 :508）、文件名嗅探（AttachmentName/ContentType→TargetFileName，:247-270，U1.2 D6/D13 系）、AssemblingProgressChanged、FetchServerTimeStamp（U1.2 D11 系）。~~盘空间预检无对应物~~——**本轮证伪并改为移植**（§0-11，statvfs.getFreeSizeSync 照译 :279-285/:318-325） | 源码行号如左 |
| D8 | SaveChunkState 全部调用点（:157/:183/:231/:252/:283/:326/:457）为空锚不落盘——分片状态持久化属 U2.2（chunks JSON 替代二进制 chunks.db，决策 4） | 决策 4/UNIT_CATALOG U2.2 |
| D9 | 原版 Stop 后死 grabber 条目滞留 grabberDict（:129/:245 提前 return 不删）→ 同实例 8 分片暂停后恢复因 `Count==MAX_COUNT`（:313）卡死的边界 bug；本引擎 stop() 即清 records，不复刻 | 不复刻 bug 先例（U1.2 D6）；:129/:245/:313 本会话核实 |
| D10 | Stop 语义单入口 stop()（暂停/取消同源）；cancel 不设独立入口（U1.2 D7 沿用）；onPaused 携带 Σdownloaded（U1.2 writtenBytes 的多片扩展） | U1.2 D7 |
| D11 | SessionExpired(9) 映射不移植（:496-501 InvalidResponse+totalDownloaded>0→9；U3.x 接错误文案时补，U1.2 D20 既定）；拼装失败错误码保真分类：盘满/IO→DiskError(8)、EOF 早尽→Generic(1)（§3.7 本轮细化——前轮"统一扁平化 Generic"表述与源码 :373-377/:396-400 不符） | U1.2 D20 沿用 + §3.7 |
| D12 | "首请求"分类 per-download（IsFirstRequest=!init，:223-226）→ per-attempt：开窗口尝试=探测类（bytes=0-，接受 200/206），闭窗口尝试=206 强检——D3 探测 abort 的派生（整流重派必须以探测类语义重发） | §0-6 |
| D13 | HttpResponseHead 增 errCode 字段（U1.2 只回 status=0；worker 结果/探针需要原始传输错误码观测面） | HttpClient.ets:29-32/:106-115 本会话核实 |
| D14 | Helpers.TickCount→Date.now()（U1.2 D15）；进度/即时速度/ETA 数学零改动（EngineMath 复用） | U1.2 D15 |
| D15 | '8 段并行'=8 个 Task 同时在途（OS 线程数系统调度）；观察口径=activeSegmentCount | 决策 2+FAQ faqs-arkts-28 |
| D16 | pieces 遍历用 JS Map 插入序（C# Dictionary 实践序等价）；GetInactiveChunkCount 缺 Downloaded==Length 排除项的源码原貌逐字保留（含其在 min() 中的轻微多计——循环由 GetInactivePiece 返 null 兜底） | :378-379 vs :394 差异本会话核实 |
| D17 | **单元边界**：多分片 assemblePieces（Offset 排序+5MB 缓冲拼接+清 temp）划入 U2.1——UNIT_CATALOG.md:49 字面把"完成按 Offset 排序 5MB 缓冲拼接"列在 U2.2，本设计按 MIGRATION_PLAN 决策 4 与探针验收闭环（成品文件字节抽查）维持划入 U2.1；U2.2 仅做分片进度 JSON 持久化+杀进程续传 | §0-13 拍板（研究 openQuestion 2 建议沿用） |
| D18 | EngineMath 不补 ERR_ASSEMBLING_FAILED(3)/ERR_SESSION_EXPIRED(9)（研究 fact 8 建议）：AssemblingFailed 引擎侧从未构造（grep 仅 ErrorMessages.cs UI 文案表），补即死码；SessionExpired 映射按 U1.2 D20 既定延后至 U3.x | §0-12 裁定 |

## 5. 各文件实现要点（可直接照做的接口面）

### 5.1 core/net/HttpProtocol.ets（改，+1 纯函数）

- `export function closedRangeHeader(start: number, end: number): string { return 'bytes=' + String(start) + '-' + String(end); }`——注释锚 DotNetHttpSession.cs:46-52/WebRequestExtensions.cs:160-163。既有函数零改动。

### 5.2 core/engine/PieceAlgo.ets（新，纯，零 @kit）

- 常量：`SEG_NOT_STARTED=0/SEG_FINISHED=1/SEG_DOWNLOADING=2/SEG_FAILED=3`、`STREAM_PRIMARY=0/STREAM_SECONDARY=1`、`SPLIT_THRESHOLD=262144`（:422/:439 `256*1024`）。
- `export class EnginePiece`（§2.1 全字段显式初始化）；`export interface PieceSnapshot`（§2.4）。
- 函数签名（全部显式返回类型，操作 `Map<string, EnginePiece>`，activeIds 用 `Set<string>`）：
  `createInitialPiece(id: string): EnginePiece`、`findMaxChunk(pieces, splittingAllowed): string | null`、`splitPiece(pieces, chunkId): string | null`（内部 util.generateRandomUUID？否——**纯函数禁 @kit**：id 由调用方传入 `splitPiece(pieces, chunkId, newId)` 三参形态）、`continueAdjacentPiece(pieces, pieceId, maxByteRange): boolean`、`allFinished(pieces): boolean`、`getInactiveChunkCount(pieces, activeIds): number`、`getInactivePiece(pieces, activeIds): string | null`、`sortPiecesByOffset(pieces): EnginePiece[]`、`windowOf(piece): number[]`（[start,end] 或 [0,-1]）、`totalDownloadedOf(pieces): number`。
- Map 遍历：`forEach((p: EnginePiece, pid: string) => …)`（禁 for...in；for..of entries 亦合规，二选一统一）。

### 5.3 core/Config.ets（改，+1 键）

- `const KEY_MAX_SEGMENTS: string = 'maxSegments';` `export const DEFAULT_MAX_SEGMENTS: number = 8;`（Config.cs:122）；`private maxSegments: number = DEFAULT_MAX_SEGMENTS;`；init() 追加 `this.maxSegments = this.readNumber(KEY_MAX_SEGMENTS, DEFAULT_MAX_SEGMENTS);`（:77 同构）；`getMaxSegments(): number` / `setMaxSegments(value: number): void`（:97-104/:121-124 同构）。

### 5.4 core/net/HttpClient.ets（改，+1 字段）

- `export interface HttpResponseHead { status: number; header: Record<string, string>; errCode: number }`；open() 内 :88/:123/:126 成功路径 errCode=0、:117 abort 路径 errCode=0、catch 路径（:110-115）errCode=err.code（status 仍 0）。既有序列化面不变（ProbeDownload S2/S6 只读 status/header）。

### 5.5 core/engine/SegmentWorker.ets（新）

- 模块顶：`export interface WorkerParams/WorkerConnectedMsg/WorkerProgressMsg/WorkerResult`（§2.3）；`export const PROGRESS_REPORT_INTERVAL_MS: number = 250;`（仅主线程引用；worker 函数体内联 250 字面量，ProbeHttp.ets:82 先例）。
- `@Concurrent async function segmentWorkerTask(params: WorkerParams): Promise<string>`——§3.4 流程；结果经 `JSON.stringify(result)` 返回；消息经 `taskpool.Task.sendData(JSON.stringify(msg))`。头键取值用 `headerValueOf`（import 自 HttpProtocol，top-level export 合规）。
- 分层红线：禁 ProbeKit/probe import、禁 Config 依赖（HttpClient 显式传 timeoutMs）、禁 hilog（worker 静默，诊断全走结果 JSON——若实测 hilog 在 taskpool 可用可作为 DIAG 观测增强，不作依赖）。

### 5.6 core/engine/PieceGrabber.ets（新，调度器）

- `export class PieceScheduler` 构造参数：`(record: DownloadRecord, events: DownloadEvents)`；内部持有 `pieces: Map<string, EnginePiece>`、`records: Map<string, DispatchRecord>`、init/splittingAllowed/fileSize/totalSize/generation/stopRequested/running/进度游标（ticksAtStartOrResume/lastProgressUpdatedAt/lastDownloadedAt/bytesSinceStartOrResume）。
- 公开方法（Downloader 门面透传）：`start(): void`、`resume(): void`、`stop(): void`、`isRunning(): boolean`、`describePieces(): string`、`getPieceSnapshots(): PieceSnapshot[]`、`activeSegmentCount(): number`。
- dispatchPiece 核心（唯一 Task 组装点）：窗口=`openWindow ? [0,-1] : windowOf(piece)`；`attemptBaseRel=piece.downloaded`；headers=`sixDefaultHeaders(url)` + Range 键；`const task: taskpool.Task = new taskpool.Task(segmentWorkerTask, params); task.onReceiveData((value: Object) => this.onWorkerMessage(record, String(value))); taskpool.execute(task).then(...).catch(...)`。**record 先入 Map 再 execute**（消息先于 execute 返回到达的竞态安全）。
- 盘空间预检（§0-11）：`import { fileIo, statfs } from '@kit.CoreFileKit'`（statvfs 经 CoreFileKit 以 statfs 名再导出）；probeConnected 与 assemblePieces 两处 `getFreeSizeSync`，调用点各自 try/catch 吞错跳过。
- describePieces 单行格式（ProbeKit 值白名单 `[A-Za-z0-9_.:/|= -]` 内）：`n=<片数> a=<在途数>/<id8>.<offset>.<length>.<downloaded>.<state>.<lastStatus>` 片间 '/'，id8=id 前 8 字符。8 片 ≈ 350B < 1500B。
- 日志：hilog domain 0x0000 tag 'PieceScheduler'（业务通道，绝不 [XDM_PROBE]）。
- 禁止 import：DownloadStore、probe/**、model/DownloadRecord 之外的 UI 依赖。

### 5.7 core/engine/Downloader.ets（改，外壳冻结）

- 头注释重写（U2.1 分段引擎）；`DownloadEvents`/`NoopDownloadEvents`/`ForwardDownloadEvents` **原样保留**（:43-129 逐字节不动）。
- `Downloader` 类：`constructor(record: DownloadRecord, events?: DownloadEvents)` 内持 `private scheduler: PieceScheduler`；`start()/resume()/stop()/isRunning()` 透传；新增 `describePieces(): string` / `getPieceSnapshots(): PieceSnapshot[]` / `activeSegmentCount(): number`（探针观测面，非事件面）。
- 摘除 U1.2 私有态：pieceId/pieceFile/fd/generation/stopRequested/timesRetried/pauseGate 等（全部移入 PieceScheduler 或消亡——**引擎层从此无 fd 字段**，约束④：fd 只存在于 worker 尝试栈帧）。

### 5.8 probe/units/ProbeSegmentLogic.ets（新，纯）

- `checkCoverage(snaps: PieceSnapshot[]): CoverageResult`（interface CoverageResult{overlapCount,gapCount,coveredBytes,firstGapStart}）：按 offset 排序，相邻 `prev.offset+prev.length` 与 `next.offset` 比较——`> next.offset` overlap++，`<` gap++；coveredBytes=Σlength（重叠去重不要求，观测值如实）。**采集守卫**：仅纳入全片 length>0 的快照（探测完成前初始片 length=-1 不参与覆盖校验，探针页采集时过滤）。
- `formatSnapshots(snaps): string`（ProbeKit 白名单内格式，`n=/id8.off.len.dld.st.wStart-wEnd` '/'连）。
- `throughputRatio(segBytesPerSec: number, singleBytesPerSec: number): number`（single<=0 → -1）。
- `SEG_SOURCE_BYTES=4194304`（与 ProbeDownloadLogic.DOWNLOAD_BYTES/P1-U2-download-server BIG_BIN_BYTES 同值锚）。

### 5.9 probe/units/ProbeSegment.ets（新，P2-U1）

- 步骤表（§6）：S1~S5 autoRun=true；页面顶部 TextInput 测试源（autoStart=false，ProbeDownload 同构）。
- 事实袋 `SegmentFacts`（EngineFacts 同构）+ `ForwardDownloadEvents` 监听器（事件消费方，onConnected 计数、onProgress 尾值、onFinished/onFailed 落袋）。
- maxConcurrent 采集：下载期间 `setInterval` 30ms 轮询 `engine.activeSegmentCount()` 取 max（awaitUntil 循环内轮询亦可——统一用 awaitUntil 的谓词轮询附带取样，避免双计时器）。
- S5 暂停窗口：默认源拼 `/slow.bin?ms=80`（S2/S4 用 `?ms=40`）；字节抽查复用 `expectedByteAt/spotOffsetAt`（./ProbeDownloadLogic import）。

## 6. 探针步骤设计（P2-U1，对应手册/EXPECT）

会话形态：单会话 A（输入源 URL→"运行全部" S1~S5 顺序执行）；无重启步（分片持久化属 U2.2）。

| 步骤 | autoRun | 操作 | 观测点（emit key=value） | 预期锚（EXPECT 判定核心） |
|---|---|---|---|---|
| BEGIN | — | begin(unitId, filesDir) | runId、filesDir | 与 END 按 runId 配对 |
| S1 源能力预检 | ✔ | 探针自建 requestInStream GET {base}/big.bin + Range: bytes=0-（不走引擎） | sourceUrl status contentLength rangeSupported chunks | status=206 contentLength=4194304 rangeSupported=true（S2~S5 环境前提，不成立→env 分流） |
| S2 8 分段并行下载 | ✔ | 新建 record（id='probe-p2u1-'+runId，url={base}/slow.bin?ms=40）→ store.add → new Downloader(record, 监听器) → start() → awaitUntil 期间 30ms 轮询 activeSegmentCount 取 maxConcurrent（同轮同步抓瞬时 getPieceSnapshots() 存序列，供 S3）；等 onFinished（120s）→ 5 抽查点 lseek+readSync 比对 expectedByteAt | piecesCount maxConcurrent connectedCount finalSize elapsedMs segBps spotChecks allSpotsMatch engineFailed | **maxConcurrent=8（8 分段并行验收核心锚；快源环境退化 ≥4 → UNVERIFIED 换源分支）**；piecesCount=16±1（分裂收敛数学：4194304/262144=16，2 的幂对分精确到 16 片×262144，FindMaxChunk 严格 `>` 使 rem==262144 不再分裂——本轮修正前轮"8±1"误算，8 是并发上限非片数）；connectedCount≥17（1 探测+16 分片连接，取消重派再加）；finalSize=4194304；**allSpotsMatch=true=多分片拼接字节级正确性证据**（expectedByteAt 确定性流，任一分片错位即 x） |
| S3 区间完整性 | ✔ | 对 S2 采集的**每个瞬时快照**分别 checkCoverage 取 maxOverlapAcrossSnapshots（不变量：任一瞬时 pieces Map 均为 [0,total) 的不交覆盖——分裂=一窗换两半窗，保性质；取消重派后亦然）；对**最终快照**（完成时点全片终值）校验 gapCount 与 coveredBytes | snapshotLines（最终快照）maxOverlapAcrossSnapshots finalGapCount coveredBytes sourceBytes coverageComplete | maxOverlapAcrossSnapshots=0（区间不重叠验收锚，全程每瞬时成立）；finalGapCount=0；coverageComplete=true（最终快照 coveredBytes==4194304；注意不可对"全程快照并集"校验——历史大窗与其分裂半窗天然重叠，并集必 overlap>0，前轮"全程窗口集合"表述有歧义，本轮改为逐瞬时+最终快照双口径） |
| S4 吞吐对比 | ✔ | 单连接基线：HttpClient open {base}/slow.bin?ms=40 → waitStreamEnd 计字节+耗时（abort 收尾）→ throughputRatio(S2.segBps, singleBps) | singleElapsedMs singleBps segBps ratio | singleBps>0 segBps>0（吞吐可测验收锚）；ratio 为观测值不判定（慢源下期望 >1——8 连接并行分摊 40ms/块延迟；EXPECT 记 UNVERIFIED 分支说明快源/空载机器下 ratio≈1 不判 FAIL） |
| S5 暂停-恢复（取消语义） | ✔ | 新 record url={base}/slow.bin?ms=80 → start → awaitUntil(downloaded>=262144) → stop() → awaitUntil(!isRunning && activeSegmentCount===0) → resume() → 等 onFinished | pausedOffset activeAfterStop resumed finalSize maxConcurrentBefore allSpotsMatch2 | activeAfterStop=0（**taskpool.cancel 协作取消排空锚**）；0<pausedOffset<4194304；resumed=true；finalSize=4194304；allSpotsMatch2=true（暂停-恢复跨多分片字节正确） |
| SUMMARY | — | end(ok) 聚合 | 每步关键键单行 <1500B | 5 段齐全 |
| END | — | ok/steps/elapsedMs | ok=true steps=5 | BEGIN/END 配对 |

- 值卫生：emit 值过 ProbeKit 消毒；URL 无空格；布尔/数字直写；**不写 PASS/FAIL**（coverageComplete/maxConcurrent 均为观测事实，判定在 EXPECT/verify）。
- 失败形态：步骤异常 catch emit errCode/errMessage（2300028 超时、13900xx 盘错、taskpool 102000xx 取消/序列化错——原始码直接观测）；S2 errCode 含 10200024（onReceiveData 未注册）→ business-code 分流（dispatchPiece 的 record 先入 Map 再 execute 回归点）。

## 7. 单元验收测试要点

### [A] 静态门禁（编码员每轮自跑）

1. `hvigorw assembleHap` 零 error 零新 warning；自查对照 arkts-grammar-standards：禁 any/解构/正则字面量；对象字面量全带类型（WorkerParams/消息/HttpRequestOptions/EnginePiece）；throw 仅 Error 子类（EngineError）；async 显式 `Promise<T>`；Record 字面量引号键；`catch (e)` 无注解 + `e as BusinessError`；Map/Set 遍历禁 for...in；**结构化类型禁令**：PieceSnapshot 单点定义（PieceAlgo.ets），probe 侧 import 同一类型，禁再造同形接口。
2. **@Concurrent 纪律（hvigor 编译期强制 + 人工复查）**：segmentWorkerTask 为模块级函数（非方法/非嵌套）；参数单对象全传值；worker 体内仅引用 top-level export 与内联字面量（禁模块级 let、禁闭包外捕）；`taskpool.Task.sendData` 仅两处调用点（connected 主 body、progress 定时器回调带 try/catch 降级）；HttpClient 构造显式 timeoutMs。
3. **事件面冻结 diff 审查**：`DownloadEvents`/`NoopDownloadEvents`/`ForwardDownloadEvents` 三声明与 U1.2 版逐字节一致（git diff 无该三段变更）；Index.ets/NewDownloadDialog.ets 零改动。
4. 纯函数 Hypium 本地用例（entry/src/test/PieceAlgo.test.ets，import 路径 `'../main/ets/core/engine/PieceAlgo'`）：
   - **initial_piece**：createInitialPiece → {offset:0,length:-1,downloaded:0,state:0,streamType:0}（:84-92）。
   - **findMaxChunk_threshold**：rem=262144 → null；rem=262145 → 该片 id（`>` 严格）；多片取 rem 最大；并列取 Map 插入序首个；splittingAllowed=false 恒 null（§0-4）。
   - **splitPiece_math**：片 {offset:0,length:4194304,downloaded:0} → 原片 {0,2097152,0}，新片 {2097152,2097152,0,NOT_STARTED}（len=rem/2 整除、offset=offset+length-len）；奇数 rem=1048575 → len=524287（下取整）；原片 downloaded 保留（{length:1000,downloaded:600} → 原片 {length:800,downloaded:600}）；rem==262144 允许分裂（len=131072）；rem==262143 → null（`<` 严格）——**Find/Split 双边界用例**。
   - **continueAdjacentPiece**：邻片 downloaded==0 && offset==position && streamType 同 && offset+length<=maxByteRange → true 且 chunk.length 扩、邻片删除；任一条件破 → false（streamType 异、downloaded>0、不相邻、超 maxByteRange 各一例——**超 maxByteRange 例锁定 D6 不可达论证**）。
   - **inactive 规则**：getInactivePiece 排除在途/Finished/downloaded==length；getInactiveChunkCount **含** downloaded==length 片（源码原貌锁定，D16）；空 Map → count=0/piece=null。
   - **allFinished**：全 FINISHED true；含 NOT_STARTED false；空 Map true。
   - **windowOf/totalDownloadedOf**：{offset:1000,length:500,downloaded:200} → [1200,1499]；Σdownloaded 求和。
   - **sortPiecesByOffset**：乱序输入按 offset 升序稳定输出。
5. 诚实注记（U0.2/U1.1/U1.2 同款）：本设计会话未运行 hvigor 构建与本地单测执行器（设计阶段无代码产物）；用例入库后由编码员实跑记录；taskpool sendData 定时器回调限制（§0-2）与 fileIo 在 taskpool worker 的可用性两项运行时行为待 P2-U1 实测回贴。

### [P] 运行时（手册承载，xdm-probe-verify 机械判定）

1. 主机侧启动测试源：`node docs/probe/P1-U2-download-server.js`（复用指引见手册 §1：绑 0.0.0.0、/big.bin /slow.bin?ms=40 /slow.bin?ms=80 路由）。
2. 构建+安装+拉起 → 探针首页 P2-U1 卡片 → 输入 `http://<主机局域网IP>:8080`（禁 127.0.0.1）→ 运行全部 S1~S5，9 标记齐全。
3. EXPECT 逐条判定：S1 源 206 能力；**S2 maxConcurrent=8（核心验收"8 分段并行日志"）+ piecesCount=16±1 + allSpotsMatch=true（多分片字节正确）**；S3 maxOverlapAcrossSnapshots=0 finalGapCount=0 coverageComplete=true（区间不重叠+全覆盖）；S4 singleBps/segBps>0（吞吐可测）+ratio 观测；S5 activeAfterStop=0（取消排空）+ 恢复后 finalSize/allSpotsMatch2。
4. 分片算法行为对照（verify 附加判定输入，对照 PieceGrabber.cs 逐条）：S2/S3/S5 的 piecesCount/maxConcurrent/pieces 行序列联合覆盖——单 Piece 探测→206→分裂收敛（:307-332）、阈值双边界（:422/:439）、失败重派（:351-403）、取消重派区间不重叠（§3.6）。
5. 验证环境标注：真机优先（吞吐数据真机才有意义），模拟器兜底；结论写回计划（含 §0-2 sendData 降级是否触发、fileIo worker 可用性两项运行时结论）。

## 8. 风险与备注

| 风险 | 缓解 |
|---|---|
| `Task.sendData` 在定时器回调内被平台拒绝（d.ts NOTE；10200023/10200024） | try/catch 捕获即 reportDisabled 降级为完成时回报（§0-2）；分裂节奏由 connected（主 body 发送）承载不受影响；P2-U1 回贴判定降级是否触发并写回计划 |
| 取消-重派的内容竞态误判（§3.6 三支柱任一被编码破坏即数据错位） | 三支柱写进 PieceGrabber/SegmentWorker 文件头注释为审查必查项；S2/S5 的 expectedByteAt 全流确定性字节抽查是错位的直接证据（allSpotsMatch=false → business-code 返修） |
| 快源下 8 并行窗口不可观测（worker 秒下完 262144B 分片） | S2/S5 默认慢源 /slow.bin（40ms/80ms 每 64KB）；EXPECT maxConcurrent ≥4 UNVERIFIED 分支；公网大文件 URL 可替换 |
| worker 内 fileIo/http 不可用（理论低风险：U0.2 S4 已证 http；fileIo 无 Context 依赖） | 错误经结果 JSON errCode 观测（env/business 分流）；不引入探针级兜底伪装成功 |
| 连接风暴（每 connected 触发 createPiece，连接数 O(片数)） | MAX_COUNT 门 + findMaxChunk 262144 阈值天然收敛（4MiB→≤16 片、record≤8）；8 并行后 createPiece 直返 |
| probe-connected 与 probe result 次序互逆 | connected 处理按 pieceId+!init 守卫不依赖 record 存在；result 到达按 record 存在性静默（§3.5） |
| resume() 时 init 已 true 却 pieces 全 Finished/空 | pieces 空 → 转全新 start（Resume :139-143 等价）；全 Finished → 直接 assemblePieces+onFinished（Resume :124-130 等价） |
| P1-U2 归档探针与新引擎不兼容的误报 | §0-8 已登记；verify 遇 P1-U2 重跑日志按归档口径不判 U2.1 回归 |
| 进度平滑度下降（250ms 消息粒度 vs 原版逐块） | UI 呈现 2~4Hz 刷新可接受；onProgress 500ms 门为最终节流；不引入伪造插值 |

—— 完 ——
