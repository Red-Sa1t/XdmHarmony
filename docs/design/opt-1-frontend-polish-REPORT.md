# OPT-1 前端优化 · 单元交付报告（opt-1-frontend-polish）

> 单元：OPT-1（24 单元外交接单元）｜risk=low｜设计书：[opt-1-frontend-polish-DESIGN.md](./opt-1-frontend-polish-DESIGN.md)（含 as-built R2-F1 修订注记）
> 工程：XdmHarmony（API 24 / SDK 6.1.1(24)，bundle com.example.xdmharmony）｜源参照：resourses/xdm（XDM 2023，GPL-2.0，只读未触碰）

## 1. 单元范围与验收要点

范围（设计书 §1，17 文件=新 4/改 13）：

- **①深色模式资源化**：语义色 12 键 base+dark 双份 color.json；全前端硬编码 hex 收敛为 `$r('app.color.*')`，使 U4.3 setColorMode 主题切换链真正可用（链零改动）。
- **②Index.ets（1986 行）拆分**：CategoryPanel/ToolbarBar/InProgressPane/FinishedPane 四子组件文件化，纯搬迁零行为变更。
- **③UX 三项收口**：分类面板对比度（随①双态字色）/僵死 Waiting 行装载清扫/onSearchClick 分类 0 早退。
- **④P4-U1 走查清单 22→23**：追加深色模式观测项，探针代码/EXPECT/手册三处同步。

验收要点（设计书 §5）：

1. 编译门禁：hvigor 零 error（ArkTS 严格子集编译期强制）。
2. 单测真值：`node scripts/run-hypium.cjs --expected-tests 640` 四条件为唯一计分口径（不以 hvigor 退出码或 BUILD SUCCESSFUL 判绿）；本单元零测试文件增删。
3. 事件面零破坏红线：五事件处理器/buildEngineEvents/recomputeToolbar 及其五消费点（selectCategory/selectRow/toggleRowSelect/handleFinished/removeRecords）/computeToolbarState/tabsSyncGuardView 防回环逐字节不动。
4. 深色适配：深浅色切换后全部界面可读（走查第 23 项）；浅色与现状零视觉回归（唯一例外=分类面板双态字色收口，ask ③a 点名目标）。
5. 配置红线：module.json5/main_pages.json/string.json 零改动（无新能力/页面/资源串）；业务文件零 probe import。

## 2. 实现摘要

按设计书 §1 顺序交付 17 文件：

| # | 文件 | 新/改 | 要点 |
|---|---|---|---|
| 1 | entry/src/main/resources/base/element/color.json | 改 | 12 键 base 值=现状硬编码 hex 逐字节（浅色零回归）；start_window_background 保留 |
| 2 | entry/src/main/resources/dark/element/color.json | 改 | 同 12 键 dark 值（DarkTheme.xaml 同键 D 值为主；accent #6EB4F0/text_danger #EF9A9A 自定，ask 授权） |
| 3 | entry/src/main/ets/components/CategoryPanel.ets | 新 | 分类面板（纯搬迁 Index:115-155/:1827-1851）；@Prop activeCategoryIndex/categoryCounts；行底/双态字色 $r 化 |
| 4 | entry/src/main/ets/components/ToolbarBar.ets | 新 | 工具栏行（纯搬迁 Index:1855-1931）；@Prop toolbarState 快照+@Link searchText+MenuElement[] 两成员+五回调上抛 |
| 5 | entry/src/main/ets/components/InProgressPane.ets | 新 | 进行中列表（纯搬迁 Index:1711-1756）；ds 按引用普通成员、headerBuilder/rowMenuBuilder @BuilderParam `() => void` 注入、bindContextMenu+四回调上抛 |
| 6 | entry/src/main/ets/components/FinishedPane.ets | 新 | 完成列表（纯搬迁 Index:1759-1798）；showToggle=false、无 bindContextMenu（现状核实） |
| 7 | entry/src/main/ets/pages/Index.ets | 改 | 五处改动面：四子组件接线/余下 hex 资源化/onSearchClick 分类 0 早退/sweepOrphanWaiting+initLists 两行调用/事件面逐字节零改动 |
| 8 | entry/src/main/ets/components/DownloadListItem.ets | 改 | 行底两常量删除改 $r、rowBackground(): string→Resource、次文本 text_secondary×2 |
| 9 | entry/src/main/ets/pages/VideoCapture.ets | 改 | 六处资源化（control_bg×3/text_danger/group_header_bg/行底三元） |
| 10 | entry/src/main/ets/components/settings/GeneralSettingsTab.ets | 改 | :529 选中/常态底→category_highlight/control_bg |
| 11 | entry/src/main/ets/components/settings/CredentialSettingsTab.ets | 改 | :247 同款映射 |
| 12 | entry/src/main/ets/components/ProgressWindowDialog.ets | 改 | :141 限速文本→accent |
| 13 | entry/src/main/ets/components/CompletedDialog.ets | 改 | :89 不再提示链接→accent |
| 14 | entry/src/main/ets/components/DownloadSelectionDialog.ets | 改 | :482 列表边框→divider |
| 15 | entry/src/main/ets/probe/units/ProbeMainWindow.ets | 改 | 22→23：CHECKLIST_TITLES 尾追第 23 项/S4 title/全部注释计数；S1~S3 逻辑与 :524 border hex 零改动 |
| 16 | docs/probe/EXPECT-u4-1-main-window-framework.json | 改 | sessions/S4 expect（total=23/checked=23）/S4 note 计数与锚速查补 23=OPT-1 深色资源化 |
| 17 | docs/probe/PROBE-u4-1-main-window-framework.md | 改 | §5 追加第 23 行+全文计数点同步 |

关键 as-built 事实：

- **语义色 12 键**：base=现状 hex 逐字节；dark 取 `XDM.Wpf.UI/Themes/DarkTheme.xaml` 同键 D 值（ListViewBackcolor #232428/ListViewSelectedBackcolor #114C7B/CategoryListBackground #1B1C1E/CategoryHighlight #114C7B/ControlBackcolor #1B1C1E/SearchBackcolor #232428/ToolbarBordercolor #000000/ListViewForecolor #B5BCC9/ListViewMouseOverBackcolor #31363F，逐一 grep 实读命中），accent/text_danger 为 ask 授权自定值。`'#E3F2FD'` 同值不同义拆 category_normal_bg/row_selected_bg 两键使 dark 侧分叉（#1B1C1E vs #114C7B，设计书 §0-4）。
- **hex 收敛覆盖**：全前端 30 处（Index 15/DownloadListItem 4/VideoCapture 6/settings 2/对话框 3）全数收敛；业务文件功能位 hex 残留=0（grep 实证，余仅注释文字）；probe 文件 hex 不在范围（ProbeMainWindow.ets:524 未动）。
- **唯一有意浅色变化**：分类面板双态字色收口（未选中 text_secondary #5B6B79/选中 category_selected_text，ask ③a 点名项）。
- **拆分不变量**：双 DS 经普通成员按引用传 pane（禁 @Prop/@Link）；keyGenerator 恒 record.id；HeaderRow/SortHeaderCell/RowContextMenu 留 Index 经 @BuilderParam `() => void` 闭包注入；五事件处理器/工具栏状态机/防回环逻辑逐字节留 Index（git diff 21 hunk 域定位核对，事件面区间 0 hunk）。
- **UX 三项**：sweepOrphanWaiting 落点=setAdmissionReady(true)（同步 drain）之后、openNextInbox 之前两行调用，仅内存不落库（与源 DownloadList.cs:95/:165 读路径无条件 Stopped 且不回写同构，RecordMapping R2 同构）；onSearchClick 头部 `activeCategoryIndex===0` 早退（对齐源 ApplyFilter index==0 零过滤分支，MainWindow.xaml.cs:158-168）；对比度随语义色+双态字色收口。
- **探针三处同步铁律**：ProbeMainWindow CHECKLIST_TITLES 23 项 / EXPECT S4 total=23 / PROBE 手册 §5 表 23 行，grep 实证 22 计数清零；runS4 发射逻辑零改动（total 取 checkedFlags.length 自适应）。
- **配置零改动**：git status 实证 module.json5/main_pages.json/string.json 不在变更集；零测试文件增删。

## 3. 问题处置表

| 编号 | 严重度 | 位置 | 处置 |
|---|---|---|---|
| R2-F1 | low | 设计书 :19/:33/:76-77/:136-138/:156/:165 与 Index.ets :52/:1654/:1721 | **已处置**（审查状态 unconfirmed→核实属实）：①文档与注释的注入 prop 类型改述为 @BuilderParam `() => void`——根因实证：SDK `ets/component/common.d.ts:28415` `declare type CustomBuilder = (() => any) \| void`，联合含 void 分支使调用点报 10505001 "This expression is not callable. Type 'void' has no call signatures"（首轮 hvigor 编译实证，InProgressPane.ets:55:12 与 FinishedPane.ets:43:12），as-built 修订注记补入设计书拍板 8；②pane 回调清单删去 onHeaderSort（实现中不存在该回调：排序经 headerBuilder 闭包→Index.SortHeaderCell.onClick→Index.onHeaderSort，与拍板 8 一致，原清单自相矛盾）；③:165 同步修正 @Link 传参为 `$searchText`（as-built 实证）；④处置后定向编译复验通过（见④）。处置性质：文档/注释级，零行为面变更 |

## 4. 验证情况

| 项 | 命令/方式（实现者本轮实际运行） | 结果 |
|---|---|---|
| ArkTS 定向编译（@BuilderParam 类型修复后） | `node "D:/Tools/DevEco Studio/tools/node/node.exe" "D:/Tools/DevEco Studio/tools/hvigor/bin/hvigorw.js" --mode module -p module=entry@default -p product=default -p buildMode=debug default@CompileArkTS --incremental` | BUILD SUCCESSFUL in 9s 843ms，0 error（此前同任务 COMPILE RESULT:FAIL {ERROR:3 WARN:93}——两条可见 10505001 均为本修复目标，第三条为 pane 破损类型对 Index 的传导性报错，随修复消失） |
| ArkTS 定向编译（R2-F1 注释处置后复验） | 同上命令 | BUILD SUCCESSFUL in 14s 263ms（CompileArkTS 7s 412ms），0 error |
| 首轮完整构建（脚本侧执行，非本报告运行） | hvigor assembleHap --mode module … | FAIL {ERROR:3 WARN:93}——修复依据（错误行由编排方回贴） |
| 完整 assembleHap 验收构建 | 脚本门禁统一执行 | 门禁结论：hvigor 编译通过；实现者按指令约定未自行运行完整构建，仅运行上述定向 CompileArkTS 任务（非完整构建、非验收口径） |
| 640 单测 | scripts/run-hypium.cjs --expected-tests 640（HYPIUM_GATE.md 四条件） | 门禁结论：测试真值门禁通过；实现者未自行运行；本单元零测试文件增删（git status 实证，expectedTests 数值未触碰） |
| 事件面零破坏 | git diff hunk 域定位核对（Index.ets 21 hunk） | 五事件处理器/buildEngineEvents/recomputeToolbar/五消费点/tabsSyncGuardView 区间 0 hunk=逐字节未动 |
| 静态检查 | devecocli check lint（CategoryPanel/InProgressPane/FinishedPane/VideoCapture 单文件+entry/src/main/ets 目录模式） | 0 error；warning 为既有类别（VideoCapture:172 经 git stash 对照 HEAD:168 同款）或设计强制独立 @Component 的 by-design 提示；Index/ToolbarBar/DownloadListItem 因 codelinter 增量缓存跳过未获 lint 结果（如实记录，ArkTS 合规以编译为准） |
| 资源/探针一致性 | node JSON.parse（color.json×2+EXPECT json）+grep（hex 残留/22 计数/probe import/残句核对） | 三个 json 解析通过；"22 项/total=22/checked=22/1~22/22/22"清零；业务文件 probe import=0 |
| 审查轮次 | 对照审查（R2-F1） | 1 项 low，已处置（见③） |

**无独立复核之说明**：本报告由实现者（编码 Agent）自写自证，未经独立复核人确认。运行时行为面（深浅色切换可读性、事件面人工回归、僵死 Waiting 行清扫时序）未在本轮自动化验证，依赖第 5 节探针走查闭环。

## 5. 遗留问题与待人工事项

1. **探针 OPT-1 待人工运行**：docs/probe/PROBE-opt-1-frontend-polish.md（预期表 docs/probe/EXPECT-opt-1-frontend-polish.json，7 步）——待模拟器运行后回贴日志，经 xdm-probe-verify 工作流核对。其中含 P4-U1 第 23 项深色观测（深浅色切换全界面可读=ask 验收面"深浅色切换后全部界面可读"，未自动化验证）。
2. **"零新 warning" 未做全量基线对比**：首轮失败构建 WARN:93 可见区段全部位于未触碰文件（AdaptiveAssembler/ProbeAdaptive*/ProbeDash* 等）；我方文件 lint 面未见新增类别，但全量 warning 清单与 HEAD 基线的逐条 diff 未执行——最终判定归脚本门禁的完整构建。
3. **既有降级项延续**（MIGRATION_PLAN §3，非本单元引入）：汉堡菜单 9 项/状态栏三触点占位禁用（D5/D12）、子分类 25 缩进不实现、OpenFile/OpenFolder 既有能力面不动。
