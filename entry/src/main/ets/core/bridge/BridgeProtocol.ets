/*
 * U0.3 扩展桥 8597 服务端（设计书 §5.1）：桥协议纯逻辑模块。
 * 零 @kit 依赖——本地单测（entry/src/test，@ohos.hypium）与探针单元可直接引用本模块，
 * 保证观测与实现同源（设计书 §0-5 单向依赖：探针可引业务，业务不得引探针）；业务侧引用
 * 无运行时副作用。
 * 对照源码（本会话只读核实，未改 resourses/ 下任何文件）：
 *   XDM.Core/HttpServer/LineReader.cs:11-37   —— 头块逐字节读：'\r' 任意位置跳过；'\n' 空行止头；
 *                                                EOF 异常（鸿蒙侧等价 = 解析失败断连不回包）。
 *   XDM.Core/HttpServer/HttpParser.cs:14-41   —— 状态行 Split(' ') 不去空项 token>2 取 arr[1]（method
 *                                                原版丢弃，本模块保留仅作探针观测，路由不用）；头行首个
 *                                                ':' 且 index>0，key/value 两端 Trim；异常 IOException。
 *   HttpParser.cs:43-57                       —— Content-Length 精确大小写键取 [0]，缺省 -1，Int64.Parse；
 *                                                Connection 缺省 "close"，equalsIgnoreCase 'keep-alive' 才复用。
 *   RequestContext.cs:33-62                   —— 应答拼装逐行对照（HTTP/1.0 恒定状态行/content-length
 *                                                忽略大小写跳过/恒 Connection: keep-alive/仅体非空才写
 *                                                Content-Length）。
 *   IpcHttpMessageProcessor.cs:278-374        —— /sync JSON 八字段写出序（Formatting.None 紧凑）。
 *   VideoTracker.cs:391-395                   —— videoList 元素 {id,text,info,tabId} 四 string。
 * U6.1 增量（设计书 u6-1-bridge-eight-routes-DESIGN.md §5.1，纯增量、既有导出零改动）：
 *   BridgeResponse                            —— 应答五元组自 BridgeServer 提公共（dispatchRequest
 *                                                产物类型跨模块消费）。
 *   IpcHttpMessageProcessor.cs:19-20          —— blockedHeaders 14 项黑名单逐串（'TE' 大小写保真）。
 *   IpcHttpMessageProcessor.cs:376-394        —— RemoveBlockedHeaders：逐黑名单名找首个忽略大小写
 *                                                精确等值键整条删除一次（等值非前缀）。
 *   Encoding.UTF8.GetString 容错               —— utf8Decode 宽松解码：一次失败恰产一个 U+FFFD
 *                                                （截断/续字节非法整体消费，.NET 同貌，见函数级三态文档）。
 *   IpcHttpMessageProcessor.cs:51-78          —— classifyRoute：八路径 switch 的 indexOf 投影，
 *                                                -1=未知（调用方 throw 断连，§0-1）。
 * ArkTS 红线：正则一律 new RegExp（禁字面量）；无 any/解构/for...in；对象字面量均具 interface 类型。
 */

/** 桥监听端口（connector.js:4 APP_BASE_URL=http://127.0.0.1:8597 连通性契约；IpcHttpMessageProcessor.cs:24） */
export const BRIDGE_PORT: number = 8597;
/** 桥绑定主机：仅回环（原版 IPAddress.Loopback，IpcHttpMessageProcessor.cs:24） */
export const BRIDGE_HOST: string = '127.0.0.1';
/** NetAddress.family：1=IPv4 */
export const BRIDGE_FAMILY: number = 1;
/** 八条路由字面量（IpcHttpMessageProcessor.cs:53-75 switch 序）；path 精确匹配，不剥 query 不校验 method */
export const ROUTE_PATHS: string[] = ['/sync', '/download', '/media', '/tab-update',
  '/vid', '/clear', '/link', '/args'];
/** /sync 应答头（OnSyncMessage，IpcHttpMessageProcessor.cs:272-273） */
export const SYNC_CONTENT_TYPE: string = 'application/json';
export const SYNC_CACHE_CONTROL: string = 'max-age=0, no-cache, must-revalidate';
/** /sync 常量字段表（CreateConfigJson :318/:326/:358 逐串） */
export const SYNC_MEDIA_TYPES: string[] = ['audio/', 'video/'];
export const SYNC_TABS_WATCHER: string[] = ['.youtube.', '/watch?v='];
export const SYNC_MATCHING_HOSTS: string[] = ['googlevideo'];

/** 请求头平行数组容器：对齐 Dictionary<string,List<string>>（HttpParser.cs:76-78）——
 * names[i] 与 values[i] 平行；插入序保留；同名多值累积；键大小写敏感；取值一律 [0] 首值。 */
export interface BridgeHeaders {
  names: string[];
  values: string[][];
}

/** parseHead 增量产物（LineReader.cs + HttpParser.cs 的无状态纯函数投影）：
 * complete=空行已达；failed=解析失败（→断连不回包，设计书 §0-1①）；method 仅探针观测不参与路由；
 * complete=false 时 method/path/headers 为空值由调用方丢弃重扫。 */
export interface HeadParseResult {
  complete: boolean;
  failed: boolean;
  method: string;
  path: string;
  headers: BridgeHeaders;
  bodyStart: number;
}

/** /sync videoList 元素（VideoTracker.cs:391-395 MediaInfo 四属性均 string；U0.3 恒空表，字段位保留） */
export interface BridgeVideoItem {
  id: string;
  text: string;
  info: string;
  tabId: string;
}

/** /sync 应答体八字段（IpcHttpMessageProcessor.cs:289-362 JsonTextWriter 写出序）——
 * interface 字段序即 JSON.stringify 序列化序（字段序契约）。 */
export interface SyncFields {
  enabled: boolean;
  fileExts: string[];
  blockedHosts: string[];
  requestFileExts: string[];
  mediaTypes: string[];
  tabsWatcher: string[];
  videoList: BridgeVideoItem[];
  matchingHosts: string[];
}

/** Content-Length 严格十进制（对齐 Int64.Parse 可用子集：'+5' 成功/'0x10' 失败；禁正则字面量） */
const INT64_DECIMAL: RegExp = new RegExp('^[+-]?[0-9]+$');

/** 新缓冲拼接（a 前 b 后），不改入参。 */
export function appendBytes(a: Uint8Array, b: Uint8Array): Uint8Array {
  const out: Uint8Array = new Uint8Array(a.length + b.length);
  out.set(a, 0);
  out.set(b, a.length);
  return out;
}

/** 头块字节级增量状态机（LineReader.cs:11-37 逐语义，设计书 §3.1）：
 * on('message') 的 ArrayBuffer 是任意分包——调用方每连接累积 Uint8Array 后从 0 重扫（头块量级数百
 * 字节，重扫成本可忽略，换取无状态纯函数）。逐字节：0x0D 一律丢弃（任意位置）；0x0A 且行空 → 头块
 * 结束（complete=true，bodyStart=当前偏移+1）；0x0A 且行非空 → 交出一行（Latin-1 逐字节转字符，对齐
 * StringBuilder.Append((char)x)）；扫到缓冲尾未遇空行 → complete=false 等下一包。行语义（HttpParser.cs）：
 * 首行 Split(' ') 保留空项且 token>2 才合法（method=token[0]、path=token[1]）；头行取首个 ':' 且
 * index>0，两端 Trim；无冒号/首位冒号 → failed=true（调用方断连不回包）。 */
export function parseHead(buf: Uint8Array, start: number): HeadParseResult {
  const headers: BridgeHeaders = { names: [], values: [] };
  const result: HeadParseResult = {
    complete: false, failed: false, method: '', path: '',
    headers: headers, bodyStart: buf.length
  };
  let line: string = '';
  let sawStatusLine: boolean = false;
  let i: number = start;
  while (i < buf.length) {
    const byte: number = buf[i];
    if (byte === 0x0D) {
      i++;
      continue;
    }
    if (byte === 0x0A) {
      if (line.length === 0) {
        result.complete = true;
        result.bodyStart = i + 1;
        return result;
      }
      if (!sawStatusLine) {
        const tokens: string[] = line.split(' ');
        if (tokens.length > 2) {
          result.method = tokens[0];
          result.path = tokens[1];
        } else {
          result.failed = true;
          return result;
        }
        sawStatusLine = true;
      } else {
        const colon: number = line.indexOf(':');
        if (colon > 0) {
          const key: string = line.slice(0, colon).trim();
          const value: string = line.slice(colon + 1).trim();
          const existing: number = result.headers.names.indexOf(key);
          if (existing >= 0) {
            result.headers.values[existing].push(value);
          } else {
            const single: string[] = [value];
            result.headers.names.push(key);
            result.headers.values.push(single);
          }
        } else {
          result.failed = true;
          return result;
        }
      }
      line = '';
      i++;
      continue;
    }
    line += String.fromCharCode(byte);
    i++;
  }
  return result;
}

/** 精确大小写键取 [0] 首值（HttpParser.cs:45 GetValueOrDefault(key)?[0] 同构）；缺省返回 ''。 */
export function firstHeader(h: BridgeHeaders, name: string): string {
  const idx: number = h.names.indexOf(name);
  if (idx >= 0) {
    const vals: string[] = h.values[idx];
    if (vals.length > 0) {
      return vals[0];
    }
  }
  return '';
}

/** Content-Length（HttpParser.cs:43-47 逐语义）：键精确大小写 'Content-Length' 取 [0]；
 * 缺省 → -1（不读体）；十进制整数（Int64.Parse 可用子集）→ 数值（>0 才读体，0/负值不读）；
 * 空串/小数/非数字 → -2（= 解析失败 → 断连不回包）。不支持 chunked（原版同）。 */
export function getContentLength(h: BridgeHeaders): number {
  const idx: number = h.names.indexOf('Content-Length');
  if (idx < 0) {
    return -1;
  }
  const vals: string[] = h.values[idx];
  const raw: string = vals.length > 0 ? vals[0] : '';
  if (!INT64_DECIMAL.test(raw)) {
    return -2;
  }
  return Number(raw);
}

/** keep-alive 判定（HttpParser.cs:49-57 逐语义）：键精确大小写 'Connection' 取 [0]，缺省按 'close'；
 * 值 equalsIgnoreCase 'keep-alive' 才复用连接——curl 默认不发该头 → 一请求一连接（非对称保留）。 */
export function isKeepAlive(h: BridgeHeaders): boolean {
  const idx: number = h.names.indexOf('Connection');
  let value: string = 'close';
  if (idx >= 0) {
    const vals: string[] = h.values[idx];
    if (vals.length > 0) {
      value = vals[0];
    }
  }
  return value.toLowerCase() === 'keep-alive';
}

/** 应答拼装（RequestContext.SendResponse 逐行对照，设计书 §3.4）：
 * ①状态行恒 'HTTP/1.0 {code} {msg}\r\n'（:37 硬编码，与请求版本无关）；
 * ②调用方头按插入序逐条输出，名为 content-length 的头忽略大小写跳过（:40-43，长度由框架重算）；
 * ③恒追加 'Connection: keep-alive\r\n'（:49，即便随后关闭——非对称签名）；
 * ④仅 body 非空且 length>0 才追加 'Content-Length: {N}\r\n'（:50-53）——404 空体不带
 *   Content-Length，HTTP/1.0 靠断连定界；
 * ⑤'\r\n' + 头块 + 体，头块 ASCII 编码 + 体字节拼单块，调用方一次 conn.send。
 * headerNames/headerValues 平行一值一头；同名多行由调用方放多个同名条目表达。 */
export function buildResponseBytes(statusCode: number, statusMessage: string,
  headerNames: string[], headerValues: string[], body: Uint8Array): Uint8Array {
  let head: string = 'HTTP/1.0 ' + String(statusCode) + ' ' + statusMessage + '\r\n';
  for (let i = 0; i < headerNames.length; i++) {
    if (headerNames[i].toLowerCase() === 'content-length') {
      continue;
    }
    head += headerNames[i] + ': ' + headerValues[i] + '\r\n';
  }
  head += 'Connection: keep-alive\r\n';
  if (body.length > 0) {
    head += 'Content-Length: ' + String(body.length) + '\r\n';
  }
  head += '\r\n';
  const headBytes: Uint8Array = asciiBytes(head);
  const out: Uint8Array = new Uint8Array(headBytes.length + body.length);
  out.set(headBytes, 0);
  out.set(body, headBytes.length);
  return out;
}

/** /sync JSON 组装（CreateConfigJson 等价投影）：SyncFields 具型字面量的 interface 字段序 =
 * §2.2 八段写出序，JSON.stringify 对 string 键保持插入序，等价 JsonTextWriter Formatting.None
 * 紧凑写出；禁手拼字符串（转义风险）。 */
export function buildSyncJson(f: SyncFields): string {
  return JSON.stringify(f);
}

/** UTF-8 编码纯函数（设计书 §3.5）：charCodeAt 循环——<0x80→1B、<0x800→2B、代理对→4B、其余 3B。
 * U0.3 内容全 ASCII；U6.1 videoList 文本可能含 CJK/emoji，编码正确性现在立契约（Hypium 用例）。 */
export function utf8Encode(s: string): Uint8Array {
  const out: number[] = [];
  let i: number = 0;
  while (i < s.length) {
    const c: number = s.charCodeAt(i);
    if (c < 0x80) {
      out.push(c);
      i++;
    } else if (c < 0x800) {
      pushTwoByte(out, c);
      i++;
    } else if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.length) {
      const d: number = s.charCodeAt(i + 1);
      if (d >= 0xDC00 && d <= 0xDFFF) {
        pushSurrogatePair(out, c, d);
        i += 2;
      } else {
        pushThreeByte(out, c);
        i++;
      }
    } else {
      pushThreeByte(out, c);
      i++;
    }
  }
  return new Uint8Array(out);
}

/** 头块 ASCII 编码（charCodeAt 循环；头块仅含 ASCII，入参由 buildResponseBytes 构造保证）。 */
function asciiBytes(s: string): Uint8Array {
  const out: Uint8Array = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) {
    out[i] = s.charCodeAt(i) & 0xFF;
  }
  return out;
}

function pushTwoByte(out: number[], c: number): void {
  out.push(0xC0 | (c >> 6));
  out.push(0x80 | (c & 0x3F));
}

function pushThreeByte(out: number[], c: number): void {
  out.push(0xE0 | (c >> 12));
  out.push(0x80 | ((c >> 6) & 0x3F));
  out.push(0x80 | (c & 0x3F));
}

function pushSurrogatePair(out: number[], hi: number, lo: number): void {
  const cp: number = 0x10000 + ((hi - 0xD800) * 0x400) + (lo - 0xDC00);
  out.push(0xF0 | (cp >> 18));
  out.push(0x80 | ((cp >> 12) & 0x3F));
  out.push(0x80 | ((cp >> 6) & 0x3F));
  out.push(0x80 | (cp & 0x3F));
}

// ────────────── U6.1 增量（设计书 §3.1/§3.3；零 @kit 纪律不变） ──────────────

/** dispatch 产物五元组（自 BridgeServer 提公共，U6.1 设计书 §2.4）：buildResponseBytes 的
 * 入参四元组 + 状态码/状态消息；headerNames/headerValues 平行一值一头。 */
export interface BridgeResponse {
  status: number;
  msg: string;
  headerNames: string[];
  headerValues: string[];
  body: Uint8Array;
}

/** 请求头剥离黑名单 14 项（IpcHttpMessageProcessor.cs:19-20 逐串，'TE' 大小写保真——比较时
 * 统一 toLowerCase 双边，等值语义不受原文大小写影响）。仅作用于 RequestHeaders（§3.3）。 */
export const BLOCKED_HEADERS: string[] = ['accept', 'if', 'authorization', 'proxy', 'connection',
  'expect', 'TE', 'upgrade', 'range', 'cookie', 'transfer-encoding', 'content-type',
  'content-length', 'content-encoding'];

/** 头剥离纯函数（RemoveBlockedHeaders，IpcHttpMessageProcessor.cs:376-394 逐语义）：
 * 对每个黑名单名，在 h.names 中找**首个** toLowerCase 后精确等值的键（InvariantCultureIgnoreCase
 * 等值——"If-None-Match" 不被 "if" 命中，等值非前缀），删除该键整条（names/values 同步 splice）；
 * 每个黑名单名最多删一个键（同名双键只删首个）。返回新容器，入参不变（纯函数）；
 * 值表内层数组浅拷贝防共享可变状态。 */
export function removeBlockedHeaders(h: BridgeHeaders): BridgeHeaders {
  const names: string[] = h.names.slice();
  const values: string[][] = [];
  for (let i = 0; i < h.values.length; i++) {
    values.push(h.values[i].slice());
  }
  for (let b = 0; b < BLOCKED_HEADERS.length; b++) {
    const target: string = BLOCKED_HEADERS[b].toLowerCase();
    let found: number = -1;
    for (let k = 0; k < names.length; k++) {
      if (names[k].toLowerCase() === target) {
        found = k;
        break;
      }
    }
    if (found >= 0) {
      names.splice(found, 1);
      values.splice(found, 1);
    }
  }
  const out: BridgeHeaders = { names: names, values: values };
  return out;
}

/** UTF-8 宽松解码（对齐 Encoding.UTF8.GetString 的 replacement fallback + TextDecoder 默认替换级）：
 * 逐字节状态机——1/2/3/4 字节合法序列产出码点（>0xFFFF 码点经代理对进 string）；非法序列
 * 处理（R3-F1 修正为 .NET 同貌：一次失败恰产一个 U+FFFD）——①起始字节即非法（孤立延续字节
 * 0x80-0xBF / overlong 双字节首 0xC0-0xC1 / 超界 0xF5-0xFF）：单字节消费；②截断的多字节
 * （输入耗尽）或续字节非法：起始字节+已确认合法续字节整体消费（重同步点=首个未消费字节）；
 * ③完整但码点非法（overlong/代理区/超 0x10FFFF）：整序列消费。与 utf8Encode 互为逆（合法输入
 * round-trip，Hypium 用例钉死）。不 import util.TextDecoder——保持本模块零 @kit，Hypium 本地
 * 可加载。 */
export function utf8Decode(bytes: Uint8Array): string {
  let out: string = '';
  let i: number = 0;
  while (i < bytes.length) {
    const b0: number = bytes[i];
    if (b0 < 0x80) {
      out += String.fromCharCode(b0);
      i++;
      continue;
    }
    let len: number = 0;
    let cp: number = 0;
    if (b0 >= 0xC2 && b0 <= 0xDF) {
      len = 2;
      cp = b0 & 0x1F;
    } else if (b0 >= 0xE0 && b0 <= 0xEF) {
      len = 3;
      cp = b0 & 0x0F;
    } else if (b0 >= 0xF0 && b0 <= 0xF4) {
      len = 4;
      cp = b0 & 0x07;
    } else {
      // ①孤立延续字节/overlong 双字节首/超界：起始即非法，单字节消费
      out += String.fromCharCode(0xFFFD);
      i++;
      continue;
    }
    // 逐续字节扫描：contOk=已确认合法续字节数；输入耗尽置 truncated、遇非法续字节 break
    // （重同步点=该非法字节处）
    let contOk: number = 0;
    let truncated: boolean = false;
    for (let j = 1; j < len; j++) {
      if (i + j >= bytes.length) {
        truncated = true;
        break;
      }
      const bj: number = bytes[i + j];
      if (bj < 0x80 || bj > 0xBF) {
        break;
      }
      cp = (cp << 6) | (bj & 0x3F);
      contOk = j;
    }
    if (truncated || contOk < len - 1) {
      // ②截断/续字节非法：起始字节+已确认续字节整体消费，恰产一个 U+FFFD（R3-F1——
      // 原实现失败路径仅前进 1 字节，截断序列会再产孤立续字节 FFFD，与 .NET/单测矛盾）
      out += String.fromCharCode(0xFFFD);
      i += 1 + contOk;
      continue;
    }
    // ③完整序列码点复查：overlong（3 字节 <0x800 / 4 字节 <0x10000）/代理区/超 0x10FFFF
    // ——整序列消费产一个 U+FFFD
    if ((len === 3 && cp < 0x800) || (len === 4 && cp < 0x10000) || cp > 0x10FFFF ||
      (cp >= 0xD800 && cp <= 0xDFFF)) {
      out += String.fromCharCode(0xFFFD);
      i += len;
      continue;
    }
    if (cp < 0x10000) {
      out += String.fromCharCode(cp);
    } else {
      const v: number = cp - 0x10000;
      out += String.fromCharCode(0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF));
    }
    i += len;
  }
  return out;
}

/** 路由分类号（IpcHttpMessageProcessor.cs:51-78 switch 的 indexOf 投影）：八路径按 ROUTE_PATHS
 * 序返回 0~7；-1=未知路径（调用方 throw → 泵 closeSilently 断连，设计书 §0-1：U0.3 的 404
 * 中间态 D1/D2 由本单元废止，1:1 源 default→ArgumentException→HttpServer 断连不回应答）。 */
export function classifyRoute(path: string): number {
  return ROUTE_PATHS.indexOf(path);
}
