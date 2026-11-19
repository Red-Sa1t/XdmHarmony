/*
 * U1.2 确定性字节锚 Hypium 本地用例（设计书 §7-[A]-3 用例清单，4 条）。
 * 被测模块零 @kit import，本地测试环境可直接 import。
 * 诚实注记（U0.2/U1.1 同款）：本设计会话未运行本地单测执行器（工程无 hvigor wrapper、devecocli 无
 * test 子命令）；用例照常入库（assembleHap 不编译 src/test，不影响编译门禁），由编码员在 IDE/hvigor
 * 侧实跑一次并记录；若 LocalUnit 任务在 SDK 6.1.1 不可用，注明"用例已入库待 U2.3 统一回归"。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  BLOCK_SIZE,
  DOWNLOAD_BYTES,
  SPOT_OFFSET_COUNT,
  expectedByteAt,
  spotOffsetAt
} from '../main/ets/probe/units/ProbeDownloadLogic';

export default function probeDownloadLogicTest(): void {
  describe('ProbeDownloadLogic', () => {
    it('expectedByteAt_blockPattern', 0, () => {
      // echo server makeSlice 同式：floor(offset/65536) % 251
      expect(expectedByteAt(0)).assertEqual(0);
      expect(expectedByteAt(65535)).assertEqual(0);
      expect(expectedByteAt(65536)).assertEqual(1);
      expect(expectedByteAt(131072)).assertEqual(2);
      // 回环锚：块 251 → 251 % 251 = 0
      expect(expectedByteAt(251 * BLOCK_SIZE)).assertEqual(0);
      expect(expectedByteAt(252 * BLOCK_SIZE)).assertEqual(1);
    });

    it('spotOffsets_fivePoints', 0, () => {
      // 固定点集 {0, pauseOffset-1, pauseOffset, total/2, total-1}
      expect(SPOT_OFFSET_COUNT).assertEqual(5);
      const pause: number = 262144;
      expect(spotOffsetAt(0, DOWNLOAD_BYTES, pause)).assertEqual(0);
      expect(spotOffsetAt(1, DOWNLOAD_BYTES, pause)).assertEqual(262143);
      expect(spotOffsetAt(2, DOWNLOAD_BYTES, pause)).assertEqual(262144);
      expect(spotOffsetAt(3, DOWNLOAD_BYTES, pause)).assertEqual(2097152);
      expect(spotOffsetAt(4, DOWNLOAD_BYTES, pause)).assertEqual(4194303);
    });

    it('spotOffsetAt_clamps', 0, () => {
      // 越界/负值归 0（用例锁定）
      expect(spotOffsetAt(0, 0, 100)).assertEqual(0);
      expect(spotOffsetAt(3, 0, 0)).assertEqual(0);
      // i 越出点集 → 0
      expect(spotOffsetAt(5, DOWNLOAD_BYTES, 100)).assertEqual(0);
      expect(spotOffsetAt(-1, DOWNLOAD_BYTES, 100)).assertEqual(0);
      // pauseOffset 越界（>=total，快源跑赢暂停形态）→ 归 0
      expect(spotOffsetAt(2, DOWNLOAD_BYTES, DOWNLOAD_BYTES)).assertEqual(0);
      // pauseOffset=0（未收到字节）→ 1/2 点归 0
      expect(spotOffsetAt(1, DOWNLOAD_BYTES, 0)).assertEqual(0);
      expect(spotOffsetAt(2, DOWNLOAD_BYTES, 0)).assertEqual(0);
      // 中点/尾点钳制：小文件边界
      expect(spotOffsetAt(4, 1, 0)).assertEqual(0);
    });

    it('constants_matchServerAnchor', 0, () => {
      // 与 docs/probe/P0-U2-echo-server.js:22-23、P1-U2-download-server.js 三处同值锚
      expect(BLOCK_SIZE).assertEqual(65536);
      expect(DOWNLOAD_BYTES).assertEqual(4194304);
    });
  });
}
