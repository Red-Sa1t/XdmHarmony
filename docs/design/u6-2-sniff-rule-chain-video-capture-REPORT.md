# U6.2 单元迁移报告：嗅探规则链全量+视频捕获页

> 单元：U6.2（Phase 6 第 2 项；探针单元 ID `P6-U2`）｜报告日期：2026-10-08
> 目标工程：`D:/git/HarmonyPC/XdmHarmony`（API 24 / SDK 6.1.1(24)，bundle `com.example.xdmharmony`，ArkTS 严格子集由 hvigor 编译期强制）
> 对照源码：`D:/git/HarmonyPC/resourses/xdm`（XDM 2023，C#/.NET，GPL-2.0；全程只读，未创建、修改或删除 resourses/ 下任何文件）
> 配套文档：设计书 `docs/design/u6-2-sniff-rule-chain-video-capture-DESIGN.md`；探针手册 `docs/probe/PROBE-u6-2-sniff-rule-chain-video-capture.md`；预期表 `docs/probe/EXPECT-u6-2-sniff-rule-chain-video-capture.json`
> 证据口径：标注【R】的条目引自本单元任务书材料（研究结论、审查记录、独立复核、门禁结论）；标注【V】的条目为报告员本会话实跑命令或实读文件核实，命令与路径随条给出。

## 1 单元范围与验收要点

### 1.1 交付范围（单元指令四件，全部落地）

1. **VideoUrlHelper 规则链全量翻译**。执行中落位勘误（设计书 §0-1）：计划书与 UNIT_CATALOG 所记"五层规则链"的文本实体在 `chrome-extension/request-watcher.js:49-90`（扩展端 isMatchingRequest），VideoUrlHelper.cs（全 980 行只读核实）的自有链是 `ProcessMediaMessage` 分派链（:35-65）。本单元按**双镜像口径**交付两份：①`isMatchingRequest` 八层+`passesSendGate` 落纯函数规格件（`VideoSniffAlgo.ets:333-410`），只作用例表载体与 U6.3 扩展复用的行为基准，红线禁止接入 /media 服务端链；②分派链五锚（IsYtFormat/IsHLS/IsDASH/YT-DASH 段配对/normal 门）在 `BridgeRoutes.processMediaMessage`（:412-442）补真实现。
2. **tracker 动作半区+视频捕获页**。`addVideoDownload` 自 BridgeRoutes 移入 `CapturedVideoTracker`（:311-330），`isFFmpegOK` 私有化随迁（:370-375）；新页 `pages/VideoCapture.ets`（272 行，对照 Wpf MediaCaptureWindow），经 Index.ets 汉堡菜单项（:1267-1271）与 NavDestination builder（:1483-1485）装配。
3. **U6.1 报告 §8 三项收敛全部执行**：收敛 a，动作半区移回 tracker，配套新建 `BridgeActions.ets`（121 行）承载 BridgeUiEvents 与 startBridgeAutoDownload，解 routes-tracker 循环依赖；收敛 b，/link pending 改存 `{url,file}` 对（`BridgeActions.ets:48-51`、写入点 `BridgeRoutes.ets:232-235`）；收敛 c，processNormalVideo 登记的 contentType 实参改 `''` 镜像源 null（`BridgeRoutes.ets:495`）。
4. **探针 P6-U2 四件**：`ProbeVideoSniff.ets`（S1~S8 全自动）+ `ProbeIndex.ets` 注册（:49/:145）+ Node 用例表 `docs/probe/P6-U2-sniff-cases.js`（65 例）+ 手册与预期表（EXPECT，11 步骤）。

范围裁剪两处（设计书 §0-2/§0-4 拍板）：manifest 拉取三分支（YT JSON/HLS/DASH 解析）只落识别谓词与两表写入，DownloadManifest/HlsParser/MpdParser/YoutubeDataFormatParser 留 U6.4/U7.1；LinkRefresher 状态机不落，U6.1 恒 false 锚延续。

### 1.2 验收要点与结果

| 验收要点 | 结果 | 证据 |
|---|---|---|
| 编译过 | 通过 | 【R】门禁结论：hvigor 全量编译（`devecocli build --modules entry`）最终状态通过（统一门禁脚本执行；报告员本会话未复跑） |
| 规则链用例表全绿 | 通过 | 【V】`node docs/probe/P6-U2-sniff-cases.js` 实跑，`SUMMARY pass=65 fail=0 total=65`（分组 A18/B9/C8/D23/E3/F4），退出码 0 |
| 样例 URL 分类正确 | 通过 | 【V】同一次实跑：A 组 17 例（八层过滤逐层+sendGate 三态）与 C 组 8 例（分派链样例分类，含 C4 同 tabId .ts 段被门②拦截即 U6.1 §7-3 暂态消除）全部 pass |
| 事件面零破坏 | 静态面通过，运行时面待探针 | 【V】`getVideoList` 与 /sync SyncFields 投影零改动（`CapturedVideoTracker.ets:176-197`，注释锚+代码核对）；/sync 八字段序冻结。【待办】探针 S8（fieldCount=8/fieldOrder/finalVideoCount=0）与全程无 jscrash 需设备侧运行后核 |

## 2 研究结论摘要：关键源码行为与 ArkTS 对应表

研究阶段九项事实（任务书【R】）与实现落点（报告员实读核实【V】）对照如下：

| # | 源码行为（位置） | ArkTS 对应（本会话实读） | 备注 |
|---|---|---|---|
| 1 | request-watcher.js:49-90 isMatchingRequest 八层过滤（blockedHosts 拒绝层、mediaExts/requestFileExts 路径 endsWith、urlPatterns 正则、mediaTypes 响应头子串、fileExts 带点 endsWith、Content-Disposition、matchingHosts 放行层；全不中隐式拒绝）+ :92-98 onSendHeaders GET 门（非 GET 需 matchingHost 子串下标严格大于 0） | `VideoSniffAlgo.isMatchingRequest`（:333-393）+ `passesSendGate`（:400-410）+ 手写 `hostOfUrl`/`urlPathOf`（:254-300） | 纯函数规格件，零 @kit；A1~A17/A13~A16 用例钉死层序与怪癖 |
| 2 | VideoUrlHelper.cs:35-65 ProcessMediaMessage：无 Content-Type 早退；四个 if 相互独立非互斥（YT JSON、HLS、DASH、YT-DASH 段配对短路普通门） | `BridgeRoutes.processMediaMessage`（:412-442）五锚真实现，无 else/return 打断独立性 | Node C2 验证 YT 锚后 normal 门仍评估 |
| 3 | :409-545 ProcessYtDashSegment：host/contentType/url 三门、按首个 '?' 拆参、range* 与空 key 参数剔除且末位剔除留尾随 '&'、id 用原始参数串前缀匹配（identity=x 命中）、itag 精确等值解析、整段异常吞掉返回 false | `VideoSniffAlgo.processYtDashSegment`（:811-895）+ `parseKeyValuePairOf`（:671-678）+ `parseInt64Gate`（:648-657） | D6/D10/D11 用例钉死三个怪癖 |
| 4 | :702-714 AddIfNew 自队尾按 (Length,ID) 去重；:763-784 AddToQueue 入队前 >32 裁剪（稳态 33）；:786-823 GetDASHPair 队尾扫描+音频侧 lastVid 同 Length 守卫 | `VideoSniffAlgo.addToQueue`（:694-705）/`getDashPair`（:710-736）/私有 `addIfNew`（:682-690） | D14~D19 用例钉死 |
| 5 | :904-966 Itags 表 60 项（研究结论 63 为勘误，逐行清点），'Hi  bitrate' 双空格逐字；查不到默认 'MKV' | `ITAG_KEYS`/`ITAG_VALUES` 平行数组+`itagQuality`（:901-924） | D21/D22/D23 用例钉死；ArkTS Record 键必须 string 故用平行数组 |
| 6 | :547-587 HandleDashAudio：URL 末段无扩展名且 mime 非 webm/mp4 时 ext='mkv' 缺前导点，文件名 '名字mkv'、显示 '[KV AUDIO]'；:589-613 CreateDual 恒 '.mkv' 后缀、长度取两段和 | `handleDashAudio`（:742-765）/`createDualInfo`（:769-791），经 `SegSink` 回调（interface :638-641）上报，BridgeRoutes 组装（:116-125） | 怪癖 1:1 保留（设计书 §0-3 拍板），D13 钉死 |
| 7 | :873-902 IsMediaFragment/AddToSkippedRefererList：Referer 的 SHA1 小写十六进制写跳过集 | `sha1Hex` 纯 TS（:485-579）+ `BridgeRoutes.addToSkippedRefererList`（:456-461）/`isMediaFragmentGuard`（:503-508） | Dictionary 降 Set（时间戳无读取面，§4-4）；C5/C6 用例验证 |
| 8 | VideoTracker.cs:313-376 AddVideoDownload 按 yt-video-hls-dash 查表、仅 yt/video 两表有 LinkAccepted 守卫位、自动分支 sanitize 对话框分支传原名；:372-376 IsFFmpegOK | `CapturedVideoTracker.addVideoDownload`（:311-330）+私有 `isFFmpegOK`（:370-375）；/vid（`BridgeRoutes.ets:207`）与 --media-vid（:278）改调 tracker | null vid 抛 Error 断连 1:1（:337-339）；LinkAccepted 恒 false 注释锚随迁 |
| 9 | VideoTracker.cs:242-311 三个单条登记重载（DualSource 入 yt 表、HLS 入 hls 表、DASH 入 dash 表）；MediaCaptureWindow.xaml(.cs) 640x400 单选列表+Close/Download/Clear | `addDualSourceVideo`/`addHlsVideo`/`addDashVideo`（:235-285）+ `getTrackedVideos` 富投影（:290-298）+ `pages/VideoCapture.ets` 全量 | 批量重载不落（调用方属 U6.4/U7.1）；页面按单元指令落全选/分组增强（§4-8） |

另有两项研究结论作为本单元边界的依据：/link pending 源语义存 `{url,file}` 对（ApplicationCore.cs:195 附近），本单元收敛 b 落地；MP3 复选框门（NewVideoDownloadDialogUIController.cs:40-47）由收敛 c 的 '' 登记保证 normal 条目无复选框，F2~F4 用例验证。

## 3 设计决策与有意差异

### 3.1 引用的 MIGRATION_PLAN 决策条款

- **决策 5（浏览器集成）**：BridgeServer 复刻 8597 八路由、扩展直接复用。本单元遵守该拓扑：扩展端八层过滤只在扩展端跑（U6.3 原样复用扩展本体），服务端镜像件禁止接入 /media，防止双重过滤改变行为（设计书 §0-1 红线，结构断言见 §5）。
- **决策 11（UI 第三平台）**：按 XDM.Core/UI 契约实现 ArkUI 版、Navigation/NavDestination 路由。VideoCapture 页为应用内 NavDestination，module.json5 与 main_pages.json 均不动（main_pages 只保留 Index 与探针页）。
- **决策 2（线程模型）**：锁不复刻。tracker 四表与嗅探状态在单线程事件循环内单写者持有（`sharedSniffState` 单例，BridgeRoutes.ets:112），源 lock(this) 与 ReaderWriterLockSlim 语义由单写者模型替代。
- **§3 降级清单与 §7 Phase 6 第 3/4 项**：HLS/DASH 捕获页显示但不解密；Topmost 复选框与 HowTo 外链不渲染（HarmonyOS 应用内页无窗口置顶语义）。
- **§9-3 单元纪律**：BridgeRoutes 改动仅限收敛项授权面，F1（--media-tab-url 缺 title 仍改名）因此延后 U6.3（设计书 §0-4）。

### 3.2 有意差异清单（设计书 §4 共 15 项，要点与执行核况）

1. **规则链双镜像口径**（§4-1）：isMatchingRequest+passesSendGate 为纯函数规格件；分派链在 BridgeRoutes 补锚。【V】`grep -n "isMatchingRequest" entry/src/main/ets/core/bridge/BridgeRoutes.ets` 零命中，红线成立。
2. **manifest 三分支只落识别+两表写入**（§4-2）：写入点保持源序（manifest 拉取之前），网络无关即消除 U6.1 §7-3 的 .ts 段误入 videoList 暂态；解析器留 U6.4/U7.1 锚（hilog 识别锚后继续）。Node C3/C4 验证。
3. **Itags 60 项**（§4-3）：研究结论 63 勘误，D22 钉死。【V】实读 `ITAG_KEYS`（:901-904）清点为 60。
4. **referersToSkip 由 Dictionary 降 Set**（§4-4）：源时间戳只写不读，键存在性即全部语义。
5. **队列稳态上限 33**（§4-5）：入队前裁剪 1:1，非"上限 32"。
6. **parseInt64Gate 以 2^53 为上界**（§4-6）：clen 超 Number.MAX_SAFE_INTEGER 视为解析失败走 catch；.NET Int64 全域不复刻，现实流量不触发。审查 R1-F3 指出 itag 源用 Int32.Parse（±2^31），落在 (2^31,2^53] 的畸形 itag 端口不抛异常而源抛，未在 §4-6 覆盖，维持现状（见 §4 处置表）。
7. **Uri.UnescapeDataString 用 decodeURIComponent try/catch 近似**（§4-7）。
8. **VideoCapture 页增强**（§4-8）：全选/多选+四组分组呈现（源为 SelectedIndex 单选+平铺，依据单元指令与 UNIT_CATALOG"全选"）；每 id 下载动作 1:1 源；事件到达全表重渲染替代按 ID 增改（观测收敛等价）。
9. **ShowMediaNotification 托盘气泡降级**（§4-9）：log+MediaAdded 事件+广播；系统通知 U6.3 端到端时评估。
10. **SHA1 纯 TS 实现**（§4-10）：保 VideoSniffAlgo 零 @kit 与 Node 自验；不用 cryptoFramework。独立复核指出在产实现无常驻可运行测试、注释向量有误（处置见 §4 的 IR-F2）。
11. **大写 host 漏屏蔽**（§4-11）：镜像 hostOfUrl 不小写化，源 new URL().host 恒小写故源端事实大小写不敏感；A17 按镜像行为钉死。该项登记口径与源行为有出入，维持现状（R1-F1，见 §4）。
12. **手写 hostOfUrl/urlPathOf**（§4-12）：WHATWG pathname 百分号规范化不复刻（用例输入全 ASCII 无观测差）。
13. **收敛 a 的文件拓扑**（§4-13）：BridgeUiEvents+startBridgeAutoDownload+pending 上移 BridgeActions.ets；/download 的 addDownloadAction 留 BridgeRoutes（源拓扑在 ApplicationCore.AddDownload）。
14. **F2 族随本单元修、F1 延后 U6.3**（§4-14）。
15. **沿用 U6.1 登记**（§4-15）：LinkAccepted 恒 false、IsFFmpegOK 降级（yt/hls/dash 自动分支不可达）、请求头/Cookie 不注入引擎（U6.3 接通）、SanitizeFileName D6 修正版、DateTime.Now 投影 Date.now()、未知路径静默断连。

### 3.3 R1-F2 修复后的空串 file 实际形态（与设计书 §3.8 原文不一致处以实现为准）

设计书 §1-#4/§3.8/§4-14 原文写"空串 file 同 null 处理（映射为 null）"，这是 R1-F2 修复前的方案。审查 round-1 F2 指出该全局映射会改变 /link、/download、HandleDashAudio 三处源侧不回退的行为，修复采用审查建议的"改回源语义"选项。最终实现（报告员实读核实）：

- `BridgeJson.buildBridgeMessage`（:301）：`file: (data.file === null || data.file.length === 0) ? data.file : sanitizeFileName(data.file)`，空串原样保留 ''，null 保持 null；
- 三个源侧不回退的消费点经文件内私有 `sanitizeOrEmpty`（空入空出，非空委托 sanitizeFileName）：`VideoSniffAlgo.ets:230-232`（HandleDashAudio/CreateDual 文件名）、`BridgeRoutes.ets:546-548`（/link pending 与 /download 自动分支）、Node 镜像同步；
- /media normal 路径的空串回退由 `processNormalVideo` 既有 `file.length===0` 二次回退分支承接（`BridgeRoutes.ets:477-480`），零改动。

设计书相应段落未随修复改写（审查 round-2 F1 指出，维持现状），本报告以本节描述为行为基线。

## 4 审查问题处置表（覆盖全部轮次）

对照审查两轮（round-1 未批准 6 项、round-2 批准 2 项）+ 独立复核 4 项，共 12 项；已修复 1 项（R1-F2），其余维持现状并在此逐项登记。

| 编号 | 严重度 | 问题摘要 | 处置 | 证据 |
|---|---|---|---|---|
| R1-F1 | low | hostOfUrl 不做小写化，源 new URL().host 恒小写，镜像件在大写 host URL 上第①层失效（源会拒）；设计书 §4-11"1:1 源怪癖"登记失实 | 未修，round-2 复核后维持现状。理由：纯规格件未接业务链，现网行为零影响；A17 用例按镜像实际行为钉死 | 【V】`VideoSniffAlgo.ets:254-276` 无 toLowerCase；本会话 grep 确认 isMatchingRequest 未被 BridgeRoutes 引用 |
| R1-F2 | medium | 空串 file 映射 null 在 buildBridgeMessage 全局生效，/link pending、/download 自动分支、HandleDashAudio/CreateDual 三处源侧空串不回退，行为被改变 | **已修复**（改回源语义）：空串原样保留 ''，三消费点 sanitizeOrEmpty，/media normal 由二次回退承接；Node 镜像同步后全量复跑 | 【V】`BridgeJson.ets:301`、`VideoSniffAlgo.ets:230-232`、`BridgeRoutes.ets:546-548`；【V】`node docs/probe/P6-U2-sniff-cases.js` 复跑 65/65 退出码 0；四路径空串 spot check 结果记录于任务书实现摘要（dash-audio='mkv'、dual='.mkv'、pending=''、normal 双扩展名源同貌） |
| R1-F3 | low | parseInt64Gate 对 itag 用 2^53 上界，源 itag 走 Int32.Parse（±2^31），(2^31,2^53] 区间行为偏离，未在 §4-6 登记 | 未修，维持现状。畸形 URL 才可达，现实扩展流量不触发 | 【V】`VideoSniffAlgo.ets:648-657` 单一上界门；设计书 §4-6 仅登记 clen |
| R1-F4 | low | 设计书 §5.1-2 结构断言按字面执行会误报（注释文本命中） | 未修，维持现状；验收执行时按"注释豁免"口径解读 | 【V】本会话实跑 `grep -rn "XDM_PROBE" entry/src/main/ets/core` 得 15 处、`grep -rnE "import .*probe"` 得 3 处，逐条确认全部为红线声明注释文本（如 `Config.ets:40`、`HttpClient.ets:15`），无实际探针输出或探针 import |
| R1-F5 | low | 手册走查清单把 'YT Video.mp4'（HandleDashAudio 单源登记，kind='video'）归入 YouTube 组 | 未修，维持现状；走查按代码实际分组核对（本报告 §6 已给出更正口径） | 【V】实读 `docs/probe/PROBE-...md:139-141` 该行仍在；`CapturedVideoTracker.addSingleSourceVideo` 入 video 表（:220-231），分组由 kind 决定（`VideoCapture.ets:91-104`） |
| R1-F6 | low | /link 全空 url 批次不触发 onShowBatchSelection，源 AddBatchLinks 空列表也开选择窗 | 未修，维持现状。降级事件面当前无观测者，边缘行为差异 | 【V】`BridgeRoutes.ets:238-245` 保留 `links.length > 0` 门 |
| R2-F1 | low | 设计书 §1-#4/§3.8/§4-14 仍描述"空串映射 null"，与 R1-F2 修复后实现脱节 | 未修设计书；行为基线以本报告 §3.3 为准（实现正确，文档滞后） | 【V】设计书 :24/:195-197/:226 实读仍在；实现见 R1-F2 行证据 |
| R2-F2 | low | round-1 五项低危（R1-F1/F3/F4/F5/F6）维持现状且未登记差异清单 | 部分处置：本报告 §4 逐项登记（即处置动作），§7 汇总风险 | 【V】round-2 F2 所列五处位置本会话逐一复核，均与 round-1 相同（见各行证据） |
| IR-F1 | medium | processNormalVideo 登记携带 tabUrl，端口 /tab-update 会改 video 表条目名；源 ProcessNormalVideo 不设 TabUrl，仅 HandleDashAudio 条目可被改名 | 未修（独立复核结论 acceptable）。属未登记的源行为偏离，建议 U6.3 与 F1（--media-tab-url）同面拍板：改传 '' 或登记差异 | 【V】`BridgeRoutes.ets:494-497` 传 `msg.tabUrl ?? ''`；`CapturedVideoTracker.renameInTable`（:401-414）按 tabUrl 等值命中即改名 |
| IR-F2 | low | 在产纯 TS SHA-1 无常驻可运行测试（Node 脚本 sha1Hex 直接用 node:crypto，E1/E2 验的是 node:crypto）；代码注释两处引用的 sha1('abc') 向量非真实值 | 未修。独立复核人在其会话内将 :485-579 转写 JS 对 node:crypto 做 20 万次随机 fuzz+双已知向量零失配（实现正确，记录于复核材料）；建议 U6.3 把转写本落进 Node 脚本并修正注释 | 【V】本会话实跑 `node -e` 计算真实向量：sha1('abc')=a9993e364706816aba3e25717850c26c9cd0d89d，与注释 `VideoSniffAlgo.ets:16`/:480-481 所引 'a9993e36470698a983e259040d7036b31f7d5f7' 不符（sha1('') 向量一致）；【V】Node 脚本 :274-276 实读为 `crypto.createHash('sha1')` |
| IR-F3 | low | sanitizeOrEmpty 只覆盖"输入为空串"，"输入非空但源 Sanitize 输出为空"（如 file='a/'）经 FileNames 的 'file' 兜底后行为偏离源（源产空串触发回退/裸扩展名） | 未修，维持现状。页签标题含尾分隔符的输入才可达 | 【V】`FileNames.ets` 'file' 兜底与三处 sanitizeOrEmpty 位置由复核记录，报告员未逐行复核 FileNames |
| IR-F4 | low | processNormalVideo 的 Content-Length 强门只有十进制正则无数值上界，超 Int64 域 CL 串源抛异常断连、端口照常收编（>2^53 失真）；与 parseInt64Gate 口径不一致且未登记 | 未修，维持现状。畸形/理论输入可达，现实扩展流量不触发 | 【V】`BridgeRoutes.ets:108`（INT64_DECIMAL）与 :486-493（gate+Number）实读 |

独立复核标注的最弱环节：VideoCapture 页勾选框视觉依赖 Toggle 构造参数 isOn 在 @State 变化后重新生效，框架联动无法静态证实，该页当前只有人工走查覆盖、无机器探针；行高亮与 selectedIds 是权威态，最坏情况为勾选视觉不同步，不致崩溃。

## 5 验证情况

### 5.1 hvigor 编译门禁（主门禁）

通过【R】。门禁结论：hvigor 全量编译（`devecocli build --modules entry`）最终状态通过。按单元纪律由统一门禁脚本执行，报告员本会话未复跑；当前代码可构建，无需不可构建标注。ArkTS 严格子集由 hvigor 编译期强制（MIGRATION_PLAN §8 验证矩阵），本单元编码全程按 arkts-grammar-standards 技能自查（禁 any、对象字面量具类型、无结构化类型、正则用 new RegExp 构造、throw 只抛 Error），三份核心文件的此类红线在文件头注均有登记。

### 5.2 codelinter 辅助检查（提示性）

exit 0【R】。Issues 20：Errors 0 / Warnings 18 / Suggestions 2，检查 6 文件。样例：Index.ets:1441 `@performance/hp-arkui-set-cache-count-for-lazyforeach-grid`（LazyForEach 于 grid 时建议设 cachedCount）。全部为提示级，不阻断；codelinter 不含 ArkTS 语法规则（语法合规由 hvigor 承担）。输出尾部有 Node ExperimentalWarning（Importing JSON modules），为工具自身噪声，与本单元代码无关。

### 5.3 规则链用例表（验收主证据，本会话实跑）

命令：`node docs/probe/P6-U2-sniff-cases.js`（工作目录 XdmHarmony 工程根）。结果：65 例逐条输出 pass，`SUMMARY pass=65 fail=0 total=65 groups={"A":18,"B":9,"C":8,"D":23,"E":3,"F":4}`，进程退出码 0。A 组八层过滤与 sendGate、B组分派谓词与 itag 边界、C组分派链全流程（含 C4 暂态消除）、D 组 YT-DASH 配对 23 例（含 D6 尾随 '&'、D10 大写 ITAG、D13 缺点 mkv、D22 Itags 60 项）、E组 SHA-1 形状与 LinkAccepted 谓词备查、F组 pending 对与 MP3 复选框门。

### 5.4 结构断言（本会话实跑）

- `grep -n "isMatchingRequest" entry/src/main/ets/core/bridge/BridgeRoutes.ets`：零命中（红线"镜像不接业务链"成立）。
- `grep -rn "XDM_PROBE" entry/src/main/ets/core`：15 处命中，逐条确认为注释中的红线声明文本；`import .*probe` 3 处同为注释。按 R1-F4 处置口径判为通过（无实际探针输出/引用）。
- `git status --short`：module.json5、main_pages.json、EntryAbility.ets 均不在改动清单，与设计书"配置文件决议：三者不动"一致。
- `node -e "require('./docs/probe/EXPECT-u6-2-...json')"`：JSON.parse 通过，11 步骤（BEGIN+S1~S8+SUMMARY+END），unitId=P6-U2。

### 5.5 对照审查与独立复核

- 对照审查：round-1 六项发现（1 medium 5 low），未批准；R1-F2 修复并全量复跑后 round-2 批准（附两项低危登记，F1/F2 均维持现状）。已修复问题编号清单：R1-F2。
- 独立复核：结论 acceptable=true，四项发现（1 medium IR-F1、3 low），全部维持现状并在 §4 登记；实现正确性方面复核人另做了纯 TS SHA-1 的 20 万次 fuzz 交叉验证（零失配，其会话内执行，记录见复核材料）。
- Hypium 本地用例：`VideoSniffAlgo.test.ets` 63 断言组（头注 :11）、`BridgeRoutes.test.ets` 收敛 a/b/c 回归增补、`List.test.ets` 注册并同步头注计数至 422（:40/:48/:74）。本地 runner 本会话不可实跑（注记同 U6.1），用例已入库不碍编译门禁；纯逻辑行为由同源 Node 镜像轨（§5.3）代验。

### 5.6 未执行的验证（如实列出）

- hvigor 编译与 codelinter 本会话未复跑（结论引自门禁材料，见 5.1/5.2）。
- 设备侧探针 P6-U2、VideoCapture 页人工走查、真实浏览器流量：均待人工在模拟器/真机执行（见 §6）。
- Hypium 用例未在本会话运行（runner 不可用）。

## 6 运行时验证待办

1. **设备侧探针 P6-U2**（[P] 验证项）。手册：`docs/probe/PROBE-u6-2-sniff-rule-chain-video-capture.md`（含 hdc 全路径、一次性签名准备、启动命令）；预期表：`docs/probe/EXPECT-u6-2-sniff-rule-chain-video-capture.json`（11 步骤，机器可读）。运行方式：`devecocli run --module entry` 安装拉起后，`%HDC% shell aa start -b com.example.xdmharmony -a EntryAbility --ps page probe` 打开探针页，P6-U2 卡片 autoStart 全自动跑 S1~S8；日志回贴后由 `xdm-probe-verify` 工作流逐步骤核对。
2. **主机侧 Node 用例轨**：已由报告员本会话实跑通过（§5.3），归档为"规则链用例表全绿"的 AI 可自验证据，无需设备。
3. **VideoCapture 页人工走查**（[H] 项，菜单进入、四组呈现、单选/全选、Download 事件计数、Clear、Close）。走查第 2 条的分组归属按代码实际核对，手册该行有笔误（R1-F5）：YouTube 组只有双源条目（如 'YT Video.mkv'）；'YT Video.mp4' 与 'Clipmkv' 是 HandleDashAudio 单源登记，在 Video 组。勾选框视觉与行高亮同步同时人工观察（独立复核最弱环节）。
4. **真实 HLS 测试流观测**（建议项，不作本单元验收）：U6.3 扩展栈就绪后用公共测试流（手册已给样例 URL）验证 .m3u8 识别与 .ts 段拦截的端到端表现。

## 7 遗留问题与风险

| # | 事项 | 性质 | 去向 |
|---|---|---|---|
| 1 | IR-F1：normal 条目携带 tabUrl，/tab-update 可改 video 表条目名（源不可） | 未登记的源行为偏离（medium） | U6.3 拍板：改传 '' 或登记差异 |
| 2 | R1-F1：镜像件大写 host 偏离源（源恒小写）；R1-F3：itag 上界口径 | 镜像件理论偏离（low，未接业务链） | U6.3 扩展复用时以源扩展本体为准，规格件仅作对照基准 |
| 3 | R1-F5 手册分组归属笔误；R2-F1 设计书 §3.8 描述过时 | 文档（low） | U6.3 文档批次顺手修 |
| 4 | LinkAccepted 恒 false：重复链接不去重差异继续 | 既有降级（U6.1 ★3） | U6.3 与 LinkRefreshWindow 一起落（E3 谓词已备查） |
| 5 | IsFFmpegOK 降级：yt/hls/dash 条目自动分支不可达 | 既有降级 | U7.2 接 IsFFmpegInstalled 真值 |
| 6 | 请求头/Cookie 不注入引擎 | 既有降级 | U6.3 接通 |
| 7 | HLS/DASH 识别后无解析（hls/dash 表仅探针种子可填） | 单元边界（设计书 §0-2） | U6.4/U7.1 |
| 8 | 在产纯 TS SHA-1 无常驻可运行测试；注释向量两处错误 | 测试链（low，实现本身已经 fuzz 验证） | U6.3（IR-F2 建议） |
| 9 | VideoCapture Toggle isOn 视觉联动未静态证实 | 潜在 UI 小缺陷（不致崩溃） | 人工走查观察；必要时改用受控属性写法 |
| 10 | /link 空批次不触发批量事件（R1-F6） | 边缘行为差异（low） | 如需对齐源在 U6.3 处理 |
| 11 | 工作树存在未跟踪文件 `nul`（Windows 重定向产物，非源码） | 仓库卫生 | 人工提交前删除（`git status --short` 本会话实跑可见 `?? nul`） |

## 8 对下个单元（U6.3 扩展复用+端到端接管）的建议

1. **tab-update 面合并拍板**：IR-F1（normal 条目 tabUrl）与本单元延后的 F1（--media-tab-url 缺 title 仍改名）同属 /tab-update 行为面，建议一次拍板并同步修 U6.1 设计 §3.4-5 的口径注记。
2. **LinkRefresher 落地**：状态机纯逻辑+两拦截点（/download 的 addDownloadAction 与 tracker.addVideoDownload 的 yt/video 守卫位），匹配谓词 FileSize==ContentLength 且>0 已备查（VideoSniffAlgo.test.ets:251 注释）；窗口 UI 同批交付。落地前需引擎侧 FileSize 查询口。
3. **pending {url,file} 消费**：勾选窗（DownloadSelectionWindow 对应物）按 U6.1 R4-F5 消费 `PendingBatchLink[]`（BridgeActions.ets:94-96 的 getter 已就位）。
4. **补在产 SHA-1 测试**：把纯 TS 实现转写本落进 Node 脚本（或 Hypium 轨）使 E1/E2 覆盖在产算法，顺带修正 VideoSniffAlgo.ets:16/:480-481 两处注释向量（真实值见 §4 IR-F2 行）。
5. **isMatchingRequest 复用口径**：U6.3 复制扩展本体时，以扩展端源码为运行基准；VideoSniffAlgo 规格件仅作行为对照与回归用例，两处已知偏离见 §7-2。
6. **系统通知评估**：ShowMediaNotification 降级（§4-9）在端到端接线时决定是否接 wantAgent 通知。
7. **手册与设计书小修**：§7-3 所列文档项一批处理；提交前删除 `nul` 文件。

## 9 提交说明

本单元代码未做 git 提交。工作树现状（`git status --short` 本会话实跑）：修改 12 个文件（BridgeJson/BridgeRoutes/CapturedVideoTracker/VideoSniffAlgo/Index/ProbeIndex/ProbeBridgeRoutes/三份 string.json/BridgeRoutes.test/List.test），新增 8 个文件（设计书、Node 用例表、探针手册、EXPECT、BridgeActions.ets、VideoCapture.ets、ProbeVideoSniff.ets、VideoSniffAlgo.test.ets），另有未跟踪 `nul` 待清理。按 MIGRATION_PLAN §9-3 与 UNIT_CATALOG 提交节奏，待人工验收后由人执行 git 提交（单元粒度回滚点）并在 Phase 6 末打 `phase-6` tag。许可证：本单元为对照 GPL-2.0 源码的跨语言重写，属衍生作品，分发遵循 GPL-2.0（MIGRATION_PLAN §11），交付报告需保留该声明。
