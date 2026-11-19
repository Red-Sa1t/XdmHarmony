/*
 * U0.1 探针基建：通用探针页脚手架。
 * 会话编排（设计书 §3.4）：begin → 顺序 await steps → end(ok)；
 * runner 契约：内部捕获 BusinessError 并 emit err= 观测值不外抛；ok=false 只留给脚手架级意外异常。
 * UI 状态徽标（done/error）只是执行事实，只进界面不进日志。
 * U0.2 增补（IR-F5/COLD-F5 会话代际守卫）：begin 后捕获 sessionToken，五守卫点
 *   （循环每轮开头 / await runStep 返回后 / catch emit 前 / end 前；runSingle 同构）
 *   任一点页面/会话所有权失效即静默 return——不发标记行、不调 end、不写状态，
 *   旧会话作废，新会话由新循环完整接管（BEGIN/END 配对不被旧循环打断）。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import {
  ProbeKit,
  KeyValue,
  PROBE_DOMAIN,
  PROBE_STATUS_PENDING,
  PROBE_STATUS_RUNNING,
  PROBE_STATUS_DONE,
  PROBE_STATUS_ERROR
} from './ProbeKit';

/** 探针步骤定义。共享类型在此一处声明，units/ 引用同一份。 */
export interface ProbeStepDef {
  stepNo: string;
  title: ResourceStr;
  autoRun: boolean;
}

/** 非标记诊断行 tag：不含 "XDM_PROBE" 子串，避免 verify grep 抓到未配对行 */
const DIAG_TAG: string = 'XdmProbePage';

@Component
export struct ProbePage {
  /** 探针单元 ID，如 'P0-U0' */
  unitId: string = '';
  pageTitle: ResourceStr = '';
  steps: ProbeStepDef[] = [];
  autoStart: boolean = true;
  /** 步骤 runner：内部捕获业务异常并 emit 观测值，不向外抛 */
  runStep: (stepNo: string) => Promise<void> = (stepNo: string): Promise<void> => Promise.resolve();

  @State statuses: string[] = [];
  @State logText: string = '';
  @State sessionRunning: boolean = false;
  @State hasResult: boolean = false;
  @State copied: boolean = false;
  private sessionStarted: boolean = false;
  private alive: boolean = false;
  private pageEpoch: number = 0;
  private sessionToken: string = '';
  private probeKit: ProbeKit = ProbeKit.getInstance();

  aboutToAppear(): void {
    if (this.alive) {
      return;
    }
    this.alive = true;
    this.pageEpoch++;
    this.sessionRunning = false;
    this.hasResult = false;
    this.copied = false;
    this.logText = '';
    const initial: string[] = [];
    for (let i = 0; i < this.steps.length; i++) {
      initial.push(PROBE_STATUS_PENDING);
    }
    this.statuses = initial;
    if (this.autoStart && !this.sessionStarted) {
      this.sessionStarted = true;
      this.startSession();
    }
  }

  aboutToDisappear(): void {
    const token: string = this.sessionToken;
    this.alive = false;
    this.pageEpoch++;
    this.sessionToken = '';
    this.sessionStarted = false;
    this.sessionRunning = false;
    this.probeKit.cancelSession(token);
  }

  /** 会话编排：守卫 → begin → 捕获 token/页面代际 → 顺序 await 步骤 → end → 刷新回显。 */
  async startSession(): Promise<void> {
    if (!this.alive || this.sessionRunning) {
      return;
    }
    const epoch: number = this.pageEpoch;
    this.sessionRunning = true;
    this.copied = false;
    this.hasResult = false;
    this.logText = '';
    this.resetStatuses();
    let ok: boolean = true;
    const filesDir: string = this.resolveFilesDir();
    this.probeKit.begin(this.unitId, filesDir);
    const token: string = this.probeKit.getSessionToken();
    this.sessionToken = token;
    for (let i = 0; i < this.steps.length; i++) {
      // 守卫点①：循环每轮开头——会话已被新 begin 作废则旧循环静默退出
      if (!this.isCurrentSession(epoch, token)) {
        return;
      }
      const stepNo: string = this.steps[i].stepNo;
      this.setStatus(i, PROBE_STATUS_RUNNING);
      try {
        await this.runStep(stepNo);
        // 守卫点②：await runStep 返回后
        if (!this.isCurrentSession(epoch, token)) {
          return;
        }
        this.setStatus(i, PROBE_STATUS_DONE);
      } catch (e) {
        // 守卫点③：catch 分支 emit 前——守卫失败静默退出，不写状态不发标记
        if (!this.isCurrentSession(epoch, token)) {
          return;
        }
        // runner 契约外溢出的脚手架级异常：补一行 err= 观测，保证"每步骤恰一行"，ok=false
        ok = false;
        this.setStatus(i, PROBE_STATUS_ERROR);
        const err = e as BusinessError;
        const errKvs: KeyValue[] = [
          new KeyValue('errCode', String(err.code)),
          new KeyValue('errMessage', err.message ?? '')
        ];
        this.probeKit.emit(stepNo, errKvs);
      }
    }
    // 守卫点④：end 前——旧循环不得产生孤儿 END
    if (!this.isCurrentSession(epoch, token)) {
      return;
    }
    this.probeKit.end(ok);
    this.refreshLog();
    this.sessionRunning = false;
    this.hasResult = true;
  }

  /** 单步迷你会话（begin → 该步 → end），供 autoRun=false 步骤的"执行"按钮；U0.1 预留。
   * 守卫点⑤：与 startSession 同构（begin 后 / await 后 / catch emit 前 / end 前）。 */
  async runSingle(stepNo: string): Promise<void> {
    if (!this.alive || this.sessionRunning) {
      return;
    }
    const epoch: number = this.pageEpoch;
    this.sessionRunning = true;
    this.copied = false;
    this.hasResult = false;
    this.logText = '';
    let ok: boolean = true;
    const filesDir: string = this.resolveFilesDir();
    this.probeKit.begin(this.unitId, filesDir);
    const token: string = this.probeKit.getSessionToken();
    this.sessionToken = token;
    const index: number = this.indexOfStep(stepNo);
    if (!this.isCurrentSession(epoch, token)) {
      return;
    }
    if (index >= 0) {
      this.setStatus(index, PROBE_STATUS_RUNNING);
    }
    try {
      await this.runStep(stepNo);
      if (!this.isCurrentSession(epoch, token)) {
        return;
      }
      if (index >= 0) {
        this.setStatus(index, PROBE_STATUS_DONE);
      }
    } catch (e) {
      if (!this.isCurrentSession(epoch, token)) {
        return;
      }
      ok = false;
      if (index >= 0) {
        this.setStatus(index, PROBE_STATUS_ERROR);
      }
      const err = e as BusinessError;
      const errKvs: KeyValue[] = [
        new KeyValue('errCode', String(err.code)),
        new KeyValue('errMessage', err.message ?? '')
      ];
      this.probeKit.emit(stepNo, errKvs);
    }
    if (!this.isCurrentSession(epoch, token)) {
      return;
    }
    this.probeKit.end(ok);
    this.refreshLog();
    this.sessionRunning = false;
    this.hasResult = true;
  }

  copyLog(): void {
    const epoch: number = this.pageEpoch;
    const token: string = this.sessionToken;
    if (!this.ownsSession(epoch, token) || !this.hasResult || this.sessionRunning) {
      return;
    }
    const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.logText);
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      if (this.ownsSession(epoch, token)) {
        this.copied = true;
      }
    }).catch((err: BusinessError) => {
      if (!this.ownsSession(epoch, token)) {
        return;
      }
      hilog.error(PROBE_DOMAIN, DIAG_TAG, '%{public}s',
        'copy log failed errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
    });
  }

  /** 所有权比较允许 ended，会话完成后的复制按钮仍然有效。 */
  private ownsSession(epoch: number, token: string): boolean {
    return this.alive && this.pageEpoch === epoch && token.length > 0 &&
      this.sessionToken === token && this.probeKit.getSessionToken() === token;
  }

  private isCurrentSession(epoch: number, token: string): boolean {
    return this.ownsSession(epoch, token) && this.probeKit.isCurrent(token);
  }

  /** 组件内取 Context：禁用已弃用 getContext(this)，getHostContext 返回 Context|undefined 需窄化 */
  private resolveFilesDir(): string {
    const ctx = this.getUIContext().getHostContext();
    return ctx?.filesDir ?? '';
  }

  private indexOfStep(stepNo: string): number {
    for (let i = 0; i < this.steps.length; i++) {
      if (this.steps[i].stepNo === stepNo) {
        return i;
      }
    }
    return -1;
  }

  private setStatus(index: number, status: string): void {
    if (index >= 0 && index < this.statuses.length) {
      this.statuses[index] = status;
    }
  }

  private resetStatuses(): void {
    for (let i = 0; i < this.statuses.length; i++) {
      this.statuses[i] = PROBE_STATUS_PENDING;
    }
  }

  private refreshLog(): void {
    const lines: string[] = this.probeKit.getLines();
    this.logText = lines.join('\n');
  }

  private statusAt(stepNo: string): string {
    const index: number = this.indexOfStep(stepNo);
    if (index >= 0 && index < this.statuses.length) {
      return this.statuses[index];
    }
    return PROBE_STATUS_PENDING;
  }

  private statusRes(stepNo: string): ResourceStr {
    const status: string = this.statusAt(stepNo);
    if (status === PROBE_STATUS_DONE) {
      return $r('app.string.probe_status_done');
    }
    if (status === PROBE_STATUS_ERROR) {
      return $r('app.string.probe_status_error');
    }
    if (status === PROBE_STATUS_RUNNING) {
      return $r('app.string.probe_status_running');
    }
    return $r('app.string.probe_status_pending');
  }

  private statusColor(stepNo: string): ResourceColor {
    const status: string = this.statusAt(stepNo);
    if (status === PROBE_STATUS_DONE) {
      return '#2E7D32';
    }
    if (status === PROBE_STATUS_ERROR) {
      return '#C62828';
    }
    if (status === PROBE_STATUS_RUNNING) {
      return '#1565C0';
    }
    return '#616161';
  }

  private statusBgColor(stepNo: string): ResourceColor {
    const status: string = this.statusAt(stepNo);
    if (status === PROBE_STATUS_DONE) {
      return '#E8F5E9';
    }
    if (status === PROBE_STATUS_ERROR) {
      return '#FFEBEE';
    }
    if (status === PROBE_STATUS_RUNNING) {
      return '#E3F2FD';
    }
    return '#ECEFF1';
  }

  build() {
    Column({ space: 12 }) {
      Text(this.pageTitle)
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .width('100%')

      Row({ space: 8 }) {
        Button(this.hasResult ? $r('app.string.probe_rerun') : $r('app.string.probe_run_all'))
          .onClick(() => {
            this.startSession();
          })
          .enabled(!this.sessionRunning)
        Button(this.copied ? $r('app.string.probe_copied') : $r('app.string.probe_copy_log'))
          .onClick(() => {
            this.copyLog();
          })
          .enabled(!this.sessionRunning)
      }
      .width('100%')

      ForEach(this.steps, (step: ProbeStepDef) => {
        Row({ space: 8 }) {
          Text(step.stepNo)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .width(44)
          Text(step.title)
            .fontSize(14)
            .layoutWeight(1)
          Text(this.statusRes(step.stepNo))
            .fontSize(12)
            .fontColor(this.statusColor(step.stepNo))
            .backgroundColor(this.statusBgColor(step.stepNo))
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .borderRadius(8)
          if (!step.autoRun) {
            Button($r('app.string.probe_step_run'))
              .onClick(() => {
                this.runSingle(step.stepNo);
              })
          }
        }
        .width('100%')
        .padding(8)
        .borderRadius(8)
        .backgroundColor('#F1F3F5')
      }, (step: ProbeStepDef) => step.stepNo)

      Scroll() {
        Text(this.logText)
          .fontSize(12)
          .fontFamily('monospace')
          .width('100%')
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
    }
    .width('100%')
    .height('100%')
    .padding(16)
  }
}
