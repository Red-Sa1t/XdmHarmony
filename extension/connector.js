const BASE = 'http://127.0.0.1:8597';
const ARRAYS = ['fileExts', 'blockedHosts', 'tabsWatcher', 'videoList', 'requestFileExts', 'matchingHosts', 'mediaTypes'];
export default class Connector {
    constructor(onMessage, onDisconnect, timeoutMs = 5000) {
        Object.assign(this, { onMessage, onDisconnect, timeoutMs, connected: false, started: false, syncPending: null });
    }
    connect() {
        if (!this.started) {
            this.started = true;
            if (chrome.alarms?.onAlarm?.addListener && chrome.alarms?.create) {
                try {
                    chrome.alarms.onAlarm.addListener(alarm => { if (alarm.name.startsWith('alerm-')) void this.onTimer(); });
                } catch { /* Immediate synchronization remains available. */ }
                for (let i = 0; i < 12; i++) {
                    try {
                        Promise.resolve(chrome.alarms.create('alerm-' + i, {
                            periodInMinutes: 1, when: Date.now() + 1000 + (i + 1) * 5000
                        })).catch(() => {});
                    } catch { /* Startup sync still works without alarms. */ }
                }
            }
        }
        return this.onTimer();
    }
    onTimer() {
        if (!this.syncPending) this.syncPending = this.request('/sync').finally(() => { this.syncPending = null; });
        return this.syncPending;
    }
    disconnect() { this.connected = false; try { this.onDisconnect(); } catch {} }
    isConnected() { return this.connected; }
    async request(path, data) {
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), this.timeoutMs);
        try {
            const options = { signal: controller.signal, cache: 'no-store' };
            if (data !== undefined) { options.method = 'POST'; options.body = JSON.stringify(data); }
            const response = await fetch(BASE + path, options);
            if (!response.ok) throw new Error('http');
            const msg = await response.json();
            if (!msg || typeof msg.enabled !== 'boolean' || ARRAYS.some(key => !Array.isArray(msg[key])) ||
                ARRAYS.filter(key => key !== 'videoList').some(key => msg[key].some(value => typeof value !== 'string'))) throw new Error('config');
            this.connected = true;
            this.onMessage(msg);
            return { ok: true }; // Legacy response is not a durable task ACK.
        } catch {
            this.disconnect();
            return { ok: false, reason: controller.signal.aborted ? 'timeout' : 'bridge-unavailable' };
        } finally { clearTimeout(timer); }
    }
    postMessage(path, data) { return this.request(path, data); }
    launchApp() { return this.onTimer(); }
}
