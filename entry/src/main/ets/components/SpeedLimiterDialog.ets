/*
 * U4.2 限速窗内容组件（设计书 §3.2/§5.7；对照 SpeedLimiterUIController.cs:9-33 +
 * SpeedLimiter.xaml.cs 控件行为，本会话逐行核对）。
 * 打开形态：ComponentContent 动态窗（源 ShowWindow→this.Show() 非模态 →
 * uiContext.openCustomDialog(ComponentContent,{isModal:false})，宿主=ProgressWindowHost.openSpeedLimiter；
 * 全仓唯一触发点=进度窗限速文本点击，DownloadProgressWindow.xaml.cs:240-242——grep 核实
 * MainWindow 无菜单项）。
 * 装载（Run :12-16）：speedLimitView(Config.getEnableSpeedLimit(), Config.getDefaultDownloadSpeed())
 * ——enabled = enable ? speed>0 : false；speed 原值回填输入框（禁用也回填）。
 * 保存（OkClicked :19-33）：OK → Config.setSpeedLimit(enabled, speed)（U3.2 组合 setter 纯消费，
 * 规范化已在 setter 内）+ 立即关窗（源 OkClicked 退订防重复的等价简化，设计书 §3.2）；
 * ConfigChanged 广播由 Config.setSpeedLimit 内触发，进度窗限速文本刷新在监听器侧（host）。
 * 控件行为（SpeedLimiter.xaml.cs）：
 *   - ctor 默认文本 '0'（:17）
 *   - 整数过滤=onChange 剥离非数字字符（源 PreviewTextInput/Pasting 按键拦截，差异 #15 等价）
 *   - 勾选框控输入可用 .enabled(checked)（源 IsReadOnly=!checked :57-60，差异 #15）
 *   - onBlur：空/非整数→valid=false；ChkEnabled.IsChecked = valid（LostFocus :66-77 逐条——
 *     ArkTS 禁用输入不可获焦，onBlur 只来自勾选态，实际效果=失效自动取消勾选）
 *   - Cancel 仅关窗不写（BtnCancel_Click :39-42）
 * 红线：本文件 import 图禁 probe/**；零 [XDM_PROBE] 输出。
 */

import { Config } from '../core/Config';
import { speedLimitView } from '../core/util/SpeedLimitView';

/** 限速窗参数（关窗请求由 host 装配：closeCustomDialog(content)） */
export class SpeedLimiterParams {
  onRequestClose: () => void = () => {
  };
}

/** 限速窗 Builder（ComponentContent 造参入口） */
@Builder
export function speedLimiterDialogBuilder(params: SpeedLimiterParams) {
  SpeedLimiterDialogContent({ params: params })
}

@Component
export struct SpeedLimiterDialogContent {
  params: SpeedLimiterParams = new SpeedLimiterParams();
  /** 勾选态（IsSpeedLimitEnabled）——成员名 limitEnabled：`enabled` 与通用属性方法冲突
   *（CustomComponent.enabled:(value:boolean)=>CommonAttribute，hvigor 10505001） */
  @State limitEnabled: boolean = false;
  /** 输入框文本（ctor 默认 '0'，SpeedLimiter.xaml.cs:17） */
  @State speedText: string = '0';

  aboutToAppear(): void {
    // Run :12-16 装载投影（speedLimitView 纯函数，SpeedLimiterUIController.cs:12-13 同式）
    const view = speedLimitView(Config.getInstance().getEnableSpeedLimit(),
      Config.getInstance().getDefaultDownloadSpeed());
    this.limitEnabled = view.enabled;
    this.speedText = String(view.speedKBps);
  }

  /** 整数过滤（源按键拦截的 onChange 等价）：剥离非数字字符重写 */
  private handleSpeedChange(value: string): void {
    const filtered: string = value.replace(new RegExp('[^0-9]', 'g'), '');
    this.speedText = filtered;
  }

  /** 失焦校验（LostFocus :66-77）：空/非整数 → valid=false；勾选=valid */
  private handleSpeedBlur(): void {
    let valid: boolean = true;
    if (this.speedText.length === 0) {
      valid = false;
    }
    const parsed: number = Number(this.speedText);
    if (!Number.isFinite(parsed) || !Number.isInteger(parsed)) {
      valid = false;
    }
    this.limitEnabled = valid;
  }

  /** 解析输入（SpeedLimit getter :28-37 TryParse 失败=0） */
  private parsedSpeed(): number {
    const parsed: number = Number(this.speedText);
    if (this.speedText.length === 0 || !Number.isFinite(parsed) || !Number.isInteger(parsed)) {
      return 0;
    }
    return parsed;
  }

  /** OK（OkClicked :19-33）：组合 setter 纯消费 + 关窗；规范化（speed<=0 归 0/false）在 setter 内 */
  private handleOk(): void {
    Config.getInstance().setSpeedLimit(this.limitEnabled, this.parsedSpeed());
    this.params.onRequestClose();
  }

  /** Cancel（BtnCancel_Click :39-42）：仅关窗不写 */
  private handleCancel(): void {
    this.params.onRequestClose();
  }

  build() {
    Column({ space: 12 }) {
      Text($r('app.string.msg_speed_limit'))
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .width('100%')
      Row({ space: 8 }) {
        Toggle({ type: ToggleType.Checkbox, isOn: this.limitEnabled })
          .onChange((value: boolean) => {
            this.limitEnabled = value;
          })
        TextInput({ text: this.speedText })
          .enabled(this.limitEnabled)
          .layoutWeight(1)
          .onChange((value: string) => {
            this.handleSpeedChange(value);
          })
          .onBlur(() => {
            this.handleSpeedBlur();
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
    .width(360)
    .padding(20)
    .backgroundColor($r('app.color.dialog_bg'))
    .borderRadius(16)
    .shadow(ShadowStyle.OUTER_DEFAULT_LG)
  }
}
