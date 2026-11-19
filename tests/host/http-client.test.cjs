'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadProduction } = require('./production-loader.cjs');
const source = path.resolve(__dirname, '../../entry/src/main/ets/core/net/HttpClient.ets');
const flush = async () => { for (let i = 0; i < 12; i++) await Promise.resolve(); };

function setup() {
  let now = 0, next = 1, resolveStatus, rejectStatus;
  const timers = new Map(), handlers = new Map();
  const status = new Promise((resolve, reject) => { resolveStatus = resolve; rejectStatus = reject; });
  const req = {
    destroyed: 0,
    on(name, callback) { handlers.set(name, callback); },
    off(name) { handlers.delete(name); },
    destroy() { this.destroyed++; },
    requestInStream() { return status; }
  };
  const exports = loadProduction(source, {
    '@kit.NetworkKit': { http: { createHttp: () => req } },
    '@kit.BasicServicesKit': {}, '@kit.PerformanceAnalysisKit': { hilog: { error() {} } },
    '../Config': { Config: { getInstance: () => ({ getNetworkTimeout: () => 30 }) } }
  }, {
    setTimeout(callback, delay) { const id = next++; timers.set(id, { at: now + delay, callback }); return id; },
    clearTimeout(id) { timers.delete(id); }
  });
  return {
    client: new exports.HttpClient(), req, timers, resolveStatus, rejectStatus,
    emit(name, value) { const cb = handlers.get(name); if (cb) cb(value); },
    callback(name) { return handlers.get(name); },
    async advance(ms) {
      const until = now + ms;
      while (true) {
        const item = [...timers].filter(([, v]) => v.at <= until).sort((a, b) => a[1].at - b[1].at)[0];
        if (!item) break;
        now = item[1].at; timers.delete(item[0]); item[1].callback(); await flush();
      }
      now = until; await flush();
    }
  };
}

test('receive-idle expiry releases pending open, closes transport and reports timeout', async () => {
  const f = setup(); let head;
  f.client.open('http://test/idle', {}).then(value => { head = value; });
  await f.advance(15000);
  assert.ok(head, 'open must not remain pending after idle expiry');
  assert.equal(head.status, 0); assert.equal(head.errCode, 2300028);
  assert.equal(await f.client.waitStreamEnd(), false);
  assert.equal(f.req.destroyed, 1); assert.equal(f.timers.size, 0);
});

test('user abort releases pending open with cancellation rather than timeout', async () => {
  const f = setup(); const pending = f.client.open('http://test/cancel', {});
  f.client.abort(); f.client.abort();
  const head = await pending;
  assert.equal(head.status, 0); assert.equal(head.errCode, 0);
  assert.equal(await f.client.waitStreamEnd(), false);
  assert.equal(f.req.destroyed, 1); assert.equal(f.timers.size, 0);
});

test('new chunks reset receive-idle deadline; eventual inactivity still terminates', async () => {
  const f = setup(); let head;
  f.client.open('http://test/active', {}).then(value => { head = value; });
  await f.advance(14000); f.emit('dataReceive', new ArrayBuffer(1));
  await f.advance(14000); assert.equal(head, undefined);
  await f.advance(1000); assert.equal(head.errCode, 2300028);
});

test('headers without Content-Range never fabricate a status code', async () => {
  const f = setup(); let head, chunks = 0;
  f.client.onChunk = () => { chunks++; };
  f.client.open('http://test/late-status', {}).then(value => { head = value; });
  f.emit('headersReceive', { 'content-type': 'text/html' });
  f.emit('dataReceive', new ArrayBuffer(1)); f.emit('dataEnd'); await flush();
  assert.equal(head, undefined); assert.equal(chunks, 1);
  assert.equal(await f.client.waitStreamEnd(), true);
  f.resolveStatus(404); await flush();
  assert.equal(head.status, 404); assert.equal(head.header['content-type'], 'text/html');
  f.client.abort(); assert.equal(f.timers.size, 0);
});

// Device fact (2026-10-18, P2-U2 instrumentation): headers and first chunk arrive within ms of
// connecting, while the requestInStream status settles only when the whole stream ends.
test('Content-Range head resolves open as provisional 206 before the stream ends', async () => {
  const f = setup(); let head, chunks = 0;
  f.client.onChunk = () => { chunks++; };
  f.client.open('http://test/range', {}).then(value => { head = value; });
  f.emit('headersReceive', { 'Content-Range': 'bytes 0-4194303/4194304' }); await flush();
  assert.equal(head.status, 206); assert.equal(head.errCode, 0);
  f.emit('dataReceive', new ArrayBuffer(1)); assert.equal(chunks, 1);
  f.emit('dataEnd'); f.resolveStatus(206); await flush();
  assert.equal(await f.client.waitStreamEnd(), true); assert.equal(f.req.destroyed, 0);
});

test('final status contradicting provisional 206 aborts the stream', async () => {
  const f = setup();
  const pending = f.client.open('http://test/contradict', {});
  f.emit('headersReceive', { 'content-range': 'bytes 0-9/10' });
  assert.equal((await pending).status, 206);
  f.resolveStatus(200); await flush();
  assert.equal(await f.client.waitStreamEnd(), false); assert.equal(f.req.destroyed, 1);
});

test('transport failure after provisional head closes the end gate', async () => {
  const f = setup();
  const pending = f.client.open('http://test/mid-fail', {});
  f.emit('headersReceive', { 'content-range': 'bytes 0-9/10' });
  assert.equal((await pending).status, 206);
  f.rejectStatus({ code: 2300056, message: 'reset' }); await flush();
  assert.equal(await f.client.waitStreamEnd(), false); assert.equal(f.req.destroyed, 1);
});

test('unsatisfied-range and redirect heads are not treated as 206', async () => {
  const f = setup(); let head;
  f.client.open('http://test/416', {}).then(value => { head = value; });
  f.emit('headersReceive', { 'content-range': 'bytes */10' });
  f.emit('headersReceive', { 'location': '/x', 'content-range': 'bytes 0-9/10' }); await flush();
  assert.equal(head, undefined);
  f.resolveStatus(416); await flush(); assert.equal(head.status, 416);
});

test('final-hop head lifts the status deadline; a long slow body is bounded only by idle', async () => {
  const f = setup(); let head;
  f.client.open('http://test/slow-200', {}).then(value => { head = value; });
  f.emit('headersReceive', { 'content-length': '10' });
  for (let i = 0; i < 6; i++) { await f.advance(9000); f.emit('dataReceive', new ArrayBuffer(1)); }
  assert.equal(head, undefined); assert.equal(f.req.destroyed, 0);
  f.emit('dataEnd'); f.resolveStatus(200); await flush();
  assert.equal(head.status, 200); assert.equal(await f.client.waitStreamEnd(), true);
});

test('readTimeout is not used as a whole-transfer cap', async () => {
  const f = setup(); let options;
  f.req.requestInStream = (_url, value) => { options = value; return new Promise(() => {}); };
  f.client.open('http://test/options', {}); await flush();
  assert.equal(options.connectTimeout, 30000);
  assert.ok(options.readTimeout >= 86400000);
  f.client.abort();
});

test('transport rejection closes end gate immediately, preserving original error', async () => {
  const f = setup(); const pending = f.client.open('http://test/error', {});
  f.rejectStatus({ code: 2300007, message: 'refused' });
  const head = await pending;
  assert.equal(head.errCode, 2300007); assert.equal(head.status, 0);
  assert.equal(await f.client.waitStreamEnd(), false); assert.equal(f.timers.size, 0);
});

test('late callbacks after end cannot rearm timer; late callbacks after abort deliver no body', async () => {
  const f = setup(); let chunks = 0;
  f.client.onChunk = () => { chunks++; };
  const pending = f.client.open('http://test/late-events', {});
  f.resolveStatus(200); await pending;
  f.emit('dataEnd'); f.emit('dataReceive', new ArrayBuffer(1));
  assert.equal(f.timers.size, 0); assert.equal(chunks, 0);
  const queued = f.callback('dataReceive');
  f.client.abort(); const before = chunks;
  queued(new ArrayBuffer(1)); assert.equal(chunks, before);
});

test('completed head and body leave no later timeout to abort a successful response', async () => {
  const f = setup(); const pending = f.client.open('http://test/complete', {});
  f.emit('dataEnd'); f.resolveStatus(200); assert.equal((await pending).status, 200);
  assert.equal(await f.client.waitStreamEnd(), true);
  await f.advance(60000); assert.equal(f.req.destroyed, 0); assert.equal(f.timers.size, 0);
});

test('abort after successful headers releases pending stream end', async () => {
  const f = setup(); const pending = f.client.open('http://test/body-cancel', {});
  f.resolveStatus(200); assert.equal((await pending).status, 200);
  f.client.abort(); assert.equal(await f.client.waitStreamEnd(), false);
});

test('dataEnd cannot remove status deadline when status never settles', async () => {
  const f = setup(); let head;
  f.client.open('http://test/missing-status', {}).then(value => { head = value; });
  f.emit('dataEnd'); await f.advance(30000);
  assert.ok(head, 'status acquisition remains bounded after dataEnd');
  assert.equal(head.status, 0); assert.equal(head.errCode, 2300028);
  assert.equal(f.req.destroyed, 1); assert.equal(f.timers.size, 0);
});

test('continuous data cannot indefinitely strand status acquisition', async () => {
  const f = setup(); let head;
  f.client.open('http://test/missing-status-active-body', {}).then(value => { head = value; });
  for (let i = 0; i < 3; i++) { await f.advance(9000); f.emit('dataReceive', new ArrayBuffer(1)); }
  assert.equal(head, undefined);
  await f.advance(3000); assert.equal(head.errCode, 2300028);
  assert.equal(f.timers.size, 0);
});
