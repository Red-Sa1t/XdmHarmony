/*
 * U1.1 探针单元：P1-U1 数据层探针（设计书 §6 步骤表）。
 * S0 Config 默认值与读写闭环 ｜ S1 建表 schema（22 列+WITHOUT ROWID）｜ S2 add 全 22 列插入
 * S3 updateProgress ｜ S4 updateStatus+读回强制规则 ｜ S5 markAsFinished+分型迁移
 * S6 getDownloadById 命中/未命中 ｜ S7 remove+计数复原
 * S8 重启持久行写入（手动）｜ S9 重启后核对（手动，pending JSON 落盘/读回）
 * 双句柄：业务 API 走 DownloadStore 单例（先 await initialize 幂等）；raw 观测走自开 RdbStore
 * 句柄（只读不写，业务先 ready 再开，同库文件 WAL 多读者安全）。
 * S8/S9 会话门：ProbePage.startSession 按数组序对全部步骤调 runStep（含 autoRun=false 步骤，
 * ProbePage.ets:76-107 无过滤）——本单元在分派层以"当前会话已发标记行数"区分（R3-F1）：自动会话
 * 触达 S8/S9 时已有 BEGIN+S0..S7 共 9 行 → 跳过（不发标记行，END steps=8）；runSingle（执行按钮）
 * 先 begin（重置行缓冲）再 runStep，入口仅 BEGIN 1 行 → 执行。runId 秒级粒度可撞号（fmtClock
 * HHmmss），不能作新会话判据。单实例 sessionRunning 守卫保证自动会话期间手动点击被脚手架忽略
 * （无孤儿 BEGIN）。
 * 会话代际守卫（U0.2 模式）：每个 runner 入口捕获 runId，每个 await 恢复后、emit 前过 isCurrent，
 * 不一致静默 return。红线：观测值只写事实不写 PASS/FAIL；S4/S9 的 statusMapped=1 是
 * "completed=0 行读回一律 Stopped"强制规则的观测事实（DownloadList.cs:95），判定在 EXPECT。
 */

import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ProbeKit, KeyValue, PROBE_DOMAIN } from '../core/ProbeKit';
import { ProbePage, ProbeStepDef } from '../core/ProbePage';
import { DownloadRecord, newDownloadRecord } from '../../model/DownloadRecord';
import { DownloadStatus } from '../../model/DownloadTypes';
import { Config, DEFAULT_MAX_RETRY } from '../../core/Config';
import { DOWNLOADS_DB_NAME, DownloadLists, DownloadStore } from '../../core/db/DownloadStore';

/** 非标记诊断行 tag：不含 "XDM_PROBE" 子串（同 ProbePage 惯例） */
const DIAG_TAG: string = 'XdmProbeStore';

/** S8/S9 持久行 pending JSON（落 <filesDir>/，S9 与人工核对消费；重按 S8 覆盖为最新行） */
const PERSIST_FILE_NAME: string = 'probe-P1-U1-persist.json';

const SQL_SCHEMA_PROBE: string = 'SELECT * FROM downloads LIMIT 0';
const SQL_MASTER_DDL: string = "SELECT sql FROM sqlite_master WHERE type='table' AND name='downloads'";
const SQL_RAW_COUNT: string = 'SELECT COUNT(*) AS cnt FROM downloads';
const SQL_RAW_BY_ID: string = 'SELECT * FROM downloads WHERE id=?';

/** 步骤定义表：S0~S7 autoRun（autoStart 自动会话），S8/S9 手动（runSingle 单步会话） */
const STORE_STEPS: ProbeStepDef[] = [
  { stepNo: 'S0', title: 'Config 默认值与读写闭环', autoRun: true },
  { stepNo: 'S1', title: '建表 schema（22 列）', autoRun: true },
  { stepNo: 'S2', title: 'add 全 22 列插入', autoRun: true },
  { stepNo: 'S3', title: 'updateProgress 直写直读', autoRun: true },
  { stepNo: 'S4', title: 'updateStatus 与读回强制规则', autoRun: true },
  { stepNo: 'S5', title: 'markAsFinished 分型迁移', autoRun: true },
  { stepNo: 'S6', title: 'getDownloadById 命中/未命中', autoRun: true },
  { stepNo: 'S7', title: 'remove 计数复原', autoRun: true },
  { stepNo: 'S8', title: '重启持久行写入（手动）', autoRun: false },
  { stepNo: 'S9', title: '重启后核对（手动）', autoRun: false }
];

/** raw 行观测值（绕过 store 映射强制规则的列上原值；text NULL → null，int NULL → 0） */
interface RawRowValues {
  rawName: string | null;
  rawStatus: number;
  rawCompleted: number;
  rawProgress: number;
  rawSize: number;
  rawDateAdded: number;
}

/** S8 落盘/S9 读回的 pending 载荷（设计书 §5.7） */
interface PersistPayload {
  id: string;
  name: string;
  size: number;
  dateAdded: number;
  progressWritten: number;
  statusWritten: number;
}

@Component
export struct ProbeStore {
  private probeKit: ProbeKit = ProbeKit.getInstance();
  /** 自开 raw 句柄（实例内缓存；重启后新页面实例自然重建） */
  private rawStore: relationalStore.RdbStore | undefined = undefined;
  /** 自动会话步骤链的当前记录 id（S2 创建，S3~S7 消费） */
  private currentId: string = '';

  /** 步骤分派 + S8/S9 会话门（见文件头注释）。
   * 门判据（R3-F1）：runId 秒级粒度可撞号（ProbeKit.fmtClock 取 HHmmss，begin 同秒重跑撞号由
   * BEGIN/END 配对吸收），不能作新会话判据；改用"当前会话已发标记行数"——ProbeKit.begin 每次重置
   * 行缓冲，自动会话触达 S8/S9 时已有 BEGIN+S0..S7 共 9 行（>1），runSingle 单步会话入口仅 BEGIN 1 行。 */
  private async runStep(stepNo: string): Promise<void> {
    if (stepNo === 'S8' || stepNo === 'S9') {
      if (this.probeKit.getLines().length > 1) {
        // 自动会话按数组序触达手动步骤：跳过（不发标记行）
        return;
      }
    }
    if (stepNo === 'S0') {
      await this.runS0();
      return;
    }
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
    if (stepNo === 'S7') {
      await this.runS7();
      return;
    }
    if (stepNo === 'S8') {
      await this.runS8();
      return;
    }
    if (stepNo === 'S9') {
      await this.runS9();
      return;
    }
  }

  /** S0 Config 默认值与读写闭环：init 幂等确认 → 3 数值键 + roundtrip(7→10) → 目录后缀 */
  private async runS0(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    const kvs: KeyValue[] = [];
    try {
      const ctx: common.Context = this.requireContext();
      Config.getInstance().init(ctx);
      const cfg: Config = Config.getInstance();
      kvs.push(new KeyValue('networkTimeout', String(cfg.getNetworkTimeout())));
      kvs.push(new KeyValue('maxRetry', String(cfg.getMaxRetry())));
      kvs.push(new KeyValue('retryDelay', String(cfg.getRetryDelay())));
      cfg.setMaxRetry(7);
      const roundtripValue: number = cfg.getMaxRetry();
      cfg.setMaxRetry(DEFAULT_MAX_RETRY);
      const restoredValue: number = cfg.getMaxRetry();
      const roundtrip: boolean = roundtripValue === 7 && restoredValue === DEFAULT_MAX_RETRY;
      kvs.push(new KeyValue('roundtrip', String(roundtrip)));
      kvs.push(new KeyValue('downloadDirSuffix', this.pathSuffix(cfg.getDownloadDir())));
      kvs.push(new KeyValue('tempDirSuffix', this.pathSuffix(cfg.getTempDir())));
    } catch (e) {
      this.pushErr(kvs, e as BusinessError);
    }
    if (!this.probeKit.isCurrent(runId)) {
      return;
    }
    this.probeKit.emit('S0', kvs);
  }

  /** S1 建表 schema：业务 ready → raw 句柄 → columnNames（LIMIT 0）+ sqlite_master 建表 SQL 尾缀 */
  private async runS1(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    const kvs: KeyValue[] = [];
    try {
      const ctx: common.Context = this.requireContext();
      await DownloadStore.getInstance().initialize(ctx);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const raw: relationalStore.RdbStore = await this.ensureRaw(ctx);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const rs: relationalStore.ResultSet = await raw.querySql(SQL_SCHEMA_PROBE);
      let columns: string = '';
      try {
        const names: Array<string> = rs.columnNames;
        columns = names.join('/');
        kvs.push(new KeyValue('colCount', String(names.length)));
      } finally {
        rs.close();
      }
      kvs.push(new KeyValue('columns', columns));
      const ddl: string = await this.readDdl(raw);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const ddlTail: string = ddl.indexOf('WITHOUT ROWID') >= 0 ? 'WITHOUT ROWID' : 'absent';
      kvs.push(new KeyValue('ddlTail', ddlTail));
    } catch (e) {
      this.pushErr(kvs, e as BusinessError);
    }
    if (!this.probeKit.isCurrent(runId)) {
      return;
    }
    this.probeKit.emit('S1', kvs);
  }

  /** S2 add 全 22 列插入：raw COUNT 前后互证 + 列上原值读回（rawCompleted=0/rawStatus=1） */
  private async runS2(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    const kvs: KeyValue[] = [];
    try {
      const ctx: common.Context = this.requireContext();
      const store: DownloadStore = DownloadStore.getInstance();
      await store.initialize(ctx);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const raw: relationalStore.RdbStore = await this.ensureRaw(ctx);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const rowsBefore: number = await this.rawCount(raw);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const id: string = 'probe-u1-' + runId;
      const record: DownloadRecord = newDownloadRecord('probe-u1-' + runId,
        Config.getInstance().getDownloadDir(), 1000, 'application/octet-stream',
        'http://probe.local/u1/' + runId, false, null, null);
      // id 链路（COLD-F1）：工厂内部恒置随机 UUID，此处覆盖为探针确定性 id（C# AddItemToTop 的
      // Id=id 直传语义，Application.cs:55）——否则落库的是后续 S3~S7 从未引用的行且 ok 旗标全 true
      record.id = id;
      const rowAdded: boolean = await store.add(record);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const rowsAfterAdd: number = await this.rawCount(raw);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const rawRow: RawRowValues | null = await this.rawRowById(raw, id);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      this.currentId = id;
      kvs.push(new KeyValue('id', id));
      kvs.push(new KeyValue('rowAdded', String(rowAdded)));
      kvs.push(new KeyValue('rowsBefore', String(rowsBefore)));
      kvs.push(new KeyValue('rowsAfterAdd', String(rowsAfterAdd)));
      kvs.push(new KeyValue('rawName', rawRow === null ? 'rowMissing' : this.textOrNull(rawRow.rawName)));
      kvs.push(new KeyValue('rawStatus', rawRow === null ? '-1' : String(rawRow.rawStatus)));
      kvs.push(new KeyValue('rawCompleted', rawRow === null ? '-1' : String(rawRow.rawCompleted)));
      kvs.push(new KeyValue('rawDateAdded', rawRow === null ? '-1' : String(rawRow.rawDateAdded)));
    } catch (e) {
      this.pushErr(kvs, e as BusinessError);
    }
    if (!this.probeKit.isCurrent(runId)) {
      return;
    }
    this.probeKit.emit('S2', kvs);
  }

  /** S3 updateProgress：progress=55 直写，raw 读回列上原值 */
  private async runS3(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    const kvs: KeyValue[] = [];
    try {
      const ctx: common.Context = this.requireContext();
      const store: DownloadStore = DownloadStore.getInstance();
      await store.initialize(ctx);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const raw: relationalStore.RdbStore = await this.ensureRaw(ctx);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const id: string = this.currentId;
      await store.updateProgress(id, 55);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const rawRow: RawRowValues | null = await this.rawRowById(raw, id);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      kvs.push(new KeyValue('id', id));
      kvs.push(new KeyValue('progressWritten', '55'));
      kvs.push(new KeyValue('progressRaw', rawRow === null ? 'rowMissing' : String(rawRow.rawProgress)));
    } catch (e) {
      this.pushErr(kvs, e as BusinessError);
    }
    if (!this.probeKit.isCurrent(runId)) {
      return;
    }
    this.probeKit.emit('S3', kvs);
  }

  /** S4 updateStatus + 读回强制规则：写 Downloading(0) → raw=0；queryInProgress 映射记录恒 Stopped(1) */
  private async runS4(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    const kvs: KeyValue[] = [];
    try {
      const ctx: common.Context = this.requireContext();
      const store: DownloadStore = DownloadStore.getInstance();
      await store.initialize(ctx);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const raw: relationalStore.RdbStore = await this.ensureRaw(ctx);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const id: string = this.currentId;
      await store.updateStatus(id, DownloadStatus.Downloading);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const rawRow: RawRowValues | null = await this.rawRowById(raw, id);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const inProgress: DownloadRecord[] = await store.queryInProgress();
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      let statusMapped: number = -1;
      for (let i = 0; i < inProgress.length; i++) {
        if (inProgress[i].id === id) {
          statusMapped = inProgress[i].status;
        }
      }
      kvs.push(new KeyValue('id', id));
      kvs.push(new KeyValue('statusWritten', String(DownloadStatus.Downloading)));
      kvs.push(new KeyValue('statusRaw', rawRow === null ? 'rowMissing' : String(rawRow.rawStatus)));
      kvs.push(new KeyValue('statusMapped', String(statusMapped)));
      kvs.push(new KeyValue('inProgressCount', String(inProgress.length)));
    } catch (e) {
      this.pushErr(kvs, e as BusinessError);
    }
    if (!this.probeKit.isCurrent(runId)) {
      return;
    }
    this.probeKit.emit('S4', kvs);
  }

  /** S5 markAsFinished + 分型迁移：completed 0→1，进行中列表 -1、全表计数不变 */
  private async runS5(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    const kvs: KeyValue[] = [];
    try {
      const ctx: common.Context = this.requireContext();
      const store: DownloadStore = DownloadStore.getInstance();
      await store.initialize(ctx);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const raw: relationalStore.RdbStore = await this.ensureRaw(ctx);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const id: string = this.currentId;
      const beforeList: DownloadRecord[] = await store.queryInProgress();
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const inProgressBefore: number = beforeList.length;
      const markOk: boolean = await store.markAsFinished(id, 1000, 'probe-u1-final.bin',
        Config.getInstance().getDownloadDir());
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const afterList: DownloadRecord[] = await store.queryInProgress();
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const inProgressAfter: number = afterList.length;
      const lists: DownloadLists = await store.queryAll();
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const allCount: number = lists.inProgress.length + lists.finished.length;
      const rawRow: RawRowValues | null = await this.rawRowById(raw, id);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      kvs.push(new KeyValue('id', id));
      kvs.push(new KeyValue('markOk', String(markOk)));
      kvs.push(new KeyValue('inProgressBefore', String(inProgressBefore)));
      kvs.push(new KeyValue('inProgressAfter', String(inProgressAfter)));
      kvs.push(new KeyValue('allCount', String(allCount)));
      kvs.push(new KeyValue('rawCompleted', rawRow === null ? '-1' : String(rawRow.rawCompleted)));
      kvs.push(new KeyValue('rawName', rawRow === null ? 'rowMissing' : this.textOrNull(rawRow.rawName)));
      kvs.push(new KeyValue('rawSize', rawRow === null ? '-1' : String(rawRow.rawSize)));
    } catch (e) {
      this.pushErr(kvs, e as BusinessError);
    }
    if (!this.probeKit.isCurrent(runId)) {
      return;
    }
    this.probeKit.emit('S5', kvs);
  }

  /** S6 getDownloadById：完成行命中（kind=1）+ 未命中返 null */
  private async runS6(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    const kvs: KeyValue[] = [];
    try {
      const ctx: common.Context = this.requireContext();
      const store: DownloadStore = DownloadStore.getInstance();
      await store.initialize(ctx);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const id: string = this.currentId;
      const found: DownloadRecord | null = await store.getDownloadById(id);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const missing: DownloadRecord | null = await store.getDownloadById('probe-u1-missing-' + runId);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      kvs.push(new KeyValue('id', id));
      kvs.push(new KeyValue('found', String(found !== null)));
      kvs.push(new KeyValue('foundKind', found === null ? '-1' : String(found.kind)));
      kvs.push(new KeyValue('foundName', found === null ? 'null' : this.textOrNull(found.name)));
      kvs.push(new KeyValue('notFoundNull', String(missing === null)));
    } catch (e) {
      this.pushErr(kvs, e as BusinessError);
    }
    if (!this.probeKit.isCurrent(runId)) {
      return;
    }
    this.probeKit.emit('S6', kvs);
  }

  /** S7 remove + 计数复原：rowsAfterRemove == S2 的 rowsBefore（remove 恰抵消 add） */
  private async runS7(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    const kvs: KeyValue[] = [];
    try {
      const ctx: common.Context = this.requireContext();
      const store: DownloadStore = DownloadStore.getInstance();
      await store.initialize(ctx);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const raw: relationalStore.RdbStore = await this.ensureRaw(ctx);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const id: string = this.currentId;
      const removeOk: boolean = await store.remove(id);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const rowsAfterRemove: number = await this.rawCount(raw);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      kvs.push(new KeyValue('id', id));
      kvs.push(new KeyValue('removeOk', String(removeOk)));
      kvs.push(new KeyValue('rowsAfterRemove', String(rowsAfterRemove)));
    } catch (e) {
      this.pushErr(kvs, e as BusinessError);
    }
    if (!this.probeKit.isCurrent(runId)) {
      return;
    }
    this.probeKit.emit('S7', kvs);
  }

  /** S8 重启持久行写入（手动单步会话）：add+updateProgress(50)+updateStatus(0) → raw 读回 → pending JSON 落盘 */
  private async runS8(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    const kvs: KeyValue[] = [];
    try {
      const ctx: common.Context = this.requireContext();
      const store: DownloadStore = DownloadStore.getInstance();
      await store.initialize(ctx);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const raw: relationalStore.RdbStore = await this.ensureRaw(ctx);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      // id 追加 epoch 毫秒后缀（R3-F1）：门修复后同一秒内可重复点 S8，纯 runId 作主键会同秒撞号
      // 冲突致 addOk=false；毫秒后缀使重复运行 id 唯一（pending JSON 每次覆盖为最新行，S9 核对最新行）
      const id: string = 'probe-u1p1-' + runId + '-' + String(Date.now());
      const name: string = 'probe-persist-' + runId;
      const record: DownloadRecord = newDownloadRecord(name, Config.getInstance().getDownloadDir(), 2000,
        'application/octet-stream', 'http://probe.local/p1/' + runId, false, null, null);
      // id 链路（COLD-F1）：同 runS2——确定性 id 必须进 record，否则 add 落库随机 UUID、
      // updateProgress/updateStatus/raw 读回/pending JSON 全部指向从未插入的行
      record.id = id;
      const addOk: boolean = await store.add(record);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const progressOk: boolean = await store.updateProgress(id, 50);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const statusOk: boolean = await store.updateStatus(id, DownloadStatus.Downloading);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const rawRow: RawRowValues | null = await this.rawRowById(raw, id);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const payload: PersistPayload = {
        id: id,
        name: name,
        size: 2000,
        dateAdded: record.dateAdded,
        progressWritten: 50,
        statusWritten: DownloadStatus.Downloading
      };
      const written: boolean = this.writePendingJson(ctx.filesDir, payload);
      kvs.push(new KeyValue('id', id));
      kvs.push(new KeyValue('addOk', String(addOk)));
      kvs.push(new KeyValue('progressOk', String(progressOk)));
      kvs.push(new KeyValue('statusOk', String(statusOk)));
      kvs.push(new KeyValue('persistenceFile', written ? PERSIST_FILE_NAME : 'writeFailed'));
      kvs.push(new KeyValue('rawProgress', rawRow === null ? 'rowMissing' : String(rawRow.rawProgress)));
      kvs.push(new KeyValue('rawStatus', rawRow === null ? 'rowMissing' : String(rawRow.rawStatus)));
    } catch (e) {
      this.pushErr(kvs, e as BusinessError);
    }
    if (!this.probeKit.isCurrent(runId)) {
      return;
    }
    this.probeKit.emit('S8', kvs);
  }

  /** S9 重启后核对（手动单步会话）：读 pending JSON → getDownloadById（映射读回）+ raw 列上原值 */
  private async runS9(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    const kvs: KeyValue[] = [];
    try {
      const ctx: common.Context = this.requireContext();
      const store: DownloadStore = DownloadStore.getInstance();
      await store.initialize(ctx);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const raw: relationalStore.RdbStore = await this.ensureRaw(ctx);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const payload: PersistPayload | null = this.readPendingJson(ctx.filesDir);
      if (payload === null) {
        // pending 缺失（首次运行/文件被清）是合法观测状态，直接出两键即返
        kvs.push(new KeyValue('pendingFound', 'false'));
        kvs.push(new KeyValue('rowFound', 'false'));
      } else {
        kvs.push(new KeyValue('pendingFound', 'true'));
        kvs.push(new KeyValue('id', payload.id));
        const record: DownloadRecord | null = await store.getDownloadById(payload.id);
        if (!this.probeKit.isCurrent(runId)) {
          return;
        }
        const rawRow: RawRowValues | null = await this.rawRowById(raw, payload.id);
        if (!this.probeKit.isCurrent(runId)) {
          return;
        }
        const rowFound: boolean = record !== null;
        const nameMatches: boolean = record !== null && record.name === payload.name;
        const sizeMatches: boolean = record !== null && record.size === payload.size;
        const dateAddedMatches: boolean = rawRow !== null && rawRow.rawDateAdded === payload.dateAdded;
        kvs.push(new KeyValue('rowFound', String(rowFound)));
        kvs.push(new KeyValue('nameMatches', String(nameMatches)));
        kvs.push(new KeyValue('sizeMatches', String(sizeMatches)));
        kvs.push(new KeyValue('dateAddedMatches', String(dateAddedMatches)));
        kvs.push(new KeyValue('rawCompleted', rawRow === null ? 'rowMissing' : String(rawRow.rawCompleted)));
        kvs.push(new KeyValue('rawProgress', rawRow === null ? 'rowMissing' : String(rawRow.rawProgress)));
        kvs.push(new KeyValue('rawStatus', rawRow === null ? 'rowMissing' : String(rawRow.rawStatus)));
        kvs.push(new KeyValue('mappedStatus', record === null ? 'rowMissing' : String(record.status)));
      }
    } catch (e) {
      this.pushErr(kvs, e as BusinessError);
    }
    if (!this.probeKit.isCurrent(runId)) {
      return;
    }
    this.probeKit.emit('S9', kvs);
  }

  // ---------- 私有工具 ----------

  private requireContext(): common.Context {
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      throw new Error('host context undefined');
    }
    return ctx;
  }

  /** 自开 raw 句柄（缓存）：业务先 ready 再开（调用方保证），只读不写。
   * hvigor throwable 检查要求 @throws API 调用点处于可接住异常的 try-catch 词法保护内
   * （调用点位于自身语句的 catch/finally 块、或仅有 try-finally 时均不视为已保护），
   * 故本文件所有 RelationalStore 调用统一 try-catch 包裹：记 errCode/errMessage 观测后原样上抛，
   * 由 runner 的 catch 收敛为该步骤 errCode 键组（行为与保护前一致）。
   * 上抛写法为 `throw err as Error`：arkts-limited-throw 只接受静态类型 Error 及其类子类，
   * BusinessError 是 interface 不可直接 throw——cast 不改变运行时对象（栈与原始诊断保留）。 */
  private async ensureRaw(context: common.Context): Promise<relationalStore.RdbStore> {
    const existing = this.rawStore;
    if (existing !== undefined) {
      return existing;
    }
    try {
      const config: relationalStore.StoreConfig = {
        name: DOWNLOADS_DB_NAME,
        securityLevel: relationalStore.SecurityLevel.S1
      };
      const rdb: relationalStore.RdbStore = await relationalStore.getRdbStore(context, config);
      this.rawStore = rdb;
      return rdb;
    } catch (e) {
      const err = e as BusinessError;
      this.logDiag('openRaw', err);
      throw err as Error;
    }
  }

  private async rawCount(raw: relationalStore.RdbStore): Promise<number> {
    let count: number = -1;
    let rs: relationalStore.ResultSet | undefined = undefined;
    try {
      rs = await raw.querySql(SQL_RAW_COUNT);
      if (rs.goToNextRow()) {
        count = rs.getLong(rs.getColumnIndex('cnt'));
      }
    } catch (e) {
      const err = e as BusinessError;
      this.logDiag('rawCount', err);
      throw err as Error;
    } finally {
      if (rs !== undefined) {
        this.closeQuietly(rs);
      }
    }
    return count;
  }

  private async rawRowById(raw: relationalStore.RdbStore, id: string): Promise<RawRowValues | null> {
    let values: RawRowValues | null = null;
    let rs: relationalStore.ResultSet | undefined = undefined;
    try {
      const args: Array<relationalStore.ValueType> = [id];
      rs = await raw.querySql(SQL_RAW_BY_ID, args);
      if (rs.goToNextRow()) {
        const row: RawRowValues = {
          rawName: this.readRawText(rs, 'name'),
          rawStatus: this.readRawInt(rs, 'status'),
          rawCompleted: this.readRawInt(rs, 'completed'),
          rawProgress: this.readRawInt(rs, 'progress'),
          rawSize: this.readRawInt(rs, 'size'),
          rawDateAdded: this.readRawInt(rs, 'date_added')
        };
        values = row;
      }
    } catch (e) {
      const err = e as BusinessError;
      this.logDiag('rawRowById', err);
      throw err as Error;
    } finally {
      if (rs !== undefined) {
        this.closeQuietly(rs);
      }
    }
    return values;
  }

  private async readDdl(raw: relationalStore.RdbStore): Promise<string> {
    let ddl: string = '';
    let rs: relationalStore.ResultSet | undefined = undefined;
    try {
      rs = await raw.querySql(SQL_MASTER_DDL);
      if (rs.goToNextRow()) {
        const idx: number = rs.getColumnIndex('sql');
        if (!rs.isColumnNull(idx)) {
          ddl = rs.getString(idx);
        }
      }
    } catch (e) {
      const err = e as BusinessError;
      this.logDiag('readDdl', err);
      throw err as Error;
    } finally {
      if (rs !== undefined) {
        this.closeQuietly(rs);
      }
    }
    return ddl;
  }

  private readRawText(rs: relationalStore.ResultSet, column: string): string | null {
    try {
      const idx: number = rs.getColumnIndex(column);
      if (rs.isColumnNull(idx)) {
        return null;
      }
      return rs.getString(idx);
    } catch (e) {
      const err = e as BusinessError;
      this.logDiag('readRawText ' + column, err);
      throw err as Error;
    }
  }

  private readRawInt(rs: relationalStore.ResultSet, column: string): number {
    try {
      const idx: number = rs.getColumnIndex(column);
      if (rs.isColumnNull(idx)) {
        return 0;
      }
      return rs.getLong(idx);
    } catch (e) {
      const err = e as BusinessError;
      this.logDiag('readRawInt ' + column, err);
      throw err as Error;
    }
  }

  /** ResultSet 关闭：close 失败吞掉（观测型句柄无后续动作）。close 在 finally 位置属 @throws
   * 调用点，也须 try-catch 词法保护（见 ensureRaw 注）。 */
  private closeQuietly(rs: relationalStore.ResultSet): void {
    try {
      rs.close();
    } catch (e) {
      // close 失败无需处理
    }
  }

  /** 探针诊断日志（非标记行，tag 不含 XDM_PROBE） */
  private logDiag(op: string, err: BusinessError): void {
    hilog.error(PROBE_DOMAIN, DIAG_TAG, '%{public}s',
      op + ' errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
  }

  private textOrNull(value: string | null): string {
    return value === null ? 'null' : value;
  }

  private pathSuffix(path: string): string {
    if (path.length === 0) {
      return 'empty';
    }
    const idx: number = path.lastIndexOf('/');
    if (idx < 0) {
      return path;
    }
    return path.slice(idx);
  }

  private writePendingJson(filesDir: string, payload: PersistPayload): boolean {
    const path: string = filesDir + '/' + PERSIST_FILE_NAME;
    try {
      const file = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, JSON.stringify(payload));
      } finally {
        fileIo.closeSync(file);
      }
      return true;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(PROBE_DOMAIN, DIAG_TAG, '%{public}s',
        'persist write failed errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
      return false;
    }
  }

  /** pending 缺失/损坏 → null（S9 出 pendingFound=false 合法状态） */
  private readPendingJson(filesDir: string): PersistPayload | null {
    const path: string = filesDir + '/' + PERSIST_FILE_NAME;
    try {
      const text: string = fileIo.readTextSync(path);
      return JSON.parse(text) as PersistPayload;
    } catch (e) {
      const err = e as BusinessError;
      hilog.info(PROBE_DOMAIN, DIAG_TAG, '%{public}s',
        'persist read errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
      return null;
    }
  }

  private pushErr(kvs: KeyValue[], err: BusinessError): void {
    kvs.push(new KeyValue('errCode', String(err.code)));
    kvs.push(new KeyValue('errMessage', err.message ?? ''));
  }

  build() {
    Column({ space: 12 }) {
      Text($r('app.string.probe_p1u1_persist_hint'))
        .fontSize(12)
        .opacity(0.7)
        .width('100%')
      Text($r('app.string.probe_p1u1_verify_hint'))
        .fontSize(12)
        .opacity(0.7)
        .width('100%')
      ProbePage({
        unitId: 'P1-U1',
        pageTitle: $r('app.string.probe_p1u1_title'),
        steps: STORE_STEPS,
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
