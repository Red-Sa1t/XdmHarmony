/*
 * U4.3 高级设置页（设计书 §1-#11；对照 AdvancedSettingsView.xaml.cs，本会话逐行核对）。
 * 降级隐藏（D7，MIGRATION_PLAN 降级清单 5/6/9 + U6 分期）：关机(msg_halt)/唤醒(msg_awake)/
 * 自定义命令(exec_cmd)/杀毒(exe_anti_vir/antivir_cmd/antivir_args)/自启(auto_start) 五组控件
 * 不渲染——RunOnLogon 不落键（源 ConfigIO :202/:373 亦注释禁用）；对应 Config 键照源默认保留。
 * 仅剩 UA：TxtDefaultUserAgent TextInput + BtnUserAgentReset（:73-76 立即写
 * Config.Instance.FallbackUserAgent=Config.cs:52 原串 DEFAULT_FALLBACK_USER_AGENT——R2-F1 修复：
 * state 回填与 Config 写入同步，Reset→Cancel 后重开显示默认 UA 与源一致；差异登记 §4-D14）。
 * 保存（UpdateConfig :49-61）：UA 写 fallbackUserAgent（D3 set 即持久化）；五组隐藏键照
 * populate 装载的 state 原值幂等回写（源隐藏控件仍参与 UpdateConfig 同构——未被修改=无害写）。
 * 红线：本文件不 import probe/**；零 [XDM_PROBE] 输出。
 */

import { Config, DEFAULT_FALLBACK_USER_AGENT } from '../../core/Config';
import { SettingsSession } from './SettingsSession';

@Component
export struct AdvancedSettingsTab {
  /** 共享会话（SettingsPage 注入） */
  session: SettingsSession = new SettingsSession();
  @State fallbackUserAgentText: string = DEFAULT_FALLBACK_USER_AGENT;
  /** 五组隐藏键镜像（populate 自 Config 装载、无控件可改；Save 照原值幂等回写） */
  @State haltState: boolean = false;
  @State keepAwakeState: boolean = true;
  @State runCmdState: boolean = false;
  @State antiVirusState: boolean = false;
  @State customCmdState: string = '';
  @State antiVirusCmdState: string = '';
  @State antiVirusArgsState: string = '';
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

  /** PopulateUI :35-47 同位（五组隐藏控件装载值保留为 state；自启 ChkAutoRun 不装载不回写） */
  populateUI(): void {
    const config: Config = Config.getInstance();
    this.fallbackUserAgentText = config.getFallbackUserAgent();
    this.haltState = config.getShutdownAfterAllFinished();
    this.keepAwakeState = config.getKeepPCAwake();
    this.runCmdState = config.getRunCommandAfterCompletion();
    this.antiVirusState = config.getScanWithAntiVirus();
    this.customCmdState = config.getAfterCompletionCommand();
    this.antiVirusCmdState = config.getAntiVirusExecutable();
    this.antiVirusArgsState = config.getAntiVirusArgs();
  }

  /** UpdateConfig :49-60 同位（EnableAutoStart 行不移植——RunOnLogon 不落键，注记 6） */
  updateConfig(): void {
    const config: Config = Config.getInstance();
    config.setShutdownAfterAllFinished(this.haltState);
    config.setKeepPCAwake(this.keepAwakeState);
    config.setRunCommandAfterCompletion(this.runCmdState);
    config.setScanWithAntiVirus(this.antiVirusState);
    config.setAfterCompletionCommand(this.customCmdState);
    config.setAntiVirusExecutable(this.antiVirusCmdState);
    config.setAntiVirusArgs(this.antiVirusArgsState);
    config.setFallbackUserAgent(this.fallbackUserAgentText);
  }

  /** BtnUserAgentReset_Click :73-76 同位：立即写 Config.Instance.FallbackUserAgent（源不关窗、
   * 文本框另行回填=R2-F1 修复——此前仅回填 state 致 Reset→Cancel→重开显示旧值的可观测偏差）；
   * 鸿蒙 set 即持久化 vs 源仅写内存（SaveConfig 在 OK）的细微差=设计书 §4-D14 登记 */
  private handleResetUserAgent(): void {
    this.fallbackUserAgentText = DEFAULT_FALLBACK_USER_AGENT;
    Config.getInstance().setFallbackUserAgent(DEFAULT_FALLBACK_USER_AGENT);
  }

  build() {
    Scroll() {
      Column({ space: 10 }) {
        Text($r('app.string.msg_fallback_ua'))
          .fontSize(13)
          .width('100%')
        Row({ space: 8 }) {
          TextInput({ text: this.fallbackUserAgentText })
            .layoutWeight(1)
            .onChange((value: string) => {
              this.fallbackUserAgentText = value;
            })
          Button($r('app.string.desc_def'))
            .fontSize(12)
            .height(32)
            .onClick(() => {
              this.handleResetUserAgent();
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
