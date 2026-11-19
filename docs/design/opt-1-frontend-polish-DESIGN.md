# OPT-1 前端优化 · 模块设计书（深色资源化 + Index 拆分 + UX 三项收口）

> 单元：OPT-1 前端优化（24 单元外交接单元）。前置：U4.1（主窗口框架）、U4.2（对话框包）、U4.3（设置/i18n/主题切换链）、U5.1/U5.2、U6.2（全部已交付——本单元是全功能面之上的纯前端收口）。
> 配套：[MIGRATION_PLAN](../../MIGRATION_PLAN.md) §6 决策 11、[UNIT_CATALOG](../../UNIT_CATALOG.md)、[PROBE_SPEC](../../PROBE_SPEC.md)、[HYPIUM_GATE](../../../scripts/HYPIUM_GATE.md)。
> 源码锚（本会话逐一读过核实）：`XDM.Wpf.UI/Themes/LightTheme.xaml:4-75` 与 `DarkTheme.xaml:4-78`（同键集双值资源字典=语义色权威规格，研究分工1 fact1）；`XDM.Core/AppController.cs:429-480`（UpdateToolbarButtonState）；`MainWindow.xaml.cs:158-195`（ApplyFilter）；`XDM.Core/DataAccess/DownloadList.cs:95/:165`（读路径无条件 Stopped）。
> 目标侧现状（本会话读过/grep 核实）：`pages/Index.ets`（1986 行，`wc -l` 实测）；`components/DownloadListItem.ets`（208 行）；`pages/VideoCapture.ets`（296 行）；全前端硬编码 hex 实测 grep=30 处（Index 15 + DownloadListItem 4 + VideoCapture 6 + settings 2 + 对话框 3），`$r('app.color.*')`=0 处，`dark/element/color.json` 仅 `start_window_background` 一键；业务文件 probe import=0；`probe/units/ProbeMainWindow.ets`（S4 清单 22 项）、`docs/probe/EXPECT-u4-1-main-window-framework.json`（S4 total=22）、`docs/probe/PROBE-u4-1-main-window-framework.md`（§5 表 22 行）；单测基线 640/640（u7-3 REPORT:111 实读 verdict）。

---

## 0. 冲突与拍板注记（必读）

1. **僵死 Waiting 行拍板：『initLists 装载清扫』案，且落点比研究建议更保守**。研究 openQuestion 建议落点为"引擎事件重放后（Index.ets:459-462 之后）"。本设计书**修正落点为 `setAdmissionReady(true)`（即 Index.ets:465 的 admission drain）之后**：`DownloadCreationService.drainAdmissions`（DownloadCreationService.ets:100-131）是同步的，`setAdmissionReady(true)`（:84-89）立即消费 `pendingAdmissions` 并逐条 `admitNew`；而 `admitNew` 门挡入队分支**不补写 status**（DownloadManager.ets:181-184，Waiting 由工厂 startWaiting=true 预置，DownloadRecord.ets:102）——若清扫落在 drain 之前，会把合法待接纳行误置 Stopped，drain 门挡入队后形成**反向僵尸**（行实际在队列、UI 显示 Stopped、"继续"按钮点击被 resumeOne 幂等守卫吞掉，DownloadManager.ets:200-202）。drain 之后清扫：待接纳行要么已入 `liveMap`/`queueMap`（`launchStart`/`launchResume` 均同步 `liveMap.set` 先于 start/resume，DownloadManager.ets:329/:344——被清扫条件保护），要么 admission 失败被重新暂存（此时归一 Stopped 语义正确=持久记录保留、可手动恢复）。拒绝"toggleLabel 改传 isQueued"案：只修按钮残留状态列 Waiting 僵尸文本，且令 @ObjectLink 只读行组件反向调 manager 越层、破坏"Index 是 record 字段唯一写者"红线。清扫不落库回声——DB 读出面本无 Waiting（RecordMapping.ets:103-106 R2：completed=0 行 status 恒 Stopped(1)，与源 DownloadList.cs:95/:165 读路径无条件 Stopped 同构）。
2. **base 语义色取值拍板：保现状 hex 逐字节**（纯深色适配、浅色零视觉回归）；WPF LightTheme 仅作键名参照，dark 侧取 DarkTheme 同键 D 值，WPF 无直接对应的键（accent/group_header/danger 的深色变体）按 ask 授权"深色值自定（深灰系背景/亮蓝高亮）"取值。若要求浅色也 1:1 对齐 WPF Light 主题属范围变更，不在本单元（会引入既有界面可见色差，研究 openQuestion 2 已否决）。
3. **分类面板字色拍板：双态显式**（未选中=`text_secondary` 中性灰、选中=`category_selected_text`），对齐 WPF LightTheme 本身即双态显式（CategoryForegroundNormal=#808080 / CategoryForegroundSelected=White）。这是"文本色原则上不显式设置"原则的**唯一新增例外面**（ask ③a 点名的对比度收口目标项）：条件分支无法表达"选中时不设色"，且深色选中底 #114C7B 需确定白字。浅色下未选中分类字由系统黑变为 #5B6B79——这是**有意的浅色可见变化**（收口项本身），唯一一处，列入差异清单。其余全部文本面维持不显式/既有显式面仅做资源化。
4. **语义键粒度拍板：同值不同义不并键**。Index.ets:158 的 `ROW_SELECTED_BG='#E3F2FD'`（分类面板**常态底**——命名误导）与 DownloadListItem.ets:38 的 `ROW_SELECTED_BG='#E3F2FD'`（下载行**选中底**）同值不同义：dark 侧分叉为 #1B1C1E（面板常态，DarkTheme CategoryListBackground）与 #114C7B（行选中，DarkTheme ListViewSelectedBackcolor），必须拆 `category_normal_bg`/`row_selected_bg` 两键，否则深色下面板常态行被误染选中蓝。VideoCapture 行常态底 #FFFFFF 同理不并入 row_normal_bg（#F5F6F8，浅色可见色差）——单列 `surface_bg`。
5. **探针 hex 不在范围**：`ProbeMainWindow.ets:524` 的 `border '#E0E0E0'` 为探针脚手架样式，非业务面，本单元不动（研究 fact2 口径）；ProbeMainWindow.ets 本单元只改走查清单数组与注释（§6）。
6. **配置文件零改动**：本单元无新能力面（无网络/后台/剪贴板/深链增量）→ `module.json5` 零改动；四个新文件是 @Component 非 @Entry 页 → `main_pages.json` 零改动（仅 Index+probe/ProbeIndex 现状维持）；走查清单标题在 ProbeMainWindow 代码数组内、空态文案原样搬迁 → `string.json` 零改动（ask 目标落点列了 string.json，实测无需改动，明写于此防编码员误加键）。
7. **640 单测钉死**：本单元零新增/删改测试文件（无新纯函数——ToolbarAlgo/StatusText/CategoryAlgo/ListAlgo 既有单测锁定不动；清扫逻辑依赖 manager/store 单例+UI 生命周期，不可本地 Hypium 直载，运行时行为由 P4-U1 走查第 14/15/23 项与 S3 覆盖）。验收命令唯一口径见 §5。
8. **拆分形态拍板**：表头（HeaderRow/SortHeaderCell/sortArrow）与行右键菜单（RowContextMenu）**留 Index**，经 `() => void` 闭包 prop（@BuilderParam 槽位）注入双 pane——四子组件文件约束内实现共享，且 @Builder 内 this 闭包绑定 Index，零签名改写零行为变更；代价是 pane 需 @Prop sortVersion 作重渲染触发锚（值本身 pane 不消费，与既有 sortArrow version 参数同款语义，Index.ets:1282-1293 注）。研究 fact9 建议同款。**as-built 修订（R2-F1）**：槽位类型不能用 CustomBuilder——SDK `ets/component/common.d.ts:28415` 实证 `declare type CustomBuilder = (() => any) | void`，联合含 void 分支使调用点报 10505001 "This expression is not callable. Type 'void' has no call signatures"（hvigor 首轮编译实证），必须用 `() => void`。

---

## 1. 目标文件清单（按实现顺序）

> 新 4 / 改 13，共 17 项。`module.json5`、`main_pages.json`、`string.json`、`core/**`、`model/**`、`pages/Settings.ets`、`pages/SettingsTab` 之外的其余组件**零改动**。业务文件禁 import `probe/**`（审查红线，现状 grep=0 保持）。新文件头注照工程惯例写来源/红线注记（同 DownloadListItem.ets:1-18 样式）；GPL-2.0 声明属交付文档层（u7-3 DELIVERY 已定），源码文件不新增许可文本。

| # | 文件 | 新/改 | 职责与对外导出 | dependsOn |
|---|---|---|---|---|
| 1 | `entry/src/main/resources/base/element/color.json` | 改 | 语义色 base 值表（§2.1 全表 12 键追加；既有 `start_window_background` 保留）。base 值=现状硬编码 hex 逐字节，**零浅色视觉回归**（键 5 例外见 §4-2） | — |
| 2 | `entry/src/main/resources/dark/element/color.json` | 改 | 同 12 键 dark 值（§2.1 D 列）。限定词目录机制：U4.3 切 `setColorMode` 后 `$r` 全部重解析，组件零监听（Settings.ets:58-70 链零改动） | #1 |
| 3 | `entry/src/main/ets/components/CategoryPanel.ets` | 新 | 分类面板 @Component（纯搬迁 Index.ets:115-155 常量区+:1827-1851 面板区）：`export struct CategoryPanel`；迁入 `CategoryPanelItem` 接口、`CATEGORY_PANEL` 常量表、`categoryIconResource()` 映射、`CategoryIcon` @Builder。Props：`activeCategoryIndex`（@Prop number，选中高亮）、`categoryCounts`（@Prop number[]，7 槽计数）。回调：`onSelectCategory: (index: number) => void`。行底色三元 `$r('app.color.category_highlight')`/`$r('app.color.category_normal_bg')`，行字色双态显式（§2.1 键 5/11） | #1 #2 |
| 4 | `entry/src/main/ets/components/ToolbarBar.ets` | 新 | 工具栏行 @Component（纯搬迁 Index.ets:1855-1931 整行）：`export struct ToolbarBar`——New(bindMenu)/Delete/OpenFile/OpenFolder/Pause/Resume 六钮+Blank+搜索 TextInput+搜索钮+汉堡钮(bindMenu)。Props：`toolbarState`（@Prop ToolbarState 整体快照）、`searchText`（@Link string，双向）、`newMenuItems`/`mainMenuItems`（普通成员 MenuElement[]，静态内容一次装配）。回调上抛：`onDeleteClick`/`onOpenAction(button: string)`/`onPauseClick`/`onResumeClick`/`onSearchClick`（New 钮无回调——bindMenu 自足）。钮面 `$r('app.color.control_bg')` | #1 #2 |
| 5 | `entry/src/main/ets/components/InProgressPane.ets` | 新 | 进行中列表 @Component（纯搬迁 Index.ets:1711-1756 InProgressPane @Builder）：`export struct InProgressPane`——空态/`List+LazyForEach(inProgressDS)`+行装配（showToggle=true）+`bindContextMenu`。Props：`ds: DownloadListDataSource`（普通成员按引用——禁 @Prop/@Link 包装）、`statusLabels: StatusLabels`（普通成员）、`inProgressCount`（@Prop number，空态切换）、`sortVersion`（@Prop number，仅触发锚）、`headerBuilder`/`rowMenuBuilder`（@BuilderParam `() => void`，Index 闭包注入——as-built R2-F1）。回调上抛：`onSelectRow`/`onToggleRowSelect`/`onToggle`/`onRowContextAppear(id: string)`（onHeaderSort 不设——排序经 headerBuilder 闭包→Index.SortHeaderCell.onClick→Index.onHeaderSort，as-built R2-F1） | #1 #2 #3 |
| 6 | `entry/src/main/ets/components/FinishedPane.ets` | 新 | 完成列表 @Component（纯搬迁 Index.ets:1759-1798 FinishedPane @Builder）：`export struct FinishedPane`——同构 showToggle=false、**无 bindContextMenu**（现状完成列表无右键菜单，Index.ets:1771-1790 核实）。Props/回调与 InProgressPane 同款（去 rowMenuBuilder/onRowContextAppear），空态判 `finishedCount` | #1 #2 #3 |
| 7 | `entry/src/main/ets/pages/Index.ets` | 改 | 五处改动面（既有字段写序逐字节不动，全部纯追加/等价替换）：①拆分接线——build 内分类面板区换 `CategoryPanel({...})`、工具栏行换 `ToolbarBar({...})`、TabContent 内换 `InProgressPane({...})`/`FinishedPane({...})`，删除 :157-158 两常量与 :1639-1643/:1646-1690/:1696-1798 已迁出代码；②hex 资源化——余下 11 处 hex 换 `$r`（表 :1655/:1689/:1859-1971 区段）；③`onSearchClick` 头部加 `if (this.activeCategoryIndex === 0) { return; }` 早退；④新增 `private sweepOrphanWaiting(records: DownloadRecord[]): void` + initLists :465 之后两行调用（§3.1）；⑤五事件处理器/buildEngineEvents/recomputeToolbar/selectCategory/selectRow/toggleRowSelect/handleToggle/工具栏三处理器/对话框控制器/菜单装配——**逐字节零改动**（回调闭包原样上抛给子组件） | #3 #4 #5 #6 #1 #2 |
| 8 | `entry/src/main/ets/components/DownloadListItem.ets` | 改 | 四处资源化：:38 `ROW_SELECTED_BG`→`$r('app.color.row_selected_bg')`、:39 `ROW_NORMAL_BG`→`$r('app.color.row_normal_bg')`（两常量删除）、:160/:166 `fontColor('#5B6B79')`→`$r('app.color.text_secondary')`；`rowBackground(): string` 改 `rowBackground(): Resource`。@ObjectLink 只读/toggleLabel 三分支/列常量导出——零改动 | #1 #2 |
| 9 | `entry/src/main/ets/pages/VideoCapture.ets` | 改 | 六处资源化：:191/:199/:207 钮面→control_bg、:219 错误文案→text_danger、:253 组头→group_header_bg、:276 三元→`$r('app.color.row_selected_bg')`/`$r('app.color.surface_bg')`（两侧均 Resource，类型一致）。tracker/选择/下载链逻辑零改动 | #1 #2 |
| 10 | `entry/src/main/ets/components/settings/GeneralSettingsTab.ets` | 改 | 一处：:529 `.backgroundColor(index === this.selectedCatIndex ? '#D6E4F5' : '#F1F3F5')` → `$r('app.color.category_highlight')`/`$r('app.color.control_bg')`（字色不显式——深色选中底 #114C7B 上系统白字可读，维持"文本色原则上不显式"） | #1 #2 |
| 11 | `entry/src/main/ets/components/settings/CredentialSettingsTab.ets` | 改 | 一处：:247 同款映射 | #1 #2 |
| 12 | `entry/src/main/ets/components/ProgressWindowDialog.ets` | 改 | 一处：:141 `fontColor('#1565C0')`（限速文本可点击强调）→ `$r('app.color.accent')`。对话框宿主/动作面零改动 | #1 #2 |
| 13 | `entry/src/main/ets/components/CompletedDialog.ets` | 改 | 一处：:89 `fontColor('#1565C0')`（不再提示链接）→ `$r('app.color.accent')` | #1 #2 |
| 14 | `entry/src/main/ets/components/DownloadSelectionDialog.ets` | 改 | 一处：:482 `.border({ width: 1, color: '#E0E0E0' })` → `$r('app.color.divider')` | #1 #2 |
| 15 | `entry/src/main/ets/probe/units/ProbeMainWindow.ets` | 改 | 走查清单 22→23 三处同步（§6.1 逐点）：`CHECKLIST_TITLES` 追加第 23 项深色观测、`MAIN_WINDOW_STEPS` S4 title 与全部注释计数 22→23。**S1/S2/S3 逻辑与 `:524` 探针 border hex 零改动** | #7 |
| 16 | `docs/probe/EXPECT-u4-1-main-window-framework.json` | 改 | S4 expect 串与项号锚 22→23（§6.2 逐点：sessions 字段、S4 expect `total=23`/`checked=<0..23>`/`checked=23 total=23`、S4 note 计数与项号→锚速查补 `23=OPT-1 深色资源化`） | #15 |
| 17 | `docs/probe/PROBE-u4-1-main-window-framework.md` | 改 | 手册同步（§6.3 逐点）：头部/§0/§3.1/§3.2 计数、§5 标题与追加第 23 行（操作/预期/差异锚）、§6 S4 示例行 `unchecked=…/23`、§7 S4 分流行 `1~23`、§8 回贴 `23/23` | #15 |

---

## 2. 数据模型与表结构（对照源码逐一核对）

### 2.1 语义色键全表（base+dark 双份 color.json 各追加 12 键；本单元唯一的"表结构"）

| # | 键名 | base（=现状 hex 逐字节） | dark | 消费点（现状行号） | dark 值依据（DarkTheme.xaml 同键 / 自定标注） |
|---|---|---|---|---|---|
| 1 | `row_normal_bg` | `#F5F6F8` | `#232428` | DownloadListItem.ets:39 行常态底 | ListViewBackcolor D#232428 |
| 2 | `row_selected_bg` | `#E3F2FD` | `#114C7B` | DownloadListItem.ets:38 行选中底；VideoCapture.ets:276 选中支 | ListViewSelectedBackcolor D#114C7B（选中字 DarkTheme=White → 见键 5 同理） |
| 3 | `category_normal_bg` | `#E3F2FD` | `#1B1C1E` | Index.ets:158 分类面板常态底（现名 ROW_SELECTED_BG，误导名删除） | CategoryListBackground D#1B1C1E |
| 4 | `category_highlight` | `#D6E4F5` | `#114C7B` | Index.ets:157 面板选中高亮；GeneralSettingsTab.ets:529、CredentialSettingsTab.ets:247 选中支 | CategoryHighlight D#114C7B |
| 5 | `category_selected_text` | `#000000` | `#FFFFFF` | Index.ets:1831 面板选中行字色（**新增显式**，现状隐式系统色） | CategoryForegroundSelected=White（DarkTheme 原值）；base 取黑（浅底 #D6E4F5 上白字不可读——源 Light 选中底为深蓝 #0A6AB6 配白字，鸿蒙浅色底是浅蓝，字色适配为黑） |
| 6 | `control_bg` | `#F1F3F5` | `#1B1C1E` | Index.ets:1859/1864/1872/1881/1890/1899/1919/1929/1960/1966 钮面×10；VideoCapture.ets:191/199/207；两设置页常态支 | ControlBackcolor D#1B1C1E |
| 7 | `surface_bg` | `#FFFFFF` | `#232428` | VideoCapture.ets:276 行常态支 | SearchBackcolor D#232428（白色表面键） |
| 8 | `group_header_bg` | `#ECEFF1` | `#31363F` | VideoCapture.ets:253 组头底 | 行悬停键 D#31363F（分组头语义最接近的既有深灰） |
| 9 | `divider` | `#E0E0E0` | `#000000` | Index.ets:1689 表头底边/:1971 状态栏顶边；DownloadSelectionDialog.ets:482 边框 | ToolbarBordercolor D#000000 |
| 10 | `accent` | `#1565C0` | `#6EB4F0` | Index.ets:1655 表头箭头；ProgressWindowDialog.ets:141；CompletedDialog.ets:89 | **自定**（ask 授权"亮蓝高亮"）：DarkTheme 强调系 ProgressBarForecolor D#114C7B 为深蓝，小字文本在深灰底上对比不足，取亮蓝 #6EB4F0 |
| 11 | `text_secondary` | `#5B6B79` | `#B5BCC9` | DownloadListItem.ets:160/:166 日期/大小；Index.ets:1831 面板未选中行字色（**新增显式**=对比度收口项） | ListViewForecolor（次文本）D#B5BCC9 |
| 12 | `text_danger` | `#C62828` | `#EF9A9A` | VideoCapture.ets:219 下载失败文案 | **自定**：WPF 无危险文本键，深底上取亮红 #EF9A9A（Material Red 200 系）保持警示可读 |

> 不落键申明：主文本色不落键（前端现状零处显式主文本 fontColor，跟随系统即自动适配深色——原则维持）；`start_window_background` 既有键双份已存在零改动；probe 文件 hex 不在范围（注记 5）。

### 2.2 四子组件 props 数据契约（零新数据类型，全部复用既有类型）

| 组件 | 装饰器成员 | 普通成员 | 回调（上抛 Index） |
|---|---|---|---|
| CategoryPanel | `@Prop activeCategoryIndex: number`；`@Prop categoryCounts: number[]` | —（CATEGORY_PANEL 常量/CategoryPanelItem/categoryIconResource 迁入为文件内私有） | `onSelectCategory(index: number)` |
| ToolbarBar | `@Prop toolbarState: ToolbarState`；`@Link searchText: string` | `newMenuItems: MenuElement[]`；`mainMenuItems: MenuElement[]`（构造期一次装配，静态内容） | `onDeleteClick()`；`onOpenAction(button: string)`；`onPauseClick()`；`onResumeClick()`；`onSearchClick()` |
| InProgressPane | `@Prop inProgressCount: number`；`@Prop sortVersion: number`（仅触发锚） | `ds: DownloadListDataSource`；`statusLabels: StatusLabels`；`headerBuilder: () => void`（@BuilderParam）；`rowMenuBuilder: () => void`（@BuilderParam） | `onSelectRow(id)`；`onToggleRowSelect(id)`；`onToggle(id)`；`onRowContextAppear(id)` |
| FinishedPane | `@Prop finishedCount: number`；`@Prop sortVersion: number`（仅触发锚） | `ds: DownloadListDataSource`；`statusLabels: StatusLabels`；`headerBuilder: () => void`（@BuilderParam） | `onSelectRow(id)`；`onToggleRowSelect(id)`；`onToggle(id)` |

### 2.3 零变更数据契约核对（逐一读过核实，本单元只消费不改写）

| 契约 | 现状锚 | 核对结论 |
|---|---|---|
| `DownloadRecord`（@Observed） | model/DownloadRecord.ets:33-84（`status` :46、`kind` :38、`uiSelected` :84） | 字段/写者/`@Observed` 语义零改动；行组件 @ObjectLink 只读红线保持，Index 恒唯一写者 |
| `DownloadStatus` 枚举 | model/DownloadTypes.ets:18-23（Downloading=0/Stopped=1/Finished=2/Waiting=3） | 零改动；清扫只在 Waiting→Stopped 方向写 |
| `ToolbarState`（class 9 布尔） | core/util/ToolbarAlgo.ets:21-31（`:9` 布尔，实为 openFile/OpenFolder/Pause/Resume visible+enabled 与 deleteEnabled——文件头 :20 注"十布尔"含注释口径差，字段实数 9，以代码为准） | 零改动；`computeToolbarState` 纯函数与 Index 消费点集合（selectCategory:969/selectRow:1023/toggleRowSelect:1040/handleFinished:906/removeRecords:1204）逐字节不动；@Prop 传整体快照后 @State 整体替换赋值语义不变 |
| `StatusLabels` | core/util/StatusText.ets:20-25 | 零改动；Index 装配一次传 pane（普通成员，aboutToAppear 先于首帧 build，子组件构造期取得终值——与现状 @Builder 内联同语义） |
| `CategoryDef`/`DEFAULT_CATEGORIES` | core/util/CategoryAlgo.ets:31/:51 | 零改动；过滤/计数路径（finishedDS.applyFilter/countByExtensions）不动 |
| `DownloadListDataSource` | model/DownloadListDataSource.ets:28-178（initialize 浅拷贝 :53、addSorted/removeById 增量通知、applyFilter/toggleSort reload、getRecordById/fullCount/countByExtensions/sortState/clearUiSelection） | 零改动；双 DS 按引用传 pane（普通成员），DataChangeListener 驱动 LazyForEach 链不变，keyGenerator 恒 record.id |
| DB 面/RecordMapping R1-R5 | core/db/RecordMapping.ets:103-106（R2 completed=0 恒 Stopped） | 零改动；清扫不落库（源语义 status 列只写不读，DownloadList.cs:95/:165） |
| 主题切换链 | pages/Settings.ets:58-70（applyThemeNow→setColorMode）+ EntryAbility 冷启重放 | 零改动；`$r` 重解析自动生效 |

---

## 3. 关键算法翻译说明

### 3.1 僵死 Waiting 行装载清扫（新增算法面；无数学，纯状态归一）

**源语义**：status 列只写不读——两条读路径（LoadDownloads/GetDownloadById）对 completed=0 行无条件强制 Stopped（DownloadList.cs:95/:165）；Waiting 仅是运行态概念（AddItemToTop startType==Waiting、SetDownloadStatusWaiting、IsDownloadActive 含 queued，AppController.cs:61/:288-297）。鸿蒙 DB 面已同构（R2），僵尸仅存在于**内存面**：`resumeOne` 门挡入队置 `record.status=Waiting` 仅 UI 内存（DownloadManager.ets:207）、工厂 startWaiting=true 的待接纳行（DownloadCreationService.ets:149-153 publishCommitted→pendingAdmissions）——二者的 status 与 manager 队列生命周期可能错位，`toggleLabel`（DownloadListItem.ets:69-77）三分支只看 `record.status`，`status===Waiting && !isQueued` 即僵死"取消排队"按钮；同源僵尸还有状态列 Waiting 文本（generateStatusText 消费点 :177）。

**翻译**（Index 新增私有方法，主线程同步 O(n)，n=双列表全量行数，仅启动装载跑一次）：

```
sweepOrphanWaiting(records: DownloadRecord[]):
  manager ← DownloadManager.getInstance()
  for i in 0..records.length-1:
    r ← records[i]
    if r.status === Waiting && !manager.isLive(r.id) && !manager.isQueued(r.id):
      r.status ← Stopped        // 仅内存；不落库（DB 读出面本无 Waiting，R2）
```

**调用点**（initLists 内既有行零改序，纯追加两行）：`DownloadCreationService.getInstance().setAdmissionReady(true)`（Index.ets:465，同步 drain）**之后**、`await BridgeInbox.getInstance().initialize()`（:466）之前：

```
this.sweepOrphanWaiting(lists.inProgress);
this.sweepOrphanWaiting(lists.finished);
```

**正确性论证（三重保护）**：
- ① 待接纳行：drain 已把 `pendingAdmissions` 逐条 `admitNew`（同步）——门过则 `launchStart` 同步 `liveMap.set`（DownloadManager.ets:329）→ `isLive=true` 保护；门挡则 enqueue → `isQueued=true` 保护；admission 异常且两集合皆空时被重新暂存（DownloadCreationService.ets:125-127）→ 归一 Stopped 语义正确（持久记录保留、可手动恢复，与源"提交成功但立即启动失败"同貌）。
- ② DB 装载行：`recordFromRow` R2 恒 Stopped——清扫对它们恒 no-op。
- ③ 重放后行：`engineDuringLoad` 重放（:459-462）只经五事件处理器写 status（Downloading/Stopped/Finished），不产生 Waiting；Scheduler 恢复类入队行经 `isQueued` 保护。
- 传入数组用 `lists.inProgress/finished`（initLists 局部变量）：`initialize` 是浅拷贝（DownloadListDataSource.ets:53 `records.slice()`），**元素引用与 DS 内同一对象**——改 status 即改 DS 行，@Observed 驱动行刷新。
- 时序上先于 `openNextInbox()`（:468）：首帧提示窗弹出前列表状态已正确。

### 3.2 onSearchClick 分类 0 早退（对齐源 ApplyFilter 分支）

源 `ApplyFilter`（MainWindow.xaml.cs:158-195）：`index==0` 分支只切视图可见性+重发事件，**对任何列表零过滤**（搜索仅作用完成列表：IsCategoryMatched=名称大小写不敏感 Contains+扩展名大写精确集，Helpers.cs:190-201）。鸿蒙现状 `onSearchClick`（Index.ets:1009-1011）无条件 `finishedDS.applyFilter(...)`——进行中视图下点搜索会**隐式改写完成 DS 投影**（完成页不可见时不可感知的过滤残留，切回完成页才显形）。翻译：方法体首行加 `if (this.activeCategoryIndex === 0) { return; }`——观测行为与源等价（源该分支不改过滤投影），`selectCategory` 清搜索框（:953）/clearFilter 分支结构零改动，无泄漏面（分类切换恒清框）。

### 3.3 拆分等价变换与状态传递矩阵（纯搬迁的核心不变量）

| 不变量 | 保持手段 |
|---|---|
| 五事件处理器/buildEngineEvents 逐字节 | 全留 Index；pane 经三回调（onSelectRow/onToggleRowSelect/onToggle）转发，闭包链多一跳、逻辑逐字节不变（DownloadListItem 三回调 onSelect/onToggleSelect/onToggle 同款先例，DownloadListItem.ets:53-58） |
| 工具栏状态机重算触发点 | 全留 Index（selectCategory/selectRow/toggleRowSelect/handleFinished/removeRecords 五消费点+recomputeToolbar）；ToolbarBar 只搬六钮渲染，`toolbarState` @Prop 收快照——Index `this.toolbarState = computeToolbarState(...)` 整体替换 → @Prop 同步 → 子重渲染（class 整体替换触发语义不变） |
| 双 DS 引用与 LazyForEach 通知链 | `ds` 普通成员按引用传 pane（**禁 @Prop/@Link**——装饰器会拷贝/代理破坏"DS 引用不变、内部 DataChangeListener 驱动"模型）；keyGenerator 恒 record.id |
| 表头箭头重渲染 | HeaderRow/SortHeaderCell/sortArrow 留 Index（sortVersion @State 读 DS.sortState 快照的手法原样），经 `headerBuilder`（@BuilderParam `() => void`）闭包 prop 注入 pane（`: (): void => { this.HeaderRow(true) }` 箭头闭包捕获 Index this）；pane `@Prop sortVersion` 作重渲染触发锚（值不消费）——sortVersion++ → Index 重渲染 → @Prop 同步 → pane 重渲染 → 重调 builder 读最新值 |
| 行右键菜单 R2-F1 手法 | RowContextMenu @Builder 留 Index（读 `this.contextMenuRowId`/分派 onRefreshLinkMenu/onShowProgressMenu），经 `rowMenuBuilder`（@BuilderParam `() => void`）注入；`bindContextMenu(this.rowMenuBuilder, ResponseType.RightClick, { onAppear: (): void => { this.onRowContextAppear(record.id) } })`——onAppear 上抛 Index.handleRowContextAppear（写 contextMenuRowId+selectRow，Index.ets:1417-1420 零改动） |
| @Builder 传引用的 this 绑定 | 父侧一律以**箭头闭包**包装 @Builder 调用（`(): void => { this.HeaderRow(true) }`），禁直接传方法引用（this 丢失）——@BuilderParam 槽位类型 `() => void`（as-built R2-F1：CustomBuilder 联合含 void 分支调用点 10505001 不可调用） |
| 空态/文本 | '暂无进行中下载'/'暂无已完成下载' 随 pane 原样搬迁（不做 i18n，纯搬迁口径） |
| 防回环/Tabs 同步 | tabsSyncGuardView/onTabChange/syncTabsView 全留 Index（Tabs 仍在 Index build） |

### 3.4 线程模型映射

本单元零新增异步/TaskPool 面：全部改动（渲染拆分、$r 资源化、清扫、早退）在 UI 主线程同步执行。清扫 O(n) 单次遍历仅在 initLists 装载路径执行一次，`manager.isLive/isQueued` 是同步 Map 读取（DownloadManager.ets:244-250），无跨线程竞争；store/manager 既有线程纪律（DB fire-and-forget Promise、引擎事件经 wrapper 回主线程）零触碰。

---

## 4. 与源码的有意差异清单

| # | 差异 | 定性与依据 |
|---|---|---|
| 1 | 深色语义色为"源参照+自定"混合：背景/次文本/边框/高亮取 DarkTheme.xaml 同键 D 值；accent（#6EB4F0）/text_danger（#EF9A9A）/group_header dark 深色值自定 | ask 授权"语义色深色值自定（深灰系背景/亮蓝高亮）"；非像素级 1:1 |
| 2 | base 全键=现状 hex 逐字节（浅色零回归）——**唯一例外**：分类面板未选中行字色新增显式 `text_secondary`（浅色系统黑→#5B6B79 中性灰）、选中行新增显式 `category_selected_text` | ask ③a 点名的对比度收口目标项；WPF LightTheme 本身即双态显式（Normal #808080/Selected White），鸿蒙按底色明度适配 |
| 3 | 僵死 Waiting 行修法=initLists 装载清扫（drain 后），不改 toggleLabel、不动 store 层 | 源在读路径强制 Stopped（DownloadList.cs:95/:165）且不回写；鸿蒙 DB 面已同构（R2），清扫补内存面错位窗口；一次修复按钮+状态列双消费点，Index 恒唯一写者、行组件不越层调 manager |
| 4 | onSearchClick 加分类 0 早退 | 对齐源 ApplyFilter index==0 零过滤分支（MainWindow.xaml.cs:158-168）；消除鸿蒙侧"进行中视图下点搜索隐式改写完成 DS 投影"的不可感知残留 |
| 5 | Index.ets 拆分为四子组件+@BuilderParam `() => void` 闭包 prop 注入表头/右键菜单 builder | WPF 无此形态（XAML 模板/DataTemplate 天然分离），属鸿蒙化结构等价变换；事件面/DS 引用/@ObjectLink/防回环语义零变更 |
| 6 | MIGRATION_PLAN 既有降级项延续（非本单元引入）：汉堡菜单 9 项占位禁用（D5）、状态栏三触点占位禁用（D12）、子分类 25 缩进不实现、OpenFile/OpenFolder 等既有能力面不动 | UNIT_CATALOG/MIGRATION_PLAN §3 降级清单 |
| 7 | `module.json5`/`main_pages.json`/`string.json` 零改动 | 无新能力/新页面/新资源串（走查标题在探针代码数组内；空态文案原样搬迁） |
| 8 | 640 单测零增删（expectedTests 钉死） | 无新纯函数；清扫依赖单例+生命周期不可本地直载，运行时行为由 P4-U1 S3+走查 14/15/23 项覆盖 |

---

## 5. 单元验收测试要点

1. **编译门禁**：hvigor 全量构建零 error 零新 warning（ArkTS 严格子集编译期强制；重点自查面：`rowBackground(): Resource` 返回类型、三元两侧同为 Resource、@Prop class/数组、@BuilderParam 槽位类型 `() => void`（R2-F1）、@Link searchText 父侧传 `$searchText`）。
2. **单测真值（唯一计分口径）**：`node scripts/run-hypium.cjs --expected-tests 640 --output ../migration-runs/hypium -- 'D:/Tools/DevEco Studio/tools/node/node.exe' 'D:/Tools/DevEco Studio/tools/hvigor/bin/hvigorw.js' test --no-parallel`——四条件全满足（result 文件 + 完成标记 + expectedTests 钉死 + exit 0）方为通过；**不得以 hvigor 退出码或 BUILD SUCCESSFUL 判绿**（HYPIUM_GATE.md）。基线 640/640（u7-3 REPORT:111 verdict 实读）。本单元零新增测试文件，`--expected-tests 640` 不得改动。
3. **事件面零破坏（回归面）**：P4-U1 走查清单第 1~22 项复走（重点是 4/5 视图切换、7/8 搜索与清框、9 排序、11~13 选中状态机、14/15 Waiting 行取消排队与持久、16/17 工具栏、21 流畅）——拆分后五事件处理器/工具栏状态机/防回环逻辑逐字节未动，任何一项 FAIL 即拆分回归。
4. **深色适配（新增验收面）**：P4-U1 第 23 项（§6.3 定义）——设置页勾选"深色主题"跟随系统+系统切深色后，主列表/分类面板/工具栏/搜索行/状态栏/双列表行/右键菜单/各对话框全部可读，无同色叠字；浅色模式下全界面与现状逐像素无差（除分类面板未选中字色收口）。
5. **UX 三项专项**：a) 对比度——深浅两态下分类面板未选中/选中行字底对比可读；b) 僵死 Waiting——造门挡入队行→杀进程重启→行显 Stopped（走查 14/15 既有项回归），且启动瞬间待接纳/排队行不闪现 Stopped（清扫 drain 后时序保护）；c) 搜索早退——进行中视图（分类 0）下点搜索钮，完成 DS 投影不变（切完成页无过滤残留）。
6. **纯逻辑算法说明**：本单元无分段/偏移/限速数学，无新纯函数拆分与 Hypium 用例（ ToolbarAlgo/StatusText/CategoryAlgo/ListAlgo 既有用例锁定不动即回归证明）；清扫算法正确性由 §3.1 三重保护论证+探针/走查覆盖，见差异 #8。

---

## 6. 探针改动设计（P4-U1 走查清单 22→23 三处同步；无新探针文件）

> 同步铁律：三处（探针代码数组 / EXPECT S4 expect 串 / 手册 §5 表）任一漏改，`xdm-probe-verify` 按 S4 expect 判 FAIL/UNVERIFIED（EXPECT 钉死 `total=22` 会与发射值 23 冲突）。

### 6.1 `probe/units/ProbeMainWindow.ets`（业务探针文件，允许改）

| 位置 | 改动 |
|---|---|
| 文件头注 :3-4/:17 | "22 项清单"→"23 项清单"；S4 说明补"23=OPT-1 深色模式观测" |
| `MAIN_WINDOW_STEPS` :57 | S4 `title: '人工走查清单 22 项'` → `'人工走查清单 23 项'` |
| `CHECKLIST_TITLES` :60-84 | 注释计数 22→23；数组尾部追加第 23 项（文案见 6.3 表行 23 走查项列，日志白名单外字符经 ProbeKit 消毒，标题只进 UI 不进日志——现状机制零改动） |
| `checkedFlags` :105/:498 注释 | "（22 项；…）"→23 |
| `runS4` :395 注释 | `checked=<k> total=22` → `total=23`（发射逻辑零改动——total 取 `checkedFlags.length` 自适应） |
| S1/S2/S3 全部逻辑、`:524` border hex | **零改动** |

### 6.2 `docs/probe/EXPECT-u4-1-main-window-framework.json`

| 位置 | 改动 |
|---|---|
| `sessions` 字段 | 两处"22 项清单"→23（主会话走查+单步会话勾选） |
| S4 `expect` | `checked=<0..22> total=22` → `checked=<0..23> total=23`；`checked=22 total=22 unchecked=none` → `checked=23 total=23 unchecked=none` |
| S4 `note` | "22 项 Toggle"→23；"unchecked=1 基项号"口径不变；`checked=22/22`→`23/23`；项号→锚速查末尾追加 `23=OPT-1 深色资源化（深浅色切换全界面可读）` |
| S1/S2/S3/SUMMARY/END | 零改动 |

### 6.3 `docs/probe/PROBE-u4-1-main-window-framework.md` §5 追加行（其余计数同步点：头部 :5-6、§0 步骤 3、§3.1、§3.2、§5 标题、§6 S4 示例行 `unchecked=1/…/22`→`…/23`、§7 S4 行 `1~22`→`1~23`、§8 `④S4 走查清单 22/22`→`23/23`）

| # | 走查项 | 操作 | 预期 | 差异锚 |
|---|---|---|---|---|
| 23 | 深色模式全界面可读 | 常规设置页勾选"深色主题"（跟随系统）→ 系统切换深色模式 → 逐界面目检（主列表/分类面板/工具栏六钮/搜索行/状态栏/双列表行/行右键菜单/新建/进度/完成/选择/删除确认对话框） | 全部界面文字与底色对比可读，无同色叠字/白底白字/黑底黑字；切回浅色与既有观感一致 | OPT-1 深色语义色资源化（`app.color.*` base+dark 双份 color.json；U4.3 setColorMode 链零改动） |

> 探针步骤设计说明：第 23 项为**人工观测项**（S4 勾选面机制内，无新增发射键）；S1~S3 自动步骤与两段会话形态（主会话 7 行/S4 单步 4 行、runId 配对、末次 runId 为 S4 验收锚）全部保持。运行次序红线（§0：先主页面走查→探针→勾选→单步 S4）不变，走查时第 23 项需在系统深色下完成主页面目检后再勾选。
