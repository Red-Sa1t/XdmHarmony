/*
 * U3.2 ScheduleAlgo 纯函数 Hypium 本地用例（设计书 §7-[A]-2 用例清单，13 条）。
 * 被测模块零 @kit import（ScheduleAlgo.ets），本地测试环境可直接 import（QueueAlgo.test.ets
 * 同口径）。
 * 锁定目标（Scheduler.cs 逐字语义）：
 *   - scheduledBoundary 次序铁律：end 先判先 return（:58-63）——start==end 恒 END（§0-9 探针
 *     S3 依赖：start 分支永不触达）；start 后判（:65-82）；邻分钟不触发（60s 采样漏分钟=源同
 *     行为不补偿，D9）；
 *   - matchesDay HasFlag 逐字（:105-107 (d1&d2)==d2）：位存在/位缺失/None 永不匹配（:92-98
 *     匹配链首即假）；
 *   - weekDayBitOf 位值表直译（DownloadSchedule.cs:17-20 Sun=1..Sat=64，jsDayOfWeek 0=周日
 *     同基）；非法入参→0；
 *   - minutesOfDay 边界（0:00→0 / 23:59→1439，D7 分钟数存储值域）。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  minutesOfDay,
  weekDayBitOf,
  matchesDay,
  scheduledBoundary,
  BOUNDARY_NONE,
  BOUNDARY_END,
  BOUNDARY_START
} from '../main/ets/core/engine/ScheduleAlgo';

export default function scheduleAlgoTest(): void {
  describe('ScheduleAlgo', () => {
    it('boundary_noMatch_returnsNone', 0, () => {
      // 该分钟既非 end 也非 start → NONE（onTick 无动作）
      expect(scheduledBoundary(100, 200, 300)).assertEqual(BOUNDARY_NONE);
      expect(scheduledBoundary(199, 200, 300)).assertEqual(BOUNDARY_NONE);
      expect(scheduledBoundary(301, 200, 300)).assertEqual(BOUNDARY_NONE);
    });

    it('boundary_endExact_returnsEnd', 0, () => {
      // end 精确相等 → END（StopDownloads 分支）
      expect(scheduledBoundary(300, 200, 300)).assertEqual(BOUNDARY_END);
      expect(BOUNDARY_END).assertEqual(1);
    });

    it('boundary_endCheckedBeforeStart', 0, () => {
      // 次序铁律：start==end → END（:58-63 end 先判先 return——start 分支永不触达）
      expect(scheduledBoundary(300, 300, 300)).assertEqual(BOUNDARY_END);
      expect(scheduledBoundary(0, 0, 0)).assertEqual(BOUNDARY_END);
    });

    it('boundary_startExact_returnsStart', 0, () => {
      // start 精确相等且 ≠end → START（ResumeDownload 分支）
      expect(scheduledBoundary(200, 200, 300)).assertEqual(BOUNDARY_START);
      expect(BOUNDARY_START).assertEqual(2);
    });

    it('boundary_startOtherMinute_none', 0, () => {
      // 邻分钟不触发（比较粒度=分钟精确相等；60s 采样漏分钟=源同行为，D9）
      expect(scheduledBoundary(201, 200, 300)).assertEqual(BOUNDARY_NONE);
      expect(scheduledBoundary(199, 200, 300)).assertEqual(BOUNDARY_NONE);
    });

    it('matchesDay_bitPresent', 0, () => {
      // HasFlag 逐字：掩码含该位 → true（127=全周）
      expect(matchesDay(127, 2)).assertTrue();
      expect(matchesDay(127, 1)).assertTrue();
      expect(matchesDay(127, 64)).assertTrue();
      expect(matchesDay(2, 2)).assertTrue();
    });

    it('matchesDay_bitAbsent', 0, () => {
      // 掩码缺该位 → false（1=仅周日，周一位 2 缺失）
      expect(matchesDay(1, 2)).assertFalse();
      expect(matchesDay(64, 2)).assertFalse();
      expect(matchesDay(85, 2)).assertFalse();   // 85=1010101b（日/二/四/六），周一位 2 缺失
    });

    it('matchesDay_noneNeverMatches', 0, () => {
      // Days==None（0）永不触发（:92-98 匹配链首即假——0&bit=0≠bit）
      expect(matchesDay(0, 1)).assertFalse();
      expect(matchesDay(0, 64)).assertFalse();
      expect(matchesDay(0, 0)).assertTrue();     // 位值 0 的退化位（无实际星期对应，数学面锁定）
    });

    it('weekBit_sunday', 0, () => {
      // jsDayOfWeek 0=周日 → 1（WeekDays.Sun=1）
      expect(weekDayBitOf(0)).assertEqual(1);
    });

    it('weekBit_monday', 0, () => {
      // 1=周一 → 2（WeekDays.Mon=2）
      expect(weekDayBitOf(1)).assertEqual(2);
    });

    it('weekBit_saturday', 0, () => {
      // 6=周六 → 64（WeekDays.Sat=64）
      expect(weekDayBitOf(6)).assertEqual(64);
      // 位值表全列（1<<d：1,2,4,8,16,32,64）
      expect(weekDayBitOf(2)).assertEqual(4);
      expect(weekDayBitOf(3)).assertEqual(8);
      expect(weekDayBitOf(4)).assertEqual(16);
      expect(weekDayBitOf(5)).assertEqual(32);
    });

    it('weekBit_invalidZero', 0, () => {
      // 非法入参（>6 或 <0）→ 0（None 语义恒不匹配）
      expect(weekDayBitOf(7)).assertEqual(0);
      expect(weekDayBitOf(-1)).assertEqual(0);
    });

    it('minutesOfDay_edges', 0, () => {
      // 值域边界：0:00→0 / 23:59→1439（D7 分钟数存储 0..1439）
      expect(minutesOfDay(0, 0)).assertEqual(0);
      expect(minutesOfDay(23, 59)).assertEqual(1439);
      expect(minutesOfDay(12, 34)).assertEqual(754);
      // 越界防御钳 0（纯函数面兜底）
      expect(minutesOfDay(24, 0)).assertEqual(0);
      expect(minutesOfDay(0, 60)).assertEqual(0);
    });
  });
}
