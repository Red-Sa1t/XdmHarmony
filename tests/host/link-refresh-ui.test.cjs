'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadMethods } = require('./production-method-loader.cjs');
const root = path.resolve(__dirname, '../../entry/src/main/ets');
const tick = () => new Promise(resolve => setTimeout(resolve, 5));
function deferred() { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; }
function setup(sizeInState = null) {
  const order = [], alerts = [], records = new Map(), browsers = [];
  let serial = 0, observer;
  const service = { begin(record, listener) { order.push(['begin', record.id, record.size]); observer = listener; return ++serial; },
    stop(token) { order.push(['stop', token]); } };
  const Subject = loadMethods(path.join(root, 'pages/Index.ets'), [
    'onRefreshLinkMenu', 'openPendingRefresh', 'refreshReferer', 'onRefreshAccepted', 'onRefreshStopped', 'onRefreshClosed', 'onOpenReferer'
  ], { LinkRefresher: { getInstance: () => service }, DownloadRecord: class {}, StateStore: class { readChunks() { return sizeInState === null ? null : { totalSize: sizeInState }; } },
    joinTempDir: (base, id) => base + '/' + id, Config: { getInstance: () => ({ getTempDir: () => '/tmp' }) },
    resolveRunRequest: record => ({ url: record.primaryUrl, context: record.requestContext, revision: record.requestRevision }),
    cloneDownloadRequestContext: input => structuredClone(input), isUriValid: url => /^https?:\/\/[^\s]+$/i.test(url.trim()),
    $r: name => name, setTimeout });
  const index = new Subject();
  Object.assign(index, { pageActive: true, loadGeneration: 1, refreshToken: 0, refreshWindowToken: 0, pendingRefreshId: '', refreshModel: {},
    findById: id => records.get(id) || null,
    refreshLinkController: { open() { order.push(['open', index.refreshToken]); }, close() { order.push(['close', index.refreshWindowToken]); } },
    getUIContext: () => ({ showAlertDialog: options => alerts.push(options), getHostContext: () => ({ openLink: async url => { browsers.push(url); order.push(['browser']); } }) }) });
  index.refreshObserver = { onAccepted: (token, id, request) => index.onRefreshAccepted(token, id, request) };
  const record = (id, size = 12) => { const value = { id, name: id + '.bin', size, status: 1, progress: 43, primaryUrl: 'https://old/' + id,
    requestRevision: 0, downloadType: 'Http', requestContext: { cookies: 'old', headers: { names: ['Referer'], values: [['https://source/page']] } } };
    records.set(id, value); return value; };
  return { index, order, alerts, records, browsers, record, service, observer: () => observer };
}
test('active refresh registers watch before opening browser and uses restored positive size without changing record metadata', async () => {
  const h = setup(15), record = h.record('active', 12); h.index.onRefreshLinkMenu(record.id); await tick();
  assert.deepEqual(h.order.slice(0, 3), [['begin', 'active', 15], ['open', 1], ['browser']]);
  assert.equal(record.size, 12); assert.equal(record.status, 1); assert.equal(record.progress, 43);
  assert.equal(h.index.refreshModel.token, 1); assert.equal(h.browsers[0], 'https://source/page');
});
test('replacement watch waits for old window destruction and stale close cannot stop the new watch', async () => {
  const h = setup(); h.record('a'); h.record('b'); h.index.onRefreshLinkMenu('a');
  h.index.onRefreshLinkMenu('b'); assert.equal(h.order.filter(row => row[0] === 'begin').length, 1);
  h.index.onRefreshClosed(1); await tick();
  assert.equal(h.index.refreshToken, 2); assert.equal(h.index.refreshWindowToken, 2);
  h.index.onRefreshClosed(1); assert.equal(h.index.refreshToken, 2); assert.equal(h.index.refreshWindowToken, 2);
});
test('accepted snapshot updates transport only and old success alert cannot close replacement window', async () => {
  const h = setup(), record = h.record('a'); h.record('b'); h.index.onRefreshLinkMenu('a');
  const snapshot = { url: 'https://fresh/a', revision: 1, context: { cookies: 'new', headers: null } };
  h.observer().onAccepted(1, 'a', snapshot);
  assert.equal(record.primaryUrl, snapshot.url); assert.equal(record.requestContext.cookies, 'new');
  snapshot.context.cookies = 'mutated'; assert.equal(record.requestContext.cookies, 'new');
  assert.equal(record.status, 1); assert.equal(record.progress, 43); assert.equal(record.size, 12); assert.equal(record.name, 'a.bin');
  const oldAlert = h.alerts.at(-1); h.index.onRefreshLinkMenu('b'); h.index.onRefreshClosed(1); await tick();
  const closes = h.order.filter(row => row[0] === 'close').length;
  oldAlert.primaryButton.action(); assert.equal(h.order.filter(row => row[0] === 'close').length, closes);
});
test('stopped or hidden page ignores late accepted callback', () => {
  const h = setup(), record = h.record('a'); h.index.onRefreshLinkMenu('a'); h.index.onRefreshStopped(1);
  h.index.onRefreshAccepted(1, 'a', { url: 'https://fresh/a', revision: 1, context: { cookies: 'new', headers: null } });
  assert.equal(record.primaryUrl, 'https://old/a'); assert.equal(h.alerts.length, 0);
});
test('late browser open failure cannot label a replacement watch, but its own failure is visible', async () => {
  const h = setup(), oldOpen = deferred(), newOpen = deferred(); h.record('a'); h.record('b');
  let browserCalls = 0;
  h.index.getUIContext = () => ({ getHostContext: () => ({
    openLink: () => (++browserCalls === 1 ? oldOpen.promise : newOpen.promise)
  }), showAlertDialog() {} });
  h.index.onRefreshLinkMenu('a');
  h.index.onRefreshLinkMenu('b'); h.index.onRefreshClosed(1); await tick();
  assert.equal(h.index.refreshToken, 2); assert.equal(browserCalls, 2);
  oldOpen.reject(new Error('old browser failed')); await tick();
  assert.equal(h.index.refreshModel.browserOpenFailed, false);
  assert.equal(h.index.refreshToken, 2);
  newOpen.reject(new Error('current browser failed')); await tick();
  assert.equal(h.index.refreshModel.browserOpenFailed, true);
  assert.equal(h.index.refreshToken, 2);
});

test('failed dialog opening stops the watch and closes a partially opened window before retry', () => {
  const h = setup(); h.record('a');
  h.index.refreshLinkController.open = () => { throw new Error('window failed'); };
  h.index.onRefreshLinkMenu('a');
  assert.ok(h.order.some(row => row[0] === 'stop' && row[1] === 1));
  assert.ok(h.order.some(row => row[0] === 'close' && row[1] === 1));
  assert.equal(h.index.refreshToken, 0); assert.equal(h.index.refreshWindowToken, 0);
  assert.equal(h.browsers.length, 0); assert.equal(h.alerts.length, 1);
  h.index.refreshLinkController.open = () => h.order.push(['open', h.index.refreshToken]);
  h.index.onRefreshLinkMenu('a');
  assert.equal(h.index.refreshToken, 2);
  h.index.onRefreshClosed(1); assert.equal(h.index.refreshWindowToken, 2);
});
test('non-HTTP referer is not launched and newer record version is never overwritten by stale success', () => {
  const h = setup(), record = h.record('a'); record.requestContext.headers.values[0][0] = 'file:///private';
  h.index.onRefreshLinkMenu('a'); assert.equal(h.browsers.length, 0);
  record.requestRevision = 3; record.primaryUrl = 'https://latest/a';
  h.index.onRefreshAccepted(1, 'a', { url: 'https://older/a', revision: 2, context: { cookies: 'older', headers: null } });
  assert.equal(record.primaryUrl, 'https://latest/a'); assert.equal(record.requestRevision, 3);
});
test('refresh dialog reports its captured token exactly once per lifetime', () => {
  const Dialog = loadMethods(path.join(root, 'components/RefreshLinkDialog.ets'), [
    'aboutToAppear', 'handleStop', 'notifyStopped', 'aboutToDisappear'
  ]);
  const dialog = new Dialog(), stops = [], closes = [];
  Object.assign(dialog, { model: { token: 7 }, onStopped: token => stops.push(token), onClosed: token => closes.push(token),
    controller: { close() {} } });
  dialog.aboutToAppear(); dialog.model.token = 8; dialog.handleStop(); dialog.aboutToDisappear(); dialog.aboutToDisappear();
  assert.deepEqual(stops, [7]); assert.deepEqual(closes, [7]);
  dialog.aboutToAppear(); dialog.aboutToDisappear(); assert.deepEqual(stops, [7, 8]); assert.deepEqual(closes, [7, 8]);
});
