/*
 * HLS/DASH/dual-source business downloader (u6-4 outer integration O3/O6a/O7, pragmatic slice).
 * Same lifecycle and event surface as the HTTP Downloader so DownloadManager/Index consume it
 * unchanged: start/resume/stop/isRunning + the six DownloadEvents.
 *
 * One business run:
 *   onStarted -> E4 resume-first child (freshPlan=null)
 *     -> only an exact C.empty result (failed/AdaptivePlanMissing/released, no state, no lease)
 *        fetches the selected media playlists (HLS) or uses captured segments (DASH/dual)
 *        and starts a second E4 child with the fresh plan
 *   -> ready lease -> AdaptiveAssembler (concat or native remux) -> move the output into the
 *      download directory under a unique name -> release lease -> clean the temp directory
 *   -> onFinished(id, bytes, path); Index then commits the Store row and copies to the user folder.
 *
 * Pause: stop() pauses E4 / cancels assembly and manifest work; the owned work drains before
 * onPaused. Restart resumes from the persisted C state (no manifest traffic once a plan exists).
 * Known gaps (DELIVERY D tier): no live-prefix checkpoints inside a single long chunk (O5b),
 * POST manifest discovery, per-source auth/proxy (O4), dual-source second header set, and the
 * outbox-based completion receipt (O6b) - completion uses the same Index/Store path as Http.
 */

import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DownloadEvents, NoopDownloadEvents } from './Downloader';
import { resolveRunRequest } from './DownloadRequestState';
import { DownloadRecord } from '../../model/DownloadRecord';
import { DownloadRunRequest } from '../../model/DownloadRunRequest';
import { AdaptiveSourceDescriptor } from '../../model/AdaptiveSource';
import { Config } from '../Config';
import { getUniqueFileName } from '../util/FileNames';
import { AdaptivePlan, buildDashPlan, buildHlsPlan } from '../adaptive/AdaptivePlan';
import { AdaptiveReadyInput, AdaptiveRunController, AdaptiveRunInput, AdaptiveRunProgress,
  AdaptiveRunResult } from '../adaptive/AdaptiveRunController';
import { AdaptiveThrottlePolicy } from '../adaptive/AdaptiveDownloadThrottle';
import { AdaptiveAssembler, AdaptiveAssemblyProgress, AdaptiveAssemblyResult } from '../adaptive/AdaptiveAssembler';
import { ManifestClient, ManifestFetchResult } from '../adaptive/ManifestClient';
import { parseHlsMediaPlaylist } from '../adaptive/HlsParser';
import { HlsPlaylist } from '../adaptive/HlsModel';
import { resolveHlsUrl } from '../adaptive/HlsUrlResolver';
import { StateStore } from '../db/StateStore';
import { setAdaptiveHeadRejectSink } from '../adaptive/AdaptiveAttemptExecutor';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'AdaptiveDownloader';
const PROGRESS_INTERVAL_MS: number = 1000;
const MANIFEST_TIMEOUT_MS: number = 30000;
const MAX_SEGMENTS_PER_RUN: number = 64;

setAdaptiveHeadRejectSink((chunkId: string, status: number, code: string): void => {
  hilog.warn(LOG_DOMAIN, LOG_TAG, '%{public}s', 'segment rejected chunk=' + chunkId + ' status=' + String(status) +
    ' code=' + code);
});

/** Numeric failure codes for the existing numeric onFailed surface (string code goes to hilog). */
export const ADAPTIVE_ERR_SOURCE: number = 3001;
export const ADAPTIVE_ERR_MANIFEST: number = 3002;
export const ADAPTIVE_ERR_UNSUPPORTED: number = 3003;
export const ADAPTIVE_ERR_DOWNLOAD: number = 3004;
export const ADAPTIVE_ERR_ASSEMBLY: number = 3005;
export const ADAPTIVE_ERR_PUBLISH: number = 3006;
export const ADAPTIVE_ERR_RESOURCE: number = 3007;

class AdaptiveFault extends Error {
  code: number;
  detail: string;

  constructor(code: number, detail: string) {
    super('Adaptive download failed');
    this.code = code;
    this.detail = detail;
  }
}

/** Media/manifest extensions replaced by the assembled container extension. */
const REPLACEABLE_EXTENSIONS: string[] = ['.ts', '.mp4', '.mkv', '.webm', '.m4v', '.m4a', '.m3u8', '.mpd',
  '.mp3', '.aac', '.m4s'];

export function adaptiveOutputName(recordName: string | null, extension: string): string {
  let stem: string = recordName !== null && recordName.trim().length > 0 ? recordName.trim() : 'video';
  for (let guard = 0; guard < 3; guard++) {
    const dot: number = stem.lastIndexOf('.');
    if (dot <= 0) { break; }
    const ext: string = stem.substring(dot).toLowerCase();
    if (REPLACEABLE_EXTENSIONS.indexOf(ext) < 0) { break; }
    stem = stem.substring(0, dot);
  }
  const suffix: string = extension.startsWith('.') ? extension : '.' + extension;
  return stem + (suffix === '.' ? '.mkv' : suffix);
}

export class AdaptiveDownloader {
  private readonly record: DownloadRecord;
  private readonly events: DownloadEvents;
  private running: boolean = false;
  private stopRequested: boolean = false;
  private controller: AdaptiveRunController | null = null;
  private assembler: AdaptiveAssembler | null = null;
  private manifest: ManifestClient | null = null;
  private progressTimer: number = -1;
  private lastWritten: number = 0;
  private lastSampleAt: number = 0;
  private speed: number = 0;
  private connected: boolean = false;
  private latestSealedBytes: number = 0;
  private lastAssemblyEvent: number = 0;

  constructor(record: DownloadRecord, events?: DownloadEvents) {
    this.record = record;
    this.events = events ?? new NoopDownloadEvents();
  }

  start(): void {
    this.launch();
  }

  /** Resume and start share one path: E4 restores the persisted plan before any manifest IO. */
  resume(): void {
    this.launch();
  }

  stop(): void {
    if (!this.running || this.stopRequested) {
      return;
    }
    this.stopRequested = true;
    const controller: AdaptiveRunController | null = this.controller;
    if (controller !== null) { controller.pause(); }
    const assembler: AdaptiveAssembler | null = this.assembler;
    if (assembler !== null) { assembler.cancel(); }
    const manifest: ManifestClient | null = this.manifest;
    if (manifest !== null) { manifest.cancel(); }
  }

  isRunning(): boolean {
    return this.running;
  }

  private launch(): void {
    if (this.running) {
      return;
    }
    this.running = true;
    this.stopRequested = false;
    this.connected = false;
    this.execute().catch((): void => {
      // execute() reports every outcome itself; this only guards an unexpected rejection.
      this.finishFailed(ADAPTIVE_ERR_DOWNLOAD, 'AdaptiveUnexpected');
    });
  }

  private async execute(): Promise<void> {
    this.events.onStarted(this.record.id);
    try {
      const tempBase: string = Config.getInstance().getTempDir();
      try { await fileIo.mkdir(tempBase, true); } catch (_) { /* exists */ }
      let result: AdaptiveRunResult = await this.runChild(tempBase, null);
      if (this.isPlanMissing(result)) {
        if (this.stopRequested) { this.finishPaused(); return; }
        const plan: AdaptivePlan = await this.buildPlan();
        if (this.stopRequested) { this.finishPaused(); return; }
        result = await this.runChild(tempBase, plan);
      }
      await this.consume(tempBase, result);
    } catch (e) {
      if (e instanceof AdaptiveFault) {
        if (this.stopRequested && e.code === ADAPTIVE_ERR_MANIFEST) { this.finishPaused(); return; }
        this.finishFailed(e.code, e.detail);
      } else {
        this.finishFailed(ADAPTIVE_ERR_DOWNLOAD, 'AdaptiveUnexpected');
      }
    }
  }

  /** Exact C.empty: the only state that authorizes manifest traffic and a fresh plan. */
  private isPlanMissing(result: AdaptiveRunResult): boolean {
    return result.kind === 'failed' && result.errorCode === 'AdaptivePlanMissing' &&
      result.ownerDisposition === 'released' && result.durableState === null && result.ready === null;
  }

  private runInput(tempBase: string, plan: AdaptivePlan | null): AdaptiveRunInput {
    const input: AdaptiveRunInput = new AdaptiveRunInput();
    input.downloadId = this.record.id;
    input.runToken = util.generateRandomUUID(true);
    input.tempBase = tempBase;
    input.freshPlan = plan;
    const request: DownloadRunRequest = resolveRunRequest(this.record);
    input.request = request;
    const config: Config = Config.getInstance();
    const segments: number = config.getMaxSegments();
    input.limits.maxSegments = Number.isSafeInteger(segments) && segments > 0
      ? Math.min(segments, MAX_SEGMENTS_PER_RUN) : 8;
    const retry: number = config.getMaxRetry();
    input.limits.maxRetry = Number.isSafeInteger(retry) && retry >= 0 ? retry : 10;
    const delay: number = config.getRetryDelay();
    input.limits.retryDelayMs = Number.isSafeInteger(delay) && delay >= 0 ? delay * 1000 : 5000;
    input.networkTimeoutSeconds = config.getNetworkTimeout();
    return input;
  }

  private policy(): AdaptiveThrottlePolicy {
    const policy: AdaptiveThrottlePolicy = new AdaptiveThrottlePolicy();
    const config: Config = Config.getInstance();
    policy.globalEnabled = config.getEnableSpeedLimit() && config.getDefaultDownloadSpeed() > 0;
    policy.globalKiBps = policy.globalEnabled ? config.getDefaultDownloadSpeed() : 0;
    policy.taskKiBps = this.record.maxSpeedLimitInKiB > 0 ? this.record.maxSpeedLimitInKiB : 0;
    return policy;
  }

  private async runChild(tempBase: string, plan: AdaptivePlan | null): Promise<AdaptiveRunResult> {
    let input: AdaptiveRunInput;
    try {
      input = this.runInput(tempBase, plan);
    } catch (_) {
      throw new AdaptiveFault(ADAPTIVE_ERR_SOURCE, 'AdaptiveRequestUnavailable');
    }
    const controller: AdaptiveRunController = new AdaptiveRunController(input,
      (): AdaptiveThrottlePolicy => this.policy());
    this.controller = controller;
    if (this.stopRequested) { controller.pause(); }
    this.startProgress();
    try {
      return await controller.run();
    } finally {
      this.stopProgress();
      this.sample(controller.progressSnapshot());
      this.controller = null;
    }
  }

  private async buildPlan(): Promise<AdaptivePlan> {
    const source: AdaptiveSourceDescriptor | null = this.record.adaptiveSource;
    if (source === null) {
      throw new AdaptiveFault(ADAPTIVE_ERR_SOURCE, 'AdaptiveSourceMissing');
    }
    let plan: AdaptivePlan | null = null;
    if (source.kind === 'dash') {
      plan = buildDashPlan(source.primaryUrl, source.videoSegments, source.videoMime, source.audioSegments,
        source.audioMime, source.duration, source.duration);
    } else if (source.kind === 'dual') {
      plan = buildDashPlan(source.primaryUrl, [source.primaryUrl], source.videoMime, [source.secondaryUrl],
        source.audioMime, 0, 0);
    } else {
      const primary: HlsPlaylist = await this.fetchPlaylist(source.primaryUrl);
      let secondary: HlsPlaylist | null = null;
      if (source.secondaryUrl.length > 0) {
        secondary = await this.fetchPlaylist(source.secondaryUrl);
      }
      if (primary.isEncrypted || primary.isKeyIFrameOnly || (secondary !== null &&
        (secondary.isEncrypted || secondary.isKeyIFrameOnly))) {
        throw new AdaptiveFault(ADAPTIVE_ERR_UNSUPPORTED, 'AdaptiveEncryptedOrIFrameOnly');
      }
      plan = buildHlsPlan(source.primaryUrl, primary, secondary === null ? '' : source.secondaryUrl, secondary);
    }
    if (plan === null) {
      throw new AdaptiveFault(ADAPTIVE_ERR_UNSUPPORTED, 'AdaptivePlanRejected');
    }
    return plan;
  }

  private async fetchPlaylist(url: string): Promise<HlsPlaylist> {
    const client: ManifestClient = new ManifestClient();
    this.manifest = client;
    let fetched: ManifestFetchResult;
    try {
      const request: DownloadRunRequest = resolveRunRequest(this.record);
      fetched = await client.fetchGet(url, request.context, MANIFEST_TIMEOUT_MS);
    } catch (_) {
      throw new AdaptiveFault(ADAPTIVE_ERR_MANIFEST, 'AdaptiveManifestFailed');
    } finally {
      this.manifest = null;
    }
    if (fetched.status !== 'ok') {
      throw new AdaptiveFault(ADAPTIVE_ERR_MANIFEST, 'AdaptiveManifest_' + fetched.status);
    }
    const base: string = fetched.finalUrl.length > 0 ? fetched.finalUrl : url;
    const playlist: HlsPlaylist | null = parseHlsMediaPlaylist(fetched.text, base, resolveHlsUrl);
    if (playlist === null) {
      throw new AdaptiveFault(ADAPTIVE_ERR_UNSUPPORTED, 'AdaptivePlaylistRejected');
    }
    return playlist;
  }

  private async consume(tempBase: string, result: AdaptiveRunResult): Promise<void> {
    if (result.kind === 'ready' && result.ready !== null) {
      await this.assembleAndPublish(tempBase, result.ready);
      return;
    }
    if (result.kind === 'paused') {
      this.finishPaused();
      return;
    }
    if (result.kind === 'resourceFault' || result.ownerDisposition === 'quarantined') {
      this.finishFailed(ADAPTIVE_ERR_RESOURCE, result.errorCode);
      return;
    }
    if (this.stopRequested && result.ownerDisposition === 'released') {
      this.finishPaused();
      return;
    }
    const code: number = result.errorCode === 'AdaptivePlanMissing' ? ADAPTIVE_ERR_SOURCE : ADAPTIVE_ERR_DOWNLOAD;
    this.finishFailed(code, result.errorCode.length > 0 ? result.errorCode : result.kind);
  }

  private async assembleAndPublish(tempBase: string, ready: AdaptiveReadyInput): Promise<void> {
    const assembler: AdaptiveAssembler = new AdaptiveAssembler(tempBase, ready.downloadId);
    this.assembler = assembler;
    let settled: AdaptiveAssemblyResult | null = null;
    let started: boolean = false;
    let finalPath: string = '';
    let finalBytes: number = 0;
    let failure: AdaptiveFault | null = null;
    try {
      if (this.stopRequested || !ready.lease.isCurrent() || ready.lease.isStopRequested()) {
        throw new AdaptiveFault(0, 'AdaptiveStopped');
      }
      if (!ready.lease.attachReader((): void => { assembler.cancel(); })) {
        throw new AdaptiveFault(ADAPTIVE_ERR_RESOURCE, 'AdaptiveReaderRejected');
      }
      this.reportAssembling();
      started = true;
      const assembled: AdaptiveAssemblyResult = await assembler.run(ready.state,
        (progress: AdaptiveAssemblyProgress): void => { this.onAssemblyProgress(progress); });
      settled = await assembler.drain();
      if (!assembled.closed || assembled.resourceUncertain || !assembled.cleanupComplete ||
        !settled.closed || settled.resourceUncertain || !settled.cleanupComplete) {
        throw new AdaptiveFault(ADAPTIVE_ERR_RESOURCE, 'AdaptiveAssemblyUncertain');
      }
      if (assembled.status === 'stopped' || this.stopRequested) {
        throw new AdaptiveFault(0, 'AdaptiveStopped');
      }
      if (assembled.status !== 'success' || assembled.outputName.length === 0) {
        throw new AdaptiveFault(ADAPTIVE_ERR_ASSEMBLY, assembled.errorCode.length > 0 ? assembled.errorCode : 'AdaptiveAssemblyFailed');
      }
      const published: string = await this.publish(tempBase, ready.downloadId, assembled);
      finalPath = published;
      const stat: fileIo.Stat = await fileIo.stat(published);
      finalBytes = stat.size;
    } catch (e) {
      failure = e instanceof AdaptiveFault ? e : new AdaptiveFault(ADAPTIVE_ERR_PUBLISH, 'AdaptivePublishFailed');
    } finally {
      this.assembler = null;
    }
    const readerSettled: boolean = !started || settled !== null;
    const unsafe: boolean = failure !== null && failure.code === ADAPTIVE_ERR_RESOURCE;
    if (!readerSettled || unsafe) {
      ready.lease.quarantine('AdaptiveReaderResourceUncertain');
      this.finishFailed(ADAPTIVE_ERR_RESOURCE, failure !== null ? failure.detail : 'AdaptiveReaderUnsettled');
      return;
    }
    const released: boolean = ready.lease.release();
    if (failure !== null) {
      if (failure.code === 0) { this.finishPaused(); }
      else { this.finishFailed(failure.code, failure.detail); }
      return;
    }
    if (released) {
      // Completed parts and checkpoint slots are no longer needed once the output is published.
      StateStore.removeById(tempBase, ready.downloadId);
    }
    this.finishSucceeded(finalBytes, finalPath);
  }

  /** Same-sandbox move into the download directory under a collision-free name. */
  private async publish(tempBase: string, id: string, assembled: AdaptiveAssemblyResult): Promise<string> {
    const source: string = tempBase + '/' + id + '/' + assembled.outputName;
    const targetDir: string = this.record.targetDir !== null && this.record.targetDir.length > 0
      ? this.record.targetDir : Config.getInstance().getDownloadDir();
    try { await fileIo.mkdir(targetDir, true); } catch (_) { /* exists */ }
    const wanted: string = adaptiveOutputName(this.record.name, assembled.extension);
    // 2026-11-22：设置「覆盖已有文件」——勾选时先删同名旧文件再落位，否则自动改名
    const overwrite: boolean = Config.getInstance().getFileConflictResolution() === 1;
    const unique: string = overwrite ? wanted : getUniqueFileName(wanted, targetDir, (path: string): boolean => {
      try { return fileIo.accessSync(path); } catch (_) { return false; }
    });
    if (overwrite) {
      try { await fileIo.unlink(targetDir + '/' + unique); } catch (_) { /* absent */ }
    }
    const target: string = targetDir + '/' + unique;
    try {
      await fileIo.rename(source, target);
    } catch (_) {
      try {
        await fileIo.copyFile(source, target);
        await fileIo.unlink(source);
      } catch (e2) {
        try { await fileIo.unlink(target); } catch (_) { /* nothing published */ }
        throw new AdaptiveFault(ADAPTIVE_ERR_PUBLISH, 'AdaptivePublishFailed');
      }
    }
    return target;
  }

  // ---------- progress ----------

  private startProgress(): void {
    this.stopProgress();
    this.lastWritten = 0;
    this.lastSampleAt = Date.now();
    this.speed = 0;
    this.progressTimer = setInterval((): void => {
      const controller: AdaptiveRunController | null = this.controller;
      if (controller !== null) { this.sample(controller.progressSnapshot()); }
    }, PROGRESS_INTERVAL_MS);
  }

  private stopProgress(): void {
    if (this.progressTimer >= 0) {
      clearInterval(this.progressTimer);
      this.progressTimer = -1;
    }
  }

  private sample(progress: AdaptiveRunProgress): void {
    if (!progress.planned || progress.totalChunks <= 0) {
      return;
    }
    this.latestSealedBytes = progress.sealedBytes;
    if (this.stopRequested) {
      return;
    }
    if (!this.connected) {
      this.connected = true;
      this.events.onConnected(this.record.id, 200, -1, true, '');
    }
    const now: number = Date.now();
    const elapsed: number = now - this.lastSampleAt;
    if (progress.writtenBytes >= this.lastWritten && elapsed > 0) {
      const instant: number = (progress.writtenBytes - this.lastWritten) * 1000 / elapsed;
      this.speed = this.speed === 0 ? instant : this.speed * 0.6 + instant * 0.4;
    }
    this.lastWritten = progress.writtenBytes;
    this.lastSampleAt = now;
    // Never 100 before the output is published and the record is committed.
    const percent: number = Math.min(99, Math.floor(progress.completedChunks * 100 / progress.totalChunks));
    const remaining: number = progress.totalChunks - progress.completedChunks;
    const average: number = progress.completedChunks > 0 ? progress.sealedBytes / progress.completedChunks : 0;
    const eta: number = this.speed > 1 && average > 0 ? Math.round(remaining * average / this.speed) : 0;
    const downloaded: number = Math.max(progress.sealedBytes, progress.writtenBytes);
    this.events.onProgress(this.record.id, percent, Math.round(this.speed), eta, downloaded);
  }

  private reportAssembling(): void {
    this.speed = 0;
    this.events.onProgress(this.record.id, 99, 0, 0, this.latestSealedBytes);
  }

  /** Assembly has no network rate; the row stays at 99% until the published file exists. */
  private onAssemblyProgress(progress: AdaptiveAssemblyProgress): void {
    const now: number = Date.now();
    if (this.stopRequested || progress.totalInputBytes <= 0 || now - this.lastAssemblyEvent < PROGRESS_INTERVAL_MS) {
      return;
    }
    this.lastAssemblyEvent = now;
    this.events.onProgress(this.record.id, 99, 0, 0, this.latestSealedBytes);
  }

  // ---------- terminal events (exactly one per run) ----------

  private finishPaused(): void {
    if (!this.running) { return; }
    this.running = false;
    this.stopProgress();
    this.events.onPaused(this.record.id, this.latestSealedBytes);
  }

  private finishFailed(code: number, detail: string): void {
    if (!this.running) { return; }
    this.running = false;
    this.stopProgress();
    hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s', 'adaptive failed code=' + String(code) + ' detail=' + detail);
    this.events.onFailed(this.record.id, code, detail);
  }

  private finishSucceeded(bytes: number, path: string): void {
    if (!this.running) { return; }
    this.running = false;
    this.stopProgress();
    this.events.onFinished(this.record.id, bytes, path);
  }
}
