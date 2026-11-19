import { describe, it, expect } from '@ohos/hypium';
import { DownloadRequestContext, DownloadRequestHeaders, cloneDownloadRequestContext,
  serializeDownloadRequestContext, parseDownloadRequestContext,
  composeDownloadHeaders } from '../main/ets/model/DownloadRequestContext';

export default function downloadRequestContextTest(): void {
  describe('DownloadRequestContext', () => {
    it('prototypeNamedHeaderIsRepresentedAsOwnCaseEquivalentField', 0, () => {
      const context: DownloadRequestContext = new DownloadRequestContext();
      context.headers = { names: ['__proto__'], values: [['custom-value']] };
      const headers: Record<string, string> = composeDownloadHeaders('https://host/file', context);
      const key: string | undefined = Object.keys(headers).find((name: string): boolean =>
        name.toLowerCase() === '__proto__');
      expect(key !== undefined && headers[key] === 'custom-value').assertTrue();
    });
    it('nullHeadersUseDefaultsButEmptyHeadersDoNot', 0, () => {
      const context: DownloadRequestContext = new DownloadRequestContext();
      expect(composeDownloadHeaders('http://host/a/file', context)['referer']).assertEqual('http://host/a/');
      const empty: DownloadRequestHeaders = { names: [], values: [] };
      context.headers = empty;
      expect(Object.keys(composeDownloadHeaders('http://host/a/file', context)).length).assertEqual(1);
    });
    it('independentCookieOverridesAllCaseVariants', 0, () => {
      const context: DownloadRequestContext = new DownloadRequestContext();
      context.headers = { names: ['cookie', 'Cookie'], values: [['old=1'], ['old=2']] };
      context.cookies = 'sid=opaque; theme=dark';
      const headers: Record<string, string> = composeDownloadHeaders('http://host/file', context);
      expect(headers['Cookie']).assertEqual(context.cookies);
      expect(Object.keys(headers).filter((name: string): boolean => name.toLowerCase() === 'cookie').length)
        .assertEqual(1);
    });
    it('engineRangeIdentityAndMultiValues', 0, () => {
      const context: DownloadRequestContext = new DownloadRequestContext();
      context.headers = { names: ['Range', 'range', 'Accept-Encoding', 'accept-encoding', 'X-Test', 'x-test',
        'Referer', 'Content-Type'], values: [['bytes=8-'], ['bytes=9-'], ['gzip'], ['br'], ['a', 'b'],
        ['c'], ['https://origin/private'], ['video/mp4']] };
      const headers: Record<string, string> = composeDownloadHeaders('http://host/file', context, 'bytes=20-30');
      expect(headers['Range']).assertEqual('bytes=20-30');
      expect(headers['Accept-Encoding']).assertEqual('identity');
      expect(headers['x-test']).assertEqual('a, b, c');
      expect(headers['referer']).assertEqual('https://origin/private');
      expect(Object.keys(headers).length).assertEqual(4);
    });
    it('headerCookieJoinsWithSemicolonWhenSeparateCookieNull', 0, () => {
      const context: DownloadRequestContext = new DownloadRequestContext();
      context.headers = { names: ['Cookie'], values: [['a=1', 'b=2']] };
      expect(composeDownloadHeaders('http://host', context)['cookie']).assertEqual('a=1; b=2');
    });
    it('emptyCookieIsNotNull', 0, () => {
      const context: DownloadRequestContext = new DownloadRequestContext();
      context.cookies = '';
      expect(composeDownloadHeaders('http://host', context)['Cookie']).assertEqual('');
      const restored: DownloadRequestContext | null = parseDownloadRequestContext(serializeDownloadRequestContext(context));
      expect(restored !== null && restored.cookies === '').assertTrue();
    });
    it('cloneAndRoundTripPreserveAllValuesWithoutAliasing', 0, () => {
      const context: DownloadRequestContext = new DownloadRequestContext();
      context.headers = { names: ['X-Test'], values: [['a', 'b']] };
      context.cookies = 'a=1';
      const clone: DownloadRequestContext = cloneDownloadRequestContext(context);
      context.headers.values[0][0] = 'changed';
      expect(clone.headers !== null && clone.headers.values[0][0] === 'a').assertTrue();
      const restored: DownloadRequestContext | null = parseDownloadRequestContext(serializeDownloadRequestContext(clone));
      expect(restored !== null && restored.headers !== null && restored.headers.values[0].join(',') === 'a,b')
        .assertTrue();
    });
    it('invalidDocumentsNeverBecomeDefaultCredentials', 0, () => {
      const invalid: string[] = ['null', '[]', '{}', '{',
        '{"schema":2,"headers":null,"cookies":null}',
        '{"schema":1,"headers":{"names":["X"],"values":[]},"cookies":null}',
        '{"schema":1,"headers":{"names":["Bad Header"],"values":[["x"]]},"cookies":null}',
        '{"schema":1,"headers":{"names":["X"],"values":[[2]]},"cookies":null}',
        '{"schema":1,"headers":null,"cookies":"a\\r\\nX: evil"}'];
      for (let i = 0; i < invalid.length; i++) {
        expect(parseDownloadRequestContext(invalid[i]) === null).assertTrue();
      }
    });
    it('rangeAbsentNeverReplaysBrowserRange', 0, () => {
      const context: DownloadRequestContext = new DownloadRequestContext();
      context.headers = { names: ['rAnGe'], values: [['bytes=123-']] };
      expect(Object.keys(composeDownloadHeaders('http://host', context)).length).assertEqual(1);
    });
  });
}
