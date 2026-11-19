/*
 * U0.3 探针单元：P0-U3 扩展桥 8597 服务端探针（设计书 §6 步骤表）。
 * S1 服务启动+端口监听观测（getStats 快照 → start() 幂等 memoized → 再快照；EntryAbility 经
 *    devecocli run 正常拉起即已启动桥服务——alreadyStarted=true 本身就是"启动接线"的运行时证据）。
 * S2 应用内自连 GET /sync 应答观测（同连接 keep-alive 两请求复用观测 + 另开一连接 Connection: close
 *    观测服务端主动关闭；应答经 splitResponseHead+parseSyncBody；原始头+体写 detail 文件）。
 * S3 主机侧 curl 指引（autoRun=false 手动；emit 指引命令串 + 服务端计数快照；全套命令见手册 §4，
 *    AI 在设备连接时代执行，执行后复点"执行"产生复核 minisession）。
 * S4 八路由 404/错误处理观测（逐路径新连接 Connection: close；GET 八条字面量 + GET /sync?x=1
 *    （不剥 query→404）+ POST /sync（体 {}，Content-Length: 2）→200 + 裸发 GARBAGE 观测断连不回包）。
 * 会话代际守卫：每个 runner 入口捕获 runId，每个 await 之后、emit 之前复检 isCurrent，不一致静默
 *   return（U0.2 §3.5 惯例）。自连客户端 10s 硬顶防挂起（沿用 U0.2 END_GATE_TIMEOUT 先例）。
 * 红线：布尔键（portMismatch/jsonValid/closeConnClosed/malformedClosed）均为对直接观测值的谓词
 *   编码，不含通过/失败判定词；期望值只存在于 EXPECT 表。探针可单向 import core/bridge（§0-5）。
 * 注记：应答体/头文本以 Latin-1 逐字节解码（U0.3 的 /sync JSON 全 ASCII，Latin-1==UTF-8；
 *   U6.1 videoList 含 CJK 时升级 util.TextDecoder，不属本单元）。
 */

import { socket } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ProbeKit, KeyValue } from '../core/ProbeKit';
import { ProbePage, ProbeStepDef } from '../core/ProbePage';
import { BridgeServer, BridgeStats } from '../../core/bridge/BridgeServer';
import {
  BRIDGE_PORT, BRIDGE_HOST, BRIDGE_FAMILY, ROUTE_PATHS, appendBytes
} from '../../core/bridge/BridgeProtocol';
import {
  SYNC_BODY_MARKER, ResponseHeadView, SyncBodyView,
  splitResponseHead, parseSyncBody
} from './ProbeBridgeLogic';

/** P0-U3 步骤定义表（S1/S2/S4 autoRun，S3 手动——主机侧 curl 前后各点一次"执行"） */
const BRIDGE_STEPS: ProbeStepDef[] = [
  { stepNo: 'S1', title: '服务启动+端口监听观测', autoRun: true },
  { stepNo: 'S2', title: '应用内自连 GET /sync 应答观测', autoRun: true },
  { stepNo: 'S3', title: '主机侧 curl 指引（手动）', autoRun: false },
  { stepNo: 'S4', title: '八路由 404/错误处理观测', autoRun: true }
];

/** 自连客户端 connect 超时（TCPConnectOptions.timeout，ms） */
const CONNECT_TIMEOUT_MS: number = 5000;
/** 应答等待硬顶：防服务端异常时探针挂起（U0.2 END_GATE_TIMEOUT 先例） */
const RESPONSE_TIMEOUT_MS: number = 10000;
/** Connection: close 后等服务端 FIN 的宽限期（CL 完整先到、close 事件略后的竞态窗口） */
const CLOSE_GRACE_MS: number = 2000;
/** awaitResponse/awaitClose 轮询间隔 */
const POLL_INTERVAL_MS: number = 20;

/** S2 keep-alive 复用请求（两连发同文；头块以 \r\n\r\n 收尾） */
const KEEPALIVE_SYNC_REQUEST: string = 'GET /sync HTTP/1.1\r\nHost: 127.0.0.1:8597\r\n' +
  'Connection: keep-alive\r\n\r\n';
/** S2 服务端主动关闭观测请求（curl 默认形态同构：不发 Connection 头——此处显式 close 等价） */
const CLOSE_SYNC_REQUEST: string = 'GET /sync HTTP/1.1\r\nHost: 127.0.0.1:8597\r\n' +
  'Connection: close\r\n\r\n';
/** S4 POST /sync 样例（体 {}，Content-Length: 2） */
const POST_SYNC_REQUEST: string = 'POST /sync HTTP/1.1\r\nHost: 127.0.0.1:8597\r\n' +
  'Connection: close\r\nContent-Length: 2\r\n\r\n{}';
/** S4 裸发垃圾（状态行 token≤2 → 服务端解析失败断连不回包观测） */
const GARBAGE_REQUEST: string = 'GARBAGE\r\n\r\n';

/** 单路由探测产物（文件内私有）：errCode 非 0 表示连接级失败（也是错误处理观测事实，记 err）。 */
interface RouteProbeResult {
  status: number;
  headComplete: boolean;
  closed: boolean;
  errCode: number;
  errMessage: string;
}

/** S2/S4 应用内自连客户端（constructTCPSocketInstance + connect/send/on('message')/on('close')）。
 * 累积缓冲复用 BridgeProtocol.appendBytes（探针→业务单向依赖，观测与实现同源）。 */
class ProbeBridgeClient {
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
    // connect/send 的 d.ts 标注 @throws：try/catch 收编后原样重抛（运行时仍是同一错误对象，
    // 调用方 err.code/errMessage 观测不受影响），消除 Function may throw exceptions 告警
    try {
      await this.client.connect(opt);
    } catch (e) {
      const cause: Error = e as Error;
      throw cause;
    }
  }

  async sendText(text: string): Promise<void> {
    const opt: socket.TCPSendOptions = { data: text };
    try {
      await this.client.send(opt);
    } catch (e) {
      const cause: Error = e as Error;
      throw cause;
    }
  }

  /** 等待当前应答完整：CL 完整即返；无 CL（404 空体）等服务端 close；10s 硬顶放行。 */
  async awaitResponse(): Promise<void> {
    const deadline: number = Date.now() + RESPONSE_TIMEOUT_MS;
    while (Date.now() < deadline && !this.closed) {
      if (ProbeBridgeClient.responseComplete(this.chunks, this.closed)) {
        return;
      }
      await sleepMs(POLL_INTERVAL_MS);
    }
  }

  /** Connection: close 后等服务端 FIN 的宽限等待（closeConnClosed 观测的竞态窗口吸收）。 */
  async awaitClose(graceMs: number): Promise<void> {
    const deadline: number = Date.now() + graceMs;
    while (Date.now() < deadline && !this.closed) {
      await sleepMs(POLL_INTERVAL_MS);
    }
  }

  /** 取走当前累积应答：按 CL 精确截断并把剩余字节留在缓冲（keep-alive 第二应答复用同一缓冲）；
   * 无 CL（close 定界）全量取走并清空。 */
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

function bytesToLatin1(bytes: Uint8Array): string {
  let out: string = '';
  for (let i = 0; i < bytes.length; i++) {
    out += String.fromCharCode(bytes[i]);
  }
  return out;
}

/** 探针值白名单消毒预转换：逗号不在白名单（ProbeKit VALUE_BAD 会替换 '?'），emit 前统一
 * ', ' 与 ',' → '/'（白名单内且 SUMMARY 段内 '/' 稳定不替换）；原始逗号形另存 detail 文件。 */
function commasToSlash(v: string): string {
  return v.split(', ').join('/').split(',').join('/');
}

function sleepMs(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, ms);
  });
}

/** 单次请求文本（新连接 + Connection: close；不剥 query——/sync?x=1 按 unknown path 404）。 */
function getRequest(path: string): string {
  return 'GET ' + path + ' HTTP/1.1\r\nHost: 127.0.0.1:8597\r\nConnection: close\r\n\r\n';
}

/** 路由状态观测值：errCode 非 0 → 'err'+code（连接失败也是错误处理观测事实）；否则状态码。 */
function statusTextOf(res: RouteProbeResult): string {
  if (res.errCode !== 0) {
    return 'err' + String(res.errCode);
  }
  return String(res.status);
}

@Component
export struct ProbeBridge {
  private probeKit: ProbeKit = ProbeKit.getInstance();

  /** 步骤分派：各 runner 自行捕获 runId 并过会话守卫（设计书 §3.5） */
  private async runStep(stepNo: string): Promise<void> {
    if (stepNo === 'S1') {
      await this.runS1();
      return;
    }
    if (stepNo === 'S2') {
      await this.runS2();
      return;
    }
    if (stepNo === 'S3') {
      await this.runS3();
      return;
    }
    if (stepNo === 'S4') {
      await this.runS4();
      return;
    }
  }

  /** S1 服务启动+端口监听观测：EntryAbility 已 start（memoized 复用）→ 前后快照对比。 */
  private async runS1(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const before: BridgeStats = BridgeServer.getInstance().getStats();
      await BridgeServer.getInstance().start();
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const after: BridgeStats = BridgeServer.getInstance().getStats();
      const portMismatch: boolean = after.boundPort !== BRIDGE_PORT;
      const kvs: KeyValue[] = [
        new KeyValue('alreadyStarted', String(before.started)),
        new KeyValue('boundPort', String(after.boundPort)),
        new KeyValue('portMismatch', String(portMismatch)),
        new KeyValue('connections', String(after.connections)),
        new KeyValue('requests', String(after.requests))
      ];
      this.probeKit.emit('S1', kvs);
    } catch (e) {
      const err = e as BusinessError;
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const errKvs: KeyValue[] = [
        new KeyValue('errCode', String(err.code)),
        new KeyValue('errMessage', err.message ?? '')
      ];
      this.probeKit.emit('S1', errKvs);
    }
  }

  /** S2 自连 /sync 应答观测：keep-alive 同连接两请求（reuseResponses）+ Connection: close 连接
   * （closeConnClosed=服务端主动关闭观测）；resp1 经 splitResponseHead+parseSyncBody 观测八字段；
   * 原始头+体写 detail 文件（大段数据不进 hilog，PROBE_SPEC §2）。 */
  private async runS2(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    const filesDir: string = this.resolveFilesDir();
    const detailName: string = 'probe-P0-U3-' + runId + '-s2-response.txt';
    const connKeep: ProbeBridgeClient = new ProbeBridgeClient();
    const connClose: ProbeBridgeClient = new ProbeBridgeClient();
    let reuseResponses: number = 0;
    let closeConnClosed: boolean = false;
    let primary: Uint8Array = new Uint8Array(0);
    try {
      await connKeep.connect();
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      await connKeep.sendText(KEEPALIVE_SYNC_REQUEST);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      await connKeep.awaitResponse();
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const resp1: Uint8Array = connKeep.take();
      const view1: ResponseHeadView = splitResponseHead(resp1);
      if (view1.status === 200) {
        reuseResponses = 1;
      }
      primary = resp1;
      await connKeep.sendText(KEEPALIVE_SYNC_REQUEST);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      await connKeep.awaitResponse();
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const resp2: Uint8Array = connKeep.take();
      const view2: ResponseHeadView = splitResponseHead(resp2);
      if (view2.status === 200 && reuseResponses === 1) {
        reuseResponses = 2;
      }
      await connKeep.close();
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }

      await connClose.connect();
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      await connClose.sendText(CLOSE_SYNC_REQUEST);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      await connClose.awaitResponse();
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      await connClose.awaitClose(CLOSE_GRACE_MS);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      closeConnClosed = connClose.isClosed();
      await connClose.close();
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }

      const headView: ResponseHeadView = splitResponseHead(primary);
      let bodyText: string = '';
      let bodyBytes: number = 0;
      if (headView.complete) {
        bodyBytes = primary.length - headView.bodyStart;
        bodyText = bytesToLatin1(primary.slice(headView.bodyStart));
      }
      const syncBody: SyncBodyView = parseSyncBody(bodyText);
      // 原始逗号形（parseSyncBody 契约/应答头原值）进 detail 文件；hilog 值白名单不含逗号
      // （PROBE_SPEC §2 / ProbeKit VALUE_BAD，直接 emit 会被替换 '?'）——emit 侧统一经
      // commasToSlash 转白名单内 '/'（SUMMARY 段内 '/' 稳定不替换；R2-F2）
      const fieldOrderRaw: string = syncBody.fieldOrder;
      const fieldOrderSafe: string = commasToSlash(fieldOrderRaw);
      const contentType: string = headerValueOf(headView, 'content-type');
      const cacheControlRaw: string = headerValueOf(headView, 'cache-control');
      const cacheControlSafe: string = commasToSlash(cacheControlRaw);
      const contentLength: string = headerValueOf(headView, 'content-length');

      let detailFile: string = '';
      try {
        const detail = fileIo.openSync(filesDir + '/' + detailName,
          fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
        try {
          const headText: string = headView.complete ?
            bytesToLatin1(primary.slice(0, headView.bodyStart)) : '';
          const markerHit: boolean = bodyText.indexOf(SYNC_BODY_MARKER) >= 0;
          const content: string = 'runId=' + this.probeKit.getRunId() + ' sessionToken=' + runId +
            ' markerHit=' + String(markerHit) +
            ' fieldOrderRaw=' + fieldOrderRaw + '\r\n' +
            headText + '\r\n' + bodyText + '\r\n';
          fileIo.writeSync(detail.fd, content);
          detailFile = detailName;
        } finally {
          fileIo.closeSync(detail);
        }
      } catch (e) {
        detailFile = '';
      }

      const kvs: KeyValue[] = [
        new KeyValue('status', String(headView.status)),
        new KeyValue('contentType', contentType.length > 0 ? contentType : 'absent'),
        new KeyValue('cacheControl', cacheControlSafe.length > 0 ? cacheControlSafe : 'absent'),
        new KeyValue('contentLength', contentLength.length > 0 ? contentLength : 'absent'),
        new KeyValue('bodyBytes', String(bodyBytes)),
        new KeyValue('jsonValid', String(syncBody.jsonValid)),
        new KeyValue('fieldCount', String(syncBody.fieldCount)),
        new KeyValue('fieldOrder', fieldOrderSafe.length > 0 ? fieldOrderSafe : 'absent'),
        new KeyValue('reuseResponses', String(reuseResponses)),
        new KeyValue('closeConnClosed', String(closeConnClosed)),
        new KeyValue('detailFile', detailFile)
      ];
      this.probeKit.emit('S2', kvs);
    } catch (e) {
      const err = e as BusinessError;
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const errKvs: KeyValue[] = [
        new KeyValue('reuseResponses', String(reuseResponses)),
        new KeyValue('closeConnClosed', String(closeConnClosed)),
        new KeyValue('errCode', String(err.code)),
        new KeyValue('errMessage', err.message ?? '')
      ];
      this.probeKit.emit('S2', errKvs);
    } finally {
      await connKeep.close();
      await connClose.close();
    }
  }

  /** S3 主机侧 curl 指引（手动）：emit 指引命令串 + 服务端计数快照；主机侧全套命令见手册 §4。 */
  private async runS3(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    if (!this.probeKit.isCurrent(runId)) {
      return;
    }
    const stats: BridgeStats = BridgeServer.getInstance().getStats();
    const kvs: KeyValue[] = [
      new KeyValue('cmd1', 'hdc fport tcp:18597 tcp:8597'),
      new KeyValue('cmd2', 'curl http://127.0.0.1:18597/sync'),
      new KeyValue('connections', String(stats.connections)),
      new KeyValue('requests', String(stats.requests)),
      new KeyValue('lastMethod', stats.lastMethod.length > 0 ? stats.lastMethod : 'absent'),
      new KeyValue('lastPath', stats.lastPath.length > 0 ? stats.lastPath : 'absent')
    ];
    this.probeKit.emit('S3', kvs);
  }

  /** S4 八路由 404/错误处理观测：逐路径新连接（单路由失败记 err 不中断循环）+ query 404 +
   * POST 200 + garbage 断连不回包。 */
  private async runS4(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    const results: RouteProbeResult[] = [];
    for (let i = 0; i < ROUTE_PATHS.length; i++) {
      results.push(await this.singleRequest(getRequest(ROUTE_PATHS[i])));
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
    }
    const queryResult: RouteProbeResult = await this.singleRequest(getRequest('/sync?x=1'));
    if (!this.probeKit.isCurrent(runId)) {
      return;
    }
    const postResult: RouteProbeResult = await this.singleRequest(POST_SYNC_REQUEST);
    if (!this.probeKit.isCurrent(runId)) {
      return;
    }
    const garbageResult: RouteProbeResult = await this.singleRequest(GARBAGE_REQUEST);
    if (!this.probeKit.isCurrent(runId)) {
      return;
    }
    const malformedClosed: boolean = garbageResult.closed && !garbageResult.headComplete;
    const kvs: KeyValue[] = [
      new KeyValue('syncStatus', statusTextOf(results[0])),
      new KeyValue('downloadStatus', statusTextOf(results[1])),
      new KeyValue('mediaStatus', statusTextOf(results[2])),
      new KeyValue('tabUpdateStatus', statusTextOf(results[3])),
      new KeyValue('vidStatus', statusTextOf(results[4])),
      new KeyValue('clearStatus', statusTextOf(results[5])),
      new KeyValue('linkStatus', statusTextOf(results[6])),
      new KeyValue('argsStatus', statusTextOf(results[7])),
      new KeyValue('querySyncStatus', statusTextOf(queryResult)),
      new KeyValue('postSyncStatus', statusTextOf(postResult)),
      new KeyValue('malformedClosed', String(malformedClosed))
    ];
    this.probeKit.emit('S4', kvs);
  }

  /** 单轮自连探测：新连接 → 发送 → 等应答 → 解析状态；catch 记 errCode/errMessage 不外抛。 */
  private async singleRequest(requestText: string): Promise<RouteProbeResult> {
    const conn: ProbeBridgeClient = new ProbeBridgeClient();
    let result: RouteProbeResult = {
      status: -1, headComplete: false, closed: false, errCode: 0, errMessage: ''
    };
    try {
      await conn.connect();
      await conn.sendText(requestText);
      await conn.awaitResponse();
      const bytes: Uint8Array = conn.take();
      const view: ResponseHeadView = splitResponseHead(bytes);
      const done: RouteProbeResult = {
        status: view.status, headComplete: view.complete, closed: conn.isClosed(),
        errCode: 0, errMessage: ''
      };
      result = done;
    } catch (e) {
      const err = e as BusinessError;
      const failed: RouteProbeResult = {
        status: -1, headComplete: false, closed: conn.isClosed(),
        errCode: err.code, errMessage: err.message ?? ''
      };
      result = failed;
    } finally {
      await conn.close();
    }
    return result;
  }

  /** 组件内取 Context：禁用已弃用 getContext(this)，getHostContext 返回 Context|undefined 需窄化 */
  private resolveFilesDir(): string {
    const ctx = this.getUIContext().getHostContext();
    return ctx?.filesDir ?? '';
  }

  build() {
    Column({ space: 12 }) {
      Text($r('app.string.probe_p0u3_hint'))
        .fontSize(12)
        .opacity(0.7)
        .width('100%')
      ProbePage({
        unitId: 'P0-U3',
        pageTitle: $r('app.string.probe_p0u3_title'),
        steps: BRIDGE_STEPS,
        autoStart: true,
        runStep: (stepNo: string): Promise<void> => this.runStep(stepNo)
      })
        .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .padding(16)
  }
}
