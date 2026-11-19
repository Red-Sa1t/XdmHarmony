/*
 * U4.3 语言对话框（设计书 §1-#13；对照 LanguageSettingsWindow.xaml.cs，本会话逐行核对）。
 * 形态：@CustomDialog（源 ShowDialog 同位；由 Index 汉堡菜单 menu_lang 打开——源
 * MainWindow ctxMainMenu MENU_LANG 项同位）。源 25 语言下拉（index.txt 逐行装载）→ 三选项
 * （资源面只有中英两套，D1）：lang_follow_system→'default'/lang_chinese→'zh-Hans'/
 * lang_english→'en-US'；初选=Config.getLanguage() 反查（源 ctor :50-53 selection 同位；
 * 未知名→无选中 SelectedIndex<0 同貌）。
 * OK（BtnOk_Click :76-85 同位+D2 改进）：i18n.System.setAppPreferredLanguage(tag) →
 * Config.setLanguage(tag) → 关窗（即时生效——源改语言需重启 MSG_LANG2，本版 MSG_LANG2 不渲染）；
 * setAppPreferredLanguage 抛 BusinessError（401/890001）→ catch 记日志：不写键不关窗
 * （设计书 §3.4）。'default' 运行期切回跟随系统的生效时机由探针 S4 观测。
 * 红线：本文件不 import probe/**；零 [XDM_PROBE] 输出。
 */

import { i18n } from '@kit.LocalizationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Config } from '../core/Config';

/** 三选项落库 tag（序=选项序；language 键存 i18n tag，D1） */
const LANGUAGE_TAGS: string[] = ['default', 'zh-Hans', 'en-US'];

@CustomDialog
export struct LanguageDialog {
  controller?: CustomDialogController;
  onCancel: () => void = () => {
  };
  /** 语言已切换（宿主刷新 getStringSync 缓存的标签：状态列、进度窗等） */
  onApplied: () => void = () => {
  };
  @State selectedIndex: number = -1;

  aboutToAppear(): void {
    this.selectedIndex = this.indexOfLanguage(Config.getInstance().getLanguage());
  }

  /** ctor :50-53 反查同貌；未知值→-1（源 selection 缺省=无选中同貌） */
  private indexOfLanguage(tag: string): number {
    for (let i = 0; i < LANGUAGE_TAGS.length; i++) {
      if (LANGUAGE_TAGS[i] === tag) {
        return i;
      }
    }
    return -1;
  }

  private languageOptions(): SelectOption[] {
    const options: SelectOption[] = [
      { value: $r('app.string.lang_follow_system') },
      { value: $r('app.string.lang_chinese') },
      { value: $r('app.string.lang_english') }
    ];
    return options;
  }

  /** Text shown in the closed Select (ArkUI shows nothing without value). */
  private labelOf(index: number): ResourceStr {
    if (index === 0) { return $r('app.string.lang_follow_system'); }
    if (index === 1) { return $r('app.string.lang_chinese'); }
    if (index === 2) { return $r('app.string.lang_english'); }
    return '';
  }

  /** BtnOk_Click :76-85：选中有效才动作；即时生效（D2） */
  private handleOk(): void {
    if (this.selectedIndex < 0 || this.selectedIndex >= LANGUAGE_TAGS.length) {
      return;
    }
    const tag: string = LANGUAGE_TAGS[this.selectedIndex];
    try {
      i18n.System.setAppPreferredLanguage(tag);
    } catch (e) {
      const err = e as BusinessError;
      // 失败不写键不关窗（设计书 §3.4：890001 等错误 catch 后保持对话框）
      hilog.error(0x0000, 'LanguageDialog', '%{public}s',
        'setAppPreferredLanguage failed tag=' + tag + ' errCode=' + String(err.code) +
        ' errMessage=' + (err.message ?? ''));
      return;
    }
    Config.getInstance().setLanguage(tag);
    this.onApplied();
    this.controller?.close();
  }

  private handleCancel(): void {
    this.onCancel();
    this.controller?.close();
  }

  build() {
    Column({ space: 12 }) {
      Text($r('app.string.msg_lang1'))
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .width('100%')
      Select(this.languageOptions())
        .selected(this.selectedIndex)
        .value(this.labelOf(this.selectedIndex))
        .onSelect((index: number, value: string) => {
          this.selectedIndex = index;
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
