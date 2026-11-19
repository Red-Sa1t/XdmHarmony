import RequestWatcher from './request-watcher.js';
import Connector from './connector.js';
import { callApi, listen } from './browser-api.js';

export default class App {
    constructor() {
        this.videoList = []; this.blockedHosts = []; this.fileExts = []; this.tabsWatcher = [];
        this.userDisabled = false; this.settingsReady = false; this.settingsRevision = 0;
        this.appEnabled = false; this.activeTabId = -1; this.started = false; this.startupReady = false;
        this.handoffs = new Set(); this.inFlightHandoffs = new Set(); this.terminalHandoffs = new Set(); this.capabilities = {};
        this.connector = new Connector(this.onMessage.bind(this), this.onDisconnect.bind(this));
        this.requestWatcher = new RequestWatcher(this.onRequestDataReceived.bind(this));
    }
    start() {
        if (this.started) return this.startup;
        this.started = true;
        this.register(); // Register MV3 event listeners synchronously.
        const revision = this.settingsRevision;
        const settings = callApi(chrome.storage?.local, 'get', ['userDisabled']).then(result => {
            if (revision === this.settingsRevision) {
                this.userDisabled = result.value?.userDisabled === true || (!result.ok && !!chrome.storage?.local?.get);
            }
            this.settingsReady = true;
            this.updateActionIcon();
        });
        this.startup = Promise.all([settings, this.connector.connect()]).finally(() => { this.startupReady = true; });
        return this.startup;
    }
    async awaitStartup() {
        if (this.startupReady) return true;
        if (!this.startup) return false;
        let timer;
        try {
            return await Promise.race([this.startup.then(() => true, () => false),
                new Promise(resolve => { timer = setTimeout(() => resolve(false), 5500); })]);
        } finally { clearTimeout(timer); }
    }
    releaseTerminalHandoff(id) {
        if (this.inFlightHandoffs.has(id)) this.terminalHandoffs.add(id);
        else this.handoffs.delete(id);
    }
    onMessage(msg) {
        this.appEnabled = msg.enabled; this.fileExts = msg.fileExts; this.blockedHosts = msg.blockedHosts;
        this.tabsWatcher = msg.tabsWatcher; this.videoList = msg.videoList;
        this.requestWatcher.updateConfig({ mediaExts: msg.requestFileExts, blockedHosts: msg.blockedHosts,
            matchingHosts: msg.matchingHosts, mediaTypes: msg.mediaTypes });
        this.updateActionIcon();
    }
    onDisconnect() { this.updateActionIcon(); }
    isMonitoringEnabled() { return this.settingsReady && this.appEnabled && !this.userDisabled && this.connector.isConnected(); }
    onRequestDataReceived(data) { if (this.isMonitoringEnabled()) void this.connector.postMessage('/media', data); }
    onDeterminingFilename(download, suggest) {
        let suggested = false;
        const finish = () => { if (!suggested) { suggested = true; suggest(); } };
        const url = download.finalUrl || download.url;
        if (!this.capabilities.takeover || !this.isSupportedProtocol(url) || this.handoffs.has(download.id) ||
            (this.startupReady && (!this.isMonitoringEnabled() || !this.shouldTakeOver(url, download.filename)))) {
            finish(); return false;
        }
        this.handoffs.add(download.id);
        this.inFlightHandoffs.add(download.id);
        let referrer = download.referrer;
        if (!referrer && download.finalUrl && download.finalUrl !== download.url) referrer = download.url;
        void (async () => {
            try {
                // The event may be the reason MV3 woke this worker. Wait for both
                // configuration and restored user preference before deciding capture.
                if (!await this.awaitStartup() || !this.isMonitoringEnabled() || !this.shouldTakeOver(url, download.filename)) {
                    this.handoffs.delete(download.id);
                    return;
                }
                const result = await this.triggerDownload(url, download.filename, referrer, download.fileSize, download.mime);
                if (result.ok) {
                    const canceled = await callApi(chrome.downloads, 'cancel', [download.id]);
                    if (canceled.ok) await callApi(chrome.downloads, 'erase', [{ id: download.id }]);
                }
            } finally {
                this.inFlightHandoffs.delete(download.id);
                if (this.terminalHandoffs.delete(download.id)) this.handoffs.delete(download.id);
                finish();
            }
        })().catch(() => { finish(); });
        return true;
    }
    register() {
        this.capabilities.takeover = !!chrome.downloads?.cancel && !!chrome.cookies?.getAll &&
            listen(chrome.downloads?.onDeterminingFilename, this.onDeterminingFilename.bind(this));
        listen(chrome.downloads?.onErased, id => this.releaseTerminalHandoff(id));
        listen(chrome.downloads?.onChanged, delta => {
            if (['complete', 'interrupted'].includes(delta.state?.current)) this.releaseTerminalHandoff(delta.id);
        });
        listen(chrome.tabs?.onUpdated, this.onTabUpdate.bind(this));
        listen(chrome.tabs?.onActivated, info => { this.activeTabId = String(info.tabId); });
        listen(chrome.runtime?.onMessage, this.onPopupMessage.bind(this));
        this.capabilities.sniffing = this.requestWatcher.register();
        this.capabilities.extraHeaders = this.capabilities.sniffing && this.requestWatcher.extraHeaders;
        if (chrome.contextMenus?.create) {
            void callApi(chrome.contextMenus, 'create', [{ id: 'download-any-link', title: 'Download with XDM', contexts: ['link', 'video', 'audio', 'all'] }]);
            void callApi(chrome.contextMenus, 'create', [{ id: 'download-image-link', title: 'Download Image with XDM', contexts: ['image'] }]);
            listen(chrome.contextMenus.onClicked, this.onMenuClicked.bind(this));
        }
    }
    isSupportedProtocol(url) { try { return ['http:', 'https:'].includes(new URL(url).protocol); } catch { return false; } }
    shouldTakeOver(url, file) {
        if (!this.isSupportedProtocol(url)) return false;
        const parsed = new URL(url);
        if (this.blockedHosts.some(host => parsed.host.includes(host))) return false;
        const path = (file || parsed.pathname).toUpperCase();
        return this.fileExts.some(ext => path.endsWith(ext.toUpperCase()));
    }
    updateActionIcon() {
        const suffix = this.isMonitoringEnabled() ? '.png' : '-mono.png';
        void callApi(chrome.action, 'setIcon', [{ path: { 16: 'icon16' + suffix, 48: 'icon48' + suffix, 128: 'icon128' + suffix } }]);
        void callApi(chrome.action, 'setBadgeText', [{ text: this.videoList.length ? String(this.videoList.length) : '' }]);
        const popup = !this.connector.isConnected() ? './error.html' : !this.appEnabled ? './disabled.html' : './popup.html';
        void callApi(chrome.action, 'setPopup', [{ popup }]);
    }
    async triggerDownload(url, file, referer, size, mime) {
        if (!this.isSupportedProtocol(url)) return { ok: false, reason: 'url' };
        const result = await callApi(chrome.cookies, 'getAll', [{ url }]);
        if (chrome.cookies?.getAll && !result.ok) return { ok: false, reason: 'cookies' };
        const cookies = result.value || [];
        const requestHeaders = { 'User-Agent': [navigator.userAgent] };
        if (referer) requestHeaders.Referer = [referer];
        const responseHeaders = {};
        if (Number(size) > 0) responseHeaders['Content-Length'] = [Number(size)];
        if (mime) responseHeaders['Content-Type'] = [mime];
        return this.connector.postMessage('/download', {
            url, cookie: result.ok ? cookies.map(item => item.name + '=' + item.value).join('; ') : undefined,
            requestHeaders, responseHeaders, filename: file, fileSize: size, mimeType: mime
        });
    }
    onTabUpdate(tabId, changeInfo, tab) {
        if (this.isMonitoringEnabled() && changeInfo.title && typeof tab?.url === 'string' && this.tabsWatcher.some(watched => tab.url.includes(watched)))
            void this.connector.postMessage('/tab-update', { tabUrl: tab.url, tabTitle: changeInfo.title });
    }
    onPopupMessage(request, sender, sendResponse) {
        if (request?.type === 'stat') sendResponse({ enabled: this.isMonitoringEnabled(), list: this.videoList, capabilities: this.capabilities });
        else if (request?.type === 'cmd') {
            this.settingsRevision++; this.userDisabled = request.enabled === false;
            void callApi(chrome.storage?.local, 'set', [{ userDisabled: this.userDisabled }]);
            this.updateActionIcon();
            if (request.enabled) void this.connector.onTimer();
            sendResponse({ ok: true });
        } else if (request?.type === 'vid' || request?.type === 'clear') {
            const path = request.type === 'vid' ? '/vid' : '/clear';
            const data = request.type === 'vid' ? { vid: String(request.itemId) } : {};
            void this.connector.postMessage(path, data).then(sendResponse).catch(() => sendResponse({ ok: false }));
            return true;
        }
        return false;
    }
    onMenuClicked(info) {
        if (!['download-any-link', 'download-image-link'].includes(info.menuItemId)) return;
        const urls = info.menuItemId === 'download-image-link' ? [info.srcUrl, info.linkUrl, info.pageUrl] : [info.linkUrl, info.srcUrl, info.pageUrl];
        const url = urls.find(value => this.isSupportedProtocol(value));
        if (url) void this.triggerDownload(url, null, info.pageUrl, null, null).catch(() => {});
    }
}
