'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const { fixture, VirtualClock, plain, bytes, sdkError, sleep, deferred, flush, within, until, digest, sourceManifest } = require('./adaptive-stream-harness.cjs');
const OPTIONS = { concurrency: false, timeout: 30000 };
let startManifest;
test.before(async () => { startManifest = await sourceManifest(); });
test.after(async () => {
  const endManifest = await sourceManifest();
  assert.deepEqual(endManifest, startManifest, 'the production and harness sources stayed fixed during this run');
  if (process.env.E3_HOST_REPORT) await fs.writeFile(process.env.E3_HOST_REPORT,
    JSON.stringify({ scope: 'actual production ETS + Node HTTP/FS; not target RCP evidence', sourceHashes: startManifest, sourcesUnchanged: true }, null, 2) + '\n');
});

function serveBody(body, status = 200, extra = {}) {
  return (_request, response) => { response.writeHead(status, { 'Content-Length': body.length, ...extra }); response.end(body); };
}
function assertClosed(f, result) {
  assert.equal(result.stream.allSessionsApiClosed, true); assert.equal(result.stream.resourceUncertain, false);
  assert.equal(result.stream.sessionCount, result.stream.apiClosedCount);
  assert.equal(f.io.handles.size, 0); assert.equal(f.io.pending, 0);
  if (result.file) { assert.equal(result.file.closed, true); assert.equal(result.file.resourceUncertain, false); }
}
async function assertComplete(f, claim, result, expected) {
  assert.equal(result.kind, 'settled'); assert.equal(result.settlement.outcome, 'complete', JSON.stringify(result));
  assert.equal(result.stream.eof, true); assert.equal(result.stream.sdkPromiseSettled, true);
  assert.equal(result.stream.fetchSucceeded, true); assert.equal(result.receivedExact, true);
  assert.equal(result.file.sealed, true); assertClosed(f, result);
  assert.deepEqual(await fs.readFile(claim.filePath), Buffer.from(expected));
  const accepted = claim.run.settle(result.settlement, 2);
  assert.equal(accepted.accepted, true); assert.equal(accepted.candidateAccepted, true);
}

for (const scenario of [
  { name: 'whole 200', body: Buffer.from('abcdef') },
  { name: 'empty whole 200', body: Buffer.alloc(0) },
  { name: '206 at remote offset with copied prefix', body: Buffer.from('EFGH'), length: 8, offset: 100, prefix: 'abcdTAIL', prefixBytes: 4,
    status: 206, extra: { 'Content-Range': 'bytes 104-107/1000' }, expected: 'abcdEFGH' },
  { name: 'ignored Range whole 200 resets old prefix', body: Buffer.from('NEW'), prefix: 'OLDPREFIX', expected: 'NEW' }
]) {
  test('H1/H4 ' + scenario.name + ' seals the actual file before E1 accepts it', OPTIONS, async t => {
    const f = await fixture(t), server = await f.server(serveBody(scenario.body, scenario.status, scenario.extra));
    const c = await f.claim(server.url + '/body.ts', scenario), result = await within(c.task.run());
    await assertComplete(f, c, result, scenario.expected ?? scenario.body);
    assert.equal(result.writtenBytes, scenario.body.length); assert.equal(result.receivedBytes, scenario.body.length);
    assert.equal(server.requests.length, 1); assert.equal(server.requests[0].headers['accept-encoding'], 'identity');
    if (scenario.prefix) assert.equal(await fs.readFile(path.join(c.directory, 'old.part'), 'utf8'), scenario.prefix);
    const operations = f.io.events.filter(event => event.path === c.filePath);
    assert.ok(operations.find(event => event.op === 'fsync').index < operations.find(event => event.op === 'close').index);
  });
}

test('H1 whole chunked 200 has exact received/written counts without Content-Length', OPTIONS, async t => {
  const f = await fixture(t), body = Buffer.alloc(100003, 47);
  const server = await f.server((_req, res) => { res.writeHead(200); res.write(body.subarray(0, 100)); res.end(body.subarray(100)); });
  const c = await f.claim(server.url + '/chunked.ts'), result = await within(c.task.run());
  await assertComplete(f, c, result, body); assert.equal(result.receivedBytes, body.length);
});

test('H2 16MiB ignored-Range 200 uses one bounded pull stream under slow real FS', OPTIONS, async t => {
  const f = await fixture(t), body = Buffer.alloc(16 * 1024 * 1024, 31);
  f.io.before = async event => { if (event.op === 'write') await sleep(1); };
  const server = await f.server(serveBody(body)), c = await f.claim(server.url + '/large.ts');
  const result = await within(c.task.run(), 20000); await assertComplete(f, c, result, body);
  assert.equal(server.requests.length, 1); assert.ok(f.sdk.records[0].pauses > 0); assert.ok(f.sdk.records[0].resumes > 0);
  assert.equal(f.sdk.queues.length, 1); assert.ok(f.sdk.queues[0].peak <= 65536);
  assert.ok(f.io.events.filter(e => e.op === 'write').every(e => e.requested <= 32768));
  assert.equal(f.io.peakPending, 1); assert.equal(f.stream.adaptiveRcpAdmissionSnapshot().pending, 0);
});

test('H1 real FS short writes and reads preserve exact prefix and body boundaries', OPTIONS, async t => {
  const f = await fixture(t); f.io.readLimit = 3; f.io.writeLimit = 5;
  const body = Buffer.alloc(1001, 76), prefix = Buffer.alloc(101, 42);
  const server = await f.server(serveBody(body, 206, { 'Content-Range': 'bytes 101-1101/1102' }));
  const c = await f.claim(server.url + '/short.ts', { prefix, length: 1102 });
  const result = await within(c.task.run()); await assertComplete(f, c, result, Buffer.concat([prefix, body]));
  assert.equal(result.writtenBytes, 1001); assert.equal(c.gate.snapshot().writtenBytes, 1001);
});

for (const scenario of [
  { status: 200, length: 4, code: 'RangeNotHonored' },
  { status: 206, length: 4, extra: { 'Content-Range': 'bytes 1-4/10' }, code: 'RangeMismatch' },
  { status: 200, extra: { 'Content-Encoding': 'gzip' }, code: 'UnsupportedEncoding' },
  { status: 401, code: 'AuthOrSession', outcome: 'retryable' }, { status: 403, code: 'AuthOrSession', outcome: 'retryable' },
  { status: 416, code: 'RangeUnsatisfied', outcome: 'retryable' }, { status: 404, code: 'InvalidResponse', outcome: 'retryable' },
  { status: 204, code: 'InvalidResponse' },
  { status: 429, outcome: 'retryable' }, { status: 503, outcome: 'retryable' }
]) {
  test('H4 rejects/classifies HTTP ' + JSON.stringify(scenario) + ' before file IO', OPTIONS, async t => {
    const f = await fixture(t), server = await f.server(serveBody(Buffer.from('abcd'), scenario.status, scenario.extra));
    const c = await f.claim(server.url + '/bad.ts', scenario), result = await within(c.task.run());
    assert.equal(result.settlement.outcome, scenario.outcome || 'fatal');
    if (scenario.code) assert.equal(result.settlement.errorCode, scenario.code);
    assert.equal(f.io.events.length, 0); assert.equal(result.file, null); assertClosed(f, result);
  });
}

test('H5 real chunked 206 extra byte is not clamped or committed', OPTIONS, async t => {
  const f = await fixture(t);
  const server = await f.server((_req, res) => { res.writeHead(206, { 'Content-Range': 'bytes 0-3/4' }); res.write('abcd'); res.end('!'); });
  const c = await f.claim(server.url + '/extra.ts', { length: 4 }), result = await within(c.task.run());
  assert.equal(result.settlement.outcome, 'fatal'); assert.equal(result.settlement.errorCode, 'BodyTooLong');
  assert.ok(result.receivedBytes > 4); assert.equal(result.settlement.sealedPart, null); assertClosed(f, result);
});

for (const length of [1, 4]) {
  test('H5 full known L=' + length + ' without fetch success retains at most L-1', OPTIONS, async t => {
    const f = await fixture(t, { sdk: { neverSettle: true } }), body = Buffer.alloc(length, 90);
    const server = await f.server(serveBody(body, 206, { 'Content-Range': 'bytes 0-' + (length - 1) + '/' + length }));
    const c = await f.claim(server.url + '/no-eof.ts', { length, timeoutSeconds: 1 });
    const result = await within(c.task.run());
    assert.equal(result.settlement.outcome, 'retryable'); assert.equal(result.stream.eof, false);
    assert.equal(result.stream.sdkPromiseSettled, false); assert.equal(result.stream.detachedFetchCount, 1);
    assert.equal(result.settlement.sealedPart?.downloaded ?? 0, length - 1);
    if (length > 1) assert.equal((await fs.stat(c.filePath)).size, length - 1);
    assertClosed(f, result);
  });
}

for (const scenario of [
  { name: 'small header-first final response fallback', sdk: { headerFirst: true }, expected: 'complete' },
  { name: 'seven paired informational blocks', sdk: { informational: 7 }, expected: 'complete' },
  { name: 'eighth informational block exceeds event budget', sdk: { informational: 8 }, expected: 'fatal' },
  { name: 'duplicate accepted header pair', sdk: { duplicateHead: true }, expected: 'fatal' },
  // Device trace 2026-10-18 (P6-U5 S2): the SDK emits headers before status as well as after it; a large
  // header-first body must pair on the following status instead of waiting on a queue-paused fetch.
  { name: 'large header-first ordering pairs on the following status', sdk: { headerFirst: true }, size: 262144, expected: 'complete' },
  { name: 'large headers withheld until EOF', sdk: { lateHeaders: true }, size: 262144, expected: 'fatal' },
  { name: 'missing end after successful fetch', sdk: { noEnd: true }, expected: 'fatal' },
  { name: 'delayed end after successful fetch', sdk: { endDelay: 30 }, expected: 'complete' },
  { name: 'end before delayed successful fetch', sdk: { resolveDelay: 30 }, expected: 'complete' },
  { name: 'final metadata mismatch', sdk: { finalHeaders: { 'Content-Length': '2' } }, expected: 'fatal' }
]) {
  test('H5/H6 ' + scenario.name, OPTIONS, async t => {
    const f = await fixture(t, { sdk: scenario.sdk }), body = Buffer.alloc(scenario.size || 8, 42);
    const server = await f.server(serveBody(body)), c = await f.claim(server.url + '/order.ts', { timeoutSeconds: 1 });
    const result = await within(c.task.run()); assert.equal(result.settlement.outcome, scenario.expected, JSON.stringify(result));
    if (scenario.expected === 'complete') await assertComplete(f, c, result, body);
    else assert.equal(result.settlement.sealedPart, null);
    assertClosed(f, result);
  });
}

test('H7 explicit cross-origin redirect strips credentials permanently and closes the old hop', OPTIONS, async t => {
  const f = await fixture(t); let first, second;
  first = await f.server((req, res) => {
    if (req.url === '/start.ts') { res.writeHead(302, { Location: second.url + '/middle.ts' }); res.write('redirect'); }
    else { res.end('FINAL'); }
  });
  second = await f.server((_req, res) => { res.writeHead(307, { Location: first.url + '/last.ts' }); res.end(); });
  const context = new f.context.DownloadRequestContext();
  context.headers = { names: ['Authorization', 'Proxy-Authorization', 'Referer'], values: [['secret'], ['proxysecret'], ['https://page.invalid/']] };
  context.cookies = 'private=1';
  const c = await f.claim(first.url + '/start.ts', { context }), result = await within(c.task.run());
  await assertComplete(f, c, result, 'FINAL'); assert.equal(result.stream.sessionCount, 3);
  assert.equal(first.requests[0].headers.authorization, 'secret');
  for (const request of [second.requests[0], first.requests[1]]) {
    assert.equal(request.headers.authorization, undefined); assert.equal(request.headers['proxy-authorization'], undefined);
    assert.equal(request.headers.cookie, undefined); assert.equal(request.headers.referer, 'https://page.invalid/');
  }
  assert.ok(f.sdk.records.every(record => record.closeCalls === 1));
  assert.equal(result.receivedBytes, 5, 'redirect body is excluded');
});

for (const kind of ['stop', 'dispose', 'drain']) {
  test('H11 ' + kind + ' before run admits no IO and subsequent run cannot reopen', OPTIONS, async t => {
    const f = await fixture(t), c = await f.claim('http://127.0.0.1:1/unstarted.ts');
    if (kind !== 'drain') c.task[kind]();
    const result = await c.task.drain();
    assert.equal(result.kind, kind === 'dispose' ? 'disposed' : 'settled');
    assert.deepEqual(plain(await c.task.run()), plain(result)); assert.equal(f.sdk.records.length, 0); assert.equal(f.io.events.length, 0);
  });
}

test('H11 stop during actual append waits for IO and seals only a positive known partial', OPTIONS, async t => {
  const f = await fixture(t), entered = deferred(), release = deferred();
  const server = await f.server(serveBody(Buffer.alloc(131072, 9), 206, { 'Content-Range': 'bytes 0-131071/131072' }));
  const c = await f.claim(server.url + '/stop.ts', { length: 131072 });
  let first = true; f.io.before = async event => { if (first && event.op === 'write') { first = false; entered.resolve(); await release.promise; } };
  const work = c.task.run(); await within(entered.promise); c.run.requestPause(); c.task.stop(); await flush();
  assert.equal(f.io.pending, 1); release.resolve(); const result = await within(work);
  assert.equal(result.settlement.outcome, 'stopped'); assert.ok(result.settlement.sealedPart.downloaded > 0);
  assert.ok(result.settlement.sealedPart.downloaded < 131072); assertClosed(f, result);
  assert.equal(c.run.settle(result.settlement, 2).candidateAccepted, true);
});

for (const options of [{ cancelThrow: true }, { closeThrow: true }, { createThrow: 401 }, { queueThrow: true }, { fetchThrow: true }]) {
  test('H12 explicit resource facts for ' + JSON.stringify(options), OPTIONS, async t => {
    const f = await fixture(t, { sdk: options });
    const server = await f.server((_req, res) => { res.writeHead(200, { 'Content-Length': '10000' }); res.flushHeaders(); });
    const c = await f.claim(server.url + '/resource.ts', { timeoutSeconds: 1 }), result = await within(c.task.run());
    if (options.closeThrow) { assert.equal(result.kind, 'resourceFault'); assert.equal(result.settlement, null); }
    else { assert.equal(result.kind, 'settled'); assertClosed(f, result); }
    if (options.cancelThrow) assert.equal(result.stream.cancelCode, 401);
    assert.equal(f.stream.adaptiveRcpAdmissionSnapshot().pending, options.fetchThrow ? 1 : 0);
  });
}

test('H12 real file close failure is resourceFault even after network API closure', OPTIONS, async t => {
  const f = await fixture(t), server = await f.server(serveBody(Buffer.from('abc'))), c = await f.claim(server.url + '/close.ts');
  f.io.before = async event => { if (event.op === 'close') throw sdkError(13900005); };
  const result = await within(c.task.run());
  assert.equal(result.kind, 'resourceFault'); assert.equal(result.settlement, null);
  assert.equal(result.stream.allSessionsApiClosed, true); assert.equal(result.file.resourceUncertain, true);
  assert.equal(f.io.events.filter(e => e.op === 'close').length, 1);
});

test('H13 input and result copies protect identity, files and the frozen outcome', OPTIONS, async t => {
  const f = await fixture(t), server = await f.server(serveBody(Buffer.from('sealed'))), c = await f.claim(server.url + '/copy.ts');
  c.input.dispatch.identity.runToken = 'mutated'; c.input.dispatch.chunk.url = 'http://127.0.0.1:1/other';
  const result = await within(c.task.run()), preserved = plain(result);
  result.identity.runToken = 'evil'; result.settlement.sealedPart.downloaded = 999; result.stream.eof = false;
  assert.deepEqual(plain(await c.task.drain()), preserved); c.task.dispose(); assert.deepEqual(plain(await c.task.run()), preserved);
  assert.equal(await fs.readFile(c.filePath, 'utf8'), 'sealed'); assert.equal(server.requests.length, 1);
});

function identity(f, lane = 0, attempt = 1) {
  const value = new f.scheduler.AdaptiveAttemptIdentity(); value.downloadId = '01234567-89ab-cdef-0123-456789abcdef';
  value.runToken = 'gate'; value.chunkId = 'c' + lane; value.laneId = lane; value.attemptId = attempt; return value;
}

test('H9 actual shared helper enforces aggregate 1KiB/s for eight lanes and rebases paid sleeps', OPTIONS, async t => {
  const clock = new VirtualClock(), f = await fixture(t, { globals: { setTimeout: clock.setTimeout, clearTimeout: clock.clearTimeout } });
  const policy = new f.throttle.AdaptiveThrottlePolicy(); policy.taskKiBps = 1;
  const first = identity(f), gate = new f.throttle.AdaptiveDownloadThrottle(first.downloadId, first.runToken, 8, () => policy, clock.now); f.gates.push(gate);
  for (let index = 0; index < 64; index++) {
    const grant = await gate.acquire(identity(f, index % 8));
    assert.equal(grant.kind, 'granted'); const started = clock.time;
    await clock.finish(gate.finish(grant, 32768));
    if (index > 0) assert.equal(clock.time - started, 32000);
  }
  assert.equal(gate.snapshot().writtenBytes, 2097152); assert.equal(clock.time, 2016001);
  assert.ok(gate.snapshot().writtenBytes <= (clock.time - 1) * 1024 / 1000 + 65536);
});

test('H10 cancellation carries unpaid debt to another lane and rate updates reprice only that debt', OPTIONS, async t => {
  const clock = new VirtualClock(), f = await fixture(t, { globals: { setTimeout: clock.setTimeout, clearTimeout: clock.clearTimeout } });
  const policy = new f.throttle.AdaptiveThrottlePolicy(); policy.taskKiBps = 1;
  const id = identity(f), next = identity(f, 1), gate = new f.throttle.AdaptiveDownloadThrottle(id.downloadId, id.runToken, 2, () => policy, clock.now); f.gates.push(gate);
  await gate.finish(await gate.acquire(id), 32768);
  const grant = await gate.acquire(id), paying = gate.finish(grant, 32768); await flush(); gate.cancelAttempt(id);
  assert.equal((await paying).kind, 'canceled'); assert.equal(gate.snapshot().hasDebt, true);
  let granted = false; const waiting = gate.acquire(next).then(value => { granted = true; return value; });
  await clock.advance(1000); assert.equal(granted, false);
  policy.taskKiBps = 2; gate.refreshPolicy(); await clock.advance(14999); assert.equal(granted, false);
  await clock.advance(1); const held = await waiting; assert.equal(held.kind, 'granted');
  assert.equal((await gate.finish(grant, 0)).kind, 'fault', 'stale release cannot free new owner');
  assert.equal(gate.snapshot().pendingTickets, 1); await gate.finish(held, 0); assert.equal(gate.snapshot().pendingTickets, 0);
});

test('H8 normalization uses finite request budgets and does not mutate Config', OPTIONS, async t => {
  const f = await fixture(t);
  for (const pair of [[30, 30000], [0, 30000], [-1, 30000], [NaN, 30000], [Infinity, 30000], [0.1, 1000], [301, 300000]]) {
    assert.equal(f.executor.normalizeAdaptiveNetworkTimeout(pair[0]), pair[1]);
  }
  const server = await f.server(serveBody(Buffer.from('ok'))), c = await f.claim(server.url + '/time.ts');
  await within(c.task.run()); const timeout = f.sdk.records[0].configuration.requestConfiguration.transfer.timeout;
  assert.ok(timeout.transferMs > 2147480000 && timeout.transferMs <= 2147483647); assert.equal(timeout.inactivityMs, undefined);
});

test('H12 eight completed 30-redirect attempts retain 240 permits; all runs share the hard 256 admission cap', OPTIONS, async t => {
  const f = await fixture(t, { sdk: { forRequest: target => ({ neverSettle: Number(target.pathname.split('/').at(-1)) < 30 }) } });
  const server = await f.server((req, res) => {
    const current = Number(req.url.split('/').at(-1));
    if (current < 30) { res.writeHead(302, { Location: './' + (current + 1) }); res.write('unconsumed redirect body'); }
    else res.end('Z');
  });
  const delivered = [];
  for (let attempt = 0; attempt < 8; attempt++) {
    const c = await f.claim(server.url + '/attempt-' + attempt + '/0'), result = await within(c.task.run());
    await assertComplete(f, c, result, 'Z'); assert.equal(result.stream.detachedFetchCount, 30);
    assert.equal(f.stream.adaptiveRcpAdmissionSnapshot().pending, (attempt + 1) * 30);
    delivered.push({ task: c.task, result: plain(result) });
  }
  const initialRequests = server.requests.length, initialQueues = f.sdk.queues.length;
  const c = await f.claim(server.url + '/ninth/0'), result = await within(c.task.run());
  assert.equal(result.settlement.outcome, 'fatal'); assert.equal(result.errorCode, 'RcpPendingFetchLimit');
  assert.equal(result.stream.sessionCount, 16); assertClosed(f, result);
  assert.equal(server.requests.length - initialRequests, 16); assert.equal(f.sdk.queues.length - initialQueues, 16);
  assert.deepEqual(plain(f.stream.adaptiveRcpAdmissionSnapshot()), { limit: 256, pending: 256, highWater: 256 });
  const counts = [f.sdk.queues.length, f.sdk.records.length, server.requests.length];
  const denied = await f.claim(server.url + '/fresh-download/30'), rejected = await denied.task.run();
  assert.equal(rejected.errorCode, 'RcpPendingFetchLimit'); assert.equal(rejected.stream.sessionCount, 0);
  assert.deepEqual([f.sdk.queues.length, f.sdk.records.length, server.requests.length], counts);
  const old = f.sdk.records[0]; old.emit('onDataEnd', old.request); old.emit('onClosed', old.request);
  delivered[0].task.stop(); delivered[0].task.dispose(); await flush();
  assert.equal(f.stream.adaptiveRcpAdmissionSnapshot().pending, 256, 'API closure, end, stale notifications and disposal never release admission');
  old.forceResolve(); await flush(); assert.equal(f.stream.adaptiveRcpAdmissionSnapshot().pending, 255);
  old.forceResolve(); old.forceReject(); await flush(); assert.equal(f.stream.adaptiveRcpAdmissionSnapshot().pending, 255);
  const renewed = await f.claim(server.url + '/reused-permit/30'), resumed = await renewed.task.run();
  await assertComplete(f, renewed, resumed, 'Z'); assert.equal(f.stream.adaptiveRcpAdmissionSnapshot().pending, 255);
  f.sdk.records[1].forceReject(); await flush(); assert.equal(f.stream.adaptiveRcpAdmissionSnapshot().pending, 254);
  for (const previous of delivered) assert.deepEqual(plain(await previous.task.drain()), previous.result, 'late settlement never mutates delivered receipts');
  for (const record of f.sdk.records) record.forceReject(); await flush();
  assert.equal(f.stream.adaptiveRcpAdmissionSnapshot().pending, 0);
  t.diagnostic('E3_ADMISSION ' + JSON.stringify({ completedRedirectAttempts: 8, pendingAfterCompleted: 240,
    finalAttemptAdmitted: 16, highWater: 256, beforeAdmissionResourcesCreated: 0, finalPending: 0 }));
});

test('H12 preparation failures return admission only before fetch is invoked', OPTIONS, async t => {
  const f = await fixture(t);
  for (const option of [{ queueThrow: true }, { createThrow: 201 }, { createThrow: 401 }, { createThrow: 1007900994 }, { requestThrow: true }]) {
    Object.assign(f.sdk.options, option);
    const c = await f.claim('http://127.0.0.1:1/not-started.ts'), result = await c.task.run();
    assert.equal(result.settlement.outcome, 'fatal'); assertClosed(f, result);
    assert.equal(f.stream.adaptiveRcpAdmissionSnapshot().pending, 0);
    for (const key of Object.keys(option)) delete f.sdk.options[key];
  }
  assert.ok(f.sdk.records.every(record => record.closeCalls === 1));
});

test('H12 pre-fetch clock failures leave admission available to the next healthy download', OPTIONS, async t => {
  const f = await fixture(t);
  const server = await f.server(serveBody(Buffer.from('healthy')));
  for (const mode of ['throw', 'backwards']) {
    let reads = 0;
    const clock = () => {
      reads++;
      if (reads === 3) {
        if (mode === 'throw') throw new Error('Controlled clock failure before SDK preparation');
        return 9;
      }
      return 10 + reads;
    };
    const c = await f.claim(server.url + '/not-started.ts', { clock });
    const result = await within(c.task.run()); c.task.dispose(); await c.task.drain();
    assert.equal(result.kind, 'settled'); assert.equal(result.settlement.outcome, 'fatal');
    assert.equal(result.errorCode, 'RcpRequestFailed'); assert.equal(result.stream.detachedFetchCount, 0);
    assert.equal(result.stream.sessionCount, 0); assert.equal(result.stream.allSessionsApiClosed, true);
    assert.equal(f.stream.adaptiveRcpAdmissionSnapshot().pending, 0);
    assert.equal(f.sdk.records.length, 0); assert.equal(f.sdk.queues.length, 0);
    assert.equal(f.io.events.length, 0); assert.equal(f.io.handles.size, 0);
  }
  const healthy = await f.claim(server.url + '/healthy.ts');
  await assertComplete(f, healthy, await within(healthy.task.run()), 'healthy');
  assert.equal(server.requests.length, 1); assert.equal(f.stream.adaptiveRcpAdmissionSnapshot().pending, 0);
});

test('H12 invalid queue counters and read exceptions fail closed without a candidate', OPTIONS, async t => {
  const f = await fixture(t), server = await f.server(serveBody(Buffer.from('abc')));
  // readThrow models the device queue-overflow abort (1007900990): retryable, nothing committed.
  for (const option of [{ readThrow: true }, { badStored: -1 }, { badStored: 1048577 }, { badStored: NaN }, { badStored: 1.5 }]) {
    Object.assign(f.sdk.options, option);
    const c = await f.claim(server.url + '/bad-queue.ts'), result = await within(c.task.run());
    assert.equal(result.settlement.outcome, option.readThrow ? 'retryable' : 'fatal', JSON.stringify(option)); assert.equal(result.settlement.sealedPart, null);
    assert.equal(result.stream.eof, false); assertClosed(f, result);
    for (const key of Object.keys(option)) delete f.sdk.options[key];
  }
});

test('H7 every redirect status preserves encoded relative URLs, OWS, fixed Referer and one Range', OPTIONS, async t => {
  const f = await fixture(t), server = await f.server((req, res) => {
    if (req.url.startsWith('/status/')) { res.writeHead(Number(req.url.split('/')[2]), { Location: ' \t../final.ts?token=a%2Fb%2Bc&x=%3D \t' }); res.end('ignored'); }
    else res.end('OK');
  });
  for (const status of [301, 302, 303, 307, 308]) {
    const context = new f.context.DownloadRequestContext();
    context.headers = { names: ['Range', 'Host', 'Content-Length', 'Transfer-Encoding', 'Accept-Encoding'], values: [['bytes=999-'], ['bad.invalid'], ['999'], ['chunked'], ['gzip']] };
    const c = await f.claim(server.url + '/status/' + status, { context }), result = await within(c.task.run());
    await assertComplete(f, c, result, 'OK');
    const requests = server.requests.slice(-2);
    assert.equal(requests[1].url, '/final.ts?token=a%2Fb%2Bc&x=%3D');
    assert.equal(requests[1].headers.range, 'bytes=0-'); assert.equal(requests[1].headers['accept-encoding'], 'identity');
    assert.equal(requests[1].headers.referer, requests[0].headers.referer);
    assert.equal(requests[1].headers['content-length'], undefined); assert.equal(requests[1].headers['transfer-encoding'], undefined);
  }
});

test('H7 malformed and duplicate Location never open a subsequent hop', OPTIONS, async t => {
  const f = await fixture(t), server = await f.server((_req, res) => { res.writeHead(302, { Location: '/final.ts' }); res.end(); });
  for (const headers of [{}, { Location: {} }, { Location: ['a', 'b'] }, { Location: [] }, { Location: 'a', location: 'a' },
    { Location: '/bad path' }, { Location: '\u0000/bad' }, { Location: 'x'.repeat(32769) }, { Location: 'file:///private' }]) {
    f.sdk.options.headers = headers;
    const before = f.sdk.records.length, c = await f.claim(server.url + '/bad-location.ts'), result = await within(c.task.run());
    assert.equal(result.settlement.outcome, 'fatal'); assert.equal(result.settlement.sealedPart, null);
    assert.equal(f.sdk.records.length - before, 1); assertClosed(f, result);
  }
});

test('H7 redirect loops and the thirty-first redirect fail after bounded closed hops', OPTIONS, async t => {
  const f = await fixture(t), server = await f.server((req, res) => {
    const next = req.url === '/loop' ? '/loop' : '/' + (Number(req.url.slice(1)) + 1);
    res.writeHead(302, { Location: next }); res.write('unending redirect');
  });
  for (const [target, expected] of [['/loop', 1], ['/0', 31]]) {
    const before = f.sdk.records.length, c = await f.claim(server.url + target), result = await within(c.task.run());
    assert.equal(result.settlement.outcome, 'fatal'); assert.equal(f.sdk.records.length - before, expected);
    assert.equal(result.writtenBytes, 0); assert.equal(result.settlement.sealedPart, null); assertClosed(f, result);
  }
});

test('H6 header budgets and invalid critical types cannot use final-response recovery', OPTIONS, async t => {
  const f = await fixture(t), server = await f.server(serveBody(Buffer.from('abc')));
  const overKeys = {}; for (let i = 0; i < 129; i++) overKeys['x-' + i] = 'z';
  for (const headers of [overKeys, { 'Content-Length': 3 }, { 'Content-Length': null }, { 'Content-Length': {} },
    { 'Content-Length': [3] }, { 'Content-Length': Array(9).fill('3') }, { 'Content-Length': '3\u0000' },
    { 'Content-Encoding': 'x'.repeat(16385) }, { 'Content-Length': '3', 'content-length': '4' },
    { 'Content-Length': '3', 'Transfer-Encoding': 'chunked' }]) {
    f.sdk.options.headers = headers;
    const c = await f.claim(server.url + '/invalid-head.ts'), before = f.io.events.length, result = await within(c.task.run());
    assert.equal(result.settlement.outcome, 'fatal', Object.keys(headers).join(',')); assert.equal(result.settlement.sealedPart, null);
    assert.equal(f.io.events.length, before); assertClosed(f, result);
  }
});

function directStream(t, f, claim, clock, timeout = 1000) {
  const request = new f.stream.AdaptiveStreamRequest(); request.identity = claim.dispatch.identity;
  request.url = claim.input.dispatch.chunk.url; request.window = f.protocol.createAdaptiveWindow(claim.dispatch.chunk,
    claim.dispatch.prefix.downloaded, claim.input.knownResourceTotal); request.requestContext = claim.input.requestContext;
  request.networkDeadlineMs = timeout;
  const stream = new f.stream.AdaptiveRcpStream(request, () => {}, clock);
  t.after(() => stream.close()); return stream;
}

test('H6 body is quarantined until a trusted pair; optional identity is allowed but a wrong identity is ignored', OPTIONS, async t => {
  const f = await fixture(t, { sdk: { script(record, queue) { queue.push(Buffer.from('abc')); record.response = { request: record.request, statusCode: 200, headers: { 'Content-Length': '3' } }; } } });
  const c = await f.claim('http://fixture.invalid/body-first.ts'), work = c.task.run(); await flush();
  const record = f.sdk.records[0]; record.emit('onDownloadProgress', 3, 3, record.request);
  record.emit('onStatusCodeReceive', 401, { id: 'wrong' }); record.emit('onHeaderReceive', {}, { id: 'wrong' }); await flush();
  assert.equal(f.io.events.length, 0); assert.equal(f.sdk.queues[0].reads, 0);
  record.emit('onStatusCodeReceive', 200); record.emit('onHeaderReceive', { 'Content-Length': '3' });
  record.emit('onDataEnd'); record.forceResolve(); const result = await within(work);
  await assertComplete(f, c, result, 'abc'); assert.equal(result.stream.headSource, 'early');
});

test('H6 missing informational header pair quarantines and recovers only from an actual final Response', OPTIONS, async t => {
  const f = await fixture(t, { sdk: { script(record, queue, handlers, settle) {
    handlers.onStatusCodeReceive(103, record.request); handlers.onStatusCodeReceive(200, record.request);
    handlers.onHeaderReceive({ 'Content-Length': '3' }, record.request); queue.push(Buffer.from('abc'));
    record.response = { request: record.request, statusCode: 200, headers: { 'Content-Length': '3' } };
    handlers.onDataEnd(record.request); settle(true, record.response);
  } } });
  const c = await f.claim('http://fixture.invalid/missing-103-head.ts'), result = await within(c.task.run());
  await assertComplete(f, c, result, 'abc'); assert.equal(result.stream.headSource, 'finalResponse');
});

test('H6 101 and malformed final request identity cannot produce a candidate', OPTIONS, async t => {
  const f = await fixture(t);
  for (const variant of ['upgrade', 'missing', 'mismatch']) {
    f.sdk.options.script = (record, queue, handlers, settle) => {
      handlers.onStatusCodeReceive(variant === 'upgrade' ? 101 : 200, record.request);
      handlers.onHeaderReceive({ 'Content-Length': '3' }, record.request); queue.push(Buffer.from('abc'));
      handlers.onDataEnd(record.request);
      settle(true, { statusCode: 200, headers: { 'Content-Length': '3' }, ...(variant === 'missing' ? {} : { request: { id: 'wrong' } }) });
    };
    const c = await f.claim('http://fixture.invalid/final-request.ts'), result = await within(c.task.run());
    assert.equal(result.settlement.outcome, 'fatal'); assert.equal(result.settlement.sealedPart, null); assertClosed(f, result);
  }
});

test('H6 a final metadata mismatch after real writes invalidates only the fresh candidate', OPTIONS, async t => {
  const f = await fixture(t, { sdk: { resolveDelay: 40, finalHeaders: { 'Content-Length': '100001' } } });
  const server = await f.server(serveBody(Buffer.alloc(100000, 48))), c = await f.claim(server.url + '/late-mismatch.ts', { prefix: 'OLD' });
  const result = await within(c.task.run()); assert.ok(result.writtenBytes > 0); assert.equal(result.errorCode, 'RcpFinalHeadMismatch');
  assert.equal(result.settlement.sealedPart, null); assert.equal(result.stream.headTrusted, false);
  await assert.rejects(fs.stat(c.filePath), { code: 'ENOENT' }); assert.equal(await fs.readFile(path.join(c.directory, 'old.part'), 'utf8'), 'OLD');
  assertClosed(f, result);
});

test('H5 short bodies and rejection after onDataEnd remain retryable, with bounded known prefixes', OPTIONS, async t => {
  const f = await fixture(t), server = await f.server((req, res) => {
    res.writeHead(206, { 'Content-Range': 'bytes 0-7/8' }); res.write(req.url === '/short.ts' ? 'abc' : 'abcdefgh'); res.end();
  });
  for (const target of ['/short.ts', '/reject.ts']) {
    f.sdk.options.rejectAfterEnd = target === '/reject.ts';
    const c = await f.claim(server.url + target, { length: 8 }), result = await within(c.task.run());
    assert.equal(result.settlement.outcome, 'retryable');
    if (target === '/short.ts') assert.equal(result.settlement.sealedPart?.downloaded, 3);
    else assert.ok((result.settlement.sealedPart?.downloaded ?? 0) <= 7);
    assert.equal(result.settlement.sealedPart?.complete ?? false, false); assertClosed(f, result);
    assert.equal(c.run.settle(result.settlement, 2).accepted, true);
  }
});

test('H5 a temporarily empty real HTTP queue is not end of stream', OPTIONS, async t => {
  const f = await fixture(t), server = await f.server((_req, res) => {
    res.writeHead(200); res.write('first'); setTimeout(() => res.end('last'), 70);
  });
  const c = await f.claim(server.url + '/gap.ts'), work = c.task.run();
  await until(() => c.gate.snapshot().writtenBytes === 5); assert.equal(f.sdk.records[0].fetchSettled, false);
  const result = await within(work); await assertComplete(f, c, result, 'firstlast');
});

test('H1/H5 whole 206 suffix requires a proven full extent and preserves copied bytes separately', OPTIONS, async t => {
  const f = await fixture(t), server = await f.server((req, res) => {
    res.writeHead(206, { 'Content-Range': req.url === '/complete.ts' ? 'bytes 4-7/8' : 'bytes 4-7/10' }); res.end('EFGH');
  });
  for (const target of ['/complete.ts', '/incomplete.ts']) {
    const c = await f.claim(server.url + target, { prefix: 'abcd' }), result = await within(c.task.run());
    if (target === '/complete.ts') await assertComplete(f, c, result, 'abcdEFGH');
    else { assert.notEqual(result.settlement.outcome, 'complete'); assertClosed(f, result); }
    if (target === '/complete.ts') assert.equal(result.writtenBytes, 4);
    assert.equal(await fs.readFile(path.join(c.directory, 'old.part'), 'utf8'), 'abcd');
  }
});

test('H4 whole 200 stop can replace a larger old prefix with a smaller fresh prefix only through reset', OPTIONS, async t => {
  const f = await fixture(t), server = await f.server((_req, res) => { res.writeHead(200); res.write('NEW'); });
  const c = await f.claim(server.url + '/reset-stop.ts', { prefix: 'OLD-PREFIX-LONG' }), work = c.task.run();
  await until(() => c.gate.snapshot().writtenBytes === 3); c.run.requestPause(); c.task.stop();
  const result = await within(work); assert.equal(result.settlement.outcome, 'stopped');
  assert.equal(result.settlement.whole200Reset, true); assert.equal(result.settlement.sealedPart.downloaded, 3);
  assert.equal(c.run.settle(result.settlement, 2).candidateAccepted, true);
  assert.equal(await fs.readFile(c.filePath, 'utf8'), 'NEW');
  assert.equal(await fs.readFile(path.join(c.directory, 'old.part'), 'utf8'), 'OLD-PREFIX-LONG'); assertClosed(f, result);
});

test('H8 virtual header deadlines are absolute and wrong identities or early body do not renew them', OPTIONS, async t => {
  const clock = new VirtualClock(), f = await fixture(t, { globals: { setTimeout: clock.setTimeout, clearTimeout: clock.clearTimeout }, sdk: { script() {} } });
  for (const earlyBody of [false, true]) {
    const c = await f.claim('http://fixture.invalid/no-head.ts'), source = directStream(t, f, c, clock.now);
    const work = source.start(), record = f.sdk.records.at(-1);
    if (earlyBody) f.sdk.queues.at(-1).push(Buffer.from('body'));
    for (let i = 0; i < 4; i++) {
      await clock.advance(200); record.emit('onStatusCodeReceive', 200, { id: 'wrong' });
      record.emit('onDownloadProgress', 9999, 9999, record.request);
    }
    await clock.advance(200); const result = await work;
    assert.equal(result.kind, 'failed'); assert.equal(result.errorCode, earlyBody ? 'RcpHeadOrderUnsupported' : 'RcpHeaderTimeout');
    assert.equal(source.snapshot().failureKind, earlyBody ? 'fatal' : 'retryable');
    assert.equal(f.io.events.length, 0); assert.equal(record.closeCalls, 1);
  }
});

test('H8 queue-positive and local time beyond sixty seconds do not count toward demand idle', OPTIONS, async t => {
  const clock = new VirtualClock(), f = await fixture(t, { globals: { setTimeout: clock.setTimeout, clearTimeout: clock.clearTimeout },
    sdk: { script(record, queue, handlers) { handlers.onStatusCodeReceive(200, record.request); handlers.onHeaderReceive({}, record.request); queue.push(Buffer.from('abc')); } } });
  const c = await f.claim('http://fixture.invalid/idle.ts'), source = directStream(t, f, c, clock.now);
  assert.equal((await source.start()).kind, 'head'); await clock.advance(65000);
  assert.equal(source.snapshot().failureCode, ''); assert.equal((await source.waitReadable()).kind, 'ready');
  assert.equal(source.pull(32768).data.byteLength, 3); await clock.advance(65000);
  assert.equal(source.snapshot().failureCode, '', 'an empty queue without caller demand has no idle timer');
  let done = false; const work = source.waitReadable().then(value => { done = true; return value; });
  await clock.advance(999); assert.equal(done, false); await clock.advance(1);
  assert.equal((await work).errorCode, 'RcpIdleTimeout'); assert.equal(source.snapshot().eof, false);
});

test('H8 the attempt transfer budget decreases across hops and never restarts after budget exhaustion', OPTIONS, async t => {
  const clock = new VirtualClock(), f = await fixture(t, { globals: { setTimeout: clock.setTimeout, clearTimeout: clock.clearTimeout } });
  for (const gap of [65000, 2147483647]) {
    const initialCount = f.sdk.records.length;
    f.sdk.options.script = (record, queue, handlers, settle) => {
      if (record.url.endsWith('/first.ts')) {
        handlers.onStatusCodeReceive(302, record.request); handlers.onHeaderReceive({ Location: '/final.ts' }, record.request); clock.time += gap;
      } else {
        handlers.onStatusCodeReceive(200, record.request); handlers.onHeaderReceive({ 'Content-Length': '0' }, record.request);
        handlers.onDataEnd(record.request); settle(true, { request: record.request, statusCode: 200, headers: { 'Content-Length': '0' } });
      }
    };
    const c = await f.claim('http://fixture.invalid/first.ts'), source = directStream(t, f, c, clock.now), result = await source.start();
    assert.equal(f.sdk.records[initialCount].configuration.requestConfiguration.transfer.timeout.transferMs, 2147483647);
    if (gap < 2147483647) {
      assert.equal(result.kind, 'head'); assert.equal((await source.waitReadable()).kind, 'eof');
      assert.equal(f.sdk.records[initialCount + 1].configuration.requestConfiguration.transfer.timeout.transferMs, 2147483647 - gap);
    } else { assert.equal(result.errorCode, 'RcpTransferBudgetExceeded'); assert.equal(f.sdk.records.length - initialCount, 1); }
    source.close();
  }
});

test('H8 slow real prefix reads and appends exclude local latency from network idle', OPTIONS, async t => {
  const clock = new VirtualClock(), f = await fixture(t, { globals: { setTimeout: clock.setTimeout, clearTimeout: clock.clearTimeout } });
  const server = await f.server(serveBody(Buffer.alloc(64, 83), 206, { 'Content-Range': 'bytes 4-67/68' }));
  for (const boundary of ['read', 'append']) {
    const entered = deferred(), release = deferred(); let writes = 0, used = false;
    f.io.before = async event => {
      if (event.op === 'write') writes++;
      if (!used && (boundary === 'read' ? event.op === 'read' : event.op === 'write' && writes === 2)) {
        used = true; entered.resolve(); await release.promise;
      }
    };
    const c = await f.claim(server.url + '/local-delay.ts', { length: 68, prefix: 'abcd', timeoutSeconds: 1, clock: clock.now }), work = c.task.run();
    await within(entered.promise); await clock.advance(65000);
    assert.equal(f.sdk.records.at(-1).closeCalls, 0, 'local IO is not network demand');
    release.resolve(); const result = await within(work); await assertComplete(f, c, result, Buffer.concat([Buffer.from('abcd'), Buffer.alloc(64, 83)]));
    f.io.before = null;
  }
});

function gateFixture(f, clock, policy, lanes = 8) {
  const id = identity(f), provider = typeof policy === 'function' ? policy : () => policy;
  const gate = new f.throttle.AdaptiveDownloadThrottle(id.downloadId, id.runToken, lanes, provider, clock.now);
  f.gates.push(gate); return gate;
}

test('H9 FIFO grants retain bounded waiters and account for one-byte submillisecond quanta', OPTIONS, async t => {
  const clock = new VirtualClock(), f = await fixture(t, { globals: { setTimeout: clock.setTimeout, clearTimeout: clock.clearTimeout } });
  const policy = new f.throttle.AdaptiveThrottlePolicy(); policy.taskKiBps = 1;
  const gate = gateFixture(f, clock, policy), first = await gate.acquire(identity(f)), order = [];
  const waiting = Array.from({ length: 7 }, (_, index) => gate.acquire(identity(f, index + 1)).then(value => { order.push(index + 1); return value; }));
  assert.equal(gate.snapshot().pendingTickets, 8);
  assert.equal((await gate.acquire(identity(f, 1, 2))).errorCode, 'GateAlreadyPending');
  await gate.finish(first, 1);
  for (let i = 0; i < waiting.length; i++) {
    const grant = await waiting[i], started = clock.time;
    await clock.finish(gate.finish(grant, 1)); assert.equal(clock.time - started, 1);
  }
  assert.deepEqual(order, [1, 2, 3, 4, 5, 6, 7]); assert.equal(gate.snapshot().writtenBytes, 8);
  assert.equal(gate.snapshot().pendingTickets, 0);
});

test('H10 positive caps, global toggles and disable/re-enable alter only unpaid debt', OPTIONS, async t => {
  const clock = new VirtualClock(), f = await fixture(t, { globals: { setTimeout: clock.setTimeout, clearTimeout: clock.clearTimeout } });
  const policy = new f.throttle.AdaptiveThrottlePolicy(); policy.globalEnabled = true; policy.globalKiBps = 2; policy.taskKiBps = 1;
  const gate = gateFixture(f, clock, policy); await gate.finish(await gate.acquire(identity(f)), 32768);
  let paid = false; const debt = gate.finish(await gate.acquire(identity(f)), 32768).then(value => { paid = true; return value; });
  policy.globalEnabled = false; gate.refreshPolicy(); assert.equal(gate.snapshot().effectiveKiBps, 1);
  await clock.advance(2000); assert.equal(paid, false);
  policy.taskKiBps = 2; gate.refreshPolicy(); assert.equal(gate.snapshot().effectiveKiBps, 2);
  policy.globalEnabled = true; policy.globalKiBps = 1; gate.refreshPolicy(); assert.equal(gate.snapshot().effectiveKiBps, 1);
  await clock.advance(14000); assert.equal(paid, false);
  policy.globalEnabled = false; policy.taskKiBps = 0; gate.refreshPolicy(); assert.equal((await debt).kind, 'paid');
  assert.equal(gate.snapshot().writtenBytes, 65536); assert.equal(gate.snapshot().hasDebt, false);
  await gate.finish(await gate.acquire(identity(f)), 32768); policy.taskKiBps = 1; gate.refreshPolicy();
  const started = clock.time; await clock.finish(gate.finish(await gate.acquire(identity(f)), 32768));
  assert.equal(clock.time - started, 32000); assert.equal(gate.snapshot().writtenBytes, 131072);
});

test('H10 policy refresh happens within three seconds and malformed providers preserve already-written accounting', OPTIONS, async t => {
  const clock = new VirtualClock(), f = await fixture(t, { globals: { setTimeout: clock.setTimeout, clearTimeout: clock.clearTimeout } });
  const policy = new f.throttle.AdaptiveThrottlePolicy(); policy.taskKiBps = 1;
  const gate = gateFixture(f, clock, policy); await gate.finish(await gate.acquire(identity(f)), 32768);
  let refreshed = false; const pending = gate.finish(await gate.acquire(identity(f)), 32768).then(value => { refreshed = true; return value; }); policy.taskKiBps = 0;
  await clock.advance(3000); assert.equal(refreshed, true); assert.equal((await pending).kind, 'paid'); assert.equal(gate.snapshot().effectiveKiBps, 0);
  for (const bad of [null, { globalEnabled: false, globalKiBps: 0, taskKiBps: -1 }, { globalEnabled: false, globalKiBps: 0, taskKiBps: 1.5 }, 'throw']) {
    let current = new f.throttle.AdaptiveThrottlePolicy();
    const broken = gateFixture(f, clock, () => { if (current === 'throw') throw sdkError(401); return current; });
    const grant = await broken.acquire(identity(f)); current = bad; await clock.advance(3000);
    const result = await broken.finish(grant, 17);
    assert.equal(result.kind, 'fault'); assert.equal(result.errorCode, 'InvalidThrottlePolicy');
    assert.equal(broken.snapshot().writtenBytes, 17, 'confirmed IO stays counted even when a subsequent provider/clock read fails');
    assert.equal(broken.snapshot().pendingTickets, 0);
  }
});

test('H10 cancellation during append holds the grant until its real byte delta and carries debt across attempts', OPTIONS, async t => {
  const clock = new VirtualClock(), f = await fixture(t, { globals: { setTimeout: clock.setTimeout, clearTimeout: clock.clearTimeout } });
  const policy = new f.throttle.AdaptiveThrottlePolicy(); policy.taskKiBps = 1;
  const gate = gateFixture(f, clock, policy), id = identity(f); await gate.finish(await gate.acquire(id), 32768);
  const grant = await gate.acquire(id); gate.cancelAttempt(id);
  let granted = false; const next = gate.acquire(identity(f, 0, 2)).then(value => { granted = true; return value; });
  assert.equal((await next).errorCode, 'GateAlreadyPending'); assert.equal(gate.snapshot().pendingTickets, 1);
  assert.equal((await gate.finish(grant, 32768)).kind, 'canceled'); assert.equal(gate.snapshot().hasDebt, true);
  granted = false; const retry = gate.acquire(identity(f, 0, 2)).then(value => { granted = true; return value; });
  await clock.advance(31999); assert.equal(granted, false); await clock.advance(1);
  const held = await retry; gate.cancelAttempt(id); assert.equal(gate.snapshot().pendingTickets, 1);
  assert.equal((await gate.finish(grant, 0)).errorCode, 'InvalidGateGrant');
  assert.equal((await gate.finish(held, 0)).kind, 'paid'); assert.equal(gate.snapshot().writtenBytes, 65536);
});

test('H11 stop/dispose before and after every actual open/copy/append/seal IO boundary drains exactly once', OPTIONS, async t => {
  const f = await fixture(t), server = await f.server(serveBody(Buffer.from('EFGH'), 206, { 'Content-Range': 'bytes 4-7/8' }));
  const settings = { prefix: 'abcd', length: 8 }, initial = await f.claim(server.url + '/boundaries.ts', settings);
  await assertComplete(f, initial, await initial.task.run(), 'abcdEFGH');
  const trace = f.io.events.map(event => ({ op: event.op, role: path.basename(event.path) === 'old.part' ? 'prefix' : 'candidate' }));
  let count = 0;
  for (const operation of ['stop', 'dispose']) for (const phase of ['before', 'settled']) for (let index = 0; index < trace.length; index++) {
    const c = await f.claim(server.url + '/boundaries.ts', settings), start = f.io.events.length;
    const entered = deferred(), release = deferred(); let triggered = false, finished = false;
    f.io[phase] = async event => { if (event.index - start === index) { triggered = true; entered.resolve(); await release.promise; } };
    const work = c.task.run().then(value => { finished = true; return value; });
    await within(entered.promise); if (operation === 'stop') c.run.requestPause(); c.task[operation](); await flush();
    assert.equal(finished, false, 'drain must await the accepted IO'); release.resolve(); const result = await within(work); f.io[phase] = null;
    const label = JSON.stringify({ operation, phase, index, boundary: trace[index] });
    assert.equal(triggered, true, label); assertClosed(f, result);
    assert.equal(result.kind, operation === 'dispose' ? 'disposed' : 'settled', label);
    if (operation === 'dispose') { assert.equal(result.settlement, null); if (result.file.cleanupComplete) assert.equal(result.errorCode, '', label); }
    else assert.equal(c.run.settle(result.settlement, 2).accepted, true, label);
    if (!result.file.cleanupComplete) assert.notEqual(result.errorCode, '', 'cleanup uncertainty remains visible: ' + label);
    assert.equal(await fs.readFile(path.join(c.directory, 'old.part'), 'utf8'), 'abcd');
    const operations = f.io.events.slice(start), closes = operations.filter(event => event.op === 'close');
    assert.equal(new Set(closes.map(event => event.fd)).size, closes.length, label);
    const deliveredCount = f.io.events.length; f.sdk.records.at(-1).emit('onDataEnd', f.sdk.records.at(-1).request); await flush();
    assert.deepEqual(plain(await c.task.drain()), plain(result)); assert.equal(f.io.events.length, deliveredCount);
    count++;
  }
  t.diagnostic('E3_STOP_IO_BOUNDARIES ' + JSON.stringify({ baselineOperations: trace.length, combinations: count, trace }));
});

test('H11 stop during a queue read prevents subsequent file append admission', OPTIONS, async t => {
  const f = await fixture(t), server = await f.server(serveBody(Buffer.from('body')));
  const c = await f.claim(server.url + '/pull-stop.ts'); let stopped = false;
  f.sdk.options.afterPull = () => { if (!stopped) { stopped = true; c.run.requestPause(); c.task.stop(); } };
  const result = await within(c.task.run());
  assert.equal(stopped, true); assert.equal(result.settlement.outcome, 'stopped'); assert.equal(result.writtenBytes, 0);
  assert.equal(f.io.events.filter(event => event.op === 'write').length, 0); assert.equal(c.gate.snapshot().writtenBytes, 0); assertClosed(f, result);
});

test('H11 waiting for headers, an empty queue or another lane grant can be stopped without late writes', OPTIONS, async t => {
  const f = await fixture(t), server = await f.server((req, res) => {
    if (req.url === '/headers.ts') return;
    res.writeHead(200); res.flushHeaders(); if (req.url === '/grant.ts') res.write('held');
  });
  for (const stage of ['headers', 'queue', 'grant']) {
    const c = await f.claim(server.url + '/' + stage + '.ts', { count: 2, lanes: 2 });
    const blocker = stage === 'grant' ? await c.gate.acquire(c.dispatches[1].identity) : null;
    const before = f.io.events.length, work = c.task.run();
    await until(() => stage === 'headers' ? server.requests.at(-1)?.url === '/headers.ts' :
      stage === 'queue' ? f.io.events.length > before && f.io.events.at(-1).op === 'stat' : c.gate.snapshot().pendingTickets === 2);
    c.run.requestPause(); c.task.stop(); const result = await within(work); assert.equal(result.settlement.outcome, 'stopped');
    assert.equal(result.writtenBytes, 0); assertClosed(f, result);
    if (blocker) await c.gate.finish(blocker, 0);
  }
});

test('H11 stop during real append returns before unpaid debt while the next lane must still pay it', OPTIONS, async t => {
  const clock = new VirtualClock(), f = await fixture(t, { globals: { setTimeout: clock.setTimeout, clearTimeout: clock.clearTimeout } });
  const server = await f.server(serveBody(Buffer.alloc(131072, 17), 206, { 'Content-Range': 'bytes 0-131071/131072' }));
  const policy = new f.throttle.AdaptiveThrottlePolicy(); policy.taskKiBps = 1;
  const c = await f.claim(server.url + '/stop-debt.ts', { count: 2, lanes: 2, length: 131072, policy, clock: clock.now });
  const entered = deferred(), release = deferred(); let writes = 0;
  f.io.before = async event => { if (event.op === 'write' && ++writes === 2) { entered.resolve(); await release.promise; } };
  const work = c.task.run(); await within(entered.promise); c.run.requestPause(); c.task.stop(); release.resolve();
  const result = await within(work); assert.equal(clock.time, 1); assert.equal(result.settlement.outcome, 'stopped');
  assert.equal(result.writtenBytes, 65536); assert.equal(c.gate.snapshot().writtenBytes, 65536); assert.equal(c.gate.snapshot().hasDebt, true); assertClosed(f, result);
  let available = false; const next = c.gate.acquire(c.dispatches[1].identity).then(value => { available = true; return value; });
  await clock.advance(31999); assert.equal(available, false); await clock.advance(1);
  const grant = await next; assert.equal(grant.kind, 'granted'); await c.gate.finish(grant, 0);
});

test('H11 disposal after actual E2 seal but before executor receipt exposes a discard filename only', OPTIONS, async t => {
  const f = await fixture(t), server = await f.server(serveBody(Buffer.from('sealed'))), c = await f.claim(server.url + '/sealed-dispose.ts');
  const seal = f.file.AdaptiveAttemptFile.prototype.seal;
  f.file.AdaptiveAttemptFile.prototype.seal = function (...args) { return seal.apply(this, args).then(result => { assert.equal(result.sealed, true); c.task.dispose(); return result; }); };
  const result = await within(c.task.run()); assert.equal(result.kind, 'disposed'); assert.equal(result.settlement, null);
  assert.equal(result.discardFileName, c.dispatch.candidateFileName); assert.equal(await fs.readFile(c.filePath, 'utf8'), 'sealed');
  assert.equal(c.run.isCurrentAttempt(c.dispatch.identity), true, 'no hidden scheduler settlement occurs'); assertClosed(f, result);
});

test('H11 disposal during the real L-minus-one truncate cannot publish a partial candidate', OPTIONS, async t => {
  const f = await fixture(t, { sdk: { neverSettle: true } }), server = await f.server(serveBody(Buffer.from('abcd'), 206, { 'Content-Range': 'bytes 0-3/4' }));
  const c = await f.claim(server.url + '/truncate-dispose.ts', { length: 4, timeoutSeconds: 1 }); let hit = false;
  f.io.before = async event => { if (event.op === 'truncate') { hit = true; c.task.dispose(); } };
  const result = await within(c.task.run()); assert.equal(hit, true); assert.equal(result.kind, 'disposed'); assert.equal(result.settlement, null);
  assert.equal(result.file.sealed, false); assert.equal(result.errorCode, ''); assertClosed(f, result);
});

test('H12 partial/zero writes, seal failure and secondary cleanup errors retain exact confirmed counts and close facts', OPTIONS, async t => {
  const f = await fixture(t), server = await f.server(serveBody(Buffer.alloc(100, 71)));
  for (const scenario of ['partial', 'zero', 'stat', 'fsync', 'cleanup']) {
    const c = await f.claim(server.url + '/disk-fail.ts'), start = f.io.events.length; let writes = 0, stats = 0;
    f.io.writeLimit = scenario === 'zero' ? 0 : scenario === 'partial' ? 7 : Infinity;
    f.io.before = async event => {
      if (event.op === 'write' && (++writes === 2 && scenario === 'partial' || scenario === 'cleanup')) throw sdkError(13900025);
      if (event.op === 'stat' && ++stats === 2 && scenario === 'stat') throw sdkError(13900005);
      if (event.op === 'fsync' && scenario === 'fsync') throw sdkError(13900005);
      if (event.op === 'unlink' && scenario === 'cleanup') throw sdkError(13900012);
    };
    const result = await within(c.task.run()); f.io.before = null;
    assert.equal(result.kind, 'settled'); assert.equal(result.settlement.outcome, 'fatal'); assert.equal(result.settlement.sealedPart, null); assertClosed(f, result);
    assert.equal(result.writtenBytes, scenario === 'partial' ? 7 : scenario === 'stat' || scenario === 'fsync' ? 100 : 0);
    assert.equal(c.gate.snapshot().writtenBytes, result.writtenBytes);
    assert.equal(f.io.events.slice(start).filter(event => event.op === 'close').length, 1);
    if (scenario === 'cleanup') { assert.equal(result.file.cleanupComplete, false); assert.equal(result.file.cleanupErrorCode, 13900012); }
    else await assert.rejects(fs.stat(c.filePath), { code: 'ENOENT' });
  }
});

test('H12 a close rejection after physical close is still uncertain and cannot be retried or ordinarily settled', OPTIONS, async t => {
  const f = await fixture(t), server = await f.server(serveBody(Buffer.from('abc'))), c = await f.claim(server.url + '/after-close-error.ts');
  f.io.after = async event => { if (event.op === 'close') throw sdkError(13900005); };
  const result = await within(c.task.run()); assert.equal(result.kind, 'resourceFault'); assert.equal(result.settlement, null);
  assert.equal(f.io.handles.size, 0); assert.equal(result.file.resourceUncertain, true); assert.equal(result.file.closed, false);
  assert.equal(f.io.events.filter(event => event.op === 'close').length, 1); assert.equal(result.stream.allSessionsApiClosed, true);
});

test('H12 protocol failure survives stop, and resource uncertainty takes precedence over protocol settlement', OPTIONS, async t => {
  const f = await fixture(t), server = await f.server(serveBody(Buffer.from('error body'), 403));
  for (const closeFailure of [false, true]) {
    f.sdk.options.closeThrow = closeFailure;
    const c = await f.claim(server.url + '/forbidden.ts'), result = await within(c.task.run()); c.task.stop();
    if (closeFailure) { assert.equal(result.kind, 'resourceFault'); assert.equal(result.settlement, null); }
    else { assert.equal(result.errorCode, 'AuthOrSession'); assert.equal(result.settlement.outcome, 'retryable'); assertClosed(f, result); }
    assert.deepEqual(plain(await c.task.drain()), plain(result));
  }
});

test('H13 constructors read neither policy nor clock and duplicate run returns isolated exact E1 receipts', OPTIONS, async t => {
  const f = await fixture(t), c = await f.claim('http://127.0.0.1:1/unstarted.ts');
  let calls = 0; const clock = () => { calls++; return 1; }, provider = () => { calls++; return new f.throttle.AdaptiveThrottlePolicy(); };
  const gate = new f.throttle.AdaptiveDownloadThrottle(c.id, c.dispatch.identity.runToken, 1, provider, clock);
  const task = new f.executor.AdaptiveAttemptExecutor(c.input, gate, clock), source = directStream(t, f, c, clock);
  assert.equal(calls, 0); assert.equal(f.io.events.length, 0); assert.equal(f.sdk.records.length, 0); gate.dispose(); task.dispose(); source.close();
  const server = await f.server(serveBody(Buffer.from('once'))), running = await f.claim(server.url + '/once.ts');
  const results = await Promise.all([running.task.run(), running.task.run(), running.task.drain()]);
  assert.equal(server.requests.length, 1); assert.notEqual(results[0], results[1]);
  assert.deepEqual(Object.keys(results[0].settlement).sort(), ['errorCode', 'identity', 'outcome', 'sealedPart', 'whole200Reset']);
  assert.deepEqual(Object.keys(results[0].settlement.sealedPart).sort(), ['chunkId', 'complete', 'downloaded', 'fileName']);
  await assertComplete(f, running, results[0], 'once');
});

test('H13 fixed diagnostics never copy signed URLs, credentials, response body or SDK error text', OPTIONS, async t => {
  const f = await fixture(t), secret = 'e3-secret-token-1486';
  const server = await f.server((_req, res) => { res.writeHead(403); res.end('private-body-' + secret); });
  const context = new f.context.DownloadRequestContext(); context.cookies = 'private=' + secret;
  context.headers = { names: ['Authorization'], values: [['Bearer ' + secret]] };
  const c = await f.claim(server.url + '/asset.ts?signature=' + secret, { context }), result = await c.task.run();
  const diagnostic = JSON.stringify(result); assert.equal(diagnostic.includes(secret), false);
  assert.equal(diagnostic.includes(server.url), false); assert.equal(diagnostic.includes('Private SDK detail'), false);
  assert.equal(result.errorCode, 'AuthOrSession');
});

test('H12 old redirect callbacks and late rejection cannot affect a new active hop or retain its owner', OPTIONS, async t => {
  const f = await fixture(t, { sdk: { forRequest: target => ({ neverSettle: target.pathname === '/redirect.ts' }) } });
  let finish;
  const server = await f.server((req, res) => {
    if (req.url === '/redirect.ts') { res.writeHead(302, { Location: '/active.ts' }); res.write('old'); }
    else { res.writeHead(200); res.write('new'); finish = () => res.end('end'); }
  });
  const c = await f.claim(server.url + '/redirect.ts'), work = c.task.run(); await until(() => c.gate.snapshot().writtenBytes === 3);
  const old = f.sdk.records[0]; assert.equal(old.closed, true); assert.equal(old.fetchSettled, false);
  old.emit('onStatusCodeReceive', 500, old.request); old.emit('onHeaderReceive', { 'Content-Length': {} }, old.request);
  old.emit('onDataEnd', old.request); old.emit('onDownloadProgress', Number.MAX_SAFE_INTEGER, Number.MAX_SAFE_INTEGER, old.request);
  old.forceReject(); await flush(); assert.equal(f.sdk.records[1].closeCalls, 0);
  finish(); const result = await within(work); await assertComplete(f, c, result, 'newend');
  assert.equal(f.stream.adaptiveRcpAdmissionSnapshot().pending, 0); assert.equal(result.stream.headTrusted, true);
});

test('H10 canceled FIFO waiters disappear and disposing one gate does not release another gate', OPTIONS, async t => {
  const clock = new VirtualClock(), f = await fixture(t, { globals: { setTimeout: clock.setTimeout, clearTimeout: clock.clearTimeout } });
  const policy = new f.throttle.AdaptiveThrottlePolicy(), gate = gateFixture(f, clock, policy), other = gateFixture(f, clock, policy);
  const held = await gate.acquire(identity(f)), otherHeld = await other.acquire(identity(f));
  const canceled = gate.acquire(identity(f, 1)), successor = gate.acquire(identity(f, 2)); gate.cancelAttempt(identity(f, 1));
  assert.equal((await canceled).kind, 'canceled'); assert.equal(gate.snapshot().pendingTickets, 2);
  gate.dispose(); assert.equal((await successor).kind, 'canceled'); assert.equal(other.snapshot().pendingTickets, 1);
  assert.equal((await other.finish(otherHeld, 9)).kind, 'paid'); assert.equal(other.snapshot().writtenBytes, 9);
  assert.equal((await gate.finish(held, 7)).kind, 'canceled'); assert.equal(gate.snapshot().writtenBytes, 7);
});

test('H10 a backwards monotonic clock fails the gate while preserving an already-confirmed append', OPTIONS, async t => {
  const clock = new VirtualClock(), f = await fixture(t), policy = new f.throttle.AdaptiveThrottlePolicy();
  const gate = gateFixture(f, clock, policy), held = await gate.acquire(identity(f)); clock.time = 0;
  assert.equal((await gate.finish(held, 13)).kind, 'fault'); assert.equal(gate.snapshot().writtenBytes, 13);
  assert.equal(gate.snapshot().pendingTickets, 0);
});

test('H13 context is captured before run and signed path/query encodings survive fragment removal', OPTIONS, async t => {
  const f = await fixture(t), server = await f.server(serveBody(Buffer.from('encoded')));
  const context = new f.context.DownloadRequestContext(); context.cookies = 'a=original';
  context.headers = { names: ['Authorization'], values: [['original']] };
  const c = await f.claim(server.url + '/a%2Fb.ts?signature=A%2FB%2BC%3D#unused', { context });
  context.headers.values[0][0] = 'mutated'; context.cookies = 'a=changed';
  const result = await c.task.run(); await assertComplete(f, c, result, 'encoded');
  assert.equal(server.requests[0].url, '/a%2Fb.ts?signature=A%2FB%2BC%3D');
  assert.equal(server.requests[0].headers.authorization, 'original'); assert.equal(server.requests[0].headers.cookie, 'a=original');
});

test('H7 a one-element Location array is accepted without joining or coercing its contents', OPTIONS, async t => {
  const f = await fixture(t, { sdk: { forRequest: target => target.pathname === '/array.ts' ? { headers: { Location: ['/last.ts'] } } : {} } });
  const server = await f.server((req, res) => {
    if (req.url === '/array.ts') { res.writeHead(308, { Location: '/last.ts' }); res.end(); } else res.end('array');
  });
  const c = await f.claim(server.url + '/array.ts'), result = await c.task.run(); await assertComplete(f, c, result, 'array');
});

test('H4 identical repeated Content-Length retains the accepted E1 tolerance without losing duplicate values', OPTIONS, async t => {
  const f = await fixture(t, { sdk: { headers: { 'Content-Length': '3', 'content-length': '3' } } });
  const server = await f.server(serveBody(Buffer.from('abc'))), c = await f.claim(server.url + '/same-length.ts');
  await assertComplete(f, c, await c.task.run(), 'abc');
});

test('H6 eight informational blocks exceed the explicit seven-block cap even with final-Response-only fallback', OPTIONS, async t => {
  const f = await fixture(t, { sdk: { script(record, queue, handlers, settle) {
    for (let i = 0; i < 8; i++) { handlers.onStatusCodeReceive(103, record.request); handlers.onHeaderReceive({}, record.request); }
    queue.push(Buffer.from('abc')); handlers.onDataEnd(record.request);
    settle(true, { request: record.request, statusCode: 200, headers: { 'Content-Length': '3' } });
  } } });
  const c = await f.claim('http://fixture.invalid/eight-informational.ts'), result = await within(c.task.run());
  assert.equal(result.errorCode, 'RcpHeaderLimit'); assert.equal(result.settlement.outcome, 'fatal');
  assert.equal(result.settlement.sealedPart, null); assert.equal(f.io.events.length, 0); assertClosed(f, result);
});
