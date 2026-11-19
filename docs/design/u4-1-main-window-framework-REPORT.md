# U4.1 主窗口框架 — 单元交付报告

- **单元**：U4.1 主窗口框架（Phase 4 首单元，前置 U3.1）
- **报告日期**：2026-09-29
- **设计书**：`docs/design/u4-1-main-window-framework-DESIGN.md`
- **探针手册 / 预期表**：`docs/probe/PROBE-u4-1-main-window-framework.md` / `docs/probe/EXPECT-u4-1-main-window-framework.json`
- **结论速览**：hvigor 编译门禁**通过**（工作流全量构建通过；本报告会话复跑 `devecocli build --modules entry` → `BUILD SUCCESSFUL`，CompileArkTS UP-TO-DATE）。审查全史 3 项修复已逐条磁盘核实在位；遗留 2 项 medium（handleFinished 幽灵选中、走查项 11 文案矛盾）与 5 项 low 未修，见 §4/§7。运行时走查（探针 P4-U1 + 22 项人工清单）待模拟器人工执行。

---

## ① 单元范围与验收要点

单元定义见 `docs/UNIT_CATALOG.md:63`：双列表（进行中/完成）、分类树、搜索、工具栏；Navigation/NavDestination 路由定案；DownloadListItem + LazyForEach/IDataSource；验收要点=走查清单项可勾、列表流畅。

任务书分解为五项交付：

1. **主窗口升级**：工具栏按钮面 + 分类树/分类计数 + 搜索过滤（对照 Wpf `MainWindow`）；
2. **DownloadListItem 组件化 + LazyForEach/IDataSource**（为大量下载列表性能铺路）；
3. **Waiting 行按钮接通 `manager.stopOne`**（U3.1 复核 F3 死按钮闭环 + D9 排队取消 DB 回声）；
4. **探针 P4-U1** UI 走查观测 + 手册（含 22 项人工走查清单）；
5. **string.json 键骨架**（i18n base 键，D11）。

单元级验收（任务书）：编译过；走查清单可勾；列表结构对照 MainWindow；事件面零破坏。

## ② 研究结论摘要（关键源码行为 → ArkTS 对应表）

研究材料见任务书【研究结论】（本节为落地核对后的摘要；带 ✓ 的行已在本报告会话对目标代码逐行核实）：

| # | 源码行为（对照位置） | ArkTS 落点 | 风险 |
|---|---|---|---|
| 1 | 分类树 1:1：2 顶层（ALL_UNFINISHED/ALL_FINISHED）+ 5 预定义分类（`MainWindow.xaml.cs:74-81`/`:152-195`、`Config.cs:157-221`）；选择语义 index 0/1/>1 三分支；每次切换清搜索框；启动默认 SwitchToFinishedView（ctor:104）；源码分类项无计数 | Index 分类面板 7 项 + `selectCategory` 三分支（Index.ets:380-405 ✓）；默认 `activeCategoryIndex=1`（Index.ets:111 ✓，对齐 D15）；分类计数为鸿蒙增强（D2，`categoryCounts` Index.ets:122 ✓）；Tabs 双向联动（D1，`syncTabsView`/`onTabChange` :407-430 ✓） | low |
| 2 | 搜索只作用已完成列表；匹配=关键词 contains AND 分类扩展名（`Helpers.cs:179-205`、`MainWindow.xaml.cs:158-195`）；触发=搜索按钮/切分类，非实时 | `onSearchClick`→`finishedDS.applyFilter`（Index.ets:443-445 ✓）；进行中列表不接过滤（D13 源码同貌）；TextInput placeholder `$r('app.string.lbl_search')`（string.json:204 ✓） | low |
| 3 | 行契约：进行中行=FileIconText/Name/Size/DateAdded/Progress/Status/Speed/ETA；状态文本 `GenerateStatusText` 四分支合成（`Helpers.cs:210-257`） | `@Observed DownloadRecord` + `core/util/StatusText.ets` 纯函数；状态列单 Text（DownloadListItem.ets:177 ✓，D18） | low |
| 4 | 工具栏状态机：五键先全禁→按视图/选中数/IsDownloadActive 启停；排队也算 active（`AppController.cs:429-478`、`ApplicationCore.cs:562-565`） | `core/util/ToolbarAlgo.ets` `computeToolbarState` + `recomputeToolbar`（Index.ets:488-499 ✓）；`singleIsActive=isLive(id)||isQueued(id)`（:495 ✓ 与源码语义对齐） | medium（多选交互，D3） |
| 5 | 双列表初始 DateAdded desc、列头点击翻转（同列再点反向）、%列头不可排、AddToTop 置顶（`MainWindow.xaml.cs:115-150`/`:453-477`/`:570-594`/`:281-289`） | `core/util/ListAlgo.ets` 比较器 + `DownloadListDataSource`（initialize desc 投影、`addSorted` 插 index 0、`toggleSort`、D9 数据源内排序投影）；表头箭头经 `sortVersion` 刷新（Index.ets:126 ✓） | medium（D9 实现层级差异） |
| 6 | LazyForEach/IDataSource：按可视区按需创建；DataChangeListener 增量通知；BasicDataSource 为指南示例代码非框架模块（devecocli docs 已核实） | `model/BasicDataSource.ets` + `model/DownloadListDataSource.ets`；keyGenerator=record.id；@Observed 字段级刷新零 notifyDataChange（DownloadListItem.ets:12 注释 ✓） | low |
| 7 | Waiting 行死按钮（复核 F3）+ D9 回声修复口径：handleToggle 增 isQueued 分支走 stopOne；stopOne queued 分支不补位；Index 传 `onQueuedCancelled` 补 DB 回声 | `handleToggle` 三分支 isLive/isQueued/else→resumeOne（Index.ets:271-286 ✓，D17）；`buildManagerHooks` 传 `onQueuedCancelled`→`store.updateStatus(Stopped)`（Index.ets:202-213 ✓，D10/D9） | low |
| 8 | 主窗组合：左 190px 分类列表 + 工具栏（New/Delete/OpenFile/OpenFolder/Pause/Resume）+ 搜索框 + 双 ListView（列宽 Name200/DateAdded80/Size60/%50/Status150 等）+ 状态栏 + 汉堡菜单 12 项 + 新建 3 项（`MainWindow.xaml:318-576`） | Index build() Row[分类面板 190（:869 ✓）\| 工具栏/搜索/Tabs 双列表/状态栏]；菜单壳占位禁用（D5）；文件类型图标 SymbolGlyph（DownloadListItem.ets:94-114 ✓，D8）；Navigation 根保留 | low |
| 9 | 窗口事件/方法契约面（`IApplicationWindow.cs:12-133`）：DeleteAllFinishedDownloads 先 Yes/No 确认；ConfirmDelete 出参 approved+deleteFiles；SelectionChanged/CategoryChanged 唯一消费=工具栏重算 | 事件面不建独立对应物（D16，直接同步调 recomputeToolbar）；Delete 简版接线 AlertDialog.confirm（D7）；右键菜单 18 项清单与启用规则记为 U4.2 输入不实现 | low |
| 10 | 平台服务降级点：Save/OpenFileDialog（U5.2 DocumentViewPicker）、PromtForCredentials（U4.2 CustomDialog）、菜单退出=Environment.Exit(0) 无对应 API、媒体嗅探（U6.2） | U4.1 仅保证菜单壳存在，导出/导入/退出/媒体嗅探置禁用并登记降级（D5） | low |

## ③ 设计决策与有意差异（引用 MIGRATION_PLAN 决策条款）

总体依据 `docs/MIGRATION_PLAN.md` **§6 决策 11（UI）**：「按 XDM.Core/UI 的 I*View 接口契约实现 ArkUI 版（第三平台 UI）；@Observed+@ObjectLink 驱动列表进度；LazyForEach + IDataSource；Navigation/NavDestination」——本单元全部落实；**§7 Phase 4** 验收「对照 XDM 走查表逐项勾选」由探针 P4-U1 手册 22 项清单承载。有意差异（任务书【有意差异】D1–D18 全量）：

| 编号 | 差异 | 说明 |
|---|---|---|
| D1 | 分类树 + Tabs 并存双向联动 | 源码内容区纯分类驱动无 Tabs；分类点击联动 Tabs index、Tabs onChange 反向映射（已获授权拍板点；Index.ets:407-430 ✓） |
| D2 | 分类计数为鸿蒙增强 | 口径=未过滤全长（顶层=两数据源 fullCount，子分类=扩展名匹配数），不受搜索过滤影响 |
| D3 | 多选混合方案 | 行点击=单选替换 + 行内复选框=多选开关（源码 WPF Ctrl/Shift 多选；ArkUI List 无原生多选、2in1 修饰键事件面未实测）；工具栏状态机按 selectedCount 消费，>1 分支 1:1 保留 |
| D4 | 分类切换清空当前视图选中 | 源码仅清搜索框；防过滤后不可见选中态（Index.ets:402 ✓） |
| D5 | 菜单壳占位禁用 | 汉堡 12 项/新建 3 项壳占位（动作 U4.2 接线）；导出/导入待 U5.2、退出无对应 API、媒体嗅探待 U6.2 |
| D6 | OpenFile/OpenFolder 状态机 1:1 渲染 | 点击动作占位（文件打开能力面待 U5.2） |
| D7 | Delete 简版接线 | AlertDialog.confirm→live 行先 stopOne 不删行、非 live 行 store.remove+行移除；完整 DeleteDownloads 链 U4.2 接 |
| D8 | 图标/日期载体平台化 | IconMap 映射规则 1:1 但 Vector Path→SymbolGlyph（首字母 Text 兜底）；DateAdded StringFormat=d→'YYYY-MM-DD' |
| D9 | 排序实现层级差异 | WPF CollectionView 视图排序→数据源内排序投影；可观测行为对齐（初始 desc、首击升序、%列不可排、新项置顶） |
| D10 | 行级 toggle 按钮为鸿蒙既有增强 | Waiting 行标签='取消排队'（btn_cancel_queue 新键，string.json:324 ✓）；U3.1 复核 F3 闭环 + D9 回声接通（Index.ets:202-213 ✓） |
| D11 | i18n 仅 base 键骨架 | 值=英文源文案原值；zh_CN/en_US 与语言切换 U4.3；分类顶层复用 lbl_active/lbl_complete（string.json:120/:124 ✓） |
| D12 | 状态栏三触点占位禁用 | 浏览器监视（U5.x）、Queue and scheduler（U4.2）、Help |
| D13 | 搜索触发点/作用域源码同貌 | 搜索按钮点击/分类切换触发、进行中列表不接过滤——FilterByKeyword 在 MainWindow 未接线，非遗漏 |
| D14 | 工具栏无「全部暂停」按钮 | 任务书提及但源码钮集无此键，按源码执行 |
| D15 | 启动默认视图=已完成 | 源码 ctor:104 SwitchToFinishedView；对齐修正 U1.2 现状默认进行中（Index.ets:111 ✓，对齐非差异） |
| D16 | 事件面不建独立对应物 | AppController 中唯一消费即工具栏重算，ArkTS 直接同步调；右键菜单 18 项清单记为 U4.2 输入 |
| D17 | handleToggle 三分支 | isLive→stopOne / isQueued→stopOne / else resumeOne（Index.ets:271-286 ✓）；resumeOne 幂等 return 的死态不复现 |
| D18 | %列保留 ProgressBar 高 5 模板 | xaml:640-647 同构；行内不另画全宽进度条（U1.2 卡片遗形移除，列结构对照 MainWindow） |

配置项核查（任务书硬性要求）：`entry/src/main/module.json5` deviceTypes 含 `2in1`（:9 ✓）、已配 `ohos.permission.INTERNET`（:16 ✓）；本单元无新增能力面（UI 单元，无网络以外权限诉求）；页面路由保持 Navigation 根（Index.ets:106 NavPathStack 预留 ✓），main_pages.json 约束不涉及新增页面。

## ④ 审查问题处置表（覆盖全部轮次）

对照审查两轮（round 2：5 findings、round 4：4 findings，均 approved=false）、独立复核一轮（7 findings，acceptable=true）。同项跨轮沿用编号归并；「处置证据」列均为**本报告会话在当前代码上逐条核实**（读取/检索原文），非转抄。

| 归并编号 | 轮次编号 | 严重度 | 问题（位置） | 处置 | 处置证据（本会话核实） |
|---|---|---|---|---|---|
| A1 | R2-F1 | high | 探针 S1 `initOrder` 期望值 `c/b/a` 与自身论证/实现矛盾（DateAdded desc 投影必为 c/a/b），机械判定必 FAIL | **已修复**（期望统一改 c/a/b） | EXPECT-u4-1-main-window-framework.json:13、PROBE 手册 :138/:149、设计书 :419/:468 全部为 `initOrder=c/a/b`，五处一致 |
| A2 | R2-F2 → R4-F1 | medium | Checkbox 点击冒泡未隔离：点击会同时触发行 onSelect→clearSelection+单选替换，破坏多选路径（走查项 13）；程序化 .select 回写可致选中态振荡。R4 修法修正：`e.stopPropagation()` 对 onClick 回调不可达（ClickEvent 无该方法，SDK common.d.ts:11608 区段仅属性） | **已修复**（结构性隔离 + 守卫） | DownloadListItem.ets：onSelect 挂内容区 Row（:185-187），Checkbox 独立列（:136-147）不在其内、外层行无 onClick；onChange 守卫 `if (value === this.record.uiSelected) return`（:141-143）；:127-132 注释记录 stopPropagation 不可达与隔离方案。实现轮对该文件 lint 报 No defects found（实现轮执行，非本会话复跑） |
| A3 | R2-F3 = R4-F2 = 复核-F4 | low | `'.ApplicationContext.Core'` 键源码因大小写永不命中（落 Other），实现小写后可命中 CAT_PROGRAMS——quirk 被修正且注释「保留保真」与行为相悖 | **未修（接受，登记）** | CategoryAlgo.ets:110 键为小写 `.applicationcontext.core`；:15 头注释仍写「源码原貌移植…保留保真」。注释与行为不一致仍存在，建议按复核建议改为「有意修正 quirk」（U4.2 顺手项） |
| A4 | R2-F4 = R4-F3 = 复核-F5 | low | 分类面板未选中项复用 `ROW_SELECTED_BG='#E3F2FD'`（与行选中高亮同值同名），与选中色 `#D6E4F5` 同为蓝色系对比弱（走查项 1 辨识度差） | **未修（接受，登记）** | Index.ets:100 常量、:863 未选中分支仍用 ROW_SELECTED_BG；DownloadListItem.ets:39 已有同值语义正确的 `ROW_NORMAL_BG='#F5F6F8'` 可复用 |
| A5 | R2-F5 = R4-F4 = 复核-F6 | low | 分类 0（进行中视图）下点搜索仍对 finishedDS 以 (keyword, null) 覆写过滤器——源码 ApplyFilter 的 index==0 分支不触碰 lvFinished 的 Filter（不可观测但属源码没有的状态写入） | **未修（接受，登记）** | Index.ets:443-445 `onSearchClick` 无 activeCategoryIndex===0 早退分支 |
| B1 | 复核-F1 | **medium（新）** | handleFinished 迁移行不清选中：不从 selectedIds 摘 id、不清 uiSelected、不 recomputeToolbar——幽灵选中（WPF 侧 ObservableCollection 移除会经 SelectionChanged 清选）。后果链：选中行下载完成→工具栏 Delete 仍启用→deleteSelectedRows 走非 active 分支 store.remove，把刚完成记录静默从 DB+双数据源删除；stale Resume 对 finished 记录重新起跑 | **未修（遗留，最高优先）** | Index.ets:352-373 handleFinished 仅有字段写+removeById+addSorted+recomputeCounts+markAsFinished，无任何选中清理；对照 :448-458 selectRow/:477-483 clearSelection |
| B2 | 复核-F2 | **medium（新）** | 走查项 11 期望「再点同行取消选中」与实现（selectRow=clearSelection 后无条件重选同行，Index.ets:448-458 ✓）及 WPF 源语义（单击已选中项不取消）三方矛盾——S4 机械验收将恒报项 11 未勾或误导走查者误勾 | **未修（遗留）** | 三处文案仍在：ProbeMainWindow.ets:72（CHECKLIST_TITLES[10]）、PROBE-u4-1-…md:116、设计书 :440 |
| B3 | 复核-F3 | low（新） | 杀进程残留 DB 的僵死 Waiting 行（不在 manager 队列）：按钮标签按 status=Waiting 显示「取消排队」，但 handleToggle isLive/isQueued 均假→落 resumeOne→实际开始下载，标签与动作错位 | **未修（登记 U4.2 输入）** | Index.ets:271-286 三分支只判 manager 状态不判行 status；DownloadListItem.ets:73-75 标签按行 status 分派 |
| B4 | 复核-F7 | low（新，注释漂移） | DownloadManager.ets 头注释仍称「Index 本单元不传（UI 无排队取消触点）」，与本单元 Index 传 onQueuedCancelled 矛盾（U3.1 旧注释；本单元 engine 文件零改动红线所致） | **未修（U4.2 顺手更正）** | DownloadManager.ets:34 vs Index.ets:202-213（buildManagerHooks 确已传钩子） |

**处置汇总**：已修复 3 项（A1 high、A2 medium×2 轮次）；未修 7 项——medium 2（B1、B2）、low 5（A3、A4、A5、B3、B4）。已修复问题编号台账（R2-F1、R2-F2、R4-F1）与上表一致。

**材料间矛盾澄清（以磁盘与门禁为准）**：
1. **探针文件命名漂移**：任务材料【实现文件】清单与审查引用写 `PROBE-p4-u1-…`/`EXPECT-p4-u1-…`；磁盘实际为 `PROBE-u4-1-main-window-framework.md`/`EXPECT-u4-1-main-window-framework.json`（目录清单核实；EXPECT 内 `unitId=P4-U1`、`slug=u4-1`）。系文件重命名后文档引用未同步，不影响内容；后续引用以 u4-1 名为准。
2. R4-F1 修复说明与 round 4 审查快照冲突：审查行号引用系修复前快照，当前代码两项修法已在位（A2 证据）。

## ⑤ 验证情况

| 验证项 | 结论 | 证据 |
|---|---|---|
| hvigor 编译门禁（工作流） | **通过** | 任务书【门禁结论】：`devecocli build --modules entry` 全量构建最终状态通过 |
| hvigor 编译（本报告会话复跑） | **通过**（增量） | `cd D:/git/HarmonyPC/XdmHarmony && devecocli build --modules entry` → `BUILD SUCCESSFUL in 587 ms`，`CompileArkTS` UP-TO-DATE（自门禁全量构建后源码零变更，缓存命中即当前树可编译）。附 WARN：无 signingConfigs，`Will skip sign 'hos_hap'`（见 §7）。注：首次在错误工作目录执行报 `Not in a valid project directory`，非构建失败，纠正后重跑 |
| codelinter 辅助（门禁执行，本会话未复跑） | exit 0，提示性 | Summary: Issues 18 \| Errors 0 \| Warnings 16 \| Suggestions 2 \| Files checked 4；可见条目为 `@performance/hp-arkui-set-cache-count-for-lazyforeach-grid`（Index.ets:815 等，LazyForEach cachedCount 建议）——不阻断（§7 遗留） |
| 对照审查（round 2 + round 4） | approved=false；3 项修复落地、3 项低危未修 | §4 表 A1–A5；修复项均经本会话磁盘核实 |
| 独立复核 | acceptable=true；2 medium + 5 low 新发现/延续 | §4 表 B1–B4；weakestSpot=选中态生命周期（B1） |
| ArkTS 合规 | 编译期强制通过 | codelinter 不含 ArkTS 语法规则，严格子集由 hvigor 编译期强制——本会话复跑 `CompileArkTS` UP-TO-DATE 即当前代码通过编译期 ArkTS 检查 |
| 配置项 | 符合 | module.json5 deviceTypes 含 2in1（:9）、ohos.permission.INTERNET（:16）；string.json 关键键在位（lbl_search:204、btn_cancel_queue:324、lbl_active:120、lbl_complete:124、stat_waiting:236、menu_batch_download:264） |
| 运行时走查（探针 P4-U1 + 22 项清单） | **未执行**（待人工） | 见 §6；走查项 11/13 运行时复核需真机/模拟器，本环境未运行 |

## ⑥ 运行时验证待办（探针）

探针 **P4-U1** 已生成，待人工在模拟器运行后回贴日志，用 **xdm-probe-verify** 工作流核对：

- **手册**：`docs/probe/PROBE-u4-1-main-window-framework.md`（§5=22 项人工走查清单，项号→差异锚速查见预期表 S4 note）
- **预期表**：`docs/probe/EXPECT-u4-1-main-window-framework.json`（7 步骤行：BEGIN/S1/S2/S3/S4/SUMMARY/END）
- **操作次序（预期表 sessions 字段）**：①主页面按手册 §5 人工走查 22 项 → ②探针页点「运行全部」（主会话 S1→S4 自动跑，恰 7 行日志）→ ③回探针页勾 22 项清单 → 点 S4「执行」（单步迷你会话，恰 4 行）。运行次序红线：探针会话内不切页。
- **环境前提**：S3 需主机侧先启动 `node docs/probe/P1-U2-download-server.js`（零改动复用 U1.2 慢源，ms=300 由探针 URL 参数携带）；S1/S2/S4 无需测试源。
- **验收锚**：S4 末次 runId `checked=22 total=22 unchecked=none`；S3 `queuedCancelEcho=1`、`startedCount=1`（排队取消不补位，F3/D9 闭环证据）；S1 `initOrder=c/a/b`。
- **已知偏差预警**：走查项 11 清单文案含无法满足的期望（§4 B2）——人工走查到项 11 时按实际情况记录，勿按错误文案勾选；S4 机械判定预期将因该项报 unchecked，属 B2 文案问题而非代码缺陷。

## ⑦ 遗留问题与风险

按优先级：

1. **B1（medium）handleFinished 幽灵选中**：全单元最薄弱点（独立复核 weakestSpot）；「选中行下载中→完成→点工具栏 Delete」会静默删刚完成记录、「选中→完成→Resume 仍启用」会对 finished 记录重新起跑。模拟器走查最可能复现的行为偏差。**建议人工验收前修**（改动 ~5 行，见 §8-1）。
2. **B2（medium）走查项 11 文案矛盾**：不修则 S4 机械验收恒报 1 项 unchecked；三处（探针清单字符串/手册/设计书）须同步改。
3. **A3/A4/A5（low×3，审查三轮延续未修）**：quirk 注释与行为不一致、分类面板未选中底色、分类 0 搜索覆写过滤器。均为可观测性极低/纯视觉项，接受并登记；A4 修法=复用 DownloadListItem 的 `ROW_NORMAL_BG`。
4. **B3（low）僵死 Waiting 行标签/动作错位**：kill-while-queued 场景；登记 U4.2 输入。
5. **B4（low）DownloadManager.ets:34 注释漂移**：U4.2 触及 engine 红线解除时更正。
6. **codelinter 16 条 Warning（LazyForEach cachedCount 建议）**：大量下载（走查项 21 流畅性）场景前评估 `.cachedCount()` 取值；提示性不阻断。
7. **签名未配置**：构建 WARN `Will skip sign 'hos_hap'`——真机安装前需在 build-profile.json5 配 signingConfigs（模拟器不受阻）。
8. **文档一致性**：探针文件 p4-u1→u4-1 重命名后，任务材料【实现文件】清单与审查引用中的旧名未同步（§4 矛盾澄清-1）。
9. **多选交互（D3）依赖结构隔离**：2in1 物理键盘 Ctrl+Click 修饰键事件面仍未实测（任务书 openQuestions 遗留）；D3 混合方案已使多选路径不依赖修饰键，风险受控。

## ⑧ 对下个单元（U4.2 对话框包）的建议

1. **进 U4.2 首个提交先修 B1**：handleFinished 在 removeById 后补选中清理（`selectedIds.delete(id)` + `record.uiSelected=false` + `selectedCount` 同步 + `recomputeToolbar()`，或直接 `clearSelection()+recomputeToolbar()`），对齐 WPF 移除即清选中语义；随后**同步修 B2**（走查项 11 文案三处统一为「再点同行保持选中（WPF 单击同貌，取消经复选框或切换分类）」，或如需再点取消则改 selectRow 为 toggle 并登记差异）。
2. **U4.2 输入（研究结论已备）**：右键菜单 18 项清单与启用规则（`AppController.cs:730-791` InProgress/FinishedContextMenuOpening）；完整 DeleteDownloads 链（ConfirmDelete 的 approved+deleteFiles 出参、文件清理，`MainWindow.xaml.cs:316-327`）；菜单 12 项/新建 3 项动作接线（D5 占位逐项点亮：SettingsClicked、ClearAllFinishedClicked→AlertDialog.confirm+`store.removeAllFinished`（API 名编码时核对）、SchedulerClicked、帮助/更新双态 `:662-672`）；PromtForCredentials→CustomDialog（`WpfPlatformUIService.cs:153-163`）。
3. **B3**：僵死 Waiting 行处理二选一（toggleLabel 改由 Index 传 isQueued，或启动时把 DB 中非排队 Waiting 行归一为 Stopped）。
4. **B4**：DownloadManager.ets:34 注释更正（engine 文件改动红线在 U4.2 不再适用时）。
5. **导出/导入**保持禁用待 U5.2 DocumentViewPicker；媒体嗅探壳待 U6.2 NavDestination（D5 降级登记延续）。
6. 若走查发现大列表卡顿，先落 codelinter 建议的 `.cachedCount()` 再谈结构改动。

## ⑨ 提交说明

- **代码未做 git 提交**：本单元全部产物处于工作区待验收态（`git status --porcelain`：6 个修改 + 14 个新增未跟踪文件；HEAD=`4e29314` 台账 U3.2 完成回填/U4.1 启动）。待人工验收（含 §6 探针运行 + 22 项走查）通过后由人提交，并按 Phase 打 tag（Phase 4 末统一 `phase-4`）。
- 流程备注：`docs/UNIT_CATALOG.md:19` 的默认节奏为「AI 每单元完成即 git 提交（单元粒度回滚点）」；本单元按任务书指示改为验收后提交，与本目录默认不同，特此说明。
- 对照源码只读约束：`resourses/`（XDM 2023 源码）在本单元全程未编辑、未创建、未删除任何文件（本报告会话仅读取目标工程文件与文档，未写入 resourses/）。
