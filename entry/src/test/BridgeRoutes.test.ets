/*
 * U6.1 八路由纯函数 Hypium 本地用例（设计书 §7-[A]-3 用例清单；单元指令指定：路由分派/
 * JSON 解析门/头剥离纯函数三项为主，嗅探数学/args 文法/头取值等按清单全落）。
 * 被测模块 BridgeProtocol/BridgeJson/VideoSniffAlgo 均零 @kit import，本地测试环境可直接加载。
 * 执行环境注记（同 U0.3 §7-3 口径）：本地单测 runner 本会话不可验证（用例入库不影响编译门禁，
 * assembleHap 不编译 src/test），由编码员实跑或留统一回归。
 * 用例计数：classifyRoute 3 + removeBlockedHeaders 5 + utf8Decode 5 + parseExtData 12（含
 * R2-F1 数字头值强转收编与 boolean 仍 throw 边界）+
 * parseExtDataArray 4 + parseArgsArray 4 + parseArgs 5 + parseHeaderArg 3 + headerValueFirst 4 +
 * getContentLengthOf 4 + isNormalVideo 6 + parentDirUri 3 + extFromMedia 5 + qualityText 2 +
 * getExtensionOf/generateUpdatedFileName 4 = 69 条断言组（≥40 达标）。
 * U6.2 增补（设计书 u6-2 §5.1-3/§1-#9）：BridgeConvergence 组 4 条——pending {url,file} 对
 * （收敛 b）、/vid 未命中静默+命中对话框事件计数（收敛 a：BridgeUiEvents 族 import 自
 * BridgeActions）、addVideoDownload(null) throw 断连锚（§4-11 随迁）、/media 登记条目
 * contentType===''（收敛 c）。**该组 import BridgeActions/CapturedVideoTracker/BridgeRoutes
 * （含 @kit 与单例）**——本地 runner 需完整运行时（设备侧 test runner 可跑；探针 P6-U2 的
 * S2/S6/S7 对同一行为在设备侧另有覆盖）。合计 69+4=73 条断言组。
 * ArkTS 红线：无 any/解构/for...in/正则字面量；箭头函数显式返回类型；对象字面量具类型。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  BridgeHeaders, removeBlockedHeaders, utf8Encode, utf8Decode, classifyRoute
} from '../main/ets/core/bridge/BridgeProtocol';
import {
  BridgeExtData,
  parseExtData, parseExtDataArray, parseArgsArray, parseArgs, parseHeaderArg,
  headerValueFirst, getContentLengthOf
} from '../main/ets/core/bridge/BridgeJson';
import {
  SniffState, createSniffState, parentDirUri, isNormalVideo, extFromMedia,
  qualityText, getExtensionOf, generateUpdatedFileName
} from '../main/ets/core/bridge/VideoSniffAlgo';
import {
  PendingBatchLink, pendingBatchLinksOf
} from '../main/ets/core/bridge/BridgeActions';
import { CapturedVideoTracker, TrackedVideo } from '../main/ets/core/bridge/CapturedVideoTracker';
import { handleRoute } from '../main/ets/core/bridge/BridgeRoutes';
import { BridgeInboxItem, DownloadCreationRequest } from '../main/ets/model/DownloadCreationRequest';

/** 断言辅助：调用应抛（throw=断连门语义），返回是否真抛。 */
function throwsOn(call: () => void): boolean {
  try {
    call();
    return false;
  } catch (e) {
    return true;
  }
}

/** 测试辅助：构造 BridgeHeaders（插入序平行数组，单值/多值混合）。 */
function headersOf(names: string[], flatValues: string[][]): BridgeHeaders {
  const h: BridgeHeaders = { names: names.slice(), values: [] };
  for (let i = 0; i < flatValues.length; i++) {
    h.values.push(flatValues[i].slice());
  }
  return h;
}

/** 测试辅助：ASCII 串 → 字节。 */
function asciiBytesOf(s: string): Uint8Array {
  const out: Uint8Array = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) {
    out[i] = s.charCodeAt(i);
  }
  return out;
}

export default function bridgeRoutesTest(): void {
  describe('BridgeRoutes', () => {
    // ────────────── classifyRoute（§7-3 第一组） ──────────────

    it('classifyRoute_eightPathsByOrder', 0, () => {
      expect(classifyRoute('/sync')).assertEqual(0);
      expect(classifyRoute('/download')).assertEqual(1);
      expect(classifyRoute('/media')).assertEqual(2);
      expect(classifyRoute('/tab-update')).assertEqual(3);
      expect(classifyRoute('/vid')).assertEqual(4);
      expect(classifyRoute('/clear')).assertEqual(5);
      expect(classifyRoute('/link')).assertEqual(6);
      expect(classifyRoute('/args')).assertEqual(7);
    });

    it('classifyRoute_queryNotStripped', 0, () => {
      expect(classifyRoute('/sync?x=1')).assertEqual(-1);
    });

    it('classifyRoute_trailingSlashAndEmptyUnknown', 0, () => {
      expect(classifyRoute('/sync/')).assertEqual(-1);
      expect(classifyRoute('')).assertEqual(-1);
    });

    // ────────────── removeBlockedHeaders（§7-3 第二组：黑名单精确等值/一次删除/仅请求头） ──────────────

    it('removeBlockedHeaders_allFourteenExactNamesDeleted', 0, () => {
      const names: string[] = ['accept', 'if', 'authorization', 'proxy', 'connection',
        'expect', 'TE', 'upgrade', 'range', 'cookie', 'transfer-encoding', 'content-type',
        'content-length', 'content-encoding'];
      const vals: string[][] = [];
      for (let i = 0; i < names.length; i++) {
        const single: string[] = ['v' + String(i)];
        vals.push(single);
      }
      const out: BridgeHeaders = removeBlockedHeaders(headersOf(names, vals));
      expect(out.names.length).assertEqual(0);
      expect(out.values.length).assertEqual(0);
    });

    it('removeBlockedHeaders_caseInsensitiveExactButNotPrefix', 0, () => {
      // 大写 Cookie/混合 cOnnection 精确等值被删；Accept 删而 Accept-Encoding 留；If-None-Match 留
      const h: BridgeHeaders = headersOf(
        ['User-Agent', 'Cookie', 'cOnnection', 'Accept', 'Accept-Encoding', 'If-None-Match'],
        [['UA'], ['a=b'], ['close'], ['*/*'], ['identity'], ['W/"1"']]);
      const out: BridgeHeaders = removeBlockedHeaders(h);
      expect(out.names.indexOf('User-Agent')).assertEqual(0);
      expect(out.names.indexOf('Cookie')).assertEqual(-1);
      expect(out.names.indexOf('cOnnection')).assertEqual(-1);
      expect(out.names.indexOf('Accept')).assertEqual(-1);
      expect(out.names.indexOf('Accept-Encoding')).assertLargerOrEqual(0);
      expect(out.names.indexOf('If-None-Match')).assertLargerOrEqual(0);
      expect(out.names.length).assertEqual(3);
    });

    it('removeBlockedHeaders_duplicateNameDeletesFirstOnly', 0, () => {
      const h: BridgeHeaders = headersOf(['cookie', 'Cookie', 'Referer'],
        [['a=1'], ['a=2'], ['r']]);
      const out: BridgeHeaders = removeBlockedHeaders(h);
      expect(out.names.length).assertEqual(2);
      expect(out.names.indexOf('cookie')).assertEqual(-1);
      expect(out.names[0]).assertEqual('Cookie');
      expect(out.values[0][0]).assertEqual('a=2');
      expect(out.names[1]).assertEqual('Referer');
    });

    it('removeBlockedHeaders_inputUnchanged', 0, () => {
      const h: BridgeHeaders = headersOf(['Accept', 'Referer'], [['*/*'], ['r']]);
      removeBlockedHeaders(h);
      expect(h.names.length).assertEqual(2);
      expect(h.names[0]).assertEqual('Accept');
      expect(h.values[0][0]).assertEqual('*/*');
    });

    it('removeBlockedHeaders_responseShapedContainerSameBehavior', 0, () => {
      // 函数无侧差别：ResponseHeaders 形容器（Content-Type/Content-Length 在列）传入同规则处理
      // ——"仅请求头"由调用方不传保证（源 RemoveBlockedHeaders 只读 RequestHeaders）
      const h: BridgeHeaders = headersOf(['Content-Type', 'Content-Length', 'X-Custom'],
        [['video/mp4'], ['1024'], ['c']]);
      const out: BridgeHeaders = removeBlockedHeaders(h);
      expect(out.names.length).assertEqual(1);
      expect(out.names[0]).assertEqual('X-Custom');
    });

    // ────────────── utf8Decode（§7-3 第三组） ──────────────

    it('utf8Decode_asciiIdentity', 0, () => {
      expect(utf8Decode(asciiBytesOf('XDM bridge 8597'))).assertEqual('XDM bridge 8597');
      expect(utf8Decode(new Uint8Array(0))).assertEqual('');
    });

    it('utf8Decode_cjkRoundTrip', 0, () => {
      expect(utf8Decode(utf8Encode('下载'))).assertEqual('下载');
    });

    it('utf8Decode_emojiFourByteRoundTrip', 0, () => {
      expect(utf8Decode(utf8Encode('🎬视频'))).assertEqual('🎬视频');
    });

    it('utf8Decode_loneInvalidByteToReplacement', 0, () => {
      const bytes: Uint8Array = new Uint8Array([0x61, 0xFF, 0x62]);
      const out: string = utf8Decode(bytes);
      expect(out.length).assertEqual(3);
      expect(out.charCodeAt(0)).assertEqual(0x61);
      expect(out.charCodeAt(1)).assertEqual(0xFFFD);
      expect(out.charCodeAt(2)).assertEqual(0x62);
    });

    it('utf8Decode_truncatedThreeByteToReplacement', 0, () => {
      // '下' = E4 B8 8B；截去末续字节 → 恰一个 U+FFFD（R3-F1：截断序列整体消费，.NET 同貌）
      const bytes: Uint8Array = new Uint8Array([0xE4, 0xB8]);
      const out: string = utf8Decode(bytes);
      expect(out.length).assertEqual(1);
      expect(out.charCodeAt(0)).assertEqual(0xFFFD);
      // 截断后重同步：起始+已确认续字节整体消费后，后续合法字节正常解码
      const resync: string = utf8Decode(new Uint8Array([0xE4, 0xB8, 0x41]));
      expect(resync.length).assertEqual(2);
      expect(resync.charCodeAt(0)).assertEqual(0xFFFD);
      expect(resync.charCodeAt(1)).assertEqual(0x41);
    });

    // ────────────── parseExtData（§7-3 第四组） ──────────────

    it('parseExtData_fullFieldObject', 0, () => {
      const data: BridgeExtData | null = parseExtData(
        '{"url":"https://h/a.mp4","cookie":"a=b","file":"Clip","method":"GET",' +
        '"userAgent":"UA","tabUrl":"https://t/","tabId":"7","tabTitle":"T","referer":"r",' +
        '"fileSize":10,"mimeType":"video/mp4","vid":"v1",' +
        '"requestHeaders":{"Referer":["r"],"User-Agent":["UA"]},' +
        '"responseHeaders":{"Content-Type":["video/mp4"],"Content-Length":["10"]}}');
      expect(data !== null).assertTrue();
      const d: BridgeExtData = data as BridgeExtData;
      expect(d.url).assertEqual('https://h/a.mp4');
      expect(d.cookie).assertEqual('a=b');
      expect(d.file).assertEqual('Clip');
      expect(d.method).assertEqual('GET');
      expect(d.userAgent).assertEqual('UA');
      expect(d.tabUrl).assertEqual('https://t/');
      expect(d.tabId).assertEqual('7');
      expect(d.tabTitle).assertEqual('T');
      expect(d.referer).assertEqual('r');
      expect(d.fileSize).assertEqual(10);
      expect(d.mimeType).assertEqual('video/mp4');
      expect(d.vid).assertEqual('v1');
      const req: BridgeHeaders = d.requestHeaders as BridgeHeaders;
      expect(req.names.length).assertEqual(2);
      expect(req.names[0]).assertEqual('Referer');
      expect(req.values[0][0]).assertEqual('r');
      const res: BridgeHeaders = d.responseHeaders as BridgeHeaders;
      expect(res.names.length).assertEqual(2);
      expect(res.values[1][0]).assertEqual('10');
    });

    it('parseExtData_nullLiteralToNull', 0, () => {
      expect(parseExtData('null')).assertNull();
    });

    it('parseExtData_badJsonThrows', 0, () => {
      expect(throwsOn((): void => {
        parseExtData('not json');
      })).assertTrue();
    });

    it('parseExtData_filenameKeyFallsToFile', 0, () => {
      // 双键兼容：/download 的 filename 落到 file（§2.2）；sanitize 归 buildBridgeMessage 此处原值
      const data: BridgeExtData | null = parseExtData('{"url":"https://h/a.zip","filename":"setup.exe"}');
      expect(data !== null).assertTrue();
      expect((data as BridgeExtData).file).assertEqual('setup.exe');
    });

    it('parseExtData_fileKeyPreferredOverFilename', 0, () => {
      const data: BridgeExtData | null = parseExtData(
        '{"file":"a.mp4","filename":"b.zip"}');
      expect((data as BridgeExtData).file).assertEqual('a.mp4');
    });

    it('parseExtData_numberUrlThrows', 0, () => {
      expect(throwsOn((): void => {
        parseExtData('{"url":123}');
      })).assertTrue();
    });

    it('parseExtData_headersValueNotArrayThrows', 0, () => {
      expect(throwsOn((): void => {
        parseExtData('{"requestHeaders":{"a":"b"}}');
      })).assertTrue();
    });

    it('parseExtData_numberHeaderValueCoerced', 0, () => {
      // R2-F1：chrome app.js:225-229 / firefox app.js:170 主线流量 responseHeaders
      // ["Content-Length"]=[fz]（fz=+size 为 number）——按 Newtonsoft ReadAsString 语义
      // String(v) 强转收编不 throw；强转后 getContentLengthOf 正常出数
      const data: BridgeExtData | null = parseExtData(
        '{"url":"https://h/a.zip","filename":"setup.exe","fileSize":2048000,' +
        '"requestHeaders":{"User-Agent":["UA"]},' +
        '"responseHeaders":{"Content-Length":[2048000],"Content-Type":' +
        '["application/octet-stream"]}}');
      expect(data !== null).assertTrue();
      const res: BridgeHeaders = (data as BridgeExtData).responseHeaders as BridgeHeaders;
      expect(res.names.length).assertEqual(2);
      expect(headerValueFirst(res, 'Content-Length')).assertEqual('2048000');
      expect(headerValueFirst(res, 'Content-Type')).assertEqual('application/octet-stream');
      expect(getContentLengthOf(res)).assertEqual(2048000);
    });

    it('parseExtData_booleanHeaderValueStillThrows', 0, () => {
      // R2-F1 例外仅限 number 元素：其余类型严格门不变（throw→断连）
      expect(throwsOn((): void => {
        parseExtData('{"responseHeaders":{"X-Flag":[true]}}');
      })).assertTrue();
    });

    it('parseExtData_absentFieldsAllNull', 0, () => {
      const data: BridgeExtData | null = parseExtData('{}');
      expect(data !== null).assertTrue();
      const d: BridgeExtData = data as BridgeExtData;
      expect(d.url).assertNull();
      expect(d.cookie).assertNull();
      expect(d.requestHeaders).assertNull();
      expect(d.responseHeaders).assertNull();
      expect(d.file).assertNull();
      expect(d.method).assertNull();
      expect(d.tabId).assertNull();
      expect(d.tabTitle).assertNull();
      expect(d.fileSize).assertNull();
      expect(d.vid).assertNull();
    });

    it('parseExtData_extraFieldsIgnored', 0, () => {
      const data: BridgeExtData | null = parseExtData('{"url":"u","unknownKey":[1,2,3]}');
      expect((data as BridgeExtData).url).assertEqual('u');
    });

    it('parseExtData_topLevelArrayThrows', 0, () => {
      expect(throwsOn((): void => {
        parseExtData('[{"url":"u"}]');
      })).assertTrue();
    });

    // ────────────── parseExtDataArray（§7-3 第五组） ──────────────

    it('parseExtDataArray_twoElements', 0, () => {
      const arr = parseExtDataArray(
        '[{"url":"https://h/a.zip","file":"a.zip"},{"url":"https://h/b.zip"}]');
      expect(arr !== null).assertTrue();
      expect((arr as BridgeExtData[]).length).assertEqual(2);
      expect((arr as BridgeExtData[])[1].url).assertEqual('https://h/b.zip');
    });

    it('parseExtDataArray_nullLiteralToNull', 0, () => {
      expect(parseExtDataArray('null')).assertNull();
    });

    it('parseExtDataArray_objectBodyThrows', 0, () => {
      expect(throwsOn((): void => {
        parseExtDataArray('{"url":"u"}');
      })).assertTrue();
    });

    it('parseExtDataArray_nonObjectElementThrows', 0, () => {
      expect(throwsOn((): void => {
        parseExtDataArray('[{"url":"u"},"str"]');
      })).assertTrue();
    });

    // ────────────── parseArgsArray（§7-3 第六组） ──────────────

    it('parseArgsArray_stringList', 0, () => {
      const arr: string[] | null = parseArgsArray('["--url","http://h/a"]');
      expect(arr !== null).assertTrue();
      expect((arr as string[]).length).assertEqual(2);
      expect((arr as string[])[1]).assertEqual('http://h/a');
    });

    it('parseArgsArray_nullLiteralToNull', 0, () => {
      expect(parseArgsArray('null')).assertNull();
    });

    it('parseArgsArray_emptyListToEmpty', 0, () => {
      const arr: string[] | null = parseArgsArray('[]');
      expect(arr !== null).assertTrue();
      expect((arr as string[]).length).assertEqual(0);
    });

    it('parseArgsArray_numberElementThrows', 0, () => {
      // Newtonsoft 数字→字符串强转不复刻（§4-9）
      expect(throwsOn((): void => {
        parseArgsArray('[1]');
      })).assertTrue();
    });

    // ────────────── parseArgs 文法（§7-3 第七组；ArgsProcessor.cs:155-194） ──────────────

    it('parseArgs_singleSwitchDoesNotSwallowValue', 0, () => {
      const map = parseArgs(['--quit', 'v']);
      const quit: string[] | undefined = map['--quit'];
      expect(quit !== undefined && quit.length === 0).assertTrue();
      const url: string[] | undefined = map['--url'];
      expect(url !== undefined && url.length === 1).assertTrue();
      expect(url !== undefined && url[0] === 'v').assertTrue();
    });

    it('parseArgs_nameValueSwitchAccumulates', 0, () => {
      const map = parseArgs(['-H', 'a:1', '-H', 'b:2']);
      const h: string[] | undefined = map['-H'];
      expect(h !== undefined && h.length === 2).assertTrue();
      expect(h !== undefined && h[0] === 'a:1').assertTrue();
      expect(h !== undefined && h[1] === 'b:2').assertTrue();
    });

    it('parseArgs_bareValuesReplaceUrlWholesale', 0, () => {
      // 整体替换非追加：多裸值 count 恒 1 取后者（:182-184）
      const map = parseArgs(['a', 'b']);
      const url: string[] | undefined = map['--url'];
      expect(url !== undefined && url.length === 1).assertTrue();
      expect(url !== undefined && url[0] === 'b').assertTrue();
    });

    it('parseArgs_xdmAppPrefixSkipped', 0, () => {
      const map = parseArgs(['xdm+app://abc', '--quit']);
      expect(map['xdm+app://abc']).assertUndefined();
      const quit: string[] | undefined = map['--quit'];
      expect(quit !== undefined && quit.length === 0).assertTrue();
    });

    it('parseArgs_switchReappearanceKeepsBucket', 0, () => {
      // '-' 开头重复出现不重置已有值表（:167-169 ContainsKey 门）
      const map = parseArgs(['--header', 'a:1', '--media', '--header', 'b:2']);
      const h: string[] | undefined = map['--header'];
      expect(h !== undefined && h.length === 2).assertTrue();
      const media: string[] | undefined = map['--media'];
      expect(media !== undefined && media.length === 0).assertTrue();
    });

    it('parseHeaderArg_nameValueSplit', 0, () => {
      const kv: string[] | null = parseHeaderArg('Name:Value');
      expect(kv !== null).assertTrue();
      expect((kv as string[])[0]).assertEqual('Name');
      expect((kv as string[])[1]).assertEqual('Value');
    });

    it('parseHeaderArg_noColonNull', 0, () => {
      expect(parseHeaderArg('novalue')).assertNull();
    });

    it('parseHeaderArg_colonAtIndexZeroNull', 0, () => {
      expect(parseHeaderArg(':v')).assertNull();
    });

    // ────────────── headerValueFirst（§7-3 第八组；Message.cs:85-126） ──────────────

    it('headerValueFirst_exactKeyHit', 0, () => {
      const h: BridgeHeaders = headersOf(['Content-Type'], [['video/mp4', 'x']]);
      expect(headerValueFirst(h, 'Content-Type')).assertEqual('video/mp4');
    });

    it('headerValueFirst_lowercaseFallbackHit', 0, () => {
      const h: BridgeHeaders = headersOf(['content-type'], [['video/mp4']]);
      expect(headerValueFirst(h, 'Content-Type')).assertEqual('video/mp4');
    });

    it('headerValueFirst_multiValueTakesFirst', 0, () => {
      const h: BridgeHeaders = headersOf(['Accept'], [['a', 'b']]);
      expect(headerValueFirst(h, 'Accept')).assertEqual('a');
    });

    it('headerValueFirst_missingAndNullContainerNull', 0, () => {
      const h: BridgeHeaders = headersOf(['X-A'], [['a']]);
      expect(headerValueFirst(h, 'X-B')).assertNull();
      expect(headerValueFirst(null, 'X-A')).assertNull();
    });

    // ────────────── getContentLengthOf（§7-3 第九组；Message.cs:128-137） ──────────────

    it('getContentLengthOf_decimalParsed', 0, () => {
      const h: BridgeHeaders = headersOf(['Content-Length'], [['1048576']]);
      expect(getContentLengthOf(h)).assertEqual(1048576);
    });

    it('getContentLengthOf_garbageToZero', 0, () => {
      const h: BridgeHeaders = headersOf(['Content-Length'], [['12abc']]);
      expect(getContentLengthOf(h)).assertEqual(0);
      const empty: BridgeHeaders = headersOf(['Content-Length'], [['']]);
      expect(getContentLengthOf(empty)).assertEqual(0);
    });

    it('getContentLengthOf_absentToZero', 0, () => {
      const h: BridgeHeaders = headersOf(['X-A'], [['a']]);
      expect(getContentLengthOf(h)).assertEqual(0);
      expect(getContentLengthOf(null)).assertEqual(0);
    });

    it('getContentLengthOf_negativeStringPassesThrough', 0, () => {
      // Int32.Parse 接受负号——负值放行，>0 判定归调用方（isNormalVideo ①）
      const h: BridgeHeaders = headersOf(['Content-Length'], [['-5']]);
      expect(getContentLengthOf(h)).assertEqual(-5);
    });

    // ────────────── isNormalVideo 五条件（§7-3 第十组；VideoUrlHelper.cs:67-90） ──────────────

    it('isNormalVideo_sizeGate', 0, () => {
      const state: SniffState = createSniffState();
      // ① size>0 且 <minBytes → false；size=0 过①（0 不小于 minBytes 且不大于 0）
      expect(isNormalVideo(state, 'video/mp4', 'https://h/a.mp4', 1, null, 1024)).assertFalse();
      expect(isNormalVideo(state, 'video/mp4', 'https://h/a.mp4', 0, null, 1024)).assertTrue();
      expect(isNormalVideo(state, 'video/mp4', 'https://h/a.mp4', 1024, null, 1024)).assertTrue();
    });

    it('isNormalVideo_m3u8TabHit', 0, () => {
      const state: SniffState = createSniffState();
      state.m3u8Tabs.add('9');
      expect(isNormalVideo(state, 'video/mp4', 'https://h/a.mp4', 999999, '9', 1024)).assertFalse();
      expect(isNormalVideo(state, 'video/mp4', 'https://h/a.mp4', 999999, '8', 1024)).assertTrue();
    });

    it('isNormalVideo_initMp4SideEffect', 0, () => {
      const state: SniffState = createSniffState();
      expect(isNormalVideo(state, 'video/mp4', 'https://h/a/b/init.mp4?x=1', 999999, null, 1024))
        .assertFalse();
      expect(state.suspectedFragments.has('https://h/a/b/')).assertTrue();
    });

    it('isNormalVideo_siblingOfSuspectedFragment', 0, () => {
      const state: SniffState = createSniffState();
      state.suspectedFragments.add('https://h/a/b/');
      expect(isNormalVideo(state, 'video/mp4', 'https://h/a/b/seg-1.mp4', 999999, null, 1024))
        .assertFalse();
    });

    it('isNormalVideo_streamFragmentMarkers', 0, () => {
      const state: SniffState = createSniffState();
      // ⑤ contentType 含 f4f / m4s → false；url 原始大小写含 abst/f4x/.fbcdn/9614 → false
      expect(isNormalVideo(state, 'video/x-f4f', 'https://h/a', 999999, null, 1024)).assertFalse();
      expect(isNormalVideo(state, 'application/mp4 m4s', 'https://h/a', 999999, null, 1024))
        .assertFalse();
      expect(isNormalVideo(state, 'video/mp4', 'https://h/abst/1', 999999, null, 1024)).assertFalse();
      expect(isNormalVideo(state, 'video/mp4', 'https://h/f4x/1', 999999, null, 1024)).assertFalse();
      expect(isNormalVideo(state, 'video/mp4', 'https://video.fbcdn.net/1', 999999, null, 1024))
        .assertFalse();
      expect(isNormalVideo(state, 'video/mp4', 'http://127.0.0.1:9614/v', 999999, null, 1024))
        .assertFalse();
      // 大小写敏感性：URL 大写 ABST 不命中（C# Contains 序数敏感）
      expect(isNormalVideo(state, 'video/mp4', 'https://h/ABST/1', 999999, null, 1024)).assertTrue();
    });

    it('isNormalVideo_plainMp4TrueAndNullTypeFalse', 0, () => {
      const state: SniffState = createSniffState();
      expect(isNormalVideo(state, 'video/mp4', 'https://h/big.mp4', 5242880, '1', 1048576))
        .assertTrue();
      expect(isNormalVideo(state, null, 'https://h/big.mp4', 5242880, '1', 1048576)).assertFalse();
    });

    // ────────────── parentDirUri（§7-3 第十一组） ──────────────

    it('parentDirUri_stripQueryTakeDirPrefix', 0, () => {
      expect(parentDirUri('https://h/a/b/init.mp4?x=1')).assertEqual('https://h/a/b/');
      expect(parentDirUri('https://h/a/b/init.mp4#frag')).assertEqual('https://h/a/b/');
    });

    it('parentDirUri_trailingSlashUnchanged', 0, () => {
      expect(parentDirUri('https://h/a/b/')).assertEqual('https://h/a/b/');
    });

    it('parentDirUri_rootLevelAndNoSlash', 0, () => {
      expect(parentDirUri('https://h/init.mp4')).assertEqual('https://h/');
      expect(parentDirUri('relative')).assertEqual('relative');
    });

    // ────────────── extFromMedia 映射序（§7-3 第十二组；VideoUrlHelper.cs:631-675） ──────────────

    it('extFromMedia_videoTypes', 0, () => {
      expect(extFromMedia('video/mp4', '')).assertEqual('mp4');
      expect(extFromMedia('video/x-flv', '')).assertEqual('flv');
      expect(extFromMedia('video/webm', '')).assertEqual('mkv');
      expect(extFromMedia('audio/x-matroska', '')).assertEqual('mkv');
      expect(extFromMedia('video/x-mkv', '')).assertEqual('mkv');
    });

    it('extFromMedia_audioMpegEqualsNotContains', 0, () => {
      // Equals 语义：'audio/mpeg' 等值命中；'audio/mpeg;x' 不命中（非 Contains）；含 'audio/mp3' 命中
      expect(extFromMedia('audio/mpeg', '')).assertEqual('mp3');
      expect(extFromMedia('audio/mpeg;x', '')).assertNull();
      expect(extFromMedia('xaudio/mp3', '')).assertEqual('mp3');
    });

    it('extFromMedia_aacAndM4a', 0, () => {
      expect(extFromMedia('audio/aac', '')).assertEqual('aac');
      expect(extFromMedia('audio/aac;chars=16', '')).assertEqual('aac');
      expect(extFromMedia('audio/mp4', '')).assertEqual('m4a');
    });

    it('extFromMedia_urlFallbacks', 0, () => {
      expect(extFromMedia('application/octet-stream', 'https://h/v/clip.mp4')).assertEqual('mp4');
      expect(extFromMedia('application/octet-stream', 'https://h/v/clip.mkv')).assertEqual('mkv');
      expect(extFromMedia('application/octet-stream', 'https://h/v/clip.ts')).assertEqual('ts');
    });

    it('extFromMedia_noneMatchNull', 0, () => {
      expect(extFromMedia('text/html', 'https://h/page')).assertNull();
    });

    // ────────────── qualityText（§7-3 第十三组；VideoUrlHelper.cs:687） ──────────────

    it('qualityText_extAndSize', 0, () => {
      const text: string = qualityText('mp4', 5242880);
      expect(text.indexOf('[MP4] ')).assertEqual(0);
      expect(text.indexOf('5.0M')).assertLargerOrEqual(0);
    });

    it('qualityText_zeroSizeTrailingSpaceKept', 0, () => {
      expect(qualityText('ts', 0)).assertEqual('[TS] ');
    });

    // ────────────── getExtensionOf / generateUpdatedFileName（§7-3 第十四组） ──────────────

    it('getExtensionOf_basics', 0, () => {
      expect(getExtensionOf('a.mp4')).assertEqual('.mp4');
      expect(getExtensionOf('a')).assertEqual('');
      expect(getExtensionOf('a.')).assertEqual('.');
      expect(getExtensionOf('.bashrc')).assertEqual('.bashrc');
      expect(getExtensionOf('dir/sub/b.tar.gz')).assertEqual('.gz');
    });

    it('generateUpdatedFileName_extKeptAndSanitized', 0, () => {
      expect(generateUpdatedFileName('old.mp4', 'New: Title')).assertEqual('New_ Title.mp4');
    });

    it('generateUpdatedFileName_noExtOldFile', 0, () => {
      expect(generateUpdatedFileName('oldname', 'New Title')).assertEqual('New Title');
    });

    it('generateUpdatedFileName_emptyNewNameFallsBack', 0, () => {
      // sanitizeFileName('') → 'file'（FileNames 空结果兜底）
      expect(generateUpdatedFileName('a.mp4', '')).assertEqual('file.mp4');
    });
  });

  // ────────────── U6.2 收敛 a/b/c 回归（设计书 §5.1-3；import 自 BridgeActions） ──────────────

  describe('BridgeConvergence', () => {
    it('convergence_pendingPairsCarryFile', 0, () => {
      // 收敛 b：/link pending 存 {url,file} 对（U6.1 现实现丢弃 file 只存 url——R4-F5 勘误闭环）
      const first: DownloadCreationRequest = new DownloadCreationRequest();
      first.url = 'https://h/f/pack.zip'; first.name = 'pack.zip';
      const second: DownloadCreationRequest = new DownloadCreationRequest();
      second.url = 'https://h/f/doc.pdf'; second.name = 'doc.pdf';
      const item: BridgeInboxItem = new BridgeInboxItem();
      item.kind = 'batch'; item.requests = [first, second];
      const pending: PendingBatchLink[] = pendingBatchLinksOf([item]);
      expect(pending.length >= 2).assertTrue();
      const last: PendingBatchLink = pending[pending.length - 1];
      const prev: PendingBatchLink = pending[pending.length - 2];
      expect(last.url).assertEqual('https://h/f/doc.pdf');
      expect(last.file).assertEqual('doc.pdf');
      expect(prev.file).assertEqual('pack.zip');
    });

    it('convergence_vidMissSilentAndHitLookupPreservesSource', 0, async (): Promise<void> => {
      // Durable hit/enqueue ordering now requires a database; covered by production-source host tests.
      const tracker: CapturedVideoTracker = CapturedVideoTracker.getInstance();
      tracker.clearVideoList();
      const before: number = tracker.getTrackedVideos().length;
      await tracker.addVideoDownload('nonexistent-vid-u62'); // 未命中静默
      expect(tracker.getTrackedVideos().length).assertEqual(before);
      tracker.addSingleSourceVideo('Conv Clip.mp4', 5242880, '', 'https://h/v/conv.mp4',
        null, null, '[MP4] 5.0M', '90', 'https://t/');
      const videos: TrackedVideo[] = tracker.getTrackedVideos();
      expect(videos.length).assertEqual(before + 1);
      const hit = tracker.lookupVideoDownload(videos[videos.length - 1].id);
      expect(hit.found).assertTrue();
      expect(hit.uri).assertEqual('https://h/v/conv.mp4');
      expect(hit.contentType).assertEqual('');
      tracker.clearVideoList();
    });

    it('convergence_vidNullThrows', 0, async (): Promise<void> => {
      // §4-11 锚随迁：ContainsKey(null)→ArgumentNullException→断连——不得改静默
      let rejected: boolean = false;
      try {
        await CapturedVideoTracker.getInstance().addVideoDownload(null);
      } catch (e) {
        rejected = true;
      }
      expect(rejected).assertTrue();
    });

    it('convergence_mediaRegisteredWithEmptyContentType', 0, async (): Promise<void> => {
      // 收敛 c：processNormalVideo 登记条目 contentType===''（源 ProcessNormalVideo 不设 ContentType）
      // 本例只验路由登记，不依赖上一用例留下的singleton条目或preview UUID随机性。
      const tracker: CapturedVideoTracker = CapturedVideoTracker.getInstance();
      tracker.clearVideoList();
      const body: string = '{"url":"https://h/v/conv2.mp4","file":"Conv2","requestHeaders":' +
        '{"User-Agent":["UA"]},"responseHeaders":{"Content-Type":["video/mp4"],' +
        '"Content-Length":["5242880"]},"tabId":"91","tabUrl":"https://t2/"}';
      try {
        await handleRoute(2, utf8Encode(body)); // /media
        const videos: TrackedVideo[] = tracker.getTrackedVideos();
        expect(videos.length).assertEqual(1);
        expect(videos[0].uri).assertEqual('https://h/v/conv2.mp4');
        expect(videos[0].contentType).assertEqual('');
        expect(videos[0].file).assertEqual('Conv2.mp4');
      } finally {
        tracker.clearVideoList();
      }
    });

    it('convergence_normalVideoImmuneToTabUpdateRename', 0, async (): Promise<void> => {
      // U6.2 IR-F1 修复回归：processNormalVideo 登记不携带 tabUrl（源 ProcessNormalVideo 只设
      // TabId），故 /tab-update 传入该 tabUrl 时 normal 条目名不可被改写
      const tracker: CapturedVideoTracker = CapturedVideoTracker.getInstance();
      tracker.clearVideoList();
      const body: string = '{"url":"https://h/v/ir1.mp4","file":"IrClip","requestHeaders":' +
        '{"User-Agent":["UA"]},"responseHeaders":{"Content-Type":["video/mp4"],' +
        '"Content-Length":["1048576"]},"tabId":"95","tabUrl":"https://t-ir/"}';
      try {
        await handleRoute(2, utf8Encode(body)); // /media 登记
        tracker.updateMediaTitle('https://t-ir/', 'Renamed Title');
        const videos: TrackedVideo[] = tracker.getTrackedVideos();
        expect(videos.length).assertEqual(1);
        expect(videos[0].tabUrl).assertEqual('');  // 登记不携带（镜像源）
        expect(videos[0].file).assertEqual('IrClip.mp4'); // 未被改名
      } finally {
        tracker.clearVideoList();
      }
    });

    it('convergence_argsMediaTabUrlMissingTitleAborts', 0, async (): Promise<void> => {
      // U6.2 F1 修复回归：--media-tab-url 缺 --media-tab-title 时整体中止（源 ArgsProcessor.cs:23-24
      // 取 title 先于 UpdateMediaTitle、缺键 KeyNotFoundException 被 :130-133 吞→零改名）
      const tracker: CapturedVideoTracker = CapturedVideoTracker.getInstance();
      tracker.clearVideoList();
      tracker.addSingleSourceVideo('F1 Clip.mp4', 2097152, '', 'https://h/v/f1.mp4',
        null, null, '[MP4] 2.0M', '96', 'https://t-f1/');
      try {
        // /args body 须为 JSON 字符串数组（parseArgsArray，BridgeJson.ets:187）
        await handleRoute(7, utf8Encode('["--media-tab-url=https://t-f1/"]')); // 无 title 键
        const videos: TrackedVideo[] = tracker.getTrackedVideos();
        expect(videos.length).assertEqual(1);
        expect(videos[0].file).assertEqual('F1 Clip.mp4'); // 整体中止，未被误改为 file.mp4
      } finally {
        tracker.clearVideoList();
      }
    });
  });
}
