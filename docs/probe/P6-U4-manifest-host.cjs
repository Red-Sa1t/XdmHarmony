'use strict';
// Fixed, synthetic P6-U4 wire fixtures. No filesystem reads, proxying or raw header echo.
// Usage: node docs/probe/P6-U4-manifest-host.cjs [--host 0.0.0.0] [--port 8794]
const http = require('node:http');
const { isIP } = require('node:net');
const { parseArgs } = require('node:util');

const MANIFEST_TYPE = 'application/vnd.apple.mpegurl; charset=utf-8';
const TEXT_TYPE = 'text/plain; charset=utf-8';
const TOO_LARGE_BYTES = 8 * 1024 * 1024 + 1;
const LARGE_BLOCK = Buffer.alloc(64 * 1024, 0x61);
const SLOW_MS = 1500;
const INVALID_UTF8 = Buffer.from([0x23, 0x45, 0x58, 0x54, 0x4d, 0x33, 0x55, 0x0a, 0xc3, 0x28]);

function manifest(headers) {
  const flag = value => value ? '1' : '0';
  return Buffer.from([
    '#EXTM3U',
    '#PROBE-UNICODE:中文',
    '#PROBE-COOKIE:' + flag(headers.cookie === 'probe=adaptive'),
    '#PROBE-REFERER:' + flag(headers.referer === 'https://probe.invalid/page'),
    '#PROBE-MULTI:' + flag(headers['x-probe'] === 'one, two'),
    '#PROBE-IDENTITY:' + flag(headers['accept-encoding'] === 'identity'),
    '#PROBE-RANGE:' + flag(headers.range === undefined),
    '#EXTINF:1',
    'segment.ts?sig=a%2Fb',
    '#EXT-X-ENDLIST',
    ''
  ].join('\n'), 'utf8');
}

function headersFor(type, length, extra = {}) {
  return { 'Content-Type': type, 'Content-Length': length, 'Cache-Control': 'no-store', ...extra };
}

function send(res, status, body, type = TEXT_TYPE, extra = {}) {
  if (res.destroyed || res.writableEnded) return;
  res.writeHead(status, headersFor(type, body.length, extra));
  res.end(body);
}

function sendTooLarge(res) {
  res.writeHead(200, headersFor(MANIFEST_TYPE, TOO_LARGE_BYTES));
  let sent = 0;
  let active = true;
  const stop = () => { active = false; res.off('drain', pump); };
  function pump() {
    while (active && !res.destroyed && sent < TOO_LARGE_BYTES) {
      const count = Math.min(LARGE_BLOCK.length, TOO_LARGE_BYTES - sent);
      sent += count;
      if (!res.write(LARGE_BLOCK.subarray(0, count))) {
        res.once('drain', pump);
        return;
      }
    }
    if (active && !res.destroyed) { active = false; res.end(); }
  }
  res.once('close', stop);
  res.once('error', stop);
  pump();
}

function createProbeServer() {
  const slowTimers = new Set();
  const server = http.createServer((req, res) => {
    res.on('error', () => res.destroy());
    // Request bodies and query parameters never change fixture bytes or select a file/URL.
    req.resume();
    if (req.method !== 'GET') {
      send(res, 405, Buffer.from('GET required\n'), TEXT_TYPE, { Allow: 'GET' });
      return;
    }
    const route = (req.url || '').split('?', 1)[0];
    if (route === '/direct/list.m3u8' || route === '/final/list.m3u8') {
      send(res, 200, manifest(req.headers), MANIFEST_TYPE);
    } else if (route === '/redirect/start') {
      send(res, 302, Buffer.alloc(0), TEXT_TYPE, {
        Location: '../final/list.m3u8?sig=a%2Fb#display'
      });
    } else if (route === '/invalid-utf8') {
      send(res, 200, INVALID_UTF8, MANIFEST_TYPE);
    } else if (route === '/too-large') {
      sendTooLarge(res);
    } else if (route === '/slow') {
      const body = manifest(req.headers);
      let timer = setTimeout(() => {
        slowTimers.delete(timer);
        timer = null;
        send(res, 200, body, MANIFEST_TYPE);
      }, SLOW_MS);
      slowTimers.add(timer);
      res.once('close', () => {
        if (timer !== null) { clearTimeout(timer); slowTimers.delete(timer); timer = null; }
      });
    } else {
      send(res, 404, Buffer.from('Not found\n'));
    }
  });
  server.on('close', () => {
    for (const timer of slowTimers) clearTimeout(timer);
    slowTimers.clear();
  });
  return server;
}

function main() {
  const usage = 'Usage: node docs/probe/P6-U4-manifest-host.cjs [--host <IP|localhost>] [--port <0..65535>]\n';
  let values;
  try {
    values = parseArgs({ options: {
      host: { type: 'string', default: '127.0.0.1' },
      port: { type: 'string', default: '8794' },
      help: { type: 'boolean', default: false }
    }, strict: true, allowPositionals: false }).values;
    if (values.help) { process.stdout.write(usage); return; }
    if ((!isIP(values.host) && values.host !== 'localhost') || !/^\d+$/.test(values.port) ||
      !Number.isSafeInteger(Number(values.port)) || Number(values.port) > 65535) {
      throw new Error('Invalid probe options');
    }
  } catch (_) {
    process.stderr.write(usage);
    process.exitCode = 2;
    return;
  }
  const server = createProbeServer();
  server.once('error', () => {
    process.stderr.write('P6-U4 manifest source failed to listen.\n');
    process.exitCode = 1;
  });
  let stopping = false;
  const stop = () => {
    if (stopping) return;
    stopping = true;
    server.close();
    server.closeAllConnections();
  };
  process.once('SIGINT', stop);
  process.once('SIGTERM', stop);
  server.listen(Number(values.port), values.host, () => {
    const address = server.address();
    const host = address.family === 'IPv6' ? '[' + address.address + ']' : address.address;
    process.stdout.write('P6-U4 manifest source listening at http://' + host + ':' + address.port + '\n');
  });
}

module.exports = { createProbeServer };
if (require.main === module) main();
