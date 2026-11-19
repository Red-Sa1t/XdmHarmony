'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const { test } = require('node:test');
const { fixture, within, ioError, sha256 } = require('./adaptive-controller-probe-harness.cjs');

test('P6-U6 S1 actual controller owns ready through F/hash reads, then restores without new GETs', async t => {
  const f = await fixture(t); const server = await f.server();
  const facts = await f.complete(f.create(server.origin), 'S1');
  assert.equal(facts.firstKind, 'ready'); assert.equal(facts.firstOwner, 'heldForAssembly');
  assert.equal(facts.firstP0Bytes, '65536'); assert.equal(facts.firstP1Bytes, '65536');
  assert.equal(facts.busyKind, 'rejected'); assert.equal(facts.busyError, 'AdaptiveOwnerBusy');
  assert.equal(facts.busyOwner, 'notAcquired'); assert.equal(facts.attached, 'true');
  assert.equal(facts.asmStatus, 'success'); assert.equal(facts.asmBytes, '131072');
  const expected = Buffer.alloc(131072); for (let i = 0; i < expected.length; i++) expected[i] = i % 251;
  assert.equal(facts.outputSha256, sha256(expected));
  assert.equal(facts.inputsAndSlotsUnchanged, 'true'); assert.equal(facts.leaseReleased, 'true');
  assert.equal(facts.restoredKind, 'ready'); assert.equal(facts.restoredLeaseReleased, 'true');
  assert.equal(server.events.length, 2); assert.deepEqual(server.events.map(event => event.status), [206, 206]);
  assert.equal(f.leases.size, 2); assert.equal(f.readers.length, 1);
  assert.equal(facts.asmClosed, 'true'); assert.equal(facts.asmUncertain, 'false');
});

test('P6-U6 S2 actual timed pause seals a nonzero prefix and resumes its exact Range', async t => {
  const f = await fixture(t); const server = await f.server();
  const facts = await f.complete(f.create(server.origin), 'S2');
  assert.equal(facts.pauseTimerFired, 'true'); assert.equal(facts.pausedKind, 'paused');
  assert.equal(facts.pausedOwner, 'released'); assert.equal(facts.nonzeroPrefix, 'true');
  const prefix = Number(facts.pausedP0Bytes); assert.ok(prefix > 0 && prefix < 524288);
  assert.equal(facts.pausedP0Complete, 'false'); assert.equal(facts.resumedKind, 'ready');
  assert.equal(facts.resumedP0Bytes, '524288'); assert.equal(facts.resumedP0Complete, 'true');
  assert.equal(facts.asmBytes, '524288'); assert.equal(facts.oldPrefixUnchanged, 'true');
  assert.equal(facts.outputSha256, '61d1d9c5745bdaa4fab39240651bc242a5186b15393fd475082fcf6e84f400ab');
  assert.equal(server.events.length, 2); assert.equal(server.events[1].start, prefix);
  assert.equal(facts.leaseReleased, 'true');
});

test('P6-U6 S3 pause before attach rejects reader and preserves the original ready snapshot', async t => {
  const f = await fixture(t); const server = await f.server();
  const facts = await f.complete(f.create(server.origin), 'S3');
  assert.equal(facts.stopRequested, 'true'); assert.equal(facts.attached, 'false');
  assert.equal(facts.readerStarted, 'false'); assert.equal(f.readers.length, 0);
  assert.equal(facts.drainedKind, 'ready'); assert.equal(facts.drainedOwner, 'heldForAssembly');
  assert.equal(facts.leaseReleased, 'true'); assert.equal(facts.leaseCurrentAfterRelease, 'false');
  assert.equal(facts.secondRelease, 'false');
});

test('P6-U6 S4 real F progress relays one stop and external hashes prove original inputs unchanged', async t => {
  const f = await fixture(t); const server = await f.server();
  const session = f.create(server.origin); const facts = await f.complete(session, 'S4');
  assert.equal(facts.attached, 'true'); assert.equal(facts.secondAttach, 'false');
  assert.equal(facts.asmStatus, 'stopped'); assert.equal(facts.asmMediaStarted, 'false');
  assert.equal(facts.asmClosed, 'true'); assert.equal(facts.asmCleanup, 'true');
  assert.equal(facts.stopNotifications, '1'); assert.equal(facts.stopRequested, 'true');
  assert.equal(facts.drainedKind, 'ready'); assert.equal(facts.leaseReleased, 'true');
  assert.equal(f.hashCalls.length, 4, 'only the pre-stop fingerprints run inside the production session');
  for (let i = 0; i < 4; i++) {
    const bytes = await fs.readFile(f.io.real(facts.inputDirectory + '/' + facts['beforeName' + i]));
    assert.equal(sha256(bytes), facts['beforeSha256_' + i]);
  }
});

test('P6-U6 an obsolete token admits no filesystem or controller work', async t => {
  const f = await fixture(t); const session = f.create(); f.invalidate(); const count = f.io.history.length;
  await assert.rejects(session.execute('S1'), /ControllerProbeStopped/);
  assert.equal(await session.releaseResources(), true); assert.equal(f.io.history.length, count);
  assert.equal(f.controllers.length, 0);
});

test('P6-U6 cancellation after real mkdir adopts its directory without starting a controller', async t => {
  const f = await fixture(t); const session = f.create();
  const gate = f.hold(event => event.op === 'mkdir', 'after');
  const pending = session.execute('S1'); const rejected = assert.rejects(pending, /ControllerProbeStopped/);
  try {
    await gate.entered; session.cancel(); f.invalidate();
  } finally { gate.release(); }
  await rejected; assert.equal(await session.releaseResources(), true);
  assert.equal(f.controllers.length, 0); assert.equal(f.io.handles.size, 0);
  const count = f.io.history.length; await assert.rejects(session.writeEvidence('S1'), /ControllerProbeStopped/);
  assert.equal(f.io.history.length, count);
});

test('P6-U6 ready returned after cancellation is adopted once and released after real business settlement', async t => {
  const f = await fixture(t); const server = await f.server(); const session = f.create(server.origin);
  const entered = f.gate(); const released = f.gate(); let hit = false;
  f.hooks.afterRun = async value => {
    if (!hit && value.kind === 'ready') { hit = true; entered.resolve(value); await released.promise; }
  };
  const pending = session.execute('S1'); const rejected = assert.rejects(pending, /ControllerProbeStopped/);
  let drain; let settled = false;
  try {
    const result = await within(entered.promise, 'real ready return'); session.cancel(); f.invalidate();
    drain = session.releaseResources().then(value => { settled = true; return value; });
    await new Promise(resolve => setImmediate(resolve)); assert.equal(settled, false);
    assert.equal(result.ready.lease.isCurrent(), true);
    assert.equal((await f.busy(result.ready)).errorCode, 'AdaptiveOwnerBusy');
  } finally { released.resolve(); }
  await rejected; assert.equal(await drain, true); assert.equal(f.leases.size, 1);
  const lease = [...f.leases.values()][0]; assert.deepEqual(lease.releases, [true]);
  assert.equal(lease.lease.isCurrent(), false); assert.equal(f.readers.length, 0);
});

test('P6-U6 cancellation immediately after attach starts no F IO and drains the registered idle reader', async t => {
  const f = await fixture(t); const server = await f.server(); const session = f.create(server.origin);
  let accepted = 0;
  f.hooks.afterAttach = (_lease, success) => { if (success) { accepted++; session.cancel(); f.invalidate(); } };
  await assert.rejects(session.execute('S1'), /ControllerProbeStopped|ControllerLeaseStopped/);
  assert.equal(await session.releaseResources(), true); assert.equal(accepted, 1);
  assert.equal(f.readers.length, 1); assert.equal(f.readers[0].runs, 0);
  assert.equal(f.io.history.filter(event => event.path?.includes('/asm-')).length, 0);
  assert.deepEqual([...f.leases.values()][0].releases, [true]);
});

test('P6-U6 a real pending hash keeps the ready lease until the outer reader actually drains', async t => {
  const f = await fixture(t); const server = await f.server(); const session = f.create(server.origin);
  const entered = f.gate(); const released = f.gate(); let hit = false;
  f.hooks.beforeHash = async () => { if (!hit) { hit = true; entered.resolve(); await released.promise; } };
  const pending = session.execute('S1'); const rejected = assert.rejects(pending, /ControllerProbeStopped|ControllerLeaseStopped/);
  let drain; let settled = false;
  try {
    await within(entered.promise, 'admitted hash'); session.cancel();
    drain = session.releaseResources().then(value => { settled = true; return value; });
    const lease = [...f.leases.values()][0];
    assert.equal((await f.controllers[0].instance.drain()).kind, 'ready');
    assert.equal((await f.busy(lease.ready)).errorCode, 'AdaptiveOwnerBusy');
    await new Promise(resolve => setImmediate(resolve)); assert.equal(settled, false);
    assert.equal(lease.releases.length, 0); assert.equal(lease.lease.isCurrent(), true);
  } finally { released.resolve(); }
  await rejected; assert.equal(await drain, true); assert.ok(f.hashCalls.every(value => value.finished));
  assert.equal([...f.leases.values()][0].lease.isCurrent(), false);
});

test('P6-U6 E4 drain returns ready while a real F read is pending and admission stays busy', async t => {
  const f = await fixture(t); const server = await f.server(); const session = f.create(server.origin);
  const gate = f.hold(event => event.op === 'read' && event.path.endsWith('.part') && f.readers.some(item => item.runs > 0));
  const pending = session.execute('S1'); const rejected = assert.rejects(pending, /ControllerProbeStopped/);
  let drain; let settled = false;
  try {
    await gate.entered; const first = f.controllers[0].instance; first.pause();
    const result = await within(first.drain(), 'E4 drain excludes its actual external reader');
    assert.equal(result.kind, 'ready'); assert.equal(result.ready.lease.isStopRequested(), true);
    assert.equal((await f.busy(result.ready)).errorCode, 'AdaptiveOwnerBusy');
    session.cancel(); drain = session.releaseResources().then(value => { settled = true; return value; });
    await new Promise(resolve => setImmediate(resolve)); assert.equal(settled, false);
    assert.equal([...f.leases.values()][0].releases.length, 0); assert.equal(f.readers[0].result, null);
  } finally { gate.release(); }
  await rejected; assert.equal(await drain, true); assert.equal(f.readers[0].result.closed, true);
  assert.equal(f.readers[0].result.resourceUncertain, false); assert.equal(f.io.handles.size, 0);
  assert.deepEqual([...f.leases.values()][0].releases, [true]);
});

for (const boundary of ['input-open', 'output-seal']) {
  test('P6-U6 adopts and drains actual F ' + boundary + ' completion after page cancellation', async t => {
    const f = await fixture(t); const server = await f.server(); const session = f.create(server.origin);
    const gate = f.hold(event => boundary === 'input-open' ?
      event.op === 'open' && event.path.endsWith('.part') && (event.mode & 3) === 0 && f.readers.some(item => item.runs > 0) :
      event.op === 'close' && event.path.includes('/asm-'), 'after');
    const pending = session.execute('S1'); const rejected = assert.rejects(pending, /ControllerProbeStopped/);
    try { await gate.entered; session.cancel(); f.invalidate(); } finally { gate.release(); }
    await rejected; assert.equal(await session.releaseResources(), true); assert.equal(f.io.handles.size, 0);
    assert.equal(f.readers[0].result.closed, true); assert.deepEqual([...f.leases.values()][0].releases, [true]);
    const count = f.io.history.length; await assert.rejects(session.writeEvidence('S1'), /ControllerProbeStopped/);
    assert.equal(f.io.history.length, count); assert.equal(f.facts(session).detailFile, undefined);
  });
}

test('P6-U6 unclaimed F open cancelled before fd-stat keeps its residual and quarantines the lease', async t => {
  const f = await fixture(t); const server = await f.server(); const session = f.create(server.origin);
  const gate = f.hold(event => event.op === 'open' && event.path.includes('/asm-'), 'after');
  const pending = session.execute('S1'); const rejected = assert.rejects(pending, /ControllerProbeStopped/);
  let target;
  try { target = (await gate.entered).path; session.cancel(); } finally { gate.release(); }
  await rejected; assert.equal(await session.releaseResources(), false); assert.equal(f.io.handles.size, 0);
  assert.equal((await fs.stat(f.io.real(target))).size, 0);
  const lease = [...f.leases.values()][0]; assert.equal(lease.releases.length, 0); assert.ok(lease.quarantines.length > 0);
  assert.equal((await f.busy(lease.ready)).errorCode, 'AdaptiveOwnerQuarantined');
});

for (const boundary of ['C-staging', 'F-input']) {
  test('P6-U6 ' + boundary + ' failed close is sticky, does not retry, and suppresses evidence IO', async t => {
    const f = await fixture(t); const server = await f.server(); const session = f.create(server.origin);
    let target = ''; let hit = false; let failedCloseIndex = -1;
    f.io.before = async event => {
      const selected = boundary === 'C-staging' ? event.path?.endsWith('.tmp') :
        event.path?.endsWith('.part') && !event.path?.includes('/asm-') && f.readers.some(item => item.runs > 0);
      if (!hit && event.op === 'close' && selected) {
        hit = true; target = event.path; failedCloseIndex = event.index; f.allowUncertain(target); throw ioError();
      }
    };
    await assert.rejects(session.execute('S1'), /ControllerResourceUncertain|ControllerAssemblyUncertain/);
    assert.equal(hit, true); assert.equal(await session.releaseResources(), false); assert.equal(f.io.handles.size, 1);
    assert.equal(f.io.history.filter(event => event.index >= failedCloseIndex && event.op === 'close' && event.path === target).length, 1);
    assert.equal(f.io.history.some(event => event.op === 'unlink' && event.path === target), false);
    const count = f.io.history.length; await session.writeEvidence('S1'); assert.equal(f.io.history.length, count);
    assert.equal(f.facts(session).detailFile, undefined);
    if (boundary === 'F-input') {
      const lease = [...f.leases.values()][0]; assert.equal(lease.releases.length, 0);
      assert.equal((await f.busy(lease.ready)).errorCode, 'AdaptiveOwnerQuarantined');
    }
  });
}

for (const boundary of ['open', 'close']) {
  test('P6-U6 evidence ' + boundary + ' completion after cancellation never publishes stale detailFile', async t => {
    const f = await fixture(t); const server = await f.server(); const session = f.create(server.origin);
    await session.execute('S3'); assert.equal(await session.releaseResources(), true); session.noteCleanup(true);
    const gate = f.hold(event => event.op === boundary && event.path.includes('/details-'), 'after');
    const pending = session.writeEvidence('S3'); const rejected = assert.rejects(pending, /ControllerProbeStopped|ControllerEvidenceUnavailable/);
    let target;
    try { target = (await gate.entered).path; session.cancel(); f.invalidate(); } finally { gate.release(); }
    await rejected; assert.equal(await session.releaseResources(), boundary === 'close'); assert.equal(f.io.handles.size, 0);
    assert.equal(f.facts(session).detailFile, undefined);
    assert.equal(f.io.history.filter(event => event.op === 'close' && event.path === target).length, 1);
    if (boundary === 'open') assert.equal((await fs.stat(f.io.real(target))).size, 0);
  });
}

test('P6-U6 failed evidence close reports unsafe cleanup without a second close or new evidence', async t => {
  const f = await fixture(t); const server = await f.server(); const session = f.create(server.origin);
  await session.execute('S3'); assert.equal(await session.releaseResources(), true); session.noteCleanup(true);
  let target = '';
  f.io.before = async event => {
    if (target === '' && event.op === 'close' && event.path.includes('/details-')) {
      target = event.path; f.allowUncertain(target); throw ioError();
    }
  };
  await assert.rejects(session.writeEvidence('S3'), /ControllerEvidenceUncertain/);
  assert.equal(await session.releaseResources(), false); assert.equal(f.io.handles.size, 1);
  assert.equal(f.io.history.filter(event => event.op === 'close' && event.path === target).length, 1);
  assert.equal(f.facts(session).detailFile, undefined);
  const count = f.io.history.length; await session.writeEvidence('S3'); assert.equal(f.io.history.length, count);
});
