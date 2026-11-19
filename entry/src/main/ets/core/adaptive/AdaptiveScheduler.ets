import { AdaptiveChunk, AdaptiveChunkRange, AdaptiveDownloadState, AdaptivePartState,
  copyAdaptiveChunk, partitionAdaptiveChunks } from './AdaptivePlan';
import { encodeAdaptiveState } from './AdaptiveStateCodec';

export class AdaptiveSchedulerLimits {
  maxSegments: number = 8;
  maxRetry: number = 10;
  retryDelayMs: number = 10000;
}

export class AdaptiveAttemptIdentity {
  downloadId: string = '';
  runToken: string = '';
  laneId: number = 0;
  chunkId: string = '';
  attemptId: number = 0;
}

export class AdaptiveDispatch {
  identity: AdaptiveAttemptIdentity = new AdaptiveAttemptIdentity();
  chunk: AdaptiveChunk = new AdaptiveChunk();
  prefix: AdaptivePartState = new AdaptivePartState();
  candidateFileName: string = '';
}

/** Only submit after transport/writes have settled and all owned descriptors have closed. */
export class AdaptiveSettlement {
  identity: AdaptiveAttemptIdentity = new AdaptiveAttemptIdentity();
  outcome: string = 'stopped';
  errorCode: string = '';
  sealedPart: AdaptivePartState | null = null;
  whole200Reset: boolean = false;
}

export class AdaptiveSettlementResult {
  accepted: boolean = false;
  candidateAccepted: boolean = false;
  code: string = 'StaleReceipt';
  stopAttempts: AdaptiveAttemptIdentity[] = [];
}

export class AdaptiveQuiesced {
  reason: string = '';
  failureCode: string = '';
  failureCount: number = 0;
  retryFailures: number = 0;
  completedParts: number = 0;
  totalParts: number = 0;
  downloadedBytes: number = 0;
  candidatesChanged: boolean = false;
  checkpointWanted: boolean = false;
  readyForAssembly: boolean = false;
}

class OwnedAttempt {
  identity: AdaptiveAttemptIdentity = new AdaptiveAttemptIdentity();
  chunkIndex: number = 0;
  candidateFileName: string = '';
}

class AdaptiveLane {
  start: number = 0;
  end: number = 0;
  cursor: number = 0;
  phase: string = 'ready';
  deadline: number = -1;
  owner: OwnedAttempt | null = null;
}

function safeCount(value: number): boolean { return Number.isSafeInteger(value) && value >= 0; }

function validToken(value: string): boolean {
  return typeof value === 'string' && value.length > 0 && value.length <= 64 &&
    !new RegExp('[^A-Za-z0-9_-]').test(value);
}

function validErrorCode(value: string): boolean {
  return typeof value === 'string' && value.length > 0 && value.length <= 64 &&
    new RegExp('^[A-Za-z]').test(value) && !new RegExp('[^A-Za-z0-9_]').test(value);
}

function exactFields(value: Object | null, fields: string[]): boolean {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) { return false; }
  const keys: string[] = Object.keys(value);
  if (keys.length !== fields.length) { return false; }
  for (let i = 0; i < keys.length; i++) { if (fields.indexOf(keys[i]) < 0) { return false; } }
  return true;
}

function copyPart(part: AdaptivePartState): AdaptivePartState {
  const result: AdaptivePartState = new AdaptivePartState();
  result.chunkId = part.chunkId; result.downloaded = part.downloaded;
  result.complete = part.complete; result.fileName = part.fileName; return result;
}

function copyIdentity(identity: AdaptiveAttemptIdentity): AdaptiveAttemptIdentity {
  const result: AdaptiveAttemptIdentity = new AdaptiveAttemptIdentity();
  result.downloadId = identity.downloadId; result.runToken = identity.runToken;
  result.laneId = identity.laneId; result.chunkId = identity.chunkId; result.attemptId = identity.attemptId;
  return result;
}

function validLimits(limits: AdaptiveSchedulerLimits): boolean {
  return exactFields(limits, ['maxSegments', 'maxRetry', 'retryDelayMs']) &&
    safeCount(limits.maxSegments) && limits.maxSegments > 0 &&
    safeCount(limits.maxRetry) && limits.maxRetry < Number.MAX_SAFE_INTEGER && safeCount(limits.retryDelayMs);
}

/** One instance owns one run. No IO, clock reads, timers, checkpoints or user terminal events. */
export class AdaptiveScheduler {
  private downloadId: string;
  private runToken: string;
  private chunks: AdaptiveChunk[];
  private parts: AdaptivePartState[];
  private maxAttempts: number;
  private retryDelayMs: number;
  private lanes: AdaptiveLane[] = [];
  private attempts: number[] = [];
  private names: Set<string> = new Set<string>();
  private dirty: Set<number> = new Set<number>();
  private phase: string = 'running';
  private reason: string = '';
  private lastNow: number = -1;
  private attemptSequence: number = 0;
  private activeOwners: number = 0;
  private completed: number = 0;
  private downloadedBytes: number = 0;
  private failureCode: string = '';
  private failureCount: number = 0;
  private retryFailures: number = 0;
  private changed: boolean = false;
  private taken: boolean = false;

  private constructor(runToken: string, state: AdaptiveDownloadState, limits: AdaptiveSchedulerLimits) {
    this.downloadId = state.downloadId; this.runToken = runToken;
    this.chunks = state.plan.chunks; this.parts = state.parts;
    this.maxAttempts = 1 + limits.maxRetry; this.retryDelayMs = limits.retryDelayMs;
    for (let i = 0; i < this.parts.length; i++) {
      const part: AdaptivePartState = this.parts[i];
      this.attempts.push(0); this.downloadedBytes += part.downloaded;
      if (part.complete) { this.completed++; }
      if (part.fileName !== '') { this.names.add(part.fileName); }
    }
    const ranges: AdaptiveChunkRange[] = partitionAdaptiveChunks(this.parts, limits.maxSegments);
    for (let i = 0; i < ranges.length; i++) {
      const lane: AdaptiveLane = new AdaptiveLane();
      lane.start = ranges[i].start; lane.end = ranges[i].end; lane.cursor = lane.start;
      this.advance(lane); this.lanes.push(lane);
    }
    if (this.completed === this.parts.length) { this.phase = 'quiesced'; this.reason = 'allPartsVerified'; }
  }

  static create(runToken: string, state: AdaptiveDownloadState,
    limits: AdaptiveSchedulerLimits): AdaptiveScheduler | null {
    if (!validToken(runToken) || !validLimits(limits)) { return null; }
    try {
      // One canonical B validation at admission. Parsing its own output makes the snapshot independent.
      const parsed: Object | null = JSON.parse(encodeAdaptiveState(state));
      if (parsed === null) { return null; }
      return new AdaptiveScheduler(runToken, parsed as AdaptiveDownloadState, limits);
    } catch (e) { return null; }
  }

  private checkClock(nowMs: number): void {
    if (!safeCount(nowMs) || nowMs < this.lastNow) { throw new Error('InvalidClock'); }
  }

  private advance(lane: AdaptiveLane): void {
    while (lane.cursor <= lane.end && this.parts[lane.cursor].complete) { lane.cursor++; }
    lane.phase = lane.cursor > lane.end ? 'done' : 'ready'; lane.deadline = -1;
  }

  private ownerOf(identity: AdaptiveAttemptIdentity): OwnedAttempt | null {
    if (!exactFields(identity, ['downloadId', 'runToken', 'laneId', 'chunkId', 'attemptId']) ||
      identity.downloadId !== this.downloadId || identity.runToken !== this.runToken ||
      !safeCount(identity.laneId) || identity.laneId >= this.lanes.length ||
      !safeCount(identity.attemptId) || identity.attemptId === 0) { return null; }
    const owner: OwnedAttempt | null = this.lanes[identity.laneId].owner;
    if (owner === null || owner.identity.attemptId !== identity.attemptId ||
      owner.identity.chunkId !== identity.chunkId) { return null; }
    return owner;
  }

  isCurrentAttempt(identity: AdaptiveAttemptIdentity): boolean { return this.ownerOf(identity) !== null; }

  mayReportProgress(identity: AdaptiveAttemptIdentity): boolean {
    return this.phase === 'running' && this.ownerOf(identity) !== null;
  }

  /** Invalid clock/slots/identity arithmetic throws before any owner, budget or cursor is changed. */
  claim(nowMs: number, availableSlots: number): AdaptiveDispatch[] {
    const dispatches: AdaptiveDispatch[] = [];
    if (this.phase !== 'running') { return dispatches; }
    this.checkClock(nowMs);
    if (!safeCount(availableSlots)) { throw new Error('InvalidSlots'); }
    const owners: OwnedAttempt[] = [];
    for (let i = 0; i < this.lanes.length && owners.length < availableSlots; i++) {
      const lane: AdaptiveLane = this.lanes[i];
      if (lane.phase !== 'ready' && !(lane.phase === 'waitingRetry' && lane.deadline <= nowMs)) { continue; }
      if (this.attemptSequence >= Number.MAX_SAFE_INTEGER - owners.length) { throw new Error('AttemptIdExhausted'); }
      const owner: OwnedAttempt = new OwnedAttempt();
      owner.chunkIndex = lane.cursor;
      owner.identity.downloadId = this.downloadId; owner.identity.runToken = this.runToken;
      owner.identity.laneId = i; owner.identity.chunkId = this.parts[lane.cursor].chunkId;
      owner.identity.attemptId = this.attemptSequence + owners.length + 1;
      owner.candidateFileName = this.runToken + '_' + String(owner.identity.attemptId) + '.part';
      if (this.names.has(owner.candidateFileName)) { throw new Error('CandidateNameCollision'); }
      const chunk: AdaptiveChunk | null = copyAdaptiveChunk(this.chunks[lane.cursor]);
      if (chunk === null) { throw new Error('InvalidChunk'); }
      const dispatch: AdaptiveDispatch = new AdaptiveDispatch();
      dispatch.identity = copyIdentity(owner.identity); dispatch.chunk = chunk;
      dispatch.prefix = copyPart(this.parts[lane.cursor]); dispatch.candidateFileName = owner.candidateFileName;
      owners.push(owner); dispatches.push(dispatch);
    }
    for (let i = 0; i < owners.length; i++) {
      const owner: OwnedAttempt = owners[i]; const lane: AdaptiveLane = this.lanes[owner.identity.laneId];
      lane.owner = owner; lane.phase = 'active'; lane.deadline = -1; this.attempts[owner.chunkIndex]++;
    }
    this.attemptSequence += owners.length; this.activeOwners += owners.length; this.lastNow = nowMs;
    return dispatches;
  }

  private validReceipt(report: AdaptiveSettlement, owner: OwnedAttempt): boolean {
    if (!exactFields(report, ['identity', 'outcome', 'errorCode', 'sealedPart', 'whole200Reset']) ||
      ['complete', 'retryable', 'fatal', 'stopped'].indexOf(report.outcome) < 0 ||
      typeof report.errorCode !== 'string' ||
      (report.errorCode !== '' && !validErrorCode(report.errorCode)) ||
      (report.outcome === 'complete' && report.errorCode !== '') ||
      ((report.outcome === 'fatal' || report.outcome === 'retryable') && report.errorCode === '') ||
      typeof report.whole200Reset !== 'boolean') { return false; }
    const chunk: AdaptiveChunk = this.chunks[owner.chunkIndex];
    if (report.whole200Reset && chunk.length !== -1) { return false; }
    const part: AdaptivePartState | null = report.sealedPart;
    if (part === null) { return report.outcome !== 'complete'; }
    if (!exactFields(part, ['chunkId', 'downloaded', 'complete', 'fileName']) ||
      part.chunkId !== owner.identity.chunkId || !safeCount(part.downloaded) || typeof part.complete !== 'boolean' ||
      part.fileName !== owner.candidateFileName || this.names.has(part.fileName) ||
      part.complete !== (report.outcome === 'complete') || (!part.complete && part.downloaded === 0)) { return false; }
    if (chunk.length !== -1 && (part.complete ? part.downloaded !== chunk.length : part.downloaded >= chunk.length)) {
      return false;
    }
    return report.whole200Reset || part.downloaded >= this.parts[owner.chunkIndex].downloaded;
  }

  private recordFailure(code: string): void {
    if (this.failureCount === 0) { this.failureCode = code; } this.failureCount++;
  }

  private beginStop(reason: string): AdaptiveAttemptIdentity[] {
    const stop: AdaptiveAttemptIdentity[] = [];
    if (this.phase !== 'running') { return stop; }
    this.phase = 'quiescing'; this.reason = reason;
    for (let i = 0; i < this.lanes.length; i++) {
      const lane: AdaptiveLane = this.lanes[i];
      lane.deadline = -1;
      const owner: OwnedAttempt | null = lane.owner;
      if (owner !== null) { stop.push(copyIdentity(owner.identity)); }
      else { lane.phase = 'done'; }
    }
    if (this.activeOwners === 0) { this.phase = 'quiesced'; }
    return stop;
  }

  requestPause(): AdaptiveAttemptIdentity[] { return this.beginStop('pauseRequested'); }

  /** Sole lane-release operation. A receipt atomically owns its sealed candidate and final outcome. */
  settle(report: AdaptiveSettlement, nowMs: number): AdaptiveSettlementResult {
    const result: AdaptiveSettlementResult = new AdaptiveSettlementResult();
    if (report === null || typeof report !== 'object') { return result; }
    const owner: OwnedAttempt | null = this.ownerOf(report.identity);
    if (owner === null) { return result; }
    this.checkClock(nowMs);
    const valid: boolean = this.validReceipt(report, owner);
    const part: AdaptivePartState | null = valid ? report.sealedPart : null;
    const index: number = owner.chunkIndex;
    const previous: AdaptivePartState = this.parts[index];
    let nextBytes: number = this.downloadedBytes;
    if (part !== null) {
      const otherBytes: number = this.downloadedBytes - previous.downloaded;
      if (part.downloaded > Number.MAX_SAFE_INTEGER - otherBytes) { throw new Error('ByteTotalOverflow'); }
      nextBytes = otherBytes + part.downloaded;
    }
    const outcome: string = valid ? report.outcome : 'fatal';
    const canRetry: boolean = outcome === 'retryable' && this.phase === 'running' &&
      this.attempts[index] < this.maxAttempts;
    let deadline: number = -1;
    if (canRetry) {
      if (nowMs > Number.MAX_SAFE_INTEGER - this.retryDelayMs) { throw new Error('InvalidDeadline'); }
      deadline = nowMs + this.retryDelayMs;
    }
    // All rejectable clock, deadline and aggregate arithmetic has completed before this point.
    this.lastNow = nowMs;
    if (part !== null) {
      if (previous.fileName !== '') { this.names.delete(previous.fileName); }
      const copied: AdaptivePartState = copyPart(part);
      this.parts[index] = copied; this.names.add(copied.fileName); this.downloadedBytes = nextBytes;
      if (copied.complete) { this.completed++; }
      this.dirty.add(index); this.changed = true; result.candidateAccepted = true;
    }
    const lane: AdaptiveLane = this.lanes[owner.identity.laneId];
    lane.owner = null; lane.deadline = -1; lane.phase = 'done'; this.activeOwners--;
    result.accepted = true; result.code = valid ? 'Settled' : 'InvalidReceipt';
    if (outcome === 'complete') {
      if (this.phase === 'running') { lane.cursor = index + 1; this.advance(lane); }
    } else if (outcome === 'retryable') {
      this.retryFailures++;
      if (canRetry) { lane.phase = 'waitingRetry'; lane.deadline = deadline; }
      else if (this.phase === 'running') {
        this.recordFailure('RetryBudgetExhausted'); result.stopAttempts = this.beginStop('fatal');
      }
    } else if (outcome === 'fatal') {
      this.recordFailure(valid ? report.errorCode : 'InvalidReceipt'); result.stopAttempts = this.beginStop('fatal');
    } else if (this.phase === 'running') {
      this.recordFailure('UnexpectedStop'); result.stopAttempts = this.beginStop('fatal');
    }
    if (this.phase === 'running' && this.completed === this.parts.length) {
      result.stopAttempts = this.beginStop('allPartsVerified');
    }
    if (this.phase === 'quiescing' && this.activeOwners === 0) { this.phase = 'quiesced'; }
    return result;
  }

  nextRetryAt(): number {
    if (this.phase !== 'running') { return -1; }
    let deadline: number = -1;
    for (let i = 0; i < this.lanes.length; i++) {
      const lane: AdaptiveLane = this.lanes[i];
      if (lane.phase === 'waitingRetry' && (deadline === -1 || lane.deadline < deadline)) { deadline = lane.deadline; }
    }
    return deadline;
  }

  snapshotParts(): AdaptivePartState[] {
    const result: AdaptivePartState[] = [];
    for (let i = 0; i < this.parts.length; i++) { result.push(copyPart(this.parts[i])); }
    return result;
  }

  takeChanges(): AdaptivePartState[] {
    const indices: number[] = [];
    this.dirty.forEach((index: number): void => { indices.push(index); });
    indices.sort((left: number, right: number): number => left - right);
    const result: AdaptivePartState[] = [];
    for (let i = 0; i < indices.length; i++) { result.push(copyPart(this.parts[indices[i]])); }
    this.dirty.clear(); return result;
  }

  /** Once-only pure quiescence, not durable pause or publication. The caller still owns C save/drain. */
  takeQuiesced(): AdaptiveQuiesced | null {
    if (this.phase !== 'quiesced' || this.taken) { return null; }
    const result: AdaptiveQuiesced = new AdaptiveQuiesced();
    result.reason = this.reason; result.failureCode = this.failureCode; result.failureCount = this.failureCount;
    result.retryFailures = this.retryFailures; result.completedParts = this.completed; result.totalParts = this.parts.length;
    result.downloadedBytes = this.downloadedBytes; result.candidatesChanged = this.changed;
    result.checkpointWanted = this.changed;
    result.readyForAssembly = this.reason === 'allPartsVerified' && this.failureCount === 0;
    this.taken = true; return result;
  }
}

export function createAdaptiveScheduler(runToken: string, state: AdaptiveDownloadState,
  limits: AdaptiveSchedulerLimits): AdaptiveScheduler | null {
  return AdaptiveScheduler.create(runToken, state, limits);
}
