/*
 * U1.2 新建下载对话框（@CustomDialog，INewDownloadDialog 契约最小子集，设计书 §3.5/§5.7）。
 * 对照源码锚（UI/NewDownloadDialogUIController.cs）：
 *   校验链        ← :153-162 OnDownloadClicked：IsUriValid → MSG_INVALID_URL；SelectedFileName 空
 *                  → MSG_NO_FILE（showAlertDialog 等价 ShowMessageBox；promptAction 全局已废弃走 UIContext）
 *   UrlChanged    ← :65-72：isUriValid 时 fileName=fileNameFromUrl(url) 自动推导
 *                  （设计修正：fileNameTouched 未置位才覆盖——C# 无条件覆盖，保用户输入）
 *   fetchMode     ← :184 同式：SelectedFileName != 推导名 ? None : FileNameAndExtension
 *                  （fileNameTouched 漏标输入场景由推导名比较兜底）
 *   DisposeWindow ← :213 → controller.close()
 * 契约裁剪（D13，单元指令"最小子集"）：SetFileSizeText 不预留（U5.2 D5：剪贴板 Message 无
 * Content-Length 恒 '---' 信息量为零）、DownloadLater/QueueScheduler/UrlBlocked 事件不注册死
 * （队列/黑名单属 U3.1/U6.x）；无目录下拉（U1.2 D13 子集延续），saveDir 只读展示经 FolderAlgo
 * 解析（Manual→拷贝目标 URI/Auto→沙箱目录，D5 双轨投影）。
 * U5.2 预填经 NewDownloadModel（设计书 §1-#12/拍板⑦）：共享对象模式（keyConstraint #2 惯例——
 * builder 构造期绑定，open 前赋值）；预填在 aboutToAppear：url/derivedName/fileName 三写且
 * 不置 fileNameTouched（UrlChangedEvent 自动推导 :53-58 同位；程序化赋值不触回显守卫）；
 * initialUrl 消费后即清（防重开残留）。onClosed 回调由 aboutToDisappear 发射
 * （DestroyEvent→destroyCallback 同位：任何关闭路径恰一次）。
 * 红线：本文件 import 图禁 probe/**；@Observed 字段不在本组件写（onConfirm 回调链在 Index 单写者侧）。
 */

import { isUriValid } from '../core/net/HttpProtocol';
import { sanitizeFileName, fileNameFromUrl } from '../core/util/FileNames';
import { FOLDER_MODE_MANUAL } from '../core/util/FolderAlgo';
import { SaveDirectory, displayFolder } from '../core/fs/SaveDirectory';
import { FileNameFetchMode } from '../model/DownloadTypes';
import { Config } from '../core/Config';

/** 确认回调：url 原文、消毒后文件名、fileNameFetchMode 列值（NewDownloadDialogUIController.cs:184 同式） */
export type NewDownloadConfirmHandler = (url: string, fileName: string, fetchMode: number) => Promise<boolean>;

/** 预填模型（plain class 无装饰器——只读一次非渲染态；Index 持有共享实例 open 前赋 initialUrl） */
export class NewDownloadModel {
  initialUrl: string = '';
  initialName: string = '';
  initialSize: number = 0;
}

@CustomDialog
export struct NewDownloadDialog {
  controller?: CustomDialogController;
  onConfirm: NewDownloadConfirmHandler = async (url: string, fileName: string, fetchMode: number): Promise<boolean> => {
    return false;
  };
  onCancel: () => Promise<boolean> = async (): Promise<boolean> => {
    return true;
  };
  /** 预填载体（Index/剪贴板链 open 前写 initialUrl；aboutToAppear 一次性消费） */
  model: NewDownloadModel = new NewDownloadModel();
  /** 关闭回调（DestroyEvent 同位：任何关闭路径——确认/取消/外部点击——aboutToDisappear 恰一次） */
  onClosed: () => void = () => {
  };
  @State url: string = '';
  @State fileName: string = '';
  @State saveDir: string = '';
  @State busy: boolean = false;
  private generation: number = 0;
  private active: boolean = false;
  /** 用户是否手动改过文件名（TextInput 回显守卫：程序化赋值不置位） */
  private fileNameTouched: boolean = false;
  /** 当前 URL 的自动推导名（fetchMode 比较基准） */
  private derivedName: string = '';
  /** 程序写入过的文件名（回显守卫用） */
  private autoNames: Set<string> = new Set<string>();
  /** 预填地址（预填名可能来自浏览器/剪贴板，不按地址重推） */
  private prefilledUrl: string = '';

  aboutToAppear(): void {
    this.generation++;
    this.active = true;
    this.busy = false;
    // saveDir 展示经 FolderAlgo 解析（D5）：Manual→拷贝目标 URI（userSelected/recentFolders[0]）/
    // Auto（null）→沙箱 downloadDir；既有行替换、语义等价（原恒沙箱目录）
    const cfg: Config = Config.getInstance();
    // 2026-11-22：显示成品最终位置——选过保存目录时为该目录（按类型自动分类时为其下分类子文件夹），
    // 否则为应用内下载目录
    const userFolder: string = SaveDirectory.userFolder();
    this.saveDir = userFolder.length > 0 ? displayFolder(userFolder) +
      (cfg.getFolderSelectionMode() === FOLDER_MODE_MANUAL ? '' : '/…') : cfg.getDownloadDir();
    // U5.2 预填块（ShowNewDownloadDialog :263-276 message 分支同位）：三写不置 fileNameTouched
    // （不触回显守卫）；initialUrl 非法/空跳过；消费后即清防重开残留
    const initial: string = this.model.initialUrl;
    if (initial.length > 0 && isUriValid(initial)) {
      this.url = initial;
      const derived: string = fileNameFromUrl(initial);
      this.derivedName = derived;
      this.fileName = this.model.initialName.length > 0 ? this.model.initialName : derived;
      this.autoNames.add(this.fileName);
      this.prefilledUrl = initial;
    }
    this.model.initialUrl = '';
    this.model.initialName = '';
  }

  /** DestroyEvent 同位（拍板⑥/D10）：任何关闭路径恰一次发射——Index.onNewDownloadClosed 摘
   * openPrompts 单实例集锚 */
  aboutToDisappear(): void {
    this.generation++;
    this.active = false;
    this.onClosed();
  }

  private handleUrlChange(value: string): void {
    this.url = value;
    if (isUriValid(value)) {
      const derived: string = fileNameFromUrl(value);
      this.derivedName = derived;
      if (!this.fileNameTouched) {
        this.autoNames.add(derived);
        this.fileName = derived;
      }
    }
  }

  private handleNameChange(value: string): void {
    // 回显守卫：程序化赋值（UrlChanged 自动推导）触发的 onChange 不置 touched 旗标
    // 2026-11-22：快速输入/粘贴地址时 onChange 回显可能晚到（值为更早一次的推导名），程序写入过的名字
    // 一律不算用户修改
    if (value !== this.fileName && !this.autoNames.has(value)) {
      this.fileNameTouched = true;
    }
    this.fileName = value;
  }

  /** Download Now（OnDownloadClicked :149-162 校验链 1:1） */
  private async handleConfirm(): Promise<void> {
    if (this.busy) {
      return;
    }
    if (!isUriValid(this.url)) {
      this.showMsg($r('app.string.msg_invalid_url'));
      return;
    }
    if (this.fileName.length === 0) {
      this.showMsg($r('app.string.msg_no_file'));
      return;
    }
    // 与 C# new Uri() 的 RFC 空白归一等价（Helpers.cs:45-56）：校验后提交前剥离首尾空白，
    // 防带空白 URL 直发传输层→连接期重试 10×10s 的『莫名失败』体验（独立复核 low）
    this.url = this.url.trim();
    // 2026-11-22：用户没改过文件名时按最终地址重新推导（输入过程中的回显可能留下中间结果）
    if (!this.fileNameTouched && this.url !== this.prefilledUrl) {
      const finalName: string = fileNameFromUrl(this.url);
      if (finalName.length > 0) {
        this.derivedName = finalName;
        this.autoNames.add(finalName);
        this.fileName = finalName;
      }
    }
    const fetchMode: number = (this.fileNameTouched || this.fileName !== this.derivedName)
      ? FileNameFetchMode.None
      : FileNameFetchMode.FileNameAndExtension;
    this.busy = true;
    const generation: number = this.generation;
    try {
      const ok: boolean = await this.onConfirm(this.url, sanitizeFileName(this.fileName), fetchMode);
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

  /** ShowMessageBox 等价（UIContext.showAlertDialog；避免已废弃全局 promptAction） */
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
      Text($r('app.string.nd_title'))
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .width('100%')
      Text($r('app.string.nd_address'))
        .fontSize(13)
        .width('100%')
      TextInput({ text: this.url, placeholder: 'http://' })
        .onChange((value: string) => {
          this.handleUrlChange(value);
        })
        .width('100%')
      Text($r('app.string.nd_file'))
        .fontSize(13)
        .width('100%')
      TextInput({ text: this.fileName })
        .onChange((value: string) => {
          this.handleNameChange(value);
        })
        .width('100%')
      Text($r('app.string.lbl_save_in'))
        .fontSize(13)
        .width('100%')
      Text(this.saveDir.length > 0 ? this.saveDir : '-')
        .fontSize(12)
        .opacity(0.7)
        .maxLines(2)
        .width('100%')
      Row({ space: 12 }) {
        Button($r('app.string.nd_cancel'))
          .onClick(() => {
            this.handleCancel();
          })
        Button($r('app.string.nd_download_now'))
          .onClick(() => {
            this.handleConfirm();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
    }
    .width('100%')
    .padding(16)
    .enabled(!this.busy)
  }
}
