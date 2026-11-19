/*
 * U0.2 探针（P0-U2）纯函数与可序列化类型模块。
 * 零 @kit import：本地单测（entry/src/test，@ohos.hypium）可直接 import；
 * 业务/探针侧 import 无运行时副作用。
 * 可序列化类型均过 TaskPool 边界安全（S4 的 SegmentResult 以 JSON 字符串回传主线程后 as 还原）。
 * 常量三处同值锚（echo server / 本文件 / EXPECT 表）：
 *   BIG_BIN_BYTES=4194304 与 docs/probe/P0-U2-echo-server.js、EXPECT-u0-2-http-capability-probe.json 同值。
 */

/** S1/S4 观测总量锚：4MiB（64KB 分块 ≈64 块，足够呈现分块行为，低于 request() 接收上限 50MB） */
export const BIG_BIN_BYTES: number = 4194304;
/** S6 超时观测取值：3000ms 短超时避免单步阻塞 30s（PROBE_SPEC §2 示例同口径）。
 * 产品值 30000ms（原版 Config.cs:120 NetworkTimeout=30 → SingleSourceHTTPDownloader.cs:101）由 U1.2 固化；
 * 二者是同一参数位（connectTimeout/readTimeout，本机 d.ts 默认各 60000ms）的不同取值。 */
export const PROBE_TIMEOUT_MS: number = 3000;
/** S6 不可达地址：RFC 5737 TEST-NET-1 保留段，预期静默丢包 → 2300028；
 * RST/拒绝环境得 2300007（EXPECT 接受域记 UNVERIFIED，手册提供换地址重跑指引）。 */
export const UNREACHABLE_URL: string = 'http://192.0.2.1:8080/big.bin';
/** S5 Cookie 注入值（字符全在探针值白名单 [A-Za-z0-9_.:/|= -] 内，不触发消毒替换） */
export const ECHO_COOKIE: string = 'XDMProbeCookie=1';

/** S4 分窗：闭区间 [start, end]，对齐原版 PieceGrabber AddRange(start, end)（PieceGrabber.cs:391-394，bytes=start-end） */
export interface RangeWindow {
  start: number;
  end: number;
}

/** Content-Range 解析产物；解析失败字段取 -1（对齐 DotNetHttpSession.GetTotalLengthFromContentRange 的 -1 语义，DotNetHttpSession.cs:94-98） */
export interface ContentRangeParts {
  start: number;
  end: number;
  total: number;
}

/** echo 服务回显体解析产物（S3 acceptEncoding / S5 url+cookie 的观测源） */
export interface EchoFields {
  url: string;
  cookie: string;
  acceptEncoding: string;
}

/** S4 单分段结果：@Concurrent worker 内组装，JSON 字符串过 TaskPool 边界，主线程 JSON.parse as SegmentResult 还原 */
export interface SegmentResult {
  index: number;
  status: number;
  bytes: number;
  durationMs: number;
  errCode: number;
}

/** 大小写不敏感头查找：ArkTS 禁 for...in，用 Object.keys 遍历 + toLowerCase 比对；未命中返回 ''。
 * headers 由 resp.header as Record<string, string> 获得（http d.ts:267，header 类型为 Object 槽位）。 */
export function headerOf(headers: Record<string, string>, name: string): string {
  const keys: string[] = Object.keys(headers);
  for (let i = 0; i < keys.length; i++) {
    if (keys[i].toLowerCase() === name) {
      return headers[keys[i]];
    }
  }
  return '';
}

/** Content-Range 解析：
 * 'bytes 0-4194303/4194304' → {0,4194303,4194304}；未指定区间形态（bytes 星号 + '/123'）→ {-1,-1,123}；
 * 无 '/' 或非数字 → {-1,-1,-1}。区间段缺失但 total 可信的形态归 {-1,-1,total}。 */
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
    // '*/N' 或区间段缺失：total 可信，start/end 未知
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

/** 均分 Range 窗：win = floor(total/parts)（win<1 或参数非法返回 []）；
 * 第 i 窗 start=i*win，末窗 end=total-1 吸收余数。4194304/8 → 8 窗 ×524288。
 * 闭区间语义对齐原版 AddRange(start, end)。 */
export function splitRangeWindows(total: number, parts: number): RangeWindow[] {
  const windows: RangeWindow[] = [];
  if (total <= 0 || parts <= 0) {
    return windows;
  }
  const win: number = Math.floor(total / parts);
  if (win < 1) {
    return windows;
  }
  for (let i = 0; i < parts; i++) {
    const start: number = i * win;
    const end: number = (i === parts - 1) ? total - 1 : (i + 1) * win - 1;
    const window: RangeWindow = { start: start, end: end };
    windows.push(window);
  }
  return windows;
}

/** echo 回显体解析：按空格切 token；每 token 以首个 '=' 分 key/value（value 可含 '='，
 * 如 cookie=XDMProbeCookie=1 不截断）；未知/缺失 token 取 ''。 */
export function parseEchoBody(body: string): EchoFields {
  const fields: EchoFields = { url: '', cookie: '', acceptEncoding: '' };
  const trimmed: string = body.trim();
  if (trimmed.length === 0) {
    return fields;
  }
  const tokens: string[] = trimmed.split(' ');
  for (let i = 0; i < tokens.length; i++) {
    const token: string = tokens[i];
    const eq: number = token.indexOf('=');
    if (eq <= 0) {
      continue;
    }
    const key: string = token.slice(0, eq);
    const value: string = token.slice(eq + 1);
    if (key === 'url') {
      fields.url = value;
    } else if (key === 'cookie') {
      fields.cookie = value;
    } else if (key === 'acceptEncoding') {
      fields.acceptEncoding = value;
    }
  }
  return fields;
}

/** S6 timedOut 编码的唯一谓词：errCode==2300028（本机 d.ts:1111 Operation timeout）。
 * 2300007（connect 失败，RST/拒绝环境）不在此列——EXPECT 接受域记 UNVERIFIED。 */
export function isTimeoutCode(code: number): boolean {
  return code === 2300028;
}
