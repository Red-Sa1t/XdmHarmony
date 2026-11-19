# Production-source host checks

Run `node --test XdmHarmony/tests/host/http-client.test.cjs` from the workspace root.

The loader transpiles the actual `HttpClient.ets`; only imported platform services and timers are replaced. It does not copy the implementation. Set `XDM_TYPESCRIPT_PATH` to a TypeScript compiler path if DevEco Studio is elsewhere; local `typescript` is the final fallback.

The tests verify idle expiry releases a pending open, abort semantics, inactivity deadline refresh, error/end cleanup, late-body suppression and status fidelity when status arrives after body. An independent configured status-acquisition deadline releases open even when dataEnd arrived but the SDK status never settles. They cannot prove the SDK's actual callback order or TaskPool behavior. The delayed-status test enforces not inventing status from headers; it is not acceptance of header-first behavior. Device fact (2026-10-18, P2-U2 instrumentation): the SDK status settles only when the whole stream ends and `readTimeout` acts as a whole-transfer cap. `open()` therefore resolves a provisional 206 from a valid `Content-Range` (checked against the final status), lifts the status deadline once final-hop headers arrive and passes a 24 h `readTimeout`; heads without `Content-Range` still wait for the real status. P2-U2 S1–S4 passed on device with this behaviour.

Device acceptance still needs P2-U2 S1–S4 with saved-state restoration and byte validation, plus 80/600/2500ms timing comparison, Range-ignoring 200 and long regular windows.

## Adaptive (HLS/DASH) business shell (2026-11-06)

`adaptive-downloader.test.cjs` drives the production `AdaptiveDownloader.ets` with scripted E4 controller, F assembler, manifest client and file system fakes: resume-first then exact C.empty bootstrap (DASH segments, HLS video+audio playlists), zero manifest traffic when a plan is persisted, encrypted/manifest/missing-descriptor failures, pause drain, quarantine, assembly failure, collision-free publication with copy fallback, speed-limit policy, output naming, the `AdaptiveSource` model and the DownloadManager factory. `creation-inbox.test.cjs` covers the `download_adaptive_source` side table in real SQLite (atomic promotion, captured-descriptor pinning, rollback, corrupt payload). `bridge-durable.test.cjs` covers tracker snapshots and HLS capture through the real `/media` route. `hls-parser.test.cjs` pins RFC 3986 reference resolution with a URL mock that reproduces the device SDK base-URL defect. Device acceptance evidence: `docs/probe/e2e-adaptive-2026-11-06.log`.
