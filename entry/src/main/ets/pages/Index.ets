/*
 * U1.2 主列表页 → U4.1 主窗口框架升级（设计书 §5.10 八处改动面）。
 * 布局对照 MainWindow.xaml：Row[分类面板 190 | Column[工具栏钮面(:318-447)+搜索行(:448-493)
 * +内容区+状态栏(:508-576)]]；内容区=Tabs 双列表（U1.2 既有容器保留，D1 分类树+Tabs 并存双向联动）。
 * 渲染层（决策 11/§3.5）：LazyForEach(inProgressDS/finishedDS)+IDataSource 替换 @State 数组直改；
 * 结构变更必走 DS 的 notifyDataAdd/Delete/Reloaded；字段级刷新靠 @Observed+@ObjectLink（行组件
 * @ObjectLink 只读，本页仍是 record 字段唯一写者）；keyGenerator 恒 record.id；不用
 * LazyForEachOptions（API 26+，本工程 API 24）。
 * 事件面零破坏红线（§0-7）：Downloader.ets/DownloadManager.ets/NewDownloadDialog.ets 零改动；
 * buildEngineEvents 与五事件消费方（handleStarted/Connected/Progress/Paused/Failed）逻辑逐字节
 * 保留；handleFinished 仅把 splice/unshift 换 DS 调用。
 * U3.1 复核闭环（D9/D10/D17）：manager.init 传 hooks（onQueuedCancelled→store.updateStatus(Stopped)，
 * 排队取消 DB 回声；内存 status=Stopped 由 stopOne queued 分支已置，同一 record 引用）；handleToggle
 * 三分支 isLive→stopOne / isQueued→stopOne / else resumeOne（F3 死按钮闭环）。
 * 分类状态机（§3.1）：selectCategory 对照 lvCategory_SelectionChanged+ApplyFilter（清搜索框→过滤→
 * 重算工具栏/计数）；CategoryChanged/SelectionChanged 事件面不建对应物（D16，直接同步调
 * recomputeToolbar）。搜索（§3.2）：触发点仅搜索按钮/分类切换，只作用完成数据源（D13 源码同貌）。
 * 多选交互（D3）：行点击单选替换+行内 Checkbox 多选开关；工具栏状态机按 selectedCount 消费。
 * 启动默认视图=已完成（D15，源码 ctor:104 SwitchToFinishedView）。
 * 工具栏接线（§0-6/D7）：New=bindMenu 新建下拉 3 项（第 1 项开对话框）；Pause/Resume 对选中集逐 id
 * stopOne/resumeOne（与行按钮同路径零新引擎面）；Delete U4.2 升级两分支（进行中先停后确认删/
 * 完成确认框含删文件勾选，UIActions.cs:19-55）；OpenFile/OpenFolder
 * 状态机 1:1 渲染、点击动作占位（D6，U5.2 能力面）。
 * 汉堡菜单 12 项（D5）占位禁用（MenuElement.enabled=false，动作 U4.2 接线）；状态栏三触点占位
 * 禁用（D12）。i18n：触面字面量切 $r（D11 键骨架）；走查清单未触面的中文提示（删除确认/空态）留待 U4.3。
 * U4.2 对话框包接线（设计书 §5.11 八处改动面）：进度窗宿主 init+五事件处理器尾部 host 转发（既有
 * 字段写序逐字节不动，仅追加分发；handleFailed 签名追加 errorCode 透传供 host 状态文本）；批量→选择
 * 会话链；行右键菜单 Refresh link/Show progress 两项（差异 #17）。U6.3 接入持久化刷新与
 * Referer 浏览器打开；当前下载轮次保留原请求，下次启动使用新版。业务日志 hilog domain 0x0000。
 * U4.3 三处接线（设计书 §1-#14）：①title_settings→pushPathByName('settings',1)（源恒开常规页签
 * 同貌）②settings_monitoring→(…,0) ③menu_lang→LanguageDialog；Navigation 追加
 * .navDestination builder（pathStack :123 首次启用）；既有事件面/字段写序逐字节不动。
 * U5.1 三处增量（设计书 §1-#10；既有字段写序逐字节不动，ProgressNotifier 只在尾部追加转发
 * ——U4.2 progressHost 同款手法）：①五 handler 尾部 notifier 转发（started→onDownloadStarted/
 * progress→onDownloadProgress/paused→onDownloadEnded('paused')/failed→onDownloadEnded('failed')/
 * finished→onDownloadEnded('finished')，Size 回退 finishedSize(record.size,finalFileSize)）；
 * ②menu_exit 启用；③新增 handleMenuExit→terminateSelf（WPF menuExit Environment.Exit(0) 1:1，D4）。
 * U5.2 六处增量（设计书 §1-#14；五 handler 既有写序逐字节不动，全部尾部/既有 if 块内追加）：
 * ①模块级 openPrompts Set（NewDownloadPromptTracker 对应物 D10）+成员 newDownloadModel/
 * pendingPromptUrl（声明先于 dialogController——builder 构造期捕获引用 keyConstraint #2）；
 * ②dialogController builder 追加 model/onClosed、refreshLinkController 摘除 onOpenReferer 死接线
 * （INT-F5）；③新增 onClipboardUrl（AddDownload 分流 1:1）/onNewDownloadClosed（PromptClosed）；
 * ④aboutToAppear 尾部 ClipboardWatcher.setUrlHandler；⑤onOpenPlaceholder→handleOpenAction
 * （UIActions :76-120 状态机 1:1+SaveDirectory.openFile 真实能力）；⑥removeRecords 成功分支消费
 * StateStore.removeById（R3-F1）+成品 unlink；handleFinished 尾部 syncFinishedFile（D1 拷贝链）；
 * onShowProgressMenu isLive 门（INT-F6）；handleStarted modelOf 块内尾部 speedText/etaText 复位（D12）。
 * U6.2 两处增量（设计书 u6-2 §1-#7；其余零改动）：①菜单项 msg_media_capture（源 MainWindow.xaml:65
 * menuMediaGrabber 同位）启用→pushPathByName('videoCapture','')；②settingsNavDestination builder
 * 追加 videoCapture 分支装 VideoCapturePage（既有 settings 分支零改动）。
 * OPT-1 四处改动（设计书 §1-#7；既有字段写序逐字节不动，全部纯追加/等价替换）：①四子组件接线
 * （CategoryPanel/ToolbarBar/InProgressPane/FinishedPane 纯搬迁零行为变更——表头 HeaderRow/
 * SortHeaderCell/sortArrow 与行右键菜单 RowContextMenu 留本页，经 `() => void` 闭包 prop
 * （@BuilderParam——CustomBuilder 联合含 void 分支调用点 10505001 不可调用）注入
 * 双 pane；五事件处理器/buildEngineEvents/recomputeToolbar 及其五消费点/computeToolbarState/
 * tabsSyncGuardView 防回环逐字节零改动）；②余下 hex 资源化（$r('app.color.*')——base+dark 双份
 * color.json，U4.3 setColorMode 链零改动自动生效；表头箭头 accent/表头底边与状态栏顶边 divider/
 * 状态栏两钮 control_bg）；③onSearchClick 头部加分类 0 早退（§3.2 对齐源 ApplyFilter index==0
 * 零过滤分支）；④新增 sweepOrphanWaiting 私有方法 + initLists 内 setAdmissionReady(true)（同步
 * drain）之后两行调用（§3.1 僵死 Waiting 行装载清扫——仅内存不落库，落点三重保护见方法头注）。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { bundleManager, common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { KeyCode } from '@kit.InputKit';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { DownloadRecord } from '../model/DownloadRecord';
import { DownloadCreationRequest, BridgeInboxItem, cloneDownloadCreationRequest } from '../model/DownloadCreationRequest';
import { DownloadCreationService } from '../core/engine/DownloadCreationService';
import { BridgeInbox } from '../core/bridge/BridgeInbox';
import { LinkRefresher, LinkRefreshObserver } from '../core/bridge/LinkRefresher';
import { DownloadRunRequest } from '../model/DownloadRunRequest';
import { cloneDownloadRequestContext, DownloadRequestContext } from '../model/DownloadRequestContext';
import { resolveRunRequest } from '../core/engine/DownloadRequestState';
import { RestoredPieces } from '../core/engine/PieceAlgo';
import { joinTempDir } from '../core/db/RecordMapping';
import { DownloadStatus, AuthenticationInfo, ProxyInfo, FileNameFetchMode, DownloadKind } from '../model/DownloadTypes';
import { DownloadStore, DownloadLists } from '../core/db/DownloadStore';
import { Config } from '../core/Config';
import { StateStore } from '../core/db/StateStore';
import { SaveDirectory } from '../core/fs/SaveDirectory';
import { ClipboardWatcher } from '../core/clipboard/ClipboardWatcher';
import { DownloadEvents, ForwardDownloadEvents } from '../core/engine/Downloader';
import { DownloadManager, ManagerHooks } from '../core/engine/DownloadManager';
import { NewDownloadDialog, NewDownloadModel } from '../components/NewDownloadDialog';
import {
  ProgressWindowHost,
  ProgressWindowActions,
  ProgressWindowModel
} from '../components/ProgressWindowDialog';
import { BatchDownloadDialog } from '../components/BatchDownloadDialog';
import {
  DownloadSelectionDialog,
  SelectionItemModel,
  SelectionSession
} from '../components/DownloadSelectionDialog';
import { DeleteConfirmDialog } from '../components/DeleteConfirmDialog';
import { RefreshLinkDialog, RefreshLinkModel } from '../components/RefreshLinkDialog';
import { LanguageDialog } from '../components/LanguageDialog';
import { SettingsPage, SETTINGS_TAB_MONITORING, SETTINGS_TAB_GENERAL } from './Settings';
import { VideoCapturePage } from './VideoCapture';
import { DownloadListDataSource } from '../model/DownloadListDataSource';
import {
  DownloadListItem,
  COL_BUTTON_WIDTH,
  COL_CHECKBOX_WIDTH,
  COL_FLEX_DATE,
  COL_FLEX_NAME_FINISHED,
  COL_FLEX_NAME_INPROGRESS,
  COL_FLEX_PROGRESS,
  COL_FLEX_SIZE,
  COL_FLEX_STATUS,
  COL_ICON_WIDTH
} from '../components/DownloadListItem';
import { CategoryDef, DEFAULT_CATEGORIES } from '../core/util/CategoryAlgo';
import { ToolbarState, computeToolbarState } from '../core/util/ToolbarAlgo';
import { StatusLabels } from '../core/util/StatusText';
import { SortKey } from '../core/util/ListAlgo';
import { formatSpeed, toHMS, formatSize } from '../core/util/Formatting';
import { fileNameFromUrl } from '../core/util/FileNames';
import { isUriValid } from '../core/net/HttpProtocol';
import { ProgressNotifier } from '../core/notify/ProgressNotifier';
import { finishedSize } from '../core/notify/NotifyAlgo';
// OPT-1 四子组件（纯搬迁自本页：CategoryPanel←:115-155/:1827-1851、ToolbarBar←:1855-1931、
// InProgressPane/FinishedPane←:1711-1798 @Builder）
import { CategoryPanel } from '../components/CategoryPanel';
import { ToolbarBar, SEARCH_INPUT_ID } from '../components/ToolbarBar';
import { SystemPromptGate } from '../core/util/SystemPromptGate';
import { InProgressPane } from '../components/InProgressPane';
import { FinishedPane } from '../components/FinishedPane';

// OPT-1：分类面板常量表/CategoryPanelItem/categoryIconResource 迁入 components/CategoryPanel.ets；
// CATEGORY_HIGHLIGHT/ROW_SELECTED_BG 两常量删除改语义色资源——'#E3F2FD' 同值不同义拆
// category_normal_bg/row_selected_bg 两键使 dark 侧分叉（#1B1C1E vs #114C7B，设计书 §0-4）。

/** per-URL 单实例集（U5.2 D10：NewDownloadPromptTracker.newDownloadPrompts 对应物——源
 * static HashSet+lock → ArkTS 主线程事件循环天然串行无锁，Config.ets D1 先例）。
 * 登记时机=对话框 open 前（PromptOpen :269），摘除时机=对话框关闭回调（PromptClosed）。 */
const openPrompts: Set<string> = new Set<string>();

@Entry
@Component
struct Index {
  /** Phase 4 NavDestination 路由预留（本单元无子页；U6.2 媒体嗅探页将来走 NavDestination D5） */
  private pathStack: NavPathStack = new NavPathStack();
  /** 双列表数据源（成员非 @State——DS 内部变更经 DataChangeListener 驱动 LazyForEach，引用不变） */
  private inProgressDS: DownloadListDataSource = new DownloadListDataSource();
  private finishedDS: DownloadListDataSource = new DownloadListDataSource();
  /** 分类索引（D15 默认 1=已完成，源码 ctor:104）；activeView=Tabs 同步序号（D1 双向联动） */
  @State activeCategoryIndex: number = 1;
  @State activeView: number = 1;
  /** 程序化同步防回环标记：selectCategory 同步 activeView 前记录目标序号，
   * onChange 命中即回环吞掉（防回环 guard，§0-1；标记值恒等于当前视图，用户切换必异值不误吞） */
  private tabsSyncGuardView: number = -1;
  @State searchText: string = '';
  /** 选中态（D3）：selectedIds=权威选中集（非 @State——渲染镜像在 record.uiSelected @Observed） */
  private selectedIds: Set<string> = new Set();
  @State selectedCount: number = 0;
  /** Footer browser-monitoring switch (source main-window toggle: write config + broadcast). */
  @State monitoringEnabled: boolean = true;
  private monitoringListener: () => void = (): void => {
    this.monitoringEnabled = Config.getInstance().getIsBrowserMonitoringEnabled();
    Config.getInstance().onConfigChanged(this.monitoringListener);
  };
  @State toolbarState: ToolbarState = computeToolbarState(false, 0, false);
  /** 分类计数（D2 口径：未过滤全长——顶层 0/1=两数据源 fullCount，子分类=扩展名匹配数） */
  @State categoryCounts: number[] = [0, 0, 0, 0, 0, 0, 0];
  @State inProgressCount: number = 0;
  @State finishedCount: number = 0;
  /** 表头箭头重渲染锚（DS.sortState() 非 @State 不可追踪，列头点击后自增触发表头刷新） */
  @State sortVersion: number = 0;
  /** 状态列标签（§3.6：Index 装配一次传入，行内零资源查询） */
  /** 搜索框是否获焦（ToolbarBar 回报；快捷键据此让出文本编辑按键） */
  private searchFocused: boolean = false;
  private statusLabels: StatusLabels = {
    downloading: 'Downloading',
    stopped: 'Stopped',
    finished: 'Finished',
    waiting: 'Waiting'
  };
  private tabsController: TabsController = new TabsController();
  /** U5.2 预填载体（拍板⑦共享对象模式）：必须声明在 dialogController 之前——builder 构造期
   * 捕获引用，open 前写 initialUrl（keyConstraint #2，RefreshLinkModel 先例） */
  private newDownloadModel: NewDownloadModel = new NewDownloadModel();
  /** 当前待关 URL 快照（对话框 aboutToDisappear 回调摘除 openPrompts 用） */
  private pendingPromptUrl: string = '';
  /** 提示串行队列（R2-F2）：单对话框投影下提示对话框在开时命中的新 URL 入队，
   * 关闭回调逐个出队重开（源=每 URL 各自弹窗并行——Application.cs:263-276 每次新建窗口；
   * CustomDialogController 单实例无法并行多窗，串行重放近似保语义无泄漏，设计书 D17） */
  private promptQueue: string[] = [];
  private pageActive: boolean = false;
  private listReady: boolean = false;
  private loadGeneration: number = 0;
  private addedDuringLoad: Map<string, DownloadRecord> = new Map();
  private engineDuringLoad: Array<() => void> = [];
  private promptOpen: boolean = false;
  private activeInbox: BridgeInboxItem | null = null;
  private addedListener: (record: DownloadRecord) => void = (record: DownloadRecord): void => {
    if (!this.listReady) {
      this.addedDuringLoad.set(record.id, record);
      return;
    }
    if (this.findById(record.id) === null) {
      this.inProgressDS.addSorted(record);
      this.recomputeCounts();
      this.recomputeToolbar();
    }
  };
  private inboxListener: () => void = (): void => { this.openNextInbox(); };
  private dialogController: CustomDialogController = new CustomDialogController({
    width: 560,
    backgroundColor: $r('app.color.dialog_bg'),
    backgroundBlurStyle: BlurStyle.NONE,
    cornerRadius: 16,
    builder: NewDownloadDialog({
      model: this.newDownloadModel,
      onConfirm: (url: string, fileName: string, fetchMode: number): Promise<boolean> => {
        return this.confirmNewDownload(url, fileName, fetchMode);
      },
      onCancel: (): Promise<boolean> => {
        return this.cancelActiveInbox();
      },
      onClosed: (): void => {
        this.onNewDownloadClosed();
      }
    }),
    autoCancel: false
  });
  /** U4.2 对话框面（§5.11-2）：进度窗宿主 + 五单实例窗的 session/model 共享对象
   * （keyConstraint #2：builder 构造期绑定，open 前改字段禁重建 controller——共享对象先于
   * controller 声明，成员初始化序内 this 引用稳定） */
  private progressHost: ProgressWindowHost = ProgressWindowHost.getInstance();
  private selectionSession: SelectionSession = new SelectionSession();
  private refreshModel: RefreshLinkModel = new RefreshLinkModel();
  private refreshToken: number = 0;
  private refreshWindowToken: number = 0;
  private pendingRefreshId: string = '';
  private refreshObserver: LinkRefreshObserver = {
    onAccepted: (token: number, id: string, request: DownloadRunRequest): void => {
      this.onRefreshAccepted(token, id, request);
    },
    onFailed: (token: number, id: string): void => {
      if (this.pageActive && token === this.refreshToken) {
        this.refreshModel.failed = true;
      }
    }
  };
  /** 完成分支 Delete 确认的待删 id 快照（确认回调时消费） */
  private pendingDeleteIds: string[] = [];
  /** 行右键菜单目标行 id（R2-F1：右键时经 ContextMenuOptions.onAppear 捕获——右键不触发
   * 行 onClick 选中，菜单分派不得依赖 firstSelectedId；WPF 右键即选中同构） */
  private contextMenuRowId: string = '';
  /** 对话框标签（stat_downloading/msg_time_left——进度窗 statusText/etaText 组装原料） */
  private labelStatDownloading: string = 'Downloading';
  private labelMsgTimeLeft: string = 'Time left';
  private batchDialogController: CustomDialogController = new CustomDialogController({
    width: 720,
    backgroundColor: $r('app.color.dialog_bg'),
    backgroundBlurStyle: BlurStyle.NONE,
    cornerRadius: 16,
    builder: BatchDownloadDialog({
      onConfirm: (links: string[]): void => {
        this.onBatchConfirm(links);
      },
      onCancel: (): void => {
      }
    }),
    // 源 Show()（UIController Run :42-45）非模态分型
    isModal: false,
    autoCancel: true
  });
  private selectionDialogController: CustomDialogController = new CustomDialogController({
    width: 760,
    backgroundColor: $r('app.color.dialog_bg'),
    backgroundBlurStyle: BlurStyle.NONE,
    cornerRadius: 16,
    builder: DownloadSelectionDialog({
      session: this.selectionSession,
      onConfirm: (items: SelectionItemModel[], auth: AuthenticationInfo | null,
        proxy: ProxyInfo | null, startImmediately: boolean): Promise<boolean> => {
        return this.onSelectionConfirm(items, auth, proxy, startImmediately);
      },
      onCancel: (): Promise<boolean> => {
        return this.cancelActiveInbox();
      },
      onClosed: (): void => {
        this.onNewDownloadClosed();
      }
    }),
    // 源 Show()（Run :54-57）非模态分型
    isModal: false,
    autoCancel: false
  });
  private deleteConfirmController: CustomDialogController = new CustomDialogController({
    width: 460,
    backgroundColor: $r('app.color.dialog_bg'),
    backgroundBlurStyle: BlurStyle.NONE,
    cornerRadius: 16,
    builder: DeleteConfirmDialog({
      onConfirm: (deleteFiles: boolean): void => {
        this.onDeleteConfirmed(deleteFiles);
      },
      onCancel: (): void => {
      }
    }),
    // 源 ShowDialog()（MainWindow.xaml.cs:316-327）模态分型（默认 isModal:true）
    autoCancel: true
  });
  private refreshLinkController: CustomDialogController = new CustomDialogController({
    width: 520,
    backgroundColor: $r('app.color.dialog_bg'),
    backgroundBlurStyle: BlurStyle.NONE,
    cornerRadius: 16,
    builder: RefreshLinkDialog({
      model: this.refreshModel,
      onStopped: (token: number): void => {
        this.onRefreshStopped(token);
      },
      onClosed: (token: number): void => {
        this.onRefreshClosed(token);
      }
    }),
    // 源 ShowWindow()（LinkRefreshDialogUIController :79）非模态分型；外部点击关窗=Stop 语义
    // WatchingStopped 由对话框 aboutToDisappear 按捕获的会话 token 兜底恰一次。
    isModal: false,
    autoCancel: true
  });
  /** U4.3 语言对话框（menu_lang 触发；LanguageSettingsWindow ShowDialog 模态分型） */
  private languageDialogController: CustomDialogController = new CustomDialogController({
    width: 420,
    backgroundColor: $r('app.color.dialog_bg'),
    backgroundBlurStyle: BlurStyle.NONE,
    cornerRadius: 16,
    builder: LanguageDialog({
      onCancel: (): void => {
      },
      onApplied: (): void => {
        // 资源配置更新异步落地：稍后再读 getStringSync
        setTimeout(() => {
          this.reloadLocalizedLabels();
        }, 300);
      }
    }),
    autoCancel: true
  });

  aboutToAppear(): void {
    this.monitoringEnabled = Config.getInstance().getIsBrowserMonitoringEnabled();
    this.pageActive = true;
    this.listReady = false;
    this.loadGeneration++;
    DownloadCreationService.getInstance().setAdmissionReady(false);
    DownloadCreationService.getInstance().subscribeAdded(this.addedListener);
    BridgeInbox.getInstance().subscribeChanged(this.inboxListener);
    SystemPromptGate.subscribeIdle(this.inboxListener);
    DownloadManager.getInstance().init(this.buildEngineEvents(), this.buildManagerHooks());
    this.statusLabels = this.buildStatusLabels();
    this.loadDialogLabels();
    // host.init（§5.11-2）：actionsFactory 闭包持 manager/record 定位（进度窗三按钮动作）
    this.progressHost.init(this.getUIContext(),
      (id: string): ProgressWindowActions => this.buildProgressActions(id));
    this.initLists();
    // U5.2 尾部追加（设计书 §1-#14④）：剪贴板命中接线——后到者接管（manager.init 同款惯例；
    // 应用级单例，aboutToDisappear 不摘——无泄漏面）
    ClipboardWatcher.getInstance().setUrlHandler((url: string): void => {
      this.onClipboardUrl(url);
    });
  }

  /** §8 风险缓解：页面销毁收口动态窗（进度/完成/限速 ComponentContent 残留） */
  aboutToDisappear(): void {
    Config.getInstance().offConfigChanged(this.monitoringListener);
    this.pageActive = false;
    this.loadGeneration++;
    // Persist queued engine echoes before detaching this page's hydration attempt.
    this.listReady = true;
    const events: Array<() => void> = this.engineDuringLoad.splice(0);
    for (let i = 0; i < events.length; i++) {
      events[i]();
    }
    DownloadCreationService.getInstance().setAdmissionReady(false);
    DownloadCreationService.getInstance().unsubscribeAdded(this.addedListener);
    BridgeInbox.getInstance().unsubscribeChanged(this.inboxListener);
    SystemPromptGate.unsubscribeIdle(this.inboxListener);
    if (this.activeInbox !== null) {
      BridgeInbox.getInstance().release(this.activeInbox.id);
      this.activeInbox = null;
    }
    this.dialogController.close();
    this.selectionDialogController.close();
    this.pendingRefreshId = '';
    this.onRefreshStopped(this.refreshToken);
    this.refreshLinkController.close();
    this.promptOpen = false;
    this.progressHost.closeAll();
  }

  /** 对话框标签装载（buildStatusLabels 同式：getStringSync(resId) + 英文 fallback） */
  /** 运行时切换语言（2026-11-19 修复：状态列/进度窗标签为启动时缓存，切换后仍显示旧语言）：
   * 原地改写 statusLabels（各行持同一引用）+ 双列表 reload 重建行 + 对话框/进度窗标签重载 */
  private reloadLocalizedLabels(): void {
    const fresh: StatusLabels = this.buildStatusLabels();
    this.statusLabels.downloading = fresh.downloading;
    this.statusLabels.stopped = fresh.stopped;
    this.statusLabels.finished = fresh.finished;
    this.statusLabels.waiting = fresh.waiting;
    this.loadDialogLabels();
    this.progressHost.reloadLabels();
    this.inProgressDS.notifyDataReloaded();
    this.finishedDS.notifyDataReloaded();
    const v: number = AppStorage.get<number>('xdmLabelsVersion') ?? 0;
    AppStorage.setOrCreate<number>('xdmLabelsVersion', v + 1);
  }

  private loadDialogLabels(): void {
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      return;
    }
    try {
      this.labelStatDownloading = ctx.resourceManager.getStringSync($r('app.string.stat_downloading').id);
      this.labelMsgTimeLeft = ctx.resourceManager.getStringSync($r('app.string.msg_time_left').id);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, 'Index', '%{public}s',
        'loadDialogLabels failed errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
    }
  }

  /** 进度窗动作装配（§2.1 表三按钮+限速文本；BtnPause/BtnStop/BtnHide/TxtSpeedLimit 同位） */
  private buildProgressActions(id: string): ProgressWindowActions {
    const actions: ProgressWindowActions = new ProgressWindowActions();
    actions.onPauseResume = (): void => {
      const model: ProgressWindowModel | undefined = this.progressHost.modelOf(id);
      const record: DownloadRecord | null = this.findById(id);
      if (model === undefined || record === null) {
        return;
      }
      if (model.resumable) {
        // BtnPause_Click if 分支（:218-222）：Resume + 按钮回 Pause
        DownloadManager.getInstance().resumeOne(record);
        model.resumable = false;
      } else {
        // else 分支（:224）：停不下窗——取消回声（onPaused 尾部转发）再置 Resume
        DownloadManager.getInstance().stopOne(id);
      }
    };
    actions.onStop = (): void => {
      // BtnStop_Click（:227-230，StopDownload(true) 语义）：stopOne + 直接关窗兜底
      DownloadManager.getInstance().stopOne(id);
      this.progressHost.closeFor(id);
    };
    actions.onHide = (): void => {
      // BtnHide_Click（:233-238）：仅关窗不停（HideProgressWindow :643-651 同位）
      this.progressHost.hideFor(id);
    };
    actions.onOpenSpeedLimiter = (): void => {
      // TxtSpeedLimit_MouseDown（:240-242 → ShowSpeedLimiterWindow 同位）
      this.progressHost.openSpeedLimiter();
    };
    return actions;
  }

  /** 初始化序列（§5.8-4）：initialize（幂等 ready 门）→ queryAll 双列表 DS 装载；失败留空 + 日志 */
  private async initLists(): Promise<void> {
    const generation: number = this.loadGeneration;
    const store: DownloadStore = DownloadStore.getInstance();
    try {
      const ctx = this.getUIContext().getHostContext();
      if (ctx !== undefined) {
        await store.initialize(ctx);
      }
      const lists: DownloadLists = await store.queryAll();
      if (generation !== this.loadGeneration) {
        return;
      }
      const pending: DownloadRecord[] = DownloadCreationService.getInstance().getPendingAdmissions();
      for (let i = 0; i < pending.length; i++) {
        this.addedDuringLoad.set(pending[i].id, pending[i]);
      }
      this.addedDuringLoad.forEach((record: DownloadRecord, id: string): void => {
        const existing: number = lists.inProgress.findIndex((item: DownloadRecord): boolean => item.id === id);
        if (existing >= 0) {
          lists.inProgress[existing] = record;
        } else {
          lists.inProgress.push(record);
        }
      });
      this.addedDuringLoad.clear();
      this.inProgressDS.initialize(lists.inProgress);
      this.finishedDS.initialize(lists.finished);
      this.listReady = true;
      const events: Array<() => void> = this.engineDuringLoad.splice(0);
      for (let i = 0; i < events.length; i++) {
        events[i]();
      }
      this.recomputeCounts();
      this.recomputeToolbar();
      DownloadCreationService.getInstance().setAdmissionReady(true);
      // OPT-1 僵死 Waiting 行装载清扫（设计书 §3.1；initLists 既有行零改序，纯追加两行）：
      // 落点=setAdmissionReady(true)（同步 drain）之后——待接纳行门过 launchStart/launchResume
      // 已同步 liveMap.set（isLive 保护）、门挡 enqueue（isQueued 保护），drain 前清扫会把合法
      // 待接纳行误置 Stopped 形成反向僵尸（DownloadManager.ets:181-184 门挡入队不补写 status）。
      // 先于 openNextInbox()：首帧提示窗弹出前列表状态已正确。
      this.sweepOrphanWaiting(lists.inProgress);
      this.sweepOrphanWaiting(lists.finished);
      await BridgeInbox.getInstance().initialize();
      if (generation === this.loadGeneration) {
        this.openNextInbox();
      }
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, 'Index', '%{public}s',
        'initLists failed errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
    }
  }

  /** 引擎事件适配器（单实例共享；各回调按 id 定位 record）。
   * hvigor 实测：DownloadEvents 方法签名接口不可用对象字面量装配（arkts-no-untyped-obj-literals）——
   * 改经 ForwardDownloadEvents 实现类做闭包转发。U4.1 零改动（事件面零破坏红线 §0-7）。 */
  private deliverEngineEvent(event: () => void): void {
    if (!this.listReady) {
      this.engineDuringLoad.push(event);
    } else {
      event();
    }
  }

  /** OPT-1 僵死 Waiting 行装载清扫（设计书 §3.1，源读路径强制 Stopped 的内存面对应物——
   * DownloadList.cs:95/:165 completed=0 行无条件 Stopped；鸿蒙 DB 面已由 RecordMapping R2 同构，
   * 僵尸仅存在于内存面：resumeOne 门挡入队置 Waiting 仅 UI 内存 DownloadManager.ets:207、工厂
   * startWaiting=true 待接纳行 DownloadCreationService.ets:149-153——status 与 manager 队列生命
   * 周期错位时 toggleLabel（DownloadListItem.ets:69-77 三分支只看 record.status）呈"取消排队"
   * 死按钮+状态列 Waiting 僵尸文本）。归一 Waiting→Stopped 仅内存不落库（DB 读出面本无 Waiting，
   * 不落库回声与源读路径不回写同构）；一次修复按钮+状态列双消费点，不改 toggleLabel、行组件
   * 不越层调 manager（Index 恒 record 字段唯一写者红线）。
   * 传入数组=initLists 局部 lists.inProgress/finished（DownloadListDataSource.initialize 浅拷贝
   * DownloadListDataSource.ets:53，元素引用与 DS 内同一对象——改 status 即改 DS 行，@Observed
   * 驱动行刷新）；主线程同步 O(n) 单次遍历，isLive/isQueued 为同步 Map 读（DownloadManager.ets
   * :244-250）。三重保护论证（§3.1）：①待接纳行 drain 后 liveMap/queueMap 保护或异常重存
   * pendingAdmissions（归一 Stopped 语义正确=持久记录保留可手动恢复）；②DB 装载行 R2 恒 Stopped
   * 恒 no-op；③重放只经五事件处理器写 status（Downloading/Stopped/Finished）不产生 Waiting。 */
  private sweepOrphanWaiting(records: DownloadRecord[]): void {
    const manager: DownloadManager = DownloadManager.getInstance();
    for (let i = 0; i < records.length; i++) {
      const record: DownloadRecord = records[i];
      if (record.status === DownloadStatus.Waiting && !manager.isLive(record.id) &&
        !manager.isQueued(record.id)) {
        record.status = DownloadStatus.Stopped;
      }
    }
  }

  private buildEngineEvents(): DownloadEvents {
    return new ForwardDownloadEvents(
      (id: string): void => {
        this.deliverEngineEvent((): void => { this.handleStarted(id); });
      },
      (id: string, status: number, totalSize: number, resumable: boolean, contentType: string): void => {
        this.deliverEngineEvent((): void => { this.handleConnected(id, totalSize); });
      },
      (id: string, progress: number, instantSpeed: number, etaSeconds: number,
        downloadedBytes: number): void => {
        this.deliverEngineEvent((): void => { this.handleProgress(id, progress, instantSpeed, etaSeconds, downloadedBytes); });
      },
      (id: string, offsetBytes: number): void => {
        this.deliverEngineEvent((): void => { this.handlePaused(id, offsetBytes); });
      },
      (id: string, finalFileSize: number, filePath: string): void => {
        this.deliverEngineEvent((): void => { this.handleFinished(id, finalFileSize, filePath); });
      },
      (id: string, errorCode: number, errorMessage: string): void => {
        this.deliverEngineEvent((): void => { this.handleFailed(id, errorCode); });
      }
    );
  }

  /** 排队取消 DB 回声（D9/U3.1 复核闭环）：stopOne queued 分支已置内存 status=Stopped（同一
   * record 引用），本钩子把 Stopped 落库（源码 DownloadCanelled→UpdateDownloadStatus 链）。
   * 类型化字面量装配（ProbeQueue.ets:419-421 先例，arkts-no-untyped-obj-literals 同证）。 */
  private buildManagerHooks(): ManagerHooks {
    const hooks: ManagerHooks = {
      onQueuedCancelled: (id: string): void => {
        DownloadStore.getInstance().updateStatus(id, DownloadStatus.Stopped).catch((err: BusinessError) => {
          hilog.error(0x0000, 'Index', '%{public}s',
            'queuedCancel echo updateStatus failed errCode=' + String(err.code) +
            ' errMessage=' + (err.message ?? ''));
        });
      }
    };
    return hooks;
  }

  /** 状态列标签装配（§3.6：getStringSync 一次；失败回退英文常量=string.json base 同值） */
  private buildStatusLabels(): StatusLabels {
    const fallback: StatusLabels = {
      downloading: 'Downloading',
      stopped: 'Stopped',
      finished: 'Finished',
      waiting: 'Waiting'
    };
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      return fallback;
    }
    try {
      // getStringSync(resource: Resource) 已弃用（@useinstead getStringSync，resId: number 变体
      // ——resourceManager.d.ts:2376/:2378 核实），走 $r(...).id 数字 id 重载避告警
      const labels: StatusLabels = {
        downloading: ctx.resourceManager.getStringSync($r('app.string.stat_downloading').id),
        stopped: ctx.resourceManager.getStringSync($r('app.string.stat_stopped').id),
        finished: ctx.resourceManager.getStringSync($r('app.string.stat_finished').id),
        waiting: ctx.resourceManager.getStringSync($r('app.string.stat_waiting').id)
      };
      return labels;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, 'Index', '%{public}s',
        'buildStatusLabels failed errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
      return fallback;
    }
  }

  /** 新建下载确认链（对照 Application.StartDownload/AddItemToTop 语义；U3.1 起经 manager）：
   * 工厂（startWaiting=true，D13 对齐 AddItemToTop :55 落库 Waiting）→ fetchMode 覆盖 → add →
   * DS 变更（§3.3：addSorted 全量 Append+投影按序插入+notifyDataAdd）→ manager.admitNew
   * （store.add→DS 变更→admitNew 次序红线不变）。 */
  private async startNewDownload(url: string, fileName: string, fetchMode: number): Promise<void> {
    const request: DownloadCreationRequest = new DownloadCreationRequest();
    request.url = url;
    request.name = fileName;
    request.fetchMode = fetchMode;
    request.targetDir = Config.getInstance().getDownloadDir();
    await DownloadCreationService.getInstance().create(request);
  }

  private async confirmNewDownload(url: string, fileName: string, fetchMode: number): Promise<boolean> {
    const generation: number = this.loadGeneration;
    if (this.activeInbox === null) {
      await this.startNewDownload(url, fileName, fetchMode);
    } else {
      const id: string = this.activeInbox.id;
      const request: DownloadCreationRequest = cloneDownloadCreationRequest(this.activeInbox.requests[0]);
      request.url = url;
      request.name = fileName;
      request.fetchMode = fetchMode;
      await BridgeInbox.getInstance().confirm(id, [request]);
      if (!this.pageActive || generation !== this.loadGeneration || this.activeInbox?.id !== id) {
        return false;
      }
      this.activeInbox = null;
    }
    return this.pageActive && generation === this.loadGeneration;
  }

  private async cancelActiveInbox(): Promise<boolean> {
    const generation: number = this.loadGeneration;
    if (this.activeInbox !== null) {
      const id: string = this.activeInbox.id;
      await BridgeInbox.getInstance().cancel(id);
      if (!this.pageActive || generation !== this.loadGeneration || this.activeInbox?.id !== id) {
        return false;
      }
      this.activeInbox = null;
    }
    return this.pageActive && generation === this.loadGeneration;
  }

  private openNextInbox(): void {
    if (!this.pageActive || !this.listReady || this.promptOpen) {
      return;
    }
    // 系统授权弹窗在屏时 ArkUI 不挂接对话框（见 SystemPromptGate 头注），等授权结束后由 idle 回调补弹
    if (SystemPromptGate.busy()) {
      return;
    }
    const inbox: BridgeInbox = BridgeInbox.getInstance();
    const item: BridgeInboxItem | null = inbox.peekNext();
    if (item === null || !inbox.claim(item.id)) {
      return;
    }
    this.activeInbox = item;
    this.promptOpen = true;
    // HLS/DASH/dual-source captures with a valid adaptive descriptor use the normal dialog below
    // (BridgeInbox.confirm pins the captured descriptor); anything else stays explicitly unsupported.
    const adaptiveReady: boolean = item.requests.length === 1 && item.requests[0].adaptive !== null;
    if (item.kind === 'video' && item.videoKind !== 'video' && !adaptiveReady) {
      const generation: number = this.loadGeneration;
      this.getUIContext().showAlertDialog({
        message: $r('app.string.msg_video_download_unavailable'),
        autoCancel: false,
        primaryButton: { value: $r('app.string.nd_cancel'), action: (): void => {
          if (!this.pageActive || generation !== this.loadGeneration || this.activeInbox?.id !== item.id) {
            return;
          }
          this.cancelActiveInbox().then((ok: boolean): void => {
            if (ok && this.pageActive && generation === this.loadGeneration) { this.onNewDownloadClosed(); }
          }).catch((): void => {
            if (this.pageActive && generation === this.loadGeneration) {
              this.getUIContext().showAlertDialog({ message: $r('app.string.msg_download_save_failed') });
              this.onNewDownloadClosed();
            }
          });
        } }
      });
      return;
    }
    if (item.kind === 'batch') {
      const items: SelectionItemModel[] = [];
      for (let i = 0; i < item.requests.length; i++) {
        const request: DownloadCreationRequest = item.requests[i];
        const selection: SelectionItemModel = new SelectionItemModel();
        selection.url = request.url;
        selection.name = request.name;
        selection.size = request.size;
        selection.contextUrl = request.contextUrl;
        selection.requestContext = request.requestContext;
        items.push(selection);
      }
      this.selectionSession.items = items;
      this.selectionSession.auth = null;
      this.selectionSession.proxy = null;
      this.selectionSession.saveIn = Config.getInstance().getDownloadDir();
      this.selectionDialogController.open();
    } else {
      const request: DownloadCreationRequest = item.requests[0];
      this.newDownloadModel.initialUrl = request.url;
      this.newDownloadModel.initialName = request.name;
      this.newDownloadModel.initialSize = request.size;
      this.dialogController.open();
    }
  }

  /** 剪贴板命中分流（U5.2：ApplicationCore.AddDownload :208-236 状态机 1:1；ClipboardWatcher
   * urlHandler 接线）：
   * LinkAccepted 拦截位注释锚（D6：源 :209 if (LinkRefresher.LinkAccepted(message)) return——
   * U5.2 恒 false 不建死代码，refreshLinkCandidate 无登记方，U6.x 桥接时在此补判）；
   * 自动开始分支（:214-231）复用 startNewDownload（D7：工厂+store.add+admitNew 链等价
   * SingleSourceHTTPDownloadInfo{Uri,File=SanitizeFileName(GetFileName(url))} 直启）；
   * 提示分支（:265-272）：per-URL 单实例集门（IsPromptAlreadyOpen）→登记（PromptOpen）→
   * 预填（message.Url → NewDownloadModel.initialUrl）→开窗（ShowNewDownloadDialog）。
   * 自动分支不登记 openPrompts（源无此门，lastClipboardText 去重已覆盖重复复制，拍板⑥）。 */
  private onClipboardUrl(url: string): void {
    if (Config.getInstance().getStartDownloadAutomatically()) {
      this.startNewDownload(url, fileNameFromUrl(url), FileNameFetchMode.FileNameAndExtension)
        .catch((): void => { this.getUIContext().showAlertDialog({ message: $r('app.string.msg_download_save_failed') }); });
      return;
    }
    if (openPrompts.has(url)) {
      return;
    }
    openPrompts.add(url);
    // R2-F2：提示对话框在开（单对话框投影）时入队串行重放——不覆盖 pendingPromptUrl 快照
    // （源=每 URL 各自弹窗并行，无此排队；目标侧 D17 登记，设计书 §4）
    if (this.promptOpen) {
      this.promptQueue.push(url);
      return;
    }
    this.promptOpen = true;
    this.pendingPromptUrl = url;
    this.newDownloadModel.initialUrl = url;
    this.dialogController.open();
  }

  /** 对话框关闭回调（U5.2：DestroyEvent→destroyCallback→PromptClosed :278-282 同位；任何
   * 关闭路径——确认/取消/外部点击——经 aboutToDisappear 恰一次，摘除单实例集锚）。
   * R2-F2：摘除后队列非空则出队下一个并延迟重开——重开走 setTimeout(0) 避开 aboutToDisappear
   * 拆卸中态（本回调由对话框 aboutToDisappear 触发）；出队 URL 已在入队时登记 openPrompts。 */
  private onNewDownloadClosed(): void {
    this.promptOpen = true;
    if (this.activeInbox !== null) {
      const releasedId: string = this.activeInbox.id;
      this.activeInbox = null;
      BridgeInbox.getInstance().release(releasedId);
    }
    this.promptOpen = false;
    if (this.pendingPromptUrl.length > 0) {
      openPrompts.delete(this.pendingPromptUrl);
      this.pendingPromptUrl = '';
    }
    if (this.pageActive && this.promptQueue.length > 0) {
      const next: string = this.promptQueue[0];
      this.promptQueue.splice(0, 1);
      this.promptOpen = true;
      this.pendingPromptUrl = next;
      this.newDownloadModel.initialUrl = next;
      const generation: number = this.loadGeneration;
      setTimeout((): void => {
        if (this.pageActive && generation === this.loadGeneration && this.promptOpen &&
          this.activeInbox === null && this.pendingPromptUrl === next) {
          this.dialogController.open();
        }
      }, 0);
    } else if (this.pageActive) {
      setTimeout((): void => { this.openNextInbox(); }, 0);
    }
  }

  /** New 菜单直开（R2-F3：Application.cs:414-420 NewDownloadClicked → CreateAndShowDialog(true)
   * message=null 直开路径；控制器剪贴板预填分支 NewDownloadDialogUIController.cs:57-64 同构
   * ——GetUrlFromClipboard（Application.cs:180-188）IsUriValid 门非空才预填）：
   * R3-F1——getData 前先经 ClipboardWatcher.requestReadPermission 显式申请（默认
   * monitorClipboard=false 时唯一申请点 watcher.start() 不触发，New 菜单是用户主动消费点=
   * 标准申请时机；会话级守卫幂等），申请终态后再读：首次点击弹授权框、点允许本次即得预填；
   * 拒绝/读失败（201）走 catch 静默保持空白（D9 同款降级=源 GetUrlFromClipboard 返 null 同貌）。
   * 不登记 openPrompts/pendingPromptUrl（源 New 按钮不经 NewDownloadPromptTracker，:263-276 仅
   * ShowNewDownloadDialog 有）；不触碰 promptQueue（模态对话框在开时主窗不可点，无并发面）。 */
  private openNewDownloadFromClipboard(): void {
    if (this.promptOpen) { return; }
    this.promptOpen = true;
    const generation: number = this.loadGeneration;
    ClipboardWatcher.getInstance().requestReadPermission()
      .then((): Promise<pasteboard.PasteData> => {
        return pasteboard.getSystemPasteboard().getData();
      })
      .then((data: pasteboard.PasteData): void => {
        if (!this.pageActive || generation !== this.loadGeneration || !this.promptOpen || this.activeInbox !== null) {
          return;
        }
        const text: string = data.getPrimaryText();
        if (text.length > 0 && isUriValid(text)) {
          this.newDownloadModel.initialUrl = text;
        }
        this.dialogController.open();
      })
      .catch((err: BusinessError): void => {
        hilog.warn(0x0000, 'Index', '%{public}s',
          'new download clipboard read skipped errCode=' + String(err.code));
        if (this.pageActive && generation === this.loadGeneration && this.promptOpen && this.activeInbox === null) {
          this.dialogController.open();
        }
      });
  }

  /** 行按钮分派（D17 三分支修正，F3 死按钮闭环）：isLive→stopOne（暂停/取消）；isQueued→stopOne
   * （取消排队——stopOne queued 分支不补位+内存 Stopped+hooks 回声落库）；否则 resumeOne
   * （幂等守卫吸收重复点击；门过 launchResume 起跑/门挡入队 status=Waiting 仅 UI 内存）。 */
  private handleToggle(id: string): void {
    const manager: DownloadManager = DownloadManager.getInstance();
    if (manager.isLive(id)) {
      manager.stopOne(id);
      return;
    }
    if (manager.isQueued(id)) {
      manager.stopOne(id);
      return;
    }
    const record: DownloadRecord | null = this.findById(id);
    if (record === null) {
      return;
    }
    manager.resumeOne(record);
  }

  // ---------- 事件消费方（@Observed 字段主写者；DB 写 fire-and-forget） ----------
  // U4.1 红线：以下五方法与 buildEngineEvents 逻辑逐字节保留（handleFinished 仅 splice/unshift 换 DS 调用）
  // U4.2 红线：既有字段写序逐字节不动——仅在方法尾部追加 host 转发行（对话框消费，事件面零破坏）；
  // handleFailed 签名追加 errorCode 透传（host.onFailed 状态文本原料，写序不变）

  private handleStarted(id: string): void {
    const record: DownloadRecord | null = this.findById(id);
    if (record !== null) {
      record.status = DownloadStatus.Downloading;
    }
    // U4.2 尾部转发（差异 #16 源非对称 1:1）：Start 恒看 Config 门、Resume 路径经 isInteractive
    // （ApplicationCore.cs:166-176 vs :306-319）
    if (record !== null && Config.getInstance().getShowProgressWindow() &&
      DownloadManager.getInstance().isInteractive(id)) {
      this.progressHost.openFor(record);
    }
    // DownloadStarted（DownloadProgressWindow.xaml.cs:216-222；Resume 路径 :313-317 复用窗同置）：
    // 已开窗的 resume 行经此复位 Pause 态（start/resume 两路径引擎均发 onStarted——
    // PieceGrabber.ets:235/:289 核实）；openFor 幂等 no-op（§5.6）
    const startedModel: ProgressWindowModel | undefined = this.progressHost.modelOf(id);
    if (startedModel !== undefined) {
      startedModel.statusText = this.labelStatDownloading + ' ...';
      startedModel.resumable = false;
      // U5.2 块内尾部追加（D12）：speedText/etaText 复位（ResumeDownload :305-321 重开窗复位锚
      // ——500ms 内速度/ETA 显示空，首个进度事件回填；既有两行写序不动）
      startedModel.speedText = '';
      startedModel.etaText = '';
    }
    // U5.1 尾部转发（设计书 §3.3）：通知编排——D8 覆盖最新活跃名 + 0→非 0 长时任务申请锚
    ProgressNotifier.getInstance().onDownloadStarted(id, record !== null ? (record.name ?? '') : '');
  }

  private handleConnected(id: string, totalSize: number): void {
    const record: DownloadRecord | null = this.findById(id);
    if (record !== null && totalSize > 0) {
      record.size = totalSize;
    }
  }

  private handleProgress(id: string, progress: number, instantSpeed: number, etaSeconds: number,
    downloadedBytes: number): void {
    const record: DownloadRecord | null = this.findById(id);
    if (record !== null) {
      record.status = DownloadStatus.Downloading;
      record.progress = progress;
      record.downloadSpeed = formatSpeed(instantSpeed);
      record.eta = (etaSeconds > 0 ? toHMS(etaSeconds) : '---');
      record.downloadedBytes = downloadedBytes;
    }
    // D8：每 >500ms 进度事件一次落库（对照 Application.cs:323-331 逐事件写库）
    DownloadStore.getInstance().updateProgress(id, progress).catch((err: BusinessError) => {
      hilog.error(0x0000, 'Index', '%{public}s',
        'updateProgress failed errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
    });
    // U4.2 尾部转发（DownloadProgressChanged :359-371 同位）：五字段写（钳位+组合）
    const model: ProgressWindowModel | undefined = this.progressHost.modelOf(id);
    if (model !== undefined) {
      model.progressPercent = progress >= 0 && progress <= 100 ? progress : 0;
      model.statusText = this.labelStatDownloading + ' ' + formatSize(downloadedBytes) + ' / ' +
        formatSize(record !== null ? record.size : 0);
      model.speedText = formatSpeed(instantSpeed);
      model.etaText = this.labelMsgTimeLeft + ': ' + (etaSeconds > 0 ? toHMS(etaSeconds) : '---');
    }
    // U5.1 尾部转发（设计书 §3.3）：实况窗 publish 直发（引擎 500ms 门已节流，D11 无二次节流）
    ProgressNotifier.getInstance().onDownloadProgress(id, record !== null ? (record.name ?? '') : '', progress);
  }

  private handlePaused(id: string, offsetBytes: number): void {
    const record: DownloadRecord | null = this.findById(id);
    if (record !== null) {
      record.status = DownloadStatus.Stopped;
      record.downloadSpeed = null;
      record.eta = null;
      record.downloadedBytes = offsetBytes;
    }
    DownloadStore.getInstance().updateStatus(id, DownloadStatus.Stopped).catch((err: BusinessError) => {
      hilog.error(0x0000, 'Index', '%{public}s',
        'updateStatus failed errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
    });
    // U4.2 尾部转发（DownloadCancelled :443-458：停即取消语义共用）
    this.progressHost.onPaused(id);
    // U5.1 尾部转发（设计书 §3.2）：终态转发（归零释放判定挂此）
    ProgressNotifier.getInstance().onDownloadEnded(id, 'paused', offsetBytes, '');
  }

  private handleFailed(id: string, errorCode: number): void {
    const record: DownloadRecord | null = this.findById(id);
    if (record !== null) {
      record.status = DownloadStatus.Stopped;
      record.downloadSpeed = null;
      record.eta = null;
    }
    DownloadStore.getInstance().updateStatus(id, DownloadStatus.Stopped).catch((err: BusinessError) => {
      hilog.error(0x0000, 'Index', '%{public}s',
        'updateStatus failed errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
    });
    // U4.2 尾部转发（DownloadFailed :421-436；'error '+code 差异 #4）
    this.progressHost.onFailed(id, errorCode);
    // U5.1 尾部转发（设计书 §3.2）：终态转发（归零释放判定挂此）
    ProgressNotifier.getInstance().onDownloadEnded(id, 'failed', 0, '');
  }

  /** 完成迁移（handleFinished）：字段写与 markAsFinished 链零改动；splice/unshift 换
   * inProgressDS.removeById + finishedDS.addSorted（record 引用即 inProgressDS 中同一对象，
   * 完成项 dateAdded 保持起始时间——源码 MarkAsFinished 不改 DateAdded，完成序由排序键呈现 §3.3）。 */
  private handleFinished(id: string, finalFileSize: number, filePath: string): void {
    const name: string = this.baseNameOf(filePath);
    const folder: string = this.dirNameOf(filePath);
    const record: DownloadRecord | null = this.inProgressDS.getRecordById(id);
    if (record !== null) {
      record.status = DownloadStatus.Finished;
      record.progress = 100;
      record.name = name;
      record.size = finalFileSize > 0 ? finalFileSize : record.size;
      record.downloadSpeed = null;
      record.eta = null;
      // 幽灵选中清理（独立复核 medium，对齐 WPF 移除即清选中 AppController.cs:524-528）：
      // 选中行完成迁移后若不清，工具栏 Delete/stale Resume 会作用于已完成记录
      if (this.selectedIds.delete(id)) {
        record.uiSelected = false;
      }
      this.inProgressDS.removeById(id);
      this.finishedDS.addSorted(record);
      this.recomputeCounts();
      this.recomputeToolbar();
      // R2-F1（拍板⑧ kind 门本会话生效）：kind 只在 DB 装载时由 completed 列映射
      // （RecordMapping.ets:104），markAsFinished 只写库不改内存对象——此处补内存置位，
      // 使本会话内 removeRecords 的 kind===Finished 成品删除门即生效（源 :772
      // entry is FinishedDownloadItem && deleteDownloadedFile → File.Delete 同构）
      record.kind = DownloadKind.Finished;
    }
    // 完成落库（对照 MarkAsFinished + Application.DownloadFinished :117-125 取 basename/dirname；D12 单写）
    DownloadStore.getInstance().markAsFinished(id, finalFileSize, name, folder)
      .catch((err: BusinessError) => {
        hilog.error(0x0000, 'Index', '%{public}s',
          'markAsFinished failed errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
      });
    // U4.2 尾部转发（DownloadFinished :393-419：关进度窗+完成窗门——§3.6）
    this.progressHost.onDownloadFinished(id, filePath);
    // U5.1 尾部转发（设计书 §3.4）：完成通知（新通道 D5）+ 归零释放判定；Size 回退取更新后
    // record.size（Application.cs:126 GetDownloadById 回读同义——record 引用即既有链路写回后的值）
    ProgressNotifier.getInstance().onDownloadEnded(id, 'finished',
      record !== null ? finishedSize(record.size, finalFileSize) : finalFileSize, filePath);
    // U5.2 尾部追加（设计书 §1-#14⑥/§3.4）：完成成品拷贝用户目录（D1 双轨用户目录半区）——
    // fire-and-forget 不阻塞（拷贝期间列表/后续下载不受阻 §3.6）；copyTargetFolder ''（Auto/
    // 未选目录）无事发生；失败文件留沙箱+toast 提示重选（D2：授权失效/重启后临时授权失效）
    SaveDirectory.syncFinishedFile(filePath).then((copied: boolean): void => {
      if (!copied) {
        const toastOpts: promptAction.ShowToastOptions = { message: $r('app.string.msg_copy_failed') };
        // showToast 在 PromptAction 类上（@ohos.arkui.UIContext.d.ts:987/:1015），UIContext 无
        // 此属性——经 getPromptAction() 取实例（ProgressWindowDialog U4.2 同款惯例）
        this.getUIContext().getPromptAction().showToast(toastOpts);
      }
    }).catch((err: BusinessError): void => {
      hilog.error(0x0000, 'Index', '%{public}s',
        'syncFinishedFile threw errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
    });
  }

  // ---------- 分类/搜索/选中/工具栏（§5.10-8 新增私有方法面） ----------

  /** 分类选择状态机（§3.1，对照 lvCategory_SelectionChanged :152-156 + ApplyFilter :158-195）：
   * 清搜索框（:153）→ 切视图/过滤 → 清选中（D4）→ recomputeToolbar（SelectionChanged/CategoryChanged
   * 唯一消费=工具栏重算，D16 直接同步调）→ recomputeCounts（D2 鸿蒙增强）。 */
  private selectCategory(index: number): void {
    // WPF ListBox SelectionChanged 同貌：同 index 不重复触发；亦为 Tabs 程序化同步防回环第一道
    if (index === this.activeCategoryIndex) {
      return;
    }
    this.activeCategoryIndex = index;
    this.searchText = '';
    if (index === 0) {
      // 进行中视图（:161-168：lvInProgress.Visible+CategoryChanged(Level=0,Index=0)）
      this.syncTabsView(0);
      this.finishedDS.clearFilter();
    } else {
      // 完成视图（:169-192）
      this.syncTabsView(1);
      if (index === 1) {
        this.finishedDS.clearFilter();
      } else if (index - 2 >= 0 && index - 2 < DEFAULT_CATEGORIES.length) {
        this.finishedDS.applyFilter('', DEFAULT_CATEGORIES[index - 2]);
      } else {
        this.finishedDS.clearFilter();
      }
    }
    this.clearSelection();
    this.recomputeToolbar();
    this.recomputeCounts();
  }

  /** Tabs 程序化同步（D1）：activeView 赋值前落防回环标记（onTabChange 命中即吞） */
  private syncTabsView(index: number): void {
    this.tabsSyncGuardView = index;
    this.activeView = index;
  }

  /** Tabs onChange 反向映射（D1）：index0→分类 0；index1→分类<1 时置 1，>1 时保持子分类仅对齐视图 */
  private onTabChange(index: number): void {
    if (index === this.tabsSyncGuardView) {
      // 程序化同步回声：吞掉并复位标记（标记恒等于当前视图，用户切换必异值不误吞）
      this.tabsSyncGuardView = -1;
      return;
    }
    this.tabsSyncGuardView = -1;
    if (index === 0) {
      this.selectCategory(0);
      return;
    }
    if (this.activeCategoryIndex < 1) {
      this.selectCategory(1);
      return;
    }
    this.activeView = index;
  }

  /** 当前子分类（搜索过滤用；分类 0/1 → null=全部） */
  private currentCategory(): CategoryDef | null {
    const idx: number = this.activeCategoryIndex;
    if (idx >= 2 && idx - 2 < DEFAULT_CATEGORIES.length) {
      return DEFAULT_CATEGORIES[idx - 2];
    }
    return null;
  }

  /** 搜索触发（§3.2，对照 SearchButton_Click :428-431 → ApplyFilter）：只作用完成数据源；
   * 输入中只改 @State searchText 不触发（D13 源码同貌：进行中列表不接过滤）。
   * OPT-1（设计书 §3.2）：分类 0 早退——对齐源 ApplyFilter index==0 分支（MainWindow.xaml.cs
   * :158-168 只切视图可见性+重发事件，对任何列表零过滤），消除进行中视图下点搜索隐式改写完成
   * DS 投影的不可感知残留（完成页不可见时过滤残留切回完成页才显形）；分类切换恒清搜索框
   * （selectCategory :953），无泄漏面。 */
  private onSearchClick(): void {
    if (this.activeCategoryIndex === 0) {
      return;
    }
    this.finishedDS.applyFilter(this.searchText.trim(), this.currentCategory());
  }

  /** 主窗口按键（2026-11-20）：Delete 删除选中、Ctrl+A 全选当前列表、Esc 取消选择、Ctrl+F 定位搜索框；
   * 搜索框获焦时不处理 Delete/Ctrl+A/Esc（留给文本编辑）。Ctrl+N 新建由 keyboardShortcut 承担。 */
  private handleKeyEvent(event: KeyEvent): boolean {
    if (event.type !== KeyType.Down) {
      return false;
    }
    let ctrl: boolean = false;
    try {
      if (event.getModifierKeyState !== undefined) {
        ctrl = event.getModifierKeyState(['Ctrl']);
      }
    } catch (e) {
      ctrl = false;
    }
    if (ctrl && event.keyCode === KeyCode.KEYCODE_F) {
      this.getUIContext().getFocusController().requestFocus(SEARCH_INPUT_ID);
      return true;
    }
    if (this.searchFocused) {
      return false;
    }
    if (ctrl && event.keyCode === KeyCode.KEYCODE_A) {
      this.selectAllVisible();
      return true;
    }
    if (!ctrl && event.keyCode === KeyCode.KEYCODE_FORWARD_DEL) {
      if (this.selectedIds.size > 0) {
        this.handleToolbarDelete();
      }
      return true;
    }
    if (event.keyCode === KeyCode.KEYCODE_ESCAPE && this.selectedIds.size > 0) {
      this.clearSelection();
      this.recomputeToolbar();
      return true;
    }
    return false;
  }

  /** Ctrl+A：选中当前标签页可见（已排序/过滤）的全部行 */
  private selectAllVisible(): void {
    const ds: DownloadListDataSource = this.activeCategoryIndex === 0 ? this.inProgressDS : this.finishedDS;
    const ids: string[] = ds.visibleIds();
    for (let i = 0; i < ids.length; i++) {
      const record: DownloadRecord | null = this.findById(ids[i]);
      if (record !== null) {
        record.uiSelected = true;
        this.selectedIds.add(ids[i]);
      }
    }
    this.selectedCount = this.selectedIds.size;
    this.recomputeToolbar();
  }

  /** 单选替换（D3，WPF 单击选择语义）：先清全部选中再标新行 */
  private selectRow(id: string): void {
    this.clearSelection();
    const record: DownloadRecord | null = this.findById(id);
    if (record === null) {
      return;
    }
    record.uiSelected = true;
    this.selectedIds.add(id);
    this.selectedCount = this.selectedIds.size;
    this.recomputeToolbar();
  }

  /** 复选框多选开关（D3）：toggle Set 成员资格+uiSelected 镜像 */
  private toggleRowSelect(id: string): void {
    const record: DownloadRecord | null = this.findById(id);
    if (record === null) {
      return;
    }
    if (this.selectedIds.has(id)) {
      this.selectedIds.delete(id);
      record.uiSelected = false;
    } else {
      this.selectedIds.add(id);
      record.uiSelected = true;
    }
    this.selectedCount = this.selectedIds.size;
    this.recomputeToolbar();
  }

  /** 清空选中（D4/§8-3）：遍历置 uiSelected=false（@Observed 驱动行高亮刷新）+清 Set+计数归零 */
  private clearSelection(): void {
    this.inProgressDS.clearUiSelection();
    this.finishedDS.clearUiSelection();
    this.selectedIds.clear();
    this.selectedCount = 0;
  }

  /** 工具栏状态机重算（§2.4）：inProgressViewSelected=分类 index===0（IsInProgressViewSelected
   * xaml.cs:267 同构）；singleIsActive=选中首行 isLive||isQueued（IsDownloadActive :562-565 同构，
   * 排队也算 active）。computeToolbarState 整体赋 @State（class 整体替换触发渲染）。 */
  private recomputeToolbar(): void {
    const inProgressViewSelected: boolean = this.activeCategoryIndex === 0;
    let singleIsActive: boolean = false;
    if (this.selectedCount === 1) {
      const firstId: string = this.firstSelectedId();
      if (firstId !== '') {
        const manager: DownloadManager = DownloadManager.getInstance();
        singleIsActive = manager.isLive(firstId) || manager.isQueued(firstId);
      }
    }
    this.toolbarState = computeToolbarState(inProgressViewSelected, this.selectedCount, singleIsActive);
  }

  /** 选中集首元素（Set 无索引枚举面——forEach 收敛单值；仅 selectedCount===1 时消费） */
  private firstSelectedId(): string {
    let found: string = '';
    this.selectedIds.forEach((id: string): void => {
      if (found === '') {
        found = id;
      }
    });
    return found;
  }

  /** 分类计数重算（D2）：顶层 0/1=两数据源 fullCount；子分类=完成数据源扩展名匹配数（未过滤全长） */
  private recomputeCounts(): void {
    this.inProgressCount = this.inProgressDS.fullCount();
    this.finishedCount = this.finishedDS.fullCount();
    const counts: number[] = [0, 0, 0, 0, 0, 0, 0];
    counts[0] = this.inProgressCount;
    counts[1] = this.finishedCount;
    for (let i = 0; i < DEFAULT_CATEGORIES.length && i + 2 < counts.length; i++) {
      counts[i + 2] = this.finishedDS.countByExtensions(DEFAULT_CATEGORIES[i].fileExtensions);
    }
    this.categoryCounts = counts;
  }

  /** 工具栏 Pause（§0-6）：对选中集逐 id stopOne（与行按钮同路径，零新引擎面） */
  private handleToolbarPause(): void {
    const manager: DownloadManager = DownloadManager.getInstance();
    this.selectedIds.forEach((id: string): void => {
      manager.stopOne(id);
    });
  }

  /** 工具栏 Resume（§0-6）：对选中集逐 id resumeOne */
  private handleToolbarResume(): void {
    const manager: DownloadManager = DownloadManager.getInstance();
    this.selectedIds.forEach((id: string): void => {
      const record: DownloadRecord | null = this.findById(id);
      if (record !== null) {
        manager.resumeOne(record);
      }
    });
  }

  /** 工具栏 Delete（U4.2 升级两分支，§3.4 对照 UIActions.DeleteDownloads :19-55 逐行）：
   * inProgressOnly 分支（:21-38）——StopDownloads 先于确认弹窗（:24 时序红线：点 Cancel 行也已被停，
   * 记录保留可恢复）；Confirm(approved) → 逐行 RemoveDownload+行删除+DB 删。
   * 完成分支（:40-54）——ConfirmDelete 模态确认（带删文件勾选）→ approved 才删。
   * 差异 #5：U4.1 简版"停不删"升级为源码全链"先停→确认→删记录"。 */
  private handleToolbarDelete(): void {
    const ids: string[] = [];
    this.selectedIds.forEach((id: string): void => {
      ids.push(id);
    });
    if (ids.length === 0) {
      return;
    }
    if (this.activeCategoryIndex === 0) {
      // :24 StopDownloads 先于确认弹窗（stopOne 同步、alert 异步——时序天然保持）
      const manager: DownloadManager = DownloadManager.getInstance();
      ids.forEach((id: string): void => {
        manager.stopOne(id);
      });
      this.getUIContext().showAlertDialog({
        message: $r('app.string.del_sel_text'),
        primaryButton: {
          value: $r('app.string.desc_del'),
          action: () => {
            this.removeRecords(ids, false);
          }
        },
        secondaryButton: {
          value: $r('app.string.nd_cancel'),
          action: () => {
          }
        }
      });
      return;
    }
    // 完成分支：ConfirmDelete（模态，MainWindow.xaml.cs:316-327 分型）
    this.pendingDeleteIds = ids;
    this.deleteConfirmController.open();
  }

  /** 确认回调（approved 分支）：删除记录（含勾选值透传——差异 #6 只收值不删盘上文件） */
  private onDeleteConfirmed(deleteFiles: boolean): void {
    const ids: string[] = this.pendingDeleteIds;
    this.pendingDeleteIds = [];
    this.removeRecords(ids, deleteFiles);
  }

  /** 逐行删记录（:27-36 RemoveDownload+MainWindow.Delete+RemoveDownloadById 同位）：
   * 选中清理→store.remove→盘上清理（U5.2 R3-F1 闭环）→双 DS removeById→recompute；
   * live/queued 行 stopOne 已在确认前完成。
   * U5.2（设计书 §1-#14⑥/拍板⑧）：store.remove 成功分支消费 StateStore.removeById
   * （tempDir/<id> 目录级删除——RemoveDownload :725-798 tempDir 半区，deleteFiles=false 也照删）
   * + deleteFiles && kind===Finished 成品 unlink（:758-756 FinishedDownloadItem 分支同构）。
   * record 引用在 store.remove 之前经 findById 抓取（then 回调执行时 DS 已移除、findById 返 null）。 */
  private removeRecords(ids: string[], deleteFiles: boolean): void {
    const records: (DownloadRecord | null)[] = [];
    for (let i = 0; i < ids.length; i++) {
      const id: string = ids[i];
      this.selectedIds.delete(id);
      const record: DownloadRecord | null = this.findById(id);
      if (record !== null) {
        record.uiSelected = false;
      }
      records.push(record);
      // 2026-11-19：已删任务的进度窗随之关闭（否则残留一个无法再操作的窗口）
      this.progressHost.closeFor(id);
    }
    this.selectedCount = this.selectedIds.size;
    this.recomputeToolbar();
    // 2026-11-19 修复：逐条串行删除。store.remove 各开 IMMEDIATE 事务，并发提交时多数行未删
    // （模拟器实测"移除已完成"15 条只删 4 条；多选 Delete 同受影响）
    this.removeRecordsSequential(ids, records, deleteFiles).catch((err: BusinessError) => {
      hilog.error(0x0000, 'Index', '%{public}s',
        'removeRecords threw errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
    });
  }

  private async removeRecordsSequential(ids: string[], records: (DownloadRecord | null)[],
    deleteFiles: boolean): Promise<void> {
    const store: DownloadStore = DownloadStore.getInstance();
    const tempDir: string = Config.getInstance().getTempDir();
    for (let i = 0; i < ids.length; i++) {
      const id: string = ids[i];
      const record: DownloadRecord | null = records[i];
      const ok: boolean = await store.remove(id);
      if (!ok) {
        hilog.error(0x0000, 'Index', '%{public}s', 'store.remove failed id=' + id);
        continue;
      }
      // U5.2 追加：恢复态+临时分片恒清（chunks.json 双槽/staging+分片文件全在目录内）
      StateStore.removeById(tempDir, id);
      // U5.2 追加：成品删除门=deleteFiles && Finished && targetDir/name 非空（源 :758-756）
      if (deleteFiles && record !== null && record.kind === DownloadKind.Finished &&
        record.targetDir !== null && record.name !== null &&
        record.targetDir.length > 0 && record.name.length > 0) {
        try {
          fileIo.unlinkSync(record.targetDir + '/' + record.name);
        } catch (e) {
          const unlinkErr = e as BusinessError;
          hilog.info(0x0000, 'Index', '%{public}s',
            'finished file unlink failed id=' + id + ' errCode=' + String(unlinkErr.code) +
            ' errMessage=' + (unlinkErr.message ?? ''));
        }
      }
      this.inProgressDS.removeById(id);
      this.finishedDS.removeById(id);
      this.recomputeCounts();
    }
  }

  /** OpenFile/OpenFolder 点击（U5.2 真实能力接线，替换 U4.1 占位；UIActions :76-120 状态机 1:1）：
   * 无选中→no_item_selected 弹窗（OpenSelectedFolder/OpenSelectedFile 末行同构 :120/:108 末行）；
   * record/targetDir/name 缺失→msg_file_not_found（:114-117 TargetDir 空分支同构）；
   * SaveDirectory.openFile（accessSync 预检+openPreview 单文件变体）失败→msg_file_not_found
   * 弹窗（:88/:108 ShowMessageBox 1:1）；openFolder 同路预览（D3 降级，hilog 由 SaveDirectory 登记）。 */
  private handleOpenAction(button: string): void {
    const id: string = this.firstSelectedId();
    if (id === '') {
      this.showOpenError($r('app.string.no_item_selected'));
      return;
    }
    const record: DownloadRecord | null = this.findById(id);
    if (record === null || record.targetDir === null || record.name === null ||
      record.targetDir.length === 0 || record.name.length === 0) {
      this.showOpenError($r('app.string.msg_file_not_found'));
      return;
    }
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      return;
    }
    const path: string = record.targetDir + '/' + record.name;
    // ctx 已窄化非 undefined（handleMenuExit 同款 downcast 惯例）
    SaveDirectory.openFile(ctx as common.UIAbilityContext, path, button).then((ok: boolean): void => {
      if (!ok) {
        this.showOpenError($r('app.string.msg_file_not_found'));
      }
    }).catch((err: BusinessError): void => {
      hilog.error(0x0000, 'Index', '%{public}s',
        'handleOpenAction threw errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
    });
  }

  /** Open/OpenFolder 失败提示（ShowMessageBox 等价：UIContext.showAlertDialog） */
  private showOpenError(message: ResourceStr): void {
    this.getUIContext().showAlertDialog({
      message: message,
      primaryButton: {
        value: 'OK',
        action: () => {
        }
      }
    });
  }

  // ---------- 工具 ----------

  private findById(id: string): DownloadRecord | null {
    const inProgress: DownloadRecord | null = this.inProgressDS.getRecordById(id);
    if (inProgress !== null) {
      return inProgress;
    }
    return this.finishedDS.getRecordById(id);
  }

  private baseNameOf(path: string): string {
    const idx: number = path.lastIndexOf('/');
    return idx >= 0 ? path.slice(idx + 1) : path;
  }

  private dirNameOf(path: string): string {
    const idx: number = path.lastIndexOf('/');
    return idx >= 0 ? path.slice(0, idx) : path;
  }

  /** 表头排序分派：当前列表 DS.toggleSort + sortVersion++（表头箭头重渲染，§5.9） */
  private onHeaderSort(key: SortKey, isInProgress: boolean): void {
    if (isInProgress) {
      this.inProgressDS.toggleSort(key);
    } else {
      this.finishedDS.toggleSort(key);
    }
    this.sortVersion++;
  }

  /** 表头箭头文本（DS.sortState 快照读取；version 参数为调用点 @State 追踪锚——箭头重渲染由
   * sortVersion++ 经调用点表达式依赖触发，本参数不参与取值） */
  private sortArrow(isInProgress: boolean, key: SortKey, version: number): string {
    if (version < 0) {
      return '';
    }
    const state = isInProgress ? this.inProgressDS.sortState() : this.finishedDS.sortState();
    if (state.key !== key) {
      return '';
    }
    return state.desc ? '↓' : '↑';
  }

  /** 新建下拉 3 项（源 newDownloadContextMenu :206-210 同序；第 3 项 U4.2 接线开批量窗，
   * 第 2 项视频向导维持占位禁用 D5） */
  private newMenuItems(): MenuElement[] {
    const items: MenuElement[] = [
      {
        value: $r('app.string.lbl_new_download'),
        action: () => {
          // R2-F3：源 New 按钮直开路径带剪贴板预填分支（Application.cs:414-420
          // NewDownloadClicked → CreateAndShowDialog(true) message=null → 控制器
          // GetUrlFromClipboard IsUriValid 门预填）——经 openNewDownloadFromClipboard 复刻
          this.openNewDownloadFromClipboard();
        }
      },
      // 上架整改（2026-11-19）：视频向导（yt-dlp 降级项 D5）未实现，移除禁用占位项——
      // 视频下载经浏览器扩展/媒体抓取页完成
      {
        value: $r('app.string.menu_batch_download'),
        action: () => {
          this.batchDialogController.open();
        }
      }
    ];
    return items;
  }

  // ---------- U4.2 批量/选择/刷新链接触发链（§5.11-7/8、§3.7） ----------

  /** 批量确认链（OnOKClicked :53-58 DestroyWindow→ShowDownloadSelectionWindow 次序 1:1：
   * 本窗已在回调前 close；此处填会话开选择窗）。条目名=fileNameFromUrl（Batch 侧生成文件名，
   * 走 shi.File ?? GetFileName 的前半支，§2.2）。 */
  private onBatchConfirm(links: string[]): void {
    if (this.promptOpen) {
      const pending: BridgeInboxItem = new BridgeInboxItem();
      pending.kind = 'batch';
      for (let i = 0; i < links.length; i++) {
        const request: DownloadCreationRequest = new DownloadCreationRequest();
        request.url = links[i];
        request.name = fileNameFromUrl(links[i]);
        request.targetDir = Config.getInstance().getDownloadDir();
        pending.requests.push(request);
      }
      BridgeInbox.getInstance().enqueue(pending).catch((): void => {
        this.getUIContext().showAlertDialog({ message: $r('app.string.msg_download_save_failed') });
      });
      return;
    }
    this.promptOpen = true;
    const items: SelectionItemModel[] = [];
    for (let i = 0; i < links.length; i++) {
      const item: SelectionItemModel = new SelectionItemModel();
      item.url = links[i];
      item.name = fileNameFromUrl(links[i]);
      item.entryType = 'Http';
      item.selected = true;
      items.push(item);
    }
    this.selectionSession.items = items;
    this.selectionSession.auth = null;
    this.selectionSession.proxy = null;
    this.selectionSession.saveIn = Config.getInstance().getDownloadDir();
    this.selectionDialogController.open();
  }

  /** 选择确认链（§3.5 Download Now/Later 分型：StartDownload :126-186 同序——
   * 工厂（Now/排队落 Waiting、Later 落 Stopped——源 startType 缺省 Waiting，
   * ApplicationCore.cs:138-148）→ fetchMode 覆盖 FileNameAndExtension → add →
   * DS 变更 → Now 才 admitNew（源 else { SaveForLater(); } :198-200 同位）） */
  private async onSelectionConfirm(items: SelectionItemModel[], auth: AuthenticationInfo | null,
    proxy: ProxyInfo | null, startImmediately: boolean): Promise<boolean> {
    const generation: number = this.loadGeneration;
    const targetDir: string = this.selectionSession.saveIn.length > 0
      ? this.selectionSession.saveIn : Config.getInstance().getDownloadDir();
    const requests: DownloadCreationRequest[] = [];
    for (let i = 0; i < items.length; i++) {
      const item: SelectionItemModel = items[i];
      const request: DownloadCreationRequest = new DownloadCreationRequest();
      request.url = item.url;
      request.name = item.name;
      request.size = item.size;
      request.targetDir = targetDir;
      request.startImmediately = startImmediately;
      request.authentication = auth;
      request.proxy = proxy;
      request.contextUrl = item.contextUrl;
      request.requestContext = item.requestContext;
      requests.push(request);
    }
    if (this.activeInbox !== null) {
      const id: string = this.activeInbox.id;
      await BridgeInbox.getInstance().confirm(id, requests);
      if (!this.pageActive || generation !== this.loadGeneration || this.activeInbox?.id !== id) {
        return false;
      }
      this.activeInbox = null;
    } else {
      // Persist the entire manual batch before promotion, so failures can be retried atomically.
      const item: BridgeInboxItem = new BridgeInboxItem();
      item.kind = 'batch';
      item.requests = requests;
      const saved: BridgeInboxItem = await BridgeInbox.getInstance().enqueue(item);
      if (!this.pageActive || generation !== this.loadGeneration) {
        setTimeout((): void => { this.openNextInbox(); }, 0);
        return false;
      }
      this.activeInbox = saved;
      if (!BridgeInbox.getInstance().claim(saved.id)) {
        this.activeInbox = null;
        return false;
      }
      await BridgeInbox.getInstance().confirm(saved.id, requests);
      if (!this.pageActive || generation !== this.loadGeneration || this.activeInbox?.id !== saved.id) {
        return false;
      }
      this.activeInbox = null;
    }
    return true;
  }

  /** 右键菜单开菜单钩子（R2-F1：WPF 右键即选中同构——先 selectRow(id) 再开菜单分派；
   * 捕获被右击行 id 供菜单项按 id 分派，不依赖左键选中态） */
  private handleRowContextAppear(id: string): void {
    this.contextMenuRowId = id;
    this.selectRow(id);
  }

  /** 行右键 Refresh link：Http 的活动、排队和停止任务均可监听。
   * 先登记匹配会话，再打开有效 Referer；替换对话框等待旧窗关闭，以隔离生命周期回调。 */
  private onRefreshLinkMenu(id: string): void {
    if (!this.pageActive || id.length === 0) { return; }
    this.pendingRefreshId = id;
    if (this.refreshWindowToken !== 0) {
      this.onRefreshStopped(this.refreshToken);
      this.refreshLinkController.close();
      return;
    }
    this.openPendingRefresh();
  }

  private openPendingRefresh(): void {
    if (!this.pageActive || this.refreshWindowToken !== 0 || this.pendingRefreshId.length === 0) { return; }
    const id: string = this.pendingRefreshId;
    this.pendingRefreshId = '';
    const record: DownloadRecord | null = this.findById(id);
    if (record === null) { return; }
    if (record.downloadType !== 'Http') {
      this.getUIContext().showAlertDialog({ message: $r('app.string.no_refresh_link') });
      return;
    }
    try {
      // Match the restored download state, including when the initial DB size was positive but stale.
      const state: RestoredPieces | null = new StateStore(joinTempDir(Config.getInstance().getTempDir(), id)).readChunks();
      const candidate: DownloadRecord = new DownloadRecord();
      candidate.id = record.id;
      candidate.downloadType = record.downloadType;
      candidate.size = state !== null && Number.isSafeInteger(state.totalSize) && state.totalSize > 0
        ? state.totalSize : record.size;
      const request: DownloadRunRequest = resolveRunRequest(record);
      const token: number = LinkRefresher.getInstance().begin(candidate, this.refreshObserver);
      this.refreshToken = token;
      this.refreshWindowToken = token;
      this.refreshModel.token = token;
      this.refreshModel.targetName = record.name ?? '';
      this.refreshModel.waiting = true;
      this.refreshModel.linkAccepted = false;
      this.refreshModel.failed = false;
      this.refreshModel.browserOpenFailed = false;
      this.refreshLinkController.open();
      const referer: string = this.refreshReferer(request.context);
      if (referer.length > 0) { this.onOpenReferer(referer, token); }
    } catch (e) {
      const failedWindowToken: number = this.refreshWindowToken;
      this.onRefreshStopped(this.refreshToken);
      if (failedWindowToken !== 0) {
        try { this.refreshLinkController.close(); } catch (closeError) {}
      }
      if (this.refreshWindowToken === failedWindowToken) { this.refreshWindowToken = 0; }
      this.getUIContext().showAlertDialog({ message: $r('app.string.msg_refresh_save_failed') });
    }
  }

  private refreshReferer(context: DownloadRequestContext): string {
    const headers = context.headers;
    if (headers !== null) {
      for (let i = 0; i < headers.names.length; i++) {
        if (headers.names[i].toLowerCase() === 'referer' && headers.values[i].length > 0) {
          const url: string = headers.values[i][0].trim();
          if (isUriValid(url) && (url.toLowerCase().startsWith('http://') || url.toLowerCase().startsWith('https://'))) {
            return url;
          }
          return '';
        }
      }
    }
    return '';
  }

  private onRefreshAccepted(token: number, id: string, request: DownloadRunRequest): void {
    if (!this.pageActive || this.refreshToken !== token || this.refreshWindowToken !== token) { return; }
    const record: DownloadRecord | null = this.findById(id);
    if (record !== null && request.revision >= record.requestRevision) {
      record.primaryUrl = request.url;
      record.requestContext = cloneDownloadRequestContext(request.context);
      record.requestRevision = request.revision;
    }
    this.refreshModel.linkAccepted = true;
    this.refreshModel.waiting = false;
    this.refreshModel.failed = false;
    const generation: number = this.loadGeneration;
    this.getUIContext().showAlertDialog({
      message: $r('app.string.msg_ref_link_msg'),
      autoCancel: false,
      primaryButton: { value: 'OK', action: (): void => {
        if (this.pageActive && generation === this.loadGeneration && this.refreshWindowToken === token) {
          this.refreshLinkController.close();
        }
      } }
    });
  }

  /** 行右键 Show progress（UIActions.ShowProgressWindow :180-184：首选中行开窗——
   * host.openFor 对已有 model 幂等 no-op，CreateOrGetProgressWindow :309 同构）。
   * U5.2 INT-F6：isLive 门（ShowProgressWindow :326-328 !liveDownloads.ContainsKey→return——
   * queued 不算 live，对停/排队行不开冻结窗）。 */
  private onShowProgressMenu(id: string): void {
    if (id === '') {
      return;
    }
    if (!DownloadManager.getInstance().isLive(id)) {
      return;
    }
    const record: DownloadRecord | null = this.findById(id);
    if (record !== null) {
      this.progressHost.openFor(record);
    }
  }

  /** WatchingStopped → ClearWatchList；已开始的存储提交继续完成，旧会话不再通知 UI。 */
  private onRefreshStopped(token: number): void {
    LinkRefresher.getInstance().stop(token);
    if (this.refreshToken === token) { this.refreshToken = 0; }
  }

  private onRefreshClosed(token: number): void {
    this.onRefreshStopped(token);
    if (this.refreshWindowToken !== token) { return; }
    this.refreshWindowToken = 0;
    if (this.pageActive && this.pendingRefreshId.length > 0) {
      const generation: number = this.loadGeneration;
      setTimeout((): void => {
        if (this.pageActive && generation === this.loadGeneration) { this.openPendingRefresh(); }
      }, 0);
    }
  }

  private async onOpenReferer(refererUrl: string, token: number): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (ctx === undefined) { throw new Error('Page context unavailable'); }
      await (ctx as common.UIAbilityContext).openLink(refererUrl, { appLinkingOnly: false });
    } catch (e) {
      if (this.pageActive && this.refreshToken === token) {
        this.refreshModel.browserOpenFailed = true;
      }
    }
  }

  /** U5.1 真实退出路径（设计书 §1-#10③/拍板④/D4）：menu_exit→terminateSelf——WPF 托盘
   * Exit（menuExit.Click→Environment.Exit(0)）1:1；无二次确认（源 Exit 即刻退出，活跃下载
   * 一并终止=WPF 同貌）。官方样例同款 downcast（undefined 已窄化）。terminateSelf 带 @throws
   * （hvigor "Function may throw exceptions" 规则点）——.catch 兜底记日志（EntryAbility
   * requestEnableNotification 同款收口，未处理返回值会报新 warning）。 */
  private handleMenuExit(): void {
    const ctx = this.getUIContext().getHostContext();
    if (ctx !== undefined) {
      (ctx as common.UIAbilityContext).terminateSelf().catch((err: BusinessError) => {
        hilog.error(0x0000, 'Index', '%{public}s', 'terminateSelf failed errCode=' +
          String(err.code) + ' errMessage=' + (err.message ?? ''));
      });
    }
  }

  /** 汉堡菜单 12 项（源 ctxMainMenu :59-87 逐项同序；U4.3 接线前三项：title_settings→设置页
   * （默认常规页签 1=源 ShowSettingsDialog 恒 this(1) 同貌）、settings_monitoring→设置页监控
   * 页签 0（源 ShowBrowserMonitoringDialog 开 0 同貌）、menu_lang→语言对话框；其余 9 项维持
   * 占位禁用；action 必填见 newMenuItems 注） */
  private mainMenuItems(): MenuElement[] {
    const items: MenuElement[] = [
      {
        value: $r('app.string.title_settings'),
        action: () => {
          this.pathStack.pushPathByName('settings', SETTINGS_TAB_GENERAL);
        }
      },
      {
        value: $r('app.string.settings_monitoring'),
        action: () => {
          this.pathStack.pushPathByName('settings', SETTINGS_TAB_MONITORING);
        }
      },
      {
        value: $r('app.string.msg_media_capture'),
        action: () => {
          // U6.2 启用（源 MainWindow.xaml:65 menuMediaGrabber → CreateAndShowMediaGrabber 同位）：
          // 视频捕获页（VideoCapturePage，NavDestination 装配见 settingsNavDestination）
          this.pathStack.pushPathByName('videoCapture', '');
        }
      },
      // 上架整改（2026-11-19）：源 ClearAllFinishedClicked（Application.cs:499-504）接线
      {
        value: $r('app.string.menu_delete_completed'),
        action: () => {
          this.handleRemoveAllFinished();
        }
      },
      {
        value: $r('app.string.menu_lang'),
        action: () => {
          this.languageDialogController.open();
        }
      },
      // 上架整改（2026-11-19）：导出/导入、帮助、报告问题、检查更新（由应用市场承担）未实现，
      // 移除禁用占位项；"关于"接线（版本 + GPL-2.0 声明 + 上游致谢 + 源码地址）
      {
        value: $r('app.string.menu_about'),
        action: () => {
          this.showAbout();
        }
      },
      // U5.1 启用（拍板④/D4）：Exit→terminateSelf（真实退出路径；X 关闭在有活跃下载时被
      // onPrepareToTerminate 拦截=最小化，恢复窗口后经此真正退出）
      {
        value: $r('app.string.menu_exit'),
        action: () => {
          this.handleMenuExit();
        }
      }
    ];
    return items;
  }

  /** 清除全部已完成（源 ClearAllFinishedClicked：DeleteAllFinishedDownloads + RemoveAllFinished，
   * 仅删记录不删盘上文件）；移植版加一次确认，避免误触清空列表。 */
  private handleRemoveAllFinished(): void {
    const ids: string[] = this.finishedDS.allIds();
    if (ids.length === 0) {
      return;
    }
    this.getUIContext().showAlertDialog({
      message: $r('app.string.remove_finished_confirm'),
      primaryButton: {
        value: $r('app.string.desc_del'),
        action: () => {
          this.removeRecords(ids, false);
        }
      },
      secondaryButton: {
        value: $r('app.string.nd_cancel'),
        action: () => {
        }
      }
    });
  }

  /** 关于（GPL-2.0 第 1 条要求的版权/无担保声明 + 源码获取途径） */
  private showAbout(): void {
    let version: string = '';
    try {
      version = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT).versionName;
    } catch (e) {
      version = '';
    }
    this.getUIContext().showAlertDialog({
      title: $r('app.string.about_title'),
      message: $r('app.string.about_text', version),
      confirm: {
        value: $r('app.string.btn_ok'),
        action: () => {
        }
      }
    });
  }

  // ---------- build（§5.10-9：Row[分类面板 | Column[工具栏/搜索/Tabs 双列表/状态栏]]） ----------

  // OPT-1：CategoryIcon @Builder 迁入 components/CategoryPanel.ets（分类面板纯搬迁）。

  /** 表头可排单元格（Row+箭头；onClick 绑列键——'%' 与 Status 列无 Tag 不绑点击，源码同貌）。
   * 留 Index 经 headerBuilder（@BuilderParam `() => void`）闭包注入双 pane（§3.3——禁直接传方法引用，this 丢失） */
  @Builder
  SortHeaderCell(label: ResourceStr, isInProgress: boolean, key: SortKey, flex: number) {
    Row({ space: 2 }) {
      Text(label)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .maxLines(1)
      Text(this.sortArrow(isInProgress, key, this.sortVersion))
        .fontSize(11)
        .fontColor($r('app.color.accent'))
    }
    .layoutWeight(flex)
    .onClick(() => {
      this.onHeaderSort(key, isInProgress);
    })
  }

  /** 表头行（§5.9；列 flex 与行组件共用同一组常量——禁两处魔法数漂移）。
   * 名称列前有 Checkbox+图标两个定宽格（源 xaml 头 Padding=40 视觉补偿的同构拆分）。 */
  @Builder
  HeaderRow(isInProgress: boolean) {
    Row() {
      Row().width(COL_CHECKBOX_WIDTH)
      Row().width(COL_ICON_WIDTH)
      this.SortHeaderCell($r('app.string.sort_name'), isInProgress, 'Name',
        isInProgress ? COL_FLEX_NAME_INPROGRESS : COL_FLEX_NAME_FINISHED)
      this.SortHeaderCell($r('app.string.sort_date'), isInProgress, 'DateAdded', COL_FLEX_DATE)
      this.SortHeaderCell($r('app.string.sort_size'), isInProgress, 'Size', COL_FLEX_SIZE)
      if (isInProgress) {
        Text('%')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .layoutWeight(COL_FLEX_PROGRESS)
        Text($r('app.string.sort_status'))
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .layoutWeight(COL_FLEX_STATUS)
        Row().width(COL_BUTTON_WIDTH)
      }
    }
    .width('100%')
    .padding({ left: 6, right: 6, top: 4, bottom: 4 })
    .border({ width: { bottom: 1 }, color: $r('app.color.divider') })
  }

  /** 行右键菜单（差异 #17：源进行中菜单 10 项，本单元只接 Refresh link/Show progress 两项——
   * 其余动作（SaveAs/Restart/MoveToQueue/Properties 等）不在本单元；事件面追加非破坏）。
   * R2-F1：菜单项按 contextMenuRowId 分派（右键 onAppear 捕获的行 id——右键不触发行选中，
   * firstSelectedId 在未先左键选中时空/错位；源 WPF 右键先选中再开菜单 UIActions.cs:173-184） */
  @Builder
  RowContextMenu() {
    Menu() {
      MenuItem({ content: $r('app.string.menu_refresh_link') })
        .onClick(() => {
          this.onRefreshLinkMenu(this.contextMenuRowId);
        })
      MenuItem({ content: $r('app.string.lbl_show_progress') })
        .onClick(() => {
          this.onShowProgressMenu(this.contextMenuRowId);
        })
    }
  }

  // OPT-1：InProgressPane/FinishedPane @Builder 迁出为 components/InProgressPane.ets 与
  // components/FinishedPane.ets 独立 @Component——DS 经普通成员按引用传递（禁 @Prop/@Link）、
  // 表头/行右键菜单经 @BuilderParam `() => void` 闭包 prop 注入（build 内 TabContent 接线处）、三行回调
  // 上抛（selectRow/toggleRowSelect/handleToggle 逻辑逐字节留本页）；空态文案随 pane 原样搬迁。

  /** U4.3 设置页 NavDestination 装配（pathStack 首次启用；param=页签序，窄化
   * typeof param === 'number' ? param : 1——pushPathByName 恒传 number，防御非数字参数）。
   * U6.2 追加 videoCapture 分支（设计书 §1-#7：视频捕获页 NavDestination 装配，param 不用）。 */
  @Builder
  settingsNavDestination(name: string, param: Object) {
    if (name === 'settings') {
      NavDestination() {
        SettingsPage({
          initialTab: typeof param === 'number' ? param : SETTINGS_TAB_GENERAL,
          pathStack: this.pathStack
        })
      }
      .title($r('app.string.title_settings'))
    } else if (name === 'videoCapture') {
      NavDestination() {
        VideoCapturePage({
          pathStack: this.pathStack
        })
      }
      .title($r('app.string.msg_media_capture'))
    }
  }

  build() {
    Navigation(this.pathStack) {
      Row({ space: 8 }) {
        // ── 左：分类面板（宽 190，对照 xaml Grid 列定义 :215-218；OPT-1 拆 CategoryPanel 组件，
        // 行底/字色 $r 语义色——资源化+对比度收口见该文件）──
        CategoryPanel({
          activeCategoryIndex: this.activeCategoryIndex,
          categoryCounts: this.categoryCounts,
          onSelectCategory: (index: number): void => {
            this.selectCategory(index);
          }
        })

        // ── 右：工具栏 + 搜索 + Tabs 双列表 + 状态栏 ──
        Column({ space: 8 }) {
          // 工具栏行（xaml :318-447 钮面+:448-493 搜索行；OPT-1 拆 ToolbarBar 组件——
          // toolbarState @Prop 收整体快照、searchText @Link 双向、五回调上抛（本页处理器
          // handleToolbarDelete/handleOpenAction/handleToolbarPause/handleToolbarResume/
          // onSearchClick 逐字节不动）；New/汉堡菜单数据由本页装配传入（action 闭包捕获本页 this））
          ToolbarBar({
            toolbarState: this.toolbarState,
            searchText: $searchText,
            newMenuItems: this.newMenuItems(),
            mainMenuItems: this.mainMenuItems(),
            onDeleteClick: (): void => {
              this.handleToolbarDelete();
            },
            onOpenAction: (button: string): void => {
              this.handleOpenAction(button);
            },
            onPauseClick: (): void => {
              this.handleToolbarPause();
            },
            onResumeClick: (): void => {
              this.handleToolbarResume();
            },
            onSearchClick: (): void => {
              this.onSearchClick();
            },
            onSearchFocusChange: (focused: boolean): void => {
              this.searchFocused = focused;
            }
          })

          Tabs({ index: this.activeView, barPosition: BarPosition.Start, controller: this.tabsController }) {
            TabContent() {
              // OPT-1：ds 普通成员按引用传递（禁 @Prop/@Link——保"DS 引用不变、DataChangeListener
              // 驱动 LazyForEach"模型）；sortVersion @Prop 仅重渲染触发锚；headerBuilder/rowMenuBuilder
              // 箭头闭包注入（捕获本页 this——@Builder 方法引用直接传会丢 this）；三行回调逐字节转发
              InProgressPane({
                ds: this.inProgressDS,
                statusLabels: this.statusLabels,
                inProgressCount: this.inProgressCount,
                sortVersion: this.sortVersion,
                headerBuilder: (): void => {
                  this.HeaderRow(true)
                },
                rowMenuBuilder: (): void => {
                  this.RowContextMenu()
                },
                onSelectRow: (id: string): void => {
                  this.selectRow(id);
                },
                onToggleRowSelect: (id: string): void => {
                  this.toggleRowSelect(id);
                },
                onToggle: (id: string): void => {
                  this.handleToggle(id);
                },
                onRowContextAppear: (id: string): void => {
                  this.handleRowContextAppear(id);
                }
              })
            }
            .tabBar($r('app.string.lbl_active'))

            TabContent() {
              // OPT-1：完成 pane 同款接线（无 rowMenuBuilder/onRowContextAppear——完成列表无右键菜单）
              FinishedPane({
                ds: this.finishedDS,
                statusLabels: this.statusLabels,
                finishedCount: this.finishedCount,
                sortVersion: this.sortVersion,
                headerBuilder: (): void => {
                  this.HeaderRow(false)
                },
                onSelectRow: (id: string): void => {
                  this.selectRow(id);
                },
                onToggleRowSelect: (id: string): void => {
                  this.toggleRowSelect(id);
                },
                onToggle: (id: string): void => {
                  this.handleToggle(id);
                }
              })
            }
            .tabBar($r('app.string.lbl_complete'))
          }
          .onChange((index: number) => {
            this.onTabChange(index);
          })
          .width('100%')
          .layoutWeight(1)

          // 状态栏（:508-576 三触点占位禁用 D12：浏览器监视 U5.x / Queue U4.2 / Help U4.2）
          Row({ space: 8 }) {
            Text($r('app.string.settings_monitoring'))
              .fontSize(12)
            Toggle({ type: ToggleType.Switch, isOn: this.monitoringEnabled })
              .onChange((isOn: boolean) => {
                this.monitoringEnabled = isOn;
                Config.getInstance().setIsBrowserMonitoringEnabled(isOn);
                Config.getInstance().broadcastConfigChange();
              })
            // 上架整改（2026-11-19）：队列/计划任务与帮助未实现，移除禁用占位按钮
            Blank()
          }
          .width('100%')
          .padding({ top: 4, bottom: 4 })
          .border({ width: { top: 1 }, color: $r('app.color.divider') })
        }
        .layoutWeight(1)
        .height('100%')
      }
      .width('100%')
      .height('100%')
      .padding(12)
      .alignItems(VerticalAlign.Top)
      // 键盘快捷键（2026-11-20，PC 审核：键盘操作应符合标准定义）
      .focusable(true)
      .defaultFocus(true)
      .focusOnTouch(true)
      .keyboardShortcut('n', [ModifierKey.CTRL], (): void => {
        this.openNewDownloadFromClipboard();
      })
      .onKeyEvent((event: KeyEvent): boolean => {
        return this.handleKeyEvent(event);
      })
    }
    .mode(NavigationMode.Stack)
    .navDestination(this.settingsNavDestination)
    .width('100%')
    .height('100%')
  }
}
