/** Local-file FFmpeg n6.0 / LAME 3.100 bridge. No operation overwrites an existing file. */
export interface NativeMediaCapabilities {
  apiVersion: number;
  ffmpegVersion: string;
  lameVersion: string;
  abi: string;
  remuxMp4: boolean;
  remuxMatroska: boolean;
  encodeMp3: boolean;
  maxActiveJobs: number;
}

export interface NativeMediaResult {
  /** success | failed | cancelled | busy */
  status: string;
  errorCode: string;
  nativeCode: number;
  phase: string;
  jobId: string;
  /** Empty on failure/cancel; caller owns publication of the successful temporary file. */
  outputPath: string;
  /** mp4 | matroska | mp3 */
  format: string;
  outputBytes: number;
  durationMs: number;
  warnings: string[];
}

export interface NativeMediaProgress {
  jobId: string;
  found: boolean;
  phase: string;
  processedTimeMs: number;
  totalTimeMs: number;
  cancelRequested: boolean;
}

export interface NativeMediaApi {
  capabilities(): NativeMediaCapabilities;
  remux(jobId: string, inputVideo: string, inputAudio: string,
    temporaryOutput: string, container: string): Promise<NativeMediaResult>;
  toMp3(jobId: string, inputAudio: string, temporaryOutput: string): Promise<NativeMediaResult>;
  /** True only when this call changed the operation to cancel-requested before commit. */
  cancel(jobId: string): boolean;
  progress(jobId: string): NativeMediaProgress;
}

declare const mediaNative: NativeMediaApi;
export default mediaNative;
