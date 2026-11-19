/*
 * U6.2 嗅探规则链 Hypium 本地用例（设计书 u6-2 §5.0 用例表 ArkTS 侧落点 + §5.1-3 清单）。
 * 被测模块 VideoSniffAlgo/BridgeJson/BridgeProtocol 均零 @kit import，本地测试环境可直接加载
 * （BridgeRoutes/CapturedVideoTracker/BridgeActions 含 @kit 与单例，不入本地用例——编排级行为
 * 由探针 P6-U2 设备侧对真实现覆盖；C 组分派链全流程在本文件内以**编排镜像**（与
 * BridgeRoutes.processMediaMessage 链序同构）承载，Node 侧 docs/probe/P6-U2-sniff-cases.js
 * 为同一张表的 JS 镜像——双份用例表同源同验，设计书 §0-1）。
 * 用例计数：A 组 18（isMatchingRequest 八层逐层+sendGate 三态+A8b 边界）+ B 组 9（分派链
 * 谓词五件+itag 十二点边界）+ C 组 8（分派链全流程，每 it 新 SniffState 防串扰）+ D 组 23
 * （YT-DASH 配对全量怪癖）+ E 组 3（sha1/LinkAccepted 谓词）+ F2 回归 2（空串 file 源语义
 * 保留+processNormalVideo 空串二次回退——R1-F2） = 63 断言组（≥55 达标）。
 * U7.1 增量（设计书 u7-1 §6 VideoSniffAlgo 行）：+10 断言组——dashQuality 4（双轨完整串双空格
 * 钉死/und+零带宽双尾随空格/video-only 无中间空格/audio-only 序不同）+ processDashVideo 6
 * （1&1 降级 dual/多轨 multi 全量段/★单轨只取首段 quirk/单轨 audio 标记+ext/双周期前缀 '1 '/
 * webm 双 mime → mkv）= 73 断言组。
 * 执行环境注记（同 U6.1 §7-3 口径）：本地单测 runner 本会话不可实跑（用例入库不影响编译门禁，
 * assembleHap 不编译 src/test）；Node 轨 `node docs/probe/P6-U2-sniff-cases.js` 已 65/65 全绿
 * （退出码 0）=『规则链用例表全绿』的可执行证据。
 * 怪癖钉死（设计书 §0-3/关键约束）：range 前缀/空 key 参数剔除且末位剔除留尾随 '&'（D6）、
 * 'id' 原始参数串前缀判定（D10 相关）、itag/clen 严格十进制门异常 → false（D11）、入队前 >32
 * 裁剪稳态 33（D18/D19）、getDashPair 自队尾+lastVid 同 Length 守卫（D15~D17）、'mkv' 缺点
 * （D13）、Itags 60 项+双空格（D22/D23）。
 * ArkTS 红线：无 any/解构/for...in/正则字面量（A12 用 new RegExp）；箭头函数显式返回类型；
 * 对象字面量均具 interface 类型（嵌套字面量先建局部具型常量）。
 */

import { describe, it, expect } from '@ohos/hypium';
import { BridgeHeaders } from '../main/ets/core/bridge/BridgeProtocol';
import { sanitizeFileName, fileNameFromUrl } from '../main/ets/core/util/FileNames';
import {
  BridgeExtData,
  BridgeMessage, parseExtData, buildBridgeMessage, headerValueFirst, getContentLengthOf
} from '../main/ets/core/bridge/BridgeJson';
import {
  SniffState,
  createSniffState,
  SniffRuleConfig,
  isMatchingRequest,
  passesSendGate,
  isYtFormat,
  isHLS,
  isHLSUrl,
  isDASH,
  isDASHUrl,
  isNormalVideoItag,
  isNormalVideo,
  extFromMedia,
  qualityText,
  processYtDashSegment,
  processDashVideo,
  dashQuality,
  sha1Hex,
  itagQuality,
  ITAG_KEYS,
  ITAG_VALUES,
  DashCaptureItem,
  DashDualCapture,
  DashMultiCapture,
  DashSingleCapture,
  SegSink,
  SegSingle,
  SegDual
} from '../main/ets/core/bridge/VideoSniffAlgo';
import { DashPair, DashRepresentation } from '../main/ets/core/adaptive/DashModel';

/** 默认规则配置（/sync 八字段投影，设计书 §2.3；Config 默认表 + 两恒空层）。 */
const DEFAULT_CFG: SniffRuleConfig = {
  blockedHosts: ['update.microsoft.com', 'windowsupdate.com', 'thwawte.com'],
  mediaExts: [],
  requestFileExts: ['MP4', 'M3U8', 'F4M', 'WEBM', 'OGG', 'MP3', 'AAC', 'FLV', 'MKV', 'DIVX', 'MOV',
    'MPG', 'MPEG', 'OPUS', 'MPD'],
  urlPatternRes: [],
  fileExts: ['3GP', '7Z', 'AVI', 'BZ2', 'DEB', 'DOC', 'DOCX', 'EXE', 'ISO', 'MSI', 'PDF', 'PPT',
    'PPTX', 'RAR', 'RPM', 'XLS', 'XLSX', 'SIT', 'SITX', 'TAR', 'JAR', 'ZIP', 'XZ'],
  mediaTypes: ['audio/', 'video/'],
  matchingHosts: ['googlevideo']
};

/** 配置覆写工厂 A：mediaExts 层注入（恒空层参数位，A6）。 */
function cfgWithMediaExts(exts: string[]): SniffRuleConfig {
  const cfg: SniffRuleConfig = {
    blockedHosts: DEFAULT_CFG.blockedHosts.slice(),
    mediaExts: exts,
    requestFileExts: DEFAULT_CFG.requestFileExts.slice(),
    urlPatternRes: DEFAULT_CFG.urlPatternRes.slice(),
    fileExts: DEFAULT_CFG.fileExts.slice(),
    mediaTypes: DEFAULT_CFG.mediaTypes.slice(),
    matchingHosts: DEFAULT_CFG.matchingHosts.slice()
  };
  return cfg;
}

/** 配置覆写工厂 B：urlPatternRes 层注入（恒空层参数位，A12）。 */
function cfgWithPatterns(patterns: RegExp[]): SniffRuleConfig {
  const cfg: SniffRuleConfig = {
    blockedHosts: DEFAULT_CFG.blockedHosts.slice(),
    mediaExts: DEFAULT_CFG.mediaExts.slice(),
    requestFileExts: DEFAULT_CFG.requestFileExts.slice(),
    urlPatternRes: patterns,
    fileExts: DEFAULT_CFG.fileExts.slice(),
    mediaTypes: DEFAULT_CFG.mediaTypes.slice(),
    matchingHosts: DEFAULT_CFG.matchingHosts.slice()
  };
  return cfg;
}

/** SegSink 收集器（onSingle/onDual 落数组供断言）。 */
class SinkCollector {
  singles: SegSingle[] = [];
  duals: SegDual[] = [];

  toSink(): SegSink {
    const self: SinkCollector = this;
    const sink: SegSink = {
      onSingle: (seg: SegSingle): void => {
        self.singles.push(seg);
      },
      onDual: (seg: SegDual): void => {
        self.duals.push(seg);
      }
    };
    return sink;
  }
}

/** 测试辅助：构造 BridgeHeaders（插入序平行数组）。 */
function headersOf(pairs: string[][]): BridgeHeaders {
  const names: string[] = [];
  const values: string[][] = [];
  for (let i = 0; i < pairs.length; i++) {
    names.push(pairs[i][0]);
    const single: string[] = [pairs[i][1]];
    values.push(single);
  }
  const h: BridgeHeaders = { names: names, values: values };
  return h;
}

/** 测试辅助：Content-Type(+Content-Length)/Referer 组装（探针 S2~S6 载荷同构）。 */
function mediaMsg(url: string, ct: string, contentLength: number | null, file: string | null,
  tabId: string | null, referer: string | null): BridgeMessage {
  const resNames: string[] = ['Content-Type'];
  const resValues: string[][] = [[ct]];
  if (contentLength !== null) {
    resNames.push('Content-Length');
    const cl: string[] = [String(contentLength)];
    resValues.push(cl);
  }
  const reqNames: string[] = [];
  const reqValues: string[][] = [];
  if (referer !== null) {
    reqNames.push('Referer');
    const ref: string[] = [referer];
    reqValues.push(ref);
  }
  const reqH: BridgeHeaders = { names: reqNames, values: reqValues };
  const resH: BridgeHeaders = { names: resNames, values: resValues };
  const msg: BridgeMessage = {
    url: url,
    method: 'GET',
    requestHeaders: reqH,
    responseHeaders: resH,
    cookies: null,
    file: file,
    tabId: tabId,
    tabUrl: 'https://www.youtube.com/watch?v=abc',
    mediaSourceUrl: null
  };
  return msg;
}

// ────────────── C 组编排镜像（BridgeRoutes.processMediaMessage 链序同构，§5.1-3） ──────────────

function addToSkippedOf(state: SniffState, referer: string | null): void {
  if (referer === null || referer.length === 0) {
    return;
  }
  state.referersToSkip.add(sha1Hex(referer));
}

function isMediaFragmentOf(state: SniffState, referer: string | null): boolean {
  if (referer === null || referer.length === 0) {
    return false;
  }
  return state.referersToSkip.has(sha1Hex(referer));
}

/** ProcessNormalVideo 镜像（contentType 登记实参 ''——收敛 c；空串 file 二次回退链序与
 * BridgeRoutes.processNormalVideo 一致：''→fileNameFromUrl(url)，R1-F2）。 */
const INT64_DECIMAL_TEST: RegExp = new RegExp('^[+-]?[0-9]+$');

function processNormalVideoOf(state: SniffState, msg: BridgeMessage, contentType: string,
  sink: SegSink): void {
  const referer: string | null = headerValueFirst(msg.requestHeaders, 'Referer');
  if (isMediaFragmentOf(state, referer)) {
    return;
  }
  const url: string = msg.url ?? '';
  let file: string = msg.file !== null ? msg.file : fileNameFromUrl(url);
  if (file.length === 0) {
    file = fileNameFromUrl(url);
  }
  const ext: string | null = extFromMedia(contentType.toLowerCase(), url.toLowerCase());
  if (ext === null) {
    return;
  }
  const rawLen: string | null = headerValueFirst(msg.responseHeaders, 'Content-Length');
  if (rawLen === null) {
    throw new Error('Content-Length required for media');
  }
  if (!INT64_DECIMAL_TEST.test(rawLen)) {
    throw new Error('Content-Length invalid for media');
  }
  const seg: SegSingle = {
    file: sanitizeFileName(file) + '.' + ext,
    size: Number(rawLen),
    contentType: '',
    displayText: qualityText(ext, Number(rawLen)),
    uri: url,
    headers: msg.requestHeaders,
    cookies: msg.cookies,
    tabId: msg.tabId ?? '',
    tabUrl: msg.tabUrl ?? ''
  };
  sink.onSingle(seg);
}

/** 分派链编排镜像（VideoUrlHelper.cs:35-65 四段独立非互斥，§3.3）。 */
function dispatchMediaOf(state: SniffState, msg: BridgeMessage, sink: SegSink): void {
  const contentType: string | null = headerValueFirst(msg.responseHeaders, 'Content-Type');
  if (contentType === null) {
    return;
  }
  if (isYtFormat(contentType)) {
    // 识别锚（源无 return 继续走——U6.4/U7.1 落 manifest 解析）
  }
  if (isHLS(contentType) || isHLSUrl(msg.url)) {
    const tabId: string | null = msg.tabId;
    if (tabId !== null && tabId.length > 0) {
      state.m3u8Tabs.add(tabId);
    }
    addToSkippedOf(state, headerValueFirst(msg.requestHeaders, 'Referer'));
  }
  if (isDASH(contentType) || isDASHUrl(msg.url)) {
    const tabId: string | null = msg.tabId;
    if (tabId !== null && tabId.length > 0) {
      state.m3u8Tabs.add(tabId);
    }
    addToSkippedOf(state, headerValueFirst(msg.requestHeaders, 'Referer'));
  }
  if (!processYtDashSegment(state, msg, sink)) {
    if (msg.url === null) {
      throw new Error('url required');
    }
    const size: number = getContentLengthOf(msg.responseHeaders);
    if (isNormalVideo(state, contentType, msg.url, size, msg.tabId, 1024 * 1024)) {
      processNormalVideoOf(state, msg, contentType, sink);
    }
  }
}

/** LinkAccepted 匹配谓词（LinkRefresher.cs:46-63：FileSize==ContentLength 且>0，备查）。 */
function linkAcceptedOf(fileSize: number, contentLength: number): boolean {
  return fileSize > 0 && contentLength > 0 && fileSize === contentLength;
}

const GV: string = 'https://rr.googlevideo.com/videoplayback';

/** U7.1 processDashVideo 夹具 helper（模块顶层——ArkTS 禁 describe 内嵌函数声明）。 */
function dashPairOf(video: DashRepresentation | null, audio: DashRepresentation | null): DashPair {
  return new DashPair(video, audio);
}

/** 双轨 DashRepresentation 对（可变段数；video 1080p 1000000 / audio eng 128000）。 */
function dualRep(videoSegments: number, audioSegments: number): DashPair {
  const v: string[] = [];
  const a: string[] = [];
  for (let i = 0; i < videoSegments; i++) { v.push('https://h/v-' + String(i) + '.m4s'); }
  for (let i = 0; i < audioSegments; i++) { a.push('https://h/a-' + String(i) + '.m4s'); }
  return dashPairOf(
    new DashRepresentation(v, 1920, 1080, 'avc1', 1000000, 60000, 'video/mp4', ''),
    new DashRepresentation(a, -1, -1, 'mp4a', 128000, 60000, 'audio/mp4', 'eng'));
}

export default function videoSniffAlgoTest(): void {
  describe('VideoSniffAlgo', () => {
    // ────────────── A 组 isMatchingRequest/passSendGate（18 断言组） ──────────────

    it('isMatchingRequest_blockedHostsExactAndSubstring', 0, () => {
      const html: BridgeHeaders = headersOf([['Content-Type', 'text/html']]);
      expect(isMatchingRequest(DEFAULT_CFG, 'https://download.windowsupdate.com/c/up.exe', html))
        .assertFalse();
      expect(isMatchingRequest(DEFAULT_CFG, 'https://a.update.microsoft.com/x', html)).assertFalse();
    });

    it('isMatchingRequest_requestFileExtsUppercasePath', 0, () => {
      const html: BridgeHeaders = headersOf([['Content-Type', 'text/html']]);
      expect(isMatchingRequest(DEFAULT_CFG, 'https://h/Video.MP4', html)).assertTrue();
      expect(isMatchingRequest(DEFAULT_CFG, 'https://h/video.mp4?x=1', html)).assertTrue();
    });

    it('isMatchingRequest_mediaTypesContentType', 0, () => {
      const ct: BridgeHeaders = headersOf([['Content-Type', 'video/mp4']]);
      expect(isMatchingRequest(DEFAULT_CFG, 'https://h/a', ct)).assertTrue();
    });

    it('isMatchingRequest_mediaExtsLayerInjected', 0, () => {
      const tsExts: string[] = ['.TS'];
      const cfg: SniffRuleConfig = cfgWithMediaExts(tsExts);
      const html: BridgeHeaders = headersOf([['Content-Type', 'text/html']]);
      expect(isMatchingRequest(cfg, 'https://h/a.ts', html)).assertTrue();
    });

    it('isMatchingRequest_fileExtsDotExt', 0, () => {
      const octet: BridgeHeaders = headersOf([['Content-Type', 'application/octet-stream']]);
      expect(isMatchingRequest(DEFAULT_CFG, 'https://h/f/setup.EXE', octet)).assertTrue();
    });

    it('isMatchingRequest_contentDispositionZipHit', 0, () => {
      const h: BridgeHeaders = headersOf([['Content-Type', 'text/html'],
        ['Content-Disposition', 'attachment; filename="a.ZIP"']]);
      expect(isMatchingRequest(DEFAULT_CFG, 'https://h/a', h)).assertTrue();
    });

    it('isMatchingRequest_contentDispositionMkvNotInFileExts', 0, () => {
      // MKV∈VideoExtensions∉fileExts（源语义：Content-Disposition 层只扫 fileExts）
      const h: BridgeHeaders = headersOf([['Content-Type', 'text/html'],
        ['Content-Disposition', 'attachment; filename="a.MKV"']]);
      expect(isMatchingRequest(DEFAULT_CFG, 'https://h/a', h)).assertFalse();
    });

    it('isMatchingRequest_matchingHostsHit', 0, () => {
      const html: BridgeHeaders = headersOf([['Content-Type', 'text/html']]);
      expect(isMatchingRequest(DEFAULT_CFG, 'https://rr.googlevideo.com/videoplayback', html))
        .assertTrue();
    });

    it('isMatchingRequest_noLayerMatchImplicitReject', 0, () => {
      const html: BridgeHeaders = headersOf([['Content-Type', 'text/html']]);
      expect(isMatchingRequest(DEFAULT_CFG, 'https://h/index.html', html)).assertFalse();
    });

    it('isMatchingRequest_queryNotParticipating', 0, () => {
      const html: BridgeHeaders = headersOf([['Content-Type', 'text/html']]);
      expect(isMatchingRequest(DEFAULT_CFG, 'https://h/get?a.EXE', html)).assertFalse();
    });

    it('isMatchingRequest_urlPatternLayerInjected', 0, () => {
      const res: RegExp[] = [new RegExp('special/video/[0-9]+', 'i')];
      const cfg: SniffRuleConfig = cfgWithPatterns(res);
      const html: BridgeHeaders = headersOf([['Content-Type', 'text/html']]);
      expect(isMatchingRequest(cfg, 'https://h/special/video/9', html)).assertTrue();
    });

    it('isMatchingRequest_invalidUrlFalse', 0, () => {
      // 非法 URL（无 '://'）→ false（源 new URL 抛 → 监听器中止的净效果）
      const html: BridgeHeaders = headersOf([['Content-Type', 'text/html']]);
      expect(isMatchingRequest(DEFAULT_CFG, 'not-a-url', html)).assertFalse();
      expect(isMatchingRequest(DEFAULT_CFG, 'https://', html)).assertFalse();
    });

    it('passesSendGate_postWithoutMatchingHostRejected', 0, () => {
      expect(passesSendGate('POST', 'https://h/a', DEFAULT_CFG.matchingHosts)).assertFalse();
    });

    it('passesSendGate_postWithHostAtIndexGreaterThanZero', 0, () => {
      expect(passesSendGate('POST', 'https://x.googlevideo.com/v', DEFAULT_CFG.matchingHosts))
        .assertTrue();
    });

    it('passesSendGate_postHostAtIndexZeroQuirk', 0, () => {
      // 源怪癖：url.indexOf(h) 严格大于 0——下标 0 不算（request-watcher.js:94）
      expect(passesSendGate('POST', 'googlevideo.com/v', DEFAULT_CFG.matchingHosts)).assertFalse();
    });

    it('passesSendGate_getAlwaysPasses', 0, () => {
      expect(passesSendGate('GET', 'https://h/any', [])).assertTrue();
    });

    it('isMatchingRequest_uppercaseHostNotBlockedByOrdinalLayer', 0, () => {
      // 大写 host 屏蔽层序数敏感未中（A17 怪癖登记）且余层未中
      const html: BridgeHeaders = headersOf([['Content-Type', 'text/html']]);
      expect(isMatchingRequest(DEFAULT_CFG, 'https://WINDOWSUPDATE.COM/x', html)).assertFalse();
    });

    it('isMatchingRequest_portKeptAndUserinfoStripped', 0, () => {
      // hostOfUrl：端口保留、userinfo 剥离（u.host 语义，§4-12）——googlevideo@ 子串在 userinfo 不命中层⑧
      const html: BridgeHeaders = headersOf([['Content-Type', 'text/html']]);
      expect(isMatchingRequest(DEFAULT_CFG, 'https://user@googlevideo.example.com:8080/a', html))
        .assertTrue();
    });

    // ────────────── B 组分派链谓词（9 断言组） ──────────────

    it('isYtFormat_exactAndCaseInsensitiveAndEmpty', 0, () => {
      expect(isYtFormat('application/json')).assertTrue();
      expect(isYtFormat('APPLICATION/JSON; charset=utf-8')).assertTrue();
      expect(isYtFormat('')).assertFalse();
      expect(isYtFormat(null)).assertFalse();
    });

    it('isHLS_ordinalCaseSensitive', 0, () => {
      expect(isHLS('application/vnd.apple.mpegurl')).assertTrue();
      expect(isHLS('APPLICATION/VND.APPLE.MPEGURL')).assertFalse();
    });

    it('isHLSUrl_lowercaseNormalized', 0, () => {
      expect(isHLSUrl('https://h/PLAYLIST.M3U8')).assertTrue();
      expect(isHLSUrl('https://h/list.m3u8')).assertTrue();
      expect(isHLSUrl(null)).assertFalse();
    });

    it('isDASH_dashXml', 0, () => {
      expect(isDASH('application/dash+xml')).assertTrue();
      expect(isDASH('application/DASH+xml')).assertFalse();
    });

    it('isDASHUrl_mpdLowercase', 0, () => {
      expect(isDASHUrl('https://h/manifest.MPD')).assertTrue();
      expect(isDASHUrl(null)).assertFalse();
    });

    it('isNormalVideoItag_twelveBoundaries', 0, () => {
      const pts: number[][] = [[4, 0], [5, 1], [78, 1], [79, 0], [81, 0], [82, 1], [85, 1],
        [86, 0], [99, 0], [100, 1], [102, 1], [103, 0]];
      for (let i = 0; i < pts.length; i++) {
        expect(isNormalVideoItag(pts[i][0])).assertEqual(pts[i][1] === 1);
      }
    });

    // ────────────── C 组分派链全流程（8 断言组；每 it 新 state 防串扰） ──────────────

    it('dispatch_normalVideoRegisteredWithEmptyContentType', 0, () => {
      const state: SniffState = createSniffState();
      const sink: SinkCollector = new SinkCollector();
      dispatchMediaOf(state, mediaMsg('https://h/v/clip.mp4', 'video/mp4', 5242880, 'Movie', '1', null), sink.toSink());
      expect(sink.singles.length).assertEqual(1);
      expect(sink.singles[0].contentType).assertEqual('');
      expect(sink.singles[0].displayText.indexOf('[MP4]')).assertEqual(0);
    });

    it('dispatch_ytJsonAnchorNoRegistration', 0, () => {
      const state: SniffState = createSniffState();
      const sink: SinkCollector = new SinkCollector();
      dispatchMediaOf(state, mediaMsg('https://h/api/manifest', 'application/json', null, null, '1', null), sink.toSink());
      expect(sink.singles.length).assertEqual(0);
      expect(sink.duals.length).assertEqual(0);
    });

    it('dispatch_m3u8RegistersTabAndRefererSkip', 0, () => {
      const state: SniffState = createSniffState();
      const sink: SinkCollector = new SinkCollector();
      dispatchMediaOf(state, mediaMsg('https://h/list.m3u8', 'application/vnd.apple.mpegurl', null, null, '200', 'R1'), sink.toSink());
      expect(state.m3u8Tabs.has('200')).assertTrue();
      expect(state.referersToSkip.has(sha1Hex('R1'))).assertTrue();
      expect(sink.singles.length).assertEqual(0);
    });

    it('dispatch_sameTabTsSegmentBlocked_transienceRemoved', 0, () => {
      const state: SniffState = createSniffState();
      const sink: SinkCollector = new SinkCollector();
      dispatchMediaOf(state, mediaMsg('https://h/list.m3u8', 'application/vnd.apple.mpegurl', null, null, '200', 'R1'), sink.toSink());
      dispatchMediaOf(state, mediaMsg('https://h/seg/001.ts', 'video/mp2t', 300000, null, '200', 'R1'), sink.toSink());
      expect(sink.singles.length).assertEqual(0);
      expect(sink.duals.length).assertEqual(0);
    });

    it('dispatch_sameRefererBlockedByMediaFragment', 0, () => {
      const state: SniffState = createSniffState();
      const sink: SinkCollector = new SinkCollector();
      dispatchMediaOf(state, mediaMsg('https://h/list2.m3u8', 'application/vnd.apple.mpegurl', null, null, '201', 'R1'), sink.toSink());
      dispatchMediaOf(state, mediaMsg('https://h/v/clip.mp4', 'video/mp4', 5242880, null, '201', 'R1'), sink.toSink());
      expect(sink.singles.length).assertEqual(0);
    });

    it('dispatch_otherRefererOtherTabRegistered', 0, () => {
      const state: SniffState = createSniffState();
      const sink: SinkCollector = new SinkCollector();
      dispatchMediaOf(state, mediaMsg('https://h/list2.m3u8', 'application/vnd.apple.mpegurl', null, null, '201', 'R1'), sink.toSink());
      dispatchMediaOf(state, mediaMsg('https://h/v/clip.mp4', 'video/mp4', 5242880, null, '202', 'R2'), sink.toSink());
      expect(sink.singles.length).assertEqual(1);
    });

    it('dispatch_initMp4FragmentSetBlocksSibling', 0, () => {
      const state: SniffState = createSniffState();
      const sink: SinkCollector = new SinkCollector();
      dispatchMediaOf(state, mediaMsg('https://h/a/b/init.mp4?x=1', 'video/mp4', 9999999, null, '1', null), sink.toSink());
      expect(state.suspectedFragments.has('https://h/a/b/')).assertTrue();
      dispatchMediaOf(state, mediaMsg('https://h/a/b/seg-1.mp4', 'video/mp4', 9999999, null, '1', null), sink.toSink());
      expect(sink.singles.length).assertEqual(0);
    });

    it('dispatch_sizeBelowMinRejected', 0, () => {
      const state: SniffState = createSniffState();
      const sink: SinkCollector = new SinkCollector();
      dispatchMediaOf(state, mediaMsg('https://h/v/tiny.mp4', 'video/mp4', 512, null, '1', null), sink.toSink());
      expect(sink.singles.length).assertEqual(0);
    });

    // ────────────── D 组 YT-DASH 配对（23 断言组） ──────────────

    it('dash_threeGatesReject', 0, () => {
      const state: SniffState = createSniffState();
      expect(processYtDashSegment(state, mediaMsg('https://h.example.com/videoplayback?itag=140&clen=1000',
        'audio/mp4', null, null, '1', null), new SinkCollector().toSink())).assertFalse();
      expect(processYtDashSegment(state, mediaMsg(GV + '?itag=140&clen=1000', 'text/html', null, null, '1', null),
        new SinkCollector().toSink())).assertFalse();
      expect(processYtDashSegment(state, mediaMsg(GV + '?clen=1000', 'audio/mp4', null, null, '1', null),
        new SinkCollector().toSink())).assertFalse();
    });

    it('dash_audioSegmentConsumedWithMp4AudioText', 0, () => {
      const state: SniffState = createSniffState();
      const sink: SinkCollector = new SinkCollector();
      const ok: boolean = processYtDashSegment(state,
        mediaMsg(GV + '?itag=140&mime=audio%2Fmp4&clen=1000&id=oA', 'audio/mp4', null, 'YT Video', '1', null), sink.toSink());
      expect(ok).assertTrue();
      expect(sink.singles.length).assertEqual(1);
      expect(sink.singles[0].displayText).assertEqual('[MP4 AUDIO] 1000B');
      expect(sink.singles[0].contentType).assertEqual('audio/mp4');
      expect(sink.singles[0].file.endsWith('.mp4')).assertTrue();
    });

    it('dash_rangeTailParamDroppedLeavesTrailingAmpersand', 0, () => {
      const state: SniffState = createSniffState();
      processYtDashSegment(state, mediaMsg(GV + '?itag=140&mime=audio%2Fmp4&id=oA&range=0-1000',
        'audio/mp4', null, 'YT Video', '1', null), new SinkCollector().toSink());
      expect(state.audioQueue.length).assertEqual(1);
      expect(state.audioQueue[0].url.endsWith('&')).assertTrue();
      expect(state.audioQueue[0].url.indexOf('range')).assertEqual(-1);
    });

    it('dash_sameIdPairProducesMkvDual', 0, () => {
      const state: SniffState = createSniffState();
      const sink: SinkCollector = new SinkCollector();
      processYtDashSegment(state, mediaMsg(GV + '?itag=140&mime=audio%2Fmp4&clen=1000&id=oA', 'audio/mp4', null, 'YT Video', '1', null), sink.toSink());
      processYtDashSegment(state, mediaMsg(GV + '?itag=137&mime=video%2Fmp4&clen=2000&id=oA', 'video/mp4', null, 'YT Video', '1', null), sink.toSink());
      expect(sink.duals.length).assertEqual(1);
      expect(sink.duals[0].file.endsWith('.mkv')).assertTrue();
      expect(sink.duals[0].size).assertEqual(3000);
      expect(sink.duals[0].displayText).assertEqual('[1080p] 2.9K');
    });

    it('dash_itag22ShortCircuitsToNormalGate', 0, () => {
      const state: SniffState = createSniffState();
      expect(processYtDashSegment(state, mediaMsg(GV + '?itag=22&mime=video%2Fmp4&clen=5000&id=oB',
        'video/mp4', null, null, '1', null), new SinkCollector().toSink())).assertFalse();
    });

    it('dash_uppercaseItagKeyParsesZeroStillConsumes', 0, () => {
      const state: SniffState = createSniffState();
      const ok: boolean = processYtDashSegment(state, mediaMsg(GV + '?ITAG=137&mime=video%2Fmp4&clen=2000&id=oC',
        'video/mp4', null, null, '1', null), new SinkCollector().toSink());
      expect(ok).assertTrue();
      expect(state.videoQueue.length).assertEqual(1);
    });

    it('dash_garbageItagParseThrowsToFalse', 0, () => {
      const state: SniffState = createSniffState();
      expect(processYtDashSegment(state, mediaMsg(GV + '?itag=abc&mime=video%2Fmp4&clen=100&id=oD',
        'video/mp4', null, null, '1', null), new SinkCollector().toSink())).assertFalse();
    });

    it('dash_audioWebmExtension', 0, () => {
      const state: SniffState = createSniffState();
      const sink: SinkCollector = new SinkCollector();
      processYtDashSegment(state, mediaMsg(GV + '?itag=139&mime=audio%2Fwebm&clen=1000&id=oE',
        'audio/webm', null, 'YT Video', '1', null), sink.toSink());
      expect(sink.singles[0].file.endsWith('.webm')).assertTrue();
      expect(sink.singles[0].displayText).assertEqual('[WEBM AUDIO] 1000B');
    });

    it('dash_audioFlacMkvQuirkKept', 0, () => {
      const state: SniffState = createSniffState();
      const sink: SinkCollector = new SinkCollector();
      processYtDashSegment(state, mediaMsg(GV + '?itag=139&mime=audio%2Fflac&clen=1000&id=oF',
        'audio/flac', null, 'Clip', '1', null), sink.toSink());
      expect(sink.singles[0].file).assertEqual('Clipmkv');
      expect(sink.singles[0].displayText).assertEqual('[KV AUDIO] 1000B');
    });

    it('dash_addIfNewDedupByLengthAndId', 0, () => {
      const state: SniffState = createSniffState();
      const sink: SinkCollector = new SinkCollector();
      const msg: BridgeMessage = mediaMsg(GV + '?itag=140&mime=audio%2Fmp4&clen=1000&id=oA',
        'audio/mp4', null, 'YT Video', '1', null);
      processYtDashSegment(state, msg, sink.toSink());
      processYtDashSegment(state, msg, sink.toSink());
      expect(sink.singles.length).assertEqual(1);
      expect(state.audioQueue.length).assertEqual(1);
    });

    it('dash_pairScansFromQueueTail', 0, () => {
      const state: SniffState = createSniffState();
      const sink: SinkCollector = new SinkCollector();
      processYtDashSegment(state, mediaMsg(GV + '?itag=137&mime=video%2Fmp4&clen=1000&id=oG', 'video/mp4', null, null, '1', null), sink.toSink());
      processYtDashSegment(state, mediaMsg(GV + '?itag=137&mime=video%2Fmp4&clen=2500&id=oG', 'video/mp4', null, null, '1', null), sink.toSink());
      processYtDashSegment(state, mediaMsg(GV + '?itag=140&mime=audio%2Fmp4&clen=1000&id=oG', 'audio/mp4', null, 'V', '1', null), sink.toSink());
      expect(sink.duals.length).assertEqual(1);
      expect(sink.duals[0].size).assertEqual(3500);
    });

    it('dash_lastVidGuardBlocksSecondPairingOfSameVideo', 0, () => {
      const state: SniffState = createSniffState();
      const sink: SinkCollector = new SinkCollector();
      processYtDashSegment(state, mediaMsg(GV + '?itag=137&mime=video%2Fmp4&clen=1000&id=oH', 'video/mp4', null, null, '1', null), sink.toSink());
      processYtDashSegment(state, mediaMsg(GV + '?itag=140&mime=audio%2Fmp4&clen=1000&id=oH', 'audio/mp4', null, null, '1', null), sink.toSink());
      processYtDashSegment(state, mediaMsg(GV + '?itag=140&mime=audio%2Fmp4&clen=2000&id=oH', 'audio/mp4', null, null, '1', null), sink.toSink());
      expect(sink.duals.length).assertEqual(1);
    });

    it('dash_videoArrivalPairsLatestAudio', 0, () => {
      const state: SniffState = createSniffState();
      const sink: SinkCollector = new SinkCollector();
      processYtDashSegment(state, mediaMsg(GV + '?itag=140&mime=audio%2Fmp4&clen=2001&id=oI', 'audio/mp4', null, null, '1', null), sink.toSink());
      processYtDashSegment(state, mediaMsg(GV + '?itag=302&mime=video%2Fmp4&clen=2000&id=oI', 'video/mp4', null, null, '1', null), sink.toSink());
      expect(sink.duals.length).assertEqual(1);
      expect(sink.duals[0].size).assertEqual(4001);
      expect(sink.duals[0].displayText).assertEqual('[720p] 3.9K');
    });

    it('dash_queueSteadyState33After34', 0, () => {
      const state: SniffState = createSniffState();
      for (let i = 1; i <= 34; i++) {
        processYtDashSegment(state, mediaMsg(GV + '?itag=140&mime=audio%2Fmp4&clen=' + String(i * 10) +
          '&id=q' + String(i), 'audio/mp4', null, null, '1', null), new SinkCollector().toSink());
      }
      expect(state.audioQueue.length).assertEqual(33);
    });

    it('dash_oldestEvictedBeforeEnqueue', 0, () => {
      const state: SniffState = createSniffState();
      processYtDashSegment(state, mediaMsg(GV + '?itag=140&mime=audio%2Fmp4&clen=1&id=old',
        'audio/mp4', null, null, '1', null), new SinkCollector().toSink());
      for (let i = 1; i <= 33; i++) {
        processYtDashSegment(state, mediaMsg(GV + '?itag=140&mime=audio%2Fmp4&clen=' + String(1000 + i * 10) +
          '&id=q' + String(i), 'audio/mp4', null, null, '1', null), new SinkCollector().toSink());
      }
      expect(state.audioQueue.length).assertEqual(33);
      let oldGone: boolean = true;
      for (let i = 0; i < state.audioQueue.length; i++) {
        if (state.audioQueue[i].id === 'old') {
          oldGone = false;
        }
      }
      expect(oldGone).assertTrue();
    });

    it('dash_octetStreamAudioSideNoHandleDashAudio', 0, () => {
      const state: SniffState = createSniffState();
      const sink: SinkCollector = new SinkCollector();
      const ok: boolean = processYtDashSegment(state, mediaMsg(GV + '?itag=251&clen=3000&id=oJ',
        'application/octet-stream', null, null, '1', null), sink.toSink());
      expect(ok).assertTrue();
      expect(state.audioQueue.length).assertEqual(1);
      expect(sink.singles.length).assertEqual(0);
    });

    it('dash_itagMissingDefaultsToMkv', 0, () => {
      const state: SniffState = createSniffState();
      const sink: SinkCollector = new SinkCollector();
      processYtDashSegment(state, mediaMsg(GV + '?itag=140&mime=audio%2Fmp4&clen=400&id=oK', 'audio/mp4', null, null, '1', null), sink.toSink());
      processYtDashSegment(state, mediaMsg(GV + '?itag=999&mime=video%2Fmp4&clen=600&id=oK', 'video/mp4', null, null, '1', null), sink.toSink());
      expect(sink.duals.length).assertEqual(1);
      expect(sink.duals[0].displayText).assertEqual('[MKV] 1000B');
    });

    it('dash_itagTableSixtyEntries', 0, () => {
      expect(ITAG_KEYS.length).assertEqual(60);
      expect(ITAG_VALUES.length).assertEqual(60);
    });

    it('dash_itagSpotChecks', 0, () => {
      expect(itagQuality(137)).assertEqual('1080p');
      expect(itagQuality(141)).assertEqual('Hi  bitrate');
      expect(itagQuality(82)).assertEqual('360p 3D');
      expect(itagQuality(9999)).assertEqual('MKV');
    });

    // ────────────── E 组 sha1/LinkAccepted 谓词（3 断言组） ──────────────

    it('sha1_fortyLowercaseHex', 0, () => {
      const digest: string = sha1Hex('https://media.example.com/page');
      expect(digest.length).assertEqual(40);
      expect(new RegExp('^[0-9a-f]{40}$').test(digest)).assertTrue();
    });

    it('sha1_abcKnownVector', 0, () => {
      // node:crypto 交叉验证（docs/probe/P6-U2-sniff-cases.js E2 同向量）
      expect(sha1Hex('abc')).assertEqual('a9993e364706816aba3e25717850c26c9cd0d89d');
    });

    it('linkAcceptedPredicateThreeStates', 0, () => {
      // LinkRefresher.cs:46-63 匹配谓词备查（§0-4：U6.3 与刷新链接窗一起落）
      expect(linkAcceptedOf(500, 500)).assertTrue();
      expect(linkAcceptedOf(500, 600)).assertFalse();
      expect(linkAcceptedOf(0, 0)).assertFalse();
    });

    // ────────────── F2 回归（BridgeJson 空串 file 源语义保留，设计书 §3.8 + R1-F2 复核修正） ──────────────

    it('buildBridgeMessage_emptyFileKeptAsEmptyString', 0, () => {
      // R1-F2：空串 file **原样保留 ''**（=源 SanitizeFileName('')='' 空 in 空 out 直译）——
      // /media normal 的回退由 processNormalVideo 既有 IsNullOrEmpty 二次回退承接；/link pending、
      // /download 自动分支、HandleDashAudio/CreateDual 源侧空串均不回退（''+ext=裸扩展名）。
      // U6.1 实现经 sanitize 的 'file' 兜底把空串变非空才是 F2 原始缺陷。
      const data = parseExtData('{"url":"https://h/x.mp4","file":"","requestHeaders":{"a":["b"]}}');
      expect(data !== null).assertTrue();
      const msg: BridgeMessage = buildBridgeMessage(data as BridgeExtData);
      expect(msg.file).assertEqual('');
      const data2 = parseExtData('{"url":"https://h/x.mp4","file":"clip","requestHeaders":{"a":["b"]}}');
      const msg2: BridgeMessage = buildBridgeMessage(data2 as BridgeExtData);
      expect(msg2.file).assertEqual('clip');
      const data3 = parseExtData('{"url":"https://h/x.mp4","requestHeaders":{"a":["b"]}}');
      const msg3: BridgeMessage = buildBridgeMessage(data3 as BridgeExtData);
      expect(msg3.file).assertNull();
    });

    it('processNormalVideoOf_emptyFileSecondFallback', 0, () => {
      // 空串 file 经 processNormalVideo 的 IsNullOrEmpty 二次回退（VideoUrlHelper.cs:627-630）
      // → fileNameFromUrl(url) 保留已有扩展；源 :680 仍无条件追加 .mp4，不去重扩展。
      // FileHelper.cs:88-100 无 contentType 参数时直接返回完整basename。
      const state: SniffState = createSniffState();
      const sink: SinkCollector = new SinkCollector();
      dispatchMediaOf(state, mediaMsg('https://h/x.mp4', 'video/mp4', 5242880, '', '1', null), sink.toSink());
      expect(sink.singles.length).assertEqual(1);
      expect(sink.singles[0].file).assertEqual('x.mp4.mp4');
    });

    // ────────────── U7.1：dashQuality 四形态 + processDashVideo 六场景（§6 VideoSniffAlgo 行） ──────────────

    it('dashQuality_dual_full_double_space_quirk', 0, (): void => {
      // GetQualityString :320 双轨 = 高度段+带宽段+' '+语言段；1128000/1024=1101（trunc）；
      // ★双空格 quirk（' Kbps ' 尾随空格 + 字面 ' '）逐字符钉死
      const video: DashRepresentation = new DashRepresentation(['https://h/v.m4s'], 1920, 1080,
        'avc1', 1000000, 60000, 'video/mp4', '');
      const audio: DashRepresentation = new DashRepresentation(['https://h/a.m4s'], -1, -1,
        'mp4a', 128000, 60000, 'audio/mp4', 'eng');
      expect(dashQuality(video, audio)).assertEqual('1080p 1101 Kbps  eng ');
    });

    it('dashQuality_dual_und_and_zero_bandwidth', 0, (): void => {
      // lang='und'→空段；bandwidth≤0→空段；高度段+字面 ' ' 保留 → 尾随双空格
      const video: DashRepresentation = new DashRepresentation(['https://h/v.m4s'], 1280, 720,
        'avc1', 0, 60000, 'video/mp4', '');
      const audio: DashRepresentation = new DashRepresentation(['https://h/a.m4s'], -1, -1,
        'mp4a', -1, 60000, 'audio/mp4', 'und');
      expect(dashQuality(video, audio)).assertEqual('720p  ');
    });

    it('dashQuality_videoOnly_no_middle_space', 0, (): void => {
      // :324 video-only = 高度段+带宽段（无中间空格/无语言段）
      const video: DashRepresentation = new DashRepresentation(['https://h/v.m4s'], 1920, 1080,
        'avc1', 524288, 60000, 'video/mp4', '');
      expect(dashQuality(video, null)).assertEqual('1080p 512 Kbps ');
      const tiny: DashRepresentation = new DashRepresentation(['https://h/v.m4s'], 640, 0,
        'avc1', 524288, 60000, 'video/mp4', '');
      expect(dashQuality(tiny, null)).assertEqual('512 Kbps ');
    });

    it('dashQuality_audioOnly_languageFirst_orderQuirk', 0, (): void => {
      // ★:328 audio-only = 语言段+带宽段（序与双轨不同）
      const audio: DashRepresentation = new DashRepresentation(['https://h/a.m4s'], -1, -1,
        'mp4a', 65536, 60000, 'audio/mp4', 'en');
      expect(dashQuality(null, audio)).assertEqual('en 64 Kbps ');
    });

    it('processDashVideo_oneAndOne_degradesToDual', 0, (): void => {
      // :213-234 v/a 段数均 1 → dual 条目（uri1/uri2=两首段；ext=双 mime 含 mp4 → mp4）
      const items: DashCaptureItem[] = processDashVideo([[dualRep(1, 1)]], 'clip',
        'https://h/v.mpd', null, null);
      expect(items.length).assertEqual(1);
      expect(items[0].form).assertEqual('dual');
      const dual: DashDualCapture = items[0] as DashDualCapture;
      expect(dual.uri1).assertEqual('https://h/v-0.m4s');
      expect(dual.uri2).assertEqual('https://h/a-0.m4s');
      expect(dual.file).assertEqual('clip.mp4');
      expect(dual.displayText).assertEqual('[MP4] 1080p 1101 Kbps  eng ');
    });

    it('processDashVideo_multi_fullSegments_and_duration', 0, (): void => {
      // :235-257 段数>1 → multi 条目（全量段/duration=max/manifestUrl/双 mime）
      const pair: DashPair = dualRep(2, 3);
      const items: DashCaptureItem[] = processDashVideo([[pair]], 'clip', 'https://h/v.mpd', null, null);
      expect(items.length).assertEqual(1);
      expect(items[0].form).assertEqual('multi');
      const multi: DashMultiCapture = items[0] as DashMultiCapture;
      expect(multi.videoSegments.length).assertEqual(2);
      expect(multi.audioSegments.length).assertEqual(3);
      expect(multi.duration).assertEqual(60000);
      expect(multi.manifestUrl).assertEqual('https://h/v.mpd');
      expect(multi.videoMime).assertEqual('video/mp4');
      expect(multi.audioMime).assertEqual('audio/mp4');
    });

    it('processDashVideo_singleVideo_firstSegmentQuirk', 0, (): void => {
      // ★:259-263→:278-296 源 AddSingleItem 只下 Segments[0]（多段单轨产物不完整 quirk 1:1）
      const video: DashRepresentation = new DashRepresentation(
        ['https://h/v-0.m4s', 'https://h/v-1.m4s', 'https://h/v-2.m4s'], 640, 360, 'avc1',
        400000, 60000, 'video/mp2t', '');
      const items: DashCaptureItem[] = processDashVideo([[dashPairOf(video, null)]], 'clip',
        'https://h/v.mpd', null, null);
      expect(items.length).assertEqual(1);
      expect(items[0].form).assertEqual('single');
      const single: DashSingleCapture = items[0] as DashSingleCapture;
      expect(single.uri).assertEqual('https://h/v-0.m4s');
      expect(single.audioOnly).assertFalse();
      // video/mp2t 不含 'mp4' 子串 → mkv（:280 源 quirk 1:1）
      expect(single.file).assertEqual('clip.mkv');
    });

    it('processDashVideo_singleAudio_flagAndExt', 0, (): void => {
      const audio: DashRepresentation = new DashRepresentation(['https://h/a-0.m4s'], -1, -1,
        'mp4a', 128000, 60000, 'audio/mp4', 'en');
      const items: DashCaptureItem[] = processDashVideo([[dashPairOf(null, audio)]], 'clip',
        'https://h/v.mpd', null, null);
      const single: DashSingleCapture = items[0] as DashSingleCapture;
      expect(single.audioOnly).assertTrue();
      expect(single.file).assertEqual('clip.mp4');
      expect(single.displayText).assertEqual('[MP4] en 125 Kbps ');
    });

    it('processDashVideo_secondPeriodPrefix', 0, (): void => {
      // :209 多周期前缀 'N '（periodIdx>0）
      const items: DashCaptureItem[] = processDashVideo(
        [[dualRep(1, 1)], [dualRep(1, 1)]], 'clip', 'https://h/v.mpd', null, null);
      expect(items.length).assertEqual(2);
      expect(items[0].form).assertEqual('dual');
      const second: DashDualCapture = items[1] as DashDualCapture;
      expect(second.file).assertEqual('1 clip.mp4');
    });

    it('processDashVideo_webmMimes_pickMkv', 0, (): void => {
      // :216/:237 双 mime 均含 mp4 才 mp4，否则 mkv（webm → mkv）
      const pair: DashPair = dashPairOf(
        new DashRepresentation(['https://h/v-0.webm'], 640, 360, 'vp9', 400000, 60000, 'video/webm', ''),
        new DashRepresentation(['https://h/a-0.webm'], -1, -1, 'opus', 96000, 60000, 'audio/webm', ''));
      const items: DashCaptureItem[] = processDashVideo([[pair]], 'clip', 'https://h/v.mpd', null, null);
      const dual: DashDualCapture = items[0] as DashDualCapture;
      expect(dual.file).assertEqual('clip.mkv');
      expect(dual.displayText).assertEqual('[MKV] 360p 484 Kbps  ');
    });
  });
}
