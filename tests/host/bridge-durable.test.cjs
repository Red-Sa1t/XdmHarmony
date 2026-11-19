'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const crypto = require('node:crypto');
const { loadProduction } = require('./production-loader.cjs');
const root = path.resolve(__dirname, '../../entry/src/main/ets');
const flush = async () => { for (let i = 0; i < 20; i++) await Promise.resolve(); };
function deferred() { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; }

function setup(auto = false, extraModules = []) {
  const gate = deferred(), refreshGate = deferred(), calls = [], refreshCalls = [], pending = [], cache = new Map();
  const config = { getDownloadDir: () => '/downloads', getStartDownloadAutomatically: () => auto,
    broadcastConfigChange() {}, getMinVideoSize: () => 1024, getIsBrowserMonitoringEnabled: () => true,
    getFileExtensions: () => [], getBlockedHosts: () => [], getVideoExtensions: () => [] };
  const service = { create: async request => { calls.push({ kind: 'create', request }); await gate.promise; return { id: 'created' }; } };
  const inbox = { enqueue: async item => { calls.push({ kind: 'inbox', item }); await gate.promise; pending.push(item); return item; }, getPending: () => pending };
  let refreshBehavior = async (id, url, context) => {
    await refreshGate.promise;
    return { url, context, revision: refreshCalls.length };
  };
  const store = { async refreshCommittedRequest(id, url, context) {
    refreshCalls.push({ id, url, context });
    return await refreshBehavior(id, url, context);
  } };
  const modules = new Map([
    [path.join(root, 'core/Config.ets'), { Config: { getInstance: () => config } }],
    [path.join(root, 'core/engine/DownloadCreationService.ets'), { DownloadCreationService: { getInstance: () => service } }],
    [path.join(root, 'core/db/DownloadStore.ets'), { DownloadStore: { getInstance: () => store } }],
    [path.join(root, 'core/bridge/BridgeInbox.ets'), { BridgeInbox: { getInstance: () => inbox } }],
    ...extraModules.map(([file, value]) => [path.join(root, file), value])
  ]);
  const kits = { '@kit.ArkTS': { util: { generateRandomUUID: () => crypto.randomUUID() },
    url: { URL: { parseURL: (reference, base) => new URL(reference, base) } } },
    '@kit.PerformanceAnalysisKit': { hilog: { info() {}, error() {} } }, '@kit.BasicServicesKit': {}, '@kit.NetworkKit': { socket: {} },
    '@kit.RemoteCommunicationKit': { rcp: {} } };
  function load(file) {
    if (modules.has(file)) return modules.get(file);
    if (cache.has(file)) return cache.get(file);
    const imports = {};
    for (const m of fs.readFileSync(file, 'utf8').matchAll(/import[\s\S]*?from\s+'([^']+)'/g)) {
      const name = m[1];
      Object.defineProperty(imports, name, { enumerable: true, configurable: true, get: () => {
        if (Object.hasOwn(kits, name)) return kits[name];
        if (!name.startsWith('.')) throw new Error('Unmocked kit ' + name);
        return load(path.resolve(path.dirname(file), name + '.ets'));
      } });
    }
    const exports = loadProduction(file, imports, { Observed: value => value },
      file.endsWith('BridgeServer.ets') ? ['ClientSession'] : []);
    cache.set(file, exports); return exports;
  }
  const routes = load(path.join(root, 'core/bridge/BridgeRoutes.ets'));
  const actions = load(path.join(root, 'core/bridge/BridgeActions.ets'));
  const tracker = load(path.join(root, 'core/bridge/CapturedVideoTracker.ets')).CapturedVideoTracker.getInstance();
  const protocol = load(path.join(root, 'core/bridge/BridgeProtocol.ets'));
  const server = load(path.join(root, 'core/bridge/BridgeServer.ets'));
  const refresherModule = load(path.join(root, 'core/bridge/LinkRefresher.ets'));
  const refresher = refresherModule.LinkRefresher.getInstance();
  const recordModule = load(path.join(root, 'model/DownloadRecord.ets'));
  const requestModule = load(path.join(root, 'model/DownloadCreationRequest.ets'));
  function record(id = 'existing', size = 12, status = 1) {
    const target = new recordModule.DownloadRecord();
    target.id = id; target.size = size; target.status = status; target.downloadType = 'Http';
    target.primaryUrl = 'https://old/expired'; target.name = 'original.bin';
    return target;
  }
  function request(url = 'https://host/new', size = 12) {
    const input = new requestModule.DownloadCreationRequest();
    input.url = url; input.contextUrl = url; input.size = size;
    input.requestContext.cookies = 'fresh=1';
    input.requestContext.headers = { names: ['Referer'], values: [['https://origin/fresh']] };
    return input;
  }
  function session(route, body) {
    const sent = []; let closes = 0;
    const conn = { clientId: 1, async send(options) { sent.push(Buffer.from(options.data).toString()); }, async close() { closes++; } };
    const instance = new server.ClientSession(conn, { noteRequest() {} });
    const json = JSON.stringify(body);
    instance.buffer = protocol.utf8Encode('POST ' + route + ' HTTP/1.1\r\nContent-Length: ' + Buffer.byteLength(json) + '\r\n\r\n' + json);
    return { instance, sent, get closes() { return closes; } };
  }
  return { gate, calls, actions, routes, tracker, protocol, session, refresher,
    refreshGate, refreshCalls, record, request, readRefreshContentLength: refresherModule.readRefreshContentLength,
    setRefreshBehavior(behavior) { refreshBehavior = behavior; } };
}
function message(url, cookie = 'sid=private') {
  return { url, file: 'file.bin', cookie, requestHeaders: { Referer: ['https://origin/page'], 'X-Auth': ['token'] }, responseHeaders: { 'Content-Length': ['12'] } };
}

test('automatic response waits for production action service promise', async () => {
  const f = setup(true), s = f.session('/download', message('https://host/file'));
  const drain = s.instance.drain(); await flush();
  assert.equal(f.calls.length, 1); assert.equal(f.calls[0].kind, 'create'); assert.equal(s.sent.length, 0);
  assert.equal(f.calls[0].request.requestContext.cookies, 'sid=private');
  assert.equal(f.calls[0].request.contextUrl, 'https://host/file');
  f.gate.resolve(); await drain;
  assert.equal(s.sent.length, 1); assert.match(s.sent[0], /^HTTP\/1.0 200/);
});

test('automatic persistence rejection closes connection without acknowledging', async () => {
  const f = setup(true), s = f.session('/download', message('https://host/file'));
  const drain = s.instance.drain(); await flush(); f.gate.reject(new Error('write failed')); await drain;
  assert.equal(s.sent.length, 0); assert.equal(s.closes, 1);
});

test('manual response and observation event wait for durable inbox', async () => {
  const f = setup(false), s = f.session('/download', message('https://host/file'));
  let events = 0; f.actions.registerBridgeUiEvents({ onShowNewDownloadDialog() { events++; } });
  const drain = s.instance.drain(); await flush();
  assert.equal(f.calls[0].kind, 'inbox'); assert.equal(events, 0); assert.equal(s.sent.length, 0);
  assert.equal(f.calls[0].item.requests[0].requestContext.cookies, 'sid=private');
  f.gate.resolve(); await drain; assert.equal(events, 1); assert.equal(s.sent.length, 1);
});

test('batch is one durable inbox with per-link credential snapshots', async () => {
  const f = setup(false), s = f.session('/link', [message('https://host/a', 'a=1'), message('https://host/b', 'b=2')]);
  const drain = s.instance.drain(); await flush();
  assert.equal(f.calls.length, 1); const item = f.calls[0].item;
  assert.equal(item.kind, 'batch'); assert.equal(item.requests.length, 2);
  assert.equal(item.requests[0].requestContext.cookies, 'a=1'); assert.equal(item.requests[1].requestContext.cookies, 'b=2');
  assert.equal(s.sent.length, 0); f.gate.resolve(); await drain;
  assert.equal(f.actions.getPendingBatchLinks().length, 2);
});

test('video manual snapshot survives tracker clear and source header mutation before persistence', async () => {
  const f = setup(false), headers = { names: ['Referer'], values: [['https://origin/private']] };
  f.tracker.addSingleSourceVideo('Video.mp4', 12, '', 'https://host/video', headers, 'video=1', '', '1', '');
  const id = f.tracker.getTrackedVideos()[0].id;
  const s = f.session('/vid', { vid: id }), drain = s.instance.drain(); await flush();
  assert.equal(f.calls[0].item.videoKind, 'video');
  f.tracker.clearVideoList(); headers.values[0][0] = 'changed';
  assert.equal(f.calls[0].item.requests[0].requestContext.headers.values[0][0], 'https://origin/private');
  assert.equal(f.calls[0].item.requests[0].requestContext.cookies, 'video=1');
  f.gate.resolve(); await drain; assert.equal(s.sent.length, 1);
});

test('legacy args explicitly swallows awaited persistence rejection while direct route does not', async () => {
  const f = setup(true), s = f.session('/args', ['--url', 'https://host/file']);
  const drain = s.instance.drain(); await flush(); assert.equal(s.sent.length, 0);
  f.gate.reject(new Error('write failed')); await drain;
  assert.equal(s.sent.length, 1); assert.match(s.sent[0], /^HTTP\/1.0 200/);
});

test('manual inbox failure is not acknowledged and does not emit dialog observation', async () => {
  const f = setup(false), s = f.session('/download', message('https://host/file'));
  let events = 0; f.actions.registerBridgeUiEvents({ onShowNewDownloadDialog() { events++; } });
  const drain = s.instance.drain(); await flush(); f.gate.reject(new Error('inbox failed')); await drain;
  assert.equal(events, 0); assert.equal(s.sent.length, 0); assert.equal(s.closes, 1);
});

test('normal auto video retains credentials; adaptive video never falls back to ordinary create', async () => {
  const normal = setup(true);
  normal.tracker.addSingleSourceVideo('Video.mp4', 12, '', 'https://host/video', null, 'video=1', '', '1', '');
  const id = normal.tracker.getTrackedVideos()[0].id;
  const action = normal.tracker.addVideoDownload(id); await flush();
  assert.equal(normal.calls[0].kind, 'create'); assert.equal(normal.calls[0].request.requestContext.cookies, 'video=1');
  normal.gate.resolve(); await action;
  const adaptive = setup(true);
  adaptive.tracker.addDualSourceVideo('Dual', 12, 'https://host/v', 'https://host/a', null, null, 'v=1', 'a=1', '', '1', '');
  const pending = adaptive.tracker.addVideoDownload(adaptive.tracker.getTrackedVideos()[0].id); await flush();
  assert.equal(adaptive.calls[0].kind, 'inbox'); assert.equal(adaptive.calls[0].item.videoKind, 'yt');
  const dual = adaptive.calls[0].item.requests[0].adaptive;
  assert.equal(dual.kind, 'dual'); assert.equal(dual.primaryUrl, 'https://host/v'); assert.equal(dual.secondaryUrl, 'https://host/a');
  assert.equal(dual.videoMime, 'video/mp4'); assert.equal(dual.audioMime, 'audio/mp4');
  adaptive.gate.resolve(); await pending;
});

test('multi-selection snapshots every later video before first persistence wait and tracker clear', async () => {
  const f = setup(false), headers = { names: ['Referer'], values: [['https://origin/second']] };
  f.tracker.addSingleSourceVideo('A.mp4', 12, '', 'https://host/a', null, 'a=1', '', '1', '');
  f.tracker.addSingleSourceVideo('B.mp4', 24, '', 'https://host/b', headers, 'b=2', '', '2', '');
  const snapshots = f.tracker.snapshotVideoDownloads(f.tracker.getTrackedVideos().map(v => v.id));
  const operation = (async () => { for (const snapshot of snapshots) await f.tracker.submitVideoDownload(snapshot); })();
  await flush(); assert.equal(f.calls.length, 1);
  f.tracker.clearVideoList(); headers.values[0][0] = 'changed';
  f.gate.resolve(); await operation;
  assert.equal(f.calls.length, 2);
  assert.equal(f.calls[1].item.requests[0].url, 'https://host/b');
  assert.equal(f.calls[1].item.requests[0].name, 'B.mp4');
  assert.equal(f.calls[1].item.requests[0].size, 24);
  assert.equal(f.calls[1].item.requests[0].requestContext.cookies, 'b=2');
  assert.equal(f.calls[1].item.requests[0].requestContext.headers.values[0][0], 'https://origin/second');
});

test('refresh uses one case-insensitive length key and strict safe integer parsing', () => {
  const f = setup();
  const h = (names, values) => ({ names, values });
  assert.equal(f.readRefreshContentLength(h(['cOnTeNt-LeNgTh'], [['  +0012  ']])), 12);
  assert.equal(f.readRefreshContentLength(h(['Content-Length'], [['-12']])), -12);
  assert.equal(f.readRefreshContentLength(h([], [])), 0);
  assert.equal(f.readRefreshContentLength(h(['Content-Length', 'content-length'], [['12'], ['12']])), 0);
  for (const values of [[], [''], ['12x'], ['1.2'], ['9007199254740993']]) {
    assert.throws(() => f.readRefreshContentLength(h(['Content-Length'], [values])));
  }
  assert.throws(() => f.readRefreshContentLength(null));
});

test('active and queued targets consume matching auto or manual downloads only after commit', async () => {
  for (const auto of [false, true]) {
    for (const status of [0, 1, 3]) {
      const f = setup(auto), target = f.record('existing', 12, status), accepted = [];
      const token = f.refresher.begin(target, { onAccepted: (...args) => accepted.push(args) });
      const s = f.session('/download', message('https://unrelated-host/other-name', 'fresh=2'));
      const drain = s.instance.drain(); await flush();
      assert.equal(f.refreshCalls.length, 1); assert.equal(f.calls.length, 0); assert.equal(accepted.length, 0);
      assert.equal(s.sent.length, 0); assert.equal(target.status, status);
      f.refreshGate.resolve(); await drain;
      assert.equal(s.sent.length, 1); assert.equal(f.calls.length, 0); assert.equal(accepted.length, 1);
      assert.equal(accepted[0][0], token); assert.equal(accepted[0][1], 'existing');
      assert.equal(accepted[0][2].url, 'https://unrelated-host/other-name');
      assert.equal(accepted[0][2].context.cookies, 'fresh=2'); assert.equal(accepted[0][2].revision, 1);
      assert.equal(target.name, 'original.bin'); assert.equal(target.primaryUrl, 'https://old/expired');
      assert.equal(target.status, status);
    }
  }
});

test('refresh missing target or persistence failure closes direct request and keeps watch retryable', async () => {
  const f = setup(true), accepted = [], failed = [];
  f.refresher.begin(f.record(), { onAccepted: (...args) => accepted.push(args), onFailed: (...args) => failed.push(args) });
  f.setRefreshBehavior(async () => null);
  const s = f.session('/download', message('https://host/retry'));
  await s.instance.drain();
  assert.equal(failed.length, 1); assert.equal(accepted.length, 0); assert.equal(f.calls.length, 0);
  assert.equal(s.sent.length, 0); assert.equal(s.closes, 1);
  f.setRefreshBehavior(async (id, url, context) => ({ url, context, revision: 2 }));
  const retry = f.session('/download', message('https://host/retry'));
  await retry.instance.drain(); assert.equal(accepted.length, 1); assert.equal(retry.sent.length, 1);
  assert.equal(f.calls.length, 0);
});

test('mismatch preserves watch and ordinary task creation; zero or unsafe sizes never match', async () => {
  for (const size of [0, -1, 13, 9007199254740992]) {
    const f = setup(true); let accepted = 0;
    f.refresher.begin(f.record('existing', size), { onAccepted() { accepted++; } });
    const s = f.session('/download', message('https://host/file'));
    const drain = s.instance.drain(); await flush();
    assert.equal(f.refreshCalls.length, 0); assert.equal(f.calls.length, 1);
    f.gate.resolve(); await drain; assert.equal(accepted, 0);
  }
  const f = setup(); f.refresher.begin(f.record(), { onAccepted() {} });
  const mismatch = f.request('https://host/other', 13);
  assert.equal(await f.refresher.tryAcceptSingleSource(mismatch), false);
  f.refreshGate.resolve(); assert.equal(await f.refresher.tryAcceptSingleSource(f.request()), true);
});

test('ordinary video refresh uses detached full snapshot and emits no new-video dialog', async () => {
  for (const auto of [false, true]) {
    const f = setup(auto), headers = { names: ['Referer'], values: [['https://origin/snapshot']] };
    let accepted = 0, dialogs = 0;
    f.refresher.begin(f.record(), { onAccepted() { accepted++; } });
    f.actions.registerBridgeUiEvents({ onShowVideoDownloadDialog() { dialogs++; } });
    f.tracker.addSingleSourceVideo('New.mp4', 12, '', 'https://host/video', headers, 'video=2', '', '1', '');
    const id = f.tracker.getTrackedVideos()[0].id;
    const pending = f.tracker.addVideoDownload(id); await flush();
    f.tracker.clearVideoList(); headers.values[0][0] = 'changed';
    assert.equal(f.refreshCalls[0].context.headers.values[0][0], 'https://origin/snapshot');
    assert.equal(f.refreshCalls[0].context.cookies, 'video=2'); assert.equal(f.calls.length, 0);
    f.refreshGate.resolve(); await pending; assert.equal(accepted, 1); assert.equal(dialogs, 0);
  }
});

test('adaptive video and batch do not consume a single-source refresh watch', async () => {
  const f = setup(true); let accepted = 0;
  f.refresher.begin(f.record(), { onAccepted() { accepted++; } });
  f.tracker.addDualSourceVideo('Dual', 12, 'https://host/v', 'https://host/a', null, null, 'v=1', 'a=1', '', '1', '');
  const video = f.tracker.addVideoDownload(f.tracker.getTrackedVideos()[0].id); await flush();
  f.gate.resolve(); await video;
  const batch = f.session('/link', [message('https://host/file')]); await batch.instance.drain();
  assert.equal(f.refreshCalls.length, 0); assert.equal(accepted, 0); assert.equal(f.calls.length, 2);
  f.refreshGate.resolve(); assert.equal(await f.refresher.tryAcceptSingleSource(f.request()), true);
});

test('stop before matching preserves ordinary action; old stop cannot clear a newer watch', async () => {
  const f = setup(), accepted = [];
  const old = f.refresher.begin(f.record('old'), { onAccepted: (...args) => accepted.push(args) });
  f.refresher.stop(old);
  assert.equal(await f.refresher.tryAcceptSingleSource(f.request()), false);
  const token = f.refresher.begin(f.record('new'), { onAccepted: (...args) => accepted.push(args) });
  f.refresher.stop(old); f.refreshGate.resolve();
  assert.equal(await f.refresher.tryAcceptSingleSource(f.request()), true);
  assert.equal(accepted.length, 1); assert.equal(accepted[0][0], token); assert.equal(accepted[0][1], 'new');
});

test('stop and replacement during commit suppress old UI without undoing its accepted request', async () => {
  const f = setup(), oldAccepted = [], newAccepted = [];
  const old = f.refresher.begin(f.record('old'), { onAccepted: (...args) => oldAccepted.push(args) });
  const first = f.refresher.tryAcceptSingleSource(f.request('https://host/old'));
  f.refresher.stop(old);
  const next = f.refresher.begin(f.record('new'), { onAccepted: (...args) => newAccepted.push(args) });
  f.refresher.stop(old);
  const second = f.refresher.tryAcceptSingleSource(f.request('https://host/new'));
  assert.equal(f.refreshCalls.length, 1);
  f.refreshGate.resolve(); assert.equal(await first, true); assert.equal(await second, true);
  assert.equal(oldAccepted.length, 0); assert.equal(newAccepted.length, 1);
  assert.equal(newAccepted[0][0], next); assert.equal(f.refreshCalls.length, 2);
  assert.equal(f.refreshCalls[0].id, 'old'); assert.equal(f.refreshCalls[1].id, 'new');
});

test('concurrent matching socket requests consume one watch and then follow ordinary creation', async () => {
  const f = setup(true); let accepted = 0;
  f.refresher.begin(f.record(), { onAccepted() { accepted++; } });
  const a = f.session('/download', message('https://host/a'));
  const b = f.session('/download', message('https://host/b'));
  const first = a.instance.drain(), second = b.instance.drain(); await flush();
  assert.equal(f.refreshCalls.length, 1); assert.equal(f.calls.length, 0);
  f.refreshGate.resolve(); await flush();
  assert.equal(f.refreshCalls.length, 1); assert.equal(accepted, 1);
  assert.equal(f.calls.length, 1); assert.equal(f.calls[0].request.url, 'https://host/b');
  f.gate.resolve(); await Promise.all([first, second]);
  assert.equal(a.sent.length, 1); assert.equal(b.sent.length, 1);
});

test('failed first match lets queued second request retry with its original detached credentials', async () => {
  const f = setup(), wait = deferred(); let accepted = 0, failed = 0, sequence = 0;
  f.refresher.begin(f.record(), { onAccepted() { accepted++; }, onFailed() { failed++; } });
  f.setRefreshBehavior(async (id, url, context) => {
    sequence++; if (sequence === 1) { await wait.promise; return null; }
    return { url, context, revision: 1 };
  });
  const a = f.refresher.tryAcceptSingleSource(f.request('https://host/a'));
  const aRejected = assert.rejects(a, /could not be saved/);
  const input = f.request('https://host/b');
  const b = f.refresher.tryAcceptSingleSource(input);
  input.url = 'https://attacker/changed'; input.requestContext.cookies = 'changed';
  input.requestContext.headers.values[0][0] = 'changed';
  wait.resolve(); await aRejected; assert.equal(await b, true);
  assert.equal(failed, 1); assert.equal(accepted, 1); assert.equal(f.refreshCalls.length, 2);
  assert.equal(f.refreshCalls[1].url, 'https://host/b');
  assert.equal(f.refreshCalls[1].context.cookies, 'fresh=1');
  assert.equal(f.refreshCalls[1].context.headers.values[0][0], 'https://origin/fresh');
});

test('success observers cannot break ACK and a reentrant new watch survives old completion', async () => {
  const f = setup(); let next, accepted = 0;
  f.refresher.begin(f.record('old'), { onAccepted() {
    f.refresher.begin(f.record('new'), { onAccepted() { accepted++; } });
    next = f.refresher.tryAcceptSingleSource(f.request('https://host/new'));
    throw new Error('UI detached');
  } });
  const pending = f.refresher.tryAcceptSingleSource(f.request('https://host/old'));
  f.refreshGate.resolve(); assert.equal(await pending, true); assert.equal(await next, true);
  assert.equal(accepted, 1); assert.equal(f.refreshCalls[1].id, 'new');
});

test('validation failure observer may retry reentrantly without losing serialization', async () => {
  const f = setup(); let retry, failures = 0;
  f.refresher.begin(f.record(), { onAccepted() {}, onFailed() {
    failures++; retry = f.refresher.tryAcceptSingleSource(f.request());
  } });
  const malformed = { url: 'https://host/bad', cookies: null, requestHeaders: null,
    responseHeaders: { names: ['Content-Length'], values: [['bad']] } };
  await assert.rejects(f.refresher.tryAcceptMessage(malformed), /Invalid refresh content length/);
  await flush(); assert.equal(failures, 1); assert.equal(f.refreshCalls.length, 1);
  f.refreshGate.resolve(); assert.equal(await retry, true);
});

test('matched invalid URL rejects without overwriting target or falling through to creation', async () => {
  const f = setup(true); let accepted = 0, failures = 0;
  f.refresher.begin(f.record(), { onAccepted() { accepted++; }, onFailed() { failures++; } });
  for (const url of ['', 'not-url', 'https://', 'ftp://host/file']) {
    const s = f.session('/download', message(url));
    await s.instance.drain();
    assert.equal(s.sent.length, 0); assert.equal(s.closes, 1);
  }
  assert.equal(f.refreshCalls.length, 0); assert.equal(f.calls.length, 0);
  assert.equal(accepted, 0); assert.equal(failures, 4);
  f.refreshGate.resolve();
  assert.equal(await f.refresher.tryAcceptSingleSource(f.request('  https://host/valid  ')), true);
  assert.equal(f.refreshCalls[0].url, 'https://host/valid'); assert.equal(accepted, 1);
});

test('HLS and DASH snapshots carry the full adaptive descriptor and survive tracker clear', async () => {
  const f = setup(false);
  f.tracker.addHlsVideo('Show.mp4', 'https://cdn/v.m3u8', 'https://cdn/a.m3u8', null, 's=1', 'MP4 720p', '1', '');
  f.tracker.addDashVideo('Clip.mp4', 'https://cdn/m.mpd', ['https://cdn/v1.m4s'], ['https://cdn/a1.m4s'], null, null, 9,
    'video/mp4', 'audio/mp4', 'DASH', '1', '');
  const snapshots = f.tracker.snapshotVideoDownloads(f.tracker.getTrackedVideos().map(v => v.id));
  f.tracker.clearVideoList();
  const hls = snapshots.find(x => x.kind === 'hls').request.adaptive;
  const dash = snapshots.find(x => x.kind === 'dash').request.adaptive;
  assert.equal(hls.kind, 'hls'); assert.equal(hls.primaryUrl, 'https://cdn/v.m3u8'); assert.equal(hls.secondaryUrl, 'https://cdn/a.m3u8');
  assert.equal(dash.kind, 'dash'); assert.deepEqual(dash.videoSegments, ['https://cdn/v1.m4s']); assert.equal(dash.duration, 9);
  const operation = (async () => { for (const snapshot of snapshots) await f.tracker.submitVideoDownload(snapshot); })();
  await flush(); f.gate.resolve(); await operation;
  assert.deepEqual(f.calls.map(c => c.item.requests[0].adaptive.kind).sort(), ['dash', 'hls']);
});

function hlsCapture(text, finalUrl = 'https://cdn/live/master.m3u8') {
  const fetched = [];
  class Client {
    async fetchGet(url, context) { fetched.push({ url, cookies: context.cookies }); return { status: 'ok', finalUrl, text, requestedUrl: url }; }
    cancel() {}
  }
  const f = setup(false, [['core/adaptive/ManifestClient.ets', { ManifestClient: Client }]]);
  return { f, fetched };
}
function hlsMessage(url) {
  return { url, file: 'Show', cookie: 'sid=1', tabId: '7', tabUrl: 'https://site/page',
    requestHeaders: { Referer: ['https://site/page'] }, responseHeaders: { 'Content-Type': ['application/vnd.apple.mpegurl'] } };
}

test('captured HLS master playlist registers one entry per variant with resolved media playlists', async () => {
  const master = ['#EXTM3U', '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",URI="audio/en.m3u8"',
    '#EXT-X-STREAM-INF:BANDWIDTH=1280000,RESOLUTION=1280x720,AUDIO="aud"', 'video/720.m3u8',
    '#EXT-X-STREAM-INF:BANDWIDTH=640000,RESOLUTION=640x360', 'video/360.m3u8', ''].join('\n');
  const { f, fetched } = hlsCapture(master);
  const s = f.session('/media', hlsMessage('https://site/master.m3u8'));
  await s.instance.drain(); await flush();
  assert.equal(fetched.length, 1); assert.equal(fetched[0].cookies, 'sid=1');
  const videos = f.tracker.getTrackedVideos().filter(v => v.kind === 'hls');
  assert.equal(videos.length, 2);
  const paired = videos.find(v => v.uri2 !== '');
  assert.equal(paired.uri, 'https://cdn/live/video/720.m3u8'); assert.equal(paired.uri2, 'https://cdn/live/audio/en.m3u8');
  assert.equal(paired.file, 'Show.mp4');
  const single = videos.find(v => v.uri2 === '');
  assert.equal(single.uri, 'https://cdn/live/video/360.m3u8'); assert.equal(single.file, 'Show.ts');
});

test('captured HLS media playlist registers itself; I-frame-only lists are skipped', async () => {
  const media = ['#EXTM3U', '#EXT-X-TARGETDURATION:4', '#EXTINF:4,', 'seg0.ts', '#EXTINF:4,', 'seg1.ts', '#EXT-X-ENDLIST', ''].join('\n');
  const one = hlsCapture(media, 'https://cdn/live/index.m3u8');
  await one.f.session('/media', hlsMessage('https://site/index.m3u8')).instance.drain(); await flush();
  const videos = one.f.tracker.getTrackedVideos().filter(v => v.kind === 'hls');
  assert.equal(videos.length, 1); assert.equal(videos[0].uri, 'https://site/index.m3u8'); assert.equal(videos[0].description, '[.ts]');
  const iframes = hlsCapture(['#EXTM3U', '#EXT-X-I-FRAMES-ONLY', '#EXTINF:4,', 'seg0.ts', ''].join('\n'));
  await iframes.f.session('/media', hlsMessage('https://site/i.m3u8')).instance.drain(); await flush();
  assert.equal(iframes.f.tracker.getTrackedVideos().filter(v => v.kind === 'hls').length, 0);
});

test('YouTube DASH audio+video segments through /media register the audio item and the dual-source pair', async () => {
  const f = setup(false);
  const seg = (url, ctype) => ({ url, file: 'YT Video', tabId: '205', requestHeaders: {}, responseHeaders: { 'Content-Type': [ctype] } });
  await f.session('/media', seg('https://rr.googlevideo.com/videoplayback?itag=140&mime=audio%2Fmp4&clen=1000&id=oA', 'audio/mp4')).instance.drain();
  await flush();
  await f.session('/media', seg('https://rr.googlevideo.com/videoplayback?itag=137&mime=video%2Fmp4&clen=2000&id=oA', 'video/mp4')).instance.drain();
  await flush();
  const videos = f.tracker.getTrackedVideos();
  const dual = videos.filter(v => v.kind === 'yt' && v.file === 'YT Video.mkv');
  assert.equal(dual.length, 1, JSON.stringify(videos.map(v => [v.kind, v.file, v.description])));
  assert.ok(videos.some(v => v.file === 'YT Video.mp4' && v.kind === 'video'), JSON.stringify(videos.map(v => [v.kind, v.file, v.description])));
});
