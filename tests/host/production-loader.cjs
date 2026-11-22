'use strict';
const fs = require('node:fs');
const vm = require('node:vm');

const TRANSPORT_POLICY_FILE = require('node:path').join(__dirname, '../../entry/src/main/ets/core/net/TransportPolicy.ets');
const RCP_PROXY_FILE = require('node:path').join(__dirname, '../../entry/src/main/ets/core/adaptive/RcpProxy.ets');
let transportPolicy = null;

function loadProduction(file, imports, globals = {}, expose = []) {
  const candidates = [process.env.XDM_TYPESCRIPT_PATH,
    'D:/Tools/DevEco Studio/tools/ohpm/node_modules/typescript/lib/typescript.js'].filter(Boolean);
  let ts;
  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) { ts = require(candidate); break; }
  }
  if (!ts) ts = require('typescript');
  if (!expose.every(name => /^[A-Za-z_$][\w$]*$/.test(name))) throw new Error('Invalid test export');
  const source = fs.readFileSync(file, 'utf8') + (expose.length ? '\nexport { ' + expose.join(', ') + ' };\n' : '');
  const compiled = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
    fileName: file.replace(/\.ets$/, '.ts'), reportDiagnostics: true
  });
  const errors = (compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error);
  if (errors.length) throw new Error(errors.map(d => ts.flattenDiagnosticMessageText(d.messageText, '\n')).join('\n'));
  const module = { exports: {} };
  const context = vm.createContext({ module, exports: module.exports, ArrayBuffer,
    // Standard runtime facilities the engine uses for worker shared state (2026-11-19). Intervals are
    // unref'd so a scheduler a test leaves "running" cannot keep the Node process alive.
    SharedArrayBuffer, Atomics, Int32Array, Float64Array,
    setInterval: (fn, ms) => { const t = setInterval(fn, ms); if (t.unref) t.unref(); return t; },
    clearInterval: t => clearInterval(t),
    require(name) {
      // 2026-11-22: TransportPolicy is pure (no @kit imports); load the real module when a test does not mock it.
      // Tests that auto-stub every import with {} also get the real module.
      if ((name.endsWith('/TransportPolicy') || name.endsWith('/RcpProxy')) &&
        (!Object.hasOwn(imports, name) || Object.keys(imports[name] || {}).length === 0)) {
        if (name.endsWith('/RcpProxy')) return loadProduction(RCP_PROXY_FILE, {});
        if (!transportPolicy) transportPolicy = loadProduction(TRANSPORT_POLICY_FILE, {});
        return transportPolicy;
      }
      if (!Object.hasOwn(imports, name)) throw new Error('Unmocked production dependency: ' + name);
      return imports[name];
    }, ...globals });
  new vm.Script(compiled.outputText, { filename: file }).runInContext(context);
  return module.exports;
}
module.exports = { loadProduction };
