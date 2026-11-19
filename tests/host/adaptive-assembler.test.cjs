'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const { test } = require('node:test');
const { fixture, hold, within, ioError, plain, ID, codec } = require('./adaptive-assembler-harness.cjs');

function accepted(value, name = 'success') {
  assert.equal(value.status, name); assert.equal(value.closed, true);
  assert.equal(value.resourceUncertain, false); assert.equal(value.cleanupComplete, true);
}

test('F rejects invalid ownership, incomplete state and unsafe total before filesystem IO', async t => {
  const f = await fixture(t); const state = await f.complete(['x', 'y']);
  for (const change of [s => { s.downloadId = 'bad'; }, s => { s.parts[0].complete = false; },
    s => { s.parts[0].downloaded = Number.MAX_SAFE_INTEGER; s.parts[1].downloaded = 1; },
    s => { s.parts[0].fileName = '../foreign'; }]) {
    const copied = plain(state); change(copied);
    assert.equal((await f.assembler().run(copied)).status, 'invalid');
    assert.equal(f.adapter.history.length, 0);
  }
  assert.equal((await f.assembler('invalid').run(state)).status, 'invalid');
  assert.equal((await f.assembler(ID, '../relative').run(state)).status, 'invalid');
  assert.equal(f.adapter.history.length, 0);
});

test('F single-track assembly consumes exact committed prefixes, including empty parts', async t => {
  const f = await fixture(t); const state = await f.complete(['ab', '', 'cdef']);
  await fs.appendFile(f.file('input-0.part'), 'UNCOMMITTED');
  await fs.appendFile(f.file('input-1.part'), 'IGNORED');
  const before = codec.encodeAdaptiveState(state);
  const output = await f.assembler().run(state);
  accepted(output); assert.equal(output.extension, '.ts'); assert.equal(output.outputBytes, 6);
  assert.equal(await fs.readFile(f.file(output.outputName), 'utf8'), 'abcdef');
  assert.equal(await fs.readFile(f.file('input-0.part'), 'utf8'), 'abUNCOMMITTED');
  assert.equal(codec.encodeAdaptiveState(state), before);
  assert.deepEqual(plain(output.retainedNames), [output.outputName]);
  assert.equal(f.nativeCalls.length, 0); assert.equal(output.mediaStarted, false);
  assert.equal(f.adapter.history.filter(e => e.op === 'open' && e.path.endsWith('input-1.part')).length, 1);
});

test('F short reads/writes preserve 2 MiB bytes with one reader, one writer and bounded buffers', async t => {
  const f = await fixture(t); const bytes = Buffer.alloc(2 * 1024 * 1024 + 17);
  for (let i = 0; i < bytes.length; i++) bytes[i] = i % 251;
  const state = await f.complete([bytes]);
  f.adapter.shortRead = 12289; f.adapter.shortWrite = 4097;
  const result = await f.assembler().run(state); accepted(result);
  assert.deepEqual(await fs.readFile(f.file(result.outputName)), bytes);
  assert.equal(f.adapter.peakHandles, 2); assert.equal(f.adapter.peakPending, 1);
  assert.ok(Math.max(...f.allocations) <= 65536);
  assert.ok(f.adapter.history.filter(e => e.op === 'read' || e.op === 'write').every(e => e.bytes <= 65536));
});

test('F dual-track interleaving, MAP and discontinuity retain per-track order', async t => {
  const f = await fixture(t);
  const state = await f.fromLines(['#EXT-X-MAP:URI="init.mp4"', 'v1.m4s', '#EXT-X-DISCONTINUITY', 'v2.m4s'],
    ['#EXT-X-MAP:URI="audio.mp4"', 'a1.m4a'], ['VI', 'AI', 'V1', 'A1', 'V2']);
  const result = await f.assembler().run(state); accepted(result);
  assert.equal(result.extension, '.mp4'); assert.equal(result.mediaStarted, true); assert.equal(result.mediaSettled, true);
  assert.equal(f.nativeCalls.length, 1);
  const call = f.nativeCalls[0];
  assert.equal(await fs.readFile(f.adapter.real(call.video), 'utf8'), 'VIV1V2');
  assert.equal(await fs.readFile(f.adapter.real(call.audio), 'utf8'), 'AIA1');
  assert.equal(await fs.readFile(f.file(result.outputName), 'utf8'), 'VIV1V2|AIA1');
  assert.equal(result.retainedNames.length, 3);
  const nativeStart = f.adapter.history.findIndex(e => e.op === 'lstat' && e.path.endsWith('.mp4'));
  assert.ok(f.adapter.history.slice(0, nativeStart).filter(e => e.op === 'close').length >= 7);
});

test('F single .mp4 and mixed dual .mkv preserve the accepted plan/container contract', async t => {
  const f = await fixture(t); const single = await f.complete(['v'], null, ['mp4', 'm4a']);
  accepted(await f.assembler().run(single)); assert.equal(f.nativeCalls.length, 0);
  const dual = await f.complete(['v'], ['a'], ['ts', 'm4a']);
  assert.equal(dual.plan.suggestedExtension, '.mkv');
  const result = await f.assembler().run(dual); accepted(result);
  assert.equal(result.extension, '.mkv'); assert.equal(f.nativeCalls[0].format, 'matroska');
});

for (const code of ['UNSUPPORTED_STREAM', 'INVALID_DATA']) {
  test('F dual .ts accepts only existing native fallback for ' + code, async t => {
    const f = await fixture(t); const state = await f.complete(['video'], ['audio']);
    assert.equal(state.plan.suggestedExtension, '.ts');
    f.setNative(async call => {
      if (call.format === 'mp4') return f.nativeResult(call, 'failed', code);
      await fs.writeFile(f.adapter.real(call.output), 'mkv', { flag: 'wx' });
      return f.nativeResult(call, 'success', 'NONE', { outputBytes: 3, warnings: ['CHAPTERS_NOT_COPIED'] });
    });
    const result = await f.assembler().run(state); accepted(result);
    assert.equal(result.extension, '.mkv'); assert.deepEqual(f.nativeCalls.map(c => c.format), ['mp4', 'matroska']);
    assert.deepEqual(plain(result.warnings), ['CHAPTERS_NOT_COPIED']);
  });
}

for (const code of ['OUTPUT_IO', 'RESOURCE_LIMIT', 'CODEC_UNAVAILABLE']) {
  test('F native ' + code + ' is reported without an unsupported extra fallback', async t => {
    const f = await fixture(t); const state = await f.complete(['v'], ['a']);
    f.setNative(async call => f.nativeResult(call, code === 'RESOURCE_LIMIT' ? 'busy' : 'failed', code));
    const result = await f.assembler().run(state); accepted(result, 'mediaError');
    assert.equal(result.errorCode, 'Media_' + code); assert.equal(f.nativeCalls.length, 1);
    assert.equal(result.outputName, ''); assert.equal(result.retainedNames.length, 2);
  });
}

for (const shape of ['missing', 'short', 'directory']) {
  test('F ' + shape + ' committed input fails without touching source/state files', async t => {
    const f = await fixture(t); const state = await f.complete(['abcdef']);
    const target = f.file('input-0.part');
    if (shape === 'missing') await fs.unlink(target);
    else if (shape === 'short') await fs.truncate(target, 2);
    else { await fs.unlink(target); await fs.mkdir(target); }
    const result = await f.assembler().run(state); accepted(result, 'ioError');
    assert.equal(result.retainedNames.length, 0); assert.equal(f.nativeCalls.length, 0);
    assert.equal(f.adapter.history.some(e => e.op === 'unlink' && e.path.endsWith('input-0.part')), false);
  });
}

test('F existing candidate and native-output collisions remain untouched', async t => {
  const namespace = '11111111-1111-4111-8111-111111111111';
  for (const suffix of ['-0.part', '.mp4', '.mkv']) {
    const f = await fixture(t); const state = await f.complete(['v'], ['a']); f.uuids.push(namespace);
    const name = 'asm-' + namespace + suffix; await fs.writeFile(f.file(name), 'foreign');
    const result = await f.assembler().run(state); accepted(result, 'ioError');
    assert.equal(await fs.readFile(f.file(name), 'utf8'), 'foreign');
    assert.equal(f.adapter.history.some(e => (e.op === 'open' || e.op === 'unlink') && e.path === f.virtual(name)), false);
    assert.equal(f.nativeCalls.length, 0);
  }
});

test('F zero, negative and oversized read counts fail and close the input exactly once', async t => {
  for (const count of [0, -1, NaN, Infinity, 99]) {
    const f = await fixture(t); const state = await f.complete(['abc']);
    f.adapter.after = async (event, value) => event.op === 'read' ? count : value;
    const result = await f.assembler().run(state); accepted(result, 'ioError');
    assert.equal(result.errorCode, 'AssemblyShortInput');
    assert.equal(f.adapter.history.filter(e => e.op === 'close' && e.path.endsWith('input-0.part')).length, 1);
  }
});

test('F actual fd metadata is verified even when path metadata was sufficient', async t => {
  const f = await fixture(t); const state = await f.complete(['abcdef']);
  f.adapter.after = async (event, value) => event.op === 'stat' && event.path.endsWith('input-0.part') ?
    { size: 2, isFile: () => true, isDirectory: () => false } : value;
  const result = await f.assembler().run(state); accepted(result, 'ioError');
  assert.equal(f.adapter.history.some(e => e.op === 'read'), false);
});

test('F cancellation at every real IO boundary retains truthful resource facts', async t => {
  const baseline = await fixture(t); const initial = await baseline.complete(['abc']);
  accepted(await baseline.assembler().run(initial));
  const events = baseline.adapter.history.map(e => ({ op: e.op, index: e.index, nativeCompleted: e.nativeCompleted }));
  let scenarios = 0;
  for (const event of events) {
    // ENOENT is a rejected native operation; there is no successful-return hook for that boundary.
    for (const timing of event.nativeCompleted ? ['before', 'after'] : ['before']) {
      const f = await fixture(t); const state = await f.complete(['abc']); const owner = f.assembler();
      const gate = hold(f, e => e.index === event.index && e.op === event.op, timing);
      const pending = owner.run(state); await gate.entered;
      let drained = false; owner.drain().then(() => { drained = true; });
      owner.cancel(); owner.cancel(); await Promise.resolve(); assert.equal(drained, false);
      gate.release(); const result = await within(pending, 'cancelled assembly'); gate.reached();
      assert.equal(result.stopRequested, true); assert.equal(result.closed, true); assert.equal(result.resourceUncertain, false);
      assert.ok(result.status === 'stopped' || (result.status === 'ioError' && !result.cleanupComplete));
      assert.equal(result.outputName, ''); assert.equal(f.nativeCalls.length, 0);
      assert.equal(await fs.readFile(f.file('input-0.part'), 'utf8'), 'abc'); scenarios++;
    }
  }
  t.diagnostic(JSON.stringify({ actualIoCancellationScenarios: scenarios }));
});

for (const timing of ['before', 'after']) {
  test('F input close ' + timing + ' rejection is sticky, single-attempt and defeats clean-stop claims', async t => {
    const f = await fixture(t); const state = await f.complete(['data']); const owner = f.assembler();
    f.adapter[timing] = async (event, value) => {
      if (event.op === 'close' && event.path.endsWith('input-0.part')) { owner.cancel(); throw ioError(); }
      return value;
    };
    if (timing === 'before') f.allowUncertain(f.virtual('input-0.part'));
    const result = await owner.run(state);
    assert.equal(result.status, 'ioError'); assert.equal(result.closed, false);
    assert.equal(result.resourceUncertain, true); assert.equal(result.cleanupComplete, false);
    assert.equal(f.adapter.history.filter(e => e.op === 'close' && e.path.endsWith('input-0.part')).length, 1);
    if (timing === 'before') {
      const handle = [...f.adapter.handles.values()][0]; assert.equal((await handle.stat()).isFile(), true);
    } else assert.equal(f.adapter.handles.size, 0);
  });
}

test('F adopts an already sealed receipt before a reentrant cancel returns it to the owner', async t => {
  const f = await fixture(t); const state = await f.complete(['sealed']); const owner = f.assembler();
  const seal = f.attempt.AdaptiveAttemptFile.prototype.seal;
  f.attempt.AdaptiveAttemptFile.prototype.seal = function (...args) {
    return seal.apply(this, args).then(value => { assert.equal(value.sealed, true); owner.cancel(); return value; });
  };
  const result = await owner.run(state); accepted(result, 'stopped');
  assert.equal(result.retainedNames.length, 1); assert.equal(result.outputName, '');
  assert.equal(await fs.readFile(f.file(result.retainedNames[0]), 'utf8'), 'sealed');
});

test('F caller state, listener mutations/exceptions and returned results cannot alter owned facts', async t => {
  const f = await fixture(t); const state = await f.complete(['one', 'two']); const owner = f.assembler();
  const gate = hold(f, e => e.op === 'lstat'); let observations = 0;
  const pending = owner.run(state, value => { observations++; value.copiedBytes = -1; throw new Error('observer'); });
  await gate.entered; state.parts[0].fileName = 'foreign.part'; state.parts[1].downloaded = 100;
  gate.release(); const result = await pending; accepted(result); assert.ok(observations > 0);
  assert.equal(await fs.readFile(f.file(result.outputName), 'utf8'), 'onetwo');
  result.retainedNames.length = 0; result.outputName = 'mutated'; owner.cancel();
  const again = await owner.drain(); accepted(again); assert.equal(again.retainedNames.length, 1);
  assert.equal(again.stopRequested, false); assert.notEqual(again.outputName, 'mutated');
  assert.equal((await owner.run(state)).status, 'invalid');
});

test('F cancel before run and a listener stop prevent all later work without revoking fixed success', async t => {
  const f = await fixture(t); const state = await f.complete(['a'], ['b']);
  const early = f.assembler(); early.cancel(); assert.equal((await early.drain()).status, 'new');
  accepted(await early.run(state), 'stopped'); assert.equal(f.adapter.history.length, 0);
  const owner = f.assembler(); const result = await owner.run(state, () => owner.cancel());
  accepted(result, 'stopped'); assert.equal(f.nativeCalls.length, 0);
  assert.equal(f.adapter.history.some(e => e.op === 'open' && e.path.endsWith('input-1.part')), false);
});

test('F pending run rejects reentry and drain waits for the actual owned native promise', async t => {
  const f = await fixture(t); const state = await f.complete(['v'], ['a']); const owner = f.assembler();
  const entered = f.gate(); const gate = f.gate(); let ended = false;
  f.setNative(async call => { entered.resolve(); await gate.promise; return f.nativeResult(call, 'cancelled', 'CANCELLED'); });
  f.setCancel(() => true);
  const pending = owner.run(state); await entered.promise;
  assert.equal((await owner.run(state)).status, 'busy'); owner.drain().then(() => { ended = true; });
  owner.cancel(); owner.cancel(); await new Promise(resolve => setImmediate(resolve));
  assert.equal(ended, false); assert.equal(f.nativeCancels.length, 1);
  gate.resolve(); const result = await pending; accepted(result, 'stopped');
  assert.equal(result.mediaSettled, true); assert.equal(result.retainedNames.length, 2);
});

test('F late successful native output is verified and retained even if cancel occurs during lstat', async t => {
  const f = await fixture(t); const state = await f.complete(['v'], ['a']); const owner = f.assembler();
  let postNative = false;
  f.setNative(async call => {
    await fs.writeFile(f.adapter.real(call.output), 'real-result', { flag: 'wx' }); postNative = true;
    return f.nativeResult(call, 'success', 'NONE', { outputBytes: 11 });
  });
  const gate = hold(f, e => postNative && e.op === 'lstat' && e.path.endsWith('.mp4'), 'after');
  const pending = owner.run(state); await gate.entered; owner.cancel(); gate.release();
  const result = await pending; accepted(result, 'stopped');
  assert.equal(result.retainedNames.length, 3); assert.equal(result.outputName, '');
  assert.equal(await fs.readFile(f.adapter.real(f.nativeCalls[0].output), 'utf8'), 'real-result');
  assert.equal(f.nativeCancels.length, 0, 'already settled native promise is not cancelled');
});

for (const mismatch of ['job', 'path', 'format', 'bytes', 'file']) {
  test('F rejects a native success with mismatched ' + mismatch + ' facts', async t => {
    const f = await fixture(t); const state = await f.complete(['v'], ['a']);
    f.setNative(async call => {
      await fs.writeFile(f.adapter.real(call.output), 'out', { flag: 'wx' });
      const value = f.nativeResult(call, 'success', 'NONE', { outputBytes: 3 });
      if (mismatch === 'job') value.jobId = 'foreign';
      if (mismatch === 'path') value.outputPath = '/foreign/private';
      if (mismatch === 'format') value.format = 'mp3';
      if (mismatch === 'bytes') value.outputBytes = 4;
      if (mismatch === 'file') { await fs.unlink(f.adapter.real(call.output)); await fs.mkdir(f.adapter.real(call.output)); }
      return value;
    });
    const result = await f.assembler().run(state);
    assert.equal(result.status, 'mediaError'); assert.equal(result.outputName, '');
    assert.equal(result.retainedNames.length, 2); assert.equal(result.cleanupComplete, false);
    assert.equal(f.adapter.history.some(e => e.path === '/foreign/private'), false);
  });
}

test('F output cleanup failures stay distinct from handle closure and do not erase sealed inputs', async t => {
  const f = await fixture(t); const state = await f.complete(['v'], ['a']);
  f.adapter.before = async event => {
    if (event.op === 'read' && event.path.endsWith('input-1.part')) throw ioError();
    if (event.op === 'unlink') throw ioError(13900012);
  };
  const result = await f.assembler().run(state);
  assert.equal(result.status, 'ioError'); assert.equal(result.closed, true); assert.equal(result.resourceUncertain, false);
  assert.equal(result.cleanupComplete, false); assert.equal(result.retainedNames.length, 1);
  assert.equal(await fs.readFile(f.file(result.retainedNames[0]), 'utf8'), 'v');
  assert.equal(f.nativeCalls.length, 0);
});

test('F warning and failure fields do not expose arbitrary native text', async t => {
  const f = await fixture(t); const state = await f.complete(['v'], ['a']);
  f.setNative(async call => {
    await fs.writeFile(f.adapter.real(call.output), 'out', { flag: 'wx' });
    return f.nativeResult(call, 'success', 'NONE', { outputBytes: 3,
      warnings: ['secret token', 'INVALID_COVER_ART', 'INVALID_COVER_ART', ...Array(100).fill('private')] });
  });
  const result = await f.assembler().run(state); accepted(result);
  assert.deepEqual(plain(result.warnings), ['UNRECOGNIZED_MEDIA_WARNING', 'INVALID_COVER_ART']);
  assert.ok(!JSON.stringify(result).includes('secret'));
});

test('F cancellation of its queued media leaves another queue owner running', async t => {
  const f = await fixture(t); const state = await f.complete(['v'], ['a']);
  const externalEntered = f.gate(); const externalDone = f.gate();
  f.setNative(async call => {
    assert.equal(call.id, 'external-owner', 'the cancelled queued assembly must never reach native');
    externalEntered.resolve(); await externalDone.promise;
    await fs.writeFile(f.adapter.real(call.output), 'external', { flag: 'wx' });
    return f.nativeResult(call, 'success', 'NONE', { outputBytes: 8 });
  });
  const other = f.processor.remux('external-owner', f.virtual('input-0.part'), f.virtual('input-1.part'), f.virtual('external.mp4'));
  await externalEntered.promise;
  const submitted = f.gate(); const submit = f.processor.remuxWithFallback;
  f.processor.remuxWithFallback = function (...args) {
    const result = submit.apply(this, args); submitted.resolve(); return result;
  };
  const owner = f.assembler(); const pending = owner.run(state); await submitted.promise;
  owner.cancel(); const result = await within(pending, 'queued assembly cancellation');
  accepted(result, 'stopped'); assert.equal(result.mediaStarted, true); assert.equal(result.mediaSettled, true);
  assert.equal(f.nativeCalls.length, 1); assert.equal(f.nativeCancels.length, 0);
  externalDone.resolve(); assert.equal((await other).status, 'success');
  assert.equal(await fs.readFile(f.file('external.mp4'), 'utf8'), 'external');
});

for (const cancelKind of ['false', 'throw']) {
  test('F late ' + cancelKind + ' native cancel stops a future fallback while preserving the actual failure', async t => {
    const f = await fixture(t); const state = await f.complete(['v'], ['a']); const owner = f.assembler();
    f.setCancel(() => { if (cancelKind === 'throw') throw new Error('cancel failed'); return false; });
    f.setNative(async call => {
      assert.equal(call.format, 'mp4');
      // This adapter has fixed the native failure before requesting stop; its promise continuation is pending.
      const failed = f.nativeResult(call, 'failed', 'UNSUPPORTED_STREAM'); owner.cancel(); return failed;
    });
    const result = await owner.run(state); accepted(result, 'mediaError');
    assert.equal(result.stopRequested, true); assert.equal(result.errorCode, 'Media_UNSUPPORTED_STREAM');
    assert.equal(result.retainedNames.length, 2); assert.equal(f.nativeCalls.length, 1); assert.equal(f.nativeCancels.length, 1);
  });
}
