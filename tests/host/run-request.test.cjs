'use strict';
// Real scheduler, manager, resolver and piece algorithms; taskpool/IO are controlled.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { loadProduction } = require('./production-loader.cjs');
const root = path.resolve(__dirname, '../../entry/src/main/ets');
const load = (file, imports = {}, globals = {}) => loadProduction(path.join(root, file + '.ets'), imports, globals);
function environment() {
  const protocol = load('core/net/HttpProtocol');
  const context = load('model/DownloadRequestContext', { '../core/net/HttpProtocol': protocol });
  const run = load('model/DownloadRunRequest', { './DownloadRequestContext': context });
  const state = load('core/engine/DownloadRequestState', {
    '../../model/DownloadRunRequest': run, '../../model/DownloadRequestContext': context
  });
  const pieces = load('core/engine/PieceAlgo');
  const tasks = [], echoes = [];
  let serial = 0;
  const taskpool = {
    Task: class { constructor(fn, params) { this.params = params; tasks.push(this); } onReceiveData(listener) { this.listener = listener; } },
    execute: () => new Promise(() => {}), cancel(task) { task.cancelled = true; }
  };
  const config = { getMaxSegments: () => 4, getMaxRetry: () => 5, getRetryDelay: () => 0, getNetworkTimeout: () => 30,
    getTempDir: () => '/tmp', getEnableSpeedLimit: () => false, getDefaultDownloadSpeed: () => 0,
    getMaxParallelDownloads: () => 1 };
  const configModule = { Config: { getInstance: () => config } };
  const logger = { hilog: { error() {}, info() {}, warn() {} } };
  const downloaderExports = {};
  const deps = {};
  for (const m of fs.readFileSync(path.join(root, 'core/engine/PieceGrabber.ets'), 'utf8').matchAll(/import[\s\S]*?from\s+'([^']+)'/g)) deps[m[1]] = {};
  Object.assign(deps, {
    '@kit.ArkTS': { taskpool, util: { generateRandomUUID: () => 'piece-' + (++serial) } },
    '@kit.CoreFileKit': { fileIo: { mkdirSync() {} } }, '@kit.PerformanceAnalysisKit': logger,
    './PieceAlgo': pieces, './EngineMath': load('core/engine/EngineMath'), './SpeedLimiter': load('core/engine/SpeedLimiter'),
    '../net/HttpProtocol': protocol, '../../model/DownloadRequestContext': context, '../../model/DownloadRunRequest': run,
    './DownloadRequestState': state, '../Config': configModule, './Downloader': downloaderExports,
    '../db/RecordMapping': { joinTempDir: (base, id) => base + '/' + id },
    '../db/StateStore': { StateStore: class { clear() {} saveChunks() {} readChunks() { return null; } } }
  });
  const scheduler = load('core/engine/PieceGrabber', deps, { setTimeout });
  Object.assign(downloaderExports, load('core/engine/Downloader', { './PieceGrabber': scheduler }));
  const managerApi = load('core/engine/DownloadManager', { './Downloader': downloaderExports,
    './AdaptiveDownloader': { AdaptiveDownloader: class { constructor() { assert.fail('Http record routed to adaptive engine'); } } },
    '../../model/AdaptiveSource': load('model/AdaptiveSource'),
    './QueueAlgo': load('core/engine/QueueAlgo'), '../../model/DownloadTypes': load('model/DownloadTypes'),
    '../Config': configModule, '@kit.PerformanceAnalysisKit': logger });
  const events = new downloaderExports.ForwardDownloadEvents(id => echoes.push(['start', id]), () => {}, () => {},
    id => echoes.push(['pause', id]), () => {}, id => echoes.push(['failed', id]));
  const record = id => ({ id, primaryUrl: 'https://old/' + id, requestRevision: 0, requestContext: credentials('old'),
    size: 1048576, name: id, targetDir: '/out' });
  function credentials(value) { const c = new context.DownloadRequestContext(); c.cookies = value;
    c.headers = { names: ['X-Auth'], values: [[value]] }; return c; }
  function publish(record, value = 'new', revision = 1) { const r = new run.DownloadRunRequest();
    r.url = 'https://' + value + '/' + record.id; r.context = credentials(value); r.revision = revision;
    state.publishCommittedRequest(record.id, r); return r; }
  return { scheduler: scheduler.PieceScheduler, manager: managerApi.DownloadManager.getInstance(), tasks, echoes,
    events, state, record, publish, credentials };
}
test('current run retains URL and credentials through real split and body retry after refresh', () => {
  const h = environment(), record = h.record('active');
  const scheduler = new h.scheduler(record, h.events); scheduler.start();
  const firstPiece = [...scheduler.pieces.values()][0];
  firstPiece.length = 1048576; firstPiece.downloaded = 123;
  scheduler.init = true; scheduler.splittingAllowed = true;
  const fresh = h.publish(record);
  record.primaryUrl = fresh.url; record.requestContext = fresh.context; record.requestRevision = 1;
  fresh.context.headers.values[0][0] = 'later-mutation';
  scheduler.createPiece();
  scheduler.retryImmediately([...scheduler.records.values()][0]);
  assert.ok(h.tasks.length >= 4);
  for (const task of h.tasks) { assert.equal(task.params.url, 'https://old/active');
    assert.equal(task.params.headers.Cookie, 'old'); assert.equal(task.params.headers['x-auth'], 'old'); }
  assert.equal(h.echoes.filter(e => e[0] === 'start').length, 1);
});
test('same scheduler resumes with committed new request and preserves piece range offsets', () => {
  const h = environment(), record = h.record('resume'), scheduler = new h.scheduler(record, h.events);
  scheduler.start(); const piece = [...scheduler.pieces.values()][0]; piece.length = 1000; piece.downloaded = 123;
  scheduler.init = true; scheduler.splittingAllowed = false;
  h.publish(record); scheduler.stop(); const before = h.tasks.length; scheduler.resume();
  const params = h.tasks[before].params;
  assert.equal(params.url, 'https://new/resume'); assert.equal(params.headers.Cookie, 'new');
  assert.equal(params.headers.Range, 'bytes=123-999'); assert.equal(params.writeStartOffset, 123);
  assert.equal(piece.downloaded, 123); assert.equal(record.requestRevision, 0);
});
test('queued stale record starts through real manager and new Downloader with latest committed request', () => {
  const h = environment(); h.manager.init(h.events);
  const blocker = h.record('blocker'), queued = h.record('queued');
  h.manager.admitNew(blocker); h.manager.admitNew(queued); assert.equal(h.manager.isQueued(queued.id), true);
  h.publish(queued); const before = h.tasks.length; h.manager.stopOne(blocker.id);
  assert.equal(h.manager.isLive(queued.id), true); assert.equal(h.manager.isQueued(queued.id), false);
  assert.equal(h.tasks[before].params.url, 'https://new/queued'); assert.equal(h.tasks[before].params.headers.Cookie, 'new');
});
test('snapshot capture precedes onStarted reentrant publication; subsequent run uses the publication', () => {
  const h = environment(), record = h.record('boundary');
  h.events.onStarted = () => { h.publish(record); };
  const scheduler = new h.scheduler(record, h.events); scheduler.start();
  assert.equal(h.tasks[0].params.url, 'https://old/boundary');
  scheduler.stop(); scheduler.resume();
  assert.equal(h.tasks.at(-1).params.url, 'https://new/boundary');
});
test('deleted request resolution fails cleanly without stranding an admitted manager slot', () => {
  const h = environment(), record = h.record('deleted'); h.manager.init(h.events);
  h.state.forgetRequest(record.id);
  assert.doesNotThrow(() => h.manager.admitNew(record));
  assert.equal(h.manager.isLive(record.id), false); assert.equal(h.tasks.length, 0);
  assert.deepEqual(h.echoes, [['failed', record.id]]);
});
test('duplicate start while running cannot replace the current run snapshot', () => {
  const h = environment(), record = h.record('double'), scheduler = new h.scheduler(record, h.events);
  scheduler.start(); h.publish(record); scheduler.start();
  scheduler.dispatchPiece([...scheduler.pieces.keys()][0], true, true, 1);
  assert.equal(h.tasks.at(-1).params.url, 'https://old/double');
  assert.equal(h.echoes.filter(e => e[0] === 'start').length, 1);
});
