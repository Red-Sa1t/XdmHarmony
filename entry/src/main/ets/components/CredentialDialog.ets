/*
 * U4.2 凭据对话框（设计书 §3.8/§5.10；对照 CredentialsPromptDialog.xaml.cs，本会话逐行核对）。
 * 形态：@CustomDialog 默认模态（源 PromtForCredentials → ShowDialog() 分型，WpfPlatformUIService
 * :126-137）。业务无 UI 触发点（源 PromptForCredential 全仓 0 调用方死链，设计注记 §0-3）——
 * Index 不持控制器，探针页持控制器验收（差异 #11）。
 * 内容面（xaml.cs）：
 *   - User Name/Password 两输入（TxtUserName/TxtPassword.Password）
 *   - OK：空用户名 → MessageBox(MSG_NO_USERNAME) 不关窗（:56-61）；否则 Result=true+Close
 *   - Cancel：Result=false+Close（:63-67）
 *   - 产物 Credentials = {UserName, Password}（:17-22——写既有 record.authentication，
 *     勘误②零表结构变更；Basic 头注入+401 挑战重试登记 U6.x，openQuestion 拍板不做 preemptive）
 * 红线：本文件 import 图禁 probe/**；零 [XDM_PROBE] 输出。
 */

import { AuthenticationInfo } from '../model/DownloadTypes';

@CustomDialog
export struct CredentialDialog {
  controller?: CustomDialogController;
  /** 确认回调：非空用户名的 AuthenticationInfo（消费方=探针页验收；业务挂点 U6.x） */
  onConfirm: (auth: AuthenticationInfo) => void = (auth: AuthenticationInfo): void => {
  };
  onCancel: () => void = () => {
  };
  @State userName: string = '';
  @State password: string = '';

  /** OK（BtnOk_Click :56-61：空用户名提示不关窗；否则回调+关窗） */
  private handleOk(): void {
    if (this.userName.length === 0) {
      this.showMsg($r('app.string.msg_no_username'));
      return;
    }
    const auth: AuthenticationInfo = {
      userName: this.userName,
      password: this.password
    };
    this.onConfirm(auth);
    this.controller?.close();
  }

  private handleCancel(): void {
    this.onCancel();
    this.controller?.close();
  }

  private showMsg(message: ResourceStr): void {
    this.getUIContext().showAlertDialog({
      message: message,
      primaryButton: {
        value: 'OK',
        action: () => {
        }
      }
    });
  }

  build() {
    Column({ space: 12 }) {
      Text($r('app.string.nd_auth'))
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .width('100%')
      Text($r('app.string.desc_user'))
        .fontSize(13)
        .width('100%')
      TextInput({ text: this.userName })
        .onChange((value: string) => {
          this.userName = value;
        })
        .width('100%')
      Text($r('app.string.desc_pass'))
        .fontSize(13)
        .width('100%')
      TextInput({ text: this.password })
        .type(InputType.Password)
        .onChange((value: string) => {
          this.password = value;
        })
        .width('100%')
      Row({ space: 12 }) {
        Button($r('app.string.nd_cancel'))
          .onClick(() => {
            this.handleCancel();
          })
        Button($r('app.string.msg_ok'))
          .onClick(() => {
            this.handleOk();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
    }
    .width(360)
    .padding(16)
  }
}
