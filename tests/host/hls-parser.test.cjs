'use strict';
// Actual production ETS. Only the platform URL primitive is replaced by Node URL;
// these tests do not establish Harmony URL/runtime or HLS downloader acceptance.
const assert = require('node:assert/strict');
const path = require('node:path');
const { test } = require('node:test');
const { loadProduction } = require('./production-loader.cjs');

const source = path.resolve(__dirname, '../../entry/src/main/ets/core/adaptive');
const model = loadProduction(path.join(source, 'HlsModel.ets'), {});
const adapter = loadProduction(path.join(source, 'HlsUrlResolver.ets'), {
  './HlsModel': model,
  '@kit.ArkTS': { url: { URL: { parseURL: (reference, base) => new URL(reference, base) } } }
});
const parser = loadProduction(path.join(source, 'HlsParser.ets'), { './HlsModel': model });
const base = 'https://media.example/live/master.m3u8?base=a%2Fb#old';
const resolve = adapter.resolveHlsUrl;
const master = text => parser.parseHlsMasterPlaylist(text, base, resolve);
const media = text => parser.parseHlsMediaPlaylist(text, base, resolve);
const manifest = lines => '#EXTM3U\n' + lines.join('\n');
const plain = value => JSON.parse(JSON.stringify(value));
const ranges = playlist => plain(playlist.segments.map(segment => segment.byteRange));

test('attributes preserve quoted commas, first equals, duplicate-last and source value trimming', () => {
  const result = parser.parseHlsAttributes(' CODECS = "avc1.4d401f,mp4a.40.2",URI="v?sig=a=b&x=1", NAME=" old ",NAME=\' new \' ');
  assert.deepEqual(plain(result), { CODECS: 'avc1.4d401f,mp4a.40.2', URI: 'v?sig=a=b&x=1', NAME: 'new' });
  assert.deepEqual(plain(parser.parseHlsAttributes('')), {});
});

test('attributes reject broken quoting, missing equals, empty pairs and invalid keys', () => {
  for (const input of ['URI="unclosed', 'URI="a"b', 'URI=\'unclosed', 'URI=a,', ',URI=a', 'URI=a,,NAME=b',
    'URI', '=a', 'lower=a', '__proto__=a', 'NAME="a\u0000b"']) {
    assert.equal(parser.parseHlsAttributes(input), null, input);
  }
});

test('attributes enforce count and input length limits', () => {
  const maximum = Array.from({ length: parser.HLS_MAX_ATTRIBUTES }, (_, i) => 'X' + i + '=a').join(',');
  assert.equal(Object.keys(parser.parseHlsAttributes(maximum)).length, parser.HLS_MAX_ATTRIBUTES);
  assert.equal(parser.parseHlsAttributes(maximum + ',EXTRA=a'), null);
  assert.equal(parser.parseHlsAttributes('URI=' + 'a'.repeat(parser.HLS_MAX_LINE_CHARS)), null);
});

test('URL adapter resolves relative, absolute, parent, protocol-relative and query-only references', () => {
  const cases = [
    ['video/index.m3u8', 'https://media.example/live/video/index.m3u8'],
    ['../segment.ts', 'https://media.example/segment.ts'],
    ['/root/part.ts', 'https://media.example/root/part.ts'],
    ['//cdn.example/part.ts', 'https://cdn.example/part.ts'],
    ['http://cdn.example/part.ts', 'http://cdn.example/part.ts'],
    ['?sig=new%2F%2B&x=a=b', 'https://media.example/live/master.m3u8?sig=new%2F%2B&x=a=b'],
    ['part%2fA%2B.ts?sig=x%2Fy%2B&z=a=b', 'https://media.example/live/part%2fA%2B.ts?sig=x%2Fy%2B&z=a=b'],
    ['https://[::1]:8080/part.ts', 'https://[::1]:8080/part.ts']
  ];
  for (const [reference, expected] of cases) assert.equal(resolve(base, reference), expected);
});

test('URL adapter rejects non-HTTP, missing authority, control and ambiguous raw references', () => {
  const badReferences = ['', ' ', ' file:///x', 'file:///x', 'data:text/plain,x', 'javascript:alert(1)',
    'ftp://cdn.example/x', 'http:///cdn.example/x', 'https:opaque', 'https://', '//', '///cdn.example/x',
    '//?secret=x', '/a\nb', '/a\rb', '/a\tb', '/a\u0000b', '/a\u007fb', '\\cdn.example\\x', 'part.ts '];
  for (const reference of badReferences) assert.throws(() => resolve(base, reference), /HLS URL could not be resolved/);
  for (const origin of ['', 'not-a-url', 'file:///x', 'https://', 'http:///cdn.example/x',
    'https:cdn.example/x', ' https://media.example/x', 'https://media.example/\nx']) {
    assert.throws(() => resolve(origin, 'part.ts'), /HLS URL could not be resolved/);
  }
});

test('URL failures redact credentials, signed queries and SDK errors', () => {
  const throwingAdapter = loadProduction(path.join(source, 'HlsUrlResolver.ets'), {
    './HlsModel': model,
    '@kit.ArkTS': { url: { URL: { parseURL: () => { throw new Error('secret:password?token=hidden'); } } } }
  });
  assert.throws(() => throwingAdapter.resolveHlsUrl('https://user:password@example.test/?token=hidden', 'part.ts'),
    error => error.message === 'HLS URL could not be resolved' && !String(error.stack).includes('token=hidden'));
});

test('URL limits apply before and after percent-encoding expansion', () => {
  assert.throws(() => resolve(base, 'x'.repeat(model.HLS_MAX_URL_CHARS + 1)), /HLS URL/);
  assert.throws(() => resolve('https://a/' + 'x'.repeat(model.HLS_MAX_URL_CHARS), 's'), /HLS URL/);
  assert.throws(() => resolve(base, '\u4e2d'.repeat(Math.ceil(model.HLS_MAX_URL_CHARS / 9))), /HLS URL/);
  assert.equal(resolve('https://a/', 'x'.repeat(model.HLS_MAX_URL_CHARS - 'https://a/'.length)).length,
    model.HLS_MAX_URL_CHARS);
});

test('master accepts BOM/CRLF and independent single-track variants', () => {
  const result = master('\ufeff\r\n #EXTM3U \r\n#EXT-X-VERSION:3\r\n#EXT-X-STREAM-INF:BANDWIDTH=2048,RESOLUTION=1280x720\r\nv/one.m3u8\r\n#EXT-X-STREAM-INF:BANDWIDTH=4096\r\n../two.m3u8\r\n');
  assert.equal(result.length, 2);
  assert.equal(result[0].videoPlaylist, 'https://media.example/live/v/one.m3u8');
  assert.equal(result[0].audioPlaylist, null);
  assert.equal(result[0].attributes.RESOLUTION, '1280x720');
  assert.equal(result[1].videoPlaylist, 'https://media.example/two.m3u8');
});

test('master expands all AUDIO renditions including in-band and lets rendition attributes win', () => {
  const result = master(manifest([
    '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",LANGUAGE="en",URI="audio/en.m3u8"',
    '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Chinese",LANGUAGE="zh",URI="audio/zh.m3u8"',
    '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Muxed"',
    '#EXT-X-STREAM-INF:BANDWIDTH=2048,AUDIO="aud",NAME="stream",CODECS="avc1,mp4a"', 'video.m3u8'
  ]));
  assert.equal(result.length, 3);
  assert.deepEqual(plain(result.map(item => item.attributes.NAME)), ['English', 'Chinese', 'Muxed']);
  assert.deepEqual(plain(result.map(item => item.audioPlaylist)), [
    'https://media.example/live/audio/en.m3u8', 'https://media.example/live/audio/zh.m3u8', null]);
  assert.ok(result.every(item => item.videoPlaylist === 'https://media.example/live/video.m3u8'));
  assert.equal(result[0].attributes.CODECS, 'avc1,mp4a');
  assert.equal(result[0].attributes.BANDWIDTH, '2048');
});

test('master gives AUDIO precedence over VIDEO and does not invent missing groups', () => {
  const result = master(manifest([
    '#EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="vid",NAME="video",URI="other.m3u8"',
    '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="audio",URI="a.m3u8"',
    '#EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO="aud",VIDEO="vid"', 'v.m3u8'
  ]));
  assert.equal(result.length, 1);
  assert.equal(result[0].attributes.NAME, 'audio');
  assert.equal(result[0].videoPlaylist, 'https://media.example/live/v.m3u8');
  assert.equal(master(manifest(['#EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO="missing"', 'v.m3u8'])), null);
  const mixed = master(manifest(['#EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO="missing"', 'v.m3u8',
    '#EXT-X-STREAM-INF:BANDWIDTH=1', 'standalone.m3u8']));
  assert.equal(mixed.length, 1);
  assert.equal(mixed[0].videoPlaylist, 'https://media.example/live/standalone.m3u8');
});

test('master VIDEO groups reverse stream/rendition track mapping and retain in-band null', () => {
  const result = master(manifest([
    '#EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="vid",NAME="External",URI="v.m3u8"',
    '#EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="vid",NAME="In-band"',
    '#EXT-X-STREAM-INF:BANDWIDTH=1,VIDEO="vid"', 'a.m3u8'
  ]));
  assert.equal(result.length, 2);
  assert.equal(result[0].videoPlaylist, 'https://media.example/live/v.m3u8');
  assert.equal(result[1].videoPlaylist, null);
  assert.ok(result.every(item => item.audioPlaylist === 'https://media.example/live/a.m3u8'));
});

test('master rejects truncated pairs, bare URI, malformed bandwidth and required rendition fields', () => {
  const bad = [[], ['bare.m3u8'], ['#EXT-X-STREAM-INF:BANDWIDTH=1'],
    ['#EXT-X-STREAM-INF:BANDWIDTH=1', '#EXT-X-STREAM-INF:BANDWIDTH=2', 'v.m3u8'],
    ['#EXT-X-STREAM-INF:BANDWIDTH=1', '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=g,NAME=n', 'v.m3u8'],
    ['#EXT-X-STREAM-INF', 'v.m3u8'], ['#EXT-X-STREAM-INF:NAME=n', 'v.m3u8'],
    ['#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=g', '#EXT-X-STREAM-INF:BANDWIDTH=1', 'v.m3u8'],
    ['#EXT-X-MEDIA:GROUP-ID=g,NAME=n', '#EXT-X-STREAM-INF:BANDWIDTH=1', 'v.m3u8'],
    ['#EXT-X-MEDIA:TYPE=AUDIO,NAME=n', '#EXT-X-STREAM-INF:BANDWIDTH=1', 'v.m3u8']];
  for (const value of ['0', '-1', '1.5', '1e3', 'NaN', 'Infinity', '9007199254740992', '']) {
    bad.push(['#EXT-X-STREAM-INF:BANDWIDTH=' + value, 'v.m3u8']);
  }
  for (const lines of bad) assert.equal(master(manifest(lines)), null, lines.join(' | '));
});

test('master rejects media transport tags mixed into a variant list', () => {
  for (const tag of ['#EXTINF:1,', '#EXTINF', '#EXT-X-BYTERANGE:10@0', '#EXT-X-KEY:METHOD=NONE',
    '#EXT-X-MAP:URI="init.mp4"', '#EXT-X-MEDIA-SEQUENCE:1', '#EXT-X-ENDLIST', '#EXT-X-TARGETDURATION:2']) {
    assert.equal(master(manifest(['#EXT-X-STREAM-INF:BANDWIDTH=1', 'v.m3u8', tag])), null, tag);
  }
});

test('master rejects any matched invalid URI and never returns a partial malformed result', () => {
  assert.equal(master(manifest(['#EXT-X-STREAM-INF:BANDWIDTH=1', 'file:///secret'])), null);
  assert.equal(master(manifest(['#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=g,NAME=n,URI=""',
    '#EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO=g', 'v.m3u8'])), null);
  assert.equal(master(manifest(['#EXT-X-STREAM-INF:BANDWIDTH=1', 'v.m3u8',
    '#EXT-X-STREAM-INF:BANDWIDTH=1', 'https:///empty-authority'])), null);
});

test('master stream and rendition input bounds accept the exact maximum', () => {
  const streams = Array.from({ length: parser.HLS_MAX_VARIANTS }, () => '#EXT-X-STREAM-INF:BANDWIDTH=1\nv.m3u8');
  assert.equal(master(manifest(streams)).length, parser.HLS_MAX_VARIANTS);
  assert.equal(master(manifest(streams.concat(streams[0]))), null);
  const renditions = Array.from({ length: parser.HLS_MAX_RENDITIONS }, (_, i) =>
    '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=g,NAME=n' + i);
  assert.equal(master(manifest(renditions.concat('#EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO=g', 'v.m3u8'))).length,
    parser.HLS_MAX_RENDITIONS);
  assert.equal(master(manifest(renditions.concat(renditions[0], '#EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO=g', 'v.m3u8'))), null);
});

test('master expansion bound includes grouped cross products and following standalone streams', () => {
  const renditions = Array.from({ length: parser.HLS_MAX_RENDITIONS }, (_, i) =>
    '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=g,NAME=n' + i);
  assert.equal(master(manifest(renditions.concat('#EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO=g', 'v.m3u8',
    '#EXT-X-STREAM-INF:BANDWIDTH=1', 'standalone.m3u8'))), null);
  assert.equal(master(manifest(renditions.slice(0, 1025).concat('#EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO=g', 'v1.m3u8',
    '#EXT-X-STREAM-INF:BANDWIDTH=2,AUDIO=g', 'v2.m3u8'))), null);
});

test('media rejects missing signatures, empty content and MAP-only content', () => {
  for (const text of ['', 's.ts', '#EXTM3Ubad\ns.ts', 'text\n#EXTM3U\ns.ts', '#EXTM3U',
    '#EXTM3U\n#EXT-X-MAP:URI="init.mp4"']) assert.equal(media(text), null, text);
});

test('media accepts BOM/CRLF and finite live snapshots while resetting EXTINF after each URI', () => {
  const result = media('\ufeff#EXTM3U\r\n#EXT-X-TARGETDURATION:3\r\n#EXTINF:2.25,title\r\ns1.ts\r\ns2.ts\r\n');
  assert.equal(result.segments.length, 2);
  assert.deepEqual(plain(result.segments.map(segment => segment.duration)), [2.25, 0]);
  assert.equal(result.totalDuration, 2.25);
  assert.equal(result.endList, false);
  assert.equal(result.segments[0].url, 'https://media.example/live/s1.ts');
  assert.equal(result.hasByteRange, false);
  assert.equal(result.isEncrypted, false);
  assert.equal(media(manifest(['#EXTINF:1,', 's.ts', '#EXT-X-ENDLIST'])).endList, true);
});

test('media sequence advances for media only and MAP carries the following sequence', () => {
  const result = media(manifest(['#EXT-X-MEDIA-SEQUENCE:21', '#EXT-X-MAP:URI="init.mp4"',
    '#EXTINF:1,', 'first.m4s', '#EXT-X-MAP:URI="next-init.mp4"', '#EXTINF:2,', 'second.m4s']));
  assert.equal(result.mediaSequence, 21);
  assert.deepEqual(plain(result.segments.map(segment => segment.sequence)), [21, 21, 22, 22]);
  assert.deepEqual(plain(result.segments.map(segment => segment.isInit)), [true, false, true, false]);
  assert.deepEqual(plain(result.segments.map(segment => segment.duration)), [0, 1, 0, 2]);
  assert.equal(result.totalDuration, 3);
});

test('media sequence and discontinuity sequence before first media also update preceding MAP metadata', () => {
  const result = media(manifest(['#EXT-X-MAP:URI="init.mp4"', '#EXT-X-MEDIA-SEQUENCE:7',
    '#EXT-X-DISCONTINUITY-SEQUENCE:4', 's.m4s']));
  assert.deepEqual(plain(result.segments.map(segment => segment.sequence)), [7, 7]);
  assert.deepEqual(plain(result.segments.map(segment => segment.discontinuitySequence)), [4, 4]);
});

test('media rejects unsafe, duplicate or late sequence tags and checks increment overflow', () => {
  for (const value of ['-1', '1e3', '1.5', 'NaN', 'Infinity', '9007199254740992', '']) {
    assert.equal(media(manifest(['#EXT-X-MEDIA-SEQUENCE:' + value, 's.ts'])), null, value);
  }
  assert.equal(media(manifest(['#EXT-X-MEDIA-SEQUENCE:1', '#EXT-X-MEDIA-SEQUENCE:1', 's.ts'])), null);
  assert.equal(media(manifest(['s.ts', '#EXT-X-MEDIA-SEQUENCE:1'])), null);
  assert.equal(media(manifest(['#EXT-X-MEDIA-SEQUENCE:9007199254740991', 's.ts'])).segments[0].sequence,
    Number.MAX_SAFE_INTEGER);
  assert.equal(media(manifest(['#EXT-X-MEDIA-SEQUENCE:9007199254740991', 's.ts', 't.ts'])), null);
});

test('media explicit byte ranges honor nonzero offsets and explicit zero independently of history', () => {
  const result = media(manifest(['#EXT-X-BYTERANGE:10@100', 'packed.mp4',
    '#EXT-X-BYTERANGE:5@0', 'packed.mp4', '#EXT-X-BYTERANGE:3', 'packed.mp4']));
  assert.deepEqual(ranges(result), [{ offset: 100, length: 10 }, { offset: 0, length: 5 }, { offset: 5, length: 3 }]);
  assert.equal(result.hasByteRange, true);
});

test('media implicit byte ranges use the preceding range endpoint on the same resolved resource', () => {
  const result = media(manifest(['#EXT-X-BYTERANGE:10@100', './packed.mp4',
    '#EXT-X-BYTERANGE:5', 'packed.mp4', '#EXT-X-BYTERANGE:3', './packed.mp4']));
  assert.deepEqual(ranges(result), [{ offset: 100, length: 10 }, { offset: 110, length: 5 }, { offset: 115, length: 3 }]);
});

test('media implicit byte ranges reject missing predecessor, changed resource or query', () => {
  assert.equal(media(manifest(['#EXT-X-BYTERANGE:10', 'packed.mp4'])), null);
  for (const next of ['other.mp4', 'packed.mp4?next=1', '//other.example/packed.mp4']) {
    assert.equal(media(manifest(['#EXT-X-BYTERANGE:10@100', 'packed.mp4', '#EXT-X-BYTERANGE:5', next])), null);
  }
});

test('media whole-file segments clear range state but retain aggregate hasByteRange', () => {
  const result = media(manifest(['#EXT-X-BYTERANGE:10@100', 'packed.mp4', 'packed.mp4',
    '#EXT-X-BYTERANGE:5@50', 'packed.mp4', 'whole.ts']));
  assert.deepEqual(ranges(result), [{ offset: 100, length: 10 }, null, { offset: 50, length: 5 }, null]);
  assert.equal(result.hasByteRange, true);
  assert.equal(media(manifest(['#EXT-X-BYTERANGE:10@100', 'packed.mp4', 'packed.mp4',
    '#EXT-X-BYTERANGE:5', 'packed.mp4'])), null);
});

test('MAP range defaults to source offset zero independently and consumes no pending media range/duration', () => {
  const result = media(manifest(['#EXT-X-BYTERANGE:10@100', 'packed.mp4', '#EXTINF:2,',
    '#EXT-X-BYTERANGE:5', '#EXT-X-MAP:URI="init.mp4",BYTERANGE="8"', 'packed.mp4']));
  assert.deepEqual(ranges(result), [{ offset: 100, length: 10 }, { offset: 0, length: 8 }, { offset: 110, length: 5 }]);
  assert.deepEqual(plain(result.segments.map(segment => segment.duration)), [0, 0, 2]);
  assert.deepEqual(plain(result.segments.map(segment => segment.sequence)), [0, 1, 1]);
  const onlyMapRange = media(manifest(['#EXT-X-MAP:URI="init.mp4",BYTERANGE="8@40"', 's.m4s']));
  assert.deepEqual(ranges(onlyMapRange), [{ offset: 40, length: 8 }, null]);
  assert.equal(onlyMapRange.hasByteRange, true);
});

test('byte range numbers reject malformed, nonpositive or unsafe values and exact endpoint overflow', () => {
  for (const range of ['0@0', '-1@0', '1@-1', '1@', '@1', '1.5@0', '1@0@1', '1e3@0',
    'NaN@0', '9007199254740992@0', '2@9007199254740991', '9007199254740991@2']) {
    assert.equal(media(manifest(['#EXT-X-BYTERANGE:' + range, 'packed.mp4'])), null, range);
    assert.equal(media(manifest(['#EXT-X-MAP:URI="init.mp4",BYTERANGE="' + range + '"', 's.m4s'])), null, range);
  }
  assert.equal(media(manifest(['#EXT-X-BYTERANGE:1@9007199254740991', 'packed.mp4'])).segments[0].byteRange.offset,
    Number.MAX_SAFE_INTEGER);
  assert.equal(media(manifest(['#EXT-X-BYTERANGE:1@9007199254740991', 'packed.mp4',
    '#EXT-X-BYTERANGE:1', 'packed.mp4'])), null);
});

test('EXTINF rejects invalid/negative numbers and total-duration overflow', () => {
  for (const duration of ['', '-1', '-0', 'NaN', 'Infinity', '1e3', '0x10', '9007199254740992']) {
    assert.equal(media(manifest(['#EXTINF:' + duration + ',title', 's.ts'])), null, duration);
  }
  assert.equal(media(manifest(['#EXTINF:.25,title', 's.ts', '#EXTINF:+1.5,title', 't.ts'])).totalDuration, 1.75);
  assert.equal(media(manifest(['#EXTINF:9007199254740991,', 's.ts', '#EXTINF:1,', 't.ts'])), null);
});

test('media rejects duplicate/dangling transport tags and never returns a valid prefix of bad input', () => {
  for (const suffix of [['#EXTINF:1,'], ['#EXT-X-BYTERANGE:1@0'], ['#EXTINF:1,', '#EXTINF:2,', 't.ts'],
    ['#EXT-X-BYTERANGE:1@0', '#EXT-X-BYTERANGE:2@0', 't.ts'], ['#EXT-X-MAP:BYTERANGE="8@0"'],
    ['#EXT-X-MAP:URI=""'], ['#EXTINF'], ['#EXT-X-BYTERANGE'], ['#EXT-X-MEDIA-SEQUENCE'],
    ['#EXT-X-KEY'], ['#EXT-X-MAP'], ['#EXT-X-DISCONTINUITY-SEQUENCE'],
    ['#EXT-X-I-FRAMES-ONLY:invalid'], ['#EXT-X-ENDLIST:invalid'], ['#EXT-X-DISCONTINUITY:invalid'],
    ['#EXT-X-STREAM-INF'], ['#EXT-X-MEDIA'], ['#EXT-X-STREAM-INF:BANDWIDTH=1', 'v.m3u8'],
    ['#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=g,NAME=n'], ['file:///bad']]) {
    assert.equal(media(manifest(['good.ts'].concat(suffix))), null, suffix.join(' | '));
  }
});

test('AES-128 identity records key and computes a padded IV separately for each media sequence', () => {
  const result = media(manifest(['#EXT-X-MEDIA-SEQUENCE:14', '#EXT-X-KEY:METHOD=AES-128,URI="../key?sig=a=b"',
    'first.ts', 'second.ts']));
  assert.equal(result.isEncrypted, true);
  assert.deepEqual(plain(result.segments.map(segment => segment.iv)), ['0x' + '0'.repeat(31) + 'e', '0x' + '0'.repeat(31) + 'f']);
  assert.ok(result.segments.every(segment => segment.keyUrl === 'https://media.example/key?sig=a=b'));
});

test('AES explicit IV normalizes to 16 bytes and a replacement KEY without IV resumes sequence-derived IV', () => {
  const result = media(manifest(['#EXT-X-MEDIA-SEQUENCE:7',
    '#EXT-X-KEY:METHOD=AES-128,KEYFORMAT="identity",URI="key",IV=0XA', 's.ts', 't.ts',
    '#EXT-X-KEY:METHOD=AES-128,URI="new-key"', 'u.ts']));
  assert.deepEqual(plain(result.segments.map(segment => segment.iv)), ['0x' + '0'.repeat(31) + 'a',
    '0x' + '0'.repeat(31) + 'a', '0x' + '0'.repeat(31) + '9']);
  assert.equal(result.segments[2].keyUrl, 'https://media.example/live/new-key');
});

test('METHOD=NONE clears following key/IV while encrypted aggregate remains true', () => {
  const result = media(manifest(['#EXT-X-KEY:METHOD=AES-128,URI="key",IV=0x1', 'encrypted.ts',
    '#EXT-X-KEY:METHOD=NONE', 'plain.ts']));
  assert.equal(result.isEncrypted, true);
  assert.equal(result.segments[1].keyUrl, null);
  assert.equal(result.segments[1].iv, null);
  assert.equal(media(manifest(['#EXT-X-KEY:METHOD=NONE', 'plain.ts'])).isEncrypted, false);
});

test('unsupported encryption and malformed IV/key reject the complete media playlist', () => {
  for (const attrs of ['METHOD=SAMPLE-AES,URI="key"', 'METHOD=AES-256,URI="key"',
    'METHOD=AES-128,URI="key",KEYFORMAT="com.apple.streamingkeydelivery"', 'METHOD=AES-128',
    'METHOD=AES-128,URI=""', 'URI="key"', 'METHOD=AES-128,URI="file:///key"',
    'METHOD=AES-128,URI="key",IV=123', 'METHOD=AES-128,URI="key",IV=0x',
    'METHOD=AES-128,URI="key",IV=0xG', 'METHOD=AES-128,URI="key",IV=0x' + '1'.repeat(33)]) {
    assert.equal(media(manifest(['plain.ts', '#EXT-X-KEY:' + attrs, 'encrypted.ts'])), null, attrs);
  }
});

test('encrypted MAP requires explicit IV and carries key metadata when that IV exists', () => {
  assert.equal(media(manifest(['#EXT-X-KEY:METHOD=AES-128,URI="key"', '#EXT-X-MAP:URI="init.mp4"', 's.m4s'])), null);
  const result = media(manifest(['#EXT-X-KEY:METHOD=AES-128,URI="key",IV=0x2', '#EXT-X-MAP:URI="init.mp4"',
    '#EXT-X-KEY:METHOD=NONE', 's.m4s']));
  assert.equal(result.segments[0].isInit, true);
  assert.equal(result.segments[0].iv, '0x' + '0'.repeat(31) + '2');
  assert.equal(result.segments[1].keyUrl, null);
  assert.equal(result.isEncrypted, true);
});

test('I-frame flags accept source colon form and standard standalone form', () => {
  for (const tag of ['#EXT-X-I-FRAMES-ONLY', '#EXT-X-I-FRAMES-ONLY:']) {
    assert.equal(media(manifest([tag, 's.ts'])).isKeyIFrameOnly, true);
  }
  assert.equal(media(manifest(['s.ts'])).isKeyIFrameOnly, false);
});

test('discontinuity boundaries survive MAP insertion and subsequent media retain discontinuity sequence', () => {
  const result = media(manifest(['#EXT-X-DISCONTINUITY-SEQUENCE:5', 'first.ts', '#EXT-X-DISCONTINUITY',
    '#EXT-X-MAP:URI="new-init.mp4"', 'second.m4s', '#EXT-X-DISCONTINUITY', 'third.m4s']));
  assert.equal(result.discontinuitySequence, 5);
  assert.deepEqual(plain(result.segments.map(segment => segment.discontinuity)), [false, true, false, true]);
  assert.deepEqual(plain(result.segments.map(segment => segment.discontinuitySequence)), [5, 6, 6, 7]);
});

test('discontinuity sequence rejects late/duplicate/unsafe values and increment overflow', () => {
  for (const lines of [['#EXT-X-DISCONTINUITY-SEQUENCE:-1', 's.ts'],
    ['#EXT-X-DISCONTINUITY-SEQUENCE:9007199254740992', 's.ts'],
    ['#EXT-X-DISCONTINUITY-SEQUENCE:1', '#EXT-X-DISCONTINUITY-SEQUENCE:1', 's.ts'],
    ['s.ts', '#EXT-X-DISCONTINUITY-SEQUENCE:1'], ['#EXT-X-DISCONTINUITY', '#EXT-X-DISCONTINUITY-SEQUENCE:1', 's.ts'],
    ['#EXT-X-DISCONTINUITY-SEQUENCE:9007199254740991', '#EXT-X-DISCONTINUITY', 's.ts']]) {
    assert.equal(media(manifest(lines)), null, lines.join(' | '));
  }
});

test('resolver exceptions and invalid returned strings reject whole master/media inputs', () => {
  for (const resolver of [() => { throw new Error('secret'); }, () => '', () => 'x'.repeat(model.HLS_MAX_URL_CHARS + 1),
    () => 'https://bad/\nsecret']) {
    assert.equal(parser.parseHlsMediaPlaylist(manifest(['s.ts']), base, resolver), null);
    assert.equal(parser.parseHlsMasterPlaylist(manifest(['#EXT-X-STREAM-INF:BANDWIDTH=1', 'v.m3u8']), base, resolver), null);
  }
});

test('manifest text length limit rejects oversized input before splitting', () => {
  const prefix = '#EXTM3U\ns.ts\n';
  const maximumComment = '#' + 'x'.repeat(parser.HLS_MAX_LINE_CHARS - 1) + '\n';
  let input = prefix;
  while (input.length + maximumComment.length < parser.HLS_MAX_MANIFEST_CHARS) input += maximumComment;
  input += '#' + 'x'.repeat(parser.HLS_MAX_MANIFEST_CHARS - input.length - 1);
  assert.equal(input.length, parser.HLS_MAX_MANIFEST_CHARS);
  assert.equal(media(input).segments.length, 1);
  assert.equal(media(input + 'x'), null);
});

test('manifest individual line and physical line count limits include ignored comments', () => {
  const comment = '#' + 'x'.repeat(parser.HLS_MAX_LINE_CHARS - 1);
  assert.equal(media(manifest([comment, 's.ts'])).segments.length, 1);
  assert.equal(media(manifest([comment + 'x', 's.ts'])), null);
  const lines = ['s.ts'].concat(Array(parser.HLS_MAX_LINES - 2).fill('#comment'));
  assert.equal(media(manifest(lines)).segments.length, 1);
  assert.equal(media(manifest(lines.concat('#extra'))), null);
});

test('segment bound counts MAP and media segments together and accepts exact maximum', () => {
  const mediaLines = Array(parser.HLS_MAX_SEGMENTS).fill('s.ts');
  assert.equal(media(manifest(mediaLines)).segments.length, parser.HLS_MAX_SEGMENTS);
  assert.equal(media(manifest(mediaLines.concat('one-too-many.ts'))), null);
  const withMap = ['#EXT-X-MAP:URI="init.mp4"'].concat(mediaLines.slice(1));
  assert.equal(media(manifest(withMap)).segments.length, parser.HLS_MAX_SEGMENTS);
  assert.equal(media(manifest(withMap.concat('one-too-many.ts'))), null);
});

test('quality matches source integer bandwidth and NAME-before-LANGUAGE display order', () => {
  assert.equal(parser.hlsQuality({ RESOLUTION: '1920x1080', BANDWIDTH: '4097', NAME: 'Main', LANGUAGE: 'en' }),
    '1920x1080 4 Kbps Main');
  assert.equal(parser.hlsQuality({ BANDWIDTH: '1023', LANGUAGE: 'en' }), '0 Kbps en');
  assert.equal(parser.hlsQuality({ LANGUAGE: 'zh' }), 'zh');
  assert.equal(parser.hlsQuality({ NAME: '', LANGUAGE: 'en' }), null);
  assert.equal(parser.hlsQuality(null), null);
  assert.equal(parser.hlsQuality({}), null);
});

test('quality skips invalid bandwidth without leaking a NaN/Infinity value into labels', () => {
  for (const value of ['-1', '1.5', '1e3', 'NaN', 'Infinity', '9007199254740992', '']) {
    assert.equal(parser.hlsQuality({ RESOLUTION: '720x480', BANDWIDTH: value, LANGUAGE: 'en' }), '720x480 en');
  }
});

test('container guessing uses source extension rules and resolves differing tracks to mkv', () => {
  for (const extension of ['.m4s', '.m4a', '.mp4', '.mp4suffix', '.fmp4', '.Mp4', '.M4S', '.FMP4']) {
    assert.equal(parser.guessHlsContainer(extension), '.mp4');
  }
  assert.equal(parser.guessHlsContainer('.ts'), '.ts');
  assert.equal(parser.guessHlsContainer('.TS'), '.ts');
  for (const extension of ['', '.aac', '.ts?token=x', 'https://host/part.ts']) {
    assert.equal(parser.guessHlsContainer(extension), '.mkv');
  }
  assert.equal(parser.guessHlsContainer('.m4s', '.mp4'), '.mp4');
  assert.equal(parser.guessHlsContainer('.ts', '.ts'), '.ts');
  assert.equal(parser.guessHlsContainer('.ts', '.m4a'), '.mkv');
});

test('delta SKIP tags reject complete inputs instead of assigning incorrect snapshot sequences', () => {
  for (const tag of ['#EXT-X-SKIP:SKIPPED-SEGMENTS=3', '#EXT-X-SKIP:SKIPPED-SEGMENTS=0',
    '#EXT-X-SKIP', '#EXT-X-SKIP SKIPPED-SEGMENTS=3']) {
    assert.equal(media(manifest(['#EXT-X-MEDIA-SEQUENCE:100', tag, '#EXTINF:1,', 's103.ts', 's104.ts'])), null);
    assert.equal(master(manifest([tag, '#EXT-X-STREAM-INF:BANDWIDTH=1', 'v.m3u8'])), null);
  }
  let calls = 0;
  assert.equal(parser.parseHlsMediaPlaylist(manifest(['valid.ts', '#EXT-X-SKIP:SKIPPED-SEGMENTS=3']), base,
    (origin, reference) => { calls++; return resolve(origin, reference); }), null);
  assert.equal(calls, 0, 'unsupported tags are rejected before output or URL allocation');
  const full = media(manifest(['#EXT-X-SERVER-CONTROL:CAN-SKIP-UNTIL=6', '#EXT-X-MEDIA-SEQUENCE:100', 's100.ts']));
  assert.equal(full.segments[0].sequence, 100);
});

test('DEFINE including NAME, IMPORT and QUERYPARAM rejects even when no URI uses the variable', () => {
  for (const tag of ['#EXT-X-DEFINE:NAME="prefix",VALUE="../assets"', '#EXT-X-DEFINE:IMPORT="prefix"',
    '#EXT-X-DEFINE:QUERYPARAM="token"', '#EXT-X-DEFINE', '#EXT-X-DEFINE NAME="prefix"']) {
    assert.equal(media(manifest([tag, 'literal.ts'])), null);
    assert.equal(master(manifest([tag, '#EXT-X-STREAM-INF:BANDWIDTH=1', 'literal.m3u8'])), null);
  }
  assert.equal(media(manifest(['# ordinary comment with {$prefix} is not a variable URI', 'literal.ts'])).segments.length, 1);
});

test('unexpanded variables reject bare URI, quoted attributes, MAP, key and every master track position', () => {
  for (const lines of [['{$prefix}/s.ts'], ['s.ts?sig={$token}'], ['{$unterminated'],
    ['#EXT-X-MAP:URI="{$prefix}/init.mp4"', 'literal.ts'],
    ['#EXT-X-KEY:METHOD=AES-128,URI="key?token={$token}"', 'literal.ts']]) {
    assert.equal(media(manifest(lines)), null, lines.join(' | '));
  }
  for (const lines of [['#EXT-X-STREAM-INF:BANDWIDTH=1', '{$prefix}/variant.m3u8'],
    ['#EXT-X-STREAM-INF:BANDWIDTH=1,CODECS="{$codecs}"', 'v.m3u8'],
    ['#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=g,NAME="{$name}",URI="a.m3u8"',
      '#EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO=g', 'v.m3u8'],
    ['#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=g,NAME=n,URI="{$prefix}/a.m3u8"',
      '#EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO=g', 'v.m3u8']]) {
    assert.equal(master(manifest(lines)), null, lines.join(' | '));
  }
  assert.equal(parser.parseHlsAttributes('NAME="{$label}"'), null);
  assert.equal(parser.parseHlsMediaPlaylist(manifest(['literal.ts']), 'https://host/{$base}/m.m3u8', resolve), null);
  assert.equal(parser.parseHlsMediaPlaylist(manifest(['literal.ts']), base, () => 'https://host/{$raw}/s.ts'), null);
});

test('URL adapter rejects raw variables but preserves already encoded literal paths and signed queries', () => {
  for (const reference of ['{$prefix}/s.ts', 's.ts?sig={$token}', '{$unterminated']) {
    assert.throws(() => resolve(base, reference), /HLS URL could not be resolved/);
  }
  assert.throws(() => resolve('https://host/{$base}/m.m3u8', 's.ts'), /HLS URL could not be resolved/);
  const literal = '%7B$prefix%7D/s.ts?sig=%7B$token%7D%2F%2B';
  const expected = 'https://media.example/live/' + literal;
  assert.equal(resolve(base, literal), expected);
  assert.equal(media(manifest([literal])).segments[0].url, expected);
});

test('media cumulative output accepts 8 Mi minus one and exact 8 Mi, rejects plus one and stops early', () => {
  assert.equal(parser.HLS_MAX_OUTPUT_CHARS, 8 * 1024 * 1024);
  const prefix = 'https://budget.example/';
  const longBase = prefix + 'x'.repeat(16384 - prefix.length - 2) + '/m';
  const lines = Array(512).fill('s');
  const parse = input => parser.parseHlsMediaPlaylist(manifest(input), longBase, resolve);
  const total = playlist => playlist.segments.reduce((sum, item) => sum + item.url.length, 0);
  assert.equal(total(parse(lines)), parser.HLS_MAX_OUTPUT_CHARS);
  lines[511] = '.';
  assert.equal(total(parse(lines)), parser.HLS_MAX_OUTPUT_CHARS - 1);
  lines[511] = 'ss';
  assert.equal(parse(lines), null);
  let calls = 0;
  assert.equal(parser.parseHlsMediaPlaylist(manifest(Array(600).fill('s')), longBase,
    (origin, reference) => { calls++; return resolve(origin, reference); }), null);
  assert.ok(calls <= 514, 'reject at the first oversized output instead of resolving the whole manifest');
});

test('media output budget counts MAP, shared key URL and per-segment IV as logical occurrences', () => {
  const prefix = 'https://budget.example/';
  const longBase = prefix + 'x'.repeat(model.HLS_MAX_URL_CHARS - prefix.length - 2) + '/m';
  const parse = lines => parser.parseHlsMediaPlaylist(manifest(lines), longBase, resolve);
  const withMap = ['#EXT-X-MAP:URI="i"'].concat(Array(255).fill('s'));
  assert.equal(parse(withMap).segments.length, 256);
  assert.equal(parse(withMap.concat('s')), null);
  const encrypted = ['#EXT-X-KEY:METHOD=AES-128,URI="k",IV=0x1'].concat(Array(127).fill('s'));
  assert.equal(parse(encrypted).segments.length, 127);
  // Without charging the shared key per output, or without charging the 34-char IV,
  // 128 segments would fit incorrectly (URL + key alone equals exactly 8 Mi).
  assert.equal(parse(encrypted.concat('s')), null);
});

test('master output budget counts both shared track URLs and every merged attribute key/value', () => {
  const prefix = 'https://budget.example/';
  const longBase = prefix + 'x'.repeat(model.HLS_MAX_URL_CHARS - prefix.length - 2) + '/m';
  const grouped = count => Array.from({ length: count }, (_, i) =>
    '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=g,NAME=n' + i + ',URI="a"')
    .concat('#EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO=g', 'v');
  assert.equal(parser.parseHlsMasterPlaylist(manifest(grouped(127)), longBase, resolve).length, 127);
  assert.equal(parser.parseHlsMasterPlaylist(manifest(grouped(128)), longBase, resolve), null);
  const attribute = 'K'.repeat(8192) + '=' + 'V'.repeat(8192);
  const attributesExpanded = count => Array.from({ length: count }, (_, i) =>
    '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=g,NAME=n' + i)
    .concat('#EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO=g,' + attribute, 'v');
  assert.equal(master(manifest(attributesExpanded(400))).length, 400);
  assert.equal(master(manifest(attributesExpanded(512))), null);
});

test('master retained collection is bounded before final expansion even for unmatched groups', () => {
  const prefix = 'https://budget.example/';
  const longBase = prefix + 'x'.repeat(model.HLS_MAX_URL_CHARS - prefix.length - 2) + '/m';
  for (const attrs of ['BANDWIDTH=1,AUDIO=missing', 'BANDWIDTH=1']) {
    const text = manifest(Array(600).fill('#EXT-X-STREAM-INF:' + attrs + '\nv'));
    let calls = 0;
    assert.equal(parser.parseHlsMasterPlaylist(text, longBase,
      (origin, reference) => { calls++; return resolve(origin, reference); }), null);
    assert.ok(calls <= 258, 'do not collect all 600 long URLs before noticing the budget');
  }
});

test('Hypium source declares and executes 37 actual production-parser cases on host', () => {
  const cases = [];
  const suite = loadProduction(path.resolve(__dirname, '../../entry/src/test/HlsParser.test.ets'), {
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
    '../main/ets/core/adaptive/HlsParser': parser
  });
  suite.default();
  assert.equal(cases.length, 37);
  assert.equal(new Set(cases.map(item => item.name)).size, 37);
  for (const item of cases) {
    try { item.body(); } catch (error) { throw new Error('Hypium source case failed: ' + item.name, { cause: error }); }
  }
});

test('reference resolution follows RFC 3986 without relying on the platform base-URL handling', () => {
  // Device SDK (2026-11-06): parseURL('./', 'https://h/a/b.mpd') kept 'b.mpd' as a directory.
  const faulty = loadProduction(path.join(source, 'HlsUrlResolver.ets'), {
    './HlsModel': model,
    '@kit.ArkTS': { url: { URL: { parseURL: (reference, baseUrl) => {
      if (baseUrl !== undefined) return new URL(reference, baseUrl.endsWith('/') ? baseUrl : baseUrl + '/');
      return new URL(reference);
    } } } }
  });
  const mpd = 'https://dash.example/akamai/bbb/bbb.mpd';
  assert.equal(faulty.resolveHlsUrl(mpd, './'), 'https://dash.example/akamai/bbb/');
  assert.equal(faulty.resolveHlsUrl(faulty.resolveHlsUrl(mpd, './'), 'rep/rep_5.m4v'), 'https://dash.example/akamai/bbb/rep/rep_5.m4v');
  assert.equal(faulty.resolveHlsUrl(mpd, 'rep/rep_5.m4v'), 'https://dash.example/akamai/bbb/rep/rep_5.m4v');
  // RFC 3986 5.4.1 normal examples (base http://a/b/c/d;p?q)
  const rfc = 'http://a/b/c/d;p?q';
  const examples = [['g', 'http://a/b/c/g'], ['./g', 'http://a/b/c/g'], ['g/', 'http://a/b/c/g/'], ['/g', 'http://a/g'],
    ['//g', 'http://g/'], ['?y', 'http://a/b/c/d;p?y'], ['g?y', 'http://a/b/c/g?y'], ['#s', 'http://a/b/c/d;p?q#s'],
    [';x', 'http://a/b/c/;x'], ['g;x', 'http://a/b/c/g;x'], ['.', 'http://a/b/c/'], ['./', 'http://a/b/c/'],
    ['..', 'http://a/b/'], ['../', 'http://a/b/'], ['../g', 'http://a/b/g'], ['../..', 'http://a/'], ['../../g', 'http://a/g'],
    ['../../../g', 'http://a/g'], ['/./g', 'http://a/g'], ['/../g', 'http://a/g'], ['g.', 'http://a/b/c/g.'],
    ['./../g', 'http://a/b/g'], ['g/./h', 'http://a/b/c/g/h'], ['g/../h', 'http://a/b/c/h']];
  for (const [reference, expected] of examples) assert.equal(faulty.resolveHlsUrl(rfc, reference), expected, reference);
  assert.equal(adapter.removeDotSegments('/a/b/c/./../../g'), '/a/g');
  assert.equal(adapter.removeDotSegments('mid/content=5/../6'), 'mid/6');
});
