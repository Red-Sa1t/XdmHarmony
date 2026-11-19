'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { checkEvidence, readText } = require('../../scripts/run-hypium.cjs');
const log = '> hvigor Finished :entry:default@GenerateUnitTestResult... after 1 ms\n' +
  '> hvigor Finished :entry:test... after 1 ms\n> hvigor BUILD SUCCESSFUL in 1 s\n';
const result = 'class=Suite\ntest=works\nresult=Success\nTests run: 1, Failure: 0, Error: 0, Pass: 1, Ignore: 0\n';

test('complete paired execution evidence passes, ANSI is accepted', () => {
  assert.equal(checkEvidence(log, result, 0, 1).ok, true);
  assert.equal(checkEvidence(log.replace('Finished', '\x1b[32mFinished'), result, 0).ok, true);
  assert.equal(checkEvidence(log.replace('Finished', '\\u001b[32mFinished'), result, 0).ok, true);
});
test('assertion error overrides BUILD SUCCESSFUL and child zero', () => {
  assert.equal(checkEvidence('ERROR: Error in someCase, expect 1 equals 2\n' + log, result, 0).ok, false);
});
test('PowerShell UTF-16 BOM log is decoded before validation', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'xdm-hypium-encoding-'));
  const file = path.join(dir, 'utf16.log');
  fs.writeFileSync(file, Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from(log, 'utf16le')]));
  assert.equal(checkEvidence(readText(file), result, 0).ok, true);
});
test('missing exit, missing result, incomplete log and repeated executions fail', () => {
  assert.equal(checkEvidence(log, result, undefined).ok, false);
  assert.equal(checkEvidence(log, undefined, 0).ok, false);
  assert.equal(checkEvidence('BUILD SUCCESSFUL', result, 0).ok, false);
  assert.equal(checkEvidence(log + log, result, 0).ok, false);
  assert.equal(checkEvidence(log, result, 3).ok, false);
});
test('zero tests, skipped cases, failure counts and mismatched expected count fail', () => {
  assert.equal(checkEvidence(log, 'Tests run: 0, Failure: 0, Error: 0, Pass: 0, Ignore: 0', 0).ok, false);
  assert.equal(checkEvidence(log, result.replace('Pass: 1, Ignore: 0', 'Pass: 0, Ignore: 1'), 0).ok, false);
  assert.equal(checkEvidence(log, result.replace('Failure: 0', 'Failure: 1'), 0).ok, false);
  assert.equal(checkEvidence(log, result, 0, 2).ok, false);
});
test('truncated, duplicate and forged summary-only results fail', () => {
  assert.equal(checkEvidence(log, result.split('Tests run:')[0], 0).ok, false);
  assert.equal(checkEvidence(log, result.split('\n').at(-2), 0).ok, false);
  assert.equal(checkEvidence(log, result.replace('result=Success', ''), 0).ok, false);
  assert.equal(checkEvidence(log, result + 'unexpected tail\n', 0).ok, false);
  const duplicate = result.replace('Tests run:', 'test=works\nresult=Success\nTests run:').replace('run: 1', 'run: 2').replace('Pass: 1', 'Pass: 2');
  assert.equal(checkEvidence(log, duplicate, 0).ok, false);
});

function launch(writeFresh, failAssertion) {
  const project = fs.mkdtempSync(path.join(os.tmpdir(), 'xdm-hypium-gate-'));
  const resultPath = path.join(project, 'test_result.txt');
  fs.writeFileSync(resultPath, result);
  const old = new Date(Date.now() - 60000); fs.utimesSync(resultPath, old, old);
  const child = path.join(project, 'fake-hvigor.cjs');
  fs.writeFileSync(child, `const fs=require('node:fs');\n${writeFresh ? `fs.writeFileSync(${JSON.stringify(resultPath)},${JSON.stringify(result)});` : ''}\nprocess.stdout.write(${JSON.stringify(log)});\n${failAssertion ? "process.stderr.write('ERROR: Error in fakeCase, expect 1 equals 2\\n');" : ''}`);
  const gate = path.resolve(__dirname, '../../scripts/run-hypium.cjs');
  const run = spawnSync(process.execPath, [gate, '--project', project, '--output', path.join(project, 'artifacts'),
    '--result', resultPath, '--expected-tests', '1', '--', process.execPath, child], { encoding: 'utf8', windowsHide: true });
  const runDir = path.join(project, 'artifacts', fs.readdirSync(path.join(project, 'artifacts'))[0]);
  const verdict = JSON.parse(fs.readFileSync(path.join(runDir, 'verdict.json')));
  assert.equal(fs.existsSync(path.join(runDir, 'hvigor.log')), true);
  assert.equal(fs.existsSync(path.join(runDir, 'test_result.txt')), true);
  return { run, verdict };
}
test('wrapper measures child exit and preserves fresh successful evidence', () => {
  const { run, verdict } = launch(true, false);
  assert.equal(run.status, 0, run.stderr); assert.equal(verdict.ok, true);
});
test('wrapper rejects stale prior result despite successful child', () => {
  const { run, verdict } = launch(false, false);
  assert.equal(run.status, 1); assert.match(verdict.issues.join(' '), /not refreshed/);
});
test('wrapper sees stderr assertion even when child exits zero', () => {
  const { run, verdict } = launch(true, true);
  assert.equal(run.status, 1); assert.equal(verdict.child.code, 0); assert.equal(verdict.ok, false);
});
