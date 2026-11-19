/*
 * U4.3 SettingParse 纯函数 Hypium 本地用例（设计书 §7 用例清单，22 条）。
 * 被测模块零 @kit import（SettingParse.ets），本地测试环境可直接 import。
 * 锁定目标：
 *   - tryParseInt（Int32.TryParse 同貌 §3.3）：正/零/负/显式符号/字母/前缀字母/空串/小数/
 *     Int32 上界/上界+1 溢出；
 *   - parseExtensionList（BrowserMonitoringView.xaml.cs:52-52 **不去重**）：trim/去空/空串/
 *     全逗号/重复保留；
 *   - parseCategoryTypes（GeneralSettingsView.xaml.cs:86-87 HashSet 语义）：CRLF 删+去重保序/
 *     顺序保留/空串/混合换行/单元素三连去重；
 *   - joinForEdit/clampToRange：join 回填与下拉回显防御三例。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  tryParseInt,
  parseExtensionList,
  parseCategoryTypes,
  joinForEdit,
  clampToRange,
  MIN_VIDEO_SIZE_CHOICES
} from '../main/ets/core/util/SettingParse';

export default function settingParseTest(): void {
  describe('SettingParse', () => {
    // ── tryParseInt（10 条）──
    it('tryParseInt_plain', 0, () => {
      expect(tryParseInt('500')).assertEqual(500);
    });

    it('tryParseInt_zero', 0, () => {
      expect(tryParseInt('0')).assertEqual(0);
    });

    it('tryParseInt_negative', 0, () => {
      // Int32 NumberStyles.Integer 允许负号
      expect(tryParseInt('-5')).assertEqual(-5);
    });

    it('tryParseInt_plusSign', 0, () => {
      expect(tryParseInt('+7')).assertEqual(7);
    });

    it('tryParseInt_trailingLetter', 0, () => {
      expect(tryParseInt('12a')).assertNull();
    });

    it('tryParseInt_leadingLetter', 0, () => {
      expect(tryParseInt('a12')).assertNull();
    });

    it('tryParseInt_empty', 0, () => {
      expect(tryParseInt('')).assertNull();
    });

    it('tryParseInt_decimal', 0, () => {
      expect(tryParseInt('1.5')).assertNull();
    });

    it('tryParseInt_int32Max', 0, () => {
      expect(tryParseInt('2147483647')).assertEqual(2147483647);
    });

    it('tryParseInt_int32Overflow', 0, () => {
      // 2147483648 = Int32.MaxValue+1 → TryParse false 同貌
      expect(tryParseInt('2147483648')).assertNull();
    });

    // ── parseExtensionList（5 条）──
    it('parseExtensionList_trimAndDropEmpty', 0, () => {
      const parsed: string[] = parseExtensionList('MP4, WEBM ,,MP3');
      expect(parsed.length).assertEqual(3);
      expect(parsed[0]).assertEqual('MP4');
      expect(parsed[1]).assertEqual('WEBM');
      expect(parsed[2]).assertEqual('MP3');
    });

    it('parseExtensionList_empty', 0, () => {
      const parsed: string[] = parseExtensionList('');
      expect(parsed.length).assertEqual(0);
    });

    it('parseExtensionList_allCommas', 0, () => {
      const parsed: string[] = parseExtensionList(',,,');
      expect(parsed.length).assertEqual(0);
    });

    it('parseExtensionList_keepsDuplicates', 0, () => {
      // **不去重**锚（与 parseCategoryTypes HashSet 语义对照）
      const parsed: string[] = parseExtensionList('MP4,MP4');
      expect(parsed.length).assertEqual(2);
      expect(parsed[0]).assertEqual('MP4');
      expect(parsed[1]).assertEqual('MP4');
    });

    it('parseExtensionList_surroundingSpace', 0, () => {
      const parsed: string[] = parseExtensionList(' MP4 ');
      expect(parsed.length).assertEqual(1);
      expect(parsed[0]).assertEqual('MP4');
    });

    // ── parseCategoryTypes（5 条）──
    it('parseCategoryTypes_crlfDedupKeepOrder', 0, () => {
      // CRLF 删+trim+去重保序（设计书 §7-16 锚例）
      const parsed: string[] = parseCategoryTypes(' .MP4 ,.MP4,\r\n.MKV,,');
      expect(parsed.length).assertEqual(2);
      expect(parsed[0]).assertEqual('.MP4');
      expect(parsed[1]).assertEqual('.MKV');
    });

    it('parseCategoryTypes_orderPreserved', 0, () => {
      const parsed: string[] = parseCategoryTypes('.MP4,.MKV');
      expect(parsed.length).assertEqual(2);
      expect(parsed[0]).assertEqual('.MP4');
      expect(parsed[1]).assertEqual('.MKV');
    });

    it('parseCategoryTypes_empty', 0, () => {
      const parsed: string[] = parseCategoryTypes('');
      expect(parsed.length).assertEqual(0);
    });

    it('parseCategoryTypes_mixedNewlines', 0, () => {
      const parsed: string[] = parseCategoryTypes('.A,\n.B,,\r\n');
      expect(parsed.length).assertEqual(2);
      expect(parsed[0]).assertEqual('.A');
      expect(parsed[1]).assertEqual('.B');
    });

    it('parseCategoryTypes_singleDedup', 0, () => {
      const parsed: string[] = parseCategoryTypes('.A,.A,.A');
      expect(parsed.length).assertEqual(1);
      expect(parsed[0]).assertEqual('.A');
    });

    // ── joinForEdit/clampToRange（2 条）──
    it('joinForEdit_displayRoundTrip', 0, () => {
      const list: string[] = ['MP4', 'WEBM'];
      expect(joinForEdit(list)).assertEqual('MP4,WEBM');
      // 回填-解析往返（显示回填 joinForEdit 同貌）
      expect(joinForEdit(parseExtensionList('MP4,WEBM'))).assertEqual('MP4,WEBM');
    });

    it('clampToRange_bounds', 0, () => {
      expect(clampToRange(999, 1, 50)).assertEqual(50);
      expect(clampToRange(0, 1, 50)).assertEqual(1);
      expect(clampToRange(33, 1, 50)).assertEqual(33);
    });
  });
}
