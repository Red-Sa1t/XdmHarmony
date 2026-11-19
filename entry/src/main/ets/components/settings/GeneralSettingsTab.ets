/*
 * U4.3 常规设置页 + 分类编辑对话框（设计书 §1-#8；对照 GeneralSettingsView.xaml.cs +
 * CategoryEditWindow.xaml.cs，本会话逐行核对）。
 * 控件面（xaml 15 行全清单）：ChkShowPrg/ChkShowComplete/ChkStartAuto/ChkOverwrite/ChkDarkTheme/
 * ChkAutoCat 六 Toggle、TxtTempFolder/TxtDownloadFolder 两 TextInput（Browse 占位——沙箱无自由
 * 路径 D5，U5.2 接 picker）、CmbMaxParallalDownloads 1..50 Select（ctor :34）、CmbDblClickAction
 * 两项 Select（0=CTX_OPEN_FOLDER/1=MSG_OPEN_FILE，:48）、LvCategories 分类列表 +
 * CatAdd/CatEdit/CatDel/CatDef 四钮（:75-135）。
 * 枚举方向红线（设计书 §2.3）：fileConflictResolution 勾=Overwrite=1/不勾=AutoRename=0（:42/:62-63）；
 * folderSelectionMode 勾=Auto=0/不勾=Manual=1（:46/:68-69）——两枚举 0 值语义方向相反。
 * 分类对话框（CategoryEditWindow 同位）：新增 Name=util.generateRandomUUID()（Guid.NewGuid().
 * ToString() 同貌 D10）、编辑保留原 Name（:103-105 cat.Name）、FileTypes 解析=parseCategoryTypes
 * （Replace("\r\n","")+HashSet 去重保序 §3.1）、校验链 Name→FileTypes→Folder 弹
 * msg_cat_name_missing/msg_cat_file_types_missing/msg_cat_folder_missing 不关窗（:84-100）。
 * 红线：本文件不 import probe/**；零 [XDM_PROBE] 输出。
 */

import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Config } from '../../core/Config';
import { CategoryDef, DEFAULT_CATEGORIES } from '../../core/util/CategoryAlgo';
import { SaveDirectory } from '../../core/fs/SaveDirectory';
import { SettingsSession } from './SettingsSession';
import { clampToRange, joinForEdit, parseCategoryTypes, RANGE_MAX_PARALLEL, RANGE_MIN }
  from '../../core/util/SettingParse';

/** 分类对话框预填模型（宿主先改再 open——RefreshLinkModel 同式） */
export class CategoryEditModel {
  categoryName: string = '';
  fileTypes: string = '';
  folder: string = '';
}

/** 分类编辑对话框（CategoryEditWindow 同位；@CustomDialog 默认模态=源 ShowDialog 分型） */
@CustomDialog
export struct CategoryEditDialog {
  controller?: CustomDialogController;
  /** 预填模型（新增=空模型；编辑=SetCategory :64-69 同位回填） */
  model: CategoryEditModel = new CategoryEditModel();
  /** 校验通过后的确认回调（FileTypes 原文交宿主 parseCategoryTypes——源宿主侧解析同构） */
  onConfirm: (categoryName: string, fileTypes: string, folder: string) => void =
    (categoryName: string, fileTypes: string, folder: string): void => {
    };
  onCancel: () => void = () => {
  };
  @State categoryName: string = '';
  @State fileTypes: string = '';
  @State folder: string = '';

  aboutToAppear(): void {
    this.categoryName = this.model.categoryName;
    this.fileTypes = this.model.fileTypes;
    this.folder = this.model.folder;
  }

  /** BtnOk_Click :84-102 校验链逐条：Name→FileTypes→Folder，不符弹提示不关窗 */
  private handleOk(): void {
    if (this.categoryName.length === 0) {
      this.showMsg($r('app.string.msg_cat_name_missing'));
      return;
    }
    if (this.fileTypes.length === 0) {
      this.showMsg($r('app.string.msg_cat_file_types_missing'));
      return;
    }
    if (this.folder.length === 0) {
      this.showMsg($r('app.string.msg_cat_folder_missing'));
      return;
    }
    this.onConfirm(this.categoryName, this.fileTypes, this.folder);
    this.controller?.close();
  }

  private handleCancel(): void {
    this.onCancel();
    this.controller?.close();
  }

  /** Browse 占位（FolderBrowserDialog 能力面 U5.2 接 picker，D5；当前 hilog 登记） */
  private handleBrowse(): void {
    hilog.info(0x0000, 'CategoryEdit', '%{public}s',
      'category folder browse placeholder (D5: U5.2 picker pending)');
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
      Text($r('app.string.settings_cat_name'))
        .fontSize(13)
        .width('100%')
      TextInput({ text: this.categoryName })
        .onChange((value: string) => {
          this.categoryName = value;
        })
        .width('100%')
      Text($r('app.string.settings_cat_types'))
        .fontSize(13)
        .width('100%')
      TextArea({ text: this.fileTypes })
        .height(72)
        .onChange((value: string) => {
          this.fileTypes = value;
        })
        .width('100%')
      Text($r('app.string.settings_cat_folder'))
        .fontSize(13)
        .width('100%')
      Row({ space: 8 }) {
        TextInput({ text: this.folder })
          .layoutWeight(1)
          .onChange((value: string) => {
            this.folder = value;
          })
        Button($r('app.string.btn_browse'))
          .fontSize(12)
          .height(32)
          .onClick(() => {
            this.handleBrowse();
          })
      }
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
    .width(420)
    .padding(16)
  }
}

@Component
export struct GeneralSettingsTab {
  /** 共享会话（SettingsPage 注入） */
  session: SettingsSession = new SettingsSession();
  /** 六 Toggle（PopulateUI :39-48 装载序） */
  @State showProgress: boolean = true;
  @State showComplete: boolean = true;
  @State startAuto: boolean = false;
  /** 勾=Overwrite=1（ChkOverwrite.IsChecked = FileConflictResolution==Overwrite :42） */
  @State overwriteExisting: boolean = false;
  @State darkTheme: boolean = true;
  /** 勾=Auto=0（ChkAutoCat.IsChecked = FolderSelectionMode==Auto :46——与上条方向相反） */
  @State autoCat: boolean = false;
  @State tempFolderText: string = '';
  @State downloadFolderText: string = '';
  /** 最大并发 Select 序号（值=序号+1，1..50） */
  @State maxParallelIndex: number = 2;
  /** 双击行为 Select 序号（0=打开文件夹/1=打开文件） */
  @State dblClickIndex: number = 0;
  /** 分类本地镜像（:29 ObservableCollection 同位；Save 时整块写回） */
  @State categories: CategoryDef[] = [];
  @State selectedCatIndex: number = -1;
  /** 分类对话框共享模型 + 控制器（宿主改模型后 open） */
  private categoryModel: CategoryEditModel = new CategoryEditModel();
  /** 确认回调模式：0=新增/1=编辑（编辑保留原 Name :103-105） */
  private categoryEditMode: number = 0;
  private categoryEditIndex: number = -1;
  private categoryDialogController: CustomDialogController = new CustomDialogController({
    width: 480,
    backgroundColor: $r('app.color.dialog_bg'),
    backgroundBlurStyle: BlurStyle.NONE,
    cornerRadius: 16,
    builder: CategoryEditDialog({
      model: this.categoryModel,
      onConfirm: (categoryName: string, fileTypes: string, folder: string): void => {
        this.onCategoryConfirmed(categoryName, fileTypes, folder);
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

  /** PopulateUI :37-55 同位 */
  populateUI(): void {
    const config: Config = Config.getInstance();
    this.showProgress = config.getShowProgressWindow();
    this.showComplete = config.getShowDownloadCompleteWindow();
    this.startAuto = config.getStartDownloadAutomatically();
    this.overwriteExisting = config.getFileConflictResolution() === 1;
    this.darkTheme = config.getAllowSystemDarkTheme();
    this.tempFolderText = config.getTempDir();
    this.maxParallelIndex = clampToRange(config.getMaxParallelDownloads(), RANGE_MIN,
      RANGE_MAX_PARALLEL) - RANGE_MIN;
    this.autoCat = config.getFolderSelectionMode() === 0;
    this.downloadFolderText = config.getDownloadDir();
    this.dblClickIndex = config.getDoubleClickOpenFile() ? 1 : 0;
    const cats: CategoryDef[] = config.getCategories();
    const mirror: CategoryDef[] = [];
    for (let i = 0; i < cats.length; i++) {
      mirror.push(cats[i]);
    }
    this.categories = mirror;
    this.selectedCatIndex = -1;
  }

  /** UpdateConfig :57-73 同位（TempDir/DefaultDownloadFolder=既有 tempDir/downloadDir 键） */
  updateConfig(): void {
    const config: Config = Config.getInstance();
    config.setShowProgressWindow(this.showProgress);
    config.setShowDownloadCompleteWindow(this.showComplete);
    config.setStartDownloadAutomatically(this.startAuto);
    // :62-63 勾=Overwrite(1)/不勾=AutoRename(0)——与 folderSelectionMode 的 0 值方向相反
    config.setFileConflictResolution(this.overwriteExisting ? 1 : 0);
    config.setTempDir(this.tempFolderText);
    config.setMaxParallelDownloads(clampToRange(this.maxParallelIndex + RANGE_MIN, RANGE_MIN,
      RANGE_MAX_PARALLEL));
    config.setCategories(this.categories);
    // :68-69 勾=Auto(0)/不勾=Manual(1)
    config.setFolderSelectionMode(this.autoCat ? 0 : 1);
    config.setDownloadDir(this.downloadFolderText);
    config.setAllowSystemDarkTheme(this.darkTheme);
    config.setDoubleClickOpenFile(this.dblClickIndex === 1);
  }

  private parallelOptions(): SelectOption[] {
    const options: SelectOption[] = [];
    for (let i = RANGE_MIN; i <= RANGE_MAX_PARALLEL; i++) {
      const option: SelectOption = { value: String(i) };
      options.push(option);
    }
    return options;
  }

  private dblClickOptions(): SelectOption[] {
    const options: SelectOption[] = [
      { value: $r('app.string.ctx_open_folder') },
      { value: $r('app.string.msg_open_file') }
    ];
    return options;
  }

  /** CatAdd_Click :75-90：空模型开对话框；确认后新 CategoryDef（Name=随机 UUID D10、
   * IsPredefined=false 源对象初始化器缺省同貌） */
  private handleCategoryAdd(): void {
    this.categoryModel.categoryName = '';
    this.categoryModel.fileTypes = '';
    this.categoryModel.folder = '';
    this.categoryEditMode = 0;
    this.categoryEditIndex = -1;
    this.categoryDialogController.open();
  }

  /** CatEdit_Click :92-113：SetCategory 同位回填（DisplayName/join(FileExtensions)/DefaultFolder） */
  private handleCategoryEdit(): void {
    const index: number = this.selectedCatIndex;
    if (index < 0 || index >= this.categories.length) {
      return;
    }
    const cat: CategoryDef = this.categories[index];
    this.categoryModel.categoryName = cat.displayName;
    this.categoryModel.fileTypes = joinForEdit(cat.fileExtensions);
    this.categoryModel.folder = cat.defaultFolderName;
    this.categoryEditMode = 1;
    this.categoryEditIndex = index;
    this.categoryDialogController.open();
  }

  /** 对话框确认回调（新增 :81-88 / 编辑 :103-110 两分支；FileTypes 宿主侧 parseCategoryTypes
   * =源 new HashSet<string>(...) 同构） */
  private onCategoryConfirmed(categoryName: string, fileTypes: string, folder: string): void {
    const types: string[] = parseCategoryTypes(fileTypes);
    if (this.categoryEditMode === 1 && this.categoryEditIndex >= 0 &&
      this.categoryEditIndex < this.categories.length) {
      const old: CategoryDef = this.categories[this.categoryEditIndex];
      const updated: CategoryDef = new CategoryDef(old.name, categoryName, types, folder,
        old.isPredefined);
      const mirror: CategoryDef[] = this.categories.slice();
      mirror[this.categoryEditIndex] = updated;
      this.categories = mirror;
      return;
    }
    const created: CategoryDef = new CategoryDef(util.generateRandomUUID(), categoryName, types,
      folder, false);
    const mirror: CategoryDef[] = this.categories.slice();
    mirror.push(created);
    this.categories = mirror;
  }

  /** CatDel_Click :115-122：按选中索引删 */
  private handleCategoryDelete(): void {
    const index: number = this.selectedCatIndex;
    if (index < 0 || index >= this.categories.length) {
      return;
    }
    const mirror: CategoryDef[] = this.categories.slice();
    mirror.splice(index, 1);
    this.categories = mirror;
    this.selectedCatIndex = -1;
  }

  /** CatDef_Click :124-135：清空后回填 Config.DefaultCategories（=DEFAULT_CATEGORIES 副本） */
  private handleCategoryDefaults(): void {
    const defaults: CategoryDef[] = [];
    for (let i = 0; i < DEFAULT_CATEGORIES.length; i++) {
      defaults.push(DEFAULT_CATEGORIES[i]);
    }
    this.categories = defaults;
    this.selectedCatIndex = -1;
  }

  /** 目录 Browse 占位（temp/category 维持占位——U5.2 D8：URI 不能作沙箱 tempDir/分类尾段目录，
   * 语义不兼容；hilog 登记原样） */
  private handleBrowsePlaceholder(kind: string): void {
    hilog.info(0x0000, 'GeneralSettings', '%{public}s',
      'folder browse placeholder kind=' + kind + ' (D8: URI incompatible with sandbox path keys)');
  }

  /** downloadDir Browse（U5.2 真实能力接线，拍板⑩/D4）：DocumentViewPicker 选目录→
   * applyPickedFolder 写拷贝目标三键（recentFolders/folderSelectionMode=Manual/
   * userSelectedDownloadFolder——Helpers.cs:318-320 三动作）→toast 视觉反馈。
   * 不回填 downloadFolderText、不调 setDownloadDir（Save 时 setDownloadDir(downloadFolderText)
   * 会把 URI 写进引擎目标键→破坏沙箱落盘，拍板①）。重启后需重选目录（D2 临时授权降级）。 */
  private handleBrowseDownload(): void {
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      return;
    }
    // ctx 已窄化非 undefined（handleMenuExit 同款 downcast 惯例）
    SaveDirectory.pickSaveFolder(ctx as common.UIAbilityContext).then((uri: string | null): void => {
      if (uri === null) {
        return;
      }
      SaveDirectory.applyPickedFolder(uri);
      const toastOpts: promptAction.ShowToastOptions = { message: $r('app.string.msg_folder_picked') };
      // showToast 在 PromptAction 类上（@ohos.arkui.UIContext.d.ts:987/:1015），UIContext 无
      // 此属性——经 getPromptAction() 取实例（设计书 §1-#15 原文即此调用形态）
      this.getUIContext().getPromptAction().showToast(toastOpts);
    }).catch((err: BusinessError): void => {
      hilog.error(0x0000, 'GeneralSettings', '%{public}s',
        'handleBrowseDownload threw errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
    });
  }

  build() {
    Scroll() {
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          Toggle({ type: ToggleType.Checkbox, isOn: this.showProgress })
            .onChange((value: boolean) => {
              this.showProgress = value;
            })
          Text($r('app.string.show_dwn_prg'))
            .fontSize(13)
            .layoutWeight(1)
        }
        .width('100%')

        Row({ space: 8 }) {
          Toggle({ type: ToggleType.Checkbox, isOn: this.showComplete })
            .onChange((value: boolean) => {
              this.showComplete = value;
            })
          Text($r('app.string.show_dwn_complete'))
            .fontSize(13)
            .layoutWeight(1)
        }
        .width('100%')

        Row({ space: 8 }) {
          Toggle({ type: ToggleType.Checkbox, isOn: this.startAuto })
            .onChange((value: boolean) => {
              this.startAuto = value;
            })
          Text($r('app.string.lbl_start_auto'))
            .fontSize(13)
            .layoutWeight(1)
        }
        .width('100%')

        Row({ space: 8 }) {
          Toggle({ type: ToggleType.Checkbox, isOn: this.overwriteExisting })
            .onChange((value: boolean) => {
              this.overwriteExisting = value;
            })
          Text($r('app.string.lbl_overwrite_existing'))
            .fontSize(13)
            .layoutWeight(1)
        }
        .width('100%')

        Row({ space: 8 }) {
          Text($r('app.string.msg_double_click_action'))
            .fontSize(13)
            .layoutWeight(1)
          Select(this.dblClickOptions())
            .selected(this.dblClickIndex)
            .value(this.dblClickIndex === 1 ? $r('app.string.msg_open_file')
              : $r('app.string.ctx_open_folder'))
            .onSelect((index: number, value: string) => {
              this.dblClickIndex = index;
            })
            .width(150)
        }
        .width('100%')

        Text($r('app.string.lbl_temp_folder'))
          .fontSize(13)
          .width('100%')
        Row({ space: 8 }) {
          TextInput({ text: this.tempFolderText })
            .layoutWeight(1)
            .onChange((value: string) => {
              this.tempFolderText = value;
            })
          Button($r('app.string.btn_browse'))
            .fontSize(12)
            .height(32)
            .onClick(() => {
              this.handleBrowsePlaceholder('temp');
            })
        }
        .width('100%')

        Text($r('app.string.settings_folder'))
          .fontSize(13)
          .width('100%')
        Row({ space: 8 }) {
          TextInput({ text: this.downloadFolderText })
            .layoutWeight(1)
            .onChange((value: string) => {
              this.downloadFolderText = value;
            })
          Button($r('app.string.btn_browse'))
            .fontSize(12)
            .height(32)
            .onClick(() => {
              this.handleBrowseDownload();
            })
        }
        .width('100%')

        Row({ space: 8 }) {
          Text($r('app.string.msg_max_download'))
            .fontSize(13)
            .layoutWeight(1)
          Select(this.parallelOptions())
            .selected(this.maxParallelIndex)
            .value(String(clampToRange(this.maxParallelIndex + RANGE_MIN, RANGE_MIN,
              RANGE_MAX_PARALLEL)))
            .onSelect((index: number, value: string) => {
              this.maxParallelIndex = index;
            })
            .width(100)
        }
        .width('100%')

        Row({ space: 8 }) {
          Toggle({ type: ToggleType.Checkbox, isOn: this.darkTheme })
            .onChange((value: boolean) => {
              this.darkTheme = value;
            })
          Text($r('app.string.settings_dark_theme'))
            .fontSize(13)
            .layoutWeight(1)
        }
        .width('100%')

        Row({ space: 8 }) {
          Toggle({ type: ToggleType.Checkbox, isOn: this.autoCat })
            .onChange((value: boolean) => {
              this.autoCat = value;
            })
          Text($r('app.string.settings_auto_cat'))
            .fontSize(13)
            .layoutWeight(1)
        }
        .width('100%')

        Text($r('app.string.settings_cat'))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .width('100%')

        List({ space: 2 }) {
          ForEach(this.categories, (cat: CategoryDef, index: number) => {
            ListItem() {
              Row({ space: 8 }) {
                Text(cat.displayName)
                  .fontSize(13)
                  .layoutWeight(2)
                  .maxLines(1)
                Text(joinForEdit(cat.fileExtensions))
                  .fontSize(12)
                  .opacity(0.7)
                  .layoutWeight(3)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(cat.defaultFolderName)
                  .fontSize(12)
                  .opacity(0.7)
                  .layoutWeight(2)
                  .maxLines(1)
              }
              .width('100%')
              .padding(8)
              .borderRadius(6)
              // OPT-1：选中/常态底资源化（字色维持不显式——深色选中底 #114C7B 上系统白字可读）
              .backgroundColor(index === this.selectedCatIndex
                ? $r('app.color.category_highlight') : $r('app.color.control_bg'))
              .onClick(() => {
                this.selectedCatIndex = index;
              })
            }
          // 键含可变内容（独立复核 medium 修复）：纯 name 键在编辑分类后不变→ArkUI ForEach 不重建
          // 子树，会话内显示名/扩展名/目录不刷新（持久化正确、重开页才回显）
          }, (cat: CategoryDef): string => cat.name + '/' + cat.displayName + '/' + String(cat.fileExtensions.length))
        }
        .width('100%')
        .height(180)
        .scrollBar(BarState.Auto)

        Row({ space: 8 }) {
          Blank()
          Button($r('app.string.settings_cat_add'))
            .fontSize(12)
            .height(30)
            .onClick(() => {
              this.handleCategoryAdd();
            })
          Button($r('app.string.settings_cat_edit'))
            .fontSize(12)
            .height(30)
            .onClick(() => {
              this.handleCategoryEdit();
            })
          Button($r('app.string.desc_del'))
            .fontSize(12)
            .height(30)
            .onClick(() => {
              this.handleCategoryDelete();
            })
          Button($r('app.string.desc_def'))
            .fontSize(12)
            .height(30)
            .onClick(() => {
              this.handleCategoryDefaults();
            })
        }
        .width('100%')
      }
      .width('100%')
      .padding(12)
    }
    .align(Alignment.Top)
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Auto)
  }
}
