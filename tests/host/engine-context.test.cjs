'use strict';
// Production scheduler/manager methods with mocked platform dependencies, not a rewritten dispatch.
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const { loadProduction } = require('./production-loader.cjs');
const root = path.resolve(__dirname, '../../entry/src/main/ets');
const protocol = loadProduction(path.join(root, 'core/net/HttpProtocol.ets'), {});
const contextApi = loadProduction(path.join(root, 'model/DownloadRequestContext.ets'), { '../core/net/HttpProtocol': protocol });
const runApi = loadProduction(path.join(root, 'model/DownloadRunRequest.ets'), { './DownloadRequestContext': contextApi });
const requestState = loadProduction(path.join(root, 'core/engine/DownloadRequestState.ets'), {
  '../../model/DownloadRunRequest': runApi, '../../model/DownloadRequestContext': contextApi
});
const logger = { hilog: { error() {}, info() {} } };
let created = 0, canceled = 0, saved = 0, released = 0;
const taskpool = { Task: class { constructor() { created++; } }, cancel() { canceled++; } };
const config = { getMaxParallelDownloads: () => 3 };
const configModule = { Config: { getInstance: () => config } };
const schedulerFile = path.join(root, 'core/engine/PieceGrabber.ets');
const imports = {};
for (const match of fs.readFileSync(schedulerFile, 'utf8').matchAll(/import[\s\S]*?from\s+'([^']+)'/g)) imports[match[1]] = {};
Object.assign(imports, {
  '@kit.ArkTS': { taskpool, util: { generateRandomUUID: () => 'piece' } },
  '@kit.CoreFileKit': { fileIo: { mkdirSync() {} } },
  '@kit.PerformanceAnalysisKit': logger,
  './PieceAlgo': { createInitialPiece: id => ({ id, length: -1, downloaded: 0, offset: 0 }), windowOf: p => [p.offset + p.downloaded, p.offset + p.length - 1] },
  './EngineMath': { ERR_GENERIC: 1 },
  '../net/HttpProtocol': protocol,
  '../../model/DownloadRequestContext': contextApi,
  '../../model/DownloadRunRequest': runApi,
  './DownloadRequestState': requestState,
  '../Config': configModule
});
const { PieceScheduler } = loadProduction(schedulerFile, imports);
const managerFile = path.join(root, 'core/engine/DownloadManager.ets');
const managerImports = {};
for (const match of fs.readFileSync(managerFile, 'utf8').matchAll(/import[\s\S]*?from\s+'([^']+)'/g)) managerImports[match[1]] = {};
managerImports['../Config'] = configModule;
managerImports['@kit.PerformanceAnalysisKit'] = logger;
managerImports['./QueueAlgo'] = { effectiveMaxParallel: n => n, pickNextQueuedId: () => null };
const { DownloadManager } = loadProduction(managerFile, managerImports);
let failed = 0, started = 0;
const manager = DownloadManager.getInstance();
manager.init({ onStarted() { started++; }, onFailed(id, code, message) { failed++; assert.equal(manager.isLive(id), false); assert.equal(message.includes('secret'), false); } });
function owner() {
  const s = Object.create(PieceScheduler.prototype);
  const context = new contextApi.DownloadRequestContext(); context.cookies = 'secret\r\nbad';
  Object.assign(s, { running: false, stopRequested: false, generation: 0,
    record: { id: 'download', primaryUrl: 'https://host/file', requestContext: context, requestRevision: 0 },
    pieces: new Map(), records: new Map(), lastStatusById: new Map(),
    stateStore: { clear() {}, saveChunks() { saved++; } },
    events: manager.wrapper, tempDirPath: '/mock', totalSize: 20 });
  manager.liveMap.set('download', { nonInteractive: false });
  return s;
}
const first = owner();
assert.doesNotThrow(() => first.start());
assert.equal(started, 1); assert.equal(failed, 1); assert.equal(first.running, false);
assert.equal(first.records.size, 0); assert.equal(created, 0); assert.equal(manager.isLive('download'), false);
console.log('ok invalid-initial-context-emits-failure-and-releases-manager-slot');
const active = owner(); active.running = true;
active.runRequest = requestState.resolveRunRequest(active.record);
active.pieces.set('piece', { id: 'piece', length: 20, downloaded: 4, offset: 0 });
active.records.set('piece', { pieceId: 'piece', alive: true, task: {}, cancelView: new Int32Array(4), writtenView: new Float64Array(1) });
active.records.set('other', { pieceId: 'other', alive: true, task: {}, cancelView: new Int32Array(4), writtenView: new Float64Array(1) });
active.pauseResolve = () => { released++; };
const beforeGeneration = active.generation;
assert.doesNotThrow(() => active.dispatchPiece('piece', false, false, 0));
assert.equal(active.running, false); assert.equal(active.stopRequested, true);
assert.equal(active.generation, beforeGeneration + 1); assert.equal(active.records.size, 0);
assert.equal(canceled, 2); assert.equal(created, 0); assert.equal(released, 1); assert.equal(saved, 2);
assert.equal(failed, 2); assert.equal(manager.isLive('download'), false);
assert.doesNotThrow(() => active.dispatchPiece('piece', false, false, 0));
assert.equal(failed, 2);
console.log('ok invalid-inflight-context-cancels-all-and-suppresses-late-dispatch');
const custom = new contextApi.DownloadRequestContext(); custom.headers = { names: ['__proto__'], values: [['custom']] };
const reopened = protocol.copyHeadersWithRange(contextApi.composeDownloadHeaders('https://host/file', custom), 'bytes=4-19');
const customKey = Object.keys(reopened).find(key => key.toLowerCase() === '__proto__');
assert.equal(reopened[customKey], 'custom');
console.log('ok special-header-survives-production-worker-header-copy');
const capturedWrapper = manager.wrapper;
const currentEvents = [];
manager.init({ onStarted(id) { currentEvents.push(id); } });
assert.equal(manager.wrapper, capturedWrapper);
capturedWrapper.onStarted('existing-live-download');
assert.deepEqual(currentEvents, ['existing-live-download']);
assert.equal(started, 1);
console.log('ok existing-download-wrapper-forwards-to-replacement-page');
console.log('SUMMARY tests=4 fail=0 scope=production-methods-with-mocked-platform');
