/*
 * U6.1 视频列表桥侧数据半区 → U6.2 动作半区收拢（设计书 u6-2 §3.1/§2.4/§2.5/§2.6）。
 * VideoTracker.cs 的四表投影——数据半区（四张插入序表、GetVideoList 排序投影、Clear+广播、
 * UpdateMediaTitle、单源视频登记、按 vid 查找、ffmpeg 需求判定、监听器注册表）+ U6.2 动作半区
 * （addVideoDownload——自 BridgeRoutes.videoDownloadAction 移入，U6.1 报告 §8-a 收敛项）。
 * 拓扑（§3.1）：BridgeRoutes → CapturedVideoTracker → BridgeActions 单向无环；startBridgeAutoDownload
 * 经 BridgeActions 中立件调用（若留 BridgeRoutes 则逆边成环）。
 * 对照源码（本会话只读核实，未改 resourses/ 下任何文件）：
 *   VideoTracker.cs:19-22  —— 四 GenericOrderedDictionary → 四张 Map（Map 迭代序=插入序同构；
 *                lock(this) 不复刻——单线程事件循环，MIGRATION_PLAN 决策 2 精神）。
 *   VideoTracker.cs:27-34  —— ClearVideoList：清四表+BroadcastConfigChange（鸿蒙侧复用既有
 *                Config.broadcastConfigChange 公共 API，不新增广播机制，§0-7④）。
 *   VideoTracker.cs:47-89  —— UpdateMediaTitle：仅扫 yt+video 两表、tabUrl 空跳过、精确等值
 *                命中改 file（GenerateUpdatedFileName）+ MediaUpdated 事件。
 *   VideoTracker.cs:130-158 —— GetVideoList：yt→video→hls→dash 拼接后按 DateAdded 升序排序
 *                （Array.sort 稳定排序=源观测序的保守超集，§3-5）→ MediaInfo 四字段投影。
 *                U6.2 新增 getTrackedVideos 富投影（§2.6：页需要 kind 分组，/sync 投影
 *                BridgeVideoItem 契约冻结不挂 kind——getVideoList 零改动，事件面零破坏红线）。
 *   VideoTracker.cs:242-258/:277-293/:295-311 —— AddVideoNotification 三单条重载（DualSource→yt /
 *                MultiSourceHLS→hls / MultiSourceDASH→dash）：id=UUID、DateTime.Now、入表、
 *                MediaAdded+ShowMediaNotification+BroadcastConfigChange。**ShowMediaNotification
 *                托盘气泡（MSG_VID_CAP）U6.2 拍板降级为 log+MediaAdded 事件+广播**（系统通知
 *                U6.3 端到端接线时评估 wantAgent 导航面，设计书 §4-9）。批量重载 AddVideoNotifications
 *                ×4（:160-240）唯一调用方 ProcessPostYtFormats（U6.4/U7.1）——本单元不落。
 *   VideoTracker.cs:260-275 —— AddVideoNotification 单源重载：id=Guid.NewGuid、DateTime.Now、
 *                入 video 表、MediaAdded+ShowMediaNotification+BroadcastConfigChange。
 *   VideoTracker.cs:313-370 —— AddVideoDownload（动作半区，U6.2 移入本类）：
 *                ContainsKey(null)→ArgumentNullException→断连（1:1 保留，§4-11 防顺手防御锚——
 *                **不得改静默**）；查表序 yt→video→hls→dash，仅 yt/video 两表有 LinkRefresher.
 *                LinkAccepted 前置守卫位（:321/:329，恒 false 注释锚随迁 §4-3）；未命中静默；
 *                valid 且 StartDownloadAutomatically && IsFFmpegOK → StartVideoDownload（自动
 *                分支 sanitize 后传；**对话框分支 name 未消毒**——源 :367 传原名）；否则
 *                ShowVideoDownloadDialog。
 *   VideoTracker.cs:372-376 —— IsFFmpegOK：!IsFFmpegRequiredForDownload → true；否则
 *                FFmpegMediaProcessor.IsFFmpegInstalled()（U6.1 §4-6 降级：yt/hls/dash 恒 false，
 *                U7.2 接真值）→ **私有化随迁**（唯一调用方 addVideoDownload）。
 *   VideoTracker.cs:91-94   —— IsFFmpegRequiredForDownload：yt/hls/dash 含 id。
 *   VideoTracker.cs:24-25   —— MediaAdded/MediaUpdated 两事件 → 监听器注册表（Config.
 *                onConfigChanged 同款；逐监听器 try/catch 吞异常+遍历拷贝防回调内注销塌缩）。
 *   TrackedVideo 扩 8 承载字段（§2.4：DualSource.Uri2/Headers2/Cookies2、MultiSourceHLS.AudioUri、
 *                MultiSourceDASH.VideoSegments/AudioSegments/Duration/VideoMimeType/AudioMimeType
 *                ——三类 DownloadInfo 逐字段对齐；**显式默认值防 undefined 流转**）。
 *   既有字段取值（§2.4）：uri←Uri1/VideoUri/manifest URL（U7.1 消费）；size←displayInfo.Size
 *                （dual=两段 clen 和；hls/dash 源不设→0）；contentType 源三类均未设→''（唯一例外
 *                HandleDashAudio 单源条目=info.mime）；dateAdded←Date.now()（源 MediaInfo 构造用
 *                DateTime.Now 而非 displayInfo.CreationTime，:253/:270/:288/:306——两者此刻同值）。
 * 有意差异：DateTime.Now → Date.now() epoch ms（U1.1 D1 先例）；util.generateRandomUUID 对应
 *   Guid.NewGuid().ToString()；LinkAccepted 恒 false（§0-4 拍板延续——重复链接不去重差异继续，
 *   U6.3 与刷新链接窗一起落）。
 * 业务日志：hilog domain 0x0000、tag 'VideoTracker'，绝不输出探针标记（§0-6）。
 * ArkTS 红线：无 any/解构/for...in/正则字面量；对象字面量均具 interface 类型；throw 只抛 Error。
 */

import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { BridgeHeaders, BridgeVideoItem } from './BridgeProtocol';
import { generateUpdatedFileName } from './VideoSniffAlgo';
import { BridgeUiEvents, fireBridgeUiEvent, startBridgeAutoDownload,
  bridgeRequestOf, enqueueBridgeRequests } from './BridgeActions';
import { sanitizeFileName } from '../util/FileNames';
import { FileNameFetchMode } from '../../model/DownloadTypes';
import { Config } from '../Config';
import { DownloadCreationRequest } from '../../model/DownloadCreationRequest';
import { LinkRefresher } from './LinkRefresher';
import { AdaptiveSourceDescriptor, mimeFromUrlQuery, validateAdaptiveSource } from '../../model/AdaptiveSource';

/** 业务日志面（domain 0x0000 / tag 'VideoTracker'） */
const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'VideoTracker';

/** 单条被捕获视频：KeyValuePair<TDownloadInfo, StreamingVideoDisplayInfo> 拍平
 * （下载信息半区 uri/headers/cookies + 展示半区 file/size/contentType/description/
 * tabId/tabUrl/dateAdded，设计书 §2.4；U6.2 分型时再拆）。 */
export class TrackedVideo {
  id: string;
  /** 四表归属：'yt'/'video'/'hls'/'dash' */
  kind: string;
  /** 展示名（GetVideoList 的 text / UpdateMediaTitle 回写目标） */
  file: string;
  size: number;
  contentType: string;
  uri: string;
  headers: BridgeHeaders | null;
  cookies: string | null;
  /** StreamingVideoDisplayInfo.DescriptionText（qualityText 产物） */
  description: string;
  tabId: string;
  tabUrl: string;
  /** epoch ms（DateTime.Now 投影，D1） */
  dateAdded: number;

  constructor(id: string, kind: string, file: string, size: number, contentType: string,
    uri: string, headers: BridgeHeaders | null, cookies: string | null, description: string,
    tabId: string, tabUrl: string, dateAdded: number) {
    this.id = id;
    this.kind = kind;
    this.file = file;
    this.size = size;
    this.contentType = contentType;
    this.uri = uri;
    this.headers = headers;
    this.cookies = cookies;
    this.description = description;
    this.tabId = tabId;
    this.tabUrl = tabUrl;
    this.dateAdded = dateAdded;
  }

  /** ── U6.2 追加 8 承载字段（设计书 §2.4；显式默认值防 undefined 流转）── */
  /** DualSource.Uri2 / MultiSourceHLS.AudioUri（addDualSourceVideo / addHlsVideo 写入） */
  uri2: string = '';
  /** DualSource.Headers2（addDualSourceVideo） */
  headers2: BridgeHeaders | null = null;
  /** DualSource.Cookies2（addDualSourceVideo） */
  cookies2: string | null = null;
  /** MultiSourceDASH.VideoSegments（List<Uri> 串化；addDashVideo） */
  videoSegments: string[] = [];
  /** MultiSourceDASH.AudioSegments（addDashVideo） */
  audioSegments: string[] = [];
  /** MultiSourceDASH.Duration（max(video,audio)；addDashVideo） */
  duration: number = 0;
  /** MultiSourceDASH.VideoMimeType（addDashVideo） */
  videoMimeType: string = '';
  /** MultiSourceDASH.AudioMimeType（addDashVideo） */
  audioMimeType: string = '';
}

/** AddVideoDownload 命中产物（VideoTracker.cs:319-355 的读取半区投影；未命中 found=false）。 */
export interface VideoLookup {
  found: boolean;
  kind: string;
  name: string;
  size: number;
  contentType: string;
  uri: string;
  headers: BridgeHeaders | null;
  cookies: string | null;
}

/** Detached submission captured before any persistence wait, including a multi-selection's later items. */
export interface VideoDownloadSnapshot {
  id: string;
  kind: string;
  contentType: string;
  automatic: boolean;
  request: DownloadCreationRequest;
}

/** MediaAdded/MediaUpdated 两事件的监听器（VideoTracker.cs:24-25）；回调可选实现。 */
export interface TrackerListener {
  onMediaAdded?: (item: BridgeVideoItem) => void;
  onMediaUpdated?: (item: BridgeVideoItem) => void;
}

/** 未命中常量投影（name/uri/contentType 空串、size 0、kind 'video' 占位——C# valid=false
 * 时不触任何动作，字段值无观测面）。 */
function missLookup(): VideoLookup {
  const miss: VideoLookup = {
    found: false, kind: 'video', name: '', size: 0, contentType: '', uri: '',
    headers: null, cookies: null
  };
  return miss;
}

/** Adaptive descriptor for one tracked HLS/DASH/dual-source entry; null when the capture cannot
 * be downloaded by the adaptive engine (it then stays an explicit unsupported item). */
export function adaptiveSourceOf(video: TrackedVideo): AdaptiveSourceDescriptor | null {
  const source: AdaptiveSourceDescriptor = new AdaptiveSourceDescriptor();
  source.primaryUrl = video.uri;
  if (video.kind === 'hls') {
    source.kind = 'hls';
    source.secondaryUrl = video.uri2;
  } else if (video.kind === 'dash') {
    source.kind = 'dash';
    source.videoSegments = video.videoSegments.slice();
    source.audioSegments = video.audioSegments.slice();
    source.videoMime = video.videoMimeType;
    source.audioMime = video.audioMimeType;
    source.duration = video.duration;
  } else if (video.kind === 'yt') {
    source.kind = 'dual';
    source.secondaryUrl = video.uri2;
    const videoMime: string = mimeFromUrlQuery(video.uri);
    const audioMime: string = mimeFromUrlQuery(video.uri2);
    source.videoMime = videoMime.length > 0 ? videoMime : 'video/mp4';
    source.audioMime = audioMime.length > 0 ? audioMime : 'audio/mp4';
  } else {
    return null;
  }
  return validateAdaptiveSource(source) ? source : null;
}

/** 视频列表桥侧数据半区单例（ApplicationContext.VideoTracker 对应物）。 */
export class CapturedVideoTracker {
  private static instance: CapturedVideoTracker | undefined = undefined;

  /** 四张插入序表（U6.1 仅 video 表有写入方 addSingleSourceVideo；另三表为 U6.2 预留，
   * 读取路径全部就位，§3-5） */
  private ytMap: Map<string, TrackedVideo> = new Map();
  private videoMap: Map<string, TrackedVideo> = new Map();
  private hlsMap: Map<string, TrackedVideo> = new Map();
  private dashMap: Map<string, TrackedVideo> = new Map();
  /** 监听器注册表（Config.onConfigChanged 同款数组注册表） */
  private listeners: TrackerListener[] = [];

  private constructor() {
  }

  static getInstance(): CapturedVideoTracker {
    if (CapturedVideoTracker.instance === undefined) {
      CapturedVideoTracker.instance = new CapturedVideoTracker();
    }
    return CapturedVideoTracker.instance;
  }

  /** GetVideoList（VideoTracker.cs:130-158）：yt→video→hls→dash 拼接（插入序）后按 dateAdded
   * 升序稳定排序（Array.sort 稳定=源 List.Sort 不稳定但拼接序即观测序的保守超集）→ 逐项映射
   * BridgeVideoItem{id, text:file, info:description, tabId}（MediaInfo 四属性投影，:391-395）。 */
  getVideoList(): BridgeVideoItem[] {
    const all: TrackedVideo[] = [];
    this.appendEntriesOf(this.ytMap, all);
    this.appendEntriesOf(this.videoMap, all);
    this.appendEntriesOf(this.hlsMap, all);
    this.appendEntriesOf(this.dashMap, all);
    all.sort((a: TrackedVideo, b: TrackedVideo): number => a.dateAdded - b.dateAdded);
    const out: BridgeVideoItem[] = [];
    for (let i = 0; i < all.length; i++) {
      const item: BridgeVideoItem = {
        id: all[i].id,
        text: all[i].file,
        info: all[i].description,
        tabId: all[i].tabId
      };
      out.push(item);
    }
    return out;
  }

  /** ClearVideoList（VideoTracker.cs:27-34）：清四表 + Config.broadcastConfigChange
   * （ApplicationContext.BroadcastConfigChange 同位，既有公共 API 复用不新增广播机制）。 */
  clearVideoList(): void {
    this.ytMap.clear();
    this.hlsMap.clear();
    this.dashMap.clear();
    this.videoMap.clear();
    Config.getInstance().broadcastConfigChange();
  }

  /** UpdateMediaTitle（VideoTracker.cs:47-89）：**仅扫 yt+video 两表**；tabUrl 空（含 null）
   * 跳过、精确等值命中；效果 file=generateUpdatedFileName(file, tabTitle)（扩展名保留）→
   * 逐命中项触发 onMediaUpdated。 */
  updateMediaTitle(tabUrl: string, tabTitle: string): void {
    this.renameInTable(this.ytMap, tabUrl, tabTitle);
    this.renameInTable(this.videoMap, tabUrl, tabTitle);
  }

  /** 单源视频登记（VideoTracker.cs:260-275 单源重载投影）：id=UUID、dateAdded=Date.now()、
   * 入 video 表、触发 onMediaAdded + broadcastConfigChange（ShowMediaNotification 通知半区
   * U6.2 拍板降级：log+事件+广播，系统通知 U6.3 端到端接线时评估，§4-9）。 */
  addSingleSourceVideo(file: string, size: number, contentType: string, uri: string,
    headers: BridgeHeaders | null, cookies: string | null, description: string,
    tabId: string | null, tabUrl: string | null): void {
    const id: string = util.generateRandomUUID();
    const video: TrackedVideo = new TrackedVideo(id, 'video', file, size, contentType, uri,
      headers, cookies, description, tabId ?? '', tabUrl ?? '', Date.now());
    this.videoMap.set(id, video);
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'single source video added kind=video size=' +
      String(size));
    this.fireMediaAdded(video);
    Config.getInstance().broadcastConfigChange();
  }

  /** 双源视频登记（VideoTracker.cs:242-258 DualSource 重载投影，U6.2）：入 **yt** 表；事件序
   * id=UUID→入表→onMediaAdded→broadcastConfigChange（同单源重载 §2.5）。 */
  addDualSourceVideo(file: string, size: number, uri1: string, uri2: string,
    headers1: BridgeHeaders | null, headers2: BridgeHeaders | null, cookies1: string | null,
    cookies2: string | null, description: string, tabId: string | null,
    tabUrl: string | null): void {
    const id: string = util.generateRandomUUID();
    const video: TrackedVideo = new TrackedVideo(id, 'yt', file, size, '', uri1, headers1, cookies1,
      description, tabId ?? '', tabUrl ?? '', Date.now());
    video.uri2 = uri2;
    video.headers2 = headers2;
    video.cookies2 = cookies2;
    this.ytMap.set(id, video);
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'dual source video added kind=yt size=' +
      String(size));
    this.fireMediaAdded(video);
    Config.getInstance().broadcastConfigChange();
  }

  /** HLS 视频登记（VideoTracker.cs:277-293 MultiSourceHLS 重载投影，U6.2）：入 **hls** 表；
   * size 源不设→0、contentType ''（§2.4）；uri=VideoUri、uri2=AudioUri。 */
  addHlsVideo(file: string, videoUri: string, audioUri: string, headers: BridgeHeaders | null,
    cookies: string | null, description: string, tabId: string | null,
    tabUrl: string | null): void {
    const id: string = util.generateRandomUUID();
    const video: TrackedVideo = new TrackedVideo(id, 'hls', file, 0, '', videoUri, headers, cookies,
      description, tabId ?? '', tabUrl ?? '', Date.now());
    video.uri2 = audioUri;
    this.hlsMap.set(id, video);
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'hls video added kind=hls');
    this.fireMediaAdded(video);
    Config.getInstance().broadcastConfigChange();
  }

  /** DASH 视频登记（VideoTracker.cs:295-311 MultiSourceDASH 重载投影，U6.2）：入 **dash** 表；
   * size 源不设→0、contentType ''；uri=manifest URL（U7.1 消费）；duration=max(video,audio)。 */
  addDashVideo(file: string, manifestUrl: string, videoSegments: string[], audioSegments: string[],
    headers: BridgeHeaders | null, cookies: string | null, duration: number, videoMime: string,
    audioMime: string, description: string, tabId: string | null, tabUrl: string | null): void {
    const id: string = util.generateRandomUUID();
    const video: TrackedVideo = new TrackedVideo(id, 'dash', file, 0, '', manifestUrl, headers,
      cookies, description, tabId ?? '', tabUrl ?? '', Date.now());
    video.videoSegments = videoSegments.slice();
    video.audioSegments = audioSegments.slice();
    video.duration = duration;
    video.videoMimeType = videoMime;
    video.audioMimeType = audioMime;
    this.dashMap.set(id, video);
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'dash video added kind=dash segments=' +
      String(videoSegments.length + audioSegments.length));
    this.fireMediaAdded(video);
    Config.getInstance().broadcastConfigChange();
  }

  /** getTrackedVideos 富投影（设计书 §2.6，U6.2）：与 getVideoList 同序（yt→video→hls→dash
   * 拼接 + dateAdded 升序稳定排序），返回 TrackedVideo 全字段（VideoCapture 页分组需要 kind；
   * **getVideoList 与 /sync SyncFields 契约冻结零改动**——事件面零破坏红线）。 */
  getTrackedVideos(): TrackedVideo[] {
    const all: TrackedVideo[] = [];
    this.appendEntriesOf(this.ytMap, all);
    this.appendEntriesOf(this.videoMap, all);
    this.appendEntriesOf(this.hlsMap, all);
    this.appendEntriesOf(this.dashMap, all);
    all.sort((a: TrackedVideo, b: TrackedVideo): number => a.dateAdded - b.dateAdded);
    return all;
  }

  /** AddVideoDownload 动作段（VideoTracker.cs:313-370 逐行；U6.2 自 BridgeRoutes.videoDownloadAction
   * 移入——U6.1 报告 §8-a 收敛项）：
   * 1. videoId 为 null/undefined → throw（ContainsKey(null)→ArgumentNullException→断连 1:1，
   *    §4-11 锚随迁——不得改静默）；
   * 2. 查表序 yt→video→hls→dash；仅 yt/video 两表有 LinkAccepted 前置守卫位（:321/:329 恒 false
   *    注释锚随迁，lookupVideoDownload 内登记）；未命中静默；
   * 3. 自动分支（StartDownloadAutomatically && isFFmpegOK）：startBridgeAutoDownload(sanitize(
   *    name), size, uri, ExtensionOnly)——单源 video 表语义；**yt/hls/dash 在 IsFFmpegOK 降级恒
   *    false 下不可达，U7.2 接 IsFFmpegInstalled 真值后接线 StartVideoDownload 分表语义**；
   * 4. 对话框分支：fireBridgeUiEvent(onShowVideoDownloadDialog(id, name, size, contentType))——
   *    **name 未消毒**（源 :367 传原名；:361 只在自动分支 Sanitize）。 */
  async addVideoDownload(videoId: string | null): Promise<void> {
    const snapshot: VideoDownloadSnapshot | null = this.snapshotVideoDownload(videoId);
    if (snapshot !== null) {
      await this.submitVideoDownload(snapshot);
    }
  }

  snapshotVideoDownloads(ids: string[]): VideoDownloadSnapshot[] {
    const snapshots: VideoDownloadSnapshot[] = [];
    for (let i = 0; i < ids.length; i++) {
      const snapshot: VideoDownloadSnapshot | null = this.snapshotVideoDownload(ids[i]);
      if (snapshot !== null) {
        snapshots.push(snapshot);
      }
    }
    return snapshots;
  }

  private snapshotVideoDownload(videoId: string | null): VideoDownloadSnapshot | null {
    const lookup: VideoLookup = this.lookupVideoDownload(videoId);
    if (!lookup.found) {
      return null;
    }
    const id: string = videoId ?? '';
    const request: DownloadCreationRequest = bridgeRequestOf(lookup.name, lookup.size, lookup.uri,
      FileNameFetchMode.ExtensionOnly, lookup.headers, lookup.cookies);
    if (lookup.kind !== 'video') {
      // Snapshot the full adaptive source before any await: /clear or later captures cannot change it.
      const tracked: TrackedVideo | null = this.findTracked(id);
      request.adaptive = tracked !== null ? adaptiveSourceOf(tracked) : null;
    }
    const snapshot: VideoDownloadSnapshot = {
      id: id, kind: lookup.kind, contentType: lookup.contentType, request: request,
      automatic: lookup.kind === 'video' && Config.getInstance().getStartDownloadAutomatically() && this.isFFmpegOK(id)
    };
    return snapshot;
  }

  async submitVideoDownload(snapshot: VideoDownloadSnapshot): Promise<void> {
    const request: DownloadCreationRequest = snapshot.request;
    if (snapshot.kind === 'video' && await LinkRefresher.getInstance().tryAcceptSingleSource(request)) {
      return;
    }
    if (snapshot.automatic && snapshot.kind === 'video') {
      await startBridgeAutoDownload(sanitizeFileName(request.name), request.size, request.url,
        FileNameFetchMode.ExtensionOnly, request.requestContext);
    } else {
      // Snapshot credentials now; /clear or title changes must not alter an acknowledged request.
      // Non-normal media remains pending for an explicit unsupported-capability UI, never an HTTP fallback.
      await enqueueBridgeRequests([request], 'video', snapshot.kind, snapshot.id);
      hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'video download dialog event kind=' + snapshot.kind);
      fireBridgeUiEvent((l: BridgeUiEvents): void => {
        const cb: ((videoId: string, name: string, size: number, contentType: string) => void) |
          undefined = l.onShowVideoDownloadDialog;
        if (cb !== undefined) {
          cb(snapshot.id, request.name, request.size, snapshot.contentType);
        }
      });
    }
  }

  /** 按 vid 查找（VideoTracker.cs:313-355 读取半区）：**videoId 为 null/undefined → throw
   * Error**（ContainsKey(null)→ArgumentNullException→断连的 1:1，§4-11——不得改成静默忽略）；
   * 查找序 yt→video→hls→dash；未命中 → {found:false}（静默无操作锚）。LinkRefresher.
   * LinkAccepted 前置守卫（:321/:329）未迁移恒 false，注释锚登记（§4-3）。 */
  lookupVideoDownload(videoId: string | null): VideoLookup {
    if (videoId === null || videoId === undefined) {
      throw new Error('vid required');
    }
    // LinkAccepted 守卫位（源 :321/:329 if (LinkRefresher.LinkAccepted(..)) return）——
    // U6.1 未迁移恒 false，不建死代码（Index.ets:468 注释锚同款登记法，§4-3）
    const yt: TrackedVideo | undefined = this.ytMap.get(videoId);
    if (yt !== undefined) {
      return this.lookupOf(yt);
    }
    const video: TrackedVideo | undefined = this.videoMap.get(videoId);
    if (video !== undefined) {
      return this.lookupOf(video);
    }
    const hls: TrackedVideo | undefined = this.hlsMap.get(videoId);
    if (hls !== undefined) {
      return this.lookupOf(hls);
    }
    const dash: TrackedVideo | undefined = this.dashMap.get(videoId);
    if (dash !== undefined) {
      return this.lookupOf(dash);
    }
    return missLookup();
  }

  private findTracked(id: string): TrackedVideo | null {
    return this.ytMap.get(id) ?? this.hlsMap.get(id) ?? this.dashMap.get(id) ?? this.videoMap.get(id) ?? null;
  }

  /** IsFFmpegRequiredForDownload（VideoTracker.cs:91-94）：yt/hls/dash 含 id → true
   * （video 表=单源恒不需要）。 */
  isFFmpegRequiredForDownload(id: string): boolean {
    return this.ytMap.has(id) || this.dashMap.has(id) || this.hlsMap.has(id);
  }

  /** IsFFmpegOK（VideoTracker.cs:372-376）——U6.2 自 BridgeRoutes 移入**私有化**（唯一调用方
   * addVideoDownload）：!IsFFmpegRequiredForDownload → true；否则 FFmpegMediaProcessor.
   * IsFFmpegInstalled() 未迁移恒 false（U6.1 §4-6 降级不变，U7.2 接真值）。 */
  private isFFmpegOK(id: string): boolean {
    if (!this.isFFmpegRequiredForDownload(id)) {
      return true;
    }
    return false;
  }

  /** 监听器注册/注销（重复引用幂等；off 传同一对象引用移除）。 */
  registerTrackerListener(l: TrackerListener): void {
    if (this.listeners.indexOf(l) < 0) {
      this.listeners.push(l);
    }
  }

  unregisterTrackerListener(l: TrackerListener): void {
    const idx: number = this.listeners.indexOf(l);
    if (idx >= 0) {
      this.listeners.splice(idx, 1);
    }
  }

  // ────────────── 文件内私有 ──────────────

  private appendEntriesOf(table: Map<string, TrackedVideo>, out: TrackedVideo[]): void {
    table.forEach((value: TrackedVideo) => {
      out.push(value);
    });
  }

  /** 单表标题回写（VideoTracker.cs:49-88 单表循环体）：tabUrl 空（含 null 空串）跳过；
   * 精确等值命中 → generateUpdatedFileName + onMediaUpdated。 */
  private renameInTable(table: Map<string, TrackedVideo>, tabUrl: string, tabTitle: string): void {
    const entries: TrackedVideo[] = [];
    this.appendEntriesOf(table, entries);
    for (let i = 0; i < entries.length; i++) {
      const entry: TrackedVideo = entries[i];
      if (entry.tabUrl.length === 0) {
        continue;
      }
      if (entry.tabUrl === tabUrl) {
        entry.file = generateUpdatedFileName(entry.file, tabTitle);
        this.fireMediaUpdated(entry);
      }
    }
  }

  private lookupOf(video: TrackedVideo): VideoLookup {
    const hit: VideoLookup = {
      found: true,
      kind: video.kind,
      name: video.file,
      size: video.size,
      contentType: video.contentType,
      uri: video.uri,
      headers: video.headers,
      cookies: video.cookies
    };
    return hit;
  }

  /** 逐监听器 try/catch 吞异常 + 遍历拷贝（回调内注销塌缩防护，Config.broadcastConfigChange
   * 同款，设计书 §8 风险表）。 */
  private fireMediaAdded(video: TrackedVideo): void {
    const item: BridgeVideoItem = {
      id: video.id, text: video.file, info: video.description, tabId: video.tabId
    };
    const snapshot: TrackerListener[] = this.listeners.slice();
    for (let i = 0; i < snapshot.length; i++) {
      const cb: ((item: BridgeVideoItem) => void) | undefined = snapshot[i].onMediaAdded;
      if (cb === undefined) {
        continue;
      }
      try {
        cb(item);
      } catch (e) {
        const err = e as BusinessError;
        hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s', 'onMediaAdded listener failed errCode=' +
          String(err.code) + ' errMessage=' + (err.message ?? ''));
      }
    }
  }

  private fireMediaUpdated(video: TrackedVideo): void {
    const item: BridgeVideoItem = {
      id: video.id, text: video.file, info: video.description, tabId: video.tabId
    };
    const snapshot: TrackerListener[] = this.listeners.slice();
    for (let i = 0; i < snapshot.length; i++) {
      const cb: ((item: BridgeVideoItem) => void) | undefined = snapshot[i].onMediaUpdated;
      if (cb === undefined) {
        continue;
      }
      try {
        cb(item);
      } catch (e) {
        const err = e as BusinessError;
        hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s', 'onMediaUpdated listener failed errCode=' +
          String(err.code) + ' errMessage=' + (err.message ?? ''));
      }
    }
  }
}
