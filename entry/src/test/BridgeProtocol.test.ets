/*
 * U0.3 桥协议纯函数 Hypium 本地用例（设计书 §7-[A]-3 用例清单）。
 * 被测模块 BridgeProtocol.ets 零 @kit import，本地测试环境可直接 import。
 * 执行环境注记（同 U0.2 §7-3 口径）：本地单测 runner 本会话不可验证（用例入库不影响编译门禁，
 * assembleHap 不编译 src/test），由编码员实跑或留统一回归。
 * 用例计数：parseHead 10 + getContentLength 2 组（9 断言点）+ isKeepAlive 2 组（5 断言点）+
 * buildResponseBytes 4 + utf8Encode 4 + buildSyncJson 8 = 30 条。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  BRIDGE_PORT, ROUTE_PATHS, SYNC_MEDIA_TYPES, SYNC_TABS_WATCHER, SYNC_MATCHING_HOSTS,
  BridgeHeaders, BridgeVideoItem, SyncFields, HeadParseResult,
  appendBytes, parseHead, firstHeader, getContentLength, isKeepAlive,
  buildResponseBytes, buildSyncJson, utf8Encode
} from '../main/ets/core/bridge/BridgeProtocol';

/** 测试辅助：ASCII 字符串 → 字节（头块/样例体均为 ASCII）。 */
function asciiBytesOf(s: string): Uint8Array {
  const out: Uint8Array = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) {
    out[i] = s.charCodeAt(i);
  }
  return out;
}

/** 测试辅助：字节 → Latin-1 字符串（逐字节 fromCharCode，断言可读）。 */
function stringOf(bytes: Uint8Array): string {
  let out: string = '';
  for (let i = 0; i < bytes.length; i++) {
    out += String.fromCharCode(bytes[i]);
  }
  return out;
}

/** 测试辅助：构造 BridgeHeaders（插入序平行数组）。 */
function headersOf(names: string[], flatValues: string[]): BridgeHeaders {
  const h: BridgeHeaders = { names: names, values: [] };
  for (let i = 0; i < flatValues.length; i++) {
    const single: string[] = [flatValues[i]];
    h.values.push(single);
  }
  return h;
}

export default function bridgeProtocolTest(): void {
  describe('BridgeProtocol', () => {
    it('BRIDGE_PORT_is8597_andRouteOrder', 0, () => {
      expect(BRIDGE_PORT).assertEqual(8597);
      expect(ROUTE_PATHS[0]).assertEqual('/sync');
      expect(ROUTE_PATHS[1]).assertEqual('/download');
      expect(ROUTE_PATHS[2]).assertEqual('/media');
      expect(ROUTE_PATHS[3]).assertEqual('/tab-update');
      expect(ROUTE_PATHS[4]).assertEqual('/vid');
      expect(ROUTE_PATHS[5]).assertEqual('/clear');
      expect(ROUTE_PATHS[6]).assertEqual('/link');
      expect(ROUTE_PATHS[7]).assertEqual('/args');
    });

    it('parseHead_singlePacketComplete', 0, () => {
      const req: string = 'GET /sync HTTP/1.1\r\nHost: 127.0.0.1:8597\r\n\r\n';
      const head: HeadParseResult = parseHead(asciiBytesOf(req), 0);
      expect(head.complete).assertEqual(true);
      expect(head.failed).assertEqual(false);
      expect(head.method).assertEqual('GET');
      expect(head.path).assertEqual('/sync');
      expect(firstHeader(head.headers, 'Host')).assertEqual('127.0.0.1:8597');
      expect(head.bodyStart).assertEqual(req.length);
    });

    it('parseHead_crossPacketIncremental', 0, () => {
      const part1: Uint8Array = asciiBytesOf('GET /sync HT');
      const part2: Uint8Array = asciiBytesOf('TP/1.1\r\nHost: h\r\n\r\n');
      const first: HeadParseResult = parseHead(part1, 0);
      expect(first.complete).assertEqual(false);
      const full: Uint8Array = appendBytes(part1, part2);
      const head: HeadParseResult = parseHead(full, 0);
      expect(head.complete).assertEqual(true);
      expect(head.failed).assertEqual(false);
      expect(head.method).assertEqual('GET');
      expect(head.path).assertEqual('/sync');
    });

    it('parseHead_statusLineTooFewTokensFailed', 0, () => {
      const head: HeadParseResult = parseHead(asciiBytesOf('GET /\r\n\r\n'), 0);
      expect(head.failed).assertEqual(true);
      expect(head.complete).assertEqual(false);
    });

    it('parseHead_headerWithoutColonFailed', 0, () => {
      const noColon: HeadParseResult =
        parseHead(asciiBytesOf('GET /sync HTTP/1.1\r\nBadHeader\r\n\r\n'), 0);
      expect(noColon.failed).assertEqual(true);
      const colonFirst: HeadParseResult =
        parseHead(asciiBytesOf('GET /sync HTTP/1.1\r\n: v\r\n\r\n'), 0);
      expect(colonFirst.failed).assertEqual(true);
    });

    it('parseHead_firstColonSplitsHostPortValue', 0, () => {
      const head: HeadParseResult = parseHead(asciiBytesOf('GET /sync HTTP/1.1\r\nHost: a:b\r\n\r\n'), 0);
      expect(head.failed).assertEqual(false);
      expect(firstHeader(head.headers, 'Host')).assertEqual('a:b');
    });

    it('parseHead_crDroppedAnywhere', 0, () => {
      const head: HeadParseResult = parseHead(asciiBytesOf('Ge\rT /sync HTTP/1.1\r\n\r\n'), 0);
      expect(head.complete).assertEqual(true);
      expect(head.failed).assertEqual(false);
      expect(head.method).assertEqual('GeT');
      expect(head.path).assertEqual('/sync');
    });

    it('parseHead_duplicateHeadersAccumulateFirstWins', 0, () => {
      const head: HeadParseResult = parseHead(asciiBytesOf('GET /sync HTTP/1.1\r\nX-A: 1\r\nX-A: 2\r\n\r\n'), 0);
      expect(head.headers.names.length).assertEqual(1);
      expect(head.headers.values[0].length).assertEqual(2);
      expect(firstHeader(head.headers, 'X-A')).assertEqual('1');
    });

    it('parseHead_contentLengthKeyCaseSensitive', 0, () => {
      const head: HeadParseResult = parseHead(asciiBytesOf(
        'GET /sync HTTP/1.1\r\ncontent-length: 5\r\nContent-Length: 9\r\n\r\n'), 0);
      expect(head.headers.names.length).assertEqual(2);
      expect(getContentLength(head.headers)).assertEqual(9);
    });

    it('parseHead_bodyStartPointsAtFirstBodyByte', 0, () => {
      const req: string = 'GET /sync HTTP/1.1\r\nHost: h\r\n\r\nBODY';
      const head: HeadParseResult = parseHead(asciiBytesOf(req), 0);
      expect(head.complete).assertEqual(true);
      expect(head.bodyStart).assertEqual(req.length - 4);
      expect(stringOf(asciiBytesOf(req).slice(head.bodyStart))).assertEqual('BODY');
    });

    it('parseHead_incompleteHasNoSideEffectValues', 0, () => {
      const head: HeadParseResult = parseHead(asciiBytesOf('GET /sync HT'), 0);
      expect(head.complete).assertEqual(false);
      expect(head.failed).assertEqual(false);
      expect(head.method).assertEqual('');
      expect(head.path).assertEqual('');
      expect(head.headers.names.length).assertEqual(0);
      expect(head.bodyStart).assertEqual(12);
    });

    it('getContentLength_defaultAndDecimalAndInvalid', 0, () => {
      const none: BridgeHeaders = headersOf(['Host'], ['h']);
      expect(getContentLength(none)).assertEqual(-1);
      expect(getContentLength(headersOf(['Content-Length'], ['10']))).assertEqual(10);
      expect(getContentLength(headersOf(['Content-Length'], ['abc']))).assertEqual(-2);
      expect(getContentLength(headersOf(['Content-Length'], ['']))).assertEqual(-2);
      expect(getContentLength(headersOf(['Content-Length'], ['12.5']))).assertEqual(-2);
    });

    it('getContentLength_signedForms', 0, () => {
      expect(getContentLength(headersOf(['Content-Length'], ['-5']))).assertEqual(-5);
      expect(getContentLength(headersOf(['Content-Length'], ['+5']))).assertEqual(5);
      expect(getContentLength(headersOf(['Content-Length'], ['0x10']))).assertEqual(-2);
    });

    it('isKeepAlive_defaultFalseAndCaseInsensitive', 0, () => {
      expect(isKeepAlive(headersOf(['Host'], ['h']))).assertEqual(false);
      expect(isKeepAlive(headersOf(['Connection'], ['keep-alive']))).assertEqual(true);
      expect(isKeepAlive(headersOf(['Connection'], ['Keep-Alive']))).assertEqual(true);
      expect(isKeepAlive(headersOf(['Connection'], ['close']))).assertEqual(false);
    });

    it('isKeepAlive_multiValueTakesFirst', 0, () => {
      const h: BridgeHeaders = { names: ['Connection'], values: [] };
      const first: string[] = ['close'];
      const second: string[] = ['keep-alive'];
      h.values.push(first);
      h.values.push(second);
      expect(isKeepAlive(h)).assertEqual(false);
    });

    it('buildResponseBytes_fullByteOrder200', 0, () => {
      const names: string[] = ['Content-Type', 'Cache-Control'];
      const values: string[] = ['application/json', 'max-age=0, no-cache, must-revalidate'];
      const body: Uint8Array = asciiBytesOf('{}');
      const out: Uint8Array = buildResponseBytes(200, 'OK', names, values, body);
      const expected: string = 'HTTP/1.0 200 OK\r\n' +
        'Content-Type: application/json\r\n' +
        'Cache-Control: max-age=0, no-cache, must-revalidate\r\n' +
        'Connection: keep-alive\r\n' +
        'Content-Length: 2\r\n' +
        '\r\n' +
        '{}';
      expect(stringOf(out)).assertEqual(expected);
    });

    it('buildResponseBytes_404EmptyBodyNoContentLength', 0, () => {
      const empty: Uint8Array = new Uint8Array(0);
      const out: Uint8Array = buildResponseBytes(404, 'Not Found', [], [], empty);
      const text: string = stringOf(out);
      expect(text).assertEqual('HTTP/1.0 404 Not Found\r\nConnection: keep-alive\r\n\r\n');
      expect(text.indexOf('Content-Length')).assertEqual(-1);
    });

    it('buildResponseBytes_callerContentLengthSkippedCaseInsensitive', 0, () => {
      const names: string[] = ['content-length', 'X-A'];
      const values: string[] = ['5', 'v'];
      const out: Uint8Array = buildResponseBytes(200, 'OK', names, values, asciiBytesOf('abcde'));
      const text: string = stringOf(out);
      expect(text).assertEqual('HTTP/1.0 200 OK\r\nX-A: v\r\n' +
        'Connection: keep-alive\r\nContent-Length: 5\r\n\r\nabcde');
    });

    it('buildResponseBytes_sameNameTwoEntriesTwoLines', 0, () => {
      const names: string[] = ['X-A', 'X-A'];
      const values: string[] = ['1', '2'];
      const out: Uint8Array = buildResponseBytes(200, 'OK', names, values, new Uint8Array(0));
      const text: string = stringOf(out);
      expect(text.indexOf('X-A: 1\r\nX-A: 2\r\n')).assertEqual(17);
    });

    it('utf8Encode_asciiIdentityAndEmpty', 0, () => {
      const abc: Uint8Array = utf8Encode('ABC');
      expect(abc.length).assertEqual(3);
      expect(abc[0]).assertEqual(65);
      expect(abc[1]).assertEqual(66);
      expect(abc[2]).assertEqual(67);
      expect(utf8Encode('').length).assertEqual(0);
    });

    it('utf8Encode_cjkThreeBytes', 0, () => {
      const bytes: Uint8Array = utf8Encode('下载');
      expect(bytes.length).assertEqual(6);
      expect(bytes[0]).assertEqual(0xE4);
      expect(bytes[1]).assertEqual(0xB8);
      expect(bytes[2]).assertEqual(0x8B);
      expect(bytes[3]).assertEqual(0xE8);
      expect(bytes[4]).assertEqual(0xBD);
      expect(bytes[5]).assertEqual(0xBD);
    });

    it('utf8Encode_emojiSurrogatePairFourBytes', 0, () => {
      const bytes: Uint8Array = utf8Encode('\uD83D\uDE00');
      expect(bytes.length).assertEqual(4);
      expect(bytes[0]).assertEqual(0xF0);
      expect(bytes[1]).assertEqual(0x9F);
      expect(bytes[2]).assertEqual(0x98);
      expect(bytes[3]).assertEqual(0x80);
    });

    it('buildSyncJson_defaultFieldOrder', 0, () => {
      const fields: SyncFields = makeDefaultFields();
      const json: string = buildSyncJson(fields);
      const parsed: Record<string, Object> = JSON.parse(json) as Record<string, Object>;
      const keys: string[] = Object.keys(parsed);
      expect(keys.length).assertEqual(8);
      expect(keys.join(',')).assertEqual(
        'enabled,fileExts,blockedHosts,requestFileExts,mediaTypes,tabsWatcher,videoList,matchingHosts');
    });

    it('buildSyncJson_fileExts23ItemsInOrder', 0, () => {
      const fields: SyncFields = makeDefaultFields();
      const json: string = buildSyncJson(fields);
      const parsed: Record<string, Object> = JSON.parse(json) as Record<string, Object>;
      const exts: string[] = parsed['fileExts'] as string[];
      expect(exts.length).assertEqual(23);
      const expected: string[] = ['3GP', '7Z', 'AVI', 'BZ2', 'DEB', 'DOC', 'DOCX', 'EXE', 'ISO',
        'MSI', 'PDF', 'PPT', 'PPTX', 'RAR', 'RPM', 'XLS', 'XLSX', 'SIT', 'SITX', 'TAR', 'JAR',
        'ZIP', 'XZ'];
      for (let i = 0; i < expected.length; i++) {
        expect(exts[i]).assertEqual(expected[i]);
      }
    });

    it('buildSyncJson_blockedHosts3AndRequestFileExts15', 0, () => {
      const json: string = buildSyncJson(makeDefaultFields());
      const parsed: Record<string, Object> = JSON.parse(json) as Record<string, Object>;
      const hosts: string[] = parsed['blockedHosts'] as string[];
      expect(hosts.length).assertEqual(3);
      expect(hosts[0]).assertEqual('update.microsoft.com');
      expect(hosts[1]).assertEqual('windowsupdate.com');
      expect(hosts[2]).assertEqual('thwawte.com');
      const reqExts: string[] = parsed['requestFileExts'] as string[];
      expect(reqExts.length).assertEqual(15);
      const expected: string[] = ['MP4', 'M3U8', 'F4M', 'WEBM', 'OGG', 'MP3', 'AAC', 'FLV', 'MKV',
        'DIVX', 'MOV', 'MPG', 'MPEG', 'OPUS', 'MPD'];
      for (let i = 0; i < expected.length; i++) {
        expect(reqExts[i]).assertEqual(expected[i]);
      }
    });

    it('buildSyncJson_constantThreeTables', 0, () => {
      const json: string = buildSyncJson(makeDefaultFields());
      const parsed: Record<string, Object> = JSON.parse(json) as Record<string, Object>;
      const mediaTypes: string[] = parsed['mediaTypes'] as string[];
      expect(mediaTypes.length).assertEqual(SYNC_MEDIA_TYPES.length);
      expect(mediaTypes[0]).assertEqual('audio/');
      expect(mediaTypes[1]).assertEqual('video/');
      const tabsWatcher: string[] = parsed['tabsWatcher'] as string[];
      expect(tabsWatcher.length).assertEqual(SYNC_TABS_WATCHER.length);
      expect(tabsWatcher[0]).assertEqual('.youtube.');
      expect(tabsWatcher[1]).assertEqual('/watch?v=');
      const matchingHosts: string[] = parsed['matchingHosts'] as string[];
      expect(matchingHosts.length).assertEqual(SYNC_MATCHING_HOSTS.length);
      expect(matchingHosts[0]).assertEqual('googlevideo');
    });

    it('buildSyncJson_emptyVideoList', 0, () => {
      const json: string = buildSyncJson(makeDefaultFields());
      const at: number = json.indexOf('"videoList":[]');
      expect(at > 0).assertEqual(true);
      const afterAt: number = json.indexOf('"matchingHosts"');
      expect(json.slice(at, afterAt)).assertEqual('"videoList":[],');
    });

    it('buildSyncJson_singleVideoElementFieldOrder', 0, () => {
      const fields: SyncFields = makeDefaultFields();
      const video: BridgeVideoItem = { id: 'v1', text: 'Title', info: 'Info', tabId: '7' };
      const videos: BridgeVideoItem[] = [video];
      fields.videoList = videos;
      const json: string = buildSyncJson(fields);
      const parsed: Record<string, Object> = JSON.parse(json) as Record<string, Object>;
      const list: Object[] = parsed['videoList'] as Object[];
      const first: Record<string, Object> = list[0] as Record<string, Object>;
      const keys: string[] = Object.keys(first);
      expect(keys.join(',')).assertEqual('id,text,info,tabId');
      expect(first['id']).assertEqual('v1');
      expect(first['tabId']).assertEqual('7');
    });

    it('buildSyncJson_compactNoSpacesAfterSeparators', 0, () => {
      const json: string = buildSyncJson(makeDefaultFields());
      expect(json.indexOf(', ')).assertEqual(-1);
      expect(json.indexOf(': ')).assertEqual(-1);
    });

    it('buildSyncJson_enabledFalseSerializesFalse', 0, () => {
      const fields: SyncFields = makeDefaultFields();
      fields.enabled = false;
      const json: string = buildSyncJson(fields);
      expect(json.indexOf('{"enabled":false')).assertEqual(0);
    });
  });
}

/** 构造默认 SyncFields（对照 Config.cs:56-75 默认表逐串；测试自建，不 import 业务 Config）。 */
function makeDefaultFields(): SyncFields {
  const fileExts: string[] = ['3GP', '7Z', 'AVI', 'BZ2', 'DEB', 'DOC', 'DOCX', 'EXE', 'ISO',
    'MSI', 'PDF', 'PPT', 'PPTX', 'RAR', 'RPM', 'XLS', 'XLSX', 'SIT', 'SITX', 'TAR', 'JAR',
    'ZIP', 'XZ'];
  const blockedHosts: string[] = ['update.microsoft.com', 'windowsupdate.com', 'thwawte.com'];
  const requestFileExts: string[] = ['MP4', 'M3U8', 'F4M', 'WEBM', 'OGG', 'MP3', 'AAC', 'FLV',
    'MKV', 'DIVX', 'MOV', 'MPG', 'MPEG', 'OPUS', 'MPD'];
  const videos: BridgeVideoItem[] = [];
  const fields: SyncFields = {
    enabled: true,
    fileExts: fileExts,
    blockedHosts: blockedHosts,
    requestFileExts: requestFileExts,
    mediaTypes: SYNC_MEDIA_TYPES,
    tabsWatcher: SYNC_TABS_WATCHER,
    videoList: videos,
    matchingHosts: SYNC_MATCHING_HOSTS
  };
  return fields;
}
