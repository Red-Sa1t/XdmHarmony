/* Source: LinkRefresher.cs and LinkRefreshDialogUIController.cs.
 * One watch consumes a same-size single-source request before ordinary creation.
 * Active runs keep their run snapshot; only future runs use the committed request.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DownloadRecord } from '../../model/DownloadRecord';
import { DownloadCreationRequest } from '../../model/DownloadCreationRequest';
import { DownloadRequestContext, DownloadRequestHeaders,
  cloneDownloadRequestContext } from '../../model/DownloadRequestContext';
import { DownloadRunRequest, cloneDownloadRunRequest } from '../../model/DownloadRunRequest';
import { DownloadStore } from '../db/DownloadStore';
import { isUriValid } from '../net/HttpProtocol';
import { BridgeMessage } from './BridgeJson';
import { BridgeHeaders } from './BridgeProtocol';

export interface LinkRefreshObserver {
  onAccepted: (token: number, id: string, request: DownloadRunRequest) => void;
  onFailed?: (token: number, id: string) => void;
}

interface RefreshWatch {
  token: number;
  id: string;
  size: number;
  observer: LinkRefreshObserver;
}

class RefreshInput {
  url: string | null = null;
  size: number = 0;
  context: DownloadRequestContext = new DownloadRequestContext();
  fromMessage: boolean = false;
  responseHeaders: BridgeHeaders | null = null;
}

/** Message overload uses one case-insensitive key and strict Int64-style parsing.
 * ArkTS cannot represent integers beyond its safe range: reject rather than round-match.
 */
export function readRefreshContentLength(headers: BridgeHeaders | null): number {
  if (headers === null) {
    throw new Error('Refresh response headers missing');
  }
  let index: number = -1;
  let count: number = 0;
  for (let i = 0; i < headers.names.length; i++) {
    if (headers.names[i].toLowerCase() === 'content-length') {
      index = i;
      count++;
    }
  }
  if (count !== 1) {
    return 0;
  }
  const values: string[] = headers.values[index];
  if (values.length === 0) {
    throw new Error('Refresh content length missing');
  }
  const value: string = values[0].trim();
  if (!new RegExp('^[+-]?[0-9]+$').test(value)) {
    throw new Error('Invalid refresh content length');
  }
  const size: number = Number(value);
  if (!Number.isSafeInteger(size)) {
    throw new Error('Unsupported refresh content length');
  }
  return size;
}

export class LinkRefresher {
  private static instance: LinkRefresher | undefined = undefined;
  private watch: RefreshWatch | undefined = undefined;
  private nextToken: number = 0;
  private pending: Promise<void> | undefined = undefined;

  private constructor() {
  }

  static getInstance(): LinkRefresher {
    if (LinkRefresher.instance === undefined) {
      LinkRefresher.instance = new LinkRefresher();
    }
    return LinkRefresher.instance;
  }

  /** UI loads the target first. Status is deliberately unrestricted, as in the source UI. */
  begin(record: DownloadRecord, observer: LinkRefreshObserver): number {
    if (record.id.length === 0 || record.downloadType !== 'Http') {
      throw new Error('Unsupported refresh target');
    }
    if (!Number.isSafeInteger(this.nextToken + 1)) {
      throw new Error('Refresh session exhausted');
    }
    const token: number = ++this.nextToken;
    const watch: RefreshWatch = { token: token, id: record.id, size: record.size, observer: observer };
    this.watch = watch;
    return token;
  }

  /** Old dialog disposal cannot clear a newer watch. A started commit cannot be undone. */
  stop(token: number): void {
    if (this.watch !== undefined && this.watch.token === token) {
      this.watch = undefined;
    }
  }

  async tryAcceptMessage(message: BridgeMessage): Promise<boolean> {
    if (this.watch === undefined) {
      return false;
    }
    const input: RefreshInput = new RefreshInput();
    input.url = message.url;
    input.fromMessage = true;
    const context: DownloadRequestContext = new DownloadRequestContext();
    context.cookies = message.cookies;
    if (message.requestHeaders !== null) {
      const headers: DownloadRequestHeaders = { names: message.requestHeaders.names.slice(), values: [] };
      for (let i = 0; i < message.requestHeaders.values.length; i++) {
        headers.values.push(message.requestHeaders.values[i].slice());
      }
      context.headers = headers;
    }
    input.context = context;
    if (message.responseHeaders !== null) {
      const headers: BridgeHeaders = { names: message.responseHeaders.names.slice(), values: [] };
      for (let i = 0; i < message.responseHeaders.values.length; i++) {
        headers.values.push(message.responseHeaders.values[i].slice());
      }
      input.responseHeaders = headers;
    }
    return await this.accept(input);
  }

  /** Caller only passes ordinary single-source video; adaptive display sizes are not transport info. */
  async tryAcceptSingleSource(request: DownloadCreationRequest): Promise<boolean> {
    if (this.watch === undefined) {
      return false;
    }
    const input: RefreshInput = new RefreshInput();
    input.url = request.url;
    input.size = request.size;
    input.context = cloneDownloadRequestContext(request.requestContext);
    return await this.accept(input);
  }

  private async accept(input: RefreshInput): Promise<boolean> {
    // Recheck after each predecessor: another awakened request may already have claimed the gate.
    while (this.pending !== undefined) {
      await this.pending;
    }
    const watch: RefreshWatch | undefined = this.watch;
    if (watch === undefined) {
      return false;
    }
    let finish: () => void = (): void => {};
    // Own the gate even during validation: a failure observer may reenter with another request.
    this.pending = new Promise<void>((resolve: () => void): void => { finish = resolve; });
    try {
      const size: number = input.fromMessage ? readRefreshContentLength(input.responseHeaders) : input.size;
      if (!Number.isSafeInteger(watch.size) || watch.size <= 0 ||
        !Number.isSafeInteger(size) || size !== watch.size) {
        return false;
      }
      if (input.url === null || !isUriValid(input.url)) {
        throw new Error('Invalid refresh URL');
      }
      // Claim synchronously, before the first persistence await. Stop only detaches this session's UI.
      const committed: DownloadRunRequest | null = await DownloadStore.getInstance()
        .refreshCommittedRequest(watch.id, input.url.trim(), input.context);
      if (committed === null) {
        throw new Error('Refresh request could not be saved');
      }
      if (this.watch !== undefined && this.watch.token === watch.token) {
        this.watch = undefined;
        this.notifyAccepted(watch, committed);
      }
      return true;
    } catch (e) {
      this.notifyFailed(watch);
      // Matching failure must not fall through to ordinary task creation.
      throw e as Error;
    } finally {
      this.pending = undefined;
      finish();
    }
  }

  private notifyAccepted(watch: RefreshWatch, request: DownloadRunRequest): void {
    try {
      watch.observer.onAccepted(watch.token, watch.id, cloneDownloadRunRequest(request));
    } catch (e) {
      hilog.error(0x0000, 'LinkRefresher', '%{public}s', 'refresh accepted observer failed');
    }
  }

  private notifyFailed(watch: RefreshWatch): void {
    if (this.watch === undefined || this.watch.token !== watch.token) {
      return;
    }
    try {
      const callback: ((token: number, id: string) => void) | undefined = watch.observer.onFailed;
      if (callback !== undefined) {
        callback(watch.token, watch.id);
      }
    } catch (e) {
      hilog.error(0x0000, 'LinkRefresher', '%{public}s', 'refresh failure observer failed');
    }
  }
}
