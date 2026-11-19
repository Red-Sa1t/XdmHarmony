import { hilog } from '@kit.PerformanceAnalysisKit';
import { DownloadCreationRequest, cloneDownloadCreationRequest,
  validateDownloadCreationRequest } from '../../model/DownloadCreationRequest';
import { DownloadRecord, newDownloadRecord } from '../../model/DownloadRecord';
import { DownloadRequestContext } from '../../model/DownloadRequestContext';
import { DownloadStore } from '../db/DownloadStore';
import { DownloadManager } from './DownloadManager';
import { Config } from '../Config';
import { AdaptiveSourceDescriptor, adaptiveDownloadType, cloneAdaptiveSource } from '../../model/AdaptiveSource';

export type DownloadAddedListener = (record: DownloadRecord) => void;

/** All new downloads (Http and adaptive) share durable commit -> added -> admission ordering. No URL dedupe. */
export class DownloadCreationService {
  private static instance: DownloadCreationService | undefined = undefined;
  private admissionReady: boolean = false;
  private listeners: DownloadAddedListener[] = [];
  private pendingAdmissions: Map<string, DownloadRecord> = new Map();
  private confirming: Map<string, Promise<DownloadRecord[]>> = new Map();
  private publicationDepth: number = 0;

  static getInstance(): DownloadCreationService {
    if (DownloadCreationService.instance === undefined) {
      DownloadCreationService.instance = new DownloadCreationService();
    }
    return DownloadCreationService.instance;
  }

  subscribeAdded(listener: DownloadAddedListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unsubscribeAdded(listener: DownloadAddedListener): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  async create(request: DownloadCreationRequest): Promise<DownloadRecord> {
    const record: DownloadRecord = this.makeRecord(request);
    const startImmediately: boolean = request.startImmediately;
    if (!await DownloadStore.getInstance().add(record)) {
      throw new Error('Download could not be saved');
    }
    this.publishCommitted(record, startImmediately);
    this.drainAdmissions();
    return record;
  }

  confirmInbox(id: string, requests: DownloadCreationRequest[]): Promise<DownloadRecord[]> {
    const existing: Promise<DownloadRecord[]> | undefined = this.confirming.get(id);
    if (existing !== undefined) {
      return existing;
    }
    const pending: Promise<DownloadRecord[]> = this.promote(id, requests).finally((): void => {
      this.confirming.delete(id);
    });
    this.confirming.set(id, pending);
    return pending;
  }

  private async promote(id: string, requests: DownloadCreationRequest[]): Promise<DownloadRecord[]> {
    if (requests.length === 0) {
      throw new Error('No downloads selected');
    }
    const records: DownloadRecord[] = [];
    const starts: boolean[] = [];
    for (let i = 0; i < requests.length; i++) {
      records.push(this.makeRecord(requests[i]));
      starts.push(requests[i].startImmediately);
    }
    if (!await DownloadStore.getInstance().promoteBridgeInbox(id, records)) {
      throw new Error('Downloads could not be confirmed');
    }
    for (let i = 0; i < records.length; i++) {
      this.publishCommitted(records[i], starts[i]);
    }
    this.drainAdmissions();
    return records;
  }

  setAdmissionReady(ready: boolean): void {
    this.admissionReady = ready;
    if (ready) {
      this.drainAdmissions();
    }
  }

  /** Identity-preserving snapshot for Index hydration; callers must not mutate admission state. */
  getPendingAdmissions(): DownloadRecord[] {
    const records: DownloadRecord[] = [];
    this.pendingAdmissions.forEach((record: DownloadRecord): void => {
      records.push(record);
    });
    return records;
  }

  drainAdmissions(): void {
    const manager: DownloadManager = DownloadManager.getInstance();
    if (this.publicationDepth > 0 || !this.admissionReady || !manager.isReady()) {
      return;
    }
    const pending: DownloadRecord[] = [];
    this.pendingAdmissions.forEach((record: DownloadRecord): void => {
      pending.push(record);
    });
    for (let i = 0; i < pending.length; i++) {
      if (!this.admissionReady || !manager.isReady()) {
        return;
      }
      const record: DownloadRecord = pending[i];
      if (!this.pendingAdmissions.has(record.id)) {
        continue;
      }
      this.pendingAdmissions.delete(record.id);
      if (manager.isLive(record.id) || manager.isQueued(record.id)) {
        continue;
      }
      try {
        manager.admitNew(record);
      } catch (e) {
        // The durable task remains accepted even when immediate launch fails.
        if (!manager.isLive(record.id) && !manager.isQueued(record.id)) {
          this.pendingAdmissions.set(record.id, record);
        }
        hilog.error(0x0000, 'DownloadCreation', '%{public}s', 'admission failed; durable record retained');
      }
    }
  }

  private makeRecord(input: DownloadCreationRequest): DownloadRecord {
    if (!validateDownloadCreationRequest(input)) {
      throw new Error('Invalid download creation request');
    }
    const request: DownloadCreationRequest = cloneDownloadCreationRequest(input);
    const url: string = request.url.trim();
    const directory: string = request.targetDir.length > 0
      ? request.targetDir : Config.getInstance().getDownloadDir();
    const adaptive: AdaptiveSourceDescriptor | null = request.adaptive;
    const downloadType: string = adaptive !== null ? adaptiveDownloadType(adaptive.kind) : 'Http';
    const record: DownloadRecord = newDownloadRecord(request.name, directory, request.size, downloadType, url,
      request.startImmediately, request.authentication, request.proxy);
    record.adaptiveSource = adaptive !== null ? cloneAdaptiveSource(adaptive) : null;
    record.fileNameFetchMode = request.fetchMode;
    record.requestContext = request.contextUrl.trim() === url
      ? request.requestContext : new DownloadRequestContext();
    return record;
  }

  private publishCommitted(record: DownloadRecord, startImmediately: boolean): void {
    this.publicationDepth++;
    if (startImmediately) {
      this.pendingAdmissions.set(record.id, record);
    }
    const listeners: DownloadAddedListener[] = this.listeners.slice();
    for (let i = 0; i < listeners.length; i++) {
      try {
        listeners[i](record);
      } catch (e) {
        hilog.error(0x0000, 'DownloadCreation', '%{public}s', 'added listener failed');
      }
    }
    this.publicationDepth--;
  }
}
