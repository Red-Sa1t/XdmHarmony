# U3.2 限速+重试+定时调度 · 单元执行报告

> 单元：U3.2（Phase 3 第 2 单元；探针单元 ID `P3-U2`）。设计书：`docs/design/u3-2-speed-limit-retry-scheduler-DESIGN.md`。
> 报告日期：2026-09-29。报告依据：单元执行材料（研究结论 10 facts + 3 openQuestions、设计书、实现文件清单、对照审查 R2/R3 两轮、独立复核、主会话门禁输出），以及本报告会话的独立抽验（详见⑤，全部为本会话实际执行）。
> 结论速览：**hvigor 全量编译通过（本报告会话重跑确认 BUILD SUCCESSFUL）；对照审查 R3 轮 approved=true；独立复核 acceptable=true；153 条单测用例就位但 hvigorw test 未运行（按任务书约定归统一脚本执行）；限速实测与定时窗行为两项运行时验收待 P3-U2 探针人工执行。**

---

## ① 单元范围与验收要点

**范围（任务书四项 + 探针）**

| # | 任务 | 落点 | 状态 |
|---|---|---|---|
| 1 | `core/engine/SpeedLimiter.ets`——限速数学逐字翻译 + 异步 sleep 补偿（接入 SegmentWorker 分块路径） | SpeedLimiter.ets（纯函数层）+ SegmentWorker.ets（泵式执行）+ PieceGrabber.ets（share 派发） | 已实现，编译通过 |
| 2 | 重试策略对照源码核实（固定间隔 vs 指数退避，以源码为准） | 核实结论=**固定间隔 RetryDelay×1000，源码全 Core 无任何退避计算**；本单元对重试路径零改动（D5） | 已核实，零改动 |
| 3 | `core/engine/Scheduler.ets`——定时启停时间窗（控制 DownloadManager 全部 live 实例） | Scheduler.ets（新）+ ScheduleAlgo.ets（纯函数层）+ EntryAbility.ets 启动挂接 + DownloadManager.resumeOne 可选参 | 已实现，编译通过 |
| 4 | Config 追加速率/定时键 | Config.ets 第 8~13 键 + setSpeedLimit/setSchedule 组合 setter | 已实现，编译通过 |
| 5 | 探针 P3-U2：限速速率区间观测 + 定时窗停止观测 + 手册与预期表 | ProbeSpeedLimit.ets + ProbeIndex.ets 注册 + string.json 2 键 + PROBE 手册 + EXPECT 预期表 | 已生成，**待人工运行** |

**验收要点对照（任务书四条）**

| 验收项 | 现状 | 证据 |
|---|---|---|
| 编译过 | **通过**（本报告会话重跑 `devecocli build --modules entry` → `BUILD SUCCESSFUL in 41 s 348 ms`，2026-09-29） | ⑤-1 |
| 限速实测吻合 | **待运行时验证**（静态面已锁定：纯函数 13 条单测 + node 转写 36/36 断言佐证；±30% 速率窗判定由探针 S2 承载） | ⑥ |
| 定时窗行为对照源码 | **待运行时验证**（状态机逐字锚静态对照已过三轮审查；停止边界由探针 S3 承载） | ⑥ |
| 既有 127 条单测全绿 | **用例就位、未运行**：153 条（127 既有 + 26 新增）用例数经本会话 grep 实测；hvigorw test 按任务书约定由统一脚本执行，单元执行会话与本报告会话均未运行 | ⑤-3 |

**一处任务书与实态的矛盾（以实测为准）**：任务书模板句"module.json5 当前缺 ohos.permission.INTERNET"与实态不符——本会话 grep `entry/src/main/module.json5` 核实：`requestPermissions` 含 `ohos.permission.INTERNET`（:14-16）、`deviceTypes` 已含 2in1（:7）。本单元无新增系统能力（限速=引擎内计算，Scheduler=setInterval 定时器），module.json5 与 main_pages.json 显式不动（设计书 §0-5，有据非遗漏；main_pages.json 本会话 cat 核实仅 `pages/Index` + `probe/ProbeIndex`）。

**实现文件清单（18 个，全部 status=done）**：新建 7（SpeedLimiter.ets / ScheduleAlgo.ets / Scheduler.ets / ProbeSpeedLimit.ets / SpeedLimit.test.ets / ScheduleAlgo.test.ets / PROBE 手册 + EXPECT 预期表）；修改 11（SegmentWorker.ets / PieceGrabber.ets / Downloader.ets / DownloadManager.ets / Config.ets / EntryAbility.ets / ProbeIndex.ets / string.json / List.test.ets / 及两份探针文档）。本会话 `git status --short` 实测：9 个修改 + 9 个未跟踪，与清单一一对应。

## ② 研究结论摘要（关键源码行为 → ArkTS 对应表）

研究阶段逐条深读源码（facts 10 条 + openQuestions 3 条），三条 openQuestions 均已拍板（设计书 §0-1/2/3）。核心对应关系：

| 源码行为（锚） | ArkTS 对应 | 风险 |
|---|---|---|
| 限速="窗口均速差额睡眠补偿"而非令牌桶：`speedLimit<1` 早退；首调只建基线；`maxBytesPerMS=(double)speedLimit*1024/1000`，`actualTimeSpent<1` 不推进基线并入下次；仅 `actualTimeSpent<expectedTimeSpent` 才 `sleep(ceil(差额))`（SpeedLimiter.cs:46-82） | `computeThrottleSleepMs` 纯函数**数学逐字**（SpeedLimiter.ets:46，导出面本会话 grep 核实）；sleep 改异步 Promise 补偿，不阻塞 worker 事件循环 | low |
| 限速值来源与缓存：`EnableSpeedLimit && DefaltDownloadSpeed>0` 双门（SpeedLimiter.cs:33-44）+ 3000ms 缓存 / -2 哨兵（:22-31） | 主线程 dispatchPiece 派发前双门换算（PieceGrabber.ets:471-475，本会话 Read 核实）+ `perWorkerLimitKBps` 均摊（D1）；3s 缓存机制随派发冻结消亡（D2） | low |
| 限速作用域=同一下载实例共享 limiter（per-download 字段，MultiSourceDownloaderBase.cs:31），跨下载各自实例 | TaskPool worker 隔离 → per-worker limiter + 主线程 `share=limit/maxSegments` 静态均摊（D1，聚合恒 ≤limit 保守方向；单分段与源码逐字等价） | high→已对冲 |
| 限速执行=分片线程阻塞 sleep + ManualResetEvent 可唤醒（SpeedLimiter.cs:84-87/:17-20） | requestInStream 无暂停/背压 API（本会话核实设计书引证）→ 泵式写盘 + 8MiB 水位 abort/原地重连 + 100ms 切片可取消睡眠（D3/D4）；SegmentWorker.ets:203 `throttleEnabled = speedLimitKBps>=1 && !probeMode` 门（本会话 Read 核实） | medium |
| 重试=固定间隔 `sleep(RetryDelay*1000)`（RetryDelay 全 Core 消费点仅 PieceGrabber.cs:120 与 HttpChunkDownloader.cs:182；唯一 backoff 命中是 WinInetClient.cs:1238 注释掉的常量），默认 MaxRetry=10 / RetryDelay=10s | PieceGrabber.ets 既有 retryConnectPhase `sleepMs(retryDelay*1000)` 已与源码同构，**本单元零改动，差异登记为零**（D5）；PieceGrabber.ets 重试三方法逐字对照零差异（实现清单，sed 比对） | low |
| Scheduler=60s 采样定时器（Timer(0,60000)，Scheduler.cs:28-31）按 HH:MM 精确相等触发队列级启停；end 先判（:58-63 无条件 Remove+StopDownloads）、start 后判（:65-82 查重 Add+ResumeDownload）；Days 位匹配 HasFlag（:105-107） | Scheduler.ets 状态机逐字复刻（本会话 Read :122-155 核实：onTick 同步入口→位匹配→startOrStopItem，end 分支 :140-145 先判、start 分支 :147-153 查重）+ ScheduleAlgo 纯函数层（三常量四函数，导出面本会话核实）；核心初始化即启动（EntryAbility.ets:60，对照 ApplicationCore.cs:64） | low |
| 计划数据宿主=DownloadQueue 实体随 queues.db 持久化（DownloadSchedule.cs:9-20，WeekDays 位标志 None=0…Sat=64） | **降级为 Config 六键**（D6，U3.1 无队列实体）：scheduleEnabled / scheduleStartMinutes / scheduleEndMinutes / scheduleDays（分钟数 0..1439，D7）；队列实体落地时迁移，ScheduleAlgo 纯函数面零改动 | medium |
| 批量启停=StopDownloads（ApplicationCore.cs:347-380）/ResumeDownload（:250-324）逐 id | DownloadManager.stopOne（live/queued 双分支+幂等 no-op，:199-219 本会话 Read 核实）/resumeOne（`nonInteractive?` 可选参，:176-192）1:1 承接；Scheduler 仅逐 id 循环，不新增 manager API | low |
| 速率配置键：DefaltDownloadSpeed（int，KB/s，源拼写即 'Defalt'）+ EnableSpeedLimit（bool）（Config.cs:124/:126，ConfigIO.cs:154-167）；UI 写回规范化（SpeedLimiterUIController.cs:22-27） | Config.ets 第 8~9 键 `enableSpeedLimit`/`defaultDownloadSpeed`（键名纠正拼写，D8）+ `setSpeedLimit` 规范化逐字（Config.ets:231-235 本会话 Read 核实：`enabled ? speedKBps>0 : false` / `speedKBps>0 ? speedKBps : 0`） | low |

时钟源：Environment.TickCount64 → `systemDateTime.getUptime(TimeType.ACTIVE)`（API10+，不含深睡；活动下载场景等价，D15）。

## ③ 设计决策与有意差异（引用 MIGRATION_PLAN 决策条款）

计划依据：MIGRATION_PLAN §6 决策 2（异步限速睡眠补偿）、决策 10（配置 preferences）+ §7 Phase 3；UNIT_CATALOG U3.2 行（验证 [A]+[P]）。设计书 D 清单 18 项，要点：

| # | 差异 | 一句话依据 |
|---|---|---|
| D1 | 限速作用域：源 per-download 共享（聚合=limit）→ per-worker 独立 + `share=limit/maxSegments` 静态均摊，聚合恒 ≤limit（保守方向）；单分段与源码逐字等价。弃动态分摊：派发冻结下分裂爬坡期调和级数超限至 ~2.7×limit | 研究 openQuestion 1 拍板 |
| D2 | 限速热生效粒度：源 3s 缓存重读 → share 派发时读、attempt 期冻结，变更下次派发生效；3000ms 缓存与 -2 哨兵消亡 | worker 禁触 Config 纪律 |
| D3 | 限速执行机制：源阻塞线程 sleep → 异步 sleep 补偿（数学逐字）+ 泵式写盘 + 8MiB 水位 abort/原地重连；重连不耗 timesRetried 预算 | requestInStream 无暂停/背压 API（grep d.ts 证实） |
| D4 | 唤醒语义：不复刻源 ManualResetEvent Set 后永不 Reset 的"永久失效"态 → attempt 生命周期界定 + isCanceled 100ms 切片轮询打断睡眠 | SpeedLimiter.cs:17-20 |
| D5 | **重试=固定间隔，差异为零（本单元零改动）**；MIGRATION_PLAN §7"指数退避重试"措辞与源码冲突，建议主会话修订 | 源码全量 grep 核实无退避 |
| D6 | 计划宿主降级：源 Schedule 挂队列实体（queues.db）→ 暂挂 Config 六键 + 作用域=downloads 表全部未完成行；队列实体落地时迁移 | U3.1 无队列实体 |
| D7 | 计划时间粒度：源 TimeSpan Tick 级持久化但比较只到 HH:MM → 直接存分钟数 0..1439 | 语义等价 |
| D8 | 键名/钳制：`DefaltDownloadSpeed` 拼写纠正为 `defaultDownloadSpeed`；setSpeedLimit 规范化逐字；setSchedule 分钟钳 [0,1439]、daysMask &0x7F 防御 | ConfigIO.cs:166；U3.1 先例 |
| D9 | 定时器：setInterval + start() 立即首扫（dueTime:0 等价）；start() 幂等防泄漏（源 Start() 重复调用泄漏 Timer 不复刻）；60s 采样漏分钟=源同行为不补偿 | Scheduler.cs:28-41 |
| D10 | stopAll/resumeAll 作用域：源遍历队列成员清单 → 遍历 queryInProgress() 全部未完成行（stopOne 对非 live/queued 行幂等 no-op 无害） | 默认队列等价物 |
| D11 | resumeAll 单次读表：源两轮读取（队列清单+逐 id GetDownloadById）→ queryInProgress 一次取全记录直用 | 数据等价 |
| D12 | closeProgressWindow:true 不复刻（进度窗 UI 面，Phase 4 域） | ApplicationCore.cs:352 |
| D13 | nonInteractive 消费落地：resumeOne 可选参（源 ResumeDownload 第二参 :251）落 LiveSlot/QueuedEntry 预留字段；UI 效果 Phase 4 消费 | ResumeDownload :251/:324 |
| D14 | Scheduler 单例化 + tickCount 观测面为新增（源为 ApplicationCore 持有字段、无 tick 计数；服务探针诊断） | ApplicationCore.cs:597-601 |
| D15 | 时钟源：TickCount64（含睡眠）→ getUptime(ACTIVE)（不含深睡，API10+ d.ts:238 核实） | 活动下载场景等价 |
| D16 | 测量基准：源 GetDownloaded()=下载聚合字节 → worker 自身 written（本 attempt 字节）；resume/重派后基线自然重建 | 源每次 resume 新建 downloader 同构 |
| D17 | P3-U2 只探停止边界不探启动边界（任务书口径）：启动边界会 resume 全部未完成行含历史探针遗留行，观测不可确定；由纯函数单测+审查覆盖 | 任务书"定时窗停止观测" |
| D18 | WorkerResult 追加 4 个 throttle 观测字段（无源码对应物，平台行为观测面；JSON 消费方按字段名读取天然容忍） | 探针 S2 消费 |

另有 §0-7 零回归硬承诺：`enableSpeedLimit=false`（默认）时 worker 走 U2.1 原直写路径逐字节等价，泵/队列/水位/重连全部只在 throttleEnabled 分支存在——本单元最大回归风险的对冲设计。

## ④ 审查问题处置表（覆盖全部轮次）

审查轨迹：R2 轮 approved=**false**（6 findings）→ 修复 R2-F1 → R3 轮 approved=**true**（5 low 系 R2 延续项）；独立复核 acceptable=**true**（8 findings：1 medium + 7 low，含 3 项新发现）。同一问题跨轮延续的合并为一行。

| 编号（R2/R3/复核） | 严重度 | 位置 | 问题 | 处置 | 证据（本会话核实） |
|---|---|---|---|---|---|
| HVIGOR-F1 | 阻塞（编译） | SegmentWorker.ets | default import 致 hvigor 编译失败 | **已修复**（具名 import），复跑 assembleHap BUILD SUCCESSFUL in 14s 263ms | 实现清单；本报告会话重跑编译通过 |
| R2-F1 | high | SpeedLimit.test.ets:62-92 | 5 处用例以 nowMs=0 作基线，二次调用命中 :52 哨兵分支重建基线返 0（期望 900 实得 0），跑必挂；另 exactLimit 边界未被真正行使 | **已修复**：5 处基线改 nowMs=1000 并后移测量点（用例数不变 13 条，全 suite 仍 153）；node 逐字转写纯函数跑全部调用序列 36/36 断言 PASS；附带修复 exactLimit 声明处 `0 => {` 缺 `, ()` 语法残缺 | 本会话 Read 全文核实修复在位：:66/:74/:84/:92/:105 基线 nowMs=1000，:75 断言 900、:85 断言 exact 边界 0，注释逐处标注 R2-F1 |
| R2-F2 = R3-F1 = 复核 F2 | low | SegmentWorker.ets:99/:170、PieceGrabber.ets:469-470（对照 PieceGrabber.ets:489 与 SegmentWorker.ets:203） | 三处注释称"探测派发 speedLimitKBps 恒 0"，实际 dispatchPiece 对探测派发同样无条件传 shareKBps（限速开启时 >0）；行为无碍——:203 `throttleEnabled = speedLimitKBps>=1 && !probeMode` 门兜住探测不限速 | 未修（R3 轮 approved=true 放行），**转遗留 L2** | 本会话 Read :99/:170/:469-470/:489/:203 逐处核实，与审查描述一致 |
| R2-F3 = R3-F2 = 复核 F3 | low | 设计书 §3.3（:236 伪码）对照 Scheduler.ets:163-189 | stopAllAsync 实现为两趟次序（先清退 queued 再停 live），偏离设计书伪码单趟与源码 DownloadIds 顺序；代码内注释已论证必要性（本引擎 onPaused 回声同步触发 dequeueOne 补位，单趟先停 live 会起跑仍在队列的待停项），且两趟更忠实于源码批量快照语义，但设计书 D 清单未登记 | 未修，**转遗留 L3**（代码建议保留） | 本会话 Read 设计书 :236-240（伪码单趟）与 Scheduler.ets:163-189（两趟+论证注释）核实 |
| R2-F4 = R3-F3 = 复核 F4 | low | ProbeSpeedLimit.ets:150（EXPECT json:13/:28、PROBE 手册:107/:118 同名键） | S1 观测键名 `scheduleEnabledBefore` 实际取值是 `this.snapshot.enableSpeedLimit`（限速开关），非计划开关——键名与语义错位；EXPECT/手册已与 S4 `restoredLimitEnabled` 配对故三者自洽，但验证者单读日志行会误读 | 未修，**转遗留 L4** | 本会话 grep + Read :150 核实（`const scheduleEnabledBefore: boolean = this.snapshot.enableSpeedLimit;`） |
| R2-F5 = R3-F4 = 复核 F5 | low | MIGRATION_PLAN.md:146、UNIT_CATALOG.md:57 | 两文档仍写"指数退避重试"，与源码核实结论（固定间隔 RetryDelay×1000，全 Core 无退避计算）冲突；设计书 D5 已登记并建议主会话修订，至今未改——验收者按 PLAN/CATALOG 找指数退避会误判不通过 | 未修，**转遗留 L1**（建议主会话两处各改一词："固定间隔重试（MaxRetry=10/RetryDelay=10s）"） | 本会话 `grep -n "退避"` 两文件命中原文核实 |
| R2-F6 = R3-F5 = 复核 F6 | low | EXPECT json:18-19、PROBE 手册:108/:135（§5 分支表） | S2 判定盲区：EXPECT 要求 sleepCount>=1 且 avgRateKBs∈[716.8,1331.2]，但当网络速率落在 [716.8,1024)（慢于限额）时 sleepCount=0 是物理正确结果而 avgRate 仍在窗内——速率判据过、sleepCount 判据挂，无分支映射可归（手册 §5 env 分支仅覆盖 avgRate<716.8 且 sleepCount=0） | 未修，**转遗留 L5** | 本会话 Read EXPECT:19 分支映射与手册 §5 表格核实 |
| 复核 F1（新发现） | **medium** | Scheduler.ets:147-153 + EntryAbility.ets:52-60 + DownloadManager.ets:177-180 + DownloadStore.ets:143-148；对照 Scheduler.cs:65-82 | 启动分钟竞态吞掉整个调度窗：EntryAbility.onCreate 中 Scheduler.start()（:60）立即首扫，若启动分钟恰为 start 分钟，startOrStopItem 在 resumeAllAsync 之前同步 activeSchedules.add（:152-153），随后 queryInProgress 经 db() 的 await ready 门异步解析时 DownloadManager 可能尚未 init——resumeOne 落 :177-180 "init not called" 分支被丢弃，而查重门（:149-151）把后续每个 start 边界 tick 全部吞掉，直到 end 边界才清除——当天整个启动窗的定时恢复静默丢失。源码 AppDB 先于 StartScheduler 就绪且同步取 dict，无此竞态。当前仅可经探针残留/手工改 preferences 触发；U4 UI 落地 scheduleEnabled 后成为生产路径 | 未修（独立复核 acceptable=true 放行），**转遗留首位 L0** | 本会话 Read 四文件逐环节核实链路成立（:152 add 先于 :153 fire-and-forget；:177-180 丢弃分支；:144-148 await ready 门） |
| 复核 F7（新发现） | low | PieceGrabber.ets:820-821（对照守卫 :809 与累加点 :822-827） | 注释称 throttle 观测"无条件累加，attempt 无关——陈旧/取消回执的观测值同样入账"，但 onWorkerResult 守卫 :809（record 缺失/!alive/attempt 不匹配）在累加之前 return——被取消/替换 attempt 的回执观测值实际不入账。仅影响 D18 观测面完整性，限速行为与计费口径不受影响 | 未修，**转遗留 L6** | 本会话 Read :804-827 核实守卫先于累加 |
| 复核 F8（新发现） | low | ProbeSpeedLimit.ets:284-319（S2 轮询超时出口） | S2 引擎直驱超时（finished=false）退出轮询后未调用 dl.stop()——该 Downloader 不在 DownloadManager 集合内，S3 stopAllAsync（仅经 manager 作用域）与 S4 都够不到它：慢网下孤儿下载继续后台跑，干扰 S3 观测时序且永不收敛直到拼装完成或进程退出。EXPECT 仅写 finished=false → FAIL 分流，未提孤儿续跑 | 未修，**转遗留 L7**（修复：超时出口补 dl.stop()） | 本会话 Read :284-319 核实超时出口无 stop |

## ⑤ 验证情况

**1. hvigor 编译门禁（通过）**
- 单元执行侧：`devecocli build --modules entry` 最终状态通过（主会话门禁输出）；SegmentWorker HVIGOR-F1 修复后复跑 `hvigor assembleHap` BUILD SUCCESSFUL in 14s 263ms。
- 本报告会话重跑确认：`devecocli build --modules entry` → **BUILD SUCCESSFUL in 41 s 348 ms**（2026-09-29；仅 SignHap 跳过签名的环境提示——工程未配 signingConfigs，非错误）。**当前代码可构建。**

**2. codelinter 辅助检查（提示性，不作为 ArkTS 合规门禁）**：exit 0；Summary: Issues 14 / Errors 0 / Warnings 14 / Suggestions 0（Files checked 3；可见警告均为 `@performance/avoid-overusing-custom-component-check`，落在探针文件，属提示性建议）。主会话门禁输出中部截断，此处引用可见汇总行。实现侧另有 `devecocli check lint` 0 issues 记录（core 树，实现清单）。

**3. 单测（用例就位，hvigorw test 未运行）**
- 用例数：本会话 `grep -c "it("` 12 个测试文件实测合计 **153 条 = 127 既有（DownloadTypes 4 + EngineMath 10 + FileNameFormat 13 + HttpProtocol 26 + PieceAlgo 31 + ProbeDownloadLogic 4 + ProbeHttpLogic 16 + QueueAlgo 10 + RecordMapping 13）+ 26 新增（SpeedLimit 13 + ScheduleAlgo 13）**；List.test.ets 为注册入口不含 it(（grep=0，注册 speedLimitTest()+scheduleAlgoTest()）。
- **hvigorw test 在单元执行会话与本报告会话均未运行**（任务书约定由统一脚本执行）——"153 条全绿"目前是**未验证状态**而非已验证状态。实现侧的数学佐证：node 逐字转写 computeThrottleSleepMs 纯函数跑全部调用序列 36/36 断言 PASS（材料提供，本报告会话未重跑）；SpeedLimit/ScheduleAlgo 两条新增用例的期望值此前经人工复算（实现清单）。

**4. 对照审查（两轮收口）**：R2 approved=false（6 findings：1 high + 5 low）→ R2-F1 修复后 R3 approved=true（5 项 low 均为 R2 延续，明确"低级别项未修，继续上报"后放行）。收口口径：high/medium 全清（R2-F1 已修），low 遗留全部显式登记进⑦。

**5. 独立复核（acceptable=true）**：8 findings（1 medium + 7 low），并对高危面（限速数学、worker 泵/取消/fd 生命周期、两趟 stopAll）逐行复核未发现行为性缺陷；weakestSpot=Scheduler↔DownloadManager/DownloadStore 启动期异步边界（即复核 F1，见⑦ L0）。复核同时声明：hvigorw build/test 按任务书归脚本执行，153 条全绿门未由复核会话验证——与本报告⑤-3 口径一致。

**6. 本报告会话独立抽验清单（全部实际执行）**：
- 重跑编译门禁（`devecocli build --modules entry` → BUILD SUCCESSFUL in 41s 348ms）；
- `grep -c "it("` 12 测试文件 → 153 条；
- `git log --oneline -3`（最新提交 cf21776 = U3.1 收口）+ `git status --short`（9 修改 + 9 未跟踪 = U3.2 全部 18 文件，未提交）；
- `grep -n "退避"` MIGRATION_PLAN.md / UNIT_CATALOG.md → F5 遗留属实；
- Read 核实审查行号：Scheduler.ets:122-207、EntryAbility.ets:44-62、DownloadManager.ets:170-219、DownloadStore.ets:138-154、PieceGrabber.ets:455-499/:800-834、SegmentWorker.ets:90-214、ProbeSpeedLimit.ets:135-363、SpeedLimit.test.ets 全文；
- Read 核实设计书全文（§0 拍板注记 9 条、D 清单 18 项、§3 算法翻译、§6 探针步骤、§7 验收要点）与 EXPECT json 全文、PROBE 手册 :100-140；
- grep 核实 Config.ets 六键与 setSpeedLimit/setSchedule（:49-57/:93-98/:127-132/:169-189/:231-246）、SpeedLimiter.ets / ScheduleAlgo.ets 导出面、ProbeIndex.ets P3-U2 注册（:15/:30/:110-111）、string.json 2 键（:172/:176）；
- grep 核实 module.json5（deviceTypes :7、ohos.permission.INTERNET :14-16）与 main_pages.json（仅 Index + ProbeIndex）。

**7. ArkTS 合规说明**：codelinter 不含 ArkTS 语法规则，ArkTS 严格子集由 **hvigor 编译期强制**——本单元 hvigor 全量编译通过即合规面通过（无 any、对象字面量带类型、`queue.shift()` 窄化、无 for..in、Set/Map 受限面等由编译器把关；设计书 §7-[A]-1）。禁用结构化类型等规则在源文件层面以编码纪律自查（材料：编码员对照 arkts-grammar-standards 技能），无法以单条命令复核，如实注明。

## ⑥ 运行时验证待办（探针 P3-U2）

**状态：探针已生成、未运行，待人工在模拟器执行后回贴日志，用 xdm-probe-verify 工作流核对。**

- 探针页：`entry/src/main/ets/probe/units/ProbeSpeedLimit.ets`（P3-U2 四步全 autoRun，经 ProbeIndex 注册；冷启动 `page=probe` 路由）
- 运行手册：`docs/probe/PROBE-u3-2-speed-limit-retry-scheduler.md`（预期标记行示例、失败形态、§5 环境差异分支表）
- 预期表：`docs/probe/EXPECT-u3-2-speed-limit-retry-scheduler.json`（BEGIN + S1~S4 + SUMMARY + END 共 7 标记行；hilog 过滤 `XDM_PROBE`）
- 测试源：`docs/probe/P1-U2-download-server.js` **零改动复用**（/big.bin=4MiB 全速源、/slow.bin?ms=2500=定时窗长活源）

**运行前提（手册 §1）**：主机 `node P1-U2-download-server.js`；设备内填主机局域网 IP（禁 127.0.0.1）；网络快于 1024KB/s；避开午夜 ±2min（23:58~00:02）；探针会话内不切页；总时长 ≈4 分钟（S3 含 60~120s 分钟边界等待）。

**两条核心运行时验收**：
1. **限速实测吻合（S2）**：avgRateKBs∈[716.8,1331.2]（1024±30%）、activeSegmentMax=1、burstReopenCount=0、finished=true；sleepCount>=1（网络快于限额时）；sleepTotalMs/peakQueuedBytes 为事实项（区分 D3 背压形态，跑完回写设计书）。
2. **定时窗停止行为对照源码（S3）**：liveBefore=1/queuedBefore=2 → liveAfter=0/queuedAfter=0；pausedEcho=1、queuedCancelledEcho=2、resumedEcho=0（start==end 且 end 先判次序保真）；tickCountAfter>tickCountBefore。

## ⑦ 遗留问题与风险

按优先级（复核 F1 为唯一 medium，其余 low 均经 R3 approved=true 与独立复核 acceptable=true 放行）：

- **L0（medium，复核 F1）Scheduler 启动分钟竞态吞调度窗**：见④表。修复建议（复核已给）：`resumeAllAsync` 的 .then 内检测 manager.wrapper 缺失时 `activeSchedules.delete(SCHEDULE_KEY)` 留待下一 tick 重入；或把 add 移到异步动作确认生效之后；或将 EntryAbility 的 `Scheduler.start()` 延后到 DownloadStore.initialize.then 之后（两处任一闭环）。**建议下单元首个动作处理**——U4 落地 scheduleEnabled UI 后即成生产路径。
- **L1 文档措辞与源码冲突（复核 F5）**：MIGRATION_PLAN.md:146 与 UNIT_CATALOG.md:57 仍写"指数退避重试"，源码核实为固定间隔（D5）。建议主会话两处各改一词，防验收者按 PLAN 误判。
- **L2 三处注释与代码不符（复核 F2）**：SegmentWorker.ets:99/:170、PieceGrabber.ets:469-470 "探测派发 share 恒 0" 实为同传 share（:203 门兜底）。统一改注释或真按 probeMode 置 0，二选一。
- **L3 设计书与实现无据偏差（复核 F3）**：stopAllAsync 两趟次序未登记进设计书 §3.3/D 清单（代码有论证注释、建议保留）。补记一条 D 即闭环。
- **L4 探针键名语义错位（复核 F4）**：S1 `scheduleEnabledBefore` 实取限速开关（ProbeSpeedLimit.ets:150）。改名 limitEnabledBefore（探针+手册+EXPECT 四处同步）或改记真实 scheduleEnabled。
- **L5 S2 判定盲区（复核 F6）**：avgRate∈[716.8,1024) 且 sleepCount=0 无分支可归。EXPECT/手册增补 env 分支或给 sleepCount>=1 加"网络快于限额时"条件锚。
- **L6 观测注释与守卫不符（复核 F7）**：PieceGrabber.ets:820-821 "无条件累加"实被 :809 守卫拦截——仅影响 D18 观测面完整性。改注释即可。
- **L7 探针孤儿下载（复核 F8）**：S2 超时出口未 dl.stop()。超时分支补一行 stop 后再 emit。
- **开放问题（非缺陷）**：D3 原生背压形态未知——S2 peakQueuedBytes 观测值（≈0=有背压 / ≈文件长=burst-chasing）即结论本身，跑完回写设计书 D3 与 RISK_ASSESSMENT。
- **结构性风险**：D1 聚合限速偏差（多段并发时单 worker 全额 share 的保守方向聚合 ≤limit，少段相位低于 limit）与 D6 计划宿主降级（Config 六键替代 per-queue 实体）均为**已拍板、已登记**的有意差异，验收时按设计书口径评判，不算缺陷。
- **验证面风险**：hvigorw test 153 条与探针两条核心运行时验收均未实际执行——本单元"编译过"已双确认，"单测全绿/限速实测吻合/定时窗行为对照源码"三项在统一脚本与人工探针运行前保持未验证状态。

## ⑧ 对下个单元的建议

1. **先修 L0（复核 F1 启动竞态）**——U4 前唯一 medium；推荐"resumeAllAsync 内 wrapper 未就绪时回滚 activeSchedules 并留待下一 tick"方案（不引入启动时序耦合），修后补一条针对 start 边界+未 init 场景的静态审查项。
2. **低级别批量收口一次做完**：L2/L3/L4/L6（注释与文档登记类）+ L1（PLAN/CATALOG 两词，主会话动作）+ L5/L7（探针文档与探针代码，探针运行前修最佳——避免首跑日志产生不可归分支）。
3. **U4 设置页消费预告**：六个新键的 UI 写入一律走 `setSpeedLimit`/`setSchedule` 组合 setter（规范化/钳制已内聚在 Config.ets:231-246，UI 零重复逻辑）；限速热生效语义=下次派发（D2），计划=下一 tick，设置页文案按此写。
4. **队列实体落地时（U4 Queue 页）执行 D6 迁移**：Scheduler 构造注入"调度配置提供方"接口，ScheduleAlgo 纯函数面与状态机零改动；迁移时一并复核 L0 修复在新宿主下仍闭环。
5. **探针跑完后回写两项结论**：D3 背压形态（peakQueuedBytes 二值分布）与 P3-U2 运行结果——结论回设计书与 RISK_ASSESSMENT（主会话动作）。
6. **把 hvigorw test 纳入统一脚本门禁的显式步骤**并留存 153 条运行输出——本单元"全绿"验收点目前依赖约定而非证据，Phase 3 收口前补齐。
7. **重试路径 diff 门延续**：PieceGrabber.ets 的 retryImmediately/retryConnectPhase/retryAfterDelay 三方法块保持 diff 为空（D5 差异为零的持续证明），后续单元审查沿用此核对项。

## ⑨ 版本与提交说明

工程 XdmHarmony 为 git 仓库（本会话 `git log` 核实：最新提交 cf21776，即 U3.1 完成回填台账）。**U3.2 全部改动（9 个修改 + 9 个新增文件）当前处于工作区未提交状态**；按迁移流程约定，代码不做 git 提交，待人工验收（含统一脚本单测与 P3-U2 探针运行）通过后，由人工提交并按 Phase 打 tag。本报告会话未对任何源文件、配置或文档做修改（唯一写入为本报告文件自身）；`resourses/` 对照源码目录全程只读，未做任何编辑、创建或删除。

---

*报告完。证据可复现性：⑤-6 所列命令均在本报告会话（2026-09-29）于 D:/git/HarmonyPC/XdmHarmony 实际执行，行号引用以当日工作区状态为准。*
