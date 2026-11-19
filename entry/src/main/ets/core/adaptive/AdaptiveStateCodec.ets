import { AdaptiveChunk, AdaptivePlan, AdaptivePartState, AdaptiveDownloadState, ADAPTIVE_MAX_CHUNKS,
  ADAPTIVE_MAX_STATE_CHARS, copyAdaptiveChunk, copyAdaptivePlan } from './AdaptivePlan';

function invalidState(): Error { return new Error('Invalid adaptive state'); }

function objectFields(value: Object | null, fields: string[]): Record<string, Object> {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) { throw invalidState(); }
  const keys: string[] = Object.keys(value);
  if (keys.length !== fields.length) { throw invalidState(); }
  for (let i = 0; i < keys.length; i++) { if (fields.indexOf(keys[i]) < 0) { throw invalidState(); } }
  return value as Record<string, Object>;
}

function textField(record: Record<string, Object>, key: string): string {
  const value: Object | undefined = record[key];
  if (typeof value !== 'string') { throw invalidState(); }
  return value as string;
}

function numberField(record: Record<string, Object>, key: string): number {
  const value: Object | undefined = record[key];
  if (typeof value !== 'number') { throw invalidState(); }
  return value as number;
}

function booleanField(record: Record<string, Object>, key: string): boolean {
  const value: Object | undefined = record[key];
  if (typeof value !== 'boolean') { throw invalidState(); }
  return value as boolean;
}

function arrayField(record: Record<string, Object>, key: string): Object[] {
  const value: Object | undefined = record[key];
  if (!Array.isArray(value)) { throw invalidState(); }
  return value as Object[];
}

function validDownloadId(value: string): boolean {
  return typeof value === 'string' &&
    new RegExp('^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$').test(value);
}

function safeCount(value: number): boolean { return Number.isSafeInteger(value) && value >= 0; }

function freshPart(chunkId: string): AdaptivePartState {
  const part: AdaptivePartState = new AdaptivePartState();
  part.chunkId = chunkId;
  return part;
}

/** Local truth table; filename uniqueness is checked by the whole-state validator. */
function copyPart(value: Object | null, chunk: AdaptiveChunk): AdaptivePartState {
  const record: Record<string, Object> = objectFields(value, ['chunkId', 'downloaded', 'complete', 'fileName']);
  const part: AdaptivePartState = new AdaptivePartState();
  part.chunkId = textField(record, 'chunkId');
  part.downloaded = numberField(record, 'downloaded');
  part.complete = booleanField(record, 'complete');
  part.fileName = textField(record, 'fileName');
  if (part.chunkId !== chunk.id || !safeCount(part.downloaded)) { throw invalidState(); }
  if (!part.complete && part.downloaded === 0) {
    if (part.fileName !== '') { throw invalidState(); }
    return part;
  }
  if (!new RegExp('^[A-Za-z0-9_-]{1,120}\\.part$').test(part.fileName)) { throw invalidState(); }
  if (chunk.length !== -1) {
    if (part.complete ? part.downloaded !== chunk.length : part.downloaded >= chunk.length) { throw invalidState(); }
  }
  return part;
}

interface StateEnvelope {
  schema: number;
  downloadId: string;
  generation: number;
  plan: AdaptivePlan | null;
  parts: AdaptivePartState[];
}

function copyState(value: Object | null, expectedId: string | null): AdaptiveDownloadState {
  const record: Record<string, Object> = objectFields(value, ['schema', 'downloadId', 'generation', 'plan', 'parts']);
  const state: AdaptiveDownloadState = new AdaptiveDownloadState();
  state.schema = numberField(record, 'schema');
  state.downloadId = textField(record, 'downloadId');
  state.generation = numberField(record, 'generation');
  if (state.schema !== 1 || !validDownloadId(state.downloadId) || !safeCount(state.generation) ||
    (expectedId !== null && state.downloadId !== expectedId)) { throw invalidState(); }
  const plan: AdaptivePlan | null = copyAdaptivePlan(record['plan'] ?? null);
  const rawParts: Object[] = arrayField(record, 'parts');
  if (plan === null || rawParts.length !== plan.chunks.length || rawParts.length > ADAPTIVE_MAX_CHUNKS) {
    throw invalidState();
  }
  state.plan = plan;
  const envelope: StateEnvelope = {
    schema: state.schema, downloadId: state.downloadId, generation: state.generation, plan: null, parts: []
  };
  // copyAdaptivePlan already bounded its complete JSON to 8 Mi characters before this allocation.
  let characters: number = JSON.stringify(envelope).length - 4 + JSON.stringify(plan).length;
  let downloaded: number = 0;
  const fileNames: Set<string> = new Set<string>();
  for (let i = 0; i < rawParts.length; i++) {
    const part: AdaptivePartState = copyPart(rawParts[i], plan.chunks[i]);
    if (part.fileName !== '') {
      if (fileNames.has(part.fileName)) { throw invalidState(); }
      fileNames.add(part.fileName);
    }
    if (part.downloaded > Number.MAX_SAFE_INTEGER - downloaded) { throw invalidState(); }
    downloaded += part.downloaded;
    // Each validated part is at most 206 characters. Do not stringify the complete state first.
    characters += JSON.stringify(part).length + (i > 0 ? 1 : 0);
    if (characters > ADAPTIVE_MAX_STATE_CHARS) { throw invalidState(); }
    state.parts.push(part);
  }
  return state;
}

/** Fresh parts own no file. The returned plan and parts do not alias caller data. */
export function newAdaptiveState(downloadId: string, plan: AdaptivePlan): AdaptiveDownloadState | null {
  try {
    if (!validDownloadId(downloadId)) { return null; }
    const copied: AdaptivePlan | null = copyAdaptivePlan(plan);
    if (copied === null) { return null; }
    const state: AdaptiveDownloadState = new AdaptiveDownloadState();
    state.downloadId = downloadId;
    state.plan = copied;
    for (let i = 0; i < copied.chunks.length; i++) { state.parts.push(freshPart(copied.chunks[i].id)); }
    return copyState(state, downloadId);
  } catch (e) { return null; }
}

/** Only a fully validated, bounded canonical state may be serialized; errors contain no URL or filename. */
export function encodeAdaptiveState(state: AdaptiveDownloadState): string {
  try {
    const canonical: AdaptiveDownloadState = copyState(state, null);
    const text: string = JSON.stringify(canonical);
    if (text.length > ADAPTIVE_MAX_STATE_CHARS) { throw invalidState(); }
    return text;
  } catch (e) { throw invalidState(); }
}

/** Bound shape depth/container allocation before JSON.parse; valid schema 1 needs depth at most 4. */
function boundedJsonShape(text: string): boolean {
  let depth: number = 0;
  let containers: number = 0;
  let quoted: boolean = false;
  let escaped: boolean = false;
  for (let i = 0; i < text.length; i++) {
    const character: string = text.charAt(i);
    if (quoted) {
      if (escaped) { escaped = false; }
      else if (character === '\\') { escaped = true; }
      else if (character === '"') { quoted = false; }
      continue;
    }
    if (character === '"') { quoted = true; }
    else if (character === '[' || character === '{') {
      depth++; containers++;
      if (depth > 8 || containers > ADAPTIVE_MAX_CHUNKS * 2 + 8) { return false; }
    } else if (character === ']' || character === '}') {
      if (--depth < 0) { return false; }
    }
  }
  return !quoted && depth === 0;
}

export function decodeAdaptiveState(text: string, expectedDownloadId: string): AdaptiveDownloadState | null {
  try {
    if (typeof text !== 'string' || text.length === 0 || text.length > ADAPTIVE_MAX_STATE_CHARS ||
      !validDownloadId(expectedDownloadId) || !boundedJsonShape(text)) { return null; }
    const parsed: Object | null = JSON.parse(text);
    return copyState(parsed, expectedDownloadId);
  } catch (e) { return null; }
}

/** Keep only a validated immutable prefix. Stat never upgrades a part to complete. No IO or mutation. */
export function reconcileAdaptivePart(chunk: AdaptiveChunk, saved: AdaptivePartState,
  actualFileSize: number): AdaptivePartState {
  let id: string = '';
  if (chunk !== null && typeof chunk === 'object' && typeof chunk.id === 'string' &&
    new RegExp('^c(0|[1-9][0-9]{0,4})$').test(chunk.id) && Number(chunk.id.substring(1)) < ADAPTIVE_MAX_CHUNKS) {
    id = chunk.id;
  }
  const fresh: AdaptivePartState = freshPart(id);
  try {
    const checked: AdaptiveChunk | null = copyAdaptiveChunk(chunk);
    if (checked === null || !safeCount(actualFileSize)) { return fresh; }
    const part: AdaptivePartState = copyPart(saved, checked);
    if (actualFileSize < part.downloaded) { return fresh; }
    return part;
  } catch (e) { return fresh; }
}
