/*
 * U5.2 探针单元：P5-U2 剪贴板监视+保存目录（设计书 §6 五步）。
 * 会话模型：autoStart=false——主会话"运行全部"（S1/S2 autoRun 跑完；S3/S4/S5 发占位行 mode=
 * mainSessionPlaceholder，恰 9 行 = BEGIN+S1+S2+S3+S4+S5+SUMMARY+END）+三个单步会话（S3 人工
 * 复制轨/S4 目录选择/S5 走查发射，各恰 4 行）。判定锚：S1/S2 取主会话，S3/S4/S5 取各自单步
 * 会话末次 runId。主/单步区分锚：s1RunId 成员——begin 每会话新 runId，runS3/S4/S5 比对当前
 * runId===s1RunId 即主会话（单步会话恒异值）。
 *   S1 监视启动+权限锚（auto）：快照 monitorClipboard→置 true→syncFromConfig()→isActive() 读回
 *      →（首次触发 READ_PASTEBOARD 申请，手册注明点允许）→permRequested 读回→detectCount/
 *      filteredCount 基线→保持 true 不恢复（S2/S3 依赖；走查①同向）。
 *   S2 程序写入直链三连（auto，setData 轨无需权限 D14）：写 http 直链→轮询 ≤10s 至 detectCount
 *      增量（识别）→再写同 URL→200ms 后读计数（去重锚）→写 ftp://→读 filteredCount 增量（过滤）。
 *   S3 人工复制轨（manual 单步）：手册指引"浏览器/备忘录复制任意 http(s) 直链→回探针页点本步骤
 *      执行"→读 lastDetectedUrl/detectDelta（对 S2 后基线）/lastReadOk/probeHandlerFired。
 *   S4 保存目录选择+StateStore 清理观测（manual 单步）：pickSaveFolder（弹 FOLDER picker 人工选）
 *      →applyPickedFolder→Config 回读三键→mkdir tempDir/probe-p5u2-<runId>/+写两个假文件→
 *      StateStore.removeById→accessSync 复检不存在。
 *   S5 走查清单 10 项发射（manual 单步；§5 清单，标题只进 UI 不进日志——ProbeDialogs S5 先例）。
 * 探针页 aboutToAppear：ClipboardWatcher.setUrlHandler(探针观测回调)（后到者接管——探针轨不弹窗
 *   只计数，Index 不在场）；aboutToDisappear 不摘 handler（应用级单例无泄漏面，manager.init 同例）。
 * 失败形态：步骤异常 catch emit errCode/errMessage（IR-F5 守卫惯例：每个 await 后过 isCurrent）。
 * 纪律：观测值只写事实不写 PASS/FAIL；[XDM_PROBE] 仅经 ProbeKit 出口。
 */

import { common } from '@kit.AbilityKit';
import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { ProbeKit, KeyValue } from '../core/ProbeKit';
import { ProbePage, ProbeStepDef } from '../core/ProbePage';
import { ClipboardWatcher } from '../../core/clipboard/ClipboardWatcher';
import { SaveDirectory } from '../../core/fs/SaveDirectory';
import { StateStore } from '../../core/db/StateStore';
import { Config } from '../../core/Config';

/** S2 轮询参数（设计书 §8-6：POLL_MS=100 不忙等+10s 超时；ProbeDialogs S3 同参） */
const S2_TIMEOUT_MS: number = 10000;
const POLL_MS: number = 100;
/** 去重/过滤观察等待（设计书 §6 S2：200ms 后读计数） */
const DEDUP_WAIT_MS: number = 200;
/** S2 测试直链（程序写入轨；仅写入剪贴板不发起下载——startDownloadAutomatically 默认 false） */
const S2_URL_DETECT: string = 'http://127.0.0.1:8081/big.bin';
/** S2 过滤轨（非 http/https scheme——三重过滤第二道拒） */
const S2_URL_FILTERED: string = 'ftp://host/f.bin';

/** 步骤定义表（S3/S4/S5 manual——单步迷你会话；标题只进 UI 不进日志） */
const CLIPBOARD_STEPS: ProbeStepDef[] = [
  { stepNo: 'S1', title: '监视启动+权限锚（首跑会弹 READ_PASTEBOARD，点允许）', autoRun: true },
  { stepNo: 'S2', title: '程序写入直链三连（识别/去重/过滤）', autoRun: true },
  { stepNo: 'S3', title: '人工复制轨：先复制任意 http(s) 直链，再点执行', autoRun: false },
  { stepNo: 'S4', title: '保存目录选择+StateStore 清理观测（弹目录 picker）', autoRun: false },
  { stepNo: 'S5', title: '人工走查清单 10 项：勾选后点执行发射', autoRun: false }
];

/** S5 走查清单 10 项（设计书 §5 人工走查全文；只进勾选面 UI，不进探针日志） */
const CHECKLIST_TITLES: string[] = [
  '设置页监控勾选 Monitor clipboard→Save→复制直链→新建对话框弹出且 URL/文件名预填',
  '同 URL 再次复制不重复弹窗（openPrompts/lastClipboardText 双锚）',
  '关掉对话框后再复制同 URL 能再次弹（PromptClosed 摘除锚）',
  '勾选 Start download automatically→复制直链→自动开始下载无弹窗',
  '设置页 General Browse→picker 选目录→toast+完成下载后文件出现在所选用户目录（文件管理器可见）',
  '工具栏 Open→预览打开成品文件',
  'Open folder→同路预览（D3 降级）',
  '删除进行中记录→确认后重启应用记录不恢复且无残留（tempDir/<id> 清理锚）',
  '停行/排队行右键 Show progress→不开窗（isLive 门）',
  '刷新链接窗 Stop 或点外部关闭→hilog WatchingStopped 恰一次（无双发）'
];

@Component
export struct ProbeClipboardSaveDir {
  /** S5 勾选面（10 项；状态跨会话存续） */
  @State checkedFlags: boolean[] = CHECKLIST_TITLES.map((title: string): boolean => false);
  private probeKit: ProbeKit = ProbeKit.getInstance();
  /** 主/单步会话区分锚：S1 所在会话的 runId（单步会话 begin 恒新 runId） */
  private s1RunId: string = '';
  /** S3 detectDelta 基线（S1/S2 收尾时刷新） */
  private detectBaseline: number = 0;
  /** 探针 urlHandler 命中计数（探针轨不弹窗只计数） */
  private urlHandlerHits: number = 0;

  aboutToAppear(): void {
    // 后到者接管（设计书 §6）：探针轨不弹窗只计数；Index 不在场（page=probe 冷启动）
    ClipboardWatcher.getInstance().setUrlHandler((url: string): void => {
      this.urlHandlerHits++;
    });
  }

  // aboutToDisappear 不摘 handler（应用级单例无泄漏面，设计书 §6 明示）

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

  // ---------- S1 监视启动+权限锚（auto） ----------

  private async runS1(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    this.s1RunId = runId;
    try {
      const watcher: ClipboardWatcher = ClipboardWatcher.getInstance();
      const cfg: Config = Config.getInstance();
      const cfgBefore: boolean = cfg.getMonitorClipboard();
      cfg.setMonitorClipboard(true);
      watcher.syncFromConfig();
      const cfgAfter: boolean = cfg.getMonitorClipboard();
      const watcherActive: boolean = watcher.isActive();
      const permRequested: boolean = watcher.permissionRequestedOnce();
      const detectBase: number = watcher.detectCount();
      const filteredBase: number = watcher.filteredCount();
      this.detectBaseline = detectBase;
      const kvs: KeyValue[] = [
        new KeyValue('cfgBefore', String(cfgBefore)),
        new KeyValue('cfgAfter', String(cfgAfter)),
        new KeyValue('watcherActive', String(watcherActive)),
        new KeyValue('permRequested', String(permRequested)),
        new KeyValue('detectBase', String(detectBase)),
        new KeyValue('filteredBase', String(filteredBase))
      ];
      this.probeKit.emit('S1', kvs);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
    } catch (e) {
      this.emitStepError('S1', runId, e as BusinessError);
    }
  }

  // ---------- S2 程序写入直链三连（auto，setData 轨无需权限 D14） ----------

  private async runS2(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    try {
      const watcher: ClipboardWatcher = ClipboardWatcher.getInstance();
      // 识别段：写 http 直链→轮询至 detectCount 增量（≤10s）
      const detectBefore: number = watcher.detectCount();
      await this.writeClipboard(S2_URL_DETECT);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      await this.pollDetectIncrease(detectBefore, runId);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const detectDelta: number = watcher.detectCount() - detectBefore;
      const detectedUrl: string = watcher.lastDetectedUrl();
      // 去重段：再写同 URL→200ms 后读计数（lastClipboardText 锚应吞掉）
      await this.writeClipboard(S2_URL_DETECT);
      await this.sleep(DEDUP_WAIT_MS);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const dedupDetectDelta: number = watcher.detectCount() - detectBefore - detectDelta;
      // 过滤段：写 ftp://→200ms 后读 filteredCount 增量（isUriValid 拒）
      const filteredBefore: number = watcher.filteredCount();
      await this.writeClipboard(S2_URL_FILTERED);
      await this.sleep(DEDUP_WAIT_MS);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      const filteredDelta: number = watcher.filteredCount() - filteredBefore;
      this.detectBaseline = watcher.detectCount();
      const kvs: KeyValue[] = [
        new KeyValue('url1', S2_URL_DETECT),
        new KeyValue('detectDelta', String(detectDelta)),
        new KeyValue('dedupDetectDelta', String(dedupDetectDelta)),
        new KeyValue('filteredUrl', S2_URL_FILTERED),
        new KeyValue('filteredDelta', String(filteredDelta)),
        new KeyValue('lastDetectedUrl', detectedUrl),
        new KeyValue('lastReadOk', String(watcher.lastReadOk()))
      ];
      this.probeKit.emit('S2', kvs);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
    } catch (e) {
      this.emitStepError('S2', runId, e as BusinessError);
    }
  }

  // ---------- S3 人工复制轨（manual 单步） ----------

  private async runS3(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    if (runId === this.s1RunId) {
      // 主会话占位行（设计书 §6：S3/S4/S5 发占位行，恰 9 行）
      const placeholder: KeyValue[] = [new KeyValue('mode', 'mainSessionPlaceholder')];
      this.probeKit.emit('S3', placeholder);
      return;
    }
    try {
      const watcher: ClipboardWatcher = ClipboardWatcher.getInstance();
      const detectDelta: number = watcher.detectCount() - this.detectBaseline;
      const kvs: KeyValue[] = [
        new KeyValue('lastDetectedUrl', watcher.lastDetectedUrl()),
        new KeyValue('detectDelta', String(detectDelta)),
        new KeyValue('lastReadOk', String(watcher.lastReadOk())),
        new KeyValue('probeHandlerFired', String(this.urlHandlerHits))
      ];
      this.probeKit.emit('S3', kvs);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
    } catch (e) {
      this.emitStepError('S3', runId, e as BusinessError);
    }
  }

  // ---------- S4 保存目录选择+StateStore 清理观测（manual 单步） ----------

  private async runS4(): Promise<void> {
    const runId: string = this.probeKit.getSessionToken();
    if (runId === this.s1RunId) {
      const placeholder: KeyValue[] = [new KeyValue('mode', 'mainSessionPlaceholder')];
      this.probeKit.emit('S4', placeholder);
      return;
    }
    try {
      const ctx: common.UIAbilityContext = this.requireUIAbilityContext();
      const uri: string | null = await SaveDirectory.pickSaveFolder(ctx);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
      let pickedUri: string = 'null';
      let folderCount: number = 0;
      let selectionMode: number = -1;
      let userSelected: string = 'null';
      if (uri !== null) {
        pickedUri = uri;
        SaveDirectory.applyPickedFolder(uri);
        const cfg: Config = Config.getInstance();
        folderCount = cfg.getRecentFolders().length;
        selectionMode = cfg.getFolderSelectionMode();
        userSelected = cfg.getUserSelectedDownloadFolder();
      }
      // StateStore 清理观测：建 probe 目录+两个假文件→removeById→复检
      const tempDir: string = Config.getInstance().getTempDir();
      const probeDirName: string = 'probe-p5u2-' + runId;
      fileIo.mkdirSync(tempDir + '/' + probeDirName);
      this.writeFakeFile(tempDir + '/' + probeDirName + '/fake-a.txt', 'probe-a');
      this.writeFakeFile(tempDir + '/' + probeDirName + '/fake-b.txt', 'probe-b');
      StateStore.removeById(tempDir, probeDirName);
      let tempGone: boolean = false;
      try {
        tempGone = !fileIo.accessSync(tempDir + '/' + probeDirName);
      } catch (e) {
        tempGone = true;
      }
      const kvs: KeyValue[] = [
        new KeyValue('pickedUri', pickedUri),
        new KeyValue('folderCount', String(folderCount)),
        new KeyValue('selectionMode', String(selectionMode)),
        new KeyValue('userSelected', userSelected),
        new KeyValue('tempGone', String(tempGone))
      ];
      this.probeKit.emit('S4', kvs);
      if (!this.probeKit.isCurrent(runId)) {
        return;
      }
    } catch (e) {
      this.emitStepError('S4', runId, e as BusinessError);
    }
  }

  // ---------- S5 人工走查清单 10 项（manual 单步） ----------

  /** S5：checked=<k> total=10 unchecked=<索引'/'串或 none>（1 基项号；ProbeDialogs S5 同式） */
  private runS5(): void {
    const runId: string = this.probeKit.getSessionToken();
    if (runId === this.s1RunId) {
      const placeholder: KeyValue[] = [new KeyValue('mode', 'mainSessionPlaceholder')];
      this.probeKit.emit('S5', placeholder);
      return;
    }
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

  /** 程序写入剪贴板（setData 无需权限，D14）；read 失败由 watcher 侧 lastReadOk 承载 */
  private writeClipboard(text: string): Promise<void> {
    const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    return pasteboard.getSystemPasteboard().setData(data).then((): void => {
    });
  }

  /** 轮询 detectCount 增量（POLL_MS=100+10s 超时；每轮 await 后过 isCurrent 由调用方复核） */
  private async pollDetectIncrease(before: number, runId: string): Promise<boolean> {
    const watcher: ClipboardWatcher = ClipboardWatcher.getInstance();
    const deadline: number = Date.now() + S2_TIMEOUT_MS;
    while (Date.now() < deadline) {
      if (watcher.detectCount() > before) {
        return true;
      }
      await this.sleep(POLL_MS);
      if (!this.probeKit.isCurrent(runId)) {
        return false;
      }
    }
    return watcher.detectCount() > before;
  }

  /** 假文件写入（openSync WRITE_ONLY|CREATE|TRUNC + writeSync + closeSync，StateStore 同款） */
  private writeFakeFile(path: string, content: string): void {
    const file = fileIo.openSync(path,
      fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, content);
    } finally {
      fileIo.closeSync(file);
    }
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

  /** UIAbilityContext 窄化（downcast 前 undefined 窄化惯例；缺失抛错由 runStep catch 承载） */
  private requireUIAbilityContext(): common.UIAbilityContext {
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      throw new Error('host context undefined');
    }
    return ctx as common.UIAbilityContext;
  }

  build() {
    Column({ space: 12 }) {
      Text($r('app.string.probe_p5u2_title'))
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .width('100%')
      Text($r('app.string.probe_p5u2_check_hint'))
        .fontSize(12)
        .opacity(0.7)
        .width('100%')

      // S5 勾选面（10 项；状态跨"运行全部"与单步 S5 存续）
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
      .height(180)
      .scrollBar(BarState.Auto)
      .border({ width: 1, color: '#E0E0E0' })
      .borderRadius(8)
      .padding(6)

      ProbePage({
        unitId: 'P5-U2',
        pageTitle: $r('app.string.probe_p5u2_title'),
        steps: CLIPBOARD_STEPS,
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
