/*
 * Adaptive (HLS/DASH/dual-source) business descriptor persisted with a download record.
 * Pure model: no @kit imports, loadable by host tests.
 *
 * kind     | primaryUrl                   | secondaryUrl          | segment lists
 * 'hls'    | video (or muxed) media list  | audio media list / '' | unused
 * 'dash'   | MPD manifest URL             | ''                    | video/audio segment URLs
 * 'dual'   | video direct URL             | audio direct URL      | unused
 *
 * The descriptor is the creation-time source identity. Once the engine has persisted a plan
 * (AdaptiveStateStore), resume uses that plan and never re-reads remote manifests.
 */

export const ADAPTIVE_SOURCE_SCHEMA: number = 1;
const MAX_URL_CHARS: number = 32768;
const MAX_SEGMENTS: number = 10000;
const MAX_PAYLOAD_CHARS: number = 16777216;
const MAX_MIME_CHARS: number = 256;

export class AdaptiveSourceDescriptor {
  schema: number = ADAPTIVE_SOURCE_SCHEMA;
  kind: string = 'hls';
  primaryUrl: string = '';
  secondaryUrl: string = '';
  videoSegments: string[] = [];
  audioSegments: string[] = [];
  videoMime: string = '';
  audioMime: string = '';
  duration: number = 0;
}

/** DownloadRecord.downloadType value for each descriptor kind ('Http' stays the default). */
export function adaptiveDownloadType(kind: string): string {
  if (kind === 'hls') { return 'Hls'; }
  if (kind === 'dash') { return 'Dash'; }
  if (kind === 'dual') { return 'Dual'; }
  return '';
}

export function isAdaptiveDownloadType(downloadType: string | null): boolean {
  return downloadType === 'Hls' || downloadType === 'Dash' || downloadType === 'Dual';
}

function httpUrl(value: string): boolean {
  if (typeof value !== 'string' || value.length === 0 || value.length > MAX_URL_CHARS) { return false; }
  const lower: string = value.substring(0, 8).toLowerCase();
  return lower.startsWith('http://') || lower.startsWith('https://');
}

function urlList(values: string[]): boolean {
  if (!Array.isArray(values) || values.length > MAX_SEGMENTS) { return false; }
  for (let i = 0; i < values.length; i++) {
    if (!httpUrl(values[i])) { return false; }
  }
  return true;
}

function mime(value: string): boolean {
  return typeof value === 'string' && value.length <= MAX_MIME_CHARS;
}

export function validateAdaptiveSource(value: AdaptiveSourceDescriptor | null): boolean {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) { return false; }
  if (value.schema !== ADAPTIVE_SOURCE_SCHEMA || adaptiveDownloadType(value.kind) === '') { return false; }
  if (!httpUrl(value.primaryUrl) || typeof value.secondaryUrl !== 'string') { return false; }
  if (!urlList(value.videoSegments) || !urlList(value.audioSegments) || !mime(value.videoMime) ||
    !mime(value.audioMime) || typeof value.duration !== 'number' || !Number.isFinite(value.duration) ||
    value.duration < 0) { return false; }
  if (value.kind === 'hls') {
    return (value.secondaryUrl === '' || httpUrl(value.secondaryUrl)) &&
      value.videoSegments.length === 0 && value.audioSegments.length === 0;
  }
  if (value.kind === 'dash') {
    return value.secondaryUrl === '' && value.videoSegments.length > 0 && value.audioSegments.length > 0;
  }
  return httpUrl(value.secondaryUrl) && value.videoSegments.length === 0 && value.audioSegments.length === 0;
}

export function cloneAdaptiveSource(value: AdaptiveSourceDescriptor): AdaptiveSourceDescriptor {
  const copy: AdaptiveSourceDescriptor = new AdaptiveSourceDescriptor();
  copy.schema = value.schema;
  copy.kind = value.kind;
  copy.primaryUrl = value.primaryUrl;
  copy.secondaryUrl = value.secondaryUrl;
  copy.videoSegments = value.videoSegments.slice();
  copy.audioSegments = value.audioSegments.slice();
  copy.videoMime = value.videoMime;
  copy.audioMime = value.audioMime;
  copy.duration = value.duration;
  return copy;
}

export function serializeAdaptiveSource(value: AdaptiveSourceDescriptor): string {
  if (!validateAdaptiveSource(value)) { throw new Error('Invalid adaptive source'); }
  const text: string = JSON.stringify(cloneAdaptiveSource(value));
  if (text.length > MAX_PAYLOAD_CHARS) { throw new Error('Adaptive source too large'); }
  return text;
}

export function parseAdaptiveSource(text: string): AdaptiveSourceDescriptor | null {
  try {
    if (typeof text !== 'string' || text.length === 0 || text.length > MAX_PAYLOAD_CHARS) { return null; }
    const parsed: Object | null = JSON.parse(text) as Object | null;
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) { return null; }
    const raw: AdaptiveSourceDescriptor = parsed as AdaptiveSourceDescriptor;
    if (!validateAdaptiveSource(raw)) { return null; }
    return cloneAdaptiveSource(raw);
  } catch (e) {
    return null;
  }
}

/** Best-effort MIME from a googlevideo-style `mime=` query value; '' when absent. */
export function mimeFromUrlQuery(url: string): string {
  const match: RegExpExecArray | null = new RegExp('[?&]mime=([^&#]*)').exec(url);
  if (match === null) { return ''; }
  try {
    const value: string = decodeURIComponent(match[1].replace(new RegExp('\\+', 'g'), ' ')).toLowerCase();
    return value.length <= MAX_MIME_CHARS && new RegExp('^(video|audio)/[a-z0-9.+-]+$').test(value) ? value : '';
  } catch (e) {
    return '';
  }
}
