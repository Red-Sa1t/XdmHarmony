# U4.1 主窗口框架 · 模块设计书

> 单元：U4.1（Phase 4 第 1 单元；探针单元 ID `P4-U1`，slug `u4-1-main-window-framework`）。
> 来源：xdm-migrate 工作流"模块设计师"角色，2026-09-29。
> 依据：MIGRATION_PLAN §5（pages/components/model 落点）+ §6 决策 11（@Observed+@ObjectLink 驱动列表、LazyForEach+IDataSource、Navigation/NavDestination）；UNIT_CATALOG U4.1 行（验证 [A]+[P]走查，验收要点"走查清单项可勾；列表流畅"，前置 U3.1）；PROBE_SPEC v1；源码研究结论（10 facts + 2 openQuestions）。
> 对照源码（本会话只读核实，未改 resourses/ 下任何文件）：`XDM.Wpf.UI/MainWindow/MainWindow.xaml.cs`（:74-81 分类构造 2 顶层+5 预定义、:104 `SwitchToFinishedView()` 启动默认完成视图、:115-150 双列表初始 DateAdded desc 排序、:152-195 `lvCategory_SelectionChanged`/`ApplyFilter`（清搜索框→过滤→CategoryChanged→SelectionChanged）、:281-294 `AddToTop`=Append 非插首、:453-477/:570-594 列头点击排序（首击升序、同列再点降序、无 Tag 直接 return））；`MainWindow.xaml`（:318-447 工具栏钮集 BtnNew/BtnDelete/BtnOpen(Collapsed)/BtnOpenFolder/BtnPause/BtnResume、:448-493 搜索框宽 100+placeholder+搜索钮、:494-503+59-87 BtnMenu 汉堡菜单 12 项、:508-576 状态栏（监视文案+toggle 图标+Queue and scheduler+Help）、:590-650 进行中列模板 Name200[图标 24×24+名]/DateAdded80(StringFormat=d)/Size60/%50(**ProgressBar 高 5**)/Status150(**DisplayMemberBinding=StatusText 单文本**)、:650-712 完成列模板 Name400/DateAdded80/Size60）；`XDM.Core/Config.cs:157-221`（DefaultCategories 5 项扩展名集合逐串核实）；`XDM.Core/Util/Helpers.cs:179-257`（IsMatchesKeyword/IsOfCategoryOrMatchesKeyword/IsOfCategory/GetStatusText/GenerateStatusText）；`XDM.Core/AppController.cs:429-478`（UpdateToolbarButtonState 五键重算状态机）+ `ApplicationCore.cs:40/:562-565`（ActiveDownloadCount/IsDownloadActive=live||queued）；`XDM.Core/UI/IApplicationWindow.cs:12-138`（事件/方法契约面+CategoryChangedEventArgs）；`XDM.Core/UI/IconMap.cs:9-57`（imageTypes 分类键映射+GetVectorNameForFileType/Category）。
> 工程现状核实（本会话读文件）：`pages/Index.ets`（Tabs 双列表 U1.2+manager 接入 U3.1；:120/:204 unshift/splice 直改 @State 数组=本单元替换点；:132-143 handleToggle 无 isQueued 分支=复核 F3 死按钮根源；:289-299/:317-327 ForEach 渲染；:348-393 DownloadListItem 内嵌同文件）；`core/engine/DownloadManager.ets`（:35-37 ManagerHooks.onQueuedCancelled 已备、:205-227 stopOne queued 分支不补位+回声、:182-198 resumeOne 幂等 return）；`core/db/DownloadStore.ets`（add/updateProgress/updateStatus/markAsFinished/updateDownloadEntry/remove/getDownloadById/queryAll/queryInProgress/queryFinished——**无 removeAllFinished**，清除已完成 U4.2 另议）；`model/DownloadRecord.ets`（@Observed 16+2 字段+工厂）；`model/DownloadTypes.ets`（DownloadStatus 四值 :18-23）；`core/util/Formatting.ets`（formatSize/formatSpeed/toHMS，无 formatDate）；`probe/core/ProbeKit.ets`（begin/emit/end/isCurrent）、`probe/core/ProbePage.ets`（:25-28 ProbeStepDef、:35-42 props=unitId/pageTitle/steps/autoStart/runStep、:120 runSingle 单步迷你会话）、`probe/units/ProbeQueue.ets:419-421`（**ManagerHooks 类型化对象字面量装配先例**）、`probe/ProbeIndex.ets`（PROBE_UNITS 注册表+else-if）；`main_pages.json`（仅 Index+ProbeIndex）；`module.json5`（deviceTypes ["phone","2in1"]+INTERNET 已具备）；`resources/base/element/string.json`（lbl_active=Active/lbl_complete=Complete 已有——与源键 ALL_UNFINISHED/ALL_FINISHED 同值）。
> API 面核实（本会话执行 `devecocli docs`）：LazyForEach 两签名（options 形态 **API 26+ 且必须同供 keyGenerator 否则编译失败**——本工程 API 24 不用 options 形态）；IDataSource 四方法 totalCount/getData/registerDataChangeListener/unregisterDataChangeListener（API 11+）；getData 应避免耗时操作。SymbolGlyph 仅支持系统预置 Symbol 资源名（本地 SDK 无 sys.symbol 名表——`hm_symbol_config_next.json` 仅含 glyph 层分组无名称映射，本会话实测确认），具体资源名编码时在 DevEco 内核实（无效名编译期资源错误暴露），一律配首字母 Text 兜底。

## 0. 冲突与拍板注记（必读）

1. **openQuestion 2 拍板：保留 Tabs + 分类树双向联动（结构差异已获授权）**。源码内容区由分类列表独占驱动（无 Tabs）。ArkTS 侧保留 U1.2 既有 Tabs 作双列表容器，分类点击联动 Tabs index（分类 0↔Tab 进行中；分类 ≥1↔Tab 已完成）；Tabs onChange 反向映射分类（index0→分类 0；index1→分类 <1 时置 1，>1 时保持子分类不动）。程序化同步与用户点击用 guard 布尔防回环。差异登记 §4-D1。
2. **openQuestion 1 拍板：多选交互=行点击单选替换+行内复选框多选的混合方案**。WPF Ctrl/Shift 多选依赖修饰键，ArkUI List 无原生多选、2in1 物理键盘 Ctrl+Click 事件面未实测。交互：行体点击=单选（Set 替换为 {id}，对照 WPF 单击选择语义）；行内 Checkbox=多选开关（toggle Set 成员资格）。工具栏状态机只消费 selectedCount——>1 分支（Pause+Resume 同启）经复选框可达，状态机本体 1:1。选中态载体=DownloadRecord.uiSelected（@Observed 字段驱动行内高亮/勾选刷新，LazyForEach 下免 notifyDataChange）。差异登记 §4-D3。
3. **分类计数口径拍板（鸿蒙侧增强，源码无计数）**：计数=未过滤全长（不受搜索过滤影响）——顶层 0=进行中数据源 fullCount、顶层 1=完成数据源 fullCount、子分类 i=完成数据源中扩展名∈分类集合的行数。每次结构性增删/迁移/删除后重算。差异登记 §4-D2。
4. **启动默认视图对齐源码（修正非差异）**：源码 ctor:104 `SwitchToFinishedView()`——启动默认"已完成"（分类 index 1）。现状 Index 默认进行中，本单元对齐为默认 index 1。走查表按此写（§6 走查项 1）。
5. **工具栏"全部暂停"按钮不存在**：源码钮集=New/Delete/OpenFile/OpenFolder/Pause/Resume（MainWindow.xaml:318-447 逐钮核实，任务书"新建/暂停/继续/删除/全部暂停等"中的"全部暂停"无源码锚），按源码钮集执行，不新增按钮。差异登记 §4-D14。
6. **工具栏动作接线深度（超出"按钮面"的最小接线，有意为之）**：U4.1 接线=New（既有对话框）+Pause/Resume（对选中集合逐 id 调 stopOne/resumeOne，与行按钮同路径，零新引擎面）+Delete 简版（AlertDialog.confirm→live 行先 stopOne 不删行、非 live 行 store.remove+DS removeById）；OpenFile/OpenFolder 状态机 1:1 渲染但点击动作占位（业务日志，U5.2 能力面）。完整 DeleteDownloads 链（ConfirmDelete 对话框 approved+deleteFiles 出参、文件清理）U4.2 接。差异登记 §4-D6/D7。
7. **事件面零破坏红线（承 U2.x/U3.1）**：Downloader.ets/DownloadManager.ets 零改动（F3 修复只动 Index 消费方——hooks 机制 U3.1 已备）；buildEngineEvents 与五事件消费方（handleStarted/Connected/Progress/Paused/Failed）逻辑逐字节保留；handleFinished 仅把 splice/unshift 换 DS 调用；@Observed 字段单写者仍是 Index（行组件 @ObjectLink 只读渲染）。
8. **module.json5 / main_pages.json 不动（有据，非遗漏）**：本单元无新系统能力（纯 UI+既有 manager/store 消费；INTERNET 已有、deviceTypes 2in1 已有）；探针经 ProbeIndex 嵌入不注册路由（U2.1 §0-9 同口径；main_pages 红线"只保留 Index 与探针页"已满足）。两文件不列入 files 清单。
9. **纯函数层纪律（承 U2.3/U3.1）**：StatusText/CategoryAlgo/ListAlgo/ToolbarAlgo 四文件零 import（含 @kit），Hypium 本地单测直接加载。ArkTS 无结构化类型——DownloadRecord 需 `implements SortableRow` 才可入 compareRows/sortedInsertIndex（model→util 单向依赖，无环）。
10. **i18n 只建 base 键骨架（本单元）**：40 键值取源文案英文原值（English.txt 逐键核实）；zh_CN/en_US 与语言切换 U4.3；分类顶层两项复用既有 lbl_active/lbl_complete（同值键不重复建，源键名 ALL_UNFINISHED/ALL_FINISHED 注释锚明）；行按钮/工具栏从中文/英文字面量切换到 $r 引用（触面内全量，未触面不动）。
11. **manager.init 后到者接管与走查次序**：探针 P4-U1 S3 会 init 接管事件袋——手册规定次序=先主页面人工走查（勾选清单）→进探针页跑"运行全部"（S1~S3 auto）→回探针页勾选 S4 清单并单步执行（§6）。

## 1. 目标文件清单（按实现顺序）

| # | 文件 | 新/改 | 职责 | 对外导出 | 依赖 |
|---|---|---|---|---|---|
| 1 | `entry/src/main/ets/core/util/StatusText.ets` | 新 | 状态列文本合成纯函数（Helpers.cs:243-256 GenerateStatusText 逐分支移植） | `StatusLabels`（interface：downloading/stopped/finished/waiting 四标签）、`generateStatusText(status, speed, eta, labels)` | 无（零 import） |
| 2 | `entry/src/main/ets/core/util/CategoryAlgo.ets` | 新 | 分类纯函数层：`fileExtensionOf`（Path.GetExtension 语义）、`CategoryDef`（name/displayName/fileExtensions 大写集/defaultFolderName/isPredefined）、`DEFAULT_CATEGORIES`（Config.cs:157-221 五项逐串）、`isOfCategory`、`isOfCategoryOrMatchesKeyword`（Helpers.cs:190-205）、`iconCategoryKeyForExtension`（IconMap.cs:9-42 imageTypes 移植） | 上述六导出 | 无（零 import） |
| 3 | `entry/src/main/ets/core/util/ListAlgo.ets` | 新 | 列表排序纯函数层：`SortableRow`（interface：id/name/dateAdded/size）、`SortKey`（'Name'\|'DateAdded'\|'Size'）、`compareRows(a,b,key,desc)`、`sortedInsertIndex(rows,row,key,desc)`（前向线性扫，dateAdded desc 下新项 O(1) 命中 index 0）、`nextSortDirection(curKey,curDesc,clickedKey)`（:453-477 同列翻转语义） | 上述五导出 | 无（零 import） |
| 4 | `entry/src/main/ets/core/util/ToolbarAlgo.ets` | 新 | 工具栏按钮状态机纯函数（AppController.cs:429-478 逐分支移植）：`ToolbarState`（class，@State 可装配：六 enabled+四 visible）、`computeToolbarState(inProgressViewSelected, selectedCount, singleIsActive)` | `ToolbarState`、`computeToolbarState` | 无（零 import） |
| 5 | `entry/src/main/ets/model/DownloadRecord.ets` | 改 | ①类声明 `implements RecordData, SortableRow`（ArkTS 无结构化类型，§0-9）②追加 UI 会话字段 `uiSelected: boolean = false`（选中高亮/复选框渲染态，不落库不入 RecordData，行组件经 @ObjectLink 观察刷新） | 既有导出不动 | #3 |
| 6 | `entry/src/main/ets/model/BasicDataSource.ets` | 新 | IDataSource 基类（开发指南 BasicDataSource 同构，ArkTS 类型标注）：监听器数组+notifyDataAdd/notifyDataDelete/notifyDataChange/notifyDataReloaded 四通知面 | `BasicDataSource<T>`（泛型类，implements IDataSource） | 无（IDataSource/DataChangeListener 为 ArkUI 环境类型） |
| 7 | `entry/src/main/ets/model/DownloadListDataSource.ets` | 新 | 双列表数据源（WPF ObservableCollection+CollectionView 同构，§3.5）：records 全量数组+visible 排序过滤投影；`initialize(records)`（dateAdded desc）、`addSorted(record)`（Append 全量+投影按序插入+notifyDataAdd）、`removeById(id)`、`applyFilter(keyword, category)`/`clearFilter()`（notifyDataReloaded）、`toggleSort(key)`、`getRecordById(id)`、`fullCount()`、`countByExtensions(exts)`、`sortState()` | `DownloadListDataSource`（extends BasicDataSource<DownloadRecord>） | #2 #3 #5 #6 |
| 8 | `entry/src/main/ets/core/util/Formatting.ets` | 改 | 追加 `formatDate(ms)`（epoch 毫秒→'YYYY-MM-DD'；源 StringFormat=d 文化相关，差异 §4-D8） | 追加 `formatDate` | 无 |
| 9 | `entry/src/main/ets/components/DownloadListItem.ets` | 新（自 Index.ets:348-393 抽出重写） | 行组件：Row 网格行布局（Checkbox+FileTypeIcon 24×24+名称/日期(formatDate)/大小(formatSize)/% 列(Progress 高 5，仅进行中)/状态列(**generateStatusText 单 Text**，仅进行中)/行按钮）；列宽 flex 与表头行对齐（§5.9）；单选/多选回调 | `DownloadListItem`（@Component，@ObjectLink record + showToggle/onSelect/onToggleSelect/onToggle/labels props） | #1 #2 #5 #8 |
| 10 | `entry/src/main/ets/pages/Index.ets` | 改（本单元主改造，§5.10 改动面） | 主窗口升级：Row[分类面板 7 项+计数 \| Column[工具栏钮面、搜索行、Tabs 双列表(LazyForEach+表头排序行)、状态栏]]；分类/搜索/选中三状态；hooks 回声接线；F3 修复 | —（@Entry 页） | #2 #4 #7 #9 |
| 11 | `entry/src/test/StatusText.test.ets` | 新 | generateStatusText 8 用例（§7-[A]-2） | `statusTextTest` | #1 |
| 12 | `entry/src/test/CategoryAlgo.test.ets` | 新 | 分类 12 用例（§7-[A]-2） | `categoryAlgoTest` | #2 |
| 13 | `entry/src/test/ListAlgo.test.ets` | 新 | 排序 8 用例（§7-[A]-2） | `listAlgoTest` | #3 |
| 14 | `entry/src/test/ToolbarAlgo.test.ets` | 新 | 状态机 7 用例（§7-[A]-2） | `toolbarAlgoTest` | #4 |
| 15 | `entry/src/test/List.test.ets` | 改 | testsuite 注册四套件 | —（测试入口） | #11~#14 |
| 16 | `entry/src/main/resources/base/element/string.json` | 改 | **键骨架 +40 键**（§2.5；纯 JSON 禁尾逗号；值=源文案英文原值） | —（资源） | #9 #10 #17 |
| 17 | `entry/src/main/ets/probe/units/ProbeMainWindow.ets` | 新 | P4-U1 探针页（§6 四步）：S1 数据源行为/S2 纯函数面/S3 排队取消回声链（auto）+S4 人工走查清单（manual，22 项 Toggle 勾选发射） | `ProbeMainWindow`（struct） | #2 #4 #7、../core/ProbeKit+ProbePage、../../core/engine/DownloadManager、../../core/db/DownloadStore、../../core/Config、../../model/DownloadRecord、../../core/util/StatusText+ListAlgo+ToolbarAlgo |
| 18 | `entry/src/main/ets/probe/ProbeIndex.ets` | 改 | PROBE_UNITS 追加 `{unitId:'P4-U1'}` + else-if 追加 `ProbeMainWindow()` | —（@Entry 页） | #17 |
| 19 | `docs/probe/PROBE-u4-1-main-window-framework.md` | 新 | 探针运行手册：**人工走查清单 22 项对照表**（§6 走查清单）+ 先走查后探针次序 + 测试源指引 | —（文档） | #17 |
| 20 | `docs/probe/EXPECT-u4-1-main-window-framework.json` | 新 | 机器可读预期表（BEGIN+S1~S4+SUMMARY+END；schema 同 EXPECT-u3-1） | —（JSON） | #19 |

**显式不动的文件**：`module.json5`/`main_pages.json`（§0-8）；`core/engine/Downloader.ets`/`core/engine/DownloadManager.ets`（事件面与 hooks 机制零改动——F3 修复只在 Index 消费方）；`components/NewDownloadDialog.ets`（onConfirm 签名不变）；`core/db/DownloadStore.ets`（remove 已备，不加 removeAllFinished——清除已完成 U4.2）；`core/engine/PieceGrabber.ets`/`SegmentWorker.ets`/`QueueAlgo.ets`/`Scheduler.ets`/`SpeedLimiter.ets`；`core/net/HttpClient.ets`；`entryability/EntryAbility.ets`；既有 probe/units 十一文件（归档不追改）。**红线**：`core/**` 与 `model/**` 不得 import `probe/**`；Index/组件/数据源零 `[XDM_PROBE]` 输出（业务日志 hilog domain 0x0000）；业务页面禁 import probe/**（审查规则，双向）。

## 2. 数据模型与表结构（对照源码逐一核对）

### 2.1 行契约映射（IInProgressDownloadRow.cs:10-29 / IFinishedDownloadRow.cs:10-21 → DownloadRecord）

| 源行字段 | DownloadRecord 字段 | 核对锚 | 本单元消费 |
|---|---|---|---|
| FileIconText | name 派生（CategoryAlgo.iconCategoryKeyForExtension(fileExtensionOf(name))） | IconMap.cs:44-57 | 行首图标 24×24（§4-D8 载体差异） |
| Name | name | :12 | 名称列 |
| Size(long) | size | IInProgressDownloadRow.cs:14 | 大小列（formatSize，对照 FileSizeValueConverter） |
| DateAdded | dateAdded（epoch 毫秒，U1.1-D1） | :16 | 日期列（formatDate）+默认排序键 |
| Progress(0-100) | progress | :18 | % 列 ProgressBar 高 5（xaml :640-647 模板同构） |
| Status | status（DownloadStatus 四值 DownloadTypes.ets:18-23） | DownloadEntries.cs:64-67 | 状态列合成（§3.4）+行按钮标签 |
| DownloadSpeed(string?) | downloadSpeed（UI 派生非持久化） | :22 | 状态列合成原料 |
| ETA(string?) | eta（同上） | :24 | 状态列合成原料 |
| 完成行四字段 | 同模型 kind=Finished 分型（U1.1-D4） | IFinishedDownloadRow.cs | 完成列表渲染 |

运行时字段 downloadedBytes/tempDir 与本单元无关（引擎期）；**零新表零新列**——downloads 表 22 列、RecordData 15 字段投影零改动。新增 `uiSelected` 为 UI 会话态：不实现 RecordData 接口成员、rowFromRecord 不映射、重启即失（WPF 选中态同为视图态，同貌）。

### 2.2 CategoryDef（对照 Config.cs:157-221 Category + IconMap.cs:18-29）

```ts
// CategoryAlgo.ets（零 import）
export class CategoryDef {
  name: string;              // 对照 Name：'CAT_DOCUMENTS' 等（事件面键，CategoryChanged 无对应消费，保留可溯）
  displayName: string;       // 对照 DisplayName：显示名（渲染走 string.json cat_* 键，值同）
  fileExtensions: string[];  // 对照 FileExtensions（大写、含点；isOfCategory 内 toUpperCase 后比对）
  defaultFolderName: string; // 对照 DefaultFolder 的尾段（'Documents' 等）；完整 OS 下载目录拼接是 Phase 5/U4.3 消费
  isPredefined: boolean;     // 对照 IsPredefined：五项恒 true（源码注释掉的 Other 项不移植）
}
```

DEFAULT_CATEGORIES 五项扩展名集合逐串对照（Config.cs:160-219 本会话 sed 核实）：Documents 7（.DOC/.DOCX/.PDF/.MD/.XLSX/.XLS/.CBZ）、Music 5（.MP3/.AAC/.MPA/.WMA/.MIDI）、Videos 13（.MP4/.WEBM/.OGG/.FLV/.MKV/.DIVX/.MOV/.MPG/.MPEG/.OPUS/.AVI/.WMV/.TS）、Compressed 7（.7Z/.ZIP/.RAR/.BZ2/.GZ/.XZ/.TAR）、Programs 4（.EXE/.DEB/.RPM/.MSI）。**注意 IconMap.imageTypes（IconMap.cs:9-16）是另一套小写扩展名集**（多 .m4a/.ac3/.mka/.m4v/.txt/.html/.bin/.appx，少 .md/.opus 等）——图标分类键用 imageTypes 移植版（iconCategoryKeyForExtension），过滤用 DEFAULT_CATEGORIES，两套不混用（源码本就两套）。

### 2.3 DownloadListDataSource 内存结构（对照 ObservableCollection + ListCollectionView）

```ts
// DownloadListDataSource.ets
export class DownloadListDataSource extends BasicDataSource<DownloadRecord> {
  private records: DownloadRecord[] = [];      // 全量（对照 ObservableCollection，AddToTop=Append xaml.cs:281-289）
  private visible: DownloadRecord[] = [];      // 投影（对照 CollectionView 排序+Filter 视图）
  private sortKey: SortKey = 'DateAdded';      // 对照初始 SortDescription（xaml.cs:115-150 DateAdded Descending）
  private sortDesc: boolean = true;
  private filterKeyword: string = '';          // 对照 TxtSearch.Text（ApplyFilter 只作用于本列表）
  private filterCategory: CategoryDef | null = null; // 对照 view.Filter 的 category 闭包参
}
```

| ArkTS 结构 | 源码对应物 | 关键同构点 |
|---|---|---|
| records 全量 + visible 投影 | ObservableCollection + ListCollectionView（SortDescriptions+Filter） | 源码 AddToTop 仅 Append（:281-289），显示位次由视图排序决定——`addSorted` 同构：全量 Append+投影按当前排序/过滤找位 |
| filterKeyword+filterCategory | `IsOfCategoryOrMatchesKeyword(name, TxtSearch.Text, category?.category)`（Helpers.cs:190-198） | AND 语义：关键词空或 contains（不区分大小写）→ 扩展名∈集合（category null 恒过） |
| sortKey/sortDesc | SortDescription("DateAdded", Descending) 初始 + 列头点击翻转（:453-477） | nextSortDirection：同列且当前升序→降序，否则→升序 |
| fullCount/countByExtensions | （源码无计数——鸿蒙增强 §0-3） | 计数不受 filterKeyword/filterCategory 影响（未过滤全长口径） |

**不落盘**：数据源为纯内存视图层，DB 真值仍全在 DownloadStore（本单元零新 DB API）。

### 2.4 ToolbarState（对照 peer 五钮+Visible 语义，AppController.cs:429-478）

```ts
export class ToolbarState {           // class 而非 interface——@State 整体赋值触发渲染（ArkTS 字面量装配纪律）
  openFileVisible: boolean = false;   // 对照 OpenFileButton.Visible（进行中视图 false/完成视图 true，xaml 默认 Collapsed）
  openFolderVisible: boolean = false; // 对照 OpenFolderButton.Visible（状态机全程接管）
  pauseVisible: boolean = false;      // 对照 PauseButton.Visible（进行中 true/完成 false）
  resumeVisible: boolean = false;     // 对照 ResumeButton.Visible
  openFileEnabled: boolean = false;   // 五键每轮重算先全禁用（:431-435）
  openFolderEnabled: boolean = false;
  pauseEnabled: boolean = false;
  resumeEnabled: boolean = false;
  deleteEnabled: boolean = false;     // 选中>0 即启用（两视图同规）
}
export function computeToolbarState(inProgressViewSelected: boolean, selectedCount: number,
  singleIsActive: boolean): ToolbarState   // singleIsActive=manager.isLive(id)||isQueued(id)（IsDownloadActive :562-565 同构——排队也算 active）
```

分支逐一对照：进行中视图选中 1 → isActive?pause:resume；选中 >1 → Pause+Resume 均启用（Waiting/排队项算 active 仍显 Pause——resumeOne 对排队 id 幂等 return，启用它无意义，与源码一致）；完成视图选中 1 → OpenFile+OpenFolder；New 钮不在状态机内（恒可用，源码同貌）。

### 2.5 string.json 追加键（base/element，纯 JSON 禁尾逗号；值=English.txt 原值本会话逐键核实）

| 键 | 值（base） | 源键锚 |
|---|---|---|
| desc_new | New | DESC_NEW |
| desc_del | Delete | DESC_DEL |
| ctx_open_file | Open | CTX_OPEN_FILE |
| ctx_open_folder | Open folder | CTX_OPEN_FOLDER |
| menu_pause | Pause | MENU_PAUSE |
| menu_resume | Resume | MENU_RESUME |
| lbl_search | Search | LBL_SEARCH |
| sort_name / sort_date / sort_size / sort_status | Name / Date / Size / Status | SORT_NAME/SORT_DATE/SORT_SIZE/SORT_STATUS |
| stat_downloading / stat_stopped / stat_finished / stat_waiting | Downloading / Stopped / Finished / Waiting | STAT_DOWNLOADING/STAT_STOPPED/STAT_FINISHED/STAT_WAITING |
| settings_monitoring | Browser monitoring | SETTINGS_MONITORING（工具栏与状态栏两处同键，源码同貌） |
| desc_q_title | Queue and scheduler | DESC_Q_TITLE |
| lbl_support_page | Help and support | LBL_SUPPORT_PAGE |
| menu_delete_completed | Remove finished downloads | MENU_DELETE_COMPLETED |
| lbl_new_download / lbl_video_download / menu_batch_download | New download / Video download / Batch download | LBL_NEW_DOWNLOAD/LBL_VIDEO_DOWNLOAD/MENU_BATCH_DOWNLOAD |
| title_settings / msg_media_capture / menu_export / menu_import / menu_lang | Settings / Media grabber / Export / Import / Language | TITLE_SETTINGS/MSG_MEDIA_CAPTURE/MENU_EXPORT/MENU_IMPORT/MENU_LANG |
| lbl_report_problem / menu_update / menu_about / menu_exit | Report a problem / Check for update / About XDM / Exit | LBL_REPORT_PROBLEM/MENU_UPDATE/MENU_ABOUT/MENU_EXIT |
| cat_documents / cat_music / cat_videos / cat_compressed / cat_programs | Document / Music / Video / Compressed / Application | CAT_DOCUMENTS/CAT_MUSIC/CAT_VIDEOS/CAT_COMPRESSED/CAT_PROGRAMS |
| btn_cancel_queue | Cancel queue | （鸿蒙侧新增——Waiting 行按钮，§4-D10） |
| probe_p4u1_title | P4-U1 主窗口走查探针 | 探针基建 |
| probe_p4u1_source_hint | 测试源地址（主机局域网 IP，禁 127.0.0.1） | 探针基建 |
| probe_p4u1_check_hint | 主页面走查完成后逐项勾选，再点击 S4 执行 | 探针基建 |

分类顶层两项**复用既有键** `lbl_active`（Active）/`lbl_complete`（Complete）——与源键 ALL_UNFINISHED/ALL_FINISHED 同值，不重复建键（§0-10）。

## 3. 关键算法翻译说明

### 3.1 分类选择状态机（对照 lvCategory_SelectionChanged :151-157 + ApplyFilter :159-193）

```
selectCategory(index)                          // index∈[0,6]：0=Active 1=Complete 2..6=五个预定义分类
  guard（程序化同步防回环）
  activeCategoryIndex = index
  searchText = ''                              // 对照 TxtSearch.Text = string.Empty（:153）——清搜索框
  if index === 0:
    activeView = 0（Tabs 同步至进行中）          // 对照 lvInProgress.Visible+lvFinished.Collapsed+CategoryChanged(Level=0,Index=0)
    finishedDS.clearFilter()
  else:
    activeView = 1（Tabs 同步至已完成）
    if index === 1: finishedDS.clearFilter()   // 对照 view.Filter=…(null) + CategoryChanged(Level=0,Index=1)
    else: finishedDS.applyFilter(searchText='', DEFAULT_CATEGORIES[index-2])
                                               // 对照 view.Filter=IsCategoryMatched(…,cat) + CategoryChanged(Level=1,Index=index-2)
  clearSelection()                             // 差异 §4-D4：源码无显式清空，防不可见选中态
  recomputeToolbar()                           // 对照 ApplyFilter 尾部 SelectionChanged?.Invoke → UpdateToolbarButtonState
  recomputeCounts()                            // 鸿蒙增强计数刷新（§0-3）
```

CategoryChanged/SelectionChanged 事件面**不建对应物**：AppController 中两事件唯一消费点就是 UpdateToolbarButtonState（:524-528），ArkTS 侧直接同步调用 recomputeToolbar（研究 fact 10 同口径）。Tabs onChange 反向：index0→selectCategory(0)；index1→activeCategoryIndex<1 ? selectCategory(1) : 仅对齐 activeView（保持子分类过滤）。

### 3.2 搜索过滤（对照 SearchButton_Click :428-431 + Helpers.cs:179-207）

```
onSearchClick()                                // 触发点仅两处：搜索按钮点击 / 分类切换（输入中只改 @State searchText 不触发——源码同貌）
  finishedDS.applyFilter(searchText.trim(), currentCategory())   // 只作用于完成数据源
// applyFilter 内可见性判定 = isOfCategoryOrMatchesKeyword(name, keyword, category)：
//   (keyword==='' || name.toLowerCase().contains(keyword.toLowerCase()))
//   && (category===null || fileExtensionOf(name).toUpperCase() ∈ category.fileExtensions)
```

进行中列表**明确不接过滤**（Helpers.FilterByKeyword :179-185 存在但 MainWindow 未接线——走查表按此写：搜索时进行中列表不变）。Path.GetExtension 移植=「最后一个 '.' 起含点到串尾；无 '.' 返回空串」（fileExtensionOf，对照 .zip.md → '.md' 边缘）。

### 3.3 排序（对照 xaml.cs:115-150 初始排序 + :453-477/:570-594 列头点击 + :281-289 AddToTop）

- **初始**：initialize(records) 将 sortKey='DateAdded'/sortDesc=true 后重算投影——两列表同（进行中列表源码延至首可见时挂排序，可观测结果相同）。
- **列头点击**：表头行 onClick(key) → nextSortDirection：同列且当前升序→降序，否则→升序（首击恒升序，含从初始 DateAdded desc 点击 DateAdded→转升序）；'%' 列无排序键不绑点击（对照无 Tag 直接 return）。重算投影后 notifyDataReloaded。
- **新项置顶语义**：addSorted(record) 全量 records.push（Append，对照 :281-289）→ 若过过滤条件，sortedInsertIndex 按 (sortKey,sortDesc) 前向线性扫投影插入位（dateAdded desc 默认态下新项 dateAdded=now 为最大→index 0，与 AddToTop+视图排序的置顶呈现等价）→ notifyDataAdd(idx)。**不整表重排**（保 O(1) 常态路径）；用户自选排序下插入位次由比较器保证正确。
- compareRows：Name=字符串比较（null 名按空串，C# string.Compare 同貌）；DateAdded/Size=数值比较；desc 翻转结果符号。
- 完成迁移（handleFinished）同走 addSorted——finished 项 dateAdded 保持起始时间（源码 MarkAsFinished 不改 DateAdded），完成序由排序键自然呈现。

### 3.4 状态列文本合成（对照 Helpers.cs:210-257 GenerateStatusText/GetStatusText）

```
generateStatusText(status, speed, eta, labels):
  if status !== Downloading: return labels[status]        // Stopped/Finished/Waiting → STAT_*（GetStatusText :212-229）
  if eta 空 && speed 空: return labels.downloading        // STAT_DOWNLOADING（:235-237）
  if eta 空: return speed                                 // 只显 Speed（:238-240）
  if speed 空: return eta                                 // 只显 ETA（:241-243）
  return speed + ' - ' + eta                              // "{Speed} - {ETA}"（:244-246）
```

空判定=（值===null || 值===''），对照 string.IsNullOrEmpty。行组件状态列=**单 Text** 输出本函数结果（替代现 speed/eta 两 Text 散排）——源码 Status 列即 DisplayMemberBinding=StatusText 单列（xaml:652），INPC 级联刷新由 @Observed 字段变更+每次渲染重算自然获得。

### 3.5 LazyForEach/IDataSource 渲染层（决策 11；对照 CollectionView 通知模型）

- **数据源实现**：BasicDataSource<T> 持 DataChangeListener[]（registerDataChangeListener/unregisterDataChangeListener）；DownloadListDataSource 重算投影后 notifyDataReloaded、addSorted→notifyDataAdd(idx)、removeById→notifyDataDelete(idx)；getData(i) 带边界守卫；**getData 内零排序/过滤/格式化耗时操作**（devecocli docs 实测告诫）。
- **键值**：keyGenerator=(record)=>record.id（UUID 唯一稳定，满足「修改数据项不影响键值则组件不重建」）。
- **字段级刷新零通知**：@Observed record 的 progress/downloadSpeed/eta/status/uiSelected 变更由 @ObjectLink 行组件自动刷新——**禁 emit notifyDataChange**（双通道重复刷新）。30ms 轮询（P2-U1）事件面不依赖渲染方式，进度事件仍走 @Observed 直改。
- **不用 LazyForEachOptions**：API 26+ 起（devecocli docs 实测），本工程 API 24——用基础签名，keyGenerator 必传。
- **结构变更同步性**：addSorted/removeById/重算投影在调用栈内同步完成（store Promise 的 .then 边界内、事件回调内），无异步窗口——LazyForEach 通知与数组状态永不撕裂。
- **组件复用/缓存**：本单元不引入 cachedCount 等调优参数（走查规模 ~几十行），列表流畅性验收以走查项 21 人工感知为准。

### 3.6 线程模型映射（决策 2 增量）

| 源码机制 | ArkTS 对应 | 说明 |
|---|---|---|
| RunOnUIThread ×2（Dispatcher.BeginInvoke，IApplicationWindow.cs:54-56） | 直接调用 | ArkUI 事件回调与引擎事件回流（U2 既有 taskpool→主线程）天然主线程，无派发层 |
| CollectionView 视图刷新（WPF 数据绑定自动） | DataChangeListener notify*（§3.5） | 同步调用栈内完成 |
| SearchButton_Click / 列头 Click（UI 线程） | ArkUI onClick | 同左 |
| store 异步 CRUD（Promise） | .then 边界内做 DS 变更+通知 | U3.1 §3.5 同构：异步边界只延迟时点，不撕裂一致性 |
| TextResource.GetText（每帧查资源表） | string.json $r / StatusLabels 一次性装配 | 行组件 labels 由 Index 装配一次传入（getStringSync），行内零资源查询 |

本单元零 TaskPool 新增（纯 UI 单元）；限速/分段数学不在本单元触面。

## 4. 有意差异清单（对照源码/计划，含已定降级项）

| # | 差异 | 依据 |
|---|---|---|
| D1 | 分类树+Tabs 并存、双向联动（源码无 Tabs，内容区纯分类驱动）——分类点击联动 Tabs index，Tabs onChange 反向映射 | §0-1；研究 openQuestion 2（已授权拍板点） |
| D2 | 分类计数为鸿蒙侧增强：每分类行右端显示计数（未过滤全长口径，顶层 0/1=两列表 fullCount，子分类=扩展名匹配数）；源码分类项仅图标+名 | §0-3；研究 openQuestion 2 |
| D3 | 多选交互混合方案：行点击单选替换+行内复选框多选（源码 WPF Ctrl/Shift 多选）；状态机 selectedCount 消费面 1:1 | §0-2；研究 openQuestion 1 |
| D4 | 分类切换时清空当前视图选中（源码仅清搜索框）——防过滤后不可见选中态造成工具栏状态与所见不符 | §3.1 |
| D5 | 汉堡菜单 12 项/新建下拉 3 项为壳：占位禁用，动作 U4.2 接线；导出/导入为 MIGRATION_PLAN 降级（U5.2 DocumentViewPicker）、退出 Environment.Exit(0) 无对应 API（隐藏或禁用 U7.3 拍板）、媒体嗅探待 U6.2 NavDestination 页 | 研究 fact 8/9；MainWindow.xaml.cs:662-672 |
| D6 | OpenFile/OpenFolder：状态机（Visible+Enabled）1:1，点击动作占位（业务日志）——文件打开/文件夹打开待 U5.2 能力面 | §0-6 |
| D7 | 工具栏 Delete 简版接线：AlertDialog.confirm → live 行先 stopOne 不删行、非 live 行 store.remove+DS removeById；完整 DeleteDownloads 链（ConfirmDelete 对话框 approved+deleteFiles、文件清理、批量次序）U4.2 接 | §0-6；MainWindow.xaml.cs:316-327 |
| D8 | 图标/日期载体平台化：IconMap 映射规则 1:1 移植但 Vector Path→SymbolGlyph（sys.symbol.*，编码期核实资源名）+扩展名首字母 Text 兜底；DateAdded 列 StringFormat=d（文化相关）→ formatDate 'YYYY-MM-DD' | §1-#9；IconMap.cs |
| D9 | 排序实现层级：WPF CollectionView 视图排序（AddToTop 仅 Append）→ 数据源内排序投影（records 全量+visible）；可观测行为对齐（初始 DateAdded desc/列头翻转/%不可排/新项置顶） | §3.3 |
| D10 | 行级 toggle 按钮为鸿蒙侧既有增强（U1.2 起，源码行为右键菜单）：Waiting 行标签='取消排队'（btn_cancel_queue 新键），点击→stopOne（isQueued 分支）；**U3.1 复核 F3 死按钮本单元闭环 + D9 排队取消 DB 回声接通（Index init 传 onQueuedCancelled→store.updateStatus(Stopped)）** | Index.ets:132-143；DownloadManager.ets:35-37/:205-227；U3.1 REPORT 复核 F3 |
| D11 | i18n 仅 base 键骨架（值=源文案英文原值）；分类顶层复用 lbl_active/lbl_complete；zh_CN/en_US 与语言切换 U4.3 | §0-10；任务书⑤ |
| D12 | 状态栏三触点占位禁用：浏览器监视 toggle（U5.x ClipboardWatcher/桥联动）、Queue and scheduler（U4.2 Scheduler 页）、Help（U4.2） | 研究 fact 8 |
| D13 | 搜索触发点=搜索按钮点击/分类切换，非输入实时过滤；进行中列表不接过滤（FilterByKeyword 未接线）——**源码同貌 1:1，非遗漏** | §3.2；Helpers.cs:179-185 |
| D14 | 工具栏无"全部暂停"按钮（源码钮集无此键，任务书表述按源码执行） | §0-5 |
| D15 | 启动默认视图=已完成（源码 ctor:104 SwitchToFinishedView）——对齐修正：U1.2 现状默认进行中，本单元改为默认 index 1（非差异，走查表按此核对） | §0-4 |
| D16 | CategoryChanged/SelectionChanged/IApplicationWindow 事件面不建独立对应物——两事件在 AppController 的唯一消费即工具栏重算，ArkTS 直接同步调用 recomputeToolbar；右键菜单 18 项清单与启用规则（AppController.cs:730-791）作为 **U4.2 输入**记录，本单元不实现 | 研究 fact 10 |
| D17 | handleToggle 分支次序修正：isLive→stopOne / **isQueued→stopOne（新增）** / else resumeOne——resumeOne 对排队 id 幂等 return 的死态不复现 | DownloadManager.ets:182-198 |
| D18 | Progress 列保留 ProgressBar 高 5 模板（xaml:640-647 同构），非纯文本 %——**源码同貌非差异**；行内不再另画全宽进度条（U1.2 卡片布局遗形移除，列结构对照 MainWindow 验收） | xaml:640-647 |

## 5. 各文件实现要点（可直接照做的接口面）

### 5.1 core/util/StatusText.ets（新，零 import）

```ts
export interface StatusLabels { downloading: string; stopped: string; finished: string; waiting: string; }
export function generateStatusText(status: number, speed: string | null, eta: string | null,
  labels: StatusLabels): string          // §3.4；空判定 (v === null || v === '')
```

### 5.2 core/util/CategoryAlgo.ets（新，零 import）

```ts
export function fileExtensionOf(name: string): string          // 最后 '.' 起含点；无 '.' → ''
export class CategoryDef { name; displayName; fileExtensions: string[]; defaultFolderName; isPredefined }
export const DEFAULT_CATEGORIES: CategoryDef[]                 // 五项，§2.2 逐串
export function isOfCategory(name: string, category: CategoryDef | null): boolean
  // category===null → true；fileExtensionOf(name).toUpperCase() ∈ category.fileExtensions（集合线性查，n≤13）
export function isOfCategoryOrMatchesKeyword(name: string, keyword: string,
  category: CategoryDef | null): boolean
  // (keyword==='' || name.toLowerCase().includes(keyword.toLowerCase())) && isOfCategory(...)
export function iconCategoryKeyForExtension(extLower: string): string
  // IconMap.imageTypes 移植：'CAT_COMPRESSED'|'CAT_MUSIC'|'CAT_VIDEOS'|'CAT_DOCUMENTS'|'CAT_PROGRAMS'|'Other'
```

### 5.3 core/util/ListAlgo.ets（新，零 import）

```ts
export interface SortableRow { id: string; name: string | null; dateAdded: number; size: number; }
export type SortKey = 'Name' | 'DateAdded' | 'Size';
export function compareRows(a: SortableRow, b: SortableRow, key: SortKey, desc: boolean): number
  // Name：null 按空串字符串比较；DateAdded/Size：数值比较；desc 翻转符号
export function sortedInsertIndex(rows: SortableRow[], row: SortableRow, key: SortKey, desc: boolean): number
  // 前向线性扫（dateAdded desc 新项首元素即命中 O(1) 常态）；返回投影插入下标
export function nextSortDirection(curKey: SortKey, curDesc: boolean, clickedKey: SortKey): boolean
  // 同列且当前升序(!curDesc) → true(降序)；否则 false(升序)——xaml.cs:458-461 同构
```

### 5.4 core/util/ToolbarAlgo.ets（新，零 import）

```ts
export class ToolbarState { /* §2.4 十字段 */ }
export function computeToolbarState(inProgressViewSelected: boolean, selectedCount: number,
  singleIsActive: boolean): ToolbarState   // §2.4 分支逐一对照 AppController.cs:429-478
```

### 5.5 model/BasicDataSource.ets（新）

照开发指南 BasicDataSource 示例 ArkTS 化：`export class BasicDataSource<T> implements IDataSource`；`private listeners: DataChangeListener[] = []`；`totalCount(): number`（子类覆写或基类持数组——取**基类持监听器+通知面、子类持数据**形态）；四 notify 方法遍历 listeners 派发（indexed for，禁 for..in）。IDataSource/DataChangeListener 为 ArkUI 环境类型，零 import。

### 5.6 model/DownloadListDataSource.ets（新）

```ts
export class DownloadListDataSource extends BasicDataSource<DownloadRecord> {
  totalCount(): number;  getData(index: number): DownloadRecord | null;   // 边界守卫
  initialize(records: DownloadRecord[]): void;   // records 拷贝 + sortKey='DateAdded'/desc=true + rebuild + reload
  addSorted(record: DownloadRecord): void;       // §3.3：push 全量 → 过滤判定 → sortedInsertIndex 投影插入 → notifyDataAdd
  removeById(id: string): boolean;               // 全量删+投影删（命中才 notifyDataDelete）；未命中 false（幂等）
  applyFilter(keyword: string, category: CategoryDef | null): void;  // rebuild 投影 + notifyDataReloaded
  clearFilter(): void;                           // keyword=''/category=null + reload
  toggleSort(key: SortKey): void;                // nextSortDirection + rebuild + reload
  getRecordById(id: string): DownloadRecord | null;   // 全量线性查
  fullCount(): number;                           // records.length（未过滤全长）
  countByExtensions(exts: string[]): number;     // 遍历 records 按 isOfCategory 计数（§0-3 口径）
  sortState(): SortKey 的 curKey/curDesc 只读快照       // 表头箭头渲染原料
}
// rebuild()：visible = records.filter(isOfCategoryOrMatchesKeyword) 后 sort(compareRows)——O(n log n)，
// 仅 initialize/applyFilter/toggleSort 触发；高频路径 addSorted/removeById 走增量通知
```

### 5.7 model/DownloadRecord.ets（改，两处）

①类声明行改 `export class DownloadRecord implements RecordData, SortableRow`（SortableRow 自 '../core/util/ListAlgo' import——model→util 单向）；②downloadedBytes/tempDir 后追加：

```ts
/** UI 会话态：行选中高亮/复选框渲染（U4.1；不落库不入 RecordData，单写者=Index 选中链） */
uiSelected: boolean = false;
```

文件头注释追加 SortableRow/uiSelected 锚注。

### 5.8 components/DownloadListItem.ets（新）

```ts
@Component export struct DownloadListItem {
  @ObjectLink record: DownloadRecord;
  showToggle: boolean = false;                  // 进行中 true / 完成 false（Tab 语义保留）
  labels: StatusLabels = { downloading: 'Downloading', stopped: 'Stopped', finished: 'Finished', waiting: 'Waiting' };
  onSelect: (id: string) => void = (id: string): void => {};
  onToggleSelect: (id: string) => void = (id: string): void => {};
  onToggle: (id: string) => void = (id: string): void => {};
}
```

build 布局（列 flex 与表头行严格对齐，§5.9 同表）：
- 进行中行：`Row[ Checkbox(record.uiSelected) | FileTypeIcon(24×24) | 名称(flex3) | formatDate(dateAdded)(flex1) | formatSize(size)(flex1) | Progress 高 5(flex0.8，value=record.progress) | Text(generateStatusText(record.status, record.downloadSpeed, record.eta, labels))(flex1.5) | 行按钮(fixed) ]`
- 完成行：`Row[ Checkbox | FileTypeIcon | 名称(flex4) | 日期(flex1) | 大小(flex1) ]`（无 %/状态/按钮）。
- 行按钮标签三分支（D17/D10）：`record.status === Downloading → $r('app.string.menu_pause')`；`=== Waiting → $r('app.string.btn_cancel_queue')`；否则 `$r('app.string.menu_resume')`；onClick → onToggle(record.id)。
- 选中视觉：record.uiSelected → 行背景高亮色；Checkbox onChange → onToggleSelect(record.id)（行体 onClick → onSelect(record.id)，Checkbox 区拦截冒泡）。
- FileTypeIcon @Builder：iconCategoryKeyForExtension(fileExtensionOf(name ?? '')) 五键 switch → SymbolGlyph($r('sys.symbol.*'))，default 与 symbol 不可用时 Text(扩展名首字母大写)。**sys.symbol 具体名编码期在 DevEco 补全核实（本地 SDK 无名表，本会话实测）；无效名编译期资源错误即暴露，兜底分支恒在**。
- @ObjectLink 只读红线：record 字段在本组件内零写入（回调全部上抛 Index）。

### 5.9 Index 表头行（Index.ets 内私有 @Builder，两列表各一）

`Row[ 空(对齐 Checkbox) | sort_name(→'Name') | sort_date | sort_size | '%'（进行中，无点击） | sort_status | 空(对齐按钮) ]`；可排三列绑 onClick(key) → 当前 DS.toggleSort(key) + @State sortVersion++（表头箭头重渲染）。列 flex 与行组件共用同一组常量（文件内 const 数组，禁两处魔法数漂移）。

### 5.10 pages/Index.ets（改，改动面八处）

1. **imports**：+DownloadListDataSource/BasicDataSource 不直接引（DS 自带）、+CategoryAlgo(DEFAULT_CATEGORIES)/ToolbarAlgo/StatusText(StatusLabels)/Formatting(formatDate 不在此用)+ManagerHooks。
2. **aboutToAppear**：`DownloadManager.getInstance().init(this.buildEngineEvents(), this.buildManagerHooks());`（hooks 装配照 ProbeQueue.ets:419-421 类型化字面量先例——`onQueuedCancelled: (id: string): void => { store.updateStatus(id, DownloadStatus.Stopped).catch(日志); }`，内存 status=Stopped 由 stopOne queued 分支已置（同一 record 引用），**D9 回声闭环**）；随后 initLists()。
3. **状态字段**：删 @State inProgressList/finishedList；+`inProgressDS/finishedDS: DownloadListDataSource`（成员非 @State——DS 内部变更经 DataChangeListener 驱动 LazyForEach，DS 引用本身不变）+`@State activeCategoryIndex: number = 1`（D15 默认完成视图）+`@State activeView: number = 1`+`@State searchText: string`+`@State selectedCount: number = 0`+`@State toolbarState: ToolbarState = computeToolbarState(false, 0, false)`+`@State categoryCounts: number[] = [0,0,0,0,0,0,0]`+`@State sortVersion: number = 0`+`selectedIds: Set<string>`（非 @State，权威选中集）+tabsSyncGuard 布尔。
4. **initLists**：queryAll 后 `this.inProgressDS.initialize(lists.inProgress); this.finishedDS.initialize(lists.finished); this.recomputeCounts(); this.recomputeToolbar();`（失败分支留空+日志，既有语义保留）。
5. **startNewDownload**：`this.inProgressList.unshift(record)` → `this.inProgressDS.addSorted(record); this.recomputeCounts();`（store.add→addSorted→admitNew 次序红线不变）。
6. **handleToggle**：三分支（D17）——`if (manager.isLive(id)) { manager.stopOne(id); return; } if (manager.isQueued(id)) { manager.stopOne(id); return; } …resumeOne(record)`。
7. **handleFinished**：`splice/unshift` → `this.inProgressDS.removeById(id); this.finishedDS.addSorted(record); this.recomputeCounts();`（record 引用即 inProgressDS 中的同一对象）；事件消费方其余五方法逐字节不动。
8. **新增私有方法面**：selectCategory（§3.1）/onSearchClick（§3.2）/onTabChange/selectRow(id)（Set 替换+uiSelected 重标）/toggleRowSelect(id)（Set toggle）/clearSelection（遍历 selectedIds 置 uiSelected=false+清 Set+selectedCount=0）/recomputeToolbar（取选中首行 id 算 singleIsActive=manager.isLive||isQueued，调 computeToolbarState 整体赋 @State）/recomputeCounts（DS.fullCount×2+五分类 countByExtensions）/handleToolbarPause/Resume/Delete（§0-6 接线）。
9. **build()**（Navigation 根保留，mode Stack）：

```
Navigation(pathStack) {
  Row({ space: 8 }) {
    // ── 左：分类面板（宽 ~190，对照 xaml 左栏）──
    Column { ForEach(CATEGORY_PANEL, 行[SymbolGlyph/首字母 | 名称 | 计数 Blank+Text]) }  // 7 项，高亮=activeCategoryIndex
    // ── 右 ──
    Column({ space: 8 }) {
      Row {  // 工具栏钮面（§0-5/§0-6）
        Button($r('app.string.desc_new')).bindMenu(新建下拉 3 项 CustomBuilder：lbl_new_download 开对话框 / lbl_video_download 禁用 / menu_batch_download 禁用)
        Button($r('app.string.desc_del')).enabled(toolbarState.deleteEnabled).onClick(handleToolbarDelete)
        Button($r('app.string.ctx_open_file')).visibility(toolbarState.openFileVisible)…（点击占位日志）
        Button($r('app.string.ctx_open_folder')).…同上
        Button($r('app.string.menu_pause')).visibility(toolbarState.pauseVisible).enabled(toolbarState.pauseEnabled).onClick(handleToolbarPause)
        Button($r('app.string.menu_resume')).…同 Resume
        Blank()
        TextInput({ placeholder: $r('app.string.lbl_search'), text: this.searchText })   // 输入只改 @State
        Button(搜索图标/文本).onClick(onSearchClick)
        Button('☰').bindMenu(汉堡 12 项 CustomBuilder，全占位禁用，§4-D5)
      }
      Tabs({ index: this.activeView, barPosition: BarPosition.Start, controller }) {   // D1
        TabContent($r('app.string.lbl_active')) { 表头行(进行中) + List { LazyForEach(inProgressDS, 行组件, key=id) } }
        TabContent($r('app.string.lbl_complete')) { 表头行(完成) + List { LazyForEach(finishedDS, 行组件, key=id) } }
      }.onChange(onTabChange).layoutWeight(1)
      Row {  // 状态栏（D12 占位）
        Text($r('app.string.settings_monitoring')) + 监视 toggle 图标(占位禁用)
        Button($r('app.string.desc_q_title'))(禁用)  Blank()  Button($r('app.string.lbl_support_page'))(禁用)
      }
    }.layoutWeight(1)
  }
}.mode(NavigationMode.Stack)
```

空列表占位（'暂无进行中下载'）保留：List 外 if(DS.totalCount()===0) 分支——totalCount 非 @State，改由 `@State inProgressCount/finishedCount`（recomputeCounts 一并维护）驱动空态与计数徽标。

### 5.11 probe/units/ProbeMainWindow.ets（新，P4-U1）

结构同 ProbeSpeedLimit（@Component + ProbePage + runStep 分派 + facts 袋 + isCurrent 守卫）；`UNIT_ID='P4-U1'`、`DEFAULT_BASE_URL='http://192.168.1.20:8080'`、SLOW_MS=300、POLL_MS=100、S3_TIMEOUT_MS=20000；`autoStart=false`（S4 人工）；步骤表 `[{S1,autoRun:true},{S2,autoRun:true},{S3,autoRun:true},{S4,autoRun:false}]`；S4 清单 22 项 Toggle（标题来自走查清单表 §6，中文 UI 文本不进日志）；确定性 id `probe-p4u1-<runId>-<i>`（store.add 前覆盖，COLD-F1 约定）。

## 6. 探针步骤设计（P4-U1 四步 + 人工走查清单，对应手册/EXPECT）

> 驱动模型：S1/S2 纯内存零业务副作用；S3 只调业务公开 API（DownloadManager/DownloadStore/Config）；S4 人工勾选。观测值只写事实不写 PASS/FAIL。**手册次序红线（§0-11）：先主页面走查→探针页"运行全部"（S1~S3）→回探针页勾选清单→单步执行 S4**（S3 init 接管事件袋，走查须在前）。

| 步骤 | 操作 | 观测点 | 日志标记行（值=观测事实） |
|---|---|---|---|
| BEGIN | ProbePage begin | runId/filesDir | `[XDM_PROBE][P4-U1][BEGIN] runId=<HHmmss> filesDir=<沙箱files路径>` |
| S1 数据源行为 | 纯内存构造 DownloadListDataSource：initialize 3 记录（dateAdded 升序喂入，名 c.zip/a.pdf/b.mp3 时序 t3>t2>t1）→ addSorted(新 d.bin) → toggleSort('Name')×2 → applyFilter('a') → clearFilter+applyFilter('','.ZIP') → clearFilter → removeById('c') | 初始排序 desc、投影插入位、排序翻转、关键词/分类过滤、删除通知 | `[S1] initOrder=c/a/b addIndex=0 totalCountAfterAdd=4 nameAsc=a/b/c/d nameDesc=d/c/b/a keywordFiltered=1 fullCount=4 categoryFiltered=1 totalCountAfterRemove=3` |
| S2 纯函数面 | generateStatusText 六分支（labels 用英文标签常量）+ computeToolbarState 五场景（进行中 0 选/1 选 active/1 选停态/2 选；完成 1 选） | 状态合成四形态+状态机 enabled/visible | `[S2] statNoSpeed=Downloading statSpeedOnly=1.2MB/s statEtaOnly=00:01 statBoth=1.2MB/s - 00:01 statStopped=Stopped statWaiting=Waiting ip0=del0/pv1/ofv0 ip1Active=p1/r0/del1 ip1Idle=p0/r1 ip2=p1/r1/del1 fin1=of1/pv0/del1` |
| S3 排队取消回声链 | 快照 maxParallel→set 1→manager.init(事实袋, hooks 计数+镜像 updateStatus)→r1 slow.bin?ms=300 add+admitNew（live）→r2 add+admitNew（queued，status=Waiting）→**先**模拟行分派：isQueued(r2)→stopOne(r2)（排队取消，不补位）→**后** isLive(r1)→stopOne(r1)→轮询 live==0（20s 超时）→getDownloadById(r2) 读 DB→恢复 maxParallel+读回校验 | isQueued 分派命中、回声计数、排队取消不补位（startedCount 恒 1）、onPaused 回声、DB 回声持久化、参数恢复 | `[S3] maxParallelBefore=3 submitted=2 queuedStatusBeforeStop=3 queuedCancelEcho=1 startedCount=1 pausedEcho=1 liveAfterStops=0 queuedAfterCancel=0 dbStatusAfterEcho=1 maxParallelRestored=3` |
| S4 走查清单（manual） | 人工按 §6 走查清单在主页面核对 22 项→回探针页逐项 Toggle 勾选→点"执行" | 勾选面 | `[S4] checked=<k> total=22 unchecked=<索引'/'串或 none>` |
| SUMMARY | end(ok) 聚合 | 四段关键值 | `[SUMMARY] S1=…|S2=…|S3=…|S4=…`（<1500B ProbeKit 降级保证） |
| END | ok/steps/elapsed | steps=4 | `[END] ok=true steps=4 elapsedMs=<ms>` |

**S3 关键确定性论证**：先取消排队项后停运行项的次序保证 startedCount 恒 1——若排队取消误补位（回归）则 r2 在 r1 停止前已被 dequeueOne 启动，startedCount=2 且 isQueued 分派脱靶，回声=0（EXPECT 分流 business-code）；maxParallel=1 保证 admitNew(r2) 必入队（status=Waiting 可观测）；hooks 镜像 updateStatus 后 getDownloadById 读回 1（D9 DB 回声链端到端）。

### 6bis. 人工走查清单（22 项，写入手册 §5 并渲染进 S4 勾选面；对照 XDM 走查表）

1. 启动默认落在"已完成"视图（分类第 2 项高亮+Tabs 完成页）（D15，源码 ctor:104）
2. 分类面板 7 项齐全：全部下载中/全部已完成/Document/Music/Video/Compressed/Application
3. 分类各带计数且与对应列表行数一致（子分类=扩展名匹配数，D2 口径）
4. 点击"全部下载中"→进行中列表+OpenFile/OpenFolder 隐藏+Pause/Resume 显示
5. 点击"全部已完成"→完成列表+OpenFile/OpenFolder 显示+Pause/Resume 隐藏
6. 点击子分类→完成列表仅剩匹配扩展名行（如 Video 只剩 .mp4/.mkv…）
7. 搜索框输入关键词+点击搜索→完成列表按名称包含过滤；进行中列表不受影响（D13）
8. 切换分类后搜索框被清空（源码 :153 同貌）
9. 列头点击：Name 首击升序/再击降序；DateAdded/Size 同；% 列头点击无反应
10. 新建下载后新行出现在进行中列表顶部（dateAdded desc 置顶，对照 AddToTop）
11. 行点击选中高亮+Delete 启用；再点同行保持选中（WPF 同貌——单击已选中项不取消，取消选中经复选框或切换分类；勘误：曾误写"再点同行取消选中"，独立复核 F2）
12. 选中 1 个运行中行→Pause 启用/Resume 禁用；选中 1 个停态行→反之；选中 Waiting 行→Pause（排队算 active）
13. 复选框勾选 2 行→Pause+Resume 均启用（D3 多选路径）
14. Waiting 行按钮显示"取消排队"，点击后行变 Stopped+按钮变"继续"（F3 修复）
15. 上一步后杀进程重启→该行仍为停态（D9 DB 回声）
16. 工具栏 Pause/Resume 对选中行生效且与行按钮同效
17. 工具栏 Delete：确认后非运行行消失、重启不回；运行行被停不删（D7 简版口径）
18. 新建下拉：New download 打开既有对话框；Video download/Batch download 禁用
19. 汉堡菜单 12 项可见且全部占位禁用（D5）
20. 状态栏：Browser monitoring 文案+toggle 图标+Queue and scheduler+Help 占位禁用（D12）
21. 造 >50 行历史后滑动双列表无可感知卡顿（LazyForEach 生效，单元验收"列表流畅"）
22. 状态列文本：运行中='速度 - ETA'或'Downloading'；停态='Stopped'；排队='Waiting'（GenerateStatusText 合成）

## 7. 单元验收测试要点

### [A] 静态门禁（编码员每轮自跑）

1. **hvigor 构建**：`hvigorw assembleHap` 零 error 零新 warning——ArkTS 严格子集编译期强制（自查对照 arkts-grammar-standards：无 any、对象字面量带声明类型（hooks 照 ProbeQueue 先例）、无结构化类型（DownloadRecord implements SortableRow）、Set/Map 仅限面 API、indexed for）。
2. **Hypium 本地单测**（`hvigorw test`）四套件 35 条：
   - StatusText 8：downloading 无速无 ETA→标签；只 speed；只 eta；双全 `'1.2MB/s - 00:01'`；空串视同 null（IsNullOrEmpty）；Stopped/Finished/Waiting 各归标签。
   - CategoryAlgo 12：DEFAULT_CATEGORIES 长度 5+各集合长度 7/5/13/7/4+抽查逐串（.CBZ/.MIDI/.TS/.XZ/.MSI）；isOfCategory null→true；'.doc' 命中 .DOC 大写集；无扩展名→不命中任一分类；'.zip.md'→'.md'；关键词+分类 AND 双拒/双过；iconCategoryKeyForExtension：.zip→CAT_COMPRESSED、.m4a→CAT_MUSIC（imageTypes 特有）、.txt→CAT_DOCUMENTS、.bin→CAT_PROGRAMS、.xyz→Other。
   - ListAlgo 8：compareRows Name 升/降/null 尾置、DateAdded、Size；sortedInsertIndex dateAdded desc 新最大→0、中间位插入、asc 插尾；nextSortDirection 同列升→降/同列降→升/异列→升（初始 desc 态点 DateAdded 转升）。
   - ToolbarAlgo 7：进行中 0 选=delete0+pv1/ofv0；1 选 active=p1/r0；1 选停态=p0/r1；2 选=p1/r1/del1；完成 1 选=of1/ofF1/pv0/del1；完成 0 选=delete0；singleIsActive=true 时 Waiting 归 pause 分支。
3. **事件面零破坏核对**（审查项）：Downloader.ets/DownloadManager.ets/NewDownloadDialog.ets git diff 为空；Index 五事件消费方（handleStarted/Connected/Progress/Paused/Failed）+buildEngineEvents diff 为空；`grep -r "XDM_PROBE" entry/src/main/ets/core/ entry/src/main/ets/model/ entry/src/main/ets/components/` 零命中；`grep -rn "probe/" entry/src/main/ets/pages/ entry/src/main/ets/components/` 零命中。
4. **结构核对**：main_pages.json 仍仅 Index+ProbeIndex；module.json5 无 diff；string.json 合法 JSON（禁尾逗号）且 40 新键齐全；DownloadRecord 无新增 RecordData 成员。

### [P] 运行时（手册承载，xdm-probe-verify 机械判定 + 人工走查）

- **S1**：initOrder=c/a/b（初始 desc）、addIndex=0（置顶语义）、keywordFiltered=1/fullCount=4（过滤不蚀全量）、categoryFiltered=1、totalCountAfterRemove=3——数据源行为锚。
- **S2**：statBoth=1.2MB/s - 00:01（合成格式）+五场景状态机布尔——纯函数运行时佐证（与 [A] 单测互证）。
- **S3**：queuedCancelEcho=1、startedCount=1（排队取消不补位）、pausedEcho=1、liveAfterStops=0、dbStatusAfterEcho=1（D9 回声链端到端）、maxParallelRestored=3（环境恢复）——F3/D9 闭环锚；分支映射：queuedCancelEcho=0 或 startedCount=2 → business-code（isQueued 分派缺失/误补位）；dbStatusAfterEcho≠1 → business-code（updateStatus 链断）；sourceStatus 类异常 → env。
- **S4**：checked=22/22 为全绿目标（unchecked 非空→按项号分流走查返修，verify 记 UNVERIFIED 并列出项号）。
- **环境前提**：S3 需主机侧 `node P1-U2-download-server.js`（零改动复用，ms=300 由探针 URL 携带）；S1/S2/S4 无需测试源。

## 7bis. 单元验收对照（UNIT_CATALOG U4.1 行）

| 目录要求 | 本设计落点 |
|---|---|
| 双列表（进行中/完成）、分类树、搜索、工具栏 | §5.10 build()（Row[分类面板\|Column[工具栏/搜索/Tabs 双列表/状态栏]]）；分类语义 §3.1（7 项 1:1）；搜索 §3.2（只作用完成列表 1:1）；工具栏钮面+状态机 §2.4（AppController.cs:429-478 逐分支） |
| Navigation/NavDestination 路由定案 | Navigation 根保留（Index.ets:264 既有），本单元无子页（对话框 CustomDialog/菜单 bindMenu 壳）；U6.2 媒体嗅探页将来走 NavDestination（预留注记 D5） |
| DownloadListItem + LazyForEach/IDataSource | §5.5-§5.8（BasicDataSource/DownloadListDataSource/DownloadListItem 独立文件）；渲染层纪律 §3.5 |
| 验收要点"走查清单项可勾" | §6bis 22 项对照表 + P4-U1 S4 勾选发射（可勾） |
| 验收要点"列表流畅" | §6bis 走查项 21（>50 行人工滑动感知）+ §3.5（可视区按需创建/高频路径增量通知） |
| 验证 [A]+[P]走查 | §7-[A]（hvigor+35 单测）+ §7-[P]（P4-U1 S1~S3 机械判定 + S4 人工走查） |
| 前置 U3.1 | manager API/hooks 机制原样消费零改动（§1 显式不动清单）；F3/D9 遗留闭环（D10/D17） |

## 8. 风险与备注

1. **sys.symbol 资源名不确定**（本地 SDK 无名表，本会话实测）：编码期 DevEco 补全核实；任一无效名在资源编译期报错即改——兜底分支（首字母 Text）保证走查不被图标阻塞； icons 语义映射 1:1 已由 iconCategoryKeyForExtension 固化（[A] 单测覆盖）。
2. **LazyForEach 与 @ObjectLink 组合**：行组件 @ObjectLink record 在 LazyForEach 复用/回收下的刷新依赖键值稳定（record.id）——键值生成器必传且恒 id；禁在 itemGenerator 内做过滤/排序（getData 耗时告诫）。
3. **选中态双载体一致性**：selectedIds（Index 权威）与 record.uiSelected（渲染镜像）由 selectRow/toggleRowSelect/clearSelection 三口子单点维护；removeById 前须先清该行选中（handleToolbarDelete 内序）；分类切换清空（D4）防跨过滤选中。
4. **S3 探针与 Index 单例竞争**（U3.1 §0-9 同款）：S3 init 接管事件袋——手册次序红线"先走查后探针"；探针会话内不切页。
5. **DB 行残留**：S3 每轮 +2（probe-p4u1-<runId>-*），与既有探针同口径不清理；S1/S2 纯内存零残留。
6. **U4.2 输入交接**：右键菜单 18 项清单与启用规则（AppController.cs:730-791）、ConfirmDelete 对话框（approved+deleteFiles）、DeleteAllFinishedDownloads（MessageBox MENU_DELETE_COMPLETED 文案→finishedList.Clear()）、进度窗口（LiveSlot.nonInteractive 预留）、菜单 12 项动作接线——均已在 §4 各 D 行登记锚点，U4.2 设计书按此续接。
