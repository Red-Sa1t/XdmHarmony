# U7.1 DashDownloader（DASH 解析、计划与捕获接线）设计

> 同构基准：[u6-4-hls-DESIGN.md](./u6-4-hls-DESIGN.md)。core/adaptive/ 的管线 14 模块（AdaptivePlan/Protocol/Scheduler/RunController/Assembler/AttemptExecutor/AttemptFile/RcpStream/DownloadThrottle/StateCodec + ManifestClient + Hls 三件）**冻结复用，零架构改动**；本单元只新增 DASH 与 HLS 的差异面：MpdParser 全量翻译（XML 边界 + 三寻址 + Timeline 状态机 + 模板变量）、buildDashPlan（计划层 Dash 分支）、捕获侧 tracker dash 表接线（VideoSniffAlgo/BridgeRoutes）、探针 P7-U1 三件套与手册。
> 源事实依据：本单元研究结论 + `migration-runs/202610080259/u7-1-dash-source-facts.md`、`u7-1-dash-xml-sdk-facts.md`（SDK d.ts 实测：parseXml 自 API14、SAX 自 API24；工程 compatible 23 → 采用 Pull/parseXml 路径）。

## 0. 范围裁定（与 u6-4 同构对齐）

| 项 | 裁定 | 依据 |
|---|---|---|
| 捕获侧（嗅探→MPD 解析→tracker dash 表） | **本单元接线**：BridgeRoutes.ets:433-438 的 U7.1 锚升级为真实捕获路径 | 单元指令②；源 ProcessDashVideo（VideoUrlHelper.cs:183-276）在嗅探期同步解析；addDashVideo（CapturedVideoTracker.ets:281）U6.2 已落 |
| 下载侧（Tracker 条目→Manager→管线→发布） | **不在本单元落**：与 HlsDownloader 同属 u6-4 外层集成（O2/O3/O7）；本单元以 buildDashPlan + 管线直驱（探针）交付"经 adaptive 管线下载可播"验收 | u6-4-hls-DESIGN.md"后续接线契约"；u6-4-hls-outer-integration-design.md §4 |
| core/adaptive/DashDownloader.ets | 不创建（理由同上；文件名留给外层集成单元） | 同上 |
| VideoCapture.ets | **零改动**（dash 分组 U6.2 已就位，VideoCapture.ets:37-38 GROUP_KINDS 含 'dash'） | 实读核对 |
| module.json5 / main_pages.json | **零改动**（已核对：module.json5:9 deviceTypes 含 2in1、:16 已有 ohos.permission.INTERNET；main_pages.json 仅 Index+probe/ProbeIndex，探针经 ProbeIndex 注册不新增路由页） | 实读核对 |
| string.json ×3 locale | **改动**：+3 个探针标题键（对齐 probe_p6u4_title 先例，base/zh_CN/en_US 各 :853-855） | 实读核对 |
| POST 清单（message.RequestMethod=POST + base64 body，源 VideoUrlHelper.cs:849-857） | 延后接线（对齐 U6.4 O1 明示"POST/request-body 捕获另行接线"）；本单元捕获路径 **GET-only** | openQuestion 3 采纳 |

## 1. 源对照与数据流

只读依据（resourses/xdm，全部只读核对）：

| 源文件 | 位置 | 本单元对应 |
|---|---|---|
| MediaParser/Dash/MpdParser.cs（431 行） | :18-19 模板正则；:32-37 根门；:41-66 Parse 根；:69-128 ParsePeriod；:130-149 ParseAdaptationSet；:151-306 ParseRepresentation；:308-348 ParseTemplate；:350-359 FormatDigit；:361-397 多周期时长；:399-420 trickmode | DashParser.ets 全量翻译（§4 逐公式） |
| MediaParser/Dash/DashUtil.cs（42 行） | :8-40 ParseXsDuration | DashUtil.ets |
| MediaParser/Dash/Representation.cs（30 行） | 八只读属性 | DashModel.ets DashRepresentation |
| MediaParser/Util/UrlResolver.cs | :10-13 绝对 http(s) 直取/相对拼接 | 复用 resolveHlsUrl（HlsUrlResolver.ets:5，SDK url.URL 语义超集，签名查询/转义保留） |
| BrowserMonitoring/VideoUrlHelper.cs | :183-276 ProcessDashVideo；:278-296 AddSingleItem；:298-331 GetQualityString；:825-871 DownloadManifest | VideoSniffAlgo.ets（纯函数）+ BridgeRoutes.ets（网络/写入半区） |
| Downloader/Adaptive/Dash/MultiSourceDASHDownloader.cs | :16 Type；:25-125 ctor 分块/容器/文件名；:264-268 末段扩展猜测；:270-298 CreateChunks2 交错 | AdaptivePlan.ets buildDashPlan |
| Util/FileExtensionHelper.cs + Util/MimeTypes.cs | :9-46 + :59-67 | guessHlsContainer 复用 + dashMimeExtension（video*/audio* 全 20 行） |
| XDM_Tests/DashSanityTest.cs | :27-31 时长用例；:33-175 四个 MPD 向量 | 逐公式用例表（§6）+ 探针 fixture |

数据流（捕获）：`/media`（BridgeRoutes.processMediaMessage:418）→ ④ isDASH/isDASHUrl 锚（:434，U6.2 已落 tab 登记+referer 写入，序 :187-191 对齐）→ **新增** processDashCapture：await 前快照 msg（headers/cookies/url/file/tabId）→ ManifestClient.fetchGet（GET）→ DashXmlFeed.parseDashManifest（真机 xml.parseXml + 纯语义）→ VideoSniffAlgo.processDashVideo（双轨降级/多轨/单轨 + quality 串）→ CapturedVideoTracker.addDashVideo / addDualSourceVideo / addSingleSourceVideo。解析或下载失败 → log + 整清单跳过（源：异常上抛→本次清单整体丢弃，不进 dash 表）。

数据流（下载，探针直驱）：TrackedVideo dash 条目（videoSegments/audioSegments/videoMimeType/audioMimeType/duration）→ **buildDashPlan**（AdaptivePlan.ets，镜像 buildHlsPlan:373-404 交错循环）→ copyAdaptivePlan 校验（kind='Dash' 分支）→ AdaptiveStateCodec/AdaptiveStateStore（generation CAS，源 RestoreState/SaveState 对应物）→ AdaptiveRunController（E4：分块认领/重试/限速/检查点）→ AdaptiveReadyInput.lease → AdaptiveAssembler（F：单轨拼接 / 双轨 MediaProcessorNapi remux + .mkv 降级，AdaptiveAssembler.ets:8 已接 U0.4）→ 产出 .mp4/.mkv。

## 2. 目标文件清单（实现顺序）

| # | 文件 | 职责与对外导出 | dependsOn |
|---|---|---|---|
| 1 | `entry/src/main/ets/core/adaptive/DashModel.ets`（新） | 纯 DASH 元数据与预算常量：`DashRepresentation`（镜像 Representation.cs 八字段：segments:string[]/width/height/codec/bandwidth/duration/mimeType/language）、`DashPair{video,audio}`、`DASH_TRICK_MODE_URI`、预算常量组（§3.3）、`DashPeriodAttrs{duration,start}`（多周期输入形态）。零 @kit 导入 | — |
| 2 | `entry/src/main/ets/core/adaptive/DashUtil.ets`（新） | `parseXsDuration(value): number`（DashUtil.cs:8-40 直译，抛错=清单丢弃语义）。零 @kit | — |
| 3 | `entry/src/main/ets/core/adaptive/DashParser.ets`（新） | 纯语义层：`DashXmlEvent`/`DashXmlNode` 类型、`buildMpdTree(events)`（有界树）、`parseDashManifestFromEvents(events, playlistUrl, resolve): DashPair[][]`（根门/周期/组合全逻辑，失败 throw=整清单丢弃）、`parseDashTemplate(url, number, time, bandwidth, representationId)`、`parsePeriodDurations(periods, total)`。零 @kit（resolve 以 `DashUrlResolver` 函数注入，复用 HlsModel 的 HlsUrlResolver 类型——HlsParser.ets 同款注入惯例） | 1, 2 |
| 4 | `entry/src/main/ets/core/adaptive/DashXmlFeed.ets`（新） | SDK 适配层（唯一 @kit 触点）：`decodeMpdEvents(text): DashXmlEvent[]`（xml.parseXml + token/attr 回调 + 预算，结构事实）、`parseDashManifest(text, url, resolve)`（compose 3+本层）。仅被 BridgeRoutes/探针引用，Hypium 不导入（@kit 模块本地单测不可依赖） | 3 |
| 5 | `entry/src/main/ets/core/adaptive/AdaptivePlan.ets`（改） | 新增 `buildDashPlan(manifestUrl, videoSegments, videoMime, audioSegments, audioMime, videoDuration, audioDuration)`（交错建计划，镜像 buildHlsPlan:373-404）+ `dashMimeExtension(mime)`（MimeTypes.cs video*/audio* 20 行）+ copyAdaptivePlan **kind='Dash' 分支**（§3.2）。Hls 分支与既有字段契约零改动 | 1 |
| 6 | `entry/src/main/ets/core/bridge/VideoSniffAlgo.ets`（改） | 新增纯函数：`dashQuality(video, audio)`（GetQualityString :298-331 逐字符对齐）、`processDashVideo(periods, file): DashCaptureItem[]`（ProcessDashVideo :202-273 + AddSingleItem :278-296 的条目映射半区，双轨降级/前缀/ext/displayText）、`DashCaptureItem` 类型。零 @kit 惯例保持 | 1 |
| 7 | `entry/src/main/ets/core/bridge/BridgeRoutes.ets`（改） | 捕获接线：④锚分支追加 `processDashCapture(msg)`（fire-and-forget async，await 前快照；ManifestClient 模块级单例 GET；结果→tracker 三写入方；catch→log+跳过）。既有锚 log/two-writes 顺序保持 | 4, 5, 6 |
| 8 | `entry/src/main/ets/probe/units/ProbeDashFoundation.ets`（新） | P7-U1-F 六步骤（§7.1）：xml 边界/时长表/Timeline/simple/三寻址+多周期/拒绝门+BBC | 1, 2, 3, 4 |
| 9 | `entry/src/main/ets/probe/units/ProbeDashPipeline.ets`（新） | P7-U1-P 六步骤（§7.2）：主机真 HTTP 清单→buildDashPlan→E4 全量下载→单轨拼接→双轨 remux→恢复与拒绝 | 4, 5 |
| 10 | `entry/src/main/ets/probe/units/ProbeDashController.ets`（新） | P7-U1-C 五步骤（§7.3）：镜像 ProbeAdaptiveController 步骤形态，换 Dash 计划 | 5 |
| 11 | `entry/src/main/ets/probe/ProbeIndex.ets`（改） | PROBE_UNITS + import + else-if 三分支（:38-59/:81- 表尾追加惯例） | 8, 9, 10 |
| 12 | `entry/src/main/resources/base/element/string.json`（改） | `probe_p7u1_foundation_title`/`probe_p7u1_pipeline_title`/`probe_p7u1_controller_title` | 11 |
| 13 | `entry/src/main/resources/zh_CN/element/string.json`（改） | 同上中文 | 11 |
| 14 | `entry/src/main/resources/en_US/element/string.json`（改） | 同上英文 | 11 |
| 15 | `entry/src/test/DashUtil.test.ets`（新） | parseXsDuration 用例 10 条（§6） | 2 |
| 16 | `entry/src/test/DashParser.test.ets`（新） | 逐公式用例 30 条（§6；事件注入式，不用 @kit） | 1, 2, 3 |
| 17 | `entry/src/test/AdaptivePlan.test.ets`（改） | +buildDashPlan/Dash 校验 12 条 | 5 |
| 18 | `entry/src/test/VideoSniffAlgo.test.ets`（改） | +dashQuality/processDashVideo 10 条 | 1, 6 |
| 19 | `entry/src/test/List.test.ets`（改） | 注册 DashUtil/DashParser 两套件 + 头注计数更新（AdaptivePlan/VideoSniffAlgo 已注册零改动） | 15, 16, 17, 18 |
| 20 | `docs/probe/P7-U1-dash-host.cjs`（新） | 主机固定 MPD/分段源（P6-U4-manifest-host.cjs 同款：只自产响应，无文件浏览/转发）：4 向量 MPD、dynamic/encrypted/no-period 反例、init+media 分段字节 | — |
| 21 | `docs/probe/PROBE-u7-1-dash-foundation.md`（新） | P7-U1-F 手册（含 DASH 公共测试流指引） | 8 |
| 22 | `docs/probe/PROBE-u7-1-dash-pipeline.md`（新） | P7-U1-P 手册 | 9, 20 |
| 23 | `docs/probe/PROBE-u7-1-dash-controller.md`（新） | P7-U1-C 手册 | 10, 20 |
| 24 | `docs/probe/EXPECT-u7-1-dash-foundation.json`（新） | P7-U1-F 期望表（pending-device-run） | 21 |
| 25 | `docs/probe/EXPECT-u7-1-dash-pipeline.json`（新） | P7-U1-P 期望表 | 22 |
| 26 | `docs/probe/EXPECT-u7-1-dash-controller.json`（新） | P7-U1-C 期望表 | 23 |
| 27 | `docs/design/u7-1-dash-DESIGN.md`（本文件） | — | — |

## 3. 数据模型（对照源码逐项核对）

### 3.1 DashRepresentation ↔ Representation.cs:6-28

| C# | ArkTS | 核对 |
|---|---|---|
| `List<Uri> Segments` | `segments: string[]`（含 init/首段；绝对 URL） | 源解析期已 Resolve；Uri.ToString→string |
| `int Width/Height` | `width/height: number`（缺省 -1） | Int32.Parse(width ?? "-1")，MpdParser.cs:174/199/243/298 |
| `string Codec` | `codec: string`（可为 ''） | 属性缺省 → C# null；ArkTS 统一 ''（映射层判空，无观测差异） |
| `long Bandwidth` | `bandwidth: number`（缺省 -1） | Int64.Parse；$Bandwidth$ 替换仍用原始属性串（:156/:344）→ 原始串需旁路传递 |
| `long Duration` | `duration: number` | =periodDuration（ms），三寻址共用 |
| `string MimeType` | `mimeType: string` | 小写化后 audio/video 前缀门（:153/:160） |
| `string Language` | `language: string` | 同 Codec 缺省处理 |

`DashPair{video: DashRepresentation|null, audio: DashRepresentation|null}` ↔ KeyValuePair<Representation?,Representation?>（:109-125）。

### 3.2 AdaptivePlan Dash 分支（AdaptivePlan.ets 改动面）

`AdaptivePlan.kind` 取值扩展 `'Hls'|'Dash'`；**AdaptiveTrack/AdaptiveChunk 零新字段**（AdaptiveStateCodec.ets:53/:80 objectFields 精确字段数校验对旧 HLS 状态的兼容红线，AdaptivePlan.ets:70-76 同款）。

| 计划要素 | HLS（冻结，:240-308） | Dash（本单元） |
|---|---|---|
| chunk 形态 | BYTERANGE → offset/length；MAP init → isInit=true | **恒 offset=0 / length=-1 / isInit=false / duration=0**（源 CreateChunk：Offset=0/Size=-1，MultiSourceDASHDownloader.cs:133-145；init 段就是 segments[0]，无特判——CreateChunks2 逐段入列） |
| 交错 | primary 全长循环内 primary[i]+secondary[i]（:389-401） | 同构交错：min(v,a) 对（video=track0/audio=track1）+ video 尾段 + audio 尾段（CreateChunks2:275-297 逐行） |
| mediaSequence | playlist MEDIA-SEQUENCE 连续 | =trackOrder（单调连续，天然满足 :274-280 既有序列校验器）；discontinuity 恒 false/0 |
| track.role | dual: video/audio；单轨 muxed | **恒双轨** video/audio（单轨 DASH 走 SingleSourceHTTPDownloadInfo 不进计划，源 :261-267→AddSingleItem） |
| track.container | 末 chunk URL 扩展推断（:298-301 强校验） | mime 链：`dashMimeExtension(mime) ?? guessHlsContainer(末段扩展)`（:61-64：Format ?? mime ?? GuessContainerFormatFromPlaylist） |
| suggestedExtension | guessHlsContainer(c0,c1) 合并（:303-305） | `dashMimeExtension(videoMime) ?? guessHlsContainer(video 容器)`（:91-92）＝tracks[0].container（校验器按此恒等式核） |
| plan.duration | max(两轨 segment duration 和)（:303） | max(videoDuration, audioDuration)（源 :245 Math.Max；分块无时长可反推，构造期断言 + 校验器只做 safeDuration/全 0 分块时长核） |
| 计划上限 | ADAPTIVE_MAX_CHUNKS=20000（:4，=HLS_MAX_SEGMENTS×2） | 复用同预算：每轨 ≤DASH_MAX_SEGMENTS(10000) → 双轨 ≤20000 恰合 |

校验器 `copyAdaptivePlan`：kind!=='Hls' && kind!=='Dash' → null（:252 一处分支化）；Dash 分支跳过末-URL-容器强校验（:298-301，smooth 模板 URL 无扩展名）、其余（isAdaptiveHttpUrl/序列连续/交错序/预算/恒等式）全部复用。StateCodec/Store/RunController 零改动（构造器 :372-377 经 copyAdaptivePlan 自动获得 Dash 计划接受能力）。

### 3.3 预算常量（DashModel.ets；源无界 → 目标设界，超限 throw=整清单丢弃）

| 常量 | 值 | 对齐 |
|---|---|---|
| DASH_MAX_MANIFEST_CHARS | 2097152 | =HLS_MAX_MANIFEST_CHARS（ManifestClient.ets:12 字节预算 8Mi 的 UTF-16 面一致） |
| DASH_MAX_NODES / DASH_MAX_DEPTH | 20000 / 64 | XML 树界（研究结论边界清单；HlsParser 行数界同量级） |
| DASH_MAX_ATTRS_PER_NODE / DASH_MAX_TEXT_CHARS | 256 / 32768 | =HLS_MAX_ATTRIBUTES / HLS_MAX_LINE_CHARS |
| DASH_MAX_PERIODS / DASH_MAX_ADAPTATION_SETS / DASH_MAX_REPRESENTATIONS | 256 / 256 / 2048 | =HLS_MAX_VARIANTS 量级 |
| DASH_MAX_SEGMENTS | 10000 | =HLS_MAX_SEGMENTS（u6-4 设计书"每轨最多10,000块"同款） |
| DASH_MAX_PAIRS | 2048 | video×audio 组合界（笛卡尔积防炸；超出部分条目丢弃+log） |
| DASH_MAX_OUTPUT_URL_CHARS | 8388608 | =HLS_MAX_OUTPUT_CHARS（周期内累计展开 URL 字符） |
| URL 单值 | 复用 HLS_MAX_URL_CHARS=32768 | resolveHlsUrl 内已强制（HlsUrlResolver.ets:9/:27） |

## 4. 关键算法翻译说明（逐公式对照——本单元唯一高风险区）

### 4.1 ParseXsDuration（DashUtil.cs:8-40 → DashUtil.ets）

正则逐字符直译（两段 T 部件串联保持原样，IgnoreCase）：`^(-)?P(([0-9]*)Y)?(([0-9]*)M)?(([0-9]*)D)?(T(([0-9]*)H)?(([0-9]*)M)?(([0-9.]*)S)?)?(T(([0-9]*)H)?(([0-9]*)M)?(([0-9.]*)S)?)?$`。ArkTS 用命名组 neg/year/month/day/hour/minute/second 对齐组号 1/3/5/7/10/12/14。

```
matched: seconds = Y*31556908 + M*2629739 + D*86400 + H*3600 + Min*60 + S*1   // 各组非空才累加，parseFloat
         millis = Math.trunc(seconds * 1000);  neg → -millis                  // :33-34 (long) 截断
unmatched: fallback = parseFloat(value) * 3600 * 1000 → trunc                  // :38 按小时数解释
           parseFloat 得 NaN → throw（对齐 C# Double.Parse 抛 FormatException→清单丢弃）
```
- 年/月系数（月=30.4368 天、年=365.242 天）逐值保留；秒组允许小数（`[0-9.]*`，注意非法形态 "1.2.3" parseFloat=1.2 与 C# Double.Parse 抛错不同 → 用 `^[0-9]*\.?[0-9]*$` 复核后 parseFloat，异常形态 throw）。
- 负号只认组 1（前缀 `-`），数值组件负值由 fallback 保留符号（"-1800" → -6480000000）。
- C# Double.Parse 受运行文化影响（源事实已登记）；ArkTS parseFloat 恒点号——平台差异登记，非行为分支。

### 4.2 根门与骨架（MpdParser.cs:32-66）

| 源 | 语义 | ArkTS |
|---|---|---|
| :32 DocumentElement?.Name != "MPD" → throw | Namespaces=false → 本地名匹配 | ignoreNameSpace=true 后根名 `MPD`；非 MPD（含空文档）throw |
| :34 Attributes["type"]?.Value == "dynamic" → throw | **大小写敏感**（"Dynamic" 不拒——用例钉住） | attrs['type'] === 'dynamic' 精确等值 |
| :36 SelectSingleNode("descendant::ContentProtection") → throw | 任意层后代 | 树全遍历查 name==='ContentProtection'（预算内） |
| :51 child::Period 数 <1 → throw | 至少一周期 | children('Period') 数量门 |
| :42 mediaPresentationDuration ?? "0" | 缺省走 fallback 得 0ms | parseXsDuration(attrs['mediaPresentationDuration'] ?? '0') |
| :44-48 根级 child::BaseURL（取第一个） | 相对 playlistUrl 解析 | resolve(playlistUrl, text)（=UrlResolver.Resolve :10-13 的 SDK 等价物） |

### 4.3 多周期时长反推（:361-397 → parsePeriodDurations）

逆文档序（Stack push 顺排、pop 逆序）逐周期：

```
start、duration 均缺 → throw "Both period start and duration is missing"
duration 存在 → dur=parseXsDuration(duration); list.Add(dur); last = total - dur      // 仅对最后周期正确，中间带 duration 的混合形态会算错——1:1 保留（用例钉死）
否则 → start=parseXsDuration(start); list.Add(last - start); last = start
结束 list.Reverse() → 正序返回
```
源 :387-390 的 `PT0S` 缺省分支是死代码（到该处必有 start，否则已 throw）——**不复刻，注释锚登记**（CapturedVideoTracker.ets:387 LinkAccepted 锚同款惯例）。

### 4.4 Period / AdaptationSet（:69-149）

- :72-75 `Period@duration` 属性存在 → parseXsDuration 覆盖传入值。
- :76-80 周期级 BaseURL 覆盖父级；**各级 BaseURL 局部变量互不污染**（四级链 MPD→Period→AS→Repr 依次相对解析）。
- :83 `hasParentSegmentBase = child::SegmentBase != null`（布尔标志下传；AdaptationSet 级 SegmentBase **不被检查**，落入后续分支——用例钉住）。
- :87-99 组分类按**首个有效 Representation 的 mime 前缀**（audio→audioList，其余→videoList）；`representations.Count==0` 的组跳过。
- :138-141/:399-420 trickmode：AS 的**第一个** child::EssentialProperty 或第一个 child::SupplementalProperty 的 `schemeIdUri` 精确等于 `http://dashif.org/guidelines/trickmode` → 整组返回空（SelectSingleNode 取首语义）。
- :103-126 笛卡尔：video 外层 × audio 内层（序=videoList×audioList 嵌套序）；单侧单列（另一侧 null）。

### 4.5 ParseRepresentation 三寻址（:151-306）——判定顺序固定，不重排

属性继承（:153-158，repr 优先、父 AS 兜底）：mimeType（小写化）→ 非 audio/video 前缀 → null 丢弃；width/height/bandwidth/codecs/lang 同继承。

| 分支 | 源行为 | 逐公式 |
|---|---|---|
| ① index（:170-177） | repr 级 child::SegmentBase **或** hasParentSegmentBase | `segments=[baseUrl]` 单段整文件；sidx/字节范围**不解析**；duration=periodDuration |
| ② list（:178-202） | 仅 repr 级 child::SegmentList | 首段 = 第一个 child::Initialization **??** 第一个 child::RepresentationIndex 的 `sourceURL`（相对解析）；随后逐 SegmentURL 的 `media`；mediaRange/indexRange 不消费；总段数 0 → repr=null |
| ③ template（:203-304） | repr 级 child::SegmentTemplate **?? 父 AS 级**（Period 级不查） | 子分支 4.6/4.7 |

### 4.6 simple 寻址（:212-245）

```
timescale=Int64(模板@timescale ?? 1); duration=Int64(@duration ?? 1); startNumber=Int64(@startNumber ?? 1)
segmentCount = (int)Math.Ceiling( (periodDuration/1000) / (duration/timescale) )      // periodDuration 毫秒
representationId = repr@id（缺失 → throw，对齐 C# NRE→清单丢弃）
number = startNumber;  time = startNumber          // ★quirk：$Time$ 起点为 startNumber 而非 0（:220）
initialization 属性存在 → 先展开 init 段（time=startNumber）插最前
循环 i<segmentCount：展开 media → resolve → push；number++; time += duration        // time 步进用原始 duration（tick 值）
```
**除零/负值精确形态**——C# 为 IEEE double 除法 + `(int)` 强转 + `List<Uri>(capacity)` 负容量抛错三段语义，须逐形态钉死（**对研究结论"duration<=0→0 段"的澄清：该说法只覆盖其中两个子形态**）：

```
num = periodDuration / 1000（double）；den = duration / timescale（C# double 除法：0/0→NaN，x/0→±∞）
ratio = num / den（IEEE）；segmentCount = (int)Math.Ceiling(ratio)
```

| num（periodDuration） | den（duration/timescale） | ratio | C# segmentCount | 结果 |
|---|---|---|---|---|
| >0 | >0 | >0 | ceil，≤int.Max | **正常路径** |
| >0 | +∞（timescale=0 且 duration>0） | 0 | 0 | **0 段**（无 init→repr=null；有 init→init-only 单段 repr，List(0) 合法） |
| >0 | 0（duration=0） | +∞ | (int)+∞=int.MinValue | List 负容量 → throw |
| >0 | <0（duration<0 或 timescale<0） | <0 | ≤-1 | throw |
| =0（periodDuration=0） | 有限或 ±∞ | 0 | 0 | **0 段** |
| 0 | NaN（duration=0 且 timescale=0） | NaN | (int)NaN=int.MinValue（x64 cvt） | throw |
| <0 | >0 | <0 | ≤-1 | throw |
| <0 | <0 | >0 | ceil | **正常路径**（双负镜像保留） |
| <0 | ±∞ | ±0 | 0 | **0 段** |

统一 ArkTS 守卫（覆盖全表，防 Math.ceil(Infinity)=Infinity 挂死循环）：
```
const num: number = periodDuration / 1000;
const den: number = duration / timescale;      // IEEE：0/0→NaN、x/0→±∞，与 C# 同
const ratio: number = num / den;
if (Number.isNaN(ratio) || !Number.isFinite(ratio) || ratio < 0) { throw … }   // NaN/±∞/负 → 源 List 抛错同效
const segmentCount: number = Math.ceil(ratio);
if (segmentCount > DASH_MAX_SEGMENTS) { throw … }   // 源 (int) 溢出→int.MinValue→List 抛错同效；预算门显式化
// segmentCount===0 → 无 init 则 repr=null，有 init 则 init-only 单段 repr（1:1）
```
duration>0 正常但 segmentCount 超预算 → throw（源 (int) 溢出路径同效，目标以 DASH_MAX_SEGMENTS 显式化，§5-4）。

### 4.7 explicit/Timeline 寻址（:247-301）——逐 `<S>` 状态机

```
number = Int64(@startNumber ?? 1);  time = 0L                    // init 段以 time=0 展开（:255 先于 init :263-268）
initialization 存在 → init 段插最前
逐 <S>：
  d  = Int64(@d)        // 必填：缺失→NRE、垃圾→FormatException → throw
  t  = Int64(@t ?? -1)  // 哨兵
  r  = Int64(@r ?? -1)
  if (t > 0) time = t   // ★严格不等号：t="0" 不重置（quirk）；t<0 亦不重置
  duration = d
  展开 media（time）→ resolve → push; number++; time += duration
  if (r > 0) 重复 r 次：展开 → push; number++; time += duration
// r=-1（DASH 规范"重复至周期末"）与 r=0 均只发 1 段——源未实现规范语义，1:1 保留
```
预算：累计 push 数 >DASH_MAX_SEGMENTS → throw（源 List 无界增长，目标设界，§5-3）。

### 4.8 模板变量（:18-19/:222-223/:308-359 → parseDashTemplate）

流程顺序不可变：**先 `$$`→`\u0000` 转义 → 对转义串预扫描一次 Match 列表 → 逐 Match 顺序 String.replace → `\u0000`→`$` 恢复**（:222-223/:231/:238/:266/:280/:290）。

| 变量 | 替换值 | ArkTS |
|---|---|---|
| `$Number$` | number 十进制 | String(number) |
| `$Number%0N d/x` | ToString("dN")/("xN") | d：sign 处理后 String(\|v\|).padStart(N,'0')；x：v.toString(16).padStart(N,'0')（小写；PowerShell 实证 12→000c） |
| `$Time$` / `$Time%0N…$` | 同上，取 time | 同上 |
| `$RepresentationID$` | representationId 原串（可为 ''） | 直接替换 |
| `$Bandwidth$` | **原始属性串**（未转数值，:156 旁路） | 直接替换 |

正则（命名组直译）：`\$(RepresentationID|Time|Time%0(?<time_digits>[0-9]+)(?<time_dx>[dx])?|Number|Number%0(?<num_digits>[0-9]+)(?<num_dx>[dx])?|Bandwidth)\$`。
- 无 dx 形态（如 `$Number%04$`）：源 .NET ContainsKey 对已定义命名组恒真 → dx=""→ ToString("4") 输出**字面量**（实证 12.ToString("4")=="4"，源缺陷）。**目标按 d（十进制补零）处理**（openQuestion 1 采纳；ISO 23009-1 合法清单必带 d/x，不触发该路径）——deviation 登记。
- 负数形态：.NET ("d6")→"-000012"、("x6")→二补全宽；目标统一 sign+幅值 padStart / sign+hex（合法 MPD 时间/编号非负，超规范输入的显式偏差）。
- `media` 属性缺失：simple 分支源 `Attributes?["media"]?.Value` → null → Matches(null) 抛异常；timeline 分支 `.Attributes["media"].Value` → NRE——两者均 **throw=清单丢弃**（ArkTS 统一 throw）。

### 4.9 捕获条目映射（VideoUrlHelper.cs:183-331 → VideoSniffAlgo 纯函数 + BridgeRoutes 写入半区）

```
file = msg.file ?? fileNameFromUrl(url)                       // :185
逐周期（periodIdx 从 0）：prefix = periodIdx===0 ? '' : periodIdx + ' '   // :209
逐 pair：
  ext（双轨）= video.mime 含 'mp4' && audio.mime 含 'mp4' ? 'mp4' : 'mkv'   // :216/:237 子串包含
  name = prefix + sanitizeFileName(file) + '.' + ext
  video && audio：
    v.segments.length===1 && a.segments.length===1 → dual 条目（uri1/uri2=两首段；headers×2/cookies×2）  // :213-234
    否则 → multi 条目（videoSegments/audioSegments 全量、duration=max(v.dur,a.dur)、双 mime、url=manifestUrl） // :235-257
  仅 video → single 条目 uri=segments[0]（★源 quirk：多段单轨只下首段，产物不完整，1:1 保留）        // :259-263→:278-296
  仅 audio → 同上（audioOnly 标记）
displayText = '[' + ext.toUpperCase() + '] ' + dashQuality(video, audio)
dashQuality（:298-331 逐字符）：
  双轨: (h>0 ? h+'p ' : '') + (bwSum>0 ? (bwSum/1024)+' Kbps ' : '') + ' ' + (lang≠null&&lang!=='und' ? lang+' ' : '')
  video-only: resolution + bandwidth（无中间空格/无 lang 段）
  audio-only: lang 段 + bandwidth（★序与双轨不同）
  bwSum = 各侧 bandwidth>0 求和，整除 1024；全空时保留尾随/双空格——逐用例钉死
```

### 4.10 下载侧对应（MultiSourceDASHDownloader.cs → 既有管线复用）

| 源 | 目标 |
|---|---|
| :16 `Type="Mpd-Dash"`、:49 FileSize=-1 | plan 元数据；进度按分块计数（AdaptiveProgress），无总大小假设 |
| :31 Demuxed=两表非 null | buildDashPlan 双轨必填；1&1 降级发生在捕获侧 |
| :270-298 CreateChunks2 交错 + 1_/2_ 前缀临时名 | AdaptiveChunk trackIndex 0=video/1=audio + StateCodec part 文件名（生成代 CAS 承担临时文件簿记） |
| :61-64/:91-92 容器链 | §3.2 track.container/suggestedExtension 规则 |
| :157-236 RestoreState（chunks.db 失败→重建） | AdaptiveStateStore 装载失败 → newAdaptiveState 重建全零 parts（MIGRATION_PLAN 决策 4/10 JSON 化） |
| :238-248 SaveState | RunController 检查点周期提交（既有） |
| 合并 | AdaptiveAssembler：单轨拼接 / 双轨 MediaProcessorNapi remux，.mp4 失败降 .mkv（U6.4 装配面既有） |

### 4.11 线程模型映射

- **解析**：xml.parseXml + 树构建 + 语义全为同步 CPU，运行在调用线程（桥主线程/探针页）。预算（2Mi 字符/2 万节点）封顶最坏停顿，量级与 HlsParser 同类（u6-4 同款主线程纯函数）。**不引入 TaskPool**。
- **捕获网络**：BridgeRoutes 捕获路径为 fire-and-forget async（await 前深拷贝快照 msg；旧会话无法污染快照）。源为同步阻塞 HTTP（DownloadManifest :859 Send）——响应时序差异登记（§5-6）。
- **下载执行**：全继承冻结管线——E4 RunController 主线程异步状态机 + AttemptExecutor/RcpStream（u6-4 设计书"后续调度在主线程维护状态"）；remux 走 AdaptiveAssembler→MediaProcessorNapi（U0.4 native 面）。MIGRATION_PLAN 决策 2 的 TaskPool 只属 Progressive 引擎，adaptive 管线明确不适用。

## 5. 与源码的有意差异清单

| # | 差异 | 理由/依据 |
|---|---|---|
| 1 | `$Number%04$`（无 dx）按 d 处理；源 .NET 输出字面量 "4" 的缺陷不复刻 | openQuestion 1；合法 DASH（ISO 23009-1）不触发 |
| 2 | 负数 %0Nd/%0Nx 输出 sign+幅值补零；不迁移 .NET 二补全宽 | 超规范输入的显式定义（合法 MPD 非负） |
| 3 | 死代码不复刻：parsePeriodDurations 的 PT0S 分支（MpdParser.cs:387-390）、FormatDigit 的 dx="D" 死路径（:353）、MultiSourceDASHDownloader 大段注释块 | 项目"不建死代码、注释锚登记"惯例 |
| 4 | 全套预算设界（§3.3）：清单字符/树节点/深度/周期/组合/每轨段数/累计 URL 字符；数值解析统一严格十进制正则（.NET 宽松空白/进制形态被拒） | 研究结论"必须设界"要求；超限=整清单丢弃（与源异常丢弃同效） |
| 5 | 单轨 DASH 保持源 AddSingleItem 只下 Segments[0] 的 quirk（多段单轨产物不完整不可播） | openQuestion 2 采纳 1:1；验收流选双轨清单规避 |
| 6 | 捕获侧 manifest 拉取异步 fire-and-forget（源为同步阻塞）；响应不等待解析完成 | ArkTS 主线程不可阻塞；await 前快照保证一致性 |
| 7 | 源 DownloadManifest 每次新建 HttpClient 可并行；目标共用模块级 ManifestClient（busy→log+跳过） | U6.4 唯一清单请求面方向（O1）；串行化是显式收敛 |
| 8 | POST 清单（base64 body）延后接线，本单元 GET-only | openQuestion 3；对齐 U6.4 O1/O3 既定延后 |
| 9 | chunks.db 二进制恢复 → AdaptiveStateStore/StateCodec JSON generation-CAS | MIGRATION_PLAN 决策 4/10；"恢复失败重建分块"语义由装载失败→newAdaptiveState 承担 |
| 10 | core/adaptive/DashDownloader.ets 不落盘；业务下载外壳随 u6-4 外层集成（O7）统一落 HlsDownloader/DashDownloader | u6-4-hls-DESIGN.md"后续接线契约"；避免两套并发业务编排 |
| 11 | XML 适配层显式拒绝 DOCDECL/ENTITY_REFERENCE 事件 | 实体展开防护（研究结论 XML 边界项 3）；源 XmlTextReader Namespaces=false 默认亦不展开 DTD |
| 12 | 模块名勘误：MIGRATION_PLAN 决策 7 写 "@ohos.util.xml"，实际为 `@ohos.xml`（parseXml 自 API14；SAX 自 API24 因 compatible 23 不采用） | u7-1-dash-xml-sdk-facts.md 实测 d.ts |
| 13 | BBC 向量源测试的 playlistUrl 带尾随空格（C# Uri 宽容）；目标 fixture 用修剪后 URL | resolveHlsUrl 拒绝非 trim 输入（HlsUrlResolver.ets:7，有意收紧） |

**MIGRATION_PLAN 已定降级项沿用**（非本单元新增）：不解密（ContentProtection 拒绝=对等源 :36）、直播 dynamic 拒绝（对等源 :34）、SegmentBase 的 sidx 索引/字节范围不解析（源即整文件直下）、单轨多段不完整（源 quirk）。

## 6. 纯函数拆分与 Hypium 用例清单（目标 +62，区间 +50~70）

纯函数面：`parseXsDuration`（DashUtil）、`buildMpdTree`/`parseDashManifestFromEvents`/`parseDashTemplate`/`parsePeriodDurations`（DashParser，事件注入式——结构/语义分离使 4 向量公式验证可本地跑）、`buildDashPlan`/`dashMimeExtension`（AdaptivePlan）、`dashQuality`/`processDashVideo`（VideoSniffAlgo）。

| 套件 | 条数 | 用例要点（★=源 quirk 钉死） |
|---|---|---|
| DashUtil.test.ets | 10 | PT0H10M54.00S→654000（源测试向量）；-PT30S→-30000；PT0S→0；P1Y=31556908000/P2M=5259478000/P3D=259200000（系数）；复合 PT4H5M6.5S；小写 pt1h；fallback "0"→0、"1.5"→5400000；"1.2.3"→throw；空串→throw |
| DashParser.test.ets | 30 | 根门 6：非 MPD 根/type=dynamic 拒/★"Dynamic" 不拒/任意层 ContentProtection/无 Period/空文档。周期 3：单周期默认时长；多周期双 start 逆算；★duration-only 中间周期混合形态（last=total-dur 源误差钉死）；双缺 throw。三寻址 7：SegmentBase→[baseUrl] 单段/Period 级标志生效/★AS 级 SegmentBase 被忽略/List init 优先 RepresentationIndex/List 零段→null/List mediaRange 忽略/Template 父 AS 级回退+Period 级不查。simple 6：默认值三元组/★time 起点奇偶（$Time$ 首值=startNumber）/ceil 数学（Sintel 888000ms→178）/★$$→字面 $/★$Bandwidth$ 原始串/$RepresentationID$。timeline 6：d 缺失 throw/★t="0" 不重置/r>0 展开（r=2→3 段）/★r=0 与 r=-1 均 1 段/startNumber 传递/init 段 $Time$=0。格式化 2：%06d→000001/%0Nx→000c（+无 dx 按偏差钉 d）。组合与门 2：video×audio 笛卡尔序/trickmode 组丢弃 |
| AdaptivePlan.test.ets（追加） | 12 | buildDashPlan：交错序 c0=video0,c1=audio0…/长轨尾段追列/全 chunk offset=0&length=-1&isInit=false/duration=max/双 .mp4→.mp4/webm→.mkv/mime 未命中→末段扩展回退/suggestedExtension===tracks[0].container/段数超 10000→null/空段表→null/非法 URL→null；copyAdaptivePlan：Dash 计划 encode→decode roundtrip（StateCodec 通路）+ Hls 旧分支回归各 1 |
| VideoSniffAlgo.test.ets（追加） | 10 | dashQuality 4：双轨完整串（双空格钉死）/video-only 尾随空格/audio-only 序（lang 前置）/bandwidth=-1 或全零 → 空段；processDashVideo 6：1&1 降级 dual/多轨 multi 全量段/单轨只取首段 quirk/双周期前缀 "1 "/ext 双 mime 规则/displayText 前缀拼接 |

注册纪律：15/16 为新套件经 List.test.ets 追加 import+调用；17/18 追加到既有套件（已注册）。门禁口径：`node scripts/run-hypium.cjs --expected-tests 0 -- <hvigor test 命令>`（scripts/HYPIUM_GATE.md：child exit 0 + 执行完成标记 + test_result.txt 全绿 + 无漏配对；**不得以 hvigor 退出码/BUILD SUCCESSFUL 判绿**）。expectedTests 传 0（本单元拍板：数量不强制），注册纪律由 List.test.ets import/call 双点 + 审查核对。

## 7. 探针设计（P7-U1 三件套）

单元 ID 采用 `P7-U1-F` / `P7-U1-P` / `P7-U1-C`（ProbeKit sanitizeToken 白名单 [A-Za-z0-9-] 合法；与未来 P7-U2/P7-U3 探针位不冲突；标记形如 `[XDM_PROBE][P7-U1-F][S1]`）。三探针共用 docs/probe/P7-U1-dash-host.cjs；手册含 **DASH 公共测试流指引**（dash.akamaized.net 的 Sintel/BBC 静态流、rdmedia.bbc.co.uk——均需双轨 static；dynamic/DRM 流用于观察拒绝路径；公网可达性人工确认一次，本地验收走 host cjs）。每步骤独立 owner + ProbeKit.isCurrent 会话守卫（ProbeAdaptiveFoundation.ets:85-115 惯例）；BEGIN/SUMMARY/END 保留；值只写观测事实。

### 7.1 P7-U1-F（foundation：纯函数 + XML 结构事实，ProbeDashFoundation.ets）

| 步骤 | 操作 | 观测点（emit 键） | 日志标记 |
|---|---|---|---|
| S1 XML 结构与树 | 真机 xml.parseXml 解析 Smooth 向量；记录事件序 | rootName/attrCount/nodeCount/maxDepth/attrCallbackOrder（实测 token↔attr 相对序，钉进 EXPECT）/selfClosingCount/ignoreNameSpaceNames=1 | [P7-U1-F][S1] |
| S2 时长表 | 逐例跑 parseXsDuration | durationCases=10 casesOk=true | [S2] |
| S3 Timeline 展开 | Smooth 向量端到端（真机解码→语义） | videoSegmentsCount=91（init+89+1）/videoFirstUrl/videoLastTime=1792810000 量级观测值/audioSegmentsCount 与 Σ(1+max(r,0)) 自洽=true/pairCount=16 | [S3] |
| S4 simple+模板 | Sintel 向量端到端 | videoSegmentsCount=179（init+178）/audioSegmentsCount=175/mediaCount=174/segmentCount=174? 双轨分别列/dollarLiteral=true（au$dio）/startNumberZero=true/%06d 样例（BBC 向量并入 S6） | [S4] |
| S5 三寻址+多周期 | 多周期向量端到端 | periodCount=2/p1Items=2(单轨 video)/p2Pairs=4/p2ListSegments=11(init+10)/p2TimelineSegments=10/tEqualsZeroQuirk=true | [S5] |
| S6 拒绝门+BBC | dynamic/encrypted/no-period/非 MPD 四反例 throw；BBC 向量 | dynamicRejected/encryptedRejected/noPeriodRejected/wrongRootRejected 均=true；bbcVideoSegmentsCount=151（init+150）/bbcPairs=15/bbcFirstNumber=000001 | [S6] |

EXPECT 期望值来源：§4/§6 公式推导（video 91/150/178 等为手工核算值）；音频计数用解析器与独立 Σ 公式双算一致性钉住，不预填手数。S1 的 XML 事件序为**实测钉板**（XML SDK facts 文档要求的最小验证项）。

### 7.2 P7-U1-P（pipeline：真 HTTP 经 adaptive 管线，ProbeDashPipeline.ets）

| 步骤 | 操作 | 观测点 |
|---|---|---|
| S1 清单→计划 | host cjs 拉 MPD（GET，P7-U1 源地址）→ parseDashManifest → buildDashPlan | planKind=Dash/chunkCount/interleaveOk=true/containerRule=mp4 或 mkv |
| S2 全量下载 | newAdaptiveState → AdaptiveRunController(freshPlan) run | resultKind=ready? 观测实际返回/partsComplete=chunkCount/generation=1/每 part 字节=host 固定段字节 |
| S3 单轨拼接 | 单 video 计划 → AdaptiveAssembler | outputBytes=Σ段字节/extension=.mp4/内容序匹配=true |
| S4 双轨 remux | 双轨计划 → AdaptiveAssembler（真 MediaProcessorNapi） | mediaStarted/mediaSettled/extension=.mp4（remux 成功）或 .mkv（降级，如实记录）/outputBytes |
| S5 恢复 | S2 中途 stop → paused；重开 store+RunController(freshPlan=null) resume | resumeKind=ready/prefixBytes 保留=true/manifestRefetch=0 |
| S6 管线拒绝 | 超预算计划/非法 URL 计划 → E4 | rejected=true/errorCode=InvalidAdaptiveRunInput 或计划 null |

### 7.3 P7-U1-C（controller：E4 状态机，ProbeDashController.ets；镜像 ProbeAdaptiveController S1-S4 形态）

| 步骤 | 操作 | 观测点 |
|---|---|---|
| S1 运行/租约/装配/恢复 | Dash 计划跑通 E4→lease→Assembler→回填 | readyLeaseAttach=true/commitGeneration 递增/drain 干净 |
| S2 真实暂停与已提交前缀恢复 | 中途 stop→重开恢复 | pausedKind/prefixBytes 保真 |
| S3 读者准入前暂停 | ready 前 cancel | cancelledClean=true |
| S4 读者准入后传递暂停 | attachReader 后 onStop 传递 | readerStopNotified=true |
| S5 目录属主 | 同目录第二 controller | ownerRejected=AdaptiveOwnerBusy |

### 7.4 host cjs（P7-U1-dash-host.cjs）

路由（固定自产字节，无文件系统访问）：`/mpd/smooth|bbc|sintel|multiperiod|dynamic|encrypted|noperiod`（Content-Type `application/dash+xml`）、`/seg/:repr/:name`（init/media 固定字节序列，`Content-Length` 精确，支持被 Range 或 whole-GET 消费）。反例 MPD：type="dynamic"、含 ContentProtection、无 Period。用法同 P6-U4：`node docs/probe/P7-U1-dash-host.cjs --host 0.0.0.0 --port 8795`，设备填 PC 局域网地址。

## 8. 验收要点与门禁

1. **编译**：hvigor 全量零 error 零新 warning（ArkTS 严格子集编译期强制；对照 arkts-grammar-standards 自查：无 any/无对象字面量裸类型/无 for...in/正则用 new RegExp/无解构）。
2. **单测**：run-hypium.cjs 口径全绿（§6；--expected-tests 0）；新增用例全部注册 List.test.ets。
3. **逐公式对照**：§4 表逐条对应 DashParser 用例（四向量 + 时长 + 三寻址 + 模板 + 多周期）；MpdParser.cs 431 行无未映射分支（死代码按 §5-3 锚登记）。
4. **端到端**：P7-U1-P S2-S4——DASH 测试流经 adaptive 管线下载、双轨 remux 产物可播（探针日志 + 设备侧播放确认；手册指引公共测试流）。
5. **探针**：三手册 + 三 EXPECT（pending-device-run），`xdm-probe-verify` 逐步骤判定。
6. **回归红线**：Hls 分支既有 32 条 AdaptivePlan 用例 + StateCodec/RunController/Assembler 行为零变化；/sync videoList 契约冻结零改动（addDashVideo 写入不触碰 SyncFields 投影）。
