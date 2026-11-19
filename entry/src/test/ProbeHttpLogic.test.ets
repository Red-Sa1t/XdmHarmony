/*
 * U0.2 探针纯函数 Hypium 本地用例（设计书 §7-[A]-3 用例清单）。
 * 被测模块零 @kit import，本地测试环境可直接 import。
 * 诚实注记：工程模板未携带 entry/src/test/、本机 devecocli 无 test 子命令、hvigor wrapper 不在工程内——
 * 本地单测执行命令在本设计会话无法验证；用例照常入库（assembleHap 不编译 src/test，不影响编译门禁），
 * 由编码员在 IDE/hvigor 侧实跑一次并记录；若 LocalUnit 任务在 SDK 6.1.1 不可用，注明"用例已入库待 U2.3 统一回归"。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  BIG_BIN_BYTES,
  ContentRangeParts,
  EchoFields,
  RangeWindow,
  headerOf,
  parseContentRange,
  splitRangeWindows,
  parseEchoBody,
  isTimeoutCode
} from '../main/ets/probe/units/ProbeHttpLogic';

export default function probeHttpLogicTest(): void {
  describe('ProbeHttpLogic', () => {
    it('splitRangeWindows_evenSplit_4MiB_8', 0, () => {
      const windows: RangeWindow[] = splitRangeWindows(BIG_BIN_BYTES, 8);
      expect(windows.length).assertEqual(8);
      expect(windows[0].start).assertEqual(0);
      expect(windows[0].end).assertEqual(524287);
      expect(windows[7].start).assertEqual(3670016);
      expect(windows[7].end).assertEqual(4194303);
      for (let i = 0; i < windows.length; i++) {
        expect(windows[i].end - windows[i].start + 1).assertEqual(524288);
      }
    });

    it('splitRangeWindows_uneven_10_3_lastWindowAbsorbsRemainder', 0, () => {
      const windows: RangeWindow[] = splitRangeWindows(10, 3);
      expect(windows.length).assertEqual(3);
      expect(windows[0].start).assertEqual(0);
      expect(windows[0].end).assertEqual(2);
      expect(windows[1].start).assertEqual(3);
      expect(windows[1].end).assertEqual(5);
      expect(windows[2].start).assertEqual(6);
      expect(windows[2].end).assertEqual(9);
    });

    it('splitRangeWindows_singlePart_100_1', 0, () => {
      const windows: RangeWindow[] = splitRangeWindows(100, 1);
      expect(windows.length).assertEqual(1);
      expect(windows[0].start).assertEqual(0);
      expect(windows[0].end).assertEqual(99);
    });

    it('splitRangeWindows_winLessThanOne_4_8_returnsEmpty', 0, () => {
      const windows: RangeWindow[] = splitRangeWindows(4, 8);
      expect(windows.length).assertEqual(0);
    });

    it('parseContentRange_standard', 0, () => {
      const parts: ContentRangeParts = parseContentRange('bytes 0-4194303/4194304');
      expect(parts.start).assertEqual(0);
      expect(parts.end).assertEqual(4194303);
      expect(parts.total).assertEqual(4194304);
    });

    it('parseContentRange_unspecifiedRange_returnsTotal', 0, () => {
      const parts: ContentRangeParts = parseContentRange('bytes */123');
      expect(parts.start).assertEqual(-1);
      expect(parts.end).assertEqual(-1);
      expect(parts.total).assertEqual(123);
    });

    it('parseContentRange_missingSlash_returnsAllMinusOne', 0, () => {
      const parts: ContentRangeParts = parseContentRange('bytes 0-');
      expect(parts.start).assertEqual(-1);
      expect(parts.end).assertEqual(-1);
      expect(parts.total).assertEqual(-1);
    });

    it('parseContentRange_garbage_returnsAllMinusOne', 0, () => {
      const parts: ContentRangeParts = parseContentRange('garbage');
      expect(parts.start).assertEqual(-1);
      expect(parts.end).assertEqual(-1);
      expect(parts.total).assertEqual(-1);
    });

    it('parseEchoBody_valueWithEqualsKept', 0, () => {
      const fields: EchoFields =
        parseEchoBody('url=http://h/final cookie=XDMProbeCookie=1 acceptEncoding=identity');
      expect(fields.url).assertEqual('http://h/final');
      expect(fields.cookie).assertEqual('XDMProbeCookie=1');
      expect(fields.acceptEncoding).assertEqual('identity');
    });

    it('parseEchoBody_partialTokens_missingAreEmpty', 0, () => {
      const fields: EchoFields = parseEchoBody('acceptEncoding=identity');
      expect(fields.url).assertEqual('');
      expect(fields.cookie).assertEqual('');
      expect(fields.acceptEncoding).assertEqual('identity');
    });

    it('parseEchoBody_emptyBody_returnsAllEmpty', 0, () => {
      const fields: EchoFields = parseEchoBody('');
      expect(fields.url).assertEqual('');
      expect(fields.cookie).assertEqual('');
      expect(fields.acceptEncoding).assertEqual('');
    });

    it('headerOf_lowercaseKeyHit', 0, () => {
      const headers: Record<string, string> = {};
      headers['content-type'] = 'text/plain';
      expect(headerOf(headers, 'content-type')).assertEqual('text/plain');
    });

    it('headerOf_caseInsensitiveHit', 0, () => {
      const headers: Record<string, string> = {};
      headers['Content-Range'] = 'bytes 0-524287/4194304';
      expect(headerOf(headers, 'content-range')).assertEqual('bytes 0-524287/4194304');
    });

    it('headerOf_missReturnsEmpty', 0, () => {
      const headers: Record<string, string> = {};
      headers['Content-Length'] = '1024';
      expect(headerOf(headers, 'content-range')).assertEqual('');
    });

    it('isTimeoutCode_2300028_true', 0, () => {
      expect(isTimeoutCode(2300028)).assertEqual(true);
    });

    it('isTimeoutCode_2300007_false', 0, () => {
      expect(isTimeoutCode(2300007)).assertEqual(false);
    });
  });
}
