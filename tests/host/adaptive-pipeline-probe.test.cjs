'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const { test } = require('node:test');
const { fixture, within, ioError } = require('./adaptive-pipeline-probe-harness.cjs');

test('P6-U5 S1 runs actual E3 Range bodies through E1 and C then publishes closed evidence', async t => {
  const f = await fixture(t); const server = await f.server(); const session = f.create(server.origin);
  const facts = await f.complete(session, 'S1');
  assert.equal(facts.generation, '1'); assert.equal(facts.parts, '2'); assert.equal(facts.readyForAssembly, 'true');
  assert.equal(facts.p0Bytes, '65536'); assert.equal(facts.p1Bytes, '65536');
  assert.equal(facts.p0Complete, 'true'); assert.equal(facts.p1Complete, 'true');
  assert.equal(facts.p0Sha256, '4b640d85ab3ba30fd02c9fc9db4a8928f416322ad27022ea58a65aaee68a4df2');
  assert.equal(facts.p1Sha256, 'fe89f108b4028dc360cbe69ce0ccbe4d9bc8af0123f731304b77327fd495a1f6');
  assert.equal(facts.a0Eof, 'true'); assert.equal(facts.a1Eof, 'true'); assert.equal(facts.gatePending, '0');
  assert.deepEqual(server.events.map(event => event.status), [206, 206]);
  assert.equal(facts.a0RequestStart, '0'); assert.equal(facts.a1RequestStart, '65536');
  assert.equal(facts.a0ResponseStatus, undefined, 'private response headers are not fabricated');
});

test('P6-U5 S3 stops a real slow transfer and commits only its actual sealed prefix', async t => {
  const f = await fixture(t); const server = await f.server(); const facts = await f.complete(f.create(server.origin), 'S3');
  assert.equal(facts.timerFired, 'true'); assert.equal(facts.a0Outcome, 'stopped');
  assert.equal(facts.p0Complete, 'false'); assert.ok(Number(facts.p0Bytes) < 524288);
  assert.equal(facts.readyForAssembly, 'false'); assert.equal(facts.a0ApiClosed, 'true'); assert.equal(facts.gatePending, '0');
});

test('P6-U5 S4 uses actual exact-prefix F output and leaves both state slots and physical tails intact', async t => {
  const f = await fixture(t); const facts = await f.complete(f.create(), 'S4');
  assert.equal(facts.asmStatus, 'success'); assert.equal(facts.asmBytes, '6');
  assert.equal(facts.asmMediaStarted, 'false'); assert.equal(facts.inputsUnchanged, 'true'); assert.equal(facts.slotsUnchanged, 'true');
  assert.equal(facts.outputSha256, 'bef57ec7f53a6d40beb640a780a639c83bc29ac8a9816f1fc6c5c6dcd93c4721');
});

test('P6-U5 S5 reaches the real F/media queue with correct full rawfile track bytes', async t => {
  const f = await fixture(t); const facts = await f.complete(f.create(), 'S5');
  assert.equal(facts.asmStatus, 'success'); assert.equal(facts.asmMediaStarted, 'true'); assert.equal(facts.asmMediaSettled, 'true');
  assert.equal(facts.videoTrackSha256, 'a9031eb264daacdb12b8b5f09d28cddedb41e94c59bce3bc53d30a29cfcc2254');
  assert.equal(facts.audioTrackSha256, 'bc07711e61565df03d063be18af19e2fc1ae23f36ea2845a41f21a1393ddb138');
  assert.equal(f.nativeCalls.length, 1);
  t.diagnostic('This case verifies the production probe/F/queue control flow with a controlled native API; actual native/decode evidence is a separate gate.');
});

test('P6-U5 S6 independently owns missing/cancelled fixtures and preserves their old inputs', async t => {
  const f = await fixture(t); const facts = await f.complete(f.create(), 'S6');
  assert.equal(facts.missingStatus, 'ioError'); assert.equal(facts.missingOutput, '');
  assert.equal(facts.missingKeptUnchanged, 'true'); assert.equal(facts.missingSlotsUnchanged, 'true');
  assert.equal(facts.cancelStatus, 'stopped'); assert.equal(facts.cancelStop, 'true');
  assert.equal(facts.cancelInputsUnchanged, 'true'); assert.equal(facts.cancelMediaStarted, 'false');
  assert.equal(f.nativeCalls.length, 0);
});

test('P6-U5 cancelled owner adopts a returned file before draining and never publishes stale evidence', async t => {
  const f = await fixture(t); const session = f.create();
  const gate = f.hold(event => event.op === 'open' && event.path.endsWith('.part'), 'after');
  const pending = session.execute('S4', f.raw); const rejection = assert.rejects(pending, /PipelineProbeStopped|PipelineFileUnavailable/);
  await gate.entered; session.cancel(); f.invalidate(); gate.release();
  await rejection; await within(session.releaseResources(), 'stale owner release');
  assert.equal(f.io.handles.size, 0);
  const calls = f.io.history.length;
  await assert.rejects(session.writeEvidence('S4'), /PipelineProbeStopped/);
  assert.equal(f.io.history.length, calls); assert.equal(f.facts(session).detailFile, undefined);
});

test('P6-U5 a C close rejection remains visible and suppresses all new evidence IO', async t => {
  const f = await fixture(t); const session = f.create(); let rejected = false; let uncertainPath = '';
  f.io.before = async event => {
    if (!rejected && event.op === 'close' && event.path.endsWith('.tmp')) {
      rejected = true; uncertainPath = event.path; f.allowUncertain(event.path); throw ioError();
    }
  };
  await assert.rejects(session.execute('S4', f.raw), /PipelineStateResourceUncertain/);
  assert.equal(rejected, true); assert.equal(await session.releaseResources(), false);
  assert.equal(f.io.handles.size, 1);
  assert.equal((await [...f.io.handles.values()][0].stat()).isFile(), true);
  const calls = f.io.history.length; await session.writeEvidence('S4');
  assert.equal(f.io.history.length, calls); assert.equal(f.facts(session).detailFile, undefined);
  assert.equal(f.io.history.filter(event => event.op === 'close' && event.path === uncertainPath).length, 1);
});

test('P6-U5 session token replacement rejects before new filesystem work', async t => {
  const f = await fixture(t); const session = f.create(); f.invalidate(); const calls = f.io.history.length;
  await assert.rejects(session.execute('S4', f.raw), /PipelineProbeStopped/);
  assert.equal(await session.releaseResources(), true); assert.equal(f.io.history.length, calls);
});

test('P6-U5 S2 actual 512 KiB/4 KiBps probe survives beyond 60 seconds and persists every byte',
  { skip: process.env.XDM_PIPELINE_LONG !== '1', timeout: 180000 }, async t => {
    const f = await fixture(t); const server = await f.server(); const facts = await f.complete(f.create(server.origin), 'S2');
    assert.equal(facts.sampleAt60, 'true'); assert.equal(facts.attemptPendingAt60, 'true');
    assert.ok(Number(facts.elapsedMs) > 60000); assert.equal(facts.a0Eof, 'true');
    assert.equal(facts.a0Written, '524288'); assert.equal(facts.p0Bytes, '524288'); assert.equal(facts.p0Complete, 'true');
    assert.equal(facts.p0Sha256, '61d1d9c5745bdaa4fab39240651bc242a5186b15393fd475082fcf6e84f400ab');
    assert.equal(server.events.length, 1); assert.equal(server.events[0].status, 200);
    assert.ok(Number(facts.a0QueueHigh) <= 65536);
    t.diagnostic(JSON.stringify({ scope: 'actual production probe over Node RCP boundary + real wire/FS', facts }));
  });
