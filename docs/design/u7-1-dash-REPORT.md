# U7.1 DashDownloader 迁移报告（Phase 7）

- 单元：U7.1 DashDownloader（UNIT_CATALOG Phase 7 第 1 单元）
- 报告日期：2026-10-11
- 目标工程：D:/git/HarmonyPC/XdmHarmony（HarmonyOS PC，API 24 / SDK 6.1.1(24)，compatibleSdkVersion 6.1.0(23)，bundle com.example.xdmharmony，ArkTS 严格子集）
- 对照源码：D:/git/HarmonyPC/resourses/xdm（XDM 2023，C#/.NET，GPL-2.0，只读参考；本报告环节对其仅执行读取）
- 设计书：docs/design/u7-1-dash-DESIGN.md（同目录）
- 证据约定：标注「材料」的结论引自本单元工作流的门禁与审查记录；标注「报告员实读」的是本报告环节在磁盘核对到的事实。报告员未重跑编译与测试门禁，详见⑤。

**当前状态：编译门禁、单测真值门禁、codelinter 辅助检查均通过；对照审查 approved 序列第 2 轮过；独立复核 acceptable=true（5 项发现：2 medium 未处置、3 low 已处置）；探针 P7-U1 已生成，待人工运行回贴日志。无门禁未通过项。**

## ①单元范围与验收要点

范围（单元指令四条）：

1. MpdParser 全量翻译：SegmentBase/SegmentList/SegmentTemplate 三寻址、SegmentTimeline 状态机展开、$Number$/$Time$/$RepresentationID$/$Bandwidth$ 模板变量（含 %0Nd 补零），拒绝 dynamic 与 ContentProtection。
2. 音视频 Representation 组合为 video×audio 笛卡尔组合，经 VideoSniffAlgo.processDashVideo 写入 CapturedVideoTracker dash 表（U6.2 已落的 addDashVideo 入口）。
3. 下载执行复用 U6.4 adaptive 冻结管线：AdaptivePlan.ets 新增 buildDashPlan（镜像 buildHlsPlan 交错循环），DASH 计划经 AdaptiveRunController/AdaptiveAssembler 直驱。
4. 探针 P7-U1 三件套（foundation/pipeline/controller）加手册与预期表。

范围边界（设计书 §0 裁定）：

- core/adaptive/DashDownloader.ets 不在本单元创建：业务下载外壳（Manager 工厂与 UI 接线）与 HlsDownloader 同属 u6-4 外层集成（O2/O3/O7）；本单元以 buildDashPlan 加管线直驱探针交付「经 adaptive 管线下载可播」验收。
- VideoCapture.ets、module.json5、main_pages.json 零改动。报告员实读复核：VideoCapture.ets:37 GROUP_KINDS 已含 'dash'；module.json5:9 deviceTypes 含 2in1、:16 已有 ohos.permission.INTERNET；main_pages.json 仅 pages/Index 与 probe/ProbeIndex 两项，探针经 ProbeIndex 注册，不新增路由页。
- string.json 三 locale 各新增 3 个探针标题键（probe_p7u1_foundation_title / probe_p7u1_pipeline_title / probe_p7u1_controller_title），grep 计数 base/zh_CN/en_US 各 3。
- POST 清单（RequestMethod=POST 加 base64 body）延后接线，本单元捕获 GET-only（有意差异 8）。

交付文件：设计书 §2 清单 1 至 26 共 26 个交付文件加设计书本身（7 个 core 文件、4 个探针单元文件、3 份 string.json、5 个测试文件、1 个 host cjs、3 份分册手册、3 份分册 EXPECT、1 份合并手册与合并 EXPECT），报告员逐一核对全部存在。

验收要点（设计书 §8）：编译过（零 error 零新 warning）；MpdParser 逐公式对照（四个 MPD 向量进用例表）；DASH 测试流经 adaptive 管线下载可播（探针 P7-U1-P S2 至 S4 验）；单测全绿且新增全部注册（run-hypium 口径）。

## ②研究结论摘要（关键源码行为与 ArkTS 对应表）

| # | 源码依据 | 关键源码行为 | ArkTS 落点 | 风险 |
|---|---|---|---|---|
| 1 | MediaParser/Dash/MpdParser.cs:247-301 | Timeline 显式寻址逐 S 展开：d 必填，t/r 缺省 -1；t>0 才重置 time（t="0" 不重置的 quirk）；每个 S 发 1 段后 number 加一、time 加 d；r>0 再发 r 段；r=0 与 r=-1 均只发 1 段（源未实现规范「重复至周期末」语义） | DashParser.ets timeline 分支（:434-487）逐字段解析，严格不等号原样保留；number/time 用 number 类型并加安全整数门（:467-469） | 高 |
| 2 | MpdParser.cs:214-242 | simple 寻址：timescale/duration/startNumber 缺省 1；segmentCount=ceil((periodDuration/1000)/(duration/timescale))；time 初值取 startNumber 而非 0（quirk）；initialization 先展开；$$ 转义恢复字面 $ | DashParser.ets simple 分支（:385-431）直译；除零与负值按 IEEE/(int)/List 负容量三段语义形态表钉死（NaN、±∞、负 ratio throw，ratio 为 0 得 0 段，:392-402） | 高 |
| 3 | MediaParser/Dash/DashUtil.cs:8-40 | xs:duration 两段 T 部件串联正则（组号 H=10/M=12/S=14，IgnoreCase）；年 31556908 秒、月 2629739、日 86400；总秒乘 1000 后截断；不匹配时 fallback 按小时数解释（如缺省串 "0" 得 0ms） | DashUtil.ets parseXsDuration（:53）命名组直译；fallback parseFloat 得 NaN 时 throw（对齐 C# Double.Parse 异常即清单丢弃） | 高 |
| 4 | MpdParser.cs:32-51 | MPD 根门四条：根名非 "MPD"、type 属性精确等于 "dynamic"（大小写敏感）、任意层存在 ContentProtection、无 child::Period，均整清单丢弃；mediaPresentationDuration 缺省 "0" | buildMpdTree（DashParser.ets:98）加根门；DashXmlFeed.ets 经 @ohos.xml parseXml（ignoreNameSpace=true 对齐 Namespaces=false），DOCDECL/ENTITY_REFERENCE 事件显式拒绝（:96-99） | 中 |
| 5 | MpdParser.cs:18-19, 308-359 | 模板正则五类变量；%0Nd 十进制补零（12 得 0012）、%0Nx 小写十六进制（12 得 000c）；$Bandwidth$ 用原始属性串未转数值；无 dx 形态源输出字面量（源缺陷） | parseDashTemplate（DashParser.ets:259）预扫描 Match 列表后顺序替换；无 dx 按 d 处理（有意差异 1）；bandwidth 原始串旁路传递 | 中 |
| 6 | MpdParser.cs:361-397 | 多周期时长反推按逆文档序迭代：start 与 duration 均缺 throw；带 duration 周期记 last=total-dur（该式仅对最后周期正确，中间周期混合形态源误差 1:1 保留） | parsePeriodDurations（DashParser.ets:582）栈迭代加 reverse；PT0S 死分支不复刻（设计书 §5-3 注释锚惯例） | 中 |
| 7 | MpdParser.cs:170-207, 308-359 与 Util/UrlResolver.cs:10-13 | 三寻址判定序固定：SegmentBase（repr 级或 Period 级标志）优先、SegmentList 次之、SegmentTemplate 回退父 AdaptationSet 级（Period 级不查）；BaseURL 四级链各级局部变量互不污染；index 寻址单段整文件、忽略 sidx 与字节范围 | DashParser.ets 同序 if-else；URL 解析复用 HlsUrlResolver 同语义（绝对 http(s) 直取、相对拼接）；parseDashManifestFromEvents 导出于 :624 | 中 |
| 8 | VideoUrlHelper.cs:197-331 | ProcessDashVideo 按周期序号加前缀（第 0 周期为空串）；双轨两侧各 1 段时降级 dual 条目，否则 multi 条目（duration 取两侧最大）；单轨 AddSingleItem 只取 Segments[0]（多段单轨产物不完整的源 quirk）；扩展名按双 mime 是否均含 mp4 判；displayText 逐字符拼接含双空格/尾随空格 | VideoSniffAlgo.ets dashQuality（:984）与 processDashVideo 纯函数、DashCaptureItem 联合类型（:976）；BridgeRoutes.ets:444-448 dash 锚分支，processDashCapture（:524）写入方 :551 addDashVideo、:557 addDualSourceVideo、:562 addSingleSourceVideo | 中 |
| 9 | MpdParser.cs:91-163 与 Representation.cs:6-28 | 属性继承 repr 优先、父 AS 兜底；mime 小写后非 audio/video 前缀丢弃；trickmode（EssentialProperty 或 SupplementalProperty 首个命中 guideline URI）整组返回空；video 外层乘 audio 内层笛卡尔，单侧单列 | DashModel.ets DashRepresentation 八字段 class 镜像（segments/width/height/codec/bandwidth/duration/mimeType/language，缺省 -1 或空串）；组合与门在 DashParser.ets（containsTrickMode :491） | 低 |
| 10 | MultiSourceDASHDownloader.cs:14-313 与 FileExtensionHelper.cs、MimeTypes.cs | Type="Mpd-Dash"、FileSize 初始 -1；chunk Offset=0/Size=-1；CreateChunks2 交错（min(v,a) 对交替加双尾段，video=stream0/audio=stream1）；容器链 mime 表优先、末段扩展猜测回退（.ts 保持、.m4*/mp4* 得 .mp4、其余 .mkv）；RestoreState 失败重建分块 | AdaptivePlan.ets buildDashPlan（:471）加 dashMimeExtension（:57）、copyAdaptivePlan kind='Dash' 分支（:275/:322）；持久化由 AdaptiveStateStore/StateCodec generation-CAS 承担；装配复用 AdaptiveAssembler（双轨 remux 走 U0.4 MediaProcessorNapi，.mp4 失败降 .mkv） | 中 |

单测对应：设计书 §6 计划新增 62 条（区间 50 至 70），实际注册 71 条：DashUtil 12、DashParser 36、AdaptivePlan 增补 13、VideoSniffAlgo 增补 10（List.test.ets:49-59 头注对账，569 基线加 71 得 640，与门禁计数一致）。四个 MPD 向量（Smooth Streaming r=88 时间线、BBC $Number%06d$、Sintel $$ 转义加 startNumber=0、多周期 SegmentBase/SegmentList 加 ST r=9）经 DashParser 事件注入验证；DashXmlFeed（@kit 适配层）按设计不进 Hypium，真机 XML 行为由探针 P7-U1-F 补验。两套新套件在 List.test.ets:91-92（import）与 :124-125（调用）双点注册。

## ③设计决策与有意差异

架构基线遵循 MIGRATION_PLAN §6 技术决策中与本单元相关者：决策 2（线程模型：adaptive 管线主线程异步状态机，TaskPool 只属 Progressive 引擎，本单元不引入 TaskPool）；决策 4 与 10（进度持久化 JSON 化，下载状态由 AdaptiveStateStore/AdaptiveStateCodec generation-CAS 承担，替代源 chunks.db 二进制恢复）；决策 6 与 7（HLS/DASH 拒绝加密与 dynamic，对等原版）；决策 8（remux 合并失败降级 .mkv，由 U6.4 装配面既有逻辑承担）；决策 9（HTTP 客户端参考模型）。core/adaptive/ 管线 14 模块冻结复用，零架构改动（设计书头部声明）。

有意差异 13 项（编号与设计书 §5 对齐）：

| # | 差异 | 依据 |
|---|---|---|
| 1 | $Number%04$（无 dx 后缀）按 d 十进制补零处理；源 .NET ToString("4") 输出字面量的缺陷不复刻 | openQuestion 1；ISO 23009-1 合法清单必带 d/x，不触发该路径 |
| 2 | 负数模板值补零统一 sign 加幅值（padStart / toString(16)）；不迁移 .NET "d"/"x" 负数二补全宽格式 | 合法 MPD 时间与编号非负，超规范输入的显式定义 |
| 3 | 死代码不复刻：parsePeriodDurations 的 PT0S 缺省分支（MpdParser.cs:387-390）、FormatDigit 的 dx="D" 死路径（:353）、MultiSourceDASHDownloader 大段注释块 | 项目「不建死代码、注释锚登记」惯例 |
| 4 | 新增全套有界预算（清单 2Mi 字符、树 2 万节点、深度 64、周期 256、组合 2048、每轨 10000 段、周期累计 URL 8Mi 字符）与严格十进制数值解析，超限 throw，等效源异常即整清单丢弃 | 源无界且依赖 .NET 异常路径；研究结论要求设界（设计书 §3.3） |
| 5 | 单轨 DASH 保持源 AddSingleItem 只下 Segments[0] 的 quirk（多段单轨产物不完整不可播） | openQuestion 2 按 1:1 保留；验收流选双轨清单规避 |
| 6 | 捕获侧 manifest 拉取为 fire-and-forget 异步（await 前深拷贝 msg 快照）；源为同步阻塞 HTTP，/media 响应不等待解析完成 | ArkTS 主线程不可阻塞（设计书 §4.11） |
| 7 | 源 DownloadManifest 每次新建 HttpClient 可并行；目标共用模块级 ManifestClient（busy 时 log 后跳过），串行化收敛 | U6.4 O1「唯一清单请求面」方向 |
| 8 | POST 清单（RequestMethod=POST 加 base64 body）延后接线，本单元捕获 GET-only | openQuestion 3；对齐 U6.4 O1/O3 既定延后 |
| 9 | chunks.db 二进制恢复改为 AdaptiveStateStore/AdaptiveStateCodec JSON generation-CAS；「恢复失败重建分块」语义由装载失败后 newAdaptiveState 承担 | MIGRATION_PLAN 决策 4/10 |
| 10 | core/adaptive/DashDownloader.ets 不落盘；业务下载外壳随 u6-4 外层集成（O7）统一落 HlsDownloader/DashDownloader | u6-4 设计书「后续接线契约」；避免两套并发业务编排 |
| 11 | XML 适配层显式拒绝 DOCDECL/ENTITY_REFERENCE 事件 | 实体展开防护；源 XmlTextReader Namespaces=false 默认亦不展开 DTD |
| 12 | XML 模块名勘误：实际为 @ohos.xml（MIGRATION_PLAN 决策 7 所写 @ohos.util.xml 有误）；采用 parseXml（API14 起）Pull 路径，SAX（API24 起）因工程 compatible 23 不采用 | u7-1-dash-xml-sdk-facts.md 实测 d.ts（材料） |
| 13 | BBC 向量源测试的 playlistUrl 尾随空格不迁移，目标 fixture 用修剪后 URL | resolveHlsUrl 有意拒绝非 trim 输入（HlsUrlResolver.ets:7） |

补充澄清两项（ask 材料登记，未占设计书 §5 编号）：simple 寻址 segmentCount 按 IEEE/(int)/List 负容量形态表实现，对研究结论「duration 小于等于 0 得 0 段」做了修正，ratio 为 0 的形态得 0 段（init-only 或 null），NaN、±∞、负值 throw（设计书 §4.6）；配置文件 VideoCapture.ets/module.json5/main_pages.json 零改动已列为范围裁定（①）。

## ④审查问题处置表

对照审查记录（材料原话）：「共 1 轮，approved 序列：第2轮过；已修复问题编号 []」。结合实现摘要：第 1 轮评审列出 19 处编译错误（评审编号 7 至 14 在 ProbeDashFoundation，15 至 18 在 ProbeDashPipeline，第 19 条在双方输出中均被截断未单独定位），内容为 DASH_EVENT_START 导入源写错（误从 DashModel 导入，实际在 DashParser）、缺 DashPair 与 DownloadRequestContext 导入、fileIo.hash 误用（@kit.CoreFileKit 的 hash 为独立导出，应为 hash.hash）；六处 arkts-no-any-unknown 为导入错误的推断级联，随修复消零。修复后全量重编译通过，第 2 轮通过。

独立复核换人产出 5 项发现（F1 至 F5）。材料中各项 status 字段均为 unconfirmed（复核结论尚未经处置轮回签）；处置标注以材料【已处置】/【未处置】为准。报告员对每项做了磁盘实读核对（2026-10-11）：

| 编号 | 严重度 | 位置 | 问题摘要 | 材料处置 | 报告员实读核对 |
|---|---|---|---|---|---|
| F1 | medium | DashXmlFeed.ets:74-83（flushOpen 调用点）、:9-12（文件头注释） | onToken 对任何到达 token 无条件冲刷未决 start 事件：若 SDK 回调序为属性先于 START_TAG，属性先建的无名暂存 start（name=''）被冲入事件流，真实元素 start 丢失全部属性，buildMpdTree 对空名 start throw（DashParser.ets:107），DASH 捕获整链失效；头注声称「本适配器状态机对两种先后序均成立」，与代码行为不一致 | 未处置 | 属实。onToken 首行无条件 flushOpen（DashXmlFeed.ets:77），onAttribute 暂存无名事件（:60-65），全文件（122 行）无补名合并路径；头注 :9-12 仍声明两种先后序均成立。复核修法：START_TAG 到达且暂存事件名为空时补名合并（保留已并入属性），或把头注改为仅支持 token 先序、属性先序由探针 S1 钉板暴露 |
| F2 | medium | DashParser.ets:470-482（timeline 分支 r 内层循环） | 段数预算检查 `segments.length > DASH_MAX_SEGMENTS` 只在外层每个 S 处理完后执行，单个 <S r="巨大"> 的内层循环每次 push 后不检查，DASH_MAX_SEGMENTS 门失效，仅靠 DashUrlBudget（8Mi URL 字符）兜底；最坏约 84 万次迭代（8388608 除以最短合法 URL 约 10 字符），每次迭代含 2 次 new RegExp（resolveReference 内），主线程秒级阻塞、瞬时内存数十 MB | 未处置 | 属实。检查在 :482 外层循环尾，内层 :471-480 push 后无段数检查；对照 simple 分支 :400 有前置门。复核修法：段数检查移入 r>0 内层每次 push 后，最坏迭代数封顶 10000 |
| F3 | low | DashParser.ets:131-137、:168-174 | 混合内容节点（直接文本与子元素并存，如 `<BaseURL>t1<x>t2</x>t3</BaseURL>`）innerText 得 't1t3t2'，与 C# XmlNode.InnerText 文档序 't1t2t3' 不同（MpdParser.cs:47 消费 BaseURL）；触发面窄，BaseURL 为纯文本内容模型，混合内容非法 | 已处置（接受现状） | 行为属实（text 事件挂接 :135，innerText :168-174）；复核建议中的 innerText 注释锚未落地：:167 注释仍声明「按文档序串接」，未注明混合内容偏差。列入⑦ R3 |
| F4 | low | VideoSniffAlgo.ets:990-991（dashQuality 语言段门） | C# GetAudioLanguage（VideoUrlHelper.cs:304-307）条件为 Language 非空串且非 "und"，lang="" 形态产生一个空格段；实现追加 language.length>0 门将其吞掉，quality 串少一个空格。DashModel.ets:11「映射层判空，无观测差异」的声明对 lang="" 形态不成立 | 已处置（注释锚登记） | 核对一致：:990-991 保留 length 门；:980 注释已登记 lang 为 "und" 或空串时语言段为空、双空格 quirk 的成因。差异限于 lang="" 形态（缺省形态无差异），影响为 quality 串少一个空格 |
| F5 | low | ProbeDashPipeline.ets:550（S5 manifestRefetch） | manifestRefetch=0 为硬编码 code-path 断言而非运行时观测值（合并 EXPECT 已自注 code-path fact）；若恢复路径（freshPlan=null）错误发起清单请求，该键恒为 0 不暴露。resumedKind 与 prefixPreserved 仍覆盖恢复正确性主体 | 已处置（保持现状） | 核对一致：:550 赋值 0 并带注释「恢复路径 freshPlan=null，不发生清单请求」。复核建议的可选加强（ManifestClient 请求计数回调）未做，属可选项 |

## ⑤验证情况

| 门禁 | 命令与口径 | 结论 | 证据来源 |
|---|---|---|---|
| hvigor 全量编译 | devecocli build --modules entry（返修复现用 assembleHap，module=entry@default / product=default / buildMode=debug） | 通过。修复前 19 错（含 6 处 arkts-no-any-unknown 级联），修复后 BUILD SUCCESSFUL；touch 本单元 10 个文件重编译 0 新 warning，92 条 warning 为未触碰文件既有基线 | 材料门禁执行记录与实现摘要。报告员未在本环节复跑编译 |
| 单测真值门禁 | node scripts/run-hypium.cjs --expected-tests 640；判定以 entry/.test/default/intermediates/test/coverage_data/test_result.txt 结果文件、执行完成标记与防漏注册为准，不以 hvigor 退出码或 BUILD SUCCESSFUL 判绿（scripts/HYPIUM_GATE.md） | 通过，640/640，Failure 0、Error 0、Ignore 0 | 门禁执行记录（材料）；报告员实读 test_result.txt（2026-10-11 01:59 生成），尾行「Tests run: 640, Failure: 0, Error: 0, Pass: 640, Ignore: 0」；与 List.test.ets 头注 569 加 71 得 640 对账一致；run-hypium.cjs:20-56 校验完成标记与 expected-tests 计数 |
| codelinter 辅助 | codelinter 扫描（提示性；不含 ArkTS 语法规则） | exit 0；Summary: Issues 10（Errors 0 / Warnings 8 / Suggestions 2），Files checked 7；可见条目为 Index.ets:1771 等既有文件的 @performance/hp-arkui-set-cache-count-for-lazyforeach-grid 建议类输出（材料输出截断，逐条归属以门禁原始输出为准），非本单元新增 | 材料门禁执行记录。报告员未复跑 |
| 对照审查 | 保真度对照（评审轮次） | approved 序列第 2 轮过；已修复问题编号 []（材料原话） | 材料审查记录 |
| 独立复核 | 换人挑错 | acceptable=true；5 项发现（2 medium、3 low），weakestSpot 指 DashXmlFeed 回调序适配层（DASH 链唯一接触未钉板 SDK 行为的环节），其次为 timeline 大 r 主线程阻塞面 | 材料复核记录，发现明细见④ |

ArkTS 合规说明：codelinter 不含 ArkTS 语法规则（MIGRATION_PLAN §8 验证矩阵同此声明），ArkTS 严格子集由 hvigor 编译期强制。本单元 6 处 arkts-no-any-unknown 编译期报错随导入修复消零，全量编译通过即为本单元语法合规证据；文件头登记的红线（无 any、无解构、无 for...in、正则用 new RegExp、对象字面量具显式类型）见 DashModel.ets:18-19 与 DashXmlFeed.ets:19-20。

报告员实读核对补充项：交付文件 27 项存在性（①）；探针三件套在 ProbeIndex.ets:33-35（import）、:64-66（注册表）、:166-171（分支）三点注册；两新测试套件在 List.test.ets 双点注册；module.json5/VideoCapture.ets/main_pages.json 零改动声明；F1 至 F5 代码现状（④表末列）。

## ⑥运行时验证待办

- 状态：探针 P7-U1 三件套全部待人工运行，四份 EXPECT（合并版与三份分册）状态均为 pending-device-run（材料；分册 EXPECT 的 pending-device-run 为设计内状态）。
- 材料位置：单元级合并手册 docs/probe/PROBE-u7-1-dash.md，含 17 个步骤行（F-S1 至 F-S6、P-S1 至 P-S6、C-S1 至 C-S5）；合并预期表 docs/probe/EXPECT-u7-1-dash.json，26 条预期项为 17 个步骤行加每探针 BEGIN/SUMMARY/END 示例保留行。单元指令汇总行写的「26 步」即此口径，实为 17 个验证步骤，以手册与 EXPECT 实文为准。分册：PROBE-u7-1-dash-foundation/pipeline/controller.md 与同名 EXPECT JSON（逐单元判据细版）。
- 运行指引在合并手册第 0-1 节：真机需 devecocli auth login 与 devecocli signature generate（本机 2026-10-03 会话已沉淀，跳过条件见手册）；模拟器 devecocli emulator start「Pura 90」；P 管线与 C 控制器依赖主机测试源 node docs/probe/P7-U1-dash-host.cjs --host 0.0.0.0 --port 8795（F 基础探针为零网络行内注入，不依赖）；hdc 用全路径 "D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"。
- 运行后回贴 [XDM_PROBE] 日志，用 xdm-probe-verify 工作流逐步骤判定并分流返修。
- 第一优先验证项：P7-U1-F S1 attrCallbackOrder（xml token 回调与属性回调的相对序钉板）。该相对序官方文档无保证，直接决定 F1 是否在真机显形（④weakestSpot 同此判断）。
- 端到端验收对应 P7-U1-P S2 至 S4：全量下载、单轨拼接、双轨 remux 产物可播（设计书 §8-4）。手册另附公网 DASH 测试流指引（dash.akamaized.net 的 Sintel/BBC 静态流，需双轨 static；dynamic 与 DRM 流用于观察拒绝路径），公网可达性需人工确认一次，本地验收走 host cjs。

## ⑦遗留问题与风险

- R1（medium，F1 未处置）：DashXmlFeed 回调序适配层。探针 S1 若实测属性先序，DASH 捕获整链失效（空名 start 事件使 buildMpdTree 在 DashParser.ets:107 throw）。属探针首跑即知的小修（补名合并或改头注），建议判定后立即处置。
- R2（medium，F2 未处置）：Timeline 单个大 r 的段数门缺口。最坏约 84 万次迭代、主线程秒级阻塞，不崩但卡顿可感；恶意 MPD 经嗅探路径即可触发，单测事件注入与大 r 形态未覆盖（独立复核同此判断）。修复为一行级移动检查位置。
- R3（low，F3 残留）：innerText 混合内容序偏差未按建议登记注释锚，DashParser.ets:167 注释声明与实现在混合内容形态有出入。触发面为非法 XML 内容，实际风险很低。
- R4（low，F5）：manifestRefetch 为 code-path 断言，恢复路径若错误发起清单请求不由该键暴露，由 resumedKind 与 prefixPreserved 覆盖主体。
- R5（登记性差异，非缺陷）：单轨 DASH 只下 Segments[0]（源 quirk 1:1）；POST 清单延后（GET-only）；$Number%04$ 按 d 处理；负数模板补零为 sign 加幅值；全套预算设界为源所无的新增行为（超限 throw 等效源异常丢弃）。均已编号登记于③表。
- R6（流程）：端到端「下载可播」验收尚未执行，取决于⑥探针运行；编译与单测门禁不能替代该验收。
- R7（基线）：codelinter 10 条既有建议与编译期 92 条 warning 为未触碰文件既有基线，非本单元引入；是否清理留给 U7.3 收尾评估。

## ⑧对下个单元的建议

下个单元为 U7.2 MediaProcessorNapi（UNIT_CATALOG Phase 7 序列 U7.1、U7.2、U7.3）。

1. 先跑 P7-U1 探针（合并手册 17 个步骤），S1 attrCallbackOrder 结果决定 F1 处置方向：实测属性先序则修 DashXmlFeed 补名合并（十行内改动），实测 token 先序则把头注改为仅支持 token 先序。两者都建议在下一次触碰 core/adaptive 的运行中落掉。
2. F2 的一行级加固（段数检查移入 r 内层循环）建议与 F1 同批落地，并补一条 timeline 大 r 预算单测（DashParser 事件注入即可，不必等真机）。
3. U7.2 落 MediaProcessorNapi 时保持 U0.4 既有封装面签名：AdaptiveAssembler.ets 已按其接线，U6.4/U7.1 管线对 remux 面零改动是回归红线（设计书 §8-6）；本单元双轨 remux 产物扩展名与降级行为已在探针 S4 预期中钉板，U7.2 改动封装面时同步核对。
4. POST 清单接线（openQuestion 3）与单轨整轨进管线（openQuestion 2）属保真度拍板项，建议在 U7.3 交付文档的降级与差异清单中统一收口，供课程验收对表。
5. 单测口径沿用 scripts/HYPIUM_GATE.md：--expected-tests 随用例总数更新（当前基线 640），判定只认 test_result.txt 结果文件加执行完成标记，不以 hvigor 退出码或 BUILD SUCCESSFUL 判绿。

## ⑨git 说明

本单元代码未做 git 提交，待人工验收后由人提交并按 Phase 打 tag。探针 P7-U1 的运行判定结果（xdm-probe-verify 核对）为人工验收输入之一。
