import { DownloadRequestContext, cloneDownloadRequestContext } from '../../model/DownloadRequestContext';
import { AdaptiveChunk, AdaptivePartState, copyAdaptiveChunk } from './AdaptivePlan';
import { AdaptiveAttemptIdentity, AdaptiveDispatch, AdaptiveSettlement } from './AdaptiveScheduler';
import { AdaptiveRequestWindow, AdaptiveResponseHead, AdaptiveBodyFacts, AdaptiveHeadCheck,
  AdaptiveTransferCheck, createAdaptiveWindow, inspectAdaptiveHead, inspectAdaptiveTransfer } from './AdaptiveProtocol';
import { AdaptiveAttemptFile, AttemptFileResult } from './AdaptiveAttemptFile';
import { AdaptiveClock, adaptiveNowMs, AdaptiveDownloadThrottle, AdaptiveGateGrant, AdaptiveGateResult,
  copyAdaptiveAttemptIdentity, validAdaptiveAttemptIdentity } from './AdaptiveDownloadThrottle';
import { AdaptiveRcpStream, AdaptiveStreamRequest, AdaptiveStreamFacts, AdaptiveStreamHeadResult,
  AdaptiveReadiness, AdaptivePullResult, ADAPTIVE_RCP_PULL_BYTES, copyAdaptiveResponseHead } from './AdaptiveRcpStream';

/** Optional diagnostics sink for rejected response heads: chunk id, numeric status and fixed code only
 * (never URLs, headers or bodies). Registered by the business shell; null in tests/probes. */
export type AdaptiveHeadRejectSink = (chunkId: string, status: number, code: string) => void;
let headRejectSink: AdaptiveHeadRejectSink | null = null;

export function setAdaptiveHeadRejectSink(sink: AdaptiveHeadRejectSink | null): void {
  headRejectSink = sink;
}

export class AdaptiveAttemptOptions {
  dispatch: AdaptiveDispatch = new AdaptiveDispatch();
  requestContext: DownloadRequestContext = new DownloadRequestContext();
  tempBase: string = '';
  knownResourceTotal: number = -1;
  networkTimeoutSeconds: number = 30;
}

export class AdaptiveAttemptResult {
  kind: string = 'settled';
  identity: AdaptiveAttemptIdentity = new AdaptiveAttemptIdentity();
  settlement: AdaptiveSettlement | null = null;
  stream: AdaptiveStreamFacts = new AdaptiveStreamFacts();
  file: AttemptFileResult | null = null;
  receivedBytes: number = 0;
  receivedExact: boolean = false;
  writtenBytes: number = 0;
  errorCode: string = '';
  discardFileName: string = '';
}

export function normalizeAdaptiveNetworkTimeout(rawSeconds: number): number {
  if (!Number.isFinite(rawSeconds) || rawSeconds <= 0) { return 30000; }
  return Math.max(1000, Math.ceil(Math.min(300, rawSeconds) * 1000));
}

function copyPart(value: AdaptivePartState): AdaptivePartState {
  const copied: AdaptivePartState = new AdaptivePartState(); copied.chunkId = value.chunkId;
  copied.downloaded = value.downloaded; copied.complete = value.complete; copied.fileName = value.fileName; return copied;
}

/** Only our closed, bounded receipt DTO enters this clone; no SDK object or external JSON enters it. */
function copyResult(value: AdaptiveAttemptResult): AdaptiveAttemptResult {
  return JSON.parse(JSON.stringify(value)) as AdaptiveAttemptResult;
}

function validPartName(value: string): boolean {
  return typeof value === 'string' && value.length >= 6 && value.length <= 125 &&
    new RegExp('^[A-Za-z0-9_-]+\\.part$').test(value) && !new RegExp('[\\r\\n\\u2028\\u2029]').test(value);
}

/** One immutable E1 claim. No constructor IO; only run admits a network/file operation. */
export class AdaptiveAttemptExecutor {
  private options: AdaptiveAttemptOptions = new AdaptiveAttemptOptions();
  private gate: AdaptiveDownloadThrottle;
  private clock: AdaptiveClock;
  private stream: AdaptiveRcpStream | null = null;
  private file: AdaptiveAttemptFile | null = null;
  private fileResult: AttemptFileResult | null = null;
  private window: AdaptiveRequestWindow | null = null;
  private head: AdaptiveResponseHead = new AdaptiveResponseHead();
  private headCheck: AdaptiveHeadCheck = new AdaptiveHeadCheck();
  private work: Promise<AdaptiveAttemptResult> | null = null;
  private completed: AdaptiveAttemptResult | null = null;
  private stopRequested: boolean = false;
  private disposed: boolean = false;
  private opening: boolean = false;
  private writtenBytes: number = 0;
  private fatalCode: string = '';
  private diskErrorCode: number = 0;

  constructor(options: AdaptiveAttemptOptions, sharedGate: AdaptiveDownloadThrottle, clock: AdaptiveClock = adaptiveNowMs) {
    this.gate = sharedGate; this.clock = clock;
    try {
      this.options.dispatch.identity = copyAdaptiveAttemptIdentity(options.dispatch.identity);
      const chunk: AdaptiveChunk | null = copyAdaptiveChunk(options.dispatch.chunk);
      if (chunk === null) { throw new Error('InvalidAdaptiveDispatch'); }
      this.options.dispatch.chunk = chunk; this.options.dispatch.prefix = copyPart(options.dispatch.prefix);
      this.options.dispatch.candidateFileName = options.dispatch.candidateFileName;
      this.options.requestContext = cloneDownloadRequestContext(options.requestContext);
      this.options.tempBase = options.tempBase; this.options.knownResourceTotal = options.knownResourceTotal;
      this.options.networkTimeoutSeconds = options.networkTimeoutSeconds;
      if (!validAdaptiveAttemptIdentity(this.options.dispatch.identity) || !this.gate.accepts(this.options.dispatch.identity) ||
        this.options.dispatch.identity.chunkId !== chunk.id || this.options.dispatch.prefix.chunkId !== chunk.id ||
        this.options.dispatch.prefix.complete !== false || !validPartName(this.options.dispatch.candidateFileName) ||
        (this.options.dispatch.prefix.downloaded > 0 && !validPartName(this.options.dispatch.prefix.fileName))) {
        throw new Error('InvalidAdaptiveDispatch');
      }
      this.window = createAdaptiveWindow(chunk, this.options.dispatch.prefix.downloaded, this.options.knownResourceTotal);
      if (this.window === null) { throw new Error('InvalidAdaptiveWindow'); }
    } catch (e) { this.fatalCode = 'InvalidAdaptiveDispatch'; }
  }

  run(): Promise<AdaptiveAttemptResult> {
    if (this.work === null) { this.work = this.execute(); }
    return this.work.then<AdaptiveAttemptResult>((value: AdaptiveAttemptResult): AdaptiveAttemptResult => copyResult(value));
  }

  stop(): void {
    if (this.completed !== null) { return; }
    this.stopRequested = true; this.gate.cancelAttempt(this.options.dispatch.identity);
    if (this.stream !== null) { this.stream.stop(); }
    if (this.opening && this.file !== null) { this.file.dispose(); }
  }

  dispose(): void {
    if (this.completed !== null || this.disposed) { return; }
    this.disposed = true; this.stopRequested = true; this.gate.cancelAttempt(this.options.dispatch.identity);
    if (this.stream !== null) { this.stream.stop('Disposed'); }
    if (this.file !== null) { this.file.dispose(); }
  }

  drain(): Promise<AdaptiveAttemptResult> {
    if (this.work === null) { this.stop(); }
    return this.run();
  }

  private async execute(): Promise<AdaptiveAttemptResult> {
    try {
      if (this.fatalCode === '' && !this.stopRequested && this.window !== null) {
        const request: AdaptiveStreamRequest = new AdaptiveStreamRequest();
        request.identity = copyAdaptiveAttemptIdentity(this.options.dispatch.identity); request.url = this.options.dispatch.chunk.url;
        request.window = this.window; request.requestContext = this.options.requestContext;
        request.networkDeadlineMs = normalizeAdaptiveNetworkTimeout(this.options.networkTimeoutSeconds);
        this.stream = new AdaptiveRcpStream(request, (_code: string): void => {
          this.gate.cancelAttempt(this.options.dispatch.identity);
          if (this.opening && this.file !== null) { this.file.dispose(); }
        }, this.clock);
        const opened: AdaptiveStreamHeadResult = await this.stream.start();
        this.head = copyAdaptiveResponseHead(opened.head);
        this.headCheck = inspectAdaptiveHead(this.window, this.head);
        if (opened.kind === 'head' && this.headCheck.kind === 'accept' && !this.stopRequested) {
          await this.openCandidate();
          if (this.fatalCode === '' && !this.stopRequested && this.fileResult !== null && this.fileResult.status === 'opened') {
            await this.consume();
          }
        } else if (opened.kind === 'head' && this.headCheck.kind === 'reject') {
          this.fatalCode = this.headCheck.code;
          const sink: AdaptiveHeadRejectSink | null = headRejectSink;
          if (sink !== null) {
            try { sink(this.options.dispatch.chunk.id, this.head.status, this.headCheck.code); } catch (_) { /* diagnostics only */ }
          }
        }
      }
    } catch (e) { if (this.fatalCode === '' && !this.disposed) { this.fatalCode = 'AdaptiveAttemptFailed'; } }
    try { await this.finishOwned(); }
    catch (e) {
      if (this.fatalCode === '') { this.fatalCode = 'AdaptiveAttemptFailed'; }
      if (this.stream !== null) { this.stream.close(); }
      await this.disposeCandidate();
    }
    const result: AdaptiveAttemptResult = this.makeResult(); this.completed = result; return result;
  }

  private async openCandidate(): Promise<void> {
    if (this.window === null || this.stopRequested) { return; }
    let maxBytes: number = this.window.chunkLength;
    if (maxBytes === -1) {
      if (this.headCheck.expectedBytes >= 0) {
        if (this.headCheck.writeBase > Number.MAX_SAFE_INTEGER - this.headCheck.expectedBytes) {
          this.fatalCode = 'AttemptByteOverflow'; return;
        }
        maxBytes = this.headCheck.writeBase + this.headCheck.expectedBytes;
      } else { maxBytes = Number.MAX_SAFE_INTEGER; }
    }
    this.file = new AdaptiveAttemptFile(this.options.tempBase, this.options.dispatch.identity.downloadId,
      this.options.dispatch.candidateFileName, maxBytes);
    this.opening = true;
    try {
      const copiedBytes: number = this.headCheck.writeBase;
      const prefixName: string = copiedBytes > 0 ? this.options.dispatch.prefix.fileName : '';
      this.fileResult = await this.file.open(prefixName, copiedBytes);
      if (this.fileResult.status !== 'opened' || this.fileResult.confirmedBytes !== copiedBytes) {
        const interrupted: boolean = this.fileResult.status === 'disposed' && this.fileResult.errorCode === 0 &&
          (this.stopRequested || (this.stream !== null && this.stream.snapshot().failureCode !== ''));
        if (!interrupted) { this.diskFailed(this.fileResult); }
      }
    } finally { this.opening = false; }
  }

  private async consume(): Promise<void> {
    const source: AdaptiveRcpStream | null = this.stream; const file: AdaptiveAttemptFile | null = this.file;
    if (source === null || file === null) { return; }
    while (!this.stopRequested && this.fatalCode === '') {
      const ready: AdaptiveReadiness = await source.waitReadable();
      if (ready.kind !== 'ready' || this.stopRequested) { break; }
      const grant: AdaptiveGateGrant = await this.gate.acquire(this.options.dispatch.identity);
      if (grant.kind !== 'granted') {
        if (grant.kind === 'fault') { this.fatalCode = grant.errorCode || 'ThrottleFailed'; }
        break;
      }
      let confirmed: number = 0;
      try {
        const facts: AdaptiveStreamFacts = source.snapshot();
        if (this.stopRequested || facts.failureCode !== '' || !facts.headTrusted) { break; }
        let maxPull: number = ADAPTIVE_RCP_PULL_BYTES;
        if (this.headCheck.expectedBytes >= 0) {
          maxPull = Math.min(maxPull, Math.max(1, this.headCheck.expectedBytes - facts.pulledBytes + 1));
        }
        const pulled: AdaptivePullResult = source.pull(maxPull);
        if (pulled.kind === 'empty') { continue; }
        if (pulled.kind !== 'data') { break; }
        const afterPull: AdaptiveStreamFacts = source.snapshot();
        if (this.stopRequested || afterPull.failureCode !== '' || !afterPull.headTrusted) { break; }
        const received: number = afterPull.receivedBytes;
        if (this.headCheck.expectedBytes >= 0 && received > this.headCheck.expectedBytes) {
          this.fatalCode = 'BodyTooLong'; break;
        }
        const previous: number = this.fileResult === null ? this.headCheck.writeBase : this.fileResult.confirmedBytes;
        this.fileResult = await file.append(pulled.data);
        const delta: number = this.fileResult.confirmedBytes - previous;
        if (!Number.isSafeInteger(delta) || delta < 0 || delta > pulled.data.byteLength ||
          this.writtenBytes > Number.MAX_SAFE_INTEGER - delta) { this.fatalCode = 'AttemptByteOverflow'; break; }
        confirmed = delta; this.writtenBytes += confirmed;
        if (this.fileResult.status !== 'appended' || confirmed !== pulled.data.byteLength) {
          if (!(this.disposed && this.fileResult.status === 'disposed' && this.fileResult.errorCode === 0)) {
            this.diskFailed(this.fileResult);
          }
        }
      } finally {
        const charged: AdaptiveGateResult = await this.gate.finish(grant, confirmed);
        if (charged.kind === 'fault' && this.fatalCode === '') { this.fatalCode = charged.errorCode || 'ThrottleFailed'; }
      }
    }
  }

  private diskFailed(result: AttemptFileResult): void {
    this.diskErrorCode = result.errorCode > 0 ? result.errorCode : 1;
    if (this.fatalCode === '') { this.fatalCode = 'DiskFailure'; }
  }

  private streamFacts(): AdaptiveStreamFacts { return this.stream === null ? new AdaptiveStreamFacts() : this.stream.snapshot(); }

  private inspect(): AdaptiveTransferCheck {
    if (this.window === null) { return new AdaptiveTransferCheck(); }
    const network: AdaptiveStreamFacts = this.streamFacts();
    const head: AdaptiveResponseHead = copyAdaptiveResponseHead(this.head);
    if (network.failureKind === 'retryable' || network.failureKind === 'stopped') {
      head.transportErrorCode = network.transportCode > 0 ? network.transportCode : 1;
    }
    const body: AdaptiveBodyFacts = new AdaptiveBodyFacts(); body.receivedBytes = network.receivedBytes;
    body.writtenBytes = this.writtenBytes; body.streamEnded = network.eof; body.stopRequested = this.stopRequested;
    body.diskErrorCode = this.diskErrorCode;
    return inspectAdaptiveTransfer(this.window, head, body);
  }

  private async finishOwned(): Promise<void> {
    if (this.stream !== null) { this.stream.close(); await this.stream.drain(); }
    const network: AdaptiveStreamFacts = this.streamFacts();
    if (network.failureKind === 'fatal' && this.fatalCode === '') { this.fatalCode = network.failureCode; }
    if (this.file === null) { return; }
    this.fileResult = await this.file.drain();
    if (this.disposed || this.fatalCode !== '' || network.resourceUncertain || !network.allSessionsApiClosed ||
      !network.headTrusted || this.fileResult.resourceUncertain || !this.fileResult.prefixClosed) {
      await this.disposeCandidate(); return;
    }
    const checked: AdaptiveTransferCheck = this.inspect();
    let retain: number = -1;
    if (checked.kind === 'completeBytes') { retain = checked.prefixLimit; }
    else if (checked.kind === 'partialBytes' || checked.kind === 'retryable') {
      if (checked.allowNewPrefix && checked.prefixLimit > 0 &&
        (checked.prefixLimit > this.options.dispatch.prefix.downloaded || checked.resetPrefix)) { retain = checked.prefixLimit; }
    } else if (checked.kind === 'reject') { this.fatalCode = checked.code; }
    if (retain < 0) { await this.disposeCandidate(); return; }
    this.fileResult = await this.file.seal(retain);
    if (!this.fileResult.sealed || !this.fileResult.closed || this.fileResult.resourceUncertain ||
      !this.fileResult.cleanupComplete || this.fileResult.confirmedBytes !== retain ||
      this.fileResult.fileName !== this.options.dispatch.candidateFileName) {
      if (!(this.disposed && this.fileResult.status === 'disposed' && this.fileResult.errorCode === 0)) {
        this.diskFailed(this.fileResult);
      }
      await this.disposeCandidate();
    }
  }

  private async disposeCandidate(): Promise<void> {
    if (this.file === null) { return; }
    try { this.file.dispose(); this.fileResult = await this.file.drain(); }
    catch (e) {
      const uncertain: AttemptFileResult = new AttemptFileResult(); uncertain.status = 'ioError';
      uncertain.closed = false; uncertain.resourceUncertain = true; uncertain.cleanupComplete = false;
      uncertain.prefixClosed = false; uncertain.candidateClosed = false; this.fileResult = uncertain;
    }
  }

  private makeResult(): AdaptiveAttemptResult {
    const result: AdaptiveAttemptResult = new AdaptiveAttemptResult(); result.identity = copyAdaptiveAttemptIdentity(this.options.dispatch.identity);
    result.stream = this.streamFacts(); result.file = this.fileResult;
    result.receivedBytes = result.stream.receivedBytes; result.receivedExact = result.stream.receivedExact;
    result.writtenBytes = this.writtenBytes;
    const file: AttemptFileResult | null = this.fileResult;
    if (result.stream.resourceUncertain || !result.stream.allSessionsApiClosed ||
      (file !== null && (file.resourceUncertain || !file.closed))) {
      result.kind = 'resourceFault'; result.errorCode = result.stream.resourceUncertain ? 'RcpCloseFailed' : 'AttemptResourceUncertain';
      return result;
    }
    if (file !== null && !file.cleanupComplete && this.fatalCode === '') { this.fatalCode = 'AttemptCleanupFailed'; }
    if (this.disposed) {
      result.kind = 'disposed'; result.errorCode = this.fatalCode;
      if (file !== null && file.sealed) { result.discardFileName = file.fileName; } return result;
    }
    const checked: AdaptiveTransferCheck = this.inspect();
    const settlement: AdaptiveSettlement = new AdaptiveSettlement(); settlement.identity = copyAdaptiveAttemptIdentity(result.identity);
    settlement.whole200Reset = this.headCheck.kind === 'accept' && this.headCheck.resetPrefix;
    if (this.fatalCode !== '') { settlement.outcome = 'fatal'; settlement.errorCode = this.fatalCode; }
    else if (checked.kind === 'completeBytes' && file !== null && file.sealed) { settlement.outcome = 'complete'; }
    else if (this.stopRequested) { settlement.outcome = 'stopped'; }
    else if (checked.kind === 'reject') { settlement.outcome = 'fatal'; settlement.errorCode = checked.code; }
    else { settlement.outcome = 'retryable'; settlement.errorCode = result.stream.failureCode || checked.code; }
    if (file !== null && file.sealed && settlement.outcome !== 'fatal') {
      const part: AdaptivePartState = new AdaptivePartState(); part.chunkId = this.options.dispatch.chunk.id;
      part.downloaded = file.confirmedBytes; part.complete = settlement.outcome === 'complete'; part.fileName = file.fileName;
      settlement.sealedPart = part;
    } else if (file !== null && file.sealed) { result.discardFileName = file.fileName; }
    result.settlement = settlement; result.errorCode = settlement.errorCode; return result;
  }
}
