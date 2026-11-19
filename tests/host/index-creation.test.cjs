'use strict';
// Execute unchanged production Index methods with platform/UI dependencies replaced.
// This covers orchestration, not ArkUI rendering or a real device lifecycle.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.XDM_TYPESCRIPT_PATH || 'D:/Tools/DevEco Studio/tools/ohpm/node_modules/typescript/lib/typescript.js');
const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/pages/Index.ets'), 'utf8');
function method(name, input = source) {
  const match = new RegExp('  private (?:async )?' + name + '\\(').exec(input);
  assert.ok(match, name);
  const start = input.indexOf('{', match.index);
  const scanner = ts.createScanner(ts.ScriptTarget.Latest, true, ts.LanguageVariant.Standard, input.slice(start));
  let depth = 0;
  for (let token = scanner.scan(); token !== ts.SyntaxKind.EndOfFileToken; token = scanner.scan()) {
    if (token === ts.SyntaxKind.OpenBraceToken) depth++;
    if (token === ts.SyntaxKind.CloseBraceToken && --depth === 0) {
      return input.slice(match.index, start + scanner.getTextPos());
    }
  }
  throw new Error('Unclosed production method: ' + name);
}
function deferred() { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; }
function harness(store, service, inbox, platform = {}) {
  const names = ['initLists', 'deliverEngineEvent', 'confirmNewDownload', 'cancelActiveInbox', 'startNewDownload', 'onSelectionConfirm', 'onNewDownloadClosed', 'openNextInbox', 'openNewDownloadFromClipboard'];
  const compiled = ts.transpileModule('class IndexHarness {\n' + names.map(name => method(name)).join('\n') + '\n}\nexports.IndexHarness = IndexHarness;',
    { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText;
  class Request { constructor() { this.startImmediately = true; this.contextUrl = ''; this.requestContext = {}; } }
  const context = { exports: {}, DownloadStore: { getInstance: () => store }, DownloadCreationService: { getInstance: () => service },
    BridgeInbox: { getInstance: () => inbox }, Config: { getInstance: () => ({ getDownloadDir: () => '/downloads' }) },
    DownloadCreationRequest: Request, BridgeInboxItem: class {}, cloneDownloadCreationRequest: request => structuredClone(request),
    hilog: { error() {}, warn() {} }, setTimeout, openPrompts: new Set(), $r: value => value, ...platform };
  vm.runInNewContext(compiled, context);
  const index = new context.exports.IndexHarness();
  const dataSource = () => ({ records: [], initialize(records) { this.records = records; } });
  Object.assign(index, { pageActive: true, loadGeneration: 1, listReady: false, addedDuringLoad: new Map(), engineDuringLoad: [],
    inProgressDS: dataSource(), finishedDS: dataSource(), activeInbox: null, selectionSession: { saveIn: '/downloads' },
    pendingPromptUrl: '', promptQueue: [], promptOpen: false,
    getUIContext: () => ({ getHostContext: () => undefined }), recomputeCounts() {}, recomputeToolbar() {}, openNextInbox() {} });
  return index;
}
test('hydration retains newly committed record identity and replays engine events before admission', async () => {
  const query = deferred(); const order = [];
  const committed = { id: 'new', status: 'Waiting' };
  const index = harness({ queryAll: () => query.promise }, {
    getPendingAdmissions: () => [committed], setAdmissionReady: ready => { assert.equal(ready, true); order.push('admission'); }
  }, { initialize: async () => {} });
  const loading = index.initLists();
  index.addedDuringLoad.set('new', committed);
  index.deliverEngineEvent(() => { order.push('event'); committed.status = 'Downloading'; });
  query.resolve({ inProgress: [{ id: 'new', status: 'Stopped' }, { id: 'old' }], finished: [] });
  await loading;
  assert.equal(index.inProgressDS.records.length, 2);
  assert.equal(index.inProgressDS.records[0], committed);
  assert.equal(committed.status, 'Downloading');
  assert.deepEqual(order, ['event', 'admission']);
});
test('obsolete page query cannot hydrate or enable admission', async () => {
  const query = deferred();
  const index = harness({ queryAll: () => query.promise }, { setAdmissionReady() { assert.fail('stale admission'); } }, {});
  const loading = index.initLists(); index.loadGeneration++;
  query.resolve({ inProgress: [{ id: 'obsolete' }], finished: [] }); await loading;
  assert.equal(index.inProgressDS.records.length, 0);
});
test('single captured request preserves original credential binding when user changes URL', async () => {
  let captured;
  const index = harness({}, {}, { confirm: async (id, requests) => { assert.equal(id, 'inbox'); captured = requests[0]; } });
  const original = { url: 'https://original/file', contextUrl: 'https://original/file', requestContext: { cookies: 'session' } };
  index.activeInbox = { id: 'inbox', requests: [original] };
  assert.equal(await index.confirmNewDownload('https://other/file', 'new.bin', 0), true);
  assert.equal(captured.url, 'https://other/file');
  assert.equal(captured.contextUrl, original.contextUrl); // Service must clear context on mismatch.
  assert.equal(original.url, 'https://original/file');
  assert.equal(index.activeInbox, null);
});
test('failed inbox promotion retains the active request for retry', async () => {
  const index = harness({}, {}, { confirm: async () => { throw new Error('database unavailable'); } });
  const item = { id: 'inbox', requests: [{ url: 'https://host/file' }] };
  index.activeInbox = item;
  await assert.rejects(index.confirmNewDownload('https://host/file', 'f', 0));
  assert.equal(index.activeInbox, item);
});
test('manual batch retry reuses its durable inbox and keeps per-item context and Later choice', async () => {
  let enqueues = 0, confirms = 0, captured;
  const inbox = { enqueue: async item => { enqueues++; return { ...item, id: 'batch' }; }, claim: () => true,
    confirm: async (id, requests) => { confirms++; captured = requests; if (confirms === 1) throw new Error('rollback'); } };
  const index = harness({}, {}, inbox);
  const items = [{ url: 'https://a/file', name: 'a', size: 10, contextUrl: 'https://a/file', requestContext: { cookies: 'a' } },
    { url: 'https://b/file', name: 'b', size: 20, contextUrl: 'https://b/file', requestContext: { cookies: 'b' } }];
  await assert.rejects(index.onSelectionConfirm(items, null, null, false));
  assert.equal(index.activeInbox.id, 'batch');
  assert.equal(await index.onSelectionConfirm(items, null, null, false), true);
  assert.equal(enqueues, 1); assert.equal(confirms, 2);
  assert.equal(captured[0].requestContext.cookies, 'a'); assert.equal(captured[1].requestContext.cookies, 'b');
  assert.equal(captured.every(request => !request.startImmediately), true);
});
test('release notification cannot reopen the inbox while old dialog is being dismantled', async () => {
  let index, notifications = 0, opened = 0;
  index = harness({}, {}, { release() {
    notifications++;
    assert.equal(index.activeInbox, null);
    assert.equal(index.promptOpen, true);
    index.openNextInbox();
  } });
  index.openNextInbox = () => { if (!index.promptOpen) opened++; };
  index.activeInbox = { id: 'pending' }; index.promptOpen = true;
  index.onNewDownloadClosed();
  assert.equal(notifications, 1); assert.equal(opened, 0);
  await new Promise(resolve => setTimeout(resolve, 5));
  assert.equal(opened, 1);
});
test('leaving page during manual batch enqueue cannot leave an orphan claim', async () => {
  const saving = deferred();
  const index = harness({}, {}, { enqueue: () => saving.promise, claim() { assert.fail('orphan claim'); } });
  const pending = index.onSelectionConfirm([{ url: 'https://host/f', name: 'f', requestContext: {} }], null, null, true);
  index.pageActive = false; index.loadGeneration++;
  saving.resolve({ id: 'saved', requests: [] });
  assert.equal(await pending, false);
  assert.equal(index.activeInbox, null);
});
test('scheduled clipboard prompt from an old page cannot open over the next page inbox', async () => {
  const index = harness({}, {}, {});
  index.promptQueue = ['https://queued/file'];
  index.newDownloadModel = {};
  index.dialogController = { open() { assert.fail('old prompt timer opened'); } };
  index.onNewDownloadClosed();
  index.loadGeneration += 2;
  index.activeInbox = { id: 'next-page-inbox' };
  await new Promise(resolve => setTimeout(resolve, 5));
  assert.equal(index.activeInbox.id, 'next-page-inbox');
});
test('late confirm from a previous page must not clear the new active inbox', async () => {
  const saving = deferred();
  const index = harness({}, {}, { confirm: () => saving.promise });
  index.activeInbox = { id: 'old', requests: [{ url: 'https://host/old' }] };
  const pending = index.confirmNewDownload('https://host/old', 'old', 0);
  index.loadGeneration++;
  const next = { id: 'next', requests: [] }; index.activeInbox = next;
  saving.resolve([]);
  assert.equal(await pending, false);
  assert.equal(index.activeInbox, next);
});
test('late cancellation from a previous page must not clear the new active inbox', async () => {
  const canceling = deferred();
  const index = harness({}, {}, { cancel: () => canceling.promise });
  index.activeInbox = { id: 'old' };
  const pending = index.cancelActiveInbox();
  index.loadGeneration++;
  const next = { id: 'next' }; index.activeInbox = next;
  canceling.resolve();
  assert.equal(await pending, false);
  assert.equal(index.activeInbox, next);
});
test('a stale unsupported-video alert cannot cancel the current page request', () => {
  let alert;
  const index = harness({}, {}, { peekNext: () => ({ id: 'old-video', kind: 'video', videoKind: 'hls', requests: [{ adaptive: null }] }),
    claim: () => true, cancel() { assert.fail('stale alert canceled current inbox'); } });
  delete index.openNextInbox;
  index.listReady = true;
  index.getUIContext = () => ({ showAlertDialog: options => { alert = options; } });
  index.openNextInbox();
  index.loadGeneration++;
  index.activeInbox = { id: 'new-request' };
  alert.primaryButton.action();
  assert.equal(index.activeInbox.id, 'new-request');
});
test('adaptive video inbox opens the new download dialog prefilled instead of the unsupported alert', () => {
  let opened = 0;
  const item = { id: 'hls-1', kind: 'video', videoKind: 'hls',
    requests: [{ url: 'https://h/v.m3u8', name: 'show.mp4', size: 0, adaptive: { kind: 'hls' } }] };
  const index = harness({}, {}, { peekNext: () => item, claim: () => true });
  delete index.openNextInbox;
  index.listReady = true;
  index.newDownloadModel = { initialUrl: '', initialName: '', initialSize: -1 };
  index.dialogController = { open() { opened++; } };
  index.getUIContext = () => ({ showAlertDialog() { assert.fail('adaptive item shown as unsupported'); } });
  index.openNextInbox();
  assert.equal(opened, 1);
  assert.equal(index.newDownloadModel.initialUrl, 'https://h/v.m3u8');
  assert.equal(index.newDownloadModel.initialName, 'show.mp4');
  assert.equal(index.activeInbox, item);
});
for (const failed of [false, true]) {
  test(`stale clipboard ${failed ? 'failure' : 'success'} cannot open over a new inbox dialog`, async () => {
    const reading = deferred();
    const index = harness({}, {}, {}, {
      ClipboardWatcher: { getInstance: () => ({ requestReadPermission: async () => {} }) },
      pasteboard: { getSystemPasteboard: () => ({ getData: () => reading.promise }) }, isUriValid: () => true
    });
    index.newDownloadModel = { initialUrl: 'batch-current' };
    index.dialogController = { open() { assert.fail('stale clipboard opened over inbox'); } };
    index.openNewDownloadFromClipboard();
    await Promise.resolve();
    index.loadGeneration += 2;
    const next = { id: 'batch-current' }; index.activeInbox = next;
    if (failed) reading.reject(new Error('read failure')); else reading.resolve({ getPrimaryText: () => 'https://old/file' });
    await new Promise(resolve => setTimeout(resolve, 5));
    assert.equal(index.newDownloadModel.initialUrl, 'batch-current');
    assert.equal(index.activeInbox, next);
  });
}
for (const file of ['NewDownloadDialog', 'DownloadSelectionDialog']) {
  const input = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/components', file + '.ets'), 'utf8');
  const exported = input.slice(input.indexOf('export struct ' + file));
  for (const operation of [file === 'NewDownloadDialog' ? 'handleConfirm' : 'submit', 'handleCancel']) {
    for (const reject of [false, true]) {
      test(`${file}.${operation}: stale ${reject ? 'failure' : 'success'} cannot close or update a replacement dialog`, async () => {
        const pending = deferred();
        const context = { exports: {}, isUriValid: () => true, sanitizeFileName: value => value,
          FileNameFetchMode: { None: 0, FileNameAndExtension: 2 }, $r: value => value };
        const code = 'class Dialog {\n' + method(operation, exported) + '\n}\nexports.Dialog = Dialog;';
        vm.runInNewContext(ts.transpileModule(code, { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText, context);
        const dialog = new context.exports.Dialog();
        Object.assign(dialog, { busy: false, active: true, generation: 1, url: 'https://host/file', fileName: 'file',
          derivedName: 'file', fileNameTouched: false, session: { auth: null, proxy: null }, selectedItems: () => [], validate: () => true,
          onConfirm: () => pending.promise, onCancel: () => pending.promise,
          controller: { close() { assert.fail('closed replacement dialog'); } }, showMsg() { assert.fail('stale dialog message'); } });
        const result = dialog[operation](true);
        dialog.generation++; dialog.active = true; dialog.busy = true;
        if (reject) pending.reject(new Error('old request failed')); else pending.resolve(true);
        await result;
        assert.equal(dialog.busy, true);
      });
    }
  }
}
