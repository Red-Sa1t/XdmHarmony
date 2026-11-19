import { AuthenticationInfo, ProxyInfo, FileNameFetchMode } from './DownloadTypes';
import { DownloadRequestContext, cloneDownloadRequestContext, parseDownloadRequestContext,
  serializeDownloadRequestContext } from './DownloadRequestContext';
import { isUriValid } from '../core/net/HttpProtocol';
import { AdaptiveSourceDescriptor, cloneAdaptiveSource, validateAdaptiveSource } from './AdaptiveSource';

/** Detached creation input; captured credentials are bound to contextUrl, not arbitrary UI edits. */
export class DownloadCreationRequest {
  url: string = '';
  name: string = '';
  size: number = 0;
  targetDir: string = '';
  fetchMode: number = FileNameFetchMode.FileNameAndExtension;
  startImmediately: boolean = true;
  authentication: AuthenticationInfo | null = null;
  proxy: ProxyInfo | null = null;
  requestContext: DownloadRequestContext = new DownloadRequestContext();
  contextUrl: string = '';
  /** Non-null only for HLS/DASH/dual-source captures; selects the adaptive downloader. */
  adaptive: AdaptiveSourceDescriptor | null = null;
}

export class BridgeInboxItem {
  id: string = '';
  kind: string = 'download';
  createdAt: number = 0;
  requests: DownloadCreationRequest[] = [];
  videoKind: string = '';
  videoId: string = '';
}

interface InboxDocument {
  schema: number;
  item: BridgeInboxItem;
}

export function cloneDownloadCreationRequest(request: DownloadCreationRequest): DownloadCreationRequest {
  const result: DownloadCreationRequest = new DownloadCreationRequest();
  result.url = request.url;
  result.name = request.name;
  result.size = request.size;
  result.targetDir = request.targetDir;
  result.fetchMode = request.fetchMode;
  result.startImmediately = request.startImmediately;
  result.contextUrl = request.contextUrl;
  result.requestContext = cloneDownloadRequestContext(request.requestContext);
  // Older inbox payloads predate the field; treat absence as an ordinary HTTP request.
  const adaptive: AdaptiveSourceDescriptor | null | undefined = request.adaptive;
  result.adaptive = adaptive === undefined || adaptive === null ? null : cloneAdaptiveSource(adaptive);
  if (request.authentication !== null) {
    result.authentication = { userName: request.authentication.userName, password: request.authentication.password };
  }
  if (request.proxy !== null) {
    result.proxy = { proxyType: request.proxy.proxyType, host: request.proxy.host, port: request.proxy.port,
      userName: request.proxy.userName, password: request.proxy.password };
  }
  return result;
}

export function cloneBridgeInboxItem(item: BridgeInboxItem): BridgeInboxItem {
  const result: BridgeInboxItem = new BridgeInboxItem();
  result.id = item.id;
  result.kind = item.kind;
  result.createdAt = item.createdAt;
  result.videoKind = item.videoKind;
  result.videoId = item.videoId;
  for (let i = 0; i < item.requests.length; i++) {
    result.requests.push(cloneDownloadCreationRequest(item.requests[i]));
  }
  return result;
}

export function validateDownloadCreationRequest(request: DownloadCreationRequest): boolean {
  if (request === null || typeof request !== 'object' || typeof request.url !== 'string' ||
    !isUriValid(request.url) || typeof request.name !== 'string' || typeof request.targetDir !== 'string' ||
    typeof request.contextUrl !== 'string' || typeof request.size !== 'number' || !Number.isFinite(request.size) ||
    request.size < -1 || typeof request.startImmediately !== 'boolean' ||
    !Number.isInteger(request.fetchMode) || request.fetchMode < 0 || request.fetchMode > 2) {
    return false;
  }
  const adaptive: AdaptiveSourceDescriptor | null | undefined = request.adaptive;
  if (adaptive !== undefined && adaptive !== null && !validateAdaptiveSource(adaptive)) {
    return false;
  }
  const auth: AuthenticationInfo | null = request.authentication;
  if (auth !== null && (typeof auth !== 'object' || typeof auth.userName !== 'string' || !nullableText(auth.password))) {
    return false;
  }
  const proxy: ProxyInfo | null = request.proxy;
  if (proxy !== null && (typeof proxy !== 'object' || !Number.isInteger(proxy.proxyType) || proxy.proxyType < 0 ||
    proxy.proxyType > 2 || !Number.isInteger(proxy.port) || proxy.port < 0 || proxy.port > 65535 ||
    !nullableText(proxy.host) || !nullableText(proxy.userName) || !nullableText(proxy.password))) {
    return false;
  }
  try {
    serializeDownloadRequestContext(request.requestContext);
    return true;
  } catch (e) {
    return false;
  }
}

export function serializeBridgeInboxItem(item: BridgeInboxItem): string {
  const doc: InboxDocument = { schema: 1, item: item };
  const text: string = JSON.stringify(doc);
  if (parseBridgeInboxItem(text) === null) {
    throw new Error('Invalid bridge inbox item');
  }
  return text;
}

export function parseBridgeInboxItem(text: string): BridgeInboxItem | null {
  try {
    const parsed: Object | null = JSON.parse(text);
    if (parsed === null || typeof parsed !== 'object') {
      return null;
    }
    const doc: InboxDocument = parsed as InboxDocument;
    const item: BridgeInboxItem = doc.item;
    if (doc.schema !== 1 || item === null || typeof item !== 'object' || typeof item.id !== 'string' ||
      item.id.length === 0 || (item.kind !== 'download' && item.kind !== 'batch' && item.kind !== 'video') ||
      !Number.isSafeInteger(item.createdAt) || item.createdAt < 0 || !Array.isArray(item.requests) ||
      item.requests.length === 0 || typeof item.videoKind !== 'string' || typeof item.videoId !== 'string') {
      return null;
    }
    for (let i = 0; i < item.requests.length; i++) {
      const request: DownloadCreationRequest = item.requests[i];
      if (!validateDownloadCreationRequest(request)) {
        return null;
      }
      // Materialize a new class tree; external JSON is never shared with live UI state.
      const context: DownloadRequestContext | null = parseDownloadRequestContext(
        serializeDownloadRequestContext(request.requestContext));
      if (context === null) {
        return null;
      }
      request.requestContext = context;
    }
    return cloneBridgeInboxItem(item);
  } catch (e) {
    return null;
  }
}

function nullableText(value: string | null): boolean {
  return value === null || typeof value === 'string';
}
