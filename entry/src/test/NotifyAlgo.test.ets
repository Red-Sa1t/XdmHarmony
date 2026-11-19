/*
 * U5.1 NotifyAlgo 纯函数 Hypium 本地用例（设计书 §7 用例清单，12 条）。
 * 被测模块零 @kit import（core/notify/NotifyAlgo.ets），本地测试环境可直接 import。
 * 锁定目标：
 *   - clampProgress 钳位边界/中值（浮点透传）；
 *   - finishedSize 回退正路/负路（Application.cs:126 1:1，含非正数回退）；
 *   - shouldApplyTask/shouldReleaseTask 跃迁与守卫（申请/释放判定不重叠）；
 *   - shouldPublishFinish 门控（D6 锚：只门完成通知）；
 *   - pickFinishNotificationId 撞号避让（§0-10）；
 *   - 常量值。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  clampProgress,
  finishedSize,
  shouldApplyTask,
  shouldReleaseTask,
  shouldPublishFinish,
  pickFinishNotificationId,
  FINISH_NOTIFY_ID_BASE,
  PROGRESS_MIN,
  PROGRESS_MAX
} from '../main/ets/core/notify/NotifyAlgo';

export default function notifyAlgoTest(): void {
  describe('NotifyAlgo', () => {
    // ── 1 clampProgress 边界 ──
    it('clampProgress_bounds', 0, () => {
      expect(clampProgress(-1)).assertEqual(0);
      expect(clampProgress(0)).assertEqual(0);
      expect(clampProgress(100)).assertEqual(100);
      expect(clampProgress(101)).assertEqual(100);
    });

    // ── 2 clampProgress 中值（浮点透传，模板端自渲染） ──
    it('clampProgress_midpoint', 0, () => {
      expect(clampProgress(37.5)).assertEqual(37.5);
    });

    // ── 3 finishedSize 回退正路（recorded>0 优先，Application.cs:126） ──
    it('finishedSize_recordedWins', 0, () => {
      expect(finishedSize(1048576, 1000)).assertEqual(1048576);
    });

    // ── 4 finishedSize 回退负路（回退规则含非正数） ──
    it('finishedSize_fallsBack', 0, () => {
      expect(finishedSize(0, 999)).assertEqual(999);
      expect(finishedSize(-1, 999)).assertEqual(999);
    });

    // ── 5 shouldApplyTask 跃迁（0→非 0 申请锚） ──
    it('shouldApplyTask_transition', 0, () => {
      expect(shouldApplyTask(1, false)).assertTrue();
      expect(shouldApplyTask(3, false)).assertTrue();
    });

    // ── 6 shouldApplyTask 幂等（不空申请） ──
    it('shouldApplyTask_guard', 0, () => {
      expect(shouldApplyTask(2, true)).assertFalse();
      expect(shouldApplyTask(0, false)).assertFalse();
    });

    // ── 7 shouldReleaseTask 跃迁（归零释放锚） ──
    it('shouldReleaseTask_transition', 0, () => {
      expect(shouldReleaseTask(0, true)).assertTrue();
    });

    // ── 8 shouldReleaseTask 守卫（未申请不释放） ──
    it('shouldReleaseTask_guard', 0, () => {
      expect(shouldReleaseTask(2, true)).assertFalse();
      expect(shouldReleaseTask(0, false)).assertFalse();
    });

    // ── 9 shouldPublishFinish 门控（D6 锚） ──
    it('shouldPublishFinish_gate', 0, () => {
      expect(shouldPublishFinish(true)).assertTrue();
      expect(shouldPublishFinish(false)).assertFalse();
    });

    // ── 10 pickFinishNotificationId 撞号避让 ──
    it('pickFinishNotificationId_avoidance', 0, () => {
      expect(pickFinishNotificationId(7)).assertEqual(1001);
      expect(pickFinishNotificationId(1001)).assertEqual(1002);
      expect(pickFinishNotificationId(1002)).assertEqual(1001);
    });

    // ── 11 常量值 ──
    it('constants_values', 0, () => {
      expect(FINISH_NOTIFY_ID_BASE).assertEqual(1001);
      expect(PROGRESS_MIN).assertEqual(0);
      expect(PROGRESS_MAX).assertEqual(100);
    });

    // ── 12 边界组合（同帧互斥——申请/释放判定不重叠） ──
    it('applyRelease_disjoint', 0, () => {
      expect(shouldApplyTask(1, true)).assertFalse();
      expect(shouldReleaseTask(1, false)).assertFalse();
    });
  });
}
