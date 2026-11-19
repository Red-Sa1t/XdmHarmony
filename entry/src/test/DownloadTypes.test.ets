/*
 * U1.1 本地单测：四枚举数值与列值编码逐一断言（设计书 §7-[A]-3，防成员重排）。
 * 枚举数值 = downloads 表列值锚（status/proxy/filenamefetchmode/completed 四列），
 * 重排会静默改写落库语义——这里逐成员锁死。
 * 诚实注记（沿用 U0.2）：本会话未运行本地单测执行器（工程无 hvigor wrapper、devecocli 无 test
 * 子命令）；用例照常入库（assembleHap 不编译 src/test），由 IDE/hvigor LocalUnit 实跑或待 U2.3 统一回归。
 */

import { describe, it, expect } from '@ohos/hypium';
import { DownloadKind, DownloadStatus, FileNameFetchMode, ProxyType } from '../main/ets/model/DownloadTypes';

export default function downloadTypesTest(): void {
  describe('DownloadTypes', () => {
    it('downloadStatus_values_matchColumnEncoding', 0, () => {
      expect(DownloadStatus.Downloading).assertEqual(0);
      expect(DownloadStatus.Stopped).assertEqual(1);
      expect(DownloadStatus.Finished).assertEqual(2);
      expect(DownloadStatus.Waiting).assertEqual(3);
    });

    it('proxyType_values_matchColumnEncoding', 0, () => {
      expect(ProxyType.System).assertEqual(0);
      expect(ProxyType.Direct).assertEqual(1);
      expect(ProxyType.Custom).assertEqual(2);
    });

    it('fileNameFetchMode_values_matchColumnEncoding', 0, () => {
      expect(FileNameFetchMode.None).assertEqual(0);
      expect(FileNameFetchMode.FileNameAndExtension).assertEqual(1);
      expect(FileNameFetchMode.ExtensionOnly).assertEqual(2);
    });

    it('downloadKind_values_matchCompletedColumn', 0, () => {
      expect(DownloadKind.InProgress).assertEqual(0);
      expect(DownloadKind.Finished).assertEqual(1);
    });
  });
}
