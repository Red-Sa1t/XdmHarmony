/*
 * U5.1 探针单元：P5-U1 后台长时任务+通知探针（设计书 §6 五步）。
 * 会话模型：主会话（"运行全部"，S1→S4 autoRun + S5 占位发射，8 行 = BEGIN+S1+S2+S3+S4+S5+
 * SUMMARY+END）+ S5 单步会话（人工两阶段 armed→survived，各 4 行 = BEGIN+S5+SUMMARY+END，
 * 末次 runId=验收锚）。主会话内的 S5 为占位发射（经 mainSessionS1Seen 标记识别——主会话 S1
 * 先行置位，S5 见位即发占位行并复位；单步会话不跑 S1，标记 false → 真实两阶段）。
 *   S1 授权+基线+监听注册：manager.init（事件袋尾部转发 ProgressNotifier，后到者接管）→
 *      isNotificationEnabledSync → getActiveNotificationCount → getAllContinuousTasks →
 *      backgroundTaskManager.on('continuousTaskCancel', cb)（cb 写模块级 LastCancel，进程内
 *      注册一次幂等；reason 只记数字不做枚举名映射——12 属 26+ detailedReason，D1）
 *   S2 申请锚：3 条 /slow.bin?ms=300（确定性 id probe-p5u1-<runId>-1..3，store.add 前覆盖
 *      record.id——COLD-F1 约定）→ admitNew → 轮询 ≤10s 至 taskNotificationId()>=0
 *      （startBackgroundRunning.then 簿记=真实注册完成锚，R2-F1）→ getAllContinuousTasks
 *   S3 实况窗观测：liveCount>0 期间 ≤10s 轮询——事件袋 progressEvents delta、notifier.stats()
 *      （publishOk/publishFail/publishMsMax 累计口径，D12）、getActiveNotificationCount
 *   S4 完成→释放锚：轮询 ≤120s 至 activeCount==0 且 getAllContinuousTasks==0（真实释放
 *      完成锚，R2-F1）→ finishedCount →
 *      getActiveNotificationCount（完成通知在、实况窗已移除）→ cancel(finishNotifyId) →
 *      再读计数 → 读 LastCancel
 *   S5 后台存活（autoRun=false 单步×2）：armed=重提 1 个长下载（/slow.bin?ms=2000 ≈30-60s）→
 *      轮询至 applied → 写模块级 armed 快照（armedRecordId/armedProgressAt——进程不死即有效，
 *      恰好是本单元验收对象，§8-5）→ emit 后人工走查（点 X 关窗→等 15-20s→Dock 恢复→回探针页）；
 *      survived（第二次执行）=getAllContinuousTasks + store 读该 record 进度 + 读 LastCancel →
 *      emit 后复位 armed 快照（下一周期可重新 armed）
 * 事件袋尾部转发（§0-11 红线）：page=probe 冷启动 Index 不在，探针自带同款转发
 * （ProgressNotifier.onDownloadStarted/Progress/onDownloadEnded）+ DB 回声镜像 Index 消费方角色
 * （progress→updateProgress、finished→markAsFinished——S5 survived 的 store 进度/kind 读数原料）。
 * 探针驱动模型（P2-U1/P3-U1 同构）：只调业务公开 API（DownloadManager/DownloadStore/Config/
 * ProgressNotifier/NotifyAlgo 观测面）；观测值只写事实不写 PASS/FAIL（判定在 EXPECT/verify）。
 */

import { common } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ProbeKit, KeyValue, PROBE_DOMAIN } from '../core/ProbeKit';
import { ProbePage, ProbeStepDef } from '../core/ProbePage';
import { DownloadEvents, ForwardDownloadEvents } from '../../core/engine/Downloader';
import { DownloadManager } from '../../core/engine/DownloadManager';
import { DownloadRecord, newDownloadRecord } from '../../model/DownloadRecord';
import { DownloadKind } from '../../model/DownloadTypes';
import { DownloadStore } from '../../core/db/DownloadStore';
import { Config } from '../../core/Config';
import { finishedSize } from '../../core/notify/NotifyAlgo';
import { ProgressNotifier, NotifierStats } from '../../core/notify/ProgressNotifier';

/** 非标记诊断行 tag：不含 "XDM_PROBE" 子串（verify grep 不抓未配对行） */
const DIAG_TAG: string = 'XdmProbeBgNotify';

/** 测试源缺省地址（手册"可替换参数"占位值；真机/模拟器填主机局域网 IP，禁 127.0.0.1） */
const DEFAULT_BASE_URL: string = 'http://127.0.0.1:8081';

/** S2 下载源慢参数（3×/slow.bin?ms=300 ≈3-5s 全链完成，S3 实况窗窗口内可观测 publish 流） */
const SLOW_MS_S2: number = 300;
/** S5 armed 长下载慢参数（≈30-60s——关窗 15-20s 走查窗口内必未完成） */
const SLOW_MS_S5: number = 2000;

/** S2 提交数（3 并发=Config 默认上限内全 live） */
const SUBMIT_COUNT: number = 3;

/** S2/S5-armed 申请锚轮询超时 / S3 实况窗观测窗 / S4 释放锚超时 / 轮询周期 */
const APPLY_TIMEOUT_MS: number = 10000;
const LIVE_VIEW_WINDOW_MS: number = 10000;
const RELEASE_TIMEOUT_MS: number = 120000;
const POLL_MS: number = 100;

/** 步骤定义表：S1~S4 autoRun；S5 autoRun=false（单步迷你会话两阶段） */
const BACKGROUND_NOTIFY_STEPS: ProbeStepDef[] = [
  { stepNo: 'S1', title: '授权+基线+取消监听注册', autoRun: true },
  { stepNo: 'S2', title: '提交 3 下载+申请锚', autoRun: true },
  { stepNo: 'S3', title: '实况窗 publish 观测', autoRun: true },
  { stepNo: 'S4', title: '完成→释放+完成通知锚', autoRun: true },
  { stepNo: 'S5', title: '后台存活两阶段（armed→survived）', autoRun: false }
];

// ---------- 模块级跨会话进程内持久观测态（业务代码不注册不消费——仅本探针写读） ----------

/** continuousTaskCancel 最后一次观测（reason 只记数字；caught=false=未捕获过） */
let lastCancelCaught: boolean = false;
let lastCancelReason: number = -1;
let lastCancelId: number = -1;
/** 取消监听进程内注册一次守卫（重复 on 同回调名无害，注册幂等更稳） */
let cancelListenerRegistered: boolean = false;

/** S5 armed 快照（armed→survived 跨会话存续；survived emit 后复位空串=可重新 armed） */
let armedRecordId: string = '';
let armedProgressAt: number = 0;

/** 引擎事实袋（主线程单写者，各步骤结束统一读取 emit） */
class NotifyFacts {
  startedCount: number = 0;
  progressCount: number = 0;
  finishedCount: number = 0;
  pausedCount: number = 0;
  failedCount: number = 0;
}

@Component
export struct ProbeBackgroundNotify {
  @State baseUrl: string = DEFAULT_BASE_URL;
  private probeKit: ProbeKit = ProbeKit.getInstance();
  private facts: NotifyFacts = new NotifyFacts();
  /** 确定性 id→创建名/连接大小/最新进度（事件袋翻译 + S5 armed 快照原料） */
  private idToName: Map<string, string> = new Map();
  private idToSize: Map<string, number> = new Map();
  private idToProgress: Map<string, number> = new Map();
  /** 主会话占位识别标记：S1（仅主会话跑）置位 → S5 发占位行并复位；单步 S5 标记 false → 真实两阶段 */
  private mainSessionS1Seen: boolean = false;

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
      await this.runS5();
      return;
    }
  }

  /** S1 授权+基线+监听注册：重置会话态 → manager.init（事件袋后到者接管）→ 通知授权态/
   * 通知基线/任务基线 → continuousTaskCancel 监听注册（进程内一次）。 */
  private async runS1(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      this.resetSessionState();
      this.mainSessionS1Seen = true;
      const manager: DownloadManager = DownloadManager.getInstance();
      manager.init(this.buildListener());
      const notifyEnabled: boolean = notificationManager.isNotificationEnabledSync();
      const notifyBaseline: number = await notificationManager.getActiveNotificationCount();
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const tasks: backgroundTaskManager.ContinuousTaskInfo[] =
        await backgroundTaskManager.getAllContinuousTasks(this.requireContext());
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      this.registerCancelListener();
      const kvs: KeyValue[] = [
        new KeyValue('notifyEnabled', String(notifyEnabled)),
        new KeyValue('notifyBaseline', String(notifyBaseline)),
        new KeyValue('taskBaseline', String(tasks.length)),
        new KeyValue('taskModes', this.modesOf(tasks)),
        new KeyValue('cancelListener', 'on')
      ];
      this.probeKit.emit('S1', kvs);
    } catch (e) {
      this.emitStepError('S1', runId, e as BusinessError);
    }
  }

  /** S2 申请锚：3 条确定性 id 下载（store.add→admitNew；事件袋尾部转发已挂）→ 轮询 ≤10s 至
   * taskNotificationId()>=0 → getAllContinuousTasks 读系统侧详情（notificationId/modes/
   * abilityName）。锚点取系统注册完成点而非乐观簿记（R2-F1：isTaskApplied 在 IPC 往返前置位，
   * 其后立即读 getAllContinuousTasks 会瞬态 taskCount=0 产生假 FAIL）。 */
  private async runS2(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const ctx: common.Context = this.requireContext();
      const store: DownloadStore = DownloadStore.getInstance();
      await store.initialize(ctx);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const manager: DownloadManager = DownloadManager.getInstance();
      const notifier: ProgressNotifier = ProgressNotifier.getInstance();
      const url: string = this.joinBase('/slow.bin?ms=' + String(SLOW_MS_S2));
      let submitted: number = 0;
      for (let i = 0; i < SUBMIT_COUNT; i++) {
        const id: string = 'probe-p5u1-' + runId + '-' + String(i + 1);
        const record: DownloadRecord = newDownloadRecord('p5-' + String(i + 1) + '.bin',
          Config.getInstance().getDownloadDir(), 0, null, url, true, null, null);
        record.id = id;
        this.idToName.set(id, record.name ?? '');
        await store.add(record);
        if (!this.probeKit.isCurrent(runId)) {
          return;
        }
        submitted++;
        manager.admitNew(record);
      }
      // R2-F1：taskNotificationIdValue 仅在 startBackgroundRunning.then 簿记（真实注册完成点）；
      // isTaskApplied 是乐观守卫值（IPC 往返前置位），其后读系统任务表会有瞬态空窗
      const applied: boolean = await this.pollUntil((): boolean => notifier.taskNotificationId() >= 0,
        APPLY_TIMEOUT_MS, POLL_MS);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const tasks: backgroundTaskManager.ContinuousTaskInfo[] =
        await backgroundTaskManager.getAllContinuousTasks(this.requireContext());
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const mode0: string = tasks.length > 0 ? this.modesOf([tasks[0]]) : 'none';
      const abilityName: string = tasks.length > 0 ? tasks[0].wantAgentAbilityName : 'none';
      const kvs: KeyValue[] = [
        new KeyValue('submitted', String(submitted)),
        new KeyValue('applied', String(applied)),
        new KeyValue('notificationId', applied ? String(notifier.taskNotificationId()) : 'none'),
        new KeyValue('continuousTaskId',
          applied && notifier.continuousTaskId() >= 0 ? String(notifier.continuousTaskId()) : 'none'),
        new KeyValue('taskCount', String(tasks.length)),
        new KeyValue('mode0', mode0),
        new KeyValue('abilityName', abilityName)
      ];
      this.probeKit.emit('S2', kvs);
    } catch (e) {
      this.emitStepError('S2', runId, e as BusinessError);
    }
  }

  /** S3 实况窗观测：liveCount>0 期间 ≤10s 轮询——progressEvents delta（事件袋）+ stats
   * 累计（publishOk/publishFail/publishMsMax，D12）+ getActiveNotificationCount。 */
  private async runS3(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const manager: DownloadManager = DownloadManager.getInstance();
      const notifier: ProgressNotifier = ProgressNotifier.getInstance();
      const progressBefore: number = this.facts.progressCount;
      const beginTick: number = Date.now();
      const deadline: number = beginTick + LIVE_VIEW_WINDOW_MS;
      while (Date.now() < deadline && manager.liveCount() > 0) {
        await this.sleep(POLL_MS);
        if (!this.probeKit.isCurrent(runId)) {
          return;
        }
      }
      const stats: NotifierStats = notifier.stats();
      const notifyCount: number = await notificationManager.getActiveNotificationCount();
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const kvs: KeyValue[] = [
        new KeyValue('progressEvents', String(this.facts.progressCount - progressBefore)),
        new KeyValue('publishOk', String(stats.publishOk)),
        new KeyValue('publishFail', String(stats.publishFail)),
        new KeyValue('publishMsMax', String(stats.publishMsMax)),
        new KeyValue('notifyCount', String(notifyCount))
      ];
      this.probeKit.emit('S3', kvs);
    } catch (e) {
      this.emitStepError('S3', runId, e as BusinessError);
    }
  }

  /** S4 完成→释放锚：轮询 ≤120s 至 activeCount==0 且 getAllContinuousTasks==0 → finishedCount →
   * 通知数（完成通知在、实况窗已移除）→ cancel(finishNotifyId) → 再读计数 → 读 LastCancel
   * （系统未取消时 lastCancelReason=none）。锚点取系统侧任务表清空（R2-F1：isTaskApplied 乐观
   * 复位点早于 stopBackgroundRunning IPC 往返完成，作锚会瞬态 taskCountAfter>0 产生假 FAIL）。 */
  private async runS4(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const manager: DownloadManager = DownloadManager.getInstance();
      const notifier: ProgressNotifier = ProgressNotifier.getInstance();
      // R2-F1：released 以系统侧 getAllContinuousTasks==0 为准（真实释放完成）；
      // 下载未排空（activeCount>0）期间只睡不查，归零后开始轮询任务表直至清空或超时
      let released: boolean = false;
      let taskCountAfter: number = -1;
      const releaseBeginTick: number = Date.now();
      while (Date.now() - releaseBeginTick < RELEASE_TIMEOUT_MS) {
        if (manager.activeDownloadCount() === 0) {
          const tasksNow: backgroundTaskManager.ContinuousTaskInfo[] =
            await backgroundTaskManager.getAllContinuousTasks(this.requireContext());
          if (!this.probeKit.isCurrent(runId)) {
            return;
          }
          taskCountAfter = tasksNow.length;
          if (taskCountAfter === 0) {
            released = true;
            break;
          }
        }
        await this.sleep(POLL_MS);
      }
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const finishedCount: number = this.facts.finishedCount;
      const notifyCountWithFinish: number = await notificationManager.getActiveNotificationCount();
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const finishId: number = notifier.finishNotifyId();
      await notificationManager.cancel(finishId);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const notifyCountAfterCancel: number = await notificationManager.getActiveNotificationCount();
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const kvs: KeyValue[] = [
        new KeyValue('finishedCount', String(finishedCount)),
        new KeyValue('released', String(released)),
        new KeyValue('taskCountAfter', String(taskCountAfter)),
        new KeyValue('finishId', String(finishId)),
        new KeyValue('notifyCountWithFinish', String(notifyCountWithFinish)),
        new KeyValue('notifyCountAfterCancel', String(notifyCountAfterCancel)),
        new KeyValue('lastCancelReason', lastCancelCaught ? String(lastCancelReason) : 'none'),
        new KeyValue('lastCancelId', lastCancelCaught ? String(lastCancelId) : 'none')
      ];
      this.probeKit.emit('S4', kvs);
    } catch (e) {
      this.emitStepError('S4', runId, e as BusinessError);
    }
  }

  /** S5 分派：armed 快照空=armed 阶段；非空=survived 阶段（主会话内的占位发射经 S1 置位
   * 标记识别，不触达真实两阶段）。 */
  private async runS5(): Promise<void> {
    if (this.mainSessionS1Seen) {
      this.mainSessionS1Seen = false;
      const kvs: KeyValue[] = [
        new KeyValue('phase', 'placeholder'),
        new KeyValue('armedState', armedRecordId !== '' ? 'armed' : 'none'),
        new KeyValue('recordId', armedRecordId !== '' ? armedRecordId : 'none')
      ];
      this.probeKit.emit('S5', kvs);
      return;
    }
    if (armedRecordId === '') {
      await this.runS5Armed();
      return;
    }
    await this.runS5Survived();
  }

  /** S5-armed：重提 1 个长下载 → 轮询至 applied（taskNotificationId()>=0 真实注册完成锚，
   * R2-F1 同 S2）→ 写模块级 armed 快照 → emit。
   * manager.init 幂等（后到者接管）——S5 可在主会话之前单步执行（防御冷启动 wrapper 未挂）。 */
  private async runS5Armed(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const ctx: common.Context = this.requireContext();
      const store: DownloadStore = DownloadStore.getInstance();
      await store.initialize(ctx);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const manager: DownloadManager = DownloadManager.getInstance();
      const notifier: ProgressNotifier = ProgressNotifier.getInstance();
      manager.init(this.buildListener());
      const url: string = this.joinBase('/slow.bin?ms=' + String(SLOW_MS_S5));
      const id: string = 'probe-p5u1-' + runId + '-s5';
      const record: DownloadRecord = newDownloadRecord('p5-s5.bin',
        Config.getInstance().getDownloadDir(), 0, null, url, true, null, null);
      record.id = id;
      this.idToName.set(id, record.name ?? '');
      await store.add(record);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      manager.admitNew(record);
      // R2-F1 同 S2：申请锚取 startBackgroundRunning.then 簿记完成点（taskNotificationId()>=0），
      // 乐观守卫值 isTaskApplied 在 IPC 往返前置位，其后读系统任务表会有瞬态空窗
      const applied: boolean = await this.pollUntil((): boolean => notifier.taskNotificationId() >= 0,
        APPLY_TIMEOUT_MS, POLL_MS);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      armedRecordId = id;
      const progressAt: number | undefined = this.idToProgress.get(id);
      armedProgressAt = progressAt !== undefined ? progressAt : 0;
      const kvs: KeyValue[] = [
        new KeyValue('phase', 'armed'),
        new KeyValue('applied', String(applied)),
        new KeyValue('notificationId', applied ? String(notifier.taskNotificationId()) : 'none'),
        new KeyValue('progressAtArmed', String(armedProgressAt)),
        new KeyValue('recordId', id)
      ];
      this.probeKit.emit('S5', kvs);
    } catch (e) {
      this.emitStepError('S5', runId, e as BusinessError);
    }
  }

  /** S5-survived（第二次执行；人工走查"点 X 关窗→等 15-20s→Dock 恢复→回探针页"之后）：
   * getAllContinuousTasks（任务在否）+ store 读该 record 进度（后台推进直接观测——进度由
   * 事件袋 DB 回声镜像 Index 消费方角色写入）+ kind=Finished 判定 + 通知数 + LastCancel。
   * emit 后复位 armed 快照（下一周期可重新 armed）。 */
  private async runS5Survived(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const store: DownloadStore = DownloadStore.getInstance();
      const tasks: backgroundTaskManager.ContinuousTaskInfo[] =
        await backgroundTaskManager.getAllContinuousTasks(this.requireContext());
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const record: DownloadRecord | null = await store.getDownloadById(armedRecordId);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const progressNow: number = record !== null ? record.progress : -1;
      const downloadFinished: boolean = record !== null && record.kind === DownloadKind.Finished;
      const advanced: boolean = progressNow > armedProgressAt;
      const notifyCount: number = await notificationManager.getActiveNotificationCount();
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const kvs: KeyValue[] = [
        new KeyValue('phase', 'survived'),
        new KeyValue('taskAlive', String(tasks.length)),
        new KeyValue('progressAtArmed', String(armedProgressAt)),
        new KeyValue('progressNow', String(progressNow)),
        new KeyValue('advanced', String(advanced)),
        new KeyValue('downloadFinished', String(downloadFinished)),
        new KeyValue('recordId', armedRecordId),
        new KeyValue('notifyCount', String(notifyCount)),
        new KeyValue('lastCancelReason', lastCancelCaught ? String(lastCancelReason) : 'none')
      ];
      this.probeKit.emit('S5', kvs);
      armedRecordId = '';
    } catch (e) {
      this.emitStepError('S5', runId, e as BusinessError);
    }
  }

  // ---------- 事件袋（引擎事实采集 + DB 回声镜像 Index 消费方角色 + 尾部转发 ProgressNotifier） ----------

  private buildListener(): DownloadEvents {
    // DownloadEvents 方法签名接口禁对象字面量装配（arkts-no-untyped-obj-literals）——
    // 经 ForwardDownloadEvents 实现类闭包转发（U1.2/P2-U1/P3-U1 同证）
    return new ForwardDownloadEvents(
      (id: string): void => {
        this.facts.startedCount++;
        ProgressNotifier.getInstance().onDownloadStarted(id, this.nameOf(id));
      },
      (id: string, status: number, totalSize: number, resumable: boolean, contentType: string): void => {
        this.idToSize.set(id, totalSize);
      },
      (id: string, progress: number, instantSpeed: number, etaSeconds: number,
        downloadedBytes: number): void => {
        this.facts.progressCount++;
        this.idToProgress.set(id, progress);
        // DB 回声（Index handleProgress 的 DB 写角色镜像；引擎 500ms 门已节流，同口径逐事件写）
        DownloadStore.getInstance().updateProgress(id, progress).catch((err: BusinessError): void => {
          hilog.error(PROBE_DOMAIN, DIAG_TAG, '%{public}s', 'bag updateProgress failed errCode=' +
            String(err.code) + ' errMessage=' + (err.message ?? ''));
        });
        // 事件袋尾部转发（§0-11：page=probe 冷启动 Index 不在，探针自带同款转发）
        ProgressNotifier.getInstance().onDownloadProgress(id, this.nameOf(id), progress);
      },
      (id: string, offsetBytes: number): void => {
        this.facts.pausedCount++;
        ProgressNotifier.getInstance().onDownloadEnded(id, 'paused', offsetBytes, '');
      },
      (id: string, finalFileSize: number, filePath: string): void => {
        this.facts.finishedCount++;
        const sizeBefore: number | undefined = this.idToSize.get(id);
        const recordedSize: number = sizeBefore !== undefined ? sizeBefore : 0;
        // DB 回声（Index handleFinished 的 markAsFinished 角色镜像——kind→Finished 供 S5 读数）
        DownloadStore.getInstance().markAsFinished(id, finalFileSize, this.baseNameOf(filePath),
          this.dirNameOf(filePath)).catch((err: BusinessError): void => {
          hilog.error(PROBE_DOMAIN, DIAG_TAG, '%{public}s', 'bag markAsFinished failed errCode=' +
            String(err.code) + ' errMessage=' + (err.message ?? ''));
        });
        // Size 回退与 Index.handleFinished 尾部转发同款（Application.cs:126，recorded>0 优先）
        ProgressNotifier.getInstance().onDownloadEnded(id, 'finished',
          finishedSize(recordedSize, finalFileSize), filePath);
      },
      (id: string, errorCode: number, errorMessage: string): void => {
        this.facts.failedCount++;
        ProgressNotifier.getInstance().onDownloadEnded(id, 'failed', 0, '');
      }
    );
  }

  /** continuousTaskCancel 监听（进程内注册一次；cb 写模块级 LastCancel——跨会话存续）。
   * on 带 @throws（hvigor "Function may throw exceptions" 规则点）——try/catch 收口，注册失败
   * 保持未注册位（下一轮 S1 重试；LastCancel 未捕获时 lastCancelReason=none 属合法观测）。 */
  private registerCancelListener(): void {
    if (cancelListenerRegistered) {
      return;
    }
    try {
      backgroundTaskManager.on('continuousTaskCancel',
        (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
          lastCancelCaught = true;
          lastCancelReason = info.reason;
          lastCancelId = info.id;
        });
      cancelListenerRegistered = true;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(PROBE_DOMAIN, DIAG_TAG, '%{public}s', 'continuousTaskCancel on failed errCode=' +
        String(err.code) + ' errMessage=' + (err.message ?? ''));
    }
  }

  // ---------- 工具 ----------

  private resetSessionState(): void {
    this.facts = new NotifyFacts();
    this.idToName = new Map();
    this.idToSize = new Map();
    this.idToProgress = new Map();
  }

  private nameOf(id: string): string {
    const name: string | undefined = this.idToName.get(id);
    return name !== undefined ? name : '';
  }

  /** 全部任务的 backgroundModes 聚合（'/'+连接；空表 'none'） */
  private modesOf(tasks: backgroundTaskManager.ContinuousTaskInfo[]): string {
    const parts: string[] = [];
    for (let i = 0; i < tasks.length; i++) {
      const modes: string[] = tasks[i].backgroundModes;
      for (let j = 0; j < modes.length; j++) {
        parts.push(modes[j]);
      }
    }
    return parts.length > 0 ? parts.join('/') : 'none';
  }

  private baseNameOf(path: string): string {
    const idx: number = path.lastIndexOf('/');
    return idx >= 0 ? path.slice(idx + 1) : path;
  }

  private dirNameOf(path: string): string {
    const idx: number = path.lastIndexOf('/');
    return idx >= 0 ? path.slice(0, idx) : path;
  }

  /** 谓词轮询（P2-U2/P3-U1 pollUntil 同式，POLL_MS=100 不忙等） */
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

  /** 测试源拼接：TextInput 值去尾部斜杠 + 路由；空值回退缺省地址（ProbeQueue 同构） */
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
      Text($r('app.string.probe_p5u1_check_hint'))
        .fontSize(12)
        .opacity(0.7)
        .width('100%')
      TextInput({ text: this.baseUrl, placeholder: $r('app.string.probe_p3u1_source_hint') })
        .onChange((value: string) => {
          this.baseUrl = value;
        })
        .width('100%')
      ProbePage({
        unitId: 'P5-U1',
        pageTitle: $r('app.string.probe_p5u1_title'),
        steps: BACKGROUND_NOTIFY_STEPS,
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
