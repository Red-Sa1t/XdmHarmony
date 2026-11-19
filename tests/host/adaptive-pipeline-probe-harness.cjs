'use strict';
// The production probe owner is executed unchanged up to its ArkUI component declaration.
// Real Node sockets/FS replace SDK boundaries; the native adapter in these control-flow tests
// is separate from the actual C++/decode gate in adaptive-assembler-native.test.cjs.
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
const { fixture: assemblyFixture, hold, within, ioError } = require('./adaptive-assembler-harness.cjs');
const { NodeRcpAdapter } = require('./adaptive-stream-sdk.cjs');
const { loadModules } = require('./adaptive-stream-harness.cjs');
const { loadProduction } = require('./production-loader.cjs');
const { startAdaptiveFixture } = require('../../docs/probe/P6-U5-adaptive-host.cjs');
const ETS = path.resolve(__dirname, '../../entry/src/main/ets');

async function fixture(t) {
  const cleanup = []; const f = await assemblyFixture({ after: action => cleanup.push(action) });
  const sdk = new NodeRcpAdapter(); const sessions = []; const servers = [];
  let currentToken = 'pipeline_test_token';
  const io = f.adapter;
  io.api.mkdir = (target, recursive) => io.call('mkdir', { path: target }, () => fs.mkdir(io.real(target), { recursive }));
  io.api.rename = (source, target) => io.call('rename', { path: source, target }, () => fs.rename(io.real(source), io.real(target)));
  const modules = loadModules(io, sdk);
  class HostEncoder { encodeInto(text) { return new TextEncoder().encode(text); } }
  const util = {
    generateRandomUUID: () => crypto.randomUUID(), TextEncoder: HostEncoder,
    TextDecoder: { create: (encoding, options) => {
      const decoder = new TextDecoder(encoding, options);
      return { decodeToString: (buffer, settings) => decoder.decode(buffer, settings) };
    } }
  };
  const globals = { Error, Promise, ArrayBuffer, Uint8Array, setTimeout, clearTimeout };
  const coreKit = { fileIo: io.api, hash: { hash: async (target, algorithm) =>
    crypto.createHash(algorithm).update(await fs.readFile(io.real(target))).digest('hex') } };
  const store = loadProduction(path.join(ETS, 'core/db/AdaptiveStateStore.ets'), {
    '@kit.CoreFileKit': coreKit, '@kit.ArkTS': { util }, '@kit.BasicServicesKit': {},
    '../adaptive/AdaptivePlan': modules.plan, '../adaptive/AdaptiveStateCodec': modules.codec
  }, globals);
  const media = { MediaProcessorNapi: f.processor.constructor };
  const assembly = loadProduction(path.join(ETS, 'core/adaptive/AdaptiveAssembler.ets'), {
    '@kit.CoreFileKit': coreKit, '@kit.ArkTS': { util }, '@kit.BasicServicesKit': {},
    './AdaptivePlan': modules.plan, './AdaptiveStateCodec': modules.codec, './AdaptiveAttemptFile': modules.file,
    '../media/MediaProcessorNapi': media
  }, globals);
  class KeyValue { constructor(key, value) { this.key = key; this.value = value; } }
  const kit = { KeyValue, ProbeKit: { getInstance: () => ({ isCurrent: token => token === currentToken }) } };
  const source = await fs.readFile(path.join(ETS, 'probe/units/ProbeAdaptivePipeline.ets'), 'utf8');
  const prefix = source.split('@Component')[0]; assert.ok(prefix.includes('export class AdaptivePipelineSession'));
  const loadedPath = path.join(f.realBase, 'ProbeAdaptivePipeline.session.ets'); await fs.writeFile(loadedPath, prefix);
  const probe = loadProduction(loadedPath, {
    '@kit.CoreFileKit': coreKit, '@kit.ArkTS': { util }, '@kit.BasicServicesKit': {},
    '../core/ProbeKit': kit, '../core/ProbePage': {},
    '../../core/adaptive/HlsModel': modules.models, '../../core/adaptive/HlsParser': modules.parser,
    '../../core/adaptive/HlsUrlResolver': modules.resolver, '../../core/adaptive/AdaptivePlan': modules.plan,
    '../../core/adaptive/AdaptiveStateCodec': modules.codec, '../../core/db/AdaptiveStateStore': store,
    '../../core/adaptive/AdaptiveAttemptFile': modules.file, '../../core/adaptive/AdaptiveScheduler': modules.scheduler,
    '../../core/adaptive/AdaptiveProtocol': modules.protocol, '../../core/adaptive/AdaptiveAttemptExecutor': modules.executor,
    '../../core/adaptive/AdaptiveDownloadThrottle': modules.throttle, '../../core/adaptive/AdaptiveAssembler': assembly,
    '../../model/DownloadRequestContext': modules.context
  }, globals);
  const raw = async name => Uint8Array.from(await fs.readFile(path.resolve(__dirname, '../../entry/src/main/resources/rawfile', name)));
  const create = origin => {
    const session = new probe.AdaptivePipelineSession(f.base, origin || 'http://127.0.0.1:18766', currentToken, '123456');
    sessions.push(session); return session;
  };
  t.after(async () => {
    for (const session of sessions) session.cancel();
    for (const session of sessions) await within(session.releaseResources(), 'probe owner drain', 10000);
    media.MediaProcessorNapi.getInstance().dispose();
    sdk.cleanup(); for (const server of servers) await server.close();
    for (const action of cleanup) await action();
  });
  return { ...f, io, sdk, modules, store, create, raw, hold: (predicate, timing) => hold(f, predicate, timing),
    invalidate: () => { currentToken = 'replacement_' + crypto.randomUUID(); },
    server: async () => { const value = await startAdaptiveFixture({ port: 0 }); servers.push(value); return value; },
    facts: session => Object.fromEntries(session.facts.map(item => [item.key, item.value])),
    async complete(session, step) {
      await session.execute(step, raw);
      const safe = await session.releaseResources(); assert.equal(safe, true);
      session.noteCleanup(safe); await session.writeEvidence(step);
      assert.equal(await session.releaseResources(), true);
      const facts = Object.fromEntries(session.facts.map(item => [item.key, item.value]));
      assert.equal(facts.cleanupComplete, 'true');
      const detail = JSON.parse(await fs.readFile(io.real(facts.detailFile), 'utf8'));
      assert.equal(detail.unit, 'P6-U5'); assert.equal(detail.step, step);
      assert.equal(Object.fromEntries(detail.facts.map(item => [item.key, item.value])).cleanupComplete, 'true');
      assert.equal(io.handles.size, 0, 'all owned host handles close before detail publication');
      return facts;
    }
  };
}

module.exports = { fixture, within, ioError };
