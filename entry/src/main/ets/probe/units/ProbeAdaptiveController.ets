import { fileIo, hash } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { ProbeKit, KeyValue } from '../core/ProbeKit';
import { ProbePage, ProbeStepDef } from '../core/ProbePage';
import { HlsPlaylist } from '../../core/adaptive/HlsModel';
import { parseHlsMediaPlaylist } from '../../core/adaptive/HlsParser';
import { resolveHlsUrl } from '../../core/adaptive/HlsUrlResolver';
import { AdaptivePlan, AdaptiveDownloadState, buildHlsPlan, isAdaptiveHttpUrl } from '../../core/adaptive/AdaptivePlan';
import { AdaptiveRunController, AdaptiveRunInput, AdaptiveRunResult,
  AdaptiveReadyInput } from '../../core/adaptive/AdaptiveRunController';
import { AdaptiveThrottlePolicy, adaptiveNowMs } from '../../core/adaptive/AdaptiveDownloadThrottle';
import { AdaptiveAssembler, AdaptiveAssemblyResult } from '../../core/adaptive/AdaptiveAssembler';
import { AdaptiveAttemptFile, AttemptFileResult } from '../../core/adaptive/AdaptiveAttemptFile';

const CONTROLLER_STEPS: ProbeStepDef[] = [
  { stepNo: 'S1', title: '运行、就绪租约、装配与恢复', autoRun: true },
  { stepNo: 'S2', title: '真实暂停与已提交前缀恢复', autoRun: true },
  { stepNo: 'S3', title: '读者准入前暂停', autoRun: true },
  { stepNo: 'S4', title: '读者准入后传递暂停', autoRun: true }
];

class ControllerRunRef {
  input: AdaptiveRunInput;
  controller: AdaptiveRunController;
  constructor(input: AdaptiveRunInput, controller: AdaptiveRunController) {
    this.input = input; this.controller = controller;
  }
}

class ControllerLeaseRef {
  ready: AdaptiveReadyInput;
  reader: AdaptiveAssembler | null = null;
  result: AdaptiveAssemblyResult | null = null;
  attached: boolean = false;
  started: boolean = false;
  returned: boolean = false;
  quarantined: boolean = false;
  unsafe: boolean = false;
  notifications: number = 0;
  constructor(ready: AdaptiveReadyInput) { this.ready = ready; }
}

class ControllerTimer {
  id: number = -1;
  active: boolean = true;
  fired: boolean = false;
}

class ControllerFingerprints {
  names: string[] = [];
  hashes: string[] = [];
}

class ControllerDetails {
  unit: string = 'P6-U6';
  step: string = '';
  runId: string = '';
  sessionToken: string = '';
  directory: string = '';
  facts: KeyValue[] = [];
}

/** Actual E4/F ownership adapter, restricted to this step's freshly created fixture root. */
export class AdaptiveControllerProbeSession {
  readonly facts: KeyValue[] = [];
  private filesDir: string;
  private source: string;
  private token: string;
  private runId: string;
  private base: string = '';
  private evidenceId: string = '';
  private cancelled: boolean = false;
  private cleanupSafe: boolean = true;
  private runs: ControllerRunRef[] = [];
  private leases: ControllerLeaseRef[] = [];
  private writers: AdaptiveAttemptFile[] = [];
  private reads: Array<Promise<string>> = [];
  private timers: ControllerTimer[] = [];
  private business: Promise<void> | null = null;
  private businessFinished: boolean = false;
  private releasing: Promise<boolean> | null = null;

  constructor(filesDir: string, source: string, token: string, runId: string) {
    this.filesDir = filesDir; this.source = source; this.token = token; this.runId = runId;
  }

  isCurrent(): boolean { return !this.cancelled && ProbeKit.getInstance().isCurrent(this.token); }
  private check(): void { if (!this.isCurrent()) { throw new Error('ControllerProbeStopped'); } }
  private note(key: string, value: string | number | boolean): void {
    for (let i = 0; i < this.facts.length; i++) {
      if (this.facts[i].key === key) { this.facts[i].value = String(value); return; }
    }
    this.facts.push(new KeyValue(key, String(value)));
  }

  noteFailure(error: BusinessError): void {
    this.note('errCode', error.code ?? -1); this.note('err', 'ControllerProbeFailure');
  }

  cancel(): void {
    this.cancelled = true; this.stopTimers();
    for (let i = 0; i < this.runs.length; i++) { this.runs[i].controller.pause(); }
    for (let i = 0; i < this.leases.length; i++) { this.leases[i].reader?.cancel(); }
    for (let i = 0; i < this.writers.length; i++) { this.writers[i].dispose(); }
  }

  private stopTimer(timer: ControllerTimer): void {
    timer.active = false; const id: number = timer.id; timer.id = -1;
    if (id >= 0) { clearTimeout(id); }
  }

  private stopTimers(): void { for (let i = 0; i < this.timers.length; i++) { this.stopTimer(this.timers[i]); } }

  private timer(delay: number, action: () => void): ControllerTimer {
    const timer: ControllerTimer = new ControllerTimer(); this.timers.push(timer);
    timer.id = setTimeout((): void => {
      if (!timer.active || !this.isCurrent()) { return; }
      timer.active = false; timer.id = -1; timer.fired = true; action();
    }, delay);
    return timer;
  }

  private async prepare(): Promise<void> {
    this.check(); if (this.base !== '') { return; }
    if (this.filesDir === '') { throw new Error('ControllerFilesUnavailable'); }
    const directory: string = this.filesDir + '/probe-adaptive-controller-' + util.generateRandomUUID(true);
    await fileIo.mkdir(directory, false);
    this.base = directory; this.check();
  }

  private async fixture(ranged: boolean): Promise<AdaptiveRunInput> {
    await this.prepare(); this.check();
    const origin: string = this.source.trim();
    if (!isAdaptiveHttpUrl(origin)) { throw new Error('ControllerServerInvalid'); }
    const target: string = resolveHlsUrl(origin, '/bytes');
    const manifestUrl: string = resolveHlsUrl(origin, '/inline-probe.m3u8');
    const lines: string = ranged ? '#EXT-X-BYTERANGE:65536@0\n' + target +
      '\n#EXT-X-BYTERANGE:65536@65536\n' + target : target;
    const media: HlsPlaylist | null = parseHlsMediaPlaylist('#EXTM3U\n' + lines + '\n#EXT-X-ENDLIST\n', manifestUrl, resolveHlsUrl);
    if (media === null) { throw new Error('ControllerPlanUnavailable'); }
    const plan: AdaptivePlan | null = buildHlsPlan(manifestUrl, media);
    if (plan === null) { throw new Error('ControllerPlanUnavailable'); }
    const input: AdaptiveRunInput = this.input(util.generateRandomUUID(true), manifestUrl);
    input.freshPlan = plan; input.limits.maxSegments = ranged ? 2 : 1;
    return input;
  }

  private input(id: string, url: string): AdaptiveRunInput {
    const input: AdaptiveRunInput = new AdaptiveRunInput();
    input.downloadId = id; input.runToken = util.generateRandomUUID(true); input.tempBase = this.base;
    input.request.url = url; input.limits.maxSegments = 2; input.limits.maxRetry = 0;
    input.limits.retryDelayMs = 0; input.networkTimeoutSeconds = 2;
    return input;
  }

  private make(input: AdaptiveRunInput, rate: number = 0): ControllerRunRef {
    this.check();
    const policy: AdaptiveThrottlePolicy = new AdaptiveThrottlePolicy(); policy.taskKiBps = rate;
    const controller: AdaptiveRunController = new AdaptiveRunController(input, (): AdaptiveThrottlePolicy => policy);
    const owned: ControllerRunRef = new ControllerRunRef(input, controller); this.runs.push(owned); return owned;
  }

  private adopt(result: AdaptiveRunResult): void {
    if (result.kind === 'resourceFault' || result.ownerDisposition === 'quarantined') { this.cleanupSafe = false; }
    const ready: AdaptiveReadyInput | null = result.ready;
    if (ready === null) { return; }
    for (let i = 0; i < this.leases.length; i++) {
      if (this.leases[i].ready.lease === ready.lease) { return; }
    }
    this.leases.push(new ControllerLeaseRef(ready));
  }

  private async run(owned: ControllerRunRef): Promise<AdaptiveRunResult> {
    this.check(); const result: AdaptiveRunResult = await owned.controller.run();
    this.adopt(result); this.check();
    if (!this.cleanupSafe) { throw new Error('ControllerResourceUncertain'); }
    return result;
  }

  private noteRun(prefix: string, result: AdaptiveRunResult): void {
    this.note(prefix + 'Kind', result.kind); this.note(prefix + 'Owner', result.ownerDisposition);
    this.note(prefix + 'Error', result.errorCode);
    const state: AdaptiveDownloadState | null = result.durableState;
    this.note(prefix + 'Generation', state?.generation ?? -1); this.note(prefix + 'Parts', state?.parts.length ?? 0);
    if (state !== null) {
      for (let i = 0; i < state.parts.length; i++) {
        this.note(prefix + 'P' + String(i) + 'Bytes', state.parts[i].downloaded);
        this.note(prefix + 'P' + String(i) + 'Complete', state.parts[i].complete);
      }
    }
  }

  private ready(result: AdaptiveRunResult): ControllerLeaseRef {
    const ready: AdaptiveReadyInput | null = result.ready;
    if (result.kind !== 'ready' || result.ownerDisposition !== 'heldForAssembly' || ready === null ||
      ready.tempBase !== this.base || ready.downloadId !== result.downloadId) { throw new Error('ControllerReadyUnavailable'); }
    for (let i = 0; i < this.leases.length; i++) {
      if (this.leases[i].ready.lease === ready.lease) { this.checkLease(this.leases[i]); return this.leases[i]; }
    }
    throw new Error('ControllerLeaseUnavailable');
  }

  private checkLease(owned: ControllerLeaseRef): void {
    this.check();
    if (owned.returned || owned.quarantined || !owned.ready.lease.isCurrent() || owned.ready.lease.isStopRequested()) {
      throw new Error('ControllerLeaseStopped');
    }
  }

  private path(id: string, name: string): string { return this.base + '/' + id + '/' + name; }

  private async fingerprint(target: string, lease: ControllerLeaseRef | null = null): Promise<string> {
    this.check(); if (lease !== null) { this.checkLease(lease); }
    const pending: Promise<string> = hash.hash(target, 'sha256'); this.reads.push(pending);
    try {
      const value: string = await pending;
      this.check(); if (lease !== null) { this.checkLease(lease); } return value;
    } finally {
      const index: number = this.reads.indexOf(pending); if (index >= 0) { this.reads.splice(index, 1); }
    }
  }

  private async fingerprints(owned: ControllerLeaseRef): Promise<ControllerFingerprints> {
    this.checkLease(owned);
    if (!owned.attached) { throw new Error('ControllerReaderNotAttached'); }
    const values: ControllerFingerprints = new ControllerFingerprints();
    for (let i = 0; i < owned.ready.state.parts.length; i++) { values.names.push(owned.ready.state.parts[i].fileName); }
    values.names.push('adaptive-state.1.json'); values.names.push('adaptive-state.2.json');
    for (let i = 0; i < values.names.length; i++) {
      values.hashes.push(await this.fingerprint(this.path(owned.ready.downloadId, values.names[i]), owned));
    }
    return values;
  }

  private attach(owned: ControllerLeaseRef): void {
    this.checkLease(owned);
    const reader: AdaptiveAssembler = new AdaptiveAssembler(this.base, owned.ready.downloadId);
    owned.reader = reader;
    owned.attached = owned.ready.lease.attachReader((): void => { owned.notifications++; reader.cancel(); });
    if (!owned.attached) { throw new Error('ControllerReaderRejected'); }
    this.checkLease(owned);
  }

  private assemblySafe(result: AdaptiveAssemblyResult): boolean {
    return result.closed && !result.resourceUncertain && result.cleanupComplete && (!result.mediaStarted || result.mediaSettled);
  }

  private adoptAssembly(owned: ControllerLeaseRef, result: AdaptiveAssemblyResult): void {
    owned.result = result;
    if (!this.assemblySafe(result)) { owned.unsafe = true; this.cleanupSafe = false; }
  }

  private noteAssembly(prefix: string, result: AdaptiveAssemblyResult): void {
    this.note(prefix + 'Status', result.status); this.note(prefix + 'Error', result.errorCode);
    this.note(prefix + 'Bytes', result.outputBytes); this.note(prefix + 'Output', result.outputName);
    this.note(prefix + 'Closed', result.closed); this.note(prefix + 'Uncertain', result.resourceUncertain);
    this.note(prefix + 'Cleanup', result.cleanupComplete); this.note(prefix + 'MediaStarted', result.mediaStarted);
    this.note(prefix + 'MediaSettled', result.mediaSettled); this.note(prefix + 'Retained', result.retainedNames.length);
  }

  private async assemble(owned: ControllerLeaseRef, stopRun: ControllerRunRef | null = null): Promise<AdaptiveAssemblyResult> {
    this.checkLease(owned); const reader: AdaptiveAssembler | null = owned.reader;
    if (!owned.attached || reader === null || owned.started) { throw new Error('ControllerReaderUnavailable'); }
    owned.started = true;
    const result: AdaptiveAssemblyResult = await reader.run(owned.ready.state, (): void => {
      if (stopRun !== null) { stopRun.controller.pause(); }
    });
    this.adoptAssembly(owned, result); this.check();
    const drained: AdaptiveAssemblyResult = await reader.drain(); this.adoptAssembly(owned, drained); this.check();
    if (owned.unsafe) { throw new Error('ControllerAssemblyUncertain'); }
    return result;
  }

  private returnLease(owned: ControllerLeaseRef): boolean {
    if (owned.returned) { return false; }
    if (owned.quarantined || owned.unsafe || (owned.started && owned.result === null) || this.reads.length > 0) {
      owned.ready.lease.quarantine('ControllerReaderResourceUncertain'); owned.quarantined = true;
      this.cleanupSafe = false; return false;
    }
    const returned: boolean = owned.ready.lease.release();
    if (returned) { owned.returned = true; }
    else { this.cleanupSafe = false; }
    return returned;
  }

  private async normal(): Promise<void> {
    const input: AdaptiveRunInput = await this.fixture(true);
    const run: ControllerRunRef = this.make(input); const result: AdaptiveRunResult = await this.run(run);
    this.noteRun('first', result); const owned: ControllerLeaseRef = this.ready(result);
    this.note('leaseCurrent', owned.ready.lease.isCurrent());
    const blocked: AdaptiveRunResult = await this.run(this.make(this.input(input.downloadId, input.request.url)));
    this.noteRun('busy', blocked);
    if (blocked.kind !== 'rejected' || blocked.errorCode !== 'AdaptiveOwnerBusy') { throw new Error('ControllerBusyMismatch'); }
    this.attach(owned); this.note('attached', owned.attached);
    const before: ControllerFingerprints = await this.fingerprints(owned);
    const assembled: AdaptiveAssemblyResult = await this.assemble(owned); this.noteAssembly('asm', assembled);
    if (assembled.status !== 'success') { throw new Error('ControllerAssemblyFailed'); }
    this.note('outputSha256', await this.fingerprint(this.path(input.downloadId, assembled.outputName), owned));
    const after: ControllerFingerprints = await this.fingerprints(owned);
    this.note('inputsAndSlotsUnchanged', JSON.stringify(before) === JSON.stringify(after));
    this.note('leaseReleased', this.returnLease(owned)); this.check();
    const restored: AdaptiveRunResult = await this.run(this.make(this.input(input.downloadId, input.request.url)));
    this.noteRun('restored', restored); const next: ControllerLeaseRef = this.ready(restored);
    this.note('restoredLeaseReleased', this.returnLease(next));
  }

  private async pauseResume(): Promise<void> {
    const input: AdaptiveRunInput = await this.fixture(false); const first: ControllerRunRef = this.make(input, 4);
    const started: number = adaptiveNowMs(); const pending: Promise<AdaptiveRunResult> = this.run(first);
    const timer: ControllerTimer = this.timer(1000, (): void => first.controller.pause());
    const paused: AdaptiveRunResult = await pending; this.stopTimer(timer); this.check();
    this.note('pauseTimerFired', timer.fired); this.note('pauseElapsedMs', adaptiveNowMs() - started); this.noteRun('paused', paused);
    const state: AdaptiveDownloadState | null = paused.durableState;
    if (!timer.fired || paused.kind !== 'paused' || paused.ownerDisposition !== 'released' || state === null ||
      state.parts.length !== 1 || state.parts[0].complete) { throw new Error('ControllerPauseMismatch'); }
    const prefixName: string = state.parts[0].fileName;
    this.note('nonzeroPrefix', state.parts[0].downloaded > 0);
    let prefixHash: string = '';
    if (prefixName !== '') { prefixHash = await this.fingerprint(this.path(input.downloadId, prefixName)); }
    const resumedInput: AdaptiveRunInput = this.input(input.downloadId, input.request.url); resumedInput.limits.maxSegments = 1;
    const resumed: AdaptiveRunResult = await this.run(this.make(resumedInput)); this.noteRun('resumed', resumed);
    const owned: ControllerLeaseRef = this.ready(resumed); this.attach(owned);
    const assembled: AdaptiveAssemblyResult = await this.assemble(owned); this.noteAssembly('asm', assembled);
    if (assembled.status !== 'success') { throw new Error('ControllerAssemblyFailed'); }
    this.note('outputSha256', await this.fingerprint(this.path(input.downloadId, assembled.outputName), owned));
    if (prefixName !== '') {
      const after: string = await this.fingerprint(this.path(input.downloadId, prefixName), owned);
      this.note('oldPrefixUnchanged', prefixHash === after);
    }
    this.note('leaseReleased', this.returnLease(owned));
  }

  private async beforeAttach(): Promise<void> {
    const input: AdaptiveRunInput = await this.fixture(true); const run: ControllerRunRef = this.make(input);
    const result: AdaptiveRunResult = await this.run(run); this.noteRun('first', result);
    const owned: ControllerLeaseRef = this.ready(result); run.controller.pause();
    owned.attached = owned.ready.lease.attachReader((): void => { owned.notifications++; });
    this.note('stopRequested', owned.ready.lease.isStopRequested()); this.note('attached', owned.attached);
    this.note('readerStarted', owned.started);
    const repeated: AdaptiveRunResult = await run.controller.drain(); this.adopt(repeated); this.check(); this.noteRun('drained', repeated);
    this.note('leaseReleased', this.returnLease(owned));
    this.note('leaseCurrentAfterRelease', owned.ready.lease.isCurrent()); this.note('secondRelease', owned.ready.lease.release());
    if (owned.attached) { throw new Error('ControllerStoppedAttachAccepted'); }
  }

  private async afterAttach(): Promise<void> {
    const input: AdaptiveRunInput = await this.fixture(true); const run: ControllerRunRef = this.make(input);
    const result: AdaptiveRunResult = await this.run(run); this.noteRun('first', result);
    const owned: ControllerLeaseRef = this.ready(result); this.attach(owned);
    this.note('attached', owned.attached); this.note('secondAttach', owned.ready.lease.attachReader((): void => {}));
    const before: ControllerFingerprints = await this.fingerprints(owned);
    this.note('inputDirectory', this.base + '/' + input.downloadId);
    for (let i = 0; i < before.names.length; i++) {
      this.note('beforeName' + String(i), before.names[i]); this.note('beforeSha256_' + String(i), before.hashes[i]);
    }
    const assembled: AdaptiveAssemblyResult = await this.assemble(owned, run); this.noteAssembly('asm', assembled);
    run.controller.pause(); this.note('stopNotifications', owned.notifications);
    this.note('stopRequested', owned.ready.lease.isStopRequested());
    const repeated: AdaptiveRunResult = await run.controller.drain(); this.adopt(repeated); this.check(); this.noteRun('drained', repeated);
    // No new file reads after the reader's stop. The exported files can be compared to beforeSha256_*.
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
      else { throw new Error('ControllerStepUnavailable'); }
      this.check();
    } finally { this.businessFinished = true; }
  }

  releaseResources(): Promise<boolean> {
    if (this.releasing !== null) { return this.releasing; }
    const work: Promise<boolean> = this.releaseOwned(); this.releasing = work;
    return work.then<boolean>((value: boolean): boolean => {
      if (this.releasing === work) { this.releasing = null; } return value;
    });
  }

  private async releaseOwned(): Promise<boolean> {
    this.stopTimers();
    if (this.business !== null && !this.businessFinished) { this.cancel(); }
    if (this.business !== null) { try { await this.business; } catch (_) { /* Primary caller records the failure. */ } }
    for (let i = 0; i < this.runs.length; i++) {
      try { this.runs[i].controller.pause(); this.adopt(await this.runs[i].controller.drain()); }
      catch (_) { this.cleanupSafe = false; }
    }
    for (let i = 0; i < this.leases.length; i++) {
      const owned: ControllerLeaseRef = this.leases[i];
      if (owned.reader !== null) {
        try { owned.reader.cancel(); this.adoptAssembly(owned, await owned.reader.drain()); }
        catch (_) { owned.unsafe = true; this.cleanupSafe = false; }
      }
    }
    const reads: Array<Promise<string>> = this.reads.slice();
    for (let i = 0; i < reads.length; i++) { try { await reads[i]; } catch (_) { this.cleanupSafe = false; } }
    for (let i = 0; i < this.leases.length; i++) {
      if (!this.leases[i].returned && !this.leases[i].quarantined) { this.returnLease(this.leases[i]); }
    }
    for (let i = 0; i < this.writers.length; i++) {
      try {
        this.writers[i].dispose(); const value: AttemptFileResult = await this.writers[i].drain();
        if (!value.closed || value.resourceUncertain || !value.cleanupComplete) { this.cleanupSafe = false; }
      } catch (_) { this.cleanupSafe = false; }
    }
    return this.cleanupSafe;
  }

  private evidenceResult(value: AttemptFileResult, expected: string): void {
    if (value.resourceUncertain || (expected === 'sealed' && (!value.closed || !value.cleanupComplete))) {
      this.cleanupSafe = false; throw new Error('ControllerEvidenceUncertain');
    }
    if (value.status !== expected || (expected === 'sealed' && !value.sealed)) { throw new Error('ControllerEvidenceUnavailable'); }
  }

  async writeEvidence(step: string): Promise<void> {
    this.check(); if (!this.cleanupSafe || this.base === '' || !this.businessFinished) { return; }
    if (this.evidenceId === '') {
      const id: string = util.generateRandomUUID(true); await fileIo.mkdir(this.base + '/' + id, false);
      this.evidenceId = id; this.check();
    }
    const details: ControllerDetails = new ControllerDetails();
    details.step = step; details.runId = this.runId; details.sessionToken = this.token;
    details.directory = this.base; details.facts = this.facts.slice();
    const bytes: Uint8Array = new util.TextEncoder().encodeInto(JSON.stringify(details, null, 2));
    if (bytes.byteLength > 65536) { throw new Error('ControllerEvidenceTooLarge'); }
    const name: string = 'details-' + util.generateRandomUUID(true) + '.part';
    const writer: AdaptiveAttemptFile = new AdaptiveAttemptFile(this.base, this.evidenceId, name, bytes.byteLength);
    this.writers.push(writer);
    const opened: AttemptFileResult = await writer.open('', 0); this.evidenceResult(opened, 'opened'); this.check();
    const appended: AttemptFileResult = await writer.append(bytes.buffer as ArrayBuffer);
    this.evidenceResult(appended, 'appended'); this.check();
    const sealed: AttemptFileResult = await writer.seal(bytes.byteLength); this.evidenceResult(sealed, 'sealed'); this.check();
    const drained: AttemptFileResult = await writer.drain(); this.evidenceResult(drained, 'sealed'); this.check();
    this.note('detailFile', this.path(this.evidenceId, name));
  }

  noteCleanup(value: boolean): void { this.note('cleanupComplete', value); }

  markerFacts(): KeyValue[] {
    const compact: KeyValue[] = [];
    for (let i = 0; i < this.facts.length; i++) {
      const item: KeyValue = this.facts[i];
      // Full pre-stop file names and hashes remain in the sealed details file.
      if (item.key === 'inputDirectory' || item.key.startsWith('beforeName') || item.key.startsWith('beforeSha256_')) { continue; }
      compact.push(new KeyValue(item.key, item.value));
    }
    return compact;
  }
}

@Component
export struct ProbeAdaptiveController {
  @State baseUrl: string = 'http://127.0.0.1:18766';
  private alive: boolean = false;
  private owner: AdaptiveControllerProbeSession | undefined = undefined;

  aboutToAppear(): void { this.alive = true; }
  aboutToDisappear(): void { this.alive = false; this.owner?.cancel(); }

  private async runStep(step: string): Promise<void> {
    if (!this.alive) { return; }
    const kit: ProbeKit = ProbeKit.getInstance(); const token: string = kit.getSessionToken();
    if (!kit.isCurrent(token)) { return; }
    this.owner?.cancel();
    const context = this.getUIContext().getHostContext();
    const session: AdaptiveControllerProbeSession = new AdaptiveControllerProbeSession(context?.filesDir ?? '', this.baseUrl, token, kit.getRunId());
    this.owner = session;
    try {
      try { await session.execute(step); } catch (error) { session.noteFailure(error as BusinessError); }
      const released: boolean = await session.releaseResources();
      if (!this.alive || this.owner !== session || !session.isCurrent()) { return; }
      session.noteCleanup(released);
      if (released) { try { await session.writeEvidence(step); } catch (error) { session.noteFailure(error as BusinessError); } }
      const finalReleased: boolean = await session.releaseResources();
      if (!this.alive || this.owner !== session || !session.isCurrent()) { return; }
      session.noteCleanup(finalReleased); kit.emit(step, session.markerFacts());
    } finally { session.cancel(); if (this.owner === session) { this.owner = undefined; } }
  }

  build() {
    Column({ space: 12 }) {
      Text($r('app.string.probe_http_source_hint')).fontSize(12).opacity(0.7).width('100%')
      TextInput({ text: this.baseUrl, placeholder: $r('app.string.probe_http_source_hint') })
        .onChange((value: string): void => { this.baseUrl = value; }).width('100%')
      ProbePage({ unitId: 'P6-U6', pageTitle: $r('app.string.probe_p6u6_title'), steps: CONTROLLER_STEPS,
        autoStart: false, runStep: (step: string): Promise<void> => this.runStep(step) }).layoutWeight(1)
    }.width('100%').height('100%').padding(16)
  }
}
