import { HlsMediaSegment, HlsPlaylist, HLS_MAX_URL_CHARS } from './HlsModel';
import { guessHlsContainer, HLS_MAX_SEGMENTS } from './HlsParser';
import { DASH_MAX_SEGMENTS } from './DashModel';

export const ADAPTIVE_MAX_CHUNKS: number = HLS_MAX_SEGMENTS * 2;
export const ADAPTIVE_MAX_PLAN_CHARS: number = 8388608;
export const ADAPTIVE_MAX_STATE_CHARS: number = 16777216;
export const ADAPTIVE_MAX_PARALLEL: number = 64;

export class AdaptiveTrack {
  index: number = 0;
  role: string = 'muxed';
  playlistUrl: string = '';
  container: string = '.mkv';
  endList: boolean = false;
}

export class AdaptiveChunk {
  id: string = '';
  trackIndex: number = 0;
  trackOrder: number = 0;
  url: string = '';
  offset: number = 0;
  length: number = -1;
  duration: number = 0;
  isInit: boolean = false;
  mediaSequence: number = 0;
  discontinuity: boolean = false;
  discontinuitySequence: number = 0;
}

export class AdaptivePlan {
  kind: string = 'Hls';
  primaryUrl: string = '';
  secondaryUrl: string = '';
  tracks: AdaptiveTrack[] = [];
  chunks: AdaptiveChunk[] = [];
  duration: number = 0;
  suggestedExtension: string = '.mkv';
}

/** MimeTypes.cs video/audio 两族 20 项键表（:28-67 逐行，video/mp2t 重复赋值归一；平行数组——
 * ArkTS Record 键必须 string 且禁结构化查找面，对齐 VideoSniffAlgo.Itags 惯例）。 */
const DASH_MIME_KEYS: string[] = ['video/x-msvideo', 'video/x-flv', 'audio/x-wav', 'audio/basic',
  'audio/x-aiff', 'video/3gpp', 'audio/mid', 'audio/mpeg', 'video/x-ms-wmv', 'video/mpeg',
  'video/quicktime', 'video/flv', 'video/mp4', 'video/mp2t', 'video/x-matroska', 'audio/mp4',
  'audio/mp2t', 'audio/x-matroska', 'video/webm', 'audio/webm'];

/** 与 DASH_MIME_KEYS 平行的扩展名值表（FileExtensionHelper.GetExtensionFromMimeType 的
 * '.' 前缀语义，FileExtensionHelper.cs:38-46）。 */
const DASH_MIME_VALUES: string[] = ['.avi', '.flv', '.wav', '.au', '.aiff', '.3gp', '.mid', '.mp3',
  '.wmv', '.mpeg', '.qt', '.flv', '.mp4', '.ts', '.mkv', '.mp4', '.ts', '.mkv', '.mkv', '.mkv'];

/** GetExtensionFromMimeType（MimeTypes.Get 精确等值键查找，:9-14）：命中 → '.'+ext；未命中 → null。
 * 注意：非容器值扩展（.avi/.qt/.wmv 等）会被 copyTrack 的 containerValue 门拒绝 → 整计划 null
 * ——DASH 实践（fMP4/webm/ts）不触发，源全表在此仅为对照保真（设计书 §3.2）。 */
export function dashMimeExtension(mime: string): string | null {
  for (let i = 0; i < DASH_MIME_KEYS.length; i++) {
    if (DASH_MIME_KEYS[i] === mime) { return DASH_MIME_VALUES[i]; }
  }
  return null;
}

export class AdaptivePartState {
  chunkId: string = '';
  downloaded: number = 0;
  complete: boolean = false;
  fileName: string = '';
}

export class AdaptiveDownloadState {
  schema: number = 1;
  downloadId: string = '';
  generation: number = 0;
  plan: AdaptivePlan = new AdaptivePlan();
  parts: AdaptivePartState[] = [];
}

export class AdaptiveChunkRange {
  start: number = 0;
  end: number = 0;
}

export class AdaptiveProgress {
  completed: number = 0;
  total: number = 0;
  percent: number = 0;
  downloadedBytes: number = 0;
}

function invalidPlan(): Error { return new Error('Invalid adaptive plan'); }

function objectFields(value: Object | null, fields: string[]): Record<string, Object> {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) { throw invalidPlan(); }
  const keys: string[] = Object.keys(value);
  if (keys.length !== fields.length) { throw invalidPlan(); }
  for (let i = 0; i < keys.length; i++) { if (fields.indexOf(keys[i]) < 0) { throw invalidPlan(); } }
  return value as Record<string, Object>;
}

function textField(record: Record<string, Object>, key: string): string {
  const value: Object | undefined = record[key];
  if (typeof value !== 'string') { throw invalidPlan(); }
  return value as string;
}

function numberField(record: Record<string, Object>, key: string): number {
  const value: Object | undefined = record[key];
  if (typeof value !== 'number') { throw invalidPlan(); }
  return value as number;
}

function booleanField(record: Record<string, Object>, key: string): boolean {
  const value: Object | undefined = record[key];
  if (typeof value !== 'boolean') { throw invalidPlan(); }
  return value as boolean;
}

function arrayField(record: Record<string, Object>, key: string): Object[] {
  const value: Object | undefined = record[key];
  if (!Array.isArray(value)) { throw invalidPlan(); }
  return value as Object[];
}

function safeCount(value: number): boolean { return Number.isSafeInteger(value) && value >= 0; }
function safeDuration(value: number): boolean { return Number.isFinite(value) && value >= 0 && value <= Number.MAX_SAFE_INTEGER; }
function containerValue(value: string): boolean { return value === '.ts' || value === '.mp4' || value === '.mkv'; }

function validPort(value: string): boolean {
  return new RegExp('^[0-9]{1,5}$').test(value) && Number(value) <= 65535;
}

/** Raw HTTP(S) shape only. The transport must still use the platform URL implementation. */
export function isAdaptiveHttpUrl(value: string): boolean {
  if (typeof value !== 'string' || value.length === 0 || value.length > HLS_MAX_URL_CHARS ||
    value !== value.trim() || value.indexOf('\\') >= 0 || value.indexOf('{$') >= 0 ||
    new RegExp('[\\x00-\\x20\\x7f]').test(value) || !new RegExp('^https?://', 'i').test(value)) { return false; }
  const start: number = value.indexOf('://') + 3;
  let end: number = value.length;
  const delimiters: string[] = ['/', '?', '#'];
  for (let i = 0; i < delimiters.length; i++) {
    const at: number = value.indexOf(delimiters[i], start);
    if (at >= 0 && at < end) { end = at; }
  }
  const authority: string = value.substring(start, end);
  if (new RegExp('["<>^{}|]').test(authority)) { return false; }
  const userEnd: number = authority.lastIndexOf('@');
  if (userEnd >= 0 && authority.indexOf('@') !== userEnd) { return false; }
  const hostPort: string = authority.substring(userEnd + 1);
  if (hostPort.length === 0) { return false; }
  if (hostPort.startsWith('[')) {
    const close: number = hostPort.indexOf(']');
    if (close < 0 || !ipv6Shape(hostPort.substring(1, close))) { return false; }
    const suffix: string = hostPort.substring(close + 1);
    return suffix.length === 0 || (suffix.startsWith(':') && validPort(suffix.substring(1)));
  }
  const colon: number = hostPort.indexOf(':');
  const host: string = colon < 0 ? hostPort : hostPort.substring(0, colon);
  if (host.length === 0 || new RegExp('[%\\[\\]"<>^{}|]').test(host)) { return false; }
  return colon < 0 || validPort(hostPort.substring(colon + 1));
}

function ipv6Shape(host: string): boolean {
  if (host.length === 0 || host.indexOf(':') < 0 || host.indexOf(':::') >= 0 ||
    (host.startsWith(':') && !host.startsWith('::')) || (host.endsWith(':') && !host.endsWith('::')) ||
    !new RegExp('^[0-9A-Fa-f:.]+$').test(host)) { return false; }
  const compressed: number = host.indexOf('::');
  if (compressed >= 0 && host.indexOf('::', compressed + 2) >= 0) { return false; }
  const groups: string[] = host.split(':');
  let count: number = 0;
  for (let i = 0; i < groups.length; i++) {
    const group: string = groups[i];
    if (group.length === 0) { continue; }
    if (group.indexOf('.') >= 0) {
      if (i !== groups.length - 1) { return false; }
      const octets: string[] = group.split('.');
      if (octets.length !== 4) { return false; }
      for (let j = 0; j < octets.length; j++) {
        if (!new RegExp('^[0-9]{1,3}$').test(octets[j]) || Number(octets[j]) > 255) { return false; }
      }
      count += 2;
    } else {
      if (!new RegExp('^[0-9A-Fa-f]{1,4}$').test(group)) { return false; }
      count++;
    }
  }
  if (compressed >= 0) { return count < 8; }
  return count === 8 && !host.startsWith(':') && !host.endsWith(':');
}

function extensionOf(value: string): string {
  let end: number = value.length;
  const query: number = value.indexOf('?');
  const fragment: number = value.indexOf('#');
  if (query >= 0) { end = Math.min(end, query); }
  if (fragment >= 0) { end = Math.min(end, fragment); }
  const start: number = value.indexOf('/', value.indexOf('://') + 3);
  if (start < 0 || start >= end) { return ''; }
  let path: string = value.substring(start, end);
  // Source FileHelper reads Uri.LocalPath. Decode only this suggestion input, never the request URL/query.
  try { path = decodeURIComponent(path); } catch (e) {}
  const name: string = path.substring(path.lastIndexOf('/') + 1);
  const dot: number = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot);
}

/** Read generic JSON/model data field by field; never assert raw input as a valid chunk. */
export function copyAdaptiveChunk(value: Object | null): AdaptiveChunk | null {
  try {
    const fields: string[] = ['id', 'trackIndex', 'trackOrder', 'url', 'offset', 'length', 'duration',
      'isInit', 'mediaSequence', 'discontinuity', 'discontinuitySequence'];
    const record: Record<string, Object> = objectFields(value, fields);
    const chunk: AdaptiveChunk = new AdaptiveChunk();
    chunk.id = textField(record, 'id');
    chunk.trackIndex = numberField(record, 'trackIndex');
    chunk.trackOrder = numberField(record, 'trackOrder');
    chunk.url = textField(record, 'url');
    chunk.offset = numberField(record, 'offset');
    chunk.length = numberField(record, 'length');
    chunk.duration = numberField(record, 'duration');
    chunk.isInit = booleanField(record, 'isInit');
    chunk.mediaSequence = numberField(record, 'mediaSequence');
    chunk.discontinuity = booleanField(record, 'discontinuity');
    chunk.discontinuitySequence = numberField(record, 'discontinuitySequence');
    if (!new RegExp('^c(0|[1-9][0-9]{0,4})$').test(chunk.id) || Number(chunk.id.substring(1)) >= ADAPTIVE_MAX_CHUNKS ||
      (chunk.trackIndex !== 0 && chunk.trackIndex !== 1) || !safeCount(chunk.trackOrder) ||
      chunk.trackOrder >= HLS_MAX_SEGMENTS || !isAdaptiveHttpUrl(chunk.url) || !safeCount(chunk.offset) ||
      !safeDuration(chunk.duration) || (chunk.isInit && chunk.duration !== 0) ||
      !safeCount(chunk.mediaSequence) || !safeCount(chunk.discontinuitySequence)) { return null; }
    if (chunk.length === -1) {
      if (chunk.offset !== 0) { return null; }
    } else if (!safeCount(chunk.length) || chunk.length === 0 ||
      chunk.offset > Number.MAX_SAFE_INTEGER - (chunk.length - 1)) { return null; }
    return chunk;
  } catch (e) { return null; }
}

function copyTrack(value: Object | null): AdaptiveTrack {
  const record: Record<string, Object> = objectFields(value, ['index', 'role', 'playlistUrl', 'container', 'endList']);
  const track: AdaptiveTrack = new AdaptiveTrack();
  track.index = numberField(record, 'index');
  track.role = textField(record, 'role');
  track.playlistUrl = textField(record, 'playlistUrl');
  track.container = textField(record, 'container');
  track.endList = booleanField(record, 'endList');
  if (!isAdaptiveHttpUrl(track.playlistUrl) || !containerValue(track.container)) { throw invalidPlan(); }
  return track;
}

class PlanBudget {
  private used: number = 0;

  constructor(planWithoutChunks: AdaptivePlan) { this.used = JSON.stringify(planWithoutChunks).length; }

  add(chunk: AdaptiveChunk, index: number): void {
    // One validated chunk has a bounded URL. Never stringify an unbounded whole plan first.
    this.used += JSON.stringify(chunk).length + (index > 0 ? 1 : 0);
    if (this.used > ADAPTIVE_MAX_PLAN_CHARS) { throw invalidPlan(); }
  }
}

/** Strict canonical plan validation and deep copy, shared by builder and state codec. */
export function copyAdaptivePlan(value: Object | null): AdaptivePlan | null {
  try {
    const record: Record<string, Object> = objectFields(value, ['kind', 'primaryUrl', 'secondaryUrl', 'tracks',
      'chunks', 'duration', 'suggestedExtension']);
    const plan: AdaptivePlan = new AdaptivePlan();
    plan.kind = textField(record, 'kind');
    plan.primaryUrl = textField(record, 'primaryUrl');
    plan.secondaryUrl = textField(record, 'secondaryUrl');
    plan.duration = numberField(record, 'duration');
    plan.suggestedExtension = textField(record, 'suggestedExtension');
    const rawTracks: Object[] = arrayField(record, 'tracks');
    const rawChunks: Object[] = arrayField(record, 'chunks');
    if ((plan.kind !== 'Hls' && plan.kind !== 'Dash') || !isAdaptiveHttpUrl(plan.primaryUrl) ||
      !safeDuration(plan.duration) || !containerValue(plan.suggestedExtension) ||
      rawTracks.length < 1 || rawTracks.length > 2 ||
      rawChunks.length < 1 || rawChunks.length > ADAPTIVE_MAX_CHUNKS) { return null; }
    if ((rawTracks.length === 1 && plan.secondaryUrl !== '') ||
      (rawTracks.length === 2 && !isAdaptiveHttpUrl(plan.secondaryUrl))) { return null; }
    for (let i = 0; i < rawTracks.length; i++) {
      const track: AdaptiveTrack = copyTrack(rawTracks[i]);
      const role: string = rawTracks.length === 1 ? 'muxed' : (i === 0 ? 'video' : 'audio');
      if (track.index !== i || track.role !== role ||
        track.playlistUrl !== (i === 0 ? plan.primaryUrl : plan.secondaryUrl)) { return null; }
      plan.tracks.push(track);
    }
    const budget: PlanBudget = new PlanBudget(plan);
    const counts: number[] = [0, 0];
    const mediaCounts: number[] = [0, 0];
    const durations: number[] = [0, 0];
    const last: Array<AdaptiveChunk | null> = [null, null];
    for (let i = 0; i < rawChunks.length; i++) {
      const chunk: AdaptiveChunk | null = copyAdaptiveChunk(rawChunks[i]);
      if (chunk === null || chunk.id !== 'c' + String(i) || chunk.trackIndex >= plan.tracks.length ||
        chunk.trackOrder !== counts[chunk.trackIndex]) { return null; }
      const trackIndex: number = chunk.trackIndex;
      const previous: AdaptiveChunk | null = last[trackIndex];
      if (previous !== null) {
        const sequence: number = previous.mediaSequence + (previous.isInit ? 0 : 1);
        if (!safeCount(sequence) || chunk.mediaSequence !== sequence ||
          (chunk.discontinuity ? chunk.discontinuitySequence <= previous.discontinuitySequence :
          chunk.discontinuitySequence !== previous.discontinuitySequence)) { return null; }
      } else if (chunk.discontinuity && chunk.discontinuitySequence === 0) { return null; }
      counts[trackIndex]++;
      if (!chunk.isInit) { mediaCounts[trackIndex]++; }
      durations[trackIndex] += chunk.duration;
      if (!safeDuration(durations[trackIndex])) { return null; }
      budget.add(chunk, i);
      plan.chunks.push(chunk);
      last[trackIndex] = chunk;
    }
    let index: number = 0;
    for (let order = 0; order < Math.max(counts[0], counts[1]); order++) {
      for (let track = 0; track < plan.tracks.length; track++) {
        if (order < counts[track]) {
          if (plan.chunks[index].trackIndex !== track || plan.chunks[index].trackOrder !== order) { return null; }
          index++;
        }
      }
    }
    if (plan.kind === 'Dash') {
      // Dash（设计书 §3.2）：分块恒 duration=0（源 CreateChunk 无时长）——跳过 :303 和式恒等与
      // :298-301 末-URL-容器强校验（smooth 模板 URL 无扩展名）；suggestedExtension 恒等式核。
      return plan.suggestedExtension === plan.tracks[0].container ? plan : null;
    }
    for (let i = 0; i < plan.tracks.length; i++) {
      const finalChunk: AdaptiveChunk | null = last[i];
      if (mediaCounts[i] === 0 || finalChunk === null ||
        plan.tracks[i].container !== guessHlsContainer(extensionOf(finalChunk.url))) { return null; }
    }
    if (plan.duration !== Math.max(durations[0], durations[1])) { return null; }
    const expected: string = plan.tracks.length === 1 ? plan.tracks[0].container :
      guessHlsContainer(plan.tracks[0].container, plan.tracks[1].container);
    return plan.suggestedExtension === expected ? plan : null;
  } catch (e) { return null; }
}

function validPlaylist(playlist: HlsPlaylist): boolean {
  if (playlist === null || typeof playlist !== 'object' || !Array.isArray(playlist.segments) ||
    playlist.segments.length < 1 || playlist.segments.length > HLS_MAX_SEGMENTS ||
    playlist.isEncrypted !== false || playlist.isKeyIFrameOnly !== false ||
    typeof playlist.hasByteRange !== 'boolean' || typeof playlist.endList !== 'boolean' ||
    !safeCount(playlist.mediaSequence) || !safeCount(playlist.discontinuitySequence) ||
    !safeDuration(playlist.totalDuration)) { return false; }
  let mediaCount: number = 0;
  let duration: number = 0;
  let hasRange: boolean = false;
  let discontinuitySequence: number = playlist.discontinuitySequence;
  for (let i = 0; i < playlist.segments.length; i++) {
    const segment: HlsMediaSegment = playlist.segments[i];
    if (segment === null || typeof segment !== 'object' || !isAdaptiveHttpUrl(segment.url) ||
      segment.keyUrl !== null || segment.iv !== null || typeof segment.isInit !== 'boolean' ||
      typeof segment.discontinuity !== 'boolean' || !safeDuration(segment.duration) ||
      (segment.isInit && segment.duration !== 0) || !safeCount(segment.sequence) ||
      segment.sequence !== playlist.mediaSequence + mediaCount || !safeCount(segment.discontinuitySequence) ||
      (segment.discontinuity ? segment.discontinuitySequence <= discontinuitySequence :
      segment.discontinuitySequence !== discontinuitySequence)) { return false; }
    if (segment.byteRange !== null) {
      const offset: number = segment.byteRange.offset;
      const length: number = segment.byteRange.length;
      if (!safeCount(offset) || !safeCount(length) || length === 0 ||
        offset > Number.MAX_SAFE_INTEGER - (length - 1)) { return false; }
      hasRange = true;
    }
    duration += segment.duration;
    if (!safeDuration(duration)) { return false; }
    if (!segment.isInit) { mediaCount++; }
    discontinuitySequence = segment.discontinuitySequence;
  }
  return mediaCount > 0 && duration === playlist.totalDuration && hasRange === playlist.hasByteRange;
}

function trackOf(url: string, playlist: HlsPlaylist, index: number, dual: boolean): AdaptiveTrack {
  const track: AdaptiveTrack = new AdaptiveTrack();
  track.index = index;
  track.role = dual ? (index === 0 ? 'video' : 'audio') : 'muxed';
  track.playlistUrl = url;
  // Follow source MediaSegments.Last(), including an initialization MAP at the tail.
  track.container = guessHlsContainer(extensionOf(playlist.segments[playlist.segments.length - 1].url));
  track.endList = playlist.endList;
  return track;
}

function chunkOf(segment: HlsMediaSegment, id: number, trackIndex: number, trackOrder: number): AdaptiveChunk {
  const chunk: AdaptiveChunk = new AdaptiveChunk();
  chunk.id = 'c' + String(id);
  chunk.trackIndex = trackIndex;
  chunk.trackOrder = trackOrder;
  chunk.url = segment.url;
  chunk.offset = segment.byteRange?.offset ?? 0;
  chunk.length = segment.byteRange?.length ?? -1;
  chunk.duration = segment.duration;
  chunk.isInit = segment.isInit;
  chunk.mediaSequence = segment.sequence;
  chunk.discontinuity = segment.discontinuity;
  chunk.discontinuitySequence = segment.discontinuitySequence;
  return chunk;
}

/** Fixed source interleaving. A plan is metadata, not a completed or playable download. */
export function buildHlsPlan(primaryUrl: string, primary: HlsPlaylist,
  secondaryUrl: string = '', secondary: HlsPlaylist | null = null): AdaptivePlan | null {
  try {
    if (!isAdaptiveHttpUrl(primaryUrl) || !validPlaylist(primary) ||
      (secondary === null ? secondaryUrl !== '' : (!isAdaptiveHttpUrl(secondaryUrl) || !validPlaylist(secondary)))) {
      return null;
    }
    const plan: AdaptivePlan = new AdaptivePlan();
    plan.primaryUrl = primaryUrl;
    plan.secondaryUrl = secondaryUrl;
    plan.duration = Math.max(primary.totalDuration, secondary?.totalDuration ?? 0);
    plan.tracks.push(trackOf(primaryUrl, primary, 0, secondary !== null));
    if (secondary !== null) { plan.tracks.push(trackOf(secondaryUrl, secondary, 1, true)); }
    plan.suggestedExtension = plan.tracks.length === 1 ? plan.tracks[0].container :
      guessHlsContainer(plan.tracks[0].container, plan.tracks[1].container);
    const budget: PlanBudget = new PlanBudget(plan);
    const length: number = Math.max(primary.segments.length, secondary?.segments.length ?? 0);
    for (let i = 0; i < length; i++) {
      if (i < primary.segments.length) {
        const chunk: AdaptiveChunk = chunkOf(primary.segments[i], plan.chunks.length, 0, i);
        budget.add(chunk, plan.chunks.length);
        plan.chunks.push(chunk);
      }
      if (secondary !== null && i < secondary.segments.length) {
        const chunk: AdaptiveChunk = chunkOf(secondary.segments[i], plan.chunks.length, 1, i);
        budget.add(chunk, plan.chunks.length);
        plan.chunks.push(chunk);
      }
    }
    return copyAdaptivePlan(plan);
  } catch (e) { return null; }
}

/** 源 CreateChunk（MultiSourceDASHDownloader.cs:133-145）的 chunk 形态：恒 offset=0/Size=-1，
 * StreamIndex=trackIndex；init 段就是 segments[0] 无特判（CreateChunks2 逐段入列）。 */
function dashChunkOf(url: string, id: number, trackIndex: number, trackOrder: number): AdaptiveChunk {
  const chunk: AdaptiveChunk = new AdaptiveChunk();
  chunk.id = 'c' + String(id);
  chunk.trackIndex = trackIndex;
  chunk.trackOrder = trackOrder;
  chunk.url = url;
  chunk.offset = 0;
  chunk.length = -1;
  chunk.duration = 0;
  chunk.isInit = false;
  chunk.mediaSequence = trackOrder; // 单调连续（天然满足 :274-280 既有序列校验器）
  chunk.discontinuity = false;
  chunk.discontinuitySequence = 0;
  return chunk;
}

/** 容器链（:61-64）：Format ?? GetExtensionFromMimeType(mime) ?? GuessContainerFormatFromPlaylist。
 * track.container = dashMimeExtension(mime) ?? guessHlsContainer(末段扩展)（设计书 §3.2）；
 * GuessContainerFormatFromPlaylist 源取 Path.GetExtension（:264-268），此处按 extensionOf 取
 * URL 扩展后经 guessHlsContainer 归一（.ts/.mp4/.mkv，containerValue 门要求）。 */
function dashContainerOf(mime: string, lastSegmentUrl: string): string {
  const fromMime: string | null = dashMimeExtension(mime);
  if (fromMime !== null) { return fromMime; }
  return guessHlsContainer(extensionOf(lastSegmentUrl));
}

/**
 * DASH 计划（MultiSourceDASHDownloader.cs → 既有管线复用，设计书 §3.2/§4.10）。
 * 仅接受双轨（单轨 DASH 走 SingleSource 入口不进计划，源 :261-267→AddSingleItem）；
 * 交错序镜像 CreateChunks2 :270-298：min(v,a) 对（video=track0/audio=track1）+ video 尾段 + audio 尾段；
 * duration=max(videoDuration, audioDuration)（源 :245 Math.Max）；plan.primaryUrl/secondaryUrl
 * 均为 manifestUrl（源 MultiSourceDASHDownloadState.Url 单清单）；预算 ADAPTIVE_MAX_CHUNKS
 * =20000 = 2×DASH_MAX_SEGMENTS 恰合。返回 copyAdaptivePlan 全量校验产物（失败 null）。
 */
export function buildDashPlan(manifestUrl: string, videoSegments: string[], videoMime: string,
  audioSegments: string[], audioMime: string, videoDuration: number,
  audioDuration: number): AdaptivePlan | null {
  try {
    if (!isAdaptiveHttpUrl(manifestUrl) || videoSegments.length < 1 || audioSegments.length < 1 ||
      videoSegments.length > DASH_MAX_SEGMENTS || audioSegments.length > DASH_MAX_SEGMENTS ||
      !safeDuration(videoDuration) || !safeDuration(audioDuration)) { return null; }
    for (let i = 0; i < videoSegments.length; i++) {
      if (!isAdaptiveHttpUrl(videoSegments[i])) { return null; }
    }
    for (let i = 0; i < audioSegments.length; i++) {
      if (!isAdaptiveHttpUrl(audioSegments[i])) { return null; }
    }
    const plan: AdaptivePlan = new AdaptivePlan();
    plan.kind = 'Dash';
    plan.primaryUrl = manifestUrl;
    plan.secondaryUrl = manifestUrl;
    plan.duration = Math.max(videoDuration, audioDuration);
    const videoTrack: AdaptiveTrack = new AdaptiveTrack();
    videoTrack.index = 0;
    videoTrack.role = 'video';
    videoTrack.playlistUrl = manifestUrl;
    videoTrack.container = dashContainerOf(videoMime, videoSegments[videoSegments.length - 1]);
    videoTrack.endList = true; // static MPD 一次性全量清单（dynamic 已在解析层拒绝）
    const audioTrack: AdaptiveTrack = new AdaptiveTrack();
    audioTrack.index = 1;
    audioTrack.role = 'audio';
    audioTrack.playlistUrl = manifestUrl;
    audioTrack.container = dashContainerOf(audioMime, audioSegments[audioSegments.length - 1]);
    audioTrack.endList = true;
    plan.tracks.push(videoTrack);
    plan.tracks.push(audioTrack);
    // :91-92 ext = GetExtensionFromMimeType(VideoMimeType) ?? GuessContainerFormatFromSegmentExtension
    plan.suggestedExtension = dashMimeExtension(videoMime) ?? guessHlsContainer(videoTrack.container);
    const budget: PlanBudget = new PlanBudget(plan);
    const minLen: number = Math.min(videoSegments.length, audioSegments.length);
    for (let i = 0; i < minLen; i++) {
      const video: AdaptiveChunk = dashChunkOf(videoSegments[i], plan.chunks.length, 0, i);
      budget.add(video, plan.chunks.length);
      plan.chunks.push(video);
      const audio: AdaptiveChunk = dashChunkOf(audioSegments[i], plan.chunks.length, 1, i);
      budget.add(audio, plan.chunks.length);
      plan.chunks.push(audio);
    }
    for (let i = minLen; i < videoSegments.length; i++) { // :285-290 video 尾段追列
      const video: AdaptiveChunk = dashChunkOf(videoSegments[i], plan.chunks.length, 0, i);
      budget.add(video, plan.chunks.length);
      plan.chunks.push(video);
    }
    for (let i = minLen; i < audioSegments.length; i++) { // :291-296 audio 尾段追列
      const audio: AdaptiveChunk = dashChunkOf(audioSegments[i], plan.chunks.length, 1, i);
      budget.add(audio, plan.chunks.length);
      plan.chunks.push(audio);
    }
    return copyAdaptivePlan(plan);
  } catch (e) { return null; }
}

function checkedParts(parts: AdaptivePartState[]): void {
  if (!Array.isArray(parts) || parts.length > ADAPTIVE_MAX_CHUNKS) { throw new Error('Invalid adaptive progress'); }
  for (let i = 0; i < parts.length; i++) {
    if (parts[i] === null || typeof parts[i] !== 'object' || typeof parts[i].complete !== 'boolean') {
      throw new Error('Invalid adaptive progress');
    }
  }
}

/** Source unfinished-count partitioning, including finished items inside closed ranges. */
export function partitionAdaptiveChunks(parts: AdaptivePartState[], maxSegments: number): AdaptiveChunkRange[] {
  checkedParts(parts);
  const ranges: AdaptiveChunkRange[] = [];
  let unfinished: number = 0;
  for (let i = 0; i < parts.length; i++) { if (!parts[i].complete) { unfinished++; } }
  if (unfinished === 0) { return ranges; }
  const cap: number = Number.isFinite(maxSegments) && Number.isInteger(maxSegments) && maxSegments >= 1 ?
    Math.min(maxSegments, ADAPTIVE_MAX_PARALLEL) : 1;
  const perRange: number = Math.ceil(unfinished / Math.min(unfinished, cap));
  let start: number = 0;
  let count: number = 0;
  for (let i = 0; i < parts.length; i++) {
    if (!parts[i].complete) { count++; }
    if (count === perRange) {
      const range: AdaptiveChunkRange = new AdaptiveChunkRange();
      range.start = start; range.end = i;
      ranges.push(range);
      start = i + 1; count = 0;
    }
  }
  if (count > 0) {
    const range: AdaptiveChunkRange = new AdaptiveChunkRange();
    range.start = start; range.end = parts.length - 1;
    ranges.push(range);
  }
  return ranges;
}

/** 100 percent means all chunks are verified; publication is a separate operation. */
export function adaptiveProgress(parts: AdaptivePartState[]): AdaptiveProgress {
  checkedParts(parts);
  const progress: AdaptiveProgress = new AdaptiveProgress();
  progress.total = parts.length;
  for (let i = 0; i < parts.length; i++) {
    if (!safeCount(parts[i].downloaded) || parts[i].downloaded > Number.MAX_SAFE_INTEGER - progress.downloadedBytes) {
      throw new Error('Invalid adaptive progress');
    }
    progress.downloadedBytes += parts[i].downloaded;
    if (parts[i].complete) { progress.completed++; }
  }
  progress.percent = progress.total === 0 ? 0 : Math.floor(progress.completed * 100 / progress.total);
  return progress;
}
