'use strict';
// Actual production ETS. This verifies pure planning/persistence rules, not IO or media playback.
const assert = require('node:assert/strict');
const path = require('node:path');
const { test } = require('node:test');
const { loadProduction } = require('./production-loader.cjs');
const source = path.resolve(__dirname, '../../entry/src/main/ets/core/adaptive');
const model = loadProduction(path.join(source, 'HlsModel.ets'), {});
const parser = loadProduction(path.join(source, 'HlsParser.ets'), { './HlsModel': model });
const adapter = loadProduction(path.join(source, 'HlsUrlResolver.ets'), {
  './HlsModel': model, '@kit.ArkTS': { url: { URL: { parseURL: (reference, base) => new URL(reference, base) } } }
});
// Modules share Error identity in the target runtime. Preserve that when separate VM contexts host them.
const plan = loadProduction(path.join(source, 'AdaptivePlan.ets'), { './DashModel': require('./production-loader.cjs').loadProduction(require('node:path').resolve(__dirname, '../../entry/src/main/ets/core/adaptive/DashModel.ets'), {}, { Error }),  './HlsModel': model, './HlsParser': parser }, { Error });
const codec = loadProduction(path.join(source, 'AdaptiveStateCodec.ets'), { './AdaptivePlan': plan }, { Error });
const PRIMARY = 'https://video.example/master.m3u8?sig=primary%2F';
const SECONDARY = 'https://audio.example/master.m3u8?sig=secondary%2B';
const ID = '01234567-89ab-cdef-0123-456789abcdef';
const OTHER_ID = '11234567-89ab-cdef-0123-456789abcdef';
const plain = value => JSON.parse(JSON.stringify(value));
const manifest = lines => '#EXTM3U\n' + lines.join('\n');
function playlist(lines, url = PRIMARY) {
  const value = parser.parseHlsMediaPlaylist(manifest(lines), url, adapter.resolveHlsUrl);
  assert.ok(value, 'valid production-parser fixture');
  return value;
}
function build(lines, other = null) {
  const value = plan.buildHlsPlan(PRIMARY, playlist(lines), other === null ? '' : SECONDARY,
    other === null ? null : playlist(other, SECONDARY));
  assert.ok(value, 'valid production-plan fixture');
  return value;
}
function state(lines = ['s.ts'], other = null) {
  const value = codec.newAdaptiveState(ID, build(lines, other));
  assert.ok(value, 'valid fresh state fixture');
  return value;
}
function badState(value, label = '') {
  assert.throws(() => codec.encodeAdaptiveState(value), error => error.message === 'Invalid adaptive state', label);
  assert.equal(codec.decodeAdaptiveState(JSON.stringify(value), ID), null, label);
}
function prefix(part, downloaded, complete = false, fileName = 'owned.part') {
  part.downloaded = downloaded; part.complete = complete; part.fileName = fileName;
}
function parts(flags) {
  return flags.map((complete, i) => {
    const item = new plan.AdaptivePartState(); item.chunkId = 'c' + i; item.complete = complete;
    item.fileName = complete ? 'p' + i + '.part' : ''; return item;
  });
}
function tunePlanSize(value, target, padding = 'x') {
  let remaining = target - JSON.stringify(value).length;
  const cost = JSON.stringify(padding).length - 2;
  assert.ok(remaining >= 0);
  for (const chunk of value.chunks) {
    const count = Math.min(Math.floor(remaining / cost), model.HLS_MAX_URL_CHARS - chunk.url.length);
    if (count > 0) { chunk.url = chunk.url.replace('/s.ts', '/' + padding.repeat(count) + 's.ts'); remaining -= count * cost; }
    if (remaining === 0) break;
  }
  if (remaining === 1) {
    const chunk = value.chunks.find(item => item.url.length < model.HLS_MAX_URL_CHARS);
    assert.ok(chunk); chunk.url = chunk.url.slice(0, -4) + 'xs.ts'; remaining = 0;
  }
  assert.equal(remaining, 0, 'fixture must fit per-URL bounds');
  assert.equal(JSON.stringify(value).length, target);
  return value;
}
function playlistFromPlan(value, track = 0) {
  const result = new model.HlsPlaylist();
  const rows = value.chunks.filter(item => item.trackIndex === track);
  result.mediaSequence = rows[0].mediaSequence;
  result.discontinuitySequence = rows[0].discontinuitySequence;
  for (const row of rows) {
    const segment = new model.HlsMediaSegment();
    segment.url = row.url; segment.duration = row.duration; segment.sequence = row.mediaSequence;
    segment.isInit = row.isInit; segment.discontinuity = row.discontinuity;
    segment.discontinuitySequence = row.discontinuitySequence;
    if (row.length !== -1) {
      segment.byteRange = new model.HlsByteRange(); segment.byteRange.offset = row.offset;
      segment.byteRange.length = row.length; result.hasByteRange = true;
    }
    result.totalDuration += row.duration; result.segments.push(segment);
  }
  return result;
}

test('single-track plan preserves duration, role, finite snapshot and query-free extension', () => {
  const value = build(['#EXTINF:1.25,', 's.TS?token=.mp4#trick', '#EXTINF:2,', 'other.TS#tail.mp4']);
  assert.equal(value.kind, 'Hls'); assert.equal(value.duration, 3.25);
  assert.equal(value.secondaryUrl, ''); assert.equal(value.suggestedExtension, '.ts');
  assert.deepEqual(plain(value.tracks), [{ index: 0, role: 'muxed', playlistUrl: PRIMARY, container: '.ts', endList: false }]);
  assert.deepEqual(plain(value.chunks.map(item => [item.id, item.trackIndex, item.trackOrder, item.length])),
    [['c0', 0, 0, -1], ['c1', 0, 1, -1]]);
  const encoded = build(['file%2EMP4?token=.ts%2F%2B']);
  assert.equal(encoded.suggestedExtension, '.mp4');
  assert.equal(encoded.chunks[0].url, 'https://video.example/file%2EMP4?token=.ts%2F%2B');
});

test('two tracks interleave by source list index and use maximum duration', () => {
  const value = build(['#EXTINF:4,', 'v1.M4S', '#EXTINF:5,', 'v2.MP4', '#EXT-X-ENDLIST'],
    ['#EXTINF:2,', 'a1.m4a', '#EXTINF:3,', 'a2.fmp4']);
  assert.equal(value.duration, 9); assert.equal(value.suggestedExtension, '.mp4');
  assert.deepEqual(plain(value.tracks.map(item => [item.index, item.role, item.endList])), [[0, 'video', true], [1, 'audio', false]]);
  assert.deepEqual(plain(value.chunks.map(item => [item.id, item.trackIndex, item.trackOrder])),
    [['c0', 0, 0], ['c1', 1, 0], ['c2', 0, 1], ['c3', 1, 1]]);
});

test('longer primary or secondary appends remaining entries without changing track order', () => {
  assert.deepEqual(plain(build(['v0.ts', 'v1.ts', 'v2.ts'], ['a0.m4a']).chunks.map(item => item.trackIndex)), [0, 1, 0, 0]);
  const value = build(['v0.ts'], ['a0.m4a', 'a1.m4a', 'a2.m4a']);
  assert.deepEqual(plain(value.chunks.map(item => [item.trackIndex, item.trackOrder])), [[0, 0], [1, 0], [1, 1], [1, 2]]);
  assert.equal(value.suggestedExtension, '.mkv');
});

test('MAP is an independent chunk and trailing MAP participates in source container inference', () => {
  const value = build(['#EXT-X-MEDIA-SEQUENCE:8', '#EXT-X-DISCONTINUITY-SEQUENCE:2', '#EXT-X-MAP:URI="init.mp4"',
    '#EXTINF:3,', 's.ts', '#EXT-X-DISCONTINUITY', '#EXT-X-MAP:URI="tail.MP4?x=.ts"']);
  assert.deepEqual(plain(value.chunks.map(item => [item.isInit, item.duration, item.mediaSequence])), [[true, 0, 8], [false, 3, 8], [true, 0, 9]]);
  assert.equal(value.chunks[2].discontinuity, true); assert.equal(value.chunks[2].discontinuitySequence, 3);
  assert.equal(value.duration, 3); assert.equal(value.suggestedExtension, '.mp4');
});

test('byte ranges are per chunk and do not turn whole resources into zero-length ranges', () => {
  const value = build(['#EXT-X-BYTERANGE:10@90', 'packed.mp4', 'whole.ts', '#EXT-X-BYTERANGE:5@0', 'packed.mp4']);
  assert.deepEqual(plain(value.chunks.map(item => [item.offset, item.length])), [[90, 10], [0, -1], [0, 5]]);
  assert.equal(plan.buildHlsPlan(PRIMARY, playlist(['#EXT-X-BYTERANGE:1@9007199254740991', 's.ts'])).chunks[0].offset,
    Number.MAX_SAFE_INTEGER);
});

test('builder and validated copy share no mutable parser, plan, track or chunk objects', () => {
  const input = playlist(['#EXT-X-BYTERANGE:5@20', 's.ts']);
  const value = plan.buildHlsPlan(PRIMARY, input);
  const copied = plan.copyAdaptivePlan(value);
  input.segments[0].byteRange.offset = 999; input.segments[0].url = 'https://changed/s.mp4';
  value.chunks[0].offset = 40; value.tracks[0].playlistUrl = 'https://changed/list';
  assert.equal(copied.chunks[0].offset, 20); assert.equal(copied.chunks[0].url, 'https://video.example/s.ts');
  assert.equal(copied.tracks[0].playlistUrl, PRIMARY);
});

test('encrypted metadata including earlier AES then NONE and I-frame-only content is rejected', () => {
  const aes = playlist(['#EXT-X-KEY:METHOD=AES-128,URI="key"', 's.ts', '#EXT-X-KEY:METHOD=NONE', 't.ts']);
  assert.equal(plan.buildHlsPlan(PRIMARY, aes), null);
  aes.isEncrypted = false;
  assert.equal(plan.buildHlsPlan(PRIMARY, aes), null, 'individual keys cannot hide behind false aggregate');
  const clear = playlist(['s.ts']); clear.segments[0].iv = '0x1';
  assert.equal(plan.buildHlsPlan(PRIMARY, clear), null);
  assert.equal(plan.buildHlsPlan(PRIMARY, playlist(['#EXT-X-I-FRAMES-ONLY', 's.ts'])), null);
});

test('secondary URL and playlist must pair and every track needs real media', () => {
  const good = playlist(['s.ts']);
  assert.equal(plan.buildHlsPlan(PRIMARY, good, SECONDARY, null), null);
  assert.equal(plan.buildHlsPlan(PRIMARY, good, '', good), null);
  assert.equal(plan.buildHlsPlan(PRIMARY, new model.HlsPlaylist()), null);
  const mapOnly = playlist(['#EXT-X-MAP:URI="init.mp4"', 's.ts']); mapOnly.segments.pop();
  assert.equal(plan.buildHlsPlan(PRIMARY, mapOnly), null);
});

test('builder rejects contradictory aggregate flags, durations and segment metadata', () => {
  const mutators = [value => { value.hasByteRange = true; }, value => { value.totalDuration = 99; },
    value => { value.segments[0].sequence = 2; }, value => { value.segments[0].duration = -1; },
    value => { value.segments[0].duration = Infinity; }, value => { value.endList = 'true'; },
    value => { value.segments[0].discontinuitySequence = 1; }, value => { value.segments[0].url = 'file:///s.ts'; }];
  for (const mutate of mutators) { const value = playlist(['s.ts']); mutate(value); assert.equal(plan.buildHlsPlan(PRIMARY, value), null); }
  const ranged = playlist(['#EXT-X-BYTERANGE:10@20', 's.ts']); ranged.hasByteRange = false;
  assert.equal(plan.buildHlsPlan(PRIMARY, ranged), null);
});

test('HTTP raw shape permits normal HTTP/HTTPS/IPv6 and rejects authority, scheme and control faults', () => {
  for (const url of ['http://localhost:8080/s.ts', 'https://user:pass@host/s.ts?sig=a%2Fb', 'https://[::1]:443/s.ts',
    'https://[::ffff:127.0.0.1]/s.ts', 'http://[::]/s.ts', 'http://[1::]/s.ts',
    'https://例子.test/s.ts', 'https://host/%7B$prefix%7D/s.ts']) {
    assert.equal(plan.isAdaptiveHttpUrl(url), true, url);
  }
  for (const url of ['', 'https://', 'https:///s.ts', 'file:///s.ts', 'data:text/plain,a', 'https:host/s.ts',
    'https://host:bad/s.ts', 'https://host:65536/s.ts', 'https://host:/s.ts', 'https://[:::]/s.ts',
    'http://[::1:]/part.ts', 'http://[:1::]/part.ts', 'http://[1::2:]/part.ts',
    'https://host/s\nts', 'https://host/s ts', 'https://host\\s.ts', 'https://host/{$prefix}/s.ts', ' https://host/s.ts']) {
    assert.equal(plan.isAdaptiveHttpUrl(url), false, url);
  }
  assert.equal(plan.isAdaptiveHttpUrl('https://host/' + 'x'.repeat(model.HLS_MAX_URL_CHARS)), false);
});

test('canonical plan rejects id, order, role, URL correspondence and derived field tampering', () => {
  const original = build(['s.ts', 't.ts'], ['a.m4a', 'b.m4a']);
  const mutators = [value => { value.kind = 'Dash'; }, value => { value.chunks[1].id = 'c0'; },
    value => { value.chunks[0].id = 'c00'; }, value => { value.chunks[2].trackOrder = 3; },
    value => { const item = value.chunks[0]; value.chunks[0] = value.chunks[1]; value.chunks[1] = item;
      value.chunks.forEach((chunk, i) => { chunk.id = 'c' + i; }); },
    value => { value.tracks[0].role = 'muxed'; }, value => { value.tracks[0].index = 1; },
    value => { value.tracks[1].playlistUrl = PRIMARY; }, value => { value.secondaryUrl = ''; },
    value => { value.duration = 99; }, value => { value.tracks[0].container = '.mp4'; },
    value => { value.suggestedExtension = '.ts'; }, value => { value.chunks[2].mediaSequence = 9; },
    value => { value.chunks[2].discontinuitySequence = 1; }, value => { value.tracks.push(value.tracks[0]); }];
  for (const mutate of mutators) { const value = plain(original); mutate(value); assert.equal(plan.copyAdaptivePlan(value), null); }
});

test('canonical plan and chunks reject extra/missing fields and invalid scalar/range values', () => {
  const original = build(['#EXT-X-BYTERANGE:10@90', 's.ts']);
  for (const mutate of [value => { value.extra = true; }, value => { value.tracks[0].extra = true; },
    value => { value.chunks[0].extra = true; }, value => { delete value.chunks[0].duration; },
    value => { value.chunks[0].offset = -1; }, value => { value.chunks[0].length = 0; },
    value => { value.chunks[0].length = -1; }, value => { value.chunks[0].offset = Number.MAX_SAFE_INTEGER; },
    value => { value.chunks[0].trackIndex = 0.5; }, value => { value.chunks[0].trackOrder = '0'; },
    value => { value.chunks[0].mediaSequence = Number.MAX_SAFE_INTEGER + 1; },
    value => { value.chunks[0].isInit = true; value.chunks[0].duration = 1; }]) {
    const value = plain(original); mutate(value); assert.equal(plan.copyAdaptivePlan(value), null);
  }
});

test('partition matches source leading, internal and trailing-finished closed ranges', () => {
  assert.deepEqual(plain(plan.partitionAdaptiveChunks(parts([true, false, true, false, true]), 2)), [{ start: 0, end: 1 }, { start: 2, end: 3 }]);
  assert.deepEqual(plain(plan.partitionAdaptiveChunks(parts([true, false, true, false, true, false, true]), 2)),
    [{ start: 0, end: 3 }, { start: 4, end: 6 }]);
  assert.deepEqual(plain(plan.partitionAdaptiveChunks(parts([false, true, true]), 1)), [{ start: 0, end: 0 }]);
  assert.deepEqual(plain(plan.partitionAdaptiveChunks(parts([true, true]), 64)), []);
  assert.deepEqual(plain(plan.partitionAdaptiveChunks([], 64)), []);
});

test('partition cap supports 1..64 and defensively normalizes invalid configuration', () => {
  const items = parts(Array(64).fill(false));
  for (const cap of [1, 3, 8, 16, 17, 32, 64, 65, 0, -1, 1.5, NaN, Infinity]) {
    const effective = Number.isFinite(cap) && Number.isInteger(cap) && cap >= 1 ? Math.min(64, cap) : 1;
    const ranges = plan.partitionAdaptiveChunks(items, cap);
    assert.ok(ranges.length <= effective);
    const seen = new Set();
    for (const range of ranges) {
      assert.ok(range.start <= range.end);
      for (let index = range.start; index <= range.end; index++) { assert.equal(seen.has(index), false); seen.add(index); }
    }
    assert.equal(seen.size, 64);
    if (effective === 64) assert.equal(ranges.length, 64);
  }
});

test('progress counts verified chunks separately from prefix bytes and rounds down percentages', () => {
  const items = parts([true, false, false]); items[0].downloaded = 10; items[1].downloaded = 5;
  assert.deepEqual(plain(plan.adaptiveProgress(items)), { completed: 1, total: 3, percent: 33, downloadedBytes: 15 });
  assert.deepEqual(plain(plan.adaptiveProgress([])), { completed: 0, total: 0, percent: 0, downloadedBytes: 0 });
  assert.equal(plan.adaptiveProgress(parts([true, true])).percent, 100);
});

test('progress rejects unsafe byte totals and malformed completion flags without silent coercion', () => {
  for (const count of [-1, 0.5, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1]) {
    const item = parts([false]); item[0].downloaded = count;
    assert.throws(() => plan.adaptiveProgress(item), /Invalid adaptive progress/);
  }
  const overflow = parts([true, false]); overflow[0].downloaded = Number.MAX_SAFE_INTEGER; overflow[1].downloaded = 1;
  assert.throws(() => plan.adaptiveProgress(overflow), /Invalid adaptive progress/);
  assert.throws(() => plan.partitionAdaptiveChunks([{ complete: 'false' }], 8), /Invalid adaptive progress/);
});

test('fresh state uses generation zero, ordered empty parts and a validated deep-copied plan', () => {
  const original = build(['s.ts', 't.ts']);
  const value = codec.newAdaptiveState(ID, original);
  assert.equal(value.schema, 1); assert.equal(value.generation, 0); assert.equal(value.downloadId, ID);
  assert.deepEqual(plain(value.parts), [{ chunkId: 'c0', downloaded: 0, complete: false, fileName: '' },
    { chunkId: 'c1', downloaded: 0, complete: false, fileName: '' }]);
  original.chunks[0].url = 'https://changed/s.ts'; assert.notEqual(value.plan.chunks[0].url, original.chunks[0].url);
  for (const id of ['', '../outside', 'not-a-uuid', ID + 'x']) assert.equal(codec.newAdaptiveState(id, original), null);
});

test('codec round-trips partial range, verified complete range and verified empty whole resource', () => {
  const value = state(['#EXT-X-BYTERANGE:10@90', 'packed.ts', '#EXT-X-BYTERANGE:5@20', 'packed.ts', 'empty.ts']);
  prefix(value.parts[0], 4, false, 'prefix_0.part'); prefix(value.parts[1], 5, true, 'verified-1.part');
  prefix(value.parts[2], 0, true, 'empty.part'); value.generation = Number.MAX_SAFE_INTEGER;
  const encoded = codec.encodeAdaptiveState(value);
  const decoded = codec.decodeAdaptiveState(encoded, ID);
  assert.deepEqual(plain(decoded), plain(value));
  decoded.parts[0].downloaded = 2; decoded.plan.chunks[0].url = 'https://changed/s.ts';
  assert.equal(value.parts[0].downloaded, 4); assert.notEqual(value.plan.chunks[0].url, decoded.plan.chunks[0].url);
});

test('codec validates schema, UUID binding, generation, exact fields and all nested models', () => {
  const original = state(['s.ts']);
  assert.equal(codec.decodeAdaptiveState(codec.encodeAdaptiveState(original), OTHER_ID), null);
  for (const mutate of [value => { value.schema = 2; }, value => { value.schema = '1'; }, value => { value.downloadId = 'bad'; },
    value => { value.generation = -1; }, value => { value.generation = 0.5; }, value => { value.generation = Number.MAX_SAFE_INTEGER + 1; },
    value => { value.cookies = 'secret'; }, value => { value.plan.extra = 1; }, value => { value.plan.tracks[0].extra = 1; },
    value => { value.plan.chunks[0].extra = 1; }, value => { value.parts[0].extra = 1; },
    value => { delete value.parts[0].complete; }, value => { value.parts[0].complete = 'false'; },
    value => { value.parts[0].downloaded = '0'; }]) {
    const value = plain(original); mutate(value); badState(value);
  }
});

test('known-range state accepts only fresh, strictly shorter partial and exact verified complete', () => {
  for (const [downloaded, complete, name] of [[0, false, ''], [1, false, 'p.part'], [9, false, 'p.part'], [10, true, 'p.part']]) {
    const value = state(['#EXT-X-BYTERANGE:10@90', 's.ts']); prefix(value.parts[0], downloaded, complete, name);
    assert.ok(codec.decodeAdaptiveState(codec.encodeAdaptiveState(value), ID));
  }
  for (const [downloaded, complete, name] of [[0, false, 'p.part'], [1, false, ''], [10, false, 'p.part'],
    [11, false, 'p.part'], [9, true, 'p.part'], [11, true, 'p.part'], [10, true, ''], [0, true, 'p.part'],
    [-1, false, 'p.part'], [0.5, false, 'p.part'], [Number.MAX_SAFE_INTEGER + 1, true, 'p.part']]) {
    const value = state(['#EXT-X-BYTERANGE:10@90', 's.ts']); prefix(value.parts[0], downloaded, complete, name);
    badState(value, [downloaded, complete, name].join('|'));
  }
});

test('unknown-size resources permit verified zero-byte completion but no zero-byte partial filename', () => {
  for (const [bytes, complete, name] of [[0, false, ''], [0, true, 'empty.part'], [1, false, 'prefix.part'], [1, true, 'done.part']]) {
    const value = state(); prefix(value.parts[0], bytes, complete, name);
    assert.ok(codec.decodeAdaptiveState(codec.encodeAdaptiveState(value), ID));
  }
  for (const [bytes, complete, name] of [[0, false, 'partial.part'], [0, true, ''], [1, true, ''], [1, false, '']]) {
    const value = state(); prefix(value.parts[0], bytes, complete, name); badState(value);
  }
});

test('part basenames are restricted, bounded and unique across different chunk IDs', () => {
  for (const name of ['../x.part', '/x.part', 'C:\\x.part', 'x.part/child', '.part', 'x.PART', 'x.part:stream',
    '中文.part', 'x'.repeat(121) + '.part', 'x.part\n']) {
    const value = state(); prefix(value.parts[0], 1, false, name); badState(value, name);
  }
  const limit = state(); prefix(limit.parts[0], 1, false, 'x'.repeat(120) + '.part');
  assert.ok(codec.decodeAdaptiveState(codec.encodeAdaptiveState(limit), ID));
  const duplicate = state(['s.ts', 't.ts']);
  prefix(duplicate.parts[0], 1, true, 'same.part'); prefix(duplicate.parts[1], 1, true, 'same.part'); badState(duplicate);
  assert.ok(codec.decodeAdaptiveState(codec.encodeAdaptiveState(state(['s.ts', 't.ts'])), ID));
});

test('part order/count/identity and summed downloaded bytes are strict at both codec boundaries', () => {
  const original = state(['s.ts', 't.ts']);
  for (const mutate of [value => { value.parts.reverse(); }, value => { value.parts.pop(); },
    value => { value.parts.push(value.parts[0]); }, value => { value.parts[0].chunkId = 'c1'; },
    value => { prefix(value.parts[0], Number.MAX_SAFE_INTEGER, true, 'one.part'); prefix(value.parts[1], 1, true, 'two.part'); }]) {
    const value = plain(original); mutate(value); badState(value);
  }
});

test('invalid serialization raises a fixed error without signed URL, credentials or raw JSON details', () => {
  const value = state(); value.plan.primaryUrl = 'https://user:password@host/?token=hidden';
  assert.throws(() => codec.encodeAdaptiveState(value), error => error.message === 'Invalid adaptive state' &&
    !String(error.stack).includes('token=hidden') && !String(error.stack).includes('user:password'));
  value.plan.loop = value;
  assert.throws(() => codec.encodeAdaptiveState(value), error => error.message === 'Invalid adaptive state');
});

test('decoder rejects malformed JSON, primitive shapes and prototype-style fields', () => {
  for (const text of ['', '{', 'null', '[]', '1', '"string"', '{"__proto__":{"polluted":true}}',
    '{"constructor":{"prototype":{"x":1}}}']) assert.equal(codec.decodeAdaptiveState(text, ID), null);
  const value = codec.encodeAdaptiveState(state());
  assert.equal(codec.decodeAdaptiveState(value.replace('"generation":0', '"__proto__":{},"generation":0'), ID), null);
  assert.equal({}.polluted, undefined);
});

test('reconcile clears missing/short files and retains only committed prefixes from longer files', () => {
  const value = state(['#EXT-X-BYTERANGE:10@90', 's.ts']); prefix(value.parts[0], 4, false, 'prefix.part');
  const before = plain(value.parts[0]);
  for (const size of [-1, -2, 0, 3, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1]) {
    assert.deepEqual(plain(codec.reconcileAdaptivePart(value.plan.chunks[0], value.parts[0], size)),
      { chunkId: 'c0', downloaded: 0, complete: false, fileName: '' });
  }
  for (const size of [4, 10, 100]) assert.deepEqual(plain(codec.reconcileAdaptivePart(value.plan.chunks[0], value.parts[0], size)), before);
  assert.deepEqual(plain(value.parts[0]), before);
});

test('reconcile never completes an unknown resource based on stat and preserves verified empty responses', () => {
  const value = state();
  assert.equal(codec.reconcileAdaptivePart(value.plan.chunks[0], value.parts[0], 100).complete, false);
  prefix(value.parts[0], 3, false, 'partial.part');
  const partial = codec.reconcileAdaptivePart(value.plan.chunks[0], value.parts[0], 999999);
  assert.equal(partial.downloaded, 3); assert.equal(partial.complete, false);
  prefix(value.parts[0], 0, true, 'empty.part');
  assert.equal(codec.reconcileAdaptivePart(value.plan.chunks[0], value.parts[0], 0).complete, true);
  assert.equal(codec.reconcileAdaptivePart(value.plan.chunks[0], value.parts[0], -1).complete, false);
});

test('reconcile rejects uncommitted full ranges and invalid local combinations instead of inventing completion', () => {
  const value = state(['#EXT-X-BYTERANGE:10@90', 's.ts']);
  for (const [bytes, complete, name] of [[10, false, 'attempt.part'], [11, true, 'over.part'], [9, true, 'short.part'],
    [1, false, ''], [0, false, 'empty-attempt.part']]) {
    prefix(value.parts[0], bytes, complete, name);
    const result = codec.reconcileAdaptivePart(value.plan.chunks[0], value.parts[0], 100);
    assert.equal(result.downloaded, 0); assert.equal(result.complete, false); assert.equal(result.fileName, '');
  }
  prefix(value.parts[0], 10, true, 'verified.part');
  assert.equal(codec.reconcileAdaptivePart(value.plan.chunks[0], value.parts[0], 11).complete, true);
  value.parts[0].chunkId = 'c1';
  assert.equal(codec.reconcileAdaptivePart(value.plan.chunks[0], value.parts[0], 10).fileName, '');
});

test('range endpoint at MAX_SAFE_INTEGER can retain a valid shorter prefix without arithmetic overflow', () => {
  const value = state(['#EXT-X-BYTERANGE:2@9007199254740990', 's.ts']); prefix(value.parts[0], 1, false, 'prefix.part');
  assert.ok(codec.decodeAdaptiveState(codec.encodeAdaptiveState(value), ID));
  const result = codec.reconcileAdaptivePart(value.plan.chunks[0], value.parts[0], 2);
  assert.equal(result.downloaded, 1); assert.equal(result.complete, false);
  assert.equal(value.plan.chunks[0].offset + result.downloaded, Number.MAX_SAFE_INTEGER);
});

test('full canonical plan JSON budget accepts minus one/exact and rejects plus one across builder and codec', () => {
  const exact = tunePlanSize(build(Array(512).fill('s.ts')), plan.ADAPTIVE_MAX_PLAN_CHARS);
  const below = plain(exact); below.chunks[0].url = below.chunks[0].url.replace('/x', '/');
  const above = plain(exact); above.chunks[511].url = above.chunks[511].url.replace('/s.ts', '/xs.ts');
  assert.equal(JSON.stringify(below).length, plan.ADAPTIVE_MAX_PLAN_CHARS - 1);
  assert.equal(JSON.stringify(above).length, plan.ADAPTIVE_MAX_PLAN_CHARS + 1);
  for (const value of [below, exact]) {
    assert.ok(plan.copyAdaptivePlan(value));
    assert.ok(plan.buildHlsPlan(PRIMARY, playlistFromPlan(value)));
    assert.ok(codec.newAdaptiveState(ID, value));
  }
  assert.equal(plan.copyAdaptivePlan(above), null);
  assert.equal(plan.buildHlsPlan(PRIMARY, playlistFromPlan(above)), null);
  assert.equal(codec.newAdaptiveState(ID, above), null);
  const invalid = new plan.AdaptiveDownloadState(); invalid.downloadId = ID; invalid.plan = above;
  invalid.parts = above.chunks.map(item => { const part = new plan.AdaptivePartState(); part.chunkId = item.id; return part; });
  badState(invalid);
});

test('plan budget includes JSON escaping and refuses oversize before a whole-plan stringify', () => {
  const above = tunePlanSize(build(Array(512).fill('s.ts')), plan.ADAPTIVE_MAX_PLAN_CHARS + 2, '"');
  assert.ok(above.chunks.reduce((sum, item) => sum + item.url.length, 0) < plan.ADAPTIVE_MAX_PLAN_CHARS);
  let wholePlans = 0;
  const checkedPlan = loadProduction(path.join(source, 'AdaptivePlan.ets'), { './DashModel': require('./production-loader.cjs').loadProduction(require('node:path').resolve(__dirname, '../../entry/src/main/ets/core/adaptive/DashModel.ets'), {}, { Error }),  './HlsModel': model, './HlsParser': parser }, {
    JSON: { stringify: value => { if (value?.kind === 'Hls' && value.chunks?.length > 0) wholePlans++; return JSON.stringify(value); } }
  });
  assert.equal(checkedPlan.copyAdaptivePlan(above), null);
  assert.equal(wholePlans, 0);
});

test('decoder checks full 16 Mi input boundary and shape bounds before parsing unbounded content', () => {
  const encoded = codec.encodeAdaptiveState(state());
  const exact = encoded + ' '.repeat(plan.ADAPTIVE_MAX_STATE_CHARS - encoded.length);
  assert.ok(codec.decodeAdaptiveState(exact, ID));
  let parses = 0;
  const checkedCodec = loadProduction(path.join(source, 'AdaptiveStateCodec.ets'), { './AdaptivePlan': plan }, {
    JSON: { stringify: value => JSON.stringify(value), parse: text => { parses++; return JSON.parse(text); } }
  });
  assert.equal(checkedCodec.decodeAdaptiveState(exact + ' ', ID), null);
  assert.equal(checkedCodec.decodeAdaptiveState('['.repeat(9) + '0' + ']'.repeat(9), ID), null);
  assert.equal(parses, 0);
});

test('maximum 20000-chunk plan leaves enough complete-state budget after every basename/prefix grows', () => {
  const value = build(Array(parser.HLS_MAX_SEGMENTS).fill('s.ts'), Array(parser.HLS_MAX_SEGMENTS).fill('s.ts'));
  assert.equal(value.chunks.length, plan.ADAPTIVE_MAX_CHUNKS);
  tunePlanSize(value, plan.ADAPTIVE_MAX_PLAN_CHARS);
  const snapshot = codec.newAdaptiveState(ID, value);
  assert.ok(snapshot);
  const each = Math.floor(Number.MAX_SAFE_INTEGER / snapshot.parts.length);
  for (let i = 0; i < snapshot.parts.length; i++) {
    prefix(snapshot.parts[i], each, i % 2 === 0, 'p' + String(i).padStart(5, '0') + 'x'.repeat(114) + '.part');
  }
  const encoded = codec.encodeAdaptiveState(snapshot);
  assert.ok(encoded.length <= 12528724, '8 Mi plan + declared maximum part/envelope reservation');
  assert.ok(encoded.length <= plan.ADAPTIVE_MAX_STATE_CHARS);
  const restored = codec.decodeAdaptiveState(encoded, ID);
  assert.equal(restored.parts.length, 20000);
  assert.equal(restored.parts[19999].fileName.length, 125);
  const maximumPart = new plan.AdaptivePartState(); maximumPart.chunkId = 'c19999';
  prefix(maximumPart, Number.MAX_SAFE_INTEGER, false, 'x'.repeat(120) + '.part');
  assert.ok(JSON.stringify(maximumPart).length <= 206);
  const tooMany = playlist(Array(parser.HLS_MAX_SEGMENTS).fill('s.ts'));
  const extra = new model.HlsMediaSegment(); extra.url = 'https://video.example/s.ts'; extra.sequence = 10000;
  tooMany.segments.push(extra);
  assert.equal(plan.buildHlsPlan(PRIMARY, tooMany), null);
});

test('Hypium source declares and executes 45 actual production-plan/state cases on host', () => {
  const cases = [];
  const suite = loadProduction(path.resolve(__dirname, '../../entry/src/test/AdaptivePlan.test.ets'), {
    '@ohos/hypium': {
      describe: (_name, body) => body(),
      it: (name, _flags, body) => cases.push({ name, body }),
      expect: actual => ({
        assertEqual: expected => assert.equal(actual, expected),
        assertTrue: () => assert.equal(actual, true),
        assertFalse: () => assert.equal(actual, false)
      })
    },
    '../main/ets/core/adaptive/HlsModel': model,
    '../main/ets/core/adaptive/HlsParser': parser,
    '../main/ets/core/adaptive/AdaptivePlan': plan,
    '../main/ets/core/adaptive/AdaptiveStateCodec': codec,
    '../main/ets/core/adaptive/DashModel': loadProduction(path.resolve(__dirname, '../../entry/src/main/ets/core/adaptive/DashModel.ets'), {}, { Error })
  }, { Error });
  suite.default();
  // U7.1 (a98e2fc) added 13 Dash budget/codec cases to the Hypium source: 32 -> 45.
  assert.equal(cases.length, 45);
  assert.equal(new Set(cases.map(item => item.name)).size, 45);
  for (const item of cases) {
    try { item.body(); } catch (error) { throw new Error('Hypium source case failed: ' + item.name, { cause: error }); }
  }
});
