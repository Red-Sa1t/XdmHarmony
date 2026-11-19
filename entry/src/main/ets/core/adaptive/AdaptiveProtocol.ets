import { AdaptiveChunk, copyAdaptiveChunk, ADAPTIVE_MAX_CHUNKS } from './AdaptivePlan';

const MAX_HEADER_VALUES: number = 8;
const MAX_HEADER_CHARS: number = 16384;

export class AdaptiveRequestWindow {
  chunkId: string = '';
  chunkOffset: number = 0;
  chunkLength: number = -1;
  prefixBytes: number = 0;
  remoteStart: number = 0;
  remoteEnd: number = -1;
  knownResourceTotal: number = -1;
}

export class AdaptiveContentRange {
  kind: string = 'invalid';
  start: number = -1;
  end: number = -1;
  total: number = -1;
}

/** Arrays preserve duplicate critical fields. Error codes are normalized numeric values, not text. */
export class AdaptiveResponseHead {
  status: number = 0;
  transportErrorCode: number = 0;
  contentRange: string[] = [];
  contentLength: string[] = [];
  contentEncoding: string[] = [];
  transferEncoding: string[] = [];
}

/** Counts belong to this response. Copying the old prefix is excluded from both counts. */
export class AdaptiveBodyFacts {
  receivedBytes: number = 0;
  writtenBytes: number = 0;
  writesPending: boolean = false;
  streamEnded: boolean = false;
  stopRequested: boolean = false;
  diskErrorCode: number = 0;
}

export class AdaptiveHeadCheck {
  kind: string = 'reject';
  code: string = 'InvalidHead';
  expectedBytes: number = -1;
  writeBase: number = 0;
  resetPrefix: boolean = false;
  completeEligible: boolean = false;
  resourceTotal: number = -1;
}

export class AdaptiveTransferCheck {
  kind: string = 'reject';
  code: string = 'InvalidBody';
  expectedBytes: number = -1;
  writeBase: number = 0;
  resetPrefix: boolean = false;
  /** If false, prefixLimit refers only to the previously sealed file. */
  allowNewPrefix: boolean = false;
  prefixLimit: number = 0;
}

function safeCount(value: number): boolean { return Number.isSafeInteger(value) && value >= 0; }

function exactFields(value: Object | null, fields: string[]): boolean {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) { return false; }
  const keys: string[] = Object.keys(value);
  if (keys.length !== fields.length) { return false; }
  for (let i = 0; i < keys.length; i++) { if (fields.indexOf(keys[i]) < 0) { return false; } }
  return true;
}

function validWindow(window: AdaptiveRequestWindow): boolean {
  if (!exactFields(window, ['chunkId', 'chunkOffset', 'chunkLength', 'prefixBytes', 'remoteStart',
    'remoteEnd', 'knownResourceTotal']) || typeof window.chunkId !== 'string' || !noControls(window.chunkId) ||
    !new RegExp('^c(0|[1-9][0-9]{0,4})$').test(window.chunkId) ||
    Number(window.chunkId.substring(1)) >= ADAPTIVE_MAX_CHUNKS || !safeCount(window.chunkOffset) ||
    !safeCount(window.prefixBytes) || !safeCount(window.remoteStart) ||
    !(window.knownResourceTotal === -1 || safeCount(window.knownResourceTotal))) { return false; }
  if (window.chunkLength === -1) {
    return window.chunkOffset === 0 && window.remoteStart === window.prefixBytes && window.remoteEnd === -1;
  }
  if (!safeCount(window.chunkLength) || window.chunkLength === 0 || window.prefixBytes >= window.chunkLength ||
    window.chunkOffset > Number.MAX_SAFE_INTEGER - (window.chunkLength - 1)) { return false; }
  return window.remoteStart === window.chunkOffset + window.prefixBytes &&
    window.remoteEnd === window.chunkOffset + (window.chunkLength - 1) &&
    (window.knownResourceTotal === -1 || window.remoteEnd < window.knownResourceTotal);
}

/** Builds a window for an unfinished chunk; a full known-range prefix is never proof of completion. */
export function createAdaptiveWindow(chunk: AdaptiveChunk, prefixBytes: number,
  knownResourceTotal: number = -1): AdaptiveRequestWindow | null {
  const checked: AdaptiveChunk | null = copyAdaptiveChunk(chunk);
  if (checked === null || !safeCount(prefixBytes) ||
    !(knownResourceTotal === -1 || safeCount(knownResourceTotal))) { return null; }
  const window: AdaptiveRequestWindow = new AdaptiveRequestWindow();
  window.chunkId = checked.id; window.chunkOffset = checked.offset; window.chunkLength = checked.length;
  window.prefixBytes = prefixBytes; window.knownResourceTotal = knownResourceTotal;
  if (checked.length === -1) { window.remoteStart = prefixBytes; }
  else {
    if (prefixBytes >= checked.length) { return null; }
    window.remoteStart = checked.offset + prefixBytes;
    window.remoteEnd = checked.offset + (checked.length - 1);
  }
  return validWindow(window) ? window : null;
}

function trimOws(value: string): string {
  let first: number = 0; let last: number = value.length;
  while (first < last && (value.charAt(first) === ' ' || value.charAt(first) === '\t')) { first++; }
  while (last > first && (value.charAt(last - 1) === ' ' || value.charAt(last - 1) === '\t')) { last--; }
  return value.substring(first, last);
}

function noControls(value: string): boolean {
  for (let i = 0; i < value.length; i++) {
    const code: number = value.charCodeAt(i);
    if ((code < 32 && code !== 9) || (code >= 127 && code <= 159)) { return false; }
  }
  return true;
}

function decimal(value: string): number {
  if (value.length === 0) { return -1; }
  let result: number = 0;
  for (let i = 0; i < value.length; i++) {
    const digit: number = value.charCodeAt(i) - 48;
    if (digit < 0 || digit > 9 || result > Math.floor((Number.MAX_SAFE_INTEGER - digit) / 10)) { return -1; }
    result = result * 10 + digit;
  }
  return result;
}

export function parseAdaptiveContentRange(text: string): AdaptiveContentRange {
  const result: AdaptiveContentRange = new AdaptiveContentRange();
  if (typeof text !== 'string' || text.length > MAX_HEADER_CHARS || !noControls(text)) { return result; }
  const value: string = trimOws(text);
  const unsatisfied: RegExpExecArray | null = new RegExp('^bytes[ \\t]+\\*/([0-9]+)$', 'i').exec(value);
  if (unsatisfied !== null) {
    const total: number = decimal(unsatisfied[1]);
    if (total >= 0) { result.kind = 'unsatisfied'; result.total = total; }
    return result;
  }
  const matched: RegExpExecArray | null = new RegExp('^bytes[ \\t]+([0-9]+)-([0-9]+)/(\\*|[0-9]+)$', 'i').exec(value);
  if (matched === null) { return result; }
  const start: number = decimal(matched[1]); const end: number = decimal(matched[2]);
  const total: number = matched[3] === '*' ? -1 : decimal(matched[3]);
  if (start < 0 || end < start || end - start === Number.MAX_SAFE_INTEGER ||
    (matched[3] !== '*' && (total < 0 || total <= end))) { return result; }
  result.kind = 'range'; result.start = start; result.end = end; result.total = total;
  return result;
}

function validHeaders(head: AdaptiveResponseHead): boolean {
  if (!exactFields(head, ['status', 'transportErrorCode', 'contentRange', 'contentLength', 'contentEncoding',
    'transferEncoding']) || !safeCount(head.status) || head.status > 599 ||
    !safeCount(head.transportErrorCode)) { return false; }
  const groups: string[][] = [head.contentRange, head.contentLength, head.contentEncoding, head.transferEncoding];
  let chars: number = 0;
  for (let i = 0; i < groups.length; i++) {
    const values: string[] = groups[i];
    if (!Array.isArray(values) || values.length > MAX_HEADER_VALUES) { return false; }
    for (let j = 0; j < values.length; j++) {
      if (typeof values[j] !== 'string' || values[j].length > MAX_HEADER_CHARS - chars) { return false; }
      chars += values[j].length;
      if (!noControls(values[j])) { return false; }
    }
  }
  return true;
}

/** -1 is absent, -2 is invalid; a present zero is not absence. */
function contentLength(values: string[]): number {
  let result: number = -1;
  for (let i = 0; i < values.length; i++) {
    const current: number = decimal(trimOws(values[i]));
    if (current < 0 || (result >= 0 && result !== current)) { return -2; }
    result = current;
  }
  return result;
}

function singleEncoding(values: string[], permitted: string): boolean {
  return values.length === 0 || (values.length === 1 && trimOws(values[0]).toLowerCase() === permitted);
}

function rejectedHead(code: string, kind: string = 'reject'): AdaptiveHeadCheck {
  const result: AdaptiveHeadCheck = new AdaptiveHeadCheck(); result.code = code; result.kind = kind;
  return result;
}

/** Valid HTTP metadata can be retained after a later transport failure; transfer inspection handles that failure. */
export function inspectAdaptiveHead(window: AdaptiveRequestWindow, head: AdaptiveResponseHead): AdaptiveHeadCheck {
  if (!validWindow(window)) { return rejectedHead('InvalidWindow'); }
  if (!validHeaders(head)) { return rejectedHead('InvalidHead'); }
  if (head.status === 0) { return rejectedHead('TransportFailure', 'retryable'); }
  if (head.status !== 200 && head.status !== 206) {
    if ([408, 429, 500, 502, 503, 504].indexOf(head.status) >= 0) {
      return rejectedHead('TransientHttp', 'retryable');
    }
    // Source HttpChunkDownloader: EnsureSuccessStatusCode throws for every HTTP error and the chunk
    // retries up to MaxRetry with RetryDelay. Real CDN edges answer sporadic 404s for existing
    // segments (2026-11-06 device evidence), so 4xx stays within the bounded retry budget; the
    // fixed code still names the class once retries are exhausted. 1xx/2xx-other/3xx remain fatal.
    const code: string = head.status === 416 ? 'RangeUnsatisfied' :
      (head.status === 401 || head.status === 403 ? 'AuthOrSession' : 'InvalidResponse');
    return rejectedHead(code, head.status >= 400 && head.status <= 599 ? 'retryable' : 'reject');
  }
  if (!singleEncoding(head.contentEncoding, 'identity')) { return rejectedHead('UnsupportedEncoding'); }
  if (!singleEncoding(head.transferEncoding, 'chunked') ||
    (head.transferEncoding.length !== 0 && head.contentLength.length !== 0)) { return rejectedHead('InvalidFraming'); }
  const length: number = contentLength(head.contentLength);
  if (length === -2 || head.contentRange.length > 1) { return rejectedHead('InvalidLength'); }
  const result: AdaptiveHeadCheck = new AdaptiveHeadCheck();
  if (head.status === 200) {
    if (window.chunkLength !== -1) { return rejectedHead('RangeNotHonored'); }
    if (head.contentRange.length !== 0) { return rejectedHead('UnexpectedContentRange'); }
    result.writeBase = 0; result.resetPrefix = window.prefixBytes > 0;
    result.expectedBytes = length; result.completeEligible = true; result.resourceTotal = length;
  } else {
    if (head.contentRange.length !== 1) { return rejectedHead('InvalidContentRange'); }
    const range: AdaptiveContentRange = parseAdaptiveContentRange(head.contentRange[0]);
    if (range.kind !== 'range' || range.start !== window.remoteStart ||
      (window.remoteEnd !== -1 && range.end !== window.remoteEnd) ||
      (window.knownResourceTotal !== -1 && range.total !== window.knownResourceTotal)) {
      return rejectedHead('RangeMismatch');
    }
    const span: number = range.end - range.start + 1;
    if (length !== -1 && length !== span) { return rejectedHead('LengthMismatch'); }
    result.writeBase = window.prefixBytes; result.expectedBytes = span; result.resourceTotal = range.total;
    result.completeEligible = window.chunkLength !== -1 || (range.total !== -1 && range.end === range.total - 1);
  }
  result.kind = 'accept'; result.code = 'Accepted'; return result;
}

function validBody(body: AdaptiveBodyFacts): boolean {
  return exactFields(body, ['receivedBytes', 'writtenBytes', 'writesPending', 'streamEnded', 'stopRequested',
    'diskErrorCode']) && safeCount(body.receivedBytes) && safeCount(body.writtenBytes) &&
    body.writtenBytes <= body.receivedBytes && safeCount(body.diskErrorCode) &&
    typeof body.writesPending === 'boolean' && typeof body.streamEnded === 'boolean' &&
    typeof body.stopRequested === 'boolean';
}

/** Byte eligibility only: a completeBytes result still requires real fsync/close/seal before scheduling settlement. */
export function inspectAdaptiveTransfer(window: AdaptiveRequestWindow, head: AdaptiveResponseHead,
  body: AdaptiveBodyFacts): AdaptiveTransferCheck {
  const result: AdaptiveTransferCheck = new AdaptiveTransferCheck();
  if (!validWindow(window)) { result.code = 'InvalidWindow'; return result; }
  result.prefixLimit = window.prefixBytes; result.writeBase = window.prefixBytes;
  if (!validBody(body)) { return result; }
  const checked: AdaptiveHeadCheck = inspectAdaptiveHead(window, head);
  if (checked.kind !== 'accept') {
    result.kind = checked.kind; result.code = checked.code;
    if (checked.kind === 'retryable' && head.status === 0 && body.stopRequested && body.diskErrorCode === 0) {
      result.kind = 'partialBytes'; result.code = 'Stopped';
    }
    if (body.diskErrorCode !== 0) { result.kind = 'reject'; result.code = 'DiskFailure'; }
    if (body.writesPending) { result.kind = 'pending'; }
    return result;
  }
  result.expectedBytes = checked.expectedBytes; result.writeBase = checked.writeBase;
  result.resetPrefix = checked.resetPrefix;
  if (body.writtenBytes > Number.MAX_SAFE_INTEGER - checked.writeBase) { return result; }
  if (checked.expectedBytes !== -1 && body.receivedBytes > checked.expectedBytes) {
    result.code = 'BodyTooLong';
    if (body.writesPending) { result.kind = 'pending'; }
    return result;
  }
  const writtenTotal: number = checked.writeBase + body.writtenBytes;
  result.allowNewPrefix = true;
  result.prefixLimit = window.chunkLength === -1 ? writtenTotal : Math.min(writtenTotal, window.chunkLength - 1);
  if (body.diskErrorCode !== 0) {
    result.code = 'DiskFailure'; if (body.writesPending) { result.kind = 'pending'; } return result;
  }
  if (body.writesPending) { result.kind = 'pending'; result.code = 'WritesPending'; return result; }
  if (head.transportErrorCode !== 0) {
    result.kind = body.stopRequested ? 'partialBytes' : 'retryable';
    result.code = body.stopRequested ? 'Stopped' : 'TransportFailure'; return result;
  }
  const bodyExact: boolean = body.receivedBytes === body.writtenBytes &&
    (checked.expectedBytes === -1 || body.receivedBytes === checked.expectedBytes);
  if (body.streamEnded && bodyExact && checked.completeEligible) {
    result.kind = 'completeBytes'; result.code = 'Complete'; result.prefixLimit = writtenTotal; return result;
  }
  result.kind = 'partialBytes';
  result.code = body.stopRequested ? 'Stopped' :
    (body.streamEnded && bodyExact && !checked.completeEligible ? 'WholeExtentUnproven' : 'IncompleteBody');
  return result;
}
