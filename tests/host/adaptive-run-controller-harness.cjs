'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const nativeFs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const http = require('node:http');
const { performance } = require('node:perf_hooks');
const { loadProduction } = require('./production-loader.cjs');
const { loadModules, within, until, deferred, sleep, plain } = require('./adaptive-stream-harness.cjs');
const { NodeFileAdapter, NodeRcpAdapter, sdkError } = require('./adaptive-stream-sdk.cjs');

const ETS = path.resolve(__dirname, '../../entry/src/main/ets');

class RunFileAdapter extends NodeFileAdapter {
  constructor(root) {
    super(root);
    this.api.OpenMode.WRITE_ONLY = 1;
    this.api.open = (target, mode) => this.invoke('open', { path: target, mode }, async () => {
      this.owned(target);
      let flags = (mode & 2) ? nativeFs.constants.O_RDWR :
        ((mode & 1) ? nativeFs.constants.O_WRONLY : nativeFs.constants.O_RDONLY);
      if (mode & 64) flags |= nativeFs.constants.O_CREAT;
      if (mode & 262144) flags |= nativeFs.constants.O_NOFOLLOW || 0;
      const file = await fs.open(target, flags);
      this.handles.set(file.fd, { file, path: path.resolve(target) });
      return { fd: file.fd };
    });
    this.api.mkdir = (target, recursive) => this.invoke('mkdir', { path: target }, () => {
      this.owned(target); return fs.mkdir(target, { recursive: recursive === true });
    });
    this.api.rename = (from, to) => this.invoke('rename', { path: from, to }, () => {
      this.owned(from); this.owned(to); return fs.rename(from, to);
    });
  }
}

async function fixture(t, options = {}) {
  const root = path.resolve(await fs.mkdtemp(path.join(os.tmpdir(), 'harmony-e4-')));
  const io = new RunFileAdapter(root);
  const sdk = new NodeRcpAdapter(options.sdk || {});
  const modules = loadModules(io, sdk, options);
  const globals = { Error, Promise, ArrayBuffer, Uint8Array, setTimeout, clearTimeout, ...options.globals };
  const metrics = { stores: [], loadCalls: 0, saveCalls: 0, drainCalls: 0, captures: [],
    pendingSaves: 0, maxPendingSaves: 0, constructed: [], runCalls: 0, gateCount: 0, saves: [], attemptResults: [] };
  const hooks = {};
  const controllers = [], readyValues = [], gates = [], servers = [];
  class HostTextEncoder { encodeInto(text) { return new TextEncoder().encode(text); } }
  const util = { TextEncoder: HostTextEncoder, generateRandomUUID: () => crypto.randomUUID(),
    TextDecoder: { create: (encoding, settings) => {
      const decoder = new TextDecoder(encoding, settings);
      return { decodeToString: (input, decodeOptions) => decoder.decode(input, decodeOptions) };
    } } };
  const store = loadProduction(path.join(ETS, 'core/db/AdaptiveStateStore.ets'), {
    '@kit.CoreFileKit': { fileIo: io.api }, '@kit.ArkTS': { util }, '@kit.BasicServicesKit': {},
    '../adaptive/AdaptivePlan': modules.plan, '../adaptive/AdaptiveStateCodec': modules.codec
  }, globals);
  class ObservedStore extends store.AdaptiveStateStore {
    constructor(...args) { super(...args); metrics.stores.push(this); }
    load() {
      metrics.loadCalls++;
      return super.load().then(value => { if (hooks.afterLoad) hooks.afterLoad(value, this); return value; });
    }
    save(value, expected) {
      metrics.saveCalls++;
      const observed = { expected, parts: plain(value.parts), generation: value.generation, result: null };
      metrics.saves.push(observed);
      if (hooks.beforeSave) hooks.beforeSave(value, expected, this);
      const began = performance.now();
      const work = super.save(value, expected);
      metrics.captures.push(performance.now() - began);
      metrics.pendingSaves++; metrics.maxPendingSaves = Math.max(metrics.maxPendingSaves, metrics.pendingSaves);
      return work.then(result => { observed.result = plain(result); if (hooks.afterSave) hooks.afterSave(result, this); return result; })
        .finally(() => { metrics.pendingSaves--; });
    }
    drain() { metrics.drainCalls++; return super.drain(); }
  }
  class ObservedExecutor extends modules.executor.AdaptiveAttemptExecutor {
    constructor(input, gate, clock) {
      super(input, gate, clock);
      metrics.constructed.push(plain(input.dispatch));
      if (hooks.afterExecutorConstructor) hooks.afterExecutorConstructor(input, this);
    }
    run() {
      metrics.runCalls++;
      if (hooks.beforeExecutorRun) hooks.beforeExecutorRun(this);
      return super.run().then(value => {
        metrics.attemptResults.push(plain(value));
        if (hooks.afterExecutorResult) hooks.afterExecutorResult(value, this);
        return value;
      });
    }
  }
  class ObservedThrottle extends modules.throttle.AdaptiveDownloadThrottle {
    constructor(...args) { super(...args); metrics.gateCount++; }
  }
  const request = loadProduction(path.join(ETS, 'model/DownloadRunRequest.ets'),
    { './DownloadRequestContext': modules.context }, globals);
  const controller = loadProduction(path.join(ETS, 'core/adaptive/AdaptiveRunController.ets'), {
    '@kit.ArkTS': { util },
    '../../model/DownloadRunRequest': request,
    '../../model/DownloadRequestContext': modules.context,
    './AdaptivePlan': modules.plan, './AdaptiveStateCodec': modules.codec,
    './AdaptiveScheduler': modules.scheduler,
    './AdaptiveAttemptExecutor': { ...modules.executor, AdaptiveAttemptExecutor: ObservedExecutor },
    './AdaptiveDownloadThrottle': { ...modules.throttle, AdaptiveDownloadThrottle: ObservedThrottle },
    '../db/AdaptiveStateStore': { ...store, AdaptiveStateStore: ObservedStore }
  }, globals);
  const f = { root, io, sdk, ...modules, store, controller, request, metrics, hooks, controllers,
    expectedLeakedHandles: 0, util };
  f.gate = () => { const gate = deferred(); gates.push(gate); return gate; };
  f.server = async handler => {
    const sockets = new Set(), requests = [];
    const server = http.createServer((request, response) => {
      requests.push({ url: request.url, headers: request.headers });
      handler(request, response, requests.length);
    });
    server.on('connection', socket => { sockets.add(socket); socket.once('close', () => sockets.delete(socket)); });
    server.on('clientError', (_error, socket) => socket.destroy());
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    servers.push({ server, sockets });
    return { url: 'http://127.0.0.1:' + server.address().port, requests };
  };
  f.input = (urls = ['https://run.example/s.ts'], settings = {}) => {
    if (typeof urls === 'string') urls = [urls];
    const input = new controller.AdaptiveRunInput();
    input.downloadId = settings.id || crypto.randomUUID();
    input.runToken = settings.runToken || 'run_' + crypto.randomBytes(5).toString('hex');
    input.tempBase = settings.base || root;
    input.request.url = urls[0];
    if (settings.context) input.request.context = settings.context;
    input.request.revision = settings.revision ?? 0;
    input.networkTimeoutSeconds = settings.timeoutSeconds ?? 3;
    input.limits.maxSegments = settings.lanes ?? 2;
    input.limits.maxRetry = settings.retries ?? 1;
    input.limits.retryDelayMs = settings.retryDelayMs ?? 1;
    const text = '#EXTM3U\n' + urls.map(url => '#EXTINF:1,\n' +
      (settings.rangeLength !== undefined ? '#EXT-X-BYTERANGE:' + settings.rangeLength + '@' + (settings.offset || 0) + '\n' : '') +
      url).join('\n') + '\n#EXT-X-ENDLIST\n';
    const parsed = modules.parser.parseHlsMediaPlaylist(text, urls[0], modules.resolver.resolveHlsUrl);
    assert.ok(parsed);
    input.freshPlan = modules.plan.buildHlsPlan(urls[0], parsed);
    assert.ok(input.freshPlan);
    return input;
  };
  f.make = (input, settings = {}) => {
    const policy = settings.policy || new modules.throttle.AdaptiveThrottlePolicy();
    const run = new controller.AdaptiveRunController(input, settings.provider || (() => policy), settings.clock);
    controllers.push(run);
    return run;
  };
  f.result = async run => {
    const result = await within(run.run(), 12000);
    if (result.ready) readyValues.push(result.ready);
    return result;
  };
  f.newStore = (input) => new ObservedStore(input.tempBase, input.downloadId);
  f.seed = async (input, settings = {}) => {
    const state = modules.codec.newAdaptiveState(input.downloadId, input.freshPlan);
    assert.ok(state);
    const dir = path.join(root, input.downloadId);
    await fs.mkdir(dir, { recursive: true });
    for (let i = 0; i < state.parts.length; i++) {
      if (settings.complete || settings.prefixBytes !== undefined) {
        const count = settings.prefixBytes ?? (settings.bytes?.length ?? 4);
        const data = settings.bytes || Buffer.alloc(count, 0x61 + i);
        state.parts[i].downloaded = count;
        state.parts[i].complete = settings.complete === true;
        state.parts[i].fileName = 'seed_' + i + '.part';
        await fs.writeFile(path.join(dir, state.parts[i].fileName), data);
      }
    }
    const instance = f.newStore(input);
    let saved = await instance.save(state, -1);
    assert.equal(saved.status, 'saved');
    for (let i = 0; i < (settings.generation || 0); i++) {
      saved = await instance.save(saved.state, saved.state.generation);
      assert.equal(saved.status, 'saved');
    }
    await instance.drain(); instance.dispose();
    return { state: saved.state, directory: dir };
  };
  f.resetMetrics = () => {
    metrics.loadCalls = 0; metrics.saveCalls = 0; metrics.drainCalls = 0;
    metrics.captures.length = 0; metrics.pendingSaves = 0; metrics.maxPendingSaves = 0;
    metrics.constructed.length = 0; metrics.runCalls = 0; metrics.gateCount = 0; metrics.saves.length = 0;
    metrics.attemptResults.length = 0;
    io.events.length = 0;
  };
  t.after(async () => {
    io.before = null; io.after = null; io.settled = null;
    for (const key of Object.keys(hooks)) delete hooks[key];
    for (const gate of gates) gate.resolve();
    for (const run of controllers) run.pause();
    for (const run of controllers) {
      const value = await within(run.drain(), 12000);
      if (value.ready) readyValues.push(value.ready);
    }
    for (const ready of readyValues) if (ready.lease.isCurrent()) ready.lease.release();
    for (const item of metrics.stores) { await item.drain(); item.dispose(); }
    const leaked = io.handles.size;
    sdk.cleanup(); await io.cleanup();
    for (const item of servers) {
      for (const socket of item.sockets) socket.destroy();
      await new Promise(resolve => item.server.close(resolve));
    }
    assert.equal(path.dirname(root), path.resolve(os.tmpdir()));
    assert.ok(path.basename(root).startsWith('harmony-e4-'));
    await fs.rm(root, { recursive: true, force: true });
    assert.equal(leaked, f.expectedLeakedHandles, 'manual fixture cleanup cannot masquerade as production closure');
  });
  return f;
}

async function sourceManifest() {
  const production = ['AdaptiveRunController', 'AdaptiveDownloadThrottle', 'AdaptiveRcpStream', 'AdaptiveAttemptExecutor',
    'AdaptiveAttemptFile', 'AdaptiveProtocol', 'AdaptiveScheduler', 'AdaptivePlan', 'AdaptiveStateCodec',
    'HlsModel', 'HlsParser', 'HlsUrlResolver'].map(name => path.join(ETS, 'core/adaptive', name + '.ets'));
  const files = [...production, path.join(ETS, 'core/db/AdaptiveStateStore.ets'),
    path.join(ETS, 'core/engine/SpeedLimiter.ets'), path.join(ETS, 'core/net/HttpProtocol.ets'),
    path.join(ETS, 'model/DownloadRequestContext.ets'), path.join(ETS, 'model/DownloadRunRequest.ets'),
    ...['production-loader.cjs', 'adaptive-stream-sdk.cjs', 'adaptive-stream-harness.cjs',
      'adaptive-run-controller-harness.cjs', 'adaptive-run-controller.test.cjs'].map(name => path.join(__dirname, name))];
  const result = {};
  for (const file of files) result[path.relative(path.resolve(__dirname, '../..'), file).replaceAll('\\', '/')] =
    crypto.createHash('sha256').update(await fs.readFile(file)).digest('hex');
  return result;
}

module.exports = { fixture, RunFileAdapter, within, until, deferred, sleep, plain, sdkError, sourceManifest, ETS };
