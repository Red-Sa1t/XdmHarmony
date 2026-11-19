'use strict';
// Actual production ETS with async SDK adapters over isolated real temporary directories.
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const nativeFs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { performance } = require('node:perf_hooks');
const { test } = require('node:test');
const { loadProduction } = require('./production-loader.cjs');

const SOURCE = path.resolve(__dirname, '../../entry/src/main/ets/core');
const ID = '01234567-89ab-cdef-0123-456789abcdef';
const OTHER_ID = '11234567-89ab-cdef-0123-456789abcdef';
const PRIMARY = 'https://state.example/list.m3u8?sig=a%2Fb';
const model = loadProduction(path.join(SOURCE, 'adaptive/HlsModel.ets'), {}, { Error });
const parser = loadProduction(path.join(SOURCE, 'adaptive/HlsParser.ets'), { './HlsModel': model }, { Error });
const plan = loadProduction(path.join(SOURCE, 'adaptive/AdaptivePlan.ets'), { './DashModel': require('./production-loader.cjs').loadProduction(require('node:path').resolve(__dirname, '../../entry/src/main/ets/core/adaptive/DashModel.ets'), {}, { Error }), 
  './HlsModel': model, './HlsParser': parser
}, { Error });
const codec = loadProduction(path.join(SOURCE, 'adaptive/AdaptiveStateCodec.ets'), { './AdaptivePlan': plan }, { Error });
const plain = value => JSON.parse(JSON.stringify(value));
const clone = value => codec.decodeAdaptiveState(codec.encodeAdaptiveState(value), value.downloadId);

function ioError(code = 13900005) {
  const value = new Error('Injected filesystem failure');
  value.code = code;
  return value;
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
      timer = setTimeout(() => reject(new Error('Timed out: ' + label)), 5000);
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
    this.shortRead = Infinity;
    this.shortWrite = Infinity;
    this.api = {
      OpenMode: { READ_ONLY: 0, WRITE_ONLY: 1, CREATE: 64, NOFOLLOW: 262144 },
      lstat: target => this.call('lstat', { path: target }, async () => {
        const value = await fs.lstat(target);
        return { size: value.size, isFile: () => value.isFile(), isDirectory: () => value.isDirectory() };
      }),
      mkdir: (target, recursive) => this.call('mkdir', { path: target }, async () => {
        await fs.mkdir(target, { recursive: recursive === true });
      }),
      open: (target, mode) => this.call('open', { path: target, mode }, async () => {
        let flags = (mode & 1) ? nativeFs.constants.O_WRONLY : nativeFs.constants.O_RDONLY;
        if (mode & 64) flags |= nativeFs.constants.O_CREAT;
        if (mode & 262144) flags |= nativeFs.constants.O_NOFOLLOW || 0;
        const handle = await fs.open(target, flags);
        this.handles.set(handle.fd, handle); this.paths.set(handle.fd, path.resolve(target));
        return { fd: handle.fd };
      }),
      read: (fd, buffer, options) => this.call('read', {
        fd, path: this.paths.get(fd), requested: options?.length ?? buffer.byteLength
      }, async () => {
        assert.equal(options?.offset, undefined, 'read must follow current file pointer without relative seek');
        const handle = this.handles.get(fd); if (!handle) throw ioError(13900008);
        const length = Math.min(options?.length ?? buffer.byteLength, this.shortRead);
        const value = await handle.read(Buffer.from(buffer), 0, length, null);
        return value.bytesRead;
      }),
      write: (fd, buffer, options) => this.call('write', {
        fd, path: this.paths.get(fd), requested: buffer.byteLength
      }, async () => {
        assert.equal(options?.offset, undefined, 'write must follow current file pointer without relative seek');
        const handle = this.handles.get(fd); if (!handle) throw ioError(13900008);
        const length = Math.min(buffer.byteLength, this.shortWrite);
        const value = await handle.write(Buffer.from(buffer), 0, length, null);
        return value.bytesWritten;
      }),
      fsync: fd => this.call('fsync', { fd, path: this.paths.get(fd) }, async () => {
        const handle = this.handles.get(fd); if (!handle) throw ioError(13900008);
        await handle.sync();
      }),
      close: file => {
        const fd = typeof file === 'number' ? file : file.fd;
        return this.call('close', { fd, path: this.paths.get(fd) }, async () => {
          const handle = this.handles.get(fd); if (!handle) throw ioError(13900008);
          await handle.close(); this.handles.delete(fd);
        });
      },
      unlink: target => this.call('unlink', { path: target }, () => fs.unlink(target)),
      rename: (from, to) => this.call('rename', { path: from, to: path.resolve(to) }, () => fs.rename(from, to))
    };
  }

  async call(op, fields, operation) {
    const event = { op, ...fields, path: fields.path ? path.resolve(fields.path) : '', index: this.history.length };
    this.history.push(event);
    try {
      if (this.before) await this.before(event);
      const value = await operation();
      if (this.after) {
        const replacement = await this.after(event, value);
        if (replacement !== undefined) return replacement;
      }
      return value;
    } catch (error) { throw sdkError(error); }
  }
}

function fresh(count = 1, ranged = false, id = ID, segmentUrl = 'https://state.example/s.ts') {
  const lines = [];
  for (let i = 0; i < count; i++) {
    if (ranged) lines.push('#EXT-X-BYTERANGE:10@90');
    lines.push(segmentUrl);
  }
  const media = parser.parseHlsMediaPlaylist('#EXTM3U\n' + lines.join('\n'), PRIMARY, (_base, reference) => reference);
  assert.ok(media);
  const built = plan.buildHlsPlan(PRIMARY, media);
  assert.ok(built);
  const value = codec.newAdaptiveState(id, built);
  assert.ok(value);
  return value;
}

function prefix(state, index, bytes, complete = false, fileName = 'p' + index + '.part') {
  state.parts[index].downloaded = bytes;
  state.parts[index].complete = complete;
  state.parts[index].fileName = fileName;
}

async function fixture(t) {
  const temporaryRoot = path.resolve(os.tmpdir());
  const base = await fs.mkdtemp(path.join(temporaryRoot, 'xdm-adaptive-state-'));
  const absoluteBase = path.resolve(base);
  const adapter = new FileAdapter();
  const stores = [];
  const gates = [];
  const allocations = [];
  const uuids = [];
  const metrics = { captures: 0 };
  class TrackedArrayBuffer extends ArrayBuffer {
    constructor(size) { super(size); allocations.push(size); }
  }
  class HostTextEncoder { encodeInto(text) { return new TextEncoder().encode(text); } }
  const util = {
    TextEncoder: HostTextEncoder,
    TextDecoder: { create: (encoding, options) => {
      const decoder = new TextDecoder(encoding, options);
      return { decodeToString: (input, decodeOptions) => decoder.decode(input, decodeOptions) };
    } },
    generateRandomUUID: () => uuids.length ? uuids.shift() : crypto.randomUUID()
  };
  const observedCodec = { ...codec, encodeAdaptiveState: value => {
    metrics.captures++; return codec.encodeAdaptiveState(value);
  } };
  const production = loadProduction(path.join(SOURCE, 'db/AdaptiveStateStore.ets'), {
    '@kit.CoreFileKit': { fileIo: adapter.api }, '@kit.ArkTS': { util }, '@kit.BasicServicesKit': {},
    '../adaptive/AdaptivePlan': plan, '../adaptive/AdaptiveStateCodec': observedCodec
  }, { Error, ArrayBuffer: TrackedArrayBuffer });
  const value = {
    base, adapter, stores, allocations, uuids, metrics, production,
    dir: path.join(base, ID),
    slot: number => path.join(base, ID, 'adaptive-state.' + number + '.json'),
    store: (directory = base, id = ID) => {
      const store = new production.AdaptiveStateStore(directory, id);
      stores.push(store); return store;
    },
    gate: () => { const gate = deferred(); gates.push(gate); return gate; },
    slots: async () => {
      const values = [];
      for (const number of [1, 2]) {
        try { values.push(await fs.readFile(value.slot(number), 'utf8')); }
        catch (error) { if (error.code !== 'ENOENT') throw error; values.push(null); }
      }
      return values;
    },
    putSlot: async (number, state) => {
      await fs.mkdir(value.dir, { recursive: true });
      await fs.writeFile(value.slot(number), codec.encodeAdaptiveState(state), 'utf8');
    },
    parts: async (state, length = null) => {
      await fs.mkdir(value.dir, { recursive: true });
      for (const part of state.parts) {
        if (part.fileName) await fs.writeFile(path.join(value.dir, part.fileName), Buffer.alloc(length ?? part.downloaded, 0x61));
      }
    }
  };
  t.after(async () => {
    adapter.before = null; adapter.after = null;
    for (const gate of gates) gate.resolve();
    for (const store of stores) store.dispose();
    await Promise.all(stores.map(store => store.drain()));
    const leaked = adapter.handles.size;
    for (const handle of adapter.handles.values()) { try { await handle.close(); } catch {} }
    adapter.handles.clear();
    // Verify the exact generated absolute target before recursive test-fixture cleanup.
    assert.equal(path.resolve(base), absoluteBase);
    assert.equal(path.dirname(absoluteBase), temporaryRoot);
    assert.ok(path.basename(absoluteBase).startsWith('xdm-adaptive-state-'));
    await fs.rm(absoluteBase, { recursive: true, force: true });
    assert.equal(leaked, 0, 'production must settle/close its owned handles before drain');
  });
  return value;
}

async function seedTwo(f) {
  const store = f.store();
  const first = await store.save(fresh(), -1);
  assert.equal(first.status, 'saved');
  const second = await store.save(first.state, 0);
  assert.equal(second.status, 'saved'); assert.equal(second.state.generation, 1);
  await store.drain(); f.adapter.history.length = 0;
  return { store, state: second.state };
}

function mutateOnce(adapter, phase, when = 'before') {
  let triggered = false;
  adapter[when] = async (event, value) => {
    if (!triggered && phase(event)) { triggered = true; throw ioError(); }
    return value;
  };
  return () => assert.equal(triggered, true, 'requested fault must reach its IO boundary');
}

test('constructor and owner validation reject with zero IO before any large snapshot', async t => {
  const f = await fixture(t);
  for (const args of [['relative/path', ID], ['', ID], [f.base, '../outside'], [f.base + '\0bad', ID]]) {
    const store = f.store(...args);
    assert.equal((await store.load()).status, 'invalid');
    assert.equal((await store.save(fresh(), -1)).status, 'invalid');
  }
  const store = f.store();
  assert.equal((await store.save(fresh(1, false, OTHER_ID), -1)).status, 'invalid');
  for (const generation of [-2, 0.5, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1, Number.MAX_SAFE_INTEGER]) {
    assert.equal((await store.save(fresh(), generation)).status, 'invalid');
  }
  const invalid = fresh(); invalid.parts[0].downloaded = 1;
  for (let i = 0; i < 3; i++) assert.equal((await store.save(invalid, -1)).status, 'invalid',
    'failed validation must release the synchronously reserved capacity');
  assert.equal(f.adapter.history.length, 0);
  assert.equal(f.allocations.length, 0);
});

test('empty load creates no directory and dispose makes later calls inert', async t => {
  const f = await fixture(t); const store = f.store();
  assert.deepEqual(plain(await store.load()), { status: 'empty', state: null, repairedParts: 0 });
  await assert.rejects(fs.stat(f.dir), { code: 'ENOENT' });
  const before = f.adapter.history.length; store.dispose();
  assert.equal((await store.load()).status, 'disposed');
  assert.equal((await store.save(fresh(), -1)).status, 'disposed');
  await store.drain(); assert.equal(f.adapter.history.length, before);
});

test('initial save, generations and reopen recovery preserve independent caller snapshots', async t => {
  const f = await fixture(t); const store = f.store(); const input = fresh();
  const first = await store.save(input, -1);
  assert.equal(first.status, 'saved'); assert.equal(first.state.generation, 0); assert.equal(input.generation, 0);
  const second = await store.save(first.state, 0);
  assert.equal(second.status, 'saved'); assert.equal(second.state.generation, 1);
  assert.equal(first.state.generation, 0);
  const third = await store.save(second.state, 1);
  assert.equal(third.status, 'saved'); assert.equal(third.state.generation, 2);
  const slots = await f.slots();
  assert.equal(JSON.parse(slots[0]).generation, 2); assert.equal(JSON.parse(slots[1]).generation, 1);
  third.state.plan.chunks[0].url = 'https://changed.example/x.ts';
  const reopened = await f.store().load();
  assert.equal(reopened.status, 'loaded'); assert.equal(reopened.state.generation, 2);
  assert.equal(reopened.state.plan.chunks[0].url, input.plan.chunks[0].url);
});

test('generation ordering overrides reversed slot position and mtime', async t => {
  const f = await fixture(t);
  const older = fresh(); older.generation = 7;
  const newer = fresh(); newer.generation = 9;
  await f.putSlot(1, older); await f.putSlot(2, newer);
  await fs.utimes(f.slot(1), new Date(), new Date());
  await fs.utimes(f.slot(2), new Date(0), new Date(0));
  assert.equal((await f.store().load()).state.generation, 9);
  await f.putSlot(1, newer); await f.putSlot(2, older);
  assert.equal((await f.store().load()).state.generation, 9);
});

test('one malformed replica falls back, while invalid or wrong-owner-only slots cannot initialize', async t => {
  const f = await fixture(t); const store = f.store();
  const valid = fresh(); valid.generation = 4;
  await f.putSlot(2, valid); await fs.writeFile(f.slot(1), '{"unfinished":');
  assert.equal((await store.load()).state.generation, 4);
  await fs.unlink(f.slot(2));
  const before = await f.slots();
  assert.equal((await store.load()).status, 'invalid');
  assert.equal((await store.save(fresh(), -1)).status, 'invalid');
  assert.deepEqual(await f.slots(), before);
  await f.putSlot(1, fresh(1, false, OTHER_ID));
  assert.equal((await store.load()).status, 'invalid');
  await fs.writeFile(f.slot(1), codec.encodeAdaptiveState(fresh()).replace('"schema":1', '"schema":2'));
  assert.equal((await store.load()).status, 'invalid');
});

test('equal-generation identical replicas are recoverable and differing canonical contents conflict', async t => {
  const f = await fixture(t); const original = fresh(); original.generation = 2;
  await f.putSlot(1, original); await f.putSlot(2, original);
  assert.equal((await f.store().load()).state.generation, 2);
  const changed = fresh(1, false, ID, 'https://state.example/changed.ts'); changed.generation = 2;
  await f.putSlot(2, changed);
  const before = await f.slots();
  assert.equal((await f.store().load()).status, 'conflict');
  assert.equal((await f.store().save(original, 2)).status, 'conflict');
  assert.deepEqual(await f.slots(), before);
});

test('unreadable newer slot permits older load but blocks save without changing either slot', async t => {
  const f = await fixture(t); const older = fresh(); older.generation = 8;
  const newer = fresh(); newer.generation = 9;
  await f.putSlot(1, older); await f.putSlot(2, newer);
  const before = await f.slots();
  const store = f.store();
  for (const fault of ['open', 'stat-property']) {
    f.adapter.before = async event => {
      if (fault === 'open' && event.op === 'open' && event.path === f.slot(2)) throw ioError();
    };
    f.adapter.after = async (event, value) => {
      if (fault === 'stat-property' && event.op === 'lstat' && event.path === f.slot(2)) {
        Object.defineProperty(value, 'size', { get() { throw ioError(); } });
      }
      return value;
    };
    const loaded = await store.load();
    assert.equal(loaded.status, 'loaded'); assert.equal(loaded.state.generation, 8);
    assert.equal((await store.save(loaded.state, 8)).status, 'ioError');
    assert.deepEqual(await f.slots(), before);
  }
  assert.equal(f.adapter.history.some(event => ['write', 'unlink', 'rename', 'fsync'].includes(event.op)), false);
});

test('unknown slot metadata and read-close faults remain IO errors rather than empty slots', async t => {
  const f = await fixture(t); const store = f.store(); await f.putSlot(1, fresh());
  for (const op of ['lstat', 'open', 'read', 'close']) {
    const before = await f.slots();
    f.adapter.before = async event => { if (event.op === op && event.path === f.slot(1)) throw ioError(13900012); };
    assert.equal((await store.load()).status, 'ioError', op);
    assert.equal((await store.save(fresh(), -1)).status, 'ioError', op);
    f.adapter.before = null;
    // Persistent synthetic close failure may retain a handle; close it after the simulated fault is removed.
    for (const handle of f.adapter.handles.values()) { await handle.close(); }
    f.adapter.handles.clear();
    assert.deepEqual(await f.slots(), before);
  }
});

test('short IO follows file pointers and strict UTF-8 survives split multibyte characters', async t => {
  const f = await fixture(t); const store = f.store();
  f.adapter.shortWrite = 7; f.adapter.shortRead = 2;
  const state = fresh(1, false, ID, 'https://state.example/中文-😀.ts?sig=a%2Fb');
  const saved = await store.save(state, -1);
  assert.equal(saved.status, 'saved');
  const loaded = await store.load();
  assert.equal(loaded.status, 'loaded'); assert.deepEqual(plain(loaded.state), plain(state));
  assert.ok(f.adapter.history.filter(event => event.op === 'write').length > 20);
  assert.ok(f.adapter.history.filter(event => event.op === 'read').length > 100);
  assert.ok(f.allocations.every(size => size <= 65536));
});

test('UTF-8 decoder retains a four-byte character split across the 64 KiB block boundary', async t => {
  const f = await fixture(t); const store = f.store(); const state = fresh(3);
  state.plan.chunks[2].url = 'https://state.example/😀.ts';
  let remaining = 65535 - Buffer.from(codec.encodeAdaptiveState(state)).indexOf(Buffer.from('😀'));
  for (let i = 0; i < 2; i++) {
    const chunk = state.plan.chunks[i];
    const count = Math.min(remaining, model.HLS_MAX_URL_CHARS - chunk.url.length);
    chunk.url = chunk.url.slice(0, -4) + 'x'.repeat(count) + 's.ts'; remaining -= count;
  }
  assert.equal(remaining, 0);
  assert.equal(Buffer.from(codec.encodeAdaptiveState(state)).indexOf(Buffer.from('😀')), 65535);
  assert.equal((await store.save(state, -1)).status, 'saved');
  const loaded = await store.load();
  assert.equal(loaded.status, 'loaded'); assert.deepEqual(plain(loaded.state), plain(state));
  assert.ok(f.allocations.includes(65536));
});

test('malformed and incomplete UTF-8 never become valid slot contents', async t => {
  const f = await fixture(t); const store = f.store(); await fs.mkdir(f.dir);
  const encoded = Buffer.from(codec.encodeAdaptiveState(fresh()), 'utf8');
  for (const bad of [
    Buffer.concat([encoded, Buffer.from([0xc3])]),
    Buffer.from([0xff, 0xfe, 0x7b, 0x7d]),
    Buffer.concat([Buffer.from('{"'), Buffer.from([0xc0, 0xaf]), Buffer.from('":1}')])
  ]) {
    await fs.writeFile(f.slot(1), bad);
    assert.equal((await store.load()).status, 'invalid');
  }
});

test('oversized byte metadata rejects before opening or allocating file buffers', async t => {
  const f = await fixture(t); await f.putSlot(1, fresh()); const store = f.store();
  f.adapter.after = async (event, value) => {
    if (event.op === 'lstat' && event.path === f.slot(1)) value.size = plan.ADAPTIVE_MAX_STATE_CHARS * 4 + 1;
    return value;
  };
  assert.equal((await store.load()).status, 'invalid');
  assert.equal(f.adapter.history.some(event => event.op === 'open'), false);
  assert.equal(f.allocations.length, 0);
});

test('text limit is enforced while streaming even when the byte limit permits the file', async t => {
  const f = await fixture(t); await fs.mkdir(f.dir);
  const handle = await fs.open(f.slot(1), 'w');
  const block = Buffer.alloc(65536, 0x20);
  try {
    for (let i = 0; i < plan.ADAPTIVE_MAX_STATE_CHARS / block.length + 1; i++) await handle.write(block);
  } finally { await handle.close(); }
  assert.equal((await f.store().load()).status, 'invalid');
  assert.ok(f.allocations.every(size => size <= 65536));
});

test('stat-sized truncation and unexpected tail growth reject instead of decoding a prefix', async t => {
  const f = await fixture(t); const store = f.store();
  for (const delta of [-1, 1]) {
    await f.putSlot(1, fresh());
    f.adapter.after = async (event, value) => {
      if (event.op === 'lstat' && event.path === f.slot(1)) value.size += delta;
      return value;
    };
    assert.equal((await store.load()).status, 'invalid');
  }
});

test('invalid read counts and zero, negative or oversized writes stop publication', async t => {
  const f = await fixture(t); const store = f.store(); await f.putSlot(1, fresh());
  const before = await f.slots();
  for (const count of [-1, NaN, Infinity, 999999]) {
    f.adapter.after = async (event, value) => event.op === 'read' ? count : value;
    assert.equal((await store.load()).status, 'ioError');
  }
  f.adapter.after = null;
  for (const count of [0, -1, NaN, Infinity, 999999]) {
    f.adapter.after = async (event, value) => event.op === 'write' ? count : value;
    assert.equal((await store.save(fresh(), 0)).status, 'ioError');
    assert.deepEqual(await f.slots(), before);
  }
});

test('staging faults preserve the latest slot and only known-closed instances can resume IO', async t => {
  const phases = ['open', 'write', 'fsync', 'close', 'unlink', 'rename'];
  for (const op of phases) {
    const f = await fixture(t); const seeded = await seedTwo(f);
    const before = await f.slots();
    const observed = mutateOnce(f.adapter, event => event.op === op &&
      (op === 'unlink' ? event.path === f.slot(1) : event.path.endsWith('.tmp')));
    assert.equal((await seeded.store.save(seeded.state, 1)).status, 'ioError', op); observed();
    f.adapter.before = null;
    const after = await f.slots();
    assert.equal(after[1], before[1], op + ' must preserve the latest slot');
    if (op !== 'rename') assert.equal(after[0], before[0], op);
    if (op === 'close') {
      assert.equal(seeded.store.hasUncertainResources(), true);
      const calls = f.adapter.history.length; const captures = f.metrics.captures;
      assert.equal((await seeded.store.load()).status, 'ioError');
      assert.equal((await seeded.store.save(seeded.state, 1)).status, 'ioError');
      assert.equal(f.adapter.history.length, calls, 'unknown closure must prevent subsequent IO');
      assert.equal(f.metrics.captures, captures, 'quarantined instance must not capture another snapshot');
      const retained = (await fs.readdir(f.dir)).filter(name => name.endsWith('.tmp'));
      assert.equal(retained.length, 1);
      assert.equal(f.adapter.handles.size, 1);
      const [fd, handle] = [...f.adapter.handles.entries()][0];
      const retainedPath = path.join(f.dir, retained[0]);
      assert.equal(f.adapter.paths.get(fd), retainedPath);
      assert.equal((await handle.stat()).isFile(), true, 'injected close rejection leaves the actual host fd open');
      assert.equal(f.adapter.history.filter(event => event.op === 'close' && event.path === retainedPath).length, 1);
      assert.equal(f.adapter.history.some(event => event.op === 'unlink' && event.path === retainedPath), false);
      seeded.store.dispose(); await seeded.store.drain();
      assert.equal(seeded.store.hasUncertainResources(), true);
      // Test-only release AFTER asserting the real resource facts. This is not product closure.
      await handle.close(); f.adapter.handles.delete(fd);
    } else {
      assert.equal(seeded.store.hasUncertainResources(), false);
      assert.equal((await seeded.store.load()).state.generation, 1);
      assert.equal((await seeded.store.save(seeded.state, 1)).status, 'saved', op + ' must release queue admission');
      assert.equal((await fs.readdir(f.dir)).some(name => name.endsWith('.tmp')), false);
    }
  }
});

test('close failure reported after closing still prevents publication and cannot erase the old checkpoint', async t => {
  const f = await fixture(t); const seeded = await seedTwo(f); const before = await f.slots();
  const observed = mutateOnce(f.adapter, event => event.op === 'close' && event.path.endsWith('.tmp'), 'after');
  assert.equal((await seeded.store.save(seeded.state, 1)).status, 'ioError'); observed();
  f.adapter.after = null;
  assert.deepEqual(await f.slots(), before);
  assert.equal(f.adapter.handles.size, 0);
  assert.equal(seeded.store.hasUncertainResources(), true, 'a rejected close cannot establish closure from SDK facts');
  assert.equal((await fs.readdir(f.dir)).filter(name => name.endsWith('.tmp')).length, 1);
});

test('failed cleanup leaves only its own orphan staging and a subsequent save never sweeps that orphan', async t => {
  const f = await fixture(t); const seeded = await seedTwo(f); const before = await f.slots();
  let abandoned = '';
  f.adapter.before = async event => {
    if (event.op === 'write') { abandoned = event.path; throw ioError(); }
    if (event.op === 'unlink' && event.path === abandoned) throw ioError(13900012);
  };
  assert.equal((await seeded.store.save(seeded.state, 1)).status, 'ioError');
  assert.ok(abandoned.endsWith('.tmp')); assert.equal((await fs.stat(abandoned)).isFile(), true);
  assert.deepEqual(await f.slots(), before);
  f.adapter.before = null;
  assert.equal((await seeded.store.save(seeded.state, 1)).status, 'saved');
  assert.equal((await fs.stat(abandoned)).isFile(), true);
});

test('save checks ordinary prefix files and separates missing/short content from permission errors', async t => {
  const f = await fixture(t); const store = f.store(); const initial = await store.save(fresh(1, true), -1);
  const value = clone(initial.state); prefix(value, 0, 4);
  const before = await f.slots();
  assert.equal((await store.save(value, 0)).status, 'invalid');
  await fs.writeFile(path.join(f.dir, 'p0.part'), 'abc');
  assert.equal((await store.save(value, 0)).status, 'invalid');
  await fs.unlink(path.join(f.dir, 'p0.part')); await fs.mkdir(path.join(f.dir, 'p0.part'));
  assert.equal((await store.save(value, 0)).status, 'invalid');
  await fs.rmdir(path.join(f.dir, 'p0.part')); await fs.writeFile(path.join(f.dir, 'p0.part'), 'abcdef');
  f.adapter.before = async event => { if (event.op === 'lstat' && event.path.endsWith('.part')) throw ioError(13900012); };
  assert.equal((await store.save(value, 0)).status, 'ioError');
  assert.deepEqual(await f.slots(), before);
  f.adapter.before = null;
  assert.equal((await store.save(value, 0)).status, 'saved');
});

test('load repairs missing, short and nonordinary parts without writing, truncating or inferring completion', async t => {
  const f = await fixture(t); const store = f.store(); const value = fresh(5);
  for (let i = 0; i < 5; i++) prefix(value, i, 4, i === 3);
  await f.parts(value); assert.equal((await store.save(value, -1)).status, 'saved');
  await fs.unlink(path.join(f.dir, 'p0.part'));
  await fs.truncate(path.join(f.dir, 'p1.part'), 2);
  await fs.unlink(path.join(f.dir, 'p2.part')); await fs.mkdir(path.join(f.dir, 'p2.part'));
  await fs.appendFile(path.join(f.dir, 'p3.part'), 'tail');
  await fs.appendFile(path.join(f.dir, 'p4.part'), 'uncommitted');
  const before = await f.slots(); f.adapter.history.length = 0;
  const loaded = await store.load();
  assert.equal(loaded.status, 'loaded'); assert.equal(loaded.repairedParts, 3);
  for (let i = 0; i < 3; i++) assert.deepEqual(plain(loaded.state.parts[i]), {
    chunkId: 'c' + i, downloaded: 0, complete: false, fileName: ''
  });
  assert.equal(loaded.state.parts[3].downloaded, 4); assert.equal(loaded.state.parts[3].complete, true);
  assert.equal(loaded.state.parts[4].downloaded, 4); assert.equal(loaded.state.parts[4].complete, false);
  assert.deepEqual(await f.slots(), before);
  assert.equal((await fs.stat(path.join(f.dir, 'p4.part'))).size, 15);
  assert.equal(f.adapter.history.some(event => ['write', 'unlink', 'rename', 'mkdir', 'fsync'].includes(event.op)), false);
});

test('verified empty resources require an actual ordinary file and unknown part IO does not fabricate repairs', async t => {
  const f = await fixture(t); const store = f.store(); const value = fresh(); prefix(value, 0, 0, true);
  assert.equal((await store.save(value, -1)).status, 'invalid');
  await f.parts(value); assert.equal((await store.save(value, -1)).status, 'saved');
  assert.equal((await store.load()).state.parts[0].complete, true);
  f.adapter.before = async event => { if (event.op === 'lstat' && event.path.endsWith('.part')) throw ioError(); };
  assert.deepEqual(plain(await store.load()), { status: 'ioError', state: null, repairedParts: 0 });
});

test('pre-existing staging collision is neither opened nor cleaned', async t => {
  const f = await fixture(t); const seeded = await seedTwo(f);
  const uuid = 'ffffffff-ffff-4fff-8fff-ffffffffffff';
  const collision = path.join(f.dir, 'adaptive-state.' + uuid + '.tmp');
  await fs.writeFile(collision, 'unrelated preserved bytes');
  const before = await f.slots(); f.uuids.push(uuid); f.adapter.history.length = 0;
  assert.equal((await seeded.store.save(seeded.state, 1)).status, 'ioError');
  assert.equal(await fs.readFile(collision, 'utf8'), 'unrelated preserved bytes');
  assert.deepEqual(await f.slots(), before);
  assert.equal(f.adapter.history.some(event => event.path === collision && ['open', 'unlink', 'write'].includes(event.op)), false);
});

test('cleanup preserves ordinary HTTP state, foreign staging and parts used by the older replica', async t => {
  const f = await fixture(t); const store = f.store(); const old = fresh(); prefix(old, 0, 3, true, 'older.part');
  await f.parts(old);
  const first = await store.save(old, -1); assert.equal(first.status, 'saved');
  const next = clone(first.state); prefix(next, 0, 4, true, 'newer.part');
  await f.parts(next);
  await fs.writeFile(path.join(f.dir, 'chunks.json.1'), 'ordinary HTTP data');
  await fs.writeFile(path.join(f.dir, 'adaptive-state.foreign.tmp'), 'foreign');
  assert.equal((await store.save(next, 0)).status, 'saved');
  await fs.writeFile(f.slot(2), 'broken newer slot');
  const recovered = await store.load();
  assert.equal(recovered.state.generation, 0); assert.equal(recovered.state.parts[0].fileName, 'older.part');
  assert.equal(await fs.readFile(path.join(f.dir, 'older.part'), 'utf8'), 'aaa');
  assert.equal(await fs.readFile(path.join(f.dir, 'chunks.json.1'), 'utf8'), 'ordinary HTTP data');
  assert.equal(await fs.readFile(path.join(f.dir, 'adaptive-state.foreign.tmp'), 'utf8'), 'foreign');
});

test('caller changes after save invocation cannot alter the already captured checkpoint', async t => {
  const f = await fixture(t); const store = f.store(); const entered = f.gate(); const resume = f.gate();
  let once = false;
  f.adapter.before = async event => {
    if (!once && event.op === 'lstat') { once = true; entered.resolve(); await resume.promise; }
  };
  const input = fresh(2); const expected = plain(input);
  const pending = store.save(input, -1);
  input.generation = 99; input.plan.chunks[0].url = 'https://changed.example/private.ts';
  input.parts.reverse(); input.parts[0].downloaded = 999;
  await within(entered.promise, 'captured save IO'); resume.resolve();
  const saved = await pending;
  assert.equal(saved.status, 'saved'); assert.deepEqual(plain(saved.state), expected);
  assert.deepEqual(plain((await store.load()).state), expected);
});

test('stale expected generation, input-generation mismatch and plan changes cannot overwrite a checkpoint', async t => {
  const f = await fixture(t); const seeded = await seedTwo(f); const before = await f.slots();
  assert.equal((await seeded.store.save(fresh(), 0)).status, 'conflict');
  assert.equal((await seeded.store.save(seeded.state, 0)).status, 'conflict');
  assert.equal((await seeded.store.save(fresh(), -1)).status, 'conflict');
  const changed = clone(seeded.state); changed.plan.chunks[0].url = 'https://state.example/other.ts';
  assert.equal((await seeded.store.save(changed, 1)).status, 'invalid');
  assert.deepEqual(await f.slots(), before);
});

test('maximum safe generation can be loaded but cannot be incremented', async t => {
  const f = await fixture(t); const value = fresh(); value.generation = Number.MAX_SAFE_INTEGER;
  await f.putSlot(1, value); const store = f.store();
  assert.equal((await store.load()).state.generation, Number.MAX_SAFE_INTEGER);
  const before = await f.slots();
  assert.equal((await store.save(value, Number.MAX_SAFE_INTEGER)).status, 'invalid');
  assert.deepEqual(await f.slots(), before);
});

test('two same-directory instances serialize initial CAS despite normalized path differences', async t => {
  const f = await fixture(t);
  const first = f.store(); const second = f.store(f.base + '/unused/../.');
  const a = first.save(fresh(), -1); const b = second.save(fresh(), -1);
  const outcomes = await Promise.all([a, b]);
  assert.deepEqual(outcomes.map(item => item.status), ['saved', 'conflict']);
  assert.equal((await second.load()).state.generation, 0);
});

test('an old instance rejoins the current queue after idle-map removal instead of using a detached chain', async t => {
  const f = await fixture(t); const old = f.store();
  const initial = await old.save(fresh(), -1); await old.drain();
  const newer = f.store(); const entered = f.gate(); const resume = f.gate(); let arrivals = 0;
  f.adapter.before = async event => {
    if (event.op === 'lstat' && event.path === f.dir) {
      arrivals++;
      if (arrivals === 1) { entered.resolve(); await resume.promise; }
    }
  };
  const first = newer.save(initial.state, 0);
  await within(entered.promise, 'current queue operation');
  const second = old.save(initial.state, 0);
  await Promise.resolve(); assert.equal(arrivals, 1, 'the old instance must wait on the current shared queue');
  resume.resolve();
  assert.equal((await first).status, 'saved'); assert.equal((await second).status, 'conflict');
});

test('third operation is busy before touching the large snapshot and a released queue is reusable', async t => {
  const f = await fixture(t); const first = f.store(); const second = f.store();
  const entered = f.gate(); const resume = f.gate(); let paused = false;
  f.adapter.before = async event => {
    if (!paused && event.op === 'lstat') { paused = true; entered.resolve(); await resume.promise; }
  };
  const a = first.save(fresh(), -1); const b = second.load();
  let planReads = 0; const overflow = fresh();
  Object.defineProperty(overflow, 'plan', { enumerable: true, get() { planReads++; throw new Error('must not allocate'); } });
  const beforeCaptures = f.metrics.captures;
  assert.equal((await f.store().save(overflow, -1)).status, 'busy');
  assert.equal((await first.load()).status, 'busy');
  assert.equal(planReads, 0); assert.equal(f.metrics.captures, beforeCaptures);
  await within(entered.promise, 'queue capacity gate'); resume.resolve();
  assert.equal((await a).status, 'saved'); assert.equal((await b).status, 'loaded');
  assert.equal((await f.store().load()).status, 'loaded');
});

test('drain is an instance barrier without admission and does not wait for another queued instance', async t => {
  const f = await fixture(t); const old = f.store(); const next = f.store();
  const firstEntered = f.gate(); const firstResume = f.gate(); const nextEntered = f.gate(); const nextResume = f.gate();
  let phase = 0;
  f.adapter.before = async event => {
    if (event.op === 'lstat' && event.path === f.dir) {
      if (phase === 0) { phase = 1; firstEntered.resolve(); await firstResume.promise; }
      else if (phase === 2) { phase = 3; nextEntered.resolve(); await nextResume.promise; }
    }
  };
  const saving = old.save(fresh(), -1); await within(firstEntered.promise, 'first instance pause');
  const loading = next.load(); const barrier = old.drain();
  assert.equal((await next.load()).status, 'busy');
  // The first save's second owner-directory lstat must run normally; arm the next instance after commit.
  f.adapter.after = async (event, value) => { if (event.op === 'rename') phase = 2; return value; };
  firstResume.resolve();
  assert.equal((await saving).status, 'saved');
  await within(nextEntered.promise, 'second instance pause');
  await within(barrier, 'old instance barrier must exclude later instance');
  nextResume.resolve(); assert.equal((await loading).status, 'loaded');
});

test('disposed queued work performs no IO and cannot overwrite a newer instance', async t => {
  const f = await fixture(t); const old = f.store(); const cancelled = f.store();
  const entered = f.gate(); const resume = f.gate(); let once = false;
  f.adapter.before = async event => {
    if (!once && event.op === 'lstat') { once = true; entered.resolve(); await resume.promise; }
  };
  const first = old.save(fresh(), -1); await within(entered.promise, 'running save');
  const second = cancelled.save(fresh(), -1); cancelled.dispose();
  resume.resolve(); assert.equal((await first).status, 'saved');
  const count = f.adapter.history.length;
  assert.equal((await second).status, 'disposed'); await cancelled.drain();
  assert.equal(f.adapter.history.length, count);
  const next = f.store(); const loaded = await next.load();
  assert.equal((await next.save(loaded.state, 0)).status, 'saved');
});

test('dispose while every save IO call is pending preserves the prior latest slot until rename', async t => {
  const baseline = await fixture(t); const baselineSeed = await seedTwo(baseline);
  assert.equal((await baselineSeed.store.save(baselineSeed.state, 1)).status, 'saved');
  const expectedEvents = baseline.adapter.history.map(event => event.op);
  assert.equal(expectedEvents[expectedEvents.length - 1], 'rename');
  for (let index = 0; index < expectedEvents.length; index++) {
    const f = await fixture(t); const seeded = await seedTwo(f); const before = await f.slots();
    let seen = 0; let triggered = false;
    f.adapter.before = async event => {
      if (seen++ === index) {
        assert.equal(event.op, expectedEvents[index]); triggered = true; seeded.store.dispose();
      }
    };
    const outcome = await seeded.store.save(seeded.state, 1);
    assert.equal(triggered, true, 'boundary ' + index + ' ' + expectedEvents[index]);
    assert.equal(outcome.status, expectedEvents[index] === 'rename' ? 'saved' : 'disposed',
      'boundary ' + index + ' ' + expectedEvents[index]);
    await seeded.store.drain(); f.adapter.before = null;
    assert.equal((await f.slots())[1], before[1], 'prior latest slot must remain at every boundary');
    assert.equal(f.adapter.handles.size, 0);
    assert.equal((await fs.readdir(f.dir)).some(name => name.endsWith('.tmp')), false);
  }
});

test('dispose during an already entered rename still returns the committed generation', async t => {
  const f = await fixture(t); const seeded = await seedTwo(f);
  f.adapter.before = async event => { if (event.op === 'rename') seeded.store.dispose(); };
  const value = await seeded.store.save(seeded.state, 1);
  assert.equal(value.status, 'saved'); assert.equal(value.state.generation, 2);
  f.adapter.before = null;
  assert.equal((await f.store().load()).state.generation, 2);
});

test('disposal while first-save directory creation is pending leaves no published state', async t => {
  const f = await fixture(t); const store = f.store();
  f.adapter.before = async event => { if (event.op === 'mkdir') store.dispose(); };
  assert.equal((await store.save(fresh(), -1)).status, 'disposed'); await store.drain();
  f.adapter.before = null;
  assert.deepEqual(await f.slots(), [null, null]);
  assert.equal((await f.store().load()).status, 'empty');
});

test('disposal during each load IO boundary is read-only and drains owned file handles', async t => {
  const baseline = await fixture(t); const state = fresh(2);
  prefix(state, 0, 3); prefix(state, 1, 3);
  await baseline.parts(state); await baseline.putSlot(1, state);
  assert.equal((await baseline.store().load()).status, 'loaded');
  const events = baseline.adapter.history.map(event => event.op);
  for (let index = 0; index < events.length; index++) {
    const f = await fixture(t); await f.parts(state); await f.putSlot(1, state);
    const store = f.store(); const before = await f.slots(); let seen = 0; let triggered = false;
    f.adapter.before = async event => {
      if (seen++ === index) { assert.equal(event.op, events[index]); triggered = true; store.dispose(); }
    };
    assert.equal((await store.load()).status, 'disposed', 'load boundary ' + index + ' ' + events[index]);
    assert.equal(triggered, true); await store.drain(); f.adapter.before = null;
    assert.deepEqual(await f.slots(), before);
    assert.equal(f.adapter.handles.size, 0);
    assert.equal(f.adapter.history.some(event => ['write', 'unlink', 'rename', 'mkdir', 'fsync'].includes(event.op)), false);
  }
});

test('old disposal during staging cleanup does not cancel a new instance queued for recovery', async t => {
  const f = await fixture(t); const seeded = await seedTwo(f); const entered = f.gate(); const resume = f.gate();
  f.adapter.after = async (event, value) => {
    if (event.op === 'write') { seeded.store.dispose(); entered.resolve(); await resume.promise; }
    return value;
  };
  const saving = seeded.store.save(seeded.state, 1);
  await within(entered.promise, 'old stage write');
  const next = f.store(); const loading = next.load();
  resume.resolve(); assert.equal((await saving).status, 'disposed'); await seeded.store.drain();
  f.adapter.after = null;
  const loaded = await loading; assert.equal(loaded.state.generation, 1);
  assert.equal((await next.save(loaded.state, 1)).status, 'saved');
});

test('part inspection is streamed with at most 16 outstanding stats and drain waits for all probes', async t => {
  const f = await fixture(t); const store = f.store(); const state = fresh(48);
  for (let i = 0; i < state.parts.length; i++) prefix(state, i, 1, true);
  await f.parts(state);
  const entered = f.gate(); const resume = f.gate();
  let active = 0; let maximum = 0; let probes = 0;
  f.adapter.before = async event => {
    if (event.op === 'lstat' && event.path.endsWith('.part')) {
      active++; probes++; maximum = Math.max(maximum, active);
      if (probes === 16) entered.resolve();
      await resume.promise;
    }
  };
  f.adapter.after = async (event, value) => {
    if (event.op === 'lstat' && event.path.endsWith('.part')) active--;
    return value;
  };
  const pending = store.save(state, -1); await within(entered.promise, '16 part probes');
  assert.equal(probes, 16); assert.equal(maximum, 16);
  store.dispose(); let drained = false; const barrier = store.drain().then(() => { drained = true; });
  await Promise.resolve(); assert.equal(drained, false);
  resume.resolve(); assert.equal((await pending).status, 'disposed'); await barrier;
  assert.equal(active, 0); assert.equal(probes, 16);
});

test('non-directory owner and nonordinary state slot are rejected without arbitrary path mutation', async t => {
  const f = await fixture(t); await fs.writeFile(f.dir, 'not a directory'); const store = f.store();
  assert.equal((await store.load()).status, 'invalid');
  assert.equal((await store.save(fresh(), -1)).status, 'invalid');
  assert.equal(await fs.readFile(f.dir, 'utf8'), 'not a directory');
  await fs.unlink(f.dir); await fs.mkdir(f.dir); await fs.mkdir(f.slot(1));
  assert.equal((await store.load()).status, 'invalid');
  assert.equal((await store.save(fresh(), -1)).status, 'invalid');
  assert.equal((await fs.stat(f.slot(1))).isDirectory(), true);
});

test('error results contain only fixed classifications and no filesystem or source credentials', async t => {
  const f = await fixture(t); const store = f.store();
  f.adapter.before = async () => {
    const error = ioError(); error.message = 'private-path https://user:password@host/?token=hidden';
    throw error;
  };
  const value = await store.save(fresh(), -1);
  assert.deepEqual(plain(value), { status: 'ioError', state: null, repairedParts: 0 });
  assert.equal(JSON.stringify(value).includes('private-path'), false);
  assert.equal(JSON.stringify(value).includes('token=hidden'), false);
});

test('maximum canonical snapshot capture remains bounded and records its synchronous CPU cost', async t => {
  const f = await fixture(t);
  const media = new model.HlsPlaylist();
  for (let i = 0; i < parser.HLS_MAX_SEGMENTS; i++) {
    const item = new model.HlsMediaSegment(); item.url = 'https://state.example/s.ts'; item.sequence = i;
    media.segments.push(item);
  }
  const built = plan.buildHlsPlan(PRIMARY, media, 'https://state.example/audio.m3u8', media);
  assert.ok(built); assert.equal(built.chunks.length, 20000);
  let remaining = plan.ADAPTIVE_MAX_PLAN_CHARS - JSON.stringify(built).length;
  for (const chunk of built.chunks) {
    const count = Math.min(remaining, model.HLS_MAX_URL_CHARS - chunk.url.length);
    chunk.url = chunk.url.slice(0, -4) + 'x'.repeat(count) + 's.ts';
    remaining -= count; if (remaining === 0) break;
  }
  assert.equal(remaining, 0); assert.equal(JSON.stringify(built).length, plan.ADAPTIVE_MAX_PLAN_CHARS);
  const value = codec.newAdaptiveState(ID, built); assert.ok(value);
  const each = Math.floor(Number.MAX_SAFE_INTEGER / value.parts.length);
  for (let i = 0; i < value.parts.length; i++) {
    prefix(value, i, each, i % 2 === 0, 'p' + String(i).padStart(5, '0') + 'x'.repeat(114) + '.part');
  }
  const chars = codec.encodeAdaptiveState(value).length;
  const store = f.store(); const start = performance.now();
  const pending = store.save(value, -1);
  const captureMs = performance.now() - start;
  store.dispose();
  assert.equal((await pending).status, 'disposed'); await store.drain();
  assert.equal(f.adapter.history.length, 0, 'capture completed synchronously, then disposal stopped queued IO');
  assert.ok(chars <= 12528724); assert.equal(f.metrics.captures, 1);
  t.diagnostic(JSON.stringify({ chunks: 20000, planChars: plan.ADAPTIVE_MAX_PLAN_CHARS,
    stateChars: chars, synchronousCaptureMs: Math.round(captureMs * 100) / 100,
    scope: 'host CPU observation only; no target heartbeat or IO timing claim' }));
});
