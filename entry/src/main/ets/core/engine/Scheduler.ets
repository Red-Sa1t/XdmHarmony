/*
 * U3.2 定时启停调度器（设计书 §2.4/§3.3/§5.8；Scheduler.cs 逐字状态机）。
 * 单例 + 常驻（EntryAbility.onCreate 启动——对照 ApplicationCore.cs:64 初始化序列调
 * StartScheduler :597-601："核心初始化即启动"，非 UI 页加载时；源为 ApplicationCore 持有字段，
 * ArkTS 侧单例化+tickCount 观测面为新增 D14）。
 *
 * 状态机逐字锚（Scheduler.cs）：
 *   :28-31  Start=Timer(OnTimer,null,0,60000) → setInterval(60000)+start() 立即首扫（dueTime:0
 *           等价）；start() 幂等（源 Start() 重复调用泄漏 Timer 不复刻，D9）
 *   :33-41  Stop/Dispose 均 timer.Dispose → stop()=clearInterval 合一
 *   :58-63  end 边界先判先 return：无条件 activeSchedules.Remove（不查成员资格）+ StopDownloads
 *           ——用户手动开的下载到点同样被停（次序铁律：start==end 时 start 分支永不触达，§0-9）
 *   :65-82  start 边界后判：activeSchedules 查重门 → Add → ResumeDownload(nonInteractive:true)
 *   :85-103 ProcessScheduledItem：Schedule!=null 门 + DayOfWeek 位匹配链（:92-98）
 *   :105-107 HasFlag：(d1 & d2) == d2 逐字（ScheduleAlgo.matchesDay）
 *   :110-117 OnTimer：逐队列 ProcessScheduledItem → 单 Config 调度配置（D6 宿主降级）
 *
 * 作用域与分层（设计书 D6/D10/D11）：
 *  - 源 Schedule 挂 DownloadQueue 实体（queues.db per-queue）→ 暂挂 Config 六键 + 作用域=
 *    DownloadStore.queryInProgress() 全部未完成行（默认队列 DownloadIds 等价物，含历史探针行
 *    ——stopOne/resumeOne 幂等 no-op 无害）；队列实体（U4）落地时迁移回 per-queue，ScheduleAlgo
 *    纯函数面零改动。
 *  - **零 DB 写**（queryInProgress 只读；DB 写仍全在事件消费方——U2.x 分层纪律）；
 *  - 零 probe import、零 [XDM_PROBE] 输出（业务日志 hilog domain 0x0000 tag 'Scheduler'，
 *    只记异常路径与边界动作计数 info）。
 *
 * 定时器纪律（设计书 §3.3 同步决策）：setInterval 回调内绝不 await——onTick 为同步入口
 * （tickCounter++/scheduleEnabled 门/day 位匹配/分钟双边界，纯内存计算），命中边界即调
 * stopAllAsync()/resumeAllAsync()（queryInProgress await 后逐 id 动作）fire-and-forget +
 * .catch(log)。重入风险：60s 周期 vs 一次 DB 读（毫秒级）重叠概率可忽略；即使重叠，
 * stopOne/resumeOne 幂等（live/queued 成员资格门）+ activeSchedules 查重门，无重复动作后果。
 * 60s 采样漏分钟=源同行为不补偿（D9）。manager 全方法同步无 await 的 U3.1 承诺不受影响
 * （Scheduler 是新调用方，非 manager 改动）。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  minutesOfDay,
  weekDayBitOf,
  matchesDay,
  scheduledBoundary,
  BOUNDARY_END,
  BOUNDARY_START
} from './ScheduleAlgo';
import { DownloadManager } from './DownloadManager';
import { DownloadStore } from '../db/DownloadStore';
import { DownloadRecord } from '../../model/DownloadRecord';
import { Config } from '../Config';

/** 业务日志面（domain 0x0000 / tag 'Scheduler'；只记异常路径与边界动作计数） */
const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'Scheduler';
/** 调度配置查重键（源 item.ID 等价物——D6 单 Config 调度配置下恒 'default'） */
const SCHEDULE_KEY: string = 'default';

export class Scheduler {
  private static instance: Scheduler | undefined = undefined;

  /** Timer? timer（:12）；-1=未武装（start 幂等判据） */
  private timerId: number = -1;
  /** HashSet<string> activeSchedules（:13）——start 边界查重（end 无条件 Remove 不查成员 :61；
   * 单调度配置下键恒 SCHEDULE_KEY） */
  private activeSchedules: Set<string> = new Set<string>();
  /** tick 计数（观测面 D14——探针区分"边界未匹配"与"定时器死"；源无对应物） */
  private tickCounter: number = 0;
  /** tick 时钟复用实例（@performance/reuse-date-instances-check：定时器回调内禁 new Date——
   * 每 tick setTime(Date.now()) 取新鲜时间；主线程串行无重入别名风险） */
  private readonly tickClock: Date = new Date();

  private constructor() {
  }

  static getInstance(): Scheduler {
    if (Scheduler.instance === undefined) {
      Scheduler.instance = new Scheduler();
    }
    return Scheduler.instance;
  }

  /** Start()（:28-31 dueTime:0 等价）：立即首扫（同步 onTick）+ 60s 节拍；幂等防 Timer 泄漏
   * （源 Start() 重复调用泄漏不复刻，D9）。 */
  start(): void {
    if (this.timerId >= 0) {
      return;
    }
    this.onTick(this.sampleTickClock());
    this.timerId = setInterval((): void => {
      this.onTick(this.sampleTickClock());
    }, 60000);
  }

  /** tick 时间取样：复用实例 setTime（每 tick 新鲜时间——对照源 OnTimer/StartOrStopItem 各读
   * DateTime.Now 的语义保真；D7 分钟粒度） */
  private sampleTickClock(): Date {
    this.tickClock.setTime(Date.now());
    return this.tickClock;
  }

  /** Stop/Dispose 合一（:33-41 timer.Dispose）；activeSchedules 不清（源同貌——Set 生命周期
   * 随实例；重 start 后查重语义连续）。 */
  stop(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  isRunning(): boolean {
    return this.timerId >= 0;
  }

  /** 观测面（D14）：自实例创建以来的 tick 总数（含 scheduleEnabled=false 的早退 tick） */
  tickCount(): number {
    return this.tickCounter;
  }

  /** OnTimer（:110-117→ProcessScheduledItem :85-103）：同步入口——scheduleEnabled 门（:87
   * queue.Schedule != null 的布尔化等价，D6）→ day 位匹配链（:92-98 + HasFlag :105-107）→
   * startOrStopItem。纯内存计算，绝不 await。tick 时间由定时器回调一次取样下传（对照源
   * OnTimer→StartOrStopItem 各读 DateTime.Now——同 tick 内毫秒级差在分钟粒度下等价，D7）。 */
  private onTick(now: Date): void {
    this.tickCounter++;
    if (!Config.getInstance().getScheduleEnabled()) {
      return;
    }
    const dayBit: number = weekDayBitOf(now.getDay());
    if (!matchesDay(Config.getInstance().getScheduleDays(), dayBit)) {
      return;
    }
    this.startOrStopItem(now);
  }

  /** StartOrStopItem（:43-82 逐字次序）：end 先判先 return（无条件 Remove+stop）；start 后判
   * （查重门→Add→resume）。分钟粒度比较（:45-50 h/m 分离 ⇔ 分钟数相等，D7）。 */
  private startOrStopItem(now: Date): void {
    const nowMinutes: number = minutesOfDay(now.getHours(), now.getMinutes());
    const boundary: number = scheduledBoundary(nowMinutes,
      Config.getInstance().getScheduleStartMinutes(), Config.getInstance().getScheduleEndMinutes());
    if (boundary === BOUNDARY_END) {
      // :58-63 end 先判先 return（§0-9：start==end 时 start 分支永不触达——pausedEcho/resumedEcho
      // 探针判定锚）
      this.stopAllAsync();
      this.activeSchedules.delete(SCHEDULE_KEY);
      return;
    }
    if (boundary === BOUNDARY_START) {
      // :65-82 查重门
      if (this.activeSchedules.has(SCHEDULE_KEY)) {
        return;
      }
      this.activeSchedules.add(SCHEDULE_KEY);
      this.resumeAllAsync();
    }
  }

  /** StopDownloads :347-380 逐 id 等价（D10 作用域=queryInProgress 全部未完成行；D11 单次读表；
   * closeProgressWindow:true 不复刻 D12）。
   * 两趟次序（queued 先、live 后）：manager 的 onPaused 回声时点补位（U3.1 §3.3——echo 内同步
   * dequeueOne）是单栈级联——若先停 live，回声补位会立刻起跑仍在队列的待停项（起跑-再停的
   * 无谓翻转，pausedEcho 虚增）。排队项先行清退（queued 分支摘除不补位，P3-U1 S4 实测锚）后，
   * live 停止的回声补位面对空队列 no-op——"停全部"语义一步到位，对照源码 StopDownloads 意图。 */
  private stopAllAsync(): void {
    DownloadStore.getInstance().queryInProgress().then((records: DownloadRecord[]) => {
      let stopped: number = 0;
      const manager: DownloadManager = DownloadManager.getInstance();
      // 第一趟：排队项清退（摘除不补位）
      for (let i = 0; i < records.length; i++) {
        const id: string = records[i].id;
        if (manager.isQueued(id)) {
          manager.stopOne(id);
          stopped++;
        }
      }
      // 第二趟：live 停止（回声补位对空队列 no-op）
      for (let i = 0; i < records.length; i++) {
        const id: string = records[i].id;
        if (manager.isLive(id)) {
          manager.stopOne(id);
          stopped++;
        }
      }
      hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s',
        'scheduled stop applied=' + String(stopped) + ' scanned=' + String(records.length));
    }).catch((err: BusinessError) => {
      hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s',
        'stopAll failed errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
    });
  }

  /** ResumeDownload(dict, nonInteractive:true) :250-324 逐 id 等价（D11 单次读表直用，源为队列
   * 清单+逐 id GetDownloadById 两轮读取——数据等价）；幂等守卫/门判定超门入队 Waiting 全在
   * manager.resumeOne；nonInteractive=true 落 QueuedEntry/LiveSlot 预留字段（:251/:324，D13——
   * UI 效果 Phase 4 消费）。 */
  private resumeAllAsync(): void {
    DownloadStore.getInstance().queryInProgress().then((records: DownloadRecord[]) => {
      const manager: DownloadManager = DownloadManager.getInstance();
      // 启动分钟竞态防御（独立复核 medium）：EntryAbility 的 Scheduler.start() 早于 UI 侧
      // manager.init()——此刻逐 id resumeOne 会全部落 'init not called' 被丢弃，而 activeSchedules
      // 已入册把后续每个 start 边界 tick 吞掉，整个调度窗静默丢失。回滚查重门留待下一 tick 重入
      //（60s 后 UI 必已就绪），最坏延迟一个采样周期
      if (!manager.isReady()) {
        this.activeSchedules.delete(SCHEDULE_KEY);
        hilog.warn(LOG_DOMAIN, LOG_TAG, '%{public}s',
          'scheduled resume deferred: manager not initialized, will retry next tick');
        return;
      }
      for (let i = 0; i < records.length; i++) {
        manager.resumeOne(records[i], true);
      }
      hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s',
        'scheduled resume applied=' + String(records.length));
    }).catch((err: BusinessError) => {
      hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s',
        'resumeAll failed errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
    });
  }
}
