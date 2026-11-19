# U5.1 后台长时任务 + 通知 · 模块设计书

> 单元：U5.1 后台长时任务+通知（Phase 5，M5 前置）。前置：U3.1（DownloadManager activeDownloadCount 口径）、U4.3（EntryAbility onCreate 调序刚定版 + ShowNotification 键）。
> 配套：[MIGRATION_PLAN](../../MIGRATION_PLAN.md) §5 结构、§6 决策 2/11、§7 Phase 5、[UNIT_CATALOG](../../UNIT_CATALOG.md) U5.1 行、[PROBE_SPEC](../../PROBE_SPEC.md)、[U0.5 平台调研](../research/U0.5-PLATFORM-RESEARCH.md)。
> 源码锚（本会话逐一读过核实）：`XDM.Wpf.UI/MainWindow/MainWindow.xaml.cs:674-678`（Window_Closing=e.Cancel+Hide）、`XDM.Wpf.UI/App.xaml.cs:78-84/:137-142`（TrayClick 恢复 / SessionEnding→Exit(0)）、`XDM.Wpf.UI/AppTrayIcon.cs:19-45`（唯一 balloon：ShowNotification 门控 MSG_DOWNLOAD_VIDEO→点击开 MediaGrabber）、`XDM.Core/Application.cs:115-159`（DownloadFinished：MarkAsFinished→FinishedDownloadItem.Size 回退 :126→ActiveDownloadCount==0 && IsInProgressViewSelected→SwitchToFinishedView :152-156）、`XDM.Core/ApplicationCore.cs:40`（ActiveDownloadCount=liveDownloads.Count+queuedDownloads.Count）、`XDM.Core/Config.cs:48-50`（DefaultShowNotification=true / ShowNotification=true）、`XDM.Core/ClipboardMonitor.cs`（app-lifetime 单例语义，U5.2 依赖标注）。
> 目标侧现状（本会话读过核实）：`module.json5`（requestPermissions 仅 INTERNET；deviceTypes 已含 2in1；abilities[0] 无 backgroundModes）、`entryability/EntryAbility.ets`（U4.3 调序定版；无 onPrepareToTerminate；无 windowStageClose 监听）、`pages/Index.ets`（五 handler 尾部转发模式先例=progressHost；汉堡菜单 menu_exit 占位禁用 :1050）、`core/engine/Downloader.ets`（DownloadEvents/Noop/Forward 三声明冻结）、`core/engine/DownloadManager.ets`（activeDownloadCount()=live+queued :256-258）、`core/engine/EngineMath.ets:68-70`（shouldEmitProgress 500ms 门）、`core/Config.ets:587-594`（getShowNotification）、`probe/core/{ProbeKit,ProbePage}.ets`、`probe/ProbeIndex.ets`（P0-U0…P4-U3 共 11 单元）、`docs/probe/P1-U2-download-server.js`（/slow.bin?ms=N 测试源）。
> API 证据（本会话 `devecocli docs read` 逐篇核实，命令与文档 ID 见 §0 各条）。

---

## 0. 冲突与拍板注记（必读）

1. **研究结论 API 纠偏①（任务书所写 `startContinuousTask` 不存在）**：本会话 `devecocli docs read "API参考/Background_Tasks_Kit_后台任务开发服务/ArkTS_API/ohos_resourceschedule_backgroundTaskManager_后台任务管理_/js-apis-resourceschedule-backgroundtaskmanager"` 全文核实：API 24 文档只有 `startBackgroundRunning` 三形态——(context, bgMode, wantAgent)（9+ 枚举遗留）、**`startBackgroundRunning(context, bgModes: string[], wantAgent): Promise<ContinuousTaskNotification>`（12+，本单元采用）**、(context, ContinuousTaskRequest)（21+）。12+ 形态返回 `res.notificationId`（`continuousTaskId` 15+ 可选字段，返回值里可能为 undefined——探针只记观测值）；错误码 201/401/9800005（Continuous task verification failed）/9800006（Notification verification failed）。**一个 UIAbility 同一时刻仅支持一个长时任务**（文档明示）→ 全应用单实例语义是硬约束不是选择。文档同步确认：`stopBackgroundRunning(context): Promise<void>` 取消当前 UIAbility 下**所有**长时任务；`getAllContinuousTasks(context): Promise<ContinuousTaskInfo[]>`（20+）返回 backgroundModes/notificationId/continuousTaskId/suspendState/wantAgentAbilityName；`on('continuousTaskCancel')`（15+，需 KEEP_BACKGROUND_RUNNING）回调 `{reason, id}`；`ContinuousTaskCancelReason`（15+）枚举仅 1..11，`SYSTEM_CANCEL_DATA_TRANSFER_NOT_UPDATE=12` 属 `ContinuousTaskDetailedCancelReason`（**26+**）——API 24 上探针**只记数字 reason，不做枚举名映射**。
2. **拍板②：实况窗进度通知是系统契约不是 UX 装饰**。同篇文档 dataTransfer 示例核实五要素：①publish 的 `id` **必须**等于长时任务返回的 notificationId；②`notificationContentType=ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW`（notificationManager 文档 :1972 核实：三方不能直接创建该类型，只能发布同 ID 更新系统代建的那条）；③`systemLiveView.typeCode=8`（dataTransfer 专用且仅支持此值）；④`notificationSlotType=SlotType.LIVE_VIEW`；⑤`template={name:'downloadTemplate', data:{title, fileName, progressValue 必填}}`。**进度超过 10 分钟未更新→系统取消长时任务**（SYSTEM_CANCEL_DATA_TRANSFER_NOT_UPDATE=12）。因此引擎 500ms 门（EngineMath.shouldEmitProgress=HTTPDownloaderBase.cs:288 1:1）直通 publish 天然满足契约；活跃下载停滞期最坏=MaxRetry×RetryDelay=10×10s=100s ≪ 10min，排队补位为秒级——无契约违约路径。
3. **拍板③：关窗拦截=条件拦截+minimize**。faqs-ability-151（本会话读全文）核实：`onPrepareToTerminate(): boolean` 仅 2in1 生效 + 需 `ohos.permission.PREPARE_APP_TERMINATE`（permissions-for-all :33-42 核实：normal/system_grant/起始版本 10）；回调触发点=**窗口 X 关闭与 Dock/托盘右键退出两者**，返回 true 拦截；互斥规则：实现 onPrepareToTerminateAsync、AbilityStage.onPrepareTermination* 或注册 `windowStage.on('windowStageClose')` 任一即不执行（本工程三处皆无，EntryAbility.ets 全文核实）。**拍板行为**：`DownloadManager.activeDownloadCount()>0` → `return true` + 主窗 `minimize()`（faqs-arkui-889 核实：主窗 minimize=最小化，Dock 可还原；子窗才是隐藏）→ 下载在长时任务下继续；`activeCount==0` → `return false` 放行正常关闭。WPF 是无条件 `e.Cancel=true; this.Hide()`（MainWindow.xaml.cs:674-678），差异 D3/D10 登记。
4. **拍板④：真实退出路径=hamburger menu Exit 接线**（WPF `menuExit.Click→Environment.Exit(0)` 1:1；托盘本体 statusBarManager 按 U0.5 结论=GO 信号但实装超本单元面，登记 U5.2+）。menu_exit 从占位禁用改为 `terminateSelf()`；不加二次确认（源 Exit 即刻退出，下载一并终止=WPF 同貌）。副作用登记：有活跃下载时 Dock 右键退出也会被 onPrepareToTerminate 拦截（平台无法区分关闭来源）——用户恢复窗口后经汉堡菜单 Exit 真正退出。
5. **拍板⑤：申请/释放粒度=0→非 0 申请、归零即释放**（对照 ApplicationCore.cs:40 ActiveDownloadCount 与 Application.cs:152-156 归零即切完成视图的时点同构；DownloadManager.activeDownloadCount() 已是 live+queued 同口径）。**stop/apply 竞态回补**：`stopBackgroundRunning().then` 内复查 `activeCount>0` 则重申请（归零判定与补位 dequeueOne 都在主线程事件循环内串行，竞态窗口仅存在于异步 then 恢复点）。探针若发现频繁申请/释放抖动 → 登记"延迟释放"偏差，本设计不预设。
6. **拍板⑥：publish 直发，无二次节流**（openQuestion 拍板：默认与引擎 500ms 门同步直发）。ProgressNotifier 内置 publish 诊断计数（ok/fail/msMax，仅观测面），P5-U1 探针 S3 记录；若实测明显卡顿 → 登记 1-2s 二次节流偏差返修，本设计不预设。
7. **ShowNotification 门控范围拍板**：`Config.getShowNotification()`（Config.ets:587，默认 true，源 Config.cs:50）**只门控完成通知**，不门控实况窗进度更新（进度更新=长时任务系统契约，见拍板②，门掉会触发 10 分钟系统取消→破坏"关窗后下载继续"）。源版该键原语义=媒体检测 balloon 门控（AppTrayIcon.cs:21 `Config.Instance.ShowNotification`），媒体 balloon 本体归 U6.2。
8. **通知授权前置（鸿蒙特有，WPF 无对应物）**：`requestEnableNotification(context)` 仅可在 loadContent 成功后调用（notificationManager 文档 :1461-1587 核实，10+）；授权弹窗仅首次，用户拒绝后该接口无法再弹（err 1600004），二次申请 `openNotificationSettingsWithResult` **不实装**（差异 D7 登记）；通知开关关闭时 publish 无报错但不显示；`isNotificationEnabledSync()`（12+）供探针观测。
9. **module.json5 改动面=三处**（module-configuration-file :282/:333 核实 backgroundModes 为 ability 级字符串数组标签，可缺省）：requestPermissions 加 `KEEP_BACKGROUND_RUNNING`（normal/system_grant/起始版本 8，permissions-for-all :171-178 核实）与 `PREPARE_APP_TERMINATE`；abilities[0]（EntryAbility 节点）加 `backgroundModes: ["dataTransfer"]`。deviceTypes 已含 2in1、INTERNET 已有，均不动；main_pages.json **零改动**（探针子页走 ProbeIndex 条件渲染，U0.1 惯例）。
10. **完成通知=新通道**（WPF 无系统通知完成语义，原版完成=DownloadCompleteDialog 不可达于关窗场景，本设计书登记为新行为）；完成 Size 回退规则照抄 Application.cs:126 `downloadEntry.Size>0 ? downloadEntry.Size : finalFileSize`，抽为纯函数（§3.4）。完成通知 id 自选固定值 1001（与长时任务系统 id 区间避让：若系统返回 notificationId===1001 则用 1002，`pickFinishNotificationId` 纯函数）；长时任务释放后对系统实况窗通知做一次防御性 `cancel(taskNotificationId)`（catch 忽略——系统大概率已随任务取消代删）。
11. **事件面零破坏红线（单元验收①）**：`Downloader.ets` 三声明、`DownloadManager.ets` 全文件、`NewDownloadDialog.ets` 零改动；Index 五 handler（handleStarted/Connected/Progress/Paused/Failed/Finished）**既有字段写序逐字节不动**，ProgressNotifier 只在方法尾部追加转发（U4.2 progressHost 同款手法）；探针经自身事件袋尾部转发消费同一 ProgressNotifier 公开面（page=probe 冷启动时 Index 不加载，探针必须自带转发——P3-U1 事件袋先例）。
12. **U5.2 依赖标注**：ClipboardWatcher（pasteboard.on('update')）挂 ApplicationContext 级生命周期（对照 ClipboardMonitor.cs app-lifetime 单例 + Application.cs:34 WindowLoaded 一次性挂接），关窗后的持续监视依赖本单元长时任务保活——本单元不动 clipboard/ 文件，仅在此登记依赖关系。
13. **纯逻辑拆分**：本单元决策类判断全部抽 `core/notify/NotifyAlgo.ets` 纯函数（零 @kit import，Hypium 直载，QueueAlgo/ScheduleAlgo 先例）；ProgressNotifier 承载 @kit API 编排与异步状态机。业务日志 hilog domain 0x0000、零 probe import、`[XDM_PROBE]` 仅 ProbeKit 出口（分层红线沿用）。

---

## 1. 目标文件清单（按实现顺序）

> 新 5 / 改 9，共 14 项（业务新 2+改 3；配置改 1；资源改 3；单测新 1+改 1；探针新 1+改 1；文档新 2）。`main_pages.json`、`core/engine/**`、`model/**`、`core/db/**`、`components/**` 零改动。业务文件禁 import `probe/**`（审查红线）。

| # | 文件 | 新/改 | 职责与对外导出 | dependsOn |
|---|---|---|---|---|
| 1 | `entry/src/main/module.json5` | 改 | 三处增量（§0-9）：①requestPermissions 数组追加 `{"name": "ohos.permission.KEEP_BACKGROUND_RUNNING"}` 与 `{"name": "ohos.permission.PREPARE_APP_TERMINATE"}`（顺序：INTERNET 后追加，不动既有项）；②abilities[0]（EntryAbility 节点，skills 之前或之后皆可、推荐紧跟 exported）加 `"backgroundModes": ["dataTransfer"]`；③其余字段逐字节不动 | — |
| 2 | `entry/src/main/ets/core/notify/NotifyAlgo.ets` | 新 | 通知决策纯函数层（零 import，Hypium 直载）：`clampProgress(progress): number`（[0,100] 钳位，Index.handleProgress :493 同款）、`finishedSize(recordedSize, finalFileSize): number`（Application.cs:126 回退规则 §3.4）、`shouldApplyTask(activeCount, taskApplied): boolean`（activeCount>0 && !taskApplied）、`shouldReleaseTask(activeCount, taskApplied): boolean`（activeCount<=0 && taskApplied）、`shouldPublishFinish(showNotification): boolean`（门控 §0-7）、`pickFinishNotificationId(taskNotificationId): number`（===1001?1002:1001）、常量 `FINISH_NOTIFY_ID_BASE=1001`、`PROGRESS_MIN=0`/`PROGRESS_MAX=100` | — |
| 3 | `entry/src/test/NotifyAlgo.test.ets` | 新 | §7 Hypium 用例 12 条 | #2 |
| 4 | `entry/src/test/List.test.ets` | 改 | testsuite 追加 `notifyAlgoTest()` 注册 + 头部注释补 U5.1 行（229+12=241 条） | #3 |
| 5 | `entry/src/main/resources/base/element/string.json` | 改 | 追加 3 键：`notify_finished_title`（"Download finished"）、`probe_p5u1_title`（"P5-U1 后台任务+通知探针"）、`probe_p5u1_check_hint`（"按手册完成后台存活走查（关窗→等待→恢复）后单步执行 S5"）。实况窗 title/fileName 用文件名原值、text 用百分比数字——不占资源键 | — |
| 6 | `entry/src/main/resources/zh_CN/element/string.json` | 改 | 同步 3 键（notify_finished_title="下载完成"；probe 两键同 base 中文） | #5 |
| 7 | `entry/src/main/resources/en_US/element/string.json` | 改 | 同步 3 键（notify_finished_title="Download finished"） | #5 |
| 8 | `entry/src/main/ets/core/notify/ProgressNotifier.ets` | 新 | **本单元核心**。应用级单例（DownloadManager 同款 getInstance），对外导出：`init(context: common.UIAbilityContext): void`（存 UIAbilityContext+装载完成通知标题 `context.resourceManager.getStringByNameSync('notify_finished_title')`——本会话 SDK d.ts:2454 核实存在；失败回退 'Download finished' 常量）、`onDownloadStarted(id, fileName): void`、`onDownloadProgress(id, fileName, progress): void`、`onDownloadEnded(id, kind: 'paused'\|'failed'\|'finished', finalFileSize, filePath): void`、观测面 `isTaskApplied(): boolean`/`taskNotificationId(): number`（未申请=-1）/`stats(): NotifierStats`（publishOk/publishFail/publishMsMax）。内部状态机与五要素 publish 见 §2/§3.2/§3.3。import 面：backgroundTaskManager/notificationManager/wantAgent（@kit.BackgroundTasksKit、@kit.NotificationKit、@kit.AbilityKit）+ NotifyAlgo + Config + hilog。**不 import Index**（activeDownloadCount 经 DownloadManager 单例读面，依赖方向 core/engine ← core/notify 单向） | #2 #5 |
| 9 | `entry/src/main/ets/entryability/EntryAbility.ets` | 改 | 只加不改（U4.3 调序红线）：①onCreate 尾部（Scheduler.start() 之后）加 `ProgressNotifier.getInstance().init(this.context)`；②loadTarget() 的 loadContent 成功回调内追加 `requestEnableNotification(this.context)`（try/catch，err 1600004 等只记 0x0000 日志不重试，§0-8）；③新增 `onPrepareToTerminate(): boolean`（§3.1；import DownloadManager 读 activeDownloadCount——UIAbility 层 import core 层方向合法） | #8 |
| 10 | `entry/src/main/ets/pages/Index.ets` | 改 | 三处增量（既有写序逐字节不动）：①五 handler 尾部追加 notifier 转发（§3.3/§3.4：handleStarted→onDownloadStarted、handleProgress→onDownloadProgress、handlePaused→onDownloadEnded('paused')、handleFailed→onDownloadEnded('failed')、handleFinished→onDownloadEnded('finished')）；②`mainMenuItems()` 的 menu_exit 项启用：`{ value: $r('app.string.menu_exit'), action: () => { this.handleMenuExit(); } }`；③新增 `private handleMenuExit(): void`——`const ctx = this.getUIContext().getHostContext(); if (ctx !== undefined) { (ctx as common.UIAbilityContext).terminateSelf(); }`（import { common } from '@kit.AbilityKit'；官方样例同款 downcast，undefined 已窄化） | #8 |
| 11 | `entry/src/main/ets/probe/units/ProbeBackgroundNotify.ets` | 新 | P5-U1 探针（§6 五步）：事件袋 ForwardDownloadEvents 尾部转发 ProgressNotifier（page=probe 冷启动 Index 不在，探针自带同款转发——§0-11）；S1 授权+基线+continuousTaskCancel 监听注册 / S2 提交 3 下载+申请锚 / S3 实况窗 publish 观测 / S4 完成→释放+完成通知锚 / S5 后台存活人工走查（autoRun=false，两阶段单步 armed→survived）。模块级 static 存 armed 快照与 lastCancel（跨会话进程内持久）。**不经Notifier以外的任何私有通道** | #8 |
| 12 | `entry/src/main/ets/probe/ProbeIndex.ets` | 改 | PROBE_UNITS 追加 `{unitId:'P5-U1', title: $r('app.string.probe_p5u1_title')}` 表项 + else-if 分支 `ProbeBackgroundNotify()`（U0.1 注册惯例） | #11 |
| 13 | `docs/probe/PROBE-u5-1-background-task-notification.md` | 新 | 探针手册：测试源=P1-U2-download-server.js 复用零改动（§6 前置）+ 人工走查清单 8 项 + 运行/抓取命令 + 环境差异分支表 | #11 |
| 14 | `docs/probe/EXPECT-u5-1-background-task-notification.json` | 新 | verify 期望表（S1~S5 键值期望；后台存活/通知计数项标注 observe-both 与环境敏感） | #13 |

---

## 2. 数据模型与表结构（对照源码逐一核对）

**DB 零变更**：downloads 表 22 列不动（进度落库沿用 handleProgress 既有 `DownloadStore.updateProgress(id, progress)`——对照源 Application.cs:323-331 逐事件写库链已由 U1.2 落地）；preferences 零新键（通知文案走 resources）。

**ProgressNotifier 内存态**（对照源逐一核对）：

| 字段 | 类型 | 语义 | 源锚/对照 |
|---|---|---|---|
| `context` | `common.UIAbilityContext \| undefined` | startBackgroundRunning/stopBackgroundRunning/publish/wantAgent 的 context（文档：Stage 模型仅 UIAbility 可申请） | EntryAbility.init 传入 |
| `taskApplied` | boolean | 长时任务申请态（全应用单实例硬约束，§0-1） | ApplicationCore.ActiveDownloadCount 0↔>0 跃迁 |
| `taskNotificationId` | number（未申请=-1） | 系统代建实况窗通知 id（res.notificationId）——publish 更新与防御性 cancel 都用**系统返回值，严禁自选** | ContinuousTaskNotification.notificationId（文档 12+ 形态） |
| `continuousTaskId` | number（未申请=-1，返回 undefined 记 -1） | 长时任务 id（观测/探针用；API 24 的 stop 走 context 全量取消，不用 id 形态——那是 21+） | ContinuousTaskNotification.continuousTaskId（15+ 可选） |
| `finishNotifyId` | number | 完成通知固定 id=1001（与系统返回撞号则 1002）——`pickFinishNotificationId` | §0-10 |
| `latestFileName` / `latestProgress` | string / number | 多下载聚合展示=**最新一次进度事件的下载**（≤3 并发共享一条实况窗） | D8（WPF 无对应物，展示选择） |
| `finishedTitle` | string | 完成通知标题（init 时装载，失败回退 'Download finished'） | 新增资源键 notify_finished_title |
| `publishOk` / `publishFail` / `publishMsMax` | number | publish 诊断计数（ok/fail/单次最大耗时 ms；**观测面非控制面**） | D12（鸿蒙新增，探针 S3 消费） |
| 模块级 `LastCancel.reason/id/caught` | number/number/boolean | 探针注册的 continuousTaskCancel 监听写入（跨会话进程内持久；业务代码不注册不消费） | on('continuousTaskCancel') 15+ |

**通知请求形状**（逐字段核对文档示例）：

```
实况窗更新（onDownloadProgress）              完成通知（onDownloadEnded('finished')）
{                                             {
  id: taskNotificationId,     // 系统返回值      id: finishNotifyId,          // 自选 1001/1002
  notificationSlotType: SlotType.LIVE_VIEW,    content: { notificationContentType:
  content: { notificationContentType:            ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
    ContentType.NOTIFICATION_CONTENT_SYSTEM_      basic: { title: finishedTitle,
      LIVE_VIEW,                                           text: fileName } } }
    systemLiveView: { typeCode: 8,             // 无 template/slotType 字段（默认渠道）
      title: fileName, text: '<n>%' } },     }
  template: { name: 'downloadTemplate',
    data: { title: fileName, fileName: fileName,
      progressValue: clampProgress(progress) } }
}
```

**完成 Size 回退**（Application.cs:126 1:1，纯函数化）：`finishedSize(recordedSize, finalFileSize) = recordedSize > 0 ? recordedSize : finalFileSize`；调用点=handleFinished 尾部转发（record.size 已被既有链路更新，取更新后值传入——与源 GetDownloadById 回读同义）。

---

## 3. 关键算法翻译说明

### 3.1 关窗拦截状态机（MainWindow.xaml.cs:674-678 → onPrepareToTerminate）

```
WPF: Window_Closing → e.Cancel=true; this.Hide()   // 无条件，进程常驻
鸿蒙: onPrepareToTerminate(): boolean
  ├─ DownloadManager.activeDownloadCount() > 0 ?
  │    ├─ 是 → windowStage.getMainWindowSync().minimize()   // 主窗 minimize=Dock 可还原（faqs-arkui-889）
  │    │       return true                                   // 拦截=X=最小化，下载在长时任务下继续
  │    └─ 否 → return false                                  // 空闲放行（D10：WPF 空闲也常驻）
```

要点：①getMainWindowSync 可能抛错（窗口态异常）——try/catch 吞掉仍 `return true`（窗口保持打开属无害降级）；②互斥规则三清空已核实（§0-3）：本工程不实现 onPrepareToTerminateAsync、无 AbilityStage.onPrepareTermination*、无 windowStageClose 监听；③真机实测若回调不触发（onPrepareToTerminate 系 PC 形态行为）→ 降级"最小化即后台继续"（用户手动最小化，长时任务同样保活）——探针 S5 走查结果回填后由 verify 判定，编码期按 faqs-ability-151 原样实现即可。

### 3.2 长时任务申请/释放状态机（Idle→Applying→Applied→Releasing）

```
onDownloadStarted(id, fileName):        // handleStarted 尾部/探针事件袋尾部调用
  if shouldApplyTask(activeCount, taskApplied):      // activeCount>0 && !taskApplied（NotifyAlgo）
    taskApplied 置位采用"乐观守卫+失败回滚"：立即置 true 防同帧重复申请（主线程串行，无真并发）
    → wantAgent.getWantAgent(wantAgentInfo)          // wants=[{bundleName:'com.example.xdmharmony',
    → startBackgroundRunning(ctx, ['dataTransfer'], wantAgentObj)   //  abilityName:'EntryAbility'}]
    → .then(res): taskNotificationId=res.notificationId; continuousTaskId=res.continuousTaskId ?? -1
    → .catch: taskApplied=false（下次事件重试）; publishOk 无涉; 0x0000 error 日志

onDownloadEnded(id, kind, finalFileSize, filePath):   // handlePaused/Failed/Finished 尾部调用
  if kind === 'finished':                            // 完成链（§3.4）
    publishFinishNotification()                      // shouldPublishFinish(Config.getShowNotification()) 门控
  if shouldReleaseTask(activeCount, taskApplied):    // activeCount<=0 && taskApplied
    taskApplied=false; taskNotificationId=-1         // 先落簿记防释放窗口内新申请被吞
    stopBackgroundRunning(ctx)
      .then: cancel(taskNotificationId 旧值).catch(忽略)   // 防御性删实况窗（系统多已代删）
             if activeCount > 0: 重新走申请路径            // ★竞态回补：归零判定与补位 dequeueOne
             else: 维持 Applied=false                      //   之间的异步窗口闭合（§0-5）
      .catch: 0x0000 error 日志（taskApplied 已复位，下次事件重试）
```

注记：①**notify 层不反向被 engine 依赖**——activeCount 经 `DownloadManager.getInstance().activeDownloadCount()` 单例读面获取（依赖方向 core/engine ← core/notify 单向，DownloadManager 零改动；§3.2 状态机内 activeCount 均指该读面）。②申请失败重试挂在"下一个 onStarted/ended 事件"上，不加定时器（失败态=9800005 类验证失败时重试同样失败，事件驱动收敛即可）。③排队场景（activeCount 含 queued）反复申请/释放的抖动由探针 S4 观测后按 §0-5 处置。

### 3.3 实况窗进度更新链（引擎 500ms 门 → publish 直发）

```
SegmentWorker 进度事件（EngineMath.shouldEmitProgress 500ms 门，HTTPDownloaderBase.cs:288 1:1）
→ PieceScheduler 聚合 → ManagedEvents.onProgress → Index.handleProgress（既有写序逐字节不动）
→ 尾部追加: ProgressNotifier.onDownloadProgress(id, fileName, progress)
  → 构造五要素 NotificationRequest（§2 表）→ publish fire-and-forget
    .then: publishOk++/publishMsMax 更新（Date.now 差值）
    .catch: publishFail++（1600004 通知未授权等——契约不受影响，任务与下载继续）
```

线程模型（决策 2 的本单元投影）：**零 TaskPool**——无 CPU 密集计算；全部调用发生在 ArkTS 主线程事件循环（引擎进度事件本就由主线程消费）；start/stop/publish 均 Promise fire-and-forget + BusinessError catch，不 await 不阻塞 handler（源 WPF 事件消费在 UI 线程=RunOnUiThread 等价物，语义同构）。

### 3.4 完成链（Application.cs:115-159 映射）

handleFinished 既有链（record 迁移+markAsFinished+progressHost.onDownloadFinished）**逐字节不动**，尾部追加 `onDownloadEnded(id,'finished',finalFileSize,filePath)`：
①完成通知（新通道 D5）：title=finishedTitle（资源键），text=fileName；发布与否=shouldPublishFinish 门控；
②释放判定：activeCount==0（=源 `CoreService.ActiveDownloadCount==0`，Application.cs:152）→ stopBackgroundRunning（补位已由 manager.dequeueOne 在 delegate 之后执行，此处读数已含补位结果，无时序差）；
③Size 回退：finishedSize(record.size, finalFileSize)——经 handleFinished 已写回 record.size，等价源 GetDownloadById 回读。

### 3.5 通知授权前置链（EntryAbility.loadTarget）

loadContent 成功回调内（文档硬约束"仅可在 loadContent 成功后调用"）：`requestEnableNotification(this.context)` + catch 记 0x0000 日志（1600004=用户已拒绝不再弹——D7；非首次调用恒成功）。冷启动/暖启动都会经过 loadTarget——重复调用无害（文档明示非首次直接返回 success）。探针 S1 用 `isNotificationEnabledSync()` 观测授权态。

---

## 4. 与源码的有意差异清单

| # | 差异 | 依据 |
|---|---|---|
| D1 | 任务书 `startContinuousTask` → 实装 `startBackgroundRunning(context, ['dataTransfer'], wantAgent)`（12+ 形态，API 24 唯一可用 string[] 形态；21+ ContinuousTaskRequest 形态不用） | API 纠偏（§0-1，文档核实） |
| D2 | 实况窗进度通知本体（SYSTEM_LIVE_VIEW/typeCode=8/downloadTemplate 五要素）——WPF 无进度系统通知，进度只在窗口 | 平台契约（§0-2） |
| D3 | 关窗拦截**条件化**：仅活跃下载>0 拦截+minimize；WPF 是无条件 `e.Cancel=true; this.Hide()` 常驻 | 拍板③（§0-3） |
| D4 | 真实退出=hamburger menu Exit→terminateSelf（WPF 托盘 Exit 1:1）；托盘本体 statusBarManager 不实装（U0.5 GO 信号，登记 U5.2+）；有活跃下载时 Dock 右键退出被一并拦截（平台无法区分关闭来源） | 拍板④/faqs-ability-151 |
| D5 | 完成通知=新通道（WPF 无系统完成通知，完成=DownloadCompleteDialog）；关窗场景对话框不可达，通知为替代通道 | §0-10 |
| D6 | ShowNotification 门控只作用于完成通知；原版语义（门媒体 balloon）归 U6.2；实况窗更新不受门控（10 分钟系统契约优先） | 拍板⑦（§0-7） |
| D7 | requestEnableNotification 授权前置为鸿蒙特有（WPF 无）；拒绝后二次申请 openNotificationSettingsWithResult 不实装 | §0-8 |
| D8 | 多下载聚合展示=最新活跃下载的文件名/进度（≤3 并发共享一条实况窗）；WPF 无对应物 | §2 |
| D9 | 通知文案自拟登记：`notify_finished_title`（"Download finished"）；原版唯一通知文案 MEDIA_DOWNLOAD_VIDEO/MSG_DWN_VID_DESC 不在本单元消费（U6.2 媒体检测时按 English.txt:12/204 对照登记） | 源码 AppTrayIcon.cs:19-45 |
| D10 | 空闲时 X 关窗=正常退出（WPF 空闲时也常驻托盘）；D3 的对偶面，为无托盘实装前保留 Dock/系统退出路径 | 拍板③ |
| D11 | publish 直发（与引擎 500ms 门同步，无二次节流）；抖动/卡顿偏差留探针 S3 实证后登记 | 拍板⑥ |
| D12 | NotifierStats 诊断计数（publishOk/publishFail/publishMsMax）为鸿蒙新增观测面（非源行为，仅探针/诊断消费） | §2 |
| D13 | onPrepareToTerminate 真机不触发的降级预案："最小化即后台继续"（长时任务保活语义不变，仅失去 X 拦截）；由 P5-U1 S5 走查实证后由 verify 判定 | §3.1 |
| D14 | MIGRATION_PLAN §7 Phase 5 的"ClipboardWatcher/DocumentViewPicker 归 U5.2"维持不变；本单元仅登记保活依赖（§0-12） | UNIT_CATALOG U5.2 行 |

---

## 5. 单元验收测试要点

- **[A] 编译门禁**：hvigor 全量构建零 error 零新 warning（ArkTS 严格子集在编译期强制；写码对照 arkts-grammar-standards 自查——本单元高危点：`wantAgent.WantAgentInfo` 对象字面量必须显式类型标注、`NotificationTemplate.data` 内字段不可用索引签名推断、`(ctx as common.UIAbilityContext)` downcast 需在 undefined 窄化之后）。
- **[A] 事件面零破坏静态核对**：`Downloader.ets`/`DownloadManager.ets`/`NewDownloadDialog.ets` 与 U4.3 版 diff 为空；`Index.ets` 五 handler 既有字段写序 diff 仅尾部追加行；EntryAbility onCreate 既有语句序零改动（仅尾部追加 init）。
- **[A] 纯逻辑单测**：`NotifyAlgo.test.ets` 12 条全绿（§7）。
- **[P] P5-U1 探针**：S1~S4 主会话（自动）+ S5 后台存活走查（单步两阶段）；真机优先（后台保活/通知真实；模拟器可验 2in1 X 拦截与 Dock 还原形态）；判定走 `xdm-probe-verify` 对照 EXPECT 表。
- **[P] 人工走查**（手册 §5 清单 8 项）：①活跃下载时点 X→窗口最小化而非退出；②通知面板可见实况窗进度且随下载刷新；③关窗 30s 后恢复窗口下载已推进（DB 进度/列表读数）；④下载全部完成→进度通知消失、完成通知出现；⑤无活跃下载时点 X→应用正常退出；⑥汉堡菜单 Exit→应用退出（有活跃下载时下载一并终止=WPF Exit 同貌）；⑦（真机附加）锁屏后下载继续；⑧设置页关掉 ShowNotification→完成通知消失但进度实况窗仍在（D6 锚）。
- **[P] 回归护栏**：既有 P1~P4 探针结论不重跑（探针一次性原则）；事件面与既有行为回归由 hvigor+单测门禁承担；Phase 7 整机回归（后台/通知面）按 MIGRATION_PLAN §8 计划复验。

---

## 6. 探针步骤设计（P5-U1 · ProbeBackgroundNotify.ets）

**会话模型**：主会话（"运行全部"，S1→S4 autoRun + S5 占位发射，8 行 = BEGIN+S1+S2+S3+S4+S5+SUMMARY+END）+ S5 单步会话（人工两阶段，各 4 行 = BEGIN+S5+SUMMARY+END）。验收锚：S1~S4 取主会话，S5 取**末次 runId**（survived 段）。前置人工：启动主机测试源（P1-U2-download-server.js 零改动复用，/slow.bin?ms=N ms 参数任意整数合法）。

| 步骤 | autoRun | 操作 | 观测点 | 日志标记（示例值；只写事实） |
|---|---|---|---|---|
| S1 | 是 | 授权+基线+监听注册：manager.init（事件袋尾部转发 ProgressNotifier，后到者接管）→ `isNotificationEnabledSync()` → `getActiveNotificationCount()` → `getAllContinuousTasks()` → `backgroundTaskManager.on('continuousTaskCancel', cb)`（cb 写模块级 LastCancel） | 授权态/通知基线/任务基线 | `[S1] notifyEnabled=true notifyBaseline=0 taskBaseline=0 taskModes=none cancelListener=on` |
| S2 | 是 | 申请锚：构造 3 条记录（id=probe-p5u1-\<runId\>-1..3，url=\<base\>/slow.bin?ms=300）→ store.add → admitNew（事件袋尾部转发已挂）→ 轮询 ≤10s 至 notifier.isTaskApplied() → getAllContinuousTasks 读详情 | 任务申请成功性/系统返回 id/modes/abilityName | `[S2] applied=true notificationId=\<系统值\> continuousTaskId=\<值\|none\> taskCount=1 mode0=dataTransfer abilityName=EntryAbility` |
| S3 | 是 | 实况窗观测：liveCount>0 期间轮询 10s——事件袋 progressEvents 计数、notifier.stats()（publishOk/publishFail/publishMsMax）、getActiveNotificationCount | 500ms 门直发实况窗的 publish 成功率/耗时/通知存在 | `[S3] progressEvents=\<n\> publishOk=\<n\> publishFail=\<n\> publishMsMax=\<ms\> notifyCount=1` |
| S4 | 是 | 完成→释放锚：轮询 ≤120s 至 activeCount==0 且 !isTaskApplied() → 记 finishedCount → getActiveNotificationCount（完成通知在、实况窗已移除）→ `cancel(finishNotifyId)` → 再读计数 → 读 LastCancel | 释放发生/通知数迁移/系统未取消 | `[S4] finishedCount=3 released=true taskCountAfter=0 finishId=1001 notifyCountWithFinish=1 notifyCountAfterCancel=0 lastCancelReason=none` |
| S5 | 否（单步×2） | **armed**：重提 1 个长下载（/slow.bin?ms=2000，≈30-60s）→ 轮询至 applied → 写模块级 armedSnapshot（id/progressAtArmed）→ emit 后**手册指引：点 X 关窗→等 15-20s→Dock/任务栏恢复窗口→回探针页**。**survived**（第二次执行）：getAllContinuousTasks + store 读该 record 进度 + 读 LastCancel | 后台存活直接观测（任务在/进度推进/未收到系统取消） | armed：`[S5] phase=armed applied=true notificationId=\<值\> progressAtArmed=0 recordId=probe-p5u1-...`<br>survived：`[S5] phase=survived taskAlive=1 progressAtArmed=0 progressNow=\<n\> advanced=true downloadFinished=false notifyCount=1 lastCancelReason=none` |

失败形态：步骤异常 catch emit `errCode/errMessage`（如 S2 的 9800005/9800006、S1 的权限缺配 201）。EXPECT 表分支映射：S2 applied=false → 分流 business-code（module.json5 backgroundModes/权限/申请链）；S3 notifyCount=0 → observe-both（通知开关关闭时 publish 无报错不显示——回读 S1 notifyEnabled 判环境）；S4 released=false → 分流 business-code（释放链/竞态回补）；S5 advanced=false → 分流 business-code（保活链）；S5 taskAlive=0 且 downloadFinished=true → 合法观测（下载在后台已跑完——关窗后下载继续的直接证据，不判 FAIL）。

---

## 7. Hypium 本地用例清单（NotifyAlgo.test.ets，12 条；被测模块零 @kit import）

| # | 用例 | 断言锚 |
|---|---|---|
| 1 | clampProgress 边界 | clampProgress(-1)=0、clampProgress(0)=0、clampProgress(100)=100、clampProgress(101)=100 |
| 2 | clampProgress 中值 | clampProgress(37.5)=37.5（浮点透传，模板端自渲染） |
| 3 | finishedSize 回退正路 | finishedSize(1048576, 1000)=1048576（recorded>0 优先，Application.cs:126） |
| 4 | finishedSize 回退负路 | finishedSize(0, 999)=999、finishedSize(-1, 999)=999（回退规则含非正数） |
| 5 | shouldApplyTask 跃迁 | shouldApplyTask(1,false)=true、shouldApplyTask(3,false)=true（0→非0 申请锚） |
| 6 | shouldApplyTask 幂等 | shouldApplyTask(2,true)=false、shouldApplyTask(0,false)=false（不空申请） |
| 7 | shouldReleaseTask 跃迁 | shouldReleaseTask(0,true)=true（归零释放锚） |
| 8 | shouldReleaseTask 守卫 | shouldReleaseTask(2,true)=false、shouldReleaseTask(0,false)=false（未申请不释放） |
| 9 | shouldPublishFinish 门控 | shouldPublishFinish(true)=true、shouldPublishFinish(false)=false（D6 锚） |
| 10 | pickFinishNotificationId 避让 | pickFinishNotificationId(7)=1001、pickFinishNotificationId(1001)=1002、pickFinishNotificationId(1002)=1001 |
| 11 | 常量值 | FINISH_NOTIFY_ID_BASE=1001、PROGRESS_MIN=0、PROGRESS_MAX=100 |
| 12 | 边界组合 | shouldApplyTask(1,true)=false && shouldReleaseTask(1,false)=false（同帧互斥——申请/释放判定不重叠） |

---

## 8. 编码注记（给 build agent 的落地提示）

1. import 面固定：`import { backgroundTaskManager } from '@kit.BackgroundTasksKit'`、`import { notificationManager } from '@kit.NotificationKit'`、`import { wantAgent, WantAgent, common } from '@kit.AbilityKit'`；WantAgentInfo 字面量显式 `wantAgent.WantAgentInfo` 类型标注（arkts-no-untyped-obj-literals）。
2. `systemLiveView.typeCode` 值 8 用字面量 number（d.ts 无枚举常量）；`SlotType.LIVE_VIEW`/`ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW`/`NOTIFICATION_CONTENT_BASIC_TEXT` 用枚举成员。
3. ProgressNotifier 所有 @kit 异步调用 fire-and-forget（.then/.catch），不 await；handler 尾部转发保持同步语义（不改变 Index 事件处理时序）。
4. onPrepareToTerminate 签名 `(): boolean`（faqs-ability-151 样例同款）；EntryAbility 的 `this.windowStage` 已有（:47），直接复用。
5. 探针 S2/S5 的 store.add 前覆盖 record.id（COLD-F1 约定）；S5 模块级 armed 快照字段命名 `armedRecordId/armedProgressAt`（跨会话进程内持久——进程不死即有效，恰好是本单元验收对象）。
