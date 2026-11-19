// Real E3 network/FS and F assembly entry points. Device EXPECT remains an external judgment.
import { fileIo, hash } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { ProbeKit, KeyValue } from '../core/ProbeKit';
import { ProbePage, ProbeStepDef } from '../core/ProbePage';
import { HlsPlaylist } from '../../core/adaptive/HlsModel';
import { parseHlsMediaPlaylist } from '../../core/adaptive/HlsParser';
import { resolveHlsUrl } from '../../core/adaptive/HlsUrlResolver';
import { AdaptivePlan, AdaptiveDownloadState, buildHlsPlan, isAdaptiveHttpUrl } from '../../core/adaptive/AdaptivePlan';
import { newAdaptiveState, encodeAdaptiveState, decodeAdaptiveState } from '../../core/adaptive/AdaptiveStateCodec';
import { AdaptiveStateStore, AdaptiveStoreResult } from '../../core/db/AdaptiveStateStore';
import { AdaptiveAttemptFile, AttemptFileResult } from '../../core/adaptive/AdaptiveAttemptFile';
import { AdaptiveScheduler, AdaptiveSchedulerLimits, AdaptiveDispatch,
  AdaptiveSettlementResult, AdaptiveQuiesced } from '../../core/adaptive/AdaptiveScheduler';
import { createAdaptiveWindow, AdaptiveRequestWindow } from '../../core/adaptive/AdaptiveProtocol';
import { AdaptiveAttemptExecutor, AdaptiveAttemptOptions, AdaptiveAttemptResult } from '../../core/adaptive/AdaptiveAttemptExecutor';
import { AdaptiveDownloadThrottle, AdaptiveThrottlePolicy, adaptiveNowMs } from '../../core/adaptive/AdaptiveDownloadThrottle';
import { AdaptiveAssembler, AdaptiveAssemblyResult } from '../../core/adaptive/AdaptiveAssembler';
import { DownloadRequestContext } from '../../model/DownloadRequestContext';

const PIPELINE_STEPS: ProbeStepDef[] = [
  { stepNo: 'S1', title: '真实 Range 双片下载与状态提交', autoRun: true },
  { stepNo: 'S2', title: '512 KiB 低速长流（约两分钟）', autoRun: true },
  { stepNo: 'S3', title: '网络停止与已封存前缀', autoRun: true },
  { stepNo: 'S4', title: '按提交前缀串接与旧文件保留', autoRun: true },
  { stepNo: 'S5', title: '双轨样本串接及真实 Native 合并', autoRun: true },
  { stepNo: 'S6', title: '缺失输入、装配取消与资源收尾', autoRun: true }
];

type PipelineRawLoader = (name: string) => Promise<Uint8Array>;

class PipelineFixture {
  state: AdaptiveDownloadState;
  store: AdaptiveStateStore;
  constructor(state: AdaptiveDownloadState, store: AdaptiveStateStore) { this.state = state; this.store = store; }
}

class PipelineTimer {
  id: number = -1;
  active: boolean = true;
  fired: boolean = false;
}

class PipelineDetails {
  unit: string = 'P6-U5';
  step: string = '';
  runId: string = '';
  sessionToken: string = '';
  directory: string = '';
  facts: KeyValue[] = [];
}

/** Each step owns a fresh private root; old completions never write into a replacement step. */
export class AdaptivePipelineSession {
  readonly facts: KeyValue[] = [];
  private filesDir: string;
  private source: string;
  private token: string;
  private runId: string;
  private base: string = '';
  private evidenceDownloadId: string = '';
  private ownsBase: boolean = false;
  private cancelled: boolean = false;
  private cleanupSafe: boolean = true;
  private stores: AdaptiveStateStore[] = [];
  private writers: AdaptiveAttemptFile[] = [];
  private executors: AdaptiveAttemptExecutor[] = [];
  private gates: AdaptiveDownloadThrottle[] = [];
  private assemblers: AdaptiveAssembler[] = [];
  private timers: PipelineTimer[] = [];

  constructor(filesDir: string, source: string, token: string, runId: string) {
    this.filesDir = filesDir; this.source = source; this.token = token; this.runId = runId;
  }

  isCurrent(): boolean { return !this.cancelled && ProbeKit.getInstance().isCurrent(this.token); }
  check(): void { if (!this.isCurrent()) { throw new Error('PipelineProbeStopped'); } }
  private note(key: string, value: string | number | boolean): void {
    for (let i = 0; i < this.facts.length; i++) {
      if (this.facts[i].key === key) { this.facts[i].value = String(value); return; }
    }
    this.facts.push(new KeyValue(key, String(value)));
  }

  noteFailure(error: BusinessError): void {
    this.note('errCode', error.code ?? -1);
    // Do not expose arbitrary SDK paths, URLs or credentials in the short marker line.
    this.note('err', 'PipelineProbeFailure');
  }

  cancel(): void {
    if (this.cancelled) { return; }
    this.cancelled = true;
    this.stopTimers();
    for (let i = 0; i < this.executors.length; i++) { this.executors[i].dispose(); }
    for (let i = 0; i < this.assemblers.length; i++) { this.assemblers[i].cancel(); }
    for (let i = 0; i < this.writers.length; i++) { this.writers[i].dispose(); }
    for (let i = 0; i < this.stores.length; i++) { this.stores[i].dispose(); }
  }

  private stopTimer(timer: PipelineTimer): void {
    timer.active = false;
    const id: number = timer.id; timer.id = -1;
    if (id >= 0) { clearTimeout(id); }
  }

  private stopTimers(): void { for (let i = 0; i < this.timers.length; i++) { this.stopTimer(this.timers[i]); } }

  private timer(delay: number, action: () => void): PipelineTimer {
    const owned: PipelineTimer = new PipelineTimer(); this.timers.push(owned);
    owned.id = setTimeout((): void => {
      if (!owned.active || !this.isCurrent()) { return; }
      owned.active = false; owned.id = -1; owned.fired = true; action();
    }, delay);
    return owned;
  }

  private async prepare(): Promise<void> {
    this.check();
    if (this.ownsBase) { return; }
    if (this.filesDir.length === 0) { throw new Error('PipelineProbeFilesUnavailable'); }
    const base: string = this.filesDir + '/probe-adaptive-pipeline-' + util.generateRandomUUID(true);
    await fileIo.mkdir(base, false);
    this.base = base; this.ownsBase = true; this.check();
  }

  private store(id: string): AdaptiveStateStore {
    this.check();
    const value: AdaptiveStateStore = new AdaptiveStateStore(this.base, id); this.stores.push(value); return value;
  }

  private checkedState(owner: AdaptiveStateStore, result: AdaptiveStoreResult, status: string): AdaptiveDownloadState {
    if (owner.hasUncertainResources()) { this.cleanupSafe = false; throw new Error('PipelineStateResourceUncertain'); }
    this.check();
    if (result.status !== status || result.state === null) { throw new Error('PipelineStateUnavailable'); }
    return result.state;
  }

  private async fixture(primary: string[], secondary: string[] | null = null): Promise<PipelineFixture> {
    await this.prepare(); this.check();
    const first: HlsPlaylist | null = parseHlsMediaPlaylist('#EXTM3U\n' + primary.join('\n'),
      'https://probe.invalid/main.m3u8', resolveHlsUrl);
    const second: HlsPlaylist | null = secondary === null ? null : parseHlsMediaPlaylist('#EXTM3U\n' + secondary.join('\n'),
      'https://probe.invalid/audio.m3u8', resolveHlsUrl);
    if (first === null || (secondary !== null && second === null)) { throw new Error('PipelinePlanUnavailable'); }
    const plan: AdaptivePlan | null = buildHlsPlan('https://probe.invalid/main.m3u8', first,
      secondary === null ? '' : 'https://probe.invalid/audio.m3u8', second);
    if (plan === null) { throw new Error('PipelinePlanUnavailable'); }
    const id: string = util.generateRandomUUID(true);
    const initial: AdaptiveDownloadState | null = newAdaptiveState(id, plan);
    if (initial === null) { throw new Error('PipelineStateUnavailable'); }
    const store: AdaptiveStateStore = this.store(id);
    const saved: AdaptiveStoreResult = await store.save(initial, -1);
    const state: AdaptiveDownloadState = this.checkedState(store, saved, 'saved');
    if (this.evidenceDownloadId === '') { this.evidenceDownloadId = id; }
    return new PipelineFixture(state, store);
  }

  private serverPath(path: string): string {
    const base: string = this.source.trim();
    if (!isAdaptiveHttpUrl(base)) { throw new Error('PipelineServerUrlInvalid'); }
    return resolveHlsUrl(base, path);
  }

  private partPath(state: AdaptiveDownloadState, name: string): string {
    return this.base + '/' + state.downloadId + '/' + name;
  }

  private async fingerprint(path: string): Promise<string> {
    this.check(); const value: string = await hash.hash(path, 'sha256'); this.check(); return value;
  }

  private copyState(state: AdaptiveDownloadState): AdaptiveDownloadState {
    const copied: AdaptiveDownloadState | null = decodeAdaptiveState(encodeAdaptiveState(state), state.downloadId);
    if (copied === null) { throw new Error('PipelineStateUnavailable'); }
    return copied;
  }

  private async commit(fixture: PipelineFixture, state: AdaptiveDownloadState): Promise<AdaptiveDownloadState> {
    this.check();
    const result: AdaptiveStoreResult = await fixture.store.save(state, fixture.state.generation);
    const saved: AdaptiveDownloadState = this.checkedState(fixture.store, result, 'saved');
    fixture.state = saved;
    const reopened: AdaptiveStateStore = this.store(saved.downloadId);
    const loaded: AdaptiveStoreResult = await reopened.load();
    return this.checkedState(reopened, loaded, 'loaded');
  }

  private fileSafe(file: AttemptFileResult | null): boolean {
    return file === null || (file.closed && file.cleanupComplete && !file.resourceUncertain);
  }

  private executorSafe(result: AdaptiveAttemptResult): boolean {
    return result.kind !== 'resourceFault' && !result.stream.resourceUncertain &&
      result.stream.allSessionsApiClosed && this.fileSafe(result.file);
  }

  private noteAttempt(index: number, result: AdaptiveAttemptResult): void {
    const key: string = 'a' + String(index);
    this.note(key + 'Kind', result.kind); this.note(key + 'Outcome', result.settlement?.outcome ?? 'none');
    this.note(key + 'Error', result.errorCode); this.note(key + 'HeadSource', result.stream.headSource);
    this.note(key + 'HeadTrusted', result.stream.headTrusted); this.note(key + 'Received', result.receivedBytes);
    this.note(key + 'Written', result.writtenBytes); this.note(key + 'Eof', result.stream.eof);
    this.note(key + 'FetchSettled', result.stream.sdkPromiseSettled);
    this.note(key + 'DetachedFetch', result.stream.detachedFetchCount);
    this.note(key + 'ApiClosed', result.stream.allSessionsApiClosed);
    this.note(key + 'QueueHigh', result.stream.maxQueuedBytes);
  }

  private async download(ranged: boolean, stop: boolean): Promise<void> {
    const url: string = this.serverPath(ranged ? '/bytes' : '/whole');
    const lines: string[] = ranged ? ['#EXT-X-BYTERANGE:65536@0', url, '#EXT-X-BYTERANGE:65536@65536', url] : [url];
    const fixture: PipelineFixture = await this.fixture(lines); this.check();
    const limits: AdaptiveSchedulerLimits = new AdaptiveSchedulerLimits();
    limits.maxSegments = ranged ? 2 : 1; limits.maxRetry = 0; limits.retryDelayMs = 0;
    const runToken: string = util.generateRandomUUID(true);
    const scheduler: AdaptiveScheduler | null = AdaptiveScheduler.create(runToken, fixture.state, limits);
    if (scheduler === null) { throw new Error('PipelineSchedulerUnavailable'); }
    const policy: AdaptiveThrottlePolicy = new AdaptiveThrottlePolicy(); policy.taskKiBps = ranged ? 0 : 4;
    const gate: AdaptiveDownloadThrottle = new AdaptiveDownloadThrottle(fixture.state.downloadId, runToken, limits.maxSegments,
      (): AdaptiveThrottlePolicy => policy);
    this.gates.push(gate);
    const claims: AdaptiveDispatch[] = scheduler.claim(adaptiveNowMs(), limits.maxSegments);
    if (claims.length !== limits.maxSegments) { throw new Error('PipelineClaimsUnavailable'); }
    const owners: AdaptiveAttemptExecutor[] = [];
    for (let i = 0; i < claims.length; i++) {
      const options: AdaptiveAttemptOptions = new AdaptiveAttemptOptions();
      options.dispatch = claims[i]; options.tempBase = this.base;
      options.requestContext = new DownloadRequestContext(); options.networkTimeoutSeconds = 2;
      options.knownResourceTotal = ranged ? 524288 : -1;
      const owner: AdaptiveAttemptExecutor = new AdaptiveAttemptExecutor(options, gate);
      this.executors.push(owner); owners.push(owner);
      const window: AdaptiveRequestWindow | null = createAdaptiveWindow(claims[i].chunk, 0, options.knownResourceTotal);
      this.note('a' + String(i) + 'RequestStart', window?.remoteStart ?? -1);
      this.note('a' + String(i) + 'RequestEnd', window?.remoteEnd ?? -1);
    }
    const started: number = adaptiveNowMs();
    const tasks: Array<Promise<AdaptiveAttemptResult>> = [];
    for (let i = 0; i < owners.length; i++) { tasks.push(owners[i].run()); }
    let finished: boolean = false;
    let sampled: boolean = false;
    let pendingAt60: boolean = false;
    const timer: PipelineTimer | null = ranged ? null : this.timer(stop ? 1000 : 60000, (): void => {
      if (stop) {
        scheduler.requestPause();
        for (let i = 0; i < owners.length; i++) { owners[i].stop(); }
      } else { sampled = true; pendingAt60 = !finished; }
    });
    const results: AdaptiveAttemptResult[] = await Promise.all<AdaptiveAttemptResult>(tasks);
    finished = true;
    if (timer !== null) { this.stopTimer(timer); }
    this.check();
    this.note('elapsedMs', adaptiveNowMs() - started);
    if (!ranged) {
      this.note('timerFired', timer?.fired ?? false);
      this.note('sampleAt60', sampled); this.note('attemptPendingAt60', pendingAt60);
    }
    for (let i = 0; i < results.length; i++) {
      const observed: AdaptiveAttemptResult = results[i]; this.noteAttempt(i, observed);
      if (!this.executorSafe(observed)) { this.cleanupSafe = false; throw new Error('PipelineAttemptResourceUncertain'); }
      if (observed.kind !== 'settled' || observed.settlement === null) { throw new Error('PipelineAttemptUnavailable'); }
      const settled: AdaptiveSettlementResult = scheduler.settle(observed.settlement, adaptiveNowMs());
      if (!settled.accepted) { throw new Error('PipelineSettlementRejected'); }
    }
    const quiesced: AdaptiveQuiesced | null = scheduler.takeQuiesced();
    this.note('quiesced', quiesced?.reason ?? 'none'); this.note('readyForAssembly', quiesced?.readyForAssembly ?? false);
    const changed: AdaptiveDownloadState = this.copyState(fixture.state); changed.parts = scheduler.snapshotParts();
    const restored: AdaptiveDownloadState = await this.commit(fixture, changed); this.check();
    this.note('generation', restored.generation); this.note('parts', restored.parts.length);
    for (let i = 0; i < restored.parts.length; i++) {
      this.note('p' + String(i) + 'Bytes', restored.parts[i].downloaded);
      this.note('p' + String(i) + 'Complete', restored.parts[i].complete);
      if (restored.parts[i].fileName !== '') {
        const fingerprint: string = await this.fingerprint(this.partPath(restored, restored.parts[i].fileName)); this.check();
        this.note('p' + String(i) + 'Sha256', fingerprint);
      }
    }
    this.note('gatePending', gate.snapshot().pendingTickets);
  }

  private bytes(value: string): Uint8Array { return new util.TextEncoder().encodeInto(value); }

  private requireFile(value: AttemptFileResult, status: string): void {
    if (value.resourceUncertain || (status === 'sealed' && (!value.closed || !value.cleanupComplete))) {
      this.cleanupSafe = false; throw new Error('PipelineFileResourceUncertain');
    }
    if (value.status !== status || (status === 'sealed' && !value.sealed)) { throw new Error('PipelineFileUnavailable'); }
  }

  private async writePart(id: string, content: Uint8Array, name: string): Promise<AttemptFileResult> {
    this.check();
    const writer: AdaptiveAttemptFile = new AdaptiveAttemptFile(this.base, id, name, content.byteLength);
    this.writers.push(writer);
    const opened: AttemptFileResult = await writer.open('', 0); this.requireFile(opened, 'opened'); this.check();
    for (let offset = 0; offset < content.byteLength; offset += 65536) {
      const data: ArrayBuffer = content.slice(offset, Math.min(offset + 65536, content.byteLength)).buffer as ArrayBuffer;
      const appended: AttemptFileResult = await writer.append(data); this.requireFile(appended, 'appended'); this.check();
    }
    const sealed: AttemptFileResult = await writer.seal(content.byteLength);
    this.requireFile(sealed, 'sealed'); this.check(); return sealed;
  }

  private async fill(fixture: PipelineFixture, contents: Uint8Array[], prefixes: number[] = []): Promise<AdaptiveDownloadState> {
    const state: AdaptiveDownloadState = this.copyState(fixture.state);
    if (state.parts.length !== contents.length) { throw new Error('PipelineFixtureUnavailable'); }
    for (let i = 0; i < state.parts.length; i++) {
      const sealed: AttemptFileResult = await this.writePart(state.downloadId, contents[i], 'probe-' + util.generateRandomUUID(true) + '.part');
      this.check();
      state.parts[i].fileName = sealed.fileName;
      state.parts[i].downloaded = prefixes.length === 0 ? sealed.confirmedBytes : prefixes[i]; state.parts[i].complete = true;
    }
    return this.commit(fixture, state);
  }

  private assembler(state: AdaptiveDownloadState): AdaptiveAssembler {
    this.check(); const value: AdaptiveAssembler = new AdaptiveAssembler(this.base, state.downloadId);
    this.assemblers.push(value); return value;
  }

  private noteAssembly(prefix: string, result: AdaptiveAssemblyResult): void {
    this.note(prefix + 'Status', result.status); this.note(prefix + 'Error', result.errorCode);
    this.note(prefix + 'Bytes', result.outputBytes); this.note(prefix + 'Extension', result.extension);
    this.note(prefix + 'Output', result.outputName); this.note(prefix + 'Retained', result.retainedNames.length);
    this.note(prefix + 'Closed', result.closed); this.note(prefix + 'Uncertain', result.resourceUncertain);
    this.note(prefix + 'Cleanup', result.cleanupComplete); this.note(prefix + 'MediaStarted', result.mediaStarted);
    this.note(prefix + 'MediaSettled', result.mediaSettled); this.note(prefix + 'Stop', result.stopRequested);
    for (let i = 0; i < result.retainedNames.length; i++) { this.note(prefix + 'Retained' + String(i), result.retainedNames[i]); }
    if (!result.closed || result.resourceUncertain || !result.cleanupComplete) {
      this.cleanupSafe = false; throw new Error('PipelineAssemblyResourceUncertain');
    }
  }

  private async exactPrefix(): Promise<void> {
    const fixture: PipelineFixture = await this.fixture(['first.ts', 'second.ts']); this.check();
    const state: AdaptiveDownloadState = await this.fill(fixture, [this.bytes('abcTAIL'), this.bytes('defMORE')], [3, 3]); this.check();
    const first: string = await this.fingerprint(this.partPath(state, state.parts[0].fileName)); this.check();
    const second: string = await this.fingerprint(this.partPath(state, state.parts[1].fileName)); this.check();
    const slot1: string = await this.fingerprint(this.partPath(state, 'adaptive-state.1.json')); this.check();
    const slot2: string = await this.fingerprint(this.partPath(state, 'adaptive-state.2.json')); this.check();
    const output: AdaptiveAssemblyResult = await this.assembler(state).run(state); this.noteAssembly('asm', output); this.check();
    if (output.status === 'success') {
      this.note('outputSha256', await this.fingerprint(this.partPath(state, output.outputName))); this.check();
    }
    const firstAfter: string = await this.fingerprint(this.partPath(state, state.parts[0].fileName)); this.check();
    const secondAfter: string = await this.fingerprint(this.partPath(state, state.parts[1].fileName)); this.check();
    const slot1After: string = await this.fingerprint(this.partPath(state, 'adaptive-state.1.json')); this.check();
    const slot2After: string = await this.fingerprint(this.partPath(state, 'adaptive-state.2.json')); this.check();
    this.note('inputsUnchanged', first === firstAfter && second === secondAfter);
    this.note('slotsUnchanged', slot1 === slot1After && slot2 === slot2After);
  }

  private async nativeAssembly(loadRaw: PipelineRawLoader): Promise<void> {
    const video: Uint8Array = await loadRaw('native-media/video.mp4'); this.check();
    const audio: Uint8Array = await loadRaw('native-media/audio.m4a'); this.check();
    const fixture: PipelineFixture = await this.fixture(['v0.mp4', 'v1.mp4'], ['a0.m4a', 'a1.m4a']); this.check();
    const videoAt: number = Math.floor(video.length / 2); const audioAt: number = Math.floor(audio.length / 2);
    const contents: Uint8Array[] = [video.slice(0, videoAt), audio.slice(0, audioAt), video.slice(videoAt), audio.slice(audioAt)];
    const state: AdaptiveDownloadState = await this.fill(fixture, contents); this.check();
    this.note('videoBytes', video.length); this.note('audioBytes', audio.length);
    for (let i = 0; i < state.parts.length; i++) {
      this.note('p' + String(i) + 'Sha256', await this.fingerprint(this.partPath(state, state.parts[i].fileName))); this.check();
    }
    const result: AdaptiveAssemblyResult = await this.assembler(state).run(state); this.noteAssembly('asm', result); this.check();
    if (result.status === 'success') {
      if (result.retainedNames.length >= 2) {
        this.note('videoTrackSha256', await this.fingerprint(this.partPath(state, result.retainedNames[0]))); this.check();
        this.note('audioTrackSha256', await this.fingerprint(this.partPath(state, result.retainedNames[1]))); this.check();
      }
      this.note('outputSha256', await this.fingerprint(this.partPath(state, result.outputName))); this.check();
      this.note('outputFile', this.partPath(state, result.outputName));
    }
  }

  private async failures(): Promise<void> {
    const missing: PipelineFixture = await this.fixture(['missing.ts', 'kept.ts']); this.check();
    const missingState: AdaptiveDownloadState = await this.fill(missing, [this.bytes('gone'), this.bytes('kept')]); this.check();
    const retained: string = await this.fingerprint(this.partPath(missingState, missingState.parts[1].fileName)); this.check();
    const slot1: string = await this.fingerprint(this.partPath(missingState, 'adaptive-state.1.json')); this.check();
    const slot2: string = await this.fingerprint(this.partPath(missingState, 'adaptive-state.2.json')); this.check();
    // Only a freshly created input in this fixture is removed to exercise missing-file recovery.
    await fileIo.unlink(this.partPath(missingState, missingState.parts[0].fileName)); this.check();
    const failed: AdaptiveAssemblyResult = await this.assembler(missingState).run(missingState);
    this.noteAssembly('missing', failed); this.check();
    const retainedAfter: string = await this.fingerprint(this.partPath(missingState, missingState.parts[1].fileName)); this.check();
    const slot1After: string = await this.fingerprint(this.partPath(missingState, 'adaptive-state.1.json')); this.check();
    const slot2After: string = await this.fingerprint(this.partPath(missingState, 'adaptive-state.2.json')); this.check();
    this.note('missingKeptUnchanged', retained === retainedAfter);
    this.note('missingSlotsUnchanged', slot1 === slot1After && slot2 === slot2After);
    const stopped: PipelineFixture = await this.fixture(['first.ts', 'second.ts']); this.check();
    const state: AdaptiveDownloadState = await this.fill(stopped, [this.bytes('first'), this.bytes('second')]); this.check();
    const oldFirst: string = await this.fingerprint(this.partPath(state, state.parts[0].fileName)); this.check();
    const oldSecond: string = await this.fingerprint(this.partPath(state, state.parts[1].fileName)); this.check();
    const owner: AdaptiveAssembler = this.assembler(state);
    const result: AdaptiveAssemblyResult = await owner.run(state, (): void => { if (this.isCurrent()) { owner.cancel(); } });
    this.noteAssembly('cancel', result); this.check();
    const newFirst: string = await this.fingerprint(this.partPath(state, state.parts[0].fileName)); this.check();
    const newSecond: string = await this.fingerprint(this.partPath(state, state.parts[1].fileName)); this.check();
    this.note('cancelInputsUnchanged', oldFirst === newFirst && oldSecond === newSecond);
  }

  async execute(step: string, loadRaw: PipelineRawLoader): Promise<void> {
    this.check();
    if (step === 'S1') { await this.download(true, false); }
    else if (step === 'S2') { await this.download(false, false); }
    else if (step === 'S3') { await this.download(false, true); }
    else if (step === 'S4') { await this.exactPrefix(); }
    else if (step === 'S5') { await this.nativeAssembly(loadRaw); }
    else if (step === 'S6') { await this.failures(); }
    else { throw new Error('PipelineStepUnavailable'); }
    this.check();
  }

  async releaseResources(): Promise<boolean> {
    this.stopTimers();
    for (let i = 0; i < this.executors.length; i++) {
      try {
        this.executors[i].dispose();
        if (!this.executorSafe(await this.executors[i].drain())) { this.cleanupSafe = false; }
      } catch (_) { this.cleanupSafe = false; }
    }
    for (let i = 0; i < this.gates.length; i++) {
      this.gates[i].dispose();
      if (this.gates[i].snapshot().pendingTickets !== 0) { this.cleanupSafe = false; }
    }
    for (let i = 0; i < this.assemblers.length; i++) {
      try {
        this.assemblers[i].cancel();
        const ended: AdaptiveAssemblyResult = await this.assemblers[i].drain();
        if (!ended.closed || ended.resourceUncertain || !ended.cleanupComplete) { this.cleanupSafe = false; }
      } catch (_) { this.cleanupSafe = false; }
    }
    for (let i = 0; i < this.writers.length; i++) {
      try {
        this.writers[i].dispose();
        if (!this.fileSafe(await this.writers[i].drain())) { this.cleanupSafe = false; }
      } catch (_) { this.cleanupSafe = false; }
    }
    for (let i = 0; i < this.stores.length; i++) {
      try {
        this.stores[i].dispose(); await this.stores[i].drain();
        if (this.stores[i].hasUncertainResources()) { this.cleanupSafe = false; }
      } catch (_) { this.cleanupSafe = false; }
    }
    return this.cleanupSafe;
  }

  async writeEvidence(step: string): Promise<void> {
    this.check();
    if (!this.cleanupSafe || this.evidenceDownloadId === '') { return; }
    const details: PipelineDetails = new PipelineDetails();
    details.step = step; details.runId = this.runId; details.sessionToken = this.token;
    details.directory = this.base; details.facts = this.facts.slice();
    const content: Uint8Array = this.bytes(JSON.stringify(details, null, 2));
    if (content.byteLength > 65536) { throw new Error('PipelineEvidenceTooLarge'); }
    const name: string = 'details-' + util.generateRandomUUID(true) + '.part';
    await this.writePart(this.evidenceDownloadId, content, name); this.check();
    this.note('detailFile', this.base + '/' + this.evidenceDownloadId + '/' + name);
  }

  noteCleanup(complete: boolean): void { this.note('cleanupComplete', complete); }
}

@Component
export struct ProbeAdaptivePipeline {
  @State baseUrl: string = 'http://127.0.0.1:18766';
  private alive: boolean = false;
  private owner: AdaptivePipelineSession | undefined = undefined;

  aboutToAppear(): void { this.alive = true; }
  aboutToDisappear(): void { this.alive = false; this.owner?.cancel(); }

  private async runStep(step: string): Promise<void> {
    if (!this.alive) { return; }
    const kit: ProbeKit = ProbeKit.getInstance(); const token: string = kit.getSessionToken();
    if (!kit.isCurrent(token)) { return; }
    this.owner?.cancel();
    const context = this.getUIContext().getHostContext();
    const session: AdaptivePipelineSession = new AdaptivePipelineSession(context?.filesDir ?? '', this.baseUrl, token, kit.getRunId());
    this.owner = session;
    try {
      try {
        await session.execute(step, async (name: string): Promise<Uint8Array> => {
          if (context === undefined) { throw new Error('PipelineResourceContextUnavailable'); }
          return context.resourceManager.getRawFileContent(name);
        });
      } catch (error) { session.noteFailure(error as BusinessError); }
      const released: boolean = await session.releaseResources();
      if (!this.alive || this.owner !== session || !session.isCurrent()) { return; }
      session.noteCleanup(released);
      if (released) {
        try { await session.writeEvidence(step); } catch (error) { session.noteFailure(error as BusinessError); }
      }
      const finalReleased: boolean = await session.releaseResources();
      if (!this.alive || this.owner !== session || !session.isCurrent()) { return; }
      session.noteCleanup(finalReleased);
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
      ProbePage({ unitId: 'P6-U5', pageTitle: $r('app.string.probe_p6u5_title'), steps: PIPELINE_STEPS,
        autoStart: false, runStep: (step: string): Promise<void> => this.runStep(step) }).layoutWeight(1)
    }.width('100%').height('100%').padding(16)
  }
}
