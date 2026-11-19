# U5.2 剪贴板监视+保存目录 · 单元交付报告

> 单元：U5.2 剪贴板监视+保存目录（Phase 5 收口，**M5 里程碑**）｜ bundle：com.example.xdmharmony ｜ API 24 / SDK 6.1.1(24)
> 报告日期：2026-10-02 ｜ 源码对照：resourses/xdm（XDM 2023，C#/.NET，GPL-2.0，只读）
> 配套文档：[设计书](./u5-2-clipboard-save-dir-DESIGN.md) ｜ [探针手册](../probe/PROBE-u5-2-clipboard-save-dir.md) ｜ [预期表](../probe/EXPECT-u5-2-clipboard-save-dir.json)
> **状态总览：hvigor 全量编译门禁通过；codelinter 辅助检查 0 Error；单测 257/257 全 Success（产物文件核实）；代码、设计书、探针手册、预期表全部落盘；对照审查 R4 轮 approved，独立复核 acceptable=true，遗留 6 low 见 §7；探针 P5-U2 待人工在模拟器/真机运行回贴。代码未做 git 提交（§9）。**
> 单元判定注记：本次工作流运行参数（args.unit/source/target）为空，单元 ID 按证据链判定为 U5.2——`docs/design/NIGHT-RUN.md:25`（`| 12 | U5.2 剪贴板+保存目录 | 🔄 运行中（dwfrun-a6d48356，M5 收口）`）+ 工作树状态（u5-2 设计书与本单元 21+ 文件已落盘未提交，§9 git 清单与设计书 §1 文件表逐项吻合）。

---

## ① 单元范围与验收要点

### 1.1 任务书范围（UNIT_CATALOG.md:72 逐字）

| 项 | 内容 |
|---|---|
| 单元 | **U5.2 剪贴板监视+保存目录**：pasteboard.on('update') 订阅 + 直链识别弹提示；DocumentViewPicker 选目录 + 写用户目录 |
| 源码对照 | `XDM.Core/ClipboardMonitor.cs`、`XDM.Core/IPlatformClipboardMonitor.cs` |
| 目标落点 | `core/clipboard/ClipboardWatcher.ets`（实际扩为 ClipboardWatcher + SaveDirectory + FolderAlgo + Index/对话框接线） |
| 验收标准 | 复制直链弹提示；文件落用户目录 |
| 前置 | U5.1（后台长时任务+通知）、U4.1（主窗口框架） |
| 验证 | [A] 静态/编译/单测 + [P] 探针/人工走查 |

### 1.2 验收要点对照（设计书 §5）

| 验收项 | 状态 | 证据 |
|---|---|---|
| [A] 编译门禁 | **通过** | hvigor 全量编译（devecocli build --modules entry）最终状态通过（§5.1） |
| [A] 事件面零破坏 | **通过（静态核对）** | 报告员本轮 `git status --porcelain` 核实：改动清单 15 改 + 8 新增（§9），**不含** Downloader.ets / DownloadManager.ets / ProgressNotifier.ets / Config.ets（红线四文件零改动）；resourses/ 零路径触碰 |
| [A] 纯逻辑单测 257 条全绿 | **通过（产物核实）** | 实现会话实跑 test 命令 exit=0（§5.3）；报告员读产物 `entry/.test/default/intermediates/test/coverage_data/test_result.txt` 尾行 `Tests run: 257, Failure: 0, Error: 0, Pass: 257, Ignore: 0`，`result=Success` 恰 257 条 |
| [P] P5-U2 探针 | **代码/手册/预期表已就绪，待人工运行回贴** | §6 |
| [P] 人工走查 10 项 | **待人工**（探针 S5 发射计数） | 手册 §5 清单：①弹窗预填 ②双锚不重弹 ③关闭后可再弹 ④自动开始 ⑤目录登记+完成拷贝 ⑥工具栏 Open ⑦Open folder 降级 ⑧删记录清理 ⑨isLive 门 ⑩刷新窗停止单发 |
| [P] 回归护栏（U5.1 不回退） | 静态面通过；运行时待探针 | U5.1 文件不在本轮改动清单（同上 git 核实）；P5-U1 探针结论不重跑（探针一次性原则） |

### 1.3 实现文件清单（实现会话回报 21 项 + 1 项返修追加，全部落盘核实）

改 15：`entry/src/main/module.json5`（:25 追加 READ_PASTEBOARD，报告员核实 2in1 :9 / INTERNET :16 在位）、`pages/Index.ets`、`entryability/EntryAbility.ets`、`core/db/StateStore.ets`、`components/NewDownloadDialog.ets`、`components/RefreshLinkDialog.ets`、`components/ProgressWindowDialog.ets`、`components/settings/GeneralSettingsTab.ets`、`probe/ProbeIndex.ets`、`probe/units/ProbeDialogs.ets`、resources 三目录 string.json、`entry/src/test/List.test.ets`（:46/:50 import + :68/:72 注册 batchAlgoTest/folderAlgoTest，报告员核实）、**`entry/src/test/BatchAlgo.test.ets`（COLD-F1 返修追加，超出设计书 §1 原表 21 项）**。
新 8：`core/clipboard/ClipboardWatcher.ets`、`core/fs/SaveDirectory.ets`、`core/util/FolderAlgo.ets`、`entry/src/test/FolderAlgo.test.ets`（16 用例）、`probe/units/ProbeClipboardSaveDir.ets`、`docs/probe/PROBE-u5-2-clipboard-save-dir.md`、`docs/probe/EXPECT-u5-2-clipboard-save-dir.json`、`docs/design/u5-2-clipboard-save-dir-DESIGN.md`（设计书本体）。
`main_pages.json` 零改动；`core/engine/**`、`model/**`、`core/Config.ets`、`core/net/**` 零改动（不在 git 改动清单）。

---

## ② 研究结论摘要（关键源码行为→ArkTS 对应表）

来源：研究员结论（任务材料），落点代码为本会话核实。

| # | 源码行为（对照锚） | ArkTS 对应（落点） | 风险 |
|---|---|---|---|
| 1 | `ClipboardMonitor.cs:40-70` 生命周期状态机：Start 幂等双守卫（isClipboardMonitorActive + 内部再查 Config.MonitorClipboard :45，默认 false）、Stop 非活跃即返；ConfigChanged 事件→MonitorClipboard?Start():Stop()（:25-38） | `ClipboardWatcher.ets` 应用级单例：active 双守卫逐条翻译；Config.onConfigChanged（app-lifetime 不 off）；on('update')/off('update') 传同一成员箭头引用；onUpdate→getData().then(clipboardChanged(getPrimaryText()))，catch 保持订阅计数不崩 | low |
| 2 | `ApplicationCore.cs:208-236` AddDownload：LinkAccepted 拦截位（U5.2 恒 false）；StartDownloadAutomatically=true→SanitizeFileName(GetFileName(url))+SingleSourceHTTPDownloadInfo 直启；否则 ShowNewDownloadDialog | `Index.onClipboardUrl` 读 Config.startDownloadAutomatically 分流：自动分支复用既有 startNewDownload(url, fileNameFromUrl(url), FileNameAndExtension)（D7 不建第二条构造链）；手动分支经 NewDownloadModel 预填对话框；LinkAccepted 留注释锚（D6） | low |
| 3 | 平台适配器契约（IPlatformClipboardMonitor.cs:9-18）：Win32=查看器链事件无载荷（消费端 GetClipboardText() 补读）；Gtk=1000ms 轮询。鸿蒙 on('update') 同为无载荷（UpdateCallback=()=>void）→同貌选 Win32 语义：事件后主动 getData() 补读；getData 需 READ_PASTEBOARD | `pasteboard.on('update')/off('update')` + `getData()` + `getPrimaryText()`；权限拒绝/读失败→保持订阅+lastReadOk=false+hilog，不崩不重弹（D9） | medium |
| 4 | `NewDownloadPromptTracker.cs:8-35` + `Application.cs:263-276`：per-URL 单实例门（static HashSet+lock）；PromptOpen 在 open 前登记、destroyCallback 恰一次摘除 | Index 模块级 `Set<string>`（ArkTS 主线程事件循环天然串行替代 lock）；登记在对话框 open 前，摘除挂 aboutToDisappear 统一 onClosed；自动分支不登记（源无此门）。审查追加 D17 排队串行重放（§4） | low |
| 5 | `Helpers.cs:45-61` IsUriValid：scheme 小写比较仅 http/https，catch→false | 直接复用既有 `core/net/HttpProtocol.ets:159` isUriValid，不新写；过滤链第二环与 New 菜单预填校验共用 | low |
| 6 | `Helpers.cs:311-341` UpdateRecentFolderList（空串不动/头插/已在表不前移+恒置 Manual+SaveConfig）/GetManualDownloadFolder（非 Manual→null；userSelected 在表→它，否则 [0]；空表→Default） | `FolderAlgo.updateRecentFolderList/manualDownloadFolder` 纯函数 1:1（FOLDER_MODE_AUTO=0/MANUAL=1 对应 Config.cs:505-511 枚举）；`SaveDirectory.applyPickedFolder` 落 Config 三键（recentFolders/folderSelectionMode/userSelectedDownloadFolder，键全在位零新增） | low |
| 7 | `NewDownloadDialogUIController.cs:14-68` + `Application.cs:180-188`：DestroyEvent 先挂回调（任何关闭路径恰一次）；Url/SelectedFileName 预填（Message.File??GetFileName(url)）；SetFileSizeText 恒 '---'（Message 无 ResponseHeaders）；无 message 时 GetUrlFromClipboard（IsUriValid 门）预填 | `NewDownloadModel{initialUrl}` 共享对象+aboutToAppear 预填三写（url/derivedName/fileName，不置 fileNameTouched）+一次性消费；onClosed=aboutToDisappear 发射；SetFileSizeText 不实装（D5）；New 菜单走 openNewDownloadFromClipboard（D18） | low |
| 8 | `ApplicationCore.cs:691-798` RemoveDownload + `UIActions.cs:19-46`：state 文件+tempDir **无论 deleteFiles 真假都删**；成品仅 `entry is FinishedDownloadItem && deleteDownloadedFile` 才删；全程 try/catch 吞 | `StateStore.removeById(baseTempDir,id)` 目录级删除（tempDir/&lt;id&gt;/ 含 chunks 三工件+分片=源 RemoveStateFiles+Directory.Delete 双步等价归并，listFileSync+逐文件 unlinkSync+rmdirSync 全吞错）；Index.removeRecords 在 store.remove 成功分支消费；成品删除门 `record.kind===Finished && deleteFiles` | medium |
| 9 | `FileHelper.cs:23-41` GetDownloadFolderByFileName（ext 带点大写匹配 Categories.FileExtensions→DefaultFolder，未命中回退）+ :88-118 GetFileName（LocalPath 取名，空→Host.Replace('.','_')，再 Sanitize） | `FolderAlgo.downloadFolderByFileName` 纯函数（末个'.'起取扩展名 toUpperCase 带点；命中 CategoryDef.fileExtensions→downloadDir+'/'+defaultFolderName 尾段拼接）；自动分支文件名用既有 fileNameFromUrl+Sanitize 等价链 | low |
| 10 | `UIActions.cs:76-120`（无选中→NO_ITEM_SELECTED；打开失败→ERR_MSG_FILE_NOT_FOUND_MSG，English.txt:166-167）+ LinkRefreshWindow.xaml.cs:65-72（BtnStop→Close→Window_Closing→WatchingStopped 恰一次） | `handleOpenAction` 两工具栏钮接线：两文案 string.json 逐字收录（base/zh_CN/en_US）；打开走 SaveDirectory.openFile（filePreview.openPreview 仅收 uri）；失败/无选中 toast 同文案；RefreshLinkDialog stoppedSent 幂等守卫+aboutToDisappear 兜底 | low |

---

## ③ 设计决策与有意差异

**计划条款引用**：MIGRATION_PLAN **§6 决策 10**（存储——Config 键全在位零新增、preferences 零新键、downloads 表 22 列不动）；**§6 决策 11**（UI——Navigation/NavDestination、CustomDialog/bindSheet、文案走 resources 三语言）；**§6 决策 2**（线程模型——本单元投影为零 TaskPool，pasteboard/Picker/fileIo 异步全在主线程事件循环消费，设计书 §3.6 映射表）；**§7 Phase 5**（ClipboardWatcher on('update') + DocumentViewPicker 保存目录=本单元承载，验收"复制直链弹提示；文件入用户目录"）；**§8 验证矩阵**（hvigor 编译期 ArkTS 严格子集为主、codelinter 辅助）。设计书 §0 拍板①-⑬（①双轨目录授权生命周期 ②OpenFolder 降级 ③过滤链 1:1 ④权限面 ⑤复用 startNewDownload ⑥per-URL 单实例集 ⑦共享对象预填 ⑧删记录盘上清理挂 store.remove 成功分支 ⑨顺手收口四接线点 ⑩Browse 只接 downloadDir ⑪事件面零破坏红线 ⑫纯逻辑拆分 FolderAlgo ⑬线程模型）。

| # | 差异 | 依据 |
|---|---|---|
| D1 | 双轨目录：引擎落盘恒沙箱 downloadDir（record.targetDir 不变），用户目录 URI 仅作完成后 fileIo.copy 目标——源=直接下载进所选目录（Picker 临时授权生命周期+引擎零接触红线） | 拍板① |
| D2 | 不做 persistPermission/FILE_ACCESS_PERSIST（受限开放权限课程工程不可申请）；重启后需重选目录，拷贝失败回退沙箱+toast 不丢文件 | 拍板① |
| D3 | OpenFolder 降级=openPreview 同路+hilog 差异登记（鸿蒙无"文件管理器定位到目录"公开 API） | 拍板② |
| D4 | 设置页 Browse 驱动 recentFolders 三键（拷贝目标链），不回填 downloadDir TextInput（防 URI 写入引擎目标键破坏落盘） | 拍板⑩ |
| D5 | 新建对话框无目录下拉；saveDir 展示 Manual→拷贝目标 URI / Auto→沙箱目录；SetFileSizeText('---') 不实装（剪贴板 Message 无 Content-Length 恒 '---'，信息量为零） | 拍板⑦ |
| D6 | LinkRefresher.LinkAccepted 拦截位=注释锚不建死代码（U5.2 恒 false，U6.x 桥接时在 onClipboardUrl 入口补判） | 源 ApplicationCore.cs:209 |
| D7 | 自动开始路径复用既有 startNewDownload 工厂链（工厂+store.add+admitNew），不构造 SingleSourceHTTPDownloadInfo 直启链 | 拍板⑤ |
| D8 | temp/category 两处 Browse 维持占位（URI 不能作沙箱 tempDir/分类尾段目录，语义不兼容） | 拍板⑩ |
| D9 | READ_PASTEBOARD 运行期一次申请（permissionRequested 会话守卫）；拒绝后保持订阅只记日志不重弹（监视链空转）——鸿蒙特有，WPF 无权限概念 | 拍板④ |
| D10 | per-URL 单实例集=Index 模块级 Set&lt;string&gt;（源 static HashSet+lock，ArkTS 主线程事件循环天然串行）；对话框关闭统一走 aboutToDisappear 回调（源 DestroyEvent 事件语义同构） | 拍板⑥ |
| D11 | 完成窗 Open/Open folder 失败仅 hilog（源 DownloadComplete 窗同貌）；工具栏 Open 失败弹 msg_file_not_found（UIActions:88/:108 1:1） | §3.4 |
| D12 | handleStarted modelOf 块内追加 speedText/etaText 复位（ResumeDownload:305-321 重开窗复位锚） | 拍板⑨② |
| D13 | 剪贴板 Message 的 File=null/Headers 空/Cookies null 由 newDownloadRecord 工厂自然承载（源 :212-217 只填 Uri/File 两项的等价投影） | 源 Message.cs:11-27 |
| D14 | 探针写入轨 setData 无需权限；人工复制轨与程序写入轨分 S3/S2 两步（探针专用轨道，源无对应物） | §6 |
| D15 | INT-F8（Config proxy 回退两处）继续登记不实现——HttpClient 不读 proxy，Config.Instance.Proxy 传参在目标侧无消费方（U6.x 接线时一并处理） | 拍板⑨④ |
| D16 | 新增资源键 msg_copy_failed/msg_folder_picked/clipboard_permission_reason 为自拟登记（鸿蒙拷贝链/toast/权限 reason 平台新增面）；msg_file_not_found/no_item_selected 取 English.txt:166-167 逐字 | §1-#5 |
| D17 | 提示对话框串行化（R2-F2 审查修复）：提示对话框在开时命中新 URL 入队 promptQueue，对话框关闭回调查队列逐个延迟重开——源=每 URL 各自弹窗并行，目标 CustomDialogController 单实例无法并行多窗 | R2-F2 修复 |
| D18 | New 菜单预填权限面（R2-F3/R3-F1 审查修复）：openNewDownloadFromClipboard 在 getData 前经 ClipboardWatcher.requestReadPermission()（公开入口，与 watcher.start 共用会话级一次守卫）显式申请——用户主动点菜单=标准申请时机；拒绝/读失败静默保持空白打开 | R2-F3/R3-F1 修复 |
| D19 | 完成拷贝 dest=目录 URI（COLD-F2/COLD-F3 审查修复）：syncFinishedFile 改 fileIo.copy(srcUri, target)——destUri 传目录 URI 为 @ohos.file.fs.d.ts:895-903 文档语义（"destination file or directory"），平台负责落名与百分号编码，替代 `<folderUri>/<文件名>` 裸拼（文件名含空格/#/?/% 时 URI 解析破坏→拷贝整链必失败）；requestReadPermission catch 分支守卫复位（错误路径下 New 菜单显式入口仍可达） | COLD-F2/F3 修复 |

---

## ④ 审查问题处置表（覆盖全部轮次）

轮次链：R2 对照审查（**approved=false**，6 findings）→ 修复 R2-F1/F2/F3 → R3 对照审查（**approved=false**，6 findings，3 新 + 3 前轮遗留）→ 修复 R3-F1 → R4 对照审查（**approved=true**，5 findings 全为前轮遗留 low，无新发现）→ 冷启动返修 COLD-F1/F2/F3 → 独立复核（**acceptable=true**，6 findings：5 前轮遗留 + 1 新发现 low）。

**已修复（7 项，与实现会话回报的已修复编号一致）：**

| 编号 | 轮次 | 严重度 | 问题摘要 | 处置 | 证据（报告员本轮核实的落点） |
|---|---|---|---|---|---|
| R2-F1 | R2 | **high** | 成品删除门 record.kind===Finished 本会话内恒 false：kind 只在 DB 装载时映射（RecordMapping.ets:104），markAsFinished 只写库不改内存对象，handleFinished 只置 status 不置 kind——本会话完成的记录当场勾"删文件"删除时盘上成品永不删，违背拍板⑧核心语义 | 修复：handleFinished 的 if(record!==null) 块内尾部追加 `record.kind = DownloadKind.Finished`（既有写序不动） | ✅ `pages/Index.ets:692`（块内尾部，含 R2-F1 注释锚）；kind 门消费点 `Index.ets:963-964`（removeRecords 成品删除门） |
| R2-F2 | R2 | medium | per-URL 单实例集实现为"单对话框+单 pendingPromptUrl 快照"，并发第二 URL 时快照被覆盖、A 永久残留 openPrompts（本会话内不再弹）——源为每 URL 各自弹窗各自摘除、无此泄漏 | 修复：D17 排队串行重放——提示对话框在开时新 URL 入 promptQueue，关闭回调摘除后逐个重开（登记入设计书差异清单） | ✅ `Index.ets:193`（promptQueue 声明）、`:484-490`（pendingPromptUrl 非空入队，含 R2-F2 注释）、`:498-508`（关闭回调摘除+出队重放） |
| R2-F3 | R2 | medium | 源"新建下载"按钮走剪贴板预填分支（GetUrlFromClipboard 带 IsUriValid 门，研究结论明确列为复刻行为），目标侧 New 菜单打开空白对话框且未登记裁剪 | 修复：D18 New 菜单接 openNewDownloadFromClipboard（isUriValid 门预填） | ✅ `Index.ets:524-545`（openNewDownloadFromClipboard 全文）、`:1085-1086`（New 菜单 action 调用点） |
| R3-F1 | R3 | medium | R2-F3 修复引入新偏差：READ_PASTEBOARD 唯一申请点在 watcher.start（需 monitorClipboard=true），默认 false 时 New 菜单 getData 恒 201、预填永久失效且无提示——降级仅写在代码注释未登记设计书 | 修复：openNewDownloadFromClipboard 在 getData 前先经 ClipboardWatcher.requestReadPermission()（公开入口+会话级一次守卫）；申请终态后再读 | ✅ `Index.ets:525`（.then 链先申请后 getData）；`ClipboardWatcher.ets:188-224`（requestReadPermission 公开入口，:191-194 守卫） |
| COLD-F1 | 实现轮 | —（测试面） | BatchAlgo.test.ets 8 处 `expect(links).assertNotNull()`——hypium 1.0.25 Assert 面无 assertNotNull，首次真实执行即失败；连带暴露坏用例 preview_singleLink_secondLastEmpty（letterParams('A','A') 在源 startChar>=endChar 门下恒 []，期望单链为不可能输入） | 修复：8 处改谓词等价断言 `expect(links === null).assertEqual(false)`（PieceAlgo.test.ets:372 同款）；坏用例改为直构单链数组验 computeBatchPreview 纯聚合语义（生成器与源 1:1 无误，属测试侧错误） | ✅ `BatchAlgo.test.ets` grep 核实：assertNotNull 仅存于 8 行注释（:68/:100/:110/:125/:135/:148/:164/:184，均"COLD-F1"注记），零实际调用；257 条全绿含修复后用例（§5.3） |
| COLD-F2 | 实现轮 | —（运行时正确性） | syncFinishedFile dest 为未编码 basename 裸拼 `<folderUri>/<文件名>`——文件名含空格/#/?/% 时 URI 解析破坏，拷贝整链必失败 | 修复：改 `fileIo.copy(srcUri, target)`——destUri 传目录 URI（d.ts:895-903 文档语义，平台负责落名与百分号编码）；移除无引用的 baseNameOf，登记 D19 | ✅ `core/fs/SaveDirectory.ets:155`（`return fileIo.copy(srcUri, target).then(...)`）、:142-143 注释同步 |
| COLD-F3 | 实现轮 | —（可用性） | requestReadPermission catch 分支不复位守卫——onCreate 早期申请若因窗口未就绪等报错，permissionRequested 恒 true，D18 的 New 菜单显式入口永不可达（审查提出 syncFromConfig 移 onWindowStageCreate 未采纳：非强制且守卫复位已自愈） | 修复：catch 分支补 `permissionRequested = false`（仅错误路径复位；用户拒绝路径 flag 保持 true 不变，不造成重弹循环） | ✅ `ClipboardWatcher.ets:219`（catch 内复位，含 COLD-F3 注释块 :218-220） |

**未修遗留（复核轮确认维持原状，均 low，明细见 §7）：** R2-F4/R3-F4/R4-F3/复核-F3（handleOpenAction 空目标弹窗文案落点）、R2-F5/R3-F5/R4-F4/复核-F4（探针"恰 9 行"注释 vs 权威表 8 行）、R2-F6/R3-F6/R4-F5/复核-F5（FolderAlgo 末位点理论差异）、R3-F2/R4-F1/复核-F1（D17 守卫单方向）、R3-F3/R4-F2/复核-F2（走查③文案与源矛盾）、复核-F6 新发现（探针 S1 永久置 monitorClipboard=true 不恢复）。

---

## ⑤ 验证情况

### 5.1 hvigor 编译门禁

**通过**。据本单元工作流主会话门禁结论（任务材料）：hvigor 全量编译（`devecocli build --modules entry`）最终状态通过。报告员本轮未重跑构建——门禁结论取自主会话门禁日志，代码此后仅经 COLD 返修且返修后实现会话复跑 test 命令（含全量编译，exit=0，§5.3），无构建面回退证据。

### 5.2 codelinter 辅助检查（提示性）

**exit 0，0 Error**。据主会话门禁日志（任务材料）：`Summary: Issues: 19 | Errors: 0 | Warnings: 17 | Suggestions: 2 | Files checked: 5`。其中 2 条 WARN 为既有 on/off 'Function may throw exceptions'（非本单元清单项，不阻断，保持最小改动未处理）；Suggestions 为 @performance/hp-arkui-set-cache-count-for-lazyforeach-grid 类性能提示（Index.ets 等 5 文件）。codelinter 实测不含 ArkTS 语法规则（MIGRATION_PLAN §8 已登记），仅作辅助。

### 5.3 单元测试（257 条）

实现会话按任务书指定命令实跑：`DEVECO_SDK_HOME=... node hvigorw.js --mode module -p module=entry@default test`——**exit=0、无 COMPILE RESULT:FAIL**（任务材料）。报告员本轮核实产物文件 `entry/.test/default/intermediates/test/coverage_data/test_result.txt`：
- 尾行汇总：`Tests run: 257, Failure: 0, Error: 0, Pass: 257, Ignore: 0`；
- `result=Success` 行恰 **257** 条（grep 计数），无其它 result 值；
- 注册面：`List.test.ets:46/:50`（batchAlgoTest/folderAlgoTest import）+ `:68/:72`（注册调用）。

验收口径"[A] 257 条全绿"（设计书 §5：FolderAlgo 新 16 条 + 既有 241 条）**达成**。

### 5.4 对照审查与独立复核结论

- **R2 对照审查：approved=false**（6 findings：1 high + 2 medium + 3 low）→ 修复 R2-F1/F2/F3；
- **R3 对照审查：approved=false**（6 findings：1 medium 新 + 5 low 维持）→ 修复 R3-F1；
- **R4 对照审查：approved=true**（5 findings 全为前轮遗留 low，无新发现）；
- **独立复核：acceptable=true**（6 findings：5 前轮遗留 low + 1 新发现 low；weakestSpot=完成拷贝链运行时未实测，§6/§7）。

### 5.5 ArkTS 合规说明

ArkTS 严格子集由 **hvigor 编译期强制**（MIGRATION_PLAN §8 验证矩阵；codelinter 实测不含 ArkTS 语法规则，不依赖 lint 抓语法）——编译门禁通过即合规。本单元高危点在设计书 §5-[A] 预列并随编译通过验证：`picker.DocumentSelectOptions`/`filePreview.PreviewInfo` 对象字面量显式类型（arkts-no-untyped-obj-literals）、on/off('update') 回调同一成员引用、`(ctx as common.UIAbilityContext)` downcast 在 undefined 窄化之后、模块级 `new Set<string>()` 泛型显式。

### 5.6 代码证据抽查（报告员本轮执行，汇总）

本轮运行的核查命令与结论：`grep Index.ets`（R2-F1 落点 :692、kind 门 :963、D17 队列 :150/:189/:193/:484-508）、`sed Index.ets:518-545`（R3-F1 openNewDownloadFromClipboard 全文）、`sed Index.ets:680-700`（handleFinished 块内尾部置位）、`grep SaveDirectory.ets`（COLD-F2 fileIo.copy(srcUri, target) :155）、`sed ClipboardWatcher.ets:180-225`（COLD-F3 catch 复位 :219、requestReadPermission 公开入口 :188）、`grep -n assertNotNull BatchAlgo.test.ets`（8 处全为注释）、`grep module.json5`（2in1 :9 / INTERNET :16 / READ_PASTEBOARD :25）、`grep StateStore.ets`（static removeById :122）、读 `test_result.txt`（257/257）、`git status --porcelain`（§9 清单）、`grep 恰 [89] 行`（口径不一致三处仍在，§7-L4）、读 `NIGHT-RUN.md:25`（dwfrun-a6d48356）与 `UNIT_CATALOG.md:72`（U5.2 行）。

---

## ⑥ 运行时验证待办（探针）

**本单元有探针**：P5-U2（ProbeClipboardSaveDir.ets），已生成并落盘：
- 探针手册：`docs/probe/PROBE-u5-2-clipboard-save-dir.md`（运行次序/权限弹窗指引/人工复制轨指引/走查清单 10 项/抓取命令）；
- 预期表：`docs/probe/EXPECT-u5-2-clipboard-save-dir.json`（**权威判定口径**，四会话模型）。

**运行指引**（据手册与预期表 sessions 字段）：
1. **运行次序**：主会话（探针页"运行全部"：S1/S2 autoRun 真观测，S3/S4/S5 发占位行，恰 8 行 BEGIN+S1+S2+S3+S4+S5+SUMMARY+END）→ S3 单步（先在浏览器/备忘录人工复制 http(s) 直链，回探针页执行）→ S4 单步（弹目录 picker 人工选/取消）→ 正常应用模式人工走查 10 项 → S5 单步发射计数；
2. **权限弹窗**：首次运行 S1 弹 READ_PASTEBOARD 授权框（requestPermissionsFromUser fire-and-forget，点允许；拒绝后 getData 201、监视链空转不重弹=D9）；S2 程序写入轨 setData 无需权限（D14）；
3. **判定**：人工回贴日志后走 `xdm-probe-verify` 工作流对照 EXPECT 表逐步骤判定分流；S1/S2 判定取主会话，S3/S4/S5 取各自单步会话末次 runId；重跑残留注记（同会话二次"运行全部" S2 detectDelta=0 属去重锚重跑伪影）见预期表 sessions 字段；
4. **优先观测点**（独立复核 weakestSpot，首跑模拟器应优先打）：①完成拷贝链"文件 src→目录 dest 跨授权域拷贝"（SaveDirectory.ets:155 按 d.ts 文档语义传目录 URI，契约正确但**从未在模拟器/真机执行过**）——对应探针 S4/S5 走查⑤；②EntryAbility.onCreate 早期权限申请（syncFromConfig→start）的系统弹窗行为（COLD-F3 守卫复位可自愈错误路径，但 onCreate 弹授权框属模拟器观测范围）。

---

## ⑦ 遗留问题与风险

全部遗留为 **low**，独立复核已判 acceptable=true，不阻塞本单元交付；处置决定（修 or 正式登记进设计书）建议在 M5 人工验收前拍板：

| 编号 | 严重度 | 问题 | 建议处置 |
|---|---|---|---|
| L1（复核-F1/R4-F1/R3-F2） | low | D17 排队守卫只覆盖"提示对话框在开"方向：手动 New 对话框在开时剪贴板命中 URL 走直通分支→open() 对已在开对话框无效→提示被静默吞掉，且 lastClipboardText 已置为该 url（紧接着重复制同 URL 也被过滤）。无状态泄漏（关闭回调摘登记），有界差异 | 守卫面扩为"任一对话框在开"入队串行重放，或设计书 D17 补登记该方向降级 |
| L2（复核-F2/R4-F2/R3-F3） | low | 走查项③"关掉对话框后再复制同 URL 能再次弹"与源矛盾——源 ClipboardMonitor.cs:65-69 的 lastClipboardText 锚在 PromptClosed 时不清除，关对话框后重复制同 URL 在源码上同样被过滤；按字面执行会把正确实现误判为缺陷 | 三处文案（PROBE 手册 :111、ProbeClipboardSaveDir.ets、设计书）改为"关掉对话框→复制任意**其它**文本→再复制原 URL 能再次弹" |
| L3（复核-F3/R4-F3/R2-F4） | low | handleOpenAction：record 非 null 但 targetDir/name 为空时弹 msg_file_not_found；源 OpenSelectedFile 空目标分支仅 Log.Debug 后落到末行 NO_ITEM_SELECTED（UIActions.cs:110-115），ERR 文案仅在 OpenFile 返回 false 时弹。成品行实际恒非空，影响面极小 | 该分支改弹 no_item_selected 与源落点一致，或设计书登记归一化差异 |
| L4（复核-F4/R4-F4/R2-F5） | low | 探针注释与设计书写"恰 9 行"，权威期望表写"恰 8 行"（实际 BEGIN+5 步+SUMMARY+END=8 行）。报告员本轮 grep 核实：EXPECT json:4 为"恰 8 行"（正确），DESIGN.md:254 与 ProbeClipboardSaveDir.ets:4/:204 仍"恰 9 行"——口径不一致易误导人工核对 | 三处"恰 9 行"改"恰 8 行"（docs/注释级，零编译风险）；**人工核对探针行数时以 EXPECT json 为准** |
| L5（复核-F5/R4-F5/R2-F6） | low | FolderAlgo.downloadFolderByFileName：fileName 末位是'.'（如 'file.'）时实现取 ext='.'，.NET Path.GetExtension 返回空串——仅当类别表含 '.' 键才分叉，现网 DEFAULT_CATEGORIES 无此键，两端实际都回退 downloadDir；实现与设计书"下标>0"口径一致 | 可选加 `dot < fileName.length - 1` 门；否则登记为理论差异维持现状 |
| L6（复核-F6，新发现） | low | 探针 S1 把真实用户设置 monitorClipboard 置 true 且全程不恢复（writeBoolean 即持久化）——跑一次探针即永久翻转用户可见设置，并使后续冷启动自动订阅；设计书 §6 S1 措辞"恢复快照前保持 true"与实现不一致未登记 | 主会话 END（S2 之后）恢复 cfgBefore 快照，或把"S1 永久置 true"作为探针副作用在设计书 §6 显式登记 |

**其它风险登记：**
- **R-1（运行时未实测，中关注）**：完成拷贝链 fileIo.copy(srcUri→目录 URI) 与 onCreate 早期权限申请均未在模拟器/真机执行（两轮审查无模拟器会话，此项 not run）——探针 S4/S5 首跑即验，见 §6-4；
- **R-2（D15/INT-F8 延期项）**：Config proxy 回退两处继续登记不实现（HttpClient 不读 proxy，目标侧无消费方），U6.x HttpClient 接线时一并处理；
- **R-3（codelinter 余量）**：2 条 WARN（on/off 'Function may throw exceptions'）+2 条 Suggestion（LazyForEach cachedCount 类）非本单元清单项，维持不处理；
- **R-4（许可）**：XDM 为 GPL-2.0，对照重写属衍生作品，分发须遵循 GPL-2.0（MIGRATION_PLAN §11）——交付报告需声明。

---

## ⑧ 对下个单元的建议

1. **运行参数丢失核对（来自研究员 openQuestions，高优先）**：本次运行 args.unit/source/target 全为空（脚本取 args ?? '' 的行为），靠证据链判定 U5.2。主会话应核对 amend/续跑链路是否丢参，避免下一单元再次靠 NIGHT-RUN.md/工作树反推单元 ID；下游各阶段务必复用既有 `u5-2-clipboard-save-dir-DESIGN.md`，勿产出第二份设计书、勿对已落盘文件重复编码。
2. **下一单元按敏捷计划为 U0.3 桥服务**（NIGHT-RUN.md 推进注记："U0.3 桥服务按敏捷计划仍在 U6.1 前"），随后 U6.1~U6.3 浏览器集成。U6.x 桥接时收口本单元预埋的两个锚：①D6——LinkRefresher.LinkAccepted 拦截位在 `Index.ets` onClipboardUrl 入口补判（注释锚在位）；②D15——Config proxy 传参在 HttpClient 接线时一并消费。
3. **探针清账**：P5-U1（U5.1）与 P5-U2（本单元）两份探针均待人工模拟器/真机运行回贴；建议下个单元的模拟器会话一并执行回贴（首跑优先打本单元 §6-4 两个观测点），由 xdm-probe-verify 判定后分流返修。
4. **遗留 low 清账**：§7 六项在 M5 人工验收前拍板——修（L2/L4 为纯文案零风险）或正式登记进设计书差异清单（L1/L3/L5/L6）；不要无登记静默带过。
5. **git 收口**：本单元未提交（§9）；M5 人工验收通过后提交并打 `phase-5` tag（NIGHT-RUN.md 的 M5 收口行同步更新）。

---

## ⑨ git 状态说明

**代码未做 git 提交**——待人工验收后由人提交并按 Phase 打 tag。报告员本轮 `git status --porcelain` 核实（工作树状态，全部位于 XdmHarmony/ 内）：

- 改 15：`entry/src/main/module.json5`、`pages/Index.ets`、`entryability/EntryAbility.ets`、`core/db/StateStore.ets`、`components/NewDownloadDialog.ets`、`components/RefreshLinkDialog.ets`、`components/ProgressWindowDialog.ets`、`components/settings/GeneralSettingsTab.ets`、`probe/ProbeIndex.ets`、`probe/units/ProbeDialogs.ets`、`resources/{base,zh_CN,en_US}/element/string.json`、`entry/src/test/List.test.ets`、`entry/src/test/BatchAlgo.test.ets`；
- 新 8（untracked）：`core/clipboard/`（ClipboardWatcher.ets）、`core/fs/`（SaveDirectory.ets）、`core/util/FolderAlgo.ets`、`probe/units/ProbeClipboardSaveDir.ets`、`entry/src/test/FolderAlgo.test.ets`、`docs/design/u5-2-clipboard-save-dir-DESIGN.md`、`docs/probe/PROBE-u5-2-clipboard-save-dir.md`、`docs/probe/EXPECT-u5-2-clipboard-save-dir.json`；
- **红线核验**：改动清单不含 `core/engine/**`、`model/**`、`core/Config.ets`、`core/net/**`、`main_pages.json`（事件面零破坏红线的静态证据）；**只读约束核验**：resourses/ 下零文件被改动、创建或删除。

建议提交粒度：单元粒度单 commit（迁移计划 §9-3），随 Phase 5 收口在人工验收通过后由人执行并 `git tag phase-5`（回滚点语义见迁移计划 §10）。
