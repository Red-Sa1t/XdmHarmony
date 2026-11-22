'use strict';
// Business shell for HLS/DASH/dual-source downloads (core/engine/AdaptiveDownloader.ets) with the
// E4 controller, F assembler, manifest client and file system replaced by scripted fakes.
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadProduction } = require('./production-loader.cjs');

const root = path.join(__dirname, '../../entry/src/main/ets');
const load = (file, imports = {}, globals = {}) => loadProduction(path.join(root, file + '.ets'), imports, globals);
const sourceModel = load('model/AdaptiveSource');

function setup(script) {
  const log = [];
  const runs = [];
  const fsCalls = [];
  const existing = new Set(script.existing || []);
  class Input {
    constructor() {
      this.downloadId = ''; this.runToken = ''; this.tempBase = ''; this.freshPlan = null;
      this.request = null; this.limits = { maxSegments: 0, maxRetry: 0, retryDelayMs: 0 }; this.networkTimeoutSeconds = 0;
    }
  }
  class Controller {
    constructor(input, policy) {
      this.input = input; this.policy = policy(); this.paused = false;
      runs.push(this);
      this.result = script.runs.shift();
      if (this.result === undefined) throw new Error('unexpected E4 run');
    }
    run() {
      const result = typeof this.result === 'function' ? this.result(this) : this.result;
      return Promise.resolve(result);
    }
    pause() { this.paused = true; log.push('pause'); }
    progressSnapshot() {
      return script.progress || { planned: true, totalChunks: 4, completedChunks: 2, sealedBytes: 2000, writtenBytes: 2000,
        durationSeconds: 0 };
    }
  }
  class Assembler {
    constructor(base, id) { this.base = base; this.id = id; this.cancelled = false; log.push('assembler ' + base + ' ' + id); }
    run(state, listener) {
      if (listener) listener({ phase: 'concat', copiedBytes: 1, totalInputBytes: 2, processedTimeMs: 0, totalTimeMs: -1 });
      const result = typeof script.assembly === 'function' ? script.assembly(this) : script.assembly;
      this.last = result;
      return Promise.resolve(result);
    }
    drain() { return Promise.resolve(this.last); }
    cancel() { this.cancelled = true; log.push('assembly cancel'); }
  }
  const manifests = script.manifests || {};
  class Client {
    fetchGet(url) {
      log.push('manifest ' + url);
      const value = manifests[url];
      return Promise.resolve(value || { status: 'httpError', finalUrl: url, text: '' });
    }
    cancel() { log.push('manifest cancel'); }
  }
  const fileIo = {
    mkdir: async () => {},
    rename: async (from, to) => { fsCalls.push(['rename', from, to]); if (script.renameFails) throw new Error('EXDEV'); },
    copyFile: async (from, to) => { fsCalls.push(['copy', from, to]); },
    unlink: async p => { fsCalls.push(['unlink', p]); },
    stat: async () => ({ size: script.outputBytes ?? 4321 }),
    accessSync: p => existing.has(p)
  };
  const removed = [];
  const sinks = [];
  const plans = [];
  const config = { getTempDir: () => '/tmp/xdm', getDownloadDir: () => '/dl', getMaxSegments: () => 8,
    getFileConflictResolution: () => 0,
    getMaxRetry: () => 3, getRetryDelay: () => 2, getNetworkTimeout: () => 30,
    getEnableSpeedLimit: () => script.limit !== undefined, getDefaultDownloadSpeed: () => script.limit ?? 0 };
  const mod = load('core/engine/AdaptiveDownloader', {
    '@kit.CoreFileKit': { fileIo },
    '@kit.ArkTS': { util: { generateRandomUUID: () => 'token-' + runs.length } },
    '@kit.PerformanceAnalysisKit': { hilog: { error: (...args) => log.push('log ' + args[3]),
      warn: (...args) => log.push('warn ' + args[3]) } },
    './Downloader': { NoopDownloadEvents: class {} },
    './DownloadRequestState': { resolveRunRequest: () => ({ url: 'https://h/m.m3u8', context: { headers: null, cookies: null }, revision: 0 }) },
    '../Config': { Config: { getInstance: () => config } },
    '../util/FileNames': load('core/util/FileNames', { '@kit.ArkTS': { uri: {}, url: {} } }),
    '../adaptive/AdaptivePlan': {
      buildDashPlan: (...args) => { plans.push(['dash', ...args]); return script.plan === undefined ? { kind: 'Dash' } : script.plan; },
      buildHlsPlan: (...args) => { plans.push(['hls', ...args]); return script.plan === undefined ? { kind: 'Hls' } : script.plan; }
    },
    '../adaptive/AdaptiveRunController': { AdaptiveRunController: Controller, AdaptiveRunInput: Input },
    '../adaptive/AdaptiveDownloadThrottle': { AdaptiveThrottlePolicy: class { constructor() { this.globalEnabled = false; this.globalKiBps = 0; this.taskKiBps = 0; } } },
    '../adaptive/AdaptiveAssembler': { AdaptiveAssembler: Assembler },
    '../adaptive/ManifestClient': { ManifestClient: Client },
    '../adaptive/HlsParser': { parseHlsMediaPlaylist: text => (text === 'bad' ? null : JSON.parse(text)) },
    '../adaptive/HlsUrlResolver': { resolveHlsUrl: (a, b) => b },
    '../db/StateStore': { StateStore: { removeById: (base, id) => removed.push(base + '/' + id) } },
    '../adaptive/AdaptiveAttemptExecutor': { setAdaptiveHeadRejectSink: sink => { sinks.push(sink); } }
  }, { setInterval: () => 1, clearInterval: () => {} });
  const events = [];
  const sink = {
    onStarted: id => events.push(['started', id]),
    onConnected: (id, status, size) => events.push(['connected', status, size]),
    onProgress: (id, percent, speed, eta, bytes) => events.push(['progress', percent, bytes]),
    onPaused: (id, bytes) => events.push(['paused', bytes]),
    onFinished: (id, size, file) => events.push(['finished', size, file]),
    onFailed: (id, code, detail) => events.push(['failed', code, detail])
  };
  const record = Object.assign({ id: '11111111-2222-4333-8444-555555555555', name: 'clip.mp4', targetDir: '/dl',
    maxSpeedLimitInKiB: 0, downloadType: 'Dash', adaptiveSource: null }, script.record || {});
  const downloader = new mod.AdaptiveDownloader(record, sink);
  const settled = () => new Promise(resolve => setTimeout(resolve, 10));
  return { mod, downloader, events, log, runs, fsCalls, removed, plans, settled, record, sinks };
}

function lease(log) {
  return {
    isCurrent: () => true, isStopRequested: () => false,
    attachReader: () => { log.push('attach'); return true; },
    release: () => { log.push('release'); return true; },
    quarantine: code => log.push('quarantine ' + code)
  };
}

const planMissing = { kind: 'failed', errorCode: 'AdaptivePlanMissing', ownerDisposition: 'released', durableState: null, ready: null };
const dashSource = Object.assign(new sourceModel.AdaptiveSourceDescriptor(), { kind: 'dash', primaryUrl: 'https://h/a.mpd',
  videoSegments: ['https://h/v1.m4s'], audioSegments: ['https://h/a1.m4s'], videoMime: 'video/mp4', audioMime: 'audio/mp4', duration: 10 });
const success = { status: 'success', errorCode: '', outputName: 'out.mp4', outputBytes: 4321, extension: '.mp4',
  closed: true, resourceUncertain: false, cleanupComplete: true };

function ready(log) {
  return { kind: 'ready', errorCode: '', ownerDisposition: 'heldForAssembly', durableState: {},
    ready: { downloadId: '11111111-2222-4333-8444-555555555555', state: { parts: [] }, lease: lease(log) } };
}

test('empty checkpoint builds the DASH plan once, then assembles and publishes into the download directory', async () => {
  let ctx;
  ctx = setup({ record: { adaptiveSource: dashSource }, runs: [planMissing, () => ready(ctx.log)], assembly: success });
  ctx.downloader.start();
  await ctx.settled();
  assert.equal(ctx.runs.length, 2);
  assert.equal(ctx.runs[0].input.freshPlan, null, 'first child must try checkpoint resume');
  assert.deepEqual(ctx.runs[1].input.freshPlan, { kind: 'Dash' });
  assert.equal(ctx.runs[0].input.tempBase, '/tmp/xdm');
  assert.equal(ctx.runs[0].input.limits.retryDelayMs, 2000);
  assert.equal(ctx.plans.length, 1);
  assert.deepEqual(ctx.fsCalls, [['rename', '/tmp/xdm/11111111-2222-4333-8444-555555555555/out.mp4', '/dl/clip.mp4']]);
  assert.deepEqual(ctx.removed, ['/tmp/xdm/11111111-2222-4333-8444-555555555555']);
  assert.ok(ctx.log.indexOf('attach') < ctx.log.indexOf('release'));
  assert.deepEqual(ctx.events[0], ['started', ctx.record.id]);
  assert.deepEqual(ctx.events[ctx.events.length - 1], ['finished', 4321, '/dl/clip.mp4']);
  assert.ok(ctx.events.every(e => e[0] !== 'progress' || e[1] <= 99), 'never 100% before publication');
  assert.equal(ctx.downloader.isRunning(), false);
});

test('a persisted plan resumes without any manifest or plan work', async () => {
  let ctx;
  ctx = setup({ record: { adaptiveSource: null, downloadType: 'Hls' }, runs: [() => ready(ctx.log)], assembly: success });
  ctx.downloader.resume();
  await ctx.settled();
  assert.equal(ctx.runs.length, 1);
  assert.equal(ctx.plans.length, 0);
  assert.ok(!ctx.log.some(l => l.startsWith('manifest')));
  assert.equal(ctx.events[ctx.events.length - 1][0], 'finished');
});

test('HLS bootstrap fetches selected video and audio media playlists and pairs them in one plan', async () => {
  const playlist = JSON.stringify({ segments: [{}], isEncrypted: false, isKeyIFrameOnly: false });
  let ctx;
  const source = Object.assign(new sourceModel.AdaptiveSourceDescriptor(), { kind: 'hls', primaryUrl: 'https://h/v.m3u8', secondaryUrl: 'https://h/a.m3u8' });
  ctx = setup({ record: { adaptiveSource: source, downloadType: 'Hls', name: 'show.m3u8.mp4' },
    runs: [planMissing, () => ready(ctx.log)], assembly: Object.assign({}, success, { extension: '.mkv', outputName: 'out.mkv' }),
    manifests: { 'https://h/v.m3u8': { status: 'ok', finalUrl: 'https://cdn/v.m3u8', text: playlist },
      'https://h/a.m3u8': { status: 'ok', finalUrl: 'https://cdn/a.m3u8', text: playlist } } });
  ctx.downloader.start();
  await ctx.settled();
  assert.deepEqual(ctx.log.filter(l => l.startsWith('manifest')), ['manifest https://h/v.m3u8', 'manifest https://h/a.m3u8']);
  assert.equal(ctx.plans[0][0], 'hls');
  assert.equal(ctx.plans[0][3], 'https://h/a.m3u8');
  assert.deepEqual(ctx.events[ctx.events.length - 1], ['finished', 4321, '/dl/show.mkv'], 'container extension replaces media extensions');
});

test('encrypted HLS fails as unsupported without starting a download run', async () => {
  const playlist = JSON.stringify({ segments: [{}], isEncrypted: true, isKeyIFrameOnly: false });
  const source = Object.assign(new sourceModel.AdaptiveSourceDescriptor(), { kind: 'hls', primaryUrl: 'https://h/v.m3u8' });
  const ctx = setup({ record: { adaptiveSource: source, downloadType: 'Hls' }, runs: [planMissing],
    manifests: { 'https://h/v.m3u8': { status: 'ok', finalUrl: 'https://h/v.m3u8', text: playlist } } });
  ctx.downloader.start();
  await ctx.settled();
  assert.equal(ctx.runs.length, 1);
  assert.deepEqual(ctx.events[ctx.events.length - 1], ['failed', 3003, 'AdaptiveEncryptedOrIFrameOnly']);
});

test('manifest HTTP failure reports a manifest error code', async () => {
  const source = Object.assign(new sourceModel.AdaptiveSourceDescriptor(), { kind: 'hls', primaryUrl: 'https://h/v.m3u8' });
  const ctx = setup({ record: { adaptiveSource: source, downloadType: 'Hls' }, runs: [planMissing] });
  ctx.downloader.start();
  await ctx.settled();
  assert.deepEqual(ctx.events[ctx.events.length - 1], ['failed', 3002, 'AdaptiveManifest_httpError']);
});

test('missing descriptor with an empty checkpoint fails explicitly instead of becoming Http', async () => {
  const ctx = setup({ record: { adaptiveSource: null }, runs: [planMissing] });
  ctx.downloader.start();
  await ctx.settled();
  assert.deepEqual(ctx.events[ctx.events.length - 1], ['failed', 3001, 'AdaptiveSourceMissing']);
});

test('stop pauses the live E4 child and reports the sealed prefix after it drains', async () => {
  let release;
  const gate = new Promise(resolve => { release = resolve; });
  const ctx = setup({ record: { adaptiveSource: dashSource },
    runs: [c => gate.then(() => ({ kind: 'paused', errorCode: '', ownerDisposition: 'released', durableState: {}, ready: null }))] });
  ctx.downloader.start();
  await new Promise(resolve => setTimeout(resolve, 0));
  ctx.downloader.stop();
  assert.equal(ctx.runs[0].paused, true);
  assert.equal(ctx.downloader.isRunning(), true, 'still running until the owned work drains');
  release();
  await ctx.settled();
  assert.deepEqual(ctx.events[ctx.events.length - 1], ['paused', 2000]);
  assert.equal(ctx.downloader.isRunning(), false);
});

test('ordinary E4 failure is reported once and never triggers manifest work', async () => {
  const ctx = setup({ record: { adaptiveSource: dashSource },
    runs: [{ kind: 'failed', errorCode: 'AdaptiveRetryExhausted', ownerDisposition: 'released', durableState: {}, ready: null }] });
  ctx.downloader.start();
  await ctx.settled();
  assert.equal(ctx.plans.length, 0);
  assert.deepEqual(ctx.events.filter(e => e[0] === 'failed'), [['failed', 3004, 'AdaptiveRetryExhausted']]);
});

test('quarantined E4 result is a resource failure', async () => {
  const ctx = setup({ record: { adaptiveSource: dashSource },
    runs: [{ kind: 'resourceFault', errorCode: 'AdaptiveCheckpointResourceUncertain', ownerDisposition: 'quarantined', durableState: null, ready: null }] });
  ctx.downloader.start();
  await ctx.settled();
  assert.deepEqual(ctx.events[ctx.events.length - 1], ['failed', 3007, 'AdaptiveCheckpointResourceUncertain']);
});

test('stopped assembly releases the lease and pauses; the checkpoint stays for the next resume', async () => {
  let ctx;
  ctx = setup({ record: { adaptiveSource: dashSource }, runs: [() => ready(ctx.log)],
    assembly: Object.assign({}, success, { status: 'stopped', outputName: '' }) });
  ctx.downloader.start();
  await ctx.settled();
  assert.ok(ctx.log.includes('release'));
  assert.deepEqual(ctx.removed, []);
  assert.equal(ctx.events[ctx.events.length - 1][0], 'paused');
});

test('uncertain assembly resources quarantine the lease', async () => {
  let ctx;
  ctx = setup({ record: { adaptiveSource: dashSource }, runs: [() => ready(ctx.log)],
    assembly: Object.assign({}, success, { resourceUncertain: true }) });
  ctx.downloader.start();
  await ctx.settled();
  assert.ok(ctx.log.some(l => l.startsWith('quarantine')));
  assert.ok(!ctx.log.includes('release'));
  assert.deepEqual(ctx.events[ctx.events.length - 1], ['failed', 3007, 'AdaptiveAssemblyUncertain']);
});

test('assembly failure keeps the checkpoint and reports an assembly error', async () => {
  let ctx;
  ctx = setup({ record: { adaptiveSource: dashSource }, runs: [() => ready(ctx.log)],
    assembly: Object.assign({}, success, { status: 'ioError', errorCode: 'AssemblyIoFailure', outputName: '' }) });
  ctx.downloader.start();
  await ctx.settled();
  assert.ok(ctx.log.includes('release'));
  assert.deepEqual(ctx.removed, []);
  assert.deepEqual(ctx.events[ctx.events.length - 1], ['failed', 3005, 'AssemblyIoFailure']);
});

test('publication avoids collisions and falls back to copy when rename fails', async () => {
  let ctx;
  ctx = setup({ record: { adaptiveSource: dashSource }, runs: [() => ready(ctx.log)], assembly: success,
    existing: ['/dl/clip.mp4'], renameFails: true });
  ctx.downloader.start();
  await ctx.settled();
  assert.deepEqual(ctx.fsCalls.map(c => c[0] + ' ' + c[2]), ['rename /dl/clip_1.mp4', 'copy /dl/clip_1.mp4', 'unlink undefined']);
  assert.deepEqual(ctx.events[ctx.events.length - 1], ['finished', 4321, '/dl/clip_1.mp4']);
});

test('speed limits come from global config and the task limit', async () => {
  let ctx;
  ctx = setup({ record: { adaptiveSource: dashSource, maxSpeedLimitInKiB: 64 }, runs: [() => ready(ctx.log)],
    assembly: success, limit: 256 });
  ctx.downloader.start();
  await ctx.settled();
  assert.equal(ctx.runs[0].policy.globalEnabled, true);
  assert.equal(ctx.runs[0].policy.globalKiBps, 256);
  assert.equal(ctx.runs[0].policy.taskKiBps, 64);
});

test('adaptiveOutputName strips media and manifest extensions only', () => {
  const ctx = setup({ runs: [] });
  const name = ctx.mod.adaptiveOutputName;
  assert.equal(name('clip.ts', '.mp4'), 'clip.mp4');
  assert.equal(name('index.m3u8.mp4', '.mkv'), 'index.mkv');
  assert.equal(name('my.show', '.mp4'), 'my.show.mp4');
  assert.equal(name(null, '.ts'), 'video.ts');
  assert.equal(name('a.mp4', 'mkv'), 'a.mkv');
});

test('AdaptiveSource validates kinds, round-trips and rejects malformed payloads', () => {
  const m = sourceModel;
  assert.equal(m.adaptiveDownloadType('hls'), 'Hls');
  assert.equal(m.adaptiveDownloadType('dash'), 'Dash');
  assert.equal(m.adaptiveDownloadType('dual'), 'Dual');
  assert.equal(m.adaptiveDownloadType('video'), '');
  assert.equal(m.isAdaptiveDownloadType('Http'), false);
  assert.equal(m.isAdaptiveDownloadType('Dash'), true);
  const text = m.serializeAdaptiveSource(dashSource);
  const parsed = m.parseAdaptiveSource(text);
  assert.deepEqual(JSON.parse(JSON.stringify(parsed)), JSON.parse(text));
  parsed.videoSegments.push('https://x');
  assert.equal(dashSource.videoSegments.length, 1, 'clone is detached');
  const hls = Object.assign(new m.AdaptiveSourceDescriptor(), { kind: 'hls', primaryUrl: 'https://h/v.m3u8' });
  assert.equal(m.validateAdaptiveSource(hls), true);
  assert.equal(m.validateAdaptiveSource(Object.assign(new m.AdaptiveSourceDescriptor(), hls, { secondaryUrl: 'ftp://x' })), false);
  assert.equal(m.validateAdaptiveSource(Object.assign(new m.AdaptiveSourceDescriptor(), { kind: 'dash', primaryUrl: 'https://h/a.mpd' })), false,
    'dash needs both segment lists');
  assert.equal(m.validateAdaptiveSource(Object.assign(new m.AdaptiveSourceDescriptor(), { kind: 'dual', primaryUrl: 'https://h/v' })), false,
    'dual needs the audio URL');
  assert.equal(m.validateAdaptiveSource(Object.assign(new m.AdaptiveSourceDescriptor(), { kind: 'video', primaryUrl: 'https://h/v' })), false);
  assert.equal(m.parseAdaptiveSource('{"schema":2}'), null);
  assert.equal(m.parseAdaptiveSource('not json'), null);
  assert.throws(() => m.serializeAdaptiveSource(Object.assign(new m.AdaptiveSourceDescriptor(), { kind: 'hls', primaryUrl: 'javascript:1' })));
  assert.equal(m.mimeFromUrlQuery('https://r.googlevideo.com/videoplayback?itag=1&mime=video%2Fwebm&x=1'), 'video/webm');
  assert.equal(m.mimeFromUrlQuery('https://h/a?mime=text%2Fhtml'), '');
  assert.equal(m.mimeFromUrlQuery('https://h/a'), '');
});

test('DownloadManager factory routes persisted Hls/Dash/Dual types to the adaptive engine and the rest to Http', () => {
  const made = [];
  class Http { constructor(record) { made.push(['http', record.downloadType]); } start() {} resume() {} stop() {} isRunning() { return false; } }
  class Adaptive { constructor(record) { made.push(['adaptive', record.downloadType]); } start() {} resume() {} stop() {} isRunning() { return false; } }
  const manager = load('core/engine/DownloadManager', {
    './Downloader': { Downloader: Http }, './AdaptiveDownloader': { AdaptiveDownloader: Adaptive },
    '../../model/AdaptiveSource': sourceModel, './QueueAlgo': load('core/engine/QueueAlgo'),
    '../../model/DownloadTypes': load('model/DownloadTypes'),
    '../Config': { Config: { getInstance: () => ({ getMaxParallelDownloads: () => 3 }) } },
    '@kit.PerformanceAnalysisKit': { hilog: { error() {} } }
  });
  for (const type of ['Hls', 'Dash', 'Dual', 'Http', null, 'hls']) {
    manager.createManagedDownloader({ id: 'x', downloadType: type }, {});
  }
  assert.deepEqual(made, [['adaptive', 'Hls'], ['adaptive', 'Dash'], ['adaptive', 'Dual'], ['http', 'Http'], ['http', null], ['http', 'hls']]);
});

test('rejected segment heads are logged with chunk id, status and fixed code only', () => {
  const ctx = setup({ runs: [] });
  assert.equal(ctx.sinks.length, 1);
  ctx.sinks[0]('c7', 404, 'InvalidResponse');
  assert.deepEqual(ctx.log.filter(l => l.startsWith('warn')), ['warn segment rejected chunk=c7 status=404 code=InvalidResponse']);
});
