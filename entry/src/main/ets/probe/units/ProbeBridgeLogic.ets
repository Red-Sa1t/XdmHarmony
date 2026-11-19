/*
 * U0.3 探针专用客户端纯函数（设计书 §5.4）：服务端不解析自身应答——应答头/体切分与 /sync
 * 应答体形状观测放探针模块。零 @kit import：本地单测（entry/src/test）与 ProbeBridge 均可直接
 * import（探针→业务单向依赖红线只约束 core/，本文件不 import core/，与 BridgeProtocol 无耦合）。
 * S2 观测面：jsonValid（JSON.parse 成功性）+ fieldCount + fieldOrder（Object.keys 序 = 应答体
 * 文本序，八字段契约的观测面）；值只写观测事实，判定在 xdm-probe-verify 对照 EXPECT 表进行。
 */

/** S2 观测辅助锚：/sync 应答体首字段名（含 JSON 引号形态，用于 detail 文件证据核验）。 */
export const SYNC_BODY_MARKER: string = '"enabled"';

/** 客户端应答头切分产物：status 取状态行第二 token（'HTTP/1.0 200 OK'→200，解析失败 -1 且
 * failed=true）；headerNames 统一小写便于查找；bodyStart 指向体首字节（无体应答 = buf.length，
 * 完整性靠 on('close') 门，设计书 §3.4-4）。 */
export interface ResponseHeadView {
  complete: boolean;
  failed: boolean;
  status: number;
  statusLine: string;
  headerNames: string[];
  headerValues: string[][];
  bodyStart: number;
}

/** /sync 应答体形状观测产物：jsonValid=JSON.parse 成功且为对象；fieldCount=顶层字段数；
 * fieldOrder=顶层字段名逗号连接（保持应答体文本序）。 */
export interface SyncBodyView {
  jsonValid: boolean;
  fieldCount: number;
  fieldOrder: string;
}

/** 应答头/体切分：字节级扫 \r\n\r\n（13,10,13,10）定头块尾；头块在完整到达后 Latin-1 转字符串
 * 按行解析（自连客户端一次性累积应答后再切，无服务端侧任意分包增量需求）。状态行 token>1 才取
 * 第二 token 为 status；头行取首个 ':' 且 index>0，头名小写化；应答头行异常不置 failed（自产
 * 应答格式可控，解析只观测不判定）。 */
export function splitResponseHead(buf: Uint8Array): ResponseHeadView {
  const view: ResponseHeadView = {
    complete: false, failed: false, status: -1, statusLine: '',
    headerNames: [], headerValues: [], bodyStart: buf.length
  };
  let end: number = -1;
  for (let i = 0; i + 3 < buf.length; i++) {
    if (buf[i] === 13 && buf[i + 1] === 10 && buf[i + 2] === 13 && buf[i + 3] === 10) {
      end = i;
      break;
    }
  }
  if (end < 0) {
    return view;
  }
  view.complete = true;
  view.bodyStart = end + 4;
  let headText: string = '';
  for (let i = 0; i < end; i++) {
    headText += String.fromCharCode(buf[i]);
  }
  const lines: string[] = headText.split('\r\n');
  if (lines.length === 0) {
    view.failed = true;
    return view;
  }
  view.statusLine = lines[0];
  const tokens: string[] = lines[0].split(' ');
  if (tokens.length > 1) {
    const code: number = Number(tokens[1]);
    if (Number.isFinite(code)) {
      view.status = code;
    } else {
      view.failed = true;
    }
  } else {
    view.failed = true;
  }
  for (let i = 1; i < lines.length; i++) {
    const colon: number = lines[i].indexOf(':');
    if (colon > 0) {
      const name: string = lines[i].slice(0, colon).trim().toLowerCase();
      const value: string = lines[i].slice(colon + 1).trim();
      const existing: number = view.headerNames.indexOf(name);
      if (existing >= 0) {
        view.headerValues[existing].push(value);
      } else {
        const single: string[] = [value];
        view.headerNames.push(name);
        view.headerValues.push(single);
      }
    }
  }
  return view;
}

/** /sync 应答体形状观测：JSON.parse + Object.keys 序；非法串（含 null/标量等非对象形态解析期
 * 抛错或 keys 抛错）→ jsonValid=false；字段缺失时 fieldCount<8（观测不判定，判定在 EXPECT 表）。 */
export function parseSyncBody(bodyText: string): SyncBodyView {
  const view: SyncBodyView = { jsonValid: false, fieldCount: 0, fieldOrder: '' };
  try {
    const obj: Record<string, Object> = JSON.parse(bodyText) as Record<string, Object>;
    const keys: string[] = Object.keys(obj);
    view.jsonValid = true;
    view.fieldCount = keys.length;
    view.fieldOrder = keys.join(',');
  } catch (e) {
    view.jsonValid = false;
  }
  return view;
}
