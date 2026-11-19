/*
 * U4.3 凭据设置页 + 密码编辑对话框（设计书 §1-#10；对照 PasswordManagerView.xaml.cs +
 * PasswordWindow.xaml.cs，本会话逐行核对）。
 * 控件面：LvPasswords 凭据列表（host/user/pass 三列，:34-41 PopulateUI）+ 增/改/删三钮
 * （CatAdd/CatEdit/CatDel :48-91——删除按选中索引 D13：LvPasswords.SelectedIndex 对应物=
 * 列表行选中态）。PasswordWindow（:24-94）：Host/UserName/Password 三输入，OK 校验链
 * 空 Host→MSG_HOST_NAME_MISSING（:75-79）、空 User→MSG_NO_USERNAME（:80-84）弹提示不关窗；
 * 取消零写入。
 * 保存（UpdateConfig :43-46）：setUserCredentials(本地列表整块写回)。
 * 形态：@CustomDialog 默认模态（源 ShowDialog 分型）；宿主改预填模型后 open（RefreshLinkModel 式）。
 * 红线：本文件不 import probe/**；零 [XDM_PROBE] 输出。
 */

import { Config, UserCredential } from '../../core/Config';
import { SettingsSession } from './SettingsSession';

/** 密码对话框预填模型（新增=空模型；编辑=SetPassword :48-53 同位回填） */
export class PasswordEditModel {
  host: string = '';
  user: string = '';
  password: string = '';
}

/** 密码编辑对话框（PasswordWindow 同位） */
@CustomDialog
export struct PasswordEditDialog {
  controller?: CustomDialogController;
  model: PasswordEditModel = new PasswordEditModel();
  /** 校验通过后的确认回调（宿主按新增/编辑模式落列表） */
  onConfirm: (host: string, user: string, password: string) => void =
    (host: string, user: string, password: string): void => {
    };
  onCancel: () => void = () => {
  };
  @State hostText: string = '';
  @State userText: string = '';
  @State passwordText: string = '';

  aboutToAppear(): void {
    this.hostText = this.model.host;
    this.userText = this.model.user;
    this.passwordText = this.model.password;
  }

  /** BtnOk_Click :73-87 校验链：空 Host→MSG_HOST_NAME_MISSING、空 User→MSG_NO_USERNAME */
  private handleOk(): void {
    if (this.hostText.length === 0) {
      this.showMsg($r('app.string.msg_host_name_missing'));
      return;
    }
    if (this.userText.length === 0) {
      this.showMsg($r('app.string.msg_no_username'));
      return;
    }
    this.onConfirm(this.hostText, this.userText, this.passwordText);
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
      Text($r('app.string.desc_host'))
        .fontSize(13)
        .width('100%')
      TextInput({ text: this.hostText })
        .onChange((value: string) => {
          this.hostText = value;
        })
        .width('100%')
      Text($r('app.string.desc_user'))
        .fontSize(13)
        .width('100%')
      TextInput({ text: this.userText })
        .onChange((value: string) => {
          this.userText = value;
        })
        .width('100%')
      Text($r('app.string.desc_pass'))
        .fontSize(13)
        .width('100%')
      TextInput({ text: this.passwordText })
        .type(InputType.Password)
        .onChange((value: string) => {
          this.passwordText = value;
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
    .width(380)
    .padding(16)
  }
}

@Component
export struct CredentialSettingsTab {
  /** 共享会话（SettingsPage 注入） */
  session: SettingsSession = new SettingsSession();
  /** 凭据本地镜像（:27 ObservableCollection 同位；Save 时整块写回） */
  @State credentials: UserCredential[] = [];
  @State selectedCredIndex: number = -1;
  private passwordModel: PasswordEditModel = new PasswordEditModel();
  /** 确认回调模式：0=新增/1=编辑 */
  private passwordEditMode: number = 0;
  private passwordEditIndex: number = -1;
  private passwordDialogController: CustomDialogController = new CustomDialogController({
    width: 480,
    backgroundColor: $r('app.color.dialog_bg'),
    backgroundBlurStyle: BlurStyle.NONE,
    cornerRadius: 16,
    builder: PasswordEditDialog({
      model: this.passwordModel,
      onConfirm: (host: string, user: string, password: string): void => {
        this.onPasswordConfirmed(host, user, password);
      },
      onCancel: (): void => {
      }
    }),
    autoCancel: true
  });
  /** 注册引用（register/off 必须同引用） */
  private updaterFn: () => void = (): void => {
    this.updateConfig();
  };

  aboutToAppear(): void {
    this.populateUI();
    this.session.registerUpdater(this.updaterFn);
  }

  aboutToDisappear(): void {
    this.session.unregisterUpdater(this.updaterFn);
  }

  /** PopulateUI :34-41 同位 */
  populateUI(): void {
    const loaded: UserCredential[] = Config.getInstance().getUserCredentials();
    const mirror: UserCredential[] = [];
    for (let i = 0; i < loaded.length; i++) {
      mirror.push(loaded[i]);
    }
    this.credentials = mirror;
    this.selectedCredIndex = -1;
  }

  /** UpdateConfig :43-46 同位：本地列表整块写回 */
  updateConfig(): void {
    Config.getInstance().setUserCredentials(this.credentials);
  }

  /** CatAdd_Click :48-60：空模型开对话框 */
  private handleCredentialAdd(): void {
    this.passwordModel.host = '';
    this.passwordModel.user = '';
    this.passwordModel.password = '';
    this.passwordEditMode = 0;
    this.passwordEditIndex = -1;
    this.passwordDialogController.open();
  }

  /** CatEdit_Click :63-81：SetPassword 同位回填 */
  private handleCredentialEdit(): void {
    const index: number = this.selectedCredIndex;
    if (index < 0 || index >= this.credentials.length) {
      return;
    }
    const entry: UserCredential = this.credentials[index];
    this.passwordModel.host = entry.host;
    this.passwordModel.user = entry.user;
    this.passwordModel.password = entry.password;
    this.passwordEditMode = 1;
    this.passwordEditIndex = index;
    this.passwordDialogController.open();
  }

  /** 对话框确认回调（新增 :54-59 / 编辑 :72-79 两分支） */
  private onPasswordConfirmed(host: string, user: string, password: string): void {
    const entry: UserCredential = new UserCredential(host, user, password);
    const mirror: UserCredential[] = this.credentials.slice();
    if (this.passwordEditMode === 1 && this.passwordEditIndex >= 0 &&
      this.passwordEditIndex < mirror.length) {
      mirror[this.passwordEditIndex] = entry;
    } else {
      mirror.push(entry);
    }
    this.credentials = mirror;
  }

  /** CatDel_Click :84-91：按选中索引删（D13） */
  private handleCredentialDelete(): void {
    const index: number = this.selectedCredIndex;
    if (index < 0 || index >= this.credentials.length) {
      return;
    }
    const mirror: UserCredential[] = this.credentials.slice();
    mirror.splice(index, 1);
    this.credentials = mirror;
    this.selectedCredIndex = -1;
  }

  build() {
    Column({ space: 10 }) {
      List({ space: 2 }) {
        ForEach(this.credentials, (entry: UserCredential, index: number) => {
          ListItem() {
            Row({ space: 8 }) {
              Text(entry.host)
                .fontSize(13)
                .layoutWeight(2)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(entry.user)
                .fontSize(12)
                .opacity(0.7)
                .layoutWeight(2)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text('••••••')
                .fontSize(12)
                .opacity(0.7)
                .layoutWeight(1)
            }
            .width('100%')
            .padding(8)
            .borderRadius(6)
            // OPT-1：选中/常态底资源化（与 GeneralSettingsTab 分类列表同款映射，字色维持不显式）
            .backgroundColor(index === this.selectedCredIndex
              ? $r('app.color.category_highlight') : $r('app.color.control_bg'))
            .onClick(() => {
              this.selectedCredIndex = index;
            })
          }
        }, (entry: UserCredential, index: number) => entry.host + '/' + entry.user + '/' +
          String(index))
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)

      Row({ space: 8 }) {
        Blank()
        Button($r('app.string.settings_cat_add'))
          .fontSize(12)
          .height(30)
          .onClick(() => {
            this.handleCredentialAdd();
          })
        Button($r('app.string.settings_cat_edit'))
          .fontSize(12)
          .height(30)
          .onClick(() => {
            this.handleCredentialEdit();
          })
        Button($r('app.string.desc_del'))
          .fontSize(12)
          .height(30)
          .onClick(() => {
            this.handleCredentialDelete();
          })
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding(12)
  }
}
