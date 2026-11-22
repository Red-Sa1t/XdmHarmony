// Startup GET manifests use explicit redirects: HttpRequestContext.url does not
// promise the effective response URL. Each request and deadline belongs to one call.
// Hops use RCP with autoRedirect=false: @ohos.net.http maxRedirects is only a follow cap, and
// maxRedirects=0 rejects the first 3xx with 2300047 instead of returning it (2026-10-18 device
// P6-U4 S3), so a redirected manifest could never be fetched.
import { rcp } from '@kit.RemoteCommunicationKit';
import { url, util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { DownloadRequestContext, cloneDownloadRequestContext, composeDownloadHeaders } from '../../model/DownloadRequestContext';
import { HLS_MAX_URL_CHARS } from './HlsModel';
import { HLS_MAX_MANIFEST_CHARS } from './HlsParser';
import { isAdaptiveHttpUrl } from './AdaptivePlan';
import { currentRcpProxy } from './RcpProxy';
import { resolveHlsUrl } from './HlsUrlResolver';


export const MANIFEST_MAX_BYTES: number = HLS_MAX_MANIFEST_CHARS * 4;
export const MANIFEST_MAX_REDIRECTS: number = 30;
export const MANIFEST_MAX_TIMEOUT_MS: number = 300000;

export class ManifestFetchResult {
  status: string = 'invalid';
  requestedUrl: string = '';
  finalUrl: string = '';
  text: string = '';
  httpStatus: number = 0;
  errorCode: number = 0;
}

class ManifestHop {
  response: rcp.Response | undefined = undefined;
  errorCode: number = 0;
}

class ManifestScope {
  requestedUrl: string = '';
  currentUrl: string = '';
  live: boolean = true;
  request: rcp.Session | undefined = undefined;
  timerId: number = -1;
  deadline: number = 0;
  timeoutMs: number = 0;
  stopResult: ManifestFetchResult | undefined = undefined;
  resolveStop: ((value: ManifestHop) => void) | undefined = undefined;
  stopGate: Promise<ManifestHop>;

  constructor() {
    this.stopGate = new Promise<ManifestHop>((resolve: (value: ManifestHop) => void): void => {
      this.resolveStop = resolve;
    });
  }
}

function resultOf(status: string, scope?: ManifestScope, httpStatus: number = 0,
  errorCode: number = 0): ManifestFetchResult {
  const result: ManifestFetchResult = new ManifestFetchResult();
  result.status = status;
  result.requestedUrl = scope?.requestedUrl ?? '';
  result.finalUrl = scope?.currentUrl ?? '';
  result.httpStatus = httpStatus;
  result.errorCode = errorCode;
  return result;
}

// RCP reports libcurl results as 1007900000 + CURLcode; keep this module's established
// 23000xx network-code contract (2300028 timeout, 2300063 size) for callers and evidence.
const RCP_CURL_BASE: number = 1007900000;

function errorNumber(error: BusinessError): number {
  if (error === null || typeof error !== 'object') { return 0; }
  const code: number = Number.isSafeInteger(error.code) && error.code >= 0 ? error.code : 0;
  return code > RCP_CURL_BASE && code < RCP_CURL_BASE + 100 ? 2300000 + (code - RCP_CURL_BASE) : code;
}

function requestUrl(value: string): string {
  if (!isAdaptiveHttpUrl(value)) { throw new Error('Invalid manifest URL'); }
  const parsed: url.URL = url.URL.parseURL(value);
  if ((parsed.protocol !== 'http:' && parsed.protocol !== 'https:') || parsed.hostname.length === 0) {
    throw new Error('Invalid manifest URL');
  }
  parsed.hash = '';
  const normalized: string = parsed.href;
  if (!isAdaptiveHttpUrl(normalized)) { throw new Error('Invalid manifest URL'); }
  return normalized;
}

function requestHeaders(saved: Record<string, string>, credentials: boolean): Record<string, string> {
  const headers: Record<string, string> = {};
  const keys: string[] = Object.keys(saved);
  let hasAccept: boolean = false;
  for (let i = 0; i < keys.length; i++) {
    const name: string = keys[i].toLowerCase();
    if (name === 'host' || name === 'content-length' || name === 'transfer-encoding' ||
      (!credentials && (name === 'authorization' || name === 'proxy-authorization' || name === 'cookie'))) {
      continue;
    }
    if (name === 'accept') { hasAccept = true; }
    headers[keys[i]] = saved[keys[i]];
  }
  if (!hasAccept) { headers['Accept'] = '*/*'; }
  return headers;
}

// Header values are SDK data. Reject ambiguous fields instead of coercing objects
// or joining multiple Locations into a different (potentially signed) URL.
function redirectLocation(header: Object): string {
  if (header === null || typeof header !== 'object' || Array.isArray(header)) { return ''; }
  const record: Record<string, Object> = header as Record<string, Object>;
  const keys: string[] = Object.keys(record);
  let found: boolean = false;
  let value: string = '';
  for (let i = 0; i < keys.length; i++) {
    if (keys[i].toLowerCase() !== 'location') { continue; }
    if (found) { return ''; }
    found = true;
    const raw: Object | undefined = record[keys[i]];
    if (typeof raw === 'string') {
      value = raw as string;
    } else if (Array.isArray(raw)) {
      const values: Object[] = raw as Object[];
      if (values.length !== 1 || typeof values[0] !== 'string') { return ''; }
      value = values[0] as string;
    } else {
      return '';
    }
  }
  if (!found || value.length > HLS_MAX_URL_CHARS || new RegExp('[\\x00-\\x08\\x0a-\\x1f\\x7f]').test(value)) {
    return '';
  }
  // Only HTTP field OWS is stripped; URL controls or whitespace inside it remain invalid.
  value = value.replace(new RegExp('^[ \\t]+|[ \\t]+$', 'g'), '');
  if (value.length === 0 || new RegExp('[\\s]').test(value)) { return ''; }
  return value;
}

function isRedirect(status: number): boolean {
  return status === 301 || status === 302 || status === 303 || status === 307 || status === 308;
}

export class ManifestClient {
  private active: ManifestScope | undefined = undefined;

  async fetchGet(inputUrl: string, context: DownloadRequestContext,
    timeoutMs: number): Promise<ManifestFetchResult> {
    if (this.active !== undefined) { return resultOf('busy'); }
    if (!Number.isSafeInteger(timeoutMs) || timeoutMs <= 0 || timeoutMs > MANIFEST_MAX_TIMEOUT_MS) {
      return resultOf('invalid');
    }
    let normalized: string = '';
    let headers: Record<string, string>;
    try {
      normalized = requestUrl(inputUrl);
      const snapshot: DownloadRequestContext = cloneDownloadRequestContext(context);
      headers = composeDownloadHeaders(normalized, snapshot);
    } catch (_) {
      // SDK errors and request contexts can contain credentials. Never return/log their text.
      return resultOf('invalid');
    }
    const scope: ManifestScope = new ManifestScope();
    scope.requestedUrl = inputUrl;
    scope.currentUrl = normalized;
    scope.timeoutMs = timeoutMs;
    scope.deadline = Date.now() + timeoutMs;
    this.active = scope;
    try {
      scope.timerId = setTimeout((): void => {
        this.stop(scope, 'networkError', 2300028);
      }, timeoutMs);
      const result: ManifestFetchResult = await this.fetchChain(scope, headers);
      return scope.stopResult ?? result;
    } catch (error) {
      return scope.stopResult ?? resultOf('networkError', scope, 0, errorNumber(error as BusinessError));
    } finally {
      scope.live = false;
      this.clearTimer(scope);
      const request: rcp.Session | undefined = scope.request;
      if (request !== undefined) { this.releaseRequest(scope, request); }
      if (this.active === scope) { this.active = undefined; }
    }
  }

  cancel(): void {
    const scope: ManifestScope | undefined = this.active;
    if (scope !== undefined) { this.stop(scope, 'cancelled', 0); }
  }

  private stop(scope: ManifestScope, status: string, errorCode: number): void {
    if (!scope.live) { return; }
    scope.live = false;
    scope.stopResult = resultOf(status, scope, 0, errorCode);
    // Release this identity synchronously so cancel(); fetchGet() is safe even
    // while the old request's native Promise remains unresolved.
    if (this.active === scope) { this.active = undefined; }
    const resolve: ((value: ManifestHop) => void) | undefined = scope.resolveStop;
    scope.resolveStop = undefined;
    if (resolve !== undefined) { resolve(new ManifestHop()); }
    this.clearTimer(scope);
    const request: rcp.Session | undefined = scope.request;
    if (request !== undefined) { this.releaseRequest(scope, request); }
  }

  private stillLive(scope: ManifestScope): boolean {
    if (!scope.live) { return false; }
    if (Date.now() >= scope.deadline) {
      this.stop(scope, 'networkError', 2300028);
      return false;
    }
    return true;
  }

  private clearTimer(scope: ManifestScope): void {
    const timer: number = scope.timerId;
    scope.timerId = -1;
    if (timer >= 0) { clearTimeout(timer); }
  }

  private releaseRequest(scope: ManifestScope, request: rcp.Session): void {
    if (scope.request !== request) { return; }
    scope.request = undefined;
    try { request.cancel(); } catch (_) {
      // Cancelling an already settled session is a no-op for this scope; close below still runs.
    }
    try { request.close(); } catch (_) {
      // Cleanup was attempted once. The SDK may fail to release its own handle;
      // that cannot change an already completed result or affect another scope.
    }
  }

  private async fetchHop(scope: ManifestScope, headers: Record<string, string>,
    remaining: number): Promise<ManifestHop> {
    let request: rcp.Session | undefined = undefined;
    try {
      const timeout: number = Math.min(scope.timeoutMs, Math.max(1, Math.ceil(scope.deadline - Date.now())));
      const timeouts: rcp.Timeout = { connectMs: timeout, transferMs: timeout };
      const transfer: rcp.TransferConfiguration = { autoRedirect: false, timeout: timeouts };
      // RCP has no body cap option: cancel once received bytes pass the remaining budget, so the
      // buffered body stays bounded like the former maxLimit (reported with its 2300063 code).
      let oversize: boolean = false;
      const handlers: rcp.HttpEventsHandler = {
        onDownloadProgress: (_total: number, transferred: number): void => {
          const session: rcp.Session | undefined = scope.request;
          if (oversize || transferred <= remaining || session === undefined) { return; }
          oversize = true;
          try { session.cancel(); } catch (_) {
            // The settled fetch below still reports this hop; the post-response bound remains.
          }
        }
      };
      const tracing: rcp.TracingConfiguration = { verbose: false, httpEventsHandler: handlers };
      const configuration: rcp.Configuration = { transfer: transfer, tracing: tracing, proxy: currentRcpProxy() };
      const cacheControl: rcp.CacheControl = { noCache: true, noStore: true };
      const sessionConfiguration: rcp.SessionConfiguration = {
        requestConfiguration: configuration, cacheControl: cacheControl
      };
      request = rcp.createSession(sessionConfiguration);
      scope.request = request;
      const outgoing: rcp.Request = new rcp.Request(scope.currentUrl, 'GET', headers);
      // Only these local response wrappers survive a pending SDK promise. They
      // cannot mutate this client, create redirects, or destroy a later request.
      const pending: Promise<ManifestHop> = request.fetch(outgoing)
        .then((response: rcp.Response): ManifestHop => {
          const hop: ManifestHop = new ManifestHop();
          hop.response = response;
          return hop;
        }).catch((error: BusinessError): ManifestHop => {
          const hop: ManifestHop = new ManifestHop();
          hop.errorCode = oversize ? 2300063 : errorNumber(error);
          return hop;
        });
      return await Promise.race<ManifestHop>([pending, scope.stopGate]);
    } catch (error) {
      const hop: ManifestHop = new ManifestHop();
      hop.errorCode = errorNumber(error as BusinessError);
      return hop;
    } finally {
      if (request !== undefined) { this.releaseRequest(scope, request); }
    }
  }

  private async fetchChain(scope: ManifestScope, savedHeaders: Record<string, string>): Promise<ManifestFetchResult> {
    const visited: Set<string> = new Set<string>();
    visited.add(scope.currentUrl);
    let remaining: number = MANIFEST_MAX_BYTES;
    let redirects: number = 0;
    let credentials: boolean = true;
    while (this.stillLive(scope)) {
      if (remaining <= 0) { return resultOf('tooLarge', scope); }
      const hop: ManifestHop = await this.fetchHop(scope, requestHeaders(savedHeaders, credentials), remaining);
      if (!this.stillLive(scope)) { break; }
      const response: rcp.Response | undefined = hop.response;
      if (response === undefined) {
        return resultOf(hop.errorCode === 2300063 ? 'tooLarge' : 'networkError', scope, 0, hop.errorCode);
      }
      const status: number = response.statusCode;
      if (!Number.isInteger(status) || status < 100 || status > 599) { return resultOf('networkError', scope); }
      const raw: ArrayBuffer | undefined = response.body;
      if (raw !== undefined && !(raw instanceof ArrayBuffer)) { return resultOf('unsupported', scope, status); }
      const body: ArrayBuffer = raw ?? new ArrayBuffer(0);
      if (body.byteLength > remaining) { return resultOf('tooLarge', scope, status); }
      remaining -= body.byteLength;
      if (isRedirect(status)) {
        if (redirects >= MANIFEST_MAX_REDIRECTS) { return resultOf('httpError', scope, status, 2300047); }
        const location: string = redirectLocation(response.headers);
        if (location.length === 0) { return resultOf('httpError', scope, status); }
        let next: string = '';
        try {
          next = requestUrl(resolveHlsUrl(scope.currentUrl, location));
          if (url.URL.parseURL(scope.currentUrl).origin !== url.URL.parseURL(next).origin) { credentials = false; }
        } catch (_) {
          return resultOf('httpError', scope, status);
        }
        if (visited.has(next)) { return resultOf('httpError', scope, status, 2300047); }
        visited.add(next);
        redirects++;
        scope.currentUrl = next;
        continue;
      }
      if (status !== 200) { return resultOf('httpError', scope, status); }
      let text: string = '';
      try {
        const options: util.TextDecoderOptions = { fatal: true };
        const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', options);
        const decodeOptions: util.DecodeToStringOptions = { stream: false };
        text = decoder.decodeToString(new Uint8Array(body), decodeOptions);
      } catch (_) {
        return resultOf('invalidUtf8', scope, status);
      }
      if (text.length > HLS_MAX_MANIFEST_CHARS) { return resultOf('tooLarge', scope, status); }
      if (!this.stillLive(scope)) { break; }
      const result: ManifestFetchResult = resultOf('ok', scope, status);
      result.text = text;
      return result;
    }
    return scope.stopResult ?? resultOf('cancelled', scope);
  }
}
