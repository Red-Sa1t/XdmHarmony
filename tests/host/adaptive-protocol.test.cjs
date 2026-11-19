'use strict';
// Load the production ETS and its real pure dependencies. No mirror protocol implementation.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');
const { loadProduction } = require('./production-loader.cjs');
const source = path.resolve(__dirname, '../../entry/src/main/ets/core/adaptive');
const model = loadProduction(path.join(source, 'HlsModel.ets'), {}, { Error });
const parser = loadProduction(path.join(source, 'HlsParser.ets'), { './HlsModel': model }, { Error });
const plan = loadProduction(path.join(source, 'AdaptivePlan.ets'), { './DashModel': require('./production-loader.cjs').loadProduction(require('node:path').resolve(__dirname, '../../entry/src/main/ets/core/adaptive/DashModel.ets'), {}, { Error }),  './HlsModel': model, './HlsParser': parser }, { Error });
const protocol = loadProduction(path.join(source, 'AdaptiveProtocol.ets'), { './AdaptivePlan': plan }, { Error });
const plain = value => JSON.parse(JSON.stringify(value));
function chunk(length = 10, offset = 90) {
  const value = new plan.AdaptiveChunk();
  value.id = 'c0'; value.url = 'https://media.example/s.ts'; value.length = length; value.offset = offset; return value;
}
function window(length = 10, offset = 90, prefix = 0, total = -1) {
  const value = protocol.createAdaptiveWindow(chunk(length, offset), prefix, total);
  assert.ok(value, 'valid window fixture'); return value;
}
function head(status = 206, range = 'bytes 90-99/100', length = '10') {
  const value = new protocol.AdaptiveResponseHead(); value.status = status;
  if (range !== '') value.contentRange.push(range);
  if (length !== '') value.contentLength.push(length); return value;
}
function body(received, written = received, ended = true) {
  const value = new protocol.AdaptiveBodyFacts();
  value.receivedBytes = received; value.writtenBytes = written; value.streamEnded = ended; return value;
}

test('range windows preserve the closed remote range and independent local prefix', () => {
  for (const offset of [0, 1, 90, Number.MAX_SAFE_INTEGER - 20]) {
    for (const length of [1, 2, 10, 20]) {
      for (const prefix of new Set([0, length - 1])) {
        const value = window(length, offset, prefix);
        assert.equal(value.remoteStart, offset + prefix); assert.equal(value.remoteEnd, offset + (length - 1));
        assert.equal(value.prefixBytes, prefix); assert.equal(value.chunkLength, length);
      }
    }
  }
  assert.equal(protocol.createAdaptiveWindow(chunk(2, Number.MAX_SAFE_INTEGER), 0), null);
  assert.equal(protocol.createAdaptiveWindow(chunk(), 10), null);
  assert.equal(protocol.createAdaptiveWindow(chunk(), 0, 99), null);
});

test('forged request windows and scalar fields cannot reach response acceptance', () => {
  const mutations = [value => { value.remoteStart++; }, value => { value.remoteEnd--; },
    value => { value.chunkId = 'c0\n'; }, value => { value.prefixBytes = '0'; },
    value => { value.chunkLength = Infinity; }, value => { value.chunkOffset = -1; },
    value => { value.knownResourceTotal = NaN; }, value => { value.extra = true; },
    value => { delete value.remoteEnd; }];
  for (const mutate of mutations) {
    const value = window(); mutate(value);
    assert.equal(protocol.inspectAdaptiveHead(value, head()).code, 'InvalidWindow');
    assert.equal(protocol.inspectAdaptiveTransfer(value, head(), body(10)).code, 'InvalidWindow');
  }
  for (const value of [null, undefined, [], 0, 'window']) assert.equal(protocol.inspectAdaptiveHead(value, head()).code, 'InvalidWindow');
});

test('Content-Range parses strict decimal syntax including the largest safe endpoint', () => {
  for (const [text, expected] of [
    ['BYTES\t000-009/0010', ['range', 0, 9, 10]], [' bytes 7-9/*\t', ['range', 7, 9, -1]],
    ['bytes */0', ['unsatisfied', -1, -1, 0]],
    ['bytes 9007199254740991-9007199254740991/*', ['range', Number.MAX_SAFE_INTEGER, Number.MAX_SAFE_INTEGER, -1]]
  ]) {
    const value = protocol.parseAdaptiveContentRange(text);
    assert.deepEqual([value.kind, value.start, value.end, value.total], expected);
  }
  for (const text of ['bytes 0-9/10\n', 'bytes +0-9/10', 'bytes 0-9/10.0', 'bytes 0-9/1e1',
    'bytes 0-9/-1', 'bytes 0-9/9007199254740992', 'bytes 0-9007199254740991/*', 'bytes 2-1/3',
    'bytes 0-9/9', 'bytes 0-9/*x', 'bytes 0-9 /10', 'bytes\n0-9/10', 'bytes */*', '', null, 123]) {
    assert.equal(protocol.parseAdaptiveContentRange(text).kind, 'invalid', String(text));
  }
});

test('critical headers reject unsupported container and value types without coercion', () => {
  for (const key of ['contentRange', 'contentLength', 'contentEncoding', 'transferEncoding']) {
    for (const invalid of [undefined, null, 0, '10', {}, [0], [null], [['10']], [undefined]]) {
      const value = head(); value[key] = invalid;
      assert.equal(protocol.inspectAdaptiveHead(window(), value).code, 'InvalidHead', key);
    }
  }
  for (const invalid of [null, undefined, [], 0, 'head']) assert.equal(protocol.inspectAdaptiveHead(window(), invalid).code, 'InvalidHead');
});

test('controls are rejected in every critical field and errors do not echo input', () => {
  for (const key of ['contentRange', 'contentLength', 'contentEncoding', 'transferEncoding']) {
    for (const control of ['\0', '\r', '\n', '\v', '\u007f', '\u0085', '\u009f']) {
      const value = head(); value[key] = ['secret=https://user:password@host/token' + control];
      const result = protocol.inspectAdaptiveHead(window(), value);
      assert.equal(result.kind, 'reject'); assert.doesNotMatch(JSON.stringify(result), /secret|password|token|https/);
    }
  }
});

test('header character and repetition budgets are checked before parsing or copying', () => {
  const value = head(200, '', ''); value.contentLength = ['0'.repeat(16384)];
  assert.equal(protocol.inspectAdaptiveHead(window(-1, 0), value).expectedBytes, 0);
  value.contentEncoding = ['identity'];
  assert.equal(protocol.inspectAdaptiveHead(window(-1, 0), value).code, 'InvalidHead');
  value.contentEncoding = []; value.contentLength = Array(8).fill('0');
  assert.equal(protocol.inspectAdaptiveHead(window(-1, 0), value).kind, 'accept');
  value.contentLength.push('0'); assert.equal(protocol.inspectAdaptiveHead(window(-1, 0), value).code, 'InvalidHead');
});

test('Content-Length absent, exact zero, duplicates and safe precision have distinct meaning', () => {
  const value = head(200, '', ''); const request = window(-1, 0);
  assert.equal(protocol.inspectAdaptiveHead(request, value).expectedBytes, -1);
  value.contentLength = ['000', '0']; assert.equal(protocol.inspectAdaptiveHead(request, value).expectedBytes, 0);
  value.contentLength = [String(Number.MAX_SAFE_INTEGER)];
  assert.equal(protocol.inspectAdaptiveHead(request, value).expectedBytes, Number.MAX_SAFE_INTEGER);
  for (const values of [['10', '11'], ['9007199254740992'], ['1e1'], ['+10'], ['-0'], ['10.0'], ['0x10'], [''], ['10, 10']]) {
    value.contentLength = values; assert.equal(protocol.inspectAdaptiveHead(request, value).kind, 'reject');
  }
});

test('transport failures and every HTTP error status are retryable (source parity) and no error response body is retained', () => {
  const transients = new Set([0, 408, 429, 500, 502, 503, 504]);
  for (let status = 400; status <= 599; status++) transients.add(status);
  for (let status = 0; status <= 599; status++) {
    if (status === 206) continue;
    const result = protocol.inspectAdaptiveTransfer(window(), head(status), body(10));
    assert.equal(result.kind, transients.has(status) ? 'retryable' : 'reject', String(status));
    assert.equal(result.allowNewPrefix, false, String(status));
  }
});

test('known windows require exact 206 bounds and current-response rather than entity Content-Length', () => {
  const request = window(10, 90, 4, 100);
  assert.equal(protocol.inspectAdaptiveHead(request, head(206, 'bytes 94-99/100', '6')).kind, 'accept');
  for (const range of ['bytes 93-99/100', 'bytes 94-100/101', 'bytes 94-98/100', 'bytes 94-99/101', 'bytes 94-99/*']) {
    assert.equal(protocol.inspectAdaptiveHead(request, head(206, range, '')).kind, 'reject', range);
  }
  assert.equal(protocol.inspectAdaptiveHead(request, head(206, 'bytes 94-99/100', '100')).code, 'LengthMismatch');
  assert.equal(protocol.inspectAdaptiveHead(window(10, 0), head(200, '', '10')).code, 'RangeNotHonored');
});

test('content encoding and transfer framing never silently change byte representation', () => {
  const request = window(-1, 0);
  for (const encoding of [[], ['identity'], [' IDENTITY\t']]) {
    const value = head(200, '', ''); value.contentEncoding = encoding; value.transferEncoding = ['CHUNKED'];
    assert.equal(protocol.inspectAdaptiveHead(request, value).kind, 'accept');
  }
  for (const encoding of [['gzip'], ['deflate'], ['br'], [''], ['identity', 'identity'], ['identity,gzip']]) {
    const value = head(200, '', ''); value.contentEncoding = encoding;
    assert.equal(protocol.inspectAdaptiveHead(request, value).kind, 'reject');
  }
  for (const transfer of [['gzip'], ['identity'], ['chunked', 'chunked'], ['gzip, chunked']]) {
    const value = head(200, '', ''); value.transferEncoding = transfer;
    assert.equal(protocol.inspectAdaptiveHead(request, value).kind, 'reject');
  }
  const conflict = head(200, '', '0'); conflict.transferEncoding = ['chunked'];
  assert.equal(protocol.inspectAdaptiveHead(request, conflict).code, 'InvalidFraming');
});

test('overlong whole 200 body cannot be made valid by capping the writes', () => {
  const result = protocol.inspectAdaptiveTransfer(window(-1, 0, 5), head(200, '', '10'), body(11, 10));
  assert.equal(result.code, 'BodyTooLong'); assert.equal(result.allowNewPrefix, false);
  assert.equal(result.prefixLimit, 5); assert.equal(result.resetPrefix, true);
});

test('every incomplete known transfer keeps a strict prefix and never treats write length as EOS', () => {
  const request = window(10, 90, 4); const response = head(206, 'bytes 94-99/100', '6');
  for (let received = 0; received <= 6; received++) {
    for (let written = 0; written <= received; written++) {
      for (const ended of [false, true]) {
        const result = protocol.inspectAdaptiveTransfer(request, response, body(received, written, ended));
        const complete = ended && received === 6 && written === 6;
        assert.equal(result.kind, complete ? 'completeBytes' : 'partialBytes');
        assert.equal(result.prefixLimit, complete ? 10 : Math.min(9, 4 + written));
      }
    }
  }
});

test('whole 200 reset may retain a shorter new prefix but never adds copied old bytes', () => {
  for (const written of [0, 1, 3]) {
    const result = protocol.inspectAdaptiveTransfer(window(-1, 0, 12, 20), head(200, '', '10'), body(written));
    assert.equal(result.kind, 'partialBytes'); assert.equal(result.prefixLimit, written); assert.equal(result.writeBase, 0);
  }
  const empty = protocol.inspectAdaptiveTransfer(window(-1, 0, 12), head(200, '', '0'), body(0));
  assert.equal(empty.kind, 'completeBytes'); assert.equal(empty.prefixLimit, 0);
});

test('open-ended 206 without end-of-resource proof stays partial even at exact response EOS', () => {
  for (const range of ['bytes 4-9/*', 'bytes 4-9/20']) {
    const result = protocol.inspectAdaptiveTransfer(window(-1, 0, 4), head(206, range, '6'), body(6));
    assert.equal(result.kind, 'partialBytes'); assert.equal(result.code, 'WholeExtentUnproven'); assert.equal(result.prefixLimit, 10);
  }
  assert.equal(protocol.inspectAdaptiveTransfer(window(-1, 0, 4), head(206, 'bytes 4-9/10', '6'), body(6)).kind, 'completeBytes');
});

test('late transport, disk and cancellation observations cannot manufacture completion', () => {
  const response = head(); response.transportErrorCode = 1;
  assert.equal(protocol.inspectAdaptiveHead(window(), response).kind, 'accept');
  assert.equal(protocol.inspectAdaptiveTransfer(window(), response, body(10)).kind, 'retryable');
  const stopped = body(10); stopped.stopRequested = true;
  assert.equal(protocol.inspectAdaptiveTransfer(window(), response, stopped).code, 'Stopped');
  stopped.diskErrorCode = 1;
  assert.equal(protocol.inspectAdaptiveTransfer(window(), response, stopped).code, 'DiskFailure');
  const empty = body(0, 0, false); empty.stopRequested = true;
  assert.equal(protocol.inspectAdaptiveTransfer(window(), head(0, '', ''), empty).code, 'Stopped');
});

test('invalid body scalar types and aggregate overflow fail before retaining new data', () => {
  const mutations = [value => { value.receivedBytes = '10'; }, value => { value.receivedBytes = Infinity; },
    value => { value.writtenBytes = -1; }, value => { value.writtenBytes = 11; }, value => { value.writtenBytes = 0.5; },
    value => { value.streamEnded = 1; }, value => { value.writesPending = 'false'; }, value => { value.stopRequested = null; },
    value => { value.diskErrorCode = 'disk private path'; }, value => { delete value.streamEnded; }];
  for (const mutate of mutations) {
    const value = body(10); mutate(value); const result = protocol.inspectAdaptiveTransfer(window(), head(), value);
    assert.equal(result.code, 'InvalidBody'); assert.equal(result.allowNewPrefix, false);
  }
  const result = protocol.inspectAdaptiveTransfer(window(-1, 0, Number.MAX_SAFE_INTEGER),
    head(206, 'bytes 9007199254740991-9007199254740991/*', '1'), body(1));
  assert.equal(result.code, 'InvalidBody'); assert.equal(result.allowNewPrefix, false);
});

test('checks do not mutate inputs or reuse mutable results and final inspection revalidates headers', () => {
  const request = window(); const response = head(); const facts = body(10);
  const before = plain([request, response, facts]); const result = protocol.inspectAdaptiveTransfer(request, response, facts);
  assert.deepEqual(plain([request, response, facts]), before);
  result.prefixLimit = 0; result.code = 'tampered';
  assert.equal(protocol.inspectAdaptiveTransfer(request, response, facts).prefixLimit, 10);
  const accepted = protocol.inspectAdaptiveHead(request, response); accepted.kind = 'accept';
  response.contentRange = ['bytes 0-9/100'];
  assert.equal(protocol.inspectAdaptiveTransfer(request, response, facts).kind, 'reject');
});

test('static Hypium protocol bodies execute against the same production ETS', t => {
  const cases = [];
  const shim = {
    describe: (_name, register) => register(),
    it: (name, _level, run) => cases.push({ name, run }),
    expect: value => ({ assertEqual: expected => assert.equal(value, expected),
      assertTrue: () => assert.equal(value, true), assertFalse: () => assert.equal(value, false) })
  };
  const file = path.resolve(__dirname, '../../entry/src/test/AdaptiveProtocol.test.ets');
  const statics = [...fs.readFileSync(file, 'utf8').matchAll(/^\s*it\('([^']+)'/gm)].map(match => match[1]);
  loadProduction(file, { '@ohos/hypium': shim, '../main/ets/core/adaptive/AdaptivePlan': plan,
    '../main/ets/core/adaptive/AdaptiveProtocol': protocol }, { Error }).default();
  assert.deepEqual(cases.map(item => item.name), statics); assert.equal(new Set(statics).size, statics.length);
  assert.equal(statics.length, 34);
  for (const item of cases) {
    try { assert.equal(item.run(), undefined); }
    catch (error) { throw new Error('Hypium ' + item.name + ': ' + error.message, { cause: error }); }
  }
  t.diagnostic('Executed ' + cases.length + ' static Hypium bodies; this is not SDK/Hypium-device execution.');
});
