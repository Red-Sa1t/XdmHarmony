'use strict';
// 把 demo-record.cjs 拉回的设备帧（文件名=设备纳秒时间戳）按真实时间合成为视频，并烧录中文字幕。
// usage: node docs/probe/e2e/demo-assemble.cjs <out.mp4>
const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const WORK = path.join(process.env.XDM_E2E_WORK || process.cwd(), 'demo');
const out = path.resolve(process.argv[2] || path.join(WORK, 'xdm-demo.mp4'));
const frameDir = path.join(WORK, 'frames', 'rec');
const dir = fs.existsSync(frameDir) ? frameDir : path.join(WORK, 'frames');
const frames = fs.readdirSync(dir).filter(f => /^\d+\.jpeg$/.test(f))
  .map(f => ({ f: path.join(dir, f), t: Number(BigInt(f.slice(0, -5)) / 1000000n) }))
  .sort((a, b) => a.t - b.t);
if (frames.length < 2) throw new Error('no frames in ' + dir);
const t0 = frames[0].t;
// concat 清单：每帧持续到下一帧（最后一帧 2 秒）
let list = '';
for (let i = 0; i < frames.length; i++) {
  const d = i + 1 < frames.length ? (frames[i + 1].t - frames[i].t) / 1000 : 2;
  list += `file '${frames[i].f.replace(/\\/g, '/')}'\nduration ${Math.max(0.04, d).toFixed(3)}\n`;
}
list += `file '${frames[frames.length - 1].f.replace(/\\/g, '/')}'\n`;
fs.writeFileSync(path.join(WORK, 'frames.txt'), list);
// 字幕：每条从其时间点显示到下一条开始
const caps = JSON.parse(fs.readFileSync(path.join(WORK, 'captions.json'), 'utf8'));
const end = frames[frames.length - 1].t + 2000;
const ts = ms => {
  ms = Math.max(0, ms);
  const h = Math.floor(ms / 3600000), m = Math.floor(ms / 60000) % 60, s = Math.floor(ms / 1000) % 60, x = ms % 1000;
  return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')},${String(x).padStart(3, '0')}`;
};
let srt = '';
caps.forEach((c, i) => {
  const a = c.t - t0, b = (i + 1 < caps.length ? caps[i + 1].t : end) - t0;
  srt += `${i + 1}\n${ts(a)} --> ${ts(b)}\n${c.text}\n\n`;
});
fs.writeFileSync(path.join(WORK, 'captions.srt'), srt, 'utf8');
const style = 'FontName=Microsoft YaHei,FontSize=15,PrimaryColour=&H00FFFFFF,BackColour=&H99000000,BorderStyle=3,Outline=1,Shadow=0,MarginV=18';
execFileSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', 'frames.txt',
  '-vf', `scale=1920:-2:flags=lanczos,subtitles=captions.srt:force_style='${style}',fps=30`,
  '-c:v', 'libx264', '-preset', 'medium', '-crf', '22', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', out], { cwd: WORK, stdio: 'inherit' });
const dur = (end - t0) / 1000;
console.log(`frames=${frames.length} duration=${dur.toFixed(1)}s avgfps=${(frames.length / dur).toFixed(2)} -> ${out}`);
