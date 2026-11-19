/*
 * U4.1 探针单元：P4-U1 主窗口走查探针（设计书 §5.11/§6 四步）。
 * 会话模型：**autoStart=false——先主页面人工走查（勾选 23 项清单）→探针页"运行全部"（S1~S3
 * auto+S4 占位发射）→回探针页勾选清单→单步执行 S4（验收锚=末次 runId 的 S4 行）**。
 *   S1 数据源行为观测（纯内存零业务副作用）：DownloadListDataSource initialize 3 记录
 *      （dateAdded 升序喂入 b.mp3(t1)/a.pdf(t2)/c.zip(t3)）→addSorted(d.bin t4)→toggleSort('Name')×2
 *      →applyFilter('a')→clearFilter+applyFilter('','.ZIP' 分类)→clearFilter→removeById('c')。
 *   S2 纯函数面观测：generateStatusText 六分支（英文标签常量）+computeToolbarState 五场景。
 *   S3 排队取消回声链：快照 maxParallel→set 1→manager.init(事实袋, hooks 计数+镜像 updateStatus)
 *      →r1 slow.bin?ms=300 add+admitNew（live）→r2 add+admitNew（queued，status=Waiting(3)）
 *      →**先** isQueued(r2)→stopOne(r2)（排队取消不补位）→**后** isLive(r1)→stopOne(r1)→轮询
 *      live==0（20s 超时）→getDownloadById(r2) 读 DB→恢复 maxParallel+读回校验。
 *      确定性论证（设计书 §6）：先取消排队后停运行的次序保证 startedCount 恒 1——若排队取消误补位
 *      则 r2 在 r1 停止前已被 dequeueOne 启动（startedCount=2 且回声=0）；ms=300 慢源保证停止窗口
 *      远大于提交序列（提交+双 stop 亚秒完成，单分段 4MiB≈分钟级）；maxParallel=1 保证 admitNew(r2)
 *      必入队（status=Waiting 可观测）。
 *   S4 走查清单（manual）：23 项 Toggle 勾选发射 checked/total/unchecked（中文标题只进 UI 不进日志；
 *   23=OPT-1 深色模式观测项——深浅色切换全界面可读）。
 * 驱动模型（设计书 §6）：S1/S2 纯内存零业务副作用；S3 只调业务公开 API（DownloadManager/
 * DownloadStore/Config）。观测值只写事实不写 PASS/FAIL（判定在 EXPECT/verify）。
 * 会话纪律：S3 manager.init 后到者接管事件袋——手册次序红线"先主页面走查后探针"，探针会话内不切页。
 * 确定性 id：probe-p4u1-<runId>-<i>（store.add 前覆盖 record.id——COLD-F1 约定）；DB 行每轮 +2
 * （S1/S2 纯内存零残留），与既有探针同口径不清理。
 * 环境前提：S3 需主机侧 node P1-U2-download-server.js（零改动复用，ms=300 由探针 URL 携带）；
 * S1/S2/S4 无需测试源。
 */

import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ProbeKit, KeyValue } from '../core/ProbeKit';
import { ProbePage, ProbeStepDef } from '../core/ProbePage';
import { DownloadEvents, ForwardDownloadEvents } from '../../core/engine/Downloader';
import { DownloadManager, ManagerHooks } from '../../core/engine/DownloadManager';
import { DownloadRecord, newDownloadRecord } from '../../model/DownloadRecord';
import { DownloadStatus } from '../../model/DownloadTypes';
import { DownloadStore } from '../../core/db/DownloadStore';
import { Config } from '../../core/Config';
import { DownloadListDataSource } from '../../model/DownloadListDataSource';
import { DEFAULT_CATEGORIES } from '../../core/util/CategoryAlgo';
import { StatusLabels, generateStatusText } from '../../core/util/StatusText';
import { computeToolbarState } from '../../core/util/ToolbarAlgo';

/** 测试源缺省地址（TextInput 占位；真机/模拟器填主机局域网 IP，禁 127.0.0.1） */
const DEFAULT_BASE_URL: string = 'http://127.0.0.1:8081';

/** S3 慢源参数（/slow.bin?ms=300——提交+双 stop 亚秒窗口 << 首下载完成时间；ms 由 URL 携带） */
const SLOW_MS: number = 300;

/** S3 live 归零轮询（POLL_MS=100 不忙等；20s 超时后仍发观测行） */
const S3_TIMEOUT_MS: number = 20000;
const POLL_MS: number = 100;

/** 步骤定义表（S4 manual——单步迷你会话） */
const MAIN_WINDOW_STEPS: ProbeStepDef[] = [
  { stepNo: 'S1', title: '数据源行为观测', autoRun: true },
  { stepNo: 'S2', title: '纯函数面观测', autoRun: true },
  { stepNo: 'S3', title: '排队取消回声链', autoRun: true },
  { stepNo: 'S4', title: '人工走查清单 23 项', autoRun: false }
];

/** 人工走查清单 23 项标题（§6bis 对照表+OPT-1 追加第 23 项；只进 S4 勾选面 UI，不进探针日志） */
const CHECKLIST_TITLES: string[] = [
  '启动默认落在"已完成"视图（分类第 2 项高亮+Tabs 完成页）',
  '分类面板 7 项齐全：全部下载中/全部已完成/Document/Music/Video/Compressed/Application',
  '分类各带计数且与对应列表行数一致（子分类=扩展名匹配数）',
  '点击"全部下载中"→进行中列表+OpenFile/OpenFolder 隐藏+Pause/Resume 显示',
  '点击"全部已完成"→完成列表+OpenFile/OpenFolder 显示+Pause/Resume 隐藏',
  '点击子分类→完成列表仅剩匹配扩展名行（如 Video 只剩 .mp4/.mkv…）',
  '搜索框输入关键词+点击搜索→完成列表按名称包含过滤；进行中列表不受影响',
  '切换分类后搜索框被清空',
  '列头点击：Name 首击升序/再击降序；DateAdded/Size 同；% 列头点击无反应',
  '新建下载后新行出现在进行中列表顶部',
  '行点击选中高亮+Delete 启用；再点同行保持选中（WPF 同貌，取消选中经复选框）',
  '选中 1 个运行中行→Pause 启用/Resume 禁用；选中停态行→反之；选中 Waiting 行→Pause',
  '复选框勾选 2 行→Pause+Resume 均启用',
  'Waiting 行按钮显示"取消排队"，点击后行变 Stopped+按钮变"继续"',
  '上一步后杀进程重启→该行仍为停态（DB 回声）',
  '工具栏 Pause/Resume 对选中行生效且与行按钮同效',
  '工具栏 Delete：确认后非运行行消失、重启不回；运行行被停不删',
  '新建下拉：New download 打开既有对话框；Video download/Batch download 禁用',
  '汉堡菜单 12 项可见且全部占位禁用',
  '状态栏：Browser monitoring 文案+toggle+Queue and scheduler+Help 占位禁用',
  '造 >50 行历史后滑动双列表无可感知卡顿',
  '状态列文本：运行中=速度-ETA 或 Downloading；停态=Stopped；排队=Waiting',
  '深色模式全界面可读'
];

/** S2 英文标签常量（string.json base STAT_* 同值） */
const S2_LABELS: StatusLabels = {
  downloading: 'Downloading',
  stopped: 'Stopped',
  finished: 'Finished',
  waiting: 'Waiting'
};

/** S3 manager 事件事实袋（startedCount/pausedEcho 原料） */
class MainWindowFacts {
  startedCount: number = 0;
  pausedCount: number = 0;
  finishedCount: number = 0;
  failedCount: number = 0;
}

@Component
export struct ProbeMainWindow {
  @State baseUrl: string = DEFAULT_BASE_URL;
  /** S4 勾选面（23 项；autoStart=false 会话外的 UI 态，跨"运行全部"/单步 S4 存续） */
  @State checkedFlags: boolean[] = CHECKLIST_TITLES.map((title: string): boolean => false);
  private probeKit: ProbeKit = ProbeKit.getInstance();
  private facts: MainWindowFacts = new MainWindowFacts();
  private queuedCancelledCount: number = 0;
  /** hooks 镜像 updateStatus 的在途 Promise（S3 读 DB 前等待——回声落库时序确定性） */
  private dbEchoPromise: Promise<boolean> | undefined = undefined;

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
      this.runS4();
      return;
    }
  }

  // ---------- S1 数据源行为观测（纯内存） ----------

  /** S1（设计书 §6 步骤表）：初始排序 desc/投影插入位/排序翻转/关键词与分类过滤/删除通知 */
  private async runS1(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const ds: DownloadListDataSource = new DownloadListDataSource();
      // dateAdded 升序喂入：b.mp3(t1) < a.pdf(t2) < c.zip(t3)；t4=d.bin
      const recB: DownloadRecord = this.makeMemoryRow('b.mp3', 1000);
      const recA: DownloadRecord = this.makeMemoryRow('a.pdf', 2000);
      const recC: DownloadRecord = this.makeMemoryRow('c.zip', 3000);
      ds.initialize([recB, recA, recC]);
      const initOrder: string = this.stemsOfVisible(ds, 3);
      ds.addSorted(this.makeMemoryRow('d.bin', 4000));
      const totalCountAfterAdd: number = ds.totalCount();
      const addIndex: number = this.indexOfStem(ds, 'd');
      ds.toggleSort('Name');
      const nameAsc: string = this.stemsOfVisible(ds, 4);
      ds.toggleSort('Name');
      const nameDesc: string = this.stemsOfVisible(ds, 4);
      ds.applyFilter('a', null);
      const keywordFiltered: number = ds.totalCount();
      const fullCount: number = ds.fullCount();
      ds.clearFilter();
      // '.ZIP' 分类过滤（Compressed 集含 .ZIP——Config.cs:200）
      ds.applyFilter('', DEFAULT_CATEGORIES[3]);
      const categoryFiltered: number = ds.totalCount();
      ds.clearFilter();
      const removed: boolean = ds.removeById(recC.id);
      const totalCountAfterRemove: number = ds.totalCount();
      const kvs: KeyValue[] = [
        new KeyValue('initOrder', initOrder),
        new KeyValue('addIndex', String(addIndex)),
        new KeyValue('totalCountAfterAdd', String(totalCountAfterAdd)),
        new KeyValue('nameAsc', nameAsc),
        new KeyValue('nameDesc', nameDesc),
        new KeyValue('keywordFiltered', String(keywordFiltered)),
        new KeyValue('fullCount', String(fullCount)),
        new KeyValue('categoryFiltered', String(categoryFiltered)),
        new KeyValue('removeHit', String(removed ? 1 : 0)),
        new KeyValue('totalCountAfterRemove', String(totalCountAfterRemove))
      ];
      this.probeKit.emit('S1', kvs);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
    } catch (e) {
      this.emitStepError('S1', runId, e as BusinessError);
    }
  }

  /** S1 纯内存行（不走 store：id 覆盖供 removeById 定位；dateAdded 确定性时序） */
  private makeMemoryRow(name: string, dateAdded: number): DownloadRecord {
    const record: DownloadRecord = newDownloadRecord(name, '/data/local/tmp', 0, null,
      'http://probe.internal/' + name, false, null, null);
    record.id = 'probe-p4u1-ds-' + name;
    record.dateAdded = dateAdded;
    return record;
  }

  /** 投影前 n 项名干序（'c.zip'→'c'，'/' 连接） */
  private stemsOfVisible(ds: DownloadListDataSource, count: number): string {
    const parts: string[] = [];
    const total: number = ds.totalCount();
    for (let i = 0; i < count && i < total; i++) {
      const record: DownloadRecord | undefined = ds.getData(i);
      const name: string = record !== undefined ? (record.name ?? '') : '';
      const dot: number = name.indexOf('.');
      parts.push(dot >= 0 ? name.slice(0, dot) : name);
    }
    return parts.join('/');
  }

  /** 按名干找投影下标（未命中 -1） */
  private indexOfStem(ds: DownloadListDataSource, stem: string): number {
    const total: number = ds.totalCount();
    for (let i = 0; i < total; i++) {
      const record: DownloadRecord | undefined = ds.getData(i);
      const name: string = record !== undefined ? (record.name ?? '') : '';
      const dot: number = name.indexOf('.');
      const s: string = dot >= 0 ? name.slice(0, dot) : name;
      if (s === stem) {
        return i;
      }
    }
    return -1;
  }

  // ---------- S2 纯函数面观测 ----------

  /** S2（设计书 §6）：generateStatusText 六分支 + computeToolbarState 五场景（布尔 1/0 编码） */
  private async runS2(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const statNoSpeed: string = generateStatusText(0, null, null, S2_LABELS);
      const statSpeedOnly: string = generateStatusText(0, '1.2MB/s', null, S2_LABELS);
      const statEtaOnly: string = generateStatusText(0, null, '00:01', S2_LABELS);
      const statBoth: string = generateStatusText(0, '1.2MB/s', '00:01', S2_LABELS);
      const statStopped: string = generateStatusText(1, null, null, S2_LABELS);
      const statWaiting: string = generateStatusText(3, null, null, S2_LABELS);
      const ip0 = computeToolbarState(true, 0, false);
      const ip1Active = computeToolbarState(true, 1, true);
      const ip1Idle = computeToolbarState(true, 1, false);
      const ip2 = computeToolbarState(true, 2, false);
      const fin1 = computeToolbarState(false, 1, false);
      const kvs: KeyValue[] = [
        new KeyValue('statNoSpeed', statNoSpeed),
        new KeyValue('statSpeedOnly', statSpeedOnly),
        new KeyValue('statEtaOnly', statEtaOnly),
        new KeyValue('statBoth', statBoth),
        new KeyValue('statStopped', statStopped),
        new KeyValue('statWaiting', statWaiting),
        new KeyValue('ip0', 'del' + this.bit(ip0.deleteEnabled) + '/pv' + this.bit(ip0.pauseVisible) +
          '/ofv' + this.bit(ip0.openFileVisible)),
        new KeyValue('ip1Active', 'p' + this.bit(ip1Active.pauseEnabled) + '/r' +
          this.bit(ip1Active.resumeEnabled) + '/del' + this.bit(ip1Active.deleteEnabled)),
        new KeyValue('ip1Idle', 'p' + this.bit(ip1Idle.pauseEnabled) + '/r' + this.bit(ip1Idle.resumeEnabled)),
        new KeyValue('ip2', 'p' + this.bit(ip2.pauseEnabled) + '/r' + this.bit(ip2.resumeEnabled) +
          '/del' + this.bit(ip2.deleteEnabled)),
        new KeyValue('fin1', 'of' + this.bit(fin1.openFileEnabled) + '/pv' + this.bit(fin1.pauseVisible) +
          '/del' + this.bit(fin1.deleteEnabled))
      ];
      this.probeKit.emit('S2', kvs);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
    } catch (e) {
      this.emitStepError('S2', runId, e as BusinessError);
    }
  }

  private bit(v: boolean): string {
    return v ? '1' : '0';
  }

  // ---------- S3 排队取消回声链 ----------

  /** S3（设计书 §6）：maxParallel 快照→1；先取消排队项后停运行项保证 startedCount=1 不补位锚；
   * hooks 镜像 updateStatus 后 getDownloadById 读回；恢复 maxParallel。 */
  private async runS3(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      this.resetSessionState();
      const cfg: Config = Config.getInstance();
      const maxParallelBefore: number = cfg.getMaxParallelDownloads();
      cfg.setMaxParallelDownloads(1);
      const manager: DownloadManager = DownloadManager.getInstance();
      manager.init(this.buildListener(), this.buildHooks());
      const store: DownloadStore = DownloadStore.getInstance();
      const ctx: common.Context = this.requireContext();
      await store.initialize(ctx);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      // r1 提交（live）：确定性 id 在 add 前覆盖（COLD-F1）
      const r1: DownloadRecord = newDownloadRecord('p4u1-r1.bin', Config.getInstance().getDownloadDir(),
        0, null, this.joinBase('/slow.bin?ms=' + String(SLOW_MS)), true, null, null);
      r1.id = 'probe-p4u1-' + runId + '-1';
      const ok1: boolean = await store.add(r1);
      if (ok1) {
        manager.admitNew(r1);
      }
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      // r2 提交（queued，status=Waiting(3) 工厂 startWaiting=true）
      const r2: DownloadRecord = newDownloadRecord('p4u1-r2.bin', Config.getInstance().getDownloadDir(),
        0, null, this.joinBase('/slow.bin?ms=' + String(SLOW_MS)), true, null, null);
      r2.id = 'probe-p4u1-' + runId + '-2';
      const ok2: boolean = await store.add(r2);
      if (ok2) {
        manager.admitNew(r2);
      }
      const queuedStatusBeforeStop: number = r2.status;
      const submitted: number = (ok1 ? 1 : 0) + (ok2 ? 1 : 0);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      // 先取消排队项（isQueued 分派命中 → stopOne queued 分支：不补位+内存 Stopped+hooks 回声）
      const r2WasQueued: boolean = manager.isQueued(r2.id);
      if (r2WasQueued) {
        manager.stopOne(r2.id);
      }
      const queuedAfterCancel: number = manager.queuedCount();
      // 后停运行项（live 分支 stopIntent+downloader.stop；onPaused 回声时队列已空 → 无补位）
      const r1WasLive: boolean = manager.isLive(r1.id);
      if (r1WasLive) {
        manager.stopOne(r1.id);
      }
      await this.pollUntil((): boolean => manager.liveCount() === 0, S3_TIMEOUT_MS, POLL_MS);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      // DB 回声读回：等待 hooks 镜像 updateStatus 在途 Promise（store.updateStatus 内部
      // try/catch 吞异常恒 resolve，不会 reject）
      const echo: Promise<boolean> | undefined = this.dbEchoPromise;
      if (echo !== undefined) {
        await echo;
      }
      const dbRecord: DownloadRecord | null = await store.getDownloadById(r2.id);
      const dbStatusAfterEcho: number = dbRecord !== null ? dbRecord.status : -1;
      // 环境恢复+读回校验
      cfg.setMaxParallelDownloads(maxParallelBefore);
      const maxParallelRestored: number = cfg.getMaxParallelDownloads();
      const kvs: KeyValue[] = [
        new KeyValue('maxParallelBefore', String(maxParallelBefore)),
        new KeyValue('submitted', String(submitted)),
        new KeyValue('queuedStatusBeforeStop', String(queuedStatusBeforeStop)),
        new KeyValue('queuedCancelEcho', String(this.queuedCancelledCount)),
        new KeyValue('startedCount', String(this.facts.startedCount)),
        new KeyValue('pausedEcho', String(this.facts.pausedCount)),
        new KeyValue('liveAfterStops', String(manager.liveCount())),
        new KeyValue('queuedAfterCancel', String(queuedAfterCancel)),
        new KeyValue('dbStatusAfterEcho', String(dbStatusAfterEcho)),
        new KeyValue('maxParallelRestored', String(maxParallelRestored))
      ];
      this.probeKit.emit('S3', kvs);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
    } catch (e) {
      this.emitStepError('S3', runId, e as BusinessError);
    }
  }

  /** manager 事件事实袋（ForwardDownloadEvents 闭包转发——DownloadEvents 接口禁字面量装配先例） */
  private buildListener(): DownloadEvents {
    return new ForwardDownloadEvents(
      (id: string): void => {
        this.facts.startedCount++;
      },
      (id: string, status: number, totalSize: number, resumable: boolean, contentType: string): void => {
      },
      (id: string, progress: number, instantSpeed: number, etaSeconds: number,
        downloadedBytes: number): void => {
      },
      (id: string, offsetBytes: number): void => {
        this.facts.pausedCount++;
      },
      (id: string, finalFileSize: number, filePath: string): void => {
        this.facts.finishedCount++;
      },
      (id: string, errorCode: number, errorMessage: string): void => {
        this.facts.failedCount++;
      }
    );
  }

  /** hooks（类型化字面量装配，ProbeQueue.ets:419-421 先例）：计数+镜像 Index D9 回声
   * （updateStatus(Stopped)——内存 Stopped 已由 stopOne queued 分支置位，同一 record 引用） */
  private buildHooks(): ManagerHooks {
    const hooks: ManagerHooks = {
      onQueuedCancelled: (id: string): void => {
        this.queuedCancelledCount++;
        this.dbEchoPromise = DownloadStore.getInstance().updateStatus(id, DownloadStatus.Stopped);
      }
    };
    return hooks;
  }

  // ---------- S4 人工走查清单（manual 单步） ----------

  /** S4（设计书 §6）：checked=<k> total=23 unchecked=<索引'/'串或 none>（1 基项号） */
  private runS4(): void {
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
      this.probeKit.emit('S4', kvs);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
    } catch (e) {
      this.emitStepError('S4', runId, e as BusinessError);
    }
  }

  // ---------- 工具 ----------

  private resetSessionState(): void {
    this.facts = new MainWindowFacts();
    this.queuedCancelledCount = 0;
    this.dbEchoPromise = undefined;
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

  /** 测试源拼接：TextInput 值去尾部斜杠 + 路由；空值回退缺省地址（ProbeSpeedLimit 同构） */
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
      Text($r('app.string.probe_p4u1_title'))
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .width('100%')
      Text($r('app.string.probe_p4u1_source_hint'))
        .fontSize(12)
        .opacity(0.7)
        .width('100%')
      TextInput({ text: this.baseUrl, placeholder: $r('app.string.probe_p4u1_source_hint') })
        .onChange((value: string) => {
          this.baseUrl = value;
        })
        .width('100%')
      Text($r('app.string.probe_p4u1_check_hint'))
        .fontSize(12)
        .opacity(0.7)
        .width('100%')
      // S4 勾选面（23 项；状态跨"运行全部"与单步 S4 存续）
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
        unitId: 'P4-U1',
        pageTitle: $r('app.string.probe_p4u1_title'),
        steps: MAIN_WINDOW_STEPS,
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
