# U5.2 剪贴板监视 + 保存目录 · 模块设计书

> 单元：U5.2 剪贴板监视+保存目录（Phase 5 收口，M5 里程碑）。前置：U5.1（onPrepareToTerminate/ProgressNotifier 刚落地勿回退）、U4.1（工具栏 Open/OpenFolder 状态机渲染在位）、U4.3（设置页 downloadDir 输入与 monitorClipboard 键）。
> 配套：[MIGRATION_PLAN](../../MIGRATION_PLAN.md) §5 结构（core/clipboard/ClipboardWatcher.ets 预留位）、§6 决策 10/11、§7 Phase 5、[UNIT_CATALOG](../../UNIT_CATALOG.md) U5.2 行、[PROBE_SPEC](../../PROBE_SPEC.md)。
> 源码锚（本会话逐一读过核实）：`XDM.Core/ClipboardMonitor.cs:25-74`（监视生命周期+三重过滤链全文）、`XDM.Core/Util/Helpers.cs:45-61`（IsUriValid 仅 http/https）、`Helpers.cs:311-341`（UpdateRecentFolderList/GetManualDownloadFolder）、`XDM.Core/Util/FileHelper.cs:23-41`（GetDownloadFolderByFileName 带点大写扩展名匹配）、`XDM.Core/ApplicationCore.cs:208-236`（AddDownload 分流）、`ApplicationCore.cs:691-703/:725-798`（RemoveDownload 逐文件删 state+Directory.Delete(tempDir,true)）、`XDM.Core/NewDownloadPromptTracker.cs:10-35`（HashSet+lock per-URL 单实例）、`XDM.Core/Application.cs:180-188`（GetUrlFromClipboard）/`:263-276`（ShowNewDownloadDialog 预填链）、`XDM.Core/UI/NewDownloadDialogUIController.cs:14-68`（DestroyEvent 回调+Url 预填）、`XDM.Core/UIActions.cs:19-55`（DeleteDownloads 先停后删）/`:76-120`（OpenSelectedFile/OpenSelectedFolder 失败弹 ERR_MSG_FILE_NOT_FOUND_MSG）、`XDM.Wpf.UI/Dialogs/RefreshLink/LinkRefreshWindow.xaml.cs:65-72`（BtnStop→Close→Window_Closing→WatchingStopped 恰一次）、`XDM.Core/IPlatformClipboardMonitor.cs`（四成员契约）、`Lang/English.txt:166-167`（ERR_MSG_FILE_NOT_FOUND_MSG/NO_ITEM_SELECTED 逐字）。
> 目标侧现状（本会话读过核实）：`module.json5`（requestPermissions 仅 INTERNET/KEEP_BACKGROUND_RUNNING/PREPARE_APP_TERMINATE；deviceTypes 已含 2in1）、`core/Config.ets`（monitorClipboard/recentFolders/folderSelectionMode/userSelectedDownloadFolder/startDownloadAutomatically 全键在位 :107/:99-102/:138/:99，onConfigChanged/offConfigChanged/broadcastConfigChange 在位 :465-542）、`pages/Index.ets`（onOpenPlaceholder 占位 :836-840、removeRecords 差异 #6 登记 :804-834、onShowProgressMenu 无 isLive 门 :1007-1015、refreshLinkController builder 挂 onOpenReferer :226-239、五 handler 尾部转发惯例 :455-584）、`core/db/StateStore.ets`（chunks.json 双槽+staging 三工件，无 per-id 清理）、`core/engine/DownloadManager.ets`（isLive :239 在位）、`components/NewDownloadDialog.ets`（@State url='' :32，无预填入参）、`components/RefreshLinkDialog.ets`（onOpenReferer 死 prop :35-36、handleStop 无守卫 :39-42）、`components/settings/GeneralSettingsTab.ets`（download Browse 占位 :329-332/:428）、`components/ProgressWindowDialog.ets`（openCompleted 的 Open/Open folder 占位 actions :409-417）、`probe/units/ProbeDialogs.ets`（S2 局部 listener 异常路径不卸载 :334-345，aboutToDisappear 无 off :141-147）、`probe/ProbeIndex.ets`（P0-U0…P5-U1 共 12 单元）、单测 20 文件 **241 条 it**（本会话 grep 计数核实，与任务书验收口径一致）。
> API 证据（本会话 SDK d.ts 逐一读过核实）：`@ohos.pasteboard.d.ts`（on('update') :1737 / off('update') :1768 / getData :2235 / createData :289 / getPrimaryText :1214）、`@ohos.file.picker.d.ts`（DocumentSelectMode.FOLDER=1 :466 / selectMode :670 / maxSelectNumber :653 / DocumentViewPicker ctor(context) :860 / select→Promise<Array<string>> :924）、`@ohos.file.fs.d.ts`（copy(srcUri,destUri,options?) :895 / accessSync :653 / listFileSync :3476 / unlinkSync :7658 / rmdirSync :6786——**非递归，13900032 Directory not empty**）、`@ohos.file.fileuri.d.ts`（getUriFromPath :162）、`@hms.filemanagement.filepreview.d.ts`（openPreview(context,file:PreviewInfo,info?) :30，单文件变体 since 11；kit 导出=`@kit.PreviewKit`，`@kit.PreviewKit.d.ts:9-11` 本会话核实）、`@ohos.abilityAccessCtrl.d.ts`（requestPermissionsFromUser :292）。

---

## 0. 冲突与拍板注记（必读）

1. **拍板①（openQuestion 1）：用户目录授权生命周期=临时授权+完成后拷贝，不做持久化**。Picker 临时授权应用退出/设备重启即失效（研究结论 faqs-share-12 核实）；持久化需 `fileShare.persistPermission`+受限开放权限 `ohos.permission.FILE_ACCESS_PERSIST`（课程工程申请不可行）。**拍板**：downloadDir 默认保持沙箱 `<filesDir>/Downloads` 现状；DocumentViewPicker 选中目录 URI 按 UpdateRecentFolderList 数学存入 recentFolders/userSelectedDownloadFolder/folderSelectionMode=Manual 三键（Config.ets 键全在位零新增）；**引擎落盘目标恒沙箱 downloadDir（record.targetDir 不变——引擎/Downloader/PieceGrabber 零接触）**，下载完成后经 `fileIo.copy(fileUri.getUriFromPath(沙箱成品), <folderUri>/<文件名>)` 拷入用户目录；拷贝失败（授权失效/重启后）→ 文件留在沙箱+hilog+toast 提示重选，绝不静默丢文件、绝不先删成品再拷贝。降级"重启后需重选目录"登记 §4。
2. **拍板②（openQuestion 2）：OpenFolder 降级=openPreview 同路**。鸿蒙无公开"文件管理器定位到目录"API。拍板：`openFolder` 动作对选中文件走与 openFile 相同的 `filePreview.openPreview` 路径（优于纯 toast：用户至少看到文件），hilog 登记 `action=openFolder downgraded` 差异；**不可留占位不接线**（本单元验收要求）。多文件变体 openPreview(files[]) 在 2in1 返回 801 禁用（研究结论 preview-arkts:202），故恒用单文件变体。
3. **拍板③：剪贴板识别只处理用户复制的直链，过滤链逐条 1:1**。与 U6.x 浏览器扩展嗅探的分工=扩展流量过滤规则（VideoUrlHelper/blockedHosts）不在本单元；ClipboardWatcher 的排除项**只有源码 ClipboardMonitor.cs:66-71 三重过滤链**：非空 && `isUriValid`（scheme 小写比较仅 http/https，复用 `core/net/HttpProtocol.ets:159` 既有实现——ftp/file/magnet/纯文本/浏览器自身 URL 全拒）&& `text !== lastClipboardText`。**无效文本不更新 lastClipboardText**（源码同貌：重复复制同一 URL 只在首次弹）。监视生命周期幂等双守卫（`isClipboardMonitorActive` :47-48/:56-57 + Start 内部再查 MonitorClipboard :49）逐条翻译；Config 响应走 `Config.onConfigChanged`（设置页 Save 收尾一次广播，Settings.ets:55 本会话核实——ApplicationContext "ConfigChanged" 事件同位）。
4. **拍板④：权限面**。`on('update')` 订阅为公开 API 无需权限；`getData()` 需 `ohos.permission.READ_PASTEBOARD`（user_grant）→ module.json5 显式新增（含 reason+usedScene）；**运行期一次申请**（watcher start 时 `requestPermissionsFromUser`，`permissionRequested` 会话级守卫防重复弹窗）；拒绝/失败 → **保持订阅+仅 hilog 登记不可读，不崩不重弹**（探针写入轨 setData 无需权限，不受影响）。降级语义：未授权时监视链空转（每次 update 读失败计数），不破坏订阅本身。
5. **拍板⑤：自动开始路径复用 startNewDownload，不建第二条下载构造链**。源 AddDownload 自动分支构造 `SingleSourceHTTPDownloadInfo{Uri,File=SanitizeFileName(GetFileName(url))}` + StartDownload(startImmediately:true)——目标等价物=既有 `Index.startNewDownload(url, fileNameFromUrl(url), FileNameFetchMode.FileNameAndExtension)`（工厂+store.add+admitNew 链，排队/门语义由 manager 承载）。LinkRefresher.LinkAccepted 拦截位：**保留注释锚不建死代码**（U5.2 恒 false——refreshLinkCandidate 无登记方；U6.x 桥接时在 onClipboardUrl 入口补判，§4 D6）。
6. **拍板⑥：per-URL 单实例集=Index 模块级 `Set<string>`**（源 static HashSet+lock；ArkTS 主线程事件循环天然串行无竞态，Config.ets D1 注释先例"主线程单点天然串行"）。登记时机=对话框 open 前（PromptOpen :269），摘除时机=对话框 aboutToDisappear 统一回调（源 `window.DestroyEvent += destroyCallback` :18——**任何关闭路径恰一次**，等价 WPF Destroy 事件语义）。自动开始分支不登记（源无此门，lastClipboardText 去重已覆盖重复复制）。
7. **拍板⑦：NewDownloadDialog 预填=共享对象模式（keyConstraint #2 惯例）**。对话框既有 `@State url=''` 与校验链（handleUrlChange/handleNameChange/handleConfirm）**零改动**；新增 `model: NewDownloadModel`（plain class，构造期绑定，open 前赋值）+ `onClosed` 回调（aboutToDisappear 发射）。预填赋值在 aboutToAppear：`url/derivedName/fileName` 三写且**不置 fileNameTouched**（UrlChangedEvent 自动推导 :53-58 同位；程序化赋值不触回显守卫）。`initialUrl` 消费后即清（防重开残留）。`SetFileSizeText("---")` 不实装（剪贴板 Message 无 Content-Length 恒 '---'，信息量为零——§4 D5）。
8. **拍板⑧：删记录盘上清理（INT-F4）挂 store.remove 成功分支**。源 RemoveDownload(:725-798)：state 文件+tempDir **无论 deleteFiles 真假都删**（进行中分支 UIActions.DeleteDownloads 即传 false）；仅 `FinishedDownloadItem && deleteFiles` 才删成品 `TargetDir/Name`。目标：`StateStore.removeById(baseTempDir, id)` 静态方法（tempDir/<id>/ 目录级删除=listFileSync+逐文件 unlinkSync+rmdirSync，PieceGrabber.deleteTempDir :1165-1181 同款手法；chunks 三工件+分片文件全在目录内=源 RemoveStateFiles+Directory.Delete 双步的等价归并）；`Index.removeRecords` 在 `store.remove(id).then(ok)` 成功分支消费（既有 then 链内追加，写序不变）；成品删除用 `record.kind===DownloadKind.Finished && deleteFiles` 门（源 entry is FinishedDownloadItem 同构）+ fileIo.unlinkSync 全 catch 吞。U4.2 差异 #6 的 hilog 登记块删除（真实能力替换）。
9. **拍板⑨：顺手收口四项接线点**：①INT-F5 RefreshLinkDialog 删死回调 `onOpenReferer` prop（Index builder 同步摘除；Index.onOpenReferer 方法保留——onRefreshLinkMenu :996-999 有源锚调用点 LinkRefreshDialogUIController :75-77）；`handleStop` 加 `stoppedSent` 幂等守卫 + `aboutToDisappear` 兜底一次 `onStopped`（BtnStop_Click→Close→Window_Closing 恰一次语义，autoCancel 外点关闭路径补齐）。②INT-F6 `onShowProgressMenu` 增 `manager.isLive(id)` 门（ShowProgressWindow :326-328 `!liveDownloads.ContainsKey→return`——**queued 不算 live**，对停/排队行不开冻结窗）；`handleStarted` 既有 modelOf 块内**尾部追加** `speedText=''/etaText=''` 复位（ResumeDownload :305-321 重开窗复位锚）。③INT-F7 ProbeDialogs aboutToDisappear 补 `Config.offConfigChanged`——S2 listener 从局部 const 提升为成员引用，runS2 finally+aboutToDisappear 双点卸载（异常路径不漏）。④INT-F8（Config proxy 回退两处）**继续登记不实现**（代理消费仍休眠：HttpClient 不读 proxy，源 ApplicationCore.cs:214 `Config.Instance.Proxy` 传参在目标侧无对应物——U6.x HttpClient 接线时一并处理）。
10. **拍板⑩：设置页 Browse 只接 downloadDir 一处**。选中 URI 走 UpdateRecentFolderList 数学写入三键（拷贝目标链），**不回填 downloadDir TextInput、不调 setDownloadDir**（Save 时 setDownloadDir(downloadFolderText) 会把 URI 写进引擎目标键→破坏落盘，见拍板①）；视觉反馈=toast（msg_folder_picked）+hilog。temp/category 两处 Browse 维持占位（URI 不能作沙箱 tempDir/分类尾段目录，语义不兼容——§4 D8）。
11. **事件面零破坏红线（单元验收①）**：`Downloader.ets`/`DownloadManager.ets`/`ProgressNotifier.ets`/`Config.ets` **零改动**；Index 五 handler（handleStarted/Connected/Progress/Paused/Failed/Finished）**既有字段写序逐字节不动**，全部增量=方法尾部追加或既有 if 块内尾部追加（progressHost/notifier 两轮同款手法）；NewDownloadDialog 既有校验链零改动（只加 prop/回调/aboutToAppear 前置块）。
12. **纯逻辑拆分**：目录解析数学全部抽 `core/util/FolderAlgo.ets` 纯函数（零 @kit import，Hypium 直载，QueueAlgo/ScheduleAlgo/NotifyAlgo 先例）；ClipboardWatcher/SaveDirectory 承载 @kit API 编排。业务日志 hilog domain 0x0000、零 probe import、`[XDM_PROBE]` 仅 ProbeKit 出口（分层红线沿用）。
13. **线程模型（决策 2 投影）**：**零 TaskPool**——剪贴板 on('update') 系统回调/Picker Promise/fileIo.copy Promise 全在主线程事件循环消费；fileIo.copy 异步 fire-and-forget 不阻塞 handleFinished（拷贝期间列表/后续下载不受阻）；StateStore.removeById 主线程同步删（源 Directory.Delete 在 UI 线程同构，16 分片目录毫秒级；分片可达 GB 级时源码同样同步删，不预设异步化）。

---

## 1. 目标文件清单（按实现顺序）

> 新 6 / 改 15，共 21 项（业务新 3+改 7；配置改 1；资源改 3；单测新 1+改 1；探针新 1+改 2；文档新 2）。`main_pages.json` 零改动（探针子页走 ProbeIndex 条件渲染，U0.1 惯例）；`core/engine/**`、`model/**`、`core/Config.ets`、`core/net/**` 零改动。业务文件禁 import `probe/**`（审查红线）。

| # | 文件 | 新/改 | 职责与对外导出 | dependsOn |
|---|---|---|---|---|
| 1 | `entry/src/main/module.json5` | 改 | requestPermissions 数组追加第 4 项：`{"name": "ohos.permission.READ_PASTEBOARD", "reason": "$string:clipboard_permission_reason", "usedScene": {"abilities": ["EntryAbility"], "when": "inuse"}}`（user_grant 需 reason+usedScene；PREPARE_APP_TERMINATE 之后追加，既有三项逐字节不动）；deviceTypes/backgroundModes/skills 零改动 | — |
| 2 | `entry/src/main/ets/core/util/FolderAlgo.ets` | 新 | 目录解析纯函数层（零 @kit import，Hypium 直载）：`updateRecentFolderList(folders: string[], folder: string): string[]`（空串原表拷贝返回；不含→头插；含→原序拷贝——Helpers.cs:311-321 数学 1:1；Manual 置位与持久化归调用方）、`manualDownloadFolder(mode: number, recentFolders: string[], userSelected: string, defaultFolder: string): string \| null`（mode!==1→null；userSelected 非空且在表→userSelected；否则表[0]；空表→defaultFolder——:323-339 逐条）、`downloadFolderByFileName(fileName: string, categories: CategoryDef[], downloadDir: string): string`（末个'>'0 的 '.' 起取扩展名 toUpperCase 带点；命中 category.fileExtensions→`downloadDir+'/'+defaultFolderName`（D5 尾段拼接）；未命中/空名→downloadDir——FileHelper.cs:23-41，源返回完整 DefaultFolder=拼接等价）、常量 `FOLDER_MODE_AUTO=0`/`FOLDER_MODE_MANUAL=1`。import 仅 CategoryAlgo 类型 | — |
| 3 | `entry/src/test/FolderAlgo.test.ets` | 新 | §7 Hypium 用例 16 条 | #2 |
| 4 | `entry/src/test/List.test.ets` | 改 | testsuite 追加 `folderAlgoTest()` 注册 + 头部注释补 U5.2 行（241+16=257 条） | #3 |
| 5 | `entry/src/main/resources/base/element/string.json` | 改 | 追加 7 键：`clipboard_permission_reason`（"Used to detect copied download links"）、`msg_file_not_found`（"The file has been moved,renamed or deleted"——English.txt:166 逐字）、`no_item_selected`（"Please select item to open"——English.txt:167 逐字）、`msg_copy_failed`（"Could not copy to the selected folder. The file is kept in the app Downloads folder."自拟登记）、`msg_folder_picked`（"Save folder recorded. Finished downloads will be copied to it."自拟登记）、`probe_p5u2_title`（"P5-U2 剪贴板+保存目录探针"）、`probe_p5u2_check_hint`（走查提示文案） | — |
| 6 | `entry/src/main/resources/zh_CN/element/string.json` | 改 | 同步 7 键中文 | #5 |
| 7 | `entry/src/main/resources/en_US/element/string.json` | 改 | 同步 7 键英文 | #5 |
| 8 | `entry/src/main/ets/core/fs/SaveDirectory.ets` | 新 | 保存目录能力面（@kit 编排，无状态静态类）：`pickSaveFolder(ctx: common.UIAbilityContext): Promise<string \| null>`（`new picker.DocumentViewPicker(ctx).select(opts)`，opts 显式 `picker.DocumentSelectOptions` 字面量 `{maxSelectNumber: 1, selectMode: picker.DocumentSelectMode.FOLDER}`；空数组/取消→null）、`applyPickedFolder(uri: string): void`（UpdateRecentFolderList 数学+三键持久化：`FolderAlgo.updateRecentFolderList(Config.getRecentFolders(), uri)`→setRecentFolders + setFolderSelectionMode(MANUAL) + setUserSelectedDownloadFolder(uri)——源三键一存 :318-320 同位）、`copyTargetFolder(): string`（`FolderAlgo.manualDownloadFolder(...)`，仅返回 `file://` 前缀结果否则 ''）、`syncFinishedFile(filePath: string): Promise<boolean>`（copyTargetFolder 为 ''→resolve(true) 无事；否则 `fileIo.copy(fileUri.getUriFromPath(filePath), target + '/' + baseNameOf(filePath))` 成功 true/失败 catch→hilog+false——文件留沙箱不删）、`openFile(ctx: common.UIAbilityContext, path: string, action: string): Promise<boolean>`（`fileIo.accessSync` 预检失败/异常→false+hilog `action=` 登记；`filePreview.openPreview(ctx, previewInfo)`，PreviewInfo 显式类型字面量 `{uri: fileUri.getUriFromPath(path)}`；openPreview 失败 catch→false——13900042 不支持类型同路）。import：picker/fileIo/fileUri（@kit.CoreFileKit）+ filePreview（**@kit.PreviewKit**，本会话核实 kit 导出）+ FolderAlgo/Config/FileNames.baseName 复用（自实现 baseNameOf 私有函数，不 import components） | #2 |
| 9 | `entry/src/main/ets/core/clipboard/ClipboardWatcher.ets` | 新 | **本单元核心**。应用级单例（IPlatformClipboardMonitor+IClipboardMonitor 两层合一，方法面保持 start/stop+内部读文本）：`init(context: common.UIAbilityContext): void`（存 context+`Config.onConfigChanged(listener)`——**app-lifetime 永不 off**，源 ctor ApplicationEvent+= 同构）、`syncFromConfig(): void`（MonitorClipboard?start:stop——:33-45 1:1）、`setUrlHandler(handler: ((url: string) => void) \| undefined): void`（后到者接管，manager.init 先例：探针页/新 Index 实例重挂）、`start(): void`/`stop(): void`（active 双向幂等守卫+start 内部再查 Config——:47-59 逐条；on/off('update') 传**同一成员箭头函数引用**）、私有 `onUpdate()`（回调无载荷→`getData().then(data => clipboardChanged(data.getPrimaryText()))`，catch→lastReadOk=false+hilog 保持订阅）、私有 `clipboardChanged(text)`（三重过滤链短路序逐条；通过才 `lastClipboardText=text` 并计数+调 urlHandler——AddDownload(new Message{Url}) 同位）、私有 `requestReadPermissionOnce()`（`abilityAccessCtrl.createAtManager().requestPermissionsFromUser(ctx, ['ohos.permission.READ_PASTEBOARD'])` fire-and-forget，permissionRequested 守卫）、观测面（探针 P5-U2 消费）：`isActive()/detectCount()/filteredCount()/lastDetectedUrl()/lastReadOk()`。业务日志 tag 'ClipboardWatcher' | #1(逻辑上) |
| 10 | `entry/src/main/ets/core/db/StateStore.ets` | 改 | 只加不改：新增静态 `removeById(baseTempDir: string, recordId: string): void`——`dir=baseTempDir+'/'+recordId`；`fileIo.listFileSync(dir)` 逐文件 `unlinkSync`（内层 try/catch 吞）→`rmdirSync(dir)`（外层 try/catch 吞——目录不存在/非空残留均无害）；头部注释补一段 R3-F1 锚（RemoveDownload :725-798 tempDir 半区：deleteFiles=false 也照删）。既有 saveChunks/readChunks/clear/私有工具**逐字节不动** | — |
| 11 | `entry/src/main/ets/entryability/EntryAbility.ets` | 改 | 只加不改（U5.1 手法）：onCreate 尾部（ProgressNotifier.init 之后）追加两行：`ClipboardWatcher.getInstance().init(this.context);` + `ClipboardWatcher.getInstance().syncFromConfig();`（对照 Application.cs:34 WindowLoaded 后启动——默认 MonitorClipboard=false 故默认不订阅；注释登记 U5.2）。import 追加 ClipboardWatcher。其余语句序零改动 | #9 |
| 12 | `entry/src/main/ets/components/NewDownloadDialog.ets` | 改 | ①新增导出 `export class NewDownloadModel { initialUrl: string = ''; }`（plain class，无装饰器——只读一次非渲染态）；②新增 prop `model: NewDownloadModel = new NewDownloadModel()` 与 `onClosed: () => void = () => {};`；③aboutToAppear 既有 saveDir 行后追加预填块：`initial=model.initialUrl` 非空且 `isUriValid(initial)`→`url/derivedName/fileName` 三写（不置 fileNameTouched）+`model.initialUrl=''` 一次性消费；saveDir 行改经 FolderAlgo 解析：`manualDownloadFolder(cfg.getFolderSelectionMode(), cfg.getRecentFolders(), cfg.getUserSelectedDownloadFolder(), cfg.getDownloadDir()) ?? cfg.getDownloadDir()`；④新增 `aboutToDisappear(): void { this.onClosed(); }`（DestroyEvent 统一回调锚）。校验链/handleUrlChange/handleNameChange/handleConfirm/build **零改动**；头部注释删"剪贴板 URL 预填不移植（U5.2）"一行改为"U5.2 预填经 NewDownloadModel" | #2 |
| 13 | `entry/src/main/ets/components/RefreshLinkDialog.ets` | 改 | INT-F5：①删 `onOpenReferer` prop（:35-36 死回调——对话框内无调用点）；②新增 `private stoppedSent: boolean = false;`；③`handleStop()` 改 `this.notifyStopped(); this.controller?.close();`；④新增私有 `notifyStopped(): void { if (this.stoppedSent) return; this.stoppedSent = true; this.onStopped(); }` + `aboutToDisappear(): void { this.notifyStopped(); }`（Stop 钮→close→aboutToDisappear 二次调用被守卫吸收=任何关闭路径恰一次，LinkRefreshWindow :65-72 语义） | — |
| 14 | `entry/src/main/ets/pages/Index.ets` | 改 | 六处增量（五 handler 既有写序逐字节不动，全部尾部/块内追加）：①模块级 `const openPrompts: Set<string> = new Set<string>();`（NewDownloadPromptTracker 对应物）+ 新增成员 `newDownloadModel`（**声明在 dialogController 之前**——keyConstraint #2 初始化序）、`pendingPromptUrl: string`；②dialogController builder 追加 `model: this.newDownloadModel` 与 `onClosed: (): void => { this.onNewDownloadClosed(); }`；refreshLinkController builder **摘除 onOpenReferer 接线**（:232-234）；③新增 `onClipboardUrl(url)/onNewDownloadClosed()`（§3.2 状态机）；④aboutToAppear 尾部追加 `ClipboardWatcher.getInstance().setUrlHandler((url: string): void => { this.onClipboardUrl(url); });`；⑤`onOpenPlaceholder` 替换为 `handleOpenAction(button)`（§3.5：NO_ITEM_SELECTED/ERR 弹窗+SaveDirectory.openFile；两个工具栏钮 onClick 改调它）；⑥`removeRecords`：store.remove 成功分支内追加 `StateStore.removeById(tempDir, id)`（tempDir 循环外取 Config 一次）与 deleteFiles&&kind===Finished 的成品 unlink；删 U4.2 差异 #6 hilog 块；`handleFinished` 尾部追加 `SaveDirectory.syncFinishedFile(filePath).then(...)`（false→toast msg_copy_failed）；`onShowProgressMenu` 开头加 `if (!DownloadManager.getInstance().isLive(id)) { return; }`；`handleStarted` 既有 modelOf 块内尾部追加 `startedModel.speedText = ''; startedModel.etaText = '';`。import 追加：ClipboardWatcher/SaveDirectory/StateStore/DownloadKind | #8 #9 #10 #12 #13 |
| 15 | `entry/src/main/ets/components/settings/GeneralSettingsTab.ets` | 改 | 只改 downloadDir 一处 Browse：`handleBrowsePlaceholder('download')` 调用点（:428）改调新增 `handleBrowseDownload()`——`getHostContext()` 窄化 downcast UIAbilityContext→`SaveDirectory.pickSaveFolder(ctx)`→非 null 时 `SaveDirectory.applyPickedFolder(uri)` + `getPromptAction().showToast({message: $r('app.string.msg_folder_picked')})`；temp Browse（:410）与 CategoryEdit 的 Browse（:78-82）维持占位不动（hilog 原样）。其余零改动 | #8 |
| 16 | `entry/src/main/ets/components/ProgressWindowDialog.ets` | 改 | 完成窗 Open/Open folder 占位接线（openCompleted 内 :409-417 两处）：`actions.onOpenFile = (): void => { this.openFinishedFile(folder + '/' + fileName, 'openFile'); }`、`actions.onOpenFolder = (): void => { this.openFinishedFile(folder + '/' + fileName, 'openFolder'); }`；新增私有 `openFinishedFile(path, action)`：getHostContext 窄化→`SaveDirectory.openFile(...)` fire-and-forget，失败仅 hilog（完成窗无失败弹窗=源 DownloadComplete 窗同貌，§4 D11） | #8 |
| 17 | `entry/src/main/ets/probe/units/ProbeClipboardSaveDir.ets` | 新 | P5-U2 探针（§6 五步）：autoStart=false；S1 监视启动+权限锚（auto）/S2 程序写入直链三连观测（auto）/S3 人工复制轨（manual 单步）/S4 保存目录选择+StateStore 清理观测（manual 单步）/S5 人工走查清单（manual 单步发射） | #8 #9 #10 |
| 18 | `entry/src/main/ets/probe/units/ProbeDialogs.ets` | 改 | INT-F7：新增成员 `private s2ConfigListener: (() => void) \| null = null;`；runS2 内局部 `const listener` 注册前赋给成员、**try/finally** 包裹写读段（finally 内 offConfigChanged+成员置 null）；aboutToDisappear 追加：成员非 null 时 `Config.getInstance().offConfigChanged(成员)` + 置 null（异常路径/页面卸载双兜底）。其余步骤零改动 | — |
| 19 | `entry/src/main/ets/probe/ProbeIndex.ets` | 改 | PROBE_UNITS 追加 `{unitId: 'P5-U2', title: $r('app.string.probe_p5u2_title')}` + else-if 分支 `ProbeClipboardSaveDir()`（U0.1 注册惯例） | #17 |
| 20 | `docs/probe/PROBE-u5-2-clipboard-save-dir.md` | 新 | 探针手册（§6）：运行次序/权限弹窗指引/人工复制轨指引/走查清单 10 项/抓取命令 | #17 |
| 21 | `docs/probe/EXPECT-u5-2-clipboard-save-dir.json` | 新 | verify 期望表（BEGIN/S1~S5/SUMMARY/END；权限拒绝与环境敏感项标注 observe-both） | #20 |

---

## 2. 数据模型与表结构（对照源码逐一核对）

**DB 零变更**：downloads 表 22 列不动（targetDir 恒沙箱路径；完成迁移走既有 markAsFinished）。**preferences 零新键**：本单元全部消费既有键——

| Config 键（Config.ets） | 本单元消费面 | 源锚 |
|---|---|---|
| `monitorClipboard`（:111 默认 false） | ClipboardWatcher.syncFromConfig 读；MonitoringSettingsTab 既有写 | Config.cs:114 + ConfigIO.cs:190 |
| `startDownloadAutomatically`（:107 默认 false） | onClipboardUrl 分流读 | Config.cs:110 + ApplicationCore.cs:214 |
| `recentFolders`（JSON 集合键 :99） | applyPickedFolder 写（updateRecentFolderList 数学）；NewDownloadDialog/saveDirectory 读 | Config.cs:94 + Helpers.cs:313-320 |
| `folderSelectionMode`（:102，0=Auto/1=Manual） | applyPickedFolder 写 1；copyTargetFolder/saveDir 读 | Config.cs:96（FolderSelectionMode 枚举 :505-508） |
| `userSelectedDownloadFolder`（:138） | applyPickedFolder 写；manualDownloadFolder 读 | Config.cs:98 |
| `downloadDir`（沙箱 `<filesDir>/Downloads`） | 引擎落盘目标（**本单元不改其写入方**——startNewDownload :412 既有）；saveDir Auto 分支展示 | Config.cs:154（有意差异 D1 双轨） |

**ClipboardWatcher 内存态**（对照源逐一核对）：

| 字段 | 类型 | 语义 | 源锚 |
|---|---|---|---|
| `context` | `common.UIAbilityContext \| undefined` | requestPermissionsFromUser 的 context | IPlatformClipboardMonitor 平台适配器上下文（鸿蒙无 per-window 适配器→应用级） |
| `active` | boolean | `isClipboardMonitorActive`（幂等守卫半区） | ClipboardMonitor.cs:26 |
| `lastClipboardText` | string | 去重锚（三重过滤第三条；**无效文本不更新**） | :27 + :66-71 |
| `urlHandler` | `((url: string) => void) \| undefined` | ClipboardChanged 事件的单订阅者投影（Index/探针后到者接管） | cm.ClipboardChanged += / -= |
| `permissionRequested` | boolean | READ_PASTEBOARD 会话级一次申请守卫 | 鸿蒙特有（WPF 无权限概念） |
| `configListener` | 成员箭头函数 | ConfigChanged→syncFromConfig（app-lifetime 不 off） | ctor :30 ApplicationContext_ApplicationEvent |
| `detectCount/filteredCount/lastDetectedUrl/lastReadOk` | number/number/string/boolean | 观测面（仅探针/诊断消费，非源行为） | 鸿蒙新增 |

**Index 侧新增态**：模块级 `openPrompts: Set<string>`（NewDownloadPromptTracker.newDownloadPrompts 对应物，`pendingPromptUrl` 为当前待关 URL 快照）；成员 `newDownloadModel: NewDownloadModel`（预填载体，plain class 单字段 initialUrl）。

**StateStore 工件布局零变更**：tempDir/<recordId>/ 内 chunks.json.1/.2/.new + 分片文件（头注 :4-8 不动）；`removeById` 只是把"目录级删除"补成公开能力（源 RemoveStateFiles 逐文件 + Directory.Delete(tempDir,true) 双步在本布局下归并为一次目录删除——布局本身即源码 TempDir 同构，无语义差）。

**通知/后台面零接触**：U5.1 的 ProgressNotifier/onPrepareToTerminate/module.json5 backgroundModes 全部原样（红线），ClipboardWatcher 与之无调用关系。

---

## 3. 关键算法翻译说明

### 3.1 监视生命周期状态机（ClipboardMonitor.cs:25-74 → ClipboardWatcher）

```
源(WPF/Gtk)                                        鸿蒙(ArkTS)
────────────────────────────────────────────────────────────────────────────
ctor: ApplicationContext.ApplicationEvent +=   →   init(): Config.onConfigChanged(configListener)
        (e.Type=="ConfigChanged")                   （app-lifetime 永不 off——源事件随对象存活同构；
         ? Start() : Stop()                          设置页 Save→broadcastConfigChange 触达）
Start():                                             start():
  if (isClipboardMonitorActive) return;    :47-48      if (active) return;
  if (!Config.MonitorClipboard) 不订阅      :49         if (!Config.getMonitorClipboard()) return;
  cm.StartClipboardMonitoring()                        pasteboard.getSystemPasteboard().on('update', onUpdate)
  isClipboardMonitorActive = true                      active = true
  cm.ClipboardChanged += Handler                       （单 handler 引用即订阅；权限申请 fire-and-forget）
Stop():                                              stop():
  if (!isClipboardMonitorActive) return;   :56-57      if (!active) return;
  cm.StopClipboardMonitoring()                         pasteboard.getSystemPasteboard().off('update', onUpdate)
  isClipboardMonitorActive = false                     active = false
```

要点：①`on('update')` 回调**无载荷**（d.ts:1737 `callback: () => void`）——触发后再 `getData()` 读文本，与 Wpf Win32ClipboarMonitor 推送链同构（Gtk 是 1000ms 轮询，两平台适配器差异在源码内被接口吸收，鸿蒙取推送式）；②on/off 必须传**同一成员箭头函数引用**（`private onUpdate = (): void => {...}` 或成员方法绑定字段——匿名箭头会导致 off 失配）；③启动时机=EntryAbility.onCreate 尾部 syncFromConfig()（Application.cs:34 WindowLoaded 后 Start 同位；默认 false→默认不订阅）+ 设置页 Save 广播（运行期开关）。

### 3.2 剪贴板命中链（Cm_ClipboardChanged :64-72 + AddDownload :208-236 → onClipboardUrl）

```
onUpdate (系统回调,主线程)
  → getData().then(data => clipboardChanged(data.getPrimaryText()))
      catch → lastReadOk=false + hilog warn + return（保持订阅不重弹权限）
clipboardChanged(text):
  if (text 非空 && isUriValid(text) && text !== lastClipboardText):   // 三重过滤短路序 1:1
    lastClipboardText = text                                          // 仅通过才更新（:70 次序红线）
    detectCount++; lastDetectedUrl = text
    urlHandler?.(text)                                                // = AddDownload(new Message{Url=text})
  else: filteredCount++                                               // 无效文本不更新 lastClipboardText

Index.onClipboardUrl(url):                                            // ApplicationCore.AddDownload :208-236
  // U6.x 登记处：LinkRefresher.LinkAccepted(message) 为 true 时 return（恒 false，钩子位注释保留）
  if (Config.getStartDownloadAutomatically()):
    startNewDownload(url, fileNameFromUrl(url), FileNameFetchMode.FileNameAndExtension)  // :214-231 自动分支
    return
  if (openPrompts.has(url)): return            // NewDownloadPromptTracker.IsPromptAlreadyOpen :265-268
  openPrompts.add(url); pendingPromptUrl = url // PromptOpen :269
  newDownloadModel.initialUrl = url
  dialogController.open()                      // ShowNewDownloadDialog → CreateAndShowDialog :270-272
Index.onNewDownloadClosed():                    // DestroyEvent → PromptClosed（任何关闭路径恰一次）
  if (pendingPromptUrl 非空): openPrompts.delete(pendingPromptUrl); pendingPromptUrl = ''
```

文件名推导：`fileNameFromUrl`（FileNames.ets:49，FileHelper.GetFileName(new Uri(url)) 既有等价物）对应自动分支 `File=SanitizeFileName(message.File ?? GetFileName(url))`；对话框预填分支的 `SelectedFileName=SanitizeFileName(...)` 由 aboutToAppear 预填块承担（sanitize 在 handleConfirm :79 既有链统一发生，不重复）。

### 3.3 保存目录数学（Helpers.cs:311-341 + FileHelper.cs:23-41 → FolderAlgo）

```
updateRecentFolderList(folders, folder):        // UpdateRecentFolderList :311-321（表操作半区）
  folder 空 → 返回 folders 拷贝（不变）
  !folders.contains(folder) → [folder, ...folders]        // Insert(0, folder)
  含 → folders 拷贝（不重排不去重）
  ※ Manual 置位+持久化在调用方 applyPickedFolder（源 Config.FolderSelectionMode=Manual+SaveConfig :318-320
    三动作本就跨 Config/Helpers 两处，目标侧归并进 applyPickedFolder 一处）

manualDownloadFolder(mode, recentFolders, userSelected, defaultFolder):   // :323-339 逐条
  mode != MANUAL(1) → null                                 // Auto 返回 null（调用方退化类别解析）
  userSelected 非空 && recentFolders.contains(userSelected) → userSelected
  recentFolders.length > 0 → recentFolders[0]
  → defaultFolder

downloadFolderByFileName(fileName, categories, downloadDir):              // FileHelper.cs:23-41
  ext = 末个下标>0 的 '.' 起子串 toUpperCase（带点；'.bashrc' 形态=无扩展名——Path.GetExtension 同貌）
  for cat in categories: if ext 非空 && cat.fileExtensions.contains(ext) → downloadDir + '/' + cat.defaultFolderName
  → downloadDir                                            // 未命中回退 DefaultDownloadFolder
```

消费面：`applyPickedFolder`（设置页 Browse 后）、`copyTargetFolder`（完成拷贝目标，Auto→'' 不拷贝）、NewDownloadDialog saveDir 展示（`manualDownloadFolder(...) ?? downloadDir`——Manual 显示拷贝目标 URI、Auto 显示沙箱目录）。

### 3.4 完成拷贝链 + Open/OpenFolder 状态机

```
handleFinished(既有链逐字节不动) 尾部追加:
  SaveDirectory.syncFinishedFile(filePath)
    ├─ copyTargetFolder() === ''（Auto/沙箱路径）→ resolve(true)      // 无拷贝目标，无事发生
    └─ fileIo.copy(fileUri.getUriFromPath(filePath), <folderUri> + '/' + basename)
         .then → true                                                 // 落用户目录
         .catch → hilog.error + false → Index toast(msg_copy_failed)  // 授权失效/重启后：文件留沙箱
Open/OpenFolder（Index.handleOpenAction，UIActions :76-120 状态机 1:1）:
  firstSelectedId() === '' → showAlertDialog(no_item_selected)        // NO_ITEM_SELECTED（OpenSelectedFolder 末行/OpenSelectedFile 末行同构）
  record/targetDir/name 缺失 → showAlertDialog(msg_file_not_found)    // TargetDir 空分支 :114-117
  SaveDirectory.openFile(ctx, targetDir+'/'+name, action):
    fileIo.accessSync(path) 失败 → false → showAlertDialog(msg_file_not_found)   // File.Exists :104/:92
    filePreview.openPreview(ctx, {uri: fileUri.getUriFromPath(path)})            // 单文件变体
    openFolder 同路 + hilog action=openFolder downgraded（拍板②降级）
完成窗（ProgressWindowHost.openCompleted）Open/Open folder 同函数接线，失败仅 hilog（D11）
```

### 3.5 删记录盘上清理（RemoveDownload :725-798 → removeRecords 消费）

```
store.remove(id).then(ok => {                                     // 既有 then 链，写序不变
  ...既有失败门...
  StateStore.removeById(Config.getTempDir(), id)                  // 恒清（:725-798 全程 deleteFiles=false 也删 state+tempDir）
  if (deleteFiles && record !== null && record.kind === DownloadKind.Finished
      && record.targetDir !== null && record.name !== null):
    try fileIo.unlinkSync(targetDir + '/' + name) catch 吞        // FinishedDownloadItem+deleteFiles 分支 :758-756
  ...既有 DS removeById/recomputeCounts...
})
```

`removeById` 全 catch 吞绝不抛（源 RemoveDownload 最外层 catch :796-798 同构）；进行中分支（deleteFiles=false）与完成分支（deleteFiles 勾选）都先经此清理恢复态与临时分片——U4.2 R3-F1"删记录不清理恢复态与临时分片"闭环。

### 3.6 线程模型映射（决策 2 投影）

| 源 | 鸿蒙 |
|---|---|
| WPF Dispatcher/RunOnUIThread 串行 UI 线程 | ArkTS 主线程事件循环天然串行——openPrompts/lastClipboardText/active 全部无锁（Config.ets D1 先例） |
| Win32 剪贴板查看链推送（窗口消息） | pasteboard.on('update') 系统回调（主线程），getData Promise 读回 |
| FolderBrowserDialog.ShowDialog() 模态阻塞 | DocumentViewPicker.select() Promise（非阻塞，回调内写 Config） |
| Shell Execute / explorer /select | filePreview.openPreview Promise（fire-and-forget） |
| File.Delete/Directory.Delete 同步盘 IO | fileIo.unlinkSync/rmdirSync 同步（毫秒级目录；源码同样 UI 线程同步删） |
| fileIo.copy 用户目录大文件 | Promise 异步 fire-and-forget（**不阻塞** handleFinished；拷贝期间后续下载/通知不受阻） |

---

## 4. 与源码的有意差异清单

| # | 差异 | 依据 |
|---|---|---|
| D1 | **双轨目录**：引擎落盘恒沙箱 downloadDir（record.targetDir 不变）；用户目录 URI 仅作完成后 fileIo.copy 目标。源=直接下载进所选目录（StartDownload targetFolder/Downloader :307 类别解析） | 拍板①（Picker 临时授权生命周期；引擎零接触红线） |
| D2 | 不做 persistPermission/FILE_ACCESS_PERSIST（受限开放权限课程工程不可申请）；**重启后需重选目录**（临时授权失效，拷贝回退沙箱+toast 提示） | openQuestion 1 拍板 |
| D3 | OpenFolder 降级=openPreview 同路（无"文件管理器定位目录"公开 API）+hilog 差异登记 | openQuestion 2 拍板 |
| D4 | 设置页 Browse 驱动 recentFolders 三键（拷贝目标链），**不回填 downloadDir TextInput**（防 URI 写入引擎目标键）；视觉反馈=toast | 拍板⑩ |
| D5 | 新建对话框无目录下拉（U1.2 D13 子集延续）；saveDir 展示 Manual→拷贝目标 URI/Auto→沙箱目录；`SetFileSizeText("---")` 不实装（剪贴板 Message 无 Content-Length 恒 '---' 信息量为零） | 拍板⑦ |
| D6 | LinkRefresher.LinkAccepted 拦截位=注释锚不建死代码（U5.2 恒 false——refreshLinkCandidate 无登记方；U6.x 桥接补判） | 源 ApplicationCore.cs:209 |
| D7 | 自动开始路径复用 startNewDownload（工厂+store.add+admitNew），不构造 SingleSourceHTTPDownloadInfo 直启链 | 拍板⑤ |
| D8 | temp/category 两处 Browse 维持占位（URI 不能作沙箱 tempDir/分类尾段目录，语义不兼容；源 FolderBrowserDialog 返回真实路径可直写） | 拍板⑩ |
| D9 | READ_PASTEBOARD 运行期一次申请；拒绝后保持订阅只记日志不重弹（监视链空转）——鸿蒙特有，WPF 无权限概念 | 拍板④ |
| D10 | per-URL 单实例集=Index 模块级 Set（源 static HashSet+lock）；对话框关闭统一走 aboutToDispose 回调（源 DestroyEvent 事件语义同构） | 拍板⑥ |
| D11 | 完成窗 Open/Open folder 失败仅 hilog（源 DownloadComplete 窗 Open 无失败弹窗同貌）；工具栏 Open 失败弹 msg_file_not_found（UIActions :88/:108 1:1） | §3.4 |
| D12 | handleStarted modelOf 块内追加 speedText/etaText 复位（ResumeDownload :305-321 重开窗复位锚；500ms 内速度/ETA 显示 '---' 空串） | 拍板⑨② |
| D13 | 剪贴板 Message 的 File=null/Headers 空/Cookies null 语义由 newDownloadRecord 工厂自然承载（源 :212-217 四字段只填 Uri/File 两项的等价投影） | 源 Message.cs:11-27 |
| D14 | probe 写入轨 setData 无需权限（d.ts :2235）；人工复制轨与程序写入轨分 S3/S2 两步（源无对应物，探针专用轨道） | §6 |
| D15 | INT-F8（Config proxy 回退两处）继续登记不实现——HttpClient 不读 proxy，`Config.Instance.Proxy` 传参在目标侧无消费方 | 拍板⑨④ |
| D16 | 新增资源键 msg_copy_failed/msg_folder_picked/clipboard_permission_reason 为自拟登记（源无对应文案——鸿蒙拷贝链/toast/权限 reason 为平台新增面）；msg_file_not_found/no_item_selected 取 English.txt:166-167 逐字 | §1-#5 |
| D17 | 提示对话框串行化（R2-F2 审查修复）：提示对话框在开时命中新 URL 入队 promptQueue（openPrompts 入队即登记防重），对话框关闭回调查队列逐个 setTimeout(0) 延迟重开——源=每 URL 各自弹窗并行（Application.cs:263-276 每次新建窗口+各自 destroyCallback 恰摘自身）；目标 CustomDialogController 单实例无法并行多窗，串行重放保 per-URL 单实例语义且无 pendingPromptUrl 快照覆盖泄漏；重开延迟避开 aboutToDisappear 拆卸中态 | 源 NewDownloadPromptTracker.cs + Application.cs:263-276 |
| D18 | New 菜单预填权限面（R2-F3/R3-F1 审查修复）：openNewDownloadFromClipboard 在 getData 前经 ClipboardWatcher.requestReadPermission()（公开入口，与 watcher.start 共用 permissionRequested 会话级一次守卫）显式申请——用户主动点菜单=标准申请时机（默认 monitorClipboard=false 时 watcher.start 不触发，无此前置则预填恒 201 失效）；申请终态后再读，拒绝/读失败静默保持空白打开——源 GetUrlFromClipboard（Application.cs:180-188）无权限概念恒可用，鸿蒙平台新增面（D9 同族降级） | 源 Application.cs:180-188 + 拍板④/D9 |
| D19 | 完成拷贝 dest=目录 URI（COLD-F2/COLD-F3 审查修复）：syncFinishedFile 改 fileIo.copy(srcUri, target)——destUri 传目录 URI 为 @ohos.file.fs.d.ts:895-903 文档语义（"destination file or directory"），平台负责落名（源 URI 末段）与百分号编码，替代本设计书拍板①/§3.4 的 `<folderUri>/<文件名>` 裸拼（文件名含空格/#/?/% 时 URI 解析破坏→拷贝整链必失败）；requestReadPermission catch 分支守卫复位（permissionRequested=false——onCreate 早期申请若因窗口未就绪等报错，New 菜单显式入口仍可达，不造成重弹循环） | @ohos.file.fs.d.ts:903 + 拍板① |

---

## 5. 单元验收测试要点

- **[A] 编译门禁**：hvigor 全量构建零 error 零新 warning（ArkTS 严格子集编译期强制；本单元高危点：`picker.DocumentSelectOptions`/`filePreview.PreviewInfo` 对象字面量必须显式类型标注（arkts-no-untyped-obj-literals）、on/off('update') 回调须同一成员引用、`(ctx as common.UIAbilityContext)` downcast 须在 undefined 窄化之后、模块级 `new Set<string>()` 泛型显式）。
- **[A] 事件面零破坏静态核对**：`Downloader.ets`/`DownloadManager.ets`/`ProgressNotifier.ets`/`Config.ets` 与 U5.1 版 diff 为空；`Index.ets` 五 handler 既有写序 diff 仅尾部/既有 if 块内追加行；NewDownloadDialog 校验链（handleUrlChange/handleNameChange/handleConfirm）diff 为空；StateStore 既有方法 diff 为空。
- **[A] 纯逻辑单测**：`FolderAlgo.test.ets` 16 条全绿 + 既有 241 条全绿（合计 257）。
- **[P] P5-U2 探针**：S1/S2 主会话自动 + S3/S4/S5 单步；真机优先（剪贴板跨应用复制、用户目录落盘都更真实；模拟器可验程序写入轨与目录选择）；判定走 `xdm-probe-verify` 对照 EXPECT 表。
- **[P] 人工走查**（手册清单 10 项）：①设置页监控勾选 Monitor clipboard→Save→复制直链→新建对话框弹出且 URL/文件名预填（Index 正常模式，探针 S2 覆盖不到的接线层）；②同 URL 再次复制不重复弹窗（openPrompts/lastClipboardText 双锚）；③关掉对话框后再复制同 URL 能再次弹（PromptClosed 摘除锚）；④勾选 Start download automatically→复制直链→自动开始下载无弹窗；⑤设置页 General Browse→picker 选目录→toast+完成下载后文件出现在所选用户目录（文件管理器可见）；⑥工具栏 Open→预览打开成品文件；⑦Open folder→同路预览（D3 降级）；⑧删除进行中记录→确认后重启应用记录不恢复且无残留（tempDir/<id> 清理锚）；⑨停行/排队行右键 Show progress→不开窗（isLive 门）；⑩刷新链接窗 Stop 或点外部关闭→hilog WatchingStopped 恰一次（无双发）。
- **[P] 回归护栏**：U5.1 的 onPrepareToTerminate/ProgressNotifier 行为不回退（既有 P5-U1 探针结论不重跑——探针一次性原则）；关窗后台继续下载链路不受本单元改动影响（handleFinished 尾部追加为 fire-and-forget）。

---

## 6. 探针步骤设计（P5-U2 · ProbeClipboardSaveDir.ets）

**会话模型**：主会话（"运行全部"：S1/S2 autoRun 跑完，S3/S4/S5 发占位行，恰 9 行 = BEGIN+S1+S2+S3+S4+S5+SUMMARY+END）+ 三个单步会话（S3 人工复制轨、S4 目录选择、S5 走查发射，各恰 4 行）。判定锚：S1/S2 取主会话，S3/S4 取各自单步会话末次 runId。**前置人工**：无测试源需求（本单元不下载）；首次运行 S1 会弹 READ_PASTEBOARD 授权框（点允许）。探针页 aboutToAppear 需 `ClipboardWatcher.setUrlHandler(探针观测回调)`（后到者接管——探针轨不弹窗只计数；Index 不在场）。探针结束 aboutToDisappear 不摘 handler（应用级单例无泄漏面，与 manager.init 同例）。

| 步骤 | autoRun | 操作 | 观测点 | 日志标记（示例值；只写事实） |
|---|---|---|---|---|
| S1 | 是 | 监视启动+权限锚：快照 monitorClipboard→置 true→syncFromConfig()→isActive() 读回→（首次触发权限申请，手册注明点允许）→ 读 detectCount/filteredCount 基线 → 恢复快照前保持 true（S2 依赖） | 订阅建立/权限申请发起/基线计数 | `[S1] cfgBefore=false cfgAfter=true watcherActive=true permRequested=true detectBase=0 filteredBase=0` |
| S2 | 是 | 程序写入直链三连（setData 轨，无需权限）：`pasteboard.createData(MIMETYPE_TEXT_PLAIN,'http://192.168.1.20:8080/big.bin')`+setData→轮询 ≤10s 至 detectCount 增量→**再写同 URL**→200ms 后读计数（去重锚）→写 `'ftp://host/f.bin'`→读 filteredCount 增量 | 识别/去重/过滤三段事实 | `[S2] url1=http://.../big.bin detectDelta=1 dedupDetectDelta=0 filteredDelta=1 lastReadOk=true` |
| S3 | 否（单步） | **人工复制轨**：手册指引"在浏览器/备忘录复制任意一条 http(s) 直链→回探针页点本步骤执行"→读 detectCount/lastDetectedUrl（用户复制动作已触发 onUpdate） | 跨应用人工复制被识别 | `[S3] lastDetectedUrl=<用户复制URL消毒后> detectDelta>=1 lastReadOk=true` |
| S4 | 否（单步） | 保存目录选择+清理观测：点执行→`SaveDirectory.pickSaveFolder`（弹 FOLDER picker，人工选目录）→applyPickedFolder→Config 回读（recentFolders[0]/folderSelectionMode/userSelectedDownloadFolder）→再验 StateStore 清理：mkdir `tempDir/probe-p5u2-<runId>/`+写两个假文件→`StateStore.removeById`→accessSync 复检不存在 | picker URI/三键回读/目录级删除 | `[S4] pickedUri=file://... folderCount=1 selectionMode=1 userSelected=file://... tempGone=true` |
| S5 | 否（单步） | 人工走查清单 10 项发射（§5 清单；标题只进 UI 不进日志，探测页勾选面同 ProbeDialogs S5 先例）——本步骤在**正常应用模式**（非 page=probe 冷启动）人工操作后回来发射计数 | 走查完成度 | `[S5] checked=<n> total=10 unchecked=<k>` |

失败形态：步骤异常 catch emit `errCode/errMessage`（如 S1 的 201 权限缺配——module.json5 漏配分流 business-code；S2 lastReadOk=false 且 detectDelta=0 → 权限被拒 observe-both（回读 S1 后用户手动允许再跑）或 business-code（on('update') 链）；S4 pickedUri 为空 → 用户取消 observe-both；S4 tempGone=false → 分流 business-code（removeById 链））。EXPECT 表同步标注：S3 人工轨在 page=probe 冷启动下只验证"识别+计数"，弹窗预填层由 S5 走查①承担（分工明确防止假 PASS）。

---

## 7. Hypium 本地用例清单（FolderAlgo.test.ets，16 条；被测模块零 @kit import）

| # | 用例 | 断言锚 |
|---|---|---|
| 1 | updateRecentFolderList 空串不变 | updateRecentFolderList(['a'],'') 内容恒 ['a']（:312-314 空 return） |
| 2 | updateRecentFolderList 头插 | updateRecentFolderList(['a','b'],'c')=['c','a','b']（Insert(0) :315-317） |
| 3 | updateRecentFolderList 已存在不重排 | updateRecentFolderList(['a','b'],'a')=['a','b']（contains 短路） |
| 4 | updateRecentFolderList 空表首插 | updateRecentFolderList([],'x')=['x'] |
| 5 | manualDownloadFolder Auto 恒 null | manualDownloadFolder(0,['a'],'a','def')=null（:338-339） |
| 6 | manualDownloadFolder Manual+userSelected 在表 | (1,['a','b'],'b','def')='b'（:327-329） |
| 7 | manualDownloadFolder userSelected 不在表回退[0] | (1,['a','b'],'zzz','def')='a'（:330-331 条件含 Contains） |
| 8 | manualDownloadFolder userSelected 空回退[0] | (1,['a','b'],'','def')='a'（:326 空串门） |
| 9 | manualDownloadFolder 空表回退 default | (1,[],'','def')='def'（:332-333） |
| 10 | manualDownloadFolder 边界组合 | (1,[],'zzz','def')='def'（userSelected 不在空表+空表→default） |
| 11 | downloadFolderByFileName 命中分类 | ('file.PDF',cats,'/d')='/d/Documents'（带点大写匹配 FileHelper.cs:27-33） |
| 12 | downloadFolderByFileName 大小写不敏感 | ('file.pdf',cats,'/d')='/d/Documents'（toUpperCase 归一） |
| 13 | downloadFolderByFileName 未命中回退 | ('file.xyz',cats,'/d')='/d'（:39 回退 DefaultDownloadFolder） |
| 14 | downloadFolderByFileName 无扩展名回退 | ('file',cats,'/d')='/d'；('.bashrc',cats,'/d')='/d'（dot>0 门=Path.GetExtension dotfile 同貌） |
| 15 | downloadFolderByFileName 空文件名回退 | ('',cats,'/d')='/d' |
| 16 | 常量值 | FOLDER_MODE_AUTO=0、FOLDER_MODE_MANUAL=1（Config.cs:505-508 枚举同值） |

---

## 8. 编码注记（给 build agent 的落地提示）

1. import 面固定：`import { pasteboard } from '@kit.BasicServicesKit'`、`import { picker, fileIo, fileUri } from '@kit.CoreFileKit'`、`import { filePreview } from '@kit.PreviewKit'`（**不是** CoreFileKit——本会话 `@kit.PreviewKit.d.ts:9-11` 核实）、`import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit'`。
2. `clipboardChanged` 三重过滤**短路序不可重排**：`text.length === 0 || !isUriValid(text) || text === this.lastClipboardText`——第二项失败时不得触达第三项（源 :66 单表达式 && 短链）。
3. `on('update')`/`off('update')` 与 `Config.onConfigChanged` 的回调都存**成员字段**（箭头函数属性），严禁调用点内联匿名函数（off 失配=订阅泄漏）。
4. Index 成员声明序红线：`newDownloadModel`/`pendingPromptUrl` 必须在 `dialogController`（:165）**之前**声明（builder 构造期捕获引用——keyConstraint #2 惯例，RefreshLinkModel 先例 :180）。
5. `removeRecords` 的 `record` 引用必须在 store.remove **之前**经 findById 抓取（then 回调执行时 DS 已移除、findById 返 null）；成品 unlink 用抓取到的引用判 kind/targetDir/name。
6. 探针 S2 轮询 detectCount 用 100ms POLL+10s 超时（ProbeDialogs S3 同参常量），每轮 await 后过 `probeKit.isCurrent(runId)` 守卫（IR-F5 五守卫点惯例）。
7. 业务日志 domain 0x0000 / tag 'ClipboardWatcher'/'SaveDirectory'；绝不输出 [XDM_PROBE]；探针标记仅经 ProbeKit.emit（ProbeClipboardSaveDir.ets 唯一出口）。
