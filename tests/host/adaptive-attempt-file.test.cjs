'use strict';
// Actual production ETS with asynchronous SDK boundaries over isolated real files.
// Node cannot prove HarmonyOS close-rejection, NOFOLLOW, or physical power-loss semantics.
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const nativeFs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { performance } = require('node:perf_hooks');
const { test } = require('node:test');
const { loadProduction } = require('./production-loader.cjs');

const SOURCE = path.resolve(__dirname, '../../entry/src/main/ets/core/adaptive/AdaptiveAttemptFile.ets');
const ID = '01234567-89ab-cdef-0123-456789abcdef';
const CANDIDATE = 'a0_candidate.part';
const PREFIX = 'old_prefix.part';
const LIMIT = 65536;
const plain = value => JSON.parse(JSON.stringify(value));
const bytes = value => Uint8Array.from(typeof value === 'string' ? Buffer.from(value) : value).buffer;

function ioError(code = 13900005, message = 'Injected filesystem failure') {
  const error = new Error(message); error.code = code; return error;
}

function sdkError(error) {
  if (typeof error?.code === 'number') return error;
  const codes = { ENOENT: 13900002, EIO: 13900005, EBADF: 13900008, EACCES: 13900012,
    EPERM: 13900012, EEXIST: 13900015, ENOTDIR: 13900018, EISDIR: 13900019, ENOSPC: 13900025 };
  return ioError(codes[error?.code] || 13900042);
}

function deferred() {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
}

async function within(promise, label) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_resolve, reject) => {
      timer = setTimeout(() => reject(new Error('Timed out: ' + label)), 7000);
    })]);
  } finally { clearTimeout(timer); }
}

class FileAdapter {
  constructor() {
    this.history = [];
    this.handles = new Map();
    this.paths = new Map();
    this.before = null;
    this.after = null;
    this.rawErrors = false;
    this.shortRead = Infinity;
    this.shortWrite = Infinity;
    this.pending = 0;
    this.peakPending = 0;
    this.api = {
      OpenMode: { READ_ONLY: 0, READ_WRITE: 2, CREATE: 64, NOFOLLOW: 262144 },
      lstat: target => this.call('lstat', { path: target }, async () => this.metadata(await fs.lstat(target))),
      stat: fd => this.call('stat', { fd, path: this.paths.get(fd) }, async () => {
        assert.equal(typeof fd, 'number', 'metadata must inspect the owned fd');
        return this.metadata(await this.handle(fd).stat());
      }),
      open: (target, mode) => this.call('open', { path: target, mode }, async () => {
        let flags = (mode & 2) ? nativeFs.constants.O_RDWR : nativeFs.constants.O_RDONLY;
        if (mode & 64) flags |= nativeFs.constants.O_CREAT;
        if (mode & 262144) flags |= nativeFs.constants.O_NOFOLLOW || 0;
        const handle = await fs.open(target, flags);
        this.handles.set(handle.fd, handle); this.paths.set(handle.fd, path.resolve(target));
        return { fd: handle.fd };
      }),
      read: (fd, buffer, options) => this.call('read', {
        fd, path: this.paths.get(fd), requested: options?.length ?? buffer.byteLength,
        bufferLength: buffer.byteLength
      }, async () => {
        assert.equal(options?.offset, undefined, 'SDK read offset is relative: omit it');
        const length = Math.min(options?.length ?? buffer.byteLength, this.shortRead);
        return (await this.handle(fd).read(Buffer.from(buffer), 0, length, null)).bytesRead;
      }),
      write: (fd, buffer, options) => this.call('write', {
        fd, path: this.paths.get(fd), requested: buffer.byteLength
      }, async () => {
        assert.equal(options?.offset, undefined, 'SDK write offset is relative: omit it');
        return (await this.handle(fd).write(Buffer.from(buffer), 0,
          Math.min(buffer.byteLength, this.shortWrite), null)).bytesWritten;
      }),
      truncate: (fd, length) => this.call('truncate', { fd, path: this.paths.get(fd), length }, async () => {
        assert.equal(typeof fd, 'number', 'truncate must use the owned candidate fd');
        await this.handle(fd).truncate(length);
      }),
      fsync: fd => this.call('fsync', { fd, path: this.paths.get(fd) }, () => this.handle(fd).sync()),
      close: file => {
        const fd = typeof file === 'number' ? file : file.fd;
        return this.call('close', { fd, path: this.paths.get(fd) }, async () => {
          await this.handle(fd).close(); this.handles.delete(fd);
        });
      },
      unlink: target => this.call('unlink', { path: target }, () => fs.unlink(target))
    };
  }

  metadata(value) {
    return { size: value.size, isFile: () => value.isFile(), isDirectory: () => value.isDirectory() };
  }

  handle(fd) {
    const handle = this.handles.get(fd); if (!handle) throw ioError(13900008); return handle;
  }

  async call(op, fields, operation) {
    const event = { op, ...fields, path: fields.path ? path.resolve(fields.path) : '',
      index: this.history.length, nativeStarted: false, nativeCompleted: false, returned: undefined };
    this.history.push(event); this.pending++;
    this.peakPending = Math.max(this.peakPending, this.pending);
    try {
      if (this.before) await this.before(event);
      event.nativeStarted = true;
      let value = await operation(); event.nativeCompleted = true;
      if (this.after) {
        const replacement = await this.after(event, value);
        if (replacement !== undefined) value = replacement;
      }
      event.returned = typeof value === 'number' ? value : undefined;
      return value;
    } catch (error) { throw this.rawErrors ? error : sdkError(error); }
    finally { this.pending--; }
  }
}

async function fixture(t) {
  const temporaryRoot = await fs.realpath(os.tmpdir());
  const base = await fs.mkdtemp(path.join(temporaryRoot, 'xdm-adaptive-attempt-'));
  const absoluteBase = path.resolve(base);
  const dir = path.join(base, ID); await fs.mkdir(dir);
  const adapter = new FileAdapter();
  const attempts = []; const gates = []; const allocations = [];
  const allowedUncertain = new Set();
  class TrackedArrayBuffer extends ArrayBuffer {
    constructor(size) { super(size); allocations.push(size); }
    // The public API receives native caller buffers as well as instrumented captured buffers.
    static [Symbol.hasInstance](value) { return value instanceof ArrayBuffer; }
  }
  const production = loadProduction(SOURCE, {
    '@kit.CoreFileKit': { fileIo: adapter.api }, '@kit.BasicServicesKit': {}
  }, { Error, ArrayBuffer: TrackedArrayBuffer }, ['ATTEMPT_LEASES']);
  const f = {
    base, dir, adapter, allocations, production, attempts,
    file: name => path.join(dir, name),
    candidate: path.join(dir, CANDIDATE), prefix: path.join(dir, PREFIX),
    gate: () => { const gate = deferred(); gates.push(gate); return gate; },
    attempt: (name = CANDIDATE, max = Number.MAX_SAFE_INTEGER, directory = base, id = ID) => {
      const attempt = new production.AdaptiveAttemptFile(directory, id, name, max);
      attempts.push(attempt); return attempt;
    },
    allowUncertain: target => allowedUncertain.add(path.resolve(target)),
    putPrefix: async value => fs.writeFile(path.join(dir, PREFIX), value),
    leaseCount: () => production.ATTEMPT_LEASES.size
  };
  t.after(async () => {
    adapter.before = null; adapter.after = null;
    for (const gate of gates) gate.resolve();
    for (const attempt of attempts) attempt.dispose();
    await within(Promise.all(attempts.map(attempt => attempt.drain())), 'fixture drain');
    const unexpected = [];
    // A simulated before-close rejection intentionally leaves a native handle alive. Only the
    // harness closes explicitly expected uncertain handles, after product facts were asserted.
    for (const [fd, handle] of adapter.handles) {
      if (!allowedUncertain.has(adapter.paths.get(fd))) unexpected.push(adapter.paths.get(fd));
      try { await handle.close(); } catch {}
    }
    adapter.handles.clear();
    assert.equal(path.resolve(base), absoluteBase);
    assert.equal(path.dirname(absoluteBase), path.resolve(temporaryRoot));
    assert.ok(path.basename(absoluteBase).startsWith('xdm-adaptive-attempt-'));
    assert.equal(await fs.realpath(absoluteBase), absoluteBase);
    await fs.rm(absoluteBase, { recursive: true, force: true });
    assert.equal(adapter.pending, 0, 'drain waits actual admitted IO');
    assert.deepEqual(unexpected, [], 'unexpected production-owned handle leak');
    assert.equal(f.leaseCount(), 0, 'terminal attempts do not retain lease history');
  });
  return f;
}

function match(op, name = '') {
  return event => event.op === op && (!name || path.basename(event.path) === name);
}

function once(adapter, predicate, effect, timing = 'before') {
  let hits = 0;
  adapter[timing] = async (event, value) => {
    if (hits === 0 && predicate(event)) { hits++; return effect(event, value); }
    return value;
  };
  return () => assert.equal(hits, 1, 'injection must reach the selected actual SDK boundary');
}

function hold(f, predicate, timing = 'before') {
  const entered = f.gate(); const release = f.gate();
  const reached = once(f.adapter, predicate, async (_event, value) => {
    entered.resolve(); await release.promise; return value;
  }, timing);
  return { entered: within(entered.promise, 'selected SDK boundary'), release: release.resolve, reached };
}

async function absent(target) { await assert.rejects(fs.lstat(target), { code: 'ENOENT' }); }

function closed(result, status) {
  assert.equal(result.status, status); assert.equal(result.sealed, false);
  assert.equal(result.closed, true); assert.equal(result.prefixClosed, true);
  assert.equal(result.candidateClosed, true); assert.equal(result.resourceUncertain, false);
}

test('constructors reject unsafe owner/path/basename/max values without IO or buffer allocation', async t => {
  const f = await fixture(t);
  const constructors = [
    ['relative', ID, CANDIDATE, 16], ['', ID, CANDIDATE, 16],
    ['file://' + f.base, ID, CANDIDATE, 16], [f.base + '\0bad', ID, CANDIDATE, 16],
    ['/' + 'a'.repeat(4097), ID, CANDIDATE, 16], ['/../../escape', ID, CANDIDATE, 16],
    [f.base, '../bad', CANDIDATE, 16], [f.base, '', CANDIDATE, 16],
    ...['../outside.part', 'a/b.part', 'a\\b.part', 'a.part?', 'a.part\0', '.part',
      'adaptive-state.1.json', 'a'.repeat(121) + '.part'].map(name => [f.base, ID, name, 16]),
    ...[-1, 0.5, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1].map(max => [f.base, ID, CANDIDATE, max])
  ];
  for (const [directory, id, name, max] of constructors) {
    const attempt = f.attempt(name, max, directory, id);
    assert.equal((await attempt.drain()).status, 'invalid');
    assert.equal((await attempt.open('', 0)).status, 'invalid');
    assert.equal((await attempt.append(bytes('x'))).status, 'invalid');
    assert.equal((await attempt.seal(0)).status, 'invalid');
  }
  assert.equal(f.adapter.history.length, 0); assert.equal(f.allocations.length, 0);
});

test('invalid prefix parameters do not consume an otherwise valid instance', async t => {
  const f = await fixture(t); const attempt = f.attempt(CANDIDATE, 16);
  for (const [name, size] of [[PREFIX, 0], ['', 1], ['../x.part', 1], [CANDIDATE, 1],
    [PREFIX, 17], ...[-1, 0.5, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1].map(size => [PREFIX, size])]) {
    assert.equal((await attempt.open(name, size)).status, 'invalid');
  }
  if (process.platform === 'win32') assert.equal((await attempt.open(CANDIDATE.slice(0, -5).toUpperCase() + '.part', 1)).status, 'invalid');
  assert.equal(f.adapter.history.length, 0); assert.equal(f.leaseCount(), 0);
  assert.equal((await attempt.open('', 0)).status, 'opened');
});

test('missing task directory is rejected without creating it', async t => {
  const f = await fixture(t); await fs.rmdir(f.dir);
  closed(await f.attempt().open('', 0), 'invalid');
  await absent(f.dir); assert.deepEqual(f.adapter.history.map(event => event.op), ['lstat']);
});

test('task path must be an ordinary directory', async t => {
  const f = await fixture(t); await fs.rmdir(f.dir); await fs.writeFile(f.dir, 'ordinary file');
  closed(await f.attempt().open('', 0), 'invalid');
  assert.equal(await fs.readFile(f.dir, 'utf8'), 'ordinary file');
});

test('real linked task directory is rejected without touching its target', async t => {
  const f = await fixture(t); const target = path.join(f.base, 'target'); await fs.mkdir(target);
  await fs.rmdir(f.dir); await fs.symlink(target, f.dir, process.platform === 'win32' ? 'junction' : 'dir');
  assert.equal((await fs.lstat(f.dir)).isSymbolicLink(), true);
  closed(await f.attempt().open('', 0), 'invalid');
  assert.deepEqual(await fs.readdir(target), []);
});

for (const kind of ['empty', 'nonempty', 'directory', 'directory-link']) {
  test('existing ' + kind + ' candidate is a collision with no mutation or ownership', async t => {
    const f = await fixture(t);
    if (kind === 'directory') await fs.mkdir(f.candidate);
    else if (kind === 'directory-link') {
      const target = path.join(f.base, 'foreign'); await fs.mkdir(target); await fs.writeFile(path.join(target, 'marker'), 'keep');
      await fs.symlink(target, f.candidate, process.platform === 'win32' ? 'junction' : 'dir');
    } else await fs.writeFile(f.candidate, kind === 'empty' ? '' : 'do not truncate');
    const original = await fs.lstat(f.candidate);
    const attempt = f.attempt(); const result = await attempt.open('', 0);
    closed(result, 'collision'); assert.equal(result.cleanupComplete, true);
    attempt.dispose(); await attempt.drain();
    assert.equal((await fs.lstat(f.candidate)).size, original.size);
    if (kind === 'nonempty') assert.equal(await fs.readFile(f.candidate, 'utf8'), 'do not truncate');
    assert.equal(f.adapter.history.filter(event => ['open', 'write', 'truncate', 'unlink'].includes(event.op)).length, 0);
    assert.equal(f.leaseCount(), 0);
  });
}

test('zero-byte seal performs real fsync/close and survives disposal', async t => {
  const f = await fixture(t); const attempt = f.attempt(CANDIDATE, 0);
  const opened = await attempt.open('', 0);
  assert.equal(opened.status, 'opened'); assert.equal(opened.closed, false); assert.equal(opened.confirmedBytes, 0);
  assert.equal((await attempt.drain()).closed, false, 'idle writable drain does not invent a close');
  assert.equal((await attempt.append(new ArrayBuffer(0))).status, 'appended');
  assert.equal(f.adapter.history.filter(match('write')).length, 0);
  const sealed = await attempt.seal(0);
  assert.equal(sealed.status, 'sealed'); assert.equal(sealed.sealed, true); assert.equal(sealed.closed, true);
  assert.equal(sealed.cleanupComplete, true); assert.equal((await fs.stat(f.candidate)).size, 0);
  assert.deepEqual(f.adapter.history.slice(-3).map(event => event.op), ['stat', 'fsync', 'close']);
  attempt.dispose(); assert.deepEqual(plain(await attempt.drain()), plain(sealed));
  assert.equal(f.adapter.history.filter(match('unlink')).length, 0);
});

test('S5 candidate append16 snapshots caller bytes, rejects busy calls, and seals16', async t => {
  const f = await fixture(t); const attempt = f.attempt(CANDIDATE, 16);
  assert.equal((await attempt.open('', 0)).status, 'opened');
  const source = bytes('0123456789ABCDEF'); const gate = hold(f, match('write', CANDIDATE));
  const pending = attempt.append(source); new Uint8Array(source).fill(0x78);
  await gate.entered;
  const allocations = f.allocations.length; const calls = f.adapter.history.length;
  let touched = false;
  const hostile = new ArrayBuffer(1);
  Object.defineProperty(hostile, 'byteLength', { get() { touched = true; throw new Error('must not inspect busy input'); } });
  assert.equal((await attempt.append(hostile)).status, 'busy');
  assert.equal((await attempt.open('', 0)).status, 'busy');
  assert.equal((await attempt.seal(16)).status, 'busy');
  assert.equal(touched, false); assert.equal(f.allocations.length, allocations); assert.equal(f.adapter.history.length, calls);
  gate.release(); const appended = await pending; gate.reached();
  assert.equal(appended.status, 'appended'); assert.equal(appended.confirmedBytes, 16); assert.equal(appended.closed, false);
  const result = await attempt.seal(16);
  assert.equal(result.status, 'sealed'); assert.equal(result.fileName, CANDIDATE);
  assert.equal(result.confirmedBytes, 16); assert.equal(result.closed, true); assert.equal(result.sealed, true);
  assert.equal(await fs.readFile(f.candidate, 'utf8'), '0123456789ABCDEF');
  assert.equal((await attempt.append(bytes('x'))).status, 'invalid');
  assert.equal((await attempt.open('', 0)).status, 'invalid');
});

test('S6 sealed16 with only committed8 copies exactly8, appends8, and seals16', async t => {
  const f = await fixture(t); const original = f.attempt(PREFIX, 16);
  assert.equal((await original.open('', 0)).status, 'opened');
  assert.equal((await original.append(bytes('01234567old-tail'))).confirmedBytes, 16);
  assert.equal((await original.seal(16)).status, 'sealed');
  const attempt = f.attempt(CANDIDATE, 16);
  const copied = await attempt.open(PREFIX, 8);
  assert.equal(copied.status, 'opened'); assert.equal(copied.confirmedBytes, 8); assert.equal(copied.prefixClosed, true);
  assert.equal(await fs.readFile(f.candidate, 'utf8'), '01234567');
  assert.equal((await attempt.append(bytes('89ABCDEF'))).confirmedBytes, 16);
  assert.equal((await attempt.seal(16)).status, 'sealed');
  assert.equal(await fs.readFile(f.candidate, 'utf8'), '0123456789ABCDEF');
  assert.equal(await fs.readFile(f.prefix, 'utf8'), '01234567old-tail');
  assert.deepEqual(f.adapter.history.filter(match('read', PREFIX)).map(event => event.requested), [8]);
  original.dispose(); attempt.dispose(); await Promise.all([original.drain(), attempt.drain()]);
  assert.equal(await fs.readFile(f.prefix, 'utf8'), '01234567old-tail');
});

test('large prefix copies in bounded blocks and ignores its extra physical tail', async t => {
  const f = await fixture(t); const count = 8 * 1024 * 1024 + 17;
  const source = Buffer.alloc(count + 61);
  for (let i = 0; i < source.length; i++) source[i] = (i * 17 + Math.floor(i / 251)) % 256;
  await f.putPrefix(source); const attempt = f.attempt(); const started = performance.now();
  const opened = await attempt.open(PREFIX, count);
  assert.equal(opened.confirmedBytes, count); assert.equal(opened.status, 'opened');
  assert.equal((await attempt.seal(count)).status, 'sealed');
  const elapsed = performance.now() - started;
  assert.deepEqual(await fs.readFile(f.candidate), source.subarray(0, count));
  assert.deepEqual(await fs.readFile(f.prefix), source);
  const reads = f.adapter.history.filter(match('read')); const writes = f.adapter.history.filter(match('write'));
  assert.equal(reads.length, 129); assert.equal(reads.at(-1).requested, 17);
  assert.equal(Math.max(...reads.map(event => event.requested)), LIMIT);
  assert.equal(Math.max(...writes.map(event => event.requested)), LIMIT);
  assert.equal(Math.max(...f.allocations), LIMIT); assert.equal(f.adapter.peakPending, 1);
  assert.equal(f.allocations.reduce((total, value) => total + value, 0), LIMIT + 17);
  t.diagnostic(JSON.stringify({ bytes: count, readCalls: reads.length, writeCalls: writes.length,
    maxAllocation: Math.max(...f.allocations), cumulativeAllocation: f.allocations.reduce((a, b) => a + b, 0),
    maxPendingIo: f.adapter.peakPending, elapsedMs: Number(elapsed.toFixed(2)) }));
});

test('short reads and writes cross buffer boundaries without stale bytes or relative offsets', async t => {
  const f = await fixture(t); const count = LIMIT * 2 + 29; const source = Buffer.alloc(count + 93);
  for (let i = 0; i < source.length; i++) source[i] = (i * 29 + 3) % 256;
  await f.putPrefix(source); f.adapter.shortRead = 7001; f.adapter.shortWrite = 997;
  const attempt = f.attempt(CANDIDATE, count + 5);
  assert.equal((await attempt.open(PREFIX, count)).confirmedBytes, count);
  assert.equal((await attempt.append(bytes([9, 8, 7]))).confirmedBytes, count + 3);
  assert.equal((await attempt.append(bytes([6, 5]))).confirmedBytes, count + 5);
  assert.equal((await attempt.seal(count + 5)).status, 'sealed');
  assert.deepEqual(await fs.readFile(f.candidate), Buffer.concat([source.subarray(0, count), Buffer.from([9, 8, 7, 6, 5])]));
  assert.deepEqual(await fs.readFile(f.prefix), source);
  assert.ok(f.adapter.history.filter(match('write')).length > f.adapter.history.filter(match('read')).length);
  assert.ok(f.allocations.every(value => value <= LIMIT)); assert.equal(f.adapter.peakPending, 1);
});

test('append validates actual buffers, block/max limits, detached input, and retain bounds without consuming state', async t => {
  const f = await fixture(t); const attempt = f.attempt(CANDIDATE, LIMIT);
  assert.equal((await attempt.append(bytes('x'))).status, 'invalid');
  assert.equal((await attempt.seal(0)).status, 'invalid');
  await attempt.open('', 0); const calls = f.adapter.history.length;
  const detached = new ArrayBuffer(2); structuredClone(detached, { transfer: [detached] });
  const throwing = new ArrayBuffer(1); Object.defineProperty(throwing, 'byteLength', { get() { throw new Error('bad length'); } });
  for (const data of [null, {}, Buffer.from('x'), new Uint8Array(1), new ArrayBuffer(LIMIT + 1), detached, throwing]) {
    assert.equal((await attempt.append(data)).status, 'invalid');
  }
  for (const retain of [-1, 0.5, 1, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1]) {
    assert.equal((await attempt.seal(retain)).status, 'invalid');
  }
  assert.equal(f.adapter.history.length, calls);
  assert.equal((await attempt.append(new ArrayBuffer(LIMIT))).confirmedBytes, LIMIT);
  const allocationCount = f.allocations.length; const after = f.adapter.history.length;
  assert.equal((await attempt.append(bytes('x'))).status, 'invalid');
  assert.equal(f.allocations.length, allocationCount); assert.equal(f.adapter.history.length, after);
  assert.equal((await attempt.seal(LIMIT)).status, 'sealed');
});

test('retain100 to99 truncates only the owned candidate and preserves the old40 prefix', async t => {
  const f = await fixture(t); await f.putPrefix(Buffer.alloc(40, 1)); const attempt = f.attempt(CANDIDATE, 100);
  assert.equal((await attempt.open(PREFIX, 40)).confirmedBytes, 40);
  assert.equal((await attempt.append(new Uint8Array(60).fill(2).buffer)).confirmedBytes, 100);
  const result = await attempt.seal(99);
  assert.equal(result.status, 'sealed'); assert.equal(result.confirmedBytes, 99);
  assert.deepEqual(await fs.readFile(f.candidate), Buffer.concat([Buffer.alloc(40, 1), Buffer.alloc(59, 2)]));
  assert.deepEqual(await fs.readFile(f.prefix), Buffer.alloc(40, 1));
  const truncates = f.adapter.history.filter(match('truncate'));
  assert.equal(truncates.length, 1); assert.equal(truncates[0].path, f.candidate); assert.equal(truncates[0].length, 99);
});

test('retain0 can seal IO facts after discarding all candidate bytes', async t => {
  const f = await fixture(t); const attempt = f.attempt(); await attempt.open('', 0); await attempt.append(bytes('discard'));
  const result = await attempt.seal(0); assert.equal(result.status, 'sealed'); assert.equal(result.confirmedBytes, 0);
  assert.equal((await fs.stat(f.candidate)).size, 0); assert.equal(result.closed, true);
});

for (const kind of ['missing', 'short', 'directory', 'directory-link']) {
  test('invalid ' + kind + ' prefix leaves prior data intact and cleans only its candidate', async t => {
    const f = await fixture(t);
    if (kind === 'short') await f.putPrefix('x');
    if (kind === 'directory') await fs.mkdir(f.prefix);
    if (kind === 'directory-link') {
      const target = path.join(f.base, 'prefix-target'); await fs.mkdir(target);
      await fs.symlink(target, f.prefix, process.platform === 'win32' ? 'junction' : 'dir');
    }
    const result = await f.attempt().open(PREFIX, 8); closed(result, 'invalid');
    assert.equal(result.cleanupComplete, true); await absent(f.candidate);
    if (kind !== 'missing') assert.ok(await fs.lstat(f.prefix));
    if (kind === 'short') assert.equal(await fs.readFile(f.prefix, 'utf8'), 'x');
    assert.equal(f.adapter.history.filter(match('open', PREFIX)).length, 0);
  });
}

for (const role of ['candidate', 'prefix']) {
  test('real file symlink for ' + role + ' is rejected before opening its target', async t => {
    const f = await fixture(t); const target = path.join(f.base, 'linked-content'); await fs.writeFile(target, 'preserve');
    const linked = role === 'candidate' ? f.candidate : f.prefix;
    try { await fs.symlink(target, linked, 'file'); }
    catch (error) {
      if (['EPERM', 'EACCES', 'ENOTSUP'].includes(error.code)) {
        t.skip('host lacks real file-symlink privilege; real directory-junction cases remain covered'); return;
      }
      throw error;
    }
    assert.equal((await fs.lstat(linked)).isSymbolicLink(), true);
    closed(await f.attempt().open(role === 'prefix' ? PREFIX : '', role === 'prefix' ? 8 : 0),
      role === 'prefix' ? 'invalid' : 'collision');
    assert.equal(await fs.readFile(target, 'utf8'), 'preserve');
    assert.equal(f.adapter.history.filter(match('open', path.basename(linked))).length, 0);
  });
}

for (const kind of ['stat-error', 'nonordinary', 'nonzero', 'unsafe-size', 'throwing-size', 'throwing-kind']) {
  test('candidate returned File is closed after ' + kind + ' without claiming delete authority', async t => {
    const f = await fixture(t); const attempt = f.attempt();
    const reached = once(f.adapter, match('stat', CANDIDATE), async (_event, value) => {
      if (kind === 'stat-error') throw ioError(771);
      if (kind === 'nonordinary') return { ...value, isFile: () => false };
      if (kind === 'nonzero') { await fs.writeFile(f.candidate, 'external'); return { ...value, size: 8 }; }
      if (kind === 'unsafe-size') return { ...value, size: Number.MAX_SAFE_INTEGER + 1 };
      if (kind === 'throwing-size') return { ...value, get size() { throw ioError(772); } };
      return { ...value, isFile() { throw ioError(773); } };
    }, 'after');
    const result = await attempt.open('', 0); reached();
    closed(result, kind === 'nonzero' ? 'collision' :
      ['nonordinary', 'unsafe-size'].includes(kind) ? 'invalid' : 'ioError');
    assert.equal(result.cleanupComplete, false); assert.equal(f.adapter.handles.size, 0);
    assert.equal(f.adapter.history.filter(match('close', CANDIDATE)).length, 1);
    assert.equal(f.adapter.history.filter(match('unlink')).length, 0);
    assert.ok(await fs.lstat(f.candidate));
    if (kind === 'nonzero') assert.equal(await fs.readFile(f.candidate, 'utf8'), 'external');
    const count = f.adapter.history.length; assert.equal((await attempt.open('', 0)).status, 'invalid');
    assert.equal(f.adapter.history.length, count);
  });
}

for (const kind of ['short', 'nonordinary', 'throwing-size']) {
  test('opened prefix fd ' + kind + ' closes both returned handles and preserves prefix', async t => {
    const f = await fixture(t); await f.putPrefix('0123456789');
    once(f.adapter, match('stat', PREFIX), async (_event, value) => {
      if (kind === 'short') return { ...value, size: 7 };
      if (kind === 'nonordinary') return { ...value, isFile: () => false };
      return { ...value, get size() { throw ioError(784); } };
    }, 'after');
    const result = await f.attempt().open(PREFIX, 8);
    closed(result, kind === 'throwing-size' ? 'ioError' : 'invalid');
    assert.equal(result.cleanupComplete, true); await absent(f.candidate);
    assert.equal(await fs.readFile(f.prefix, 'utf8'), '0123456789');
    assert.equal(f.adapter.history.filter(match('close', PREFIX)).length, 1);
    assert.equal(f.adapter.history.filter(match('close', CANDIDATE)).length, 1);
  });
}

test('open rejection before creating a path does not grant deletion authority', async t => {
  const f = await fixture(t); once(f.adapter, match('open', CANDIDATE), () => { throw ioError(801); });
  const result = await f.attempt().open('', 0); closed(result, 'ioError');
  assert.equal(result.errorCode, 801); assert.equal(result.cleanupComplete, false);
  assert.equal(f.adapter.history.filter(match('unlink')).length, 0); await absent(f.candidate);
});

test('open rejection after native creation but without returned File preserves the unclaimed path', async t => {
  const f = await fixture(t);
  once(f.adapter, match('open', CANDIDATE), async (_event, value) => {
    // This adapter rejection returns no File and internally releases its private handle.
    await f.adapter.handle(value.fd).close(); f.adapter.handles.delete(value.fd);
    await fs.writeFile(f.candidate, 'unclaimed'); throw ioError(802);
  }, 'after');
  const result = await f.attempt().open('', 0); closed(result, 'ioError');
  assert.equal(result.errorCode, 802); assert.equal(result.cleanupComplete, false);
  assert.equal(await fs.readFile(f.candidate, 'utf8'), 'unclaimed');
  assert.equal(f.adapter.history.filter(event => ['close', 'unlink'].includes(event.op)).length, 0);
});

for (const count of [0, -1, NaN, Infinity, 9]) {
  test('invalid prefix read count ' + String(count) + ' never produces a receipt', async t => {
    const f = await fixture(t); await f.putPrefix('01234567');
    once(f.adapter, match('read', PREFIX), () => count, 'after');
    const result = await f.attempt().open(PREFIX, 8); closed(result, count === 0 ? 'invalid' : 'ioError');
    assert.equal(result.confirmedBytes, 0); await absent(f.candidate);
    assert.equal(await fs.readFile(f.prefix, 'utf8'), '01234567');
  });
}

for (const count of [0, -1, NaN, Infinity, 9]) {
  test('invalid append write count ' + String(count) + ' does not count unconfirmed bytes', async t => {
    const f = await fixture(t); const attempt = f.attempt(); await attempt.open('', 0);
    once(f.adapter, match('write', CANDIDATE), () => count, 'after');
    const result = await attempt.append(bytes('01234567')); closed(result, 'ioError');
    assert.equal(result.confirmedBytes, 0); await absent(f.candidate);
    assert.equal((await attempt.seal(0)).status, 'invalid');
  });
}

for (const timing of ['before', 'after']) {
  test('short successful write then ' + timing + '-native failure counts only acknowledged bytes', async t => {
    const f = await fixture(t); await f.putPrefix('ABCDEFGH'); const attempt = f.attempt();
    await attempt.open(PREFIX, 4); f.adapter.shortWrite = 2; let writes = 0;
    const reached = once(f.adapter, event => match('write', CANDIDATE)(event) && ++writes === 2,
      () => { throw ioError(811); }, timing);
    const result = await attempt.append(bytes('01234567')); reached(); closed(result, 'ioError');
    assert.equal(result.errorCode, 811); assert.equal(result.confirmedBytes, 6);
    assert.equal(result.cleanupComplete, true); await absent(f.candidate);
    assert.equal(await fs.readFile(f.prefix, 'utf8'), 'ABCDEFGH');
  });
}

test('partial prefix-copy failure reports IO history but cannot seal that partial copy', async t => {
  const f = await fixture(t); await f.putPrefix('0123456789ABCDEF'); f.adapter.shortWrite = 3;
  let writes = 0; once(f.adapter, event => match('write', CANDIDATE)(event) && ++writes === 2,
    () => { throw ioError(812); });
  const attempt = f.attempt(); const result = await attempt.open(PREFIX, 16);
  closed(result, 'ioError'); assert.equal(result.confirmedBytes, 3); await absent(f.candidate);
  assert.equal((await attempt.seal(3)).status, 'invalid');
  assert.equal(await fs.readFile(f.prefix, 'utf8'), '0123456789ABCDEF');
});

test('seal verifies exact fd size before fsync and never blesses an externally changed candidate', async t => {
  const f = await fixture(t); const attempt = f.attempt(); await attempt.open('', 0); await attempt.append(bytes('abcdefgh'));
  await fs.appendFile(f.candidate, 'tail'); const result = await attempt.seal(8);
  closed(result, 'ioError'); assert.equal(result.confirmedBytes, 8); await absent(f.candidate);
  assert.equal(f.adapter.history.filter(match('fsync')).length, 0);
});

const OPEN_STAGES = [
  ['task lstat', 'lstat', ID], ['candidate lstat', 'lstat', CANDIDATE],
  ['candidate open', 'open', CANDIDATE], ['candidate fd stat', 'stat', CANDIDATE],
  ['prefix lstat', 'lstat', PREFIX], ['prefix open', 'open', PREFIX],
  ['prefix fd stat', 'stat', PREFIX], ['prefix read', 'read', PREFIX],
  ['prefix-copy write', 'write', CANDIDATE], ['prefix close', 'close', PREFIX]
];

for (const [label, op, name] of OPEN_STAGES) {
  test('open IO rejection at ' + label + ' returns truthful cleanup/resource facts', async t => {
    const f = await fixture(t); await f.putPrefix('0123456789ABCDEF');
    const reached = once(f.adapter, match(op, name), () => { throw ioError(901); });
    const attempt = f.attempt(); const result = await attempt.open(PREFIX, 8); reached();
    assert.equal(result.status, 'ioError'); assert.equal(result.errorCode, 901); assert.equal(result.sealed, false);
    if (op === 'close') {
      f.allowUncertain(f.prefix); assert.equal(result.prefixClosed, false);
      assert.equal(result.candidateClosed, true); assert.equal(result.resourceUncertain, true);
      assert.equal(result.cleanupComplete, false); assert.ok(await fs.lstat(f.candidate));
    } else {
      assert.equal(result.closed, true); assert.equal(result.resourceUncertain, false);
      if (label === 'candidate fd stat') assert.ok(await fs.lstat(f.candidate));
      else await absent(f.candidate);
      assert.equal(result.cleanupComplete, !['candidate open', 'candidate fd stat'].includes(label));
    }
    assert.equal(await fs.readFile(f.prefix, 'utf8'), '0123456789ABCDEF');
    assert.equal(f.leaseCount(), 0);
    const count = f.adapter.history.length; await attempt.drain(); attempt.dispose(); await attempt.drain();
    assert.equal(f.adapter.history.length, count);
  });
}

for (const [label, op] of [['append write', 'write'], ['seal truncate', 'truncate'],
  ['seal fd stat', 'stat'], ['seal fsync', 'fsync'], ['seal close', 'close']]) {
  test('writable IO rejection at ' + label + ' prevents sealed receipts', async t => {
    const f = await fixture(t); const attempt = f.attempt(); await attempt.open('', 0); await attempt.append(bytes('01234567'));
    const reached = once(f.adapter, match(op, CANDIDATE), () => { throw ioError(902); });
    const result = op === 'write' ? await attempt.append(bytes('89ABCDEF')) : await attempt.seal(7); reached();
    assert.equal(result.status, 'ioError'); assert.equal(result.errorCode, 902); assert.equal(result.sealed, false);
    if (op === 'close') {
      f.allowUncertain(f.candidate); assert.equal(result.closed, false); assert.equal(result.resourceUncertain, true);
      assert.equal(result.candidateCloseCode, 902); assert.equal(result.cleanupComplete, false);
      assert.ok(await fs.lstat(f.candidate)); assert.equal(f.adapter.history.filter(match('close', CANDIDATE)).length, 1);
    } else { assert.equal(result.closed, true); assert.equal(result.cleanupComplete, true); await absent(f.candidate); }
    assert.equal(result.confirmedBytes, ['stat', 'fsync', 'close'].includes(op) ? 7 : 8);
  });
}

for (const [label, op, name] of OPEN_STAGES) {
  test('dispose while ' + label + ' is pending waits real IO then cleans only owned resources', async t => {
    const f = await fixture(t); await f.putPrefix('0123456789ABCDEF');
    const attempt = f.attempt(); const gate = hold(f, match(op, name)); const pending = attempt.open(PREFIX, 8);
    await gate.entered; attempt.dispose(); let drained = false; const drain = attempt.drain().then(value => { drained = true; return value; });
    await Promise.resolve(); await Promise.resolve(); assert.equal(drained, false, 'no timer/cancel shortcut may invent settlement');
    assert.equal((await attempt.open('', 0)).status, 'disposed');
    gate.release(); const result = await pending; gate.reached();
    assert.deepEqual(plain(await drain), plain(result)); closed(result, 'disposed');
    const unclaimed = label === 'candidate open'; assert.equal(result.cleanupComplete, !unclaimed);
    if (unclaimed) {
      assert.equal((await fs.stat(f.candidate)).size, 0);
      assert.equal(f.adapter.history.filter(match('unlink')).length, 0);
    } else await absent(f.candidate);
    assert.equal(await fs.readFile(f.prefix, 'utf8'), '0123456789ABCDEF');
    assert.equal(f.leaseCount(), 0);
    assert.equal(result.confirmedBytes, ['prefix-copy write', 'prefix close'].includes(label) ? 8 : 0);
  });
}

for (const [label, op] of [['append write', 'write'], ['seal truncate', 'truncate'],
  ['seal fd stat', 'stat'], ['seal fsync', 'fsync'], ['seal close', 'close']]) {
  test('dispose while ' + label + ' is pending cannot deliver a seal receipt', async t => {
    const f = await fixture(t); const attempt = f.attempt(); await attempt.open('', 0); await attempt.append(bytes('01234567'));
    const gate = hold(f, match(op, CANDIDATE)); const pending = op === 'write' ? attempt.append(bytes('89ABCDEF')) : attempt.seal(7);
    await gate.entered; attempt.dispose(); let settled = false;
    const drain = attempt.drain().then(value => { settled = true; return value; });
    await Promise.resolve(); await Promise.resolve(); assert.equal(settled, false);
    gate.release(); const result = await pending; gate.reached(); closed(result, 'disposed');
    assert.deepEqual(plain(await drain), plain(result)); assert.equal(result.cleanupComplete, true); await absent(f.candidate);
    assert.equal(result.confirmedBytes, op === 'write' ? 16 : 7);
    assert.equal(f.adapter.history.filter(match('close', CANDIDATE)).length, 1);
  });
}

test('S6 append immediately followed by dispose/drain waits acknowledged write and removes unsealed candidate', async t => {
  const f = await fixture(t); await f.putPrefix('01234567old-tail'); const attempt = f.attempt();
  await attempt.open(PREFIX, 8); const pending = attempt.append(bytes('89ABCDEF'));
  attempt.dispose(); const result = await attempt.drain(); closed(result, 'disposed');
  assert.deepEqual(plain(await pending), plain(result)); assert.equal(result.confirmedBytes, 16);
  assert.equal(result.cleanupComplete, true); await absent(f.candidate);
  assert.equal(await fs.readFile(f.prefix, 'utf8'), '01234567old-tail');
});

for (const [op, name] of [['close', PREFIX], ['close', CANDIDATE], ['unlink', CANDIDATE]]) {
  test('dispose during failed-operation cleanup ' + op + ' of ' + name + ' waits and preserves the primary error', async t => {
    const f = await fixture(t); await f.putPrefix('01234567'); const attempt = f.attempt();
    const entered = f.gate(); const release = f.gate(); let held = false;
    f.adapter.before = async event => {
      if (event.op === 'read') throw ioError(903);
      if (!held && match(op, name)(event)) { held = true; entered.resolve(); await release.promise; }
    };
    const pending = attempt.open(PREFIX, 8); await within(entered.promise, 'failed-operation cleanup');
    attempt.dispose(); let settled = false; const drain = attempt.drain().then(value => { settled = true; return value; });
    await Promise.resolve(); await Promise.resolve(); assert.equal(settled, false);
    assert.equal(f.leaseCount(), 1); release.resolve(); const result = await pending;
    closed(result, 'ioError'); assert.equal(result.errorCode, 903); assert.equal(result.cleanupComplete, true);
    assert.deepEqual(plain(await drain), plain(result)); await absent(f.candidate);
    assert.equal(await fs.readFile(f.prefix, 'utf8'), '01234567');
  });
}

test('disposal after the fixed seal receipt keeps the immutable candidate', async t => {
  const f = await fixture(t); const attempt = f.attempt(); await attempt.open('', 0); await attempt.append(bytes('sealed'));
  const pending = attempt.seal(6); const result = await pending;
  attempt.dispose(); assert.equal(result.status, 'sealed'); assert.equal(result.sealed, true);
  assert.deepEqual(plain(await attempt.drain()), plain(result)); assert.equal(await fs.readFile(f.candidate, 'utf8'), 'sealed');
  const count = f.adapter.history.length; attempt.dispose(); await attempt.drain();
  assert.equal((await attempt.append(bytes('x'))).status, 'disposed'); assert.equal(f.adapter.history.length, count);
});

for (const op of ['close', 'unlink']) {
  test('idle dispose places actual ' + op + ' completion in drain and is idempotent', async t => {
    const f = await fixture(t); const attempt = f.attempt(); await attempt.open('', 0); await attempt.append(bytes('unsealed'));
    const gate = hold(f, match(op, CANDIDATE)); attempt.dispose(); await gate.entered;
    let settled = false; const drain = attempt.drain().then(value => { settled = true; return value; });
    await Promise.resolve(); await Promise.resolve(); assert.equal(settled, false);
    attempt.dispose(); assert.equal((await attempt.seal(8)).status, 'disposed');
    assert.equal(f.leaseCount(), 1); gate.release(); const result = await drain; gate.reached(); closed(result, 'disposed');
    assert.equal(result.cleanupComplete, true); await absent(f.candidate);
    const count = f.adapter.history.length; attempt.dispose(); await attempt.drain(); await attempt.drain();
    assert.equal(f.adapter.history.length, count); assert.equal(f.adapter.history.filter(match('close', CANDIDATE)).length, 1);
    assert.equal(f.adapter.history.filter(match('unlink', CANDIDATE)).length, 1);
  });
}

test('each operation and drain returns independent result facts', async t => {
  const f = await fixture(t); const attempt = f.attempt(); const initial = await attempt.drain(); initial.status = 'tampered';
  assert.equal((await attempt.drain()).status, 'new');
  const opened = await attempt.open('', 0); opened.confirmedBytes = 888; opened.closed = true;
  assert.equal((await attempt.drain()).confirmedBytes, 0); assert.equal((await attempt.drain()).closed, false);
  const appended = await attempt.append(bytes('bytes')); const observed = await attempt.drain();
  assert.notEqual(appended, observed); appended.confirmedBytes = 999; observed.fileName = 'tampered';
  assert.equal((await attempt.drain()).confirmedBytes, 5); assert.equal((await attempt.drain()).fileName, CANDIDATE);
  const result = await attempt.seal(5); result.sealed = false; result.status = 'tampered';
  assert.equal((await attempt.drain()).sealed, true); assert.equal((await attempt.drain()).status, 'sealed');
});

test('drain captures admitted work and does not acquire hidden queue capacity', async t => {
  const f = await fixture(t); const attempt = f.attempt(); await attempt.open('', 0);
  const oldDrain = attempt.drain(); const gate = hold(f, match('write', CANDIDATE));
  const pending = attempt.append(bytes('next')); await gate.entered;
  assert.equal((await oldDrain).status, 'opened');
  let settled = false; const nextDrain = attempt.drain().then(value => { settled = true; return value; });
  await Promise.resolve(); assert.equal(settled, false);
  gate.release(); assert.equal((await pending).status, 'appended'); assert.equal((await nextDrain).confirmedBytes, 4);
});

for (const timing of ['before', 'after']) {
  test('candidate close rejection ' + timing + ' native close stays uncertain and is never retried', async t => {
    const f = await fixture(t); const attempt = f.attempt(); await attempt.open('', 0); await attempt.append(bytes('data'));
    if (timing === 'before') f.allowUncertain(f.candidate);
    const reached = once(f.adapter, match('close', CANDIDATE), () => { throw ioError(1001); }, timing);
    const result = await attempt.seal(4); reached();
    assert.equal(result.status, 'ioError'); assert.equal(result.closed, false); assert.equal(result.resourceUncertain, true);
    assert.equal(result.candidateCloseCode, 1001); assert.equal(result.sealed, false); assert.equal(result.cleanupComplete, false);
    assert.equal(f.adapter.handles.size, timing === 'before' ? 1 : 0);
    assert.equal(await fs.readFile(f.candidate, 'utf8'), 'data');
    attempt.dispose(); await attempt.drain(); await attempt.drain();
    assert.equal(f.adapter.history.filter(match('close', CANDIDATE)).length, 1);
    assert.equal(f.adapter.history.filter(match('unlink')).length, 0);
  });
}

test('prefix close rejection after native close remains uncertain while candidate close still runs', async t => {
  const f = await fixture(t); await f.putPrefix('01234567');
  const reached = once(f.adapter, match('close', PREFIX), () => { throw ioError(1002); }, 'after');
  const result = await f.attempt().open(PREFIX, 8); reached();
  assert.equal(result.status, 'ioError'); assert.equal(result.errorCode, 1002);
  assert.equal(result.prefixClosed, false); assert.equal(result.candidateClosed, true);
  assert.equal(result.closed, false); assert.equal(result.resourceUncertain, true); assert.equal(result.cleanupComplete, false);
  assert.equal(f.adapter.handles.size, 0); assert.equal(f.adapter.history.filter(match('close', PREFIX)).length, 1);
  assert.equal(f.adapter.history.filter(match('close', CANDIDATE)).length, 1);
  assert.equal(f.adapter.history.filter(match('unlink')).length, 0);
  assert.equal(await fs.readFile(f.prefix, 'utf8'), '01234567');
  assert.equal(await fs.readFile(f.candidate, 'utf8'), '01234567');
});

test('primary read error and both independent close failures are retained without unlink', async t => {
  const f = await fixture(t); await f.putPrefix('01234567'); f.allowUncertain(f.prefix); f.allowUncertain(f.candidate);
  f.adapter.before = event => {
    if (event.op === 'read') throw ioError(1101);
    if (match('close', PREFIX)(event)) throw ioError(1102);
    if (match('close', CANDIDATE)(event)) throw ioError(1103);
  };
  const result = await f.attempt().open(PREFIX, 8);
  assert.equal(result.status, 'ioError'); assert.equal(result.errorCode, 1101);
  assert.equal(result.prefixCloseCode, 1102); assert.equal(result.candidateCloseCode, 1103);
  assert.equal(result.prefixClosed, false); assert.equal(result.candidateClosed, false);
  assert.equal(result.resourceUncertain, true); assert.equal(result.cleanupComplete, false);
  assert.equal(f.adapter.history.filter(match('close', PREFIX)).length, 1);
  assert.equal(f.adapter.history.filter(match('close', CANDIDATE)).length, 1);
  assert.equal(f.adapter.history.filter(match('unlink')).length, 0); assert.ok(await fs.lstat(f.candidate));
});

test('primary write failure survives unlink failure after successful close', async t => {
  const f = await fixture(t); const attempt = f.attempt(); await attempt.open('', 0);
  f.adapter.before = event => {
    if (event.op === 'write') throw ioError(1201);
    if (event.op === 'unlink') throw ioError(1202);
  };
  const result = await attempt.append(bytes('x')); closed(result, 'ioError');
  assert.equal(result.errorCode, 1201); assert.equal(result.cleanupErrorCode, 1202); assert.equal(result.cleanupComplete, false);
  assert.ok(await fs.lstat(f.candidate)); const count = f.adapter.history.length;
  attempt.dispose(); await attempt.drain(); assert.equal(f.adapter.history.length, count);
});

test('idle disposal retains its primary status while reporting auxiliary close or unlink failure', async t => {
  const f = await fixture(t);
  for (const op of ['close', 'unlink']) {
    const name = op + '.part'; const target = f.file(name); const attempt = f.attempt(name); await attempt.open('', 0);
    if (op === 'close') f.allowUncertain(target);
    once(f.adapter, match(op, name), () => { throw ioError(1203); });
    attempt.dispose(); const result = await attempt.drain(); assert.equal(result.status, 'disposed');
    assert.equal(result.errorCode, 0); assert.equal(result.cleanupComplete, false);
    assert.equal(result.closed, op !== 'close'); assert.equal(result.resourceUncertain, op === 'close');
    assert.equal(op === 'close' ? result.candidateCloseCode : result.cleanupErrorCode, 1203);
    assert.ok(await fs.lstat(target)); f.adapter.before = null;
  }
});

test('actual IO rejection while cancellation is pending keeps the primary IO error', async t => {
  const f = await fixture(t); const attempt = f.attempt(); await attempt.open('', 0);
  const gate = hold(f, match('write', CANDIDATE));
  f.adapter.after = event => { if (event.op === 'write') throw ioError(1204); };
  const pending = attempt.append(bytes('x')); await gate.entered; attempt.dispose(); gate.release();
  const result = await pending; closed(result, 'ioError'); assert.equal(result.errorCode, 1204);
  assert.equal(result.confirmedBytes, 0); await absent(f.candidate);
});

test('same basename lease excludes other instances throughout opening, idle, append, and cleanup', async t => {
  const f = await fixture(t); const attempt = f.attempt(); const openingGate = hold(f, match('open', CANDIDATE));
  const pending = attempt.open('', 0); assert.equal(f.leaseCount(), 1);
  assert.equal((await f.attempt().open('', 0)).status, 'collision');
  await openingGate.entered; openingGate.release(); await pending;
  assert.equal((await f.attempt().open('', 0)).status, 'collision');
  const appendGate = hold(f, match('write', CANDIDATE)); const append = attempt.append(bytes('x')); await appendGate.entered;
  assert.equal((await f.attempt().open('', 0)).status, 'collision'); appendGate.release(); await append;
  assert.equal(f.leaseCount(), 1);
  const cleanupGate = hold(f, match('unlink', CANDIDATE)); attempt.dispose(); await cleanupGate.entered;
  const count = f.adapter.history.length; assert.equal((await f.attempt().open('', 0)).status, 'collision');
  assert.equal(f.adapter.history.length, count); cleanupGate.release(); await attempt.drain();
  assert.equal(f.leaseCount(), 0); await absent(f.candidate);
  const next = f.attempt(); assert.equal((await next.open('', 0)).status, 'opened');
  await next.append(bytes('new owner')); await next.seal(9);
  const after = f.adapter.history.length; attempt.dispose(); await attempt.drain();
  assert.equal(f.adapter.history.length, after); assert.equal(await fs.readFile(f.candidate, 'utf8'), 'new owner');
});

test('normalized directory spellings share a lease and Windows case aliases cannot bypass it', async t => {
  const f = await fixture(t); const attempt = f.attempt(); await attempt.open('', 0);
  const spellings = [f.base + '/./', f.base.replaceAll('\\', '/') + '/unused/..'];
  if (process.platform === 'win32') spellings.push(f.base.toUpperCase().replaceAll('\\', '/'));
  for (const spelling of spellings) {
    const other = f.attempt(process.platform === 'win32' ? CANDIDATE.slice(0, -5).toUpperCase() + '.part' : CANDIDATE,
      Number.MAX_SAFE_INTEGER, spelling);
    const count = f.adapter.history.length; assert.equal((await other.open('', 0)).status, 'collision');
    assert.equal(f.adapter.history.length, count);
  }
});

test('different candidates can run concurrently without sharing bytes or cleanup', async t => {
  const f = await fixture(t); const first = f.attempt('first.part'); const second = f.attempt('second.part');
  const gate = hold(f, match('open', 'first.part')); const firstOpen = first.open('', 0); await gate.entered;
  assert.equal((await second.open('', 0)).status, 'opened'); assert.equal(f.leaseCount(), 2);
  assert.equal((await second.append(bytes('second'))).status, 'appended'); assert.equal((await second.seal(6)).status, 'sealed');
  gate.release(); await firstOpen; await first.append(bytes('first')); first.dispose(); await first.drain();
  await absent(f.file('first.part')); assert.equal(await fs.readFile(f.file('second.part'), 'utf8'), 'second');
  assert.ok(f.adapter.peakPending >= 2); assert.equal(f.leaseCount(), 0);
});

test('foreign candidates, historical orphans, prefix, and ordinary/state slots survive own cleanup', async t => {
  const f = await fixture(t); const names = ['http-state.json', 'adaptive-state.1.json', 'adaptive-state.2.json',
    'other_candidate.part', 'historical_orphan.part', PREFIX];
  for (const name of names) await fs.writeFile(f.file(name), 'preserve:' + name);
  const before = await Promise.all(names.map(name => fs.readFile(f.file(name))));
  const attempt = f.attempt(); await attempt.open(PREFIX, 8); await attempt.append(bytes('new bytes'));
  attempt.dispose(); await attempt.drain(); await absent(f.candidate);
  for (let i = 0; i < names.length; i++) assert.deepEqual(await fs.readFile(f.file(names[i])), before[i]);
  assert.deepEqual((await fs.readdir(f.dir)).sort(), names.sort());
  assert.deepEqual(f.adapter.history.filter(match('unlink')).map(event => event.path), [f.candidate]);
});

test('resource results expose only fixed statuses/codes/basename and never raw exceptions, paths, or fds', async t => {
  const f = await fixture(t); const attempt = f.attempt(); await attempt.open('', 0);
  const secret = 'https://private.example/?token=do-not-log ' + f.candidate;
  once(f.adapter, match('write'), () => { throw ioError(1301, secret); });
  const result = await attempt.append(bytes('x')); assert.equal(result.status, 'ioError'); assert.equal(result.errorCode, 1301);
  const encoded = JSON.stringify(result); assert.equal(encoded.includes(secret), false); assert.equal(encoded.includes(f.base), false);
  assert.deepEqual(Object.keys(plain(result)).sort(), ['status', 'errorCode', 'fileName', 'confirmedBytes', 'sealed', 'closed',
    'cleanupComplete', 'resourceUncertain', 'prefixClosed', 'candidateClosed', 'prefixCloseCode', 'candidateCloseCode',
    'cleanupErrorCode'].sort());
});

test('unknown or throwing SDK error codes remain fixed code0 rather than escaping', async t => {
  const f = await fixture(t);
  for (const [index, error] of [new Error('raw message'), { code: -1 }, { code: 'EIO' },
    { get code() { throw new Error('getter failure'); } }].entries()) {
    const name = 'unknown' + index + '.part'; const attempt = f.attempt(name);
    f.adapter.rawErrors = false; assert.equal((await attempt.open('', 0)).status, 'opened');
    f.adapter.rawErrors = true;
    once(f.adapter, match('write', name), () => { throw error; });
    const result = await attempt.append(bytes('x')); closed(result, 'ioError'); assert.equal(result.errorCode, 0);
    f.adapter.before = null; await absent(f.file(name));
  }
});
