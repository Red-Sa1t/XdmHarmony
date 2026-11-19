import { fileIo, ReadOptions } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';

export const ATTEMPT_MAX_BLOCK_BYTES: number = 65536;
const MISSING_FILE_CODE: number = 13900002;

/** IO facts only. sealed does not establish HTTP completeness or a valid adaptive part. */
export class AttemptFileResult {
  status: string = 'new';
  errorCode: number = 0;
  fileName: string = '';
  confirmedBytes: number = 0;
  sealed: boolean = false;
  closed: boolean = true;
  cleanupComplete: boolean = true;
  resourceUncertain: boolean = false;
  prefixClosed: boolean = true;
  candidateClosed: boolean = true;
  prefixCloseCode: number = 0;
  candidateCloseCode: number = 0;
  cleanupErrorCode: number = 0;
}

class AttemptFault extends Error {
  status: string = 'ioError';
  code: number = 0;

  constructor(status: string, code: number = 0) {
    super('Adaptive attempt file operation failed');
    this.status = status; this.code = code;
  }
}

class OwnedHandle {
  file: fileIo.File | null = null;
  closed: boolean = true;
  closeAttempted: boolean = false;
  uncertain: boolean = false;
  closeCode: number = 0;
}

class AttemptLease {
  key: string = '';
}

type AttemptWork = () => Promise<AttemptFileResult>;
// Every writer of a candidate basename must use this same main-thread module.
const ATTEMPT_LEASES: Map<string, AttemptLease> = new Map<string, AttemptLease>();

function safeBytes(value: number): boolean { return Number.isSafeInteger(value) && value >= 0; }

function validPartName(value: string): boolean {
  // Matches B's internal basename contract; never accepts a path or a state-slot name.
  return typeof value === 'string' && new RegExp('^[A-Za-z0-9_-]{1,120}[.]part$').test(value);
}

function validDownloadId(value: string): boolean {
  return typeof value === 'string' &&
    new RegExp('^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$').test(value);
}

function errorNumber(error: Object): number {
  try {
    const code: number | undefined = (error as BusinessError)?.code;
    return code !== undefined && safeBytes(code) ? code : 0;
  } catch (e) { return 0; }
}

/** Lexical identity; the configured base and its ancestors must have no symlink aliases. */
function normalizeBase(value: string): string {
  if (typeof value !== 'string' || value.length === 0 || value.length > 4096 ||
    new RegExp('[\\x00-\\x1f\\x7f]').test(value) || value.indexOf('://') >= 0) { return ''; }
  const normalized: string = value.replace(new RegExp('\\\\', 'g'), '/');
  let root: string = '';
  if (new RegExp('^[A-Za-z]:/').test(normalized)) { root = normalized.substring(0, 3); }
  else if (normalized.startsWith('/')) { root = '/'; }
  else { return ''; }
  const input: string[] = normalized.substring(root.length).split('/');
  const components: string[] = [];
  for (let i = 0; i < input.length; i++) {
    if (input[i] === '' || input[i] === '.') { continue; }
    if (input[i] === '..') {
      if (components.length === 0) { return ''; }
      components.pop();
    } else { components.push(input[i]); }
  }
  return root + components.join('/');
}

function copyResult(source: AttemptFileResult): AttemptFileResult {
  const copied: AttemptFileResult = new AttemptFileResult();
  copied.status = source.status; copied.errorCode = source.errorCode;
  copied.fileName = source.fileName; copied.confirmedBytes = source.confirmedBytes;
  copied.sealed = source.sealed; copied.closed = source.closed;
  copied.cleanupComplete = source.cleanupComplete; copied.resourceUncertain = source.resourceUncertain;
  copied.prefixClosed = source.prefixClosed; copied.candidateClosed = source.candidateClosed;
  copied.prefixCloseCode = source.prefixCloseCode; copied.candidateCloseCode = source.candidateCloseCode;
  copied.cleanupErrorCode = source.cleanupErrorCode;
  return copied;
}

/** One candidate lifetime: copy a stopped prefix, append bounded blocks, then seal or dispose. */
export class AdaptiveAttemptFile {
  private valid: boolean = false;
  private directory: string = '';
  private name: string = '';
  private maxBytes: number = 0;
  private foldCase: boolean = false;
  private lease: AttemptLease | null = null;
  private phase: string = 'new';
  private inflight: boolean = false;
  private disposed: boolean = false;
  private sealed: boolean = false;
  private claimed: boolean = false;
  private creationAttempted: boolean = false;
  private cleanupStarted: boolean = false;
  private cleanupComplete: boolean = true;
  private cleanupErrorCode: number = 0;
  private confirmedBytes: number = 0;
  private failureStatus: string = '';
  private failureCode: number = 0;
  private prefix: OwnedHandle = new OwnedHandle();
  private candidate: OwnedHandle = new OwnedHandle();
  private barrier: Promise<AttemptFileResult> = Promise.resolve<AttemptFileResult>(new AttemptFileResult());

  constructor(tempDirectory: string, downloadId: string, candidateName: string, maxBytes: number) {
    const base: string = normalizeBase(tempDirectory);
    if (base !== '' && validDownloadId(downloadId) && validPartName(candidateName) && safeBytes(maxBytes)) {
      this.directory = base + (base.endsWith('/') ? '' : '/') + downloadId;
      this.name = candidateName; this.maxBytes = maxBytes;
      this.foldCase = new RegExp('^[A-Za-z]:/').test(this.directory);
      this.valid = true;
    }
    this.barrier = Promise.resolve<AttemptFileResult>(this.snapshot(this.valid ? 'new' : 'invalid'));
  }

  open(prefixName: string, prefixBytes: number): Promise<AttemptFileResult> {
    const unavailable: string = this.unavailable('new');
    if (unavailable !== '') { return this.immediate(unavailable); }
    if (!safeBytes(prefixBytes) || prefixBytes > this.maxBytes ||
      (prefixBytes === 0 ? prefixName !== '' : !validPartName(prefixName)) ||
      (prefixName !== '' && this.identity(prefixName) === this.identity(this.name))) {
      return this.immediate('invalid');
    }
    const key: string = this.identity(this.directory + '/' + this.name);
    if (ATTEMPT_LEASES.has(key)) {
      this.fail('collision', 0); this.phase = 'failed';
      this.barrier = Promise.resolve<AttemptFileResult>(this.snapshot('collision'));
      return this.drain();
    }
    const lease: AttemptLease = new AttemptLease();
    lease.key = key; ATTEMPT_LEASES.set(key, lease); this.lease = lease;
    return this.start('opening', (): Promise<AttemptFileResult> => this.openFile(prefixName, prefixBytes));
  }

  append(data: ArrayBuffer): Promise<AttemptFileResult> {
    const unavailable: string = this.unavailable('writable');
    if (unavailable !== '') { return this.immediate(unavailable); }
    let captured: ArrayBuffer;
    try {
      if (!(data instanceof ArrayBuffer) || data.byteLength > ATTEMPT_MAX_BLOCK_BYTES ||
        !safeBytes(data.byteLength) || data.byteLength > this.maxBytes - this.confirmedBytes) {
        return this.immediate('invalid');
      }
      captured = new ArrayBuffer(data.byteLength);
      new Uint8Array(captured).set(new Uint8Array(data));
    } catch (e) { return this.immediate('invalid'); }
    if (this.disposed) { return this.immediate('disposed'); }
    return this.start('writable', (): Promise<AttemptFileResult> => this.appendFile(captured));
  }

  seal(retainBytes: number): Promise<AttemptFileResult> {
    const unavailable: string = this.unavailable('writable');
    if (unavailable !== '') { return this.immediate(unavailable); }
    if (!safeBytes(retainBytes) || retainBytes > this.confirmedBytes) { return this.immediate('invalid'); }
    return this.start('sealing', (): Promise<AttemptFileResult> => this.sealFile(retainBytes));
  }

  dispose(): void {
    if (this.disposed) { return; }
    this.disposed = true;
    if (this.sealed || this.phase === 'failed' || this.inflight) { return; }
    this.fail('disposed', 0); this.phase = 'disposed'; this.inflight = true;
    this.barrier = this.disposeIdle();
  }

  /** Captures this lifetime's already-admitted work/cleanup; each caller gets separate facts. */
  drain(): Promise<AttemptFileResult> {
    const accepted: Promise<AttemptFileResult> = this.barrier;
    return accepted.then<AttemptFileResult>((value: AttemptFileResult): AttemptFileResult => copyResult(value));
  }

  private identity(value: string): string { return this.foldCase ? value.toLowerCase() : value; }
  private candidatePath(): string { return this.directory + '/' + this.name; }
  private checkActive(): void { if (this.disposed) { throw new AttemptFault('disposed'); } }

  private unavailable(requiredPhase: string): string {
    if (!this.valid) { return 'invalid'; }
    if (this.disposed) { return 'disposed'; }
    if (this.inflight) { return 'busy'; }
    return this.phase === requiredPhase ? '' : 'invalid';
  }

  private snapshot(status: string): AttemptFileResult {
    const value: AttemptFileResult = new AttemptFileResult();
    value.status = status; value.errorCode = this.failureCode;
    value.fileName = this.name; value.confirmedBytes = this.confirmedBytes;
    value.sealed = this.sealed; value.prefixClosed = this.prefix.closed;
    value.candidateClosed = this.candidate.closed; value.closed = this.prefix.closed && this.candidate.closed;
    value.resourceUncertain = this.prefix.uncertain || this.candidate.uncertain;
    value.cleanupComplete = this.cleanupComplete;
    value.prefixCloseCode = this.prefix.closeCode; value.candidateCloseCode = this.candidate.closeCode;
    value.cleanupErrorCode = this.cleanupErrorCode;
    return value;
  }

  private immediate(status: string): Promise<AttemptFileResult> {
    return Promise.resolve<AttemptFileResult>(this.snapshot(status));
  }

  private fail(status: string, code: number): void {
    if (this.failureStatus === '') { this.failureStatus = status; this.failureCode = code; }
  }

  private start(phase: string, work: AttemptWork): Promise<AttemptFileResult> {
    this.phase = phase; this.inflight = true;
    this.barrier = this.execute(work);
    return this.drain();
  }

  private async execute(work: AttemptWork): Promise<AttemptFileResult> {
    let completed: AttemptFileResult | null = null;
    try {
      this.checkActive();
      completed = await work();
      if (!completed.sealed) { this.checkActive(); }
    } catch (e) {
      if (e instanceof AttemptFault) { this.fail(e.status, e.code); }
      else { this.fail('ioError', errorNumber(e as BusinessError)); }
      this.phase = this.failureStatus === 'disposed' ? 'disposed' : 'failed';
    }
    try {
      if (!this.sealed && (this.phase === 'failed' || this.phase === 'disposed')) { await this.cleanup(); }
    } finally {
      if (this.sealed || this.phase === 'failed' || this.phase === 'disposed') { this.releaseLease(); }
      this.inflight = false;
    }
    return this.failureStatus !== '' ? this.snapshot(this.failureStatus) :
      (completed ?? this.snapshot('ioError'));
  }

  private async disposeIdle(): Promise<AttemptFileResult> {
    try { await this.cleanup(); }
    finally { this.releaseLease(); this.inflight = false; }
    return this.snapshot(this.failureStatus);
  }

  private releaseLease(): void {
    const lease: AttemptLease | null = this.lease;
    if (lease !== null && ATTEMPT_LEASES.get(lease.key) === lease) { ATTEMPT_LEASES.delete(lease.key); }
    this.lease = null;
  }

  private acquire(handle: OwnedHandle, file: fileIo.File): void {
    // File-return establishes close responsibility, independently of path-delete authority.
    handle.file = file; handle.closed = false;
  }

  private async closeHandle(handle: OwnedHandle): Promise<void> {
    const file: fileIo.File | null = handle.file;
    if (file === null || handle.closeAttempted) { return; }
    handle.closeAttempted = true; handle.file = null;
    try { await fileIo.close(file); handle.closed = true; }
    catch (e) {
      handle.uncertain = true; handle.closeCode = errorNumber(e as BusinessError);
      this.fail('ioError', handle.closeCode);
    }
    // Never retry a failed close: the SDK does not prove whether that fd was released/reused.
  }

  private async cleanup(): Promise<void> {
    if (this.cleanupStarted || this.sealed) { return; }
    this.cleanupStarted = true;
    await this.closeHandle(this.prefix);
    await this.closeHandle(this.candidate);
    if (!this.prefix.closed || !this.candidate.closed) { this.cleanupComplete = false; return; }
    if (!this.claimed) {
      // An entered open that failed/was cancelled before claiming may have left an unowned file.
      this.cleanupComplete = !this.creationAttempted;
      return;
    }
    try {
      await fileIo.unlink(this.candidatePath());
      this.claimed = false; this.cleanupComplete = true;
    } catch (e) { this.cleanupErrorCode = errorNumber(e as BusinessError); this.cleanupComplete = false; }
  }

  private async existingDirectory(): Promise<void> {
    let stat: fileIo.Stat;
    try { stat = await fileIo.lstat(this.directory); }
    catch (e) {
      const code: number = errorNumber(e as BusinessError);
      throw new AttemptFault(code === MISSING_FILE_CODE ? 'invalid' : 'ioError', code);
    }
    this.checkActive();
    if (!stat.isDirectory()) { throw new AttemptFault('invalid'); }
  }

  private async candidateAbsent(): Promise<void> {
    let exists: boolean = true;
    try { await fileIo.lstat(this.candidatePath()); }
    catch (e) {
      const code: number = errorNumber(e as BusinessError);
      if (code !== MISSING_FILE_CODE) { throw new AttemptFault('ioError', code); }
      exists = false;
    }
    this.checkActive();
    if (exists) { throw new AttemptFault('collision'); }
  }

  private ordinarySize(stat: fileIo.Stat): number {
    if (!stat.isFile()) { throw new AttemptFault('invalid'); }
    const bytes: number = stat.size;
    if (!safeBytes(bytes)) { throw new AttemptFault('invalid'); }
    return bytes;
  }

  private async openFile(prefixName: string, prefixBytes: number): Promise<AttemptFileResult> {
    await this.existingDirectory(); this.checkActive();
    await this.candidateAbsent(); this.checkActive();
    this.creationAttempted = true; this.cleanupComplete = false;
    const file: fileIo.File = await fileIo.open(this.candidatePath(),
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.NOFOLLOW);
    this.acquire(this.candidate, file); this.checkActive();
    const stat: fileIo.Stat = await fileIo.stat(file.fd);
    if (this.ordinarySize(stat) !== 0) { throw new AttemptFault('collision'); }
    this.claimed = true; this.checkActive();
    if (prefixBytes > 0) { await this.copyPrefix(prefixName, prefixBytes, file.fd); this.checkActive(); }
    this.phase = 'writable';
    return this.snapshot('opened');
  }

  private async copyPrefix(name: string, bytes: number, targetFd: number): Promise<void> {
    const path: string = this.directory + '/' + name;
    let metadata: fileIo.Stat;
    try { metadata = await fileIo.lstat(path); }
    catch (e) {
      const code: number = errorNumber(e as BusinessError);
      throw new AttemptFault(code === MISSING_FILE_CODE ? 'invalid' : 'ioError', code);
    }
    this.checkActive();
    if (this.ordinarySize(metadata) < bytes) { throw new AttemptFault('invalid'); }
    const file: fileIo.File = await fileIo.open(path, fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.NOFOLLOW);
    this.acquire(this.prefix, file); this.checkActive();
    const openedStat: fileIo.Stat = await fileIo.stat(file.fd);
    this.checkActive();
    if (this.ordinarySize(openedStat) < bytes) { throw new AttemptFault('invalid'); }
    const buffer: ArrayBuffer = new ArrayBuffer(Math.min(ATTEMPT_MAX_BLOCK_BYTES, bytes));
    let copied: number = 0;
    while (copied < bytes) {
      const length: number = Math.min(buffer.byteLength, bytes - copied);
      const options: ReadOptions = { length: length };
      const count: number = await fileIo.read(file.fd, buffer, options);
      this.checkActive();
      if (!safeBytes(count) || count > length) { throw new AttemptFault('ioError'); }
      if (count === 0) { throw new AttemptFault('invalid'); }
      await this.writeBytes(targetFd, buffer, count); this.checkActive();
      copied += count;
    }
    await this.closeHandle(this.prefix);
    this.checkActive();
    if (!this.prefix.closed) { throw new AttemptFault('ioError', this.prefix.closeCode); }
  }

  private async writeBytes(fd: number, buffer: ArrayBuffer, length: number): Promise<void> {
    let written: number = 0;
    while (written < length) {
      const remaining: ArrayBuffer = written === 0 && length === buffer.byteLength ? buffer : buffer.slice(written, length);
      const count: number = await fileIo.write(fd, remaining);
      if (!safeBytes(count) || count === 0 || count > remaining.byteLength) { throw new AttemptFault('ioError'); }
      this.confirmedBytes += count; written += count;
      this.checkActive();
    }
  }

  private async appendFile(data: ArrayBuffer): Promise<AttemptFileResult> {
    const file: fileIo.File | null = this.candidate.file;
    if (file === null || !this.claimed) { throw new AttemptFault('invalid'); }
    await this.writeBytes(file.fd, data, data.byteLength); this.checkActive();
    return this.snapshot('appended');
  }

  private async sealFile(retainBytes: number): Promise<AttemptFileResult> {
    const file: fileIo.File | null = this.candidate.file;
    if (file === null || !this.claimed) { throw new AttemptFault('invalid'); }
    if (retainBytes < this.confirmedBytes) {
      await fileIo.truncate(file.fd, retainBytes);
      this.confirmedBytes = retainBytes; this.checkActive();
    }
    const stat: fileIo.Stat = await fileIo.stat(file.fd);
    this.checkActive();
    if (this.ordinarySize(stat) !== retainBytes) { throw new AttemptFault('ioError'); }
    await fileIo.fsync(file.fd); this.checkActive();
    await this.closeHandle(this.candidate);
    this.checkActive();
    if (!this.candidate.closed) { throw new AttemptFault('ioError', this.candidate.closeCode); }
    // No await between the last disposal check and this fixed successful receipt.
    this.sealed = true; this.phase = 'sealed'; this.cleanupComplete = true;
    return this.snapshot('sealed');
  }
}
