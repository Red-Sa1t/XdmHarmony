import { rcp } from '@kit.RemoteCommunicationKit';
import { url } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { currentRcpProxy } from './RcpProxy';
import { DownloadRequestContext, cloneDownloadRequestContext, composeDownloadHeaders } from '../../model/DownloadRequestContext';
import { AdaptiveAttemptIdentity } from './AdaptiveScheduler';
import { AdaptiveRequestWindow, AdaptiveResponseHead } from './AdaptiveProtocol';
import { isAdaptiveHttpUrl } from './AdaptivePlan';
import { HLS_MAX_URL_CHARS } from './HlsModel';
import { resolveHlsUrl } from './HlsUrlResolver';
import { AdaptiveClock, adaptiveNowMs, copyAdaptiveAttemptIdentity, validAdaptiveAttemptIdentity } from './AdaptiveDownloadThrottle';

export const ADAPTIVE_RCP_QUEUE_BYTES: number = 65536;
/** Physical queue size. The cacheSize pause engages late: the SDK kept writing up to ~280 KiB past a
 * 64 KiB threshold (2026-10-18 device P6-U6 S2), and a write that overflows the queue aborts the
 * transfer ("Abort request. Reason=Out of memory", 1007900023) with in-flight bytes lost — surfacing
 * as read()/readInto() 1007900990. Capacity therefore stays well above the pause threshold. */
export const ADAPTIVE_RCP_QUEUE_CAPACITY: number = 1048576;
export const ADAPTIVE_RCP_PULL_BYTES: number = 32768;
export const ADAPTIVE_RCP_TRANSFER_MS: number = 2147483647;
export const ADAPTIVE_RCP_PENDING_LIMIT: number = 256;

class FetchPermit { released: boolean = false; }
let pendingFetches: number = 0;
let pendingHighWater: number = 0;

export class AdaptiveRcpAdmissionFacts {
  limit: number = ADAPTIVE_RCP_PENDING_LIMIT;
  pending: number = 0;
  highWater: number = 0;
}

/** Same module/main-thread domain only; no reset hook can erase pending SDK work. */
export function adaptiveRcpAdmissionSnapshot(): AdaptiveRcpAdmissionFacts {
  const result: AdaptiveRcpAdmissionFacts = new AdaptiveRcpAdmissionFacts();
  result.pending = pendingFetches; result.highWater = pendingHighWater; return result;
}

function acquireFetchPermit(): FetchPermit | null {
  if (pendingFetches >= ADAPTIVE_RCP_PENDING_LIMIT) { return null; }
  const permit: FetchPermit = new FetchPermit(); pendingFetches++;
  pendingHighWater = Math.max(pendingHighWater, pendingFetches); return permit;
}

function releaseFetchPermit(permit: FetchPermit | null): void {
  if (permit !== null && !permit.released) { permit.released = true; pendingFetches--; }
}

export class AdaptiveStreamRequest {
  identity: AdaptiveAttemptIdentity = new AdaptiveAttemptIdentity();
  url: string = '';
  window: AdaptiveRequestWindow = new AdaptiveRequestWindow();
  requestContext: DownloadRequestContext = new DownloadRequestContext();
  networkDeadlineMs: number = 30000;
}

export class AdaptiveStreamFacts {
  headSource: string = 'none';
  headTrusted: boolean = false;
  sdkEndObserved: boolean = false;
  sdkPromiseSettled: boolean = false;
  fetchSucceeded: boolean = false;
  eof: boolean = false;
  sessionCount: number = 0;
  apiClosedCount: number = 0;
  allSessionsApiClosed: boolean = true;
  resourceUncertain: boolean = false;
  detachedFetchCount: number = 0;
  transportCode: number = 0;
  cancelCode: number = 0;
  closeCode: number = 0;
  failureCode: string = '';
  failureKind: string = '';
  receivedBytes: number = 0;
  receivedExact: boolean = false;
  pulledBytes: number = 0;
  maxQueuedBytes: number = 0;
}

export class AdaptiveStreamHeadResult {
  kind: string = 'failed';
  errorCode: string = '';
  head: AdaptiveResponseHead = new AdaptiveResponseHead();
  hop: number = 0;
}

export class AdaptiveReadiness { kind: string = 'failed'; errorCode: string = ''; }
export class AdaptivePullResult {
  kind: string = 'failed';
  errorCode: string = '';
  data: ArrayBuffer = new ArrayBuffer(0);
}

class ParsedHead {
  head: AdaptiveResponseHead = new AdaptiveResponseHead();
  location: string = '';
}

class HopFence {
  owner: AdaptiveRcpStream | null = null;
  serial: number = 0;
  requestId: string = '';
  permit: FetchPermit | null = null;
}

class RcpHop {
  fence: HopFence = new HopFence();
  session: rcp.Session | null = null;
  request: rcp.Request | null = null;
  queue: rcp.INetworkOutputQueue | null = null;
  fetchInvoked: boolean = false;
  settled: boolean = false;
  finalMatched: boolean = false;
  pendingStatus: number = -1;
  pendingHeaders: rcp.ResponseHeaders | null = null;
  events: number = 0;
  informationalStatuses: number = 0;
  quarantine: boolean = false;
  accepted: ParsedHead | null = null;
  headerDeadline: number = 0;
}

function numericError(error: BusinessError): number {
  return error !== null && typeof error === 'object' && Number.isSafeInteger(error.code) && error.code > 0 ? error.code : 0;
}

function copyWindow(value: AdaptiveRequestWindow): AdaptiveRequestWindow {
  const result: AdaptiveRequestWindow = new AdaptiveRequestWindow();
  result.chunkId = value.chunkId; result.chunkOffset = value.chunkOffset; result.chunkLength = value.chunkLength;
  result.prefixBytes = value.prefixBytes; result.remoteStart = value.remoteStart; result.remoteEnd = value.remoteEnd;
  result.knownResourceTotal = value.knownResourceTotal; return result;
}

export function copyAdaptiveResponseHead(value: AdaptiveResponseHead): AdaptiveResponseHead {
  const result: AdaptiveResponseHead = new AdaptiveResponseHead(); result.status = value.status;
  result.transportErrorCode = value.transportErrorCode; result.contentRange = value.contentRange.slice();
  result.contentLength = value.contentLength.slice(); result.contentEncoding = value.contentEncoding.slice();
  result.transferEncoding = value.transferEncoding.slice(); return result;
}

function normalizeUrl(value: string): string {
  if (!isAdaptiveHttpUrl(value)) { throw new Error('InvalidAdaptiveUrl'); }
  const parsed: url.URL = url.URL.parseURL(value); parsed.hash = '';
  if (!isAdaptiveHttpUrl(parsed.href)) { throw new Error('InvalidAdaptiveUrl'); }
  return parsed.href;
}

function trimOws(value: string): string { return value.replace(new RegExp('^[ \\t]+|[ \\t]+$', 'g'), ''); }

function parseHeaders(status: number, value: Object): ParsedHead {
  if (!Number.isSafeInteger(status) || status < 100 || status > 599 || value === null ||
    typeof value !== 'object' || Array.isArray(value)) { throw new Error('RcpInvalidHead'); }
  const parsed: ParsedHead = new ParsedHead(); parsed.head.status = status;
  const record: Record<string, Object | undefined> = value as Record<string, Object | undefined>;
  const keys: string[] = Object.keys(record); if (keys.length > 128) { throw new Error('RcpHeaderLimit'); }
  let chars: number = 0; let locationSeen: boolean = false;
  for (let i = 0; i < keys.length; i++) {
    const name: string = keys[i].toLowerCase(); const raw: Object | undefined = record[keys[i]];
    let group: string[] | null = null;
    if (name === 'content-range') { group = parsed.head.contentRange; }
    if (name === 'content-length') { group = parsed.head.contentLength; }
    if (name === 'content-encoding') { group = parsed.head.contentEncoding; }
    if (name === 'transfer-encoding') { group = parsed.head.transferEncoding; }
    if (group === null && name !== 'location') { continue; }
    if (raw === undefined && name !== 'location') { continue; }
    let values: Object[];
    if (typeof raw === 'string') { values = [raw]; }
    else if (Array.isArray(raw)) { values = raw as Object[]; }
    else { throw new Error('RcpInvalidHead'); }
    if (name === 'location') {
      if (locationSeen || values.length !== 1 || typeof values[0] !== 'string') { throw new Error('RcpInvalidLocation'); }
      locationSeen = true; const location: string = values[0] as string;
      if (location.length > HLS_MAX_URL_CHARS || new RegExp('[\\x00-\\x08\\x0a-\\x1f\\x7f]').test(location)) {
        throw new Error('RcpInvalidLocation');
      }
      parsed.location = trimOws(location);
      if (parsed.location.length === 0 || new RegExp('\\s').test(parsed.location)) { throw new Error('RcpInvalidLocation'); }
    } else if (group !== null) {
      if (group.length + values.length > 8) { throw new Error('RcpHeaderLimit'); }
      for (let j = 0; j < values.length; j++) {
        if (typeof values[j] !== 'string') { throw new Error('RcpInvalidHead'); }
        const text: string = values[j] as string; chars += text.length;
        if (chars > 16384 || new RegExp('[\\x00-\\x08\\x0a-\\x1f\\x7f-\\x9f]').test(text)) { throw new Error('RcpInvalidHead'); }
        group.push(trimOws(text));
      }
    }
  }
  return parsed;
}

function sameHead(a: AdaptiveResponseHead, b: AdaptiveResponseHead): boolean {
  return a.status === b.status && JSON.stringify(a.contentRange) === JSON.stringify(b.contentRange) &&
    JSON.stringify(a.contentLength) === JSON.stringify(b.contentLength) &&
    JSON.stringify(a.contentEncoding) === JSON.stringify(b.contentEncoding) &&
    JSON.stringify(a.transferEncoding) === JSON.stringify(b.transferEncoding);
}

function isRedirect(status: number): boolean { return [301, 302, 303, 307, 308].indexOf(status) >= 0; }

/** Reads through a caller-owned buffer, sized to what is stored, so the SDK never allocates the result
 * (a rejected read()/readInto() had already dequeued its bytes on device: 6 x 32768 lost of 524288). */
function readQueue(queue: rcp.INetworkOutputQueue, maxBytes: number): ArrayBuffer {
  const want: number = Math.min(maxBytes, queue.getStoredBytes());
  if (!Number.isSafeInteger(want) || want <= 0) { return new ArrayBuffer(0); }
  const buffer: ArrayBuffer = new ArrayBuffer(want);
  const count: number = queue.readInto(buffer);
  if (!Number.isSafeInteger(count) || count < 0 || count > want) { throw new Error('RcpQueueAccounting'); }
  return count === want ? buffer : buffer.slice(0, count);
}

function makeHandlers(fence: HopFence): rcp.HttpEventsHandler {
  const handlers: rcp.HttpEventsHandler = {
    onStatusCodeReceive: (status: number, request?: rcp.Request): void => {
      if (fence.owner !== null) { fence.owner.receiveStatus(fence, status, request); }
    },
    onHeaderReceive: (headers: rcp.ResponseHeaders, request?: rcp.Request): void => {
      if (fence.owner !== null) { fence.owner.receiveHeaders(fence, headers, request); }
    },
    onDataEnd: (request?: rcp.Request): void => { if (fence.owner !== null) { fence.owner.receiveEnd(fence, request); } },
    onDownloadProgress: (_total: number, _transferred: number, request?: rcp.Request): void => {
      if (fence.owner !== null) { fence.owner.receiveProgress(fence, request); }
    }
  };
  return handlers;
}

function watchFetch(promise: Promise<rcp.Response>, fence: HopFence): void {
  promise.then<void, void>((response: rcp.Response): void => {
    releaseFetchPermit(fence.permit); fence.permit = null;
    if (fence.owner !== null) { fence.owner.receiveResponse(fence, response); }
  }, (error: BusinessError): void => {
    releaseFetchPermit(fence.permit); fence.permit = null;
    if (fence.owner !== null) { fence.owner.receiveFailure(fence, numericError(error)); }
  });
}

/** Bounded SDK stream. The only retained SDK callback capture is its detachable HopFence. */
export class AdaptiveRcpStream {
  private request: AdaptiveStreamRequest = new AdaptiveStreamRequest();
  private onFailure: (code: string) => void;
  private clock: AdaptiveClock;
  private facts: AdaptiveStreamFacts = new AdaptiveStreamFacts();
  private head: AdaptiveResponseHead = new AdaptiveResponseHead();
  private hop: RcpHop | null = null;
  private detached: FetchPermit[] = [];
  private phase: string = 'new';
  private starting: Promise<AdaptiveStreamHeadResult> | null = null;
  private waiter: (() => void) | null = null;
  private timer: number = -1;
  private budgetEnd: number = 0;
  private lastNow: number = 0;
  private demandSince: number = -1;
  private closing: boolean = false;

  constructor(requestSnapshot: AdaptiveStreamRequest, onFailure: (code: string) => void,
    clock: AdaptiveClock = adaptiveNowMs) {
    this.onFailure = onFailure; this.clock = clock;
    try {
      this.request.identity = copyAdaptiveAttemptIdentity(requestSnapshot.identity);
      this.request.url = requestSnapshot.url; this.request.window = copyWindow(requestSnapshot.window);
      this.request.requestContext = cloneDownloadRequestContext(requestSnapshot.requestContext);
      this.request.networkDeadlineMs = requestSnapshot.networkDeadlineMs;
    } catch (e) { this.facts.failureCode = 'InvalidStreamRequest'; this.facts.failureKind = 'fatal'; }
  }

  start(): Promise<AdaptiveStreamHeadResult> {
    if (this.starting === null) { this.starting = this.startOwned(); }
    return this.starting.then<AdaptiveStreamHeadResult>((value: AdaptiveStreamHeadResult): AdaptiveStreamHeadResult => {
      const result: AdaptiveStreamHeadResult = new AdaptiveStreamHeadResult(); result.kind = value.kind;
      result.errorCode = value.errorCode; result.head = copyAdaptiveResponseHead(value.head); result.hop = value.hop; return result;
    });
  }

  private async startOwned(): Promise<AdaptiveStreamHeadResult> {
    try {
      if (this.phase !== 'new' || this.facts.failureCode !== '') { return this.headResult(); }
      if (!validAdaptiveAttemptIdentity(this.request.identity) || !Number.isSafeInteger(this.request.networkDeadlineMs) ||
        this.request.networkDeadlineMs < 1 || this.request.networkDeadlineMs > 300000) { throw new Error('InvalidStreamRequest'); }
      const now: number = this.now();
      if (now > Number.MAX_SAFE_INTEGER - ADAPTIVE_RCP_TRANSFER_MS) { throw new Error('InvalidStreamClock'); }
      this.budgetEnd = now + ADAPTIVE_RCP_TRANSFER_MS;
      let currentUrl: string = normalizeUrl(this.request.url);
      const saved: Record<string, string> = composeDownloadHeaders(currentUrl, this.request.requestContext);
      const visited: Set<string> = new Set<string>(); visited.add(currentUrl); let credentials: boolean = true;
      for (let redirects: number = 0; redirects <= 30; redirects++) {
        this.openHop(currentUrl, saved, credentials);
        while (this.facts.failureCode === '' && this.hop !== null && this.hop.accepted === null) { await this.waitSignal(); }
        if (this.facts.failureCode !== '' || this.hop === null) { return this.headResult(); }
        const accepted: ParsedHead | null = this.hop.accepted;
        if (accepted === null) { throw new Error('RcpInvalidHead'); }
        if (!isRedirect(accepted.head.status)) {
          this.head = copyAdaptiveResponseHead(accepted.head); this.facts.headTrusted = true;
          this.phase = 'body'; this.arm(); return this.headResult();
        }
        if (redirects === 30 || accepted.location.length === 0) { throw new Error('RcpRedirectLimit'); }
        const next: string = normalizeUrl(resolveHlsUrl(currentUrl, accepted.location));
        if (visited.has(next)) { throw new Error('RcpRedirectLoop'); }
        if (url.URL.parseURL(currentUrl).origin !== url.URL.parseURL(next).origin) { credentials = false; }
        this.closeHop(); if (this.facts.resourceUncertain) { return this.headResult(); }
        visited.add(next); currentUrl = next;
      }
    } catch (e) { this.fail('RcpRequestFailed', 'fatal'); }
    return this.headResult();
  }

  private openHop(currentUrl: string, saved: Record<string, string>, credentials: boolean): void {
    if (this.facts.failureCode !== '') { return; }
    const remaining: number = this.budgetEnd - this.now();
    if (remaining <= 0) { this.fail('RcpTransferBudgetExceeded', 'retryable'); return; }
    // Validate the clock before reserving admission for any SDK work.
    const headerDeadline: number = Math.min(this.budgetEnd, this.now() + this.request.networkDeadlineMs);
    const permit: FetchPermit | null = acquireFetchPermit();
    if (permit === null) { this.fail('RcpPendingFetchLimit', 'fatal'); return; }
    const hop: RcpHop = new RcpHop(); this.hop = hop; this.phase = 'headers';
    hop.fence.owner = this; hop.fence.serial = this.facts.sessionCount + 1; hop.fence.permit = permit;
    this.facts.headSource = 'none'; this.facts.headTrusted = false; this.facts.sdkEndObserved = false;
    this.facts.sdkPromiseSettled = false; this.facts.fetchSucceeded = false; this.facts.eof = false;
    this.facts.pulledBytes = 0; this.facts.receivedBytes = 0; this.facts.receivedExact = false;
    hop.headerDeadline = headerDeadline;
    try {
      const receiving: rcp.ReceivingPauseByCache = { kind: 'cacheSize', size: ADAPTIVE_RCP_QUEUE_BYTES };
      hop.queue = new rcp.NetworkOutputQueue(ADAPTIVE_RCP_QUEUE_CAPACITY, receiving);
      const timeout: rcp.Timeout = { connectMs: Math.min(this.request.networkDeadlineMs, remaining), transferMs: remaining };
      const transfer: rcp.TransferConfiguration = { autoRedirect: false, timeout: timeout };
      const tracing: rcp.TracingConfiguration = { verbose: false, httpEventsHandler: makeHandlers(hop.fence) };
      const configuration: rcp.Configuration = { transfer: transfer, tracing: tracing, proxy: currentRcpProxy() };
      const cacheControl: rcp.CacheControl = { noCache: true, noStore: true };
      const sessionConfiguration: rcp.SessionConfiguration = { requestConfiguration: configuration, cacheControl: cacheControl };
      hop.session = rcp.createSession(sessionConfiguration); this.facts.sessionCount++; this.facts.allSessionsApiClosed = false;
      const headers: Record<string, string> = {}; const keys: string[] = Object.keys(saved); let hasAccept: boolean = false;
      for (let i = 0; i < keys.length; i++) {
        const lower: string = keys[i].toLowerCase();
        if (['host', 'range', 'content-length', 'transfer-encoding'].indexOf(lower) >= 0 ||
          (!credentials && ['authorization', 'proxy-authorization', 'cookie'].indexOf(lower) >= 0)) { continue; }
        if (lower === 'accept') { hasAccept = true; } headers[keys[i]] = saved[keys[i]];
      }
      if (!hasAccept) { headers['Accept'] = '*/*'; }
      const window: AdaptiveRequestWindow = this.request.window;
      headers['Range'] = 'bytes=' + window.remoteStart + '-' + (window.remoteEnd < 0 ? '' : window.remoteEnd.toString());
      hop.request = new rcp.Request(currentUrl, 'GET', headers); hop.request.destination = hop.queue;
      hop.fence.requestId = hop.request.id; hop.fetchInvoked = true;
      const fetching: Promise<rcp.Response> = hop.session.fetch(hop.request); watchFetch(fetching, hop.fence); this.arm();
    } catch (e) {
      if (!hop.fetchInvoked) { releaseFetchPermit(permit); hop.fence.permit = null; }
      const code: number = numericError(e as BusinessError);
      this.fail(hop.fetchInvoked ? 'RcpFetchStartUncertain' :
        (code === 201 ? 'RcpPermissionDenied' : (code === 1007900994 ? 'RcpSessionUnavailable' : 'RcpConfigurationRejected')), 'fatal', code);
    }
  }

  private headResult(): AdaptiveStreamHeadResult {
    const result: AdaptiveStreamHeadResult = new AdaptiveStreamHeadResult(); result.head = copyAdaptiveResponseHead(this.head);
    result.hop = this.facts.sessionCount; result.errorCode = this.facts.failureCode;
    result.kind = this.facts.headTrusted && this.facts.failureCode === '' ? 'head' :
      (this.facts.failureKind === 'stopped' ? 'stopped' : 'failed'); return result;
  }

  private owns(fence: HopFence, request?: rcp.Request): boolean {
    return fence.owner === this && this.hop !== null && this.hop.fence === fence &&
      (request === undefined || request.id === fence.requestId);
  }

  /** SDK entry points require this module's exact, still-owned fence. */
  receiveStatus(fence: HopFence, status: number, request?: rcp.Request): void {
    if (!this.owns(fence, request) || this.hop === null) { return; }
    const hop: RcpHop = this.hop;
    if (++hop.events > 16) { this.fail('RcpHeaderLimit', 'fatal', 0, true); return; }
    if (hop.accepted !== null) { this.fail('RcpHeadSequenceChanged', 'fatal', 0, true); return; }
    if (!Number.isSafeInteger(status) || status < 100 || status > 599) {
      this.fail('RcpInvalidStatus', 'fatal', 0, true); return;
    }
    if (status === 101) { this.fail('RcpUnsupportedUpgrade', 'fatal', 0, true); return; }
    if (status < 200 && ++hop.informationalStatuses > 7) { this.fail('RcpHeaderLimit', 'fatal', 0, true); return; }
    const early: rcp.ResponseHeaders | null = hop.pendingHeaders;
    if (early !== null) {
      // Header-first order: this status closes the block that arrived before it. The SDK delivers
      // both orders (2026-10-18 device trace: headers->status and status->headers within one run).
      hop.pendingHeaders = null;
      if (status >= 200 && !hop.quarantine) {
        try { hop.accepted = parseHeaders(status, early); this.facts.headSource = 'early'; }
        catch (e) { this.fail('RcpInvalidHead', 'fatal', 0, true); return; }
      }
      this.wake(); return;
    }
    if (hop.pendingStatus !== -1) { hop.quarantine = true; }
    hop.pendingStatus = status; this.wake();
  }

  receiveHeaders(fence: HopFence, headers: rcp.ResponseHeaders, request?: rcp.Request): void {
    if (!this.owns(fence, request) || this.hop === null) { return; }
    const hop: RcpHop = this.hop;
    if (++hop.events > 16) { this.fail('RcpHeaderLimit', 'fatal', 0, true); return; }
    if (hop.accepted !== null) { this.fail('RcpHeadSequenceChanged', 'fatal', 0, true); return; }
    if (hop.pendingStatus < 0) {
      // Status not seen yet: hold this block for the next status. Two blocks with no status
      // between them cannot be paired and leave only the final-response head trustworthy.
      if (hop.pendingHeaders !== null) { hop.quarantine = true; }
      hop.pendingHeaders = headers; this.wake(); return;
    }
    try {
      const parsed: ParsedHead = parseHeaders(hop.pendingStatus, headers);
      if (!hop.quarantine && hop.pendingStatus >= 200) { hop.accepted = parsed; this.facts.headSource = 'early'; }
      hop.pendingStatus = -1; this.wake();
    } catch (e) { this.fail('RcpInvalidHead', 'fatal', 0, true); }
  }

  receiveEnd(fence: HopFence, request?: rcp.Request): void {
    if (this.owns(fence, request)) { this.facts.sdkEndObserved = true; this.wake(); }
  }

  receiveProgress(fence: HopFence, request?: rcp.Request): void {
    if (!this.owns(fence, request)) { return; }
    try { this.observeQueue(); this.wake(); } catch (e) { this.fail('RcpQueueReadFailed', 'fatal'); }
  }

  receiveResponse(fence: HopFence, response: rcp.Response): void {
    if (!this.owns(fence) || this.hop === null) { return; }
    const hop: RcpHop = this.hop; hop.settled = true; this.facts.sdkPromiseSettled = true; this.facts.fetchSucceeded = true;
    try {
      if (response.request.id !== fence.requestId) { throw new Error('RcpRequestMismatch'); }
      const parsed: ParsedHead = parseHeaders(response.statusCode, response.headers);
      if (hop.accepted !== null && !sameHead(hop.accepted.head, parsed.head)) {
        this.fail('RcpFinalHeadMismatch', 'fatal', 0, true); return;
      }
      if (hop.accepted === null) { hop.accepted = parsed; this.facts.headSource = 'finalResponse'; }
      hop.finalMatched = true; this.wake();
    } catch (e) { this.fail('RcpInvalidHead', 'fatal', 0, true); }
  }

  receiveFailure(fence: HopFence, code: number): void {
    if (!this.owns(fence) || this.hop === null) { return; }
    this.hop.settled = true; this.facts.sdkPromiseSettled = true;
    this.fail('RcpTransportFailure', 'retryable', code);
  }

  async waitReadable(): Promise<AdaptiveReadiness> {
    const result: AdaptiveReadiness = new AdaptiveReadiness();
    try {
      while (this.phase === 'body' && this.facts.failureCode === '') {
        if (this.observeQueue() > 0) { result.kind = 'ready'; return result; }
        if (this.updateEof()) { result.kind = 'eof'; return result; }
        if (this.demandSince < 0) { this.demandSince = this.now(); }
        await this.waitSignal();
      }
      result.kind = this.facts.failureKind === 'stopped' ? 'stopped' : 'failed'; result.errorCode = this.facts.failureCode;
    } catch (e) { this.fail('RcpQueueReadFailed', 'fatal'); result.errorCode = this.facts.failureCode; }
    finally { this.demandSince = -1; this.arm(); }
    return result;
  }

  pull(maxBytes: number): AdaptivePullResult {
    const result: AdaptivePullResult = new AdaptivePullResult();
    if (this.phase !== 'body' || !this.facts.headTrusted || this.facts.failureCode !== '' || this.hop === null ||
      this.hop.queue === null || !Number.isSafeInteger(maxBytes) || maxBytes < 1 || maxBytes > ADAPTIVE_RCP_PULL_BYTES) {
      result.errorCode = this.facts.failureCode || 'InvalidStreamPull'; return result;
    }
    try {
      const data: ArrayBuffer = readQueue(this.hop.queue, maxBytes);
      if (!(data instanceof ArrayBuffer) || data.byteLength > maxBytes ||
        this.facts.pulledBytes > Number.MAX_SAFE_INTEGER - data.byteLength) { throw new Error('RcpQueueAccounting'); }
      this.facts.pulledBytes += data.byteLength; this.observeQueue(); result.data = data;
      result.kind = data.byteLength === 0 ? 'empty' : 'data';
    } catch (e) {
      // 1007900990 is the queue-overflow abort seen through the read side: the lost bytes were never
      // appended, so a new attempt resumes from the sealed prefix. Anything else stays fatal.
      const overflow: boolean = (e as BusinessError).code === 1007900990;
      this.fail(overflow ? 'RcpQueueOverflow' : 'RcpQueueReadFailed', overflow ? 'retryable' : 'fatal');
      result.errorCode = this.facts.failureCode;
    }
    return result;
  }

  stop(reasonCode: string = 'Stopped'): void {
    if (this.phase === 'closed') { return; }
    this.updateEof();
    if (!this.facts.eof && this.facts.failureCode === '') {
      this.facts.failureCode = reasonCode === 'Disposed' ? 'Disposed' : 'Stopped'; this.facts.failureKind = 'stopped';
    }
    this.close();
  }

  close(): void {
    if (this.phase === 'closed' || this.closing) { return; }
    this.updateEof(); this.closeHop(); this.phase = 'closed'; this.demandSince = -1; this.clearTimer(); this.wake(false);
  }

  drain(): Promise<AdaptiveStreamFacts> {
    if (this.phase !== 'closed') { this.close(); }
    return Promise.resolve<AdaptiveStreamFacts>(this.snapshot());
  }

  snapshot(): AdaptiveStreamFacts {
    if (this.phase !== 'closed') { try { this.observeQueue(); this.updateEof(); } catch (e) { this.fail('RcpQueueReadFailed', 'fatal'); } }
    const result: AdaptiveStreamFacts = new AdaptiveStreamFacts();
    result.headSource = this.facts.headSource; result.headTrusted = this.facts.headTrusted;
    result.sdkEndObserved = this.facts.sdkEndObserved; result.sdkPromiseSettled = this.facts.sdkPromiseSettled;
    result.fetchSucceeded = this.facts.fetchSucceeded; result.eof = this.facts.eof;
    result.sessionCount = this.facts.sessionCount; result.apiClosedCount = this.facts.apiClosedCount;
    result.allSessionsApiClosed = this.facts.apiClosedCount === this.facts.sessionCount && !this.facts.resourceUncertain;
    result.resourceUncertain = this.facts.resourceUncertain;
    result.detachedFetchCount = this.detached.filter((permit: FetchPermit): boolean => !permit.released).length;
    result.transportCode = this.facts.transportCode; result.cancelCode = this.facts.cancelCode; result.closeCode = this.facts.closeCode;
    result.failureCode = this.facts.failureCode; result.failureKind = this.facts.failureKind;
    result.receivedBytes = this.facts.receivedBytes; result.receivedExact = this.facts.receivedExact;
    result.pulledBytes = this.facts.pulledBytes; result.maxQueuedBytes = this.facts.maxQueuedBytes; return result;
  }

  private observeQueue(): number {
    if (this.hop === null || this.hop.queue === null) { return 0; }
    const stored: number = this.hop.queue.getStoredBytes();
    if (!Number.isSafeInteger(stored) || stored < 0 || stored > ADAPTIVE_RCP_QUEUE_CAPACITY ||
      this.facts.pulledBytes > Number.MAX_SAFE_INTEGER - stored) { throw new Error('RcpQueueLimitBroken'); }
    this.facts.maxQueuedBytes = Math.max(this.facts.maxQueuedBytes, stored);
    this.facts.receivedBytes = Math.max(this.facts.receivedBytes, this.facts.pulledBytes + stored); return stored;
  }

  private updateEof(): boolean {
    if (this.facts.eof) { return true; }
    if (this.phase !== 'body' || this.hop === null || this.facts.failureCode !== '' || !this.facts.headTrusted ||
      !this.hop.finalMatched || !this.facts.fetchSucceeded || !this.facts.sdkEndObserved) { return false; }
    try {
      if (this.observeQueue() === 0 && this.facts.receivedBytes === this.facts.pulledBytes) {
        this.facts.eof = true; this.facts.receivedExact = true;
      }
    } catch (e) { this.fail('RcpQueueReadFailed', 'fatal'); }
    return this.facts.eof;
  }

  private closeHop(): void {
    const hop: RcpHop | null = this.hop; if (hop === null || this.closing) { return; }
    this.closing = true;
    try { this.observeQueue(); } catch (e) { if (this.facts.failureCode === '') { this.facts.failureCode = 'RcpQueueReadFailed'; this.facts.failureKind = 'fatal'; } }
    hop.fence.owner = null; hop.fence.requestId = ''; hop.fence.serial = 0;
    if (hop.fence.permit !== null && !hop.fence.permit.released) { this.detached.push(hop.fence.permit); }
    if (hop.session !== null) {
      if (!this.facts.eof) { try { hop.session.cancel(hop.request === null ? undefined : hop.request); } catch (e) { this.facts.cancelCode = numericError(e as BusinessError); } }
      try { hop.session.close(); this.facts.apiClosedCount++; }
      catch (e) {
        this.facts.closeCode = numericError(e as BusinessError); this.facts.resourceUncertain = true;
        this.facts.failureCode = 'RcpCloseFailed'; this.facts.failureKind = 'fatal';
      }
    }
    hop.session = null; hop.request = null; hop.queue = null; hop.accepted = null; this.hop = null; this.closing = false;
  }

  private fail(code: string, kind: string, transportCode: number = 0, untrustHead: boolean = false): void {
    if (this.phase === 'closed') { return; }
    if (this.facts.failureCode === '' || (this.facts.failureKind === 'stopped' && kind === 'fatal')) {
      this.facts.failureCode = code; this.facts.failureKind = kind; this.facts.transportCode = transportCode;
    }
    if (untrustHead) { this.facts.headTrusted = false; }
    this.facts.eof = false; this.facts.receivedExact = false; this.close();
    try { this.onFailure(this.facts.failureCode); } catch (e) { /* Consumer notification cannot escape an SDK callback. */ }
  }

  private now(): number {
    const now: number = this.clock();
    if (!Number.isSafeInteger(now) || now < 1 || now < this.lastNow) { throw new Error('InvalidStreamClock'); }
    this.lastNow = now; return now;
  }

  private checkDeadlines(): void {
    if (this.phase === 'new' || this.phase === 'closed') { return; }
    const now: number = this.now();
    if (now >= this.budgetEnd) { this.fail('RcpTransferBudgetExceeded', 'retryable'); return; }
    if (this.phase === 'headers' && this.hop !== null && now >= this.hop.headerDeadline) {
      const unsupported: boolean = this.hop.quarantine || this.observeQueue() > 0;
      this.fail(unsupported ? 'RcpHeadOrderUnsupported' : 'RcpHeaderTimeout', unsupported ? 'fatal' : 'retryable'); return;
    }
    if (this.demandSince >= 0 && this.observeQueue() === 0 && now - this.demandSince >= this.request.networkDeadlineMs) {
      const code: string = this.facts.fetchSucceeded ? 'RcpEndUnobserved' :
        (this.facts.sdkEndObserved ? 'RcpCompletionTimeout' : 'RcpIdleTimeout');
      this.fail(code, this.facts.fetchSucceeded ? 'fatal' : 'retryable');
    }
  }

  private clearTimer(): void { if (this.timer !== -1) { clearTimeout(this.timer); this.timer = -1; } }

  private arm(): void {
    this.clearTimer(); if (this.phase === 'new' || this.phase === 'closed') { return; }
    try {
      const now: number = this.now(); let wait: number = Math.max(1, this.budgetEnd - now);
      if (this.phase === 'headers' && this.hop !== null) { wait = Math.min(wait, Math.max(1, this.hop.headerDeadline - now)); }
      if (this.demandSince >= 0) { wait = Math.min(wait, Math.max(1, this.request.networkDeadlineMs - (now - this.demandSince))); }
      if (this.waiter !== null) { wait = Math.min(wait, 25); }
      this.timer = setTimeout((): void => {
        this.timer = -1;
        try { this.checkDeadlines(); this.wake(); } catch (e) { this.fail('RcpStreamClockFailed', 'fatal'); }
      }, wait);
    } catch (e) { this.fail('RcpStreamClockFailed', 'fatal'); }
  }

  private wake(arm: boolean = true): void {
    const resolve: (() => void) | null = this.waiter; this.waiter = null; if (resolve !== null) { resolve(); }
    if (arm) { this.arm(); }
  }

  private waitSignal(): Promise<void> {
    return new Promise<void>((resolve): void => { this.waiter = resolve; this.arm(); });
  }
}
