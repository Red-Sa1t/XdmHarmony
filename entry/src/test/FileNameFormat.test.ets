/*
 * U1.2 文件名+格式化 Hypium 本地用例（设计书 §7-[A]-3 用例清单，13 条）。
 * 被测模块零 @kit import，本地测试环境可直接 import。
 * 诚实注记（U0.2/U1.1 同款）：本设计会话未运行本地单测执行器（工程无 hvigor wrapper、devecocli 无
 * test 子命令）；用例照常入库（assembleHap 不编译 src/test，不影响编译门禁），由编码员在 IDE/hvigor
 * 侧实跑一次并记录；若 LocalUnit 任务在 SDK 6.1.1 不可用，注明"用例已入库待 U2.3 统一回归"。
 */

import { describe, it, expect } from '@ohos/hypium';
import { sanitizeFileName, fileNameFromUrl, getUniqueFileName } from '../main/ets/core/util/FileNames';
import { formatSize, formatSpeed, toHMS } from '../main/ets/core/util/Formatting';

export default function fileNameFormatTest(): void {
  describe('FileNameFormat', () => {
    it('sanitizeFileName_invalidCharsReplaced', 0, () => {
      // 显式无效字符集 '\\ / : * ? " < > |' + 控制符 → '_'（FileHelper.cs:15-20 语义 + D6 枚举）
      expect(sanitizeFileName('a<b>:c?"d')).assertEqual('a_b__c__d');
      expect(sanitizeFileName('a|b*c')).assertEqual('a_b_c');
      expect(sanitizeFileName('a\x01b')).assertEqual('a_b');
    });

    it('sanitizeFileName_lastSegmentAfterSlashOrBackslash', 0, () => {
      // D6 修正原版死赋值：'/' 与 '\\' 较大下标取最后一段
      expect(sanitizeFileName('a/b\\c/d.txt')).assertEqual('d.txt');
      expect(sanitizeFileName('e\\f.txt')).assertEqual('f.txt');
      expect(sanitizeFileName('g/h.txt')).assertEqual('h.txt');
    });

    it('sanitizeFileName_keepsNormalDots', 0, () => {
      expect(sanitizeFileName('report.v2.final.txt')).assertEqual('report.v2.final.txt');
    });

    it('sanitizeFileName_emptyFallback', 0, () => {
      expect(sanitizeFileName('')).assertEqual('file');
      expect(sanitizeFileName('///')).assertEqual('file');
    });

    it('fileNameFromUrl_pathTail', 0, () => {
      expect(fileNameFromUrl('http://h/dir/big.bin?x=1')).assertEqual('big.bin');
      expect(fileNameFromUrl('http://h/dir/big.bin#frag')).assertEqual('big.bin');
    });

    it('fileNameFromUrl_rootFallsToHost', 0, () => {
      expect(fileNameFromUrl('http://a.b.c/')).assertEqual('a_b_c');
    });

    it('getUniqueFileName_noConflict', 0, () => {
      const result: string = getUniqueFileName('name.ext', '/tmp/dl', (p: string): boolean => false);
      expect(result).assertEqual('name.ext');
    });

    it('getUniqueFileName_increments', 0, () => {
      // 注入假存在表（纯度：不触 fs）：name.ext 与 name_1.ext 已存在 → name_2.ext（FileHelper.cs:107-124）
      const dir: string = '/tmp/dl';
      const table: Record<string, boolean> = {};
      table[dir + '/name.ext'] = true;
      table[dir + '/name_1.ext'] = true;
      const result: string = getUniqueFileName('name.ext', dir, (p: string): boolean => {
        return table[p] === true;
      });
      expect(result).assertEqual('name_2.ext');
    });

    it('formatSize_ladder', 0, () => {
      // FormattingHelper.cs:21-41 阶梯：>KB K / >MB M / >GB G（一位小数）
      expect(formatSize(2048)).assertEqual('2.0K');
      expect(formatSize(5242880)).assertEqual('5.0M');
      expect(formatSize(2147483649)).assertEqual('2.0G');
    });

    it('formatSize_nonPositiveDash', 0, () => {
      expect(formatSize(0)).assertEqual('---');
      expect(formatSize(-5)).assertEqual('---');
    });

    it('formatSize_bytesInteger', 0, () => {
      expect(formatSize(999)).assertEqual('999B');
      // C# 阶梯 length > KB 严格大于：1024 恰在界上 → 整数 B 分支
      expect(formatSize(1024)).assertEqual('1024B');
    });

    it('formatSpeed_suffix', 0, () => {
      // Application.cs:309：FormatSize(speed) + "/s"
      expect(formatSpeed(2048)).assertEqual('2.0K/s');
      expect(formatSpeed(0)).assertEqual('---/s');
    });

    it('toHMS_padding', 0, () => {
      // FormattingHelper.cs:11-19：逐段 PadLeft(2,'0')
      expect(toHMS(3661)).assertEqual('01:01:01');
      expect(toHMS(0)).assertEqual('00:00:00');
      expect(toHMS(45296)).assertEqual('12:34:56');
    });
  });
}
