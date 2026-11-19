'use strict';
// End-to-end acceptance source for the HLS/DASH business shell (2026-11-06).
// Generates REAL playable media with ffmpeg (H.264 320x180@25 testsrc2 + AAC 440 Hz sine, 20 s)
// into --dir once, then serves it with Range support:
//   /hls/master.m3u8          master: variant A = muxed TS; variant B = video-only TS + AUDIO rendition
//   /hls/muxed/index.m3u8     media playlist (muxed TS, 2 s segments)
//   /hls/video/index.m3u8     video-only TS      /hls/audio/index.m3u8  audio-only TS
//   /dash/manifest.mpd        DASH (fMP4 init + m4s, separate video/audio adaptation sets)
//   /slow/...                 same tree, every response throttled (pause/kill/resume window)
//   /__log                    JSON request log (method, path, range) ; /__reset clears it
// Usage: node docs/probe/E2E-adaptive-host.cjs --dir <work dir> [--host 127.0.0.1] [--port 18800]
// Device access: hdc rport tcp:18800 tcp:18800, then http://127.0.0.1:18800/...
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { parseArgs } = require('node:util');

const { values } = parseArgs({ options: {
  dir: { type: 'string' }, host: { type: 'string', default: '127.0.0.1' }, port: { type: 'string', default: '18800' },
  'slow-bps': { type: 'string', default: '40000' } } });
if (!values.dir) { console.error('--dir required'); process.exit(2); }
const dir = path.resolve(values.dir);
const slowBps = Number(values['slow-bps']);

function ff(args, cwd) { execFileSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', ...args], { cwd, stdio: 'inherit' }); }
const SRC = ['-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=25', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=44100',
  '-t', '20'];
const VENC = ['-c:v', 'libx264', '-preset', 'veryfast', '-g', '50', '-keyint_min', '50', '-sc_threshold', '0', '-pix_fmt', 'yuv420p'];
const AENC = ['-c:a', 'aac', '-b:a', '96k', '-ac', '2'];

function generate() {
  const marker = path.join(dir, '.generated');
  if (fs.existsSync(marker)) return;
  for (const sub of ['hls/muxed', 'hls/video', 'hls/audio', 'dash']) fs.mkdirSync(path.join(dir, sub), { recursive: true });
  // Reference source (what every download must reproduce when decoded)
  ff([...SRC, ...VENC, ...AENC, 'source.mp4'], dir);
  const hls = ['-f', 'hls', '-hls_time', '2', '-hls_playlist_type', 'vod', '-hls_segment_filename'];
  ff(['-i', 'source.mp4', '-c', 'copy', ...hls, 'hls/muxed/seg%03d.ts', 'hls/muxed/index.m3u8'], dir);
  ff(['-i', 'source.mp4', '-map', '0:v', '-c', 'copy', ...hls, 'hls/video/seg%03d.ts', 'hls/video/index.m3u8'], dir);
  ff(['-i', 'source.mp4', '-map', '0:a', '-c', 'copy', ...hls, 'hls/audio/seg%03d.ts', 'hls/audio/index.m3u8'], dir);
  fs.writeFileSync(path.join(dir, 'hls/master.m3u8'), [
    '#EXTM3U',
    '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",LANGUAGE="en",DEFAULT=YES,URI="audio/index.m3u8"',
    '#EXT-X-STREAM-INF:BANDWIDTH=400000,RESOLUTION=320x180,CODECS="avc1.64000d,mp4a.40.2"',
    'muxed/index.m3u8',
    '#EXT-X-STREAM-INF:BANDWIDTH=380000,RESOLUTION=320x180,CODECS="avc1.64000d,mp4a.40.2",AUDIO="aud"',
    'video/index.m3u8', ''].join('\n'));
  ff(['-i', '../source.mp4', '-map', '0:v', '-map', '0:a', '-c', 'copy', '-f', 'dash', '-seg_duration', '2',
    '-use_template', '1', '-use_timeline', '0', '-adaptation_sets', 'id=0,streams=v id=1,streams=a',
    '-init_seg_name', 'init-$RepresentationID$.m4s', '-media_seg_name', 'chunk-$RepresentationID$-$Number%05d$.m4s',
    'manifest.mpd'], path.join(dir, 'dash'));
  fs.writeFileSync(marker, new Date().toISOString());
}

const TYPES = { '.m3u8': 'application/vnd.apple.mpegurl', '.ts': 'video/mp2t', '.mpd': 'application/dash+xml',
  '.m4s': 'video/iso.segment', '.mp4': 'video/mp4' };
const log = [];

function serve(req, res) {
  const url = new URL(req.url, 'http://x');
  if (url.pathname === '/__log') { res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(log)); return; }
  if (url.pathname === '/__reset') { log.length = 0; res.writeHead(204); res.end(); return; }
  let rel = decodeURIComponent(url.pathname);
  const slow = rel.startsWith('/slow/');
  if (slow) rel = rel.substring(5);
  const file = path.join(dir, rel);
  log.push({ t: Date.now(), method: req.method, path: url.pathname, range: req.headers.range || '', cookie: req.headers.cookie || '' });
  if (!file.startsWith(dir) || !fs.existsSync(file) || !fs.statSync(file).isFile()) { res.writeHead(404); res.end(); return; }
  const size = fs.statSync(file).size;
  const type = TYPES[path.extname(file)] || 'application/octet-stream';
  let start = 0, end = size - 1, status = 200;
  const m = /^bytes=(\d+)-(\d*)$/.exec(req.headers.range || '');
  if (m) {
    start = Number(m[1]); end = m[2] ? Math.min(Number(m[2]), size - 1) : size - 1;
    if (start >= size || start > end) { res.writeHead(416, { 'Content-Range': 'bytes */' + size }); res.end(); return; }
    status = 206;
  }
  const headers = { 'Content-Type': type, 'Content-Length': String(end - start + 1), 'Accept-Ranges': 'bytes' };
  if (status === 206) headers['Content-Range'] = `bytes ${start}-${end}/${size}`;
  res.writeHead(status, headers);
  if (req.method === 'HEAD') { res.end(); return; }
  const stream = fs.createReadStream(file, { start, end, highWaterMark: slow ? 4096 : 65536 });
  if (!slow) { stream.pipe(res); return; }
  // throttle: pause after each chunk for chunk/slowBps seconds
  stream.on('data', chunk => {
    stream.pause();
    res.write(chunk, () => setTimeout(() => stream.resume(), Math.ceil(chunk.length * 1000 / slowBps)));
  });
  stream.on('end', () => res.end());
  stream.on('error', () => res.destroy());
  res.on('close', () => stream.destroy());
}

generate();
http.createServer(serve).listen(Number(values.port), values.host, () => {
  console.log(`E2E adaptive host on http://${values.host}:${values.port} dir=${dir}`);
});
