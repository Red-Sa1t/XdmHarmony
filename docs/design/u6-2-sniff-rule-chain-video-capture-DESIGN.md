# U6.2 嗅探规则链全量 + 视频捕获页 · 模块设计书

> 单元：U6.2（Phase 6 第 2 项；探针单元 ID `P6-U2`）。
> 依据：MIGRATION_PLAN §6 决策 5（嗅探规则服务端对照）、§7 Phase 6 第 3/4 项；UNIT_CATALOG U6.2 行；PROBE_SPEC v1；单元指令（规则链全量翻译 + tracker 动作半区 + VideoCapture 页 + U6.1 报告 §8 三项收敛 + 探针 P6-U2 四件）；源码研究结论（分工1）。
> 对照源码（本会话只读核实，未改 resourses/ 下任何文件）：
> `XDM.Core/BrowserMonitoring/VideoUrlHelper.cs`（全 980 行）、`BrowserMonitoring/VideoTracker.cs`（全 402 行）、`chrome-extension/request-watcher.js`（全 200 行）、`XDM.Core/Message.cs`、`XDM.Core/Util/ParsingHelper.cs`、`Util/FileHelper.cs:15-21,88-117`、`Util/FileExtensionHelper.cs:9-21`、`MediaParser/Hls/HlsParser.cs:15,22`、`XDM.Core/LinkRefresher.cs`（全 125 行）、`ApplicationCore.cs:188-236`、`StreamingVideoDisplayInfo.cs`、`Downloader/Progressive/SingleHttp|DualHttp/*DownloadInfo.cs`、`Downloader/Adaptive/MultiSourceDownloaderBase.cs:793-801`、`XDM.Wpf.UI/Dialogs/MediaCapture/MediaCaptureWindow.xaml(.cs)`、`MainWindow/WpfPlatformUIService.cs:227-245`、`XDM.Core/UI/NewVideoDownloadDialogUIController.cs:40-46`、`AppTrayIcon.cs:25-41`、`Lang/English.txt`（MSG_QUALITY/MSG_DOWNLOAD/MSG_CLEAR/MSG_CLOSE/MSG_MEDIA_CAPTURE/MSG_VID_CAP）。
> 既有工程事实（本会话核实）：U6.1 已交 `VideoSniffAlgo.ets`（isNormalVideo 五门+extFromMedia+qualityText+parentDirUri+getExtensionOf+generateUpdatedFileName，零 @kit）、`CapturedVideoTracker.ets`（数据半区：四表+事件+lookup）、`BridgeRoutes.ets`（八路由+动作半区，:408-411 四个 no-op 锚）、`BridgeJson.ets`（三门+七字段映射）、`Index.ets:1262` 已有禁用菜单项 `msg_media_capture`（源 MainWindow.xaml:65 menuMediaGrabber 同位）、:1460-1473 NavDestination builder 惯例（Settings 先例）；`Formatting.ets formatSize` 与源 `FormattingHelper.FormatSize` 逐语义一致；probe 基建 ProbeKit/ProbePage/ProbeIndex/ProbeBridgeNet/ProbeBridgeRoutes 就绪。

## 0. 拍板注记（本单元四个口径裁决，必读）

1. **"五层规则链"的落位勘误与验收口径**。单元指令与 UNIT_CATALOG 把五层链（blockedHosts→扩展名→URL 正则→mediaTypes→Content-Disposition→host 白名单）记在 VideoUrlHelper.cs 名下；本会话全读 980 行核实：**该链文本在 `chrome-extension/request-watcher.js:49-90 isMatchingRequest`**（扩展端请求过滤，U6.3 原样复用扩展本体），VideoUrlHelper.cs 的自有链是 `ProcessMediaMessage` 分派链（:35-65）。本设计的口径：**两份链都落 `VideoSniffAlgo.ets` 纯函数镜像 + 双份用例表（均可 Node 自验）**——①`isMatchingRequest` 八层逐层镜像（+`passesSendGate` :92-98 门）；②`ProcessMediaMessage` 分派链逐锚补全。满足"规则链用例表全绿、样例 URL 分类正确"验收在两种读法下都成立。**红线：`isMatchingRequest` 不得接入 `/media` 服务端链**——源拓扑中该过滤只发生在扩展端（request-watcher.js:105 在 onHeadersReceived 内调用后才 post /media），服务端再跑一遍即双重过滤改变行为；它是纯函数规格件（用例表载体 + U6.3 扩展复用的行为基准）。
2. **manifest 三分支（YT JSON/HLS/DASH 解析）不进本单元**（采纳研究建议）。`DownloadManifest`（VideoUrlHelper.cs:825-871）与 HlsParser/MpdParser/YoutubeDataFormatParser 依赖网络与 U6.4/U7.1 才交付的解析器；本单元 HLS/DASH/YT-JSON 三分支落"**识别谓词 + m3u8MpdTabs/referersToSkip 两表写入方（写入点在 manifest 拉取之前，VideoUrlHelper.cs:187-191/:337-341 源序保持）+ log 锚后 return**"。网络无关即消除 U6.1 §7-3 暂态（.m3u8/.mpd 请求自身经过 /media 时 tabId 已登记，后续 .ts 段被 IsNormalVideo 门②拦截）。hls/dash 表的 UI 走查数据由探针直调本单元新增的 `addHlsVideo/addDashVideo` 写入方种子（数据形状与 U6.4/U7.1 解析产物一致）。
3. **HandleDashAudio 'mkv' 缺点怪癖 1:1 保留**（openQuestion#3 裁决）：URL 末段无扩展名且 mime 不含 webm/mp4 时 `ext='mkv'`（缺前导点）→ 文件名 `名字mkv`（无点分隔）、质量文本 `[KV AUDIO]`（ext.Substring(1) 吞掉 K）。对等原版零成本，不修（Node 用例 D13 钉死）。
4. **LinkRefresher 状态机本单元不落**（openQuestion#4 裁决，推翻研究的"建议落纯逻辑"倾向）：单元指令红线"BridgeRoutes 改动仅限评估收敛项"，收敛清单只有三项（§0 下方 a/b/c）；LinkAccepted 落地需改 `addDownloadAction` 守卫位（超出授权面）且依赖引擎侧 FileSize 查询口（HTTPDownloaderBase 对应物未建）。U6.1 ★3 恒 false 锚延续，注释锚原地保留，U6.3 与刷新链接窗（LinkRefreshWindow）一起落。评估记录：LinkRefresher.cs:46-63 匹配谓词（FileSize==ContentLength 且>0）已进用例表 E3 备查，落地时直接取用。
   **U6.1 报告 §8 三项收敛的执行边界**：(a) 评估建链/对话框事件移回 tracker——**执行**（§3.1，含 BridgeUiEvents 上移新文件避免循环 import）；(b) `/link` pending 改 `{url,file}` 对——**执行**（§3.4）；(c) contentType 语义 F3/F4——**执行**（§3.5，processNormalVideo 登记传 `''` 镜像源 null）。另有 U6.1 §8-1 建议的 F2 族（空串 file 兜底失效）属 `BridgeJson.ets` 一行级修正，**随本单元修**（不在 BridgeRoutes，不触红线）；F1（`--media-tab-url` 缺 title 仍改名）属 BridgeRoutes /args 行为变更，**延后 U6.3**（超本单元授权面，登记遗留）。

## 1. 目标文件清单（按实现顺序）

| # | 文件 | 新/改 | 职责 | 对外导出 | 依赖 |
|---|---|---|---|---|---|
| 1 | `entry/src/main/ets/core/bridge/VideoSniffAlgo.ets` | 改 | 嗅探纯函数全量（零 @kit 纪律不变）：既有六函数零改动；新增 isMatchingRequest 八层镜像+passesSendGate、分派链谓词五件（isYtFormat/isHLS/isHLSUrl/isDASH/isDASHUrl）、isNormalVideo(itag) 三区间、YT-DASH 段配对全量（processYtDashSegment/addToQueue/addIfNew/getDashPair/handleDashAudio/createDual/Itags 表/DashInfo 类）、SHA1 纯 TS、hostOfUrl、parseInt64Gate、unescapeDataString、parseKeyValuePairOf；SniffState 扩双队列+lastVid | 既有导出不变；新增 `DashInfo`、`SniffState`（字段扩展）、`createSniffState`（扩展初始化）、`SniffRuleConfig`、`isMatchingRequest`、`passesSendGate`、`isYtFormat`、`isHLS`、`isHLSUrl`、`isDASH`、`isDASHUrl`、`isNormalVideoItag`、`processYtDashSegment`、`handleDashAudio`、`createDualInfo`、`ITAG_KEYS/ITAG_VALUES`、`itagQuality`、`sha1Hex`、`hostOfUrl`、`parseKeyValuePairOf` | `core/util/FileNames`、`core/util/Formatting`（既有） |
| 2 | `entry/src/main/ets/core/bridge/BridgeActions.ets` | 新 | 桥动作公共件（收敛 a 的循环依赖解法）：`BridgeUiEvents` 接口（自 BridgeRoutes 上移，onShowBatchSelection 载荷改 `PendingBatchLink[]`）、`PendingBatchLink{url,file}`、监听器注册表+register/unregister+`fireBridgeUiEvent`、`startBridgeAutoDownload`（自 BridgeRoutes 上移，唯一建链点红线不变） | `BridgeUiEvents`、`PendingBatchLink`、`registerBridgeUiEvents`、`unregisterBridgeUiEvents`、`fireBridgeUiEvent`、`startBridgeAutoDownload` | #1（否）——依赖 `BridgeJson`（BridgeMessage 类型）、`core/Config`、`core/util/FileNames`、`model/DownloadRecord`+`DownloadTypes`、`core/db/DownloadStore`、`core/engine/DownloadManager` |
| 3 | `entry/src/main/ets/core/bridge/CapturedVideoTracker.ets` | 改 | 数据半区增量+动作半区收拢：TrackedVideo 扩双源/分段承载字段；三个新写入方（addDualSourceVideo→yt/addHlsVideo→hls/addDashVideo→dash，单条重载语义）；`getTrackedVideos()` 富投影；`addVideoDownload(vid)`（自 BridgeRoutes 移入，LinkAccepted 守卫注释锚保留）+`isFFmpegOK` 私有化 | 既有导出不变；新增 `addDualSourceVideo`、`addHlsVideo`、`addDashVideo`、`getTrackedVideos`、`addVideoDownload` | #2、`BridgeJson`（BridgeHeaders 经 #1）、`core/Config` |
| 4 | `entry/src/main/ets/core/bridge/BridgeJson.ets` | 改 | F2 族修复：`buildBridgeMessage` 空串 file 同 null 处理（对齐源 SanitizeFileName('')=''→ProcessNormalVideo IsNullOrEmpty 回退 GetFileName 的净效果） | 既有导出不变 | 无新增 |
| 5 | `entry/src/main/ets/core/bridge/BridgeRoutes.ets` | 改 | 收敛 a/b/c+嗅探链锚补全：删 BridgeUiEvents/pendingBatchLinks/videoDownloadAction/isFFmpegOK/startBridgeAutoDownload（移 #2/#3）；/vid 与 /args --media-vid 改调 `tracker.addVideoDownload`；handleLinkRoute 存 `PendingBatchLink{url,file}`；processMediaMessage 补 ②IsYtFormat ③IsHLS/IsHLSUrl ④IsDASH/IsDASHUrl ⑤ProcessYtDashSegment 五锚为真实现（两表写入+配对登记）；processNormalVideo contentType 实参改 `''`；processNormalVideo 空 file 二次回退分支恢复可达（随 #4） | 既有导出面收缩为：`handleRoute`、`buildSyncResponse`（BridgeUiEvents/registerBridgeUiEvents/unregisterBridgeUiEvents/getPendingBatchLinks 改由 #2 提供） | #1 #2 #3 #4 |
| 6 | `entry/src/main/ets/pages/VideoCapture.ets` | 新 | 视频捕获页（对照 MediaCaptureWindow.xaml）：@Component `VideoCapturePage({pathStack})`，分组列表（yt/video/hls/dash 四组头）+两列 Name/Quality+全选/单选+Download/Clear/Close | `VideoCapturePage`（struct） | #3（getTrackedVideos/监听器/clearVideoList/addVideoDownload）、`BridgeProtocol`（BridgeVideoItem）、`core/Config`（broadcastConfigChange 不直接用，经 tracker） |
| 7 | `entry/src/main/ets/pages/Index.ets` | 改 | 菜单项 `msg_media_capture`（:1262 占位禁用项）启用 → `pathStack.pushPathByName('videoCapture','')`；settingsNavDestination builder（:1463）追加 `else if (name === 'videoCapture')` 分支装 VideoCapturePage。其余零改动 | —（页） | #6 |
| 8 | `entry/src/test/VideoSniffAlgo.test.ets` | 新 | Hypium 本地用例（§5 用例表 ArkTS 侧）：A/B/C/D/E 组纯函数断言 + F2 修复回归 | default testsuite 注册函数 | #1 #4（零 @kit 本地可加载） |
| 9 | `entry/src/test/BridgeRoutes.test.ets` | 改 | import 路径改 #2（BridgeUiEvents 族）；pending 断言改 `PendingBatchLink` 形；新增收敛 a/b/c 回归用例 | testsuite | #2 #5 |
| 10 | `entry/src/test/List.test.ets` | 改 | testsuite 追加注册 #8；头注计数注记同步（顺带修 U6.1 F7） | testsuite | #8 |
| 11 | `entry/src/main/ets/probe/units/ProbeVideoSniff.ets` | 新 | P6-U2 探针 @Component：S1~S8 runner（§6 步骤表）；S7 直调 #3 三写入方种子 hls/dash 条目供走查；tracker 监听器+BridgeUiEvents 监听器注册计数 | `ProbeVideoSniff`（struct） | #1 #2 #3 #5、`probe/units/ProbeBridgeNet`（ProbeTcpClient 复用）、`probe/units/ProbeBridgeLogic`（splitResponseHead/parseSyncBody 复用）、`probe/core/ProbeKit`/`ProbePage` |
| 12 | `entry/src/main/ets/probe/ProbeIndex.ets` | 改 | PROBE_UNITS 表尾追加 `{unitId:'P6-U2',...}` + else-if 分支（只加不改惯例） | —（@Entry 页） | #11 |
| 13 | `entry/src/main/resources/base/element/string.json` | 改 | 追加 `msg_quality`/`msg_download`/`msg_clear`/`msg_close`（对照 English.txt:198,221-223）+ `probe_p6u2_title`/`probe_p6u2_hint` | —（资源） | 无 |
| 14 | `entry/src/main/resources/zh_CN/element/string.json` | 改 | 同 #13 中文文案 | —（资源） | 无 |
| 15 | `entry/src/main/resources/en_US/element/string.json` | 改 | 同 #13 英文文案 | —（资源） | 无 |
| 16 | `docs/probe/P6-U2-sniff-cases.js` | 新 | 规则链用例表 Node 自验脚本（§5 全表 65 用例的 JS 镜像，`node docs/probe/P6-U2-sniff-cases.js` 主机侧直接跑，SUMMARY pass=65 fail=0 退出码 0=验收"规则链用例表全绿"的 AI 可自验证据） | —（脚本） | #1 的行为契约 |
| 17 | `docs/probe/PROBE-u6-2-sniff-rule-chain-video-capture.md` | 新 | 探针运行手册：设备侧 S1~S8 + Node 用例脚本轨 + VideoCapture 页人工走查清单 + 真实 HLS 测试流观测建议（U6.1 §8-5） | —（文档） | #11 #16 |
| 18 | `docs/probe/EXPECT-u6-2-sniff-rule-chain-video-capture.json` | 新 | 机器可读预期表（BEGIN/S1~S8/SUMMARY/END 11 步骤，须过 JSON.parse 校验） | —（JSON） | #17 |

**配置文件决议（显式）**：`module.json5` **不动**——本单元不新增能力（嗅探识别与两表写入网络无关，manifest 拉取留 U6.4/U7.1；捕获页为应用内 NavDestination；`deviceTypes` 已含 2in1、`requestPermissions` 已含 `ohos.permission.INTERNET`，U0.1 落地）；`main_pages.json` **不动**——VideoCapture 走 Navigation/NavDestination（页路由统一红线），main_pages 只保留 Index 与探针页；`EntryAbility.ets` **不动**（桥已常驻 start，tracker/路由惰性单例）。编码时若发现权限/配置缺失（异常态）上报主流程，不得擅自改配置。**不触碰**：`resourses/` 下任何文件（只读红线）。

## 2. 数据模型与表结构（对照源码逐一核对）

### 2.1 业务表结构：无

无 RelationalStore 新表、无 preferences 新键。tracker 四表仍为**纯内存会话态**（源 VideoTracker 同）；YT-DASH 配对双队列与 lastVid 也是内存态（源 VideoUrlHelper.cs:27-29 静态字段 → SniffState 注入化投影，U6.1 §3.8 先例）。

### 2.2 SniffState 扩展（VideoUrlHelper.cs:26-33 逐字段）

| 字段 | 类型 | 源对照 |
|---|---|---|
| suspectedFragments | Set\<string\> | :33 suspectedMp4Fragments（U6.1 已有） |
| m3u8Tabs | Set\<string\> | :32 m3u8MpdTabs（U6.1 恒空→U6.2 有写入方） |
| referersToSkip | Set\<string\> | :30 Dictionary\<string,DateTime\>——**值只作时间戳刷新无读取面**（IsMediaFragment :873-886 命中即刷新，从不比较时间），ArkTS 降为 Set（键存在性即全部语义），登记微差异 §4-11 |
| videoQueue | DashInfo[] | :28 List\<DashInfo\> |
| audioQueue | DashInfo[] | :29 List\<DashInfo\> |
| lastVid | DashInfo \| null | :27 DashInfo（null 初始化） |

**DashInfo**（:969-979 逐字段）：`url:string; length:number; isVideo:boolean; itag:number; id:string; mime:string; headers:BridgeHeaders|null; cookies:string|null`（Headers/Cookies 自 message 注入）。

### 2.3 SniffRuleConfig（isMatchingRequest 入参，/sync 八字段投影）

| 字段 | 类型 | 源对照（IpcHttpMessageProcessor.cs:278-374 + request-watcher.js:21-47） |
|---|---|---|
| blockedHosts | string[] | Config.getBlockedHosts()（默认 3 项，thwawte 保真） |
| mediaExts | string[] | /sync 从不发送 → **恒空层**（保留参数位钉死层序） |
| requestFileExts | string[] | Config.getVideoExtensions()（15 项大写无点） |
| urlPatternRes | RegExp[] | /sync 从不发送 → **恒空层**（updateConfig :40-46 编译产物；镜像收已编译 RegExp） |
| fileExts | string[] | Config.getFileExtensions()（23 项大写无点） |
| mediaTypes | string[] | SYNC_MEDIA_TYPES = ['audio/','video/'] |
| matchingHosts | string[] | SYNC_MATCHING_HOSTS = ['googlevideo'] |

### 2.4 TrackedVideo 扩展（TrackedVideo.cs 三类 DownloadInfo 逐字段对齐）

既有 12 字段零改动，追加 8 可空/默认字段：

| 新字段 | 类型 | 承载（源类.字段） | 写入方 |
|---|---|---|---|
| uri2 | string（默认 ''） | DualSource.Uri2 / MultiSourceHLS.AudioUri | addDualSourceVideo / addHlsVideo |
| headers2 | BridgeHeaders \| null（默认 null） | DualSource.Headers2 | addDualSourceVideo |
| cookies2 | string \| null（默认 null） | DualSource.Cookies2 | addDualSourceVideo |
| videoSegments | string[]（默认 []） | MultiSourceDASH.VideoSegments（List\<Uri\> 串化） | addDashVideo |
| audioSegments | string[]（默认 []） | MultiSourceDASH.AudioSegments | addDashVideo |
| duration | number（默认 0） | MultiSourceDASH.Duration（max(video,audio)） | addDashVideo |
| videoMimeType / audioMimeType | string（默认 ''） | MultiSourceDASH.VideoMimeType/AudioMimeType | addDashVideo |

既有字段在新写入方的取值：`uri`←DualSource.Uri1 / HLS.VideoUri / DASH.Url(**manifest URL**，U7.1 消费)；`size`←displayInfo.Size（dual=两段 clen 和；**hls/dash 源不设 Size→0**）；`contentType`←源 AddVideoDownload 读取位（yt→ContentType1、video→ContentType、hls/dash→ContentType，源三类均未设→**''**；唯一例外 HandleDashAudio 单源条目=info.Mime）；`description`←displayInfo.DescriptionText（=Quality 文本）；`dateAdded`←Date.now()（**MediaInfo 构造用 DateTime.Now 而非 displayInfo.CreationTime**，VideoTracker.cs:253/:270/:288/:306 逐处核实——两者此刻同值，投影取 now 与 U6.1 一致）。

### 2.5 三个新写入方（VideoTracker.cs 单条重载四件 :242-311 对齐三件，单源件 U6.1 已有）

| 方法 | 入表 | 源重载 | 事件序 |
|---|---|---|---|
| addDualSourceVideo(file,size,uri1,uri2,headers1,headers2,cookies1,cookies2,description,tabId,tabUrl) | yt | AddVideoNotification(displayInfo, DualSource) :242-258 | id=UUID→入表→onMediaAdded→broadcastConfigChange |
| addHlsVideo(file,videoUri,audioUri,headers,cookies,description,tabId,tabUrl) | hls | AddVideoNotification(displayInfo, MultiSourceHLS) :277-293 | 同上 |
| addDashVideo(file,manifestUrl,videoSegments,audioSegments,headers,cookies,duration,videoMime,audioMime,description,tabId,tabUrl) | dash | AddVideoNotification(displayInfo, MultiSourceDASH) :295-311 | 同上 |

批量重载 AddVideoNotifications×4（:160-240，每条一发事件+每批一次通知/广播）的唯一调用方是 ProcessPostYtFormats（YT JSON 解析器，U6.4/U7.1）——**本单元不落批量重载**，U6.4 接线时补。

### 2.6 getTrackedVideos()（VideoCapture 页富投影）

`getTrackedVideos(): TrackedVideo[]`——与 getVideoList 同序（yt→video→hls→dash 拼接 + dateAdded 升序稳定排序），返回 TrackedVideo 全字段（页需要 kind 做分组；/sync 投影 BridgeVideoItem 契约冻结不挂 kind，故新开只读方法，**getVideoList 零改动**）。

### 2.7 PendingBatchLink（收敛 b）

`interface PendingBatchLink { url: string; file: string }`——handleLinkRoute 逐项 `file=sanitizeFileName(msg.file ?? fileNameFromUrl(url))`（映射时已算好，U6.1 现实现丢弃→本单元存对）；`getPendingBatchLinks(): PendingBatchLink[]` 返回拷贝；`onShowBatchSelection(items: PendingBatchLink[])` 载荷同步改对数组（U6.3 勾选窗按 R4-F5 消费）。

### 2.8 Itags 表（VideoUrlHelper.cs:904-966）

**60 项**（研究结论"63 项"勘误，本会话逐行清点 906-965 行=60 条；Node 用例 D22 钉死）。键：5,133,6,134,135,136,264,137,266,139,140,13,141,271,272,17,18,22,278,160,34,35,36,37,38,167,168,169,170,298,43,171,299,44,172,45,46,302,303,308,313,59,315,78,82,83,84,85,218,219,100,101,102,242,243,244,245,246,247,248；值逐字含 `'Hi  bitrate'`（**双空格**，:918/:940）与 3D 档 `'360p 3D'` 等；查不到默认 `'MKV'`（:528 GetValueOrDefault 兜底）。ArkTS 形态：平行数组 `ITAG_KEYS: number[]` + `ITAG_VALUES: string[]` + `itagQuality(itag): string`（Map<number,string> 惰性构建或线性查找皆可，60 项量级无性能面；禁 Record<number,...>——ArkTS Record 键必须 string）。

## 3. 关键算法翻译说明（数学与状态机逐条保留）

### 3.1 收敛 (a)：tracker 动作半区收拢（VideoTracker.cs:313-376 → CapturedVideoTracker）

**拓扑**：`BridgeRoutes → CapturedVideoTracker → BridgeActions` 单向，无环。`BridgeUiEvents`+`startBridgeAutoDownload` 上移新文件 BridgeActions.ets（研究结论给的第二方案"上移 BridgeUiEvents 到独立文件"）；`startBridgeAutoDownload` 同步上移因 tracker 动作半区的自动分支要调它（源 StartVideoDownload→CoreService.StartDownload 同位），若留 BridgeRoutes 则 tracker→routes 逆边成环。

`CapturedVideoTracker.addVideoDownload(videoId: string | null): void`（源 :313-370 逐行）：
1. `videoId === null/undefined → throw Error`（ContainsKey(null)→ArgumentNullException→断连的 1:1，§4-11 锚随迁）。
2. 按 **yt→video→hls→dash** 查表；**仅 yt/video 两表有 LinkAccepted 前置守卫位**（:321/:329，恒 false 注释锚保留）。
3. 命中半区：yt→name=File、size=displayInfo.Size、contentType=ContentType1('')；video→name=File、size=displayInfo.Size、contentType=ContentType；hls→name=File、contentType=ContentType（源 try/catch 吞→''）、size 恒 0；dash→name=File、contentType=ContentType、size 恒 0。
4. `valid` → `Config.getStartDownloadAutomatically() && isFFmpegOK(videoId)` → 自动分支 `startBridgeAutoDownload(sanitizeFileName(name), size, uri, FileNameFetchMode.ExtensionOnly)`（单源 video 表语义；yt/hls/dash 在 IsFFmpegOK 降级恒 false 下不可达，分支注释锚"U7.2 接 IsFFmpegInstalled 真值后接线 StartVideoDownload 分表语义"）；否则 `fireBridgeUiEvent(l => l.onShowVideoDownloadDialog?.(id, name, size, contentType))`（**name 未消毒**——源 :361 只在自动分支 Sanitize，:367 对话框传原名）。未命中静默。
5. `isFFmpegOK(id)`（源 :372-376）私有化随迁：`!isFFmpegRequiredForDownload(id) → true`，否则 false（U6.1 §4-6 降级不变）。

BridgeRoutes 侧：`handleVidRoute` 改 `CapturedVideoTracker.getInstance().addVideoDownload(data.vid)`；`dispatchArgs` 的 `--media-vid` 支同改；`addDownloadAction`（/download）**留 BridgeRoutes**（源拓扑在 ApplicationCore.AddDownload :208-236 而非 tracker）改调 `fireBridgeUiEvent`+`startBridgeAutoDownload`（自 #2 import）。

### 3.2 isMatchingRequest 八层镜像（request-watcher.js:49-90 → VideoSniffAlgo，纯函数规格件，不接业务链）

```
isMatchingRequest(cfg: SniffRuleConfig, url: string, responseHeaders: BridgeHeaders): boolean
①hostOfUrl(url)（u.host 投影，含端口、剥 userinfo）→ blockedHosts 逐项 host.indexOf(h)>=0 → false
②upath=urlPathOf(url).toUpperCase()（u.pathname 投影：authority 后首 '/' 起、至 '?'/'#' 止、不含 query）；
  mediaExts 逐项 upath.endsWith(e) → true（恒空层）
③requestFileExts 逐项 upath.endsWith(e) → true
④urlPatternRes 逐项 re.test(url) → true（恒空层；try/catch 包裹 :67-71）
⑤responseHeaders 名字 toUpperCase()==='CONTENT-TYPE' 首值 value.indexOf(m)>=0（m∈mediaTypes）→ true
⑥fileExts 逐项 upath.endsWith('.'+e) → true
⑦'CONTENT-DISPOSITION' 首值 toUpperCase().indexOf('.'+ext)>=0（ext∈fileExts）→ true
⑧matchingHosts 逐项 host.indexOf(h)>=0 → true；全不中 → false（源隐式 undefined）
passesSendGate(method, url, matchingHosts): method==='GET' || matchingHosts 存在 h 使 url.indexOf(h)>0
  （:92-98——**严格大于 0**：匹配在下标 0 不算，源怪癖；非 GET 请求仅过门才入 requestMap）
```
URL 解析手写（hostOfUrl/urlPathOf）：`://` 后至首个 `/` 为 authority（剥 `@` 前 userinfo、**保留端口**——u.host 含端口）；pathname 取 authority 后首 `/` 至 `?`/`#`。WHATWG 对 pathname 的轻度百分号规范化不复刻（用例表输入全 ASCII 普通路径，无观测差，登记 §4-12）；非法 URL（无 `://`）→ false（源 `new URL` 抛异常使 webRequest 监听器中止=消息不上送，净效果同）。

### 3.3 ProcessMediaMessage 分派链补锚（VideoUrlHelper.cs:35-65 → BridgeRoutes.processMediaMessage）

U6.1 已有骨架上把四个 no-op 锚换成真实现，**四段相互独立非互斥**（源四 if 无 else）：

```
contentType = headerValueFirst(responseHeaders,'Content-Type')；null → return（:37-41 不变）
①isYtFormat(contentType)（:750-761：非空 && toLowerCase().contains('application/json')）
  → 锚：hilog 'yt manifest branch recognized' + return 链不入后续？——**否，源无 return**：锚后继续走
    ②③④⑤（独立性保留；U6.4 落 ProcessPostYtFormats 时在此分支内调 DownloadManifest）
②isHLS(contentType)（:716-726：contentType **原始大小写** contains 'mpegurl'/'.m3u8'/'m3u8'——序数敏感）
  || isHLSUrl(url)（:728-731：url.toLowerCase().contains('.m3u8')）
  → 写入方（**:187-191/:337-341 源序：tabId 登记与 referer 写入都在 manifest 拉取之前**）：
      tabId 非空 → state.m3u8Tabs.add(tabId)；AddToSkippedRefererList(referer)（§3.4）；
      锚：hilog 'hls manifest recognized (parser U6.4)' + return 本分支（无网络动作）
③isDASH(contentType)（:733-743：contains 'dash' 序数敏感）|| isDASHUrl(url)（:745-748 '.mpd'）
  → 同②两表写入 + 锚 'dash manifest recognized (parser U7.1)'
④!processYtDashSegment(sharedSniffState, msg, tracker 写入回调)（§3.5）→ ⑤
⑤isNormalVideo(五门，U6.1 已有) → processNormalVideo（U6.1 已有；contentType 实参改 '' 传登记位，§3.5-F3）
```
⚠️ 源②③⑤分支返回值不短路后续判定（IsHLS 命中的消息还会被 ④⑤ 评估）——保持四段顺序执行，不得加 else/return。

### 3.4 referer 跳过表（:873-902 → VideoSniffAlgo + BridgeRoutes）

- `sha1Hex(input): string`——纯 TS SHA-1（FIPS 180-4，UTF-8 输入，40 位小写 hex；≈40 行零 @kit，Node 用 node:crypto 交叉验证 E2 向量 `sha1('abc')=a9993e36...`）。**不用 cryptoFramework**：保 VideoSniffAlgo 零 @kit 纪律与 Node 自验能力（差异登记 §4-10）。
- `AddToSkippedRefererList(referer)`（:888-895）：referer 空串/null → 忽略；否则 `referersToSkip.add(sha1Hex(referer))`。
- `IsMediaFragment(referer)`（:873-886）：referer 空 → false；`referersToSkip.has(sha1Hex(referer))` → true（源命中即刷新 DateTime.Now 值——Set 化后无此动作，§4-11）；BridgeRoutes 的 `isMediaFragmentGuard`（U6.1 :457-462 占位原串查询）改传 `sha1Hex(referer)` 键，**调用点零改动**。

### 3.5 YT-DASH 段配对全量（:409-613 → VideoSniffAlgo 纯函数组 + BridgeRoutes 接线）

`processYtDashSegment(state: SniffState, msg: BridgeMessage, out: SegSink): boolean`——**整段 try/catch，任何异常 → return false**（源 :543 `catch {}` 吞掉返回 false→落普通视频门，含 Int32/Int64.Parse 抛、Uri 构造抛）：

1. **host 门**：`hostOfUrl(msg.url)` 含 `.youtube.` 或 `.googlevideo.`（indexOf>=0；裸域 `youtube.com`/`googlevideo.com` **不含**前导点串→不过门，1:1）。
2. **contentType 门**：responseHeaders 'Content-Type' 首值 toLowerCase；null 或不含 `audio/`/`video/`/`application/octet` → false。
3. **url 门**：`url.toLowerCase()` 同时含 `videoplayback` 与 `itag` → 否则 false。
4. **参数重组**（:430-484 逐行）：`parseKeyValuePairOf(url,'?')`（ParsingHelper.cs:13-21 语义：Trim→首分隔符下标<1→('','')）拆 path/query；`query.split('&')` 逐项：`parseKeyValuePairOf(str,'=')`，key 空 → **continue（不追加进 yt_url）**；key 以 `range` 开头 → continue（同样不追加）；key==='itag' → `itag=parseInt64Gate(val)`；key==='clen' → clen 同门；key 以 `mime` 开头 → `mime=unescapeDataString(val)`；**str（原始参数串）**以 `id` 开头 → id=val（怪癖：`identity=x` 会命中）；非跳过项追加 str，且 `i<arr.length-1` 时追加 '&'——**末位参数被跳过时前一参数留下尾随 '&'**（Node D6 钉死）。
5. **短路口**：`itag!==0 && isNormalVideoItag(itag)`（:697-700：`(itag>4&&itag<79)||(itag>81&&itag<86)||(itag>99&&itag<103)`）→ return false（该段落普通视频门——常规画质 itag 走 ProcessNormalVideo 登记为 .mp4 等）。itag=0（缺参/大写 ITAG 不被精确等值解析）不短路（Node D10）。
6. **DashInfo 构造**：`{url: yt_url, length: clen, isVideo: mime.startsWith('video'), itag, id, mime, headers: msg.requestHeaders, cookies: msg.cookies}`。
7. **addToQueue**（:763-784）：先 `videoQueue.length>32 → shift(0)`、audioQueue 同——**入队前裁剪**，稳态上限 33（Node D18）；再 `addIfNew(info, isVideo?videoQueue:audioQueue)`（:702-714：自**队尾**向队首按 `(length,id)` 双等值去重，命中返回 false 不入队）。
8. 入队成功（addIfNew true）：
   a. `!info.isVideo && mime.startsWith('audio/')` → **handleDashAudio**（:547-587，先配对前登记）：`size=info.length`；`ext=getExtensionOf(fileNameFromUrl(info.url))`；ext 为空 → `mime.contains('webm')?'.webm':mime.contains('mp4')?'.mp4':'mkv'`（**'mkv' 缺点**）；`quality=ext.substring(1).toUpperCase()`；displayText=`'['+quality+' AUDIO] '+(size>0?formatSize(size):'')`；tracker.addSingleSourceVideo(`sanitize(msg.file ?? fileNameFromUrl(msg.url))+ext`, size, **info.mime**, info.url, info.headers, info.cookies, displayText, msg.tabId, msg.tabUrl)——**唯一设 contentType 的 U6.2 写入路径**（F3 对照面）。
   b. `getDashPair(state, info)`（:786-823）：info.isVideo → 自 audioQueue **队尾**向队首找 `id===info.id`（无守卫）；否则自 videoQueue 队尾向队首找，命中时 `lastVid!==null && lastVid.length===di.length → return null`（**lastVid 守卫**：同一段视频不被连续两条音频重复配对），否则 `lastVid=di; return di`（Node D15~D17 钉死队尾扫描+守卫序）。null → return true（消费但无条目）。
   c. `createDualInfo(di, info, msg)`（:589-613）：`video=info1.isVideo?info1:info2; audio=另一`；`{uri1:video.url, uri2:audio.url, headers1:video.headers, headers2:audio.headers, file:sanitize(msg.file ?? fileNameFromUrl(msg.url))+'.mkv', cookies1:video.cookies, cookies2:audio.cookies, contentLength:video.length+audio.length}`。
   d. `size=di.length+info.length`；`quality=itagQuality(info.isVideo?info.itag:di.itag)`（**恒取视频侧 itag**）；displayText=`'['+quality+'] '+(size>0?formatSize(size):'')`；tracker.addDualSourceVideo(file, size, uri1, uri2, headers1, headers2, cookies1, cookies2, displayText, msg.tabId, msg.tabUrl)。
9. return true（**即使去重失败或配对失败**——消息已被消费，源 :541）。

**写入接线**：VideoSniffAlgo 保持零 @kit 且不 import tracker——`processYtDashSegment` 的第 8 步通过注入回调 `out: SegSink { onSingle(info: SegSingle): void; onDual(info: SegDual): void }`（interface 定义在 VideoSniffAlgo）上报，BridgeRoutes 组装回调调 tracker 写入方。handleDashAudio 在纯函数内只产 `SegSingle{file,size,display,contentType,uri}` 数据，登记动作同样走 SegSink（Node 用例同构）。**不加 @Concurrent/TaskPool**：单消息处理微秒级，桥泵单线程事件循环内同步执行（U6.1 §3.8 结论沿用）；`store.add` 异步续体与 U6.1 相同。

### 3.6 收敛 (b)：/link pending 对（§2.7）——handleLinkRoute :233-236 的 `pendingBatchLinks.push(url)` 改 push `{url, file}`；事件载荷与 getter 同步（U6.3 消费前完成）。

### 3.7 收敛 (c)：contentType 登记——`processNormalVideo` 的 `addSingleSourceVideo(...)` contentType 实参 `contentType` → `''`（源 ProcessNormalVideo 不设 ContentType=null，VideoUrlHelper.cs:677-684 无 ContentType 赋值行；U6.1 R2-F3 闭环）。对话框影响面（F4）登记：U6.3 对话框 MP3 复选框门=`contentType 非空 && toLowerCase().startsWith('audio') && !contains('mpeg') && !contains('mp3')`（NewVideoDownloadDialogUIController.cs:40-47）——normal 条目 '' 无复选框（源同貌）；HandleDashAudio 条目 info.mime（如 audio/mp4）有复选框（源同貌）。

### 3.8 F2 族修复（BridgeJson.buildBridgeMessage :294）

`file: data.file === null ? null : sanitizeFileName(data.file)` → `file: (data.file === null || data.file.length === 0) ? null : sanitizeFileName(data.file)`——净效果对齐源：`SanitizeFileName('')` 返回 `''`（FileHelper.cs:17 null 直返、空串 Split→''）→ `ProcessNormalVideo` 的 `IsNullOrEmpty(file)` 回退 `GetFileName(url)`（VideoUrlHelper.cs:627-630）；U6.1 现实现经 sanitize 的 `'file'` 兜底堵死了该回退。连带 `processNormalVideo` 内 `file.length===0` 二次回退分支恢复可达（BridgeRoutes 既有代码零改动）。

### 3.9 VideoCapture 页（MediaCaptureWindow.xaml/.cs 对照）

布局（xaml :1-41）：标题=媒体捕获（msg_media_capture 既有键）；列表两列 **Name(400px)/Quality(150px)** = MediaInfo.Name/Description（xaml :34-37）；底部按钮 **Close（左）/ Download / Clear（右）**（xaml :18-26）。行为（.cs :18-128）：
- 构造订阅 MediaAdded/MediaUpdated + 预填 GetVideoList() 存量（:50-64）→ aboutToAppear 注册 TrackerListener + `tracker.getTrackedVideos()` 预填；aboutToDisappear 注销（Closing :94-99 对应）。
- 事件到达重取全表重渲染（源 AddMedia/UpdateMedia 按 ID 增改——观测收敛等价，登记 §4-9）。
- Clear（:73-77）：`tracker.clearVideoList()` + 本地清空。
- Download（:79-88）：源为 **SelectedIndex 单选**；本页按单元指令落 **全选/多选增强**（§4-8）：每行 Checkbox+行点击切换、组头/列表头全选 Toggle；Download 按选中序逐 id `tracker.addVideoDownload(id)`（每 id 动作 1:1 源，事件由 BridgeUiEvents 承载，auto=false 默认下计数观测）。
- Close：`pathStack.pop(true)` 返回主列表。
- **分组呈现**：yt/video/hls/dash 四组头（内容源=GetVideoList 拼接序+dateAdded 升序的 kind 分组视图；源为平铺列表——呈现层差异登记 §4-8；`/sync videoList` 投影零改动）。
- **降级不渲染**：Topmost 复选框（HarmonyOS 应用内 NavDestination 无窗口置顶语义）、HowTo 外链（PlatformHelper.OpenBrowser 对应物未接）——§4-8。
- 状态栏无新入口；唯一入口=汉堡菜单项（源 MainWindow.xaml:65 menuMediaGrabber 同位）。

## 4. 有意差异清单（全部；★=本单元新增，☆=沿用既有登记）

1. ★**规则链双镜像口径**：isMatchingRequest+passesSendGate 落 VideoSniffAlgo 纯函数规格件（源链在扩展端，服务端不接入——防双重过滤）；分派链在 BridgeRoutes 补锚。双份用例表 Node 可自验。
2. ★**manifest 三分支只落识别+两表写入**（写入点=源 manifest 拉取前的源序），DownloadManifest/解析器留 U6.4/U7.1 锚（log+return）。暂态效应 U6.1 §7-3 自本单元消除（Node C4 + 探针 S3 验证）。
3. ★**Itags 60 项**（研究结论 63 勘误，:904-966 逐行清点）。
4. ★**referersToSkip Dictionary→Set**：源值（DateTime 时间戳）只写不读（IsMediaFragment 从不比较时间），键存在性即全部语义。
5. ★**AddToQueue 稳态上限 33**：源 `Count>32 → RemoveAt(0)` 在入队前执行（1:1 保留，非"上限 32"）。
6. ★**parseInt64Gate 安全整数上界**：clen/itag 超 2^53（Number.MAX_SAFE_INTEGER）视为解析失败走 catch→return false；.NET Int64 可达 ±9.2e18，现实视频段 clen 不触发（登记理论边界）。
7. ★**Uri.UnescapeDataString→decodeURIComponent try/catch**：非法序列 .NET Core 保留原样近似（Framework 抛异常路径不复刻——真实 YT mime 参数恒合法）。
8. ★**VideoCapture 页增强**：全选/多选（源 SelectedIndex 单选，依据单元指令与 UNIT_CATALOG"全选"）+分组呈现（源平铺）；Topmost/HowTo 链接降级不渲染；事件到达全表重渲染替代按 ID 增改（观测等价）。
9. ★**ShowMediaNotification 通知半区继续降级**（U6.1 §3-5 拍板项在本单元落定）：源每次登记弹托盘气泡 MSG_VID_CAP"Streaming video detected"（AppTrayIcon.cs:25-41，点击开 MediaGrabber）→ 本单元 log+MediaAdded 事件+广播，系统通知 U6.3 端到端接线时评估（wantAgent 导航面）。
10. ★**SHA1 用纯 TS 实现**（非 cryptoFramework）：保零 @kit 与 Node 自验；node:crypto 交叉验证（E2 向量）。
11. ★**IsMediaFragment 命中不刷新时间戳**（Set 化副作用，源时间戳无读取面）；**大写 host 漏屏蔽**（request-watcher.js:53 indexOf 序数敏感，Node A17 钉死，1:1 保留）。
12. ★**手写 hostOfUrl/urlPathOf 替代 new URL/Uri**：WHATWG pathname 百分号规范化不复刻（用例表输入全 ASCII 无观测差）；userinfo 剥离、端口保留按 u.host 语义。
13. ★（收敛 a）BridgeUiEvents 接口自 BridgeRoutes 移至 BridgeActions.ets（import 路径变更，事件语义零变化——事件面零破坏红线不受影响）；/download 动作留 BridgeRoutes（源拓扑）。
14. ★F2 族随本单元修（BridgeJson 空串 file→null）；F1（/args --media-tab-url 缺 title 改名）延后 U6.3（超收敛项授权面）。
15. ☆ 沿用 U6.1 已登记：LinkAccepted 恒 false（§4-3，本单元 §0-4 拍板延续）、IsFFmpegOK 降级（§4-6）、请求头/Cookie 不注入引擎（§4-4，U6.3 接通）、SanitizeFileName D6 修正版（§4-7）、DateTime.Now→Date.now()（D1）、未知路径静默断连（§4-1）。

## 5. 单元验收测试要点

### 5.0 规则链用例表（本会话 Node 自验通过：`node u62-sniff-verify.js` → SUMMARY pass=65 fail=0，退出码 0；编码员将该脚本整理为 #16 落 docs/probe/P6-U2-sniff-cases.js，ArkTS 侧按同一张表落 Hypium）

**A 组 isMatchingRequest/passSendGate（17 例）**：
| # | 输入要点 | 期望 |
|---|---|---|
| A1 | blockedHosts 精确域命中（download.windowsupdate.com） | false |
| A2 | blockedHosts 子串命中（a.update.microsoft.com） | false |
| A3 | requestFileExts 大写路径 Video.MP4 endsWith('MP4') | true |
| A4 | 小写路径大写化后命中（video.mp4?x=1） | true |
| A5 | mediaTypes：Content-Type=video/mp4 | true |
| A6 | mediaExts 恒空层注入 ['.TS'] 后路径 a.ts 命中 | true |
| A7 | fileExts 层：路径 /f/setup.EXE + octet-stream | true |
| A8 | Content-Disposition .ZIP 命中（fileExts 内） | true |
| A8b | Content-Disposition .MKV 不命中（MKV∈VideoExtensions∉fileExts——源语义） | false |
| A9 | matchingHosts googlevideo host 命中 | true |
| A10 | 全层未中（text/html+index.html） | false（隐式拒） |
| A11 | query 含 a.EXE 不参与（仅 pathname） | false |
| A12 | urlPatterns 层注入正则命中 | true |
| A13 | sendGate：POST 无 matchingHost | 不入 |
| A14 | sendGate：POST url 下标>0 含 googlevideo | 入 |
| A15 | sendGate：POST url 以 googlevideo 开头（下标 0） | 不入（源怪癖） |
| A16 | sendGate：GET | 恒入 |
| A17 | 大写 host 屏蔽层序数敏感未中且余层未中 | false（怪癖登记） |

**B 组分派链谓词（9 例）**：IsYtFormat 精确/大小写不敏感/空串（B1~B3）；IsHLS mpegurl 命中、大写 MPEGURL 序数敏感不命中（B4/B5）；IsHLSUrl .M3U8 小写化命中（B6）；IsDASH dash+xml（B7）；IsDASHUrl .mpd（B8）；isNormalVideoItag 十二点边界 4否/5是/78是/79否/81否/82是/85是/86否/99否/100是/102是/103否（B9）。

**C 组分派链全流程（8 例）**：normal video/mp4 登记（C1）；application/json→YT 识别锚无登记（C2）；.m3u8→m3u8Tabs+referer 写入（C3）；**同 tabId .ts 段被门②拦截=U6.1 §7-3 暂态消除**（C4）；同 referer 普通视频被 IsMediaFragment 拦（C5）；异 referer 正常登记（C6）；init.mp4 疑似分片集拦兄弟段（C7）；size<MinVideoSize*1024 拒（C8）。

**D 组 YT-DASH 配对（23 例）**：host/contentType/url 三门拒绝（D1~D3）；音频段消费+`[MP4 AUDIO] 1000B`+`.mp4` 后缀+contentType=mime（D4/D5）；**range 末位丢参留尾随 '&'**（D6）；同 id 配对→yt 双源 `.mkv`/size=3000/`[1080p] 2.9K`（D7/D8）；itag=22 短路落普通门（D9）；大写 ITAG→itag=0 不短路仍消费（D10）；itag=abc Parse 抛→catch→false（D11）；audio/webm→`[WEBM AUDIO]`+`.webm`（D12）；**audio/flac→ext='mkv' 缺点→文件 'Clipmkv'+'[KV AUDIO]'**（D13）；AddIfNew (length,id) 去重（D14）；配对自队尾（音频命中最新视频 2500→size 3500）（D15）；**lastVid 守卫挡同视频二次配对**（D16）；视频到达侧命中最新音频→dual 2 size=4001 `[720p] 3.9K`（D17）；队列稳态 33（34 入队后）（D18）；队首最老被挤（D19）；application/octet 入音频侧不触发 HandleDashAudio（D20）；Itags 缺项默认 MKV→`[MKV] 1000B`（D21）；**Itags 60 项**（D22）；抽查 137/141（双空格）/82（D23）。

**E/F 组（4+4 例）**：sha1 40 位小写、`sha1('abc')` 已知向量（E1/E2）；LinkAccepted 谓词 FileSize==ContentLength 且>0 三态（E3）；pending {url,file} 对（F1）；MP3 复选框门 '' 无框/audio/mp4 有框/audio/mpeg、audio/mp3 无框（F2~F4）。

### 5.1 [A] 静态门禁（编码员每轮自跑）

1. hvigor 全量构建零 error 零新 warning；ArkTS 严格子集自查（对象字面量具 interface 类型、禁正则字面量——SHA1/parseInt 门用 `new RegExp`、禁 any/解构/for...in、throw 只抛 Error；Map/Set 替代字典）。
2. 结构断言：`grep -rn "XDM_PROBE" entry/src/main/ets/core` 零命中；`grep -rn "import.*probe" entry/src/main/ets/core` 零命中；**`grep -n "isMatchingRequest" entry/src/main/ets/core/bridge/BridgeRoutes.ets` 零命中**（红线：镜像不接业务链）；`git diff --stat` 确认 module.json5/main_pages.json/EntryAbility.ets 零改动；BridgeServer.ets 零改动（#1~#5 均不触泵）。
3. Hypium 本地用例清单（`VideoSniffAlgo.test.ets` 新增 + `BridgeRoutes.test.ets` 增补；§5.0 全表为输入，执行环境注记同 U6.1：本地 runner 会话不可实跑，用例入库不碍编译门禁）：
   - A 组 18 断言组（isMatchingRequest 层序逐层钉死+sendGate 三态）；B 组 9；C 组 8（共享 state 用后即弃防串扰）；D 组 23；E 组 3；F2 回归：`parseExtData('{"url":"https://h/x.mp4","file":"","requestHeaders":{"a":["b"]}}')`→buildBridgeMessage→file=null（1 组）。
   - BridgeRoutes.test.ets 增补：/vid 未命中静默+命中对话框事件计数（import 改 BridgeActions 后回归）；pending 两项含 file；processNormalVideo 登记条目 contentType===''（收敛 c）。
   - 用例计数 ≥55 断言组；List.test.ets 注册+头注计数同步（F7 顺带修）。

### 5.2 [P] 运行时（手册+Node 双轨承载）

4. **Node 用例轨（AI 主机侧可自验，无需设备）**：`node docs/probe/P6-U2-sniff-cases.js` → 全 PASS、`SUMMARY pass=65 fail=0`、退出码 0（=验收"规则链用例表全绿（纯逻辑单测）"的可执行证据）。
5. **设备侧探针**：`devecocli run --module entry` → `aa start --ps page probe` → P6-U2 卡片自动跑 S1~S8（§6）。
6. **VideoCapture 页人工走查**（手册 §走查清单）：菜单开页→分组四节可见→存量/增量条目渲染→单选/全选→Download（对话框事件计数，U6.3 前 UI 反馈=无弹窗为预期）→Clear 清空→Close 返回。
7. **事件面零破坏回归**：探针全程主页面无 jscrash（`devecocli log --crash` 空）；S8 的 /sync fieldCount=8+fieldOrder 不变；`/clear` 后 videoList=0。
8. **真实 HLS 测试流观测建议**（U6.1 §8-5，手册承载、不作本单元验收）：U6.3 扩展栈就绪后用公共测试流（如 `https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8`）实测——.m3u8 请求被识别、同 tab 的 .ts 段不再误入 videoList（对照 U6.1 行为）；U6.4 落解析器后 master 档位入 hls 表。

## 6. 探针步骤设计（P6-U2，autoStart=true 全自动）

拉起/抓取命令沿用 PROBE_SPEC §3 与 U6.1 手册口径。全部行 hilog domain 0xD001、tag XDM_PROBE、`%{public}s`、`[XDM_PROBE][P6-U2][<步骤>] key=value` 单行 <1500B；布尔/计数均为直接观测谓词，不含 PASS/FAIL 词；值白名单预转换（'['/']'→取括号内 token，commasToSlash 同 U6.1）。**前置**：BEGIN 后立即注册 tracker 监听器（mediaAdded/mediaUpdated 计数从 0 起）与 BridgeUiEvents 监听器（videoDialog 计数）；S1 先 POST /clear 清基线。

| 步骤 | 操作 | 观测点（emit 键） | 标记行示例 |
|---|---|---|---|
| BEGIN | autoStart | runId、filesDir | `[XDM_PROBE][P6-U2][BEGIN] runId=101601 filesDir=...` |
| S1 就绪+/clear | stats 快照→POST /clear→GET /sync 解析 | started、clearStatus、baseVideoCount | `... clearStatus=200 baseVideoCount=0` |
| S2 分类矩阵 | POST /media ×3：①video/mp4+CL=5242880（file=Movie）→②audio/aac+CL=2048（file=Tone）→③application/json（锚，无 CL） | mediaStatus、addedEvents、listCount、firstTextSuffix、secondTextSuffix、secondInfoPrefix | `... mediaStatus=200 addedEvents=2 listCount=2 firstTextSuffix=.mp4 secondTextSuffix=.m4a secondInfoPrefix=[AAC]` |
| S3 HLS 暂态消除 | POST /media（url=/list.m3u8，ct=application/vnd.apple.mpegurl，tabId=200，无登记预期）→POST /media（url=/seg/001.ts，ct=video/mp2t，CL=300000，tabId=200，门②拦截预期） | hlsStatus1、hlsStatus2、beforeCount、afterCount、tsBlocked | `... hlsStatus1=200 hlsStatus2=200 beforeCount=2 afterCount=2 tsBlocked=true` |
| S4 referer 跳过 | POST /media（/list2.m3u8，tabId=201，requestHeaders.Referer=R1）→POST /media（/v/clip.mp4，video/mp4，CL=5242880，Referer=R1→拦截；Referer=R2→登记） | beforeCount、afterSkipCount、afterOtherCount | `... beforeCount=2 afterSkipCount=2 afterOtherCount=3` |
| S5 YT-DASH 配对 | POST /media（googlevideo/videoplayback?itag=140&mime=audio%2Fmp4&clen=1000&id=oA&range=0-1000，ct=audio/mp4，file=YT Video）→POST /media（同 host?itag=137&mime=video%2Fmp4&clen=2000&id=oA，ct=video/mp4） | audioStatus、videoStatus、dualCount、audioTextPrefix、dualTextPrefix、listCount | `... audioStatus=200 videoStatus=200 dualCount=1 audioTextPrefix=MP4_AUDIO dualTextPrefix=1080p listCount=5` |
| S6 短路+怪典+对话框事件 | POST /media（itag=22 常规 itag→落普通门 .mp4）→POST /media（itag=139&mime=audio%2Fflac→'[KV AUDIO]'+'Clipmkv'）→POST /vid{vid:命中 normal 条目 id}（auto=false→对话框事件） | normalStatus、kvStatus、kvTextPrefix、kvFileText、videoDialogEvents | `... normalStatus=200 kvStatus=200 kvTextPrefix=KV_AUDIO kvFileText=Clipmkv videoDialogEvents=1` |
| S7 捕获页种子+走查指引 | 直调 tracker.addHlsVideo/addDashVideo 各 1 条种子（源数据形状 §2.4）→GET /sync | seededCount、kindCount、walkthroughHint | `... seededCount=2 kindCount=4 walkthroughHint=open-menu-media-capture` |
| S8 事件面回归 | POST /clear→GET /sync 全量（fieldCount/fieldOrder/finalVideoCount）+stats 快照 | clearStatus、finalVideoCount、fieldCount、fieldOrder、connections | `... clearStatus=200 finalVideoCount=0 fieldCount=8 fieldOrder=enabled/fileExts/... connections=15` |
| SUMMARY | end(ok) 聚合 | 各段关键键 | `... [SUMMARY] S1=clearStatus=200|S2=listCount=2|...` |
| END | ok、steps=8、elapsedMs | | `... [END] ok=true steps=8 elapsedMs=2800` |

失败路径：任一步 catch → 该步输出 errCode/errMessage 键组仍恰一行，不中断后续步骤。**主机侧双轨**：①`node docs/probe/P6-U2-sniff-cases.js`（纯函数用例表，无需设备）；②`hdc fport tcp:18597 tcp:8597` + 手册 curl 命令集（S2~S6 载荷复制）兜底。两轨判定汇入 EXPECT 表 note（用例轨全绿+探针轨全绿=运行时验收通过；捕获页走查为 [H] 人工项）。

## 7. 风险与备注

| 风险 | 缓解 |
|---|---|
| 编码员把 isMatchingRequest 接进 /media 链造成双重过滤 | §0-1 红线+§5.1-2 结构断言 grep 零命中 |
| 分派链四段被写成互斥（else/return） | §3.3 ⚠️ 注+Node C2（YT JSON 锚后 normal 门仍评估）+用例独立性 |
| tracker↔routes 循环 import | BridgeActions 中立件拓扑（§3.1），routes→tracker→actions 单向；hvigor 编译门禁兜底 |
| TrackedVideo 新字段漏默认值致 undefined 流转 | §2.4 全字段默认值表；ArkTS 类字段显式初始化 |
| 队列/lastVid 状态跨探针步骤串扰 | SniffState 为 BridgeRoutes 持有单例——探针 S5/S6 依赖前序状态属预期（与源进程内静态一致）；S1 /clear 不清嗅探态（源 ClearVideoList 只清四表）——用例表 C/D 组各自 newSniffState 隔离 |
| /vid 对话框事件在 U6.3 前无可见 UI | 探针 videoDialogEvents 计数承载走查；手册注明预期现象 |
| pending 结构变更破坏 U6.1 探针 | ProbeBridgeRoutes.ets 随 #9 同步改（import+断言），P6-U1 探针归档不重跑（UNIT_CATALOG 节奏） |
| 大写 ITAG/缺点 mkv 等怪癖被"顺手修好" | §0-3 拍板+D10/D13 用例钉死+§4 差异清单对照审查锚 |
