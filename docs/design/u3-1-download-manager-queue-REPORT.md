# U3.1 队列调度+并发上限 · 单元迁移报告

> 单元：U3.1（Phase 3 第 1 单元）｜对照源码：`resourses/xdm`（XDM 2023，C#/.NET，GPL-2.0，只读）｜目标工程：`XdmHarmony`（API 24 / SDK 6.1.1(24)）
> 设计书：[u3-1-download-manager-queue-DESIGN.md](./u3-1-download-manager-queue-DESIGN.md)｜探针手册：[../probe/PROBE-u3-1-download-manager-queue.md](../probe/PROBE-u3-1-download-manager-queue.md)｜预期表：[../probe/EXPECT-u3-1-download-manager-queue.json](../probe/EXPECT-u3-1-download-manager-queue.json)
> 报告：xdm-migrate 工作流"迁移报告员"角色，2026-09-28。本报告所有"本轮实测"均为报告员在本会话内执行的只读检查/构建，其余验证结论注明来源。

**结论速览**：[A] 静态门禁全过（本轮报告员复跑 `hvigorw test` 127 条全绿 + `hvigorw assembleHap` BUILD SUCCESSFUL）；对照审查第 2 轮通过；独立复核 acceptable（3 条 low 不阻塞）；[P] 运行时探针 P3-U1 已生成、待人工在模拟器/真机执行回贴；代码未做 git 提交（⑨）。

---

## ① 单元范围与验收要点

**目录依据**（UNIT_CATALOG.md:56 实读）：U3.1＝"并发上限 3 + 排队 + 状态机 + 优先级"，对照锚标注 QueueManager.cs（123 行）/DownloadQueue.cs（83 行），产出 `core/engine/DownloadManager.ets`，验收要点"排队正确（PROBE 记录并发数不超 3）"，验证 [A]+[P]，前置 U2.2。

**研究修正**（研究结论 fact 1+9，设计书 §7bis 采纳）：调度本体不在 QueueManager.cs（那只是命名队列+Schedule 的持久化清单），而在 `ApplicationCore.cs` 的 liveDownloads/queuedDownloads 双集合调度器；QueueManager 面降级为 U3.2/U4 兼容锚（设计书 §0-7）。

**任务书四项交付**：

| # | 任务 | 落点 | 状态 |
|---|---|---|---|
| 1 | 全局下载管理器：并发上限（默认 3）+排队（FIFO+优先级字段预留）+状态机 | `entry/src/main/ets/core/engine/DownloadManager.ets`（新，350 行）+ `core/engine/QueueAlgo.ets`（新，纯函数层） | 已实现 |
| 2 | Config 追加 maxParallelDownloads 键 | `core/Config.ets` 第 7 键（:39/:48/:64/:92/:124-126/:159-162 六处，本轮实读） | 已实现 |
| 3 | Index 接入 manager（新建经 manager 排队，超并发自动等待补位） | `pages/Index.ets` 五处收敛改动（本轮 git diff 逐一核实，见⑤） | 已实现 |
| 4 | 探针 P3-U1（6 并发请求观测 maxConcurrent 与补位顺序）+手册与预期表 | `probe/units/ProbeQueue.ets`（新）+ ProbeIndex/string.json 接入 + PROBE/EXPECT 文档 | 已实现，待运行 |

**交付文件（12 个，与 git 工作树逐一对应，本轮 `git status --porcelain` 实测）**：改 5——`core/Config.ets`(+18)、`pages/Index.ets`(±64)、`probe/ProbeIndex.ets`(+6)、`resources/base/element/string.json`(+8)、`test/List.test.ets`(+4)；新 7——`core/engine/QueueAlgo.ets`、`core/engine/DownloadManager.ets`、`test/QueueAlgo.test.ets`、`probe/units/ProbeQueue.ets`、`docs/probe/PROBE-…md`、`docs/probe/EXPECT-…json`、`docs/design/u3-1-…-DESIGN.md`。module.json5 与 main_pages.json 不动（设计书 §0-5 有据：INTERNET/2in1 已具备，队列调度纯内存无新增系统能力；本轮实读设计书注记，未改动两文件）。

**验收三要点与判定口径**：①编译过（⑤，双门禁通过）；②排队与上限实测吻合（[P]：S2 即时集合 3/3 + S3 peakLive≤3 + 补位序 FIFO，⑥待运行）；③事件面零破坏（[A] 侧：Downloader.ets 对 HEAD diff 为空、Index 事件消费方未出现在 diff 中——本轮 git 实测；[P] 侧：探针事件袋与业务共面，failed/paused 计数异常即回归，⑥）。

## ② 研究结论摘要（关键源码行为→ArkTS 对应表）

研究结论 10 facts 中与实现直接相关的 7 条如下（锚点列标注"✓抽查"者为报告员本轮 grep 实证，其余引用研究/设计会话只读核实记录）：

| 源码行为（锚点） | ArkTS 对应 | 风险 |
|---|---|---|
| 门判定＝`liveDownloads.Count >= Config.Instance.MaxParallelDownloads`（不含排队数），超门即 `queuedDownloads.Add(id,nonInteractive)`；GenericOrderedDictionary 为插入序 List+Dict，Add 已存在键不改位，`First()`=最旧项→严格 FIFO；ProcessNextQueuedItem 每次恰取 1 个（ApplicationCore.cs:144/:262/:567-578、Collections/GenericOrderedDictionary.cs:48-58）✓抽查（:35-36/:40/:144/:262/:455/:475/:496/:567 与 Add 的 ContainsKey 守卫均命中） | `DownloadManager.admitNew/resumeOne/dequeueOne` 门判定一律 `liveMap.size >= effectiveMaxParallel(Config…)`（DownloadManager.ets:162/:181/:344）；`queueMap`+`queueIds` 双结构（:124-126）；`pickNextQueuedId` 严格 `>` 首见胜出=默认全 0 严格 FIFO（QueueAlgo.ets:34-43） | low |
| 新下载三态判定：超门→不建实例入队（startType 保持 Waiting）；AddItemToTop 先于 liveDownloads.Add 与 Start；排队项不持有 Downloader（ApplicationCore.cs:126-186，:150 先于 :155-181） | Index 先 `store.add`+`unshift` 再 `admitNew`（Index.ets:115-121，本轮 diff 核实）；`launchStart` 先 `liveMap.set` 后 `start()`（DownloadManager.ets:270-278） | medium |
| 补位触发＝Finished/Failed/Cancelled 三处理器"移除→收尾→ProcessNextQueuedItem"（:415-498，:455/:475/:496 ✓抽查）；用户停运行中项→Stop()→Cancelled→同路径；取消排队项只移除不补位（:360-369） | `ManagedEvents` wrapper"簿记→delegate→补位"固定次序（DownloadManager.ets:93-109）；`stopOne` 双分支（:194-216，queued 分支不补位） | medium |
| 状态机：DownloadStartType×DownloadStatus 映射，SetDownloadStatusWaiting 只改 UI 不落库（Application.cs:231-240；DownloadEntries.cs:64-67） | 复用既有 `DownloadStatus`（Waiting=3）；resume 排队只置内存 `record.status=Waiting`（DownloadManager.ets:183）；新建路径 status=3 随 store.add 落库（D13） | low |
| ResumeDownload 幂等守卫：双 ContainsKey 命中即 return（:261，批量遇重复中止整批） | `resumeOne` 单点幂等 return（DownloadManager.ets:178-180），批量语义降级登记 D8 | low |
| ActiveDownloadCount=live+queued（:40 ✓抽查）；MaxParallelDownloads 默认 3，键名 "MaxParallelDownloads"（Config.cs:104 ✓抽查 `public int MaxParallelDownloads { get; set; } = 3;`；ConfigIO.cs:178-179/:392） | `activeDownloadCount()`（:237-239）；Config 第 7 键 `maxParallelDownloads`/`DEFAULT…=3`（Config.ets:39/:48） | low |
| 引擎七事件；Start/Resume 两路挂载一致；:622 AssembingProgressChanged `+=` 笔误（try/catch 吞） | DownloadEvents 六回调已覆盖（U2 冻结面），AssemblingProgress 不补——事件面冻结优先于逐事件对齐；DetachEventHandlers 无对应物（D14） | low |

**openQuestion 拍板**（设计书 §0-1/§0-2）：①onPaused 合流语义（无独立 Cancelled 事件）以 stopIntent 簿记+wasLive 守卫+空队 no-op 防御，排队取消不经事件走 `stopOne` queued 分支；②Waiting 落库分路径：新建路径落库（工厂 startWaiting=true）、resume 排队路径仅内存（原版同貌），重启不自动续跑由 U2.2 行为兜底。

## ③ 设计决策与有意差异（引用 MIGRATION_PLAN 决策条款）

设计书 §4 登记 15 条有意差异，全部保留，摘录如下（依据列注明计划条款）：

| # | 差异 | 依据 |
|---|---|---|
| D1 | C# `lock(this)` 不复刻——ArkTS 主线程事件循环天然串行，全方法同步无 await（"同步决策承诺"） | §6 决策 2 |
| D2 | `nonInteractive` 字段预留恒 false，进度窗口显隐归 Phase 4 | §6 决策 11 |
| D3 | `priority` 字段预留恒 0——源码本无优先级，pickNextQueuedId 按 priority DESC/插入序 ASC，默认全 0 严格等价 FIFO | 任务书"优先级字段预留"的忠实落法 |
| D4 | 命名队列/queues.db 二进制/Schedule 不实现，manager 内置单默认队列（内存）；持久化若做走 preferences JSON | §6 决策 10 同构；U3.2/U4 兼容锚 |
| D5 | ShutdownAfterAllFinished/RunCommandAfterCompletion/awakePingTimer 不实现 | §3 降级清单第 5/6 条（关机类/保活归 Phase 5） |
| D6 | 进度窗口集/ShowDownloadCompleteWindow 不实现 | Phase 4 域 |
| D7 | 补位路径 resume() 与新建即时路径 start() 双入口保留（源码 :322/:180 同貌）；全新记录 resume 经 U2.2 恢复桥自退化 start | — |
| D8 | 批量 ResumeDownload 遇重复项 `return` 中止整批 → manager 单 id 入参降为单点幂等 return | 源码行为差异登记 |
| D9 | 排队取消的 DB 回声延至 ManagerHooks 消费方（U3.1 UI 无触点，manager 零 DB 写红线） | U2.x 分层纪律 |
| D10 | 任务书 Config.cs:119 勘误：实锚 :104（:118 是 TempDir）；键名沿用工程 camelCase | 本轮抽查证实 :104 |
| D11 | effectiveMaxParallel 防御钳制 <1 归 1（源码无钳制，U4.3 设置 UI 落地前防御） | QueueAlgo.ets:50-52 |
| D12 | 任务书"暂停/恢复不占调度决策"与源码不符，按源码执行（暂停释放槽位补位；恢复过门可入队） | §0-3 登记 |
| D13 | 新建工厂 startWaiting false→true（status=Waiting(3) 落库），顺带对齐源码 AddItemToTop | §0-2 |
| D14 | DetachEventHandlers 逐事件 `-=` 不复刻（实例随 liveMap 摘除弃用）；源码 :622 `+=` 笔误自然不存在 | — |
| D15 | HandleProbeResult 由既有 handleConnected 承担，manager 不新增 | — |

§0 拍板另有关键三条：§0-4 Index 五处收敛改动（事件消费方零改动）；§0-5 module.json5/main_pages.json 不动（有据非遗漏）；§0-9 manager.init"后到者接管"（每次 init 重建 wrapper 替换 delegate，解决 Index/探针双页对应用级单例的事件袋竞争）。

## ④ 审查问题处置表（覆盖全部轮次）

对照审查 2 轮（R1 不通过 4 findings → R2 通过）+ 独立复核（acceptable=true，3 findings）。已修复编号：R1-F1、R1-F2、R1-F3。

| 编号 | 轮次/严重度 | 问题 | 处置 | 证据（报告员本轮核实方式） |
|---|---|---|---|---|
| F1 | R1/high | S4 的 newStartsAfterCancel/Stop 基线 startedBefore 取在提交循环前，两值恒=3，健康运行必报假 FAIL（EXPECT 要求恒=0，§5 明确 ≠0 即 FAIL 分流"排队取消补位回归/队列空 stop 补位回归"） | **已修复**：快照改取 stopOne 动作前 | 读码：ProbeQueue.ets:354 `startsAtCancel`（先于 :355 `stopOne(queuedId)`）、:361 `startsAtStopLoop`（先于 :362-364 stop 循环）、emit :358/:380 为 `startedCount − 快照`；grep `startedBefore` 全文件零命中（实测输出为空） |
| F2 | R1/high | S3 的 started 实现为步骤起点 delta（=3），EXPECT/手册定义为全会话累计 6，逐次运行必假 FAIL | **已修复**：S3 emit 改全会话累计 | 读码：ProbeQueue.ets:305 `new KeyValue('started', String(this.facts.startedCount))`，:303-304 注释记 R1-F2 口径；事件袋 :395-398 onStarted 计数含首发与补位 |
| F3 | R1/high | 7 处清单外工作树改动（PieceGrabber 热修等）不在本单元 files 清单，其中两文件在"显式不动"清单内 | **编排侧处理，代码零返工**：主会话按 D25 授权单独提交 | 本轮 git 实测：HEAD 前两条为 `e720b7a`（U2.3 热修 COLD-F1，提交信息明示"跨红线授权 D25"）与 `d73bee6`（U2.3 审查收口）；`git status` 工作树现仅剩 U3.1 的 12 个文件；`git diff HEAD --stat -- Downloader.ets` 为空（引擎事件面无损）。设计书 §1 末已追加"U2.3 谱系 D25 热修豁免注记"（:39 实读） |
| F4 | R1/low | S2 在 store.add 返回 false 时仍 admitNew（注释自称"与 Index 同口径"不实——Index.ets:116-119 add 失败提前 return）；S4 的 await store.add 未检查返回值 | **未修复，R2 定性不阻塞**（健康运行零影响，探针健壮性/注释准确性问题） | 读码仍在：ProbeQueue.ets:214-217（addOk=false 仅 failedCount++ 后继续 :219 admitNew）、:341（S4 未检查）。独立复核补充：该 failedCount++ 是死观测——S2 emit 键 :225-232 无 failed，S3 的 failed 增量以 :248 failedBefore 为基线，S2 期的自增落在其前观测不到 |
| F1 | R2/low | 复述 R1-F4（上轮未随修复下发） | **approved，遗留** | 同上 |
| F1 | 独立复核/low | 同 R1-F4 + 死观测论证 | **遗留（不阻塞）** | 同上；S2 注释现文 :215"DB 写失败仍继续提交链（与 Index 同口径记观测，不加判定）"仍含不实短语 |
| F2 | 独立复核/low | stopIntent 是只写不读的死簿记（全文件仅 add/delete 无读取点），而文件头与设计书宣称"三重防御：stopIntent+liveMap 成员资格+队列空 no-op"——实际起作用的只有后两者，虚假安全声明误导维护者 | **未修复（不阻塞）**：今日无功能影响（onPaused 全引擎唯一发射点在 PieceGrabber.ets:314 且只在 stop() 内，意图不可能分叉） | grep 实测：stopIntent 仅 DownloadManager.ets:128（声明）/:197（add）/:251（delete）+注释，无 `.has` 读取点 |
| F3 | 独立复核/low | 排队（Waiting）行按钮呈死态：handleToggle 对非 live id 一律 resumeOne，而 resumeOne 对 queueMap 命中的 id 幂等 return；按钮因 status≠Downloading 渲染"继续"，点击无效果。C# 排队取消行为在业务路径不可达（设计书 D9 已登记"UI 无排队取消触点"，但死按钮未点名） | **未修复（不阻塞）**：建议 U4 为 Waiting 行接 stopOne+hooks 回声或禁用/隐藏按钮，并在 D9 差异行补"排队行按钮暂呈死态" | 读码：Index.ets:132-143（handleToggle）、:378（按钮标签三元）、DownloadManager.ets:178-180（resumeOne 幂等 return） |
| — | 独立复核/weakestSpot | 最可能出运行时问题的缝：manager.init"后到者接管"+wrapper 构造期绑定——在途下载永远向发起页的 delegate 报告，探针观测正确性依赖手册"会话内不切页"纪律而非代码强制；唯一安全网是 S1 基线非零→UNVERIFIED 分流 | **接受，写入风险**（⑦-3）；复核同时声明沿 launchStart/launchResume→PieceScheduler 全链未找到同步异常导致 liveMap 僵尸槽的路径 | 独立复核记录；与设计书 §8-1/手册"会话纪律"一致 |

## ⑤ 验证情况

### 5.1 报告员本轮实测（[A] 门禁复跑，开发机桌面 win32，全部本会话执行）

| 检查 | 命令 | 结果 |
|---|---|---|
| Hypium 本地单测 | `DEVECO_SDK_HOME="D:/Tools/DevEco Studio/sdk" "D:/Tools/DevEco Studio/tools/node/node.exe" "D:/Tools/DevEco Studio/tools/hvigor/bin/hvigorw.js" test`（工程根；命令链沿用 U2.3 设计书 §3.7 实测口径） | exit 0，`BUILD SUCCESSFUL in 13 s 950 ms`，stdout 无 `ERROR: Error in` 行；磁盘结果 `entry/.test/default/intermediates/test/coverage_data/test_result.txt`＝**`Tests run: 127, Failure: 0, Error: 0, Pass: 127, Ignore: 0`**（127＝U2.3 存量 117＋本单元 QueueAlgo 10；末条用例 `effectiveMax_negative_clampsToOne result=Success`） |
| HAP 全量构建 | 同链 `… hvigorw.js assembleHap` | exit 0，`BUILD SUCCESSFUL in 14 s 575 ms`（SignHap 步骤输出签名配置提示——构建通过、产物未签名；真机首装签名准备见手册 §0，模拟器安装不需要） |
| 事件面冻结红线 | `git diff HEAD --stat -- entry/src/main/ets/core/engine/Downloader.ets` | 输出为空＝逐字节未动 |
| Index 改动收敛性 | `git diff -- entry/src/main/ets/pages/Index.ets` | 变更仅：头注释、import（+manager，-Downloader）、删 `downloaders`/`engineEvents` 两字段、aboutToAppear 加 init、startNewDownload 改 admitNew（工厂 `false`→`true`）、handleToggle 整体替换、handleFinished 删 `downloaders.delete(id)` 一行——事件消费方 handleStarted/Connected/Progress/Paused/Failed 与 buildEngineEvents 不在 diff 中，零改动成立 |
| 修复残留 | `grep -n "startedBefore" probe/units/ProbeQueue.ets` | 零命中 |
| 探针红线 | `grep -rn "XDM_PROBE" entry/src/main/ets/core/` | 仅 8 行注释性声明（"绝不输出 [XDM_PROBE]"类），零代码输出行 |
| 单测注册 | grep `it(`（QueueAlgo.test.ets，10 条 :48-123）／`queueAlgoTest`（List.test.ets:18/:29）／`P3-U1`（ProbeIndex.ets:28/:106-107） | 三处注册齐全 |
| stopIntent 争议核实 | `grep -n "stopIntent" DownloadManager.ets` | :128/:197/:251，无读取点（独立复核 F2 定性属实，见④） |
| 对照源码锚点抽查（只读） | grep `MaxParallelDownloads`（Config.cs）／双集合与补位锚（ApplicationCore.cs）／Add 守卫（GenericOrderedDictionary.cs） | Config.cs:104 `= 3` ✓；ApplicationCore.cs:35-36/:40/:144/:262/:455/:475/:496/:567 ✓；GenericOrderedDictionary.cs Add 含 ContainsKey 守卫 ✓ |

### 5.2 工作流记录结论（报告员引用，本轮未复跑）

- **hvigor 全量编译门禁**（工作流门禁执行）：`devecocli build --modules entry` 最终状态**通过**（本会话另以 hvigorw assembleHap 复跑佐证，见 5.1）。
- **codelinter 辅助检查**（提示性，门禁记录）：exit 0，`Issues: 14 | Errors: 0 | Warnings: 14 | Suggestions: 0 | Files checked: 3`，14 条全部为 `@performance/avoid-overusing-custom-component-check` 提示性 warning（ProbeStore.ets 等探针侧既有文件），无 error。
- **编码员修复后自验记录**（实现摘要）：R1-F1/F2 修复后 `hvigorw test` 全绿＋assembleHap 零 error 零新 warning＋ProbeQueue.ets lint 零缺陷。
- **对照审查**：R1 不通过（3 high＋1 low）→ R2 **通过**（1 low 遗留，见④）。
- **独立复核**：**acceptable=true**，3 条 low 均不阻塞验收（见④）。

### 5.3 ArkTS 合规说明

ArkTS 严格子集由 **hvigor 编译期强制**（codelinter 不含 ArkTS 语法规则）——5.1 两项全量编译通过即本轮合规的执行证据。编码自查对照 arkts-grammar-standards 要点在设计书 §7-[A]-1 登记：无 any、对象字面量带声明类型（如 ProbeQueue.ets:420 `const hooks: ManagerHooks = {…}`）、Map/Set 仅限 get/has/set/delete/size/add 面、禁 for..in（双结构法+indexed for 投影，QueueAlgo.ets:36-38/DownloadManager.ets:329-334）、throw 仅 Error 子类。

## ⑥ 运行时验证待办（探针）

**本单元有探针，[P] 运行时验证尚未执行——单元验收核心"排队与上限实测吻合"目前只有静态证据，待人工运行后回贴。**

- 产物：手册 `docs/probe/PROBE-u3-1-download-manager-queue.md`＋预期表 `docs/probe/EXPECT-u3-1-download-manager-queue.json`（7 标记行：BEGIN+S1~S4+SUMMARY+END，单会话四步全自动）。
- 运行指引（手册 §0-§3 摘要）：①主机启动测试源 `node P1-U2-download-server.js`（零改动复用，ms=300/0 由探针 URL 携带）并放行防火墙；②`devecocli run --module entry` 后 `hdc shell aa start -b com.example.xdmharmony -a EntryAbility --ps page probe`；③探针页填**主机局域网 IP**（禁 127.0.0.1）→ 点"运行全部"；④`hilog -x | grep XDM_PROBE` 抓取回贴，由 xdm-probe-verify 工作流逐步骤判定。
- 核心判定锚（EXPECT 表）：S1 `maxParallel=3`（Config 第 7 键默认值实测）＋基线 0/0＋`sourceStatus=206`；S2 `liveAfterSubmit=3 queuedAfterSubmit=3 activeAfterSubmit=6 queuedOrder=4/5/6`（上限即时锚）；S3 `peakLive≤3、swapCount=3、swapTargets=4/5/6（FIFO 补位序）、allFinished=6 failed=0 started=6`；S4 `newStartsAfterCancel=0（排队取消不补位）、queuedCancelledEcho=1、pausedCount=3、liveAfterStop=0、newStartsAfterStop=0（队列空 stop 无补位）`。
- 会话纪律：探针会话内不切页（manager.init 后到者接管，中途回 Index 事件袋被换走）；S1 基线非零→杀进程重启重跑；环境分支/FAIL 分流见手册 §5。

## ⑦ 遗留问题与风险

1. **三条 low 遗留**（④详证，均不阻塞）：探针 store.add 检查口径不一致＋failedCount 死观测（R1-F4/R2-F1/复核F1）、stopIntent 死簿记与"三重防御"声明不符（复核F2）、排队行按钮死态未在 D9 点名（复核F3）。归属：U4 UI 接入时统一消化。
2. **[P] 探针未运行**：验收核心（S2/S3/S4）尚待设备侧证据；本报告的"通过"仅覆盖 [A] 静态面。
3. **会话纪律依赖**（复核 weakestSpot）：探针观测正确性依赖"会话内不切页"的手册纪律而非代码强制；会话被打断时旧 wrapper 事件落进孤儿事实袋，安全网仅 S1 基线 UNVERIFIED 分流。
4. **24 连接压力**：3 并发×8 分段打 Node 单线程测试源；S3 `failed>0` 时按 EXPECT 分流 env（ms=600 或减提交数重跑）。
5. **队列纯内存**：重启即清空（原版 liveDownloads/queuedDownloads 同貌），重启不自动续跑由 U2.2 行为兜底；排队/运行态无持久化。
6. **构建签名提示**：assembleHap 输出签名配置提示（产物未签名）——真机验证前需按手册 §0 完成 `devecocli signature generate`。
7. **D9 DB 回声未接**：排队取消仅置内存 status=Stopped，无 DB 写（manager 零 DB 写红线）；DB 回声待 hooks 消费方（U4）。

## ⑧ 对下个单元的建议（U3.2 限速+重试+定时调度）

1. **Scheduler 直接消费现成 API**：manager 的 resumeOne/stopOne 均单项粒度，批量定时启停按 id 列表循环调用即可（设计书 §8-5 预留对账）；注意 resumeOne 过门可入队、stopOne live 分支补位在 onPaused 回声时点——定时批量操作的事件风暴与限速叠加时观察门判定次序。
2. **U4 UI 接入清单**（消化遗留）：①Waiting 行按钮接 `manager.stopOne`+hooks 回声或禁用/隐藏（复核F3），并补 D9 差异行；②清理 stopIntent——消费（诊断日志字段）或删除并把"三重防御"改"双重防御（wasLive 去重+空队 no-op）"（复核F2）；③新增探针勿复制 S2/S4 的"add 失败继续提交链"模式，统一 add 失败跳过 admitNew 并补 addFailed 观测键（R1-F4）。
3. **Config 第 7 键**：setter 已备 U4.3 设置 UI 直接消费；改值无热生效语义（只影响后续门判定，原版同貌），设置项做下拉整数即可（源码 WPF 同款）。
4. **兼容锚勿破**：队列持久化若做走 preferences JSON（决策 10 同构），不复刻 queues.db；优先级消费口子在 QueueAlgo.pickNextQueuedId，改动时保持"严格 `>` 首见胜出"语义（默认全 0=FIFO 的等价性依赖它）。
5. **探针基建**：QueueAlgo 纯函数层零 @kit 的"Hypium 直接加载"模式（PieceAlgo 同口径）可继续用于 U3.2 限速数学（SpeedLimiter 睡眠补偿）的单测承载。

## ⑨ git 提交说明

**本单元代码未做 git 提交。** 本轮实测：`git status --porcelain` 工作树含且仅含 U3.1 的 12 个文件（5 M＋7 ??），HEAD=`d73bee6`（U2.3 收口）——工作树状态与设计书 files 清单一致，无清单外改动。待人工验收后由人提交（单元粒度回滚点），并随 Phase 3 收口打 `phase-3` tag（计划 §10）。

执行口径注记：MIGRATION_PLAN §9.3 原写"AI 每单元完成即 git 提交"，本单元按当前流程改为人工验收后由人提交，以本报告口径为准。

许可证（计划 §11）：XDM 2023 为 GPL-2.0，本工程对照重写属衍生作品，分发须遵循 GPL-2.0（课程内部使用不受影响）。
