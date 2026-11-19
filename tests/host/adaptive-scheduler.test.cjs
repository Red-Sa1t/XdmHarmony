'use strict';
// Production ETS with real B dependencies; injected receipts are pure facts, not IO acceptance.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { performance } = require('node:perf_hooks');
const { test } = require('node:test');
const { loadProduction } = require('./production-loader.cjs');
const source = path.resolve(__dirname, '../../entry/src/main/ets/core/adaptive');
const model = loadProduction(path.join(source, 'HlsModel.ets'), {}, { Error });
const parser = loadProduction(path.join(source, 'HlsParser.ets'), { './HlsModel': model }, { Error });
const plan = loadProduction(path.join(source, 'AdaptivePlan.ets'), { './DashModel': require('./production-loader.cjs').loadProduction(require('node:path').resolve(__dirname, '../../entry/src/main/ets/core/adaptive/DashModel.ets'), {}, { Error }),  './HlsModel': model, './HlsParser': parser }, { Error });
const codec = loadProduction(path.join(source, 'AdaptiveStateCodec.ets'), { './AdaptivePlan': plan }, { Error });
const protocol = loadProduction(path.join(source, 'AdaptiveProtocol.ets'), { './AdaptivePlan': plan }, { Error });
const scheduler = loadProduction(path.join(source, 'AdaptiveScheduler.ets'), {
  './AdaptivePlan': plan, './AdaptiveStateCodec': codec
}, { Error });
const ID = '01234567-89ab-cdef-0123-456789abcdef';
const PRIMARY = 'https://media.example/video.m3u8';
const SECONDARY = 'https://media.example/audio.m3u8';
const plain = value => JSON.parse(JSON.stringify(value));
function playlist(count, known = true) {
  const value = new model.HlsPlaylist(); value.hasByteRange = known;
  for (let i = 0; i < count; i++) {
    const segment = new model.HlsMediaSegment(); segment.url = 'https://media.example/s' + i + '.ts'; segment.sequence = i;
    if (known) { segment.byteRange = new model.HlsByteRange(); segment.byteRange.offset = 90; segment.byteRange.length = 10; }
    value.segments.push(segment);
  }
  return value;
}
function state(count = 2, known = true, secondaryCount = 0) {
  const value = codec.newAdaptiveState(ID, plan.buildHlsPlan(PRIMARY, playlist(count, known),
    secondaryCount ? SECONDARY : '', secondaryCount ? playlist(secondaryCount, known) : null));
  assert.ok(value, 'valid production state fixture'); return value;
}
function saved(part, bytes, complete = false, fileName = 'saved_' + part.chunkId + '.part') {
  part.downloaded = bytes; part.complete = complete; part.fileName = fileName;
}
function limits(segments = 2, retries = 1, delay = 10) {
  const value = new scheduler.AdaptiveSchedulerLimits();
  value.maxSegments = segments; value.maxRetry = retries; value.retryDelayMs = delay; return value;
}
function run(value = state(), segments = 2, retries = 1, delay = 10, module = scheduler, token = 'runA') {
  const result = module.createAdaptiveScheduler(token, value, limits(segments, retries, delay));
  assert.ok(result, 'valid scheduler fixture'); return result;
}
function receipt(dispatch, outcome = 'complete', bytes = 10, reset = false) {
  const value = new scheduler.AdaptiveSettlement();
  value.identity = Object.assign(new scheduler.AdaptiveAttemptIdentity(), dispatch.identity);
  value.outcome = outcome; value.whole200Reset = reset;
  value.errorCode = outcome === 'retryable' ? 'TransportFailure' : outcome === 'fatal' ? 'DiskFailure' : '';
  if (bytes >= 0) {
    value.sealedPart = new plan.AdaptivePartState();
    value.sealedPart.chunkId = dispatch.identity.chunkId; value.sealedPart.downloaded = bytes;
    value.sealedPart.complete = outcome === 'complete'; value.sealedPart.fileName = dispatch.candidateFileName;
  }
  return value;
}
function quiesced(value) { const result = value.takeQuiesced(); assert.ok(result, 'scheduler quiesced'); return result; }
function assertCodec(value, owner) {
  const snapshot = plain(value); snapshot.parts = plain(owner.snapshotParts());
  assert.ok(codec.decodeAdaptiveState(codec.encodeAdaptiveState(snapshot), ID));
}

test('actual B partitions govern lane count and every unfinished chunk is claimed once in lane order', () => {
  for (const count of [1, 2, 3, 5, 7, 65]) {
    for (const cap of [1, 2, 4, 8, 64, 100]) {
      const value = state(count);
      for (let i = 1; i < count; i += 3) saved(value.parts[i], 10, true);
      const expected = plan.partitionAdaptiveChunks(value.parts, cap).map(range =>
        value.parts.slice(range.start, range.end + 1).filter(part => !part.complete).map(part => part.chunkId));
      const owner = run(value, cap); const seen = new Set(); let round = 0;
      while (expected.some(lane => lane.length)) {
        const dispatches = owner.claim(round, 100);
        assert.ok(dispatches.length > 0); assert.ok(dispatches.length <= expected.length);
        for (const dispatch of dispatches) {
          assert.equal(dispatch.chunk.id, expected[dispatch.identity.laneId].shift());
          assert.equal(seen.has(dispatch.chunk.id), false); seen.add(dispatch.chunk.id);
          assert.equal(owner.isCurrentAttempt(dispatch.identity), true); owner.settle(receipt(dispatch), round);
        }
        round++;
      }
      assert.equal(seen.size, value.parts.filter(part => !part.complete).length);
      assert.equal(quiesced(owner).readyForAssembly, true); assertCodec(value, owner);
    }
  }
});

test('claim publishes independent descriptors after ownership registration and honors available slots', () => {
  const owner = run(state(5), 4); assert.equal(owner.claim(0, 0).length, 0);
  const first = owner.claim(0, 1)[0]; const original = plain(first.identity);
  first.identity.chunkId = 'foreign'; first.chunk.offset = 999; first.prefix.downloaded = 999;
  assert.equal(owner.isCurrentAttempt(original), true);
  assert.equal(owner.claim(0, 1)[0].identity.laneId, 1); assert.equal(owner.claim(0, 100).length, 1);
  assert.equal(owner.claim(0, 100).length, 0); assert.equal(owner.snapshotParts()[0].downloaded, 0);
});

test('factory rejects invalid state, exact-shape limits, hostile tokens and unsafe integers', () => {
  for (const token of ['', '../run', 'run\n', 'run\r', 'run space', '中文', 'a'.repeat(65), null, 1]) {
    assert.equal(scheduler.createAdaptiveScheduler(token, state(), limits()), null);
  }
  assert.ok(scheduler.createAdaptiveScheduler('a'.repeat(64), state(), limits()));
  for (const key of ['maxSegments', 'maxRetry', 'retryDelayMs']) {
    for (const invalid of [-1, 0.5, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1, '1', null]) {
      const config = limits(); config[key] = invalid;
      assert.equal(scheduler.createAdaptiveScheduler('run', state(), config), null, key);
    }
  }
  for (const config of [null, {}, { ...limits(), extra: 1 }, { ...limits(), maxSegments: 0 },
    { ...limits(), maxRetry: Number.MAX_SAFE_INTEGER }]) assert.equal(scheduler.createAdaptiveScheduler('run', state(), config), null);
  const invalid = state(); saved(invalid.parts[0], 10, false);
  assert.equal(scheduler.createAdaptiveScheduler('run', invalid, limits()), null);
  assert.equal(scheduler.createAdaptiveScheduler('run', { ...state(), cookies: 'private' }, limits()), null);
});

test('retry budget survives accepted headers, progress checks and repeated partial sealing', () => {
  for (const retries of [0, 1, 10]) {
    const owner = run(state(1), 1, retries, 0);
    for (let i = 0; i <= retries; i++) {
      const dispatch = owner.claim(i, 1)[0]; const request = protocol.createAdaptiveWindow(dispatch.chunk, dispatch.prefix.downloaded);
      const head = new protocol.AdaptiveResponseHead(); head.status = 206;
      head.contentRange = ['bytes ' + request.remoteStart + '-' + request.remoteEnd + '/100'];
      head.contentLength = [String(10 - dispatch.prefix.downloaded)];
      for (let j = 0; j < 5; j++) {
        assert.equal(protocol.inspectAdaptiveHead(request, head).kind, 'accept');
        assert.equal(owner.mayReportProgress(dispatch.identity), true);
      }
      owner.settle(receipt(dispatch, 'retryable', 1), i);
    }
    const result = quiesced(owner);
    assert.equal(result.failureCode, 'RetryBudgetExhausted'); assert.equal(result.retryFailures, retries + 1);
    assert.equal(result.failureCount, 1); assert.equal(owner.claim(100, 1).length, 0);
  }
});

test('successful retry retains assembly eligibility and next chunk has an independent budget', () => {
  const value = state(2); const owner = run(value, 1, 1, 0);
  for (let i = 0; i < 2; i++) {
    const first = owner.claim(0, 1)[0]; owner.settle(receipt(first, 'retryable', 4), 0);
    const second = owner.claim(0, 1)[0]; assert.equal(second.prefix.downloaded, 4); owner.settle(receipt(second), 0);
  }
  const result = quiesced(owner);
  assert.equal(result.readyForAssembly, true); assert.equal(result.failureCount, 0); assert.equal(result.retryFailures, 2);
  assert.equal(result.downloadedBytes, 20); assertCodec(value, owner);
});

test('waiting retry uses an explicit deadline while siblings continue and duplicate wakes do nothing', () => {
  const owner = run(); const first = owner.claim(100, 2);
  owner.settle(receipt(first[0], 'retryable', 4), 100); assert.equal(owner.nextRetryAt(), 110);
  owner.settle(receipt(first[1]), 100); assert.equal(owner.takeQuiesced(), null);
  assert.equal(owner.claim(109, 2).length, 0); assert.equal(owner.claim(110, 2).length, 1);
  assert.equal(owner.claim(110, 2).length, 0); assert.equal(owner.nextRetryAt(), -1);
});

test('pause captures claimed-before-start owners and requires one settled receipt for each', () => {
  const owner = run(); const dispatches = owner.claim(0, 2); const stops = owner.requestPause();
  assert.equal(stops.length, 2); stops[0].chunkId = 'tampered';
  assert.equal(owner.requestPause().length, 0); assert.equal(owner.claim(100, 2).length, 0);
  assert.equal(owner.isCurrentAttempt(dispatches[0].identity), true); assert.equal(owner.mayReportProgress(dispatches[0].identity), false);
  owner.settle(receipt(dispatches[0], 'stopped', -1), 100); assert.equal(owner.takeQuiesced(), null);
  owner.settle(receipt(dispatches[1], 'stopped', -1), 100);
  const result = quiesced(owner); assert.equal(result.reason, 'pauseRequested'); assert.equal(result.failureCount, 0);
  assert.equal(owner.takeQuiesced(), null); assert.equal(owner.settle(receipt(dispatches[1]), 100).accepted, false);
});

test('pause and last completion are linearized in either order without discarding valid bytes', () => {
  for (const pauseFirst of [true, false]) {
    const value = state(1); value.generation = 7; const owner = run(value); const dispatch = owner.claim(0, 1)[0];
    if (pauseFirst) owner.requestPause();
    owner.settle(receipt(dispatch), 0);
    if (!pauseFirst) owner.requestPause();
    const result = quiesced(owner);
    assert.equal(result.reason, pauseFirst ? 'pauseRequested' : 'allPartsVerified');
    assert.equal(result.readyForAssembly, !pauseFirst); assert.equal(result.completedParts, 1);
    assert.equal(owner.snapshotParts()[0].complete, true); assert.equal(value.generation, 7);
    assert.equal(owner.takeQuiesced(), null); assertCodec(value, owner);
  }
});

test('fatal waits for all siblings and preserves first failure alongside later successful candidates', () => {
  const value = state(3); const owner = run(value, 3); const dispatches = owner.claim(0, 3);
  assert.equal(owner.settle(receipt(dispatches[0], 'fatal', 3), 0).stopAttempts.length, 2);
  owner.settle(receipt(dispatches[2]), 0); assert.equal(owner.takeQuiesced(), null);
  const last = receipt(dispatches[1], 'fatal', 4); last.errorCode = 'SealFailed';
  assert.equal(owner.settle(last, 0).stopAttempts.length, 0);
  const result = quiesced(owner);
  assert.equal(result.reason, 'fatal'); assert.equal(result.failureCode, 'DiskFailure'); assert.equal(result.failureCount, 2);
  assert.equal(result.downloadedBytes, 17); assert.equal(result.completedParts, 1); assert.equal(result.readyForAssembly, false);
  assertCodec(value, owner);
});

test('paused late retryable outcome does not invent exhaustion but independent sealing fault is retained', () => {
  const owner = run(state(), 2, 0); const dispatches = owner.claim(0, 2); owner.requestPause();
  owner.settle(receipt(dispatches[0], 'retryable', 4), 0); owner.settle(receipt(dispatches[1], 'fatal', -1), 0);
  const result = quiesced(owner);
  assert.equal(result.reason, 'pauseRequested'); assert.equal(result.failureCode, 'DiskFailure');
  assert.equal(result.failureCount, 1); assert.equal(owner.nextRetryAt(), -1); assert.equal(owner.claim(100, 2).length, 0);
});

test('old attempt, duplicate and foreign identities are ignored before clock or candidate handling', () => {
  const owner = run(state(1), 1, 1, 0); const first = owner.claim(0, 1)[0]; owner.settle(receipt(first, 'retryable', 4), 0);
  const second = owner.claim(0, 1)[0]; const before = plain(owner.snapshotParts());
  const invalid = [receipt(first), receipt(second), receipt(second), receipt(second), receipt(second)];
  invalid[1].identity.runToken = 'other'; invalid[2].identity.chunkId = 'c1';
  invalid[3].identity.laneId = 99; invalid[4].identity.downloadId = '11234567-89ab-cdef-0123-456789abcdef';
  for (const report of invalid) assert.equal(owner.settle(report, NaN).accepted, false);
  for (const identity of [null, undefined, [], {}, { ...second.identity, attemptId: NaN }, { ...second.identity, extra: 1 }]) {
    assert.equal(owner.settle({ ...receipt(second), identity }, NaN).accepted, false);
  }
  assert.deepEqual(plain(owner.snapshotParts()), before); assert.equal(owner.isCurrentAttempt(second.identity), true);
  owner.settle(receipt(second), 0); assert.equal(owner.settle(receipt(second), 0).accepted, false);
  assert.equal(quiesced(owner).readyForAssembly, true);
});

test('malformed current receipts fail explicitly without adopting a forged candidate', () => {
  const mutations = [value => { value.sealedPart = null; }, value => { value.sealedPart.downloaded = 9; },
    value => { value.sealedPart.downloaded = '10'; }, value => { value.sealedPart.complete = 'true'; },
    value => { value.sealedPart.chunkId = 'c1'; }, value => { value.sealedPart.fileName = 'foreign.part'; },
    value => { value.sealedPart.extra = true; }, value => { delete value.sealedPart.complete; },
    value => { value.outcome = 'success'; }, value => { value.errorCode = 'https://private/token'; },
    value => { value.errorCode = 'Failure\n'; }, value => { value.errorCode = 'A'.repeat(65); },
    value => { value.whole200Reset = true; }, value => { value.whole200Reset = 'false'; }, value => { value.extra = 1; }];
  for (const mutate of mutations) {
    const value = state(1); saved(value.parts[0], 4); const owner = run(value); const dispatch = owner.claim(0, 1)[0];
    const report = receipt(dispatch); mutate(report); const result = owner.settle(report, 0);
    assert.equal(result.accepted, true); assert.equal(result.candidateAccepted, false); assert.equal(result.code, 'InvalidReceipt');
    assert.equal(owner.isCurrentAttempt(dispatch.identity), false); assert.equal(owner.snapshotParts()[0].downloaded, 4);
    const done = quiesced(owner); assert.equal(done.failureCode, 'InvalidReceipt'); assert.doesNotMatch(JSON.stringify(done), /private|https/);
  }
});

test('null sealed result preserves the previous prefix even if a whole 200 reset was observed', () => {
  const value = state(1, false); saved(value.parts[0], 12); const owner = run(value); const dispatch = owner.claim(0, 1)[0];
  owner.settle(receipt(dispatch, 'retryable', -1, true), 0);
  assert.equal(owner.snapshotParts()[0].downloaded, 12); assert.equal(owner.snapshotParts()[0].fileName, 'saved_c0.part');
  assert.equal(owner.takeChanges().length, 0); assert.equal(owner.claim(10, 1)[0].prefix.downloaded, 12);
  assertCodec(value, owner);
});

test('only whole 200 reset permits a shorter candidate and aggregate bytes are replaced rather than added', () => {
  for (const outcome of ['complete', 'retryable']) {
    for (const reset of [true, false]) {
      const value = state(1, false); saved(value.parts[0], 12); const owner = run(value); const dispatch = owner.claim(0, 1)[0];
      const result = owner.settle(receipt(dispatch, outcome, 3, reset), 0);
      assert.equal(result.candidateAccepted, reset); assert.equal(owner.snapshotParts()[0].downloaded, reset ? 3 : 12);
      if (!reset) assert.equal(quiesced(owner).failureCode, 'InvalidReceipt');
      else if (outcome === 'complete') assert.equal(quiesced(owner).downloadedBytes, 3);
      else assert.equal(owner.claim(10, 1)[0].prefix.downloaded, 3);
      assertCodec(value, owner);
    }
  }
});

test('zero-byte complete whole files require an owned sealed filename while zero-byte partial is fresh', () => {
  const value = state(1, false); const owner = run(value); const dispatch = owner.claim(0, 1)[0];
  owner.settle(receipt(dispatch, 'complete', 0), 0); assert.equal(quiesced(owner).readyForAssembly, true); assertCodec(value, owner);
  for (const kind of ['partial', 'nameless', 'fullRange']) {
    const other = run(state(1, kind === 'fullRange')); const item = other.claim(0, 1)[0];
    const report = receipt(item, kind === 'partial' || kind === 'fullRange' ? 'retryable' : 'complete', kind === 'fullRange' ? 10 : 0);
    if (kind === 'nameless') report.sealedPart.fileName = '';
    other.settle(report, 0); assert.equal(quiesced(other).failureCode, 'InvalidReceipt');
  }
});

test('a candidate cannot borrow another active owner filename', () => {
  const value = state(); const owner = run(value); const dispatches = owner.claim(0, 2);
  const wrong = receipt(dispatches[0]); wrong.sealedPart.fileName = dispatches[1].candidateFileName;
  const result = owner.settle(wrong, 0); assert.equal(result.code, 'InvalidReceipt'); assert.equal(result.stopAttempts.length, 1);
  assert.equal(owner.isCurrentAttempt(dispatches[1].identity), true);
  owner.settle(receipt(dispatches[1]), 0); assert.equal(quiesced(owner).failureCount, 1); assertCodec(value, owner);
});

test('candidate allocation collision rejects a whole claim batch before any owner or attempt counter is changed', () => {
  const value = state(); saved(value.parts[1], 1, false, 'runA_2.part'); const owner = run(value);
  assert.throws(() => owner.claim(0, 2), { message: 'CandidateNameCollision' });
  const first = owner.claim(0, 1)[0]; assert.equal(first.identity.attemptId, 1);
  assert.equal(owner.requestPause().length, 1); assert.equal(owner.snapshotParts()[1].fileName, 'runA_2.part');
});

test('malformed or reversed claim and settlement clocks are transactional', () => {
  const owner = run(); const dispatch = owner.claim(100, 1)[0]; const report = receipt(dispatch, 'retryable', 4);
  for (const now of [99, -1, 0.5, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1, '100', null, true]) {
    assert.throws(() => owner.claim(now, 1), { message: 'InvalidClock' });
    assert.throws(() => owner.settle(report, now), { message: 'InvalidClock' });
  }
  for (const slots of [-1, 0.5, NaN, Infinity, '1', null]) assert.throws(() => owner.claim(100, slots), { message: 'InvalidSlots' });
  assert.equal(owner.isCurrentAttempt(dispatch.identity), true); assert.equal(owner.snapshotParts()[0].downloaded, 0);
  assert.equal(owner.takeChanges().length, 0); assert.equal(owner.nextRetryAt(), -1);
  assert.equal(owner.claim(100, 1)[0].identity.attemptId, 2);
  owner.settle(report, 100); assert.equal(owner.nextRetryAt(), 110);
});

test('deadline overflow does not update the clock, adopt a prefix or consume another retry', () => {
  const value = state(1); const owner = run(value); const now = Number.MAX_SAFE_INTEGER - 10;
  const dispatch = owner.claim(now, 1)[0]; const report = receipt(dispatch, 'retryable', 4);
  assert.throws(() => owner.settle(report, now + 1), { message: 'InvalidDeadline' });
  assert.equal(owner.isCurrentAttempt(dispatch.identity), true); assert.equal(owner.snapshotParts()[0].downloaded, 0);
  assert.equal(owner.takeChanges().length, 0); assert.equal(owner.nextRetryAt(), -1);
  owner.settle(report, now); assert.equal(owner.nextRetryAt(), Number.MAX_SAFE_INTEGER);
  const next = owner.claim(Number.MAX_SAFE_INTEGER, 1)[0]; assert.equal(next.identity.attemptId, 2);
  owner.settle(receipt(next), Number.MAX_SAFE_INTEGER); assert.equal(quiesced(owner).readyForAssembly, true); assertCodec(value, owner);
});

test('aggregate overflow leaves the receipt retryable by the caller with its original owner intact', () => {
  const value = state(2, false); saved(value.parts[0], Number.MAX_SAFE_INTEGER - 1, true);
  const owner = run(value); const dispatch = owner.claim(0, 1)[0];
  assert.throws(() => owner.settle(receipt(dispatch, 'complete', 2), 1), { message: 'ByteTotalOverflow' });
  assert.equal(owner.isCurrentAttempt(dispatch.identity), true); assert.equal(owner.takeChanges().length, 0);
  owner.settle(receipt(dispatch, 'complete', 1), 0);
  assert.equal(quiesced(owner).downloadedBytes, Number.MAX_SAFE_INTEGER); assertCodec(value, owner);
});

test('input plan, limits, dispatch, receipt, snapshots and dirty results never alias scheduler state', () => {
  const value = state(1); const config = limits(1, 1, 0); const owner = scheduler.createAdaptiveScheduler('runA', value, config);
  value.plan.chunks[0].url = 'https://changed.example/file.ts'; value.parts[0].downloaded = 9; config.maxRetry = 0;
  const dispatch = owner.claim(0, 1)[0]; const report = receipt(dispatch, 'retryable', 4);
  dispatch.identity.chunkId = 'foreign'; dispatch.chunk.offset = 1; dispatch.prefix.downloaded = 9; dispatch.candidateFileName = 'forged.part';
  assert.equal(owner.isCurrentAttempt(report.identity), true); owner.settle(report, 0); report.sealedPart.downloaded = 8;
  const changed = owner.takeChanges(); const snapshot = owner.snapshotParts(); changed[0].downloaded = 7; snapshot[0].downloaded = 6;
  assert.equal(owner.snapshotParts()[0].downloaded, 4);
  const retry = owner.claim(0, 1)[0]; assert.equal(retry.chunk.url, 'https://media.example/s0.ts');
  assert.equal(retry.prefix.downloaded, 4); owner.settle(receipt(retry), 0); assert.equal(quiesced(owner).readyForAssembly, true);
});

test('dirty state coalesces latest candidates per chunk, preserves source order and survives consumption in final summary', () => {
  const owner = run(state(), 2, 2, 0); const first = owner.claim(0, 2);
  owner.settle(receipt(first[1], 'retryable', 3), 0); owner.settle(receipt(first[0], 'retryable', 2), 0);
  const second = owner.claim(0, 2); owner.settle(receipt(second[1], 'retryable', 4), 0);
  const changes = owner.takeChanges(); assert.deepEqual(plain(changes.map(part => [part.chunkId, part.downloaded])), [['c0', 2], ['c1', 4]]);
  assert.equal(owner.takeChanges().length, 0); owner.requestPause(); owner.settle(receipt(second[0], 'stopped', -1), 0);
  const result = quiesced(owner); assert.equal(result.checkpointWanted, true); assert.equal(result.candidatesChanged, true);
});

test('attempt sequence overflow rejects the entire batch and never wraps identity', () => {
  const owner = run();
  // Boundary injection avoids quadrillions of setup calls; subsequent operations use production public methods.
  owner.attemptSequence = Number.MAX_SAFE_INTEGER - 1;
  assert.throws(() => owner.claim(0, 2), { message: 'AttemptIdExhausted' });
  const dispatch = owner.claim(0, 1)[0]; assert.equal(dispatch.identity.attemptId, Number.MAX_SAFE_INTEGER);
  assert.throws(() => owner.claim(0, 1), { message: 'AttemptIdExhausted' });
  assert.equal(owner.requestPause().length, 1); owner.settle(receipt(dispatch, 'stopped', -1), 0);
  assert.equal(quiesced(owner).reason, 'pauseRequested');
});

test('large 20000-part plan is validated once and one settlement never calls the full-state codec', t => {
  const value = state(10000, false, 10000);
  let remaining = plan.ADAPTIVE_MAX_PLAN_CHARS - JSON.stringify(value.plan).length;
  for (const chunk of value.plan.chunks) {
    const count = Math.min(remaining, model.HLS_MAX_URL_CHARS - chunk.url.length);
    chunk.url = chunk.url.slice(0, -3) + 'x'.repeat(count) + '.ts'; remaining -= count;
    if (remaining === 0) break;
  }
  assert.equal(remaining, 0); assert.equal(JSON.stringify(value.plan).length, plan.ADAPTIVE_MAX_PLAN_CHARS);
  for (const part of value.parts) saved(part, 5, false, (part.chunkId + '_').padEnd(120, 'x') + '.part');
  let codecCalls = 0; let partitionCalls = 0; let chunkCopies = 0;
  const observed = loadProduction(path.join(source, 'AdaptiveScheduler.ets'), {
    './AdaptivePlan': { ...plan,
      partitionAdaptiveChunks(...args) { partitionCalls++; return plan.partitionAdaptiveChunks(...args); },
      copyAdaptiveChunk(...args) { chunkCopies++; return plan.copyAdaptiveChunk(...args); } },
    './AdaptiveStateCodec': { ...codec, encodeAdaptiveState(...args) { codecCalls++; return codec.encodeAdaptiveState(...args); } }
  }, { Error });
  const start = performance.now(); const owner = run(value, 64, 1, 10, observed, 'largeRun'); const initialized = performance.now();
  assert.equal(codecCalls, 1); assert.equal(partitionCalls, 1);
  const dispatch = owner.claim(0, 1)[0]; const settleStart = performance.now();
  owner.settle(receipt(dispatch, 'retryable', 6), 0); const settled = performance.now();
  assert.equal(codecCalls, 1); assert.equal(partitionCalls, 1); assert.equal(chunkCopies, 1);
  const snapshotStart = performance.now(); const snapshot = owner.snapshotParts(); const snapshotEnd = performance.now();
  assert.equal(snapshot.length, 20000); assert.equal(snapshot[0].downloaded, 6); assert.equal(owner.takeChanges().length, 1);
  assert.equal(codecCalls, 1); assert.equal(partitionCalls, 1); assertCodec(value, owner);
  t.diagnostic(JSON.stringify({ scope: 'host-author-measurement', parts: value.parts.length,
    planChars: JSON.stringify(value.plan).length, stateChars: JSON.stringify(value).length,
    initializeMs: initialized - start, settleMs: settled - settleStart, snapshotMs: snapshotEnd - snapshotStart,
    schedulerCodecCalls: codecCalls, schedulerPartitionCalls: partitionCalls }));
});

test('static Hypium scheduler bodies execute against the same production ETS', t => {
  const cases = [];
  const shim = { describe: (_name, register) => register(), it: (name, _level, body) => cases.push({ name, body }),
    expect: value => ({ assertEqual: expected => assert.equal(value, expected),
      assertTrue: () => assert.equal(value, true), assertFalse: () => assert.equal(value, false) }) };
  const file = path.resolve(__dirname, '../../entry/src/test/AdaptiveScheduler.test.ets');
  const statics = [...fs.readFileSync(file, 'utf8').matchAll(/^\s*it\('([^']+)'/gm)].map(match => match[1]);
  loadProduction(file, { '@ohos/hypium': shim, '../main/ets/core/adaptive/HlsModel': model,
    '../main/ets/core/adaptive/HlsParser': parser, '../main/ets/core/adaptive/AdaptivePlan': plan,
    '../main/ets/core/adaptive/AdaptiveStateCodec': codec, '../main/ets/core/adaptive/AdaptiveScheduler': scheduler }, { Error }).default();
  assert.deepEqual(cases.map(item => item.name), statics); assert.equal(new Set(statics).size, statics.length);
  assert.equal(statics.length, 34);
  for (const item of cases) {
    try { assert.equal(item.body(), undefined); }
    catch (error) { throw new Error('Hypium ' + item.name + ': ' + error.message, { cause: error }); }
  }
  t.diagnostic('Executed ' + cases.length + ' static Hypium bodies; this is not SDK/Hypium-device execution.');
});
