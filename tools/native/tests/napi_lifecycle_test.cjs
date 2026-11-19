'use strict';
// Execute the real production NAPI module against Node's NAPI host, including
// environment termination. This is not a substitute for OHOS/Ark runtime tests.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { Worker, isMainThread, parentPort, workerData } = require('node:worker_threads');

async function bounded(promise, milliseconds, label) {
  let timeout;
  try {
    return await Promise.race([promise, new Promise((resolve, reject) => {
      timeout = setTimeout(() => reject(new Error(label + ' timed out')), milliseconds);
    })]);
  } finally { clearTimeout(timeout); }
}

if (!isMainThread) {
  const native = require(workerData.addon);
  native.toMp3(workerData.id, workerData.input, workerData.output).then(result => parentPort.postMessage({ result }));
  setTimeout(() => parentPort.postMessage({ submitted: true, progress: native.progress(workerData.id) }), 5);
} else {
  async function main() {
    if (process.argv.length !== 5) throw new Error('Usage: node napi_lifecycle_test.cjs ADDON FIXTURES FRESH_OUTPUT');
    const addon = path.resolve(process.argv[2]);
    const fixtures = path.resolve(process.argv[3]);
    const output = path.resolve(process.argv[4]);
    fs.mkdirSync(output, { recursive: true });
    const native = require(addon);
    const short = path.join(fixtures, 'tone-44100-mono.wav');
    const long = path.join(fixtures, 'tone-cancel.wav');
    const digest = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
    const beforeShort = digest(short), beforeLong = digest(long);
    const checks = [];
    function record(name, observed) {
      checks.push({ case: name, ...observed });
      fs.writeFileSync(path.join(output, 'results.json'), JSON.stringify({
        scope: 'Actual production NAPI executed on Node/Linux host; OHOS runtime remains separate', checks
      }, null, 2) + '\n');
      console.log(JSON.stringify({ case: name, checked: true }));
    }
    const capabilities = native.capabilities();
    assert.equal(capabilities.apiVersion, 1);
    assert.equal(capabilities.ffmpegVersion, '6.0');
    assert.equal(capabilities.lameVersion, '3.100');
    assert.equal(capabilities.maxActiveJobs, 1);
    assert.equal(capabilities.remuxMp4 && capabilities.remuxMatroska && capabilities.encodeMp3, true);
    record('capabilities', capabilities);

    for (const call of [() => native.toMp3(), () => native.toMp3('id', null, '/tmp/output'),
      () => native.toMp3('id', short, '/tmp/output', 'extra'), () => native.capabilities('extra'),
      () => native.toMp3('id', 'x'.repeat(4096), '/tmp/output')]) {
      assert.throws(call, error => error.code === 'XDM_MEDIA_ARGUMENT');
    }
    const invalid = await native.toMp3('invalid-path', 'relative.wav', path.join(output, 'invalid.part'));
    assert.equal(invalid.errorCode, 'INVALID_ARGUMENT');
    assert.equal(invalid.outputPath, '');
    assert.equal(fs.existsSync(path.join(output, 'invalid.part')), false);
    record('arguments', { rejectedShapes: 5, invalid });

    const cancelPath = path.join(output, 'cancel.part');
    const pending = native.toMp3('cancel-main', long, cancelPath);
    assert.equal(native.progress('cancel-main').found, true);
    const busy = await native.toMp3('busy', short, path.join(output, 'busy.part'));
    assert.equal(busy.status, 'busy');
    assert.equal(busy.errorCode, 'BUSY');
    assert.equal(native.cancel('cancel-main'), true);
    assert.equal(native.cancel('cancel-main'), false);
    const cancelled = await bounded(pending, 10000, 'active cancellation');
    assert.equal(cancelled.status, 'cancelled');
    assert.equal(cancelled.outputPath, '');
    assert.equal(fs.existsSync(cancelPath), false);
    assert.equal(fs.existsSync(path.join(output, 'busy.part')), false);
    record('busy-and-cancel', { busy, cancelled });

    const repeated = [];
    for (let i = 0; i < 20; i++) {
      const id = 'repeat-' + i, target = path.join(output, id + '.mp3');
      const result = await bounded(native.toMp3(id, short, target), 10000, id);
      assert.equal(result.status, 'success');
      assert.equal(result.outputPath, target);
      assert.equal(result.outputBytes, fs.statSync(target).size);
      assert.equal(native.progress(id).found, false);
      assert.equal(native.cancel(id), false);
      repeated.push({ result, sha256: digest(target) });
    }
    record('twenty-sequential-and-late-cancel', { repeated });

    const terminations = [];
    for (let i = 0; i < 20; i++) {
      const id = 'worker-' + i, target = path.join(output, id + '.part');
      const worker = new Worker(__filename, { workerData: { addon, id, input: long, output: target } });
      const submitted = await bounded(new Promise((resolve, reject) => {
        worker.once('error', reject);
        worker.once('message', resolve);
      }), 10000, 'worker submission');
      assert.equal(submitted.submitted, true, 'Long job completed before teardown could be requested');
      assert.equal(submitted.progress.found, true);
      assert.equal(native.progress(id).found, false, 'Foreign environment must not expose progress');
      assert.equal(native.cancel(id), false, 'Foreign environment must not cancel the owner');
      const started = Date.now();
      await bounded(worker.terminate(), 10000, 'worker teardown');
      assert.equal(fs.existsSync(target), false, 'Terminated environment left an owned partial');
      const nextPath = path.join(output, 'after-worker-' + i + '.mp3');
      const followup = await bounded(native.toMp3('after-worker-' + i, short, nextPath), 10000, 'registry reuse');
      assert.equal(followup.status, 'success');
      terminations.push({ observedPhase: submitted.progress.phase,
        processedTimeMs: submitted.progress.processedTimeMs, terminateAndReuseMs: Date.now() - started,
        ownedPartialRemoved: true, followupStatus: followup.status });
    }
    record('twenty-environment-teardowns-and-owner-isolation', { terminations });
    assert.equal(digest(short), beforeShort);
    assert.equal(digest(long), beforeLong);
    record('input-preservation', { shortSha256: beforeShort, longSha256: beforeLong });
    console.log(JSON.stringify({ checked: checks.length, output }));
  }
  main().catch(error => { console.error(error); process.exitCode = 1; });
}
