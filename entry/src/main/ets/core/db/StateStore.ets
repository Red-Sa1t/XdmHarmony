/*
 * U2.2 下载状态 JSON 持久化 IO 壳（设计书 §2.2/§3.2/§5.2）：对照 TransactedIO.WriteStream/ReadStream
 * 双槽机制 + SaveChunkState/RestoreState 的文件面。
 * 工件布局（tempDir/<recordId>/ 内，随 deleteTempDir 自然清理=源码 chunks.db 在 TempDir 同构，
 * :159 SaveChunkState → DeleteFileParts :544-555）：
 *   chunks.json.1   槽位 1（读序首选；轮换后恒为最新——WriteStream 轮换不变量）
 *   chunks.json.2   槽位 2（上一代完整副本）
 *   chunks.json.new staging（写入中工件；**永不被读**，只经 renameSync 原子入槽）
 * 写序（对照 WriteStream :159-186 逐窗口）：staging(TRUNC 清上次崩溃半成品) → 新内容原子入 .2
 * （.1 全程完整）→ 轮换三步 .1→.3.<guid> / .2→.1 / .3→.2——任一时刻至少一个可读完整副本。
 * 读序（对照 ReadStream :92-103）：.1 先（最新）→ .2（上一代）；单槽 readTextSync 失败/结构门
 * （parseChunksJson，D2 END. 标记的 JSON 等价）不过 → 试另一槽；两槽全败 → null（无状态）。
 * 纪律：全部方法 catch 吞绝不抛（对照外层 catch→Log.Debug→return false，调用方本就忽略返回值）；
 * rename 前对已存在目标 bestEffortUnlink（不依赖 renameSync 未文档化的 replace 语义，d.ts :6597）。
 * 依赖红线：只依赖 PieceAlgo 纯类型/纯函数（禁 import PieceGrabber/Downloader——避免
 * engine→db→engine 环）；禁 probe import；业务日志 hilog domain 0x0000 tag 'StateStore'
 * （**绝不 [XDM_PROBE]**）。主线程同步 IO：16 片×~120B ≈2KB 文本+≥2s 节流，<1ms 级（§3.2 量级论证）。
 * U5.2 增量（R3-F1 收口，只加不改）：静态 removeById(baseTempDir, recordId)——目录级删除
 * （listFileSync 逐文件 unlinkSync + rmdirSync，PieceGrabber.deleteTempDir :1165-1181 同款手法；
 * rmdirSync 非递归——目录残留文件必先逐个 unlink）。对照源 RemoveDownload（ApplicationCore.cs
 * :725-798）tempDir 半区：state 文件+tempDir 无论 deleteFiles 真假都删（进行中分支 UIActions
 * DeleteDownloads 即传 false），最外层 catch 吞绝不抛（:796-798 同构）。
 */

import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { EnginePiece, RestoredPieces, buildChunksJson, parseChunksJson } from '../engine/PieceAlgo';

/** 工件基名（源码同名字 chunks.db 的 JSON 化对照物，D1） */
const CHUNKS_BASE_NAME: string = 'chunks.json';

export class StateStore {
  /** per-download 实例：构造入参 = 分片临时目录 tempDir/<recordId>（工件三件套全在其内） */
  private readonly dir: string;

  constructor(tempDirPath: string) {
    this.dir = tempDirPath;
  }

  /** 保存分片状态（WriteStream 公共入口 :159-186 等价；对照 SaveChunkState :153-165 调用面）：
   * pieces 空静默门在调度器侧（:158）；本方法同步写 staging→原子入槽+轮换；任一步抛错 catch 吞
   * +业务日志，绝不抛。 */
  saveChunks(pieces: Map<string, EnginePiece>, totalSize: number): void {
    try {
      const text: string = buildChunksJson(pieces, totalSize);
      const staging: string = this.dir + '/' + CHUNKS_BASE_NAME + '.new';
      // TRUNC：清掉上次崩溃残留的半成品 staging（staging 从不被读，半写无害）
      const file = fileIo.openSync(staging,
        fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, text);
      } finally {
        fileIo.closeSync(file);
      }
      const slot1: string = this.slotPath(1);
      if (!this.existsQuiet(slot1)) {
        // 首写（对照 :162-165：仅 .1 不存在时直写 .1）
        this.bestEffortUnlink(slot1);
        fileIo.renameSync(staging, slot1);
        return;
      }
      const slot2: string = this.slotPath(2);
      // 新内容先原子入 .2（.1 全程完整）→ 轮换三步（对照 :174-177 次序）：
      // .1→.3.<guid>（guid 防撞）/ .2→.1（最新恒 .1，读序偏好依据）/ .3→.2
      this.bestEffortUnlink(slot2);
      fileIo.renameSync(staging, slot2);
      const name3: string = this.dir + '/' + CHUNKS_BASE_NAME + '.3.' + util.generateRandomUUID();
      fileIo.renameSync(slot1, name3);
      fileIo.renameSync(slot2, slot1);
      fileIo.renameSync(name3, slot2);
    } catch (e) {
      const err = e as BusinessError;
      hilog.info(0x0000, 'StateStore', '%{public}s',
        'saveChunks failed errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
    }
  }

  /** 读回分片状态（ReadStream 公共入口 :92-103 等价；对照 RestoreState :200-206/:214-219 吞→空）：
   * 双槽读序 .1→.2；单槽读失败/结构门不过 → 试另一槽；两槽全败 → null（无状态→全新 start）。
   * 绝不抛。 */
  readChunks(): RestoredPieces | null {
    for (let slot = 1; slot <= 2; slot++) {
      const path: string = this.slotPath(slot);
      if (!this.existsQuiet(path)) {
        continue;
      }
      try {
        const text: string = fileIo.readTextSync(path);
        const restored: RestoredPieces | null = parseChunksJson(text);
        if (restored !== null) {
          return restored;
        }
        // 结构门不过（半写/畸形）：对照单文件 catch→false→试另一槽
      } catch (e) {
        const err = e as BusinessError;
        hilog.info(0x0000, 'StateStore', '%{public}s',
          'readChunks slot=' + String(slot) + ' failed errCode=' + String(err.code) +
            ' errMessage=' + (err.message ?? ''));
      }
    }
    return null;
  }

  /** 清残留（start() 全新下载前调用，D4：关闭源码 [Start, 首次保存] 崩溃窗口内恢复到上一会话
   * 残留 pieces 的歧义路径）：三工件逐个 unlink，全 catch 吞。孤儿分片文件不清（源码同貌，
   * deleteTempDir 兜底）。 */
  clear(): void {
    const staging: string = this.dir + '/' + CHUNKS_BASE_NAME + '.new';
    this.bestEffortUnlink(this.slotPath(1));
    this.bestEffortUnlink(this.slotPath(2));
    this.bestEffortUnlink(staging);
  }

  /** per-id 态删除（U5.2 R3-F1 收口；对照 RemoveDownload :725-798 tempDir 半区——deleteFiles
   * false 也照删 state+tempDir）：tempDir/<recordId>/ 目录级删除=listFileSync 逐文件 unlinkSync
   * （内层 try/catch 吞）→rmdirSync（外层 try/catch 吞——目录不存在/非空残留均无害）。
   * rmdirSync 非递归（13900032 Directory not empty），故必先逐文件 unlink；
   * 全程 catch 吞绝不抛（源最外层 catch :796-798 同构）。静态方法：调用方无 StateStore 实例
   * （Index.removeRecords 删记录路径只有 baseTempDir+id）。 */
  static removeById(baseTempDir: string, recordId: string): void {
    const dir: string = baseTempDir + '/' + recordId;
    try {
      const names: string[] = fileIo.listFileSync(dir);
      for (let i = 0; i < names.length; i++) {
        try {
          fileIo.unlinkSync(dir + '/' + names[i]);
        } catch (e) {
          // 单文件失败吞（删目录时 rmdirSync 会再报非空，调用方语义=尽力清理）
        }
      }
      fileIo.rmdirSync(dir);
    } catch (e) {
      // 目录不存在（无恢复态）/rmdir 非空残留：均无害（源 RemoveDownload 最外层 catch 同构）
    }
  }

  // ---------- 内部工具（全 catch 吞） ----------

  private slotPath(slot: number): string {
    return this.dir + '/' + CHUNKS_BASE_NAME + '.' + String(slot);
  }

  /** rename 前防御性 unlink 目标（catch 吞）：不依赖 renameSync 对已存在目标的替换语义
   * （d.ts :6597 未文档化 replace 行为）；unlink 窗口内另一槽仍完整，不变量不破（§2.2）。 */
  private bestEffortUnlink(path: string): void {
    try {
      fileIo.unlinkSync(path);
    } catch (e) {
      // 不存在/失败吞（对照 WriteStream 前置 File.Delete 的 try/catch 语义）
    }
  }

  private existsQuiet(path: string): boolean {
    try {
      return fileIo.accessSync(path);
    } catch (e) {
      return false;
    }
  }
}
