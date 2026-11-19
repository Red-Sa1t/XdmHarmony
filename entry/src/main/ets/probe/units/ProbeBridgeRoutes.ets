/*
 * U6.1 探针单元：P6-U1 扩展桥八路由完整版探针（设计书 §6 步骤表，autoStart=true 全自动 S1~S9）。
 * S1 就绪+/clear 基线 → S2 /media 嗅探→videoList 增长 → S3 /tab-update 回写 → S4 /vid 未命中/
 *    命中 → S5 /download 对话框事件+头剥离观测 → S6 /args 参数链（--media-tab-url 组 + --url
 *    --media 组）→ S7 /link pending → S8 错误处理三谓词（未知路径/坏 JSON/缺 vid——连接关闭且
 *    无完整应答头块=静默断连观测）→ S9 最终 /sync 全量。
 * 监听器：tracker（mediaAdded/mediaUpdated 计数）与 BridgeUiEvents（videoDialog/
 *    newDownloadDialog/batch 事件袋 + 对话框携带的 BridgeMessage 头剥离观测）在组件挂载即注册
 *    （BEGIN 后、S1 前计数从 0 起，设计书 §6 前置），卸载注销。
 * 观测红线：布尔键均为直接观测谓词（closed/status/计数/首尾匹配），不含通过/失败判定词；
 *    期望只在 EXPECT-u6-1-bridge-eight-routes.json。值白名单预转换：'['/']' 不在白名单，
 *    mediaInfoPrefix 取 description 首段括号内 token；含逗号值经 commasToSlash（P0-U3 同款）。
 * 会话代际守卫：每个 runner 入口捕获 runId，每个 await 之后、emit 之前复检 isCurrent，不一致
 *    静默 return（U0.2 §3.5 惯例）。自连客户端复用 ProbeBridgeNet（P0-U3 提炼件）。
 */

import { BusinessError } from '@kit.BasicServicesKit';
import { ProbeKit, KeyValue } from '../core/ProbeKit';
import { ProbePage, ProbeStepDef } from '../core/ProbePage';
import { BridgeServer, BridgeStats } from '../../core/bridge/BridgeServer';
import { BridgeVideoItem } from '../../core/bridge/BridgeProtocol';
import { BridgeMessage, headerValueFirst } from '../../core/bridge/BridgeJson';
import { CapturedVideoTracker, TrackerListener } from '../../core/bridge/CapturedVideoTracker';
import {
  BridgeUiEvents, registerBridgeUiEvents, unregisterBridgeUiEvents, getPendingBatchLinks,
  PendingBatchLink
} from '../../core/bridge/BridgeActions';
import {
  ProbeTcpClient, postJsonRequest, getRequest, decodeBody
} from './ProbeBridgeNet';
import { ResponseHeadView, SyncBodyView, splitResponseHead, parseSyncBody } from './ProbeBridgeLogic';

/** P6-U1 步骤定义表（S1~S9 全自动） */
const ROUTES_STEPS: ProbeStepDef[] = [
  { stepNo: 'S1', title: '就绪+/clear 清空基线', autoRun: true },
  { stepNo: 'S2', title: '/media 嗅探→列表增长', autoRun: true },
  { stepNo: 'S3', title: '/tab-update 标题回写', autoRun: true },
  { stepNo: 'S4', title: '/vid 未命中/命中', autoRun: true },
  { stepNo: 'S5', title: '/download 接管+头剥离观测', autoRun: true },
  { stepNo: 'S6', title: '/args 参数链', autoRun: true },
  { stepNo: 'S7', title: '/link 兼容路由', autoRun: true },
  { stepNo: 'S8', title: '错误处理三谓词', autoRun: true },
  { stepNo: 'S9', title: '最终 /sync 全量', autoRun: true }
];

/** Connection: close 后等服务端 FIN 的宽限期（S8 断连谓词观测窗口） */
const CLOSE_GRACE_MS: number = 1500;

/** S2 /media 样例体（request-watcher.js:150-189 形：file 键+tabUrl/tabId/method） */
const MEDIA_BODY: string = '{"url":"https://media.example.com/v/clip.mp4","file":"Test Clip",' +
  '"method":"GET","tabId":"100","tabUrl":"https://www.youtube.com/watch?v=abc","cookie":"a=b",' +
  '"requestHeaders":{"Referer":["https://media.example.com/page"],"User-Agent":["ProbeUA"]},' +
  '"responseHeaders":{"Content-Type":["video/mp4"],"Content-Length":["5242880"]}}';
/** S3 /tab-update 样例体（app.js:105-108 形） */
const TAB_UPDATE_BODY: string = '{"tabUrl":"https://www.youtube.com/watch?v=abc",' +
  '"tabTitle":"New Title"}';
/** S4 /vid 未命中样例体（app.js:273-275 形） */
const VID_MISS_BODY: string = '{"vid":"nonexistent-vid"}';
/** S5 /download 样例体（chrome app.js:229-239 形：键名 filename 不带 method/tabUrl；
 *  Content-Length 发 number 形=真实契约 fz=+size，R2-F1 回归观测点） */
const DOWNLOAD_BODY: string = '{"url":"https://dl.example.com/setup.exe","cookie":"sid=1",' +
  '"requestHeaders":{"User-Agent":["ChromeUA"],"Cookie":["sid=1"],"Accept":["text/html"],' +
  '"Accept-Encoding":["gzip"]},"responseHeaders":{"Content-Length":[2048000],' +
  '"Content-Type":["application/octet-stream"]},"filename":"setup.exe","fileSize":2048000,' +
  '"mimeType":"application/octet-stream"}';
/** S6 /args 两组（ArgsProcessor 文法：xdm+app:// 前缀跳过 + --url 名值链） */
const ARGS_TAB_BODY: string = '["xdm+app://x","--media-tab-url",' +
  '"https://www.youtube.com/watch?v=abc","--media-tab-title","Args Title"]';
const ARGS_MEDIA_BODY: string = '["--url","https://h/v/args.mp4","--media",' +
  '"--known-mime-type","video/mp4","--known-file-size","2097152"]';
/** S7 /link 样例体（ExtensionData 数组，第二项空 url 跳过锚；**每元素必带 requestHeaders**
 * ——buildBridgeMessage 对 null requestHeaders throw→断连（1:1 源 Select 内 RemoveBlockedHeaders
 * NRE，COLD-F1：映射先于空 url 跳过，空 url 项同样须过门）） */
const LINK_BODY: string = '[{"url":"https://h/f/pack.zip","file":"pack.zip",' +
  '"requestHeaders":{"User-Agent":["ProbeUA"]}},' +
  '{"url":"","file":"x","requestHeaders":{"User-Agent":["ProbeUA"]}}]';
/** S8 坏 JSON 体（IpcHttpMessageProcessor 坏 JSON→断连观测） */
const BAD_JSON_BODY: string = 'not json';
/** S8 缺 vid 体（ContainsKey(null)→断连 1:1 观测） */
const VID_MISSING_BODY: string = '{}';

/** 单轮往返产物（文件内私有） */
interface RoundTripResult {
  status: number;
  headComplete: boolean;
  closed: boolean;
  errCode: number;
  errMessage: string;
  bytes: Uint8Array;
}

/** videoList 观测产物（文件内私有） */
interface VideoListSummary {
  parseOk: boolean;
  count: number;
  firstText: string;
  firstId: string;
  firstInfo: string;
}

/** /sync 应答观测产物（文件内私有） */
interface SyncObservation {
  status: number;
  bodyText: string;
  fieldView: SyncBodyView;
  list: VideoListSummary;
}

@Component
export struct ProbeBridgeRoutes {
  private probeKit: ProbeKit = ProbeKit.getInstance();

  /** 事件袋计数（监听器在 aboutToAppear 注册，计数从 0 起） */
  private mediaAddedEvents: number = 0;
  private mediaUpdatedEvents: number = 0;
  private videoDialogEvents: number = 0;
  private newDownloadDialogEvents: number = 0;
  private batchEvents: number = 0;
  /** S5 对话框事件携带的 BridgeMessage（头剥离观测源） */
  private lastDialogMessage: BridgeMessage | null = null;
  /** S2 捕获的视频 id（S4 命中分支复用；跨步骤组件字段传递） */
  private capturedVid: string = '';
  /** 监听器引用（注销用） */
  private trackerListener: TrackerListener | null = null;
  private uiListener: BridgeUiEvents | null = null;

  aboutToAppear(): void {
    const tracker: TrackerListener = {
      onMediaAdded: (item: BridgeVideoItem): void => {
        this.mediaAddedEvents++;
      },
      onMediaUpdated: (item: BridgeVideoItem): void => {
        this.mediaUpdatedEvents++;
      }
    };
    this.trackerListener = tracker;
    CapturedVideoTracker.getInstance().registerTrackerListener(tracker);
    const ui: BridgeUiEvents = {
      onShowNewDownloadDialog: (msg: BridgeMessage): void => {
        this.newDownloadDialogEvents++;
        this.lastDialogMessage = msg;
      },
      onShowVideoDownloadDialog: (videoId: string, name: string, size: number,
        contentType: string): void => {
        this.videoDialogEvents++;
      },
      onShowBatchSelection: (items: PendingBatchLink[]): void => {
        this.batchEvents++;
      },
      onAppCommand: (cmd: string, argv: string[]): void => {
      }
    };
    this.uiListener = ui;
    registerBridgeUiEvents(ui);
  }

  aboutToDisappear(): void {
    const tracker: TrackerListener | null = this.trackerListener;
    if (tracker !== null) {
      CapturedVideoTracker.getInstance().unregisterTrackerListener(tracker);
      this.trackerListener = null;
    }
    const ui: BridgeUiEvents | null = this.uiListener;
    if (ui !== null) {
      unregisterBridgeUiEvents(ui);
      this.uiListener = null;
    }
  }

  /** 步骤分派：各 runner 自行捕获 runId 并过会话守卫（设计书 §3.5） */
  private async runStep(stepNo: string): Promise<void> {
    if (stepNo === 'S1') {
      await this.runS1();
      return;
    }
    if (stepNo === 'S2') {
      await this.runS2();
      return;
    }
    if (stepNo === 'S3') {
      await this.runS3();
      return;
    }
    if (stepNo === 'S4') {
      await this.runS4();
      return;
    }
    if (stepNo === 'S5') {
      await this.runS5();
      return;
    }
    if (stepNo === 'S6') {
      await this.runS6();
      return;
    }
    if (stepNo === 'S7') {
      await this.runS7();
      return;
    }
    if (stepNo === 'S8') {
      await this.runS8();
      return;
    }
    if (stepNo === 'S9') {
      await this.runS9();
      return;
    }
  }

  /** S1 就绪+/clear 清空基线：stats 快照 → POST /clear → 应答 videoList 计数。 */
  private async runS1(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const before: BridgeStats = BridgeServer.getInstance().getStats();
      await BridgeServer.getInstance().start();
      const trip: RoundTripResult = await this.roundTrip(postJsonRequest('/clear', '{}'), 0);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const sync: SyncObservation = this.observeSync(trip);
      const kvs: KeyValue[] = [
        new KeyValue('started', String(before.started)),
        new KeyValue('boundPort', String(BridgeServer.getInstance().getStats().boundPort)),
        new KeyValue('clearStatus', statusTextOf(trip)),
        new KeyValue('baseVideoCount', String(sync.list.count)),
        new KeyValue('requestsBefore', String(before.requests))
      ];
      this.emitGuarded(runId, 'S1', kvs);
    } catch (e) {
      this.emitError(runId, 'S1', e as BusinessError);
    }
  }

  /** S2 /media 嗅探→列表增长：POST /media（video/mp4+5MB）→ videoList=1、onMediaAdded=1、
   *  text 末缀 .mp4、description 首段 [MP4]；捕获 id 供 S4。 */
  private async runS2(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const trip: RoundTripResult = await this.roundTrip(postJsonRequest('/media', MEDIA_BODY), 0);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const sync: SyncObservation = this.observeSync(trip);
      if (sync.list.firstId.length > 0) {
        this.capturedVid = sync.list.firstId;
      }
      const kvs: KeyValue[] = [
        new KeyValue('mediaStatus', statusTextOf(trip)),
        new KeyValue('mediaListCount', String(sync.list.count)),
        new KeyValue('mediaTextSuffix', suffixOf(sync.list.firstText, 4)),
        new KeyValue('mediaInfoPrefix', bracketTokenOf(sync.list.firstInfo)),
        new KeyValue('mediaAddedEvents', String(this.mediaAddedEvents)),
        new KeyValue('vid', prefixOf(sync.list.firstId, 8))
      ];
      this.emitGuarded(runId, 'S2', kvs);
    } catch (e) {
      this.emitError(runId, 'S2', e as BusinessError);
    }
  }

  /** S3 /tab-update 标题回写：POST /tab-update（tabUrl 同 S2）→ text 前缀 New Title、
   *  扩展名保留、onMediaUpdated=1。 */
  private async runS3(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const trip: RoundTripResult =
        await this.roundTrip(postJsonRequest('/tab-update', TAB_UPDATE_BODY), 0);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const sync: SyncObservation = this.observeSync(trip);
      const kvs: KeyValue[] = [
        new KeyValue('tabUpdateStatus', statusTextOf(trip)),
        new KeyValue('tabTextPrefix', prefixOf(sync.list.firstText, 9)),
        new KeyValue('tabExtKept', String(sync.list.firstText.endsWith('.mp4'))),
        new KeyValue('mediaUpdatedEvents', String(this.mediaUpdatedEvents))
      ];
      this.emitGuarded(runId, 'S3', kvs);
    } catch (e) {
      this.emitError(runId, 'S3', e as BusinessError);
    }
  }

  /** S4 /vid 未命中/命中：miss（200 列表不变）→ hit（auto=false 默认→对话框事件计数）。 */
  private async runS4(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const miss: RoundTripResult =
        await this.roundTrip(postJsonRequest('/vid', VID_MISS_BODY), 0);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const missSync: SyncObservation = this.observeSync(miss);
      const hitBody: string = '{"vid":"' + this.capturedVid + '"}';
      const hit: RoundTripResult = await this.roundTrip(postJsonRequest('/vid', hitBody), 0);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const kvs: KeyValue[] = [
        new KeyValue('vidMissStatus', statusTextOf(miss)),
        new KeyValue('vidMissListCount', String(missSync.list.count)),
        new KeyValue('vidHitStatus', statusTextOf(hit)),
        new KeyValue('videoDialogEvents', String(this.videoDialogEvents))
      ];
      this.emitGuarded(runId, 'S4', kvs);
    } catch (e) {
      this.emitError(runId, 'S4', e as BusinessError);
    }
  }

  /** S5 /download 接管+头剥离观测：POST /download（chrome filename 形）→ 对话框事件携带的
   *  BridgeMessage 检查剥离结果（UA 留/Cookie 删/Accept 删/Accept-Encoding 留）。 */
  private async runS5(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const trip: RoundTripResult =
        await this.roundTrip(postJsonRequest('/download', DOWNLOAD_BODY), 0);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const msg: BridgeMessage | null = this.lastDialogMessage;
      let uaPreserved: boolean = false;
      let cookieStripped: boolean = false;
      let acceptStripped: boolean = false;
      let acceptEncodingPreserved: boolean = false;
      if (msg !== null) {
        uaPreserved = headerValueFirst(msg.requestHeaders, 'User-Agent') !== null;
        cookieStripped = headerValueFirst(msg.requestHeaders, 'Cookie') === null;
        acceptStripped = headerValueFirst(msg.requestHeaders, 'Accept') === null;
        acceptEncodingPreserved = headerValueFirst(msg.requestHeaders, 'Accept-Encoding') !== null;
      }
      const kvs: KeyValue[] = [
        new KeyValue('downloadStatus', statusTextOf(trip)),
        new KeyValue('downloadDialogEvents', String(this.newDownloadDialogEvents)),
        new KeyValue('uaPreserved', String(uaPreserved)),
        new KeyValue('cookieStripped', String(cookieStripped)),
        new KeyValue('acceptStripped', String(acceptStripped)),
        new KeyValue('acceptEncodingPreserved', String(acceptEncodingPreserved))
      ];
      this.emitGuarded(runId, 'S5', kvs);
    } catch (e) {
      this.emitError(runId, 'S5', e as BusinessError);
    }
  }

  /** S6 /args 参数链：--media-tab-url 组（标题再回写）→ --url --media --known-* 组（列表+1）。 */
  private async runS6(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const tab: RoundTripResult =
        await this.roundTrip(postJsonRequest('/args', ARGS_TAB_BODY), 0);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const tabSync: SyncObservation = this.observeSync(tab);
      const media: RoundTripResult =
        await this.roundTrip(postJsonRequest('/args', ARGS_MEDIA_BODY), 0);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const mediaSync: SyncObservation = this.observeSync(media);
      const kvs: KeyValue[] = [
        new KeyValue('argsTabStatus', statusTextOf(tab)),
        new KeyValue('argsTabPrefix', prefixOf(tabSync.list.firstText, 10)),
        new KeyValue('argsMediaStatus', statusTextOf(media)),
        new KeyValue('argsMediaCount', String(mediaSync.list.count))
      ];
      this.emitGuarded(runId, 'S6', kvs);
    } catch (e) {
      this.emitError(runId, 'S6', e as BusinessError);
    }
  }

  /** S7 /link 兼容路由：POST 数组（一项空 url 跳过）→ 批量事件+pending 计数。 */
  private async runS7(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const pendingBefore: number = getPendingBatchLinks().length;
      const trip: RoundTripResult = await this.roundTrip(postJsonRequest('/link', LINK_BODY), 0);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const pendingAfter: number = getPendingBatchLinks().length;
      const kvs: KeyValue[] = [
        new KeyValue('linkStatus', statusTextOf(trip)),
        new KeyValue('batchEvents', String(this.batchEvents)),
        new KeyValue('pendingLinks', String(pendingAfter - pendingBefore))
      ];
      this.emitGuarded(runId, 'S7', kvs);
    } catch (e) {
      this.emitError(runId, 'S7', e as BusinessError);
    }
  }

  /** S8 错误处理三谓词：未知路径 GET /sync?x=1 / 坏 JSON POST /download / 缺 vid POST /vid {}——
   *  三者各新连接；closed 且无完整应答头块 = 静默断连观测（1:1 源语义）。 */
  private async runS8(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const unknown: RoundTripResult = await this.roundTrip(getRequest('/sync?x=1'), CLOSE_GRACE_MS);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const badJson: RoundTripResult =
        await this.roundTrip(postJsonRequest('/download', BAD_JSON_BODY), CLOSE_GRACE_MS);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const vidMissing: RoundTripResult =
        await this.roundTrip(postJsonRequest('/vid', VID_MISSING_BODY), CLOSE_GRACE_MS);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const kvs: KeyValue[] = [
        new KeyValue('unknownClosed', String(closedWithoutResponse(unknown))),
        new KeyValue('badJsonClosed', String(closedWithoutResponse(badJson))),
        new KeyValue('vidMissingClosed', String(closedWithoutResponse(vidMissing)))
      ];
      this.emitGuarded(runId, 'S8', kvs);
    } catch (e) {
      this.emitError(runId, 'S8', e as BusinessError);
    }
  }

  /** S9 最终 /sync 全量：GET /sync → 八字段序+videoList+stats 终快照。 */
  private async runS9(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const trip: RoundTripResult = await this.roundTrip(getRequest('/sync'), 0);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const sync: SyncObservation = this.observeSync(trip);
      const stats: BridgeStats = BridgeServer.getInstance().getStats();
      const kvs: KeyValue[] = [
        new KeyValue('syncStatus', statusTextOf(trip)),
        new KeyValue('fieldCount', String(sync.fieldView.fieldCount)),
        new KeyValue('fieldOrder', commasToSlash(sync.fieldView.fieldOrder)),
        new KeyValue('finalVideoCount', String(sync.list.count)),
        new KeyValue('connections', String(stats.connections)),
        new KeyValue('requests', String(stats.requests))
      ];
      this.emitGuarded(runId, 'S9', kvs);
    } catch (e) {
      this.emitError(runId, 'S9', e as BusinessError);
    }
  }

  // ────────────── 文件内私有辅助 ──────────────

  /** 单轮自连往返：新连接 → 发送 → 等应答（closeGraceMs>0 再等 FIN）→ 取观测；异常记 err 不外抛。 */
  private async roundTrip(requestBytes: Uint8Array, closeGraceMs: number): Promise<RoundTripResult> {
    const conn: ProbeTcpClient = new ProbeTcpClient();
    let result: RoundTripResult = {
      status: -1, headComplete: false, closed: false, errCode: 0, errMessage: '',
      bytes: new Uint8Array(0)
    };
    try {
      await conn.connect();
      await conn.sendBytes(requestBytes);
      await conn.awaitResponse();
      if (closeGraceMs > 0) {
        await conn.awaitClose(closeGraceMs);
      }
      const bytes: Uint8Array = conn.take();
      const view: ResponseHeadView = splitResponseHead(bytes);
      const done: RoundTripResult = {
        status: view.status, headComplete: view.complete, closed: conn.isClosed(),
        errCode: 0, errMessage: '', bytes: bytes
      };
      result = done;
    } catch (e) {
      const err = e as BusinessError;
      const failed: RoundTripResult = {
        status: -1, headComplete: false, closed: conn.isClosed(),
        errCode: err.code, errMessage: err.message ?? '', bytes: new Uint8Array(0)
      };
      result = failed;
    } finally {
      await conn.close();
    }
    return result;
  }

  /** /sync 形应答观测：头切分+体 UTF-8 解码（decodeBody，与实现同源）+字段序+videoList 摘要。 */
  private observeSync(trip: RoundTripResult): SyncObservation {
    const view: ResponseHeadView = splitResponseHead(trip.bytes);
    const bodyText: string = view.complete ? decodeBody(trip.bytes, view.bodyStart) : '';
    const fieldView: SyncBodyView = parseSyncBody(bodyText);
    const list: VideoListSummary = videoListSummary(bodyText);
    const obs: SyncObservation = {
      status: view.status, bodyText: bodyText, fieldView: fieldView, list: list
    };
    return obs;
  }

  /** emit 前会话守卫复检（await roundTrip 之后）。 */
  private emitGuarded(runId: string, stepNo: string, kvs: KeyValue[]): void {
    if (!this.probeKit.isCurrent(runId)) {
      return;
    }
    this.probeKit.emit(stepNo, kvs);
  }

  /** 失败路径：errCode/errMessage 键组仍恰一行（观测红线：不中断会话）。 */
  private emitError(runId: string, stepNo: string, err: BusinessError): void {
    if (!this.probeKit.isCurrent(runId)) {
      return;
    }
    const errKvs: KeyValue[] = [
      new KeyValue('errCode', String(err.code)),
      new KeyValue('errMessage', err.message ?? '')
    ];
    this.probeKit.emit(stepNo, errKvs);
  }

  build() {
    Column({ space: 12 }) {
      Text($r('app.string.probe_p6u1_hint'))
        .fontSize(12)
        .opacity(0.7)
        .width('100%')
      ProbePage({
        unitId: 'P6-U1',
        pageTitle: $r('app.string.probe_p6u1_title'),
        steps: ROUTES_STEPS,
        autoStart: true,
        runStep: (stepNo: string): Promise<void> => this.runStep(stepNo)
      })
        .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .padding(16)
  }
}

/** 路由状态观测值：errCode 非 0 → 'err'+code；否则状态码。 */
function statusTextOf(res: RoundTripResult): string {
  if (res.errCode !== 0) {
    return 'err' + String(res.errCode);
  }
  return String(res.status);
}

/** 静默断连谓词：closed 且无完整应答头块（零应答字节或不足一个头块）。 */
function closedWithoutResponse(res: RoundTripResult): boolean {
  return res.closed && !res.headComplete;
}

/** videoList 摘要（JSON.parse→Record 窄化→计数/首元素 text/id/info；失败 parseOk=false）。 */
function videoListSummary(bodyText: string): VideoListSummary {
  const summary: VideoListSummary = {
    parseOk: false, count: -1, firstText: '', firstId: '', firstInfo: ''
  };
  try {
    const obj: Record<string, Object> = JSON.parse(bodyText) as Record<string, Object>;
    const list: Object = obj['videoList'];
    if (!Array.isArray(list)) {
      return summary;
    }
    const arr: Object[] = list as Object[];
    summary.parseOk = true;
    summary.count = arr.length;
    if (arr.length > 0) {
      const first: Record<string, Object> = arr[0] as Record<string, Object>;
      const text: Object | undefined = first['text'];
      if (typeof text === 'string') {
        summary.firstText = text;
      }
      const id: Object | undefined = first['id'];
      if (typeof id === 'string') {
        summary.firstId = id;
      }
      const info: Object | undefined = first['info'];
      if (typeof info === 'string') {
        summary.firstInfo = info;
      }
    }
  } catch (e) {
    summary.parseOk = false;
  }
  return summary;
}

/** 前缀截取（越界安全） */
function prefixOf(v: string, len: number): string {
  return v.length <= len ? v : v.slice(0, len);
}

/** 末缀截取（越界安全） */
function suffixOf(v: string, len: number): string {
  return v.length <= len ? v : v.slice(v.length - len);
}

/** description 首段 '[X] ...' 的括号内 token（'['/']' 不在 emit 值白名单，预剥离；
 *  无括号返回原串前 8 字符） */
function bracketTokenOf(info: string): string {
  const open: number = info.indexOf('[');
  const close: number = info.indexOf(']');
  if (open >= 0 && close > open) {
    return info.slice(open + 1, close);
  }
  return prefixOf(info, 8);
}

/** 探针值白名单消毒预转换（P0-U3 同款）：', ' 与 ',' → '/' */
function commasToSlash(v: string): string {
  return v.split(', ').join('/').split(',').join('/');
}
