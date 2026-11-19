/*
 * U4.2 进度窗三件套（设计书 §2.1/§3.3/§5.6；对照 ApplicationCore.cs:160-500/629-657 +
 * DownloadProgressWindow.xaml.cs，本会话逐行核对）。
 * 形态（差异 #1/#2）：源一下载一独立窗口（activeProgressWindows[download.Id] 字典，
 * ApplicationCore.cs:169/:312）→ 动态多窗非模态。ArkTS 落地通道（hvigor 编译实测修正）：
 *   - openCustomDialog/closeCustomDialog 的 ComponentContent 重载不在 UIContext 类上，而在
 *     UIContext.getPromptAction() 返回的 PromptAction 实例上（@ohos.arkui.UIContext.d.ts:987
 *     class PromptAction 内 :1208 openCustomDialog<T>/:1265 closeCustomDialog<T>；getPromptAction
 *     在 UIContext 类体 :3909+——设计书 §3.8 写的 'UIContext.d.ts:1208' 是文件锚非类锚）；
 *   - wrapBuilder 的实参必须是同文件 @Builder 函数（跨模块 import 的 @Builder 不携带装饰器
 *     变换，编译期 10905109）——本文件为限速窗/完成窗定义本地 @Builder 包装调内容组件
 *     （progressWindowBuilder/speedLimiterLocalBuilder/completedLocalBuilder）。
 * 刷新机制（keyConstraint #2）：@Observed ProgressWindowModel + @ObjectLink 只读渲染；
 * 模型字段唯一写者=Index 事件链/host（禁换引用）；Content 组件对 model 只读。
 * 创建时机非对称（差异 #16，源 1:1）：Start 路径只看 Config.ShowProgressWindow
 * （ApplicationCore.cs:166-176 无 nonInteractive 条件）；Resume 路径要求 show && !nonInteractive
 * （:306-308）→ Index.onStarted 尾部经 manager.isInteractive(id) 判定后调 openFor。
 * autoCancel:false（差异 #2）：外部点击/返回键不关窗（源 Window_Closing→StopDownload(true)
 * 的"误触关窗即停"放大面）；关闭路径仅 Hide（hideFor 不停）/Stop（stopOne+closeFor）。
 * ConfigChanged 刷新（xaml.cs:46-58 ApplicationEvent）：Config.setSpeedLimit 广播 →
 * 全部开窗 speedLimitText 重算（SetSpeedLimitText :177-186 同式）。
 * 红线：本文件 import 图禁 probe/**；零 [XDM_PROBE] 输出；引擎事件面零接触
 * （onPaused/onFailed/onDownloadFinished 均由 Index 事件处理器尾部转发调用）。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { UIContext, ComponentContent, promptAction, PromptAction } from '@kit.ArkUI';
import { DownloadRecord } from '../model/DownloadRecord';
import { Config } from '../core/Config';
import { SaveDirectory } from '../core/fs/SaveDirectory';
import { DownloadManager } from '../core/engine/DownloadManager';
import { speedLimitView } from '../core/util/SpeedLimitView';
import { CompletedParams, CompletedActions, CompletedDialogContent } from './CompletedDialog';
import { SpeedLimiterParams, SpeedLimiterDialogContent } from './SpeedLimiterDialog';

/** 业务日志面（domain 0x0000 / tag 'ProgressWindowHost'；只记异常路径） */
const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'ProgressWindowHost';

/** 进度窗状态机模型（@Observed；§2.1 九字段，全显式默认；唯一写者=Index 事件链/host） */
@Observed
export class ProgressWindowModel {
  /** BtnPause/Stop/Hide 动作与 host 定位键（DownloadProgressWindow.downloadId） */
  downloadId: string = '';
  /** FileNameText（ApplicationCore.cs:171/:312）=record.name */
  fileName: string = '';
  /** UrlText（:173）=record.primaryUrl ?? '' */
  url: string = '';
  /** FileSizeText/TxtStatus；初始 'Downloading ...'；进度/失败/取消态被覆盖（§3.3 表） */
  statusText: string = '';
  /** DownloadSpeedText：formatSize(bytes/s)+'/s' */
  speedText: string = '';
  /** DownloadETAText：msg_time_left + ': ' + toHMS */
  etaText: string = '';
  /** DownloadProgress（actPrgUpdate 钳位 v>=0&&v<=100?v:0 由写者执行） */
  progressPercent: number = 0;
  /** BtnPause.Tag != null（:206-235）：DownloadStarted 置 false、Failed/Cancelled 置 true */
  resumable: boolean = false;
  /** TxtSpeedLimit（:177-186）：Config 装载+ConfigChanged 刷新 */
  speedLimitText: string = '';
}

/** 进度窗动作面（Index actionsFactory 装配：闭包持 manager/record 定位） */
export class ProgressWindowActions {
  /** Pause/Resume 切换（BtnPause_Click :206-235：resumable 分派） */
  onPauseResume: () => void = () => {
  };
  /** Stop（BtnStop_Click :227-230：stopOne+关窗兜底） */
  onStop: () => void = () => {
  };
  /** Hide（BtnHide_Click :233-238：仅关窗不停） */
  onHide: () => void = () => {
  };
  /** 限速文本点击（TxtSpeedLimit_MouseDown :240-242 → host.openSpeedLimiter） */
  onOpenSpeedLimiter: () => void = () => {
  };
}

/** Content 造参（@Builder 单参约束；解包传成员） */
export class ProgressWindowContentParams {
  model: ProgressWindowModel = new ProgressWindowModel();
  actions: ProgressWindowActions = new ProgressWindowActions();
}

/** 进度窗 Builder（本文件本地 @Builder——wrapBuilder 实参须同文件，跨文件 import 不携带变换） */
@Builder
function progressWindowBuilder(p: ProgressWindowContentParams) {
  ProgressWindowContent({ model: p.model, actions: p.actions })
}

/** 限速窗 Builder（本地包装调 SpeedLimiterDialogContent；同上 wrapBuilder 约束） */
@Builder
function speedLimiterLocalBuilder(params: SpeedLimiterParams) {
  SpeedLimiterDialogContent({ params: params })
}

/** 完成窗 Builder（本地包装调 CompletedDialogContent；同上 wrapBuilder 约束） */
@Builder
function completedLocalBuilder(params: CompletedParams) {
  CompletedDialogContent({ params: params })
}

/** 进度窗内容（@ObjectLink 只读渲染；Title={p}% {name} 由进度条+百分比文本承载，差异 #1） */
@Component
export struct ProgressWindowContent {
  @ObjectLink model: ProgressWindowModel;
  actions: ProgressWindowActions = new ProgressWindowActions();

  build() {
    Column({ space: 10 }) {
      Text(this.model.fileName)
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .maxLines(1)
        .width('100%')
      Text(this.model.url)
        .fontSize(11)
        .opacity(0.6)
        .maxLines(1)
        // 长 URL（百分号编码无断词点）按字符截断并加省略号，否则只显示到最后一个 '/'
        .wordBreak(WordBreak.BREAK_ALL)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      Progress({ value: this.model.progressPercent, total: 100, type: ProgressType.Linear })
        .width('100%')
      Text(`${this.model.progressPercent}%`)
        .fontSize(13)
        .width('100%')
      Text(this.model.statusText)
        .fontSize(12)
        .maxLines(2)
        .width('100%')
      Row({ space: 16 }) {
        Text(this.model.speedText)
          .fontSize(12)
        Text(this.model.etaText)
          .fontSize(12)
      }
      .width('100%')
      Text(this.model.speedLimitText)
        .fontSize(12)
        // OPT-1：限速文本强调色资源化（可点击强调语义；dark=#6EB4F0 亮蓝自定值）
        .fontColor($r('app.color.accent'))
        .width('100%')
        .onClick(() => {
          this.actions.onOpenSpeedLimiter();
        })
      Row({ space: 10 }) {
        Button($r('app.string.dwn_hide'))
          .fontSize(12)
          .onClick(() => {
            this.actions.onHide();
          })
        Button($r('app.string.btn_stop_processing'))
          .fontSize(12)
          .onClick(() => {
            this.actions.onStop();
          })
        Button(this.model.resumable ? $r('app.string.menu_resume') : $r('app.string.menu_pause'))
          .fontSize(12)
          .onClick(() => {
            this.actions.onPauseResume();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
    }
    .width(420)
    .padding(20)
    .backgroundColor($r('app.color.dialog_bg'))
    .borderRadius(16)
    .shadow(ShadowStyle.OUTER_DEFAULT_LG)
  }
}

/** host 内部开窗簿记（model+content 成对；=activeProgressWindows[id] 字典项） */
class HostWindow {
  model: ProgressWindowModel = new ProgressWindowModel();
  content: ComponentContent<ProgressWindowContentParams> | null = null;
}

/** 完成窗排队项（单窗门下的补弹载体；actions 在补弹时重建） */
interface CompletedPendingItem {
  fileName: string;
  folder: string;
}

/**
 * 进度窗宿主（单例）：动态多窗生命周期 + 完成窗门 + 限速窗入口 + ConfigChanged 刷新。
 * Index.aboutToAppear 调 init；探针页自持独立 host 实例时经 createDetached 重建（设计 §5.12）。
 * 开合通道：UIContext（ComponentContent 构造）+ getPromptAction() 实例（open/closeCustomDialog）。
 */
export class ProgressWindowHost {
  private static instance: ProgressWindowHost | undefined = undefined;

  private uiContext: UIContext | null = null;
  /** 对话框开合通道（UIContext.getPromptAction()；openCustomDialog/closeCustomDialog 在此类上） */
  private dialogs: PromptAction | null = null;
  private actionsFactory: ((id: string) => ProgressWindowActions) | null = null;
  private windows: Map<string, HostWindow> = new Map();
  private speedLimiterContent: ComponentContent<SpeedLimiterParams> | null = null;
  private speedLimiterOpen: boolean = false;
  private completedContent: ComponentContent<CompletedParams> | null = null;
  private completedOpen: boolean = false;
  /** 完成窗排队（独立复核 medium 修复）：源码逐下载一窗可叠加（Application.cs:250-256），
   * ArkTS 单窗门下批量完成时后续 onDownloadFinished 被吞——改队列待前一窗关闭后补弹
   * （有意差异：串行弹窗替代堆叠，登记设计差异清单）。 */
  private completedPending: CompletedPendingItem[] = new Array<CompletedPendingItem>();
  /** ConfigChanged 监听（稳定引用——onConfigChanged 同引用幂等） */
  private configListener: () => void = (): void => {
    this.refreshSpeedLimitTexts();
  };
  /** 本地化标签缓存（fallback=English.txt 原文；init 时 resourceManager 一次装载） */
  private labelStatDownloading: string = 'Downloading';
  private labelMsgDwnStop: string = 'Download stopped';
  private labelSpeedLimitTitle: string = 'Speed limit';
  private labelNoSpeedLimit: string = 'No speed limit';

  static getInstance(): ProgressWindowHost {
    if (ProgressWindowHost.instance === undefined) {
      ProgressWindowHost.instance = new ProgressWindowHost();
    }
    return ProgressWindowHost.instance;
  }

  /** 探针页自持 host 用（绕过单例新建；设计 §5.12——探针不与 Index 共享应用单例） */
  static createDetached(): ProgressWindowHost {
    return new ProgressWindowHost();
  }

  /** 初始化（Index.aboutToAppear / 探针页）：uiContext+对话框通道+动作工厂+标签+Config 监听 */
  init(uiContext: UIContext, actionsFactory: (id: string) => ProgressWindowActions): void {
    this.uiContext = uiContext;
    this.dialogs = uiContext.getPromptAction();
    this.actionsFactory = actionsFactory;
    this.loadLabels();
    Config.getInstance().onConfigChanged(this.configListener);
  }

  /**
   * 开窗（幂等）：已有 model no-op（源 GetProgressWindow :309 复用同构）；否则建模型+开非模态窗。
   * 初始字段（ApplicationCore.cs:171-175 同位）：fileName/url/statusText='Downloading ...'/resumable=false
   * （DownloadStarted :216-222 置 Pause 态）+限速文本装载（Window_Loaded :252-256 同位）。
   */
  openFor(record: DownloadRecord): void {
    const ctx = this.uiContext;
    const dialogs = this.dialogs;
    if (ctx === null || dialogs === null) {
      return;
    }
    if (this.windows.has(record.id)) {
      return;
    }
    const model: ProgressWindowModel = new ProgressWindowModel();
    model.downloadId = record.id;
    model.fileName = record.name ?? '';
    model.url = record.primaryUrl ?? '';
    model.statusText = this.labelStatDownloading + ' ...';
    model.resumable = false;
    model.speedLimitText = this.speedLimitTextOf();
    const params: ProgressWindowContentParams = new ProgressWindowContentParams();
    params.model = model;
    const factory = this.actionsFactory;
    params.actions = factory !== null ? factory(record.id) : new ProgressWindowActions();
    const builder: WrappedBuilder<[ProgressWindowContentParams]> = wrapBuilder(progressWindowBuilder);
    const content: ComponentContent<ProgressWindowContentParams> =
      new ComponentContent<ProgressWindowContentParams>(ctx, builder, params);
    const entry: HostWindow = new HostWindow();
    entry.model = model;
    entry.content = content;
    this.windows.set(record.id, entry);
    // Non-modal windows would otherwise open exactly on top of each other: cascade them.
    const step: number = ((this.windows.size - 1) % 6) * 28;
    const options: promptAction.BaseDialogOptions = { isModal: false, autoCancel: false, offset: { dx: step, dy: step } };
    dialogs.openCustomDialog<ProgressWindowContentParams>(content, options)
      .catch((err: BusinessError) => {
        hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s',
          'openCustomDialog failed errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
      });
  }

  /** 关窗（Stop/结束路径；源 DestroyWindow :643-651 前的 activeProgressWindows.Remove 同位） */
  closeFor(id: string): void {
    const dialogs = this.dialogs;
    const entry: HostWindow | undefined = this.windows.get(id);
    if (entry === undefined) {
      return;
    }
    this.windows.delete(id);
    if (dialogs !== null && entry.content !== null) {
      dialogs.closeCustomDialog<ProgressWindowContentParams>(entry.content)
        .catch((err: BusinessError) => {
          hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s',
            'closeCustomDialog failed errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
        });
    }
  }

  /** Hide 路径（HideProgressWindow :643-651 同位——仅关窗不停；与 closeFor 同实现双名对齐源码） */
  hideFor(id: string): void {
    this.closeFor(id);
  }

  modelOf(id: string): ProgressWindowModel | undefined {
    const entry: HostWindow | undefined = this.windows.get(id);
    return entry !== undefined ? entry.model : undefined;
  }

  /** 取消回声（DownloadCancelled :443-458）：statusText=msg_dwn_stop、etaText=''、resumable=true */
  onPaused(id: string): void {
    const model: ProgressWindowModel | undefined = this.modelOf(id);
    if (model !== undefined) {
      model.statusText = this.labelMsgDwnStop;
      model.etaText = '';
      model.resumable = true;
    }
  }

  /** 失败回声（DownloadFailed :421-436）：statusText='error '+code（差异 #4 本地化表随 U4.3） */
  onFailed(id: string, errorCode: number): void {
    const model: ProgressWindowModel | undefined = this.modelOf(id);
    if (model !== undefined) {
      model.statusText = 'error ' + String(errorCode);
      model.etaText = '';
      model.resumable = true;
    }
  }

  /**
   * 完成收口（DownloadFinished :393-419）：先关进度窗（:412-417 DownloadId=null+DestroyWindow）
   * → Config 门 && !nonInteractive（:410-414 逐字双门——R2-F3 补齐：nonInteractive 末态经
   * manager.endedNonInteractive 查询（回声簿记先摘 liveMap，事后 isInteractive 恒 true 不可用；
   * Scheduler 定时恢复 nonInteractive=true 的下载完成不弹完成窗，源码同构））→ 开完成窗。
   */
  onDownloadFinished(id: string, filePath: string): void {
    this.closeFor(id);
    if (Config.getInstance().getShowDownloadCompleteWindow() &&
      !DownloadManager.getInstance().endedNonInteractive(id)) {
      this.openCompleted(this.baseNameOf(filePath), this.dirNameOf(filePath));
    }
  }

  /** 限速窗（ShowSpeedLimiterWindow 同位；入口=进度窗限速文本点击，全仓唯一触发点） */
  openSpeedLimiter(): void {
    const ctx = this.uiContext;
    const dialogs = this.dialogs;
    if (ctx === null || dialogs === null) {
      return;
    }
    if (this.speedLimiterOpen) {
      return;
    }
    const params: SpeedLimiterParams = new SpeedLimiterParams();
    params.onRequestClose = (): void => {
      this.closeSpeedLimiter();
    };
    const builder: WrappedBuilder<[SpeedLimiterParams]> = wrapBuilder(speedLimiterLocalBuilder);
    this.speedLimiterContent = new ComponentContent<SpeedLimiterParams>(ctx, builder, params);
    this.speedLimiterOpen = true;
    const options: promptAction.BaseDialogOptions = { isModal: false, autoCancel: true };
    dialogs.openCustomDialog<SpeedLimiterParams>(this.speedLimiterContent, options)
      .catch((err: BusinessError) => {
        hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s',
          'openSpeedLimiter failed errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
      });
  }

  /** 观测（探针 S3） */
  windowCount(): number {
    return this.windows.size;
  }

  /** 页面销毁收口（§8 风险缓解：Index/探针页 aboutToDisappear） */
  closeAll(): void {
    const dialogs = this.dialogs;
    this.windows.forEach((entry: HostWindow): void => {
      if (dialogs !== null && entry.content !== null) {
        dialogs.closeCustomDialog<ProgressWindowContentParams>(entry.content)
          .catch((err: BusinessError) => {
            hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s',
              'closeAll closeCustomDialog failed errCode=' + String(err.code) +
              ' errMessage=' + (err.message ?? ''));
          });
      }
    });
    this.windows.clear();
    this.closeSpeedLimiter();
    this.closeCompleted();
  }

  // ---------- 私有实现 ----------

  private closeSpeedLimiter(): void {
    const dialogs = this.dialogs;
    const content = this.speedLimiterContent;
    this.speedLimiterOpen = false;
    this.speedLimiterContent = null;
    if (dialogs !== null && content !== null) {
      dialogs.closeCustomDialog<SpeedLimiterParams>(content)
        .catch((err: BusinessError) => {
          hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s',
            'closeSpeedLimiter failed errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
        });
    }
  }

  /** 完成窗（DownloadCompleteUIController.ShowDialog :8-33 装配 + Show() 非模态）。
   * 独立复核 medium 修复：单窗门下批量完成的后续通知不再吞掉——入队待前一窗关闭后补弹
   * （有意差异 D 系：源码逐下载堆叠多窗，本实现串行补弹）。 */
  private openCompleted(fileName: string, folder: string): void {
    const ctx = this.uiContext;
    const dialogs = this.dialogs;
    if (this.completedOpen) {
      const pending: CompletedPendingItem = { fileName: fileName, folder: folder };
      this.completedPending.push(pending);
      return;
    }
    if (ctx === null || dialogs === null) {
      return;
    }
    const params: CompletedParams = new CompletedParams();
    params.fileName = fileName;
    params.folder = folder;
    const actions: CompletedActions = new CompletedActions();
    // U5.2 接线（差异 #6 闭环）：Open/Open folder→SaveDirectory.openFile（accessSync 预检+
    // openPreview 单文件变体）；openFolder 同路（D3 降级）；失败仅 hilog（完成窗无失败弹窗=
    // 源 DownloadComplete 窗同貌，D11）
    actions.onOpenFile = (): void => {
      this.openFinishedFile(folder + '/' + fileName, 'openFile');
    };
    actions.onOpenFolder = (): void => {
      this.openFinishedFile(folder + '/' + fileName, 'openFolder');
    };
    // 差异 #14：持久化（源仅内存态 ShowDownloadCompleteWindow=false 不落盘）
    actions.onDontShowAgain = (): void => {
      Config.getInstance().setShowDownloadCompleteWindow(false);
    };
    actions.onClose = (): void => {
      this.closeCompleted();
    };
    params.actions = actions;
    const builder: WrappedBuilder<[CompletedParams]> = wrapBuilder(completedLocalBuilder);
    this.completedContent = new ComponentContent<CompletedParams>(ctx, builder, params);
    this.completedOpen = true;
    const options: promptAction.BaseDialogOptions = { isModal: false, autoCancel: true };
    dialogs.openCustomDialog<CompletedParams>(this.completedContent, options)
      .catch((err: BusinessError) => {
        // 开启失败复位单飞门（独立复核 low）：否则完成窗/限速窗从此永久静默
        this.completedOpen = false;
        this.completedContent = null;
        hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s',
          'openCompleted failed errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
      });
  }

  private closeCompleted(): void {
    const dialogs = this.dialogs;
    const content = this.completedContent;
    this.completedOpen = false;
    this.completedContent = null;
    if (dialogs !== null && content !== null) {
      dialogs.closeCustomDialog<CompletedParams>(content)
        .then((): void => {
          // 完成窗队列补弹（独立复核 medium 修复）：串行弹出下一项
          const next: CompletedPendingItem | undefined = this.completedPending.shift();
          if (next !== undefined) {
            this.openCompleted(next.fileName, next.folder);
          }
        })
        .catch((err: BusinessError) => {
          hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s',
            'closeCompleted failed errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
        });
    }
  }

  /** 完成窗 Open/Open folder 动作（U5.2 接线，D11）：SaveDirectory.openFile fire-and-forget
   * ——失败（文件不存在/预览不支持）仅 hilog，不弹窗（源 DownloadComplete 窗同貌）。 */
  private openFinishedFile(path: string, action: string): void {
    const ctx = this.uiContext?.getHostContext();
    if (ctx === undefined) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, '%{public}s',
        'openFinishedFile skipped: no host context action=' + action);
      return;
    }
    // ctx 已窄化非 undefined（handleMenuExit 同款 downcast 惯例）
    SaveDirectory.openFile(ctx as common.UIAbilityContext, path, action).then((ok: boolean): void => {
      if (!ok) {
        hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s',
          'openFinishedFile failed action=' + action + ' path=' + path);
      }
    }).catch((err: BusinessError): void => {
      hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s',
        'openFinishedFile threw errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
    });
  }

  /** 完成窗存活观测（探针 S4 completedShown） */
  isCompletedOpen(): boolean {
    return this.completedOpen;
  }

  /** 待补弹完成窗数观测（探针 S4：首窗未关时后续完成只入队，存活态无法区分门是否挡住） */
  completedPendingCount(): number {
    return this.completedPending.length;
  }

  /** 限速文本（SetSpeedLimitText :177-186 同式：enable&&limit>0 → '{title} - {limit}K/S'） */
  private speedLimitTextOf(): string {
    const view = speedLimitView(Config.getInstance().getEnableSpeedLimit(),
      Config.getInstance().getDefaultDownloadSpeed());
    if (view.enabled && view.speedKBps > 0) {
      return this.labelSpeedLimitTitle + ' - ' + String(view.speedKBps) + 'K/S';
    }
    return this.labelNoSpeedLimit;
  }

  /** ConfigChanged 广播消费（xaml.cs:46-58）：全部开窗限速文本重算 */
  private refreshSpeedLimitTexts(): void {
    const text: string = this.speedLimitTextOf();
    this.windows.forEach((entry: HostWindow): void => {
      entry.model.speedLimitText = text;
    });
  }

  /** 运行时切换语言后重载标签并刷新已开窗口的限速文本（2026-11-19） */
  reloadLabels(): void {
    this.loadLabels();
    this.refreshSpeedLimitTexts();
  }

  /** 标签装载（getStringSync(resId) 重载避弃用告警——Index.buildStatusLabels 先例） */
  private loadLabels(): void {
    const ctx = this.uiContext?.getHostContext();
    if (ctx === undefined || ctx === null) {
      return;
    }
    try {
      this.labelStatDownloading = ctx.resourceManager.getStringSync($r('app.string.stat_downloading').id);
      this.labelMsgDwnStop = ctx.resourceManager.getStringSync($r('app.string.msg_dwn_stop').id);
      this.labelSpeedLimitTitle = ctx.resourceManager.getStringSync($r('app.string.speed_limit_title').id);
      this.labelNoSpeedLimit = ctx.resourceManager.getStringSync($r('app.string.msg_no_speed_limit').id);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s',
        'loadLabels failed errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
    }
  }

  private baseNameOf(path: string): string {
    const idx: number = path.lastIndexOf('/');
    return idx >= 0 ? path.slice(idx + 1) : path;
  }

  private dirNameOf(path: string): string {
    const idx: number = path.lastIndexOf('/');
    return idx >= 0 ? path.slice(0, idx) : path;
  }
}
