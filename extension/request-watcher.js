"use strict";
import Logger from './logger.js';
import { callApi } from './browser-api.js';

export default class RequestWatcher {
    constructor(callback) {
        this.logger = new Logger();
        this.blockedHosts = [];
        this.mediaExts = [];
        this.fileExts = [];
        this.requestMap = new Map();
        this.callback = callback;
        this.matchingHosts = [];
        this.mediaTypes = [];
        this.onSendHeadersEventCallback = this.onSendHeadersEvent.bind(this);
        this.onHeadersReceivedEventCallback = this.onHeadersReceivedEvent.bind(this);
        this.onErrorOccurredEventCallback = this.onErrorOccurredEvent.bind(this);
        this.urlPatterns = [];
        this.requestFileExts = [];
    }

    updateConfig(config) {
        if (config.blockedHosts) {
            this.blockedHosts = config.blockedHosts
        }
        if (config.fileExts) {
            this.fileExts = config.fileExts
        }
        if (config.mediaExts) {
            this.mediaExts = config.mediaExts
        }
        if (config.matchingHosts) {
            this.matchingHosts = config.matchingHosts
        }
        if (config.mediaTypes) {
            this.mediaTypes = config.mediaTypes
        }
        if (config.requestFileExts) {
            this.requestFileExts = config.requestFileExts
        }
        if (config.urlPatterns) {
            this.urlPatterns = config.urlPatterns.map(pattern => {
                try {
                    return new RegExp(pattern, "i");
                } catch { }
            }).filter(item => item || false);
        }
    }

    isMatchingRequest(res) {
        let u;
        try { u = new URL(res.url); } catch { return false; }

        let hostName = u.host;
        if (this.blockedHosts.find(h => hostName.indexOf(h) >= 0)) {
            return false;
        }

        let path = u.pathname;
        let upath = path.toUpperCase();
        if (this.mediaExts.find(e => upath.endsWith(e))) {
            return true;
        }

        if (this.requestFileExts.find(e => upath.endsWith(e))) {
            return true;
        }

        try {
            if (this.urlPatterns.find(re => re.test(res.url))) {
                return true;
            }
        } catch { }

        let mediaType = (res.responseHeaders || []).find(h => h["name"].toUpperCase() === "CONTENT-TYPE");
        if (mediaType && this.mediaTypes.find(m => mediaType["value"].indexOf(m) >= 0)) {
            return true;
        }

        if (this.fileExts.find(e => upath.endsWith("." + e))) {
            return true;
        }

        let contentDisposition = (res.responseHeaders || []).find(h => h["name"].toUpperCase() === "CONTENT-DISPOSITION");
        if (contentDisposition && this.fileExts.find(ext => contentDisposition["value"].toUpperCase().indexOf("." + ext) >= 0)) {
            return true;
        }

        if (this.matchingHosts.find(h => hostName.indexOf(h) >= 0)) {
            return true;
        }
    }

    onSendHeadersEvent(info) {
        if (info.method !== "GET" && !(this.matchingHosts
            && this.matchingHosts.find(matchingHost => info.url.indexOf(matchingHost) > 0))) {
            return;
        }
        if (this.requestMap.size >= 2048) this.requestMap.delete(this.requestMap.keys().next().value);
        this.requestMap.set(info.requestId, info);
    }

    onHeadersReceivedEvent(res) {
        let reqId = res.requestId;
        let req = this.requestMap.get(reqId);
        if (req) {
            this.requestMap.delete(reqId);
            if (this.callback && this.isMatchingRequest(res)) {
                if (req.tabId !== -1) {
                    void callApi(chrome.tabs, 'get', [req.tabId]).then(result => {
                        const tab = result.ok ? result.value : null;
                        this.callback(this.createRequestData(req, res, tab?.title || null, tab?.url || null, req.tabId));
                    }).catch(() => {});
                } else {
                    this.callback(this.createRequestData(req, res, null, null, req.tabId));
                }
            }
        }
    }

    onErrorOccurredEvent(info) {
        let reqId = info.requestId;
        this.requestMap.delete(reqId);
    }

    register() {
        const web = chrome.webRequest;
        const filter = { urls: ["http://*/*", "https://*/*"] };
        const registrations = [];
        this.extraHeaders = true;
        const add = (event, callback, field) => {
            if (!event?.addListener) return false;
            try { event.addListener(callback, filter, ["extraHeaders", field]); }
            catch {
                this.extraHeaders = false;
                try { event.addListener(callback, filter, [field]); } catch { return false; }
            }
            registrations.push([event, callback]);
            return true;
        };
        if (!add(web?.onSendHeaders, this.onSendHeadersEventCallback, 'requestHeaders') ||
            !add(web?.onHeadersReceived, this.onHeadersReceivedEventCallback, 'responseHeaders')) {
            for (const [event, callback] of registrations) {
                try { event.removeListener(callback); } catch {}
            }
            return false;
        }
        this.registrations = registrations;
        for (const event of [web.onErrorOccurred, web.onCompleted]) {
            try { event?.addListener(this.onErrorOccurredEventCallback, filter); } catch {}
        }
        return true;
    }

    unRegister() {
        for (const [event, callback] of this.registrations || []) {
            try { event.removeListener(callback); } catch {}
        }
        try { chrome.webRequest?.onErrorOccurred?.removeListener(this.onErrorOccurredEventCallback); } catch {}
        try { chrome.webRequest?.onCompleted?.removeListener(this.onErrorOccurredEventCallback); } catch {}
        this.requestMap.clear();
    }

    createRequestData(req, res, title, tabUrl, tabId) {
        let data = {
            url: res.url,
            file: title,
            requestHeaders: Object.create(null),
            responseHeaders: Object.create(null),
            cookie: undefined,
            method: req.method,
            userAgent: navigator.userAgent,
            tabUrl: tabUrl,
            tabId: tabId + ""
        };

        let cookies = [];

        if (req.extraHeaders) {
            req.extraHeaders.forEach(h => {
                if (h.name.toLowerCase() === 'cookie') {
                    cookies.push(h.value);
                }
                this.addToDict(data.requestHeaders, h.name, h.value);
            });
        }
        if (req.requestHeaders) {
            req.requestHeaders.forEach(h => {
                if (h.name.toLowerCase() === 'cookie') {
                    cookies.push(h.value);
                }
                this.addToDict(data.requestHeaders, h.name, h.value);
            });
        }
        if (res.responseHeaders) {
            res.responseHeaders.forEach(h => {
                this.addToDict(data.responseHeaders, h.name, h.value);
            });
        }
        if (cookies.length > 0) {
            data.cookie = cookies.join(";");
        }
        return data;
    }

    addToDict(dict, key, value) {
        let values = dict[key];
        if (values) {
            values.push(value);
        } else {
            dict[key] = [value];
        }
    }
}
