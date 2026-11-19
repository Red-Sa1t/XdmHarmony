# U0.1 工程基座修正 + 探针基建 · 单元迁移报告

> 单元：U0.1（Phase 0 第 1 项）｜ 报告日期：2026-09-27 ｜ 报告角色：迁移报告员（xdm-migrate 工作流）
> 材料来源：单元指令；`docs/MIGRATION_PLAN.md`；`docs/UNIT_CATALOG.md`；`docs/PROBE_SPEC.md`；设计书 `docs/design/u0-1-foundation-probe-infra-DESIGN.md`；实现摘要（8 文件）；对照审查全史（第 1 轮，approved，5 项发现）；独立复核（acceptable，6 项发现）；门禁结论（主流程脚本执行）。标注"本会话"者为报告员本次亲自执行/核实的证据。
> **总判定**：静态结构断言与 hvigor 编译门禁全部通过（本会话复跑 `devecocli build --modules entry` → exit 0，BUILD SUCCESSFUL）；对照审查 + 独立复核共 11 项发现，**无阻断项**：2 项部分闭环、9 项未处置（代码类 2、防御类 2、文档类 4、流程注记 1，详见④⑦）；**运行时探针验收 OPEN**——探针尚未运行、日志未回贴，待人工按⑥执行。

---

## ① 单元范围与验收要点

### 1.1 范围（8 个文件：4 改 4 新，全部本会话通读核实）

| # | 文件 | 新/改 | 职责 | 关键落点（本会话行号核实） |
|---|---|---|---|---|
| 1 | `entry/src/main/module.json5` | 改 | deviceTypes 补 2in1；补 ohos.permission.INTERNET | `module.json5:7-10`（deviceTypes=["phone","2in1"]）、`:14-18`（requestPermissions 最小项）、`:28`（EntryAbility exported:true 保持） |
| 2 | `entry/src/main/resources/base/element/string.json` | 改 | 追加首批探针 UI 文案键 | `string.json` 现 16 键（既有 3 键保留 + 13 个 `probe_` 前缀中文键），本会话 JSON.parse 通过 |
| 3 | `entry/src/main/ets/probe/core/ProbeKit.ets` | 新 | 探针标记工具（唯一 `[XDM_PROBE]` 出口）：DOMAIN 0xD001/TAG/runId/emit/SUMMARY 聚合/兜底写盘/值消毒 | 常量 `:15-21`；`begin :72-85`、`emit :89-108`、`end :111-134`；行上限截断取 1499（`:100-102`、`:124-126`）；兜底全量重写 `:168-186`；消毒 `:197-203` |
| 4 | `entry/src/main/ets/probe/core/ProbePage.ets` | 新 | 探针页脚手架 @Component：步骤列表+状态徽标+自动运行+重跑/复制+会话编排 | `startSession :60-93`（begin→顺序 await runStep→end(ok)）、`runSingle :95-129`（单步迷你会话预留）、`copyLog :131-139`、Context 取用 `:141-145` |
| 5 | `entry/src/main/ets/probe/units/ProbeEnv.ets` | 新 | P0-U0 环境自检五步骤 S1~S5 | S1 设备形态 `:49-59`、S2 API 版本 `:61-71`、S3 产品系列 `:73-82`、S4 包信息 `:84-97`、S5 写盘自检 `:99-124`（只输出 writeBytes/readBackBytes 观测值） |
| 6 | `entry/src/main/ets/probe/ProbeIndex.ets` | 新 | 探针首页 @Entry：单元注册表 + 页内条件渲染 | `PROBE_UNITS :15-17`（现仅 P0-U0）、`@Entry :19`、列表/详情切换 `:36-87` |
| 7 | `entry/src/main/resources/base/profile/main_pages.json` | 改 | 注册探针首页 | `main_pages.json:2-5` src=["pages/Index","probe/ProbeIndex"] |
| 8 | `entry/src/main/ets/entryability/EntryAbility.ets` | 改 | want 参数路由探针页 | `targetPage/windowStage :33-34`、`onCreate :36-44`（首行解析）、`onNewWant :46-54`（仅显式 page=probe 切页）、`isProbeRoute/resolveTargetPage :83-102`、`loadTarget :104-116` |

### 1.2 明确不做（设计书 §1/§4，本会话核实均成立）

- 不新增 ProbeAbility（采用 EntryAbility + want 参数路由，见③差异 1）；
- `pages/Index.ets` 不改、不 import probe/（本会话 `grep -n "import"` 于该文件 **0 行命中**，零依赖成立）；
- 不建 AppScope 资源、不建 zh_CN/en_US 目录（留 U4.3）、不建 1xx Hypium 测试目录（U0.1 验证级别为 [A]+[H] 冒烟，无 [A] 单测行，UNIT_CATALOG.md:13）；
- 不动 XDM 背景事实对应的 temp 目录与 8597 桥（分别留 U1.1 与 U0.3/U6.1，见②）。

### 1.3 验收要点（UNIT_CATALOG.md:13 U0.1 行 + 单元指令）

| 验收点 | 状态 |
|---|---|
| hvigor 编译通过（零 error、零新 warning） | ✅ 主流程门禁通过；本会话复跑 exit 0（⑤） |
| 模拟器可安装、可启动 | ⏳ 待 [H] 冒烟（⑥） |
| 探针页可经 want 参数拉起并输出 `[XDM_PROBE][P0-U0]` 完整标记序列（BEGIN/S1~S5/SUMMARY/END 共 8 行） | ⏳ 待 [H] 冒烟 + `xdm-probe-verify` 对照期望表判定（⑥） |
| 对照 XDM 源码 | —（脚手架修正，本单元不对照业务源码） |

---

## ② 研究结论摘要（平台行为/工程现状 → ArkTS/配置对应表）

**说明**：本单元不对照 XDM 业务源码（UNIT_CATALOG.md:13 对照源码列 = "—（脚手架修正）"）。研究结论的全部关键事实为鸿蒙平台 API 与工程现状，均已在设计/实现阶段经本机 SDK d.ts 与官方文档核实（研究员材料）；下表"落点"列由报告员逐行复核到当前代码。

| # | 核实点 | 平台/现状事实（研究结论材料） | ArkTS/配置落点（本会话核实） |
|---|---|---|---|
| 1 | 设备形态 | `2in1` 为 deviceTypes 合法枚举（PC 形态） | `module.json5:7-10` = ["phone","2in1"] |
| 2 | 权限声明 | ohos.permission.INTERNET：normal 级、system_grant、起始版本 9；system_grant 的 reason/usedScene 均选填 | `module.json5:14-18` 最小合法项 `{"name":"ohos.permission.INTERNET"}`；本会话剥 1 个既有尾逗号后 JSON.parse 通过 |
| 3 | want 参数路由 | `want.parameters` 为 Record<string,Object>（值仅 String/Number/Boolean 等）；冷启动 onCreate 收 want 后于 onWindowStageCreate loadContent；已后台时 onNewWant 可直接再次 loadContent；`aa start --ps <k> <v>` 注入参数 | `EntryAbility.ets:36-44` onCreate 首行解析；`:46-54` onNewWant 仅显式 `page=probe` 切页（桌面图标暖启动不打断）；`:83-102` `params['page']` 经 `typeof === 'string'` 窄化比较（未用 as 强转 Object） |
| 4 | hilog 契约 | `hilog.info(domain,tag,format,...args)`；domain 0x0~0xFFFF（0xD001 合法）；tag ≤31 字节；`%{public}s` 防 private 脱敏 | `ProbeKit.ets:15-17` 常量 + `:163` 唯一标记出口；非标记诊断行用 tag `XdmProbeKit`/`XdmProbePage`（`:20-21`、ProbePage.ets:28，不含锚子串防 verify 误抓） |
| 5 | 沙箱文件 | `fileIo.openSync(path, OpenMode 位或)` → `writeSync` → `closeSync`；filesDir 由 context 提供 | `ProbeKit.ets:168-186` 每标记行变更即全量重写 `<filesDir>/probe-latest.txt`（中途 jscrash 也留痕）；`ProbeEnv.ets:99-124` S5 写读 `probe-selftest.txt` |
| 6 | 设备信息 | `deviceInfo.deviceType/osFullName/sdkApiVersion/firstApiVersion/marketName` 同步常量、免权限 | `ProbeEnv.ets:49-82` S1~S3 逐字段 emit |
| 7 | 包信息 | `bundleManager.getBundleInfoForSelfSync(GET_BUNDLE_INFO_DEFAULT)` 查自身免权限 | `ProbeEnv.ets:84-97` S4 emit bundleName/versionName/versionCode |
| 8 | 页面注册 | main_pages src 元素相对 src/main/ets；每注册页必须恰一个 @Entry，@Component 子组件不得列入 | `main_pages.json` 恰两项；本会话 `grep -rn "@Entry"` 全工程恰 2 处（pages/Index.ets:16、probe/ProbeIndex.ets:19）；ProbePage/ProbeEnv 均 @Component 未注册 |

**XDM 源码背景两点（研究结论 fact#13，本单元均不落地，仅登记去向）**：
1. `resourses/xdm/app/XDM/XDM.Core/Config.cs:241-248` DataDir/TempDir（不存在则建）→ 鸿蒙侧 `filesDir + '/temp'`，**留 U1.1** 引入 Config 时用 `fileIo.mkdirSync` 首次创建；
2. `resourses/xdm/app/XDM/chrome-extension/connector.js:4` `APP_BASE_URL="http://127.0.0.1:8597"` → **留 U0.3/U6.1** BridgeServer。
（本报告员未改动 resourses/ 下任何文件，仅按约束只读引用。）

---

## ③ 设计决策与有意差异（对照 MIGRATION_PLAN 条款）

### 3.1 计划条款引用

| MIGRATION_PLAN 条款 | 在本单元的落点 |
|---|---|
| §7.1 第 1 项（Phase 0 序列） | 本单元即该项："工程基座修正（deviceTypes 补 2in1、补 ohos.permission.INTERNET）与探针基建（单元 U0.1）" |
| §5 目标工程结构 | EntryAbility/pages 结构保持模板形态；`ets/probe/` 为计划 §5 图之外的基建目录，依据 PROBE_SPEC.md:8-17"探针作为主工程 entry 模块内的探针页"的形态拍板落位 |
| §6 决策 2（TaskPool 线程模型） | 本单元不预置并发：全部主线程 + async/await 串行（设计书 §3.5）；TaskPool/8 并发按计划从 U0.2（ProbeHttp）起引入 |
| §6 决策 11（Navigation/NavDestination + 页面注册） | 业务页路由统一 Navigation/NavDestination 是后续单元约束；本单元按单元指令"main_pages.json 只保留 Index 与探针页"，探针子单元选择用 ProbeIndex 页内条件渲染（ProbeIndex.ets:36-87），不占路由名额 |
| §8 验证矩阵 | 静态检查 = hvigor 编译期 ArkTS 严格子集（主）+ codelinter（辅助）；编译门禁零 error 零新 warning——均已按此执行（⑤） |
| §9.3（工作流门禁） | 每轮返修后全量 hvigor 构建（由主流程脚本统一执行，审查员只读）；代码不自动 git 提交（见⑨） |
| §9.4（探针闭环） | 工作流生成探针页 + PROBE.md + EXPECT 表 → 人工运行回贴 → xdm-probe-verify 判定；本单元产物见⑥ |

### 3.2 有意差异清单（设计书 §4-1..9，含执行状态注记）

| # | 有意差异 | 状态（本会话核实） |
|---|---|---|
| 1 | 不新增 ProbeAbility，按单元指令采用 EntryAbility+want 参数路由（PROBE_SPEC v1 :19/:91 的独立 Ability 方案废弃） | ✅ 已执行；且 PROBE_SPEC.md 已由主流程同步修订：现 `:19` 为"探针页经 EntryAbility want 参数路由拉起"、`:93-94` 命令已改 `aa start -b com.example.xdmharmony -a EntryAbility --ps page probe` |
| 2 | EntryAbility 不 import probe/ 任何文件、路由日志不用 XDM_PROBE 标记（沿用模板 domain 0x0000/testTag） | ✅ 已执行（grep 核实：probe 命中仅注释与路由字符串；`[XDM_PROBE]` hilog 出口仅 ProbeKit.ets:163） |
| 3 | base string.json 新增键值取中文（base 为默认语言；zh_CN/en_US 留 U4.3） | ✅ 已执行（13 键中文） |
| 4 | requestPermissions 取最小合法形，不写 reason/usedScene | ✅ 已执行（module.json5:14-18） |
| 5 | 组件内取 Context 用 `getUIContext().getHostContext()` 替代已弃用 `getContext(this)`，避免新 warning | ✅ 已执行（ProbePage.ets:141-145、ProbeEnv.ets:104-105）；但同一"零弃用 API"规则在 ProbePage.ets:132 的 `createPlainTextData` 上出现例外（独立复核 F1，未处置，见④⑦） |
| 6 | 探针不做 PASS/FAIL 判定；UI 状态徽标只进界面不进日志 | ✅ 已执行（S5 仅输出 writeBytes/readBackBytes，ProbeEnv.ets:117-118；done/error 徽标仅 UI，ProbePage.ets:181-221） |
| 7 | 暖启动仅显式携带 page=probe 时切探针页；"默认仍进 Index"约束冷启动 | ✅ 已执行（EntryAbility.ets:46-54） |
| 8 | 探针单元选择用页内条件渲染而非 Navigation/NavDestination | ✅ 已执行（ProbeIndex.ets:36-87） |
| 9 | 兜底文件每标记行变更即全量重写（非仅 end 时写） | ✅ 已执行（ProbeKit.ets:168-186）；本单元不对照 XDM 业务源码、无新增降级项 |

---

## ④ 审查问题处置表（对照审查第 1 轮 5 项 + 独立复核 6 项，共 11 项，全部覆盖）

> 轮次标注：R1 = 对照审查第 1 轮；IR = 独立复核。"本会话证据"为报告员在当前工作区重新核实的结果。截至本报告，`已修复问题编号` 为空（首轮无返修），下表"处置"列据实记录。

| 编号 | 来源 | 严重度 | 位置 | 问题 | 处置 | 本会话证据 |
|---|---|---|---|---|---|---|
| R1-F1 | R1 | low | ProbeKit.ets:197-199 ↔ PROBE_SPEC §2 白名单 | 消毒替换字符 `?` 不在值白名单 `[A-Za-z0-9_.:/|= -]` 内；若 verify 将来按白名单加严格 value 校验会误判 | **部分闭环**：实现按设计书 §3.2 有意保留；PROBE_SPEC 命令部分已修订，但 **§2 白名单仍未补 `?`**（PROBE_SPEC.md:46 现行无 `?`）→ 文档余项挂起（⑦#4） | ProbeKit.ets:198 现用 `'?'`；本会话正则复现：FORMAT 正则对 `osFullName=??-?` 匹配 **true**（当前无机械影响，与 R1-F1 判断一致） |
| R1-F2 | R1 | low | ProbeKit.ets:58, :162 | 私有字段 `lastLine` write-only 死代码 | **未处置** | 本会话 `grep -rn "lastLine"` 全工程仅 2 处：`:58` 声明、`:162` 写入，零读取点 |
| R1-F3 | R1 | low | DESIGN.md:315（§7 [A]-2） | 设计书笔误："业务页（pages/Index）与 EntryAbility 均 import probe/"漏"不"字，与 §1/§4-2 及实现自相矛盾 | **未处置** | DESIGN.md:315 现文仍为"均 import probe/"；实测实现为零 import（EntryAbility probe 命中仅注释/字符串，pages/Index.ets 零 import 行）——仅文档笔误，实现与 §1/§4-2 一致 |
| R1-F4 | R1 | low | DESIGN.md:115（§3.3 ②） | 设计文示例 `slice(0,1500)` 会产出恰 1500 字节行，违反自身"单行 <1500B"约束；实现取 1499 更严 | **未处置**（实现正确，文档示例误导） | DESIGN.md:115 现文仍为 `slice(0, 1500)`；ProbeKit.ets:100-101/:124-125 实为 `PROBE_LINE_LIMIT - 1` = 1499 |
| R1-F5 | R1 | low（流程） | 验收门禁 | hvigor 构建与 [H] 冒烟按角色约束未由审查员执行，需脚本闭环 | **部分闭环**：构建已由主流程门禁通过（材料）+ 本报告员复跑通过；**冒烟仍待人工**（⑥） | 见⑤.1 |
| IR-F1 | IR | **medium** | ProbePage.ets:132 | 使用 `pasteboard.createPlainTextData`（本机 SDK @ohos.pasteboard.d.ts:239-242 标 @deprecated since 9，@useinstead createData），与设计书 §4-5 自设"零弃用 API/零新 warning"规则自相矛盾；复核建议改 `pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.logText)`（该重载 @since 24 ≤ API 24 可用）并同步修订设计书 §5.2 | **未处置（本单元最重遗留）** | 本会话 grep：全工程仅 ProbePage.ets:132 一处 `createPlainTextData`；构建门禁通过、codelinter 无 deprecation 告警（⑤.2）——当前不阻断，但属设计一致性/向前兼容风险，建议 U0.2 开工前随手修（⑦#1、⑧） |
| IR-F2 | IR | low | ProbeKit.ets:58, :162 | 同 R1-F2（lastLine 死代码），复核确认仍未落地 | **未处置** | 同 R1-F2 证据 |
| IR-F3 | IR | low | DESIGN.md:315 | 同 R1-F3（设计书笔误仍未修订）；复核 grep 实测实现与 §1/§4-2 一致 | **未处置** | 同 R1-F3 证据 |
| IR-F4 | IR | low | ProbeKit.ets:99（emit 空 kvs）、:116-127（end 零 summaries） | 脚手架级 footgun：空 kvs 产出 `[XDM_PROBE][U][Sx] `（尾空格）、零 summaries 产出 `[SUMMARY] `，均不满足 verify 正则（`\s` 后需 ≥1 字符）。U0.1 各步骤所有路径 kvs ≥1（ProbeEnv.ets:52-56/64-68/76-80/87-94，且 S5 在 try 前先推 probeFile `:102`），**当前不可达**；将来任何单元某步空观测即触发 verify FORMAT-ERROR 噪音 | **未处置**（防御缺口，U0.1 不可达；建议 U0.2 前加守卫，见⑧） | 本会话 node 复现：`emptyEmit(kvs=[])` → NOMATCH(false)；`emptySummary(summaries=[])` → NOMATCH(false)；正常行 → MATCH(true)，与 IR-F4 结论一致 |
| IR-F5 | IR | low | ProbeKit.ets:72-85 + ProbePage.ets:61-93 | 并发隐患：ProbeKit 单例 begin() 无条件重置、编排循环无会话代际校验。将来 U0.2 引入真异步步骤 + 暖启动整页重建（新 ProbePage aboutToAppear 自动 begin）时，旧异步循环会串话/提前终结新会话。U0.1 全同步执行（单微任务排空）**不可达** | **未处置**（列为 U0.2 前置改造，见⑧） | 本会话复读：begin 无条件重置状态（ProbeKit.ets:73-80）确认；startSession/runSingle 无 runId 比对确认 |
| IR-F6 | IR | low | DESIGN.md:301（§6 S4 行） | 设计书称 getBundleInfoForSelfSync "API 10+"，本机 SDK d.ts 实标 @since 20；无运行期风险（compatibleSdkVersion=6.1.1(24) 钉死 ≥24≥20），属文档标注失真 | **未处置**（文档项） | DESIGN.md:301 现文仍为"API 10+" |

**处置统计**：已完全闭环 0 ｜ 部分闭环 2（R1-F1 的 SPEC 命令部分、R1-F5 的构建部分）｜ 未处置 9（medium 1：IR-F1；其余 low：文档类 4 项含 R1-F3/R1-F4/IR-F6/R1-F1 余项、代码类 1 项 IR-F2、防御类 2 项 IR-F4/IR-F5、流程注记 1 项 R1-F5 余项）。无阻断验收的发现。

---

## ⑤ 验证情况

### 5.1 hvigor 编译门禁 ✅

- **主流程门禁（材料，非本报告员执行）**：`devecocli build --modules entry` → 最终状态**通过**。
- **本报告员复跑（本会话）**：`cd D:/git/HarmonyPC/XdmHarmony && devecocli build --modules entry` → **exit 0，BUILD SUCCESSFUL in 5 min 22 s 11 ms**。全程唯一 WARN：`Will skip sign 'hos_hap'. No signingConfigs profile is configured`——模拟器免签名的既有基线告警（研究阶段基线同样存在），非代码告警。
- 诚实注记：本次复跑为**增量构建**（CompileArkTS 等 task UP-TO-DATE），未重新产出 ArkTS 编译诊断；"零 error、零新 warning"的权威证据是主流程门禁轮的全量构建结论。两者共同证明当前工作区可构建。

### 5.2 codelinter 辅助检查 ✅（提示性）

- 门禁轮 codelinter exit 0；输出显示唯一告警：`ProbeEnv.ets` 1 Warning —— `@performance/avoid-overusing-custom-component-check`（建议优先用 @Builder 代替自定义组件）。该告警指向 ProbePage 子组件用法：ProbePage 持有 @State 必须为组件，属**建议级**而非 hvigor 构建告警，按设计保留（实现摘要已登记）。
- 实现阶段逐文件 `devecocli check lint`（实现摘要材料）：ProbeKit/ProbePage/ProbeEntryAbility 等中 3 文件零缺陷、ProbeIndex 初报 1 条 `hp-arkui-no-state-var-access-in-loop` 已修复归零、ProbeEnv 1 条性能建议保留。

### 5.3 本会话结构断言（全部亲自执行）

| 断言 | 命令（摘要） | 结果 |
|---|---|---|
| @Entry 唯一性 | `grep -rn "@Entry" entry/src/main/ets` | 恰 2 处：pages/Index.ets:16、probe/ProbeIndex.ets:19（另 1 处为 ProbeIndex.ets:2 注释） |
| 业务页零 probe 依赖 | `grep -n "import" pages/Index.ets` | 0 行（零 import） |
| EntryAbility 不 import probe/ | `grep -n "probe" entryability/EntryAbility.ets` | 命中均为注释与路由字符串（'probe/ProbeIndex'、page=probe），无 import 语句 |
| 标记唯一出口 | grep XDM_PROBE / hilog 核对 | hilog 携 PROBE_TAG 仅 ProbeKit.ets:163；其余文件命中为注释；诊断行 tag XdmProbeKit/XdmProbePage 不含锚子串 |
| 死代码定位 | `grep -rn "lastLine" entry/src/main/ets` | 仅 ProbeKit.ets:58/:162（佐证 R1-F2/IR-F2） |
| 弃用 API 定位 | `grep -rn "createPlainTextData\|createData(" entry/src/main/ets` | 仅 ProbePage.ets:132 createPlainTextData（佐证 IR-F1） |
| main_pages.json 合法性 | `node JSON.parse` | OK，src=["pages/Index","probe/ProbeIndex"] |
| string.json 合法性 | `node JSON.parse` | OK，16 键（13 个 probe_ 前缀） |
| module.json5 JSON5 合法性 | 剥 1 个尾逗号后 `node JSON.parse` | OK；deviceTypes=["phone","2in1"]、requestPermissions=[{"name":"ohos.permission.INTERNET"}]、exported=true |
| EXPECT 期望表合法性 | `node JSON.parse` | OK，unitId=P0-U0、8 步骤 |
| verify 正则边界 | node 正则复现 | 空 emit 行/空 SUMMARY 行 NOMATCH（IR-F4 成立）；`?` 值 MATCH（R1-F1 当前无机械影响）；正常行 MATCH |

### 5.4 对照审查与独立复核结论（材料）

- 对照审查第 1 轮：**approved**（5 项发现全为 low，见④）。
- 独立复核：**acceptable = true**（6 项发现：medium 1 + low 5；weakestSpot 指向 ProbeKit 单例会话生命周期 IR-F5 与弃用 API IR-F1）。

### 5.5 未执行/不可用项

- `devecocli check compat`：**不可用**——本机 DevEco 6.1.1.300 低于所需 26.0.0.810（实现摘要材料；本报告员未复跑）。
- [H] 真机/模拟器冒烟与探针运行：**未执行**（属人工待办，见⑥）。
- Hypium 单测：本单元按 UNIT_CATALOG 验证级别无 [A] 单测行，未建用例（有意不做，见①.2）。

### 5.6 ArkTS 合规说明

ArkTS 严格子集**由 hvigor 编译期强制**（codelinter 不含 ArkTS 语法规则）——本单元编译门禁通过即为合规依据。编码期按 arkts-grammar-standards 技能自查的关键点在代码中可见：无 any/解构/构造器参数属性；正则一律 `new RegExp`（ProbeKit.ets:31-33）；静态单例方法用类名引用 `ProbeKit.instance`（:64-68）；async 方法显式 `Promise<void>`（ProbePage.ets:61/:96、ProbeEnv.ets:25）；`Record` 下标访问 + `typeof` 窄化（EntryAbility.ets:85-90）；对象字面量带类型上下文（ProbeEnv.ets:15-21 步骤表）。

### 5.7 git 状态（本会话核实）

`git -C XdmHarmony status --porcelain`：`M` EntryAbility.ets、module.json5、string.json、main_pages.json；`??` entry/src/main/ets/probe/。仓库仅 1 个 commit（`8e7cc57 Initial commit`），**无任何 tag**——本单元改动全部未提交（⑨）。

---

## ⑥ 运行时验证待办（探针运行指引）

**状态：探针 P0-U0 尚未运行、日志未回贴。本单元运行时验收 OPEN。**

- 探针手册：`XdmHarmony/docs/probe/PROBE-u0-1-foundation-probe-infra.md`（含修订后的命令口径、8 行预期序列、路由行为 4 场景验收表）
- 机器可读期望表：`XdmHarmony/docs/probe/EXPECT-u0-1-foundation-probe-infra.json`（unitId=P0-U0，8 步骤，本会话解析通过）

人工执行要点（详见 PROBE 手册 §1~§3）：

1. 模拟器免签名可直接推包；真机需一次性 `devecocli auth login` + `devecocli signature generate --product default`。
2. 构建+安装+拉起默认页：`devecocli run --module entry`（验证无参冷启动落 pages/Index 的回归路径）。
3. 路由探针首页：`hdc shell "aa start -b com.example.xdmharmony -a EntryAbility --ps page probe"`（`devecocli run` 无法携带 want 参数，勿用其替代）。
4. 点击探针首页卡片「环境自检（P0-U0）」→ 进入自动运行 S1~S5（唯一人工动作；可选点「复制日志」留证）。
5. 抓取：`hdc shell "hilog -x | grep XDM_PROBE" > probe-P0-U0.log`；兜底 `cat <filesDir>/probe-latest.txt`；自检产物 `cat <filesDir>/probe-selftest.txt`。
6. 冒烟 4 场景（PROBE 手册 §5）：冷启动带参直进探针页 / 暖启动带参经 onNewWant 切页 / 桌面图标暖启动保持当前页 / 无参冷启动落 Index。
7. 将 `probe-P0-U0.log` 原文回贴，由 `xdm-probe-verify` 对照 EXPECT 表逐步骤判定 PASS/FAIL/UNVERIFIED/MISSING 并分流返修。

预期 8 行序列：`[BEGIN]`（runId=HHmmss、filesDir）+ S1 deviceType/osFullName + S2 sdkApiVersion/firstApiVersion + S3 marketName + S4 bundleName/versionName/versionCode + S5 probeFile/writeBytes/readBackBytes（两值相等由 verify 比对，探针不输出 match/differs）+ `[SUMMARY]`（5 段聚合，<1500B）+ `[END] ok=… steps=5 elapsedMs=…`。

---

## ⑦ 遗留问题与风险

1. **IR-F1（medium，最重遗留）**：ProbePage.ets:132 弃用 API `pasteboard.createPlainTextData`（@deprecated since 9）。当前构建/codelinter 均未因此报错（⑤），不阻断本单元验收，但违反设计书 §4-5 自设的"零弃用 API"一致性规则且有向前兼容风险。**建议 U0.2 开工前修复**：改 `pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.logText)`（本 SDK 重载 @since 24 ≤ API 24 可用），后续单元统一 createData，并同步修订设计书 §5.2。
2. **R1-F2/IR-F2（low）**：ProbeKit.ets:58/:162 `lastLine` 死代码，随手删除或补 getLastLine() 访问器。
3. **设计文档三处笔误未修订（low，误导走查）**：DESIGN.md:315（"均 import probe/"漏"不"）、:115（`slice(0,1500)` 应为 `slice(0, PROBE_LINE_LIMIT - 1)`）、:301（"API 10+"应为 @since 20）。实现本身正确。
4. **R1-F1 余项（low）**：PROBE_SPEC.md:46 §2 值白名单仍未补 `?`（或把替换字符改 `_`）。当前 verify FORMAT 正则不校验 value 字符集（本会话复现 MATCH），无机械影响；将来 verify 若加严格 value 校验会把含 CJK 的消毒行误判 FORMAT-ERROR。另：PROBE_SPEC.md:94 模板命令为不带引号形式（`hdc shell aa start ...`），与 PROBE 手册 ：41 的带引号形式（`hdc shell "aa start ..."`）并存——以带引号形式为准。
5. **IR-F4（low，U0.1 不可达）**：emit 空 kvs / end 零 summaries 会产出 NOMATCH 行。U0.1 各步骤所有路径 kvs ≥1；U0.2 起需在 ProbeKit 加守卫（空时补计数 kv 或不留尾空格）。
6. **IR-F5（low，U0.1 不可达，U0.2 变活）**：ProbeKit 单例会话无代际校验；U0.2 引入真异步步骤 + 暖启动整页重建后可能串话/提前 END。U0.2 开工前必须加会话令牌（begin 返回 runId，编排循环每次 emit/end 前比对）。
7. **真机签名**：真机冒烟前置一次性 auth login + signature generate（模拟器免签）；构建 WARN "No signingConfigs" 在配置签名材料后消失。
8. **计划内挂起项**：zh_CN/en_US 资源目录（U4.3）；XDM temp 目录约定 Config.cs:241-248（U1.1）；8597 常量 connector.js:4（U0.3/U6.1）；探针交付前整体移除 `entry/src/main/ets/probe/`（U7.3，PROBE_SPEC §1 既有约定）；PROBE_SPEC 手册模板的期望表按单元生成（后续单元沿用本单元 PROBE/EXPECT 文件形态）。

---

## ⑧ 对下个单元（U0.2 HTTP 能力探针）的建议

1. **开工前半小时级小修清单（本单元遗留，勿带进 U0.2）**：createData 替换（IR-F1）→ lastLine 删除（IR-F2）→ 设计书三处笔误（⑦#3）→ PROBE_SPEC 白名单 `?` 决策（⑦#4）。
2. **会话基建两处防御先做再写 ProbeHttp**：① ProbeKit/ProbePage 会话代际校验（IR-F5，U0.2 真异步后变活）；② emit 空 kvs 守卫（IR-F4，U0.2 步骤可能出现空观测）。
3. **并发引入**：TaskPool/8 并发按 MIGRATION_PLAN §6 决策 2 与设计书 §3.5 从 U0.2 起引入；requestInStream 的 `dataReceive` 事件流替代阻塞读（计划 §6 决策 2）。
4. **网络前置已就绪**：INTERNET 权限本单元已入 module.json5:14-18；测试源必须支持 Range（`npx http-server`，Python SimpleHTTPServer 不支持——MIGRATION_PLAN §7 Phase 2 注记同样适用 P0-U2 的 206 判定）；模拟器访问主机测试源用主机局域网 IP + 绑 0.0.0.0（PROBE_SPEC §3 注意事项）。
5. **探针工程惯例沿用本单元**：PROBE 手册命令一律 `hdc shell "aa start -b com.example.xdmharmony -a EntryAbility --ps page probe"`（带引号）；大段数据（全量响应头）写 `files/probe-<unit>-<runId>.txt` 只记 `detailFile=`（PROBE_SPEC.md:48），不塞单行；autoRun=false 的步骤用 ProbePage 已预留的 runSingle 单步按钮（ProbePage.ets:95-129，如"复制文本到剪贴板"类人工步骤）。
6. **结论回写**：U0.2 的"http 还是 rcp"结论须回写 MIGRATION_PLAN（UNIT_CATALOG.md:14 验收要求），复用本单元 P0-U0 的 deviceType/API 观测值做环境标注。

---

## ⑨ git 提交说明

**本单元代码未做 git 提交**：`git status --porcelain` 显示 4 个修改文件（EntryAbility.ets、module.json5、string.json、main_pages.json）+ 新增 `entry/src/main/ets/probe/` 目录，全部处于未暂存/未跟踪状态；仓库当前仅 `8e7cc57 Initial commit`、无 tag（本会话核实）。按 MIGRATION_PLAN §9.3（"代码不自动 git 提交，人工验收后提交"）与 §9.5（每 Phase 验收通过后 `git tag phase-N`）：待人工完成⑥的探针回贴判定并通过验收后，由人工提交并按 Phase 0 打 `phase-0` tag。`resourses/xdm` 对照源码全程只读，未做任何改动。
