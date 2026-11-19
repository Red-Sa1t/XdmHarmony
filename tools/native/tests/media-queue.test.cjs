'use strict';
// These tests execute the production ArkTS FIFO with a typed native adapter.
// They verify scheduling policy, not FFmpeg output or device execution.
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadProduction } = require('../../../tests/host/production-loader.cjs');

function setup() {
  const intervals = new Map();
  let timerSequence = 0;
  const calls = [];
  const cancelCalls = [];
  const native = {
    capabilities() { return { apiVersion: 1, remuxMp4: true, remuxMatroska: true, encodeMp3: true, maxActiveJobs: 1 }; },
    remux(id, video, audio, output, format) { return this.start({ id, video, audio, output, format, operation: 'remux' }); },
    toMp3(id, audio, output) { return this.start({ id, audio, output, format: 'mp3', operation: 'mp3' }); },
    start(details) {
      let resolve, reject;
      const promise = new Promise((ok, no) => { resolve = ok; reject = no; });
      calls.push({ ...details, resolve, reject, settled: false, cancelled: false });
      return promise;
    },
    cancel(id) {
      cancelCalls.push(id);
      const active = calls.find(call => call.id === id && !call.settled);
      if (!active || active.cancelled) return false;
      active.cancelled = true;
      return true;
    },
    progress(id) {
      const active = calls.find(call => call.id === id && !call.settled);
      return { jobId: id, found: !!active, phase: 'encode', processedTimeMs: 800, totalTimeMs: 1000,
        cancelRequested: !!active?.cancelled };
    }
  };
  const loaded = loadProduction(path.resolve(__dirname, '../../../entry/src/main/ets/core/media/MediaProcessorNapi.ets'),
    { 'libxdm_media.so': { default: native } }, {
      setInterval(callback, milliseconds) {
        assert.equal(milliseconds, 1000);
        intervals.set(++timerSequence, callback);
        return timerSequence;
      },
      clearInterval(id) { intervals.delete(id); }
    });
  const processor = new loaded.MediaProcessorNapi(native);
  function finish(index, status = 'success', code = 'NONE') {
    const call = calls[index];
    assert.ok(call && !call.settled);
    call.settled = true;
    call.resolve({ jobId: call.id, status, errorCode: code, nativeCode: status === 'success' ? 0 : -1,
      phase: 'close', outputPath: status === 'success' ? call.output : '', format: call.format,
      outputBytes: status === 'success' ? 123 : 0, durationMs: status === 'success' ? 1000 : -1, warnings: [] });
  }
  return { processor, native, calls, finish, intervals, cancelCalls,
    tick() { for (const callback of [...intervals.values()]) callback(); } };
}

const flush = () => new Promise(resolve => setImmediate(resolve));
const audio = '/sandbox/audio.wav';
const video = '/sandbox/video.mp4';

test('one active job plus 16 waiting; overflow resolves busy and FIFO drains', async () => {
  const context = setup();
  const promises = [];
  for (let i = 0; i < 17; i++) promises.push(context.processor.toMp3(`job-${i}`, audio, `/sandbox/${i}.part`));
  assert.equal(context.calls.length, 1);
  assert.equal(context.processor.progress('job-1').phase, 'queued');
  const overflow = await context.processor.toMp3('overflow', audio, '/sandbox/overflow.part');
  assert.equal(overflow.status, 'busy');
  assert.equal(overflow.errorCode, 'RESOURCE_LIMIT');
  for (let i = 0; i < 17; i++) {
    assert.equal(context.calls[i].id, `job-${i}`);
    assert.equal(context.calls.length, i + 1);
    context.finish(i);
    assert.equal((await promises[i]).status, 'success');
  }
  assert.equal(context.intervals.size, 0);
});

test('queued cancellation settles without touching native; repeated cancellation returns false', async () => {
  const context = setup();
  const first = context.processor.toMp3('first', audio, '/sandbox/first.part');
  const second = context.processor.toMp3('second', audio, '/sandbox/second.part');
  assert.equal(context.processor.cancel('second'), true);
  assert.equal(context.processor.cancel('second'), false);
  assert.equal((await second).status, 'cancelled');
  assert.equal(context.calls.length, 1);
  assert.equal(context.cancelCalls.length, 0);
  context.finish(0);
  await first;
});

test('active cancellation waits for native cleanup and clears the progress timer', async () => {
  const context = setup();
  let observed = 0;
  let settled = false;
  const operation = context.processor.toMp3('cancel', audio, '/sandbox/cancel.part', () => observed++);
  operation.then(() => { settled = true; });
  context.tick();
  assert.equal(observed, 1);
  assert.equal(context.processor.cancel('cancel'), true);
  assert.equal(context.intervals.size, 0);
  assert.equal(context.processor.cancel('cancel'), false);
  await flush();
  assert.equal(settled, false);
  context.finish(0, 'cancelled', 'CANCELLED');
  assert.equal((await operation).status, 'cancelled');
});

test('a late cancellation cannot falsify a committed native success', async () => {
  const context = setup();
  const operation = context.processor.toMp3('late', audio, '/sandbox/late.part');
  context.finish(0);
  assert.equal(context.processor.cancel('late'), false);
  const result = await operation;
  assert.equal(result.status, 'success');
  assert.equal(result.outputPath, '/sandbox/late.part');
});

test('MP4 incompatibility retries once as Matroska and retains FIFO ownership', async () => {
  const context = setup();
  const operation = context.processor.remuxWithFallback('merge', video, audio, '/sandbox/video.part', '/sandbox/fallback.part');
  const next = context.processor.toMp3('next', audio, '/sandbox/next.part');
  context.finish(0, 'failed', 'UNSUPPORTED_STREAM');
  await flush();
  assert.equal(context.calls.length, 2);
  assert.equal(context.calls[1].id, 'merge');
  assert.equal(context.calls[1].format, 'matroska');
  assert.equal(context.calls[1].output, '/sandbox/fallback.part');
  context.finish(1);
  const result = await operation;
  assert.equal(result.outputPath, '/sandbox/fallback.part');
  assert.equal(result.format, 'matroska');
  assert.equal(context.calls[2].id, 'next');
  context.finish(2);
  await next;
});

test('IO, missing input, busy, and cancellation do not trigger format retries', async () => {
  for (const [status, code] of [['failed', 'OUTPUT_IO'], ['failed', 'INPUT_NOT_FOUND'],
    ['failed', 'OUTPUT_EXISTS'], ['busy', 'BUSY'], ['cancelled', 'CANCELLED']]) {
    const context = setup();
    const operation = context.processor.remuxWithFallback('merge', video, audio, '/sandbox/one.part', '/sandbox/two.part');
    context.finish(0, status, code);
    assert.equal((await operation).errorCode, code);
    assert.equal(context.calls.length, 1);
  }
});

test('invalid paths, duplicate IDs and unsafe fallback names fail before native', async () => {
  const context = setup();
  const first = context.processor.toMp3('duplicate', audio, '/sandbox/first.part');
  const cases = [
    context.processor.toMp3('duplicate', audio, '/sandbox/second.part'),
    context.processor.toMp3('path', 'https://example.com/audio.wav', '/sandbox/url.part'),
    context.processor.toMp3('nul', '/sandbox/a\0.wav', '/sandbox/nul.part'),
    context.processor.toMp3('../traverse', audio, '/sandbox/traverse.part'),
    context.processor.toMp3('same', audio, audio),
    context.processor.remuxWithFallback('fallback', video, audio, '/sandbox/output.part', audio)
  ];
  for (const promise of cases) assert.equal((await promise).errorCode, 'INVALID_ARGUMENT');
  assert.equal(context.calls.length, 1);
  context.finish(0);
  await first;
});

test('bridge rejection and throwing observers cannot strand later jobs', async () => {
  const context = setup();
  const first = context.processor.toMp3('throws', audio, '/sandbox/throws.part', () => { throw new Error('observer'); });
  const second = context.processor.toMp3('next', audio, '/sandbox/next.part');
  context.tick();
  context.calls[0].settled = true;
  context.calls[0].reject(new Error('bridge exception'));
  assert.equal((await first).errorCode, 'INTERNAL');
  assert.equal(context.calls.length, 2);
  assert.equal(context.intervals.size, 0);
  context.finish(1);
  assert.equal((await second).status, 'success');
});

test('dispose clears listeners, cancels pending jobs, and waits for the active native result', async () => {
  const context = setup();
  let observed = 0;
  const first = context.processor.toMp3('active', audio, '/sandbox/active.part', () => observed++);
  const second = context.processor.toMp3('queued', audio, '/sandbox/queued.part');
  context.processor.dispose();
  context.processor.dispose();
  assert.equal(context.intervals.size, 0);
  context.tick();
  assert.equal(observed, 0);
  assert.equal((await second).status, 'cancelled');
  assert.equal(context.calls.length, 1);
  assert.deepEqual(context.cancelCalls, ['active']);
  assert.equal((await context.processor.toMp3('closed', audio, '/sandbox/closed.part')).status, 'failed');
  context.finish(0, 'cancelled', 'CANCELLED');
  assert.equal((await first).status, 'cancelled');
});
