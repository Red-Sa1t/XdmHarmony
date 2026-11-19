/*
 * U1.2 探针（P1-U2）纯函数层（设计书 §5.9）：零 @kit import——Hypium 本地单测可直接加载。
 * 常量同值锚（三处：P1-U2-download-server.js / 本文件 / EXPECT 表）：
 *   BLOCK_SIZE=65536、DOWNLOAD_BYTES=4194304 与 docs/probe/P0-U2-echo-server.js:22-23 同值
 *   （P1-U2-download-server.js 复刻同规格 /big.bin + 新增 /slow.bin?ms=40 分块延迟源）。
 * 确定性字节流：字节 o 属于块 floor(o/65536)，值为 块号 % 251（echo server makeSlice :27-33 同式）——
 * S7 字节抽查比对以此判定 206 续传的字节级正确性（若 resume 忽略偏移，pauseOffset 处字节必错位）。
 */

/** 64KB 分块（echo server CHUNK_SIZE 同值锚） */
export const BLOCK_SIZE: number = 65536;
/** 观测总量锚：4MiB（echo server BIG_BIN_BYTES 同值锚） */
export const DOWNLOAD_BYTES: number = 4194304;
/** 抽查点集大小：{0, pauseOffset-1, pauseOffset, total/2, total-1} */
export const SPOT_OFFSET_COUNT: number = 5;

/** 确定性字节值（echo server makeSlice 同式）：floor(offset/65536) % 251 */
export function expectedByteAt(offset: number): number {
  return Math.floor(offset / BLOCK_SIZE) % 251;
}

/** 第 i 个抽查点（i∈[0,4)）：固定点集 {0, pauseOffset-1(>0 时), pauseOffset, floor(total/2), total-1}；
 * 越界（>=totalBytes）或负值归 0（用例锁定）。totalBytes<=0 时全点归 0。 */
export function spotOffsetAt(i: number, totalBytes: number, pauseOffset: number): number {
  if (totalBytes <= 0) {
    return 0;
  }
  let offset: number = 0;
  if (i === 0) {
    offset = 0;
  } else if (i === 1) {
    offset = pauseOffset > 0 ? pauseOffset - 1 : 0;
  } else if (i === 2) {
    offset = pauseOffset > 0 ? pauseOffset : 0;
  } else if (i === 3) {
    offset = Math.floor(totalBytes / 2);
  } else if (i === 4) {
    offset = totalBytes - 1;
  }
  if (offset < 0 || offset >= totalBytes) {
    return 0;
  }
  return offset;
}
