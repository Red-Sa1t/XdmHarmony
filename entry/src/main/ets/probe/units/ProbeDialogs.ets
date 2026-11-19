/*
 * U4.2 探针单元：P4-U2 对话框包走查探针（设计书 §5.12/§6 五步）。
 * 会话模型：autoStart=false——S1/S2 纯函数与 Config 回读可"运行全部"先行；S3 需主机侧慢源
 * （node P1-U2-download-server.js，/slow.bin?ms=300 零改动复用）；S4 无需网络；S5 人工 26 项
 * 勾选清单（§6bis）单步执行。
 *   S1 批量算法观测：BatchParams 八场景调 generateBatchLinks/computeBatchPreview（isUriValid
 *      由 core/net/HttpProtocol 注入——探针只 import 业务公开面）。
 *   S2 限速规范化+Config 回读：speedLimitView 四场景；Config 快照→setSpeedLimit(true,100)/
 *      (true,0)/(false,50) 逐次读回 getter；ConfigChanged 监听计数；恢复快照。
 *   S3 进度窗生命周期（慢源实跑）：探针页自持 ProgressWindowHost（createDetached——不与 Index
 *      共享应用单例）+ manager.init 后到者接管事件袋（事件袋内复刻 Index 五转发尾——openFor/
 *      模型写/onPaused/onFailed/onDownloadFinished）；store.add(r1, id=probe-p4u2-<runId>-1
 *      COLD-F1)+admitNew→轮询开窗→停→轮询停态→续→轮询回 Pause 态→停+closeFor→窗计数归零。
 *   S4 完成窗触发门：快照 showDownloadCompleteWindow→host.onDownloadFinished('fake-id',…)
 *      →completedShown+windowCount（进度窗不存在不误关）→关闸再调→恢复 true 读回。
 *   S5 走查清单（manual）：26 项 Toggle 勾选发射 checked/total/unchecked（标题只进 UI 不进日志）。
 * 探针页另持 CredentialDialog/DeleteConfirmDialog 控制器（清单第 25/26 项对话框面走查辅助——
 *   Credential 业务无触发点，源码死链 §0-3）。
 * 纪律：观测值只写事实不写 PASS/FAIL（判定在 EXPECT/verify）；业务侧零 probe import；
 *   [XDM_PROBE] 仅经 ProbeKit 出口；DB 行每轮 +1（S3），与既有探针同口径不清理。
 */

import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ProbeKit, KeyValue } from '../core/ProbeKit';
import { ProbePage, ProbeStepDef } from '../core/ProbePage';
import { DownloadEvents, ForwardDownloadEvents } from '../../core/engine/Downloader';
import { DownloadManager } from '../../core/engine/DownloadManager';
import { DownloadRecord, newDownloadRecord } from '../../model/DownloadRecord';
import { DownloadStore } from '../../core/db/DownloadStore';
import { Config } from '../../core/Config';
import { isUriValid } from '../../core/net/HttpProtocol';
import { formatSize, formatSpeed, toHMS } from '../../core/util/Formatting';
import { BatchParams, generateBatchLinks, computeBatchPreview } from '../../core/util/BatchAlgo';
import { speedLimitView } from '../../core/util/SpeedLimitView';
import {
  ProgressWindowHost,
  ProgressWindowActions,
  ProgressWindowModel
} from '../../components/ProgressWindowDialog';
import { CredentialDialog } from '../../components/CredentialDialog';
import { DeleteConfirmDialog } from '../../components/DeleteConfirmDialog';
import { AuthenticationInfo } from '../../model/DownloadTypes';

/** 测试源缺省地址（TextInput 占位；真机/模拟器填主机局域网 IP，禁 127.0.0.1） */
const DEFAULT_BASE_URL: string = 'http://127.0.0.1:8081';

/** S3 慢源参数（/slow.bin?ms=300——P4-U1 S3 同参：停/续观测窗口远大于提交序列） */
const SLOW_MS: number = 300;

/** S3 轮询（POLL_MS=100 不忙等；各观测点独立 20s 超时后仍发观测行） */
const S3_TIMEOUT_MS: number = 20000;
const POLL_MS: number = 100;

/** 步骤定义表（S5 manual——单步迷你会话） */
const DIALOG_STEPS: ProbeStepDef[] = [
  { stepNo: 'S1', title: '批量算法观测', autoRun: true },
  { stepNo: 'S2', title: '限速规范化+Config 回读', autoRun: true },
  { stepNo: 'S3', title: '进度窗生命周期（慢源）', autoRun: true },
  { stepNo: 'S4', title: '完成窗触发门', autoRun: true },
  { stepNo: 'S5', title: '人工走查清单 26 项', autoRun: false }
];

/** S5 走查清单 26 项（§6bis 全文；只进勾选面 UI，不进探针日志） */
const CHECKLIST_TITLES: string[] = [
  '新建下拉第 3 项 Batch download 可点，批量窗打开且非模态（主窗可继续操作）',
  '批量窗地址含 * 时三预览+数量即时刷新；抹掉 * 预览清空',
  'Letters 模式 From/To 下拉各 26 项 A..Z；切 Numbers 后 From/To 变数字输入',
  '勾选补零+位数 3 → 数字预览出现前导零（001…）',
  '批量窗 OK 无生成 → "Select items to download" 提示且窗不关；有生成 → 批量窗关、选择窗开',
  '选择窗条目默认全选中；全选框不勾但条目已全选（源码同貌）；取消若干条后 OK 只下被选条目数',
  '选择窗全不选后 OK → "Select items to download" 提示不关窗',
  'Download Now → 选择窗关、进行中列表新增行并起跑',
  'Download Later → 不使用队列 → 新行 Stopped 不起跑，手动继续可跑（源码 startType 缺省 Waiting 仅对 Now 生效）',
  'More → 高级窗有 No Proxy/Manual Proxy 与认证两输入，无 System Proxy 项',
  'More 填 user/pass+Manual host/port 确认 → Download Now → 新行建出（行为不因裁剪中断）',
  '进行中行右键 → 菜单含 Refresh link/Show progress 两项',
  '右键 Refresh link → 等待窗打开（Http 记录）；窗显 "Waiting for download link..."',
  '刷新链接窗 Stop → 窗关无残留',
  '右键 Show progress → 进度窗开；重复点击不弹第二窗（幂等）',
  '进度窗文件名/URL/进度/速度/ETA 与主列表行一致',
  '进度窗限速文本初始 "No speed limit"；点击 → 限速窗打开（非模态）',
  '限速窗勾选+输入 100 → OK → 进度窗限速文本变 "Speed limit - 100K/S"（ConfigChanged 刷新）',
  '限速输入非整数被滤除；输入清空失焦 → 勾选自动取消',
  '进度窗 Pause → 状态 "Download stopped"+按钮变 Resume，下载停；Resume → 续跑按钮回 Pause',
  '进度窗 Hide → 窗关下载继续（主列表进度仍在走）',
  '进度窗 Stop → 窗关下载停（行变 Stopped）',
  '小文件完成 → 进度窗自动关 + 完成窗弹出（Download Complete+文件名/目录）',
  '完成窗 Open/Open folder 点击不崩溃（占位）；Don\'t show this again → 窗关，再次完成下载不再弹',
  '进行中视图选中行 Delete → 行先被停 → 确认框（无删文件选项）→ 确认后行消失且重启不回；Cancel 则行保留（但已停）',
  '完成视图选中行 Delete → 确认框带 "Delete files from disk" 选项 → 确认后行消失；探针页 Credential 步骤：空用户名 OK → "User name required" 不关窗，填名+密码 OK 回调收到 userName，Cancel 无回调'
];

/** S3 manager 事件事实袋 */
class DialogsFacts {
  startedCount: number = 0;
  pausedCount: number = 0;
  finishedCount: number = 0;
  failedCount: number = 0;
}

@Component
export struct ProbeDialogs {
  @State baseUrl: string = DEFAULT_BASE_URL;
  /** S5 勾选面（26 项；状态跨"运行全部"与单步 S5 存续） */
  @State checkedFlags: boolean[] = CHECKLIST_TITLES.map((title: string): boolean => false);
  private probeKit: ProbeKit = ProbeKit.getInstance();
  private facts: DialogsFacts = new DialogsFacts();
  /** 探针页自持进度窗宿主（S3/S4 惰性建） */
  private probeHost: ProgressWindowHost | null = null;
  /** S3 在途记录引用（事件袋按 id 回查） */
  private liveRecord: DownloadRecord | null = null;
  /** 凭据/删除确认窗走查辅助（清单第 25/26 项） */
  private credentialController: CustomDialogController = new CustomDialogController({
    builder: CredentialDialog({
      onConfirm: (auth: AuthenticationInfo): void => {
        // 观测事实不进 [XDM_PROBE]（S5 勾选清单承载），仅 UI 可见的走查辅助
        this.credentialEcho = auth.userName;
      },
      onCancel: (): void => {
        this.credentialEcho = '';
      }
    }),
    autoCancel: true
  });
  private deleteConfirmProbeController: CustomDialogController = new CustomDialogController({
    builder: DeleteConfirmDialog({
      onConfirm: (deleteFiles: boolean): void => {
        this.deleteConfirmEcho = deleteFiles;
      },
      onCancel: (): void => {
        this.deleteConfirmEcho = null;
      }
    }),
    autoCancel: true
  });
  /** 走查辅助回显（仅 UI 提示，不进日志） */
  @State credentialEcho: string = '';
  @State deleteConfirmEcho: boolean | null = null;
  /** U5.2 INT-F7：S2 Config listener 成员引用（runS2 try/finally 卸载；aboutToDisappear 兜底） */
  private s2ConfigListener: (() => void) | null = null;

  /** §8 风险缓解（探针页同理）：组件销毁收口自持 host 的动态窗残留 + INT-F7 兜底卸载 S2
   * listener（异常路径 finally 已卸；页面卸载时若仍残留则在此 off，防监听器泄漏） */
  aboutToDisappear(): void {
    const host: ProgressWindowHost | null = this.probeHost;
    if (host !== null) {
      host.closeAll();
    }
    const listener: (() => void) | null = this.s2ConfigListener;
    if (listener !== null) {
      Config.getInstance().offConfigChanged(listener);
      this.s2ConfigListener = null;
    }
  }

  /** 步骤分派 */
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
      this.runS5();
      return;
    }
  }

  // ---------- S1 批量算法观测 ----------

  private async runS1(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      // 场景①：字母 A-C
      const letterAC: string[] | null = generateBatchLinks(this.letterParams('A', 'C'), isUriValid);
      const letterACCount: number = letterAC !== null ? letterAC.length : -1;
      // 场景②：无星号
      const noStar: string[] | null = generateBatchLinks(this.noAsteriskParams(), isUriValid);
      const noAsterisk: number = noStar !== null ? noStar.length : -1;
      // 场景③：字母区间反序（start>=end）
      const reversed: string[] | null = generateBatchLinks(this.letterParams('C', 'A'), isUriValid);
      const letterReversed: number = reversed !== null ? reversed.length : -1;
      // 场景④：字母缺选（startLetter 空）
      const missing: string[] | null = generateBatchLinks(this.letterMissingParams(), isUriValid);
      const letterMissing: number = missing !== null ? missing.length : -1;
      // 场景⑤：数字 1-3
      const digit123: string[] | null = generateBatchLinks(this.digitParams(1, 3, false, 0), isUriValid);
      const digit123Stems: string = digit123 !== null ? this.stemsOf(digit123) : 'null';
      const digit123Count: number = digit123 !== null ? digit123.length : -1;
      // 场景⑥：数字补零 D3（1-3）
      const digitPad: string[] | null = generateBatchLinks(this.digitParams(1, 3, true, 3), isUriValid);
      const digitPadStems: string = digitPad !== null ? this.stemsOf(digitPad) : 'null';
      // 场景⑦：数字负数区间 -1..1 D3（padDigits 负号外置）
      const digitNeg: string[] | null = generateBatchLinks(this.digitParams(-1, 1, true, 3), isUriValid);
      const digitNegStems: string = digitNeg !== null ? this.stemsOf(digitNeg) : 'null';
      // 场景⑧：两星号 URL（split/join 全量替换）
      const twoStars: string[] | null = generateBatchLinks(this.twoStarsParams(), isUriValid);
      const twoStarsCount: number = twoStars !== null && twoStars.length > 0
        ? this.countChar(twoStars[0], 'A') : -1;
      // 场景⑨：非法 URL（无 scheme）→ null
      const invalid: string[] | null = generateBatchLinks(this.invalidParams(), isUriValid);
      const invalidNull: string = invalid === null ? 'null' : 'notnull';
      // 场景⑩：四链预览
      const previewInput: string[] | null = generateBatchLinks(this.letterParams('A', 'D'), isUriValid);
      const preview: string[] = previewInput !== null ? previewInput : [];
      const computed = computeBatchPreview(preview);
      const kvs: KeyValue[] = [
        new KeyValue('letterAC', String(letterACCount)),
        new KeyValue('noAsterisk', String(noAsterisk)),
        new KeyValue('letterReversed', String(letterReversed)),
        new KeyValue('letterMissing', String(letterMissing)),
        new KeyValue('digit123', digit123Stems),
        new KeyValue('digit123Count', String(digit123Count)),
        new KeyValue('digitPad', digitPadStems),
        new KeyValue('digitNeg', digitNegStems),
        new KeyValue('twoStars', String(twoStarsCount)),
        new KeyValue('invalid', invalidNull),
        new KeyValue('previewFirst', this.stemOf(computed.first)),
        new KeyValue('previewSecond', this.stemOf(computed.second)),
        new KeyValue('previewLast', this.stemOf(computed.last)),
        new KeyValue('previewSize', String(computed.size))
      ];
      this.probeKit.emit('S1', kvs);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
    } catch (e) {
      this.emitStepError('S1', runId, e as BusinessError);
    }
  }

  private letterParams(start: string, end: string): BatchParams {
    const params: BatchParams = new BatchParams();
    params.url = 'http://probe.local/file*.bin';
    params.isLetterMode = true;
    params.startLetter = start;
    params.endLetter = end;
    return params;
  }

  private letterMissingParams(): BatchParams {
    const params: BatchParams = new BatchParams();
    params.url = 'http://probe.local/file*.bin';
    params.isLetterMode = true;
    params.startLetter = '';
    params.endLetter = 'C';
    return params;
  }

  private noAsteriskParams(): BatchParams {
    const params: BatchParams = new BatchParams();
    params.url = 'http://probe.local/file.bin';
    params.isLetterMode = true;
    params.startLetter = 'A';
    params.endLetter = 'C';
    return params;
  }

  private digitParams(start: number, end: number, pad: boolean, padCount: number): BatchParams {
    const params: BatchParams = new BatchParams();
    params.url = 'http://probe.local/file*.bin';
    params.isLetterMode = false;
    params.startNumber = start;
    params.endNumber = end;
    params.useLeadingZero = pad;
    params.leadingZeroCount = padCount;
    return params;
  }

  private twoStarsParams(): BatchParams {
    const params: BatchParams = new BatchParams();
    params.url = 'http://probe.local/a*b*c.bin';
    params.isLetterMode = true;
    // 严格区间 start<end（BatchAlgo :73-75 start>=end 空）——'A'..'B' 生成 2 链，
    // links[0]='.../aAbAc.bin' → countChar(links[0],'A')=2（EXPECT-u4-2 S1 twoStars=2 对齐）
    params.startLetter = 'A';
    params.endLetter = 'B';
    return params;
  }

  private invalidParams(): BatchParams {
    const params: BatchParams = new BatchParams();
    params.url = 'not-a-scheme/*.bin';
    params.isLetterMode = true;
    params.startLetter = 'A';
    params.endLetter = 'B';
    return params;
  }

  /** 末段名干串（'http://x/file1.bin'→'file1'，'/' 连接） */
  private stemsOf(urls: string[]): string {
    const parts: string[] = [];
    for (let i = 0; i < urls.length; i++) {
      parts.push(this.stemOf(urls[i]));
    }
    return parts.join('/');
  }

  private stemOf(url: string): string {
    const slash: number = url.lastIndexOf('/');
    const last: string = slash >= 0 ? url.slice(slash + 1) : url;
    return last.length > 0 ? last : '-';
  }

  private countChar(text: string, ch: string): number {
    let count: number = 0;
    for (let i = 0; i < text.length; i++) {
      if (text.charAt(i) === ch) {
        count++;
      }
    }
    return count;
  }

  // ---------- S2 限速规范化+Config 回读 ----------

  private async runS2(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      // 装载四场景（SpeedLimiterUIController.cs:12-13 同式）
      const viewOn = speedLimitView(true, 100);
      const viewOffCfg = speedLimitView(false, 50);
      const viewZero = speedLimitView(true, 0);
      const viewNeg = speedLimitView(true, -5);
      // Config 快照→三次写读回→监听计数→恢复
      // U5.2 INT-F7：listener 注册前提升为成员引用 s2ConfigListener+try/finally 包裹写读段
      // （异常路径 finally 卸载）；aboutToDisappear 页面卸载兜底——双兜底防监听器泄漏
      const cfg: Config = Config.getInstance();
      const snapEnable: boolean = cfg.getEnableSpeedLimit();
      const snapSpeed: number = cfg.getDefaultDownloadSpeed();
      let listenerFired: number = 0;
      const listener = (): void => {
        listenerFired++;
      };
      this.s2ConfigListener = listener;
      let firedAfterSets: number = 0;
      let setTrue100: string = '';
      let setTrue0: string = '';
      let setFalse50: string = '';
      let restored: string = '';
      try {
        cfg.onConfigChanged(listener);
        cfg.setSpeedLimit(true, 100);
        setTrue100 = this.readSpeedPair(cfg);
        cfg.setSpeedLimit(true, 0);
        setTrue0 = this.readSpeedPair(cfg);
        cfg.setSpeedLimit(false, 50);
        setFalse50 = this.readSpeedPair(cfg);
        firedAfterSets = listenerFired;
        cfg.setSpeedLimit(snapEnable, snapSpeed);
        restored = this.readSpeedPair(cfg);
      } finally {
        // 卸载（异常路径兜底）：finally 恒执行，成员引用同步置 null
        cfg.offConfigChanged(listener);
        this.s2ConfigListener = null;
      }
      const kvs: KeyValue[] = [
        new KeyValue('viewOn', this.pairOf(viewOn.enabled, viewOn.speedKBps)),
        new KeyValue('viewOffCfg', this.pairOf(viewOffCfg.enabled, viewOffCfg.speedKBps)),
        new KeyValue('viewZero', this.pairOf(viewZero.enabled, viewZero.speedKBps)),
        new KeyValue('viewNeg', this.pairOf(viewNeg.enabled, viewNeg.speedKBps)),
        new KeyValue('setTrue100', setTrue100),
        new KeyValue('setTrue0', setTrue0),
        new KeyValue('setFalse50', setFalse50),
        new KeyValue('listenerFired', String(firedAfterSets)),
        new KeyValue('restored', restored)
      ];
      this.probeKit.emit('S2', kvs);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
    } catch (e) {
      this.emitStepError('S2', runId, e as BusinessError);
    }
  }

  private readSpeedPair(cfg: Config): string {
    return this.pairOf(cfg.getEnableSpeedLimit(), cfg.getDefaultDownloadSpeed());
  }

  private pairOf(enabled: boolean, speed: number): string {
    return (enabled ? '1' : '0') + '/' + String(speed);
  }

  // ---------- S3 进度窗生命周期（慢源实跑） ----------

  private async runS3(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      this.resetSessionState();
      const host: ProgressWindowHost = this.ensureHost();
      const manager: DownloadManager = DownloadManager.getInstance();
      manager.init(this.buildHostEvents(host));
      const store: DownloadStore = DownloadStore.getInstance();
      const ctx: common.Context = this.requireContext();
      await store.initialize(ctx);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      // r1 提交（live）：确定性 id 在 add 前覆盖（COLD-F1）
      const r1: DownloadRecord = newDownloadRecord('p4u2-r1.bin', Config.getInstance().getDownloadDir(),
        0, null, this.joinBase('/slow.bin?ms=' + String(SLOW_MS)), false, null, null);
      r1.id = 'probe-p4u2-' + runId + '-1';
      this.liveRecord = r1;
      const ok1: boolean = await store.add(r1);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      if (ok1) {
        manager.admitNew(r1);
      }
      // 开窗观测（onStarted 转发→openFor）
      await this.pollUntil((): boolean => host.windowCount() === 1, S3_TIMEOUT_MS, POLL_MS);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const model: ProgressWindowModel | undefined = host.modelOf(r1.id);
      const opened: number = host.windowCount();
      const fileName: string = model !== undefined ? model.fileName : 'none';
      const statusPrefix: string = model !== undefined ? model.statusText.split(' ')[0] : 'none';
      // 停（stopOne→onPaused 回声→host.onPaused 写停态）
      manager.stopOne(r1.id);
      await this.pollUntil((): boolean => {
        const m: ProgressWindowModel | undefined = host.modelOf(r1.id);
        return m !== undefined && m.resumable && m.statusText === 'Download stopped';
      }, S3_TIMEOUT_MS, POLL_MS);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const pausedModel: ProgressWindowModel | undefined = host.modelOf(r1.id);
      const pausedResumable: number = pausedModel !== undefined && pausedModel.resumable ? 1 : 0;
      const pausedStatus: string = pausedModel !== undefined ? pausedModel.statusText : 'none';
      // 续（resumeOne→onStarted 回声→模型复位 Pause 态）
      manager.resumeOne(r1);
      await this.pollUntil((): boolean => {
        const m: ProgressWindowModel | undefined = host.modelOf(r1.id);
        return m !== undefined && !m.resumable;
      }, S3_TIMEOUT_MS, POLL_MS);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const resumedModel: ProgressWindowModel | undefined = host.modelOf(r1.id);
      const resumedResumable: number = resumedModel !== undefined && !resumedModel.resumable ? 1 : 0;
      // 停+关窗（BtnStop 语义：stopOne+closeFor 兜底）
      manager.stopOne(r1.id);
      host.closeFor(r1.id);
      await this.pollUntil((): boolean => manager.liveCount() === 0, S3_TIMEOUT_MS, POLL_MS);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      host.closeAll();
      this.liveRecord = null;
      const kvs: KeyValue[] = [
        new KeyValue('submitted', ok1 ? '1' : '0'),
        new KeyValue('opened', String(opened)),
        new KeyValue('fileName', fileName),
        new KeyValue('statusPrefix', statusPrefix),
        new KeyValue('pausedResumable', String(pausedResumable)),
        new KeyValue('pausedStatus', pausedStatus),
        new KeyValue('resumedResumable', String(resumedResumable)),
        new KeyValue('closedCount', String(host.windowCount())),
        new KeyValue('liveAfter', String(manager.liveCount())),
        new KeyValue('startedEcho', String(this.facts.startedCount)),
        new KeyValue('pausedEcho', String(this.facts.pausedCount))
      ];
      this.probeKit.emit('S3', kvs);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
    } catch (e) {
      this.emitStepError('S3', runId, e as BusinessError);
    }
  }

  /**
   * S3 事件袋（manager.init 后到者接管）：复刻 Index 五转发尾（openFor 门+模型写/
   * onPaused/onFailed/onDownloadFinished）+事实计数——host 消费路径与业务面同构。
   */
  private buildHostEvents(host: ProgressWindowHost): DownloadEvents {
    return new ForwardDownloadEvents(
      (id: string): void => {
        this.facts.startedCount++;
        const record: DownloadRecord | null = this.recordOf(id);
        if (record !== null && Config.getInstance().getShowProgressWindow() &&
          DownloadManager.getInstance().isInteractive(id)) {
          host.openFor(record);
        }
        const model: ProgressWindowModel | undefined = host.modelOf(id);
        if (model !== undefined) {
          model.statusText = 'Downloading ...';
          model.resumable = false;
        }
      },
      (id: string, status: number, totalSize: number, resumable: boolean, contentType: string): void => {
        const record: DownloadRecord | null = this.recordOf(id);
        if (record !== null && totalSize > 0) {
          record.size = totalSize;
        }
      },
      (id: string, progress: number, instantSpeed: number, etaSeconds: number,
        downloadedBytes: number): void => {
        const record: DownloadRecord | null = this.recordOf(id);
        const model: ProgressWindowModel | undefined = host.modelOf(id);
        if (model !== undefined) {
          model.progressPercent = progress >= 0 && progress <= 100 ? progress : 0;
          model.statusText = 'Downloading ' + formatSize(downloadedBytes) + ' / ' +
            formatSize(record !== null ? record.size : 0);
          model.speedText = formatSpeed(instantSpeed);
          model.etaText = 'Time left: ' + toHMS(etaSeconds);
        }
      },
      (id: string, offsetBytes: number): void => {
        this.facts.pausedCount++;
        host.onPaused(id);
      },
      (id: string, finalFileSize: number, filePath: string): void => {
        this.facts.finishedCount++;
        host.onDownloadFinished(id, filePath);
      },
      (id: string, errorCode: number, errorMessage: string): void => {
        this.facts.failedCount++;
        host.onFailed(id, errorCode);
      }
    );
  }

  private recordOf(id: string): DownloadRecord | null {
    const record: DownloadRecord | null = this.liveRecord;
    if (record !== null && record.id === id) {
      return record;
    }
    return null;
  }

  // ---------- S4 完成窗触发门 ----------

  private async runS4(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const host: ProgressWindowHost = this.ensureHost();
      const cfg: Config = Config.getInstance();
      const gateBefore: number = cfg.getShowDownloadCompleteWindow() ? 1 : 0;
      host.onDownloadFinished('probe-p4u2-fake-1', '/tmp/p4u2.bin');
      // openCustomDialog 异步落位——completedOpen 簿记同步置位（host 实现），观测确定性成立
      const completedShown1: number = host.isCompletedOpen() ? 1 : 0;
      const windowCountAfter: number = host.windowCount();
      cfg.setShowDownloadCompleteWindow(false);
      const gateAfterDisable: number = cfg.getShowDownloadCompleteWindow() ? 1 : 0;
      // 首窗仍开着（单飞：后续完成只入队补弹），存活态恒 1——改以「新开或新入队」判门是否挡住
      // （2026-10-18 真机 completedShown2=1 实为首窗存活读数，门本身正确）
      const openBefore: boolean = host.isCompletedOpen();
      const pendingBefore: number = host.completedPendingCount();
      host.onDownloadFinished('probe-p4u2-fake-2', '/tmp/p4u2b.bin');
      const completedShown2: number = (host.completedPendingCount() > pendingBefore ||
        (!openBefore && host.isCompletedOpen())) ? 1 : 0;
      cfg.setShowDownloadCompleteWindow(true);
      const restored: number = cfg.getShowDownloadCompleteWindow() ? 1 : 0;
      host.closeAll();
      const kvs: KeyValue[] = [
        new KeyValue('gateBefore', String(gateBefore)),
        new KeyValue('completedShown1', String(completedShown1)),
        new KeyValue('windowCountAfter', String(windowCountAfter)),
        new KeyValue('gateAfterDisable', String(gateAfterDisable)),
        new KeyValue('completedShown2', String(completedShown2)),
        new KeyValue('restored', String(restored))
      ];
      this.probeKit.emit('S4', kvs);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
    } catch (e) {
      this.emitStepError('S4', runId, e as BusinessError);
    }
  }

  // ---------- S5 人工走查清单（manual 单步） ----------

  /** S5：checked=<k> total=26 unchecked=<索引'/'串或 none>（1 基项号） */
  private runS5(): void {
    const runId: string = this.probeKit.getSessionToken();
    try {
      let checked: number = 0;
      const unchecked: string[] = [];
      for (let i = 0; i < this.checkedFlags.length; i++) {
        if (this.checkedFlags[i]) {
          checked++;
        } else {
          unchecked.push(String(i + 1));
        }
      }
      const kvs: KeyValue[] = [
        new KeyValue('checked', String(checked)),
        new KeyValue('total', String(this.checkedFlags.length)),
        new KeyValue('unchecked', unchecked.length > 0 ? unchecked.join('/') : 'none')
      ];
      this.probeKit.emit('S5', kvs);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
    } catch (e) {
      this.emitStepError('S5', runId, e as BusinessError);
    }
  }

  // ---------- 工具 ----------

  private resetSessionState(): void {
    this.facts = new DialogsFacts();
    this.liveRecord = null;
  }

  /** 探针页自持宿主（惰性建+init——actionsFactory 与 Index 同构） */
  private ensureHost(): ProgressWindowHost {
    if (this.probeHost === null) {
      const host: ProgressWindowHost = ProgressWindowHost.createDetached();
      host.init(this.getUIContext(), (id: string): ProgressWindowActions => {
        const actions: ProgressWindowActions = new ProgressWindowActions();
        actions.onPauseResume = (): void => {
          const model: ProgressWindowModel | undefined = host.modelOf(id);
          const record: DownloadRecord | null = this.recordOf(id);
          if (model === undefined || record === null) {
            return;
          }
          if (model.resumable) {
            DownloadManager.getInstance().resumeOne(record);
            model.resumable = false;
          } else {
            DownloadManager.getInstance().stopOne(id);
          }
        };
        actions.onStop = (): void => {
          DownloadManager.getInstance().stopOne(id);
          host.closeFor(id);
        };
        actions.onHide = (): void => {
          host.hideFor(id);
        };
        actions.onOpenSpeedLimiter = (): void => {
          host.openSpeedLimiter();
        };
        return actions;
      });
      this.probeHost = host;
    }
    return this.probeHost;
  }

  /** 谓词轮询（P4-U1 pollUntil 同式，POLL_MS=100 不忙等） */
  private async pollUntil(predicate: () => boolean, timeoutMs: number, pollMs: number): Promise<boolean> {
    const deadline: number = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (predicate()) {
        return true;
      }
      await this.sleep(pollMs);
    }
    return predicate();
  }

  private async sleep(ms: number): Promise<void> {
    await new Promise<void>((resolve: () => void) => {
      setTimeout(() => resolve(), ms);
    });
  }

  private emitStepError(stepNo: string, runId: string, err: BusinessError): void {
    if (!this.probeKit.isCurrent(runId)) {
      return;
    }
    const kvs: KeyValue[] = [
      new KeyValue('errCode', String(err.code)),
      new KeyValue('errMessage', err.message ?? '')
    ];
    this.probeKit.emit(stepNo, kvs);
  }

  private requireContext(): common.Context {
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      throw new Error('host context undefined');
    }
    return ctx;
  }

  /** 测试源拼接：TextInput 值去尾部斜杠 + 路由；空值回退缺省地址（P4-U1 同构） */
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

  build() {
    Column({ space: 12 }) {
      Text($r('app.string.probe_p4u2_title'))
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .width('100%')
      Text($r('app.string.probe_p4u2_source_hint'))
        .fontSize(12)
        .opacity(0.7)
        .width('100%')
      TextInput({ text: this.baseUrl, placeholder: $r('app.string.probe_p4u2_source_hint') })
        .onChange((value: string) => {
          this.baseUrl = value;
        })
        .width('100%')
      Text($r('app.string.probe_p4u2_check_hint'))
        .fontSize(12)
        .opacity(0.7)
        .width('100%')

      // 走查辅助：凭据/删除确认窗（清单第 25/26 项对话框面）
      Row({ space: 8 }) {
        Button('打开凭据窗')
          .fontSize(12)
          .onClick(() => {
            this.credentialController.open();
          })
        Text(this.credentialEcho.length > 0 ? 'userName=' + this.credentialEcho : '未确认')
          .fontSize(11)
          .opacity(0.7)
          .layoutWeight(1)
          .maxLines(1)
        Button('打开删除确认窗')
          .fontSize(12)
          .onClick(() => {
            this.deleteConfirmProbeController.open();
          })
        Text(this.deleteConfirmEcho === null ? '未确认'
          : (this.deleteConfirmEcho ? 'deleteFiles=1' : 'deleteFiles=0'))
          .fontSize(11)
          .opacity(0.7)
          .layoutWeight(1)
          .maxLines(1)
      }
      .width('100%')

      // S5 勾选面（26 项；状态跨"运行全部"与单步 S5 存续）
      Scroll() {
        Column({ space: 4 }) {
          ForEach(CHECKLIST_TITLES, (title: string, index: number) => {
            Row({ space: 8 }) {
              Text(String(index + 1))
                .fontSize(12)
                .opacity(0.6)
                .width(22)
              Text(title)
                .fontSize(12)
                .layoutWeight(1)
              Toggle({ type: ToggleType.Checkbox, isOn: this.checkedFlags[index] })
                .onChange((value: boolean) => {
                  this.checkedFlags[index] = value;
                })
            }
            .width('100%')
            .padding(4)
          }, (title: string, index: number) => String(index))
        }
        .width('100%')
      }
      .width('100%')
      .height(220)
      .scrollBar(BarState.Auto)
      .border({ width: 1, color: '#E0E0E0' })
      .borderRadius(8)
      .padding(6)

      ProbePage({
        unitId: 'P4-U2',
        pageTitle: $r('app.string.probe_p4u2_title'),
        steps: DIALOG_STEPS,
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
