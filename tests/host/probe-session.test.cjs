'use strict';
// Execute actual probe orchestration and native probe methods; only ArkUI render
// syntax and SDK boundaries are replaced. This does not establish OHOS behavior.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const test = require('node:test');
const ts = require(process.env.XDM_TYPESCRIPT_PATH ||
  'D:/Tools/DevEco Studio/tools/ohpm/node_modules/typescript/lib/typescript.js');
const base = path.resolve(__dirname, '../../entry/src/main/ets/probe');
const flush = () => new Promise(resolve => setImmediate(resolve));
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

function fixture() {
  let now = Date.UTC(2026, 9, 8, 6, 1, 20), timerId = 0, fd = 0;
  class Clock extends Date {
    constructor(...args) { super(...(args.length ? args : [now])); }
    static now() { return now; }
  }
  const intervals = new Map(), timeouts = new Map(), diagnostics = [], writes = [];
  const clipboard = [], jobs = [];
  const hilog = { info() {}, error(...args) { diagnostics.push(args); } };
  const fileIo = {
    OpenMode: { READ_WRITE: 1, CREATE: 2, TRUNC: 4, WRITE_ONLY: 8 },
    openSync(file) { writes.push({ file, data: [] }); return { fd: ++fd }; },
    closeSync() {}, accessSync() { return false; },
    writeSync(handle, data) {
      const bytes = typeof data === 'string' ? Buffer.from(data) : Buffer.from(data);
      writes[handle - 1].data.push(bytes);
      return bytes.length;
    }
  };
  const util = { generateRandomUUID: () => crypto.randomUUID(),
    TextEncoder: class { encodeInto(value) { return new TextEncoder().encode(value); } } };
  const globals = { Date: Clock, ArrayBuffer, Uint8Array, DataView, $r: value => value,
    setInterval(fn) { const id = ++timerId; intervals.set(id, fn); return id; },
    clearInterval(id) { intervals.delete(id); },
    setTimeout(fn) { const id = ++timerId; timeouts.set(id, fn); return id; },
    clearTimeout(id) { timeouts.delete(id); } };
  function load(relative, imports, ui = false) {
    const file = path.join(base, relative);
    let source = fs.readFileSync(file, 'utf8');
    if (ui) {
      source = source.replace(/@Component\s*/g, '').replace(/@State\s+/g, '')
        .replace(/\bexport struct\b/, 'export class');
      const build = source.indexOf('\n  build()');
      assert.ok(build >= 0, 'expected ArkUI build boundary');
      source = source.slice(0, build) + '\n}\n';
    }
    const output = ts.transpileModule(source, { fileName: file.replace(/\.ets$/, '.ts'),
      compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
    assert.deepEqual((output.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error), []);
    const module = { exports: {} };
    const context = vm.createContext({ module, exports: module.exports, ...globals,
      require(name) { assert.ok(Object.hasOwn(imports, name), name); return imports[name]; } });
    new vm.Script(output.outputText, { filename: file }).runInContext(context);
    return module.exports;
  }
  const core = load('core/ProbeKit.ets', { '@kit.PerformanceAnalysisKit': { hilog },
    '@kit.CoreFileKit': { fileIo }, '@kit.ArkTS': { util } });
  const kit = core.ProbeKit.getInstance();
  const pageModule = load('core/ProbePage.ets', { './ProbeKit': core,
    '@kit.PerformanceAnalysisKit': { hilog }, '@kit.BasicServicesKit': { pasteboard: {
      MIMETYPE_TEXT_PLAIN: 'text/plain', createData: (type, value) => ({ type, value }),
      getSystemPasteboard: () => ({ setData(data) {
        const pending = deferred(); clipboard.push({ data, ...pending }); return pending.promise;
      } })
    } } }, true);
  class Processor {
    dispose() { this.disposed = true; }
    capabilities() { return {}; }
    toMp3(id) { const pending = deferred(); jobs.push({ id, owner: this, ...pending }); return pending.promise; }
  }
  const nativeModule = load('units/ProbeNativeMedia.ets', { '../core/ProbeKit': core,
    '@kit.CoreFileKit': { fileIo, hash: { hash: async () => 'host-fixture' } },
    '@kit.ArkTS': { util }, '../../core/media/MediaProcessorNapi': { MediaProcessorNapi: Processor } }, true);
  function page(runner, steps = ['S1']) {
    const result = new pageModule.ProbePage();
    result.unitId = 'P0-U4'; result.autoStart = false;
    result.steps = steps.map(stepNo => ({ stepNo, title: '', autoRun: true }));
    result.runStep = runner || (async step => kit.emit(step, [new core.KeyValue('observed', '1')]));
    result.getUIContext = () => ({ getHostContext: () => ({ filesDir: '' }) });
    result.aboutToAppear();
    return result;
  }
  function native() {
    const result = new nativeModule.ProbeNativeMedia();
    result.aboutToAppear(); result.directory = '/host-probe';
    result.inputs = [{ path: '/host-probe/video.mp4' }, { path: '/host-probe/audio.m4a' },
      { path: '/host-probe/tone.wav' }];
    return result;
  }
  return { kit, core, page, native, clipboard, jobs, intervals, timeouts, writes, diagnostics,
    advance(ms) { now += ms; } };
}

test('same-second and clock rollback identities stay unique while BEGIN remains HHmmss', () => {
  const f = fixture();
  f.kit.begin('P0-U4', '');
  const first = f.kit.getSessionToken(), display = f.kit.getRunId();
  f.kit.begin('P0-U4', '');
  const second = f.kit.getSessionToken();
  assert.equal(f.kit.getRunId(), display);
  assert.match(display, /^\d{6}$/);
  assert.notEqual(first, second);
  assert.match(second, /^[A-Za-z0-9-]+$/);
  assert.equal(f.kit.isCurrent(first), false);
  assert.equal(f.kit.isCurrent(display), false);
  f.kit.cancelSession(first);
  assert.equal(f.kit.isCurrent(second), true);
  f.advance(-1000); f.kit.begin('P0-U4', '');
  assert.notEqual(f.kit.getSessionToken(), second);
  assert.match(f.kit.getLines()[0], /^\[XDM_PROBE\]\[P0-U4\]\[BEGIN\] runId=\d{6} filesDir=$/);
});

test('normal sequential session emits one END after all observed steps', async () => {
  const f = fixture(), p = f.page(undefined, ['S1', 'S2']);
  await p.startSession();
  assert.deepEqual(Array.from(p.statuses), ['done', 'done']);
  assert.equal(p.hasResult, true); assert.equal(p.sessionRunning, false);
  assert.equal(f.kit.isCurrent(f.kit.getSessionToken()), false);
  assert.equal(f.kit.getLines().filter(line => line.includes('[END]')).length, 1);
  assert.match(f.kit.getLines().at(-1), /ok=true steps=2 /);
});

test('exit invalidates a pending step without a synthetic END or later UI mutation', async () => {
  const f = fixture(), pending = deferred(), p = f.page(() => pending.promise);
  const work = p.startSession(), token = f.kit.getSessionToken();
  p.aboutToDisappear(); const statuses = Array.from(p.statuses);
  assert.equal(f.kit.isCurrent(token), false);
  pending.resolve(); await work;
  assert.equal(p.hasResult, false);
  assert.deepEqual(Array.from(p.statuses), statuses);
  assert.equal(f.kit.getLines().some(line => line.includes('[END]')), false);
  await p.startSession(); await p.runSingle('S1');
  assert.equal(f.kit.getSessionToken(), token, 'invisible page cannot start a session');
});

test('same-second old page completion cannot end a new page session', async () => {
  const f = fixture(), oldStep = deferred(), nextStep = deferred();
  const first = f.page(() => oldStep.promise), oldWork = first.startSession();
  const oldDisplay = f.kit.getRunId(); first.aboutToDisappear();
  const next = f.page(async step => { await nextStep.promise; f.kit.emit(step, []); });
  const work = next.startSession(), nextToken = f.kit.getSessionToken();
  assert.equal(f.kit.getRunId(), oldDisplay);
  oldStep.resolve(); await oldWork;
  assert.equal(f.kit.isCurrent(nextToken), true);
  assert.equal(next.sessionRunning, true);
  assert.equal(f.kit.getLines().some(line => line.includes('[END]')), false);
  nextStep.resolve(); await work;
  assert.match(f.kit.getLines().at(-1), /ok=true steps=1 /);
});

for (const fail of [false, true]) {
  test('reused component ignores old ' + (fail ? 'rejection' : 'fulfillment') + ' during its new run', async () => {
    const f = fixture(), oldStep = deferred(), nextStep = deferred();
    const p = f.page(() => oldStep.promise), oldWork = p.startSession();
    p.aboutToDisappear(); p.aboutToAppear();
    p.runStep = async step => { await nextStep.promise; f.kit.emit(step, []); };
    const nextWork = p.startSession();
    if (fail) oldStep.reject(new Error('old step failed')); else oldStep.resolve();
    await oldWork;
    assert.equal(p.sessionRunning, true); assert.equal(p.hasResult, false);
    assert.deepEqual(Array.from(p.statuses), ['running']);
    assert.equal(f.kit.getLines().length, 1);
    nextStep.resolve(); await nextWork;
    assert.match(f.kit.getLines().at(-1), /ok=true steps=1 /);
  });
}

test('single-step continuation also respects page generation and token', async () => {
  const f = fixture(), oldStep = deferred(), nextStep = deferred();
  const p = f.page(() => oldStep.promise), oldWork = p.runSingle('S1');
  p.aboutToDisappear(); p.aboutToAppear(); p.runStep = () => nextStep.promise;
  const nextWork = p.runSingle('S1');
  oldStep.reject(new Error('stale single step')); await oldWork;
  assert.equal(p.sessionRunning, true); assert.equal(f.kit.getLines().length, 1);
  nextStep.resolve(); await nextWork;
  assert.equal(p.sessionRunning, false); assert.equal(p.hasResult, true);
});

test('late disappearance of an old page cannot cancel a newer active page', async () => {
  const f = fixture(), a = deferred(), b = deferred();
  const first = f.page(() => a.promise), oldWork = first.startSession();
  const next = f.page(() => b.promise), nextWork = next.startSession();
  const token = f.kit.getSessionToken(); first.aboutToDisappear();
  assert.equal(f.kit.isCurrent(token), true);
  a.resolve(); b.resolve(); await Promise.all([oldWork, nextWork]);
});

test('copy succeeds after END, and its delayed result cannot mark a rerun copied', async () => {
  const f = fixture(), p = f.page(); await p.startSession();
  p.copyLog(); assert.equal(f.clipboard.length, 1);
  assert.match(f.clipboard[0].data.value, /\[END\]/);
  f.clipboard[0].resolve(); await flush(); assert.equal(p.copied, true);
  p.copyLog(); const nextStep = deferred(); p.runStep = () => nextStep.promise;
  const nextWork = p.startSession();
  f.clipboard[1].resolve(); await flush(); assert.equal(p.copied, false);
  nextStep.resolve(); await nextWork;
});

test('delayed clipboard failure from an earlier page is ignored', async () => {
  const f = fixture(), p = f.page(); await p.startSession(); p.copyLog();
  p.aboutToDisappear(); p.aboutToAppear(); await p.startSession();
  f.clipboard[0].reject(new Error('old clipboard error')); await flush();
  assert.equal(p.copied, false); assert.equal(f.diagnostics.length, 0);
});

test('old native S6 completion cannot stop the heartbeat of a reused component', async () => {
  const f = fixture(), p = f.native(); f.kit.begin('P0-U4', '');
  const oldWork = p.runS6(f.kit.getSessionToken()); assert.equal(f.jobs.length, 1);
  p.aboutToDisappear(); p.aboutToAppear(); f.kit.begin('P0-U4', '');
  const token = f.kit.getSessionToken(), work = p.runS6(token), heartbeat = p.pulseTimer;
  assert.equal(f.jobs.length, 2); assert.equal(f.intervals.has(heartbeat), true);
  f.jobs[0].resolve({ status: 'cancelled' }); await oldWork;
  assert.equal(p.pulseRun, token); assert.equal(f.intervals.has(heartbeat), true);
  p.aboutToDisappear(); f.jobs[1].resolve({ status: 'cancelled' }); await work;
  assert.equal(f.intervals.size, 0);
});

test('stale native pause callback cannot erase the next pause ownership', async () => {
  const f = fixture(), p = f.native(); f.kit.begin('P0-U4', '');
  const oldWork = p.pause(5, f.kit.getSessionToken()), oldCallback = f.timeouts.get(p.pauseTimer);
  p.aboutToDisappear(); await oldWork; p.aboutToAppear(); f.kit.begin('P0-U4', '');
  const token = f.kit.getSessionToken(), work = p.pause(5, token), timer = p.pauseTimer;
  oldCallback();
  assert.equal(p.pauseTimer, timer); assert.equal(p.pauseRun, token);
  f.timeouts.get(timer)(); await work;
  assert.equal(p.pauseTimer, -1); p.aboutToDisappear();
});

test('native evidence keeps display runId and unique file identity separately', () => {
  const f = fixture(), p = f.native(); f.kit.begin('P0-U4', '');
  const firstName = p.fresh('evidence');
  const token = f.kit.getSessionToken(); p.record(token, 'S1', [], []);
  const detail = JSON.parse(Buffer.concat(f.writes[0].data).toString('utf8'));
  assert.equal(detail.runId, f.kit.getRunId()); assert.equal(detail.sessionToken, token);
  f.kit.begin('P0-U4', ''); const next = f.native();
  assert.notEqual(next.fresh('evidence'), firstName);
});
