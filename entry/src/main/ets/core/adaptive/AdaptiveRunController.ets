import { util } from '@kit.ArkTS';
import { DownloadRunRequest, cloneDownloadRunRequest } from '../../model/DownloadRunRequest';
import { serializeDownloadRequestContext } from '../../model/DownloadRequestContext';
import { AdaptiveDownloadState, AdaptivePlan, AdaptivePartState, copyAdaptivePlan,
  isAdaptiveHttpUrl, partitionAdaptiveChunks } from './AdaptivePlan';
import { encodeAdaptiveState, decodeAdaptiveState, newAdaptiveState } from './AdaptiveStateCodec';
import { AdaptiveScheduler, AdaptiveSchedulerLimits, AdaptiveDispatch, AdaptiveAttemptIdentity,
  AdaptiveSettlement, AdaptiveSettlementResult, AdaptiveQuiesced, createAdaptiveScheduler } from './AdaptiveScheduler';
import { AdaptiveAttemptExecutor, AdaptiveAttemptOptions, AdaptiveAttemptResult } from './AdaptiveAttemptExecutor';
import { AdaptiveDownloadThrottle, AdaptiveThrottlePolicyProvider, AdaptiveClock, adaptiveNowMs,
  validAdaptiveAttemptIdentity, sameAdaptiveAttemptIdentity, copyAdaptiveAttemptIdentity } from './AdaptiveDownloadThrottle';
import { AdaptiveStateStore, AdaptiveStoreResult } from '../db/AdaptiveStateStore';

export class AdaptiveRunInput {
  downloadId: string = '';
  runToken: string = '';
  tempBase: string = '';
  freshPlan: AdaptivePlan | null = null;
  request: DownloadRunRequest = new DownloadRunRequest();
  limits: AdaptiveSchedulerLimits = new AdaptiveSchedulerLimits();
  networkTimeoutSeconds: number = 30;
}

/** Only the real returned capability can retire its original directory owner. */
export interface AdaptiveAssemblyLease {
  isCurrent(): boolean;
  isStopRequested(): boolean;
  attachReader(onStop: () => void): boolean;
  release(): boolean;
  quarantine(errorCode: string): void;
}

export class AdaptiveReadyInput {
  downloadId: string = '';
  runToken: string = '';
  assemblyId: string = '';
  generation: number = 0;
  tempBase: string = '';
  state: AdaptiveDownloadState = new AdaptiveDownloadState();
  lease: AdaptiveAssemblyLease;

  constructor(lease: AdaptiveAssemblyLease) { this.lease = lease; }
}

/** Read-only UI sample. Counts sealed parts only; writtenBytes is the run's live network write
 * total (all lanes/retries) and is never a durability claim. */
export class AdaptiveRunProgress {
  planned: boolean = false;
  totalChunks: number = 0;
  completedChunks: number = 0;
  sealedBytes: number = 0;
  writtenBytes: number = 0;
  durationSeconds: number = 0;
}

export class AdaptiveRunResult {
  kind: string = 'rejected';
  downloadId: string = '';
  runToken: string = '';
  errorCode: string = '';
  durableState: AdaptiveDownloadState | null = null;
  ready: AdaptiveReadyInput | null = null;
  ownerDisposition: string = 'notAcquired';
}

class RunOwner {
  key: string = '';
  phase: string = 'active';
  stopRequested: boolean = false;
  errorCode: string = '';
  notificationCode: string = '';
  store: AdaptiveStateStore | null = null;
  lease: OwnedAssemblyLease | null = null;
  onStop: (() => void) | null = null;
  stopNotified: boolean = false;
}

// Same main-thread module as all E4 runs. This is not a cross-process filesystem lock.
const RUN_OWNERS: Map<string, RunOwner> = new Map<string, RunOwner>();
const MAX_TIMER_MS: number = 2147483647;

function safeCount(value: number): boolean { return Number.isSafeInteger(value) && value >= 0; }

function validId(value: string): boolean {
  return typeof value === 'string' && value.length === 36 &&
    new RegExp('^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$').test(value);
}

function validToken(value: string): boolean {
  return typeof value === 'string' && value.length > 0 && value.length <= 64 &&
    !new RegExp('[^A-Za-z0-9_-]').test(value);
}

function fixedCode(value: string, fallback: string): string {
  return typeof value === 'string' && value.length > 0 && value.length <= 64 &&
    new RegExp('^[A-Za-z][A-Za-z0-9_]*$').test(value) ? value : fallback;
}

function normalizeBase(value: string): string {
  if (typeof value !== 'string' || value.length === 0 || value.length > 4096 ||
    value.indexOf('://') >= 0 || new RegExp('[\\x00-\\x1f\\x7f]').test(value)) { return ''; }
  const normalized: string = value.replace(new RegExp('\\\\', 'g'), '/');
  let root: string = '';
  if (new RegExp('^[A-Za-z]:/').test(normalized)) { root = normalized.substring(0, 3); }
  else if (normalized.startsWith('/')) { root = '/'; }
  else { return ''; }
  const components: string[] = normalized.substring(root.length).split('/');
  const kept: string[] = [];
  for (let i = 0; i < components.length; i++) {
    const part: string = components[i];
    if (part === '' || part === '.') { continue; }
    if (part === '..') {
      if (kept.length === 0) { return ''; }
      kept.pop();
    } else { kept.push(part); }
  }
  return root + kept.join('/');
}

function storeUncertain(store: AdaptiveStateStore | null): boolean {
  if (store === null) { return false; }
  try { return store.hasUncertainResources(); }
  catch (_) { return true; }
}

function notifyReader(owner: RunOwner): void {
  const listener: (() => void) | null = owner.onStop;
  if (listener === null || owner.stopNotified) { return; }
  owner.stopNotified = true;
  try { listener(); }
  catch (_) { owner.notificationCode = 'ReaderStopCallbackFailed'; }
}

function isolateOwner(owner: RunOwner, code: string): void {
  if (RUN_OWNERS.get(owner.key) !== owner || owner.phase === 'released') { return; }
  if (owner.phase !== 'quarantined') {
    owner.phase = 'quarantined'; owner.errorCode = fixedCode(code, 'AdaptiveResourceUncertain');
  }
  owner.stopRequested = true;
  notifyReader(owner);
  owner.onStop = null;
}

class OwnedAssemblyLease implements AdaptiveAssemblyLease {
  private owner: RunOwner;
  private attached: boolean = false;
  private released: boolean = false;

  constructor(owner: RunOwner) { this.owner = owner; }

  isCurrent(): boolean {
    return !this.released && this.owner.phase === 'ready' &&
      RUN_OWNERS.get(this.owner.key) === this.owner && this.owner.lease === this;
  }

  isStopRequested(): boolean { return this.owner.stopRequested; }

  attachReader(onStop: () => void): boolean {
    if (!this.isCurrent() || this.attached || this.owner.stopRequested || typeof onStop !== 'function') { return false; }
    this.attached = true; this.owner.onStop = onStop;
    return true;
  }

  /** The trusted reader calls this only after its actual drain proves safe closure. */
  release(): boolean {
    if (!this.isCurrent()) { return false; }
    if (storeUncertain(this.owner.store)) {
      this.quarantine('AdaptiveCheckpointResourceUncertain'); return false;
    }
    this.released = true; this.owner.phase = 'released'; this.owner.onStop = null;
    RUN_OWNERS.delete(this.owner.key);
    return true;
  }

  quarantine(errorCode: string): void {
    if (!this.isCurrent()) { return; }
    isolateOwner(this.owner, errorCode);
  }
}

function copyState(value: AdaptiveDownloadState): AdaptiveDownloadState {
  const copied: AdaptiveDownloadState | null = decodeAdaptiveState(encodeAdaptiveState(value), value.downloadId);
  if (copied === null) { throw new Error('InvalidAdaptiveState'); }
  return copied;
}

function copyRunResult(value: AdaptiveRunResult): AdaptiveRunResult {
  const copied: AdaptiveRunResult = new AdaptiveRunResult();
  copied.kind = value.kind; copied.downloadId = value.downloadId; copied.runToken = value.runToken;
  copied.errorCode = value.errorCode; copied.ownerDisposition = value.ownerDisposition;
  if (value.durableState !== null) { copied.durableState = copyState(value.durableState); }
  if (value.ready !== null) {
    const ready: AdaptiveReadyInput = new AdaptiveReadyInput(value.ready.lease);
    ready.downloadId = value.ready.downloadId; ready.runToken = value.ready.runToken;
    ready.assemblyId = value.ready.assemblyId; ready.generation = value.ready.generation;
    ready.tempBase = value.ready.tempBase; ready.state = copyState(value.ready.state);
    copied.ready = ready;
  }
  return copied;
}

class CapturedRevision {
  index: number;
  revision: number;
  constructor(index: number, revision: number) { this.index = index; this.revision = revision; }
}

/** One capture/save at a time. Offers never replace a newer E1 state with an old saved snapshot. */
class RunCheckpoint {
  working: AdaptiveDownloadState | null = null;
  durable: AdaptiveDownloadState | null = null;
  generation: number = -1;
  failedCode: string = '';
  uncertain: boolean = false;
  saving: boolean = false;
  nextAllowed: number = 0;
  private store: AdaptiveStateStore;
  private clock: AdaptiveClock;
  private provide: () => AdaptiveDownloadState;
  private changed: () => void;
  private revisions: number[] = [];
  private dirty: Set<number> = new Set<number>();
  private repairPending: boolean = false;
  private work: Promise<void> | null = null;

  constructor(store: AdaptiveStateStore, clock: AdaptiveClock,
    provide: () => AdaptiveDownloadState, changed: () => void) {
    this.store = store; this.clock = clock; this.provide = provide; this.changed = changed;
  }

  seed(state: AdaptiveDownloadState, generation: number, durable: boolean, needsSave: boolean): void {
    this.working = state; this.generation = generation;
    this.durable = durable ? state : null; this.repairPending = needsSave;
    for (let i = 0; i < state.parts.length; i++) { this.revisions.push(0); }
  }

  checkResources(): boolean {
    if (storeUncertain(this.store)) { this.uncertain = true; }
    return this.uncertain;
  }

  hasChanges(): boolean { return this.repairPending || this.dirty.size > 0; }

  offer(changes: AdaptivePartState[]): void {
    for (let i = 0; i < changes.length; i++) {
      const index: number = Number(changes[i].chunkId.substring(1));
      if (!safeCount(index) || index >= this.revisions.length || this.revisions[index] === Number.MAX_SAFE_INTEGER) {
        this.failedCode = 'AdaptiveRevisionOverflow'; return;
      }
      this.revisions[index]++; this.dirty.add(index);
    }
  }

  start(force: boolean): void {
    if (this.saving || this.failedCode !== '' || !this.hasChanges() || this.checkResources()) { return; }
    this.saving = true;
    this.work = this.save(force);
  }

  async drain(): Promise<void> {
    const accepted: Promise<void> | null = this.work;
    if (accepted !== null) { await accepted; }
    this.checkResources();
  }

  private async save(force: boolean): Promise<void> {
    let captureMs: number = 0;
    try {
      const began: number = this.clock();
      const captured: AdaptiveDownloadState = this.provide();
      const versions: CapturedRevision[] = [];
      this.dirty.forEach((index: number): void => { versions.push(new CapturedRevision(index, this.revisions[index])); });
      const repair: boolean = this.repairPending;
      // This call captures synchronously; do not lose its admitted Promise if the second clock read fails.
      const operation: Promise<AdaptiveStoreResult> = this.store.save(captured, this.generation);
      try { captureMs = this.clock() - began; }
      catch (_) { this.failedCode = 'InvalidAdaptiveClock'; }
      const saved: AdaptiveStoreResult = await operation;
      if (saved.status === 'saved' && saved.state !== null) {
        this.generation = saved.state.generation; this.durable = saved.state;
        for (let i = 0; i < versions.length; i++) {
          const item: CapturedRevision = versions[i];
          if (this.revisions[item.index] === item.revision) { this.dirty.delete(item.index); }
        }
        if (repair) { this.repairPending = false; }
      } else if (saved.status !== 'busy' || force) {
        this.failedCode = saved.status === 'busy' ? 'AdaptiveCheckpointBusy' :
          (saved.status === 'conflict' ? 'AdaptiveCheckpointConflict' :
          (saved.status === 'invalid' ? 'AdaptiveCheckpointInvalid' :
          (saved.status === 'disposed' ? 'AdaptiveCheckpointDisposed' : 'AdaptiveCheckpointIoError')));
      }
      this.checkResources();
    } catch (_) {
      if (this.failedCode === '') { this.failedCode = 'AdaptiveCheckpointFailed'; }
      this.checkResources();
    } finally {
      try {
        const ended: number = this.clock();
        const gap: number = Math.max(2000, Math.min(Number.MAX_SAFE_INTEGER, captureMs * 5));
        this.nextAllowed = gap > Number.MAX_SAFE_INTEGER - ended ? Number.MAX_SAFE_INTEGER : ended + gap;
      } catch (_) { if (this.failedCode === '') { this.failedCode = 'InvalidAdaptiveClock'; } }
      this.saving = false;
      this.changed();
    }
  }
}

class RunAttempt {
  dispatch: AdaptiveDispatch;
  executor: AdaptiveAttemptExecutor | null = null;
  work: Promise<void> | null = null;
  stopRequested: boolean = false;
  handled: boolean = false;

  constructor(dispatch: AdaptiveDispatch) { this.dispatch = dispatch; }
}

type RunCompletion = (result: AdaptiveRunResult) => void;

/** A single source/checkpoint lifetime. A ready reader's lifetime belongs to the returned lease. */
export class AdaptiveRunController {
  private input: AdaptiveRunInput = new AdaptiveRunInput();
  private policy: AdaptiveThrottlePolicyProvider;
  private clock: AdaptiveClock;
  private valid: boolean = false;
  private started: boolean = false;
  private ended: boolean = false;
  private stopped: boolean = false;
  private stopIssued: boolean = false;
  private schedulerStopping: boolean = false;
  private abandoned: boolean = false;
  private finalizing: boolean = false;
  private failureCode: string = '';
  private resourceCode: string = '';
  private lastNow: number = 0;
  private owner: RunOwner | null = null;
  private checkpoint: RunCheckpoint | null = null;
  private scheduler: AdaptiveScheduler | null = null;
  private gate: AdaptiveDownloadThrottle | null = null;
  private lanes: number = 0;
  private attempts: RunAttempt[] = [];
  private quiesced: AdaptiveQuiesced | null = null;
  private retryTimer: number = -1;
  private checkpointTimer: number = -1;
  private retryDeadline: number = -1;
  private checkpointDeadline: number = -1;
  private wake: (() => void) | null = null;
  private wakePending: boolean = false;
  private completion: RunCompletion | null = null;
  private barrier: Promise<AdaptiveRunResult> = Promise.resolve<AdaptiveRunResult>(new AdaptiveRunResult());

  constructor(input: AdaptiveRunInput, policyProvider: AdaptiveThrottlePolicyProvider,
    clock: AdaptiveClock = adaptiveNowMs) {
    this.policy = policyProvider; this.clock = clock;
    try {
      this.input.downloadId = input.downloadId; this.input.runToken = input.runToken;
      this.input.tempBase = normalizeBase(input.tempBase);
      if (!validId(input.downloadId) || !validToken(input.runToken) || this.input.tempBase === '' ||
        typeof policyProvider !== 'function' || typeof clock !== 'function') { return; }
      this.input.request = cloneDownloadRunRequest(input.request);
      if (!safeCount(this.input.request.revision) || !isAdaptiveHttpUrl(this.input.request.url)) { return; }
      serializeDownloadRequestContext(this.input.request.context);
      const limits: AdaptiveSchedulerLimits = input.limits;
      if (limits === null || typeof limits !== 'object' || Array.isArray(limits)) { return; }
      const keys: string[] = Object.keys(limits);
      if (keys.length !== 3 || keys.indexOf('maxSegments') < 0 || keys.indexOf('maxRetry') < 0 ||
        keys.indexOf('retryDelayMs') < 0 || !safeCount(limits.maxSegments) || limits.maxSegments === 0 ||
        !safeCount(limits.maxRetry) || limits.maxRetry === Number.MAX_SAFE_INTEGER || !safeCount(limits.retryDelayMs)) { return; }
      this.input.limits.maxSegments = limits.maxSegments; this.input.limits.maxRetry = limits.maxRetry;
      this.input.limits.retryDelayMs = limits.retryDelayMs; this.input.networkTimeoutSeconds = input.networkTimeoutSeconds;
      if (input.freshPlan !== null) {
        this.input.freshPlan = copyAdaptivePlan(input.freshPlan);
        if (this.input.freshPlan === null) { return; }
      }
      this.valid = true;
    } catch (_) { this.valid = false; }
  }

  run(): Promise<AdaptiveRunResult> {
    if (this.started) { return this.observe(); }
    this.started = true;
    this.barrier = new Promise<AdaptiveRunResult>((resolve: RunCompletion): void => { this.completion = resolve; });
    if (!this.valid) { this.finishUnowned('rejected', 'InvalidAdaptiveRunInput'); return this.observe(); }
    if (this.stopped) { this.finishUnowned('paused', ''); return this.observe(); }
    const directory: string = this.input.tempBase + (this.input.tempBase.endsWith('/') ? '' : '/') + this.input.downloadId;
    const key: string = new RegExp('^[A-Za-z]:/').test(directory) ? directory.toLowerCase() : directory;
    const previous: RunOwner | undefined = RUN_OWNERS.get(key);
    if (previous !== undefined) {
      this.finishUnowned('rejected', previous.phase === 'quarantined' ? 'AdaptiveOwnerQuarantined' : 'AdaptiveOwnerBusy');
      return this.observe();
    }
    const owner: RunOwner = new RunOwner(); owner.key = key;
    RUN_OWNERS.set(key, owner); this.owner = owner;
    this.execute();
    return this.observe();
  }

  pause(): void {
    if (this.ended) {
      const owner: RunOwner | null = this.owner;
      if (owner !== null && owner.phase === 'ready' && RUN_OWNERS.get(owner.key) === owner) {
        owner.stopRequested = true; notifyReader(owner);
      }
      return;
    }
    this.stopped = true;
    if (this.owner !== null) { this.owner.stopRequested = true; }
    this.beginStop();
    this.signal();
  }

  drain(): Promise<AdaptiveRunResult> {
    if (!this.started) { this.pause(); return this.run(); }
    return this.observe();
  }

  /** Bounded, side-effect-free observation for progress UI; failures read as "no data". */
  progressSnapshot(): AdaptiveRunProgress {
    const progress: AdaptiveRunProgress = new AdaptiveRunProgress();
    try {
      const checkpoint: RunCheckpoint | null = this.checkpoint;
      const working: AdaptiveDownloadState | null = checkpoint === null ? null : checkpoint.working;
      if (working !== null) {
        const parts: AdaptivePartState[] = this.scheduler === null ? working.parts : this.scheduler.snapshotParts();
        progress.planned = true;
        progress.totalChunks = parts.length;
        progress.durationSeconds = working.plan.duration;
        for (let i = 0; i < parts.length; i++) {
          if (parts[i].complete) { progress.completedChunks++; }
          if (safeCount(parts[i].downloaded)) { progress.sealedBytes += parts[i].downloaded; }
        }
      }
      if (this.gate !== null) { progress.writtenBytes = this.gate.snapshot().writtenBytes; }
    } catch (_) {
      return new AdaptiveRunProgress();
    }
    return progress;
  }

  private observe(): Promise<AdaptiveRunResult> {
    return this.barrier.then<AdaptiveRunResult>((result: AdaptiveRunResult): AdaptiveRunResult => copyRunResult(result));
  }

  private now(): number {
    const value: number = this.clock();
    if (!Number.isSafeInteger(value) || value <= 0 || value < this.lastNow) { throw new Error('InvalidAdaptiveClock'); }
    this.lastNow = value; return value;
  }

  private signal(): void {
    const wake: (() => void) | null = this.wake;
    if (wake !== null) { this.wake = null; wake(); }
    else { this.wakePending = true; }
  }

  private waitChange(): Promise<void> {
    if (this.wakePending) { this.wakePending = false; return Promise.resolve<void>(undefined); }
    return new Promise<void>((resolve: () => void): void => { this.wake = resolve; });
  }

  private stopping(): boolean {
    return this.stopped || this.schedulerStopping || this.failureCode !== '' || this.resourceCode !== '';
  }

  private fail(code: string, abandoned: boolean = false): void {
    const changed: boolean = this.failureCode === '' || (abandoned && !this.abandoned);
    if (this.failureCode === '') { this.failureCode = fixedCode(code, 'AdaptiveRunFailed'); }
    this.abandoned = this.abandoned || abandoned;
    this.beginStop();
    if (changed) { this.signal(); }
  }

  private resourceFault(code: string): void {
    const changed: boolean = this.resourceCode === '';
    if (this.resourceCode === '') { this.resourceCode = fixedCode(code, 'AdaptiveResourceUncertain'); }
    this.abandoned = true;
    if (this.owner !== null) { isolateOwner(this.owner, this.resourceCode); }
    this.beginStop();
    if (changed) { this.signal(); }
  }

  private checkpointChanged(): void {
    this.checkCheckpoint(); this.signal();
  }

  private checkCheckpoint(): boolean {
    const checkpoint: RunCheckpoint | null = this.checkpoint;
    if (checkpoint === null) { return true; }
    if (checkpoint.checkResources()) { this.resourceFault('AdaptiveCheckpointResourceUncertain'); return false; }
    if (checkpoint.failedCode !== '') { this.fail(checkpoint.failedCode); return false; }
    return true;
  }

  private beginStop(): void {
    this.clearTimers();
    if (!this.stopIssued) {
      this.stopIssued = true;
      if (this.scheduler !== null) {
        try { this.scheduler.requestPause(); }
        catch (_) { this.abandoned = true; if (this.failureCode === '') { this.failureCode = 'AdaptiveSchedulerFailed'; } }
      }
    }
    for (let i = 0; i < this.attempts.length; i++) { this.stopAttempt(this.attempts[i]); }
  }

  private stopAttempt(entry: RunAttempt): void {
    entry.stopRequested = true;
    if (entry.executor !== null && !entry.handled) {
      try { entry.executor.stop(); }
      catch (_) { this.abandoned = true; if (this.failureCode === '') { this.failureCode = 'AdaptiveAttemptStopFailed'; } }
    }
  }

  private async execute(): Promise<void> {
    try {
      const owner: RunOwner | null = this.owner;
      if (owner === null) { throw new Error('MissingAdaptiveOwner'); }
      const store: AdaptiveStateStore = new AdaptiveStateStore(this.input.tempBase, this.input.downloadId);
      owner.store = store;
      this.checkpoint = new RunCheckpoint(store, (): number => this.now(),
        (): AdaptiveDownloadState => this.stateForSave(), (): void => this.checkpointChanged());
      await this.bootstrap(store);
      if (!this.stopping() && this.checkpoint.working !== null) {
        const state: AdaptiveDownloadState = this.stateForSave();
        this.scheduler = createAdaptiveScheduler(this.input.runToken, state, this.input.limits);
        if (this.scheduler === null) { this.fail('InvalidAdaptiveScheduler'); }
        else {
          this.lanes = partitionAdaptiveChunks(state.parts, this.input.limits.maxSegments).length;
          if (this.lanes > 0) {
            this.gate = new AdaptiveDownloadThrottle(this.input.downloadId, this.input.runToken, this.lanes,
              this.policy, (): number => this.now());
          }
          await this.drive();
        }
      }
    } catch (_) { this.fail('AdaptiveRunFailed', true); }
    await this.finishOwned();
    this.finishResult();
  }

  private async bootstrap(store: AdaptiveStateStore): Promise<void> {
    let loaded: AdaptiveStoreResult;
    try { loaded = await store.load(); }
    catch (_) { this.fail('AdaptiveCheckpointLoadFailed'); this.checkCheckpoint(); return; }
    const checkpoint: RunCheckpoint | null = this.checkpoint;
    if (checkpoint === null) { throw new Error('MissingAdaptiveCheckpoint'); }
    if (loaded.status === 'loaded' && loaded.state !== null) {
      checkpoint.seed(loaded.state, loaded.state.generation, loaded.repairedParts === 0, loaded.repairedParts > 0);
    }
    if (!this.checkCheckpoint()) { return; }
    if (loaded.status === 'empty') {
      if (this.stopped) { return; }
      const plan: AdaptivePlan | null = this.input.freshPlan;
      const fresh: AdaptiveDownloadState | null = plan === null ? null : newAdaptiveState(this.input.downloadId, plan);
      if (fresh === null) { this.fail('AdaptivePlanMissing'); return; }
      checkpoint.seed(fresh, -1, false, true);
    } else if (loaded.status !== 'loaded' || loaded.state === null) {
      this.fail(loaded.status === 'busy' ? 'AdaptiveCheckpointBusy' :
        (loaded.status === 'conflict' ? 'AdaptiveCheckpointConflict' :
        (loaded.status === 'invalid' ? 'AdaptiveCheckpointInvalid' :
        (loaded.status === 'disposed' ? 'AdaptiveCheckpointDisposed' : 'AdaptiveCheckpointIoError'))));
      return;
    }
    if (checkpoint.hasChanges()) { checkpoint.start(true); await checkpoint.drain(); this.checkCheckpoint(); }
  }

  private stateForSave(): AdaptiveDownloadState {
    const checkpoint: RunCheckpoint | null = this.checkpoint;
    if (checkpoint === null || checkpoint.working === null) { throw new Error('MissingAdaptiveState'); }
    const value: AdaptiveDownloadState = new AdaptiveDownloadState();
    value.downloadId = this.input.downloadId; value.generation = checkpoint.generation < 0 ? 0 : checkpoint.generation;
    value.plan = checkpoint.working.plan;
    value.parts = this.scheduler === null ? checkpoint.working.parts : this.scheduler.snapshotParts();
    return value;
  }

  private async drive(): Promise<void> {
    while (true) {
      this.checkCheckpoint();
      if (this.stopping()) { this.beginStop(); }
      else { this.pump(); }
      const scheduler: AdaptiveScheduler | null = this.scheduler;
      if (!this.abandoned && scheduler !== null && this.quiesced === null) {
        this.quiesced = scheduler.takeQuiesced();
      }
      if (this.attempts.length === 0 && (this.stopping() || this.quiesced !== null)) { return; }
      if (!this.stopping()) { this.scheduleTimers(); }
      await this.waitChange();
    }
  }

  private pump(): void {
    const scheduler: AdaptiveScheduler | null = this.scheduler;
    const gate: AdaptiveDownloadThrottle | null = this.gate;
    if (scheduler === null || this.finalizing || !this.checkCheckpoint() || this.stopping()) { return; }
    try {
      const now: number = this.now();
      if (this.stopping()) { return; }
      const dispatches: AdaptiveDispatch[] = scheduler.claim(now, this.lanes - this.attempts.length);
      const batch: RunAttempt[] = [];
      for (let i = 0; i < dispatches.length; i++) {
        const entry: RunAttempt = new RunAttempt(dispatches[i]); this.attempts.push(entry); batch.push(entry);
      }
      for (let i = 0; i < batch.length; i++) {
        const entry: RunAttempt = batch[i];
        try {
          if (gate === null) { throw new Error('MissingAdaptiveGate'); }
          const options: AdaptiveAttemptOptions = new AdaptiveAttemptOptions();
          options.dispatch = entry.dispatch; options.requestContext = this.input.request.context;
          options.tempBase = this.input.tempBase; options.knownResourceTotal = -1;
          options.networkTimeoutSeconds = this.input.networkTimeoutSeconds;
          entry.executor = new AdaptiveAttemptExecutor(options, gate, (): number => this.now());
        } catch (_) {
          // The accepted E3 constructor performs no IO and has not returned a handle.
          const report: AdaptiveSettlement = new AdaptiveSettlement();
          report.identity = copyAdaptiveAttemptIdentity(entry.dispatch.identity);
          report.outcome = 'fatal'; report.errorCode = 'AdaptiveExecutorConstructionFailed';
          this.settle(report); this.retire(entry);
        }
      }
      for (let i = 0; i < batch.length; i++) {
        const entry: RunAttempt = batch[i];
        if (entry.handled || entry.executor === null) { continue; }
        if (this.stopping() || entry.stopRequested) { this.stopAttempt(entry); }
        let operation: Promise<AdaptiveAttemptResult>;
        try { operation = entry.stopRequested ? entry.executor.drain() : entry.executor.run(); }
        catch (_) {
          this.fail('AdaptiveAttemptStartFailed', true);
          try { operation = entry.executor.drain(); }
          catch (_) { this.resourceFault('AdaptiveAttemptResourceUncertain'); this.retire(entry); continue; }
        }
        entry.work = this.observeAttempt(entry, operation);
      }
    } catch (_) { this.fail('AdaptiveSchedulerFailed', true); }
  }

  private async observeAttempt(entry: RunAttempt, work: Promise<AdaptiveAttemptResult>): Promise<void> {
    let result: AdaptiveAttemptResult | null = null;
    try { result = await work; }
    catch (_) {
      this.fail('AdaptiveAttemptFailed', true);
      try { if (entry.executor !== null) { result = await entry.executor.drain(); } }
      catch (_) { this.resourceFault('AdaptiveAttemptResourceUncertain'); }
    }
    try {
      if (result === null) { this.resourceFault('AdaptiveAttemptResourceUncertain'); }
      else { this.acceptAttempt(entry, result); }
    } catch (_) { this.resourceFault('AdaptiveAttemptResourceUncertain'); }
    finally { this.retire(entry); this.signal(); }
  }

  private acceptAttempt(entry: RunAttempt, result: AdaptiveAttemptResult): void {
    if (entry.handled) { return; }
    if (!validAdaptiveAttemptIdentity(result.identity) ||
      !sameAdaptiveAttemptIdentity(entry.dispatch.identity, result.identity)) {
      this.resourceFault('AdaptiveReceiptIdentityMismatch'); return;
    }
    if (result.stream === null || result.stream.allSessionsApiClosed !== true ||
      result.stream.resourceUncertain !== false || result.file === undefined ||
      (result.file !== null && (result.file.closed !== true || result.file.resourceUncertain !== false))) {
      this.resourceFault('AdaptiveAttemptResourceUncertain'); return;
    }
    if (result.kind === 'resourceFault') { this.resourceFault(result.errorCode); return; }
    if (result.kind === 'disposed') { this.fail('AdaptiveAttemptDisposed', true); return; }
    if (result.kind !== 'settled' || result.settlement === null) { this.fail('AdaptiveReceiptInvalid', true); return; }
    const settlement: AdaptiveSettlement = result.settlement;
    if (!validAdaptiveAttemptIdentity(settlement.identity) ||
      !sameAdaptiveAttemptIdentity(settlement.identity, entry.dispatch.identity)) {
      this.fail('AdaptiveReceiptInvalid', true); return;
    }
    const part: AdaptivePartState | null = settlement.sealedPart;
    if (part !== null && (result.file === null || result.file.sealed !== true ||
      result.file.fileName !== entry.dispatch.candidateFileName || result.file.fileName !== part.fileName ||
      result.file.confirmedBytes !== part.downloaded)) { this.fail('AdaptiveReceiptInvalid', true); return; }
    this.settle(settlement);
  }

  private settle(settlement: AdaptiveSettlement): void {
    const scheduler: AdaptiveScheduler | null = this.scheduler;
    if (scheduler === null) { this.fail('AdaptiveSchedulerFailed', true); return; }
    try {
      const accepted: AdaptiveSettlementResult = scheduler.settle(settlement, this.now());
      if (!accepted.accepted || accepted.code !== 'Settled') { this.fail('AdaptiveReceiptRejected', true); }
      const changes: AdaptivePartState[] = scheduler.takeChanges();
      if (this.checkpoint !== null) { this.checkpoint.offer(changes); this.checkCheckpoint(); }
      if (accepted.stopAttempts.length > 0) { this.schedulerStopping = true; }
      for (let i = 0; i < accepted.stopAttempts.length; i++) {
        const identity: AdaptiveAttemptIdentity = accepted.stopAttempts[i];
        for (let j = 0; j < this.attempts.length; j++) {
          if (sameAdaptiveAttemptIdentity(this.attempts[j].dispatch.identity, identity)) { this.stopAttempt(this.attempts[j]); }
        }
      }
    } catch (_) { this.fail('AdaptiveSchedulerFailed', true); }
  }

  private retire(entry: RunAttempt): void {
    if (entry.handled) { return; }
    entry.handled = true;
    const index: number = this.attempts.indexOf(entry);
    if (index >= 0) { this.attempts.splice(index, 1); }
  }

  private scheduleTimers(): void {
    const scheduler: AdaptiveScheduler | null = this.scheduler;
    const checkpoint: RunCheckpoint | null = this.checkpoint;
    if (scheduler === null || checkpoint === null) { return; }
    try {
      const now: number = this.now();
      if (this.stopping()) { return; }
      const retry: number = scheduler.nextRetryAt();
      if (retry !== this.retryDeadline) {
        if (this.retryTimer >= 0) { clearTimeout(this.retryTimer); }
        this.retryTimer = -1; this.retryDeadline = retry;
        if (retry >= 0) {
          this.retryTimer = setTimeout((): void => {
            this.retryTimer = -1; this.retryDeadline = -1; this.signal();
          }, Math.max(1, Math.min(MAX_TIMER_MS, retry - now)));
        }
      }
      if (!checkpoint.saving && checkpoint.hasChanges()) {
        if (now >= checkpoint.nextAllowed) { checkpoint.start(false); }
        else if (this.checkpointDeadline !== checkpoint.nextAllowed) {
          if (this.checkpointTimer >= 0) { clearTimeout(this.checkpointTimer); }
          this.checkpointDeadline = checkpoint.nextAllowed;
          this.checkpointTimer = setTimeout((): void => {
            this.checkpointTimer = -1; this.checkpointDeadline = -1; this.signal();
          }, Math.max(1, Math.min(MAX_TIMER_MS, checkpoint.nextAllowed - now)));
        }
      }
    } catch (_) { this.fail('InvalidAdaptiveClock', true); }
  }

  private clearTimers(): void {
    if (this.retryTimer >= 0) { clearTimeout(this.retryTimer); }
    if (this.checkpointTimer >= 0) { clearTimeout(this.checkpointTimer); }
    this.retryTimer = -1; this.checkpointTimer = -1; this.retryDeadline = -1; this.checkpointDeadline = -1;
  }

  private async finishOwned(): Promise<void> {
    this.finalizing = true; this.clearTimers(); this.beginStop();
    const pending: RunAttempt[] = this.attempts.slice();
    for (let i = 0; i < pending.length; i++) {
      const operation: Promise<void> | null = pending[i].work;
      if (operation !== null) {
        try { await operation; }
        catch (_) { this.resourceFault('AdaptiveAttemptResourceUncertain'); }
      }
    }
    if (this.gate !== null) {
      try { this.gate.dispose(); }
      catch (_) { this.fail('AdaptiveGateDisposeFailed', true); }
    }
    const checkpoint: RunCheckpoint | null = this.checkpoint;
    if (checkpoint !== null) {
      try {
        await checkpoint.drain(); this.checkCheckpoint();
        if (!checkpoint.uncertain && checkpoint.failedCode === '' && checkpoint.hasChanges()) {
          checkpoint.start(true); await checkpoint.drain(); this.checkCheckpoint();
        }
      } catch (_) { this.resourceFault('AdaptiveCheckpointResourceUncertain'); }
    }
    const owner: RunOwner | null = this.owner;
    if (owner !== null && owner.store !== null) {
      try { await owner.store.drain(); }
      catch (_) { this.resourceFault('AdaptiveCheckpointResourceUncertain'); }
      this.checkCheckpoint();
      try { owner.store.dispose(); }
      catch (_) { this.resourceFault('AdaptiveCheckpointResourceUncertain'); }
      this.checkCheckpoint();
    }
  }

  private baseResult(): AdaptiveRunResult {
    const result: AdaptiveRunResult = new AdaptiveRunResult();
    result.downloadId = this.input.downloadId; result.runToken = this.input.runToken;
    return result;
  }

  private finishUnowned(kind: string, code: string): void {
    const result: AdaptiveRunResult = this.baseResult(); result.kind = kind; result.errorCode = code;
    this.commit(result);
  }

  private finishResult(): void {
    const result: AdaptiveRunResult = this.baseResult();
    const owner: RunOwner | null = this.owner;
    const checkpoint: RunCheckpoint | null = this.checkpoint;
    if (checkpoint !== null && checkpoint.durable !== null) { result.durableState = checkpoint.durable; }
    if (this.quiesced !== null && this.quiesced.failureCode !== '' && this.failureCode === '') {
      this.failureCode = fixedCode(this.quiesced.failureCode, 'AdaptiveRunFailed');
    }
    this.checkCheckpoint();
    if (owner === null || RUN_OWNERS.get(owner.key) !== owner) {
      result.kind = 'resourceFault'; result.errorCode = 'AdaptiveOwnerLost'; result.ownerDisposition = 'notAcquired';
    } else if (this.resourceCode !== '' || owner.phase === 'quarantined') {
      result.kind = 'resourceFault'; result.errorCode = this.resourceCode || owner.errorCode;
      result.ownerDisposition = 'quarantined';
    } else {
      if (!this.stopped && this.failureCode === '' && this.quiesced !== null && this.quiesced.readyForAssembly &&
        result.durableState !== null && result.durableState.parts.every((part: AdaptivePartState): boolean => part.complete)) {
        try {
          const assemblyId: string = util.generateRandomUUID();
          if (!validId(assemblyId)) { throw new Error('InvalidAdaptiveAssemblyId'); }
          if (!this.stopped && this.checkCheckpoint()) {
            const lease: OwnedAssemblyLease = new OwnedAssemblyLease(owner);
            const ready: AdaptiveReadyInput = new AdaptiveReadyInput(lease);
            ready.downloadId = this.input.downloadId; ready.runToken = this.input.runToken;
            ready.assemblyId = assemblyId; ready.generation = result.durableState.generation;
            ready.tempBase = this.input.tempBase; ready.state = result.durableState;
            owner.lease = lease; owner.phase = 'ready';
            result.kind = 'ready'; result.ready = ready; result.ownerDisposition = 'heldForAssembly';
            this.commit(result); return;
          }
        } catch (_) { this.fail('AdaptiveReadyFailed'); }
      }
      if (this.resourceCode !== '' || owner.phase === 'quarantined' || storeUncertain(owner.store)) {
        isolateOwner(owner, 'AdaptiveCheckpointResourceUncertain');
        result.kind = 'resourceFault'; result.errorCode = this.resourceCode || owner.errorCode;
        result.ownerDisposition = 'quarantined';
      } else {
        result.kind = this.failureCode !== '' || (!this.stopped && this.quiesced === null) ? 'failed' : 'paused';
        result.errorCode = this.failureCode || (result.kind === 'failed' ? 'AdaptiveRunIncomplete' : '');
        owner.phase = 'released'; owner.onStop = null; RUN_OWNERS.delete(owner.key);
        result.ownerDisposition = 'released';
      }
    }
    this.commit(result);
  }

  private commit(result: AdaptiveRunResult): void {
    if (this.ended) { return; }
    this.ended = true; this.clearTimers();
    const complete: RunCompletion | null = this.completion; this.completion = null;
    if (complete !== null) { complete(result); }
  }
}
