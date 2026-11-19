'use strict';
// Actual production ManifestClient/parser/context/resolver over real loopback HTTP.
// Only Harmony SDK boundaries are adapted to Node; this is not Harmony runtime evidence.
const assert = require('node:assert/strict');
const http = require('node:http');
const path = require('node:path');
const { performance } = require('node:perf_hooks');
const { test } = require('node:test');
const { loadProduction } = require('./production-loader.cjs');
const { rcpOverHttp } = require('./rcp-http-adapter.cjs');
const { createProbeServer } = require('../../docs/probe/P6-U4-manifest-host.cjs');

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
const TEST_TIMEOUT = { timeout: 15000 };

function probeContext() {
  const value = new contexts.DownloadRequestContext();
  value.headers = {
    names: ['Referer', 'X-Probe', 'x-probe', 'Range', 'Accept-Encoding', 'Cookie'],
    values: [['https://probe.invalid/page'], ['one'], ['two'], ['bytes=20-30'], ['gzip'], ['unused=1']]
  };
  value.cookies = 'probe=adaptive';
  return value;
}

function fixedError(code) {
  const error = new Error('Node HTTP adapter failure');
  error.code = code;
  return error;
}

function nodeHttpAdapter() {
  const records = [];
  const live = new Set();
  return {
    records, live,
    api: {
      RequestMethod: { GET: 'GET' }, HttpDataType: { ARRAY_BUFFER },
      createHttp() {
        let outgoing, incoming, rejectPending;
        let settled = false;
        const record = { url: '', destroyCalls: 0, bytes: 0, responseSeen: false,
          limitExceeded: false, closed: Promise.resolve() };
        records.push(record);
        const fail = code => {
          if (!settled && rejectPending) { settled = true; rejectPending(fixedError(code)); }
          incoming?.destroy();
          outgoing?.destroy();
        };
        return {
          request(input, options) {
            assert.equal(outgoing, undefined, 'one Node request per SDK HttpRequest');
            assert.equal(options.method, 'GET');
            assert.equal(options.maxRedirects, 0, 'Node adapter must not follow redirects');
            assert.equal(options.expectDataType, ARRAY_BUFFER);
            assert.equal(options.usingCache, false);
            assert.equal(typeof options.onProgress, 'function', 'RCP body bound is reported through download progress');
            record.url = input;
            return new Promise((resolve, reject) => {
              rejectPending = reject;
              outgoing = http.request(input, { method: options.method, headers: options.header, agent: false }, res => {
                incoming = res;
                record.responseSeen = true;
                record.httpStatus = res.statusCode;
                const chunks = [];
                res.on('data', chunk => {
                  if (settled) return;
                  record.bytes += chunk.length;
                  // Emulate RCP onDownloadProgress; D cancels the session once its budget is passed.
                  options.onProgress(0, record.bytes);
                  if (settled) { record.limitExceeded = true; return; }
                  chunks.push(chunk);
                });
                res.once('end', () => {
                  if (settled) return;
                  settled = true;
                  const body = Buffer.concat(chunks, record.bytes);
                  resolve({ responseCode: res.statusCode, header: res.headers, cookies: '',
                    resultType: ARRAY_BUFFER,
                    result: body.buffer.slice(body.byteOffset, body.byteOffset + body.byteLength) });
                });
                res.once('aborted', () => fail(0));
                res.once('error', () => fail(0));
              });
              const owned = outgoing;
              live.add(owned);
              record.closed = new Promise(done => owned.once('close', () => { live.delete(owned); done(); }));
              owned.once('error', () => fail(0));
              // No Node inactivity timeout: the actual D deadline controls the timeout test.
              owned.end();
            });
          },
          destroy() {
            record.destroyCalls++;
            fail(0);
          }
        };
      }
    }
  };
}

async function fixture(t) {
  const server = createProbeServer();
  assert.equal(server.listening, false, 'import/factory must not choose a listening interface');
  const adapter = nodeHttpAdapter();
  const timers = new Map();
  const pending = [];
  let nextTimer = 1;
  const exported = loadProduction(adaptive('ManifestClient'), {
    '@kit.RemoteCommunicationKit': { rcp: rcpOverHttp(adapter.api) }, '@kit.BasicServicesKit': {},
    '@kit.ArkTS': { url: platformUrl, util: { TextDecoder: { create(encoding, options) {
      const decoder = new TextDecoder(encoding, options);
      return { decodeToString: (input, decodeOptions) => decoder.decode(input, decodeOptions) };
    } } } },
    '../../model/DownloadRequestContext': contexts,
    './HlsModel': model, './HlsParser': parser, './AdaptivePlan': plan, './HlsUrlResolver': resolver
  }, {
    setTimeout(callback, delay) {
      const id = nextTimer++;
      const timer = setTimeout(() => { timers.delete(id); callback(); }, delay);
      timers.set(id, timer);
      return id;
    },
    clearTimeout(id) {
      const timer = timers.get(id);
      if (timer !== undefined) { clearTimeout(timer); timers.delete(id); }
    }
  });
  const client = new exported.ManifestClient();
  t.after(async () => {
    client.cancel();
    await Promise.allSettled(pending);
    const leakedTimers = timers.size;
    for (const timer of timers.values()) clearTimeout(timer);
    timers.clear();
    for (const request of adapter.live) request.destroy();
    if (server.listening) {
      await new Promise((resolve, reject) => {
        server.close(error => error ? reject(error) : resolve());
        server.closeAllConnections();
      });
    }
    await Promise.all(adapter.records.map(record => record.closed));
    assert.equal(leakedTimers, 0, 'production must release its deadline timers');
    assert.equal(adapter.live.size, 0);
    for (const record of adapter.records) assert.equal(record.destroyCalls, 1, 'destroy each owned SDK request once');
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => { server.off('error', reject); resolve(); });
  });
  const base = 'http://127.0.0.1:' + server.address().port;
  return { server, base, client, adapter, timers, exported,
    fetch(route, timeoutMs = 5000, context = probeContext()) {
      const promise = client.fetchGet(base + route, context, timeoutMs);
      pending.push(promise);
      return promise;
    }
  };
}

function checkManifest(result, directory) {
  assert.equal(result.status, 'ok');
  assert.equal(result.httpStatus, 200);
  assert.equal(result.errorCode, 0);
  const lines = result.text.split('\n');
  for (const line of ['#PROBE-UNICODE:中文', '#PROBE-COOKIE:1', '#PROBE-REFERER:1',
    '#PROBE-MULTI:1', '#PROBE-IDENTITY:1', '#PROBE-RANGE:1']) assert.ok(lines.includes(line), line);
  const parsed = parser.parseHlsMediaPlaylist(result.text, result.finalUrl, resolver.resolveHlsUrl);
  assert.ok(parsed);
  assert.equal(parsed.segments.length, 1);
  assert.equal(parsed.segments[0].url, directory + '/segment.ts?sig=a%2Fb');
}

function observeRequest(server, route) {
  return new Promise(resolve => {
    const listener = (req, res) => {
      if (req.url !== route) return;
      server.off('request', listener);
      resolve({ res, closed: new Promise(done => res.once('close', done)) });
    };
    server.on('request', listener);
  });
}

function rawRequest(base, route, { headers = {}, method = 'GET', collect = true } = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request(base + route, { method, headers, agent: false }, res => {
      let count = 0;
      const chunks = [];
      res.on('data', chunk => { count += chunk.length; if (collect) chunks.push(chunk); });
      res.once('end', () => resolve({ status: res.statusCode, headers: res.headers, bytes: count,
        body: collect ? Buffer.concat(chunks, count).toString('utf8') : '' }));
      res.once('aborted', () => reject(new Error('Raw fixture response aborted')));
      res.once('error', reject);
    });
    req.once('error', reject);
    req.setTimeout(5000, () => req.destroy(new Error('Raw fixture timeout')));
    req.end();
  });
}

test('real wire direct GET retains synthetic context, Unicode and relative segment resolution', TEST_TIMEOUT, async t => {
  const f = await fixture(t);
  const result = await f.fetch('/direct/list.m3u8#display');
  checkManifest(result, f.base + '/direct');
  assert.equal(result.requestedUrl, f.base + '/direct/list.m3u8#display');
  assert.equal(result.finalUrl, f.base + '/direct/list.m3u8');
  assert.equal(f.adapter.records.length, 1);
  assert.equal(f.adapter.records[0].url, result.finalUrl);
});

test('real 302 crosses directories, preserves signed query bytes and strips Location fragment', TEST_TIMEOUT, async t => {
  const f = await fixture(t);
  const result = await f.fetch('/redirect/start');
  checkManifest(result, f.base + '/final');
  assert.equal(result.finalUrl, f.base + '/final/list.m3u8?sig=a%2Fb');
  assert.deepEqual(f.adapter.records.map(record => record.url), [
    f.base + '/redirect/start', f.base + '/final/list.m3u8?sig=a%2Fb'
  ]);
  assert.deepEqual(f.adapter.records.map(record => record.httpStatus), [302, 200]);
});

test('actual malformed response bytes yield invalidUtf8 with no accepted text', TEST_TIMEOUT, async t => {
  const f = await fixture(t);
  const result = await f.fetch('/invalid-utf8');
  assert.equal(result.status, 'invalidUtf8');
  assert.equal(result.httpStatus, 200);
  assert.equal(result.errorCode, 0);
  assert.equal(result.text, '');
  assert.equal(f.adapter.records[0].bytes, 10);
});

test('fixed 8 MiB plus one source obeys backpressure and reaches the SDK limit boundary', TEST_TIMEOUT, async t => {
  const f = await fixture(t);
  let backpressure = 0;
  const observeWrites = (req, res) => {
    if (!req.url.startsWith('/too-large')) return;
    const write = res.write;
    res.write = function (...args) {
      const accepted = write.apply(this, args);
      if (!accepted) backpressure++;
      return accepted;
    };
  };
  f.server.prependListener('request', observeWrites);
  const raw = await rawRequest(f.base, '/too-large?size=1&url=https://ignored.invalid/', { collect: false });
  assert.equal(raw.status, 200);
  assert.equal(raw.bytes, 8 * 1024 * 1024 + 1);
  assert.equal(Number(raw.headers['content-length']), raw.bytes);
  assert.ok(raw.headers['content-type'].startsWith('application/vnd.apple.mpegurl'));
  assert.ok(backpressure > 0, 'real ServerResponse.write returned false and streaming resumed');
  const result = await f.fetch('/too-large');
  assert.equal(result.status, 'tooLarge');
  assert.equal(result.errorCode, 2300063);
  assert.equal(result.text, '');
  assert.ok(f.adapter.records[0].bytes > f.exported.MANIFEST_MAX_BYTES);
  assert.equal(f.adapter.records[0].limitExceeded, true);
});

test('fixed and unknown routes produce real 404 responses without accepting their bodies', TEST_TIMEOUT, async t => {
  const f = await fixture(t);
  for (const route of ['/not-found', '/arbitrary/file?path=C:/private&url=https://ignored.invalid/']) {
    const result = await f.fetch(route);
    assert.equal(result.status, 'httpError');
    assert.equal(result.httpStatus, 404);
    assert.equal(result.errorCode, 0);
    assert.equal(result.text, '');
  }
});

test('finite slow route returns its real manifest when the deadline permits it', TEST_TIMEOUT, async t => {
  const f = await fixture(t);
  const started = performance.now();
  const result = await f.fetch('/slow');
  checkManifest(result, f.base);
  t.diagnostic(JSON.stringify({ route: 'slow', elapsedMs: Math.round(performance.now() - started),
    scope: 'host wire observation, not Harmony timing' }));
});

test('production total deadline stops a real pending response and allows subsequent reuse', TEST_TIMEOUT, async t => {
  const f = await fixture(t);
  const seen = observeRequest(f.server, '/slow');
  const pending = f.fetch('/slow', 250);
  const source = await seen;
  const result = await pending;
  assert.equal(result.status, 'networkError');
  assert.equal(result.errorCode, 2300028);
  assert.equal(result.text, '');
  assert.equal(f.adapter.records[0].responseSeen, false, 'source had not started its delayed response');
  await source.closed;
  assert.equal(f.timers.size, 0);
  checkManifest(await f.fetch('/direct/list.m3u8'), f.base + '/direct');
});

test('cancel after request arrival releases the socket and immediate reuse survives old cleanup', TEST_TIMEOUT, async t => {
  const f = await fixture(t);
  const seen = observeRequest(f.server, '/slow');
  const previous = f.fetch('/slow');
  const source = await seen;
  f.client.cancel();
  // Deliberately start the new operation before awaiting the cancelled one.
  const current = f.fetch('/direct/list.m3u8');
  const cancelled = await previous;
  assert.equal(cancelled.status, 'cancelled');
  assert.equal(cancelled.errorCode, 0);
  assert.equal(cancelled.text, '');
  checkManifest(await current, f.base + '/direct');
  await source.closed;
  assert.equal(f.adapter.records.length, 2);
  assert.deepEqual(f.adapter.records.map(record => record.destroyCalls), [1, 1]);
  assert.equal(f.timers.size, 0);
});

test('fixture only emits boolean header flags and fixed method errors', TEST_TIMEOUT, async t => {
  const f = await fixture(t);
  const raw = await rawRequest(f.base, '/direct/list.m3u8', { headers: {
    Cookie: 'private=cookie', Referer: 'https://secret.invalid/private', 'X-Probe': 'private-header',
    'Accept-Encoding': 'gzip', Range: 'bytes=0-99'
  } });
  assert.equal(raw.status, 200);
  assert.equal(Number(raw.headers['content-length']), Buffer.byteLength(raw.body));
  for (const field of ['COOKIE', 'REFERER', 'MULTI', 'IDENTITY', 'RANGE']) {
    assert.ok(raw.body.split('\n').includes('#PROBE-' + field + ':0'));
  }
  for (const secret of ['private=cookie', 'secret.invalid', 'private-header', 'bytes=0-99']) {
    assert.equal(raw.body.includes(secret), false);
  }
  const post = await rawRequest(f.base, '/direct/list.m3u8', { method: 'POST' });
  assert.equal(post.status, 405);
  assert.equal(post.headers.allow, 'GET');
  assert.equal(post.body, 'GET required\n');
});
