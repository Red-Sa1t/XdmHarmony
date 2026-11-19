'use strict';
// Drive one probe unit on an emulator/device through uitest (full acceptance runs, 2026-11-19).
// usage: node docs/probe/e2e/probe-run.cjs <UNIT> [--in idx=value ...] [--wait sec] [--noRun] [--rerun] [--stay]
//   Opens the probe page (unless NO_OPEN=1), enters the unit row, fills TextInputs by index,
//   presses 运行全部 (or 重跑), waits for [END] in the on-page log, writes <work>/logs/<UNIT>.log.
// env: XDM_T (hdc target, default 127.0.0.1:5555), XDM_E2E_WORK (work dir, default cwd)
const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const H = 'D:/Tools/DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe';
const T = ['-t', process.env.XDM_T || '127.0.0.1:5555'];
const WORK = process.env.XDM_E2E_WORK || process.cwd();
const hdc = a => execFileSync(H, T.concat(a)).toString();
// recv via the target folder + bare name (a restarted hdc server joins the client cwd onto absolute paths)
const recv = (remote, local) => execFileSync(H, T.concat(['file', 'recv', remote, path.basename(local)]), { cwd: path.dirname(local) }).toString();
const sleep = ms => execFileSync(process.execPath, ['-e', `setTimeout(()=>{},${ms})`]);

function nodes() {
  hdc(['shell', 'uitest dumpLayout -b com.neuohos.xdm -p /data/local/tmp/l.json']);
  recv('/data/local/tmp/l.json', path.join(WORK, 'layout.json'));
  const j = JSON.parse(fs.readFileSync(path.join(WORK, 'layout.json'), 'utf8'));
  const all = [];
  (function w(n) {
    const a = n.attributes || {};
    const m = /\[(\d+),(\d+)\]\[(\d+),(\d+)\]/.exec(a.bounds || '');
    if (m) all.push({ t: a.type, x: a.text, b: m.slice(1).map(Number) });
    (n.children || []).forEach(w);
  })(j);
  return all;
}
const ctr = b => [(b[0] + b[2]) >> 1, (b[1] + b[3]) >> 1];
const click = (x, y) => hdc(['shell', `uitest uiInput click ${x} ${y}`]);
const swipeUp = () => hdc(['shell', 'uitest uiInput swipe 1560 1500 1560 800 600']);
// Probe marker lines of one unit from device hilog (the on-page log can sit below the fold).
const unitLines = u => {
  let out = '';
  try { out = execFileSync(H, T.concat(['shell', 'hilog -x | grep XDM_PROBE']), { maxBuffer: 1 << 26 }).toString(); } catch (_) {}
  return out.split(/\r?\n/).map(l => l.slice(l.indexOf('[XDM_PROBE]'))).filter(l => l.startsWith('[XDM_PROBE][' + u + ']'));
};

const args = process.argv.slice(2);
const unit = args[0];
const inputs = [];
let wait = 120; let run = true; let rerun = false;
for (let i = 1; i < args.length; i++) {
  if (args[i] === '--in') inputs.push(args[++i]);
  else if (args[i] === '--wait') wait = Number(args[++i]);
  else if (args[i] === '--noRun') run = false;
  else if (args[i] === '--rerun') rerun = true;
}
// Sessions before entering: units with autoStart begin on entry and must not be started twice
// (a second session in the same process inherits listener counters / sniff dedupe state).
const beginsAtOpen = unitLines(unit).filter(l => l.includes('][BEGIN]')).length;
if (!process.env.NO_OPEN) {
  hdc(['shell', 'aa start -b com.neuohos.xdm -a EntryAbility --ps page probe']);
  sleep(2500);
  let row = null;
  for (let s = 0; s < 8 && !row; s++) {
    row = nodes().find(n => n.x === unit && n.t === 'Text');
    if (!row) { swipeUp(); sleep(800); }
  }
  if (!row) { console.log('unit not found ' + unit); process.exit(2); }
  click(...ctr(row.b));
  sleep(2000);
}
const fields = nodes().filter(n => n.t === 'TextInput');
console.log('inputs:', fields.map((f, i) => i + '=' + JSON.stringify(f.x)).join(' '));
for (const spec of inputs) {
  const k = spec.indexOf('=');
  const f = fields[Number(spec.slice(0, k))];
  if (!f) { console.log('no input ' + spec); continue; }
  const [x, y] = ctr(f.b);
  click(x, y); sleep(300);
  hdc(['shell', 'uitest uiInput keyEvent 2072 2017']);
  hdc(['shell', 'uitest uiInput keyEvent 2055']);
  hdc(['shell', `uitest uiInput inputText ${x} ${y} "${spec.slice(k + 1)}"`]);
  sleep(300);
}
let beginsBefore = unitLines(unit).filter(l => l.includes('][BEGIN]')).length;
if (beginsBefore > beginsAtOpen && !rerun) {
  console.log('auto-started on entry; not pressing run');
  run = false;
  beginsBefore = beginsAtOpen;
}
if (run) {
  let btn = null;
  for (let i = 0; i < 6 && !btn; i++) {
    btn = nodes().find(n => n.t === 'Button' && (rerun ? n.x === '重跑' : (n.x === '运行全部' || n.x === '重跑')));
    if (!btn) sleep(600);
  }
  if (btn) click(...ctr(btn.b)); else console.log('no run button');
}
const end = Date.now() + wait * 1000;
let text = '';
while (Date.now() < end) {
  sleep(3000);
  const lines = unitLines(unit);
  const idx = [];
  lines.forEach((l, i) => { if (l.includes('][BEGIN]')) idx.push(i); });
  if (idx.length > beginsBefore) {
    text = lines.slice(idx[idx.length - 1]).join('\n');
    if (/\]\[END\]/.test(text)) break;
  }
}
fs.mkdirSync(path.join(WORK, 'logs'), { recursive: true });
fs.appendFileSync(path.join(WORK, 'logs', unit + '.log'), text + '\n');
console.log(text || '(no new session)');
console.log('ended:', /\]\[END\]/.test(text));
