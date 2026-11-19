import { HlsAttributes, HlsByteRange, HlsMediaSegment, HlsPlaylist, HlsPlaylistContainer,
  HlsUrlResolver, HLS_MAX_URL_CHARS } from './HlsModel';

export const HLS_MAX_MANIFEST_CHARS: number = 2097152;
export const HLS_MAX_LINES: number = 50000;
export const HLS_MAX_LINE_CHARS: number = 32768;
export const HLS_MAX_SEGMENTS: number = 10000;
export const HLS_MAX_VARIANTS: number = 2048;
export const HLS_MAX_RENDITIONS: number = 2048;
export const HLS_MAX_ATTRIBUTES: number = 256;
// Logical string occurrences, not heap bytes. Master retained input has its own equal budget.
export const HLS_MAX_OUTPUT_CHARS: number = 8388608;

const STREAM_TAG: string = '#EXT-X-STREAM-INF:';
const MEDIA_TAG: string = '#EXT-X-MEDIA:';
const RANGE_TAG: string = '#EXT-X-BYTERANGE:';
const DURATION_TAG: string = '#EXTINF:';
const SEQUENCE_TAG: string = '#EXT-X-MEDIA-SEQUENCE:';
const KEY_TAG: string = '#EXT-X-KEY:';
const MAP_TAG: string = '#EXT-X-MAP:';
const DISCONTINUITY_SEQUENCE_TAG: string = '#EXT-X-DISCONTINUITY-SEQUENCE:';

/** Dictionary semantics match HlsHelper: commas in double quotes, first '=', last duplicate wins.
 * Whitespace around keys is tolerated. Malformed quoting or pairs reject the attribute list. */
export function parseHlsAttributes(text: string): HlsAttributes | null {
  if (text.length > HLS_MAX_LINE_CHARS) { return null; }
  const attributes: HlsAttributes = {};
  let insideQuote: boolean = false;
  let start: number = 0;
  let count: number = 0;
  for (let i = 0; i <= text.length; i++) {
    if (i < text.length && text.charAt(i) === '"') { insideQuote = !insideQuote; }
    if (i !== text.length && (text.charAt(i) !== ',' || insideQuote)) { continue; }
    if (insideQuote) { return null; }
    const pair: string = text.substring(start, i).trim();
    start = i + 1;
    if (pair.length === 0) {
      if (text.trim().length === 0) { return attributes; }
      return null;
    }
    if (++count > HLS_MAX_ATTRIBUTES) { return null; }
    const equal: number = pair.indexOf('=');
    if (equal <= 0) { return null; }
    const name: string = pair.substring(0, equal).trim();
    // HLS attribute names are uppercase tokens; this also excludes prototype names.
    if (!new RegExp('^[A-Z0-9-]+$').test(name)) { return null; }
    let value: string = pair.substring(equal + 1).trim();
    if (value.startsWith('"') || value.startsWith("'")) {
      const quote: string = value.charAt(0);
      if (value.length < 2 || !value.endsWith(quote)) { return null; }
      value = value.substring(1, value.length - 1).trim();
    }
    if (value.indexOf('"') >= 0 || value.indexOf('{$') >= 0 ||
      new RegExp('[\\x00-\\x1f\\x7f]').test(value)) { return null; }
    attributes[name] = value;
  }
  return attributes;
}

function manifestLines(text: string): string[] | null {
  if (text.length === 0 || text.length > HLS_MAX_MANIFEST_CHARS) { return null; }
  const lines: string[] = [];
  let start: number = 0;
  let lineCount: number = 0;
  while (start <= text.length) {
    let end: number = text.indexOf('\n', start);
    if (end < 0) { end = text.length; }
    if (++lineCount > HLS_MAX_LINES || end - start > HLS_MAX_LINE_CHARS) { return null; }
    const line: string = text.substring(start, end).trim();
    // No delta merge or variable substitution exists in this finite-snapshot parser.
    if (new RegExp('^#EXT-X-(?:SKIP|DEFINE)(?:[:\\s]|$)').test(line) ||
      ((line.charAt(0) !== '#' || line.startsWith('#EXT')) && line.indexOf('{$') >= 0)) { return null; }
    if (line.length > 0) { lines.push(line); }
    if (end === text.length) { break; }
    start = end + 1;
  }
  return lines.length > 0 && lines[0] === '#EXTM3U' ? lines : null;
}

function unsignedInteger(text: string): number {
  if (!new RegExp('^[0-9]+$').test(text)) { throw new Error('Invalid HLS integer'); }
  const value: number = Number(text);
  if (!Number.isSafeInteger(value) || value < 0) { throw new Error('Unsupported HLS integer'); }
  return value;
}

function checkedAttributes(text: string): HlsAttributes {
  const attributes: HlsAttributes | null = parseHlsAttributes(text);
  if (attributes === null) { throw new Error('Invalid HLS attributes'); }
  return attributes;
}

function required(attributes: HlsAttributes, name: string): string {
  const value: string | undefined = attributes[name];
  if (value === undefined || value.length === 0) { throw new Error('Missing HLS attribute'); }
  return value;
}

function resolveReference(base: string, reference: string, resolve: HlsUrlResolver): string {
  if (reference.length === 0 || reference.length > HLS_MAX_URL_CHARS ||
    base.indexOf('{$') >= 0 || reference.indexOf('{$') >= 0 ||
    new RegExp('[\\x00-\\x1f\\x7f]').test(reference)) { throw new Error('Invalid HLS reference'); }
  const result: string = resolve(base, reference);
  if (result.length === 0 || result.length > HLS_MAX_URL_CHARS ||
    result.indexOf('{$') >= 0 ||
    new RegExp('[\\x00-\\x1f\\x7f]').test(result)) { throw new Error('Invalid HLS resolution'); }
  return result;
}

class HlsTextBudget {
  private used: number = 0;

  add(characters: number): void {
    if (characters > HLS_MAX_OUTPUT_CHARS - this.used) { throw new Error('HLS character budget exceeded'); }
    this.used += characters;
  }
}

function attributeCharacters(attributes: HlsAttributes): number {
  let characters: number = 0;
  const keys: string[] = Object.keys(attributes);
  for (let i = 0; i < keys.length; i++) { characters += keys[i].length + attributes[keys[i]].length; }
  return characters;
}

function appendContainer(containers: HlsPlaylistContainer[], container: HlsPlaylistContainer,
  budget: HlsTextBudget): void {
  if (containers.length >= HLS_MAX_VARIANTS) { throw new Error('HLS variant limit'); }
  budget.add((container.videoPlaylist?.length ?? 0) + (container.audioPlaylist?.length ?? 0) +
    attributeCharacters(container.attributes));
  containers.push(container);
}

function mergeAttributes(stream: HlsAttributes, rendition: HlsAttributes): HlsAttributes {
  const result: HlsAttributes = {};
  const streamKeys: string[] = Object.keys(stream);
  const renditionKeys: string[] = Object.keys(rendition);
  for (let i = 0; i < streamKeys.length; i++) { result[streamKeys[i]] = stream[streamKeys[i]]; }
  for (let i = 0; i < renditionKeys.length; i++) { result[renditionKeys[i]] = rendition[renditionKeys[i]]; }
  return result;
}

class MasterStream {
  uri: string = '';
  attributes: HlsAttributes = {};
}

/** Master variants preserve source AUDIO-first grouping and rendition attribute overrides. */
export function parseHlsMasterPlaylist(text: string, manifestUrl: string,
  resolve: HlsUrlResolver): HlsPlaylistContainer[] | null {
  try {
    const lines: string[] | null = manifestLines(text);
    if (lines === null) { return null; }
    resolveReference(manifestUrl, manifestUrl, resolve);
    const streams: MasterStream[] = [];
    const renditions: HlsAttributes[] = [];
    const retainedBudget: HlsTextBudget = new HlsTextBudget();
    const outputBudget: HlsTextBudget = new HlsTextBudget();
    let pending: HlsAttributes | null = null;
    for (let i = 1; i < lines.length; i++) {
      const line: string = lines[i];
      if (line.startsWith(STREAM_TAG)) {
        if (pending !== null || streams.length >= HLS_MAX_VARIANTS) { return null; }
        pending = checkedAttributes(line.substring(STREAM_TAG.length));
        if (unsignedInteger(required(pending, 'BANDWIDTH')) === 0) { return null; }
        retainedBudget.add(attributeCharacters(pending));
      } else if (line.startsWith(MEDIA_TAG)) {
        if (pending !== null || renditions.length >= HLS_MAX_RENDITIONS) { return null; }
        const attributes: HlsAttributes = checkedAttributes(line.substring(MEDIA_TAG.length));
        required(attributes, 'TYPE'); required(attributes, 'GROUP-ID'); required(attributes, 'NAME');
        retainedBudget.add(attributeCharacters(attributes));
        renditions.push(attributes);
      } else if (line.charAt(0) !== '#') {
        if (pending === null) { return null; }
        const stream: MasterStream = new MasterStream();
        stream.attributes = pending;
        stream.uri = resolveReference(manifestUrl, line, resolve);
        retainedBudget.add(stream.uri.length);
        streams.push(stream);
        pending = null;
      } else if (line === '#EXT-X-STREAM-INF' || line === '#EXT-X-MEDIA' || isMediaOnlyTag(line)) {
        return null;
      }
    }
    if (pending !== null || streams.length === 0) { return null; }
    const containers: HlsPlaylistContainer[] = [];
    for (let i = 0; i < streams.length; i++) {
      const stream: MasterStream = streams[i];
      const audioGroup: string | undefined = stream.attributes['AUDIO'];
      const videoGroup: string | undefined = stream.attributes['VIDEO'];
      const type: string = audioGroup !== undefined ? 'AUDIO' : 'VIDEO';
      const group: string | undefined = audioGroup !== undefined ? audioGroup : videoGroup;
      if (group === undefined) {
        const container: HlsPlaylistContainer = new HlsPlaylistContainer();
        container.videoPlaylist = stream.uri;
        container.attributes = mergeAttributes(stream.attributes, {});
        appendContainer(containers, container, outputBudget);
      } else {
        for (let j = 0; j < renditions.length; j++) {
          const rendition: HlsAttributes = renditions[j];
          if (rendition['TYPE'] !== type || rendition['GROUP-ID'] !== group) { continue; }
          const uri: string | undefined = rendition['URI'];
          const mediaUri: string | null = uri === undefined ? null : resolveReference(manifestUrl, uri, resolve);
          const container: HlsPlaylistContainer = new HlsPlaylistContainer();
          container.videoPlaylist = type === 'AUDIO' ? stream.uri : mediaUri;
          container.audioPlaylist = type === 'AUDIO' ? mediaUri : stream.uri;
          container.attributes = mergeAttributes(stream.attributes, rendition);
          appendContainer(containers, container, outputBudget);
        }
      }
    }
    return containers.length > 0 ? containers : null;
  } catch (e) {
    return null;
  }
}

function isMediaOnlyTag(line: string): boolean {
  const colon: number = line.indexOf(':');
  const name: string = colon < 0 ? line : line.substring(0, colon);
  return name === '#EXTINF' || name === '#EXT-X-BYTERANGE' || name === '#EXT-X-MEDIA-SEQUENCE' ||
    name === '#EXT-X-KEY' || name === '#EXT-X-MAP' || name === '#EXT-X-I-FRAMES-ONLY' ||
    name === '#EXT-X-ENDLIST' || name === '#EXT-X-DISCONTINUITY' ||
    name === '#EXT-X-DISCONTINUITY-SEQUENCE' || name === '#EXT-X-TARGETDURATION' ||
    name === '#EXT-X-PLAYLIST-TYPE';
}

function byteRange(text: string, previous: HlsByteRange | null, sameResource: boolean,
  mapRange: boolean): HlsByteRange {
  const parts: string[] = text.trim().split('@');
  if (parts.length > 2) { throw new Error('Invalid HLS byte range'); }
  const range: HlsByteRange = new HlsByteRange();
  range.length = unsignedInteger(parts[0]);
  if (range.length === 0) { throw new Error('Empty HLS byte range'); }
  if (parts.length === 2) {
    range.offset = unsignedInteger(parts[1]);
  } else if (mapRange) {
    // Preserve source MAP ParseByteRange default 0; never borrow media-range state.
    range.offset = 0;
  } else {
    if (previous === null || !sameResource) { throw new Error('Missing HLS range predecessor'); }
    range.offset = previous.offset + previous.length;
  }
  if (!Number.isSafeInteger(range.offset) || range.offset < 0 ||
    range.offset > Number.MAX_SAFE_INTEGER - (range.length - 1)) {
    throw new Error('Unsupported HLS range endpoint');
  }
  return range;
}

function durationValue(text: string): number {
  const comma: number = text.indexOf(',');
  const value: string = (comma < 0 ? text : text.substring(0, comma)).trim();
  if (!new RegExp('^[+]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)$').test(value)) {
    throw new Error('Invalid HLS duration');
  }
  const duration: number = Number(value);
  if (!Number.isFinite(duration) || duration > Number.MAX_SAFE_INTEGER) { throw new Error('Unsupported HLS duration'); }
  return duration;
}

function explicitIv(value: string): string {
  if (!new RegExp('^0[xX][0-9a-fA-F]{1,32}$').test(value)) { throw new Error('Invalid HLS IV'); }
  return '0x' + value.substring(2).toLowerCase().padStart(32, '0');
}

class MediaState {
  playlist: HlsPlaylist = new HlsPlaylist();
  outputBudget: HlsTextBudget = new HlsTextBudget();
  count: number = 0;
  duration: number = 0;
  durationPending: boolean = false;
  rangeText: string | null = null;
  previousRange: HlsByteRange | null = null;
  previousRangeUrl: string = '';
  keyUrl: string | null = null;
  iv: string | null = null;
  sequenceSet: boolean = false;
  discontinuitySet: boolean = false;
  discontinuities: number = 0;
  boundary: boolean = false;
}

function appendSegment(state: MediaState, uri: string, isInit: boolean,
  range: HlsByteRange | null): void {
  if (state.playlist.segments.length >= HLS_MAX_SEGMENTS) { throw new Error('HLS segment limit'); }
  const segment: HlsMediaSegment = new HlsMediaSegment();
  segment.url = uri;
  segment.byteRange = range;
  segment.duration = isInit ? 0 : state.duration;
  segment.sequence = state.playlist.mediaSequence + state.count;
  segment.isInit = isInit;
  segment.keyUrl = state.keyUrl;
  segment.iv = state.keyUrl === null ? null : state.iv ??
    ('0x' + segment.sequence.toString(16).padStart(32, '0'));
  segment.discontinuity = state.boundary;
  segment.discontinuitySequence = state.playlist.discontinuitySequence + state.discontinuities;
  if (!Number.isSafeInteger(segment.sequence) || !Number.isSafeInteger(segment.discontinuitySequence)) {
    throw new Error('Unsupported HLS sequence');
  }
  state.outputBudget.add(segment.url.length + (segment.keyUrl?.length ?? 0) + (segment.iv?.length ?? 0));
  state.playlist.segments.push(segment);
  state.boundary = false;
  if (range !== null) { state.playlist.hasByteRange = true; }
  if (state.keyUrl !== null) { state.playlist.isEncrypted = true; }
  if (!isInit) {
    state.count++;
    state.playlist.totalDuration += state.duration;
    if (!Number.isFinite(state.playlist.totalDuration) || state.playlist.totalDuration > Number.MAX_SAFE_INTEGER) {
      throw new Error('Unsupported HLS total duration');
    }
    state.duration = 0;
    state.durationPending = false;
    state.rangeText = null;
    state.previousRange = range;
    state.previousRangeUrl = uri;
  }
}

function parseKey(state: MediaState, text: string, base: string, resolve: HlsUrlResolver): void {
  const attributes: HlsAttributes = checkedAttributes(text);
  const method: string = required(attributes, 'METHOD');
  if (method === 'NONE') { state.keyUrl = null; state.iv = null; return; }
  if (method !== 'AES-128' || (attributes['KEYFORMAT'] ?? 'identity') !== 'identity') {
    throw new Error('Unsupported HLS encryption');
  }
  state.keyUrl = resolveReference(base, required(attributes, 'URI'), resolve);
  const iv: string | undefined = attributes['IV'];
  state.iv = iv === undefined ? null : explicitIv(iv);
}

/** Finite media snapshot only. Unsupported/malformed transport input rejects the entire list. */
export function parseHlsMediaPlaylist(text: string, manifestUrl: string, resolve: HlsUrlResolver): HlsPlaylist | null {
  try {
    const lines: string[] | null = manifestLines(text);
    if (lines === null) { return null; }
    resolveReference(manifestUrl, manifestUrl, resolve);
    const state: MediaState = new MediaState();
    for (let i = 1; i < lines.length; i++) {
      const line: string = lines[i];
      if (line.charAt(0) !== '#') {
        const uri: string = resolveReference(manifestUrl, line, resolve);
        const range: HlsByteRange | null = state.rangeText === null ? null : byteRange(state.rangeText,
          state.previousRange, uri === state.previousRangeUrl, false);
        appendSegment(state, uri, false, range);
      } else if (line.startsWith(DURATION_TAG)) {
        if (state.durationPending) { return null; }
        state.duration = durationValue(line.substring(DURATION_TAG.length));
        state.durationPending = true;
      } else if (line.startsWith(RANGE_TAG)) {
        if (state.rangeText !== null) { return null; }
        state.rangeText = line.substring(RANGE_TAG.length).trim();
      } else if (line.startsWith(SEQUENCE_TAG)) {
        if (state.sequenceSet || state.count > 0) { return null; }
        state.sequenceSet = true;
        state.playlist.mediaSequence = unsignedInteger(line.substring(SEQUENCE_TAG.length).trim());
        for (let j = 0; j < state.playlist.segments.length; j++) {
          state.playlist.segments[j].sequence = state.playlist.mediaSequence;
        }
      } else if (line.startsWith(KEY_TAG)) {
        parseKey(state, line.substring(KEY_TAG.length), manifestUrl, resolve);
      } else if (line.startsWith(MAP_TAG)) {
        const attributes: HlsAttributes = checkedAttributes(line.substring(MAP_TAG.length));
        const uri: string = resolveReference(manifestUrl, required(attributes, 'URI'), resolve);
        const rangeText: string | undefined = attributes['BYTERANGE'];
        if (state.keyUrl !== null && state.iv === null) { return null; }
        const range: HlsByteRange | null = rangeText === undefined ? null : byteRange(rangeText, null, false, true);
        appendSegment(state, uri, true, range);
      } else if (line === '#EXT-X-I-FRAMES-ONLY' || line === '#EXT-X-I-FRAMES-ONLY:') {
        state.playlist.isKeyIFrameOnly = true;
      } else if (line === '#EXT-X-ENDLIST') {
        state.playlist.endList = true;
      } else if (line === '#EXT-X-DISCONTINUITY') {
        state.discontinuities++;
        state.boundary = true;
      } else if (line.startsWith(DISCONTINUITY_SEQUENCE_TAG)) {
        if (state.discontinuitySet || state.count > 0 || state.discontinuities > 0) { return null; }
        state.discontinuitySet = true;
        state.playlist.discontinuitySequence = unsignedInteger(line.substring(DISCONTINUITY_SEQUENCE_TAG.length).trim());
        for (let j = 0; j < state.playlist.segments.length; j++) {
          state.playlist.segments[j].discontinuitySequence = state.playlist.discontinuitySequence;
        }
      } else if (line.startsWith(STREAM_TAG) || line.startsWith(MEDIA_TAG) ||
        line === '#EXT-X-STREAM-INF' || line === '#EXT-X-MEDIA' || line === '#EXTINF' ||
        line === '#EXT-X-BYTERANGE' || line === '#EXT-X-MEDIA-SEQUENCE' || line === '#EXT-X-KEY' ||
        line === '#EXT-X-MAP' || line === '#EXT-X-DISCONTINUITY-SEQUENCE' ||
        line.startsWith('#EXT-X-I-FRAMES-ONLY:') || line.startsWith('#EXT-X-ENDLIST:') ||
        line.startsWith('#EXT-X-DISCONTINUITY:')) {
        return null;
      }
    }
    return state.count > 0 && !state.durationPending && state.rangeText === null ? state.playlist : null;
  } catch (e) {
    return null;
  }
}

export function hlsQuality(attributes: HlsAttributes | null): string | null {
  if (attributes === null) { return null; }
  let text: string = attributes['RESOLUTION'] ?? '';
  const bandwidth: string | undefined = attributes['BANDWIDTH'];
  if (bandwidth !== undefined) {
    try {
      const rate: number = unsignedInteger(bandwidth);
      if (text.length > 0) { text += ' '; }
      text += String(Math.floor(rate / 1024)) + ' Kbps';
    } catch (e) {}
  }
  const name: string | undefined = attributes['NAME'];
  const label: string | undefined = name !== undefined ? name : attributes['LANGUAGE'];
  if (label !== undefined) {
    if (text.length > 0) { text += ' '; }
    text += label;
  }
  return text.length > 0 ? text : null;
}

/** Inputs are file extensions, as in FileExtensionHelper; no network/path parsing. */
export function guessHlsContainer(extension: string, otherExtension: string | null = null): string {
  const first: string = containerOf(extension);
  return otherExtension === null || first === containerOf(otherExtension) ? first : '.mkv';
}

function containerOf(extension: string): string {
  const normalized: string = extension.toLowerCase();
  if (normalized === '.ts') { return '.ts'; }
  return normalized.startsWith('.m4') || normalized.startsWith('.mp4') || normalized.startsWith('.fmp4') ? '.mp4' : '.mkv';
}
