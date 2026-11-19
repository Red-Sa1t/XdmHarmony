'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const crypto = require('node:crypto');
const { performance } = require('node:perf_hooks');
const { fixture, within, sleep, digest, sourceManifest } = require('./adaptive-stream-harness.cjs');

test('H3 actual 512KiB ignored-Range 200 remains network-pending past 60s at 4KiB/s', { timeout: 180000 }, async t => {
  const sourceHashes = await sourceManifest();
  const f = await fixture(t), body = Buffer.alloc(512 * 1024, 73);
  const server = await f.server((_req, res) => { res.writeHead(200, { 'Content-Length': body.length }); res.end(body); });
  const policy = new f.throttle.AdaptiveThrottlePolicy(); policy.globalEnabled = true; policy.globalKiBps = 4;
  const c = await f.claim(server.url + '/long-no-range.ts', { policy, timeoutSeconds: 1 });
  const startedAt = performance.now(), work = c.task.run();
  await sleep(60100);
  const observation = { elapsedMs: performance.now() - startedAt, fetchPending: !f.sdk.records[0].fetchSettled,
    deliveredBytes: f.sdk.records[0].deliveredBytes, totalBytes: body.length, queueBytes: f.sdk.queues[0].size,
    writtenBytes: c.gate.snapshot().writtenBytes, requests: server.requests.length };
  t.diagnostic('H3_REAL_NETWORK_60S ' + JSON.stringify(observation));
  if (process.env.E3_H3_REPORT) await fs.writeFile(process.env.E3_H3_REPORT,
    JSON.stringify({ phase: 'networkPendingAt60s', sourceHashes, observation }, null, 2) + '\n');
  assert.equal(observation.fetchPending, true, 'network itself must still be pending beyond 60 seconds');
  assert.ok(observation.deliveredBytes < body.length); assert.equal(observation.requests, 1);
  const result = await within(work, 100000), elapsedMs = performance.now() - startedAt;
  assert.equal(result.settlement.outcome, 'complete', JSON.stringify(result));
  assert.equal(result.stream.eof, true); assert.equal(result.file.sealed, true); assert.equal(result.file.closed, true);
  assert.equal(f.io.handles.size, 0); assert.equal(server.requests.length, 1);
  const fileSha256 = await digest(c.filePath), expectedSha256 = crypto.createHash('sha256').update(body).digest('hex');
  assert.equal(fileSha256, expectedSha256); assert.deepEqual(await sourceManifest(), sourceHashes);
  assert.ok(elapsedMs > 110000); assert.ok(f.sdk.queues[0].peak <= 65536);
  const report = { scope: 'actual production ETS + Node HTTP/FS; not target RCP evidence', sourceHashes, sourcesUnchanged: true,
    environment: { node: process.version, platform: process.platform, arch: process.arch }, fileSha256, expectedSha256,
    observationAt60s: observation, elapsedMs, writtenBytes: result.writtenBytes, receivedBytes: result.receivedBytes,
    fetchSucceeded: result.stream.fetchSucceeded, allSessionsApiClosed: result.stream.allSessionsApiClosed,
    sdkEndObserved: result.stream.sdkEndObserved, receivedExact: result.receivedExact, eof: result.stream.eof,
    networkEndElapsedMs: f.sdk.records[0].networkEndedAt - startedAt, sessionCount: result.stream.sessionCount,
    configuredTransferMs: f.sdk.records[0].configuration.requestConfiguration.transfer.timeout.transferMs,
    queuePeak: f.sdk.queues[0].peak, requests: server.requests.length, outcome: result.settlement.outcome };
  t.diagnostic('H3_REAL_NETWORK_COMPLETE ' + JSON.stringify(report));
  if (process.env.E3_H3_REPORT) await fs.writeFile(process.env.E3_H3_REPORT, JSON.stringify(report, null, 2) + '\n');
});
