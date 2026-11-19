/*
 * U7.1 DASH XML SDK 适配层（设计书 u7-1-dash-DESIGN.md §2-4/§5-11/§5-12）。
 * 唯一 @kit 触点：@ohos.xml（模块名勘误——MIGRATION_PLAN 决策 7 写 @ohos.util.xml，实际为
 * @ohos.xml；parseXml 自 API14、SAX 自 API24——工程 compatible 23 → 采用 Pull/parseXml 路径，
 * u7-1-dash-xml-sdk-facts.md 实测 d.ts）。仅被 BridgeRoutes/探针引用，Hypium 不导入
 * （@kit 模块本地单测不可依赖；四 MPD 向量公式验证走 DashParser 事件注入 + 真机探针双保险）。
 * 回调合同（u7-1-xml-sdk-api-doc.txt:995-1005）：tokenValueCallbackFunction 收全部 EventType，
 *   ParseInfo.getName()/getText() 取名/文本；attributeValueCallbackFunction 逐属性。
 *   文档未给 token↔attr 跨回调顺序保证（SDK facts 明示）——本适配器状态机对两种先后序均成立：
 *   属性先于 START_TAG 到达时先建无名暂存 start 事件、token 到达补名；token 先到时属性继续
 *   并入同一未决 start 事件；任一"下一 token"到达即冲刷（属同一元素的全部属性回调必先于
 *   下一元素任一回调——流式语义保证）。实测相对序由探针 P7-U1-F S1 attrCallbackOrder 钉板。
 * 预算（§3.3）：清单字符/事件数（≤3×DASH_MAX_NODES，约 nodes+ends+texts 上界）/每节点属性
 *   在 feed 与 buildMpdTree 双侧强制；DOCDECL/ENTITY_REFERENCE 事件显式拒绝（§5-11——防实体
 *   展开研究结论边界项 3；supportDoctype=false 不等于拒绝，双保险）。
 * 解码面：XmlPullParser 只支持 UTF-8（SDK facts）；ManifestClient 已 fatal-UTF8 解码为 string，
 *   此处 TextEncoder 回编码喂入。CDATA→text（C# XmlDocument 将 CDATA 并入文本内容，InnerText 同值）；
 *   WHITESPACE/COMMENT/INSTRUCTION 跳过（XmlDocument 默认丢弃纯空白文本节点、忽略注释/PI）。
 * ArkTS 红线：无 any/解构/for...in/正则字面量；对象字面量具 xml.ParseOptions 类型；
 *   throw 只抛 Error；回调用箭头函数显式返回类型。
 */

import { xml, util } from '@kit.ArkTS';
import { DASH_EVENT_END, DASH_EVENT_START, DASH_EVENT_TEXT, DashUrlResolver, DashXmlEvent,
  parseDashManifestFromEvents } from './DashParser';
import { DASH_MAX_ATTRS_PER_NODE, DASH_MAX_MANIFEST_CHARS, DASH_MAX_NODES, DashPair } from './DashModel';

/** 事件数上界：节点+闭合+文本 ≈ 3×节点预算（树构建仍以节点数/文本预算终审）。 */
const DASH_MAX_EVENTS: number = DASH_MAX_NODES * 3;

/** DECODE_REJECT 事后标记（回调内 throw 若未穿透 SDK 仍可在此终审——双保险）。 */
class MpdDecodeState {
  events: DashXmlEvent[] = [];
  openStart: DashXmlEvent | null = null;
  rejected: boolean = false;
  overBudget: boolean = false;
}

/**
 * decodeMpdEvents：xml.parseXml（ignoreNameSpace=true → 本地名；拒 DOCDECL/ENTITY）→
 * DashXmlEvent[]。清单空/超 DASH_MAX_MANIFEST_CHARS → throw=整清单丢弃。
 */
export function decodeMpdEvents(text: string): DashXmlEvent[] {
  if (text.length === 0 || text.length > DASH_MAX_MANIFEST_CHARS) {
    throw new Error('Invalid DASH manifest text');
  }
  const encoder: util.TextEncoder = util.TextEncoder.create('utf-8');
  const encoded: Uint8Array = encoder.encodeInto(text);
  const state: MpdDecodeState = new MpdDecodeState();

  const flushOpen = (): void => {
    if (state.openStart !== null) {
      state.events.push(state.openStart);
      state.openStart = null;
    }
  };

  const onAttribute = (name: string, value: string): boolean => {
    if (state.overBudget) { return false; }
    if (state.openStart === null) {
      // 属性先于 START_TAG 到达（回调序实测项）：先建无名暂存事件，token 到达补名
      const provisional: DashXmlEvent = new DashXmlEvent();
      provisional.kind = DASH_EVENT_START;
      state.openStart = provisional;
    }
    if (Object.keys(state.openStart.attrs).length >= DASH_MAX_ATTRS_PER_NODE) {
      state.overBudget = true;
      return false;
    }
    state.openStart.attrs[name] = value;
    return true;
  };

  const onToken = (eventType: xml.EventType, parseInfo: xml.ParseInfo): boolean => {
    if (state.overBudget) { return false; }
    // 属性先序合并（独立复核 medium 修复）：START_TAG 到达时若存在无名暂存 start（属性回调
    // 先于 token 建立的事件），补名合并保留已并入属性，而非先冲刷再新建——先冲刷会把空名
    // start 事件泄入事件流且真实元素丢失全部属性（buildMpdTree 对空名 start throw）
    if (eventType === xml.EventType.START_TAG && state.openStart !== null && state.openStart.name === '') {
      state.openStart.name = parseInfo.getName();
      flushOpen();
      return true;
    }
    // 任一下一 token 到达即冲刷未决 start（元素属性回调必已全部完成——流式语义）
    flushOpen();
    if (eventType === xml.EventType.START_TAG) {
      if (state.events.length + 1 > DASH_MAX_EVENTS) { state.overBudget = true; return false; }
      const start: DashXmlEvent = new DashXmlEvent();
      start.kind = DASH_EVENT_START;
      start.name = parseInfo.getName();
      state.openStart = start;
    } else if (eventType === xml.EventType.END_TAG) {
      if (state.events.length + 1 > DASH_MAX_EVENTS) { state.overBudget = true; return false; }
      const end: DashXmlEvent = new DashXmlEvent();
      end.kind = DASH_EVENT_END;
      end.name = parseInfo.getName();
      state.events.push(end);
    } else if (eventType === xml.EventType.TEXT || eventType === xml.EventType.CDSECT) {
      if (state.events.length + 1 > DASH_MAX_EVENTS) { state.overBudget = true; return false; }
      const body: DashXmlEvent = new DashXmlEvent();
      body.kind = DASH_EVENT_TEXT;
      body.text = parseInfo.getText();
      state.events.push(body);
    } else if (eventType === xml.EventType.DOCDECL || eventType === xml.EventType.ENTITY_REFERENCE) {
      // §5-11：显式拒绝防实体展开（supportDoctype=false 不等于拒绝——SDK facts，双保险）
      state.rejected = true;
      return false;
    }
    // START_DOCUMENT/END_DOCUMENT/WHITESPACE/COMMENT/INSTRUCTION：按文件头注释语义跳过
    return true;
  };

  const parser: xml.XmlPullParser = new xml.XmlPullParser(encoded.buffer as ArrayBuffer, 'UTF-8');
  const options: xml.ParseOptions = {
    supportDoctype: false,
    ignoreNameSpace: true,
    tokenValueCallbackFunction: onToken,
    attributeValueCallbackFunction: onAttribute
  };
  parser.parseXml(options);
  if (state.overBudget) { throw new Error('DASH event budget exceeded'); }
  if (state.rejected) { throw new Error('DASH DTD entity rejected'); }
  flushOpen();
  return state.events;
}

/** parseDashManifest：本层解码 + DashParser 纯语义组合（失败 throw=整清单丢弃）。 */
export function parseDashManifest(text: string, url: string, resolve: DashUrlResolver): DashPair[][] {
  return parseDashManifestFromEvents(decodeMpdEvents(text), url, resolve);
}
