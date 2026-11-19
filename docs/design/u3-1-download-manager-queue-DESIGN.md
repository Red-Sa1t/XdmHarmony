# U3.1 队列调度+并发上限 · 模块设计书

> 单元：U3.1（Phase 3 第 1 单元；探针单元 ID `P3-U1`，slug `u3-1-download-manager-queue`）。
> 来源：xdm-migrate 工作流"模块设计师"角色，2026-09-28。
> 依据：MIGRATION_PLAN §6 决策 2（主线程单点管理）/决策 10（配置 preferences 存储）+ §7 Phase 3（并发上限 3+排队优先级）；UNIT_CATALOG U3.1 行（验证 [A]+[P]，"排队正确（PROBE 记录并发数不超 3）"）；PROBE_SPEC v1；U2.x 引擎纪律（事件面冻结/挂起防御/主线程单点/超时预算语义固化）；源码研究结论（10 facts + 2 openQuestions）。
> 对照源码（本会话只读核实，未改 resourses/ 下任何文件）：`ApplicationCore.cs`（:35-40 liveDownloads/queuedDownloads 双集合+ActiveDownloadCount、:126-186 StartDownload 三态判定+AddItemToTop 次序、:250-324 ResumeDownload 幂等守卫/门判定/四 DownloadType 分支、:347-380 StopDownloads 双分支、:415-457 DownloadFinished、:459-477 DownloadFailed、:479-498 DownloadCancelled、:500-514 HandleProbeResult、:562-565 IsDownloadActive、:567-595 ProcessNextQueuedItem、:614-627 DetachEventHandlers【:622 += 笔误证实】）；`Collections/GenericOrderedDictionary.cs`（:48-58 Add 已存在键不改位、:96-102 Remove、GetEnumerator 按 keys List 序yield——插入序=FIFO 语义根基）；`Config.cs:104`（`public int MaxParallelDownloads { get; set; } = 3;`——任务书 :119 勘误证实：:118 是 TempDir）+ `IO/ConfigIO.cs:178-179/:392`（字面量键 "MaxParallelDownloads" Int32 读写）；`IApplication.cs:201-204`（DownloadStartType{Waiting,Stopped,Scheduled}）；`Application.cs:37-68`（AddItemToTop：Status=startType==Waiting?Waiting:Stopped **落库** + AddNewDownload、:115-159 DownloadFinished、:233-241 SetDownloadStatusWaiting **只改 UI 不落库**）；`DownloadEntries.cs:64-67`（DownloadStatus{Downloading,Stopped,Finished,Waiting}）；`SingleSourceHTTPDownloader.cs:106-109`（SaveForLater→Start(false)）；`UI/NewDownloadDialogUIController.cs:95/:100`（"立即下载"钮恒 startImmediately=true 无队列、"加入队列"钮 startImmediately=false+queueId）；`QueueManager.cs:11-13/:76-110/:112-121`（命名队列/queues.db/RemoveFinishedDownload——U3.1 不实现，兼容锚见 §0-7）。
> 工程现状核实（本会话读文件）：`Config.ets` 六键（downloadDir/tempDir/networkTimeout/maxRetry/retryDelay/maxSegments，setter 模式 :115-144 内存赋值+putSync+flushQuietly）；`Index.ets`（startNewDownload :100-122 **store.add 后立即 new Downloader+start 直跑**、handleToggle :130-150 自建 Downloader 无门判定、handleFinished :199-221 `downloaders.delete(id)`、事件消费方 :154-234、engineEvents 惰性建 :110-113/:137-139）；`Downloader.ets:21-28` DownloadEvents 六回调（onPaused≡Cancelled 语义，U2 冻结面）；`PieceGrabber.ets`（**onPaused 唯一发射点 :314 在 stop() 内**、onStarted :227 start/:281 resume **同步派发**、onFailed :953、onFinished :1089、resume() :237-290 对全新记录恢复桥空→start() 自退化）；`DownloadTypes.ets:18-23` Waiting=3 已存在；`DownloadRecord.ets` 工厂 startWaiting 参数 :81-99 + COLD-F1 确定性 id 约定 :78-80；`DownloadStore.ets` add/updateStatus/markAsFinished/queryAll 已备；`ProbeKit.ets`（begin/emit/end/isCurrent :75-152）、`ProbePage.ets`（步骤编排 + runSingle）、`ProbeResume.ets`（探针单元驱动模型同构参照）、`ProbeIndex.ets:20-27/:91-104`（PROBE_UNITS 注册表+else-if 分支）；`main_pages.json`（仅 Index+ProbeIndex）；`module.json5`（deviceTypes ["phone","2in1"]+INTERNET 已具备，本会话读文件核实）；`List.test.ets`（testsuite 注册表）；`hvigorw test` 脚本化单测入口（U2.3 设计书 §3.7 实测接通）。

## 0. 冲突与拍板注记（必读）

1. **openQuestion 1 拍板：接受 stopIntent 簿记方案**（事件面零改动前提下唯一无歧义解）。论证：U2 事件面无独立 Cancelled，onPaused≡Cancelled；本会话 grep 证实 onPaused **唯一发射点是 Downloader.stop()**（PieceGrabber.ets:314），onFinished/onFailed 各自独立——因此"运行中实例的 onPaused"必然源自 stop 调用，无自发暂停。manager 簿记规则：`stopOne(id)` 命中 liveMap 时记 `stopIntent.add(id)` 再 `downloader.stop()`；wrapper.onPaused 到达时 `stopIntent.delete(id)`（吸收 stop fire-and-forget 的异步时差）→ `liveMap.delete(id)`（返回值 wasLive 即去重守卫）→ delegate → wasLive 才 `dequeueOne()`。三重防御：stopIntent（意图确认）+ liveMap 成员资格（去重，onFailed/onPaused 竞态双到只补位一次）+ 队列空 no-op。**排队项取消不经事件**：`stopOne(id)` 未命中 liveMap 而命中 queueMap → 直接摘除不补位（对照 StopDownloads :360-369 分支），UI/DB 回声经 ManagerHooks.onQueuedCancelled 可选钩子（Index 本单元不传——UI 无排队取消触点，探针 S4 传计数钩子）。
2. **openQuestion 2 拍板：Waiting 落库语义分路径，均零新增 DB 调用。** 研究结论的"入队一律不落库"表述需精化——本会话逐行核实原版两条入队路径持久化行为不同：①**新建路径**（NewDownloadDialogUIController.cs:95 恒 startImmediately=true → startType=Waiting → AddItemToTop :55 `Status=startType==Waiting?Waiting:Stopped` **随 AddNewDownload 落库 Waiting(3)**）；②**resume 排队路径**（ResumeDownload :264-269 → SetDownloadStatusWaiting Application.cs:233-241 **只改 UI 不落库**，DB 行保持 Stopped）。ArkTS 侧对齐：①Index 工厂参数 startWaiting false→true（Waiting 经既有 store.add 天然落库，零新代码）；②manager.resumeOne 超门只置 `record.status=Waiting`（@Observed 内存态）不调 updateStatus。重启后两路均不自动续跑（liveDownloads/queuedDownloads 原版纯内存，ArkTS 同构）——U2.2 既有"重启不自动续跑"行为兜底，Index 查询面零改动。
3. **任务书"暂停/恢复由用户操作直接作用于运行中实例不占调度决策"与源码有出入，按源码执行并在此记录。** 源码事实：运行中暂停→Cancelled 事件→**释放槽位并 ProcessNextQueuedItem 补位**（ApplicationCore.cs:479-497）；恢复→ResumeDownload **过门判定，超门入队**（:262-270）。即暂停/恢复与调度强耦合。本设计按源码 1:1（stopOne 的 live 分支经 onPaused 补位；resumeOne 过门）；任务书语句按"暂停/恢复不需要专用调度语义，走通用事件钩子/门判定"理解。差异已在 §4-D12 登记。
4. **Index.ets 列入改动（目标落点已列，改动收敛为五处）**：①import ②aboutToAppear 顶部挂 `manager.init(buildEngineEvents())` ③startNewDownload 工厂 startWaiting=true + 删直接 new Downloader 三行改 manager.admitNew ④handleToggle 改 manager 分派（自建 Downloader 逻辑移入 manager）⑤handleFinished 删 `downloaders.delete(id)` 一行（downloaders/engineEvents 两字段随之删除）。**事件消费方 handleStarted/Connected/Progress/Paused/Failed 与 buildEngineEvents 零改动**——事件面零破坏由"wrapper 包裹转发"达成（§3.2）。
5. **module.json5 / main_pages.json 不动（有据，非遗漏）**：本会话复核 module.json5——deviceTypes 含 2in1、requestPermissions=[ohos.permission.INTERNET] 已具备；U3.1 无新增系统能力（队列调度纯内存状态机，不涉网络参数/后台任务/剪贴板/深链）。main_pages.json 仅 Index+ProbeIndex，P3-U1 探针经 ProbeIndex 嵌入不注册路由（U2.1 §0-9 同口径）。两文件均不列入 files 清单。
6. **DownloadEvents 事件面冻结手段=wrapper 包裹而非绕开**：Downloader.ets 三声明（DownloadEvents/NoopDownloadEvents/ForwardDownloadEvents）逐字节不动；manager 内部 `ManagedEvents implements DownloadEvents` 持 delegate（Index 的 ForwardDownloadEvents 或探针的事件袋），固定次序"簿记→delegate→补位"转发六回调。消费方（Index/探针）感知不到 wrapper 存在。
7. **QueueManager.cs 不实现（兼容锚，后续单元不返工）**：命名队列清单/queues.db 二进制 V1/Schedule 属 Phase 4 Queue 页与 U3.2 Scheduler；本单元 manager **内置单默认队列**（queueMap+queueIds 即 "Default queue" 的内存态）。队列持久化若后续做，走 preferences JSON（决策 10 同构），不复刻二进制 queues.db。DownloadFinished 的 QueueManager.RemoveFinishedDownload 随之无对应物（无命名队列可摘）。
8. **ResumeDownload :261 幂等守卫的 return 语义**：原版批量 ResumeDownload 遇重复项 `return` 中止整批（非 continue，原版如此）；manager API 为单 id 入参天然无批量路径，守卫实现为单点幂等 return（resumeOne 对已 live/queued 的 id 直接 return），源码行为差异登记 §4-D8。
9. **manager.init(events) 采用"后到者接管"（替换 delegate）语义**：manager 为应用级单例，Index 与探针页都会 init——先到事件袋固化会把事件错路由到已销毁页面。约定：每次 init 重建 wrapper 替换 delegate（幂等廉价）；Index 在 aboutToAppear 首行 init，探针在 S1 init。代价：探针会话结束后 Index 需重新 aboutToAppear（正常拉起即触发）才接管事件——写入手册。

## 1. 目标文件清单（按实现顺序）

| # | 文件 | 新/改 | 职责 | 对外导出 | 依赖 |
|---|---|---|---|---|---|
| 1 | `entry/src/main/ets/core/engine/QueueAlgo.ets` | 新 | 调度纯函数层（零 @kit，Hypium 直接加载）：`QueueOrderEntry` 数据类（id+priority）、`pickNextQueuedId(entries)`（priority DESC、插入序 ASC，严格 > 比较首见胜出=默认全 0 时严格 FIFO）、`effectiveMaxParallel(raw)`（<1 归一为 1 的防御钳制） | `QueueOrderEntry`、`pickNextQueuedId`、`effectiveMaxParallel` | 无（保持零 @kit） |
| 2 | `entry/src/main/ets/core/Config.ets` | 改 | 追加第 7 键 `maxParallelDownloads`（KEY/DEFAULT=3/字段/getter/setter/init 读取行，模式与既有六键逐字一致） | 追加 `DEFAULT_MAX_PARALLEL_DOWNLOADS`、`getMaxParallelDownloads()`、`setMaxParallelDownloads()`；既有导出不动 | 无 |
| 3 | `entry/src/main/ets/core/engine/DownloadManager.ets` | 新 | **全局下载管理器单例**：liveMap（运行实例）+queueMap/queueIds（FIFO 队列）双集合、门判定、三事件补位、stop 双分支、stopIntent 簿记、ManagedEvents wrapper（钩子注入）、观测 getter 面（探针消费） | `DownloadManager`（init/admitNew/resumeOne/stopOne/isLive/isQueued/liveCount/queuedCount/activeDownloadCount/queueOrder）、`ManagerHooks` | #1 #2、既有 Downloader/DownloadRecord/DownloadTypes/Config/hilog |
| 4 | `entry/src/main/ets/pages/Index.ets` | 改 | 主列表页接入 manager（§0-4 五处收敛改动；事件消费方零改动） | —（@Entry 页） | #3 |
| 5 | `entry/src/test/QueueAlgo.test.ets` | 新 | QueueAlgo 纯函数 Hypium 用例（§7-[A]-2，10 条：FIFO/优先级/并列/负值/空表/单元素/钳制四例） | `queueAlgoTest` | #1 |
| 6 | `entry/src/test/List.test.ets` | 改 | testsuite 注册 `queueAlgoTest()` | —（测试入口） | #5 |
| 7 | `entry/src/main/ets/probe/units/ProbeQueue.ets` | 新 | P3-U1 探针页（§6 步骤表）：S1 门参数+基线+源预检 → S2 快速提交 6 观测即时集合 → S3 拥挤窗口轮询 maxConcurrent+补位序列 → S4 停止/取消路径（排队取消不补位+队列空 stop 无补位） | `ProbeQueue`（struct） | #2 #3、../core/ProbeKit+ProbePage、../../core/db/DownloadStore、../../core/Config、../../core/engine/Downloader(ForwardDownloadEvents)、../../model/DownloadRecord |
| 8 | `entry/src/main/ets/probe/ProbeIndex.ets` | 改 | PROBE_UNITS 追加 `{unitId:'P3-U1'}` + else-if 追加 `ProbeQueue()` | —（@Entry 页） | #7 |
| 9 | `entry/src/main/resources/base/element/string.json` | 改 | 追加探针 2 键（§2.5；纯 JSON 禁尾逗号） | —（资源） | #7 |
| 10 | `docs/probe/PROBE-u3-1-download-manager-queue.md` | 新 | 探针运行手册：P1-U2-download-server.js 零改动复用（/slow.bin?ms=300 慢源构造拥挤）+ 服务器启动指引（复用 P1-U2 手册口径）+ 预期序列表 | —（文档） | #7 |
| 11 | `docs/probe/EXPECT-u3-1-download-manager-queue.json` | 新 | 机器可读预期表（BEGIN+S1~S4+SUMMARY+END；schema 同 EXPECT-u2-2） | —（JSON） | #10 |

**显式不动的文件**：`module.json5`/`main_pages.json`（§0-5）；`core/engine/Downloader.ets`（事件面冻结红线，wrapper 在 manager 内部）；`components/NewDownloadDialog.ets`（onConfirm 签名不变）；`core/db/DownloadStore.ets`/`core/db/RecordMapping.ets`（22 列不动，零新 DB 调用）；`model/DownloadRecord.ets`/`model/DownloadTypes.ets`（工厂/枚举已备）；`core/engine/PieceGrabber.ets`/`SegmentWorker.ets`/`PieceAlgo.ets`/`EngineMath.ets`；`core/net/HttpClient.ets`；`entryability/EntryAbility.ets`（onCreate 已挂 Config.init）；既有 probe/units 七文件（归档不追改）。**红线**：`core/**` 不得 import `probe/**`；`DownloadManager.ets` 零 DownloadStore（DB 写全在 Index 事件消费方，U2.x 分层纪律）、零 probe import、零 [XDM_PROBE] 输出（业务日志 hilog domain 0x0000 tag 'DownloadManager'）。

**U2.3 谱系 D25 热修豁免注记（R1-F3 登记，2026-09-28）**：HEAD 08cfc8a 之后与本单元编码窗口重叠的 7 处工作树改动——`PieceGrabber.ets`（COLD-F1 热修：小文件 ≤256KiB 探测零派发时对探测片直派闭窗窗口，防 running=true 永挂）、`PieceAlgo.ets`/`PieceAlgo.test.ets`（注释锚点）、`.gitignore`（拼行修复）、`docs/design/u2-3-fidelity-matrix.md`、`docs/design/u2-3-engine-fidelity-DESIGN.md`、`NIGHT-RUN.md`——已由主会话按其自述**单独提交**（`e720b7a` 热修 + `d73bee6` 审查收口，提交信息明示"跨红线授权 D25"），归属 U2.3 谱系，不在 U3.1 改动面；热修分支对 4MiB 探针源不可达（splittingAllowed 且 findMaxChunk 非空），不影响 U3.1 调度行为与探针确定性。U3.1 对上述 7 文件零改动，事件面冻结无损（Downloader.ets git diff 为空实测）。

## 2. 数据模型与表结构（对照源码逐一核对）

### 2.1 manager 内存双集合（对照 ApplicationCore.cs:35-40 + GenericOrderedDictionary.cs）

```ts
// DownloadManager.ets 内部（对照 liveDownloads/queuedDownloads，:35-36）
private liveMap: Map<string, LiveSlot> = new Map();        // 运行中实例
private queueMap: Map<string, QueuedEntry> = new Map();    // 排队项（成员资格 O(1)）
private queueIds: string[] = [];                           // 队列插入序（=GenericOrderedDictionary 的 keys List）
private stopIntent: Set<string> = new Set();               // §0-1 簿记（stop 已发起未回声）

class LiveSlot {                      // 对照 KeyValuePair<IBaseDownloader, bool>（:303 值元组）
  downloader: Downloader;
  nonInteractive: boolean = false;    // 预留（原版控制进度窗口显隐，Phase 4 消费）
  constructor(downloader: Downloader) { this.downloader = downloader; }
}
class QueuedEntry {                   // 对照 queuedDownloads 值 bool（:264/:147）+ 优先级预留
  record: DownloadRecord;             // 内存引用（补位时 new Downloader 的原料，免 DB 回读）
  priority: number = 0;               // 预留：源码无优先级（grep 验证），U3.1 恒 0
  nonInteractive: boolean = false;    // 预留：ResumeDownload(nonInteractive) 第二参（:251）
  constructor(record: DownloadRecord) { this.record = record; }
}
```

| ArkTS 结构 | 源码对应物 | 关键同构点 |
|---|---|---|
| `queueMap`+`queueIds` 双结构 | `GenericOrderedDictionary`（Dict+List） | Add 已存在键不改位（:50-54 `if(!ContainsKey) keys.Add`）→ enqueue 幂等；Remove 同步双删（:96-102）；`First()`=keys[0] 最旧项 |
| `liveMap` | `Dictionary<string, KeyValuePair<IBaseDownloader,bool>>` | 仅 get/has/set/delete/size，**不遍历**（ArkTS 禁 for..in，双结构法天然规避） |
| `stopIntent` | （无对应物——U2 事件面 onPaused 合流语义的簿记解，§0-1） | Set<string>（工程先例 PieceAlgo.ets:200） |
| `activeDownloadCount()` | `ActiveDownloadCount = live.Count+queued.Count`（:40） | 排队也算活跃 |
| `isLive/isQueued` | `IsDownloadActive`（:562-565）双 ContainsKey | 探针/拨动按钮观测面 |

**不落盘**：双集合纯内存（原版同貌）——重启即清空，配合 §0-2 的"重启不自动续跑"。**无新表/无新列**：downloads 表 22 列零改动；queues.db 无对应物（§0-7）。

### 2.2 状态机映射（record.status × 调度状态；对照 DownloadEntries.cs:64-67 + IApplication.cs:201-204）

```
新建（Index.startNewDownload）
  工厂 startWaiting=true → status=Waiting(3)【随 store.add 落库，对照 AddItemToTop :55+64】
  → manager.admitNew：
      门过（liveMap.size < max）→ launchStart → onStarted → Downloading(0)
      门挡（liveMap.size >= max）→ 入队，status 保持 Waiting(3)（已落库，行显示排队）
恢复（Index.handleToggle → manager.resumeOne）
  DB status 原值（Stopped(1) 或重启后的 Waiting(3)）
  → 门过 → launchResume → onStarted → Downloading(0)
  → 门挡 → 入队 + record.status=Waiting(3)【仅 UI 内存，不落库，对照 SetDownloadStatusWaiting :233-241】
补位（dequeueOne）→ launchResume → onStarted → Downloading(0)
完成 onFinished → Index.handleFinished → Finished(2) + markAsFinished + 双列表迁移（既有零改动）
失败 onFailed / 暂停 onPaused → Index.handlePaused/Failed → Stopped(1) + updateStatus（既有零改动）
排队取消 stopOne(queued 分支) → 摘除 + record.status=Stopped(1)【仅 UI 内存】+ hooks.onQueuedCancelled
```

DownloadStartType{Waiting,Stopped,Scheduled}（:201-204）的 ArkTS 对应物=工厂 startWaiting 布参（Scheduled 由 U3.2 Scheduler 消费）；DownloadStatus 枚举四值 DownloadTypes.ets:18-23 已有，零改动。**manager 不写任何 status 列**（写库仍全在 Index 消费方）。

### 2.3 Config 第 7 键（对照 Config.cs:104 + ConfigIO.cs:178-179/:392）

| 项 | 值 | 锚 |
|---|---|---|
| 键名 | `'maxParallelDownloads'` | 源码字面量 "MaxParallelDownloads"（ConfigIO.cs:178）；ArkTS 侧沿用既有六键 camelCase 工程约定 |
| 默认值 | `DEFAULT_MAX_PARALLEL_DOWNLOADS = 3` | Config.cs:104 `= 3` |
| 类型/读写 | number，Int32 同构（ConfigIO.cs:179 ReadInt32/:392 WriteInt32） | readNumber/writeNumber 既有私有方法 |
| getter/setter | `getMaxParallelDownloads()` / `setMaxParallelDownloads(value)`（内存赋值+putSync+flushQuietly） | Config.ets:115-144 既有模式逐字一致 |
| 运行中改值 | 无热生效语义——只影响后续门判定（原版同貌：下拉改值后下一次门判定读新值） | ConfigIO 无事件通知机制 |

### 2.4 downloads 表 / DownloadRecord / API 面：零改动

22 列 DDL、rowFromRecord/recordFromRecord、add/updateProgress/updateStatus/markAsFinished/queryAll 均不动（本会话读 DownloadStore.ets:32-67 核实）。排队项的 DB 投影：新建路径 status=3（工厂+add 天然写入）；resume 排队路径 DB 行不变。RecordData 15 字段接口不动；QueuedEntry/LiveSlot 为 manager 模块内运行时结构，不落库。

### 2.5 string.json 追加键（base/element，纯 JSON 禁尾逗号）

| 键 | 值（base） |
|---|---|
| `probe_p3u1_title` | `P3-U1 队列调度探针` |
| `probe_p3u1_source_hint` | `测试源地址（主机局域网 IP，禁 127.0.0.1）` |

## 3. 关键算法翻译说明

### 3.1 门判定与新建入队（对照 StartDownload :126-186 逐行）

```
admitNew(record)                                    // 对照 StartDownload(http,targetDir,startImmediately=true,…)
  守卫：wrapper 未建 → 业务日志+return（Index aboutToAppear 先 init，§0-9）
  门判定：liveMap.size >= effectiveMaxParallel(Config.getMaxParallelDownloads())
    是 → enqueue(new QueuedEntry(record))           // 对照 :144-147 queuedDownloads.Add(id,false)
    否 → launchStart(record)                        // 对照 :155-181
enqueue(entry)：queueIds.push(id) + queueMap.set(id, entry)   // 对照 GenericOrderedDictionary.Add（已存在键不改位→先 has 门保幂等）
launchStart(record)：const dl = new Downloader(record, this.wrapper)
  liveMap.set(record.id, new LiveSlot(dl))          // 对照 :157 liveDownloads.Add 先于 Start
  dl.start()                                        // 对照 :180 download.Start()（fire-and-forget）
```

次序红线：**AddItemToTop（UI 行+落库）先于门后动作**——源码 :150 在 :155-181 前；ArkTS 侧由 Index 承担：`store.add.then(ok → unshift(record) → manager.admitNew(record))`，行先入列、admitNew 后行状态被事件翻转为 Downloading（门过）或保持 Waiting（门挡）。门不含排队数（源码 :262 只数 liveDownloads）——**排队多深都不改变"运行=3"**。

### 3.2 三事件补位与 ManagedEvents wrapper（对照 DownloadFinished/Failed/Cancelled :415-498 + ProcessNextQueuedItem :567-578）

wrapper 六回调转发规则（固定次序：**簿记→delegate→补位**；源码三处理器均为"Detach→liveDownloads.Remove→UI/DB 收尾→ProcessNextQueuedItem"同构，Failed 处理器 Remove 先于 UI :466-467、Finished 处理器 UI 先于 Remove :422-428——单线程下 UI 与簿记的相对次序不可观测，补位恒最后是唯一可观测不变量）：

```
onStarted/onConnected/onProgress → 纯 delegate（manager 零簿记）
onPaused(id, offset)  → stopIntent.delete(id); wasLive = liveMap.delete(id)
                        → delegate; if (wasLive) dequeueOne()
onFinished(id, …)     → wasLive = liveMap.delete(id) → delegate; if (wasLive) dequeueOne()
onFailed(id, …)       → wasLive = liveMap.delete(id) → delegate; if (wasLive) dequeueOne()
```

- `wasLive` 守卫=去重锚：onFailed 与 onPaused 竞态双到（引擎极端时序）只补位一次；孤儿事件（id 已不在 liveMap）不触发补位。
- onPaused 不经 stopIntent 命中判定也按 Cancelled 补位（wasLive 足够）——stopIntent 是意图确认与时差吸收（§0-1），不改变结果。
- **补位一次恰取一个**（ProcessNextQueuedItem :567-578 每次只 `First()` 一个，不递归不清空）：3 个完成事件=3 次补位。

```
dequeueOne()                                        // 对照 ProcessNextQueuedItem :567-578 + ResumeDownload :250-324
  queueIds.length === 0 → return                    // 关机/keep-alive 尾分支为降级项（§4-D5）
  projection = queueIds → QueueOrderEntry[]（indexed for，Map 不遍历）
  nextId = pickNextQueuedId(projection)             // §3.4；null 兜底 return
  entry = queueMap.get(nextId); removeFromQueue(nextId)   // 对照 :571-572 先摘除
  liveMap.size >= effectiveMaxParallel(…) → enqueueBack(entry)（队尾，=源码 Remove 后再 Add 的尾插 :264）+ return
  launchResume(entry.record)                        // 对照 :576 ResumeDownload 单项
launchResume(record)：const dl = new Downloader(record, this.wrapper)
  liveMap.set(record.id, new LiveSlot(dl)); dl.resume()
```

**补位路径用 resume()、新建即时路径用 start()**（对照 :322 `liveDownloads[item.Key].Key.Resume()` vs :180 `download.Start()`）：排队项补位对全新记录经 U2.2 恢复桥自退化 start（PieceGrabber.ets:241-248 pieces 空→start()），对曾暂停的记录正确续传——两语义由一个 resume() 覆盖，与源码 ResumeDownload 单一入口同构。

### 3.3 stop 双分支与 stopIntent 簿记（对照 StopDownloads :347-380）

```
stopOne(id)
  live = liveMap.get(id)
  live !== undefined → stopIntent.add(id); live.downloader.stop(); return
      // 对照 :352-356 http.Stop()；源码注释掉的 liveDownloads.Remove(:356) 不复刻——移除交给事件（wrapper.onPaused）
  queueMap.has(id) → entry=queueMap.get(id); removeFromQueue(id)
      entry.record.status = DownloadStatus.Stopped（仅 UI 内存）
      hooks?.onQueuedCancelled?.(id)                // 可选回声（Index 本单元不传）
      return                                        // 不补位（:360-369 无 ProcessNextQueuedItem）
  两边未命中 → return（幂等：按钮双击/竞态无害）
```

运行中 stop 的完整链：stopOne → stopIntent.add → Downloader.stop()（fire-and-forget）→ 引擎取消在途 Task → onPaused(Σdownloaded) 异步到达 → wrapper（§3.2 onPaused 分支）→ Index.handlePaused 置 Stopped + 落库（既有）→ 补位。**stop 不等补位**：补位在事件回声时点，非 stopOne 调用时点。

### 3.4 取队首：FIFO+优先级（对照 GenericOrderedDictionary.cs:48-58/:96-102 → QueueAlgo.pickNextQueuedId）

源码语义：插入序 List+Dict，Add 已存在键不改位，First()=最旧项——**严格 FIFO**（研究 fact 1 已验证源码无优先级）。ArkTS 翻译为纯函数（O(n) 单趟，严格 `>` 首见胜出=并列取最旧，与"priority DESC、插入序 ASC"字典序一致）：

```
pickNextQueuedId(entries: QueueOrderEntry[]): string | null
  best: QueueOrderEntry | null = null
  for i in 0..entries.length-1:
    e = entries[i]
    if (best === null || e.priority > best.priority) best = e   // 严格 >：并列时先见（最旧）胜出
  return best === null ? null : best.id
```

默认全 0 时逐元素等价于 keys[0]（FIFO）；未来优先级注入只需 setQueuedPriority 一个口子（本单元不实现，字段预留）。`effectiveMaxParallel(raw) = raw >= 1 ? raw : 1`（防御钳制，§4-D11）。

### 3.5 线程模型映射（决策 2 增量；对照 lock(this)/Timer/RunOnUiThread）

| 源码机制 | ArkTS 对应 | 说明 |
|---|---|---|
| `lock(this)` 包住全部事件处理器与 ResumeDownload/StopDownloads（:401/:417/:461/:481） | **不复刻** | ArkTS 主线程事件循环天然串行；manager 全部状态变更发生在事件回调/用户动作的单线程时点，无竞态面 |
| `Timer awakePingTimer`（keep-alive 60s） | 不实现（Phase 5 长时任务域） | 降级项 §4-D5 |
| `RunOnUiThread(...)`（SetDownloadStatusWaiting :265-269 等） | 直接赋值（已在主线程） | `record.status=Waiting` 同步生效，@Observed 自动刷新 |
| 引擎事件跨线程回流（C# 事件于线程池线程触发） | taskpool 事件回流主线程（U2 既有） | manager 只在主线程被调用 |
| DB 同步写（AddItemToTop 内 AddNewDownload） | `store.add` Promise（既有） | **异步边界只延迟 admitNew 时机**：门判定与集合变更在 .then 内同步完成，两次快速新建的 .then 按提交序串行执行——门判定不会被并发新建穿透 |

**同步决策承诺（编码硬约束）**：manager 全部公开/私有方法为同步 void/boolean/number，方法体内无 await、无 Promise 分叉——门判定、入队、补位在单一调用栈内完成，杜绝"判定与变更之间被其他事件插入"的调度撕裂。探针侧轮询用 sleep 循环（POLL_MS=100，P2-U2 pollUntil 同构），不忙等。

## 4. 有意差异清单（对照源码/计划，含已定降级项）

| # | 差异 | 依据 |
|---|---|---|
| D1 | C# `lock(this)` 不复刻（JS 单线程事件循环串行） | 决策 2；§3.5 |
| D2 | `nonInteractive` 字段预留恒 false，不接进度窗口（原版控制 CreateProgressWindow/ShowProgressWindow 显隐） | Phase 4 进度页消费；MIGRATION_PLAN §6 决策 11 |
| D3 | `priority` 字段预留恒 0；无 setPriority API（源码本就无优先级，FIFO+字段预留=任务书"优先级字段预留"的忠实落法） | 任务书①；研究 fact 1 |
| D4 | 命名队列/queues.db 二进制/Schedule 不实现：manager 内置单默认队列（内存） | U3.2/U4 域；§0-7 兼容锚 |
| D5 | ShutdownAfterAllFinished/RunCommandAfterCompletion/awakePingTimer(keep-alive) 分支不实现 | MIGRATION_PLAN §3 降级清单第 5/6 条（关机类/保活 Phase 5） |
| D6 | 进度窗口集 activeProgressWindows/ShowDownloadCompleteWindow 不实现 | Phase 4 域 |
| D7 | 补位路径 resume() vs 新建即时路径 start() 的双入口保留（源码 :322/:180 同貌）；全新记录的 resume 经 U2.2 恢复桥自退化 start，行为等价 | §3.2 |
| D8 | 原版批量 ResumeDownload 的 `return`（中止整批）语义：manager 单 id 入参无批量路径，守卫降为单点幂等 return | §0-8；ApplicationCore.cs:261 |
| D9 | 排队项取消的 DB 回声（源码 DownloadCanelled→UpdateDownloadStatus(Stopped)）延至 hooks 消费方：U3.1 UI 无排队取消触点，manager 零 DB 写红线优先，仅置内存 status=Stopped | §3.3；U2.x 分层纪律 |
| D10 | 任务书 Config.cs:119 勘误：MaxParallelDownloads 实锚 :104（:118 是 TempDir），默认 3 | 本会话 sed 核实 |
| D11 | `effectiveMaxParallel` 防御钳制（<1 归一 1）：源码无钳制（WPF 下拉枚举保证合法），ArkTS 侧在 U4.3 设置 UI 落地前的运行时防御 | §3.4 |
| D12 | 任务书"暂停/恢复不占调度决策"与源码不符：按源码执行（暂停释放槽位补位 :479-497；恢复过门可入队 :262-270），语句按"无专用调度语义"理解 | §0-3 |
| D13 | 新建下载 record 工厂参数 startWaiting false→true（status=Waiting(3) 落库）——U1.2 起的既有直跑实现与源码 AddItemToTop 的偏差，本单元顺带对齐 | §0-2；Application.cs:55 |
| D14 | DetachEventHandlers 逐事件 `-=` 不复刻：Downloader 实例随 liveMap 摘除整体弃用（引用消失即回收），wrapper 为共享单实例无逐下载监听器可摘；源码 :622 `+=` 笔误（try/catch 吞）自然不存在的 | §1 红线；本会话读 :614-627 核实 |
| D15 | HandleProbeResult（Probed→UpdateItem 文件名/真实大小回写）由既有 handleConnected 承担（U1.2 已实现 onConnected→record.size），manager 不新增 | Index.ets:161-166 |

## 5. 各文件实现要点（可直接照做的接口面）

### 5.1 core/engine/QueueAlgo.ets（新，零 @kit）

```ts
export class QueueOrderEntry {
  id: string; priority: number;
  constructor(id: string, priority: number) { this.id = id; this.priority = priority; }
}
export function pickNextQueuedId(entries: QueueOrderEntry[]): string | null   // §3.4
export function effectiveMaxParallel(raw: number): number                     // raw>=1?raw:1
```

### 5.2 core/Config.ets（改，第 7 键）

追加位置：KEY 常量区（KEY_MAX_SEGMENTS 后）、DEFAULT 区、字段区、init() 读取链（maxSegments 行后）、getter 区（getMaxSegments 后）、setter 区。命名/模式与六键逐字一致：`KEY_MAX_PARALLEL_DOWNLOADS: string = 'maxParallelDownloads'`、`DEFAULT_MAX_PARALLEL_DOWNLOADS: number = 3`、`private maxParallelDownloads: number = DEFAULT_MAX_PARALLEL_DOWNLOADS`、`this.maxParallelDownloads = this.readNumber(KEY_MAX_PARALLEL_DOWNLOADS, DEFAULT_MAX_PARALLEL_DOWNLOADS);`、getter 直返、setter `setMaxParallelDownloads(value: number)` = 内存赋值+`writeNumber`。文件头注释追加第 7 键锚注（Config.cs:104）。

### 5.3 core/engine/DownloadManager.ets（新）

```ts
import { Downloader, DownloadEvents } from './Downloader';      // 只 import 需要的两个，Noop/Forward 不 import
import { pickNextQueuedId, effectiveMaxParallel, QueueOrderEntry } from './QueueAlgo';
import { DownloadRecord } from '../../model/DownloadRecord';
import { DownloadStatus } from '../../model/DownloadTypes';
import { Config } from '../Config';
import { hilog } from '@kit.PerformanceAnalysisKit';

export interface ManagerHooks { onQueuedCancelled?: (id: string) => void; }   // §3.3 排队取消回声

export class DownloadManager {
  private static instance: DownloadManager | undefined = undefined;
  static getInstance(): DownloadManager;
  /** 后到者接管（§0-9）：重建 wrapper 替换 delegate；hooks 可选（缺省无回声） */
  init(events: DownloadEvents, hooks?: ManagerHooks): void;
  admitNew(record: DownloadRecord): void;      // 新建入队/起跑（§3.1）
  resumeOne(record: DownloadRecord): void;     // 用户恢复（§3.2 门判定 + §0-8 幂等守卫）
  stopOne(id: string): void;                   // 停止/取消双分支（§3.3）
  isLive(id: string): boolean;  isQueued(id: string): boolean;
  liveCount(): number;  queuedCount(): number;
  activeDownloadCount(): number;               // live+queued（:40 口径，探针 maxConcurrent 用 liveCount）
  queueOrder(): string[];                      // queueIds 拷贝（探针 queuedOrder 观测）
}
// 模块内私有：LiveSlot / QueuedEntry / ManagedEvents（implements DownloadEvents，§3.2）/ 私有方法
// enqueue/enqueueBack/removeFromQueue/launchStart/launchResume/dequeueOne
```

内部规则补充：①wrapper 是 ManagedEvents 单实例，init 时新建（绑 delegate+hooks）；② admitNew/resumeOne 在 wrapper 未建（init 未调）时只记业务日志并 return（防御，不抛）；③ enqueue 前先 `queueMap.has(id)` 幂等门（对照 Add 不改位）；④ 日志：tag 'DownloadManager' domain 0x0000，只记异常路径（store.add 失败归 Index、wrapper 未建、孤儿 onPaused），**绝不输出 [XDM_PROBE]**。

### 5.4 pages/Index.ets（改，五处）

1. `import { DownloadManager } from '../core/engine/DownloadManager';`
2. aboutToAppear 首行：`DownloadManager.getInstance().init(this.buildEngineEvents());`（先于 initLists——事件面就绪不依赖 DB）
3. startNewDownload：工厂第 6 参 `false`→`true`（§4-D13）；.then 内删 `engineEvents` 惰性建 + `new Downloader` + `downloaders.set` 三块，改为 `this.inProgressList.unshift(record);` 后 `DownloadManager.getInstance().admitNew(record);`
4. handleToggle 整体替换：
```ts
const manager = DownloadManager.getInstance();
if (manager.isLive(id)) { manager.stopOne(id); return; }
const record: DownloadRecord | null = this.findById(id);
if (record === null) { return; }
manager.resumeOne(record);
```
5. handleFinished 删 `this.downloaders.delete(id);` 一行；类字段 `downloaders`/`engineEvents` 删除；buildEngineEvents 方法保留原样。

### 5.5 entry/src/test/QueueAlgo.test.ets（新，10 条）

import `{ describe, it, expect } from '@ohos/hypium'`（斜杠形态，U2.3 §3.7 实测）；导出 `queueAlgoTest()`。用例表见 §7-[A]-2。

### 5.6 probe/units/ProbeQueue.ets（新，P3-U1）

结构同 ProbeResume（@Component + ProbePage + runStep 分派 + facts 袋 + isCurrent 守卫）；四步全 autoRun；常量：`UNIT_ID='P3-U1'`、`DEFAULT_BASE_URL='http://192.168.1.20:8080'`、`SLOW_MS=300`（URL `/slow.bin?ms=300`，手册可替换）、`SUBMIT_COUNT=6`、`MORE_COUNT=4`、`WINDOW_TIMEOUT_MS=90000`、`STOP_TIMEOUT_MS=30000`、`POLL_MS=100`。事件袋：经 `ForwardDownloadEvents` 装配（闭包转发 Index.ets:74-96 同构）→ `manager.init(events, hooks)`——hooks 计数 onQueuedCancelled。确定性 id：`probe-p3u1-<runId>-<i>`（store.add 前覆盖 record.id，COLD-F1 约定）；id→序号 Map 供事件袋翻译。S2/S4 提交循环：`newDownloadRecord('q'+i+'.bin', Config.getDownloadDir(), 0, null, url, true, null, null)` → 覆盖 id → `await store.add(record)` → `manager.admitNew(record)`。

## 6. 探针步骤设计（P3-U1 四步，对应手册/EXPECT）

> 驱动模型：只调业务公开 API（DownloadManager/DownloadStore/Config）；manager 零 [XDM_PROBE] 输出——事件经 ForwardDownloadEvents 事实袋采集，各步骤结束统一 emit。观测值只写事实不写 PASS/FAIL（maxConcurrent≤3 的判定在 EXPECT/verify）。会话模型：单会话自动 S1→S4（无人工设备侧动作；人工仅启动主机测试源+填 IP）。

| 步骤 | 操作 | 观测点 | 日志标记行（值=观测事实） |
|---|---|---|---|
| BEGIN | ProbePage begin | runId/filesDir | `[XDM_PROBE][P3-U1][BEGIN] runId=<HHmmss> filesDir=<沙箱files路径>` |
| S1 门参数+基线+源预检 | 读 `Config.getMaxParallelDownloads()`；读 `manager.liveCount()/queuedCount()` 基线；自建 requestInStream GET `<base>/slow.bin?ms=0` + `Range: bytes=0-0`（不走引擎，P2-U2 S1 同构） | 门默认值、单例干净基线、测试源可达+Range 能力 | `[S1] maxParallel=3 liveBaseline=0 queuedBaseline=0 sourceStatus=206` |
| S2 快速提交 6 | 连续提交 6 个 `<base>/slow.bin?ms=300` 下载（确定性 id 序号 1..6）：`await store.add` → `manager.admitNew(record)`；全部提交完（6 个 .then 均已执行）立即读集合 | 提交序、即时 live/queued/active、队列插入序 | `[S2] submitted=6 submitOrder=1/2/3/4/5/6 liveAfterSubmit=<n> queuedAfterSubmit=<n> activeAfterSubmit=<n> queuedOrder=<i>/<j>/<k>` |
| S3 拥挤窗口轮询+补位序列 | POLL_MS=100 轮询 `liveCount()/queuedCount()` 直至 `live==0 && queued==0`（90s 超时）；期间事件袋记录 onStarted/onFinished 序号流，onFinished 后紧邻的 onStarted 记为补位对（onStarted 同步派发保证严格交错，PieceGrabber.ets:281） | **maxConcurrent（liveCount 峰值）**、queued 峰值、首发序、补位对序列、完成/失败计数 | `[S3] samples=<n> peakLive=<n> queuedPeak=<n> swapCount=<n> swapTargets=<a>/<b>/<c> swapSources=<obs> startedFirstOrder=<…> allFinished=<n> failed=<n> elapsedMs=<n>` |
| S4 停止/取消路径 | 再提交 4 个（#7..#10：3 live+1 queued）→ `manager.stopOne(#10)`（queued 分支）→ 读集合 → 依次 `stopOne(#7/#8/#9)`（live 分支，stopIntent 簿记）→ 轮询直至 `live==0`（30s 超时） | 排队取消不补位（取消后无新 start、live 不减）；队列空时 stop 无补位；onPaused×3 回声 | `[S4] submittedMore=4 liveAfterSubmit2=<n> queuedAfterSubmit2=<n> cancelledQueued=10 queuedAfterCancel=<n> liveAfterCancel=<n> newStartsAfterCancel=<n> pausedCount=<n> liveAfterStop=<n> newStartsAfterStop=<n>` |
| SUMMARY | end(ok) 聚合 | 四段关键值 | `[SUMMARY] S1=…|S2=…|S3=…|S4=…`（<1500B 两级降级由 ProbeKit 保证） |
| END | ok/steps/elapsed | steps=4 | `[END] ok=true steps=4 elapsedMs=<ms>` |

**关键确定性论证**（EXPECT 判定依据）：①S2 即时集合确定性——admitNew 的门判定与 liveMap/queueMap 变更在单调用栈同步完成，6 个 store.add 的 .then 按提交序串行，且 /slow.bin?ms=300 首完成距提交 >2s，故 liveAfterSubmit=3/queuedAfterSubmit=3 必然（健康分支）；②S3 补位序确定性——补位 dequeue 在 onFinished 事件处理器内同步执行，launchResume→resume()→onStarted 同步派发（PieceGrabber.ets:281），事件流严格"finished(k)→started(补位)"交错，swapTargets 依次 4/5/6（FIFO，priority 全 0）；swapSources=1/2/3 的完成次序不判定（服务端响应次序非确定）；③peakLive 由轮询采样，采样窗口 <ms=300 块延迟，峰值不低于实际峰值——EXPECT 只判 `peakLive<=3` 上界与 `peakLive>=1` 下界（下界防"全没跑起来"假绿，配合 allFinished=6 锚死）。

## 7. 单元验收测试要点

### [A] 静态门禁（编码员每轮自跑）

1. **hvigor 构建**：`hvigorw assembleHap`（或 devecocli build）零 error 零新 warning——ArkTS 严格子集编译期强制（codelinter 不含语法规则，自查对照 arkts-grammar-standards：无 any、对象字面量带声明类型、无 for..in 遍历 Map、Set/Map 仅限 get/has/set/delete/size/add 面如工程先例）。
2. **Hypium 本地单测**（`hvigorw test`，U2.3 §3.7 接通入口）——QueueAlgo 10 条：
   - `pickNext_empty_returnsNull`（空表 null）
   - `pickNext_single_returnsIt`（单元素恒返）
   - `pickNext_allZero_strictFifo`（全 0 五元素→按插入序首个）
   - `pickNext_priority_beatsOrder`（旧 0 新 5→新者胜）
   - `pickNext_tie_oldestWins`（两条同 priority→先插入者）
   - `pickNext_negative_lowerLoses`（0 vs -1→0 胜）
   - `pickNext_mixed_fullOrder`（五元素混合多趟抽取序列=优先级群组间 FIFO）
   - `effectiveMax_positive_passthrough`（3→3）
   - `effectiveMax_zero_clampsToOne`（0→1）
   - `effectiveMax_negative_clampsToOne`（-5→1）
3. **事件面零破坏核对**（审查项）：Downloader.ets 逐字节 diff 为空；Index 事件消费方五方法 diff 为空；NewDownloadDialog.ets diff 为空；`grep -r "XDM_PROBE" entry/src/main/ets/core/` 零命中。
4. **分层红线核对**：DownloadManager.ets 无 DownloadStore/无 probe import；Index 除 manager 接入外无新增 DB 调用。

### [P] 运行时（手册承载，xdm-probe-verify 机械判定）

- **排队与上限实测吻合**（单元验收核心）：S2 `liveAfterSubmit=3 queuedAfterSubmit=3 activeAfterSubmit=6`；S3 `peakLive<=3` 且 `swapCount=3`、`swapTargets=4/5/6`、`allFinished=6 failed=0`；S1 `maxParallel=3`（默认值实测）。
- **停止/取消路径**：S4 `queuedAfterCancel=0 liveAfterCancel=3 newStartsAfterCancel=0`（排队取消不补位）、`pausedCount=3 liveAfterStop=0 newStartsAfterStop=0`（队列空 stop 无补位）。
- **事件面零破坏（运行时佐证）**：S2~S4 全程 Index 既有事件消费路径不回归——探针事件袋与业务共面（wrapper），若 Index 列表状态翻转/落库链路被 manager 破坏，探针 failed/paused 计数即异常。
- 环境分支：S1 sourceStatus≠206（服务器未启动/IP 错/防火墙）→ FAIL 分流 env；S3 超时（90s）→ 分流 business-code（补位停摆：查 hilog DownloadManager/PieceScheduler）。

## 7bis. 单元验收对照（UNIT_CATALOG U3.1 行）

| 目录要求 | 本设计落点 |
|---|---|
| 并发上限 3 + 排队 + 状态机 + 优先级 | 门判定 §3.1（默认 3 实测于 P3-U1 S1）；FIFO 队列 §3.4；状态机 §2.2（Waiting/Downloading/Stopped/Finished 全路径）；优先级字段预留 §4-D3 |
| 对照源码 QueueManager.cs(123 行)/DownloadQueue.cs(83 行) | 研究结论修正+本会话核实：调度本体在 ApplicationCore.cs 双集合（QueueManager 仅命名队列持久化清单）——对照锚逐行落实于 §3.1-§3.3；QueueManager 面作 U4/U3.2 兼容锚（§0-7） |
| 验收要点"排队正确（PROBE 记录并发数不超 3）" | P3-U1 S2/S3（§6）：peakLive≤3 + 补位序 FIFO |
| 验证 [A]+[P] | §7-[A]（hvigor+hvigorw test 10 条）+ §7-[P]（P3-U1 四步） |
| 前置 U2.2 | 恢复桥/事件面/挂起防御语义全部继承，零改动引用（§1 显式不动清单） |

## 8. 风险与备注

1. **探针与 Index 单例竞争**（§0-9）：manager.init 后到者接管。探针运行期间 Index 若被重建（aboutToAppear 再 init）会把事件袋换回 Index——探针四步无人工中断点，正常流程不触发；手册注明"探针会话内不切页"。
2. **探针重跑残留**：单例集合基线由 S1 观测（liveBaseline/queuedBaseline 非零→EXPECT 分支 UNVERIFIED，重启应用后重跑）；DB 行每轮 +10（probe-p3u1-<runId>-* 主键不冲突），与既有探针同口径不清理。
3. **24 连接压力**：3 并发×8 分段=24 个 HTTP 连接打 Node 单线程测试源——P0-U2 仅验证过 8 并发连接；ms=300 延迟下服务端仅串行写块，风险低；若 S3 出现 failed>0，EXPECT 分流 env（换 ms=600 或减 SUBMIT_COUNT 重跑）。
4. **吞吐依赖**：/slow.bin?ms=300 单下载时长受分段并行度影响（8 连接时 ≈3-5s），S3 90s 预算充裕；若设备网络栈握手慢导致 <3 并发窗口被首完成击穿（peakLive<3 且 allFinished=6），EXPECT 记 UNVERIFIED 而非 FAIL——上限正确性由 S2 即时集合锚（liveAfterSubmit=3）独立保证，不依赖 S3 窗口宽度。
5. **U3.2 接口预留对账**：Scheduler 定时启停将消费 resumeOne（批量恢复）与 stopOne（批量暂停）——manager API 面已按单项粒度备好；nonInteractive/priority 两预留字段的消费方分别在 Phase 4 进度页与优先级 UI（未排期单元）。
