/*
 * U4.2 删除确认对话框（设计书 §3.4/§5.10；对照 DeleteConfirmDialog.xaml.cs +
 * MainWindow.xaml.cs:316-327 ConfirmDelete，本会话逐行核对）。
 * 形态：@CustomDialog 默认模态（源 ShowDialog() 分型——§3.8 模态三件套之一）；
 * 宿主=Index 单实例 controller（完成视图 Delete 分支）。
 * 内容面：说明文本（DEL_SEL_TEXT，ConfirmDelete 首参）+ 'Delete files from disk' 勾选
 * （ChkDiskDel → ShouldDeleteFile）+ Delete/Cancel（Result=true/false + Close）。
 * 差异 #6：deleteFiles 勾选只收值不删盘上文件（U5.2 文件能力面，hilog 登记在 Index 消费侧）。
 * 红线：本文件 import 图禁 probe/**；零 [XDM_PROBE] 输出。
 */

@CustomDialog
export struct DeleteConfirmDialog {
  controller?: CustomDialogController;
  /** 确认回调：携带删文件勾选值（approved 分支） */
  onConfirm: (deleteFiles: boolean) => void = (deleteFiles: boolean): void => {
  };
  /** 取消回调（approved=false 分支——Index 侧行保留但已停的语义注记在 §3.4） */
  onCancel: () => void = () => {
  };
  @State deleteFiles: boolean = false;

  private handleDelete(): void {
    this.onConfirm(this.deleteFiles);
    this.controller?.close();
  }

  private handleCancel(): void {
    this.onCancel();
    this.controller?.close();
  }

  build() {
    Column({ space: 14 }) {
      Text($r('app.string.del_sel_text'))
        .fontSize(14)
        .width('100%')
      Row({ space: 8 }) {
        Toggle({ type: ToggleType.Checkbox, isOn: this.deleteFiles })
          .onChange((value: boolean) => {
            this.deleteFiles = value;
          })
        Text($r('app.string.lbl_delete_file'))
          .fontSize(13)
      }
      .width('100%')
      Row({ space: 12 }) {
        Button($r('app.string.nd_cancel'))
          .onClick(() => {
            this.handleCancel();
          })
        Button($r('app.string.desc_del'))
          .onClick(() => {
            this.handleDelete();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
    }
    .width(380)
    .padding(16)
  }
}
