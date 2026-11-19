# U6.1 BridgeServer 八路由完整版 · 模块设计书

> 单元：U6.1（Phase 6 第 1 项；探针单元 ID `P6-U1`）。
> 依据：MIGRATION_PLAN §6 决策 5（8597 八路由复刻）、§7 Phase 6 第 1 项；UNIT_CATALOG U6.1 行；PROBE_SPEC v1；单元指令（八路由业务补全+tracker 半区+探针 P6-U1+单测三项）；源码研究结论（分工1）。
> 对照源码（本会话只读核实，未改 resourses/ 下任何文件）：
> `XDM.Core/BrowserMonitoring/IpcHttpMessageProcessor.cs`（全 397 行）、`BrowserMonitoring/ExtensionData.cs`、`BrowserMonitoring/VideoTracker.cs`、`BrowserMonitoring/VideoUrlHelper.cs:35-90,615-700,873-902`、`ArgsProcessor.cs`（全）、`ApplicationCore.cs:188-236`、`Message.cs`（全）、`Util/FileHelper.cs:15-21`、`Util/ParsingHelper.cs`、`Collections/GenericOrderedDictionary.cs`、`chrome-extension/connector.js`、`chrome-extension/app.js`、`chrome-extension/request-watcher.js:150-189`、`firefox-amo/app/app.js:181`。
> 既有工程事实（本会话核实）：U0.3 已交 `BridgeProtocol.ets`（纯协议函数）+`BridgeServer.ets`（8597 监听/ClientSession 泵/仅 /sync 业务，其余 404 骨架）；`EntryAbility.ets:116` 已常驻 start；`Config.ets` 四 getter（getIsBrowserMonitoringEnabled/getFileExtensions/getBlockedHosts/getVideoExtensions）+ getMinVideoSize/getStartDownloadAutomatically/broadcastConfigChange 全就绪；`FileNames.ets` sanitizeFileName/fileNameFromUrl 纯函数就绪；`Formatting.ets` formatSize 就绪；`newDownloadRecord+store.add+admitNew` 链在 `Index.ets:449-459` 运行。

## 0. 拍板注记（三个 openQuestions 的裁决，必读）

1. **未知路径：废止 U0.3 的 404 中间态，改回源码 1:1 的"静默断连不回应答"**（openQuestion#3 采纳）。U0.3 设计书 §0-2 曾前瞻"U6.1 沿用未知路径 404"——本设计**推翻该前瞻**：对照 `IpcHttpMessageProcessor.cs:76-77`（default → throw ArgumentException）+ `HttpServer.cs:46-63`（rethrow → 每连接 catch → tcp.Close()，不回任何应答字节），本单元把未知路径改为 `throw Error` → 既有 ClientSession 泵的 rethrow-关闭通道（`BridgeServer.ets:274-286` catch → closeSilently）。理由：①本单元验收标准是"八路由对照源码逐端点"，404 是 U0.3 骨架期的显式中间态（D1/D2，注释即声明"U6.1 补全业务"）；②扩展 connector.js 只请求八条已知路径（`connector.js:4` + app.js postMessage 仅 /media /tab-update /download /vid /clear——本会话 grep 核实），零兼容风险；③静默断连使错误路径与"解析失败断连"统一，状态机更小。**同步影响**：U0.3 探针 S4 的 `querySyncStatus=404` 预期在 U6.1 后不复现（连接关闭且零应答字节=正确）；本单元探针 S8 以 `unknownClosed=true` 观测，手册与 Node 脚本判定同步改写。U0.3 探针已归档不重跑（UNIT_CATALOG 探针节奏节）。
2. **/media 落"纯头/URL 数学"子集（IsNormalVideo+ProcessNormalVideo），YT/HLS/DASH 分类与网络清单下载留 U6.2**（openQuestion#1 采纳研究建议）。不落该子集则 /media 只剩解析门，探针 videoList 观测全为空表，八路由验收形同虚设。子集边界：`IsNormalVideo` 五条数学（含疑似分片集 `suspectedMp4Fragments` 状态）+ `ProcessNormalVideo`（referer 守卫×空表、扩展名映射、`[EXT] size` 描述文本、入单源表）；**不落**：YT manifest 下载（网络）、HLS/DASH/segment 识别与处理、`m3u8MpdTabs`/`referersToSkip` 两表的**写入方**（本单元保留读取守卫，两表恒空 → 守卫恒过，U6.2 填充）。已知边界效应：真实浏览器 HLS `.ts` 段在 U6.1 会误入 videoList（源版靠 HLS 处理链+m3u8MpdTabs 拦截）——U6.2 全链落地前该效应只影响真实流量不影响受控探针流量，登记为暂态（§4-2）。
3. **/link 与 /args 的 UI 动作降级为"解析+校验 1:1，动作=事件+log+pending 存储"**（openQuestion#2 采纳）。`ShowDownloadSelectionWindow`（批量勾选窗）、`--quit` 进程退出、`--first-run` 激活主窗+RunOnLogon 均无鸿蒙对应物；U4.2 已有 `DownloadSelectionDialog.ets` 组件可复用，但接线属 UI 单元（U6.3 扩展端到端时一并落）。/link 现版 chrome 与 firefox 扩展都不再发（本会话 grep 全扩展目录核实，postMessage 仅五路径），兼容保留风险极低。
4. **tracker 半区的动作归属**：`CapturedVideoTracker`（本单元新建）承担**数据半区**——四张插入序表、GetVideoList 排序投影、Clear、UpdateMediaTitle、按 vid 查找、MediaAdded/MediaUpdated 事件；`AddVideoDownload`/`CoreService.AddDownload` 的**动作半区**（自动开下走 newDownloadRecord+store.add+admitNew 链 / 对话框事件）放 `BridgeRoutes.ets`——理由：动作链要 import `DownloadStore/DownloadManager`（core/db、core/engine），若放 tracker 则 tracker↔routes 循环 import（routes 的 /vid /args 处理器要查 tracker 表）。U6.2 落视频捕获窗时再评估是否收拢（届时 UI 订阅方就位）。
5. **module.json5 / main_pages.json / EntryAbility 显式不动（有据，非遗漏）**：本单元不新增能力——桥是回环 TCP 服务，`module.json5:7-10` deviceTypes 已含 `2in1`、`:11-18` requestPermissions 已含 `ohos.permission.INTERNET`（U0.1 落地，U0.3 §0-4 已核实 TCPSocketServer 各 API 的权限前提）；/--quit 降级为事件（§0-3）不调 UIAbility 退出；`main_pages.json` 只含 Index+ProbeIndex 不变；EntryAbility 已 `BridgeServer.getInstance().start()`（:116），tracker/路由模块全部惰性单例无需启动接线。编码时若发现权限缺失（异常态）上报主流程，不得擅自改配置。
6. **业务/探针依赖红线（U0.3 §0-5 延续）**：`core/bridge/` 全部业务文件禁止 import `probe/` 下任何文件、禁止输出含 `[XDM_PROBE]` 子串的日志行（业务 hilog domain 0x0000）；探针可单向 import `core/bridge/BridgeProtocol`（纯函数）与 `CapturedVideoTracker/BridgeRoutes`（注册观测监听器）。
7. **事件面零破坏的含义（红线操作化）**：①既有 `DownloadEvents`/`ManagerHooks`/`Config.onConfigChanged` 三个事件面零改动；②本单元新增 `CapturedVideoTracker` 监听器与 `BridgeUiEvents`（新事件面，纯增量）；③桥自动链创建的 record 会经 `DownloadManager` 既有事件袋流向 Index——`Index.handleStarted` 等 handler 对未知 id 均有 `findById→null` 守卫（`Index.ets:568-595` 本会话核实，ProgressNotifier 收空名安全），不崩溃不误改；④`Config.broadcastConfigChange()` 是既有 public API（U4.3 放开），tracker 复用不新增广播机制。

## 1. 目标文件清单（按实现顺序）

| # | 文件 | 新/改 | 职责 | 对外导出 | 依赖 |
|---|---|---|---|---|---|
| 1 | `entry/src/main/ets/core/bridge/BridgeProtocol.ets` | 改 | 桥协议纯逻辑模块增量：`BridgeResponse` 应答五元组（自 BridgeServer 提为公共）、14 项请求头黑名单、头剥离纯函数、宽松 UTF-8 解码、路由分类号 | 既有全部导出不变，新增 `BridgeResponse`、`BLOCKED_HEADERS`、`removeBlockedHeaders`、`utf8Decode`、`classifyRoute` | 无（保持零 @kit import） |
| 2 | `entry/src/main/ets/core/bridge/BridgeJson.ets` | 新 | 请求体 JSON 解析门+消息映射（纯逻辑，零 @kit）：ExtensionData 单对象/数组/List\<string\> 三门、头字典转换、Message 七字段映射（含 file/filename 双键+sanitize+头剥离接线）、头取值（精确→小写两段查找，Message.GetHeaderValue 语义）、Content-Length 数值门、ArgsProcessor 文法 | `BridgeExtData`、`BridgeMessage`、`ArgsMap`、`SINGLE_SWITCHES`、`parseExtData`、`parseExtDataArray`、`parseArgsArray`、`jsonHeadersOrNull`、`headerValueFirst`、`getContentLengthOf`、`buildBridgeMessage`、`parseArgs`、`parseHeaderArg` | #1、`core/util/FileNames` |
| 3 | `entry/src/main/ets/core/bridge/VideoSniffAlgo.ets` | 新 | /media 嗅探纯数学（U6.1 子集，零 @kit）：URL 父目录规整、IsNormalVideo 五条件（含疑似分片集副作用）、Content-Type/URL→扩展名映射、`[EXT] size` 质量文本、Path.GetExtension 子集、标题回写文件名合成 | `SniffState`、`createSniffState`、`parentDirUri`、`isNormalVideo`、`extFromMedia`、`qualityText`、`getExtensionOf`、`generateUpdatedFileName` | #1、`core/util/FileNames`、`core/util/Formatting` |
| 4 | `entry/src/main/ets/core/bridge/CapturedVideoTracker.ets` | 新 | 视频列表桥侧数据半区（VideoTracker.cs 四表投影）：四张插入序 Map（yt/video/hls/dash）、GetVideoList 拼接+按时间升序、Clear+广播、UpdateMediaTitle（仅 yt+video）、单源视频登记（id=UUID+MediaAdded 事件）、按 vid 查找（yt→video→hls→dash 序）、ffmpeg 需求判定 | `CapturedVideoTracker`（单例）、`TrackedVideo`、`VideoLookup`、`TrackerListener` | #1（BridgeVideoItem）、#3（generateUpdatedFileName）、`core/Config`（broadcastConfigChange）、`@kit.ArkTS`（util.generateRandomUUID） |
| 5 | `entry/src/main/ets/core/bridge/BridgeRoutes.ets` | 新 | 八路由业务编排 + /sync 应答组装 + 动作半区：逐路由处理器（含 JSON 门调用）、AddDownload/AddBatchLinks/AddVideoDownload 动作投影（自动开下走既有链、对话框走事件）、/args 分派、共享嗅探状态、BridgeUiEvents 事件面+pending 批量列表 | `handleRoute`、`buildSyncResponse`、`BridgeUiEvents`、`registerBridgeUiEvents`、`getPendingBatchLinks`（processMediaMessage/addDownloadAction/startBridgeAutoDownload 为文件内私有，§5.5，勘误 R4-F5） | #1~#4、`core/Config`、`core/util/FileNames`、`model/DownloadRecord`+`model/DownloadTypes`、`core/db/DownloadStore`、`core/engine/DownloadManager` |
| 6 | `entry/src/main/ets/core/bridge/BridgeServer.ets` | 改 | 泵与分发接线：`dispatchRequest` 改为 classifyRoute→未知 throw→`BridgeRoutes.handleRoute(业务)`→统一 `buildSyncResponse()`；删除本地 buildSyncResponse/notFoundResponse（D1/D2 废止） | 既有导出（BridgeServer/BridgeStats）不变；私有 BridgeResponse 改 import #1 | #1 #5 |
| 7 | `entry/src/test/BridgeRoutes.test.ets` | 新 | Hypium 本地用例：路由分类/JSON 三门/头剥离纯函数/嗅探数学/args 文法（清单见 §7-[A]-3） | default testsuite 注册函数 | #1 #2 #3（零 @kit，本地可加载） |
| 8 | `entry/src/test/List.test.ets` | 改 | testsuite 追加注册 #7 | `testsuite` | #7 |
| 9 | `entry/src/main/ets/probe/units/ProbeBridgeNet.ets` | 新 | 探针共用自连 TCP 客户端（P0-U3 ProbeBridgeClient 提炼为可复用文件，P0-U3 归档文件不动）：connect/send（头+体字节级 POST，**不带 Content-Type/Connection 头**，对齐 connector.js fetch 形态）/等应答（CL 或 close 定界）/take/10s 硬顶 | `ProbeTcpClient` | #1（appendBytes） |
| 10 | `entry/src/main/ets/probe/units/ProbeBridgeRoutes.ets` | 新 | P6-U1 探针 @Component：S1~S9 runner（§6 步骤表）；tracker/路由事件监听器注册（媒体事件计数、对话框事件、剥离后消息观测）；videoList 观测解析 | `ProbeBridgeRoutes`（struct） | #4 #5（监听器）、#9、`probe/units/ProbeBridgeLogic`（splitResponseHead/parseSyncBody 复用）、`probe/core/ProbeKit`/`ProbePage` |
| 11 | `entry/src/main/ets/probe/ProbeIndex.ets` | 改 | PROBE_UNITS 追加 `{unitId:'P6-U1',...}` + else-if 分支 | —（@Entry 页） | #10 |
| 12 | `entry/src/main/resources/base/element/string.json` | 改 | 追加 `probe_p6u1_title`、`probe_p6u1_hint` 两键 | —（资源） | 无 |
| 13 | `entry/src/main/resources/zh_CN/element/string.json` | 改 | 同 #12（中文文案） | —（资源） | 无 |
| 14 | `entry/src/main/resources/en_US/element/string.json` | 改 | 同 #12（英文文案） | —（资源） | 无 |
| 15 | `docs/probe/P6-U1-node-client.js` | 新 | 主机侧 Node 流量模拟与自验脚本（经 `hdc fport tcp:18597 tcp:8597`）：八路由逐一打流+断言（每请求新 TCP、POST 无 Content-Type、连接关闭+CL 定界），逐项打印 PASS/FAIL、退出码汇总 | —（脚本） | #5 的行为契约 |
| 16 | `docs/probe/PROBE-u6-1-bridge-eight-routes.md` | 新 | 探针运行手册（双轨：AI 自动=devecocli/hdc 驱动 Node 脚本自验 + 人工 curl 兜底命令集；未知路径"连接关闭且零应答字节=正确"判定口径） | —（文档） | #10 #15 |
| 17 | `docs/probe/EXPECT-u6-1-bridge-eight-routes.json` | 新 | 机器可读预期表（BEGIN/S1~S9/SUMMARY/END，须过 JSON.parse 校验） | —（JSON） | #16 |

**显式不动的配置文件（有据，§0-5）**：`module.json5`（INTERNET 与 2in1 已在）、`main_pages.json`、`EntryAbility.ets`、`Index.ets`（消费方零改动红线）。**不触碰**：`resourses/` 下任何文件（只读红线）。

## 2. 数据模型与表结构（对照源码逐一核对）

### 2.1 业务表结构：无

无 RelationalStore 新表、无 preferences 新键（/sync 八字段全走既有 `Config` getter 与常量表；tracker 四表是**纯内存会话态**——源版 VideoTracker 同为内存表，GetVideoList 不落盘）。`downloads` 表沿用 U1.1 既有 DDL，桥自动链只调用既有 `store.add`。

### 2.2 八路由请求/应答契约（IpcHttpMessageProcessor.cs:47-86 逐端点）

分派总则：`switch(path)` 八路径**精确匹配**（不剥 query、不校验 method）；每条已知路由业务执行后**统一**走 `OnSyncMessage`（:79）→ `200 OK` + `Content-Type: application/json` + `Cache-Control: max-age=0, no-cache, must-revalidate` + sync JSON 体（§2.3）；业务异常（含 JSON 门失败）→ rethrow → **断连不回应答**（:81-85 + HttpServer.cs:56-63）；`null` 体（JSON 字面量 `"null"`）→ 该路由早退**仍回 sync 应答**；未知路径 → throw → 断连（§0-1）。

| 路由 | 请求体（扩展实测形状，本会话核实） | 业务（源码行） | 成功应答 |
|---|---|---|---|
| `/sync` | 无体（GET；扩展 alarm 轮询 connector.js:25） | 无操作（:53-54） | 200+sync JSON |
| `/download` | chrome `app.js:229-239`：`{url, cookie, requestHeaders{User-Agent,Referer?}, responseHeaders{Content-Length?,Content-Type?}, filename, fileSize, mimeType}`——**键名是 filename 不是 file**（firefox 同，app.js:181）；不带 method/tabUrl/tabId | 反序列化 null→早退；七字段映射+Sanitize+头剥离（:118-136）→ AddDownload（ApplicationCore.cs:208-236：LinkAccepted 命中→静默丢弃；StartDownloadAutomatically(默认 false)=true→以 File??URL末段 自动开下；false→ShowNewDownloadDialog） | 200+sync JSON |
| `/media` | `request-watcher.js:150-189`：`{url, file(=tab标题可 null), requestHeaders, responseHeaders, cookie(多段';'join 可 undefined), method, userAgent, tabUrl, tabId(可'-1')}`——**键名是 file** | null→早退；七字段映射+剥离（:138-156）→ `VideoUrlHelper.ProcessMediaMessage`（本单元纯规则子集 §3.4） | 200+sync JSON |
| `/tab-update` | `{tabUrl, tabTitle}`（app.js:105-108） | null→早退；`VideoTracker.UpdateMediaTitle(msg.TabUrl,msg.TabTitle)`（:108-116；VideoTracker.cs:47-89 仅扫 yt+video 两表） | 200+sync JSON |
| `/vid` | `{vid:'<id>'}`（app.js:273-275） | null→早退；`VideoTracker.AddVideoDownload(msg.Vid)`（:98-106；VideoTracker.cs:313-370：**vid 缺失→ContainsKey(null) 抛 ArgumentNullException→断连**；查不到=静默无操作） | 200+sync JSON |
| `/clear` | `{}`（app.js:278） | `VideoTracker.ClearVideoList()`（:67-69；VideoTracker.cs:27-34 清四表+BroadcastConfigChange） | 200+sync JSON |
| `/link` | ExtensionData **数组**（现版扩展不发——本会话 grep 核实，兼容保留） | null→早退；逐项七字段映射+剥离（:158-179）→ `AddBatchLinks`（ApplicationCore.cs:188-206：跳过空 Url、File=Sanitize(File??URL末段)→ShowDownloadSelectionWindow） | 200+sync JSON |
| `/args` | JSON `List<string>`（如 `["xdm+app://...","--url","http://...","--media"]`） | null 或空表→早退；`ArgsProcessor.Process(args)`（:88-96；ArgsProcessor.cs:15-134 **内层 try/catch 吞掉一切业务异常——不断连**） | 200+sync JSON |

**Newtonsoft 大小写不敏感绑定的等价投影**：`/media` 的 `file` 与 `/download` 的 `filename` 经大小写不敏感属性绑定落到同一 `ExtensionData.File`（ExtensionData.cs:13）。ArkTS 侧解析门取 `file` 键优先、`filename` 次之（两键并存的胜负序是源码"后写覆盖"的简化，扩展从不双发，登记微差异 §4-9）。

### 2.3 /sync 应答体（唯一增量 = videoList 实时化）

字段序/常量与 U0.3 §2.2 完全一致（`SyncFields` interface 字段序契约冻结，`BridgeProtocol.ets:66-77` 零改动）。唯一增量：`videoList` 从 `CapturedVideoTracker.getInstance().getVideoList()` 实时取（对照 `IpcHttpMessageProcessor.cs:332` `ApplicationContext.VideoTracker.GetVideoList()`）。元素 `{id,text,info,tabId}` ← `MediaInfo(ID,Name,Description,TabId)`（VideoTracker.cs:130-158,391-395）。

### 2.4 协议数据模型（ArkTS 形态新增）

| 类型 | 字段 | 源码对照 |
|---|---|---|
| `interface BridgeResponse`（自 BridgeServer 提公共） | `status:number; msg:string; headerNames:string[]; headerValues:string[]; body:Uint8Array` | 应答五元组（buildResponseBytes 入参） |
| `interface BridgeExtData` | `url?:string\|null; cookie?:string\|null; requestHeaders?:BridgeHeaders\|null; responseHeaders?:BridgeHeaders\|null; file?:string\|null; method?:string\|null; userAgent?:string\|null; tabUrl?:string\|null; tabId?:string\|null; tabTitle?:string\|null; referer?:string\|null; fileSize?:number\|null; mimeType?:string\|null; vid?:string\|null` | ExtensionData.cs:9-22 十四属性逐字段（可空统一 null） |
| `interface BridgeMessage` | `url:string\|null; method:string\|null; requestHeaders:BridgeHeaders\|null; responseHeaders:BridgeHeaders\|null; cookies:string\|null; file:string\|null; tabUrl:string\|null; tabId:string\|null; mediaSourceUrl:string\|null` | Message.cs:11-22（method=null 覆盖构造器 "GET" 默认的源语义保留） |
| `interface ArgsMap` | 键=开关名、值=string[] | ArgsProcessor.cs:155-194 `Dictionary<string,List<string>>` |
| `interface SniffState` | `suspectedFragments:Set<string>; m3u8Tabs:Set<string>; referersToSkip:Set<string>` | VideoUrlHelper.cs:30-33 三静态集（U6.1 仅第一集有写入方） |
| `class TrackedVideo` | `id:string; kind:string('yt'/'video'/'hls'/'dash'); file:string; size:number; contentType:string; uri:string; headers:BridgeHeaders\|null; cookies:string\|null; description:string; tabId:string; tabUrl:string; dateAdded:number(epoch ms)` | `KeyValuePair<TDownloadInfo,StreamingVideoDisplayInfo>` 拍平（下载信息半区+展示信息半区，U6.2 分型时再拆） |
| `interface VideoLookup` | `found:boolean; kind:string; name:string; size:number; contentType:string; uri:string; headers:BridgeHeaders\|null; cookies:string\|null` | AddVideoDownload 的命中产物（VideoTracker.cs:319-355） |
| `interface TrackerListener` | `onMediaAdded?:(item:BridgeVideoItem)=>void; onMediaUpdated?:(item:BridgeVideoItem)=>void` | VideoTracker.cs:24-25 两事件 |
| `interface BridgeUiEvents` | `onShowNewDownloadDialog?:(msg:BridgeMessage)=>void; onShowVideoDownloadDialog?:(videoId:string,name:string,size:number,contentType:string)=>void; onShowBatchSelection?:(items:string[])=>void; onAppCommand?:(cmd:string,argv:string[])=>void` | Application.ShowNewDownloadDialog/ShowVideoDownloadDialog/ShowDownloadSelectionWindow/--quit/--first-run 的降级事件面（§0-3） |

头字典换算：JSON `requestHeaders:{名:[值,...]}` → `BridgeHeaders` 平行数组（`Object.keys` 保存 JSON 文本序=插入序）；**字段缺省 → null**（非空容器）——后续 `removeBlockedHeaders`/`headerValueFirst` 收到 null 的行为按源码 NRE→断连处理（§3.2）。

## 3. 关键算法与线程模型翻译说明

### 3.1 分派骨架（BridgeServer.dispatchRequest 重写）

```
dispatchRequest(path, method, body) → BridgeResponse:
  idx = classifyRoute(path)            // ROUTE_PATHS.indexOf，-1=未知
  if (idx < 0) { hilog 'unsupported'; throw Error('Unsupported request: '+path) }  // §0-1 断连
  BridgeRoutes.handleRoute(idx, body)  // 业务；任何 throw（JSON 门/缺字段/NRE 等价物）穿透到泵
  return BridgeRoutes.buildSyncResponse()  // 八路由成功统一 200+sync JSON
```

泵（ClientSession.drain）零改动：`handleRoute`/`buildSyncResponse` 的异常沿既有 catch → `closeSilently`（BridgeServer.ets:274-286 rethrow-关闭通道已就绪）。U0.3 的 `notFoundResponse`/本地 `buildSyncResponse` 删除；`/args` 的内层吞异常（ArgsProcessor.cs:130-133）在 `BridgeRoutes.handleArgsRoute` 内部 try/catch 实现，**不穿透**（§3.6）。

### 3.2 JSON 解析门与七字段映射（IpcHttpMessageProcessor.cs:90,100,110,120,158,160 → BridgeJson.ets）

- **解码**：`utf8Decode(body)`（§3.3）→ `JSON.parse`。非法 JSON → throw（→断连）；体为 `"null"` → 返回 null → 路由早退仍回 sync。
- **形状门**：`parseExtData(text)`——解析产物必须为 object（收到数组/字符串/数字 → throw，对齐 `DeserializeObject<ExtensionData>` 对非对象体的 JsonSerializationException）；逐字段"**存在即验型**"：string 字段须 typeof string、`requestHeaders/responseHeaders` 须 object 且逐值为 string[]、`fileSize` 须 number；缺省字段置 null；多余字段忽略（Newtonsoft 同）。类型不符 → throw → 断连。`parseExtDataArray`：产物须为数组且逐元素为 object（逐元素复用单对象门）；`parseArgsArray`：产物须为数组且逐元素 string（**数字元素不隐式转字符串**——Newtonsoft JsonReader.ReadAsString 的数字强转不复刻，§4-9）。
- **七字段映射** `buildBridgeMessage(data)`（:125-133 逐行）：`url←data.url`、`method←data.method`（null 覆盖默认，照传）、`requestHeaders←data.requestHeaders`、`responseHeaders←data.responseHeaders`、`cookies←data.cookie`、`file←data.file===null?null:sanitizeFileName(data.file)`（FileHelper.cs:15-21；复用 FileNames.sanitizeFileName 的 D6 修正版，§4-7）、`tabUrl←data.tabUrl`、`tabId←data.tabId`；随后 `requestHeaders=removeBlockedHeaders(requestHeaders)`——**requestHeaders 为 null 时 throw**（源码 Message 构造器初始化空字典后被 null 覆盖，RemoveBlockedHeaders 取 Keys → NRE → 断连的等价物）。**仅 /download、/media、/link 调 buildBridgeMessage；/vid、/tab-update、/args、/clear、/sync 不做映射不剥离**（源码同）。
- **头取值**（Message.cs:85-126 语义）：`headerValueFirst(h,key)`——精确键 → 小写键两段查找，命中取值表 [0]；miss 或 h 为 null → null。`getContentLengthOf(msg)`（Message.cs:128-137）：ResponseHeaders 的 `Content-Length` 首值，全串十进制（`new RegExp('^[+-]?[0-9]+$')`）→ Number；缺省/非数字/空串 → 0（try/catch 吞掉 Int32.Parse 异常→0 的源语义）。

### 3.3 头剥离与 UTF-8 解码（纯函数）

**removeBlockedHeaders(h)**（IpcHttpMessageProcessor.cs:376-394 逐语义）：14 项黑名单 `{accept, if, authorization, proxy, connection, expect, TE, upgrade, range, cookie, transfer-encoding, content-type, content-length, content-encoding}`（:19-20 逐串）。对每个黑名单名：在 `h.names` 中找**首个** `toLowerCase()` 相等（InvariantCultureIgnoreCase 精确**等值**——"If-None-Match" 不被 "if" 命中）的键，删除该键整条（names/values 同步 splice）；每个黑名单名**最多删一个键**；返回新容器（入参不变）。**只作用于 RequestHeaders**（ResponseHeaders 由调用方不传——扩展的 Content-Type/Content-Length 在响应头必须原样保留供嗅探/记录用）。注：源黑名单含 "TE" 大写混合——等值比较对小写化后比较，故实现统一 `toLowerCase` 双边。

**utf8Decode(bytes)**（对齐 `Encoding.UTF8.GetString` 容错 + TextDecoder 默认替换级）：逐字节状态机——1/2/3/4 字节序列按 UTF-8 规则解码（代理对由 4 字节序列产出的码点直接进 string）；**非法序列一次失败恰产一个 U+FFFD**（R3-F1 修正为 .NET replacement fallback 同貌：①起始字节即非法（孤立延续字节/0xC0-0xC1/0xF5-0xFF）单字节消费；②截断的多字节或续字节非法 → 起始字节+已确认合法续字节整体消费（原稿"前进 1 字节重同步"会使截断序列再产孤立续字节 FFFD、与 .NET 及单测矛盾）；③完整但码点非法（overlong/代理区/超 0x10FFFF）整序列消费）。与既有 `utf8Encode` 互为逆（Hypium round-trip 用例）。保持 BridgeProtocol 零 @kit（不 import util.TextDecoder），本地单测可加载。

### 3.4 /media 纯规则子集（VideoUrlHelper.cs:35-65,67-90,615-700 → VideoSniffAlgo.ets + BridgeRoutes）

`processMediaMessage(msg)`（:35-65 链序保留，未落分支为 no-op 锚）：

1. `contentType = headerValueFirst(msg.responseHeaders,'Content-Type')`；**null（键缺省）→ return**（:37-41）。
2. IsYtFormat（contentType 小写含 `application/json`，:750-761）→ **U6.1 no-op**（manifest 下载=网络，U6.2）。
3. IsHLS(contentType 含 mpegurl/.m3u8/m3u8) || URL 含 .m3u8 → **U6.1 no-op**（U6.2）。
4. IsDASH || URL 含 .mpd → **U6.1 no-op**（U6.2）。
5. ProcessYtDashSegment → **U6.1 no-op**（U6.2）。
6. `isNormalVideo(state, contentType, msg.url, getContentLengthOf(msg), msg.tabId, minBytes=Config.getMinVideoSize()*1024)` → 真 → `processNormalVideo(msg, contentType)`。

`isNormalVideo`（:67-90 五条件 1:1，大小写敏感性逐处保留）：
① `size>0 && size<minBytes` → false（Config.cs:116 MinVideoSize 默认 1024KB）；② `tabId` 非空且 `state.m3u8Tabs.has(tabId)` → false（**U6.1 恒空集**——写入方在 HLS/DASH 处理，U6.2）；③ `url.toLowerCase()` 含 `init.mp4` → `state.suspectedFragments.add(parentDirUri(url))`、false（**有副作用，单线程事件循环下安全**）；④ `state.suspectedFragments.has(parentDirUri(url))` → false；⑤ `contentType!==null && !(contentType 含 f4f || 含 m4s || url 含 abst || url 含 f4x || url 含 .fbcdn || url 含 http://127.0.0.1:9614)`——④⑤的 url 比较用**原始大小写**（C# string.Contains 序数敏感），仅③先 toLowerCase（源 :77 同）。

`parentDirUri(url)`：RFC 3986 相对引用 `"."` 解析的等价物（源 `new Uri(new Uri(url), ".").AbsoluteUri`，:79/:82）——去 query/fragment → 取路径末段前缀：`scheme://authority + path截至最后一个'/'`（末段为空则原样）；`https://h/a/b/init.mp4?x=1 → https://h/a/b/`、`https://h/a/b/ → https://h/a/b/`、`https://h/init.mp4 → https://h/`。纯函数，Hypium 用例钉死。

`processNormalVideo`（:615-695 逐行）：
1. `isMediaFragment(referer)`（:873-886）——referer（请求头 `Referer` 首值）在 `state.referersToSkip` 则跳过；**U6.1 恒空集 → 恒 false**（SHA1 键与写入方留 U6.2，§4-2）。守卫调用保留（U6.2 填表即生效）。
2. `file = msg.file ?? fileNameFromUrl(msg.url)`；空串则再取 `fileNameFromUrl`（:627-630）。
3. `ext = extFromMedia(contentType.toLowerCase(), url.toLowerCase())`（:631-675 映射序逐行）：`video/mp4→mp4`、`video/x-flv→flv`、`video/webm→mkv`、`含 matroska 或含 mkv→mkv`、**`type==='audio/mpeg'（等值）|| 含 'audio/mp3'→mp3`**、`含 audio/aac→aac`、`含 audio/mp4→m4a`、`url 含 .mp4→mp4`、`.mkv→mkv`、`.ts→ts`；否则 **null → return**。
4. `size`：`Content-Length` 响应头首值——**缺省 → throw**（源 :686 `long.Parse(null)` 抛 → 断连的 1:1 保留）；非全串十进制 → throw（long.Parse 同）。已知 size（isNormalVideo 已验）此处恒合法，throw 分支只对畸形流量生效。
5. 登记：`tracker.addSingleSourceVideo(file=sanitizeFileName(file)+'.'+ext, size, contentType 原值, uri=msg.url, headers=msg.requestHeaders, cookies=msg.cookies, description=qualityText(ext,size), tabId=msg.tabId, tabUrl=msg.tabUrl)`。`qualityText(ext,size)`=`'['+ext.toUpperCase()+'] '+(size>0?formatSize(size):'')`（:687 逐字，size=0 时尾随空格保留）。

### 3.5 tracker 数据半区（VideoTracker.cs → CapturedVideoTracker.ets）

- **四表**：`ytMap/videoMap/hlsMap/dashMap: Map<string,TrackedVideo>`（Map 迭代序=插入序=GenericOrderedDictionary keys 序同构；lock(this) 不复刻——单线程事件循环，MIGRATION_PLAN 决策 2 精神）。**U6.1 仅 video 表有写入方**（addSingleSourceVideo），另三表为 U6.2 预留（读取路径全部就位）。
- `getVideoList()`（:130-158）：按 **yt→video→hls→dash** 拼接后按 `dateAdded` **升序**排序（`Array.sort` 稳定排序——C# List.Sort 不稳定但同毫秒并列时拼接序即为观测序，稳定排序是源观测序的保守超集）→ 逐项映射 `BridgeVideoItem{id, text:file, info:description, tabId}`。
- `clearVideoList()`（:27-34）：清四表 + `Config.getInstance().broadcastConfigChange()`（ApplicationContext.BroadcastConfigChange 同位）。
- `updateMediaTitle(tabUrl, tabTitle)`（:47-89）：**只扫 yt+video 两表**；条件 `entry.tabUrl 非空 && === tabUrl`；效果 `entry.file = generateUpdatedFileName(entry.file, tabTitle)`（VideoSniffAlgo：`ext=getExtensionOf(oldFile)`（Path.GetExtension 子集：末段最后一个'.'起、无'.'→''、'.bashrc'→整段）；`sanitizeFileName(newName)` 后 ext 非空则拼接）→ 逐命中项触发 `onMediaUpdated`。
- `addSingleSourceVideo(...)`（:260-275 单源重载投影）：`id=util.generateRandomUUID()`（Guid.NewGuid().ToString 对应物）、`dateAdded=Date.now()`（DateTime.Now→epoch ms，U1.1 D1 先例）、入 video 表、触发 `onMediaAdded` + `broadcastConfigChange()`（ShowMediaNotification 通知半区 U6.2 拍板，本单元不弹）。
- `lookupVideoDownload(videoId)`（:313-355 的读取半区）：按 yt→video→hls→dash 查找；**vid 为 null/undefined → throw Error**（ContainsKey(null)→ArgumentNullException→断连的 1:1）；未命中 → `{found:false}`（静默无操作锚）。LinkRefresher.LinkAccepted 前置守卫（:321/:329）**未迁移恒 false**，注释锚登记（§4-3）。
- `isFFmpegRequiredForDownload(id)`（:91-94）：yt/hls/dash 含 id → true。`BridgeRoutes.isFFmpegOK(id)`（:372-376 投影）：`!required → true`；required → **false**（FFmpegMediaProcessor.IsFFmpegInstalled 的 U6.1 降级——U0.4 未做，§4-6；U7.2 接真值）。
- 监听器：`registerTrackerListener/unregisterTrackerListener`（Config.onConfigChanged 同款数组注册表；逐监听器 try/catch 吞异常防回调塌缩；遍历拷贝防回调内注销塌缩）。

### 3.6 /args 文法与分派（ArgsProcessor.cs:15-134,155-194 → BridgeJson.parseArgs + BridgeRoutes.handleArgsRoute）

**parseArgs(args)**（:155-194 文法 1:1）：跳过 `xdm+app://` 前缀项（:161-163）；`-` 开头项为开关名——单值开关集 `SINGLE_SWITCHES={'--background','--first-run','--restore-window','--quit','--media','--media-clear'}`（:15，**后不吞值**），否则为名值开关的当前名（:165-179）；裸值项：无当前名 → `options['--url']=[arg]`（**整体替换非追加——多裸值时后者覆盖且 count 恒 1**，:182-184），有当前名 → 追加到当前名值表并复位（:186-190）。

**分派序**（:20-128，**整体包 try/catch 吞异常**——`--media-tab-url` 缺 `--media-tab-title` 等键缺失异常只记日志不外抛，仍回 sync 应答，:130-133）：
1. `--media-tab-url` → `tracker.updateMediaTitle(args['--media-tab-url'][0], args['--media-tab-title'][0] ?? '')` → return（:21-27）。
2. `--media-vid` → vid 动作（同 /vid 核心，§3.7）→ return（:28-33）。
3. `--media-clear` → `tracker.clearVideoList()` → return（:34-37）。
4. `--url` 且 count===1 → 组装 message：`url`；`requestHeaders=空容器`（**本路径非 null**，:44）；`-H`/`--header` 逐项 `parseHeaderArg('Name:Value')`（首个':'且下标≥1、两端 Trim——ParsingHelper.cs:18-21 逐语义；键已存在则追加值表否则新建，:136-153）；`--cookie`→cookies、`-C`→cookies（后者覆盖，:53-68）；`--output`→file、`-o`→file（**不 sanitize**——源此路径原值直传，:57-64）；`--known-file-size`→responseHeaders['Content-Length']=[v]、`--known-mime-type`→responseHeaders['Content-Type']=[v]（:69-76）；`--media-source-url`→mediaSourceUrl（字段保留，下游 U6.2 消费）；`--tab-url`/`--tab-id`（:81-88）。**不做头剥离**（源 /args 无 RemoveBlockedHeaders 调用）。然后：无 `--media` → `addDownloadAction(msg)`；有 → `processMediaMessage(msg)`（:90-97）。
5. `--quit` → log + `onAppCommand('quit',[])`（Environment.Exit 降级 §0-3）。
6. 无 `--background` → `--first-run` ? `onAppCommand('first-run',[])`（RunOnLogon+SaveConfig+ShowBrowserMonitoringDialog 均降级）: `onAppCommand('activate',[])`（ShowAndActivate 降级）（:100-128）。

### 3.7 动作半区（ApplicationCore.cs:188-236 + VideoTracker.cs:356-369 → BridgeRoutes）

- `addDownloadAction(msg)`（:208-236 状态机）：LinkAccepted 守卫注释锚恒 false（Index.ets:468 同款登记法）；`Config.getStartDownloadAutomatically()`=true → `startBridgeAutoDownload(file=sanitizeFileName(msg.file ?? fileNameFromUrl(msg.url)), size=getContentLengthOf(msg), url=msg.url, FileNameFetchMode.FileNameAndExtension)`；false → log + `onShowNewDownloadDialog(msg)` 事件（ShowNewDownloadDialog UI 留 U6.3）。
- `videoDownloadAction(vid)`（VideoTracker.cs:313-370 动作段）：`lookup=tracker.lookupVideoDownload(vid)`（null vid 在 lookup 内 throw）；!found → 静默 return；found → `getStartDownloadAutomatically() && isFFmpegOK(vid)` ? `startBridgeAutoDownload(sanitizeFileName(lookup.name), lookup.size, lookup.uri, FileNameFetchMode.ExtensionOnly)`（:358-363 单源分支；yt/hls/dash 分支 U6.2）: log + `onShowVideoDownloadDialog(vid,name,size,contentType)` 事件（:367 降级）。
- `startBridgeAutoDownload(fileName,size,url,fetchMode)`（**唯一建链点**，红线）：`targetDir=Config.getDownloadDir()`；`record=newDownloadRecord(fileName,targetDir,size,'Http',url,true,null,null)`（DownloadRecord.ets:89-107）→ `record.fileNameFetchMode=fetchMode` → `store.add(record).then(ok=>{ok? DownloadManager.getInstance().admitNew(record) : log}).catch(log)`（Index.ets:449-459 同构；**不更新 Index 内存 DS**——事件经既有事件袋流向 Index，handler 空指针安全，§0-7；UI 完整接线 U6.3）。admitNew 在 manager 未 init 时防御 no-op（DownloadManager.ets:171-175 既有行为，真机流程 Index 先 init）。
- `/link`（:188-206）：逐项跳过空 url；`file=sanitizeFileName(item.file ?? fileNameFromUrl(item.url))`；收集 `{url,file}` → **pending 列表**（内存 `getPendingBatchLinks()` 供 U6.3 勾选窗消费；勘误 R4-F5：现实现只存 url 串——U6.3 消费前须改为 {url,file} 对或从 url 重算并保留 item.file 信息）+ log + `onShowBatchSelection(urls)` 事件。

### 3.8 线程模型映射

沿用 U0.3 §3.7 全套（listen 事件回调 + 每连接 ClientSession 泵 + busy/pending 串行化，**零改动**）。本单元新增面全部落在泵的同步段：JSON 解析/嗅探数学/tracker 表操作均为百字节~微秒级 CPU，主事件循环无压力；`store.add` 的 .then 回调在事件循环续体执行，admitNew 语义与 Index 链一致（提交序串行）。**不用 TaskPool**（MIGRATION_PLAN 决策 2 的例外说明同 U0.3 §3.7：单例与 socket 不可跨线程）。tracker 四表无锁（单线程单写者）；`suspectedFragments` 等 SniffState 集合同理。

## 4. 有意差异清单（全部；★=本单元新增，☆=沿用既有已登记项）

1. ★**未知路径静默断连（推翻 U0.3 D2 前瞻注记 §0-2）**：404 空体 → `throw`→closeSilently（1:1 IpcHttpMessageProcessor.cs:76-77 + HttpServer.cs:56-63）。U0.3 D1（七路由 404）随业务补全自然消亡；D2 由本项取代。探针/Node/curl 判定口径同步改写（§6、§0-1）。
2. ★**/media 仅纯规则子集**：YT manifest 下载、HLS/DASH/segment 识别处理、`m3u8MpdTabs`/`referersToSkip`（SHA1）写入方全部留 U6.2（读取守卫就位、恒空集）。暂态效应：真实 HLS `.ts` 段可能误入 videoList，U6.2 全链落地即消除（受控探针流量不触发）。
3. ★**LinkRefresher.LinkAccepted 未迁移 → 恒 false**（/download、/vid 的重复链接不去重；U6.x 补，Index.ets:468 注释锚同款登记）。
4. ★**请求头/Cookie 不注入引擎**：解析与剥离照做，但 DownloadRecord 无 headers 字段、PieceGrabber 自建 sixDefaultHeaders（PieceGrabber.ets:462）→ 桥发起的下载暂不带浏览器 cookie。引擎侧注入点（HttpClient.open 的 header 参数已支持，HttpClient.ets:78）**M6 验收前（U6.3）必须接通**——登记为最高优先跟进项。
5. ★**UI 动作降级为事件**：ShowNewDownloadDialog/ShowVideoDownloadDialog/ShowDownloadSelectionWindow（U4.2 已有 DownloadSelectionDialog 组件，接线留 U6.3）、`--quit` 进程退出、`--first-run`/`--background` 主窗激活（含 RunOnLogon 写入）→ `BridgeUiEvents` 事件+log+pending 列表（§0-3）。
6. ★**IsFFmpegOK 降级**：U0.4 未做 → 单源恒 true、yt/hls/dash 恒 false（自适应源视频下载降级到对话框事件）；U7.2 接 FFmpegMediaProcessor.IsFFmpegInstalled 真值。
7. ☆**SanitizeFileName 复用 FileNames.sanitizeFileName（U1.2 D6 修正版）**：取 '/'与'\\' 较大下标段，不复刻源 :17-18 死赋值怪癖（'/' 切割结果被 '\\' 切割覆盖）。
8. ☆**MIGRATION_PLAN §3 既有降级**：Chrome Native Messaging 不复刻、register.html 注册省略（决策 5）——本单元 none 新增。
9. ★**JSON 门严格类型**：Newtonsoft 的数字→字符串隐式强转（如 `url:123` 读成 `"123"`、args 表 `[1]` 读成 `["1"]`）不复刻——类型不符即 throw 断连；`file`/`filename` 双键并存取 file 优先（源"后写覆盖"，扩展从不双发）。**例外（R2-F1 补记）**：头值数组的 number 元素按 `JsonReader.ReadAsString` 语义 `String(v)` 强转收编（`BridgeJson.jsonHeadersOrNull`）——chrome `app.js:225-229` 主线流量 `responseHeaders["Content-Length"]=[fz]`（`fz=+size` 为 number，调用点 :77-79 传 `download.fileSize`）、firefox `app.js:170` 同，严格 throw 会误杀真实扩展 /download 且此时浏览器下载已被 `chrome.downloads.cancel+erase` 取消、用户下载直接丢失；其余元素类型（boolean/object/null 等）仍 throw。初稿仅以 `url:123`/`args[1]` 为例登记严格门，未覆盖头值数字这一真实客户端契约，审查轮修正。
10. ★**桥自动链不更新 Index 内存 DS**：record 落库+引擎运行+事件流向 Index（handler null 安全），但主列表 UI 不即时显示该条（重启/刷新后 store 可见）；完整接线 U6.3。
11. ★**/vid 缺 vid → 断连（1:1 保留，非差异，防"顺手防御"故列锚）**：源 ContainsKey(null)→ArgumentNullException→断连；不得改成静默忽略。
12. ☆**method 字段保留观测**（U0.3 差异 #6 延续）：仅 stats/日志，不参与路由。

## 5. 各文件实现要点（接口面，可直接照做）

### 5.1 BridgeProtocol.ets（改，纯增量；文件头补 U6.1 注记段）

```typescript
export interface BridgeResponse { status: number; msg: string; headerNames: string[];
  headerValues: string[]; body: Uint8Array }                    // 自 BridgeServer 提公共
export const BLOCKED_HEADERS: string[] = ['accept','if','authorization','proxy','connection',
  'expect','TE','upgrade','range','cookie','transfer-encoding','content-type','content-length',
  'content-encoding'];                                          // :19-20 逐串（'TE' 大小写保真）
export function removeBlockedHeaders(h: BridgeHeaders): BridgeHeaders  // §3.3；新容器；h 各键 toLowerCase 等值
export function utf8Decode(bytes: Uint8Array): string                  // §3.3 宽松解码，非法→U+FFFD 重同步
export function classifyRoute(path: string): number                    // ROUTE_PATHS.indexOf；-1=未知
```

### 5.2 BridgeJson.ets（新，零 @kit）

```typescript
export interface BridgeExtData { /* §2.4 十四可空字段 */ }
export interface BridgeMessage { /* §2.4 九字段 */ }
export interface ArgsMap { [key: string]: string[] }   // 注：ArkTS 允许 index signature；或 Map<string,string[]>——编码员择一，测试同构
export const SINGLE_SWITCHES: string[] = ['--background','--first-run','--restore-window',
  '--quit','--media','--media-clear'];
export function parseExtData(text: string): BridgeExtData | null        // §3.2；坏 JSON/形状→throw；'null'→null
export function parseExtDataArray(text: string): BridgeExtData[] | null // /link；元素逐个过单对象门
export function parseArgsArray(text: string): string[] | null           // /args；非字符串元素→throw
export function jsonHeadersOrNull(v: object | null): BridgeHeaders | null  // JSON 头字典→平行数组；值非 string[]→throw
export function headerValueFirst(h: BridgeHeaders | null, key: string): string | null  // 精确→小写两段；[0]；miss→null
export function getContentLengthOf(responseHeaders: BridgeHeaders | null): number      // §3.2；缺省/垃圾→0
export function buildBridgeMessage(data: BridgeExtData): BridgeMessage  // §3.2 七字段+sanitize+剥离；requestHeaders null→throw
export function parseArgs(args: string[]): ArgsMap                      // §3.6 文法；--url 整体替换语义
export function parseHeaderArg(text: string): string[] | null           // 'Name:Value'→[name,value]；首':' 下标<1→null
```

### 5.3 VideoSniffAlgo.ets（新，零 @kit）

```typescript
export interface SniffState { suspectedFragments: Set<string>; m3u8Tabs: Set<string>;
  referersToSkip: Set<string> }
export function createSniffState(): SniffState
export function parentDirUri(url: string): string                       // §3.4 RFC3986 '.' 解析等价
export function isNormalVideo(state: SniffState, contentType: string | null, url: string,
  size: number, tabId: string | null, minBytes: number): boolean        // §3.4 五条件；③有副作用
export function extFromMedia(typeLower: string, urlLower: string): string | null  // §3.4 映射序
export function qualityText(ext: string, size: number): string          // '[EXT] size'；size=0 尾随空格保留
export function getExtensionOf(name: string): string                    // Path.GetExtension 子集
export function generateUpdatedFileName(oldFile: string, newName: string): string  // §3.5
```

### 5.4 CapturedVideoTracker.ets（新）

```typescript
export class TrackedVideo { /* §2.4 字段 */ }
export interface VideoLookup { found: boolean; kind: string; name: string; size: number;
  contentType: string; uri: string; headers: BridgeHeaders | null; cookies: string | null }
export interface TrackerListener { onMediaAdded?: (item: BridgeVideoItem) => void;
  onMediaUpdated?: (item: BridgeVideoItem) => void }
export class CapturedVideoTracker {                 // 单例
  static getInstance(): CapturedVideoTracker
  getVideoList(): BridgeVideoItem[]                 // yt→video→hls→dash 拼接 + dateAdded 升序稳定排序
  clearVideoList(): void                            // 清四表 + Config.broadcastConfigChange()
  updateMediaTitle(tabUrl: string, tabTitle: string): void   // 仅 yt+video；generateUpdatedFileName；onMediaUpdated
  addSingleSourceVideo(file: string, size: number, contentType: string, uri: string,
    headers: BridgeHeaders | null, cookies: string | null, description: string,
    tabId: string | null, tabUrl: string | null): void      // video 表；UUID+now；onMediaAdded+广播
  lookupVideoDownload(videoId: string | null): VideoLookup  // vid null→throw；yt→video→hls→dash
  isFFmpegRequiredForDownload(id: string): boolean
  registerTrackerListener(l: TrackerListener): void / unregisterTrackerListener(l): void
}
```

### 5.5 BridgeRoutes.ets（新）

```typescript
export interface BridgeUiEvents { /* §2.4 四回调 */ }
export function registerBridgeUiEvents(l: BridgeUiEvents): void / unregisterBridgeUiEvents(l): void
export function getPendingBatchLinks(): string[]            // /link 累积（内存，U6.3 消费）
export function handleRoute(routeIndex: number, body: Uint8Array): void   // 业务；throw=断连；/args 内层吞
export function buildSyncResponse(): BridgeResponse        // Config 四 getter + 三常量表 + tracker.getVideoList()
// 文件内私有：processMediaMessage / processNormalVideo / addDownloadAction / videoDownloadAction /
//   handleArgsRoute / isFFmpegOK / startBridgeAutoDownload / 共享 SniffState 单例
```

`buildSyncResponse`＝U0.3 `BridgeServer.buildSyncResponse`（BridgeServer.ets:327-346）平移+videoList 换 tracker 实时值，`SyncFields` 字段序零改动。

### 5.6 BridgeServer.ets（改）

`dispatchRequest`（:303-322）按 §3.1 重写为 8 行骨架；删除 `buildSyncResponse`（:327-346）与 `notFoundResponse`（:350-354）；`BridgeResponse` 改 import BridgeProtocol；文件头注释补 U6.1 段（D1/D2 废止声明）。**ClientSession 泵、start/stop/stats、EntryAbility 接线零改动。**

### 5.7 探针三件套（#9/#10/#11）与资源

- `ProbeBridgeNet.ets`：`ProbeTcpClient`——`connect()/sendBytes(bytes:Uint8Array)/awaitResponse()/awaitClose(graceMs)/take()/isClosed()/close()`；请求构造辅助 `postJson(path, jsonText)`（**无 Content-Type、无 Connection 头**，Content-Length=字节长；connector.js:45 fetch 形态）与 `get(path)`。会话代际守卫与 10s 硬顶沿用 P0-U3 惯例（ProbeBridge.ets:41-48 常量平移）。
- `ProbeBridgeRoutes.ets`：`PROBE_STEPS` S1~S9（§6）；本地纯辅助 `videoListSummary(syncBodyText)`（JSON.parse→Record<string,Object> 窄化→取 videoList 长度/首元素 text/id）+ `commasToSlash` 消毒（P0-U3 同款）；tracker/BridgeUiEvents 监听器计数（mediaAdded/mediaUpdated/videoDialog/newDownloadDialog/batch 事件袋）。
- `ProbeIndex.ets`：表尾追加 `{unitId:'P6-U1', title:$r('app.string.probe_p6u1_title')}` + else-if 分支（只加不改惯例）。
- 三份 string.json：`probe_p6u1_title`＝`扩展桥八路由探针（P6-U1）`（en_US 同义英文）、`probe_p6u1_hint`＝一句"AI 自动=主机侧 Node 脚本；人工兜底=curl 命令集见手册"提示。

### 5.8 Node 脚本 P6-U1-node-client.js（主机侧自验）

`node:net` 直连 127.0.0.1:18597（fport 转发）。每请求新 TCP、POST 无 Content-Type/Connection、以"服务端关连接 + 已读 Content-Length 字节"为完整应答信号（客户端契约 §2.2 脚注）。步骤：①GET /sync 基线（JSON 八字段+videoList 空）②POST /clear→200 ③POST /media（video/mp4+5MB）→/sync videoList=1 ④POST /tab-update→text 回写 ⑤POST /vid 未命中(200 列表不变)/命中(200，auto=false→对话框事件不可主机侧观测，仅验应答) ⑥POST /download（filename 形）→200 ⑦POST /args（--media-tab-url 组+--url --media --known-mime-type video/mp4 组）→列表+2 ⑧POST /link 数组→200 ⑨GET /sync?x=1→**连接关闭且零应答字节=PASS** ⑩POST /download 体 'not json'→同上。逐项打印 `PASS/FAIL <编号> <观测>`，末行 `SUMMARY pass=N fail=M`，`process.exitCode = fail>0?1:0`。

## 6. 探针步骤设计（P6-U1，autoStart=true 全自动）

拉起/抓取命令沿用 PROBE_SPEC §3 与 U0.3 手册口径。所有行 hilog domain 0xD001、tag XDM_PROBE、`%{public}s`；每步恰一行 <1500B；值白名单（含逗号值预转换 '/'）。**S1 前置**：应用已由 EntryAbility 启动桥；tracker 监听器在 BEGIN 后立即注册（计数从 0 起）。

| 步骤 | 操作 | 观测点（emit 键） | 标记行示例 |
|---|---|---|---|
| BEGIN | ProbePage autoStart | runId、filesDir | `[XDM_PROBE][P6-U1][BEGIN] runId=101530 filesDir=...` |
| S1 就绪+/clear 清空 | stats 快照→POST /clear→解析应答体 | started、boundPort、clearStatus、baseVideoCount、requestsBefore | `... clearStatus=200 baseVideoCount=0` |
| S2 /media 嗅探→列表增长 | POST /media（url/file=Test Clip/tabId=100/tabUrl=www.youtube.com/watch?v=abc/method=GET/requestHeaders{Referer,User-Agent}/responseHeaders{Content-Type:[video/mp4],Content-Length:[5242880]}/cookie=a=b）→解析应答 videoList | mediaStatus、mediaListCount、mediaTextSuffix、mediaInfoPrefix、mediaAddedEvents、vid | `... mediaStatus=200 mediaListCount=1 mediaTextSuffix=.mp4 mediaInfoPrefix=[MP4] mediaAddedEvents=1 vid=3f2a...` |
| S3 /tab-update 标题回写 | POST /tab-update{tabUrl 同上, tabTitle:New Title}→解析应答 | tabUpdateStatus、tabTextPrefix、tabExtKept、mediaUpdatedEvents | `... tabUpdateStatus=200 tabTextPrefix=New Title tabExtKept=true mediaUpdatedEvents=1` |
| S4 /vid 未命中/命中 | POST /vid{vid:nonexistent}→解析；POST /vid{vid:S2 的 id}→解析（auto=false 默认→对话框事件计数） | vidMissStatus、vidMissListCount、vidHitStatus、videoDialogEvents | `... vidMissStatus=200 vidMissListCount=1 vidHitStatus=200 videoDialogEvents=1` |
| S5 /download 接管+头剥离观测 | POST /download（chrome 形 filename=setup.exe、cookie、requestHeaders{User-Agent,Cookie,Accept,Accept-Encoding}、responseHeaders{Content-Length,Content-Type}）→解析；对话框事件携带的 BridgeMessage 检查剥离结果 | downloadStatus、downloadDialogEvents、uaPreserved、cookieStripped、acceptStripped、acceptEncodingPreserved | `... downloadStatus=200 downloadDialogEvents=1 uaPreserved=true cookieStripped=true acceptStripped=true acceptEncodingPreserved=true` |
| S6 /args 参数链 | POST /args `["xdm+app://x","--media-tab-url",<tabUrl>,"--media-tab-title","Args Title"]`→解析；再 POST /args `["--url","http://h/v/args.mp4","--media","--known-mime-type","video/mp4","--known-file-size","2097152"]`→解析 | argsTabStatus、argsTabPrefix、argsMediaStatus、argsMediaCount | `... argsTabStatus=200 argsTabPrefix=Args Title argsMediaStatus=200 argsMediaCount=2` |
| S7 /link 兼容路由 | POST /link `[{url,file},{url:'',file:x}]`→解析 | linkStatus、batchEvents、pendingLinks | `... linkStatus=200 batchEvents=1 pendingLinks=1` |
| S8 错误处理 | GET /sync?x=1；POST /download 体 `not json`；POST /vid 体 `{}`（缺 vid）——三者各新连接 | unknownClosed、badJsonClosed、vidMissingClosed | `... unknownClosed=true badJsonClosed=true vidMissingClosed=true`（closed && 无完整应答头块的谓词编码） |
| S9 最终 /sync 全量 | GET /sync→splitResponseHead+parseSyncBody+videoListSummary；stats 终快照 | syncStatus、fieldCount、fieldOrder、finalVideoCount、connections、requests | `... syncStatus=200 fieldCount=8 fieldOrder=enabled/fileExts/... finalVideoCount=2` |
| SUMMARY | end(ok) 聚合 | 各段关键键 | `... [SUMMARY] S1=clearStatus=200|S2=mediaListCount=1|...` |
| END | ok、steps=9、elapsedMs | | `... [END] ok=true steps=9 elapsedMs=3420` |

失败路径：任一步 catch → 该步输出 errCode/errMessage 键组仍恰一行；S8 三连接失败记 err 不中断。**观测红线**：布尔键均为直接观测谓词（closed/status/计数），不含 PASS/FAIL 词；期望只在 EXPECT 表。

**主机侧双轨（手册承载）**：AI 自动轨=`hdc fport tcp:18597 tcp:8597 && node docs/probe/P6-U1-node-client.js`（§5.8 十步，退出码 0=全绿）；人工兜底轨=手册 §4 的 curl 命令集（每命令配"预期现象"，未知路径条目明示"curl 报 Empty reply from server / 连接被关 = 正确"）。两轨判定都汇入 EXPECT 表 note。

## 7. 单元验收测试要点

### [A] 静态门禁（编码员每轮自跑）

1. **hvigor 全量构建**零 error 零新 warning。ArkTS 严格子集自查：对象字面量具 interface 类型（BridgeExtData/BridgeMessage/SyncFields/ProbeStepDef…）；禁正则字面量/any/解构/for...in；throw 只抛 Error（arkts-limited-throw）；Set/Map 替代字典；socket 回调参数类型标注。
2. **结构断言**：`grep -rn "XDM_PROBE" entry/src/main/ets/core` 零命中；`grep -rn "import.*probe" entry/src/main/ets/core` 零命中；`grep -n "P6-U1" entry/src/main/ets/probe/ProbeIndex.ets` 命中注册与分支；`git diff --stat` 确认 module.json5/main_pages.json/EntryAbility.ets/Index.ets 零改动；BridgeServer.ets 中 notFoundResponse 零命中（D1/D2 废止）。
3. **Hypium 本地用例清单**（`BridgeRoutes.test.ets`；执行环境注记同 U0.3 §7-3：本地 runner 本会话不可验证，用例入库不碍编译门禁，编码员实跑或统一回归）：
   - `classifyRoute`：八路径按 ROUTE_PATHS 序返回 0~7；`/sync?x=1`、`/sync/`、`''` → -1。（3 断言组）
   - `removeBlockedHeaders`：①14 项逐一存在且精确等值（含大写 `Cookie`/混合 `cOnnection`）全被删；②`Accept` 删而 `Accept-Encoding` 留、`If-None-Match` 留（等值非前缀）；③同名双键（`cookie`+`Cookie`）只删首个；④入参容器不变（纯函数）；⑤ResponseHeaders 形容器传入不被特殊处理（函数无侧差别）。（黑名单精确等值/一次删除/仅请求头三断言组——单元验收指定项）
   - `utf8Decode`：①ASCII 恒等；②`utf8Encode('下载')` round-trip；③emoji 4 字节 round-trip；④`0xFF` 孤立字节→U+FFFD；⑤3 字节序列截断→U+FFFD。
   - `parseExtData`：①全字段对象；②`'null'`→null；③`'not json'`→throw；④`filename` 键落到 file（双键兼容）；⑤`url:123`→throw；⑥`requestHeaders:{a:'b'}`（值非数组）→throw；⑦缺省字段全 null；⑧多余字段忽略；⑨顶层数组体→throw。
   - `parseExtDataArray`：①两元素；②`'null'`→null；③对象体→throw；④元素非对象→throw。
   - `parseArgsArray`：①字符串表；②`'null'`→null；③`[]`→[]；④`[1]`→throw。
   - `parseArgs` 文法：①单值开关集不吞值（`['--quit','v']`→`--quit:[]` 且 `v` 落 `--url`）；②名值开关（`['-H','a:1','-H','b:2']`→`-H:[a:1,b:2]`）；③双裸值→`--url` count=1 取后者（整体替换语义）；④`xdm+app://` 前缀跳过；⑤`parseHeaderArg('Name:Value')`→['Name','Value']；`'novalue'`→null；`':v'`→null（下标<1）。
   - `headerValueFirst`：①精确键命中；②小写键兜底命中；③多值取 [0]；④缺省→null。
   - `getContentLengthOf`：①`'1048576'`→1048576；②垃圾/空→0；③缺省→0；④负数串→负值（>0 判定由调用方）。
   - `isNormalVideo`：①size=1 且 minBytes=1024→false；size=0→过①；②tabId 命中 m3u8Tabs（手工填 state）→false；③`init.mp4` URL→false 且 parentDirUri 入 suspectedFragments；④同目录兄弟 URL（state 预填）→false；⑤contentType `video/x-f4f`→false、`application/mp4 m4s`→false、url 含 `abst`/`f4x`/`.fbcdn`/`http://127.0.0.1:9614`→false；⑥`video/mp4`+大 size→true。
   - `parentDirUri`：①`https://h/a/b/init.mp4?x=1`→`https://h/a/b/`；②尾斜杠 URL 原样；③根级 `https://h/init.mp4`→`https://h/`。
   - `extFromMedia`：①mp4/flv/webm→mkv/mkv(matroska)/mkv(mkv)；②`audio/mpeg` 等值→mp3、`audio/mpeg;x` **不**→mp3（Equals 语义）、`xaudio/mp3`→mp3（Contains）；③aac/m4a；④URL 兜底 .mp4/.mkv/.ts；⑤全不中→null。
   - `qualityText`：`('mp4',5242880)` 前缀 `[MP4] ` 且含 formatSize(5242880) 值；`('mp4',0)` 尾随空格。
   - `getExtensionOf`/`generateUpdatedFileName`：`'a.mp4'`→`.mp4`、`'a'`→`''`、`'a.'`→`'.'`、`'.bashrc'`→`'.bashrc'`；`('old.mp4','New: Title')`→`'New_ Title.mp4'`；无扩展名旧文件→仅 sanitize。
   - 用例计数 ≥ 40 条断言组；`List.test.ets` 追加注册。

### [P] 运行时（手册+Node 双轨承载）

4. **设备侧探针**：`devecocli run --module entry` → `aa start --ps page probe` → P6-U1 卡片自动跑 S1~S9 十一行序列逐行命中 FORMAT 正则（BEGIN/SUMMARY/END 配对）。
5. **主机侧 Node 自验（AI 设备连接时代跑）**：`hdc fport tcp:18597 tcp:8597 && node docs/probe/P6-U1-node-client.js` → 十步全 PASS、退出码 0（=验收"Node 模拟流量全绿"）；`hdc fport rm tcp:18597` 清理。
6. **人工 curl 兜底**：手册 §4 命令集逐条执行对照预期现象（重点：未知路径 `curl -i http://127.0.0.1:18597/nope` = Empty reply/连接关 = **正确**；八路由各 200 且应答体为 sync JSON）。
7. **事件面零破坏回归**：探针运行期间应用主页面正常（无 jscrash；`devecocli log --crash` 空）；S5 后在主页新建一次普通下载确认既有链不受影响（可选人工步骤，手册注明）。
8. **xdm-probe-verify**：回贴 `probe-P6-U1.log` 全文 + EXPECT-u6-1-bridge-eight-routes.json；Node 脚本 stdout 一并回贴（note 声明双轨判定合并口径）。

## 8. 风险与备注

| 风险 | 缓解 |
|---|---|
| handleRoute 异常被误 catch 转 404/500（编码惯性） | §3.1 骨架 8 行定形；结构断言 notFoundResponse 零命中；S8 三谓词 + Node ⑨⑩ 步双验 |
| /args 内层吞异常与外层断连语义混淆 | 仅 handleArgsRoute 内 try/catch（§3.6）；S6 观测 + 单测文法组钉死；`--url` 缺 `--media-tab-title` 类异常走 log |
| tracker 稳定排序依赖（同毫秒并列） | Array.sort 稳定（ES2019+）；拼接序本身即源观测序的保守超集（§3.5） |
| 泵 await send 期间下一请求到达 | U0.3 busy/pending 泵零改动承接（S9 connections/requests 与 S1 差值互证） |
| probe 监听器回调异常塌缩事件链 | tracker/BridgeUiEvents 逐监听器 try/catch + 遍历拷贝（Config.broadcastConfigChange 同款） |
| 桥自动链在 manager 未 init 时被吞 | admitNew 既有防御 no-op + hilog（DownloadManager.ets:171-175）；真机流程 Index 先 init；Node ⑦ 步 /download 默认 auto=false 不触链，auto=true 场景留 U6.3 端到端 |
| store.add 失败静默 | .then(ok) 分支 hilog error（Index 链同款）；不重试不弹窗（源 SaveForLater 语义外的失败面） |
| CJK/emoji 文件名经 utf8Decode→JSON.parse→utf8Encode 往返 | round-trip Hypium 用例 + utf8Encode U0.3 既有用例互证 |
| 探针 S2 捕获 id 的行内长度（UUID 36B） | 单行 <1500B 预算充分；vid 只取前 8 字符观测（期望表按前缀断言） |
