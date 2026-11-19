/*
 * U2.1 探针（P2-U1）纯函数层（设计书 §5.8）：零 @kit import——Hypium 本地单测可直接加载。
 * 区间覆盖/重叠/间隙校验（S3 逐瞬时快照不变量观测：任一瞬时 pieces Map 均为 [0,total) 的不交
 * 覆盖——分裂=一窗换两半窗保性质，取消重派后亦然，§6-S3）；快照行格式化（ProbeKit 值白名单
 * [A-Za-z0-9_.:/|= -] 内字符）；吞吐比值（S4 观测值，不判定）。
 * 红线：观测值只写事实不写 PASS/FAIL（coverageComplete/maxConcurrent 等谓词在探针页对观测值
 * 编码，判定在 EXPECT/verify）。
 * 常量同值锚：SEG_SOURCE_BYTES=4194304 与 ProbeDownloadLogic.DOWNLOAD_BYTES /
 * P1-U2-download-server.js BIG_BIN_BYTES 三处同值（S2/S3/S5 判定锚）。
 */

import { PieceSnapshot } from '../../core/engine/PieceAlgo';

/** 观测总量锚：4MiB（echo server BIG_BIN_BYTES 同值锚） */
export const SEG_SOURCE_BYTES: number = 4194304;

/** 覆盖校验结果（观测事实：overlapCount/gapCount/coveredBytes=Σlength，重叠去重不要求） */
export interface CoverageResult {
  overlapCount: number;
  gapCount: number;
  /** 首个间隙起点（下一片 offset）；无间隙 -1 */
  firstGapStart: number;
  coveredBytes: number;
}

/** 区间完整性校验：按 offset 排序后相邻比较——prev.offset+prev.length 与 next.offset：
 * `>` overlap++（区间重叠）；`<` gap++（间隙）；相等=无缝衔接。
 * 采集守卫：仅纳入 length>0 的分片（探测完成前初始片 length=-1 不参与覆盖校验——
 * 排序前过滤，探针页可直传全量快照）。注意不可对"全程快照并集"校验——历史大窗与其分裂
 * 半窗天然重叠，并集必 overlap>0；口径=逐瞬时快照（§6-S3 双口径之一）。 */
export function checkCoverage(snaps: PieceSnapshot[]): CoverageResult {
  const usable: PieceSnapshot[] = [];
  for (let i = 0; i < snaps.length; i++) {
    if (snaps[i].length > 0) {
      usable.push(snaps[i]);
    }
  }
  usable.sort((a: PieceSnapshot, b: PieceSnapshot): number => a.offset - b.offset);
  let overlapCount: number = 0;
  let gapCount: number = 0;
  let firstGapStart: number = -1;
  let coveredBytes: number = 0;
  for (let i = 0; i < usable.length; i++) {
    coveredBytes += usable[i].length;
  }
  for (let i = 1; i < usable.length; i++) {
    const prevEnd: number = usable[i - 1].offset + usable[i - 1].length;
    if (prevEnd > usable[i].offset) {
      overlapCount++;
    } else if (prevEnd < usable[i].offset) {
      gapCount++;
      if (firstGapStart < 0) {
        firstGapStart = usable[i].offset;
      }
    }
  }
  const result: CoverageResult = {
    overlapCount: overlapCount,
    gapCount: gapCount,
    firstGapStart: firstGapStart,
    coveredBytes: coveredBytes
  };
  return result;
}

/** 快照行格式化（ProbeKit 白名单内）：n=<数>/<id8>.<offset>.<length>.<downloaded>.<state>.
 * <windowStart>-<windowEnd> 片间 '/' 连接。 */
export function formatSnapshots(snaps: PieceSnapshot[]): string {
  let line: string = 'n=' + String(snaps.length);
  for (let i = 0; i < snaps.length; i++) {
    const p: PieceSnapshot = snaps[i];
    line += '/' + p.id.slice(0, 8) + '.' + String(p.offset) + '.' + String(p.length) + '.' +
      String(p.downloaded) + '.' + String(p.state) + '.' +
      String(p.windowStart) + '-' + String(p.windowEnd);
  }
  return line;
}

/** 吞吐比值（S4 观测值不判定）：single<=0（基线不可测）→ -1；否则 seg/single
 * （慢源下期望 >1——8 连接并行分摊每块延迟；快源/空载机器下 ≈1，EXPECT 记 UNVERIFIED 分支）。 */
export function throughputRatio(segBytesPerSec: number, singleBytesPerSec: number): number {
  if (singleBytesPerSec <= 0) {
    return -1;
  }
  return segBytesPerSec / singleBytesPerSec;
}
