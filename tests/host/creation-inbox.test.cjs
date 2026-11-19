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
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'xdm-inbox-test-'));
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
  const { DownloadCreationRequest, BridgeInboxItem } = load('model/DownloadCreationRequest');
  const { DownloadCreationService } = load('core/engine/DownloadCreationService');
  const { BridgeInbox } = load('core/bridge/BridgeInbox');
  const { newDownloadRecord } = load('model/DownloadRecord');
  const store = DownloadStore.getInstance(), service = DownloadCreationService.getInstance(), inbox = BridgeInbox.getInstance();
  await store.initialize({}); await inbox.initialize();
  const request = (name = 'file.bin') => { const r = new DownloadCreationRequest(); r.name = name; r.url = 'https://host/' + name; r.contextUrl = r.url; r.requestContext.cookies = 'sid=' + name; return r; };
  const item = id => { const i = new BridgeInboxItem(); i.id = id; i.requests = [request(id)]; return i; };
  const added = record => sequence.push('added:' + record.id); service.subscribeAdded(added);
  await check('durable-create-before-added-and-ready-admission', async () => {
    const release = await lock(); const promise = service.create(request());
    await new Promise(resolve => setImmediate(resolve)); assert.equal(sequence.length, 0); release();
    const record = await promise;
    assert.equal(service.getPendingAdmissions()[0], record);
    assert.ok(await store.getDownloadById(record.id)); assert.deepEqual(sequence, ['added:' + record.id]);
    service.setAdmissionReady(true); assert.equal(active.size, 0);
    managerReady = true; service.drainAdmissions(); service.drainAdmissions();
    assert.deepEqual(sequence, ['added:' + record.id, 'admit:' + record.id]);
  });
  await check('later-and-edited-url-do-not-admit-or-leak-captured-context', async () => {
    const r = request('later'); r.startImmediately = false; r.url = 'https://other/file';
    const record = await service.create(r); assert.equal(record.requestContext.cookies, null);
    assert.equal(record.requestContext.headers, null); assert.equal(active.has(record.id), false);
    assert.equal((await store.getDownloadById(record.id)).requestContext.cookies, null);
  });
  await check('inbox-ack-after-real-sqlite-commit-and-clone-isolation', async () => {
    const release = await lock(); const input = item('manual'); const promise = inbox.enqueue(input);
    input.requests[0].requestContext.cookies = 'mutated';
    await new Promise(resolve => setImmediate(resolve)); assert.equal(inbox.getPending().length, 0); release();
    const accepted = await promise;
    assert.equal((await store.queryBridgeInbox())[0].requests[0].requestContext.cookies, 'sid=manual');
    accepted.requests[0].requestContext.cookies = 'mutated-again';
    assert.equal(inbox.peekNext().requests[0].requestContext.cookies, 'sid=manual');
    assert.equal(inbox.claim('manual'), true); assert.equal(inbox.peekNext(), null); inbox.release('manual');
  });
  await check('concurrent-confirm-promotes-once-and-removes-inbox', async () => {
    const input = inbox.peekNext();
    const before = sequence.length;
    const results = await Promise.all([inbox.confirm(input.id, input.requests), inbox.confirm(input.id, input.requests)]);
    assert.equal(results[0][0].id, results[1][0].id);
    assert.equal(sequence.length - before, 2); assert.equal(inbox.getPending().length, 0);
    assert.equal((await store.queryBridgeInbox()).length, 0);
    await assert.rejects(inbox.confirm(input.id, input.requests));
  });
  await check('batch-second-record-failure-rolls-back-all-records-and-retains-inbox', async () => {
    const input = item('batch'); input.kind = 'batch'; input.requests.push(request('second'));
    await inbox.enqueue(input);
    const before = (await sql('SELECT count(*) AS n FROM downloads'))[0].n;
    await sql("CREATE TRIGGER reject_second BEFORE INSERT ON downloads WHEN NEW.name='second' BEGIN SELECT RAISE(ABORT,'test'); END");
    await assert.rejects(inbox.confirm('batch', input.requests));
    assert.equal((await sql('SELECT count(*) AS n FROM downloads'))[0].n, before);
    assert.equal((await store.queryBridgeInbox()).length, 1); assert.equal(inbox.getPending().length, 1);
    await sql('DROP TRIGGER reject_second');
    const records = await inbox.confirm('batch', input.requests); assert.equal(records.length, 2);
    assert.notEqual(records[0].requestContext.cookies, records[1].requestContext.cookies);
  });
  await check('inbox-delete-failure-rolls-back-promoted-download', async () => {
    const input = await inbox.enqueue(item('delete-fails'));
    const before = (await sql('SELECT count(*) AS n FROM downloads'))[0].n;
    await sql("CREATE TRIGGER reject_consume BEFORE DELETE ON bridge_inbox BEGIN SELECT RAISE(ABORT,'test'); END");
    await assert.rejects(inbox.confirm(input.id, input.requests));
    assert.equal((await sql('SELECT count(*) AS n FROM downloads'))[0].n, before);
    await assert.rejects(inbox.cancel(input.id)); assert.equal(inbox.getPending().length, 1);
    await sql('DROP TRIGGER reject_consume'); await inbox.cancel(input.id);
    assert.equal(inbox.getPending().length, 0); assert.equal((await store.queryBridgeInbox()).length, 0);
  });
  await check('context-insert-failure-keeps-inbox-and-rolls-back-download', async () => {
    const input = await inbox.enqueue(item('context-fails'));
    const before = (await sql('SELECT count(*) AS n FROM downloads'))[0].n;
    await sql("CREATE TRIGGER reject_context BEFORE INSERT ON download_request_context BEGIN SELECT RAISE(ABORT,'test'); END");
    await assert.rejects(inbox.confirm(input.id, input.requests));
    assert.equal((await sql('SELECT count(*) AS n FROM downloads'))[0].n, before);
    assert.equal(inbox.peekNext().id, input.id);
    await sql('DROP TRIGGER reject_context'); await inbox.cancel(input.id);
  });
  await check('confirm-cancel-race-has-one-owner', async () => {
    const input = await inbox.enqueue(item('confirm-cancel'));
    const release = await lock(); const confirmed = inbox.confirm(input.id, input.requests);
    await assert.rejects(inbox.cancel(input.id)); release(); await confirmed;
    assert.equal(inbox.getPending().length, 0);
    const canceled = await inbox.enqueue(item('cancel-confirm'));
    const release2 = await lock(); const removed = inbox.cancel(canceled.id);
    await assert.rejects(inbox.confirm(canceled.id, canceled.requests)); release2(); await removed;
    assert.equal(inbox.getPending().length, 0);
  });
  await check('release-during-failed-confirm-unblocks-next-page-only-after-settlement', async () => {
    const input = await inbox.enqueue(item('release-confirm')); assert.equal(inbox.claim(input.id), true);
    let changes = 0; const listener = () => { changes++; }; inbox.subscribeChanged(listener);
    const release = await lock(); failure = 'INSERT INTO downloads';
    const operation = inbox.confirm(input.id, input.requests); inbox.release(input.id);
    assert.equal(inbox.peekNext(), null); release(); await assert.rejects(operation);
    assert.equal(inbox.peekNext().id, input.id); assert.ok(changes > 0);
    inbox.unsubscribeChanged(listener); await inbox.cancel(input.id);
  });
  await check('release-during-failed-cancel-unblocks-next-page-only-after-settlement', async () => {
    const input = await inbox.enqueue(item('release-cancel')); assert.equal(inbox.claim(input.id), true);
    const release = await lock(); failure = 'DELETE FROM bridge_inbox';
    const operation = inbox.cancel(input.id); inbox.release(input.id);
    assert.equal(inbox.peekNext(), null); release(); await assert.rejects(operation);
    assert.equal(inbox.peekNext().id, input.id); await inbox.cancel(input.id);
  });
  await check('direct-concurrent-store-promotion-has-one-winner', async () => {
    const input = item('store-race'); input.createdAt = Date.now(); assert.equal(await store.saveBridgeInbox(input), true);
    const make = () => newDownloadRecord('race', '/mock', 1, 'Http', 'https://host/race', true, null, null);
    const results = await Promise.all([store.promoteBridgeInbox(input.id, [make()]), store.promoteBridgeInbox(input.id, [make()])]);
    assert.equal(results.filter(Boolean).length, 1);
  });
  const { AdaptiveSourceDescriptor } = load('model/AdaptiveSource');
  const dash = (manifest = 'https://cdn/a.mpd') => Object.assign(new AdaptiveSourceDescriptor(), { kind: 'dash', primaryUrl: manifest,
    videoSegments: ['https://cdn/v1.m4s', 'https://cdn/v2.m4s'], audioSegments: ['https://cdn/a1.m4s'],
    videoMime: 'video/mp4', audioMime: 'audio/mp4', duration: 12 });
  const videoItem = (id, adaptive) => { const i = item(id); i.kind = 'video'; i.videoKind = 'dash'; i.requests[0].adaptive = adaptive; return i; };
  await check('adaptive-video-inbox-promotes-captured-descriptor-and-reloads-it', async () => {
    const input = await inbox.enqueue(videoItem('dash-video', dash()));
    const edited = input.requests.map(r => Object.assign(r, { name: 'renamed.mp4', adaptive: dash('https://evil/other.mpd') }));
    const records = await inbox.confirm(input.id, edited);
    assert.equal(records[0].downloadType, 'Dash');
    assert.equal(records[0].adaptiveSource.primaryUrl, 'https://cdn/a.mpd', 'caller cannot substitute the captured source');
    const loaded = await store.getDownloadById(records[0].id);
    assert.equal(loaded.downloadType, 'Dash'); assert.equal(loaded.name, 'renamed.mp4');
    assert.deepEqual(loaded.adaptiveSource.videoSegments, ['https://cdn/v1.m4s', 'https://cdn/v2.m4s']);
    assert.equal((await sql('SELECT count(*) AS n FROM download_adaptive_source WHERE id=?', [records[0].id]))[0].n, 1);
    assert.equal(await store.remove(records[0].id), true);
    assert.equal((await sql('SELECT count(*) AS n FROM download_adaptive_source WHERE id=?', [records[0].id]))[0].n, 0);
  });
  await check('video-inbox-without-adaptive-descriptor-stays-unsupported', async () => {
    const input = await inbox.enqueue(videoItem('no-descriptor', null));
    await assert.rejects(inbox.confirm(input.id, input.requests));
    await inbox.cancel(input.id);
  });
  await check('adaptive-source-insert-failure-rolls-back-the-download', async () => {
    const input = await inbox.enqueue(videoItem('source-fails', dash()));
    const before = (await sql('SELECT count(*) AS n FROM downloads'))[0].n;
    await sql("CREATE TRIGGER reject_source BEFORE INSERT ON download_adaptive_source BEGIN SELECT RAISE(ABORT,'test'); END");
    await assert.rejects(inbox.confirm(input.id, input.requests));
    assert.equal((await sql('SELECT count(*) AS n FROM downloads'))[0].n, before);
    await sql('DROP TRIGGER reject_source'); await inbox.cancel(input.id);
  });
  await check('corrupt-adaptive-descriptor-loads-row-without-source', async () => {
    const record = await service.create(Object.assign(request('dash-direct'), { adaptive: dash() }));
    assert.equal(record.downloadType, 'Dash');
    await sql('UPDATE download_adaptive_source SET payload=? WHERE id=?', ['{"schema":9}', record.id]);
    const loaded = await store.getDownloadById(record.id);
    assert.equal(loaded.downloadType, 'Dash'); assert.equal(loaded.adaptiveSource, null);
  });
  await check('corrupt-inbox-first-isolated-and-reinitialization-restores-healthy', async () => {
    await sql('INSERT INTO bridge_inbox(id,payload,created_at) VALUES(?,?,?)', ['corrupt', '{}', 1]);
    const good = item('healthy'); good.createdAt = 2; assert.equal(await store.saveBridgeInbox(good), true);
    assert.deepEqual((await store.queryBridgeInbox()).map(i => i.id), ['healthy']);
    BridgeInbox.instance = undefined; const restored = BridgeInbox.getInstance(); await restored.initialize();
    assert.equal(restored.peekNext().id, 'healthy'); await restored.cancel('healthy');
  });
  await check('failed-persistence-never-publishes-or-acknowledges', async () => {
    failure = 'INSERT INTO bridge_inbox'; await assert.rejects(inbox.enqueue(item('not-saved')));
    const before = sequence.length; failure = 'INSERT INTO downloads'; await assert.rejects(service.create(request('not-created')));
    assert.equal(sequence.length, before);
  });
  await check('schema-keeps-original-22-columns', async () => {
    assert.equal((await sql('PRAGMA table_info(downloads)')).length, 22);
  });
  console.log(`SUMMARY tests=${count} fail=0 scope=production-ETS-with-real-host-SQLite`);
}
main().catch(error => { console.error(error); process.exitCode = 1; }).finally(() => {
  python.stdin.end(); python.once('exit', () => {
    const resolved = path.resolve(work), tempRoot = path.resolve(os.tmpdir()) + path.sep;
    assert.ok(resolved.startsWith(tempRoot) && path.basename(resolved).startsWith('xdm-inbox-test-'));
    fs.rmSync(resolved, { recursive: true, force: true });
  });
});
