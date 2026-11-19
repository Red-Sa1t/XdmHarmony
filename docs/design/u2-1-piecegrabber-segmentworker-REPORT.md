# U2.1 迁移单元报告：PieceGrabber+SegmentWorker 并发

> 单元：U2.1（Phase 2 第 1 单元，探针单元 ID `P2-U1`）｜对照源码：`resourses/xdm/app/XDM/XDM.Core/Downloader/Progressive/`（PieceGrabber.cs 472 行、HTTPDownloaderBase.cs 636 行、SingleSourceHTTPDownloader.cs 540 行等，只读）
> 设计书：[u2-1-piecegrabber-segmentworker-DESIGN.md](./u2-1-piecegrabber-segmentworker-DESIGN.md)｜工作流：xdm-migrate（研究→设计→编码→对照审查 R2~R4→独立复核→本报告）
> 报告生成：2026-09-28。报告内所有代码锚点均在本会话逐文件读取核实；所有标注"本会话执行"的检查为报告员亲跑，其余为工作流材料转述并注明。

## ① 单元范围与验收要点

**范围**（UNIT_CATALOG.md:48）：动态分裂逐行翻译（单 Piece `Range:0-` 探测→206 判 resumable→最大剩余分片对半分裂、阈值 256KB）；相邻分片吸收 ContinueAdjacentPiece；TaskPool 并发（MaxSegments=8）。目标落点 `core/engine/PieceGrabber.ets`、`SegmentWorker.ets`（实际扩展为 15 文件清单，见 §⑤）。

**验收要点**：①"8 分段并行"观测（探针 S2 maxConcurrent=8）；②大文件吞吐显著优于 U1.2（探针 S4 ratio）；③区间不重叠+全覆盖（S3）；④多分片拼接字节正确（S2/S5 allSpotsMatch）；⑤取消排空（S5 activeAfterStop=0）。验证方式 [A]+[P]：[A] 门禁本会话已过（见 §⑤），[P] 探针待人工运行（见 §⑥）。

**单元边界拍板（D17，与目录字面有意不一致）**：UNIT_CATALOG.md:49 把"完成按 Offset 排序 5MB 缓冲拼接"列在 U2.2；本单元按 MIGRATION_PLAN 决策 4（"分片落盘：每分片独立临时文件+追加写+完成后顺序拼接"为同构整体）与探针验收闭环需要（AllFinished 后必须产出成品文件，否则字节抽查无从取材）将多分片 assemblePieces 划入 U2.1；U2.2 仅做分片进度 JSON 持久化+杀进程续传。

**配置文件说明**：本单元唯一配置文件改动是 Config.ets 补第 6 键 maxSegments（Config.ets:33-41 本会话核实）。module.json5 与 main_pages.json 无改动且**正确地不列入 files 清单**——本会话核实 module.json5:7 deviceTypes、:14-16 `ohos.permission.INTERNET` 均已由 U0.1 落地（设计书 §0-9），TaskPool 为进程内能力非权限门控，本单元无新增系统能力。注：单元指令模板"当前缺 ohos.permission.INTERNET"的表述对本工程现状已过时，以文件实况为准。

## ② 研究结论摘要（关键源码行为 → ArkTS 对应表）

研究阶段产出 12 facts + 2 openQuestions（全部来源文件全文读取核实）。核心行为与落点：

| # | 源码行为（C#） | ArkTS 落点（本会话核实） |
|---|---|---|
| 1 | 调度核心 CreatePiece（HTTPDownloaderBase.cs:307-332）：每次连接成功触发一次分裂（SingleSourceHTTPDownloader.cs:292 PieceConnected 末尾无条件调用），MAX_COUNT=Config.MaxSegments=8（Config.cs:122） | PieceGrabber.ets `createPiece()` :433-458 逐行（MAX_COUNT 门 :437、retryFailedPieces 消耗预算 :441、findMaxChunk/splitPiece :444-446、分裂命中在途片 cancel+重派下半区 :450-452、新上半片 :454）；每连接一次分裂驱动在 onConnectedMsg→createPiece（:546/:571）；Config.ets 第 6 键 :33-41 |
| 2 | 分裂数学 FindMaxChunk/SplitPiece（HTTPDownloaderBase.cs:405-466）：rem 最大者（严格 `>`）、阈值 256*1024、新片取上半区 `Offset=Offset+Length-len`、原片活体缩短 `Length-=len` | PieceAlgo.ets 纯函数（零 @kit，U2.3 单测对象）；SPLIT_THRESHOLD=262144；活体缩短无共享通道→cancel+按收缩后窗口重派（D5，三支柱论证设计书 §3.6，SegmentWorker.ets 文件头 :4-13 落地为审查必查项） |
| 3 | 单 grabber 主循环与异常分类（PieceGrabber.cs:68-140）：NonRetriable/AssembleFailed/OperationCanceled 上抛；HttpException→InvalidResponse；其余吞掉 timesRetried++ 超 10→MaxRetryFailed；仅 connectPhase 失败 sleep 10s（可被 Stop 唤醒） | onWorkerResult 分类（PieceGrabber.ets:632-717）+ retryConnectPhase :747-771（sleep 与 pauseGate Promise.race :766）+ retryImmediately :734-743（先 ++ 后判，EngineMath.exceedsMaxRetry 1:1）；timesRetried 为 record 粒度（DispatchRecord :121-122，重派新建 record 归零，约束③） |
| 4 | 首请求/非首请求 Range 构造（PieceGrabber.cs:368-397 + DotNetHttpSession.cs:46-52）：首请求 `bytes=0-` 开区间接受 200/206；非首请求闭区间 `bytes=X-Y` 且强检 206，contentLength>0 且不符→InvalidResponse | HttpProtocol.ets `closedRangeHeader(start,end)` :145（本会话核实）；per-attempt 分类（D12）：开窗口 record.openWindow 接受 200/206（PieceGrabber.ets:535-547），闭窗口三检 :549-571（206 强检/total==fileSize/start==windowStart） |
| 5 | 探测 ProbeResult 与 PieceConnected 落位（PieceGrabber.cs:436-447 + SingleSourceHTTPDownloader.cs:228-293）：ResourceSize/Resumable/FinalUri 等仅首连接携带；freespace<ResourceSize→DiskError | probeConnected（PieceGrabber.ets:574-628）：isSuccessStatus 门 :577、探测值落位 :586-602、events.onConnected :605（U1.2 六方法签名冻结，Downloader.ets:21-28）、盘空间预检 statfs.getFreeSizeSync :608-618（§0-11 照译）、splittingAllowed 分派 :620-627 |
| 6 | 相邻分片吸收 ContinueAdjacentPiece（HTTPDownloaderBase.cs:157-195）：窗口读完以 maxByteRange 尝试吸收；闭区间连接数学上不可满足成功条件（唯一成功路径=探测连接） | PieceAlgo.ets 纯函数逐字保真 + 完成路径原位调用（PieceGrabber.ets:695）；运行时恒 false 为已登记偏差（D6），算法由 U2.3 用例锁定 |
| 7 | 字节账本 UpdateDownloadedBytesCount（:268-305）：total+=bytes、>500ms 进度门、2000ms 状态保存门 | worker progress 消息（SegmentWorker.ets:244-262，250ms 周期 try/catch 降级）→onProgressMsg（PieceGrabber.ets:508-520）→emitProgressIfDue :821-837（EngineMath 数学零改动）；2000ms SaveChunkState 门为空注释锚（D8，持久化归 U2.2，:457/:787/:806 锚点本会话可见） |
| 8 | 终态族：PieceDownloadFailed（:224-241）删 record→空则 OnFailed；PieceDownloadFinished（:243-266）全完→AssemblePieces；AllFinished（:334-349） | pieceDownloadFailed :798-810 / pieceDownloadFinished :777-793 / failDownload :812-817；多分片拼装 assemblePieces :844-971（排序+盘检 :871-880+5MB 缓冲 :887/:104+按 pc.length 精确读 :913-927+EOF 早尽→Generic :922+清 temp :944/:974-992）；EngineMath 不补 3/9 错误码（D18，EngineMath.ets:26-30 本会话核实仅 1/2/4/5/8） |
| 9 | 数据模型 Piece/SegmentState/ErrorCode（Piece.cs:6-37 等）：三 long 字段 Interlocked；State 只赋 0/1；活跃=grabberDict 成员资格 | EnginePiece 普通字段（主线程单点后无并发写者，决策 2）；SEG_*/STREAM_* 常量锚枚举序；Id=util.generateRandomUUID()（:195/:445）；活跃=records 成员资格（activeIds :420-426） |
| 10 | 落盘（PieceGrabber.cs:219-255 + :233-236）：分片文件=TempDir/pieceId，OpenOrCreate+Seek(Downloaded,Begin)；32KiB 定长拷贝；IOException→DiskError | worker 局部 fd（SegmentWorker.ets:146/:158-169 开档+lseek、:284-290 finally closeSync，约束④禁入共享字段）；onChunk 窗口定长封顶 :177-184+isCanceled 先查后写 :172-176+writeSync 异常捕获 :186-194 |
| 11 | Stop 语义（PieceGrabber.cs:142-157 + HTTPDownloaderBase.cs:109-130）：cancel+Abort+唤醒 sleep；引擎级逐 grabber Stop、temp 保留 | stop()（PieceGrabber.ets:239-260）：代际自增+逐 record taskpool.cancel+records.clear（D9 不复刻死 grabber 滞留 bug）+pauseGate 放行+onPaused(Σdownloaded)（D10）；sleep 唤醒=pauseGate Promise 门（:766） |
| 12 | RetryFailedPieces/GetInactiveChunkCount/GetInactivePiece（:351-403）：先补失败片；计数缺 Downloaded==Length 排除项为源码原貌 | retryFailedPieces :462-477 逐行；计数缺排除项逐字保留不"顺手修复"（D16），U2.3 用例锁定 |

## ③ 设计决策与有意差异

线程模型遵循 MIGRATION_PLAN §6 决策 2（"原版每分片裸 Thread+阻塞读+ReaderWriterLockSlim → SegmentWorker 走 TaskPool；dataReceive 事件流替代阻塞读；pieces 字典主线程单点管理（消除锁）"），分段算法遵循决策 3（精确翻译+强制 identity），分片落盘与拼接遵循决策 4。设计书登记 18 条有意差异（D1~D18，全文见设计书 §4），要点：

| 差异 | 内容 | 依据 |
|---|---|---|
| D1 | 裸 Thread+阻塞读+锁 → taskpool.Task+dataReceive 事件流+主线程单点无锁 | 决策 2 |
| D2 | progress 由共享内存逐块计数改为 Task.sendData 250ms 周期消息（+完成终值；定时器回调内发送 try/catch 降级） | d.ts :283 NOTE |
| D3 | 探测连接取头即 abort（原版同流续写下半区+活体吸收）→0 字节探测+下半区闭区间显式重派，+1 次握手零重复字节 | 窗口按值不可变 |
| D4 | 非 resumable/未知大小显式单 worker 整流模式（splittingAllowed=false），替代原版失败风暴收敛循环，终态等价 | §0-4 |
| D5 | 分裂命中在途分片→cancel+立即重派下半区；重派起点=最近 progress 回报（前缀覆盖幂等） | §3.6 三支柱 |
| D6 | ContinueAdjacentPiece 逐字保真+完成路径原位调用，但闭区间窗口数学上不可成功——运行时恒 false 的 parity 调用 | 本会话推导 :171 条件 |
| D7 | 不移植：连接复用禁令/TextRedirect/文件名嗅探/AssemblingProgressChanged/FetchServerTimeStamp；盘空间预检经 statvfs 证伪后**改为照译移植**（设计书 §0-11 对前轮论断的修正） | 源码行号 |
| D8/D9/D10/D11 | SaveChunkState 空锚（U2.2）；Stop 后死 grabber 滞留 bug 不复刻；停止单入口 stop()；SessionExpired(9) 延后 U3.x、拼装失败分类 DiskError/Generic | 决策 4/U1.2 既定 |
| D12/D13/D14/D15/D16 | 首请求分类 per-attempt；HttpResponseHead 增 errCode；TickCount→Date.now()；"8 段并行"=8 Task 在途（观测口径 activeSegmentCount）；Map 插入序+计数缺项原貌保留 | 各锚 |
| D17/D18 | 单元边界（拼接归 U2.1）；EngineMath 不补 3/9 错误码（grep 证实引擎侧从未构造，补即死码） | §0-12/§0-13 |

## ④ 审查问题处置表（全轮次：对照审查 R2/R3/R4 + 独立复核）

已修复认定以本会话代码读取为准（非仅凭材料自述）：

| 编号 | 严重度 | 问题摘要 | 处置 | 证据（本会话核实） |
|---|---|---|---|---|
| R2-F1 | high | 陈旧 progress 消息污染新 record（虚增恢复点→分片文件空洞→拼装错位） | **已修复** | onReceiveData 闭包捕获 rec 本体 PieceGrabber.ets:382-384；onWorkerMessage 入口本体守卫 `!rec.alive \|\| records.get!==rec` :485-489 |
| R2-F2 | high | 探测尝试连接期失败被静默吞（探测 record 删除后无重试无 onFailed，引擎 running=true 永久挂起） | **已修复** | phase==='connect' 判定移到 result.probe 之前：:668-671（connect 先行）→:674-677（probe 收尾），探测 connect 失败走 retryConnectPhase（保持 probeMode/openWindow :757-758） |
| R2-F3 | medium | progress 降级承诺未落地（sendData 被拒后 onProgress 全程不发射，UI 停摆、S5 拖满超时） | **已修复** | onWorkerResult 账本更新后调用 emitProgressIfDue()：:678-688 |
| R2-F4（=R3-F2=R4-F1=复核 F2） | low | 闭窗口 connected 校验对缺 Content-Range 头响应偏严（C# 仅 contentLength>0 才查 total；现实现无头也执行两检，边缘 206 响应被误判终态） | **仍开放（历轮已接受登记）** | :549-568 现况无 contentLength>0 门、parts.start 校验无条件执行 |
| R2-F5（=R3-F3=R4-F2=复核 F3） | low | worker 写盘 IO 错误不短路（置 diskErrCode 后继续收完整条响应体才返回，终态判定推迟上限=流时长；主线程分类 R3-F1 修复后已正确，仅剩 worker 侧时序） | **仍开放（历轮已接受登记）** | SegmentWorker.ets:186-194 捕获后无 client.abort() |
| R2-F6（=R3-F4=R4-F3=复核 F4） | low | PieceGrabber.ets↔Downloader.ets 循环 import（设计书 §1 依赖表未登记反向边） | **仍开放（运行时可用，无顶层执行依赖；登记为文档层缺口）** | PieceGrabber.ets:100 ↔ Downloader.ets:15 本会话核实 |
| R2-F7（=R3-F5=R4-F4=复核 F7 部分） | low | 清单外文件 oh-package-lock.json5 变更 | **无需代码改动（构建期自动再生，AUTOGENERATED，仅 hamock/hypium 锁定）**；另 NIGHT-RUN.md（09:13，工作流台账）、.zcode/workflow-runs/*.mjs（工作流基础设施）同口径登记 | 复核 F7 实测 mtime 转述 |
| R3-F1 | medium | R2-F2 修复引入回归：worker 开档/lseek 失败（phase='connect'+diskErrCode≠0）被误入 10×10s 重试环，最终 MAX_RETRY(4) 而非立即 DiskError(8) | **已修复** | diskErrCode!==0 判定前置到 connect/probe 之前：:658（diskErrCode）→:668（connect）→:674（probe）行序本会话逐行核实；SegmentWorker.ets:131 初始 phase='connect'、:165-169 开档失败路径不改 phase 亦核实 |
| 复核 F1 | **medium** | **探测 result 先于 connected 消息到达时引擎永久挂起**：probe 收尾分支无条件 records.delete（:674-677），而 onWorkerMessage 对一切消息先过 record 本体守卫（:487）——result 先到即删 record，晚到的探测 connected 被丢，probeConnected 永不执行、init 恒 false、无终态。与设计书 §3.5/§8"connected 处理按 pieceId+!init 守卫，不依赖 record 存在""次序互逆均安全"的承诺**不符**；:672-673 注释自述"互逆均安全"与实际代码不符 | **仍开放**（复核 acceptable=true 总体放行，此项为其唯一 medium 与 weakestSpot，未返修）——见 §⑦ 风险首位 | PieceGrabber.ets:481-504（守卫）与 :674-677（probe 收尾）本会话逐行核实，矛盾确认 |
| 复核 F5 | low | assemblePieces 的 try 块内 4 处 stopRequested 早退绕过 closeSync(outFd)（无 finally 兜底；当前单线程同步拼装下守卫不可达，属防御死码带 fd 泄漏隐患） | **仍开放** | :889/:900-901/:914-916/:939-941 早退 vs :942 closeSync、catch 分支 :954-961 有关闭但早退路径无——本会话核实 |
| 复核 F6 | low | 同实例 finish 后误调 resume() 会二次终态（temp 已删、pieces 全 FINISHED 留存→assemblePieces 逐片 openSync 失败→onFailed(DISK_ERROR) 追加在 onFinished 之后；C# Resume 走空态回退全新开始） | **仍开放（需消费方误用才触发，UI 正常流程不调）** | resume() :208-231 全 Finished→assemblePieces :227-231 路径本会话核实 |

审查轮次结论：R2 不通过（F1/F2 两 high）→返修；R3 不通过（F1 回归 medium）→返修；R4 通过（approved=true，3 项 low 开放项历轮已接受）；独立复核 acceptable=true（1 medium F1 + 6 low，未返修，逐条登记）。

## ⑤ 验证情况

| 检查 | 结论 | 证据 |
|---|---|---|
| hvigor 编译门禁（devecocli build --modules entry） | **通过（本会话亲跑）** | 报告员执行 `devecocli build --modules entry`（工作目录 D:/git/HarmonyPC/XdmHarmony）→ `BUILD SUCCESSFUL in 528 ms`、`Build completed successfully`，零 error。注：本次为增量构建（CompileArkTS 等 UP-TO-DATE——自工作流最后一轮成功编译后源码零改动，缓存命中即门禁通过口径）；编码轮材料另载全量 `assembleHap --parallel` BUILD SUCCESSFUL in 5s162ms/CompileArkTS 2.4s 零 error、唯一 ArkTS WARN 在未触碰的 U0.2 既有文件 ProbeHttp.ets:230 |
| codelinter 辅助（提示性） | **工作流材料：exit 0（14 warnings/0 errors/3 files，均 @performance/avoid-overusing-custom-component-check 于 probe 页文件）；本会话未能复跑成功** | 报告员两次尝试 `node "D:/Tools/DevEco Studio/plugins/codelinter/index.js" --dir <目录> --project … [--language ets --incremental false]` 均报 `Some error occurred during linting. This may cause incomplete report results.`（工作流的确切调用参数未知，无法复现其 exit 0 运行）；两次失败调用在仓库根遗留同名 `undefined` 日志文件一枚，报告员已删除复原。codelinter 不含 ArkTS 语法规则（计划 §8 验证矩阵明示），该项为提示性非门禁 |
| ArkTS 严格子集合规 | **由 hvigor 编译期强制**（工程无 ArkTS 语法 lint 规则，计划 §8 与单元指令同口径）；门禁通过即合规通过。编码期对照 arkts-grammar-standards 自查（禁 any/对象字面量带类型/无结构化类型等），@Concurrent 纪律（模块级函数/参数全传值/仅 top-level export+内联字面量）见 SegmentWorker.ets 文件头 :16-27 自述并由 hvigor 编译期强制 | hvigor 门禁本会话通过（上行）；SegmentWorker.ets:124-125 @Concurrent 模块级函数形态本会话核实 |
| 对照审查 | 4 轮（R2/R3/R4+复核），结论与处置见 §④；最终 approved=true（R4） | §④ 全表 |
| 独立复核 | acceptable=true，weakestSpot=探测回执跨通道次序假设（复核 F1，medium，开放） | §④ 复核行 + §⑦ |
| 纯函数单测 | PieceAlgo.test.ets 14 条用例**已入库未实跑**（assembleHap 不编译 src/test；本地无 test 执行器——编码轮材料如实注明；实跑归 U2.3/IDE 侧） | 本会话核实文件存在且 `it('` 恰 14 条；执行未运行 |
| 事件面冻结 | DownloadEvents/NoopDownloadEvents/ForwardDownloadEvents 三声明保留（Downloader.ets:21-79 本会话核实，六方法签名与 U1.2 一致）；UI 消费面零改动 | Downloader.ets:21-28 |

**实现文件清单**（15 文件，全部 status=done）：改 HttpProtocol.ets（+closedRangeHeader :145）、Config.ets（第 6 键）、HttpClient.ets（HttpResponseHead+errCode，D13）、Downloader.ets（外壳冻结内部委托 PieceScheduler）、ProbeIndex.ets（P2-U1 注册 :24/:98-99）、string.json（探针 3 键）、List.test.ets；新 PieceAlgo.ets、SegmentWorker.ets、PieceGrabber.ets、ProbeSegmentLogic.ets、ProbeSegment.ets（S5 暂停阈值 262144 :51 本会话核实）、PieceAlgo.test.ets、PROBE/EXPECT 两文档。除上表 oh-package-lock.json5（自动再生）外无清单外源码改动。

## ⑥ 运行时验证待办（[P] 口径）

- **探针手册**：`docs/probe/PROBE-u2-1-piecegrabber-segmentworker.md`（含 P1-U2-download-server.js 复用指引、hdc 全路径、逐步骤预期标记表、环境差异分支表、会话守卫冒烟）。
- **预期表**：`docs/probe/EXPECT-u2-1-piecegrabber-segmentworker.json`（8 条目：BEGIN+S1~S5+SUMMARY+END；本会话读文件核实。注：设计书 §1 #15 写"共 9 条目"为笔误，实际 8 条目与手册 §4"恰 8 行"一致）。
- **运行指引**：主机 `node docs/probe/P1-U2-download-server.js` → `devecocli run --module entry` → `hdc shell aa start -b com.example.xdmharmony -a EntryAbility --ps page probe` → P2-U1 卡片填主机局域网 IP（禁 127.0.0.1）→ 运行全部 → 抓 `hilog -x | grep XDM_PROBE` 回贴，由 xdm-probe-verify 工作流判定。
- **核心验收锚**：S2 maxConcurrent=8+piecesCount=16±1+allSpotsMatch=true；S3 maxOverlapAcrossSnapshots=0+coverageComplete=true；S4 singleBps/segBps>0（ratio 观测）；S5 activeAfterStop=0+allSpotsMatch2=true。
- **本单元特有回写项**：①sendData 定时器回调限制的降级是否实际触发；②fileIo 在 taskpool worker 的可用性；③ratio 实测值（Phase 2"吞吐显著优于 U1.2"量化输入）。

## ⑦ 遗留问题与风险

按风险排序：

1. **复核 F1（medium，开放）——探测回执跨通道次序假设**：probe 的 execute Promise 结果与 sendData connected 消息分属两条回传通道，SDK 不保证次序；现实现 record 本体守卫（:487）统一拦截，result 先到即删 record，晚到的 connected 被丢→probeConnected 永不执行→引擎挂死无终态（探针 S2 将表现为 120s 超时 finished=false）。**代码注释 :672-673"互逆均安全"与设计书 §3.5/§8 承诺同实际代码矛盾——以代码与日志为准认定：承诺未实现**。若探针 S2 出现"探测期无 connected 即超时"形态，此项即实锤，修复方向复核已给出（connected 按 pieceId+!init 守卫，不依赖 record）。另 weakestSpot 指出：worker 在主线程 206/Content-Range 校验前已按窗口写盘（C# 先验证后写盘），正确性依赖"同窗重试前缀全覆盖自愈"+消息次序——S2/S5 字节抽查（allSpotsMatch）是事后捕获面。
2. **R2-F4 系（low，开放）**：缺 Content-Range 头的边缘 206 响应会被误判终态（C# 放行）。影响面：非常规服务器。
3. **R2-F5 系（low，开放）**：worker 写盘错后不短路续流（终态正确、时序偏差，上限=流时长）。
4. **复核 F5（low，开放）**：assemblePieces stopRequested 早退路径 fd 泄漏隐患（当前不可达防御死码）。
5. **复核 F6（low，开放）**：同实例 finish 后误调 resume() 二次终态（需消费方误用）。
6. **R2-F6 系（low，开放）**：PieceGrabber↔Downloader 循环 import（运行时可用，设计依赖图漏登记反向边）。
7. **探针/单测未实跑**：[P] 口径全部待人工（§⑥）；PieceAlgo 14 用例未在本地执行器实跑（U2.3 承接）。
8. **oh-package-lock.json5 每轮构建再生**（AUTOGENERATED，无行为影响），建议提交时纳入或以 .gitignore 处置，避免每单元"清单外改动"重复上报。

## ⑧ 对下个单元（U2.2）的建议

1. **优先消化复核 F1**：U2.2 的杀进程续传同样依赖调度入口的确定性收敛；若 U2.2 开工前有机会返修，建议先改 connected 守卫（pieceId+!init）再叠加持久化，避免在挂死隐患上叠加状态恢复逻辑；探针 P2-U1 回贴时首查此项形态。
2. **边界交接（D17）**：U2.2 范围=分片进度 JSON 持久化（SaveChunkState 七处空锚：PieceGrabber.ets :457/:787/:806 等已就位）+杀进程重启续传；assemblePieces 已在 U2.1 落地，U2.2 不重做。目录字面差异建议在 U2.2 设计书差异清单再次显式登记，避免后续单元误判。
3. **顺手项**：①R2-F4 的 contentLength>0 门与缺头跳过 start 校验（一行级）；②复核 F5 的 finally 关 fd；③循环 import 抽独立事件模块（消环）——均低风险，可并入 U2.2 编码轮。
4. **Config 键位**：maxSegments 已入 preferences（Config.ets:33-41），U2.2 恢复逻辑读取时注意 worker 线程禁触 Config 单例的纪律（SegmentWorker.ets:20-21 先例：显式传参）。
5. **探针复用**：P2-U1 的快照/抽查面（ProbeSegmentLogic）可直接扩展 U2.2 的重启续传步骤；P1-U2-download-server.js 继续复用。

## ⑨ 提交说明

本单元代码**未做 git 提交**。本会话 `git status` 核实：工作树含本单元全部产物（9 个修改文件+8 个未跟踪新文件，含设计书更新与 PROBE/EXPECT 文档），仓库当前 HEAD=f826b55（U2.1 设计文档提交，编码前）。按流程（MIGRATION_PLAN §9.3、UNIT_CATALOG 敏捷批次"提交与验收"条），待人工验收（探针回贴判定+Phase 级走查）后由人工执行 git 提交并按 Phase 打 tag（phase-2 在 U2.2 完成后）。

—— 完 ——
