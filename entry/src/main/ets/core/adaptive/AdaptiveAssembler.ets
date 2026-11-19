// Exact committed prefixes become local temporary outputs; publication and DB completion are separate.
import { fileIo, ReadOptions } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { AdaptiveDownloadState, AdaptivePartState } from './AdaptivePlan';
import { encodeAdaptiveState, decodeAdaptiveState } from './AdaptiveStateCodec';
import { AdaptiveAttemptFile, AttemptFileResult, ATTEMPT_MAX_BLOCK_BYTES } from './AdaptiveAttemptFile';
import { MediaProcessorNapi, NativeMediaProgress, NativeMediaResult } from '../media/MediaProcessorNapi';

export class AdaptiveAssemblyProgress {
  phase: string = 'concat';
  copiedBytes: number = 0;
  totalInputBytes: number = 0;
  processedTimeMs: number = 0;
  totalTimeMs: number = -1;
}

export type AdaptiveAssemblyListener = (progress: AdaptiveAssemblyProgress) => void;

export class AdaptiveAssemblyResult {
  status: string = 'new';
  errorCode: string = '';
  ioErrorCode: number = 0;
  outputName: string = '';
  outputBytes: number = 0;
  extension: string = '';
  retainedNames: string[] = [];
  warnings: string[] = [];
  closed: boolean = true;
  resourceUncertain: boolean = false;
  cleanupComplete: boolean = true;
  mediaStarted: boolean = false;
  mediaSettled: boolean = false;
  stopRequested: boolean = false;
}

class AssemblyFault extends Error {
  status: string;
  errorCode: string;
  ioErrorCode: number;

  constructor(status: string, code: string, numeric: number = 0) {
    super('Adaptive assembly failed');
    this.status = status; this.errorCode = code; this.ioErrorCode = numeric;
  }
}

class AssemblyReader {
  file: fileIo.File | null = null;
  closed: boolean = true;
  closeAttempted: boolean = false;
}

class AssemblyWriter {
  name: string;
  limit: number;
  writer: AdaptiveAttemptFile;
  last: AttemptFileResult = new AttemptFileResult();

  constructor(base: string, id: string, name: string, limit: number) {
    this.name = name; this.limit = limit;
    this.writer = new AdaptiveAttemptFile(base, id, name, limit);
  }
}

type AssemblyCompletion = (value: AdaptiveAssemblyResult) => void;

function safeBytes(value: number): boolean { return Number.isSafeInteger(value) && value >= 0; }

function safeCode(error: Object): number {
  try {
    const code: number | undefined = (error as BusinessError)?.code;
    return code !== undefined && safeBytes(code) ? code : 0;
  } catch (_) { return 0; }
}

function validUuid(value: string): boolean {
  return typeof value === 'string' &&
    new RegExp('^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$').test(value);
}

function assemblyBase(value: string): string {
  if (typeof value !== 'string' || value.length === 0 || value.length > 4096 ||
    value.indexOf('://') >= 0 || new RegExp('[\\x00-\\x1f\\x7f]').test(value)) { return ''; }
  const normalized: string = value.replace(new RegExp('\\\\', 'g'), '/');
  let root: string = '';
  if (new RegExp('^[A-Za-z]:/').test(normalized)) { root = normalized.substring(0, 3); }
  else if (normalized.startsWith('/')) { root = '/'; }
  else { return ''; }
  const parts: string[] = normalized.substring(root.length).split('/');
  const kept: string[] = [];
  for (let i = 0; i < parts.length; i++) {
    if (parts[i] === '' || parts[i] === '.') { continue; }
    if (parts[i] === '..') {
      if (kept.length === 0) { return ''; }
      kept.pop();
    } else { kept.push(parts[i]); }
  }
  return root + kept.join('/');
}

function copyAssemblyResult(source: AdaptiveAssemblyResult): AdaptiveAssemblyResult {
  const copied: AdaptiveAssemblyResult = new AdaptiveAssemblyResult();
  copied.status = source.status; copied.errorCode = source.errorCode; copied.ioErrorCode = source.ioErrorCode;
  copied.outputName = source.outputName; copied.outputBytes = source.outputBytes; copied.extension = source.extension;
  copied.retainedNames = source.retainedNames.slice(); copied.warnings = source.warnings.slice();
  copied.closed = source.closed; copied.resourceUncertain = source.resourceUncertain;
  copied.cleanupComplete = source.cleanupComplete; copied.mediaStarted = source.mediaStarted;
  copied.mediaSettled = source.mediaSettled; copied.stopRequested = source.stopRequested;
  return copied;
}

/** One assembly lifetime. Its caller retains the download directory lease through actual drain. */
export class AdaptiveAssembler {
  private readonly base: string;
  private readonly downloadId: string;
  private readonly processor: MediaProcessorNapi;
  private directory: string = '';
  private valid: boolean = false;
  private started: boolean = false;
  private ended: boolean = false;
  private stopped: boolean = false;
  private uncertain: boolean = false;
  private cleanupComplete: boolean = true;
  private closeCode: number = 0;
  private reader: AssemblyReader = new AssemblyReader();
  private writers: AssemblyWriter[] = [];
  private tracks: number[][] = [];
  private totals: number[] = [];
  private totalInputBytes: number = 0;
  private copiedBytes: number = 0;
  private names: string[] = [];
  private retainedNames: string[] = [];
  private warningCodes: string[] = [];
  private mediaJobId: string = '';
  private mp4Name: string = '';
  private mkvName: string = '';
  private mediaStarted: boolean = false;
  private mediaSettled: boolean = false;
  private mediaCancelIssued: boolean = false;
  private mediaOutputNames: string[] = [];
  private mediaOutputsAudited: boolean = false;
  private listener: AdaptiveAssemblyListener | undefined = undefined;
  private lastProgressMs: number = 0;
  private completion: AssemblyCompletion | undefined = undefined;
  private finalResult: AdaptiveAssemblyResult = new AdaptiveAssemblyResult();
  private barrier: Promise<AdaptiveAssemblyResult> = Promise.resolve<AdaptiveAssemblyResult>(new AdaptiveAssemblyResult());

  constructor(tempBase: string, downloadId: string, processor: MediaProcessorNapi = MediaProcessorNapi.getInstance()) {
    this.base = assemblyBase(tempBase); this.downloadId = downloadId; this.processor = processor;
    this.valid = this.base !== '' && validUuid(downloadId);
    if (this.valid) { this.directory = this.base + (this.base.endsWith('/') ? '' : '/') + downloadId; }
  }

  run(state: AdaptiveDownloadState, listener?: AdaptiveAssemblyListener): Promise<AdaptiveAssemblyResult> {
    if (this.started) { return this.immediate(this.ended ? 'invalid' : 'busy', 'AssemblyAlreadyStarted'); }
    this.started = true; this.listener = listener;
    // Publish the barrier before any input getter, callback, or IO can re-enter this owner.
    this.barrier = new Promise<AdaptiveAssemblyResult>((resolve: AssemblyCompletion): void => { this.completion = resolve; });
    try {
      if (!this.valid) { throw new AssemblyFault('invalid', 'InvalidAssemblyInput'); }
      this.checkStop();
      const captured: AdaptiveDownloadState | null = decodeAdaptiveState(encodeAdaptiveState(state), this.downloadId);
      if (captured === null) { throw new AssemblyFault('invalid', 'InvalidAssemblyState'); }
      this.prepare(captured);
      // Input capture above is synchronous. Async work always stays attached to the published barrier.
      this.execute(captured).catch(async (): Promise<void> => {
        this.uncertain = true;
        await this.cleanup();
        this.finish('ioError', 'AssemblyUnexpectedFailure', 0, '', 0, '');
      });
    } catch (error) {
      const fault: AssemblyFault = error instanceof AssemblyFault ? error : new AssemblyFault('invalid', 'InvalidAssemblyState');
      this.finish(fault.status, fault.errorCode, fault.ioErrorCode, '', 0, '');
    }
    return this.drain();
  }

  cancel(): void {
    if (this.ended || this.stopped) { return; }
    this.stopped = true;
    for (let i = 0; i < this.writers.length; i++) { this.writers[i].writer.dispose(); }
    if (this.mediaStarted && !this.mediaSettled && !this.mediaCancelIssued) {
      this.mediaCancelIssued = true;
      try { this.processor.cancel(this.mediaJobId); } catch (_) {}
    }
  }

  drain(): Promise<AdaptiveAssemblyResult> {
    if (!this.started) {
      return this.immediate(this.valid ? 'new' : 'invalid', this.valid ? '' : 'InvalidAssemblyInput');
    }
    return this.barrier.then<AdaptiveAssemblyResult>((value: AdaptiveAssemblyResult): AdaptiveAssemblyResult => copyAssemblyResult(value));
  }

  private immediate(status: string, code: string): Promise<AdaptiveAssemblyResult> {
    const value: AdaptiveAssemblyResult = new AdaptiveAssemblyResult();
    value.status = status; value.errorCode = code; value.stopRequested = this.stopped;
    return Promise.resolve<AdaptiveAssemblyResult>(value);
  }

  private checkStop(): void {
    if (this.stopped) { throw new AssemblyFault('stopped', 'AssemblyStopped'); }
  }

  private prepare(state: AdaptiveDownloadState): void {
    if (state.plan.tracks.length < 1 || state.plan.tracks.length > 2) {
      throw new AssemblyFault('invalid', 'InvalidAssemblyState');
    }
    for (let i = 0; i < state.plan.tracks.length; i++) { this.tracks.push([]); this.totals.push(0); }
    for (let i = 0; i < state.parts.length; i++) {
      const part: AdaptivePartState = state.parts[i];
      const track: number = state.plan.chunks[i].trackIndex;
      if (!part.complete || !safeBytes(part.downloaded) || part.fileName.length === 0 ||
        state.plan.chunks[i].trackOrder !== this.tracks[track].length ||
        part.downloaded > Number.MAX_SAFE_INTEGER - this.totals[track] ||
        part.downloaded > Number.MAX_SAFE_INTEGER - this.totalInputBytes) {
        throw new AssemblyFault('invalid', 'IncompleteAssemblyInput');
      }
      this.tracks[track].push(i); this.totals[track] += part.downloaded; this.totalInputBytes += part.downloaded;
    }
    const id: string = util.generateRandomUUID(true);
    if (!validUuid(id)) { throw new AssemblyFault('invalid', 'InvalidAssemblyIdentity'); }
    for (let i = 0; i < this.tracks.length; i++) { this.names.push('asm-' + id + '-' + String(i) + '.part'); }
    this.mediaJobId = 'asm-' + id; this.mp4Name = 'asm-' + id + '.mp4'; this.mkvName = 'asm-' + id + '.mkv';
  }

  private retain(name: string): void {
    if (this.retainedNames.indexOf(name) < 0) { this.retainedNames.push(name); }
  }

  private rememberWriter(owner: AssemblyWriter, observed: AttemptFileResult): void {
    owner.last = observed;
    if (observed.resourceUncertain) { this.uncertain = true; }
    if (observed.sealed && observed.closed && !observed.resourceUncertain &&
      observed.fileName === owner.name && observed.confirmedBytes === owner.limit) { this.retain(owner.name); }
  }

  private requireWriter(observed: AttemptFileResult, expected: string): void {
    if (observed.status === expected && !observed.resourceUncertain &&
      (expected !== 'sealed' || (observed.sealed && observed.closed && observed.cleanupComplete))) { return; }
    if (observed.status === 'disposed' && this.stopped && !observed.resourceUncertain) {
      throw new AssemblyFault('stopped', 'AssemblyStopped');
    }
    throw new AssemblyFault('ioError', 'AssemblyCandidateFailure', observed.errorCode);
  }

  private async execute(state: AdaptiveDownloadState): Promise<void> {
    let fault: AssemblyFault | null = null;
    let outputName: string = '';
    let outputBytes: number = 0;
    let extension: string = '';
    try {
      this.checkStop();
      const directory: fileIo.Stat = await fileIo.lstat(this.directory);
      this.checkStop();
      if (!directory.isDirectory()) { throw new AssemblyFault('ioError', 'AssemblyDirectoryUnavailable'); }
      for (let track = 0; track < this.tracks.length; track++) {
        await this.concatTrack(state, track);
        this.checkStop();
      }
      if (this.tracks.length === 1) {
        outputName = this.names[0]; outputBytes = this.totals[0]; extension = state.plan.suggestedExtension;
      } else {
        const media: NativeMediaResult = await this.processMedia(state.plan.suggestedExtension);
        // processMedia adopts a verified native success before observing cancellation.
        this.checkStop();
        extension = media.format === 'mp4' ? '.mp4' : '.mkv';
        outputName = media.format === 'mp4' ? this.mp4Name : this.mkvName;
        outputBytes = media.outputBytes;
      }
    } catch (error) {
      fault = error instanceof AssemblyFault ? error : new AssemblyFault('ioError', 'AssemblyIoFailure', safeCode(error as Error));
    }
    await this.cleanup();
    if (!this.allClosed() || !this.cleanupComplete) {
      if (fault === null || fault.status === 'stopped') {
        fault = new AssemblyFault('ioError', this.uncertain ? 'AssemblyResourceUncertain' : 'AssemblyCleanupIncomplete', this.closeCode);
      }
    }
    if (fault === null && this.stopped) { fault = new AssemblyFault('stopped', 'AssemblyStopped'); }
    if (fault !== null) { this.finish(fault.status, fault.errorCode, fault.ioErrorCode, '', 0, ''); }
    else { this.finish('success', '', 0, outputName, outputBytes, extension); }
  }

  private ordinarySize(stat: fileIo.Stat, required: number): void {
    if (!stat.isFile() || !safeBytes(stat.size) || stat.size < required) {
      throw new AssemblyFault('ioError', 'AssemblyInputUnavailable');
    }
  }

  private async concatTrack(state: AdaptiveDownloadState, track: number): Promise<void> {
    this.checkStop();
    const owner: AssemblyWriter = new AssemblyWriter(this.base, this.downloadId, this.names[track], this.totals[track]);
    // Register before the first E2 call so re-entrant cancellation sees every owner.
    this.writers.push(owner);
    const opened: AttemptFileResult = await owner.writer.open('', 0);
    this.rememberWriter(owner, opened); this.requireWriter(opened, 'opened');
    if (opened.fileName !== owner.name || opened.confirmedBytes !== 0) {
      throw new AssemblyFault('ioError', 'AssemblyCandidateMismatch');
    }
    this.checkStop();
    const indices: number[] = this.tracks[track];
    for (let i = 0; i < indices.length; i++) {
      await this.copyPart(state.parts[indices[i]], owner);
      this.checkStop();
    }
    const sealed: AttemptFileResult = await owner.writer.seal(owner.limit);
    this.rememberWriter(owner, sealed); this.requireWriter(sealed, 'sealed');
    if (sealed.fileName !== owner.name || sealed.confirmedBytes !== owner.limit) {
      throw new AssemblyFault('ioError', 'AssemblyCandidateMismatch');
    }
    this.checkStop();
    this.notifyConcat(true);
    this.checkStop();
  }

  private async copyPart(part: AdaptivePartState, writer: AssemblyWriter): Promise<void> {
    this.checkStop();
    const path: string = this.directory + '/' + part.fileName;
    const metadata: fileIo.Stat = await fileIo.lstat(path);
    this.ordinarySize(metadata, part.downloaded); this.checkStop();
    const owner: AssemblyReader = new AssemblyReader();
    this.reader = owner;
    try {
      const file: fileIo.File = await fileIo.open(path, fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.NOFOLLOW);
      owner.file = file; owner.closed = false;
      this.checkStop();
      const actual: fileIo.Stat = await fileIo.stat(file.fd);
      this.ordinarySize(actual, part.downloaded); this.checkStop();
      const buffer: ArrayBuffer = new ArrayBuffer(Math.min(ATTEMPT_MAX_BLOCK_BYTES, part.downloaded));
      let consumed: number = 0;
      while (consumed < part.downloaded) {
        const length: number = Math.min(buffer.byteLength, part.downloaded - consumed);
        const options: ReadOptions = { length: length };
        const count: number = await fileIo.read(file.fd, buffer, options);
        if (!safeBytes(count) || count === 0 || count > length) {
          throw new AssemblyFault('ioError', 'AssemblyShortInput');
        }
        this.checkStop();
        const expected: number = writer.last.confirmedBytes + count;
        const appended: AttemptFileResult = await writer.writer.append(buffer.slice(0, count));
        this.rememberWriter(writer, appended); this.requireWriter(appended, 'appended');
        if (appended.fileName !== writer.name || appended.confirmedBytes !== expected) {
          throw new AssemblyFault('ioError', 'AssemblyCandidateMismatch');
        }
        consumed += count; this.copiedBytes += count;
        this.checkStop();
        this.notifyConcat(false);
        this.checkStop();
      }
    } finally { await this.closeReader(owner); }
    if (!owner.closed) { throw new AssemblyFault('ioError', 'AssemblyInputCloseFailure', this.closeCode); }
    this.checkStop();
  }

  private async closeReader(owner: AssemblyReader): Promise<void> {
    const file: fileIo.File | null = owner.file;
    if (file === null || owner.closeAttempted) { return; }
    owner.closeAttempted = true; owner.file = null;
    try { await fileIo.close(file); owner.closed = true; }
    catch (error) { this.uncertain = true; this.closeCode = safeCode(error as Error); }
  }

  private async requireAbsent(name: string): Promise<void> {
    let absent: boolean = false;
    try { await fileIo.lstat(this.directory + '/' + name); }
    catch (error) {
      if (safeCode(error as Error) !== 13900002) { throw new AssemblyFault('ioError', 'AssemblyOutputUnavailable', safeCode(error as Error)); }
      absent = true;
    }
    if (!absent) { throw new AssemblyFault('ioError', 'AssemblyOutputCollision'); }
    this.checkStop();
  }

  private mediaErrorCode(value: string): string {
    const allowed: string[] = ['INVALID_ARGUMENT', 'INPUT_NOT_FOUND', 'INPUT_IO', 'OUTPUT_IO', 'OUTPUT_EXISTS',
      'INVALID_DATA', 'UNSUPPORTED_STREAM', 'CODEC_UNAVAILABLE', 'RESOURCE_LIMIT', 'BUSY', 'CANCELLED', 'INTERNAL'];
    return allowed.indexOf(value) >= 0 ? 'Media_' + value : 'AssemblyMediaFailure';
  }

  private captureWarnings(warnings: string[]): void {
    const allowed: string[] = ['UNSUPPORTED_COVER_ART', 'INVALID_COVER_ART', 'CHAPTERS_NOT_COPIED'];
    for (let i = 0; i < Math.min(warnings.length, 16); i++) {
      const code: string = allowed.indexOf(warnings[i]) >= 0 ? warnings[i] : 'UNRECOGNIZED_MEDIA_WARNING';
      if (this.warningCodes.indexOf(code) < 0) { this.warningCodes.push(code); }
    }
    if (warnings.length > 16 && this.warningCodes.indexOf('UNRECOGNIZED_MEDIA_WARNING') < 0) {
      this.warningCodes.push('UNRECOGNIZED_MEDIA_WARNING');
    }
  }

  private async processMedia(extension: string): Promise<NativeMediaResult> {
    this.checkStop();
    const directMkv: boolean = extension === '.mkv';
    if (!directMkv) { await this.requireAbsent(this.mp4Name); this.checkStop(); }
    await this.requireAbsent(this.mkvName); this.checkStop();
    const video: string = this.directory + '/' + this.names[0];
    const audio: string = this.directory + '/' + this.names[1];
    const mp4: string = this.directory + '/' + this.mp4Name;
    const mkv: string = this.directory + '/' + this.mkvName;
    const listener: (progress: NativeMediaProgress) => void = (progress: NativeMediaProgress): void => this.notifyMedia(progress);
    let observed: NativeMediaResult;
    this.mediaOutputNames = directMkv ? [this.mkvName] : [this.mp4Name, this.mkvName];
    this.mediaStarted = true;
    try {
      observed = directMkv ? await this.processor.remux(this.mediaJobId, video, audio, mkv, 'matroska', listener) :
        await this.processor.remuxWithFallback(this.mediaJobId, video, audio, mp4, mkv, listener);
      this.mediaSettled = true;
    } catch (error) {
      this.mediaSettled = true; this.uncertain = true;
      throw new AssemblyFault('mediaError', 'AssemblyMediaBridgeFailure');
    }
    if (observed === null || typeof observed !== 'object' || observed.jobId !== this.mediaJobId ||
      !Array.isArray(observed.warnings)) {
      this.cleanupComplete = false;
      throw new AssemblyFault('mediaError', 'AssemblyMediaReceiptMismatch');
    }
    this.captureWarnings(observed.warnings);
    if (observed.status !== 'success') {
      if (observed.status === 'cancelled' && this.stopped) { throw new AssemblyFault('stopped', 'AssemblyStopped'); }
      throw new AssemblyFault('mediaError', this.mediaErrorCode(observed.errorCode));
    }
    const isMp4: boolean = !directMkv && observed.format === 'mp4' && observed.outputPath === mp4;
    const isMkv: boolean = observed.format === 'matroska' && observed.outputPath === mkv;
    if ((!isMp4 && !isMkv) || !safeBytes(observed.outputBytes)) {
      this.cleanupComplete = false;
      throw new AssemblyFault('mediaError', 'AssemblyMediaReceiptMismatch');
    }
    // A successful native return is adopted even when cancellation occurred during its await.
    let output: fileIo.Stat;
    try { output = await fileIo.lstat(observed.outputPath); }
    catch (error) {
      this.cleanupComplete = false;
      throw new AssemblyFault('mediaError', 'AssemblyMediaOutputUnavailable', safeCode(error as Error));
    }
    if (!output.isFile() || !safeBytes(output.size) || output.size !== observed.outputBytes) {
      this.cleanupComplete = false;
      throw new AssemblyFault('mediaError', 'AssemblyMediaOutputMismatch');
    }
    this.retain(isMp4 ? this.mp4Name : this.mkvName);
    this.checkStop();
    return observed;
  }

  private notifyConcat(force: boolean): void {
    const value: AdaptiveAssemblyProgress = new AdaptiveAssemblyProgress();
    value.copiedBytes = this.copiedBytes; value.totalInputBytes = this.totalInputBytes;
    this.notify(value, force);
  }

  private notifyMedia(observed: NativeMediaProgress): void {
    if (this.ended || this.stopped || !this.mediaStarted || this.mediaSettled || !observed.found ||
      observed.jobId !== this.mediaJobId || !safeBytes(observed.processedTimeMs) ||
      (observed.totalTimeMs !== -1 && !safeBytes(observed.totalTimeMs))) { return; }
    const value: AdaptiveAssemblyProgress = new AdaptiveAssemblyProgress();
    value.phase = 'media'; value.copiedBytes = this.copiedBytes; value.totalInputBytes = this.totalInputBytes;
    value.processedTimeMs = observed.processedTimeMs; value.totalTimeMs = observed.totalTimeMs;
    this.notify(value, false);
  }

  private notify(value: AdaptiveAssemblyProgress, force: boolean): void {
    if (this.ended || this.stopped || this.listener === undefined) { return; }
    const now: number = Date.now();
    if (!force && this.lastProgressMs > 0 && now >= this.lastProgressMs && now - this.lastProgressMs < 200) { return; }
    this.lastProgressMs = now;
    try { this.listener(value); } catch (_) {}
  }

  private async cleanup(): Promise<void> {
    await this.closeReader(this.reader);
    for (let i = 0; i < this.writers.length; i++) {
      const owner: AssemblyWriter = this.writers[i];
      try {
        owner.writer.dispose();
        const ended: AttemptFileResult = await owner.writer.drain();
        this.rememberWriter(owner, ended);
        if (!ended.closed || !ended.cleanupComplete || ended.resourceUncertain) { this.cleanupComplete = false; }
      } catch (_) { this.uncertain = true; this.cleanupComplete = false; }
    }
    await this.auditMediaOutputs();
    if (!this.reader.closed || this.uncertain) { this.cleanupComplete = false; }
  }

  private async auditMediaOutputs(): Promise<void> {
    if (!this.mediaStarted || !this.mediaSettled || this.mediaOutputsAudited) { return; }
    this.mediaOutputsAudited = true;
    for (let i = 0; i < this.mediaOutputNames.length; i++) {
      const name: string = this.mediaOutputNames[i];
      if (this.retainedNames.indexOf(name) >= 0) { continue; }
      // Native failure cleanup is best effort, and a bridge error can hide a committed output.
      // Only ENOENT establishes absence. Do not claim or delete an unverified artifact.
      try {
        await fileIo.lstat(this.directory + '/' + name);
        this.cleanupComplete = false;
      } catch (error) {
        const code: number = safeCode(error as Error);
        if (code !== 13900002) {
          this.cleanupComplete = false;
          if (this.closeCode === 0) { this.closeCode = code; }
        }
      }
    }
  }

  private allClosed(): boolean {
    if (!this.reader.closed || this.uncertain || (this.mediaStarted && !this.mediaSettled)) { return false; }
    for (let i = 0; i < this.writers.length; i++) { if (!this.writers[i].last.closed) { return false; } }
    return true;
  }

  private finish(status: string, code: string, numeric: number, name: string, bytes: number, extension: string): void {
    if (this.ended) { return; }
    const value: AdaptiveAssemblyResult = new AdaptiveAssemblyResult();
    value.status = status; value.errorCode = code; value.ioErrorCode = numeric;
    value.outputName = name; value.outputBytes = bytes; value.extension = extension;
    value.retainedNames = this.retainedNames.slice(); value.warnings = this.warningCodes.slice();
    value.closed = this.allClosed(); value.resourceUncertain = this.uncertain;
    value.cleanupComplete = this.cleanupComplete; value.mediaStarted = this.mediaStarted;
    value.mediaSettled = this.mediaSettled; value.stopRequested = this.stopped;
    this.finalResult = value; this.ended = true; this.listener = undefined;
    const complete: AssemblyCompletion | undefined = this.completion;
    this.completion = undefined;
    if (complete !== undefined) { complete(value); }
  }
}
