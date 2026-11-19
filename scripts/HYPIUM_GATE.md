# Hypium execution gate

`hvigor test` can exit zero and print `BUILD SUCCESSFUL` even when Hypium reports assertion failures. The observed r2 run had five such errors. Use this wrapper to combine process status, execution markers and the actual case result file.

Run an existing tested hvigor invocation by putting its executable and separate arguments after `--`:

```powershell
node scripts/run-hypium.cjs --expected-tests 432 --output ../migration-runs/hypium -- 'D:/Tools/DevEco Studio/tools/node/node.exe' '<hvigor-js-entry>' <the-existing-hvigor-test-arguments>
```

The wrapper does not invent toolchain flags or mutate environment settings. Inherit the same SDK/Node environment used for the known working invocation. Use an actual executable (Node plus its JS entry on Windows), not a shell command string or `.cmd` shim. `--project` defaults to this XdmHarmony directory; `--result` defaults to `entry/.test/default/intermediates/test/coverage_data/test_result.txt`. Adjust `--expected-tests` deliberately when registered scope changes. Without that option, the gate proves all cases reported by this run passed, but cannot prove an intended suite was not accidentally omitted.

For already captured evidence:

```powershell
node scripts/run-hypium.cjs --check-log ../migration-runs/202610080259/hypium-r3.log --result entry/.test/default/intermediates/test/coverage_data/test_result.txt --child-exit-code 0 --expected-tests 432
```

Historical mode requires the caller to provide the matching result file and observed child exit code. It cannot independently prove two supplied files came from the same run. A log alone always fails closed. UTF-8 and BOM-marked PowerShell UTF-16 logs are accepted. Never pair an old failed log with a newer result and claim success: errors in either input block the gate.

Passing requires:

- Measured child exit zero in run mode, or explicitly supplied observed zero in historical mode.
- No `ERROR:`, assertion/uncaught rejection or `BUILD FAILED` evidence.
- Exactly one ordered sequence: completed GenerateUnitTestResult, completed module test, BUILD SUCCESSFUL. Cached/incomplete/concatenated task logs do not substitute for execution.
- `test_result.txt` has nonzero tests, all individual class/test/result records paired, no duplicate cases, a unique terminal summary, every test passed and no failures/errors/ignores. Optional expected count must match exactly.
- Run mode result is newly created or refreshed during that process, not an unchanged previous result.

Every launched run has a unique artifact directory containing raw combined `hvigor.log`, a copy of `test_result.txt` when present and `verdict.json` with timestamps, child status and result fingerprints. Old artifacts are retained. Exit 0 means accepted evidence, 1 means failed/incomplete evidence, 2 means CLI or filesystem error. Run only one hvigor test process for a given project/result path at a time; the wrapper cannot attribute a concurrently overwritten SDK result to the right process.

Validation: `node --test tests/host/hypium-gate.test.cjs` executes parser checks plus fake child-process integrations; it does not launch hvigor. Actual r2 log is rejected despite supplied exit zero; current r3 plus its 432/432 case file passes. The coverage HTML/coverageReport.json are coverage artifacts, not assertion counts, and are not used as success proof. This is a preview Hypium gate, not device/network/persistence acceptance.
