'use strict';
// SDK boundaries only: actual Node sockets and files, never an alternate E3 implementation.
const assert = require('node:assert/strict');
const http = require('node:http');
const https = require('node:https');
const fs = require('node:fs/promises');
const nativeFs = require('node:fs');
const path = require('node:path');
const { performance } = require('node:perf_hooks');

function sdkError(code = 1007900007) { return Object.assign(new Error('Private SDK detail must not escape'), { code }); }
function fileError(error) {
  if (typeof error?.code === 'number') return error;
  return sdkError(({ ENOENT: 13900002, EIO: 13900005, EBADF: 13900008, EACCES: 13900012,
    EPERM: 13900012, EEXIST: 13900015, ENOTDIR: 13900018, EISDIR: 13900019, ENOSPC: 13900025 })[error?.code] || 13900042);
}
function bytes(value) { const b = Buffer.from(value); return b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength); }

class NodeFileAdapter {
  constructor(root) {
    this.root = path.resolve(root); this.handles = new Map(); this.events = [];
    this.before = null; this.after = null; this.settled = null; this.readLimit = Infinity; this.writeLimit = Infinity;
    this.pending = 0; this.peakPending = 0;
    this.api = {
      OpenMode: { READ_ONLY: 0, READ_WRITE: 2, CREATE: 64, NOFOLLOW: 262144 },
      lstat: target => this.invoke('lstat', { path: target }, () => fs.lstat(target)),
      stat: fd => this.invoke('stat', { fd, path: this.entry(fd).path }, () => this.entry(fd).file.stat()),
      open: (target, mode) => this.invoke('open', { path: target, mode }, async () => {
        this.owned(target);
        let flags = (mode & 2) ? nativeFs.constants.O_RDWR : nativeFs.constants.O_RDONLY;
        if (mode & 64) flags |= nativeFs.constants.O_CREAT;
        if (mode & 262144) flags |= nativeFs.constants.O_NOFOLLOW || 0;
        const file = await fs.open(target, flags); this.handles.set(file.fd, { file, path: path.resolve(target) });
        return { fd: file.fd };
      }),
      read: (fd, buffer, options) => this.invoke('read', { fd, path: this.entry(fd).path,
        requested: options?.length ?? buffer.byteLength, bufferLength: buffer.byteLength }, async () => {
        assert.equal(options?.offset, undefined, 'SDK offsets are relative: sequential reads omit them');
        return (await this.entry(fd).file.read(Buffer.from(buffer), 0,
          Math.min(options?.length ?? buffer.byteLength, this.readLimit), null)).bytesRead;
      }),
      write: (fd, buffer, options) => this.invoke('write', { fd, path: this.entry(fd).path,
        requested: buffer.byteLength }, async () => {
        assert.equal(options?.offset, undefined, 'SDK offsets are relative: sequential writes omit them');
        return (await this.entry(fd).file.write(Buffer.from(buffer), 0,
          Math.min(buffer.byteLength, this.writeLimit), null)).bytesWritten;
      }),
      truncate: (fd, length) => this.invoke('truncate', { fd, path: this.entry(fd).path, length }, () => this.entry(fd).file.truncate(length)),
      fsync: fd => this.invoke('fsync', { fd, path: this.entry(fd).path }, () => this.entry(fd).file.sync()),
      close: file => {
        const fd = typeof file === 'number' ? file : file.fd;
        return this.invoke('close', { fd, path: this.entry(fd).path }, async () => {
          await this.entry(fd).file.close(); this.handles.delete(fd);
        });
      },
      unlink: target => this.invoke('unlink', { path: target }, () => { this.owned(target); return fs.unlink(target); })
    };
  }
  owned(target) { assert.ok(path.resolve(target).toLowerCase().startsWith(this.root.toLowerCase() + path.sep), 'fixture owns all IO'); }
  entry(fd) { const entry = this.handles.get(fd); if (!entry) throw sdkError(13900008); return entry; }
  async invoke(op, fields, action) {
    const event = { index: this.events.length, op, ...fields, ok: false }; this.events.push(event);
    this.pending++; this.peakPending = Math.max(this.peakPending, this.pending);
    try {
      if (this.before) await this.before(event);
      const result = await action(); event.ok = true; if (typeof result === 'number') event.count = result;
      if (this.after) await this.after(event, result);
      return result;
    } catch (error) { const mapped = fileError(error); event.errorCode = mapped.code; throw mapped; }
    finally { try { if (this.settled) await this.settled(event); } finally { this.pending--; } }
  }
  async cleanup() {
    for (const entry of this.handles.values()) await entry.file.close().catch(() => {});
    this.handles.clear();
  }
}

function headersOf(raw) {
  const result = Object.create(null);
  for (let i = 0; i < raw.length; i += 2) {
    const key = raw[i];
    if (result[key] === undefined) result[key] = raw[i + 1];
    else result[key] = Array.isArray(result[key]) ? result[key].concat(raw[i + 1]) : [result[key], raw[i + 1]];
  }
  return result;
}

class NodeRcpAdapter {
  constructor(options = {}) {
    this.options = options; this.records = []; this.queues = []; this.requestSequence = 0;
    const adapter = this;
    this.api = {
      NetworkOutputQueue: class {
        constructor(maxSize, receiving) {
          if (adapter.options.queueThrow) throw sdkError(1007900990);
          assert.equal(maxSize, 1048576); assert.deepEqual(JSON.parse(JSON.stringify(receiving)), { kind: 'cacheSize', size: 65536 });
          // Device: receiving pauses at the cacheSize threshold, below the physical capacity (late pause, overshoot).
          this.buffer = Buffer.alloc(maxSize); this.capacity = maxSize; this.pauseAt = receiving.size; this.start = 0; this.size = 0;
          this.peak = 0; this.reads = 0; this.afterRead = null; adapter.queues.push(this);
        }
        getStoredBytes() { return adapter.options.badStored ?? this.size; }
        push(chunk) {
          assert.ok(chunk.length <= this.capacity - this.size);
          const end = (this.start + this.size) % this.capacity;
          const first = Math.min(chunk.length, this.capacity - end);
          chunk.copy(this.buffer, end, 0, first); if (first < chunk.length) chunk.copy(this.buffer, 0, first);
          this.size += chunk.length; this.peak = Math.max(this.peak, this.size);
        }
        readInto(target) {
          if (adapter.options.readThrow) throw sdkError(1007900990);
          assert.ok(target instanceof ArrayBuffer && target.byteLength > 0 && target.byteLength <= 32768);
          const count = Math.min(target.byteLength, this.size), output = Buffer.from(target, 0, count);
          const first = Math.min(count, this.capacity - this.start);
          this.buffer.copy(output, 0, this.start, this.start + first);
          if (first < count) this.buffer.copy(output, first, 0, count - first);
          this.start = (this.start + count) % this.capacity; this.size -= count; this.reads++;
          if (this.afterRead) queueMicrotask(this.afterRead);
          if (adapter.options.afterPull) adapter.options.afterPull(this, count);
          return count;
        }
        // Production must not call read(): on device it can dequeue bytes and then reject (data loss).
        read() { throw new Error('NetworkOutputQueue.read must not be used'); }
        readLegacy(max) {
          if (adapter.options.readThrow) throw sdkError(1007900990);
          assert.ok(max > 0 && max <= 32768);
          const count = Math.min(max, this.size), output = Buffer.alloc(count);
          const first = Math.min(count, this.capacity - this.start);
          this.buffer.copy(output, 0, this.start, this.start + first);
          if (first < count) this.buffer.copy(output, first, 0, count - first);
          this.start = (this.start + count) % this.capacity; this.size -= count; this.reads++;
          if (this.afterRead) queueMicrotask(this.afterRead);
          if (adapter.options.afterPull) adapter.options.afterPull(this, count);
          return bytes(output);
        }
      },
      Request: class {
        constructor(input, method, headers) {
          if (adapter.options.requestThrow) throw sdkError(401);
          this.url = new URL(input); this.method = method; this.headers = headers;
          this.id = 'e3_' + (++adapter.requestSequence);
        }
      },
      createSession(configuration) { return adapter.createSession(configuration); }
    };
  }
  createSession(configuration) {
    if (this.options.createThrow) throw sdkError(this.options.createThrow);
    assert.equal(configuration.requestConfiguration.transfer.autoRedirect, false);
    assert.equal(configuration.requestConfiguration.tracing.verbose, false);
    assert.equal(configuration.requestConfiguration.tracing.httpEventsHandler.onDataReceive, undefined);
    assert.equal(configuration.requestConfiguration.transfer.timeout.inactivityMs, undefined);
    assert.equal(configuration.cookieRepository, undefined);
    const record = { index: this.records.length, closeCalls: 0, cancelCalls: 0, closed: false,
      fetchSettled: false, timeline: [], deliveredBytes: 0, pauses: 0, resumes: 0, configuration };
    this.records.push(record);
    let outgoing, incoming, rejectFetch, resolveFetch, transferTimer, options = {}, queue, handlers;
    const timers = new Set();
    const later = (callback, delay) => { const timer = setTimeout(() => { timers.delete(timer); callback(); }, delay); timers.add(timer); return timer; };
    const event = name => record.timeline.push({ name, at: performance.now() });
    const settle = (success, value, force = false) => {
      if (!resolveFetch || !rejectFetch) return;
      if (record.fetchSettled || (options.neverSettle && !force)) return;
      record.fetchSettled = true; clearTimeout(transferTimer); event(success ? 'resolve' : 'reject');
      if (success) resolveFetch(value); else rejectFetch(value);
    };
    const releaseSocket = () => { incoming?.destroy(); outgoing?.destroy(); clearTimeout(transferTimer); };
    record.forceResolve = response => settle(true, response || record.response, true);
    record.forceReject = () => settle(false, sdkError(1007900007), true);
    record.forceClose = () => { releaseSocket(); for (const timer of timers) clearTimeout(timer); timers.clear(); };
    record.emit = (name, ...args) => handlers[name]?.(...args);
    const sendHeaders = () => {
      const h = record.response.headers;
      event('head');
      if (options.informational) for (let i = 0; i < options.informational; i++) {
        handlers.onStatusCodeReceive?.(103, record.request); handlers.onHeaderReceive?.({}, record.request);
      }
      if (options.headerFirst) { handlers.onHeaderReceive?.(h, record.request); handlers.onStatusCodeReceive?.(record.response.statusCode, record.request); }
      else { handlers.onStatusCodeReceive?.(record.response.statusCode, record.request); handlers.onHeaderReceive?.(h, record.request); }
      if (options.duplicateHead) handlers.onHeaderReceive?.(h, record.request);
    };
    const end = () => {
      event('networkEnd'); record.networkEndedAt = performance.now();
      if (options.lateHeaders) sendHeaders();
      const response = options.finalHeaders ? { ...record.response, headers: options.finalHeaders } : record.response;
      const notifyEnd = () => { if (!options.noEnd) { event('end'); handlers.onDataEnd?.(record.request); } };
      const finishFetch = () => settle(!options.rejectAfterEnd, options.rejectAfterEnd ? sdkError(1007900018) : response);
      if (options.endDelay) { finishFetch(); later(notifyEnd, options.endDelay); }
      else { notifyEnd(); if (options.resolveDelay) later(finishFetch, options.resolveDelay); else finishFetch(); }
    };
    const pump = () => {
      if (!incoming || record.closed) return;
      while (queue.size < queue.pauseAt && incoming.readableLength > 0) {
        const count = Math.min(queue.pauseAt - queue.size, incoming.readableLength, options.wireQuantum || 32768);
        const chunk = incoming.read(count); if (!chunk) break;
        queue.push(chunk); record.deliveredBytes += chunk.length;
        handlers.onDownloadProgress?.(0, record.deliveredBytes, record.request);
      }
      // Reading zero after the last buffered bytes asks Node to emit its actual end event.
      // Unlike a data listener, bounded manual reads must explicitly make this final demand.
      if (queue.size < queue.pauseAt && incoming.readableLength === 0) incoming.read(0);
      if (queue.size === queue.pauseAt) { incoming.pause(); record.pauses++; }
    };
    return {
      fetch: request => {
        if (this.options.fetchThrow) throw sdkError(401);
        options = typeof this.options.forRequest === 'function' ? this.options.forRequest(request.url, record) || {} : this.options;
        handlers = configuration.requestConfiguration.tracing.httpEventsHandler; queue = request.destination;
        record.request = request; record.url = request.url.toString(); record.startedAt = performance.now(); event('fetch');
        queue.afterRead = () => { if (!record.closed) { record.resumes++; pump(); } };
        return new Promise((resolve, reject) => {
          resolveFetch = resolve; rejectFetch = reject;
          if (this.options.onFetch) this.options.onFetch(record);
          if (options.script) { options.script(record, queue, handlers, settle); return; }
          const transport = request.url.protocol === 'https:' ? https : http;
          outgoing = transport.request(request.url, { method: request.method, headers: request.headers, agent: false,
            highWaterMark: 16384 }, response => {
            incoming = response;
            record.response = { request, statusCode: response.statusCode,
              headers: options.headers || headersOf(response.rawHeaders) };
            event('networkHead'); if (!options.lateHeaders && !options.noHeaders) sendHeaders();
            if (record.closed) { response.destroy(); return; }
            response.on('readable', pump);
            response.on('end', end);
            response.on('aborted', () => settle(false, sdkError(1007900018)));
            response.on('error', () => settle(false, sdkError(1007900007)));
            pump();
          });
          outgoing.on('error', () => settle(false, sdkError(1007900007)));
          transferTimer = setTimeout(() => { settle(false, sdkError(1007900028)); releaseSocket(); },
            configuration.requestConfiguration.transfer.timeout.transferMs);
          outgoing.end();
        });
      },
      cancel: () => {
        record.cancelCalls++; if (options.cancelThrow || this.options.cancelThrow) throw sdkError(401);
        settle(false, sdkError(1007900992)); releaseSocket();
      },
      close: () => {
        record.closeCalls++; releaseSocket();
        if (options.closeThrow || this.options.closeThrow) throw sdkError(1007900993);
        record.closed = true; queue && (queue.afterRead = null);
        settle(false, sdkError(1007900993));
      }
    };
  }
  cleanup() { for (const record of this.records) record.forceClose(); }
}

module.exports = { NodeFileAdapter, NodeRcpAdapter, bytes, sdkError };
