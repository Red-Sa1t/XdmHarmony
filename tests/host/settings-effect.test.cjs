'use strict';
// 2026-11-22 settings usability: user agent / proxy / saved credentials / category folders reach real behaviour.
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadProduction } = require('./production-loader.cjs');
const root = path.resolve(__dirname, '../../entry/src/main/ets');
const load = (file, imports = {}) => loadProduction(path.join(root, file + '.ets'), imports);

function fresh() {
  const policy = load('core/net/TransportPolicy');
  const protocol = load('core/net/HttpProtocol', { './TransportPolicy': policy });
  const context = load('model/DownloadRequestContext', {
    '../core/net/HttpProtocol': protocol, '../core/net/TransportPolicy': policy
  });
  return { policy, protocol, context };
}
const plain = v => JSON.parse(JSON.stringify(v));
const direct = { proxyType: 1, host: null, port: 0, userName: null, password: null };

test('base64 and Basic authorization match RFC 7617 examples, including UTF-8', () => {
  const { policy } = fresh();
  assert.equal(policy.basicAuthorization('Aladdin', 'open sesame'), 'Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ==');
  assert.equal(policy.base64Utf8('test:123£'), 'dGVzdDoxMjPCow==');
  assert.equal(policy.base64Utf8(''), '');
  assert.equal(policy.base64Utf8('a'), 'YQ==');
  assert.equal(policy.base64Utf8('ab'), 'YWI=');
});

test('fallback user agent from settings is used only for manually added downloads', () => {
  const { policy, context } = fresh();
  policy.configureTransport('MyAgent/1.0', direct, []);
  const manual = new context.DownloadRequestContext();
  assert.equal(context.composeDownloadHeaders('https://a.example/f.zip', manual)['user-agent'], 'MyAgent/1.0');
  const browser = new context.DownloadRequestContext();
  browser.headers = { names: ['User-Agent'], values: [['Browser/2']] };
  assert.equal(context.composeDownloadHeaders('https://a.example/f.zip', browser)['user-agent'], 'Browser/2');
  policy.configureTransport('  ', direct, []);
  assert.match(context.composeDownloadHeaders('https://a.example/f.zip', manual)['user-agent'], /^Mozilla\/5\.0/);
});

test('saved credentials apply by host; per-download authentication wins; browser Authorization is kept', () => {
  const { policy, context } = fresh();
  policy.configureTransport('', direct, [{ host: 'https://Files.Example.com/', user: 'u', password: 'p' },
    { host: 'other.example', user: 'x', password: 'y' }]);
  const ctx = new context.DownloadRequestContext();
  assert.equal(context.composeDownloadHeaders('https://files.example.com:8443/a', ctx).Authorization,
    policy.basicAuthorization('u', 'p'));
  assert.equal(context.composeDownloadHeaders('https://nope.example/a', ctx).Authorization, undefined);
  assert.equal(context.composeDownloadHeaders('https://files.example.com/a', ctx, null,
    { userName: 'me', password: null }).Authorization, policy.basicAuthorization('me', ''));
  const browser = new context.DownloadRequestContext();
  browser.headers = { names: ['Authorization'], values: [['Bearer t']] };
  const h = context.composeDownloadHeaders('https://files.example.com/a', browser);
  assert.equal(h.authorization, 'Bearer t');
  assert.equal(h.Authorization, undefined);
});

test('proxy: per-download direct/custom overrides global; System follows settings; bad custom falls back to direct', () => {
  const { policy } = fresh();
  policy.configureTransport('', { proxyType: 2, host: ' 10.0.0.1 ', port: 3128, userName: 'pu', password: 'pp' }, []);
  assert.deepEqual(plain(policy.resolveProxy(null)), { mode: 2, host: '10.0.0.1', port: 3128, user: 'pu', password: 'pp' });
  assert.deepEqual(policy.resolveProxy({ proxyType: 0, host: null, port: 0, userName: null, password: null }).mode, 2);
  assert.equal(policy.resolveProxy(direct).mode, 1);
  assert.equal(policy.resolveProxy(undefined).mode, 2);
  policy.configureTransport('', { proxyType: 2, host: '', port: 3128, userName: null, password: null }, []);
  assert.equal(policy.resolveProxy(null).mode, 1);
  policy.configureTransport('', { proxyType: 0, host: null, port: 0, userName: null, password: null }, []);
  assert.equal(policy.resolveProxy(null).mode, 0);
});

test('rcp proxy mapping', () => {
  const policy = load('core/net/TransportPolicy');
  const rcp = load('core/adaptive/RcpProxy', { '../net/TransportPolicy': policy });
  assert.equal(rcp.rcpProxyOf({ mode: 0, host: '', port: 0, user: '', password: '' }), 'system');
  assert.equal(rcp.rcpProxyOf({ mode: 1, host: '', port: 0, user: '', password: '' }), 'no-proxy');
  assert.deepEqual(plain(rcp.rcpProxyOf({ mode: 2, host: 'h', port: 8080, user: 'a b', password: '@' })),
    { url: 'http://a%20b:%40@h:8080' });
});

test('Last-Modified parsing', () => {
  const { policy } = fresh();
  assert.equal(policy.parseHttpDate('Wed, 21 Oct 2015 07:28:00 GMT'), Date.UTC(2015, 9, 21, 7, 28, 0));
  assert.equal(policy.parseHttpDate(''), -1);
  assert.equal(policy.parseHttpDate('garbage'), -1);
});

test('category subfolder for a file name follows the edited category list', () => {
  const cat = load('core/util/CategoryAlgo');
  const folders = load('core/util/FolderAlgo', { './CategoryAlgo': cat });
  assert.equal(folders.categoryFolderFor('a.PDF', cat.DEFAULT_CATEGORIES), 'Documents');
  assert.equal(folders.categoryFolderFor('song.mp3', cat.DEFAULT_CATEGORIES), 'Music');
  assert.equal(folders.categoryFolderFor('noext', cat.DEFAULT_CATEGORIES), '');
  const custom = [new cat.CategoryDef('x', 'Books', ['.EPUB'], 'Books', false),
    new cat.CategoryDef('y', 'Bad', ['.BIN'], '../up', false)];
  assert.equal(folders.categoryFolderFor('n.epub', custom), 'Books');
  assert.equal(folders.categoryFolderFor('n.bin', custom), '');
  assert.equal(folders.categoryFolderFor('n.pdf', custom), '');
});
