# U2.2 分片落盘+断点续传+进度持久化 · 模块设计书

> 单元：U2.2（Phase 2 第 2 单元；探针单元 ID `P2-U2`，slug `u2-2-resume-state-persist`）。
> 来源：xdm-migrate 工作流"模块设计师"角色，2026-09-28。
> 依据：MIGRATION_PLAN §6 决策 4（分片落盘与原版同构：每分片独立临时文件+追加写+完成后顺序拼接；进度持久化 JSON 化替代二进制 chunks.db）+ 决策 10（下载状态 JSON，无需兼容原二进制格式）；UNIT_CATALOG U2.2 行（验证 [A]+[P]）；PROBE_SPEC v1；U2.1 既有面（PieceScheduler/SegmentWorker/PieceAlgo/EngineMath/HttpProtocol/Config 六键/DownloadStore 22 列）；源码研究结论（12 facts + 2 openQuestions）。
> 对照源码（本会话只读核实，未改 resourses/ 下任何文件）：`HTTPDownloaderBase.cs`（:25-29 状态游标初始化、:109-130 Stop【无保存】、:157-195 ContinueAdjacentPiece【:183 保存】、:224-241 PieceDownloadFailed【:231 保存】、:243-266 PieceDownloadFinished【:252+:255 双写】、:268-305 UpdateDownloadedBytesCount【:274-283 2000ms 数据门+游标】、:307-332 CreatePiece【:326 保存】、:430-466 SplitPiece【:457 保存】、:515-526 TicksAndSizeAtResume、:557-618 WriteChunkState/ReadChunkState 二进制字段序、:210-213 GetPieceFile、:544-555 DeleteFileParts）、`SingleSourceHTTPDownloader.cs`（:76-104 Start(bool)、:106-109 SaveForLater、:111-151 Resume、:153-165 SaveChunkState【:158 pieces 空→静默不写】、:174-221 RestoreState【:200-206 双槽读/:214-219 读败吞→FileSize=-1】、:228-293 PieceConnected【:272-275 探测落位→SaveState+SaveChunkState】）、`TransactedIO.cs`（:12 END. 标记、:92-122 ReadStream 双槽读序+完整性门、:159-186 WriteStream 首写/轮换 .1→.3.<guid>/.2→.1/.3→.2）、`DownloadStateIO.cs`（:77-150 {Id}.state 下载级字段——本单元不落对应物，见 D1）、`PieceGrabber.cs`（:159-172 闭窗口未知大小→NonRetriable(NonResumable)、:233-236 OpenOrCreate+Seek(Downloaded)）、`SegmentState.cs:3-7`（枚举序 NotStarted=0/Finished=1/Downloading=2/Failed=3）。
> API 核实（本机 SDK 6.1.1(24)，本会话 grep 于 `D:\Tools\DevEco Studio\sdk\default\openharmony\ets\api\@ohos.file.fs.d.ts`）：`renameSync(oldPath: string, newPath: string): void` :6597（抛 13900001/13900002 等 BusinessError）；`accessSync/unlinkSync/writeSync/readTextSync/openSync/mkdirSync` 均为工程在用 API（PieceGrabber.ets:879/:996/:901、ProbeDownload.ets:831 等本会话读文件核实）。
> 工程现状核实（本会话读文件）：PieceGrabber.ets 1025 行（resume() :208-235 缺 mkdir、三处 SaveChunkState 占位锚 :457/:804/:823、assemblePieces :861-988、deleteTempDir :991-1009、dispatchPiece 分片文件名 `tempDirPath+'/'+pieceId` :356、SegmentWorker 传 `writeStartOffset: piece.downloaded` :357）；Downloader.ets 门面（观测面 :134-149）；Index.ets handleToggle :127-152（**Map 未命中分支按 downloadedBytes>0 分流 resume/start——重启后 DB 行 downloadedBytes 恒 0 → 走 start()，恢复路径不可达，本单元必须改**，DownloadStore.ets:356 注释"downloadedBytes 重启后保持默认值"）；DownloadStore 22 列/六方法；Config 六键（maxSegments 已有）；module.json5 deviceTypes 含 2in1+INTERNET（:7-17）；main_pages.json 仅 Index+ProbeIndex；EntryAbility onCreate Config.init+DownloadStore.initialize（:51-52）；List.test.ets 注册 `pieceAlgoTest()`（追加用例入 PieceAlgo.test.ets 即可，无需改注册文件）。
> **现状段落时效注记**：上行与 §3.3 表内行号均为 **U2.2 编码前基线快照**。本 run 经 AmendWorkflow 续跑（2026-09-28），上一化身编码阶段已把 §1 全部 10 文件落成；本会话按"收敛基线差异审查"口径逐文件核对，**实现与设计书零偏差**，落地行号与门禁实测见 §9（设计落成核实）。

## 0. 冲突与拍板注记（必读）

1. **openQuestion 1 拍板：单一自足 chunks.json（双槽 .1/.2，存 `tempDir/<recordId>/`），不落 {Id}.state 对应物。** 论证：决策 4 只要求 chunks.db JSON 化；{Id}.state 的下载级字段（id/name/size/targetDir/primary_url）在 U1.1 downloads 表 22 列已有对应物且 Index.ets 已在写（onConnected/onProgress/handlePaused 链）；单文件方案崩溃窗口与探针断言更简单（一个工件=一个观测点）；chunks.json 冗余携带 totalSize 使恢复自足（省一次异步 DB 读——引擎恢复路径保持同步纯文件读）。代价：finalUrl/LastModified/Cookies 暂无处存（本引擎 HttpClient 未向主线程回传 finalUrl），登记 D1；行为等价性：每请求重走重定向（+1 跳，源码行为差异见 D1）。若审查推翻要求两工件同构，只需 StateStore 内多一个槽位对，调度器面零改动。
2. **openQuestion 2 拍板：保真——Stop()/暂停/退出不补显式保存。** 本会话逐行核实 HTTPDownloaderBase.cs:109-130 Stop 全函数无 SaveChunkState（StopDownloads→http.Stop() 链路 U2.1 研究已 grep 全库验证）。后果：持久化 downloaded 相对暂停时刻最多陈旧一个 2000ms 数据门窗口（数据流游标 :283，**Stop 不触发**）。探针预期表按容差断言（§6-S3/S4：`staleBytes ≥ 0`、`resumedFromSum ≤ pausedDownloaded`、`firstProgressDownloaded ≥ resumedFromSum`），不要求逐字节等于暂停瞬间值。若审查倾向加显式 Stop 保存=偏离源码行为，须先推翻本条并登记差异（现按源码保真不加）。
3. **U2.1 遗留 mkdir 缺口的处置（红线⑤裁定：属本单元恢复路径本体，非"遗留另修"）**：resume() 现缺 `mkdirSync(tempDirPath)`（对照源码 Resume :119 `Directory.CreateDirectory(state.TempDir)`——U2.1 只做同实例暂停恢复，temp 目录必然存在故未暴露）；U2.2 恢复路径跨进程，temp 目录被清（用户清理/异常）时 worker `openSync` 无父目录直接 DiskError。研究 fact 1 判 medium。修复=恢复路径一行幂等 mkdir（§3.1），不改 U2.1 其余任何行为。
4. **Index.ets 列入改动（目标落点未列但必须）**：不改则"重启后点继续"走 start() 从零重下、孤儿化 temp 分片——断点续传的业务入口不存在，单元验收"杀进程重启续传链路"只对探针成立。改动收敛为 handleToggle Map 未命中分支的 3 行（§5.4）：重启后的历史行一律先 resume()（对照源码 Resume：无状态自退化全新 Start，:139-143），同实例 Map 命中分支零改动。
5. **module.json5 / main_pages.json / Config 不动（有据，非遗漏）**：本会话复核 module.json5——deviceTypes=["phone","2in1"]、requestPermissions=[INTERNET] 已具备；U2.2 无新增系统能力（fileIo 沙箱内读写免权限；force-stop/aa start 是主机侧 hdc 动作非应用能力）。main_pages.json 仅 Index+ProbeIndex，P2-U2 探针页经 ProbeIndex 嵌入不注册路由（U2.1 §0-9 同口径）。Config 六键已含 tempDir/maxSegments，无新键。三文件均不列入 files 清单。
6. **落盘链复核结论（红线②，本会话逐行读 PieceGrabber.ets:861-1009 与 SegmentWorker.ets:153-168）**：分片临时文件追加写（openSync READ_WRITE|CREATE 不带 TRUNC + lseek(writeStartOffset) ≡ PieceGrabber.cs:233-236 OpenOrCreate+Seek(Downloaded,Begin)）与按 Offset 排序拼接（sortPiecesByOffset→盘检→5MB 精确拷贝→deleteTempDir）已在 U2.1 落位且语义正确，**本单元零改动、零重写**；StateStore 工件放 tempDir 内即随 deleteTempDir 自然清理（源码同构：chunks.db 在 TempDir 内、DeleteFileParts :544-555 递归删整目录）。设计仅新增"恢复后 lseek 顺序覆盖陈旧尾部"的幂等论证（§3.5）。
7. **持久化与 500ms 进度门的关系（编码防错点）**：2000ms 状态门是**独立游标**（源码 :26 lastStateSavedAt 构造时初始化、:283 独立判定，与 :287 lastProgressUpdatedAt 互不相干）。本引擎挂在**字节账本更新点**（onProgressMsg/onWorkerResult），**不得**塞进 emitProgressIfDue 内——进度门 500ms 早退会跳过保存判定，违反写入时机语义。两游标永不复用（研究 fact 9）。
8. **state 字段值域**：U2.1 已定 pieces 只赋 SEG_NOT_STARTED/SEG_FINISHED 两值（源码全 Progressive 从未赋 Downloading/Failed，"活跃"以 records 成员资格判定）；持久化沿用该值域，读回不校验 0..3 范围外整数的合法性（源码 `(SegmentState)r.ReadInt32()` 同样不校验，仅要求有限 number——结构门见 §2.2）。

## 1. 目标文件清单（按实现顺序）

| # | 文件 | 新/改 | 职责 | 对外导出 | 依赖 |
|---|---|---|---|---|---|
| 1 | `entry/src/main/ets/core/engine/PieceAlgo.ets` | 改 | 分片算法纯函数层（既有，零 @kit）追加 chunks JSON 序列化/反序列化纯函数：`buildChunksJson(pieces,totalSize)`（字段序对照 WriteChunkState :557-570）与 `parseChunksJson(text)`（结构校验=END. 标记等价完整性门，任一违规返 null 绝不抛）；`RestoredPieces` 结果类 | 追加 `RestoredPieces`、`buildChunksJson`、`parseChunksJson`；既有导出全部不动 | 无（保持零 @kit，Hypium 可直接加载） |
| 2 | `entry/src/main/ets/core/db/StateStore.ets` | 新 | **下载状态 JSON 持久化 IO 壳（对照 TransactedIO.WriteStream/ReadStream 双槽机制 + SaveChunkState/RestoreState 的文件面）**：`saveChunks(pieces,totalSize)` 同步写（staging→renameSync 原子入槽+轮换）、`readChunks()` 双槽读序 .1→.2、`clear()` 清残留槽位/staging；全部 catch 吞+业务日志（hilog domain 0x0000 tag 'StateStore'），绝不抛 | `StateStore`（类；per-download 实例，构造入参 tempDirPath） | #1、@kit.CoreFileKit(fileIo)、@kit.ArkTS(util)、@kit.PerformanceAnalysisKit(hilog)、@kit.BasicServicesKit |
| 3 | `entry/src/main/ets/core/engine/PieceGrabber.ets` | 改 | 分片调度器（既有）四组增量：①StateStore 持有+`saveChunks()`（含 pieces 空静默门 :158）+`saveChunksIfDue()`（2000ms 独立游标）②8 个 SaveChunkState 调用点逐锚落盘（§3.3 表）③resume() 增恢复桥：pieces 空→`restoreState()` 读盘注入（pieces/fileSize/totalSize/splittingAllowed）→仍空→既有 start()；恢复路径补 mkdir（对照 Resume :119）④start() 清残留状态文件 | 既有导出全部不动（`PieceScheduler` 类签名不变） | #1 #2（新增；其余既有依赖不动） |
| 4 | `entry/src/main/ets/pages/Index.ets` | 改 | 主列表页（既有）handleToggle Map 未命中分支：重启后历史行一律 `resume()`（无状态自退化全新 start，对照 Resume :139-143）；Map 命中分支与事件消费方零改动 | —（@Entry 页） | #3（经既有 Downloader 门面） |
| 5 | `entry/src/test/PieceAlgo.test.ets` | 改 | 追加 chunks JSON 纯函数 Hypium 用例（§7-[A]-4，10 条：round-trip/截断/畸形/类型错/缺字段/空 Map/length=-1/state 序数/插入序/空 id） | 既有 `pieceAlgoTest` 内追加 describe（List.test.ets 注册不动） | #1 |
| 6 | `entry/src/main/ets/probe/units/ProbeResume.ets` | 新 | P2-U2 探针页（两段式，§6 步骤表）：会话 A S1~S3 自动（源预检/慢源下载到 2MiB 暂停+快照/状态文件体检+pending 落盘）→force-stop→会话 B S4 手动单步会话（读 pending→DB 行重建→StateStore 直读恢复输入→Downloader.resume()→恢复起点观测→等完成→字节抽查） | `ProbeResume`（struct） | #2 #3（经 Downloader 门面）、../core/ProbeKit+ProbePage、../../core/db/DownloadStore、../../core/Config、./ProbeSegmentLogic(formatSnapshots)、./ProbeDownloadLogic(expectedByteAt/spotOffsetAt/SPOT_OFFSET_COUNT) |
| 7 | `entry/src/main/ets/probe/ProbeIndex.ets` | 改 | PROBE_UNITS 追加 `{unitId:'P2-U2'}` + else-if 追加 `ProbeResume()` | —（@Entry 页） | #6 |
| 8 | `entry/src/main/resources/base/element/string.json` | 改 | 追加探针 3 键（§2.4；纯 JSON 禁尾逗号） | —（资源） | #6 |
| 9 | `docs/probe/PROBE-u2-2-resume-state-persist.md` | 新 | 探针运行手册：P1-U2-download-server.js 复用（/slow.bin?ms=600 慢源参数）+ 两段式 force-stop 重启（AI hdc 自动主轨+人工兜底双轨）+ 主机侧 server 控制台 Range 起点第二证据 + 预期序列表 | —（文档） | #6 |
| 10 | `docs/probe/EXPECT-u2-2-resume-state-persist.json` | 新 | 机器可读预期表（BEGIN+S1~S4+SUMMARY+END；schema 同 EXPECT-u2-1，含容差语义注记 §0-2） | —（JSON） | #9 |

**显式不动的文件**：`module.json5`/`main_pages.json`/`Config.ets`（§0-5）；`SegmentWorker.ets`（落盘链复核通过，零改动）；`Downloader.ets`（门面与事件面冻结，恢复桥在调度器内部）；`DownloadStore.ets`/`RecordMapping.ets`（22 列不动，恢复自足不读库）；`EngineMath.ets`/`HttpProtocol.ets`/`HttpClient.ets`；既有 probe/units 五文件（归档不追改）；`EntryAbility.ets`（onCreate 已挂 Config.init+DownloadStore.initialize，会话 B 冷启动即就绪）。**红线**：`core/**` 不得 import `probe/**`；`PieceAlgo.ets` 保持零 @kit（StateStore 的 IO 全部隔在 db 层）；`StateStore.ets` 不得 import PieceGrabber/Downloader（只依赖 PieceAlgo 纯类型，避免 engine→db→engine 环）。

## 2. 数据模型与表结构（对照源码逐一核对）

### 2.1 chunks.json 文档结构（对照 WriteChunkState/ReadChunkState :557-574 + SegmentState.cs:3-7）

源码二进制字段序 `count + 每片 [key, Id, Downloaded(int64), Length, Offset, State(int), StreamType(int)]`（key 与 Id 同值=片 id，字典键）JSON 化为：

```json
{ "schema": 1, "totalSize": 4194304,
  "pieces": [ { "id": "<uuid>", "downloaded": 123456, "length": 262144,
                "offset": 2097152, "state": 0, "streamType": 0 } ] }
```

| JSON 字段 | 源码字段 | 类型门（parseChunksJson 结构校验，任一违规→null） | 说明 |
|---|---|---|---|
| schema | —（JSON 化新增版本号） | number，恒 1 | 前向兼容锚（决策 10：无需兼容原二进制） |
| totalSize | —（源码在 {Id}.state FileSize） | number（有限） | **恢复自足冗余**：探测值落位后的 totalSize；-1=未知大小（预探测状态） |
| pieces[] | count+逐片 | Array | 空数组合法（读回等价无状态→全新 start，对照 pieces.Count==0 语义） |
| pieces[].id | key+Id | string 非空 | **temp 文件名映射键**（tempDir/<id>，与 dispatchPiece :356 拼法一致，跨重启稳定） |
| pieces[].downloaded | Downloaded | number（有限，≥0 不强制——源码 int64 直读同貌） | 相对片首已落盘字节数（持久化值 ≤ 分片文件实际字节数，§3.5 不变量） |
| pieces[].length | Length | number（有限） | -1=未知（预探测初始片可被持久化，恢复走 NonResumable 终态=源码 :169-170 同貌，§3.4 边界） |
| pieces[].offset | Offset | number（有限） | 文件绝对区间起点 |
| pieces[].state | State(int) | number（有限；**不校验 0..3**——源码 `(SegmentState)r.ReadInt32()` 同样直转） | 枚举序 NotStarted=0/Finished=1/Downloading=2/Failed=3 **不得重排**（实际只写 0/1，§0-8） |
| pieces[].streamType | StreamType(int) | number（有限） | 单源恒 0 |

ArkTS 装配纪律：`PieceDoc`/`ChunksDoc`/`RestoredPieces` 全部 **class**（`JSON.stringify` 序列化类实例自有字段；`JSON.parse(text) as ChunksDoc` 后**逐字段 new EnginePiece() 赋值**入 Map——禁 untyped 对象字面量直投 `Map<string, EnginePiece>`，研究 fact 4）；Map 按数组序插入（恢复后的遍历序=保存序=源码 Dictionary 实践序等价，D16 沿用）。

### 2.2 工件布局与双槽（对照 TransactedIO.cs）

```
<filesDir>/temp/<recordId>/            ← 既有 tempDir（Config.getTempDir()+joinTempDir，跨重启存活：filesDir 非 cacheDir）
  ├─ <pieceId>                         ← 分片临时文件（U2.1 既有，追加写，本单元不动）
  ├─ chunks.json.1                     ← 槽位 1（读序首选；轮换后恒为最新，对照 WriteStream 轮换不变量）
  ├─ chunks.json.2                     ← 槽位 2（上一代完整副本）
  └─ chunks.json.new                   ← staging（写入中工件；永不被读，只经 renameSync 原子入槽）
```

- 源码 `chunks.db` 即存 TempDir（SaveChunkState :159 `TransactedIO.WriteStream("chunks.db", state.TempDir, ...)`），完成收尾 DeleteFileParts 递归删 TempDir 连带清理——**本设计同构**：StateStore 工件全部在 tempDir 内，随既有 deleteTempDir（PieceGrabber.ets:991-1009）自然清理，StateStore 不另设清理入口。
- 崩溃安全不变量（对照 WriteStream :174-186 逐窗口分析）：staging 写入期间两槽皆旧且完整；`rename(new→.2)` 后、轮换前，.1 旧完整+.2 新完整；轮换三步间任一点，`.3.<guid>`/`.1`/`.2` 至少一份完整——**任一时刻至少一个可读完整副本**。JSON 化的完整性门=`JSON.parse 成功+§2.1 结构校验`（≡ 源码 [pos][payload][END.] 标记三检：截断→parse 失败→弃槽取另一份）。
- 源码 WriteStream 原地覆写（OpenOrCreate+Seek(4)）的尾部陈旧字节靠 pos+len 边界忽略；JSON 全文 readTextSync 无边界概念，故写侧改 **staging(TRUNC)+rename 原子换入**（§0 研究授权变通）——半写工件只可能是 staging（从不被读），槽位内容只会被完整文件原子替换。

### 2.3 downloads 表 / DownloadRecord / Config：零改动

恢复自足（chunks.json 含 totalSize）→ 引擎恢复路径不读 DB；DB 行的 downloadedBytes=0（重启读回默认值）不再影响引擎分流（Index.ets 改动后历史行直接 resume()）。六配置键沿用（tempDir/maxSegments/maxRetry/retryDelay/networkTimeout/downloadDir）。

### 2.4 string.json 追加键

| 键 | 值 |
|---|---|
| probe_p2u2_title | 断点续传探针（P2-U2） |
| probe_p2u2_source_hint | 测试源地址（主机局域网 IP，如 http://192.168.1.20:8080） |
| probe_p2u2_restart_hint | S1~S3 跑完后按手册 force-stop 重启，再进本页点 S4（慢源 /slow.bin?ms=600） |

## 3. 关键算法翻译说明

### 3.1 恢复状态机（对照 Resume :111-151 + RestoreState :174-221 逐行）

```
resume()                                      // PieceScheduler.resume() 改造点（既有 :208-235）
  if (running) return
  if (pieces.size === 0):
    restoreState()                            // ← U2.2 新增（对照 :118 RestoreState）
      restored = stateStore.readChunks()      //   双槽 .1→.2，结构门失败→null（对照 :200-206+:214-219 吞→空）
      if (restored === null || restored.pieces.size === 0) return   // 无状态：pieces 保持空
      pieces = restored.pieces                //   注入（源码 pieces = ChunkStateFromBytes(s) 等价）
      totalSize = restored.totalSize
      fileSize = totalSize > 0 ? totalSize : -1
      splittingAllowed = totalSize > 0        //   恢复集仅来自已探测会话；totalSize<=0（预探测/未知大小）禁分裂
    if (pieces.size === 0): start(); return   // :139-143 无状态→全新 Start（含 SaveForLater 等价语义，研究 fact 10）
  mkdirSync(tempDirPath, true) 吞异常          // ← U2.2 补（对照 :119；temp 被清时 worker DiskError 预防，§0-3）
  ……既有体不动：generation++/游标重置/onStarted/allFinished→assemblePieces 直接收尾
    （:124-130）/init=true+createPiece()（:135-137）——恢复后全部请求非首请求（闭窗口 206 强检），
    resume() 既有 TicksAndSizeAtResume 等价（:221-225 Σdownloaded 基线）零改动
```

- **同实例 stop→resume（会话内暂停恢复）不重读盘**：pieces 非空直接走既有体（内存态恒 ≥ 盘上态）；源码 Resume 恒重读（其 SaveChunkState 落后 ≤2s 的陈旧值同样正确——前缀覆盖幂等，§3.5）。登记 D5。
- **恢复后首个动作链**：resume→createPiece→retryFailedPieces→dispatchPiece(闭窗口)：Range=`closedRangeHeader(offset+downloaded, offset+length-1)`（既有 :348）；206 强检+Content-Range 三检（既有 :566-585）；worker `writeStartOffset=piece.downloaded`（既有 :357）lseek 覆盖写。**恢复路径零新增请求构造代码**（研究 fact 6）。

### 3.2 双槽写入/读取算法（StateStore.ets，主线程同步 IO）

```
saveChunks(pieces, totalSize):                // 对照 WriteStream 公共入口 :159-186；绝不抛
  text = buildChunksJson(pieces, totalSize)   // 纯函数（#1）
  staging = dir+'/chunks.json.new'
  openSync(staging, WRITE_ONLY|CREATE|TRUNC) → writeSync(fd, text) → closeSync
                                              // TRUNC：清掉上次崩溃残留的半成品 staging（staging 从不被读）
  if (!accessSync(slot1)):
    bestEffortUnlink(slot1); renameSync(staging, slot1)          // 首写（对照 :162-165）
    return
  bestEffortUnlink(slot2); renameSync(staging, slot2)            // 新内容先原子入 .2（.1 全程完整）
  name3 = dir+'/chunks.json.3.'+util.generateRandomUUID()        // 对照 :170（guid 防撞）
  renameSync(slot1, name3); renameSync(slot2, slot1); renameSync(name3, slot2)
                                              // 轮换后最新恒在 .1（对照 :171-173；读序偏好依据）
  // 任一步抛错：catch 吞 + hilog 'StateStore'（对照外层 catch→Log.Debug→return false，调用方本就忽略返回值）

readChunks(): RestoredPieces | null           // 对照 ReadStream 公共入口 :92-103
  for slot in [slot1, slot2]:                 // .1 先（最新）→ .2（上一代）
    if (!accessSync(slot)) continue
    try { text = readTextSync(slot) } catch { continue }         // 对照单文件 catch→false→试另一槽
    restored = parseChunksJson(text)          // END. 标记等价完整性门（§2.1）
    if (restored !== null) return restored
  return null                                 // 两槽全败=无状态→全新 start

clear(): for f in [slot1, slot2, staging]: try unlinkSync(f) catch 吞
```

`bestEffortUnlink`：rename 前防御性 unlink 目标（catch 吞）——不依赖 renameSync 对已存在目标的替换语义（d.ts :6597 未文档化 replace 行为；unlink 窗口内另一槽仍完整，不变量不破）。

**量级论证**：16 片 × ~120B ≈ 2KB 文本，全 sync API 主线程直写；节流 ≥2s/次+事件点保存，单次 <1ms 级——无可观测卡顿，不引入 TaskPool/异步化（与源码同为调用线程直写）。

### 3.3 SaveChunkState 写入时机全集（8 调用点逐锚落盘；红线③）

| # | 源码锚 | 语义 | PieceGrabber.ets 落点（现行号） | 动作 |
|---|---|---|---|---|
| 1 | HTTPDownloaderBase.cs:183 | ContinueAdjacentPiece 吸收后 | onWorkerResult 闭窗口完成 absorbed=true 分支（:712-718，D6 运行时恒 false 的 parity 调用点） | `saveChunks()` |
| 2 | :231 | PieceDownloadFailed | pieceDownloadFailed（:823 既有占位锚处） | `saveChunks()` |
| 3 | :252 | PieceDownloadFinished 标记后 | pieceDownloadFinished（:804 既有占位锚处，state=Finished+records.delete 之后） | `saveChunks()` |
| 4 | :255 | 全完成拼装前**双写** | pieceDownloadFinished 的 allFinished 分支、assemblePieces() 调用前 | `saveChunks()`（保真双写，字节无变化也写——源码同貌） |
| 5 | :283 | **数据流 2000ms 门**（:26 游标构造时初始化，独立于 :287 500ms 进度门） | onProgressMsg（:536 `piece.downloaded=abs` 后、emitProgressIfDue 前）+ onWorkerResult 终值账本（:701 后、emitProgressIfDue 前）——两处字节账本更新点 | `saveChunksIfDue()`：`now - lastStateSavedAt > 2000 → saveChunks(); lastStateSavedAt = now`（**先存后置游标，与 :283-284 次序一致；游标只增不重置**） |
| 6 | :326 | CreatePiece 末尾 | createPiece（:457 既有占位锚处） | `saveChunks()` |
| 7 | :457 | SplitPiece 分裂后（源码在算法函数内嵌） | createPiece 内 splitPiece 返回非 null 后（纯函数层禁 IO，保存移至调用点——与 #6 构成分裂轮双写，对齐源码 :457+:326 双保存） | `saveChunks()` |
| 8 | SingleSourceHTTPDownloader.cs:275 | PieceConnected 探测落位后（SaveState 之后） | probeConnected 探测值落位+init/splittingAllowed 赋值后（:619 之后、events.onConnected 前；SaveState 对应物=downloads 表由 Index 写，引擎侧无动作） | `saveChunks()` |

- `saveChunks()` 私有封装：`if (pieces.size === 0) return; stateStore.saveChunks(this.pieces, this.totalSize);`（**pieces 空静默门对照 :158**）。
- `lastStateSavedAt: number` 新字段，构造时 `Date.now()` 初始化（对照 :26 字段初始化；start()/resume() **不重置**——源码仅构造初始化，久停后恢复首笔数据即触发保存，保真）。
- **stop() 不加保存**（§0-2 拍板）；**start() 增 `stateStore.clear()`**（mkdir 后、初始片建立前——关闭源码 [Start, 首次 SaveChunkState] 崩溃窗口内恢复到上一会话残留 pieces 的歧义路径，登记 D4；孤儿分片文件仍不清，源码同貌，deleteTempDir 兜底）。

### 3.4 恢复边界行为（对照源码逐条，均为零新代码的既有行为复核）

| 边界 | 源码行为 | 本引擎路径（既有） |
|---|---|---|
| 恢复集含 length=-1 片（预探测状态被持久化，如探测连接失败触发 :231 保存） | init=true 后重派闭窗口 → PieceGrabber.cs:169-170 NonRetriable(NonResumable,"Resume not supported") | dispatchPiece :328-330 同终态（U2.1 已落位） |
| 恢复集全 Finished（暂停点恰在收尾后） | Resume :124-130 直接 AssemblePieces+OnFinished | resume() :227-231 直接 assemblePieces（需 totalSize 冗余供盘检/精确拷贝——§2.1 totalSize 存在的第二个理由） |
| 服务器内容变更（Content-Range total ≠ 恢复 fileSize） | Connect :198-202 IsFileChangedOnServer→InvalidResponse | onConnectedMsg :573-578 同终态 |
| SaveForLater 项（只建初始片不启动，无 chunks.db） | Resume 因 pieces 空走全新 Start | 无 chunks.json→restoreState 空→start()（队列调度本体属 U3.1 不做） |
| 恢复后速度/进度基线 | TicksAndSizeAtResume :515-526（ΣDownloaded 重算、ticks=now） | resume() :221-225 既有同构，注入后自动生效 |

### 3.5 字节正确性论证（重启续传幂等；探针 EXPECT 判定依据）

不变量链：worker 写盘同步先于回报（SegmentWorker onChunk `writeSync→written+=n`，progress 定时器 250ms 后才发）→ 主线程 `piece.downloaded` ≤ 该 worker 已写盘字节 → 持久化 `downloaded` ≤ 分片文件实际字节（保存时点快照，文件此后只增）。恢复时 worker `openSync(READ_WRITE|CREATE 不 TRUNC)+lseek(persisted downloaded)`：文件尾部 `(persisted, 实际]` 区间的陈旧字节被新 worker 以**同绝对偏移同源内容顺序覆盖**（前缀覆盖幂等——U2.1 三支柱②同论证，跨进程版）；assemblePieces 每片只读 `piece.length` 字节（支柱③），超出收缩后 length 的陈旧尾部恒被忽略。已知边界（与源码同貌，不修）：状态文件在而分片文件被删 → lseek 超 EOF 写出 sparse 零洞 → 成品错位（FileStream.OpenOrCreate+Seek 同病；探针 allSpotsMatch 会暴露，登记 §8 风险表）。

### 3.6 线程模型映射（决策 2 增量）

| 原版（C#） | 本引擎（ArkTS） |
|---|---|
| SaveChunkState 在 grabber 线程回调内、rwLock.EnterWriteLock 下写盘 | 主线程单点：全部 8 调用点在调度器消息/结果处理路径上，**无锁**（pieces Map 只主线程触碰，U2.1 纪律沿用） |
| TransactedIO 同步 FileStream 写（调用线程直写） | StateStore 同步 fileIo（主线程；≤2KB+≥2s 节流，§3.2 量级论证） |
| Resume 在新 Thread 内跑 RestoreState | resume() 主线程同步读盘（readTextSync ×≤2）后走既有异步派发——UI 线程一次 <1ms 级读，不引入 Worker/TaskPool |
| RestoreState 崩溃容错（ReadStream 双槽+catch 吞） | readChunks 双槽+结构门返 null（异常不上抛，§3.2） |
| {Id}.state 经 Config.DataDir 全局目录 | 不落（D1）：下载级字段在 downloads 表，恢复自足字段在 chunks.json |

## 4. 有意差异清单（对照源码/计划，含已定降级项）

| # | 差异 | 依据 |
|---|---|---|
| D1 | **单工件 chunks.json 替代源码两工件**（chunks.db+{Id}.state）：下载级字段（id/name/size/targetDir/primary_url）由 U1.1 downloads 表承载；finalUrl/LastModified/Cookies 不持久化——引擎未回传 finalUrl，每请求重走重定向（行为等价+1 跳）；LastModified 无 If-Range 消费方（决策 3：仅 Content-Length 校验），Cookies 本单元无注入源 | §0-1 拍板（研究 openQuestion 1 建议）；决策 4/10 |
| D2 | **JSON 完整性门替代 END. 二进制标记**：[pos][payload][END.] 三检 → `JSON.parse 成功+结构校验`；写侧 staging(TRUNC)+renameSync 原子入槽替代 WriteStream 原地覆写（readTextSync 全文读无 pos 边界可忽略尾部陈旧字节，半写只可能发生在从不被读的 staging）；轮换序 .2 入新→.1→.3.<guid>→.2→.1/.3→.2、读序 .1→.2、最新恒 .1 全部保真 | §2.2/§3.2；renameSync d.ts :6597 本会话核实 |
| D3 | **SplitPiece 内嵌保存移到调度器调用点**（源码 :457 在算法函数内；PieceAlgo 纯函数层禁 IO——U2.1 既定分层）；保存时机/频次不变（分裂轮 #7+#6 双写对齐源码 :457+:326） | U2.1 分层红线延续 |
| D4 | **start() 先 clear() 残留状态文件**：源码 Start 仅 mkdir 幂等不清 chunks.db，崩溃窗口 [Start, 首次 SaveChunkState(#8)] 内重启会恢复上一会话残留 pieces（跨会话分片集歧义）；本引擎关闭该窗口。孤儿分片文件仍不清（源码同貌，完成收尾 deleteTempDir 兜底） | §3.3；研究 fact 10 建议 |
| D5 | **同实例 stop→resume 用内存 pieces，不重读盘**（源码 Resume 恒 RestoreState 重读，≤2s 陈旧）：内存态恒 ≥ 盘上态，前缀覆盖幂等（§3.5）保证两者字节等价；跨进程 resume 才走 RestoreState 等价路径 | U2.1 resume() 既有语义延续+本单元 §3.1 |
| D6 | SaveForLater/队列调度本体不落（U3.1）："无状态→全新 start"规则天然覆盖其恢复语义 | 研究事实 10；UNIT_CATALOG 边界 |
| D7 | 恢复路径补 `mkdirSync(tempDirPath,true)`（对照 Resume :119）：U2.1 resume() 缺失（同实例恢复 temp 必在，未暴露）；跨进程恢复 temp 被清时是 worker DiskError 前置因——研究判 medium，按红线⑤裁定属本单元恢复路径本体修复 | §0-3 |
| D8 | state 持久化沿用 0/1 值域（源码全 Progressive 从未赋 Downloading/Failed）；读回不校验枚举范围（源码 int 直转同貌，结构门只验有限 number） | U2.1 fact 2 延续；§0-8 |
| D9 | Index.ets handleToggle Map 未命中分支改为一律 resume()（原按 downloadedBytes>0 分流，重启后 DB 行该字段恒 0 → 恢复不可达）；同实例分支零改动 | §0-4；DownloadStore.ets:356 读回默认值本会话核实 |
| D10 | 沿用 U2.1 已登记差异（D1 线程模型/D2 消息化/D3 探测 abort/D4 整流/D5 取消重派/D9 stop 清 records/D11 SessionExpired 延后/D16 Map 序等），本单元不重开；U1.2/U2.1 其余遗留 low（缺头响应偏严/worker 盘错时序/循环 import 登记等）不在本单元修复范围（红线⑤，无 high/medium 级新增） | 单元约束⑤ |

**非差异的保真声明**（审查勿误判为遗漏）：stop()/暂停/退出**不**补显式保存（源码 Stop :109-130 无 SaveChunkState，本会话逐行核实）——最旧持久化状态 ≤2s 陈旧是源码语义，探针按容差断言（§0-2/§6）。

## 5. 各文件实现要点（可直接照做的接口面）

### 5.1 core/engine/PieceAlgo.ets（改，+3 导出，零 @kit 保持）

- `export class RestoredPieces { pieces: Map<string, EnginePiece> = new Map<string, EnginePiece>(); totalSize: number = -1; }`
- `export function buildChunksJson(pieces: Map<string, EnginePiece>, totalSize: number): string`——内部 `PieceDoc`/`ChunksDoc` class（字段 §2.1，**字段序=源码写序：id→downloaded→length→offset→state→streamType**，注释锚 :557-570）；Map.forEach 按插入序产出数组；`JSON.stringify(doc)`。
- `export function parseChunksJson(text: string): RestoredPieces | null`——整体 try/catch 返 null；`JSON.parse(text) as ChunksDoc` 后结构校验（§2.1 类型门列）；逐片 `new EnginePiece()` 六字段赋值入 Map（数组序=插入序）；`pieces` 非数组/任一片违规/schema≠1 → null；空 pieces 数组合法（空 Map 返回，调用方按无状态处理）。

### 5.2 core/db/StateStore.ets（新）

- `export class StateStore { constructor(tempDirPath: string) }`；文件名常量模块级私有：`chunks.json` 基名，槽位/Staging 拼法 §2.2。
- `saveChunks(pieces: Map<string, EnginePiece>, totalSize: number): void` / `readChunks(): RestoredPieces | null` / `clear(): void`——算法 §3.2 逐行；`bestEffortUnlink(path)` 私有（accessSync→unlinkSync，全 catch 吞）；`name3` 用 `util.generateRandomUUID()`。业务日志 hilog domain 0x0000 tag `'StateStore'`（绝不 [XDM_PROBE]）。**禁止** import PieceGrabber/Downloader/probe/**。

### 5.3 core/engine/PieceGrabber.ets（改，四组增量）

- 新字段：`private readonly stateStore: StateStore`（构造 `new StateStore(this.tempDirPath)`，置于 tempDirPath 赋值后）；`private lastStateSavedAt: number = Date.now();`
- 新私有方法：`saveChunks()`（pieces 空静默门+委托）、`saveChunksIfDue()`（§3.3-#5 次序：先 saveChunks 后置游标）、`restoreState()`（§3.1 注入逻辑，**绝不抛**）。
- 8 调用点逐锚替换（§3.3 表——其中 :457/:804/:823 三处既有占位锚注释删除换成实调用；probeConnected 落位点、splitPiece 调用点、absorbed 分支、双写点为新增行）；onProgressMsg/onWorkerResult 在 `piece.downloaded = abs` 之后、`emitProgressIfDue()` 之前插 `saveChunksIfDue()`。
- resume() 头部插恢复桥+mkdir（§3.1）；start() 在 mkdirSync 之后插 `this.stateStore.clear()`。
- 文件头注释更新：U2.1 头部"SaveChunkState ← 全部调用点空注释锚不落盘（U2.2，D8）"改为已落盘说明+8 锚行号表；追加恢复桥/幂等论证（§3.5）摘要。**其余（assemblePieces/deleteTempDir/dispatchPiece/消息面/三支柱注释）一字不动**。

### 5.4 pages/Index.ets（改，3 行）

- handleToggle :127-152：Map 未命中分支构造 Downloader 后，将"`record.downloadedBytes > 0 → resume() 否则 start()`"改为**一律 `target.resume()`**（注释锚：对照 Resume :139-143 无状态自退化全新 Start；重启后 DB 行 downloadedBytes 恒 0，旧分流使恢复路径不可达——D9）。Map 命中分支（会话内暂停/失败重试语义）与事件消费方零改动。

### 5.5 entry/src/test/PieceAlgo.test.ets（改，追加 describe）

- 追加 `describe('chunksJson', ...)` 于 `pieceAlgoTest()` 内（List.test.ets 注册不动）；用例清单 §7-[A]-4。

### 5.6 probe/units/ProbeResume.ets（新，P2-U2）

- 页面形态：`autoStart=false` + TextInput 测试源（U1.2/P2-U1 同构）+ 步骤表 S1~S3 `autoRun:true` + S4 `autoRun:false`（手动单步会话，ProbeDownload S9 同款按钮）。
- S4 会话门（S9 先例）：`runStep('S4')` 入口 `if (this.probeKit.getLines().length > 1) return;`（自动会话触达手动步跳过，不发标记行）。
- pending 工件：`<filesDir>/probe-P2-U2-persist.json`（会话 A S3 写、会话 B S4 读；重跑覆盖）。载荷 class `ResumePending { recordId/name/targetDir/url/pausedDownloaded/sourceBytes: ...; pieceRows: PersistPieceRow[] }`，`PersistPieceRow { id/offset/length/downloaded }`（S2 暂停时 getPieceSnapshots 转储；S4 与 StateStore 读回值按 id 对拍 offset/length）。
- 引擎驱动只走 `Downloader` 公开面（start/stop/resume/isRunning/getPieceSnapshots/activeSegmentCount/describePieces）+ `DownloadStore`（add/getDownloadById）+ `StateStore`（**只读** readChunks——恢复输入观测，不写）；事件采集 ForwardDownloadEvents 事实袋（ProbeSegment SegmentFacts 同构）；会话代际守卫 runId+isCurrent 每 await 后先过。
- 慢源参数：S2/S4 用 `/slow.bin?ms=600`（每 64KB 块延迟 600ms；8 连接合计 ≈850KB/s，2MiB 阈值 ≈2.4s 到达——**确保暂停前 2000ms 数据门至少触发一次**，持久化值非零且滞后可观测；server 端 ms 参数任意整数合法，本会话读 P1-U2-download-server.js:100-110 核实，零改动复用）。
- 字节抽查复用 `expectedByteAt/spotOffsetAt/SPOT_OFFSET_COUNT`（ProbeDownloadLogic import；与 server makeSlice 同值锚）。

## 6. 探针步骤设计（P2-U2 两段式，对应手册/EXPECT）

会话模型：**A（自动 S1~S3）→ force-stop 杀进程 → B（手动 S4 单步会话）**。行格式 `[XDM_PROBE][P2-U2][<步骤>] key=value`；每步骤恰一行 <1500B；值只写观测事实不写 PASS/FAIL（判定在 EXPECT/verify）。

| 步骤 | autoRun | 操作 | 观测点（emit key=value） | 预期锚（EXPECT 判定核心） |
|---|---|---|---|---|
| BEGIN | — | begin(unitId, filesDir) | runId、filesDir | 与 END 按 runId 配对（A/B 两会话各自独立） |
| S1 源能力预检 | ✔ | 自建 requestInStream GET {base}/big.bin + Range: bytes=0-（不走引擎，P2-U1 S1 同构） | sourceUrl status contentLength rangeSupported chunks | status=206 contentLength=4194304 rangeSupported=true（不成立→env 分流） |
| S2 慢源下载到阈值并暂停 | ✔ | 新 record（id=`probe-p2u2-<runIdA>`，url={base}/slow.bin?ms=600）→ store.add → Downloader.start → pollUntil(lastDownloaded≥2097152 或 failed, 90s, 30ms) → stop() → pollUntil(!isRunning && activeSegmentCount===0) → 快照 | recordId addOk pauseLanded pausedDownloaded（onPaused Σ） pausedPieces（formatSnapshots 行） pausedPieceCount activeAfterStop elapsedToPauseMs | pauseLanded=true；0<pausedDownloaded<4194304；pausedPieceCount≥2（分裂已发生）；activeAfterStop=0（取消排空，U2.1 S5 锚复用）；elapsedToPauseMs>2000（保证数据门触发过的间接证据） |
| S3 状态文件体检+pending 落盘 | ✔ | `new StateStore(joinTempDir(Config.getTempDir(), recordId))`：readChunks() 直读 + accessSync 两槽 + 逐片 statSync(tempDir/<id>).size 与持久化 downloaded 对拍；写 pending JSON | slot1Exists slot2Exists savedPieces savedTotal savedLine staleBytes（=pausedDownloaded−Σsaved.downloaded） minFileOverPersisted pendingWritten | slot1Exists=true；savedTotal=4194304；**staleBytes≥0**（容差上界不判 FAIL：慢源 600ms 下 ≤2s 窗 ≈ ≤1.7MiB，EXPECT 记 UNVERIFIED 分支说明——§0-2 拍板）；**minFileOverPersisted=true**（持久化 downloaded ≤ 分片文件实际字节——§3.5 不变量直接观测）；pendingWritten=true |
| —— | 手册动作 | `hdc shell aa force-stop com.example.xdmharmony` → `hdc shell aa start -b com.example.xdmharmony -a EntryAbility --ps page probe` → 探针首页 → P2-U2 → 点 S4（人工兜底：最近任务划掉+桌面图标拉起，同一入口） | ——（主机侧第二证据：P1-U2 server 控制台逐请求打印 Range，恢复后各分片起点应=offset+持久化 downloaded） | —— |
| S4 重启续传+成品字节抽查 | ✘（手动单步） | 读 pending → store.getDownloadById 重建 record（DB 行跨重启存在性兼证）→ `new StateStore(tempDir).readChunks()` 观测恢复输入 → new Downloader(record, listener) → **resume()**（恢复桥入口）→ 捕获首个 onProgress 的 downloadedBytes + 首批 getPieceSnapshots → 等 onFinished（120s）→ spotChecks（5 点含 pausedDownloaded 邻域）| pendingFound rowFound restoredPieces restoredSum restoredLine offsetsUnchanged（pending.pieceRows 与 restored 按 id 对拍 offset/length） resumed firstProgressDownloaded finished finalSize tempDirGone spotChecks allSpotsMatch | pendingFound=true rowFound=true；**offsetsUnchanged=true（各分片 offset/length 跨重启不变——断点续传结构锚）**；**resumedFromSum>0 且 ≤ pausedDownloaded（S2 值）**；**firstProgressDownloaded ≥ restoredSum**（恢复真实从断点继续而非从零——fresh-restart 缺陷的直接判别式）；finished=true finalSize=4194304 tempDirGone=true；**allSpotsMatch=true（续传产物字节正确性）** |
| SUMMARY | — | end(ok) 聚合 | 每步关键键 | 会话 A 3 段 / 会话 B 1 段 |
| END | — | ok/steps/elapsedMs | ok=true steps=3（A）/1（B） | BEGIN/END 配对无孤儿 |

失败形态：步骤异常 catch emit errCode/errMessage（1390000x 盘错/2300028 超时/102000xx taskpool）；S2/S4 引擎失败快速 emit `engineFailed=true errCode=<N> errMessage=<...>`（如恢复集含 length=-1 片→errCode=2 NonResumable 是源码同貌边界，EXPECT 记 Known-behavior 分支而非静默）。

## 7. 单元验收测试要点

### [A] 静态门禁（编码员每轮自跑）

1. `hvigorw assembleHap` 零 error 零新 warning；对照 arkts-grammar-standards 自查：禁 any/解构/正则字面量；`PieceDoc/ChunksDoc/RestoredPieces/PersistPieceRow` 全 class 装配（JSON.parse 产物只经 `as` 后逐字段搬运，禁 untyped 字面量直投 Map/Array）；`catch (e)` 无注解+`e as BusinessError`；Map 遍历 forEach；StateStore 全部方法显式返回类型且**不抛**（最外层 try/catch）。
2. **改动面 diff 审查**：PieceGrabber.ets 除 §5.3 四组增量外零变更（assemblePieces/deleteTempDir/dispatchPiece/SegmentWorker 消息面一字不动——红线②）；SegmentWorker.ets/Downloader.ets/DownloadStore.ets/RecordMapping.ets/EngineMath.ets/HttpProtocol.ets/module.json5/main_pages.json/Config.ets 零 diff（§0-5/§1）；Index.ets 仅 handleToggle Map 未命中分支。
3. **8 调用点核对表**（红线③）：逐锚 grep `saveChunks`——恰 8 个调用点+1 个 IfDue 封装（§3.3 表行号对照）；`lastStateSavedAt` 全文件恰一处赋值族（构造+IfDue 内）；emitProgressIfDue 内**无**保存调用（§0-7）。
4. 纯函数 Hypium 本地用例（PieceAlgo.test.ets 追加，import 路径既有）：
   - **roundtrip_16**：16 片（offset/length 覆盖 [0,4194304)、downloaded 混 0/部分/满、state 混 0/1）→ buildChunksJson → parseChunksJson → 逐片六字段相等且 Map 插入序=原序。
   - **roundtrip_totalsize**：totalSize=4194304 与 -1 两例往返。
   - **empty_map**：空 Map → build → parse → 空 Map（等价无状态语义）。
   - **truncated_json**：合法产物截半 → null。
   - **garbage_text**：非 JSON 文本 → null。
   - **field_type_error**：downloaded 为字符串（手工拼 JSON）→ null；缺 offset 字段 → null；id 空串 → null。
   - **initial_piece_doc**：{offset:0,length:-1,downloaded:0,state:0} 往返合法（预探测状态可持久化——§3.4 边界前提）。
   - **state_ordinal**：state=1 往返仍 1（枚举序不重排锚）。
   - **schema_gate**：schema=2 → null（版本门）。
   - **nonfinite_gate**：length 为 1e999（parse 后 Infinity）→ null（有限数门）。
5. 诚实注记（U0.2/U1.1/U2.1 同款 + 本单元续跑更新）：原设计会话未运行构建/单测（当时无代码产物）；**2026-09-28 续跑会话已实跑 `devecocli build`（= hvigor assembleHap）→ BUILD SUCCESSFUL in 4m56s，零 error**，唯一 warning 在 ProbeHttp.ets:230（U0.2 归档文件，git status 改动面外，非本单元新增）+ SignHap 跳过签名（build-profile.json5 无 signingConfigs 主机侧常态）。**Hypium 本地单测执行器本会话未运行**——§7-[A]-4 十条 chunksJson 用例已入库（PieceAlgo.test.ets:294-424）但执行记录仍由编码员/审查会话回贴。StateStore 的 IO 行为（rename 轮换/双槽回退/crash 窗口）无法在本地 Hypium 验证（fileIo 属 @kit）——由 P2-U2 运行时探针承载。

### [P] 运行时（手册承载，xdm-probe-verify 机械判定）

1. 主机侧 `node docs/probe/P1-U2-download-server.js`（复用零改动；ms=600 由探针 URL 参数携带）。
2. 会话 A：构建+安装+拉起 → P2-U2 卡片 → 填源 → 运行全部 S1~S3（BEGIN+S1~S3+SUMMARY+END 恰 7 行）。
3. force-stop + 二次拉起（AI hdc 主轨 / 人工兜底双轨，手册 §2 命令逐条）→ P2-U2 → 点 S4（单步会话恰 4 行）。
4. EXPECT 逐条判定：S1 源 206；S2 暂停落地+取消排空；S3 双槽存在+**minFileOverPersisted=true**+staleBytes≥0（容差）；S4 **offsetsUnchanged=true+firstProgressDownloaded≥restoredSum+finalSize+allSpotsMatch=true**（断点续传三联锚）；两 BEGIN/END 配对。
5. 主机侧交叉证据：server 控制台恢复后各请求 Range 起点 vs S4 restoredLine 各片 offset+downloaded 逐片人工核对（手册 §4 表格模板）。
6. 验证环境标注（真机优先）；结论写回计划（含 staging/rename 轮换是否实测无异常）。

## 7bis. 单元验收对照（UNIT_Catalog U2.2 行）

- 编译过 → [A]-1/2。
- 杀进程重启续传链路可观测 → [P]-2~4（S4 offsetsUnchanged/firstProgress/finalSize 三联 + server Range 交叉证据）。
- 拼接产物字节正确 → [P]-4 allSpotsMatch=true（5 抽查点含暂停邻域；expectedByteAt 确定性流，任一分片错位即 x）。
- 每分片 offset 观测 → S2 pausedPieces/S3 savedLine/S4 restoredLine 三拍对账（同一 formatSnapshots 格式）。

## 8. 风险与备注

| 风险 | 缓解 |
|---|---|
| renameSync 对已存在目标的替换语义未文档化（d.ts :6597 无 replace 说明） | 写侧 bestEffortUnlink 目标后再 rename（§3.2）；不变量"至少一槽完整"在任何 unlink/rename 交错下成立（§2.2 窗口分析）；P2-U2 S3 slot1Exists/savedLine 实测回贴 |
| 主线程同步写盘卡顿（理论低：≤2KB×≥2s 节流） | 量级论证 §3.2；如实测 jank 再评估异步化（登记后续，不在本单元） |
| 状态文件在而分片文件被删 → sparse 零洞 → 成品错位 | 与源码同貌（FileStream.OpenOrCreate+Seek 同病，§3.5），不修；探针 allSpotsMatch 暴露后按 env 分流（用户清理 temp） |
| 恢复集含 length=-1 片 → NonResumable 终态被误判缺陷 | §3.4 边界表+源码 :169-170 锚；EXPECT Known-behavior 分支 |
| 久停后 lastStateSavedAt 不重置致恢复首笔即存（源码同貌） | 非缺陷（保真）；审查对照 :26 字段初始化语义 |
| S4 手动步骤被自动会话触达 | S9 先例会话门（lines>1 跳过，ProbeDownload.ets:100-104 本会话核实同款） |
| 慢源 ms=600 下暂停阈值 2MiB 未达（网络抖动） | pollUntil 90s 上限+pauseLanded=false → UNVERIFIED 换源分支（手册 §5） |
| P1-U2/P2-U1 归档探针与本单元无交集（探针页累积安装） | 无相互影响；P2-U2 新增 S4 手动步不改既有页面 |
| pending JSON 与 DB 行不一致（add 失败后仍跑 S2） | S2 addOk=false 时快速 emit 收束；S4 rowFound=false 分支 |

## 9. 设计落成核实（design-as-built，2026-09-28 续跑会话）

> **运行上下文**：本 run（dwfrun-86bedf52）经 AmendWorkflow 续跑时本次 ask 的【本单元】/【目标落点】字段为空，单元参数已自父 run（dwfrun-b24f3036）args_json 原文恢复：U2.2 断点续传；source=HTTPDownloaderBase.cs+SingleSourceHTTPDownloader.cs；target=StateStore+PieceGrabber+PieceAlgo+probe+docs/probe/；红线①恢复路径重建调度器②复用 assemblePieces③写入时机对照原版④探针 P2-U2 两段式⑤U1.2/U2.1 遗留 low 不在本单元范围。与 run 名称、既有设计书、工作树三方互证一致，无矛盾。**本会话按"收敛基线差异审查"口径核对已落成实现（非重写），结论：实现与设计书零偏差**；后续对照审查员按本设计书+§9 落地行号核对即可，无需重新推导。

### 9.1 工作树与门禁（本会话实际运行的命令）

- `git status --short`（XdmHarmony 仓）：M `PieceAlgo.ets`/`PieceGrabber.ets`/`Index.ets`/`ProbeIndex.ets`/`string.json`/`PieceAlgo.test.ets`；?? `core/db/StateStore.ets`/`probe/units/ProbeResume.ets`/`docs/probe/PROBE-u2-2-resume-state-persist.md`/`docs/probe/EXPECT-u2-2-resume-state-persist.json`——§1 十文件全部在树（另有台账 NIGHT-RUN.md 修改，非本单元交付物；设计书本体已随提交 7585907 入库）。
- 编译门禁 [A]-1 实跑：`devecocli build` → **BUILD SUCCESSFUL in 4m56s，零 error**；唯一 ArkTS:WARN 在 `ProbeHttp.ets:230`（U0.2 归档文件，改动面外，非本单元新增）；`SignHap` 跳过签名（build-profile.json5 无 signingConfigs，真机签名另备）。**Hypium 单测执行器未运行**（§7-[A]-5 诚实注记）。

### 9.2 逐文件落成核对（行数为 landed 现行，本会话逐文件读）

| 文件（§1 序） | landed 行数 | 核对结论（关键落点现行行号） |
|---|---|---|
| PieceAlgo.ets | 348 | buildChunksJson :280-294 / parseChunksJson :302-343（结构门：schema==1/totalSize 有限/pieces 数组/逐片六字段有限+id 非空；state 不校验 0..3=D8；全 try/catch 返 null 绝不抛）/ RestoredPieces :273-276；PieceDoc 字段序 id→downloaded→length→offset→state→streamType（:254-261）；零 @kit 保持（头部 :4-6 声明） |
| StateStore.ets | 134 | saveChunks :40-73（staging WRITE_ONLY\|CREATE\|TRUNC :45-46→首写 .1 :53-57 或 .2 入 :59-63+三步轮换 :64-67）/ readChunks :78-99（.1→.2 序+结构门过则返）/ clear :104-109 / bestEffortUnlink :119-125 / existsQuiet :127-133；全方法 catch 吞+hilog 0x0000 tag 'StateStore'（无 [XDM_PROBE]）；import 面仅 PieceAlgo 纯类型+@kit 四件（禁 import 红线遵守） |
| PieceGrabber.ets | 1127 | stateStore 字段 :152（构造 :187 `new StateStore(this.tempDirPath)`）+lastStateSavedAt :155（构造初始化，start/resume 不重置）；start() clear() :217；resume() 恢复桥 :238-246（restoreState→空则 start）+mkdir :249-253+基线重置 :258-262+allFinished→assemble :264-267+init=true+createPiece :270-271；saveChunks 空静默门 :307-312；saveChunksIfDue :318-324（先存后置游标）；restoreState :331-344（注入 pieces/totalSize/fileSize/splittingAllowed 四量，绝不抛）；三支柱/assemblePieces :963-1090/deleteTempDir :1093-1111 与 U2.1 一字未动 |
| Index.ets | 401 | handleToggle :130-150：Map 未命中分支建 Downloader 后 `target.resume()`（:149，注释锚 D9 :124-129 全文在位）；Map 命中/事件消费方零改动 |
| PieceAlgo.test.ets | 424 | describe('chunksJson') :294-424 恰 10 条：roundtrip_16/roundtrip_totalsize/empty_map/truncated_json/garbage_text/field_type_error/initial_piece_doc/state_ordinal/schema_gate/nonfinite_gate——与 §7-[A]-4 清单逐一对应；List.test.ets 注册不动（:15 import+:25 pieceAlgoTest()） |
| ProbeResume.ets | 738 | 步骤表 :65-70（S1~S3 autoRun+S4 手动）；S4 会话门 :124-129（lines>1 跳过）；S1 :149-210（自建 requestInStream Range bytes=0-）；S2 :215-280（id=probe-p2u2-<runId>、ms=600、2MiB 阈值 :52、取消排空轮询 :256-257、快照转储 :261）；S3 :286-337（StateStore 只读直读 :292-293、双槽存在性 :294-295、minFileOverPersisted :479-495、staleBytes :301、pending 写 :303-319/:534-550）；S4 :344-426（pending 读回+结构门 :552-586、DB 重建 :359、resume() :383、firstProgressDownloaded :443-445、engineFailed 快速收束 :401-408、tempDirGone :410-415、5 点抽查 :591-638、offsetsMatch :498-511）；ResumePending/PersistPieceRow class 逐字段装配 :566-581 |
| ProbeIndex.ets | — | P2-U2 卡片 :26+import :13+路由分支 :102-103 |
| string.json | — | probe_p2u2_title/source_hint/restart_hint 三键 :152-161 |
| PROBE md / EXPECT json | 164 / 42 | 与 §6 步骤表一致：会话 A 恰 6 行/会话 B 恰 4 行、staleBytes 容差语义（只判 ≥0）、Known-behavior 分支（errCode=2 NonResumable）、server Range 对账表、环境差异分支表 |

### 9.3 §3.3 表"现行号"→ landed 行号对照（8 锚）

| 锚 | §3.3 编码前快照行 | landed 行 |
|---|---|---|
| ① absorbed 后保存 | :712-718 | :806-810（continueAdjacentPiece :806→saveChunks :810） |
| ② pieceDownloadFailed | :823 | :925 |
| ③ pieceDownloadFinished 标记后 | :804 | :902 |
| ④ 拼装前双写 | 同③分支 | :906（allFinished 分支、assemblePieces :907 之前） |
| ⑤ 2000ms 门（先存后置） | :536 | :624（onProgressMsg，piece.downloaded=abs :621 后、emitProgressIfDue :625 前）+ :795（onWorkerResult 终值账本 :792 后、:799 前） |
| ⑥ createPiece 末尾 | :457 | :542 |
| ⑦ splitPiece 调用点 | :457 占位 | :531（createdId!==null 分支首行） |
| ⑧ probeConnected 落位后 | :619 后 | :710（splittingAllowed 赋值 :707 后、onConnected :713 前） |

grep 核实：emitProgressIfDue（:940-956）体内无任何保存调用；saveChunksIfDue 仅两挂点（:624/:795）。

### 9.4 源码复核（本会话只读 sed/grep resourses/xdm，未改源文件）

- `grep -n "SaveChunkState()"`：恰 8 调用点——HTTPDownloaderBase.cs:183/:231/:252/:255/:283/:326/:457 + SingleSourceHTTPDownloader.cs:275（另有抽象声明 :90 与 override 实现 SingleSource :153）——红线③锚表与源码逐一吻合。
- HTTPDownloaderBase.cs:109-130 `Stop()`：全函数无 SaveChunkState（sed 核实）——§0-2 拍板前提成立。
- TransactedIO.cs:92-122 ReadStream（.1→.2 序、pos 越界/标记缺失/异常弃槽）+ :147-186 WriteStream（OpenOrCreate+Seek(4) 原地写；首写 .1，否则写 .2→Move .1→.3.<guid>→Move .2→.1→Move .3→.2）——§3.2 轮换序逐行吻合。
- HTTPDownloaderBase.cs:557-590 WriteChunkState/ReadChunkState：字段序 key/Id/Downloaded/Length/Offset/(int)State/(int)StreamType；`(SegmentState)r.ReadInt32()` 不校验范围——§2.1/D8 吻合；SegmentState.cs:3-7 枚举序 NotStarted/Finished/Downloading/Failed 吻合。
- SingleSourceHTTPDownloader.cs:76-109 Start(bool)/SaveForLater（SaveForLater=Start(false)：只建初始片+SaveState，**无 SaveChunkState**）——D4/D6 前提吻合；:111-151 Resume（RestoreState→CreateDirectory→Count!=0→OnStarted→AllFinished?AssemblePieces+return : init=true+CreatePiece；else Start()；catch→OnFailed）；:174-221 RestoreState（chunks.db ReadStream 失败 catch 吞→state.FileSize=-1、pieces 保持空）；:268-276 PieceConnected（state.Url=FinalUri→state.FileSize=ResourceSize??-1→SaveState→SaveChunkState）。
- HTTPDownloaderBase.cs:274-300：`ticks - lastStateSavedAt > 2000 → SaveChunkState(); lastStateSavedAt = ticks`（**先存后置**）+ 500ms 进度门独立在后——§3.3-⑤/§0-7 吻合。
- PieceGrabber.cs:169-170：`piece.Length == -1 && !IsFirstRequest → throw NonRetriableException(NonResumable,"Resume not supported")`——§3.4 边界行吻合。

### 9.5 配置面核实（§0-5"三文件不动"成立）

module.json5 deviceTypes 含 "2in1"（:7-9）+ requestPermissions ohos.permission.INTERNET（:16）；main_pages.json 仅 pages/Index+probe/ProbeIndex；Downloader.ets 门面 resume/isRunning/describePieces/getPieceSnapshots/activeSegmentCount 透传齐备（:120-147）——本单元无需任何配置文件改动，files 清单维持 §1 原样。

—— 完 ——
