import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BridgeInboxItem, DownloadCreationRequest, cloneBridgeInboxItem,
  cloneDownloadCreationRequest, serializeBridgeInboxItem } from '../../model/DownloadCreationRequest';
import { DownloadRecord } from '../../model/DownloadRecord';
import { AdaptiveSourceDescriptor, cloneAdaptiveSource } from '../../model/AdaptiveSource';
import { DownloadStore } from '../db/DownloadStore';
import { DownloadCreationService } from '../engine/DownloadCreationService';

export type BridgeInboxChangedListener = () => void;

/** Durable queue is authoritative; notifications never constitute a second consumable queue. */
export class BridgeInbox {
  private static instance: BridgeInbox | undefined = undefined;
  private ready: Promise<void> | undefined = undefined;
  private items: BridgeInboxItem[] = [];
  private claimedId: string = '';
  private listeners: BridgeInboxChangedListener[] = [];
  private confirming: Map<string, Promise<DownloadRecord[]>> = new Map();
  private canceling: Map<string, Promise<void>> = new Map();
  private deferredReleases: Set<string> = new Set();

  static getInstance(): BridgeInbox {
    if (BridgeInbox.instance === undefined) {
      BridgeInbox.instance = new BridgeInbox();
    }
    return BridgeInbox.instance;
  }

  initialize(): Promise<void> {
    if (this.ready === undefined) {
      this.ready = this.load().catch((e: Error): void => {
        this.ready = undefined;
        throw new Error('Bridge inbox unavailable');
      });
    }
    return this.ready;
  }

  private async load(): Promise<void> {
    this.items = await DownloadStore.getInstance().queryBridgeInbox();
    this.notify();
  }

  async enqueue(input: BridgeInboxItem): Promise<BridgeInboxItem> {
    const item: BridgeInboxItem = cloneBridgeInboxItem(input);
    if (item.id.length === 0) {
      item.id = util.generateRandomUUID();
    }
    if (item.createdAt === 0) {
      item.createdAt = Date.now();
    }
    serializeBridgeInboxItem(item);
    await this.initialize();
    if (!await DownloadStore.getInstance().saveBridgeInbox(item)) {
      throw new Error('Bridge request could not be saved');
    }
    this.items.push(item);
    this.notify();
    return cloneBridgeInboxItem(item);
  }

  getPending(): BridgeInboxItem[] {
    return this.items.map((item: BridgeInboxItem): BridgeInboxItem => cloneBridgeInboxItem(item));
  }

  peekNext(): BridgeInboxItem | null {
    if (this.claimedId.length > 0) {
      return null;
    }
    return this.items.length > 0 ? cloneBridgeInboxItem(this.items[0]) : null;
  }

  claim(id: string): boolean {
    if (this.claimedId.length > 0 || !this.items.some((item: BridgeInboxItem): boolean => item.id === id)) {
      return false;
    }
    this.claimedId = id;
    return true;
  }

  release(id: string): void {
    if (this.claimedId !== id) {
      return;
    }
    if (this.confirming.has(id) || this.canceling.has(id)) {
      this.deferredReleases.add(id);
      return;
    }
    this.claimedId = '';
    this.notify();
  }

  confirm(id: string, requests: DownloadCreationRequest[]): Promise<DownloadRecord[]> {
    const existing: Promise<DownloadRecord[]> | undefined = this.confirming.get(id);
    if (existing !== undefined) {
      return existing;
    }
    if (this.canceling.has(id)) {
      return Promise.reject<DownloadRecord[]>(new Error('Bridge request is being canceled'));
    }
    const pending: Promise<DownloadRecord[]> = this.finishConfirm(id, requests).finally((): void => {
      this.confirming.delete(id);
      this.applyDeferredRelease(id);
    });
    this.confirming.set(id, pending);
    return pending;
  }

  private async finishConfirm(id: string, requests: DownloadCreationRequest[]): Promise<DownloadRecord[]> {
    const detached: DownloadCreationRequest[] = requests.map((request: DownloadCreationRequest): DownloadCreationRequest =>
      cloneDownloadCreationRequest(request));
    await this.initialize();
    const item: BridgeInboxItem | undefined = this.items.find((entry: BridgeInboxItem): boolean => entry.id === id);
    if (item === undefined) {
      throw new Error('Bridge request is unavailable');
    }
    if (item.kind === 'video' && item.videoKind !== 'video') {
      // Adaptive media is created only from the descriptor captured with the inbox item; a caller
      // cannot substitute another source or downgrade the item to an ordinary HTTP download.
      const captured: AdaptiveSourceDescriptor | null = item.requests.length === 1 ? item.requests[0].adaptive : null;
      if (captured === null || detached.length !== 1) {
        throw new Error('This video download requires an unavailable media engine');
      }
      detached[0].adaptive = cloneAdaptiveSource(captured);
    }
    const records: DownloadRecord[] = await DownloadCreationService.getInstance().confirmInbox(id, detached);
    this.removeLocal(id);
    return records;
  }

  cancel(id: string): Promise<void> {
    const existing: Promise<void> | undefined = this.canceling.get(id);
    if (existing !== undefined) {
      return existing;
    }
    if (this.confirming.has(id)) {
      return Promise.reject<void>(new Error('Bridge request is being confirmed'));
    }
    const pending: Promise<void> = this.finishCancel(id).finally((): void => {
      this.canceling.delete(id);
      this.applyDeferredRelease(id);
    });
    this.canceling.set(id, pending);
    return pending;
  }

  private async finishCancel(id: string): Promise<void> {
    await this.initialize();
    if (!await DownloadStore.getInstance().removeBridgeInbox(id)) {
      throw new Error('Bridge request could not be canceled');
    }
    this.removeLocal(id);
  }

  subscribeChanged(listener: BridgeInboxChangedListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unsubscribeChanged(listener: BridgeInboxChangedListener): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  private removeLocal(id: string): void {
    this.items = this.items.filter((item: BridgeInboxItem): boolean => item.id !== id);
    if (this.claimedId === id) {
      this.claimedId = '';
    }
    this.notify();
  }

  private applyDeferredRelease(id: string): void {
    if (this.deferredReleases.has(id) && !this.confirming.has(id) && !this.canceling.has(id)) {
      this.deferredReleases.delete(id);
      if (this.claimedId === id) {
        this.claimedId = '';
        this.notify();
      }
    }
  }

  private notify(): void {
    const listeners: BridgeInboxChangedListener[] = this.listeners.slice();
    for (let i = 0; i < listeners.length; i++) {
      try {
        listeners[i]();
      } catch (e) {
        hilog.error(0x0000, 'BridgeInbox', '%{public}s', 'inbox listener failed');
      }
    }
  }
}
