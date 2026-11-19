'use strict';
// Execute the production P6-U6 session with actual E4/E3/C/E2/F modules.
// Only SDK boundaries and observation hooks use Node; each case owns real files and sockets.
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const nativeFs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { fixture: assemblyFixture, hold, within, ioError } = require('./adaptive-assembler-harness.cjs');
const { NodeRcpAdapter } = require('./adaptive-stream-sdk.cjs');
const { loadModules } = require('./adaptive-stream-harness.cjs');
const { loadProduction } = require('./production-loader.cjs');
const { startAdaptiveFixture } = require('../../docs/probe/P6-U5-adaptive-host.cjs');
const ETS = path.resolve(__dirname, '../../entry/src/main/ets');
const plain = value => JSON.parse(JSON.stringify(value));
const sha256 = bytes => crypto.createHash('sha256').update(bytes).digest('hex');

async function fixture(t) {
  const cleanup = []; const f = await assemblyFixture({ after: action => cleanup.push(action) });
  const sdk = new NodeRcpAdapter(); const sessions = []; const servers = []; const controllers = [];
  const readers = []; const leases = new Map(); const hooks = {}; const hashCalls = []; const gates = [];
  let currentToken = 'controller_test_token';
  const io = f.adapter;
  io.api.mkdir = (target, recursive) => io.call('mkdir', { path: target }, () => fs.mkdir(io.real(target), { recursive }));
  io.api.rename = (source, target) => io.call('rename', { path: source, target }, () => fs.rename(io.real(source), io.real(target)));
  const modules = loadModules(io, sdk);
  class HostEncoder { encodeInto(text) { return new TextEncoder().encode(text); } }
  const util = { generateRandomUUID: () => crypto.randomUUID(), TextEncoder: HostEncoder,
    TextDecoder: { create: (encoding, options) => {
      const decoder = new TextDecoder(encoding, options);
      return { decodeToString: (buffer, settings) => decoder.decode(buffer, settings) };
    } } };
  const globals = { Error, Promise, ArrayBuffer, Uint8Array, setTimeout, clearTimeout };
  const coreKit = { fileIo: io.api, hash: { hash: async (target, algorithm) => {
    const observed = { path: target, algorithm, finished: false }; hashCalls.push(observed);
    if (hooks.beforeHash) await hooks.beforeHash(observed);
    const value = crypto.createHash(algorithm).update(await fs.readFile(io.real(target))).digest('hex');
    if (hooks.afterHash) await hooks.afterHash(observed, value);
    observed.finished = true; return value;
  } } };
  const store = loadProduction(path.join(ETS, 'core/db/AdaptiveStateStore.ets'), {
    '@kit.CoreFileKit': coreKit, '@kit.ArkTS': { util }, '@kit.BasicServicesKit': {},
    '../adaptive/AdaptivePlan': modules.plan, '../adaptive/AdaptiveStateCodec': modules.codec
  }, globals);
  const request = loadProduction(path.join(ETS, 'model/DownloadRunRequest.ets'),
    { './DownloadRequestContext': modules.context }, globals);
  const controller = loadProduction(path.join(ETS, 'core/adaptive/AdaptiveRunController.ets'), {
    '@kit.ArkTS': { util }, '../../model/DownloadRunRequest': request,
    '../../model/DownloadRequestContext': modules.context,
    './AdaptivePlan': modules.plan, './AdaptiveStateCodec': modules.codec,
    './AdaptiveScheduler': modules.scheduler, './AdaptiveAttemptExecutor': modules.executor,
    './AdaptiveDownloadThrottle': modules.throttle, '../db/AdaptiveStateStore': store
  }, globals);
  function observeLease(value) {
    if (!value.ready || leases.has(value.ready.lease)) return;
    const lease = value.ready.lease; const record = { lease, ready: value.ready, attaches: [], releases: [], quarantines: [] };
    leases.set(lease, record);
    const attach = lease.attachReader.bind(lease); const release = lease.release.bind(lease);
    const quarantine = lease.quarantine.bind(lease);
    lease.attachReader = callback => {
      const accepted = attach(callback); record.attaches.push(accepted);
      if (hooks.afterAttach) hooks.afterAttach(record, accepted);
      return accepted;
    };
    lease.release = () => { const result = release(); record.releases.push(result); return result; };
    lease.quarantine = code => { record.quarantines.push(code); return quarantine(code); };
  }
  class ObservedController extends controller.AdaptiveRunController {
    constructor(input, policy, clock) { super(input, policy, clock); controllers.push({ instance: this, input, results: [] }); }
    run() {
      return super.run().then(async value => {
        observeLease(value); controllers.find(item => item.instance === this).results.push(value);
        if (hooks.afterRun) await hooks.afterRun(value, this);
        return value;
      });
    }
  }
  const media = { MediaProcessorNapi: f.processor.constructor };
  const assembly = loadProduction(path.join(ETS, 'core/adaptive/AdaptiveAssembler.ets'), {
    '@kit.CoreFileKit': coreKit, '@kit.ArkTS': { util }, '@kit.BasicServicesKit': {},
    './AdaptivePlan': modules.plan, './AdaptiveStateCodec': modules.codec, './AdaptiveAttemptFile': modules.file,
    '../media/MediaProcessorNapi': media
  }, globals);
  class ObservedAssembler extends assembly.AdaptiveAssembler {
    constructor(...args) { super(...args); readers.push({ instance: this, runs: 0, result: null }); }
    run(...args) {
      const item = readers.find(value => value.instance === this); item.runs++;
      return super.run(...args).then(result => { item.result = result; return result; });
    }
  }
  class KeyValue { constructor(key, value) { this.key = key; this.value = value; } }
  const kit = { KeyValue, ProbeKit: { getInstance: () => ({ isCurrent: token => token === currentToken }) } };
  const source = await fs.readFile(path.join(ETS, 'probe/units/ProbeAdaptiveController.ets'), 'utf8');
  const prefix = source.split('@Component')[0]; assert.ok(prefix.includes('export class AdaptiveControllerProbeSession'));
  const loadedPath = path.join(f.realBase, 'ProbeAdaptiveController.session.ets'); await fs.writeFile(loadedPath, prefix);
  const probe = loadProduction(loadedPath, {
    '@kit.CoreFileKit': coreKit, '@kit.ArkTS': { util }, '@kit.BasicServicesKit': {},
    '../core/ProbeKit': kit, '../core/ProbePage': {},
    '../../core/adaptive/HlsModel': modules.models, '../../core/adaptive/HlsParser': modules.parser,
    '../../core/adaptive/HlsUrlResolver': modules.resolver, '../../core/adaptive/AdaptivePlan': modules.plan,
    '../../core/adaptive/AdaptiveRunController': { ...controller, AdaptiveRunController: ObservedController },
    '../../core/adaptive/AdaptiveDownloadThrottle': modules.throttle,
    '../../core/adaptive/AdaptiveAssembler': { ...assembly, AdaptiveAssembler: ObservedAssembler },
    '../../core/adaptive/AdaptiveAttemptFile': modules.file
  }, globals);
  const create = origin => {
    const session = new probe.AdaptiveControllerProbeSession(f.base, origin || 'http://127.0.0.1:18766', currentToken, '123456');
    sessions.push(session); return session;
  };
  const emitter = loadProduction(path.join(ETS, 'probe/core/ProbeKit.ets'), {
    '@kit.PerformanceAnalysisKit': { hilog: { info: () => {}, error: (_d, _t, _f, line) => { throw new Error(line); } } },
    '@kit.CoreFileKit': { fileIo: { OpenMode: { READ_WRITE: 2, CREATE: 64, TRUNC: 512 },
      openSync: target => {
        assert.equal(path.resolve(target), path.join(f.realBase, 'probe-latest.txt'));
        return { fd: nativeFs.openSync(target, 'w+') };
      }, writeSync: (fd, content) => nativeFs.writeSync(fd, content), closeSync: file => nativeFs.closeSync(file.fd) } },
    '@kit.BasicServicesKit': {}, '@kit.ArkTS': { util }
  }, { Error });
  const emit = (session, step) => {
    const kit = emitter.ProbeKit.getInstance(); kit.begin('P6-U6', f.realBase);
    const facts = session.markerFacts ? session.markerFacts() : session.facts;
    const line = kit.emit(step, facts); kit.end(true);
    const full = '[XDM_PROBE][P6-U6][' + step + '] ' + facts.map(item => item.key + '=' + item.value).join(' ');
    assert.ok(Buffer.byteLength(full) < 1500, 'complete marker must fit: ' + Buffer.byteLength(full));
    assert.equal(line, full, 'production ProbeKit must not truncate facts');
    t.diagnostic(line); return line;
  };
  t.after(async () => {
    for (const key of Object.keys(hooks)) delete hooks[key];
    io.before = null; io.after = null;
    for (const gate of gates) gate.resolve();
    for (const session of sessions) session.cancel();
    // Gates registered with the base fixture are released by the test's own finally blocks.
    for (const session of sessions) await within(session.releaseResources(), 'controller probe real drain', 10000);
    media.MediaProcessorNapi.getInstance().dispose(); sdk.cleanup();
    for (const server of servers) await server.close();
    for (const action of cleanup) await action();
  });
  return { ...f, io, sdk, modules, store, controller, assembly, create, hooks, controllers, readers, leases, hashCalls, emit,
    gate: () => { const gate = f.gate(); gates.push(gate); return gate; },
    hold: (predicate, timing) => hold(f, predicate, timing),
    invalidate: () => { currentToken = 'replacement_' + crypto.randomUUID(); },
    server: async () => { const value = await startAdaptiveFixture({ port: 0 }); servers.push(value); return value; },
    facts: session => Object.fromEntries(session.facts.map(item => [item.key, item.value])),
    async complete(session, step) {
      await session.execute(step);
      const safe = await session.releaseResources(); assert.equal(safe, true);
      session.noteCleanup(safe); await session.writeEvidence(step);
      assert.equal(await session.releaseResources(), true); session.noteCleanup(true);
      const facts = Object.fromEntries(session.facts.map(item => [item.key, item.value]));
      const detail = JSON.parse(await fs.readFile(io.real(facts.detailFile), 'utf8'));
      assert.equal(detail.unit, 'P6-U6'); assert.equal(detail.step, step);
      assert.equal(Object.fromEntries(detail.facts.map(item => [item.key, item.value])).cleanupComplete, 'true');
      assert.equal(io.handles.size, 0); assert.equal(io.pending, 0);
      assert.equal(sdk.records.filter(item => !item.closed).length, 0);
      assert.ok([...leases.values()].every(item => !item.lease.isCurrent()));
      emit(session, step);
      return facts;
    },
    async busy(ready) {
      const input = new controller.AdaptiveRunInput(); input.tempBase = ready.tempBase;
      input.downloadId = ready.downloadId; input.runToken = crypto.randomUUID(); input.request.url = ready.state.plan.primaryUrl;
      const next = new controller.AdaptiveRunController(input, () => new modules.throttle.AdaptiveThrottlePolicy());
      const value = await next.run(); await next.drain(); return value;
    }
  };
}

module.exports = { fixture, within, ioError, plain, sha256 };
