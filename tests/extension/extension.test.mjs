import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../../extension/', import.meta.url));
const config = () => ({ enabled: true, fileExts: ['.ZIP'], blockedHosts: [], tabsWatcher: ['video.test'],
    videoList: [], requestFileExts: ['.MP4'], matchingHosts: [], mediaTypes: ['video/'] });
const response = (data = config(), ok = true) => ({ ok, json: async () => data });
function event() {
    const handlers = [];
    return { handlers, addListener(fn) { handlers.push(fn); }, removeListener(fn) {
        const i = handlers.indexOf(fn); if (i >= 0) handlers.splice(i, 1);
    } };
}
async function harness(options = {}) {
    const trace = [], requests = [], stored = options.stored || {};
    const chrome = {
        runtime: { onMessage: event(), lastError: undefined },
        alarms: { onAlarm: event(), create: () => Promise.resolve() },
        downloads: { onDeterminingFilename: event(), onErased: event(), onChanged: event(),
            cancel(id, cb) { trace.push('cancel'); cb(); }, erase(query, cb) { trace.push('erase'); cb(); } },
        cookies: { getAll(query, cb) { trace.push('cookies'); cb([{ name: 'session', value: 'private-test-value' }]); } },
        tabs: { onUpdated: event(), onActivated: event(), get(id, cb) { cb({ title: 'video', url: 'https://video.test/watch' }); } },
        action: { setIcon(value, cb) { cb(); }, setPopup(value, cb) { cb(); }, setBadgeText(value, cb) { cb(); } },
        storage: { local: { get(key, cb) { cb(stored); }, set(value, cb) { Object.assign(stored, value); cb(); } } },
        contextMenus: { create(value, cb) { cb(); }, onClicked: event() },
        webRequest: { onSendHeaders: event(), onHeadersReceived: event(), onErrorOccurred: event(), onCompleted: event() }
    };
    options.change?.(chrome);
    const context = vm.createContext({ chrome, URL, AbortController, setTimeout: options.setTimeout || setTimeout, clearTimeout,
        navigator: { userAgent: 'test-agent' }, console: { log() { throw new Error('Payload logging forbidden'); } },
        fetch: async (url, init) => {
            trace.push(init.method === 'POST' ? 'post' : 'sync'); requests.push({ url, init });
            return options.fetch ? options.fetch(url, init) : response();
        } });
    const modules = new Map();
    async function load(file) {
        const full = path.join(root, file);
        if (modules.has(full)) return modules.get(full);
        const mod = new vm.SourceTextModule(await fs.readFile(full, 'utf8'), { context, identifier: full });
        modules.set(full, mod);
        await mod.link((specifier, parent) => load(path.relative(root, path.resolve(path.dirname(parent.identifier), specifier))));
        return mod;
    }
    const appModule = await load('app.js'); await appModule.evaluate();
    const App = appModule.namespace.default;
    const app = new App();
    const Connector = modules.get(path.join(root, 'connector.js')).namespace.default;
    return { app, Connector, chrome, trace, requests, stored, load };
}
const download = { id: 7, url: 'https://files.test/file.zip', finalUrl: 'https://files.test/file.zip', filename: 'file.zip', fileSize: 42, mime: 'application/zip', referrer: 'https://files.test/page' };
async function determine(h, item = download) {
    let count = 0, ret;
    await new Promise(resolve => { ret = h.app.onDeterminingFilename(item, () => { count++; resolve(); }); });
    assert.equal(count, 1);
    return ret;
}

test('startup immediately syncs, registers only once, restores disabled preference', async () => {
    const h = await harness({ stored: { userDisabled: true } });
    const p = h.app.start(); assert.equal(h.requests.length, 1); await p; await h.app.start();
    assert.equal(h.requests.length, 1); assert.equal(h.app.isMonitoringEnabled(), false);
    assert.equal(h.chrome.downloads.onDeterminingFilename.handlers.length, 1);
    h.app.onPopupMessage({ type: 'cmd', enabled: true }, {}, () => {});
    assert.equal(h.stored.userDisabled, false);
});

test('takeover POST precedes cancel/erase; real payload retains cookie, referer, UA and size', async () => {
    const h = await harness(); await h.app.start(); h.trace.length = 0;
    assert.equal(await determine(h), true);
    assert.deepEqual(h.trace, ['cookies', 'post', 'cancel', 'erase']);
    const body = JSON.parse(h.requests.at(-1).init.body);
    assert.equal(body.cookie, 'session=private-test-value');
    assert.deepEqual(body.requestHeaders.Referer, [download.referrer]);
    assert.deepEqual(body.requestHeaders['User-Agent'], ['test-agent']);
    assert.deepEqual(body.responseHeaders['Content-Length'], [42]);
    assert.equal(h.requests.at(-1).url, 'http://127.0.0.1:8597/download');
    await determine(h); assert.equal(h.trace.filter(x => x === 'post').length, 1);
});

for (const failure of ['http', 'json', 'shape', 'network']) {
    test(`failed ${failure} response preserves browser download and does not retry POST`, async () => {
        const h = await harness({ fetch: async (url, init) => {
            if (!init.method) return response();
            if (failure === 'http') return response(config(), false);
            if (failure === 'json') return { ok: true, json: async () => { throw new Error('parse'); } };
            if (failure === 'shape') return response({ enabled: true });
            throw new Error('offline');
        } });
        await h.app.start(); await determine(h);
        assert.equal(h.trace.includes('cancel'), false); assert.equal(h.app.connector.isConnected(), false);
        assert.equal(h.requests.filter(r => r.init.method).length, 1);
    });
}

test('timeout is bounded and never marks connected', async () => {
    const h = await harness({ fetch: (url, init) => new Promise((resolve, reject) => {
        init.signal.addEventListener('abort', () => reject(new Error('abort')));
    }) });
    const connector = new h.Connector(() => {}, () => {}, 10);
    const result = await connector.postMessage('/download', {});
    assert.equal(result.ok, false); assert.equal(result.reason, 'timeout'); assert.equal(connector.isConnected(), false);
});

test('disabled, disconnected, unsupported URL, blocked host and unmatched extension all suggest', async () => {
    const h = await harness(); await h.app.start();
    h.app.userDisabled = true; assert.equal(await determine(h), false); h.app.userDisabled = false;
    h.app.connector.disconnect(); assert.equal(await determine(h), false); await h.app.connector.onTimer();
    for (const item of [{ ...download, finalUrl: 'not a url' }, { ...download, filename: 'a.txt' }]) assert.equal(await determine(h, item), false);
    h.app.blockedHosts = ['files.test']; assert.equal(await determine(h), false);
    assert.equal(h.trace.includes('post'), false);
});

test('missing takeover API keeps sniffing, popup and manual download available', async () => {
    const h = await harness({ change(chrome) { delete chrome.downloads.onDeterminingFilename; } });
    await h.app.start(); assert.equal(h.app.capabilities.takeover, false); assert.equal(h.app.capabilities.sniffing, true);
    assert.equal((await h.app.triggerDownload(download.url, null, null, null, null)).ok, true);
    const result = await new Promise(resolve => { assert.equal(h.app.onPopupMessage({ type: 'vid', itemId: 12 }, {}, resolve), true); });
    assert.equal(result.ok, true); assert.deepEqual(JSON.parse(h.requests.at(-1).init.body), { vid: '12' });
});

test('cookie read failure leaves browser untouched; cancel failure does not erase history', async () => {
    const h = await harness(); await h.app.start();
    h.chrome.cookies.getAll = (query, cb) => { h.chrome.runtime.lastError = { message: 'denied' }; cb(); h.chrome.runtime.lastError = undefined; };
    await determine(h); assert.equal(h.trace.includes('post'), false);
    const h2 = await harness(); await h2.app.start();
    h2.chrome.downloads.cancel = (id, cb) => { h2.trace.push('cancel'); h2.chrome.runtime.lastError = { message: 'completed' }; cb(); h2.chrome.runtime.lastError = undefined; };
    await determine(h2); assert.equal(h2.trace.includes('erase'), false);
});

test('request watcher actual callbacks preserve headers and emit media; lost tabs use fallback', async () => {
    const h = await harness(); await h.app.start();
    h.chrome.tabs.get = (id, cb) => { h.chrome.runtime.lastError = { message: 'gone' }; cb(); h.chrome.runtime.lastError = undefined; };
    const watcher = h.app.requestWatcher;
    watcher.onSendHeadersEvent({ requestId: 'r1', method: 'GET', url: 'https://video.test/a.mp4', tabId: 1,
        requestHeaders: [{ name: 'COOKIE', value: 'private' }, { name: 'X-Test', value: 'one' }, { name: 'X-Test', value: 'two' }] });
    watcher.onHeadersReceivedEvent({ requestId: 'r1', url: 'https://video.test/a.mp4', responseHeaders: [{ name: 'Content-Type', value: 'video/mp4' }] });
    await new Promise(resolve => setImmediate(resolve));
    const req = h.requests.find(r => r.url.endsWith('/media'));
    assert.ok(req); const data = JSON.parse(req.init.body);
    assert.equal(data.cookie, 'private'); assert.deepEqual(data.requestHeaders['X-Test'], ['one', 'two']);
    assert.equal(data.tabUrl, null); assert.equal(watcher.requestMap.size, 0);
});

test('extraHeaders unsupported falls back; missing webRequest does not break startup', async () => {
    const h = await harness({ change(chrome) {
        for (const event of [chrome.webRequest.onSendHeaders, chrome.webRequest.onHeadersReceived]) {
            const original = event.addListener;
            event.addListener = (fn, filter, fields) => { if (fields.includes('extraHeaders')) throw new Error('unsupported'); original.call(event, fn); };
        }
    } });
    await h.app.start(); assert.equal(h.app.capabilities.sniffing, true); assert.equal(h.app.requestWatcher.extraHeaders, false);
    const h2 = await harness({ change(chrome) { delete chrome.webRequest; delete chrome.alarms; delete chrome.contextMenus; delete chrome.tabs; delete chrome.action; } });
    await h2.app.start(); assert.equal(h2.app.capabilities.sniffing, false); assert.equal(h2.app.capabilities.takeover, true);
});

test('manifest preserves MV3 worker and complete source resources', async () => {
    const manifest = JSON.parse(await fs.readFile(path.join(root, 'manifest.json')));
    assert.equal(manifest.manifest_version, 3); assert.equal(manifest.background.type, 'module');
    const source = path.resolve(root, '../../resourses/xdm/app/XDM/chrome-extension');
    for (const name of await fs.readdir(source)) assert.ok((await fs.stat(path.join(root, name))).isFile(), name);
    for (const name of await fs.readdir(source)) {
        if (!name.endsWith('.js')) assert.deepEqual(await fs.readFile(path.join(root, name)), await fs.readFile(path.join(source, name)), name);
    }
});

test('cancel waits for parsed response, not just POST dispatch', async () => {
    let accept;
    const pending = new Promise(resolve => { accept = resolve; });
    const h = await harness({ fetch: async (url, init) => init.method ? { ok: true, json: () => pending } : response() });
    await h.app.start(); const finished = determine(h);
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(h.trace.includes('post'), true); assert.equal(h.trace.includes('cancel'), false);
    accept(config()); await finished; assert.equal(h.trace.includes('cancel'), true);
});

test('timeout handoff calls suggest and keeps browser download', async () => {
    const h = await harness({ fetch: async (url, init) => {
        if (!init.method) return response();
        return new Promise((resolve, reject) => init.signal.addEventListener('abort', () => reject(new Error('abort'))));
    } });
    await h.app.start(); h.app.connector.timeoutMs = 10;
    assert.equal(await determine(h), true); assert.equal(h.trace.includes('cancel'), false);
});

test('worker restart reads saved preference and immediately syncs again', async () => {
    const stored = {};
    const first = await harness({ stored }); await first.app.start();
    first.app.onPopupMessage({ type: 'cmd', enabled: false }, {}, () => {});
    const second = await harness({ stored }); await second.app.start();
    assert.equal(second.trace[0], 'sync'); assert.equal(second.app.userDisabled, true);
    assert.equal(await determine(second), false);
});

test('config controls actual watcher blocked-host filter and tab update routing', async () => {
    const settings = config(); settings.blockedHosts = ['blocked.test'];
    const h = await harness({ fetch: async () => response(settings) }); await h.app.start();
    assert.equal(h.app.requestWatcher.isMatchingRequest({ url: 'https://blocked.test/a.mp4', responseHeaders: [] }), false);
    h.app.onTabUpdate(1, { title: 'New title' }, { url: 'https://video.test/watch' });
    await new Promise(resolve => setImmediate(resolve));
    assert.deepEqual(JSON.parse(h.requests.at(-1).init.body), { tabUrl: 'https://video.test/watch', tabTitle: 'New title' });
});

for (const outcome of ['enabled', 'disabled', 'failed']) {
    test(`cold-start filename waits for startup: ${outcome}`, async () => {
        let restore, sync;
        const syncResponse = new Promise(resolve => { sync = resolve; });
        const h = await harness({ change(chrome) { chrome.storage.local.get = (key, cb) => { restore = cb; }; },
            fetch: (url, init) => init.method ? response() : syncResponse });
        const startup = h.app.start(); // Intentionally do not await startup before event.
        assert.equal(h.chrome.downloads.onDeterminingFilename.handlers.length, 1);
        let suggestions = 0;
        const finished = new Promise(resolve => {
            assert.equal(h.app.onDeterminingFilename(download, () => { suggestions++; resolve(); }), true);
        });
        await new Promise(resolve => setImmediate(resolve));
        assert.equal(suggestions, 0); assert.equal(h.trace.includes('post'), false);
        // A repeated pending callback must not create a second handoff.
        assert.equal(await determine(h), false);
        restore({ userDisabled: outcome === 'disabled' });
        sync(response(config(), outcome !== 'failed'));
        await startup; await finished;
        assert.equal(suggestions, 1);
        assert.equal(h.trace.filter(x => x === 'post').length, outcome === 'enabled' ? 1 : 0);
        assert.equal(h.trace.includes('cancel'), outcome === 'enabled');
    });
}

test('fallback IDs release only after terminal state, preserving in-flight duplicate suppression', async () => {
    let finishPost;
    const pending = new Promise(resolve => { finishPost = resolve; });
    const h = await harness({ fetch: (url, init) => init.method ? pending : response() });
    await h.app.start(); const done = determine(h);
    await new Promise(resolve => setImmediate(resolve));
    const changed = h.chrome.downloads.onChanged.handlers[0];
    changed({ id: download.id, state: { current: 'interrupted' } });
    assert.equal(h.app.handoffs.has(download.id), true);
    await determine(h); assert.equal(h.trace.filter(x => x === 'post').length, 1);
    finishPost(response(config(), false)); await done;
    assert.equal(h.app.handoffs.size, 0); assert.equal(h.app.inFlightHandoffs.size, 0); assert.equal(h.app.terminalHandoffs.size, 0);
    h.app.handoffs.add(20); changed({ id: 20, state: { current: 'in_progress' } }); assert.equal(h.app.handoffs.has(20), true);
    changed({ id: 20, state: { current: 'complete' } }); assert.equal(h.app.handoffs.has(20), false);
});

test('cold-start wait has a hard bound and late initialization cannot hand off again', async () => {
    let sync;
    const responsePending = new Promise(resolve => { sync = resolve; });
    const h = await harness({ fetch: (url, init) => init.method ? response() : responsePending,
        setTimeout: (fn, ms) => setTimeout(fn, ms === 5500 ? 10 : ms) });
    const startup = h.app.start();
    assert.equal(await determine(h), true);
    assert.equal(h.trace.includes('post'), false); assert.equal(h.app.handoffs.size, 0);
    sync(response()); await startup;
    assert.equal(h.trace.includes('post'), false);
});
