/*
 * U4.3 设置页 NavDestination 内容（设计书 §1-#12；对照 SettingsWindow.xaml + .xaml.cs，
 * 本会话逐行核对）。非 @Entry——Index 汉堡菜单 pushPathByName('settings', initialTab) 挂载。
 * 布局：Tabs(barPosition: Start) 五页签（xaml :24-38 ListBox 项序=源 pages 数组序：
 * 监控 settings_monitoring/常规 settings_general/网络 settings_network/凭据 settings_cred/
 * 高级 settings_adv）+ 底部 Save(desc_save_q :21 BtnOK)/Cancel(nd_cancel :22 BtnCancel)。
 * 五页共享一个 SettingsSession（每页 aboutToAppear 注册=源 ctor foreach PopulateUI 的分散化；
 * TabContent 全量构造序=声明序=源 pages 数组序）。
 * Save 链（BtnOK_Click :68-78 逐行）：
 *   ①session.updateAll()（foreach page.UpdateConfig() 同位）
 *   ②主题即时应用 setColorMode(allowSystemDarkTheme?NOT_SET:LIGHT)（D2 改进——源主题仅启动期
 *     一次性；faqs-arkui-1266 运行期语义）
 *   ③Config.broadcastConfigChange()（ApplicationContext.cs:109-112 BroadcastConfigChange 同位；
 *     广播一次，各页 setter 不自行广播）
 *   ④pathStack.pop()（Close() 同位；Helpers.RunGC() 不移植 D9）
 * Cancel（:80-83）：零写入直接 pop。
 * 初始页签：源 SettingsWindow() :49 this(1) 默认常规——SETTINGS_TAB_GENERAL=1；
 * ShowBrowserMonitoringDialog 开 0（SETTINGS_TAB_MONITORING）。
 * 红线：本文件不 import probe/**；零 [XDM_PROBE] 输出。
 */

import { ConfigurationConstant } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Config } from '../core/Config';
import { SettingsSession } from '../components/settings/SettingsSession';
import { MonitoringSettingsTab } from '../components/settings/MonitoringSettingsTab';
import { GeneralSettingsTab } from '../components/settings/GeneralSettingsTab';
import { NetworkSettingsTab } from '../components/settings/NetworkSettingsTab';
import { CredentialSettingsTab } from '../components/settings/CredentialSettingsTab';
import { AdvancedSettingsTab } from '../components/settings/AdvancedSettingsTab';

/** 页签序常量（源 xaml ListBox 项序；Index 菜单接线消费） */
export const SETTINGS_TAB_MONITORING: number = 0;
export const SETTINGS_TAB_GENERAL: number = 1;

@Component
export struct SettingsPage {
  /** 初始页签（pushPathByName 参数；默认 1=常规，源 SettingsWindow() :49 this(1) 同貌） */
  initialTab: number = SETTINGS_TAB_GENERAL;
  /** 宿主 Navigation 路由栈（Index 注入；pop=源 Close() 同位） */
  pathStack: NavPathStack = new NavPathStack();
  @State currentTab: number = SETTINGS_TAB_GENERAL;
  /** 五页共享会话（updateAll 依注册序=页构造序回写） */
  private session: SettingsSession = new SettingsSession();

  aboutToAppear(): void {
    this.currentTab = this.initialTab;
  }

  /** BtnOK_Click :68-78 四步链（逐行注释见文件头） */
  private handleSave(): void {
    this.session.updateAll();
    this.applyThemeNow();
    Config.getInstance().broadcastConfigChange();
    this.pathStack.pop();
  }

  /** D2 主题即时应用（源无此步；faqs-arkui-1266 setColorMode 运行期语义） */
  private applyThemeNow(): void {
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      return;
    }
    try {
      ctx.getApplicationContext().setColorMode(Config.getInstance().getAllowSystemDarkTheme()
        ? ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET
        : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, 'SettingsPage', '%{public}s',
        'applyThemeNow failed errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
    }
  }

  /** BtnCancel_Click :80-83：零写入直接关 */
  private handleCancel(): void {
    this.pathStack.pop();
  }

  build() {
    Column() {
      Tabs({ index: this.currentTab, barPosition: BarPosition.Start }) {
        TabContent() {
          MonitoringSettingsTab({ session: this.session })
        }
        .tabBar($r('app.string.settings_monitoring'))

        TabContent() {
          GeneralSettingsTab({ session: this.session })
        }
        .tabBar($r('app.string.settings_general'))

        TabContent() {
          NetworkSettingsTab({ session: this.session })
        }
        .tabBar($r('app.string.settings_network'))

        TabContent() {
          CredentialSettingsTab({ session: this.session })
        }
        .tabBar($r('app.string.settings_cred'))

        TabContent() {
          AdvancedSettingsTab({ session: this.session })
        }
        .tabBar($r('app.string.settings_adv'))
      }
      .onChange((index: number) => {
        this.currentTab = index;
      })
      .width('100%')
      .layoutWeight(1)

      Row({ space: 12 }) {
        Blank()
        Button($r('app.string.desc_save_q'))
          .fontSize(13)
          .height(34)
          .onClick(() => {
            this.handleSave();
          })
        Button($r('app.string.nd_cancel'))
          .fontSize(13)
          .height(34)
          .onClick(() => {
            this.handleCancel();
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 12 })
    }
    .width('100%')
    .height('100%')
  }
}
