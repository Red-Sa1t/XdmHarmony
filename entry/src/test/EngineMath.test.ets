/*
 * U1.2 引擎纯规则 Hypium 本地用例（设计书 §7-[A]-3 用例清单，10 条）。
 * 被测模块零 @kit import，本地测试环境可直接 import。
 * 执行注记（U2.3 更新 2026-09-28）：U2.3 设计会话已接通 hvigor 本地单测脚本化入口并实跑——
 * `hvigorw test`（UnitTestArkTS 编译→Previewer 宿主执行→GenerateUnitTestResult）BUILD SUCCESSFUL、
 * 本套 10 条全绿；本轮实跑修正本文件两处断言缺陷（avgSpeed_fractional 量级写错、
 * shouldEmitProgress_gate 预期反写——原断言从未被执行到，assembleHap 不编译 src/test）。
 * 入口命令链与四步接通过程详见 docs/design/u2-3-engine-fidelity-DESIGN.md §3.7。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  EngineError,
  ERR_GENERIC,
  ERR_NON_RESUMABLE,
  ERR_MAX_RETRY,
  ERR_INVALID_RESPONSE,
  ERR_DISK_ERROR,
  instantSpeedBps,
  avgSpeedBps,
  etaSeconds,
  shouldEmitProgress,
  exceedsMaxRetry
} from '../main/ets/core/engine/EngineMath';

export default function engineMathTest(): void {
  describe('EngineMath', () => {
    it('errCode_values_matchSourceOrder', 0, () => {
      // ErrorCode.cs:9-19 序位锚：None=0, Generic=1, NonResumable=2, AssemblingFailed=3,
      // MaxRetryFailed=4, InvalidResponse=5, FFmpegNotFound=6, FFmpegError=7, DiskError=8, SessionExpired=9
      expect(ERR_GENERIC).assertEqual(1);
      expect(ERR_NON_RESUMABLE).assertEqual(2);
      expect(ERR_MAX_RETRY).assertEqual(4);
      expect(ERR_INVALID_RESPONSE).assertEqual(5);
      expect(ERR_DISK_ERROR).assertEqual(8);
    });

    it('engineError_fields', 0, () => {
      const err: EngineError = new EngineError(ERR_NON_RESUMABLE, false, 'Resume not supported');
      expect(err instanceof Error).assertEqual(true);
      expect(err.code).assertEqual(ERR_NON_RESUMABLE);
      expect(err.retriable).assertEqual(false);
      expect(err.message).assertEqual('Resume not supported');
      const retriable: EngineError = new EngineError(ERR_GENERIC, true, 'Unexpected EOF');
      expect(retriable.retriable).assertEqual(true);
    });

    it('instantSpeed_floorDivision', 0, () => {
      // C# long 整除（HTTPDownloaderBase.cs:290）→ Math.floor：150000B/500ms → 300000B/s
      expect(instantSpeedBps(150000, 500)).assertEqual(300000);
      // 非整除截断：1000B/3ms → 333333（1000000/3 = 333333.33 → floor）
      expect(instantSpeedBps(1000, 3)).assertEqual(333333);
    });

    it('instantSpeed_zeroElapsed_returnsZero', 0, () => {
      expect(instantSpeedBps(1000, 0)).assertEqual(0);
      expect(instantSpeedBps(1000, -5)).assertEqual(0);
    });

    it('avgSpeed_fractional', 0, () => {
      // C# 浮点除（:291）：250000B/500ms → 500000.0
      expect(avgSpeedBps(250000, 500)).assertEqual(500000);
      // 非整除：1000B/3ms → 333333.333..（U2.3 实跑修正：原断言按 333.33 量级写错——返回值
      // 单位 B/s=333333.33，原量级断言恒假且从未被执行到）
      const frac: number = avgSpeedBps(1000, 3);
      expect(frac > 333333.333 && frac < 333333.334).assertEqual(true);
    });

    it('avgSpeed_zeroElapsed_returnsZero', 0, () => {
      expect(avgSpeedBps(1000, 0)).assertEqual(0);
      expect(avgSpeedBps(1000, -1)).assertEqual(0);
    });

    it('etaSeconds_ceil', 0, () => {
      // (long)Math.Ceiling((FileSize-totalDownloaded)/avgSpeed)：余 2MiB @ 1MiB/s → 2
      expect(etaSeconds(4194304, 2097152, 1048576.0)).assertEqual(2);
      // 非整除向上取整：余 1000B @ 300B/s → ceil(3.33) = 4
      expect(etaSeconds(2000, 1000, 300.0)).assertEqual(4);
    });

    it('etaSeconds_zeroSizeOrSpeed_returnsZero', 0, () => {
      // D17 守卫：fileSize<=0 或 avgSpeed<=0 → 0（C# 对 0 除得 Infinity 再 (long) 强转未定义）
      expect(etaSeconds(0, 100, 100.0)).assertEqual(0);
      expect(etaSeconds(-1, 100, 100.0)).assertEqual(0);
      expect(etaSeconds(1000, 100, 0)).assertEqual(0);
    });

    it('shouldEmitProgress_gate', 0, () => {
      // :288 `ticks - lastProgressUpdatedAt > 500`（严格大于）——U2.3 实跑修正：原断言 501/499
      // 预期写反（delta=now-last：499 例才是 delta>500 真例，501 是假例），首个断言失败即抛
      // AssertException，后两行从未执行
      expect(shouldEmitProgress(1000, 499)).assertEqual(true);
      expect(shouldEmitProgress(1000, 501)).assertEqual(false);
      expect(shouldEmitProgress(1000, 500)).assertEqual(false);
    });

    it('exceedsMaxRetry_boundary', 0, () => {
      // PieceGrabber.cs:113-117 原序：先 ++ 后判 >MaxRetry —— 10 次失败仍重试，第 11 次失败才终态
      expect(exceedsMaxRetry(10, 10)).assertEqual(false);
      expect(exceedsMaxRetry(11, 10)).assertEqual(true);
    });
  });
}
