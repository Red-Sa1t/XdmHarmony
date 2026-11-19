# U6.1 BridgeServer 八路由完整版 · 单元迁移报告

| 项 | 值 |
|---|---|
| 单元 | U6.1（Phase 6 第 1 项，探针单元 ID `P6-U1`） |
| 报告日期 | 2026-10-07 |
| 设计书 | `docs/design/u6-1-bridge-eight-routes-DESIGN.md` |
| 探针 | `docs/probe/PROBE-u6-1-bridge-eight-routes.md` + `docs/probe/EXPECT-u6-1-bridge-eight-routes.json`（12 步骤） |
| 对照源码 | `resourses/xdm/app/XDM/XDM.Core/BrowserMonitoring/IpcHttpMessageProcessor.cs` 等（只读，全程未改动 `resourses/` 下任何文件） |
| 结论摘要 | 静态验收全绿（hvigor 编译通过、对照审查第 4 轮 approved、独立复核 acceptable）；运行时验收待人工（设备侧探针 S1~S9 与 Node/fport 轨需真机执行） |

## 1. 单元范围与验收要点

本单元把 U0.3 交付的 8597 桥骨架补全为完整业务版，四项工作：

1. 八路由业务补全：`/sync` 配置全量应答、`/media` 嗅探上报、`/download` 建下载走既有链、`/vid` 视频下载动作、`/clear` 清空、`/tab-update` 标题回写、`/link` 批量链接（兼容保留）、`/args` 命令行参数链。
2. 视频列表桥侧管理：`CapturedVideoTracker.ets` 数据半区（四张插入序表、排序投影、事件）。
3. 探针 P6-U1：设备侧 S1~S9 全自动探针页 + 主机侧 Node 十步流量模拟脚本 + 运行手册 + 机器可读预期表。
4. 单测：路由分派、JSON 解析门、头剥离纯函数等，落 `entry/src/test/BridgeRoutes.test.ets`。

单元验收标准（UNIT_CATALOG U6.1 行）：编译过；八路由对照源码逐端点；Node 模拟流量全绿（AI 本地可自验）；事件面零破坏。交付实现文件 17 个，见设计书 §1 清单，全部 done。

## 2. 研究结论摘要（关键源码行为对应表）

研究阶段逐文件核实源码行为，要点如下（C# 行号均在 `resourses/xdm/app/XDM/` 下；ArkTS 行号在 `entry/src/main/ets/` 下）：

| # | 源码行为（C# 事实与出处） | ArkTS 对应物 |
|---|---|---|
| 1 | 八路径精确匹配 switch 分派（`IpcHttpMessageProcessor.cs:51-86`）；每条已知路由业务执行后统一走 `OnSyncMessage`（:79），应答一律 200 + `Content-Type: application/json` + `Cache-Control: max-age=0, no-cache, must-revalidate` + sync 配置 JSON；未知路径 throw ArgumentException（:77），rethrow 后由每连接线程 catch 关闭 TCP（`HttpServer/HttpServer.cs:46-63`），不回任何应答字节 | `BridgeServer.ets` `dispatchRequest` 改为 classifyRoute、未知路径 throw、业务调 `BridgeRoutes.handleRoute`、统一 `buildSyncResponse()`；异常沿既有 ClientSession 泵 catch 走 `closeSilently`（`BridgeServer.ets:274-286`）。U0.3 的 404 中间态（D1/D2）废止 |
| 2 | 请求体 UTF-8 解码后 `JsonConvert` 反序列化；非法 JSON 或形状不符抛异常断连；体为 `"null"` 时早退但仍回 sync 应答（:90,100,110,120,158,160）。Newtonsoft 属性绑定大小写不敏感：`/media` 发 `file`、`/download` 发 `filename`，两者落到同一 `ExtensionData.File`（`ExtensionData.cs:13`） | `BridgeJson.ets`：`parseExtData`/`parseExtDataArray`/`parseArgsArray` 三门（存在即验型，类型不符 throw）；`file`/`filename` 双键兼容（取 file 优先，登记微差异）；`buildBridgeMessage` 七字段映射 |
| 3 | `RemoveBlockedHeaders`（:376-394）：14 项黑名单（`accept, if, authorization, proxy, connection, expect, TE, upgrade, range, cookie, transfer-encoding, content-type, content-length, content-encoding`），仅作用于 RequestHeaders，逐黑名单名找首个忽略大小写精确等值键删除一次，等值语义（`If-None-Match` 不被 `if` 命中） | `BridgeProtocol.ets` `removeBlockedHeaders` 纯函数（新容器、入参不变）；单测覆盖黑名单精确等值、一次删除、仅请求头三断言组 |
| 4 | `/sync` JSON 八字段序与默认值固定（:278-374 + `Config.cs:46,56-77,110,116`）：enabled/fileExts(24 项)/blockedHosts/requestFileExts(15 项)/mediaTypes/tabsWatcher/videoList/matchingHosts | `BridgeRoutes.buildSyncResponse()`，`SyncFields` 字段序契约冻结零改动；唯一增量是 videoList 从 tracker 实时取 |
| 5 | 生效 tracker 为 `VideoTracker.cs`（四张插入序字典，GetVideoList 按 yt、video、hls、dash 表序拼接后按 DateAdded 升序；Clear 清四表并广播；UpdateMediaTitle 只扫 yt+video 两表；AddVideoDownload 按表序查找，vid 缺失时 ContainsKey(null) 抛 ArgumentNullException 断连，未命中静默）。同目录 `CapturedVideoTracker.cs` 是死代码（不在 XDM.Core.projitems 编译清单） | 行为按 `VideoTracker.cs` 翻译为 `CapturedVideoTracker.ets`（四张 Map、监听器事件、lookupVideoDownload）；UNIT_CATALOG 中 U6.2 行所记 `CapturedVideoTracker.cs(242 行)` 的对照源以研究结论为准，死代码不作为行为依据 |
| 6 | `/media` 分类链（`VideoUrlHelper.cs:35-65`）：响应头无 Content-Type 直接 return，随后依次 IsYtFormat、IsHLS、IsDASH、ProcessYtDashSegment、IsNormalVideo；`IsNormalVideo`（:67-90）五条纯数学（MinVideoSize 下限、m3u8MpdTabs、init.mp4 疑似分片集、Content-Type/URL 关键词）；`ProcessNormalVideo`（:615-700）扩展名映射与 `[EXT] size` 描述文本 | 本单元落纯规则子集：`VideoSniffAlgo.ets`（`isNormalVideo`/`extFromMedia`/`qualityText`/`parentDirUri`）+ `BridgeRoutes.processMediaMessage`（未落分支为 no-op 锚）；YT/HLS/DASH 与两表写入方留 U6.2（读取守卫就位、恒空集） |
| 7 | `/download`（:118-136）：七字段映射 + 剥离后调 `ApplicationCore.AddDownload`（`ApplicationCore.cs:208-236`），LinkAccepted 命中静默丢弃，StartDownloadAutomatically 为真自动开下、否则弹新建下载对话框 | `BridgeRoutes.addDownloadAction`：自动开下走既有 `newDownloadRecord + store.add + admitNew` 链（`Index.ets:449-459` 同构）；对话框动作降级为 `BridgeUiEvents` 事件 |
| 8 | `/link`（:158-179）请求体为 ExtensionData 数组（现版 chrome 与 firefox 扩展均已不再发送，grep 全扩展目录核实，兼容保留）；`/args`（:88-96 + `ArgsProcessor.cs`）文法与分派序：单值开关集不吞值、裸值落 `--url` 整体替换、`--media-*` 三支先于 `--url` 支、内层 try/catch 吞掉业务异常不断连（:130-133） | `parseExtDataArray` 数组门；`parseArgs` + `handleArgsRoute` 分派序 1:1，内层吞异常在 handleArgsRoute 内实现，不穿透断连 |
| 9 | 客户端契约（`chrome-extension/connector.js:14-27,39-48` + `app.js` + `HttpParser.cs:43-57` + `RequestContext.cs:33-62`）：12 个 alarm 约每 5 秒轮询 `GET /sync`（无体）；发消息 POST 不带 Content-Type 头、不带 Connection 头，每请求一条新连接，应答后服务端即关连接 | 探针客户端 `ProbeBridgeNet.ets` 与 Node 脚本 `docs/probe/P6-U1-node-client.js` 按此契约造流量：每请求新 TCP、POST 无 Content-Type、以连接关闭加已读 Content-Length 字节为完整应答信号 |

## 3. 设计决策与有意差异

依据 MIGRATION_PLAN §6 决策 5（8597 八路由复刻，`/sync` 响应配置字段逐一对照，含响应头剥离规则）、决策 2 的线程模型精神（单线程事件循环替代 lock）、§3 降级清单（Native Messaging 不复刻）、§7 Phase 6 第 1 项，以及设计书 §0 的三项 openQuestions 拍板。全部有意差异（★ 本单元新增，☆ 沿用既有登记）：

| # | 差异 | 依据 |
|---|---|---|
| ★1 | 未知路径废止 U0.3 的 404 中间态，改回源码 1:1 静默断连不回应答；Node/curl 判定口径为"连接关闭且零应答字节 = 正确" | 设计书 §0-1 拍板（openQuestion#3）；源 `IpcHttpMessageProcessor.cs:76-77` + `HttpServer.cs:56-63` |
| ★2 | `/media` 仅落纯规则子集 IsNormalVideo+ProcessNormalVideo；YT manifest 下载、HLS/DASH/segment 识别、m3u8MpdTabs/referersToSkip 两表写入方留 U6.2。暂态效应：真实 HLS `.ts` 段可能误入 videoList，U6.2 全链落地即消除 | 设计书 §0-2 拍板（openQuestion#1） |
| ★3 | LinkRefresher.LinkAccepted 未迁移恒 false，`/download` 与 `/vid` 的重复链接不去重 | 设计书 §4-3；U6.x 补 |
| ★4 | 请求头/Cookie 不注入下载引擎：剥离照做，但 DownloadRecord 无 headers 字段，桥发起的下载暂不带浏览器 cookie；HttpClient.open 的 header 注入点 U6.3 必须接通（M6 验收前置，最高优先跟进） | 设计书 §4-4 |
| ★5 | UI 动作降级事件化：ShowNewDownloadDialog/ShowVideoDownloadDialog/ShowDownloadSelectionWindow/`--quit` 进程退出/主窗激活，均改为 `BridgeUiEvents` 事件 + log + pending 列表，真 UI 留 U6.3 | 设计书 §0-3 拍板（openQuestion#2） |
| ★6 | IsFFmpegOK 降级：单源恒 true、yt/hls/dash 恒 false（U0.4 ffmpeg 未做）；U7.2 接真值 | 设计书 §4-6 |
| ☆7 | SanitizeFileName 复用 `FileNames.sanitizeFileName` 的 U1.2 D6 修正版（取 '/' 与 '\\' 较大下标段），不复刻源 :17-18 的死赋值怪癖 | MIGRATION_PLAN §6 决策 5 之剥离规则；设计书 §4-7 |
| ★8 | JSON 门严格类型：Newtonsoft 数字转字符串的隐式强转不复刻（`url:123` 即断连）；例外是头值数组中的 number 元素按 ReadAsString 语义 `String(v)` 收编（R2-F1 修正，真实扩展 `Content-Length=[number]` 主线流量不误杀）；file/filename 双键并存取 file 优先 | 设计书 §4-9（含 R2-F1 补记） |
| ★9 | 桥自动链不更新 Index 内存数据源：record 落库、引擎运行、事件流向 Index（handler 有 findById null 守卫），主列表 UI 不即时显示，完整接线 U6.3 | 设计书 §4-10、§0-7 事件面红线 |
| ★10 | tracker 动作/数据分区：CapturedVideoTracker 只做数据半区，建链与对话框事件的动作半区放 BridgeRoutes，避免 tracker 与 routes 循环 import；U6.2 视 UI 订阅方再收拢 | 设计书 §0-4 |
| ★11 | `/vid` 缺 vid 时 throw 断连（源 ContainsKey(null) 语义的 1:1 保留，非差异项，列为防顺手防御锚，不得改成静默忽略） | 设计书 §4-11 |
| ☆12 | MIGRATION_PLAN §3 既有降级沿用（Native Messaging、register.html 不复刻）；method 字段保留仅观测（U0.3 差异 #6 延续） | 设计书 §4-8、§4-12 |

配置文件面：本单元不新增能力，`module.json5`（deviceTypes 已含 2in1、requestPermissions 已含 `ohos.permission.INTERNET`）、`main_pages.json`、`EntryAbility.ets` 显式不动（设计书 §0-5 有据），`git status` 实测三者零改动。

## 4. 审查问题处置表（覆盖全部轮次）

对照审查共 4 轮：第 2 轮 5 项 findings（1 high 4 low）未通过；第 3 轮 6 项（1 medium 5 low）未通过；第 4 轮 6 项（全 low）复核后 approved。另有编码轮 hvigor 编译错误 2 项、验收冷启动轮载荷缺陷 1 项（COLD-F1）。独立复核换人执行，acceptable，7 项 findings 全 low。以下两表覆盖全部条目；表中行号均已在本会话逐条核对。

### 4.1 已修复（5 项）

| 编号 | 来源与严重度 | 问题 | 处置与证据 |
|---|---|---|---|
| R2-F1 | 对照审查第 2 轮，high | `jsonHeadersOrNull` 对非 string 头值元素 throw，而真实 chrome 扩展 `/download` 主线流量 `responseHeaders["Content-Length"]=[fz]`（`fz=+size` 为 number，`app.js:77-79,225-229`）、firefox 同（`app.js:170`），会被门误杀断连；且扩展发消息前已 `chrome.downloads.cancel+erase` 取消浏览器下载，此流量下用户下载直接丢失 | 已修复：number 元素按 Newtonsoft `ReadAsString` 语义 `String(v)` 强转收编，其余类型（boolean/object/null）仍 throw；设计 §4-9 补记该例外；新增单测边界。证据：`BridgeJson.ets:233-238`（代码注释标注 R2-F1）；`BridgeRoutes.test.ets` 头注"parseExtData 12（含 R2-F1 数字头值强转收编与 boolean 仍 throw 边界）" |
| R3-F1 | 对照审查第 3 轮，medium | `utf8Decode` 截断序列（如 `[0xE4,0xB8]`）失败路径每次只前进 1 字节，实产 2 个 U+FFFD，与自家单测期望（1 个）矛盾，偏离 .NET `Encoding.UTF8.GetString` 的 replacement fallback | 已修复：失败路径改为"起始字节 + 已确认合法续字节整体消费"，一次失败恰产一个 U+FFFD；函数级文档重写，设计 §3.3 加修正注。证据：`BridgeProtocol.ets:349-356`（标注 R3-F1 三态语义）。附带遗留：文件头注记漏改，见 4.2 表 F4 |
| hvigor-compile-error-BridgeRoutes-317/320 | 编码轮门禁，error | `BridgeRoutes.ets` 两处编译错误（317、320 行附近） | 已修复，hvigor 门禁通过 |
| COLD-F1 | 验收冷启动轮，确定性 FAIL | 三处 `/link` 载荷（探针 S7、Node T08、手册 curl ⑧）元素缺 `requestHeaders`，`buildBridgeMessage` 对 null requestHeaders throw 断连（1:1 源 Select 内 NRE 语义，映射先于空 url 跳过），载荷确定性 FAIL | 已修复：三处载荷每元素补 `requestHeaders`，实现门保真不动；修复会话以实现侧纯函数搭门建模 mock 后端到端复跑 Node 十步全绿（SUMMARY pass=10 fail=0，退出码 0），并做负控实测（旧载荷断连零字节）与正控实测（修后载荷 232 字节 200 应答）。证据：`ProbeBridgeRoutes.ets:71-75`、`P6-U1-node-client.js:309-313`、手册 §4 表 S7 行，本会话均核对在位 |
| （同族）R2-F1 单测 | 随修复新增 | — | `BridgeRoutes.test.ets` 用例总数增至 69 条断言组（本会话 `grep -c "    it('"` 实测 69） |

### 4.2 遗留未修（7 项，全 low；第 4 轮 approved 与独立复核 acceptable 均不要求本轮修复，登记为后续单元跟进）

| 编号 | 首现轮次 | 问题 | 现状证据（本会话核对） | 建议跟进 |
|---|---|---|---|---|
| F2 族（file 空串回退失效） | R2-F2，R3/R4 与独立复核复确认 | `buildBridgeMessage` 对空串 file 先经 `sanitizeFileName('')` 得 `'file'` 兜底，`processNormalVideo` 的 `file.length===0` 回退分支永不可达；源 `VideoUrlHelper.cs:623-630` 对 IsNullOrEmpty 回退 `GetFileName(url)`。`request-watcher.js` 的 title 可为空串，此流量下条目登记为 `file.mp4` 而非 URL 末段名 | `BridgeJson.ets:294`（`data.file === null ? null : sanitizeFileName(data.file)`，未含空串）、`BridgeRoutes.ets:432-435` | U6.x 随 `/media` 补全一并修：空串同 null 处理 |
| F3（contentType 存原值） | R2-F3 | `/media` 登记条目 contentType 存原值（如 `video/mp4`）并经 `/vid` 对话框事件回传；源 `ProcessNormalVideo` 不设 ContentType（默认 null）。实现与设计 §3.4-5 一致，属设计偏离源未在 §4 登记，仅影响 U6.3 对话框负载 | `BridgeRoutes.ets:449-452` | 形参改传 `''` 镜像源默认值，或设计 §4 补登 |
| F4（notFoundResponse 字面 grep 误报） | R2-F4 | 设计 §7-[A]-2 结构断言"BridgeServer.ets 中 notFoundResponse 零命中"按字面 grep 会命中 `BridgeServer.ets:20` 注释里的"本地 buildSyncResponse/notFoundResponse 已删"。代码确已删除，仅注释含该标识符，脚本化门禁按设计原文会误报 | `BridgeServer.ets:20`、设计文档 :313 | 注释改为不含标识符的措辞，或断言改为仅匹配函数定义形态 |
| F5（设计文档两处自相矛盾） | R2-F5 | 其一：§1 表（:27）把 processMediaMessage/addDownloadAction/startBridgeAutoDownload 列为对外导出，§5.5（:264）声明文件内私有，实现按私有。其二：§3.7（:164）说 `/link` pending 收集 `{url,file}`，实现 `getPendingBatchLinks():string[]` 只存 url，U6.3 勾选窗消费时丢失已算好的 file 名 | 设计文档 :27、:164、:264 与 `BridgeRoutes.ets:121-125`、:236（`pendingBatchLinks.push(url)`） | 修订设计两处；U6.3 消费前改存 `{url,file}` 对或声明从 url 重算 |
| F1（`--media-tab-url` 缺 title 仍改名） | 独立复核 F1（新增发现） | `/args` 的 `--media-tab-url` 缺 `--media-tab-title` 时以空串兜底仍执行改名，`generateUpdatedFileName` 经 `sanitizeFileName('')='file'` 兜底把命中条目统一改名为 `file.ext`；源 `ArgsProcessor.cs:23-24` 取 title 在前、缺键异常被 :130-133 吞掉即整体中止（零改名） | `BridgeRoutes.ets:268-275`（实现注释已写明"源 KeyNotFoundException 吞差异"，属有意兜底但设计 §3.6-1 未补登连锁效应） | title 缺省时跳过改名（对齐源中止语义），或设计 §3.6-1 补登 |
| F4'（头注旧描述） | R4-F1（R3-F1 修复的附带遗漏） | `BridgeProtocol.ets` 文件头 U6.1 注记仍写旧 utf8Decode 行为"非法序列 U+FFFD 替换并前进 1 字节重同步"，与同文件 R3-F1 修正后的函数级文档（:349-356）及设计 §3.3 矛盾 | `BridgeProtocol.ets:26-27` 对照 :349-356 | 头注改为三态表述（一次失败恰产一个 U+FFFD） |
| F7（计数注记过时） | R3-F6 | `List.test.ets` 头注仍写"parseExtData 10""合计 293+67=360 条"，实际 `BridgeRoutes.test.ets` 为 69 用例（parseExtData 12） | `List.test.ets:33-39`；本会话 `grep -c "    it('" entry/src/test/BridgeRoutes.test.ets` 实测 69 | 注记同步为 parseExtData 12 / 69 条 / 合计 362 |

## 5. 验证情况

### 5.1 hvigor 编译门禁（本会话复跑）

命令 `devecocli build --modules entry`（devecocli 1.3.0-stable），结果 `BUILD SUCCESSFUL`，退出码 0。多数 task 为 UP-TO-DATE（含 CompileArkTS），即自门禁轮全量编译后源码未再变更，hvigor 按输入哈希判定无需重编，与门禁脚本记录（材料）"最终状态：通过"一致。ArkTS 合规说明：codelinter 不含 ArkTS 语法规则，ArkTS 严格子集由 hvigor 编译期强制（MIGRATION_PLAN §8 验证矩阵），编译通过即语法合规；编码阶段同时按 arkts-grammar-standards 自查（禁 any、对象字面量需类型、无结构化类型等）。

### 5.2 codelinter 辅助检查（以门禁脚本记录为准，本会话未复跑）

退出码 0，Summary: Issues 20 / Errors 0 / Warnings 18 / Suggestions 2 / Files checked 6。命中项均为提示性规则（如 `hp-arkui-set-cache-count-for-lazyforeach-grid`，Index.ets 等的 LazyForEach cachedCount 建议），无 error。

### 5.3 对照审查（4 轮）

第 2 轮未通过（5 findings，含 1 项 high 即 R2-F1）；第 3 轮未通过（6 findings，含 1 项 medium 即 R3-F1）；第 4 轮 approved（6 findings 全 low，即 4.2 表遗留项）。high/medium 两项均已修复并经后续轮次复核。

### 5.4 独立复核（acceptable）

独立复核 acceptable，7 项 findings 全 low（即 4.2 表，含 1 项新增 F1）。其 weakestSpot 记录：COLD-F1 修复已有 mock 十步全绿与 S7 门序 pending=1 的实测记录；剩余最可能在真机被观测的偏差是 F2 族与 F1 的空串兜底族，均只在畸形/兼容流量触发、不崩溃。

### 5.5 单测与 Node 模拟流量

单测：`BridgeRoutes.test.ets` 69 条断言组入库（本会话 grep 实测 69，满足设计 ≥40 要求），覆盖路由分派、JSON 三门、头剥离、嗅探数学、args 文法、头取值。Hypium 本地 runner 在本会话环境不可执行，用例未实跑，如实登记（assembleHap 不编译 src/test，不影响编译门禁），执行留统一回归。

Node 模拟流量：设备侧与 fport 轨需真机连接，本会话无设备，未执行。COLD-F1 修复会话曾以实现侧纯函数搭门建模 mock 端到端复跑，十步全绿（SUMMARY pass=10 fail=0，退出码 0；负控旧载荷断连零字节、正控修后载荷 232 字节 200 应答），mock 为该会话临时产物未落盘，本会话无法复跑该记录，按修复会话实测登记。本会话可执行的替代核验：`node --check docs/probe/P6-U1-node-client.js` 通过；T09/T10 判定口径（未知路径与坏 JSON 断连零字节 = 正确）与脚本内断言一致。

探针材料本会话校验：`EXPECT-u6-1-bridge-eight-routes.json` 经 JSON 解析校验通过；探针 S7 载荷（`ProbeBridgeRoutes.ets:71-75`）经门逻辑复刻验证可达 200（设备侧实跑需真机 + fport，本会话不可执行，以复刻验证替代并注记）。

### 5.6 事件面零破坏

设计红线 §0-7 的三项核验：既有 DownloadEvents/ManagerHooks/Config.onConfigChanged 事件面零改动（审查轮确认）；新增 CapturedVideoTracker 监听器与 BridgeUiEvents 为纯增量；桥自动链经既有事件袋流向 Index，handler 对未知 id 有 findById null 守卫。工作区 `git status` 实测 `Index.ets` 零改动，`module.json5`/`main_pages.json`/`EntryAbility.ets` 零改动。

## 6. 运行时验证待办（探针）

本单元运行时验收未完成，待人工在真机/模拟器执行后回贴日志：

1. 环境与运行：按 `docs/probe/PROBE-u6-1-bridge-eight-routes.md` §0~§3（`devecocli run --module entry` 推包，`aa start --ps page probe` 开探针页，点 P6-U1 卡片自动跑 S1~S9；hilog 抓取 `probe-P6-U1.log`）。
2. 主机侧 Node 轨：`hdc fport tcp:18597 tcp:8597` 后 `node docs/probe/P6-U1-node-client.js`，预期 SUMMARY pass=10 fail=0、退出码 0；收尾 `hdc fport rm tcp:18597`。
3. 人工 curl 兜底轨：手册 §4 命令集逐条对照预期现象（重点：未知路径 curl 报 Empty reply from server 或连接被关即正确）。
4. 核对：回贴探针日志与 Node stdout，用 xdm-probe-verify 工作流对照 `docs/probe/EXPECT-u6-1-bridge-eight-routes.json`（12 步骤：BEGIN、S1~S9、SUMMARY、END）逐步判定。双轨判定合并口径在预期表 END 步 note：两轨任一全绿即 [P] 运行时验收通过。
5. 注意：U0.3 探针 S4 的 `querySyncStatus=404` 预期在本单元后不复现（404 中间态已废止），U0.3 探针已归档不重跑。

## 7. 遗留问题与风险

1. 4.2 表 7 项 low 遗留 findings，全部为畸形/兼容流量触发或文档层面问题，不崩溃、不阻塞 M6；其中 F5 的 pending 结构问题会影响 U6.3 勾选窗消费，须在 U6.3 动工前处置。
2. 桥下载暂不带浏览器 cookie（差异 ★4）：M6 端到端验收（真浏览器播视频后应用带 cookies 完整下载）的硬前提，U6.3 必须接通 HttpClient.open 的头注入，属最高优先跟进项。
3. U6.1 暂态效应：真实浏览器 HLS `.ts` 段会误入 videoList（HLS 处理链与 m3u8MpdTabs 写入方在 U6.2 落地）；受控探针流量不触发。
4. LinkAccepted 未迁移：重复链接不去重；主列表 UI 不即时显示桥自动链记录（完整接线 U6.3）；UI 动作仅事件化；IsFFmpegOK 为降级值。以上均为已登记差异，对应 U6.3/U7.2 收口。
5. 设备侧探针 S7 与 Hypium 用例未在真实设备执行（本会话环境限制），以门逻辑复刻与代码入库替代，须随 §6 待办一并验证。
6. 工作区存在杂物文件 `nul`（git status 未跟踪项，非本单元交付物），人工提交前建议删除。

## 8. 对下个单元的建议（U6.2 嗅探规则 + 视频捕获）

1. 动工前先修 4.2 表 F2 族与 F1（两处空串兜底），改动面小且与本单元文件重叠（`BridgeJson.ets`、`BridgeRoutes.ets`），避免 U6.2 返工时混入。
2. U6.2 落 HLS/DASH/YT-itag 识别与 m3u8MpdTabs/referersToSkip 写入方时，读取守卫已在本单元就位（`SniffState` 三集、`processMediaMessage` 的 no-op 锚），填表即生效，无需改调用面。
3. 对照源以 `VideoUrlHelper.cs` 与 `VideoTracker.cs` 为准；UNIT_CATALOG 中 U6.2 行所记 `CapturedVideoTracker.cs` 是死代码（不在 projitems 编译清单），不作为行为依据（见本报告 §2-5）。
4. U6.2 收拢 tracker 动作半区时（UI 订阅方就位），一并评估把建链/对话框事件从 BridgeRoutes 移回 tracker（设计书 §0-4 预留）。
5. U6.2 探针建议加入真实 HLS 测试流观测，验证 §7-3 暂态效应消除；同时复核本单元遗留的 contentType 语义（F3）在对话框负载上的影响面。
6. 修订设计文档三处（F4 的 grep 断言、F5 的导出列与 pending 结构）后再进入脚本化门禁，避免按旧原文误报。

## 9. git 提交说明

本单元代码未做 git 提交。工作区现状（本会话 `git status` 实测）：7 个修改文件（BridgeProtocol.ets、BridgeServer.ets、ProbeIndex.ets、三份 string.json、List.test.ets）与 10 个新增文件（设计书、探针三件套、BridgeJson/BridgeRoutes/VideoSniffAlgo/CapturedVideoTracker、ProbeBridgeNet/ProbeBridgeRoutes、BridgeRoutes.test.ets）全部处于未提交状态；最后一次提交为 47bb4dc（2026-10-03，探针会话#1）。按 MIGRATION_PLAN §9-3 与 §10 的节奏，待人工验收通过后由人提交（单元粒度回滚点）并在 Phase 6 验收完成时打 `phase-6` tag。
