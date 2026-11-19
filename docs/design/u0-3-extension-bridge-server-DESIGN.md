# U0.3 扩展桥 8597 服务端（回补 Phase 0）· 模块设计书

> 单元：U0.3（Phase 0 第 3 项，回补执行于 U6.1 之前；探针单元 ID `P0-U3`，归 Phase 0 谱系）。
> 依据：MIGRATION_PLAN §6 决策 5（浏览器集成 8597 八路由）、§7 Phase 6 第 1 项；UNIT_CATALOG U0.3 行；PROBE_SPEC v1；单元指令（监听+解析+八路由分发骨架+`/sync` 最小应答+探针 P0-U3 四步骤）；源码研究结论。
> 对照源码（本会话只读核实，未改 resourses/ 下任何文件）：
> `XDM.Core/BrowserMonitoring/IpcHttpMessageProcessor.cs`、`XDM.Core/HttpServer/HttpServer.cs`、`HttpParser.cs`、`LineReader.cs`、`RequestContext.cs`、`XDM.Core/Config.cs`、`XDM.Core/BrowserMonitoring/VideoTracker.cs`、`chrome-extension/connector.js`。
> 路径勘误（研究结论已登记，本会话复核成立）：HttpParser.cs / HttpServer.cs / LineReader.cs / RequestContext.cs 实际位于 `app/XDM/XDM.Core/HttpServer/`（非 BrowserMonitoring/HttpServer/）。
> 本机 API 面（本会话逐条核实 `D:\Tools\DevEco Studio\sdk\default\openharmony\ets\api\@ohos.net.socket.d.ts`、`@ohos.net.connection.d.ts`、`@ohos.util.d.ts`）：见 §3.6。

## 0. 冲突与拍板注记（必读）

1. **异常路径二分（对研究结论建议的修正拍板）**：研究员 arktsMapping 建议"try/catch 显式把处理异常转为 500/404 应答"。本设计**收窄为二分**：①**解析层失败**（状态行 token≤2 / 头行无冒号或冒号在首位 / 头块中途 EOF / Content-Length 非数字）与 **/sync 处理异常**（含 CreateConfigJson 失败——原版 `return null` 后 `UTF8.GetBytes(null)` 依旧异常穿透，`IpcHttpMessageProcessor.cs:280-284,369-373`）→ **断连不回包**（1:1 对齐原版：异常 rethrow 到 `HttpServer.cs:56-63` 每连接 catch → `tcp.Close()`，原版没有 404/500）；②**格式良好但路径未知/未实现** → **404 空体**（单元指令拍板，原版为 throw 断连——显式偏差 D1/D2）。鸿蒙侧"断连不回包"完全可实现（catch 后只 `conn.close()` 不 send），无需注入应答；ArkTS 无线程异常穿透不构成必须转 404/500 的理由。
2. **404 语义的 U6.1 延续**（研究结论 openQuestion#1 采纳）：本单元把八路径精确匹配与 404 兜底骨架立为桥协议规格；U6.1 补全业务路由时沿用"未知路径 404"语义并写入桥协议规格书（扩展 connector.js 只请求八条已知路径，`chrome-extension/connector.js:4,25,45`，无兼容风险）。
3. **端口占用静默回退**（openQuestion#2 采纳研究建议）：鸿蒙 `listen()` 文档明示 bind 失败会由系统随机分配端口（listen 成功≠拿到 8597）——`start()` 后必须 `getLocalAddress()` 校验 `port===8597`；失配仅 hilog + 探针观测（`portMismatch=true`），视为"已运行实例"等价物，**不做 UI 提示**（原版 `MSG_ALREADY_RUNNING` 弹窗的 UI 等价物留 U6.x 拍板，本单元不阻塞）。
4. **module.json5 / main_pages.json 显式不动（有据，非遗漏）**：本单元涉及网络能力，但 `module.json5:14-18` 已含 `ohos.permission.INTERNET`（U0.1 落地，TCPSocketServer 的 listen/getLocalAddress/send 均要求该权限——本会话 d.ts 核实 `@since 10` 起标注），`:7-10` deviceTypes 已含 `"2in1"`；无新增后台/剪贴板/深链能力，故**零权限新增**。`main_pages.json` 只含 `pages/Index` + `probe/ProbeIndex`，探针子页沿用页内条件渲染惯例不注册。编码时若发现权限缺失（异常态）上报主流程，不得擅自改配置。
5. **业务/探针依赖红线**：`BridgeServer`（业务）**禁止 import probe/ 下任何文件、禁止输出含 `[XDM_PROBE]` 子串的日志行**（业务 hilog 用 domain 0x0000 + tag `BridgeServer`）；探针 `ProbeBridge` **允许** import `core/bridge/BridgeProtocol`（探针→业务单向依赖，复用同一份协议常量与纯函数保证观测与实现同源）。
6. **S3 迷你会话口径**：S3 为 `autoRun=false` 手动步骤，主机侧 curl 前后各点一次"执行"，每次产生独立 minisession（BEGIN+S3+END）——EXPECTED 表 note 声明"取主机 curl 执行后的最后一次 S3 行判定计数增长"，verify 按 runId 配对不视为格式错误（ProbePage.runSingle 既有编排，ProbePage.ets:122-172）。
7. **8597 常驻监听与后台任务交互（产线登记，非本单元实现项）**：见 §8.2。U0.3 验收仅在应用前台；退后台 socket 存活性由 U5.1 DATA_TRANSFER 连续任务语义承接（下载活跃期保活），空闲期进程可能被冻结属平台行为，登记为已知约束，不作为 FAIL 依据。
8. **videoList 恒空数组**：U0.3 无 CapturedVideoTracker（U6.2 落地），`/sync` 应答 `videoList: []`——字段与位置保留（字段序契约），元素结构 `{id,text,info,tabId}` 按 `VideoTracker.cs:391-395`（ID/Name/Description/TabId 均 string）预定义 interface 供 U6.1 复用。

## 1. 目标文件清单（按实现顺序）

| # | 文件 | 新/改 | 职责 | 对外导出 | 依赖 |
|---|---|---|---|---|---|
| 1 | `entry/src/main/ets/core/bridge/BridgeProtocol.ets` | 新 | 桥协议**纯逻辑模块**（零 @kit import，Hypium/探针可 import）：常量（端口/主机/八路径/`/sync` 响应头与常量表）+ 4 个 interface + 8 个纯函数（增量头解析、Content-Length、keep-alive、响应拼装、sync JSON 组装、UTF-8 编码） | `BRIDGE_PORT`、`BRIDGE_HOST`、`BRIDGE_FAMILY`、`ROUTE_PATHS`、`SYNC_CONTENT_TYPE`、`SYNC_CACHE_CONTROL`、`SYNC_MEDIA_TYPES`、`SYNC_TABS_WATCHER`、`SYNC_MATCHING_HOSTS`、`BridgeHeaders`、`HeadParseResult`、`BridgeVideoItem`、`SyncFields`、`appendBytes`、`parseHead`、`firstHeader`、`getContentLength`、`isKeepAlive`、`buildResponseBytes`、`buildSyncJson`、`utf8Encode` | 无 |
| 2 | `entry/src/main/ets/core/bridge/BridgeServer.ets` | 新 | 8597 服务端单例：TCPSocketServer 构造/listen/getLocalAddress 端口校验；每连接 ClientSession 累积缓冲泵（增量解析→取体→dispatch→应答→keep-alive 判定）；八路径精确分发骨架（仅 `/sync` 实现业务，其余 404）；连接/请求统计 | `BridgeServer`（单例：`getInstance()`、`start()`、`stop()`、`isStarted()`、`getStats()`）、`BridgeStats`（interface） | #1（及 core/Config） |
| 3 | `entry/src/main/ets/entryability/EntryAbility.ets` | 改 | onCreate 尾部（`ClipboardWatcher.syncFromConfig()` 之后，:107 后）追加 `BridgeServer.getInstance().start().catch(...)` 只加不改；文件头补 U0.3 注记 | —（既有导出不变） | #2 |
| 4 | `entry/src/test/BridgeProtocol.test.ets` | 新 | 协议纯函数 Hypium 本地用例（清单见 §7-[A]-3） | default testsuite 注册函数 | #1 |
| 5 | `entry/src/test/List.test.ets` | 改 | testsuite 追加注册 #4（与 §7 的 ProbeBridgeLogic 用例文件一起，见 #9） | `testsuite` | #4 |
| 6 | `entry/src/main/ets/probe/units/ProbeBridgeLogic.ets` | 新 | 探针专用**客户端**纯函数（零 @kit import）：响应头/体切分、`/sync` 应答体形状观测（jsonValid/字段序） | `SYNC_BODY_MARKER`、`ResponseHeadView`、`SyncBodyView`、`splitResponseHead`、`parseSyncBody` | 无 |
| 7 | `entry/src/main/ets/probe/units/ProbeBridge.ets` | 新 | P0-U3 探针 @Component：ProbePage(autoStart=true) + S1~S4 runner（S3 autoRun=false）；S2/S4 应用内自连客户端（constructTCPSocketInstance + connect/send/on('message')/on('close')）；S2 原始应答 detail 文件落盘 | `ProbeBridge`（struct） | #1 #2 #6 |
| 8 | `entry/src/main/ets/probe/ProbeIndex.ets` | 改 | PROBE_UNITS 追加 `{unitId:'P0-U3', title:$r('app.string.probe_p0u3_title')}`；else-if 分支追加 `ProbeBridge()` | —（@Entry 页） | #7 |
| 9 | `entry/src/test/ProbeBridgeLogic.test.ets` | 新 | 探针纯函数 Hypium 用例（§7-[A]-3 末组） | default testsuite 注册函数 | #6 |
| 10 | `entry/src/main/resources/base/element/string.json` | 改 | 追加 `probe_p0u3_title`、`probe_p0u3_hint` 两键（纯 JSON 禁尾逗号） | —（资源） | 无 |
| 11 | `entry/src/main/resources/zh_CN/element/string.json` | 改 | 同 #10 两键（中文文案） | —（资源） | 无 |
| 12 | `entry/src/main/resources/en_US/element/string.json` | 改 | 同 #10 两键（英文文案） | —（资源） | 无 |
| 13 | `docs/probe/PROBE-u0-3-extension-bridge-server.md` | 新 | 探针运行手册：S1~S4 步骤表 + **主机侧 fport+curl 全套命令**（含八路由逐条与 POST 样例、`fport rm` 清理、扩展轮询时序注记） | —（文档） | #7 #10 |
| 14 | `docs/probe/EXPECT-u0-3-extension-bridge-server.json` | 新 | 机器可读预期表（BEGIN/S1~S4/SUMMARY/END 7 条目，须通过 JSON.parse 校验） | —（JSON） | #13 |

**显式不动的配置文件（有据）**：`module.json5`（§0-4：INTERNET 与 2in1 已在，`:14-18`/`:7-10`）、`main_pages.json`（探针子页不注册）。**不触碰**：`resourses/` 下任何文件（只读红线）；U6.1 的完整路由业务、`docs/` 根文档回写均不属本单元。

## 2. 数据模型与表结构（对照源码逐一核对）

### 2.1 业务表结构：无

无 RelationalStore/preferences 新键（`/sync` 四配置字段走既有 `core/Config.ets` 读取，不新增存储）；无二进制格式兼容。

### 2.2 `/sync` 应答体（唯一业务数据结构，对照 `IpcHttpMessageProcessor.cs:278-374 CreateConfigJson` 逐字段）

应答：`200 OK` + 头 `Content-Type: application/json`（:272）与 `Cache-Control: max-age=0, no-cache, must-revalidate`（:273）+ `Formatting.None` 紧凑 JSON（无空格换行，:285）。**顶层字段序固定**（JsonTextWriter 写出序 :289-362）：

| 序 | 字段 | 原版来源 | 默认值（本会话核实行号） | 鸿蒙来源 |
|---|---|---|---|---|
| 1 | `enabled` | `Config.Instance.IsBrowserMonitoringEnabled`（:290） | `true`（Config.cs:46） | `Config.getInstance().getIsBrowserMonitoringEnabled()`（Config.ets:578） |
| 2 | `fileExts` | `Config.Instance.FileExtensions`（:294） | 23 项：3GP,7Z,AVI,BZ2,DEB,DOC,DOCX,EXE,ISO,MSI,PDF,PPT,PPTX,RAR,RPM,XLS,XLSX,SIT,SITX,TAR,JAR,ZIP,XZ（Config.cs:64-68） | `getFileExtensions()`（Config.ets:820；`DEFAULT_FILE_EXTENSIONS` :176） |
| 3 | `blockedHosts` | `Config.Instance.BlockedHosts`（:302） | 3 项：update.microsoft.com,windowsupdate.com,thwawte.com（Config.cs:72-75） | `getBlockedHosts()`（Config.ets:830；`DEFAULT_BLOCKED_HOSTS` :180） |
| 4 | `requestFileExts` | `Config.Instance.VideoExtensions`（:310） | 15 项：MP4,M3U8,F4M,WEBM,OGG,MP3,AAC,FLV,MKV,DIVX,MOV,MPG,MPEG,OPUS,MPD（Config.cs:56-60） | `getVideoExtensions()`（Config.ets:810；`DEFAULT_VIDEO_EXTENSIONS` :173） |
| 5 | `mediaTypes` | 常量（:318） | `["audio/","video/"]` | `SYNC_MEDIA_TYPES` |
| 6 | `tabsWatcher` | 常量（:326） | `[".youtube.","/watch?v="]` | `SYNC_TABS_WATCHER` |
| 7 | `videoList` | `ApplicationContext.VideoTracker.GetVideoList()`（:332，VideoTracker.cs:130） | —（U0.3 恒 `[]`，§0-8） | 常量空数组；元素 interface `BridgeVideoItem` |
| 8 | `matchingHosts` | 常量（:358） | `["googlevideo"]` | `SYNC_MATCHING_HOSTS` |

`videoList` 元素字段序 `{id,text,info,tabId}`（:340-350）——原版来源 `MediaInfo`（VideoTracker.cs:391-395）四属性均 string，故 `BridgeVideoItem` 四字段全 string。扩展侧 8 字段全部消费（app.js:37-46，`enabled` 须 `===true`）；首轮询 ~6s、稳态 ~5s 一次（connector.js:14-22：12 个 periodInMinutes=1 的 alarm，相位 `now+1000+(i+1)*5000` 错开——12×1/分钟合并 ≈ 5s 间隔；手册 S3 注记引用此数供 U6.3 对表）。

### 2.3 协议数据模型（ArkTS 形态）

| 类型 | 字段 | 用途 / 源码对照 |
|---|---|---|
| `interface BridgeHeaders`（纯数据载体） | `names: string[]`、`values: string[][]`（平行数组，插入序） | 对齐 `Dictionary<string,List<string>>`（HttpParser.cs:76-78 同名多值累积、大小写敏感键、取值一律 [0] 首值）；Map 迭代序=插入序与 C# Dictionary 枚举序同构（无删除场景）；平行数组利于纯函数与用例构造 |
| `interface HeadParseResult` | `complete: boolean`（空行已达）；`failed: boolean`（解析失败→断连）；`method: string`（首 token，**不参与路由**，仅供探针观测）；`path: string`；`headers: BridgeHeaders`；`bodyStart: number`（头块结束偏移） | LineReader.cs:11-37 + HttpParser.cs:14-41,59-89 的增量产物 |
| `interface BridgeVideoItem` | `id: string; text: string; info: string; tabId: string` | VideoTracker.cs:391-395（§2.2 序 7） |
| `interface SyncFields`（buildSyncJson 入参） | `enabled: boolean; fileExts: string[]; blockedHosts: string[]; requestFileExts: string[]; mediaTypes: string[]; tabsWatcher: string[]; videoList: BridgeVideoItem[]; matchingHosts: string[]` | CreateConfigJson 八段写出序（§2.2）；interface 字段序即 JSON 序列化序 |
| `interface BridgeStats` | `started: boolean; boundPort: number; connections: number; requests: number; lastMethod: string; lastPath: string` | 探针 S1/S3 观测源；`lastMethod/lastPath` 为原版丢弃的 method 的观测补偿（HttpParser.cs:14-29 只返回 arr[1]） |
| `interface ResponseHeadView`（探针侧） | `complete: boolean; statusLine: string; status: number; headerNames: string[]; headerValues: string[][]; bodyStart: number` | 客户端应答解析（服务端不解析自身应答，放探针模块） |
| `interface SyncBodyView`（探针侧） | `jsonValid: boolean; fieldCount: number; fieldOrder: string` | S2 观测：`JSON.parse` 成功性 + `Object.keys` 序（= 应答体文本序，8 字段契约的观测面） |

沙箱落盘文件（探针 detail 通道，PROBE_SPEC §2"大段数据不进 hilog"）：

| 文件（`<filesDir>/` 下） | 产生步骤 | 内容 | 生命周期 |
|---|---|---|---|
| `probe-P0-U3-<runId>-s2-response.txt` | S2 | keep-alive 首应答原始头块文本 + 应答体文本（S3 复核可追加主机 curl 触发的服务端计数快照） | 保留作证据；标记行只记 `detailFile=` |
| `probe-latest.txt` | 脚手架 | 标记行兜底（U0.1 既有恒名） | 不变 |

## 3. 关键算法与线程模型翻译说明

### 3.1 头解析：字节级增量状态机（LineReader.cs:11-37 逐语义保留）

原版 `ReadLines` 逐字节：跳过 `'\r'`（**任意位置**，非仅行尾）；遇 `'\n'` 且行缓冲空 → 头块结束（yield break）；`'\n'` 且非空 → 交出一行并清缓冲；EOF → `IOException`（断连）。鸿蒙侧 `TCPSocketConnection.on('message')` 的 `SocketMessageInfo.message: ArrayBuffer` 是**任意分包**（本会话 d.ts:5070 核实字段 `message: ArrayBuffer`，@since 11）——**禁止对整块做字符串 split**，必须每连接维护累积 `Uint8Array` 缓冲（`appendBytes` 追加）+ `parseHead(buf, 0)` 增量扫描：

- 从 `start` 逐字节扫描：`0x0D` 一律丢弃（1:1 对齐"任意位置跳 \r"）；`0x0A` 且当前行空 → `complete=true`、`bodyStart=当前偏移+1`；`0x0A` 且行非空 → 交出一行（行字节按 `String.fromCharCode` 逐字节 Latin-1 转字符——对齐原版 `StringBuilder.Append((char)x)`，头域取值不含多字节语义）；扫到缓冲尾未遇空行 → `complete=false`（等下一包，已解析行序缓存于返回值内部由调用方丢弃重扫——头块量级仅数百字节，重扫成本可忽略，换取无状态纯函数）。
- 行语义（HttpParser.cs 逐条）：状态行 `Split(' ')`（**不忽略空项**）且 token 数 >2 才合法，`path=token[1]`、`method=token[0]`（保留在产物中，路由不用）；否则 `failed=true`。头行取**第一个** `':'` 且 index>0：key=冒号前 Trim、value=冒号后 Trim（含后续冒号，`'Host: a:b'→value 'a:b'`）；无冒号/首位冒号 → `failed=true`。同名头多值累积、键大小写敏感。
- `failed=true` 或后续 Content-Length 非法 → 连接**关闭不回包**（§0-1①）。

### 3.2 取体：定长精确读（HttpParser.cs:80-87 + :91-100 CopyTo(limit) 对照）

原版头块结束后 `CopyTo(limit)` 以 8192 缓冲**精确读满** `contentLength` 字节。鸿蒙侧事件流等价：`contentLength>0` 时检查 `缓冲长度 ≥ bodyStart+contentLength`——不足则本包处理到此为止（等下一包续齐）；足够则 `body = buffer.slice(bodyStart, bodyStart+contentLength)`（复制，脱离缓冲），**剩余字节保留在缓冲中**（属 keep-alive 的下一请求，:87 语义的承接）。`contentLength<=0`（含缺省 -1、负值）→ 无体。**不支持 chunked**（原版同，头块里 transfer-encoding 不处理）。

`getContentLength`（HttpParser.cs:43-47 逐语义）：键精确大小写 `Content-Length` 取 [0]；缺省 → `-1`；十进制整数（正则 `new RegExp('^[+-]?[0-9]+$')`，入参已 Trim）→ 数值（`>0` 才读体，`0`/负值不读——对齐 Int64.Parse 后 `>0` 判定）；其余（空串/小数/非数字）→ `-2`（= 解析失败 → 断连）。微偏差注记：C# `Int64.Parse` 对 `"+5"` 成功、对 `"0x10"` 失败，正则两式均对齐；`" 5 "` 已在头解析 Trim 后不会出现。

### 3.3 keep-alive：非对称行为 1:1 保留

判定（HttpParser.cs:49-57）：键精确大小写 `Connection` 取 [0]，缺省按 `"close"`；值 `equalsIgnoreCase('keep-alive')` 才复用连接。应答侧恒写 `Connection: keep-alive`（RequestContext.cs:49，即便随后关闭）——**非对称保留**：curl 默认不发 Connection 头 → 服务端一请求一连接，但应答头仍写 keep-alive（curl -v 可观测此签名，手册 §4）。复用路径：应答 send 完成后回到 §3.1 在**同一缓冲**上继续解析下一请求；关闭路径：send 完成后 `conn.close()`（d.ts:4094 `TCPSocketConnection.close(): Promise<void>` @since 10/24）。

### 3.4 应答拼装：RequestContext.SendResponse 逐行对照（RequestContext.cs:33-62）

`buildResponseBytes(statusCode, statusMessage, headers, body)` 产出单块 `Uint8Array`，**一次** `conn.send({data: ArrayBuffer})`（TCPSendOptions.data: string|ArrayBuffer，d.ts:2227 起）：

1. 状态行恒 `HTTP/1.0 {code} {msg}\r\n`（:37 硬编码，与请求版本无关）；
2. 调用方头按插入序逐值输出 `Name: Value\r\n`，但名为 `content-length` 的头**忽略大小写跳过**（:40-43，长度由框架重算）；
3. 恒追加 `Connection: keep-alive\r\n`（:49）；
4. 仅当 `body` 非空且 `length>0` 时追加 `Content-Length: {N}\r\n`（:50-53）——**404 空体不带 Content-Length**，HTTP/1.0 靠连接关闭定界（探针客户端以 `on('close')` 为完整信号）；
5. `\r\n` + 头块字节 + 体字节。头块仅含 ASCII，经 `asciiBytes()`（charCodeAt 循环）编码；体已是字节（`/sync` 的 JSON 串经 `utf8Encode`，§3.5）。

### 3.5 `/sync` JSON 组装与编码

`buildSyncJson(fields: SyncFields): string`：构造 `SyncFields` 具型对象字面量（**interface 字段序 = §2.2 序 = 序列化序**，JSON.stringify 对 string 键保持插入序）后 `JSON.stringify`——等价 JsonTextWriter `Formatting.None` 紧凑写出；禁手拼字符串（转义风险）。体编码 `utf8Encode(str): Uint8Array` 纯函数（charCodeAt 循环：`<0x80`→1B、`<0x800`→2B、代理对→4B、其余 3B）——U0.3 内容全 ASCII，但 U6.1 videoList 文本可能含 CJK，编码正确性现在立契约（Hypium 含 CJK/emoji 用例）；编码员可改用 `util.TextEncoder.encodeIntoUint8Array`（d.ts:981 @since 11）替换实现，但 `buildResponseBytes` 纯函数签名不变（体以字节传入）。

### 3.6 本机 API 面核实清单（编码期免查）

| API | 本机 d.ts 位置 | @since | 用途 |
|---|---|---|---|
| `socket.constructTCPSocketServerInstance()` | @ohos.net.socket.d.ts:143 | 10/24 | 服务端实例 |
| `TCPSocketServer.listen(address: NetAddress): Promise<void>` | :4372 | 10/24 | `listen({address:'127.0.0.1', port:8597, family:1})`；**bind 失败系统随机分配端口**（§0-3） |
| `TCPSocketServer.getLocalAddress(): Promise<NetAddress>` | :4510 | 12/24 | listen 后端口校验 `port===8597` |
| `TCPSocketServer.close(): Promise<void>` | :4392 | 20/24 | `stop()` 关闭监听端口（探针/测试路径） |
| `TCPSocketServer.on(type:'connect', cb: Callback<TCPSocketConnection>)` | :4528 | 10/24 | 每连接入口（原版每连接线程对应物）；`TCPSocketConnection.socketId: number`（@since 10） |
| `TCPSocketConnection.on('message', Callback<SocketMessageInfo>)`；`SocketMessageInfo{message: ArrayBuffer, remoteInfo}` | :5070 | 12/11 | 任意分包接收 |
| `TCPSocketConnection.send(options: TCPSendOptions): Promise<void>`；`TCPSendOptions.data: string|ArrayBuffer`（接口 :2227 起） | :4052 / :2227 | 10 | 应答单次发送 |
| `TCPSocketConnection.close(): Promise<void>`；`on(type:'close')` | :4094 / :4230 | 10 | 关闭路径与客户端完整信号 |
| `socket.constructTCPSocketInstance()` + `connect(TCPConnectOptions): Promise<void>`；`TCPConnectOptions{address: NetAddress, timeout?: number}` | :91 / :2176 | 10 | 探针 S2/S4 自连客户端 |
| `NetAddress{address: string; family?: number; port?: number}`（family 1=IPv4/2=IPv6） | @ohos.net.connection.d.ts（socket.d.ts:36 re-export） | 8/24 | listen/connect 地址对象 |
| 权限前提 | — | — | listen/getLocalAddress/send 均需 `ohos.permission.INTERNET`（module.json5 已有，§0-4） |

### 3.7 线程模型映射（对照 MIGRATION_PLAN 决策 2 精神）

| 原版 | 鸿蒙投影 |
|---|---|
| `NanoServer.Start()` 阻塞 accept 循环（HttpServer.cs:21-29） | `listen()` 一次调用 + `'connect'` 事件回调（内核 accept，事件投递） |
| 每连接专职线程（:42-64 `new Thread`） | 每连接一个 `ClientSession` 状态对象（自有缓冲/游标/关闭标志），回调由 JS 单线程事件循环串行投递——**多连接天然交错、单连接天然串行，无锁** |
| 阻塞 `stream.ReadByte()` / `CopyTo` | 事件驱动累积缓冲 + 增量 `parseHead`（§3.1/§3.2） |
| 应答后 `while(true)` 继续读下一请求 | `drain()` 泵：busy/pending 双标志串行化——`on('message')` 到达时若正在 `await send` 则置 pending 返回（数据继续累积在缓冲），send 完成后若 pending 再入泵；泵内 while 循环把缓冲中所有完整请求依次处理完 |
| 处理异常 rethrow → 每连接 catch → Close | `drain()`/`dispatch()` 内 try/catch → hilog（tag `BridgeServer`）→ `conn.close()` 不回包（§0-1①） |

**不用 TaskPool**：解析为每请求数百字节级 CPU 量、`/sync` 组装为 O(配置表长)，主事件循环无压力；socket 对象与单例不可跨线程共享，引入 TaskPool 反而破坏 §0-5 红线。探针侧亦无需 @Concurrent（自连客户端即 socket API 事件流）。

## 4. 有意差异清单（对照源码/计划）

1. **未知路径 → 404 空体**（原版 `default: throw ArgumentException` → 断连不回包，IpcHttpMessageProcessor.cs:76-77）——单元指令拍板；U6.1 沿用并写入桥协议规格书（§0-2）。
2. **七条已注册业务路由（/download /media /tab-update /vid /clear /link /args）→ 404 空体**（原版执行业务处理后统一回 200+sync JSON，:55-75）——本单元为分发骨架，业务处理 U6.1 补全；日志区分 `unimplemented`（已知路径）与 `unsupported`（未知路径）。
3. **解析层失败与 /sync 处理异常 → 断连不回包**（未采纳研究结论"异常转 500/404"建议）——1:1 原版，§0-1 拍板。
4. **videoList 恒空数组**——CapturedVideoTracker 属 U6.2；字段位与元素 interface 预留（§0-8）。
5. **端口占用：随机端口回退校验 + 仅日志/探针观测，无 MSG_ALREADY_RUNNING UI**（原版 IpcHttpMessageProcessor.cs:39-43 弹窗）——§0-3 拍板，UI 提示留 U6.x。
6. **method 保留在解析产物中**（原版 HttpParser.cs:14-29 完全丢弃）——仅作探针 S3/S4 观测（lastMethod），不参与路由判定，行为零差异。
7. **MIGRATION_PLAN §3 既有降级项（本单元不涉及实现，登记边界）**：Chrome Native Messaging 不复刻（扩展走 8597 HTTP 轮询，connector.js:4 硬编码即连通性契约）；register.html 自定义协议注册省略（决策 5）；拉起应用改深链为可选 UX 未实现。本单元 none 新增降级。
8. **响应恒 HTTP/1.0 状态行 + 恒 Connection: keep-alive 头（含无体 404）**——非偏差，1:1 保留（RequestContext.cs:37,49），列入 EXPECT 判定要点防"顺手修正"。
9. **头容器 Map/平行数组替代 `Dictionary<string,List<string>>`**——ArkTS 无结构化类型/Dictionary 等价物，语义同构（插入序+同名多值+大小写敏感），非行为差异。
10. **S3 迷你会话多次 BEGIN/END**——ProbePage.runSingle 既有编排（ProbePage.ets:122-172），EXPECTED note 声明取数口径（§0-6），非格式缺陷。

## 5. 各文件实现要点（可直接照做的接口面）

### 5.1 BridgeProtocol.ets（新，全量签名）

```typescript
// 零 @kit import（本地单测/探针可直接 import；utf8Encode 内置，不依赖 util）
export const BRIDGE_PORT: number = 8597;
export const BRIDGE_HOST: string = '127.0.0.1';
export const BRIDGE_FAMILY: number = 1;                       // NetAddress.family 1=IPv4
export const ROUTE_PATHS: string[] = ['/sync', '/download', '/media', '/tab-update',
  '/vid', '/clear', '/link', '/args'];                        // 原版 switch 序（:53-75）
export const SYNC_CONTENT_TYPE: string = 'application/json';
export const SYNC_CACHE_CONTROL: string = 'max-age=0, no-cache, must-revalidate';
export const SYNC_MEDIA_TYPES: string[] = ['audio/', 'video/'];
export const SYNC_TABS_WATCHER: string[] = ['.youtube.', '/watch?v='];
export const SYNC_MATCHING_HOSTS: string[] = ['googlevideo'];

export interface BridgeHeaders { names: string[]; values: string[][] }
export interface HeadParseResult {
  complete: boolean; failed: boolean; method: string; path: string;
  headers: BridgeHeaders; bodyStart: number; }
export interface BridgeVideoItem { id: string; text: string; info: string; tabId: string }
export interface SyncFields {
  enabled: boolean; fileExts: string[]; blockedHosts: string[]; requestFileExts: string[];
  mediaTypes: string[]; tabsWatcher: string[]; videoList: BridgeVideoItem[]; matchingHosts: string[]; }

export function appendBytes(a: Uint8Array, b: Uint8Array): Uint8Array        // 新缓冲拼接
export function parseHead(buf: Uint8Array, start: number): HeadParseResult   // §3.1 增量状态机
export function firstHeader(h: BridgeHeaders, name: string): string          // 精确大小写键 [0]，缺省 ''
export function getContentLength(h: BridgeHeaders): number                   // §3.2：-1 缺省/-2 非法
export function isKeepAlive(h: BridgeHeaders): boolean                       // §3.3
export function buildResponseBytes(statusCode: number, statusMessage: string,
  headerNames: string[], headerValues: string[], body: Uint8Array): Uint8Array // §3.4；body 可传空数组=无体
export function buildSyncJson(f: SyncFields): string                         // §3.5，JSON.stringify(SyncFields)
export function utf8Encode(s: string): Uint8Array                            // §3.5，代理对感知
```

实现注记：`parseHead` 内行缓冲用 `string` 累积（逐字节 fromCharCode）；`failed` 判定后立即返回（不再继续扫）；`complete=false` 时 `path/method/headers` 返回空值由调用方忽略。`firstHeader` 禁用正则字面量（`new RegExp`）。`getContentLength` 的数值解析用 `Number(v)` + 全串正则先行。

### 5.2 BridgeServer.ets（新）

```typescript
import { socket } from '@kit.NetworkKit';        // 其余：hilog/BusinessError/Config/BridgeProtocol
export interface BridgeStats { started: boolean; boundPort: number; connections: number;
  requests: number; lastMethod: string; lastPath: string; }

export class BridgeServer {                       // 单例（同 Config/DownloadManager 惯例）
  static getInstance(): BridgeServer
  /** 幂等 + memoized promise：EntryAbility 与探针 S1 并发/先后调用共享同一 Promise；
   *  成功路径：construct → on('connect')/on('error') → listen({address,port,family}) →
   *  getLocalAddress() 校验 → boundPort 记录；boundPort!==8597 → hilog.warn（portMismatch，§0-3） */
  start(): Promise<void>
  stop(): Promise<void>                           // 探针/测试用；关 server 实例
  isStarted(): boolean                            // start() 已调用（memoized 含义）
  getStats(): BridgeStats                         // 同步快照（S1/S3 观测源）
  // 私有：
  // onConnect(conn: socket.TCPSocketConnection): new ClientSession(conn) → connections++
  // dispatch(path, method, body: Uint8Array): { status, msg, headerNames, headerValues, body }
  //   '/sync'（ROUTE_PATHS[0]）→ try buildSyncJson(Config 四 getter + 常量表 + 空 videoList)
  //     → 200 + [Content-Type, Cache-Control] + utf8Encode(json)；异常 → rethrow 至泵（断连，§0-1①）
  //   其余 ∈ ROUTE_PATHS → 404 'Not Found' 空体 + hilog 'unimplemented'
  //   其余 → 404 'Not Found' 空体 + hilog 'unsupported'
}

class ClientSession {                             // 文件内私有类
  // 字段：conn、socketId、buffer: Uint8Array（未消费累积）、busy/pending、closed
  // onMessage(info: SocketMessageInfo): buffer=appendBytes(buffer,new Uint8Array(info.message)); drain()
  // drain(): 泵（§3.7）——每轮 parseHead(buffer,0)：
  //   !complete → break；failed → close(不回包)；
  //   len=getContentLength；len===-2 → close(不回包)；
  //   len>0 且 buffer.length<bodyStart+len → break（等包）；body=buffer.slice(...)
  //   → requests++/lastMethod/lastPath 记账 → dispatch → buildResponseBytes →
  //   await conn.send({data: bufferSource}) → isKeepAlive? 继续 : await conn.close()
  //   消费推进：buffer=剩余字节拷贝；catch → hilog(tag 'BridgeServer') → close 不回包
  // onClose(): closed=true 清引用
}
```

hilog 红线：domain 0x0000、tag `BridgeServer`（不含 `XDM_PROBE` 子串）；日志值不含请求体内容（隐私）。

### 5.3 EntryAbility.ets（改，只加不改）

onCreate 尾部（:107 `ClipboardWatcher.getInstance().syncFromConfig();` 之后）追加：

```typescript
// U0.3 只加不改（设计书 §5.3）：8597 扩展桥常驻启动——对照 ApplicationCore Init 尾部
// StartScheduler() 后 StartBrowserMonitoring() 的次序；start() 幂等 memoized，端口失配
// 仅日志（原版 MSG_ALREADY_RUNNING 的无 UI 等价物，§0-3）
BridgeServer.getInstance().start().catch((err: BusinessError) => {
  hilog.error(DOMAIN, 'testTag', '%{public}s',
    'BridgeServer start failed errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
});
```

头部块注释按本文件惯例补 U0.3 段；import 区追加 `import { BridgeServer } from '../core/bridge/BridgeServer';`。其余语句序零改动。

### 5.4 ProbeBridgeLogic.ets（新，探针专用纯函数）

```typescript
export const SYNC_BODY_MARKER: string = '"enabled"';   // S2 观测辅助锚（首字段）
export interface ResponseHeadView { complete: boolean; failed: boolean; status: number;
  statusLine: string; headerNames: string[]; headerValues: string[][]; bodyStart: number }
export interface SyncBodyView { jsonValid: boolean; fieldCount: number; fieldOrder: string }
export function splitResponseHead(buf: Uint8Array): ResponseHeadView  // 扫 \r\n\r\n；状态行 'HTTP/1.0 200 OK'→200；头名统一小写便于查找
export function parseSyncBody(bodyText: string): SyncBodyView         // JSON.parse + Object.keys(json).join(',')
```

### 5.5 ProbeBridge.ets（新）

骨架对齐 ProbeHttp 惯例（ProbeHttp.ets:46-54 步骤表 + ProbePage 组装）：

```typescript
const BRIDGE_STEPS: ProbeStepDef[] = [
  { stepNo: 'S1', title: '服务启动+端口监听观测', autoRun: true },
  { stepNo: 'S2', title: '应用内自连 GET /sync 应答观测', autoRun: true },
  { stepNo: 'S3', title: '主机侧 curl 指引（手动）', autoRun: false },
  { stepNo: 'S4', title: '八路由 404/错误处理观测', autoRun: true }
];
@Component export struct ProbeBridge { /* ProbePage({unitId:'P0-U3', autoStart:true, runStep:...}) + hint Text */ }
```

每 runner 入口捕获 runId、每个 await 后与 emit 前复检 `isCurrent`（U0.2 §3.5 守卫惯例）；自连客户端统一封装私有方法 `roundTrip(requestHead: string, bodyBytes?: Uint8Array): Promise<{status:number, bytes:Uint8Array, closedByServer:boolean}>`（connect → send → on('message') 累积 + on('close') 门 + 10s 硬顶防挂起——沿用 U0.2 END_GATE_TIMEOUT 先例）；catch 一律 emit `errCode/errMessage` 键组不外抛。

### 5.6 ProbeIndex.ets / string.json（改）

- `PROBE_UNITS` 追加 `{ unitId: 'P0-U3', title: $r('app.string.probe_p0u3_title') }`（置于表尾）；`import { ProbeBridge } from './units/ProbeBridge';`；详情 if 链尾追加 `else if (this.selectedUnitId === 'P0-U3') { ProbeBridge() }`。
- 三份 string.json 各追加两键：`probe_p0u3_title`＝`扩展桥 8597 服务端探针（P0-U3）`（en_US: `Extension Bridge 8597 Server Probe (P0-U3)`）；`probe_p0u3_hint`＝主机侧 curl 指引一句话（含 fport 18597→8597 提示，en_US 同义）。

### 5.7 本地单测

`List.test.ets` 追加 `bridgeProtocolTest()` 与 `probeBridgeLogicTest()` 两个注册（文件头注释按惯例补 U0.3 段与用例计数）。

## 6. 探针步骤设计（P0-U3）

拉起/抓取/兜底命令沿用 U0.1/U0.2 手册口径（`hdc shell "aa start -b com.example.xdmharmony -a EntryAbility --ps page probe"`）。所有行 hilog：domain 0xD001、tag XDM_PROBE、`%{public}s`。**应用经 `devecocli run` 正常拉起即已由 EntryAbility 启动桥服务——S1 的 alreadyStarted=true 本身就是"启动接线"的运行时证据**。

| 步骤 | 操作 | 观测点（emit 键） | 标记行示例 |
|---|---|---|---|
| BEGIN | ProbePage autoStart 编排 | runId、filesDir | `[XDM_PROBE][P0-U3][BEGIN] runId=143012 filesDir=/data/app/el2/100/base/com.example.xdmharmony/haps/entry/files` |
| S1 服务启动+端口监听 | 读 `getStats()` 快照（EntryAbility 已 start）→ `await start()`（幂等 memoized）→ 再读快照 | alreadyStarted、boundPort、portMismatch、connections、requests | `[XDM_PROBE][P0-U3][S1] alreadyStarted=true boundPort=8597 portMismatch=false connections=0 requests=0` |
| S2 自连 /sync 应答 | 应用内 `constructTCPSocketInstance` → connect 127.0.0.1:8597 → 发 `GET /sync HTTP/1.1\r\nHost: 127.0.0.1:8597\r\nConnection: keep-alive\r\n\r\n` → 同连接再发第二请求（keep-alive 复用观测）→ 另开一连接发 `Connection: close` 请求观测服务端关闭；应答经 `splitResponseHead`+`parseSyncBody`；原始头+体写 detail 文件 | status、contentType、cacheControl、contentLength、bodyBytes、jsonValid、fieldCount、fieldOrder、reuseResponses、closeConnClosed、detailFile | `[XDM_PROBE][P0-U3][S2] status=200 contentType=application/json cacheControl=max-age=0/no-cache/must-revalidate contentLength=257 bodyBytes=257 jsonValid=true fieldCount=8 fieldOrder=enabled/fileExts/blockedHosts/requestFileExts/mediaTypes/tabsWatcher/videoList/matchingHosts reuseResponses=2 closeConnClosed=true detailFile=probe-P0-U3-143012-s2-response.txt`（R2-F2 注记：cacheControl/fieldOrder 的分隔符 `/` 为探针值白名单消毒预转换 `','→'/'` 的呈现形——白名单不含逗号，原始逗号形 `max-age=0, no-cache, must-revalidate` / `enabled,fileExts,...` 保留在 detail 文件） |
| S3 主机侧 curl 指引 | **autoRun=false**：UI 显示 `probe_p0u3_hint`；emit 指引命令串 + 服务端计数快照；手册 §4 全套命令（`hdc fport tcp:18597 tcp:8597` → `curl http://127.0.0.1:18597/sync`）；**AI 在设备连接时代执行，执行后复点"执行"按钮**产生复核 minisession | cmd1、cmd2、connections、requests、lastMethod、lastPath | `[XDM_PROBE][P0-U3][S3] cmd1=hdc fport tcp:18597 tcp:8597 cmd2=curl http://127.0.0.1:18597/sync connections=2 requests=2 lastMethod=GET lastPath=/sync` |
| S4 八路由 404/错误处理 | 逐路径应用内自连（每路径新连接、`Connection: close`）：GET 八条字面量 + `GET /sync?x=1`（不剥 query）+ `POST /sync`（体 `{}`，Content-Length: 2）+ 裸发 `GARBAGE\r\n\r\n` 观测断连不回包 | syncStatus、downloadStatus、mediaStatus、tabUpdateStatus、vidStatus、clearStatus、linkStatus、argsStatus、querySyncStatus、postSyncStatus、malformedClosed | `[XDM_PROBE][P0-U3][S4] syncStatus=200 downloadStatus=404 mediaStatus=404 tabUpdateStatus=404 vidStatus=404 clearStatus=404 linkStatus=404 argsStatus=404 querySyncStatus=404 postSyncStatus=200 malformedClosed=true` |
| SUMMARY | end(ok) 聚合 | 全段（ProbeKit 两级降级） | `[XDM_PROBE][P0-U3][SUMMARY] S1=boundPort=8597,portMismatch=false|S2=status=200,jsonValid=true,fieldCount=8|S3=lastPath=/sync|S4=syncStatus=200,downloadStatus=404,malformedClosed=true` |
| END | ok=无脚手架级异常；steps=4；elapsedMs | ok、steps、elapsedMs | `[XDM_PROBE][P0-U3][END] ok=true steps=4 elapsedMs=820` |

失败路径：任一步 `catch(BusinessError)` → 该步输出 `errCode/errMessage` 键组（仍恰一行）；S4 单路由连接失败不中断循环——该路由状态记 `err` 字样（连接失败也是错误处理观测事实）。红线：布尔键（portMismatch/jsonValid/closeConnClosed/malformedClosed）均为对直接观测值的谓词编码，不含 PASS/FAIL 词；期望只存在于 EXPECT 表。

## 7. 单元验收测试要点

### [A] 静态门禁（编码员每轮自跑）

1. **hvigor 全量构建**零 error 零新 warning。ArkTS 严格子集自查点：对象字面量均有 interface 类型（SyncFields/BridgeHeaders/TCPSendOptions 等）；禁正则字面量（`new RegExp`）、禁 any/解构/for...in；`Map`/平行数组替代字典；async 显式 `Promise<void>`；socket 回调参数类型标注（`SocketMessageInfo`/`TCPSocketConnection`）；BusinessError 窄化 `as`。
2. **结构断言**：`grep -rn "XDM_PROBE" entry/src/main/ets/core` 零命中（业务红线）；`grep -rn "import.*probe" entry/src/main/ets/core` 零命中（依赖单向）；`grep -n "BridgeServer" entry/src/main/ets/entryability/EntryAbility.ets` 恰 import+1 次调用（只加不改）；`grep -n "P0-U3" entry/src/main/ets/probe/ProbeIndex.ets` 命中注册与分支；main_pages.json 未改。
3. **Hypium 本地用例清单**（执行环境注记同 U0.2 §7-3：本地单测 runner 本会话不可验证，用例入库不影响编译门禁，编码员实跑或留 U2.3 统一回归）：
   - `parseHead`：①单包完整 `GET /sync HTTP/1.1\r\nHost: 127.0.0.1:8597\r\n\r\n` → complete/method/path/headers；②跨包增量：`'GET /sync HT'`+`'TP/1.1\r\n\r\n'` 两段 → 首段 complete=false、拼接后 complete=true；③`'GET /\r\n\r\n'` → failed=true（token≤2）；④头行无冒号 / `': v'` → failed=true；⑤`'Host: a:b'` → value=`a:b`（首个冒号切分）；⑥`'Ge\rT /sync HTTP/1.1\r\n\r\n'` → method=`GeT`（\r 任意位置丢弃）；⑦同名双头 → values 长 2、firstHeader 取 [0]；⑧大小写敏感：`content-length` 与 `Content-Length` 共存 → getContentLength 取后者首值；⑨头块后随体字节 → bodyStart 指向体首字节且体不被吞；⑩`complete=false` 时 failed=false 且无副作用值。
   - `getContentLength`：缺省 -1；`'10'`→10；`'abc'`/`''`/`'12.5'`→-2；`'-5'`→-5（仅 >0 读体）；`'+5'`→5。
   - `isKeepAlive`：缺省 false；`'keep-alive'`/`'Keep-Alive'`→true；`'close'`→false；多值取 [0]。
   - `buildResponseBytes`：①200+两头+体 → 全字节序断言（HTTP/1.0 行/头序/恒 keep-alive/Content-Length/\r\n/体）；②404 空体 → 无 `Content-Length` 行（indexOf -1）；③调用方 `content-length` 头（小写）被跳过；④同名头逐值两行输出。
   - `utf8Encode`：①ASCII 恒等；②`'下载'` → 6 字节（E4 B8 8B E8 BD BD）；③`'😀'` → 4 字节代理对（F0 9F 98 80）；④空串。
   - `buildSyncJson`：①默认字段序 `Object.keys(JSON.parse(...))` 恰等于 §2.2 八序；②fileExts 23 项逐项比对 Config.cs:64-68；③blockedHosts 3 项、requestFileExts 15 项逐项；④mediaTypes/tabsWatcher/matchingHosts 常量三表；⑤videoList 空 → `"videoList":[]`；⑥单元素字段序 id,text,info,tabId；⑦紧凑断言：串中不含 `', '` 与 `': '`；⑧`enabled=false` 时序列化为 `false`。
   - `splitResponseHead`：①完整应答 → status=200/bodyStart 正确；②半包 → complete=false；③无体应答（无 Content-Length 头）→ complete 靠 close 门。
   - `parseSyncBody`：①合法八字段 JSON → jsonValid=true、fieldCount=8、fieldOrder 正确；②非法串 → jsonValid=false；③字段缺失 → fieldCount<8（观测不判定）。

### [P] 运行时（手册承载，xdm-probe-verify 机械判定）

4. **设备侧**：`devecocli run --module entry`（正常拉起即完成启动接线）→ `aa start --ps page probe` → P0-U3 卡片自动跑 S1/S2/S4 → 十一行序列（BEGIN+S1~S4+SUMMARY+END）逐行命中 FORMAT 正则；S3 手动点"执行"。
5. **主机侧（S3，AI 设备连接时代执行）**：`hdc fport tcp:18597 tcp:8597` → `curl -i http://127.0.0.1:18597/sync`（应答 `HTTP/1.0 200 OK`、`Content-Type: application/json`、`Cache-Control: max-age=0, no-cache, must-revalidate`、`Connection: keep-alive`、合法 JSON——**curl 收完即连接关闭**为原版非对称签名，§3.3）→ 八路由逐条 `curl -s -o NUL -w "%{http_code}"`（/sync 200、其余 404——404 即可达证据）→ `POST /sync` 200 → 复点 S3 计数增长 → `hdc fport rm tcp:18597` 清理。完整命令集见手册 §4。
6. **`/sync` 合法性判定基准**（连通性契约，connector.js:4,25,41）：`res.json()` 可解析 ⇒ 合法 JSON；字段序/字段数对照 EXPECT（§2.2 表）；`curl http://127.0.0.1:18597/sync` 的 stdout 直接过 `JSON.parse` 校验。
7. **环境分支**：S1 `portMismatch=true`（8597 被占/随机回退）→ 判 UNVERIFIED + 手册指引（重启应用/查占用 `netstat -ano | findstr 8597`），非 FAIL；S2/S4 连接被拒（errCode 系列）→ 分流 probe-code 或 env（桥未启动=EntryAbility 接线缺失）。
8. **xdm-probe-verify**：回贴 `probe-P0-U3.log` 全文 + EXPECT-u0-3-extension-bridge-server.json；S3 取"主机 curl 后最后一次 minisession"行（§0-6）。

## 8. 风险与备注

### 8.1 实现风险

| 风险 | 缓解 |
|---|---|
| on('message') 分包把头块/体切碎 | §3.1 增量状态机 + complete=false 等包；complete=false 重扫（头块量级小，正确性优先） |
| keep-alive 复用时 send 未 await 完就处理下一请求 → 应答乱序 | ClientSession busy/pending 串行泵（§3.7）；探针 S2 reuseResponses=2 即其回归观测 |
| listen 静默回退随机端口（§0-3） | getLocalAddress 校验 + portMismatch 观测 + EXPECT UNVERIFIED 分支 |
| 404 无 Content-Length，客户端（curl/自连）以断连定界 | 客户端 on('close') 为完整信号（§3.4-4）；S4 用 roundTrip close 门 |
| 极端长头块无上限（原版同样无界） | 1:1 保留（原版 LineReader 无上限）；U6.1 若加防护另行登记，本单元不做 |
| 探针 minisession 多 BEGIN/END | §0-6 口径，EXPECTED note 声明 |
| utf8Encode 代理对边界 bug | Hypium CJK/emoji 用例（§7-3）；编码员可选 util.TextEncoder 替换（§3.5） |
| 业务文件误输出探针标记 / 探针反向依赖 | §0-5 红线 + §7-2 grep 断言 |

### 8.2 产线登记：8597 常驻监听与后台任务交互（本单元不实现，登记备查）

- 原版为桌面进程，前台运行期监听天然存活；鸿蒙应用退后台后，进程可能被挂起/冻结——**socket 停止 accept 与应答，扩展侧 `res.json()` 失败 → disconnect()（connector.js:41）显示未连接**；回前台事件循环恢复后监听继续（TCP backlog 内的连接按内核行为处理）。
- 下载活跃期由 U5.1 DATA_TRANSFER 连续任务保活（进程不冻结 → 桥存活）——"边下载边嗅探"场景成立；空闲期无连续任务时桥不保证存活，属平台行为。
- U0.3 验收一律在前台执行（S3 主机 curl 时应用须在前台）；后续若需"后台也响应嗅探"，属 U6.x 需求（如保活策略拍板），不在本单元扩权。
- 单实例语义：同 bundle 二次拉起走 onNewWant，不会二次 listen（start() memoized）——原版"二次启动弹 MSG_ALREADY_RUNNING"场景在本工程结构性不存在（§0-3 仍保留校验防第三方占用）。
