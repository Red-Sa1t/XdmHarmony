/*
 * U3.2 SpeedLimiter 纯函数 Hypium 本地用例（设计书 §7-[A]-2 用例清单，13 条）。
 * 被测模块零 @kit import（SpeedLimiter.ets），本地测试环境可直接 import（QueueAlgo.test.ets
 * 同口径）。
 * 锁定目标（SpeedLimiter.cs:46-82 数学逐字铁律）：
 *   - speedLimit<1 早退（0/0.5——不触碰基线）；
 *   - 首调（lastBytes==0||lastTick==0）只初始化基线返回 0；
 *   - 亚毫秒窗口（actualTimeSpent<1）返回 0 且**不推进基线**（:62 语义——并入下次测量）；
 *   - 仅 actualTimeSpent < expectedTimeSpent（严格 <）才睡——恰好等于不睡；
 *   - Math.ceil 取整（:73 (int)Math.Ceiling 逐字）；
 *   - diff 可负（负欠速不睡）且基线无条件先推进（:65-66）；
 *   - perWorkerLimitKBps 均摊四例（D1：单段全额/8 段均摊/分数份额/防御钳 0→全额）。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  ThrottleState,
  computeThrottleSleepMs,
  perWorkerLimitKBps
} from '../main/ets/core/engine/SpeedLimiter';

export default function speedLimitTest(): void {
  describe('SpeedLimiter', () => {
    it('throttle_limitZero_returnsZero', 0, () => {
      // :49 speedLimit<1 早退——0=不限速（GetGlobalSpeedLimit 双门全假等价值）
      const state: ThrottleState = new ThrottleState();
      expect(computeThrottleSleepMs(state, 0, 4096, 1000)).assertEqual(0);
      // 早退不触碰基线（后续有效调用仍按首调处理）
      expect(state.lastTick).assertEqual(0);
      expect(state.lastBytes).assertEqual(0);
    });

    it('throttle_limitBelowOne_returnsZero', 0, () => {
      // :49 同判覆盖分数限值（0.5<1）——派发侧 share 理论下界的防御面
      const state: ThrottleState = new ThrottleState();
      expect(computeThrottleSleepMs(state, 0.5, 4096, 1000)).assertEqual(0);
      expect(state.lastTick).assertEqual(0);
    });

    it('throttle_firstCall_initializesBaseline', 0, () => {
      // :50-54 首调只初始化基线（lastBytes/lastTick 均自 0 起）并返回 0
      const state: ThrottleState = new ThrottleState();
      expect(computeThrottleSleepMs(state, 1024, 5120, 2000)).assertEqual(0);
      expect(state.lastBytes).assertEqual(5120);
      expect(state.lastTick).assertEqual(2000);
    });

    it('throttle_subMillisecond_returnsZero_baselineIntact', 0, () => {
      // :62 亚毫秒窗口：同 now 二调返回 0 且基线不推进（增量并入下次测量）
      const state: ThrottleState = new ThrottleState();
      computeThrottleSleepMs(state, 1, 1024, 1000);      // 首调基线 (1024,1000)
      expect(computeThrottleSleepMs(state, 1, 2048, 1000)).assertEqual(0);
      expect(state.lastBytes).assertEqual(1024);          // 基线未动
      expect(state.lastTick).assertEqual(1000);
      // 下次有效窗口按原基线合并结算：diff=3072-1024=2048B，1KB/s → expected=2048/1.024=2000ms，
      // actual=1000 → ceil(1000)=1000（亚毫秒窗口的 1024B 增量并入本次测量）
      expect(computeThrottleSleepMs(state, 1, 3072, 2000)).assertEqual(1000);
      expect(state.lastBytes).assertEqual(3072);
      expect(state.lastTick).assertEqual(2000);
    });

    it('throttle_underLimit_noSleep', 0, () => {
      // 欠速不睡：1024B 用时 5000ms（1KB/s 预期 1000ms）——actual > expected
      // （R2-F1：基线调用 nowMs 必须 ≠0，否则 lastTick===0 命中 :52 哨兵重建分支）
      const state: ThrottleState = new ThrottleState();
      computeThrottleSleepMs(state, 1, 1024, 1000);
      expect(computeThrottleSleepMs(state, 1, 2048, 6000)).assertEqual(0);
    });

    it('throttle_overLimit_sleepCeiling', 0, () => {
      // 超速 Math.Ceiling：1024B 用时 100ms（1KB/s → maxBytesPerMS=1.024，expected=1000）
      // → ceil(1000-100)=900（:73 逐字）（R2-F1：基线 nowMs=1000 非 0，测量点后移至 1100）
      const state: ThrottleState = new ThrottleState();
      computeThrottleSleepMs(state, 1, 1024, 1000);
      expect(computeThrottleSleepMs(state, 1, 2048, 1100)).assertEqual(900);
      expect(state.lastBytes).assertEqual(2048);
      expect(state.lastTick).assertEqual(1100);
    });

    it('throttle_exactLimit_noSleep', 0, () => {
      // 恰好等于不睡（严格 <）：1000KB/s → maxBytesPerMS=1024，diff=1024B → expected=1ms，
      // actual=1ms → 1<1 为假（R2-F1：基线 nowMs=1000，actual=1001-1000=1 真正行使边界）
      const state: ThrottleState = new ThrottleState();
      computeThrottleSleepMs(state, 1000, 1024, 1000);
      expect(computeThrottleSleepMs(state, 1000, 2048, 1001)).assertEqual(0);
    });

    it('throttle_negativeDiff_noSleep_baselineAdvances', 0, () => {
      // diff 可负（测量基准回落）：bytesNow<lastBytes → expected<0，actual≥1 恒不小于 → 不睡；
      // 基线无条件先推进（:65-66）——后续调用自新基线结算（R2-F1：基线 nowMs=1000 非 0）
      const state: ThrottleState = new ThrottleState();
      computeThrottleSleepMs(state, 1, 2000, 1000);
      expect(computeThrottleSleepMs(state, 1, 1000, 1100)).assertEqual(0);
      expect(state.lastBytes).assertEqual(1000);   // 已推进
      expect(state.lastTick).assertEqual(1100);
      // 自新基线：diff=1000-1000=0 → expected=0，actual=200 → 0 不睡
      expect(computeThrottleSleepMs(state, 1, 1000, 1300)).assertEqual(0);
      // 自新基线超速：diff=1024 → expected=1000，actual=1400-1300=100 → 900
      expect(computeThrottleSleepMs(state, 1, 2024, 1400)).assertEqual(900);
    });

    it('throttle_baselineAdvancesEachCall', 0, () => {
      // 每次有效调用推进基线（欠速链）：三调后基线=末次 (bytes,now)（R2-F1：基线 nowMs=1000 非 0）
      const state: ThrottleState = new ThrottleState();
      computeThrottleSleepMs(state, 1, 1024, 1000);
      expect(computeThrottleSleepMs(state, 1, 1100, 2000)).assertEqual(0);
      expect(computeThrottleSleepMs(state, 1, 1200, 3000)).assertEqual(0);
      expect(computeThrottleSleepMs(state, 1, 1300, 4000)).assertEqual(0);
      expect(state.lastBytes).assertEqual(1300);
      expect(state.lastTick).assertEqual(4000);
    });

    it('perWorker_singleSegment_fullLimit', 0, () => {
      // D1 单分段（maxSegments=1）= 全额 limit——与源码 per-download 共享语义逐字等价点
      expect(perWorkerLimitKBps(1024, 1)).assertEqual(1024);
      expect(perWorkerLimitKBps(0, 1)).assertEqual(0);
    });

    it('perWorker_splitByMaxSegments', 0, () => {
      // D1 均摊：8 段并发各得 1/8，聚合恒 ≤ limit（保守方向）
      expect(perWorkerLimitKBps(1024, 8)).assertEqual(128);
      expect(perWorkerLimitKBps(800, 8)).assertEqual(100);
    });

    it('perWorker_fractionalShare', 0, () => {
      // 分数份额：100/8=12.5（number 直传不取整——限速数学内 maxBytesPerMS 承载分数精度）
      expect(perWorkerLimitKBps(100, 8)).assertEqual(12.5);
    });

    it('perWorker_defensiveClamp', 0, () => {
      // 防御钳：maxSegments<1 归全额（effectiveMaxParallel 同族；Config 值恒>=1，兜底面）
      expect(perWorkerLimitKBps(1024, 0)).assertEqual(1024);
      expect(perWorkerLimitKBps(1024, -3)).assertEqual(1024);
    });
  });
}
