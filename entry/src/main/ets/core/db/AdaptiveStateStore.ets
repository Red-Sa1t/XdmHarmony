import { fileIo, ReadOptions } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { AdaptiveDownloadState, AdaptivePartState, ADAPTIVE_MAX_STATE_CHARS } from '../adaptive/AdaptivePlan';
import { encodeAdaptiveState, decodeAdaptiveState, reconcileAdaptivePart } from '../adaptive/AdaptiveStateCodec';

const MAX_FILE_BYTES: number = ADAPTIVE_MAX_STATE_CHARS * 4;
const IO_BLOCK_BYTES: number = 65536;
const MAX_DIRECTORY_OPERATIONS: number = 2;
const MAX_PART_PROBES: number = 16;
const MISSING_FILE_CODE: number = 13900002;

export class AdaptiveStoreResult {
  status: string = 'invalid';
  state: AdaptiveDownloadState | null = null;
  repairedParts: number = 0;
}

class StoreFault extends Error {
  status: string = 'ioError';

  constructor(status: string) {
    super('Adaptive state operation failed');
    this.status = status;
  }
}

class DirectoryQueue {
  key: string = '';
  pending: number = 0;
  tail: Promise<void> = Promise.resolve<void>(undefined);
}

class SlotSnapshot {
  status: string = 'absent';
  slot: number = 1;
  state: AdaptiveDownloadState | null = null;
  text: string = '';
}

class SlotSelection {
  status: string = 'empty';
  latest: SlotSnapshot | null = null;
  target: number = 1;
  targetExists: boolean = false;
}

class SaveCapture {
  expectedGeneration: number = -1;
  state: AdaptiveDownloadState = new AdaptiveDownloadState();
  text: string = '';
  planText: string = '';
}

class PartInspection {
  next: number = 0;
  repaired: number = 0;
  status: string = 'checked';
}

type StoreWork = () => Promise<AdaptiveStoreResult>;

// All callers must use this main-thread module. This is not a cross-worker/process lock.
const DIRECTORY_QUEUES: Map<string, DirectoryQueue> = new Map<string, DirectoryQueue>();

function result(status: string, state: AdaptiveDownloadState | null = null,
  repairedParts: number = 0): AdaptiveStoreResult {
  const value: AdaptiveStoreResult = new AdaptiveStoreResult();
  value.status = status; value.state = state; value.repairedParts = repairedParts;
  return value;
}

function slotResult(slot: number, status: string): SlotSnapshot {
  const value: SlotSnapshot = new SlotSnapshot();
  value.slot = slot; value.status = status;
  return value;
}

function validId(value: string): boolean {
  return typeof value === 'string' &&
    new RegExp('^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$').test(value);
}

function safeCount(value: number): boolean { return Number.isSafeInteger(value) && value >= 0; }
function isMissing(error: Object): boolean { return (error as BusinessError)?.code === MISSING_FILE_CODE; }
function faultStatus(error: Object): string { return error instanceof StoreFault ? error.status : 'ioError'; }

/** Lexical identity only; callers supply a trusted canonical configuration base, not symlink aliases. */
function normalizeDirectory(value: string): string {
  if (typeof value !== 'string' || value.length === 0 || value.length > 4096 ||
    new RegExp('[\\x00-\\x1f\\x7f]').test(value) || value.indexOf('://') >= 0) { return ''; }
  const normalized: string = value.replace(new RegExp('\\\\', 'g'), '/');
  let prefix: string = '';
  if (new RegExp('^[A-Za-z]:/').test(normalized)) { prefix = normalized.substring(0, 3); }
  else if (normalized.startsWith('/')) { prefix = '/'; }
  else { return ''; }
  const items: string[] = normalized.substring(prefix.length).split('/');
  const components: string[] = [];
  for (let i = 0; i < items.length; i++) {
    if (items[i] === '' || items[i] === '.') { continue; }
    if (items[i] === '..') {
      if (components.length === 0) { return ''; }
      components.pop();
    } else { components.push(items[i]); }
  }
  return prefix + components.join('/');
}

function reserve(key: string): DirectoryQueue | null {
  let queue: DirectoryQueue | undefined = DIRECTORY_QUEUES.get(key);
  if (queue === undefined) {
    queue = new DirectoryQueue(); queue.key = key; DIRECTORY_QUEUES.set(key, queue);
  }
  if (queue.pending >= MAX_DIRECTORY_OPERATIONS) { return null; }
  queue.pending++;
  return queue;
}

function release(queue: DirectoryQueue): void {
  queue.pending--;
  if (queue.pending === 0 && DIRECTORY_QUEUES.get(queue.key) === queue) { DIRECTORY_QUEUES.delete(queue.key); }
}

function selectSlots(first: SlotSnapshot, second: SlotSnapshot, saving: boolean): SlotSelection {
  const selected: SlotSelection = new SlotSelection();
  if (saving && (first.status === 'ioError' || second.status === 'ioError')) {
    selected.status = 'ioError'; return selected;
  }
  if (first.state !== null && second.state !== null) {
    if (first.state.generation === second.state.generation && first.text !== second.text) {
      selected.status = 'conflict'; return selected;
    }
    selected.latest = first.state.generation >= second.state.generation ? first : second;
  } else if (first.state !== null) { selected.latest = first; }
  else if (second.state !== null) { selected.latest = second; }
  if (selected.latest !== null) {
    selected.status = 'loaded';
    selected.target = selected.latest.slot === 1 ? 2 : 1;
    selected.targetExists = (selected.target === 1 ? first.status : second.status) !== 'absent';
  } else if (first.status === 'ioError' || second.status === 'ioError') { selected.status = 'ioError'; }
  else if (first.status !== 'absent' || second.status !== 'absent') { selected.status = 'invalid'; }
  return selected;
}

/** Async adaptive checkpoints, isolated from ordinary HTTP StateStore files and protocols. */
export class AdaptiveStateStore {
  private directory: string = '';
  private queueKey: string = '';
  private ownerId: string = '';
  private valid: boolean = false;
  private disposed: boolean = false;
  private uncertainResources: boolean = false;
  private barrier: Promise<void> = Promise.resolve<void>(undefined);

  constructor(tempDirectory: string, downloadId: string) {
    const base: string = normalizeDirectory(tempDirectory);
    if (base === '' || !validId(downloadId)) { return; }
    this.ownerId = downloadId;
    this.directory = base + (base.endsWith('/') ? '' : '/') + downloadId;
    // Windows host fixtures are case-insensitive; Harmony sandbox paths retain case.
    this.queueKey = new RegExp('^[A-Za-z]:/').test(this.directory) ? this.directory.toLowerCase() : this.directory;
    this.valid = true;
  }

  load(): Promise<AdaptiveStoreResult> {
    if (!this.valid) { return Promise.resolve<AdaptiveStoreResult>(result('invalid')); }
    if (this.disposed) { return Promise.resolve<AdaptiveStoreResult>(result('disposed')); }
    if (this.uncertainResources) { return Promise.resolve<AdaptiveStoreResult>(result('ioError')); }
    const queue: DirectoryQueue | null = reserve(this.queueKey);
    if (queue === null) { return Promise.resolve<AdaptiveStoreResult>(result('busy')); }
    return this.enqueue(queue, (): Promise<AdaptiveStoreResult> => this.readState());
  }

  /** Validation/admission/capture all occur synchronously before the first queued IO. */
  save(state: AdaptiveDownloadState, expectedGeneration: number): Promise<AdaptiveStoreResult> {
    if (!this.valid) { return Promise.resolve<AdaptiveStoreResult>(result('invalid')); }
    if (this.disposed) { return Promise.resolve<AdaptiveStoreResult>(result('disposed')); }
    if (this.uncertainResources) { return Promise.resolve<AdaptiveStoreResult>(result('ioError')); }
    if (state === null || typeof state !== 'object' || state.downloadId !== this.ownerId ||
      (expectedGeneration !== -1 && !safeCount(expectedGeneration)) ||
      expectedGeneration === Number.MAX_SAFE_INTEGER) {
      return Promise.resolve<AdaptiveStoreResult>(result('invalid'));
    }
    const queue: DirectoryQueue | null = reserve(this.queueKey);
    if (queue === null) { return Promise.resolve<AdaptiveStoreResult>(result('busy')); }
    try {
      const copied: AdaptiveDownloadState | null = decodeAdaptiveState(encodeAdaptiveState(state), this.ownerId);
      if (copied === null) { throw new StoreFault('invalid'); }
      if (copied.generation !== (expectedGeneration === -1 ? 0 : expectedGeneration)) {
        release(queue); return Promise.resolve<AdaptiveStoreResult>(result('conflict'));
      }
      const capture: SaveCapture = new SaveCapture();
      capture.expectedGeneration = expectedGeneration;
      copied.generation = expectedGeneration === -1 ? 0 : expectedGeneration + 1;
      capture.state = copied;
      // The codec bounded and copied every field. Only the safe next generation was changed.
      capture.text = JSON.stringify(copied);
      if (capture.text.length > ADAPTIVE_MAX_STATE_CHARS) { throw new StoreFault('invalid'); }
      capture.planText = JSON.stringify(copied.plan);
      return this.enqueue(queue, (): Promise<AdaptiveStoreResult> => this.writeState(capture));
    } catch (e) {
      release(queue); return Promise.resolve<AdaptiveStoreResult>(result('invalid'));
    }
  }

  dispose(): void { this.disposed = true; }

  /** Sticky after any owned File close rejects; data recovery does not prove resource closure. */
  hasUncertainResources(): boolean { return this.uncertainResources; }

  /** Wait for admitted work only. Callers must also inspect hasUncertainResources(). */
  drain(): Promise<void> { return this.barrier; }

  private enqueue(queue: DirectoryQueue, work: StoreWork): Promise<AdaptiveStoreResult> {
    const operation: Promise<AdaptiveStoreResult> = queue.tail.then<AdaptiveStoreResult>(
      (): Promise<AdaptiveStoreResult> => this.execute(work));
    const barrier: Promise<void> = operation.then<void>((): void => { release(queue); });
    queue.tail = barrier; this.barrier = barrier;
    return operation;
  }

  private async execute(work: StoreWork): Promise<AdaptiveStoreResult> {
    try {
      this.checkActive();
      // Work queued before a failed close must not start another filesystem operation.
      if (this.uncertainResources) { return result('ioError'); }
      const completed: AdaptiveStoreResult = await work();
      if (completed.status !== 'saved') { this.checkActive(); }
      return completed;
    } catch (e) { return result(this.disposed ? 'disposed' : faultStatus(e as Error)); }
  }

  private checkActive(): void { if (this.disposed) { throw new StoreFault('disposed'); } }
  private slotPath(slot: number): string { return this.directory + '/adaptive-state.' + String(slot) + '.json'; }

  private async closeOwned(file: fileIo.File): Promise<void> {
    try { await fileIo.close(file); }
    catch (e) {
      this.uncertainResources = true;
      throw new StoreFault('ioError');
    }
  }

  /** Load never creates a directory. Save creates only its validated configured download path. */
  private async directoryReady(create: boolean): Promise<boolean> {
    this.checkActive();
    let stat: fileIo.Stat | null = null;
    try { stat = await fileIo.lstat(this.directory); }
    catch (e) { if (!isMissing(e as BusinessError)) { throw new StoreFault('ioError'); } }
    this.checkActive();
    if (stat === null) {
      if (!create) { return false; }
      await fileIo.mkdir(this.directory, true);
      this.checkActive();
      stat = await fileIo.lstat(this.directory);
      this.checkActive();
    }
    if (!stat.isDirectory()) { throw new StoreFault('invalid'); }
    return true;
  }

  private async readSlot(slot: number): Promise<SlotSnapshot> {
    this.checkActive();
    let stat: fileIo.Stat;
    try { stat = await fileIo.lstat(this.slotPath(slot)); }
    catch (e) {
      this.checkActive();
      return slotResult(slot, isMissing(e as BusinessError) ? 'absent' : 'ioError');
    }
    this.checkActive();
    let bytes: number = 0;
    try {
      if (!stat.isFile()) { return slotResult(slot, 'invalid'); }
      bytes = stat.size;
      if (!safeCount(bytes) || bytes === 0 || bytes > MAX_FILE_BYTES) { return slotResult(slot, 'invalid'); }
    } catch (e) { return slotResult(slot, 'ioError'); }
    let file: fileIo.File | null = null;
    let read: SlotSnapshot = slotResult(slot, 'ioError');
    try {
      file = await fileIo.open(this.slotPath(slot), fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.NOFOLLOW);
      this.checkActive();
      read = await this.readSlotFile(slot, file.fd, bytes);
    } catch (e) {
      if (e instanceof StoreFault && e.status === 'disposed') { throw e; }
      read = slotResult(slot, faultStatus(e as Error));
    } finally {
      if (file !== null) {
        const closing: fileIo.File = file;
        file = null;
        try { await this.closeOwned(closing); }
        catch (e) { read = slotResult(slot, 'ioError'); }
      }
    }
    this.checkActive();
    return read;
  }

  private decodeBlock(decoder: util.TextDecoder, bytes: Uint8Array, stream: boolean): string {
    try { return decoder.decodeToString(bytes, { stream: stream }); }
    catch (e) { throw new StoreFault('invalid'); }
  }

  private async readSlotFile(slot: number, fd: number, bytes: number): Promise<SlotSnapshot> {
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { fatal: true });
    const scratch: ArrayBuffer = new ArrayBuffer(Math.min(IO_BLOCK_BYTES, bytes));
    const block: Uint8Array = new Uint8Array(Math.min(IO_BLOCK_BYTES, bytes));
    const textParts: string[] = [];
    let consumed: number = 0;
    let characters: number = 0;
    while (consumed < bytes) {
      const length: number = Math.min(IO_BLOCK_BYTES, bytes - consumed);
      let filled: number = 0;
      while (filled < length) {
        const options: ReadOptions = { length: length - filled };
        const count: number = await fileIo.read(fd, scratch, options);
        this.checkActive();
        if (!Number.isSafeInteger(count) || count < 0 || count > length - filled) { throw new StoreFault('ioError'); }
        if (count === 0) { throw new StoreFault('invalid'); }
        block.set(new Uint8Array(scratch, 0, count), filled);
        filled += count;
      }
      const piece: string = this.decodeBlock(decoder, block.subarray(0, length), true);
      characters += piece.length;
      if (characters > ADAPTIVE_MAX_STATE_CHARS) { throw new StoreFault('invalid'); }
      textParts.push(piece); consumed += length;
    }
    const tail: number = await fileIo.read(fd, new ArrayBuffer(1));
    this.checkActive();
    if (!Number.isSafeInteger(tail) || tail < 0 || tail > 1) { throw new StoreFault('ioError'); }
    if (tail !== 0) { throw new StoreFault('invalid'); }
    const end: string = this.decodeBlock(decoder, new Uint8Array(0), false);
    if (characters + end.length > ADAPTIVE_MAX_STATE_CHARS) { throw new StoreFault('invalid'); }
    textParts.push(end);
    const state: AdaptiveDownloadState | null = decodeAdaptiveState(textParts.join(''), this.ownerId);
    if (state === null) { return slotResult(slot, 'invalid'); }
    const read: SlotSnapshot = slotResult(slot, 'valid');
    read.state = state; read.text = encodeAdaptiveState(state);
    return read;
  }

  private async select(saving: boolean): Promise<SlotSelection> {
    const first: SlotSnapshot = await this.readSlot(1);
    this.checkActive();
    const second: SlotSnapshot = await this.readSlot(2);
    this.checkActive();
    return selectSlots(first, second, saving);
  }

  private async readState(): Promise<AdaptiveStoreResult> {
    const exists: boolean = await this.directoryReady(false);
    this.checkActive();
    if (!exists) { return result('empty'); }
    const selected: SlotSelection = await this.select(false);
    this.checkActive();
    const state: AdaptiveDownloadState | null = selected.latest?.state ?? null;
    if (selected.status !== 'loaded' || state === null) { return result(selected.status); }
    const inspection: PartInspection = await this.inspectParts(state, false);
    this.checkActive();
    return inspection.status === 'checked' ? result('loaded', state, inspection.repaired) : result(inspection.status);
  }

  private failInspection(inspection: PartInspection, status: string): void {
    if (status === 'disposed' || inspection.status === 'checked' ||
      (status === 'ioError' && inspection.status !== 'disposed')) { inspection.status = status; }
  }

  private async inspectLoop(state: AdaptiveDownloadState, saving: boolean, inspection: PartInspection): Promise<void> {
    try {
      while (inspection.status === 'checked' && inspection.next < state.parts.length) {
        this.checkActive();
        const index: number = inspection.next++;
        const saved: AdaptivePartState = state.parts[index];
        if (saved.fileName === '') { continue; }
        let size: number = -1;
        try {
          const stat: fileIo.Stat = await fileIo.lstat(this.directory + '/' + saved.fileName);
          this.checkActive();
          if (stat.isFile() && safeCount(stat.size)) { size = stat.size; }
        } catch (e) {
          this.checkActive();
          if (!isMissing(e as BusinessError)) { throw new StoreFault('ioError'); }
        }
        if (saving) {
          if (size < saved.downloaded || size < 0) { this.failInspection(inspection, 'invalid'); }
        } else {
          const repaired: AdaptivePartState = reconcileAdaptivePart(state.plan.chunks[index], saved, size);
          if (repaired.downloaded !== saved.downloaded || repaired.complete !== saved.complete ||
            repaired.fileName !== saved.fileName) { inspection.repaired++; }
          state.parts[index] = repaired;
        }
      }
    } catch (e) { this.failInspection(inspection, this.disposed ? 'disposed' : faultStatus(e as Error)); }
  }

  private async inspectParts(state: AdaptiveDownloadState, saving: boolean): Promise<PartInspection> {
    const inspection: PartInspection = new PartInspection();
    const workers: Array<Promise<void>> = [];
    for (let i = 0; i < Math.min(MAX_PART_PROBES, state.parts.length); i++) {
      workers.push(this.inspectLoop(state, saving, inspection));
    }
    // Loops catch their own failures, so all in-flight probes settle even after disposal.
    await Promise.all<void>(workers);
    this.checkActive();
    return inspection;
  }

  private async writeBytes(fd: number, text: string): Promise<void> {
    const encoded: Uint8Array = new util.TextEncoder().encodeInto(text);
    if (encoded.byteLength > MAX_FILE_BYTES) { throw new StoreFault('invalid'); }
    let written: number = 0;
    while (written < encoded.byteLength) {
      const size: number = Math.min(IO_BLOCK_BYTES, encoded.byteLength - written);
      const buffer: ArrayBuffer = encoded.buffer.slice(encoded.byteOffset + written, encoded.byteOffset + written + size);
      const count: number = await fileIo.write(fd, buffer);
      this.checkActive();
      if (!Number.isSafeInteger(count) || count <= 0 || count > size) { throw new StoreFault('ioError'); }
      written += count;
    }
  }

  private async writeState(capture: SaveCapture): Promise<AdaptiveStoreResult> {
    await this.directoryReady(true);
    this.checkActive();
    const selected: SlotSelection = await this.select(true);
    this.checkActive();
    if (selected.status !== 'loaded' && selected.status !== 'empty') { return result(selected.status); }
    const previous: AdaptiveDownloadState | null = selected.latest?.state ?? null;
    if (previous === null) {
      if (capture.expectedGeneration !== -1) { return result('conflict'); }
    } else {
      if (capture.expectedGeneration !== previous.generation) { return result('conflict'); }
      if (capture.planText !== JSON.stringify(previous.plan)) { return result('invalid'); }
    }
    const inspection: PartInspection = await this.inspectParts(capture.state, true);
    this.checkActive();
    if (inspection.status !== 'checked') { return result(inspection.status); }

    let file: fileIo.File | null = null;
    let staging: string = '';
    let owned: boolean = false;
    let stagingClosed: boolean = false;
    try {
      const id: string = util.generateRandomUUID();
      if (!validId(id)) { throw new StoreFault('ioError'); }
      staging = this.directory + '/adaptive-state.' + id + '.tmp';
      let present: boolean = true;
      try { await fileIo.lstat(staging); }
      catch (e) { if (!isMissing(e as BusinessError)) { throw new StoreFault('ioError'); } present = false; }
      this.checkActive();
      if (present) { throw new StoreFault('ioError'); }
      // No TRUNC: a known collision is never opened or cleaned. Writers share the directory queue.
      file = await fileIo.open(staging, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.NOFOLLOW);
      owned = true;
      this.checkActive();
      await this.writeBytes(file.fd, capture.text);
      this.checkActive();
      await fileIo.fsync(file.fd);
      this.checkActive();
      const closing: fileIo.File = file;
      file = null;
      await this.closeOwned(closing);
      stagingClosed = true;
      this.checkActive();
      if (selected.targetExists) {
        await fileIo.unlink(this.slotPath(selected.target));
        this.checkActive();
      }
      this.checkActive();
      await fileIo.rename(staging, this.slotPath(selected.target));
      // Successful entered rename commits even if dispose happened during that await.
      owned = false;
      return result('saved', capture.state);
    } finally {
      if (file !== null) {
        const closing: fileIo.File = file;
        file = null;
        try { await this.closeOwned(closing); stagingClosed = true; } catch (e) {}
      }
      // A rejected close may leave a live descriptor. Retain its staging path for isolation.
      if (owned && stagingClosed) { try { await fileIo.unlink(staging); } catch (e) {} }
    }
  }
}
