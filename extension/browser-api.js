// All outcomes resolve; consume callback errors and bound missing callbacks.
export function callApi(owner, name, args = [], timeoutMs = 2000) {
    return new Promise(resolve => {
        if (typeof owner?.[name] !== 'function') { resolve({ ok: false }); return; }
        let done = false;
        const finish = result => { if (!done) { done = true; clearTimeout(timer); resolve(result); } };
        const timer = setTimeout(() => finish({ ok: false }), timeoutMs);
        try {
            const result = owner[name](...args, value => {
                const error = chrome.runtime?.lastError;
                finish(error ? { ok: false } : { ok: true, value });
            });
            if (result?.then) result.then(value => finish({ ok: true, value }), () => finish({ ok: false }));
        } catch { finish({ ok: false }); }
    });
}
export function listen(event, handler) {
    try { if (typeof event?.addListener !== 'function') return false; event.addListener(handler); return true; }
    catch { return false; }
}
