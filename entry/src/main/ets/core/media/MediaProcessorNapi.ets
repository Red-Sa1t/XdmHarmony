// A single FIFO owns native media work for this ArkTS environment. File publication
// and deletion of downloaded input segments remain the downloader's responsibility.
import mediaNative, {
  NativeMediaApi, NativeMediaCapabilities, NativeMediaProgress, NativeMediaResult
} from 'libxdm_media.so';

export { NativeMediaApi, NativeMediaCapabilities, NativeMediaProgress, NativeMediaResult } from 'libxdm_media.so';

export type MediaProgressListener = (progress: NativeMediaProgress) => void;

const MAX_WAITING_MEDIA_JOBS: number = 16;
const MEDIA_JOB_ID: RegExp = new RegExp('^[A-Za-z0-9_.:-]{1,128}$');

class PendingMediaJob {
  jobId: string = '';
  operation: string = 'remux';
  inputVideo: string = '';
  inputAudio: string = '';
  outputPath: string = '';
  container: string = 'mp4';
  fallbackPath: string = '';
  cancelRequested: boolean = false;
  fallbackStopRequested: boolean = false;
  listener: MediaProgressListener | undefined = undefined;
  resolve: ((value: NativeMediaResult) => void) | undefined = undefined;
}

function stoppedResult(job: PendingMediaJob, status: string, code: string): NativeMediaResult {
  const result: NativeMediaResult = {
    status: status,
    errorCode: code,
    nativeCode: 0,
    phase: 'validate',
    jobId: job.jobId,
    outputPath: '',
    format: job.operation === 'mp3' ? 'mp3' : job.container,
    outputBytes: 0,
    durationMs: -1,
    warnings: []
  };
  return result;
}

function validLocalPath(path: string): boolean {
  return path.length > 1 && path.length < 4096 && path.startsWith('/') && path.indexOf('\0') < 0;
}

function validJob(job: PendingMediaJob): boolean {
  if (!MEDIA_JOB_ID.test(job.jobId) || !validLocalPath(job.inputAudio) ||
    !validLocalPath(job.outputPath) || job.outputPath === job.inputAudio) {
    return false;
  }
  if (job.operation === 'mp3') { return true; }
  if (!validLocalPath(job.inputVideo) || job.outputPath === job.inputVideo ||
    (job.container !== 'mp4' && job.container !== 'matroska')) {
    return false;
  }
  return job.fallbackPath.length === 0 || (validLocalPath(job.fallbackPath) &&
    job.fallbackPath !== job.outputPath && job.fallbackPath !== job.inputVideo && job.fallbackPath !== job.inputAudio);
}

export class MediaProcessorNapi {
  private static instance: MediaProcessorNapi | undefined = undefined;
  private readonly native: NativeMediaApi;
  private waiting: PendingMediaJob[] = [];
  private active: PendingMediaJob | undefined = undefined;
  private timerId: number = -1;
  private disposed: boolean = false;

  // A typed adapter permits testing the actual scheduling policy without a device.
  constructor(adapter: NativeMediaApi = mediaNative) {
    this.native = adapter;
  }

  static getInstance(): MediaProcessorNapi {
    if (MediaProcessorNapi.instance === undefined || MediaProcessorNapi.instance.disposed) {
      MediaProcessorNapi.instance = new MediaProcessorNapi();
    }
    return MediaProcessorNapi.instance;
  }

  capabilities(): NativeMediaCapabilities {
    return this.native.capabilities();
  }

  remux(jobId: string, inputVideo: string, inputAudio: string, temporaryOutput: string,
    container: string = 'mp4', listener?: MediaProgressListener): Promise<NativeMediaResult> {
    const job: PendingMediaJob = new PendingMediaJob();
    job.jobId = jobId;
    job.inputVideo = inputVideo;
    job.inputAudio = inputAudio;
    job.outputPath = temporaryOutput;
    job.container = container;
    job.listener = listener;
    return this.enqueue(job);
  }

  // Both names are explicitly reserved by the caller. A format change never reuses
  // a failed MP4 file or guesses the final file name from an extension.
  remuxWithFallback(jobId: string, inputVideo: string, inputAudio: string,
    temporaryMp4: string, temporaryMatroska: string,
    listener?: MediaProgressListener): Promise<NativeMediaResult> {
    const job: PendingMediaJob = new PendingMediaJob();
    job.jobId = jobId;
    job.inputVideo = inputVideo;
    job.inputAudio = inputAudio;
    job.outputPath = temporaryMp4;
    job.fallbackPath = temporaryMatroska;
    job.listener = listener;
    return this.enqueue(job);
  }

  toMp3(jobId: string, inputAudio: string, temporaryOutput: string,
    listener?: MediaProgressListener): Promise<NativeMediaResult> {
    const job: PendingMediaJob = new PendingMediaJob();
    job.jobId = jobId;
    job.operation = 'mp3';
    job.inputAudio = inputAudio;
    job.outputPath = temporaryOutput;
    job.container = 'mp3';
    job.listener = listener;
    return this.enqueue(job);
  }

  cancel(jobId: string): boolean {
    const current: PendingMediaJob | undefined = this.active;
    if (current !== undefined && current.jobId === jobId) {
      // Stop intent also covers the gap after native failure but before a possible fallback.
      // Its acknowledgement remains independent: a late native success still stays success.
      current.fallbackStopRequested = true;
      if (current.cancelRequested) { return false; }
      let accepted: boolean = false;
      try { accepted = this.native.cancel(jobId); } catch (_) { return false; }
      if (accepted) {
        current.cancelRequested = true;
        this.stopTimer();
      }
      // Native success has a commit point. A late request must not turn that
      // success into a fabricated cancelled result with a live output file.
      return accepted;
    }
    const index: number = this.waiting.findIndex((job: PendingMediaJob): boolean => job.jobId === jobId);
    if (index < 0) { return false; }
    const queued: PendingMediaJob = this.waiting[index];
    this.waiting.splice(index, 1);
    queued.cancelRequested = true;
    const resolve: ((value: NativeMediaResult) => void) | undefined = queued.resolve;
    if (resolve !== undefined) { resolve(stoppedResult(queued, 'cancelled', 'CANCELLED')); }
    return true;
  }

  progress(jobId: string): NativeMediaProgress {
    const queued: PendingMediaJob | undefined = this.waiting.find((job: PendingMediaJob): boolean => job.jobId === jobId);
    if (queued !== undefined) {
      const progress: NativeMediaProgress = {
        jobId: jobId, found: true, phase: 'queued', processedTimeMs: 0, totalTimeMs: -1, cancelRequested: false
      };
      return progress;
    }
    return this.native.progress(jobId);
  }

  // Called when the owner is destroyed. Outstanding promises still settle only
  // after native work has stopped; no progress listener survives disposal.
  dispose(): void {
    if (this.disposed) { return; }
    this.disposed = true;
    this.stopTimer();
    const pending: PendingMediaJob[] = this.waiting;
    this.waiting = [];
    for (let i: number = 0; i < pending.length; i++) {
      const job: PendingMediaJob = pending[i];
      const resolve: ((value: NativeMediaResult) => void) | undefined = job.resolve;
      if (resolve !== undefined) { resolve(stoppedResult(job, 'cancelled', 'CANCELLED')); }
    }
    const current: PendingMediaJob | undefined = this.active;
    if (current !== undefined) {
      current.listener = undefined;
      this.cancel(current.jobId);
    }
  }

  private enqueue(job: PendingMediaJob): Promise<NativeMediaResult> {
    if (this.disposed || !validJob(job) || (this.active !== undefined && this.active.jobId === job.jobId) ||
      this.waiting.some((queued: PendingMediaJob): boolean => queued.jobId === job.jobId)) {
      return Promise.resolve(stoppedResult(job, 'failed', 'INVALID_ARGUMENT'));
    }
    if (this.waiting.length >= MAX_WAITING_MEDIA_JOBS) {
      return Promise.resolve(stoppedResult(job, 'busy', 'RESOURCE_LIMIT'));
    }
    return new Promise<NativeMediaResult>((resolve: (value: NativeMediaResult) => void): void => {
      job.resolve = resolve;
      this.waiting.push(job);
      this.pump();
    });
  }

  private pump(): void {
    if (this.disposed || this.active !== undefined || this.waiting.length === 0) { return; }
    const job: PendingMediaJob = this.waiting[0];
    this.waiting.splice(0, 1);
    this.active = job;
    this.run(job);
  }

  private async run(job: PendingMediaJob): Promise<void> {
    let result: NativeMediaResult = stoppedResult(job, 'failed', 'INTERNAL');
    try {
      this.startTimer(job);
      if (job.operation === 'mp3') {
        result = await this.native.toMp3(job.jobId, job.inputAudio, job.outputPath);
      } else {
        result = await this.native.remux(job.jobId, job.inputVideo, job.inputAudio, job.outputPath, job.container);
        if (!job.fallbackStopRequested && !job.cancelRequested && !this.disposed && job.fallbackPath.length > 0 && result.status === 'failed' &&
          (result.errorCode === 'UNSUPPORTED_STREAM' || result.errorCode === 'INVALID_DATA')) {
          result = await this.native.remux(job.jobId, job.inputVideo, job.inputAudio, job.fallbackPath, 'matroska');
        }
      }
    } catch (_) {
      // Native processing failures normally resolve a Result. Bridge exceptions
      // are contained here so they cannot strand the FIFO or its callers.
      result = stoppedResult(job, 'failed', 'INTERNAL');
    } finally {
      this.stopTimer();
      this.active = undefined;
      job.listener = undefined;
      const resolve: ((value: NativeMediaResult) => void) | undefined = job.resolve;
      if (resolve !== undefined) { resolve(result); }
      this.pump();
    }
  }

  private startTimer(job: PendingMediaJob): void {
    this.stopTimer();
    if (job.listener === undefined || this.disposed) { return; }
    this.timerId = setInterval((): void => {
      if (this.active !== job || this.disposed || job.cancelRequested) { return; }
      const listener: MediaProgressListener | undefined = job.listener;
      if (listener === undefined) { return; }
      try { listener(this.native.progress(job.jobId)); } catch (_) {
        // A UI observer cannot abort media processing or retain a timer forever.
      }
    }, 1000);
  }

  private stopTimer(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }
}
