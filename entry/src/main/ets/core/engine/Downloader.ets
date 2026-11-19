/*
 * U2.1 分段下载引擎门面（设计书 §5.7；内部重写为 PieceScheduler 委托，外壳冻结）。
 * 事件面冻结（单元约束①）：DownloadEvents/NoopDownloadEvents/ForwardDownloadEvents 三声明与
 * U1.2 逐字节一致（Index.ets/NewDownloadDialog.ets/ProbeDownload.ets 等消费方零改动）；
 * 分片级观测走本类新增快照 getter（describePieces/getPieceSnapshots/activeSegmentCount），
 * 不给事件面加方法。
 * 职责迁移：U1.2 单分片私有态（pieceId/pieceFile/fd/generation/stopRequested/timesRetried/
 * pauseGate/currentClient 等）全部移入 PieceScheduler 或消亡——**引擎层从此无 fd 字段**（约束④：
 * fd 只存在于 worker 尝试栈帧，SegmentWorker.ets）。
 * 分层红线：零 DownloadStore（DB 写全在事件消费方）、零 probe import、零 [XDM_PROBE] 输出。
 * 线程模型（决策 2）：主线程单点调度（PieceScheduler）+ taskpool.Task 并行分段（SegmentWorker）；
 * 8 段并行=8 个 Task 同时在途（OS 线程数系统调度，D15）。
 */

import { PieceScheduler } from './PieceGrabber';
import { PieceSnapshot } from './PieceAlgo';
import { ThrottleStats } from './SegmentWorker';
import { DownloadRecord } from '../../model/DownloadRecord';

/** 引擎事件面（对照原版 Started/PieceConnected/ProgressChanged/Cancelled/Finished/Failed 事件族；
 * Phase 2 分片化时保此面稳定则 UI 零改动）。 */
export interface DownloadEvents {
  onStarted(id: string): void;
  onConnected(id: string, status: number, totalSize: number, resumable: boolean, contentType: string): void;
  onProgress(id: string, progress: number, instantSpeed: number, etaSeconds: number, downloadedBytes: number): void;
  onPaused(id: string, offsetBytes: number): void;
  onFinished(id: string, finalFileSize: number, filePath: string): void;
  onFailed(id: string, errorCode: number, errorMessage: string): void;
}

/** 空事件实现（默认参数用；调用方未挂监听器时引擎行为不变） */
export class NoopDownloadEvents implements DownloadEvents {
  onStarted(id: string): void {
  }

  onConnected(id: string, status: number, totalSize: number, resumable: boolean, contentType: string): void {
  }

  onProgress(id: string, progress: number, instantSpeed: number, etaSeconds: number, downloadedBytes: number): void {
  }

  onPaused(id: string, offsetBytes: number): void {
  }

  onFinished(id: string, finalFileSize: number, filePath: string): void {
  }

  onFailed(id: string, errorCode: number, errorMessage: string): void {
  }
}

/** 事件转发器（hvigor 实测修复：DownloadEvents 为方法签名接口，对象字面量装配触发
 * arkts-no-untyped-obj-literals 编译错误——方法接口的合法装配形态是类实现，闭包转发由此类承载，
 * NoopDownloadEvents 同证）。
 */
export class ForwardDownloadEvents implements DownloadEvents {
  private readonly startedFn: (id: string) => void;
  private readonly connectedFn: (id: string, status: number, totalSize: number, resumable: boolean,
    contentType: string) => void;
  private readonly progressFn: (id: string, progress: number, instantSpeed: number, etaSeconds: number,
    downloadedBytes: number) => void;
  private readonly pausedFn: (id: string, offsetBytes: number) => void;
  private readonly finishedFn: (id: string, finalFileSize: number, filePath: string) => void;
  private readonly failedFn: (id: string, errorCode: number, errorMessage: string) => void;

  constructor(startedFn: (id: string) => void,
    connectedFn: (id: string, status: number, totalSize: number, resumable: boolean,
      contentType: string) => void,
    progressFn: (id: string, progress: number, instantSpeed: number, etaSeconds: number,
      downloadedBytes: number) => void,
    pausedFn: (id: string, offsetBytes: number) => void,
    finishedFn: (id: string, finalFileSize: number, filePath: string) => void,
    failedFn: (id: string, errorCode: number, errorMessage: string) => void) {
    this.startedFn = startedFn;
    this.connectedFn = connectedFn;
    this.progressFn = progressFn;
    this.pausedFn = pausedFn;
    this.finishedFn = finishedFn;
    this.failedFn = failedFn;
  }

  onStarted(id: string): void {
    this.startedFn(id);
  }

  onConnected(id: string, status: number, totalSize: number, resumable: boolean, contentType: string): void {
    this.connectedFn(id, status, totalSize, resumable, contentType);
  }

  onProgress(id: string, progress: number, instantSpeed: number, etaSeconds: number,
    downloadedBytes: number): void {
    this.progressFn(id, progress, instantSpeed, etaSeconds, downloadedBytes);
  }

  onPaused(id: string, offsetBytes: number): void {
    this.pausedFn(id, offsetBytes);
  }

  onFinished(id: string, finalFileSize: number, filePath: string): void {
    this.finishedFn(id, finalFileSize, filePath);
  }

  onFailed(id: string, errorCode: number, errorMessage: string): void {
    this.failedFn(id, errorCode, errorMessage);
  }
}

export class Downloader {
  private readonly scheduler: PieceScheduler;

  constructor(record: DownloadRecord, events?: DownloadEvents) {
    this.scheduler = new PieceScheduler(record, events);
  }

  /** 全新下载（fire-and-forget；对照 Thread.Start :62-66 → taskpool.execute） */
  start(): void {
    this.scheduler.start();
  }

  /** 续传（同实例内 stop 后调用；pieces 状态保持 stop 时刻值——Σdownloaded 暂停偏移唯一可信源） */
  resume(): void {
    this.scheduler.resume();
  }

  /** 停止（暂停/取消同源单入口，D10）：取消全部在途 Task → 清 records → onPaused(Σdownloaded)。
   * temp 分片保留供续传（清 temp 属完成收尾）。 */
  stop(): void {
    this.scheduler.stop();
  }

  isRunning(): boolean {
    return this.scheduler.isRunning();
  }

  // ---------- 分片观测面（探针消费，非事件面，§0-7） ----------

  /** 单行分片概览（PieceScheduler.describePieces 透传） */
  describePieces(): string {
    return this.scheduler.describePieces();
  }

  /** 分片快照（PieceScheduler.getPieceSnapshots 透传；区间不重叠/覆盖观测原料） */
  getPieceSnapshots(): PieceSnapshot[] {
    return this.scheduler.getPieceSnapshots();
  }

  /** 在途分段数（"8 段并行"观测口径，D15） */
  activeSegmentCount(): number {
    return this.scheduler.activeSegmentCount();
  }

  /** throttle 观测聚合（PieceScheduler.throttleStats 透传；activeSegmentCount 同款观测面，
   * 非事件面——U3.2 探针 P3-U2 消费，D18） */
  throttleStats(): ThrottleStats {
    return this.scheduler.throttleStats();
  }
}
