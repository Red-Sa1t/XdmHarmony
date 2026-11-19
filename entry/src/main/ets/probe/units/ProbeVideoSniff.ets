/*
 * U6.2 探针单元：P6-U2 嗅探规则链+视频捕获探针（设计书 u6-2 §6 步骤表，autoStart=true 全自动 S1~S8）。
 * S1 就绪+/clear 基线 → S2 分类矩阵（video/mp4 登记+audio/aac 登记+application/json 识别锚
 *    无登记）→ S3 HLS 暂态消除（.m3u8 识别+两表写入；同 tabId .ts 段被 isNormalVideo 门②拦截）
 *    → S4 referer 跳过（同 referer 拦/异 referer 登记）→ S5 YT-DASH 配对（音频段 HandleDashAudio
 *    单源登记+同 id 视频段 dual 配对）→ S6 itag=22 短路落普通门+'mkv' 缺点怪典+/vid 对话框事件
 *    → S7 捕获页种子（直调 addHlsVideo/addDashVideo，走查数据）→ S8 事件面回归（/clear+/sync
 *    八字段序+stats）。
 * 监听器：tracker（mediaAdded/mediaUpdated 计数）与 BridgeUiEvents（videoDialog 计数，import 自
 *    BridgeActions——U6.2 收敛 a 后的注册面）在 aboutToAppear 注册（BEGIN 后、S1 前计数从 0 起），
 *    卸载注销。
 * 观测红线：布尔键均为直接观测谓词（status/计数/前缀匹配），不含通过/失败判定词；期望只在
 *    EXPECT-u6-2-sniff-rule-chain-video-capture.json。值白名单预转换：'['/']' 不在白名单，
 *    *TextPrefix 取去括号 token 且空格→'_'；fieldOrder 经 commasToSlash（P6-U1 同款）。
 * 会话代际守卫：每个 runner 入口捕获 runId，每个 await 之后、emit 之前复检 isCurrent，不一致
 *    静默 return（U0.2 §3.5 惯例）。自连客户端复用 ProbeBridgeNet（P0-U3 提炼件）。
 * 注记：S1 /clear 只清 tracker 四表不清嗅探态（源 ClearVideoList 同貌）——S5/S6 依赖前序
 *    m3u8Tabs/referersToSkip 状态属预期（设计书 §7 风险表）；S2 的 audio/aac 载荷 CL 取 2097152
 *    （设计书 §6 示例行 2048 会被 MinVideoSize 门拒——示例行为示意，EXPECT 表按真值）。
 * ArkTS 红线：无 any/解构/for...in/正则字面量；对象字面量具类型；箭头函数显式返回类型。
 */

import { BusinessError } from '@kit.BasicServicesKit';
import { ProbeKit, KeyValue } from '../core/ProbeKit';
import { ProbePage, ProbeStepDef } from '../core/ProbePage';
import { BridgeServer, BridgeStats } from '../../core/bridge/BridgeServer';
import { BridgeVideoItem } from '../../core/bridge/BridgeProtocol';
import { CapturedVideoTracker, TrackerListener, TrackedVideo } from '../../core/bridge/CapturedVideoTracker';
import {
  BridgeUiEvents, PendingBatchLink, registerBridgeUiEvents, unregisterBridgeUiEvents
} from '../../core/bridge/BridgeActions';
import {
  ProbeTcpClient, postJsonRequest, getRequest, decodeBody
} from './ProbeBridgeNet';
import { ResponseHeadView, SyncBodyView, splitResponseHead, parseSyncBody } from './ProbeBridgeLogic';

/** P6-U2 步骤定义表（S1~S8 全自动） */
const SNIFF_STEPS: ProbeStepDef[] = [
  { stepNo: 'S1', title: '就绪+/clear 清空基线', autoRun: true },
  { stepNo: 'S2', title: '/media 分类矩阵（mp4/aac/json）', autoRun: true },
  { stepNo: 'S3', title: 'HLS 暂态消除（同 tab .ts 拦截）', autoRun: true },
  { stepNo: 'S4', title: 'referer 跳过（同拦异登）', autoRun: true },
  { stepNo: 'S5', title: 'YT-DASH 段配对（audio+dual）', autoRun: true },
  { stepNo: 'S6', title: 'itag 短路+mkv 怪典+/vid 事件', autoRun: true },
  { stepNo: 'S7', title: '捕获页种子（hls/dash）', autoRun: true },
  { stepNo: 'S8', title: '事件面回归（/clear+/sync）', autoRun: true }
];

/** 单轮往返产物（文件内私有） */
interface RoundTripResult {
  status: number;
  headComplete: boolean;
  closed: boolean;
  errCode: number;
  errMessage: string;
  bytes: Uint8Array;
}

/** videoList 观测产物（首/次元素——S2 分类矩阵） */
interface VideoListSummary {
  parseOk: boolean;
  count: number;
  firstText: string;
  firstId: string;
  firstInfo: string;
  secondText: string;
  secondInfo: string;
}

/** /sync 应答观测产物（文件内私有） */
interface SyncObservation {
  status: number;
  bodyText: string;
  fieldView: SyncBodyView;
  list: VideoListSummary;
}

@Component
export struct ProbeVideoSniff {
  private probeKit: ProbeKit = ProbeKit.getInstance();

  /** 事件袋计数（aboutToAppear 注册，从 0 起） */
  private mediaAddedEvents: number = 0;
  private mediaUpdatedEvents: number = 0;
  private videoDialogEvents: number = 0;
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
      onShowVideoDownloadDialog: (videoId: string, name: string, size: number,
        contentType: string): void => {
        this.videoDialogEvents++;
      },
      onShowBatchSelection: (items: PendingBatchLink[]): void => {
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

  /** 步骤分派：各 runner 自行捕获 runId 并过会话守卫 */
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
  }

  /** S1 就绪+/clear：stats 快照 → POST /clear → 应答 videoList 计数。 */
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
        new KeyValue('baseVideoCount', String(sync.list.count))
      ];
      this.emitGuarded(runId, 'S1', kvs);
    } catch (e) {
      this.emitError(runId, 'S1', e as BusinessError);
    }
  }

  /** S2 分类矩阵：①video/mp4 5MB file=Movie → ②audio/aac 2MB file=Tone → ③application/json
   *  （识别锚、无 CL、无登记预期）。观测首/次条目文本与描述前缀。 */
  private async runS2(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const addedBefore: number = this.mediaAddedEvents;
      const first: RoundTripResult = await this.roundTrip(
        postJsonRequest('/media', mediaJson('https://h/v/movie.mp4', 'video/mp4', 5242880, 'Movie', '100', null)), 0);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const second: RoundTripResult = await this.roundTrip(
        postJsonRequest('/media', mediaJson('https://h/a/tone.aac', 'audio/aac', 2097152, 'Tone', '100', null)), 0);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const third: RoundTripResult = await this.roundTrip(
        postJsonRequest('/media', mediaJson('https://h/api/manifest', 'application/json', null, null, '100', null)), 0);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const sync: SyncObservation = this.observeSync(third);
      const kvs: KeyValue[] = [
        new KeyValue('mediaStatus', statusTextOf(first)),
        new KeyValue('secondStatus', statusTextOf(second)),
        new KeyValue('jsonStatus', statusTextOf(third)),
        new KeyValue('addedEvents', String(this.mediaAddedEvents - addedBefore)),
        new KeyValue('listCount', String(sync.list.count)),
        new KeyValue('firstTextSuffix', suffixOf(sync.list.firstText, 4)),
        new KeyValue('secondTextSuffix', suffixOf(sync.list.secondText, 4)),
        new KeyValue('secondInfoPrefix', bracketTokenOf(sync.list.secondInfo))
      ];
      this.emitGuarded(runId, 'S2', kvs);
    } catch (e) {
      this.emitError(runId, 'S2', e as BusinessError);
    }
  }

  /** S3 HLS 暂态消除：.m3u8（tabId=200，识别+两表写入、无登记）→ 同 tab .ts 段（门②拦截）。 */
  private async runS3(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const beforeCount: number = CapturedVideoTracker.getInstance().getTrackedVideos().length;
      const m3u8: RoundTripResult = await this.roundTrip(
        postJsonRequest('/media', mediaJson('https://h/list.m3u8', 'application/vnd.apple.mpegurl', null, null, '200', 'R1')), 0);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const ts: RoundTripResult = await this.roundTrip(
        postJsonRequest('/media', mediaJson('https://h/seg/001.ts', 'video/mp2t', 300000, null, '200', 'R1')), 0);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const afterCount: number = CapturedVideoTracker.getInstance().getTrackedVideos().length;
      const kvs: KeyValue[] = [
        new KeyValue('hlsStatus1', statusTextOf(m3u8)),
        new KeyValue('hlsStatus2', statusTextOf(ts)),
        new KeyValue('beforeCount', String(beforeCount)),
        new KeyValue('afterCount', String(afterCount)),
        new KeyValue('tsBlocked', String(afterCount === beforeCount))
      ];
      this.emitGuarded(runId, 'S3', kvs);
    } catch (e) {
      this.emitError(runId, 'S3', e as BusinessError);
    }
  }

  /** S4 referer 跳过：.m3u8（tabId=201、Referer=R1 写表）→ 同 referer 普通视频拦 → 异 referer 登记。 */
  private async runS4(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const beforeCount: number = CapturedVideoTracker.getInstance().getTrackedVideos().length;
      const seed: RoundTripResult = await this.roundTrip(
        postJsonRequest('/media', mediaJson('https://h/list2.m3u8', 'application/vnd.apple.mpegurl', null, null, '201', 'R1')), 0);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const skip: RoundTripResult = await this.roundTrip(
        postJsonRequest('/media', mediaJson('https://h/v/clip.mp4', 'video/mp4', 5242880, null, null, 'R1')), 0);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const afterSkipCount: number = CapturedVideoTracker.getInstance().getTrackedVideos().length;
      const other: RoundTripResult = await this.roundTrip(
        postJsonRequest('/media', mediaJson('https://h/v/clip2.mp4', 'video/mp4', 5242880, null, null, 'R2')), 0);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const afterOtherCount: number = CapturedVideoTracker.getInstance().getTrackedVideos().length;
      const kvs: KeyValue[] = [
        new KeyValue('seedStatus', statusTextOf(seed)),
        new KeyValue('skipStatus', statusTextOf(skip)),
        new KeyValue('otherStatus', statusTextOf(other)),
        new KeyValue('beforeCount', String(beforeCount)),
        new KeyValue('afterSkipCount', String(afterSkipCount)),
        new KeyValue('afterOtherCount', String(afterOtherCount))
      ];
      this.emitGuarded(runId, 'S4', kvs);
    } catch (e) {
      this.emitError(runId, 'S4', e as BusinessError);
    }
  }

  /** S5 YT-DASH 配对：音频段（itag=140、HandleDashAudio 单源登记）→ 同 id 视频段（dual 配对）。 */
  private async runS5(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const gvAudio: string = 'https://rr.googlevideo.com/videoplayback?itag=140&mime=audio%2Fmp4&clen=1000&id=oA';
      const gvVideo: string = 'https://rr.googlevideo.com/videoplayback?itag=137&mime=video%2Fmp4&clen=2000&id=oA';
      const audio: RoundTripResult = await this.roundTrip(
        postJsonRequest('/media', mediaJson(gvAudio, 'audio/mp4', null, 'YT Video', '205', null)), 0);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const audioTextPrefix: string = lastDescriptionOf('YT Video.mp4');
      const video: RoundTripResult = await this.roundTrip(
        postJsonRequest('/media', mediaJson(gvVideo, 'video/mp4', null, 'YT Video', '205', null)), 0);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const videos: TrackedVideo[] = CapturedVideoTracker.getInstance().getTrackedVideos();
      let dualCount: number = 0;
      let dualTextPrefix: string = '';
      for (let i = 0; i < videos.length; i++) {
        if (videos[i].kind === 'yt' && videos[i].file === 'YT Video.mkv') {
          dualCount++;
          dualTextPrefix = videos[i].description;
        }
      }
      const sync: SyncObservation = this.observeSync(video);
      const kvs: KeyValue[] = [
        new KeyValue('audioStatus', statusTextOf(audio)),
        new KeyValue('videoStatus', statusTextOf(video)),
        new KeyValue('dualCount', String(dualCount)),
        new KeyValue('audioTextPrefix', tokenOf(audioTextPrefix)),
        new KeyValue('dualTextPrefix', bracketTokenOf(dualTextPrefix)),
        new KeyValue('listCount', String(sync.list.count))
      ];
      this.emitGuarded(runId, 'S5', kvs);
    } catch (e) {
      this.emitError(runId, 'S5', e as BusinessError);
    }
  }

  /** S6 短路+怪典+对话框事件：itag=22 落普通门 → flac 'mkv' 缺点 → /vid 对话框事件计数。 */
  private async runS6(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const regular: string = 'https://rr.googlevideo.com/videoplayback?itag=22&mime=video%2Fmp4&clen=5242880&id=oB';
      const flac: string = 'https://rr.googlevideo.com/videoplayback?itag=139&mime=audio%2Fflac&clen=1000&id=oC';
      const normal: RoundTripResult = await this.roundTrip(
        postJsonRequest('/media', mediaJson(regular, 'video/mp4', 5242880, 'Regular', '206', null)), 0);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const normalVid: string = lastIdOfFile('Regular.mp4');
      const kv: RoundTripResult = await this.roundTrip(
        postJsonRequest('/media', mediaJson(flac, 'audio/flac', null, 'Clip', '206', null)), 0);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const kvTextPrefix: string = lastDescriptionOf('Clipmkv');
      const dialogBefore: number = this.videoDialogEvents;
      const vid: RoundTripResult = await this.roundTrip(
        postJsonRequest('/vid', '{"vid":"' + normalVid + '"}'), 0);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const kvs: KeyValue[] = [
        new KeyValue('normalStatus', statusTextOf(normal)),
        new KeyValue('kvStatus', statusTextOf(kv)),
        new KeyValue('kvTextPrefix', tokenOf(kvTextPrefix)),
        new KeyValue('kvFileText', lastFileTextOf('Clipmkv')),
        new KeyValue('vidStatus', statusTextOf(vid)),
        new KeyValue('videoDialogEvents', String(this.videoDialogEvents - dialogBefore))
      ];
      this.emitGuarded(runId, 'S6', kvs);
    } catch (e) {
      this.emitError(runId, 'S6', e as BusinessError);
    }
  }

  /** S7 捕获页种子+走查指引：直调 addHlsVideo/addDashVideo 各 1 条（数据形状设计书 §2.4）→
   *  观测四表 kind 覆盖（getTrackedVideos 富投影——/sync 投影不挂 kind）→ GET /sync。 */
  private async runS7(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const before: number = CapturedVideoTracker.getInstance().getTrackedVideos().length;
      const videoSegs: string[] = ['https://h/dash/v/seg-1.m4s', 'https://h/dash/v/seg-2.m4s'];
      const audioSegs: string[] = ['https://h/dash/a/seg-1.m4s'];
      CapturedVideoTracker.getInstance().addHlsVideo('Stream.ts', 'https://h/live.m3u8', '',
        null, null, '[TS]', '210', 'https://t/live');
      CapturedVideoTracker.getInstance().addDashVideo('Video.mkv', 'https://h/manifest.mpd',
        videoSegs, audioSegs, null, null, 0, 'video/mp4', 'audio/mp4', '[1080p]', '211',
        'https://t/dash');
      const after: number = CapturedVideoTracker.getInstance().getTrackedVideos().length;
      const videos: TrackedVideo[] = CapturedVideoTracker.getInstance().getTrackedVideos();
      const kinds: Set<string> = new Set<string>();
      for (let i = 0; i < videos.length; i++) {
        kinds.add(videos[i].kind);
      }
      const trip: RoundTripResult = await this.roundTrip(getRequest('/sync'), 0);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const sync: SyncObservation = this.observeSync(trip);
      const kvs: KeyValue[] = [
        new KeyValue('seededCount', String(after - before)),
        new KeyValue('kindCount', String(kinds.size)),
        new KeyValue('syncStatus', statusTextOf(trip)),
        new KeyValue('listCount', String(sync.list.count)),
        new KeyValue('walkthroughHint', 'open-menu-media-capture')
      ];
      this.emitGuarded(runId, 'S7', kvs);
    } catch (e) {
      this.emitError(runId, 'S7', e as BusinessError);
    }
  }

  /** S8 事件面回归：POST /clear → GET /sync 全量（八字段序+计数）+ stats 终快照。 */
  private async runS8(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const clear: RoundTripResult = await this.roundTrip(postJsonRequest('/clear', '{}'), 0);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const sync: RoundTripResult = await this.roundTrip(getRequest('/sync'), 0);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const obs: SyncObservation = this.observeSync(sync);
      const stats: BridgeStats = BridgeServer.getInstance().getStats();
      const kvs: KeyValue[] = [
        new KeyValue('clearStatus', statusTextOf(clear)),
        new KeyValue('finalVideoCount', String(obs.list.count)),
        new KeyValue('fieldCount', String(obs.fieldView.fieldCount)),
        new KeyValue('fieldOrder', commasToSlash(obs.fieldView.fieldOrder)),
        new KeyValue('connections', String(stats.connections)),
        new KeyValue('requests', String(stats.requests)),
        new KeyValue('mediaAddedEvents', String(this.mediaAddedEvents)),
        new KeyValue('videoDialogEvents', String(this.videoDialogEvents))
      ];
      this.emitGuarded(runId, 'S8', kvs);
    } catch (e) {
      this.emitError(runId, 'S8', e as BusinessError);
    }
  }

  // ────────────── 文件内私有辅助 ──────────────

  /** 单轮自连往返：新连接 → 发送 → 等应答 → 取观测；异常记 err 不外抛。 */
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

  /** /sync 形应答观测（头切分+体解码+字段序+首/次元素摘要）。 */
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
      Text($r('app.string.probe_p6u2_hint'))
        .fontSize(12)
        .opacity(0.7)
        .width('100%')
      ProbePage({
        unitId: 'P6-U2',
        pageTitle: $r('app.string.probe_p6u2_title'),
        steps: SNIFF_STEPS,
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

/** /media 载荷 JSON 组装（request-watcher.js createRequestData 形；file/tabId/referer 可选）。 */
function mediaJson(url: string, ct: string, cl: number | null, file: string | null,
  tabId: string | null, referer: string | null): string {
  const parts: string[] = [];
  parts.push('"url":' + JSON.stringify(url));
  if (file !== null) {
    parts.push('"file":' + JSON.stringify(file));
  }
  if (tabId !== null) {
    parts.push('"tabId":' + JSON.stringify(tabId));
  }
  parts.push('"tabUrl":"https://www.youtube.com/watch?v=abc"');
  parts.push('"method":"GET"');
  const reqParts: string[] = [];
  if (referer !== null) {
    reqParts.push('"Referer":[' + JSON.stringify(referer) + ']');
  }
  reqParts.push('"User-Agent":["ProbeUA"]');
  parts.push('"requestHeaders":{' + reqParts.join(',') + '}');
  // 头值恒为数组（extension/app.js:123-127 形；源 ExtensionData.cs:12 Dictionary<string, List<string>>）——
  // 裸字符串值被桥 JSON 门拒收断连（2026-10-18 真机 S2~S8 status=-1 实证）
  const resParts: string[] = [];
  resParts.push('"Content-Type":[' + JSON.stringify(ct) + ']');
  if (cl !== null) {
    resParts.push('"Content-Length":["' + String(cl) + '"]');
  }
  parts.push('"responseHeaders":{' + resParts.join(',') + '}');
  return '{' + parts.join(',') + '}';
}

/** 路由状态观测值：errCode 非 0 → 'err'+code；否则状态码。 */
function statusTextOf(res: RoundTripResult): string {
  if (res.errCode !== 0) {
    return 'err' + String(res.errCode);
  }
  return String(res.status);
}

/** videoList 摘要（首/次元素 text/id/info；失败 parseOk=false）。 */
function videoListSummary(bodyText: string): VideoListSummary {
  const summary: VideoListSummary = {
    parseOk: false, count: -1, firstText: '', firstId: '', firstInfo: '', secondText: '',
    secondInfo: ''
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
    if (arr.length > 1) {
      const second: Record<string, Object> = arr[1] as Record<string, Object>;
      const text2: Object | undefined = second['text'];
      if (typeof text2 === 'string') {
        summary.secondText = text2;
      }
      const info2: Object | undefined = second['info'];
      if (typeof info2 === 'string') {
        summary.secondInfo = info2;
      }
    }
  } catch (e) {
    summary.parseOk = false;
  }
  return summary;
}

/** 按 file 精确匹配取最新条目的 description（无命中 → ''）。 */
function lastDescriptionOf(file: string): string {
  const videos: TrackedVideo[] = CapturedVideoTracker.getInstance().getTrackedVideos();
  for (let i = videos.length - 1; i >= 0; i--) {
    if (videos[i].file === file) {
      return videos[i].description;
    }
  }
  return '';
}

/** 按 file 精确匹配取最新条目的 file 原文（无命中 → ''）。 */
function lastFileTextOf(file: string): string {
  const videos: TrackedVideo[] = CapturedVideoTracker.getInstance().getTrackedVideos();
  for (let i = videos.length - 1; i >= 0; i--) {
    if (videos[i].file === file) {
      return videos[i].file;
    }
  }
  return '';
}

/** 按 file 精确匹配取最新条目的 id（无命中 → ''；S6 /vid 载荷用）。 */
function lastIdOfFile(file: string): string {
  const videos: TrackedVideo[] = CapturedVideoTracker.getInstance().getTrackedVideos();
  for (let i = videos.length - 1; i >= 0; i--) {
    if (videos[i].file === file) {
      return videos[i].id;
    }
  }
  return '';
}

/** 前缀截取（越界安全）。 */
function prefixOf(v: string, len: number): string {
  return v.length <= len ? v : v.slice(0, len);
}

/** 末缀截取（越界安全）。 */
function suffixOf(v: string, len: number): string {
  return v.length <= len ? v : v.slice(v.length - len);
}

/** description 首段 '[X] ...' 的括号内 token（'['/']' 不在 emit 值白名单，预剥离）。 */
function bracketTokenOf(info: string): string {
  const open: number = info.indexOf('[');
  const close: number = info.indexOf(']');
  if (open >= 0 && close > open) {
    return info.slice(open + 1, close);
  }
  return prefixOf(info, 8);
}

/** '[X AUDIO] ...' 形文本的音频段 token（去括号、内部空格→'_'——设计书 §6 S5 示例口径）。 */
function tokenOf(info: string): string {
  const open: number = info.indexOf('[');
  const close: number = info.indexOf(']');
  if (open >= 0 && close > open) {
    return info.slice(open + 1, close).split(' ').join('_');
  }
  return prefixOf(info, 12);
}

/** 探针值白名单消毒预转换（P0-U3 同款）：', ' 与 ',' → '/'。 */
function commasToSlash(v: string): string {
  return v.split(', ').join('/').split(',').join('/');
}
