# U2.3 引擎保真度对照单测收口 · 单元报告

> 单元：U2.3 引擎保真度对照单测收口（Phase 2 收口）｜报告日期：2026-09-28
> 设计书：[u2-3-engine-fidelity-DESIGN.md](./u2-3-engine-fidelity-DESIGN.md)｜保真度对照表：[u2-3-fidelity-matrix.md](./u2-3-fidelity-matrix.md)
> 结论速览：**三项验收全部达成**——四用例缺口补齐（+22 条，清零）、`hvigorw test` 脚本化执行接通并实跑全绿（117 条，磁盘 test_result.txt 实证 Tests run: 127, Failure: 0, Error: 0, Pass: 127）、46 项保真度对照表落盘（✅39+⚖️5+⛔2，无 ⏳ 残留）。编译门禁通过；对照审查三轮通过；本轮含一次经授权的引擎热修（COLD-F1，登记 D25），其运行时行为真实验证待小文件探针（已登记晨间待办）。

---

## ① 单元范围与验收要点

**单元目标**（单元指令）：①审计既有用例对照验收清单的缺口并补齐（指定四缺口：分裂序列 / 206 分支 / Content-Length 校验 / 恢复偏移）；②调研并尝试接通 Hypium 本地单测的脚本化执行入口，有则实跑并记录结果；③产出引擎保真度对照表（行为项↔源码锚↔用例↔执行状态）。

**验收要点**（单元指令 + UNIT_CATALOG U2.3 行）：

| # | 验收项 | 出处 | 结果 |
|---|---|---|---|
| 1 | 用例缺口清单清零或列明理由 | 单元指令 | **清零**：四缺口均确认无用例后全部补齐（新增 22 条，设计书 §7-[A]-6 缺口表逐项对账） |
| 2 | 对照表落盘 | 单元指令 | `docs/design/u2-3-fidelity-matrix.md`，46 行为项全回填（✅39/⚖️5/⛔2，无 ⏳） |
| 3 | 测试执行可行性有明确结论 | 单元指令 | **可脚本化执行并已实跑**：`hvigorw test` 命令链、前置条件、结果判读全部实测（设计书 §3.7 五轮接通实录） |
| 4 | 用例全绿 | UNIT_CATALOG U2.3 行（"用例全绿；与源码行为逐条对照表"，验证 [A]） | 117 条实跑全绿（见 ⑤） |

**审计前提修正**（事实更正，必须入账）：单元指令称"既有 38 条用例"，仓库实测 **95 条**（8 套经 `List.test.ets` 注册；`grep -c '^    it('` 逐文件计数，设计书 §0-1）。四指定缺口经逐条核对**均确无覆盖**（`closedRangeHeader`/`resumeRangeHeader` grep 测试目录零命中），故"38 条"不影响缺口结论，仅基数更正。

**改动面约束**：单元约束代码改动仅限测试文件与纯函数层；`PieceGrabber.ets`/`SegmentWorker.ets`/`EngineMath.ets`/`module.json5`/`main_pages.json`/`Config.ets` 为零改动红线④。例外一次：COLD-F1 引擎热修触碰 `PieceGrabber.ets`（+16 行），**跨红线④经主会话授权（方案 A）**，登记 D25（见 ③④）。

**本单元无探针**：UNIT_CATALOG U2.3 行验证列=[A]（纯逻辑单测），探针文件清单显式为空；本报告核实 `docs/probe/` 下无 EXPECT-u2-3/PROBE-u2-3 文件。运行时行为面由已归档 P2-U1/P2-U2 探针承担。

---

## ② 研究结论摘要（关键源码行为→ArkTS 对应表）

研究结论 11 facts + 2 openQuestions 全部消化：9 个行为面抽纯函数并用 Hypium 锁定，2 个 openQuestion（hvigor test 纳入门禁 / CI 无头风险）已拍板（设计书 §0-5/§0-7）。逐条对应：

| # | 源码行为（源码锚） | ArkTS 对应 | 用例与执行状态 |
|---|---|---|---|
| 1 | 非首请求响应三检：status≠206→NonRetriable(InvalidResponse,"Resume not supported")；Content-Range total 与 FileSize 不符→"Content length mismatch"（外层门 FileSize>0；**缺头 total=-1 时 mismatch 照常触发**——研究 fact 1 注记修正，本会话源码再核 DN.cs:94-98 + SS.cs:510-517） | `closedWindowValidationError` 纯函数 + 结果码 `CWV_OK/STATUS/TOTAL/START`（HttpProtocol.ets）；调度器 PieceGrabber.ets:673-691 内联同构 | C2-C8 共 8 条 ✅（含 compressed 206 拒续传、缺头触发、start 加固检） |
| 2 | compressed 改写：ContentLength 恒 -1、206→OK(200)（连带禁续传/总长-1/maxByteRange=-1）（PG.cs:181-188） | `effectiveProbeStatus(status, compressed)` 纯函数 | C1 共 2 条 ✅ |
| 3 | 恢复偏移数学：首请求 `bytes=0-`、非首请求 `bytes=S-E` 闭区间含端点、写盘 Seek(Downloaded)→恢复起点=绝对 Offset+Downloaded（PG.cs:387-395 + WRE.cs:160-177） | `windowOf`（既有已测）+ `resumeRangeHeader`/`closedRangeHeader` 头形态锚 | B1-B5 共 5 条 ✅（含窗口端点边界 downloaded=0/L-1/L） |
| 4 | maxByteRange=CL<=0?-1:Offset+CL；相邻吸收四条件（PG.cs:203-204/:270-283 + HB.cs:157-195） | `maxByteRangeOf` 纯函数（锁源码形）+ `continueAdjacentPiece`（既有已测）；运行时调用点用 windowEnd+1（等价论证 D23，COLD-F2 修正） | A7/A8/B7 ✅（A8 为论证锁：吸收运行时不可达 + 原版 CL 缺失回落全长时可达的 D6 完整边界） |
| 5 | 恢复集含未知大小片闭窗重派→NonRetriable(NonResumable)（PG.cs:169-170） | `isNonResumableResume` 纯函数（泛化形 length<=0，D20） | B6 ✅ |
| 6 | HttpException 且 Enum.IsDefined(HttpStatusCode)→终态，未定义码吞掉重试（PG.cs:98-106） | ⛔ 不移植（D21）：ArkTS phase 轴架构下无运行时消费者，补即死码；599 等边界偏差正式登记不复现 | —（有意差异） |
| 7 | 每轮读长=min(32*1024, remaining)；x==0 且 remaining>0→EOF 重试；Write IOException→DiskError 终态（PG.cs:284-290/:296-299） | `cappedReadLen`+`READ_BUF_LEN` 纯函数；worker 结果面（bytesWritten<窗口长→重试） | B8 ✅；E4/E5 ⚖️（P2-U1 探针承载） |
| 8 | 重试节奏：先增后判 >MaxRetry(10)（最多 11 次尝试）；connect 期 sleep(10s) 重试、body 期立即重试（PG.cs:113-124 + Config.cs:100-102） | `exceedsMaxRetry`（既有已测）；phase→sleep 判据由结构承载（D22 不抽死函数） | E1 ✅；E2/E8 ⚖️ |
| 9 | 探测面推导：Resumable=!compressed&&206；ResourceSize=compressed?-1:CL；每连接一次 CreatePiece（PG.cs:436-447 + SS.cs:228-293） | `probeResumable`/`probeTotalSize` 纯函数；probeConnected 调度器行为（**含 D25 小文件零派发兜底热修**） | D1/D2 ✅；D3 ⚖️（探针承载+热修待小文件探针） |
| 10 | （非 XDM 源）hvigor 6.24.4 内置全局任务 `test`：编译 src/test→Previewer.exe 宿主执行 Hypium（hvigor-ohos-plugin task-initializer/global-task-creation-manager 实读） | `hvigorw test` 接通并实跑（前置：模块级 hypium 依赖+斜杠导入形态） | 全套件 ✅（见 ⑤） |
| 11 | 进度数学（instantSpeed 整除/avgSpeed 浮点/eta Ceiling/500ms 门）+ chunks 持久化字段序（HB.cs:268-305/:557-590） | EngineMath 四函数 + buildChunksJson/parseChunksJson（既有已测） | E7（7 条）/E9（10 条）✅ |

完整 46 行为项×源码锚×用例×执行状态的对照表落盘于 **u2-3-fidelity-matrix.md**（A 分裂 11 + B 偏移恢复 8 + C 响应校验 9 + D 探测 4 + E 重试/进度/持久化/传输 14），统计与勘误注记见该表文末。

---

## ③ 设计决策与有意差异

**计划依据**（MIGRATION_PLAN.md）：§8 验证矩阵"保真度：引擎行为对照源码单测（分裂/续传/限速算法），Phase 2-3"；§6 决策 3（分段算法精确翻译：动态分裂+相邻吸收+identity+仅 Content-Length 校验——对等原版）、决策 4（分片落盘+进度持久化 JSON 化）、决策 9（HTTP 客户端 206 强校验/MaxRetry 10/RetryDelay 10s 对照 Config 默认值）、决策 10（状态 JSON）、决策 2（TaskPool 线程模型，本单元只读）。

**有意差异 D19-D25**（设计书 §4 全表，摘录）：

| # | 差异 | 性质与依据 |
|---|---|---|
| D19 | `headerValueOf` 查询名小写化 | **实跑发现的真实缺陷修复（非降级）**：原实现只小写化键侧，混合大小写查询恒返回 ''，与自身"不区分大小写"契约相悖（R5 实跑 + coverageReport.json 行计数定位）；生产 5 调用点全传小写名（SegmentWorker.ets:201-203、HttpProtocol.ets:111-112），行为零变化 |
| D20 | `isNonResumableResume` 锁调度器泛化形 `length<=0`（源码 `Length==-1`） | 泛化更防御；length==0 仅恢复畸形数据可达；用例两形都锁 |
| D21 | `isDefinedHttpStatus`（Enum.IsDefined(HttpStatusCode)）不移植 | 死码裁剪：ArkTS phase 轴架构下 HttpException(status) 分类无运行时消费者（传输异常统一 status=0→connect 重试）；研究 fact 6 的 medium 边界偏差（如 599 原版重试）在此正式登记不复现 |
| D22 | phase→sleepBeforeRetry 判据不抽独立纯函数 | 判据由结构承载（SegmentWorker.ets:210 + PieceGrabber.ets:794/:838），函数体无信息量；先增后判节奏已由 exceedsMaxRetry_boundary 锁定 |
| D23 | maxByteRange 运行时调用点用 windowEnd+1，源码形 `maxByteRangeOf` 仅纯函数锁定不接线 | 行为等价论证（COLD-F2 修正版）：两形相等仅当连接时 Downloaded==0；一般情形两形均≤邻片 Offset、吸收恒 false——**原版边界：CL 头缺失时 DN.cs:32 回落 Content-Range total=文件全长，源版闭窗吸收在该场景可达**（D6 完整边界，不复刻） |
| D24 | 闭窗 total 校验省略源码外层门 `contentLength>0` | 可达性极低（空 206 退化响应）；`probeTotalSize` 的 Content-Range fallback 为 U2.1 既有加固（源码 :440 无 fallback） |
| D25 | **引擎热修（COLD-F1，跨红线④经主会话授权）**：probeConnected 分裂派发分支增零派发兜底——records 满载（:536 早退）或 findMaxChunk 无候选（小文件 totalSize≤262144 严格 `>` 不命中）时对探测片直派闭窗窗口 | 缺陷属 U2.1 既有代码（可续传小文件/maxSegments=1 会话探测后永挂：探测 record 被 :800-803 静默删除后无任何驱动）；单 hunk 纯新增 16 行（PieceGrabber.ets:748-770，git diff 实证），注释含完整挂起链证据与原版对照（PG.cs:87 流式下载）；大文件/多段流零变化。**运行时真实验证待小文件探针** |

**测试基建三处事实性修正**（实跑证据，对后续所有单元有效）：①hypium 导入必须斜杠形态 `'@ohos/hypium'`（点形态 hvigor 6.24.4 报 Cannot find module）；②模块级 `entry/oh-package.json5` 必须声明 hypium（仅根级不足）；③hypium 1.0.25 Assert 面无 `assertNotNull`（谓词等价断言替代）。

**研究结论两处修正**（入账）：①fact 1 "Content-Range 缺失时该检查永不触发"不成立（DN.cs:94-98 返 -1 + SS.cs:510-517 FileSize>0→-1≠FileSize→mismatch 触发）；②ask 所述"38 条用例"实为 95 条（grep 逐文件计数实测）。

---

## ④ 审查问题处置表（覆盖全部轮次）

审查共 3 轮 + 收口轮 2 项修复（COLD）+ 终轮独立复核 3 项发现。处置状态均经本报告会话核实：

| 编号 | 轮次 | 严重度 | 问题摘要 | 处置 | 证据（本会话核实方式） |
|---|---|---|---|---|---|
| R1-F1 | R1 | medium | 对照表 A 段与 D3 源码锚**文件前缀错标**（FindMaxChunk/ContinueAdjacentPiece/CreatePiece 等 8 处标 PG.cs，实为 HB.cs；D3 落位实为 SS.cs） | ✅ 已修复（提交 08cfc8a + COLD-F2 再复核） | 本会话通读现行矩阵：A3-A10 均 HB.cs、段标题"PieceAlgo / HB.cs:307-466"、D3 为 SS.cs:238-245/:272-275 |
| R1-F2 | R1 | medium | `entry/oh-package-lock.json5` 实际新增但未列入设计 files 清单、未入库 | ✅ 已修复 | 提交 08cfc8a 文件清单含该文件（+20 行）；设计书 §1 #1 已补登记 |
| R1-F3 | R1 | low | `entry/src/main/ets/core/engine/.hvigor/` 构建残留目录（0 字节 build.log）误生成于主源集 | ✅ 已删除 | 本会话 `ls entry/src/main/ets/core/engine/` 实证无 .hvigor/ |
| R1-F4 | R1 | low | NIGHT-RUN.md 进度表 U2.3 行重复（旧行未删） | ✅ 部分修复→R2 发现加重（U3.1 行也重复）→移交 R3 处置 | 见 R2-F2/R3-F1 行 |
| R2-F1 | R2 | medium | R1-F3 修复时 .gitignore 两条规则被拼成一行 `/.appanalyzersrc/main/ets/core/engine/.hvigor/`（原 `/.appanalyzer` 规则丢失） | ✅ 已修复 | 本会话 `cat -A .gitignore` 实证尾两行为独立的 `/.appanalyzer$` 与 `src/main/ets/core/engine/.hvigor/$` |
| R2-F2 | R2 | low | NIGHT-RUN.md :19/:20 两旧行（U2.3 旧名待启动、U3.1 旧"队列调度"待启动）残留，行号 5/6 重复 | ⏸ 未修（移交） | 本会话 `grep -n` 实证 :19/:20 两旧行仍在 |
| R3-F1 | R3（approved） | low | 同 R2-F2（历史反馈未传达给编码员） | ⏸ 移交主会话：跨单元活文档，下次提交时顺带删除 :19/:20，不阻塞本单元收口 | 同上 |
| COLD-F1 | 收口轮 | — | **可续传小文件（≤256KiB）/maxSegments 满载探测永挂**：probeConnected 分裂派发分支对零候选场景无条件 createPiece→本轮零派发→探测 record 被 :800-803 静默删除→records 空+running=true 永挂（原版探测连接流式下载不挂） | ✅ 已热修（跨红线④经主会话授权，方案 A） | 本会话实读 PieceGrabber.ets:748-770：`else if (records.size>=maxSegments \|\| findMaxChunk===null)` 分支直派 `dispatchPiece(pieceId,false,false,0)`，注释含挂起链与原版对照；git diff 实证 +16 行；D25 入设计书 §4 |
| COLD-F2 | 收口轮 | — | D23/A8/B7 五处论证与实测数学不符（"两形相等"仅在 Downloaded==0 成立），且缺 DN.cs:32 CL 缺失回落全长时原版闭窗吸收可达的 D6 完整边界 | ✅ 已改写 | PieceAlgo.ets:257-266 注释、矩阵 A8/B7 行、设计书 §3.3/§4 D23 均为修正版论证；本会话只读复核 XDM 源 HttpResponse.cs:24 确认 ContentRangeLength 锚 |
| 复核-F1 | 终轮独立复核 | low | COLD-F1 修复后残留同族挂起变体：探测 connected 消息通道失败（worker sendData 抛出/主线程 parse 失败）时 onWorkerResult :800-803 仍无条件删 record、无兜底重派 | ⏸ 未修（低优先）：登记遗留，建议并入 D25 探针待办批次做防御加固（probe 分支删除前判 !init 按连接期失败处理） | 复核材料定位 PieceGrabber.ets:800-803 + SegmentWorker.ets:234 |
| 复核-F2 | 终轮独立复核 | low | NIGHT-RUN.md :19-20 旧行仍残留（R3-F1 遗留） | ⏸ 维持 R3 处置（移交主会话） | 本会话 grep -n 实证 :17-20 四行并存 |
| 复核-F3 | 终轮独立复核 | low | 4 处**行级锚点漂移**（文件前缀均正确）：①PieceAlgo.ets:43/:253 与 ②矩阵 B8 引 "PG.cs:259"，字面量实为 :260（:259=`#if NET35`）；③矩阵 D4 引 "HttpResponse.cs:30-32"，ContentRangeLength 实为 :24；④设计书 D25 行 "749-769"，分支闭于 :770 | ⏸ 未修（一次性顺带改四处，不阻塞） | 本会话只读复核源码实证：PieceGrabber.cs:257-263 中 :259 为 `#if NET35`、:260 为 `new byte[32*1024]`、:262 为 ArrayPool.Rent；HttpResponse.cs:24 为 ContentRangeLength |

已修复问题编号汇总：**R1-F1、R1-F2、R2-F1、COLD-F1、COLD-F2**（R1-F3 亦闭环）。未修遗留全部为 low（见 ⑦）。

---

## ⑤ 验证情况

| 验证项 | 结论 | 证据与命令 |
|---|---|---|
| **hvigor 全量编译门禁** | **通过** | `devecocli build --modules entry` → BUILD SUCCESSFUL（3m25s，CompileArkTS+PackageHap，零 error）。门禁由工作流执行并回传结论；COLD-F1 热修后复跑通过 |
| **codelinter（辅助，提示性）** | 通过（0 error） | Summary: Issues 14 / **Errors 0** / Warnings 14 / Suggestions 0 / Files checked 3——14 条均为探针文件 `@performance/avoid-overusing-custom-component-check` 提示性 Warning。注：codelinter 不含 ArkTS 语法规则，仅辅助 |
| **Hypium 本地单测（[A] 门禁主项）** | **实跑全绿** | 执行链：`DEVECO_SDK_HOME` + DevEco 自带 node.exe 执行 hvigorw.js `test`（hvigor 6.24.4 + hypium 1.0.25 + Previewer.exe GUI 宿主）。**磁盘证据（本会话实读）**：`entry/.test/default/intermediates/test/coverage_data/test_result.txt` = `Tests run: 127, Failure: 0, Error: 0, Pass: 127, Ignore: 0`。127 = U2.3 范围 117 + 并行单元 U3.1 先行落入的 QueueAlgo 10 |
| 用例计数核对 | 117（U2.3）+10（U3.1）=127 | 本会话实跑 `grep -c '^    it(' entry/src/test/*.test.ets`：DownloadTypes 4 / EngineMath 10 / FileNameFormat 13 / HttpProtocol 26 / List 0 / PieceAlgo 31 / ProbeDownloadLogic 4 / ProbeHttpLogic 16 / QueueAlgo 10 / RecordMapping 13 |
| **对照审查** | 三轮通过（R3 approved） | R1：4 发现（2 medium+2 low）→修复；R2：2 发现（1 medium+1 low）→medium 修复；R3：approved，唯一 low 发现移交主会话 |
| **独立复核（终轮）** | **acceptable=true** | 两项收口修复逐行核验为正确（COLD-F1 兜底分支触发条件与 createPiece 零派发结局严格等价、消息双序收敛于 pieceDownloadFinished→assemblePieces；COLD-F2 三处改写与 DN.cs:32 实读语义一致）。最弱处=**验证面**：D25 兜底分支至今零运行时执行覆盖（现有探针源均 4MiB，触达不了 ≤256KiB 小文件路径），依赖已登记的晨间探针批次 |
| 缺口清单 | **清零** | 四指定缺口（分裂序列/206 分支/CL 校验/恢复偏移）→ 22 条新用例补齐（设计书 §7-[A]-6 逐项对账）；矩阵无 ⏳ 残留 |
| **ArkTS 合规** | 由 hvigor 编译期强制 | UnitTestArkTS 任务对 src/test+主源集做全量 ArkTS 严格子集编译，零 error（hypium 导入修复、assertNotNull 谓词化等均在该编译面验证）；codelinter 不承担语法检查 |

**执行环境与可行性结论**：`hvigorw test` 脚本化执行**已接通并实跑**，纳入每单元 [A] 门禁；执行环境=开发机桌面（test 任务以 Previewer.exe GUI 宿主 spawn），**无头 CI 不承诺复现**，失败退回 DevEco IDE 手跑注记。注：本报告会话未重跑 hvigorw test 与 devecocli build（避免重复全量构建/写构建产物），以上实跑结论来自工作流门禁执行、独立复核实跑（exit=0、BUILD SUCCESSFUL 4s777ms、stdout 零 `ERROR: Error in` 行）与本会话对磁盘产物 test_result.txt 的实读。

---

## ⑥ 运行时验证待办（探针）

**本单元无探针**（UNIT_CATALOG U2.3 行验证=[A] 纯逻辑；探针文件清单显式为空；`docs/probe/` 无 EXPECT-u2-3/PROBE-u2-3 文件）。探针日志规范（[XDM_PROBE] 标记、hilog domain 0xD001/tag XDM_PROBE）见 docs/PROBE_SPEC.md，适用于后续探针单元。

**随本单元登记的探针覆盖待办**（收口轮新增，非本单元交付物）：

1. **小文件（≤256KiB）可续传路径探针**：D25 热修兜底分支（probeConnected 直派闭窗窗口）现有探针 P1-U2/P2-U1/P3-U1 均以 4MiB 源触达不了；晨间验证批次需补 ≤256KiB 源用例，预期观测链=probeConnected 兜底派发 → 单片 pieceDownloadFinished → onFinished 收敛。预期表位置：晨间清单（NIGHT-RUN.md 文末）+ 后续单元的 EXPECT 表（docs/probe/）。
2. **复核-F1 变体同批验证**：探测 connected 消息通道失败变体（若做防御加固）一并纳入该批次。

---

## ⑦ 遗留问题与风险

| # | 遗留/风险 | 级别 | 说明与建议 |
|---|---|---|---|
| 1 | D25 热修运行时行为零执行覆盖 | 中 | 独立复核认定的最弱处：单测够不到调度器行为，现有探针源全是 4MiB。缓解：已登记小文件探针待办（⑥-1）；热修逻辑经逐行核验（触发条件与 createPiece 零派发结局严格等价、终态与源码 ：194-196 同貌） |
| 2 | 探测 connected 消息通道失败挂起变体（复核-F1） | 低 | 可达性低（sendData 正常不抛）；建议并入 ⑥ 批次做防御加固 |
| 3 | NIGHT-RUN.md :19-20 旧行残留（R2-F2/R3-F1/复核-F2） | 低 | 跨单元活文档，移交主会话下次提交时删除 |
| 4 | 4 处行级锚号漂移（复核-F3） | 低 | 一次性修正：PieceAlgo.ets:43/:253 与矩阵 B8 的 "PG.cs:259"→":260"；矩阵 D4 "HttpResponse.cs:30-32"→":24"；设计书 D25 行 "749-769"→"749-770" |
| 5 | 无头 CI 风险 | 低 | test 任务 spawn GUI 宿主（Previewer.exe），无显示器 CI 可能启动失败；执行环境注记=开发机桌面，不承诺 CI 复现 |
| 6 | D21 边界偏差 | 低 | 未定义 HttpStatusCode 码（如 599）原版重试、本引擎 connect 重试分类——有意差异，正式登记不复现 |
| 7 | 工作区多单元混杂未提交 | 中 | 当前工作区同时含 U2.3 收口改动与并行单元 U3.1 全套未提交文件（见 ⑨），提交时需按单元分离，避免交叉污染 |

---

## ⑧ 对下个单元的建议

1. **U3.1（队列调度+并发上限，当前运行中）**：测试基建三件套直接沿用——斜杠形态 hypium 导入、模块级 devDependencies 声明（`entry/oh-package.json5` 现状正确）、断言避免 assertNotNull；每轮以 `hvigorw test` 全绿作为 [A] 门禁（QueueAlgo 10 条已先行入套件并全绿）。
2. **提交纪律**：下次提交前顺带清理 NIGHT-RUN.md :19-20 旧行并修正 4 处锚号漂移（均为 1-2 行改动）；COLD-F1 热修按授权由主会话单独提交，提交信息需注明跨红线④授权与挂起链证据。
3. **探针批次**：小文件（≤256KiB）探针用例建议与 U3.1 的队列行为探针合并为一个晨间验证批次，减少真机/模拟器往返。
4. **对照表节奏**：保真度矩阵的组织方式（行为项↔源码锚↔用例↔执行状态 + ⚖️/⛔ 三态图例）已在 Phase 2 验证可行，建议 U3.x 继续沿用（限速/重试单元对应 E 段扩展）。

---

## ⑨ git 提交说明

- **主干已提交**：U2.3 主体在流水线提交 **08cfc8a**（16 文件，+893/-33：hvigorw test 打通、四大缺口补齐、headerValueOf 修复、矩阵 46 项回填、模块级 hypium 依赖）。
- **收口轮改动未提交**：COLD-F1 引擎热修（`entry/src/main/ets/core/engine/PieceGrabber.ets`，+16 行）与 COLD-F2 文档改写（`PieceAlgo.ets`、设计书、矩阵）及 `.gitignore` 回归护栏共 7 个 U2.3 相关文件处于工作区修改态（`git status` 实证为 M）；按授权 COLD-F1 待主会话单独提交，**截至本报告时点尚未落成新提交**（git log 最新提交仍为 08cfc8a）。
- **并行单元文件混在工作区**：U3.1 的未提交文件同在工作区（新增 7 个：DownloadManager.ets/QueueAlgo.ets/ProbeQueue.ets/QueueAlgo.test.ets/u3-1 设计书/EXPECT/PROBE 文档；修改 5 个：Config.ets/Index.ets/ProbeIndex.ets/string.json/List.test.ets）——提交时须与 U2.3 收口改动**分离提交**。
- **流程约定**：代码不做自动 git 提交，待人工验收通过后由人提交并按 Phase 打 tag（Phase 2 收口建议 tag 注明 08cfc8a+收口轮修复）。
