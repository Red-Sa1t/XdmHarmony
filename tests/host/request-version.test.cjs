'use strict';
// Executes production ETS through TS transpilation and SQL through Python's real SQLite.
// Platform admission is mocked; this does not replace Harmony RdbStore/device acceptance.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { spawn } = require('node:child_process');
const readline = require('node:readline');
const crypto = require('node:crypto');
const ts = require(process.env.XDM_TYPESCRIPT_PATH || 'D:/Tools/DevEco Studio/tools/ohpm/node_modules/typescript/lib/typescript.js');
const root = path.resolve(__dirname, '../../entry/src/main/ets');
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'xdm-version-test-'));
const database = path.join(work, 'downloads.db');
const python = spawn(process.env.XDM_PYTHON || 'python', [path.join(__dirname, 'sqlite-bridge.py'), database], { windowsHide: true, stdio: ['pipe', 'pipe', 'inherit'] });
let nextId = 1, tail = Promise.resolve(), failure = '';
const requests = new Map();
readline.createInterface({ input: python.stdout }).on('line', line => {
  const message = JSON.parse(line), pending = requests.get(message.id); requests.delete(message.id);
  if (message.error) pending.reject(new Error(message.error)); else pending.resolve(message.rows);
});
python.on('error', error => { for (const pending of requests.values()) pending.reject(error); requests.clear(); });
function sql(text, args = []) {
  if (failure && text.includes(failure)) { failure = ''; return Promise.reject(new Error('injected SQL failure')); }
  const id = nextId++;
  return new Promise((resolve, reject) => { requests.set(id, { resolve, reject }); python.stdin.write(JSON.stringify({ id, sql: text, args }) + '\n'); });
}
async function lock() { const previous = tail; let release; tail = new Promise(resolve => { release = resolve; }); await previous; return release; }
class ResultSet {
  constructor(rows) { this.rows = rows; this.position = -1; }
  goToNextRow() { return ++this.position < this.rows.length; }
  getColumnIndex(name) { assert.ok(Object.hasOwn(this.rows[this.position], name)); return name; }
  isColumnNull(name) { return this.rows[this.position][name] === null; }
  getString(name) { return this.rows[this.position][name]; }
  getLong(name) { return this.rows[this.position][name]; }
  close() {}
}
const rdb = {
  async executeSql(text, args) { const release = await lock(); try { await sql(text, args); } finally { release(); } },
  async querySql(text, args) { const release = await lock(); try { return new ResultSet(await sql(text, args)); } finally { release(); } },
  async createTransaction() {
    const release = await lock();
    try { await sql('BEGIN IMMEDIATE'); } catch (error) { release(); throw error; }
    return {
      execute: (text, args) => sql(text, args),
      querySql: async (text, args) => new ResultSet(await sql(text, args)),
      commit: async () => { await sql('COMMIT'); release(); },
      rollback: async () => { try { await sql('ROLLBACK'); } finally { release(); } }
    };
  }
};
const sequence = [], active = new Set();
let managerReady = false;
const manager = { isReady: () => managerReady, isLive: id => active.has(id), isQueued: () => false,
  admitNew(record) { sequence.push('admit:' + record.id); active.add(record.id); } };
const mocks = {
  '@kit.ArkData': { relationalStore: { SecurityLevel: { S1: 1 }, TransactionType: { IMMEDIATE: 1 }, getRdbStore: async () => rdb } },
  '@kit.ArkTS': { util: { generateRandomUUID: () => crypto.randomUUID() } },
  '@kit.PerformanceAnalysisKit': { hilog: { error() {}, info() {} } }
};
const cache = new Map();
function load(relative) {
  const file = path.resolve(root, relative.endsWith('.ets') ? relative : relative + '.ets');
  if (cache.has(file)) return cache.get(file).exports;
  const compiled = ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, experimentalDecorators: true } }).outputText;
  const mod = { exports: {} }; cache.set(file, mod);
  const requireLocal = name => {
    if (Object.hasOwn(mocks, name)) return mocks[name];
    if (name.endsWith('/DownloadManager')) return { DownloadManager: { getInstance: () => manager } };
    if (name.endsWith('/Config')) return { Config: { getInstance: () => ({ getDownloadDir: () => '/mock/downloads' }) } };
    if (!name.startsWith('.')) throw new Error('Unmocked import ' + name);
    return load(path.resolve(path.dirname(file), name));
  };
  vm.runInThisContext(`(function(require,module,exports,Observed){${compiled}\n})`, { filename: file })(requireLocal, mod, mod.exports, value => value);
  return mod.exports;
}
let count = 0;
async function check(name, body) { await body(); count++; console.log('ok ' + name); }
async function main() {
  const { DownloadStore } = load('core/db/DownloadStore');
  const { newDownloadRecord } = load('model/DownloadRecord');
  const { DownloadRequestContext } = load('model/DownloadRequestContext');
  const state = load('core/engine/DownloadRequestState');
  let store = DownloadStore.getInstance();
  await store.initialize({});
  const context = cookie => { const c = new DownloadRequestContext(); c.cookies = cookie; c.headers = { names: ['X-Test'], values: [[cookie]] }; return c; };
  const create = async id => { const r = newDownloadRecord(id, '/downloads', 12, 'Http', 'https://old/' + id, false, null, null); r.id = id; r.requestContext = context('old'); assert.equal(await store.add(r), true); return r; };
  await check('legacy-schema-default-revision-and-22-columns', async () => {
    assert.equal((await sql('PRAGMA table_info(downloads)')).length, 22);
    await sql("INSERT INTO downloads(id,primary_url) VALUES('legacy','https://legacy')");
    const old = await store.getDownloadById('legacy'); assert.equal(old.requestRevision,0);
    assert.equal(state.resolveRunRequest(old).url, 'https://legacy');
  });
  const record = await create('target');
  await check('refresh-commits-complete-snapshot-and-resolver-upgrades-stale-record', async () => {
    const input = context('fresh'); const p=store.refreshCommittedRequest(record.id,'https://new/target',input);
    input.headers.values[0][0]='mutated'; input.cookies='mutated';
    const snapshot=await p; assert.equal(snapshot.revision,1); assert.equal(snapshot.context.cookies,'fresh');
    assert.equal(snapshot.context.headers.values[0][0],'fresh');
    snapshot.context.cookies='returned-mutated';
    const run=state.resolveRunRequest(record); assert.equal(run.revision,1); assert.equal(run.context.cookies,'fresh');
    run.context.headers.values[0][0]='run-mutated'; assert.equal(state.resolveRunRequest(record).context.headers.values[0][0],'fresh');
    const read=await store.getDownloadById(record.id); assert.equal(read.primaryUrl,'https://new/target'); assert.equal(read.name,'target'); assert.equal(read.size,12);
  });
  await check('stale-whole-entry-CAS-rejects-without-context-or-metadata-overwrite', async () => {
    record.name='stale-name'; assert.equal(await store.updateDownloadEntry(record),false);
    const read=await store.getDownloadById(record.id); assert.equal(read.name,'target'); assert.equal(read.requestRevision,1); assert.equal(read.requestContext.cookies,'fresh');
  });
  await check('current-whole-entry-write-increments-and-publishes', async () => {
    const read=await store.getDownloadById(record.id); read.name='renamed'; read.primaryUrl='https://edited'; read.requestContext=context('edited');
    assert.equal(await store.updateDownloadEntry(read),true); assert.equal(read.requestRevision,2);
    assert.equal(state.resolveRunRequest(record).url,'https://edited');
  });
  await check('real-sqlite-trigger-failure-rolls-back-refresh-and-publication', async () => {
    await sql("CREATE TRIGGER fail_revision BEFORE INSERT ON download_request_revision WHEN NEW.id='target' BEGIN SELECT RAISE(ABORT,'revision failed'); END");
    assert.equal(await store.refreshCommittedRequest('target','https://failure',context('failure')),null);
    const read=await store.getDownloadById('target'); assert.equal(read.primaryUrl,'https://edited'); assert.equal(read.requestRevision,2);
    assert.equal(state.resolveRunRequest(record).context.cookies,'edited'); await sql('DROP TRIGGER fail_revision');
  });
  await check('two-concurrent-refreshes-linearize-and-never-publish-backwards', async () => {
    const results=await Promise.all([store.refreshCommittedRequest('target','https://r3',context('r3')),store.refreshCommittedRequest('target','https://r4',context('r4'))]);
    assert.deepEqual(results.map(r=>r.revision),[3,4]);
    state.publishCommittedRequest('target',results[0]); assert.equal(state.resolveRunRequest(record).revision,4);
    assert.equal((await store.getDownloadById('target')).requestRevision,4);
  });
  await check('two-whole-entry-writers-one-CAS-winner', async () => {
    const a=await store.getDownloadById('target'), b=await store.getDownloadById('target'); a.name='a'; b.name='b';
    const results=await Promise.all([store.updateDownloadEntry(a),store.updateDownloadEntry(b)]);
    assert.deepEqual(results,[true,false]); assert.equal((await store.getDownloadById('target')).name,'a');
  });
  await check('request-unrelated-writes-preserve-revision', async () => {
    await store.updateProgress('target',34); await store.updateStatus('target',1); await store.markAsFinished('target',12,'final','/done');
    assert.equal((await store.getDownloadById('target')).requestRevision,5);
  });
  await check('reopen-store-retains-revision-and-context', async () => {
    DownloadStore.instance=undefined; store=DownloadStore.getInstance(); await store.initialize({});
    const read=await store.getDownloadById('target'); assert.equal(read.requestRevision,5); assert.equal(read.requestContext.cookies,'r4');
  });
  await check('remove-tombstone-blocks-late-read-publication-and-refresh-resurrection', async () => {
    const before=await store.getDownloadById('target'); const snapshot=state.resolveRunRequest(before);
    assert.equal(await store.remove('target'),true); state.publishCommittedRequest('target',snapshot);
    assert.throws(()=>state.resolveRunRequest(before),/deleted/);
    assert.equal(await store.refreshCommittedRequest('target','https://resurrect',context('bad')),null);
    assert.equal(await store.getDownloadById('target'),null);
    assert.equal((await sql("SELECT * FROM download_request_revision WHERE id='target'")).length,0);
  });
  await check('revision-overflow-fails-atomically', async () => {
    const r=await create('overflow'); await sql('UPDATE download_request_revision SET revision=? WHERE id=?',[Number.MAX_SAFE_INTEGER,r.id]);
    assert.equal(await store.refreshCommittedRequest(r.id,'https://overflow',context('bad')),null);
    const read=await store.getDownloadById(r.id); assert.equal(read.primaryUrl,r.primaryUrl);
  });
  await check('caller-invented-higher-revision-cannot-override-committed-transport', async () => {
    const original=await create('forged-input');
    await store.refreshCommittedRequest(original.id,'https://new/target',context('fresh'));
    const forged=await store.getDownloadById(original.id);
    forged.requestRevision=999; forged.primaryUrl='https://uncommitted'; forged.requestContext=context('uncommitted');
    const resolved=state.resolveRunRequest(forged);
    assert.equal(resolved.revision,1); assert.equal(resolved.url,'https://new/target');
    assert.equal(resolved.context.cookies,'fresh');
    assert.equal(await store.updateDownloadEntry(forged),false);
  });
  await check('real-delayed-read-after-delete-cannot-resurrect-run-input', async () => {
    const r=await create('late-read');
    const original=rdb.querySql; let release, reached;
    const waiting=new Promise(resolve=>{ release=resolve; });
    const entered=new Promise(resolve=>{ reached=resolve; });
    rdb.querySql=async (query,args)=>{ const rows=await original(query,args); reached(); await waiting; return rows; };
    const reading=store.getDownloadById(r.id); await entered;
    rdb.querySql=original;
    assert.equal(await store.remove(r.id),true); release();
    const stale=await reading; assert.ok(stale);
    assert.throws(()=>state.resolveRunRequest(stale),/deleted/);
  });
  await check('real-delayed-read-after-refresh-cannot-downgrade-run-input', async () => {
    const r=await create('late-refresh-read');
    const original=rdb.querySql; let release, reached;
    const waiting=new Promise(resolve=>{ release=resolve; });
    const entered=new Promise(resolve=>{ reached=resolve; });
    rdb.querySql=async (query,args)=>{ const rows=await original(query,args); reached(); await waiting; return rows; };
    const reading=store.getDownloadById(r.id); await entered; rdb.querySql=original;
    await store.refreshCommittedRequest(r.id,'https://latest',context('latest')); release();
    const stale=await reading; assert.equal(stale.requestRevision,0);
    assert.equal(state.resolveRunRequest(stale).url,'https://latest');
  });
  await check('whole-entry-revision-failure-rolls-back-all-fields', async () => {
    const r=await create('entry-fault');
    await sql("CREATE TRIGGER fail_entry_revision BEFORE INSERT ON download_request_revision WHEN NEW.id='entry-fault' BEGIN SELECT RAISE(ABORT,'revision failed'); END");
    r.name='bad'; r.primaryUrl='https://bad'; r.requestContext=context('bad');
    assert.equal(await store.updateDownloadEntry(r),false);
    const saved=await store.getDownloadById(r.id); assert.equal(saved.name,'entry-fault'); assert.equal(saved.requestRevision,0);
    assert.equal(state.resolveRunRequest(saved).context.cookies,'old'); await sql('DROP TRIGGER fail_entry_revision');
  });
  console.log(`SUMMARY tests=${count} fail=0 scope=production-request-version-real-SQLite`);
}
main().catch(error => { console.error(error); process.exitCode = 1; }).finally(() => {
  python.stdin.end(); python.once('exit', () => {
    const resolved = path.resolve(work), tempRoot = path.resolve(os.tmpdir()) + path.sep;
    assert.ok(resolved.startsWith(tempRoot) && path.basename(resolved).startsWith('xdm-version-test-'));
    fs.rmSync(resolved, { recursive: true, force: true });
  });
});
