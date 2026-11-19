/*
 * U7.1 MpdParser.cs（431 行）纯语义翻译（设计书 u7-1-dash-DESIGN.md §4.2-§4.8 逐公式）。
 * 结构/语义分离：本文件只消费 DashXmlEvent[]（结构事实由 DashXmlFeed 的 @kit xml 适配层生产，
 * 四 MPD 向量公式验证走事件注入——Hypium 零 @kit 可跑），失败 throw=整清单丢弃（源异常上抛同效）。
 * 对照源码（本会话只读核实，未改 resourses/ 下任何文件）：
 *   MpdParser.cs:17-19   trickModeUri/TemplatePattern（正则逐字符保持）
 *   :32-66               Parse 根：根门三连（MPD/dynamic 大小写敏感/任意层 ContentProtection）+
 *                        mediaPresentationDuration ?? "0" + 根级 child::BaseURL 首个 + 周期数门
 *   :69-128              ParsePeriod：duration 属性覆盖/BaseURL 覆盖（局部变量互不污染）/
 *                        hasParentSegmentBase 布尔标志（只查 Period 级）/组分类按首个 repr mime 前缀/
 *                        video×audio 笛卡尔序（video 外层 × audio 内层）
 *   :130-149             ParseAdaptationSet：AS 级 BaseURL/trickmode 整组返回空/逐 repr
 *   :151-306             ParseRepresentation 三寻址（判定顺序固定不重排）：
 *                        ①SegmentBase（repr 级或 Period 级布尔标志）→ [baseUrl] 单段整文件
 *                        ②SegmentList（仅 repr 级）→ init=Initialization ?? RepresentationIndex
 *                          优先，随后逐 SegmentURL@media；mediaRange/indexRange 不消费
 *                        ③SegmentTemplate（repr ?? 父 AS，Period 级不查）→ simple/timeline
 *   :212-245             simple：segmentCount=(int)Ceiling((pd/1000)/(duration/timescale))；
 *                        ★$Time$ 起点=startNumber；init 段 time=startNumber；time 步进用原始
 *                        duration（tick 值）；repr@id 缺失 → throw（C# NRE→清单丢弃）
 *   :247-301             timeline：number=startNumber??1、time=0（init 段 $Time$=0）；逐 <S>：
 *                        d 必填（缺失 NRE→throw）、t=Int64(@t ?? -1)、r=Int64(@r ?? -1)；
 *                        ★t>0 严格不等号（t="0" 不重置）；r>0 重复 r 次（r=-1/0 均只发 1 段——
 *                        源未实现规范语义 1:1）
 *   :222-223/:231/:238   模板流程顺序不可变：$$→\u0000 → 对转义串预扫描一次 Match 列表 →
 *                        逐 Match 顺序 replace（String.Replace 全量替换语义 → split/join）→ \u0000 恢复
 *   :308-348             ParseTemplate：$Number$/$Time$ 十进制；%0Nd/%0Nx 补零（FormatDigit）；
 *                        $RepresentationID$ 原串；$Bandwidth$ 原始属性串（:156 旁路）
 *   :350-359             FormatDigit：dx 缺省 "D"——.NET ContainsKey 对已定义命名组恒真 →
 *                        无 dx 形态 dx=""。★目标偏差（§5-1）：$Number%04$ 按 d 十进制补零处理，
 *                        不复刻 ToString("4") 输出字面量的源缺陷（openQuestion 1）；dx="D" 死路径
 *                        不复刻（§5-3）。负数统一 sign+幅值补零/补 hex（§5-2，不迁移二补全宽）
 *   :361-397             CalculatePeriodDurationsIfMissing：逆文档序、duration→last=total-dur、
 *                        否则 start→push(last-start)、Reverse；双缺 throw；:387-390 PT0S 分支
 *                        死代码不复刻（§5-3 锚登记）
 *   :399-420             ContainsTrickMode：AS 的第一个 EssentialProperty ?? 第一个
 *                        SupplementalProperty 的 schemeIdUri 精确等于 trickmode → 整组空
 * 预算（§3.3/§5-4）：节点/深度/属性/文本/周期/组合/每轨段数/累计 URL 字符全套有界，
 *   超限 throw=整清单丢弃（DASH_MAX_PAIRS 例外：超出部分条目丢弃）；strict Int32/Int64 十进制
 *   解析（安全整数上界——.NET Int64 全域不复刻，§5-4）。
 * resolve 注入：DashUrlResolver=HlsUrlResolver（HlsParser.ets 同款注入惯例）；resolveReference
 *   与 HlsParser.resolveReference 同门槛（空串/超长/'{$'/控制字符→throw——resolveHlsUrl 对
 *   空/带尾随空格引用有意收紧的差异已登记 §5-13）。
 * ArkTS 红线：无 any/解构/for...in/正则字面量（TEMPLATE/INT 门用 new RegExp）；对象字面量
 *   均具 class 类型；throw 只抛 Error；显式返回类型。
 */

import { DASH_MAX_ADAPTATION_SETS, DASH_MAX_ATTRS_PER_NODE, DASH_MAX_DEPTH, DASH_MAX_NODES,
  DASH_MAX_OUTPUT_URL_CHARS, DASH_MAX_PAIRS, DASH_MAX_PERIODS, DASH_MAX_REPRESENTATIONS,
  DASH_MAX_SEGMENTS, DASH_MAX_TEXT_CHARS, DASH_TRICK_MODE_URI, DashPair, DashPeriodAttrs,
  DashRepresentation } from './DashModel';
import { parseXsDuration } from './DashUtil';
import { HLS_MAX_URL_CHARS, HlsUrlResolver } from './HlsModel';

/** DashUrlResolver=HlsUrlResolver（HlsParser 同款注入惯例；测试注入恒等 resolver）。 */
export type DashUrlResolver = HlsUrlResolver;

export const DASH_EVENT_START: string = 'start';
export const DASH_EVENT_END: string = 'end';
export const DASH_EVENT_TEXT: string = 'text';

/** XML 结构事实（DashXmlFeed 生产；kind∈start/end/text；start 事件携带 attrs）。 */
export class DashXmlEvent {
  kind: string = DASH_EVENT_TEXT;
  name: string = '';
  attrs: Record<string, string> = {};
  text: string = '';
}

/** 有界 XML 树节点（parent 链支撑 ParseRepresentation 的父属性继承，MpdParser.cs:153-158）。 */
export class DashXmlNode {
  name: string = '';
  attrs: Record<string, string> = {};
  children: DashXmlNode[] = [];
  text: string = '';
  parent: DashXmlNode | null = null;
}

/** 累计展开 URL 字符预算（=HLS_MAX_OUTPUT_CHARS 概念；周期内累计，§3.3）。 */
class DashUrlBudget {
  private used: number = 0;

  add(characters: number): void {
    if (characters > DASH_MAX_OUTPUT_URL_CHARS - this.used) {
      throw new Error('DASH URL character budget exceeded');
    }
    this.used += characters;
  }
}

/** 树内累计文本预算（feed 单事件 ≤DASH_MAX_TEXT_CHARS；此处防海量文本事件累计放大）。 */
const TREE_TEXT_BUDGET: number = 8388608;

/**
 * 有界树构建：首个 start=根；末根 end 必须出现；START 顶层兄弟/错配 end/未闭合根/超界
 * （节点数/深度/每节点属性/单段与累计文本）一律 throw=整清单丢弃。
 */
export function buildMpdTree(events: DashXmlEvent[]): DashXmlNode {
  let root: DashXmlNode | null = null;
  let current: DashXmlNode | null = null;
  let depth: number = 0;
  let nodeCount: number = 0;
  let textBudget: number = 0;
  for (let i = 0; i < events.length; i++) {
    const event: DashXmlEvent = events[i];
    if (event.kind === DASH_EVENT_START) {
      if (event.name.length === 0) { throw new Error('Invalid DASH start event'); }
      if (Object.keys(event.attrs).length > DASH_MAX_ATTRS_PER_NODE) {
        throw new Error('DASH node attribute limit');
      }
      if (++nodeCount > DASH_MAX_NODES) { throw new Error('DASH node limit'); }
      const node: DashXmlNode = new DashXmlNode();
      node.name = event.name;
      node.attrs = event.attrs;
      node.parent = current;
      if (current === null) {
        if (root !== null) { throw new Error('Multiple DASH document roots'); }
        root = node;
      } else {
        current.children.push(node);
      }
      current = node;
      depth++;
      if (depth > DASH_MAX_DEPTH) { throw new Error('DASH tree depth limit'); }
    } else if (event.kind === DASH_EVENT_END) {
      if (current === null || current.name !== event.name) {
        throw new Error('Mismatched DASH end tag');
      }
      current = current.parent;
      depth--;
    } else {
      if (event.text.length > DASH_MAX_TEXT_CHARS) { throw new Error('DASH text limit'); }
      textBudget += event.text.length;
      if (textBudget > TREE_TEXT_BUDGET) { throw new Error('DASH text budget exceeded'); }
      if (current !== null) { current.text += event.text; }
    }
  }
  if (root === null) { throw new Error('Missing DASH document root'); }
  if (current !== null) { throw new Error('Unclosed DASH document root'); }
  return root;
}

function childrenOf(node: DashXmlNode, name: string): DashXmlNode[] {
  const out: DashXmlNode[] = [];
  for (let i = 0; i < node.children.length; i++) {
    if (node.children[i].name === name) { out.push(node.children[i]); }
  }
  return out;
}

function firstChild(node: DashXmlNode, name: string): DashXmlNode | null {
  for (let i = 0; i < node.children.length; i++) {
    if (node.children[i].name === name) { return node.children[i]; }
  }
  return null;
}

/** SelectSingleNode("descendant::ContentProtection") 任意层后代语义（:36）。树已预算内。 */
function hasDescendant(node: DashXmlNode, name: string): boolean {
  for (let i = 0; i < node.children.length; i++) {
    const child: DashXmlNode = node.children[i];
    if (child.name === name || hasDescendant(child, name)) { return true; }
  }
  return false;
}

/** InnerText（C# 全部后代文本按文档序串接）。文本总量已被树预算约束。 */
function innerText(node: DashXmlNode): string {
  let out: string = node.text;
  for (let i = 0; i < node.children.length; i++) {
    out += innerText(node.children[i]);
  }
  return out;
}

// ────────────── 模板变量（MpdParser.cs:18-19/:222-223/:308-359，§4.8） ──────────────

/** TemplatePattern 逐字符直译；命名组同时占据位置组 2-5（1=变量全串 2=time_digits 3=time_dx
 * 4=num_digits 5=num_dx）——ArkTS 侧按位置读取（规避 groups 索引签名访问），模式文本不变。 */
const TEMPLATE_SOURCE: string =
  '\\$(RepresentationID|Time|Time%0(?<time_digits>[0-9]+)(?<time_dx>[dx])?|Number' +
  '|Number%0(?<num_digits>[0-9]+)(?<num_dx>[dx])?|Bandwidth)\\$';

class DashTemplateMatch {
  variable: string = '';
  digits: string = '';
  dx: string = '';
  isNumber: boolean = false;
}

/** 对转义串预扫描一次（:224/:259 GetAsEnumerable 非重叠左到右序）。 */
function scanTemplateMatches(escapedUrl: string): DashTemplateMatch[] {
  const scanner: RegExp = new RegExp(TEMPLATE_SOURCE, 'g');
  const matches: DashTemplateMatch[] = [];
  let found: RegExpExecArray | null = scanner.exec(escapedUrl);
  while (found !== null) {
    const item: DashTemplateMatch = new DashTemplateMatch();
    item.variable = found[1];
    if (item.variable.startsWith('Time%0')) {
      item.digits = typeof found[2] === 'string' ? found[2] : '';
      item.dx = typeof found[3] === 'string' ? found[3] : '';
      item.isNumber = false;
    } else if (item.variable.startsWith('Number%0')) {
      item.digits = typeof found[4] === 'string' ? found[4] : '';
      item.dx = typeof found[5] === 'string' ? found[5] : '';
      item.isNumber = true;
    }
    matches.push(item);
    found = scanner.exec(escapedUrl);
  }
  return matches;
}

/** FormatDigit（:350-359）：d/x 补零；dx=''（无 dx 形态）按 d 处理（§5-1 偏差——不复刻
 * .NET ToString("4") 字面量输出缺陷）；负数 sign+幅值（§5-2）；宽度门 32（预算纪律）。 */
function formatDigitOf(value: number, digits: string, dx: string): string {
  const width: number = Number(digits);
  if (!Number.isSafeInteger(width) || width < 1 || width > 32) {
    throw new Error('Invalid DASH template width');
  }
  const kind: string = dx === '' ? 'd' : dx; // §5-1：无 dx 形态按十进制补零
  const magnitude: number = value < 0 ? -value : value;
  const sign: string = value < 0 ? '-' : '';
  if (kind === 'x') {
    return sign + magnitude.toString(16).padStart(width, '0');
  }
  return sign + String(magnitude).padStart(width, '0');
}

/** 逐 Match 顺序替换（String.Replace 全量语义 → split/join）；变量值替换进转义串。 */
function expandTemplate(matches: DashTemplateMatch[], escapedUrl: string, number: number,
  time: number, bandwidth: string, representationId: string): string {
  let url: string = escapedUrl;
  for (let i = 0; i < matches.length; i++) {
    const item: DashTemplateMatch = matches[i];
    if (item.variable.startsWith('Number')) {
      if (item.variable === 'Number') {
        url = url.split('$Number$').join(String(number));
      } else {
        url = url.split('$' + item.variable + '$').join(formatDigitOf(number, item.digits, item.dx));
      }
    } else if (item.variable.startsWith('Time')) {
      if (item.variable === 'Time') {
        url = url.split('$Time$').join(String(time));
      } else {
        url = url.split('$' + item.variable + '$').join(formatDigitOf(time, item.digits, item.dx));
      }
    } else if (item.variable === 'RepresentationID') {
      url = url.split('$RepresentationID$').join(representationId);
    } else if (item.variable === 'Bandwidth') {
      // $Bandwidth$ 用原始属性串而非数值（:156 旁路，§3.1）
      url = url.split('$Bandwidth$').join(bandwidth);
    }
  }
  return url;
}

/** parseDashTemplate（设计书 §2-3 导出面）：raw url → $$→\u0000 → 预扫描 → 逐替换 → \u0000 恢复。 */
export function parseDashTemplate(url: string, number: number, time: number, bandwidth: string,
  representationId: string): string {
  const escaped: string = url.split('$$').join('\u0000');
  const matches: DashTemplateMatch[] = scanTemplateMatches(escaped);
  const expanded: string = expandTemplate(matches, escaped, number, time, bandwidth, representationId);
  return expanded.split('\u0000').join('$');
}

function escapeTemplate(raw: string): string {
  return raw.split('$$').join('\u0000');
}

function restoreTemplate(escaped: string): string {
  return escaped.split('\u0000').join('$');
}

// ────────────── 严格整数属性（§5-4：安全整数上界——.NET Int64 全域不复刻） ──────────────

const INT_DECIMAL: RegExp = new RegExp('^[+-]?[0-9]+$');

function int64Attr(value: string): number {
  if (!INT_DECIMAL.test(value)) { throw new Error('Invalid DASH integer'); }
  const parsed: number = Number(value);
  if (!Number.isSafeInteger(parsed)) { throw new Error('Unsupported DASH integer'); }
  return parsed;
}

function int32Attr(value: string): number {
  const parsed: number = int64Attr(value);
  if (parsed < -2147483648 || parsed > 2147483647) { throw new Error('Unsupported DASH int32'); }
  return parsed;
}

function int32OrDefault(value: string | undefined): number {
  return value === undefined ? -1 : int32Attr(value); // Int32.Parse(width ?? "-1")
}

function int64OrThrow(value: string): number {
  return int64Attr(value); // 空串/垃圾 → throw（.NET Parse 异常→清单丢弃同效）
}

// ────────────── URL 引用（HlsParser.resolveReference 同门槛 + 预算） ──────────────

function resolveReference(base: string, reference: string, resolve: DashUrlResolver,
  budget: DashUrlBudget): string {
  if (reference.length === 0 || reference.length > HLS_MAX_URL_CHARS ||
    base.indexOf('{$') >= 0 || reference.indexOf('{$') >= 0 ||
    new RegExp('[\\x00-\\x1f\\x7f]').test(reference)) { throw new Error('Invalid DASH reference'); }
  const result: string = resolve(base, reference);
  if (result.length === 0 || result.length > HLS_MAX_URL_CHARS || result.indexOf('{$') >= 0 ||
    new RegExp('[\\x00-\\x1f\\x7f]').test(result)) { throw new Error('Invalid DASH resolution'); }
  budget.add(result.length);
  return result;
}

// ────────────── ParseRepresentation 三寻址（:151-306，判定顺序固定不重排） ──────────────

const EMPTY_ATTRS: Record<string, string> = {};

function parentAttrsOf(node: DashXmlNode): Record<string, string> {
  // buildMpdTree 下 Representation 必有父节点；防御空父按空属性表（C# ParentNode NRE 不可达）
  return node.parent !== null ? node.parent.attrs : EMPTY_ATTRS;
}

function baseWithChild(node: DashXmlNode, baseUrl: string, resolve: DashUrlResolver,
  budget: DashUrlBudget): string {
  const baseNode: DashXmlNode | null = firstChild(node, 'BaseURL');
  if (baseNode === null) { return baseUrl; }
  return resolveReference(baseUrl, innerText(baseNode), resolve, budget);
}

function representationOf(segments: string[], widthAttr: string | undefined,
  heightAttr: string | undefined, codecAttr: string | undefined, bandwidthAttr: string | undefined,
  periodDuration: number, mimeType: string, langAttr: string | undefined): DashRepresentation {
  return new DashRepresentation(segments, int32OrDefault(widthAttr), int32OrDefault(heightAttr),
    codecAttr ?? '', bandwidthAttr === undefined ? -1 : int64OrThrow(bandwidthAttr),
    periodDuration, mimeType, langAttr ?? '');
}

function parseRepresentation(node: DashXmlNode, baseUrl: string, periodDuration: number,
  hasParentSegmentBase: boolean, resolve: DashUrlResolver, budget: DashUrlBudget): DashRepresentation | null {
  // 属性继承（:153-158 repr 优先、父 AS 兜底；属性存在但空串不回退——C# ?? null 语义）
  const parentAttrs: Record<string, string> = parentAttrsOf(node);
  const mimeType: string = (node.attrs['mimeType'] ?? parentAttrs['mimeType'] ?? '').toLowerCase();
  const widthAttr: string | undefined = node.attrs['width'] ?? parentAttrs['width'];
  const heightAttr: string | undefined = node.attrs['height'] ?? parentAttrs['height'];
  const bandwidthAttr: string | undefined = node.attrs['bandwidth'] ?? parentAttrs['bandwidth'];
  const codecAttr: string | undefined = node.attrs['codecs'] ?? parentAttrs['codecs'];
  const langAttr: string | undefined = node.attrs['lang'] ?? parentAttrs['lang'];
  if (!mimeType.startsWith('audio') && !mimeType.startsWith('video')) {
    return null;
  }
  const base: string = baseWithChild(node, baseUrl, resolve, budget);

  // ① index 寻址（:170-177）：repr 级 SegmentBase 或 Period 级布尔标志；sidx/字节范围不解析
  if (firstChild(node, 'SegmentBase') !== null || hasParentSegmentBase) {
    const segments: string[] = [base];
    return representationOf(segments, widthAttr, heightAttr, codecAttr, bandwidthAttr,
      periodDuration, mimeType, langAttr);
  }

  // ② list 寻址（:178-202）：仅 repr 级 SegmentList
  const segList: DashXmlNode | null = firstChild(node, 'SegmentList');
  if (segList !== null) {
    const segments: string[] = [];
    const init: DashXmlNode | null = firstChild(segList, 'Initialization') ??
      firstChild(segList, 'RepresentationIndex');
    if (init !== null) {
      // sourceURL 缺失 → C# Resolve(baseUrl, null) NRE→清单丢弃；'' → resolve 门槛 throw（§5-13 收紧面）
      const sourceUrl: string = init.attrs['sourceURL'] ?? '';
      segments.push(resolveReference(base, sourceUrl, resolve, budget));
    }
    const segUrls: DashXmlNode[] = childrenOf(segList, 'SegmentURL');
    for (let i = 0; i < segUrls.length; i++) {
      // mediaRange/indexRange 不消费（源仅读 media）
      const media: string = segUrls[i].attrs['media'] ?? '';
      segments.push(resolveReference(base, media, resolve, budget));
    }
    if (segments.length === 0) { return null; }
    return representationOf(segments, widthAttr, heightAttr, codecAttr, bandwidthAttr,
      periodDuration, mimeType, langAttr);
  }

  // ③ template 寻址（:203-304）：repr 级 ?? 父 AS 级（Period 级不查）；无模板 → :305 return null
  const template: DashXmlNode | null = firstChild(node, 'SegmentTemplate') ??
    (node.parent !== null ? firstChild(node.parent, 'SegmentTemplate') : null);
  if (template === null) { return null; }
  const timeline: DashXmlNode | null = firstChild(template, 'SegmentTimeline');
  if (timeline === null) {
    // simple 寻址（:212-245）
    const timescale: number = int64OrThrow(template.attrs['timescale'] ?? '1');
    const duration: number = int64OrThrow(template.attrs['duration'] ?? '1');
    const startNumber: number = int64OrThrow(template.attrs['startNumber'] ?? '1');
    // §4.6 IEEE 三段语义（C# double 除法 + (int)Ceiling + List 负容量抛错形态表）
    const num: number = periodDuration / 1000;
    const den: number = duration / timescale; // 0/0→NaN、x/0→±∞（与 C# IEEE 同）
    const ratio: number = num / den;
    if (Number.isNaN(ratio) || !Number.isFinite(ratio) || ratio < 0) {
      throw new Error('Invalid DASH segment count'); // 源 List 负容量抛错同效
    }
    const segmentCount: number = Math.ceil(ratio);
    if (segmentCount > DASH_MAX_SEGMENTS) {
      throw new Error('DASH segment limit'); // 源 (int) 溢出→int.MinValue→List 抛错同效（预算显式化 §5-4）
    }
    const reprId: string | undefined = node.attrs['id'];
    if (reprId === undefined) { throw new Error('Missing DASH representation id'); } // C# NRE→丢弃
    let number: number = startNumber;
    let time: number = startNumber; // ★quirk：$Time$ 起点=startNumber 而非 0（:220）
    const initAttr: string | undefined = template.attrs['initialization'];
    const mediaAttr: string | undefined = template.attrs['media'];
    if (mediaAttr === undefined) { throw new Error('Missing DASH media template'); } // Matches(null)→丢弃
    const initEscaped: string | null = initAttr === undefined ? null : escapeTemplate(initAttr);
    const mediaEscaped: string = escapeTemplate(mediaAttr);
    const mediaMatches: DashTemplateMatch[] = scanTemplateMatches(mediaEscaped);
    const segments: string[] = [];
    if (initEscaped !== null) {
      const initUrl: string = restoreTemplate(expandTemplate(scanTemplateMatches(initEscaped),
        initEscaped, number, time, bandwidthAttr ?? '', reprId));
      segments.push(resolveReference(base, initUrl, resolve, budget));
    }
    for (let i = 0; i < segmentCount; i++) {
      const segmentUrl: string = restoreTemplate(expandTemplate(mediaMatches, mediaEscaped,
        number, time, bandwidthAttr ?? '', reprId));
      segments.push(resolveReference(base, segmentUrl, resolve, budget));
      number++;
      time += duration; // 步进用原始 duration（tick 值，:241）
      if (!Number.isSafeInteger(number) || !Number.isSafeInteger(time)) {
        throw new Error('Unsupported DASH template counter');
      }
    }
    if (segments.length === 0) { return null; }
    return representationOf(segments, widthAttr, heightAttr, codecAttr, bandwidthAttr,
      periodDuration, mimeType, langAttr);
  }

  // explicit/Timeline 寻址（:247-301）
  const ss: DashXmlNode[] = childrenOf(timeline, 'S');
  if (ss.length === 0) { return null; } // :251 Count==0 → 落 :305 return null
  const reprId: string | undefined = node.attrs['id'];
  if (reprId === undefined) { throw new Error('Missing DASH representation id'); } // C# NRE→丢弃
  let number: number = int64OrThrow(template.attrs['startNumber'] ?? '1');
  let time: number = 0; // init 段 $Time$=0（:255 先于 init 展开 :263-268）
  const initAttr: string | undefined = template.attrs['initialization'];
  const mediaAttr: string | undefined = template.attrs['media'];
  if (mediaAttr === undefined) { throw new Error('Missing DASH media template'); } // .Value NRE→丢弃
  const initEscaped: string | null = initAttr === undefined ? null : escapeTemplate(initAttr);
  const mediaEscaped: string = escapeTemplate(mediaAttr);
  const mediaMatches: DashTemplateMatch[] = scanTemplateMatches(mediaEscaped);
  const segments: string[] = [];
  if (initEscaped !== null) {
    const initUrl: string = restoreTemplate(expandTemplate(scanTemplateMatches(initEscaped),
      initEscaped, number, time, bandwidthAttr ?? '', reprId));
    segments.push(resolveReference(base, initUrl, resolve, budget));
  }
  for (let i = 0; i < ss.length; i++) {
    const s: DashXmlNode = ss[i];
    const dAttr: string | undefined = s.attrs['d'];
    if (dAttr === undefined) { throw new Error('Missing DASH timeline d'); } // .Value NRE→丢弃
    const d: number = int64OrThrow(dAttr);
    const t: number = int64OrThrow(s.attrs['t'] ?? '-1');
    const r: number = int64OrThrow(s.attrs['r'] ?? '-1');
    if (t > 0) { time = t; } // ★严格不等号：t="0"/t<0 不重置（:276 quirk）
    const duration: number = d;
    const segmentUrl: string = restoreTemplate(expandTemplate(mediaMatches, mediaEscaped,
      number, time, bandwidthAttr ?? '', reprId));
    segments.push(resolveReference(base, segmentUrl, resolve, budget));
    number++;
    time += duration;
    if (!Number.isSafeInteger(number) || !Number.isSafeInteger(time)) {
      throw new Error('Unsupported DASH template counter');
    }
    if (r > 0) { // r=0 与 r=-1 均只发 1 段（源未实现规范语义 1:1，§4.7）
      for (let k = 0; k < r; k++) {
        const repeatUrl: string = restoreTemplate(expandTemplate(mediaMatches, mediaEscaped,
          number, time, bandwidthAttr ?? '', reprId));
        segments.push(resolveReference(base, repeatUrl, resolve, budget));
        number++;
        time += duration;
        if (!Number.isSafeInteger(number) || !Number.isSafeInteger(time)) {
          throw new Error('Unsupported DASH template counter');
        }
        // 段数预算内移（独立复核 medium 修复）：单个 <S r="巨大"> 的内层循环每次 push 后即检，
        // 否则仅靠 URL 字符预算兜底（最坏 ~84 万次迭代×2 次 new RegExp，主线程秒级阻塞）；
        // simple 分支前置门同款口径，最坏迭代数封顶 DASH_MAX_SEGMENTS
        if (segments.length > DASH_MAX_SEGMENTS) { throw new Error('DASH segment limit'); }
      }
    }
    if (segments.length > DASH_MAX_SEGMENTS) { throw new Error('DASH segment limit'); } // §5-4 预算
  }
  if (segments.length === 0) { return null; }
  return representationOf(segments, widthAttr, heightAttr, codecAttr, bandwidthAttr,
    periodDuration, mimeType, langAttr);
}

// ────────────── ParseAdaptationSet（:130-149） ──────────────

function containsTrickMode(node: DashXmlNode): boolean {
  // SelectSingleNode 取首个语义（:401/:410）；schemeIdUri 精确等值（:405/:414）
  const essential: DashXmlNode | null = firstChild(node, 'EssentialProperty');
  if (essential !== null && essential.attrs['schemeIdUri'] === DASH_TRICK_MODE_URI) {
    return true;
  }
  const supplemental: DashXmlNode | null = firstChild(node, 'SupplementalProperty');
  if (supplemental !== null && supplemental.attrs['schemeIdUri'] === DASH_TRICK_MODE_URI) {
    return true;
  }
  return false;
}

function parseAdaptationSet(node: DashXmlNode, baseUrl: string, periodDuration: number,
  hasParentSegmentBase: boolean, resolve: DashUrlResolver, budget: DashUrlBudget): DashRepresentation[] {
  const base: string = baseWithChild(node, baseUrl, resolve, budget); // 局部变量互不污染（:76-80/:133-137）
  if (containsTrickMode(node)) {
    return []; // 整组返回空（:138-141）
  }
  const reprNodes: DashXmlNode[] = childrenOf(node, 'Representation');
  const out: DashRepresentation[] = [];
  for (let i = 0; i < reprNodes.length; i++) {
    const representation: DashRepresentation | null = parseRepresentation(reprNodes[i], base,
      periodDuration, hasParentSegmentBase, resolve, budget);
    if (representation !== null) { out.push(representation); }
  }
  return out;
}

// ────────────── ParsePeriod（:69-128） ──────────────

function parsePeriod(node: DashXmlNode, baseUrl: string, mediaPresentationDuration: number,
  resolve: DashUrlResolver): DashPair[] {
  let periodDuration: number = mediaPresentationDuration;
  const durationAttr: string | undefined = node.attrs['duration'];
  if (durationAttr !== undefined) {
    periodDuration = parseXsDuration(durationAttr); // :72-75 覆盖传入值
  }
  const budget: DashUrlBudget = new DashUrlBudget(); // 周期内累计展开 URL 字符面（§3.3）
  const base: string = baseWithChild(node, baseUrl, resolve, budget);
  // :83 只查 Period 级 child::SegmentBase（AdaptationSet 级不被检查——用例钉住）
  const hasParentSegmentBase: boolean = firstChild(node, 'SegmentBase') !== null;
  const sets: DashXmlNode[] = childrenOf(node, 'AdaptationSet');
  if (sets.length > DASH_MAX_ADAPTATION_SETS) { throw new Error('DASH adaptation set limit'); }
  const audioList: DashRepresentation[] = [];
  const videoList: DashRepresentation[] = [];
  let reprCount: number = 0;
  for (let i = 0; i < sets.length; i++) {
    const representations: DashRepresentation[] = parseAdaptationSet(sets[i], base, periodDuration,
      hasParentSegmentBase, resolve, budget);
    if (representations.length === 0) { continue; } // :90 空组跳过
    reprCount += representations.length;
    if (reprCount > DASH_MAX_REPRESENTATIONS) { throw new Error('DASH representation limit'); }
    // 组分类按首个有效 Representation 的 mime 前缀（:91-98，序数敏感 startsWith）
    if (representations[0].mimeType.startsWith('audio')) {
      for (let j = 0; j < representations.length; j++) { audioList.push(representations[j]); }
    } else {
      for (let j = 0; j < representations.length; j++) { videoList.push(representations[j]); }
    }
  }
  const mediaList: DashPair[] = [];
  if (videoList.length > 0 && audioList.length > 0) {
    // 笛卡尔序=video 外层 × audio 内层（:103-112）
    for (let v = 0; v < videoList.length; v++) {
      for (let a = 0; a < audioList.length; a++) {
        if (mediaList.length >= DASH_MAX_PAIRS) { break; } // §3.3：超出部分条目丢弃（非 throw）
        mediaList.push(new DashPair(videoList[v], audioList[a]));
      }
    }
  } else if (videoList.length > 0) {
    for (let v = 0; v < videoList.length; v++) {
      if (mediaList.length >= DASH_MAX_PAIRS) { break; }
      mediaList.push(new DashPair(videoList[v], null));
    }
  } else if (audioList.length > 0) {
    for (let a = 0; a < audioList.length; a++) {
      if (mediaList.length >= DASH_MAX_PAIRS) { break; }
      mediaList.push(new DashPair(null, audioList[a]));
    }
  }
  return mediaList;
}

// ────────────── 多周期时长反算（:361-397 → parsePeriodDurations） ──────────────

/**
 * CalculatePeriodDurationsIfMissing 直译：逆文档序逐周期；duration 存在 → push(dur)、
 * last=total-dur（仅对最后周期正确，中间带 duration 的混合形态源误差 1:1 保留——用例钉死）；
 * 否则 start 存在 → push(last-start)、last=start；双缺 throw；结束 Reverse 正序返回。
 * 源 :387-390 PT0S 缺省分支死代码不复刻（§5-3 锚登记）。
 */
export function parsePeriodDurations(periods: DashPeriodAttrs[], total: number): number[] {
  const list: number[] = [];
  let last: number = total;
  for (let i = periods.length - 1; i >= 0; i--) { // Stack push 顺排、pop 逆序（:363-373）
    const sduration: string | null = periods[i].duration;
    const sstart: string | null = periods[i].start;
    if (sstart === null && sduration === null) {
      throw new Error('Both period start and duration is missing');
    }
    if (sduration !== null) {
      const duration: number = parseXsDuration(sduration);
      list.push(duration);
      last = total - duration;
      continue;
    }
    const start: number = parseXsDuration(sstart ?? '');
    list.push(last - start);
    last = start;
  }
  list.reverse();
  return list;
}

function periodAttrsOf(periods: DashXmlNode[]): DashPeriodAttrs[] {
  const out: DashPeriodAttrs[] = [];
  for (let i = 0; i < periods.length; i++) {
    const attrs: DashPeriodAttrs = {
      duration: periods[i].attrs['duration'] ?? null,
      start: periods[i].attrs['start'] ?? null
    };
    out.push(attrs);
  }
  return out;
}

// ────────────── Parse 根（:32-66） ──────────────

/**
 * parseDashManifestFromEvents：根门（MPD/dynamic 精确等值/任意层 ContentProtection）→
 * mediaPresentationDuration ?? "0" → 根级 BaseURL 首个 → 周期数门 → 单/多周期分派。
 * 失败 throw=整清单丢弃（源异常上抛→本次清单整体丢弃同效）。
 */
export function parseDashManifestFromEvents(events: DashXmlEvent[], playlistUrl: string,
  resolve: DashUrlResolver): DashPair[][] {
  const root: DashXmlNode = buildMpdTree(events);
  if (root.name !== 'MPD') { throw new Error('Missing MPD start tag'); } // Namespaces=false→本地名
  if (root.attrs['type'] === 'dynamic') {
    // ★大小写敏感（"Dynamic" 不拒——用例钉死）
    throw new Error('Manifest type dynamic is not supported');
  }
  if (hasDescendant(root, 'ContentProtection')) { throw new Error('Encrypted manifest'); }
  const mediaPresentationDuration: number = parseXsDuration(root.attrs['mediaPresentationDuration'] ?? '0');
  let baseUrl: string = playlistUrl;
  const rootBase: DashXmlNode | null = firstChild(root, 'BaseURL');
  if (rootBase !== null) {
    baseUrl = resolveReference(baseUrl, innerText(rootBase), resolve, new DashUrlBudget());
  }
  const periods: DashXmlNode[] = childrenOf(root, 'Period');
  if (periods.length > DASH_MAX_PERIODS) { throw new Error('DASH period limit'); }
  if (periods.length < 1) { throw new Error('No period found!'); }
  const mediaList: DashPair[][] = [];
  if (periods.length > 1) {
    const periodDurations: number[] = parsePeriodDurations(periodAttrsOf(periods), mediaPresentationDuration);
    for (let i = 0; i < periods.length; i++) {
      mediaList.push(parsePeriod(periods[i], baseUrl, periodDurations[i], resolve));
    }
  } else {
    mediaList.push(parsePeriod(periods[0], baseUrl, mediaPresentationDuration, resolve));
  }
  return mediaList;
}
