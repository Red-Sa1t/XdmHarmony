/*
 * U4.2 完成窗内容组件（设计书 §3.6/§5.5；对照 DownloadCompleteWindow.xaml.cs +
 * DownloadCompleteUIController.cs，本会话逐行核对）。
 * 打开形态：ComponentContent 动态窗（源 Show() 非模态 → uiContext.openCustomDialog
 * (ComponentContent,{isModal:false})，宿主=ProgressWindowHost.openCompleted）。
 * 内容面（xaml.cs）：
 *   - 文件名/目录两文本（FileNameText/FolderText，controller :10-11 装配）
 *   - Open / Open folder 两按钮（BtnOpen/BtnOpenFolder :53-59/:82-89——点击先回调后 Close；
 *     Cancel 键 ArkTS 增强：窗存活期用户可主动关，源窗无 Cancel 但非模态可点掉，语义等价）
 *   - "Don't show this again" 文本点击（TxtDontShowCompleteDialog_MouseDown :46-50——
 *     回调 DontShowAgainClickd + Close；host 侧装配 Config.setShowDownloadCompleteWindow(false)，
 *     差异 #14：持久化到 preferences，源码仅内存态）
 * 差异 #6：Open/Open folder 点击动作占位（hilog 登记，U5.2 文件能力面接线）。
 * 静态内容无需 @ObjectLink（params 普通成员引用，设计书 §5.5 注）。
 * 红线：本文件 import 图禁 probe/**；零 [XDM_PROBE] 输出。
 */

/** 完成窗动作面（host 装配：onOpenFile/onOpenFolder=占位 hilog、onDontShowAgain=Config 写
 * false+关窗、onClose=纯关窗——三个源码点击路径都以 Close 收尾 xaml.cs :50/:59/:89） */
export class CompletedActions {
  onOpenFile: () => void = () => {
  };
  onOpenFolder: () => void = () => {
  };
  onDontShowAgain: () => void = () => {
  };
  onClose: () => void = () => {
  };
}

/** 完成窗参数（静态快照：open 时由 host 构造，窗存续期不变） */
export class CompletedParams {
  fileName: string = '';
  folder: string = '';
  actions: CompletedActions = new CompletedActions();
}

/** 完成窗 Builder（ComponentContent 造参入口：wrapBuilder(completedDialogBuilder)） */
@Builder
export function completedDialogBuilder(params: CompletedParams) {
  CompletedDialogContent({ params: params })
}

@Component
export struct CompletedDialogContent {
  params: CompletedParams = new CompletedParams();

  /** Open（BtnOpen_Click :53-59：回调后关窗） */
  private handleOpenFile(): void {
    this.params.actions.onOpenFile();
    this.params.actions.onClose();
  }

  /** Open folder（BtnOpenFolder_Click :82-89：回调后关窗） */
  private handleOpenFolder(): void {
    this.params.actions.onOpenFolder();
    this.params.actions.onClose();
  }

  /** Don't show this again（TxtDontShowCompleteDialog_MouseDown :46-50：回调+关窗） */
  private handleDontShowAgain(): void {
    this.params.actions.onDontShowAgain();
    this.params.actions.onClose();
  }

  build() {
    Column({ space: 12 }) {
      Text($r('app.string.cd_title'))
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .width('100%')
      Text($r('app.string.nd_file'))
        .fontSize(13)
        .width('100%')
      Text(this.params.fileName.length > 0 ? this.params.fileName : '-')
        .fontSize(13)
        .maxLines(2)
        .width('100%')
      Text($r('app.string.lbl_save_in'))
        .fontSize(13)
        .width('100%')
      Text(this.params.folder.length > 0 ? this.params.folder : '-')
        .fontSize(12)
        .opacity(0.7)
        .maxLines(2)
        .width('100%')
      Text($r('app.string.msg_dont_show_again'))
        .fontSize(12)
        // OPT-1：不再提示链接色资源化（可点击强调语义；dark=#6EB4F0 亮蓝自定值）
        .fontColor($r('app.color.accent'))
        .width('100%')
        .onClick(() => {
          this.handleDontShowAgain();
        })
      Row({ space: 12 }) {
        // Non-modal window: an explicit close (source window has its title-bar close button).
        Button($r('app.string.msg_close'))
          .backgroundColor($r('app.color.control_bg'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => {
            this.params.actions.onClose();
          })
        Button($r('app.string.ctx_open_file'))
          .onClick(() => {
            this.handleOpenFile();
          })
        Button($r('app.string.ctx_open_folder'))
          .onClick(() => {
            this.handleOpenFolder();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
    }
    .width(440)
    .padding(20)
    .backgroundColor($r('app.color.dialog_bg'))
    .borderRadius(16)
    .shadow(ShadowStyle.OUTER_DEFAULT_LG)
  }
}
