'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const { performance } = require('node:perf_hooks');
const { fixture, within, until, sleep, plain, sdkError, sourceManifest } = require('./adaptive-run-controller-harness.cjs');

const observations = {};
let sourceStart, startedAtUtc;
test.before(async () => { sourceStart = await sourceManifest(); startedAtUtc = new Date().toISOString(); });
test.after(async () => {
  if (!process.env.E4_HOST_REPORT) return;
  const sourceEnd = await sourceManifest();
  await fs.writeFile(process.env.E4_HOST_REPORT, JSON.stringify({ startedAtUtc, endedAtUtc: new Date().toISOString(),
    sourceStart, sourceEnd, sourcesMatch: JSON.stringify(sourceStart) === JSON.stringify(sourceEnd), observations }, null, 2) + '\n');
});

const OPTIONS = { timeout: 30000 };
const serve = body => (_request, response) => {
  response.writeHead(200, { 'Content-Length': body.length, 'Content-Type': 'video/mp2t' });
  response.end(body);
};
const candidate = event => event.path?.endsWith('.part') && !path.basename(event.path).startsWith('seed_');
const stateSlot = event => /adaptive-state\.\d\.json$/.test(event.path || '');
const staging = event => /adaptive-state\.[0-9a-f-]+\.tmp$/i.test(event.path || '');
const resultData = value => JSON.parse(JSON.stringify(value, (key, item) => key === 'lease' ? 'capability' : item));

async function remainsPending(work, ms = 30) {
  let completed = false;
  work.then(() => { completed = true; }, () => { completed = true; });
  await sleep(ms);
  assert.equal(completed, false, 'a real outstanding operation must keep the barrier pending');
}

async function assertReady(f, input, result, bodies) {
  assert.equal(result.kind, 'ready', JSON.stringify(resultData(result)));
  assert.equal(result.errorCode, '');
  assert.equal(result.ownerDisposition, 'heldForAssembly');
  assert.equal(result.ready.downloadId, input.downloadId);
  assert.equal(result.ready.runToken, input.runToken);
  assert.match(result.ready.assemblyId, /^[0-9a-f-]{36}$/i);
  assert.equal(result.ready.generation, result.durableState.generation);
  assert.equal(result.ready.lease.isCurrent(), true);
  assert.notEqual(result.ready.state, result.durableState);
  assert.deepEqual(plain(result.ready.state), plain(result.durableState));
  assert.ok(result.durableState.parts.every(part => part.complete));
  if (bodies) for (let i = 0; i < bodies.length; i++) {
    const part = result.durableState.parts[i];
    assert.equal(part.downloaded, bodies[i].length);
    const bytes = await fs.readFile(path.join(f.root, input.downloadId, part.fileName));
    assert.deepEqual(bytes.subarray(0, part.downloaded), bodies[i]);
  }
  assert.equal(f.io.handles.size, 0);
  assert.ok(f.sdk.records.every(record => record.closed));
}

test('E4 constructor, pre-run pause and pre-run drain make no IO, clock or policy call', OPTIONS, async t => {
  let timerCalls = 0;
  const f = await fixture(t, { globals: { setTimeout: (...args) => { timerCalls++; return setTimeout(...args); } } });
  let clockCalls = 0, policyCalls = 0;
  for (const operation of ['pause', 'drain']) {
    const input = f.input();
    const run = f.make(input, {
      clock: () => { clockCalls++; return 1; },
      provider: () => { policyCalls++; return new f.throttle.AdaptiveThrottlePolicy(); }
    });
    assert.equal(f.metrics.stores.length, 0);
    if (operation === 'pause') run.pause();
    const first = await (operation === 'drain' ? run.drain() : run.run());
    assert.equal(first.kind, 'paused');
    assert.equal(first.ownerDisposition, 'notAcquired');
    assert.equal(first.ready, null); assert.equal(first.durableState, null);
    assert.deepEqual(plain(await run.run()), plain(first));
    assert.notEqual(await run.drain(), first);
  }
  assert.equal(clockCalls, 0); assert.equal(policyCalls, 0);
  assert.equal(f.metrics.stores.length, 0); assert.equal(f.io.events.length, 0);
  assert.equal(f.sdk.records.length, 0); assert.equal(f.metrics.gateCount, 0);
  assert.equal(timerCalls, 0);
});

test('E4 rejects malformed admission without producing IO or leaking private errors', OPTIONS, async t => {
  const f = await fixture(t);
  const cases = [
    input => { input.downloadId = '../private'; },
    input => { input.runToken = 'private secret'; },
    input => { input.tempBase = 'relative'; },
    input => { input.tempBase = 'C:/../../private'; },
    input => { input.request.revision = -1; },
    input => { input.request.url = 'file:///private'; },
    input => { input.request.context.cookies = 'secret\r\n'; },
    input => { input.freshPlan = {}; },
    input => { input.limits.maxSegments = 0; },
    input => { input.limits.maxRetry = Number.MAX_SAFE_INTEGER; },
    input => { input.limits.retryDelayMs = 0.5; },
    input => { input.limits.extra = 1; },
    input => { input.limits = []; },
    input => { input.request = null; }
  ];
  for (const mutate of cases) {
    const input = f.input(); mutate(input);
    const run = f.make(input); run.pause();
    const result = await run.run();
    assert.equal(result.kind, 'rejected'); assert.equal(result.errorCode, 'InvalidAdaptiveRunInput');
    assert.equal(result.ownerDisposition, 'notAcquired');
    assert.equal(result.ready, null); assert.equal(result.durableState, null);
  }
  assert.equal(f.io.events.length, 0); assert.equal(f.metrics.stores.length, 0);
});

test('E4 actual B/C/E1/E2/E3 download reaches durable ready and repeated observers share only the lease', OPTIONS, async t => {
  const f = await fixture(t);
  const body = Buffer.from('real complete segment');
  const server = await f.server(serve(body));
  const input = f.input(server.url + '/one.ts');
  const run = f.make(input);
  const firstWork = f.result(run), secondWork = run.run();
  const first = await firstWork, second = await secondWork;
  await assertReady(f, input, first, [body]);
  assert.equal(server.requests.length, 1);
  assert.equal(f.metrics.loadCalls, 1); assert.equal(f.metrics.gateCount, 1);
  assert.equal(f.metrics.saveCalls, 2); assert.equal(f.metrics.maxPendingSaves, 1);
  assert.equal(first.durableState.generation, 1);
  assert.equal(first.ready.lease, second.ready.lease);
  assert.notEqual(first, second); assert.notEqual(first.ready.state.parts, second.ready.state.parts);
  const snapshot = resultData(second);
  first.ready.state.parts[0].downloaded = 0;
  first.durableState.plan.chunks[0].url = 'https://mutated.example/';
  first.ready.assemblyId = 'mutated';
  assert.deepEqual(resultData(await run.drain()), snapshot);
  const reloaded = await f.newStore(input).load();
  assert.equal(reloaded.status, 'loaded');
  assert.deepEqual(plain(reloaded.state), plain(second.durableState));
});

test('E4 synchronous owner acquisition prevents same-directory runs during a pending load', OPTIONS, async t => {
  const f = await fixture(t), gate = f.gate();
  const input = f.input(), run = f.make(input);
  f.io.before = async event => { if (event.op === 'lstat') await gate.promise; };
  const pending = f.result(run);
  await until(() => f.io.events.length > 0);
  const otherInput = f.input(undefined, { id: input.downloadId.toUpperCase(), base: f.root + '/./' });
  const other = await f.result(f.make(otherInput));
  assert.equal(other.kind, 'rejected'); assert.equal(other.errorCode, 'AdaptiveOwnerBusy');
  assert.equal(f.metrics.loadCalls, 1);
  run.pause(); await remainsPending(run.drain());
  gate.resolve();
  const ended = await pending;
  assert.equal(ended.kind, 'paused'); assert.equal(ended.ownerDisposition, 'released');
  assert.equal(ended.durableState, null); assert.equal(f.metrics.saveCalls, 0);
  assert.equal(f.sdk.records.length, 0);
});

test('E4 loaded complete state uses persisted plan and needs no attempt, gate or save', OPTIONS, async t => {
  const f = await fixture(t), input = f.input();
  const seeded = await f.seed(input, { complete: true, generation: 2 });
  input.freshPlan = f.input('https://different.example/fresh.ts').freshPlan;
  f.resetMetrics();
  const result = await f.result(f.make(input));
  await assertReady(f, input, result, [Buffer.from('aaaa')]);
  assert.deepEqual(plain(result.durableState), plain(seeded.state));
  assert.equal(f.metrics.saveCalls, 0); assert.equal(f.metrics.gateCount, 0);
  assert.equal(f.metrics.constructed.length, 0); assert.equal(f.sdk.records.length, 0);
});

test('E4 missing persisted state and missing fresh plan fail without overwriting the directory', OPTIONS, async t => {
  const f = await fixture(t), input = f.input(); input.freshPlan = null;
  const result = await f.result(f.make(input));
  assert.equal(result.kind, 'failed'); assert.equal(result.errorCode, 'AdaptivePlanMissing');
  assert.equal(result.ownerDisposition, 'released'); assert.equal(result.durableState, null);
  assert.equal(f.metrics.saveCalls, 0); assert.equal(f.sdk.records.length, 0);
});

test('E4 saves repaired load before any dispatch even if pause arrives during load completion', OPTIONS, async t => {
  const f = await fixture(t), input = f.input();
  const seeded = await f.seed(input, { complete: true });
  await fs.truncate(path.join(seeded.directory, seeded.state.parts[0].fileName), 0);
  f.resetMetrics();
  const run = f.make(input);
  f.hooks.afterLoad = loaded => { assert.equal(loaded.repairedParts, 1); run.pause(); };
  const result = await f.result(run);
  assert.equal(result.kind, 'paused'); assert.equal(result.ownerDisposition, 'released');
  assert.equal(result.durableState.generation, 1);
  assert.deepEqual(plain(result.durableState.parts[0]), { chunkId: 'c0', downloaded: 0, complete: false, fileName: '' });
  assert.equal(f.metrics.saveCalls, 1); assert.equal(f.metrics.constructed.length, 0);
});

test('E4 a repaired state is not durable when the actual repair save fails', OPTIONS, async t => {
  const f = await fixture(t), input = f.input();
  const seeded = await f.seed(input, { complete: true });
  await fs.truncate(path.join(seeded.directory, seeded.state.parts[0].fileName), 0);
  f.resetMetrics();
  const run = f.make(input);
  f.hooks.afterLoad = () => run.pause();
  f.io.before = event => { if (event.op === 'write' && staging(event)) throw sdkError(13900005); };
  const result = await f.result(run);
  assert.equal(result.kind, 'failed'); assert.equal(result.errorCode, 'AdaptiveCheckpointIoError');
  assert.equal(result.durableState, null); assert.equal(result.ownerDisposition, 'released');
  assert.equal(f.metrics.saveCalls, 1); assert.equal(f.sdk.records.length, 0);
  assert.equal(f.metrics.stores.at(-1).hasUncertainResources(), false);
});

test('E4 whole claim batch is constructed before first run can synchronously pause it', OPTIONS, async t => {
  const f = await fixture(t);
  const input = f.input(['https://run.example/a.ts', 'https://run.example/b.ts', 'https://run.example/c.ts'], { lanes: 3 });
  const run = f.make(input);
  let observed = false;
  f.hooks.beforeExecutorRun = () => {
    if (observed) return;
    observed = true; assert.equal(f.metrics.constructed.length, 3); run.pause();
  };
  const result = await f.result(run);
  assert.equal(observed, true); assert.equal(result.kind, 'paused');
  assert.equal(result.ownerDisposition, 'released'); assert.equal(result.durableState.generation, 0);
  assert.equal(f.metrics.gateCount, 1); assert.equal(f.sdk.records.length, 0);
  assert.equal(f.io.events.filter(event => candidate(event)).length, 0);
});

for (const stage of ['before', 'after']) test('E4 loaded complete plus C sticky close fault (' + stage + ' native close) quarantines owner', OPTIONS, async t => {
  const f = await fixture(t), input = f.input();
  await f.seed(input, { complete: true, generation: 1 }); f.resetMetrics();
  let closing = null, observed = null;
  f.io[stage] = event => {
    if (!closing && event.op === 'close' && stateSlot(event)) { closing = event; throw sdkError(13900005); }
  };
  f.hooks.afterLoad = loaded => { observed = plain(loaded); };
  f.expectedLeakedHandles = stage === 'before' ? 1 : 0;
  const result = await f.result(f.make(input));
  assert.ok(closing); assert.equal(observed.status, 'loaded');
  assert.ok(observed.state.parts.every(part => part.complete));
  assert.equal(result.kind, 'resourceFault'); assert.equal(result.ready, null);
  assert.equal(result.errorCode, 'AdaptiveCheckpointResourceUncertain');
  assert.equal(result.ownerDisposition, 'quarantined');
  assert.equal(result.durableState.generation, 1);
  assert.equal(f.metrics.stores.at(-1).hasUncertainResources(), true);
  assert.equal(f.metrics.saveCalls, 0); assert.equal(f.metrics.gateCount, 0);
  assert.equal(f.metrics.constructed.length, 0); assert.equal(f.sdk.records.length, 0);
  assert.equal(f.io.events.filter(event => event.op === 'close' && event.fd === closing.fd && event.path === closing.path).length, 1);
  const newer = await f.result(f.make(f.input(undefined, { id: input.downloadId })));
  assert.equal(newer.errorCode, 'AdaptiveOwnerQuarantined'); assert.equal(f.metrics.loadCalls, 1);
});

test('E4 ordinary C IO error without uncertain close releases its directory after the real barrier', OPTIONS, async t => {
  const f = await fixture(t), input = f.input();
  f.io.before = event => { if (event.op === 'lstat') throw sdkError(13900012); };
  const result = await f.result(f.make(input));
  assert.equal(result.kind, 'failed'); assert.equal(result.errorCode, 'AdaptiveCheckpointIoError');
  assert.equal(result.ownerDisposition, 'released'); assert.equal(result.ready, null);
  assert.equal(f.metrics.stores.at(-1).hasUncertainResources(), false);
  assert.equal(f.metrics.saveCalls, 0); assert.equal(f.sdk.records.length, 0);
  f.io.before = null;
  const retryInput = f.input(undefined, { id: input.downloadId }); retryInput.freshPlan = null;
  const retry = await f.result(f.make(retryInput));
  assert.equal(retry.errorCode, 'AdaptivePlanMissing'); assert.equal(f.metrics.loadCalls, 2);
});

for (const stage of ['before', 'after']) test('E4 E2 candidate close fault (' + stage + ' native close) cannot become ordinary E1 completion', OPTIONS, async t => {
  const f = await fixture(t), body = Buffer.from('body');
  const server = await f.server(serve(body)), input = f.input(server.url + '/close.ts');
  let closing = null;
  f.io[stage] = event => {
    if (!closing && event.op === 'close' && candidate(event)) { closing = event; throw sdkError(13900005); }
  };
  f.expectedLeakedHandles = stage === 'before' ? 1 : 0;
  const result = await f.result(f.make(input));
  assert.ok(closing); assert.equal(result.kind, 'resourceFault');
  assert.equal(result.ownerDisposition, 'quarantined'); assert.equal(result.ready, null);
  assert.equal(result.durableState.generation, 0);
  assert.equal(result.durableState.parts[0].downloaded, 0);
  assert.equal(result.durableState.parts[0].complete, false);
  assert.equal(f.metrics.saveCalls, 1);
  const newer = await f.result(f.make(f.input(server.url + '/close.ts', { id: input.downloadId })));
  assert.equal(newer.errorCode, 'AdaptiveOwnerQuarantined');
});

test('E4 Session API close rejection quarantines even after native socket closure', OPTIONS, async t => {
  const f = await fixture(t, { sdk: { closeThrow: true } });
  const server = await f.server(serve(Buffer.from('body'))), input = f.input(server.url + '/network-close.ts');
  const result = await f.result(f.make(input));
  assert.equal(result.kind, 'resourceFault'); assert.equal(result.ownerDisposition, 'quarantined');
  assert.equal(result.ready, null); assert.equal(result.durableState.parts[0].complete, false);
  assert.equal(f.sdk.records[0].closeCalls, 1);
});

for (const stage of ['before', 'after']) test('E4 pause across admitted initial rename (' + stage + ') acknowledges the actual saved commit', OPTIONS, async t => {
  const f = await fixture(t), gate = f.gate(), input = f.input(), run = f.make(input);
  let reached = false;
  f.io[stage] = async event => {
    if (!reached && event.op === 'rename') { reached = true; run.pause(); await gate.promise; }
  };
  const work = f.result(run); await until(() => reached);
  await remainsPending(run.drain()); assert.equal(f.sdk.records.length, 0);
  gate.resolve(); const result = await work;
  assert.equal(result.kind, 'paused'); assert.equal(result.ownerDisposition, 'released');
  assert.equal(result.durableState.generation, 0); assert.equal(f.metrics.saveCalls, 1);
  f.io[stage] = null;
  assert.deepEqual(plain((await f.newStore(input).load()).state), plain(result.durableState));
});

test('E4 pause across final checkpoint rename waits and preserves newly committed complete parts', OPTIONS, async t => {
  const f = await fixture(t), gate = f.gate(), body = Buffer.from('final');
  const server = await f.server(serve(body)), input = f.input(server.url + '/final.ts'), run = f.make(input);
  let renames = 0, reached = false;
  f.io.after = async event => {
    if (event.op === 'rename' && ++renames === 2) { reached = true; run.pause(); await gate.promise; }
  };
  const work = f.result(run); await until(() => reached); await remainsPending(run.drain());
  gate.resolve(); const result = await work;
  assert.equal(result.kind, 'paused'); assert.equal(result.ready, null);
  assert.equal(result.durableState.generation, 1); assert.equal(result.durableState.parts[0].complete, true);
  assert.equal(result.ownerDisposition, 'released'); assert.equal(f.metrics.saveCalls, 2);
});

test('E4 pause preserves actual partial bytes, ignores later physical tail, and resumes with the loaded plan', OPTIONS, async t => {
  const f = await fixture(t), body = Buffer.alloc(160000);
  for (let i = 0; i < body.length; i++) body[i] = i % 251;
  const server = await f.server((request, response, count) => {
    if (count === 1) {
      response.writeHead(200, { 'Content-Length': body.length }); response.write(body.subarray(0, 65536));
    } else {
      const start = Number(/^bytes=(\d+)-$/.exec(request.headers.range)[1]);
      response.writeHead(206, { 'Content-Length': body.length - start, 'Content-Range': `bytes ${start}-${body.length - 1}/${body.length}` });
      response.end(body.subarray(start));
    }
  });
  const input = f.input(server.url + '/resume.ts'), run = f.make(input);
  let paused = false;
  f.io.after = event => {
    if (!paused && event.op === 'write' && candidate(event)) { paused = true; run.pause(); }
  };
  const first = await f.result(run);
  assert.equal(first.kind, 'paused'); assert.equal(first.ownerDisposition, 'released');
  const oldPart = first.durableState.parts[0];
  assert.ok(oldPart.downloaded > 0 && oldPart.downloaded < body.length);
  assert.equal(oldPart.complete, false);
  const oldPath = path.join(f.root, input.downloadId, oldPart.fileName);
  assert.deepEqual(await fs.readFile(oldPath), body.subarray(0, oldPart.downloaded));
  await fs.appendFile(oldPath, Buffer.from('UNCOMMITTED TAIL'));
  const oldBytes = await fs.readFile(oldPath);
  f.io.after = null;
  const next = f.input(server.url + '/resume.ts', { id: input.downloadId }); next.freshPlan = null;
  const complete = await f.result(f.make(next));
  await assertReady(f, next, complete, [body]);
  assert.equal(server.requests.length, 2);
  assert.equal(server.requests[1].headers.range, 'bytes=' + oldPart.downloaded + '-');
  assert.notEqual(complete.durableState.parts[0].fileName, oldPart.fileName);
  assert.deepEqual(await fs.readFile(oldPath), oldBytes);
});

test('E4 copies request headers, plan and limits before the caller mutates them', OPTIONS, async t => {
  const f = await fixture(t), body = Buffer.from('copy');
  const server = await f.server(serve(body));
  const context = new f.context.DownloadRequestContext();
  context.headers = { names: ['X-Revision'], values: [['committed']] }; context.cookies = 'run=original';
  const input = f.input(server.url + '/copied.ts', { context, revision: 4 }), run = f.make(input);
  context.headers.values[0][0] = 'mutable'; context.cookies = 'run=changed';
  input.request.url = 'https://mutated.example/'; input.request.revision = -1;
  input.freshPlan.chunks[0].url = 'https://mutated.example/'; input.limits.maxSegments = 0;
  const result = await f.result(run);
  await assertReady(f, input, result, [body]);
  assert.equal(server.requests.length, 1); assert.equal(server.requests[0].headers['x-revision'], 'committed');
  assert.equal(server.requests[0].headers.cookie, 'run=original');
  assert.equal(result.durableState.plan.chunks[0].url, server.url + '/copied.ts');
});

for (const succeeds of [true, false]) test('E4 real E1 retry budget and shared gate: ' + (succeeds ? 'retry completes' : 'budget exhaustion'), OPTIONS, async t => {
  const f = await fixture(t), body = Buffer.from('retried');
  const server = await f.server((_request, response, count) => {
    response.writeHead(succeeds && count === 3 ? 200 : 503, { 'Content-Length': body.length }); response.end(body);
  });
  const input = f.input(server.url + '/retry.ts', { retries: 2, retryDelayMs: 3 });
  const result = await f.result(f.make(input));
  assert.equal(server.requests.length, 3); assert.equal(f.metrics.constructed.length, 3);
  assert.equal(f.metrics.gateCount, 1);
  assert.deepEqual(f.metrics.constructed.map(item => item.identity.attemptId), [1, 2, 3]);
  if (succeeds) await assertReady(f, input, result, [body]);
  else {
    assert.equal(result.kind, 'failed'); assert.equal(result.errorCode, 'RetryBudgetExhausted');
    assert.equal(result.ownerDisposition, 'released'); assert.equal(result.ready, null);
    assert.equal(result.durableState.parts[0].complete, false);
  }
});

test('E4 pause before ready attachment rejects reader admission but retains a releasable lease', OPTIONS, async t => {
  const f = await fixture(t), input = f.input(); await f.seed(input, { complete: true });
  const run = f.make(input), ready = (await f.result(run)).ready;
  let notified = 0;
  run.pause(); run.pause();
  assert.equal(ready.lease.isCurrent(), true); assert.equal(ready.lease.isStopRequested(), true);
  assert.equal(ready.lease.attachReader(() => notified++), false); assert.equal(notified, 0);
  assert.equal((await run.drain()).kind, 'ready');
  assert.equal(ready.lease.release(), true); assert.equal(ready.lease.release(), false);
  assert.equal(ready.lease.isCurrent(), false);
});

test('E4 attached reader is notified once while E4 drain remains independent of actual downstream drain', OPTIONS, async t => {
  const f = await fixture(t), input = f.input(), reader = f.gate(); await f.seed(input, { complete: true });
  const run = f.make(input), result = await f.result(run), lease = result.ready.lease;
  let notified = 0;
  assert.equal(lease.attachReader(null), false);
  assert.equal(lease.attachReader(() => { notified++; }), true);
  assert.equal(lease.attachReader(() => { notified++; }), false);
  run.pause(); run.pause(); assert.equal(notified, 1); assert.equal(lease.isStopRequested(), true);
  assert.equal((await within(run.drain(), 1000)).kind, 'ready'); await remainsPending(reader.promise);
  assert.equal(lease.isCurrent(), true);
  const blocked = await f.result(f.make(f.input(undefined, { id: input.downloadId })));
  assert.equal(blocked.errorCode, 'AdaptiveOwnerBusy');
  reader.resolve(); await reader.promise;
  assert.equal(lease.release(), true);
  const newerRun = f.make(f.input(undefined, { id: input.downloadId }));
  const newer = await f.result(newerRun);
  assert.equal(newer.kind, 'ready'); assert.equal(newer.ready.lease.isStopRequested(), false);
  assert.equal(lease.release(), false); lease.quarantine('OldReaderFault'); run.pause();
  assert.equal(newer.ready.lease.isCurrent(), true); assert.equal(newer.ready.lease.isStopRequested(), false);
});

test('E4 throwing reader stop callback does not infer closure or release its owner', OPTIONS, async t => {
  const f = await fixture(t), input = f.input(); await f.seed(input, { complete: true });
  const run = f.make(input), result = await f.result(run), lease = result.ready.lease;
  let calls = 0;
  assert.equal(lease.attachReader(() => { calls++; throw new Error('private reader error'); }), true);
  assert.doesNotThrow(() => { run.pause(); run.pause(); });
  assert.equal(calls, 1); assert.equal(lease.isCurrent(), true);
  assert.equal((await run.drain()).kind, 'ready');
  const blocked = await f.result(f.make(f.input(undefined, { id: input.downloadId })));
  assert.equal(blocked.errorCode, 'AdaptiveOwnerBusy');
  lease.quarantine('ReaderCloseUncertain'); assert.equal(lease.release(), false);
  assert.equal(lease.isCurrent(), false); assert.equal(calls, 1);
  const quarantined = await f.result(f.make(f.input(undefined, { id: input.downloadId })));
  assert.equal(quarantined.errorCode, 'AdaptiveOwnerQuarantined');
  assert.equal((await run.drain()).kind, 'ready');
});

test('E4 one pending snapshot of A v1 merges newer A v2 and B v1 into the next durable generation', OPTIONS, async t => {
  const f = await fixture(t), saveGate = f.gate();
  const a = Buffer.from('abcdefgh'), b = Buffer.from('BEEF');
  let aRequests = 0, bResponse = null, offset = 0, held = false;
  const server = await f.server((request, response) => {
    if (request.url === '/a.ts') {
      aRequests++;
      if (aRequests === 1) {
        response.writeHead(200, { 'Content-Length': a.length }); response.write(a.subarray(0, 4));
        setTimeout(() => response.destroy(), 20);
      } else {
        const from = Number(/^bytes=(\d+)-$/.exec(request.headers.range)[1]);
        response.writeHead(206, { 'Content-Length': a.length - from, 'Content-Range': `bytes ${from}-${a.length - 1}/${a.length}` });
        response.end(a.subarray(from));
      }
    } else { bResponse = response; response.writeHead(200, { 'Content-Length': b.length }); response.flushHeaders(); }
  });
  const input = f.input([server.url + '/a.ts', server.url + '/b.ts'], { lanes: 2, retries: 1, retryDelayMs: 150 });
  const run = f.make(input, { clock: () => Math.floor(performance.now()) + 1 + offset });
  f.hooks.beforeExecutorRun = () => { offset = 3000; };
  f.io.before = async event => {
    if (!held && event.op === 'rename' && f.metrics.saveCalls === 2) {
      held = true; await saveGate.promise;
    }
  };
  const work = f.result(run);
  await until(() => held && bResponse !== null);
  assert.equal(f.metrics.saves[1].parts[0].downloaded, 4);
  assert.equal(f.metrics.saves[1].parts[0].complete, false);
  assert.equal(f.metrics.saves[1].parts[1].downloaded, 0);
  const committedV1 = f.metrics.saves[1].parts[0].fileName;
  bResponse.end(b);
  await until(() => f.metrics.attemptResults.filter(value => value.settlement?.outcome === 'complete').length === 2);
  await remainsPending(run.drain());
  assert.equal(f.metrics.saveCalls, 2); assert.equal(f.metrics.maxPendingSaves, 1);
  saveGate.resolve();
  const result = await work;
  await assertReady(f, input, result, [a, b]);
  assert.equal(result.durableState.generation, 2); assert.equal(f.metrics.saveCalls, 3);
  assert.deepEqual(f.metrics.saves.map(value => value.expected), [-1, 0, 1]);
  assert.deepEqual(f.metrics.saves.map(value => value.generation), [0, 0, 1]);
  assert.deepEqual(f.metrics.saves[2].parts.map(value => value.downloaded), [8, 4]);
  assert.ok(f.metrics.saves[2].parts.every(value => value.complete));
  assert.notEqual(result.durableState.parts[0].fileName, committedV1);
  assert.deepEqual(await fs.readFile(path.join(f.root, input.downloadId, committedV1)), a.subarray(0, 4));
  assert.equal(f.metrics.gateCount, 1); assert.equal(aRequests, 2);
  observations.coalescing = { saveCount: f.metrics.saveCalls, maxPendingSaves: f.metrics.maxPendingSaves,
    expectedGenerations: f.metrics.saves.map(value => value.expected),
    capturedBytes: f.metrics.saves.map(value => value.parts.map(part => part.downloaded)),
    durableGeneration: result.durableState.generation };
});

test('E4 sticky C failure while a real E3 write remains pending neither spins nor finishes the barrier', OPTIONS, async t => {
  const f = await fixture(t), writeGate = f.gate();
  let offset = 0, bResponse = null, bFile = '', heldWrite = false, faulted = false;
  const server = await f.server((request, response) => {
    response.writeHead(200, { 'Content-Length': 4 });
    if (request.url === '/a.ts') response.end('AAAA');
    else { bResponse = response; response.flushHeaders(); }
  });
  const input = f.input([server.url + '/a.ts', server.url + '/b.ts'], { lanes: 2 });
  const run = f.make(input, { clock: () => Math.floor(performance.now()) + 1 + offset });
  f.hooks.afterExecutorConstructor = options => {
    if (options.dispatch.identity.chunkId === 'c1') bFile = options.dispatch.candidateFileName;
  };
  f.hooks.beforeExecutorRun = () => { offset = 3000; };
  f.hooks.beforeSave = (_state, expected) => { if (expected === 0) bResponse.end('BBBB'); };
  f.io.before = async event => {
    if (!heldWrite && event.op === 'write' && path.basename(event.path) === bFile) {
      heldWrite = true; await writeGate.promise;
    }
    if (!faulted && event.op === 'close' && staging(event) && f.metrics.saveCalls === 2) {
      await until(() => heldWrite); faulted = true; throw sdkError(13900005);
    }
  };
  f.expectedLeakedHandles = 1;
  const work = f.result(run); await until(() => faulted);
  await remainsPending(run.drain(), 50);
  assert.equal(f.metrics.stores.at(-1).hasUncertainResources(), true);
  assert.equal(f.metrics.saveCalls, 2);
  const blocked = await f.result(f.make(f.input(undefined, { id: input.downloadId })));
  assert.equal(blocked.errorCode, 'AdaptiveOwnerQuarantined');
  writeGate.resolve(); const result = await work;
  assert.equal(result.kind, 'resourceFault'); assert.equal(result.ownerDisposition, 'quarantined');
  assert.equal(result.durableState.generation, 0); assert.equal(result.ready, null);
  assert.equal(f.metrics.saveCalls, 2, 'sticky C must not receive a final save of safe siblings');
});

test('E4 pending source write blocks its own drain while another directory can independently complete', OPTIONS, async t => {
  const f = await fixture(t), gate = f.gate(), body = Buffer.from('writer');
  const server = await f.server(serve(body)), input = f.input(server.url + '/pending.ts');
  const independentInput = f.input(); await f.seed(independentInput, { complete: true });
  const run = f.make(input); let held = false;
  f.io.before = async event => {
    if (!held && event.op === 'write' && candidate(event)) { held = true; await gate.promise; }
  };
  const work = f.result(run); await until(() => held); run.pause();
  await remainsPending(run.drain());
  const independent = await f.result(f.make(independentInput));
  assert.equal(independent.kind, 'ready');
  await remainsPending(work); gate.resolve();
  const result = await work; assert.equal(result.kind, 'paused'); assert.equal(result.ownerDisposition, 'released');
});

test('E4 source failure preserves safe sibling parts before returning failed', OPTIONS, async t => {
  const f = await fixture(t), writeGate = f.gate();
  let failResponse = null, held = false;
  const server = await f.server((request, response) => {
    if (request.url === '/good.ts') { response.writeHead(200, { 'Content-Length': 8 }); response.write('good'); }
    else { failResponse = response; }
  });
  const input = f.input([server.url + '/good.ts', server.url + '/bad.ts'], { lanes: 2 });
  const run = f.make(input);
  f.io.after = async event => {
    if (!held && event.op === 'write' && candidate(event)) { held = true; await writeGate.promise; }
  };
  const work = f.result(run); await until(() => held && failResponse);
  failResponse.writeHead(200, { 'Content-Encoding': 'gzip', 'Content-Length': 0 }); failResponse.end();
  await until(() => f.metrics.attemptResults.some(value => value.settlement?.outcome === 'fatal'));
  await remainsPending(run.drain()); writeGate.resolve();
  const result = await work;
  assert.equal(result.kind, 'failed'); assert.equal(result.ownerDisposition, 'released');
  assert.equal(result.ready, null); assert.equal(result.durableState.parts[0].downloaded, 4);
  assert.equal(result.durableState.parts[0].complete, false);
  assert.deepEqual(await fs.readFile(path.join(f.root, input.downloadId, result.durableState.parts[0].fileName)), Buffer.from('good'));
  assert.equal(f.metrics.gateCount, 1);
});

test('E4 finalized runs preserve E3 detached fetch permits until those actual fetches settle', OPTIONS, async t => {
  const f = await fixture(t, { sdk: { neverSettle: true } });
  const server = await f.server(serve(Buffer.alloc(65536, 7)));
  const original = f.input(server.url + '/detached.ts');
  for (let i = 0; i < 2; i++) {
    const input = f.input(server.url + '/detached.ts', { id: original.downloadId });
    const run = f.make(input); let paused = false;
    f.io.after = event => { if (!paused && event.op === 'write' && candidate(event)) { paused = true; run.pause(); } };
    const result = await f.result(run);
    assert.equal(result.kind, 'paused'); assert.equal(result.ownerDisposition, 'released');
    assert.equal(f.stream.adaptiveRcpAdmissionSnapshot().pending, i + 1);
    assert.equal(f.sdk.records[i].fetchSettled, false); assert.equal(f.sdk.records[i].closed, true);
  }
  for (const record of f.sdk.records) record.forceReject();
  await until(() => f.stream.adaptiveRcpAdmissionSnapshot().pending === 0);
  assert.equal(f.metrics.gateCount, 2);
});

test('E4 dense actual completions share one gate and bounded checkpoint requests', OPTIONS, async t => {
  const f = await fixture(t), body = Buffer.from('dense');
  const server = await f.server(serve(body));
  const input = f.input(Array.from({ length: 64 }, (_, i) => server.url + '/' + i + '.ts'), { lanes: 8 });
  const result = await f.result(f.make(input));
  await assertReady(f, input, result);
  assert.equal(server.requests.length, 64); assert.equal(f.metrics.constructed.length, 64);
  assert.equal(f.metrics.gateCount, 1); assert.equal(f.metrics.maxPendingSaves, 1);
  assert.ok(f.metrics.saveCalls <= 3, 'ordinary dense callbacks must not encode one full state per completion');
  assert.equal(result.durableState.parts.reduce((sum, value) => sum + value.downloaded, 0), body.length * 64);
});

test('E4 long unsealed progress honestly remains outside durable checkpoints beyond two seconds', OPTIONS, async t => {
  const f = await fixture(t), body = Buffer.alloc(65536, 3);
  const server = await f.server((_request, response) => {
    response.writeHead(200, { 'Content-Length': body.length * 4 }); response.write(body);
  });
  const input = f.input(server.url + '/live.ts', { timeoutSeconds: 15 }), run = f.make(input);
  const work = f.result(run);
  await until(() => f.io.events.filter(event => event.op === 'write' && candidate(event) && event.ok)
    .reduce((sum, event) => sum + event.count, 0) === body.length);
  const began = performance.now(); await sleep(2200);
  const elapsed = performance.now() - began;
  assert.equal(f.metrics.saveCalls, 1);
  const initialPath = f.io.events.find(event => event.op === 'rename' && event.ok).to;
  const persisted = JSON.parse(await fs.readFile(initialPath, 'utf8'));
  assert.equal(persisted.parts[0].downloaded, 0); assert.equal(persisted.parts[0].complete, false);
  run.pause(); const result = await work;
  assert.equal(result.kind, 'paused'); assert.equal(result.durableState.parts[0].downloaded, body.length);
  assert.equal(result.durableState.parts[0].complete, false); assert.equal(f.metrics.saveCalls, 2);
  observations.sealedOnly = { scope: 'sealed-only limitation, real host time', uncheckpointedBytes: body.length,
    observedUnsealedWindowMs: Math.round(elapsed), periodicLiveCheckpoint: false };
  t.diagnostic(JSON.stringify(observations.sealedOnly));
});

test('E4 a throwing capture-end clock cannot discard an already admitted successful C save', OPTIONS, async t => {
  const f = await fixture(t), input = f.input(); let clockCalls = 0;
  const run = f.make(input, { clock: () => {
    clockCalls++; if (clockCalls === 2) throw new Error('private clock failure'); return 100 + clockCalls;
  } });
  const result = await f.result(run);
  assert.equal(result.kind, 'failed'); assert.equal(result.errorCode, 'InvalidAdaptiveClock');
  assert.equal(result.durableState.generation, 0); assert.equal(result.ownerDisposition, 'released');
  assert.equal(f.metrics.saveCalls, 1); assert.equal(f.metrics.saves[0].result.status, 'saved');
  assert.equal(f.sdk.records.length, 0);
});

test('E4 invalid stored state is not treated as empty or overwritten with a fresh plan', OPTIONS, async t => {
  const f = await fixture(t), input = f.input();
  await f.seed(input, { generation: 1 });
  const slots = f.io.events.filter(event => event.op === 'rename' && event.ok).map(event => event.to);
  for (const file of slots) await fs.writeFile(file, 'corrupt');
  f.resetMetrics();
  const result = await f.result(f.make(input));
  assert.equal(result.kind, 'failed'); assert.equal(result.errorCode, 'AdaptiveCheckpointInvalid');
  assert.equal(result.ownerDisposition, 'released'); assert.equal(f.metrics.saveCalls, 0);
  for (const file of slots) assert.equal(await fs.readFile(file, 'utf8'), 'corrupt');
});

test('E4 busy bootstrap consumes the actual bounded C admission result without retry spinning', OPTIONS, async t => {
  const f = await fixture(t), input = f.input(), gate = f.gate();
  let held = false;
  f.io.before = async event => { if (!held && event.op === 'lstat') { held = true; await gate.promise; } };
  const first = f.newStore(input).load(), second = f.newStore(input).load();
  await until(() => held);
  const result = await f.result(f.make(input));
  assert.equal(result.kind, 'failed'); assert.equal(result.errorCode, 'AdaptiveCheckpointBusy');
  assert.equal(result.ownerDisposition, 'released'); assert.equal(f.metrics.saveCalls, 0);
  assert.equal(f.io.events.length, 1);
  gate.resolve(); assert.equal((await first).status, 'empty'); assert.equal((await second).status, 'empty');
});

test('E4 a real competing C generation causes final conflict without rebase or ready', OPTIONS, async t => {
  const f = await fixture(t); let response = null;
  const server = await f.server((_request, value) => { response = value; });
  const input = f.input(server.url + '/conflict.ts'), seeded = await f.seed(input);
  f.resetMetrics(); const run = f.make(input), work = f.result(run);
  await until(() => response !== null);
  const other = f.newStore(input), competing = await other.save(seeded.state, seeded.state.generation);
  assert.equal(competing.status, 'saved'); assert.equal(competing.state.generation, 1);
  response.writeHead(200, { 'Content-Length': 4 }); response.end('data');
  const result = await work;
  assert.equal(result.kind, 'failed'); assert.equal(result.errorCode, 'AdaptiveCheckpointConflict');
  assert.equal(result.ownerDisposition, 'released'); assert.equal(result.ready, null);
  assert.equal(result.durableState.generation, 0); assert.equal(result.durableState.parts[0].downloaded, 0);
  const persisted = await f.newStore(input).load();
  assert.deepEqual(plain(persisted.state), plain(competing.state));
  assert.equal(f.metrics.saves.at(-1).result.status, 'conflict');
});

test('E4 zero-IO executor construction failure stops and drains the other claimed handles', OPTIONS, async t => {
  const f = await fixture(t);
  const input = f.input(['https://run.example/a.ts', 'https://run.example/b.ts'], { lanes: 2 });
  f.hooks.afterExecutorConstructor = options => {
    if (options.dispatch.identity.chunkId === 'c0') throw new Error('private constructor error');
  };
  const result = await f.result(f.make(input));
  assert.equal(result.kind, 'failed'); assert.equal(result.errorCode, 'AdaptiveExecutorConstructionFailed');
  assert.equal(result.ownerDisposition, 'released'); assert.equal(result.ready, null);
  assert.equal(f.metrics.constructed.length, 2); assert.equal(f.sdk.records.length, 0);
  assert.equal(f.metrics.attemptResults.length, 1);
});

test('E4 an actual disposed executor is a failed run and cannot masquerade as ordinary pause', OPTIONS, async t => {
  const f = await fixture(t), input = f.input();
  f.hooks.beforeExecutorRun = executor => executor.dispose();
  const result = await f.result(f.make(input));
  assert.equal(result.kind, 'failed'); assert.equal(result.errorCode, 'AdaptiveAttemptDisposed');
  assert.equal(result.ownerDisposition, 'released'); assert.equal(result.ready, null);
  assert.equal(f.sdk.records.length, 0); assert.equal(f.metrics.attemptResults[0].kind, 'disposed');
});

test('E4 explicit quarantine sends the first reader stop once and permanently retains the original owner', OPTIONS, async t => {
  const f = await fixture(t), input = f.input(); await f.seed(input, { complete: true });
  const run = f.make(input), result = await f.result(run), lease = result.ready.lease;
  let calls = 0;
  assert.equal(lease.attachReader(() => { calls++; assert.equal(lease.isStopRequested(), true); }), true);
  lease.quarantine('ReaderResourceUncertain'); lease.quarantine('SecondFault'); run.pause();
  assert.equal(calls, 1); assert.equal(lease.isCurrent(), false); assert.equal(lease.release(), false);
  assert.equal((await run.drain()).kind, 'ready');
  const blocked = await f.result(f.make(f.input(undefined, { id: input.downloadId })));
  assert.equal(blocked.errorCode, 'AdaptiveOwnerQuarantined');
});

test('E4 ready capability allocation failure returns a fixed failure after safe C closure', OPTIONS, async t => {
  const f = await fixture(t), input = f.input(); await f.seed(input, { complete: true });
  f.util.generateRandomUUID = () => { throw new Error('private UUID failure'); };
  const result = await f.result(f.make(input));
  assert.equal(result.kind, 'failed'); assert.equal(result.errorCode, 'AdaptiveReadyFailed');
  assert.equal(result.ownerDisposition, 'released'); assert.equal(result.ready, null);
  assert.equal(result.durableState.parts[0].complete, true);
});

test('E4 maximum 20000-chunk plan records full synchronous capture, actual IO and pause scheduling cost', { timeout: 60000 }, async t => {
  const f = await fixture(t), playlist = new f.models.HlsPlaylist();
  for (let i = 0; i < f.parser.HLS_MAX_SEGMENTS; i++) {
    const segment = new f.models.HlsMediaSegment(); segment.url = 'https://size.example/s.ts'; segment.sequence = i;
    playlist.segments.push(segment);
  }
  const built = f.plan.buildHlsPlan('https://size.example/video.m3u8', playlist, 'https://size.example/audio.m3u8', playlist);
  assert.ok(built); assert.equal(built.chunks.length, 20000);
  let remaining = f.plan.ADAPTIVE_MAX_PLAN_CHARS - JSON.stringify(built).length;
  for (const chunk of built.chunks) {
    const count = Math.min(remaining, f.models.HLS_MAX_URL_CHARS - chunk.url.length);
    chunk.url = chunk.url.slice(0, -4) + 'x'.repeat(count) + 's.ts'; remaining -= count;
    if (remaining === 0) break;
  }
  assert.equal(remaining, 0); assert.equal(JSON.stringify(built).length, f.plan.ADAPTIVE_MAX_PLAN_CHARS);
  const input = f.input(); input.freshPlan = built;
  let lastClockSample = 0, captureBegan = null, captureEnd = 0, fullCaptureMs = 0;
  let pauseScheduled = 0, pauseObserved = 0, ioMs = 0;
  const beganConstructor = performance.now();
  const run = f.make(input, { clock: () => {
    const sample = performance.now();
    if (captureBegan !== null) { fullCaptureMs = sample - captureBegan; captureBegan = null; captureEnd = sample; }
    lastClockSample = sample; return Math.floor(sample) + 1;
  } });
  const constructorMs = performance.now() - beganConstructor;
  f.hooks.beforeSave = () => {
    captureBegan = lastClockSample; pauseScheduled = performance.now();
    setTimeout(() => { pauseObserved = performance.now(); run.pause(); }, 0);
  };
  f.hooks.afterSave = () => { ioMs = performance.now() - captureEnd; };
  const gaps = []; let heartbeatAt = performance.now();
  const heartbeat = setInterval(() => { const now = performance.now(); gaps.push(now - heartbeatAt); heartbeatAt = now; }, 10);
  let result;
  const beganRun = performance.now();
  try { result = await within(run.run(), 45000); await sleep(1); }
  finally { clearInterval(heartbeat); }
  const runMs = performance.now() - beganRun;
  assert.equal(result.kind, 'paused'); assert.equal(result.ownerDisposition, 'released');
  assert.equal(result.durableState.generation, 0); assert.equal(result.durableState.parts.length, 20000);
  assert.equal(f.metrics.saveCalls, 1); assert.equal(f.metrics.maxPendingSaves, 1);
  assert.equal(f.metrics.constructed.length, 0); assert.equal(f.sdk.records.length, 0);
  assert.ok(fullCaptureMs > 0); assert.ok(pauseObserved >= captureEnd);
  observations.maximumPlan = { scope: 'host, maximum canonical plan with empty parts; full C populated-state bound is separate',
    chunks: 20000, planChars: f.plan.ADAPTIVE_MAX_PLAN_CHARS, stateChars: JSON.stringify(result.durableState).length,
    constructorMs: Math.round(constructorMs), fullSynchronousCaptureMs: Math.round(fullCaptureMs),
    cSynchronousCaptureMs: Math.round(f.metrics.captures[0]), actualSaveAwaitMs: Math.round(ioMs),
    pauseTimerDelayMs: Math.round(pauseObserved - pauseScheduled),
    maxHeartbeatGapMs: Math.round(Math.max(...gaps)), runMs: Math.round(runMs),
    note: 'synchronous state capture and terminal DTO copies block this host event loop; no target latency guarantee' };
  t.diagnostic(JSON.stringify(observations.maximumPlan));
});
