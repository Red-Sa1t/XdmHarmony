/*
 * U0.2 探针单元：P0-U2 HTTP 能力探针（设计书 §6 步骤表）。
 * S1 流式落盘（requestInStream + dataReceive 计数/writeSync + dataEnd 门 + 响应头 detail 文件）
 * S2 Range 0- → 206 判定 ｜ S3 Accept-Encoding: identity 回显 ｜ S4 TaskPool 内 8 并发（风险#4 观测本体）
 * S5 重定向跟随 + Cookie 注入（finalUrl 取 /final 服务端回显——http 的 HttpResponse 无最终 URL 字段，
 *   等价观测原版 FinalUri=redirectUri??ResponseUri，PieceGrabber.cs:442-452）
 * S6 超时控制与错误码（3000ms 短超时，与产品 30s 同一参数位 connectTimeout/readTimeout；产品值由 U1.2 固化）
 * 会话代际守卫：每个 runner 入口捕获 runId，每个 await 之后、emit 之前复检 isCurrent，
 *   不一致静默 return（不发标记行、不调 end、不写状态）——防止暖启动重建页面后旧异步步骤串入新会话。
 * 红线：所有布尔键（streamClosed/rangeSupported/contentLengthMatches/all206/redirectFollowed/cookieSent/timedOut）
 *   是对直接观测值的谓词映射（服务端行为/平台返回码），不含通过/失败判定词；期望值只存在于 EXPECT 表。
 * autoStart=false + TextInput：模拟器/真机内不能用 127.0.0.1 访问主机，测试源 URL 必须可替换（手册可替换参数）。
 * 有意差异：探针不注入六键默认头全集（SingleSourceHTTPDownloader.cs:519-530），各步只注入当步观测最小头
 *   （S2 仅 Range、S3 仅 identity、S5 仅 Cookie）做单变量观察隔离；六键逐键复刻留给 U1.2 HttpClient.ets。
 */

import { http } from '@kit.NetworkKit';
import { taskpool } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ProbeKit, KeyValue } from '../core/ProbeKit';
import { ProbePage, ProbeStepDef } from '../core/ProbePage';
import {
  BIG_BIN_BYTES,
  PROBE_TIMEOUT_MS,
  UNREACHABLE_URL,
  ECHO_COOKIE,
  RangeWindow,
  ContentRangeParts,
  EchoFields,
  SegmentResult,
  headerOf,
  parseContentRange,
  splitRangeWindows,
  parseEchoBody,
  isTimeoutCode
} from './ProbeHttpLogic';

/** 测试源缺省地址（手册"可替换参数"的占位值；真机/模拟器一律填主机局域网 IP，禁 127.0.0.1） */
const DEFAULT_BASE_URL: string = 'http://127.0.0.1:8081';
/** S4 分窗数：对齐引擎 MaxSegments=8（Config.cs:122），每窗 524288B */
const SEGMENT_COUNT: number = 8;
/** S1 落盘文件名（设计书 §2.1：保留作证据，探针不自动清理） */
const S1_BIN_NAME: string = 'probe-http-s1.bin';

/** S4 步骤定义表（autoRun 全 true；会话由 ProbePage 编排，用户改完 URL 后点"运行全部"） */
const HTTP_STEPS: ProbeStepDef[] = [
  { stepNo: 'S1', title: '流式落盘（requestInStream）', autoRun: true },
  { stepNo: 'S2', title: 'Range 0- → 206 判定', autoRun: true },
  { stepNo: 'S3', title: 'identity 编码回显', autoRun: true },
  { stepNo: 'S4', title: 'TaskPool 内 8 并发', autoRun: true },
  { stepNo: 'S5', title: '重定向跟随 + Cookie 注入', autoRun: true },
  { stepNo: 'S6', title: '超时控制与错误码', autoRun: true }
];

/** dataEnd 门控硬顶：SDK d.ts 不保证断流时 dataEnd 触发，超时放行防会话挂起（独立复核 medium 修复） */
const END_GATE_TIMEOUT_MS = 15000;

/** S4 单分段抓取（TaskPool worker 侧执行）。
 * 模块级 @Concurrent：参数全传值、禁闭包捕获外部对象；http/JSON/BusinessError 均来自模块 import 或全局，
 * worker 侧 http 可用性本身就是风险#4 的观测本体（失败走 errCode 观测，不做返修）。
 * worker 内禁调 ProbeKit/hilog 探针出口（单例不可跨线程共享）——结果以 JSON 字符串返回主线程统一 emit。 */
@Concurrent
async function fetchSegment(index: number, url: string, start: number, end: number): Promise<string> {
  let status: number = 0;
  let bytes: number = 0;
  let errCode: number = 0;
  const beginTick: number = Date.now();
  const client: http.HttpRequest = http.createHttp();
  try {
    // dataEnd 门：requestInStream 的 Promise resolve 时点相对 dataEnd 无明文（防御式双等，设计书 §3.2）
    const endGate: Promise<void> = new Promise<void>((resolve: () => void) => {
      client.on('dataEnd', () => {
        resolve();
      });
    });
    client.on('dataReceive', (data: ArrayBuffer) => {
      bytes += data.byteLength;
    });
    const rangeHeader: Record<string, string> = {};
    rangeHeader['Range'] = 'bytes=' + start + '-' + end;
    // 分段超时 10000ms 内联字面量：@Concurrent 禁闭包捕获，worker 内不可引用模块常量（设计书 §3.3 同值）
    const options: http.HttpRequestOptions = { header: rangeHeader, connectTimeout: 10000, readTimeout: 10000 };
    status = await client.requestInStream(url, options);
    // dataEnd 无触发保证（断流/RST）：15s 硬顶放行，streamClosed 语义不变；Worker 若无定时器则由 catch 的读超时兜底
    await Promise.race([endGate, new Promise<void>((resolve: () => void) => setTimeout(resolve, 15000))]);
  } catch (e) {
    const err = e as BusinessError;
    errCode = err.code;
  } finally {
    client.off('dataReceive');
    client.off('dataEnd');
    client.destroy();
  }
  const result: SegmentResult = {
    index: index,
    status: status,
    bytes: bytes,
    durationMs: Date.now() - beginTick,
    errCode: errCode
  };
  return JSON.stringify(result);
}

@Component
export struct ProbeHttp {
  @State baseUrl: string = DEFAULT_BASE_URL;
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
    if (stepNo === 'S5') {
      await this.runS5();
      return;
    }
    if (stepNo === 'S6') {
      await this.runS6();
      return;
    }
  }

  /** S1 流式落盘：dataReceive 回调内只计数/writeSync（不做 emit）；await requestInStream 后再 await
   * dataEnd 门控 Promise 才 emit streamClosed（防御式双等）；finally off×3 + closeSync + destroy（官方防泄漏）。 */
  private async runS1(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    const url: string = this.joinBase('/big.bin');
    const filesDir: string = this.resolveFilesDir();
    const detailFileName: string = 'probe-P0-U2-' + runId + '-s1-headers.txt';
    let fd: number = -1;
    let chunks: number = 0;
    let totalBytes: number = 0;
    let firstChunkBytes: number = -1;
    let writtenBytes: number = 0;
    let streamClosed: boolean = false;
    let detailFile: string = '';
    const client: http.HttpRequest = http.createHttp();
    try {
      const binFile = fileIo.openSync(filesDir + '/' + S1_BIN_NAME,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fd = binFile.fd;
      const endGate: Promise<void> = new Promise<void>((resolve: () => void) => {
        client.on('dataEnd', () => {
          streamClosed = true;
          resolve();
        });
      });
      client.on('dataReceive', (data: ArrayBuffer) => {
        chunks++;
        if (firstChunkBytes < 0) {
          firstChunkBytes = data.byteLength;
        }
        totalBytes += data.byteLength;
        if (fd >= 0) {
          writtenBytes += fileIo.writeSync(fd, data);
        }
      });
      client.on('headersReceive', (header: Object) => {
        // 大段响应头不进 hilog：写 detail 文件（PROBE_SPEC §2），标记行只记 detailFile=文件名
        if (!this.probeKit.isCurrent(runId)) {
          return;
        }
        try {
          const headFile = fileIo.openSync(filesDir + '/' + detailFileName,
            fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
          try {
            fileIo.writeSync(headFile.fd, JSON.stringify(header));
          } finally {
            fileIo.closeSync(headFile);
          }
          detailFile = detailFileName;
        } catch (e) {
          detailFile = '';
        }
      });
      const status: number = await client.requestInStream(url);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      // dataEnd 无触发保证（断流/RST 时头已到体未完）：超时兜底放行，streamClosed 保持 false 观测
      await Promise.race([endGate, new Promise<void>((resolve: () => void) => setTimeout(resolve, END_GATE_TIMEOUT_MS))]);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const kvs: KeyValue[] = [
        new KeyValue('url', url),
        new KeyValue('status', String(status)),
        new KeyValue('chunks', String(chunks)),
        new KeyValue('totalBytes', String(totalBytes)),
        new KeyValue('firstChunkBytes', String(firstChunkBytes)),
        new KeyValue('writtenBytes', String(writtenBytes)),
        new KeyValue('streamClosed', String(streamClosed)),
        new KeyValue('detailFile', detailFile)
      ];
      this.probeKit.emit('S1', kvs);
    } catch (e) {
      const err = e as BusinessError;
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const errKvs: KeyValue[] = [
        new KeyValue('url', url),
        new KeyValue('chunks', String(chunks)),
        new KeyValue('totalBytes', String(totalBytes)),
        new KeyValue('streamClosed', String(streamClosed)),
        new KeyValue('errCode', String(err.code)),
        new KeyValue('errMessage', err.message ?? '')
      ];
      this.probeKit.emit('S1', errKvs);
    } finally {
      client.off('dataReceive');
      client.off('dataEnd');
      client.off('headersReceive');
      if (fd >= 0) {
        fileIo.closeSync(fd);
        fd = -1;
      }
      client.destroy();
    }
  }

  /** S2 Range 0- → 206：单调用取码+头（4MiB 体随请求回收，不逐块处理）。
   * contentLength 取值链 Content-Length → ContentRange total → -1（对齐 DotNetHttpSession.cs:32）。 */
  private async runS2(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    const url: string = this.joinBase('/big.bin');
    const rangeHeader: Record<string, string> = {};
    rangeHeader['Range'] = 'bytes=0-';
    const options: http.HttpRequestOptions = { header: rangeHeader };
    const client: http.HttpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await client.request(url, options);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const headers: Record<string, string> = resp.header as Record<string, string>;
      const parts: ContentRangeParts = parseContentRange(headerOf(headers, 'content-range'));
      let contentLength: string = headerOf(headers, 'content-length');
      if (contentLength.length === 0) {
        contentLength = parts.total >= 0 ? String(parts.total) : '-1';
      }
      // rangeSupported = status==206 的谓词编码（http.ResponseCode.PARTIAL，d.ts:2881）——服务端能力观测
      const rangeSupported: boolean = resp.responseCode === http.ResponseCode.PARTIAL;
      const kvs: KeyValue[] = [
        new KeyValue('url', url),
        new KeyValue('requestRange', 'bytes=0-'),
        new KeyValue('status', String(resp.responseCode)),
        new KeyValue('contentLength', contentLength),
        new KeyValue('contentRangeTotal', parts.total >= 0 ? String(parts.total) : '-1'),
        new KeyValue('rangeSupported', String(rangeSupported))
      ];
      this.probeKit.emit('S2', kvs);
    } catch (e) {
      const err = e as BusinessError;
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const errKvs: KeyValue[] = [
        new KeyValue('url', url),
        new KeyValue('errCode', String(err.code)),
        new KeyValue('errMessage', err.message ?? '')
      ];
      this.probeKit.emit('S2', errKvs);
    } finally {
      client.destroy();
    }
  }

  /** S3 identity 回显：显式 Accept-Encoding: identity 关闭压缩协商（对等决策 3，
   * 对应 AutomaticDecompression=All 无对应物的反向验证，DotNetHttpClient.cs:50-57）。 */
  private async runS3(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    const url: string = this.joinBase('/echo');
    const acceptHeader: Record<string, string> = {};
    acceptHeader['Accept-Encoding'] = 'identity';
    const options: http.HttpRequestOptions = { header: acceptHeader };
    const client: http.HttpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await client.request(url, options);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const body: string = resp.result as string;
      const fields: EchoFields = parseEchoBody(body);
      const headers: Record<string, string> = resp.header as Record<string, string>;
      const serverContentLength: string = headerOf(headers, 'content-length');
      const contentLengthMatches: boolean = Number(serverContentLength) === body.length;
      const serverEcho: string = fields.acceptEncoding.length > 0 ? fields.acceptEncoding : 'absent';
      const kvs: KeyValue[] = [
        new KeyValue('sent', 'identity'),
        new KeyValue('serverEcho', serverEcho),
        new KeyValue('contentLengthMatches', String(contentLengthMatches))
      ];
      this.probeKit.emit('S3', kvs);
    } catch (e) {
      const err = e as BusinessError;
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const errKvs: KeyValue[] = [
        new KeyValue('url', url),
        new KeyValue('errCode', String(err.code)),
        new KeyValue('errMessage', err.message ?? '')
      ];
      this.probeKit.emit('S3', errKvs);
    } finally {
      client.destroy();
    }
  }

  /** S4 TaskPool 内 8 并发：分窗 → 8 个 execute → Promise.all 聚合 → emit 前复检会话守卫。
   * worker 内 http 不可用（风险#4 实证）时聚合走 all206=false/firstErrCode 观测，非 probe-code 返修。 */
  private async runS4(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    const url: string = this.joinBase('/big.bin');
    const windows: RangeWindow[] = splitRangeWindows(BIG_BIN_BYTES, SEGMENT_COUNT);
    try {
      const pending: Promise<Object>[] = [];
      for (let i = 0; i < windows.length; i++) {
        const w: RangeWindow = windows[i];
        pending.push(taskpool.execute(fetchSegment, i, url, w.start, w.end));
      }
      const outputs: Object[] = await Promise.all(pending);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      let all206: boolean = true;
      let minDurationMs: number = -1;
      let maxDurationMs: number = -1;
      let totalBytes: number = 0;
      let firstErrCode: number = 0;
      for (let i = 0; i < outputs.length; i++) {
        const text: string = outputs[i] as string;
        const seg: SegmentResult = JSON.parse(text) as SegmentResult;
        if (seg.status !== 206) {
          all206 = false;
        }
        if (minDurationMs < 0 || seg.durationMs < minDurationMs) {
          minDurationMs = seg.durationMs;
        }
        if (seg.durationMs > maxDurationMs) {
          maxDurationMs = seg.durationMs;
        }
        totalBytes += seg.bytes;
        if (seg.errCode !== 0 && firstErrCode === 0) {
          firstErrCode = seg.errCode;
        }
      }
      const kvs: KeyValue[] = [
        new KeyValue('concurrent', String(windows.length)),
        new KeyValue('all206', String(all206)),
        new KeyValue('minDurationMs', String(minDurationMs)),
        new KeyValue('maxDurationMs', String(maxDurationMs)),
        new KeyValue('totalBytes', String(totalBytes)),
        new KeyValue('firstErrCode', String(firstErrCode))
      ];
      this.probeKit.emit('S4', kvs);
    } catch (e) {
      const err = e as BusinessError;
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const errKvs: KeyValue[] = [
        new KeyValue('concurrent', String(windows.length)),
        new KeyValue('errCode', String(err.code)),
        new KeyValue('errMessage', err.message ?? '')
      ];
      this.probeKit.emit('S4', errKvs);
    }
  }

  /** S5 重定向跟随 + Cookie 注入：302 绝对 Location → /final 回显实收 URL/Cookie；
   * redirectFollowed/cookieSent 是对回显值的谓词编码。仅同主机 302（官方明示手动 Cookie 不跨主机转发，
   * 本机 d.ts 无 enableAutoCookie，grep 计数 0，起始版本 26>24）——跨主机留 U1.2 公网实测。 */
  private async runS5(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    const url: string = this.joinBase('/redirect');
    const cookieHeader: Record<string, string> = {};
    cookieHeader['Cookie'] = ECHO_COOKIE;
    const options: http.HttpRequestOptions = { header: cookieHeader };
    const client: http.HttpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await client.request(url, options);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const body: string = resp.result as string;
      const fields: EchoFields = parseEchoBody(body);
      const redirectFollowed: boolean = fields.url.endsWith('/final');
      const cookieSent: boolean = fields.cookie.indexOf(ECHO_COOKIE) >= 0;
      const finalUrl: string = fields.url.length > 0 ? fields.url : 'absent';
      const cookieSeen: string = fields.cookie.length > 0 ? fields.cookie : 'absent';
      const kvs: KeyValue[] = [
        new KeyValue('requestUrl', url),
        new KeyValue('status', String(resp.responseCode)),
        new KeyValue('redirectFollowed', String(redirectFollowed)),
        new KeyValue('finalUrl', finalUrl),
        new KeyValue('cookieSeen', cookieSeen),
        new KeyValue('cookieSent', String(cookieSent))
      ];
      this.probeKit.emit('S5', kvs);
    } catch (e) {
      const err = e as BusinessError;
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const errKvs: KeyValue[] = [
        new KeyValue('requestUrl', url),
        new KeyValue('errCode', String(err.code)),
        new KeyValue('errMessage', err.message ?? '')
      ];
      this.probeKit.emit('S5', errKvs);
    } finally {
      client.destroy();
    }
  }

  /** S6 超时控制与错误码：RFC 5737 TEST-NET-1 不可达地址 + 3000ms 短超时。
   * 主判 2300028（静默丢包 Operation timeout，d.ts:1111）；2300007（RST/拒绝环境）记 UNVERIFIED。
   * errCode==2300028 即 timedOut 谓词（isTimeoutCode），其余键为直接观测值。 */
  private async runS6(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    const beginTick: number = Date.now();
    const timeoutOptions: http.HttpRequestOptions = {
      connectTimeout: PROBE_TIMEOUT_MS,
      readTimeout: PROBE_TIMEOUT_MS
    };
    const client: http.HttpRequest = http.createHttp();
    try {
      const status: number = await client.requestInStream(UNREACHABLE_URL, timeoutOptions);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const elapsedMs: number = Date.now() - beginTick;
      const kvs: KeyValue[] = [
        new KeyValue('timeoutSetMs', String(PROBE_TIMEOUT_MS)),
        new KeyValue('timedOut', 'false'),
        new KeyValue('errCode', '0'),
        new KeyValue('status', String(status)),
        new KeyValue('elapsedMs', String(elapsedMs))
      ];
      this.probeKit.emit('S6', kvs);
    } catch (e) {
      const err = e as BusinessError;
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const elapsedMs: number = Date.now() - beginTick;
      const errKvs: KeyValue[] = [
        new KeyValue('timeoutSetMs', String(PROBE_TIMEOUT_MS)),
        new KeyValue('timedOut', String(isTimeoutCode(err.code))),
        new KeyValue('errCode', String(err.code)),
        new KeyValue('elapsedMs', String(elapsedMs))
      ];
      this.probeKit.emit('S6', errKvs);
    } finally {
      client.destroy();
    }
  }

  /** 测试源拼接：TextInput 值去尾部斜杠 + 路由；空值回退缺省地址 */
  private joinBase(path: string): string {
    let base: string = this.baseUrl.trim();
    if (base.length === 0) {
      base = DEFAULT_BASE_URL;
    }
    while (base.length > 0 && base.charAt(base.length - 1) === '/') {
      base = base.slice(0, base.length - 1);
    }
    return base + path;
  }

  /** 组件内取 Context：禁用已弃用 getContext(this)，getHostContext 返回 Context|undefined 需窄化 */
  private resolveFilesDir(): string {
    const ctx = this.getUIContext().getHostContext();
    return ctx?.filesDir ?? '';
  }

  build() {
    Column({ space: 12 }) {
      Text($r('app.string.probe_http_source_hint'))
        .fontSize(12)
        .opacity(0.7)
        .width('100%')
      TextInput({ text: this.baseUrl, placeholder: $r('app.string.probe_http_source_hint') })
        .onChange((value: string) => {
          this.baseUrl = value;
        })
        .width('100%')
      ProbePage({
        unitId: 'P0-U2',
        pageTitle: $r('app.string.probe_http_title'),
        steps: HTTP_STEPS,
        autoStart: false,
        runStep: (stepNo: string): Promise<void> => this.runStep(stepNo)
      })
        .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .padding(16)
  }
}
