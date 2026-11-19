# U2.2 分片落盘 + 断点续传 + 进度持久化 · 迁移单元报告

> 单元：U2.2（Phase 2 第 2 单元；探针单元 ID `P2-U2`，slug `u2-2-resume-state-persist`）。
> 报告日期：2026-09-28。报告人：xdm-migrate 工作流"迁移报告员"（独立会话，证据均为本会话实读/实跑，标注来源者为审查材料引述）。
> 对照源码：`resourses/xdm`（XDM 2023，C#/.NET，GPL-2.0）——全程只读，未做任何写操作。
> 上游材料：研究结论（12 facts + 2 openQuestions）、设计书 `docs/design/u2-2-resume-state-persist-DESIGN.md`、对照审查两轮记录、独立复核记录、主控脚本门禁输出。

---

## 1. 单元范围与验收要点

**范围**：把 U2.1 引擎的 pieces 分片表以 JSON 双槽文件持久化——写入点逐一对照源码 `SaveChunkState` 的 8 个调用点 + 2000ms 独立数据门（Stop/暂停/退出不显式保存，持久化值最多陈旧约 2s）；杀进程重启后经恢复桥从状态文件重建调度器续传（对照源码 `RestoreState`/`Resume` 状态机：无状态→全新 start）。分片临时文件追加写与按 Offset 拼接链已在 U2.1 落位，本单元只复核复用、零改动（红线②）。

**交付面（设计书 §1 十文件，工作树 git status 实证全部在树）**：

| 类别 | 文件 |
|---|---|
| 改 | `entry/src/main/ets/core/engine/PieceAlgo.ets`（chunks JSON 序列化/反序列化纯函数）、`PieceGrabber.ets`（StateStore 持有 + 8 锚写入 + 恢复桥 + start 清残留）、`pages/Index.ets`（handleToggle 未命中分支一律 resume()）、`src/test/PieceAlgo.test.ets`（10 条 chunksJson 用例）、`probe/ProbeIndex.ets`、`string.json`（探针 3 键） |
| 新 | `core/db/StateStore.ets`（双槽 JSON 持久化 IO 壳）、`probe/units/ProbeResume.ets`（P2-U2 探针页）、`docs/probe/PROBE-u2-2-resume-state-persist.md`、`docs/probe/EXPECT-u2-2-resume-state-persist.json` |

**验收要点**（UNIT_CATALOG U2.2 行：来源 `HTTPDownloaderBase.cs:557-618`、`SingleSourceHTTPDownloader.cs` 落盘段；验证 [A]+[P]）：
1. 编译过（hvigor 零 error）——已通过（见 §5）。
2. 杀进程→重启→断点续传链路可观测（探针 S4 三联锚：offsetsUnchanged / firstProgressDownloaded≥restoredSum / finalSize）——待探针运行（见 §6）。
3. 拼接产物字节正确（allSpotsMatch=true，5 抽查点含暂停邻域）——待探针运行。
4. 每分片 offset 观测（S2 pausedPieces / S3 savedLine / S4 restoredLine 三拍对账）——待探针运行。

---

## 2. 研究结论摘要（关键源码行为 → ArkTS 对应表）

研究阶段产出 12 facts（含 risk 评级），逐条已映射落位。摘要表（"落位"=本单元或此前单元已实现并有审查记录）：

| # | 源码行为（位置） | ArkTS 对应（落点） | 状态 |
|---|---|---|---|
| 1 | 恢复状态机：RestoreState→mkdir→pieces.Count!=0→OnStarted→全 Finished 则直接拼装，否则 init=true+CreatePiece；pieces 空→全新 Start。两级失败语义不对称：chunks.db 读败被吞→走全新 Start；{Id}.state 读败→OnFailed | `PieceGrabber.ets resume()`/`restoreState()`：空→start()；mkdirSync 补齐（D7）；allFinished→assemblePieces；init=true+createPiece。ArkTS 无 {Id}.state 对应物（D1，下载级字段在 downloads 表） | 落位（risk medium→已闭合） |
| 2 | chunks 写入点全集=2000ms 数据门 + 7 个事件点（共 8 调用点）；pieces 空静默不写；Stop()/暂停/退出无任何显式保存 | `saveChunks()`（空集静默门）+`saveChunksIfDue()`（先存后置游标）；8 锚逐锚落位（现行行号见 §4 表末注）；不补 Stop 保存=源码保真（§0-2 拍板） | 落位（本会话 grep 实证 7 直调+IfDue 两挂点） |
| 3 | 分片表二进制字段序 count+每片[key,Id,Downloaded,Length,Offset,State,StreamType]；key==Id；枚举序不得重排 | `buildChunksJson`/`parseChunksJson` 字段序 id→downloaded→length→offset→state→streamType；key==Id 合并为单 id=等价化简；SEG_* 同序；读回不验 0..3（D8 源码同貌） | 落位（PieceAlgo.ets:280-294/:302-343） |
| 4 | TransactedIO 崩溃安全双槽：[pos][payload]["END."]，读 .1→.2，写原地覆写+三步轮换，任一时刻至少一份完整副本 | `StateStore.ets`：staging(TRUNC)+renameSync 原子入槽+三步轮换、readChunks .1→.2、JSON.parse 成功+结构门=END. 等价完整性门（D2，只增不减） | 落位（StateStore.ets:40-99，134 行） |
| 5 | 分片临时文件=TempDir/<pieceId>，写起点=OpenOrCreate 不截断+Seek(Downloaded,Begin) | SegmentWorker openSync+lseek(writeStartOffset)（U2.1 落位）；StateStore 原样保存 piece id；恢复后自 piece.downloaded 前缀覆盖幂等（支柱②） | 落位（零改动复用） |
| 6 | 恢复后全部请求非首请求：闭区间 Range 头 bytes=(Offset+Downloaded)-(Offset+Length-1)；206 强检+长度变更检；length=-1 残留片→NonResumable 终态 | windowOf/closedRangeHeader+resumeConnected 三检（U2.1 落位）；恢复注入后 init=true 天然走闭窗路径，零新代码 | 落位（零新代码复核） |
| 7 | 全新 Start 序列：mkdir→初始片→init=false→SaveState→Download；SaveForLater=Start(false) 永不写 chunks.db；源码全新 Start 不清旧 chunks.db | `start()` 同构（mkdirSync 幂等、初始片、OnStarted 先于派发）；有意差异 D4：start() 先 stateStore.clear() 关闭跨会话残留恢复窗口 | 落位（D4 已登记） |
| 8 | 进度 UI 事件（>500ms）与 chunks 持久化（>2000ms）是两个独立节流游标，构造时初始化、永不复用 | `emitProgressIfDue`（500ms 门）与 `saveChunksIfDue`（2000ms 门）分离；lastStateSavedAt 构造初始化、start/resume 不重置（:157/:338-340，本会话 grep 实证赋值族唯一） | 落位 |
| 9 | {Id}.state 下载级状态（Config.DataDir）：FileSize/LastModified/Url(重定向后)/Headers/Cookies 等 | D1 单工件方案：下载级字段由 downloads 表 22 列承载；chunks.json 冗余 totalSize 使恢复自足；finalUrl/LastModified/Cookies 不持久化（每请求重走重定向 +1 跳） | 落位（D1 已登记） |
| 10 | 拼接：按 Offset 排序→盘检→5MB 缓冲逐片拷贝→DeleteFileParts 递归删 TempDir；恢复路径全 Finished→直接拼装 | assemblePieces/deleteTempDir（U2.1 落位，红线②零改动）；StateStore 三工件放 tempDir 内随 deleteTempDir 自然清理；restoreState 后 allFinished→assemblePieces 捷径在 resume() | 落位（零改动复核） |
| 11 | TicksAndSizeAtResume：Σdownloaded 重算+时间基线重置；平均速度从恢复点重新起算 | resume() 显式重置 bytesSinceStartOrResume=0+ticksAtStartOrResume 等四游标（PieceGrabber.ets:276-280 本会话实读） | 落位 |
| 12 | 探针须两段式 force-stop 重启：会话 A 下载→暂停→记录每片状态→force-stop→会话 B 恢复→观测各片恢复起点（≤2s 陈旧容差）+成品字节抽查 | `ProbeResume.ets`（738 行）两段式落位：pending JSON 会话间传递+StateStore 直读恢复输入+Downloader.resume()；PROBE/EXPECT 文档已生成 | 落位（待运行时回贴） |

---

## 3. 设计决策与有意差异（引用 MIGRATION_PLAN 决策条款）

**计划依据**（MIGRATION_PLAN §6，本会话读原文）：
- **决策 4**（:117）：分片落盘与原版同构——每分片独立临时文件+追加写+完成后顺序拼接；进度持久化 JSON 化（替代二进制 chunks.db）。→ 本单元主体。
- **决策 10**（:123）：downloads 表对照 SchemaInitializer（RelationalStore）；下载状态 JSON（无需兼容原二进制格式）。→ D1/D2 的授权来源。
- **决策 2**（:115）：线程模型重构——pieces 字典由主线程单点管理（消除锁）。→ 8 锚保存全部在调度器消息/结果处理路径上、无锁（设计书 §3.6）。
- **决策 3**（:116）：分段算法精确翻译（探测→分裂→吸收；206 强校验）。→ 恢复路径零新请求构造代码的前提（fact 6）。

**有意差异清单（设计书 §4，D1–D10）**：

| # | 差异 | 依据 |
|---|---|---|
| D1 | 单工件 chunks.json（双槽 .1/.2，存 tempDir/<recordId>/）替代源码 chunks.db+{Id}.state 两工件；finalUrl/LastModified/Cookies 不持久化（每请求重走重定向 +1 跳）；chunks.json 冗余 totalSize 使恢复自足 | §0-1 拍板；决策 4/10 |
| D2 | JSON 完整性门（JSON.parse+结构校验）替代 [pos][payload][END.] 三检；写侧 staging(TRUNC)+renameSync 原子入槽替代原地覆写（只增不减）；轮换序/读序/最新恒 .1 全部保真 | §2.2/§3.2 |
| D3 | SplitPiece 内嵌保存移到调度器调用点（PieceAlgo 纯函数层禁 IO）；保存时机/频次不变（分裂轮锚⑦+锚⑥双写对齐源码 :457+:326） | U2.1 分层红线延续 |
| D4 | start() 先 stateStore.clear() 清残留状态文件（源码不清，崩溃窗口内会恢复上一会话残留 pieces）——关闭该窗口；孤儿分片文件仍不清（源码同貌，deleteTempDir 兜底） | §3.3；研究 fact 10 |
| D5 | 同实例 stop→resume 用内存 pieces 不重读盘（源码 Resume 恒重读 ≤2s 陈旧值）；内存态恒≥盘上态+前缀覆盖幂等保证字节等价；跨进程 resume 才走恢复桥 | U2.1 语义延续 |
| D6 | SaveForLater/队列调度本体不落（U3.1）；"无状态→全新 start"规则天然覆盖其恢复语义 | 研究 fact 10；单元边界 |
| D7 | 恢复路径补 mkdirSync(tempDirPath,true)（对照 Resume :119）：跨进程恢复 temp 被清时是 worker DiskError 前置因——按红线⑤裁定属本单元恢复路径本体修复 | §0-3 |
| D8 | state 持久化沿用 0/1 值域（源码全 Progressive 从未赋 Downloading/Failed）；读回不校验 0..3 范围（源码 int 直转同貌） | U2.1 fact 2 延续 |
| D9 | Index.ets handleToggle Map 未命中分支改为一律 resume()（原按 downloadedBytes>0 分流——重启后 DB 行该字段恒 0 使恢复入口不可达） | §0-4；本会话实读 Index.ets:124-150 确认在位 |
| D10 | 沿用 U2.1 已登记差异不重开；U1.2/U2.1 遗留 low 不在本单元修复范围（红线⑤） | 单元约束⑤ |

**非差异保真声明**：stop()/暂停/退出**不**补显式保存（源码 Stop :109-130 无 SaveChunkState）——持久化值 ≤2s 陈旧是源码语义，探针按容差断言（§0-2 拍板，预期表 staleBytes≥0 / resumedFromSum≤pausedDownloaded / firstProgressDownloaded≥resumedFromSum）。

**登记缺口**（独立复核 F6 发现）：R1-F1 修复引入的同实例预探测门未登记入 D 系，且其注释将恢复友好偏离表述为源码保真（详见 §4）。建议随文档修订补登为 D11。

---

## 4. 审查问题处置表（覆盖全部轮次）

审查轨迹：**第 1 轮对照审查不通过**（1 medium + 3 low）；R1-F1 修复后**第 2 轮通过**（approved=true，5 项 low 全部开放）；**独立复核 acceptable=true**，确认 5 项遗留 + 新发现 2 项 low。已修复问题编号登记：仅 R1-F1。

| 编号 | 轮次轨迹 | 严重度 | 问题摘要 | 处置 | 证据 |
|---|---|---|---|---|---|
| R1-F1 | 第 1 轮→已修复 | **medium** | 同实例 resume 在探测未落位（init=false）时把记录永久钉死 NonResumable：径直走既有体会把 {length=-1} 初始片闭窗重派→dispatchPiece NonResumable→锚②把预探测片写进 chunks.json，此后每次 resume 与跨进程 restoreState 都得同一终态 | ✅ **已修复（唯一已修复项）**：resume() 增预探测门——pieces 非空且 init=false 时先 readChunks() 探盘，null/空→start()（自带全量重置），非 null 保持现路径；门条件与 init 赋值面/源码 Start-Stop 写入点语义逐行对齐，8 锚纪律未受扰（整体 +18 行平移） | 本会话实读 `PieceGrabber.ets:249-263`：`else if (!this.init)` 门 + `diskState === null \|\| diskState.pieces.size === 0 → start()` 在位；grep 实证 8 锚现行行号：锚⑦:549/锚⑥:560/锚⑤a:642(IfDue)/锚⑧:728/锚⑤b:813(IfDue)/锚①:828/锚③:920/锚④:924/锚②:943；lastStateSavedAt 赋值族仅 :157(构造)+:338-340(IfDue 先存后置) |
| R1-F2 = R2-F2 = 复核F2 | 第 1 轮提出，第 2 轮、复核确认未修 | low | 探针 S4 的 `resumed` 键取 `String(this.facts.finishedFired)`，与 `finished` 键（:398）完全同源重复——恢复已生效但 120s 未收敛时 resumed=false，与"恢复未生效"不可区分（判定不受影响：EXPECT 把该组合归并同一超时 FAIL） | ❌ **开放**（未修复；修法=改取 `startedFired`，startedFired 已采集零成本） | 本会话实读 `ProbeResume.ets:396`：`new KeyValue('resumed', String(this.facts.finishedFired))` 与 :398 `finished` 同值 |
| R1-F3 = R2-F3 = 复核F3 | 第 1 轮提出，第 2 轮、复核确认未清理 | low | 仓库根 `nul` 文件（34 字节，git-bash stderr 误重定向产物）；nul 是 Windows 保留设备名，误提交会破坏 Windows 侧检出/工具链；git status 显示为未跟踪，`git add .` 会将其纳入提交 | ❌ **开放**（提交前必须删，git-bash `rm nul`） | 本会话 `ls -la` 实证 `nul` 34 字节存在；`cat nul` 内容="信息: 用提供的模式无法找到文件。"；`git status --short` 实证 `?? nul` |
| R1-F4 = R2-F4 = 复核F4 | 第 1 轮提出，第 2 轮、复核确认未修 | low | 设计书 5 处"同实例 Map 命中分支零改动"措辞与实际 diff 不符：被移除的 downloadedBytes>0 分流位于命中/未命中共享尾部，命中分支"未运行且 downloadedBytes==0"子 case 同样翻转为 resume()（该子 case 现由 R1-F1 门兜底，代码无缺陷，纯措辞不准） | ❌ **开放**（纯文档修订：改为"Map 命中分支的 Downloader 复用构造零改动；resume/start 选择尾分支按 §5.4 命中/未命中一律 resume()"） | 本会话实读设计书 :16/:29/:201/:229 仍含该表述；实读 `Index.ets:130-150`：命中/未命中共享尾部 `target.resume()`（:149） |
| R2-F1 = 复核F1 | 第 2 轮提出，复核确认未落地 | low | probeConnected 直接失败分支（`!isSuccessStatus`，如 404）走 cancelAllRecords+failDownload，不经 pieceDownloadFailed 故**不落锚②保存**；源码侧全部探测失败都持久化 {length=-1} 片（404 经 PieceGrabber.cs:100-110 包成 InvalidResponse→外层 catch :121-136→PieceDownloadFailed→HTTPDownloaderBase.cs:231 保存）→下次 Resume 钉死 NonResumable。与 R1-F1 门组合后可观察差异：404 后 resume→ArkTS 盘空→全新 start 可恢复，源码钉死（良性方向、对死链两者均无法下载成功） | ❌ **开放**（二选一收口：①该分支 failDownload 前补 this.saveChunks()（严格保真）；②设计书 §3.4/D 系登记为恢复友好有意差异） | 本会话实读 `PieceGrabber.ets:699-705`：`if (!isSuccessStatus(msg.status))` 分支内仅 cancelAllRecords+failDownload，无 saveChunks；源码侧本会话 sed 实读 `HTTPDownloaderBase.cs:224-241`：PieceDownloadFailed 内 `this.SaveChunkState()`（:231）在 OnFailed 之前 |
| R2-F5 = 复核F5 | 第 2 轮提出，复核确认未修 | low | 设计书未随 R1-F1 修复同步：§9.2 仍记 PieceGrabber 1127 行及修复前 resume 行号（实际 1145 行，resume 区整体 +18 漂移）；§3.1 伪码无预探测门一行；全文 grep 'R1-F1' 计数 0——后续单元按 §9 落地行号核对会全部错位 | ❌ **开放**（纯文档修订：§9.2 更新 1145 行与现行行号；§3.1 伪码补一行；D 系登记 R1-F1） | 本会话 grep 实证：设计书 :326 仍记 `1127`；全文 'R1-F1' 计数 0；`wc -l` 实测 PieceGrabber.ets=1145 行 |
| 复核F6 | 独立复核新发现 | low | R1-F1 门注释保真论证错置：注释称"精确复刻 RestoreState 盘空语义""盘空语义=:139-143 全新 Start 可恢复"，但源码 RestoreState 的 `pieces = ChunkStateFromBytes(s)` 只在 ReadStream 成功回调内执行，chunks.db 缺失时 catch 仅置 FileSize=-1、**pieces 不清空**——同实例预探测窗口源码 pieces.Count!=0→init=true+CreatePiece→NonResumable 钉死，并不走全新 Start；"盘空→全新 Start"仅对跨进程新实例成立。ArkTS 门使同实例也恢复=良性方向有意偏离，但未登记 D 系、且注释把偏差标成保真 | ❌ **开放**（修注释+"登记 §4 D 系，可与 R2-F5 合并落设计书"） | 本会话实读 `PieceGrabber.ets:250-258` 注释原文（含"盘空语义=:139-143 全新 Start 可恢复"表述）；源码佐证本会话 sed 实读 `SingleSourceHTTPDownloader.cs:200-217`：`pieces = ChunkStateFromBytes(s)` 在 ReadStream 回调内、catch 块仅 `state.FileSize = -1` |
| 复核F7 | 独立复核新发现 | low | 未登记的静默停摆边界：窗口完成时（result.bytesWritten==windowLen）piece.downloaded==piece.length，锚⑤b saveChunksIfDue 先于锚③ Finished 保存；force-stop 恰落两保存之间→chunks.json 留下 {downloaded==length, state=NotStarted}→恢复时 allFinished=false、getInactivePiece 因 downloaded==length 排除→若为唯一未完成片则零派发永挂（无 onFailed 无进度）。源码同窗口同病（:283 保存先于 :252 Finished 保存）=保真不修，但 §3.4 边界表/§8 风险表未列、失败形态是静默卡死而非报错 | ❌ **开放**（登记 §3.4/§8+EXPECT 分流补"恢复后 120s 无 firstProgress 且无 engineFailed=停摆边界"说明即可；如要修需在 restoreState 归一化 downloaded==length&&NotStarted→Finished，属偏离需登记） | 复核员实读 `PieceGrabber.ets:805-813`+`PieceAlgo.ets:212`+源码 `HTTPDownloaderBase.cs:268-283/:387-403`；本会话 grep 实证锚⑤b :813（onWorkerResult 终值账本）先于锚③ :920 的现行行号关系成立 |

**8 锚纪律本会话复核结论**：`grep -n "this.saveChunks()\|this.saveChunksIfDue()"` 结果恰为 7 个直调锚 + 2 个 IfDue 挂点 + IfDue 体内 1 个封装调用，与设计书 §3.3 表及材料自述（8 调用点+1 封装）一致；`emitProgressIfDue` 体内无保存调用（grep 反证）。R1-F1 修复未扰动锚点。

---

## 5. 验证情况

### 5.1 编译门禁（hvigor）

- **主控脚本实跑：`devecocli build --modules entry`（hvigor 全量编译）最终状态：通过。**（门禁结论来自本 run 主控脚本的门禁输出；报告员未重复执行该构建。）
- 旁证（设计书 §9.1 记录的上轮实跑）：`devecocli build` → BUILD SUCCESSFUL in 4m56s，零 error；唯一 warning 在 `ProbeHttp.ets:230`（U0.2 归档文件，改动面外）；SignHap 跳过签名（build-profile.json5 无 signingConfigs，主机侧常态）。

### 5.2 codelinter 辅助检查（提示性）

- 主控脚本实跑 exit 0。可见尾部输出：`Summary: Issues: 14 | Errors: 0 | Warnings: 14 | Suggestions: 0 | Files checked: 3`；14 条全部为 `@performance/avoid-overusing-custom-component-check`（Preferentially use the @Builder method…）提示级 warning，位于探针页（如 ProbeStore.ets:78）。**零 error，不阻塞；非本单元交付面缺陷。**（注：材料中该段前文被截断，以上为可见尾部事实。）

### 5.3 ArkTS 合规说明

- codelinter 不含 ArkTS 语法规则，**ArkTS 严格子集由 hvigor 编译期强制**——hvigor 全量编译通过即语法门通过。
- R1-F1 修复改动自查（编码会话记录）：`diskState` 显式 `RestoredPieces | null` 类型+null 窄化，无 any/解构/untyped 对象字面量。
- 本报告员本会话未对 .ets 文件做任何修改，不产生新合规面。

### 5.4 对照审查与独立复核结论

- 第 1 轮：**不通过**（R1-F1 medium + R1-F2~F4 low）。
- 第 2 轮（R1-F1 修复后）：**通过**（approved=true；R2-F1~F5 全为 low，均开放，见 §4）。
- 独立复核：**acceptable=true**；确认 R2-F1~F5 五项遗留，新发现 F6/F7 两项 low；给出最脆弱点判断（见 §7）。

### 5.5 本报告员自跑核验清单（本会话实际执行）

| 命令/动作 | 结果 |
|---|---|
| `wc -l` PieceGrabber/StateStore/PieceAlgo/ProbeResume | 1145 / 134 / 348 / 738 行（StateStore/PieceAlgo/ProbeResume 与设计书 §9.2 一致；PieceGrabber 1145 与设计书 1127 不符=R2-F5/复核F5 属实） |
| `grep -n "R1-F1\|1127" docs/design/u2-2-…-DESIGN.md` | 仅 :326 命中 `1127`；'R1-F1' 全文计数 0（复核F5 属实） |
| `ls -la` + `cat nul` + `git status --short` | `nul` 34 字节存在、内容"信息: 用提供的模式无法找到文件。"、git 未跟踪（复核F3 属实）；§1 十文件+设计书/NIGHT-RUN 台账改动全部在树未提交 |
| Read `PieceGrabber.ets:232-286` | R1-F1 门（:249-263）、D7 mkdir（:265-271）、基线重置（:276-280）在位 |
| Read `ProbeResume.ets:388-405` | :396 resumed 键与 :398 finished 同源（R1-F2/R2-F2/复核F2 属实） |
| Read `Index.ets:120-150` | :149 `target.resume()`+D9 注释块（:124-129）在位 |
| Read `MIGRATION_PLAN.md:69-126` | §5 结构与 §6 决策 1–11 原文，决策 4/10 条款引用属实 |
| `grep -n` 保存锚点 | 8 锚纪律成立（见 §4 表末） |
| sed 源码 `SingleSourceHTTPDownloader.cs:200-217`、`HTTPDownloaderBase.cs:224-241`（只读） | 复核F6 与 R2-F1 的源码论断属实 |
| `node -e JSON.parse(EXPECT-u2-2-…json)` | 解析通过，顶层键 unitId/slug/sessions/steps |

### 5.6 未运行项

- **Hypium 单测执行器未运行**（无执行器，待回贴）：10 条 chunksJson 用例已入库（PieceAlgo.test.ets describe('chunksJson')，设计书 §9.2 记 :294-424），执行记录由后续会话回贴。StateStore 的 IO 行为（rename 轮换/双槽回退/崩溃窗口）本地 Hypium 无法验证（fileIo 属 @kit），由 P2-U2 运行时探针承载。
- 本报告员未重复执行 hvigor 构建与 codelinter（按分工由主控脚本统一跑，结论见 §5.1/§5.2）。

---

## 6. 运行时验证待办（探针）

**探针 P2-U2 已生成，待人工在模拟器运行后回贴日志，用 xdm-probe-verify 工作流核对。**

- 运行手册：`D:/git/HarmonyPC/XdmHarmony/docs/probe/PROBE-u2-2-resume-state-persist.md`（16760B）
- 机器可读预期表：`D:/git/HarmonyPC/XdmHarmony/docs/probe/EXPECT-u2-2-resume-state-persist.json`（9450B；本会话 node JSON.parse 校验通过；7 步骤：BEGIN+会话 A S1~S3+SUMMARY+END / 会话 B S4+SUMMARY+END 两段独立）
- 运行步骤概要（详见手册）：主机侧 `node docs/probe/P1-U2-download-server.js`（零改动复用，慢源参数 /slow.bin?ms=600 由探针 URL 携带）→ 构建+安装+拉起 → P2-U2 卡片填源 → 自动跑 S1~S3 → `hdc shell aa force-stop com.example.xdmharmony` → `hdc shell aa start -b com.example.xdmharmony -a EntryAbility --ps page probe` → 进 P2-U2 手动点 S4 → 回贴两段日志 → xdm-probe-verify 逐条判定。
- 判定核心（容差口径，§0-2 拍板）：S3 `minFileOverPersisted=true`、`staleBytes≥0`；S4 `offsetsUnchanged=true`、`restoredSum>0 且 ≤ pausedDownloaded`、`firstProgressDownloaded ≥ restoredSum`（fresh-restart 缺陷直接判别式）、`finalSize=4194304`、`tempDirGone=true`、`allSpotsMatch=true`。主机侧第二证据：server 控制台恢复后各请求 Range 起点 vs S4 restoredLine 逐片人工对账。
- 提醒：S4 的 `resumed` 键当前与 `finished` 同源（§4 R1-F2），判定按 EXPECT 归并分支不受影响，但核对时应知晓该键语义退化。

---

## 7. 遗留问题与风险

**开放问题（8 项，全部 low 级，无 high/medium 开放）**：R1-F2（探针观测键）、R1-F3（nul 清理）、R1-F4（设计书措辞）、R2-F1（probeConnected 分支二选一收口）、R2-F5（设计书行号/伪码/D 系同步）、复核F6（门注释更正+补登记 D11）、复核F7（停摆边界登记）。其中 4 项纯文档、1 项探针一行、1 项代码可选收口、1 项提交前清理。

**最脆弱点（独立复核 weakestSpot 原文归纳）**：resume 恢复路径中"盘空"与"盘上已有预探测态"的交界带——R1-F1 门（同实例恢复友好偏离，未登记）、D4（start 先 clear）、D5（内存态不重读盘）三个对源码的恢复友好偏离都压在这一个窗口上组合生效，而其中两处（门注释、设计书 §3.4）仍被表述为源码保真，会误导审查与后续单元。运行时最坏结局是**记录卡死**（复核F7 静默停摆或 NonResumable 钉死）而非崩溃/数据损坏。

**覆盖缺口**：探针 S1~S4 恒走跨进程路径，同实例预探测窗口（R1-F1 门的唯一触达场景、恰是 D5/R1-F1 论证核心）无探针覆盖，只能靠代码审查与人工场景验证。

**已知边界（源码同貌，登记不修）**：
1. 状态文件在而分片文件被删 → lseek 超 EOF 写 sparse 零洞 → 成品错位（源码 FileStream.OpenOrCreate+Seek 同病；探针 allSpotsMatch 暴露后按 env 分流）。
2. 恢复集含 length=-1 片 → NonResumable 终态（源码 :169-170 同貌；EXPECT 记 Known-behavior 分支）。
3. 复核F7 停摆边界（源码同窗口同病）——登记 §3.4/§8 后按同口径处理。

---

## 8. 对下个单元的建议（U3.1 队列调度+并发上限）

1. **开工前顺手收口本单元 8 项 low**（均不阻塞 U3.1，但带病扩散成本更高）：删 `nul`（git-bash `rm`）；设计书 4 项修订（R1-F4 措辞 / R2-F5 行号与伪码 / 复核F6 门注释更正并把 R1-F1 门登记为 D11 / 复核F7+R2-F1 登记 §3.4）；ProbeResume.ets:396 `resumed` 改取 `startedFired`（一行）；R2-F1 二选一收口（建议选②登记差异——404 死链本就无恢复价值，登记比补保存更能说明语义）。
2. **行号基线**：核对 PieceGrabber.ets 时以 **1145 行**现值为准（设计书 §9.2 的 1127 已过期，R2-F5 修订前勿直接引用）。
3. **语义衔接**：U3.1 落 SaveForLater/队列调度本体（本单元 D6 显式让位）时会触碰 Index.ets handleToggle 与 Downloader 生命周期——设计时对照本单元 D9"一律 resume()"现状与 resume() 内"无状态→全新 start"自退化规则，避免恢复语义回退；注意 start() 先 clear()（D4）与队列入队路径的组合行为。
4. **纪律沿用**：主线程单点/消息化（决策 2）、StateStore 不新增清理入口（deleteTempDir 兜底）、`core/**` 不 import `probe/**`、PieceAlgo 零 @kit。
5. **探针**：U3.1 探针页沿用 ProbeKit 与 [XDM_PROBE] 规范；排队/并发数观测可复用本单元 S2 的 pollUntil+快照模式。

---

## 9. 交付说明

- **代码未做 git 提交**：全部交付物在工作树（本会话 `git status --short` 实证：M PieceAlgo/PieceGrabber/Index/ProbeIndex/string.json/PieceAlgo.test + 设计书与 NIGHT-RUN 台账；?? StateStore/ProbeResume/PROBE md/EXPECT json/nul），**待人工验收后由人提交并按 Phase 打 tag**。提交前务必先删 `nul`（§4 R1-F3）。
- 本 run 为 AmendWorkflow 续跑（dwfrun-86bedf52，单元参数自父 run dwfrun-b24f3036 的 args_json 原文恢复，与 run 名称/既有设计书/夜间台账三方互证一致）；既有实现按"收敛基线差异审查"口径处置（设计书 §9 已记录该上下文）。
- 对照源码 `resourses/xdm` 全程只读（本会话仅 sed/grep 读，无任何写操作）。
- 报告员未运行 hvigor 构建/codelinter/Hypium 执行器——门禁与 lint 结论引自主控脚本输出（§5.1/§5.2 已注明），单测执行记录待回贴（§5.6）。

—— 完 ——
