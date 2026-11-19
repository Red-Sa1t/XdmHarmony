# U0.3 扩展桥 8597 服务端 · 单元迁移报告

> 单元：U0.3（Phase 0 第 3 项，回补执行于 U6.1 之前；探针单元 ID `P0-U3`）。
> 依据材料：单元指令、源码研究结论、设计书 [u0-3-extension-bridge-server-DESIGN.md](./u0-3-extension-bridge-server-DESIGN.md)、对照审查全史（第 2/3 轮）、独立复核结论、门禁结论。本报告员本会话（2026-10-03）对关键代码、配置、文档、git 状态与编译门禁做了独立复核——下文标注"本会话核实/本会话执行"者为报告员亲自读取或运行的检查，其余为任务材料申报结论（注明来源）。
> 重大状态更新（详见 §⑨）：**U0.3 变更已由后续会话提交（commit `cd060a3`），工作区 clean；与任务材料"代码未做 git 提交"的说法相矛盾，以 git 日志为准**。Phase tag 尚未打。

---

## ① 单元范围与验收要点

**范围**（单元指令三项）：

1. `entry/src/main/ets/core/bridge/BridgeServer.ets`——TCPSocketServer 监听 127.0.0.1:8597 + HTTP/1.1 请求解析（方法/路径/头/体）+ 八路由分发骨架（未实现路由 404）+ `/sync` 最小应答；配套纯逻辑模块 `BridgeProtocol.ets`（零 @kit 依赖，供单测/探针同源复用）。
2. `EntryAbility` 启动接线：onCreate 尾部追加 `BridgeServer.getInstance().start()`（只加不改）。
3. 探针 P0-U3：监听/自连/主机 curl 指引/路由可达观测 + 运行手册 + 机器可读预期表。

**验收要点**（单元指令）：编译过；curl GET /sync 得合法 JSON；八路由可达。

**验收现状**：编译门禁通过（本会话 clean 后全量复跑通过，见 §⑤）；curl 与八路由可达属运行时验收，待探针 P0-U3 在模拟器/真机运行后由 `xdm-probe-verify` 判定（见 §⑥），**本会话未执行运行时验收**。

**交付文件清单**（设计书 §1 共 14 项 + 审查员指令追加的设计书自身修改；全部已含于提交 `cd060a3`，本会话读取各文件核实存在与内容）：

| 类别 | 文件 |
|---|---|
| 业务代码（新） | `core/bridge/BridgeProtocol.ets`、`core/bridge/BridgeServer.ets` |
| 接线（改） | `entryability/EntryAbility.ets`（:59 import、:116-119 start()） |
| 探针（新/改） | `probe/units/ProbeBridge.ets`（新）、`probe/units/ProbeBridgeLogic.ets`（新）、`probe/ProbeIndex.ets`（改，:43 注册 + :135-136 分支） |
| 本地单测（新/改） | `entry/src/test/BridgeProtocol.test.ets`（新，30 用例）、`entry/src/test/ProbeBridgeLogic.test.ets`（新，6 用例）、`entry/src/test/List.test.ets`（改，注册两项） |
| 资源（改） | `resources/base|zh_CN|en_US/element/string.json` 各追加 `probe_p0u3_title`/`probe_p0u3_hint`（各 :808/:812） |
| 文档（新/改） | `docs/probe/PROBE-u0-3-extension-bridge-server.md`（手册）、`docs/probe/EXPECT-u0-3-extension-bridge-server.json`（预期表 7 步骤）、`docs/design/u0-3-extension-bridge-server-DESIGN.md`（设计书，R2-F2 轮审查员指令追加修改） |
| 显式不动 | `module.json5`、`main_pages.json`（有据：见 §③第 11 条） |

---

## ② 研究结论摘要（关键源码行为 → ArkTS 对应表）

研究阶段路径勘误已登记并经设计书 §前言复核成立：HttpParser.cs / HttpServer.cs / LineReader.cs / RequestContext.cs 实际位于 `app/XDM/XDM.Core/HttpServer/`（非 BrowserMonitoring/HttpServer/）。核心行为对应（源码行号为研究结论锚点，鸿蒙侧行号为本会话核实）：

| # | 原版源码行为（研究结论锚） | 鸿蒙 ArkTS 对应（本会话核实） |
|---|---|---|
| 1 | `IpcHttpMessageProcessor.cs:47-86`：RequestPath 精确匹配 switch 八路由（/sync /download /media /tab-update /vid /clear /link /args）；default throw ArgumentException；switch 后无条件 OnSyncMessage——成功分发的路由一律 200+同一份 sync JSON | `BridgeServer.ets:303-322` `dispatchRequest(path)` 精确匹配 `ROUTE_PATHS` 八字面量（`BridgeProtocol.ets:29-30`）；仅 `/sync` 回 200+JSON（:327-346），其余已知路径 404+hilog `unimplemented`、未知路径 404+`unsupported`（有意差异 D1/D2，见 §③） |
| 2 | `IpcHttpMessageProcessor.cs:264-374` + `Config.cs:46,56-75`：/sync 应答 200 + Content-Type: application/json + Cache-Control: max-age=0, no-cache, must-revalidate；八字段序 enabled/fileExts/blockedHosts/requestFileExts/mediaTypes/tabsWatcher/videoList/matchingHosts；Formatting.None 紧凑序列化 | `BridgeServer.ets:327-346` 从既有 `core/Config` 四 getter 取值构造 `SyncFields` 具型字面量；`BridgeProtocol.ets:230-232` `buildSyncJson` = `JSON.stringify(SyncFields)`（interface 字段序即序列化序）；常量表 `BridgeProtocol.ets:32-37`；videoList 恒 `[]`（D4） |
| 3 | `LineReader.cs:11-37`：逐字节读头，'\r' 任意位置跳过、'\n' 空行止头、EOF 异常断连 | `BridgeProtocol.ets:97-154` `parseHead` 字节级增量状态机（0x0D 丢弃/0x0A 切行/Latin-1 逐字节转字符）；`BridgeServer.ets:212-218` 每连接 Uint8Array 累积缓冲 + 重扫（on('message') 任意分包，禁整块 split） |
| 4 | `HttpParser.cs:14-41,59-89`：状态行 Split(' ') 不忽略空项、token>2 取 arr[1]（method 丢弃）；头行首个 ':' 且 index>0，两端 Trim；大小写敏感字典同名多值累积、取值 [0]；不剥 query | `BridgeProtocol.ets:118-148` 同语义；头容器平行数组 `BridgeHeaders`（:41-44，同构 Dictionary，D8）；method 保留仅探针观测（D6，`BridgeServer.ets:128-133` noteRequest 记 lastMethod/lastPath） |
| 5 | `HttpParser.cs:43-47,80-100`：Content-Length 精确大小写键取 [0]，缺省 -1 不读体；值>0 精确读满；不支持 chunked | `BridgeProtocol.ets:171-182` `getContentLength`（`^[+-]?[0-9]+$` 严格十进制，非法 -2→断连）；`BridgeServer.ets:244-257` 缓冲长度门 + slice 取体 + 剩余字节保留（keep-alive 下一请求） |
| 6 | `HttpParser.cs:49-57` + `RequestContext.cs:37,49-53`：Connection 键缺省 close，equalsIgnoreCase 'keep-alive' 才复用；应答恒写 Connection: keep-alive（非对称） | `BridgeProtocol.ets:186-196` `isKeepAlive`；`BridgeServer.ets:268-272` 复用判定；`BridgeProtocol.ets:215` 恒写 keep-alive 头（非偏差，防"顺手修正"列入 EXPECT 判定要点） |
| 7 | `RequestContext.cs:33-62`：状态行恒 HTTP/1.0；content-length 头忽略大小写跳过；仅体非空写 Content-Length；404 空体靠断连定界 | `BridgeProtocol.ets:206-225` `buildResponseBytes` 逐条对照；单块 Uint8Array 经 `conn.send({data: out.buffer as ArrayBuffer})` 一次写入（`BridgeServer.ets:260-264`） |
| 8 | `HttpServer.cs:14-64` + `ApplicationCore.cs:69-73`：Loopback:8597 阻塞 accept 循环跑专职线程；Init 尾部 StartScheduler 后 StartBrowserMonitoring；端口占用弹 MSG_ALREADY_RUNNING | `BridgeServer.ets:135-169` constructTCPSocketServerInstance + listen + **getLocalAddress 校验 port===8597**（:148-155，鸿蒙 listen 失败会静默随机分配端口——文档明示，故 listen 成功≠拿到 8597）；`EntryAbility.ets:116-119` onCreate 尾部 start()（位于 Scheduler.start() :103 与 ClipboardWatcher :112-113 之后，维持原版次序）；失配仅 hilog+探针观测（D5） |
| 9 | `chrome-extension/connector.js:4,14-28,39-48` + `app.js:34-46`：APP_BASE_URL 硬编码 8597 轮询 GET /sync；res.json() 解析失败即 disconnect；首轮询 ~6s、稳态 ~5s | 连通性契约三要素（8597 + GET /sync + 合法 JSON）即验收判定基准，写入手册与 EXPECT S2 note（本会话 require() 解析 EXPECT 通过并核对 S2 条目全文）；扩展轮询时序供 U6.3 对表 |
| 10 | 每连接专职线程 + 阻塞读 | 单线程事件循环 + 每连接 `ClientSession` 状态泵（busy/pending 串行化 send，无锁不用 TaskPool，D7；`BridgeServer.ets:184-298`） |

---

## ③ 设计决策与有意差异

**计划引用**（MIGRATION_PLAN.md）：

- **决策 5（:118 浏览器集成）**：BridgeServer 复刻 8597 八路由、/sync 响应字段逐一对照、扩展直接复用（8597 地址不变）——本单元即该决策的监听/解析/分发骨架部分；register.html 自定义协议注册省略亦为决策 5 既有结论。
- **决策 2（:115 线程模型重构）**：原版裸 Thread+阻塞读 → 事件驱动；本单元每连接线程 → ClientSession 状态泵是其精神在 socket 服务端的投影。
- **§3 降级清单第 7 项（:52）**：Chrome Native Messaging 不复刻（8597 HTTP 轮询即连通性契约）——本单元无新增降级项。
- **§7 Phase 6 第 1 项（:158）与 UNIT_CATALOG 执行序（:15/:18）**：U0.3 按"Phase 0 不再全绿才进 Phase 1"的调整，回补于 U6.1 之前。
- **§8 验证矩阵（:173-178）**：静态 hvigor 主 + codelinter 辅、运行时探针——本单元验证组织遵循该矩阵。

**有意差异清单**（设计书 §4，共 11 条；要义与证据）：

1. **未知路径 → 404 空体**（原版 default throw → 断连不回包，IpcHttpMessageProcessor.cs:76-77）——单元指令拍板；U6.1 沿用并写入桥协议规格书。落地：`BridgeServer.ets:317-321`。
2. **七条业务路由 → 404 空体**（原版统一回 200+sync JSON）——本单元为分发骨架，业务在 U6.1；日志区分 unimplemented/unsupported。落地：`BridgeServer.ets:307-321`。
3. **解析层失败与 /sync 处理异常 → 断连不回包**（未采纳研究结论"异常转 500/404"建议，设计书 §0-1 拍板二分）——1:1 原版 HttpServer.cs:56-63 语义。落地：`BridgeServer.ets:237-247`（closeSilently）、:274-278（catch→closeSilently）。
4. **videoList 恒空数组**（CapturedVideoTracker 属 U6.2）；元素 interface `{id,text,info,tabId}` 按 VideoTracker.cs:391-395 预定义。落地：`BridgeProtocol.ets:59-64`、`BridgeServer.ets:329`。
5. **端口占用/静默回退随机端口：仅日志/探针观测，无 MSG_ALREADY_RUNNING UI**（留 U6.x 拍板，设计书 §0-3）。落地：`BridgeServer.ets:148-155`。
6. **method 保留在解析产物**（原版完全丢弃）仅探针观测，不参与路由，行为零差异。落地：`BridgeServer.ets:128-133`。
7. **线程模型映射**：每连接专职线程 → 事件循环 + ClientSession 状态泵（busy/pending），无锁、不用 TaskPool。落地：`BridgeServer.ets:184-298`。
8. **头容器平行数组 BridgeHeaders 同构替代 Dictionary<string,List<string>>**（插入序+同名多值+大小写敏感+取 [0] 全保留）。落地：`BridgeProtocol.ets:41-44,128-148`。
9. **Content-Length 严格十进制正则**（对齐 Int64.Parse 可用子集；不支持 chunked 原版同）。落地：`BridgeProtocol.ets:79-80,171-182`。（注：超 Int64 上界形态的偏差未收口，见 §⑦-1。）
10. **MIGRATION_PLAN §3 既有降级边界确认**（Native Messaging/register.html），本单元无新增降级项。
11. **module.json5 / main_pages.json 显式不动（有据，非遗漏）**：INTERNET 权限与 2in1 已在（module.json5:7-9 deviceTypes 含 "2in1"、:16 `ohos.permission.INTERNET`——本会话 grep 核实）。**勘误提示**：单元指令模板文称"当前缺 ohos.permission.INTERNET"，与仓库实际不符（该权限 U0.1 已落地）；以仓库文件为准，本单元零配置改动成立。`main_pages.json` 仅 `pages/Index` + `probe/ProbeIndex`（本会话读取核实），探针子页经 want 参数页内条件渲染，不注册。

---

## ④ 审查问题处置表（覆盖全部轮次）

对照审查全史（材料所给两轮）+ 独立复核一轮。**已修复编号：R2-F1、R2-F2、R2-F3**（实现摘要申报，本会话逐处核实落地）；R2-F4 及独立复核三条 low 未在本轮修复，登记遗留（见 §⑦）——**这三项遗留现已随 `cd060a3` 进入提交代码**，U6.1 处置。

| 编号 | 严重度 | 问题 | 处置 | 证据（本会话核实） |
|---|---|---|---|---|
| R2-F1 | high | drain() 先判 `!head.complete` 再判 `head.failed`，而 parseHead 失败路径 complete 恒 false → failed 分支死代码：GARBAGE/畸形请求既不回包也不断开，客户端挂到超时；偏离原版断连语义与 §0-1① | **已修复**：交换判序，先 `if (head.failed) → closeSilently('parse failed')` 再 `if (!head.complete) → break` | `BridgeServer.ets:234-243`：failed 判定在前并附短路序注释（明言 R2-F1）；编码员以逐行转录的 Node 脚本验证 4 类失败输入/正常/半包/非法 CL 四分支（F1-VERIFY-OK，材料申报） |
| R2-F2 | medium | cacheControl 原值含逗号，emit 会被 ProbeKit 白名单消毒成 '?'，与 EXPECT/手册/设计书三处示例不一致 | **已修复**：新增 `commasToSlash` 助手，fieldOrder 与 cacheControl 统一预转换为 '/' 形；EXPECT/手册/设计书三处 S2 示例同步；原始逗号形保留 detail 文件 | `ProbeBridge.ets:204`（助手）、:346-351（接入）、:377/:382（emit '/' 形）；手册 §5 表 S2 行与 EXPECT S2 条目均为 '/' 形且 note 注明口径（本会话读取原文核实）；手册 §3 主机 curl 段保持线上原始逗号形（正确：那是 HTTP 头原形，非标记行） |
| R2-F3 | medium | 用例断言 `complete===true` 与 parseHead 失败路径短路语义矛盾，实跑必挂 | **已修复**：断言改 `failed===true` 且 `complete===false` | `BridgeProtocol.test.ets:84-88`；用例总数 30（`grep -c "    it('"` = 30，本会话执行） |
| R2-F4 | low | 超 Int64 上界 Content-Length（如 20 位数字）：C# Int64.Parse 抛 OverflowException→断连；ArkTS 正则放行 Number() 得 1e20>0 → 服务端"等体"分支无限等待（不回包不断连） | **未修复，登记遗留**：两个修复选项（MAX_SAFE_INTEGER 上界护栏 / 偏差登记）均未落地；独立复核 IR-F2 复查确认仍未落地（acceptable 不阻塞）。仅恶意/畸形输入可触发，connector.js/curl/探针均不发此形态 | `BridgeProtocol.ets:171-182` 仍 `return Number(raw)` 无上界；本会话 `grep -rn "MAX_SAFE\|Overflow\|溢出\|1e20\|9999999999"` 于 core/bridge/ 与本单元三份文档**零命中**（exit 1） |
| R3 | — | 第 3 轮复审：**approved=true，零问题** | 通过 | 材料申报（对照审查全史 round 3） |
| IR-F1 | low | 空状态行（首部裸 \r\n）被 0x0A 空行分支当作头块正常终止（该分支不要求 sawStatusLine）→ dispatch('') → 404 回包；原版此形态线上一字节不回（断连）。未登记偏差 | **未修复，登记遗留**（独立复核判定 acceptable 不阻塞；仅畸形输入可触发，无崩溃无挂死） | `BridgeProtocol.ets:112-117`：空行分支直接 complete=true，无 sawStatusLine 门（本会话读取核实） |
| IR-F2 | low | 即 R2-F4 的复查：修复未落地，代码无上界；头注"Int64.Parse 可用子集"表述对溢出形态不成立 | 同 R2-F4，登记遗留 | 同 R2-F4 证据行 |
| IR-F3 | low | 用例计数注释失真：List.test.ets:29 写 BridgeProtocol"31 条"（实 30）；BridgeProtocol.test.ets:7 breakdown 写"utf8Encode 4"（实 3 条 utf8Encode + 1 条常量；总数 30 正确） | **未修复，登记遗留**（纯注释失真，零行为影响） | 本会话核实：List.test.ets:29 文字"31 条" vs grep 计数 30（同文件 :32"合计 257+36=293"反推亦为 30，内部自相矛盾）；BridgeProtocol.test.ets:217/226/237 恰 3 条 utf8Encode 用例 + :48 常量用例 1 条 |

**矛盾登记**（报告员按"以门禁与日志为准"原则核对）：实现文件清单中 `List.test.ets` 与 `BridgeProtocol.test.ets` 状态为"通过/无改动"，但独立复核 IR-F3 指出的计数注释失真仍在文件中（上表证据）——两者不构成实质冲突（"通过"针对 R2 修复项复核，注释失真属 IR 新发现且零行为影响），如实登记为遗留。另：提交 `cd060a3` 的提交信息写"37 条协议单测"，与 grep 核实的 30+6=36 条（List.test.ets:32 合计 293 口径）不符，属提交信息笔误，不影响代码。

---

## ⑤ 验证情况

| 检查 | 结论 | 证据与口径 |
|---|---|---|
| **hvigor 编译门禁（主门禁）** | **通过** | **本会话报告员亲自复跑**：`devecocli build clean` → `devecocli build --modules entry`，输出 `BUILD SUCCESSFUL in 24 s 715 ms`，0 error；输出中可见的 ArkTS 告警（8 条，tail 截取窗口内）全部位于既有基线文件（SaveDirectory.ets:103×2、ProbeHttp.ets:230、ProbeClipboardSaveDir.ets:322/:344/:347/:349、DownloadSelectionDialog.ets:222），**U0.3 文件零告警**；门禁脚本记录共 10 条告警，同为既有基线文件（材料申报，余 2 条超出本轮 tail 窗口未直接看到）。增量复跑一次：0 WARN / 0 ERROR，`BUILD SUCCESSFUL in 471 ms`。与门禁结论（clean 后全量 BUILD SUCCESSFUL、0 ERROR）一致 |
| **codelinter 辅助（提示性）** | exit 0，无阻塞 | 门禁脚本执行（材料申报，输出前段被截断）：Summary: Issues 20 \| Errors 0 \| Warnings 18 \| Suggestions 2 \| Files checked: 6；可见条目为 pages/Index.ets 的 `@performance/hp-arkui-set-cache-count-for-lazyforeach-grid` 性能建议（既有页面，非本单元文件）。**本会话未复跑**（`where codelinter` 本机无此 CLI——本会话执行确认），按材料结论引用，如实标注 |
| **结构断言（设计书 §7-[A]-2）** | 通过（本会话执行 grep） | ① `grep -rn "XDM_PROBE" entry/src/main/ets/core`：代码级 0 命中（全部命中均为各单元文件内的红线声明注释，以 `*`/`/**` 起始）；② `grep -rn "import.*probe" entry/src/main/ets/core`：代码级 0 命中（3 处命中均为"禁 import probe/**"注释声明）；③ EntryAbility 中 BridgeServer 恰 import（:59）+1 次调用（:116）；④ ProbeIndex :43 注册 / :135-136 分支命中；⑤ main_pages.json 未改（仅 Index + ProbeIndex） |
| **对照审查** | 第 2 轮不通过（F1 high/F2/F3 medium/F4 low）→ 修复 F1-F3 → **第 3 轮 approved=true 零问题** | 材料申报（对照审查全史）；修复落地本会话逐处核实（§④ 表证据列） |
| **独立复核** | **acceptable=true**，3 条 low（IR-F1/F2/F3，均未修复登记遗留）；最薄弱点判定：parseHead"空行终止 vs 状态行契约"交界 | 材料申报；IR-F1/F3 的存在性本会话以读取/grep 复核成立（§④ 表） |
| **Hypium 本地单测** | **未实跑**（无本地 runner） | 36 条用例入库（BridgeProtocol 30 + ProbeBridgeLogic 6，grep 计数本会话核实）；设计书 §7-[A]-3 与测试文件头注均声明"runner 本会话不可验证，留统一回归"；报告员本会话亦未运行 |
| **运行时验收（curl/八路由/探针）** | **未执行** | 待探针 P0-U3 于模拟器/真机运行（§⑥） |
| **ArkTS 合规说明** | 由 **hvigor 编译期强制**（ArkTS 严格子集），codelinter 不含 ArkTS 语法规则（单元指令与 MIGRATION_PLAN §8:173 口径一致） | 编码期对照 arkts-grammar-standards 自查（对象字面量均具 interface 类型、正则一律 new RegExp（`BridgeProtocol.ets:80`）、无 any/解构/for...in、Map/平行数组替代字典等，设计书 §7-[A]-1 清单）；本会话 clean 全量编译 0 error 为最终裁决。另见 `BridgeServer.ets:164-167` arkts-limited-throw 处理注记（BusinessError 升型 Error） |

---

## ⑥ 运行时验证待办（探针运行指引）

本单元**有探针**：`P0-U3`（4 个观测步骤 + BEGIN/SUMMARY/END，共 7 条目）。

- **手册**：`XdmHarmony/docs/probe/PROBE-u0-3-extension-bridge-server.md`——含设备侧拉起命令（`hdc shell "aa start -b com.example.xdmharmony -a EntryAbility --ps page probe"`）、S1~S4 步骤表、主机侧全套命令（`hdc fport tcp:18597 tcp:8597` → `curl -i http://127.0.0.1:18597/sync` → 八路由逐条 → POST /sync → `fport rm` 清理）与扩展轮询时序注记（首轮 ~6s/稳态 ~5s）。
- **预期表**：`XdmHarmony/docs/probe/EXPECT-u0-3-extension-bridge-server.json`（本会话 node require() 解析通过：unitId=P0-U3，steps=7：BEGIN,S1,S2,S3,S4,SUMMARY,END）。
- **步骤要点**：S1 启动+端口监听（alreadyStarted/boundPort/portMismatch；alreadyStarted=true 即 EntryAbility 接线的运行时证据）；S2 应用内自连 GET /sync 应答观测（status=200/contentType/contentLength==bodyBytes/jsonValid=true/fieldCount=8/fieldOrder 八字段序/reuseResponses=2 keep-alive 复用/closeConnClosed 非对称关闭）；S3 主机侧 curl 指引（autoRun=false 手动，取主机 curl 后最后一次 minisession 判计数增长）；S4 八路由 404/错误处理（七业务路由 404 即可达证据、query 不剥、POST 200、malformedClosed=true 断连观测）。
- **验收判定基准**（单元验收项映射）：curl GET /sync 应答 `HTTP/1.0 200 OK` + 合法 JSON（stdout 过 JSON.parse）+ 八字段契约序；八路由 /sync=200、其余七条=404。**注意**：S4 的 malformedClosed=true 依赖 R2-F1 修复（已落地）；空状态行形态（IR-F1）不在 S4 观测集内，不构成 FAIL 项。S2 的 cacheControl/fieldOrder 判定值为 '/' 消毒呈现形（原始逗号形在 detail 文件交叉核对）。
- **回贴口径**：人工在模拟器运行后回贴 `probe-P0-U3` 日志全文 + EXPECT 表，用 `xdm-probe-verify` 工作流逐步骤判定并分流返修（env/business-code）。U0.3 验收一律在前台执行（设计书 §8.2）。

---

## ⑦ 遗留问题与风险

| # | 项 | 严重度 | 影响 | 建议去处 |
|---|---|---|---|---|
| 1 | **R2-F4/IR-F2：Content-Length 超 Int64 上界不设防**（`BridgeProtocol.ets:171-182` 无 MAX_SAFE_INTEGER 上界）：超界值进入"等体"分支无限等待（不回包不断连）；原版 OverflowException→断连 | low | 仅恶意/畸形输入可触发（connector.js/curl/探针均不发此形态）；常规八路由行为不受影响 | U6.1：加 `Math.abs(n) > Number.MAX_SAFE_INTEGER → return -2` 走断连，或在桥协议规格书登记接受偏差；同步修正头注"Int64.Parse 可用子集"表述 |
| 2 | **IR-F1：空状态行（首部裸 \r\n/\n）走 404 回包**（`BridgeProtocol.ets:112-117` 空行分支无 sawStatusLine 门），原版此形态断连不回包；偏差未在设计书 §4 登记 | low | 仅畸形输入可触发，无崩溃无挂死；与 R2-F1 同属"空行终止 vs 状态行契约"交界（独立复核判定最薄弱点） | U6.1：parseHead 空行分支加 sawStatusLine 门（空状态行 failed=true → closeSilently），对既有 30 用例与正常请求零影响；补差异登记 |
| 3 | **IR-F3：两处用例计数注释失真**（List.test.ets:29"31 条"应为 30；BridgeProtocol.test.ets:7 breakdown"utf8Encode 4"应为"utf8Encode 3 + 常量 1"） | low | 纯注释，零行为影响 | 下一轮触碰这两个文件时顺手修正（或 U6.1 一并） |
| 4 | **8597 常驻监听 × 后台冻结**：应用退后台空闲期进程可能被冻结，socket 停止应答 → 扩展侧 disconnect | 已知约束（设计书 §8.2 产线登记） | 下载活跃期由 U5.1 DATA_TRANSFER 连续任务保活；U0.3 验收仅前台 | U6.x 若需"后台也响应嗅探"再拍板保活策略 |
| 5 | **端口失配无 UI 提示**（原版 MSG_ALREADY_RUNNING 弹窗的 UI 等价物缺位） | low（设计书 §0-3 有意拍板） | portMismatch=true 时仅 hilog+探针可见 | U6.x 拍板是否补 UI |
| 6 | **Hypium 36 条用例未实跑**；**探针 P0-U3 未运行** | 待办 | 静态与逻辑验证已尽（含编码员 Node 转录脚本与独立复核 Node 实测），运行时结论悬置 | 探针按 §⑥ 执行；Hypium 留统一回归 |
| 7 | **七条业务路由 404**（有意差异 D2，本单元即骨架） | 非缺陷 | 扩展完整功能（下载接管/嗅探上报）在 U6.1 前不可用——符合单元定位 | U6.1 补全 |

---

## ⑧ 对下个单元的建议

下一单元为 **U6.1 BridgeServer 八路由完整版**（UNIT_CATALOG:78，前置 U0.3 本单元）：

1. **先收口解析边界**（独立复核最薄弱点提示）：一并处理 §⑦-1（Content-Length 上界）与 §⑦-2（空状态行 sawStatusLine 门）——两处同属"畸形字节 × 断连不回包契约 × 增量扫描器"交集，U6.1 起流量将真实化（扩展 POST 体），建议在写桥协议规格书时统一登记全部畸形输入语义表。
2. **桥协议规格书落笔**：把"未知路径 404、七业务路由 200+sync JSON（恢复原版统一应答）、解析失败断连不回包、恒 HTTP/1.0 状态行、恒 Connection: keep-alive、不剥 query、不校验 method/Content-Type"固化为规格条款（设计书 §0-2 既定方向）。
3. **POST 体解析对照 ExtensionData.cs 13 字段**（Url/Cookie/RequestHeaders/ResponseHeaders/File/Method/UserAgent/TabUrl/TabId/TabTitle/Referer/FileSize/MimeType/Vid）；UTF-8 解码用 util.TextDecoder（研究结论已核 API 12+ 可用）；utf8Encode 的 CJK/emoji 契约已立（Hypium 用例在库），videoList 接 U6.2 VideoTracker 时直接复用 `BridgeVideoItem`；业务路由接线点在 `dispatchRequest`（`BridgeServer.ets:303-322`）known 分支替换 404 兜底即可，注意 dispatch 层异常穿透契约（rethrow 至泵 → closeSilently）不破坏。
4. **顺手项**：§⑦-3 两处计数注释修正；U6.1 完成后回写 docs/ 根文档（本单元未回写）。
5. **探针对表**：U6.3 扩展实测时以本单元手册 §3 的扩展轮询时序（首轮 ~6s/稳态 ~5s）为观测基准；S2 的 reuseResponses=2 是 busy/pending 泵的回归观测，U6.1 改动 dispatchRequest/drain 时应保持该观测不回归。

---

## ⑨ git 提交说明

**任务材料口径为"代码未做 git 提交，待人工验收后由人提交并按 Phase 打 tag"；git 日志显示该状态已被后续会话更新——以 git 日志为准，特此登记矛盾：**

- 本会话执行 `git log --oneline -1` 与 `git status --short`（XdmHarmony 为独立 git 仓库）：**工作区 clean（无未提交/未跟踪变更）**，HEAD 为 `c8ba937 收尾：U0.3 回填+探针验收会话总指引（PROBE-SESSION-ALL.md…）`。
- U0.3 全部变更已含于提交 **`cd060a3`**（"U0.3: 扩展桥 8597 服务端（BridgeProtocol 字节级增量解析+BridgeServer TCPSocket 串行泵+八路由骨架+/sync 最小应答+…+P0-U3 探针…；审查修复解析失败分支死代码（畸形请求不断连））"）——`git log --follow -- core/bridge/BridgeServer.ets` 确认该文件由 `cd060a3` 引入。提交信息中"37 条协议单测"与 grep 核实的 36 条（30+6）不符，属提交信息笔误（§④ 已登记）。
- **`git tag -l` 输出为空**：Phase tag（`phase-0`）尚未打。
- 因此剩余人工动作收敛为：人工验收（含 §⑥ 探针 P0-U3 运行核对）通过后**按 Phase 打 tag**；本报告不代替该动作，也未做任何 git 提交/打 tag 操作。若验收发现问题，返修在新提交完成（`cd060a3` 即单元级回滚点）。
