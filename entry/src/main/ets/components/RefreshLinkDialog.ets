/*
 * U4.2 刷新链接对话框（设计书 §3.7/§5.10；对照 LinkRefreshWindow.xaml.cs +
 * LinkRefreshDialogUIController.cs:17-81，本会话逐行核对）。
 * 形态：@CustomDialog 非模态（源 ShowWindow→Show 分型）；宿主=Index 单实例 controller +
 * RefreshLinkModel 共享对象（keyConstraint #2：builder 构造期绑定，open 前改字段禁重建 controller）。
 * U6.3：等待同大小的单源链接，持久化成功后由 Index 告知成功并关闭；失败保留监听供重试。
 * Stop、外部关闭和页面销毁通过捕获的 sessionToken 清理监听；每次出现重置幂等守卫。
 * 旧窗关闭不能取消随后登记的会话。浏览器打开与存储由 Index/LinkRefresher 负责。
 * 红线：本文件 import 图禁 probe/**；零 [XDM_PROBE] 输出。
 */

/** 刷新链接会话模型；Index 在开窗前设置，持久化完成后更新接受状态。 */
@Observed
export class RefreshLinkModel {
  token: number = 0;
  waiting: boolean = true;
  linkAccepted: boolean = false;
  failed: boolean = false;
  browserOpenFailed: boolean = false;
  targetName: string = '';
}

@CustomDialog
export struct RefreshLinkDialog {
  controller?: CustomDialogController;
  /** 外部传入共享实例（Index 持有；builder 构造期绑定，@ObjectLink 渲染 LinkReceived 态切换） */
  @ObjectLink model: RefreshLinkModel;
  /** Stop 回调（WatchingStopped → ClearWatchList） */
  onStopped: (token: number) => void = (token: number): void => {
  };
  onClosed: (token: number) => void = (token: number): void => {};
  /** WatchingStopped 幂等守卫（任何关闭路径恰一次） */
  private stoppedSent: boolean = false;
  private closedSent: boolean = false;
  private sessionToken: number = 0;

  aboutToAppear(): void {
    this.sessionToken = this.model.token;
    this.stoppedSent = false;
    this.closedSent = false;
  }

  /** Stop（BtnStop_Click+Window_Closing：关窗+WatchingStopped） */
  private handleStop(): void {
    this.notifyStopped();
    this.controller?.close();
  }

  /** WatchingStopped 发射（幂等）：Stop 钮路径与 aboutToDisappear 兜底共用——二次调用被守卫吸收 */
  private notifyStopped(): void {
    if (this.stoppedSent) {
      return;
    }
    this.stoppedSent = true;
    this.onStopped(this.sessionToken);
  }

  /** Window_Closing 兜底（:75-77）：Stop 钮外的任何关闭路径（外部点击/返回键）也恰一次发射 */
  aboutToDisappear(): void {
    this.notifyStopped();
    if (!this.closedSent) {
      this.closedSent = true;
      this.onClosed(this.sessionToken);
    }
  }

  build() {
    Column({ space: 14 }) {
      Text(this.model.targetName)
        .fontSize(14)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      if (this.model.linkAccepted) {
        // LinkReceived（:49-63）：宿主展示成功提示，确认后关闭。
        Text($r('app.string.msg_ref_link_msg'))
          .fontSize(14)
          .width('100%')
      } else {
        Text($r('app.string.ref_waiting_for_link'))
          .fontSize(14)
          .width('100%')
      }
      if (this.model.failed) {
        Text($r('app.string.msg_refresh_save_failed'))
          .fontSize(12)
          .width('100%')
      }
      if (this.model.browserOpenFailed) {
        Text($r('app.string.msg_refresh_browser_failed'))
          .fontSize(12)
          .width('100%')
      }
      Row({ space: 12 }) {
        Button($r('app.string.btn_stop_processing'))
          .onClick(() => {
            this.handleStop();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
    }
    .width(360)
    .padding(16)
  }
}
