/*
 * U0.3 扩展桥 8597 服务端（设计书 §5.2）：TCPSocketServer 监听 + 每连接 ClientSession 缓冲泵。
 * 对照源码（本会话只读核实）：
 *   IpcHttpMessageProcessor.cs:22-45   —— NanoServer(IPAddress.Loopback, 8597) + Run() 启动；
 *                                         bind 失败的 MSG_ALREADY_RUNNING 弹窗在鸿蒙侧降级为仅日志
 *                                         （设计书 §0-3，UI 提示留 U6.x）。
 *   HttpServer.cs:21-64                —— 阻塞 accept 循环 + 每连接专职线程 → 鸿蒙事件循环投影：
 *                                         listen() 一次 + on('connect') 回调 + 每连接 ClientSession
 *                                         状态泵（busy/pending 串行化 send，无锁，不用 TaskPool）。
 *   HttpServer.cs:46-63                —— while(true){ParseContext→HandleRequest→!KeepAlive break}；
 *                                         处理异常 rethrow → 每连接 catch → tcp.Close()（不回任何应答）
 *                                         ——鸿蒙侧 catch → conn.close() 不 send（§0-1①）。
 *   IpcHttpMessageProcessor.cs:47-86   —— switch 八路径精确分发；业务异常 rethrow → 每连接
 *                                         catch → tcp.Close()（不回任何应答）——鸿蒙侧 catch →
 *                                         conn.close() 不 send（§0-1①）。
 * U6.1 重写（设计书 u6-1-bridge-eight-routes-DESIGN.md §3.1/§5.6）：dispatchRequest 改为
 *   classifyRoute → 未知 throw（静默断连）→ BridgeRoutes.handleRoute（业务）→ 统一
 *   buildSyncResponse。**U0.3 的 D1/D2 中间态（七路由 404 空体 / 未知路径 404）本单元废止**
 *   （§0-1 拍板：1:1 源 default→ArgumentException + HttpServer.cs:56-63 断连不回应答）；
 *   本地 404 应答与 sync 组装函数已删（业务与应答组装移 BridgeRoutes）。
 *   **ClientSession 泵/start/stop/stats、EntryAbility 接线零改动。**
 * 红线（设计书 §0-5）：本文件不得引用探针目录下任何文件；不得输出探针标记行（含标记锚
 * 子串的日志一律禁止，hilog domain 0x0000、tag 'BridgeServer'）；日志不含请求体内容（隐私）。
 * API 面注记：TCPSocketConnection 的连接标识字段本机 d.ts（@ohos.net.socket.d.ts:4001）实为
 * clientId（设计书 §3.6 所记 socketId 系笔误），以 d.ts 为准。
 */

import { socket } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  BRIDGE_PORT, BRIDGE_HOST, BRIDGE_FAMILY,
  BridgeResponse, HeadParseResult,
  appendBytes, parseHead, getContentLength, isKeepAlive,
  buildResponseBytes, classifyRoute
} from './BridgeProtocol';
import { handleRoute, buildSyncResponse } from './BridgeRoutes';

/** 业务日志域：0x0000 + tag 'BridgeServer'（与探针日志域 0xD001 严格分离，§0-5） */
const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'BridgeServer';

/** 连接/请求统计快照（探针 S1/S3 观测源）；lastMethod/lastPath 为原版丢弃的 method 的观测补偿。 */
export interface BridgeStats {
  started: boolean;
  boundPort: number;
  connections: number;
  requests: number;
  lastMethod: string;
  lastPath: string;
}

/** 8597 服务端单例（同 Config/DownloadManager 惯例）。 */
export class BridgeServer {
  private static instance: BridgeServer | undefined = undefined;

  private server: socket.TCPSocketServer | undefined = undefined;
  private started: boolean = false;
  private startPromise: Promise<void> | undefined = undefined;
  private boundPort: number = -1;
  private connections: number = 0;
  private requests: number = 0;
  private lastMethod: string = '';
  private lastPath: string = '';

  private constructor() {
  }

  static getInstance(): BridgeServer {
    if (BridgeServer.instance === undefined) {
      BridgeServer.instance = new BridgeServer();
    }
    return BridgeServer.instance;
  }

  /** 幂等 + memoized promise：EntryAbility 与探针 S1 并发/先后调用共享同一 Promise。
   * 成功路径：construct → on('connect')/on('error') → listen({127.0.0.1,8597,family:1}) →
   * getLocalAddress() 校验 → boundPort 记录（listen 成功≠拿到 8597——bind 失败系统随机分配端口，
   * §0-3：失配仅 hilog.warn + 探针观测 portMismatch，不弹窗）。失败路径：复位 memoized 状态允许重试。 */
  start(): Promise<void> {
    if (this.startPromise !== undefined) {
      return this.startPromise;
    }
    this.startPromise = this.doStart();
    return this.startPromise;
  }

  /** 探针/测试路径：关闭监听端口并复位状态（后续 start() 重建）。 */
  async stop(): Promise<void> {
    const server = this.server;
    this.server = undefined;
    this.started = false;
    this.startPromise = undefined;
    this.boundPort = -1;
    if (server !== undefined) {
      try {
        await server.close();
      } catch (e) {
        const err = e as BusinessError;
        hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s', 'stop close failed errCode=' +
          String(err.code) + ' errMessage=' + (err.message ?? ''));
      }
    }
  }

  /** start() 已调用且 listen 成功（memoized 含义；探针 S1 的 alreadyStarted 观测源）。 */
  isStarted(): boolean {
    return this.started;
  }

  /** 同步统计快照（S1/S3 观测源）。 */
  getStats(): BridgeStats {
    const stats: BridgeStats = {
      started: this.started,
      boundPort: this.boundPort,
      connections: this.connections,
      requests: this.requests,
      lastMethod: this.lastMethod,
      lastPath: this.lastPath
    };
    return stats;
  }

  /** 内部：ClientSession 每请求记账（requests/lastMethod/lastPath）。 */
  noteRequest(method: string, path: string): void {
    this.requests++;
    this.lastMethod = method;
    this.lastPath = path;
  }

  private async doStart(): Promise<void> {
    const server: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();
    server.on('connect', (conn: socket.TCPSocketConnection) => {
      this.onConnect(conn);
    });
    server.on('error', (err: Error) => {
      const be = err as BusinessError;
      hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s', 'server error errCode=' +
        String(be.code) + ' errMessage=' + (be.message ?? ''));
    });
    const addr: socket.NetAddress = { address: BRIDGE_HOST, port: BRIDGE_PORT, family: BRIDGE_FAMILY };
    try {
      await server.listen(addr);
      const local: socket.NetAddress = await server.getLocalAddress();
      this.boundPort = local.port ?? -1;
      this.server = server;
      this.started = true;
      if (this.boundPort !== BRIDGE_PORT) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, '%{public}s', 'port mismatch boundPort=' +
          String(this.boundPort) + ' expected=' + String(BRIDGE_PORT));
      }
    } catch (e) {
      const be = e as BusinessError;
      hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s', 'start failed errCode=' +
        String(be.code) + ' errMessage=' + (be.message ?? ''));
      this.server = undefined;
      this.started = false;
      this.startPromise = undefined;
      this.boundPort = -1;
      // arkts-limited-throw：throw 只接受 Error 及子类——BusinessError 为 interface，升型为
      // Error 满足检查；运行时仍是同一错误对象（code/message 保留，EntryAbility catch 可读）
      const cause: Error = be;
      throw cause;
    }
  }

  /** 每连接入口（原版每连接线程对应物，HttpServer.cs:42-64）：connections++ + 新建会话泵。 */
  private onConnect(conn: socket.TCPSocketConnection): void {
    this.connections++;
    const session: ClientSession = new ClientSession(conn, this);
    session.start();
  }
}

/** 每连接会话（文件内私有类）：累积缓冲泵——增量解析 → 取体 → dispatch → 单次 send → keep-alive 判定。
 * on('message') 的 ArrayBuffer 是任意分包：每包 appendBytes 累积后重扫（头块量级小，重扫换无状态）。
 * busy/pending 串行化：send await 期间新包只置 pending（数据已入缓冲），send 完成后泵内 while
 * 继续消费；防应答乱序。异常二分（设计书 §0-1）：解析失败/Content-Length 非法/处理异常 →
 * closeSilently（关闭连接不回任何应答，1:1 原版 HttpServer.cs:56-63）。 */
class ClientSession {
  private conn: socket.TCPSocketConnection;
  private owner: BridgeServer;
  private clientId: number;
  private buffer: Uint8Array;
  private busy: boolean;
  private pending: boolean;
  private closed: boolean;

  constructor(conn: socket.TCPSocketConnection, owner: BridgeServer) {
    this.conn = conn;
    this.owner = owner;
    this.clientId = conn.clientId;
    this.buffer = new Uint8Array(0);
    this.busy = false;
    this.pending = false;
    this.closed = false;
  }

  start(): void {
    this.conn.on('message', (info: socket.SocketMessageInfo) => {
      this.onMessage(info);
    });
    this.conn.on('close', () => {
      this.onClose();
    });
  }

  private onMessage(info: socket.SocketMessageInfo): void {
    if (this.closed) {
      return;
    }
    this.buffer = appendBytes(this.buffer, new Uint8Array(info.message));
    this.drain();
  }

  private onClose(): void {
    this.closed = true;
    this.buffer = new Uint8Array(0);
  }

  private async drain(): Promise<void> {
    if (this.busy) {
      this.pending = true;
      return;
    }
    this.busy = true;
    try {
      while (!this.closed) {
        const head: HeadParseResult = parseHead(this.buffer, 0);
        // failed 判定必须先于 complete：parseHead 的失败路径（token≤2/头行无冒号）在处理非空行时
        // 即返回，此时 complete 恒为 false——若先判 complete 会把所有解析失败落入 break（连接保持
        // 打开），偏离原版 HttpServer.cs:56-63 断连语义（R2-F1）
        if (head.failed) {
          this.closeSilently('parse failed');
          return;
        }
        if (!head.complete) {
          break;
        }
        const contentLength: number = getContentLength(head.headers);
        if (contentLength === -2) {
          this.closeSilently('invalid content-length');
          return;
        }
        let body: Uint8Array = new Uint8Array(0);
        if (contentLength > 0) {
          if (this.buffer.length < head.bodyStart + contentLength) {
            break;
          }
          body = this.buffer.slice(head.bodyStart, head.bodyStart + contentLength);
        }
        const consumed: number = contentLength > 0 ? head.bodyStart + contentLength : head.bodyStart;
        this.buffer = this.buffer.slice(consumed);
        this.owner.noteRequest(head.method, head.path);
        const resp: BridgeResponse = await dispatchRequest(head.path, head.method, body);
        if (this.closed) {
          return;
        }
        const out: Uint8Array = buildResponseBytes(resp.status, resp.msg,
          resp.headerNames, resp.headerValues, resp.body);
        const data: ArrayBuffer = out.buffer as ArrayBuffer;
        const sendOpt: socket.TCPSendOptions = { data: data };
        await this.conn.send(sendOpt);
        if (this.closed) {
          return;
        }
        if (!isKeepAlive(head.headers)) {
          this.closed = true;
          await this.conn.close();
          return;
        }
      }
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s', 'session error clientId=' +
        String(this.clientId) + ' errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
      this.closeSilently('exception');
    } finally {
      this.busy = false;
    }
    if (this.pending && !this.closed) {
      this.pending = false;
      this.drain();
    }
  }

  /** 断连不回包：只 close 不 send（§0-1①），清缓冲。 */
  private closeSilently(reason: string): void {
    this.closed = true;
    this.buffer = new Uint8Array(0);
    this.conn.close().catch((err: BusinessError) => {
      hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s', 'close failed clientId=' +
        String(this.clientId) + ' reason=' + reason + ' errCode=' +
        String(err.code) + ' errMessage=' + (err.message ?? ''));
    });
  }
}

/** 八路径精确分发（IpcHttpMessageProcessor.cs:51-86 switch 投影，U6.1 设计书 §3.1 八行骨架）：
 * ①classifyRoute（path 字面量精确匹配，不剥 query 不校验 method——method 仅日志观测）；
 * ②未知路径 → hilog + throw（1:1 源 default→ArgumentException；U0.3 D2 的 404 中间态废止，
 *   §0-1）→ 泵 closeSilently 断连不回任何字节；③handleRoute 业务（任何 throw——JSON 门/
 * 缺字段/NRE 等价物——穿透到泵，绝不 catch 转 404/500）；④八路由成功统一 200+sync JSON
 * （含 null 体早退、/vid 未命中静默、/args 空表；唯一例外 /args 业务内层吞异常仍走到本行）。 */
async function dispatchRequest(path: string, method: string, body: Uint8Array): Promise<BridgeResponse> {
  const idx: number = classifyRoute(path);
  if (idx < 0) {
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'unsupported route method=' +
      method + ' path=' + path);
    throw new Error('Unsupported request: ' + path);
  }
  await handleRoute(idx, body);
  return buildSyncResponse();
}
