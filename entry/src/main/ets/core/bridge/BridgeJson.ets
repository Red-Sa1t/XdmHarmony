/*
 * U6.1 桥请求体 JSON 解析门+消息映射纯模块（设计书 u6-1-bridge-eight-routes-DESIGN.md §3.2/§5.2）。
 * 零 @kit import——Hypium 本地单测（entry/src/test）可直接加载；探针可单向引用。
 * 对照源码（本会话只读核实，未改 resourses/ 下任何文件）：
 *   IpcHttpMessageProcessor.cs:90,100,110,120,158,160 —— DeserializeObject<ExtensionData>/
 *                <ExtensionData[]>/<List<string>> 三门的 throw=断连语义（坏 JSON/形状不符，
 *                HttpServer.cs:56-63 rethrow→tcp.Close 不回应答）。
 *   IpcHttpMessageProcessor.cs:125-134/:167-176 —— Message 七字段映射逐行（url/method/
 *                requestHeaders/responseHeaders/cookies/file=Sanitize/tabUrl/tabId）+
 *                RemoveBlockedHeaders 接线。
 *   Message.cs:85-137 —— GetHeaderValue 精确→小写两段查找（第二次 ToLower 幂等）取 [0]；
 *                GetContentLength 缺省/非数字/空串 → 0（try/catch 吞 Int32.Parse 异常）。
 *   ArgsProcessor.cs:155-194 —— ParseArgs 文法（xdm+app:// 跳过/单值开关集不吞值/
 *                裸值无当前名→--url 整体替换非追加）；:136-153 PopulateHeaders（ParseKeyValuePair）。
 *   ParsingHelper.cs:13-21 —— ParseKeyValuePair：Trim→首 ':' 且 index<1 拒绝→两段 Trim。
 *   ExtensionData.cs:9-22 —— 十四属性逐字段（可空统一 null）。
 * 有意差异（设计书 §4-9）：Newtonsoft 数字→字符串隐式强转不复刻（url:123 / args [1] → throw 断连）；
 *   **唯一例外（R2-F1）**：头值数组的 number 元素按 ReadAsString 语义 String(v) 强转收编——chrome
 *   app.js:225-229 responseHeaders["Content-Length"]=[fz]（fz=+size number）是主线流量契约，
 *   严格 throw 会误杀并致用户下载丢失（扩展已 cancel+erase 浏览器下载）；其余类型仍 throw。
 *   file/filename 双键并存取 file 优先（源 Newtonsoft 大小写不敏感绑定"后写覆盖"的简化，扩展从不双发）。
 *   显式 JSON null 值与缺省同貌置 null（Newtonsoft null 绑定同貌；request-watcher.js 的 file 可为 null）。
 * ArkTS 红线：无 any/解构/for...in/正则字面量；对象字面量均具 interface/Record 类型；
 *   Record 字面量键加引号；throw 只抛 Error 子类（arkts-limited-throw）。
 */

import {
  BridgeHeaders,
  removeBlockedHeaders
} from './BridgeProtocol';
import { sanitizeFileName } from '../util/FileNames';

/** ExtensionData.cs:9-22 十四属性投影（可空统一 null；多余字段忽略同 Newtonsoft）。
 * file 键承载 /media 的 file 与 /download 的 filename 双键（大小写不敏感绑定的等价投影，§2.2）。 */
export interface BridgeExtData {
  url: string | null;
  cookie: string | null;
  requestHeaders: BridgeHeaders | null;
  responseHeaders: BridgeHeaders | null;
  file: string | null;
  method: string | null;
  userAgent: string | null;
  tabUrl: string | null;
  tabId: string | null;
  tabTitle: string | null;
  referer: string | null;
  fileSize: number | null;
  mimeType: string | null;
  vid: string | null;
}

/** Message.cs:11-22 投影（method=null 覆盖构造器 "GET" 默认的源语义保留——本类型无默认值，
 * /args 路径由构造处置 'GET'）；mediaSourceUrl 仅 /args 路径写入（下游 U6.2 消费）。 */
export interface BridgeMessage {
  url: string | null;
  method: string | null;
  requestHeaders: BridgeHeaders | null;
  responseHeaders: BridgeHeaders | null;
  cookies: string | null;
  file: string | null;
  tabUrl: string | null;
  tabId: string | null;
  mediaSourceUrl: string | null;
}

/** ArgsProcessor.cs Dictionary<string,List<string>> 投影：键=开关名、值=参数表
 * （ArkTS 禁 index signature，Record 替代；动态键读写先例 ProbeDownload.ets:185）。 */
export type ArgsMap = Record<string, string[]>;

/** 单值开关集（ArgsProcessor.cs:15 逐串）：后不吞值（switchName 复位空） */
export const SINGLE_SWITCHES: string[] = ['--background', '--first-run', '--restore-window',
  '--quit', '--media', '--media-clear'];

/** Content-Length 全串十进制门（Int32.Parse 可用子集；负值放行由调用方 >0 判定） */
const INT32_DECIMAL: RegExp = new RegExp('^[+-]?[0-9]+$');

/** JSON 解析（Config.parseStringListOr 同款窄化）：坏 JSON → throw（→断连）；
 * 'null' 字面量 → null（调用方早退仍回 sync）。 */
function parseJsonOrThrow(text: string, gate: string): Object | null {
  try {
    const parsed: Object | null = JSON.parse(text);
    return parsed;
  } catch (e) {
    throw new Error(gate + ': invalid JSON body');
  }
}

/** 单对象门私有实现：产物必须为非数组 object（对齐 DeserializeObject<ExtensionData> 对
 * 数组/字符串/数字体的 JsonSerializationException）；逐字段"存在即验型"，缺省/显式 null → null。 */
function extDataOfObject(obj: Object): BridgeExtData {
  const rec: Record<string, Object> = obj as Record<string, Object>;
  // file/filename 双键：file 优先，缺省再验 filename（§2.2 双键兼容；类型不符仍 throw）
  let file: string | null = stringFieldOrNull(rec, 'file');
  if (file === null) {
    file = stringFieldOrNull(rec, 'filename');
  }
  const data: BridgeExtData = {
    url: stringFieldOrNull(rec, 'url'),
    cookie: stringFieldOrNull(rec, 'cookie'),
    requestHeaders: headersFieldOrNull(rec, 'requestHeaders'),
    responseHeaders: headersFieldOrNull(rec, 'responseHeaders'),
    file: file,
    method: stringFieldOrNull(rec, 'method'),
    userAgent: stringFieldOrNull(rec, 'userAgent'),
    tabUrl: stringFieldOrNull(rec, 'tabUrl'),
    tabId: stringFieldOrNull(rec, 'tabId'),
    tabTitle: stringFieldOrNull(rec, 'tabTitle'),
    referer: stringFieldOrNull(rec, 'referer'),
    fileSize: numberFieldOrNull(rec, 'fileSize'),
    mimeType: stringFieldOrNull(rec, 'mimeType'),
    vid: stringFieldOrNull(rec, 'vid')
  };
  return data;
}

/** string 字段门：缺省/显式 null → null；存在但非 string（数字不隐式强转，§4-9）→ throw。 */
function stringFieldOrNull(rec: Record<string, Object>, key: string): string | null {
  const v: Object | undefined = rec[key];
  if (v === undefined || v === null) {
    return null;
  }
  if (typeof v !== 'string') {
    throw new Error('extData field ' + key + ' must be string');
  }
  return v as string;
}

/** number 字段门（fileSize: long?）：缺省/null → null；非 number → throw。 */
function numberFieldOrNull(rec: Record<string, Object>, key: string): number | null {
  const v: Object | undefined = rec[key];
  if (v === undefined || v === null) {
    return null;
  }
  if (typeof v !== 'number') {
    throw new Error('extData field ' + key + ' must be number');
  }
  return v as number;
}

/** 头字典字段门：缺省/null → null（后续 removeBlockedHeaders/headerValueFirst 收 null 按
 * 源 NRE→断连处理，§2.4）；存在须为非数组 object 且逐值为 string[]，否则 throw。 */
function headersFieldOrNull(rec: Record<string, Object>, key: string): BridgeHeaders | null {
  const v: Object | undefined = rec[key];
  if (v === undefined || v === null) {
    return null;
  }
  return jsonHeadersOrNull(v);
}

/** /download、/media、/link 单对象解析门（IpcHttpMessageProcessor.cs:120 等）：坏 JSON/形状
 * 不符 → throw（→断连）；'null' → null（路由早退仍回 sync）；多余字段忽略。 */
export function parseExtData(text: string): BridgeExtData | null {
  const parsed: Object | null = parseJsonOrThrow(text, 'extData');
  if (parsed === null) {
    return null;
  }
  if (typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error('extData body must be object');
  }
  return extDataOfObject(parsed);
}

/** /link 数组解析门（IpcHttpMessageProcessor.cs:158）：产物须为数组且逐元素为 object
 * （逐元素复用单对象门）；'null' → null；对象体/元素非对象 → throw。 */
export function parseExtDataArray(text: string): BridgeExtData[] | null {
  const parsed: Object | null = parseJsonOrThrow(text, 'extDataArray');
  if (parsed === null) {
    return null;
  }
  if (!Array.isArray(parsed)) {
    throw new Error('extDataArray body must be array');
  }
  const arr: Object[] = parsed as Object[];
  const out: BridgeExtData[] = [];
  for (let i = 0; i < arr.length; i++) {
    const item: Object = arr[i];
    if (typeof item !== 'object' || item === null || Array.isArray(item)) {
      throw new Error('extDataArray element must be object');
    }
    out.push(extDataOfObject(item));
  }
  return out;
}

/** /args 解析门（IpcHttpMessageProcessor.cs:90）：产物须为数组且逐元素 string——数字元素
 * 不隐式转字符串（Newtonsoft ReadAsString 强转不复刻，§4-9）→ throw；'null' → null；[] → []。 */
export function parseArgsArray(text: string): string[] | null {
  const parsed: Object | null = parseJsonOrThrow(text, 'argsArray');
  if (parsed === null) {
    return null;
  }
  if (!Array.isArray(parsed)) {
    throw new Error('argsArray body must be array');
  }
  const arr: Object[] = parsed as Object[];
  const out: string[] = [];
  for (let i = 0; i < arr.length; i++) {
    if (typeof arr[i] !== 'string') {
      throw new Error('argsArray element must be string');
    }
    out.push(arr[i] as string);
  }
  return out;
}

/** JSON 头字典 → BridgeHeaders 平行数组：Object.keys 保存 JSON 文本序（=插入序）；逐值须为
 * string[]。**头值 number 元素例外**：按 Newtonsoft JsonReader.ReadAsString 语义 String(v)
 * 强转收编（R2-F1——chrome app.js:225-229 主线流量 responseHeaders["Content-Length"]=[fz]
 * fz=+size 为 number，firefox app.js:170 同；严格 throw 会误杀真实扩展 /download 并致用户
 * 下载丢失——扩展在 POST 前已 chrome.downloads.cancel+erase。§4-9 例外的唯一放宽点，其余
 * 类型（boolean/object/null 等）仍 throw）。v 为 null → null（字段缺省语义，调用方决定）。 */
export function jsonHeadersOrNull(v: Object | null): BridgeHeaders | null {
  if (v === null || v === undefined) {
    return null;
  }
  if (typeof v !== 'object' || Array.isArray(v)) {
    throw new Error('headers must be object');
  }
  const rec: Record<string, Object> = v as Record<string, Object>;
  const keys: string[] = Object.keys(rec);
  const names: string[] = [];
  const values: string[][] = [];
  for (let i = 0; i < keys.length; i++) {
    const val: Object = rec[keys[i]];
    if (!Array.isArray(val)) {
      throw new Error('header value must be array');
    }
    const arr: Object[] = val as Object[];
    const strs: string[] = [];
    for (let j = 0; j < arr.length; j++) {
      const item: Object = arr[j];
      if (typeof item === 'string') {
        strs.push(item);
      } else if (typeof item === 'number') {
        // ReadAsString 数字强转（R2-F1）：String(123)='123'/String(1.5)='1.5' 与 Newtonsoft 同貌
        strs.push(String(item));
      } else {
        throw new Error('header value element must be string or number');
      }
    }
    names.push(keys[i]);
    values.push(strs);
  }
  const h: BridgeHeaders = { names: names, values: values };
  return h;
}

/** 头取值（Message.cs:85-126 GetHeaderValue 语义）：精确键 → 小写键两段查找（源第二次
 * ToLowerInvariant 幂等，等价单段）；命中取值表 [0]；miss / 空值表 / h 为 null → null。 */
export function headerValueFirst(h: BridgeHeaders | null, key: string): string | null {
  if (h === null) {
    return null;
  }
  let idx: number = h.names.indexOf(key);
  if (idx < 0) {
    idx = h.names.indexOf(key.toLowerCase());
  }
  if (idx < 0) {
    return null;
  }
  const vals: string[] = h.values[idx];
  if (vals.length === 0) {
    return null;
  }
  return vals[0];
}

/** Content-Length 数值门（Message.cs:128-137 GetContentLength）：ResponseHeaders 首值全串
 * 十进制 → Number；缺省/非数字/空串 → 0（try/catch 吞 Int32.Parse 异常→0 的源语义）；
 * 负数串放行负值（>0 判定归调用方）。 */
export function getContentLengthOf(responseHeaders: BridgeHeaders | null): number {
  const raw: string | null = headerValueFirst(responseHeaders, 'Content-Length');
  if (raw === null) {
    return 0;
  }
  if (!INT32_DECIMAL.test(raw)) {
    return 0;
  }
  return Number(raw);
}

/** 七字段映射+消毒+剥离（IpcHttpMessageProcessor.cs:125-134 逐行）：file 非空先 sanitize
 * （FileHelper.cs:15-21；复用 FileNames D6 修正版，§4-7）；随后 requestHeaders 剥离——
 * **requestHeaders 为 null 时 throw**（源 Message 构造器空字典被 null 覆盖，RemoveBlockedHeaders
 * 取 Keys → NRE → 断连的等价物）。responseHeaders 不剥离（Content-Type/Content-Length 原样
 * 保留供嗅探/记录）。仅 /download、/media、/link 调用本函数。
 * U6.2 F2 族修复（设计书 §3.8；**R1-F2 复核修正——收窄回源语义**）：**空串 file 原样保留 ''**
 * （=源 SanitizeFileName('')='' 的直译——空 in 空 out），不做 null 化。/media normal 路径的
 * 回退由 processNormalVideo 既有 IsNullOrEmpty 二次回退分支承接（VideoUrlHelper.cs:627-630，
 * U6.1 实现的 'file' 兜底曾堵死该回退）；/link pending（AddBatchLinks :195）、/download 自动
 * 分支命名（AddDownload :215）、HandleDashAudio/CreateDual 文件名（VideoUrlHelper.cs:568/:608）
 * 三处源侧空串 file 均保持空串（''+ext=裸扩展名），消费方以 sanitizeOrEmpty 镜像（空 in 空 out）
 * ——null 化全局映射会使这三处误回退为 URL 推导名（R1-F2）。 */
export function buildBridgeMessage(data: BridgeExtData): BridgeMessage {
  const msg: BridgeMessage = {
    url: data.url,
    method: data.method,
    requestHeaders: data.requestHeaders,
    responseHeaders: data.responseHeaders,
    cookies: data.cookie,
    file: (data.file === null || data.file.length === 0) ? data.file : sanitizeFileName(data.file),
    tabUrl: data.tabUrl,
    tabId: data.tabId,
    mediaSourceUrl: null
  };
  const headers: BridgeHeaders | null = msg.requestHeaders;
  if (headers === null) {
    throw new Error('requestHeaders required');
  }
  msg.requestHeaders = removeBlockedHeaders(headers);
  return msg;
}

/** ArgsProcessor.cs:155-194 文法 1:1：跳过 'xdm+app://' 前缀项；'-' 开头为开关名——单值
 * 开关集（SINGLE_SWITCHES）复位 switchName 不吞值，否则为名值开关的当前名；裸值项：无当前名
 * → options['--url']=[arg] **整体替换非追加**（多裸值时后者覆盖且 count 恒 1），有当前名 →
 * 追加到当前名值表并复位。'-' 开头重复出现不重置已有值表（options[arg] 已存在则保留）。 */
export function parseArgs(args: string[]): ArgsMap {
  const options: ArgsMap = {};
  let switchName: string = '';
  for (let i = 0; i < args.length; i++) {
    const arg: string = args[i];
    if (arg.indexOf('xdm+app://') === 0) {
      continue;
    }
    if (arg.indexOf('-') === 0) {
      const existing: string[] | undefined = options[arg];
      if (existing === undefined) {
        options[arg] = [];
      }
      if (SINGLE_SWITCHES.indexOf(arg) >= 0) {
        switchName = '';
      } else {
        switchName = arg;
      }
    } else {
      if (switchName === '') {
        options['--url'] = [arg];
      } else {
        const bucket: string[] | undefined = options[switchName];
        if (bucket !== undefined) {
          bucket.push(arg);
        }
        switchName = '';
      }
    }
  }
  return options;
}

/** 'Name:Value' 头参数解析（ParsingHelper.cs:13-21 ParseKeyValuePair）：两端 Trim → 首个 ':'
 * 且下标≥1 → [name, value] 两段 Trim；无 ':' / 下标<1 → null。 */
export function parseHeaderArg(text: string): string[] | null {
  const line: string = text.trim();
  const index: number = line.indexOf(':');
  if (index < 1) {
    return null;
  }
  const name: string = line.slice(0, index).trim();
  const value: string = line.slice(index + 1).trim();
  const out: string[] = [name, value];
  return out;
}
