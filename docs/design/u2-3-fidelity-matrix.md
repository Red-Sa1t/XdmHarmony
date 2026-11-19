# U2.3 引擎保真度对照表（行为项 ↔ 源码锚 ↔ 用例 ↔ 执行状态）

> 单元：U2.3 引擎保真度对照单测收口（Phase 2 收口）。设计书：[u2-3-engine-fidelity-DESIGN.md](./u2-3-engine-fidelity-DESIGN.md)（差异 D19-D24 与命令链见其 §4/§3.7）。
> 源码锚缩写：PieceGrabber.cs=PG.cs（XDM.Core/Downloader/Progressive/）、SingleSourceHTTPDownloader.cs=SS.cs、HTTPDownloaderBase.cs=HB.cs、WebRequestExtensions.cs=WRE.cs、DotNetHttpSession.cs=DN.cs。
> 执行状态图例：✅=实跑通过（2026-09-28，`hvigorw test`，hvigor 6.24.4+hypium 1.0.25，开发机桌面；两波——设计会话既有 95 条全绿波 + U2.3 编码新增 22 条回填波）；⚖️=架构等价（无独立纯函数用例，结构承载/运行时探针承载，理由注明）；⛔=有意差异（D 系登记，不复刻）。

## A. 分裂算法（PieceAlgo / HB.cs:307-466，吸收锚 HB.cs:157-195）

| # | 行为项 | 源码锚 | ArkTS 锚 | 用例 | 执行状态 |
|---|---|---|---|---|---|
| A1 | 初始探测片 {Offset:0,Length:-1,Downloaded:0,NotStarted,Primary} | SS.cs:84-92 | PieceAlgo createInitialPiece | createInitialPiece_probeShape | ✅ |
| A2 | 枚举序位锚（SegmentState/StreamType）+ 阈值 256*1024 | SegmentState.cs:3-7、Piece.cs:34-37、HB.cs:422/:439 | SEG_*/STREAM_*/SPLIT_THRESHOLD | constants_enumOrderAndThreshold | ✅ |
| A3 | 最大剩余片：rem=Length-Downloaded 最大（严格 `>`，并列取插入序首个）；splittingAllowed=false 恒 null | HB.cs:405-428 | findMaxChunk | findMaxChunk_thresholdStrictGreater + findMaxChunk_maxRemAndInsertOrderTie | ✅ |
| A4 | 对半分裂：len=rem/2 整除下取整、新片取上半区、原片保下半区且 Downloaded 保留 | HB.cs:430-466 | splitPiece | splitPiece_evenHalves + splitPiece_oddFloorAndDownloadedKept | ✅ |
| A5 | Find/Split 双边界（rem==262144：Find 不选、Split 允许） | HB.cs:422 `>` vs :439 `<` | 同上 | splitPiece_dualBoundary | ✅ |
| A6 | 分裂序列收敛：4MiB 初始片 → 16 片×262144 收敛 + Σlength/覆盖连续/downloaded 守恒不变量 | SS.cs:292（每连接驱动 CreatePiece）+ HB.cs:307-332 | findMaxChunk/splitPiece（U2.3 序列驱动器按 CreatePiece 节奏纯函数重放）+ createPiece（调度器） | splitSequence_converge_4MiB_to_16 + splitSequence_invariants_withDownloaded | ✅ |
| A7 | 相邻分片吸收四条件（Downloaded==0/Offset==position/StreamType 同/(O+L)<=maxByteRange）→ 删邻片扩长 | HB.cs:157-195 | continueAdjacentPiece | continueAdjacentPiece_absorb + continueAdjacentPiece_breakConditions | ✅ |
| A8 | 吸收运行时不可达：运行形 windowEnd+1 恰=邻片 Offset（pieces 不交覆盖），条件 (邻片O+邻片L)<=maxByteRange 要求邻片 L<=0 恒假；源形仅当连接时 Downloaded==0 与运行形相等（Downloaded>0 时严格更小），同样不可达——"超 maxByteRange"例锁定运行形论证；**原版边界：206 缺 CL 头时 DN.cs:32 回落 ContentRange total=文件全长，源版闭窗吸收可达**（D6 有意差异完整边界，不复刻，COLD-F2 修正） | PG.cs:273 + DN.cs:32 | PieceGrabber.ets:824 | continueAdjacentPiece_breakConditions（超 maxByteRange 断言） | ✅（论证锁） |
| A9 | inactive 规则：GetInactivePiece 排除在途/Finished/Downloaded==Length；GetInactiveChunkCount **缺**该排除项（源码原貌，D16） | HB.cs:373-403 | getInactivePiece/getInactiveChunkCount | inactiveRules_pieceExclusions + inactiveRules_countKeepsSourceQuirk | ✅ |
| A10 | allFinished：全 FINISHED 才 true；空 Map true | HB.cs:334-349 | allFinished | allFinished_semantics | ✅ |
| A11 | 排序器：offset 升序稳定 | SS.cs:295-303 | sortPiecesByOffset | sortPiecesByOffset_ascendingStable | ✅ |

## B. 窗口 / 偏移 / 恢复（PG.cs:387-395 + :169-170 + :203-204 + :284-285）

| # | 行为项 | 源码锚 | ArkTS 锚 | 用例 | 执行状态 |
|---|---|---|---|---|---|
| B1 | 闭窗口数学 [Offset+Downloaded, Offset+Length-1]（恢复起点=绝对 O+D） | PG.cs:393-394 | windowOf | windowAndTotal_math | ✅ |
| B2 | 窗口端点边界：downloaded=0 / L-1（单字节窗）/ L（空窗原样输出，getInactivePiece 保证不派发） | PG.cs:393-394 | windowOf | windowOf_endpointBoundaries | ✅ |
| B3 | 开窗 Range 头 `bytes=N-`（AddRange(0) 首请求形态） | WRE.cs:168-177 + PG.cs:389 | resumeRangeHeader | resumeRangeHeader_openEndedForms | ✅ |
| B4 | 闭窗 Range 头 `bytes=S-E` 闭区间含端点 | WRE.cs:160-163 + PG.cs:394 | closedRangeHeader | closedRangeHeader_closedIntervalForm（与 B1 的 [1200,1499] 交叉锚） | ✅ |
| B5 | 恢复重算 totalDownloaded=Σ Downloaded | HB.cs:515-526 | totalDownloadedOf | windowAndTotal_math（后半） | ✅ |
| B6 | 恢复集含未知大小片闭窗重派 → NonRetriable(NonResumable,"Resume not supported") 终态 | PG.cs:169-170 | PieceGrabber.ets:426-427 + isNonResumableResume | isNonResumableResume_closedUnknownSize | ✅ |
| B7 | maxByteRange = contentLength<=0 ? -1 : Offset+contentLength（运行时用 windowEnd+1——两形仅连接时 Downloaded==0 相等，一般源形更小但均≤邻片 Offset、吸收恒 false，行为等价 D23 修正论证；CL 缺失回落全长边界见 A8/D6） | PG.cs:203-204 | maxByteRangeOf（锁源码形）+ PieceGrabber.ets:824（运行时形） | maxByteRangeOf_sourceFormula | ✅ |
| B8 | 每轮读长=min(BUF=32768, remaining)（remaining<=0 由吸收/收尾分支先行消化） | PG.cs:259 + :284-285 | cappedReadLen + READ_BUF_LEN（worker 运行时对应物=窗口余量封顶 SegmentWorker.ets:178-179） | cappedReadLen_bufCapAndSmallRemainder + readBufLen_constant | ✅ |

## C. 闭窗响应校验链（PG.cs:181-204；调度器 PieceGrabber.ets:647-695 内联）

| # | 行为项 | 源码锚 | ArkTS 锚 | 用例 | 执行状态 |
|---|---|---|---|---|---|
| C1 | compressed 改写：ContentLength 恒 -1、206→200（连带禁续传/总长-1/maxByteRange=-1） | PG.cs:181-188 | PieceGrabber.ets:650-653 + effectiveProbeStatus | effectiveProbeStatus_compressedRewrites206To200 + effectiveProbeStatus_uncompressedPassthrough | ✅ |
| C2 | 非首请求 status≠206 → NonRetriable(InvalidResponse,"Resume not supported") | PG.cs:194-196 | PieceGrabber.ets:673-676 + closedWindowValidationError | closedWindowValidationError_statusNot206 | ✅ |
| C3 | compressed+206 拒续传（改写后 200≠206）——compressed 响应断点续传禁用锁面 | PG.cs:181-188+:196 链 | 同上 | closedWindowValidationError_compressed206Rejected | ✅ |
| C4 | Content-Range total 与 FileSize 不符 → NonRetriable(InvalidResponse,"Content length mismatch") | PG.cs:197-201 + SS.cs:510-517 | PieceGrabber.ets:679-683 + closedWindowValidationError | closedWindowValidationError_totalMismatch | ✅ |
| C5 | FileSize<=0 跳过 total 检查（IsFileChangedOnServer return false 门） | SS.cs:512-516 | 同上 gate | closedWindowValidationError_totalGateFileSizeNotPositive | ✅ |
| C6 | Content-Range 缺失（total=-1）→ mismatch 照常触发（研究 fact 1 注记修正，设计书 §0-2） | DN.cs:94-98 + SS.cs:510-517 | parseContentRange(-1) 链 | closedWindowValidationError_contentRangeMissing | ✅ |
| C7 | Content-Range start 与派发窗口起点不符 → InvalidResponse（**源码无此检**，U1.2 D9 加固） | —（ArkTS 增益） | PieceGrabber.ets:685-690 | closedWindowValidationError_startMismatch | ✅ |
| C8 | 合法 206（start/total 相符）三检全过 | PG.cs:194-201 反面 | 同上 | closedWindowValidationError_pass206 | ✅ |
| C9 | 成功状态白名单仅 200/206（3xx 已被栈跟随，4xx/5xx 拒） | WRE.cs:15-29 | isSuccessStatus | isSuccessStatus_200_206_true + isSuccessStatus_302_404_false | ✅ |

## D. 探测面推导（PG.cs:436-447 + 调度器 probeConnected）

| # | 行为项 | 源码锚 | ArkTS 锚 | 用例 | 执行状态 |
|---|---|---|---|---|---|
| D1 | Resumable = !compressed && status==206 | PG.cs:441 | PieceGrabber.ets:725/:729 + probeResumable | probeResumable_derivation | ✅ |
| D2 | ResourceSize = compressed ? -1 : ContentLength（CL 缺失时落 Content-Range total 为 U2.1 加固，D24 同族） | PG.cs:440 | PieceGrabber.ets:709-713 + probeTotalSize | probeTotalSize_compressedMinusOne + probeTotalSize_contentLengthAndRangeFallback | ✅ |
| D3 | 探测落位 piece.{Length=ResourceSize??-1,Offset:0,Downloaded:0}、init=true、SaveChunkState、每连接一次 CreatePiece | SS.cs:238-245（PieceConnected 内落位块，实测逐行）+ :272-275 + SS.cs:228-293 | probeConnected（PieceGrabber.ets:699-770） | ⚖️ 调度器行为——P2-U1 S2/S3 探针承载（piecesCount=16±1、区间不重叠）；**小文件边界（COLD-F1）**：≤256KiB 可续传文件原实现本轮零派发→探测 record 被静默删除后永挂（原版探测连接流式下载不挂），已热修兜底直派闭窗窗口（设计书 D25，跨红线④经主会话授权）；小文件路径探针待办——现有 P1-U2/P2-U1/P3-U1 探针均 4MiB 源，覆盖不到该分支 | ⚖️ |
| D4 | Content-Range 头解析（bytes S-E/T、* 形态、缺头 -1） | HttpResponse.cs:30-32 + DN.cs:94-98 | parseContentRange（HttpProtocol）+ probe 侧 headerOf/parseContentRange | parseContentRange_fullForm + parseContentRange_invalidForms + ProbeHttpLogic 4 条 | ✅ |

## E. 重试 / EOF / 进度 / 持久化 / 传输（PG.cs:98-124、HB.cs、HttpProtocol）

| # | 行为项 | 源码锚 | ArkTS 锚 | 用例 | 执行状态 |
|---|---|---|---|---|---|
| E1 | 重试上限：先 timesRetried++ 后判 >MaxRetry(10)——最多 11 次尝试，第 11 次失败才 MaxRetryFailed | PG.cs:113-117 + Config.cs:100-102 | exceedsMaxRetry（EngineMath）+ PieceGrabber.ets:867-871/:880-884 | exceedsMaxRetry_boundary | ✅ |
| E2 | connect 期失败 sleep(RetryDelay×1000) 后重试；body 期失败立即重试不 sleep | PG.cs:118-124 | phase 赋值 SegmentWorker.ets:210 + retryConnectPhase/retryImmediately 分支（PieceGrabber.ets:794/:838） | ⚖️ 结构承载（设计书 D22：判据函数体无信息量不抽） | ⚖️ |
| E3 | HttpException 且 Enum.IsDefined(HttpStatusCode) → InvalidResponse 终态；未定义码吞掉重试 | PG.cs:98-106 | ⛔ 无对应物（phase 轴架构：传输异常统一 status=0→connect 重试） | —（设计书 D21 有意差异） | ⛔ |
| E4 | Unexpected EOF（x==0 且 remaining>0）→ DownloadException(Generic) 被吞重试 | PG.cs:284-290 | bytesWritten<windowLen → retryImmediately（PieceGrabber.ets:837-839） | ⚖️ worker 结果面——P2-U1 探针承载 | ⚖️ |
| E5 | targetStream.Write IOException → NonRetriable(DiskError) 终态（C# 盘错从不进重试环） | PG.cs:296-299 | diskErrCode!=0 前置判定（PieceGrabber.ets:784-789，R3-F1） | ⚖️ 同上 | ⚖️ |
| E6 | TextRedirect：content-type=text/plain 重定向（SingleHttp 恒禁用=死路） | PG.cs:93-97 + SS.cs:508 | ⛔ 不移植（U2.1 D7 系沿用） | — | ⛔ |
| E7 | 进度数学：instantSpeed 整除 floor / avgSpeed 浮点除 / eta Ceiling / 500ms 门（另 2000ms 状态门、进度 progress 由消费方组装） | HB.cs:288-299 | instantSpeedBps/avgSpeedBps/etaSeconds/shouldEmitProgress（EngineMath） | instantSpeed_floorDivision + instantSpeed_zeroElapsed_returnsZero + avgSpeed_fractional + avgSpeed_zeroElapsed_returnsZero + etaSeconds_ceil + etaSeconds_zeroSizeOrSpeed_returnsZero + shouldEmitProgress_gate | ✅（实跑修正两处断言缺陷后） |
| E8 | 重试 sleep 时长=Config.RetryDelay*1000（10s） | PG.cs:119-120 | retryAfterDelay（PieceGrabber.ets:896-903） | ⚖️ 结构承载（Config 默认值 U1.1 已锁） | ⚖️ |
| E9 | chunks 持久化字段序 count→片(key/Id/Downloaded/Length/Offset/State/StreamType)；读败→FileSize=-1 重算 | HB.cs:557-590 | buildChunksJson/parseChunksJson（JSON 化，决策 10） | chunksJson 10 条（roundtrip_16/roundtrip_totalsize/empty_map/truncated_json/garbage_text/field_type_error/initial_piece_doc/state_ordinal/schema_gate/nonfinite_gate） | ✅ |
| E10 | 六键默认头逐键（UA 字面量/identity/Referer 目录形） | SS.cs:519-530 + Config.cs:52 | sixDefaultHeaders/refererOf | sixDefaultHeaders_sixKeysAndValues + sixDefaultHeaders_refererDirectoryOfFile + sixDefaultHeaders_refererRootPath + sixDefaultHeaders_trailingSlashUnchanged | ✅（headerValueOf 修复后） |
| E11 | 头取键大小写不敏感（键与查询名双侧） | .NET HttpHeaders 语义（自定义对齐契约） | headerValueOf（D19 修复） | headerValueOf_caseInsensitiveQueryName | ✅ |
| E12 | URI 有效性（scheme 白名单 http/https） | Helpers.cs:45-56 | isUriValid | isUriValid_httpHttpsOnly | ✅ |
| E13 | 错误码序位（Generic=1…DiskError=8）+ EngineError 单类三异常分类 | ErrorCode.cs:9-19 | ERR_* + EngineError | errCode_values_matchSourceOrder + engineError_fields | ✅ |
| E14 | 记录映射/文件名/格式化/分块窗口（探针逻辑面：expectedByteAt/splitRangeWindows/timeout 判定等） | —（U0.2/U1.1/U1.2 面复验） | ProbeDownloadLogic/FileNameFormat/DownloadTypes/RecordMapping | 4+13+4+13=34 条 | ✅ |

---

## 统计与结论

- **行为项**：46 项（A 分裂 11 + B 偏移恢复 8 + C 响应校验 9 + D 探测 4 + E 重试/进度/持久化/传输 14）。【U2.3 编码回填时勘误：设计时点统计写 44 项/E=12/✅24/⏳15/⚖️4，与本表逐行实数不符（E 段实为 14 行、⚖️ 含 E8 实为 5 行）——本节按表格实数修正。】
- **执行状态分布**（2026-09-28 回填后终态）：✅ 39（=21 既有实跑波 + 18 本轮新增用例实跑回填波：A6、B2-B4/B6-B8、C1-C8、D1-D2、E11）· ⚖️ 5（D3/E2/E4/E5/E8——调度器/worker 结构行为，P2-U1 运行时探针与结构审查承载）· ⛔ 2（E3/E6——D21/D22 系有意差异）。**无 ⏳ 残留。**
- **用例总数**：既有 95（实跑全绿）+ 新增 22（设计书 §5.3/§5.4）= 117。`grep -c '^    it('` 逐文件实测：DownloadTypes 4 / EngineMath 10 / FileNameFormat 13 / HttpProtocol 26（11+15）/ PieceAlgo 31（24+7）/ ProbeDownloadLogic 4 / ProbeHttpLogic 16 / RecordMapping 13 / List 0。
- **测试执行可行性结论**：`hvigorw test` 脚本化执行**已接通并实跑**（设计会话五轮接通证据 §3.7 + 本轮编码终验：`DEVECO_SDK_HOME` + DevEco 自带 node.exe 执行 hvigorw.js test → BUILD SUCCESSFUL in 5s 872ms（增量），stdout 无 `ERROR: Error in` 行（grep 计 0）= 117 条全绿；coverageReport.json 行级计数正向佐证——effectiveProbeStatus count=15（用例直调 5 + closedWindowValidationError 内部 10）、closedWindowValidationError count=10、maxByteRangeOf 分支 trueCount=2/falseCount=1、cappedReadLen count=4、headerValueOf count=22，与新增用例断言数逐一吻合）；执行环境=开发机桌面，无头 CI 不承诺。
- **回填约定执行记录**：2026-09-28 本轮编码实跑后 18 个 ⏳ 行已改 ✅（图例统一注明日期/环境），本节统计同步更新；无实跑失败项，未发生改锚/跳过情形。
