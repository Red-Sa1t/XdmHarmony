/*
 * U3.2 探针单元：P3-U2 限速+定时调度探针（设计书 §6 四步步骤表）。
 * 会话模型：**单会话自动 S1→S4**（四步全 autoRun；人工仅启动主机测试源+填 IP 后点"运行全部"；
 * S3 含 60~120s 分钟边界等待，手册注明总时长 ≈4 分钟）。
 *   S1 参数装配+源预检（快照 Config 六项原值→应用 setSpeedLimit(true,1024)/setMaxSegments(1)→
 *      manager.init(events,hooks)→单例基线→自建 requestInStream GET /big.bin + Range: bytes=0-0，
 *      不走引擎——ProbeQueue S1 同构）
 *   S2 限速速率区间观测（引擎直驱：new Downloader 单分段 4MiB@1024KB/s——maxSegments=1 时
 *      COLD-F1 对可续传源直派单片闭窗，activeSegmentMax=1 必然；onProgress 采样 instantSpeed
 *      与 activeSegmentCount，完成后读 dl.throttleStats()——sleepCount/sleepTotalMs/
 *      peakQueuedBytes/burstReopenCount 区分背压形态，观测事实不判 PASS/FAIL）
 *   S3 定时窗停止观测（maxParallel=1 提交 3 个 /slow.bin?ms=2500=1 live+2 queued；目标分钟=
 *      当前+2 且 start==end（§0-9：end 先判防 start 误触——resumedEcho=0 佐证）；daysMask=
 *      今日位；Scheduler stop+start 重定相位（立即首扫+60s 节拍已知相位）→轮询 live/queued
 *      归零（210s 超时；slow.bin?ms=2500 单片 64 块×2.5s≈160s > 边界最晚 120s，live 必在界内）
 *   S4 环境恢复（S1 快照回写四组 setter + Scheduler 保运行 + 读回校验）
 * 驱动模型（设计书 §6）：S2 只调引擎公开面（new Downloader+观测 getter）；S3 只调业务公开 API
 * （DownloadManager/DownloadStore/Config/Scheduler）。观测值只写事实不写 PASS/FAIL（速率 ±30% 窗
 * 判定在 EXPECT/verify）。事件袋：S2 引擎直驱独立事件袋（ForwardDownloadEvents 事实袋）+ S1
 * manager.init 后到者接管（S3 消费；hooks 计数 onQueuedCancelled——S3 queuedCancelledEcho）。
 * 会话纪律：manager.init 后到者接管（U3.1 §0-9 同款手册注记——会话内不切页）。
 * 确定性 id：probe-p3u2-<runId>-<i>（store.add 前覆盖 record.id——COLD-F1 约定）；
 * DB 行每轮 +4，与既有探针同口径不清理。
 */

import { http } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ProbeKit, KeyValue } from '../core/ProbeKit';
import { ProbePage, ProbeStepDef } from '../core/ProbePage';
import { Downloader, DownloadEvents, ForwardDownloadEvents } from '../../core/engine/Downloader';
import { DownloadManager, ManagerHooks } from '../../core/engine/DownloadManager';
import { Scheduler } from '../../core/engine/Scheduler';
import { minutesOfDay, weekDayBitOf } from '../../core/engine/ScheduleAlgo';
import { DownloadRecord, newDownloadRecord } from '../../model/DownloadRecord';
import { DownloadStore } from '../../core/db/DownloadStore';
import { Config } from '../../core/Config';

/** 测试源缺省地址（手册"可替换参数"占位值；真机/模拟器填主机局域网 IP，禁 127.0.0.1） */
const DEFAULT_BASE_URL: string = 'http://127.0.0.1:8081';

/** S2 限速限额（KB/s，手册可替换；±30% 判定窗 [716.8,1331.2] 随之换算） */
const LIMIT_KBPS: number = 1024;

/** S3 长活源慢参数（/slow.bin?ms=2500——64 块×2.5s≈160s > 边界最晚 120s，live 必在界内；
 * ms 由探针 URL 参数携带，server 零改动） */
const SLOW_MS: number = 2500;

/** S3 目标分钟偏移（当前+2，mod 1440；60s 节拍恰一拍落入目标分钟宽 60s 窗口） */
const BOUNDARY_OFFSET_MIN: number = 2;

/** S3 提交数（maxParallel=1 下 1 live+2 queued） */
const S3_SUBMIT: number = 3;

/** S2 引擎直驱完成超时（4MiB@1024KB/s≈4s，60s 预算冗余）/ S3 边界+排空超时 / 轮询周期 */
const S2_TIMEOUT_MS: number = 60000;
const S3_TIMEOUT_MS: number = 210000;
const POLL_MS: number = 100;

/** S1 源预检 dataEnd 兜底超时 */
const SOURCE_TIMEOUT_MS: number = 15000;

/** 步骤定义表：四步全 autoRun（单会话自动 S1→S4） */
const SPEED_LIMIT_STEPS: ProbeStepDef[] = [
  { stepNo: 'S1', title: '参数装配+源预检', autoRun: true },
  { stepNo: 'S2', title: '限速速率区间观测', autoRun: true },
  { stepNo: 'S3', title: '定时窗停止观测', autoRun: true },
  { stepNo: 'S4', title: '环境恢复', autoRun: true }
];

/** Config 快照（S1 落、S4 回写；六项日志面+start/end 回写暗量） */
class ConfigSnapshot {
  enableSpeedLimit: boolean = false;
  defaultDownloadSpeed: number = 0;
  maxSegments: number = 0;
  maxParallelDownloads: number = 0;
  scheduleEnabled: boolean = false;
  scheduleStartMinutes: number = 0;
  scheduleEndMinutes: number = 0;
  scheduleDays: number = 0;
}

/** S2 引擎直驱事实袋（独立事件面——不与 manager wrapper 共袋） */
class SpeedFacts {
  finished: boolean = false;
  finalBytes: number = 0;
  finishTick: number = 0;
  progressSamples: number = 0;
  instantMinKBs: number = 0;
  instantMaxKBs: number = 0;
  activeSegmentMax: number = 0;
}

/** manager 事件事实袋（S1 init；S3 消费——pausedEcho/resumedEcho 计数面） */
class ManagerFacts {
  startedCount: number = 0;
  pausedCount: number = 0;
  finishedCount: number = 0;
  failedCount: number = 0;
}

@Component
export struct ProbeSpeedLimit {
  @State baseUrl: string = DEFAULT_BASE_URL;
  private probeKit: ProbeKit = ProbeKit.getInstance();
  private snapshot: ConfigSnapshot = new ConfigSnapshot();
  private speedFacts: SpeedFacts = new SpeedFacts();
  private managerFacts: ManagerFacts = new ManagerFacts();
  /** 排队取消回声计数（hooks 消费面——S3 queuedCancelledEcho 原料） */
  private queuedCancelledCount: number = 0;
  private seqCounter: number = 0;

  /** 步骤分派（四步全 autoRun，无单步会话门） */
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

  /** S1 参数装配+源预检：重置会话态（重跑语义）→ 快照 Config 六项原值 → 应用探针配置
   * （setSpeedLimit(true,LIMIT_KBPS)/setMaxSegments(1)——S2 单分段口径）→ manager.init 后到者
   * 接管 → 单例基线 → 自建 requestInStream 源预检（不走引擎/业务栈）。 */
  private async runS1(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      this.resetSessionState();
      const cfg: Config = Config.getInstance();
      // 快照（S4 回写；scheduleEnabledBefore/speedBefore 入日志）
      this.snapshot.enableSpeedLimit = cfg.getEnableSpeedLimit();
      this.snapshot.defaultDownloadSpeed = cfg.getDefaultDownloadSpeed();
      this.snapshot.maxSegments = cfg.getMaxSegments();
      this.snapshot.maxParallelDownloads = cfg.getMaxParallelDownloads();
      this.snapshot.scheduleEnabled = cfg.getScheduleEnabled();
      this.snapshot.scheduleStartMinutes = cfg.getScheduleStartMinutes();
      this.snapshot.scheduleEndMinutes = cfg.getScheduleEndMinutes();
      this.snapshot.scheduleDays = cfg.getScheduleDays();
      const scheduleEnabledBefore: boolean = this.snapshot.enableSpeedLimit;
      const speedBefore: number = this.snapshot.defaultDownloadSpeed;
      // 应用探针配置（S2 单分段口径——maxSegments=1 时 share=limit 全额，D1 单段等价点）
      cfg.setSpeedLimit(true, LIMIT_KBPS);
      cfg.setMaxSegments(1);
      const manager: DownloadManager = DownloadManager.getInstance();
      manager.init(this.buildManagerListener(), this.buildHooks());
      const maxParallel: number = cfg.getMaxParallelDownloads();
      const liveBaseline: number = manager.liveCount();
      const queuedBaseline: number = manager.queuedCount();
      // 源预检：/big.bin Range bytes=0-0（限速步全速源；206=可达+Range 能力）
      const url: string = this.joinBase('/big.bin');
      let status: number = 0;
      let chunks: number = 0;
      const client: http.HttpRequest = http.createHttp();
      try {
        const endGate: Promise<void> = new Promise<void>((resolve: () => void) => {
          client.on('dataEnd', () => {
            resolve();
          });
        });
        client.on('dataReceive', (data: ArrayBuffer) => {
          chunks++;
        });
        const rangeHeader: Record<string, string> = {};
        rangeHeader['Range'] = 'bytes=0-0';
        const options: http.HttpRequestOptions = { header: rangeHeader, connectTimeout: 10000, readTimeout: 10000 };
        status = await client.requestInStream(url, options);
        if (!this.probeKit.isCurrent(runId)) {
          return;
        }
        await Promise.race([endGate, new Promise<void>((resolve: () => void) => setTimeout(resolve, SOURCE_TIMEOUT_MS))]);
        if (!this.probeKit.isCurrent(runId)) {
          return;
        }
        const kvs: KeyValue[] = [
          new KeyValue('sourceUrl', url),
          new KeyValue('limitKBps', String(LIMIT_KBPS)),
          new KeyValue('maxSegments', String(cfg.getMaxSegments())),
          new KeyValue('maxParallel', String(maxParallel)),
          new KeyValue('liveBaseline', String(liveBaseline)),
          new KeyValue('queuedBaseline', String(queuedBaseline)),
          new KeyValue('sourceStatus', String(status)),
          new KeyValue('chunks', String(chunks)),
          new KeyValue('scheduleEnabledBefore', String(scheduleEnabledBefore)),
          new KeyValue('speedBefore', String(speedBefore))
        ];
        this.probeKit.emit('S1', kvs);
      } catch (e) {
        const err = e as BusinessError;
        if (!this.probeKit.isCurrent(runId)) {
          return;
        }
        const errKvs: KeyValue[] = [
          new KeyValue('sourceUrl', url),
          new KeyValue('limitKBps', String(LIMIT_KBPS)),
          new KeyValue('liveBaseline', String(liveBaseline)),
          new KeyValue('queuedBaseline', String(queuedBaseline)),
          new KeyValue('sourceStatus', String(status)),
          new KeyValue('scheduleEnabledBefore', String(scheduleEnabledBefore)),
          new KeyValue('speedBefore', String(speedBefore)),
          new KeyValue('errCode', String(err.code)),
          new KeyValue('errMessage', err.message ?? '')
        ];
        this.probeKit.emit('S1', errKvs);
      } finally {
        client.off('dataReceive');
        client.off('dataEnd');
        client.destroy();
      }
    } catch (e) {
      this.emitStepError('S1', runId, e as BusinessError);
    }
  }

  /** S2 限速速率区间观测（引擎直驱）：确定性 id → store.add → new Downloader(record, events)
   * → dl.start() → 轮询 onFinished（60s 超时；轮询期采样 activeSegmentCount）→ 读
   * dl.throttleStats()。avgRateKBs=finalBytes/elapsed/1024（±30% 窗判定在 EXPECT）。 */
  private async runS2(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const ctx: common.Context = this.requireContext();
      const store: DownloadStore = DownloadStore.getInstance();
      await store.initialize(ctx);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const seq: number = this.nextSeq();
      const id: string = 'probe-p3u2-' + runId + '-' + String(seq);
      const record: DownloadRecord = newDownloadRecord('p3u2-speed.bin',
        Config.getInstance().getDownloadDir(), 0, null, this.joinBase('/big.bin'), true, null, null);
      record.id = id;
      await store.add(record);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      this.speedFacts = new SpeedFacts();
      const bag: SpeedFacts = this.speedFacts;
      const events: DownloadEvents = new ForwardDownloadEvents(
        (id2: string): void => {
        },
        (id2: string, status: number, totalSize: number, resumable: boolean, contentType: string): void => {
        },
        (id2: string, progress: number, instantSpeed: number, etaSeconds: number,
          downloadedBytes: number): void => {
          // instantSpeed B/s → KB/s（观测事实；min/max 采样）
          bag.progressSamples++;
          const kbs: number = Math.round(instantSpeed / 1024);
          if (bag.progressSamples === 1) {
            bag.instantMinKBs = kbs;
            bag.instantMaxKBs = kbs;
          } else {
            if (kbs < bag.instantMinKBs) {
              bag.instantMinKBs = kbs;
            }
            if (kbs > bag.instantMaxKBs) {
              bag.instantMaxKBs = kbs;
            }
          }
        },
        (id2: string, offsetBytes: number): void => {
        },
        (id2: string, finalFileSize: number, filePath: string): void => {
          bag.finished = true;
          bag.finalBytes = finalFileSize;
          bag.finishTick = Date.now();
        },
        (id2: string, errorCode: number, errorMessage: string): void => {
        }
      );
      const dl: Downloader = new Downloader(record, events);
      const beginTick: number = Date.now();
      dl.start();
      const deadline: number = beginTick + S2_TIMEOUT_MS;
      while (Date.now() < deadline) {
        if (bag.finished) {
          break;
        }
        const active: number = dl.activeSegmentCount();
        if (active > bag.activeSegmentMax) {
          bag.activeSegmentMax = active;
        }
        await this.sleep(POLL_MS);
        if (!this.probeKit.isCurrent(runId)) {
          return;
        }
      }
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const finishTick: number = bag.finished ? bag.finishTick : Date.now();
      const elapsedMs: number = finishTick - beginTick;
      const avgRateKBs: number = elapsedMs > 0
        ? Math.round(bag.finalBytes / 1024 / (elapsedMs / 1000) * 10) / 10
        : 0;
      const stats = dl.throttleStats();
      const kvs: KeyValue[] = [
        new KeyValue('bytes', String(bag.finalBytes)),
        new KeyValue('elapsedMs', String(elapsedMs)),
        new KeyValue('avgRateKBs', String(avgRateKBs)),
        new KeyValue('instantMinKBs', String(bag.instantMinKBs)),
        new KeyValue('instantMaxKBs', String(bag.instantMaxKBs)),
        new KeyValue('activeSegmentMax', String(bag.activeSegmentMax)),
        new KeyValue('sleepCount', String(stats.throttleSleepCount)),
        new KeyValue('sleepTotalMs', String(stats.throttleSleepTotalMs)),
        new KeyValue('peakQueuedBytes', String(stats.peakQueuedBytes)),
        new KeyValue('burstReopenCount', String(stats.burstReopenCount)),
        new KeyValue('finished', String(bag.finished))
      ];
      this.probeKit.emit('S2', kvs);
    } catch (e) {
      this.emitStepError('S2', runId, e as BusinessError);
    }
  }

  /** S3 定时窗停止观测：setMaxParallelDownloads(1) → 目标分钟=当前+2（start==end——§0-9 end
   * 先判防 start 误触）→ setSchedule(true,target,target,今日位) → 提交 3 个 slow.bin?ms=2500
   * （1 live+2 queued）→ Scheduler stop+start 重定相位 → 轮询 live/queued 归零（210s 超时）。
   * 回声口径：pausedEcho=onPaused 计数（live 整停）；queuedCancelledEcho=hooks 计数（排队清退）；
   * resumedEcho=onStarted 增量（start 分支未触达佐证——恒 0）。 */
  private async runS3(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const ctx: common.Context = this.requireContext();
      const store: DownloadStore = DownloadStore.getInstance();
      await store.initialize(ctx);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const cfg: Config = Config.getInstance();
      cfg.setMaxParallelDownloads(1);
      const now: Date = new Date();
      const nowMinutes: number = minutesOfDay(now.getHours(), now.getMinutes());
      const targetMinutes: number = (nowMinutes + BOUNDARY_OFFSET_MIN) % 1440;
      const dayBit: number = weekDayBitOf(now.getDay());
      // start==end：end 分支先判先 return（Scheduler.cs:58-63 次序），start 分支永不触达
      cfg.setSchedule(true, targetMinutes, targetMinutes, dayBit);
      const manager: DownloadManager = DownloadManager.getInstance();
      const url: string = this.joinBase('/slow.bin?ms=' + String(SLOW_MS));
      // 提交 3 个（1 live+2 queued——门判定在 admitNew 单调用栈内同步完成）
      for (let i = 0; i < S3_SUBMIT; i++) {
        const seq: number = this.nextSeq();
        const id: string = 'probe-p3u2-' + runId + '-' + String(seq);
        const record: DownloadRecord = newDownloadRecord('p3u2-window' + String(seq) + '.bin',
          Config.getInstance().getDownloadDir(), 0, null, url, true, null, null);
        record.id = id;
        await store.add(record);
        if (!this.probeKit.isCurrent(runId)) {
          return;
        }
        manager.admitNew(record);
      }
      const liveBefore: number = manager.liveCount();
      const queuedBefore: number = manager.queuedCount();
      // 回声基线（提交期 1 个 onStarted 已在册——resumedEcho 口径=窗口增量）
      const pausedBefore: number = this.managerFacts.pausedCount;
      const startedBefore: number = this.managerFacts.startedCount;
      const hooksBefore: number = this.queuedCancelledCount;
      const tickCountBefore: number = Scheduler.getInstance().tickCount();
      // 重定相位：立即首扫+60s 节拍（start() 幂等；旧节拍相位未知）
      Scheduler.getInstance().stop();
      Scheduler.getInstance().start();
      const beginTick: number = Date.now();
      const deadline: number = beginTick + S3_TIMEOUT_MS;
      while (Date.now() < deadline) {
        if (manager.liveCount() === 0 && manager.queuedCount() === 0) {
          break;
        }
        await this.sleep(POLL_MS);
        if (!this.probeKit.isCurrent(runId)) {
          return;
        }
      }
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const elapsedMs: number = Date.now() - beginTick;
      const pausedEcho: number = this.managerFacts.pausedCount - pausedBefore;
      const resumedEcho: number = this.managerFacts.startedCount - startedBefore;
      const queuedCancelledEcho: number = this.queuedCancelledCount - hooksBefore;
      const kvs: KeyValue[] = [
        new KeyValue('targetMinute', this.formatMinute(targetMinutes)),
        new KeyValue('dayBit', String(dayBit)),
        new KeyValue('submitted', String(S3_SUBMIT)),
        new KeyValue('liveBefore', String(liveBefore)),
        new KeyValue('queuedBefore', String(queuedBefore)),
        new KeyValue('liveAfter', String(manager.liveCount())),
        new KeyValue('queuedAfter', String(manager.queuedCount())),
        new KeyValue('pausedEcho', String(pausedEcho)),
        new KeyValue('queuedCancelledEcho', String(queuedCancelledEcho)),
        new KeyValue('resumedEcho', String(resumedEcho)),
        new KeyValue('tickCountBefore', String(tickCountBefore)),
        new KeyValue('tickCountAfter', String(Scheduler.getInstance().tickCount())),
        new KeyValue('elapsedMs', String(elapsedMs))
      ];
      this.probeKit.emit('S3', kvs);
    } catch (e) {
      this.emitStepError('S3', runId, e as BusinessError);
    }
  }

  /** S4 环境恢复：S1 快照回写四组 setter → Scheduler 保运行（生产态常驻——start() 幂等）→ 读回校验。 */
  private async runS4(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const cfg: Config = Config.getInstance();
      cfg.setSpeedLimit(this.snapshot.enableSpeedLimit, this.snapshot.defaultDownloadSpeed);
      cfg.setMaxSegments(this.snapshot.maxSegments);
      cfg.setMaxParallelDownloads(this.snapshot.maxParallelDownloads);
      cfg.setSchedule(this.snapshot.scheduleEnabled, this.snapshot.scheduleStartMinutes,
        this.snapshot.scheduleEndMinutes, this.snapshot.scheduleDays);
      Scheduler.getInstance().start();
      const kvs: KeyValue[] = [
        new KeyValue('restoredLimit', String(cfg.getDefaultDownloadSpeed())),
        new KeyValue('restoredLimitEnabled', String(cfg.getEnableSpeedLimit())),
        new KeyValue('restoredMaxSegments', String(cfg.getMaxSegments())),
        new KeyValue('restoredMaxParallel', String(cfg.getMaxParallelDownloads())),
        new KeyValue('restoredScheduleEnabled', String(cfg.getScheduleEnabled())),
        new KeyValue('schedulerRunning', String(Scheduler.getInstance().isRunning()))
      ];
      this.probeKit.emit('S4', kvs);
    } catch (e) {
      this.emitStepError('S4', runId, e as BusinessError);
    }
  }

  // ---------- 监听器（事件消费方，事实袋采集） ----------

  private buildManagerListener(): DownloadEvents {
    // DownloadEvents 方法签名接口禁对象字面量装配（arkts-no-untyped-obj-literals）——
    // 经 ForwardDownloadEvents 实现类闭包转发（ProbeQueue 同证）
    return new ForwardDownloadEvents(
      (id: string): void => {
        this.managerFacts.startedCount++;
      },
      (id: string, status: number, totalSize: number, resumable: boolean, contentType: string): void => {
        // 连接事实不入袋（S3 判定不消费）
      },
      (id: string, progress: number, instantSpeed: number, etaSeconds: number,
        downloadedBytes: number): void => {
        // 进度不入袋（观测面是集合轮询；事件量大记序会膨胀）
      },
      (id: string, offsetBytes: number): void => {
        this.managerFacts.pausedCount++;
      },
      (id: string, finalFileSize: number, filePath: string): void => {
        this.managerFacts.finishedCount++;
      },
      (id: string, errorCode: number, errorMessage: string): void => {
        this.managerFacts.failedCount++;
      }
    );
  }

  private buildHooks(): ManagerHooks {
    const hooks: ManagerHooks = {
      onQueuedCancelled: (id: string): void => {
        this.queuedCancelledCount++;
      }
    };
    return hooks;
  }

  // ---------- 工具 ----------

  private resetSessionState(): void {
    this.snapshot = new ConfigSnapshot();
    this.speedFacts = new SpeedFacts();
    this.managerFacts = new ManagerFacts();
    this.queuedCancelledCount = 0;
    this.seqCounter = 0;
  }

  private nextSeq(): number {
    this.seqCounter++;
    return this.seqCounter;
  }

  private formatMinute(minutes: number): string {
    return String(Math.floor(minutes / 60)).padStart(2, '0') + ':' +
      String(minutes % 60).padStart(2, '0');
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
      Text($r('app.string.probe_p3u2_source_hint'))
        .fontSize(12)
        .opacity(0.7)
        .width('100%')
      TextInput({ text: this.baseUrl, placeholder: $r('app.string.probe_p3u2_source_hint') })
        .onChange((value: string) => {
          this.baseUrl = value;
        })
        .width('100%')
      ProbePage({
        unitId: 'P3-U2',
        pageTitle: $r('app.string.probe_p3u2_title'),
        steps: SPEED_LIMIT_STEPS,
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
