# U0.2 HTTP 能力探针 · 单元迁移报告

> 单元：U0.2（Phase 0 第 2 项，探针单元 ID `P0-U2`）｜ 报告日期：2026-09-28 ｜ 报告角色：迁移报告员（xdm-migrate 工作流）
> 材料来源：单元指令；`docs/MIGRATION_PLAN.md`；`docs/UNIT_CATALOG.md`；`docs/PROBE_SPEC.md`；设计书 `docs/design/u0-2-http-capability-probe-DESIGN.md`；研究结论（DotNetHttpClient 参考模型 + 本机 SDK 6.1.1(24) d.ts 核实）；实现摘要（11 文件）；对照审查全史（第 1 轮 5 项未通过、第 2 轮 4 项通过）；独立复核（acceptable=true，8 项发现）；门禁结论（主流程脚本执行）。标注"本会话"者为报告员本次亲自执行/核实的证据。
> **总判定**：hvigor 编译门禁**通过**（主流程门禁轮最终状态：通过；本会话复跑 exit 0，且 touch 强制重编译后 CompileArkTS 真实执行仍 BUILD SUCCESSFUL 零 error）；对照审查第 2 轮 approved、独立复核 acceptable，共 17 项发现，**无阻断项**：1 项已修复（R1-F1，唯一代码修复）、16 项未处置（运行时风险 1、文档/注记 13、低概率防御 2，详见④⑦）；**栈选型结论与运行时验收 OPEN**——探针尚未运行、日志未回贴，"http 还是 rcp"结论依赖真机/模拟器运行证据（设计书 §0-3 预登记五分支判定规则，xdm-probe-verify 判定后执行回写，见⑥）。

---

## ① 单元范围与验收要点

### 1.1 范围（11 个文件：4 改 7 新，全部本会话通读核实）

| # | 文件 | 新/改 | 职责 | 关键落点（本会话行号核实） |
|---|---|---|---|---|
| 1 | `entry/src/main/ets/probe/core/ProbeKit.ets` | 改 | 会话代际守卫基建 + emit/end 空观测守卫 + lastLine 死代码清理（U0.1 遗留 IR-F5/F4/F2 搭车闭环） | `isCurrent(runId)` `:150-152`（= `started && runId===runId`）；emit 空 kvs 补 `kvs=0` `:99-100`；end 零 summaries 补偿 `:122`；`lastLine` 零代码残留（grep 仅 `:11` 注释提及删除事实）；begin/emit/end 其余契约一行未动 |
| 2 | `entry/src/main/ets/probe/core/ProbePage.ets` | 改 | startSession/runSingle 五守卫点改写；IR-F1 修复 `createPlainTextData`→`createData` | startSession 守卫点①~④ `:77-81/:86-90/:92-97/:109-113`；runSingle 同构 `:121-172`（守卫点⑤）；`copyLog` 用 `pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, …)` `:175` |
| 3 | `entry/src/main/ets/probe/units/ProbeHttpLogic.ets` | 新 | 纯函数与可序列化类型模块（零 @kit import，本地单测可 import） | 四常量 `:11-20`（BIG_BIN_BYTES=4194304 / PROBE_TIMEOUT_MS=3000 / UNREACHABLE_URL=192.0.2.1 / ECHO_COOKIE）；四 interface `:23-49`；五纯函数 `:53-151`（headerOf/parseContentRange/splitRangeWindows/parseEchoBody/isTimeoutCode） |
| 4 | `entry/src/main/ets/probe/units/ProbeHttp.ets` | 新 | P0-U2 探针组件：S1~S6 runner + `@Concurrent fetchSegment` + 响应头 detail 文件落盘 | autoStart=false + TextInput 测试源行 `:489-512`；S1 流式落盘 `:136-230`（endGate 双等 `:153-158/:187-191`，finally off×3+closeSync+destroy `:220-229`）；S2 Range `:234-277`；S3 identity `:281-319`；S4 TaskPool `:323-380`；S5 重定向+Cookie `:385-426`；S6 超时 `:431-469`；runner 内 await 后/emit 前 isCurrent 复检贯穿 |
| 5 | `entry/src/main/ets/probe/ProbeIndex.ets` | 改 | PROBE_UNITS 注册表追加 P0-U2；详情分支嵌套化 | `PROBE_UNITS :16-19`（P0-U2 在 `:18`）；`else if (selectedUnitId==='P0-U2') { ProbeHttp() }` `:86-88` |
| 6 | `entry/src/main/resources/base/element/string.json` | 改 | 追加 `probe_http_title`、`probe_http_source_hint` 两键 | 现 18 键（本会话 JSON.parse 通过），两键在 `:68-75` |
| 7 | `entry/src/test/ProbeHttpLogic.test.ets` | 新 | 纯函数 Hypium 本地用例（16 用例，覆盖设计书 §7-[A]-3 清单） | 导入 `:20` = `'../main/ets/probe/units/ProbeHttpLogic'`（R1-F1 修复后） |
| 8 | `entry/src/test/List.test.ets` | 新 | 本地单测 testsuite 入口 | `:5-9` 注册 probeHttpLogicTest |
| 9 | `docs/probe/P0-U2-echo-server.js` | 新 | 主机侧测试源（Node≥14 零依赖单文件）：big.bin(Range)/echo/redirect/final 四路由，绑 0.0.0.0 | 路由实现 `:69-125`；`BIG_BIN_BYTES=4194304` `:22`（与 ProbeHttpLogic/EXPECT 三处同值锚）；302 绝对 Location `:110-117` |
| 10 | `docs/probe/PROBE-u0-2-http-capability-probe.md` | 新 | 探针运行手册：可替换测试源 URL、echo/http-server 双起源指引、九行预期序列、2300007 重跑指引、守卫冒烟 | echo 起源 `§1 :22-33`、备选源 `:35-40`、抓取与 S1 交叉核对 `§3 :58-72`、预期表 `§4 :74-95`、环境分支 `§5 :97-106`、守卫冒烟 `§6 :108-113` |
| 11 | `docs/probe/EXPECT-u0-2-http-capability-probe.json` | 新 | 机器可读预期表（BEGIN+S1~S6+SUMMARY+END 共 9 条目） | 本会话 `node` 解析：unitId=P0-U2、entries=9、order=BEGIN,S1,S2,S3,S4,S5,S6,SUMMARY,END |

### 1.2 明确不做（设计书 §1"显式不动"+ §4，本会话核实均成立）

- `module.json5` 不改：INTERNET 权限与 deviceTypes 2in1 已由 U0.1 落地（本会话 grep：`module.json5:9` "2in1"、`:16` ohos.permission.INTERNET 在位）；本单元无新增能力，无新增权限；
- `main_pages.json` 不动：探针子页沿用 ProbeIndex 页内条件渲染（ProbeIndex.ets:84-88），不占路由；
- `docs/PROBE_SPEC.md` / `MIGRATION_PLAN.md` / `RISK_ASSESSMENT.md` 三份根文档后置改写（§0-1/§0-3）：回写由报告员在 xdm-probe-verify 判定后按设计书 §8 五分支模板执行，不属本单元 files；
- `pages/Index.ets` 不改、不 import probe/（本会话 `grep -n "import" pages/Index.ets` **0 行命中**）；
- 不复刻原版六键默认头全集、TLS 全放行/MaxConnectionsPerServer/AutomaticDecompression 等降级项（见③）。

### 1.3 验收要点（UNIT_CATALOG.md:28 U0.2 行 + 单元指令）

| 验收点 | 状态 |
|---|---|
| hvigor 编译通过（零 error、零新 warning） | ✅ 主流程门禁通过 + 本会话复跑 exit 0（⑤.1；提示级 WARN 1 条登记于⑦#6） |
| PROBE 手册（含可替换测试源 URL 与 npx http-server 起源指引）与 EXPECT 预期表生成 | ✅ 10/11 号文件（⑤.3 解析通过） |
| 六步骤标记可机械判定（每步骤恰一行，FORMAT 正则 + EXPECT 判定式） | ✅ 设计静态可验（EXPECT 谓词与设计书 §6/§8 分支一一对应）；运行时实证待⑥ |
| 六项能力逐项输出观测标记（①流式落盘→S1、②Range 206→S2、③identity 回显→S3、④TaskPool 8 并发→S4、⑤重定向+Cookie→S5、⑥超时错误码→S6） | ✅ 代码与 EXPECT 逐项对应（②表）；运行时待⑥ |
| 产出"http 还是 rcp"栈选型结论回写计划文档 | ⏳ **OPEN**——依赖运行证据；判定规则与回写模板已预登记（设计书 §8-A~E），xdm-probe-verify 判定后执行 |
| 对照 XDM 源码（DotNetHttpClient.cs 参考模型） | ✅ 研究/设计/审查三轮逐条对上（②表与独立复核 weakestSpot 佐证段） |

---

## ② 研究结论摘要（关键源码行为 → ArkTS 对应表）

研究员以 `resourses/xdm/app/XDM/XDM.Core` 的 DotNetHttpClient 参考模型（计划 §5 对照规格书指定）逐项核实，本会话逐行复核到当前代码：

| # | 原版源码行为（研究结论核实行号） | ArkTS/平台对应 | 本单元落点（本会话核实） |
|---|---|---|---|
| 1 | 响应体为阻塞流读取：`WinHttpResponseStream.cs:35-59` `Stream.Read` 循环（0 字节=流结束） | `requestInStream` 的 `on('dataReceive')`（Callback\<ArrayBuffer\>）+ `on('dataEnd')` 事件流——正是 MIGRATION_PLAN §6 决策 2 指定的"事件流替代阻塞读"机制；`request()` 有 5MB（API 23 起 50MB）接收上限，requestInStream 无此限 | ProbeHttp.ets:153-168：dataReceive 逐块计数+`fileIo.writeSync(fd,data)` 追加落盘 `probe-http-s1.bin`，dataEnd 置 streamClosed 并 resolve endGate；finally `:221-228` off×3+closeSync+destroy（官方防泄漏要求） |
| 2 | 首请求 `AddRange(0)` = `RangeHeaderValue(0,null)` = `bytes=0-`（`PieceGrabber.cs:387-395`）；206 总长从 Content-Range '/' 后解析（`DotNetHttpSession.cs:94-98`），ContentLength 取值链 Content-Length→ContentRange.Length→-1（`DotNetHttpSession.cs:32`） | `options.header['Range']='bytes=0-'` 注入；206 判定用 `http.ResponseCode.PARTIAL`（本机 d.ts:2881，枚举值 206）；`parseContentRange` 解析 content-range | ProbeHttp.ets:237-239（Range 注入）、`:253`（PARTIAL 判定）、`:247-251`（取值链）；ProbeHttpLogic.ets:66-91 |
| 3 | 默认头含 `Accept-Encoding: identity`（`SingleSourceHTTPDownloader.cs:519-530`）；`Utils.cs:9-18` IsCompressed=ContentEncoding/TransferEncoding 含 gzip\|deflate | 显式注入 `'Accept-Encoding':'identity'`，echo 服务回显实收头——identity 未被压缩协商即引擎 resumable 前提（决策 3；`DotNetHttpClient.cs:50-57` AutomaticDecompression=All 无对应物的反向验证） | ProbeHttp.ets:284-286（注入）、`:296-303`（serverEcho/contentLengthMatches）；echo server `:36-41/:105-108` 回显去空白保证单 token |
| 4 | 8 分段并发下载：`Config.cs:122` MaxSegments=8，每分片裸 Thread；官方 FAQ faqs-network-28 明示 http 并发数量无限制 | `splitRangeWindows(4194304,8)` 闭区间分窗（对齐 `AddRange(start,end)` 闭区间语义，PieceGrabber.cs:391-394）+ 模块级 `@Concurrent fetchSegment` ×8 `taskpool.execute`（参数全传值、结果以 JSON 字符串过 TaskPool 边界）；**worker 内 http 可用性即风险#4 观测本体** | ProbeHttpLogic.ets:101-117（分窗）；ProbeHttp.ets:60-99（worker）、`:329-333`（8×execute+Promise.all）、`:344`（JSON.parse as SegmentResult） |
| 5 | 重定向后回写最终 URL：`FinalUri = redirectUri ?? response.ResponseUri`（`PieceGrabber.cs:442-452`） | 本机 `@ohos.net.http.d.ts:3607-3760` 的 HttpResponse **无最终 URL 字段** → finalUrl 用测试源 `/final` 路由回显服务端实收 URL 等价观测；rcp 对照物 `Response.effectiveUrl`（rcp d.ts:2806，@since 20）可直取——列为 rcp 补偿点（设计书 §8-C） | ProbeHttp.ets:397-401：`redirectFollowed=(fields.url 以 '/final' 结尾)`、`finalUrl=回显值`；echo server `:119-123` 回显 `url=… cookie=…` |
| 6 | Cookie 以原始字符串注入请求头（`DotNetHttpClient.cs:84-87` `SetHeader(http,"Cookie",cookies)`） | `options.header['Cookie']` 同语义注入；本机 d.ts **无 enableAutoCookie**（grep 计数=0，官方标起始版本 26.0.0>24，禁用）；官方明示手动 Cookie 不跨主机转发 → 仅验同主机 302，跨主机留 U1.2 公网实测 | ProbeHttp.ets:388-390（注入）、`:400`（cookieSent 谓词=cookieSeen 含 ECHO_COOKIE）；echo server `:110-117`（302 绝对 Location） |
| 7 | 超时：`Config.cs:120` NetworkTimeout=30 → `SingleSourceHTTPDownloader.cs:101` `http.Timeout=30s`；错误码=2300000+curl 码（2300007 connect、2300028 timeout、2300047 重定向超上限，本机 d.ts:1102-1112） | connectTimeout/readTimeout 同一参数位（本机 d.ts 默认各 60000ms）；探针用 3000ms 短超时+RFC 5737 TEST-NET-1（192.0.2.1）不可达地址观测；产品值 30000ms 由 U1.2 固化 | ProbeHttp.ets:434-437（timeoutOptions）、`:440`（requestInStream 至 UNREACHABLE_URL）、`:461`（timedOut=isTimeoutCode(errCode)，ProbeHttpLogic.ets:149-151） |
| 8 | 状态强校验仅接受 200/206，其余抛 HttpException（`WebRequestExtensions.cs:23-29`）；引擎 Resumable=(!Compressed && StatusCode==206)（`PieceGrabber.cs:442-452`） | **探针红线（PROBE_SPEC §1）**：布尔键（streamClosed/rangeSupported/contentLengthMatches/all206/redirectFollowed/cookieSent/timedOut）全部是对直接观测值的谓词映射，期望不写进探针代码；200/206 判定与 Resumable 推导全部由 xdm-probe-verify 对照 EXPECT 复算 | ProbeHttp.ets:10-11（红线注释）；EXPECT 各 note 明示"谓词编码，非探针自身判定" |

**栈能力面对照结论（研究结论，待运行证据确认）**：`@ohos.net.http` 六项能力 API 面齐备（requestInStream 分块回调/PARTIAL/任意头注入/无并发上限/connect-readTimeout/curl 系错误码），建议主栈 http；rcp 列退化备选（有 effectiveUrl/autoRedirect/超时三分型/transferRange/downloadToFile @since 23，但**无 requestInStream 式分块流回调**，fetch=全量 ArrayBuffer）。切换触发条件=S1/S2/S4/S6 任一 FAIL（设计书 §8-C）；S5 finalUrl 缺口用回显补偿而非换栈（§8-E）。

---

## ③ 设计决策与有意差异（对照 MIGRATION_PLAN 条款）

### 3.1 计划条款引用

| MIGRATION_PLAN 条款 | 在本单元的落点 |
|---|---|
| §7.1 第 3 项（Phase 0 序列） | 本单元即该项："requestInStream 流式 + Range(0-)/206 判定 + identity 编码 + 8 并发连接 + 重定向/Cookie 注入 + 超时控制"——S1~S6 一一对应 |
| §6 决策 2（线程模型重构） | SegmentWorker 走 TaskPool：S4 的 8×taskpool.execute 与引擎 U2.1"每分段一个 TaskPool 任务"同构；`requestInStream` dataReceive 事件流替代阻塞读（S1） |
| §6 决策 3（分段算法/identity） | S2 单变量验 `Range:0-`→206；S3 反向验证强制 identity；206 判定与 Resumable 推导留 U2.1，本单元只产观测键 |
| §6 决策 9（HTTP 客户端） | 以 DotNetHttpClient 为参考模型；206 强校验/重定向回写最终 URL/Cookie 原始串注入/超时 30s 四要素全部入探针观测面；"http 还是 rcp"结论按 §0-3 后置回写 |
| §3 降级清单 #8（TLS 全放行） | 不迁移、探针不涉及（设计书 §4-4） |
| §8 验证矩阵 | hvigor 编译期 ArkTS 严格子集（主）+ codelinter 辅助；编译门禁零 error 零新 warning——⑤ |
| §9.4（探针闭环） | 探针页 + PROBE 手册 + EXPECT 表已产出 → 人工运行回贴 → xdm-probe-verify 判定；本单元产物见⑥ |
| PROBE_SPEC §2（detail 通道） | S1 响应头全量写 `probe-P0-U2-<runId>-s1-headers.txt`，标记行只记 `detailFile=`（ProbeHttp.ets:169-186），不塞单行 |

### 3.2 有意差异清单（材料"有意差异"11 条 + 设计书 §4，全部有意、有据）

| # | 有意差异 | 依据/理由 |
|---|---|---|
| 1 | 探针不注入原版六键默认头全集（`SingleSourceHTTPDownloader.cs:519-530`），各步只注入当步观测最小头（S2 仅 Range、S3 仅 identity、S5 仅 Cookie） | 单步单变量的观察隔离；六键逐键复刻是 U1.2 `core/net/HttpClient.ets` 的任务 |
| 2 | finalUrl 取测试源 /final 服务端回显而非栈字段 | 本机 HttpResponse 无最终 URL 字段（d.ts:3607-3760）；等价观测原版 FinalUri=redirectUri??ResponseUri（PieceGrabber.cs:442-452）；rcp `Response.effectiveUrl`（d.ts:2806）差异登记为选型补偿点（§8-C） |
| 3 | S6 超时观测用 3000ms 短超时而非产品 30s | PROBE_SPEC §2 示例同口径，避免单步 30s 阻塞；同一参数位（connectTimeout/readTimeout），产品值 30000ms 由 U1.2 固化（Config.cs:120 → SingleSourceHTTPDownloader.cs:101） |
| 4 | S6 用 RFC 5737 TEST-NET-1（192.0.2.1）不可达地址 | 不依赖测试源；主判 2300028（静默丢包），2300007（RST/拒绝环境）记 UNVERIFIED + 手册 §5 换地址/防火墙重跑指引 |
| 5 | S5 仅验同主机 302 Cookie 注入 | 官方明示手动 Cookie 不随重定向跨主机转发；本机 d.ts 无 enableAutoCookie（起始版本 26>24）；跨主机留 U1.2 公网双域名实测；U1.2 按原版语义每请求从 Cookie 存储重注（DotNetHttpClient.cs:84-87） |
| 6 | TLS 全放行/MaxConnectionsPerServer=100/AutomaticDecompression/PreAuthenticate 不迁移 | MIGRATION_PLAN §3 降级 #8 既有结论；S3 反向验证强制 identity（对等决策 3）；MaxConnectionsPerServer 由引擎 MaxSegments=8 封顶（Config.cs:122） |
| 7 | U0.1 遗留四项搭车闭环（IR-F5 会话守卫为单元指令 COLD-F5 硬要求） | IR-F5 三层守卫、IR-F4 空 kvs 补偿、IR-F1 createData 替换、IR-F2 lastLine 删除——均在触碰文件内，落地证据见④附表；U0.1 设计书三处笔误不搭车 |
| 8 | MIGRATION_PLAN §6 决策 9 / RISK #2/#4 不列本单元 files | 结论依赖运行证据；设计 §8 预登记 A~E 五分支回写文本模板，xdm-probe-verify 判定后由报告员执行 |
| 9 | 探针页形态与 P0-U0 不同：autoStart=false + TextInput 测试源 URL 参数行 | 模拟器/真机内不能用 127.0.0.1 访问主机（PROBE_SPEC §3 注记），URL 必须可替换；S1 响应头经 detail 通道落盘 |
| 10 | PROBE_SPEC.md:55-56 示例行的 S1/S2 内容与本单元步骤编号互换 | 以单元指令/EXPECT 为准（S1=流式落盘、S2=Range 206）；SPEC 示例是示意值非契约，本单元不改 PROBE_SPEC，主流程验收后统一示例 |
| 11 | S3 观测键用 sent/serverEcho/contentLengthMatches（单元指令括注为 acceptEncoding/serverEcho） | 信息等价（sent=探针自证发送值、serverEcho=实收回显），代码/EXPECT/手册四件套一致；键名映射注记为审查携带项（④#5） |

---

## ④ 审查问题处置表（对照审查 R1 5 项 + R2 4 项 + 独立复核 8 项；同项跨轮合并后共 9 个问题 + 附表 4 项搭车闭环，全部覆盖）

> 轮次标注：R1=对照审查第 1 轮（approved=false，5 项）；R2=第 2 轮（approved=true，4 项，均由 R1 携带）；IR=独立复核（acceptable=true，8 项，其中 F4~F7 与 R1/R2 携带项同源）。"已修复问题编号"=[R1-F1]，与本会话核实一致。

### 4.1 主表（9 个独立问题）

| 本报告编号 | 原始编号 | 严重度 | 位置 | 问题 | 处置 | 本会话证据 |
|---|---|---|---|---|---|---|
| P1 | R1-F1 | **high** | `entry/src/test/ProbeHttpLogic.test.ets:20` | 被测模块相对导入 `'../../main/ets/…'` 从 entry/src/test/ 解析到不存在的 entry/main/…，本地单测交付物不可编译/运行（不影响主 HAP，src/test 不参与 assembleHap） | **已修复**（第 2 轮前唯一代码修复） | `:20` 现为 `'../main/ets/probe/units/ProbeHttpLogic'`；本会话 `node path.resolve`：从 `entry/src/test` 解析至 `D:\git\HarmonyPC\XdmHarmony\entry\src\main\ets\probe\units\ProbeHttpLogic` 且 `existsSync=true`；lint 0 issue。诚实注记：Hypium 真跑仍无法执行（devecocli 无 test 子命令、hvigor wrapper 不在工程内），路径正确性以文件系统解析+lint 为证 |
| P2 | R1-F2 = R2-F1 = IR-F4 | low | `docs/design/u0-2-…-DESIGN.md:29` | 设计书称 EXPECT 表"共 8 条目"，实际 9 条目（EXPECT 与手册 §4 均正确一致），属设计文档计数笔误 | **未处置**（文档笔误） | 本会话 `node -e require('./EXPECT-…json')` → entries=9、order=BEGIN,S1..S6,SUMMARY,END；DESIGN.md:29 现文仍为"共 8 条目" |
| P3 | R1-F3 = R2-F2 = IR-F5 | low | `DESIGN.md:278` | 结构断言 `grep -rn "PASS\|FAIL" entry/src/main/ets/probe` 零命中按字面永假：命中 2 处 U0.1 既有注释；红线本体（标记行值不含判定词）未被违反 | **未处置**（断言需收窄：排除注释行或改为 KeyValue 值域检查） | 本会话 `grep -rn "PASS\|FAIL" entry/src/main/ets/probe` 命中 ProbeKit.ets:5、ProbeEnv.ets:5 两处注释（均为解释红线的注释文本）；探针标记行键集（EXPECT S1~S6）无 PASS/FAIL 词 |
| P4 | R1-F4 = R2-F3 = IR-F6 | low | `docs/probe/PROBE-u0-2-http-capability-probe.md:14-16` | 手册 §0 缺 `devecocli emulator start "Pura 90"` 与 `devecocli device list` 两步（U0.1 手册 :28-29/:36 与 PROBE_SPEC §3 模板 :87-88 均含）；冷环境照手册直接 run 会因无在线设备失败 | **未处置**（文档补两行） | 本会话 grep 对比：U0.2 手册仅 `:15` 有 `emulator list`；U0.1 手册 `:28-29`（emulator list/start）与 `:36`（device list）具备 |
| P5 | R1-F5 = R2-F4 = IR-F7 | low | `entry/src/main/ets/probe/units/ProbeHttp.ets:300` | S3 观测键用 sent/serverEcho/contentLengthMatches，偏离单元指令括注与 PROBE_SPEC.md:57 示例的 acceptEncoding/serverEcho 键名；信息等价、四件套一致、判定无歧义，但 EXPECT S3 note 未补键名映射说明 | **未处置**（注记类，三选一：EXPECT note 补映射 / 探针增发 acceptEncodingEcho 键 / 设计 §0 补拍板注记） | 本会话核实 ProbeHttp.ets:299-303、EXPECT S3（expect 第 21 行）、手册 §4 表（:85）三处一致用 `sent=identity`；EXPECT :22 note 仅解释 serverEcho 含义 |
| P6 | IR-F1（独立复核新发现，**weakestSpot**） | **medium** | `ProbeHttp.ets:191`（S1 endGate）、`:82`（S4 fetchSegment endGate，`:69-73` 实现） | S1/S4 的 dataEnd 门控 await 无超时、无错误旁路：本机 SDK 的 HttpRequest 事件面只有 dataReceive/dataEnd/header(s)Receive 四种事件（复核 grep 核实，无 error/fail 事件），requestInStream 的 Promise 仅返回 ResponseCode——若响应头已收、体传输中途断流且 dataEnd 不触发，`await endGate` 永久挂起：该步骤永不 emit、S1 finally（closeSync/destroy）永不执行（fd/client 泄漏）、startSession 在 await runStep 挂起（sessionRunning 卡 true）；S4 则 worker 永不 resolve、占用 taskpool worker | **未处置**（运行时风险，代码零设防点）。复核建议：给 endGate 加界 `Promise.race([endGate, 定时兜底])`，超时分支按 streamClosed=false 落盘 emit 并 destroy 触发 finally；S4 同理组装 errCode SegmentResult 返回。报告员意见：作为探针一次性工具可先运行观察（手册 §3 兜底命令与 devecocli log --crash 可取证），若命中该形态按返修流程处理；**该形态对 U1.2/U2.x 产品代码是硬约束——下载循环不得沿用无界 await dataEnd** | 本会话复读 ProbeHttp.ets:69-73（worker endGate 无 race/超时）、:153-158+:191（S1 同形态）、:220-229（finally 仅在正常/异常完成路径执行）；d.ts 事件面缺 error 事件为复核员本机 grep 结论（本会话未重复 grep d.ts） |
| P7 | IR-F2（独立复核新发现） | low | `ProbeKit.ets:202-208`（fmtClock HHmmss）+ `:150-152`（isCurrent） | runId 仅精确到秒：同秒两次 begin()（如 P0-U0 autoStart begin → 返回 → P0-U2 点"运行全部"全程 <1s）使 isCurrent 对旧会话恒 true，守卫失效、两套循环同 runId 交错 emit | **未处置**（手动触发概率低；fmtClock `:201` 注释明示"不引入毫秒/随机数"，由 BEGIN/END 配对 + verify 取最后 runId 吸收——该假设建立在会话完整串行上，真异步后不严密） | 本会话复读 ProbeKit.ets:201-208 与 :150-152；复核建议（毫秒位或代际计数）登记⑦ |
| P8 | IR-F3（独立复核新发现） | low | `docs/probe/EXPECT-…json:27`（S4 note）、手册 `:98`（§5 表第 3 行） | S4 风险#4 判据缺"S1/S2/S6 已 PASS"前提：测试源/网络整体不可达时 S4 在 worker 内同样以 2300007 等连接错误失败，按现文照判会把 env 故障误归因为 TaskPool 内 http 不可用；设计书 §8-B 本身有前提（"仅 S4 FAIL（S1/S2/S6 PASS）"），EXPECT/手册转录时丢失 | **未处置**（文档补前提句） | 本会话复读 EXPECT :27 note 现文（"all206=false 且 firstErrCode 非 0 → 风险#4 实证"，无前提）；DESIGN.md:300 §8-B 标题含"（S1/S2/S6 PASS）" |
| P9 | IR-F8（独立复核新发现） | low | `DESIGN.md:278` | 同一断言中 `grep -rn "@Entry" entry/src/main/ets "恰 2 处不变"` 按字面 grep 永远数出 3（含 ProbeIndex.ets:2 注释行）；真实 @Entry 装饰器确为 2 处 | **未处置**（断言改为 `grep -rn "^@Entry"` 或排除注释行） | 本会话 grep 命中 3 行：pages/Index.ets:16、probe/ProbeIndex.ets:2（注释）、probe/ProbeIndex.ets:21（装饰器） |

### 4.2 附表：U0.1 遗留四项搭车闭环（本单元触碰基建文件内落地，本会话逐项核实）

| U0.1 编号 | 内容 | 落地证据（本会话） |
|---|---|---|
| U0.1-IR-F1 | `createPlainTextData`（@deprecated since 9）→ `pasteboard.createData(MIMETYPE_TEXT_PLAIN, …)` | ProbePage.ets:175 现用 createData；本会话 `grep -rn "createPlainTextData" entry/src/main/ets` **零代码命中** |
| U0.1-IR-F2 | ProbeKit `lastLine` 死代码删除 | 本会话 grep 命中仅 ProbeKit.ets:11 注释（描述删除事实），无字段/赋值代码 |
| U0.1-IR-F4 | emit 空 kvs / end 零 summaries 补 `kvs=0` | ProbeKit.ets:99-100（emit）、`:122`（end）；防 NOMATCH 畸形行 |
| U0.1-IR-F5 | 会话代际守卫（单元指令 COLD-F5 硬要求，U0.2 真异步后变活） | ProbeKit.ets:150-152 `isCurrent`；ProbePage.ets 五守卫点（:77/:87/:94/:110/:132-141-149-164）；ProbeHttp 各 runner 入口捕获 runId（如 :137）+ 每个 await 后/emit 前复检（如 :171/:188/:192/:208/:243/:290/:307/:334/:370/:394/:441/:455） |

**处置统计**：已修复 1（P1，high）｜ 未处置 8（P6 medium + P2~P5/P7~P9 low）。未处置项中代码类仅 P6（防御缺口）与 P7（低概率守卫旁路）；其余均为文档/注记类。无阻断验收的发现。

---

## ⑤ 验证情况

### 5.1 hvigor 编译门禁 ✅

- **主流程门禁（材料，非本报告员执行）**：`devecocli build --modules entry` 最终状态**通过**。
- **本报告员复跑 1（本会话）**：`cd D:/git/HarmonyPC/XdmHarmony && devecocli build --modules entry` → **exit 0，BUILD SUCCESSFUL in 583 ms**。诚实注记：此为**增量构建**（`CompileArkTS` UP-TO-DATE），未重新产出 ArkTS 编译诊断。
- **本报告员复跑 2（本会话，强制重编译）**：`touch` 5 个 U0.2 源文件（ProbeHttp/ProbeHttpLogic/ProbeKit/ProbePage/ProbeIndex，仅改 mtime 不改内容）后重跑 → `CompileArkTS` **真实执行（Finished … after 1 s 266 ms）**，**BUILD SUCCESSFUL，exit 0，零 error**。全程 WARN 共 2 条：
  1. `Will skip sign 'hos_hap'. No signingConfigs profile is configured` —— 模拟器免签名既有基线告警（U0.1 同）；
  2. `ArkTS:WARN File: …/ProbeHttp.ets:225:9 Function may throw exceptions. Special handling is required.` —— 指向 runS1 finally 中 `fileIo.closeSync(fd)`（ProbeHttp.ets:225）的提示级诊断。**该条在材料门禁结论中不可见（门禁输出前文截断），无法确认门禁轮是否同样出现；由本会话强制重编译揭示**。属提示级（ArkTS:WARN 非 error），构建不阻断；该位置是官方防泄漏模式（finally 必须关 fd）的固有形态，登记于⑦#6 由人工定夺是否随 P6 返修一并处理。
- 综合判定：**当前工作区可构建**——权威证据 = 主流程门禁轮全量构建"通过"（材料）+ 本会话强制重编译零 error（5.1 复跑 2）。

### 5.2 codelinter 辅助检查 ✅（提示性，不含 ArkTS 语法规则）

- **主流程门禁（材料）**：exit 0；Summary: Issues: 13 | Errors: 0 | Warnings: 13 | Suggestions: 0 | Files checked: 2。
- **本报告员复跑（本会话）**：`devecocli check lint entry/src/main/ets/probe` → 输出与门禁轮**逐条一致**：13 W / 0 E / checked 2——ProbePage.ets 12 条 `@performance/hp-arkui-use-local-var-to-replace-state-var` + ProbeEnv.ets 1 条 `@performance/avoid-overusing-custom-component-check`，均为 U0.1 既有文件的编排模式建议级告警（U0.1 报告⑤.2 已登记口径）；**U0.2 新增 4 文件（ProbeHttp/ProbeHttpLogic/ProbeIndex/ProbeKit）零告警**。
- 工具行为注记：单文件模式 `devecocli check lint <file>` 对非入口文件返回 Files checked: 0（本会话实测），故目录模式为本会话采用口径。

### 5.3 本会话结构断言（全部亲自执行）

| 断言 | 命令（摘要） | 结果 |
|---|---|---|
| EXPECT 合法性与条目数 | `node -e "require('./docs/probe/EXPECT-u0-2-http-capability-probe.json')"` + 计数 | OK；unitId=P0-U2、**entries=9**、order=BEGIN,S1,S2,S3,S4,S5,S6,SUMMARY,END（佐证 P2） |
| string.json 合法性 | `node` JSON.parse + 键名过滤 | OK；**18 键**（16 既有 + probe_http_title/probe_http_source_hint） |
| 标记行红线 grep | `grep -rn "PASS\|FAIL" entry/src/main/ets/probe` | 命中 2 处注释（ProbeKit.ets:5、ProbeEnv.ets:5）——P3 复现，红线本体未违反 |
| @Entry 断言 | `grep -rn "@Entry" entry/src/main/ets` | 3 行命中（Index.ets:16、ProbeIndex.ets:2 注释、:21 装饰器）——P9 复现，真实装饰器 2 处 |
| 业务页零 probe 依赖 | `grep -n "import" entry/src/main/ets/pages/Index.ets` | **0 行命中** |
| 搭车闭环落地 | `grep -rn "lastLine\|createPlainTextData" entry/src/main/ets` | 仅 ProbeKit.ets:11 注释命中；两处代码均零残留（附表） |
| R1-F1 修复验证 | `node -e "path.resolve('entry/src/test','../main/ets/probe/units/ProbeHttpLogic')"` + existsSync | 解析至真实模块位置，exists=true |
| 基线配置在位 | `grep -n "2in1\|INTERNET" entry/src/main/module.json5` | `:9` 2in1、`:16` INTERNET（U0.1 落地，本单元未动 module.json5，与设计书 §0-4 一致） |
| 手册模拟器步骤对比 | grep 两份 PROBE 手册 | U0.2 手册仅 :15 emulator list，缺 start/device list（P4 复现） |

### 5.4 对照审查与独立复核结论（材料）

- 对照审查第 1 轮：**approved=false**（5 项：F1 high + F2~F5 low）→ 返修 R1-F1 后第 2 轮 **approved=true**（4 项携带，全 low）。
- 独立复核：**acceptable=true**（8 项：medium 1（P6）+ low 7；weakestSpot 指向 S1/S4 endGate 双等门，其余源码保真度评价扎实——Range 'bytes=0-'、FinalUri、Cookie 注入、identity、NetworkTimeout=30/MaxSegments=8 逐条对上源码）。

### 5.5 未执行/不可用项（诚实声明）

- **探针运行**：未执行（属人工待办，⑥）；本报告全部运行时结论仅到"静态可判定"层。
- **Hypium 本地单测真跑**：无法执行——`devecocli --help` 无 test 子命令（设计书 §7-[A]-3 诚实注记）；hvigor wrapper 不在工程内（`hvigor/` 仅 hvigor-config.json5）。16 个用例已入库（路径正确性以 5.3 文件系统解析+lint 为证），实跑须 IDE/hvigor 侧执行或留 U2.3 统一回归。
- `devecocli check compat`：本机 DevEco 6.1.1.300 低于所需版本，不可用（U0.1 报告⑤.5 既有结论，本会话未复跑）。
- 设计书 §7-[A]-2 的两条 grep 断言按字面不可通过（P3/P9），本会话以收窄口径执行并记录。

### 5.6 ArkTS 合规说明

ArkTS 严格子集**由 hvigor 编译期强制**（codelinter 不含 ArkTS 语法规则）——⑤.1 编译门禁通过（含强制重编译轮）即合规依据。编码期按 arkts-grammar-standards 自查的关键合规点在代码中可见：无 any/解构/正则字面量/构造器参数属性；正则一律 `new RegExp`（ProbeKit.ets:35-37）；`@Concurrent` 模块级顶层函数、参数全传值、无闭包捕获（ProbeHttp.ets:60-61，worker 内常量内联字面量 `:80`）；`Record<string,string>` 具型字面量逐键下标赋值（如 :77-78/:237-238）替代裸对象字面量；`Object.keys` 遍历替代 for...in（ProbeHttpLogic.ets:54）；`JSON.parse(text) as SegmentResult` 具型断言（:344）；async 方法显式 `Promise<void>/Promise<string>`（:61/:107/:136 等）；`as Record<string,string>` 对 resp.header（Object 槽位）的转换通过 hvigor 门禁（设计书 §3.1 备选 JSON 往返未需启用）。

### 5.7 git 状态（本会话核实）

`git status --porcelain`：4 个修改（ProbeIndex.ets、ProbeKit.ets、ProbePage.ets、string.json）+ 6 个未跟踪（docs/probe/ 三件、units/ 两件、entry/src/test/）——**本单元 11 个交付文件全部未提交**。仓库现有 3 个 commit（`8e7cc57` Initial、`0687ee1` U0.1 单元提交、`befa818` docs 纳入版本控制），**无 tag**。详见⑨。

---

## ⑥ 运行时验证待办（探针运行指引）

**状态：探针 P0-U2 已生成、尚未运行、日志未回贴。本单元运行时验收 OPEN，栈选型结论（验收点"结论明确"）随判定产出。**

- 探针手册：`XdmHarmony/docs/probe/PROBE-u0-2-http-capability-probe.md`（echo 服务与 http-server 双起源、可替换测试源 URL、九行预期序列、环境差异分支、守卫冒烟）
- 机器可读期望表：`XdmHarmony/docs/probe/EXPECT-u0-2-http-capability-probe.json`（unitId=P0-U2，9 步骤，本会话解析通过）

人工执行要点（详见手册 §0~§7；UNIT_CATALOG.md:108 将 U0.2 列为"仅两类必须提前跑"的结论型探针——**判定结论是 U1.2 开写前提**）：

1. **起源（主机侧，全程在线）**：`node docs/probe/P0-U2-echo-server.js 8080`（绑 0.0.0.0，覆盖 S1~S6 全部六步）；自检 `curl http://<主机局域网IP>:8080/echo` 回 `acceptEncoding=…`、`curl -H "Range: bytes=0-" -o NUL -w "%{http_code}" …/big.bin` 应 206；Windows 防火墙放行。备选 `npx http-server` 仅覆盖 S1/S2/S4，S3/S5 记 UNVERIFIED。
2. **设备侧**：模拟器免签名（`devecocli emulator list` 确认 "Pura 90"）；真机先一次性签名（auth login + signature generate）。`devecocli run --module entry` → `hdc shell "aa start -b com.example.xdmharmony -a EntryAbility --ps page probe"` → 探针首页点 P0-U2 → **把 TextInput 缺省 `http://192.168.1.20:8080` 改为主机实际局域网 IP（禁 127.0.0.1）** → 点"运行全部"。
3. **抓取**：`hdc shell "hilog -x | grep XDM_PROBE" > probe-P0-U2.log`；兜底 `cat <filesDir>/probe-latest.txt`；S1 交叉核对 `ls -l <filesDir>/probe-http-s1.bin`（应 4194304 字节）与 `cat <filesDir>/probe-P0-U2-<runId>-s1-headers.txt`。
4. **预期九行序列**：BEGIN（runId=HHmmss/filesDir）+ S1 url/status/chunks/totalBytes/firstChunkBytes/writtenBytes/streamClosed/detailFile + S2 requestRange=bytes=0-/status=206/contentLength/contentRangeTotal/rangeSupported + S3 sent=identity/serverEcho/contentLengthMatches + S4 concurrent=8/all206/min-maxDurationMs/totalBytes/firstErrCode + S5 requestUrl/status/redirectFollowed/finalUrl/cookieSeen/cookieSent + S6 timeoutSetMs=3000/timedOut/errCode/elapsedMs + SUMMARY（恰 6 段）+ END（ok/steps=6/elapsedMs）。
5. **环境差异分支**（手册 §5）：S6 errCode=2300028 主判 PASS；2300007 → UNVERIFIED，换 TEST-NET-2 地址（198.51.100.1）重构建重跑或检查防火墙/关代理；S4 all206=false 且分段 errCode 全非零且 S1/S2/S6 PASS → 风险#4 实证，按设计书 §8-分支 B 回写（**非 probe-code 返修**）。
6. **会话守卫冒烟（COLD-F5 运行时验证）**：S4 运行中 HOME 退后台 → `aa start --ps page probe` 暖启动重进 P0-U2 立即"运行全部" → 新会话九行完整、runId 单调配对、无旧步骤标记行串入、无孤儿 END。
7. **回贴与判定**：probe-P0-U2.log 全文回贴 → `xdm-probe-verify` 对照 EXPECT 逐步骤 PASS/FAIL/UNVERIFIED/MISSING 判定 → **按设计书 §8 五分支模板回写 MIGRATION_PLAN §6 决策 9 与 RISK_ASSESSMENT 风险#2/#4**（A 六步全绿=主栈 http 定案；B 仅 S4 FAIL=风险#4 实证走全主线程退化；C S1/S2/S6 任一 FAIL=主栈切 rcp 并登记补偿点；D 仅 S3 FAIL=identity 不可依赖；E 仅 S5 异常=maxRedirects/Cookie 每请求重注，不换栈）。

---

## ⑦ 遗留问题与风险

1. **P6/IR-F1（medium，最重运行时风险）**：S1/S4 的 `await endGate` 无界——中途断流且 dataEnd 不触发时整会话静默假死 + fd/client/taskpool worker 泄漏，只能重启应用恢复。处置：探针运行观察（假死形态按④P6 特征识别：S1 行缺失且 sessionRunning 卡 true）；命中即按复核建议返修（endGate 加 Promise.race 兜底）。**产品侧硬约束**：U1.2 Downloader/U2.1 SegmentWorker 的下载循环必须自带超时兜底，不得沿用无界 await dataEnd 形态。
2. **P7/IR-F2（low）**：runId 秒级精度 + 同秒 begin() 使会话守卫旁路。概率低（需 <1s 内两次 begin）；若守卫冒烟（⑥-6）出现串话，按复核建议引入毫秒位或代际计数。
3. **文档修订清单（low，5 项，建议主流程一次性修）**：① 设计书 :29 "8 条目"→"9 条目"（P2）；② 设计书 :278 两条 grep 断言收窄——PASS/FAIL 断言排除注释行或改 KeyValue 值域检查、@Entry 断言锚定行首 `^@Entry`（P3/P9）；③ 手册 §0 补 `devecocli emulator start "Pura 90"` 与 `devecocli device list` 两行（P4）；④ EXPECT S4 note 与手册 §5 行补"且 S1/S2/S6 已 PASS"前提（P8）；⑤ EXPECT S3 note 补"单元指令/SPEC 示例的 acceptEncoding 键在本探针记为 sent"映射说明（P5）。
4. **Hypium 单测真跑缺 runner（low，流程）**：16 用例已入库未执行；编码员 IDE/hvigor 侧实跑一次并记录，若 LocalUnit 任务在 SDK 6.1.1 不可用，注明"待 U2.3 统一回归"（UNIT_CATALOG U2.3 行即引擎保真度对照单测）。
5. **S6 环境分叉（计划内）**：2300007（RST 环境）记 UNVERIFIED，手册 §5 重跑指引已就位；若两地址均持续 2300007，S6 判 FAIL 分流 env。
6. **提示级 WARN 一条（本会话揭示）**：`ProbeHttp.ets:225:9 Function may throw exceptions`（runS1 finally 的 closeSync）。材料门禁结论无此条（输出截断），无法确认门禁轮是否出现；不阻断构建，是否随 P6 返修一并加 try 包裹由人工定夺。
7. **计划内挂起项**：MIGRATION_PLAN §6 决策 9 / RISK #2/#4 回写（⑥-7 判定后执行）；PROBE_SPEC §2 示例 S1/S2 编号错位统一（主流程验收后）；探针临时文件（probe-http-s1.bin 4MiB 等）与 probe/ 目录整体移除（U7.3，PROBE_SPEC §1）；真机签名一次性准备；跨主机 Cookie 转发公网实测（U1.2）。

---

## ⑧ 对下个单元的建议

1. **先跑探针再开 U1.2（关键路径）**：UNIT_CATALOG v2 节奏"U0.2 探针 PASS 即开 Phase 1"。U1.1（数据模型+存储+配置骨架）不依赖 HTTP 栈结论，可与探针运行并行开工；U1.2（HttpClient.ets）必须等 ⑥-7 判定与回写完成。
2. **回写执行**：xdm-probe-verify 判定后，按设计书 §8-A~E 模板回写 MIGRATION_PLAN §6 决策 9 与 RISK_ASSESSMENT 风险#2/#4，结论标注验证环境（真机/模拟器）与日期；分支 B/C 触发时同步更新 U1.2/U2.1 的单元参数 notes。
3. **U1.2 HttpClient.ets 开写时吸收本单元观测面**：六键默认头逐键复刻（User-Agent/Accept/Accept-Encoding:identity/Accept-Language/Accept-Charset/Referer，`SingleSourceHTTPDownloader.cs:519-530`）；readTimeout 固化 30000ms（Config.cs:120）；重定向回写按 §8-C 补偿点（rcp effectiveUrl 或服务端回显）；Cookie 每请求从存储重注；maxRedirects 视 S5 结果决定是否显式设置。
4. **P6 形态转产品约束**：若探针运行实证 endGate 假死形态，U1.2/U2.1 的 requestInStream 循环必须加超时兜底（Promise.race 或 readTimeout 对齐）并在 SegmentWorker 设计中消化 worker 泄漏问题。
5. **守卫基建沿用**：isCurrent 三层守卫（ProbeKit/ProbePage 五守卫点/runner 内复检）已成模板，后续探针单元（U0.3/U1.1/U1.2…）的 runner 直接复制该模式；探针页 autoStart 语义按单元需要选择（U0.2 的 autoStart=false+TextInput 形态适用于一切需主机侧测试源的单元）。
6. **文档小修清单勿带入下单元**：⑦#3 五项建议在下一次触碰对应文件时顺手闭环（手册/EXPECT 属 docs/probe/，设计书属 docs/design/），或在 Phase 0 末批修。
7. **单测执行环境**：U1.1/U2.3 交付本地用例前，先确认 IDE/hvigor 侧 LocalUnit 任务在本机 SDK 6.1.1 的可用性（本单元 P1 修复后路径已正确，执行层仍缺 runner）。

---

## ⑨ git 提交说明

**本单元代码未做 git 提交**：`git status --porcelain`（本会话核实）显示 4 个修改文件（ProbeIndex.ets、probe/core/ProbeKit.ets、probe/core/ProbePage.ets、string.json）+ 6 个未跟踪项（docs/probe/EXPECT-u0-2-http-capability-probe.json、docs/probe/P0-U2-echo-server.js、docs/probe/PROBE-u0-2-http-capability-probe.md、entry/src/main/ets/probe/units/ProbeHttp.ets、ProbeHttpLogic.ets、entry/src/test/），全部处于未暂存/未跟踪状态。仓库现有 3 个 commit（`8e7cc57` Initial、`0687ee1` U0.1 单元、`befa818` docs），**无任何 tag**。按单元指令⑨与 MIGRATION_PLAN §9.3：**待人工完成⑥的探针回贴判定并通过验收后，由人提交并按 Phase 打 tag（`phase-0`）**。`resourses/xdm` 对照源码全程只读，本会话未做任何改动。

---

> 附：本报告证据生成命令清单（本会话，工作目录 D:/git/HarmonyPC/XdmHarmony）——
> `node -e`（EXPECT/string.json 解析与计数）；`grep -rn "PASS\|FAIL" entry/src/main/ets/probe`；`grep -rn "@Entry" entry/src/main/ets`；`grep -n "import" entry/src/main/ets/pages/Index.ets`；`grep -rn "lastLine\|createPlainTextData" entry/src/main/ets`；`node -e`（path.resolve + existsSync 验证测试导入）；`git status --porcelain` / `git log --oneline -3` / `git tag`；`devecocli build --modules entry`（两次，第二次前置 touch 5 个 U0.2 源文件强制 CompileArkTS）；`devecocli check lint entry/src/main/ets/probe`；`grep` 对比两份 PROBE 手册模拟器步骤与 module.json5/main_pages.json 基线。
