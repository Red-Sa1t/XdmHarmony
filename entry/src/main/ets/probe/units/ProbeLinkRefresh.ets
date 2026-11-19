/* P6-U3: production LinkRefresher + HarmonyOS RDB observations.
 * Each step owns disposable UUID rows. No downloads or browser windows are started.
 * Network/ACK/active scheduler and cross-process acceptance are separate checks.
 */
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ProbeKit, KeyValue } from '../core/ProbeKit';
import { ProbePage, ProbeStepDef } from '../core/ProbePage';
import { DownloadRecord, newDownloadRecord } from '../../model/DownloadRecord';
import { DownloadRequestContext, DownloadRequestHeaders } from '../../model/DownloadRequestContext';
import { DownloadRunRequest } from '../../model/DownloadRunRequest';
import { DownloadStore } from '../../core/db/DownloadStore';
import { resolveRunRequest } from '../../core/engine/DownloadRequestState';
import { LinkRefresher, LinkRefreshObserver } from '../../core/bridge/LinkRefresher';
import { BridgeMessage } from '../../core/bridge/BridgeJson';
import { BridgeHeaders } from '../../core/bridge/BridgeProtocol';

const REFRESH_STEPS: ProbeStepDef[] = [
  { stepNo: 'S1', title: '刷新读回与请求快照隔离', autoRun: true },
  { stepNo: 'S2', title: '旧版本整行写入冲突', autoRun: true },
  { stepNo: 'S3', title: '提交期间停止与重开', autoRun: true },
  { stepNo: 'S4', title: '非法地址与删除目标', autoRun: true }
];

class RefreshCounts {
  accepted: number = 0;
  failed: number = 0;
}

function probeUrl(label: string): string {
  return 'https://example.invalid/probe-link-refresh/' + label;
}

function probeContext(label: string): DownloadRequestContext {
  const context: DownloadRequestContext = new DownloadRequestContext();
  const headers: DownloadRequestHeaders = {
    names: ['Referer', 'X-Probe'], values: [[probeUrl('page-' + label)], ['one', 'two']]
  };
  context.headers = headers;
  context.cookies = 'probe=' + label;
  return context;
}

function probeMessage(label: string, size: number): BridgeMessage {
  const requestHeaders: BridgeHeaders = {
    names: ['Referer', 'X-Probe'], values: [[probeUrl('page-' + label)], ['one', 'two']]
  };
  const responseHeaders: BridgeHeaders = { names: ['cOnTeNt-LeNgTh'], values: [[String(size)]] };
  const message: BridgeMessage = {
    url: probeUrl(label), method: 'GET', requestHeaders: requestHeaders, responseHeaders: responseHeaders,
    cookies: 'probe=' + label, file: label + '.bin', tabUrl: null, tabId: null, mediaSourceUrl: null
  };
  return message;
}

/** One step owns all of its resources even when the page goes away during an await. */
class RefreshProbeSession {
  private context: common.Context;
  private runId: string;
  private kit: ProbeKit = ProbeKit.getInstance();
  private store: DownloadStore = DownloadStore.getInstance();
  private service: LinkRefresher = LinkRefresher.getInstance();
  private ids: string[] = [];
  private tokens: number[] = [];
  private cancelled: boolean = false;

  constructor(context: common.Context, runId: string) {
    this.context = context;
    this.runId = runId;
  }

  cancel(): void {
    this.cancelled = true;
    for (let i = 0; i < this.tokens.length; i++) { this.service.stop(this.tokens[i]); }
  }

  async cleanup(): Promise<boolean> {
    this.cancel();
    let removed: boolean = true;
    for (let i = 0; i < this.ids.length; i++) {
      if (!await this.store.remove(this.ids[i])) { removed = false; }
    }
    return removed;
  }

  private checkCurrent(): void {
    if (this.cancelled || !this.kit.isCurrent(this.runId)) { throw new Error('Probe session ended'); }
  }

  async execute(step: string): Promise<KeyValue[]> {
    await this.store.initialize(this.context);
    this.checkCurrent();
    if (step === 'S1') { return await this.roundTrip(); }
    if (step === 'S2') { return await this.staleWrite(); }
    if (step === 'S3') { return await this.replaceDuringCommit(); }
    if (step === 'S4') { return await this.invalidAndDeleted(); }
    throw new Error('Unknown refresh probe step');
  }

  private async create(label: string): Promise<DownloadRecord> {
    this.checkCurrent();
    const record: DownloadRecord = newDownloadRecord('probe-P6-U3-' + label + '.bin',
      this.context.filesDir, 16384, 'Http', probeUrl('old-' + label), false, null, null);
    record.progress = 37;
    record.requestContext = probeContext('old');
    this.ids.push(record.id);
    const added: boolean = await this.store.add(record);
    this.checkCurrent();
    if (!added) { throw new Error('Probe row could not be created'); }
    return record;
  }

  private watch(record: DownloadRecord, counts: RefreshCounts): number {
    this.checkCurrent();
    const observer: LinkRefreshObserver = {
      onAccepted: (token: number, id: string, request: DownloadRunRequest): void => { counts.accepted++; },
      onFailed: (token: number, id: string): void => { counts.failed++; }
    };
    const token: number = this.service.begin(record, observer);
    this.tokens.push(token);
    return token;
  }

  private async read(id: string): Promise<DownloadRecord> {
    const record: DownloadRecord | null = await this.store.getDownloadById(id);
    this.checkCurrent();
    if (record === null) { throw new Error('Probe row could not be read'); }
    return record;
  }

  private async roundTrip(): Promise<KeyValue[]> {
    const record: DownloadRecord = await this.create('roundtrip');
    this.checkCurrent();
    const oldSnapshot: DownloadRunRequest = resolveRunRequest(record);
    const counts: RefreshCounts = new RefreshCounts();
    this.watch(record, counts);
    const mismatch: boolean = await this.service.tryAcceptMessage(probeMessage('different-size', record.size + 1));
    this.checkCurrent();
    const message: BridgeMessage = probeMessage('fresh', record.size);
    const pending: Promise<boolean> = this.service.tryAcceptMessage(message);
    message.cookies = 'probe=mutated';
    if (message.requestHeaders !== null) { message.requestHeaders.values[0][0] = probeUrl('mutated'); }
    const accepted: boolean = await pending;
    this.checkCurrent();
    const saved: DownloadRecord = await this.read(record.id);
    this.checkCurrent();
    const nextSnapshot: DownloadRunRequest = resolveRunRequest(record);
    const savedHeaders: DownloadRequestHeaders | null = saved.requestContext.headers;
    const oldHeaders: DownloadRequestHeaders | null = oldSnapshot.context.headers;
    const nextHeaders: DownloadRequestHeaders | null = nextSnapshot.context.headers;
    return [new KeyValue('accepted', String(accepted)), new KeyValue('mismatchConsumed', String(mismatch)),
      new KeyValue('revision', String(saved.requestRevision)),
      new KeyValue('urlFresh', String(saved.primaryUrl === probeUrl('fresh'))),
      new KeyValue('contextFresh', String(saved.requestContext.cookies === 'probe=fresh' &&
        savedHeaders !== null && savedHeaders.values[0][0] === probeUrl('page-fresh'))),
      new KeyValue('multiValues', savedHeaders === null ? 'missing' : savedHeaders.values[1].join('/')),
      new KeyValue('metadataKept', String(saved.name === record.name && saved.size === record.size &&
        saved.progress === record.progress && saved.status === record.status)),
      new KeyValue('oldRevision', String(oldSnapshot.revision)),
      new KeyValue('nextRevision', String(nextSnapshot.revision)),
      new KeyValue('oldSnapshotKept', String(oldSnapshot.url === probeUrl('old-roundtrip') &&
        oldSnapshot.context.cookies === 'probe=old' && oldHeaders !== null &&
        oldHeaders.values[0][0] === probeUrl('page-old') && oldHeaders.values[1].join('/') === 'one/two')),
      new KeyValue('nextSnapshotFresh', String(nextSnapshot.url === probeUrl('fresh') &&
        nextSnapshot.context.cookies === 'probe=fresh' && nextHeaders !== null &&
        nextHeaders.values[0][0] === probeUrl('page-fresh') && nextHeaders.values[1].join('/') === 'one/two')),
      new KeyValue('notifications', String(counts.accepted))];
  }

  private async staleWrite(): Promise<KeyValue[]> {
    const stale: DownloadRecord = await this.create('cas');
    this.checkCurrent();
    const committed: DownloadRunRequest | null = await this.store.refreshCommittedRequest(stale.id,
      probeUrl('cas-fresh'), probeContext('fresh'));
    this.checkCurrent();
    if (committed === null) { throw new Error('Probe refresh did not commit'); }
    stale.name = 'obsolete-name.bin';
    const wrote: boolean = await this.store.updateDownloadEntry(stale);
    this.checkCurrent();
    const saved: DownloadRecord = await this.read(stale.id);
    this.checkCurrent();
    return [new KeyValue('staleWriteAccepted', String(wrote)),
      new KeyValue('revision', String(saved.requestRevision)),
      new KeyValue('urlFresh', String(saved.primaryUrl === probeUrl('cas-fresh'))),
      new KeyValue('cookieFresh', String(saved.requestContext.cookies === 'probe=fresh')),
      new KeyValue('nameKept', String(saved.name === 'probe-P6-U3-cas.bin')),
      new KeyValue('resolvedRevision', String(resolveRunRequest(stale).revision))];
  }

  private async replaceDuringCommit(): Promise<KeyValue[]> {
    const first: DownloadRecord = await this.create('first');
    this.checkCurrent();
    const second: DownloadRecord = await this.create('second');
    this.checkCurrent();
    const oldCounts: RefreshCounts = new RefreshCounts();
    const newCounts: RefreshCounts = new RefreshCounts();
    const oldToken: number = this.watch(first, oldCounts);
    const pending: Promise<boolean> = this.service.tryAcceptMessage(probeMessage('old-commit', first.size));
    this.service.stop(oldToken);
    this.watch(second, newCounts);
    this.service.stop(oldToken);
    const oldConsumed: boolean = await pending;
    this.checkCurrent();
    const newConsumed: boolean = await this.service.tryAcceptMessage(probeMessage('new-commit', second.size));
    this.checkCurrent();
    const savedFirst: DownloadRecord = await this.read(first.id);
    this.checkCurrent();
    const savedSecond: DownloadRecord = await this.read(second.id);
    this.checkCurrent();
    return [new KeyValue('oldConsumed', String(oldConsumed)), new KeyValue('newConsumed', String(newConsumed)),
      new KeyValue('oldNotifications', String(oldCounts.accepted)),
      new KeyValue('newNotifications', String(newCounts.accepted)),
      new KeyValue('oldCommitted', String(savedFirst.primaryUrl === probeUrl('old-commit'))),
      new KeyValue('newCommitted', String(savedSecond.primaryUrl === probeUrl('new-commit')))];
  }

  private async invalidAndDeleted(): Promise<KeyValue[]> {
    const record: DownloadRecord = await this.create('invalid');
    this.checkCurrent();
    const counts: RefreshCounts = new RefreshCounts();
    this.watch(record, counts);
    const invalid: BridgeMessage = probeMessage('invalid', record.size);
    invalid.url = 'file:///probe-invalid';
    let invalidRejected: boolean = false;
    try { await this.service.tryAcceptMessage(invalid); } catch (e) { invalidRejected = true; }
    this.checkCurrent();
    const retryConsumed: boolean = await this.service.tryAcceptMessage(probeMessage('retry', record.size));
    this.checkCurrent();
    const removed: boolean = await this.store.remove(record.id);
    this.checkCurrent();
    this.watch(record, counts);
    let deletedRejected: boolean = false;
    try { await this.service.tryAcceptMessage(probeMessage('deleted', record.size)); }
    catch (e) { deletedRejected = true; }
    this.checkCurrent();
    const missing: DownloadRecord | null = await this.store.getDownloadById(record.id);
    this.checkCurrent();
    let tombstoned: boolean = false;
    try { resolveRunRequest(record); } catch (e) { tombstoned = true; }
    return [new KeyValue('invalidRejected', String(invalidRejected)),
      new KeyValue('retryConsumed', String(retryConsumed)), new KeyValue('removed', String(removed)),
      new KeyValue('deletedRejected', String(deletedRejected)), new KeyValue('rowAbsent', String(missing === null)),
      new KeyValue('tombstoned', String(tombstoned)), new KeyValue('acceptedEvents', String(counts.accepted)),
      new KeyValue('failedEvents', String(counts.failed))];
  }
}

@Component
export struct ProbeLinkRefresh {
  private activeSession: RefreshProbeSession | undefined = undefined;
  private alive: boolean = false;

  aboutToAppear(): void { this.alive = true; }

  aboutToDisappear(): void {
    this.alive = false;
    this.activeSession?.cancel();
  }

  private async runStep(step: string): Promise<void> {
    if (!this.alive) { return; }
    const kit: ProbeKit = ProbeKit.getInstance();
    const runId: string = kit.getSessionToken();
    const context = this.getUIContext().getHostContext();
    if (context === undefined) { throw new Error('Probe context unavailable'); }
    const session: RefreshProbeSession = new RefreshProbeSession(context, runId);
    this.activeSession = session;
    let values: KeyValue[] = [];
    try {
      values = await session.execute(step);
    } catch (e) {
      const error = e as BusinessError;
      values = [new KeyValue('errCode', String(error.code ?? -1)), new KeyValue('errMessage', error.message ?? '')];
    } finally {
      const cleanup: boolean = await session.cleanup();
      values.push(new KeyValue('cleanup', String(cleanup)));
      if (this.activeSession === session) { this.activeSession = undefined; }
    }
    if (this.alive && kit.isCurrent(runId)) { kit.emit(step, values); }
  }

  build() {
    ProbePage({
      unitId: 'P6-U3', pageTitle: $r('app.string.probe_p6u3_title'), steps: REFRESH_STEPS,
      autoStart: true, runStep: (step: string): Promise<void> => this.runStep(step)
    })
  }
}
