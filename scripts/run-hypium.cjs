#!/usr/bin/env node
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');

function readText(file) {
  const bytes = fs.readFileSync(file);
  if (bytes[0] === 0xff && bytes[1] === 0xfe) return bytes.subarray(2).toString('utf16le');
  if (bytes[0] === 0xfe && bytes[1] === 0xff) return Buffer.from(bytes.subarray(2)).swap16().toString('utf16le');
  return bytes.toString('utf8').replace(/^\uFEFF/, '');
}

function normalizeLog(text) {
  // Supports raw ANSI as well as PowerShell logs containing literal Unicode escapes.
  return text.replace(/\\u001b\[[0-?]*[ -/]*[@-~]/gi, '').replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, '');
}

function checkEvidence(logText, resultText, childExitCode, expectedTests) {
  const issues = [], log = normalizeLog(logText);
  if (childExitCode !== 0) issues.push('child exit is not a verified zero');
  if (/\bERROR\s*:|\bBUILD FAILED\b|AssertException|AssertionError|UnhandledPromiseRejection|uncaught exception/i.test(log)) {
    issues.push('execution log contains an error/assertion failure');
  }
  const required = [
    /Finished\s+:[^\s]+@GenerateUnitTestResult\b/,
    /Finished\s+:[^\s]+:test\b/,
    /\bBUILD SUCCESSFUL\b/
  ];
  let previous = -1;
  for (const pattern of required) {
    const matches = [...log.matchAll(new RegExp(pattern.source, 'g'))];
    if (matches.length !== 1 || matches[0].index <= previous) {
      issues.push('missing, repeated or unordered completion marker: ' + pattern.source);
    }
    if (matches.length) previous = matches[0].index;
  }
  if (typeof resultText !== 'string') {
    issues.push('test_result.txt is required; a build-success log is insufficient');
    return { ok: false, issues, counts: null };
  }
  const lines = resultText.replace(/^\uFEFF/, '').split(/\r?\n/).map(x => x.trim()).filter(Boolean);
  const summaryPattern = /^Tests run: (\d+), Failure: (\d+), Error: (\d+), Pass: (\d+), Ignore: (\d+)$/;
  const summaries = lines.map((line, index) => ({ match: line.match(summaryPattern), index })).filter(x => x.match);
  if (summaries.length !== 1 || summaries[0].index !== lines.length - 1) {
    issues.push('result lacks a unique terminal summary');
    return { ok: false, issues, counts: null };
  }
  const values = summaries[0].match.slice(1).map(Number);
  const counts = { total: values[0], failure: values[1], error: values[2], pass: values[3], ignore: values[4] };
  if (!values.every(Number.isSafeInteger) || counts.total < 1 || counts.total !== counts.failure + counts.error + counts.pass + counts.ignore) {
    issues.push('invalid or empty result counts');
  }
  if (counts.failure || counts.error || counts.ignore || counts.pass !== counts.total) issues.push('not all executed tests passed without skips');
  if (expectedTests !== undefined && counts.total !== expectedTests) issues.push('test count does not match --expected-tests');
  let suite = '', pending = null, successes = 0, cases = 0;
  const names = new Set();
  for (const line of lines.slice(0, -1)) {
    if (line.startsWith('class=') && line.length > 6 && pending === null) {
      suite = line.slice(6);
    } else if (line.startsWith('test=') && line.length > 5 && suite && pending === null) {
      pending = suite + '\0' + line.slice(5); cases++;
      if (names.has(pending)) issues.push('duplicate suite/test result');
      names.add(pending);
    } else if (line === 'result=Success' && pending !== null) {
      successes++; pending = null;
    } else {
      issues.push('unrecognized, failed or unpaired case result');
      pending = null;
    }
  }
  if (pending !== null || cases !== counts.total || successes !== counts.pass) issues.push('case records do not match terminal counts');
  return { ok: issues.length === 0, issues: [...new Set(issues)], counts };
}

function optionsOf(argv) {
  const options = { command: [] };
  const allowed = new Set(['check-log', 'result', 'child-exit-code', 'expected-tests', 'project', 'output']);
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--') { options.command = argv.slice(i + 1); break; }
    const key = argv[i].replace(/^--/, '');
    if (!allowed.has(key) || !argv[i].startsWith('--') || !argv[i + 1] || argv[i + 1].startsWith('--')) {
      throw new Error('Invalid option; see scripts/HYPIUM_GATE.md');
    }
    options[key] = argv[++i];
  }
  for (const key of ['child-exit-code', 'expected-tests']) {
    if (options[key] !== undefined) {
      if (!/^\d+$/.test(options[key])) throw new Error('Invalid numeric option: ' + key);
      options[key] = Number(options[key]);
      if (!Number.isSafeInteger(options[key]) || (key === 'expected-tests' && options[key] < 1)) throw new Error('Invalid count');
    }
  }
  return options;
}

function fingerprint(file) {
  try {
    const stat = fs.statSync(file), bytes = fs.readFileSync(file);
    return { mtimeMs: stat.mtimeMs, size: stat.size, sha256: crypto.createHash('sha256').update(bytes).digest('hex') };
  } catch (e) {
    if (e.code === 'ENOENT') return null;
    throw e;
  }
}

async function main(argv) {
  const opt = optionsOf(argv);
  if (opt['check-log']) {
    if (opt.command.length) throw new Error('--check-log cannot launch a command');
    const result = opt.result ? readText(opt.result) : undefined;
    const verdict = checkEvidence(readText(opt['check-log']), result, opt['child-exit-code'], opt['expected-tests']);
    console.log(JSON.stringify({ mode: 'historical-paired-evidence', ...verdict }, null, 2));
    return verdict.ok ? 0 : 1;
  }
  if (!opt.command.length || opt['child-exit-code'] !== undefined) throw new Error('Run mode requires -- executable arguments; exit code is measured');
  const project = path.resolve(opt.project || path.join(__dirname, '..'));
  const resultFile = path.resolve(project, opt.result || 'entry/.test/default/intermediates/test/coverage_data/test_result.txt');
  const outputRoot = path.resolve(opt.output || path.join(project, 'test-results/hypium'));
  const runDir = path.join(outputRoot, new Date().toISOString().replace(/[:.]/g, '-') + '-' + crypto.randomUUID());
  fs.mkdirSync(runDir, { recursive: true });
  const before = fingerprint(resultFile), startedAt = Date.now();
  const logFile = path.join(runDir, 'hvigor.log'), fd = fs.openSync(logFile, 'wx');
  let spawnError = null;
  const status = await new Promise(resolve => {
    const child = spawn(opt.command[0], opt.command.slice(1), { cwd: project, shell: false, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    child.stdout.on('data', bytes => { fs.writeSync(fd, bytes); process.stdout.write(bytes); });
    child.stderr.on('data', bytes => { fs.writeSync(fd, bytes); process.stderr.write(bytes); });
    child.on('error', error => { spawnError = error.message; });
    child.on('close', (code, signal) => resolve({ code, signal }));
  });
  fs.closeSync(fd);
  const after = fingerprint(resultFile);
  let resultText;
  if (after) {
    resultText = readText(resultFile);
    fs.copyFileSync(resultFile, path.join(runDir, 'test_result.txt'));
  }
  const verdict = checkEvidence(fs.readFileSync(logFile, 'utf8'), resultText, status.code, opt['expected-tests']);
  if (spawnError || status.signal) verdict.issues.push('child did not terminate normally: ' + (spawnError || status.signal));
  if (!after || after.mtimeMs < startedAt - 2000 || (before && after.mtimeMs === before.mtimeMs && after.sha256 === before.sha256)) {
    verdict.issues.push('result is missing or was not refreshed by this run');
  }
  verdict.ok = verdict.issues.length === 0;
  const report = { ...verdict, command: opt.command, project, resultFile, runDir, startedAt, finishedAt: Date.now(), child: status, before, after };
  fs.writeFileSync(path.join(runDir, 'verdict.json'), JSON.stringify(report, null, 2) + '\n');
  console.log('\nHYPIUM_GATE ' + JSON.stringify({ ok: verdict.ok, counts: verdict.counts, issues: verdict.issues, runDir }));
  return verdict.ok ? 0 : 1;
}

module.exports = { normalizeLog, checkEvidence, readText, main };
if (require.main === module) main(process.argv.slice(2)).then(code => { process.exitCode = code; }).catch(error => { console.error('HYPIUM_GATE_ERROR ' + error.message); process.exitCode = 2; });
