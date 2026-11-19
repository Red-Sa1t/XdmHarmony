/*
 * U6.1 探针共用自连 TCP 客户端（设计书 u6-1-bridge-eight-routes-DESIGN.md §5.7-#9）：
 * P0-U3 的 ProbeBridgeClient（ProbeBridge.ets 文件内私有类）提炼为可复用文件——归档文件
 * P0-U3 不动（UNIT_CATALOG 探针节奏节），后续桥类探针（P6-U1 起）统一引本文件。
 * 形态对齐 connector.js:45 的 fetch 请求：POST 构造**不带 Content-Type/Connection 头**
 * （仅 Host + Content-Length），Content-Length=体字节长；GET 同不带 Connection——服务端
 * isKeepAlive 缺省 close → 应答后断连，"服务端关连接 + 已读 CL 字节"双定界（设计书 §2.2）。
 * 会话代际守卫与 10s 硬顶沿用 P0-U3 惯例（ProbeBridge.ets:41-48 常量平移）。
 * 红线：探针可单向 import core/bridge（§0-5）；本文件不得被 core/ 引用。
 * ArkTS 红线：无 any/解构/for...in/正则字面量；对象字面量具类型；显式返回类型。
 */

import { socket } from '@kit.NetworkKit';
import {
  BRIDGE_PORT, BRIDGE_HOST, BRIDGE_FAMILY, appendBytes, utf8Encode, utf8Decode
} from '../../core/bridge/BridgeProtocol';
import { ResponseHeadView, splitResponseHead } from './ProbeBridgeLogic';

/** 自连客户端 connect 超时（TCPConnectOptions.timeout，ms；P0-U3 平移） */
const CONNECT_TIMEOUT_MS: number = 5000;
/** 应答等待硬顶：防服务端异常时探针挂起（U0.2 END_GATE_TIMEOUT 先例） */
const RESPONSE_TIMEOUT_MS: number = 10000;
/** awaitResponse/awaitClose 轮询间隔 */
const POLL_INTERVAL_MS: number = 20;

/**
 * 探针自连 TCP 客户端：constructTCPSocketInstance + connect/send/on('message')/on('close')。
 * 累积缓冲复用 BridgeProtocol.appendBytes（探针→业务单向依赖，观测与实现同源）；
 * 应答完整性谓词：CL 完整即返 / 无 CL（空体应答）等服务端 close / 10s 硬顶放行。
 */
export class ProbeTcpClient {
  private client: socket.TCPSocket = socket.constructTCPSocketInstance();
  private chunks: Uint8Array = new Uint8Array(0);
  private closed: boolean = false;

  async connect(): Promise<void> {
    this.client.on('message', (info: socket.SocketMessageInfo) => {
      this.chunks = appendBytes(this.chunks, new Uint8Array(info.message));
    });
    this.client.on('close', () => {
      this.closed = true;
    });
    const addr: socket.NetAddress = { address: BRIDGE_HOST, port: BRIDGE_PORT, family: BRIDGE_FAMILY };
    const opt: socket.TCPConnectOptions = { address: addr, timeout: CONNECT_TIMEOUT_MS };
    // connect/send 的 d.ts 标注 @throws：try/catch 收编后原样重抛（P0-U3 同款）
    try {
      await this.client.connect(opt);
    } catch (e) {
      const cause: Error = e as Error;
      throw cause;
    }
  }

  async sendBytes(bytes: Uint8Array): Promise<void> {
    const data: ArrayBuffer =
      bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
    const opt: socket.TCPSendOptions = { data: data };
    try {
      await this.client.send(opt);
    } catch (e) {
      const cause: Error = e as Error;
      throw cause;
    }
  }

  /** 等待当前应答完整：CL 完整即返；无 CL 等服务端 close；10s 硬顶放行。 */
  async awaitResponse(): Promise<void> {
    const deadline: number = Date.now() + RESPONSE_TIMEOUT_MS;
    while (Date.now() < deadline && !this.closed) {
      if (ProbeTcpClient.responseComplete(this.chunks, this.closed)) {
        return;
      }
      await sleepMs(POLL_INTERVAL_MS);
    }
  }

  /** 请求发完后等服务端 FIN 的宽限等待（close 观测的竞态窗口吸收，P0-U3 同款）。 */
  async awaitClose(graceMs: number): Promise<void> {
    const deadline: number = Date.now() + graceMs;
    while (Date.now() < deadline && !this.closed) {
      await sleepMs(POLL_INTERVAL_MS);
    }
  }

  /** 取走当前累积应答：按 CL 精确截断并把剩余字节留在缓冲；无 CL（close 定界）全量取走并清空。 */
  take(): Uint8Array {
    const view: ResponseHeadView = splitResponseHead(this.chunks);
    if (view.complete) {
      const cl: number = contentLengthOf(view);
      if (cl >= 0 && this.chunks.length > view.bodyStart + cl) {
        const consumed: number = view.bodyStart + cl;
        const out: Uint8Array = this.chunks.slice(0, consumed);
        this.chunks = this.chunks.slice(consumed);
        return out;
      }
    }
    const all: Uint8Array = this.chunks;
    this.chunks = new Uint8Array(0);
    return all;
  }

  isClosed(): boolean {
    return this.closed;
  }

  async close(): Promise<void> {
    try {
      await this.client.close();
    } catch (e) {
      // 观测通道关闭失败不影响已取观测值
    }
  }

  /** 应答完整性谓词：closed 即完整；CL 有效按 bodyStart+cl 计；无 CL 等 close。 */
  private static responseComplete(bytes: Uint8Array, closed: boolean): boolean {
    if (closed) {
      return true;
    }
    const view: ResponseHeadView = splitResponseHead(bytes);
    if (!view.complete) {
      return false;
    }
    const cl: number = contentLengthOf(view);
    if (cl >= 0) {
      return bytes.length >= view.bodyStart + cl;
    }
    return false;
  }
}

/** POST 构造（connector.js fetch 形态：Host + Content-Length，**无 Content-Type/Connection**）：
 * 头块 ASCII + 体 UTF-8（CJK 文件名体正确编码），Content-Length=体字节长。 */
export function postJsonRequest(path: string, jsonText: string): Uint8Array {
  const body: Uint8Array = utf8Encode(jsonText);
  const head: string = 'POST ' + path + ' HTTP/1.1\r\nHost: 127.0.0.1:' + String(BRIDGE_PORT) +
    '\r\nContent-Length: ' + String(body.length) + '\r\n\r\n';
  return appendBytes(asciiBytes(head), body);
}

/** GET 构造（无 Connection 头——curl 默认形态同构，服务端缺省 close 应答后断连）。 */
export function getRequest(path: string): Uint8Array {
  const head: string = 'GET ' + path + ' HTTP/1.1\r\nHost: 127.0.0.1:' + String(BRIDGE_PORT) +
    '\r\n\r\n';
  return asciiBytes(head);
}

/** 应答体 UTF-8 解码（videoList 文本可含 CJK；utf8Decode 与实现同源）。 */
export function decodeBody(bytes: Uint8Array, bodyStart: number): string {
  return utf8Decode(bytes.slice(bodyStart));
}

/** 头块 ASCII 编码。 */
function asciiBytes(s: string): Uint8Array {
  const out: Uint8Array = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) {
    out[i] = s.charCodeAt(i);
  }
  return out;
}

/** 探针侧小写头查找（ResponseHeadView.headerNames 已统一小写）。 */
function headerValueOf(view: ResponseHeadView, name: string): string {
  const idx: number = view.headerNames.indexOf(name);
  if (idx >= 0 && view.headerValues[idx].length > 0) {
    return view.headerValues[idx][0];
  }
  return '';
}

function contentLengthOf(view: ResponseHeadView): number {
  const raw: string = headerValueOf(view, 'content-length');
  if (raw.length === 0) {
    return -1;
  }
  const parsed: number = Number(raw);
  if (!Number.isFinite(parsed) || parsed < 0) {
    return -1;
  }
  return parsed;
}

function sleepMs(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, ms);
  });
}
