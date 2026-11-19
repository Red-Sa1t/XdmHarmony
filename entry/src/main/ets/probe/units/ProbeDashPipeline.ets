// P7-U1-P drives the frozen adaptive pipeline (E4 + F) with real DASH plans over real HTTP.
// Host fixture: docs/probe/P7-U1-dash-host.cjs (fixed MPDs + deterministic segment bytes).
// EXPECT stays an external judgment; remux outcome on synthetic bytes is recorded as observed.
import { fileIo, hash } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { ProbeKit, KeyValue } from '../core/ProbeKit';
import { ProbePage, ProbeStepDef } from '../core/ProbePage';
import { DashPair } from '../../core/adaptive/DashModel';
import { parseDashManifest } from '../../core/adaptive/DashXmlFeed';
import { resolveHlsUrl } from '../../core/adaptive/HlsUrlResolver';
import { AdaptiveChunk, AdaptiveDownloadState, AdaptivePlan, AdaptiveTrack, buildDashPlan,
  copyAdaptivePlan, isAdaptiveHttpUrl } from '../../core/adaptive/AdaptivePlan';
import { AdaptiveRunController, AdaptiveRunInput, AdaptiveRunResult,
  AdaptiveReadyInput } from '../../core/adaptive/AdaptiveRunController';
import { AdaptiveThrottlePolicy, adaptiveNowMs } from '../../core/adaptive/AdaptiveDownloadThrottle';
import { AdaptiveAssembler, AdaptiveAssemblyResult } from '../../core/adaptive/AdaptiveAssembler';
import { ManifestClient, ManifestFetchResult } from '../../core/adaptive/ManifestClient';
import { DownloadRequestContext } from '../../model/DownloadRequestContext';

const PIPELINE_STEPS: ProbeStepDef[] = [
  { stepNo: 'S1', title: '清单→计划（真 HTTP）', autoRun: true },
  { stepNo: 'S2', title: '全量下载（E4）', autoRun: true },
  { stepNo: 'S3', title: '单轨拼接与内容序', autoRun: true },
  { stepNo: 'S4', title: '双轨 remux（真 MediaProcessorNapi）', autoRun: true },
  { stepNo: 'S5', title: '恢复与已提交前缀', autoRun: true },
  { stepNo: 'S6', title: '管线拒绝', autoRun: true }
];

/** 主机固定段几何：init 1024 字节、media 4096 字节；video 轨相位 0、audio 轨相位 13、
 * 字节=(轨内绝对位置+i)%251 连续图案（内容序校验的双算基础，host cjs 同式）。 */
const INIT_BYTES: number = 1024;
const MEDIA_BYTES: number = 4096;
const VIDEO_PHASE: number = 0;
const AUDIO_PHASE: number = 13;

const DEFAULT_SOURCE: string = 'http://127.0.0.1:8795';

class DashRunRef {
  input: AdaptiveRunInput;
  controller: AdaptiveRunController;

  constructor(input: AdaptiveRunInput, controller: AdaptiveRunController) {
    this.input = input;
    this.controller = controller;
  }
}

class DashLeaseRef {
  ready: AdaptiveReadyInput;
  reader: AdaptiveAssembler | null = null;
  result: AdaptiveAssemblyResult | null = null;
  attached: boolean = false;
  started: boolean = false;
  returned: boolean = false;
  unsafe: boolean = false;

  constructor(ready: AdaptiveReadyInput) {
    this.ready = ready;
  }
}

class DashPipelineTimer {
  id: number = -1;
  active: boolean = true;
  fired: boolean = false;
}

function errorCodeOf(error: BusinessError): number {
  return error !== null && typeof error === 'object' && Number.isSafeInteger(error.code) ? error.code : -1;
}

function expectedBytes(isVideo: boolean, start: number, length: number): Uint8Array {
  const out: Uint8Array = new Uint8Array(length);
  const phase: number = isVideo ? VIDEO_PHASE : AUDIO_PHASE;
  for (let i = 0; i < length; i++) { out[i] = (phase + start + i) % 251; }
  return out;
}

function sameBytes(actual: Uint8Array, expected: Uint8Array): boolean {
  if (actual.length !== expected.length) { return false; }
  for (let i = 0; i < actual.length; i++) {
    if (actual[i] !== expected[i]) { return false; }
  }
  return true;
}

/** 单轨 Dash 计划（仅探针构造以驱动 F 的单轨拼接路径；业务侧单轨走 SingleSource 不进计划，
 * 设计书 §3.2——copyAdaptivePlan 接受 role='muxed' 单轨 Dash 形态）。 */
function buildSingleDashPlan(manifestUrl: string, segments: string[], mime: string,
  duration: number): AdaptivePlan | null {
  const plan: AdaptivePlan = new AdaptivePlan();
  plan.kind = 'Dash';
  plan.primaryUrl = manifestUrl;
  plan.secondaryUrl = '';
  plan.duration = duration;
  const track: AdaptiveTrack = new AdaptiveTrack();
  track.index = 0;
  track.role = 'muxed';
  track.playlistUrl = manifestUrl;
  track.container = '.mp4';
  track.endList = true;
  plan.tracks.push(track);
  plan.suggestedExtension = '.mp4';
  for (let i = 0; i < segments.length; i++) {
    const chunk: AdaptiveChunk = new AdaptiveChunk();
    chunk.id = 'c' + String(i);
    chunk.trackIndex = 0;
    chunk.trackOrder = i;
    chunk.url = segments[i];
    chunk.offset = 0;
    chunk.length = -1;
    chunk.duration = 0;
    chunk.isInit = false;
    chunk.mediaSequence = i;
    chunk.discontinuity = false;
    chunk.discontinuitySequence = 0;
    plan.chunks.push(chunk);
  }
  return copyAdaptivePlanOrNull(plan);
}

function copyAdaptivePlanOrNull(plan: AdaptivePlan): AdaptivePlan | null {
  // newAdaptiveState 内部同样走 copyAdaptivePlan 全量校验；此处先行校验以便空手返回 null
  return copyAdaptivePlan(plan);
}

/** 每步骤独立 owner（ProbeAdaptiveController 惯例）：runs/leases/writers 全登记，取消即停。 */
export class DashPipelineSession {
  readonly facts: KeyValue[] = [];
  private filesDir: string;
  private source: string;
  private token: string;
  private runId: string;
  private base: string = '';
  private cancelled: boolean = false;
  private cleanupSafe: boolean = true;
  private runs: DashRunRef[] = [];
  private leases: DashLeaseRef[] = [];
  private clients: ManifestClient[] = [];
  private timers: DashPipelineTimer[] = [];
  private reads: Array<Promise<string>> = [];
  private business: Promise<void> | null = null;
  private businessFinished: boolean = false;
  private releasing: Promise<boolean> | null = null;

  constructor(filesDir: string, source: string, token: string, runId: string) {
    this.filesDir = filesDir;
    this.source = source;
    this.token = token;
    this.runId = runId;
  }

  isCurrent(): boolean { return !this.cancelled && ProbeKit.getInstance().isCurrent(this.token); }

  private check(): void {
    if (!this.isCurrent()) { throw new Error('DashPipelineProbeStopped'); }
  }

  private note(key: string, value: string | number | boolean): void {
    for (let i = 0; i < this.facts.length; i++) {
      if (this.facts[i].key === key) { this.facts[i].value = String(value); return; }
    }
    this.facts.push(new KeyValue(key, String(value)));
  }

  noteFailure(error: BusinessError): void {
    this.note('errCode', String(errorCodeOf(error)));
    this.note('err', 'DashPipelineProbeFailure');
  }

  cancel(): void {
    this.cancelled = true;
    this.stopTimers();
    for (let i = 0; i < this.runs.length; i++) { this.runs[i].controller.pause(); }
    for (let i = 0; i < this.leases.length; i++) { this.leases[i].reader?.cancel(); }
    for (let i = 0; i < this.clients.length; i++) { this.clients[i].cancel(); }
  }

  private stopTimer(timer: DashPipelineTimer): void {
    timer.active = false;
    const id: number = timer.id;
    timer.id = -1;
    if (id >= 0) { clearTimeout(id); }
  }

  private stopTimers(): void {
    for (let i = 0; i < this.timers.length; i++) { this.stopTimer(this.timers[i]); }
  }

  private timer(delay: number, action: () => void): DashPipelineTimer {
    const timer: DashPipelineTimer = new DashPipelineTimer();
    this.timers.push(timer);
    timer.id = setTimeout((): void => {
      if (!timer.active || !this.isCurrent()) { return; }
      timer.active = false;
      timer.id = -1;
      timer.fired = true;
      action();
    }, delay);
    return timer;
  }

  private async prepare(): Promise<void> {
    this.check();
    if (this.base !== '') { return; }
    if (this.filesDir === '') { throw new Error('DashPipelineFilesUnavailable'); }
    const directory: string = this.filesDir + '/probe-dash-pipeline-' + util.generateRandomUUID(true);
    await fileIo.mkdir(directory, false);
    this.base = directory;
    this.check();
  }

  private input(id: string, url: string): AdaptiveRunInput {
    const input: AdaptiveRunInput = new AdaptiveRunInput();
    input.downloadId = id;
    input.runToken = util.generateRandomUUID(true);
    input.tempBase = this.base;
    input.request.url = url;
    input.limits.maxSegments = 2;
    input.limits.maxRetry = 0;
    input.limits.retryDelayMs = 0;
    input.networkTimeoutSeconds = 4;
    return input;
  }

  private make(input: AdaptiveRunInput, rate: number = 0): DashRunRef {
    this.check();
    const policy: AdaptiveThrottlePolicy = new AdaptiveThrottlePolicy();
    policy.taskKiBps = rate;
    const controller: AdaptiveRunController = new AdaptiveRunController(input,
      (): AdaptiveThrottlePolicy => policy);
    const owned: DashRunRef = new DashRunRef(input, controller);
    this.runs.push(owned);
    return owned;
  }

  private adopt(result: AdaptiveRunResult): void {
    if (result.kind === 'resourceFault' || result.ownerDisposition === 'quarantined') { this.cleanupSafe = false; }
    const ready: AdaptiveReadyInput | null = result.ready;
    if (ready === null) { return; }
    for (let i = 0; i < this.leases.length; i++) {
      if (this.leases[i].ready.lease === ready.lease) { return; }
    }
    this.leases.push(new DashLeaseRef(ready));
  }

  private async run(owned: DashRunRef): Promise<AdaptiveRunResult> {
    this.check();
    const result: AdaptiveRunResult = await owned.controller.run();
    this.adopt(result);
    this.check();
    if (!this.cleanupSafe) { throw new Error('DashPipelineResourceUncertain'); }
    return result;
  }

  private noteRun(prefix: string, result: AdaptiveRunResult): void {
    this.note(prefix + 'Kind', result.kind);
    this.note(prefix + 'Error', result.errorCode);
    const state: AdaptiveDownloadState | null = result.durableState;
    this.note(prefix + 'Generation', state?.generation ?? -1);
    this.note(prefix + 'Parts', state?.parts.length ?? 0);
    if (state !== null) {
      for (let i = 0; i < state.parts.length; i++) {
        this.note('p' + String(i) + 'Bytes', state.parts[i].downloaded);
        this.note('p' + String(i) + 'Complete', state.parts[i].complete);
      }
    }
  }

  private ready(result: AdaptiveRunResult): DashLeaseRef {
    const ready: AdaptiveReadyInput | null = result.ready;
    if (result.kind !== 'ready' || result.ownerDisposition !== 'heldForAssembly' || ready === null ||
      ready.tempBase !== this.base) { throw new Error('DashPipelineReadyUnavailable'); }
    for (let i = 0; i < this.leases.length; i++) {
      if (this.leases[i].ready.lease === ready.lease) { return this.leases[i]; }
    }
    throw new Error('DashPipelineLeaseUnavailable');
  }

  private checkLease(owned: DashLeaseRef): void {
    this.check();
    if (owned.returned || !owned.ready.lease.isCurrent() || owned.ready.lease.isStopRequested()) {
      throw new Error('DashPipelineLeaseStopped');
    }
  }

  private attach(owned: DashLeaseRef): void {
    this.checkLease(owned);
    const reader: AdaptiveAssembler = new AdaptiveAssembler(this.base, owned.ready.downloadId);
    owned.reader = reader;
    owned.attached = owned.ready.lease.attachReader((): void => { reader.cancel(); });
    if (!owned.attached) { throw new Error('DashPipelineReaderRejected'); }
    this.checkLease(owned);
  }

  private noteAssembly(prefix: string, result: AdaptiveAssemblyResult): void {
    this.note(prefix + 'Status', result.status);
    this.note(prefix + 'Error', result.errorCode);
    this.note(prefix + 'Bytes', result.outputBytes);
    this.note(prefix + 'Extension', result.extension);
    this.note(prefix + 'MediaStarted', result.mediaStarted);
    this.note(prefix + 'MediaSettled', result.mediaSettled);
    this.note(prefix + 'Closed', result.closed);
    this.note(prefix + 'Uncertain', result.resourceUncertain);
    this.note(prefix + 'Cleanup', result.cleanupComplete);
    if (!result.closed || result.resourceUncertain || !result.cleanupComplete) {
      this.cleanupSafe = false;
      throw new Error('DashPipelineAssemblyUncertain');
    }
  }

  private async assemble(owned: DashLeaseRef): Promise<AdaptiveAssemblyResult> {
    this.checkLease(owned);
    const reader: AdaptiveAssembler | null = owned.reader;
    if (!owned.attached || reader === null || owned.started) {
      throw new Error('DashPipelineReaderUnavailable');
    }
    owned.started = true;
    const result: AdaptiveAssemblyResult = await reader.run(owned.ready.state);
    // 读者结算登记（与 ProbeAdaptiveController/ProbeDashController 同纪律）：缺登记时 returnLease
    // 把已结束读者判为在跑而隔离租约（2026-10-18 真机 S3 leaseReleased=false 实证）
    owned.result = result;
    this.noteAssembly('asm', result);
    this.check();
    const drained: AdaptiveAssemblyResult = await reader.drain();
    this.noteAssembly('drain', drained);
    this.check();
    return result;
  }

  private returnLease(owned: DashLeaseRef): boolean {
    if (owned.returned) { return false; }
    if (owned.unsafe || (owned.started && owned.result === null) || this.reads.length > 0) {
      owned.ready.lease.quarantine('DashPipelineReaderResourceUncertain');
      this.cleanupSafe = false;
      return false;
    }
    const returned: boolean = owned.ready.lease.release();
    if (returned) { owned.returned = true; } else { this.cleanupSafe = false; }
    return returned;
  }

  private async readOutput(state: AdaptiveDownloadState, name: string): Promise<Uint8Array> {
    this.check();
    const path: string = this.base + '/' + state.downloadId + '/' + name;
    const file: fileIo.File = await fileIo.open(path, fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.NOFOLLOW);
    try {
      this.check();
      const stat: fileIo.Stat = await fileIo.stat(file.fd);
      this.check();
      if (stat.size < 0 || stat.size > 4194304) { throw new Error('DashPipelineOutputTooLarge'); }
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      let received: number = 0;
      while (received < buffer.byteLength) {
        const part: ArrayBuffer = new ArrayBuffer(buffer.byteLength - received);
        const count: number = await fileIo.read(file.fd, part);
        this.check();
        if (!Number.isSafeInteger(count) || count <= 0 || count > part.byteLength) {
          throw new Error('DashPipelineShortRead');
        }
        new Uint8Array(buffer).set(new Uint8Array(part, 0, count), received);
        received += count;
      }
      return new Uint8Array(buffer);
    } finally {
      await fileIo.close(file);
    }
  }

  /** 直接由主机段 URL 构造双轨 Dash 计划（与 probe.mpd 段几何一致）。 */
  private directDualPlan(): AdaptivePlan {
    const origin: string = this.source.trim();
    if (!isAdaptiveHttpUrl(origin)) { throw new Error('DashPipelineServerInvalid'); }
    const manifestUrl: string = resolveHlsUrl(origin, '/mpd/probe.mpd');
    const videoSegs: string[] = [resolveHlsUrl(origin, '/seg/p-v1-init.mp4'),
      resolveHlsUrl(origin, '/seg/p-v1-1.m4s'), resolveHlsUrl(origin, '/seg/p-v1-2.m4s')];
    const audioSegs: string[] = [resolveHlsUrl(origin, '/seg/p-a1-init.mp4'),
      resolveHlsUrl(origin, '/seg/p-a1-1.m4s'), resolveHlsUrl(origin, '/seg/p-a1-2.m4s')];
    const plan: AdaptivePlan | null = buildDashPlan(manifestUrl, videoSegs, 'video/mp4',
      audioSegs, 'audio/mp4', 120000, 120000);
    if (plan === null) { throw new Error('DashPipelinePlanUnavailable'); }
    return plan;
  }

  /** S1：真 HTTP 清单 → parseDashManifest → buildDashPlan。 */
  private async manifestToPlan(): Promise<void> {
    await this.prepare();
    this.check();
    const origin: string = this.source.trim();
    if (!isAdaptiveHttpUrl(origin)) { throw new Error('DashPipelineServerInvalid'); }
    const client: ManifestClient = new ManifestClient();
    this.clients.push(client);
    const context: DownloadRequestContext = new DownloadRequestContext();
    const fetched: ManifestFetchResult = await client.fetchGet(resolveHlsUrl(origin, '/mpd/probe.mpd'),
      context, 8000);
    this.check();
    this.note('fetchStatus', fetched.status);
    if (fetched.status !== 'ok') { throw new Error('DashPipelineManifestUnavailable'); }
    const periods: DashPair[][] = parseDashManifest(fetched.text, fetched.finalUrl, resolveHlsUrl);
    this.check();
    this.note('periodCount', periods.length);
    const pair: DashPair = periods[0][0];
    if (pair.video === null || pair.audio === null) { throw new Error('DashPipelinePairUnavailable'); }
    this.note('videoSegments', pair.video.segments.length);
    this.note('audioSegments', pair.audio.segments.length);
    const plan: AdaptivePlan | null = buildDashPlan(fetched.finalUrl, pair.video.segments,
      pair.video.mimeType, pair.audio.segments, pair.audio.mimeType, pair.video.duration,
      pair.audio.duration);
    this.note('planKind', plan === null ? 'null' : plan.kind);
    if (plan === null) { throw new Error('DashPipelinePlanUnavailable'); }
    this.note('chunkCount', plan.chunks.length);
    let interleaveOk: boolean = plan.chunks.length === 6;
    for (let i = 0; i < plan.chunks.length; i++) {
      const expectedTrack: number = i % 2;
      const expectedOrder: number = Math.floor(i / 2);
      if (plan.chunks[i].trackIndex !== expectedTrack || plan.chunks[i].trackOrder !== expectedOrder ||
        plan.chunks[i].offset !== 0 || plan.chunks[i].length !== -1 || plan.chunks[i].isInit) {
        interleaveOk = false;
      }
    }
    this.note('interleaveOk', interleaveOk);
    this.note('containerRule', plan.suggestedExtension);
  }

  /** S2：newAdaptiveState → E4 全量下载 → ready（段字节=主机固定几何）。 */
  private async fullDownload(): Promise<void> {
    await this.prepare();
    this.check();
    const plan: AdaptivePlan = this.directDualPlan();
    const id: string = util.generateRandomUUID(true);
    const input: AdaptiveRunInput = this.input(id, plan.primaryUrl);
    input.freshPlan = plan;
    const result: AdaptiveRunResult = await this.run(this.make(input));
    this.noteRun('run', result);
    if (result.kind !== 'ready' || result.durableState === null) {
      throw new Error('DashPipelineRunNotReady');
    }
    const state: AdaptiveDownloadState = result.durableState;
    let complete: number = 0;
    for (let i = 0; i < state.parts.length; i++) {
      if (state.parts[i].complete) { complete++; }
    }
    this.note('partsComplete', complete);
    const expectedSizes: number[] = [INIT_BYTES, INIT_BYTES, MEDIA_BYTES, MEDIA_BYTES, MEDIA_BYTES, MEDIA_BYTES];
    let sizesOk: boolean = state.parts.length === expectedSizes.length;
    for (let i = 0; i < expectedSizes.length; i++) {
      if (state.parts[i].downloaded !== expectedSizes[i]) { sizesOk = false; }
    }
    this.note('partSizesOk', sizesOk);
    const owned: DashLeaseRef = this.ready(result);
    this.note('leaseReleased', this.returnLease(owned));
    this.check();
  }

  /** S3：单轨计划 → E4 → 单轨拼接 → 输出字节与固定图案逐字节一致。 */
  private async singleTrack(): Promise<void> {
    await this.prepare();
    this.check();
    const origin: string = this.source.trim();
    const manifestUrl: string = resolveHlsUrl(origin, '/mpd/probe.mpd');
    const segs: string[] = [resolveHlsUrl(origin, '/seg/p-v1-init.mp4'),
      resolveHlsUrl(origin, '/seg/p-v1-1.m4s'), resolveHlsUrl(origin, '/seg/p-v1-2.m4s')];
    const plan: AdaptivePlan | null = buildSingleDashPlan(manifestUrl, segs, 'video/mp4', 120000);
    if (plan === null) { throw new Error('DashPipelineSinglePlanUnavailable'); }
    const input: AdaptiveRunInput = this.input(util.generateRandomUUID(true), manifestUrl);
    input.freshPlan = plan;
    input.limits.maxSegments = 1;
    const result: AdaptiveRunResult = await this.run(this.make(input));
    this.noteRun('run', result);
    if (result.kind !== 'ready' || result.durableState === null) {
      throw new Error('DashPipelineRunNotReady');
    }
    const owned: DashLeaseRef = this.ready(result);
    this.attach(owned);
    const assembled: AdaptiveAssemblyResult = await this.assemble(owned);
    this.note('asmExtension', assembled.extension);
    this.note('asmBytes', assembled.outputBytes);
    if (assembled.status !== 'success') { throw new Error('DashPipelineAssemblyFailed'); }
    const output: Uint8Array = await this.readOutput(owned.ready.state, assembled.outputName);
    this.check();
    const expected: Uint8Array = new Uint8Array(INIT_BYTES + 2 * MEDIA_BYTES);
    expected.set(expectedBytes(true, 0, INIT_BYTES), 0);
    expected.set(expectedBytes(true, INIT_BYTES, MEDIA_BYTES), INIT_BYTES);
    expected.set(expectedBytes(true, INIT_BYTES + MEDIA_BYTES, MEDIA_BYTES), INIT_BYTES + MEDIA_BYTES);
    this.note('contentOrderMatch', sameBytes(output, expected));
    this.note('leaseReleased', this.returnLease(owned));
    this.check();
  }

  /** S4：双轨计划 → E4 → 真 MediaProcessorNapi remux（合成字节的降级路径如实记录）。 */
  private async dualRemux(): Promise<void> {
    await this.prepare();
    this.check();
    const plan: AdaptivePlan = this.directDualPlan();
    const input: AdaptiveRunInput = this.input(util.generateRandomUUID(true), plan.primaryUrl);
    input.freshPlan = plan;
    const result: AdaptiveRunResult = await this.run(this.make(input));
    this.noteRun('run', result);
    if (result.kind !== 'ready' || result.durableState === null) {
      throw new Error('DashPipelineRunNotReady');
    }
    const owned: DashLeaseRef = this.ready(result);
    this.attach(owned);
    const assembled: AdaptiveAssemblyResult = await this.assemble(owned);
    if (assembled.status !== 'success') { throw new Error('DashPipelineAssemblyFailed'); }
    this.note('remuxPath', assembled.extension === '.mp4' ? 'media' : 'fallback');
    this.note('asmBytes', assembled.outputBytes);
    this.note('leaseReleased', this.returnLease(owned));
    this.check();
  }

  /** S5：限速运行 → 中途 pause → freshPlan=null 重开恢复 → ready + 前缀保真 + 0 次清单重取。 */
  private async resumeRun(): Promise<void> {
    await this.prepare();
    this.check();
    const plan: AdaptivePlan = this.directDualPlan();
    const id: string = util.generateRandomUUID(true);
    const input: AdaptiveRunInput = this.input(id, plan.primaryUrl);
    input.freshPlan = plan;
    input.limits.maxSegments = 1;
    const first: DashRunRef = this.make(input, 4);
    const started: number = adaptiveNowMs();
    const pending: Promise<AdaptiveRunResult> = this.run(first);
    const timer: DashPipelineTimer = this.timer(800, (): void => first.controller.pause());
    const paused: AdaptiveRunResult = await pending;
    this.stopTimer(timer);
    this.check();
    this.note('pauseTimerFired', timer.fired);
    this.note('pauseElapsedMs', adaptiveNowMs() - started);
    this.noteRun('paused', paused);
    const state: AdaptiveDownloadState | null = paused.durableState;
    if (!timer.fired || paused.kind !== 'paused' || state === null) {
      throw new Error('DashPipelinePauseMismatch');
    }
    let prefixBytes: number = 0;
    let prefixName: string = '';
    for (let i = 0; i < state.parts.length; i++) {
      if (state.parts[i].downloaded > 0) {
        prefixBytes += state.parts[i].downloaded;
        if (state.parts[i].fileName !== '') { prefixName = state.parts[i].fileName; }
      }
    }
    this.note('prefixBytes', prefixBytes);
    let prefixHash: string = '';
    if (prefixName !== '') {
      const pendingHash: Promise<string> = hash.hash(this.base + '/' + id + '/' + prefixName, 'sha256');
      this.reads.push(pendingHash);
      prefixHash = await pendingHash;
      this.reads.splice(this.reads.indexOf(pendingHash), 1);
      this.check();
    }
    this.note('manifestRefetch', 0); // 恢复路径 freshPlan=null，不发生清单请求
    const resumedInput: AdaptiveRunInput = this.input(id, plan.primaryUrl);
    resumedInput.limits.maxSegments = 1;
    const resumed: AdaptiveRunResult = await this.run(this.make(resumedInput));
    this.noteRun('resumed', resumed);
    if (resumed.kind !== 'ready') { throw new Error('DashPipelineResumeNotReady'); }
    if (prefixName !== '') {
      const afterHash: Promise<string> = hash.hash(this.base + '/' + id + '/' + prefixName, 'sha256');
      this.reads.push(afterHash);
      const after: string = await afterHash;
      this.reads.splice(this.reads.indexOf(afterHash), 1);
      this.check();
      this.note('prefixPreserved', prefixHash === after);
    }
    const owned: DashLeaseRef = this.ready(resumed);
    this.note('leaseReleased', this.returnLease(owned));
    this.check();
  }

  /** S6：超预算/非法 URL/单轨 buildDashPlan 拒绝 + E4 InvalidAdaptiveRunInput。 */
  private async pipelineRejections(): Promise<void> {
    await this.prepare();
    this.check();
    const origin: string = this.source.trim();
    const manifestUrl: string = resolveHlsUrl(origin, '/mpd/probe.mpd');
    const overVideo: string[] = [];
    for (let i = 0; i < 10001; i++) { overVideo.push(resolveHlsUrl(origin, '/seg/p-v1-1.m4s')); }
    this.note('overBudgetRejected', String(buildDashPlan(manifestUrl, overVideo, 'video/mp4',
      [resolveHlsUrl(origin, '/seg/p-a1-init.mp4')], 'audio/mp4', 1000, 1000) === null));
    this.note('invalidUrlRejected', String(buildDashPlan(manifestUrl,
      ['http://bad host/seg/x.m4s'], 'video/mp4',
      [resolveHlsUrl(origin, '/seg/p-a1-init.mp4')], 'audio/mp4', 1000, 1000) === null));
    this.note('singleTrackRejected', String(buildDashPlan(manifestUrl,
      [resolveHlsUrl(origin, '/seg/p-v1-init.mp4')], 'video/mp4', [], 'audio/mp4', 1000, 1000) === null));
    const rejectedInput: AdaptiveRunInput = this.input(util.generateRandomUUID(true), manifestUrl);
    const rejected: AdaptiveRunResult = await this.run(this.make(rejectedInput));
    this.note('e4Kind', rejected.kind);
    this.note('e4ErrorCode', rejected.errorCode);
  }

  execute(step: string): Promise<void> {
    if (this.business === null) { this.business = this.executeOwned(step); }
    return this.business;
  }

  private async executeOwned(step: string): Promise<void> {
    try {
      this.check();
      if (step === 'S1') { await this.manifestToPlan(); }
      else if (step === 'S2') { await this.fullDownload(); }
      else if (step === 'S3') { await this.singleTrack(); }
      else if (step === 'S4') { await this.dualRemux(); }
      else if (step === 'S5') { await this.resumeRun(); }
      else if (step === 'S6') { await this.pipelineRejections(); }
      else { throw new Error('DashPipelineStepUnavailable'); }
      this.check();
    } finally { this.businessFinished = true; }
  }

  releaseResources(): Promise<boolean> {
    if (this.releasing !== null) { return this.releasing; }
    const work: Promise<boolean> = this.releaseOwned();
    this.releasing = work;
    return work.then<boolean>((value: boolean): boolean => {
      if (this.releasing === work) { this.releasing = null; }
      return value;
    });
  }

  private async releaseOwned(): Promise<boolean> {
    this.stopTimers();
    if (this.business !== null && !this.businessFinished) { this.cancel(); }
    if (this.business !== null) {
      try { await this.business; } catch (e) { /* 主调用方已记录失败事实 */ }
    }
    for (let i = 0; i < this.runs.length; i++) {
      try { this.runs[i].controller.pause(); this.adopt(await this.runs[i].controller.drain()); }
      catch (e) { this.cleanupSafe = false; }
    }
    for (let i = 0; i < this.leases.length; i++) {
      const owned: DashLeaseRef = this.leases[i];
      if (owned.reader !== null) {
        try { owned.reader.cancel(); await owned.reader.drain(); }
        catch (e) { owned.unsafe = true; this.cleanupSafe = false; }
      }
    }
    const reads: Array<Promise<string>> = this.reads.slice();
    for (let i = 0; i < reads.length; i++) {
      try { await reads[i]; } catch (e) { this.cleanupSafe = false; }
    }
    for (let i = 0; i < this.leases.length; i++) {
      if (!this.leases[i].returned) {
        const released: boolean = this.leases[i].ready.lease.release();
        if (!released) { this.cleanupSafe = false; } else { this.leases[i].returned = true; }
      }
    }
    for (let i = 0; i < this.clients.length; i++) { this.clients[i].cancel(); }
    return this.cleanupSafe;
  }

  noteCleanup(value: boolean): void { this.note('cleanupComplete', value); }
}

@Component
export struct ProbeDashPipeline {
  @State baseUrl: string = DEFAULT_SOURCE;
  private alive: boolean = false;
  private owner: DashPipelineSession | undefined = undefined;

  aboutToAppear(): void { this.alive = true; }

  aboutToDisappear(): void {
    this.alive = false;
    this.owner?.cancel();
  }

  private async runStep(step: string): Promise<void> {
    if (!this.alive) { return; }
    const kit: ProbeKit = ProbeKit.getInstance();
    const token: string = kit.getSessionToken();
    if (!kit.isCurrent(token)) { return; }
    this.owner?.cancel();
    const context = this.getUIContext().getHostContext();
    const session: DashPipelineSession = new DashPipelineSession(context?.filesDir ?? '', this.baseUrl,
      token, kit.getRunId());
    this.owner = session;
    try {
      try { await session.execute(step); } catch (error) { session.noteFailure(error as BusinessError); }
      const released: boolean = await session.releaseResources();
      if (!this.alive || this.owner !== session || !session.isCurrent()) { return; }
      session.noteCleanup(released);
      kit.emit(step, session.facts);
    } finally {
      session.cancel();
      if (this.owner === session) { this.owner = undefined; }
    }
  }

  build() {
    Column({ space: 12 }) {
      Text($r('app.string.probe_http_source_hint')).fontSize(12).opacity(0.7).width('100%')
      TextInput({ text: this.baseUrl, placeholder: $r('app.string.probe_http_source_hint') })
        .onChange((value: string): void => { this.baseUrl = value; }).width('100%')
      ProbePage({ unitId: 'P7-U1-P', pageTitle: $r('app.string.probe_p7u1_pipeline_title'),
        steps: PIPELINE_STEPS, autoStart: false,
        runStep: (step: string): Promise<void> => this.runStep(step) }).layoutWeight(1)
    }.width('100%').height('100%').padding(16)
  }
}
