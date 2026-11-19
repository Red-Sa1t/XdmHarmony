# U0.1 工程基座修正 + 探针基建 · 模块设计书

> 单元：U0.1（Phase 0）。来源：xdm-migrate 工作流"模块设计师"角色，2026-09-27。
> 依据：MIGRATION_PLAN §5/§6/§7.1、UNIT_CATALOG U0.1 行、PROBE_SPEC v1、单元指令（U0.1 四项内容 + 补充约束）。
> 本单元**不对照 XDM 业务源码**（UNIT_CATALOG U0.1 对照源码列为"—（脚手架修正）"）；源码研究结论中的 Config.cs / connector.js 事实仅作后续单元背景，本单元不落地。
> 基线：研究阶段实测未改动工程 `devecocli build` = BUILD SUCCESSFUL（exit 0，无 signingConfigs 警告系模拟器免签名所致）。

## 0. 文档冲突拍板注记（必读）

PROBE_SPEC.md:19（"module.json5 注册 `ProbeAbility`（exported: true…）"）与 :91（手册命令 `devecocli run --module entry --ability ProbeAbility`）是 v1 的**独立 ProbeAbility 方案**，与单元指令的 **EntryAbility + want 参数路由**方案冲突。**本设计按单元指令实现**：单一 UIAbility（EntryAbility），不新增 ProbeAbility；探针拉起走 `page=probe` want 参数（devecocli run 无法携带 want 参数）。PROBE_SPEC.md 两处及 §3 手册模板 §2 的命令需由主流程在 U0.1 验收后统一修订为：

```
hdc shell "aa start -b com.example.xdmharmony -a EntryAbility --ps page probe"
```

此文档修订**不属于本单元 files**（目标落点未含 PROBE_SPEC.md），但必须执行，否则后续 `xdm-migrate` 生成 PROBE-*.md 会复用错误命令。

---

## 1. 目标文件清单（按实现顺序）

| # | 文件 | 新/改 | 职责 | 对外导出 | 依赖 |
|---|---|---|---|---|---|
| 1 | `entry/src/main/module.json5` | 改 | 设备形态补 `2in1`；补 `ohos.permission.INTERNET`（U0.2/U0.3 网络探针前置） | —（配置） | 无 |
| 2 | `entry/src/main/resources/base/element/string.json` | 改 | 追加 `probe_` 前缀探针 UI 文案键（首批业务文案键）；既有 3 键不动 | —（资源） | 无 |
| 3 | `entry/src/main/ets/probe/core/ProbeKit.ets` | 新 | 探针标记工具（唯一日志出口）：DOMAIN/TAG 常量、runId 生成、`emit(step,kvs)`、SUMMARY 聚合与 1500B 降级、写沙箱 `files/probe-latest.txt` 兜底、值白名单消毒 | `ProbeKit`（单例类）、`KeyValue`、`PROBE_DOMAIN`、`PROBE_TAG`、状态常量 | 无 |
| 4 | `entry/src/main/ets/probe/core/ProbePage.ets` | 新 | 通用探针页脚手架 @Component：步骤列表 + 自动运行 + 重跑/单步手动按钮 + 复制日志 + 标记行回显；持有 BEGIN→步骤→SUMMARY→END 会话编排 | `ProbePage`（struct）、`ProbeStepDef`（interface） | #3、#2（$r 文案） |
| 5 | `entry/src/main/ets/probe/units/ProbeEnv.ets` | 新 | P0-U0 环境自检探针 @Component：定义 S1~S5 步骤与 runner（deviceInfo/bundleManager/写盘自检），嵌入 ProbePage | `ProbeEnv`（struct） | #3、#4 |
| 6 | `entry/src/main/ets/probe/ProbeIndex.ets` | 新 | 探针首页 @Entry：探针单元注册表列表，点击进入对应单元视图（页内条件渲染），带返回 | —（@Entry 页） | #5、#2 |
| 7 | `entry/src/main/resources/base/profile/main_pages.json` | 改 | 注册 `probe/ProbeIndex`（`loadContent('probe/ProbeIndex')` 成功的前提） | —（配置） | #6 |
| 8 | `entry/src/main/ets/entryability/EntryAbility.ets` | 改 | want 参数路由探针页：onCreate/onNewWant 读 `want.parameters.page`，冷启动按 targetPage loadContent，暖启动显式 `page=probe` 时切页 | —（默认导出 UIAbility，签名不变） | #7（运行期路由目标须已注册） |

明确**不做**的文件：不新增 ProbeAbility（见 §0）；`pages/Index.ets` 不改（业务页禁止 import probe/，保持互不依赖）；不建 AppScope 资源（应用名 app_name 在 AppScope，本单元不动）；zh_CN/en_US 资源目录留到 U4.3；不建 1xx 测试目录（本单元无 Hypium 用例要求，见 §5）。

---

## 2. 数据模型与表结构（对照源码核对）

### 2.1 业务表结构：无

本单元无 RelationalStore 表、无 preferences、无网络协议数据结构。逐一对照核对结论：

- UNIT_CATALOG U0.1 对照源码 = "—（脚手架修正）"，无 XDM 源码行为需翻译成存储结构。
- 研究结论 fact#13 两点均为**后续单元背景**，本单元不实现：① XDM `Config.cs:241-248` DataDir=`~/.xdm-app-data/Data`、TempDir=Data/temp（不存在则建）→ 对应鸿蒙侧 `filesDir + '/temp'`，留给 U1.1 引入 Config 时用 `fileIo.mkdirSync` 首次创建；② `chrome-extension/connector.js:4` `APP_BASE_URL="http://127.0.0.1:8597"` → 留给 U0.3/U6.1 BridgeServer。本单元探针只写 `filesDir/probe-latest.txt` 与 `filesDir/probe-selftest.txt`，不动 temp 目录。
- 探针文件名 `probe-latest.txt` 是 PROBE_SPEC §1/§5 的约定（非 XDM 源码），`xdm-probe-verify` 与 PROBE 手册 §3 的兜底抓取命令都引用它，**不得改名**。

### 2.2 ProbeKit 数据模型（probe/core/ProbeKit.ets）

| 类型 | 字段 | 说明 |
|---|---|---|
| `export class KeyValue` | `key: string`、`value: string`（显式字段 + 构造体内赋值；**禁止构造函数参数属性** `constructor(public key…)`，ArkTS 禁用） | 有序键值对。**不用 `Record<string,string>`**：SUMMARY 聚合依赖插入序、ArkTS 禁 `for...in`，对象字面量还需带类型上下文，数组最直白 |
| `export class ProbeKit`（单例） | `private unitId: string`、`private runId: string`、`private started: boolean`、`private startTick: number`（Date.now()）、`private stepCount: number`、`private lines: string[]`（本次运行全部标记行）、`private summaries: string[]`（`S<no>=<段>`，emit 顺序）、`private lastLine: string` | 运行状态机 idle→running→ended（§3.4）。单例理由：一屏同时只有一个探针会话，且 ProbePage（编排）与 ProbeEnv（步骤实现）需共享同一会话 |

### 2.3 ProbePage 数据模型（probe/core/ProbePage.ets）

| 类型 | 字段 | 说明 |
|---|---|---|
| `export interface ProbeStepDef` | `stepNo: string`（'S1'…）、`title: ResourceStr`、`autoRun: boolean` | 步骤定义。interface 仅供本文件与 units/ 使用，从 ProbePage.ets 导出统一声明（"共享类型一处声明"规则） |
| 步骤状态 | 字符串常量 `PROBE_STATUS_PENDING/​RUNNING/​DONE/​ERROR` = `'pending'/'running'/'done'/'error'`，存于 `@State statuses: string[]`（与 steps 等长、按下标并行） | @State 数组按下标赋值可触发刷新，无需 @Observed/@ObjectLink；**状态只是执行事实（执行出错≠PASS/FAIL 判定），日志里不出现这些词** |
| 会话状态 | `@State logText: string`（标记行回显）、`@State sessionRunning: boolean`、`private sessionStarted: boolean`（防自动运行重复） | |
| Props（父组件经构造传入） | `unitId: string`、`pageTitle: ResourceStr`、`steps: ProbeStepDef[]`、`autoStart: boolean = true`、`runStep: (stepNo: string) => Promise<void>`（带默认空实现） | steps/runStep 为静态 prop（每单元固定），不需要响应式装饰 |

### 2.4 配置文件数据模型（三份，改动前后）

**module.json5**（现状：`deviceTypes` 仅 `["phone"]`（:7-9），全文件无 `requestPermissions`；EntryAbility `exported: true`（:22）——`aa start` 要求目标组件非 exported:false，满足）：

| 键 | 现值 | 新值 | 依据 |
|---|---|---|---|
| `module.deviceTypes` | `["phone"]` | `["phone", "2in1"]` | 单元指令固定值；`2in1` 是合法枚举（PC 形态） |
| `module.requestPermissions` | （无此键） | `[{"name": "ohos.permission.INTERNET"}]` | INTERNET 为 normal 级、system_grant——**reason/usedScene 均选填**，最小合法项即只写 name；插入位置放 `"pages"` 键之后（模块对象内键序不限，保持 JSON5 合法） |

其余键（abilities/skills/extensionAbilities，含既有尾逗号——JSON5 允许）一律不动。

**main_pages.json**：`src` 由 `["pages/Index"]` 改为 `["pages/Index", "probe/ProbeIndex"]`。src 元素为相对 `src/main/ets` 的路径；每个注册页必须恰好一个 @Entry，`core/ProbePage.ets` 与 `units/ProbeEnv.ets` 是 @Component 子组件，**不得列入**。

**string.json**：既有 3 键（module_desc / EntryAbility_desc / EntryAbility_label，被 module.json5 `$string:` 引用，缺失会打包失败）**保留不动**；追加首批探针 UI 键（命名统一 `probe_` 前缀，纯 JSON、无尾逗号）：

| 键 | 值（base，默认中文） | 用途 |
|---|---|---|
| `probe_index_title` | `XDM 迁移探针` | 探针首页标题 |
| `probe_index_empty` | `暂无探针单元` | 单元列表空态 |
| `probe_env_title` | `环境自检（P0-U0）` | P0-U0 页标题 |
| `probe_run_all` | `运行全部` | 会话启动按钮 |
| `probe_rerun` | `重跑` | 重跑按钮 |
| `probe_step_run` | `执行` | 单步手动按钮（autoRun=false 步骤行） |
| `probe_copy_log` | `复制日志` | 复制按钮 |
| `probe_copied` | `已复制` | 复制成功提示 |
| `probe_back` | `返回` | 返回单元列表 |
| `probe_status_pending` | `待运行` | 状态徽标 |
| `probe_status_running` | `运行中` | 状态徽标 |
| `probe_status_done` | `已完成` | 状态徽标 |
| `probe_status_error` | `出错` | 状态徽标（UI 事实，非判定） |

base 取中文值为有意决策（见 §4-3）；U4.3 再补 en_US 目录。

---

## 3. 关键算法与状态机翻译说明

本单元无 XDM 数学算法（分段/偏移/限速）需翻译——那些在 U2.1~U3.2。这里的"算法"是探针标记契约（PROBE_SPEC §2）与路由状态机的机械实现：

### 3.1 runId 生成与时钟

`fmtClock(): string` —— 纯函数：`new Date()` → 时/分/秒各 `String(n).padStart(2, '0')` → `HHmmss`（如 `142533`）。同秒重跑 runId 撞号的风险由"BEGIN/END 配对 + verify 取最后 runId"契约吸收（PROBE_SPEC §5），不引入毫秒/随机数。

### 3.2 字符消毒（白名单强制）

- `sanitizeValue(v: string): string` —— 把白名单 `[A-Za-z0-9_.:/|=-]` 与空格之外的字符逐个替换为 `'?'`。实现用 `const VALUE_BAD: RegExp = new RegExp('[^A-Za-z0-9_.:/|= -]', 'g')`（**正则字面量被 ArkTS 禁用，必须 new RegExp；且 `'-'` 必须是字符类最后一个字面字符**，写成 `[^...=/- ]` 会把 `=- ` 当成非法区间，运行期 SyntaxError）。
- `sanitizeToken(t: string): string` —— 单元 ID/步骤号用更严白名单 `[A-Za-z0-9-]`，违规字符**删除**（verify 正则 `\[([A-Z0-9-]+)\]\[([A-Za-z0-9-]+)\]` 的硬约束）。
- 消毒后标记行全 ASCII ⇒ `string.length` 即字节数，1500B 校验直接用 `.length`。含空格/CJK 的值（如 marketName）被消毒成 `'?'` 序列是接受的观测损失；更完整的值将来可走"大段数据写文件 + detailFile= 文件名"通道（PROBE_SPEC §2）。

### 3.3 emit 与 SUMMARY 折叠

- `emit(stepNo: string, kvs: KeyValue[]): string`：拼 `[XDM_PROBE][<unitId>][<stepNo>] ` + `k=v` 空格连接 → hilog 单行输出 + 追加 `lines` + 记录 summary 段（`stepNo + '=' + kvs.map(kv => kv.key + '=' + kv.value).join(',')`，段内 `'|'` 替换为 `'/'`，因 `'|'` 是 SUMMARY 对间分隔符）+ 每步重写兜底文件。**不做任何 PASS/FAIL 判定**（规范红线）。
- `end(ok: boolean): string`：先拼 SUMMARY 行 `[SUMMARY] S1=…|S2=…|…`，字节数三级降级：① 超长 → 每段只保留首个 kv；② 仍超长 → `slice(0, PROBE_LINE_LIMIT - 1)` 硬截断（保证单行 < 1500B）；③ 再拼 `[END] ok=<true|false> steps=<n> elapsedMs=<ms>`（elapsedMs = Date.now() − startTick；steps = stepCount）。SUMMARY 行、END 行同样进 `lines` 并触发兜底文件重写。P0-U0 全量约 9 行、SUMMARY ≈250B，远低于 1500B。
- **兜底文件策略：每次标记行变更即全量重写** `filesDir/probe-latest.txt`（`openSync(path, fileIo.OpenMode.READ_WRITE | CREATE | TRUNC)` → `writeSync(fd, lines.join('\n') + '\n')` → `closeSync(file)`），而非仅在 end 时写——探针中途 jscrash 也能留下已产出行。探测数据量 KB 级，同步 fileIo 不构成可感知阻塞。

### 3.4 会话/路由状态机

**ProbeKit 会话**：`begin(unitId, filesDir)`（重置 lines/summaries/stepCount，生成 runId，emit BEGIN 行 `runId=<HHmmss> filesDir=<路径>`）→ 任意次 `emit` → `end(ok)`。`begin` 后未 `end` 又 `begin`：视为新一轮，直接重置（探针重跑语义）；未 begin 就 emit：忽略该行并走普通 hilog 输出（不产出畸标记行）。

**EntryAbility 路由**（两分支，均已核实官方语义：冷启动在 onCreate 收 want 后于 onWindowStageCreate loadContent；应用已在后台时 onNewWant 里可直接再次 loadContent）：

```
冷启动: onCreate(want) ── resolveTargetPage(want)──▶ targetPage='probe/ProbeIndex' | 'pages/Index'
        onWindowStageCreate ── 存 windowStage 引用 ──▶ loadContent(this.targetPage)
暖启动: onNewWant(want) ── want 显式携带 page=probe ?──是──▶ targetPage='probe/ProbeIndex'
                                            │            windowStage.loadContent(targetPage)
                                            └──否──▶ 不切页（保持当前页；桌面图标暖启动不打断用户）
```

参数解析：`want.parameters` 类型 `Record<string, Object>`（值仅 String/Number/Boolean/Object/undefined/null），取键用 `params['page']`（Record 允许下标访问；**非 Record 对象禁下标访问**），以 `typeof page === 'string'` 窄化后与 `'probe'` 比较——不 `as` 强转不窄化的 `Object`。**EntryAbility 的路由决策日志用普通 hilog（沿用模板 domain 0x0000、tag 'testTag'），绝不输出 `[XDM_PROBE]` 行**——否则 verify 会把它当未配对的 P0-U0 标记行报 FORMAT-ERROR。

**页面级会话编排（ProbePage.startSession，async 串行）**：守卫 sessionRunning → `probeKit.begin(unitId, filesDir)`（filesDir 取 `this.getUIContext().getHostContext()?.filesDir ?? ''`，为空串时 BEGIN 照发、跳过兜底写盘）→ 按 steps 顺序逐个 `await this.runStep(stepNo)`（autoRun=false 的步骤同样在会话内由 runner 自行等待人工动作；单步按钮另述）→ 成功 statuses[i]='done'，runner 抛错则 'error' 且 ok=false → `probeKit.end(ok)` → 刷新 logText。**runner 契约：内部捕获 BusinessError 并 emit `err=`/`errCode=` 观测值，不向外抛**——`ok=false` 只留给脚手架级意外异常；步骤失败的事实由 err= 键呈现，判定交给 verify 对照期望表。

### 3.5 线程模型映射

- 全部主线程 + async/await **串行**执行；步骤间无并发、无 TaskPool。理由：探针单步骤是"调 API → 读字段 → 拼行"，毫秒级；MIGRATION_PLAN 决策 2 的 TaskPool/8 并发从 U0.2（ProbeHttp）起才引入，基建不预置。
- 同步 fileIo（openSync/writeSync/closeSync/readTextSync）在此数据量下使用是安全的；将来大数据探针才需要异步 fs 或 TaskPool。
- `startSession()` 为 `async` 方法，**必须显式标注返回类型 `Promise<void>`**（ArkTS 强制）；aboutToAppear 内调用不 await（fire-and-forget，事件循环自行推进）。

### 3.6 纯函数拆分（供将来单测，本单元不建用例）

`fmtClock` / `sanitizeValue` / `sanitizeToken` / SUMMARY 折叠逻辑设计为 ProbeKit 的私有纯函数（入参出参全为 string/number，无 IO）。本单元无分段/偏移/限速数学，**不要求 Hypium 用例**（UNIT_CATALOG U0.1 验证=[A]+[H]冒烟，无 [A] 单测行）；这些函数的期望行为已由探针一次运行 + verify 正则机械覆盖。若后续想补测，用例名为：fmtClock 补零、sanitizeValue 白名单外字符、sanitizeToken 剔除非法字符、SUMMARY 1500B 三级降级。

---

## 4. 与源码/既有文档的有意差异清单

1. **不新增 ProbeAbility**（与 PROBE_SPEC.md:19/:91 的 v1 方案有意不一致）：按单元指令采用 EntryAbility + want 参数路由；PROBE_SPEC 两处及 §3 手册命令需主流程验收后修订（见 §0）。
2. **EntryAbility 路由日志不用探针标记**：模板日志保持 domain 0x0000/tag testTag；ProbeKit 是唯一 `[XDM_PROBE]` 出口，EntryAbility 不 import probe/（业务与探针互不依赖的审查规则）。
3. **base string.json 新增键值为中文**：工程模板既有键是英文，探针 UI 直接面向中文验收人，base 作为默认语言取中文；zh_CN/en_US 目录按计划留 U4.3。
4. **requestPermissions 最小形**：`{"name": "ohos.permission.INTERNET"}` 不带 reason/usedScene（system_grant 权限两者选填，官方文档已核）。
5. **弃用 API 替换**：取 Context 不用 `getContext(this)`（SDK `component/common.d.ts:1711` 标注 @deprecated since 18，API 24 上会引入新 warning，违反"零新 warning"门禁），改用 `this.getUIContext().getHostContext()`（`@ohos.arkui.UIContext.d.ts:4757`，since 12，返回 `Context | undefined`，需 `?? ''` 窄化）。
6. **探针不做判定，UI 状态词只进界面不进日志**：'done'/'error' 仅是执行事实徽标；S5 写盘自检不输出 match/mismatch 判定词，只输出 `writeBytes`/`readBackBytes` 观测值，比对交给 verify。
7. **暖启动不带 page 参数不切回 Index**：单元指令"默认仍进 Index"在冷启动生效；暖启动仅在显式 `page=probe` 时切探针页，桌面图标暖启动保持当前页（避免打断用户）。
8. **探针单元选择用页内条件渲染**（ProbeIndex 内 if/else 切换，返回按钮回列表），不用 NavDestination——单元指令限定 main_pages.json 只保留 Index 与探针页，探针子页不注册路由。
9. MIGRATION_PLAN §3 的 15% 降级清单与本单元无关，无新增降级项。

---

## 5. 各文件实现要点（可直接照做的接口面）

### 5.1 ProbeKit.ets（导出面 + 签名）

```typescript
import { hilog } from '@kit.PerformanceAnalysisKit';      // @ohos.hilog.d.ts:117 info(domain,tag,format,...args)
import { fileIo } from '@kit.CoreFileKit';                // OpenMode 未被 kit 重导出（@kit.CoreFileKit.d.ts 导出表已核）→ 用 fileIo.OpenMode.*
import { BusinessError } from '@kit.BasicServicesKit';

export const PROBE_DOMAIN: number = 0xD001;   // 53249，合法域 0x0~0xFFFF
export const PROBE_TAG: string = 'XDM_PROBE'; // ≤31 字节
export const PROBE_STATUS_PENDING: string = 'pending';   // RUNNING/DONE/ERROR 同理（供 ProbePage 复用）

export class KeyValue {
  key: string = '';
  value: string = '';
  constructor(key: string, value: string) { this.key = key; this.value = value; }
}

export class ProbeKit {
  private static instance: ProbeKit | undefined = undefined;   // 禁 # 私有字段、静态方法内禁 this
  static getInstance(): ProbeKit { ... }
  begin(unitId: string, filesDir: string): string
  emit(stepNo: string, kvs: KeyValue[]): string
  end(ok: boolean): string
  getRunId(): string
  getLines(): string[]            // 返回 lines.slice() 拷贝，供 UI 回显
  // 私有：sanitizeValue/sanitizeToken/fmtClock/writeFallbackFile/readText 兜底写盘
}
```

行为红线：`hilog.info(PROBE_DOMAIN, PROBE_TAG, '%{public}s', line)` 是唯一出口（强制 %{public}s 防 private 脱敏；单行 <1500B）；兜底文件路径恒为 `<filesDir>/probe-latest.txt`；所有 catch 按 `BusinessError` 读 `err.code/err.message` 记观测值，不抛出、不写判定词。

### 5.2 ProbePage.ets（结构面）

```typescript
import { ProbeKit, KeyValue, PROBE_STATUS_PENDING, … } from './ProbeKit';  // ProbeStepDef 定义在本文件并导出

export interface ProbeStepDef { stepNo: string; title: ResourceStr; autoRun: boolean; }

@Component
export struct ProbePage {
  unitId: string = '';
  pageTitle: ResourceStr = '';
  steps: ProbeStepDef[] = [];
  autoStart: boolean = true;
  runStep: (stepNo: string) => Promise<void> = (stepNo: string): Promise<void> => Promise.resolve();
  @State statuses: string[] = [];
  @State logText: string = '';
  @State sessionRunning: boolean = false;
  @State copied: boolean = false;
  private sessionStarted: boolean = false;
  // aboutToAppear: 初始化 statuses；autoStart 且未跑过 → this.startSession()
  // startSession(): Promise<void>   —— §3.4 编排
  // runSingle(stepNo): Promise<void> —— 单步迷你会话（begin→该步→end），供 autoRun=false 步骤的"执行"按钮；U0.1 无此步，为 U0.2/U0.3 预留
  // copyLog(): void —— pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, logText)（替代弃用的 createPlainTextData，COLD-F1）+ getSystemPasteboard().setData()（Promise，.then 置 copied，.catch 记 hilog）
  build() {  // 单根 Column：
    // 标题 Text(pageTitle)；按钮行[运行全部/重跑 | 复制日志]（Button('x') 单参形式，禁同挂子组件）
    // 步骤列表 ForEach(steps, (step: ProbeStepDef) => Row[ stepNo、title、状态徽标 $r(probe_status_*)、autoRun=false 时"执行"按钮 ])
    // 标记回显 Scroll > Text(this.logText).fontSize(12)（等宽感可用 fontFamily('monospace')，失败可省）
  }
}
```

装饰器注意：成员名避开通用属性（statuses/logText/sessionRunning 均安全）；ForEach 单层、item 参数名唯一；`Button(this.copied ? $r('app.string.probe_copied') : $r('app.string.probe_copy_log'))` 单参调用。

### 5.3 ProbeEnv.ets（P0-U0 步骤实现 → §6 步骤表）

```typescript
import { ProbeKit, KeyValue } from '../core/ProbeKit';
import { ProbePage, ProbeStepDef } from '../core/ProbePage';
import { deviceInfo } from '@kit.BasicServicesKit';        // 字段已在 SDK 核实
import { bundleManager } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';

const ENV_STEPS: ProbeStepDef[] = [
  { stepNo: 'S1', title: '设备形态', autoRun: true },
  { stepNo: 'S2', title: 'API 版本', autoRun: true },
  { stepNo: 'S3', title: '产品系列', autoRun: true },
  { stepNo: 'S4', title: '应用包信息', autoRun: true },
  { stepNo: 'S5', title: '沙箱写盘自检', autoRun: true },
];

@Component
export struct ProbeEnv {
  private async runStep(stepNo: string): Promise<void> { /* S1~S5 switch；每分支 try/catch(BusinessError) 后 emit err= 观测值，不外抛 */ }
  build() {
    ProbePage({
      unitId: 'P0-U0',
      pageTitle: $r('app.string.probe_env_title'),
      steps: ENV_STEPS,
      autoStart: true,
      runStep: (stepNo: string): Promise<void> => this.runStep(stepNo),  // 实例化点内联箭头，捕获 this
    })
  }
}
```

### 5.4 ProbeIndex.ets

```typescript
import { ProbeEnv } from './units/ProbeEnv';

interface ProbeUnitEntry { unitId: string; title: ResourceStr; }
const PROBE_UNITS: ProbeUnitEntry[] = [ { unitId: 'P0-U0', title: $r('app.string.probe_env_title') } ];

@Entry
@Component
struct ProbeIndex {
  @State selectedUnitId: string = '';
  build() { // 单根 Column：
    // selectedUnitId==='' → 标题 $r(probe_index_title) + ForEach(PROBE_UNITS) 卡片 Row[unitId, title] onClick→selectedUnitId=entry.unitId（空数组显示 probe_index_empty）
    // selectedUnitId==='P0-U0' → 头部[返回按钮 probe_back onClick→selectedUnitId='' + 标题] + ProbeEnv()
    // 后续单元在此追加 else-if 分支与 PROBE_UNITS 表项
  }
}
```

### 5.5 EntryAbility.ets（改）

新增成员 `private targetPage: string = 'pages/Index';`、`private windowStage: window.WindowStage | undefined = undefined;`、私有方法 `resolveTargetPage(want: Want): void`（§3.4）。onCreate：首行调用 resolveTargetPage（保留既有 colorMode 逻辑与日志）；onWindowStageCreate：存 `this.windowStage = windowStage` 后 `loadContent(this.targetPage, …)`（沿用回调式错误日志）；onNewWant：§3.4 暖启动分支。**不 import probe/ 下任何文件**（路由目标只是字符串）。既有 `onDestroy/onWindowStageDestroy/onForeground/onBackground` 不动。

### 5.6 module.json5 / main_pages.json / string.json

见 §2.4 表格，逐键照改；改完自查 JSON5/JSON 合法性（module.json5 允许尾逗号与注释；string.json 是纯 JSON，禁尾逗号）。

---

## 6. 探针步骤设计（P0-U0 环境自检）

拉起：`hdc shell "aa start -b com.example.xdmharmony -a EntryAbility --ps page probe"`；抓取：`hdc shell "hilog -x | grep XDM_PROBE"`；兜底：`hdc shell "cat <filesDir>/probe-latest.txt"`。示例行中的值均为**模拟器形态下的典型观测示例**，非期望断言（期望表由主流程生成的 PROBE 手册承载）。

| 步骤 | 操作（API，均经本机 SDK d.ts 核实） | 观测点（emit 键） | 标记行示例 |
|---|---|---|---|
| BEGIN | ProbePage 编排：生成 runId、解析 filesDir | runId、filesDir | `[XDM_PROBE][P0-U0][BEGIN] runId=142533 filesDir=/data/app/el2/100/base/com.example.xdmharmony/haps/entry/files` |
| S1 设备形态 | 读 `deviceInfo.deviceType`（d.ts:136）、`deviceInfo.osFullName`（:390），均同步常量、免权限 | deviceType、osFullName（消毒后） | `[S1] deviceType=2in1 osFullName=HarmonyOS-6.1.1` |
| S2 API 版本 | 读 `deviceInfo.sdkApiVersion`（:478）、`deviceInfo.firstApiVersion`（:492） | sdkApiVersion、firstApiVersion | `[S2] sdkApiVersion=24 firstApiVersion=xx` |
| S3 产品系列 | 读 `deviceInfo.marketName`（:188；外部产品系列名，可含空格——白名单允许） | marketName | `[S3] marketName=HarmonyOS PC` |
| S4 应用包信息 | `bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT)`（d.ts:1634/:105，API 10+，查自身免权限），取 `name/versionName/versionCode`；catch(BusinessError) → emit err/errCode/errMessage | bundleName、versionName、versionCode（或 err 键组） | `[S4] bundleName=com.example.xdmharmony versionName=1.0.0 versionCode=1000000` |
| S5 沙箱写盘自检 | 写 `filesDir/probe-selftest.txt`：`openSync(path, fileIo.OpenMode.READ_WRITE|CREATE|TRUNC)` → `writeSync(fd, content)`（content=`<runId> P0-U0 selftest`）→ `closeSync`；再 `fileIo.readTextSync(path)`（d.ts:6336）回读；catch → err 键组 | probeFile、writeBytes、readBackBytes（**不写 match/differs 判定词**） | `[S5] probeFile=probe-selftest.txt writeBytes=25 readBackBytes=25` |
| SUMMARY | end(ok) 内聚合：`S1=deviceType=<v>|S2=sdkApiVersion=<n>|S3=marketName=<v>|S4=versionName=<v>|S5=writeBytes=<n>`（<1500B 硬校验） | — | `[SUMMARY] S1=deviceType=2in1\|S2=sdkApiVersion=24\|S3=marketName=HarmonyOS PC\|S4=versionName=1.0.0\|S5=writeBytes=25` |
| END | ok=本次会话无脚手架级异常；steps=5；elapsedMs | ok、steps、elapsedMs | `[END] ok=true steps=5 elapsedMs=12` |

探针首页（ProbeIndex）为人工入口：无 want 参数时用户从应用图标进入默认 Index，探针首页仅经 `page=probe` 或既有调试手段到达——这正是 want 路由的验收点（§7-3）。

---

## 7. 单元验收测试要点（[A] + [H] 冒烟）

**[A] 静态门禁（编码员每文件自跑）**

1. 全量构建：`cd /d D:\git\HarmonyPC\XdmHarmony && devecocli build` —— 零 error、零新 warning（基线已 BUILD SUCCESSFUL）。ArkTS 严格子集在 hvigor 编译期强制，重点自查：禁 any/解构/ctor 参数属性/正则字面量、async 显式 `Promise<void>`、对象字面量带类型、`Object` 经 typeof 窄化。
2. 结构断言（代码走查）：main_pages.json 恰两项且 ProbeIndex 恰一个 @Entry；ProbePage/ProbeEnv 未注册；业务页（pages/Index）与 EntryAbility 均不 import probe/；module.json5 仅新增 deviceTypes 值与 requestPermissions 两处；string.json 既有 3 键未动。

**[H] 冒烟（真机优先；真机需一次性 `devecocli auth login` + `devecocli signature generate --product default`，模拟器免签名）**

3. want 路由冷启动：应用未运行时执行 §0 的 `aa start --ps page probe` → 直接进入探针首页（非 Hello World Index）。
4. want 路由暖启动：探针运行中退后台，再执行同一命令 → onNewWant 切到探针首页；从桌面图标点开 → 保持原页面。
5. 默认路径回归：不带参数冷启动 → 仍进 `pages/Index`（Hello World）。
6. 标记序列完整性：进入 P0-U0 自动运行后抓 hilog，应得完整 9 行序列（BEGIN、S1~S5 各恰一行、SUMMARY、END），逐行命中 verify 正则 `^\[XDM_PROBE\]\[([A-Z0-9-]+)\]\[([A-Za-z0-9-]+)\]\s(.+)$`，BEGIN/END 配对，grep 锚 `XDM_PROBE`。
7. 兜底写盘：`cat <filesDir>/probe-latest.txt` 内容与 hilog 序列一致；`probe-selftest.txt` 存在。复制日志按钮：粘贴到备忘录可见全序列。
8. 形态观测：模拟器（2-in1）可安装、可启动、deviceType 观测值合理；真机运行后 deviceType/osFullName/sdkApiVersion 即为 U0.5 形态确认输入。
9. `xdm-probe-verify` 用本单元日志 + 期望表（主流程按 PROBE_SPEC §3 生成 PROBE-P0-U0 手册与 EXPECT 表时，拉起命令必须采用 §0 修订版）逐步骤判定。

---

## 8. 风险与备注

| 风险 | 缓解 |
|---|---|
| PROBE_SPEC 旧命令残留 → verify 流程拿到空日志 | §0 拍板 + 验收点 9 把关；主流程验收后改文档 |
| `aa start --ps` 参数拼写/设备串问题（多设备） | 先 `devecocli device list` 记 serial；整条命令用引号包裹（hdc shell 规则） |
| hilog 环形缓冲冲掉早期行 | BEGIN 行虽首行但 SUMMARY 兜底 + probe-latest.txt 即时重写（§3.3） |
| 消毒正则区间写错（'-' 位置）运行期 SyntaxError | §3.2 给出精确模式 `[^A-Za-z0-9_.:/|= -]` 与 `[^A-Za-z0-9-]` |
| 交付带探针发布 | PROBE_SPEC §1 既有约定：交付打包前整体移除 probe/（U7.3 执行，本单元无需动作） |
