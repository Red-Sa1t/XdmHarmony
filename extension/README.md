# XDM Harmony browser extension

Derived from `resourses/xdm/app/XDM/chrome-extension` in this workspace, upstream
https://github.com/subhra74/xdm. The complete original extension assets are retained.
XDM is GPL-2.0; see the included unmodified upstream LICENSE. Adaptations in 2026
cover bridge transport, asynchronous download handoff, browser capability checks,
worker preference restoration and sensitive-payload logging removal.

Load this directory as an unpacked extension in a browser that supports MV3 module
service workers. Keep the Harmony app running and its bridge listening on port
8597. The extension preserves the original bridge endpoints and payload fields.
The Windows XDM bridge on port 9614 is unrelated.

Supported browsers retain automatic download takeover by default. Actual absence
of filename/cancel/cookies APIs disables automatic takeover only; available media
sniffing, popup and context-menu operations remain enabled. Missing `extraHeaders`
falls back to ordinary request headers, so cookie visibility may be reduced. The
popup `stat` response exposes detected capabilities for integration diagnostics.
The user's disable switch is stored in extension local storage. A worker restart
immediately synchronizes with the app and restores that preference.
Filename events that wake the worker wait up to 5.5 seconds for both startup tasks
before deciding takeover. Disabled, failed or overdue initialization preserves the
browser download. Terminal download events release per-ID guards after any active
handoff finishes, so a terminal event cannot trigger duplicate in-flight POSTs.

Download handoff sends cookies and request context first, then cancels/erases the
browser task only after an HTTP 2xx response with valid bridge configuration. HTTP
errors, malformed responses, timeouts and cookie retrieval failures leave the
browser download intact. POST requests are never automatically retried. Cancel
failure does not erase browser history. All filename paths call `suggest` once.

**This is not durable or exactly-once delivery.** The existing bridge response is
configuration, not a persisted-task ACK. A request processed before its response
is lost may create a second download alongside the browser's fallback. Worker
termination during handoff also requires future protocol work. The per-ID guard
only covers one worker lifetime. The app's persistent queue/ACK must be integrated
and verified before claiming durable takeover.

The preserved legacy register page/custom launch URI is not verified to start the
Harmony app. Open the app normally if disconnected. No true-browser/target-device
integration has been validated by the host tests.

Run production-module mocked tests from `XdmHarmony`:

```sh
node --experimental-vm-modules --test tests/extension/extension.test.mjs
```

Tests use the actual extension modules in isolated VM contexts, not mirrored
implementations. They need no installed packages and never log captured cookies.
