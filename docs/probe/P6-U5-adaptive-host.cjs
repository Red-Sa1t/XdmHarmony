'use strict';
// Fixed-data loopback fixture. No arbitrary file reads, writes, credentials or control routes.
const http = require('node:http');
const TOTAL_BYTES = 524288;
const BLOCK_BYTES = 16384;

function pattern(start, count) {
  const bytes = Buffer.alloc(count);
  for (let i = 0; i < count; i++) bytes[i] = (start + i) % 251;
  return bytes;
}

function selectRange(header) {
  if (!header) return { status: 200, start: 0, end: TOTAL_BYTES - 1 };
  const match = /^bytes=(\d+)-(\d*)$/.exec(header);
  if (!match) return null;
  const start = Number(match[1]); const end = match[2] ? Number(match[2]) : TOTAL_BYTES - 1;
  if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start >= TOTAL_BYTES || start < 0 || end < start) return null;
  return { status: 206, start, end: Math.min(end, TOTAL_BYTES - 1) };
}

async function startAdaptiveFixture(options = {}) {
  const host = options.host ?? '127.0.0.1'; const port = options.port ?? 18766;
  if (typeof host !== 'string' || !host || !Number.isInteger(port) || port < 0 || port > 65535) throw new Error('Invalid fixture address');
  const events = []; const sockets = new Set(); let sequence = 0; let closed = false;
  const server = http.createServer((request, response) => {
    let pathname;
    try { pathname = new URL(request.url, 'http://fixture.invalid').pathname; }
    catch { response.writeHead(400); response.end(); return; }
    if (request.method !== 'GET') { response.writeHead(405, { Allow: 'GET', 'Content-Length': 0 }); response.end(); return; }
    if (pathname === '/health') {
      const body = Buffer.from(JSON.stringify({ fixture: 'P6-U5', bytes: TOTAL_BYTES }));
      response.writeHead(200, { 'Content-Type': 'application/json', 'Content-Length': body.length }); response.end(body); return;
    }
    if (pathname !== '/bytes' && pathname !== '/whole') { response.writeHead(404, { 'Content-Length': 0 }); response.end(); return; }
    const rangeHeader = request.headers.range ?? '';
    const range = pathname === '/whole' ? selectRange('') : selectRange(rangeHeader);
    const event = { sequence: ++sequence, route: pathname, method: request.method,
      requestRange: rangeHeader.slice(0, 160), status: range ? range.status : 416,
      start: range?.start ?? -1, end: range?.end ?? -1, writtenBytes: 0, ended: false, responseClosed: false };
    if (events.length === 256) events.shift(); events.push(event);
    response.once('close', () => { event.responseClosed = true; });
    response.once('finish', () => {
      event.ended = true;
      if (typeof options.onEvent === 'function') { try { options.onEvent({ ...event }); } catch {} }
    });
    if (!range) {
      response.writeHead(416, { 'Content-Range': 'bytes */' + TOTAL_BYTES, 'Content-Length': 0 }); response.end(); return;
    }
    const headers = { 'Content-Type': 'application/octet-stream', 'Content-Length': range.end - range.start + 1,
      'Accept-Ranges': 'bytes', 'Cache-Control': 'no-store' };
    if (range.status === 206) headers['Content-Range'] = 'bytes ' + range.start + '-' + range.end + '/' + TOTAL_BYTES;
    response.writeHead(range.status, headers);
    let offset = range.start;
    const pump = () => {
      if (closed || response.destroyed) return;
      while (offset <= range.end) {
        const block = pattern(offset, Math.min(BLOCK_BYTES, range.end - offset + 1));
        offset += block.length; event.writtenBytes += block.length;
        if (!response.write(block)) { response.once('drain', pump); return; }
      }
      response.end();
    };
    pump();
  });
  server.maxConnections = 8;
  server.on('connection', socket => { sockets.add(socket); socket.once('close', () => sockets.delete(socket)); });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, host, () => { server.off('error', reject); resolve(); });
  });
  const address = server.address();
  const origin = 'http://' + (host.includes(':') ? '[' + host + ']' : host) + ':' + address.port;
  let closing;
  return { origin, events, port: address.port,
    close() {
      if (!closing) {
        closed = true;
        closing = new Promise((resolve, reject) => {
          server.close(error => error ? reject(error) : resolve());
          for (const socket of sockets) socket.destroy();
        });
      }
      return closing;
    }
  };
}

module.exports = { startAdaptiveFixture, TOTAL_BYTES };

if (require.main === module) {
  const args = process.argv.slice(2); const options = {};
  for (let i = 0; i < args.length; i += 2) {
    if (args[i] === '--host' && args[i + 1]) options.host = args[i + 1];
    else if (args[i] === '--port' && /^\d+$/.test(args[i + 1] || '')) options.port = Number(args[i + 1]);
    else { process.stderr.write('Usage: node P6-U5-adaptive-host.cjs [--host ADDRESS] [--port PORT]\n'); process.exitCode = 64; break; }
  }
  if (!process.exitCode) {
    options.onEvent = event => process.stdout.write(JSON.stringify({ response: event }) + '\n');
    startAdaptiveFixture(options).then(fixture => {
      process.stdout.write(JSON.stringify({ fixture: 'P6-U5', origin: fixture.origin, bytes: TOTAL_BYTES }) + '\n');
      const stop = () => { fixture.close().catch(() => { process.exitCode = 1; }); };
      process.once('SIGINT', stop); process.once('SIGTERM', stop);
    }).catch(error => { process.stderr.write('Fixture failed: ' + (error.code || 'UNKNOWN') + '\n'); process.exitCode = 1; });
  }
}
