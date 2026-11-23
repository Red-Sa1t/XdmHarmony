/*
 * U5.1 通知编排核心单例（设计书 §2/§3.2/§3.3/§3.4；DownloadManager 同款 getInstance）。
 * 职责：
 *   ①长时任务申请/释放状态机（§3.2）——0→非 0 经 shouldApplyTask 申请
 *     startBackgroundRunning(context,['dataTransfer'],wantAgent)（12+ 形态，API 24 唯一可用，
 *     D1：任务书 startContinuousTask 不存在，本会话 SDK d.ts:634 核实）；归零经 shouldReleaseTask
 *     stopBackgroundRunning；stop .then 内复查 activeCount>0 竞态回补（§0-5）；乐观守卫+失败
 *     回滚防双申请（主线程串行，无真并发）。
 *   ②实况窗进度通知（系统契约，拍板②/D2）——五要素缺一即更新失败：publish 的 id 必须用
 *     startBackgroundRunning 返回的 res.notificationId（严禁自选）+ ContentType
 *     NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW + systemLiveView.typeCode=8 + SlotType.LIVE_VIEW +
 *     template={name:'downloadTemplate',data:{title,fileName,progressValue 必填}}。
 *     引擎 500ms 门直发无二次节流（D11）；进度 >10 分钟不更新系统取消任务（reason=12 属 26+
 *     detailedReason，API 24 探针只记数字）→ShowNotification 不门控实况窗更新（D6）。
 *   ③完成通知（新通道 D5）——shouldPublishFinish(Config.getShowNotification()) 门控；
 *     id=pickFinishNotificationId(taskNotificationId)（1001/1002 撞号避让，§0-10）。
 *   ④NotifierStats 诊断计数（D12，观测面非控制面）：publishOk/publishFail/publishMsMax
 *     （只统计实况窗 publish 链，§3.3；完成通知不计入）。
 * 多下载聚合（D8）：≤3 并发共享一条实况窗=最新活跃下载的文件名/进度（事件到即覆盖）。
 * 线程模型（决策 2 投影）：零 TaskPool——全部 @kit 异步 fire-and-forget（.then/.catch），
 * 不 await 不阻塞 handler；handler 尾部转发保持同步语义（不改 Index 事件处理时序，§8-3）。
 * 分层红线：零 probe import、零 [XDM_PROBE] 输出、业务日志 hilog domain 0x0000 tag
 * 'ProgressNotifier'；依赖方向 core/engine ← core/notify 单向（经 DownloadManager 单例
 * activeDownloadCount() 读面，不 import Index）。
 * 命名注记：taskNotificationIdValue/finishNotifyIdValue 等带 Value 后缀的私有字段与同名公开
 * getter 区分（ArkTS 同类成员同名冲突——设计书 §2 字段表名即 getter 面）。
 * SDK 契约注记（本会话 d.ts 核实）：NotificationContent 基本文本字段名为 normal（设计书 §2 表
 * 示意写作 basic——SDK notificationContent.d.ts:505 为准）；systemLiveView?: :554；template:
 * notificationTemplate.d.ts {name, data:Record<string,Object>}；getStringByNameSync 见
 * @ohos.resourceManager.d.ts:2454（init 装载完成通知标题，失败回退常量）。
 */

import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { wantAgent, WantAgent, Want, common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  clampProgress,
  shouldApplyTask,
  shouldReleaseTask,
  shouldPublishFinish,
  pickFinishNotificationId,
  FINISH_NOTIFY_ID_BASE
} from './NotifyAlgo';
import { DownloadManager } from '../engine/DownloadManager';
import { Config } from '../Config';

/** 业务日志面（domain 0x0000 / tag 'ProgressNotifier'；绝不输出 [XDM_PROBE]） */
const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'ProgressNotifier';

/** dataTransfer 专用实况窗 typeCode（d.ts 无枚举常量，字面量 number——设计书 §8-2） */
const LIVE_VIEW_TYPE_CODE_DATA_TRANSFER: number = 8;

/** 下载模板名（notificationManager 文档：当前仅支持 downloadTemplate） */
const DOWNLOAD_TEMPLATE_NAME: string = 'downloadTemplate';

/** 完成通知标题回退值（资源键 notify_finished_title 装载失败时；string.json base 同值） */
const FINISHED_TITLE_FALLBACK: string = 'Download finished';

/** publish 诊断计数（D12 观测面；仅探针/诊断消费） */
export interface NotifierStats {
  publishOk: number;
  publishFail: number;
  publishMsMax: number;
}

export class ProgressNotifier {
  private static instance: ProgressNotifier | undefined = undefined;

  /** startBackgroundRunning/stopBackgroundRunning/publish/wantAgent 的 context
   * （Stage 模型仅 UIAbility 可申请；EntryAbility.init 传入） */
  private context: common.UIAbilityContext | undefined = undefined;
  /** 长时任务申请态（全应用单实例硬约束：一个 UIAbility 同一时刻仅一个长时任务） */
  private taskAppliedState: boolean = false;
  /** 系统代建实况窗通知 id（res.notificationId；未申请=-1）——publish 更新与防御性 cancel
   * 都用系统返回值，严禁自选 */
  private taskNotificationIdValue: number = -1;
  /** 长时任务 id（15+ 可选字段，返回 undefined 记 -1；API 24 的 stop 走 context 全量取消） */
  private continuousTaskIdValue: number = -1;
  /** 完成通知 id（1001，系统返回撞号则 1002——pickFinishNotificationId） */
  private finishNotifyIdValue: number = FINISH_NOTIFY_ID_BASE;
  /** 最新活跃下载文件名（D8 聚合展示；空串不覆盖） */
  private latestFileNameValue: string = '';
  /** 最新实况窗进度（已钳位） */
  private latestProgressValue: number = 0;
  /** 完成通知标题（init 装载，失败回退 FINISHED_TITLE_FALLBACK） */
  private finishedTitle: string = FINISHED_TITLE_FALLBACK;
  /** 实况窗 publish 成功计数（D12） */
  private publishOkCount: number = 0;
  /** 实况窗 publish 失败计数（D12；1600004 通知未授权等——任务与下载继续） */
  private publishFailCount: number = 0;
  /** 实况窗 publish 单次最大耗时 ms（D12） */
  private publishMsMaxValue: number = 0;

  private constructor() {
  }

  static getInstance(): ProgressNotifier {
    if (ProgressNotifier.instance === undefined) {
      ProgressNotifier.instance = new ProgressNotifier();
    }
    return ProgressNotifier.instance;
  }

  /** 应用初始化（EntryAbility.onCreate 尾部调用）：存 UIAbilityContext + 装载完成通知标题
   * （getStringByNameSync 失败回退常量——幂等，重复调用无害）。 */
  init(context: common.UIAbilityContext): void {
    this.context = context;
    try {
      this.finishedTitle = context.resourceManager.getStringByNameSync('notify_finished_title');
    } catch (e) {
      const err = e as BusinessError;
      this.finishedTitle = FINISHED_TITLE_FALLBACK;
      hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s',
        'init getStringByNameSync failed errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
    }
  }

  /** 2026-11-23：语言变化（应用内切换或跟随系统时系统语言变化）后重读完成通知标题 */
  reloadLabels(): void {
    if (this.context !== undefined) {
      this.init(this.context);
    }
  }

  // ---------- 事件转发面（Index 五 handler 尾部/探针事件袋尾部调用，同步不阻塞） ----------

  /** 下载起跑（handleStarted 尾部）：D8 覆盖最新文件名 + 0→非 0 申请锚。 */
  onDownloadStarted(id: string, fileName: string): void {
    if (fileName.length > 0) {
      this.latestFileNameValue = fileName;
    }
    this.applyTask();
  }

  /** 进度事件（handleProgress 尾部）：D8 覆盖最新文件名/进度 + 实况窗 publish 直发
   * （引擎 500ms 门已节流，无二次节流 D11）。任务未在申请态时跳过 publish（无系统 id 可挂——
   * 申请失败重试挂在下一个 started/ended 事件上，§3.2 注②）。 */
  onDownloadProgress(id: string, fileName: string, progress: number): void {
    if (fileName.length > 0) {
      this.latestFileNameValue = fileName;
    }
    const clamped: number = clampProgress(progress);
    this.latestProgressValue = clamped;
    if (this.taskAppliedState && this.taskNotificationIdValue >= 0) {
      this.publishProgress(this.taskNotificationIdValue, this.latestFileNameValue, clamped);
    }
  }

  /** 下载终态（handlePaused/Failed/Finished 尾部；kind 字面量联合——设计书 §1-#8 签名）：
   * finished → 完成通知（门控）；随后归零释放判定（activeCount 经 DownloadManager 读面，
   * 补位 dequeueOne 已在 delegate 之后执行，读数已含补位结果，§3.4）。 */
  onDownloadEnded(id: string, kind: 'paused' | 'failed' | 'finished', finalFileSize: number,
    filePath: string): void {
    if (kind === 'finished') {
      this.publishFinishNotification(filePath);
    }
    if (shouldReleaseTask(DownloadManager.getInstance().activeDownloadCount(), this.taskAppliedState)) {
      this.releaseTask();
    }
  }

  // ---------- 观测面（探针/诊断消费；非控制面） ----------

  /** 长时任务申请态 */
  isTaskApplied(): boolean {
    return this.taskAppliedState;
  }

  /** 系统代建实况窗通知 id（未申请=-1） */
  taskNotificationId(): number {
    return this.taskNotificationIdValue;
  }

  /** 长时任务 id（未申请/返回 undefined=-1） */
  continuousTaskId(): number {
    return this.continuousTaskIdValue;
  }

  /** 完成通知 id（1001/1002）——探针 S4 cancel 用 */
  finishNotifyId(): number {
    return this.finishNotifyIdValue;
  }

  /** 最新活跃下载文件名（D8） */
  latestFileName(): string {
    return this.latestFileNameValue;
  }

  /** 最新实况窗进度（已钳位） */
  latestProgress(): number {
    return this.latestProgressValue;
  }

  /** publish 诊断计数快照（D12；只统计实况窗 publish 链） */
  stats(): NotifierStats {
    const stats: NotifierStats = {
      publishOk: this.publishOkCount,
      publishFail: this.publishFailCount,
      publishMsMax: this.publishMsMaxValue
    };
    return stats;
  }

  // ---------- 私有实现（申请/释放状态机 + 通知构造） ----------

  /** 申请路径（§3.2）：shouldApplyTask 门 → 乐观置位防同帧重复申请 → wantAgent →
   * startBackgroundRunning(['dataTransfer']) → 簿记系统返回 id；失败回滚挂 .catch
   * （下次 started/ended 事件重试，不加定时器——9800005 类验证失败重试同样失败，
   * 事件驱动收敛即可）。 */
  private applyTask(): void {
    const ctx = this.context;
    if (ctx === undefined) {
      return;
    }
    if (!shouldApplyTask(DownloadManager.getInstance().activeDownloadCount(), this.taskAppliedState)) {
      return;
    }
    this.taskAppliedState = true;
    const want: Want = {
      bundleName: 'com.neuohos.xdm',
      abilityName: 'EntryAbility'
    };
    const wants: Array<Want> = [want];
    // requestCode 必填（SDK wantAgent/wantAgentInfo.d.ts:105——hvigor 编译期强制 10505001；
    // 编码期只读 :53 处 wants 漏看 :105——本会话纠偏）。0=不指定跳转请求码的惯例缺省。
    // actionType 必填于长时任务：缺省时 startBackgroundRunning 拒收为 401 Invalid input parameter
    // （2026-10-18 真机 P5-U1 S2 实证，applied=false/taskCount=0）；与官方长时任务示例同形。
    const info: wantAgent.WantAgentInfo = {
      wants: wants,
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    wantAgent.getWantAgent(info).then((agent: WantAgent): Promise<backgroundTaskManager.ContinuousTaskNotification> => {
      return backgroundTaskManager.startBackgroundRunning(ctx, ['dataTransfer'], agent);
    }).then((res: backgroundTaskManager.ContinuousTaskNotification): void => {
      // 簿记系统返回值（严禁自选 notificationId——实况窗 publish 契约五要素之一）
      this.taskNotificationIdValue = res.notificationId;
      this.continuousTaskIdValue = res.continuousTaskId !== undefined ? res.continuousTaskId : -1;
      this.finishNotifyIdValue = pickFinishNotificationId(res.notificationId);
      // 真实簿记（独立复核 medium 修复）：乐观置位早于 IPC——若 apply 在途时最后一个下载走完，
      // releaseTask 先跑（复位簿记+对未建任务 stop），apply 完成后系统持孤儿任务（实况窗冻结、
      // 任务泄漏至 10 分钟系统回收、下次 apply 撞 9800007）。此处补真实 applied=true 并做对称
      // 释放判定，闭合 apply/release 双向异步窗口
      this.taskAppliedState = true;
      if (shouldReleaseTask(DownloadManager.getInstance().activeDownloadCount(), true)) {
        this.releaseTask();
      }
      hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'continuous task applied notificationId=' +
        String(res.notificationId) + ' continuousTaskId=' + String(this.continuousTaskIdValue));
    }).catch((err: BusinessError): void => {
      // 失败回滚（乐观守卫撤销）：下次 started/ended 事件重试（§3.2 注②）
      this.taskAppliedState = false;
      this.taskNotificationIdValue = -1;
      this.continuousTaskIdValue = -1;
      hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s', 'continuous task apply failed errCode=' +
        String(err.code) + ' errMessage=' + (err.message ?? ''));
    });
  }

  /** 释放路径（§3.2）：先落簿记防释放窗口内新申请被吞 → stopBackgroundRunning（API 24 走
   * context 全量取消）→ .then 内防御性 cancel 实况窗（系统大概率已代删，catch 忽略）+
   * 竞态回补（activeCount>0 重走申请路径——归零判定与补位 dequeueOne 之间异步窗口闭合）；
   * .catch 只记日志（taskApplied 已复位，下次事件重试）。 */
  private releaseTask(): void {
    const ctx = this.context;
    if (ctx === undefined) {
      return;
    }
    const oldNotificationId: number = this.taskNotificationIdValue;
    this.taskAppliedState = false;
    this.taskNotificationIdValue = -1;
    this.continuousTaskIdValue = -1;
    backgroundTaskManager.stopBackgroundRunning(ctx).then((): void => {
      if (DownloadManager.getInstance().activeDownloadCount() > 0) {
        // 竞态回补优先（独立复核 low 修复）：直接重走申请路径并跳过防御性 cancel——系统可能
        // 复用同一 notificationId，先 cancel 会误删新任务实况窗（500ms publish 可自愈但瞬态可见）
        this.applyTask();
        return;
      }
      notificationManager.cancel(oldNotificationId).catch((cancelErr: BusinessError): void => {
        // 防御性删实况窗失败忽略（系统大概率已随任务取消代删）
        hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'defensive cancel ignored errCode=' +
          String(cancelErr.code));
      });
    }).catch((err: BusinessError): void => {
      hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s', 'continuous task release failed errCode=' +
        String(err.code) + ' errMessage=' + (err.message ?? ''));
    });
  }

  /** 实况窗 publish（§3.3）：五要素请求 + 诊断计数（Date.now 差值 msMax）。 */
  private publishProgress(notificationId: number, fileName: string, progress: number): void {
    const beginTick: number = Date.now();
    const request: notificationManager.NotificationRequest =
      this.buildProgressRequest(notificationId, fileName, progress);
    notificationManager.publish(request).then((): void => {
      this.publishOkCount++;
      const cost: number = Date.now() - beginTick;
      if (cost > this.publishMsMaxValue) {
        this.publishMsMaxValue = cost;
      }
    }).catch((err: BusinessError): void => {
      // 1600004 通知未授权等——契约不受影响，任务与下载继续
      this.publishFailCount++;
      hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'live view publish failed errCode=' +
        String(err.code) + ' errMessage=' + (err.message ?? ''));
    });
  }

  /** 实况窗五要素请求（§2 表左列；缺一即更新失败）：
   * ①id=系统返回 notificationId ②NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW ③systemLiveView
   * .typeCode=8 ④SlotType.LIVE_VIEW ⑤template={name:'downloadTemplate',data:{title,
   * fileName,progressValue}}。逐字面量显式类型标注（arkts-no-untyped-obj-literals；
   * Record 字面量引号键）。 */
  private buildProgressRequest(notificationId: number, fileName: string,
    progress: number): notificationManager.NotificationRequest {
    const liveView: notificationManager.NotificationSystemLiveViewContent = {
      typeCode: LIVE_VIEW_TYPE_CODE_DATA_TRANSFER,
      title: fileName,
      text: String(progress) + '%'
    };
    const content: notificationManager.NotificationContent = {
      notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
      systemLiveView: liveView
    };
    const data: Record<string, Object> = {
      'title': fileName,
      'fileName': fileName,
      'progressValue': progress
    };
    const template: notificationManager.NotificationTemplate = {
      name: DOWNLOAD_TEMPLATE_NAME,
      data: data
    };
    const request: notificationManager.NotificationRequest = {
      id: notificationId,
      notificationSlotType: notificationManager.SlotType.LIVE_VIEW,
      content: content,
      template: template
    };
    return request;
  }

  /** 完成通知（D5 新通道，§3.4）：shouldPublishFinish 门控（D6——只门完成通知）→
   * 基本文本请求（title=finishedTitle 资源键，text=文件名 basename；filePath 空（防御）回退
   * 最新活跃文件名）。 */
  private publishFinishNotification(filePath: string): void {
    if (!shouldPublishFinish(Config.getInstance().getShowNotification())) {
      return;
    }
    const name: string = this.finishFileNameOf(filePath);
    const basic: notificationManager.NotificationBasicContent = {
      title: this.finishedTitle,
      text: name
    };
    const content: notificationManager.NotificationContent = {
      notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
      normal: basic
    };
    const request: notificationManager.NotificationRequest = {
      id: this.finishNotifyIdValue,
      content: content
    };
    notificationManager.publish(request).catch((err: BusinessError): void => {
      hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'finish publish failed errCode=' +
        String(err.code) + ' errMessage=' + (err.message ?? ''));
    });
  }

  /** 完成通知文件名（filePath basename；Index.baseNameOf 同款；空路径防御回退最新活跃名） */
  private finishFileNameOf(filePath: string): string {
    const idx: number = filePath.lastIndexOf('/');
    const name: string = idx >= 0 ? filePath.slice(idx + 1) : filePath;
    return name.length > 0 ? name : this.latestFileNameValue;
  }
}
