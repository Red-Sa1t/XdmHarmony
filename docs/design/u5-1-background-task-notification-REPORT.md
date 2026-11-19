# U5.1 后台长时任务+通知 · 单元交付报告

> 单元：U5.1 后台长时任务+通知（Phase 5，M5 前置）｜ bundle：com.example.xdmharmony ｜ API 24 / SDK 6.1.1(24)
> 报告日期：2026-10-01 ｜ 源码对照：resourses/xdm（XDM 2023，C#/.NET，GPL-2.0，只读）
> 配套文档：[设计书](./u5-1-background-task-notification-DESIGN.md) ｜ [探针手册](../probe/PROBE-u5-1-background-task-notification.md) ｜ [预期表](../probe/EXPECT-u5-1-background-task-notification.json)
> **状态总览：编译门禁通过（本会话 clean 后全量复跑 BUILD SUCCESSFUL，0 ERROR）；codelinter 辅助检查 0 Error；代码、设计书、探针手册、预期表全部落盘；探针 P5-U1 待人工在模拟器/真机运行回贴。对照审查 R3 轮 approved，独立复核 acceptable=true，遗留 1 medium + 4 low 见 §7。**

---

## ① 单元范围与验收要点

### 1.1 任务书范围（五项）

1. module.json5 补 backgroundModes dataTransfer + KEEP_BACKGROUND_RUNNING 权限；
2. backgroundTaskManager 长时任务申请/释放（下载运行期持有）；
3. 常驻进度通知（节流更新）+ 完成通知；
4. 关窗后下载继续语义（EntryAbility/窗口关闭路径）；
5. 探针 P5-U1 后台存活+通知观测+手册。

### 1.2 验收四条对照

| 验收项 | 状态 | 证据 |
|---|---|---|
| 编译过 | **通过** | 本会话 `devecocli build clean` + `devecocli build --modules entry` → hvigor `BUILD SUCCESSFUL in 11 min 39 s 92 ms`，exit 0，0 ERROR（§5.1） |
| 关窗后下载继续 | 代码已落地，**运行时证据待探针** | `onPrepareToTerminate` 条件拦截+minimize（entry/src/main/ets/entryability/EntryAbility.ets:125-144）+ 长时任务保活（entry/src/main/ets/core/notify/ProgressNotifier.ets:206-271）；直接观测=P5-U1 S5-survived `advanced=true`（§6） |
| 通知进度刷新 | 代码已落地，**运行时证据待探针** | 实况窗五要素 publish（ProgressNotifier.ets:297-324），引擎 500ms 门直发（entry/src/main/ets/pages/Index.ets:510）；观测=P5-U1 S3（§6） |
| 事件面零破坏 | **通过（静态核对）** | Downloader.ets/DownloadManager.ets/NewDownloadDialog.ets 自基线 cfb3f74 零改动（git status 空清单）；Index.ets 五 handler 纯尾部追加（§5.4） |

### 1.3 实现文件清单（设计书 §1 十四项，全部落盘核实）

改 8：`entry/src/main/module.json5`、`entry/src/main/ets/entryability/EntryAbility.ets`、`entry/src/main/ets/pages/Index.ets`、`entry/src/main/ets/probe/ProbeIndex.ets`（:19/:38/:126-127 注册 P5-U1）、resources 三目录 string.json（:768-778 各加 3 键）、`entry/src/test/List.test.ets`（:46 import + :67 注册）。
新 6：`entry/src/main/ets/core/notify/NotifyAlgo.ets`、`entry/src/main/ets/core/notify/ProgressNotifier.ets`、`entry/src/main/ets/probe/units/ProbeBackgroundNotify.ets`、`entry/src/test/NotifyAlgo.test.ets`（12 用例）、`docs/probe/PROBE-u5-1-background-task-notification.md`、`docs/probe/EXPECT-u5-1-background-task-notification.json`。
零改动面核实：`main_pages.json`（tracked 未改）、`core/engine/**`、`model/**`、`core/db/**` 均不在 git 改动清单。

---

## ② 研究结论摘要（关键源码行为→ArkTS 对应表）

| # | 源码行为（对照锚） | ArkTS 对应（本单元落点，本会话逐一读码核实） | 有意差异 |
|---|---|---|---|
| 1 | `MainWindow.xaml.cs:674-678` Window_Closing=`e.Cancel=true; this.Hide()`（关窗仅隐藏，进程常驻）；`App.xaml.cs:137-142` SessionEnding→Exit(0)；托盘 Exit 为唯一主动退出 | `EntryAbility.onPrepareToTerminate(): boolean`（EntryAbility.ets:125-144）：activeCount>0 → 主窗 minimize + return true 拦截；==0 → return false 放行。真实退出=hamburger menu Exit→terminateSelf（Index.ets:1035-1040，接线 :1085-1090） | D3 条件化、D10 空闲退出、D4 |
| 2 | `ApplicationCore.cs:40` ActiveDownloadCount=live+queued；`Application.cs:152-156` 归零即切完成视图 | `DownloadManager.activeDownloadCount()` 读面（engine 零改动）+ `shouldApplyTask/shouldReleaseTask`（NotifyAlgo.ets:38-45）+ 申请/释放状态机（ProgressNotifier.ets:206-271） | — |
| 3 | 任务书所写 `startContinuousTask` 在 API 24 文档不存在（devecocli docs read 全文核实，研究结论 D1） | `startBackgroundRunning(context, ['dataTransfer'], wantAgent)` 12+ 形态，返回 notificationId（ProgressNotifier.ets:226-234；wantAgentInfo 显式类型 :215-225） | D1 |
| 4 | 实况窗五要素=系统契约：publish id=系统返回值、NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW、systemLiveView.typeCode=8、SlotType.LIVE_VIEW、template=downloadTemplate{title,fileName,progressValue}；超 10 分钟未更新系统取消任务 | `buildProgressRequest`（ProgressNotifier.ets:297-324）+ `publishProgress` fire-and-forget（:274-290） | D2、D6、D11 |
| 5 | `HTTPDownloaderBase.cs:288` 进度 500ms 门（EngineMath.shouldEmitProgress 既有 1:1） | Index.handleProgress 尾部转发 `onDownloadProgress`（Index.ets:510），publish 直发无二次节流 | D11 |
| 6 | Downloader.ets DownloadEvents/Noop/Forward 三声明=U2.1 冻结面 | 五 handler 尾部追加转发（Index.ets:475/:510/:528/:545/:582，既有字段写序零改动）；探针冷启动经 `ForwardDownloadEvents` 闭包组合自带同款转发（ProbeBackgroundNotify.ets:440-482） | — |
| 7 | `Application.cs:115-159` DownloadFinished：Size 回退 :126、归零切视图 :152-156；原版完成=DownloadCompleteDialog（无系统通知） | `finishedSize`（NotifyAlgo.ets:33-35）+ `onDownloadEnded('finished')` 释放判定（ProgressNotifier.ets:148-156）+ 完成通知（:329-350，id 1001/1002 撞号避让） | D5 新通道、D9 |
| 8 | `AppTrayIcon.cs:19-45` Config.ShowNotification 原语义=门媒体检测 balloon | `shouldPublishFinish` 只门完成通知、不门实况窗更新（NotifyAlgo.ets:48-50；Config.ets:587 读面） | D6（媒体 balloon 归 U6.2） |
| 9 | —（鸿蒙特有，WPF 无对应物） | `requestEnableNotification` 挂 loadContent 成功回调（EntryAbility.ets:204-207），拒绝后 1600004 不再弹只记日志 | D7 |
| 10 | `ClipboardMonitor.cs:25-70` app-lifetime 单例（Start 幂等、不随窗口显隐变化） | 本单元不动 clipboard/ 文件，仅登记保活依赖：U5.2 剪贴板 watcher 的关窗存活由本单元长时任务承载（设计书 §0-12） | D14 |
| 11 | —（观测 API：getAllContinuousTasks 20+ / continuousTaskCancel 15+） | 探针观测面：S1 基线+取消监听（ProbeBackgroundNotify.ets:144-154、:488-505）、S2/S4/S5 系统侧任务表读数（:205-211、:276-290、:400-402） | D12（NotifierStats 诊断计数） |

---

## ③ 设计决策与有意差异

计划条款引用：MIGRATION_PLAN **§6 决策 2**（线程模型——本单元投影为零 TaskPool，@kit 异步全部 fire-and-forget，ProgressNotifier.ets:20-21 注释与实现一致）；**§6 决策 11**（UI 契约——menu_exit 接线、通知文案走 resources）；**§7 Phase 5**（DATA_TRANSFER 长时任务+常驻通知=本单元承载；ClipboardWatcher/DocumentViewPicker 维持 U5.2 不变=D14）；UNIT_CATALOG U5.1 行（验收="关窗后下载继续；通知进度刷新"，前置 U3.1）。

| # | 差异 | 依据 |
|---|---|---|
| D1 | 任务书 `startContinuousTask` → 实装 `startBackgroundRunning(context,['dataTransfer'],wantAgent)` 12+ 形态 | API 24 文档核实（设计书 §0-1） |
| D2 | 实况窗进度通知本体（五要素）为鸿蒙系统契约，WPF 无进度系统通知对应物 | 拍板②（§0-2） |
| D3 | 关窗拦截**条件化**：仅活跃下载>0 拦截+minimize；WPF 无条件 e.Cancel+Hide 常驻 | 拍板③（§0-3） |
| D4 | 真实退出=hamburger menu Exit→terminateSelf（WPF 托盘 Exit 1:1）；statusBarManager 托盘本体按 U0.5 GO 登记 U5.2+；有活跃下载时 Dock 右键退出被一并拦截（平台无法区分关闭来源） | 拍板④（§0-4） |
| D5 | 完成通知=新通道（WPF 完成=DownloadCompleteDialog，关窗场景不可达） | §0-10 |
| D6 | ShowNotification 只门完成通知，不门实况窗进度更新（10 分钟系统取消契约优先）；原版门媒体 balloon 语义归 U6.2 | 拍板⑦（§0-7） |
| D7 | requestEnableNotification 通知授权前置为鸿蒙特有；拒绝后二次申请 openNotificationSettingsWithResult 不实装（err 1600004 仅观测） | §0-8 |
| D8 | 多下载（≤3 并发）聚合展示=最新活跃下载的文件名/进度共享一条实况窗 | §2 |
| D9 | 完成通知文案自拟登记（notify_finished_title="Download finished"，三 string.json :768 落盘）；原版唯一 balloon 文案留 U6.2 | AppTrayIcon.cs:19-45 |
| D10 | 空闲时 X 关窗=正常退出（WPF 空闲也常驻托盘）——无托盘实装前保留 Dock/系统退出路径 | 拍板③对偶面 |
| D11 | publish 直发（与引擎 500ms 门同步，无二次节流）；若探针实测卡顿再登记 1-2s 二次节流偏差 | 拍板⑥（§0-6） |
| D12 | NotifierStats 诊断计数（publishOk/publishFail/publishMsMax）为鸿蒙新增观测面，仅探针/诊断消费 | §2 |
| D13 | onPrepareToTerminate 真机不触发的降级预案=最小化即后台继续（保活语义不变仅失去 X 拦截），由 P5-U1 S5 走查实证判定 | §3.1 |
| D14 | MIGRATION_PLAN §7 Phase 5 的 ClipboardWatcher/DocumentViewPicker 维持 U5.2 不变，本单元仅登记保活依赖 | §0-12 |

---

## ④ 审查问题处置表（覆盖全部轮次）

轮次：R2 对照审查（approved=false，4 findings）→ 修复 R2-F1 → R3 对照审查（**approved=true**，2 findings 均 low）→ 独立复核（**acceptable=true**，5 findings：1 medium 新发现 + 4 low）。已修复编号：**R2-F1**；其余按流程 approved 后登记为遗留（§7），非阻塞项。

| 编号 | 严重度 | 问题摘要 | 处置 | 证据（本会话核实） |
|---|---|---|---|---|
| R2-F1 | medium | 探针申请/释放锚轮询乐观簿记值（isTaskApplied 在 IPC 往返前置位/复位），其后读 getAllContinuousTasks 会瞬态假 FAIL | **已修复**：S2/S5-armed 申请锚改轮询 `notifier.taskNotificationId()>=0`（startBackgroundRunning.then 簿记=真实注册完成）；S4 释放锚改 activeCount==0 后轮询 getAllContinuousTasks 至 0；手册/EXPECT 判定描述同步 | ProbeBackgroundNotify.ets:198-201（S2 注释+锚）、:271-290（S4 轮询）、:370-373（S5-armed）；EXPECT json sessions 字段与 S2/S4 note 含"R2-F1"标注；手册 :126/:128。生产状态机零改动（设计书 §3.2 乐观守卫拍板口径） |
| R2-F2 / R3-F2 / 复核-F3 | low | NotifyAlgo 注释与设计书 §1-#2 声称 clampProgress 为「Index.handleProgress :493 同款」，原实现实为越界归 0（现 Index.ets:503 `progress >= 0 && progress <= 100 ? progress : 0`），clampProgress 是 min/max 钳位——progress>100 分支语义不同 | **未修（登记）**：文档措辞级，行为差异仅防御性边缘；通知侧取 clamp 为有意选择 | NotifyAlgo.ets:5、:20 仍写「:493 同款」；设计书 :36 同；Index.ets:503 原文核实 |
| R2-F3 / R3-F1 / 复核-F2 | low | releaseTask.then 内先防御性 cancel(旧实况窗 id)（:259）后竞态回补 applyTask()（:264-266），两异步 IPC 无顺序保证——系统复用同一 notificationId 时可能误删新任务实况窗（下一条 500ms publish 同 id 重建，自愈，瞬态可见） | **未修（登记）**：自愈型瞬态；修复仅需调整 .then 内顺序 | ProgressNotifier.ets:258-266 顺序核实 |
| R2-F4 / 复核-F4 | low | S4 released 判定成立瞬间读通知计数，完成通知 publish 与实况窗防御性 cancel 在途，notifyCountWithFinish 瞬态 2 未覆盖；EXPECT S5 notifyCount「>=1」未覆盖 ShowNotification=false 且后台跑完时 0 的合法分支 | **未修（登记）**：EXPECT S4 已对 0 标 observe-both（EXPECT :51-52），对瞬态 2 与 S5 分支缺口保留 | ProbeBackgroundNotify.ets:294-295（released 后立即读数）；EXPECT :78（S5 notifyCount） |
| 复核-F1 | **medium（新发现）** | applyTask 仅入口乐观置 taskAppliedState=true（:214），成功 .then（:228-234）只簿记 id 从不复位 applied=true——若最后一个下载在 wantAgent→startBackgroundRunning 在途窗口内终结，releaseTask 会先于 apply 链执行 stop，终态=系统持有任务而簿记 applied=false（实况窗冻结/任务泄漏至 10 分钟系统取消/重申请撞已有任务） | **未修（登记，最高优先遗留）**：按设计书 §3.2「乐观守卫+失败回滚」拍板口径保留，修复建议=applyTask.then 补 applied=true 簿记+对称完成判定（镜像 releaseTask.then 回补）；留待 P5-U1 探针实证后决定返修 | ProgressNotifier.ets:211-214（入口置位）、:228-242（.then 只簿记 id）、:249-271（releaseTask） |
| 复核-F5 | low | 设计书 §6 探针步骤表未随 R2-F1 同步：S2 行（:197）仍写「轮询 ≤10s 至 notifier.isTaskApplied()」、S4 行（:199）仍写「且 !isTaskApplied()」——代码/手册/EXPECT 均已改系统侧锚，设计书漂移 | **未修（登记）**：按设计书复现的人会被误导，建议下轮一并更正 | 设计书 :197、:199 原文核实；手册 :126/:128 已是新锚 |

---

## ⑤ 验证情况

### 5.1 hvigor 编译门禁（验收①）——**通过**

| 执行 | 命令 | 结果 |
|---|---|---|
| 上游实现会话（材料记录） | hvigor 全量编译（devecocli build --modules entry） | BUILD SUCCESSFUL，0 ERROR（仅既有基线 ProbeHttp.ets:230 WARN+签名缺省 WARN） |
| **本会话复跑-增量** | `devecocli build --modules entry` | `BUILD SUCCESSFUL in 899 ms`，CompileArkTS UP-TO-DATE——盘上源码与上游全量编译成功时输入一致，无漂移 |
| **本会话复跑-全量** | `devecocli build clean` → `devecocli build --modules entry` | `BUILD SUCCESSFUL in 11 min 39 s 92 ms`，exit 0；捕获输出 0 ERROR，仅两条环境性 WARN（hvigor daemon 清理提示、`Will skip sign 'hos_hap'` 签名缺省） |

结论：**当前盘上代码可构建**，编译门禁以本会话全量复跑为准。ArkTS 严格子集由 hvigor 编译期强制（codelinter 不含 ArkTS 语法规则）——全量编译 0 ERROR 即语法面直接证据；高危点自查（wantAgentInfo 显式类型、Record 字面量引号键、downcast 前 undefined 窄化）在代码可见落地：ProgressNotifier.ets:215-225、:299-323、Index.ets:1036-1038。

### 5.2 codelinter 辅助检查（提示性）——**本会话复跑，与上游记录一致**

命令：`devecocli check lint entry/src/main/ets` → exit 0，`Summary: Issues: 19 | Errors: 0 | Warnings: 17 | Suggestions: 2 | Files checked: 5`。与上游门禁材料记录逐字一致。0 Error；Warnings/Suggestions 为既有基线（Index.ets LazyForEach cachedCount 提示等 @performance 提示性项，非本单元新增错误面）。

### 5.3 纯逻辑单测——存在性与注册已核实，**用例执行未运行**

NotifyAlgo.test.ets 含 12 条用例（`grep -c "it(" = 12`，设计书 §7 清单一致）；List.test.ets :46 import + :67 注册 notifyAlgoTest。本会话未执行 Hypium 运行器（需设备环境，非本单元门禁命令）；用例运行随探针阶段一并做。

### 5.4 事件面零破坏（验收④）——**静态核对通过**

- `git status --porcelain`：Downloader.ets / DownloadManager.ets / NewDownloadDialog.ets 不在改动清单（自基线 cfb3f74 零改动）；`core/engine/**`、`resources/base/profile/**` 改动数为 0；main_pages.json tracked 未改。
- `git diff --stat`：8 个改动文件合计 +149/−3；Index.ets 的 −3 行仅为 menu_exit 占位禁用项替换为启用项（diff 删除行核实），五 handler 均纯尾部追加（:475/:510/:528/:545/:582）。
- EntryAbility onCreate 既有语句序零改动（ProgressNotifier.init 于 :97 尾部追加）。

### 5.5 预期表与其他静态核实

- EXPECT json：`python -c "import json;json.load(open(...))"` → 合法（`EXPECT json OK`）。
- 资源键：notify_finished_title / probe_p5u1_title / probe_p5u1_check_hint 三键在 base/zh_CN/en_US 三 string.json :768-778 齐备。
- 探针注册：ProbeIndex.ets:19/:38/:126-127。
- git 状态：HEAD=cfb3f74「台账：U4.3 完成回填（M4 达成）/U5.1 启动」，**无 tag**；U5.1 全部改动未提交（§9）。

### 5.6 对照审查与独立复核结论

- R2 对照审查 approved=false → 修复 R2-F1 后 R3 轮 **approved=true**。
- 独立复核 **acceptable=true**，weakestSpot=ProgressNotifier 申请/释放状态机的两个异步 IPC 窗口（详见 §7 第一条）；复核同时确认运行时崩溃面未见未捕获抛出路径（publish/stop/cancel/getStringByNameSync/getMainWindowSync 均有 catch 收口）。
- 矛盾核对：门禁结论与审查结论无矛盾——R3 approved 指对照审查通过，其遗留 low 项与独立复核新发现按流程登记（本报告 §7），不构成"审查说通过但门禁失败"类冲突。

---

## ⑥ 运行时验证待办

**探针 P5-U1 已生成，待人工在模拟器/真机运行后回贴日志，用 xdm-probe-verify 工作流核对。**

- 手册：`XdmHarmony/docs/probe/PROBE-u5-1-background-task-notification.md`；预期表：`XdmHarmony/docs/probe/EXPECT-u5-1-background-task-notification.json`（8 步骤：BEGIN/S1-S5/SUMMARY/END）。
- 运行次序：①主机启动测试源 `node docs/probe/P1-U2-download-server.js`（零改动复用）→ ②探针页"运行全部"跑主会话（S1 授权+基线+取消监听、S2 申请锚 3×/slow.bin?ms=300、S3 实况窗观测、S4 完成→释放锚）→ ③S5 单步 armed（1×/slow.bin?ms=2000）→ ④人工走查：点 X 关窗→等 15-20s→Dock/任务栏恢复→回探针页 → ⑤S5 单步 survived（**验收锚**：taskAlive≥1、advanced=true、lastCancelReason=none）。
- 判定：S1~S4 取主会话，S5 取末次 runId（survived 段）。
- 环境注意：`onPrepareToTerminate`（X 拦截=最小化）**仅 2in1 形态生效**——模拟器 "Pura 90" 若非 2in1，走查项①按手册 §7 标注 ENV 后用 2in1 形态复验；保活链（S5 taskAlive/advanced）两环境均可验。首次运行会弹通知授权框（点允许；拒绝后 1600004 不再弹，需卸载重装复位）。
- 人工走查 8 项清单见手册 §5（其中项⑧ ShowNotification 门控走查后须打回 true）。
- 回写项（手册 §8）：S2 申请运行时锚、S3 publishMsMax（D11 二次节流偏差实证输入）、S4 释放/通知迁移/lastCancelReason、S5 后台存活+D13 判定、走查 8 项勾选。
- 单测执行（NotifyAlgo 12 条）随探针阶段在设备上运行核对。

---

## ⑦ 遗留问题与风险

**代码遗留（按优先级）**

1. **复核-F1（medium，最高优先）**：applyTask 成功 .then 不簿记 taskAppliedState=true，申请/释放 IPC 交错窗口内（最后一个下载在 wantAgent→startBackgroundRunning 在途数十~数百 ms 内终结，LAN 404/秒断可触发）产生"系统持有任务+簿记未申请"失同步——实况窗冻结、任务泄漏至 10 分钟系统取消、重申请撞已有任务。建议修法（一行级）：applyTask.then 内补 `taskAppliedState=true` 簿记 + 对称完成判定 `if (shouldReleaseTask(activeCount, true)) releaseTask()`（镜像 releaseTask.then :264-266 的竞态回补）。当前按设计书 §3.2 拍板口径保留、生产状态机零改动——**探针 P5-U1 运行若复现实况窗冻结/lastCancelReason=12，即为本项返修触发条件**。
2. R3-F1/复核-F2（low）：releaseTask.then 内 cancel(旧 id) 与竞态回补 applyTask 乱序，系统复用 notificationId 时瞬态误删（下一条 500ms publish 同 id 自愈）。修法：调换 .then 内顺序。
3. R3-F2/复核-F3（low）：clampProgress 注释/设计书 :36 措辞「:493 同款」不实（原为越界归 0，现 Index.ets:503）——文档措辞更正即可，代码/用例不动。
4. 复核-F4（low）：EXPECT S4 notifyCountWithFinish 瞬态 2 分支、S5 notifyCount 的 ShowNotification=false 合法分支未覆盖——verify 可能误判，建议 EXPECT 补 observe 分支或探针 S4 读数前 sleep≈500ms。
5. 复核-F5（low）：设计书 §6 S2/S4 行锚描述未随 R2-F1 同步（:197/:199）——文档同步项。

**平台/环境风险**

- D13：onPrepareToTerminate 仅 2in1 生效，真机/模拟器不触发时降级"最小化即后台继续"（保活语义不变）；S5 走查实证后回写。
- D11：publish 直发的系统调用开销未知，S3 publishMsMax 为实证输入（>100ms 量级再登记二次节流偏差）。
- 排队场景申请/释放抖动：activeCount 含 queued，归零即释放可能反复申请/释放（设计书 §0-5 预设探针观测后处置，备选"延迟数秒释放"需登记偏差）。
- 通知授权 1600004 死角（D7）：用户拒绝后无法再弹，需卸载重装——手册 §7 已列处置。

---

## ⑧ 对下个单元（U5.2 剪贴板监视+保存目录）的建议

1. **开工前先落实复核-F1 返修**：U5.2 剪贴板 watcher 的关窗存活直接依赖本单元长时任务健康度，失同步场景下保活地基不稳；返修面仅 ProgressNotifier.applyTask()，与 U5.2 文件无交叠。
2. watcher 挂 ApplicationContext 级生命周期（对照 ClipboardMonitor.cs app-lifetime 单例 + Application.cs:34 一次性挂接；设计书 §0-12 已登记依赖），Start/Stop 幂等守卫照抄源码 ：43/:55 形态。
3. 消费 U5.1 探针回写：S5-survived 的 taskAlive/lastCancelReason 作为 U5.2 关窗后剪贴板持续工作的保活健康度锚；publishMsMax 决定 D11 是否登记二次节流偏差。
4. statusBarManager 托盘本体按 U0.5 GO 信号实装（D4 已登记 U5.2+）：实装后 D10（空闲 X 退出）可复核——WPF 语义是空闲也常驻托盘。
5. 文档同步纪律（复核-F5 教训）：设计书 §6 探针步骤表、代码锚、手册 §6、EXPECT 四处需同轮同步修改。
6. U6.2 预留：媒体检测 balloon 文案键（MEDIA_DOWNLOAD_VIDEO/MSG_DWN_VID_DESC）按 English.txt:12/204 对照登记时，ShowNotification 门控语义届时扩展回媒体 balloon（本单元 D6 只门完成通知是阶段性行为）。

---

## ⑨ 说明：代码未提交

**本单元全部代码与文档未做 git 提交**，待人工验收（含探针 P5-U1 运行回贴与 verify 核对）通过后由人提交并按 Phase 打 tag。

证据：XdmHarmony 仓库 HEAD=cfb3f74「台账：U4.3 完成回填（M4 达成）/U5.1 启动」，`git status --porcelain` 显示 8 个修改文件 + 6 个未跟踪路径（core/notify/、ProbeBackgroundNotify.ets、NotifyAlgo.test.ets、设计书、探针手册、预期表）均为本单元产物，全部处于工作区未提交状态；`git tag` 为空，尚无任何里程碑 tag。
