'use strict';
// Extract method bodies verbatim from an ArkUI struct. This deliberately excludes
// rendering and field initializers; callers supply platform/lifecycle state explicitly.
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.env.XDM_TYPESCRIPT_PATH || 'D:/Tools/DevEco Studio/tools/ohpm/node_modules/typescript/lib/typescript.js');
function extractMethod(source, name) {
  const match = new RegExp('^  (?:private |public )?(?:async )?' + name + '\\(', 'm').exec(source);
  if (!match) throw new Error('Production method not found: ' + name);
  const start = source.indexOf('{', match.index);
  const scanner = ts.createScanner(ts.ScriptTarget.Latest, true, ts.LanguageVariant.Standard, source.slice(start));
  let depth = 0;
  for (let token = scanner.scan(); token !== ts.SyntaxKind.EndOfFileToken; token = scanner.scan()) {
    if (token === ts.SyntaxKind.OpenBraceToken) depth++;
    if (token === ts.SyntaxKind.CloseBraceToken && --depth === 0) return source.slice(match.index, start + scanner.getTextPos());
  }
  throw new Error('Unclosed production method: ' + name);
}
function loadMethods(file, names, globals = {}, structName = '') {
  let source = fs.readFileSync(file, 'utf8');
  if (structName) { const at = source.indexOf('export struct ' + structName); if (at < 0) throw new Error('Unknown struct'); source = source.slice(at); }
  const generated = 'class Subject {\n' + names.map(name => extractMethod(source, name)).join('\n') + '\n}\nexports.Subject = Subject;';
  const compiled = ts.transpileModule(generated, { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText;
  const context = { exports: {}, ...globals };
  vm.runInNewContext(compiled, context, { filename: file });
  return context.exports.Subject;
}
module.exports = { loadMethods, extractMethod };
