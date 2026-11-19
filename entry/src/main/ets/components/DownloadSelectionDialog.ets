/*
 * U4.2 选择窗 + More 高级子窗（设计书 §3.5/§5.9；对照 DownloadSelectionUIController.cs:114-135 +
 * DownloadSelectionWindow.xaml.cs:185-200 + AdvancedDownloadOption.xaml.cs，本会话逐行核对）。
 * 形态：选择窗 @CustomDialog 非模态（源 Show() Run :54-57 → isModal:false）；宿主=Index 单实例
 * controller + SelectionSession 共享对象（keyConstraint #2：builder 构造期绑定，open 前改字段，
 * 禁重建 controller——Index 侧 session.items 整体替换触发 @Observed 重渲染）。
 * 条目模型（§2.2）：@Observed SelectionItemModel，selected 默认 true（xaml.cs:189
 * private bool selected = true——首屏全选框不勾但条目已全选，源码同貌保留）；entryType 恒 'Http'
 * （PopuplateEntryWrapper :69-97 四型映射，本期数据源只有 Batch 生成的 SingleSource HTTP 链接）。
 * 全选框（xaml:31-32 Checked+Unchecked 同 handler）：Toggle onChange 批量写 selected。
 * 校验链（DownloadSelectedItems :114-135 顺序 1:1）：saveIn 空 → MSG_CAT_FOLDER_MISSING（:116-120）；
 * 选中数 0 → BAT_SELECT_ITEMS（:121-125）；通过 → 逐选中项回调+关窗。
 * Download Later 菜单（DownloadLaterMenuHelper.cs:24-41 次序保留）：零命名队列项（清单恒空，
 * 差异 #9）+ 'Do not use queue'（queueId=null 落 Download Later）+ 'Queue and scheduler'（占位禁用，
 * 队列窗不在本单元）。
 * More 子窗（AdvancedDownloadOptionDialog，模态）：裁剪面=认证+代理（差异 #10：System Proxy 按
 * MIGRATION_PLAN §3-2 降级隐藏；限速段省略——源控制器 AddDownload :99-112 只消费
 * view.Authentication/view.Proxy，限速两值死值）。代理读出（AdvancedDownloadOption.xaml.cs
 * Proxy getter 同构）：No Proxy→ProxyType.Direct(1)；Manual+host 非空+port 可析→Custom(2)，否则 null
 * （消费侧 view.Proxy ?? 默认投影）。认证空用户名→null（xaml.cs :32-54 空判）。
 * 高级子窗工作副本（advancedTarget 内联初始化稳定引用——规避 CustomDialogController builder
 * 成员初始化期求值时序；子窗结构体先于宿主声明）：open 前会话→工作副本，确认后工作副本→会话。
 * Browse 占位（差异 #8：目录恒 Config.getDownloadDir()，DocumentViewPicker 归 U5.2）。
 * 红线：本文件 import 图禁 probe/**；零 [XDM_PROBE] 输出。
 */

import { AuthenticationInfo, ProxyInfo, ProxyType } from '../model/DownloadTypes';
import { Config } from '../core/Config';
import { DownloadRequestContext } from '../model/DownloadRequestContext';

/** 选择条目（@Observed；§2.2——selected 默认 true，全选框首屏不勾的源码同貌） */
@Observed
export class SelectionItemModel {
  name: string = '';
  url: string = '';
  size: number = 0;
  contextUrl: string = '';
  requestContext: DownloadRequestContext = new DownloadRequestContext();
  /** 恒 'Http'（PopuplateEntryWrapper 四型映射的 SingleSourceHTTPDownloadInfo 分支） */
  entryType: string = 'Http';
  selected: boolean = true;
}

/** 选择窗会话（Index 单写者：open 前整体替换 items/改 saveIn；对话框只读 saveIn/auth/proxy） */
@Observed
export class SelectionSession {
  items: SelectionItemModel[] = [];
  auth: AuthenticationInfo | null = null;
  proxy: ProxyInfo | null = null;
  saveIn: string = '';
}

/** 高级子窗工作副本（内联初始化稳定引用；字段=认证+代理裁剪面） */
class AdvancedTarget {
  userName: string = '';
  password: string = '';
  /** 0=No Proxy(Direct)、1=Manual(Custom)——System 选项降级隐藏（差异 #10） */
  proxyMode: number = 0;
  proxyHost: string = '';
  proxyPort: string = '';
  proxyUser: string = '';
  proxyPass: string = '';
}

/** 选择窗行（@ObjectLink item：复选框是 selected 的交互写者） */
@Component
struct SelectionRow {
  @ObjectLink item: SelectionItemModel;

  build() {
    Row({ space: 8 }) {
      Toggle({ type: ToggleType.Checkbox, isOn: this.item.selected })
        .onChange((value: boolean) => {
          this.item.selected = value;
        })
      Text(this.item.name)
        .fontSize(12)
        .maxLines(1)
        .layoutWeight(1)
      Text(this.item.entryType)
        .fontSize(11)
        .opacity(0.6)
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
  }
}

/** More 高级子窗（@CustomDialog 模态——源 ShowDialog 分型；认证+代理裁剪面，差异 #10）。
 * 先于宿主 DownloadSelectionDialog 声明（宿主成员初始化器引用本结构体）。 */
@CustomDialog
struct AdvancedOptionDialog {
  controller?: CustomDialogController;
  /** 工作副本（父 SelectionDialog 持有的稳定引用；确认后父侧回写会话） */
  target: AdvancedTarget = new AdvancedTarget();
  onConfirm: () => void = () => {
  };
  onCancel: () => void = () => {
  };
  @State userName: string = '';
  @State password: string = '';
  @State proxyMode: number = 0;
  @State proxyHost: string = '';
  @State proxyPort: string = '';
  @State proxyUser: string = '';
  @State proxyPass: string = '';

  aboutToAppear(): void {
    // 子窗每次 open 重建（close 销毁）——aboutToAppear 从工作副本装载
    this.userName = this.target.userName;
    this.password = this.target.password;
    this.proxyMode = this.target.proxyMode;
    this.proxyHost = this.target.proxyHost;
    this.proxyPort = this.target.proxyPort;
    this.proxyUser = this.target.proxyUser;
    this.proxyPass = this.target.proxyPass;
  }

  private handleOk(): void {
    this.target.userName = this.userName;
    this.target.password = this.password;
    this.target.proxyMode = this.proxyMode;
    this.target.proxyHost = this.proxyHost;
    this.target.proxyPort = this.proxyPort;
    this.target.proxyUser = this.proxyUser;
    this.target.proxyPass = this.proxyPass;
    this.onConfirm();
    this.controller?.close();
  }

  private handleCancel(): void {
    this.onCancel();
    this.controller?.close();
  }

  build() {
    Column({ space: 10 }) {
      Text($r('app.string.desc_adv_title'))
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .width('100%')

      Text($r('app.string.nd_auth'))
        .fontSize(13)
        .width('100%')
      Text($r('app.string.desc_user'))
        .fontSize(12)
        .width('100%')
      TextInput({ text: this.userName })
        .onChange((value: string) => {
          this.userName = value;
        })
        .width('100%')
      Text($r('app.string.desc_pass'))
        .fontSize(12)
        .width('100%')
      TextInput({ text: this.password })
        .onChange((value: string) => {
          this.password = value;
        })
        .width('100%')

      Text($r('app.string.desc_net4'))
        .fontSize(13)
        .width('100%')
      Row({ space: 8 }) {
        Radio({ value: 'noProxy', group: 'proxyMode' })
          .checked(this.proxyMode === 0)
          .onChange((value: boolean) => {
            if (value && this.proxyMode !== 0) {
              this.proxyMode = 0;
            }
          })
        Text($r('app.string.nd_no_proxy'))
          .fontSize(12)
        Radio({ value: 'manualProxy', group: 'proxyMode' })
          .checked(this.proxyMode === 1)
          .onChange((value: boolean) => {
            if (value && this.proxyMode !== 1) {
              this.proxyMode = 1;
            }
          })
        Text($r('app.string.nd_manual_proxy'))
          .fontSize(12)
      }
      .width('100%')

      Text($r('app.string.proxy_host'))
        .fontSize(12)
        .width('100%')
      TextInput({ text: this.proxyHost })
        .enabled(this.proxyMode === 1)
        .onChange((value: string) => {
          this.proxyHost = value;
        })
        .width('100%')
      Text($r('app.string.proxy_port'))
        .fontSize(12)
        .width('100%')
      TextInput({ text: this.proxyPort })
        .enabled(this.proxyMode === 1)
        .onChange((value: string) => {
          this.proxyPort = value.replace(new RegExp('[^0-9]', 'g'), '');
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
    .width(400)
    .padding(16)
  }
}

@CustomDialog
export struct DownloadSelectionDialog {
  controller?: CustomDialogController;
  /** 确认回调：选中条目+会话认证/代理+startImmediately（Download Now=true/Download Later=false） */
  onConfirm: (items: SelectionItemModel[], auth: AuthenticationInfo | null,
    proxy: ProxyInfo | null, startImmediately: boolean) => Promise<boolean> =
    async (items: SelectionItemModel[], auth: AuthenticationInfo | null,
      proxy: ProxyInfo | null, startImmediately: boolean): Promise<boolean> => {
      return false;
    };
  onCancel: () => Promise<boolean> = async (): Promise<boolean> => {
      return true;
    };
  onClosed: () => void = (): void => {};
  @State busy: boolean = false;
  private generation: number = 0;
  private active: boolean = false;
  @ObjectLink session: SelectionSession;
  /** 全选框（首屏不勾——条目已全选的源码同貌，§2.2） */
  @State selectAll: boolean = false;
  /** 高级子窗工作副本（先于 advancedController 声明——成员初始化序内 this 引用稳定） */
  private advancedTarget: AdvancedTarget = new AdvancedTarget();
  // Infer this initialized child controller's type: an explicit annotation makes the SDK
  // register it as a second injected parent controller and emit a duplicate setController.
  private advancedController = new CustomDialogController({
    width: 480,
    backgroundColor: $r('app.color.dialog_bg'),
    backgroundBlurStyle: BlurStyle.NONE,
    cornerRadius: 16,
    builder: AdvancedOptionDialog({
      target: this.advancedTarget,
      onConfirm: (): void => {
        this.applyAdvancedToSession();
      }
    }),
    autoCancel: true
  });

  aboutToAppear(): void {
    this.generation++;
    this.active = true;
    this.busy = false;
  }

  /** More 前：会话→工作副本（源 BtnMore_Click 以当前 authentication/proxy 构造子窗同位） */
  private handleMore(): void {
    const auth: AuthenticationInfo | null = this.session.auth;
    if (auth !== null) {
      this.advancedTarget.userName = auth.userName;
      this.advancedTarget.password = auth.password ?? '';
    } else {
      this.advancedTarget.userName = '';
      this.advancedTarget.password = '';
    }
    const proxy: ProxyInfo | null = this.session.proxy;
    if (proxy !== null && proxy.proxyType === ProxyType.Custom) {
      this.advancedTarget.proxyMode = 1;
      this.advancedTarget.proxyHost = proxy.host ?? '';
      this.advancedTarget.proxyPort = String(proxy.port);
      this.advancedTarget.proxyUser = proxy.userName ?? '';
      this.advancedTarget.proxyPass = proxy.password ?? '';
    } else {
      this.advancedTarget.proxyMode = 0;
      this.advancedTarget.proxyHost = '';
      this.advancedTarget.proxyPort = '';
      this.advancedTarget.proxyUser = '';
      this.advancedTarget.proxyPass = '';
    }
    this.advancedController.open();
  }

  /** 高级子窗确认后：工作副本→会话（源 ShowDialog 返回 true 时回填 view 属性同位） */
  private applyAdvancedToSession(): void {
    const userName: string = this.advancedTarget.userName.trim();
    if (userName.length === 0) {
      // 空用户名 → null（AdvancedDownloadOption.xaml.cs Authentication getter 空判）
      this.session.auth = null;
    } else {
      const auth: AuthenticationInfo = {
        userName: userName,
        password: this.advancedTarget.password
      };
      this.session.auth = auth;
    }
    this.session.proxy = this.readAdvancedProxy();
  }

  /** 代理读出（Proxy getter 同构）：No Proxy→Direct；Manual+host+port 可析→Custom；否则 null */
  private readAdvancedProxy(): ProxyInfo | null {
    if (this.advancedTarget.proxyMode === 0) {
      const direct: ProxyInfo = {
        proxyType: ProxyType.Direct,
        host: null,
        port: 0,
        userName: null,
        password: null
      };
      return direct;
    }
    const host: string = this.advancedTarget.proxyHost.trim();
    const port: number = Number(this.advancedTarget.proxyPort);
    if (host.length === 0 || this.advancedTarget.proxyPort.length === 0 ||
      !Number.isFinite(port) || !Number.isInteger(port)) {
      return null;
    }
    const custom: ProxyInfo = {
      proxyType: ProxyType.Custom,
      host: host,
      port: port,
      userName: this.advancedTarget.proxyUser,
      password: this.advancedTarget.proxyPass
    };
    return custom;
  }

  /** 全选框（ChkSelectAll_Checked+Unchecked 同 handler：批量写 selected） */
  private handleSelectAll(value: boolean): void {
    this.selectAll = value;
    const items: SelectionItemModel[] = this.session.items;
    for (let i = 0; i < items.length; i++) {
      items[i].selected = value;
    }
  }

  /** Browse 占位（差异 #8：目录恒 Config.getDownloadDir()，picker 归 U5.2） */
  private handleBrowse(): void {
    this.session.saveIn = Config.getInstance().getDownloadDir();
  }

  /** 选中投影（GetSelectedItems：IsSelected 过滤） */
  private selectedItems(): SelectionItemModel[] {
    const picked: SelectionItemModel[] = [];
    const items: SelectionItemModel[] = this.session.items;
    for (let i = 0; i < items.length; i++) {
      if (items[i].selected) {
        picked.push(items[i]);
      }
    }
    return picked;
  }

  /** 校验链（DownloadSelectedItems :114-135 顺序 1:1） */
  private validate(): boolean {
    if (this.session.saveIn.length === 0) {
      this.showMsg($r('app.string.msg_cat_folder_missing'));
      return false;
    }
    if (this.selectedItems().length === 0) {
      this.showMsg($r('app.string.bat_select_items'));
      return false;
    }
    return true;
  }

  /** Download Now（View_DownloadClicked → DownloadSelectedItems(true, null)） */
  private handleDownloadNow(): void {
    this.submit(true);
  }

  /** Download Later（View_DownloadLaterClicked → DownloadSelectedItems(false, queueId=null)） */
  private handleDownloadLater(): void {
    this.submit(false);
  }

  private async submit(startImmediately: boolean): Promise<void> {
    if (this.busy || !this.validate()) {
      return;
    }
    this.busy = true;
    const generation: number = this.generation;
    try {
      const ok: boolean = await this.onConfirm(this.selectedItems(), this.session.auth, this.session.proxy, startImmediately);
      if (!this.active || generation !== this.generation) { return; }
      if (ok) {
        this.controller?.close();
      } else {
        this.showMsg($r('app.string.msg_download_save_failed'));
      }
    } catch (e) {
      if (this.active && generation === this.generation) {
        this.showMsg($r('app.string.msg_download_save_failed'));
      }
    } finally {
      if (this.active && generation === this.generation) { this.busy = false; }
    }
  }

  private async handleCancel(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    const generation: number = this.generation;
    try {
      const ok: boolean = await this.onCancel();
      if (!this.active || generation !== this.generation) { return; }
      if (ok) {
        this.controller?.close();
      }
    } catch (e) {
      if (this.active && generation === this.generation) {
        this.showMsg($r('app.string.msg_download_save_failed'));
      }
    } finally {
      if (this.active && generation === this.generation) { this.busy = false; }
    }
  }

  aboutToDisappear(): void {
    this.generation++;
    this.active = false;
    this.advancedController.close();
    this.onClosed();
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

  /** Download Later 下拉（DownloadLaterMenuHelper 次序：命名队列（恒空）→ Do not use queue →
   * Queue and scheduler 占位禁用，差异 #9） */
  private laterMenuItems(): MenuElement[] {
    const items: MenuElement[] = [
      { value: $r('app.string.lbl_queue_opt3'), action: (): void => {
        this.handleDownloadLater();
      } }
      // 上架整改（2026-11-19）：队列/计划任务窗未实现，移除禁用占位项
    ];
    return items;
  }

  build() {
    Column({ space: 10 }) {
      // 全选框（首屏不勾、条目默认全选——源码同貌 §2.2）
      Row({ space: 8 }) {
        Toggle({ type: ToggleType.Checkbox, isOn: this.selectAll })
          .onChange((value: boolean) => {
            this.handleSelectAll(value);
          })
        Text($r('app.string.vid_chk'))
          .fontSize(13)
      }
      .width('100%')

      List({ space: 2 }) {
        ForEach(this.session.items, (item: SelectionItemModel) => {
          ListItem() {
            SelectionRow({ item: item })
          }
        }, (item: SelectionItemModel) => item.url)
      }
      .width('100%')
      .height(180)
      // OPT-1：列表边框资源化（dark=DarkTheme ToolbarBordercolor #000000）
      .border({ width: 1, color: $r('app.color.divider') })
      .borderRadius(6)
      .scrollBar(BarState.Auto)

      Text($r('app.string.lbl_save_in'))
        .fontSize(13)
        .width('100%')
      Row({ space: 6 }) {
        Text(this.session.saveIn.length > 0 ? this.session.saveIn : '-')
          .fontSize(12)
          .maxLines(1)
          .layoutWeight(1)
        Button($r('app.string.btn_browse'))
          .fontSize(13)
          .constraintSize({ minWidth: 44 })
          .onClick(() => {
            this.handleBrowse();
          })
      }
      .width('100%')

      Row({ space: 10 }) {
        Button($r('app.string.nd_more'))
          .fontSize(13)
          .onClick(() => {
            this.handleMore();
          })
        Button($r('app.string.nd_download_later'))
          .fontSize(13)
          .bindMenu(this.laterMenuItems())
        Button($r('app.string.nd_download_now'))
          .fontSize(13)
          .onClick(() => {
            this.handleDownloadNow();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)

      Row({ space: 10 }) {
        Button($r('app.string.nd_cancel'))
          .fontSize(13)
          .onClick(() => {
            this.handleCancel();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
    }
    .width(460)
    .padding(16)
    .enabled(!this.busy)
  }
}
