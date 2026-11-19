/*
 * U4.1 StatusText 纯函数 Hypium 本地用例（设计书 §7-[A]-2 用例清单，8 条）。
 * 被测模块零 @kit import（StatusText.ets），本地测试环境可直接 import（QueueAlgo.test.ets 同口径）。
 * 锁定目标：GenerateStatusText（Helpers.cs:228-257）四分支+四停态标签映射+空串视同 null
 * （string.IsNullOrEmpty 同貌）+default 分支数值回退。
 * 标签常量用英文原值（string.json base STAT_* 键同值——D11）。
 */

import { describe, it, expect } from '@ohos/hypium';
import { StatusLabels, generateStatusText } from '../main/ets/core/util/StatusText';

/** 英文标签常量（渲染值=string.json base 同值；探针 S2 同款） */
function labels(): StatusLabels {
  const value: StatusLabels = {
    downloading: 'Downloading',
    stopped: 'Stopped',
    finished: 'Finished',
    waiting: 'Waiting'
  };
  return value;
}

/** DownloadStatus 列值锚（DownloadEntries.cs:64-67；model/DownloadTypes.ets 枚举同值） */
const STATUS_DOWNLOADING: number = 0;
const STATUS_STOPPED: number = 1;
const STATUS_FINISHED: number = 2;
const STATUS_WAITING: number = 3;

export default function statusTextTest(): void {
  describe('StatusText', () => {
    it('downloading_noSpeedNoEta_returnsLabel', 0, () => {
      // :234-237 eta 空且 speed 空 → STAT_DOWNLOADING
      expect(generateStatusText(STATUS_DOWNLOADING, null, null, labels())).assertEqual('Downloading');
    });

    it('downloading_speedOnly_returnsSpeed', 0, () => {
      // :238-240 eta 空 → speed
      expect(generateStatusText(STATUS_DOWNLOADING, '1.2MB/s', null, labels())).assertEqual('1.2MB/s');
    });

    it('downloading_etaOnly_returnsEta', 0, () => {
      // :241-243 speed 空 → eta
      expect(generateStatusText(STATUS_DOWNLOADING, null, '00:01', labels())).assertEqual('00:01');
    });

    it('downloading_both_returnsSpeedDashEta', 0, () => {
      // :244-246 "{Speed} - {ETA}"
      expect(generateStatusText(STATUS_DOWNLOADING, '1.2MB/s', '00:01', labels()))
        .assertEqual('1.2MB/s - 00:01');
    });

    it('emptyStringTreatedAsNull', 0, () => {
      // string.IsNullOrEmpty 同貌：空串与 null 等价（:234/:238/:242）
      expect(generateStatusText(STATUS_DOWNLOADING, '', '', labels())).assertEqual('Downloading');
      expect(generateStatusText(STATUS_DOWNLOADING, '1.2MB/s', '', labels())).assertEqual('1.2MB/s');
      expect(generateStatusText(STATUS_DOWNLOADING, '', '00:01', labels())).assertEqual('00:01');
    });

    it('stopped_returnsStoppedLabel', 0, () => {
      // :217-218 → STAT_STOPPED
      expect(generateStatusText(STATUS_STOPPED, '1.2MB/s', '00:01', labels())).assertEqual('Stopped');
    });

    it('finished_returnsFinishedLabel', 0, () => {
      // :219-220 → STAT_FINISHED
      expect(generateStatusText(STATUS_FINISHED, null, null, labels())).assertEqual('Finished');
    });

    it('waiting_returnsWaitingLabel', 0, () => {
      // :221-222 → STAT_WAITING；附带 default 分支（C# status.ToString() 同貌）
      expect(generateStatusText(STATUS_WAITING, null, null, labels())).assertEqual('Waiting');
      expect(generateStatusText(9, null, null, labels())).assertEqual('9');
    });
  });
}
