/* Executes production .ets modules through TypeScript transpilation; no copied business algorithm.
 * Fake RelationalStore verifies Store transaction/control flow, NOT Harmony SDK or real disk durability.
 * Usage: node docs/probe/P6-U3-request-context-host.cjs [path/to/typescript.js]
 */
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const ts = require(process.argv[2] || 'D:/Tools/DevEco Studio/tools/ohpm/node_modules/typescript/lib/typescript.js');
const root = path.resolve(__dirname, '../..');
let total = 0;
const pending = [];
const columns = 'id completed name date_added size status progress download_type filenamefetchmode maxspeedlimitinkib targetdir primary_url referer_url auth user pass proxy proxy_host proxy_port proxy_user proxy_pass proxy_type'.split(' ');
class ResultSet {
  constructor(rows) { this.rows = rows; this.index = -1; this.closed = false; }
  goToNextRow() { assert.equal(this.closed, false); return ++this.index < this.rows.length; }
  getColumnIndex(name) { assert.ok(name in this.rows[this.index], `Missing column ${name}`); return name; }
  isColumnNull(name) { return this.rows[this.index][name] == null; }
  getString(name) { return this.rows[this.index][name]; }
  getLong(name) { return this.rows[this.index][name]; }
  close() { this.closed = true; }
}
class FakeRdb {
  constructor() { this.rows = new Map(); this.contexts = new Map(); this.failOn = ''; this.rollbacks = 0; this.ddl = []; }
  async executeSql(sql, args = []) {
    if (sql.startsWith('CREATE TABLE')) { this.ddl.push(sql); return; }
    return this.apply(this.rows, this.contexts, sql, args);
  }
  apply(rows, contexts, sql, args) {
    if (this.failOn && sql.includes(this.failOn)) { this.failOn = ''; throw new Error('injected storage failure'); }
    if (sql.startsWith('INSERT INTO downloads(')) {
      assert.ok(!rows.has(args[0]), 'duplicate primary key');
      rows.set(args[0], Object.fromEntries(columns.map((key, i) => [key, args[i]]))); return;
    }
    if (sql.startsWith('INSERT OR REPLACE INTO download_request_context')) {
      if (rows.has(args[1])) contexts.set(args[1], args[0]); return;
    }
    if (sql.startsWith('INSERT OR REPLACE INTO download_request_revision')) {
      if (rows.has(args[0])) rows.get(args[0]).request_revision = args[1]; return;
    }
    if (sql.startsWith('DELETE FROM download_request_revision')) {
      if (rows.has(args[0])) delete rows.get(args[0]).request_revision; return;
    }
    if (sql.startsWith('DELETE FROM download_request_context')) { contexts.delete(args[0]); return; }
    if (sql.startsWith('DELETE FROM downloads')) { rows.delete(args[0]); return; }
    if (sql.startsWith('UPDATE downloads SET')) {
      const keys = sql.slice('UPDATE downloads SET '.length).split(' WHERE')[0].split(',').map(x => x.trim().split('=')[0]);
      const row = rows.get(args[args.length - 1]);
      if (row) keys.forEach((key, i) => { row[key] = args[i]; });
      return;
    }
    throw new Error(`Unhandled SQL ${sql}`);
  }
  query(rows, contexts, sql, args = []) {
    let values = [...rows.values()];
    if (sql.includes('WHERE downloads.id=?') || sql.includes('WHERE id=?')) values = values.filter(r => r.id === args[0]);
    if (sql.includes('WHERE downloads.completed=?')) values = values.filter(r => r.completed === args[0]);
    return new ResultSet(values.map(row => ({ ...row, request_revision: row.request_revision ?? 0,
      request_context_payload: contexts.get(row.id) ?? null })));
  }
  async querySql(sql, args) { return this.query(this.rows, this.contexts, sql, args); }
  async createTransaction() {
    const rows = structuredClone(this.rows), contexts = structuredClone(this.contexts);
    return {
      execute: async (sql, args) => this.apply(rows, contexts, sql, args),
      querySql: async (sql, args) => this.query(rows, contexts, sql, args),
      commit: async () => { if (this.failOn === 'COMMIT') { this.failOn = ''; throw new Error('commit failure'); } this.rows = rows; this.contexts = contexts; },
      rollback: async () => { this.rollbacks++; }
    };
  }
}
const db = new FakeRdb();
const mocks = {
  '@kit.ArkData': { relationalStore: { SecurityLevel: { S1: 1 }, TransactionType: { IMMEDIATE: 1 }, getRdbStore: async () => db } },
  '@kit.ArkTS': { util: { generateRandomUUID: () => crypto.randomUUID() } },
  '@kit.PerformanceAnalysisKit': { hilog: { error() {}, info() {} } },
  '@ohos/hypium': {
    describe: (_name, fn) => fn(),
    it: (name, _flags, fn) => { pending.push({ name, fn }); },
    expect: value => ({ assertEqual: expected => assert.equal(value, expected), assertTrue: () => assert.equal(value, true) })
  }
};
const cache = new Map();
function load(file) {
  if (cache.has(file)) return cache.get(file).exports;
  const source = fs.readFileSync(file, 'utf8');
  const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, experimentalDecorators: true } }).outputText;
  const mod = { exports: {} }; cache.set(file, mod);
  const localRequire = name => {
    if (name in mocks) return mocks[name];
    if (!name.startsWith('.')) throw new Error(`Unmocked runtime dependency ${name}`);
    return load(path.resolve(path.dirname(file), name + '.ets'));
  };
  vm.runInThisContext(`(function(require,module,exports,Observed){${compiled}\n})`, { filename: file })(localRequire, mod, mod.exports, value => value);
  return mod.exports;
}
async function check(name, fn) { await fn(); total++; console.log(`ok ${name}`); }
async function main() {
  load(path.join(root, 'entry/src/test/DownloadRequestContext.test.ets')).default();
  for (const test of pending) await check(test.name, test.fn);
  const { DownloadStore } = load(path.join(root, 'entry/src/main/ets/core/db/DownloadStore.ets'));
  const { newDownloadRecord } = load(path.join(root, 'entry/src/main/ets/model/DownloadRecord.ets'));
  const { DownloadRequestContext } = load(path.join(root, 'entry/src/main/ets/model/DownloadRequestContext.ets'));
  const store = DownloadStore.getInstance(); await store.initialize({});
  const make = id => { const r = newDownloadRecord('test.bin', '/tmp', 32, 'Http', 'https://host/old', true, null, null); r.id = id; r.requestContext.cookies = 'sid=test'; r.requestContext.headers = { names: ['Referer'], values: [['https://origin/']] }; return r; };
  await check('addAndReloadContextAnd22ColumnMigration', async () => {
    assert.equal(columns.length, 22); assert.equal(db.ddl.length, 4);
    assert.ok(db.ddl[0].includes('proxy_type INT) WITHOUT ROWID'));
    assert.equal(await store.add(make('one')), true);
    const restored = await store.getDownloadById('one'); assert.equal(restored.requestContext.cookies, 'sid=test');
    assert.deepEqual(restored.requestContext.headers.values, [['https://origin/']]);
    assert.equal(restored.status, 1);
  });
  await check('legacyRowGetsNullContextAndAllQueriesHydrate', async () => {
    const old = structuredClone(db.rows.get('one')); old.id = 'legacy'; db.rows.set('legacy', old);
    assert.equal((await store.getDownloadById('legacy')).requestContext.headers, null);
    assert.equal((await store.queryAll()).inProgress.find(r => r.id === 'one').requestContext.cookies, 'sid=test');
    assert.equal((await store.queryInProgress()).find(r => r.id === 'one').requestContext.cookies, 'sid=test');
    await store.markAsFinished('one', 32, 'test.bin', '/tmp');
    assert.equal((await store.queryFinished())[0].requestContext.cookies, 'sid=test');
  });
  await check('insertContextFailureRollsBackDownload', async () => {
    db.failOn = 'INSERT OR REPLACE'; assert.equal(await store.add(make('fail')), false);
    assert.equal(db.rows.has('fail'), false); assert.equal(db.contexts.has('fail'), false);
  });
  await check('refreshIsAtomicAndPreservesOriginalOnFailure', async () => {
    const context = new DownloadRequestContext(); context.cookies = 'sid=new';
    db.failOn = 'INSERT OR REPLACE'; assert.equal(await store.refreshRequestContext('one', 'https://host/new', context), false);
    assert.equal(db.rows.get('one').primary_url, 'https://host/old');
    assert.equal((await store.getDownloadById('one')).requestContext.cookies, 'sid=test');
    assert.equal(await store.refreshRequestContext('one', 'https://host/new', context), true);
    assert.equal((await store.getDownloadById('one')).requestContext.cookies, 'sid=new');
    assert.equal(db.rows.get('one').primary_url, 'https://host/new');
    assert.equal(await store.refreshRequestContext('missing', 'https://host/new', context), false);
    assert.equal(db.contexts.has('missing'), false);
  });
  await check('updateEntryContextFailureRollsBackMetadata', async () => {
    const r = await store.getDownloadById('one'); r.primaryUrl = 'https://host/replaced'; r.requestContext.cookies = 'sid=replaced';
    db.failOn = 'INSERT OR REPLACE'; assert.equal(await store.updateDownloadEntry(r), false);
    assert.equal(db.rows.get('one').primary_url, 'https://host/new');
    assert.equal(await store.updateDownloadEntry(r), true);
    assert.equal((await store.getDownloadById('one')).requestContext.cookies, 'sid=replaced');
  });
  await check('deleteFailureRestoresContextAndCommitFailureRollsBack', async () => {
    db.failOn = 'DELETE FROM downloads'; assert.equal(await store.remove('one'), false);
    assert.equal(db.contexts.has('one'), true); assert.equal(db.rows.has('one'), true);
    db.failOn = 'COMMIT'; assert.equal(await store.add(make('commit-fail')), false);
    assert.equal(db.rows.has('commit-fail'), false);
    assert.equal(await store.remove('one'), true); assert.equal(db.contexts.has('one'), false);
    assert.equal(db.rows.has('one'), false); assert.ok(db.rollbacks >= 6);
  });
  await check('corruptedPayloadDoesNotFallBackToEmptyCredentials', async () => {
    db.contexts.set('legacy', '{}'); assert.equal(await store.getDownloadById('legacy'), null);
  });
  await check('corruptFirstRowDoesNotHideHealthyRowsFromAnyList', async () => {
    assert.equal(await store.add(make('healthy-after-corrupt')), true);
    assert.equal(await store.add(make('healthy-finished-after-corrupt')), true);
    await store.markAsFinished('healthy-finished-after-corrupt', 32, 'test.bin', '/tmp');
    assert.ok((await store.queryAll()).inProgress.some(r => r.id === 'healthy-after-corrupt'));
    assert.ok((await store.queryInProgress()).some(r => r.id === 'healthy-after-corrupt'));
    await store.markAsFinished('legacy', 32, 'test.bin', '/tmp');
    assert.ok((await store.queryAll()).finished.some(r => r.id === 'healthy-finished-after-corrupt'));
    assert.ok((await store.queryFinished()).some(r => r.id === 'healthy-finished-after-corrupt'));
    assert.equal((await store.queryAll()).finished.some(r => r.id === 'legacy'), false);
  });
  console.log(`SUMMARY tests=${total} fail=0 scope=production-ETS-with-mocked-SDK`);
}
main().catch(error => { console.error(error); process.exitCode = 1; });
