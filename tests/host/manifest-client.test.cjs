'use strict';
const assert = require('node:assert/strict');
const path = require('node:path');
const { test } = require('node:test');
const { loadProduction } = require('./production-loader.cjs');
const { rcpOverHttp } = require('./rcp-http-adapter.cjs');

const root = path.resolve(__dirname, '../../entry/src/main/ets');
const adaptive = name => path.join(root, 'core/adaptive', name + '.ets');
const model = loadProduction(adaptive('HlsModel'), {});
const parser = loadProduction(adaptive('HlsParser'), { './HlsModel': model });
const plan = loadProduction(adaptive('AdaptivePlan'), { './DashModel': require('./production-loader.cjs').loadProduction(require('node:path').resolve(__dirname, '../../entry/src/main/ets/core/adaptive/DashModel.ets'), {}, { Error }),  './HlsModel': model, './HlsParser': parser });
const platformUrl = { URL: { parseURL: (input, base) => new URL(input, base) } };
const resolver = loadProduction(adaptive('HlsUrlResolver'), {
  './HlsModel': model, '@kit.ArkTS': { url: platformUrl }
});
const protocol = loadProduction(path.join(root, 'core/net/HttpProtocol.ets'), {});
const contexts = loadProduction(path.join(root, 'model/DownloadRequestContext.ets'), {
  '../core/net/HttpProtocol': protocol
});
const ARRAY_BUFFER = 2;
const origin = 'https://origin.example/a/list.m3u8?sig=a%2Fb';
const playlist = '#EXTM3U\n#EXTINF:1,\nsegment.ts?sig=a%2Fb\n#EXT-X-ENDLIST\n';
const plain = value => JSON.parse(JSON.stringify(value));
const flush = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); };

function bytes(input) {
  if (input instanceof ArrayBuffer) return input;
  const buffer = typeof input === 'string' ? Buffer.from(input) : Buffer.from(input);
  return buffer.buffer.slice(buffer.byteOffset, buffer.byteOffset + buffer.byteLength);
}

function response(body = playlist, status = 200, header = {}) {
  return { result: bytes(body), resultType: ARRAY_BUFFER, responseCode: status, header, cookies: '' };
}

function context(names, values, cookies = null) {
  const value = new contexts.DownloadRequestContext();
  if (names !== undefined) value.headers = { names, values };
  value.cookies = cookies;
  return value;
}

function setup(settings = {}) {
  let now = 0, nextTimer = 1, decoderCalls = 0;
  const timers = new Map(), created = [], calls = [];
  class ClockDate extends Date { static now() { return now; } }
  const http = {
    RequestMethod: { GET: 'GET' }, HttpDataType: { ARRAY_BUFFER },
    createHttp() {
      if (settings.createError !== undefined) throw settings.createError;
      let resolve, reject;
      const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
      const request = {
        resolve, reject, destroyed: 0,
        request(url, options) {
          const call = { url, options, request }; calls.push(call);
          if (settings.requestError !== undefined) throw settings.requestError;
          if (settings.onRequest) settings.onRequest(call, calls.length - 1);
          return promise;
        },
        destroy() {
          this.destroyed++;
          if (settings.destroyError !== undefined) throw settings.destroyError;
        }
      };
      created.push(request);
      return request;
    }
  };
  const exports = loadProduction(adaptive('ManifestClient'), {
    '@kit.RemoteCommunicationKit': { rcp: rcpOverHttp(http) }, '@kit.BasicServicesKit': {},
    '@kit.ArkTS': {
      url: settings.url || platformUrl,
      util: { TextDecoder: { create(encoding, options) {
        decoderCalls++;
        assert.equal(encoding, 'utf-8'); assert.equal(options.fatal, true);
        const decoder = new TextDecoder(encoding, options);
        return { decodeToString(input, decodeOptions) {
          assert.equal(decodeOptions.stream, false);
          return decoder.decode(input, decodeOptions);
        } };
      } } }
    },
    '../../model/DownloadRequestContext': contexts,
    './HlsModel': model, './HlsParser': parser, './AdaptivePlan': plan, './HlsUrlResolver': resolver
  }, {
    Date: ClockDate,
    setTimeout(callback, delay) {
      const id = nextTimer++; timers.set(id, { at: now + delay, callback }); return id;
    },
    clearTimeout(id) { timers.delete(id); }
  });
  return {
    client: new exports.ManifestClient(), exports, created, calls, timers,
    get decoderCalls() { return decoderCalls; },
    jump(ms) { now += ms; },
    async advance(ms) {
      const until = now + ms;
      for (;;) {
        const item = [...timers].filter(([, timer]) => timer.at <= until).sort((a, b) => a[1].at - b[1].at)[0];
        if (!item) break;
        now = item[1].at; timers.delete(item[0]); item[1].callback(); await flush();
      }
      now = until; await flush();
    }
  };
}

test('GET returns the actual request URL, Unicode text and a bounded buffer contract', async () => {
  const f = setup();
  const pending = f.client.fetchGet(origin + '#display', context(), 1234);
  assert.equal(f.calls.length, 1);
  const call = f.calls[0];
  assert.equal(call.url, origin); assert.equal(call.options.maxRedirects, 0);
  assert.equal(typeof call.options.onProgress, 'function');
  assert.equal(call.options.method, 'GET'); assert.equal(call.options.usingCache, false);
  assert.equal(call.options.expectDataType, ARRAY_BUFFER);
  assert.equal(call.options.readTimeout, 1234); assert.equal(call.options.connectTimeout, 1234);
  assert.equal(Object.hasOwn(call.options, 'extraData'), false);
  f.created[0].resolve(response(playlist + '#中文\n'));
  const result = await pending;
  assert.equal(result.status, 'ok'); assert.equal(result.requestedUrl, origin + '#display');
  assert.equal(result.finalUrl, origin); assert.equal(result.text, playlist + '#中文\n');
  assert.equal(result.httpStatus, 200); assert.equal(f.created[0].destroyed, 1); assert.equal(f.timers.size, 0);
});

test('invalid raw and expanded URLs never allocate network requests or timers', async () => {
  const f = setup();
  for (const value of ['', 'bad', 'file:///x', 'ftp://a/x', 'https:///a/x', 'https:opaque',
    ' https://a/x', 'https://a/x ', 'https://a/\nx', 'https://a/\\x', 'https://[::1:]/x',
    'https://a/{$x}', 'https://a/' + 'x'.repeat(model.HLS_MAX_URL_CHARS),
    'https://a/' + '中'.repeat(Math.ceil(model.HLS_MAX_URL_CHARS / 9))]) {
    assert.equal((await f.client.fetchGet(value, context(), 100)).status, 'invalid', value.slice(0, 70));
  }
  assert.equal(f.created.length, 0); assert.equal(f.timers.size, 0);
});

test('SDK URL rejection and invalid timeouts remain fixed, local failures', async () => {
  const f = setup({ url: { URL: { parseURL() { throw new Error('signed URL credential secret'); } } } });
  assert.equal((await f.client.fetchGet(origin, context(), 100)).status, 'invalid');
  for (const timeout of [0, -1, 0.5, NaN, Infinity, 300001]) {
    assert.equal((await f.client.fetchGet(origin, context(), timeout)).status, 'invalid');
  }
  assert.equal(f.created.length, 0); assert.equal(f.timers.size, 0);
});

test('invalid context headers and cookies fail before any network IO', async () => {
  const f = setup();
  for (const value of [context(['Bad\nName'], [['x']]), context(['X'], [['bad\r\n']]),
    context([], [], 'cookie\nvalue'), context(['X'], [])]) {
    assert.equal((await f.client.fetchGet(origin, value, 100)).status, 'invalid');
  }
  assert.equal(f.created.length, 0);
});

test('busy is immediate and does not cancel or change the active call', async () => {
  const f = setup(); const first = f.client.fetchGet(origin, context(), 100);
  assert.equal((await f.client.fetchGet('https://other/x', context(), 50)).status, 'busy');
  assert.equal(f.calls.length, 1); assert.equal(f.created[0].destroyed, 0);
  f.created[0].resolve(response()); assert.equal((await first).status, 'ok');
});

test('header context and each SDK dictionary are isolated across relative redirects', async () => {
  const f = setup();
  const names = ['Range', 'Referer', 'X-Token', 'x-token', 'Accept-Encoding', 'Content-Type',
    'Host', 'Content-Length', 'Transfer-Encoding', 'Cookie'];
  const values = [['bytes=1-9'], ['https://site.example/watch'], ['a'], ['b'], ['gzip'], ['text/x'],
    ['captured.example'], ['300'], ['chunked'], ['captured=1']];
  const saved = context(names, values, 'original=1');
  const pending = f.client.fetchGet(origin, saved, 100);
  const headers = f.calls[0].options.header;
  assert.equal(headers['x-token'], 'a, b'); assert.equal(headers.Cookie, 'original=1');
  assert.equal(headers['Accept-Encoding'], 'identity'); assert.equal(headers.Accept, '*/*');
  for (const absent of ['range', 'host', 'content-type', 'content-length', 'transfer-encoding']) {
    assert.equal(Object.keys(headers).some(key => key.toLowerCase() === absent), false);
  }
  names[1] = 'X-Replaced'; values[2][0] = 'caller changed'; saved.cookies = 'caller changed';
  headers['x-token'] = 'SDK changed'; headers.Cookie = 'SDK changed';
  f.created[0].resolve(response('', 302, { location: 'next.m3u8', 'set-cookie': 'response=1' })); await flush();
  const next = f.calls[1].options.header;
  assert.equal(next['x-token'], 'a, b'); assert.equal(next.Cookie, 'original=1');
  assert.equal(next.referer, 'https://site.example/watch');
  f.created[1].resolve(response()); assert.equal((await pending).status, 'ok');
  assert.deepEqual(f.created.map(request => request.destroyed), [1, 1]);
});

test('empty explicit headers keep only identity and default Accept', async () => {
  const f = setup(); const pending = f.client.fetchGet(origin, context([], []), 100);
  assert.deepEqual(plain(f.calls[0].options.header), { 'Accept-Encoding': 'identity', Accept: '*/*' });
  f.created[0].resolve(response()); await pending;
});

test('all five redirects keep GET, count opaque bodies and resolve media relative to final URL', async () => {
  const codes = [301, 302, 303, 307, 308];
  const f = setup({ onRequest(call, index) {
    call.request.resolve(index < codes.length ? response([0xff], codes[index], { Location: '/new/hop' + (index + 1) }) : response());
  } });
  const result = await f.client.fetchGet(origin, context(), 100);
  assert.equal(result.status, 'ok'); assert.equal(f.calls.length, 6); assert.equal(f.decoderCalls, 1);
  assert.equal(result.finalUrl, 'https://origin.example/new/hop5');
  const parsed = parser.parseHlsMediaPlaylist(result.text, result.finalUrl, resolver.resolveHlsUrl);
  assert.equal(parsed.segments[0].url, 'https://origin.example/new/segment.ts?sig=a%2Fb');
  for (let i = 0; i < f.calls.length; i++) {
    assert.equal(f.calls[i].options.method, 'GET'); assert.equal(f.calls[i].options.maxRedirects, 0);
    assert.equal(typeof f.calls[i].options.onProgress, 'function');
  }
});

test('query-only and absolute Locations preserve signed encoding and strip fragments', async () => {
  const locations = ['?sig=b%2F%2b&x=a=b#old', 'https://cdn.example/b/list%2fm.m3u8?key=X%2B#ui'];
  const f = setup({ onRequest(call, index) {
    call.request.resolve(index < locations.length ? response('', 302, { location: locations[index] }) : response());
  } });
  const result = await f.client.fetchGet(origin, context(), 100);
  assert.equal(f.calls[1].url, 'https://origin.example/a/list.m3u8?sig=b%2F%2b&x=a=b');
  assert.equal(result.finalUrl, 'https://cdn.example/b/list%2fm.m3u8?key=X%2B');
});

test('cross-origin credentials are removed permanently while the original Referer stays fixed', async () => {
  const locations = ['https://cdn.example/next', 'https://origin.example/return'];
  const f = setup({ onRequest(call, index) {
    call.request.resolve(index < locations.length ? response('', 302, { location: locations[index] }) : response());
  } });
  const result = await f.client.fetchGet(origin,
    context(['Authorization', 'Proxy-Authorization', 'X-Public'], [['Bearer a'], ['Basic b'], ['kept']], 'session=a'), 100);
  assert.equal(result.status, 'ok'); assert.equal(f.calls[0].options.header.authorization, 'Bearer a');
  assert.equal(f.calls[0].options.header.Cookie, 'session=a');
  for (const call of f.calls.slice(1)) {
    for (const name of ['authorization', 'proxy-authorization', 'cookie']) {
      assert.equal(Object.keys(call.options.header).some(key => key.toLowerCase() === name), false);
    }
    assert.equal(call.options.header['x-public'], 'kept');
  }
  const defaults = setup({ onRequest(call, index) {
    call.request.resolve(index === 0 ? response('', 302, { location: 'https://cdn.example/b/list' }) : response());
  } });
  await defaults.client.fetchGet(origin, context(), 100);
  assert.equal(defaults.calls[1].options.header.referer, 'https://origin.example/a/');
});

test('origin comparison normalizes default ports and treats scheme or port changes as cross-origin', async () => {
  for (const [next, retained] of [['https://origin.example:443/next', true],
    ['https://origin.example:8443/next', false], ['http://origin.example/next', false]]) {
    const f = setup({ onRequest(call, index) {
      call.request.resolve(index === 0 ? response('', 302, { location: next }) : response());
    } });
    assert.equal((await f.client.fetchGet(origin, context(['Authorization'], [['a']], 'c=1'), 100)).status, 'ok');
    assert.equal(f.calls[1].options.header.authorization === 'a', retained);
    assert.equal(f.calls[1].options.header.Cookie === 'c=1', retained);
  }
});

test('Location rejects missing, ambiguous, typed and control-character values without coercion', async () => {
  let coerced = 0;
  const bad = [{}, { location: '' }, { location: ['one', 'two'] }, { location: [] }, { location: [12] },
    { location: 42 }, { location: { toString() { coerced++; return '/evil'; } } },
    { location: '/a', Location: '/b' }, { location: '/a\r\nX: b' }, { location: '/a\tb' },
    { location: '\n/a' }, { location: '/a\0b' }, { location: '/a b' }, { location: 'file:///x' },
    { location: 'https:///repair.example/x' }, { location: 'https://[1::2:]/x' }];
  for (const header of bad) {
    const f = setup({ onRequest(call) { call.request.resolve(response('', 302, header)); } });
    const result = await f.client.fetchGet(origin, context(), 100);
    assert.equal(result.status, 'httpError'); assert.equal(f.calls.length, 1);
  }
  assert.equal(coerced, 0);
});

test('single-value Location arrays allow only perimeter HTTP OWS', async () => {
  const f = setup({ onRequest(call, index) {
    call.request.resolve(index === 0 ? response('', 302, { LOCATION: [' \t../b/list.m3u8\t '] }) : response());
  } });
  const result = await f.client.fetchGet(origin, context(), 100);
  assert.equal(result.status, 'ok'); assert.equal(result.finalUrl, 'https://origin.example/b/list.m3u8');
});

test('Location limits apply to raw values and serialized non-ASCII expansion', async () => {
  for (const location of ['x'.repeat(model.HLS_MAX_URL_CHARS + 1), '中'.repeat(Math.ceil(model.HLS_MAX_URL_CHARS / 9))]) {
    const f = setup({ onRequest(call) { call.request.resolve(response('', 302, { location })); } });
    assert.equal((await f.client.fetchGet(origin, context(), 100)).status, 'httpError');
    assert.equal(f.calls.length, 1);
  }
});

test('normalized redirect loops stop before repeating a request', async () => {
  for (const locations of [['#fragment'], ['/other', origin]]) {
    const f = setup({ onRequest(call, index) { call.request.resolve(response('', 302, { location: locations[index] })); } });
    const result = await f.client.fetchGet(origin, context(), 100);
    assert.equal(result.status, 'httpError'); assert.equal(result.errorCode, 2300047);
    assert.equal(f.calls.length, locations.length);
  }
});

test('30 redirects allow 31 requests and the next redirect is rejected', async () => {
  for (const redirectCount of [30, 31]) {
    const f = setup({ onRequest(call, index) {
      call.request.resolve(index < redirectCount ? response('', 302, { location: '/hop' + (index + 1) }) : response());
    } });
    const result = await f.client.fetchGet(origin, context(), 100);
    assert.equal(result.status, redirectCount === 30 ? 'ok' : 'httpError');
    assert.equal(f.calls.length, 31); assert.equal(f.timers.size, 0);
    if (redirectCount === 31) assert.equal(result.errorCode, 2300047);
  }
});

test('non-followed statuses cannot masquerade as a full manifest', async () => {
  for (const status of [206, 300, 304, 305, 400, 404, 500]) {
    const f = setup({ onRequest(call) { call.request.resolve(response(playlist, status, { location: '/other' })); } });
    const result = await f.client.fetchGet(origin, context(), 100);
    assert.equal(result.status, 'httpError'); assert.equal(result.httpStatus, status);
    assert.equal(result.text, ''); assert.equal(f.calls.length, 1); assert.equal(f.decoderCalls, 0);
  }
});

// RCP Response has no resultType; only the body object type is checked (absent body = empty).
test('wrong SDK body type is rejected without implicit conversion', async () => {
  for (const [body, type] of [['text', ARRAY_BUFFER], [{ text: playlist }, ARRAY_BUFFER],
    [new Uint8Array([65]), ARRAY_BUFFER]]) {
    const f = setup({ onRequest(call) { call.request.resolve({ result: body, resultType: type, responseCode: 200, header: {} }); } });
    assert.equal((await f.client.fetchGet(origin, context(), 100)).status, 'unsupported');
    assert.equal(f.decoderCalls, 0);
  }
});

test('strict UTF-8 accepts BOM and actual U+FFFD and rejects malformed or truncated byte sequences', async () => {
  for (const text of ['\ufeff' + playlist, playlist + '#replacement \ufffd\n', playlist + '#😀中文\n']) {
    const f = setup({ onRequest(call) { call.request.resolve(response(text)); } });
    const result = await f.client.fetchGet(origin, context(), 100);
    assert.equal(result.status, 'ok'); assert.equal(result.text.replace(/^\ufeff/, ''), text.replace(/^\ufeff/, ''));
  }
  for (const body of [[0xff], [0xc3], [0xc0, 0xaf], [0xed, 0xa0, 0x80], [0xf4, 0x90, 0x80, 0x80], [0xff, 0xfe, 65, 0]]) {
    const f = setup({ onRequest(call) { call.request.resolve(response(body)); } });
    assert.equal((await f.client.fetchGet(origin, context(), 100)).status, 'invalidUtf8');
  }
});

test('final UTF-16 character bound permits exact ASCII and multi-byte limits', async () => {
  for (const [text, expected] of [['a'.repeat(parser.HLS_MAX_MANIFEST_CHARS), 'ok'],
    ['中'.repeat(parser.HLS_MAX_MANIFEST_CHARS), 'ok'], ['😀'.repeat(parser.HLS_MAX_MANIFEST_CHARS / 2), 'ok'],
    ['a'.repeat(parser.HLS_MAX_MANIFEST_CHARS + 1), 'tooLarge']]) {
    const f = setup({ onRequest(call) { call.request.resolve(response(text)); } });
    assert.equal((await f.client.fetchGet(origin, context(), 100)).status, expected);
  }
});

test('byte limit is cumulative over redirects and zero remaining never enters the SDK', async () => {
  const f = setup(); const finalBytes = Buffer.byteLength(playlist);
  const pending = f.client.fetchGet(origin, context(), 100);
  f.created[0].resolve(response(new ArrayBuffer(f.exports.MANIFEST_MAX_BYTES - finalBytes), 302, { location: '/next' })); await flush();
  // RCP has no maxLimit: the hop's progress bound is the remaining cumulative budget.
  f.calls[1].options.onProgress(0, finalBytes); assert.equal(f.created[1].destroyed, 0);
  f.created[1].resolve(response()); assert.equal((await pending).status, 'ok');
  const over = setup(); const overPending = over.client.fetchGet(origin, context(), 100);
  over.created[0].resolve(response(new ArrayBuffer(over.exports.MANIFEST_MAX_BYTES - finalBytes), 302, { location: '/next' })); await flush();
  over.calls[1].options.onProgress(0, finalBytes + 1);
  const overResult = await overPending;
  assert.equal(overResult.status, 'tooLarge'); assert.equal(overResult.errorCode, 2300063);
  assert.equal(over.created[1].destroyed, 1); assert.equal(over.decoderCalls, 0);
  for (const extra of [0, 1]) {
    const g = setup(); const active = g.client.fetchGet(origin, context(), 100);
    g.created[0].resolve(response(new ArrayBuffer(g.exports.MANIFEST_MAX_BYTES + extra), 302, { location: '/next' }));
    assert.equal((await active).status, 'tooLarge'); assert.equal(g.calls.length, 1); assert.equal(g.decoderCalls, 0);
  }
});

test('an oversized final SDK buffer is rejected before UTF-8 decoding', async () => {
  const f = setup(); const pending = f.client.fetchGet(origin, context(), 100);
  f.created[0].resolve(response(new ArrayBuffer(f.exports.MANIFEST_MAX_BYTES + 1)));
  assert.equal((await pending).status, 'tooLarge'); assert.equal(f.decoderCalls, 0);
});

test('numeric SDK errors survive while raw SDK exception text is discarded', async () => {
  for (const error of [{ code: 2300007, message: 'credential private trace' }, { code: 2300018 },
    { code: 2300063 }, 'private primitive', null]) {
    const f = setup(); const pending = f.client.fetchGet(origin, context(), 100);
    f.created[0].reject(error); const result = await pending;
    assert.equal(result.status, error?.code === 2300063 ? 'tooLarge' : 'networkError');
    assert.equal(result.errorCode, error?.code || 0);
    assert.equal(JSON.stringify(result).includes('private'), false);
    assert.equal(f.created[0].destroyed, 1); assert.equal(f.timers.size, 0);
  }
});

test('synchronous create/request failures still release the call and its timer', async () => {
  for (const settings of [{ createError: { code: 42 } }, { requestError: { code: 43 } }]) {
    const f = setup(settings); const result = await f.client.fetchGet(origin, context(), 100);
    assert.equal(result.status, 'networkError'); assert.equal(result.errorCode, settings.createError?.code || 43);
    assert.equal(f.timers.size, 0); for (const request of f.created) assert.equal(request.destroyed, 1);
    assert.notEqual((await f.client.fetchGet(origin, context(), 100)).status, 'busy');
  }
});

test('cancel releases a never-settling request and permits immediate same-instance reuse', async () => {
  const f = setup(); const first = f.client.fetchGet(origin, context(), 100);
  f.client.cancel(); f.client.cancel();
  const second = f.client.fetchGet('https://second.example/new', context(), 200);
  assert.equal(f.calls.length, 2); assert.equal((await first).status, 'cancelled');
  assert.equal(f.created[0].destroyed, 1); assert.equal(f.created[1].destroyed, 0); assert.equal(f.timers.size, 1);
  f.created[1].resolve(response()); assert.equal((await second).status, 'ok'); assert.equal(f.timers.size, 0);
});

test('late old success, redirect, rejection and timeout cannot mutate or destroy a reused call', async () => {
  for (const oldCompletion of ['success', 'redirect', 'rejection']) {
    const f = setup(); const first = f.client.fetchGet(origin, context(), 100);
    const oldTimer = [...f.timers.values()][0].callback;
    f.client.cancel(); const second = f.client.fetchGet('https://second.example/new', context(), 200);
    await first;
    if (oldCompletion === 'rejection') f.created[0].reject({ code: 2300007 });
    else f.created[0].resolve(response('', oldCompletion === 'redirect' ? 302 : 200, { location: '/old-next' }));
    oldTimer(); await flush();
    assert.equal(f.calls.length, 2); assert.equal(f.created[1].destroyed, 0); assert.equal(f.timers.size, 1);
    f.created[1].resolve(response()); assert.equal((await second).status, 'ok');
  }
});

test('cancel before a resolved response continuation prevents success or a new hop', async () => {
  const f = setup(); const pending = f.client.fetchGet(origin, context(), 100);
  f.created[0].resolve(response('', 302, { location: '/next' })); f.client.cancel();
  assert.equal((await pending).status, 'cancelled'); assert.equal(f.calls.length, 1); assert.equal(f.created[0].destroyed, 1);
});

test('one total deadline spans all hops and terminates an uncooperative SDK promise', async () => {
  const f = setup(); const pending = f.client.fetchGet(origin, context(), 100);
  await f.advance(60); f.created[0].resolve(response('', 302, { location: '/next' })); await flush();
  assert.equal(f.calls[1].options.connectTimeout, 40); assert.equal(f.calls[1].options.readTimeout, 40);
  await f.advance(40); const result = await pending;
  assert.equal(result.status, 'networkError'); assert.equal(result.errorCode, 2300028);
  assert.deepEqual(f.created.map(request => request.destroyed), [1, 1]); assert.equal(f.timers.size, 0);
});

test('deadline is rechecked after await even before a delayed timer callback executes', async () => {
  const f = setup(); const pending = f.client.fetchGet(origin, context(), 100);
  f.jump(101); f.created[0].resolve(response('', 302, { location: '/next' }));
  const result = await pending;
  assert.equal(result.status, 'networkError'); assert.equal(result.errorCode, 2300028); assert.equal(f.calls.length, 1);
});

test('clock rollback cannot enlarge SDK per-hop timeout beyond the supplied bound', async () => {
  const f = setup(); const pending = f.client.fetchGet(origin, context(), 100);
  f.jump(-1000); f.created[0].resolve(response('', 302, { location: '/next' })); await flush();
  assert.equal(f.calls[1].options.readTimeout, 100);
  f.client.cancel(); assert.equal((await pending).status, 'cancelled');
});

test('destroy exceptions cannot turn completed success into failure or block cancel reuse', async () => {
  const f = setup({ destroyError: new Error('private cleanup') });
  const successful = f.client.fetchGet(origin, context(), 100); f.created[0].resolve(response());
  assert.equal((await successful).status, 'ok'); assert.equal(f.created[0].destroyed, 1); assert.equal(f.timers.size, 0);
  const cancelled = f.client.fetchGet(origin, context(), 100); f.client.cancel();
  const next = f.client.fetchGet(origin, context(), 100);
  assert.equal((await cancelled).status, 'cancelled'); assert.equal(f.created[2].destroyed, 0);
  f.created[2].resolve(response()); assert.equal((await next).status, 'ok');
});
