import systemDateTime from '@ohos.systemDateTime';
import { AdaptiveAttemptIdentity } from './AdaptiveScheduler';
import { ADAPTIVE_MAX_CHUNKS, ADAPTIVE_MAX_PARALLEL } from './AdaptivePlan';
import { ThrottleState, computeThrottleSleepMs } from '../engine/SpeedLimiter';

export type AdaptiveClock = () => number;
export type AdaptiveThrottlePolicyProvider = () => AdaptiveThrottlePolicy;

export function adaptiveNowMs(): number {
  return systemDateTime.getUptime(systemDateTime.TimeType.ACTIVE, false) + 1;
}

export function copyAdaptiveAttemptIdentity(value: AdaptiveAttemptIdentity): AdaptiveAttemptIdentity {
  const copied: AdaptiveAttemptIdentity = new AdaptiveAttemptIdentity();
  copied.downloadId = value.downloadId; copied.runToken = value.runToken;
  copied.laneId = value.laneId; copied.chunkId = value.chunkId; copied.attemptId = value.attemptId;
  return copied;
}

export function sameAdaptiveAttemptIdentity(a: AdaptiveAttemptIdentity, b: AdaptiveAttemptIdentity): boolean {
  return a.downloadId === b.downloadId && a.runToken === b.runToken && a.laneId === b.laneId &&
    a.chunkId === b.chunkId && a.attemptId === b.attemptId;
}

export function validAdaptiveAttemptIdentity(value: AdaptiveAttemptIdentity): boolean {
  if (value === null || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).length !== 5) {
    return false;
  }
  return typeof value.downloadId === 'string' && value.downloadId.length === 36 &&
    new RegExp('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$').test(value.downloadId) &&
    typeof value.runToken === 'string' && value.runToken.length > 0 && value.runToken.length <= 64 &&
    !new RegExp('[^A-Za-z0-9_-]').test(value.runToken) && Number.isSafeInteger(value.laneId) && value.laneId >= 0 &&
    value.laneId < ADAPTIVE_MAX_PARALLEL && Number.isSafeInteger(value.attemptId) && value.attemptId > 0 &&
    typeof value.chunkId === 'string' && new RegExp('^c(0|[1-9][0-9]{0,4})$').test(value.chunkId) &&
    !new RegExp('[\\r\\n\\u2028\\u2029]').test(value.chunkId) && Number(value.chunkId.substring(1)) < ADAPTIVE_MAX_CHUNKS;
}

export class AdaptiveThrottlePolicy {
  globalEnabled: boolean = false;
  globalKiBps: number = 0;
  taskKiBps: number = 0;
}

export class AdaptiveGateGrant {
  kind: string = 'fault';
  errorCode: string = '';
  identity: AdaptiveAttemptIdentity = new AdaptiveAttemptIdentity();
  serial: number = 0;
}

export class AdaptiveGateResult {
  kind: string = 'fault';
  errorCode: string = '';
}

export class AdaptiveThrottleSnapshot {
  writtenBytes: number = 0;
  pendingTickets: number = 0;
  hasDebt: boolean = false;
  effectiveKiBps: number = 0;
  errorCode: string = '';
  disposed: boolean = false;
}

class GateTicket {
  identity: AdaptiveAttemptIdentity = new AdaptiveAttemptIdentity();
  serial: number = 0;
  canceled: boolean = false;
  finishing: boolean = false;
  grant: ((value: AdaptiveGateGrant) => void) | null = null;
  finish: ((value: AdaptiveGateResult) => void) | null = null;
}

function grantResult(ticket: GateTicket, kind: string, code: string = ''): AdaptiveGateGrant {
  const result: AdaptiveGateGrant = new AdaptiveGateGrant();
  result.kind = kind; result.errorCode = code; result.identity = copyAdaptiveAttemptIdentity(ticket.identity);
  result.serial = ticket.serial; return result;
}

function finishResult(kind: string, code: string = ''): AdaptiveGateResult {
  const result: AdaptiveGateResult = new AdaptiveGateResult(); result.kind = kind; result.errorCode = code; return result;
}

/** One run, all lanes/retries. Construction performs no IO, timer, clock or provider reads. */
export class AdaptiveDownloadThrottle {
  private downloadId: string;
  private runToken: string;
  private maxLanes: number;
  private provider: AdaptiveThrottlePolicyProvider;
  private clock: AdaptiveClock;
  private queue: GateTicket[] = [];
  private current: GateTicket | null = null;
  private canceled: AdaptiveAttemptIdentity[] = [];
  private serial: number = 0;
  private bytes: number = 0;
  private baseBytes: number = 0;
  private baseTick: number = 0;
  private debt: boolean = false;
  private rate: number = 0;
  private checkedAt: number = -1;
  private lastNow: number = 0;
  private timer: number = -1;
  private errorCode: string = '';
  private disposed: boolean = false;

  constructor(downloadId: string, runToken: string, maxLanes: number,
    policyProvider: AdaptiveThrottlePolicyProvider, clock: AdaptiveClock = adaptiveNowMs) {
    this.downloadId = downloadId; this.runToken = runToken; this.maxLanes = maxLanes;
    this.provider = policyProvider; this.clock = clock;
    if (!Number.isSafeInteger(maxLanes) || maxLanes < 1 || maxLanes > ADAPTIVE_MAX_PARALLEL ||
      typeof policyProvider !== 'function' || typeof clock !== 'function') { this.errorCode = 'InvalidThrottlePolicy'; }
  }

  accepts(identity: AdaptiveAttemptIdentity): boolean {
    return validAdaptiveAttemptIdentity(identity) && identity.downloadId === this.downloadId &&
      identity.runToken === this.runToken && identity.laneId < this.maxLanes;
  }

  acquire(identity: AdaptiveAttemptIdentity): Promise<AdaptiveGateGrant> {
    const ticket: GateTicket = new GateTicket();
    if (!this.accepts(identity)) { return Promise.resolve<AdaptiveGateGrant>(grantResult(ticket, 'fault', 'InvalidGateIdentity')); }
    ticket.identity = copyAdaptiveAttemptIdentity(identity);
    if (this.disposed || this.isCanceled(identity)) { return Promise.resolve<AdaptiveGateGrant>(grantResult(ticket, 'canceled')); }
    if (this.errorCode !== '') { return Promise.resolve<AdaptiveGateGrant>(grantResult(ticket, 'fault', this.errorCode)); }
    if ((this.current !== null && this.current.identity.laneId === identity.laneId) ||
      this.queue.some((item: GateTicket): boolean => item.identity.laneId === identity.laneId)) {
      return Promise.resolve<AdaptiveGateGrant>(grantResult(ticket, 'fault', 'GateAlreadyPending'));
    }
    if (this.serial === Number.MAX_SAFE_INTEGER) {
      this.fail('GateSerialOverflow'); return Promise.resolve<AdaptiveGateGrant>(grantResult(ticket, 'fault', this.errorCode));
    }
    ticket.serial = ++this.serial;
    const promise: Promise<AdaptiveGateGrant> = new Promise<AdaptiveGateGrant>((resolve): void => { ticket.grant = resolve; });
    this.queue.push(ticket); this.drive(); return promise;
  }

  finish(grant: AdaptiveGateGrant, confirmedNewBytes: number): Promise<AdaptiveGateResult> {
    const ticket: GateTicket | null = this.current;
    if (ticket === null || grant === null || grant.serial !== ticket.serial ||
      !sameAdaptiveAttemptIdentity(grant.identity, ticket.identity) || ticket.finishing) {
      return Promise.resolve<AdaptiveGateResult>(finishResult('fault', 'InvalidGateGrant'));
    }
    const promise: Promise<AdaptiveGateResult> = new Promise<AdaptiveGateResult>((resolve): void => { ticket.finish = resolve; });
    ticket.finishing = true;
    if (!Number.isSafeInteger(confirmedNewBytes) || confirmedNewBytes < 0 || confirmedNewBytes > 32768 ||
      this.bytes > Number.MAX_SAFE_INTEGER - confirmedNewBytes) { this.fail('ThrottleByteOverflow'); return promise; }
    let now: number;
    try { now = this.now(); this.readPolicy(now, false); }
    catch (e) {
      // The append already happened; a failed policy/clock read cannot erase its confirmed bytes.
      this.bytes += confirmedNewBytes; this.fail('InvalidThrottlePolicy'); return promise;
    }
    this.bytes += confirmedNewBytes;
    if (confirmedNewBytes > 0 && this.rate > 0 && this.baseBytes > 0 && this.baseTick > 0) { this.debt = true; }
    else { this.rebase(now); }
    this.drive();
    return promise;
  }

  cancelAttempt(identity: AdaptiveAttemptIdentity): void {
    if (!this.accepts(identity)) { return; }
    const index: number = this.canceled.findIndex((item: AdaptiveAttemptIdentity): boolean => item.laneId === identity.laneId);
    if (index < 0) { this.canceled.push(copyAdaptiveAttemptIdentity(identity)); }
    else { this.canceled[index] = copyAdaptiveAttemptIdentity(identity); }
    if (this.current !== null && sameAdaptiveAttemptIdentity(this.current.identity, identity)) { this.current.canceled = true; }
    for (let i = 0; i < this.queue.length; i++) {
      if (sameAdaptiveAttemptIdentity(this.queue[i].identity, identity)) { this.queue[i].canceled = true; }
    }
    this.drive();
  }

  refreshPolicy(): void {
    if (this.disposed || this.errorCode !== '') { return; }
    try { this.readPolicy(this.now(), true); this.drive(); }
    catch (e) { this.fail('InvalidThrottlePolicy'); }
  }

  dispose(): void { if (!this.disposed) { this.disposed = true; this.debt = false; this.drive(); } }

  snapshot(): AdaptiveThrottleSnapshot {
    const result: AdaptiveThrottleSnapshot = new AdaptiveThrottleSnapshot();
    result.writtenBytes = this.bytes; result.pendingTickets = this.queue.length + (this.current === null ? 0 : 1);
    result.hasDebt = this.debt; result.effectiveKiBps = this.rate; result.errorCode = this.errorCode;
    result.disposed = this.disposed; return result;
  }

  private now(): number {
    const value: number = this.clock();
    if (!Number.isSafeInteger(value) || value < 1 || value < this.lastNow) { throw new Error('InvalidThrottleClock'); }
    this.lastNow = value; return value;
  }

  private isCanceled(identity: AdaptiveAttemptIdentity): boolean {
    return this.canceled.some((item: AdaptiveAttemptIdentity): boolean => sameAdaptiveAttemptIdentity(item, identity));
  }

  private readPolicy(now: number, force: boolean): void {
    if (!force && this.checkedAt >= 0 && now - this.checkedAt < 3000) { return; }
    const policy: AdaptiveThrottlePolicy = this.provider();
    if (policy === null || typeof policy !== 'object' || typeof policy.globalEnabled !== 'boolean' ||
      !Number.isSafeInteger(policy.globalKiBps) || policy.globalKiBps < 0 ||
      !Number.isSafeInteger(policy.taskKiBps) || policy.taskKiBps < 0) { throw new Error('InvalidThrottlePolicy'); }
    let next: number = policy.globalEnabled ? policy.globalKiBps : 0;
    if (policy.taskKiBps > 0) { next = next > 0 ? Math.min(next, policy.taskKiBps) : policy.taskKiBps; }
    if (next === 0 || this.rate === 0) { this.rebase(now); }
    this.rate = next; this.checkedAt = now;
  }

  private rebase(now: number): void { this.baseBytes = this.bytes; this.baseTick = now; this.debt = false; }

  private remaining(now: number): number {
    if (!this.debt || this.rate === 0) { return 0; }
    if (now - this.baseTick < 1) { return 1; }
    const state: ThrottleState = new ThrottleState(); state.lastBytes = this.baseBytes; state.lastTick = this.baseTick;
    return computeThrottleSleepMs(state, this.rate, this.bytes, now);
  }

  private clearTimer(): void { if (this.timer !== -1) { clearTimeout(this.timer); this.timer = -1; } }

  private finishCurrent(kind: string, code: string = ''): void {
    const ticket: GateTicket | null = this.current;
    if (ticket === null || !ticket.finishing) { return; }
    const resolve: ((value: AdaptiveGateResult) => void) | null = ticket.finish;
    ticket.finish = null; this.current = null; if (resolve !== null) { resolve(finishResult(kind, code)); }
  }

  private fail(code: string): void { if (this.errorCode === '') { this.errorCode = code; } this.drive(); }

  private drive(): void {
    this.clearTimer();
    if (this.disposed || this.errorCode !== '') {
      while (this.queue.length > 0) {
        const ticket: GateTicket = this.queue[0]; this.queue.splice(0, 1);
        if (ticket.grant !== null) { ticket.grant(grantResult(ticket, this.disposed ? 'canceled' : 'fault', this.errorCode)); }
        ticket.grant = null;
      }
      this.finishCurrent(this.disposed ? 'canceled' : 'fault', this.errorCode); return;
    }
    try {
      const now: number = this.now(); this.readPolicy(now, false);
      for (let i = this.queue.length - 1; i >= 0; i--) {
        const queued: GateTicket = this.queue[i];
        if (queued.canceled) {
          this.queue.splice(i, 1); if (queued.grant !== null) { queued.grant(grantResult(queued, 'canceled')); } queued.grant = null;
        }
      }
      if (this.current !== null && !this.current.finishing) { return; }
      if (this.current !== null && this.current.canceled) { this.finishCurrent('canceled'); }
      const wait: number = this.remaining(now);
      if (wait > 0) {
        if (this.current !== null || this.queue.length > 0) {
          const refreshIn: number = Math.max(1, 3000 - (now - this.checkedAt));
          this.timer = setTimeout((): void => { this.timer = -1; this.drive(); }, Math.min(wait, refreshIn));
        }
        return;
      }
      if (this.debt) { this.rebase(now); }
      if (this.current !== null) { this.finishCurrent('paid'); }
      if (this.queue.length > 0) {
        const next: GateTicket = this.queue[0]; this.queue.splice(0, 1); this.current = next;
        const resolve: ((value: AdaptiveGateGrant) => void) | null = next.grant;
        next.grant = null; if (resolve !== null) { resolve(grantResult(next, 'granted')); }
      }
    } catch (e) { this.errorCode = 'InvalidThrottlePolicy'; this.drive(); }
  }
}
