# U0.2 HTTP 能力探针 · 模块设计书

> 单元：U0.2（Phase 0 第 2 项，探针单元 ID `P0-U2`）。来源：xdm-migrate 工作流"模块设计师"角色，2026-09-27。
> 依据：MIGRATION_PLAN §6 决策 2/9、§7.1 第 3 项；UNIT_CATALOG U0.2 行；PROBE_SPEC v1；单元指令（六项验证 + 两个硬要求）；源码研究结论（DotNetHttpClient 参考模型，本机 SDK 6.1.1(24) d.ts 核实）；U0.1 报告遗留项（IR-F1/IR-F2/IR-F4/IR-F5）。
> 对照源码（本会话只读核实，未改 resourses/ 下任何文件）：`XDM.Core/Clients/Http/DotNetHttpClient.cs`、`DotNetHttpSession.cs`、`Utils.cs`、`WebRequestExtensions.cs`、`XDM.Core/Downloader/Progressive/PieceGrabber.cs`、`SingleHttp/SingleSourceHTTPDownloader.cs`、`XDM.Core/Config.cs`。

## 0. 冲突与拍板注记（必读）

1. **PROBE_SPEC §2 示例与本单元步骤编号错位**：PROBE_SPEC.md:55-56 示例行把"Range 206"放 S1、"流式 chunks"放 S2；单元指令编号是 ①流式落盘=S1、②Range 206=S2。**以单元指令/本设计 §6 为准**——SPEC 示例是示意值非契约，EXPECT 表才是唯一判定依据。本单元不改 PROBE_SPEC（不在目标落点，越权），主流程可在验收后统一示例。
2. **"30s 超时"的探针口径**：产品语义（MIGRATION_PLAN 决策 9 的 NetworkTimeout=30，`Config.cs:120` + `SingleSourceHTTPDownloader.cs:101` `http.Timeout = TimeSpan.FromSeconds(Config.Instance.NetworkTimeout)`）在 U1.2 的 `core/net/HttpClient.ets` 固化为 readTimeout=30000ms。本探针验证的是**超时控制机制与错误码形态**，用短超时 3000ms 观测（对齐 PROBE_SPEC §2 示例 `timeoutSetMs=3000`，避免单步阻塞 30s）——二者是同一参数位（connectTimeout/readTimeout，本机 d.ts 默认各 60000ms）的不同取值，见 §6-S6。
3. **栈选型结论的回写时点**："http 还是 rcp"结论依赖真机/模拟器运行证据，编码期不可能产出。本设计 §8 **预登记五分支判定规则与回写文本模板**，由报告员在 `xdm-probe-verify` 判定后执行回写（MIGRATION_PLAN §6 决策 9、RISK_ASSESSMENT 风险#2/#4）——"结论明确"的验收 = 规则可机械映射 + 模板就位 + 手册/EXPECT 就位。
4. **module.json5 不在本单元 files**：U0.1 已落地 ohos.permission.INTERNET 与 deviceTypes 2in1（本会话复核 `module.json5:7-10` deviceTypes=["phone","2in1"]、`:14-18` requestPermissions=[INTERNET]）。本单元无新增能力（无后台任务/剪贴板读取/深链），无新增权限；`main_pages.json` 亦不动（探针子页沿用页内条件渲染惯例，PROBE_SPEC §1；main_pages 只保留 Index 与探针首页）。若编码时发现权限缺失（异常态），上报主流程而非擅自改配置。
5. **U0.1 报告 IR-F5（单元指令称 COLD-F5，同一发现）**：ProbeKit 单例 begin() 无条件重置 + ProbePage 异步循环无会话代际校验。U0.1 全同步执行不可达；U0.2 首次引入真异步步骤（requestInStream 事件回调、TaskPool、重定向跟随）后变活。本单元**开工先落守卫**（§3.5），再写 ProbeHttp。

## 1. 目标文件清单（按实现顺序）

| # | 文件 | 新/改 | 职责 | 对外导出 | 依赖 |
|---|---|---|---|---|---|
| 1 | `entry/src/main/ets/probe/core/ProbeKit.ets` | 改 | 会话代际守卫基建（IR-F5）+ emit/end 空观测守卫（IR-F4）+ lastLine 死代码清理（IR-F2）；其余契约一行不动 | 新增 `isCurrent(runId: string): boolean`；begin/emit/end/KeyValue 等签名不变 | 无 |
| 2 | `entry/src/main/ets/probe/core/ProbePage.ets` | 改 | startSession/runSingle 会话代际守卫改写（§3.5 五守卫点）；IR-F1 修复 `createPlainTextData`→`createData` | 接口不变（`ProbePage`/`ProbeStepDef`） | #1 |
| 3 | `entry/src/main/ets/probe/units/ProbeHttpLogic.ets` | 新 | 纯函数与可序列化类型模块（**零 @kit import**，本地单测可直接 import）：常量 + 4 个 interface + 5 个纯函数 | `BIG_BIN_BYTES`、`PROBE_TIMEOUT_MS`、`UNREACHABLE_URL`、`ECHO_COOKIE`、`RangeWindow`、`ContentRangeParts`、`EchoFields`、`SegmentResult`、`headerOf`、`parseContentRange`、`splitRangeWindows`、`parseEchoBody`、`isTimeoutCode` | 无 |
| 4 | `entry/src/main/ets/probe/units/ProbeHttp.ets` | 新 | P0-U2 探针 @Component：测试源 URL 输入行（TextInput）+ ProbePage(autoStart=false)；S1~S6 runner；顶层 `@Concurrent fetchSegment`（S4 八任务）；响应头 detail 文件落盘 | `ProbeHttp`（struct） | #1 #2 #3 |
| 5 | `entry/src/main/ets/probe/ProbeIndex.ets` | 改 | PROBE_UNITS 注册表追加 P0-U2 项；详情分支重构为嵌套 if（P0-U0→ProbeEnv / P0-U2→ProbeHttp），公共头部行不重复 | —（@Entry 页） | #4 |
| 6 | `entry/src/main/resources/base/element/string.json` | 改 | 追加 `probe_http_title`、`probe_http_source_hint` 两键（既有 16 键不动，纯 JSON 禁尾逗号） | —（资源） | 无 |
| 7 | `entry/src/test/ProbeHttpLogic.test.ets` | 新 | 纯函数 Hypium 本地用例（用例清单见 §7-[A]-3） | default testsuite 注册函数 | #3 |
| 8 | `entry/src/test/List.test.ets` | 新 | 本地单测入口 testsuite（注册 #7） | `testsuite` | #7 |
| 9 | `docs/probe/P0-U2-echo-server.js` | 新 | 主机侧测试源（Node ≥14，零依赖单文件）：big.bin(Range)/echo/redirect/final 四路由，绑 0.0.0.0 | —（脚本，不参与 hvigor 编译） | 无 |
| 10 | `docs/probe/PROBE-u0-2-http-capability-probe.md` | 新 | 探针运行手册：**可替换测试源 URL 参数**、`npx http-server` 备选起源指引、echo 服务起源指引、九行预期序列、2300007/2300028 环境差异指引 | —（文档） | #9 #4 #6 |
| 11 | `docs/probe/EXPECT-u0-2-http-capability-probe.json` | 新 | 机器可读预期表（BEGIN/S1~S6/SUMMARY/END 共 8 条目，expect + note，判定要点与本设计 §6 一一对应） | —（JSON，须通过 JSON.parse 校验） | #10 |

**显式不动的配置文件（有据，非遗漏）**：`module.json5`（§0-4）、`main_pages.json`（探针子页不注册，ProbeIndex 已注册）、`docs/PROBE_SPEC.md` / `MIGRATION_PLAN.md` / `RISK_ASSESSMENT.md`（§0-1/§0-3，后置处理）。**业务页面零 probe 依赖**：`pages/Index.ets` 不改（U0.1 已核零 import，本单元不触碰）。

## 2. 数据模型与表结构（对照源码逐一核对）

### 2.1 业务表结构：无

无 RelationalStore 表、无 preferences、无既有二进制格式兼容。探针落盘文件三类（前两类为本单元新增，均走 PROBE_SPEC §2 既有通道）：

| 文件（沙箱 `<filesDir>/` 下） | 产生步骤 | 内容 | 生命周期 |
|---|---|---|---|
| `probe-http-s1.bin` | S1 | big.bin 全量 4194304 字节的流式落盘（dataReceive 逐块 writeSync） | 保留作证据（手册 §3 `ls -l` 交叉核对），探针不自动清理 |
| `probe-P0-U2-<runId>-s1-headers.txt` | S1 | headersReceive 原始响应头 `JSON.stringify` 串（大段数据不进 hilog 的 detail 通道） | 同上；标记行只记 `detailFile=<文件名>` |
| `probe-latest.txt` | 脚手架 | 全部标记行兜底（U0.1 既有，恒名不改） | 不变 |

### 2.2 测试源契约（`docs/probe/P0-U2-echo-server.js`，随手册交付）

| 路由 | 响应 | 关键头 | 体 |
|---|---|---|---|
| `GET /big.bin`（无 Range） | 200 | `Content-Type: application/octet-stream`、`Content-Length: 4194304`、`Accept-Ranges: bytes` | 确定性字节流：第 k 个 64KB 块填充 `k % 251`，总长 4194304 |
| `GET /big.bin`（`Range: bytes=s-` 或 `bytes=s-e`） | 206 | `Content-Range: bytes s-e/4194304`、`Content-Length: e-s+1` | 对应区间字节 |
| `GET /echo` | 200 text/plain | `Content-Length` 与体一致 | 单行 `acceptEncoding=<实收头值或 absent>` |
| `GET /redirect` | 302 | `Location: http://<req.headers.host>/final`（**绝对地址**，规避 client 对相对 Location 的解析差异） | 空 |
| `GET /final` | 200 text/plain | `Content-Length` 与体一致 | 单行 `url=http://<host>/final cookie=<实收 Cookie 头或 absent> acceptEncoding=<实收值或 absent>` |
| 其余 | 404 | — | — |

- 常量 `BIG_BIN_BYTES=4194304`（4MiB）在 echo server、ProbeHttpLogic.ets、EXPECT 三处**同值**（verify 比对锚）；4MiB 按 64KB 分块 ≈64 块，足够呈现分块行为，且远低于 request() 接收上限（API 23 起 50MB）。
- 监听 `0.0.0.0:8080`（端口参数化，默认 8080）；控制台打印每个请求实收 method/path/Range/Cookie/Accept-Encoding（主机侧第二证据）。
- http-server 备选源（手册指引）：`fsutil file createnew big.bin 4194304` + `npx http-server -a 0.0.0.0 -p 8080`（http-server 支持 Range，Python SimpleHTTPServer 不支持——MIGRATION_PLAN §7 Phase 2 注记同源）。**http-server 无 echo/redirect/final 路由**：仅覆盖 S1/S2/S4，S3/S5 必须用 echo 服务（手册明示）。

### 2.3 ProbeHttpLogic.ets 数据模型（可序列化，TaskPool 边界安全）

| 类型 | 字段 | 用途 / 源码对照 |
|---|---|---|
| `interface RangeWindow` | `start: number; end: number` | S4 分窗；闭区间语义对齐 `PieceGrabber.cs:391-394` 的 `AddRange(start, end)`（`bytes=start-end`） |
| `interface ContentRangeParts` | `start/end/total: number`（解析失败 -1） | 对应 `DotNetHttpSession.GetTotalLengthFromContentRange()`（ContentRange.Length，`DotNetHttpSession.cs:96-99`） |
| `interface EchoFields` | `url/cookie/acceptEncoding: string` | /final、/echo 回显体解析产物（S3/S5 观测源） |
| `interface SegmentResult` | `index/status/bytes/durationMs/errCode: number` | S4 单分段结果；以 **JSON 字符串**过 TaskPool 边界（taskpool 返回值序列化丢原型，字符串最稳，主线程 `JSON.parse(...) as SegmentResult`） |

常量：`BIG_BIN_BYTES=4194304`、`PROBE_TIMEOUT_MS=3000`（§0-2）、`UNREACHABLE_URL='http://192.0.2.1:8080/big.bin'`（RFC 5737 TEST-NET-1 保留段，预期不可路由）、`ECHO_COOKIE='XDMProbeCookie=1'`（值字符全在探针值白名单内）。

### 2.4 观测键 ↔ 源码语义映射（EXPECT 判定式的数学依据）

| 观测键 | 步骤 | 源码对应（本会话逐条核实行号） | 说明 |
|---|---|---|---|
| `chunks/totalBytes/firstChunkBytes/streamClosed/writtenBytes` | S1 | 原版 `WinHttpResponseStream.cs:35-59` 阻塞 `Stream.Read` 循环（0 字节=流结束）→ 鸿蒙 `requestInStream` 的 `dataReceive`/`dataEnd` 事件流（MIGRATION_PLAN 决策 2 指定的替代机制；`@ohos.net.http.d.ts:2222/:2361/:2411`） | `writtenBytes` 为 writeSync 返回值累计；verify 比对 totalBytes==writtenBytes==4194304（探针不输出 match 词） |
| `requestRange/status/contentLength/contentRangeTotal/rangeSupported` | S2 | 首请求 `AddRange(0)`=`RangeHeaderValue(0,null)`=`'bytes=0-'`（`PieceGrabber.cs:387-395`）；206 判定 `http.ResponseCode.PARTIAL`（d.ts:2881，枚举值 206）；ContentLength 取值链 Content-Length→ContentRange.Length→-1（`DotNetHttpSession.cs:32`） | `rangeSupported` =（status==206）的布尔编码，是**服务端能力观测**（PROBE_SPEC §2 示例行同键），非 PASS/FAIL 词；Resumable 推导（`PieceGrabber.cs:442-452`）留引擎 U2.1，verify 按 EXPECT 复算 |
| `sent/serverEcho/contentLengthMatches` | S3 | 默认头 `Accept-Encoding: identity`（`SingleSourceHTTPDownloader.cs:519-530`）；`Utils.cs:9-18` `IsCompressed` = ContentEncoding/TransferEncoding 含 gzip\|deflate | `contentLengthMatches` =（响应 Content-Length 头 == 体字节数）编码；identity 未被压缩协商 = 引擎 resumable 前提（决策 3） |
| `concurrent/all206/minDurationMs/maxDurationMs/totalBytes/firstErrCode` | S4 | `Config.cs:122` MaxSegments=8（8 分段并发）；官方 FAQ faqs-network-28（http 并发数量无限制） | `all206` = 8 个 SegmentResult 全为 206 的编码；TaskPool 内 http 可用性 = 风险#4 观测本体 |
| `requestUrl/status/redirectFollowed/finalUrl/cookieSeen/cookieSent` | S5 | `FinalUri = redirectUri ?? response.ResponseUri`（`PieceGrabber.cs:442-452`）；Cookie 原始串注入 `SetHeader(http,"Cookie",cookies)`（`DotNetHttpClient.cs:84-87`） | http 模块 HttpResponse 无最终 URL 字段（本机 d.ts:3607-3760 仅 result/resultType/responseCode/header/cookies/performanceTiming）→ finalUrl 用 /final 路由回显的服务端实收 URL；`redirectFollowed` =（finalUrl 以 '/final' 结尾）编码；`cookieSent` =（cookieSeen 含 ECHO_COOKIE）编码 |
| `timeoutSetMs/timedOut/errCode/elapsedMs` | S6 | `Config.cs:120` NetworkTimeout=30 → `SingleSourceHTTPDownloader.cs:101`；错误码 = 2300000+curl 码：2300007 connect 失败、2300028 超时、2300047 重定向超上限（本机 d.ts:1102-1112，grep 核实） | `timedOut` =（errCode==2300028）编码（`isTimeoutCode`）；elapsedMs 为 Date.now 差值佐证 |

**红线重申（硬要求②）**：上述布尔键（rangeSupported/all206/contentLengthMatches/redirectFollowed/cookieSent/timedOut/streamClosed）全部是"对直接观测值的谓词映射"（服务端行为/平台返回码），不是探针对自身的 PASS/FAIL 判定；期望不写进探针代码，判定全部在 EXPECT 表（PROBE_SPEC §1）。`errMessage` 含白名单外字符时被 ProbeKit 消毒为 `?` 串（U0.1 R1-F1 挂起的白名单补 `'?'` 事项不影响 FORMAT 正则，主流程后置）。

## 3. 关键算法与线程模型翻译说明

### 3.1 纯函数（ProbeHttpLogic.ets——无 IO、入参出参可序列化，Hypium 可测）

1. `headerOf(headers: Record<string, string>, name: string): string` —— 大小写不敏感头查找：`Object.keys(headers)` 遍历（**ArkTS 禁 for...in**），`key.toLowerCase() === name` 命中返回值，否则 `''`。headers 由 `resp.header as Record<string, string>` 获得（http 的 `header` 类型为 Object，d.ts:267）；若 as-cast 过不了 hvigor 门禁，备选 `JSON.parse(JSON.stringify(resp.header)) as Record<string, string>`（两式均注明，编码员择一实编）。
2. `parseContentRange(value: string): ContentRangeParts` —— `'bytes 0-4194303/4194304'` → `{0,4194303,4194304}`；`'bytes */N'` → `{-1,-1,N}`；无 '/' 或非数字 → `{-1,-1,-1}`。
3. `splitRangeWindows(total: number, parts: number): RangeWindow[]` —— `win = Math.floor(total/parts)`（win<1 返回 `[]`）；第 i 窗 `start = i*win`、`end = (i===parts-1) ? total-1 : (i+1)*win-1`。4194304/8 → 8 窗 ×524288（`{0,524287}…{3670016,4194303}`），闭区间与原版 `AddRange(start,end)` 一致。
4. `parseEchoBody(body: string): EchoFields` —— 按空格切 token；每 token 以**首个** `'='` 分 key/value（value 可含 `'='`：`cookie=XDMProbeCookie=1`）；缺失 token 取 `''`。
5. `isTimeoutCode(code: number): boolean` —— `code === 2300028`（S6 timedOut 编码唯一谓词）。

### 3.2 requestInStream 时序门（S1/S4 正确性关键）

本机 d.ts 对 `requestInStream` 的 `Promise<number>` resolve 时点相对 `dataEnd` 无明文（d.ts:2180-2223 只写"返回 ResponseCode"）。设计按**防御式双等**：先 `await requestInStream(url, options)` 取状态码，再 `await streamDone`（dataEnd 回调 resolve 的 Promise）之后才 emit `streamClosed`——promise 先于/后于 dataEnd 两种真实时序都被覆盖；reject 路径走 catch（观测 `streamClosed=false` + errCode）。dataReceive 回调内只做计数与 writeSync，不做 emit（emit 统一在 await 完成后过会话守卫）。

### 3.3 线程模型映射（对照 MIGRATION_PLAN 决策 2）

| 步骤 | 线程模型 | 说明 |
|---|---|---|
| S1/S2/S3/S5/S6 | 主线程 + async/await | dataReceive/dataEnd/headersReceive 回调在调用线程事件循环投递；S1 每块 `fileIo.writeSync` 同步追加（openSync(READ_WRITE\|CREATE\|TRUNC) 一次，顺序写推进 fd 偏移）。4MiB/≈64 块同步写为探针规模可接受；引擎 U2.x 按"SegmentWorker 走 TaskPool + pieces 主线程单点管理"移出主线程 |
| S4 | TaskPool ×8 | 顶层 `@Concurrent async function fetchSegment(index, url, start, end): Promise<string>`（**模块级声明，禁闭包捕获外部对象**——http 从模块 import 在 worker 侧可用，这正是风险#4 的观测本体）。主线程 `taskpool.execute(fetchSegment, index, url, start, end)` ×8 → `Promise.all` → 每个返回值 `as string` → `JSON.parse as SegmentResult` 聚合。**worker 内禁调 ProbeKit/hilog 探针出口（单例不可跨线程共享），结果统一回主线程 emit**。8 个 execute 任务与引擎 U2.1 的"每分段一个 TaskPool 任务"同构 |
| 会话守卫 | 跨 await/跨线程 | 见 §3.5；worker 返回后主线程复检 isCurrent 再聚合 emit |

`taskpool` 从 `@kit.ArkTS` 导入、`http` 从 `@kit.NetworkKit` 导入（本会话 grep 两 kit 导出表核实）。

### 3.4 头注入与 echo 解析

- S2/S3/S5 按当步最小头注入：`const h: Record<string, string> = {}; h['Range'] = 'bytes=0-';` → `options.header = h`（Record 具型字面量赋给 `header?: Object`，规避 ArkTS 对裸对象字面量的限制）。Cookie 原始串注入同语义于 `DotNetHttpClient.cs:84-87`；鸿蒙 options.header 注入无校验环节，无需复刻 `TryAddWithoutValidation` 与"跳过 Content-Type"（后者对应带 body 的 POST 场景，探针无 POST）。
- S5 回显体经 `parseEchoBody` 解析后 emit。**不做跨主机重定向 Cookie 测试**：官方文档明示手动 Cookie 头不跨主机转发，双域名测试源成本高——留 U1.2 公网实测（研究结论 openQuestion#2 采纳）；本期 cookieSent 语义 = 同主机 302 后服务端是否实收 Cookie 头。
- 本机 SDK `@ohos.net.http.d.ts` **无 enableAutoCookie**（grep 计数 = 0，官方文档标起始版本 26.0.0 > 24，禁用）——Cookie 转发行为只能观测不能配置，写入 EXPECT note。

### 3.5 会话代际守卫（硬要求①，IR-F5 落地，开工先做）

- ProbeKit 新增 `isCurrent(runId: string): boolean` = `this.started && this.runId === runId`。begin() 无条件重置语义**保留**（重跑本就是新会话）。
- ProbePage.startSession（runSingle 同构）改写：begin 后 `const runId = this.probeKit.getRunId();`；**五守卫点**：① 循环每轮开头 ② `await this.runStep(stepNo)` 返回后 ③ catch 分支 emit 前 ④ 循环结束 end 前 ⑤ runSingle 对应位置；任一点 `!isCurrent(runId)` → 置 `this.sessionRunning = false` 后**静默 return**（不发标记行、不调 end、不写状态）——旧会话作废，新会话由新循环完整接管（BEGIN/END 配对不被旧循环打断）。
- ProbeHttp 每个 runner 入口再捕获一次 runId；runner 内**每个 await 之后、emit 之前**复检 `isCurrent`——双保险覆盖"暖启动重建页面 → 新 begin → 旧异步步骤恢复"串话场景（S4 的 Promise.all 聚合 emit 前同样复检）。
- IR-F4 同批落位：emit 空 kvs → 内部补 `[new KeyValue('kvs','0')]`（产出 `[Sx] kvs=0`，verify 正则 `\s(.+)` 合法）；end 零 summaries → SUMMARY 段补 `'kvs=0'`。
- IR-F1 同批落位：`copyLog` 改 `pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.logText)`（本 SDK 重载 @since 24，U0.1 报告 ⑦-1 建议原文）。
- IR-F2 同批落位：删除 ProbeKit `lastLine` 字段（:58）与赋值（:162），零读取点（U0.1 报告 grep 佐证）。
- 守卫对 P0-U0 回归零影响：同步步骤中 getRunId 全程不变，守卫点全部空转。

## 4. 有意差异清单（对照源码/计划）

1. **探针不注入六键默认头全集**：原版每请求默认头 User-Agent(Chrome/97)/Accept/Accept-Encoding/Accept-Language/Accept-Charset/Referer（`SingleSourceHTTPDownloader.cs:519-530`、`Config.cs:52`）在探针**不做默认注入**，各步只注入当步观测所需最小头（S2 仅 Range、S3 仅 Accept-Encoding、S5 仅 Cookie）——单步单变量的观察隔离；六键逐键复刻是 U1.2 `core/net/HttpClient.ets` 的任务（研究结论同口径，本单元只验 identity 一键）。
2. **AutomaticDecompression=All 无对应物且反向验证**（`DotNetHttpClient.cs:50-57`）：鸿蒙 http 无自动解压开关位；探针以显式 `identity` 关闭协商（S3 观测点），对等引擎"强制 identity"语义（决策 3）。http 模块自身是否额外注入 Accept-Encoding 由 S1/S3 的服务端回显顺带观测（观测点非预设）。
3. **MaxConnectionsPerServer=100 不复刻**（`DotNetHttpClient.cs:56`）：鸿蒙无对应配置；并发上限由引擎 MaxSegments=8 封顶（`Config.cs:122`），S4 即按 8 分窗实测。
4. **TLS 全放行 / PreAuthenticate / UseDefaultCredentials / NTLM / 自动代理不迁移**：MIGRATION_PLAN §3 降级清单 #2/#3/#8 既有结论，探针不涉及。
5. **finalUrl 取服务端回显而非栈字段**：原版 `FinalUri = redirectUri ?? ResponseUri`（`PieceGrabber.cs:442-452`）→ http 模块 HttpResponse 无最终 URL 字段，以 /final 回显等价观测；rcp 侧 `Response.effectiveUrl`（rcp d.ts:2806，@since 20）可直取——该差异列入选型结论补偿点（§8-C）。
6. **S6 用 3000ms 短超时而非产品 30s**（§0-2）：同一参数位（connectTimeout/readTimeout），避免单步 30s 阻塞；产品值 U1.2 固化 30000ms。
7. **S6 用 RFC 5737 TEST-NET-1（192.0.2.1）不可达地址**：不依赖测试源；"静默丢包→2300028 / RST 拒绝→2300007"的环境分叉按 EXPECT 接受域处理（主判 2300028，2300007 记 UNVERIFIED + 手册重跑指引——研究结论 openQuestion#1 采纳）。
8. **S5 仅同主机 302**（§3.4）：跨主机 Cookie 转发留 U1.2。
9. **MIGRATION_PLAN / RISK_ASSESSMENT / PROBE_SPEC 三份根文档后置改写**（§0-1/§0-3）：回写由报告员在 verify 判定后按 §8 模板执行，不属本单元 files。
10. **U0.1 遗留四项搭车闭环**（IR-F1/F2/F4/F5，均在触碰文件内）；U0.1 设计书三处笔误（R1-F3/R1-F4/IR-F6）不属本单元目标文件，不搭车，留主流程。

## 5. 各文件实现要点（可直接照做的接口面）

### 5.1 ProbeKit.ets（改）

```typescript
// 新增：
isCurrent(runId: string): boolean   // return this.started && this.runId === runId
// emit：kvs.length === 0 时以 [new KeyValue('kvs','0')] 替代（IR-F4）
// end：this.summaries.length === 0 时 SUMMARY 段用 'kvs=0'（IR-F4）
// 删除 private lastLine 及其赋值（IR-F2）
// 其余 begin/emit/end/消毒/兜底写盘一行不动（P0-U0 行为回归零影响）
```

### 5.2 ProbePage.ets（改）

- startSession/runSingle 按 §3.5 五守卫点改写（其余编排、UI、copyLog 时序不变）。
- copyLog：`const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.logText);`（IR-F1，替换 createPlainTextData）。

### 5.3 ProbeHttpLogic.ets（新，全量签名）

```typescript
// 零 @kit import（本地单测环境可 import；业务 import 该文件无运行时副作用）
export const BIG_BIN_BYTES: number = 4194304;
export const PROBE_TIMEOUT_MS: number = 3000;
export const UNREACHABLE_URL: string = 'http://192.0.2.1:8080/big.bin';
export const ECHO_COOKIE: string = 'XDMProbeCookie=1';
export interface RangeWindow { start: number; end: number }
export interface ContentRangeParts { start: number; end: number; total: number }
export interface EchoFields { url: string; cookie: string; acceptEncoding: string }
export interface SegmentResult { index: number; status: number; bytes: number; durationMs: number; errCode: number }
export function headerOf(headers: Record<string, string>, name: string): string
export function parseContentRange(value: string): ContentRangeParts
export function splitRangeWindows(total: number, parts: number): RangeWindow[]
export function parseEchoBody(body: string): EchoFields
export function isTimeoutCode(code: number): boolean
```

### 5.4 ProbeHttp.ets（新）

```typescript
import { http } from '@kit.NetworkKit';
import { taskpool } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ProbeKit, KeyValue } from '../core/ProbeKit';
import { ProbePage, ProbeStepDef } from '../core/ProbePage';
import { BIG_BIN_BYTES, PROBE_TIMEOUT_MS, UNREACHABLE_URL, ECHO_COOKIE,
  RangeWindow, SegmentResult, headerOf, parseContentRange, splitRangeWindows,
  parseEchoBody, isTimeoutCode } from './ProbeHttpLogic';

const DEFAULT_BASE_URL: string = 'http://192.168.1.20:8080';   // 手册可替换参数的缺省值
const HTTP_STEPS: ProbeStepDef[] = [
  { stepNo: 'S1', title: '流式落盘（requestInStream）', autoRun: true },
  { stepNo: 'S2', title: 'Range 0- → 206 判定', autoRun: true },
  { stepNo: 'S3', title: 'identity 编码回显', autoRun: true },
  { stepNo: 'S4', title: 'TaskPool 内 8 并发', autoRun: true },
  { stepNo: 'S5', title: '重定向跟随 + Cookie 注入', autoRun: true },
  { stepNo: 'S6', title: '超时控制与错误码', autoRun: true }
];

@Concurrent
async function fetchSegment(index: number, url: string, start: number, end: number): Promise<string> {
  // createHttp → on('dataReceive') 累计 bytes →
  // await requestInStream(url, { header:{'Range': 'bytes=<start>-<end>'}, connectTimeout: 10000, readTimeout: 10000 })
  // → await dataEnd 门 → SegmentResult{index,status,bytes,durationMs,errCode:0} → JSON.stringify 返回
  // catch BusinessError → SegmentResult{status:0,bytes:0,errCode:code} → JSON.stringify → finally off×3 + destroy
}

@Component
export struct ProbeHttp {
  @State baseUrl: string = DEFAULT_BASE_URL;
  private async runStep(stepNo: string): Promise<void> { /* S1~S6 分派；入口捕获 runId，每个 await 后 isCurrent 复检，emit 前终检 */ }
  build() {
    Column({ space: 12 }) {
      TextInput({ text: this.baseUrl, placeholder: $r('app.string.probe_http_source_hint') })
        .onChange((v: string) => { this.baseUrl = v; })
        .width('100%')
      ProbePage({ unitId: 'P0-U2', pageTitle: $r('app.string.probe_http_title'),
        steps: HTTP_STEPS, autoStart: false,   // 关键：等用户改完 URL 再点"运行全部"
        runStep: (stepNo: string): Promise<void> => this.runStep(stepNo) })
        .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
  }
}
```

各 runner 骨架（键集与 §6 一致，catch 一律 emit errCode/errMessage 键组不外抛）：

- **runS1**：`openSync('<filesDir>/probe-http-s1.bin', READ_WRITE|CREATE|TRUNC)` → on('dataReceive')：chunks++、totalBytes+=byteLength、首块记 firstChunkBytes、`writeSync(fd, chunk)` 累计 writtenBytes → on('dataEnd')：streamClosed=true + streamDone resolve → on('headersReceive')：`JSON.stringify(header)` 写 `probe-P0-U2-<runId>-s1-headers.txt` → `await requestInStream(url)` → `await streamDone` → emit(url,status,chunks,totalBytes,firstChunkBytes,writtenBytes,streamClosed,detailFile) → **finally**：off('dataReceive'/'dataEnd'/'headersReceive') + closeSync(fd) + destroy()（官方要求防泄漏）。
- **runS2**：`request(url, {header:{'Range':'bytes=0-'}})` → `resp.header as Record<string,string>` → headerOf('content-length'/'content-range') → parseContentRange → emit(url,requestRange='bytes=0-',status=String(resp.responseCode),contentLength,contentRangeTotal,rangeSupported=(resp.responseCode===http.ResponseCode.PARTIAL))。
- **runS3**：`request('<base>/echo', {header:{'Accept-Encoding':'identity'}})` → `parseEchoBody(resp.result as string)` → contentLengthMatches=(Number(headerOf('content-length')) === (resp.result as string).length) → emit(sent='identity',serverEcho,contentLengthMatches)。
- **runS4**：`splitRangeWindows(BIG_BIN_BYTES, 8)` → 8×`taskpool.execute(fetchSegment, i, url, w.start, w.end)` → `Promise.all` → 逐个 `as string` → `JSON.parse as SegmentResult` → 聚合 all206/min/max/totalBytes/firstErrCode → emit(concurrent='8',all206,minDurationMs,maxDurationMs,totalBytes,firstErrCode)。
- **runS5**：`request('<base>/redirect', {header:{'Cookie':ECHO_COOKIE}})` → parseEchoBody → redirectFollowed=(fields.url 以 '/final' 结尾)、cookieSent=(fields.cookie.indexOf(ECHO_COOKIE)>=0) → emit(requestUrl,status,redirectFollowed,finalUrl=fields.url,cookieSeen=fields.cookie,cookieSent)。
- **runS6**：`requestInStream(UNREACHABLE_URL, {connectTimeout:PROBE_TIMEOUT_MS, readTimeout:PROBE_TIMEOUT_MS})` → 成功态 emit(timeoutSetMs,timedOut='false',errCode='0',status)；catch(BusinessError) → emit(timeoutSetMs,timedOut=isTimeoutCode(code),errCode=String(code),elapsedMs)。

### 5.5 ProbeIndex.ets（改）

- `PROBE_UNITS` 追加 `{ unitId: 'P0-U2', title: $r('app.string.probe_http_title') }`；`import { ProbeHttp } from './units/ProbeHttp'`。
- 详情分支重构：else 公共头（返回按钮+标题行）+ `Column { if (selectedUnitId==='P0-U0') { ProbeEnv() } else if (selectedUnitId==='P0-U2') { ProbeHttp() } }`——避免逐分支复制头部行（ArkUI if/else 允许嵌套）。

### 5.6 string.json（改，追加两键）

| 键 | 值（base，默认中文） |
|---|---|
| `probe_http_title` | `HTTP 能力探针（P0-U2）` |
| `probe_http_source_hint` | `测试源地址（主机局域网 IP，如 http://192.168.1.20:8080）` |

### 5.7 本地单测（entry/src/test/，新目录）

- `List.test.ets`：`import probeHttpLogicTest from './ProbeHttpLogic.test'; export default function testsuite(): void { probeHttpLogicTest(); }`
- `ProbeHttpLogic.test.ets`：`import { describe, it, expect } from '@ohos.hypium';` + `import { ... } from '../../main/ets/probe/units/ProbeHttpLogic';`；用例清单见 §7-[A]-3。hypium 依赖已在 `oh-package.json5:7`（devDependencies `@ohos/hypium 1.0.25`，本会话核实）。

### 5.8 echo server（docs/probe/P0-U2-echo-server.js）

Node http 模块单文件 ≈80 行：`listen(0.0.0.0, process.argv[2] || 8080)`；按 §2.2 路由表实现；Range 解析用 `new RegExp('^bytes=(\\d+)-(\\d*)$')`；64KB 块字节生成器（块序 k 填充 `k % 251`）；`/redirect` 的 Location 用 `req.headers.host` 重组绝对地址；控制台打印实收头。JS 侧无 ArkTS 约束，仍统一 `new RegExp` 风格保持工程一致性。

## 6. 探针步骤设计（P0-U2）

拉起/抓取/兜底命令沿用 U0.1 手册口径（`hdc shell "aa start -b com.example.xdmharmony -a EntryAbility --ps page probe"` 带引号形式）。**`<base>` = 探针页 TextInput 值 = 手册可替换参数**；示例取 `http://192.168.1.20:8080`。所有行 hilog：domain 0xD001、tag XDM_PROBE、`%{public}s`。

| 步骤 | 操作 | 观测点（emit 键） | 标记行示例 |
|---|---|---|---|
| BEGIN | 脚手架编排（autoStart=false，用户改完 URL 点"运行全部"后 begin） | runId、filesDir | `[XDM_PROBE][P0-U2][BEGIN] runId=142533 filesDir=/data/app/el2/100/base/com.example.xdmharmony/haps/entry/files` |
| S1 流式落盘 | `requestInStream(<base>/big.bin)`；dataReceive 逐块计数+writeSync 落盘 probe-http-s1.bin；dataEnd 门；响应头全量写 detail 文件 | url、status、chunks、totalBytes、firstChunkBytes、writtenBytes、streamClosed、detailFile | `[XDM_PROBE][P0-U2][S1] url=http://192.168.1.20:8080/big.bin status=200 chunks=64 totalBytes=4194304 firstChunkBytes=65536 writtenBytes=4194304 streamClosed=true detailFile=probe-P0-U2-142533-s1-headers.txt` |
| S2 Range 206 | `request(<base>/big.bin, header Range: bytes=0-)`；单调用取码+头（4MiB 体随请求回收，不逐块处理） | url、requestRange、status、contentLength、contentRangeTotal、rangeSupported | `[XDM_PROBE][P0-U2][S2] url=http://192.168.1.20:8080/big.bin requestRange=bytes=0- status=206 contentLength=4194304 contentRangeTotal=4194304 rangeSupported=true` |
| S3 identity 回显 | `request(<base>/echo, header Accept-Encoding: identity)`；echo 服务回显实收头 | sent、serverEcho、contentLengthMatches | `[XDM_PROBE][P0-U2][S3] sent=identity serverEcho=identity contentLengthMatches=true` |
| S4 TaskPool 8 并发 | splitRangeWindows(4194304,8) → 8×`taskpool.execute(fetchSegment,…)`（各 Range 窗 524288B，对齐引擎 8 分段语义）→ Promise.all 聚合 | concurrent、all206、minDurationMs、maxDurationMs、totalBytes、firstErrCode | `[XDM_PROBE][P0-U2][S4] concurrent=8 all206=true minDurationMs=95 maxDurationMs=412 totalBytes=4194304 firstErrCode=0` |
| S5 重定向+Cookie | `request(<base>/redirect, header Cookie: XDMProbeCookie=1)`；302（绝对 Location）→ /final 回显实收 URL 与 Cookie | requestUrl、status、redirectFollowed、finalUrl、cookieSeen、cookieSent | `[XDM_PROBE][P0-U2][S5] requestUrl=http://192.168.1.20:8080/redirect status=200 redirectFollowed=true finalUrl=http://192.168.1.20:8080/final cookieSeen=XDMProbeCookie=1 cookieSent=true` |
| S6 超时错误码 | `requestInStream(UNREACHABLE_URL=192.0.2.1, connectTimeout/readTimeout=3000)` | timeoutSetMs、timedOut、errCode、elapsedMs | `[XDM_PROBE][P0-U2][S6] timeoutSetMs=3000 timedOut=true errCode=2300028 elapsedMs=3012` |
| SUMMARY | end(ok) 聚合（段间 \|、段内 ,，值内 \| 已替换 /） | 全段 | `[XDM_PROBE][P0-U2][SUMMARY] S1=url=http://192.168.1.20:8080/big.bin,status=200,chunks=64\|S2=status=206,contentRangeTotal=4194304\|S3=serverEcho=identity\|S4=all206=true\|S5=redirectFollowed=true\|S6=timedOut=true` |
| END | ok=本次会话无脚手架级异常；steps=6；elapsedMs | ok、steps、elapsedMs | `[XDM_PROBE][P0-U2][END] ok=true steps=6 elapsedMs=6500` |

失败路径：任一步 `catch(BusinessError)` → 该步行输出 `errCode/errMessage` 键组（替代正常键集，每步骤仍恰一行）；ok 不因步骤级失败置 false（runner 契约同 U0.1）。守卫中止路径（§3.5）：旧循环静默退出，**不产生任何标记行**（包括 err 行）。

## 7. 单元验收测试要点

### [A] 静态门禁（编码员每轮自跑）

1. **hvigor 全量构建**：`devecocli build --modules entry`（或等价 hvigor）零 error 零新 warning（U0.1 基线 BUILD SUCCESSFUL，唯一 WARN 为模拟器免签名 No signingConfigs）。ArkTS 严格子集自查点：`@Concurrent` 顶层函数无闭包捕获；Record 具型字面量/下标访问；`JSON.parse(...) as Interface`；async 方法显式 `Promise<void>`/`Promise<string>`；TextInput onChange 箭头参数 `(v: string)`；`Object.keys` 替代 for...in；无 any/解构/正则字面量/构造器参数属性。
2. **结构断言**：`grep -n "import" entry/src/main/ets/pages/Index.ets` 仍零行；ProbeHttp/ProbeHttpLogic 未列入 main_pages.json；`grep -rn "@Entry" entry/src/main/ets` 恰 2 处不变；ProbeKit 除 §5.1 四处 diff 外无其他改动；`grep -rn "PASS\|FAIL" entry/src/main/ets/probe` 零命中（红线②）。
3. **Hypium 本地用例清单**（entry/src/test/）：
   - `splitRangeWindows`：①(4194304,8) → 8 窗各 524288，首窗 {0,524287}、末窗 {3670016,4194303}；②(10,3) → {0,2}{3,5}{6,9}（末窗吸收余数）；③(100,1) → {0,99}；④(4,8) → 空数组（win<1 守卫）。
   - `parseContentRange`：①'bytes 0-4194303/4194304' → {0,4194303,4194304}；②'bytes */123' → {-1,-1,123}；③'bytes 0-'（缺 /）→ {-1,-1,-1}；④'garbage' → {-1,-1,-1}。
   - `parseEchoBody`：①'url=http://h/final cookie=XDMProbeCookie=1 acceptEncoding=identity' → 三字段正确（value 含 '=' 不截断）；②'acceptEncoding=identity' → url/cookie 为 ''；③'' → 全空。
   - `headerOf`：①小写键命中；②原样大小写 'Content-Range' 命中 name='content-range'；③无命中 ''。
   - `isTimeoutCode`：①2300028 → true；②2300007 → false。
   - 执行说明（诚实注记）：工程模板未携带 `entry/src/test/` 目录、devecocli 无 test 子命令（本会话 `devecocli --help` 核实，命令面只有 build/run/device/emulator/auth/skills/log/create/init/serve/docs/ui/check/signature），hvigor wrapper 亦不在工程内（`hvigor/` 仅 hvigor-config.json5）——**本地单测的执行命令在本设计会话无法验证**。用例文件照常交付（assembleHap 不编译 src/test，不影响编译门禁）；编码员须在 IDE/hvigor 侧实跑一次并记录，若 LocalUnit 任务在本机 SDK 6.1.1 不可用，在单元报告注明"用例已入库待 U2.3 统一回归"，不阻塞本单元。

### [P] 运行时（手册承载，xdm-probe-verify 机械判定）

4. **起源（主机侧）**：`node docs/probe/P0-U2-echo-server.js 8080`；主机自检 `curl http://<LAN_IP>:8080/echo` 应回 `acceptEncoding=...`；Windows 防火墙首启弹窗勾选允许。备选：`fsutil file createnew big.bin 4194304 && npx http-server -a 0.0.0.0 -p 8080`（仅覆盖 S1/S2/S4）。
5. **设备侧**：设备与主机同一局域网；探针页改 `<base>` 为主机局域网 IP → 运行全部 → 九行序列（BEGIN+S1~S6+SUMMARY+END）齐全且逐行命中 FORMAT 正则 `^\[XDM_PROBE\]\[([A-Z0-9-]+)\]\[([A-Za-z0-9-]+)\]\s(.+)$`；交叉核对 `hdc shell "ls -l <filesDir>/probe-http-s1.bin"` 应为 4194304 字节；`cat <filesDir>/probe-P0-U2-<runId>-s1-headers.txt` 存在。
6. **环境差异分支**：S6 观测 `errCode=2300007`（RST 环境）→ 判 UNVERIFIED，按手册"换不可达地址（如 198.51.100.1 TEST-NET-2）/检查防火墙/关代理"重跑；S4 `all206=true` 为主判，8 个 errCode 全非零 → 风险#4 实证，走 §8-分支 B 回写（**非 probe-code 返修**）。
7. **会话守卫冒烟（硬要求①的运行时验证）**：S4 运行中按 HOME 退后台 → `aa start --ps page probe` 暖启动重进 P0-U2 → 立即"运行全部" → 新会话九行完整、runId 单调配对、**无旧步骤标记行串入、无孤儿 END**；hilog 中旧会话无残余行。
8. **`xdm-probe-verify`**：回贴 `probe-P0-U2.log` 全文 + EXPECT-u0-2-http-capability-probe.json，逐步骤 PASS/FAIL/UNVERIFIED/MISSING 判定并分流；判定后按 §8 模板回写计划。

## 8. 栈选型结论回写模板（xdm-probe-verify 判定后由报告员执行）

| 判定分支 | MIGRATION_PLAN §6 决策 9（追加/改写文本） | RISK_ASSESSMENT 回写 |
|---|---|---|
| **A 六步全绿** | 追加："**P0-U2 已实测（环境=<模拟器/真机>，日期）**：requestInStream 流式落盘、Range 0-→206、identity 头透传、TaskPool 内 8 并发、重定向跟随+Cookie 注入、超时错误码 2300028 全部通过——主栈定为 @ohos.net.http；rcp 不启用（effectiveUrl/超时三分型优势不抵无分块流回调缺口；S5 finalUrl 以服务端回显补偿）" | #2 → 已消除（P0-U2 全绿）；#4 → 已消除（TaskPool 内 http 实测可用，S4 all206=true） |
| **B 仅 S4 FAIL**（S1/S2/S6 PASS） | 保留 http 主栈，追加："S4 实证风险#4：TaskPool 内 http 不可用（errCode 见 EXPECT-P0-U2）——U2.1 按退化路径全主线程事件驱动实现（并发请求天然并行，分段不依赖线程）" | #4 → 已实证，退化路径激活 |
| **C S1/S2/S6 任一 FAIL** | 决策 9 改写：主栈切 rcp——补偿点：`Response.effectiveUrl` 直取（替代 finalUrl 回写）、`Request.transferRange`（替代手写 Range 头）、`Timeout{connectMs,transferMs,inactivityMs}` 三分型（inactivity 为原版没有的增益）、`downloadToFile` 落盘（**无分块流回调** → 进度粒度降为文件级/定期轮询文件长度，决策 2 的事件流语义降级） | #2 → 触发切换条款 |
| **D 仅 S3 FAIL**（serverEcho≠identity） | 追加："http 栈改写/剥离 Accept-Encoding——U1.2 不可依赖 identity 头；补偿=按响应 Content-Encoding 判 Compressed（对等原版 Utils.IsCompressed），compressed 响应按不可续传处理（对等原版 Resumable=!Compressed&&206）" | #2 → 部分失败注记 |
| **E 仅 S5 异常** | `redirectFollowed=false` → U1.2 显式设置 `maxRedirects`（d.ts:592，@since 23）；`cookieSeen=absent` → 记录平台"手动 Cookie 不随重定向转发"语义，U1.2 按原版语义**每请求从 Cookie 存储重注**（`DotNetHttpClient.cs:84-87` 同构，不依赖栈自动转发）——均不需换栈 | 无需改 |

## 9. 风险与备注

| 风险 | 缓解 |
|---|---|
| TaskPool 内 http 不可用（风险#4 本体） | S4 即为其探针；SegmentResult.errCode 全量回传观测；退化路径 §8-B 预登记 |
| requestInStream promise 与 dataEnd 时序无明文 | §3.2 防御式双等（await promise → await dataEnd 门） |
| 2300007/2300028 环境分叉（NAT 静默丢包 vs RST） | EXPECT 接受域 + 手册"换地址/防火墙"重跑指引（§6-S6、§7-6） |
| 模拟器/真机内 127.0.0.1 回环误解 | 手册强调主机局域网 IP + echo 服务绑 0.0.0.0；UNREACHABLE_URL 用 RFC 5737 保留段 |
| 真异步首现的会话串话（IR-F5 变活） | §3.5 三层守卫（ProbeKit.isCurrent + ProbePage 五守卫点 + runner 内复检）+ §7-7 冒烟 |
| http-server 备选源无 echo/redirect 路由 | 手册标注：http-server 仅覆盖 S1/S2/S4，S3/S5 必须回显服务（S3/S5 记 UNVERIFIED） |
| hvigor 对 `header as Record` / `@Concurrent` 形态报错 | §5.1/§5.4 已注明备选写法（JSON 往返替代 as-cast）；失败即返修不影响设计契约 |
| 本地单测执行环境未验证（§7-3 诚实注记） | 用例文件不影响编译门禁；实跑归编码员，不可用则 U2.3 统一回归 |
| 探针临时文件残留（probe-http-s1.bin 4MiB） | 探针为一次性工具（UNIT_CATALOG 节奏），保留作证据；U7.3 移除 probe/ 时一并清理 |
| 交付带探针发布 | PROBE_SPEC §1 既有约定：交付打包前整体移除 entry/src/main/ets/probe/（U7.3 执行） |
