/*
 * U4.3 监控设置页（设计书 §1-#7；对照 BrowserMonitoringView.xaml.cs，本会话逐行核对）。
 * ISettingsPage 同构：populateUI()（=源 ctor foreach PopulateUI 分散到 aboutToAppear）/
 * updateConfig()（SettingsSession 注册回调）/session 属性（SettingsPage 注入共享会话）。
 * 控件面（源 xaml 全清单减浏览器引导区，D7：六浏览器启动按钮+两 URL 复制+DESC_MONITORING_1
 * 等引导文案不渲染——MIGRATION_PLAN 降级清单 2/U6 分期；对应键 isBrowserMonitoringEnabled
 * 照源默认落库无 UI）：
 *   - TxtDefaultFileTypes/TxtDefaultVideoFormats/TxtExceptions 三 TextArea（joinForEdit 回显，
 *     :40-42 string.Join(",",...) 同貌）+三"默认"钮（BtnDefault1/2/3 :147-160 回填 Config.
 *     Default* join——DEFAULT_*_EXPORT 常量）
 *   - CmbMinVidSize 九档 Select（ctor :33 逐值）
 *   - ChkMonitorClipboard/ChkTimestamp/ChkShowMediaNotification 三 Toggle（:44-46）
 * 保存（UpdateConfig :52-58）：三列表 parseExtensionList（Split(',').Select(Trim).Where(len>0)
 * **不去重**，§3.2）；体积/三布尔同值写。
 * 红线：本文件不 import probe/**；零 [XDM_PROBE] 输出。
 */

import { Config, DEFAULT_FILE_EXTENSIONS, DEFAULT_VIDEO_EXTENSIONS, DEFAULT_BLOCKED_HOSTS }
  from '../../core/Config';
import { SettingsSession } from './SettingsSession';
import { joinForEdit, parseExtensionList, MIN_VIDEO_SIZE_CHOICES, clampToRange }
  from '../../core/util/SettingParse';

@Component
export struct MonitoringSettingsTab {
  /** 共享会话（SettingsPage 注入；Save 时 updateAll 依注册序回写） */
  session: SettingsSession = new SettingsSession();
  @State fileTypesText: string = '';
  @State videoTypesText: string = '';
  @State exceptionsText: string = '';
  /** 九档 Select 选中序号（值=MIN_VIDEO_SIZE_CHOICES[index] KB） */
  @State minVideoIndex: number = 3;
  @State monitorClipboard: boolean = false;
  @State fetchTimestamp: boolean = false;
  @State showMediaNotification: boolean = true;
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

  /** PopulateUI :36-47 同位（浏览器引导两 URL 行不渲染 D7） */
  populateUI(): void {
    const config: Config = Config.getInstance();
    this.fileTypesText = joinForEdit(config.getFileExtensions());
    this.videoTypesText = joinForEdit(config.getVideoExtensions());
    this.exceptionsText = joinForEdit(config.getBlockedHosts());
    this.minVideoIndex = this.indexOfMinVideoSize(config.getMinVideoSize());
    this.monitorClipboard = config.getMonitorClipboard();
    this.fetchTimestamp = config.getFetchServerTimeStamp();
    this.showMediaNotification = config.getShowNotification();
  }

  /** UpdateConfig :52-58 同位：三列表 parseExtensionList（不去重 §3.2）+体积+三布尔 */
  updateConfig(): void {
    const config: Config = Config.getInstance();
    config.setFileExtensions(parseExtensionList(this.fileTypesText));
    config.setVideoExtensions(parseExtensionList(this.videoTypesText));
    config.setBlockedHosts(parseExtensionList(this.exceptionsText));
    config.setMinVideoSize(MIN_VIDEO_SIZE_CHOICES[clampToRange(this.minVideoIndex, 0,
      MIN_VIDEO_SIZE_CHOICES.length - 1)]);
    config.setMonitorClipboard(this.monitorClipboard);
    config.setFetchServerTimeStamp(this.fetchTimestamp);
    config.setShowNotification(this.showMediaNotification);
  }

  /** 九档回显反查（越界/缺档钳到最近存在档——clampToRange 下拉回显防御） */
  private indexOfMinVideoSize(sizeKB: number): number {
    for (let i = 0; i < MIN_VIDEO_SIZE_CHOICES.length; i++) {
      if (MIN_VIDEO_SIZE_CHOICES[i] === sizeKB) {
        return i;
      }
    }
    return clampToRange(sizeKB, 0, MIN_VIDEO_SIZE_CHOICES.length - 1);
  }

  private sizeOptions(): SelectOption[] {
    const options: SelectOption[] = [];
    for (let i = 0; i < MIN_VIDEO_SIZE_CHOICES.length; i++) {
      const option: SelectOption = { value: String(MIN_VIDEO_SIZE_CHOICES[i]) };
      options.push(option);
    }
    return options;
  }

  /** BtnDefault1_Click :147-150 同位 */
  private handleDefaultFileTypes(): void {
    this.fileTypesText = joinForEdit(DEFAULT_FILE_EXTENSIONS);
  }

  /** BtnDefault2_Click :152-155 同位 */
  private handleDefaultVideoTypes(): void {
    this.videoTypesText = joinForEdit(DEFAULT_VIDEO_EXTENSIONS);
  }

  /** BtnDefault3_Click :157-160 同位 */
  private handleDefaultExceptions(): void {
    this.exceptionsText = joinForEdit(DEFAULT_BLOCKED_HOSTS);
  }

  build() {
    Scroll() {
      Column({ space: 10 }) {
        Text($r('app.string.desc_filetypes'))
          .fontSize(13)
          .width('100%')
        Row({ space: 8 }) {
          TextArea({ text: this.fileTypesText })
            .layoutWeight(1)
            .height(72)
            .onChange((value: string) => {
              this.fileTypesText = value;
            })
          Button($r('app.string.desc_def'))
            .fontSize(12)
            .height(32)
            .onClick(() => {
              this.handleDefaultFileTypes();
            })
        }
        .width('100%')

        Text($r('app.string.desc_videotypes'))
          .fontSize(13)
          .width('100%')
        Row({ space: 8 }) {
          TextArea({ text: this.videoTypesText })
            .layoutWeight(1)
            .height(72)
            .onChange((value: string) => {
              this.videoTypesText = value;
            })
          Button($r('app.string.desc_def'))
            .fontSize(12)
            .height(32)
            .onClick(() => {
              this.handleDefaultVideoTypes();
            })
        }
        .width('100%')

        Text($r('app.string.desc_siteexceptions'))
          .fontSize(13)
          .width('100%')
        Row({ space: 8 }) {
          TextArea({ text: this.exceptionsText })
            .layoutWeight(1)
            .height(72)
            .onChange((value: string) => {
              this.exceptionsText = value;
            })
          Button($r('app.string.desc_def'))
            .fontSize(12)
            .height(32)
            .onClick(() => {
              this.handleDefaultExceptions();
            })
        }
        .width('100%')

        Row({ space: 8 }) {
          Text($r('app.string.lbl_min_video_size'))
            .fontSize(13)
            .layoutWeight(1)
          Select(this.sizeOptions())
            .selected(this.minVideoIndex)
            .value(String(MIN_VIDEO_SIZE_CHOICES[clampToRange(this.minVideoIndex, 0,
              MIN_VIDEO_SIZE_CHOICES.length - 1)]))
            .onSelect((index: number, value: string) => {
              this.minVideoIndex = index;
            })
            .width(120)
        }
        .width('100%')

        Row({ space: 8 }) {
          Toggle({ type: ToggleType.Checkbox, isOn: this.monitorClipboard })
            .onChange((value: boolean) => {
              this.monitorClipboard = value;
            })
          Text($r('app.string.menu_clip_add'))
            .fontSize(13)
            .layoutWeight(1)
        }
        .width('100%')

        Row({ space: 8 }) {
          Toggle({ type: ToggleType.Checkbox, isOn: this.fetchTimestamp })
            .onChange((value: boolean) => {
              this.fetchTimestamp = value;
            })
          Text($r('app.string.lbl_get_timestamp'))
            .fontSize(13)
            .layoutWeight(1)
        }
        .width('100%')

        Row({ space: 8 }) {
          Toggle({ type: ToggleType.Checkbox, isOn: this.showMediaNotification })
            .onChange((value: boolean) => {
              this.showMediaNotification = value;
            })
          Text($r('app.string.lbl_show_finish_notification'))
            .fontSize(13)
            .layoutWeight(1)
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
