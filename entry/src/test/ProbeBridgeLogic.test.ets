/*
 * U0.3 探针纯函数 Hypium 本地用例（设计书 §7-[A]-3 末组，6 条）。
 * 被测模块 ProbeBridgeLogic.ets 零 @kit import，本地测试环境可直接 import。
 * 执行环境注记（同 U0.2 §7-3 口径）：本地单测 runner 本会话不可验证，用例入库不影响编译门禁。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  SYNC_BODY_MARKER,
  ResponseHeadView,
  SyncBodyView,
  splitResponseHead,
  parseSyncBody
} from '../main/ets/probe/units/ProbeBridgeLogic';

/** 测试辅助：ASCII 字符串 → 字节。 */
function asciiBytesOf(s: string): Uint8Array {
  const out: Uint8Array = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) {
    out[i] = s.charCodeAt(i);
  }
  return out;
}

/** 测试辅助：取应答体文本（bodyStart 起 Latin-1 逐字节）。 */
function bodyTextOf(bytes: Uint8Array, view: ResponseHeadView): string {
  let out: string = '';
  for (let i = view.bodyStart; i < bytes.length; i++) {
    out += String.fromCharCode(bytes[i]);
  }
  return out;
}

export default function probeBridgeLogicTest(): void {
  describe('ProbeBridgeLogic', () => {
    it('splitResponseHead_fullResponse200', 0, () => {
      const wire: string = 'HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n' +
        'Cache-Control: max-age=0, no-cache, must-revalidate\r\nConnection: keep-alive\r\n' +
        'Content-Length: 2\r\n\r\n{}';
      const bytes: Uint8Array = asciiBytesOf(wire);
      const view: ResponseHeadView = splitResponseHead(bytes);
      expect(view.complete).assertEqual(true);
      expect(view.failed).assertEqual(false);
      expect(view.status).assertEqual(200);
      expect(view.statusLine).assertEqual('HTTP/1.0 200 OK');
      expect(view.bodyStart).assertEqual(wire.length - 2);
      expect(bodyTextOf(bytes, view)).assertEqual('{}');
      let contentType: string = '';
      for (let i = 0; i < view.headerNames.length; i++) {
        if (view.headerNames[i] === 'content-type') {
          contentType = view.headerValues[i][0];
        }
      }
      expect(contentType).assertEqual('application/json');
    });

    it('splitResponseHead_partialPacketIncomplete', 0, () => {
      const view: ResponseHeadView = splitResponseHead(asciiBytesOf('HTTP/1.0 200 OK\r\nCont'));
      expect(view.complete).assertEqual(false);
      expect(view.failed).assertEqual(false);
      expect(view.status).assertEqual(-1);
      expect(view.bodyStart).assertEqual(21);
    });

    it('splitResponseHead_headOnlyNoContentLength', 0, () => {
      const wire: string = 'HTTP/1.0 404 Not Found\r\nConnection: keep-alive\r\n\r\n';
      const view: ResponseHeadView = splitResponseHead(asciiBytesOf(wire));
      expect(view.complete).assertEqual(true);
      expect(view.status).assertEqual(404);
      expect(view.bodyStart).assertEqual(wire.length);
      expect(view.headerNames.indexOf('content-length')).assertEqual(-1);
      expect(view.headerNames.indexOf('connection')).assertEqual(0);
    });

    it('parseSyncBody_validEightFields', 0, () => {
      const body: string = '{"enabled":true,"fileExts":["ZIP"],"blockedHosts":[],' +
        '"requestFileExts":["MP4"],"mediaTypes":["audio/"],"tabsWatcher":[],"videoList":[],' +
        '"matchingHosts":["googlevideo"]}';
      const view: SyncBodyView = parseSyncBody(body);
      expect(view.jsonValid).assertEqual(true);
      expect(view.fieldCount).assertEqual(8);
      expect(view.fieldOrder).assertEqual(
        'enabled,fileExts,blockedHosts,requestFileExts,mediaTypes,tabsWatcher,videoList,matchingHosts');
      expect(body.indexOf(SYNC_BODY_MARKER)).assertEqual(1);
    });

    it('parseSyncBody_invalidText', 0, () => {
      const view: SyncBodyView = parseSyncBody('not-json');
      expect(view.jsonValid).assertEqual(false);
      expect(view.fieldCount).assertEqual(0);
      expect(view.fieldOrder).assertEqual('');
    });

    it('parseSyncBody_missingFieldsObservedNotJudged', 0, () => {
      const view: SyncBodyView = parseSyncBody('{"enabled":true}');
      expect(view.jsonValid).assertEqual(true);
      expect(view.fieldCount).assertEqual(1);
      expect(view.fieldOrder).assertEqual('enabled');
    });
  });
}
