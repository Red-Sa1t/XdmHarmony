# U4.2 对话框包 · 模块设计书

> 单元：U4.2 对话框包（Phase 4）。前置：U4.1（工具栏状态机/主窗口）、U3.2（Config.setSpeedLimit/setSchedule）。
> 配套：[MIGRATION_PLAN](../../MIGRATION_PLAN.md) §6 决策 11、[UNIT_CATALOG](../../UNIT_CATALOG.md) U4.2 行、[PROBE_SPEC](../../PROBE_SPEC.md)。
> 源码锚（本会话逐一读过核实）：`XDM.Core/UI/SpeedLimiterUIController.cs`、`XDM.Core/UIActions.cs`、
> `XDM.Core/ApplicationCore.cs:160-500/629-657`、`XDM.Core/UI/{BatchDownload,DownloadSelection,DownloadComplete,LinkRefreshDialog}UIController.cs`、
> `Xdm.Wpf.UI/Dialogs/{SpeedLimiter,ProgressWindow,DeleteConfirm,CredentialDialog,CompletedDialog,BatchDownload,DownloadSelection,AdvancedDownloadOption,RefreshLink}/`、
> `Xdm.Wpf.UI/MainWindow/{MainWindow.xaml.cs,WpfPlatformUIService.cs}`、`XDM.Core/AppController.cs:482-715`、`app/XDM/Lang/English.txt`。

---

## 0. 冲突与拍板注记（必读）

1. **研究结论勘误①（StateStore 无 headers）**：研究材料称"Header 提取 referer 依赖 StateStore 存的 headers（U2.2 JSON 态）"——实际 `core/db/StateStore.ets` 只持久化分片 JSON（`buildChunksJson(pieces, totalSize)`，StateStore.ets:40-42），**不含请求头**。RefreshLink 的 referer 提取在当前存储面不可达。处置：referer 来源登记 U6.x（随 LinkRefresher 落地一并补 headers 持久化），本期对话框面先行（详见 §3.7）。
2. **研究结论勘误②（凭据产物字段）**：研究材料称"产物落 DownloadRecord 新增 authUser/authPass 字段"——实际 `DownloadRecord.authentication: AuthenticationInfo | null` 已存在并经 downloads 表 `auth/user/pass` 列持久化（DownloadRecord.ets:61、RecordMapping.ets:88-90/:110-114 R5）。**零新增字段、零表结构变更**。
3. **openQuestion 拍板①（Basic 认证传递点）**：按研究建议——Credential 对话框先行（契约+探针可达），引擎侧 Authorization 头注入与 401 挑战自动重试登记 U6.x。理由：源码 `PromptForCredential` 全仓 0 业务调用方（本会话 grep 核实：仅 ApplicationCore.cs:629 定义与 IPlatformUIService/AppController/Application 三层转发链，无调用点），原版运行时对话框本身即死链；抢先做 preemptive Basic 头与原版 challenge 语义有偏，不做。
4. **openQuestion 拍板②（Browse 选目录）**：按研究建议——DownloadSelection 的 Browse 事件面保留、点击占位（目录恒 `Config.getDownloadDir()`，对齐 NewDownloadDialog 先例），DocumentViewPicker 归 U5.2。不提前接 picker。
5. **U4.1 走查清单第 17 项语义升级**：U4.1 简版删除"运行行被停不删"，本单元按源码全链升级为"先停→确认→删记录"（UIActions.cs:19-37 逐行核对）。走查清单同步更新（§6bis），非事件面破坏（引擎事件零改动）。
6. **两个对话框的"死值"核实**（不照搬进设计）：① DownloadSelection 的 More 子窗携带的 `EnableSpeedLimit/SpeedLimit`——`DownloadSelectionUIController.AddDownload`(:99-112) 只消费 `view.Authentication/view.Proxy`，限速两值在控制器内无读取点=死值，More 子窗裁剪时不做限速段；② Batch 的 Links 死 tab（tab1 时 OK no-op，:49 `IsBatchMode` 门）——渲染不接线，源码同貌。
7. **module.json5 本单元零改动**：对话框不新增能力面（INTERNET 已在 U0.1 补齐、deviceTypes 已含 2in1，本会话读 module.json5 核实）；无后台/剪贴板/深链新能力。main_pages.json 零改动（探针子页按 U0.1 惯例不注册，走 ProbeIndex 条件渲染）。
8. **返修补录（R3-F1：三处未列入返修声明清单的工作区改动，13:20-13:21——逐一核实均为源码保真，代码零再改，本注记即补录）**：①`components/BatchDownloadDialog.ets:80-92` 预览路径 null/[] 静默清空（=源运行时行为，勘误见 §3.1/§5.8）；②`components/ProgressWindowDialog.ets:316-322` 完成窗触发门追加 `!endedNonInteractive(id)` 双门（ApplicationCore.cs:410-414 `!nonInteractive` 逐字同构）+ :31 新增 `import { DownloadManager }`；③`core/engine/DownloadManager.ets` 观测面追加 `endedNonInteractiveMap` 末态快照（:133-136）与 `endedNonInteractive(id)`（:283-285，engineEchoEnded 摘除前快照——回声后 isInteractive 恒 true 不可用）及头部/方法处注释（:20-21/:269-271）。单元报告引用 §4 全表时，预览路径行为按本注记与 §3.1/§5.8 勘误口径声明（静默清空，勿写 MSG_INVALID_URL 弹窗）。

---

## 1. 目标文件清单（按实现顺序）

> 新 13 / 改 6 / 文档 2，共 21 项（业务新 10+探针 1+单测 2；改=string.json/Config/DownloadManager/Index/ProbeIndex/List.test.ets）。业务文件禁 import `probe/**`（审查红线）；探针只 import 业务公开面。

| # | 文件 | 新/改 | 职责与对外导出 | dependsOn |
|---|---|---|---|---|
| 1 | `entry/src/main/ets/core/util/BatchAlgo.ets` | 新 | 批量下载生成纯函数：`BatchParams`/`BatchPreview` 类型、`generateBatchLinks(params): string[] \| null`（null=URL 非法，all-or-nothing）、`computeBatchPreview(urls): BatchPreview`、`padDigits(value, count): string`（C# `D` 格式，负号外置）。零 import（Hypium 直载） | — |
| 2 | `entry/src/main/ets/core/util/SpeedLimitView.ets` | 新 | 限速窗装载规范化纯函数：`SpeedLimitView` class、`speedLimitView(enable, speedKBps): SpeedLimitView`（SpeedLimiterUIController.cs:12-13 同式）。零 import | — |
| 3 | `entry/src/main/resources/base/element/string.json` | 改 | 追加 §2.5 的 ~42 键（值=English.txt 原文，键名 camelCase 沿用工程约定） | — |
| 4 | `entry/src/main/ets/core/Config.ets` | 改 | 追加 `showProgressWindow`/`showDownloadCompleteWindow` 两键（Config.cs:106/:108 默认 true）+ getter/setter；追加 ConfigChanged 监听器注册表 `onConfigChanged/offConfigChanged`（`setSpeedLimit` 写盘后逐个回调——源 BroadcastConfigChange 同位） | — |
| 5 | `entry/src/main/ets/core/engine/DownloadManager.ets` | 改 | **唯一一处引擎改动**：追加观测方法 `isInteractive(id): boolean`（LiveSlot/QueuedEntry 的 nonInteractive 投影，未知 id 恒 true）。事件面/方法签名/既有方法体逐字节不动 | — |
| 6 | `entry/src/main/ets/components/CompletedDialog.ets` | 新 | 完成窗内容组件（`@Component CompletedDialogContent` + `CompletedParams` + `@Builder completedDialogBuilder`，供 ComponentContent 动态打开）：文件名/目录文本 + Open/Open folder 占位按钮 + Don't show again（写 Config 后关窗） | #3 #4 |
| 7 | `entry/src/main/ets/components/ProgressWindowDialog.ets` | 新 | 进度窗三件套：`@Observed ProgressWindowModel`（状态机字段 §2.1）、`ProgressWindowContent`（@ObjectLink 只读渲染）+ `ProgressWindowActions`、宿主类 `ProgressWindowHost`（单例：`init(uiContext)`、`openFor(record)`、`closeFor/hideFor(id)`、`modelOf(id)`、`onPaused/onFailed(id)`、`onDownloadFinished(id, filePath)`（关进度窗+按 Config 门开完成窗）、`openSpeedLimiter()`、`windowCount()`、Config 监听刷新限速文本）。动态非模态=`uiContext.openCustomDialog(ComponentContent, {isModal:false})`（UIContext.d.ts:1208/:1265，BaseDialogOptions.isModal=promptAction.d.ts:1092，本会话核实） | #4 #6 #8 |
| 8 | `entry/src/main/ets/components/SpeedLimiterDialog.ets` | 新 | 限速窗内容组件（供 host 动态打开）：装载用 `speedLimitView(Config…)`、勾选框控输入可用（IsReadOnly 同义 `.enabled()`）、onChange 整数过滤、onBlur 空/非整数→自动取消勾选（SpeedLimiter.xaml.cs:78-89 同构）、OK→`Config.setSpeedLimit`（规范化已在 setter 内）+ 关窗（ConfigChanged 由监听器侧刷新） | #2 #3 #4 |
| 9 | `entry/src/main/ets/components/BatchDownloadDialog.ets` | 新 | 批量窗 `@CustomDialog`（非模态）：Pattern/Links 双 tab（Links 渲染静态文案不接线）、地址含 `*`、Letters(26 项双 Select)/Numbers(双 TextInput)、补零勾选+位数、三预览+数量（`computeBatchPreview`）、OK（`IsBatchMode` 门→空生成弹 BAT_SELECT_ITEMS→否则回调 `onConfirm(links)` 由 Index 关窗开选择窗） | #1 #3 |
| 10 | `entry/src/main/ets/components/DownloadSelectionDialog.ets` | 新 | 选择窗 `@CustomDialog`（非模态）+ 同文件内 More 子窗 `AdvancedOptionDialog`（模态）：`@Observed SelectionItemModel`（默认 selected=true）、全选框、save-in 只读展示+Browse 占位、Download Now/Download Later(bindMenu: 不使用队列+Queue 占位禁用)/More；校验链 §3.5；回调 `onConfirm(items, auth, proxy, startImmediately)` | #3 |
| 11 | `entry/src/main/ets/components/DeleteConfirmDialog.ets` | 新 | 删除确认 `@CustomDialog`（**模态**，源 ShowDialog 同型）：说明文本（DEL_SEL_TEXT）+ `Delete files from disk` 勾选 + Delete/Cancel；回调 `onConfirm(deleteFiles)`/`onCancel` | #3 |
| 12 | `entry/src/main/ets/components/CredentialDialog.ets` | 新 | 凭据 `@CustomDialog`（**模态**）：User Name/Password 输入、OK 空用户名→MSG_NO_USERNAME 提示不关窗、确认回调 `onConfirm(auth: AuthenticationInfo)`、取消回调。**无业务 UI 触发点（源码死链，注记 §0-3），Index 不持控制器**；探针页持控制器验收 | #3 |
| 13 | `entry/src/main/ets/components/RefreshLinkDialog.ets` | 新 | 刷新链接 `@CustomDialog`（非模态）：等待文案 + Stop 钮（关窗+`onStopped` 回调清候选占位）；`@Observed RefreshLinkModel {waiting, linkAccepted}` 驱动 LinkReceived 态（U6.x 前恒 waiting） | #3 |
| 14 | `entry/src/main/ets/pages/Index.ets` | 改 | 触发链接线（改动面 §5.14 八处）：New 下拉第 3 项启用开批量窗；工具栏 Delete 升级两分支 §3.4；引擎五事件处理器尾部追加 host 转发（**既有字段写序逐字节不动**）；行上下文菜单（Refresh link/Show progress 两项）；host.init + Config 监听注册 | #3 #4 #5 #6 #7 #8 #9 #10 #11 #13 |
| 15 | `entry/src/main/ets/probe/units/ProbeDialogs.ets` | 新 | P4-U2 探针（§6 五步）：S1 BatchAlgo 观测 / S2 限速规范化+Config 回读 / S3 进度窗生命周期（慢源实跑）/ S4 完成窗触发门+回写 / S5 人工走查清单（§6bis，26 项勾选面） | #1 #2 #4 #6 #7 #8 #11 #12 |
| 16 | `entry/src/main/ets/probe/ProbeIndex.ets` | 改 | PROBE_UNITS 追加 `{unitId:'P4-U2'}` 表项 + else-if 分支 `ProbeDialogs()`（U0.1 注册惯例） | #15 |
| 17 | `entry/src/test/BatchAlgo.test.ets` | 新 | §7 Hypium 用例 13 条 | #1 |
| 18 | `entry/src/test/SpeedLimitView.test.ets` | 新 | §7 Hypium 用例 6 条 | #2 |
| 19 | `entry/src/test/List.test.ets` | 改 | testsuite 追加两套件注册（头部注释补 U4.2 行） | #17 #18 |
| 20 | `docs/probe/PROBE-u4-2-dialog-package.md` | 新 | 探针手册：运行命令 + 人工配合步骤（含逐对话框开合/回调走查清单 26 项全文） | #15 |
| 21 | `docs/probe/EXPECT-u4-2-dialog-package.json` | 新 | verify 期望表（S1~S5 键值期望） | #20 |

> `entry/src/main/module.json5`、`main_pages.json`、`EntryAbility.ets`、`model/**`、`core/db/**`、`core/net/**`、`core/engine/{Downloader,PieceGrabber,SpeedLimiter,Scheduler}.ets` 均零改动（事件面/存储面冻结）。

---

## 2. 数据模型与表结构（对照源码逐一核对）

### 2.1 ProgressWindowModel（@Observed；对照 IProgressWindow.cs + DownloadProgressWindow.xaml.cs 状态机）

| 字段 | 类型 | 源码锚 | 说明 |
|---|---|---|---|
| `downloadId` | string | DownloadProgressWindow.xaml.cs `downloadId` | BtnPause/Stop/Hide 动作与 host 定位键 |
| `fileName` | string | `FileNameText`（ApplicationCore.cs:171/:312） | 创建时=record.name（TargetFileName） |
| `url` | string | `UrlText`（:173） | 创建时=record.primaryUrl ?? '' |
| `statusText` | string | `FileSizeText`/`TxtStatus` | 初始 `STAT_DOWNLOADING ...`；失败/取消态被覆盖（§3.3 表） |
| `speedText` | string | `DownloadSpeedText` | `formatSize(bytes/s)+"/s"` |
| `etaText` | string | `DownloadETAText` | `msg_time_left + ": " + toHMS` |
| `progressPercent` | number | `DownloadProgress`（actPrgUpdate :39-41） | 钳位 `v>=0&&v<=100?v:0` |
| `resumable` | boolean | `BtnPause.Tag != null`（:206-235） | Tag==new() 可恢复态；DownloadStarted 置 false、Failed/Cancelled 置 true |
| `speedLimitText` | string | `TxtSpeedLimit`（:177-186） | Config 装载+ConfigChanged 刷新（§3.2） |

**状态机迁移表**（源码事件→模型字段写；全部在 Index/host 主线程事件链上执行）：

| 引擎事件（ArkTS 面） | 源码对应 | 模型写入 |
|---|---|---|
| onStarted | ApplicationCore.cs:166-176 创建窗 | fileName/url/statusText=`...STAT_DOWNLOADING ...`、resumable=false（DownloadStarted :216-222 同位） |
| onProgress | DownloadProgressChanged :359-371 | progressPercent 钳位、statusText=`{STAT_DOWNLOADING} {formatSize(downloaded)} / {formatSize(size)}`、speedText、etaText |
| onPaused | DownloadCancelled :443-458（停即取消语义，源码暂停与取消共用 Cancelled 事件） | statusText=`msg_dwn_stop`、etaText=''、resumable=true |
| onFailed | DownloadFailed :421-436 | statusText=`'error ' + errorCode`（GetLocalizedErrorMessage 降级，差异 #4）、etaText=''、resumable=true |
| onFinished | DownloadFinished :393-419 | host 关窗（`DownloadId=null + DestroyWindow` 同位）→ 按 Config 门开完成窗 |
| 用户 Pause 钮（resumable=false） | BtnPause_Click else 分支 :224 | `manager.stopOne(id)`（停不下窗，等 onPaused 回声） |
| 用户 Resume 钮（resumable=true） | BtnPause_Click if 分支 :218-222 | `manager.resumeOne(record)` + resumable=false |
| 用户 Stop 钮 | BtnStop_Click :227-230 | `manager.stopOne(id)` + 关窗（StopDownload(true) 语义：stop→close 由 onFinished/onPaused 回声触发关窗，本钮直接 closeFor 兜底） |
| 用户 Hide 钮 | BtnHide_Click :233-238 | 仅关窗不停（HideProgressWindow :643-651 同位） |
| 用户限速文本点击 | TxtSpeedLimit_MouseDown :240-242 | `host.openSpeedLimiter()`（PlatformUIService.ShowSpeedLimiterWindow 同位） |

### 2.2 SelectionItemModel（@Observed；对照 DownloadSelectionWindow.xaml.cs:185-200 wrapper）

```
class SelectionItemModel { name: string; url: string; entryType: string; selected: boolean = true }
```
- `selected` **默认 true**（xaml.cs:189 `private bool selected = true`——全选框初始未勾但条目已全选，源码同貌保留）。
- `entryType` 恒 `'Http'`（PopulateEntryWrapper :69-97 四型映射；本期数据源只有 Batch 生成的 SingleSource HTTP 链接，Dash/Hls/MpegDash 分支 U6.x）。
- 名称 fallback：Batch 侧已生成文件名（BatchAlgo 从 URL 提取），走 `shi.File ?? FileHelper.GetFileName(new Uri(shi.Uri))` 的前半支。

### 2.3 BatchParams / BatchPreview（对照 IBatchDownloadView + BatchDownloadUIController）

```
class BatchParams {
  url: string = '';            // 含 '*'
  isLetterMode: boolean = true; // ctor 初始 true（UIController.cs:26）
  startLetter: string = '';     // 'A'..'Z'，空=未选（HasValue=false 同构）
  endLetter: string = '';
  startNumber: number = 0;      // ParseIntSafe 失败=0（ParsingHelper.cs:47）
  endNumber: number = 0;
  useLeadingZero: boolean = false;
  leadingZeroCount: number = 0;
}
class BatchPreview { first: string; second: string; last: string; size: number }
```
持久化面：**零新列**——批量产物经 DownloadSelection → `newDownloadRecord(...)` → downloads 表既有 22 列。

### 2.4 Config 新增键（Config.ets 改动面）

| 键 | 类型 | 默认 | 源码锚 | 消费方 |
|---|---|---|---|---|
| `showProgressWindow` | boolean | true | Config.cs:106 | Index.onStarted → host.openFor 门 |
| `showDownloadCompleteWindow` | boolean | true | Config.cs:108 | host.onDownloadFinished 门；完成窗 DontShowAgain 写 false |
| ConfigChanged 监听器 | `(() => void)[]` | — | SpeedLimiterUIController.cs:32 `BroadcastConfigChange` | host 刷新全部开窗的 speedLimitText |

非目标：`userSelectedDownloadFolder`（Browse 占位，U5.2 连 picker 时一并落）；44 键全表仍归 U4.3。

### 2.5 string.json 追加键（值=English.txt 原文，本会话逐键 grep 行号核实）

既有键复用：`menu_pause/menu_resume/desc_del/nd_cancel/nd_download_now/nd_address/lbl_save_in/ctx_open_file/ctx_open_folder/desc_q_title/menu_batch_download/desc_new/msg_invalid_url/msg_no_file/nd_title/nd_file`。

| 键（camelCase） | 值（English.txt 原文） | 源键 | 行 |
|---|---|---|---|
| btn_stop_processing | Stop | BTN_STOP_PROCESSING | 174 |
| dwn_hide | Hide | DWN_HIDE | 175 |
| msg_dwn_stop | Download stopped | MSG_DWN_STOP | 172 |
| stat_assembling | Assembling | STAT_ASSEMBLING | 201 |
| msg_time_left | Time left | MSG_TIME_LEFT | 176 |
| lbl_show_progress | Show progress | LBL_SHOW_PROGRESS | 35 |
| speed_limit_title | Speed limit | SPEED_LIMIT_TITLE | 63 |
| msg_no_speed_limit | No speed limit | MSG_NO_SPEED_LIMIT | 173 |
| menu_speed_limiter | Speed limiter | MENU_SPEED_LIMITER | 75 |
| msg_speed_limit | Download speed limit [KB/Sec ](0 unlimited) | MSG_SPEED_LIMIT | 76 |
| bat_select_items | Select items to download | BAT_SELECT_ITEMS | 88 |
| vid_chk | Select all | VID_CHK | 84 |
| nd_more | More... | ND_MORE | 54 |
| nd_download_later | Download Later | ND_DOWNLOAD_LATER | 55 |
| lbl_queue_opt3 | Do not use queue | LBL_QUEUE_OPT3 | 82 |
| msg_cat_folder_missing | Download folder required | MSG_CAT_FOLDER_MISSING | 196 |
| bat_pattern | Pattern | BAT_PATTERN | 86 |
| bat_links | Links | BAT_LINKS | 87 |
| bat_paste_link | Please paste download links below | BAT_PASTE_LINK | 89 |
| bat_leading_zero | Use leading zero | BAT_LEADING_ZERO | 100 |
| lbl_batch_desc | Download a group of sequential files using asterisk wild card (example http://xdman.sourceforge.net/images/edge*.png) | LBL_BATCH_DESC | 90 |
| lbl_batch_asterisk | Replace asterisk with | LBL_BATCH_ASTERISK | 91 |
| lbl_batch_letter | Letters | LBL_BATCH_LETTER | 92 |
| lbl_batch_num | Numbers | LBL_BATCH_NUM | 93 |
| lbl_batch_from | From | LBL_BATCH_FROM | 94 |
| lbl_batch_to | To | LBL_BATCH_TO | 95 |
| lbl_batch_file1 | First file | LBL_BATCH_FILE1 | 97 |
| lbl_batch_file2 | Second file | LBL_BATCH_FILE2 | 98 |
| lbl_batch_filen | Last file | LBL_BATCH_FILEN | 99 |
| msg_ok | OK | MSG_OK | 45 |
| menu_refresh_link | Refresh link | MENU_REFRESH_LINK | 34 |
| ref_waiting_for_link | Waiting for download link... | REF_WAITING_FOR_LINK | 178 |
| msg_ref_link_msg | New download link is accepted | MSG_REF_LINK_MSG | 192 |
| no_refresh_link | Link refresh is not available for this download | NO_REFRESH_LINK | 211 |
| nd_auth | Authentication | ND_AUTH | 61 |
| desc_user | User Name | DESC_USER | 64 |
| desc_pass | Password | DESC_PASS | 65 |
| msg_no_username | User name required | MSG_NO_USERNAME | 191 |
| menu_delete_dwn | Delete downloads | MENU_DELETE_DWN | 17 |
| del_sel_text | Are you sure you want to delete selected downloads? | DEL_SEL_TEXT | 165 |
| lbl_delete_file | Delete files from disk | LBL_DELETE_FILE | 164 |
| cd_title | Download Complete | CD_TITLE | 177 |
| msg_dont_show_again | Don't show this again | MSG_DONT_SHOW_AGAIN | 190 |
| desc_adv_title | Advanced settings | DESC_ADV_TITLE | 60 |
| desc_net4 | Proxy settings | DESC_NET4 | 62 |
| nd_no_proxy | No Proxy | ND_NO_PROXY | 68 |
| nd_manual_proxy | Manual Proxy | ND_MANUAL_PROXY | 69 |
| proxy_host | Proxy Host | PROXY_HOST | 70 |
| proxy_port | Proxy Port | PROXY_PORT | 71 |

> `stat_assembling` 本期 UI 无消费点（差异 #3），键先落（与 U4.1 D11 键骨架同理由）。zh_CN/en_US 值按 U4.3 节奏补。JSON 纯文本禁尾逗号。

---

## 3. 关键算法翻译说明

### 3.1 批量下载生成算法（BatchDownloadUIController.cs:105-159 逐行 → BatchAlgo.ets 纯函数）

```
generateBatchLinks(params): string[] | null
  if (!params.url.includes('*')) return []                       // :107 无 '*' → 空
  try {
    if (params.isLetterMode) {
      if (startLetter==='' || endLetter==='') return null_or_empty  // :124 ArgumentException → 外层 catch → 空（实现取 []，见下）
      if (startChar >= endChar) return []                        // :128-132
      for (c = startChar; c <= endChar; c++) push(url.replace('*', c))
    } else {
      if (startNumber >= endNumber) return []                    // :144-148
      for (i = startNumber; i <= endNumber; i++)
        push(url.replace('*', useLeadingZero ? padDigits(i, count) : String(i)))  // :152-154
    }
  } catch-equivalent → return null                               // URL 非法（new Uri 抛 UriFormatException 同位）
```
- **null 与 [] 语义分离**（源码两 catch 的分流）：预览路径（OnBatchPatternChange :68-103）`UriFormatException` → MSG_INVALID_URL 弹窗（→null）；OK 路径（OnOKClicked :47-66）任何失败 → 空 → BAT_SELECT_ITEMS 弹窗（→null/[] 都按空处理）。ArkTS 侧 URL 合法性用 `isUriValid`（core/net/HttpProtocol.ets，NewDownloadDialog 先例）在生成循环内逐条判定，任一非法→整体 null（all-or-nothing，与 `new Uri` 单条抛出中止全批同构）。
- **勘误（R3-F1，返修期核实 BatchDownloadUIController.cs:105-117）**：上句"预览路径 → MSG_INVALID_URL 弹窗"系静态读码误判——公共 `GenerateBatchLink`（:108-116）catch **全部**异常返回 Empty，`OnBatchPatternChange` 的 `catch(UriFormatException)`（:95-98）**不可达**：源运行时预览对非法候选从不弹窗，外在行为即**静默清空**。BatchDownloadDialog.recomputePreview 的 null/[] 统一静默清空=源运行时行为 1:1（非裁剪差异）；null 语义仍保留两处消费：BatchAlgo 纯函数返回值（单测 all-or-nothing 锁定）与 OK 路径 BAT_SELECT_ITEMS（OnOKClicked :47-66 行为不变）。
- **padDigits(value, count)**：C# `i.ToString("D{n}")`——最少 n 位十进制、不足补零、**负号不占位**（`(-5).ToString("D3")` = `"-005"`；JS `String(-5).padStart(3,'0')` 会产出 `"0-5"`，必须 `(i<0?'-':'') + String(Math.abs(i)).padStart(count,'0')`）。字母模式 start/end 为单字符 `charCodeAt` 比较（:128 `startChar >= endChar`）。
- **computeBatchPreview**（OnBatchPatternChange :72-93 逐行）：清空 → 遍历：c==0 → first；c==1 → second；last 恒更新；size=c 计数 → c>1 才回填 last。纯函数收 `string[]` 出 `BatchPreview`。
- **线程模型**：纯同步主线程计算（源码同 UI 线程）；预览触发点=地址 onChange/模式切换/字母选择/补零勾选/数字框 onBlur（源 PatternChanged 五触发点），无防抖（源码即时重算，量级 ≤ 数千条字符串替换，主线程毫秒级）。

### 3.2 限速窗读写规范化（SpeedLimiterUIController.cs:9-33 + SpeedLimiter.xaml.cs 控件行为）

- **装载**（Run :12-16）：`speedLimitView(Config.getEnableSpeedLimit(), Config.getDefaultDownloadSpeed())`——`enabled = enable ? speed>0 : false`（禁用时 speed 原值回填输入框）。`SpeedLimitView` 纯函数，进度窗限速文本同用（`enable && limit>0 ? 'speed_limit_title - {limit}K/S' : msg_no_speed_limit`，DownloadProgressWindow.xaml.cs:177-186）。
- **保存**（OkClicked :19-33）：一次性语义（源码退订防重复）→ ArkTS 侧 OK 后立即 `controller.close()` 即等价；`Config.setSpeedLimit(enabled, speed)` 组合 setter **已按同式实现**（Config.ets:231-236，U3.2），本单元纯消费+写盘后逐个触发 ConfigChanged 监听器（源 `BroadcastConfigChange` :32 同位）。
- **控件行为**：ctor 默认文本 "0"（SpeedLimiter.xaml.cs:17）；整数过滤=onChange 剥除非数字字符（源 PreviewTextInput/Pasting 按键拦截，差异 #16）；勾选框控输入可用 `.enabled(checked)`（源 IsReadOnly=!checked :57-60）；onBlur 空/非整数 → 自动取消勾选（LostFocus :66-77 逐条：empty→invalid、TryParse 失败→invalid、`ChkEnabled.IsChecked = valid`）。Cancel 仅关窗不写（BtnCancel_Click :39-42）。
- **线程模型**：全主线程；ConfigChanged 监听器数组在主线程事件循环内同步回调（源 Dispatcher.BeginInvoke 的 UI 线程投递在 ArkTS 主线程模型下天然成立，§3.6 复用）。

### 3.3 进度窗状态机与宿主（§2.1 表为契约；此处只写宿主映射）

- **动态多窗**：源码 `activeProgressWindows[download.Id]` 字典一下载一窗（ApplicationCore.cs:169/:312）。ArkTS 侧 CustomDialogController 必须组件成员内联初始化、无法按 id 动态建 → 用 `UIContext.openCustomDialog(ComponentContent, {isModal:false})`（UIContext.d.ts:1208 签名本会话核实；isModal:false=非模态无遮罩可交互，API 12+，本工程 API 24）。host 内 `Map<string, {model, content}>` 单点管理，`closeCustomDialog(content)` 关窗。
- **刷新机制**：Index 五事件处理器在**既有字段写序之后**追加 `host.modelOf(id)` 字段写（@Observed+@ObjectLink 驱动重渲染）；事件面零改动（改动仅"追加转发行"）。源码 `Dispatcher.BeginInvoke` UI 线程投递 → ArkTS 引擎事件本就主线程回调（U3.1 线程模型），直写即可。
- **创建时机非对称**（源码 1:1）：Start 路径只看 `Config.getShowProgressWindow()`（ApplicationCore.cs:166-169 无 nonInteractive 条件）；Resume 路径要求 `showProgressWindow && !nonInteractive`（:306-308）→ Index.onStarted 追加 `manager.isInteractive(id)` 判定（新观测面 #5 文件）；Resume 路径的窗若已存在则复用（GetProgressWindow :309 同构，host.openFor 对已有 model 幂等 no-op）。
- **关窗即停 vs 隐藏不停**：源 Window_Closing → StopDownload(true)。CustomDialog 无系统 X：`autoCancel:false`（外部点击/返回不触发 dismiss，防"误触关窗即停"）；关闭路径仅 Hide（closeFor，不停）/Stop（stopOne+closeFor）。onPaused/onFinished 回声到达时若窗仍在则由 host 统一收口（StopDownload close=true 的 DestroyWindow 回调 :369-374 同位）。

### 3.4 删除两分支（UIActions.cs:19-55 逐行 → Index.handleToolbarDelete 升级）

```
if (activeCategoryIndex === 0) {                          // inProgressOnly 分支 :21-38
  ids.forEach(id => manager.stopOne(id))                  // :24 StopDownloads 先于确认弹窗
  showAlertDialog(del_sel_text) → approved:
    ids.forEach(id => { store.remove(id); 两 DS.removeById(id); 选中清理 })   // :27-36 RemoveDownload+行删除+DB
} else {                                                  // 完成分支 :40-54
  打开 DeleteConfirmDialog(del_sel_text)                   // :42 ConfirmDelete（模态）
  onConfirm(deleteFiles): ids.forEach(id => { store.remove(id); DS.removeById; deleteFiles→hilog 登记 U5.2 })
}
```
- **时序红线**：进行中分支 stopOne **先于**确认框（源码 :24 在 :25 之前——用户点 Cancel 行也已被停，记录保留可恢复）； ArkTS 侧 stopOne 是同步调用，alert 是异步 UI，天然保持此时序。
- 与 U4.1 简版差异：运行/排队行确认后**也删记录**（U4.1 只停不删）；排队行 stopOne 的 DB 回声（hooks.onQueuedCancelled → updateStatus）照旧，随后 store.remove 覆盖之（幂等）。
- `deleteFiles` 本期不删盘上文件（U5.2 openFile/openFolder/文件删除能力面），hilog 登记（差异 #7）。

### 3.5 选择窗校验链与 Download Later（DownloadSelectionUIController.cs:114-135 + ApplicationCore SaveForLater）

- 初始 `saveIn = Config.getDownloadDir()`（:28-33；FolderSelectionMode.Manual 分支降级省略——§3 系统目录概念无对应物，NewDownloadDialog 同先例）。
- OK 校验链顺序 1:1：saveIn 空 → `msg_cat_folder_missing`（:116-120）；选中数 0 → `bat_select_items`（:121-125）；通过后逐选中项回调 → Index 侧：
  - **Download Now**（startImmediately=true, queueId=null）：`newDownloadRecord(name, dir, 0, null, url, startImmediately=true, auth, proxy)` → store.add → DS.addSorted → `manager.admitNew`（StartDownload :126-186 同序，U1.2 startNewDownload 链复用，追加 auth/proxy 实参）。
  - **Download Later**（不使用队列项，queueId=null，startImmediately=false）：`newDownloadRecord(..., startImmediately=false, ...)` → Stopped 态 → store.add → DS.addSorted → **不 admitNew**（源 `else { download.SaveForLater(); }` :198-200 同位；源 startType 语义勘误——ApplicationCore.cs:138-148 缺省 Waiting 仅对 Now/排队生效，`!startImmediately` 才 Stopped；初版设计把 Now/Later 初始状态写反，独立复核 medium 已修）。
  - 命名队列项：QueueManager 队列清单本期为空（无队列创建 UI），bindMenu 动态构建 = 零队列项 + 两固定项（DownloadLaterMenuHelper.cs:24-41 先队列后两固定项的次序保留）；`lbl_queue_opt3` → 上述 Download Later；`desc_q_title`（Queue and scheduler）→ 占位禁用（队列窗不在本单元八对话框，差异 #10）。
- **More 子窗**（AdvancedDownloadOptionDialog，模态，同文件内第二个 struct）：裁剪面=认证（User Name/Password）+ 代理（`nd_no_proxy`→ProxyType.Direct / `nd_manual_proxy`→ProxyType.Custom+host/port/user/pass；System 选项按 MIGRATION_PLAN §3-2 降级隐藏）；`Authentication` 空用户名→null（源 xaml.cs :32-54 空判同构）；确认后回填选择窗会话值，随 Download Now 传入工厂（`record.authentication`/`record.proxy`）。限速段不做（注记 §0-6 死值）。ProxyType 数值锚 DownloadTypes.ets:26-30（System=0/Direct=1/Custom=2）。

### 3.6 完成窗触发（ApplicationCore.cs:393-419 DownloadFinished + DownloadCompleteUIController.cs:8-33）

```
host.onDownloadFinished(id, filePath):      // Index.handleFinished 尾部追加调用（字段写序不动）
  closeFor(id)                              // :412-417 DownloadId=null + DestroyWindow（先关进度窗）
  if (Config.getShowDownloadCompleteWindow())  // :415 门（U4.2 键落地；nonInteractive 判定已由
    openCompleted(baseName, dirName)           //   onStarted 的 isInteractive 门承担，源 :414 同构）
```
- 完成窗内容=文件名/目录两文本 + Open/Open folder 按钮（占位 hilog，D6 模式，U5.2 接线）+ `msg_dont_show_again` 文本点击 → `Config.setShowDownloadCompleteWindow(false)` + 关窗（DownloadCompleteUIController.cs:26-29；两 Open 按钮与 dontshowagain 点击均 Close，:53-59/:82-89）。
- 非模态 Show()（xaml.cs:62-65）→ `openCustomDialog({isModal:false})`。

### 3.7 刷新链接：本期边界与 U6.x 登记（LinkRefreshDialogUIController.cs:17-81）

- **触发**（UIActions.cs:173-178）：行上下文菜单 `menu_refresh_link` → 取选中进行中首行 → `record.downloadType !== 'Http'` → `showAlertDialog(no_refresh_link)` 不开窗（:21-23 return false → ShowRefreshLinkDialog 弹 NO_REFRESH_LINK，WpfPlatformUIService.cs:106-114）；Http → 开窗。
- **本期落地面**：对话框（等待文案+Stop）、Stop→关窗+`onStopped` 回调（源 WatchingStopped → ClearWatchList :43-46 的占位：hilog+空实现）、`record.refererUrl` 非 null 时 `openLink(refererUrl)`（源 OpenBrowser(referer) :75-77；当前无写入点恒 null，路径休眠）。
- **U6.x 登记表**（写进本节，不写代码）：① LinkRefresher 匹配数学（单源 `FileSize==ContentLength && FileSize>0` :55/:62；双源 `ContentLength>0 && FileSize 相等` :92-93）；② 下载状态 headers 持久化（StateStore chunks.json 追加 headers 段或独立 state 文件——勘误①）；③ referer 提取（键大小写不敏感取首值 :82-88）+ 恢复 downloader AddToWatchList；④ 桥接入口（LinkAccepted 语义随 BridgeServer /link 路由）。Dash 双源分支同登记。

### 3.8 模态分型与对话框宿主总表（Wpf Show()/ShowDialog() → ArkUI）

| 对话框 | 源打开方式（核实锚） | ArkUI 形态 | 宿主 |
|---|---|---|---|
| ProgressWindow | Show()（Dispatcher.BeginInvoke Show :193-196） | openCustomDialog isModal:false | ProgressWindowHost（动态多实例） |
| CompletedDialog | Show()（DownloadCompleteWindow.xaml.cs:62-65） | 同上 isModal:false | ProgressWindowHost |
| SpeedLimiter | ShowWindow→this.Show()（SpeedLimiterWindow.xaml.cs:69-72） | 同上 isModal:false | ProgressWindowHost（入口=进度窗限速文本，全仓唯一触发点 :240-242，MainWindow 无菜单项——grep 核实） |
| DownloadSelection | Show()（UIController Run :54-57） | @CustomDialog isModal:false | Index（单实例） |
| BatchDownload | Show()（Run :42-45） | @CustomDialog isModal:false | Index（单实例） |
| RefreshLink | ShowWindow()（:79 dialog.ShowWindow） | @CustomDialog isModal:false | Index（单实例） |
| DeleteConfirm | ShowDialog()（MainWindow.xaml.cs:316-327） | @CustomDialog 默认 isModal:true | Index（单实例） |
| Credential | ShowDialog()（WpfPlatformUIService.PromtForCredentials :126-137） | @CustomDialog 默认 isModal:true | 探针页（业务无触发点） |

> 索引非模态六窗：主窗在弹窗期间可继续操作（源码分型 1:1；isModal=false 的 API 可用性已按 devecocli 文档+SDK d.ts 双核实）。

---

## 4. 有意差异清单（对照源码/计划，含已定降级项）

| # | 差异 | 理由 |
|---|---|---|
| 1 | 进度窗用 openCustomDialog(ComponentContent) 复刻"一下载一窗"多实例；CustomDialog 不复刻系统标题栏 → `Title={p}% {name}` 由进度条+百分比文本承载 | ArkUI 控件模型差异（CustomDialogController 无法动态建）；信息不丢失 |
| 2 | 进度窗 autoCancel:false：外部点击/返回键不关窗 | 源 Window 无遮罩点击语义；防"外部点击→关窗→StopDownload(true) 误停"放大面 |
| 3 | STAT_ASSEMBLING 装配态不呈现（键保留） | Downloader 事件面无 assembling 事件（事件面冻结红线）；拼接期在 onFinished 前毫秒~秒级 |
| 4 | 失败态 statusText=`'error '+errCode`；GetLocalizedErrorMessage 本地化表随 U4.3 i18n 落 | 错误码→文案映射不在 English.txt（独立 ErrorMessages.cs），本单元键骨架只收 English.txt 键 |
| 5 | 进行中删除分支由 U4.1 简版"停不删"升级为源码全链"先停→确认→删记录"；U4.1 清单第 17 项语义更新 | UIActions.cs:19-37 源码事实（注记 §0-5），属 U4.2 计划内接链 |
| 6 | 删除确认的 deleteFiles 勾选只收值不删盘上文件（hilog 登记） | 文件删除能力面 U5.2（openFile/openFolder 同批） |
| 7 | Batch Links 死 tab 渲染静态文案不接线（tab1 OK no-op） | 源码 :49 IsBatchMode 门=死 UI，源码同貌 |
| 8 | 选择窗 Browse 点击占位（目录恒 Config.getDownloadDir()） | DocumentViewPicker 归 U5.2（拍板 §0-4） |
| 9 | Download Later 队列菜单无命名队列项（清单恒空）；Queue and scheduler 项占位禁用 | QueueManager 无 UI 创建面；队列窗不在本单元范围 |
| 10 | More 子窗裁剪：System Proxy 选项隐藏（§3-2 降级）；限速段不做 | 源控制器不消费 view.EnableSpeedLimit/SpeedLimit（死值，注记 §0-6） |
| 11 | Credential 对话框无业务触发点，探针可达；Basic 头注入+401 挑战重试登记 U6.x | 源码死链（0 调用方，注记 §0-3） |
| 12 | 凭据产物写既有 `record.authentication`（不新增 authUser/authPass） | 研究结论勘误②（注记 §0-2） |
| 13 | RefreshLink referer 提取不可达（StateStore 无 headers）；浏览器打开仅 refererUrl 非空时尝试；LinkRefresher 匹配/桥接登记 U6.x | 勘误①（注记 §0-1）；对话框面+生命周期先行 |
| 14 | DontShowAgain 持久化（源码仅内存态无 SaveConfig） | MIGRATION_PLAN 决策 10 配置=prefs 的自然推论；U4.3 全键扫描并入 |
| 15 | SpeedLimiter 整数过滤由按键拦截改为 onChange 字符重写；IsReadOnly 改 .enabled() | ArkUI 无 PreviewTextInput 等价；约束等价（仅整数） |
| 16 | 进度窗创建时机经 manager.isInteractive(id) 判定（Start 路径恒 interactive、Resume 路径看 nonInteractive——源码非对称 1:1） | nonInteractive 传播链 U3.2 已建，缺 UI 侧观测面 |
| 17 | 行上下文菜单只设 Refresh link/Show progress 两项（源进行中菜单 10 项） | 其余项动作（SaveAs/Restart/MoveToQueue/Properties 等）不在本单元；事件面追加非破坏 |
| 18 | yt-dlp 粘贴链接、系统代理自动检测、NTLM、关机动作、杀毒扫描等降级项不在任何对话框出现 | MIGRATION_PLAN §3 已定降级清单 |
| 19 | 状态栏 Queue/Help 触点维持 U4.1 占位禁用 | 同 #9；不在本单元 |
| 20 | U4.1 复核遗留 low（分类面板配色/搜索分类 0 行为/注释漂移）本单元**不**顺手修 | 保持改动面收敛，遗留项归 U4.3 复核批次 |

---

## 5. 各文件实现要点（可直接照做的接口面）

### 5.1 core/util/BatchAlgo.ets（新，零 import）
```typescript
export class BatchParams { url: string; isLetterMode: boolean; startLetter: string; endLetter: string;
  startNumber: number; endNumber: number; useLeadingZero: boolean; leadingZeroCount: number }  // 全字段显式默认
export class BatchPreview { first: string = ''; second: string = ''; last: string = ''; size: number = 0 }
export function padDigits(value: number, count: number): string   // 负号外置（§3.1）
export function generateBatchLinks(params: BatchParams, isUriValid: (url: string) => boolean): string[] | null
export function computeBatchPreview(urls: string[]): BatchPreview
```
- `isUriValid` 作入参注入（模块保持零 @kit/零业务依赖，HttpProtocol.ets 的 `isUriValid` 由调用方传入）；字母比较用 `charCodeAt(0)`；`String.replace('*', x)` 只换第一个 `*`（C# string.Replace 换全部——**差异点**：C# `url.Replace('*', i)` 替换全部出现，ArkTS 须用 `split('*').join(x)` 全量替换，单测覆盖两星号用例）。

### 5.2 core/util/SpeedLimitView.ets（新，零 import）
```typescript
export class SpeedLimitView { enabled: boolean = false; speedKBps: number = 0 }
export function speedLimitView(enableConfig: boolean, speedConfig: number): SpeedLimitView
  // return enabled = enableConfig ? speedConfig > 0 : false; speedKBps = speedConfig（禁用也回填，源 :13 原值）
```

### 5.3 core/Config.ets（改，三处）
1. `const KEY_SHOW_PROGRESS_WINDOW = 'showProgressWindow'` / `KEY_SHOW_DOWNLOAD_COMPLETE_WINDOW = 'showDownloadCompleteWindow'`；默认 true（Config.cs:106/:108）；init 内 readBoolean 装载、getter/setter（setter 同既有 writeBoolean 模式）。
2. `private configListeners: Array<() => void> = []`；`onConfigChanged(listener: () => void): void` / `offConfigChanged(listener: () => void): void`。
3. `setSpeedLimit` 末尾（writeNumber 之后）同步逐个调用监听器（try/catch 吞单监听器异常，参照 flushQuietly 风格）；其余 setter 不触发（源码仅限速窗广播）。

### 5.4 core/engine/DownloadManager.ets（改，一处）
```typescript
/** live/queued 槽的 nonInteractive 投影（ApplicationCore.cs:306-308 Resume 路径窗判定原料）；
 * 未命中 id（含未 init/已结束）恒 true——Start 路径源码即无 nonInteractive 门。 */
isInteractive(id: string): boolean
```
实现：liveMap.get→`!slot.nonInteractive`；queueMap.get→`!entry.nonInteractive`；否则 true。既有成员零改动。

### 5.5 components/CompletedDialog.ets（新）
```typescript
export class CompletedParams { fileName: string = ''; folder: string = ''; actions: CompletedActions = new CompletedActions() }
export class CompletedActions { onOpenFile: () => void = () => {}; onOpenFolder: () => void = () => {};
  onDontShowAgain: () => void = () => {} }   // host 侧装配：占位 hilog / Config 写 false + close
@Builder export function completedDialogBuilder(params: CompletedParams)
@Component export struct CompletedDialogContent   // 普通成员引用 params（静态内容，无需 @ObjectLink）
```

### 5.6 components/ProgressWindowDialog.ets（新）
```typescript
@Observed export class ProgressWindowModel { /* §2.1 九字段，全显式默认 */ }
export class ProgressWindowActions { onPauseResume: () => void = () => {}; onStop: () => void = () => {};
  onHide: () => void = () => {}; onOpenSpeedLimiter: () => void = () => {} }
@Builder export function progressWindowBuilder(p: ProgressWindowContentParams)  // {model, actions} 解包传成员
@Component export struct ProgressWindowContent { @ObjectLink model: ProgressWindowModel; actions: ProgressWindowActions = ... }
export class ProgressWindowHost {   // 单例 getInstance()
  init(uiContext: UIContext, actionsFactory: (id: string) => ProgressWindowActions): void
  openFor(record: DownloadRecord): void            // 已有 model 幂等 no-op（GetProgressWindow 同构）
  closeFor(id: string): void                       // Stop/结束路径
  hideFor(id: string): void                        // Hide 路径（同 closeFor 实现，双名对齐源码 HideProgressWindow）
  modelOf(id: string): ProgressWindowModel | undefined
  onDownloadFinished(id: string, filePath: string): void   // closeFor + Config 门 + openCompleted
  openSpeedLimiter(): void                         // SpeedLimiterDialog 内容 ComponentContent
  windowCount(): number                            // 探针观测
}
```
- Content 渲染：文件名/URL 两行 Text + Progress(value=model.progressPercent) + statusText/speedText/etaText + 限速文本（可点击）+ 三按钮行（Hide/Stop/Pause-Resume，label 按 resumable 切 `menu_pause`/`menu_resume`）。
- **@ObjectLink 纪律**：Content 组件对 model 只读；字段唯一写者=Index 事件链/host。

### 5.7 components/SpeedLimiterDialog.ets（新）
- 内容组件（供 host openSpeedLimiter 打开）：`@State enabled: boolean`/`@State speedText: string`；aboutToAppear 装载 `speedLimitView(Config…)`；TextInput `.enabled(this.enabled)` + onChange 过滤非 `0-9`；onBlur 校验（空/非整数→`this.enabled=false`）；OK → `Config.setSpeedLimit(this.enabled, parseInt-or-0)` + 关窗；Cancel 关窗。标题 `msg_speed_limit`（源 MsgText 同键）。

### 5.8 components/BatchDownloadDialog.ets（新）
- `@CustomDialog struct BatchDownloadDialog { controller; onConfirm: (links: string[]) => void; ... }`；`@State` 表单字段镜像 BatchParams + `@State preview: BatchPreview`。
- Tabs 两页（`bat_pattern`/`bat_links`）；Pattern 页=地址输入（含 `lbl_batch_desc` 提示）+ 模式选择（Letters/Numbers 两 Radio 或 Select）+ Letters：双 Select（`'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split('')` 26 项）+ Numbers：双 TextInput（ParseIntSafe 等价：parseFloat 失败归 0）+ 补零 Checkbox+位数输入。
- 重算触发=§3.1 五触发点；`generateBatchLinks(params, isUriValid)` null/[] → 预览**静默清空**（勘误 R3-F1：源公共 GenerateBatchLink BatchDownloadUIController.cs:105-117 catch-all 使 OnBatchPatternChange :95-98 弹 `msg_invalid_url` 分支不可达——静默清空=源运行时行为，详见 §3.1 勘误；本节原"null → showAlertDialog(msg_invalid_url)"表述作废）；非空 → computeBatchPreview 回填。
- OK：非 Pattern tab 直接 return（死 tab）；links 空/null → showAlertDialog(`bat_select_items`)；否则 `onConfirm(links)` + `controller.close()`（Index 在回调里开选择窗，顺序=源 DestroyWindow→ShowDownloadSelectionWindow）。

### 5.9 components/DownloadSelectionDialog.ets（新，含 AdvancedOptionDialog）
- 会话对象 `class SelectionSession { links: SelectionItemModel[] = []; auth: AuthenticationInfo | null = null; proxy: ProxyInfo | null = null; saveIn: string = '' }`（CustomDialogController builder 构造期绑定——每次 open 前 Index 改写 session 字段，禁重建 controller，keyConstraint #2）。
- 列表 ForEach(SelectionItemModel)：Checkbox+名称+类型；全选框 onChange 批量写 `selected`（@Observed 驱动）；首屏全选框**不勾**、条目恒 selected=true（源码同貌）。
- 按钮行：`nd_download_now`（validate→onConfirm(startImmediately=true)）、`nd_download_later`（bindMenu 动态构建：零队列项+`lbl_queue_opt3`+`desc_q_title` 占位禁用）、Browse（占位 hilog）、`nd_more`（开 AdvancedOptionDialog）、`nd_cancel`。
- validate（§3.5 顺序）：saveIn 空 → alert；selectedCount 0 → alert；通过 → onConfirm + close。
- `AdvancedOptionDialog`（@CustomDialog 模态）：认证两输入 + 代理 Radio（`nd_no_proxy`→Direct / `nd_manual_proxy`→Custom，host/port/user/pass 四输入）；确认回调 `onConfirm(auth, proxy)` 回填 session（空用户名→auth=null）。

### 5.10 components/DeleteConfirmDialog.ets / CredentialDialog.ets / RefreshLinkDialog.ets（新，均小件）
- DeleteConfirm：`@State deleteFiles: boolean` + Checkbox（`lbl_delete_file`）+ 文本（外部传 `del_sel_text`）+ Delete/Cancel → `onConfirm(deleteFiles)`。
- Credential：`@State user/password`；OK：user 空 → showAlertDialog(`msg_no_username`) 不关窗；否则 `onConfirm({userName, password})` + close。**Index 不持此控制器**。
- RefreshLink：成员 `model: RefreshLinkModel`（外部传入共享实例，@ObjectLink 渲染）；`ref_waiting_for_link` 文案；linkAccepted=true 时切 `msg_ref_link_msg`+自动关（U6.x 前 dormat）；Stop → `onStopped()` + close。

### 5.11 pages/Index.ets（改，改动面八处）
1. import 追加九个 components + BatchAlgo 类型 + host。
2. 成员：`progressHost: ProgressWindowHost`（aboutToAppear 内 `init(getUIContext(), actionsFactory)`，actionsFactory 闭包持 manager/record 定位）；五个单实例 @CustomDialog controller（Batch/Selection/DeleteConfirm/RefreshLink + 各 session/model 共享对象成员）；Config.onConfigChanged 注册（回调空实现留给 host 自理——host 在自身构造里注册，Index 不重复注册）。
3. `newMenuItems()` 第 3 项启用：`action: () => this.batchController.open()`。
4. `handleToolbarDelete()` 升级两分支（§3.4）；`deleteSelectedRows` 改名/改造为 `removeRecords(ids, deleteFiles)`（store.remove+双 DS.removeById+选中清理+recompute，live/queued 行 stopOne 移到确认前）。
5. 五事件处理器尾部追加转发：onStarted→`if (Config.getShowProgressWindow() && manager.isInteractive(id)) host.openFor(record)`；onProgress→modelOf 写五字段；onPaused→host.onPaused(id)；onFailed→host.onFailed(id, code)；handleFinished 尾部→`host.onDownloadFinished(id, filePath)`。**既有字段写/DB 写 fire-and-forget 序逐字节保留**。
6. 行上下文菜单：InProgressPane 的 ListItem 包 `.bindContextMenu(this.rowMenuBuilder, ResponseType.RightClick)`——两项（`menu_refresh_link`→onRefreshLink、`lbl_show_progress`→onShowProgress）；onRefreshLink：首选中行 downloadType!=='Http'→alert(`no_refresh_link`)，否则改写 refreshModel + refreshController.open()；onShowProgress：首选中行 host.openFor（幂等）。
7. 批量确认链：`onBatchConfirm(links)` → 填充 SelectionSession（links→SelectionItemModel，name=FileNames.fileNameFromUrl 提取）→ selectionController.open()。
8. 选择确认链：`onSelectionConfirm(items, auth, proxy, startImmediately)` → 逐项 startNewDownload 扩展（auth/proxy 实参、startWaiting=startImmediately——源 startType 缺省 Waiting 仅对 Now/排队生效、`!startImmediately` 才 Stopped（ApplicationCore.cs:138-148 勘误，R4-F1），skip admitNew 分支）。

### 5.12 probe/units/ProbeDialogs.ets（新，P4-U2）
- 会话模型 autoStart=false（S5 人工清单在探针页勾选后单步发射，P4-U1 先例）；S3/S4 用探针页自持的 ProgressWindowHost 实例（init 于探针组件 getUIContext）驱动对话框组件真实开合；确定性 id `probe-p4u2-<runId>-<i>`（store.add 前覆盖，COLD-F1）；DB 行残留与既有探针同口径不清理。
- S3/S4 环境前提：主机侧 node P1-U2-download-server.js（零改动复用；S3 用 `/slow.bin?ms=300`，S4 用 `/small.bin` 快源——若测试源无 small 路由，用 slow.bin?ms=1）。

---

## 6. 探针步骤设计（P4-U2，对应手册/EXPECT）

> 标记格式 `[XDM_PROBE][P4-U2][Sx] key=value`（ProbeKit 复用；值只写观测事实；单行<1500B）。

| 步骤 | 类型 | 操作 | 观测点 → 日志 kvs |
|---|---|---|---|
| BEGIN | 保留 | 探针页"运行全部" | runId/filesDir |
| **S1 批量算法纯函数** | auto | 构造 BatchParams 八场景调 generateBatchLinks+computeBatchPreview：letter A-C；no-asterisk；letter start>=end；letter 缺失；digit 1-3；digit 补零 D3；digit 负数 -1..1 D3；两星号 URL；非法 URL；四链预览 | `letterAC=3` `noAsterisk=0` `letterReversed=0` `letterMissing=0` `digit123=http://.../1|2|3 计数=3` `digitPad=001/002/003` `digitNeg=-001/000/001` `twoStars=替换数=2` `invalid=null` `previewFirst/Second/Last/Size` |
| **S2 限速规范化+Config 回读** | auto | speedLimitView 四场景；Config 快照→setSpeedLimit(true,100)/(true,0)/(false,50) 逐次读回 getter；ConfigChanged 监听计数；恢复快照 | `viewOn=1/100` `viewOffCfg=0/50` `viewZero=0/0` `setTrue100=1/100` `setTrue0=0/0` `setFalse50=0/50` `listenerFired=3` `restored=…` |
| **S3 进度窗生命周期** | auto（慢源） | host.init(探针 UIContext)→store.add(r1 slow.bin?ms=300)+admitNew→轮询 windowCount==1→模型快照（fileName/statusText 前缀/progressPercent 类型）→manager.stopOne→轮询 model.resumable==true+statusText==msg_dwn_stop 值→resumeOne→resumable 回 false→stopOne→closeFor→windowCount==0 | `opened=1` `fileName=p4u2-…` `statusPrefix=Downloading` `pausedResumable=1` `pausedStatus=Download stopped` `resumedResumable=0` `closedCount=0` `liveAfter=0` |
| **S4 完成窗触发门** | auto | 快照 showDownloadCompleteWindow→host.onDownloadFinished('fake-id','/tmp/p4u2.bin')→观测 completedShown=true + windowCount（进度窗不存在不误关）→setShowDownloadCompleteWindow(false)→再调→completedShown=false→恢复 true→读回 | `gateBefore=1` `completedShown1=1` `gateAfterDisable=0` `completedShown2=0` `restored=1` |
| **S5 走查清单** | manual | 探针页 26 项勾选（§6bis）→单步执行 | `checked=<k> total=26 unchecked=<n/n/none>` |
| SUMMARY/END | 保留 | ProbeKit 聚合 | — |

### 6bis. 人工走查清单（26 项，写入手册 §5 并渲染进 S5 勾选面）

1. 新建下拉第 3 项 Batch download 可点，批量窗打开且非模态（主窗可继续操作）
2. 批量窗地址含 `*` 时三预览+数量即时刷新；抹掉 `*` 预览清空
3. Letters 模式 From/To 下拉各 26 项 A..Z；切 Numbers 后 From/To 变数字输入
4. 勾选补零+位数 3 → 数字预览出现前导零（001…）
5. 批量窗 OK 无生成 → "Select items to download" 提示且窗不关；有生成 → 批量窗关、选择窗开
6. 选择窗条目默认全选中；全选框不勾但条目已全选（源码同貌）；取消若干条后 OK 只下被选条目数
7. 选择窗全不选后 OK → "Select items to download" 提示不关窗
8. Download Now → 选择窗关、进行中列表新增行并起跑
9. Download Later → 不使用队列 → 新行 Stopped 不起跑，手动继续可跑（源 startType 缺省 Waiting 仅对 Now 生效，勘误 R4-F1）
10. More → 高级窗有 No Proxy/Manual Proxy 与认证两输入，无 System Proxy 项
11. More 填 user/pass+Manual host/port 确认 → Download Now → 新行建出（行为不因裁剪中断）
12. 进行中行右键 → 菜单含 Refresh link/Show progress 两项
13. 右键 Refresh link → 等待窗打开（Http 记录）；窗显 "Waiting for download link..."
14. 刷新链接窗 Stop → 窗关无残留
15. 右键 Show progress → 进度窗开；重复点击不弹第二窗（幂等）
16. 进度窗文件名/URL/进度/速度/ETA 与主列表行一致
17. 进度窗限速文本初始 "No speed limit"；点击 → 限速窗打开（非模态）
18. 限速窗勾选+输入 100 → OK → 进度窗限速文本变 "Speed limit - 100K/S"（ConfigChanged 刷新）
19. 限速输入非整数被滤除；输入清空失焦 → 勾选自动取消
20. 进度窗 Pause → 状态 "Download stopped"+按钮变 Resume，下载停；Resume → 续跑按钮回 Pause
21. 进度窗 Hide → 窗关下载继续（主列表进度仍在走）
22. 进度窗 Stop → 窗关下载停（行变 Stopped）
23. 小文件完成 → 进度窗自动关 + 完成窗弹出（Download Complete+文件名/目录）
24. 完成窗 Open/Open folder 点击不崩溃（占位）；Don't show this again → 窗关，再次完成下载不再弹
25. 进行中视图选中行 Delete → 行先被停 → 确认框（无删文件选项）→ 确认后行消失且重启不回；Cancel 则行保留（但已停）
26. 完成视图选中行 Delete → 确认框带 "Delete files from disk" 选项 → 确认后行消失；探针页 Credential 步骤：空用户名 OK → "User name required" 不关窗，填名+密码 OK 回调收到 userName，Cancel 无回调

---

## 7. 单元验收测试要点

### [A] 静态门禁（编码员每轮自跑）
- hvigor 全量构建零 error 零新 warning（ArkTS 严格子集编译期强制；写码前对照 arkts-grammar-standards 技能自查：禁 any/对象字面量需类型/无结构化类型）。
- Hypium 本地用例（`entry/src/test`，Deveco 单测跑）：**BatchAlgo 13 条**——letter A-C 逐串比对 3 条 / no-asterisk、reversed、missing 三空场景 3 条 / digit 1-3 串比对 1 条 / 补零 D3 串比对 1 条 / 负数补零 -001/000/001 1 条 / 两星号全量替换 1 条 / 非法 URL→null 1 条 / 预览四链（first/second/last/size）1 条 / 预览单链（second/last 空 size=1）1 条；**SpeedLimitView 6 条**——开+正值/关+正值回填/开+零/开+负值/零速度保存归零投影/负值保存归零投影各 1 条。合计新增 19 条（全库 188→207）。
- 审查自查面：业务文件零 `probe/` import；`[XDM_PROBE]` 仅 ProbeKit 出口；string.json 无尾逗号、键值与 §2.5 表逐字一致。

### [P] 运行时（手册承载，xdm-probe-verify 机械判定 + 人工走查）
- S1/S2 纯函数与 Config 回读（无需测试源）；S3 需慢源；S4 无需网络；S5 人工 26 项。
- 走查环境：模拟器 2in1（PC 形态鼠标右键上下文菜单）或真机。

### 验收对照（UNIT_CATALOG U4.2 行）
| 验收要点 | 覆盖 |
|---|---|
| 各对话框开合/回调接通控制器逻辑 | S1-S4 auto + S5 清单 1-26 逐对话框 |
| 工具栏触发链贯通 | 清单 1（批量入口）/25-26（Delete 两分支）/12（右键触发面）；host 链 S3/S4 |
| 编译过 | [A] hvigor 门禁 |
| 事件面零破坏 | 改动面仅"事件处理器尾部追加转发行"+manager 单观测方法（§5.11-5），Downloader/存储/事件声明零改动（审查核对） |

---

## 8. 风险与备注

| 风险 | 缓解 |
|---|---|
| openCustomDialog 关闭时序（页面销毁时窗残留） | host.closeAll 于 Index aboutToDisappear；ComponentContent 持引用 closeCustomDialog(content)（UIContext.d.ts:1265）；探针页同理 |
| @ObjectLink 在 ComponentContent 内的渲染刷新 | 标准模式（@Observed 类+wrapBuilder 传参）；S3 实跑验证 statusText 变化可观测，FAIL 则降级为 host 定时器拉 model 快照字段（不换引用） |
| C# string.Replace 全量替换 vs JS replace 单次 | BatchAlgo 用 split/join；单测两星号用例锁定 |
| 负数补零格式 | padDigits 负号外置；单测锁定 -001 |
| CustomDialogController builder 构造期绑定 | session/model 共享对象方案（§5.9）；keyConstraint #2 |
| S3 慢源窗口不足 | ms=300 与 P4-U1 S3 同参（提交亚秒 << 下载分钟级）；maxParallel 快照恢复 |
| 完成窗与批量/选择窗叠加时的模态互斥 | 完成窗非模态不阻塞；DeleteConfirm 模态打开时其余窗仍在但输入被遮罩——与源 WPF ShowDialog 行为同貌 |

> 报告员注意：单元报告需引用本设计 §4 全表作降级/差异声明底稿（含勘误①②两处研究结论修正；批量预览路径 null 静默清空勘误另见 §0-8/§3.1/§5.8——按源运行时行为声明，勿写 MSG_INVALID_URL 弹窗）。
