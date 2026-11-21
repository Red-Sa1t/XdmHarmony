'use strict';
// AGC 审核演示录屏驱动（2026-11-22）：在模拟器/设备上从启动器打开应用，按体验地址页走一遍核心功能，
// 设备侧连续截屏（snapshot_display，带纳秒时间戳）并记录每一步的中文字幕时间点。
// usage: node docs/probe/e2e/demo-record.cjs [--norec] [--hap <path>]
//   前置：XDM 已卸载或将由 --hap 重新安装；浏览器可访问 red-sa1t.github.io；hdc target 127.0.0.1:5555。
// 产物：<work>/demo/frames/*.jpeg、<work>/demo/captions.json（之后用 demo-assemble.cjs 合成视频）
const { execFileSync, spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const H = 'D:/Tools/DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe';
const T = ['-t', process.env.XDM_T || '127.0.0.1:5555'];
const WORK = path.join(process.env.XDM_E2E_WORK || process.cwd(), 'demo');
const SAMPLES = 'https://red-sa1t.github.io/XdmHarmony/samples.html';
const BROWSER = ['com.huawei.hmos.browser', 'MainAbility'];
const args = process.argv.slice(2);
const RECORD = !args.includes('--norec');
const hapIdx = args.indexOf('--hap');
fs.mkdirSync(WORK, { recursive: true });

const sh = cmd => execFileSync(H, T.concat(['shell', cmd]), { maxBuffer: 1 << 26 }).toString();
const sleep = ms => execFileSync(process.execPath, ['-e', `setTimeout(()=>{},${ms})`]);
const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);

// 全部窗口 + XDM 自身（菜单、对话框等子窗口只在按包名导出时出现）两次导出合并
function dumpAll() {
  return dumpOne('-b com.neuohos.xdm').concat(dumpOne(''));
}
function dumpOne(opt) {
  try { sh('uitest dumpLayout ' + opt + ' -p /data/local/tmp/demo.json'); } catch (_) { return []; }
  execFileSync(H, T.concat(['file', 'recv', '/data/local/tmp/demo.json', 'demo.json']), { cwd: WORK });
  let j;
  try { j = JSON.parse(fs.readFileSync(path.join(WORK, 'demo.json'), 'utf8')); } catch (_) { return []; }
  const out = [];
  (function w(n) {
    const a = n.attributes || {};
    const m = /\[(\d+),(\d+)\]\[(\d+),(\d+)\]/.exec(a.bounds || '');
    if (m) out.push({ type: a.type || '', text: a.text || '', id: a.id || '', checked: a.checked, b: m.slice(1).map(Number) });
    (n.children || []).forEach(w);
  })(j);
  return out;
}
const center = n => [(n.b[0] + n.b[2]) >> 1, (n.b[1] + n.b[3]) >> 1];
const click = (x, y) => sh(`uitest uiInput click ${x} ${y}`);
const key = (...codes) => sh('uitest uiInput keyEvent ' + codes.join(' '));
// 找到文本完全匹配（可限定类型）的节点；pick: 'first' | 'last'（y 最大）| 序号
function find(text, type, pick = 'first', tries = 8) {
  for (let i = 0; i < tries; i++) {
    const all = dumpAll().filter(n => n.text === text && (!type || n.type === type) && n.b[2] > n.b[0]);
    if (all.length) {
      if (pick === 'last') return all.sort((a, b) => a.b[1] - b.b[1])[all.length - 1];
      if (typeof pick === 'number') return all[pick] || null;
      return all[0];
    }
    sleep(600);
  }
  return null;
}
function tap(text, type, pick, tries) {
  const n = find(text, type, pick, tries);
  if (!n) { log('  ! not found:', text, type || ''); return false; }
  click(...center(n));
  return true;
}
function waitFor(text, type, ms) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (dumpAll().some(n => n.text === text && (!type || n.type === type))) return true;
    sleep(800);
  }
  return false;
}

// ---- 录屏与字幕 ----
let offsetMs = 0;
const captions = [];
function cap(text) { captions.push({ t: Date.now() + offsetMs, text }); log('CAP', text); }
let recChild = null;
function startRecording() {
  sh('rm -rf /data/local/tmp/rec; mkdir -p /data/local/tmp/rec; touch /data/local/tmp/rec.on');
  const dev = Number(BigInt(sh('date +%s%N').trim()) / 1000000n);
  offsetMs = dev - Date.now();
  recChild = spawn(H, T.concat(['shell', 'while [ -f /data/local/tmp/rec.on ]; do snapshot_display -f /data/local/tmp/rec/$(date +%s%N).jpeg >/dev/null 2>&1; done']), { stdio: 'ignore' });
  sleep(1500);
}
function stopRecording() {
  sh('rm -f /data/local/tmp/rec.on');
  sleep(2500);
  try { recChild.kill(); } catch (_) {}
  const dir = path.join(WORK, 'frames');
  fs.rmSync(dir, { recursive: true, force: true });
  fs.mkdirSync(dir, { recursive: true });
  execFileSync(H, T.concat(['file', 'recv', '/data/local/tmp/rec', '.']), { cwd: dir, maxBuffer: 1 << 26 });
  fs.writeFileSync(path.join(WORK, 'captions.json'), JSON.stringify(captions, null, 1));
  log('frames pulled to', dir);
}

// ---- 应用内操作 ----
const toFront = (b, a) => sh(`aa start -b ${b} -a ${a}`);
const xdmFront = () => { toFront('com.neuohos.xdm', 'EntryAbility'); sleep(1500); };
const browserFront = () => { toFront(...BROWSER); sleep(1500); };
function menuButton() {
  const nodes = dumpAll();
  const nb = nodes.find(n => n.text === '新建' && n.type === 'Button');
  if (!nb) return null;
  const cy = (nb.b[1] + nb.b[3]) >> 1;
  const cands = nodes.filter(n => n.type === 'Button' && n.text === '' && !n.id && n.b[1] <= cy && n.b[3] >= cy);
  return cands.sort((a, b) => a.b[0] - b.b[0]).pop() || null;
}
function openMenu(item) {
  const m = menuButton();
  if (!m) { log('  ! menu button not found'); return false; }
  click(...center(m));
  sleep(800);
  return tap(item, 'Option') || tap(item);
}
function navBack(title) {
  const t = find(title, 'Text', 'first', 3);
  if (t) { click(t.b[0] - 55, (t.b[1] + t.b[3]) >> 1); sleep(1200); }
}
function closeDialogs() { if (tap('关闭', 'Button', 'last', 4)) { sleep(600); tap('关闭', 'Button', 'last', 1); } }
// 关闭文件预览窗口：标题为文件名的窗口右上角关闭钮（同一行的 EnhanceCloseBtn）
function closePreview(fileName) {
  const nodes = dumpAll();
  const t = nodes.find(n => n.text === fileName && n.b[1] < 500);
  if (!t) { key(2070); return; }
  const cy = (t.b[1] + t.b[3]) >> 1;
  const c = nodes.filter(n => n.id === 'EnhanceCloseBtn' && n.b[1] <= cy && n.b[3] >= cy)[0];
  if (c) click(...center(c)); else key(2070);
  sleep(1200);
}
function hideProgress() { for (let i = 0; i < 3; i++) { if (!tap('隐藏', 'Button', 'last', 1)) break; sleep(500); } }
// 在网页上点第 idx 个"复制链接"按钮（必要时滚动）
function copyLink(idx) {
  for (let s = 0; s < 4; s++) {
    const btns = dumpAll().filter(n => n.type === 'button' && n.text === '复制链接' || n.type === 'button' && n.text === '已复制');
    const b = btns[idx];
    if (b && b.b[3] < 1600) { click(...center(b)); return true; }
    sh('uitest uiInput swipe 1560 1400 1560 900 800');
    sleep(1200);
  }
  log('  ! copy button', idx, 'not reachable');
  return false;
}
function newFromClipboard() {
  tap('新建', 'Button');
  sleep(800);
  tap('新建下载', 'Option');
  return waitFor('现在下载', 'Button', 8000);
}

// ================= 准备（不录） =================
if (hapIdx >= 0) {
  log('reinstall');
  try { sh('bm uninstall -n com.neuohos.xdm'); } catch (_) {}
  execFileSync(H, T.concat(['install', args[hapIdx + 1]]));
}
// 浏览器：先打开体验页并处理"恢复页面"提示（选 Cancel），再最小化，录制开始时桌面干净
sh(`aa start -A ohos.want.action.viewData -U ${SAMPLES}`);
sleep(8000);
tap('Cancel', null, 'first', 2);
sleep(800);
{
  const mins = dumpOne('').filter(n => n.id === 'EnhanceMinimizeBtn');
  if (mins.length) click(...center(mins[0]));
}
sleep(1500);

// ================= 录制 =================
if (RECORD) startRecording();
cap('XDM下载管理器 演示：从启动应用开始，体验核心功能（鸿蒙 PC）');
sleep(3000);
cap('从启动器打开 XDM下载管理器');
click(1303, 2017); // 任务栏"所有应用"
sleep(1500);
const icon = find('XDM Download Manager', 'Text', 'first', 4) || find('XDM下载管理器', 'Text', 'first', 2);
if (icon) click(...center(icon)); else xdmFront();
sleep(4000);
cap('首次启动：系统询问是否允许通知（用于显示下载进度与完成提醒），选择允许');
sleep(2500);
if (!tap('Allow', null, 'first', 3) && !tap('允许', null, 'first', 2)) click(1741, 1140);
sleep(2000);
cap('主界面：左侧按文件类型分类，右侧为"进行中 / 已完成"列表');
sleep(4000);
cap('在浏览器打开体验地址页 red-sa1t.github.io/XdmHarmony/samples.html');
sh(`aa start -A ohos.want.action.viewData -U ${SAMPLES}`);
sleep(9000);

const items = [
  { idx: 0, label: '文档（PDF）', name: 'xdm-guide.pdf' },
  { idx: 1, label: '压缩包（ZIP）', name: 'xdm-sample-pack.zip' },
  { idx: 2, label: '音乐（MP3）', name: 'xdm-sample-music.mp3' }
];
for (const it of items) {
  cap(`下载${it.label}：在网页上点"复制链接"`);
  copyLink(it.idx); sleep(1500);
  cap('回到 XDM，点"新建 › 新建下载"，地址和文件名自动填入');
  xdmFront();
  newFromClipboard(); sleep(2500);
  cap('点"现在下载"：多线程分段下载，完成后弹出"下载完成"');
  tap('现在下载', 'Button');
  waitFor('下载完成', null, 30000); sleep(2500);
  closeDialogs(); hideProgress();
  browserFront();
}

cap('下载程序安装包（63 MB）：复制链接 → 新建 → 现在下载');
copyLink(4); sleep(1200);
xdmFront();
newFromClipboard(); sleep(1500);
tap('现在下载', 'Button'); sleep(3500);
cap('进度窗口显示已下载大小、速度和剩余时间');
sleep(2500);
cap('暂停：已下载的部分会保留');
tap('暂停', 'Button', 'last'); sleep(3500);
cap('恢复：从中断处继续下载');
tap('恢复', 'Button', 'last');
waitFor('下载完成', null, 90000); sleep(2500);
closeDialogs(); hideProgress();

cap('已完成列表');
tap('已完成', 'Text'); sleep(2500);
for (const c of ['文档', '音乐', '压缩', '程序']) {
  cap(`按类型自动分类：${c}`);
  tap(c, 'Text'); sleep(2200);
}
tap('已完成', 'Text'); sleep(1200);
cap('点列标题排序（名称）');
tap('名称', 'Text'); sleep(1500); tap('名称', 'Text'); sleep(1500);
cap('快捷键：Ctrl+A 全选当前列表');
key(2072, 2017); sleep(2000);
cap('快捷键：Esc 取消选择');
key(2070); sleep(1500);
cap('删除：选中后点"删除"（或按 Delete），可选择是否同时删除磁盘上的文件');
tap('xdm-sample-music.mp3', 'Text'); sleep(800);
tap('删除', 'Button'); sleep(2000);
tap('删除', 'Button', 'last'); sleep(2000);

cap('菜单 › 设置：浏览器监视、通用、网络、密码管理、高级');
openMenu('设置'); sleep(2000);
for (const t of ['通用设置', '网络设置', '密码管理', '高级设置', '浏览器监视']) { tap(t, 'Text'); sleep(1600); }
cap('在"浏览器监视"中勾选"监视剪贴板"并保存：之后复制链接会自动弹出新建下载');
const lbl = find('监视剪贴板', 'Text');
if (lbl) {
  const ly = (lbl.b[1] + lbl.b[3]) >> 1;
  const tg = dumpAll().filter(n => (n.type === 'Toggle' || n.type === 'Checkbox') && n.b[1] <= ly && n.b[3] >= ly)[0];
  if (tg) click(...center(tg)); else log('  ! toggle not found');
}
sleep(1500);
tap('保存', 'Button'); sleep(2000);
if (find('设置', 'Text', 'first', 1)) navBack('设置');

cap('下载视频（MP4）：开启监视剪贴板后，在网页上复制链接');
browserFront();
copyLink(3); sleep(1500);
cap('回到 XDM：自动弹出"新建下载"，地址已填入');
xdmFront();
waitFor('现在下载', 'Button', 8000); sleep(2000);
tap('现在下载', 'Button');
waitFor('下载完成', null, 40000); sleep(2000);
cap('下载完成后点"打开"：用系统播放器播放刚下载的视频');
tap('打开', 'Button', 'last'); sleep(9000);
closePreview('xdm-sample-video.mp4');
closeDialogs(); hideProgress();
cap('按类型自动分类：视频');
tap('视频', 'Text'); sleep(2500);
tap('已完成', 'Text'); sleep(1000);

cap('菜单 › 媒体抓取：配合浏览器扩展识别网页中的视频（扩展为可选功能）');
openMenu('媒体抓取'); sleep(3000);
navBack('媒体抓取');
cap('菜单 › 语言：简体中文 / 英文 / 跟随系统');
openMenu('语言'); sleep(2500);
tap('取消', 'Button'); sleep(1000);
cap('菜单 › 关于：版本、GPL-2.0 开源许可与源代码地址');
openMenu('关于XDM...'); sleep(4000);
tap('确定', null, 'last'); sleep(1500);
cap('演示结束。体验地址与使用指南：red-sa1t.github.io/XdmHarmony');
sleep(3500);
if (RECORD) stopRecording();
log('done');
