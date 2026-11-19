# U3.2 限速+重试+定时调度 · 模块设计书

> 单元：U3.2（Phase 3 第 2 单元；探针单元 ID `P3-U2`，slug `u3-2-speed-limit-retry-scheduler`）。
> 来源：xdm-migrate 工作流"模块设计师"角色，2026-09-29。
> 依据：MIGRATION_PLAN §6 决策 2（异步限速睡眠补偿）/决策 10（配置 preferences）+ §7 Phase 3；UNIT_CATALOG U3.2 行（验证 [A]+[P]，"限速实测吻合；定时窗启停"）；PROBE_SPEC v1；U3.1 既有纪律（事件面冻结/manager 零 DB 写/主线程单点/同步决策承诺）；源码研究结论（10 facts + 3 openQuestions，本会话逐条复核）。
> 对照源码（本会话只读核实，未改 resourses/ 下任何文件）：`SpeedLimiter.cs`（:22-31 GetCachedSpeedLimit 3000ms 窗口+-2 哨兵、:33-44 GetGlobalSpeedLimit、:46-82 ThrottleIfNeeded 逐字数学、:17-20 WakeIfSleeping、:58/:80 写锁、:84-87 sleep=ManualResetEvent.WaitOne）；`Config.cs:124`（`DefaltDownloadSpeed = 0`）/:126（`EnableSpeedLimit = false`）；`IO/ConfigIO.cs:154-155/:166-167`（字面量键 "EnableSpeedLimit" Boolean / "DefaltDownloadSpeed" Int32）；`UI/SpeedLimiterUIController.cs:9-36`（写回规范化 :22-27：`EnableSpeedLimit = enabled ? speed>0 : false`、`DefaltDownloadSpeed = speed>0 ? speed : 0`）；`Downloader/Progressive/HTTPDownloaderBase.cs:36`（`protected SpeedLimiter speedLimiter = new()` per-download 共享）/:104-106（ThrottleIfNeeded 门面）/:119（Stop 内 WakeIfSleeping）；`Downloader/Progressive/PieceGrabber.cs:107-124`（timesRetried++ 先于 >MaxRetry 判定；仅 connectPhase sleep(RetryDelay×1000)）/:303-304（**写盘→UpdateDownloadedBytesCount→ThrottleIfNeeded 调用序**）/:357；`Util/Helpers.cs:166-171`（TickCount()=Environment.TickCount64 单调毫秒）；`Scheduler.cs` 全文（:13 activeSchedules、:28-31 Start=Timer(0,60000)、:43-108 StartOrStopItem/ProcessScheduledItem、:105-107 HasFlag、:110-117 OnTimer）；`ApplicationCore.cs:64`（init 序列调 StartScheduler）/:597-601；`DownloadSchedule.cs:9-20`（struct+WeekDays 位标志 None=0,Sun=1,Mon=2,Tue=4,Wed=8,Thu=16,Fri=32,Sat=64）。
> 工程现状核实（本会话读文件/命令）：`SegmentWorker.ets`（onChunk 同步直写 :171-195、@Concurrent 纪律块 :16-27、WorkerParams :50-69、WorkerResult :96-112）；`PieceGrabber.ets`（dispatchPiece :411-488 组装 WorkerParams、retryImmediately :882-891 / retryConnectPhase :893-910 固定间隔重试、构造器读 Config :184-188、COLD-F1 分支 :749-764）；`HttpClient.ets`（onChunk 同步回调 :58/:95-105、abort :158-184）；`DownloadManager.ets`（resumeOne :173-187 / stopOne :194-216 / queueOrder :242-244、LiveSlot/QueuedEntry nonInteractive 预留 :43/:56）；`Config.ets`（七键+readNumber/readString/writeNumber/writeString 模式）；`Downloader.ets`（观测面 getter 先例 :134-149）；`DownloadStore.getDownloadById/queryInProgress`（:256-275/:305-307）；`EntryAbility.ets`（onCreate 挂 Config.init+Store.initialize :50-55）；`ProbeKit/ProbePage/ProbeQueue/ProbeIndex`（探针模式全套）；`module.json5`（**deviceTypes 含 2in1 + ohos.permission.INTERNET 已具备**，本会话 cat 核实）；`main_pages.json`（仅 Index+ProbeIndex）；测试计数（本会话 grep -c "it(" 实测：DownloadTypes 4+EngineMath 10+FileNameFormat 13+HttpProtocol 26+PieceAlgo 31+ProbeDownloadLogic 4+ProbeHttpLogic 16+QueueAlgo 10+RecordMapping 13=**127 条**）；`@ohos.net.http.d.ts`（本会话 grep：**无 pause/suspend/背压 API**，事件面仅 dataReceive/dataEnd/headersReceive/dataReceiveProgress）；`@ohos.systemDateTime.d.ts:238`（`getUptime(timeType, isNanoseconds?): number` 同步、TimeType.STARTUP=0 含深睡 / ACTIVE=1 不含深睡，@since 10；kits 目录无 SystemDateTimeKit——直连 `@ohos.systemDateTime` import）；`docs/probe/P1-U2-download-server.js`（/big.bin 4MiB Range 206 全速、/slow.bin?ms=N 64KB 块间隔确定性流）。

## 0. 冲突与拍板注记（必读）

1. **openQuestion 1 拍板：限速预算按 `maxSegments` 静态均摊（share = globalLimit / maxSegments），弃"活跃段数动态分摊"。** 论证（本会话推演）：TaskPool worker 相互隔离、WorkerParams 派发后冻结、taskpool 无主线程→worker 通道（sendData 仅 worker→主线程，SegmentWorker.ets:23-25 既有纪律）——分摊值只能在派发时定。若按派发时刻活跃段数分摊：首片（探测→COLD-F1 直派）派发时活跃=1 得全额 limit，后续分裂片依次得 limit/2、limit/3…**调和级数爬坡，8 段聚合可达 ~2.7×limit 且首片全额恒占**——超限方向（用户设 1024 得 2700+）不可接受。按 maxSegments 静态均摊：聚合 = 活跃段数 × limit/maxSegments **恒 ≤ limit**（保守方向），满段并发时恰=limit，单分段（maxSegments=1，探针口径）与整流模式单 worker 场景经 `perWorkerLimitKBps(limit, 1)=limit` **与源码逐字等价**。少段相位（收尾/小文件）聚合低于 limit——登记 D1。
2. **openQuestion 2 拍板：计划启停暂挂 Config 六键，扫描作用域=downloads 表全部未完成行（默认队列 DownloadIds 等价物）。** 源码 Schedule 挂 DownloadQueue 实体随 queues.db 持久化（per-queue）；U3.1 无队列实体（其 §0-7 已预告本迁移）。`Scheduler.ets` 状态机**逐字复刻**（位匹配→end 先 start 后→end 无条件 Remove+stop、start 查重 Add+resume），仅"遍历 QueueManager.Queues"退化为"单 Config 调度配置+queryInProgress() 作用域"——队列实体（U4 Queue 页）落地时迁移回 per-queue，ScheduleAlgo 纯函数面零改动。登记 D6/D10。
3. **openQuestion 3 拍板：重试=固定间隔，差异为零；MIGRATION_PLAN §7"指数退避重试"措辞与源码冲突，按任务书"以源码为准"。** 本会话复读 PieceGrabber.ets:882-919：`retryImmediately`（body 期，立即重派不 sleep）与 `retryConnectPhase`（连接期，`sleepMs(retryDelay*1000)` 与 pauseGate race）+ timesRetried 预算（先 ++ 后判）——与 PieceGrabber.cs:107-124 逐行同构，**本单元对重试路径零改动**（对照审查项：diff 为空）。研究结论 grep 全量证实源码无指数退避（唯一 backoff 命中是 WinInetClient.cs:1238 注释）。**建议主会话修订 PLAN §7 Phase 3 措辞为"固定间隔重试（RetryDelay=10s）"**，防验收者按 PLAN 找指数退避误判（D5）。
4. **限速执行机制的关键平台约束（本会话 grep d.ts 证实）：`requestInStream` 无暂停/背压 API。** dataReceive 是推送式同步回调；异步 sleep 期间网络分块持续入队。因此 onChunk 直写路径无法"await 限速"（onChunk 为同步 void，HttpClient.ets:58）。设计必须：①写盘与接收解耦（**泵式消费**：onChunk 入队、异步泵写盘+逐字限速数学+异步 sleep 补偿）②**内存有界**（队列水位 8MiB：溢出即 abort 当前连接，泵排空后带新 Range 原地重连——"burst-chasing"，attempt 不终结、不耗重试预算）③**网络真实限速**（水位溢出即断流：无原生背压时靠断流暂停网络；有原生背压时队列天然有界，水位永不触达，自然退化为纯睡眠补偿=源码语义）。这是对源码"阻塞线程 sleep"的唯一可行异步等价物，登记 D3。探针 S2 观测 `burstReopenCount`/`peakQueuedBytes` 区分两种模式（观测事实，不写判定）。
5. **module.json5 / main_pages.json 不动（有据，非遗漏）**：本会话 cat 核实 module.json5 deviceTypes=["phone","2in1"]、requestPermissions=[ohos.permission.INTERNET] 已具备（任务书模板句"当前缺 INTERNET"与实态不符，以实态为准）；本单元无新增系统能力（限速=引擎内计算；Scheduler=setInterval 定时器，无后台长时任务新需求——U5.1 域）。main_pages.json 仅 Index+ProbeIndex，P3-U2 经 ProbeIndex 嵌入不注册路由（U2.1/U3.1 同口径）。两文件不列入 files 清单。
6. **Scheduler 启动点=EntryAbility.onCreate**（对照 ApplicationCore.cs:64 初始化序列调 StartScheduler :597-601——"核心初始化即启动"，非 UI 页加载时）：Config.init（已有）之后追加 `Scheduler.getInstance().start()`。探针冷启动路由 probe 页不加载 Index，探针 S3 自行 stop()+start() 重定相位（立即首扫+60s 节拍已知相位）——生产语义不受影响（start() 幂等，D9）。EntryAbility 既有红线（不 import probe/）不破：Scheduler 属 core/engine/。
7. **限速关闭=零回归硬承诺**：`enableSpeedLimit=false`（默认）或派发值 <1 时，worker 走**原直写路径**（onChunk 同步 writeSync，U2.1 逐字节等价）；泵/队列/水位/重连全部只在 throttleEnabled 分支存在。既有 127 条单测、P2.x 归档探针行为面不变（WorkerResult 仅追加 4 个观测字段，消费方按字段名读取天然容忍）。这是本单元最大回归风险的对冲设计，编码与审查双查（§7-[A]-4）。
8. **P3-U2 只探停止边界，不探启动边界（有意）**：任务书明确"定时窗**停止**观测"。启动边界（resumeAll）与停止边界共用同一套状态机+manager API，由 ScheduleAlgo 纯函数单测+对照审查覆盖；不探的实因：启动边界会 resume `queryInProgress()` 全部未完成行——**含历次探针遗留行**（probe-p3u1-* 等数十行，探针不清理既有行的工程口径），哪个行抢到 live 槽依赖 DB 返回序，观测不可确定。登记 §8-4。
9. **S3 定时窗 start==end 防误触**：探针把 start 与 end 设为同一目标分钟——源码 :58-63 end 分支先判先 return，start 分支（:65-82）永不触达，探针窗口内零 resume 副作用（同时这本身就是对"end 先于 start"次序的源码保真观测，S3 步骤表可判 `resumedEcho=0`）。

## 1. 目标文件清单（按实现顺序）

| # | 文件 | 新/改 | 职责 | 对外导出 | 依赖 |
|---|---|---|---|---|---|
| 1 | `entry/src/main/ets/core/engine/SpeedLimiter.ets` | 新 | 限速纯逻辑层（零 @kit，Hypium 直接加载）：`ThrottleState`（lastTick/lastBytes 基线）、`computeThrottleSleepMs`（**SpeedLimiter.cs:46-82 数学逐字**，纯函数）、`perWorkerLimitKBps`（D1 预算均摊）、`SpeedLimiter`（worker 侧薄封装：持 state+share，`computeSleep(bytesNow, nowMs)` 同步算睡眠——异步 sleep 由 worker 自持以便取消协作） | `ThrottleState`、`computeThrottleSleepMs`、`perWorkerLimitKBps`、`SpeedLimiter` | 无（零 @kit） |
| 2 | `entry/src/main/ets/core/engine/ScheduleAlgo.ets` | 新 | 调度纯函数层（零 @kit）：`minutesOfDay(h,m)`、`weekDayBitOf(jsDayOfWeek)`（0=周日→1 … 6=周六→64，非法→0）、`matchesDay(daysMask, dayBit)`（`(daysMask & dayBit) === dayBit`，HasFlag :105-107 逐字）、`scheduledBoundary(nowMinutes, startMinutes, endMinutes)`（0=无/1=end/2=start，**end 先 start 后** :58-82 逐字） | `minutesOfDay`、`weekDayBitOf`、`matchesDay`、`scheduledBoundary`（+边界常量 `BOUNDARY_NONE/END/START: number`） | 无（零 @kit） |
| 3 | `entry/src/main/ets/core/Config.ets` | 改 | 追加第 8~13 键（§2.1）：enableSpeedLimit/defaultDownloadSpeed/scheduleEnabled/scheduleStartMinutes/scheduleEndMinutes/scheduleDays + 私有 readBoolean/writeBoolean + 组合 setter（规范化/钳制） | 追加 `DEFAULT_*` 常量、`getEnableSpeedLimit()`、`getDefaultDownloadSpeed()`、`setSpeedLimit(enabled, speedKBps)`、`getScheduleEnabled()/getScheduleStartMinutes()/getScheduleEndMinutes()/getScheduleDays()`、`setSchedule(enabled, startMinutes, endMinutes, daysMask)`；既有导出不动 | 无 |
| 4 | `entry/src/main/ets/core/engine/SegmentWorker.ets` | 改 | 限速执行点（§3.2）：WorkerParams += `speedLimitKBps`；WorkerResult += 4 观测字段（throttleSleepCount/throttleSleepTotalMs/peakQueuedBytes/burstReopenCount）+ `ThrottleStats` 类；主体重构为（重）开环：throttleEnabled 时泵式消费（队列+水位 abort+原地重连+可取消分片 sleep），关闭时单次迭代逐字节等价 U2.1 | 追加 `ThrottleStats`；`segmentWorkerTask`/`WorkerParams`/`WorkerResult` 签面向后兼容追加 | #1、@ohos.systemDateTime |
| 5 | `entry/src/main/ets/core/engine/PieceGrabber.ets` | 改 | ①dispatchPiece 读 Config 换算 share（GetGlobalSpeedLimit :33-44 等价+perWorkerLimitKBps）注入 WorkerParams；②onWorkerResult 累积 throttle 观测；③新增 `throttleStats()` 观测 getter | 追加 `throttleStats(): ThrottleStats`；既有面不动 | #1 #3 #4 |
| 6 | `entry/src/main/ets/core/engine/Downloader.ets` | 改 | 观测面透传：`throttleStats()` 单 getter 追加（describePieces/activeSegmentCount 同款先例 :134-149；**DownloadEvents 三声明零字节不动**） | 追加 `throttleStats()` | #5 |
| 7 | `entry/src/main/ets/core/engine/DownloadManager.ets` | 改 | `resumeOne(record, nonInteractive?: boolean)` 可选参落地（源码 ResumeDownload 第二参 :251）：透传 QueuedEntry/LiveSlot 的 nonInteractive 预留字段（launchResume/dequeueOne 链传播）；其余零改动 | `resumeOne` 签名追加可选参（向后兼容，Index 既有单参调用不变） | 无新依赖 |
| 8 | `entry/src/main/ets/core/engine/Scheduler.ets` | 新 | 定时启停（§3.3）：单例；setInterval(60000)+start() 立即首扫（dueTime:0 等价）；onTick→ScheduleAlgo 位匹配+双边界→stopAll（同步，逐 id stopOne）/resumeAll（异步 fire-and-forget，queryInProgress→resumeOne(record, true)）；activeSchedules:Set 查重；tickCount 观测面 | `Scheduler`（getInstance/start/stop/isRunning/tickCount） | #2 #3 #7、DownloadStore（只读）、hilog |
| 9 | `entry/src/main/ets/entryability/EntryAbility.ets` | 改 | onCreate 初始化序列追加 `Scheduler.getInstance().start()`（Config.init 之后；对照 ApplicationCore.cs:64） | —（ability 入口） | #8 |
| 10 | `entry/src/test/SpeedLimit.test.ets` | 新 | SpeedLimiter 纯函数 Hypium 用例（§7-[A]-2，13 条） | `speedLimitTest` | #1 |
| 11 | `entry/src/test/ScheduleAlgo.test.ets` | 新 | ScheduleAlgo 纯函数 Hypium 用例（§7-[A]-2，13 条） | `scheduleAlgoTest` | #2 |
| 12 | `entry/src/test/List.test.ets` | 改 | testsuite 注册 `speedLimitTest()`+`scheduleAlgoTest()`（合计 127+26=153） | —（测试入口） | #10 #11 |
| 13 | `entry/src/main/ets/probe/units/ProbeSpeedLimit.ets` | 新 | P3-U2 探针页（§6 四步）：S1 参数装配+源预检 → S2 限速速率区间观测（引擎直驱单分段 4MiB@1024KB/s）→ S3 定时窗停止观测（maxParallel=1 提交 3 个：1 live+2 queued，end 边界到点全停）→ S4 环境恢复 | `ProbeSpeedLimit`（struct） | #1~#9、../core/ProbeKit+ProbePage、DownloadStore/Config/Downloader(ForwardDownloadEvents)/DownloadManager/DownloadRecord |
| 14 | `entry/src/main/ets/probe/ProbeIndex.ets` | 改 | PROBE_UNITS 追加 `{unitId:'P3-U2'}` + else-if 追加 `ProbeSpeedLimit()` | —（@Entry 页） | #13 |
| 15 | `entry/src/main/resources/base/element/string.json` | 改 | 追加探针 2 键（§2.5；纯 JSON 禁尾逗号） | —（资源） | #13 |
| 16 | `docs/probe/PROBE-u3-2-speed-limit-retry-scheduler.md` | 新 | 探针运行手册：P1-U2-download-server.js 零改动复用（/big.bin=限速步全速源、/slow.bin?ms=2500=定时窗长活源）+ 可替换参数说明（limit/ms/边界偏移）+ 预期序列表 + 午夜跨界环境分支 | —（文档） | #13 |
| 17 | `docs/probe/EXPECT-u3-2-speed-limit-retry-scheduler.json` | 新 | 机器可读预期表（BEGIN+S1~S4+SUMMARY+END；schema 同 EXPECT-u3-1；±30% 速率窗判定 [716.8,1331.2] 与 env 分流规则） | —（JSON） | #16 |

**显式不动的文件**：`module.json5`/`main_pages.json`（§0-5）；`core/engine/QueueAlgo.ets`（pickNextQueuedId 等 U3.1 面零改动）；`core/db/DownloadStore.ets`/`RecordMapping.ets`（22 列零改动，Scheduler 只读复用 getDownloadById/queryInProgress）；`core/net/HttpClient.ets`/`HttpProtocol.ets`（**onChunk 同步签名不动**——泵在 worker 侧解耦；限速不属传输层）；`model/DownloadRecord.ets`/`DownloadTypes.ets`（maxSpeedLimitInKiB 记录级字段本单元不消费——源码它也只在 UI 透传，限速取 Config 全局值）；`pages/Index.ets`（本单元无 UI 触点——限速/计划设置页属 U4.2/U4.3）；`components/NewDownloadDialog.ets`；既有 probe/units 八文件（归档不追改）。**红线**：`core/**` 不得 import `probe/**`；`SegmentWorker.ets` 保持禁 hilog/禁 Config 单例（share 经 WorkerParams 传值）；`Scheduler.ets`/`SpeedLimiter.ets`/`DownloadManager.ets` 零 [XDM_PROBE] 输出（Scheduler 业务日志 domain 0x0000 tag 'Scheduler'）；**Scheduler 零 DB 写**（queryInProgress/getDownloadById 只读；DB 写仍全在事件消费方——U2.x 分层纪律）；重试路径（retryImmediately/retryConnectPhase/retryAfterDelay）**diff 必须为空**（§0-3）。

## 2. 数据模型与表结构（对照源码逐一核对）

### 2.1 Config 第 8~13 键（对照 Config.cs:124/:126 + ConfigIO.cs:154-167 + DownloadSchedule.cs）

| 键名（camelCase 工程约定） | 类型 | 默认 | 源码锚 | 备注 |
|---|---|---|---|---|
| `enableSpeedLimit` | boolean | false | EnableSpeedLimit（Config.cs:126，ConfigIO.cs:154-155 ReadBoolean） | false=不限速（GetGlobalSpeedLimit 返 0 等价） |
| `defaultDownloadSpeed` | number | 0 | DefaltDownloadSpeed（Config.cs:124，ConfigIO.cs:166-167 ReadInt32；**源属性名拼写即 'Defalt'，工程键名纠正拼写**，D8） | KB/s（源单位同） |
| `scheduleEnabled` | boolean | false | Schedule != null（DownloadQueue 可空结构体的 HasValue 判定，QueueSerializerV1 首 bool） | false=无计划（ProcessScheduledItem :87 直接过） |
| `scheduleStartMinutes` | number | 0 | Schedule.StartTime（TimeSpan） | 分钟数 0..1439（比较粒度 HH:MM 等价，D7） |
| `scheduleEndMinutes` | number | 0 | Schedule.EndTime（TimeSpan） | 同上 |
| `scheduleDays` | number | 0 | Schedule.Days（WeekDays:byte 位标志） | 位掩码 None=0,Sun=1,Mon=2,Tue=4,Wed=8,Thu=16,Fri=32,Sat=64（同值表直译） |

**setter（组合式，对照 SpeedLimiterUIController.cs:22-27 写回语义 1:1）**：
- `setSpeedLimit(enabled: boolean, speedKBps: number)`：`enableSpeedLimit = enabled && speedKBps > 0`（源 `enabled ? speed>0 : false` 等价）；`defaultDownloadSpeed = speedKBps > 0 ? speedKBps : 0`（非正归 0）。两键一次写入（源在 lock(Config) 内成对写+SaveConfig）。
- `setSchedule(enabled, startMinutes, endMinutes, daysMask)`：分钟钳制 [0,1439]、daysMask `& 0x7F`（防御钳制 D8——源无钳制，UI 控件保证合法；U4.3 前无 UI）。
- **getter 六个逐一对应**；私有 `readBoolean/writeBoolean` 新增（preferences.ValueType 含 boolean，模式与 readNumber 逐字一致）。
- 运行中改值热生效语义见 D2（限速=下次派发生效；计划=下一次 tick 生效——源码同貌：Scheduler 每 60s 重读 QueueManager）。

### 2.2 WorkerParams / WorkerResult 增量（SegmentWorker.ets）

| 结构 | 增量字段 | 源码锚 |
|---|---|---|
| `WorkerParams` | `speedLimitKBps: number`（0=不限速；主线程 perWorkerLimitKBps 均摊后注入；**worker 禁触 Config 单例纪律的传值通道**） | SpeedLimiter 构造参数化（源 speedLimiter 字段+GetGlobalSpeedLimit 读 Config → ArkTS 派发时读，D1/D2） |
| `WorkerResult` | `throttleSleepCount: number`、`throttleSleepTotalMs: number`、`peakQueuedBytes: number`、`burstReopenCount: number`（attempt 级观测，关闭限速时恒 0） | （无源码对应物——D3 执行机制的平台观测面，探针 S2 消费） |
| `ThrottleStats`（新导出类） | 同上 4 字段的聚合载体（PieceScheduler 跨 attempt 累加） | — |

### 2.3 限速状态模型（SpeedLimiter.ets，对照 SpeedLimiter.cs:10-15 实例字段）

```ts
export class ThrottleState {
  lastTick: number = 0;    // 对照 long lastTick（:10）
  lastBytes: number = 0;   // 对照 long lastBytes（:10）
}
```

源 `sleepHandle: ManualResetEvent`（:11）**无对应物**——唤醒改 isCanceled 轮询（D4）；源 `lastChecked/cachedSpeedLimit`（:12-13，3000ms 缓存+-2 哨兵）**消亡**——share 派发期冻结，无重读对象（D2）。`SpeedLimiter` 薄封装：`constructor(speedLimitKBps: number)`、`isEnabled(): boolean`（`speedLimitKBps >= 1`，:49 同判）、`computeSleep(bytesNow: number, nowMs: number): number`（持 ThrottleState 委托纯函数）——sleep 执行留在 worker（可取消分片，§3.2）。

### 2.4 Scheduler 状态模型（对照 Scheduler.cs:12-13 + DownloadSchedule.cs）

```ts
// core/engine/Scheduler.ets 内部
private timerId: number = -1;                    // Timer? timer（:12）
private activeSchedules: Set<string> = new Set(); // HashSet<string>（:13）——单调度配置下键恒 'default'
private tickCounter: number = 0;                 // （无源码对应物——观测面，D14）
```

扫描对象：源 `QueueManager.Queues`（每队列 Schedule+DownloadIds）→ ArkTS **单 Config 调度配置**（scheduleEnabled/Start/End/Days）+ 作用域 id 集 = `DownloadStore.queryInProgress()`（默认队列 DownloadIds 等价物，D6/D10）。WeekDays 位值经 ScheduleAlgo.number 掩码直译（ArkTS 位运算 `&`，无需枚举）。

### 2.5 downloads 表 / DownloadRecord / manager 结构：零 schema 改动

22 列 DDL 零改动；无新表（queues.db 无对应物，U3.1 §0-7 兼容锚）。manager 增量仅 `resumeOne` 可选参 + nonInteractive 传播（LiveSlot/QueuedEntry 字段 U3.1 已预留，本单元赋值；UI 消费 Phase 4，D13）。

### 2.6 string.json 追加键（base/element，纯 JSON 禁尾逗号）

| 键 | 值（base） |
|---|---|
| `probe_p3u2_title` | `P3-U2 限速+定时调度探针` |
| `probe_p3u2_source_hint` | `测试源地址（主机局域网 IP，禁 127.0.0.1）` |

## 3. 关键算法翻译说明

### 3.1 限速数学（SpeedLimiter.cs:46-82 逐字；纯函数 computeThrottleSleepMs）

```
computeThrottleSleepMs(state, speedLimitKBps, bytesNow, nowMs): number
  if (speedLimitKBps < 1) return 0                                  // :49 speedLimit<1 直接返回
  if (state.lastBytes == 0 || state.lastTick == 0) {                // :50 首调只初始化基线
    state.lastBytes = bytesNow; state.lastTick = nowMs; return 0;   // :52-53（测量基准=worker 自身 written，
  }                                                                 //    源=downloader.GetDownloaded() 聚合——D1）
  const maxBytesPerMS = speedLimitKBps * 1024 / 1000;               // :59 (double)speedLimit*1024/1000 逐字
  const actualTimeSpent = nowMs - state.lastTick;                   // :61
  if (actualTimeSpent < 1) return 0;                                // :62 亚毫秒窗口：不推进基线并入下次
  const diff = bytesNow - state.lastBytes;                          // :64 可为负
  state.lastBytes = bytesNow;                                       // :65 基线先推进
  state.lastTick = nowMs;                                           // :66
  const expectedTimeSpent = diff / maxBytesPerMS;                   // :67
  if (actualTimeSpent < expectedTimeSpent) {                        // :69 仅超速才睡
    return Math.ceil(expectedTimeSpent - actualTimeSpent);          // :73 (int)Math.Ceiling 逐字
  }
  return 0;
```

调用序保真（PieceGrabber.cs:303-304）：**写盘 → 计数 → 限速**——泵内 `writeSync → written+=n → computeSleep → await sleep`。`nowMs` 源=Helpers.TickCount()（Environment.TickCount64 单调毫秒）→ ArkTS `systemDateTime.getUptime(TimeType.ACTIVE, false)`（d.ts:238 本会话核实，@since 10 同步返回；ACTIVE 不含深睡——活动下载场景无深睡，等价 D15）。预算均摊：`perWorkerLimitKBps(globalKBps, maxSegments) = maxSegments >= 1 ? globalKBps / maxSegments : globalKBps`（maxSegments<1 防御钳 1，effectiveMaxParallel 同族；D1）。派发点换算（PieceGrabber.dispatchPiece，对照 GetGlobalSpeedLimit :33-44——`lock(Config.Instance)` 不复刻，主线程单点 D1 先例）：

```
const globalKBps = cfg.getEnableSpeedLimit() && cfg.getDefaultDownloadSpeed() > 0
  ? cfg.getDefaultDownloadSpeed() : 0;          // :38 EnableSpeedLimit && DefaltDownloadSpeed>0 双门逐字
params.speedLimitKBps = perWorkerLimitKBps(globalKBps, this.maxSegments);
```

### 3.2 worker 泵式限速执行（SegmentWorker 主体重构；§0-4 平台约束的解）

**线程模型映射**：源=分片线程阻塞读循环（read→write→count→throttle-sleep 阻塞线程=网络真实暂停）；ArkTS=dataReceive 推送（不可暂停）→ **接收与写盘解耦**：onChunk（同步，事件循环）入队；异步泵消费（写盘+限速+异步 sleep 补偿）。泵与主 body 同处 worker 事件循环（两个并发 async 续体，无锁——单线程续体交错）。

```
throttleEnabled = params.speedLimitKBps >= 1 && !params.probeMode
limiter = new SpeedLimiter(params.speedLimitKBps)          // 每 attempt 新实例（源每次 resume 新建 downloader 同构）
queue: ArrayBuffer[]; queuedBytes/peakQueuedBytes/overflow/burstReopenCount/throttleSleep*  // 局部 let（fd 同纪律）

writeChunk(chunk)                     // 原 onChunk 写盘体抽公共：isCanceled 已查、窗口定长封顶（支柱①）、
                                      // n<=0 超窗丢弃、writeSync、written+=n、diskErrCode 捕获 —— 逐字保留

client.onChunk = (chunk) => {
  if (taskpool.Task.isCanceled()) { canceledMark = true; client.abort(); return; }   // 原取消协作不动
  if (!throttleEnabled) { writeChunk(chunk); return; }   // ★限速关闭=U2.1 原路径逐字节（§0-7）
  queue.push(chunk); queuedBytes += chunk.byteLength;
  if (queuedBytes > peakQueuedBytes) peakQueuedBytes = queuedBytes;
  if (queuedBytes >= 8388608) { overflow = true; client.abort(); }  // 水位 8MiB 内联字面量（@Concurrent 禁模块常量）
};                                                      // ★probe 模式不挂 onChunk（现状保持）

pump = async (): Promise<void> => {     // 仅 throttleEnabled 时启动
  while (true) {
    if (taskpool.Task.isCanceled()) { canceledMark = true; abort 当前 client; return; }
    if (queue.length === 0) { if (attemptOver) return; await sleepMs(5); continue; }  // 空转轮询 5ms 内联
    const chunk = queue.shift(); if (chunk === undefined) continue;   // ArkTS 窄化
    queuedBytes -= chunk.byteLength;
    writeChunk(chunk);
    if (diskErrCode !== 0) { abort 当前 client; return; }             // 唤醒主 body（waitStreamEnd 放行）
    const sleepMs = limiter.computeSleep(written, getUptime(ACTIVE,false));
    if (sleepMs > 0) { throttleSleepCount++; throttleSleepTotalMs += sleepMs;
      if (await sleepCancellable(sleepMs)) return; }                  // 取消即 Wake（D4 等价物）
  }
}
sleepCancellable(ms): Promise<boolean>  // 100ms 切片轮询 isCanceled（内联 100）——taskpool cancel 打断长睡眠

主 body（重）开环：
  const pumpPromise = throttleEnabled ? pump() : Promise.resolve();
  let client = new HttpClient(params.timeoutMs);  let firstOpen = true;
  while (true) {
    headers = firstOpen ? params.headers : rebuildRange(params.headers, params.start + written,
                 params.end)                      // 首迭代逐字原头；重开仅换 Range（identity 等六头保留）
    head = await client.open(params.url, headers)
    // 首迭代体与现网代码逐字一致（status/errCode/contentRange/contentType/contentLength 落 result、
    // isCanceled 检查、status<=0 → phase='connect' return、connected 消息、probe 提前 return 在环前）
    if (!firstOpen) {                              // 重开校验（worker 自检，无 connected 消息）：
      if (闭窗口 && head.status !== 206) → break（body 期 result：主线程 retryImmediately 重派全新
          attempt 后由 206 强检收敛 InvalidResponse 终态）；开窗口非 200/206 同 break
    }
    …connected 消息（仅 firstOpen）…progress 定时器（仅 firstOpen 启动，attempt 级）…
    ended = await client.waitStreamEnd()           // overflow abort → false；自然 dataEnd → true
    if (overflow) {
      await drainQueue()                           // 轮询至 queue 空（泵继续限速排空）——canceled/diskErr 旁路退出
      overflow = false; attemptOver=false 保持
      if (canceledMark || diskErrCode !== 0) break;
      if (闭窗口 && written >= windowLen) break;   // 溢出与完成竞态：已写满即收尾
      burstReopenCount++;
      client = new HttpClient(params.timeoutMs);   // 旧 client 已 abort（幂等）；fd 跨重连保持（追加写）
      firstOpen = false; continue;                 // 原地重连——attempt 不终结、不耗 timesRetried 预算
    }
    await drainQueue()                             // 自然收尾：泵排空尾部
    result.ended = ended; break;
  }
  attemptOver = true; await pumpPromise;           // 泵退出（队列空+attemptOver）
  result.bytesWritten = written; result.diskErrCode = diskErrCode;
  result.canceled = canceledMark || taskpool.Task.isCanceled();
  result.throttleSleepCount/TotalMs/peakQueuedBytes/burstReopenCount = 累计值（关闭限速恒 0）
```

**为什么水位+重连是必要的（§0-4）**：无原生背压时异步 sleep 期间分块持续入队——不设上界则内存=整个剩余窗口（百 MB 级）；abort 断流后 TCP 窗口关闭=**网络真实暂停**，泵以限速排空，排空后重连续传——聚合网络速率收敛于 share（突发+排空周期，时限流数学自校正：重连后首笔 computeSleep 自动睡去超前量，无需专门的重连睡眠计算）。**有原生背压时**队列天然有界，水位永不触达（burstReopenCount=0），行为=纯睡眠补偿（源码语义）。两种平台形态下限速均真实且内存有界；探针 S2 以 burstReopenCount/peakQueuedBytes 观测实际形态。水位 8MiB：8 worker 最坏 64MiB（PC 2in1 可承受；默认限速关闭时零开销）。

**取消/挂起防御不退化**：sleepCancellable 100ms 切片保证 stop 后睡眠及时打断（WakeIfSleeping :17-20 等价）；abort 幂等；finally 块（timerId 清理+client.abort+fd closeSync）保持 attempt 级唯一出口；probe 模式路径零改动（探测取头即 abort，D3 探测语义不涉限速）。

### 3.3 Scheduler 定时窗状态机（Scheduler.cs 逐字）

```
start(): 若 timerId>=0 return（幂等，D9——源 Start() 重复调用泄漏 Timer 不复刻）
         this.onTick() 同步立即执行一次（dueTime:0 等价，:30）；timerId = setInterval(()=>this.onTick(), 60000)
stop():  clearInterval；timerId=-1（源 Stop/Dispose 均 timer.Dispose，:33-41 合一）
onTick(): tickCounter++;                          // 观测面
  if (!Config.getScheduleEnabled()) return        // 对照 :87 queue.Schedule != null
  const dayBit = weekDayBitOf(new Date().getDay()) // DateTime.Now.DayOfWeek（周日=0）
  if (!matchesDay(Config.getScheduleDays(), dayBit)) return   // :92-98 位匹配链 + :105-107 HasFlag
  startOrStopItem()
startOrStopItem():
  const nowMinutes = minutesOfDay(new Date().getHours(), new Date().getMinutes())  // :45-46
  const b = scheduledBoundary(nowMinutes, startMinutes, endMinutes)
  if (b === BOUNDARY_END) {                       // :58-63 end 先判先 return
    this.stopAllAsync(); this.activeSchedules.delete(KEY); return;  // 无条件 Remove（不查成员资格，:61）
  }
  if (b === BOUNDARY_START) {                     // :65-82
    if (this.activeSchedules.has(KEY)) return;    // :67-70 查重
    this.activeSchedules.add(KEY);                // :71
    this.resumeAllAsync();                        // :72-81（fire-and-forget，见下）
  }
stopAllAsync / resumeAllAsync（作用域取数 queryInProgress 为 async——两层拆分见下）
```

**同步决策**：源 OnTimer→StopDownloads 全同步（timer 线程+lock）；ArkTS `queryInProgress()` 是 async——**onTick 拆两层**：`onTick()` 同步入口（tickCounter++/scheduleEnabled 门/day 位匹配/分钟边界双判——纯内存计算），命中边界即调 `stopAllAsync()/resumeAllAsync()`（`queryInProgress()` await 后逐 id 动作），**fire-and-forget + `.catch(log)`**，setInterval 回调内绝不 await。重入风险：60s 周期 vs 一次 DB 读（毫秒级）——重叠概率可忽略；即使重叠，stopOne/resumeOne 幂等（live/queued 成员资格门）+ activeSchedules 查重门，无重复动作后果。manager 全方法同步无 await 的 U3.1 承诺不受影响（Scheduler 是新调用方，不是 manager 改动）。

```
stopAllAsync():  const records = await store.queryInProgress()
    for record of records: manager.stopOne(record.id)
    // 对照 StopDownloads :347-380 逐 id：live → stopIntent+stop()（manager :196-199 1:1）；
    // queued → 摘除+内存 Stopped+hooks 回声（manager :201-215 1:1）；未命中幂等 no-op（:379 两边未命中）
    // closeProgressWindow:true 不复刻（UI 面，D12）
resumeAllAsync(): const records = await store.queryInProgress()
    for record of records: manager.resumeOne(record, true)
    // 对照 ResumeDownload :250-324 逐 id：幂等守卫（:261，D8 单点化）/门判定超门入队 Waiting（:262-270）/
    // 门过 launchResume（:322 Resume）——manager.resumeOne :173-187 已 1:1；nonInteractive=true 落
    // QueuedEntry/LiveSlot 字段（:251 第二参，D13 消费 Phase 4）
```

**边界语义保真清单**：①比较只到分钟粒度（源 h/m 分离比较 ⇔ 分钟数相等，数学等价）②60s 采样漏过某分钟则该边界本次不触发（源同行为，不补偿——D9）③end 无条件 Remove：用户手动开的下载到点同样被停（:61 语义）④activeSchedules 只防 start 重复不拦 end（:61/:67）⑤Days==None 永不触发（matchesDay(0,·)=false，:92-98 链首即假）。

### 3.4 线程模型映射总表（决策 2 增量）

| 源码机制 | ArkTS 对应 | 锚 |
|---|---|---|
| `Timer(OnTimer, 0, 60000)`（timer 线程） | `setInterval(60000)` + start() 立即首扫（主线程） | Scheduler.cs:30；D9 |
| `lock(this)`/`lock(Config.Instance)` | 不复刻（主线程事件循环串行；manager 同步承诺沿用） | D1 先例 |
| `ManualResetEvent.WaitOne(interval)` 可唤醒睡眠 | `sleepCancellable` 100ms 切片轮询 `taskpool.Task.isCanceled()` | SpeedLimiter.cs:84-87；D4 |
| 分片线程阻塞读循环（read 即消费点） | onChunk 入队 + 异步泵消费（dataReceive 推送不可暂停） | §3.2；D3 |
| `ReaderWriterLockSlim`（跨分片共享 limiter 串行） | per-worker 独立 limiter（隔离）+ 主线程 maxSegments 均摊 | SpeedLimiter.cs:58/:80；D1 |
| `Environment.TickCount64` | `systemDateTime.getUptime(TimeType.ACTIVE, false)` | Helpers.cs:166-171；D15 |
| `WakeIfSleeping()` 只 Set 不 Reset | attempt 生命周期界定（新 attempt 新 limiter；cancel 打断睡眠） | SpeedLimiter.cs:17-20；D4 |

## 4. 有意差异清单（对照源码/计划，含已定降级项）

| # | 差异 | 依据 |
|---|---|---|
| D1 | **限速作用域降级**：源 per-download 共享 limiter（聚合=limit）；ArkTS per-worker 独立 limiter+主线程 `share=limit/maxSegments` 静态均摊——聚合恒 ≤limit（保守），满段并发=limit，少段相位低于 limit；单分段（maxSegments=1）与源码逐字等价。弃动态分摊：派发冻结下动态分摊在分裂爬坡期调和级数超限（首片全额恒占，8 段 ~2.7×limit），超限方向不可接受 | 研究 openQuestion 1 拍板（§0-1）；MultiSourceDownloaderBase.cs:31 per-download 字段 |
| D2 | **限速热生效粒度**：源 3s 缓存重读 Config（SpeedLimiter.cs:22-31）；ArkTS share 派发时读、attempt 期冻结——变更在下次派发生效（长 attempt 内不热更）；3000ms 缓存+-2 哨兵机制随之消亡（无重读对象） | worker 禁 Config 纪律；§0-1 |
| D3 | **限速执行机制**：源阻塞线程 sleep（读循环上真实暂停）+WakeIfSleeping；ArkTS 异步 sleep 补偿（数学逐字）+泵式写盘+8MiB 队列水位 abort/原地重连（burst-chasing）——requestInStream 无暂停/背压 API（本会话 grep d.ts 证实）；无原生背压时靠断流真实限速+内存有界，有背压时自然退化为纯睡眠补偿（burstReopenCount=0）。重连不耗 timesRetried 预算（attempt 内闭环） | §0-4/§3.2；PieceGrabber.cs:303-304 调用序保真 |
| D4 | **唤醒语义**：源 ManualResetEvent Set 后永不 Reset（stop 后 limiter 永久失效）；不复刻"永久失效"态——attempt 生命周期自然界定+isCanceled 切片轮询打断睡眠 | SpeedLimiter.cs:17-20；研究 fact 4 |
| D5 | **重试=固定间隔，差异为零**（本单元零改动）：源全量 grep 无指数退避（RetryDelay 消费点仅 PieceGrabber.cs:118-124 与 HttpChunkDownloader.cs:173-186）；MIGRATION_PLAN §7 Phase 3"指数退避重试"措辞与源码冲突——按任务书"以源码为准"，**建议主会话修订 PLAN 措辞**（防验收误判） | 研究 openQuestion 3 拍板；本会话复读 PieceGrabber.ets:882-919 同构证实 |
| D6 | **计划宿主降级**：源 Schedule 挂 DownloadQueue 实体持久化 queues.db（per-queue）；暂挂 Config 六键+作用域=downloads 表全部未完成行；队列实体（U4）落地时迁移，ScheduleAlgo 纯函数面零改动 | 研究 openQuestion 2 拍板；DownloadSchedule.cs/QueueManager.cs |
| D7 | **计划时间粒度**：源 TimeSpan（Tick 级持久化）但比较只到 HH:MM；直接存分钟数 0..1439（语义等价，存储简化） | Scheduler.cs:45-50 |
| D8 | **键名/钳制**：DefaltDownloadSpeed 拼写纠正为 defaultDownloadSpeed；setSpeedLimit 规范化逐字（SpeedLimiterUIController.cs:22-27）；setSchedule 分钟钳 [0,1439]/daysMask &0x7F 防御（源无钳制，UI 控件保证） | ConfigIO.cs:166；U3.1 D11 先例 |
| D9 | **定时器**：setInterval+start() 立即首扫（dueTime:0 等价）；start() 幂等防泄漏（源 Start() 重复调用泄漏 Timer 不复刻）；60s 采样漏分钟=源同行为不补偿 | Scheduler.cs:28-41 |
| D10 | **stopAll/resumeAll 作用域**：源遍历 queue.DownloadIds（队列成员清单）；遍历 queryInProgress() 全部未完成行（默认队列等价）——含历史探针行/手动停止行，stopOne 对非 live/queued 行幂等 no-op 无害 | §0-2；U3.1 §0-7 |
| D11 | **resumeAll 单次读表**：源队列清单+逐 id GetDownloadById 两轮读；queryInProgress 一次取全记录直用（数据等价） | Scheduler.cs:72-81 |
| D12 | closeProgressWindow:true 不复刻（进度窗口 UI 面，Phase 4） | ApplicationCore.cs:352；U3.1 D6 同族 |
| D13 | nonInteractive 消费落地：resumeOne 可选参落 LiveSlot/QueuedEntry 字段；UI 效果（不建进度窗）Phase 4 消费 | ResumeDownload(nonInteractive:true) :251/:324 |
| D14 | Scheduler 单例化+tickCount 观测面为新增（源为 ApplicationCore 持有字段、无 tick 计数；观测面服务探针诊断） | ApplicationCore.cs:597-601 |
| D15 | **时钟源**：Environment.TickCount64（含睡眠单调毫秒）→ getUptime(ACTIVE)（不含深睡单调毫秒）——活动下载无深睡场景等价；API10+ d.ts:238 本会话核实 | Helpers.cs:166-171 |
| D16 | **测量基准**：源 GetDownloaded()=下载聚合字节（含分片间进度）；worker 自身 written（本 attempt 字节）——resume/重派后基线自然重建（源每次 resume 新建 downloader 同构） | MultiSourceDownloaderBase.cs:699；研究 fact 2 |
| D17 | P3-U2 只探停止边界（启动边界由纯函数单测+审查覆盖）——启动边界 resume 全部未完成行含历史探针遗留行，观测不可确定 | §0-8；任务书"定时窗停止观测" |
| D18 | WorkerResult 追加 4 观测字段（无源码对应物，平台行为观测面；JSON 消费方按字段名读取天然容忍） | §3.2 |

## 5. 各文件实现要点（可直接照做的接口面）

### 5.1 core/engine/SpeedLimiter.ets（新，零 @kit）

```ts
export class ThrottleState { lastTick: number = 0; lastBytes: number = 0; }
/** SpeedLimiter.cs:46-82 逐字（§3.1）；mutate state.lastTick/lastBytes（PieceAlgo 先例）；返回睡眠毫秒（0=不睡） */
export function computeThrottleSleepMs(state: ThrottleState, speedLimitKBps: number,
  bytesNow: number, nowMs: number): number
/** D1 预算均摊：maxSegments>=1 ? globalKBps/maxSegments : globalKBps（防御钳 1） */
export function perWorkerLimitKBps(globalKBps: number, maxSegments: number): number
/** worker 侧薄封装（sleep 执行留 worker——可取消分片） */
export class SpeedLimiter {
  constructor(speedLimitKBps: number);
  isEnabled(): boolean;                       // speedLimitKBps >= 1（:49 同判）
  computeSleep(bytesNow: number, nowMs: number): number;   // 委托纯函数，持内部 ThrottleState
}
```

### 5.2 core/engine/ScheduleAlgo.ets（新，零 @kit）

```ts
export const BOUNDARY_NONE: number = 0;
export const BOUNDARY_END: number = 1;
export const BOUNDARY_START: number = 2;
export function minutesOfDay(hours: number, minutes: number): number            // h*60+m（h 0-23/m 0-59 防御钳）
export function weekDayBitOf(jsDayOfWeek: number): number                       // 0(日)→1 … 6(六)→64；非法→0
export function matchesDay(daysMask: number, dayBit: number): boolean          // (daysMask & dayBit) === dayBit
export function scheduledBoundary(nowMinutes: number, startMinutes: number,
  endMinutes: number): number   // end 精确相等→END（先判）；start 精确相等→START；否则 NONE（:58-82 逐字次序）
```

### 5.3 core/Config.ets（改，第 8~13 键）

追加位置与模式同第 7 键（KEY 常量区/DEFAULT 区/字段区/init 读取链/getter 区/setter 区）；新增私有 `readBoolean(key, defValue): boolean` / `writeBoolean(key, value)`（typeof 'boolean' 判定，模式与 readNumber/writeNumber 逐字一致）。组合 setter §2.1。文件头注释追加键锚（Config.cs:124/:126、DownloadSchedule.cs、SpeedLimiterUIController.cs:22-27）。

### 5.4 core/engine/SegmentWorker.ets（改，§3.2 全伪码）

要点重申：①`import { systemDateTime } from '@ohos.systemDateTime'`（无 kit 包装，本会话核实；worker 内同步调用）；②水位 8388608/轮询 5/切片 100 全部**内联字面量+注释**（@Concurrent 禁模块级常量）；③`queue.shift()` 返回 `ArrayBuffer|undefined` 必须窄化；④首迭代体与现网代码逐字一致（client 改 let、headers 经 rebuildRange 首迭代返 params.headers 原引用）；⑤probe 模式整个环路前置提前 return（现状保持，零改动）；⑥**重试路径零触碰**；⑦WorkerResult 追加字段在所有 return 点赋值（含 catch 分支——局部计数器天然可读）。

### 5.5 core/engine/PieceGrabber.ets（改，三处）

①dispatchPiece：params 组装追加 §3.1 换算两行；②onWorkerResult：parse 成功后无条件累加 `this.throttleSleepCount += result.throttleSleepCount`（4 项同；attempt 无关累积）；③新增 `throttleStats(): ThrottleStats`（返回 4 项聚合新实例）+ 类字段 4 个 number 初始化 0。

### 5.6 core/engine/Downloader.ets（改，一处）

`throttleStats(): ThrottleStats { return this.scheduler.throttleStats(); }`（观测面 getter，activeSegmentCount 同款）。**DownloadEvents/Noop/Forward 三声明零字节不动**。

### 5.7 core/engine/DownloadManager.ets（改，一处签名+传播）

`resumeOne(record: DownloadRecord, nonInteractive?: boolean)`：超门入队 `entry.nonInteractive = nonInteractive === true`；launchResume 增私有参传播 `new LiveSlot(dl)` 后 `slot.nonInteractive = nonInteractive === true`；dequeueOne 传 `entry.nonInteractive`。默认缺省 false——Index 既有单参调用行为不变。**其余零改动**（stopOne/门判定/补位/wrapper 全部不动）。

### 5.8 core/engine/Scheduler.ets（新）

```ts
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ScheduleAlgo … } from './ScheduleAlgo';  // 具名导入四函数+三常量
import { DownloadManager } from './DownloadManager';
import { DownloadStore } from '../db/DownloadStore';
import { Config } from '../Config';

export class Scheduler {
  private static instance: Scheduler | undefined = undefined;
  static getInstance(): Scheduler;
  start(): void;                 // 幂等；立即首扫+setInterval(60000)
  stop(): void;                  // clearInterval（源 Stop/Dispose 合一）
  isRunning(): boolean;
  tickCount(): number;           // 观测面（探针区分"边界未匹配"与"定时器死"）
  // 私有：onTick()（同步入口：tickCounter++/scheduleEnabled 门/day 位匹配→startOrStopItem）
  //       startOrStopItem()（分钟边界双判→stopAllAsync/resumeAllAsync，均 fire-and-forget .catch(log)）
  //       stopAllAsync()/resumeAllAsync()（§3.3；queryInProgress await 后逐 id stopOne/resumeOne(record,true)）
  // 业务日志：domain 0x0000 tag 'Scheduler'，只记异常路径（DB 读失败/边界动作计数 info）
}
```

### 5.9 entryability/EntryAbility.ets（改，两行）

import Scheduler + onCreate 在 `Config.getInstance().init(...)` 与 `DownloadStore...initialize` 之后追加 `Scheduler.getInstance().start();`（对照 ApplicationCore.cs:64 初始化序）。红线不破：不 import probe/。

### 5.10 entry/src/test/SpeedLimit.test.ets + ScheduleAlgo.test.ets（新，26 条）

`import { describe, it, expect } from '@ohos/hypium'`（斜杠形态，U2.3 实测口径）；导出 `speedLimitTest()` / `scheduleAlgoTest()`；用例表见 §7-[A]-2。

### 5.11 probe/units/ProbeSpeedLimit.ets（新，P3-U2）

结构同 ProbeQueue（@Component + ProbePage + runStep 分派 + facts 袋 + isCurrent 守卫）；四步全 autoRun。常量：`UNIT_ID='P3-U2'`、`DEFAULT_BASE_URL='http://192.168.1.20:8080'`、`LIMIT_KBPS=1024`（手册可替换）、`SLOW_MS=2500`（S3 长活源 /slow.bin?ms=2500，64 块×2.5s≈160s）、`BOUNDARY_OFFSET_MIN=2`（目标分钟=当前+2，mod 1440）、`S3_SUBMIT=3`、超时 `S2_TIMEOUT_MS=60000`/`S3_TIMEOUT_MS=210000`、`POLL_MS=100`。事件袋：S2 引擎直驱 `new Downloader(record, ForwardDownloadEvents(...))`（onProgress 采样 instantSpeed/activeSegmentCount；onFinished 记终值）+ S1 `manager.init(events, hooks)`（S3 消费；hooks 计数 onQueuedCancelled）。确定性 id：`probe-p3u2-<runId>-<i>`。S1 快照六项 Config 原值→S4 恢复（setSpeedLimit/setMaxSegments/setMaxParallelDownloads/setSchedule 原值回写）。

## 6. 探针步骤设计（P3-U2 四步，对应手册/EXPECT）

> 驱动模型：S2 只调引擎公开面（new Downloader+观测 getter）；S3 只调业务公开 API（DownloadManager/DownloadStore/Config/Scheduler）。观测值只写事实不写 PASS/FAIL（速率±30% 窗判定在 EXPECT/verify）。会话模型：单会话自动 S1→S4；人工仅启动主机测试源+填 IP。S3 含 60~120s 分钟边界等待（手册注明总时长 ≈4 分钟）。

| 步骤 | 操作 | 观测点 | 日志标记行（值=观测事实） |
|---|---|---|---|
| BEGIN | ProbePage begin | runId/filesDir | `[XDM_PROBE][P3-U2][BEGIN] runId=<HHmmss> filesDir=<沙箱files路径>` |
| S1 参数装配+源预检 | 快照 Config 六项原值（enableSpeedLimit/defaultDownloadSpeed/maxSegments/maxParallelDownloads/scheduleEnabled/scheduleDays）→ 应用探针配置：`setSpeedLimit(true, 1024)`、`setMaxSegments(1)`（S2 单分段口径）；`manager.init(events, hooks)`；manager 基线；自建 requestInStream GET `<base>/big.bin` + `Range: bytes=0-0` 源预检（ProbeQueue S1 同构，不走引擎） | 限速参数生效回显、单例基线、源可达+Range 能力 | `[S1] limitKBps=1024 maxSegments=1 maxParallel=<n> liveBaseline=0 queuedBaseline=0 sourceStatus=206 scheduleEnabledBefore=<b> speedBefore=<n>` |
| S2 限速速率区间观测 | 引擎直驱：`newDownloadRecord('p3u2-speed.bin', downloadDir, 0, null, '<base>/big.bin', true, null, null)` 覆盖确定性 id → `store.add` → `new Downloader(record, events)` → `dl.start()` → await onFinished（60s 超时）。events 袋 onProgress 采样 instantSpeed（B/s→KB/s）与 `dl.activeSegmentCount()`；完成后读 `dl.throttleStats()` | **avgRateKBs**（4096KB/elapsed）、instantSpeed min/max、activeSegmentMax=1、throttleSleepCount/TotalMs、peakQueuedBytes、burstReopenCount（区分背压形态）、elapsedMs | `[S2] bytes=4194304 elapsedMs=<n> avgRateKBs=<n.n> instantMinKBs=<n> instantMaxKBs=<n> activeSegmentMax=1 sleepCount=<n> sleepTotalMs=<n> peakQueuedBytes=<n> burstReopenCount=<n> finished=true` |
| S3 定时窗停止观测 | `setMaxParallelDownloads(1)` → 目标分钟 `target=(minutesOfDay(now)+2)%1440`，`start=target`、`end=target`（§0-9 end 先判防 start 误触）、`daysMask=weekDayBitOf(today)` → `setSchedule(true, start, end, daysMask)` → 提交 3 个 `<base>/slow.bin?ms=2500`（store.add→admitNew：1 live+2 queued）→ `Scheduler.stop()+start()`（重定相位：立即首扫+60s 节拍）→ 轮询 `liveCount()===0 && queuedCount()===0`（210s 超时，POLL_MS=100） | 目标分钟回显、live/queued 前后值、onPaused 回声数、排队取消回声数（hooks）、tickCount 增量（定时器活性）、**resumedEcho=0**（start 分支未触达佐证） | `[S3] targetMinute=<HH:MM> dayBit=<n> submitted=3 liveBefore=1 queuedBefore=2 liveAfter=0 queuedAfter=0 pausedEcho=1 queuedCancelledEcho=2 resumedEcho=0 tickCountBefore=<n> tickCountAfter=<n> elapsedMs=<n>` |
| S4 环境恢复 | S1 快照回写：`setSpeedLimit(before.enabled, before.speed)`、`setMaxSegments(before)`、`setMaxParallelDownloads(before)`、`setSchedule(before.enabled, before.start, before.end, before.days)`；`Scheduler.getInstance().start()`（确保生产态运行）；读回校验 | 恢复值回显、scheduler 运行态 | `[S4] restoredLimit=<n> restoredMaxSegments=<n> restoredMaxParallel=<n> restoredScheduleEnabled=<b> schedulerRunning=true` |
| SUMMARY | end(ok) 聚合 | 四段关键值 | `[SUMMARY] S1=…|S2=…|S3=…|S4=…`（<1500B 两级降级由 ProbeKit 保证） |
| END | ok/steps/elapsed | steps=4 | `[END] ok=true steps=4 elapsedMs=<ms>` |

**关键确定性论证（EXPECT 判定依据）**：①S2 单分段——maxSegments=1 时 PieceGrabber COLD-F1 分支（:749-752 `records.size >= maxSegments`）对 4MiB 可续传源直派单片闭窗，activeSegmentMax=1 必然；4096KB/1024KB/s≈4s，限速数学时限流（D3 双形态下聚合网络速率均收敛 share）→ avgRateKBs 落 [716.8,1331.2]（±30%）；若 avgRate<716.8 且 sleepCount=0 且 elapsed≈bytes/网络瓶颈 → env 分流（网络慢于限额）；②S3 边界必然命中——Scheduler armed 后节拍 t0+60k，每 60s 一拍、目标分钟宽 60s，恰一拍落入（drift 两拍内可忽略）；slow.bin?ms=2500 单片 ≈160s > 边界最晚 120s，live 必在界内；end 边界 stopOne(#1 live→onPaused) + stopOne(#2/#3 queued→hooks)，全部同步链路；③resumedEcho=0 由 start==end + end-先判（源 :58-63 次序）双保证。

## 7. 单元验收测试要点

### [A] 静态门禁（编码员每轮自跑）

1. **hvigor 构建**：`hvigorw assembleHap`（或 devecocli build）零 error 零新 warning——ArkTS 严格子集编译期强制（自查 arkts-grammar-standards：无 any、对象字面量带类型、`queue.shift()` 窄化、无 for..in、Set/Map 仅 get/has/set/delete/size/add 面）。
2. **Hypium 本地单测**（`hvigorw test`）：既有 **127 条全绿**（本会话 grep -c 实测基线）+ 新增 26 条：
   - SpeedLimit.test.ets（13）：`throttle_limitZero_returnsZero`、`throttle_limitBelowOne_returnsZero`（0.5）、`throttle_firstCall_initializesBaseline`、`throttle_subMillisecond_returnsZero_baselineIntact`（同 now 二调：返 0 且基线不推进——:62 语义）、`throttle_underLimit_noSleep`、`throttle_overLimit_sleepCeiling`（1KB/s、1024B/100ms → 900）、`throttle_exactLimit_noSleep`（actual==expected 严格 <）、`throttle_negativeDiff_noSleep_baselineAdvances`、`throttle_baselineAdvancesEachCall`、`perWorker_singleSegment_fullLimit`（1024,1→1024）、`perWorker_splitByMaxSegments`（1024,8→128）、`perWorker_fractionalShare`（100,8→12.5）、`perWorker_defensiveClamp`（1024,0→1024）
   - ScheduleAlgo.test.ets（13）：`boundary_noMatch_returnsNone`、`boundary_endExact_returnsEnd`、`boundary_endCheckedBeforeStart`（start==end→END）、`boundary_startExact_returnsStart`、`boundary_startOtherMinute_none`、`matchesDay_bitPresent`（127,2→true）、`matchesDay_bitAbsent`（1,2→false）、`matchesDay_noneNeverMatches`（0,·→false）、`weekBit_sunday`（0→1）、`weekBit_monday`（1→2）、`weekBit_saturday`（6→64）、`weekBit_invalidZero`（7→0）、`minutesOfDay_edges`（0,0→0；23,59→1439）
3. **重试路径零改动核对**（审查项）：`git diff` PieceGrabber.ets 的 retryImmediately/retryConnectPhase/retryAfterDelay 三方法块为空（§0-3/D5）。
4. **零回归与红线核对**：`grep -r "XDM_PROBE" entry/src/main/ets/core/` 零命中；`grep -rn "probe/" entry/src/main/ets/core/` 零命中；Downloader.ets DownloadEvents 三声明 diff 为空；DownloadManager.ets 除 resumeOne 签名+nonInteractive 传播外 diff 为空；HttpClient.ets diff 为空（onChunk 同步签名不动）；限速关闭路径（speedLimitKBps<1 分支）与 U2.1 onChunk 逐字节对照。

### [P] 运行时（手册承载，xdm-probe-verify 机械判定）

- **限速实测吻合**（单元验收核心）：S2 `avgRateKBs ∈ [716.8, 1331.2]`（1024±30%）、`activeSegmentMax=1`、`burstReopenCount=0`（4MiB<8MiB 水位必不触达）、`finished=true`；`sleepCount/sleepTotalMs/peakQueuedBytes` 为事实项（区分背压形态：peakQueuedBytes 接近 0=有原生背压；接近 4MiB=无背压走纯睡眠模式——两者均合法，不判 FAIL）。
- **定时窗行为对照源码**：S3 `liveBefore=1 queuedBefore=2 liveAfter=0 queuedAfter=0 pausedEcho=1 queuedCancelledEcho=2 resumedEcho=0`（end 边界全停：live 整停+排队清退并回声，对照 StopDownloads :347-380 双分支）；`tickCountAfter>tickCountBefore`（定时器活性）。
- **环境分支**：S1 sourceStatus≠206 → env（服务器未启动/IP/防火墙）；S2 avgRate<716.8 且 sleepCount=0 → env（网络慢于限额，换更快网络或调低 LIMIT_KBPS 重跑）；S3 超时且 tickCountAfter==tickCountBefore → business-code（定时器死）；S3 超时且 tickCount 有增 → business-code（边界数学/位匹配错，查 ScheduleAlgo）；S3 跨午夜运行（23:58 后）dayBit 失配 → env（手册注明避开午夜 ±2min）。
- **既有行为不回归佐证**：S2 引擎直驱完成链（onStarted→onProgress→onFinished）与 S3 manager 全链（admitNew→排队→事件）均走通——限速关闭默认态由 S1 快照回显+全工程默认值保证（enableSpeedLimit=false 时 worker 原路径）。

### 7bis. 单元验收对照（UNIT_CATALOG U3.2 行）

| 目录要求 | 本设计落点 |
|---|---|
| 睡眠补偿限速改异步 sleep | §3.1 数学逐字 + §3.2 异步 sleep/泵/水位（D1/D2/D3） |
| 指数退避重试（MaxRetry=10/RetryDelay=10s） | **源码核实为固定间隔，差异为零**（D5）——PLAN 措辞冲突已登记，重试路径零改动 |
| Scheduler 定时启停 | §3.3 状态机逐字（位匹配/end 先 start 后/activeSchedules 查重）+ D6 宿主降级 |
| 限速实测吻合 | P3-U2 S2（±30% 窗+单分段口径+背压形态观测） |
| 定时窗启停 | P3-U2 S3（停止边界全观测：live+queued+回声+tick 活性；启动边界 D17） |
| 验证 [A]+[P] | §7-[A]（hvigor+153 条单测+diff 门）+ §7-[P]（P3-U2 四步） |
| 前置 U3.1 | manager API 零破坏复用（stopOne/resumeOne/queueOrder/hooks）；nonInteractive 预留字段本单元消费落地（D13） |

## 8. 风险与备注

1. **泵+水位+重连是本单元最大复杂度源**（§3.2）：编码员须严格按 §5.4 七要点；审查重点=首迭代体逐字一致（client let 化/headers 首迭代原引用）、取消/盘错/溢出三路对 pump 的收束（drainQueue 旁路退出）、attemptOver 时序（先置位后 await pumpPromise）。**探针 S2 的 burstReopenCount=0 锚**保证 4MiB 用例不触达重连分支——重连分支的运行时验证依赖 S2 之外的真实大文件使用（Phase 级验收补充观测，本单元 EXPECT 不覆盖；纯逻辑由 §3.2 伪码审查覆盖）。
2. **原生背压形态未知**（§0-4）：peakQueuedBytes 观测值二值分布（≈0 或 ≈文件长）即为结论本身——探针跑完此问题即有答案，结论回写本设计 D3 与 RISK_ASSESSMENT（主会话动作）。
3. **getUptime 在 taskpool 可用性**：d.ts API10+ 同步函数，风险低；若 worker 内抛异常 → attempt 失败结果（errCode 观测）→ 探针 S2 直接 FAIL 可见（分流 business-code，fallback 方案=Date.now() 差分替换，仅一处调用点）。
4. **S3 历史探针行干扰**：stopAll 遍历全部未完成行（D10）——旧 probe 行 stopOne 幂等 no-op 无害；启动边界不探（D17）的根因同此。工程长期清理策略归 U7.3 交付前 probe/ 移除时一并处理。
5. **S2 时长与精度**：4MiB@1024KB/s≈4s，elapsed 测量噪声 ±100ms→±2.5%（±30% 窗冗余充足）；网络需快于 1MB/s（手册 env 分支注明；局域网/真机 WiFi 均满足）。
6. **探针与生产调度器共存**：EntryAbility 已启动 Scheduler；探针 S3 stop()+start() 重定相位后 S4 再 start()（幂等 no-op，保持运行）——生产语义"常驻运行"不破坏。探针会话内不切页（manager.init 后到者接管，U3.1 §0-9 同款手册注记）。
7. **U4.3 设置页消费预告**：六新键的 UI 写入走 setSpeedLimit/setSchedule 组合 setter（规范化内聚在 Config，UI 零重复逻辑）；队列实体落地（U4 Queue 页）时 D6 迁移路径=Scheduler 构造注入"调度配置提供方"接口，ScheduleAlgo/状态机不动。
