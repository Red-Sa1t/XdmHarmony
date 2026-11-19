# U4.2 对话框包 · 单元迁移报告

> 单元：U4.2 对话框包（Phase 4 UI 对齐）｜报告日期：2026-09-30
> 目标工程：`D:/git/HarmonyPC/XdmHarmony`（API 24 / SDK 6.1.1(24)，ArkTS 严格子集）
> 对照源码：`D:/git/HarmonyPC/resourses/xdm`（XDM 2023，C#/.NET，GPL-2.0，只读）
> 配套：[设计书 u4-2-dialog-package-DESIGN.md](./u4-2-dialog-package-DESIGN.md)、[MIGRATION_PLAN](../MIGRATION_PLAN.md)、[UNIT_CATALOG](../UNIT_CATALOG.md)、[探针手册](../probe/PROBE-u4-2-dialog-package.md)
>
> **结论摘要**：hvigor 编译门禁**通过**（代码可构建）；官方对照审查轮次记录 5/3/3 项——已修四项（R2-F1/F2/F3 18:52、R3-F1 设计书勘误 19:13），报告初稿成文时点（19:12）第 3 轮裁定 approved=false（R3-F1 未决），其修复晚于成文落地（§4/§5.3，R4-F2 更正）；内部轮次修复/遗留与独立复核项改用 INT-F\*/IR-F\* 独立编号，避免与官方 ID 冲突；独立复核**可接受**（acceptable=true；未修遗留 8 项=1 medium + 7 low，见 §4/§7）；IR-F2（选择链初始状态极性颠倒且落库）已随 **R4-F1** 修复。运行时探针 P4-U2 已生成、**待人工在模拟器/真机执行**。

---

## 1. 单元范围与验收要点

### 1.1 范围

按 XDM.Core/UI 的 I*View 契约实现 8 个操作类对话框并接通工具栏与引擎/存储（UNIT_CATALOG.md U4.2 行）：

| # | 对话框 | 对照源（Wpf.UI/Dialogs/ + Core 控制器） | 落点文件 |
|---|---|---|---|
| 1 | ProgressWindow 进度窗 | DownloadProgressWindow.xaml(.cs) + ApplicationCore.cs:160-500 | components/ProgressWindowDialog.ets |
| 2 | SpeedLimiter 限速窗 | SpeedLimiterUIController.cs:9-33 + SpeedLimiter.xaml.cs | components/SpeedLimiterDialog.ets + core/util/SpeedLimitView.ets |
| 3 | BatchDownload 批量窗 | BatchDownloadUIController.cs:22-159 | components/BatchDownloadDialog.ets + core/util/BatchAlgo.ets |
| 4 | DownloadSelection 选择窗 | DownloadSelectionUIController.cs:22-135（含 More 子窗） | components/DownloadSelectionDialog.ets |
| 5 | DeleteConfirm 删除确认 | UIActions.cs:19-55 + DeleteConfirmDialog.xaml.cs | components/DeleteConfirmDialog.ets |
| 6 | CompletedDialog 完成窗 | ApplicationCore.cs:421-444 + DownloadCompleteUIController.cs | components/CompletedDialog.ets |
| 7 | RefreshLink 刷新链接 | LinkRefreshDialogUIController.cs:17-81 | components/RefreshLinkDialog.ets |
| 8 | CredentialDialog 凭据 | CredentialsPromptDialog.xaml.cs:26-72（源码死链，§3） | components/CredentialDialog.ets |

配套改动：`string.json` 键骨架追加（设计 §2.5 表逐键列值=English.txt 原文；本会话 grep 抽验 9 键在位）、`Config.ets` 追加 `showProgressWindow`/`showDownloadCompleteWindow` 两键与 ConfigChanged 监听面、`DownloadManager.ets` 追加只读观测面（isInteractive/endedNonInteractive）、`Index.ets` 触发链接线、探针 P4-U2 与两套单测。实现文件共 21 项（新 13 / 改 6 / 文档 2，与设计 §1 清单一一对应）。

`module.json5` 与 `main_pages.json` 本单元**零改动**（设计 §0-7：对话框不新增能力面，INTERNET 已于 U0.1 补齐、deviceTypes 已含 2in1）。

### 1.2 验收要点与达成

| 验收要点（UNIT_CATALOG U4.2） | 达成情况 | 依据 |
|---|---|---|
| 编译过 | **达成**：hvigor 全量构建通过（§5.1） | 门禁结论（脚本执行） |
| 各对话框开合/回调对照源码 | 静态面达成（审查 3 轮收敛+独立复核可接受）；运行时面**待探针/走查**（§6） | §2/§4/§6 |
| 工具栏触发链贯通 | 静态面达成：New 下拉批量入口（Index.ets:854-874）、Delete 两分支（Index.ets:727-760）、行右键两项（Index.ets:1085-1097）均已接线；运行时待走查 | §6 |
| 事件面零破坏 | 达成：五事件处理器仅尾部追加 host 转发（Index.ets:434-551），事件三声明/引擎方法签名零改动；manager 仅追加两处只读观测面（DownloadManager.ets:19-20 头注登记） | 实现清单+§4 |

---

## 2. 研究结论摘要（关键源码行为 → ArkTS 对应）

研究阶段逐文件读通 I*View 契约、平台无关控制器与 WPF 实现；设计阶段另作**两处勘误**（见 2.11）。

| # | 源码行为（锚） | ArkTS 对应 | 备注 |
|---|---|---|---|
| 2.1 | 限速窗读写规范化数学：装载 `enabled = EnableSpeedLimit ? speed>0 : false`（禁用也回填值）；保存 `EnableSpeedLimit = enabled?speed>0:false`、`speed>0?speed:0`（SpeedLimiterUIController.cs:9-33）；LostFocus 空/非整数→自动取消勾选 | `speedLimitView()` 纯函数（SpeedLimitView.ets）+ SpeedLimiterDialog（onChange 整数过滤、onBlur 取消勾选，差异 #15）+ `Config.setSpeedLimit`（U3.2 已按同式实现，纯消费） | 全仓唯一入口=进度窗限速文本点击（WPF/GTK grep 核实） |
| 2.2 | 进度窗状态机：创建 FileName/URL/STAT_DOWNLOADING；进度钳位 0-100；暂停钮 Tag=null/new() 分派 Pause/Resume；Window_Closing→StopDownload(true)（关窗即停）；Hide→隐藏不停且窗销毁（ApplicationCore.cs:166-176/305-319/359-393/421-494） | `ProgressWindowModel`（@Observed 九字段）+ `ProgressWindowHost` 动态多窗（Map<id,{model,content}>）；autoCancel:false 防误触（差异 #1/#2） | Tag→`resumable: boolean` 字段 |
| 2.3 | 删除两分支：进行中=**先 StopDownloads 再确认**（Cancel 行也已被停，记录可恢复）且无删文件选项；完成=模态确认框带删文件勾选（UIActions.cs:19-55） | `handleToolbarDelete` 两分支（Index.ets:727-760）：进行中逐 id stopOne→showAlertDialog→`removeRecords`；完成→DeleteConfirmDialog→`onDeleteConfirmed` | stopOne 同步、alert 异步，时序天然保持 |
| 2.4 | 批量生成：URL 含 `*` 才生成；字母 startChar>=endChar→空、缺字母→空；数字补零 `D{n}`；`string.Replace` 全量替换（BatchDownloadUIController.cs:105-159）；Links tab=死 UI（:49 IsBatchMode 门） | `BatchAlgo.ets` 纯函数（null=URL 非法 / []=空生成语义分离；padDigits 负号外置；split/join 全量替换）+ 13 条单测；Links 死 tab 渲染不接线（差异 #7） | |
| 2.5 | 选择窗契约：条目默认全选（全选框初始不勾=源码同貌）；校验链 folder 空→MSG_CAT_FOLDER_MISSING→选中 0→BAT_SELECT_ITEMS；Now/Later 分型（Later 不起跑）；More 回填 auth/proxy（DownloadSelectionUIController.cs:22-135） | `DownloadSelectionDialog` + SelectionSession 共享对象（controller 构造期绑定）；Later 用 bindMenu（零队列项+两固定项，差异 #9）；More 子窗裁剪版（差异 #10） | **更新（R4-F1）**：独立复核指出的 Later 分支落库极性颠倒已修复——Now→Waiting/Later→Stopped（Index.ets:908-912，IR-F2），初态与源一致 |
| 2.6 | 完成窗触发：完成且 !nonInteractive 且 Config.ShowDownloadCompleteWindow 才弹（ApplicationCore.cs:410-414 双门） | `host.onDownloadFinished`：`Config.getShowDownloadCompleteWindow() && !manager.endedNonInteractive(id)`（ProgressWindowDialog.ets:316-322，内部轮次 INT-F3 补齐双门） | DontShowAgain 持久化（差异 #14，源码仅内存态） |
| 2.7 | 凭据对话框：空用户名不关窗；PromptForCredential 在 2023 全仓 **0 调用方=死链**（grep 证实） | 对话框先行+探针可达（Index 不持控制器）；Basic 头注入与 401 挑战重试登记 U6.x（拍板①：不做 preemptive 注入）；产物写既有 `record.authentication`（勘误②） | 源码运行时该窗本身不可达 |
| 2.8 | 刷新链接：非 Http→NO_REFRESH_LINK 不开窗；Http→提取 referer→OpenBrowser→等待窗；关闭即 WatchingStopped→ClearWatchList（LinkRefreshDialogUIController.cs:17-81） | 对话框+生命周期落地（等待态+Stop→close+onStopped 占位）；referer 提取**不可达**（勘误①：StateStore 只持久化 chunks 无 headers）；LinkRefresher 匹配数学/桥接登记 U6.x（差异 #13） | |
| 2.9 | 模态分型：8 窗中仅 DeleteConfirm/Credential/AdvancedOption 三件模态 ShowDialog()，其余全非模态 Show()（各 code-behind 调用点核实） | 非模态六窗 `openCustomDialog(isModal:false)` / @CustomDialog `isModal:false`；模态三件套默认 isModal:true（设计 §3.8 分型表） | API 11+ 可用，本工程 API 24 |
| 2.10 | 文案键：English.txt 原文逐键（设计 §2.5 表 49 键含 More 子窗 5 键；研究初估约 34 键经设计扩展） | `string.json` 追加，键名 camelCase 沿用工程约定；本会话 grep 抽验 `bat_select_items`/`cd_title`/`lbl_delete_file`/`msg_speed_limit`/`ref_waiting_for_link`/`desc_user`/`nd_auth`/`del_sel_text`/`stat_assembling` 9 键均在位 | zh_CN/en_US 值按 U4.3 节奏补 |
| 2.11 | **研究结论勘误①**：StateStore 只持久化分片 JSON 不含请求头（StateStore.ets:40-42 本会话核实）→ referer 提取在当前存储面不可达；**勘误②**：`DownloadRecord.authentication` 已存在且经 downloads 表 auth/user/pass 列持久化 → 零新增字段零表结构变更 | 设计书 §0-1/§0-2 采纳；差异 #12/#13 | 两处勘误均写进设计书，不照搬研究材料 |

---

## 3. 设计决策与有意差异（引用 MIGRATION_PLAN 决策条款）

### 3.1 决策条款引用

| 引用 | 在本单元的落法 |
|---|---|
| MIGRATION_PLAN §6 决策 11（按 I*View 接口契约实现 ArkUI 版"第三平台 UI"） | 8 对话框全部按契约+平台无关控制器对照翻译（§2 表）；对话框形态对照 Wpf Show()/ShowDialog() 分型 1:1 |
| §6 决策 10（配置对照 Config 44 键存 preferences） | 追加 `showProgressWindow`/`showDownloadCompleteWindow` 两键；完成窗 DontShowAgain 持久化=决策 10 的自然推论（差异 #14） |
| §3 降级清单条款 2（系统代理自动检测→仅手动代理） | More 子窗 System Proxy 选项隐藏（差异 #10/#18） |
| §3 条款 1/3/5（yt-dlp/NTLM/关机动作/杀毒） | 降级项不在任何对话框出现；视频向导菜单项维持占位禁用（差异 #18） |
| §6 决策 2 推论（事件面/线程模型：主线程单点管理） | 引擎事件本就主线程回调，五事件处理器**仅尾部追加分发行**、既有字段写序逐字节不动（Index.ets:430-432 红线注释）；manager 仅追加 `isInteractive`/`endedNonInteractive` 两处只读观测面 |
| §5 目标工程结构 | 对话框落 `components/`、纯函数落 `core/util/`、探针落 `probe/units/`，与计划结构一致 |

### 3.2 有意差异清单

权威底稿为设计书 §4 表（20 条），任务卡差异清单（19 条）为同一清单的浓缩表述（#1/#2 拆分口径差异）。要点归类：

1. **形态类**：进度窗/完成窗/限速窗用 `openCustomDialog(ComponentContent,{isModal:false})` 复刻动态多窗与非模态六窗，模态三件套用默认模态（#1）；进度窗 `autoCancel:false` 关闭路径仅 Hide（不停）/Stop（stopOne+关）（#2）；CustomDialog 无标题栏，`Title={p}% {name}` 由进度条+文本承载（#1）。
2. **事件面冻结类**：STAT_ASSEMBLING 装配态不呈现、键保留（#3，Downloader 无 assembling 事件）；失败态 statusText=`'error '+errCode`，本地化表随 U4.3（#4）。
3. **能力面后置类**：deleteFiles 勾选只收值不删盘上文件（#6，U5.2）；Browse 占位恒 `Config.getDownloadDir()`（#8，DocumentViewPicker 归 U5.2，拍板②）；完成窗 Open/Open folder 占位 hilog（同 D6 模式）。
4. **源码同貌保留类**：Batch Links 死 tab 渲染不接线（#7，源 :49 门=死 UI）；选择窗条目默认全选而全选框不勾（§2.2）。
5. **裁剪类**：Download Later 队列菜单无命名队列项、Queue and scheduler 占位禁用（#9）；More 子窗裁剪 System Proxy 与限速段（#10，源控制器只消费 view.Authentication/Proxy，限速两值为死值——DownloadSelectionUIController.cs:99-112 核实）；行上下文菜单只设 Refresh link/Show progress 两项（#17，源 10 项其余动作不在本单元）。
6. **勘误拍板类**：Credential 无业务触发点、对话框先行+探针可达，Basic 头注入/401 重试不做 preemptive（#11，拍板①）；凭据产物写既有 `record.authentication`（#12，勘误②）；RefreshLink referer 休眠、LinkRefresher 登记U6.x（#13，勘误①）。
7. **语义升级类**：进行中删除分支由 U4.1 简版"停不删"升级为源码全链"先停→确认→删记录"（#5，UIActions.cs:19-37）；U4.1 走查清单第 17 项语义随之更新。
8. **其他**：DontShowAgain 持久化（#14）；限速整数过滤改 onChange 字符重写、IsReadOnly 改 `.enabled()`（#15）；进度窗创建时机经 `manager.isInteractive(id)` 实现源非对称（#16，Start 恒开/Resume 看 nonInteractive）；yt-dlp/系统代理/NTLM/关机等降级项不出现（#18）；状态栏 Queue/Help 维持占位禁用（#19）；U4.1 复核遗留 low 不顺手修（#20，归 U4.3 复核批次）。

### 3.3 实现期对设计的一处技术勘正（非差异）

设计 §3.8/§5.6 写 `UIContext.openCustomDialog`；实现核实该 ComponentContent 重载实际位于 `UIContext.getPromptAction()` 返回的 PromptAction 实例上（@ohos.arkui.UIContext.d.ts class PromptAction 内），已在 ProgressWindowDialog.ets:5-12 头注登记（设计锚为文件行号非类成员锚）。行为面与设计一致，仅通道锚点勘正。

---

## 4. 审查问题处置表（全部轮次）

**官方对照审查**轮次记录为 5/3/3 项（第 1 轮 5 项 → 第 2 轮 3 项 → 第 3 轮 3 项）。任务卡【历史反馈】可完整列出的官方已修四项：**R2-F1、R2-F2、R2-F3**（18:52 修复）与 **R3-F1**（设计书勘误，19:13 修复——晚于本报告初稿 19:12 成文）；第 1 轮 5 项与第 3 轮其余两项的明细未随本轮材料提供，本表不作推测。**内部编码轮次**（13:20-13:21 前后工作区改动，未列入官方轮次）三项修复与五项遗留改用 **INT-F\*** 独立编号；**独立复核**四项改用 **IR-F\*** 独立编号——避免与官方 ID 冲突（初稿曾把内部三项误标为官方 R2-F1/F2/F3、把内部五项遗留误标为 R2-F4..F8/R3-F1..F5，R4-F2 更正）。IR-F2（选择链初始状态极性）已随 **R4-F1** 修复。下表去重共 16 项（官方已修 4 + 内部已修 3 + 本轮已修 1 + 未修遗留 8）。

| 编号 | 来源/轮次 | 严重度 | 问题摘要 | 处置 | 证据 |
|---|---|---|---|---|---|
| R2-F1 | 官方第 2 轮 | — | 单测 twoStars_replacesAllOccurrences 区间 'A'..'A'——BatchAlgo.ets:73-75 startChar>=endChar 返回 []，断言 length===1 必红，且未触达两星号替换路径（严格区间 start<end 最少生成 2 条） | **已修复**（18:52）：区间改 'A'..'B'，断言 length=2、links[0]='http://probe.local/aAbAc.bin'、links[1]='http://probe.local/aBbBc.bin' | BatchAlgo.test.ets:167-184（本轮重读核实） |
| R2-F2 | 官方第 2 轮 | — | 探针 S1 场景⑧ twoStarsParams 同用 'A'..'A' → generateBatchLinks 返回 [] → twoStarsCount=-1，而 EXPECT-u4-2 S1 判 twoStars=2 → verify 必 FAIL；两星号全量替换探针面零覆盖 | **已修复**（18:52）：twoStarsParams.endLetter 改 'B'（links[0]='…/aAbAc.bin'，countChar(links[0],'A')=2） | ProbeDialogs.ets:278-288（本轮重读核实）；docs/probe/EXPECT-u4-2-dialog-package.json:13 |
| R2-F3 | 官方第 2 轮 | — | 业务面唯二下载记录创建点（Index.startNewDownload/onSelectionConfirm）newDownloadRecord 第 4 参 downloadType 恒 null，而 onRefreshLinkMenu 以 record.downloadType!=='Http' 门控 → 刷新链接业务面不可达、走查第 13 项不可能通过（源 AddItemToTop 落 download.Type='Http'） | **已修复**（18:52）：两处第 4 参改传 'Http' | Index.ets:392/:911（本轮重读核实）；resourses/xdm ApplicationCore.cs:150 |
| R3-F1 | 官方第 3 轮 | medium | 返修批次声明 3 文件但工作区另有 3 处未声明改动（13:20-13:21），其中①预览路径静默清空与设计书 §3.1/:202、§5.8 明文"null→showAlertDialog(msg_invalid_url)"矛盾且 §4 差异清单未同步——单元报告将以 §4 为声明底稿把预览行为写错 | **已修复**（19:13）：设计书 §0-8 返修补录三文件 + §3.1/:204 与 §5.8/:378 勘误注记（援引 BatchDownloadUIController.cs:105-117 catch-all 使 OnBatchPatternChange :95-98 不可达）+ §8 尾注报告员指针；代码核实为源码保真零再改 | u4-2-dialog-package-DESIGN.md:21（§0-8）/:204/:378/:487 |
| INT-F1 | 内部轮次（原误标 R2-F1） | medium | 行右键菜单用 firstSelectedId 定位——右键不触发行选中，未先左键选中时菜单点击无动作/错行 | **已修复**：bindContextMenu onAppear 捕获被右击行 id + `selectRow(id)`（WPF 右键即选中同构），菜单项按 `contextMenuRowId` 分派 | Index.ets:170-172/:931-934/:1085-1097/:1130-1135 |
| INT-F2 | 内部轮次 13:20-13:21（原误标 R2-F2） | medium | 批量预览 URL 非法时弹 msg_invalid_url 模态框——源公共 GenerateBatchLink catch 全部异常返空、运行时预览从不弹窗；暂态非法输入反复弹模态框 | **已修复**：recomputePreview 对 null 与 [] 统一静默清空；showMsg 仅剩 OK 路径 | BatchDownloadDialog.ets:80-92/:100-103（本轮重读核实） |
| INT-F3 | 内部轮次 13:20-13:21（原误标 R2-F3） | medium | 完成窗门只查 Config、缺源码 !nonInteractive（ApplicationCore.cs:410-414）；事件簿记先摘 liveMap，事后 isInteractive 恒 true 无法补判 | **已修复**：manager 追加 endedNonInteractiveMap 快照 + `endedNonInteractive(id)`；完成窗门升为 Config && !nonInteractive 双门 | DownloadManager.ets:19-20/:133-136/:269-286；ProgressWindowDialog.ets:316-322/:31（本轮重读核实） |
| INT-F4 | 内部轮次遗留，内部复核两轮复认（原误标 R2-F4/R3-F1；独立复核同判，原编号独立F5） | low | 删记录只删 DB 行与列表行，不清理恢复态与临时分片（源 RemoveDownload 即使 deleteFiles=false 也删 state 与 tempDir）；差异 #6 未覆盖此残留 | **未修，登记 U5.2/U6.x**（StateStore 增 per-id 删除并与文件删除同批，或补差异声明） | Index.ets:771-801（removeRecords 仅 store.remove+双 DS 移除） |
| INT-F5 | 内部轮次遗留，内部复核两轮复认（原误标 R2-F5/R3-F2；独立复核同判，原编号独立F6） | low | 缺 `view.Proxy ?? Config.Proxy` 回退与 More 子窗 Config proxy 预填；当前 Config 无 proxy 键且引擎不消费 proxy，偏差休眠 | **未修，登记 U6.x**（代理消费落地时两处对齐） | Index.ets:903-927（onSelectionConfirm 直传 session.proxy，无回退） |
| INT-F6 | 内部轮次遗留，内部复核两轮复认（原误标 R2-F6/R3-F3；独立复核同判，原编号独立F7） | low | RefreshLinkDialog.onOpenReferer 在对话框内无调用点且 model.waiting 无读者=死代码；autoCancel:true 外部点击关窗不触发 onStopped（源任何关闭路径经 Window_Closing 都触发 WatchingStopped） | **未修，登记**（删死回调死字段或改为对话框内消费；aboutToDisappear 兜底 onStopped+handleStop 幂等守卫） | RefreshLinkDialog.ets:34-36/:39-42；Index.ets:213-226 |
| INT-F7 | 内部轮次遗留，内部复核两轮复认（原误标 R2-F7/R3-F4；独立复核同判，原编号独立F8） | low | 反复进出探针页 createDetached 新 host 并注册 ConfigChanged 监听，aboutToDisappear 只 closeAll 不 offConfigChanged——累积死监听器（泄漏，回调无害） | **未修，登记 U4.3 复核批次**（aboutToDisappear 补 offConfigChanged 或 host 增 dispose 收口） | ProbeDialogs.ets:142-145（aboutToDisappear 仅 host.closeAll()） |
| INT-F8 | 内部轮次遗留，内部复核两轮复认（原误标 R2-F8/R3-F5；独立复核同判，原编号独立F9） | low | Show progress 右键对任意进行中行开进度窗——源 ShowProgressWindow 要求 liveDownloads.ContainsKey 否则静默返回（ApplicationCore.cs:326-334）；且源重开重设 FileSizeText='Downloading ...'，openFor 幂等 no-op 对已停行开出钉旧文本的窗 | **未修，登记**（增 manager.isLive(id) 门；openFor 重开路径补 statusText/resumable 复位） | Index.ets:970-978（onShowProgressMenu 无 isLive 门） |
| IR-F1 | 独立复核 | medium | 完成窗单飞：completedOpen 存活期间后续 onDownloadFinished 全被静默吞——源码每次完成新窗可叠加，批量 3 并发小文件完成只弹第 1 窗；设计差异表无此项声明 | **未修**（独立复核判定可接受；建议下单元改 per-id 簿记并补差异声明，见 §8） | ProgressWindowDialog.ets:389-393（completedOpen 早退门）、418（置位） |
| IR-F2 | 独立复核 | medium | 选择链初始状态与源码整对颠倒并落库：`newDownloadRecord(..., !startImmediately, ...)` 使 Download Now（含排队）落 Stopped、Download Later 落 Waiting（源 StartDownload 缺省 Waiting 仅对 Now/排队生效、`!startImmediately` 才 Stopped）；U1.2 先例 startNewDownload 传 true 与源一致，本链单独反掉；走查清单第 9 项曾把错误预期固化 | **已修复（R4-F1，本轮）**：实参改 `startImmediately`（Now/排队→Waiting、Later→Stopped，本轮对照 C# 源逐行核实）；文本同步——设计书 §3.5/:243-244 与 §5.11-8/:401 极性、§6bis 第 9 项/:433、手册 §5 第 9 项/:117、ProbeDialogs.ets:74 勾选面、Index.ets:898-900 注释（EXPECT 无 S5 极性预期，grep 核实零改动） | Index.ets:908-912（在位实参）；resourses/xdm ApplicationCore.cs:138-148、Application.cs:56 |
| IR-F3 | 独立复核 | low | openCustomDialog Promise reject 时 catch 只记 hilog 不复位标志——completedOpen/speedLimiterOpen 恒 true，此后完成窗与限速窗永久静默（直至 closeAll 兜底），用户零反馈 | **未修，登记下单元**（两处 .catch 内复位标志并置空 content） | ProgressWindowDialog.ets:340-346（openSpeedLimiter 置位后 catch 仅日志）、417-424（openCompleted 同型） |
| IR-F4 | 独立复核 | low | 开/关 Promise 竞态：小文件毫秒级完成时 closeFor 可能在 openCustomDialog 落位前到达，closeCustomDialog 对未开窗 reject（仅记日志），窗随后打开成孤儿（autoCancel:false 关不掉、按钮 no-op）。按 ArkUI Promise 语义推断，无模拟器未实测 | **未修，登记**（openFor 记 pending 状态补发 close；建议探针 S3/走查 23 项实测观察） | ProgressWindowDialog.ets:248-260（windows.set 后异步开窗）vs 264-278（closeFor 立即 delete+close） |

> 处置口径说明：官方四项修复均最小化（R2 三项=单测区间/探针参数/两实参，R3-F1=纯文档勘误零代码）；内部三项修复=四文件改动、零新文件、事件三声明与既有 API 签名不动；IR-F2=一实参+注释与五处文本同步。8 项未修遗留中 5 项为内部复核两轮持续复认的 low（登记 U4.3/U5.2/U6.x），3 项为独立复核新增（IR-F1 medium + IR-F3/F4 low，登记下单元/U6.x）。证据列行号：标"本轮重读核实"者为本报告员本轮（R4）实测；其余承初稿成文会话实测，本轮未逐一复跑。独立复核结论 acceptable=true（即遗留项不阻塞本单元验收）。

---

## 5. 验证情况

### 5.1 hvigor 编译门禁（主门禁）——通过

- 命令：`devecocli build --modules entry`（工作流脚本统一执行）。
- 最终状态：**通过**（0 error）。本报告员本会话未复跑构建（按单元流程由脚本统一执行），上述结论引用任务卡门禁记录；**当前代码可构建，无需标注不可构建**。
- ArkTS 严格子集由 hvigor 编译期强制（MIGRATION_PLAN §8 验证矩阵），门禁通过即 ArkTS 合规通过。编码期另按 arkts-grammar-standards 技能自查（禁 any、对象字面量需类型等），实现清单各文件 check 备注均注明 lint/平衡校验状态。

### 5.2 codelinter 辅助检查（提示性）——exit 0

- 结果：exit 0；Summary：**Issues 19 | Errors 0 | Warnings 17 | Suggestions 2 | Files checked 5**。
- 可见建议项：`@performance/hp-arkui-set-cache-count-for-lazyforeach-grid`（Index.ets，LazyForEach 场景 cachedCount 建议，属 U4.1 起基线项）。任务卡所贴输出前段被截断，以上以 Summary 行为准。
- codelinter 不含 ArkTS 语法规则（实测结论，MIGRATION_PLAN §8），仅作性能/安全辅助提示；17 条 warning 为既有基线（含 CompletedDialog 1 条既有同类警告）。

### 5.3 对照审查——官方轮次记录 5/3/3 项（R4-F2 更正）

官方轮次：第 1 轮 5 项（明细未随本轮材料提供）→ 第 2 轮 3 项（R2-F1/F2/F3：twoStars 单测区间 'A'..'A'、探针 twoStarsParams 'A'..'A'、downloadType 恒 null）→ **18:52 修复**（三文件：BatchAlgo.test.ets/ProbeDialogs.ets/Index.ets，零新文件）→ 第 3 轮 3 项（含 R3-F1 设计书勘误，medium）。**批准时点更正：报告初稿 19:12 成文时第 3 轮裁定 approved=false（R3-F1 未决）**，初稿"第 3 轮复核 5 项均为遗留复认、approved=true"与轮次记录不符；R3-F1 修复（设计书 §0-8/:204/:378 勘误）**19:13 落地**，晚于初稿成文，该轮阻断项已消除。初稿"第 2 轮 8 项"系把内部编码轮次（13:20-13:21 前后三项修复+五项遗留，现 INT-F1..F8）误并入官方轮次所致。全史见 §4。

### 5.4 独立复核——可接受（acceptable=true）

换人复核结论可接受，9 项 findings（4 项新增：IR-F1 完成窗单飞 medium、IR-F2 选择链 startWaiting 取反 medium、IR-F3 openCustomDialog 失败不复位 low、IR-F4 开关竞态 low；5 low 为内部轮次遗留复认=INT-F4..F8）。最弱点评定：ProgressWindowHost 动态窗簿记与 PromptAction 异步时序（IR-F1/F3/F4——全异步且失败只进 hilog、错误对用户零反馈）；其次 IR-F2 状态颠倒落库。逐项现状已在代码复核确认（§4 证据列）；**IR-F2 已随 R4-F1 修复**，不属未修遗留。

### 5.5 单元测试

- `entry/src/test/BatchAlgo.test.ets`（13 条：字母/空场景/数字/补零/负数补零/两星号全量替换/非法 URL null/预览四链与单链）与 `SpeedLimitView.test.ets`（6 条规范化场景）已按设计 §7 落地并注册入 List.test.ets 套件；实现清单标注"通过（本轮无改动）"。
- **本会话未运行 Hypium 测试**（需 DevEco 测试环境），上述通过结论引自实现清单与审查记录，非本报告员复跑。

### 5.6 本报告员本会话实测复核项

| 项 | 方法 | 结果 |
|---|---|---|
| 官方 R2-F1/F2/F3 修复在位（twoStars 单测/探针 twoStars/downloadType 'Http'，R4-F2 更正归属） | 逐文件 Read（BatchAlgo.test.ets:167-184、ProbeDialogs.ets:278-288、Index.ets:392/:911） | 全部在位（§4 证据行号） |
| 官方 R3-F1 勘误在位 | Read 设计书 §0-8/:21、:204、:378、:487 | 全部在位（19:13 落地） |
| IR-F2 修复在位 + 极性对照源核实 | Read Index.ets:908-912；对照 resourses/xdm ApplicationCore.cs:138-148、Application.cs:56 | 在位且与源一致（R4-F1） |
| 内部/独立复核遗留现状在位（INT-F4..F8、IR-F1/F3/F4） | 承初稿成文会话实测（§4 证据列；本轮未逐一复跑） | 记录为未修（§4/§7） |
| string.json 键追加 | grep 抽验 9 键 | 全部在位（§1.1） |
| 探针手册/预期表文件存在 | ls docs/probe/ | PROBE-u4-2-dialog-package.md 与 EXPECT-u4-2-dialog-package.json 均在（§6） |
| module.json5/main_pages.json 零改动声明 | 引设计 §0-7（本会话未 diff 历史版本） | 声明与实现清单一致 |

---

## 6. 运行时验证待办（探针 P4-U2，待人工执行）

- **手册**：`docs/probe/PROBE-u4-2-dialog-package.md`；**预期表**：`docs/probe/EXPECT-u4-2-dialog-package.json`。8 步骤：BEGIN + S1（批量算法纯函数八场景）+ S2（限速规范化+Config 回读）+ S3（进度窗生命周期，慢源实跑）+ S4（完成窗触发门）+ S5（人工走查清单 26 项勾选）+ SUMMARY/END。标记格式 `[XDM_PROBE][P4-U2][Sx] key=value`。
- **运行次序红线（本单元特有）**：①先主页面人工走查清单 1-25 项（此刻 manager 事件袋归 Index）→ ②再进探针页"运行全部"（S1-S4 自动；S3 接管事件袋并实跑慢源下载，此后 Index 列表不再收引擎事件属预期）→ ③回探针页勾选 26 项单步执行 S5 → ④探针会话内不切页。
- **测试源**：仅 S3 需要主机侧 `node P1-U2-download-server.js`（零改动复用，S3 消费 `/slow.bin?ms=300`，ms 由探针 URL 参数携带）；填主机局域网 IP（模拟器内 127.0.0.1 为自身回环）。
- **环境**：模拟器 2in1 PC 形态（鼠标右键上下文菜单走查更真实）或真机（需一次性签名准备）。
- **核对方式**：人工运行后回贴 hilog 日志（domain 0xD001 / tag XDM_PROBE），由 `xdm-probe-verify` 工作流逐步骤判定并分流返修。
- **走查前注意（R4-F1 更新）**：IR-F2 极性颠倒已修复——走查清单第 9 项与联动文本已同步为源码口径（"Download Later → 新行 Stopped 不起跑"：设计书 §6bis/:433、§5.11-8/:401、手册 §5/:117、ProbeDialogs.ets:74 勾选面；EXPECT 的 S5 仅记 checked/total/unchecked 计数、无极性预期，grep 核实零改动），按修订后预期走查即可。

---

## 7. 遗留问题与风险

### 7.1 未修遗留（8 项，编号与 §4 对应；原独立F2 已随 R4-F1 修复移出）

| 优先建议 | 编号 | 严重度 | 影响 |
|---|---|---|---|
| 中（批量场景体验） | IR-F1 | medium | 3 并发小文件完成只弹第 1 个完成窗，其余丢失 |
| 中（容错） | IR-F3 | low | openCustomDialog 一次失败后完成窗/限速窗永久静默且零反馈 |
| 中（未实测） | IR-F4 | low | 毫秒级完成可能产生关不掉的孤儿进度窗（按 Promise 语义推断，探针/走查可暴露） |
| 低（登记 U5.2/U6.x） | INT-F4 | low | 删记录不清理恢复态与临时分片（磁盘残留） |
| 低（休眠，登记 U6.x） | INT-F5 | low | proxy 回退缺失（Config 无 proxy 键、引擎不消费，当前无可见影响） |
| 低（登记） | INT-F6 | low | RefreshLink 死回调死字段；外部点击关刷新窗不触发 onStopped（清候选占位缺位，U6.x 前候选清单本身未建） |
| 低（登记 U4.3） | INT-F7 | low | 探针页 ConfigChanged 死监听器累积泄漏 |
| 低（登记） | INT-F8 | low | Show progress 对已停/排队行开窗且文本钉旧值 |

另有既定登记项（非缺陷，见 §3.2）：Basic 头注入与 401 挑战重试、LinkRefresher 匹配数学、headers 持久化与 referer 提取、桥接 /link 入口——归 U6.x；deleteFiles 盘上删除/Browse picker/openFile/openFolder/StateStore per-id 删除——归 U5.2。

### 7.2 风险评定

1. **最可能出运行时问题**：ProgressWindowHost 的动态窗簿记与 PromptAction 异步时序（独立复核 weakestSpot；IR-F1/F3/F4 叠加）——错误路径只进 hilog、用户侧零反馈。暴露窗口：探针 S3/S4 与走查第 23 项（小文件完成弹窗）。
2. **IR-F2 状态颠倒已随 R4-F1 修复**（极性实参+文本五处同步，本轮对照 C# 源逐行核实）——当前无影响**持久化数据正确性**的已知遗留。
3. ~~走查预期表联动风险~~（已消除）：第 9 项预期已随 R4-F1 同步为源码口径（§6）。
4. codelinter 17 warnings/2 suggestions 为基线项，无 error；不阻塞验收。
5. 材料一致性核对：任务卡【实现摘要】称"lint 全域零 error、花括号平衡校验通过"，与门禁记录（Issues 19/Errors 0）一致，无矛盾；官方第 3 轮 approved=false（R3-F1 未决）→ 勘误 19:13 落地后阻断项消除，独立复核 acceptable=true；门禁通过为最终裁定，**无"审查通过但门禁失败"类矛盾**（§5.3 R4-F2 更正口径）。

---

## 8. 对下个单元的建议

1. **U4.3（设置页全配置键+i18n+主题）前置小修批次（建议随 U4.3 首轮一起做）**：
   - ~~独立F2~~ **已完成（R4-F1，本轮）**：极性实参与五处文本已同步（§4 IR-F2 行）；
   - IR-F1/F3：完成窗改 per-id 簿记（同 activeProgressWindows 模式）+ openCustomDialog 两处 catch 复位标志；完成后在设计差异表补 IR-F1 声明（或修复后删除）；
   - 随 U4.3 全键扫描并入：`showDownloadCompleteWindow`（DontShowAgain 键）与 GetLocalizedErrorMessage 错误码映射表（差异 #4 收口）；
   - U4.1 复核遗留 low + INT-F7（探针监听泄漏）+ INT-F8（isLive 门）按差异 #20 口径归 U4.3 复核批次一并处理。
2. ~~探针执行前拍板 F2~~（§6）：**已拍板并修复（R4-F1）**——预期文本已联动修订（手册第 9 项/设计书 §6bis 等），可直接走查。
3. **U5.2**：deleteFiles 落文件删除、StateStore per-id 态删除（INT-F4）、Browse 接 DocumentViewPicker、openFile/openFolder 接线（当前占位 hilog 的四个触点）。
4. **U6.x**：Basic 头注入与 401 挑战自动重试、LinkRefresher 匹配数学（Content-Length==FileSize）、下载状态 headers 持久化与 referer 提取、桥接 /link 入口、proxy 回退两处对齐（INT-F5）。
5. **IR-F4 竞态**：探针 S3 与走查 23 项实测观察毫秒级小文件场景；如复现孤儿窗，按复核建议 openFor 记 pending 状态补发 close。
6. 流程提醒：本单元 module.json5/main_pages.json 零改动成立的前提是"对话框无新能力面"；后续单元若引入网络新面/后台任务，须按任务卡配置纪律同步 module.json5 与 resources。

---

## 9. 提交状态说明

- 本单元代码**未做 git 提交**：按本单元指令，全部改动（21 项文件）留在工作区，待人工验收后由人执行提交，并按 Phase 纪律在 Phase 4 验收通过后打 `phase-4` tag。
- 口径差异明示：MIGRATION_PLAN §9-3 与 UNIT_CATALOG「提交与验收」节规定"AI 每单元完成即 git 提交（单元粒度回滚点）"；本单元按任务卡指令改为**人工验收后提交**，与计划的回滚点节奏存在偏差，特此记录供人工知悉（若需保持计划节奏，可在验收本报告后立即补一次单元粒度提交）。
- 源码目录 `resourses/xdm` 全程只读，本单元未做任何编辑/创建/删除。

---

*报告员依据：任务卡材料（研究结论/设计文档/实现清单/审查全史/独立复核/门禁结论）+ 本会话对 8 个源文件与 3 份文档的实测复核（§4 证据列、§5.6）。所有"通过"判定均注明执行主体；本报告员未复跑的项目（hvigor 构建、Hypium 测试、探针运行）已如实标注。*
