/*
 * U4.2 BatchAlgo 纯函数 Hypium 本地用例（设计书 §7-[A] 用例清单，13 条）。
 * 被测模块零 @kit import（BatchAlgo.ets），本地测试环境可直接 import（SpeedLimit.test.ets
 * 同口径）。isUriValid 以内联纯函数注入（HttpProtocol.isUriValid 同语义最小集——scheme
 * http/https + host 非空；测试侧不 import 业务网络层，保持零依赖直载）。
 * 锁定目标（BatchDownloadUIController.cs:105-159 逐行 + 设计书 §3.1 差异点）：
 *   - letter A-C 逐串比对 3 条（A/B/C 边界+串相等）；
 *   - no-asterisk / reversed / letterMissing 三空场景（[] 语义）；
 *   - digit 1-3 串比对；
 *   - 补零 D3 串比对（padDigits C# D 格式）；
 *   - 负数补零 -001/000/001（负号外置铁律——JS padStart 会产出 '0-5'，差异点锁定）；
 *   - 两星号全量替换（C# string.Replace 语义——split/join 非 replace，差异点锁定）；
 *   - 非法 URL → null（all-or-nothing）；
 *   - 预览四链（first/second/last/size）；
 *   - 预览单链（second/last 空 size=1）。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  BatchParams,
  generateBatchLinks,
  computeBatchPreview,
  padDigits
} from '../main/ets/core/util/BatchAlgo';

/** 测试侧 URI 判定（HttpProtocol.isUriValid 同语义最小集：scheme 白名单+host 非空） */
function uriOk(url: string): boolean {
  const schemeEnd: number = url.indexOf('://');
  if (schemeEnd <= 0) {
    return false;
  }
  const scheme: string = url.slice(0, schemeEnd).toLowerCase();
  if (scheme !== 'http' && scheme !== 'https') {
    return false;
  }
  const rest: string = url.slice(schemeEnd + 3);
  const hostPart: string = rest.split('/')[0];
  return hostPart.length > 0;
}

/** 字母模式参数（http://probe.local/file*.bin 基准模板） */
function letterParams(start: string, end: string): BatchParams {
  const params: BatchParams = new BatchParams();
  params.url = 'http://probe.local/file*.bin';
  params.isLetterMode = true;
  params.startLetter = start;
  params.endLetter = end;
  return params;
}

/** 数字模式参数 */
function digitParams(start: number, end: number, pad: boolean, padCount: number): BatchParams {
  const params: BatchParams = new BatchParams();
  params.url = 'http://probe.local/file*.bin';
  params.isLetterMode = false;
  params.startNumber = start;
  params.endNumber = end;
  params.useLeadingZero = pad;
  params.leadingZeroCount = padCount;
  return params;
}

export default function batchAlgoTest(): void {
  describe('BatchAlgo', () => {
    it('letterAC_firstLink_exact', 0, () => {
      // :135-139 循环首项：url.Replace('*', 'A') → fileA.bin
      const links: string[] | null = generateBatchLinks(letterParams('A', 'C'), uriOk);
      // hypium 1.0.25 Assert 面无 assertNotNull——谓词等价断言（PieceAlgo.test.ets:372 同款，COLD-F1）
      expect(links === null).assertEqual(false);
      if (links !== null) {
        expect(links.length).assertEqual(3);
        expect(links[0]).assertEqual('http://probe.local/fileA.bin');
      }
    });

    it('letterAC_middleLink_exact', 0, () => {
      // 中项 B（charCodeAt 递进遍历）
      const links: string[] | null = generateBatchLinks(letterParams('A', 'C'), uriOk);
      if (links !== null) {
        expect(links[1]).assertEqual('http://probe.local/fileB.bin');
      }
    });

    it('letterAC_lastLink_exact', 0, () => {
      // 末项 C（i <= endChar 闭区间）
      const links: string[] | null = generateBatchLinks(letterParams('A', 'C'), uriOk);
      if (links !== null) {
        expect(links[2]).assertEqual('http://probe.local/fileC.bin');
      }
    });

    it('noAsterisk_returnsEmpty', 0, () => {
      // :107 无 '*' → Enumerable.Empty → []（非 null——与非法 URL 的 null 双语义分离）
      const params: BatchParams = new BatchParams();
      params.url = 'http://probe.local/file.bin';
      params.isLetterMode = true;
      params.startLetter = 'A';
      params.endLetter = 'C';
      const links: string[] | null = generateBatchLinks(params, uriOk);
      // hypium 1.0.25 Assert 面无 assertNotNull——谓词等价断言（PieceAlgo.test.ets:372 同款，COLD-F1）
      expect(links === null).assertEqual(false);
      if (links !== null) {
        expect(links.length).assertEqual(0);
      }
    });

    it('letterReversed_returnsEmpty', 0, () => {
      // :128-132 startChar >= endChar → 空表
      const links: string[] | null = generateBatchLinks(letterParams('C', 'A'), uriOk);
      // hypium 1.0.25 Assert 面无 assertNotNull——谓词等价断言（PieceAlgo.test.ets:372 同款，COLD-F1）
      expect(links === null).assertEqual(false);
      if (links !== null) {
        expect(links.length).assertEqual(0);
      }
    });

    it('letterMissing_returnsEmpty', 0, () => {
      // :124 ArgumentException → 外层 catch 空（设计书 §3.1 拍板取 []）
      const params: BatchParams = new BatchParams();
      params.url = 'http://probe.local/file*.bin';
      params.isLetterMode = true;
      params.startLetter = '';
      params.endLetter = 'C';
      const links: string[] | null = generateBatchLinks(params, uriOk);
      // hypium 1.0.25 Assert 面无 assertNotNull——谓词等价断言（PieceAlgo.test.ets:372 同款，COLD-F1）
      expect(links === null).assertEqual(false);
      if (links !== null) {
        expect(links.length).assertEqual(0);
      }
    });

    it('digit123_linksExact', 0, () => {
      // :150-157 数字模式 1-3（无补零）
      const links: string[] | null = generateBatchLinks(digitParams(1, 3, false, 0), uriOk);
      // hypium 1.0.25 Assert 面无 assertNotNull——谓词等价断言（PieceAlgo.test.ets:372 同款，COLD-F1）
      expect(links === null).assertEqual(false);
      if (links !== null) {
        expect(links.length).assertEqual(3);
        expect(links[0]).assertEqual('http://probe.local/file1.bin');
        expect(links[1]).assertEqual('http://probe.local/file2.bin');
        expect(links[2]).assertEqual('http://probe.local/file3.bin');
      }
    });

    it('digitPad_linksExact', 0, () => {
      // :152-154 D3 格式：001/002/003
      const links: string[] | null = generateBatchLinks(digitParams(1, 3, true, 3), uriOk);
      // hypium 1.0.25 Assert 面无 assertNotNull——谓词等价断言（PieceAlgo.test.ets:372 同款，COLD-F1）
      expect(links === null).assertEqual(false);
      if (links !== null) {
        expect(links[0]).assertEqual('http://probe.local/file001.bin');
        expect(links[1]).assertEqual('http://probe.local/file002.bin');
        expect(links[2]).assertEqual('http://probe.local/file003.bin');
      }
    });

    it('digitNegativePad_signOutside', 0, () => {
      // C# (-1).ToString('D3')='-005' 族：负号不占位（JS padStart 会产出 '0-5'——差异点锁定）
      expect(padDigits(-5, 3)).assertEqual('-005');
      expect(padDigits(5, 3)).assertEqual('005');
      expect(padDigits(0, 3)).assertEqual('000');
      // 区间 -1..1 D3 全链
      const links: string[] | null = generateBatchLinks(digitParams(-1, 1, true, 3), uriOk);
      // hypium 1.0.25 Assert 面无 assertNotNull——谓词等价断言（PieceAlgo.test.ets:372 同款，COLD-F1）
      expect(links === null).assertEqual(false);
      if (links !== null) {
        expect(links.length).assertEqual(3);
        expect(links[0]).assertEqual('http://probe.local/file-001.bin');
        expect(links[1]).assertEqual('http://probe.local/file000.bin');
        expect(links[2]).assertEqual('http://probe.local/file001.bin');
      }
    });

    it('twoStars_replacesAllOccurrences', 0, () => {
      // C# string.Replace('*', x) 换全部出现（split/join 全量替换；JS replace 只换首个——差异点锁定）。
      // 严格区间 start<end（BatchAlgo :73-75 start>=end 空）最少生成 2 条——取 'A'..'B' 触达
      // 替换路径，两链各两处 '*' 同换一份字母即证全量替换
      const params: BatchParams = new BatchParams();
      params.url = 'http://probe.local/a*b*c.bin';
      params.isLetterMode = true;
      params.startLetter = 'A';
      params.endLetter = 'B';
      const links: string[] | null = generateBatchLinks(params, uriOk);
      // hypium 1.0.25 Assert 面无 assertNotNull——谓词等价断言（PieceAlgo.test.ets:372 同款，COLD-F1）
      expect(links === null).assertEqual(false);
      if (links !== null) {
        expect(links.length).assertEqual(2);
        expect(links[0]).assertEqual('http://probe.local/aAbAc.bin');
        expect(links[1]).assertEqual('http://probe.local/aBbBc.bin');
      }
    });

    it('invalidUrl_returnsNull', 0, () => {
      // new Uri 抛 UriFormatException → null（all-or-nothing；预览路径 MSG_INVALID_URL 分流）
      const params: BatchParams = new BatchParams();
      params.url = 'not-a-scheme/*.bin';
      params.isLetterMode = true;
      params.startLetter = 'A';
      params.endLetter = 'B';
      const links: string[] | null = generateBatchLinks(params, uriOk);
      expect(links).assertNull();
    });

    it('preview_fourLinks_fields', 0, () => {
      // OnBatchPatternChange :72-93：first/second/last/size 四链
      const links: string[] | null = generateBatchLinks(letterParams('A', 'D'), uriOk);
      const urls: string[] = links !== null ? links : [];
      const preview = computeBatchPreview(urls);
      expect(preview.first).assertEqual('http://probe.local/fileA.bin');
      expect(preview.second).assertEqual('http://probe.local/fileB.bin');
      expect(preview.last).assertEqual('http://probe.local/fileD.bin');
      expect(preview.size).assertEqual(4);
    });

    it('preview_singleLink_secondLastEmpty', 0, () => {
      // 单链：second/last 空（c>1 才回填 last）、size=1
      // COLD-F1 连带修正：letterParams('A','A') 在源 startChar>=endChar 门下恒 []（源
      // :128-132，BatchAlgo.ets:73 同构——字母模式最少 2 链），单链输入直接构造
      // （computeBatchPreview 是独立于生成器的纯聚合表函数，单链预览语义照验）
      const urls: string[] = ['http://probe.local/fileA.bin'];
      const preview = computeBatchPreview(urls);
      expect(preview.first).assertEqual('http://probe.local/fileA.bin');
      expect(preview.second).assertEqual('');
      expect(preview.last).assertEqual('');
      expect(preview.size).assertEqual(1);
    });
  });
}
