/* U7.1 parseXsDuration Hypium 用例（设计书 u7-1-dash-DESIGN.md §6 DashUtil 行逐条）。
 * 被测 DashUtil.ets 零 @kit，本地直接加载。DashUtil.cs:8-40 直译面：源测试向量
 * PT0H10M54.00S→654000（DashSanityTest.cs:27-31）、负前缀、年/月/日系数（30.4368/365.242 天）、
 * 复合小数、IgnoreCase、fallback 按小时解释、宽松秒组/空串 throw（.NET FormatException 同效）。
 * ArkTS 红线：无 any/解构/正则字面量；显式返回类型。 */

import { describe, it, expect } from '@ohos/hypium';
import { parseXsDuration } from '../main/ets/core/adaptive/DashUtil';

function expectThrows(call: () => void): void {
  let thrown: boolean = false;
  try {
    call();
  } catch (e) {
    thrown = true;
  }
  expect(thrown).assertTrue();
}

export default function dashUtilTest(): void {
  describe('dashUtilTest', (): void => {
    it('sourceVectorPt0h10m54', 0, (): void => {
      expect(parseXsDuration('PT0H10M54.00S')).assertEqual(654000);
    });
    it('negativePrefixOnlyGroupOne', 0, (): void => {
      expect(parseXsDuration('-PT30S')).assertEqual(-30000);
    });
    it('zeroDuration', 0, (): void => {
      expect(parseXsDuration('PT0S')).assertEqual(0);
    });
    it('yearCoefficient365242Days', 0, (): void => {
      expect(parseXsDuration('P1Y')).assertEqual(31556908000);
    });
    it('monthCoefficient304368Days', 0, (): void => {
      expect(parseXsDuration('P2M')).assertEqual(5259478000);
    });
    it('dayCoefficient', 0, (): void => {
      expect(parseXsDuration('P3D')).assertEqual(259200000);
    });
    it('compositeWithFractionSeconds', 0, (): void => {
      expect(parseXsDuration('PT4H5M6.5S')).assertEqual(14706500);
    });
    it('ignoreCase', 0, (): void => {
      expect(parseXsDuration('pt1h')).assertEqual(3600000);
    });
    it('fallbackWholeHoursZero', 0, (): void => {
      expect(parseXsDuration('0')).assertEqual(0);
    });
    it('fallbackHoursFraction', 0, (): void => {
      expect(parseXsDuration('1.5')).assertEqual(5400000);
    });
    it('looseSecondsShapeThrows', 0, (): void => {
      // [0-9.]* 命中 "1.2.3" → .NET Double.Parse FormatException 同效（设计书 §4.1）
      expectThrows((): void => { parseXsDuration('PT1.2.3S'); });
    });
    it('emptyValueThrows', 0, (): void => {
      expectThrows((): void => { parseXsDuration(''); });
    });
  });
}
