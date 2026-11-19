# U7.3 签名打包+交付文档 迁移报告（Phase 7 收官）

- 单元：U7.3 签名打包+交付文档（UNIT_CATALOG.md:89，Phase 7 第 3 单元，M7 交付）
- 报告日期：2026-10-11
- 目标工程：D:/git/HarmonyPC/XdmHarmony（HarmonyOS PC，targetSdkVersion 6.1.1(24) / compatibleSdkVersion 6.1.0(23)，bundle `com.example.xdmharmony`，ArkTS 严格子集）
- 对照源码：D:/git/HarmonyPC/resourses/xdm（XDM 2023，C#/.NET，GPL-2.0，只读；本单元仅引用其 LICENSE 与既有结论，未触碰）
- 设计书：docs/design/u7-3-signing-delivery-DESIGN.md（事实基线 F1~F20，本报告直接引用其编号）
- 本单元产出：docs/delivery/DELIVERY.md（新建，310 行）、README.md（新建，46 行）、release 构建三轮（09:01 / 10:05 / 10:21）与交付物登记
- 审查：3 轮对照审查，第 1 轮否、第 2 轮否、第 3 轮通过；修复 R1-F1、R1-F2、R2-F1；独立复核 acceptable:true（5 项 low 登记）
- 门禁：hvigor 全量编译通过；单测真值门禁 640/640（run-hypium 口径）；codelinter exit 0（提示性）
- 引证约定：本报告标注「本报告员实测」的数字、哈希、行号均为本报告会话内亲自执行的命令与读取所得；「管线门禁」指单元工作流统一执行的编译、测试、检查轮，本报告员未复跑其本体，只读其留档；引自既有文档者注明出处行号。

---

## ① 单元范围与验收要点

**计划登记**（UNIT_CATALOG.md:89）：范围=签名打包（材料人工提供）、迁移报告含 15% 降级清单与原因、GPL-2.0 声明（MIGRATION_PLAN §11）、真机回归扩展/后台/通知；验收要点=签名 HAP 可安装、交付物齐；验证方式=[H]+[P]回归。

**本 ask 拆解为三项工作**：

1. release 构建：signingConfigs 已就绪（build-profile.json5:3-17、:19-31，设计书 F1），按单元约束直接执行 `devecocli build --product default --modules entry --build-mode release` 出 HAP；签名条件不具备时才改为登记命令清单。实际条件具备，HAP 已产出并登记。
2. docs/delivery/DELIVERY.md 交付总结：24 单元全景、M1~M7 阶段划分、降级清单（主表 9 项+实现级分层）、GPL-2.0 声明、探针状态、已知问题三档账、交付物登记、构建与测试复现。
3. README.md：ask 原文写「更新」，实测文件不存在（设计书 F8），实为新建。内容为构建、测试、探针三指引。

**单元性质**：交付类。零业务代码、零探针、零配置改动（设计书 §1.2 逐文件核对清单、§1.3 零声明）。本单元自身不产生新的源码行为差异，DELIVERY.md 是全部既有差异的正式汇总点。

**验收检查表**（设计书 §5，A~H 共 8 项）关键项与本单元结果：

| # | 检查项 | 结果 |
|---|---|---|
| A/B | DELIVERY 六部分齐全、GPL-2.0 声明四要素 | 达成（A.1~H 附录逐节在位，A.4 四要素齐，第 3 轮审查通过） |
| C | release 流程可复现、T7 登记完整 | 达成（三轮构建，10:21 轮留档并登记四元组指纹）；登记与磁盘的时序耦合见⑦第 1 条 |
| D | 640 单测全绿保持（run-hypium 唯一计分口径） | 达成（管线门禁轮 verdict ok:true、640/640，本报告员实读，见⑤） |
| F/G | git diff 仅含 docs/delivery/ 与 README.md、配置零改动 | 达成（本报告员 `git status --short` 实测仅 3 个未跟踪路径，tracked 零改动） |
| E/H | README 指引可照做、降级表与计划一致 | 达成（命令面与 DELIVERY F 节同源；B.1 九项对照 MIGRATION_PLAN.md:45-54 逐条承载） |

---

## ② 研究结论摘要（关键事实与工程对应表）

研究阶段定位了交付文档四节素材的全部来源，并对命令面、产物、git 状态做了实测。逐条对应如下：

| # | 关键事实（出处） | 工程对应（落进交付文档或流程的形态） | 风险 |
|---|---|---|---|
| 1 | signingConfigs `default` 就绪（build-profile.json5:3-17、:19-31；AGC 已注册真机 UDID，PROBE-SESSION-ALL.md:76） | 不重跑 `devecocli signature generate`（会重写配置）；直接显式 release 构建；本单元 files 不含 build-profile.json5 | low |
| 2 | compatibleSdk 钉 6.1.0(23)、targetSdk 6.1.1(24)（build-profile.json5:22-23）；真机装 API 24 包被拒 code 9568297（PROBE-SESSION-ALL.md:77-78） | DELIVERY B.3/F.4 与 README.md:10 写明钉值原因，拦截任何「升回 24」的改动 | medium |
| 3 | 单测真值口径=run-hypium 四条件（scripts/HYPIUM_GATE.md:21-29）；640/640 已有两份 verdict 实证 | DELIVERY F.3 与 README 测试节照抄包装命令，明写「不得以 hvigor 退出码或 BUILD SUCCESSFUL 判绿」 | medium |
| 4 | 降级九项带原因域（MIGRATION_PLAN.md:45-54）；第 9 项开机自启已实际落定（module.json5 无 startupTask） | DELIVERY B.1 主表 9 项逐条承载；实现级差异另入 B.2，两层不混表 | low |
| 5 | GPL-2.0 声明为硬性必备节（MIGRATION_PLAN.md:203-205）；extension/LICENSE 在位，工程根无 LICENSE | DELIVERY A.4 独立节承载四要素；根 LICENSE 是否补列 openQuestion 待人工拍板 | low |
| 6 | 探针状态：会话#1 已跑 10/14（PROBE-SESSION-ALL.md:74-101）；P2-U2 已修待复验（a39ba92）；会话#2 待跑 15 项（11 份新手册） | DELIVERY C 节按三段登记；U7.1 探针状态引 u7-1-dash-REPORT.md:10 原话「已生成待人工运行回贴」 | low |
| 7 | 已知问题素材=各单元 REPORT §7；U4.1 两 medium 已修（Index.ets:896-899）；U4.2 IR-F1 报告快照过时（实际随 1047748 修复）；U6.2 IR-F1 开放 | DELIVERY D 节三档账：已修复登记证据链、开放 medium 单列（D.2）、历轮 low 一行引用（D.3） | medium |
| 8 | 24 单元全部落地提交史（36 提交），git tag 为空；a98e2fc 提交信息自称「M6 收官」与 v2 划分漂移 | DELIVERY A.2 按 UNIT_CATALOG v2:15 校正划分并注明漂移；tag 待人工补打（openQuestion #1） | medium |
| 9 | 工程结构实况：native 层在 entry/src/main/cpp（计划图 libc/ 未采用）；module.json5 已含 2in1+四权限+后台模式 | 文档按实况写；本单元 module.json5 零改动（单元模板「当前缺 ohos.permission.INTERNET」提法已过时） | low |
| 10 | 已有 HAP 产物但构建模式不可证（devecocli 默认 debug，`--help` 实测；mapping/ 无 mapping.txt 与混淆关闭一致） | E 节以重跑 release 的新产物登记（模式/时间戳/大小/sha256），旧 HAP 不充当交付物 | medium |

---

## ③ 设计决策与有意差异

**依据的计划条款**：

- MIGRATION_PLAN §3（docs/MIGRATION_PLAN.md:45-54）：九项明确降级，节标题原文要求「交付报告中逐条声明」。
- MIGRATION_PLAN §11（docs/MIGRATION_PLAN.md:203-205）：对照源码重写与扩展 JS 复用均属衍生作品，分发必须遵循 GPL-2.0，交付报告中需明确声明。
- MIGRATION_PLAN §6（docs/MIGRATION_PLAN.md:112）：十一条关键技术决策，为迁移本体既有遵循，本单元汇总、不新增。
- UNIT_CATALOG v2（docs/UNIT_CATALOG.md:9-19）：M1~M7 关键路径划分（:13-15）；tag 由人工执行（:19「AI 每单元完成即 git 提交（单元粒度回滚点），人工验收移到 Phase 级」）；Phase 7 整机回归用正式应用、不用探针页（:104）。

**有意差异清单**（11 条，均为登记性/流程性决策，无新源码行为差异）：

1. 本单元自身零源码行为差异：无新纯函数、无新状态机、无新探针。
2. MIGRATION_PLAN §3 九项降级（合计约 15% 功能面）在 DELIVERY B.1 主表逐条承载并写原因域与源码锚点；实现级差异入 B.2 单独一层，不与主表混排。
3. compatibleSdk 6.1.0(23) 环境适配作为交付形态写入文档（真机 MateBook Pro HAD-W24 为 API 23，装 24 被拒 code 9568297），并设为拦截性提醒（DELIVERY F.4 第 1 条、README.md:10）。
4. git tag 不由本单元补打：UNIT_CATALOG v2:19 规定为人工 Phase 验收动作，且探针会话#2（15 项）未过；DELIVERY A.2 登记「tag 待人工补打」（openQuestion #1）。
5. 工程根不补 GPL-2.0 LICENSE 文件（实测不存在）：ask 硬性要求是 DELIVERY.md 内含声明，根 LICENSE 列 openQuestion #2 待人工拍板，编码员未擅自新增。
6. release HAP 二进制不入 git：`.gitignore` 的 `**/build` 与 entry/.gitignore `/build` 已忽略（`git check-ignore` exit 0，设计书 F11）；DELIVERY E 节仅登记路径、模式、时间戳、大小、sha256。
7. 版本号维持 1.0.0/1000000；build-profile.json5、entry/build-profile.json5、AppScope/app.json5、module.json5 四个配置文件零改动（签名、release buildOptionSet、四权限均已就绪）。
8. README 为新建而非更新（文件不存在实测），交付说明中已纠正提法。
9. 阶段划分按 UNIT_CATALOG v2 校正：M6=浏览器接管+HLS（U6.4 止）、M7=交付（本单元）；a98e2fc 提交信息自称「M6 收官」系措辞漂移，DELIVERY A.2 注 1 写明。
10. 两个同名 IR-F1 分开登记：U4.2 报告的 IR-F1（完成窗单飞，medium）按「已修复」登记并附证据链（1047748 提交 + ProgressWindowDialog.ets:400-410 入队、:456-459 补弹实测），不照抄其报告过时的「未修」快照（设计书 F16）；U6.2 报告的 IR-F1（processNormalVideo 携带 tabUrl 命名面，medium）按「开放」登记于 D.2（R1-F2 补登），修码与否移交人工拍板。
11. 本单元无探针文件（交付类，PROBE_SPEC 不适用；UNIT_CATALOG.md:104）；真机整机回归归属探针会话#2 人工验收。

---

## ④ 审查问题处置表

审查序列：第 1 轮否（R1-F1~R1-F4）、第 2 轮否（R2-F1、R2-F2）、第 3 轮通过（R3-F1 为 low 不阻塞）。已修复编号：R1-F1、R1-F2、R2-F1。下表为三轮审查与独立复核的全部登记项（位置行号为本报告员实读 DELIVERY.md 的现行行号）：

| 编号 | 严重度 | 位置 | 问题摘要 | 处置 | 复核状态 |
|---|---|---|---|---|---|
| R1-F1 | high | E 节 T7 表（现 ：239-242） | 登记指纹与磁盘产物失配：登记的是 09:01 构建产物（signed 8,937,128 B / sha256 074709d9 开头），磁盘已被 09:44 重建覆写为 11,828,664 B / 22 条目，登记值无留档可对 | 按审查路径①重跑 release 并重测三件套回填；增补产物时间线与登记时序约定，构建日志留档 migration-runs | 已修复（第 2 轮 verified） |
| R1-F2 | medium | D.2（现 ：195）、B.2（:120）、D.3（:220） | D 档 2 声明「未发现仍开放的 medium」与 U6.2 报告 ：99 的 IR-F1（medium，未修）矛盾；B.2 将其误标 low | D.2 补登 U6.2 IR-F1（附 BridgeRoutes.ets:616-619、CapturedVideoTracker.ets:224-227、:448-461 代码证据链与 U6.3 交接漏单说明）；B.2/D.3 等级更正；修码与否移交人工拍板 | 已修复（verified） |
| R1-F3 | low | B.1 表第 1 行（:87） | 源码锚点误写 app/XDM/YDLWrapper/YDLProcess.cs，实际唯一命中为 app/XDM/XDM.Core/YDLWrapper/YDLProcess.cs | 未修 | 独立复核仍报（find 实测） |
| R1-F4 | low | A.3 表 U6.2 行（:61） | 「+46 Hypium」无出处：u6-2 报告 §5.5 与 8b91992 提交信息均对不上；注册计数从 362 增至 422，增量为 60 | 未修 | 独立复核仍报 |
| R2-F1 | medium | E 节 T7 表与时间线（:232-242） | 10:05 重跑登记后，产物再次于 10:08 被覆写（hvigor 守护日志 daemon-35192.log:320/:337 实证 assembleHap、exitCode=0）；10:05 登记的 sha256 永久不可复核 | 按审查路径①再跑 10:21 release、重测三件套回填；时间线补 10:08 事件（尺寸判据：unsigned 11,685,203 B 与 09:44 逐字节同尺寸，而三次 release 构建 unsigned 均 8,805,794 B，判定为门禁默认模式构建、非交付构建未登记）；登记时序约定扩为三条；路径②（门禁改输出目录/模式）列 openQuestion #5 | 已修复（verified） |
| R2-F2 | low | E 节时间线 09:44 行（:232） | 「构建模式无法独立证明」与第 1 轮审查已实测的 pack.info releaseType=Release 矛盾；「与 01:23/01:24 旧产物差 <1KB」无留档来源 | 09:44 行改为「非本单元构建产物、未登记」；删除无据比较 | 已改（独立复核未再报） |
| R3-F1 | low | 登记时序约定第 2 条（:236） | 判别特征「22 条目」未注明 signed 产物口径，用于 unsigned 门禁产物会误判（unsigned 门禁产物同为 21 条目、含双 map） | 补了 unsigned 尺寸判别（11,685,203 B）；条目数的 signed 口径注记未补 | 部分落实（独立复核仍报） |
| 独立复核-1 | low | :87 | 同 R1-F3（未修） | — | acceptable:true 下登记 |
| 独立复核-2 | low | :61 | 同 R1-F4（未修） | — | 同上 |
| 独立复核-3 | low | :236 | 同 R3-F1（仅部分落实） | — | 同上 |
| 独立复核-4 | low | F.1 WARN 基线句（:264） | 「WARN 仅为探针文件与 ClipboardWatcher/ManifestClient 的 may-throw 既有基线」枚举不全：10:21 构建日志 94 处 WARN 落在 16 个文件，另有 AdaptiveAssembler(6)、AdaptiveAttemptFile(11)、AdaptiveRcpStream(1)、AdaptiveStateStore(10)、DownloadStore(3)、SaveDirectory(2)；「非本单元引入」的实质结论成立 | 未修（U7.1 报告 R7 原口径为「92 条 warning 为未触碰文件既有基线」，未做枚举） | 独立复核仍报 |
| 独立复核-5 | low | E 节 T7（:239-242）与 F.2（:267-273） | 10:21 登记指纹磁盘不可对盘（磁盘为 10:23:09 门禁覆写态，判别特征与约定第 2 条吻合，属已登记的覆写态而非真实失配）；F.2 冒烟命令指向默认路径，现在执行装到的是门禁产物而非登记的 release 产物 | 按约定第 3 条收敛：全部构建活动结束后由人工执行 §F.1 一次并按实测回填；F.2 必须在终局登记之后执行 | 独立复核仍报（结构性遗留，见⑦第 1 条） |

独立复核总体结论 acceptable:true。其 weakestSpot 原话（转述）：E 节交付物登记与磁盘产物的时序耦合是全单元唯一无法靠文档自身闭合的环节，收敛路径依赖文档外动作（人工终局执行 §F.1，或门禁改输出目录的基建决策）。

---

## ⑤ 验证情况

### 5.1 管线门禁（管线执行，本报告员未复跑本体）

1. hvigor 全量编译（`devecocli build --modules entry`）：通过（管线门禁结论）。磁盘 10:23:09 的产物与本轮 assembleHap 时点吻合，属默认模式构建（特征见 5.3 判别）。
2. 单测真值门禁（run-hypium.cjs 包装）：通过。本报告员实读最新归档 `migration-runs/hypium/2026-10-11T02-52-26-395Z-82eaf3a9-2b42-4986-a3cd-e75d1c632936/verdict.json`：`ok:true`、`counts` total=640 / pass=640 / failure=0 / error=0 / ignore=0、child code 0、resultFile 为 `entry/.test/default/intermediates/test/coverage_data/test_result.txt`（38,630 B）。命令面（DELIVERY.md:279）：`node scripts/run-hypium.cjs --expected-tests 640 --output ../migration-runs/hypium -- 'D:/Tools/DevEco Studio/tools/node/node.exe' 'D:/Tools/DevEco Studio/tools/hvigor/bin/hvigorw.js' test --no-parallel`。历史归档另有 2026-10-10 两份与 2026-10-11T01-36 一份全绿 verdict（DELIVERY.md:284）。
3. codelinter 辅助检查（提示性，不作判绿依据）：exit 0，Summary 为 Issues 10 / Errors 0 / Warnings 8 / Suggestions 2 / Files checked 7；样例提示 Index.ets:1771 的 `hp-arkui-set-cache-count-for-lazyforeach-grid`（Suggestion）。

### 5.2 release 构建复现（本报告员对留档日志的核对）

10:21 交付构建留档 `D:\git\HarmonyPC\migration-runs\build-release-u7-3-20261011T1013.log`（21,958 B，`ls -l` 实测）。本报告员 grep 核对：第 326 行 `BUILD SUCCESSFUL in 19 s 397 ms`、第 330 行 `Build completed successfully`、全文 WARN 94 处（与独立复核-4 的计数一致）。三轮构建（09:01 全量 4 min 44 s、10:05 增量 12 s 747 ms、10:21 增量 19 s 397 ms）证明 §F.1 命令面可复现。

### 5.3 本报告员磁盘自查（写本报告时点）

- `ls -l --time-style=full-iso` + `sha256sum`（entry/build/default/outputs/default/）：
  - signed：2026-10-11 10:23:09.619 +0800，11,828,663 B，sha256 `81cf6bd2a0b91ed66ab5bef15eb7324c040ba6c7fb611975dbe52318382a872e`
  - unsigned：2026-10-11 10:23:09.255 +0800，11,685,203 B，sha256 `2daa5a1edc3f495d05176b8902df66836de9c6f350506e019ca47c4e2ac83c6d`
- python zipfile 解包：signed 22 条目（含 ets/sourceMaps.map + ets/symbolMap.map + .pages.info）；unsigned 21 条目（含双 map、无 .pages.info）。与 DELIVERY.md:236 登记时序约定第 2 条的门禁产物判别特征吻合，即磁盘当前为管线门禁的默认模式覆写态，截至本报告未被再次覆写（与独立复核期间的观察一致）。
- 两产物内 pack.info 实测均为：bundleName `com.example.xdmharmony`、version 1000000/1.0.0、deviceType ["phone","2in1"]、apiVersion compatible 23 / target 24、releaseType `Release`。可见 pack.info 的 releaseType 字段在默认模式构建下同样填 Release，该字段区分构建模式的推断不成立（与 R2-F2 修正一致），模式判别靠尺寸与 zip 条目。
- E 节 T7 登记的 10:21 指纹（signed sha256 `983f07c7...`）当前磁盘不可对盘，可依据仅剩 10:21 构建日志；终局人工登记（约定第 3 条）仍待执行，见⑦第 1 条。

### 5.4 对照审查与独立复核

- 对照审查 3 轮：第 1 轮否（4 项，含 1 high）、第 2 轮否（2 项）、第 3 轮通过。修复落实情况见④。
- 独立复核：acceptable:true，5 项 low（3 项为历轮 low 的复核确认，2 项新增），明细见④表末四行与独立复核-5。

### 5.5 git 核对（本报告员实测）

`git -C XdmHarmony status --short` 输出仅三行：`?? README.md`、`?? docs/delivery/`、`?? docs/design/u7-3-signing-delivery-DESIGN.md`；tracked 文件零改动（设计书 §5-F/G 达成）。`git log --oneline` 最近提交为 a98e2fc（U7.1）；`git tag -l` 为空（count 0）。

### 5.6 ArkTS 合规说明

本单元零 .ets 改动，无新语法面。ArkTS 严格子集由 hvigor 编译期强制（codelinter 不含 ArkTS 语法规则）；迁移本体 24 单元的 .ets 全部通过本轮 hvigor 全量编译门禁，即为该口径下的合规证据。

### 5.7 材料矛盾点核查

按「门禁与日志为准」原则核查了交付材料中的矛盾陈述，登记如下：

1. E 节登记指纹与磁盘产物不一致：属已登记的门禁覆写时序问题（约定第 2/3 条），与门禁结论（编译/测试均通过）无冲突，收敛路径见⑦第 1 条。
2. DELIVERY.md:264 的 WARN「仅为」枚举与日志不符（实测 94 处 WARN 落 16 文件）：登记为独立复核-4，未修。
3. DELIVERY.md:61「+46 Hypium」与 u6-2 报告、8b91992 提交信息对不上：登记为 R1-F4，未修。
4. a98e2fc 提交信息自称「M6 收官」与 UNIT_CATALOG v2 划分漂移：DELIVERY A.2 注 1 已按 v2 校正口径注明。

### 5.8 未执行项

- 本报告员未复跑 hvigor 编译门禁、run-hypium 门禁、codelinter（管线已跑，本报告员读其留档；5.1/5.2 的结论以此为准）。
- 真机安装冒烟（DELIVERY §F.2）本单元未执行：本交付会话无设备连接要求，归属会话#2 人工验收；且执行前须先按约定第 2 条判别产物身份（当前默认路径装到的是门禁产物）。

---

## ⑥ 运行时验证待办

**本单元无探针**（交付类；设计书 §1.3 零声明；UNIT_CATALOG.md:104 明确 Phase 7 整机回归用正式应用、不用探针页）。运行时验证全部归属人工环节：

1. 探针会话#2 待跑 15 项清单：DELIVERY.md C.3（:159-168），含 P4-U1 收尾、P4-U2、P5-U1、P5-U2、P0-U4（ffmpeg 真机）、P6-U1~U6.4、P7-U1-dash 四件。手册与预期表在 docs/probe/ 下（PROBE-*.md + 同名 EXPECT-*.json），总指引 docs/probe/PROBE-SESSION-ALL.md。
2. P2-U2 复验：缺陷已随 a39ba92 返修，探针未重跑，整单元重跑归属会话#2（DELIVERY C.2）。
3. 真机安装冒烟：DELIVERY §F.2 命令（:268-271），装包成功即 compatibleSdk 6.1.0(23) 钉值的最终验证；失败时记录错误码，不得通过改 compatibleSdk「修复」。执行前置条件见⑦第 1 条。

---

## ⑦ 遗留问题与风险

按优先级排列：

1. **E 节交付物登记与磁盘产物的时序耦合**（本单元最高优先遗留）：管线门禁每轮以默认模式 assembleHap 覆写 entry/build/default/outputs/default/（09:44、10:08、10:23 三次实证），T7 指纹登记后即偏离磁盘。当前磁盘为 10:23:09 门禁覆写态（本报告员实测指纹见 5.3），10:21 登记的 sha256 仅能凭构建日志侧证。收敛路径有两条，均超出编码员权限、已移交人工：约定第 3 条（全部构建活动结束后人工执行 §F.1 一次并按实测回填 T7，DELIVERY.md:237）与 openQuestion #5（门禁改用 release 模式或独立输出目录，DELIVERY.md:300）。在终局登记完成前，任何按 F.2 执行的安装冒烟装到的都是门禁产物而非登记的 release 交付物。
2. **U6.2 IR-F1（开放 medium，待人工拍板）**：processNormalVideo 登记携带 tabUrl，`/tab-update` 路由按等值 tabUrl 改写 video 表条目名，源 ProcessNormalVideo 不设 TabUrl（DELIVERY.md:195 登记完整证据链：BridgeRoutes.ets:616-619、CapturedVideoTracker.ets:224-227、:448-461）；同面的 F1（`--media-tab-url` 缺 title 仍改名）在 BridgeRoutes.ets:284-290；BridgeRoutes.ets:37-38 头注仍写「F1 延后 U6.3」而 U6.3 报告未接手，属交接漏单。本单元零代码红线未修码，移交人工拍板（改传空串或登记为有意差异），拍板后须同步 D.2、B.2、D.3 三处。
3. **4 处未修 low 文档项**（均不阻塞验收，建议人工验收时一次性修订）：R1-F3（:87 源码锚点应为 app/XDM/XDM.Core/YDLWrapper/YDLProcess.cs）、R1-F4（:61 「+46」宜改「+60」或注明口径）、R3-F1 残留（:236 条目数补「signed 产物口径」注记）、独立复核-4（:264 WARN 句删去「仅为+枚举」，改为引 U7.1 报告 R7 的既有基线口径）。
4. **运行时验收面未完成**：探针会话#2 的 15 项、P2-U2 复验、U0.4 ffmpeg 真机运行 GO（U0.4 报告自述「尚无运行 GO」）、U6.3 真实浏览器实测，均未执行。迁移本体的自动化门禁全绿覆盖不了这些人工环节。
5. **tag 与许可配套**：git tag 为空，待会话#2 通过后人工按 Phase 补打（openQuestion #1）；工程根无 LICENSE 文件，分发链自洽待人工拍板（openQuestion #2）；probe/ 目录整体移除时机待会话#2 完成后拍板（openQuestion #4，现在移除会阻断会话#2）。
6. **环境约束类风险**：compatibleSdk 若被改回 24 会直接破坏真机可装性（README.md:10 与 DELIVERY F.4 已设拦截性提醒）；`devecocli signature generate` 重跑会重写签名配置（DELIVERY F.4 第 2 条）；hvigor 任务完成后客户端进程偶发滞留守护握手（DELIVERY F.1 已登记现象与处置）。

---

## ⑧ 对下个单元的建议

U7.3 是 24 单元中的最后一个编码单元，无后续功能单元。以下建议面向人工验收与会话#2：

1. 终局登记先行：在全部构建活动（含门禁轮）结束后执行 DELIVERY §F.1 一次，按实测回填 T7 四元组与 zip 条目数，然后再做 F.2 安装冒烟，避免验证对象错位（独立复核-5）。
2. 拍板 DELIVERY G 节 5 项 openQuestion：tag 时机、根 LICENSE、HAP 交付形态、probe/ 移除时机、门禁覆写问题的基建收敛（后两项影响会话#2 的执行顺序）。
3. 会话#2 按 C.3 清单执行，P2-U2 复验优先（已修未验的引擎缺陷是唯一登记过的 high 级探针发现）；U0.4 与 U7.1-dash 探针决定 ffmpeg/DASH 面能否给出运行 GO。
4. U6.2 IR-F1 拍板后同步 D.2/B.2/D.3 三处登记；若选择修码，需连带处理同面 F1 与 BridgeRoutes.ets:37-38 的过时头注。
5. 4 处 low 文档项（⑦第 3 条）随人工验收一次性修订，改动均限 DELIVERY.md 单文件。
6. 若后续存在维护轮次：建议把管线统一构建门禁改到独立输出目录或显式 release 模式，从根上消除覆写与登记的时序耦合（openQuestion #5），并补工程根 GPL-2.0 LICENSE 使分发链自洽。

---

## ⑨ 说明：代码未做 git 提交

本单元（含本报告）未做任何 git 提交。本报告员 `git status --short` 实测：tracked 文件零改动，未跟踪新文件为 `README.md`、`docs/delivery/`（含 DELIVERY.md）、`docs/design/u7-3-signing-delivery-DESIGN.md`，加上本报告文件共四处。按 UNIT_CATALOG v2（:19、:100）约定，git 提交与 `git tag phase-N` 由人工执行：待人工验收本报告与 DELIVERY.md 后，由人提交并按 Phase 打 tag；当前 `git tag -l` 为空，DELIVERY A.2 已登记「tag 待人工补打」。
