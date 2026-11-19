'use strict';
// Compare the newest device/emulator session of each unit against a baseline log (key=value per step).
// usage: node docs/probe/e2e/baseline-diff.cjs <baseline.log> <UNIT...>
// Volatile keys (ids, paths, timings, hashes, counters of connections) are ignored.
const { execFileSync } = require('child_process');
const fs = require('fs');
const H = 'D:/Tools/DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe';
const T = ['-t', process.env.XDM_T || '127.0.0.1:5555'];
const VOLATILE = /(detailFile|runId|filesDir|elapsed|Ms$|^vid$|^id$|Id$|Output|output|sha|Sha256|Retained0|connections|requests|requestsBefore|samples|Bps|ratio|Duration|tick|Ticks|recordId|tempDir|QueueHigh|sleep|instant|avgRate|Speed|Eta|lastDownloaded|dbProgress|lastProgress|pausedDownloaded|pausedPieces|savedLine|restoredLine|restoredSum|pauseOffset|ledgerSum|aggregateFileSize|pieceCount|piecesCount|connectedCount|snapshotLines|firstChunkBytes|chunks|swapSources|peakLive|maxConcurrentBefore|pausedOffset|firstProgress|processedBefore|heartbeat|Heartbeat|timerFired|sampleAt60|attemptPendingAt60|targetMinute|dayBit|finalPathInDb|persistenceFile|pendingFile|spotChecks|requestStart|requestEnd|Received|Written|QueueBytes|maxGap|Gap)/;
function kv(line) {
  const body = line.replace(/^.*?\]\[[^\]]+\]\[[^\]]+\]\s*/, '');
  const out = {};
  for (const m of body.matchAll(/(\S+?)=(\S*)/g)) out[m[1]] = m[2];
  return out;
}
function sessions(lines, unit) {
  const own = lines.map(l => l.slice(l.indexOf('[XDM_PROBE]'))).filter(l => l.startsWith('[XDM_PROBE][' + unit + ']'));
  const res = []; let cur = null;
  for (const l of own) {
    const step = /\]\[([^\]]+)\]\s/.exec(l.slice(11))?.[1] ?? /\]\[([A-Za-z0-9-]+)\]/.exec(l.replace('[XDM_PROBE][' + unit + ']', ''))?.[1];
    const s = /^\[XDM_PROBE\]\[[^\]]+\]\[([^\]]+)\]/.exec(l)[1];
    if (s === 'BEGIN') { cur = {}; res.push(cur); }
    if (cur && s !== 'SUMMARY' && s !== 'BEGIN') cur[s] = kv(l);
  }
  return res;
}
const [baseFile, ...units] = process.argv.slice(2);
const baseLines = fs.readFileSync(baseFile, 'utf8').split(/\r?\n/);
let dev = '';
try { dev = execFileSync(H, T.concat(['shell', 'hilog -x | grep XDM_PROBE']), { maxBuffer: 1 << 27 }).toString(); } catch (_) {}
const devLines = dev.split(/\r?\n/);
for (const unit of units) {
  const base = sessions(baseLines, unit).filter(s => Object.keys(s).length > 1);
  const now = sessions(devLines, unit).filter(s => Object.keys(s).length > 1);
  if (!base.length || !now.length) { console.log(`${unit}: baseline ${base.length} / now ${now.length} sessions — skipped`); continue; }
  const b = base[base.length - 1];
  // newest emulator session that contains the same first step as the baseline session
  const n = [...now].reverse().find(s => Object.keys(b).some(k => s[k])) || now[now.length - 1];
  const diffs = [];
  for (const step of Object.keys(b)) {
    if (!n[step]) { diffs.push(`${step}: missing`); continue; }
    for (const [k, v] of Object.entries(b[step])) {
      if (VOLATILE.test(k)) continue;
      if (!(k in n[step])) diffs.push(`${step}.${k}: missing (base ${v})`);
      else if (n[step][k] !== v) diffs.push(`${step}.${k}: ${v} -> ${n[step][k]}`);
    }
  }
  console.log(`${unit}: ${diffs.length ? 'DIFF ' + diffs.join(' | ') : 'same as baseline'}`);
}
