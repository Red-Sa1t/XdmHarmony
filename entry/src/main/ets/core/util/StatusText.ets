/*
 * U4.1 状态列文本合成纯函数（设计书 §3.4/§5.1）。
 * 对照源码：XDM.Core/Util/Helpers.cs:211-257——GetStatusText（:211-226 四状态标签）+
 * GenerateStatusText（:228-257 逐分支）：
 *   非 Downloading → labels[status]（Stopped/Finished/Waiting → STAT_*；default → status.ToString()）
 *   Downloading：eta 空且 speed 空 → labels.downloading（:235-237）
 *               eta 空 → speed（:238-240）；speed 空 → eta（:241-243）
 *               双全 → "{Speed} - {ETA}"（:244-246，$"{ent.DownloadSpeed} - {ent.ETA}"）
 * 空判定 = (v === null || v === '')，对照 string.IsNullOrEmpty。
 * 零 import（含 @kit）——Hypium 本地单测（StatusText.test.ets）与探针 S2 直接加载；
 * status 入参为 number：DownloadStatus 列值编码（DownloadEntries.cs:64-67，
 * Downloading=0/Stopped=1/Finished=2/Waiting=3——model/DownloadTypes.ets 枚举同值，本文件零依赖不复述枚举）。
 * 消费方：components/DownloadListItem.ets 状态列单 Text（对照 xaml:641
 * DisplayMemberBinding=StatusText 单列——speed/eta 散排移除，@Observed 字段变更即重算）。
 * ArkTS 合规：显式返回类型、无对象字面量（labels 由调用方以 StatusLabels 类型装配）。
 */

/** 四状态标签（渲染值来自 string.json STAT_* 键，Index 侧 getStringSync 装配一次传入；探针用英文常量） */
export interface StatusLabels {
  downloading: string;
  stopped: string;
  finished: string;
  waiting: string;
}

/** IsNullOrEmpty 同貌（Helpers.cs :234/:238/:242 的 string.IsNullOrEmpty） */
function isEmptyText(v: string | null): boolean {
  return v === null || v === '';
}

/** 状态列文本合成（Helpers.cs:228-257 GenerateStatusText 逐分支移植）。
 * status：DownloadStatus 列值（0=Downloading/1=Stopped/2=Finished/3=Waiting）；
 * speed/eta：UI 派生字符串（可为 null）；labels：四状态标签。 */
export function generateStatusText(status: number, speed: string | null, eta: string | null,
  labels: StatusLabels): string {
  // 非 Downloading → GetStatusText（:211-226）：Stopped/Finished/Waiting 归标签；default → status.ToString()
  if (status === 1) {
    return labels.stopped;
  }
  if (status === 2) {
    return labels.finished;
  }
  if (status === 3) {
    return labels.waiting;
  }
  if (status !== 0) {
    // C# default: return status.ToString()（:224，防御不可达分支）
    return String(status);
  }
  // Downloading 四分支（:234-248）
  if (isEmptyText(eta) && isEmptyText(speed)) {
    return labels.downloading;
  }
  if (isEmptyText(eta)) {
    return speed ?? '';
  }
  if (isEmptyText(speed)) {
    return eta ?? '';
  }
  return `${speed} - ${eta}`;
}
