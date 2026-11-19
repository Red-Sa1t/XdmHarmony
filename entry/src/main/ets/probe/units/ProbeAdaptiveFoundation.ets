// P6-U4 observes C/D/E2 SDK boundaries and E1 local contracts. S5 uses synthetic
// HTTP facts; neither these checks nor sealed files are a playback verdict.
import { fileIo } from '@kit.CoreFileKit';
import { util, url } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { ProbeKit, KeyValue } from '../core/ProbeKit';
import { ProbePage, ProbeStepDef } from '../core/ProbePage';
import { AdaptiveStateStore, AdaptiveStoreResult } from '../../core/db/AdaptiveStateStore';
import { AdaptivePlan, AdaptiveDownloadState, AdaptivePartState, buildHlsPlan } from '../../core/adaptive/AdaptivePlan';
import { newAdaptiveState, encodeAdaptiveState, decodeAdaptiveState } from '../../core/adaptive/AdaptiveStateCodec';
import { HlsPlaylist } from '../../core/adaptive/HlsModel';
import { parseHlsMediaPlaylist } from '../../core/adaptive/HlsParser';
import { resolveHlsUrl } from '../../core/adaptive/HlsUrlResolver';
import { ManifestClient, ManifestFetchResult } from '../../core/adaptive/ManifestClient';
import { AdaptiveAttemptFile, AttemptFileResult } from '../../core/adaptive/AdaptiveAttemptFile';
import { AdaptiveBodyFacts, AdaptiveRequestWindow, AdaptiveResponseHead, AdaptiveTransferCheck,
  createAdaptiveWindow, inspectAdaptiveTransfer } from '../../core/adaptive/AdaptiveProtocol';
import { AdaptiveDispatch, AdaptiveQuiesced, AdaptiveScheduler, AdaptiveSchedulerLimits, AdaptiveSettlement,
  AdaptiveSettlementResult, createAdaptiveScheduler } from '../../core/adaptive/AdaptiveScheduler';
import { DownloadRequestContext, DownloadRequestHeaders } from '../../model/DownloadRequestContext';

const FOUNDATION_STEPS: ProbeStepDef[] = [
  { stepNo: 'S1', title: '双槽提交、重开与版本冲突', autoRun: true },
  { stepNo: 'S2', title: '短文件只读修复与旧槽恢复', autoRun: true },
  { stepNo: 'S3', title: '清单、重定向和相对片段', autoRun: true },
  { stepNo: 'S4', title: '请求边界、取消和复用', autoRun: true },
  { stepNo: 'S5', title: '本地协议、封存与调度提交', autoRun: true },
  { stepNo: 'S6', title: '不可变前缀、碰撞和清理', autoRun: true }
];
const STATE_PLAYLIST: string = '#EXTM3U\n#EXTINF:1,\nsegment.ts\n#EXT-X-ENDLIST\n';
const ATTEMPT_PLAYLIST: string = '#EXTM3U\n#EXTINF:1,\n#EXT-X-BYTERANGE:16@1000\nsegment.ts\n#EXT-X-ENDLIST\n';
const STATE_URL: string = 'https://probe.invalid/state/list.m3u8';
const DEFAULT_SOURCE: string = 'http://127.0.0.1:8794';
const FIXTURE_TEXT: string = 'abcdefghijklmnop';

class ProbeTimerOwner {
  id: number = -1;
  active: boolean = true;
  fired: boolean = false;
}

class PreparedAdaptiveState {
  store: AdaptiveStateStore;
  zero: AdaptiveDownloadState;
  one: AdaptiveDownloadState;

  constructor(store: AdaptiveStateStore, zero: AdaptiveDownloadState, one: AdaptiveDownloadState) {
    this.store = store; this.zero = zero; this.one = one;
  }
}

class FreshAdaptiveFixture {
  store: AdaptiveStateStore;
  state: AdaptiveDownloadState;

  constructor(store: AdaptiveStateStore, state: AdaptiveDownloadState) {
    this.store = store; this.state = state;
  }
}

interface FoundationDetail {
  unit: string;
  step: string;
  runId: string;
  sessionToken: string;
  directory: string;
  downloadId: string;
  facts: KeyValue[];
}

function fixtureContext(): DownloadRequestContext {
  const context: DownloadRequestContext = new DownloadRequestContext();
  const headers: DownloadRequestHeaders = {
    names: ['Referer', 'X-Probe'], values: [['https://probe.invalid/page'], ['one', 'two']]
  };
  context.headers = headers;
  context.cookies = 'probe=adaptive';
  return context;
}

function errorCode(error: BusinessError): number {
  return error !== null && typeof error === 'object' && Number.isSafeInteger(error.code) ? error.code : -1;
}

/** A run token spans multiple steps. This separate owner closes after one step. */
class AdaptiveFoundationSession {
  facts: KeyValue[] = [];
  private readonly token: string;
  private readonly displayId: string;
  private readonly filesDir: string;
  private readonly sourceInput: string;
  private readonly downloadId: string = util.generateRandomUUID(true);
  private readonly kit: ProbeKit = ProbeKit.getInstance();
  private active: boolean = true;
  private directory: string = '';
  private ownsDirectory: boolean = false;
  private stores: AdaptiveStateStore[] = [];
  private clients: ManifestClient[] = [];
  private timers: ProbeTimerOwner[] = [];
  private writers: AdaptiveAttemptFile[] = [];
  private partNames: string[] = ['fixture.part', 'adaptive-state.1.json', 'adaptive-state.2.json'];

  constructor(filesDir: string, source: string, token: string, displayId: string) {
    this.filesDir = filesDir; this.sourceInput = source; this.token = token; this.displayId = displayId;
  }

  isCurrent(): boolean { return this.active && this.kit.isCurrent(this.token); }

  private check(): void {
    if (!this.isCurrent()) { throw new Error('Probe owner ended'); }
  }

  noteFailure(error: BusinessError): void {
    this.facts.push(new KeyValue('exception', 'true'), new KeyValue('errorCode', String(errorCode(error))));
  }

  cancel(): void {
    this.active = false;
    this.stopResources();
  }

  private stopTimer(timer: ProbeTimerOwner): void {
    timer.active = false;
    const id: number = timer.id;
    timer.id = -1;
    if (id >= 0) { clearTimeout(id); }
  }

  private stopResources(): void {
    for (let i = 0; i < this.timers.length; i++) { this.stopTimer(this.timers[i]); }
    for (let i = 0; i < this.clients.length; i++) { this.clients[i].cancel(); }
    for (let i = 0; i < this.stores.length; i++) { this.stores[i].dispose(); }
    for (let i = 0; i < this.writers.length; i++) { this.writers[i].dispose(); }
  }

  async releaseResources(): Promise<void> {
    this.stopResources();
    // Cleanup is owner-local and must also finish after page/session invalidation.
    let incomplete: boolean = false;
    for (let i = 0; i < this.stores.length; i++) {
      await this.stores[i].drain();
      if (this.stores[i].hasUncertainResources()) { incomplete = true; }
    }
    for (let i = 0; i < this.writers.length; i++) {
      const ended: AttemptFileResult = await this.writers[i].drain();
      if (!ended.closed || !ended.cleanupComplete || ended.resourceUncertain) { incomplete = true; }
    }
    if (incomplete) { throw new Error('Probe resource cleanup incomplete'); }
  }

  private store(): AdaptiveStateStore {
    this.check();
    const value: AdaptiveStateStore = new AdaptiveStateStore(this.directory, this.downloadId);
    this.stores.push(value);
    return value;
  }

  private client(): ManifestClient {
    this.check();
    const value: ManifestClient = new ManifestClient();
    this.clients.push(value);
    return value;
  }

  private noteStore(label: string, observed: AdaptiveStoreResult): void {
    this.facts.push(new KeyValue(label + 'Status', observed.status),
      new KeyValue(label + 'Generation', String(observed.state?.generation ?? -1)));
  }

  private noteFetch(label: string, observed: ManifestFetchResult): void {
    this.facts.push(new KeyValue(label + 'Status', observed.status),
      new KeyValue(label + 'Code', String(observed.errorCode)));
  }

  private requireState(observed: AdaptiveStoreResult, status: string): AdaptiveDownloadState {
    if (observed.status !== status || observed.state === null) { throw new Error('Probe state unavailable'); }
    return observed.state;
  }

  private async prepareDirectory(): Promise<void> {
    this.check();
    if (this.ownsDirectory) { return; }
    if (this.filesDir.length === 0) { throw new Error('Probe files context unavailable'); }
    const candidate: string = this.filesDir + '/probe-adaptive-' + util.generateRandomUUID(true);
    await fileIo.mkdir(candidate, false);
    // EEXIST never reaches this ownership assignment. No user path is reused.
    this.directory = candidate;
    this.ownsDirectory = true;
    this.check();
  }

  private partPath(name: string): string {
    if (!this.ownsDirectory || this.partNames.indexOf(name) < 0) { throw new Error('Invalid probe-owned path'); }
    return this.directory + '/' + this.downloadId + '/' + name;
  }

  private writer(name: string): AdaptiveAttemptFile {
    this.check();
    if (!this.ownsDirectory || !new RegExp('^[A-Za-z0-9_-]{1,120}[.]part$').test(name)) {
      throw new Error('Invalid probe candidate name');
    }
    if (this.partNames.indexOf(name) < 0) { this.partNames.push(name); }
    const value: AdaptiveAttemptFile = new AdaptiveAttemptFile(this.directory, this.downloadId, name, 16);
    // Registered before open/append can enter their first IO await.
    this.writers.push(value);
    return value;
  }

  private requireAttempt(value: AttemptFileResult, status: string): void {
    if (value.status !== status || value.resourceUncertain ||
      (status === 'sealed' && (!value.sealed || !value.closed))) { throw new Error('Probe candidate unavailable'); }
  }

  private fixtureBytes(value: string): ArrayBuffer {
    return util.TextEncoder.create('utf-8').encodeInto(value).buffer as ArrayBuffer;
  }

  private copyState(value: AdaptiveDownloadState): AdaptiveDownloadState {
    const copied: AdaptiveDownloadState | null = decodeAdaptiveState(encodeAdaptiveState(value), this.downloadId);
    if (copied === null) { throw new Error('Probe state copy invalid'); }
    return copied;
  }

  private async missingPart(name: string): Promise<boolean> {
    this.check();
    const path: string = this.partPath(name);
    const parent: fileIo.Stat = await fileIo.lstat(this.directory + '/' + this.downloadId);
    this.check();
    if (!parent.isDirectory()) { throw new Error('Invalid probe directory'); }
    try { await fileIo.lstat(path); this.check(); return false; }
    catch (error) {
      this.check();
      if (errorCode(error as BusinessError) !== 13900002) { throw new Error('Probe absence unverified'); }
      return true;
    }
  }

  private async regularPart(name: string): Promise<string> {
    this.check();
    const path: string = this.partPath(name);
    const parent: fileIo.Stat = await fileIo.lstat(this.directory + '/' + this.downloadId);
    this.check();
    if (!parent.isDirectory()) { throw new Error('Invalid probe directory'); }
    const stat: fileIo.Stat = await fileIo.lstat(path);
    this.check();
    if (!stat.isFile()) { throw new Error('Invalid probe file'); }
    return path;
  }

  private async writeFile(path: string, text: string, replace: boolean): Promise<void> {
    this.check();
    if (!this.ownsDirectory || !path.startsWith(this.directory + '/')) { throw new Error('Unowned probe file'); }
    if (!replace) {
      try {
        await fileIo.lstat(path);
        this.check();
        throw new Error('Probe file collision');
      } catch (error) {
        if (errorCode(error as BusinessError) !== 13900002) { throw new Error('Probe file not available'); }
        this.check();
      }
    }
    const flags: number = fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.NOFOLLOW |
      (replace ? fileIo.OpenMode.TRUNC : 0);
    const file: fileIo.File = await fileIo.open(path, flags);
    try {
      this.check();
      const encoder: util.TextEncoder = util.TextEncoder.create('utf-8');
      const buffer: ArrayBuffer = encoder.encodeInto(text).buffer as ArrayBuffer;
      let written: number = 0;
      while (written < buffer.byteLength) {
        const count: number = await fileIo.write(file.fd, buffer.slice(written));
        this.check();
        if (!Number.isSafeInteger(count) || count <= 0 || count > buffer.byteLength - written) {
          throw new Error('Probe short write');
        }
        written += count;
      }
      await fileIo.fsync(file.fd);
      this.check();
    } finally {
      await fileIo.close(file);
    }
    this.check();
  }

  private async readPart(name: string): Promise<string> {
    const path: string = await this.regularPart(name);
    this.check();
    const file: fileIo.File = await fileIo.open(path, fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.NOFOLLOW);
    try {
      this.check();
      const stat: fileIo.Stat = await fileIo.stat(file.fd);
      this.check();
      if (!Number.isSafeInteger(stat.size) || stat.size < 0 || stat.size > 65536) { throw new Error('Probe file too large'); }
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      let received: number = 0;
      while (received < buffer.byteLength) {
        const part: ArrayBuffer = new ArrayBuffer(buffer.byteLength - received);
        const count: number = await fileIo.read(file.fd, part);
        this.check();
        if (!Number.isSafeInteger(count) || count <= 0 || count > part.byteLength) { throw new Error('Probe short read'); }
        new Uint8Array(buffer).set(new Uint8Array(part, 0, count), received);
        received += count;
      }
      const options: util.TextDecoderOptions = { fatal: true };
      return util.TextDecoder.create('utf-8', options).decodeToString(new Uint8Array(buffer));
    } finally {
      await fileIo.close(file);
    }
  }

  private async prepareState(): Promise<PreparedAdaptiveState> {
    await this.prepareDirectory();
    this.check();
    const playlist: HlsPlaylist | null = parseHlsMediaPlaylist(STATE_PLAYLIST, STATE_URL, resolveHlsUrl);
    if (playlist === null) { throw new Error('Probe playlist invalid'); }
    const plan: AdaptivePlan | null = buildHlsPlan(STATE_URL, playlist);
    if (plan === null) { throw new Error('Probe plan invalid'); }
    const initial: AdaptiveDownloadState | null = newAdaptiveState(this.downloadId, plan);
    if (initial === null) { throw new Error('Probe initial state invalid'); }
    const store: AdaptiveStateStore = this.store();
    const empty: AdaptiveStoreResult = await store.load();
    this.check(); this.noteStore('empty', empty);
    if (empty.status !== 'empty') { throw new Error('Probe directory not empty'); }
    const savedZero: AdaptiveStoreResult = await store.save(initial, -1);
    this.check(); this.noteStore('initial', savedZero);
    const zero: AdaptiveDownloadState = this.requireState(savedZero, 'saved');
    if (zero.generation !== 0) { throw new Error('Probe initial generation unexpected'); }
    await this.writeFile(this.partPath('fixture.part'), FIXTURE_TEXT, false);
    this.check();
    const changed: AdaptiveDownloadState | null = decodeAdaptiveState(encodeAdaptiveState(zero), this.downloadId);
    if (changed === null) { throw new Error('Probe state copy invalid'); }
    changed.parts[0].fileName = 'fixture.part';
    changed.parts[0].downloaded = FIXTURE_TEXT.length;
    changed.parts[0].complete = true;
    const savedOne: AdaptiveStoreResult = await store.save(changed, 0);
    this.check(); this.noteStore('next', savedOne);
    const one: AdaptiveDownloadState = this.requireState(savedOne, 'saved');
    if (one.generation !== 1) { throw new Error('Probe next generation unexpected'); }
    await store.drain();
    this.check();
    return new PreparedAdaptiveState(store, zero, one);
  }

  private async commitAndReopen(): Promise<void> {
    const prepared: PreparedAdaptiveState = await this.prepareState();
    this.check();
    const reopened: AdaptiveStoreResult = await this.store().load();
    this.check(); this.noteStore('reopen', reopened);
    const loaded: AdaptiveDownloadState = this.requireState(reopened, 'loaded');
    this.facts.push(new KeyValue('partBytes', String(loaded.parts[0].downloaded)),
      new KeyValue('partComplete', String(loaded.parts[0].complete)));
    const stale: AdaptiveStoreResult = await prepared.store.save(prepared.zero, 0);
    this.check(); this.noteStore('stale', stale);
  }

  private async repairAndFallback(): Promise<void> {
    this.facts.push(new KeyValue('recoveryCase', 'shortPart'));
    const prepared: PreparedAdaptiveState = await this.prepareState();
    this.check();
    const first: string = await this.readPart('adaptive-state.1.json');
    this.check();
    const second: string = await this.readPart('adaptive-state.2.json');
    this.check();
    const firstState: AdaptiveDownloadState | null = decodeAdaptiveState(first, this.downloadId);
    const secondState: AdaptiveDownloadState | null = decodeAdaptiveState(second, this.downloadId);
    if (firstState === null || secondState === null ||
      Math.min(firstState.generation, secondState.generation) !== 0 ||
      Math.max(firstState.generation, secondState.generation) !== 1) { throw new Error('Probe slots unexpected'); }
    const newest: string = firstState.generation > secondState.generation ? 'adaptive-state.1.json' : 'adaptive-state.2.json';
    const part: string = await this.regularPart('fixture.part');
    this.check();
    await prepared.store.drain();
    this.check();
    await this.writeFile(part, 'abcd', true);
    this.check();
    const repair: AdaptiveStoreResult = await this.store().load();
    this.check(); this.noteStore('repair', repair);
    const repaired: AdaptiveDownloadState = this.requireState(repair, 'loaded');
    this.facts.push(new KeyValue('repairedParts', String(repair.repairedParts)),
      new KeyValue('repairedBytes', String(repaired.parts[0].downloaded)),
      new KeyValue('repairedComplete', String(repaired.parts[0].complete)));
    const firstAfter: string = await this.readPart('adaptive-state.1.json');
    this.check();
    const secondAfter: string = await this.readPart('adaptive-state.2.json');
    this.check();
    const partAfter: string = await this.readPart('fixture.part');
    this.check();
    this.facts.push(new KeyValue('slotContentsUnchanged', String(first === firstAfter && second === secondAfter)),
      new KeyValue('partStillShort', String(partAfter === 'abcd')));
    await prepared.store.drain();
    this.check();
    const corruptPath: string = await this.regularPart(newest);
    this.check();
    await this.writeFile(corruptPath, '{', true);
    this.check();
    const fallback: AdaptiveStoreResult = await this.store().load();
    this.check(); this.noteStore('fallback', fallback);
  }

  private sourceBase(): string {
    const parsed: url.URL = url.URL.parseURL(this.sourceInput.trim());
    if ((parsed.protocol !== 'http:' && parsed.protocol !== 'https:') || parsed.hostname.length === 0 ||
      parsed.username.length > 0 || parsed.password.length > 0 || parsed.search.length > 0 ||
      parsed.hash.length > 0 || (parsed.pathname !== '/' && parsed.pathname !== '')) {
      throw new Error('Invalid probe source base');
    }
    return parsed.origin;
  }

  private async manifests(): Promise<void> {
    const base: string = this.sourceBase();
    const client: ManifestClient = this.client();
    const direct: ManifestFetchResult = await client.fetchGet(base + '/direct/list.m3u8', fixtureContext(), 5000);
    this.check(); this.noteFetch('direct', direct);
    const redirected: ManifestFetchResult = await client.fetchGet(base + '/redirect/start', fixtureContext(), 5000);
    this.check(); this.noteFetch('redirect', redirected);
    const parsed: HlsPlaylist | null = redirected.status === 'ok' ?
      parseHlsMediaPlaylist(redirected.text, redirected.finalUrl, resolveHlsUrl) : null;
    const body: string = redirected.text;
    this.facts.push(new KeyValue('finalDirectoryMatches', String(redirected.finalUrl === base + '/final/list.m3u8?sig=a%2Fb')),
      new KeyValue('segmentMatches', String(parsed !== null && parsed.segments.length === 1 &&
        parsed.segments[0].url === base + '/final/segment.ts?sig=a%2Fb')),
      new KeyValue('unicodePresent', String(body.indexOf('#PROBE-UNICODE:中文') >= 0)),
      new KeyValue('cookieEcho', String(body.indexOf('#PROBE-COOKIE:1') >= 0)),
      new KeyValue('refererEcho', String(body.indexOf('#PROBE-REFERER:1') >= 0)),
      new KeyValue('multiEcho', String(body.indexOf('#PROBE-MULTI:1') >= 0)),
      new KeyValue('identityEcho', String(body.indexOf('#PROBE-IDENTITY:1') >= 0)),
      new KeyValue('rangeAbsentEcho', String(body.indexOf('#PROBE-RANGE:1') >= 0)));
  }

  private async requestFailures(): Promise<void> {
    const base: string = this.sourceBase();
    const client: ManifestClient = this.client();
    const invalid: ManifestFetchResult = await client.fetchGet(base + '/invalid-utf8', fixtureContext(), 5000);
    this.check(); this.noteFetch('utf8', invalid);
    const large: ManifestFetchResult = await client.fetchGet(base + '/too-large', fixtureContext(), 10000);
    this.check(); this.noteFetch('size', large);
    const missing: ManifestFetchResult = await client.fetchGet(base + '/not-found', fixtureContext(), 5000);
    this.check(); this.noteFetch('missing', missing);
    this.facts.push(new KeyValue('missingHttp', String(missing.httpStatus)));
    const begin: number = Date.now();
    const timeout: ManifestFetchResult = await client.fetchGet(base + '/slow', fixtureContext(), 150);
    this.check(); this.noteFetch('timeout', timeout);
    this.facts.push(new KeyValue('timeoutElapsedMs', String(Date.now() - begin)));
    const pending: Promise<ManifestFetchResult> = client.fetchGet(base + '/slow', fixtureContext(), 3000);
    const timer: ProbeTimerOwner = new ProbeTimerOwner();
    this.timers.push(timer);
    timer.id = setTimeout((): void => {
      if (!timer.active || !this.isCurrent()) { return; }
      timer.active = false; timer.id = -1; timer.fired = true;
      client.cancel();
    }, 100);
    try {
      const cancelled: ManifestFetchResult = await pending;
      this.check(); this.noteFetch('cancel', cancelled);
    } finally {
      // Invalidate even a callback already queued by the event loop before reuse.
      this.stopTimer(timer);
    }
    this.facts.push(new KeyValue('cancelTimerFired', String(timer.fired)));
    const reused: ManifestFetchResult = await client.fetchGet(base + '/direct/list.m3u8', fixtureContext(), 5000);
    this.check(); this.noteFetch('reuse', reused);
  }

  private async prepareAttemptState(): Promise<FreshAdaptiveFixture> {
    await this.prepareDirectory(); this.check();
    const playlist: HlsPlaylist | null = parseHlsMediaPlaylist(ATTEMPT_PLAYLIST, STATE_URL, resolveHlsUrl);
    if (playlist === null) { throw new Error('Probe playlist invalid'); }
    const plan: AdaptivePlan | null = buildHlsPlan(STATE_URL, playlist);
    if (plan === null) { throw new Error('Probe plan invalid'); }
    const initial: AdaptiveDownloadState | null = newAdaptiveState(this.downloadId, plan);
    if (initial === null) { throw new Error('Probe initial state invalid'); }
    const store: AdaptiveStateStore = this.store();
    const saved: AdaptiveStoreResult = await store.save(initial, -1);
    this.check(); this.noteStore('initial', saved);
    const state: AdaptiveDownloadState = this.requireState(saved, 'saved');
    if (state.generation !== 0) { throw new Error('Probe initial generation unexpected'); }
    return new FreshAdaptiveFixture(store, state);
  }

  private async protocolAndCommit(): Promise<void> {
    this.facts.push(new KeyValue('syntheticHttpFacts', 'true'));
    const fixture: FreshAdaptiveFixture = await this.prepareAttemptState(); this.check();
    const limits: AdaptiveSchedulerLimits = new AdaptiveSchedulerLimits();
    limits.maxSegments = 1;
    const scheduler: AdaptiveScheduler | null = createAdaptiveScheduler(util.generateRandomUUID(true), fixture.state, limits);
    if (scheduler === null) { throw new Error('Probe scheduler invalid'); }
    const claims: AdaptiveDispatch[] = scheduler.claim(1, 1);
    if (claims.length !== 1) { throw new Error('Probe dispatch unavailable'); }
    const dispatch: AdaptiveDispatch = claims[0];
    const window: AdaptiveRequestWindow | null = createAdaptiveWindow(dispatch.chunk, dispatch.prefix.downloaded);
    if (window === null) { throw new Error('Probe window invalid'); }
    this.facts.push(new KeyValue('remoteStart', String(window.remoteStart)), new KeyValue('remoteEnd', String(window.remoteEnd)));
    const writer: AdaptiveAttemptFile = this.writer(dispatch.candidateFileName);
    const opened: AttemptFileResult = await writer.open('', 0); this.check(); this.requireAttempt(opened, 'opened');
    const input: ArrayBuffer = this.fixtureBytes(FIXTURE_TEXT);
    const pending: Promise<AttemptFileResult> = writer.append(input);
    new Uint8Array(input).fill(90);
    const busy: AttemptFileResult = await writer.append(new ArrayBuffer(1)); this.check();
    this.facts.push(new KeyValue('concurrentAppend', busy.status));
    const written: AttemptFileResult = await pending; this.check(); this.requireAttempt(written, 'appended');
    const head: AdaptiveResponseHead = new AdaptiveResponseHead();
    head.status = 206; head.contentRange = ['bytes 1000-1015/4096']; head.contentLength = ['16'];
    const body: AdaptiveBodyFacts = new AdaptiveBodyFacts();
    body.receivedBytes = 16; body.writtenBytes = written.confirmedBytes; body.streamEnded = true;
    const checked: AdaptiveTransferCheck = inspectAdaptiveTransfer(window, head, body);
    this.facts.push(new KeyValue('protocolKind', checked.kind));
    if (checked.kind !== 'completeBytes' || !checked.allowNewPrefix || checked.prefixLimit !== 16) {
      throw new Error('Probe byte contract rejected');
    }
    const sealed: AttemptFileResult = await writer.seal(checked.prefixLimit); this.check(); this.requireAttempt(sealed, 'sealed');
    this.facts.push(new KeyValue('sealed', String(sealed.sealed)), new KeyValue('closed', String(sealed.closed)));
    const text: string = await this.readPart(dispatch.candidateFileName); this.check();
    this.facts.push(new KeyValue('bufferSnapshotMatches', String(text === FIXTURE_TEXT)));
    const part: AdaptivePartState = new AdaptivePartState();
    part.chunkId = dispatch.chunk.id; part.downloaded = sealed.confirmedBytes;
    part.complete = true; part.fileName = sealed.fileName;
    const report: AdaptiveSettlement = new AdaptiveSettlement();
    report.identity = dispatch.identity; report.outcome = 'complete'; report.sealedPart = part;
    const settled: AdaptiveSettlementResult = scheduler.settle(report, 2);
    this.facts.push(new KeyValue('settledAccepted', String(settled.accepted && settled.candidateAccepted)));
    const quiesced: AdaptiveQuiesced | null = scheduler.takeQuiesced();
    this.facts.push(new KeyValue('quiescedReason', quiesced?.reason ?? 'none'),
      new KeyValue('readyForAssembly', String(quiesced?.readyForAssembly ?? false)),
      new KeyValue('quiescedOnce', String(scheduler.takeQuiesced() === null)));
    if (!settled.accepted || !settled.candidateAccepted || quiesced === null || !quiesced.readyForAssembly) {
      throw new Error('Probe candidate not adopted');
    }
    const changed: AdaptiveDownloadState = this.copyState(fixture.state);
    changed.parts = scheduler.snapshotParts();
    const committed: AdaptiveStoreResult = await fixture.store.save(changed, 0); this.check(); this.noteStore('commit', committed);
    this.requireState(committed, 'saved');
    const reopened: AdaptiveStoreResult = await this.store().load(); this.check(); this.noteStore('reopen', reopened);
    const restored: AdaptiveDownloadState = this.requireState(reopened, 'loaded');
    this.facts.push(new KeyValue('partBytes', String(restored.parts[0].downloaded)),
      new KeyValue('partComplete', String(restored.parts[0].complete)),
      new KeyValue('partNameMatches', String(restored.parts[0].fileName === dispatch.candidateFileName)));
  }

  private async immutablePrefixAndCleanup(): Promise<void> {
    const fixture: FreshAdaptiveFixture = await this.prepareAttemptState(); this.check();
    const prefixName: string = 'prefix-' + util.generateRandomUUID(true) + '.part';
    const prefix: AdaptiveAttemptFile = this.writer(prefixName);
    const opened: AttemptFileResult = await prefix.open('', 0); this.check(); this.requireAttempt(opened, 'opened');
    const written: AttemptFileResult = await prefix.append(this.fixtureBytes(FIXTURE_TEXT)); this.check(); this.requireAttempt(written, 'appended');
    const sealed: AttemptFileResult = await prefix.seal(16); this.check(); this.requireAttempt(sealed, 'sealed');
    const partial: AdaptiveDownloadState = this.copyState(fixture.state);
    partial.parts[0].fileName = prefixName; partial.parts[0].downloaded = 8;
    const savedPrefix: AdaptiveStoreResult = await fixture.store.save(partial, 0); this.check(); this.noteStore('prefixSave', savedPrefix);
    const oldState: AdaptiveDownloadState = this.requireState(savedPrefix, 'saved');
    const candidateName: string = 'resume-' + util.generateRandomUUID(true) + '.part';
    const candidate: AdaptiveAttemptFile = this.writer(candidateName);
    const copied: AttemptFileResult = await candidate.open(prefixName, 8); this.check(); this.requireAttempt(copied, 'opened');
    this.facts.push(new KeyValue('copiedPrefixBytes', String(copied.confirmedBytes)));
    const appended: AttemptFileResult = await candidate.append(this.fixtureBytes('IJKLMNOP')); this.check(); this.requireAttempt(appended, 'appended');
    const completed: AttemptFileResult = await candidate.seal(16); this.check(); this.requireAttempt(completed, 'sealed');
    const changed: AdaptiveDownloadState = this.copyState(oldState);
    changed.parts[0].fileName = candidateName; changed.parts[0].downloaded = completed.confirmedBytes;
    changed.parts[0].complete = true;
    const committed: AdaptiveStoreResult = await fixture.store.save(changed, oldState.generation);
    this.check(); this.noteStore('commit', committed); this.requireState(committed, 'saved');
    const reopened: AdaptiveStoreResult = await this.store().load(); this.check(); this.noteStore('reopen', reopened);
    const restored: AdaptiveDownloadState = this.requireState(reopened, 'loaded');
    this.facts.push(new KeyValue('partBytes', String(restored.parts[0].downloaded)),
      new KeyValue('partComplete', String(restored.parts[0].complete)));
    const slotOne: string = await this.readPart('adaptive-state.1.json'); this.check();
    const slotTwo: string = await this.readPart('adaptive-state.2.json'); this.check();
    const first: AdaptiveDownloadState | null = decodeAdaptiveState(slotOne, this.downloadId);
    const second: AdaptiveDownloadState | null = decodeAdaptiveState(slotTwo, this.downloadId);
    const previous: AdaptiveDownloadState | null = first?.generation === 1 ? first : second;
    this.facts.push(new KeyValue('olderSlotReferencesPrefix', String(previous !== null && previous.generation === 1 &&
      previous.parts[0].fileName === prefixName && previous.parts[0].downloaded === 8 && !previous.parts[0].complete)));
    const collision: AdaptiveAttemptFile = this.writer(prefixName);
    const refused: AttemptFileResult = await collision.open('', 0); this.check();
    this.facts.push(new KeyValue('collisionStatus', refused.status));
    const discardName: string = 'discard-' + util.generateRandomUUID(true) + '.part';
    const discard: AdaptiveAttemptFile = this.writer(discardName);
    const disposable: AttemptFileResult = await discard.open('', 0); this.check(); this.requireAttempt(disposable, 'opened');
    const pending: Promise<AttemptFileResult> = discard.append(this.fixtureBytes(FIXTURE_TEXT));
    discard.dispose();
    const stopped: AttemptFileResult = await pending; this.check();
    const drained: AttemptFileResult = await discard.drain(); this.check();
    this.facts.push(new KeyValue('disposedStatus', stopped.status), new KeyValue('disposedClosed', String(drained.closed)),
      new KeyValue('disposedCleanupComplete', String(drained.cleanupComplete)));
    const missing: boolean = await this.missingPart(discardName); this.check();
    const originalText: string = await this.readPart(prefixName); this.check();
    const resumedText: string = await this.readPart(candidateName); this.check();
    const firstAfter: string = await this.readPart('adaptive-state.1.json'); this.check();
    const secondAfter: string = await this.readPart('adaptive-state.2.json'); this.check();
    this.facts.push(new KeyValue('disposedFileMissing', String(missing)),
      new KeyValue('oldPrefixUnchanged', String(originalText === FIXTURE_TEXT)),
      new KeyValue('resumedBytesMatch', String(resumedText === 'abcdefghIJKLMNOP')),
      new KeyValue('slotsUnchanged', String(slotOne === firstAfter && slotTwo === secondAfter)));
  }

  async execute(step: string): Promise<void> {
    this.check();
    if (step === 'S1') { await this.commitAndReopen(); }
    else if (step === 'S2') { await this.repairAndFallback(); }
    else if (step === 'S3') { await this.manifests(); }
    else if (step === 'S4') { await this.requestFailures(); }
    else if (step === 'S5') { await this.protocolAndCommit(); }
    else if (step === 'S6') { await this.immutablePrefixAndCleanup(); }
    else { throw new Error('Unknown foundation probe step'); }
    this.check();
  }

  async writeEvidence(step: string): Promise<void> {
    this.check();
    await this.prepareDirectory();
    this.check();
    const detail: FoundationDetail = {
      unit: 'P6-U4', step: step, runId: this.displayId, sessionToken: this.token,
      directory: this.directory, downloadId: this.downloadId, facts: this.facts
    };
    const path: string = this.directory + '/details.json';
    await this.writeFile(path, JSON.stringify(detail, null, 2), false);
    this.check();
    this.facts.push(new KeyValue('detailFile', path));
  }
}

@Component
export struct ProbeAdaptiveFoundation {
  @State baseUrl: string = DEFAULT_SOURCE;
  private alive: boolean = false;
  private owner: AdaptiveFoundationSession | undefined = undefined;

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
    const filesDir: string = this.getUIContext().getHostContext()?.filesDir ?? '';
    const session: AdaptiveFoundationSession = new AdaptiveFoundationSession(filesDir, this.baseUrl, token, kit.getRunId());
    this.owner = session;
    try {
      try { await session.execute(step); } catch (error) { session.noteFailure(error as BusinessError); }
      try { await session.releaseResources(); } catch (error) { session.noteFailure(error as BusinessError); }
      if (!this.alive || this.owner !== session || !session.isCurrent()) { return; }
      try { await session.writeEvidence(step); } catch (error) { session.noteFailure(error as BusinessError); }
      if (this.alive && this.owner === session && session.isCurrent()) { kit.emit(step, session.facts); }
    } finally {
      session.cancel();
      if (this.owner === session) { this.owner = undefined; }
    }
  }

  build() {
    Column({ space: 12 }) {
      Text($r('app.string.probe_http_source_hint')).fontSize(12).opacity(0.7).width('100%')
      TextInput({ text: this.baseUrl, placeholder: $r('app.string.probe_http_source_hint') })
        .onChange((value: string) => { this.baseUrl = value; })
        .width('100%')
      ProbePage({
        unitId: 'P6-U4', pageTitle: $r('app.string.probe_p6u4_title'), steps: FOUNDATION_STEPS,
        autoStart: false, runStep: (step: string): Promise<void> => this.runStep(step)
      }).layoutWeight(1)
    }.width('100%').height('100%').padding(16)
  }
}
