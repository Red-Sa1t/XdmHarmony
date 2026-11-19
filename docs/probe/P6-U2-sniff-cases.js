#!/usr/bin/env node
/*
 * P6-U2 规则链用例表 Node 自验脚本（设计书 u6-2-sniff-rule-chain-video-capture-DESIGN.md §5.0）。
 * 用途：`node docs/probe/P6-U2-sniff-cases.js` 主机侧直接跑——SUMMARY pass=65 fail=0、退出码 0
 * 即单元验收『规则链用例表全绿（纯逻辑单测）』的 AI 可自验证据；ArkTS 侧
 * （entry/src/test/VideoSniffAlgo.test.ets）按同一张表落 Hypium（双份用例表同源同验，§0-1）。
 * 镜像对象：entry/src/main/ets/core/bridge/VideoSniffAlgo.ets（零 @kit 纯函数组）+
 * BridgeRoutes.processMediaMessage 的 C 组编排镜像 + BridgeJson.buildBridgeMessage 的 F2 回归位。
 * 对照源码（只读核实）：chrome-extension/request-watcher.js:49-98（isMatchingRequest 八层+
 * sendGate）；VideoUrlHelper.cs:35-65/:409-613/:67-90/:631-695/:697-761/:786-823/:888-902/:904-966；
 * NewVideoDownloadDialogUIController.cs:40-47（MP3 复选框门）；LinkRefresher.cs:46-63（谓词备查）。
 * 怪癖 1:1 钉死（设计书 §0-3/关键约束，勿顺手修好）：range 前缀与空 key 参数剔除且末位剔除留尾随 '&'
 * （D6）、str.StartsWith('id') 原始串判定（identity=x 命中）、itag/clen 严格十进制门异常→catch→
 * return false 落普通门（D11）、入队前 >32 裁剪稳态 33（D18）、getDashPair 自队尾扫描+lastVid 同
 * Length 守卫（D15~D17）、HandleDashAudio 'mkv' 缺点保留（D13）、大写 ITAG→itag=0 不短路（D10）、
 * Itags 60 项（D22，'Hi  bitrate' 双空格）。
 */

'use strict';

const crypto = require('crypto');

// ────────────── 镜像：纯函数基础件（VideoSniffAlgo.ets / FileNames.ets / Formatting.ets 同构） ──────────────

function sanitizeFileName(name) {
  let file = name;
  const slash = name.lastIndexOf('/');
  const backslash = name.lastIndexOf('\\');
  const cut = slash > backslash ? slash : backslash;
  if (cut >= 0) file = name.slice(cut + 1);
  let out = '';
  for (let i = 0; i < file.length; i++) {
    const ch = file.charAt(i);
    const bad = '\\/:*?"<>|'.indexOf(ch) >= 0 || ch.charCodeAt(0) <= 0x1f;
    out += bad ? '_' : ch;
  }
  return out.length === 0 ? 'file' : out;
}

function fileNameFromUrl(url) {
  let clean = url;
  const qm = clean.indexOf('?');
  if (qm >= 0) clean = clean.slice(0, qm);
  const hash = clean.indexOf('#');
  if (hash >= 0) clean = clean.slice(0, hash);
  const schemeEnd = clean.indexOf('://');
  const from = schemeEnd >= 0 ? schemeEnd + 3 : 0;
  const pathStart = clean.indexOf('/', from);
  const host = pathStart >= 0 ? clean.slice(from, pathStart) : clean.slice(from);
  const path = pathStart >= 0 ? clean.slice(pathStart + 1) : '';
  let decoded = path;
  if (path.length > 0) {
    try { decoded = decodeURIComponent(path); } catch (e) { decoded = path; }
  }
  if (decoded.length === 0) {
    return sanitizeFileName(host.split('.').join('_'));
  }
  return sanitizeFileName(decoded);
}

/** 源 FileHelper.SanitizeFileName 空串语义镜像（''→'' 空 in 空 out；R1-F2——FileNames 的
 * 'file' 兜底会误改空串行为，/link pending、HandleDashAudio/CreateDual 源侧空串 file 不回退）。 */
function sanitizeOrEmpty(name) {
  return name.length === 0 ? '' : sanitizeFileName(name);
}

function formatSize(length) {
  const GB = 1073741824, MB = 1048576, KB = 1024;
  if (length <= 0) return '---';
  if (length > GB) return `${(length / GB).toFixed(1)}G`;
  if (length > MB) return `${(length / MB).toFixed(1)}M`;
  if (length > KB) return `${(length / KB).toFixed(1)}K`;
  return `${Math.floor(length)}B`;
}

function getExtensionOf(name) {
  const slash = name.lastIndexOf('/');
  const backslash = name.lastIndexOf('\\');
  const cut = slash > backslash ? slash : backslash;
  const lastSeg = cut >= 0 ? name.slice(cut + 1) : name;
  const dot = lastSeg.lastIndexOf('.');
  if (dot < 0) return '';
  return lastSeg.slice(dot);
}

function parentDirUri(url) {
  let clean = url;
  const qm = clean.indexOf('?');
  if (qm >= 0) clean = clean.slice(0, qm);
  const hash = clean.indexOf('#');
  if (hash >= 0) clean = clean.slice(0, hash);
  const slash = clean.lastIndexOf('/');
  if (slash < 0) return clean;
  return clean.slice(0, slash + 1);
}

// ────────────── 镜像：头容器 ──────────────

function headersOf(pairs) {
  const names = [], values = [];
  for (const [n, vs] of pairs) { names.push(n); values.push(vs.slice()); }
  return { names, values };
}

function headerValueFirst(h, key) {
  if (h === null) return null;
  let idx = h.names.indexOf(key);
  if (idx < 0) idx = h.names.indexOf(key.toLowerCase());
  if (idx < 0) return null;
  const vals = h.values[idx];
  return vals.length === 0 ? null : vals[0];
}

function contentLengthOf(responseHeaders) {
  const raw = headerValueFirst(responseHeaders, 'Content-Length');
  if (raw === null) return 0;
  if (!/^[+-]?[0-9]+$/.test(raw)) return 0;
  return Number(raw);
}

// ────────────── 镜像：isMatchingRequest 八层+sendGate（request-watcher.js:49-98） ──────────────

const DEFAULT_CFG = {
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

function hostOfUrl(url) {
  const schemeEnd = url.indexOf('://');
  if (schemeEnd < 0) return '';
  const rest = url.slice(schemeEnd + 3);
  let end = rest.length;
  const slash = rest.indexOf('/');
  if (slash >= 0 && slash < end) end = slash;
  const qm = rest.indexOf('?');
  if (qm >= 0 && qm < end) end = qm;
  const hash = rest.indexOf('#');
  if (hash >= 0 && hash < end) end = hash;
  const authority = rest.slice(0, end);
  const at = authority.lastIndexOf('@');
  return at >= 0 ? authority.slice(at + 1) : authority;
}

function urlPathOf(url) {
  const schemeEnd = url.indexOf('://');
  if (schemeEnd < 0) return '';
  const rest = url.slice(schemeEnd + 3);
  const slash = rest.indexOf('/');
  if (slash < 0) return '';
  let path = rest.slice(slash);
  const qm = path.indexOf('?');
  if (qm >= 0) path = path.slice(0, qm);
  const hash = path.indexOf('#');
  if (hash >= 0) path = path.slice(0, hash);
  return path;
}

function indexOfHeaderUpper(h, upperName) {
  for (let i = 0; i < h.names.length; i++) {
    if (h.names[i].toUpperCase() === upperName) return i;
  }
  return -1;
}

function firstValueOf(h, idx) {
  const vals = h.values[idx];
  return vals.length > 0 ? vals[0] : '';
}

function isMatchingRequest(cfg, url, responseHeaders) {
  const host = hostOfUrl(url);
  if (host.length === 0) return false;
  for (const h of cfg.blockedHosts) { if (host.indexOf(h) >= 0) return false; }
  const upath = urlPathOf(url).toUpperCase();
  for (const e of cfg.mediaExts) { if (upath.endsWith(e)) return true; }
  for (const e of cfg.requestFileExts) { if (upath.endsWith(e)) return true; }
  try {
    for (const re of cfg.urlPatternRes) { if (re.test(url)) return true; }
  } catch (e) { /* 源 :71 catch {} */ }
  const ctIdx = indexOfHeaderUpper(responseHeaders, 'CONTENT-TYPE');
  if (ctIdx >= 0) {
    const ctVal = firstValueOf(responseHeaders, ctIdx);
    for (const m of cfg.mediaTypes) { if (ctVal.indexOf(m) >= 0) return true; }
  }
  for (const e of cfg.fileExts) { if (upath.endsWith('.' + e)) return true; }
  const cdIdx = indexOfHeaderUpper(responseHeaders, 'CONTENT-DISPOSITION');
  if (cdIdx >= 0) {
    const cdVal = firstValueOf(responseHeaders, cdIdx).toUpperCase();
    for (const ext of cfg.fileExts) { if (cdVal.indexOf('.' + ext) >= 0) return true; }
  }
  for (const h of cfg.matchingHosts) { if (host.indexOf(h) >= 0) return true; }
  return false;
}

function passesSendGate(method, url, matchingHosts) {
  if (method === 'GET') return true;
  for (const h of matchingHosts) { if (url.indexOf(h) > 0) return true; }
  return false;
}

// ────────────── 镜像：分派链谓词（VideoUrlHelper.cs:697-761） ──────────────

function isYtFormat(contentType) {
  if (contentType === null || contentType.length === 0) return false;
  return contentType.toLowerCase().indexOf('application/json') >= 0;
}

function isHLS(contentType) {
  return contentType.indexOf('mpegurl') >= 0 || contentType.indexOf('.m3u8') >= 0 ||
    contentType.indexOf('m3u8') >= 0;
}

function isHLSUrl(url) {
  if (url === null) return false;
  return url.toLowerCase().indexOf('.m3u8') >= 0;
}

function isDASH(contentType) {
  return contentType.indexOf('dash') >= 0;
}

function isDASHUrl(url) {
  if (url === null) return false;
  return url.toLowerCase().indexOf('.mpd') >= 0;
}

function isNormalVideoItag(itag) {
  return (itag > 4 && itag < 79) || (itag > 81 && itag < 86) || (itag > 99 && itag < 103);
}

// ────────────── 镜像：isNormalVideo 五条件+extFromMedia+qualityText（VideoUrlHelper.cs:67-90/:631-687） ──────────────

function isNormalVideo(state, contentType, url, size, tabId, minBytes) {
  if (size > 0 && size < minBytes) return false;
  if (tabId !== null && tabId.length > 0 && state.m3u8Tabs.has(tabId)) return false;
  if (url.toLowerCase().indexOf('init.mp4') >= 0) {
    state.suspectedFragments.add(parentDirUri(url));
    return false;
  }
  if (state.suspectedFragments.has(parentDirUri(url))) return false;
  return contentType !== null && !(contentType.indexOf('f4f') >= 0 ||
    contentType.indexOf('m4s') >= 0 || url.indexOf('abst') >= 0 ||
    url.indexOf('f4x') >= 0 || url.indexOf('.fbcdn') >= 0 ||
    url.indexOf('http://127.0.0.1:9614') >= 0);
}

function extFromMedia(typeLower, urlLower) {
  if (typeLower.indexOf('video/mp4') >= 0) return 'mp4';
  if (typeLower.indexOf('video/x-flv') >= 0) return 'flv';
  if (typeLower.indexOf('video/webm') >= 0) return 'mkv';
  if (typeLower.indexOf('matroska') >= 0 || typeLower.indexOf('mkv') >= 0) return 'mkv';
  if (typeLower === 'audio/mpeg' || typeLower.indexOf('audio/mp3') >= 0) return 'mp3';
  if (typeLower.indexOf('audio/aac') >= 0) return 'aac';
  if (typeLower.indexOf('audio/mp4') >= 0) return 'm4a';
  if (urlLower.indexOf('.mp4') >= 0) return 'mp4';
  if (urlLower.indexOf('.mkv') >= 0) return 'mkv';
  if (urlLower.indexOf('.ts') >= 0) return 'ts';
  return null;
}

function qualityText(ext, size) {
  return '[' + ext.toUpperCase() + '] ' + (size > 0 ? formatSize(size) : '');
}

// ────────────── 镜像：sha1（node:crypto——E2 已知向量交叉验证位） ──────────────

function sha1Hex(input) {
  return crypto.createHash('sha1').update(Buffer.from(input, 'utf8')).digest('hex');
}

// ────────────── 镜像：YT-DASH 段配对全量（VideoUrlHelper.cs:409-613） ──────────────

const ITAG_KEYS = [5, 133, 6, 134, 135, 136, 264, 137, 266, 139, 140, 13, 141, 271, 272, 17, 18,
  22, 278, 160, 34, 35, 36, 37, 38, 167, 168, 169, 170, 298, 43, 171, 299, 44, 172, 45, 46, 302,
  303, 308, 313, 59, 315, 78, 82, 83, 84, 85, 218, 219, 100, 101, 102, 242, 243, 244, 245, 246,
  247, 248];
const ITAG_VALUES = ['240p', '240p', '270p', '360p', '480p', '720p', '1440p', '1080p', '2160p',
  'Low bitrate', 'Med bitrate', 'Small', 'Hi  bitrate', '1440p', '2160p', '144p', '360p', '720p',
  '144p', '144p', '360p', '480p', '240p', '1080p', '1080p', '360p', '480p', '720p', '1080p', '720p',
  '360p', 'Med bitrate', '2160p', '480p', 'Hi  bitrate', '720p', '1080p', '720p', '1080p', '1440p',
  '2160p', '480p', '2160p', '480p', '360p 3D', '480p 3D', '720p 3D', '1080p 3D', '480p', '480p',
  '360p 3D', '480p 3D', '720p 3D', '240p', '360p', '480p', '480p', '480p', '720p', '1080p'];

function itagQuality(itag) {
  for (let i = 0; i < ITAG_KEYS.length; i++) {
    if (ITAG_KEYS[i] === itag) return ITAG_VALUES[i];
  }
  return 'MKV';
}

function newState() {
  return {
    suspectedFragments: new Set(),
    m3u8Tabs: new Set(),
    referersToSkip: new Set(),
    videoQueue: [],
    audioQueue: [],
    lastVid: null
  };
}

function newSink() {
  return {
    singles: [],
    duals: [],
    onSingle(seg) { this.singles.push(seg); },
    onDual(seg) { this.duals.push(seg); }
  };
}

function parseKeyValuePairOf(line, delimiter) {
  const trimmed = line.trim();
  const index = trimmed.indexOf(delimiter);
  if (index < 1) return ['', ''];
  return [trimmed.slice(0, index).trim(), trimmed.slice(index + 1).trim()];
}

function parseInt64Gate(val) {
  if (!/^[+-]?[0-9]+$/.test(val)) throw new Error('not a decimal integer: ' + val);
  const n = Number(val);
  if (!Number.isFinite(n) || Math.abs(n) > Number.MAX_SAFE_INTEGER) {
    throw new Error('beyond safe integer range: ' + val);
  }
  return n;
}

function unescapeDataString(val) {
  try { return decodeURIComponent(val); } catch (e) { return val; }
}

function addIfNew(info, queue) {
  for (let i = queue.length - 1; i >= 0; i--) {
    if (queue[i].length === info.length && queue[i].id === info.id) return false;
  }
  queue.push(info);
  return true;
}

function addToQueue(state, info) {
  if (state.videoQueue.length > 32) state.videoQueue.shift();
  if (state.audioQueue.length > 32) state.audioQueue.shift();
  if (info.isVideo) return addIfNew(info, state.videoQueue);
  return addIfNew(info, state.audioQueue);
}

function getDashPair(state, info) {
  if (info.isVideo) {
    if (state.audioQueue.length < 1) return null;
    for (let i = state.audioQueue.length - 1; i >= 0; i--) {
      if (state.audioQueue[i].id === info.id) return state.audioQueue[i];
    }
    return null;
  }
  if (state.videoQueue.length < 1) return null;
  for (let i = state.videoQueue.length - 1; i >= 0; i--) {
    const di = state.videoQueue[i];
    if (di.id === info.id) {
      if (state.lastVid !== null && state.lastVid.length === di.length) return null;
      state.lastVid = di;
      return di;
    }
  }
  return null;
}

function handleDashAudio(info, msg) {
  const size = info.length;
  const name = fileNameFromUrl(info.url);
  let ext = getExtensionOf(name);
  if (ext.length === 0) {
    ext = info.mime.indexOf('webm') >= 0 ? '.webm' :
      (info.mime.indexOf('mp4') >= 0 ? '.mp4' : 'mkv');
  }
  const quality = ext.length > 1 ? ext.substring(1).toUpperCase() : '';
  return {
    file: sanitizeOrEmpty(msg.file !== null ? msg.file : fileNameFromUrl(msg.url !== null ? msg.url : '')) + ext,
    size: size,
    contentType: info.mime,
    displayText: '[' + quality + ' AUDIO] ' + (size > 0 ? formatSize(size) : ''),
    uri: info.url,
    tabId: msg.tabId ?? '',
    tabUrl: msg.tabUrl ?? ''
  };
}

function createDualInfo(pair, fresh, msg) {
  let video = pair, audio = fresh;
  if (!pair.isVideo) { video = fresh; audio = pair; }
  return {
    file: sanitizeOrEmpty(msg.file !== null ? msg.file : fileNameFromUrl(msg.url !== null ? msg.url : '')) + '.mkv',
    size: video.length + audio.length,
    displayText: '',
    uri1: video.url,
    uri2: audio.url,
    tabId: msg.tabId ?? '',
    tabUrl: msg.tabUrl ?? ''
  };
}

function processYtDashSegment(state, msg, out) {
  try {
    const rawUrl = msg.url;
    if (rawUrl === null) return false;
    const host = hostOfUrl(rawUrl);
    if (host.indexOf('.youtube.') < 0 && host.indexOf('.googlevideo.') < 0) return false;
    const contentType = headerValueFirst(msg.responseHeaders, 'Content-Type');
    if (contentType === null) return false;
    const ctLower = contentType.toLowerCase();
    if (!(ctLower.indexOf('audio/') >= 0 || ctLower.indexOf('video/') >= 0 ||
      ctLower.indexOf('application/octet') >= 0)) return false;
    const lowUrl = rawUrl.toLowerCase();
    if (!(lowUrl.indexOf('videoplayback') >= 0 && lowUrl.indexOf('itag') >= 0)) return false;
    const kv = parseKeyValuePairOf(rawUrl, '?');
    const path = kv[0];
    const query = kv[1];
    const arr = query.split('&');
    let ytUrl = path + '?';
    let itag = 0, clen = 0, id = '', mime = '';
    for (let i = 0; i < arr.length; i++) {
      const str = arr[i];
      const kv1 = parseKeyValuePairOf(str, '=');
      const key = kv1[0], val = kv1[1];
      if (key.length === 0) continue;
      if (key.indexOf('range') === 0) continue;
      if (key === 'itag') itag = parseInt64Gate(val);
      if (key === 'clen') clen = parseInt64Gate(val);
      if (key.indexOf('mime') === 0) mime = unescapeDataString(val);
      if (str.indexOf('id') === 0) id = val;
      ytUrl += str;
      if (i < arr.length - 1) ytUrl += '&';
    }
    if (itag !== 0 && isNormalVideoItag(itag)) return false;
    const info = { url: ytUrl, length: clen, isVideo: mime.indexOf('video') === 0, itag: itag, id: id, mime: mime };
    if (addToQueue(state, info)) {
      if (!info.isVideo && mime.indexOf('audio/') === 0) {
        out.onSingle(handleDashAudio(info, msg));
      }
      const di = getDashPair(state, info);
      if (di === null) return true;
      const dual = createDualInfo(di, info, msg);
      const size = di.length + info.length;
      const quality = itagQuality(info.isVideo ? info.itag : di.itag);
      dual.displayText = '[' + quality + '] ' + (size > 0 ? formatSize(size) : '');
      out.onDual(dual);
    }
    return true;
  } catch (e) {
    return false;
  }
}

// ────────────── 镜像：BridgeRoutes.processMediaMessage 编排（VideoUrlHelper.cs:35-65 + :615-695） ──────────────

function addToSkippedRefererList(state, referer) {
  if (referer === null || referer.length === 0) return;
  state.referersToSkip.add(sha1Hex(referer));
}

function isMediaFragmentGuard(state, referer) {
  if (referer === null || referer.length === 0) return false;
  return state.referersToSkip.has(sha1Hex(referer));
}

function processNormalVideo(state, msg, contentType, sink) {
  const referer = headerValueFirst(msg.requestHeaders, 'Referer');
  if (isMediaFragmentGuard(state, referer)) return;
  let file = msg.file !== null ? msg.file : fileNameFromUrl(msg.url);
  if (file.length === 0) file = fileNameFromUrl(msg.url);
  const ext = extFromMedia(contentType.toLowerCase(), msg.url.toLowerCase());
  if (ext === null) return;
  const rawLen = headerValueFirst(msg.responseHeaders, 'Content-Length');
  if (rawLen === null) throw new Error('Content-Length required for media');
  if (!/^[+-]?[0-9]+$/.test(rawLen)) throw new Error('Content-Length invalid for media');
  const size = Number(rawLen);
  sink.onSingle({
    file: sanitizeFileName(file) + '.' + ext,
    size: size,
    contentType: '', // U6.2 收敛 c：源 ProcessNormalVideo 不设 ContentType=null
    displayText: qualityText(ext, size),
    uri: msg.url,
    tabId: msg.tabId ?? '',
    tabUrl: msg.tabUrl ?? ''
  });
}

function dispatchMedia(state, msg, sink) {
  const contentType = headerValueFirst(msg.responseHeaders, 'Content-Type');
  if (contentType === null) return;
  if (isYtFormat(contentType)) { /* 识别锚（manifest 下载 U6.4/U7.1）；源无 return 继续走 */ }
  if (isHLS(contentType) || isHLSUrl(msg.url)) {
    if (msg.tabId !== null && msg.tabId.length > 0) state.m3u8Tabs.add(msg.tabId);
    addToSkippedRefererList(state, headerValueFirst(msg.requestHeaders, 'Referer'));
  }
  if (isDASH(contentType) || isDASHUrl(msg.url)) {
    if (msg.tabId !== null && msg.tabId.length > 0) state.m3u8Tabs.add(msg.tabId);
    addToSkippedRefererList(state, headerValueFirst(msg.requestHeaders, 'Referer'));
  }
  if (!processYtDashSegment(state, msg, sink)) {
    if (msg.url === null) throw new Error('url required');
    const size = contentLengthOf(msg.responseHeaders);
    if (isNormalVideo(state, contentType, msg.url, size, msg.tabId, 1024 * 1024)) {
      processNormalVideo(state, msg, contentType, sink);
    }
  }
}

// ────────────── 镜像：E3/F 组谓词（LinkRefresher.cs:46-63 / NewVideoDownloadDialogUIController.cs:40-47） ──────────────

/** LinkAccepted 匹配谓词（设计书 §0-4 备查：FileSize==ContentLength 且>0——U6.3 落地时取用）。 */
function linkAcceptedPredicate(fileSize, contentLength) {
  return fileSize > 0 && contentLength > 0 && fileSize === contentLength;
}

/** MP3 复选框门（contentType 非空 && audio 前缀 && 非 mpeg/mp3——F3/F4 对照面）。 */
function showMp3Checkbox(contentType) {
  if (contentType !== null && contentType.length > 0) {
    const mime = contentType.toLowerCase();
    if (mime.indexOf('audio') === 0) {
      if (!(mime.indexOf('mpeg') >= 0 || mime.indexOf('mp3') >= 0)) return true;
    }
  }
  return false;
}

/** F1：/link pending {url,file} 对（handleLinkRoute 镜像：file=sanitize(file ?? fileNameFromUrl(url))）。 */
function pendingOf(items) {
  const out = [];
  for (const it of items) {
    if (it.url === null || it.url.length === 0) continue;
    out.push({ url: it.url, file: sanitizeOrEmpty(it.file !== null ? it.file : fileNameFromUrl(it.url)) });
  }
  return out;
}

// ────────────── 用例表（设计书 §5.0：A18+B9+C8+D23+E3+F4=65） ──────────────

const MIN_BYTES = 1024 * 1024;
const cases = [];
function addCase(id, desc, fn) { cases.push({ id, desc, fn }); }

function mediaMsg(url, ct, contentLength, file, tabId, referer) {
  return {
    url: url,
    requestHeaders: headersOf(referer !== null ? [['Referer', [referer]]] : []),
    responseHeaders: headersOf(contentLength !== null ?
      [['Content-Type', [ct]], ['Content-Length', [String(contentLength)]]] :
      [['Content-Type', [ct]]]),
    cookies: null,
    file: file,
    tabId: tabId,
    tabUrl: 'https://www.youtube.com/watch?v=abc'
  };
}

// ── A 组 isMatchingRequest/passSendGate（18 例：A1~A17+A8b） ──

addCase('A1', 'blockedHosts 精确域命中', () =>
  isMatchingRequest(DEFAULT_CFG, 'https://download.windowsupdate.com/c/up.exe',
    headersOf([['Content-Type', ['text/html']]])) === false);
addCase('A2', 'blockedHosts 子串命中（a.update.microsoft.com）', () =>
  isMatchingRequest(DEFAULT_CFG, 'https://a.update.microsoft.com/x',
    headersOf([['Content-Type', ['text/html']]])) === false);
addCase('A3', 'requestFileExts 大写路径 Video.MP4 endsWith(MP4)', () =>
  isMatchingRequest(DEFAULT_CFG, 'https://h/Video.MP4',
    headersOf([['Content-Type', ['text/html']]])) === true);
addCase('A4', '小写路径大写化后命中（video.mp4?x=1 仅 pathname）', () =>
  isMatchingRequest(DEFAULT_CFG, 'https://h/video.mp4?x=1',
    headersOf([['Content-Type', ['text/html']]])) === true);
addCase('A5', 'mediaTypes：Content-Type=video/mp4', () =>
  isMatchingRequest(DEFAULT_CFG, 'https://h/a',
    headersOf([['Content-Type', ['video/mp4']]])) === true);
addCase('A6', 'mediaExts 层注入 [".TS"] 后路径 a.ts 命中（恒空层参数位）', () => {
  const cfg = Object.assign({}, DEFAULT_CFG, { mediaExts: ['.TS'] });
  return isMatchingRequest(cfg, 'https://h/a.ts',
    headersOf([['Content-Type', ['text/html']]])) === true;
});
addCase('A7', 'fileExts 层：/f/setup.EXE + octet-stream', () =>
  isMatchingRequest(DEFAULT_CFG, 'https://h/f/setup.EXE',
    headersOf([['Content-Type', ['application/octet-stream']]])) === true);
addCase('A8', 'Content-Disposition .ZIP 命中（fileExts 内）', () =>
  isMatchingRequest(DEFAULT_CFG, 'https://h/a',
    headersOf([['Content-Type', ['text/html']], ['Content-Disposition',
      ['attachment; filename="a.ZIP"']]])) === true);
addCase('A8b', 'Content-Disposition .MKV 不命中（MKV∈VideoExtensions∉fileExts）', () =>
  isMatchingRequest(DEFAULT_CFG, 'https://h/a',
    headersOf([['Content-Type', ['text/html']], ['Content-Disposition',
      ['attachment; filename="a.MKV"']]])) === false);
addCase('A9', 'matchingHosts googlevideo host 命中', () =>
  isMatchingRequest(DEFAULT_CFG, 'https://rr.googlevideo.com/videoplayback',
    headersOf([['Content-Type', ['text/html']]])) === true);
addCase('A10', '全层未中（text/html+index.html）→ 隐式拒', () =>
  isMatchingRequest(DEFAULT_CFG, 'https://h/index.html',
    headersOf([['Content-Type', ['text/html']]])) === false);
addCase('A11', 'query 含 a.EXE 不参与（仅 pathname）', () =>
  isMatchingRequest(DEFAULT_CFG, 'https://h/get?a.EXE',
    headersOf([['Content-Type', ['text/html']]])) === false);
addCase('A12', 'urlPatterns 层注入正则命中（恒空层参数位）', () => {
  const cfg = Object.assign({}, DEFAULT_CFG, { urlPatternRes: [new RegExp('special/video/[0-9]+', 'i')] });
  return isMatchingRequest(cfg, 'https://h/special/video/9',
    headersOf([['Content-Type', ['text/html']]])) === true;
});
addCase('A13', 'sendGate：POST 无 matchingHost 不入', () =>
  passesSendGate('POST', 'https://h/a', DEFAULT_CFG.matchingHosts) === false);
addCase('A14', 'sendGate：POST url 下标>0 含 googlevideo 入', () =>
  passesSendGate('POST', 'https://x.googlevideo.com/v', DEFAULT_CFG.matchingHosts) === true);
addCase('A15', 'sendGate：POST url 以 googlevideo 开头（下标 0）不入（源怪癖）', () =>
  passesSendGate('POST', 'googlevideo.com/v', DEFAULT_CFG.matchingHosts) === false);
addCase('A16', 'sendGate：GET 恒入', () =>
  passesSendGate('GET', 'https://h/any', []) === true);
addCase('A17', '大写 host 屏蔽层序数敏感未中且余层未中（怪癖登记）', () =>
  isMatchingRequest(DEFAULT_CFG, 'https://WINDOWSUPDATE.COM/x',
    headersOf([['Content-Type', ['text/html']]])) === false);

// ── B 组分派链谓词（9 例） ──

addCase('B1', 'IsYtFormat 精确 application/json', () => isYtFormat('application/json') === true);
addCase('B2', 'IsYtFormat 大小写不敏感（APPLICATION/JSON）', () =>
  isYtFormat('APPLICATION/JSON; charset=utf-8') === true);
addCase('B3', 'IsYtFormat 空串 false（源 IsNullOrEmpty 门）', () => isYtFormat('') === false);
addCase('B4', 'IsHLS mpegurl 命中', () => isHLS('application/vnd.apple.mpegurl') === true);
addCase('B5', 'IsHLS 大写 MPEGURL 序数敏感不命中', () =>
  isHLS('APPLICATION/VND.APPLE.MPEGURL') === false);
addCase('B6', 'IsHLSUrl .M3U8 小写化命中', () => isHLSUrl('https://h/PLAYLIST.M3U8') === true);
addCase('B7', 'IsDASH dash+xml', () => isDASH('application/dash+xml') === true);
addCase('B8', 'IsDASHUrl .mpd 小写化命中', () => isDASHUrl('https://h/manifest.MPD') === true);
addCase('B9', 'isNormalVideoItag 十二点边界', () => {
  const pts = [[4, false], [5, true], [78, true], [79, false], [81, false], [82, true],
    [85, true], [86, false], [99, false], [100, true], [102, true], [103, false]];
  return pts.every(p => isNormalVideoItag(p[0]) === p[1]);
});

// ── C 组分派链全流程（8 例） ──

addCase('C1', 'normal video/mp4 登记（contentType 空串=收敛 c）', () => {
  const state = newState();
  const sink = newSink();
  dispatchMedia(state, mediaMsg('https://h/v/clip.mp4', 'video/mp4', 5242880, 'Movie', '1', null), sink);
  return sink.singles.length === 1 && sink.singles[0].file === 'Movie.mp4' &&
    sink.singles[0].contentType === '' && sink.singles[0].displayText.indexOf('[MP4]') === 0;
});
addCase('C2', 'application/json→YT 识别锚无登记（ext 门 miss return）', () => {
  const state = newState();
  const sink = newSink();
  dispatchMedia(state, mediaMsg('https://h/api/manifest', 'application/json', null, null, '1', null), sink);
  return sink.singles.length === 0 && sink.duals.length === 0;
});
addCase('C3', '.m3u8→m3u8Tabs+referer 写入（源序=manifest 拉取之前）', () => {
  const state = newState();
  const sink = newSink();
  dispatchMedia(state, mediaMsg('https://h/list.m3u8', 'application/vnd.apple.mpegurl', null, null, '200', 'R1'), sink);
  return state.m3u8Tabs.has('200') && state.referersToSkip.has(sha1Hex('R1')) &&
    sink.singles.length === 0;
});
addCase('C4', '同 tabId .ts 段被门②拦截（U6.1 §7-3 暂态消除）', () => {
  const state = newState();
  const sink = newSink();
  dispatchMedia(state, mediaMsg('https://h/list.m3u8', 'application/vnd.apple.mpegurl', null, null, '200', 'R1'), sink);
  dispatchMedia(state, mediaMsg('https://h/seg/001.ts', 'video/mp2t', 300000, null, '200', 'R1'), sink);
  return sink.singles.length === 0 && sink.duals.length === 0;
});
addCase('C5', '同 referer 普通视频被 IsMediaFragment 拦（sha1 键）', () => {
  const state = newState();
  const sink = newSink();
  dispatchMedia(state, mediaMsg('https://h/list2.m3u8', 'application/vnd.apple.mpegurl', null, null, '201', 'R1'), sink);
  dispatchMedia(state, mediaMsg('https://h/v/clip.mp4', 'video/mp4', 5242880, null, '201', 'R1'), sink);
  return sink.singles.length === 0;
});
addCase('C6', '异 referer 正常登记（异 tab——同 tab 会被门②拦=C4）', () => {
  const state = newState();
  const sink = newSink();
  dispatchMedia(state, mediaMsg('https://h/list2.m3u8', 'application/vnd.apple.mpegurl', null, null, '201', 'R1'), sink);
  dispatchMedia(state, mediaMsg('https://h/v/clip.mp4', 'video/mp4', 5242880, null, '202', 'R2'), sink);
  return sink.singles.length === 1 && sink.singles[0].file.indexOf('.mp4') > 0;
});
addCase('C7', 'init.mp4 疑似分片集拦兄弟段', () => {
  const state = newState();
  const sink = newSink();
  dispatchMedia(state, mediaMsg('https://h/a/b/init.mp4?x=1', 'video/mp4', 9999999, null, '1', null), sink);
  const wrote = state.suspectedFragments.has('https://h/a/b/');
  dispatchMedia(state, mediaMsg('https://h/a/b/seg-1.mp4', 'video/mp4', 9999999, null, '1', null), sink);
  return wrote && sink.singles.length === 0;
});
addCase('C8', 'size<MinVideoSize*1024 拒', () => {
  const state = newState();
  const sink = newSink();
  dispatchMedia(state, mediaMsg('https://h/v/tiny.mp4', 'video/mp4', 512, null, '1', null), sink);
  return sink.singles.length === 0;
});

// ── D 组 YT-DASH 配对（23 例） ──

const GV = 'https://rr.googlevideo.com/videoplayback';

addCase('D1', 'host 门拒绝（非 youtube/googlevideo）', () => {
  const state = newState();
  return processYtDashSegment(state, mediaMsg(GV.replace('rr.googlevideo.com', 'h.example.com') +
    '?itag=140&clen=1000', 'audio/mp4', null, null, '1', null), newSink()) === false;
});
addCase('D2', 'contentType 门拒绝（text/html）', () => {
  const state = newState();
  return processYtDashSegment(state, mediaMsg(GV + '?itag=140&clen=1000', 'text/html', null, null, '1', null), newSink()) === false;
});
addCase('D3', 'url 门拒绝（无 itag 参数）', () => {
  const state = newState();
  return processYtDashSegment(state, mediaMsg(GV + '?clen=1000', 'audio/mp4', null, null, '1', null), newSink()) === false;
});
addCase('D4', '音频段消费（true）', () => {
  const state = newState();
  return processYtDashSegment(state, mediaMsg(GV + '?itag=140&mime=audio%2Fmp4&clen=1000&id=oA',
    'audio/mp4', null, 'YT Video', '1', null), newSink()) === true;
});
addCase('D5', '[MP4 AUDIO] 1000B + .mp4 后缀 + contentType=mime', () => {
  const state = newState();
  const sink = newSink();
  processYtDashSegment(state, mediaMsg(GV + '?itag=140&mime=audio%2Fmp4&clen=1000&id=oA',
    'audio/mp4', null, 'YT Video', '1', null), sink);
  return sink.singles.length === 1 && sink.singles[0].file === 'YT Video.mp4' &&
    sink.singles[0].displayText === '[MP4 AUDIO] 1000B' && sink.singles[0].contentType === 'audio/mp4';
});
addCase('D6', 'range 末位丢参留尾随 &（源怪癖 1:1）', () => {
  const state = newState();
  processYtDashSegment(state, mediaMsg(GV + '?itag=140&mime=audio%2Fmp4&id=oA&range=0-1000',
    'audio/mp4', null, 'YT Video', '1', null), newSink());
  return state.audioQueue.length === 1 && state.audioQueue[0].url.endsWith('&') &&
    state.audioQueue[0].url.indexOf('range') < 0;
});
addCase('D7', '同 id 配对→yt 双源 .mkv file', () => {
  const state = newState();
  const sink = newSink();
  processYtDashSegment(state, mediaMsg(GV + '?itag=140&mime=audio%2Fmp4&clen=1000&id=oA', 'audio/mp4', null, 'YT Video', '1', null), sink);
  processYtDashSegment(state, mediaMsg(GV + '?itag=137&mime=video%2Fmp4&clen=2000&id=oA', 'video/mp4', null, 'YT Video', '1', null), sink);
  return sink.duals.length === 1 && sink.duals[0].file === 'YT Video.mkv';
});
addCase('D8', '配对 size=3000 display [1080p] 2.9K', () => {
  const state = newState();
  const sink = newSink();
  processYtDashSegment(state, mediaMsg(GV + '?itag=140&mime=audio%2Fmp4&clen=1000&id=oA', 'audio/mp4', null, 'YT Video', '1', null), sink);
  processYtDashSegment(state, mediaMsg(GV + '?itag=137&mime=video%2Fmp4&clen=2000&id=oA', 'video/mp4', null, 'YT Video', '1', null), sink);
  return sink.duals[0].size === 3000 && sink.duals[0].displayText === '[1080p] 2.9K';
});
addCase('D9', 'itag=22 短路落普通门（返回 false）', () => {
  const state = newState();
  return processYtDashSegment(state, mediaMsg(GV + '?itag=22&mime=video%2Fmp4&clen=5000&id=oB',
    'video/mp4', null, null, '1', null), newSink()) === false;
});
addCase('D10', '大写 ITAG→itag=0 不短路仍消费（源怪癖）', () => {
  const state = newState();
  return processYtDashSegment(state, mediaMsg(GV + '?ITAG=137&mime=video%2Fmp4&clen=2000&id=oC',
    'video/mp4', null, null, '1', null), newSink()) === true && state.videoQueue.length === 1;
});
addCase('D11', 'itag=abc Parse 抛→catch→false', () => {
  const state = newState();
  return processYtDashSegment(state, mediaMsg(GV + '?itag=abc&mime=video%2Fmp4&clen=100&id=oD',
    'video/mp4', null, null, '1', null), newSink()) === false;
});
addCase('D12', 'audio/webm→[WEBM AUDIO]+.webm', () => {
  const state = newState();
  const sink = newSink();
  processYtDashSegment(state, mediaMsg(GV + '?itag=139&mime=audio%2Fwebm&clen=1000&id=oE',
    'audio/webm', null, 'YT Video', '1', null), sink);
  return sink.singles[0].file === 'YT Video.webm' && sink.singles[0].displayText === '[WEBM AUDIO] 1000B';
});
addCase('D13', 'audio/flac→ext=mkv 缺点→文件 Clipmkv+[KV AUDIO]（源怪癖 1:1）', () => {
  const state = newState();
  const sink = newSink();
  processYtDashSegment(state, mediaMsg(GV + '?itag=139&mime=audio%2Fflac&clen=1000&id=oF',
    'audio/flac', null, 'Clip', '1', null), sink);
  return sink.singles[0].file === 'Clipmkv' && sink.singles[0].displayText === '[KV AUDIO] 1000B';
});
addCase('D14', 'AddIfNew (length,id) 去重（第二次不入队不再登记）', () => {
  const state = newState();
  const sink = newSink();
  const msg = mediaMsg(GV + '?itag=140&mime=audio%2Fmp4&clen=1000&id=oA', 'audio/mp4', null, 'YT Video', '1', null);
  processYtDashSegment(state, msg, sink);
  processYtDashSegment(state, msg, sink);
  return sink.singles.length === 1 && state.audioQueue.length === 1;
});
addCase('D15', '配对自队尾（音频命中最新视频 2500→size 3500）', () => {
  const state = newState();
  const sink = newSink();
  processYtDashSegment(state, mediaMsg(GV + '?itag=137&mime=video%2Fmp4&clen=1000&id=oG', 'video/mp4', null, null, '1', null), sink);
  processYtDashSegment(state, mediaMsg(GV + '?itag=137&mime=video%2Fmp4&clen=2500&id=oG', 'video/mp4', null, null, '1', null), sink);
  processYtDashSegment(state, mediaMsg(GV + '?itag=140&mime=audio%2Fmp4&clen=1000&id=oG', 'audio/mp4', null, 'V', '1', null), sink);
  return sink.duals.length === 1 && sink.duals[0].size === 3500;
});
addCase('D16', 'lastVid 守卫挡同视频二次配对', () => {
  const state = newState();
  const sink = newSink();
  processYtDashSegment(state, mediaMsg(GV + '?itag=137&mime=video%2Fmp4&clen=1000&id=oH', 'video/mp4', null, null, '1', null), sink);
  processYtDashSegment(state, mediaMsg(GV + '?itag=140&mime=audio%2Fmp4&clen=1000&id=oH', 'audio/mp4', null, null, '1', null), sink);
  processYtDashSegment(state, mediaMsg(GV + '?itag=140&mime=audio%2Fmp4&clen=2000&id=oH', 'audio/mp4', null, null, '1', null), sink);
  return sink.duals.length === 1;
});
addCase('D17', '视频到达侧命中最新音频→dual size=4001 [720p] 3.9K', () => {
  const state = newState();
  const sink = newSink();
  processYtDashSegment(state, mediaMsg(GV + '?itag=140&mime=audio%2Fmp4&clen=2001&id=oI', 'audio/mp4', null, null, '1', null), sink);
  processYtDashSegment(state, mediaMsg(GV + '?itag=302&mime=video%2Fmp4&clen=2000&id=oI', 'video/mp4', null, null, '1', null), sink);
  return sink.duals.length === 1 && sink.duals[0].size === 4001 && sink.duals[0].displayText === '[720p] 3.9K';
});
addCase('D18', '队列稳态 33（34 入队后）', () => {
  const state = newState();
  for (let i = 1; i <= 34; i++) {
    processYtDashSegment(state, mediaMsg(GV + '?itag=140&mime=audio%2Fmp4&clen=' + String(i * 10) + '&id=q' + String(i),
      'audio/mp4', null, null, '1', null), newSink());
  }
  return state.audioQueue.length === 33;
});
addCase('D19', '队首最老被挤（入队前裁剪）', () => {
  const state = newState();
  processYtDashSegment(state, mediaMsg(GV + '?itag=140&mime=audio%2Fmp4&clen=1&id=old', 'audio/mp4', null, null, '1', null), newSink());
  for (let i = 1; i <= 33; i++) {
    processYtDashSegment(state, mediaMsg(GV + '?itag=140&mime=audio%2Fmp4&clen=' + String(1000 + i * 10) + '&id=q' + String(i),
      'audio/mp4', null, null, '1', null), newSink());
  }
  return state.audioQueue.length === 33 && state.audioQueue.every(x => x.id !== 'old');
});
addCase('D20', 'application/octet 入音频侧不触发 HandleDashAudio（mime 参数缺）', () => {
  const state = newState();
  const sink = newSink();
  const ok = processYtDashSegment(state, mediaMsg(GV + '?itag=251&clen=3000&id=oJ',
    'application/octet-stream', null, null, '1', null), sink);
  return ok === true && state.audioQueue.length === 1 && sink.singles.length === 0;
});
addCase('D21', 'Itags 缺项默认 MKV→[MKV] 1000B', () => {
  const state = newState();
  const sink = newSink();
  processYtDashSegment(state, mediaMsg(GV + '?itag=140&mime=audio%2Fmp4&clen=400&id=oK', 'audio/mp4', null, null, '1', null), sink);
  processYtDashSegment(state, mediaMsg(GV + '?itag=999&mime=video%2Fmp4&clen=600&id=oK', 'video/mp4', null, null, '1', null), sink);
  return sink.duals.length === 1 && sink.duals[0].displayText === '[MKV] 1000B';
});
addCase('D22', 'Itags 60 项（研究结论 63 勘误，:906-965 逐行清点）', () =>
  ITAG_KEYS.length === 60 && ITAG_VALUES.length === 60);
addCase('D23', 'Itags 抽查 137/141（双空格）/82', () =>
  itagQuality(137) === '1080p' && itagQuality(141) === 'Hi  bitrate' && itagQuality(82) === '360p 3D');

// ── E 组 sha1/LinkAccepted 谓词（3 例） ──

addCase('E1', 'sha1 输出 40 位小写 hex', () => /^[0-9a-f]{40}$/.test(sha1Hex('https://media.example.com/page')));
addCase('E2', "sha1('abc') 已知向量（node:crypto 交叉验证）", () =>
  sha1Hex('abc') === 'a9993e364706816aba3e25717850c26c9cd0d89d');
addCase('E3', 'LinkAccepted 谓词三态（FileSize==ContentLength 且>0）', () =>
  linkAcceptedPredicate(500, 500) === true && linkAcceptedPredicate(500, 600) === false &&
  linkAcceptedPredicate(0, 0) === false);

// ── F 组 pending 对/MP3 门（4 例） ──

addCase('F1', '/link pending {url,file} 对（收敛 b）', () => {
  const pending = pendingOf([
    { url: 'https://h/f/pack.zip', file: 'pack.zip' },
    { url: 'https://h/f/doc.pdf', file: null },
    { url: '', file: 'skip' }
  ]);
  return pending.length === 2 && pending[0].url === 'https://h/f/pack.zip' &&
    pending[0].file === 'pack.zip' && pending[1].file === 'doc.pdf';
});
addCase('F2', "MP3 复选框门：'' 无框（normal 条目）", () => showMp3Checkbox('') === false);
addCase('F3', "MP3 复选框门：audio/mp4 有框（HandleDashAudio 条目）", () =>
  showMp3Checkbox('audio/mp4') === true);
addCase('F4', 'MP3 复选框门：audio/mpeg、audio/mp3 无框', () =>
  showMp3Checkbox('audio/mpeg') === false && showMp3Checkbox('audio/mp3') === false);

// ────────────── runner ──────────────

let pass = 0;
let fail = 0;
const groups = {};
for (const c of cases) {
  const g = c.id.replace(/[0-9b]+$/, '').toUpperCase();
  let ok = false;
  let errText = '';
  try {
    ok = c.fn();
  } catch (e) {
    ok = false;
    errText = String(e.message || e);
  }
  if (ok) {
    pass++;
  } else {
    fail++;
  }
  groups[g] = (groups[g] || 0) + 1;
  console.log(`[${c.id}] ${ok ? 'pass' : 'FAIL'} ${c.desc}${errText ? ' | err=' + errText : ''}`);
}
console.log(`SUMMARY pass=${pass} fail=${fail} total=${cases.length} groups=${JSON.stringify(groups)}`);
process.exit(fail > 0 ? 1 : 0);
