/*
 * U4.3 网络设置页（设计书 §1-#9；对照 NetworkSettingsView.xaml.cs，本会话逐行核对）。
 * 控件面：CmbTimeOut(1..300)/CmbMaxSegments(1..64)/CmbMaxRetry(1..100) 三 Select（ctor :28-30）；
 * ChkEnableSpeedLimit Toggle + TxtMaxSpeedLimit 输入（限速三件套规则分立 §3.3 勿合并——
 *   ①输入过滤 :79-82 PreviewTextInput：仅数字可键入（onChange 对非数字字符回退）
 *   ②失焦重置 :100-115 LostFocus：空或 tryParseInt===null → 文本重置 "0"
 *   ③保存解析 :52-55 UpdateConfig：tryParseInt 失败不写 Config 保留旧值，无提示无重置）；
 * 代理区（:58-125）：CmbProxyType 三档 NET_SYSTEM_PROXY/ND_NO_PROXY/ND_MANUAL_PROXY（:90-92）、
 * 仅 index==2 启用 host/port/user/pass 四输入（:73-77 SelectionChanged）、
 * ND_SYSTEM_PROXY 按钮不渲染（D7 降级：PlatformHelper.OpenWindowsProxySettings 无对应物）。
 * 保存（UpdateConfig :47-66）：端口 Int32.TryParse 失败→0（:57 out port 缺省同貌）；
 * Proxy **无条件整块写回**（含全空，:58-65 构造即赋值同貌）；限速勾选 raw 写
 * EnableSpeedLimit（:56）——raw setter 语义（§0-8），不得走 setSpeedLimit。
 * 红线：本文件不 import probe/**；零 [XDM_PROBE] 输出。
 */

import { Config } from '../../core/Config';
import { SettingsSession } from './SettingsSession';
import { ProxyInfo } from '../../model/DownloadTypes';
import { clampToRange, tryParseInt, RANGE_MIN, RANGE_TIMEOUT, RANGE_SEGMENTS, RANGE_RETRY }
  from '../../core/util/SettingParse';

@Component
export struct NetworkSettingsTab {
  /** 共享会话（SettingsPage 注入） */
  session: SettingsSession = new SettingsSession();
  /** 三 Select 序号（值=序号+1） */
  @State timeoutIndex: number = 29;
  @State segmentsIndex: number = 7;
  @State retryIndex: number = 9;
  /** 限速输入文本（ctor 装载原值；①过滤②失焦重置③保存解析三规则分立） */
  @State speedLimitText: string = '0';
  @State enableSpeedLimit: boolean = false;
  /** 代理三档序号（0=System/1=Direct/2=Custom） */
  @State proxyTypeIndex: number = 0;
  @State proxyHostText: string = '';
  @State proxyPortText: string = '0';
  @State proxyUserText: string = '';
  @State proxyPasswordText: string = '';
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

  /** PopulateUI :33-45 同位（Proxy 单可空字段由平铺 5 键承载，null→type=0 D6） */
  populateUI(): void {
    const config: Config = Config.getInstance();
    this.timeoutIndex = clampToRange(config.getNetworkTimeout(), RANGE_MIN, RANGE_TIMEOUT) - RANGE_MIN;
    this.segmentsIndex = clampToRange(config.getMaxSegments(), RANGE_MIN, RANGE_SEGMENTS) - RANGE_MIN;
    this.retryIndex = clampToRange(config.getMaxRetry(), RANGE_MIN, RANGE_RETRY) - RANGE_MIN;
    this.speedLimitText = String(config.getDefaultDownloadSpeed());
    this.enableSpeedLimit = config.getEnableSpeedLimit();
    const proxy: ProxyInfo = config.getProxyInfo();
    this.proxyTypeIndex = clampToRange(proxy.proxyType, 0, 2);
    this.proxyHostText = proxy.host ?? '';
    this.proxyPortText = String(proxy.port);
    this.proxyUserText = proxy.userName ?? '';
    this.proxyPasswordText = proxy.password ?? '';
  }

  /** UpdateConfig :47-66 同位：三 Select 同值写；限速 ③保存解析（失败不写保留旧值）；
   * 勾选 raw 写；端口失败→0；Proxy 无条件整块写回 */
  updateConfig(): void {
    const config: Config = Config.getInstance();
    config.setNetworkTimeout(clampToRange(this.timeoutIndex + RANGE_MIN, RANGE_MIN, RANGE_TIMEOUT));
    config.setMaxSegments(clampToRange(this.segmentsIndex + RANGE_MIN, RANGE_MIN, RANGE_SEGMENTS));
    config.setMaxRetry(clampToRange(this.retryIndex + RANGE_MIN, RANGE_MIN, RANGE_RETRY));
    const speed: number | null = tryParseInt(this.speedLimitText);
    if (speed !== null) {
      // :52-55 TryParse 成功才写（raw——无 speed>0 规范化，§0-8）
      config.setDefaultDownloadSpeedRaw(speed);
    }
    config.setEnableSpeedLimitRaw(this.enableSpeedLimit);
    const port: number | null = tryParseInt(this.proxyPortText);
    const proxy: ProxyInfo = {
      proxyType: clampToRange(this.proxyTypeIndex, 0, 2),
      host: this.proxyHostText,
      port: port !== null ? port : 0,
      userName: this.proxyUserText,
      password: this.proxyPasswordText
    };
    config.setProxyInfo(proxy);
  }

  private rangeOptions(count: number): SelectOption[] {
    const options: SelectOption[] = [];
    for (let i = RANGE_MIN; i <= count; i++) {
      const option: SelectOption = { value: String(i) };
      options.push(option);
    }
    return options;
  }

  private proxyOptions(): SelectOption[] {
    const options: SelectOption[] = [
      { value: $r('app.string.net_system_proxy') },
      { value: $r('app.string.nd_no_proxy') },
      { value: $r('app.string.nd_manual_proxy') }
    ];
    return options;
  }

  /** ①输入过滤（:79-82 PreviewTextInput 的 onChange 等价）：非数字字符不进 state */
  private handleSpeedInput(value: string): void {
    this.speedLimitText = value.replace(new RegExp('[^0-9]', 'g'), '');
  }

  /** ②失焦重置（:100-115 LostFocus）：空或 tryParseInt===null → 文本重置 "0" */
  private handleSpeedBlur(): void {
    if (this.speedLimitText.length === 0 || tryParseInt(this.speedLimitText) === null) {
      this.speedLimitText = '0';
    }
  }

  build() {
    Scroll() {
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          Text($r('app.string.desc_net1'))
            .fontSize(13)
            .layoutWeight(1)
          Select(this.rangeOptions(RANGE_TIMEOUT))
            .selected(this.timeoutIndex)
            .value(String(clampToRange(this.timeoutIndex + RANGE_MIN, RANGE_MIN, RANGE_TIMEOUT)))
            .onSelect((index: number, value: string) => {
              this.timeoutIndex = index;
            })
            .width(100)
        }
        .width('100%')

        Row({ space: 8 }) {
          Text($r('app.string.desc_net2'))
            .fontSize(13)
            .layoutWeight(1)
          Select(this.rangeOptions(RANGE_SEGMENTS))
            .selected(this.segmentsIndex)
            .value(String(clampToRange(this.segmentsIndex + RANGE_MIN, RANGE_MIN, RANGE_SEGMENTS)))
            .onSelect((index: number, value: string) => {
              this.segmentsIndex = index;
            })
            .width(100)
        }
        .width('100%')

        Row({ space: 8 }) {
          Text($r('app.string.net_max_retry'))
            .fontSize(13)
            .layoutWeight(1)
          Select(this.rangeOptions(RANGE_RETRY))
            .selected(this.retryIndex)
            .value(String(clampToRange(this.retryIndex + RANGE_MIN, RANGE_MIN, RANGE_RETRY)))
            .onSelect((index: number, value: string) => {
              this.retryIndex = index;
            })
            .width(100)
        }
        .width('100%')

        Row({ space: 8 }) {
          Toggle({ type: ToggleType.Checkbox, isOn: this.enableSpeedLimit })
            .onChange((value: boolean) => {
              this.enableSpeedLimit = value;
            })
          Text($r('app.string.msg_speed_limit'))
            .fontSize(13)
            .layoutWeight(1)
          TextInput({ text: this.speedLimitText })
            .width(110)
            .onChange((value: string) => {
              this.handleSpeedInput(value);
            })
            .onBlur(() => {
              this.handleSpeedBlur();
            })
        }
        .width('100%')

        Text($r('app.string.desc_net4'))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .width('100%')

        Row({ space: 8 }) {
          Text($r('app.string.desc_host'))
            .fontSize(13)
            .width(90)
          Select(this.proxyOptions())
            .selected(this.proxyTypeIndex)
            .onSelect((index: number, value: string) => {
              this.proxyTypeIndex = index;
            })
            .layoutWeight(1)
        }
        .width('100%')

        Row({ space: 8 }) {
          Text($r('app.string.proxy_host'))
            .fontSize(13)
            .width(90)
          TextInput({ text: this.proxyHostText })
            .enabled(this.proxyTypeIndex === 2)
            .layoutWeight(1)
            .onChange((value: string) => {
              this.proxyHostText = value;
            })
        }
        .width('100%')

        Row({ space: 8 }) {
          Text($r('app.string.proxy_port'))
            .fontSize(13)
            .width(90)
          TextInput({ text: this.proxyPortText })
            .enabled(this.proxyTypeIndex === 2)
            .layoutWeight(1)
            .onChange((value: string) => {
              this.proxyPortText = value;
            })
        }
        .width('100%')

        Row({ space: 8 }) {
          Text($r('app.string.desc_net7'))
            .fontSize(13)
            .width(90)
          TextInput({ text: this.proxyUserText })
            .enabled(this.proxyTypeIndex === 2)
            .layoutWeight(1)
            .onChange((value: string) => {
              this.proxyUserText = value;
            })
        }
        .width('100%')

        Row({ space: 8 }) {
          Text($r('app.string.desc_net8'))
            .fontSize(13)
            .width(90)
          TextInput({ text: this.proxyPasswordText })
            .type(InputType.Password)
            .enabled(this.proxyTypeIndex === 2)
            .layoutWeight(1)
            .onChange((value: string) => {
              this.proxyPasswordText = value;
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
