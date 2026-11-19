// P7-U1-C mirrors ProbeAdaptiveController S1-S4 shapes with Dash plans, plus S5 directory
// ownership. Real E4 state machine over the fixed P7-U1 host segments; EXPECT is external.
import { fileIo, hash } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { ProbeKit, KeyValue } from '../core/ProbeKit';
import { ProbePage, ProbeStepDef } from '../core/ProbePage';
import { resolveHlsUrl } from '../../core/adaptive/HlsUrlResolver';
import { AdaptiveChunk, AdaptiveDownloadState, AdaptivePlan, AdaptiveTrack, buildDashPlan,
  copyAdaptivePlan, isAdaptiveHttpUrl } from '../../core/adaptive/AdaptivePlan';
import { AdaptiveRunController, AdaptiveRunInput, AdaptiveRunResult,
  AdaptiveReadyInput } from '../../core/adaptive/AdaptiveRunController';
import { AdaptiveThrottlePolicy, adaptiveNowMs } from '../../core/adaptive/AdaptiveDownloadThrottle';
import { AdaptiveAssembler, AdaptiveAssemblyResult } from '../../core/adaptive/AdaptiveAssembler';

const CONTROLLER_STEPS: ProbeStepDef[] = [
  { stepNo: 'S1', title: '运行、就绪租约、装配与恢复', autoRun: true },
  { stepNo: 'S2', title: '真实暂停与已提交前缀恢复', autoRun: true },
  { stepNo: 'S3', title: '读者准入前暂停', autoRun: true },
  { stepNo: 'S4', title: '读者准入后传递暂停', autoRun: true },
  { stepNo: 'S5', title: '目录属主', autoRun: true }
];

const DEFAULT_SOURCE: string = 'http://127.0.0.1:8795';

class DashControllerRunRef {
  input: AdaptiveRunInput;
  controller: AdaptiveRunController;

  constructor(input: AdaptiveRunInput, controller: AdaptiveRunController) {
    this.input = input;
    this.controller = controller;
  }
}

class DashControllerLeaseRef {
  ready: AdaptiveReadyInput;
  reader: AdaptiveAssembler | null = null;
  result: AdaptiveAssemblyResult | null = null;
  attached: boolean = false;
  started: boolean = false;
  returned: boolean = false;
  quarantined: boolean = false;
  unsafe: boolean = false;
  notifications: number = 0;

  constructor(ready: AdaptiveReadyInput) {
    this.ready = ready;
  }
}

class DashControllerTimer {
  id: number = -1;
  active: boolean = true;
  fired: boolean = false;
}

class DashControllerFingerprints {
  names: string[] = [];
  hashes: string[] = [];
}

function errorCodeOf(error: BusinessError): number {
  return error !== null && typeof error === 'object' && Number.isSafeInteger(error.code) ? error.code : -1;
}

/** Dash chunk 形态（与 MultiSourceDASHDownloader.CreateChunk 同构：offset=0/length=-1/isInit=false）。 */
function dashChunk(url: string, id: number, trackIndex: number, trackOrder: number): AdaptiveChunk {
  const chunk: AdaptiveChunk = new AdaptiveChunk();
  chunk.id = 'c' + String(id);
  chunk.trackIndex = trackIndex;
  chunk.trackOrder = trackOrder;
  chunk.url = url;
  chunk.offset = 0;
  chunk.length = -1;
  chunk.duration = 0;
  chunk.isInit = false;
  chunk.mediaSequence = trackOrder;
  chunk.discontinuity = false;
  chunk.discontinuitySequence = 0;
  return chunk;
}

/** E4/F 真属主适配器，限制在本步骤新建的夹具根内（ProbeAdaptiveController 同款形态）。 */
export class DashControllerProbeSession {
  readonly facts: KeyValue[] = [];
  private filesDir: string;
  private source: string;
  private token: string;
  private runId: string;
  private base: string = '';
  private cancelled: boolean = false;
  private cleanupSafe: boolean = true;
  private runs: DashControllerRunRef[] = [];
  private leases: DashControllerLeaseRef[] = [];
  private reads: Array<Promise<string>> = [];
  private timers: DashControllerTimer[] = [];
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
    if (!this.isCurrent()) { throw new Error('DashControllerProbeStopped'); }
  }

  private note(key: string, value: string | number | boolean): void {
    for (let i = 0; i < this.facts.length; i++) {
      if (this.facts[i].key === key) { this.facts[i].value = String(value); return; }
    }
    this.facts.push(new KeyValue(key, String(value)));
  }

  noteFailure(error: BusinessError): void {
    this.note('errCode', String(errorCodeOf(error)));
    this.note('err', 'DashControllerProbeFailure');
  }

  cancel(): void {
    this.cancelled = true;
    this.stopTimers();
    for (let i = 0; i < this.runs.length; i++) { this.runs[i].controller.pause(); }
    for (let i = 0; i < this.leases.length; i++) { this.leases[i].reader?.cancel(); }
  }

  private stopTimer(timer: DashControllerTimer): void {
    timer.active = false;
    const id: number = timer.id;
    timer.id = -1;
    if (id >= 0) { clearTimeout(id); }
  }

  private stopTimers(): void {
    for (let i = 0; i < this.timers.length; i++) { this.stopTimer(this.timers[i]); }
  }

  private timer(delay: number, action: () => void): DashControllerTimer {
    const timer: DashControllerTimer = new DashControllerTimer();
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
    if (this.filesDir === '') { throw new Error('DashControllerFilesUnavailable'); }
    const directory: string = this.filesDir + '/probe-dash-controller-' + util.generateRandomUUID(true);
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

  /** Dash 双轨计划（主机固定段 URL 直构）；single=true 时用单轨 muxed 形态驱动单分块暂停面
   * （业务侧单轨 DASH 不进计划——探针构造面，设计书 §3.2）。 */
  private async fixture(single: boolean): Promise<AdaptiveRunInput> {
    await this.prepare();
    this.check();
    const origin: string = this.source.trim();
    if (!isAdaptiveHttpUrl(origin)) { throw new Error('DashControllerServerInvalid'); }
    const manifestUrl: string = resolveHlsUrl(origin, '/mpd/probe.mpd');
    let plan: AdaptivePlan | null = null;
    if (single) {
      plan = this.singlePlan(manifestUrl, [resolveHlsUrl(origin, '/seg/p-v1-init.mp4'),
        resolveHlsUrl(origin, '/seg/p-v1-1.m4s')]);
    } else {
      const videoSegs: string[] = [resolveHlsUrl(origin, '/seg/p-v1-init.mp4'),
        resolveHlsUrl(origin, '/seg/p-v1-1.m4s'), resolveHlsUrl(origin, '/seg/p-v1-2.m4s')];
      const audioSegs: string[] = [resolveHlsUrl(origin, '/seg/p-a1-init.mp4'),
        resolveHlsUrl(origin, '/seg/p-a1-1.m4s'), resolveHlsUrl(origin, '/seg/p-a1-2.m4s')];
      plan = buildDashPlan(manifestUrl, videoSegs, 'video/mp4', audioSegs, 'audio/mp4', 120000, 120000);
    }
    if (plan === null) { throw new Error('DashControllerPlanUnavailable'); }
    const input: AdaptiveRunInput = this.input(util.generateRandomUUID(true), manifestUrl);
    input.freshPlan = plan;
    input.limits.maxSegments = single ? 1 : 2;
    return input;
  }

  /** 单轨 Dash 计划（copyAdaptivePlan 全量校验；两分块=init+media）。 */
  private singlePlan(manifestUrl: string, segments: string[]): AdaptivePlan | null {
    const plan: AdaptivePlan = new AdaptivePlan();
    plan.kind = 'Dash';
    plan.primaryUrl = manifestUrl;
    plan.secondaryUrl = '';
    plan.duration = 120000;
    const track: AdaptiveTrack = new AdaptiveTrack();
    track.index = 0;
    track.role = 'muxed';
    track.playlistUrl = manifestUrl;
    track.container = '.mp4';
    track.endList = true;
    plan.tracks.push(track);
    plan.suggestedExtension = '.mp4';
    for (let i = 0; i < segments.length; i++) {
      plan.chunks.push(dashChunk(segments[i], i, 0, i));
    }
    return copyAdaptivePlan(plan);
  }

  private make(input: AdaptiveRunInput, rate: number = 0): DashControllerRunRef {
    this.check();
    const policy: AdaptiveThrottlePolicy = new AdaptiveThrottlePolicy();
    policy.taskKiBps = rate;
    const controller: AdaptiveRunController = new AdaptiveRunController(input,
      (): AdaptiveThrottlePolicy => policy);
    const owned: DashControllerRunRef = new DashControllerRunRef(input, controller);
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
    this.leases.push(new DashControllerLeaseRef(ready));
  }

  private async run(owned: DashControllerRunRef): Promise<AdaptiveRunResult> {
    this.check();
    const result: AdaptiveRunResult = await owned.controller.run();
    this.adopt(result);
    this.check();
    if (!this.cleanupSafe) { throw new Error('DashControllerResourceUncertain'); }
    return result;
  }

  private ready(result: AdaptiveRunResult): DashControllerLeaseRef {
    const ready: AdaptiveReadyInput | null = result.ready;
    if (result.kind !== 'ready' || result.ownerDisposition !== 'heldForAssembly' || ready === null ||
      ready.tempBase !== this.base || ready.downloadId !== result.downloadId) {
      throw new Error('DashControllerReadyUnavailable');
    }
    for (let i = 0; i < this.leases.length; i++) {
      if (this.leases[i].ready.lease === ready.lease) { this.checkLease(this.leases[i]); return this.leases[i]; }
    }
    throw new Error('DashControllerLeaseUnavailable');
  }

  private checkLease(owned: DashControllerLeaseRef): void {
    this.check();
    if (owned.returned || owned.quarantined || !owned.ready.lease.isCurrent() ||
      owned.ready.lease.isStopRequested()) { throw new Error('DashControllerLeaseStopped'); }
  }

  private path(id: string, name: string): string { return this.base + '/' + id + '/' + name; }

  private async fingerprint(target: string, lease: DashControllerLeaseRef | null = null): Promise<string> {
    this.check();
    if (lease !== null) { this.checkLease(lease); }
    const pending: Promise<string> = hash.hash(target, 'sha256');
    this.reads.push(pending);
    try {
      const value: string = await pending;
      this.check();
      if (lease !== null) { this.checkLease(lease); }
      return value;
    } finally {
      const index: number = this.reads.indexOf(pending);
      if (index >= 0) { this.reads.splice(index, 1); }
    }
  }

  private async fingerprints(owned: DashControllerLeaseRef): Promise<DashControllerFingerprints> {
    this.checkLease(owned);
    if (!owned.attached) { throw new Error('DashControllerReaderNotAttached'); }
    const values: DashControllerFingerprints = new DashControllerFingerprints();
    for (let i = 0; i < owned.ready.state.parts.length; i++) {
      values.names.push(owned.ready.state.parts[i].fileName);
    }
    values.names.push('adaptive-state.1.json');
    values.names.push('adaptive-state.2.json');
    for (let i = 0; i < values.names.length; i++) {
      values.hashes.push(await this.fingerprint(this.path(owned.ready.downloadId, values.names[i]), owned));
    }
    return values;
  }

  private attach(owned: DashControllerLeaseRef): void {
    this.checkLease(owned);
    const reader: AdaptiveAssembler = new AdaptiveAssembler(this.base, owned.ready.downloadId);
    owned.reader = reader;
    owned.attached = owned.ready.lease.attachReader((): void => {
      owned.notifications++;
      reader.cancel();
    });
    if (!owned.attached) { throw new Error('DashControllerReaderRejected'); }
    this.checkLease(owned);
  }

  private assemblySafe(result: AdaptiveAssemblyResult): boolean {
    return result.closed && !result.resourceUncertain && result.cleanupComplete &&
      (!result.mediaStarted || result.mediaSettled);
  }

  private adoptAssembly(owned: DashControllerLeaseRef, result: AdaptiveAssemblyResult): void {
    owned.result = result;
    if (!this.assemblySafe(result)) { owned.unsafe = true; this.cleanupSafe = false; }
  }

  private noteAssembly(prefix: string, result: AdaptiveAssemblyResult): void {
    this.note(prefix + 'Status', result.status);
    this.note(prefix + 'Extension', result.extension);
    this.note(prefix + 'Bytes', result.outputBytes);
    this.note(prefix + 'Closed', result.closed);
    this.note(prefix + 'Uncertain', result.resourceUncertain);
    this.note(prefix + 'Cleanup', result.cleanupComplete);
  }

  private async assemble(owned: DashControllerLeaseRef,
    stopRun: DashControllerRunRef | null = null): Promise<AdaptiveAssemblyResult> {
    this.checkLease(owned);
    const reader: AdaptiveAssembler | null = owned.reader;
    if (!owned.attached || reader === null || owned.started) {
      throw new Error('DashControllerReaderUnavailable');
    }
    owned.started = true;
    const result: AdaptiveAssemblyResult = await reader.run(owned.ready.state, (): void => {
      if (stopRun !== null) { stopRun.controller.pause(); }
    });
    this.adoptAssembly(owned, result);
    this.check();
    const drained: AdaptiveAssemblyResult = await reader.drain();
    this.adoptAssembly(owned, drained);
    this.check();
    if (owned.unsafe) { throw new Error('DashControllerAssemblyUncertain'); }
    return result;
  }

  private returnLease(owned: DashControllerLeaseRef): boolean {
    if (owned.returned) { return false; }
    if (owned.quarantined || owned.unsafe || (owned.started && owned.result === null) || this.reads.length > 0) {
      owned.ready.lease.quarantine('DashControllerReaderResourceUncertain');
      owned.quarantined = true;
      this.cleanupSafe = false;
      return false;
    }
    const returned: boolean = owned.ready.lease.release();
    if (returned) { owned.returned = true; } else { this.cleanupSafe = false; }
    return returned;
  }

  /** S1：Dash 计划跑通 E4 → 租约 → 同 ID busy 拒绝 → 装配回填 → 恢复。 */
  private async normal(): Promise<void> {
    const input: AdaptiveRunInput = await this.fixture(false);
    const run: DashControllerRunRef = this.make(input);
    const result: AdaptiveRunResult = await this.run(run);
    this.note('firstKind', result.kind);
    this.note('commitGeneration', result.durableState?.generation ?? -1);
    const owned: DashControllerLeaseRef = this.ready(result);
    this.note('leaseCurrent', owned.ready.lease.isCurrent());
    const blocked: AdaptiveRunResult = await this.run(this.make(this.input(input.downloadId, input.request.url)));
    this.note('busyKind', blocked.kind);
    this.note('busyErrorCode', blocked.errorCode);
    if (blocked.kind !== 'rejected' || blocked.errorCode !== 'AdaptiveOwnerBusy') {
      throw new Error('DashControllerBusyMismatch');
    }
    this.attach(owned);
    this.note('readyLeaseAttach', owned.attached);
    const before: DashControllerFingerprints = await this.fingerprints(owned);
    const assembled: AdaptiveAssemblyResult = await this.assemble(owned);
    this.noteAssembly('asm', assembled);
    if (assembled.status !== 'success') { throw new Error('DashControllerAssemblyFailed'); }
    this.note('outputSha256', await this.fingerprint(this.path(input.downloadId, assembled.outputName), owned));
    const after: DashControllerFingerprints = await this.fingerprints(owned);
    this.note('drainClean', JSON.stringify(before) === JSON.stringify(after));
    this.note('leaseReleased', this.returnLease(owned));
    this.check();
    const restored: AdaptiveRunResult = await this.run(this.make(this.input(input.downloadId, input.request.url)));
    this.note('restoredKind', restored.kind);
    const next: DashControllerLeaseRef = this.ready(restored);
    this.note('restoredLeaseReleased', this.returnLease(next));
  }

  /** S2：限速运行 → pause → freshPlan=null 重开恢复 → ready + 已提交前缀保真。 */
  private async pauseResume(): Promise<void> {
    const input: AdaptiveRunInput = await this.fixture(true);
    const first: DashControllerRunRef = this.make(input, 4);
    const started: number = adaptiveNowMs();
    const pending: Promise<AdaptiveRunResult> = this.run(first);
    const timer: DashControllerTimer = this.timer(1000, (): void => first.controller.pause());
    const paused: AdaptiveRunResult = await pending;
    this.stopTimer(timer);
    this.check();
    this.note('pauseTimerFired', timer.fired);
    this.note('pauseElapsedMs', adaptiveNowMs() - started);
    this.note('pausedKind', paused.kind);
    const state: AdaptiveDownloadState | null = paused.durableState;
    if (!timer.fired || paused.kind !== 'paused' || paused.ownerDisposition !== 'released' || state === null ||
      state.parts.length !== 2 || state.parts[1].complete) { throw new Error('DashControllerPauseMismatch'); }
    const prefixName: string = state.parts[0].fileName;
    this.note('nonzeroPrefix', state.parts[0].downloaded > 0);
    let prefixHash: string = '';
    if (prefixName !== '') { prefixHash = await this.fingerprint(this.path(input.downloadId, prefixName)); }
    const resumedInput: AdaptiveRunInput = this.input(input.downloadId, input.request.url);
    resumedInput.limits.maxSegments = 1;
    const resumed: AdaptiveRunResult = await this.run(this.make(resumedInput));
    this.note('resumedKind', resumed.kind);
    const owned: DashControllerLeaseRef = this.ready(resumed);
    this.attach(owned);
    const assembled: AdaptiveAssemblyResult = await this.assemble(owned);
    this.noteAssembly('asm', assembled);
    if (assembled.status !== 'success') { throw new Error('DashControllerAssemblyFailed'); }
    this.note('prefixBytesFidelity', state.parts[0].downloaded);
    if (prefixName !== '') {
      const after: string = await this.fingerprint(this.path(input.downloadId, prefixName), owned);
      this.note('oldPrefixUnchanged', prefixHash === after);
    }
    this.note('leaseReleased', this.returnLease(owned));
  }

  /** S3：ready 后先 pause 再 attach → 拒绝（读者准入前暂停干净）。 */
  private async beforeAttach(): Promise<void> {
    const input: AdaptiveRunInput = await this.fixture(false);
    const run: DashControllerRunRef = this.make(input);
    const result: AdaptiveRunResult = await this.run(run);
    this.note('firstKind', result.kind);
    const owned: DashControllerLeaseRef = this.ready(result);
    run.controller.pause();
    owned.attached = owned.ready.lease.attachReader((): void => { owned.notifications++; });
    this.note('stopRequested', owned.ready.lease.isStopRequested());
    this.note('attached', owned.attached);
    this.note('readerStarted', owned.started);
    const repeated: AdaptiveRunResult = await run.controller.drain();
    this.adopt(repeated);
    this.check();
    this.note('drainedKind', repeated.kind);
    this.note('leaseReleased', this.returnLease(owned));
    this.note('leaseCurrentAfterRelease', owned.ready.lease.isCurrent());
    this.note('secondRelease', owned.ready.lease.release());
    if (owned.attached) { throw new Error('DashControllerStoppedAttachAccepted'); }
    this.note('cancelledClean', String(!owned.attached));
  }

  /** S4：attach 后装配中 pause → onStop 传递 → reader 收到停止通知。 */
  private async afterAttach(): Promise<void> {
    const input: AdaptiveRunInput = await this.fixture(false);
    const run: DashControllerRunRef = this.make(input);
    const result: AdaptiveRunResult = await this.run(run);
    this.note('firstKind', result.kind);
    const owned: DashControllerLeaseRef = this.ready(result);
    this.attach(owned);
    this.note('attached', owned.attached);
    const assembled: AdaptiveAssemblyResult = await this.assemble(owned, run);
    this.noteAssembly('asm', assembled);
    run.controller.pause();
    this.note('stopNotifications', owned.notifications);
    this.note('readerStopNotified', owned.notifications > 0);
    this.note('stopRequested', owned.ready.lease.isStopRequested());
    const repeated: AdaptiveRunResult = await run.controller.drain();
    this.adopt(repeated);
    this.check();
    this.note('drainedKind', repeated.kind);
    this.note('leaseReleased', this.returnLease(owned));
  }

  /** S5：同目录第二 controller → AdaptiveOwnerBusy（目录属主单写者）。 */
  private async ownerGuard(): Promise<void> {
    const input: AdaptiveRunInput = await this.fixture(false);
    const first: DashControllerRunRef = this.make(input);
    const firstResult: AdaptiveRunResult = await this.run(first);
    this.note('firstKind', firstResult.kind);
    if (firstResult.kind !== 'ready') { throw new Error('DashControllerOwnerFirstNotReady'); }
    const second: DashControllerRunRef = this.make(this.input(input.downloadId, input.request.url));
    const secondResult: AdaptiveRunResult = await this.run(second);
    this.note('ownerRejected', secondResult.kind === 'rejected' ? secondResult.errorCode : secondResult.kind);
    if (secondResult.kind !== 'rejected' || secondResult.errorCode !== 'AdaptiveOwnerBusy') {
      throw new Error('DashControllerOwnerMismatch');
    }
    const owned: DashControllerLeaseRef = this.ready(firstResult);
    this.note('leaseReleased', this.returnLease(owned));
  }

  execute(step: string): Promise<void> {
    if (this.business === null) { this.business = this.executeOwned(step); }
    return this.business;
  }

  private async executeOwned(step: string): Promise<void> {
    try {
      this.check();
      if (step === 'S1') { await this.normal(); }
      else if (step === 'S2') { await this.pauseResume(); }
      else if (step === 'S3') { await this.beforeAttach(); }
      else if (step === 'S4') { await this.afterAttach(); }
      else if (step === 'S5') { await this.ownerGuard(); }
      else { throw new Error('DashControllerStepUnavailable'); }
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
      const owned: DashControllerLeaseRef = this.leases[i];
      if (owned.reader !== null) {
        try { owned.reader.cancel(); this.adoptAssembly(owned, await owned.reader.drain()); }
        catch (e) { owned.unsafe = true; this.cleanupSafe = false; }
      }
    }
    const reads: Array<Promise<string>> = this.reads.slice();
    for (let i = 0; i < reads.length; i++) {
      try { await reads[i]; } catch (e) { this.cleanupSafe = false; }
    }
    for (let i = 0; i < this.leases.length; i++) {
      if (!this.leases[i].returned && !this.leases[i].quarantined) { this.returnLease(this.leases[i]); }
    }
    return this.cleanupSafe;
  }

  noteCleanup(value: boolean): void { this.note('cleanupComplete', value); }
}

@Component
export struct ProbeDashController {
  @State baseUrl: string = DEFAULT_SOURCE;
  private alive: boolean = false;
  private owner: DashControllerProbeSession | undefined = undefined;

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
    const session: DashControllerProbeSession = new DashControllerProbeSession(context?.filesDir ?? '',
      this.baseUrl, token, kit.getRunId());
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
      ProbePage({ unitId: 'P7-U1-C', pageTitle: $r('app.string.probe_p7u1_controller_title'),
        steps: CONTROLLER_STEPS, autoStart: false,
        runStep: (step: string): Promise<void> => this.runStep(step) }).layoutWeight(1)
    }.width('100%').height('100%').padding(16)
  }
}
