'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const nativeFs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const crypto = require('node:crypto');
const { performance } = require('node:perf_hooks');
const { loadProduction } = require('./production-loader.cjs');
const { NodeFileAdapter, NodeRcpAdapter, bytes, sdkError } = require('./adaptive-stream-sdk.cjs');

const ETS = path.resolve(__dirname, '../../entry/src/main/ets');
const adaptive = name => path.join(ETS, 'core/adaptive', name + '.ets');
const plain = value => JSON.parse(JSON.stringify(value));
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
function deferred() { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; }
async function flush() { for (let i = 0; i < 30; i++) await Promise.resolve(); }
async function within(work, ms = 5000) {
  let timer;
  try { return await Promise.race([work, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('E3 host deadline')), ms); })]); }
  finally { clearTimeout(timer); }
}
async function until(check, ms = 5000) { const end = performance.now() + ms; while (!check()) { if (performance.now() >= end) throw new Error('E3 observation deadline'); await sleep(2); } }

function loadModules(io, sdk, options = {}) {
  const globals = { Error, Promise, ArrayBuffer, Uint8Array, setTimeout, clearTimeout, ...options.globals };
  const models = loadProduction(adaptive('HlsModel'), {}, globals);
  const parser = loadProduction(adaptive('HlsParser'), { './HlsModel': models }, globals);
  const plan = loadProduction(adaptive('AdaptivePlan'), { './DashModel': require('./production-loader.cjs').loadProduction(require('node:path').resolve(__dirname, '../../entry/src/main/ets/core/adaptive/DashModel.ets'), {}, { Error }),  './HlsModel': models, './HlsParser': parser }, globals);
  const codec = loadProduction(adaptive('AdaptiveStateCodec'), { './AdaptivePlan': plan }, globals);
  const scheduler = loadProduction(adaptive('AdaptiveScheduler'), { './AdaptivePlan': plan, './AdaptiveStateCodec': codec }, globals);
  const protocol = loadProduction(adaptive('AdaptiveProtocol'), { './AdaptivePlan': plan }, globals);
  const platformUrl = { URL: { parseURL: (value, base) => new URL(value, base) } };
  const resolver = loadProduction(adaptive('HlsUrlResolver'), { './HlsModel': models, '@kit.ArkTS': { url: platformUrl } }, globals);
  const httpProtocol = loadProduction(path.join(ETS, 'core/net/HttpProtocol.ets'), {}, globals);
  const context = loadProduction(path.join(ETS, 'model/DownloadRequestContext.ets'), { '../core/net/HttpProtocol': httpProtocol }, globals);
  const limiter = loadProduction(path.join(ETS, 'core/engine/SpeedLimiter.ets'), {}, globals);
  const throttle = loadProduction(adaptive('AdaptiveDownloadThrottle'), { './AdaptiveScheduler': scheduler, './AdaptivePlan': plan,
    '../engine/SpeedLimiter': limiter, '@ohos.systemDateTime': { default: { TimeType: { ACTIVE: 0 }, getUptime: () => Math.floor(performance.now()) } } }, globals);
  const stream = loadProduction(adaptive('AdaptiveRcpStream'), { '@kit.RemoteCommunicationKit': { rcp: sdk.api },
    '@kit.ArkTS': { url: platformUrl }, '@kit.BasicServicesKit': {}, '../../model/DownloadRequestContext': context,
    './AdaptiveScheduler': scheduler, './AdaptiveProtocol': protocol, './AdaptivePlan': plan, './HlsModel': models,
    './HlsUrlResolver': resolver, './AdaptiveDownloadThrottle': throttle }, globals);
  const file = loadProduction(adaptive('AdaptiveAttemptFile'), { '@kit.CoreFileKit': { fileIo: io.api }, '@kit.BasicServicesKit': {} }, globals);
  const executor = loadProduction(adaptive('AdaptiveAttemptExecutor'), { '../../model/DownloadRequestContext': context,
    './AdaptivePlan': plan, './AdaptiveScheduler': scheduler, './AdaptiveProtocol': protocol, './AdaptiveAttemptFile': file,
    './AdaptiveDownloadThrottle': throttle, './AdaptiveRcpStream': stream }, globals);
  return { models, parser, plan, codec, scheduler, protocol, resolver, context, limiter, throttle, stream, file, executor };
}

async function fixture(t, options = {}) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'harmony-e3-'));
  const io = new NodeFileAdapter(root), sdk = new NodeRcpAdapter(options.sdk || {});
  const modules = loadModules(io, sdk, options);
  const active = [], gates = [], servers = [], observations = [];
  t.after(async () => {
    for (const task of active) task.dispose();
    await Promise.all(active.map(task => within(task.drain()).catch(() => {})));
    for (const gate of gates) gate.dispose(); sdk.cleanup(); await io.cleanup();
    for (const item of servers) { for (const socket of item.sockets) socket.destroy(); await new Promise(resolve => item.server.close(resolve)); }
    assert.equal(path.dirname(path.resolve(root)), path.resolve(os.tmpdir()));
    assert.ok(path.basename(root).startsWith('harmony-e3-')); await fs.rm(root, { recursive: true, force: true });
  });
  const f = { root, io, sdk, ...modules, active, gates, observations };
  f.server = async handler => {
    const sockets = new Set(), requests = [];
    const server = http.createServer((request, response) => { requests.push({ url: request.url, headers: request.headers }); handler(request, response); });
    server.on('connection', socket => { sockets.add(socket); socket.once('close', () => sockets.delete(socket)); });
    server.on('clientError', (_error, socket) => socket.destroy());
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve)); servers.push({ server, sockets });
    return { url: 'http://127.0.0.1:' + server.address().port, requests };
  };
  f.claim = async (targetUrl, settings = {}) => {
    const id = settings.id || crypto.randomUUID(), runToken = settings.runToken || 'e3_' + crypto.randomBytes(5).toString('hex');
    const length = settings.length ?? -1, offset = settings.offset ?? 0, count = settings.count || 1;
    let manifest = '#EXTM3U\n';
    for (let i = 0; i < count; i++) manifest += '#EXTINF:1,\n' + (length >= 0 ? '#EXT-X-BYTERANGE:' + length + '@' + offset + '\n' : '') + targetUrl + '\n';
    manifest += '#EXT-X-ENDLIST\n';
    const playlist = f.parser.parseHlsMediaPlaylist(manifest, targetUrl, f.resolver.resolveHlsUrl); assert.ok(playlist);
    const built = f.plan.buildHlsPlan(targetUrl, playlist); assert.ok(built);
    const state = f.codec.newAdaptiveState(id, built); assert.ok(state);
    const directory = path.join(root, id); await fs.mkdir(directory, { recursive: true });
    if (settings.prefix !== undefined) {
      await fs.writeFile(path.join(directory, 'old.part'), settings.prefix);
      state.parts[0].downloaded = settings.prefixBytes ?? Buffer.byteLength(settings.prefix);
      state.parts[0].fileName = 'old.part';
    }
    const limits = new f.scheduler.AdaptiveSchedulerLimits(); limits.maxSegments = settings.lanes || 1;
    limits.maxRetry = settings.retries ?? 2; limits.retryDelayMs = 0;
    const run = f.scheduler.createAdaptiveScheduler(runToken, state, limits); assert.ok(run);
    const dispatches = run.claim(1, limits.maxSegments);
    const policy = settings.policy || new f.throttle.AdaptiveThrottlePolicy();
    const gate = new f.throttle.AdaptiveDownloadThrottle(id, runToken, Math.min(count, limits.maxSegments), () => policy, settings.clock);
    gates.push(gate);
    const make = dispatch => {
      const input = new f.executor.AdaptiveAttemptOptions(); input.dispatch = dispatch; input.tempBase = root;
      if (settings.context) input.requestContext = settings.context;
      input.networkTimeoutSeconds = settings.timeoutSeconds ?? 2; input.knownResourceTotal = settings.total ?? -1;
      const task = new f.executor.AdaptiveAttemptExecutor(input, gate, settings.clock); active.push(task);
      return { input, task, dispatch, filePath: path.join(directory, dispatch.candidateFileName) };
    };
    return { id, directory, run, state, gate, policy, dispatches, make, ...make(dispatches[0]) };
  };
  return f;
}

async function digest(file) { const hash = crypto.createHash('sha256'); for await (const chunk of nativeFs.createReadStream(file)) hash.update(chunk); return hash.digest('hex'); }

async function sourceManifest() {
  const production = ['AdaptiveDownloadThrottle', 'AdaptiveRcpStream', 'AdaptiveAttemptExecutor', 'AdaptiveAttemptFile',
    'AdaptiveProtocol', 'AdaptiveScheduler', 'AdaptivePlan', 'AdaptiveStateCodec', 'HlsModel', 'HlsParser', 'HlsUrlResolver'].map(adaptive);
  const files = [...production, path.join(ETS, 'core/engine/SpeedLimiter.ets'), path.join(ETS, 'core/net/HttpProtocol.ets'),
    path.join(ETS, 'model/DownloadRequestContext.ets'), ...['production-loader.cjs', 'adaptive-stream-sdk.cjs',
      'adaptive-stream-harness.cjs', 'adaptive-stream.test.cjs', 'adaptive-stream-long-wire.test.cjs'].map(name => path.join(__dirname, name))];
  const result = {};
  for (const file of files) result[path.relative(path.resolve(__dirname, '../..'), file).replaceAll('\\', '/')] = await digest(file);
  return result;
}

class VirtualClock {
  constructor() { this.time = 1; this.serial = 0; this.timers = new Map(); this.sleeps = []; }
  now = () => this.time;
  setTimeout = (callback, ms) => { const id = ++this.serial; this.timers.set(id, { callback, at: this.time + Math.max(1, ms) }); return id; };
  clearTimeout = id => this.timers.delete(id);
  async advance(ms) {
    const end = this.time + ms;
    while (true) {
      let first = null;
      for (const pair of this.timers) if (pair[1].at <= end && (!first || pair[1].at < first[1].at)) first = pair;
      if (!first) break; this.time = first[1].at; this.timers.delete(first[0]); first[1].callback(); await flush();
    }
    this.time = end; await flush();
  }
  async finish(work, ceiling = 100000000) {
    let done = false, result; work.then(value => { done = true; result = value; }); await flush();
    const begin = this.time;
    while (!done) {
      const times = [...this.timers.values()].map(timer => timer.at); assert.ok(times.length, 'pending operation must have a bounded timer');
      await this.advance(Math.min(...times) - this.time); assert.ok(this.time - begin < ceiling);
    }
    return result;
  }
}

module.exports = { fixture, loadModules, VirtualClock, plain, bytes, sdkError, sleep, deferred, flush, within, until, digest, sourceManifest, ETS };
