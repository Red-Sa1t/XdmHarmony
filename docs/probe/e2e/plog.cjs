// node docs/probe/e2e/plog.cjs <UNIT> [sessions=1]  -> last N sessions (BEGIN..END) of a unit from device hilog
const { execFileSync } = require('child_process');
const H = 'D:/Tools/DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe';
const T = ['-t', process.env.XDM_T || '127.0.0.1:5555'];
const unit = process.argv[2]; const n = Number(process.argv[3] || 1);
let out = '';
try { out = execFileSync(H, T.concat(['shell', 'hilog -x | grep XDM_PROBE']), { maxBuffer: 1 << 26 }).toString(); } catch (_) {}
const lines = out.split(/\r?\n/).map(l => l.slice(l.indexOf('[XDM_PROBE]'))).filter(l => l.startsWith('[XDM_PROBE][' + unit + ']'));
const starts = []; lines.forEach((l, i) => { if (l.includes('][BEGIN]')) starts.push(i); });
const from = starts.length >= n ? starts[starts.length - n] : 0;
console.log(lines.slice(from).join('\n'));
