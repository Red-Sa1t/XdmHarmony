/*
 * U4.2 SpeedLimitView 纯函数 Hypium 本地用例（设计书 §7-[A] 用例清单，6 条）。
 * 被测模块零 @kit import（SpeedLimitView.ets），本地测试环境可直接 import（BatchAlgo.test.ets
 * 同口径）。保存投影两例在测试侧内联 Config.setSpeedLimit 规范化数学（SpeedLimiterUIController.cs:22-27
 * ——enabled ? speed>0 : false / speed>0 ? speed : 0）后经 speedLimitView 读回，锁定
 * "写→读"往返的闭环语义（Config 本体带 @kit，不入本地单测）。
 * 锁定目标（SpeedLimiterUIController.cs:12-16 Run 装载投影逐字）：
 *   - 开+正值：enabled=1、speedKBps=100（原值）；
 *   - 关+正值：enabled=0、speedKBps=50（禁用也回填原值——源 :13 第二行独立读取）；
 *   - 开+零：enabled=0（speed>0 门假）；
 *   - 开+负值：enabled=0（-5 不 >0）、speedKBps=-5（原值回填）；
 *   - 零速度保存归零投影：save(true,0)→存(0,0)→读回 0/0；
 *   - 负值保存归零投影：save(true,-5)→存(0,0)→读回 0/0。
 */

import { describe, it, expect } from '@ohos/hypium';
import { SpeedLimitView, speedLimitView } from '../main/ets/core/util/SpeedLimitView';

/** 保存投影（Config.setSpeedLimit 规范化数学内联——SpeedLimiterUIController.cs:22-27 逐字） */
function saveProjection(enabled: boolean, speed: number): SpeedLimitView {
  const storedEnabled: boolean = enabled ? speed > 0 : false;
  const storedSpeed: number = speed > 0 ? speed : 0;
  return speedLimitView(storedEnabled, storedSpeed);
}

export default function speedLimitViewTest(): void {
  describe('SpeedLimitView', () => {
    it('load_enabledPositive', 0, () => {
      // Run :12：EnableSpeedLimit=true 且 DefaltDownloadSpeed=100>0 → 勾选+原值
      const view = speedLimitView(true, 100);
      expect(view.enabled).assertTrue();
      expect(view.speedKBps).assertEqual(100);
    });

    it('load_disabledPositive_backfillsSpeed', 0, () => {
      // Run :12-13：EnableSpeedLimit=false → 勾选假；SpeedLimit=50 原值回填输入框
      const view = speedLimitView(false, 50);
      expect(view.enabled).assertFalse();
      expect(view.speedKBps).assertEqual(50);
    });

    it('load_enabledZero_notEnabled', 0, () => {
      // :12 speed>0 门假：开+零 → 勾选假、回填 0
      const view = speedLimitView(true, 0);
      expect(view.enabled).assertFalse();
      expect(view.speedKBps).assertEqual(0);
    });

    it('load_enabledNegative_notEnabled_backfillsOriginal', 0, () => {
      // :12 负值不 >0 → 勾选假；:13 原值回填（-5）
      const view = speedLimitView(true, -5);
      expect(view.enabled).assertFalse();
      expect(view.speedKBps).assertEqual(-5);
    });

    it('save_zeroSpeed_normalizesToZero', 0, () => {
      // OkClicked :22-27：save(true, 0) → 存 enabled=false/speed=0 → 装载读回 0/0
      const view = saveProjection(true, 0);
      expect(view.enabled).assertFalse();
      expect(view.speedKBps).assertEqual(0);
    });

    it('save_negativeSpeed_normalizesToZero', 0, () => {
      // :22-27：save(true, -5) → 存 enabled=false/speed=0（speed>0 ? speed : 0 归零）→ 读回 0/0
      const view = saveProjection(true, -5);
      expect(view.enabled).assertFalse();
      expect(view.speedKBps).assertEqual(0);
    });
  });
}
