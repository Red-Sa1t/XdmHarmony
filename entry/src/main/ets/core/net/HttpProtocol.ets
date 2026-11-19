/*
 * U1.2 纯传输协议函数层（设计书 §5.1）：零 @kit import——Hypium 本地单测可直接加载；
 * 业务/引擎侧复用无运行时副作用。禁 import probe/**（分层红线）。
 * 对照源码锚：
 *   sixDefaultHeaders   ← SingleSourceHTTPDownloader.cs:519-530 CreateDefaultHeaders 逐键
 *                         （User-Agent 取 Config.cs:52 DefaultFallbackUserAgent 字面量，内联本模块
 *                         勿引 Config——保持零依赖，决策：UA 变更属 U4.3 设置面）
 *   refererOf           ← SingleSourceHTTPDownloader.cs:528 new Uri(state.Url, ".").ToString()
 *                         （"." 相对引用 = "目录"：最后一个 '/'（含）前缀 + 保证尾 '/'）
 *   isSuccessStatus     ← WebRequestExtensions.cs:15-29 EnsureSuccessStatusCode 白名单 200/206
 *   isCompressed        ← Utils.cs:9-15（值含 gzip/deflate）；设计书 §5.1 扩展为 content-encoding
 *                         与 transfer-encoding 双键不区分大小写取值（D4 identity 下正常不触发）
 *   parseContentRange   ← 语义对齐 ProbeHttpLogic.ets:66-91（业务侧独立实现，禁 import probe/）；
 *                         total='/' 后（HttpResponse.cs:16-32 ContentRangeLength =
 *                         GetTotalLengthFromContentRange，DotNetHttpSession.cs:94-98）
 *   resumeRangeHeader   ← WebRequestExtensions.cs:168-177 AddRange(start) 单参 → 'bytes=N-'
 *                         （单分片 open-ended，等价 PieceGrabber.cs:389 AddRange(0) 与 :393-394）
 *   isUriValid          ← Helpers.cs:45-56（scheme 小写比较仅 http/https；纯字符串实现）
 * U2.3 追加（设计书 §5.1）：闭窗校验/探测推导纯函数层——effectiveProbeStatus（PG.cs:181-188）、
 *   probeResumable（:441）、probeTotalSize（:440+调度器 :709-713 推导链）、
 *   closedWindowValidationError（:181-202 检查序 + :510-517 + U1.2 D9 加固）+ CWV_* 四结果码
 *   （§2.1 表；调度器 PieceGrabber.ets:673-691 内联形的逐字抽离，运行时调用点不切换）。
 * ArkTS 合规：禁正则字面量（无正则需求）、Record 字面量引号键、显式返回类型。
 */

/** 六键默认头（对照 SingleSourceHTTPDownloader.cs:519-530 逐键；UA 字面量锚 Config.cs:52） */
export function sixDefaultHeaders(url: string): Record<string, string> {
  const headers: Record<string, string> = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/97.0.4692.99 Safari/537.36',
    'Accept': '*/*',
    'Accept-Encoding': 'identity',
    'Accept-Language': 'en-US',
    'Accept-Charset': '*',
    'Referer': refererOf(url)
  };
  return headers;
}

/** Reopening a segment preserves its request context; only its owned byte range changes. */
export function copyHeadersWithRange(headers: Record<string, string>, range: string): Record<string, string> {
  const result: Record<string, string> = {};
  const keys: string[] = Object.keys(headers);
  for (let i = 0; i < keys.length; i++) {
    if (keys[i].toLowerCase() !== 'range') {
      result[keys[i]] = headers[keys[i]];
    }
  }
  result['Range'] = range;
  return result;
}

/** Referer 目录形式（new Uri(url, ".") 语义）：去 query/hash 后取最后一个 '/'（含）前缀；
 * 无路径 → host 尾 '/'。纯字符串（indexOf/lastIndexOf），无正则。 */
export function refererOf(url: string): string {
  let base: string = url;
  const qm: number = base.indexOf('?');
  if (qm >= 0) {
    base = base.slice(0, qm);
  }
  const hash: number = base.indexOf('#');
  if (hash >= 0) {
    base = base.slice(0, hash);
  }
  const schemeEnd: number = base.indexOf('://');
  if (schemeEnd < 0) {
    return url;
  }
  const from: number = schemeEnd + 3;
  const lastSlash: number = base.lastIndexOf('/');
  if (lastSlash >= from) {
    return base.slice(0, lastSlash + 1);
  }
  return base + '/';
}

/** 成功状态白名单（WebRequestExtensions.cs:15-29）：仅 200（ResponseCode.OK, d.ts:2767）与
 * 206（ResponseCode.PARTIAL, d.ts:2881）；其余（含 3xx 已被栈自动跟随、4xx/5xx）一律 false。 */
export function isSuccessStatus(status: number): boolean {
  return status === 200 || status === 206;
}

/** Content-Range 解析产物；解析失败字段取 -1（DotNetHttpSession.cs:94-98 -1 语义） */
export interface ContentRangeParts {
  start: number;
  end: number;
  total: number;
}

/** Content-Range 解析（语义对齐 ProbeHttpLogic.parseContentRange，业务侧独立实现）：
 * 'bytes 262144-4194303/4194304' → {262144,4194303,4194304}；星号/total 形态 → {-1,-1,total}；
 * 无 '/' 或非法 → {-1,-1,-1}；end 空缺（'bytes 0-/N'）→ end=-1。 */

export function parseContentRange(value: string): ContentRangeParts {
  const slash: number = value.indexOf('/');
  if (slash < 0) {
    return makeParts(-1, -1, -1);
  }
  const totalPart: string = value.slice(slash + 1).trim();
  const total: number = Number(totalPart);
  if (totalPart.length === 0 || !Number.isFinite(total) || total < 0) {
    return makeParts(-1, -1, -1);
  }
  const rangePart: string = value.slice(0, slash).trim();
  const tokens: string[] = rangePart.split(' ');
  const byteRange: string = tokens[tokens.length - 1];
  const dash: number = byteRange.indexOf('-');
  if (byteRange === '*' || dash < 0) {
    return makeParts(-1, -1, total);
  }
  const start: number = Number(byteRange.slice(0, dash).trim());
  const endText: string = byteRange.slice(dash + 1).trim();
  const end: number = endText.length === 0 ? -1 : Number(endText);
  if (!Number.isFinite(start) || start < 0 || !Number.isFinite(end)) {
    return makeParts(-1, -1, -1);
  }
  return makeParts(start, end, total);
}

function makeParts(start: number, end: number, total: number): ContentRangeParts {
  const parts: ContentRangeParts = { start: start, end: end, total: total };
  return parts;
}

/** 压缩判定（Utils.cs:9-15 + 设计书 §5.1 双键扩展）：content-encoding/transfer-encoding
 * 不区分大小写取键，值小写化后含 gzip 或 deflate 即 true；identity/缺失 → false。
 * D4：强制 Accept-Encoding: identity 下正常不触发，防御分支保留（compressed→总长-1/禁续传/206 视作 200）。 */
export function isCompressed(header: Record<string, string>): boolean {
  const encoding: string = headerValueOf(header, 'content-encoding');
  const transfer: string = headerValueOf(header, 'transfer-encoding');
  return containsCompressionToken(encoding) || containsCompressionToken(transfer);
}

function containsCompressionToken(value: string): boolean {
  if (value.length === 0) {
    return false;
  }
  const lower: string = value.toLowerCase();
  return lower.indexOf('gzip') >= 0 || lower.indexOf('deflate') >= 0;
}

/** 不区分大小写头取键（业务侧独立实现，语义同 ProbeHttpLogic.headerOf）；未命中返回 ''。
 * U2.3 实跑修复（hvigor test 四失败之一）：查询名 name 亦须小写化——原实现只小写化键侧，
 * 混合大小写查询（'User-Agent'）恒未命中返回 ''，与其"不区分大小写"契约相悖；
 * 全部生产调用点传小写名（SegmentWorker.ets:201-203、本文件 :111-112），行为零变化。 */
export function headerValueOf(headers: Record<string, string>, name: string): string {
  const keys: string[] = Object.keys(headers);
  const wanted: string = name.toLowerCase();
  for (let i = 0; i < keys.length; i++) {
    if (keys[i].toLowerCase() === wanted) {
      return headers[keys[i]];
    }
  }
  return '';
}

/** 续传 Range 头（WebRequestExtensions.cs:168-177 AddRange(start) 单参 open-ended 形态） */
export function resumeRangeHeader(offsetBytes: number): string {
  return 'bytes=' + String(offsetBytes) + '-';
}

/** 闭区间 Range 头（U2.1 追加；DotNetHttpSession.cs:46-52 AddRange(long,long) → RangeHeaderValue(start,end)
 * 与 WebRequestExtensions.cs:160-163 bytes={start}-{end} 逐字形态；消费锚 PieceGrabber.cs:393-394
 * AddRange(piece.Offset+piece.Downloaded, piece.Offset+piece.Length-1)）。
 * 与 resumeRangeHeader 的分工：本函数承载多分片闭窗口派发（约束⑤，U1.2 D19 open-ended 简化弃用）；
 * resumeRangeHeader 保留供 P1-U2 归档探针（ProbeDownload.ets S6 自证请求）。 */
export function closedRangeHeader(start: number, end: number): string {
  return 'bytes=' + String(start) + '-' + String(end);
}

/** URI 有效性（Helpers.cs:45-56 端口）：空/无 '://' → false；scheme 小写比较仅 http/https；
 * host 段非空。纯字符串实现，try/catch 包裹（保真 C# 版的 catch 形态）。 */
export function isUriValid(url: string): boolean {
  try {
    const trimmed: string = url.trim();
    if (trimmed.length === 0) {
      return false;
    }
    const schemeEnd: number = trimmed.indexOf('://');
    if (schemeEnd <= 0) {
      return false;
    }
    const scheme: string = trimmed.slice(0, schemeEnd).toLowerCase();
    if (scheme !== 'http' && scheme !== 'https') {
      return false;
    }
    const rest: string = trimmed.slice(schemeEnd + 3);
    let host: string = rest;
    const pathStart: number = rest.indexOf('/');
    if (pathStart >= 0) {
      host = rest.slice(0, pathStart);
    }
    const qm: number = host.indexOf('?');
    if (qm >= 0) {
      host = host.slice(0, qm);
    }
    const hash: number = host.indexOf('#');
    if (hash >= 0) {
      host = host.slice(0, hash);
    }
    return host.length > 0;
  } catch (e) {
    return false;
  }
}

// ===================== U2.3 闭窗校验/探测推导纯函数（设计书 §5.1） =====================
// 零 @kit、不 import EngineMath（CWV 结果码内聚本模块）——Hypium 直接加载 + 主源集零新依赖。

/** 闭窗校验结果码（设计书 §2.1 表）：0=三检全过；1=非 206（含 compressed 改写后非 206）→
 * NonRetriable(InvalidResponse,"Resume not supported")（PieceGrabber.cs:194-196）；2=Content-Range
 * total 与 fileSize 不符（含缺头 total=-1）→ NonRetriable(InvalidResponse,"Content length mismatch")
 * （:197-201 + SingleSourceHTTPDownloader.cs:510-517）；3=Content-Range start 与派发窗口起点不符
 * → InvalidResponse（源码无此检，U1.2 D9 加固，调度器 PieceGrabber.ets:685-690）。
 * ≠0 由消费方映射 ERR_INVALID_RESPONSE(5)——本单元不接线（红线④）。 */
export const CWV_OK: number = 0;
export const CWV_STATUS: number = 1;
export const CWV_TOTAL: number = 2;
export const CWV_START: number = 3;

/** compressed 改写（PieceGrabber.cs:181-188 逐字）：compressed 且 206 → 200；其余透传。
 * 调度器内联参照 PieceGrabber.ets:650-653（运行时不切换，等价抽离）。 */
export function effectiveProbeStatus(status: number, compressed: boolean): number {
  if (compressed && status === 206) {
    return 200;
  }
  return status;
}

/** 探测 Resumable（PieceGrabber.cs:441 逐字 `Compressed ? false : StatusCode==PartialContent`）：
 * = !compressed && status===206。调度器 :725/:729 两处内联同式（:725 额外 && totalSize>0 由
 * 调用方组合，不在函数内）。 */
export function probeResumable(compressed: boolean, status: number): boolean {
  return !compressed && status === 206;
}

/** 探测 ResourceSize（PieceGrabber.cs:440 + 调度器 PieceGrabber.ets:709-713 推导链）：
 * compressed → -1（:181-188 连锁 ResourceSize=-1）；否则 CL>0 优先，CL 缺失/0 落 Content-Range
 * total。fallback 分支为 U2.1 既有加固（源码 :440 无 fallback，其 206 响应 CL 恒在；D24 同族）。
 * 用例按调度器行为锁定。 */
export function probeTotalSize(compressed: boolean, contentLength: number,
  contentRangeTotal: number): number {
  if (compressed) {
    return -1;
  }
  return contentLength > 0 ? contentLength : contentRangeTotal;
}

/** 闭窗三检（PieceGrabber.cs:181-202 检查序 + U1.2 D9 start 检；调度器 PieceGrabber.ets:673-691
 * 内联形的逐字抽离）：0=CWV_OK 通过，CWV_STATUS/CWV_TOTAL/CWV_START=违规。检查序：
 * ①effectiveProbeStatus 改写后 ≠206 → CWV_STATUS（:194-196，compressed 改写 :181-188 前置）；
 * ②fileSize>0 && contentRangeTotal!==fileSize → CWV_TOTAL（:197-201 外层门为 :512-516
 * FileSize>0 ? FileSize!=streamSize : false——响应体字节数门省略，D24）；③start!==windowStart →
 * CWV_START（源码无，ArkTS 增益检，序在 total 后与调度器一致）。 */
export function closedWindowValidationError(status: number, compressed: boolean,
  contentRangeTotal: number, fileSize: number, contentRangeStart: number,
  windowStart: number): number {
  if (effectiveProbeStatus(status, compressed) !== 206) {
    return CWV_STATUS;
  }
  if (fileSize > 0 && contentRangeTotal !== fileSize) {
    return CWV_TOTAL;
  }
  if (contentRangeStart !== windowStart) {
    return CWV_START;
  }
  return CWV_OK;
}
