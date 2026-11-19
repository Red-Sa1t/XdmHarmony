/*
 * U4.2 限速窗装载规范化纯函数（设计书 §2.5/§3.2/§5.2）。
 * 零 import（含 @kit）——Hypium 本地单测（entry/src/test）可直接加载本模块。
 * 对照源码锚（XDM.Core/UI/SpeedLimiterUIController.cs Run :12-16，本会话逐行核对）：
 *   var speedLimitEnabled = Config.Instance.EnableSpeedLimit
 *       ? Config.Instance.DefaltDownloadSpeed > 0 : false;
 *   var defaultSpeedLimit = Config.Instance.DefaltDownloadSpeed;
 *   → 装载投影：enabled = enableConfig ? speedConfig > 0 : false；speedKBps = speedConfig
 *     （禁用时 speed 原值回填输入框——保存侧再由 Config.setSpeedLimit 规范化，U3.2 组合 setter）。
 * 消费方：SpeedLimiterDialog 装载（本单元）+ 进度窗限速文本（DownloadProgressWindow.xaml.cs:177-186
 *   SetSpeedLimitText 同式：enable && limit>0 → 'SPEED_LIMIT_TITLE - {limit}K/S'，否则 MSG_NO_SPEED_LIMIT）。
 * ArkTS 合规：零 import、class 字段显式默认、显式返回类型、无对象字面量。
 */

/** 限速窗装载投影（enabled=勾选态；speedKBps=输入框回填值，禁用也回填原值） */
export class SpeedLimitView {
  enabled: boolean = false;
  speedKBps: number = 0;
}

/** 装载规范化（SpeedLimiterUIController.cs:12-13 同式）：纯函数，无 Config 依赖 */
export function speedLimitView(enableConfig: boolean, speedConfig: number): SpeedLimitView {
  const view: SpeedLimitView = new SpeedLimitView();
  view.enabled = enableConfig ? speedConfig > 0 : false;
  view.speedKBps = speedConfig;
  return view;
}
