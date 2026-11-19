'use strict';
const assert = require('node:assert/strict');
const http = require('node:http');
const crypto = require('node:crypto');
const { test } = require('node:test');
const { startAdaptiveFixture } = require('../../docs/probe/P6-U5-adaptive-host.cjs');
function get(origin, route, headers = {}, method = 'GET') {
  return new Promise((resolve, reject) => {
    const request = http.request(origin + route, { headers, method }, response => {
      const chunks = []; response.on('data', chunk => chunks.push(chunk)); response.on('error', reject);
      response.on('end', () => resolve({ status: response.statusCode, headers: response.headers, body: Buffer.concat(chunks) }));
    });
    request.on('error', reject); request.end();
  });
}
const sha = data => crypto.createHash('sha256').update(data).digest('hex');

test('P6-U5 actual HTTP fixed whole body has the declared length and independent fingerprint', async t => {
  const fixture = await startAdaptiveFixture({ port: 0 }); t.after(() => fixture.close());
  const response = await get(fixture.origin, '/whole');
  assert.equal(response.status, 200); assert.equal(response.headers['content-length'], '524288');
  assert.equal(response.body.length, 524288);
  assert.equal(sha(response.body), '61d1d9c5745bdaa4fab39240651bc242a5186b15393fd475082fcf6e84f400ab');
  assert.equal(response.headers['content-encoding'], undefined);
});

test('P6-U5 two actual 206 requests identify distinct 64 KiB prefixes with accurate boundaries', async t => {
  const fixture = await startAdaptiveFixture({ port: 0 }); t.after(() => fixture.close());
  const first = await get(fixture.origin, '/bytes', { Range: 'bytes=0-65535', Cookie: 'must-not-appear-in-event' });
  const second = await get(fixture.origin, '/bytes', { Range: 'bytes=65536-131071' });
  assert.equal(first.status, 206); assert.equal(second.status, 206);
  assert.equal(first.headers['content-range'], 'bytes 0-65535/524288');
  assert.equal(second.headers['content-range'], 'bytes 65536-131071/524288');
  assert.equal(sha(first.body), '4b640d85ab3ba30fd02c9fc9db4a8928f416322ad27022ea58a65aaee68a4df2');
  assert.equal(sha(second.body), 'fe89f108b4028dc360cbe69ce0ccbe4d9bc8af0123f731304b77327fd495a1f6');
  assert.equal(JSON.stringify(fixture.events).includes('must-not-appear'), false);
});

test('P6-U5 malformed, multiple and unsatisfiable ranges are explicit 416 without a body', async t => {
  const fixture = await startAdaptiveFixture({ port: 0 }); t.after(() => fixture.close());
  for (const range of ['bytes=-10', 'bytes=3-2', 'bytes=524288-', 'bytes=0-1,3-4', 'bytes=9007199254740992-', 'wrong']) {
    const response = await get(fixture.origin, '/bytes', { Range: range });
    assert.equal(response.status, 416); assert.equal(response.headers['content-range'], 'bytes */524288');
    assert.equal(response.body.length, 0);
  }
});

test('P6-U5 whole route deliberately responds 200 when a Range header is sent', async t => {
  const fixture = await startAdaptiveFixture({ port: 0 }); t.after(() => fixture.close());
  const response = await get(fixture.origin, '/whole', { Range: 'bytes=3-4' });
  assert.equal(response.status, 200); assert.equal(response.body.length, 524288);
  assert.equal(response.headers['content-range'], undefined);
});

test('P6-U5 endpoint/method boundary does not expose arbitrary paths or a control endpoint', async t => {
  const fixture = await startAdaptiveFixture({ port: 0 }); t.after(() => fixture.close());
  assert.equal((await get(fixture.origin, '/../../config.toml')).status, 404);
  assert.equal((await get(fixture.origin, '/shutdown')).status, 404);
  assert.equal((await get(fixture.origin, '/bytes', {}, 'POST')).status, 405);
  assert.deepEqual(JSON.parse((await get(fixture.origin, '/health')).body), { fixture: 'P6-U5', bytes: 524288 });
});

test('P6-U5 creator close is idempotent and waits for the listening socket to end', async () => {
  const fixture = await startAdaptiveFixture({ port: 0 });
  await Promise.all([fixture.close(), fixture.close()]);
  await assert.rejects(get(fixture.origin, '/health'), error => error.code === 'ECONNREFUSED');
});
