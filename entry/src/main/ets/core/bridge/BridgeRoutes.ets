/*
 * U6.1 八路由业务编排 → U6.2 收敛 a/b/c+嗅探链补锚（设计书 u6-2 §3.3/§3.6/§3.7）。
 * handleRoute 按 classifyRoute 序号分派八路由业务（IpcHttpMessageProcessor.cs:47-86 逐端点）；
 * buildSyncResponse 为八路由成功后的统一应答组装（OnSyncMessage :79 的唯一应答出口）。
 * 应答二分铁律（§2.2）：八条已知路由业务成功（含 null 体早退、/vid 未命中静默、/args 空表）
 * 一律由 BridgeServer 统一回 200+sync JSON；业务异常（坏 JSON/形状不符/缺 vid/缺 requestHeaders）
 * throw 穿透到泵 closeSilently 断连不回任何字节——本文件**只对 /args 内层吞异常**
 * （ArgsProcessor.cs:130-133，§3.6），其余任何 catch-转-404/500 都是违规。
 * U6.2 增量（§1-#5）：
 *   收敛 a——BridgeUiEvents/监听器注册/fireBridgeUiEvent/startBridgeAutoDownload/pending 列表
 *   移 BridgeActions.ets（本文件 import 消费；/vid 与 --media-vid 改调 tracker.addVideoDownload
 *   ——动作半区收拢进 CapturedVideoTracker）；「/download 的 addDownloadAction」留本文件
 *   （源拓扑在 ApplicationCore.AddDownload :208-236 而非 tracker，设计书 §3.1）。
 *   收敛 b——/link pending 存 {url,file} 对（addPendingBatchLink；onShowBatchSelection 载荷
 *   PendingBatchLink[]，U6.3 勾选窗按 R4-F5 消费，§3.6）。
 *   收敛 c——processNormalVideo 登记 contentType 实参改 ''（源 ProcessNormalVideo 不设
 *   ContentType=null，VideoUrlHelper.cs:677-684 无 ContentType 赋值行；U6.1 R2-F3 闭环，§3.7）。
 *   R1-F2 复核修正——F2 族的空串 file 处理收窄回**源语义**（BridgeJson 空串原样保留 ''；本文件
 *   /link 与 /download 自动分支的 file 经 sanitizeOrEmpty 空 in 空 out；/media normal 由
 *   processNormalVideo 既有 IsNullOrEmpty 二次回退承接零改动；VideoSniffAlgo 的 HandleDashAudio/
 *   CreateDual 同镜像——源侧三处空串 file 均不回退，见 BridgeJson.buildBridgeMessage 注释）。
 *   嗅探链补锚（§3.3）——processMediaMessage ②IsYtFormat ③IsHLS/IsHLSUrl ④IsDASH/IsDASHUrl
 *   ⑤ProcessYtDashSegment 五锚换真实现：**四段相互独立非互斥**（源四 if 无 else——②③⑤分支
 *   返回值不短路后续判定，保持顺序执行不得加 else/return）；manifest 三分支只落识别+两表写入
 *   （写入点=源 manifest 拉取之前的源序 :187-191/:337-341，网络无关即消除 U6.1 §7-3 暂态）；
 *   DownloadManifest/HlsParser/MpdParser/YoutubeDataFormatParser 留 U6.4/U7.1 锚（log 后继续）。
 *   isMediaFragmentGuard 改 sha1Hex 键查询（§3.4——referersToSkip 写入方在 HLS/DASH 识别锚，
 *   调用点零改动）；**扩展端八层过滤纯规格件不接入本链**（§0-1 红线——源拓扑该过滤只在扩展端
 *   request-watcher.js:105，服务端再跑即双重过滤；该规格件仅存于 VideoSniffAlgo 供用例表与
 *   U6.3 扩展复用对照）。
 * 对照源码（本会话只读核实，未改 resourses/ 下任何文件）：
 *   IpcHttpMessageProcessor.cs:88-179 —— 四路由体解析+七字段映射+剥离接线（解析半区在 BridgeJson）。
 *   VideoUrlHelper.cs:35-65  —— ProcessMediaMessage 分派链链序（本单元五锚全量补真）。
 *   ArgsProcessor.cs:15-134  —— Process 分派序+外层吞异常；:155-194 文法（解析半区在 BridgeJson）。
 *   ApplicationCore.cs:188-236 —— AddBatchLinks/AddDownload 状态机（LinkAccepted 守卫注释锚恒
 *                false §4-3；StartDownloadAutomatically=true 自动开下 / false 对话框）。
 * 有意差异（设计书 §4）：请求头/Cookie 不注入引擎（§4-4，U6.3 接通）；F1（--media-tab-url 缺
 *   title 仍改名）延后 U6.3（超本单元授权面，§4-14）；桥自动链不更新 Index 内存 DS（§4-10）；
 *   --quit/--first-run/--background 主窗激活 → onAppCommand 事件（§4-5）。
 * 业务日志：hilog domain 0x0000、tag 'BridgeRoutes'，绝不输出探针标记（§0-6）；日志不含请求体。
 * ArkTS 红线：无 any/解构/for...in/正则字面量；对象字面量均具 interface/Record 类型；throw 只抛 Error。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  BridgeResponse,
  BridgeHeaders,
  BridgeVideoItem,
  SyncFields,
  SYNC_CONTENT_TYPE,
  SYNC_CACHE_CONTROL,
  SYNC_MEDIA_TYPES,
  SYNC_TABS_WATCHER,
  SYNC_MATCHING_HOSTS,
  utf8Decode,
  utf8Encode,
  buildSyncJson
} from './BridgeProtocol';
import {
  BridgeExtData,
  BridgeMessage,
  ArgsMap,
  parseExtData,
  parseExtDataArray,
  parseArgsArray,
  parseArgs,
  parseHeaderArg,
  buildBridgeMessage,
  headerValueFirst,
  getContentLengthOf
} from './BridgeJson';
import {
  SniffState,
  createSniffState,
  isNormalVideo,
  extFromMedia,
  qualityText,
  isYtFormat,
  isHLS,
  isHLSUrl,
  isDASH,
  isDASHUrl,
  processYtDashSegment,
  processDashVideo,
  sha1Hex,
  DashCaptureItem,
  DashDualCapture,
  DashMultiCapture,
  DashSingleCapture,
  SegSink,
  SegSingle,
  SegDual
} from './VideoSniffAlgo';
import { DashPair } from '../adaptive/DashModel';
import { parseDashManifest } from '../adaptive/DashXmlFeed';
import { resolveHlsUrl } from '../adaptive/HlsUrlResolver';
import { parseHlsMasterPlaylist, parseHlsMediaPlaylist, hlsQuality, guessHlsContainer } from '../adaptive/HlsParser';
import { HlsPlaylist, HlsPlaylistContainer } from '../adaptive/HlsModel';
import { ManifestClient, ManifestFetchResult } from '../adaptive/ManifestClient';
import { DownloadRequestContext } from '../../model/DownloadRequestContext';
import { CapturedVideoTracker } from './CapturedVideoTracker';
import { LinkRefresher } from './LinkRefresher';
import {
  BridgeUiEvents,
  PendingBatchLink,
  fireBridgeUiEvent,
  startBridgeAutoDownload,
  bridgeRequestOf,
  enqueueBridgeRequests
} from './BridgeActions';
import { Config } from '../Config';
import { sanitizeFileName, fileNameFromUrl } from '../util/FileNames';
import { FileNameFetchMode } from '../../model/DownloadTypes';
import { DownloadCreationRequest } from '../../model/DownloadCreationRequest';

/** 业务日志面（domain 0x0000 / tag 'BridgeRoutes'） */
const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'BridgeRoutes';

/** Content-Length 全串十进制门（processNormalVideo 的 long.Parse 1:1：缺省/垃圾 → throw 断连，
 * 设计书 §3.4-4——与 BridgeJson.getContentLengthOf 的吞异常→0 语义不同，此处是登记前的强门） */
const INT64_DECIMAL: RegExp = new RegExp('^[+-]?[0-9]+$');

/** 共享嗅探状态单例（VideoUrlHelper 静态件的实例化持有；单线程事件循环单写者，§3.8——
 * S1 /clear 不清嗅探态（源 ClearVideoList 只清四表），探针 S5/S6 依赖前序状态属预期） */
const sharedSniffState: SniffState = createSniffState();

/** YT-DASH 段配对登记回调（设计书 §3.5 写入接线：VideoSniffAlgo 零 @kit 不 import tracker，
 * 本处组装回调调 tracker 单条写入方——onSingle→addSingleSourceVideo / onDual→addDualSourceVideo）。 */
const mediaSegSink: SegSink = {
  onSingle: (seg: SegSingle): void => {
    CapturedVideoTracker.getInstance().addSingleSourceVideo(seg.file, seg.size, seg.contentType,
      seg.uri, seg.headers, seg.cookies, seg.displayText, seg.tabId, seg.tabUrl);
  },
  onDual: (seg: SegDual): void => {
    CapturedVideoTracker.getInstance().addDualSourceVideo(seg.file, seg.size, seg.uri1, seg.uri2,
      seg.headers1, seg.headers2, seg.cookies1, seg.cookies2, seg.displayText, seg.tabId, seg.tabUrl);
  }
};

/**
 * 八路由业务分派（IpcHttpMessageProcessor.cs:51-78 switch 投影；routeIndex=classifyRoute 产物）。
 * 业务异常 throw 穿透（→泵断连）；/args 内层吞异常（§3.6）。routeIndex 越界视同未知（防御锚，
 * 调用方 classifyRoute 已挡 -1）。body 为已按 Content-Length 截断的请求体字节。
 */
export async function handleRoute(routeIndex: number, body: Uint8Array): Promise<void> {
  if (routeIndex === 0) {
    // /sync：无业务（:53-54）
    return;
  }
  if (routeIndex === 1) {
    await handleDownloadRoute(body);
    return;
  }
  if (routeIndex === 2) {
    handleMediaRoute(body);
    return;
  }
  if (routeIndex === 3) {
    handleTabUpdateRoute(body);
    return;
  }
  if (routeIndex === 4) {
    await handleVidRoute(body);
    return;
  }
  if (routeIndex === 5) {
    // /clear：清四表+广播（:67-69；体不解析）
    CapturedVideoTracker.getInstance().clearVideoList();
    return;
  }
  if (routeIndex === 6) {
    await handleLinkRoute(body);
    return;
  }
  if (routeIndex === 7) {
    await handleArgsRoute(body);
    return;
  }
  throw new Error('Unsupported route index: ' + String(routeIndex));
}

/** /download（IpcHttpMessageProcessor.cs:118-136 + ApplicationCore.cs:208-236）：
 * null 体早退（仍回 sync）；七字段映射+剥离（BridgeJson 门）→ AddDownload 动作投影。 */
async function handleDownloadRoute(body: Uint8Array): Promise<void> {
  const data: BridgeExtData | null = parseExtData(utf8Decode(body));
  if (data === null) {
    return;
  }
  const msg: BridgeMessage = buildBridgeMessage(data);
  await addDownloadAction(msg);
}

/** /media（IpcHttpMessageProcessor.cs:138-156 + VideoUrlHelper.cs:35-65 U6.1 子集）。 */
function handleMediaRoute(body: Uint8Array): void {
  const data: BridgeExtData | null = parseExtData(utf8Decode(body));
  if (data === null) {
    return;
  }
  const msg: BridgeMessage = buildBridgeMessage(data);
  processMediaMessage(msg);
}

/** /tab-update（IpcHttpMessageProcessor.cs:108-116）：null 早退；UpdateMediaTitle 直传两字段
 * （**不做七字段映射不剥离**，源同）。 */
function handleTabUpdateRoute(body: Uint8Array): void {
  const data: BridgeExtData | null = parseExtData(utf8Decode(body));
  if (data === null) {
    return;
  }
  CapturedVideoTracker.getInstance().updateMediaTitle(data.tabUrl ?? '', data.tabTitle ?? '');
}

/** /vid（IpcHttpMessageProcessor.cs:98-106 + VideoTracker.cs:313-370 动作段，U6.2 收敛 a）：
 * null 早退；vid 缺失 → addVideoDownload 内 throw（断连 1:1，§4-11 锚随迁）；未命中静默。 */
async function handleVidRoute(body: Uint8Array): Promise<void> {
  const data: BridgeExtData | null = parseExtData(utf8Decode(body));
  if (data === null) {
    return;
  }
  await CapturedVideoTracker.getInstance().addVideoDownload(data.vid);
}

/** /link（IpcHttpMessageProcessor.cs:158-179 + ApplicationCore.cs:188-206）：null 早退；逐项
 * 七字段映射+剥离（任一项映射异常 → 整体断连，源 Select+RemoveBlockedHeaders 同貌）；空 url
 * 跳过；file=sanitize(file ?? fileNameFromUrl(url))——**U6.2 收敛 b：存 {url,file} 对**
 * （addPendingBatchLink；U6.1 现实现丢弃 file 只存 url，U6.3 勾选窗按 R4-F5 消费，§3.6）；
 * 收集 → pending 列表+log+批量事件（ShowDownloadSelectionWindow 降级，§4-5——载荷
 * PendingBatchLink[]）。 */
async function handleLinkRoute(body: Uint8Array): Promise<void> {
  const arr: BridgeExtData[] | null = parseExtDataArray(utf8Decode(body));
  if (arr === null) {
    return;
  }
  const messages: BridgeMessage[] = [];
  for (let i = 0; i < arr.length; i++) {
    messages.push(buildBridgeMessage(arr[i]));
  }
  const links: PendingBatchLink[] = [];
  const requests: DownloadCreationRequest[] = [];
  for (let i = 0; i < messages.length; i++) {
    const msg: BridgeMessage = messages[i];
    const url: string | null = msg.url;
    if (url === null || url.length === 0) {
      continue;
    }
    const file: string = sanitizeOrEmpty(msg.file !== null ? msg.file : fileNameFromUrl(url));
    requests.push(bridgeRequestOf(file, getContentLengthOf(msg.responseHeaders), url,
      FileNameFetchMode.FileNameAndExtension, msg.requestHeaders, msg.cookies));
    const link: PendingBatchLink = { url: url, file: file };
    links.push(link);
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'batch link queued file=' + file);
  }
  if (links.length > 0) {
    await enqueueBridgeRequests(requests, 'batch');
    fireBridgeUiEvent((l: BridgeUiEvents): void => {
      const cb: ((items: PendingBatchLink[]) => void) | undefined = l.onShowBatchSelection;
      if (cb !== undefined) {
        cb(links);
      }
    });
  }
}

/** /args（IpcHttpMessageProcessor.cs:88-96 + ArgsProcessor.cs:16-134）：null/空表早退；
 * **内层整体 try/catch 吞异常**（:130-133——键缺失等业务异常只记日志不外抛，仍回 sync 应答，
 * 应答二分铁律的唯一例外）。 */
async function handleArgsRoute(body: Uint8Array): Promise<void> {
  const args: string[] | null = parseArgsArray(utf8Decode(body));
  if (args === null || args.length === 0) {
    return;
  }
  try {
    await dispatchArgs(args);
  } catch (e) {
    const err = e as BusinessError;
    hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s', 'args processing failed errCode=' +
      String(err.code) + ' errMessage=' + (err.message ?? ''));
  }
}

/** ArgsProcessor.Process 主体（:20-128 分派序 1:1；--url 块后**不 return** 落穿 --quit/激活段）。 */
async function dispatchArgs(args: string[]): Promise<void> {
  const map: ArgsMap = parseArgs(args);
  if (map['--media-tab-url'] !== undefined) {
    // :21-27。源 ArgsProcessor.cs:23-24 取 --media-tab-title 在 UpdateMediaTitle 之前、缺键
    // KeyNotFoundException 被 :130-133 吞掉即整体中止（零改名）——缺 title 键时不执行改名
    // （U6.2 IR-F1 修复：缺省 '' 兜底会把命中条目经 sanitizeFileName('')='file' 统一误改名）
    const url: string = map['--media-tab-url'][0];
    const titleArr: string[] | undefined = map['--media-tab-title'];
    if (titleArr === undefined || titleArr.length === 0) {
      return;
    }
    CapturedVideoTracker.getInstance().updateMediaTitle(url, titleArr[0]);
    return;
  }
  if (map['--media-vid'] !== undefined) {
    // :28-33（同 /vid 核心；U6.2 收敛 a——动作收拢进 tracker.addVideoDownload）
    await CapturedVideoTracker.getInstance().addVideoDownload(map['--media-vid'][0]);
    return;
  }
  if (map['--media-clear'] !== undefined) {
    // :34-37
    CapturedVideoTracker.getInstance().clearVideoList();
    return;
  }
  const urlArr: string[] | undefined = map['--url'];
  if (urlArr !== undefined && urlArr.length === 1) {
    // :39-98 组装 message：requestHeaders=空容器（**本路径非 null**，:44）；不做头剥离（源无调用）
    const emptyReq: BridgeHeaders = { names: [], values: [] };
    const emptyRes: BridgeHeaders = { names: [], values: [] };
    const msg: BridgeMessage = {
      url: urlArr[0],
      method: 'GET',
      requestHeaders: emptyReq,
      responseHeaders: emptyRes,
      cookies: null,
      file: null,
      tabUrl: null,
      tabId: null,
      mediaSourceUrl: null
    };
    populateHeaderArgs('-H', msg, map);
    populateHeaderArgs('--header', msg, map);
    if (map['--cookie'] !== undefined) {
      msg.cookies = map['--cookie'][0];
    }
    if (map['--output'] !== undefined) {
      msg.file = map['--output'][0]; // 不 sanitize——源此路径原值直传（:57-60）
    }
    if (map['-o'] !== undefined) {
      msg.file = map['-o'][0]; // 后者覆盖（:61-64）
    }
    if (map['-C'] !== undefined) {
      msg.cookies = map['-C'][0]; // 后者覆盖（:65-68）
    }
    if (map['--known-file-size'] !== undefined) {
      // emptyRes 与 msg.responseHeaders 同一引用（构造处注入）——直接传非空局部容器，
      // 避免 BridgeHeaders|null 传非空参数的编译错（Possibly Null 窄化，写入同一字典）
      setHeaderValues(emptyRes, 'Content-Length', map['--known-file-size']);
    }
    if (map['--known-mime-type'] !== undefined) {
      setHeaderValues(emptyRes, 'Content-Type', map['--known-mime-type']);
    }
    if (map['--media-source-url'] !== undefined) {
      msg.mediaSourceUrl = map['--media-source-url'][0]; // 字段保留，U6.2 消费（:77-80）
    }
    if (map['--tab-url'] !== undefined) {
      msg.tabUrl = map['--tab-url'][0];
    }
    if (map['--tab-id'] !== undefined) {
      msg.tabId = map['--tab-id'][0];
    }
    if (map['--media'] === undefined) {
      await addDownloadAction(msg);
    } else {
      processMediaMessage(msg);
    }
  }
  if (map['--quit'] !== undefined) {
    // :100-104 Environment.Exit 降级 → 事件（§4-5）
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'received quit args');
    fireBridgeUiEvent((l: BridgeUiEvents): void => {
      const cb: ((cmd: string, argv: string[]) => void) | undefined = l.onAppCommand;
      if (cb !== undefined) {
        cb('quit', []);
      }
    });
  }
  if (map['--background'] === undefined) {
    // :106-128 ShowAndActivate/RunOnLogon+ShowBrowserMonitoringDialog 降级 → 事件（§4-5）
    const cmd: string = map['--first-run'] !== undefined ? 'first-run' : 'activate';
    fireBridgeUiEvent((l: BridgeUiEvents): void => {
      const cb: ((cmd: string, argv: string[]) => void) | undefined = l.onAppCommand;
      if (cb !== undefined) {
        cb(cmd, []);
      }
    });
  }
}

/** PopulateHeaders（ArgsProcessor.cs:136-153）：逐项 parseHeaderArg，键已存在追加值表否则新建。 */
function populateHeaderArgs(headerArgName: string, msg: BridgeMessage, map: ArgsMap): void {
  const headers: string[] | undefined = map[headerArgName];
  if (headers === undefined) {
    return;
  }
  const req: BridgeHeaders | null = msg.requestHeaders;
  if (req === null) {
    return;
  }
  for (let i = 0; i < headers.length; i++) {
    const kv: string[] | null = parseHeaderArg(headers[i]);
    if (kv !== null) {
      const idx: number = req.names.indexOf(kv[0]);
      if (idx >= 0) {
        req.values[idx].push(kv[1]);
      } else {
        req.names.push(kv[0]);
        const single: string[] = [kv[1]];
        req.values.push(single);
      }
    }
  }
}

/** ResponseHeaders 整表赋值（ArgsProcessor.cs:71/:75 索引器语义）：键存在替换整值表，否则新建。 */
function setHeaderValues(h: BridgeHeaders, name: string, values: string[]): void {
  const idx: number = h.names.indexOf(name);
  if (idx >= 0) {
    h.values[idx] = values.slice();
  } else {
    h.names.push(name);
    h.values.push(values.slice());
  }
}

/**
 * /media 嗅探链（VideoUrlHelper.cs:35-65 链序 1:1；U6.2 五锚全量补真，设计书 §3.3）。
 * **四段相互独立非互斥**（源四 if 无 else）——②③⑤分支命中不短路后续判定，严格顺序执行，
 * 不得加 else/return（Node 用例 C2：YT JSON 锚后 normal 门仍评估）：
 * ① contentType 键缺省（null）→ return（:37-41）；
 * ② IsYtFormat（:750-761）→ 识别锚 log 后**继续走**（DownloadManifest+YoutubeDataFormatParser
 *    属 U6.4/U7.1——批量重载 AddVideoNotifications 唯一调用方在 ProcessPostYtFormats，本单元
 *    不落，设计书 §0-2）；
 * ③ IsHLS/IsHLSUrl（:716-731）→ **两表写入**（源序 :337-341——tabId 登记与 referer 写入都在
 *    manifest 拉取之前）+ 锚 log（HlsParser U6.4）；暂态消除：同 tabId 的 .ts 段再过 /media 被
 *    isNormalVideo 门②拦截（U6.1 §7-3）；
 * ④ IsDASH/IsDASHUrl（:733-748）→ 同③两表写入（源序 :187-191）+ 锚 log（MpdParser U7.1）；
 * ⑤ !ProcessYtDashSegment（YT-DASH 段配对全量，VideoSniffAlgo.processYtDashSegment——
 *    消费则跳过 normal 门）→ isNormalVideo 五条件 → processNormalVideo。
 */
function processMediaMessage(msg: BridgeMessage): void {
  const contentType: string | null = headerValueFirst(msg.responseHeaders, 'Content-Type');
  if (contentType === null) {
    return;
  }
  // ② YT JSON 识别锚（源 :43-46 ProcessPostYtFormats 的网络半区留 U6.4/U7.1；源无 return 继续）
  if (isYtFormat(contentType)) {
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'yt manifest branch recognized');
  }
  // ③ HLS 识别+两表写入（源 :48-51 → :333-341）
  if (isHLS(contentType) || isHLSUrl(msg.url)) {
    registerManifestTab(msg);
    addToSkippedRefererList(headerValueFirst(msg.requestHeaders, 'Referer'));
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'hls manifest recognized');
    void processHlsCapture(msg); // fire-and-forget; swallows its own failures like processDashCapture
  }
  // ④ DASH 识别+两表写入（源 :53-56 → :183-191；U7.1 起锚后接真捕获路径）
  if (isDASH(contentType) || isDASHUrl(msg.url)) {
    registerManifestTab(msg);
    addToSkippedRefererList(headerValueFirst(msg.requestHeaders, 'Referer'));
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'dash manifest recognized (parser U7.1)');
    void processDashCapture(msg); // fire-and-forget（§5-6）；自吞异常无悬浮 Promise
  }
  // ⑤ YT-DASH 段配对（消费 → 不评估 normal 门；异常吞掉 false → 落普通视频门）
  if (!processYtDashSegment(sharedSniffState, msg, mediaSegSink)) {
    const url: string = requireUrl(msg.url);
    const size: number = getContentLengthOf(msg.responseHeaders);
    const minBytes: number = Config.getInstance().getMinVideoSize() * 1024;
    if (isNormalVideo(sharedSniffState, contentType, url, size, msg.tabId, minBytes)) {
      processNormalVideo(msg, contentType, url);
    }
  }
}

/** manifest tab 登记（源 ProcessHLSVideo :337-341 / ProcessDashVideo :187-191 同款块：
 * tabId 非空 → m3u8Tabs.add——同 tab 后续分段请求被 isNormalVideo 门②拦截）。 */
function registerManifestTab(msg: BridgeMessage): void {
  const tabId: string | null = msg.tabId;
  if (tabId !== null && tabId.length > 0) {
    sharedSniffState.m3u8Tabs.add(tabId);
  }
}

// ────────────── U7.1 增量：DASH 捕获接线（源 ProcessDashVideo 网络半区，设计书 §1/§4.9） ──────────────

/** 捕获清单拉取超时（源 Config.NetworkTimeout 默认 30s；ManifestClient 上限 300s 内）。 */
const DASH_CAPTURE_TIMEOUT_MS: number = 30000;

/** 模块级 ManifestClient（§5-7：源 DownloadManifest 每次新建 HttpClient 可并行 → 目标共用单例
 * busy→log+跳过，串行化收敛——U6.4 O1 唯一清单请求面方向）。 */
const dashManifestClient: ManifestClient = new ManifestClient();

/** await 前快照形态（§5-6：fire-and-forget 异步期间旧会话无法污染——headers 深拷贝、
 * file 已按源 :185 file ?? fileNameFromUrl(url) 回退）。 */
interface DashCaptureSnapshot {
  url: string;
  file: string;
  headers: BridgeHeaders;
  cookies: string | null;
  tabId: string | null;
  tabUrl: string | null;
}

/** 快照半区：url null（源 new Uri(null) 异常→清单跳过同效）→ null；headers 深拷贝。 */
function snapshotDashMessage(msg: BridgeMessage): DashCaptureSnapshot | null {
  const url: string | null = msg.url;
  if (url === null || url.length === 0) {
    return null;
  }
  const headers: BridgeHeaders = { names: [], values: [] };
  const req: BridgeHeaders | null = msg.requestHeaders;
  if (req !== null) {
    for (let i = 0; i < req.names.length; i++) {
      headers.names.push(req.names[i]);
      headers.values.push(req.values[i].slice());
    }
  }
  const snap: DashCaptureSnapshot = {
    url: url,
    file: msg.file !== null ? msg.file : fileNameFromUrl(url),
    headers: headers,
    cookies: msg.cookies,
    tabId: msg.tabId,
    tabUrl: msg.tabUrl
  };
  return snap;
}

/**
 * DASH 捕获接线（源 VideoUrlHelper.cs:183-276 ProcessDashVideo 的网络半区 + tracker 写入半区；
 * 纯函数半区在 VideoSniffAlgo.processDashVideo）：
 * await 前快照 → ManifestClient GET（busy→log+跳过）→ DashXmlFeed.parseDashManifest →
 * processDashVideo → tracker 三写入方（multi→addDashVideo / dual→addDualSourceVideo /
 * single→addSingleSourceVideo，size 源不设→0、single contentType 源不设→''）。
 * 拉取失败/解析失败 → log + 整清单跳过（源：异常上抛→本次清单整体丢弃，不进 dash 表）；
 * 本函数自吞全部异常（fire-and-forget 调用点无悬浮 Promise）。
 */
async function processDashCapture(msg: BridgeMessage): Promise<void> {
  const snap: DashCaptureSnapshot | null = snapshotDashMessage(msg);
  if (snap === null) {
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'dash capture skipped url missing');
    return;
  }
  try {
    const context: DownloadRequestContext = new DownloadRequestContext();
    context.headers = { names: snap.headers.names, values: snap.headers.values };
    context.cookies = snap.cookies;
    const fetched: ManifestFetchResult = await dashManifestClient.fetchGet(snap.url, context,
      DASH_CAPTURE_TIMEOUT_MS);
    if (fetched.status !== 'ok') {
      hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'dash manifest fetch skipped status=' + fetched.status);
      return;
    }
    const periods: DashPair[][] = parseDashManifest(fetched.text, snap.url, resolveHlsUrl);
    const items: DashCaptureItem[] = processDashVideo(periods, snap.file, snap.url,
      snap.headers, snap.cookies);
    const tracker: CapturedVideoTracker = CapturedVideoTracker.getInstance();
    let multiCount: number = 0;
    let dualCount: number = 0;
    let singleCount: number = 0;
    for (let i = 0; i < items.length; i++) {
      const item: DashCaptureItem = items[i];
      if (item.form === 'multi') {
        const multi: DashMultiCapture = item as DashMultiCapture;
        tracker.addDashVideo(multi.file, multi.manifestUrl, multi.videoSegments, multi.audioSegments,
          multi.headers, multi.cookies, multi.duration, multi.videoMime, multi.audioMime,
          multi.displayText, snap.tabId, snap.tabUrl);
        multiCount++;
      } else if (item.form === 'dual') {
        const dual: DashDualCapture = item as DashDualCapture;
        tracker.addDualSourceVideo(dual.file, 0, dual.uri1, dual.uri2, dual.headers1, dual.headers2,
          dual.cookies1, dual.cookies2, dual.displayText, snap.tabId, snap.tabUrl);
        dualCount++;
      } else {
        const single: DashSingleCapture = item as DashSingleCapture;
        tracker.addSingleSourceVideo(single.file, 0, '', single.uri, single.headers, single.cookies,
          single.displayText, snap.tabId, snap.tabUrl);
        singleCount++;
      }
    }
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'dash capture done multi=' + String(multiCount) +
      ' dual=' + String(dualCount) + ' single=' + String(singleCount));
  } catch (e) {
    // 解析失败=整清单丢弃（源异常上抛同效）；日志不含清单/URL 内容
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'dash capture skipped parse failed');
  }
}

// ────────────── HLS capture wiring (source ProcessHLSVideo network half, VideoUrlHelper.cs:333-409) ──────────────

/** Separate client from DASH: a page that loads both manifests must not see one skipped as busy. */
const hlsManifestClient: ManifestClient = new ManifestClient();
const HLS_MASTER_TAG: string = '#EXT-X-STREAM-INF';
const HLS_IFRAMES_TAG: string = '#EXT-X-I-FRAMES-ONLY';

function extensionOfUrl(url: string): string {
  let path: string = url;
  const cut: number = path.search(new RegExp('[?#]'));
  if (cut >= 0) { path = path.substring(0, cut); }
  const slash: number = path.lastIndexOf('/');
  const name: string = slash >= 0 ? path.substring(slash + 1) : path;
  const dot: number = name.lastIndexOf('.');
  return dot > 0 ? name.substring(dot).toLowerCase() : '';
}

/**
 * Master playlist: one tracker entry per variant/rendition combination (type MP4 when separate
 * audio+video playlists, TS otherwise; display "TYPE quality"). Media playlist: one entry with
 * display "[container]"; I-frame-only lists are skipped. Fetch/parse failure drops the manifest,
 * as the source does when DownloadManifest/parse throws.
 */
async function processHlsCapture(msg: BridgeMessage): Promise<void> {
  const snap: DashCaptureSnapshot | null = snapshotDashMessage(msg);
  if (snap === null) {
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'hls capture skipped url missing');
    return;
  }
  try {
    const context: DownloadRequestContext = new DownloadRequestContext();
    context.headers = { names: snap.headers.names, values: snap.headers.values };
    context.cookies = snap.cookies;
    const fetched: ManifestFetchResult = await hlsManifestClient.fetchGet(snap.url, context,
      DASH_CAPTURE_TIMEOUT_MS);
    if (fetched.status !== 'ok') {
      hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'hls manifest fetch skipped status=' + fetched.status);
      return;
    }
    const base: string = fetched.finalUrl.length > 0 ? fetched.finalUrl : snap.url;
    const stem: string = sanitizeFileName(snap.file);
    const tracker: CapturedVideoTracker = CapturedVideoTracker.getInstance();
    if (fetched.text.indexOf(HLS_MASTER_TAG) >= 0) {
      const variants: HlsPlaylistContainer[] | null = parseHlsMasterPlaylist(fetched.text, base, resolveHlsUrl);
      if (variants === null) {
        hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'hls capture skipped master parse failed');
        return;
      }
      let added: number = 0;
      for (let i = 0; i < variants.length; i++) {
        const video: string | null = variants[i].videoPlaylist;
        const audio: string | null = variants[i].audioPlaylist;
        const primary: string | null = video ?? audio;
        if (primary === null) { continue; }
        const both: boolean = video !== null && audio !== null;
        const type: string = both ? 'MP4' : 'TS';
        const quality: string = hlsQuality(variants[i].attributes) ?? '';
        tracker.addHlsVideo(stem + '.' + type.toLowerCase(), primary, both && audio !== null ? audio : '',
          snap.headers, snap.cookies, (type + ' ' + quality).trim(), snap.tabId, snap.tabUrl);
        added++;
      }
      hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'hls capture done master variants=' + String(added));
      return;
    }
    if (fetched.text.indexOf(HLS_IFRAMES_TAG) >= 0) {
      hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'hls capture skipped iframes-only');
      return;
    }
    const playlist: HlsPlaylist | null = parseHlsMediaPlaylist(fetched.text, base, resolveHlsUrl);
    if (playlist === null || playlist.segments.length === 0) {
      hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'hls capture skipped media parse failed');
      return;
    }
    const last: string = playlist.segments[playlist.segments.length - 1].url;
    const container: string = guessHlsContainer(extensionOfUrl(last));
    tracker.addHlsVideo(stem + '.ts', snap.url, '', snap.headers, snap.cookies, '[' + container + ']',
      snap.tabId, snap.tabUrl);
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'hls capture done media segments=' +
      String(playlist.segments.length));
  } catch (e) {
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'hls capture skipped parse failed');
  }
}

/** AddToSkippedRefererList（VideoUrlHelper.cs:888-895）：referer 空串/null → 忽略；否则
 * referersToSkip.add(sha1Hex(referer))（Dictionary<string,DateTime> 降 Set——源时间戳值只写
 * 不读，键存在性即全部语义，设计书 §4-4）。 */
function addToSkippedRefererList(referer: string | null): void {
  if (referer === null || referer.length === 0) {
    return;
  }
  sharedSniffState.referersToSkip.add(sha1Hex(referer));
}

/** ProcessNormalVideo（VideoUrlHelper.cs:615-695 逐行）：referer 守卫（referersToSkip sha1 键
 * 查询——③④识别锚写入后即生效，U6.1 恒空集暂态消除）→ file 回退（file ?? fileNameFromUrl；
 * 空串再取）→ ext 映射（miss → return）→ Content-Length 强门（缺省/非全串十进制 → throw 断连，
 * 源 long.Parse 1:1）→ 登记 tracker。**U6.2 收敛 c：contentType 登记实参改 ''**（源
 * ProcessNormalVideo 不设 ContentType=null，:677-684 无赋值行——U6.1 R2-F3 闭环，§3.7；
 * 对话框影响面：U6.3 MP3 复选框门 contentType 非空且 audio 前缀且非 mpeg/mp3——normal 条目 ''
 * 无复选框（源同貌），HandleDashAudio 条目 info.mime 有（源同貌），登记设计书 §3.7-F4）。 */
function processNormalVideo(msg: BridgeMessage, contentType: string, url: string): void {
  // :617-621 IsMediaFragment(referer)——referer 的 sha1 键在 referersToSkip 则跳过
  const referer: string | null = headerValueFirst(msg.requestHeaders, 'Referer');
  if (isMediaFragmentGuard(referer)) {
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'skipping url as media fragment');
    return;
  }
  let file: string = msg.file !== null ? msg.file : fileNameFromUrl(url);
  if (file.length === 0) {
    file = fileNameFromUrl(url);
  }
  const ext: string | null = extFromMedia(contentType.toLowerCase(), url.toLowerCase());
  if (ext === null) {
    return;
  }
  // :686 long.Parse(GetResponseHeaderFirstValue("Content-Length"))——缺省 null → 抛；垃圾 → 抛
  const rawLen: string | null = headerValueFirst(msg.responseHeaders, 'Content-Length');
  if (rawLen === null) {
    throw new Error('Content-Length required for media');
  }
  if (!INT64_DECIMAL.test(rawLen)) {
    throw new Error('Content-Length invalid for media');
  }
  const size: number = Number(rawLen);
  // tabUrl 传空（U6.2 IR-F1 修复，镜像源 ProcessNormalVideo 不设 TabUrl——VideoUrlHelper.cs:688-694
  // 仅 TabId；源 UpdateMediaTitle 对 TabUrl 空跳过 VideoTracker.cs:70-88，故 normal 条目不可被
  // /tab-update 改名；HandleDashAudio/dual 路径仍带 tabUrl 保持可改名）
  CapturedVideoTracker.getInstance().addSingleSourceVideo(
    sanitizeFileName(file) + '.' + ext, size, '', url,
    msg.requestHeaders, msg.cookies, qualityText(ext, size), msg.tabId ?? '',
    '');
}

/** IsMediaFragment（VideoUrlHelper.cs:873-886）U6.2 实现：referer 空 → false；referersToSkip
 * 按 **sha1Hex(referer)** 键查询（调用点零改动，设计书 §3.4）。源命中即刷新 DateTime.Now 值
 * ——Set 化后无此动作（时间戳无读取面，§4-4）。 */
function isMediaFragmentGuard(referer: string | null): boolean {
  if (referer === null || referer.length === 0) {
    return false;
  }
  return sharedSniffState.referersToSkip.has(sha1Hex(referer));
}

/** AddDownload 状态机（ApplicationCore.cs:208-236；**留本文件**——源拓扑在 ApplicationCore
 * 而非 tracker，设计书 §3.1）：LinkAccepted 守卫注释锚恒 false（§4-3）；
 * StartDownloadAutomatically（默认 false）=true → 自动开下（file=sanitize(file ??
 * fileNameFromUrl(url))、FileNameAndExtension——startBridgeAutoDownload 自 BridgeActions，
 * 唯一建链点红线不变）；false → log+onShowNewDownloadDialog 事件（真 UI 留 U6.3，§4-5）。 */
async function addDownloadAction(msg: BridgeMessage): Promise<void> {
  if (await LinkRefresher.getInstance().tryAcceptMessage(msg)) {
    return;
  }
  const url: string = requireUrl(msg.url);
  const file: string = sanitizeOrEmpty(msg.file !== null ? msg.file : fileNameFromUrl(url));
  const request: DownloadCreationRequest = bridgeRequestOf(file, getContentLengthOf(msg.responseHeaders),
    url, FileNameFetchMode.FileNameAndExtension, msg.requestHeaders, msg.cookies);
  if (Config.getInstance().getStartDownloadAutomatically()) {
    await startBridgeAutoDownload(file, request.size, url,
      FileNameFetchMode.FileNameAndExtension, request.requestContext);
  } else {
    await enqueueBridgeRequests([request], 'download');
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'new download dialog event');
    fireBridgeUiEvent((l: BridgeUiEvents): void => {
      const cb: ((m: BridgeMessage) => void) | undefined = l.onShowNewDownloadDialog;
      if (cb !== undefined) {
        cb(msg);
      }
    });
  }
}

/** url 非空门（源 new Uri(null) → ArgumentNullException → 断连 的等价物锚） */
function requireUrl(url: string | null): string {
  if (url === null) {
    throw new Error('url required');
  }
  return url;
}

/** 源 FileHelper.SanitizeFileName 的**空串语义**镜像（''→'' 空 in 空 out，FileHelper.cs:17-20）：
 * /link pending（AddBatchLinks :195）与 /download 自动分支命名（AddDownload :215）在源侧对空串
 * file 不回退（''?? 不触发 null 合并）——sanitizeFileName 的 'file' 兜底会误改空串语义（R1-F2），
 * 故本文件两消费点用本 helper。/media normal 的空串回退由 processNormalVideo 既有 IsNullOrEmpty
 * 二次回退分支承接（零改动）。 */
function sanitizeOrEmpty(name: string): string {
  return name.length === 0 ? '' : sanitizeFileName(name);
}

/** /sync 应答组装（IpcHttpMessageProcessor.cs:264-374；自 BridgeServer 平移 + videoList 实时化）：
 * Config 四 getter + 三常量表 + tracker.getVideoList()（:332 GetVideoList 同位）；
 * SyncFields 字段序契约冻结（U0.3 §2.2 零改动）。 */
export function buildSyncResponse(): BridgeResponse {
  const config: Config = Config.getInstance();
  const videos: BridgeVideoItem[] = CapturedVideoTracker.getInstance().getVideoList();
  const fields: SyncFields = {
    enabled: config.getIsBrowserMonitoringEnabled(),
    fileExts: config.getFileExtensions(),
    blockedHosts: config.getBlockedHosts(),
    requestFileExts: config.getVideoExtensions(),
    mediaTypes: SYNC_MEDIA_TYPES,
    tabsWatcher: SYNC_TABS_WATCHER,
    videoList: videos,
    matchingHosts: SYNC_MATCHING_HOSTS
  };
  const json: string = buildSyncJson(fields);
  const body: Uint8Array = utf8Encode(json);
  const names: string[] = ['Content-Type', 'Cache-Control'];
  const values: string[] = [SYNC_CONTENT_TYPE, SYNC_CACHE_CONTROL];
  const resp: BridgeResponse = {
    status: 200, msg: 'OK', headerNames: names, headerValues: values, body: body
  };
  return resp;
}
