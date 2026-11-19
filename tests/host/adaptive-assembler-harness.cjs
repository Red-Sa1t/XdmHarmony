'use strict';
// Actual production B/E2/F/media queue; only SDK boundaries adapt to isolated real host files.
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const nativeFs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const { loadProduction } = require('./production-loader.cjs');

const SOURCE = path.resolve(__dirname, '../../entry/src/main/ets/core');
const ID = '01234567-89ab-cdef-0123-456789abcdef';
const PRIMARY = 'https://assembly.example/main.m3u8';
const SECONDARY = 'https://assembly.example/audio.m3u8';
const plain = value => JSON.parse(JSON.stringify(value));
const model = loadProduction(path.join(SOURCE, 'adaptive/HlsModel.ets'), {});
const parser = loadProduction(path.join(SOURCE, 'adaptive/HlsParser.ets'), { './HlsModel': model });
const plan = loadProduction(path.join(SOURCE, 'adaptive/AdaptivePlan.ets'), { './DashModel': require('./production-loader.cjs').loadProduction(require('node:path').resolve(__dirname, '../../entry/src/main/ets/core/adaptive/DashModel.ets'), {}, { Error }), 
  './HlsModel': model, './HlsParser': parser
}, { Error });
const codec = loadProduction(path.join(SOURCE, 'adaptive/AdaptiveStateCodec.ets'), { './AdaptivePlan': plan }, { Error });

function ioError(code = 13900005) { return Object.assign(new Error('Injected SDK failure'), { code }); }
function sdkError(error) {
  if (typeof error?.code === 'number') return error;
  const codes = { ENOENT: 13900002, EIO: 13900005, EBADF: 13900008, EACCES: 13900012,
    EPERM: 13900012, EEXIST: 13900015, ENOTDIR: 13900018, EISDIR: 13900019 };
  return ioError(codes[error?.code] || 13900042);
}
function deferred() {
  let resolve; let reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
async function within(promise, label, timeout = 8000) {
  let timer;
  try { return await Promise.race([promise, new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error('Timed out: ' + label)), timeout);
  })]); } finally { clearTimeout(timer); }
}

class FileAdapter {
  constructor(realBase, virtualBase) {
    this.realBase = realBase; this.virtualBase = virtualBase;
    this.history = []; this.handles = new Map(); this.paths = new Map();
    this.before = null; this.after = null; this.shortRead = Infinity; this.shortWrite = Infinity;
    this.pending = 0; this.peakPending = 0; this.peakHandles = 0;
    this.api = {
      OpenMode: { READ_ONLY: 0, WRITE_ONLY: 1, READ_WRITE: 2, CREATE: 64, NOFOLLOW: 262144 },
      lstat: target => this.call('lstat', { path: target }, async () => this.metadata(await fs.lstat(this.real(target)))),
      stat: fd => this.call('stat', { fd, path: this.paths.get(fd) }, async () => this.metadata(await this.handle(fd).stat())),
      open: (target, mode) => this.call('open', { path: target, mode }, async () => {
        let flags = (mode & 2) ? nativeFs.constants.O_RDWR : ((mode & 1) ? nativeFs.constants.O_WRONLY : nativeFs.constants.O_RDONLY);
        if (mode & 64) flags |= nativeFs.constants.O_CREAT;
        if (mode & 262144) flags |= nativeFs.constants.O_NOFOLLOW || 0;
        const handle = await fs.open(this.real(target), flags);
        this.handles.set(handle.fd, handle); this.paths.set(handle.fd, target);
        this.peakHandles = Math.max(this.peakHandles, this.handles.size);
        return { fd: handle.fd };
      }),
      read: (fd, buffer, options) => this.call('read', {
        fd, path: this.paths.get(fd), bytes: buffer.byteLength, length: options?.length ?? buffer.byteLength
      }, async () => {
        assert.equal(options?.offset, undefined, 'SDK filePointer-relative offset is omitted');
        return (await this.handle(fd).read(Buffer.from(buffer), 0,
          Math.min(options?.length ?? buffer.byteLength, this.shortRead), null)).bytesRead;
      }),
      write: (fd, buffer, options) => this.call('write', { fd, path: this.paths.get(fd), bytes: buffer.byteLength }, async () => {
        assert.equal(options?.offset, undefined);
        return (await this.handle(fd).write(Buffer.from(buffer), 0, Math.min(buffer.byteLength, this.shortWrite), null)).bytesWritten;
      }),
      fsync: fd => this.call('fsync', { fd, path: this.paths.get(fd) }, () => this.handle(fd).sync()),
      truncate: (fd, size) => this.call('truncate', { fd, path: this.paths.get(fd), size }, () => this.handle(fd).truncate(size)),
      close: file => {
        const fd = typeof file === 'number' ? file : file.fd;
        return this.call('close', { fd, path: this.paths.get(fd) }, async () => {
          await this.handle(fd).close(); this.handles.delete(fd);
        });
      },
      unlink: target => this.call('unlink', { path: target }, () => fs.unlink(this.real(target)))
    };
  }
  real(target) {
    assert.ok(target === this.virtualBase || target.startsWith(this.virtualBase + '/'), 'only this virtual sandbox is mapped');
    const resolved = path.resolve(this.realBase, '.' + target.substring(this.virtualBase.length));
    assert.ok(resolved === this.realBase || resolved.startsWith(this.realBase + path.sep));
    return resolved;
  }
  handle(fd) { const handle = this.handles.get(fd); if (!handle) throw ioError(13900008); return handle; }
  metadata(stat) { return { size: stat.size, isFile: () => stat.isFile(), isDirectory: () => stat.isDirectory() }; }
  async call(op, fields, action) {
    const event = { op, ...fields, index: this.history.length, nativeStarted: false, nativeCompleted: false };
    this.history.push(event); this.pending++; this.peakPending = Math.max(this.pending, this.peakPending);
    try {
      if (this.before) await this.before(event);
      event.nativeStarted = true;
      let value = await action(); event.nativeCompleted = true;
      if (this.after) { const replacement = await this.after(event, value); if (replacement !== undefined) value = replacement; }
      event.returned = typeof value === 'number' ? value : undefined;
      return value;
    } catch (error) { throw sdkError(error); }
    finally { this.pending--; }
  }
}

async function fixture(t) {
  const temporaryRoot = await fs.realpath(os.tmpdir());
  const realBase = await fs.mkdtemp(path.join(temporaryRoot, 'xdm-assembly-'));
  const virtualBase = '/xdm-assembly-' + crypto.randomUUID();
  const dir = virtualBase + '/' + ID;
  const adapter = new FileAdapter(realBase, virtualBase); await fs.mkdir(adapter.real(dir));
  const gates = []; const assemblers = []; const allowedUncertain = new Set(); const uuids = [];
  const nativeCalls = []; const nativeCancels = []; const allocations = [];
  let nativeRemux = async call => {
    const video = await fs.readFile(adapter.real(call.video)); const audio = await fs.readFile(adapter.real(call.audio));
    const content = Buffer.concat([video, Buffer.from('|'), audio]);
    await fs.writeFile(adapter.real(call.output), content, { flag: 'wx' });
    return { status: 'success', errorCode: 'NONE', nativeCode: 0, phase: 'done', jobId: call.id,
      outputPath: call.output, format: call.format, outputBytes: content.length, durationMs: 1000, warnings: [] };
  };
  let cancelNative = () => false;
  const native = {
    capabilities: () => ({ apiVersion: 1, ffmpegVersion: 'host-adapter', lameVersion: '', abi: 'host',
      remuxMp4: true, remuxMatroska: true, encodeMp3: false, maxActiveJobs: 1 }),
    remux: async (id, video, audio, output, format) => {
      const call = { id, video, audio, output, format }; nativeCalls.push(call); return nativeRemux(call);
    },
    toMp3: async () => { throw new Error('Unexpected MP3 request'); },
    cancel: id => { nativeCancels.push(id); return cancelNative(id); },
    progress: id => ({ jobId: id, found: true, phase: 'mux', processedTimeMs: 200, totalTimeMs: 1000, cancelRequested: false })
  };
  const media = loadProduction(path.join(SOURCE, 'media/MediaProcessorNapi.ets'), { 'libxdm_media.so': { default: native } },
    { Error, setInterval, clearInterval });
  const processor = new media.MediaProcessorNapi(native);
  class TrackedArrayBuffer extends ArrayBuffer {
    constructor(size) { super(size); allocations.push(size); }
    static [Symbol.hasInstance](value) { return value instanceof ArrayBuffer; }
  }
  const attempt = loadProduction(path.join(SOURCE, 'adaptive/AdaptiveAttemptFile.ets'), {
    '@kit.CoreFileKit': { fileIo: adapter.api }, '@kit.BasicServicesKit': {}
  }, { Error, ArrayBuffer: TrackedArrayBuffer });
  const assembly = loadProduction(path.join(SOURCE, 'adaptive/AdaptiveAssembler.ets'), {
    '@kit.CoreFileKit': { fileIo: adapter.api }, '@kit.BasicServicesKit': {},
    '@kit.ArkTS': { util: { generateRandomUUID: () => uuids.length ? uuids.shift() : crypto.randomUUID() } },
    './AdaptivePlan': plan, './AdaptiveStateCodec': codec, './AdaptiveAttemptFile': attempt,
    '../media/MediaProcessorNapi': media
  }, { Error, ArrayBuffer: TrackedArrayBuffer });
  const f = {
    adapter, processor, assembly, attempt, base: virtualBase, realBase, dir, uuids, nativeCalls, nativeCancels, allocations,
    file: name => adapter.real(dir + '/' + name), virtual: name => dir + '/' + name,
    gate: () => { const gate = deferred(); gates.push(gate); return gate; },
    assembler: (id = ID, base = virtualBase) => { const item = new assembly.AdaptiveAssembler(base, id, processor); assemblers.push(item); return item; },
    allowUncertain: target => allowedUncertain.add(target),
    setNative: action => { nativeRemux = action; }, setCancel: action => { cancelNative = action; },
    nativeResult: (call, status = 'success', code = 'NONE', extra = {}) => ({ status, errorCode: code, nativeCode: 0,
      phase: 'done', jobId: call.id, outputPath: status === 'success' ? call.output : '', format: call.format,
      outputBytes: 0, durationMs: -1, warnings: [], ...extra }),
    fromLines: async (first, second, contents) => {
      const a = parser.parseHlsMediaPlaylist('#EXTM3U\n' + first.join('\n'), PRIMARY, (base, ref) => new URL(ref, base).href);
      const b = second === null ? null : parser.parseHlsMediaPlaylist('#EXTM3U\n' + second.join('\n'), SECONDARY, (base, ref) => new URL(ref, base).href);
      const built = plan.buildHlsPlan(PRIMARY, a, b ? SECONDARY : '', b); assert.ok(built);
      const state = codec.newAdaptiveState(ID, built); assert.ok(state); assert.equal(contents.length, state.parts.length);
      for (let i = 0; i < state.parts.length; i++) {
        const content = Buffer.from(contents[i]); const part = state.parts[i];
        part.complete = true; part.downloaded = content.length; part.fileName = 'input-' + i + '.part';
        await fs.writeFile(f.file(part.fileName), content);
      }
      return state;
    },
    complete: async (first, second = null, extensions = ['ts', 'ts']) => {
      const a = first.map((_, i) => 'v' + i + '.' + extensions[0]);
      const b = second === null ? null : second.map((_, i) => 'a' + i + '.' + extensions[1]);
      const contents = [];
      for (let i = 0; i < Math.max(first.length, second?.length || 0); i++) {
        if (i < first.length) contents.push(first[i]);
        if (second && i < second.length) contents.push(second[i]);
      }
      return f.fromLines(a, b, contents);
    }
  };
  t.after(async () => {
    adapter.before = null; adapter.after = null;
    for (const gate of gates) gate.resolve();
    for (const item of assemblers) item.cancel();
    await within(Promise.all(assemblers.map(item => item.drain())), 'fixture assembly drain', 10000);
    processor.dispose();
    const unexpected = [];
    for (const [fd, handle] of adapter.handles) {
      if (!allowedUncertain.has(adapter.paths.get(fd))) unexpected.push(adapter.paths.get(fd));
      // Intentional rejected-close handles are released only by the fixture, after asserted facts.
      try { await handle.close(); } catch {}
    }
    adapter.handles.clear();
    assert.equal(path.resolve(realBase), realBase);
    assert.equal(path.dirname(realBase), temporaryRoot);
    assert.ok(path.basename(realBase).startsWith('xdm-assembly-'));
    assert.equal(await fs.realpath(realBase), realBase);
    await fs.rm(realBase, { recursive: true, force: true });
    assert.deepEqual(unexpected, [], 'no unexpected product-owned handles survive drain');
    assert.equal(adapter.pending, 0);
  });
  return f;
}

function hold(f, predicate, timing = 'before') {
  const entered = f.gate(); const released = f.gate(); let hits = 0;
  f.adapter[timing] = async (event, value) => {
    if (!hits && predicate(event)) { hits++; entered.resolve(event); await released.promise; }
    return value;
  };
  return { entered: within(entered.promise, 'selected actual IO boundary'), release: released.resolve,
    reached: () => assert.equal(hits, 1) };
}

module.exports = { fixture, hold, within, ioError, plain, ID, plan, codec };
