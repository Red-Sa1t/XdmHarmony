/*
 * U1.2 传输协议纯函数 Hypium 本地用例（设计书 §7-[A]-3 用例清单，11 条）。
 * 被测模块零 @kit import，本地测试环境可直接 import。
 * 执行注记（U2.3 更新 2026-09-28）：U2.3 设计会话已接通 `hvigorw test` 脚本化入口并实跑——
 * BUILD SUCCESSFUL、本套 11 条全绿；本轮实跑暴露 headerValueOf 混合大小写查询恒未命中的真实
 * 缺陷（sixDefaultHeaders 两例失败，actual=''），修复落在被测函数 HttpProtocol.ets（查询名
 * 小写化）而非用例——用例期望值本就正确。详见 docs/design/u2-3-engine-fidelity-DESIGN.md §3.7。
 * U2.3 追加：describe('closedWindowProbe') 15 条（设计书 §5.3）——闭窗校验链 206 分支/CL 校验
 * （含 Content-Range 缺失）/探测推导/Range 头两形态逐字锚/headerValueOf 大小写回归锚，
 * 收口缺口清单 ②③④ 的 HttpProtocol 侧（设计书 §7-[A]-6）。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  sixDefaultHeaders,
  copyHeadersWithRange,
  refererOf,
  isSuccessStatus,
  isCompressed,
  parseContentRange,
  isUriValid,
  headerValueOf,
  resumeRangeHeader,
  closedRangeHeader,
  effectiveProbeStatus,
  probeResumable,
  probeTotalSize,
  closedWindowValidationError,
  CWV_OK,
  CWV_STATUS,
  CWV_TOTAL,
  CWV_START,
  ContentRangeParts
} from '../main/ets/core/net/HttpProtocol';

export default function httpProtocolTest(): void {
  describe('HttpProtocol', () => {
    it('reopen_preserves_credentials_and_replaces_all_range_casings', 0, () => {
      const original: Record<string, string> = {
        'Cookie': 'session=test-only', 'Referer': 'https://origin.test/watch',
        'X-Stream-Key': 'test-key', 'Accept-Encoding': 'identity',
        'range': 'bytes=0-10', 'RANGE': 'bytes=99-'
      };
      const reopened: Record<string, string> = copyHeadersWithRange(original, 'bytes=1048576-2097151');
      expect(reopened['Cookie']).assertEqual('session=test-only');
      expect(reopened['Referer']).assertEqual('https://origin.test/watch');
      expect(reopened['X-Stream-Key']).assertEqual('test-key');
      expect(reopened['Accept-Encoding']).assertEqual('identity');
      expect(reopened['Range']).assertEqual('bytes=1048576-2097151');
      expect(Object.keys(reopened).length).assertEqual(5);
      expect(original['range']).assertEqual('bytes=0-10');
      expect(original['RANGE']).assertEqual('bytes=99-');
      reopened['Cookie'] = 'changed';
      expect(original['Cookie']).assertEqual('session=test-only');
    });

    it('sixDefaultHeaders_sixKeysAndValues', 0, () => {
      const headers: Record<string, string> = sixDefaultHeaders('http://h/a/b.bin');
      expect(Object.keys(headers).length).assertEqual(6);
      expect(headerValueOf(headers, 'User-Agent'))
        .assertEqual('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/97.0.4692.99 Safari/537.36');
      expect(headerValueOf(headers, 'Accept')).assertEqual('*/*');
      expect(headerValueOf(headers, 'Accept-Encoding')).assertEqual('identity');
      expect(headerValueOf(headers, 'Accept-Language')).assertEqual('en-US');
      expect(headerValueOf(headers, 'Accept-Charset')).assertEqual('*');
      expect(headerValueOf(headers, 'Referer')).assertEqual('http://h/a/');
    });

    it('sixDefaultHeaders_refererDirectoryOfFile', 0, () => {
      const headers: Record<string, string> = sixDefaultHeaders('http://h/a/b?q=1');
      expect(headerValueOf(headers, 'Referer')).assertEqual('http://h/a/');
    });

    it('sixDefaultHeaders_refererRootPath', 0, () => {
      expect(refererOf('http://h')).assertEqual('http://h/');
    });

    it('sixDefaultHeaders_trailingSlashUnchanged', 0, () => {
      expect(refererOf('http://h/a/')).assertEqual('http://h/a/');
    });

    it('isSuccessStatus_200_206_true', 0, () => {
      expect(isSuccessStatus(200)).assertEqual(true);
      expect(isSuccessStatus(206)).assertEqual(true);
    });

    it('isSuccessStatus_302_404_false', 0, () => {
      expect(isSuccessStatus(302)).assertEqual(false);
      expect(isSuccessStatus(404)).assertEqual(false);
      expect(isSuccessStatus(500)).assertEqual(false);
      expect(isSuccessStatus(0)).assertEqual(false);
    });

    it('isCompressed_gzipDeflate_true', 0, () => {
      const gzip: Record<string, string> = {};
      gzip['Content-Encoding'] = 'gzip';
      expect(isCompressed(gzip)).assertEqual(true);
      const deflateUpper: Record<string, string> = {};
      deflateUpper['content-encoding'] = 'DEFLATE';
      expect(isCompressed(deflateUpper)).assertEqual(true);
      const chunked: Record<string, string> = {};
      chunked['Transfer-Encoding'] = 'gzip, chunked';
      expect(isCompressed(chunked)).assertEqual(true);
    });

    it('isCompressed_identity_false', 0, () => {
      const identity: Record<string, string> = {};
      identity['Content-Encoding'] = 'identity';
      expect(isCompressed(identity)).assertEqual(false);
      const empty: Record<string, string> = {};
      expect(isCompressed(empty)).assertEqual(false);
    });

    it('parseContentRange_fullForm', 0, () => {
      const parts: ContentRangeParts = parseContentRange('bytes 262144-4194303/4194304');
      expect(parts.start).assertEqual(262144);
      expect(parts.end).assertEqual(4194303);
      expect(parts.total).assertEqual(4194304);
    });

    it('parseContentRange_invalidForms', 0, () => {
      const noSlash: ContentRangeParts = parseContentRange('bytes 0-');
      expect(noSlash.start).assertEqual(-1);
      expect(noSlash.total).assertEqual(-1);
      const starForm: ContentRangeParts = parseContentRange('bytes */4194304');
      expect(starForm.start).assertEqual(-1);
      expect(starForm.end).assertEqual(-1);
      expect(starForm.total).assertEqual(4194304);
      const garbage: ContentRangeParts = parseContentRange('garbage');
      expect(garbage.start).assertEqual(-1);
      expect(garbage.total).assertEqual(-1);
    });

    it('isUriValid_httpHttpsOnly', 0, () => {
      expect(isUriValid('http://host/file.bin')).assertEqual(true);
      expect(isUriValid('https://host/file.bin')).assertEqual(true);
      expect(isUriValid('ftp://host/file.bin')).assertEqual(false);
      expect(isUriValid('')).assertEqual(false);
      expect(isUriValid('host/file.bin')).assertEqual(false);
      expect(isUriValid('http://')).assertEqual(false);
    });
  });

  // U2.3 追加：闭窗校验/探测推导/Range 头形态（设计书 §5.3，15 条）。
  // 收口缺口：②206 分支（闭窗强检/compressed 改写/拒绝路径）③Content-Length 校验
  // （total 比对/gate/缺头）④恢复偏移头锚（closedRangeHeader/resumeRangeHeader）。
  describe('closedWindowProbe', () => {
    it('effectiveProbeStatus_compressedRewrites206To200', 0, () => {
      // PieceGrabber.cs:181-188：Compressed 且 StatusCode==PartialContent → status=OK(200)
      expect(effectiveProbeStatus(206, true)).assertEqual(200);
      // 非 206 透传（改写仅命中 206）
      expect(effectiveProbeStatus(200, true)).assertEqual(200);
    });

    it('effectiveProbeStatus_uncompressedPassthrough', 0, () => {
      // :181-188 else 分支：非 compressed 恒透传
      expect(effectiveProbeStatus(206, false)).assertEqual(206);
      expect(effectiveProbeStatus(200, false)).assertEqual(200);
      expect(effectiveProbeStatus(404, false)).assertEqual(404);
    });

    it('probeResumable_derivation', 0, () => {
      // PieceGrabber.cs:441 逐字：Resumable = Compressed ? false : StatusCode==206
      expect(probeResumable(false, 206)).assertEqual(true);
      expect(probeResumable(true, 206)).assertEqual(false);
      expect(probeResumable(false, 200)).assertEqual(false);
      expect(probeResumable(true, 200)).assertEqual(false);
    });

    it('probeTotalSize_compressedMinusOne', 0, () => {
      // :440 ResourceSize = Compressed ? -1 : ContentLength（:181-188 连锁：compressed 总长不可知）
      expect(probeTotalSize(true, 1000, 42)).assertEqual(-1);
    });

    it('probeTotalSize_contentLengthAndRangeFallback', 0, () => {
      // 调度器 PieceGrabber.ets:709-713 推导链：CL>0 优先；CL 缺失/0 落 Content-Range total
      // （U2.1 既有加固，源码 :440 无 fallback——D24 同族，用例按调度器行为锁定）
      expect(probeTotalSize(false, 1000, 999)).assertEqual(1000);
      expect(probeTotalSize(false, 0, 4194304)).assertEqual(4194304);
      // 两源皆缺（CL=-1、头缺 total=-1）→ -1（未知大小/整流模式值域）
      expect(probeTotalSize(false, -1, -1)).assertEqual(-1);
    });

    it('closedWindowValidationError_pass206', 0, () => {
      // :194-201 三检全过（合法 206：total 与 fileSize 相符、start 与窗口起点相符）
      expect(CWV_OK).assertEqual(0);
      expect(closedWindowValidationError(206, false, 4194304, 4194304, 1200, 1200))
        .assertEqual(CWV_OK);
    });

    it('closedWindowValidationError_statusNot206', 0, () => {
      // :194-196 !firstRequest && status != PartialContent → NonRetriable(InvalidResponse,
      // "Resume not supported")——200 也拒（闭窗续传请求只接受 206）
      expect(CWV_STATUS).assertEqual(1);
      expect(closedWindowValidationError(200, false, 4194304, 4194304, 1200, 1200))
        .assertEqual(CWV_STATUS);
      expect(closedWindowValidationError(404, false, 4194304, 4194304, 1200, 1200))
        .assertEqual(CWV_STATUS);
    });

    it('closedWindowValidationError_compressed206Rejected', 0, () => {
      // :181-188+196 链：compressed 206 改写为 200 → 非 206 拒——compressed 响应断点续传禁用锁面
      expect(closedWindowValidationError(206, true, 4194304, 4194304, 1200, 1200))
        .assertEqual(CWV_STATUS);
    });

    it('closedWindowValidationError_totalMismatch', 0, () => {
      // :197-201 + SS.cs:510-517：FileSize>0 → FileSize != streamSize（streamSize=Content-Range
      // total，DN.cs:94-98）→ mismatch → NonRetriable(InvalidResponse,"Content length mismatch")
      expect(CWV_TOTAL).assertEqual(2);
      expect(closedWindowValidationError(206, false, 4194303, 4194304, 1200, 1200))
        .assertEqual(CWV_TOTAL);
    });

    it('closedWindowValidationError_totalGateFileSizeNotPositive', 0, () => {
      // SS.cs:512-516 gate：FileSize>0 不成立（-1/0）→ IsFileChangedOnServer return false
      // → total 检跳过（即使 total 不符）
      expect(closedWindowValidationError(206, false, 4194303, -1, 1200, 1200))
        .assertEqual(CWV_OK);
      expect(closedWindowValidationError(206, false, 4194303, 0, 1200, 1200))
        .assertEqual(CWV_OK);
    });

    it('closedWindowValidationError_contentRangeMissing', 0, () => {
      // DN.cs:94-98 缺头 ContentRangeLength=-1；SS.cs:510-517 FileSize>0 → -1 != FileSize
      // → mismatch 照常触发（研究 fact 1 注记修正，设计书 §0-2——"永不触发"不成立）
      expect(closedWindowValidationError(206, false, -1, 4194304, 1200, 1200))
        .assertEqual(CWV_TOTAL);
    });

    it('closedWindowValidationError_startMismatch', 0, () => {
      // U1.2 D9 加固（源码无此检；调度器 PieceGrabber.ets:685-690）：start=500 ≠ windowStart=1200
      // → CWV_START；检序在 total 后（调度器序）——total 与 start 双违规时 CWV_TOTAL 先行
      expect(CWV_START).assertEqual(3);
      expect(closedWindowValidationError(206, false, 4194304, 4194304, 500, 1200))
        .assertEqual(CWV_START);
      expect(closedWindowValidationError(206, false, 4194303, 4194304, 500, 1200))
        .assertEqual(CWV_TOTAL);
    });

    it('headerValueOf_caseInsensitiveQueryName', 0, () => {
      // D19 回归锚（U2.3 实跑发现的缺陷修复）：键与查询名双侧不区分大小写
      const headers: Record<string, string> = {};
      headers['User-Agent'] = 'UA-X';
      headers['Content-Encoding'] = 'identity';
      expect(headerValueOf(headers, 'user-agent')).assertEqual('UA-X');
      expect(headerValueOf(headers, 'USER-AGENT')).assertEqual('UA-X');
      expect(headerValueOf(headers, 'User-Agent')).assertEqual('UA-X');
      expect(headerValueOf(headers, 'cOnTeNt-EnCoDiNg')).assertEqual('identity');
      // 未命中 → ''
      expect(headerValueOf(headers, 'accept')).assertEqual('');
    });

    it('resumeRangeHeader_openEndedForms', 0, () => {
      // WRE.cs:168-177 AddRange(start) 单参 → 'bytes={start}-'（open-ended）；
      // PG.cs:389 首请求 AddRange(0)
      expect(resumeRangeHeader(0)).assertEqual('bytes=0-');
      expect(resumeRangeHeader(1048576)).assertEqual('bytes=1048576-');
    });

    it('closedRangeHeader_closedIntervalForm', 0, () => {
      // WRE.cs:160-163 AddRange(long,long) → 'bytes={start}-{end}' 闭区间含端点；
      // PG.cs:394 AddRange(Offset+Downloaded, Offset+Length-1)；与 windowAndTotal_math 的
      // [1200,1499] 交叉锚
      expect(closedRangeHeader(1200, 1499)).assertEqual('bytes=1200-1499');
      expect(closedRangeHeader(0, 4194303)).assertEqual('bytes=0-4194303');
    });
  });
}
