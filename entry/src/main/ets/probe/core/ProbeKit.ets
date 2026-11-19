/*
 * U0.1 探针基建：探针标记工具（唯一 [XDM_PROBE] 日志出口）。
 * 契约见 docs/PROBE_SPEC.md §2：
 *   行格式 [XDM_PROBE][<单元ID>][<步骤号>] key=value ...
 *   保留步骤 BEGIN / SUMMARY / END；单行 <1500 字节；值只写观测事实，不写 PASS/FAIL 判定。
 * hilog: domain 0xD001、tag 'XDM_PROBE'、强制 %{public}s 防 private 脱敏。
 * 兜底：每次标记行变更即全量重写 <filesDir>/probe-latest.txt（中途 jscrash 也留痕）。
 * U0.2 增补（IR-F5/COLD-F5）：isCurrent(sessionToken) 会话代际守卫——旧会话异步续体在 await 恢复后
 *   先过此守卫，不一致即静默中止，防止暖启动重建页面后旧异步循环污染新会话；
 *   IR-F4：emit 空 kvs / end 零 summaries 时补 kvs=0，保证"每步骤恰一行"格式合法；
 *   IR-F2：删除零读取点的 lastLine 死代码。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';

/** 探针日志域（合法域 0x0~0xFFFF） */
export const PROBE_DOMAIN: number = 0xD001;
/** 探针标记 grep 锚（hilog tag，≤31 字节） */
export const PROBE_TAG: string = 'XDM_PROBE';
/** 标记行字节上限（hilog 单条 4096 截断留余量；消毒后全 ASCII，length 即字节数） */
const PROBE_LINE_LIMIT: number = 1500;
/** 非标记诊断行专用 tag：不含 "XDM_PROBE" 子串，避免 verify 的 grep 抓到未配对行报 FORMAT-ERROR */
const DIAG_TAG: string = 'XdmProbeKit';

/** 步骤状态常量：UI 徽标用（只是执行事实，不进探针日志） */
export const PROBE_STATUS_PENDING: string = 'pending';
export const PROBE_STATUS_RUNNING: string = 'running';
export const PROBE_STATUS_DONE: string = 'done';
export const PROBE_STATUS_ERROR: string = 'error';

/** 值白名单 [A-Za-z0-9_.:/|= -] 与空格之外的字符（含 CJK）→ 替换为 '?'。
 * 正则字面量被 ArkTS 禁用，必须 new RegExp；'-' 必须置于字符类末位，否则成非法区间运行期 SyntaxError。 */
const VALUE_BAD: RegExp = new RegExp('[^A-Za-z0-9_.:/|= -]', 'g');
/** 单元 ID / 步骤号白名单 [A-Za-z0-9-]，违规字符删除（verify 正则的硬约束） */
const TOKEN_BAD: RegExp = new RegExp('[^A-Za-z0-9-]', 'g');

/** 有序键值对。不用 Record：SUMMARY 聚合依赖插入序且 ArkTS 禁 for...in，数组最直白。 */
export class KeyValue {
  key: string = '';
  value: string = '';

  constructor(key: string, value: string) {
    this.key = key;
    this.value = value;
  }
}

/** 探针会话状态机 idle→running→ended 的单例工具。
 * 单例理由：一屏同时只有一个探针会话，且 ProbePage（编排）与各 units（步骤实现）需共享同一会话。 */
export class ProbeKit {
  private static instance: ProbeKit | undefined = undefined;

  private unitId: string = '';
  private runId: string = '';
  private sessionPrefix: string = util.generateRandomUUID();
  private sessionSequence: number = 0;
  private sessionToken: string = '';
  private started: boolean = false;
  private startTick: number = 0;
  private stepCount: number = 0;
  private lines: string[] = [];
  private summaries: string[] = [];
  private filesDir: string = '';

  private constructor() {
  }

  static getInstance(): ProbeKit {
    if (ProbeKit.instance === undefined) {
      ProbeKit.instance = new ProbeKit();
    }
    return ProbeKit.instance;
  }

  /** 开启会话：重置状态、生成 runId、发 BEGIN 行。begin 后未 end 又 begin 视为新一轮（重跑语义）。 */
  begin(unitId: string, filesDir: string): string {
    this.lines = [];
    this.summaries = [];
    this.stepCount = 0;
    this.started = true;
    this.unitId = this.sanitizeToken(unitId);
    this.filesDir = filesDir;
    this.runId = this.fmtClock();
    if (this.sessionSequence >= Number.MAX_SAFE_INTEGER) {
      this.sessionPrefix = util.generateRandomUUID();
      this.sessionSequence = 0;
    }
    this.sessionSequence++;
    this.sessionToken = this.sessionPrefix + '-' + String(this.sessionSequence);
    this.startTick = Date.now();
    const line: string = '[XDM_PROBE][' + this.unitId + '][BEGIN] runId=' + this.runId +
      ' filesDir=' + this.sanitizeValue(filesDir);
    this.appendMarkerLine(line);
    return line;
  }

  /** 输出一个步骤标记行（每步骤恰好一行）：hilog 单行 + 记录 SUMMARY 段 + 重写兜底文件。
   * 未 begin 就 emit：忽略该行并走普通 hilog（不产出畸标记行）。 */
  emit(stepNo: string, kvs: KeyValue[]): string {
    if (!this.started) {
      hilog.info(PROBE_DOMAIN, DIAG_TAG, '%{public}s', 'probe emit ignored: session not started, stepNo=' + stepNo);
      return '';
    }
    const step: string = this.sanitizeToken(stepNo);
    const pairs: string[] = [];
    // IR-F4：空 kvs 补 kvs=0——verify 正则要求步骤行有非空负载，且 SUMMARY 段可留关键值
    const effectiveKvs: KeyValue[] = kvs.length > 0 ? kvs : [new KeyValue('kvs', '0')];
    for (let i = 0; i < effectiveKvs.length; i++) {
      pairs.push(effectiveKvs[i].key + '=' + this.sanitizeValue(effectiveKvs[i].value));
    }
    let line: string = '[XDM_PROBE][' + this.unitId + '][' + step + '] ' + pairs.join(' ');
    if (line.length >= PROBE_LINE_LIMIT) {
      line = line.slice(0, PROBE_LINE_LIMIT - 1);
    }
    // SUMMARY 段：S<no>=k=v,k=v；段内 '|' 替换为 '/'（'|' 是 SUMMARY 段间分隔符）
    this.summaries.push((step + '=' + pairs.join(',')).split('|').join('/'));
    this.stepCount++;
    this.appendMarkerLine(line);
    return line;
  }

  /** 结束会话：SUMMARY 聚合行（1500B 两级降级：①每段只留首个 kv ②硬截断）→ END 行。
   * IR-F4：零 summaries 时 SUMMARY 段补 kvs=0，保证聚合行负载非空。 */
  end(ok: boolean): string {
    if (!this.started) {
      hilog.info(PROBE_DOMAIN, DIAG_TAG, '%{public}s', 'probe end ignored: session not started');
      return '';
    }
    const segments: string[] = this.summaries.length > 0 ? this.summaries : ['kvs=0'];
    let summaryLine: string = '[XDM_PROBE][' + this.unitId + '][SUMMARY] ' + segments.join('|');
    if (summaryLine.length >= PROBE_LINE_LIMIT) {
      const firstPairs: string[] = [];
      for (let i = 0; i < segments.length; i++) {
        firstPairs.push(this.firstKvOfSegment(segments[i]));
      }
      summaryLine = '[XDM_PROBE][' + this.unitId + '][SUMMARY] ' + firstPairs.join('|');
    }
    if (summaryLine.length >= PROBE_LINE_LIMIT) {
      summaryLine = summaryLine.slice(0, PROBE_LINE_LIMIT - 1);
    }
    this.appendMarkerLine(summaryLine);
    const elapsedMs: number = Date.now() - this.startTick;
    const endLine: string = '[XDM_PROBE][' + this.unitId + '][END] ok=' + String(ok) +
      ' steps=' + String(this.stepCount) + ' elapsedMs=' + String(elapsedMs);
    this.appendMarkerLine(endLine);
    this.started = false;
    return endLine;
  }

  /** 日志显示编号；HHmmss 可以重复，不能用作异步守卫或缓存键。 */
  getRunId(): string {
    return this.runId;
  }

  /** 内部身份跨同秒重跑、时钟回退和页面重建保持独立；end 后保留供复制回调核对。 */
  getSessionToken(): string {
    return this.sessionToken;
  }

  /** 会话代际守卫（IR-F5/COLD-F5）：token 与当前会话一致且会话进行中才为 true。
   * ProbePage/各 units 的异步续体在每个 await 恢复后、emit/end 前先过此守卫；
   * 返回 false 即旧会话已被新一轮 begin 作废，调用方应静默 return（不发标记行、不调 end、不写状态）。 */
  isCurrent(token: string): boolean {
    return this.started && token.length > 0 && this.sessionToken === token;
  }

  /** 页面退出仅作废自己拥有的运行会话；缺 END 如实保留，不能伪造成功。 */
  cancelSession(token: string): void {
    if (this.isCurrent(token)) {
      this.started = false;
    }
  }

  /** 返回本次运行全部标记行拷贝，供 UI 回显 */
  getLines(): string[] {
    return this.lines.slice();
  }

  /** SUMMARY 段只保留首个 kv：'S1=a=1,b=2' → 'S1=a=1' */
  private firstKvOfSegment(segment: string): string {
    const eq: number = segment.indexOf('=');
    if (eq < 0) {
      return segment;
    }
    const head: string = segment.slice(0, eq + 1);
    const rest: string = segment.slice(eq + 1);
    const comma: number = rest.indexOf(',');
    if (comma >= 0) {
      return head + rest.slice(0, comma);
    }
    return head + rest;
  }

  private appendMarkerLine(line: string): void {
    this.lines.push(line);
    hilog.info(PROBE_DOMAIN, PROBE_TAG, '%{public}s', line);
    this.writeFallbackFile();
  }

  /** 兜底文件恒为 <filesDir>/probe-latest.txt（PROBE_SPEC 契约，不得改名）；每次标记行变更全量重写。 */
  private writeFallbackFile(): void {
    if (this.filesDir === '') {
      return;
    }
    try {
      const path: string = this.filesDir + '/probe-latest.txt';
      const file = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, this.lines.join('\n') + '\n');
      } finally {
        fileIo.closeSync(file);
      }
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(PROBE_DOMAIN, DIAG_TAG, '%{public}s',
        'probe fallback write failed errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
    }
  }

  /** HHmmss（本地时钟），仅用于日志显示；异步身份由独立 sessionToken 提供。 */
  private fmtClock(): string {
    const now: Date = new Date();
    const h: string = String(now.getHours()).padStart(2, '0');
    const m: string = String(now.getMinutes()).padStart(2, '0');
    const s: string = String(now.getSeconds()).padStart(2, '0');
    return h + m + s;
  }

  private sanitizeValue(v: string): string {
    return v.replace(VALUE_BAD, '?');
  }

  private sanitizeToken(t: string): string {
    return t.replace(TOKEN_BAD, '');
  }
}
