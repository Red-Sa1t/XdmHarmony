// Emulator/device acceptance driver (2026-11-13). Prereqs: E2E-adaptive-host.cjs on 18800 and
// 18810 (--slow-bps 6000), `hdc -t <target> fport tcp:18597 tcp:8597`, `rport tcp:18800/18810`, app running.
// usage (cwd = work dir containing e2e-media/): XDM_T=127.0.0.1:5555 node docs/probe/e2e/e2e-driver.cjs <scenario...>
// scenarios: http hls-ts hls-dual dash killresume pause pubdash pubhls
const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const H = 'D:/Tools/DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe';
const T = ['-t', process.env.XDM_T || '127.0.0.1:5555'];
const DIR = __dirname;
// Work dir holds the generated media (E2E-adaptive-host.cjs --dir) and pulled outputs.
const WORK = process.env.XDM_E2E_WORK || process.cwd();
const MEDIA = path.join(WORK, 'e2e-media');
const OUT = path.join(WORK, 'out');
fs.mkdirSync(OUT, { recursive: true });
const hdc = a => execFileSync(H, T.concat(a)).toString();
const sleep = ms => execFileSync('node', ['-e', `setTimeout(()=>{},${ms})`]);
const ui = (...a) => { try { return execFileSync('node', [path.join(DIR, 'ui.cjs'), ...a]).toString().trim(); } catch (e) { return (e.stdout || '').toString().trim(); } };
const curl = (...a) => execFileSync('curl', ['-s', '-m', '20', ...a]).toString();
const post = (route, body) => curl('-X', 'POST', 'http://127.0.0.1:18597' + route, '-H', 'Content-Type: application/json', '-d', JSON.stringify(body));
const md5 = f => execFileSync('md5sum', [f]).toString().split(' ')[0];
const ffmd5 = (f, map) => execFileSync('ffmpeg', ['-v', 'error', '-i', f, '-map', map, '-f', 'md5', '-']).toString().trim().replace('MD5=', '');
const decodeErrors = f => execFileSync('ffmpeg', ['-v', 'error', '-i', f, '-f', 'null', '-'], { stdio: ['ignore', 'pipe', 'pipe'], maxBuffer: 1 << 26 }).toString().trim();
const log = (port) => JSON.parse(curl(`http://127.0.0.1:${port}/__log`));
const results = [];
function verdict(name, ok, detail) { results.push({ name, ok, detail }); console.log((ok ? 'PASS ' : 'FAIL ') + name + ' :: ' + detail); }

function pull(name) {
  const dst = path.join(OUT, name);
  try { fs.unlinkSync(dst); } catch (_) {}
  try { execFileSync(H, T.concat(['file', 'recv', '-b', 'com.neuohos.xdm', 'data/storage/el2/base/haps/entry/files/Downloads/' + name, path.basename(dst)]), { cwd: path.dirname(dst) }); } catch (_) { return null; }
  return fs.existsSync(dst) ? dst : null;
}
function confirmDialog() {
  for (let i = 0; i < 15; i++) { if (ui('tap', 'Download Now', 'Button').startsWith('tapped')) return true; sleep(700); }
  return false;
}
function vidOf(prefix, tab) {
  for (let i = 0; i < 20; i++) {
    const list = JSON.parse(curl('http://127.0.0.1:18597/sync')).videoList;
    const v = list.find(x => x.text.startsWith(prefix) && (!tab || x.tabId === tab));
    if (v) return v;
    sleep(1000);
  }
  return null;
}
function capture(url, file, tab, ctype) {
  post('/media', { url, file, tabId: tab, tabUrl: 'http://127.0.0.1:18800/' + tab, cookie: 'e2e=' + tab,
    requestHeaders: { Referer: ['http://127.0.0.1:18800/' + tab] }, responseHeaders: { 'Content-Type': [ctype] } });
}
function download(v) { post('/vid', { vid: v.id }); return confirmDialog(); }
function waitFile(name, ms) {
  const end = Date.now() + ms;
  while (Date.now() < end) { const f = pull(name); if (f) return f; sleep(3000); }
  return null;
}
function closeCompleted() { ui('tap', 'Open folder', 'Button') ; } // not used (would open picker)
const concat = (dir, re) => Buffer.concat(fs.readdirSync(dir).filter(n => re.test(n)).sort().map(n => fs.readFileSync(path.join(dir, n))));

const S = {
  http() {
    const name = 'emu-http-source.mp4';
    post('/download', { url: 'http://127.0.0.1:18800/source.mp4', file: name, requestHeaders: { Referer: ['http://127.0.0.1:18800/'] },
      responseHeaders: { 'Content-Length': [String(fs.statSync(path.join(MEDIA, 'source.mp4')).size)] } });
    if (!confirmDialog()) return verdict('http', false, 'dialog not shown');
    const f = waitFile(name, 60000);
    verdict('http', !!f && md5(f) === md5(path.join(MEDIA, 'source.mp4')), f ? 'md5 ' + md5(f) : 'no file');
  },
  'hls-ts'() {
    capture('http://127.0.0.1:18800/hls/master.m3u8', 'EMU-HLS', '801', 'application/vnd.apple.mpegurl');
    const v = vidOf('EMU-HLS.ts', '801'); if (!v) return verdict('hls-ts', false, 'not captured');
    if (!download(v)) return verdict('hls-ts', false, 'dialog not shown');
    const f = waitFile('EMU-HLS.ts', 90000);
    const ref = concat(path.join(MEDIA, 'hls/muxed'), /\.ts$/);
    verdict('hls-ts', !!f && Buffer.compare(fs.readFileSync(f), ref) === 0, f ? 'bytes ' + fs.statSync(f).size + ' vs concat ' + ref.length : 'no file');
  },
  'hls-dual'() {
    const v = vidOf('EMU-HLS.mp4', '801'); if (!v) return verdict('hls-dual', false, 'not captured');
    if (!download(v)) return verdict('hls-dual', false, 'dialog not shown');
    const f = waitFile('EMU-HLS.mp4', 90000);
    if (!f) return verdict('hls-dual', false, 'no file');
    const vOk = ffmd5(f, '0:v') === ffmd5(path.join(MEDIA, 'source.mp4'), '0:v');
    const aOk = ffmd5(f, '0:a') === ffmd5(path.join(MEDIA, 'hls/audio/index.m3u8'), '0:a');
    verdict('hls-dual', vOk && aOk, 'video md5 ' + vOk + ', audio md5 ' + aOk);
  },
  dash() {
    capture('http://127.0.0.1:18800/dash/manifest.mpd', 'EMU-DASH', '802', 'application/dash+xml');
    const v = vidOf('EMU-DASH', '802'); if (!v) return verdict('dash', false, 'not captured');
    if (!download(v)) return verdict('dash', false, 'dialog not shown');
    const f = waitFile('EMU-DASH.mp4', 90000);
    if (!f) return verdict('dash', false, 'no file');
    const vOk = ffmd5(f, '0:v') === ffmd5(path.join(MEDIA, 'source.mp4'), '0:v');
    fs.writeFileSync(path.join(OUT, 'ref-a.mp4'), concat(path.join(MEDIA, 'dash'), /^(init-1|chunk-1-)/));
    const pcm = p => execFileSync('ffmpeg', ['-v', 'error', '-i', p, '-map', '0:a', '-f', 's16le', '-'], { maxBuffer: 1 << 30 });
    const a = pcm(f), b = pcm(path.join(OUT, 'ref-a.mp4'));
    const aOk = a.length <= b.length && b.compare(a, 0, a.length, 0, a.length) === 0;
    verdict('dash', vOk && aOk, `video md5 ${vOk}, audio PCM prefix-equal ${aOk} (trim ${(b.length - a.length) / 4} samples)`);
  },
  killresume() {
    curl('http://127.0.0.1:18810/__reset');
    post('/media', { url: 'http://127.0.0.1:18810/slow/hls/muxed/index.m3u8', file: 'EMU-KILL', tabId: '803', tabUrl: 'http://127.0.0.1:18810/p',
      requestHeaders: { Referer: ['http://127.0.0.1:18810/p'] }, responseHeaders: { 'Content-Type': ['application/vnd.apple.mpegurl'] } });
    const v = vidOf('EMU-KILL', '803'); if (!v || !download(v)) return verdict('killresume', false, 'capture/dialog failed');
    sleep(26000);
    const before = log(18810).map(x => x.path.split('/').pop());
    hdc(['shell', 'aa force-stop com.neuohos.xdm']);
    curl('http://127.0.0.1:18810/__reset');
    hdc(['shell', 'aa start -b com.neuohos.xdm -a EntryAbility']); sleep(5000);
    ui('tap', 'Active', 'Text'); sleep(1500);
    const row = ui('row', 'EMU-KILL.ts', 'click');
    const f = waitFile('EMU-KILL.ts', 180000);
    const after = log(18810).map(x => x.path.split('/').pop());
    const ref = concat(path.join(MEDIA, 'hls/muxed'), /\.ts$/);
    const ok = !!f && Buffer.compare(fs.readFileSync(f), ref) === 0 && !after.includes('index.m3u8') && after.length < 10;
    verdict('killresume', ok, `before kill: ${before.join(' ')} | after restart: ${after.join(' ')} | row: ${row.split('\n')[0]} | bytes equal ${!!f && Buffer.compare(fs.readFileSync(f), ref) === 0}`);
  },
  pause() {
    curl('http://127.0.0.1:18810/__reset');
    post('/media', { url: 'http://127.0.0.1:18810/slow/dash/manifest.mpd', file: 'EMU-PAUSE', tabId: '804', tabUrl: 'http://127.0.0.1:18810/q',
      requestHeaders: { Referer: ['http://127.0.0.1:18810/q'] }, responseHeaders: { 'Content-Type': ['application/dash+xml'] } });
    const v = vidOf('EMU-PAUSE', '804'); if (!v || !download(v)) return verdict('pause', false, 'capture/dialog failed');
    sleep(9000); ui('tap', 'Active', 'Text'); sleep(1000);
    const p1 = ui('row', 'EMU-PAUSE.mp4', 'click'); sleep(4000);
    const n1 = log(18810).length; const state = ui('row', 'EMU-PAUSE.mp4'); sleep(5000); const n2 = log(18810).length;
    curl('http://127.0.0.1:18810/__reset');
    ui('row', 'EMU-PAUSE.mp4', 'click');
    const f = waitFile('EMU-PAUSE.mp4', 180000);
    const after = log(18810).map(x => x.path.split('/').pop());
    const vOk = !!f && ffmd5(f, '0:v') === ffmd5(path.join(MEDIA, 'source.mp4'), '0:v');
    const ok = vOk && n1 === n2 && /Stopped|Resume/.test(state) && !after.some(x => x.endsWith('.mpd') || x.startsWith('init-'));
    verdict('pause', ok, `paused row: ${state} | requests while paused ${n1}->${n2} | resume requests ${after.length} (${after.join(' ')}) | video md5 ${vOk}`);
  },
  pubdash() {
    post('/media', { url: 'https://dash.akamaized.net/akamai/bbb_30fps/bbb_30fps.mpd', file: 'emu_bbb', tabId: '805', tabUrl: 'https://reference.dashif.org/',
      requestHeaders: { Referer: ['https://reference.dashif.org/'] }, responseHeaders: { 'Content-Type': ['application/dash+xml'] } });
    let v = null;
    for (let i = 0; i < 20 && !v; i++) { v = JSON.parse(curl('http://127.0.0.1:18597/sync')).videoList.find(x => x.tabId === '805' && x.info.includes('313')); if (!v) sleep(1500); }
    if (!v || !download(v)) return verdict('pubdash', false, 'capture/dialog failed');
    const f = waitFile('emu_bbb.mp4', 600000);
    if (!f) return verdict('pubdash', false, 'no file');
    const errs = decodeErrors(f);
    const dur = execFileSync('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', f]).toString().trim();
    verdict('pubdash', errs === '' && Math.abs(Number(dur) - 634.57) < 1, `size ${fs.statSync(f).size} duration ${dur} decodeErrors ${errs ? errs.slice(0, 80) : 'none'}`);
  },
  pubhls() {
    post('/media', { url: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8', file: 'emu_mux', tabId: '806', tabUrl: 'https://test-streams.mux.dev/',
      requestHeaders: { Referer: ['https://test-streams.mux.dev/'] }, responseHeaders: { 'Content-Type': ['application/vnd.apple.mpegurl'] } });
    let v = null;
    for (let i = 0; i < 20 && !v; i++) { v = JSON.parse(curl('http://127.0.0.1:18597/sync')).videoList.find(x => x.tabId === '806' && x.info.includes('320x184')); if (!v) sleep(1500); }
    if (!v || !download(v)) return verdict('pubhls', false, 'capture/dialog failed');
    const f = waitFile('emu_mux.ts', 900000);
    if (!f) return verdict('pubhls', false, 'no file');
    const errs = decodeErrors(f);
    const dur = execFileSync('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', f]).toString().trim();
    verdict('pubhls', errs === '' && Math.abs(Number(dur) - 634.6) < 1, `size ${fs.statSync(f).size} duration ${dur} decodeErrors ${errs ? errs.slice(0, 80) : 'none'}`);
  }
};

for (const name of process.argv.slice(2)) {
  try { S[name](); } catch (e) { verdict(name, false, 'exception ' + String(e.message).slice(0, 200)); }
  ui('click', '10', '10'); // dismiss non-modal completion window by clicking outside
  sleep(1500);
}
fs.appendFileSync(path.join(WORK, 'e2e-results.jsonl'), results.map(r => JSON.stringify(Object.assign({ t: new Date().toISOString() }, r))).join('\n') + '\n');
