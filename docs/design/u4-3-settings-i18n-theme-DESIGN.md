# U4.3 设置页全配置键 + i18n + 主题 · 模块设计书

> 单元：U4.3 设置页全配置键+i18n+主题（Phase 4）。前置：U4.1（Navigation/菜单骨架）、U1.1（Config 15 键骨架）。
> 配套：[MIGRATION_PLAN](../../MIGRATION_PLAN.md) §5/§6 决策 10/11、[UNIT_CATALOG](../../UNIT_CATALOG.md) U4.3 行、[PROBE_SPEC](../../PROBE_SPEC.md)。
> 源码锚（本会话逐一读过核实）：`XDM.Core/Config.cs`（全文 515 行）、`XDM.Core/IO/ConfigIO.cs:76-300/:330-505`（持久化键表）、
> `XDM.Wpf.UI/Dialogs/Settings/{SettingsWindow,GeneralSettingsView,NetworkSettingsView,BrowserMonitoringView,PasswordManagerView,AdvancedSettingsView,CategoryEditWindow,PasswordWindow}.{xaml,xaml.cs}`、
> `XDM.Wpf.UI/Dialogs/LanguageSettings/LanguageSettingsWindow.xaml.cs`、`XDM.Wpf.UI/App.xaml.cs:25/:122-145`、
> `XDM.Wpf.UI/MainWindow/WpfPlatformUIService.cs:147-170`、`XDM.Core/Translations/TextResource.cs`、`app/XDM/Lang/{index.txt,English.txt,Chinese simplified.txt}`、
> `XDM.Core/ApplicationContext.cs:109-112`、`XDM.Core/ClipboardMonitor.cs:27-36`、`XDM.Wpf.UI/Dialogs/ProgressWindow/DownloadProgressWindow.xaml.cs:56-63`、`XDM.Core/ProxyInfo.cs`。
> 目标侧现状（本会话读过核实）：`core/Config.ets`（15 键+ConfigChanged）、`core/util/CategoryAlgo.ets`（CategoryDef/DEFAULT_CATEGORIES）、
> `model/DownloadTypes.ets`（ProxyInfo/ProxyType）、`pages/Index.ets`（Navigation(pathStack) :1194、汉堡菜单 12 项全禁用 :1000-1024）、
> `entryability/EntryAbility.ets`（onCreate :47 setColorMode 在 :52 Config.init **之前**）、`resources/base/element/string.json`（136 键）、
> `probe/core/{ProbeKit,ProbePage}.ets`、`probe/ProbeIndex.ets`（P0-U0…P4-U2）。

---

## 0. 冲突与拍板注记（必读）

1. **研究结论勘误①（FallbackUserAgent 不持久化=源缺陷）**：研究将 FallbackUserAgent 列为普通配置键。本会话通读 `ConfigIO.cs` 序列化段（`SerializeConfig` :328-465 全部 `Write*` 调用）与反序列化 `switch`（:76-300 全部 `case`）：**键表中没有 FallbackUserAgent**——源版在 Advanced 页改 UA（AdvancedSettingsView.xaml.cs:60）后重启即失（消费点 `SingleSourceHTTPDownloader.cs:523` 读的是构造默认值）。处置：鸿蒙版 `fallbackUserAgent` set 即持久化（修复数据丢失缺口），列入差异清单 D3。
2. **研究结论勘误②（44 键计数口径）**：源 ConfigIO 持久化**具名 38 字段**（32 标量+Proxy 1+Categories 1+UserCredentials 1+三扩展/RecentFolders 列表 4 中除 RecentFolders 已计入——准确清单见 §2.1）。鸿蒙侧落地 **47 键**：源 38 字段 1:1（Proxy 拆 5 平铺键 +4）+ 既有 schedule 4 键（非源持久化键，U3.2 DownloadSchedule 结构体布尔化先例）+ 0 其他。含 15 既有键，**新增 32 键**。
3. **NotificationTimeOut 拍板**：采纳研究建议——实例默认 **0**（Config.cs:44 属性初始化器）；`DefaultNotificationTimeOut=30000`（:42）为全仓无消费死常量（本会话 grep `NotificationTimeOut` 全源码核实：唯一出现点=ConfigIO 序列化/反序列化 :83-84/:405，无读取方），不移植。
4. **openQuestion 拍板①（categories/userCredentials 落地形式）**：采纳研究建议——preferences **JSON 字符串单键**（默认 5 分类/`[]`）。理由：源即整块二进制序列化（ConfigIO.cs:419-443），无按字段查询需求；U6.1 `/sync` 不消费分类。JSON 解析用 `PieceAlgo.parseChunksJson`（PieceAlgo.ets:348-380）同款"解析门"模式：逐字段 typeof 校验，任何不符回默认。
5. **openQuestion 拍板②（语言默认值与 zh-Hans 标签匹配）**：`language` 键默认 **`en-US`**（源默认 "English" 同貌；跟随系统是菜单第三档 'default'，非默认）。`setAppPreferredLanguage('zh-Hans')` 与 `resources/zh_CN` 目录的匹配度列 **P4-U3 探针 S4/S5 实证**；退化路径：若 zh-Hans 不命中 zh_CN 限定词，改目录名 `zh`（语言级限定词，命中面更宽）后重验——不阻塞编码，只影响资源目录名。
6. **RunOnLogon 不落键**：源 ConfigIO 序列化/反序列化两处均注释禁用（:373 注释 `//WriteBoolean(...RunOnLogon...)`、:202 `//case "RunOnLogon"`），属性本身委托 `PlatformHelper.EnableAutoStart`——鸿蒙自启=计划降级项 9，无键无 UI，与源"不持久化"同貌。
7. **Proxy 平铺 5 键**（研究建议采纳）：`proxyType/proxyHost/proxyPort/proxyUser/proxyPassword`。源 `Config.Proxy` 可空（`ProxyInfo?`），null 语义=`ProxyType.System`（NetworkSettingsView.xaml.cs:40 `?? ProxyType.System`）；平铺默认值 type=0/host=''/port=0 对全部消费方等价。`getProxyInfo(): ProxyInfo` 便捷组装方法供 U6.x HttpClient 消费，**本单元不接 HTTP 栈**。
8. **限速写回双语义并存（易踩，源码即如此）**：设置页 NetworkSettingsView.UpdateConfig :52-56 是 **raw 写入**（勾选=EnableSpeedLimit 原值、速度 TryParse 成功才写、**无** SpeedLimiterUIController.cs:22-27 的 `enabled?speed>0:false` 规范化）；而 U4.2 限速窗走 `Config.setSpeedLimit`（规范化+广播，语义冻结零改动）。处置：Config 新增 `setEnableSpeedLimitRaw`/`setDefaultDownloadSpeedRaw` 两 setter 专供设置页，**不得**复用 setSpeedLimit。
9. **module.json5 / main_pages.json 零改动**：本单元无新能力面（INTERNET 已有、deviceTypes 已含 2in1，本会话读 module.json5 核实；MonitorClipboard 消费方 ClipboardWatcher 归 U5.2）。Settings 走 Navigation/NavDestination（Index 既有 `pathStack` :123 首次启用），不注册 main_pages；探针页走 ProbeIndex 条件渲染（U0.1 惯例）。
10. **浏览器引导区/降级控件从 UI 隐藏，键照源默认保留**：监控页六浏览器启动按钮+两 URL 复制+引导文案三块（BrowserMonitoringView.xaml.cs:61-165）、网络页 `ND_SYSTEM_PROXY` 按钮（:68-71）、高级页关机/唤醒/自定义命令/杀毒/自启五组（AdvancedSettingsView :37-45）——按 MIGRATION_PLAN 降级清单与 U6 分期隐藏；对应 Config 键照源默认值照落（§2.1 标注"无 UI"）。`core/Links.ets` **不在本单元建**（URL 常量当前无任何消费点=死代码；U6.1 随消费方建立——修正研究注记）。
11. **深浅色映射拍板**：源仅一键 `AllowSystemDarkTheme`（默认 true，Win10 分支恒 true，App.xaml.cs:122-134），无"强制深色"档、运行期不重算。鸿蒙：true→`COLOR_MODE_NOT_SET`（跟随系统）、false→`COLOR_MODE_LIGHT`（API 签名本会话核实：ApplicationContext.d.ts:540 `setColorMode(colorMode: ConfigurationConstant.ColorMode): void`；常量 :90/:112/:134 NOT_SET=-1/DARK=0/LIGHT=1）。faqs-arkui-1266 指出 setColorMode 仅运行期有效 → **EntryAbility.onCreate 每次冷启按 Config 键重放**；现 EntryAbility.ets:47 无条件 NOT_SET 且在 Config.init 之前——本单元调序修复。

---

## 1. 目标文件清单（按实现顺序）

> 新 13 / 改 8，共 21 项（业务新 9+改 2；资源新 2+改 1；探针新 1+改 1；单测新 1+改 1；文档新 2）。`module.json5`、`main_pages.json`、`model/**`、`core/db/**`、`core/engine/**`、`components/*Dialog.ets`（U4.2 五对话框）**零改动**。业务文件禁 import `probe/**`（审查红线）。

| # | 文件 | 新/改 | 职责与对外导出 | dependsOn |
|---|---|---|---|---|
| 1 | `entry/src/main/ets/core/util/SettingParse.ets` | 新 | 设置页纯函数层（零 import，Hypium 直载）：`tryParseInt(text): number \| null`（Int32.TryParse 同貌 §3.3）、`parseExtensionList(raw): string[]`（逗号 split→trim→去空→**不去重** §3.2）、`parseCategoryTypes(raw): string[]`（先去 `\r\n` 同上+**去重保序**=HashSet 语义 §3.1）、`joinForEdit(list): string`（`join(',')`）、值域常量 `MIN_VIDEO_SIZE_CHOICES: number[]`（9 档）、`RANGE_MAX_PARALLEL/RANGE_TIMEOUT/RANGE_SEGMENTS/RANGE_RETRY`（1..50/1..300/1..64/1..100）、`clampToRange(v, min, max): number`（下拉回显防御） | — |
| 2 | `entry/src/main/ets/core/Config.ets` | 改 | **增量 +32 键**（§2.1 全表）：标量 getter/setter（沿用 read/write 私有工具与"set 即持久化"语义）、5 个 JSON 集合键（`getVideoExtensions/setVideoExtensions`、`fileExtensions`、`blockedHosts`、`recentFolders`、`getCategories/setCategories: CategoryDef[]`（import CategoryAlgo）、`getUserCredentials/setUserCredentials: UserCredential[]`（新增 `UserCredential` class：host/user/password））——init 时解析缓存、set 时写回 JSON；`getProxyInfo(): ProxyInfo`/`setProxyInfo(p)`（平铺 5 键组装/拆写）；raw 限速两 setter（注记 8）；`getLanguage/setLanguage`、`getAllowSystemDarkTheme/setAllowSystemDarkTheme`；`broadcastConfigChange()` 改 **public**（设置页保存链收尾调用）。**15 既有键/既有 setter/监听器注册表逐字节零改动** | — |
| 3 | `entry/src/main/ets/components/settings/SettingsSession.ets` | 新 | 五页 UpdateConfig 编排（对照 SettingsWindow.xaml.cs:68-78 `foreach page.UpdateConfig()`）：`class SettingsSession { registerUpdater(fn): void; unregisterUpdater(fn): void; updateAll(): void }`（注册序=构造序=源 pages 数组序：监控→常规→网络→凭据→高级；updateAll 单监听器异常吞掉不中断链，沿用 Config.ets:281-293 容错风格）。**不承载 populate**（各页 aboutToAppear 自读 Config=源 ctor foreach PopulateUI 的等价分散化） | — |
| 4 | `entry/src/main/resources/base/element/string.json` | 改 | 追加 §2.4 的 ~51 键（值=English.txt 原文；键名 camelCase 沿用工程约定；SETTINGS_ATUO_CAT 源拼写纠正 settings_auto_cat 同 D8 先例） | — |
| 5 | `entry/src/main/resources/zh_CN/element/string.json` | 新 | **全量中文**（既有 136+新增 ~51≈187 键）：源 `Lang/Chinese simplified.txt` 有值键逐串采用（如 SETTINGS_GENERAL=通用设置、DESC_NET1=连接超时时间(以秒为单位)）；源缺键（probe_*/lang_*/新增自定键）自译补齐。**不保留源 215/260 缺键英文回退的混合 UI 态**（差异 D8） | #4 |
| 6 | `entry/src/main/resources/en_US/element/string.json` | 新 | base 英文镜像（MIGRATION_PLAN §5 结构三目录；`setAppPreferredLanguage('en-US')` 显式命中 en_US，不依赖 base 兜底） | #4 |
| 7 | `entry/src/main/ets/components/settings/MonitoringSettingsTab.ets` | 新 | 监控页（ISettingsPage 同构，`@Component struct` 暴露 `populateUI()/updateConfig()`+`session` 属性）：三 TextArea（FileExtensions/VideoExtensions/BlockedHosts 显示 `join(',')`）+三个"默认"按钮（回填 DEFAULT_* join）+最小视频体积 9 档 Select+剪贴板/时间戳/媒体通知三 Toggle；updateConfig 用 parseExtensionList（不去重）；浏览器引导区不渲染（差异 D7）。aboutToAppear 注册 updater、aboutToDisappear 注销 | #1 #2 #3 #4 |
| 8 | `entry/src/main/ets/components/settings/GeneralSettingsTab.ets` | 新 | 常规页 + 同文件 `CategoryEditDialog`（@CustomDialog，模式=U4.2 DownloadSelectionDialog 内嵌 More 子窗先例）：进度窗/完成窗/自动开始/覆盖已有/深色主题/自动分类六 Toggle、临时文件夹与默认下载文件夹 TextInput（Browse 占位）、最大并发 Select(1..50)、双击行为 Select 2 项（0=ctx_open_folder/1=msg_open_file）；分类列表（@State 本地镜像）+添加/编辑/删除/恢复默认四钮：新增 Name=`util.generateRandomUUID()`（Guid 同貌）、编辑保留原 Name、FileTypes 解析=parseCategoryTypes（去重）、校验链 Name→FileTypes→Folder 弹 msg_cat_name_missing/msg_cat_file_types_missing/msg_cat_folder_missing | #1 #2 #3 #4 |
| 9 | `entry/src/main/ets/components/settings/NetworkSettingsTab.ets` | 新 | 网络页：超时(1..300)/分段(1..64)/重试(1..100)三 Select+限速 TextInput 三件套（onChange 仅数字过滤/失焦空·非法重置 "0"/保存 tryParseInt 失败不写 Config §3.4）+限速开关 Toggle+代理 Select 三档（NET_SYSTEM_PROXY/ND_NO_PROXY/ND_MANUAL_PROXY）仅 index==2 启用 host/port/user/pass 四输入、ND_SYSTEM_PROXY 按钮不渲染；updateConfig：端口 tryParseInt 失败→0（`Int32.TryParse(TxtProxyPort.Text, out int port)` 失败 port=0 同貌）、Proxy **无条件整块写回**（含全空） | #1 #2 #3 #4 |
| 10 | `entry/src/main/ets/components/settings/CredentialSettingsTab.ets` | 新 | 凭据页 + 同文件 `PasswordEditDialog`（@CustomDialog）：凭据列表（host/user/pass）增/改/删（新增/编辑经对话框、删除按选中索引）；校验链空 Host→msg_host_name_missing、空 User→msg_no_username；updateConfig=`setUserCredentials(本地列表)` | #2 #3 #4 |
| 11 | `entry/src/main/ets/components/settings/AdvancedSettingsTab.ets` | 新 | 高级页（降级区五组控件不渲染，仅剩 UA）：FallbackUserAgent TextInput + "Reset" 按钮（回填 DEFAULT_FALLBACK_USER_AGENT 常量=Config.cs:52 原串）；updateConfig 写 fallbackUserAgent + 五组隐藏键照 state 原值回写（state 由 Config 装载未被修改=无害幂等写，源隐藏控件仍参与 UpdateConfig 同构） | #2 #3 #4 |
| 12 | `entry/src/main/ets/pages/Settings.ets` | 新 | 设置页 NavDestination 内容：`@Component struct SettingsPage { initialTab: number }`——Tabs(barPosition: Start，页签序=源 SettingsWindow.xaml:25-38 五项：监控/常规/网络/凭据/高级) + 底部 Save(desc_save_q)/Cancel(nd_cancel)；Save=session.updateAll()（五页写 Config）→ 主题即时应用（`getContext().getApplicationContext().setColorMode(allowSystemDarkTheme ? NOT_SET : LIGHT)`）→ `Config.broadcastConfigChange()`（源 BroadcastConfigChange 同位）→ `pathStack.pop()`；Cancel=零写入直接 pop（源 :80-83 同貌）；`Helpers.RunGC()` 不移植（D9）。导出初始页常量 `SETTINGS_TAB_MONITORING=0`/`SETTINGS_TAB_GENERAL=1`（源 :49 `this(1)` 默认常规） | #2 #3 #7 #8 #9 #10 #11 #4 |
| 13 | `entry/src/main/ets/components/LanguageDialog.ets` | 新 | 语言对话框 @CustomDialog（源 LanguageSettingsWindow 同位；由 Index 菜单 menu_lang 打开）：Select 三项（lang_follow_system→'default'、lang_chinese→'zh-Hans'、lang_english→'en-US'，初选=Config.getLanguage() 反查）；OK→`i18n.System.setAppPreferredLanguage(tag)` + `Config.setLanguage(tag)` + 关窗（**即时生效**，差异 D2；'default' 运行期切回跟随系统的生效时机由探针 S4 观测）；MSG_LANG2 重启提示不渲染（D2 对偶） | #2 #4 |
| 14 | `entry/src/main/ets/pages/Index.ets` | 改 | 三处接线（汉堡菜单 :1000-1024 其余 9 项维持占位禁用）：①`title_settings`→`this.pathStack.pushPathByName('settings', SETTINGS_TAB_GENERAL)`；②`settings_monitoring`→`pushPathByName('settings', SETTINGS_TAB_MONITORING)`（源 ShowSettingsDialog 忽略参数恒开 1 / ShowBrowserMonitoringDialog 开 0 同貌）；③`menu_lang`→开 LanguageDialog（CustomDialogController，模式同既有 dialogController）。Navigation 追加 `.navDestination(this.settingsNavDestination)` builder（name==='settings' → `NavDestination(){ SettingsPage({ initialTab: param }) }.title($r('app.string.title_settings'))`；param 窄化 `typeof param === 'number' ? param : 1`）。**既有事件面/字段写序逐字节不动** | #4 #12 #13 |
| 15 | `entry/src/main/ets/entryability/EntryAbility.ets` | 改 | onCreate 两处：①调序——`Config.init(this.context)` 提到主题应用之前；②主题重放——`setColorMode(config.getAllowSystemDarkTheme() ? COLOR_MODE_NOT_SET : COLOR_MODE_LIGHT)`（替换现 :47 无条件 NOT_SET）；③语言重放——`i18n.System.setAppPreferredLanguage(config.getLanguage())`（'en-US'/'zh-Hans'/'default' 三值统一调用，先于 loadContent 保证首帧资源正确）。**want 路由/数据层挂接/Scheduler 启动零改动** | #2 |
| 16 | `entry/src/main/ets/probe/units/ProbeSettings.ets` | 新 | P4-U3 探针（§6 五步）：S1 标量键默认读回 / S2 集合键读回 / S3 写回-读回-恢复闭环（finally 恢复）/ S4 语言+主题应用观测 / S5 人工走查清单 31 项。复用 ProbePage 脚手架（autoStart：S1~S4 自动、S5 manual） | #1 #2 #15 |
| 17 | `entry/src/main/ets/probe/ProbeIndex.ets` | 改 | PROBE_UNITS 追加 `{unitId:'P4-U3'}` 表项 + else-if 分支 `ProbeSettings()`（U0.1 注册惯例） | #16 |
| 18 | `entry/src/test/SettingParse.test.ets` | 新 | §7 Hypium 用例 22 条（tryParseInt 10 / parseExtensionList 5 / parseCategoryTypes 5 / joinForEdit+clamp 2） | #1 |
| 19 | `entry/src/test/List.test.ets` | 改 | testsuite 追加 SettingParse 注册 + 头部注释补 U4.3 行 | #18 |
| 20 | `docs/probe/PROBE-u4-3-settings-i18n-theme.md` | 新 | 探针手册：运行命令 + 人工配合步骤（S5 走查清单 31 项全文 + zh-Hans 目录匹配退化说明） | #16 |
| 21 | `docs/probe/EXPECT-u4-3-settings-i18n-theme.json` | 新 | verify 期望表（S1~S5 键值期望；zh-Hans 匹配项标注环境敏感） | #20 |

---

## 2. 数据模型与表结构（对照源码逐一核对）

### 2.1 Config 键全表（47 键 = 源 38 持久化字段 1:1 + schedule 4 + Proxy 拆分 +4）

**A. 既有 15 键（本单元零改动，列出仅为全表完整性）**

| 键 | 类型 | 默认 | 源锚 | 消费方 |
|---|---|---|---|---|
| downloadDir | string | `<filesDir>/Downloads` | Config.cs:154-155（D6 沙箱化先例） | U1.2/U4.2 |
| tempDir | string | `<filesDir>/temp` | Config.cs:248 | U2.2 StateStore |
| networkTimeout | number | 30 | Config.cs:120 | U1.2 HttpClient |
| maxRetry / retryDelay | number | 10 / 10 | Config.cs:100/:102 | U3.2 |
| maxSegments | number | 8 | Config.cs:122 | U2.1 |
| maxParallelDownloads | number | 3 | Config.cs:104 | U3.1 |
| enableSpeedLimit / defaultDownloadSpeed | boolean/number | false/0 | Config.cs:126/:124 | U3.2/U4.2 |
| scheduleEnabled/startMinutes/endMinutes/days | boolean/number×3 | false/0/0/0 | DownloadSchedule.cs（D6/D7） | U3.2 Scheduler |
| showProgressWindow / showDownloadCompleteWindow | boolean | true/true | Config.cs:106/:108 | U4.2 |

**B. 新增 32 键**

| 键 | 类型 | 默认 | 源锚（ConfigIO 反序列化 case 行号为持久化键证据） | 设置页控件 | 消费方 |
|---|---|---|---|---|---|
| notificationTimeOut | number | **0** | Config.cs:44（:42 死常量 30000 不用，注记 3） | 无 UI（键照源保留） | 无（源亦无消费） |
| isBrowserMonitoringEnabled | boolean | true | Config.cs:46；ConfigIO.cs:169 | 无 UI（键保留） | U6.1 监视链 |
| showNotification | boolean | true | Config.cs:50；ConfigIO.cs:86 | 监控页 Toggle（MSG_SHOW_MEDIA_NOTIFICATION） | U6.x 媒体通知 |
| fallbackUserAgent | string | `'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/97.0.4692.99 Safari/537.36'` | Config.cs:52-54；**ConfigIO 键表无此键**（勘误①） | 高级页 TextInput+Reset | U1.2 HttpClient 手动下载 UA |
| videoExtensionsJson | string(JSON) | 15 项 `'["MP4","M3U8","F4M","WEBM","OGG","MP3","AAC","FLV","MKV","DIVX","MOV","MPG","MPEG","OPUS","MPD"]'` | Config.cs:56-62；ConfigIO.cs:245（**不带点大写**） | 监控页 TextArea | U6.2 VideoUrlHelper |
| fileExtensionsJson | string(JSON) | 23 项 `'["3GP","7Z","AVI","BZ2","DEB","DOC","DOCX","EXE","ISO","MSI","PDF","PPT","PPTX","RAR","RPM","XLS","XLSX","SIT","SITX","TAR","JAR","ZIP","XZ"]'` | Config.cs:64-70；ConfigIO.cs:229 | 监控页 TextArea | U6.2 |
| blockedHostsJson | string(JSON) | 3 项 `'["update.microsoft.com","windowsupdate.com","thwawte.com"]'`（**源拼写 thwawte 原样**） | Config.cs:72-77；ConfigIO.cs:101 | 监控页 TextArea | U6.2 |
| language | string | **'en-US'** | Config.cs:79；ConfigIO.cs:175（差异 D1：tag 化） | 语言对话框（菜单） | EntryAbility 重放 |
| allowSystemDarkTheme | boolean | true | Config.cs:81；ConfigIO.cs:223 | 常规页 Toggle | EntryAbility/Settings 重放 |
| recentFoldersJson | string(JSON) | `'[]'` | Config.cs:94；ConfigIO.cs:237 | 无 UI | 后续新建对话框（登记） |
| folderSelectionMode | number | 0（Auto） | Config.cs:96（枚举 `FolderSelectionMode{Auto,Manual}` Config.cs:505-508）；ConfigIO.cs:163 | 常规页 Toggle（勾=Auto） | U5.2/U6.2 分类落盘 |
| fileConflictResolution | number | 0（AutoRename） | Config.cs:98（枚举 Config.cs:510-514）；ConfigIO.cs:160 | 常规页 Toggle（勾=Overwrite=1） | U1.2 落盘命名（登记核对） |
| startDownloadAutomatically | boolean | false | Config.cs:110；ConfigIO.cs:217 | 常规页 Toggle | 与 U4.2 选择窗默认动作联动（登记） |
| fetchServerTimeStamp | boolean | false | Config.cs:112；ConfigIO.cs:157 | 监控页 Toggle | U6.x |
| monitorClipboard | boolean | false | Config.cs:114；ConfigIO.cs:190 | 监控页 Toggle | U5.2 ClipboardWatcher（ConfigChanged 消费点已建广播链） |
| minVideoSize | number | 1024（KB） | Config.cs:116；ConfigIO.cs:187（消费 `MinVideoSize*1024` 字节=VideoUrlHelper.cs:69） | 监控页 Select 9 档 | U6.2 |
| shutdownAfterAllFinished | boolean | false | Config.cs:128；ConfigIO.cs:214 | **无 UI（降级）** | 无 |
| keepPCAwake | boolean | true | Config.cs:130；ConfigIO.cs:172 | **无 UI（降级）** | 无 |
| runCommandAfterCompletion | boolean | false | Config.cs:132；ConfigIO.cs:199 | **无 UI（降级）** | 无 |
| afterCompletionCommand | string | ''（源 null→`?? string.Empty`，ConfigIO.cs:294-299 WriteString 帮助方法逐字核实） | Config.cs:134；ConfigIO.cs:89 | **无 UI（降级）** | 无 |
| scanWithAntiVirus | boolean | false | Config.cs:136；ConfigIO.cs:205 | **无 UI（降级）** | 无 |
| antiVirusExecutable | string | '' | Config.cs:138；ConfigIO.cs:98 | **无 UI（降级）** | 无 |
| antiVirusArgs | string | '' | Config.cs:140；ConfigIO.cs:95 | **无 UI（降级）** | 无 |
| proxyType | number | 0（System） | ProxyInfo.cs:18-22 枚举 `System=0/Direct=1/Custom=2`；ConfigIO.cs:284/:497 | 网络页 Select | U6.x HttpClient（getProxyInfo 组装） |
| proxyHost | string | '' | ProxyInfo.cs:12；ConfigIO.cs:491 | 网络页 TextInput | 同上 |
| proxyPort | number | 0 | ProxyInfo.cs:14；ConfigIO.cs:494 | 网络页 TextInput | 同上 |
| proxyUser | string | '' | ProxyInfo.cs:15；ConfigIO.cs:500 | 网络页 TextInput | 同上 |
| proxyPassword | string | '' | ProxyInfo.cs:16；ConfigIO.cs:503 | 网络页 TextInput | 同上 |
| doubleClickOpenFile | boolean | false | Config.cs:144；ConfigIO.cs:226 | 常规页 Select（false→0 打开文件夹/true→1 打开文件，GeneralSettingsView.xaml.cs:48/:72 同貌） | U5.2 双击动作 |
| userSelectedDownloadFolder | string | '' | Config.cs:152；ConfigIO.cs:92 | 无 UI | U5.2 picker |
| categoriesJson | string(JSON) | 5 预定义分类（=CategoryAlgo.DEFAULT_CATEGORIES 逐串，CategoryAlgo.ets:51-63 已逐串核对 Config.cs:157-224） | Config.cs:157-226；ConfigIO.cs:419-434 | 常规页分类列表 | U5.2/U6.2 分类落盘 |
| userCredentialsJson | string(JSON) | `'[]'` | Config.cs:228；ConfigIO.cs:436-447（Host/User/Password 3 字段） | 凭据页列表 | U6.x 401 挑战 |

> 未落键：RunOnLogon（注记 6）。`DataDir/AppDir` 为源静态路径非持久化键（沙箱由 context 承载）。临时目录既有键 tempDir 对照源 TempDir=ConfigIO.cs:220。

### 2.2 JSON 集合键形状与解析门（PieceAlgo.parseChunksJson 模式逐字套用）

```
interface StringListDoc { items: string[] }                       // 扩展名/屏蔽主机/最近目录：{"items":["MP4",...]}
interface CategoryDoc { name: string; displayName: string; fileExtensions: string[];   // 带点大写（'.DOC'）
  defaultFolderName: string; isPredefined: boolean }              // = CategoryDef 字段 1:1
interface CategoryListDoc { items: CategoryDoc[] }
interface UserCredentialDoc { host: string; user: string; password: string }  // = 源 PasswordEntry 3 字段
interface UserCredentialListDoc { items: UserCredentialDoc[] }
```

- 解析门规则（对照 PieceAlgo.ets:350-380 逐型）：`JSON.parse(text)` → `Object | null` → `as XxxListDoc` → 逐字段 `typeof`/`Array.isArray` 校验 → 任一不符返回 null（getter 回默认值，记 hilog warn）。**禁 any、禁无门 as 直转**。
- 序列化：`JSON.stringify({items: list})`（包装对象防裸数组边界，与 chunks.json 同策略）。
- Config 内存缓存：init() 一次性解析（失败回默认）；setXxx 更新缓存+写 JSON 串。getter 返回**缓存数组拷贝**（防外部改写内部态）。

### 2.3 枚举/值域映射表（UI 控件 ↔ 落库值）

| 控件 | 落库键 | 控件值域 | 落库值 | 源锚 |
|---|---|---|---|---|
| 常规页"覆盖已有文件" Toggle | fileConflictResolution | 勾/不勾 | 1（Overwrite）/0（AutoRename） | GeneralSettingsView.xaml.cs:42/:62-63 |
| 常规页"自动分类" Toggle | folderSelectionMode | 勾/不勾 | 0（Auto）/1（Manual） | :46/:68-69（注意与上条 0 值语义**方向相反**） |
| 常规页"双击行为" Select | doubleClickOpenFile | index 0/1 | false/true | :48（false→0=CTX_OPEN_FOLDER）/:72（index==1→true） |
| 网络页"代理类型" Select | proxyType | index 0/1/2 | 0 System/1 Direct/2 Custom | NetworkSettingsView.xaml.cs:40/:60；仅 index==2 启用四输入 :73-77 |
| 监控页"最小视频体积" Select | minVideoSize | 9 档 | 128/256/512/1024/2048/4096/8192/16384/32768（KB） | BrowserMonitoringView.xaml.cs:33 |
| 网络页三 Select | networkTimeout/maxSegments/maxRetry | 1..300/1..64/1..100 | 同值 | NetworkSettingsView.xaml.cs:28-30 |
| 常规页"最大并发" Select | maxParallelDownloads | 1..50 | 同值 | GeneralSettingsView.xaml.cs:34 |

### 2.4 资源键表（base 追加 ~51 键；zh_CN 值来源=Lang/Chinese simplified.txt 逐串）

新增键（值=English.txt 原文；行号为 English.txt 行号）：`settings_general`(:122)、`settings_network`(:123)、`settings_cred`(:124)、`settings_adv`(:125)、`desc_save_q`(:103 Save)、`desc_filetypes`(:130)、`desc_def`(:131 Defaults 按钮)、`desc_videotypes`(:132)、`lbl_min_video_size`(:133)、`desc_siteexceptions`(:134)、`menu_clip_add`(:135)、`lbl_get_timestamp`(:136)、`msg_show_media_notification`(:242)、`show_dwn_prg`(:137)、`show_dwn_complete`(:138)、`lbl_start_auto`(:139)、`lbl_overwrite_existing`(:140)、`lbl_temp_folder`(:141)、`msg_max_download`(:142)、`settings_auto_cat`(:147，源拼写 ATUO 纠正)、`settings_folder`(:148)、`settings_dark_theme`(:149，**值去掉 "(Require app restart)"**，D2)、`settings_cat`(:143)、`settings_cat_name`(:144)、`settings_cat_types`(:145)、`settings_cat_folder`(:146)、`settings_cat_add`(:150)、`settings_cat_edit`(:151)、`msg_double_click_action`(:205)、`msg_open_file`(:206)、`btn_browse`(:58)、`msg_halt`(:157)、`msg_awake`(:158)、`exec_cmd`(:159)、`exe_anti_vir`(:160)、`antivir_cmd`(:161)、`antivir_args`(:162)、`auto_start`(:163)、`msg_fallback_ua`(:207)、`desc_net1`(:152)、`desc_net2`(:153)、`net_max_retry`(:154)、`desc_host`(:156)、`desc_net7`(:72)、`desc_net8`(:73)、`msg_host_name_missing`(:197)、`msg_cat_name_missing`(:194)、`msg_cat_file_types_missing`(:195)、`msg_lang1`(:43)、`lang_follow_system`/`lang_chinese`/`lang_english`（自定键：Follow system/Chinese/English）、`probe_p4u3_title`/`probe_p4u3_check_hint`（探针页，沿用 probe_p4u1_* 命名模式）。

复用既有键：`settings_monitoring`、`nd_cancel`、`ctx_open_folder`（双击组合框项 0）、`msg_ok`、`nd_no_proxy`/`nd_manual_proxy`/`net_system_proxy`/`proxy_host`/`proxy_port`/`msg_speed_limit`/`desc_net4`、`msg_cat_folder_missing`、`msg_no_username`、`desc_user`/`desc_pass`、`title_settings`、`menu_lang`。

zh_CN 中文锚（Chinese simplified.txt 逐串核实存在）：SETTINGS_GENERAL=通用设置、SETTINGS_NETWORK=网络设置、SETTINGS_CRED=密码管理、SETTINGS_ADV=高级设置、DESC_SAVE_Q=保存、DESC_FILETYPES=XDM将自动从浏览器接管下载以下类型的文件、DESC_DEF=默认、LBL_MIN_VIDEO_SIZE=下载视频的最小体积、DESC_SITEEXCEPTIONS=不自动从以下网站捕获下载、MENU_CLIP_ADD=监视剪贴板、LBL_GET_TIMESTAMP=从服务器获取时间戳、SHOW_DWN_PRG=显示下载进度窗口、SHOW_DWN_COMPLETE=显示下载完成窗口、LBL_START_AUTO=自动开始下载、LBL_OVERWRITE_EXISTING=覆盖已有文件、LBL_TEMP_FOLDER=缓存文件夹、MSG_MAX_DOWNLOAD=最大并发数、SETTINGS_ATUO_CAT=根据文件类型自动选择保存位置、SETTINGS_FOLDER=默认保存位置、SETTINGS_CAT=下载类别、SETTINGS_CAT_NAME=类别名、SETTINGS_CAT_TYPES=文件类型、SETTINGS_CAT_FOLDER=保存到、DESC_NET1=连接超时时间(以秒为单位)、DESC_NET2=下载分段数、NET_MAX_RETRY=最大重试次数、MSG_HALT=完成全部下载后关闭电脑、MSG_AWAKE=下载时阻止电脑休眠与睡眠、EXEC_CMD=完成全部下载后运行该程序、EXE_ANTI_VIR=下载后使用防病毒软件扫描文件、ANTIVIR_CMD=防病毒软件路径、ANTIVIR_ARGS=命令行参数、AUTO_START=开机时启动XDM、MSG_FALLBACK_UA=用户代理(如果手动添加下载任务)、MSG_DOUBLE_CLICK_ACTION=双击下载项、MSG_OPEN_FILE=打开文件、CTX_OPEN_FOLDER=打开目录、MSG_CAT_NAME_MISSING 等（校验/凭据文案同文件逐串取）。

---

## 3. 关键算法翻译说明

> 本单元**无**分段/偏移/限速数学（U2.3/U3.2 已收口）。纯逻辑=文本解析/校验/规范化（§3.1~3.3）+ 保存状态机与广播链（§3.4）。线程模型：无新增长任务，全部主线程同步（§3.5）。

### 3.1 parseCategoryTypes（分类 FileTypes 解析；CategoryEditWindow 输入→HashSet 语义）

源：`dlg.FileTypes.Replace("\r\n", "").Split(',').Select(x => x.Trim()).Where(x => x.Length > 0)` → `new HashSet<string>(...)`（GeneralSettingsView.xaml.cs:86-87/:108-109）。
翻译（保留顺序与去重语义）：

```
parseCategoryTypes(raw: string): string[]
  1. raw = raw.replaceAll('\r', '').replaceAll('\n', '')   // Replace("\r\n","") 等价：任意 CR/LF 全删（源按整串替换两字符，逐字符删更稳且输入等价）
  2. parts = raw.split(',')
  3. 逐项 trim()
  4. 过滤 length === 0
  5. 去重：C# HashSet<string> add-only 迭代序=插入序 → 首次出现保留、后现重复丢弃（线性查已有元素）
```

单测锁定：`' .MP4 ,.MP4,\r\n.MKV,,' → ['.MP4','.MKV']`（去重保序）、空串→`[]`、全逗号→`[]`、trim 生效。

### 3.2 parseExtensionList（监控页三列表解析；**不去重**）

源：`TxtDefaultFileTypes.Text.Split(',').Select(x => x.Trim()).Where(x => x.Length > 0).ToArray()`（BrowserMonitoringView.xaml.cs:52-54——与分类不同：无 HashSet、无 CRLF 预处理）。翻译同 §3.1 步骤 2-4 **无步骤 1/5**（保留重复项，`'MP4,MP4' → ['MP4','MP4']` 单测锁定）。显示回填 `joinForEdit = list.join(',')`（:40-42 `string.Join(",", ...)` 同貌）。

### 3.3 tryParseInt（Int32.TryParse 同貌；限速/端口保存用）

```
tryParseInt(text: string): number | null
  1. 空串 → null
  2. 可选前导 '+'/'-'（Int32 默认 NumberStyles.Integer 允许符号）；'-' 后无数字 → null
  3. 其余字符必须全为 [0-9]（小数点/字母/空白 → null；源 Pasting/PreviewTextInput 双过滤器已挡非数字键入，
     此处仅防御粘贴与失焦残留——空白按非法处理，实测不可达的 .NET 宽松分支不移植）
  4. 数值 > 2147483647 或 < -2147483648 → null（Int32 溢出 TryParse 返回 false 同貌）
```

三消费点语义分立（勿合并，源码即三条规则三处）：
- **输入过滤**（NetworkSettingsView.xaml.cs:79-82 PreviewTextInput）：TextInput.onChange 过滤，非数字字符不进 state（`e.Handled` 同义：onChange 内对上次合法值回退）。
- **失焦重置**（:100-115 LostFocus）：空或 tryParseInt===null → 文本重置 `"0"`。
- **保存解析**（:52-55 UpdateConfig）：`tryParseInt` 失败 → **不写 Config（保留旧值）**，无提示无重置；端口解析失败 → 0（`Int32.TryParse(TxtProxyPort.Text, out int port)` 失败 port=0 同貌，:57）。

### 3.4 保存状态机与 ConfigChanged 广播链

```
SettingsPage Save 钮（对照 SettingsWindow.xaml.cs:68-78 BtnOK_Click 逐行）：
  1. session.updateAll()            // foreach page.UpdateConfig()：注册序=页序=源 pages 数组序，
                                    //   每页自读自身 @State → Config.setXxx（单页解析失败键跳过=保留旧值）
  2. 主题即时应用                    // 源无此步（启动期一次性）；D2 改进：
                                    //   setColorMode(allowSystemDarkTheme ? NOT_SET : LIGHT)
  3. Config.broadcastConfigChange() // ApplicationContext.cs:109-112 事件名 "ConfigChanged" 同位；
                                    //   广播一次（各页 setter 自身不广播，setSpeedLimit 既有自广播不动——
                                    //   设置页 raw setter 不走它，无重复广播）
  4. pathStack.pop()                // Close() 同位；Helpers.RunGC() 不移植（D9）
Cancel 钮：pathStack.pop()（零写入，:80-83 同貌）
```

ConfigChanged 消费点（广播链先建，本单元无新消费者）：ClipboardMonitor（ClipboardMonitor.cs:27-36 按 MonitorClipboard 启停→U5.2）、进度窗限速文案（DownloadProgressWindow.xaml.cs:56-63→U4.2 host 已监听 setSpeedLimit 面，设置页改限速后同样刷新）。

语言对话框 OK（LanguageSettingsWindow.xaml.cs:76-85 同位+D2 改进）：`i18n.System.setAppPreferredLanguage(tag)` → `Config.setLanguage(tag)` → 关窗（源顺序=先写 Config 后 SaveConfig 后关窗；setAppPreferredLanguage 失败 BusinessError 890001 catch 后不写键不关窗并记日志）。

### 3.5 线程模型映射（对照源 Dispatcher 模型）

源五页 PopulateUI/UpdateConfig 全在 WPF UI 线程（MessageBox/控件访问同线程），广播经 `Dispatcher.BeginInvoke` 投递 UI 线程。ArkTS 映射：全部 **UI 主线程同步执行**（ArkUI 单线程事件模型天然等价，无 TaskPool 需求）；preferences `putSync`+`flush()` 异步落盘沿用 Config.ets:363-389 既有模式（flush 失败仅记日志）；`setAppPreferredLanguage`/`setColorMode` 均 main-thread API（ApplicationContext.d.ts:545 "can be called only by the main thread"），onCreate/Save 回调链皆主线程——合规。集合 JSON 每键 ≤ 数十 KB 串，主线程 parse 开销 µs 级，不构成任务池场景。

---

## 4. 与源码的有意差异清单

| # | 差异 | 理由（计划/平台依据） |
|---|---|---|
| D1 | `language` 存 i18n tag（'en-US'/'zh-Hans'/'default'，默认 'en-US'），非源 index.txt 显示名；语言菜单 25 语言→三选项 | 鸿蒙 i18n 机制（setAppPreferredLanguage 按 tag）；资源面只有中英两套 |
| D2 | 语言/主题**即时生效**（源改语言需重启 MSG_LANG2、主题仅进程启动期一次性）；`settings_dark_theme` 值去掉 "(Require app restart)" | UNIT_CATALOG U4.3 验收"语言切换即时生效"；MSG_LANG2 重启提示不渲染 |
| D3 | `fallbackUserAgent` 持久化（源 ConfigIO 键表遗漏，输入重启即失——勘误①） | 修复数据丢失缺陷；Config"set 即持久化"既有语义自然覆盖 |
| D4 | `notificationTimeOut` 默认 0（30000 死常量不移植）；键落库无 UI | 源运行时无消费；键照源 38 字段全落 |
| D5 | categories/userCredentials 以 JSON 单键落 preferences；分类目录存 `defaultFolderName` 尾段（完整目录=downloadDir 拼接），分类编辑对话框 Folder 输入为子文件夹名、Browse 占位（U5.2 接 picker） | 决策 10 存储等价 + 沙箱无自由路径（D6/D7 既有先例） |
| D6 | Proxy 平铺 5 键（源单可空字段序列化）；null Proxy 语义由默认 type=0 承载；本单元不接 HTTP 栈 | 研究建议；消费方 U6.x |
| D7 | UI 隐藏：监控页浏览器引导区（六浏览器按钮/两 URL 复制/DESC_MONITORING_1 等引导文案）、网络页 ND_SYSTEM_PROXY、高级页关机/唤醒/命令/杀毒/自启五组；`RunOnLogon` 不落键；对应 Config 键照源默认保留 | MIGRATION_PLAN 降级清单 2/5/6/9 + U6 分期；源 ConfigIO 亦不持久化 RunOnLogon |
| D8 | zh_CN 全量覆盖（不保留源 Chinese simplified.txt 215/260 缺键英文回退的混合 UI 态，缺键自译）；`en_US` 目录显式建立（=base 镜像） | 走查观感；MIGRATION_PLAN §5 三目录结构 |
| D9 | `Helpers.RunGC()`（BtnOK_Click 尾）不移植 | 无对应 API，无实义（托管 GC 提示） |
| D10 | 分类新增 Name 用 `util.generateRandomUUID()` 替代 `Guid.NewGuid().ToString()` | 平台对应物（同为随机 GUID 串，事件面键语义不变） |
| D11 | module.json5 / main_pages.json 零改动 | 无新能力面（INTERNET/2in1 已有）；Settings 走 NavDestination 不注册页 |
| D12 | `SETTINGS_ATUO_CAT` 源拼写纠正为 `settings_auto_cat`（源键值语义不变） | D8 拼写纠正既有先例（DefaltDownloadSpeed→defaultDownloadSpeed） |
| D13 | 监控页/凭据页对 settings 的"删除按选中索引"交互以列表选中态实现（源 LvPasswords.SelectedIndex） | ArkUI List 选中模型对应物 |
| D14 | 高级页 UA Reset 钮即时写 Config（setFallbackUserAgent，R2-F1 对照审查修复）：源 BtnUserAgentReset_Click（AdvancedSettingsView.xaml.cs:73-76）即写 Config.Instance.FallbackUserAgent、不关窗、不动文本框（OK 时 UpdateConfig 会以文本框旧值覆盖——源自身怪癖）；鸿蒙版 Reset 同步回填 state+写 Config（state 与 Config 恒一致，规避源覆盖怪癖）；细微差=鸿蒙 set 即持久化 vs 源仅写内存（SaveConfig 在 OK 键，Reset→Cancel 后源重启失、鸿蒙已落库） | 源可观测行为对齐（Reset→Cancel→重开显示默认 UA）+Config「set 即持久化」既有语义（D3 同族） |

---

## 5. 单元验收测试要点

**[A] 静态门禁（每轮返修后全量 hvigor 构建）**
- 编译零 error 零新 warning；ArkTS 严格子集（禁 any、对象字面量带类型、JSON.parse 走解析门模式）。
- 审查红线：`pages/**`、`components/**`、`core/**` 零 `probe/` import；`EntryAbility.ets` 零 `[XDM_PROBE]` 输出；业务日志 domain 0x0000。
- 冻结面核对：Config 既有 15 键 setter/getter/`setSpeedLimit`/`setSchedule`/监听器注册表逐字节未动；Index 五事件处理器/字段写序未动。

**[A] Hypium 本地单测（`hvigorw test`，SettingParse 22 条）**——§7 用例表。

**[P] 探针 P4-U3（真机优先/模拟器兜底，PROBE-u4-3 手册 + EXPECT 表）**
- S1/S2 默认值读回：47 键中可观测子集与 §2.1 表逐一对照（UA 前缀截断、thwawte 保真、15/23/3/5/0 计数）。
- S3 写回闭环：写→读回→finally 恢复，恢复后与 S1 基线一致（key=restored 值相等）。
- S4 语言/主题：setAppPreferredLanguage('zh-Hans') 后 `getAppPreferredLanguage()='zh-Hans'`；setColorMode 应用观测；恢复后读回原值。**环境敏感项**：zh-Hans ↔ zh_CN 目录命中与否在 S5 走查判定（EXPECTED 表按 observe-both 写：界面变中文=命中；仍英文=未命中走 zh 目录退化，不判 FAIL 而判 CONTINGENCY）。
- S5 人工走查 31 项（§6 步骤设计附清单）。

**[H] Phase 4 走查（并入 Phase 级验收）**：对照 XDM 2023 设置五窗逐控件走查（降级控件确认隐藏）；语言/主题/读写闭环三验收项。

---

## 6. 探针步骤设计（P4-U3 · ProbeSettings.ets）

会话模型：autoStart=false（勘误：初稿误写 true，实现与 EXPECT/手册均为双会话模型——主会话 S1~S4+占位、S5 单步）（S1~S4 自动顺序执行，全部主线程同步无 await 依赖）；S5 manual 单步（勾选清单后发射）。红线：S3/S4 全部写操作 try/finally 恢复基线（S1 先采基线）；探针值只写观测事实不写 PASS/FAIL；ProbeKit.emit 逐步骤单行。**前置人工步骤：无**（纯本机面，无需测试源）。

| 步骤 | autoRun | 操作 | 观测点（key=value） |
|---|---|---|---|
| BEGIN | — | ProbeKit.begin('P4-U3', filesDir) | runId、filesDir |
| S1 标量键默认读回 | ✔ | 逐 getter 读 Config（不做任何写） | `notificationTimeOut=0 isBrowserMonitoring=true showNotification=true lang=en-US darkTheme=true maxParallel=3 timeout=30 segments=8 retry=10 retryDelay=10 minVideo=1024 folderSel=0 conflict=0 startAuto=false fetchTs=false monitorClip=false dblClick=false shutdown=false keepAwake=true runCmd=false antivirus=false proxyType=0 proxyPort=0 uaPrefix=Mozilla/5.0 userSelFolder=0 credCount=0`（userSelFolder=0 表空串；UA 只发前缀） |
| S2 集合键读回 | ✔ | getVideoExtensions().length 等 | `videoExts=15 fileExts=23 blockedHosts=3 blockedHost0=update.microsoft.com blockedHost2=thwawte.com categories=5 catVideosExts=13 catDocsExts=7 recentFolders=0 videoFirst=MP4 videoLast=MPD` |
| S3 写回-读回-恢复 | ✔ | try{ setNetworkTimeout(120)→读；setMaxSegments(16)→读；setMinVideoSize(2048)→读；setProxyInfo(Custom/10.0.0.1/8080/u/p)→读；setFileConflictResolution(1)→读；setCategories(默认+1 自定义[parseCategoryTypes('.MP4,.MP4,.MKV')])→读 count；setUserCredentials(1 条)→读 count } finally{ 全部恢复基线 } 再读 | `timeoutW=120 timeoutR=120 timeoutRestored=30 segmentsW=16 segmentsR=16 segmentsRestored=8 minVideoW=2048 minVideoR=2048 minVideoRestored=1024 proxyW=2 proxyR=2 proxyHostR=10.0.0.1 proxyPortR=8080 proxyRestored=0 conflictW=1 conflictR=1 conflictRestored=0 catW=6 catR=6 catParseDedup=2 catRestored=5 credW=1 credR=1 credRestored=0`（catParseDedup=2：'.MP4,.MP4,.MKV' 去重后 2 项） |
| S4 语言+主题应用 | ✔ | 读 language 基线 → `i18n.System.setAppPreferredLanguage('zh-Hans')` → `getAppPreferredLanguage()` 读回 → 恢复基线 tag → 读回；`setColorMode(LIGHT)` → emit applied → `setColorMode(基线映射)` → emit applied | `langBefore=en-US langSet=zh-Hans langReadback=zh-Hans langRestored=en-US langAfterReadback=en-US themeApply1=light themeApply2=notset themeKeyBaseline=true`（readback 为系统层事实；UI 是否随切在 S5 判） |
| S5 走查清单 31 项 | ✘ | 人工在设置页逐项核对后勾选（Toggle 清单，模式=P4-U1 S4） | `checked=<n> total=31 unchecked=<k>` |
| SUMMARY/END | — | ProbeKit 聚合 | SUMMARY 单行、END ok/steps/elapsedMs |

**S5 走查清单 31 项**（标题只进 UI 不进日志）：
监控页 6 项：①三列表默认值原文回显（含 thwawte）②三个"默认"钮回填 ③改扩展保存→重进保持 ④最小体积 9 档可选回显 ⑤三 Toggle 回显保存 ⑥浏览器引导区不渲染。常规页 13 项：⑦进度窗/完成窗/自动开始 Toggle ⑧覆盖已有勾选=Overwrite ⑨深色主题 Toggle ⑩临时/下载文件夹文本回显 ⑪最大并发 1..50 ⑫自动分类 Toggle ⑬双击行为两项 ⑭分类默认 5 项 ⑮新增校验三弹（空名/空类型/空目录）⑯新增成功入列表 ⑰编辑保留 Name（UUID 键不变）⑱删除按选中 ⑲恢复默认=5 项。网络页 5 项：⑳三 Select 回显 ㉑限速输入仅数字 ㉒失焦空/非法重置 0 ㉓保存非法不回写（改后重进见旧值）㉔代理三档仅 Custom 启用+保存回显。凭据页 3 项：㉕增改删 ㉖空 Host 校验 ㉗空 User 校验。高级页 2 项：㉘UA 回显+Reset 回填 ㉙降级五组不渲染。全局 2 项：㉚保存关闭重进回读+取消零写入 ㉛语言菜单选中文→主界面文案即时变中文（zh_CN 目录命中判定点；未命中登记退化）。

日志标记样例（verify 正则锚）：
```
[XDM_PROBE][P4-U3][BEGIN] runId=143012 filesDir=/data/app/.../files
[XDM_PROBE][P4-U3][S1] notificationTimeOut=0 lang=en-US darkTheme=true maxParallel=3 ...
[XDM_PROBE][P4-U3][S2] videoExts=15 fileExts=23 blockedHosts=3 blockedHost2=thwawte.com categories=5 ...
[XDM_PROBE][P4-U3][S3] timeoutW=120 timeoutR=120 timeoutRestored=30 ... credRestored=0
[XDM_PROBE][P4-U3][S4] langBefore=en-US langSet=zh-Hans langReadback=zh-Hans langRestored=en-US ...
[XDM_PROBE][P4-U3][S5] checked=31 total=31 unchecked=0
[XDM_PROBE][P4-U3][SUMMARY] S1=notificationTimeOut=0,...|S2=videoExts=15,...|...
[XDM_PROBE][P4-U3][END] ok=true steps=5 elapsedMs=812
```

---

## 7. Hypium 本地用例清单（SettingParse.test.ets，22 条；被测模块零 @kit import）

**tryParseInt（10）**
1. `'500'→500`；2. `'0'→0`；3. `'-5'→-5`（Int32 允许负号）；4. `'+7'→7`；5. `'12a'→null`；6. `'a12'→null`；7. `''→null`；8. `'1.5'→null`；9. `'2147483647'→2147483647`（上界）；10. `'2147483648'→null`（溢出）。
**parseExtensionList（5）**
11. `'MP4, WEBM ,,MP3'→['MP4','WEBM','MP3']`（trim/去空）；12. `''→[]`；13. `',,,'→[]`；14. `'MP4,MP4'→['MP4','MP4']`（**不去重**，与 §3.1 对照）；15. `' MP4 '`→`['MP4']`。
**parseCategoryTypes（5）**
16. `' .MP4 ,.MP4,\r\n.MKV,,'→['.MP4','.MKV']`（CRLF 删+trim+去重保序）；17. `'.MP4,.MKV'→['.MP4','.MKV']`（顺序保留）；18. `''→[]`；19. `'.A,\n.B,,\r\n'→['.A','.B']`；20. `'.A,.A,.A'→['.A']`（单元素去重）。
**joinForEdit/clamp（2）**
21. `joinForEdit(['MP4','WEBM'])→'MP4,WEBM'`；22. `clampToRange(999,1,50)→50 / clampToRange(0,1,50)→1 / clampToRange(33,1,50)→33`（下拉回显防御三例）。

> Config 47 键 getter/setter 与五页 populate/updateConfig 为 IO 壳/UI 胶水（@kit 依赖，不入本地单测——被测模块零 kit import 的既有约定），由 P4-U3 探针 S1~S4 与走查覆盖。
