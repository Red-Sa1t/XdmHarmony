/*
 * U4.3 探针单元：P4-U3 设置页/i18n/主题探针（设计书 §6 五步）。
 * 会话模型：autoStart=false——"运行全部"自动 S1→S4→S5 占位发射；S5 勾选清单后单步执行（验收锚
 * =末次 runId 的 S5 行，ProbeMainWindow S4/P4-U2 S5 同款双会话形态）。
 *   S1 标量键默认读回（只读不写；47 键可观测子集）
 *   S2 集合键读回（15/23/3/5 计数+thwawte 保真+首尾锚）
 *   S3 写回-读回-finally 恢复闭环（全部写操作 try/finally 恢复 S1 基线；恢复后读回=restored 值）
 *   S4 语言+主题应用观测（setAppPreferredLanguage('zh-Hans')→读回→恢复→读回；
 *      setColorMode(LIGHT)→应用→按基线映射恢复→应用；readback 为系统层事实，UI 随切在 S5 判）
 *   S5 走查清单 31 项（manual 单步：checked/total/unchecked）
 * 红线：S3/S4 全部写操作 try/finally 恢复基线；观测值只写事实不写 PASS/FAIL；
 * 单行 <1500B；本文件 import probe/core 与业务 Config/SettingParse 合法（探针侧例外）。
 */

import { ConfigurationConstant } from '@kit.AbilityKit';
import { i18n } from '@kit.LocalizationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ProbeKit, KeyValue } from '../core/ProbeKit';
import { ProbePage, ProbeStepDef } from '../core/ProbePage';
import { Config, UserCredential } from '../../core/Config';
import { CategoryDef } from '../../core/util/CategoryAlgo';
import { parseCategoryTypes } from '../../core/util/SettingParse';
import { ProxyInfo } from '../../model/DownloadTypes';

/** 步骤定义表（S1~S4 autoRun；S5 manual 单步迷你会话） */
const SETTINGS_STEPS: ProbeStepDef[] = [
  { stepNo: 'S1', title: '标量键默认读回', autoRun: true },
  { stepNo: 'S2', title: '集合键读回', autoRun: true },
  { stepNo: 'S3', title: '写回-读回-恢复闭环', autoRun: true },
  { stepNo: 'S4', title: '语言+主题应用观测', autoRun: true },
  { stepNo: 'S5', title: '人工走查清单 31 项', autoRun: false }
];

/** 人工走查清单 31 项标题（设计书 §6 S5 清单逐项；只进勾选面 UI，不进探针日志） */
const CHECKLIST_TITLES: string[] = [
  '监控页三列表默认值原文回显（文件类型 23 项/视频 15 项/屏蔽主机含 thwawte）',
  '监控页三个"默认"钮点击后回填默认值',
  '监控页改扩展列表→保存→重进设置页保持',
  '监控页最小视频体积 9 档可选且回显当前值',
  '监控页剪贴板/时间戳/媒体通知三 Toggle 回显与保存',
  '监控页浏览器引导区（六浏览器按钮/URL 复制/引导文案）不渲染',
  '常规页进度窗/完成窗/自动开始三 Toggle 回显与保存',
  '常规页"覆盖已有文件"勾选=Overwrite（不勾=AutoRename）',
  '常规页深色主题 Toggle 回显与保存',
  '常规页临时/默认下载文件夹文本回显',
  '常规页最大并发下拉 1..50 可选且回显',
  '常规页自动分类 Toggle 勾=Auto（与覆盖已有方向相反）',
  '常规页双击行为两项（打开目录/打开文件）回显',
  '常规页分类列表默认 5 项',
  '常规页分类新增校验三弹（空名/空类型/空目录逐项弹且不关窗）',
  '常规页分类新增成功入列表',
  '常规页分类编辑保留原 Name（UUID 键不变）',
  '常规页分类删除按选中项',
  '常规页恢复默认=5 项',
  '网络页超时/分段/重试三 Select 回显（30/8/10）',
  '网络页限速输入仅数字可键入',
  '网络页限速输入失焦：空或非法重置为 0',
  '网络页限速保存非法不回写（改后保存重进见旧值）',
  '网络页代理三档仅 Manual 启用四输入+保存回显',
  '凭据页增/改/删',
  '凭据页空 Host 校验弹窗不关窗',
  '凭据页空 User 校验弹窗不关窗',
  '高级页 UA 回显+Reset 回填默认',
  '高级页关机/唤醒/命令/杀毒/自启五组不渲染',
  '全局：Save 关闭重进回读生效；Cancel 零写入（改后取消重进见旧值）',
  '全局：语言菜单选中文→主界面文案即时变中文（zh_CN 目录命中判定点；未命中登记退化）'
];

/** S3 基线快照（try/finally 恢复原料；runSingle 直跑 S3 时自采） */
class SettingsBaseline {
  networkTimeout: number = 30;
  maxSegments: number = 8;
  minVideoSize: number = 1024;
  proxyType: number = 0;
  proxyHost: string = '';
  proxyPort: number = 0;
  proxyUser: string = '';
  proxyPassword: string = '';
  fileConflictResolution: number = 0;
  categories: CategoryDef[] = [];
  credentials: UserCredential[] = [];
}

@Component
export struct ProbeSettings {
  /** S5 勾选面（31 项；状态跨"运行全部"与单步 S5 存续） */
  @State checkedFlags: boolean[] = CHECKLIST_TITLES.map((title: string): boolean => false);
  private probeKit: ProbeKit = ProbeKit.getInstance();
  private baseline: SettingsBaseline = new SettingsBaseline();

  /** 步骤分派 */
  private async runStep(stepNo: string): Promise<void> {
    if (stepNo === 'S1') {
      this.runS1();
      return;
    }
    if (stepNo === 'S2') {
      this.runS2();
      return;
    }
    if (stepNo === 'S3') {
      this.runS3();
      return;
    }
    if (stepNo === 'S4') {
      this.runS4();
      return;
    }
    if (stepNo === 'S5') {
      this.runS5();
      return;
    }
  }

  /** S1 标量键默认读回（只读；userSelFolder 发串长表空串；UA 只发前缀 12 字符） */
  private runS1(): void {
    const config: Config = Config.getInstance();
    const ua: string = config.getFallbackUserAgent();
    const kvs: KeyValue[] = [
      new KeyValue('notificationTimeOut', String(config.getNotificationTimeOut())),
      new KeyValue('isBrowserMonitoring', String(config.getIsBrowserMonitoringEnabled())),
      new KeyValue('showNotification', String(config.getShowNotification())),
      new KeyValue('lang', config.getLanguage()),
      new KeyValue('darkTheme', String(config.getAllowSystemDarkTheme())),
      new KeyValue('maxParallel', String(config.getMaxParallelDownloads())),
      new KeyValue('timeout', String(config.getNetworkTimeout())),
      new KeyValue('segments', String(config.getMaxSegments())),
      new KeyValue('retry', String(config.getMaxRetry())),
      new KeyValue('retryDelay', String(config.getRetryDelay())),
      new KeyValue('minVideo', String(config.getMinVideoSize())),
      new KeyValue('folderSel', String(config.getFolderSelectionMode())),
      new KeyValue('conflict', String(config.getFileConflictResolution())),
      new KeyValue('startAuto', String(config.getStartDownloadAutomatically())),
      new KeyValue('fetchTs', String(config.getFetchServerTimeStamp())),
      new KeyValue('monitorClip', String(config.getMonitorClipboard())),
      new KeyValue('dblClick', String(config.getDoubleClickOpenFile())),
      new KeyValue('shutdown', String(config.getShutdownAfterAllFinished())),
      new KeyValue('keepAwake', String(config.getKeepPCAwake())),
      new KeyValue('runCmd', String(config.getRunCommandAfterCompletion())),
      new KeyValue('antivirus', String(config.getScanWithAntiVirus())),
      new KeyValue('proxyType', String(config.getProxyType())),
      new KeyValue('proxyPort', String(config.getProxyPort())),
      new KeyValue('uaPrefix', ua.slice(0, 12)),
      new KeyValue('userSelFolder', String(config.getUserSelectedDownloadFolder().length)),
      new KeyValue('credCount', String(config.getUserCredentials().length))
    ];
    this.probeKit.emit('S1', kvs);
  }

  /** S2 集合键读回（计数+首尾+thwawte 保真+分类扩展数） */
  private runS2(): void {
    const config: Config = Config.getInstance();
    const videoExts: string[] = config.getVideoExtensions();
    const fileExts: string[] = config.getFileExtensions();
    const blockedHosts: string[] = config.getBlockedHosts();
    const categories: CategoryDef[] = config.getCategories();
    let catVideosExts: number = 0;
    let catDocsExts: number = 0;
    for (let i = 0; i < categories.length; i++) {
      if (categories[i].name === 'CAT_VIDEOS') {
        catVideosExts = categories[i].fileExtensions.length;
      }
      if (categories[i].name === 'CAT_DOCUMENTS') {
        catDocsExts = categories[i].fileExtensions.length;
      }
    }
    const kvs: KeyValue[] = [
      new KeyValue('videoExts', String(videoExts.length)),
      new KeyValue('fileExts', String(fileExts.length)),
      new KeyValue('blockedHosts', String(blockedHosts.length)),
      new KeyValue('blockedHost0', blockedHosts.length > 0 ? blockedHosts[0] : 'none'),
      new KeyValue('blockedHost2', blockedHosts.length > 2 ? blockedHosts[2] : 'none'),
      new KeyValue('categories', String(categories.length)),
      new KeyValue('catVideosExts', String(catVideosExts)),
      new KeyValue('catDocsExts', String(catDocsExts)),
      new KeyValue('recentFolders', String(config.getRecentFolders().length)),
      new KeyValue('videoFirst', videoExts.length > 0 ? videoExts[0] : 'none'),
      new KeyValue('videoLast', videoExts.length > 0 ? videoExts[videoExts.length - 1] : 'none')
    ];
    this.probeKit.emit('S2', kvs);
  }

  /** S3 写回-读回-finally 恢复闭环：全部写操作 try/finally 恢复基线（S1 先采基线亦可，
   * 此处自采保证单步直跑 S3 同样安全）；恢复后读回=restored 值 */
  private runS3(): void {
    const config: Config = Config.getInstance();
    const baseline: SettingsBaseline = this.captureBaseline(config);
    let timeoutW: number = 0;
    let timeoutR: number = 0;
    let segmentsW: number = 0;
    let segmentsR: number = 0;
    let minVideoW: number = 0;
    let minVideoR: number = 0;
    let proxyW: number = 0;
    let proxyR: number = 0;
    let proxyHostR: string = '';
    let proxyPortR: number = 0;
    let conflictW: number = 0;
    let conflictR: number = 0;
    let catW: number = 0;
    let catR: number = 0;
    let credW: number = 0;
    let credR: number = 0;
    try {
      config.setNetworkTimeout(120);
      timeoutW = config.getNetworkTimeout();
      timeoutR = Config.getInstance().getNetworkTimeout();
      config.setMaxSegments(16);
      segmentsW = config.getMaxSegments();
      segmentsR = Config.getInstance().getMaxSegments();
      config.setMinVideoSize(2048);
      minVideoW = config.getMinVideoSize();
      minVideoR = Config.getInstance().getMinVideoSize();
      const proxy: ProxyInfo = {
        proxyType: 2,
        host: '10.0.0.1',
        port: 8080,
        userName: 'u',
        password: 'p'
      };
      config.setProxyInfo(proxy);
      proxyW = config.getProxyType();
      proxyR = config.getProxyType();
      proxyHostR = config.getProxyHost();
      proxyPortR = config.getProxyPort();
      config.setFileConflictResolution(1);
      conflictW = config.getFileConflictResolution();
      conflictR = config.getFileConflictResolution();
      const cats: CategoryDef[] = config.getCategories();
      const custom: CategoryDef = new CategoryDef('CAT_PROBE_U4U3', 'Probe',
        parseCategoryTypes('.MP4,.MP4,.MKV'), 'Probe', false);
      cats.push(custom);
      config.setCategories(cats);
      catW = config.getCategories().length;
      catR = catW;
      const creds: UserCredential[] = [];
      creds.push(new UserCredential('probe.example.com', 'user', 'pass'));
      config.setUserCredentials(creds);
      credW = config.getUserCredentials().length;
      credR = credW;
    } finally {
      config.setNetworkTimeout(baseline.networkTimeout);
      config.setMaxSegments(baseline.maxSegments);
      config.setMinVideoSize(baseline.minVideoSize);
      const baselineProxy: ProxyInfo = {
        proxyType: baseline.proxyType,
        host: baseline.proxyHost,
        port: baseline.proxyPort,
        userName: baseline.proxyUser,
        password: baseline.proxyPassword
      };
      config.setProxyInfo(baselineProxy);
      config.setFileConflictResolution(baseline.fileConflictResolution);
      config.setCategories(baseline.categories);
      config.setUserCredentials(baseline.credentials);
    }
    const catParseDedup: number = parseCategoryTypes('.MP4,.MP4,.MKV').length;
    const kvs: KeyValue[] = [
      new KeyValue('timeoutW', String(timeoutW)),
      new KeyValue('timeoutR', String(timeoutR)),
      new KeyValue('timeoutRestored', String(config.getNetworkTimeout())),
      new KeyValue('segmentsW', String(segmentsW)),
      new KeyValue('segmentsR', String(segmentsR)),
      new KeyValue('segmentsRestored', String(config.getMaxSegments())),
      new KeyValue('minVideoW', String(minVideoW)),
      new KeyValue('minVideoR', String(minVideoR)),
      new KeyValue('minVideoRestored', String(config.getMinVideoSize())),
      new KeyValue('proxyW', String(proxyW)),
      new KeyValue('proxyR', String(proxyR)),
      new KeyValue('proxyHostR', proxyHostR),
      new KeyValue('proxyPortR', String(proxyPortR)),
      new KeyValue('proxyRestored', String(config.getProxyType())),
      new KeyValue('conflictW', String(conflictW)),
      new KeyValue('conflictR', String(conflictR)),
      new KeyValue('conflictRestored', String(config.getFileConflictResolution())),
      new KeyValue('catW', String(catW)),
      new KeyValue('catR', String(catR)),
      new KeyValue('catParseDedup', String(catParseDedup)),
      new KeyValue('catRestored', String(config.getCategories().length)),
      new KeyValue('credW', String(credW)),
      new KeyValue('credR', String(credR)),
      new KeyValue('credRestored', String(config.getUserCredentials().length))
    ];
    this.probeKit.emit('S3', kvs);
  }

  /** S4 语言+主题应用观测：写操作 try/finally 恢复基线；readback 为系统层事实 */
  private runS4(): void {
    const config: Config = Config.getInstance();
    const langBefore: string = config.getLanguage();
    const themeKeyBaseline: boolean = config.getAllowSystemDarkTheme();
    let langSet: string = 'unset';
    let langReadback: string = 'unset';
    let langRestored: string = langBefore;
    let langAfterReadback: string = 'unset';
    try {
      i18n.System.setAppPreferredLanguage('zh-Hans');
      langSet = 'zh-Hans';
      langReadback = i18n.System.getAppPreferredLanguage();
    } catch (e) {
      // 观测值只写事实：调用失败记 errCode（判定在 EXPECT/verify 侧，非探针内）
      const err = e as BusinessError;
      langSet = 'err' + String(err.code);
      langReadback = 'err' + String(err.code);
    } finally {
      // 恢复基线恒在 finally 执行；setAppPreferredLanguage 带 @throws（SDK d.ts），内层 try/catch
      // 吸收（hvigor "Function may throw exceptions" 规则点——finally 内无 catch 会遮蔽原异常）
      try {
        i18n.System.setAppPreferredLanguage(langBefore);
      } catch (e) {
        const err = e as BusinessError;
        langRestored = 'err' + String(err.code);
      }
      langAfterReadback = i18n.System.getAppPreferredLanguage();
    }
    let themeApply1: string = 'error';
    let themeApply2: string = 'error';
    const ctx = this.getUIContext().getHostContext();
    if (ctx !== undefined) {
      const appCtx = ctx.getApplicationContext();
      try {
        appCtx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
        themeApply1 = 'light';
      } catch (e) {
        const err = e as BusinessError;
        themeApply1 = 'err' + String(err.code);
      }
      try {
        appCtx.setColorMode(themeKeyBaseline ? ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET
          : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
        themeApply2 = themeKeyBaseline ? 'notset' : 'light';
      } catch (e) {
        const err = e as BusinessError;
        themeApply2 = 'err' + String(err.code);
      }
    }
    const kvs: KeyValue[] = [
      new KeyValue('langBefore', langBefore),
      new KeyValue('langSet', langSet),
      new KeyValue('langReadback', langReadback),
      new KeyValue('langRestored', langRestored),
      new KeyValue('langAfterReadback', langAfterReadback),
      new KeyValue('themeApply1', themeApply1),
      new KeyValue('themeApply2', themeApply2),
      new KeyValue('themeKeyBaseline', String(themeKeyBaseline))
    ];
    this.probeKit.emit('S4', kvs);
  }

  /** S5（manual 单步验收锚；主会话内为占位发射）：checked/total/unchecked（1 基项号） */
  private runS5(): void {
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
    } catch (e) {
      const err = e as BusinessError;
      const kvs: KeyValue[] = [
        new KeyValue('errCode', String(err.code)),
        new KeyValue('errMessage', err.message ?? '')
      ];
      this.probeKit.emit('S5', kvs);
    }
  }

  /** 基线采集（S3 try/finally 恢复原料；集合取拷贝） */
  private captureBaseline(config: Config): SettingsBaseline {
    const snapshot: SettingsBaseline = new SettingsBaseline();
    snapshot.networkTimeout = config.getNetworkTimeout();
    snapshot.maxSegments = config.getMaxSegments();
    snapshot.minVideoSize = config.getMinVideoSize();
    const proxy: ProxyInfo = config.getProxyInfo();
    snapshot.proxyType = proxy.proxyType;
    snapshot.proxyHost = proxy.host ?? '';
    snapshot.proxyPort = proxy.port;
    snapshot.proxyUser = proxy.userName ?? '';
    snapshot.proxyPassword = proxy.password ?? '';
    snapshot.fileConflictResolution = config.getFileConflictResolution();
    snapshot.categories = config.getCategories();
    snapshot.credentials = config.getUserCredentials();
    return snapshot;
  }

  build() {
    Column({ space: 12 }) {
      Text($r('app.string.probe_p4u3_title'))
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .width('100%')
      Text($r('app.string.probe_p4u3_check_hint'))
        .fontSize(12)
        .opacity(0.7)
        .width('100%')
      // S5 勾选面（31 项；状态跨"运行全部"与单步 S5 存续）
      Scroll() {
        Column({ space: 4 }) {
          ForEach(CHECKLIST_TITLES, (title: string, index: number) => {
            Row({ space: 8 }) {
              Text(String(index + 1))
                .fontSize(12)
                .opacity(0.6)
                .width(26)
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
        unitId: 'P4-U3',
        pageTitle: $r('app.string.probe_p4u3_title'),
        steps: SETTINGS_STEPS,
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
