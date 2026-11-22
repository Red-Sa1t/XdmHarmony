/*
 * U1.2 纯传输层（设计书 §5.5，参考模型 DotNetHttpClient.cs 语义 + @ohos.net.http 落地）。
 * 职责：单请求封装 http.HttpRequest——open(url,header) 走 requestInStream 回传 status+headers、
 * dataReceive 分块回调、dataEnd 门+15s 硬顶、abort()=destroy() 立即断流+生成代自增。
 * 分层红线（禁入，违者 Phase 2 TaskPool 分段化返工）：无文件落盘、无进度累计、无重试循环、
 * 无 Range 头生成（Range 由引擎侧经 header Record 传入，206 白名单判定在 HttpProtocol/engine）。
 * Cookie 原始串注入机制 = header Record 直传 'Cookie' 键（DotNetHttpClient.cs:84-87 SetHeader("Cookie",…)
 * 等价面）；U1.2 无 cookie 来源（对话框契约无 cookie 字段），注入点保留。
 * 平台语义锚（本机 SDK d.ts）：requestInStream(url,options?):Promise<number>:2222（resolve 值=最终
 * status，栈自动跟随重定向后回传最终码）；headersReceive:2286（重定向跳点触发行为未证实——S2 观测，
 * 决策 9 降级 D1：HttpResponse 无最终 URL 字段 d.ts:3607-3760，PrimaryUrl 恒原始 URL）；dataReceive:2361、
 * dataEnd:2411、destroy():2241、usingCache:223、connectTimeout:311、readTimeout:289。
 * 挂起防御：abortGate 与 requestInStream/dataEnd/15s 硬顶全部 Promise.race——destroy() 后
 * requestInStream 的 Promise 不保证 settle（ProbeHttp.ets:56-57 END_GATE 同值模式）。
 * 真机时序（2026-10-18 P2-U2 插桩实测）：headersReceive 与首块 dataReceive 在建连后即到，requestInStream
 * 的 status 直到整条流结束才 resolve；readTimeout 被 netstack 当作整次传输总时限。故 open 以
 * Content-Range 先行确认 206（provisionalStatusOf），末跳头到达即撤状态时限，readTimeout 放到 24h。
 * 日志：hilog domain 0x0000 tag 'HttpClient'（业务通道，绝不 [XDM_PROBE]）。
 */

import { http, connection } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Config } from '../Config';
import { TransportProxy, PROXY_CUSTOM, PROXY_DIRECT } from './TransportPolicy';

/** 2026-11-22：代理决策 → HttpRequestOptions.usingProxy（系统代理=true，直连=false，自定义=HttpProxy） */
export function usingProxyOf(proxy: TransportProxy | undefined): boolean | connection.HttpProxy {
  if (proxy === undefined || proxy.mode === PROXY_DIRECT) {
    return false;
  }
  if (proxy.mode === PROXY_CUSTOM) {
    const custom: connection.HttpProxy = { host: proxy.host, port: proxy.port, exclusionList: [] };
    if (proxy.user.length > 0) {
      custom.username = proxy.user;
      custom.password = proxy.password;
    }
    return custom;
  }
  return true;
}

/** dataEnd 门空闲超时：SDK 不保证断流时 dataEnd 触发——两次分块间隔超过该值才判 ended=false（防挂起）；
 * 不作总时长上限（独立复核 medium 修复：长下载不受硬顶，空闲语义由 dataReceive 重置计时承载） */
export const END_GATE_TIMEOUT_MS: number = 15000;

/** readTimeout 上限：netstack 把 readTimeout 实现为整次传输总时限（2026-10-18 真机 P2-U2：慢源连续流
 * curl total=30000ms 报 2300028 被掐断）。传输空闲由 END_GATE 空闲计时承载，此处只给 24h 上限。 */
export const STREAM_TRANSFER_CAP_MS: number = 86400000;

const CONTENT_RANGE_206: RegExp = new RegExp('^bytes [0-9]+-[0-9]+/([0-9]+|[*])$');

function headerValueOfRecord(rec: Record<string, string>, name: string): string {
  const keys: string[] = Object.keys(rec);
  for (let i = 0; i < keys.length; i++) {
    if (keys[i].toLowerCase() === name) {
      return String(rec[keys[i]]).trim();
    }
  }
  return '';
}

/** 头推断状态码：requestInStream 的 status 直到整条流结束才 resolve（2026-10-18 真机实测：头与首块
 * 11ms 到达、status 30s 后才结算），headersReceive 头不含状态行。`Content-Range: bytes S-E/T` 只随 206
 * 下发（416 的未满足区间形以星号起始，不匹配），故据此先行确认 206；其余响应仍等终态码，不臆造。 */
export function provisionalStatusOf(rec: Record<string, string>): number {
  return CONTENT_RANGE_206.test(headerValueOfRecord(rec, 'content-range')) ? 206 : -1;
}

/** 响应头值对象：status=-1 表示 headersReceive 跳点的原始条目（status 尚未到手）；
 * status=0 仅 abort 中断路径返回（非合法 HTTP 码，调用方经代际守卫丢弃）。
 * errCode（U2.1/D13 新增）：传输异常原始码观测面——成功路径 0、abort 路径 0（主动中断非传输错误）、
 * open() catch 路径填 BusinessError.code（2300028 超时/2300007 拒连等；U1.2 只回 status=0 丢失该码，
 * worker 结果 connectPhase 诊断与 P2-U1 探针需要它）。接口字段追加向后兼容（既有读取点只摸 status/header）。 */
export interface HttpResponseHead {
  status: number;
  header: Record<string, string>;
  errCode: number;
}

function makeEmptyHeader(): Record<string, string> {
  const empty: Record<string, string> = {};
  return empty;
}

export class HttpClient {
  private readonly req: http.HttpRequest = http.createHttp();
  private readonly timeoutMs: number;
  private readonly proxy: TransportProxy | undefined;
  /** abort 门：abort() resolve——open/waitStreamEnd 与其 race，保证 abort 后挂起协程必然放行 */
  private readonly abortGate: Promise<void>;
  private abortResolve: (() => void) | undefined = undefined;
  /** dataEnd 门：resolve(true)=dataEnd；resolve(false)=空闲超时或 abort（open 时重建，分块重置计时） */
  private endGate: Promise<boolean> | undefined = undefined;
  private endResolve: ((value: boolean) => void) | undefined = undefined;
  private streamSettled: boolean = false;
  private requestTimedOut: boolean = false;
  /** Status acquisition has its own deadline: dataEnd must not remove this protection.
   * 末跳响应头到达即撤销（此后由空闲计时承载；真机 status 直到整条流结束才 resolve）。 */
  private headTimerId: number = -1;
  /** open 以头推断 206 先行返回（终态码尚未到手，requestInStream 结算时核对） */
  private provisional: boolean = false;
  /** 空闲计时器句柄：dataReceive 每块重置；-1=未武装 */
  private endTimerId: number = -1;
  /** headersReceive 逐次 append（S2 重定向跳点观测载体；末条为最终头时由 open 的返回值承载 status） */
  private headsReceived: HttpResponseHead[] = [];
  /** 分块回调：调用方 open 前挂；abort 后内部守卫静默丢弃 */
  onChunk: ((chunk: ArrayBuffer) => void) | undefined = undefined;
  private aborted: boolean = false;
  /** 生成代：abort() 自增；调用方持有旧代号即可识别 abort 前的异步续体 */
  private generation: number = 0;

  constructor(timeoutMs?: number, proxy?: TransportProxy) {
    this.proxy = proxy;
    this.timeoutMs = timeoutMs !== undefined
      ? timeoutMs
      : Config.getInstance().getNetworkTimeout() * 1000;
    const gate: Promise<void> = new Promise<void>((resolve: () => void) => {
      this.abortResolve = resolve;
    });
    this.abortGate = gate;
  }

  /** 打开请求（含头与超时配置）：resolve 值=最终 status（栈自动跟随重定向）；
   * head 从 headsReceived 末条取（headersReceive 先于 resolve）；headsReceived 空（异常路径）
   * → 空 Record 兜底（getHeadsReceived 长度可作诊断，不抛错）。传输异常（DNS/拒连/2300028 超时）
   * 吞掉记日志回传 status=0（重试分类由调用方判，等价 DotNetHttpClient.Send 吞 HttpRequestException 的
   * 观测面——语义拍板 §0-1：状态已到手且非 200/206 的 InvalidResponse 终态在引擎层判）。 */
  async open(url: string, header: Record<string, string>): Promise<HttpResponseHead> {
    this.headsReceived = [];
    this.provisional = false;
    this.buildEndGate();
    this.headTimerId = setTimeout((): void => {
      this.headTimerId = -1;
      this.requestTimedOut = true;
      this.abort();
    }, this.timeoutMs);
    const options: http.HttpRequestOptions = {
      header: header,
      usingCache: false,
      usingProxy: usingProxyOf(this.proxy),
      connectTimeout: this.timeoutMs,
      readTimeout: STREAM_TRANSFER_CAP_MS
    };
    let earlyResolve: ((value: number) => void) | undefined = undefined;
    const early: Promise<number> = new Promise<number>((resolve: (value: number) => void) => {
      earlyResolve = resolve;
    });
    this.req.on('headersReceive', (headerObj: Object) => {
      if (this.aborted) {
        return;
      }
      const rec: Record<string, string> = headerObj as Record<string, string>;
      const head: HttpResponseHead = { status: -1, header: rec, errCode: 0 };
      this.headsReceived.push(head);
      if (headerValueOfRecord(rec, 'location') !== '') {
        return;
      }
      // 末跳头已到：连接建立，状态时限让位于空闲计时（长流不受 timeoutMs 总时长切断）
      this.clearHeadTimer();
      const resolve = earlyResolve;
      if (resolve !== undefined && provisionalStatusOf(rec) === 206) {
        earlyResolve = undefined;
        this.provisional = true;
        resolve(206);
      }
    });
    this.req.on('dataReceive', (data: ArrayBuffer) => {
      // 守卫：abort 后旧续体静默丢弃（禁挂起防御三件套之代际纪律）
      if (this.aborted || this.streamSettled) {
        return;
      }
      const chunk = this.onChunk;
      if (chunk !== undefined) {
        chunk(data);
      }
      this.armIdleTimer();
    });
    this.req.on('dataEnd', () => {
      this.resolveEnd(true);
    });
    let status: number = 0;
    let lastErrCode: number = 0;
    try {
      const statusPromise: Promise<number> = this.req.requestInStream(url, options);
      // 头推断 206 先行返回后，终态码仍须核对：不一致或流中途传输失败 → 断流，流门 false（调用方续传重派）
      statusPromise.then((final: number): void => {
        if (this.provisional && !this.aborted && final !== 206) {
          hilog.error(0x0000, 'HttpClient', '%{public}s', 'provisional 206 contradicted final=' + String(final));
          this.abort();
        }
      }, (e: BusinessError): void => {
        if (this.provisional && !this.aborted) {
          hilog.error(0x0000, 'HttpClient', '%{public}s', 'stream failed after head errCode=' + String(e.code));
          this.abort();
        }
      });
      const raced: number = await Promise.race([statusPromise, early, this.abortGateNum()]);
      status = raced;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, 'HttpClient', '%{public}s',
        'open failed url=' + url + ' errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
      status = 0;
      lastErrCode = err.code;
      this.resolveEnd(false);
    } finally {
      this.clearHeadTimer();
    }
    if (this.aborted) {
      const abortedHead: HttpResponseHead = {
        status: 0, header: makeEmptyHeader(), errCode: this.requestTimedOut ? 2300028 : 0
      };
      return abortedHead;
    }
    const heads: HttpResponseHead[] = this.headsReceived;
    if (heads.length > 0) {
      const last: HttpResponseHead = heads[heads.length - 1];
      const head: HttpResponseHead = { status: status, header: last.header, errCode: lastErrCode };
      return head;
    }
    const fallback: HttpResponseHead = { status: status, header: makeEmptyHeader(), errCode: lastErrCode };
    return fallback;
  }

  /** 等待流结束：true=dataEnd 正常；false=15s 硬顶（断流挂起防御）或 abort。 */
  async waitStreamEnd(): Promise<boolean> {
    const gate: Promise<boolean> | undefined = this.endGate;
    if (gate === undefined) {
      return false;
    }
    const result: boolean = await gate;
    return result;
  }

  /** headersReceive 观测载体（S2 重定向跳点观测；含最终头之外的每个跳点条目） */
  getHeadsReceived(): HttpResponseHead[] {
    return this.headsReceived;
  }

  /** 生成代读取：abort 前捕获、续体恢复后比对，不一致即旧代静默丢弃 */
  getGeneration(): number {
    return this.generation;
  }

  /** 立即断流（等价 PieceGrabber.cs:146 request.Abort）：off 全部事件 → destroy → abort 门放行 →
   * 生成代自增。此后 dataReceive/headersReceive 回调过 aborted 守卫静默丢弃。 */
  abort(): void {
    if (this.aborted) {
      return;
    }
    this.aborted = true;
    this.generation++;
    this.clearHeadTimer();
    this.resolveEnd(false);
    try {
      this.req.off('dataReceive');
      this.req.off('dataEnd');
      this.req.off('headersReceive');
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, 'HttpClient', '%{public}s',
        'off failed errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
    }
    try {
      this.req.destroy();
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, 'HttpClient', '%{public}s',
        'destroy failed errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
    }
    const resolve = this.abortResolve;
    if (resolve !== undefined) {
      resolve();
    }
  }

  /** dataEnd 门构造：race[dataEnd→true, 空闲超时→false, abort→false]（挂起防御三件套之二）。
   * 空闲超时=自本次 dataReceive 起 15s 无新分块才触发，长下载不被总时长硬顶切断。 */
  private buildEndGate(): void {
    this.streamSettled = false;
    const dataEndPromise: Promise<boolean> = new Promise<boolean>((resolve: (value: boolean) => void) => {
      this.endResolve = resolve;
    });
    const abortFalse: Promise<boolean> = this.abortGate.then((): boolean => false);
    this.endGate = Promise.race([dataEndPromise, abortFalse]);
    this.armIdleTimer();
  }

  /** （重）武装空闲计时器：每次 dataReceive 调用；resolve 后再触发为无害空操作 */
  private armIdleTimer(): void {
    if (this.streamSettled || this.aborted) {
      return;
    }
    if (this.endTimerId >= 0) {
      clearTimeout(this.endTimerId);
    }
    this.endTimerId = setTimeout((): void => {
      this.endTimerId = -1;
      // Idle expiry must also release open(): requestInStream may still be pending.
      // abort destroys the transport and settles both gates; distinguish this from user cancellation.
      this.requestTimedOut = true;
      this.abort();
    }, END_GATE_TIMEOUT_MS);
  }

  private resolveEnd(value: boolean): void {
    this.streamSettled = true;
    if (this.endTimerId >= 0) {
      clearTimeout(this.endTimerId);
      this.endTimerId = -1;
    }
    const resolve = this.endResolve;
    if (resolve !== undefined) {
      resolve(value);
      this.endResolve = undefined;
    }
  }

  private clearHeadTimer(): void {
    if (this.headTimerId >= 0) {
      clearTimeout(this.headTimerId);
      this.headTimerId = -1;
    }
  }

  /** abortGate 的 number 投影：requestInStream race 对手盘（abort 胜出 → -1） */
  private abortGateNum(): Promise<number> {
    return this.abortGate.then((): number => -1);
  }
}
