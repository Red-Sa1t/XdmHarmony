/*
 * U1.1 配置骨架（设计书 §2.4/§5.5）。
 * 存储：@ohos.data.preferences，实例名 'settings'（对照原版 settings.dat，Config.cs:257
 * TransactedIO.ReadBytes("settings.dat",...)）；44 键全表留 U4.3（MIGRATION_PLAN 决策 10），
 * 本单元只落 Phase 1 五键。
 * 默认值锚（Config.cs:100-122）：NetworkTimeout=30（秒，SingleSourceHTTPDownloader.cs:101
 * FromSeconds——U1.2 转毫秒 ×1000）、MaxRetry=10（次数上限）、RetryDelay=10（秒，sleep×1000）。
 * U3.1 第 7 键（Config.cs:104 MaxParallelDownloads=3；ConfigIO.cs:178-179/:392 Int32 读写，
 * 字面量键 "MaxParallelDownloads"——ArkTS 侧沿用既有 camelCase 工程约定；D10：任务书 :119 勘误，
 * :118 是 TempDir）：门判定消费方 DownloadManager.effectiveMaxParallel（<1 防御钳制归 1）。
 * U3.2 第 8~13 键（设计书 §2.1）：enableSpeedLimit/defaultDownloadSpeed（Config.cs:126 EnableSpeedLimit
 * =false / :124 DefaltDownloadSpeed=0；ConfigIO.cs:154-155 Boolean /:166-167 Int32——源属性名拼写
 * 即 'Defalt'，工程键名纠正拼写 D8）+ schedule 四键（DownloadSchedule.cs struct 锚：Schedule 挂
 * DownloadQueue 的可空结构体 → scheduleEnabled 布尔化，D6 计划宿主降级；TimeSpan 比较只到 HH:MM
 * → 直接存分钟数 0..1439，D7；WeekDays:byte 位标志 → daysMask 数值 0..127 同值表直译）。
 * 组合 setter：setSpeedLimit 写回规范化逐字（SpeedLimiterUIController.cs:22-27——
 * EnableSpeedLimit = enabled ? speed>0 : false、DefaltDownloadSpeed = speed>0 ? speed : 0）；
 * setSchedule 分钟钳 [0,1439]/daysMask &0x7F 防御（源无钳制由 UI 控件保证，U4.3 前无 UI，D8）。
 * 目录默认值（有意差异 D6/D7）：
 *   downloadDir = <filesDir>/Downloads（对照 Config.cs:154-155 DefaultDownloadFolder=
 *   PlatformHelper.GetOsDefaultDownloadFolder()，PlatformHelper.cs:71-85——沙箱无 OS 用户目录概念，
 *   Phase 5 DocumentViewPicker 接管）
 *   tempDir = <filesDir>/temp（对照 Config.cs:248 TempDir=Path.Combine(DataDir,"temp")——
 *   用 filesDir 不用 cacheDir：断点续传要求临时文件跨重启存活；per-download 子目录=tempDir/id）
 * 时序契约：EntryAbility.onCreate 同步调用 init(this.context)（getPreferencesSync）——先于任何消费方；
 * init 未调用前 getter 返回默认值（目录键返 ''）。
 * U4.3 增量（设计书 §2.1 47 键全表）：+32 键落 preferences——26 标量（照源 Config.cs 默认值）+
 * 6 JSON 集合键（videoExtensions/fileExtensions/blockedHosts/recentFolders: StringListDoc{"items":[]}
 * 包装、categories: CategoryListDoc、userCredentials: UserCredentialListDoc；解析门=PieceAlgo.
 * parseChunksJson 同款（JSON.parse→as Doc→逐字段 typeof/Array.isArray 校验，任一不符回默认+warn），
 * init 一次性解析缓存、set 更新缓存+写回 JSON 串、getter 返回缓存数组拷贝。分类目录存
 * defaultFolderName 尾段（完整目录=downloadDir 拼接，D5）；language 存 i18n tag 默认 'zh-Hans'（2026-11-20，原 D1 为 'en-US'）；
 * fallbackUserAgent set 即持久化（源 ConfigIO 键表无此键=输入重启即失的源缺陷修复，D3）；
 * proxy 平铺 5 键 + getProxyInfo/setProxyInfo 组装/拆写（D6，本单元不接 HTTP 栈）；
 * notificationTimeOut 默认 0（:42 死常量 30000 无消费不移植，D4）；RunOnLogon 不落键（源 ConfigIO
 * 两处均注释禁用+自启降级 9）。raw 限速两 setter 专供设置页（NetworkSettingsView.xaml.cs:52-56
 * 是无规范化 raw 写入，与限速窗 setSpeedLimit 双语义并存——设计书 §0-8），setSpeedLimit 冻结不动；
 * broadcastConfigChange 改 public（设置页 Save 收尾一次广播，ApplicationContext.cs:109-112 同位）。
 * 15 既有键/既有 setter/setSpeedLimit/监听器注册表逐字节零改动。
 * 业务日志：hilog domain 0x0000、tag 'XdmConfig'，绝不输出 [XDM_PROBE] 前缀。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { CategoryDef, DEFAULT_CATEGORIES } from './util/CategoryAlgo';
import { ProxyInfo } from '../model/DownloadTypes';

/** preferences 实例名（对照 settings.dat） */
export const CONFIG_PREF_NAME: string = 'settings';

/** 五键名（键名 = 原版 Config 属性名） */
const KEY_DOWNLOAD_DIR: string = 'downloadDir';
const KEY_TEMP_DIR: string = 'tempDir';
const KEY_NETWORK_TIMEOUT: string = 'networkTimeout';
const KEY_MAX_RETRY: string = 'maxRetry';
const KEY_RETRY_DELAY: string = 'retryDelay';
/** U2.1 第 6 键（Config.cs:122） */
const KEY_MAX_SEGMENTS: string = 'maxSegments';
/** U3.1 第 7 键（Config.cs:104；ConfigIO.cs:178 字面量 "MaxParallelDownloads"） */
const KEY_MAX_PARALLEL_DOWNLOADS: string = 'maxParallelDownloads';
/** U3.2 第 8 键（Config.cs:126 EnableSpeedLimit=false；ConfigIO.cs:154-155 ReadBoolean） */
const KEY_ENABLE_SPEED_LIMIT: string = 'enableSpeedLimit';
/** U3.2 第 9 键（Config.cs:124 DefaltDownloadSpeed=0；ConfigIO.cs:166-167 ReadInt32——
 * 源属性名拼写 'Defalt' 纠正为 default（D8）；单位 KB/s 同源） */
const KEY_DEFAULT_DOWNLOAD_SPEED: string = 'defaultDownloadSpeed';
/** U3.2 第 10~13 键（DownloadSchedule.cs struct 锚；D6 计划宿主降级暂挂 Config / D7 分钟数存储） */
const KEY_SCHEDULE_ENABLED: string = 'scheduleEnabled';
const KEY_SCHEDULE_START_MINUTES: string = 'scheduleStartMinutes';
const KEY_SCHEDULE_END_MINUTES: string = 'scheduleEndMinutes';
const KEY_SCHEDULE_DAYS: string = 'scheduleDays';
/** U4.2 第 14~15 键（Config.cs:106 ShowProgressWindow=true / :108 ShowDownloadCompleteWindow=true）：
 * 进度窗创建门（Index.onStarted→host.openFor）与完成窗弹出门（host.onDownloadFinished）；
 * 完成窗 Don't show again 写 false（DownloadCompleteUIController.cs:26-29 同位，差异 #14 持久化） */
const KEY_SHOW_PROGRESS_WINDOW: string = 'showProgressWindow';
const KEY_SHOW_DOWNLOAD_COMPLETE_WINDOW: string = 'showDownloadCompleteWindow';

/** ── U4.3 新增 32 键（设计书 §2.1-B 全表；键名 = 原版 Config 属性名 camelCase，D8 拼写先例）── */
/** Config.cs:44 实例默认 0（:42 DefaultNotificationTimeOut=30000 全仓无消费死常量不移植，D4） */
const KEY_NOTIFICATION_TIME_OUT: string = 'notificationTimeOut';
/** Config.cs:46；ConfigIO.cs:169 */
const KEY_IS_BROWSER_MONITORING_ENABLED: string = 'isBrowserMonitoringEnabled';
/** Config.cs:50；ConfigIO.cs:86 */
const KEY_SHOW_NOTIFICATION: string = 'showNotification';
/** Config.cs:52-54；ConfigIO 键表无此键（源缺陷=重启即失），鸿蒙版 set 即持久化（D3） */
const KEY_FALLBACK_USER_AGENT: string = 'fallbackUserAgent';
/** Config.cs:56-62；ConfigIO.cs:245（15 项，不带点大写） */
const KEY_VIDEO_EXTENSIONS_JSON: string = 'videoExtensionsJson';
/** Config.cs:64-70；ConfigIO.cs:229（23 项） */
const KEY_FILE_EXTENSIONS_JSON: string = 'fileExtensionsJson';
/** Config.cs:72-77；ConfigIO.cs:101（3 项，源拼写 thwawte 原样保真） */
const KEY_BLOCKED_HOSTS_JSON: string = 'blockedHostsJson';
/** Config.cs:79；ConfigIO.cs:175（D1：存 i18n tag，默认 'zh-Hans'） */
const KEY_LANGUAGE: string = 'language';
/** Config.cs:81；ConfigIO.cs:223（true→NOT_SET 跟随系统/false→LIGHT，设计书 §0-11） */
const KEY_ALLOW_SYSTEM_DARK_THEME: string = 'allowSystemDarkTheme';
/** Config.cs:94；ConfigIO.cs:237 */
const KEY_RECENT_FOLDERS_JSON: string = 'recentFoldersJson';
/** Config.cs:96（枚举 FolderSelectionMode{Auto,Manual} Config.cs:505-508）；ConfigIO.cs:163。
 * 注意 0 值方向：勾=Auto=0（与 fileConflictResolution 相反） */
const KEY_FOLDER_SELECTION_MODE: string = 'folderSelectionMode';
/** Config.cs:98（枚举 FileConflictResolution{AutoRename,Overwrite} Config.cs:510-514）；
 * ConfigIO.cs:160。勾=Overwrite=1、不勾=AutoRename=0（GeneralSettingsView.xaml.cs:42/:62-63） */
const KEY_FILE_CONFLICT_RESOLUTION: string = 'fileConflictResolution';
/** Config.cs:110；ConfigIO.cs:217 */
const KEY_START_DOWNLOAD_AUTOMATICALLY: string = 'startDownloadAutomatically';
/** Config.cs:112；ConfigIO.cs:157 */
const KEY_FETCH_SERVER_TIME_STAMP: string = 'fetchServerTimeStamp';
/** Config.cs:114；ConfigIO.cs:190（消费方 U5.2 ClipboardWatcher） */
const KEY_MONITOR_CLIPBOARD: string = 'monitorClipboard';
/** Config.cs:116 默认 1*1024 KB；ConfigIO.cs:187 */
const KEY_MIN_VIDEO_SIZE: string = 'minVideoSize';
/** Config.cs:128；ConfigIO.cs:214（无 UI 降级 D7，键照源保留） */
const KEY_SHUTDOWN_AFTER_ALL_FINISHED: string = 'shutdownAfterAllFinished';
/** Config.cs:130；ConfigIO.cs:172（无 UI 降级 D7） */
const KEY_KEEP_PC_AWAKE: string = 'keepPCAwake';
/** Config.cs:132；ConfigIO.cs:199（无 UI 降级 D7） */
const KEY_RUN_COMMAND_AFTER_COMPLETION: string = 'runCommandAfterCompletion';
/** Config.cs:134；ConfigIO.cs:89（源 null→'' 同貌默认空串；无 UI 降级 D7） */
const KEY_AFTER_COMPLETION_COMMAND: string = 'afterCompletionCommand';
/** Config.cs:136；ConfigIO.cs:205（无 UI 降级 D7） */
const KEY_SCAN_WITH_ANTI_VIRUS: string = 'scanWithAntiVirus';
/** Config.cs:138；ConfigIO.cs:98（无 UI 降级 D7） */
const KEY_ANTI_VIRUS_EXECUTABLE: string = 'antiVirusExecutable';
/** Config.cs:140；ConfigIO.cs:95（无 UI 降级 D7） */
const KEY_ANTI_VIRUS_ARGS: string = 'antiVirusArgs';
/** Proxy 平铺 5 键（D6；源 Config.Proxy 单可空字段 null 语义由 type=0 承载；ConfigIO.cs:491-503）：
 * ProxyInfo.cs:18-22 枚举 System=0/Direct=1/Custom=2 */
const KEY_PROXY_TYPE: string = 'proxyType';
const KEY_PROXY_HOST: string = 'proxyHost';
const KEY_PROXY_PORT: string = 'proxyPort';
const KEY_PROXY_USER: string = 'proxyUser';
const KEY_PROXY_PASSWORD: string = 'proxyPassword';
/** Config.cs:144；ConfigIO.cs:226（false→0 打开文件夹/true→1 打开文件） */
const KEY_DOUBLE_CLICK_OPEN_FILE: string = 'doubleClickOpenFile';
/** Config.cs:152；ConfigIO.cs:92 */
const KEY_USER_SELECTED_DOWNLOAD_FOLDER: string = 'userSelectedDownloadFolder';
/** Config.cs:157-226 五预定义分类（=CategoryAlgo.DEFAULT_CATEGORIES 逐串）；ConfigIO.cs:419-434。
 * JSON 单键落库（决策 10 存储等价 D5） */
const KEY_CATEGORIES_JSON: string = 'categoriesJson';
/** Config.cs:228；ConfigIO.cs:436-447（Host/User/Password 3 字段） */
const KEY_USER_CREDENTIALS_JSON: string = 'userCredentialsJson';

/** ── U4.3 新增默认值常量 ── */
/** fallbackUserAgent 默认（Config.cs:52 原串逐字；高级页 Reset 钮同消费） */
export const DEFAULT_FALLBACK_USER_AGENT: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) ' +
  'Chrome/97.0.4692.99 Safari/537.36';
export const DEFAULT_NOTIFICATION_TIME_OUT: number = 0;
export const DEFAULT_IS_BROWSER_MONITORING_ENABLED: boolean = true;
export const DEFAULT_SHOW_NOTIFICATION: boolean = true;
/** language 默认：2026-11-20 起为简体中文 'zh-Hans'（面向国内应用市场；原 D1 为 'en-US' 同貌源 "English"）。
 * 仅影响首次安装/未设置过语言的用户，已在"语言"对话框选过的值照常读回 */
export const DEFAULT_LANGUAGE: string = 'zh-Hans';
export const DEFAULT_ALLOW_SYSTEM_DARK_THEME: boolean = true;
/** 枚举默认 0 值（Auto / AutoRename——两枚举 0 值语义方向相反，落库键恒 0 默认） */
export const DEFAULT_FOLDER_SELECTION_MODE: number = 0;
export const DEFAULT_FILE_CONFLICT_RESOLUTION: number = 0;
export const DEFAULT_START_DOWNLOAD_AUTOMATICALLY: boolean = false;
export const DEFAULT_FETCH_SERVER_TIME_STAMP: boolean = false;
export const DEFAULT_MONITOR_CLIPBOARD: boolean = false;
/** Config.cs:116 MinVideoSize=1*1024（KB） */
export const DEFAULT_MIN_VIDEO_SIZE: number = 1024;
export const DEFAULT_SHUTDOWN_AFTER_ALL_FINISHED: boolean = false;
export const DEFAULT_KEEP_PC_AWAKE: boolean = true;
export const DEFAULT_RUN_COMMAND_AFTER_COMPLETION: boolean = false;
export const DEFAULT_SCAN_WITH_ANTI_VIRUS: boolean = false;
export const DEFAULT_PROXY_TYPE: number = 0;
export const DEFAULT_DOUBLE_CLICK_OPEN_FILE: boolean = false;

/** 15 项默认扩展名（Config.cs:56-62 逐串，不带点大写；DefaultVideoExtensions 静态属性对应物，
 * 监控页"默认"钮回填消费） */
export const DEFAULT_VIDEO_EXTENSIONS: string[] = ['MP4', 'M3U8', 'F4M', 'WEBM', 'OGG', 'MP3', 'AAC',
  'FLV', 'MKV', 'DIVX', 'MOV', 'MPG', 'MPEG', 'OPUS', 'MPD'];
/** 23 项默认文件类型（Config.cs:64-70 逐串） */
export const DEFAULT_FILE_EXTENSIONS: string[] = ['3GP', '7Z', 'AVI', 'BZ2', 'DEB', 'DOC', 'DOCX',
  'EXE', 'ISO', 'MSI', 'PDF', 'PPT', 'PPTX', 'RAR', 'RPM', 'XLS', 'XLSX', 'SIT', 'SITX', 'TAR',
  'JAR', 'ZIP', 'XZ'];
/** 3 项默认屏蔽主机（Config.cs:72-77 逐串；thwawte 源拼写原样） */
export const DEFAULT_BLOCKED_HOSTS: string[] = ['update.microsoft.com', 'windowsupdate.com',
  'thwawte.com'];

/** JSON 集合包装文档（设计书 §2.2；{"items":[...]} 防裸数组边界，与 chunks.json 同策略） */
interface StringListDoc {
  items: string[];
}

/** CategoryDef 投影（字段 1:1；fileExtensions 带点大写） */
interface CategoryDoc {
  name: string;
  displayName: string;
  fileExtensions: string[];
  defaultFolderName: string;
  isPredefined: boolean;
}

interface CategoryListDoc {
  items: CategoryDoc[];
}

/** 源 PasswordEntry 3 字段（ConfigIO.cs:436-447 Host/User/Password） */
interface UserCredentialDoc {
  host: string;
  user: string;
  password: string;
}

interface UserCredentialListDoc {
  items: UserCredentialDoc[];
}

/** 默认值锚（Config.cs:120/100/102） */
export const DEFAULT_NETWORK_TIMEOUT: number = 30;
export const DEFAULT_MAX_RETRY: number = 10;
export const DEFAULT_RETRY_DELAY: number = 10;
/** 默认值锚（Config.cs:122 MaxSegments=8；MAX_COUNT 装载点 HTTPDownloaderBase.cs:25） */
export const DEFAULT_MAX_SEGMENTS: number = 8;
/** 默认值锚（Config.cs:104 MaxParallelDownloads=3） */
export const DEFAULT_MAX_PARALLEL_DOWNLOADS: number = 3;
/** 默认值锚（Config.cs:126 EnableSpeedLimit=false / :124 DefaltDownloadSpeed=0） */
export const DEFAULT_ENABLE_SPEED_LIMIT: boolean = false;
export const DEFAULT_DOWNLOAD_SPEED: number = 0;
/** 默认值锚（DownloadSchedule 可空结构体 null → false；TimeSpan 缺省 0；WeekDays.None=0） */
export const DEFAULT_SCHEDULE_ENABLED: boolean = false;
export const DEFAULT_SCHEDULE_START_MINUTES: number = 0;
export const DEFAULT_SCHEDULE_END_MINUTES: number = 0;
export const DEFAULT_SCHEDULE_DAYS: number = 0;
/** 计划分钟值域上界（23:59，D7 分钟数存储 0..1439） */
export const SCHEDULE_MINUTES_MAX: number = 1439;
/** 默认值锚（Config.cs:106/:108 两键均 true） */
export const DEFAULT_SHOW_PROGRESS_WINDOW: boolean = true;
export const DEFAULT_SHOW_DOWNLOAD_COMPLETE_WINDOW: boolean = true;

/** 目录固定名（filesDir 下） */
export const DOWNLOAD_DIR_NAME: string = 'Downloads';
export const TEMP_DIR_NAME: string = 'temp';

/** U4.3 凭据条目（对照源 PasswordEntry Host/User/Password 3 字段；CredentialSettingsTab/
 * setUserCredentials 消费） */
export class UserCredential {
  host: string;
  user: string;
  password: string;

  constructor(host: string, user: string, password: string) {
    this.host = host;
    this.user = user;
    this.password = password;
  }
}

export class Config {
  private static instance: Config | undefined = undefined;

  private prefs: preferences.Preferences | undefined = undefined;
  private downloadDir: string = '';
  private tempDir: string = '';
  private networkTimeout: number = DEFAULT_NETWORK_TIMEOUT;
  private maxRetry: number = DEFAULT_MAX_RETRY;
  private retryDelay: number = DEFAULT_RETRY_DELAY;
  private maxSegments: number = DEFAULT_MAX_SEGMENTS;
  private maxParallelDownloads: number = DEFAULT_MAX_PARALLEL_DOWNLOADS;
  private enableSpeedLimit: boolean = DEFAULT_ENABLE_SPEED_LIMIT;
  private defaultDownloadSpeed: number = DEFAULT_DOWNLOAD_SPEED;
  private scheduleEnabled: boolean = DEFAULT_SCHEDULE_ENABLED;
  private scheduleStartMinutes: number = DEFAULT_SCHEDULE_START_MINUTES;
  private scheduleEndMinutes: number = DEFAULT_SCHEDULE_END_MINUTES;
  private scheduleDays: number = DEFAULT_SCHEDULE_DAYS;
  private showProgressWindow: boolean = DEFAULT_SHOW_PROGRESS_WINDOW;
  private showDownloadCompleteWindow: boolean = DEFAULT_SHOW_DOWNLOAD_COMPLETE_WINDOW;
  /** ── U4.3 新增 26 标量缓存字段（§2.1-B 全表序）── */
  private notificationTimeOut: number = DEFAULT_NOTIFICATION_TIME_OUT;
  private isBrowserMonitoringEnabled: boolean = DEFAULT_IS_BROWSER_MONITORING_ENABLED;
  private showNotification: boolean = DEFAULT_SHOW_NOTIFICATION;
  private fallbackUserAgent: string = DEFAULT_FALLBACK_USER_AGENT;
  private language: string = DEFAULT_LANGUAGE;
  private allowSystemDarkTheme: boolean = DEFAULT_ALLOW_SYSTEM_DARK_THEME;
  private folderSelectionMode: number = DEFAULT_FOLDER_SELECTION_MODE;
  private fileConflictResolution: number = DEFAULT_FILE_CONFLICT_RESOLUTION;
  private startDownloadAutomatically: boolean = DEFAULT_START_DOWNLOAD_AUTOMATICALLY;
  private fetchServerTimeStamp: boolean = DEFAULT_FETCH_SERVER_TIME_STAMP;
  private monitorClipboard: boolean = DEFAULT_MONITOR_CLIPBOARD;
  private minVideoSize: number = DEFAULT_MIN_VIDEO_SIZE;
  private shutdownAfterAllFinished: boolean = DEFAULT_SHUTDOWN_AFTER_ALL_FINISHED;
  private keepPCAwake: boolean = DEFAULT_KEEP_PC_AWAKE;
  private runCommandAfterCompletion: boolean = DEFAULT_RUN_COMMAND_AFTER_COMPLETION;
  private afterCompletionCommand: string = '';
  private scanWithAntiVirus: boolean = DEFAULT_SCAN_WITH_ANTI_VIRUS;
  private antiVirusExecutable: string = '';
  private antiVirusArgs: string = '';
  private proxyType: number = DEFAULT_PROXY_TYPE;
  private proxyHost: string = '';
  private proxyPort: number = 0;
  private proxyUser: string = '';
  private proxyPassword: string = '';
  private doubleClickOpenFile: boolean = DEFAULT_DOUBLE_CLICK_OPEN_FILE;
  private userSelectedDownloadFolder: string = '';
  /** ── U4.3 新增 6 JSON 集合缓存（init 一次性解析；getter 返回拷贝）── */
  private videoExtensions: string[] = DEFAULT_VIDEO_EXTENSIONS.slice();
  private fileExtensions: string[] = DEFAULT_FILE_EXTENSIONS.slice();
  private blockedHosts: string[] = DEFAULT_BLOCKED_HOSTS.slice();
  private recentFolders: string[] = [];
  private categories: CategoryDef[] = DEFAULT_CATEGORIES.slice();
  private userCredentials: UserCredential[] = [];
  /** ConfigChanged 监听器注册表（U4.2；对照 SpeedLimiterUIController.cs:32 BroadcastConfigChange
   * 的订阅面——源 ApplicationContext.ApplicationEvent 全局广播，本期唯一广播点=setSpeedLimit） */
  private configListeners: Array<() => void> = [];

  private constructor() {
  }

  static getInstance(): Config {
    if (Config.instance === undefined) {
      Config.instance = new Config();
    }
    return Config.instance;
  }

  /** 同步初始化（幂等）：getPreferencesSync 取实例 → filesDir 算目录默认 → 逐键读取。
   * 失败不抛（等价 C# LoadConfig 的容错）：保留默认值继续运行。 */
  init(context: common.Context): void {
    if (this.prefs !== undefined) {
      return;
    }
    try {
      const options: preferences.Options = { name: CONFIG_PREF_NAME };
      this.prefs = preferences.getPreferencesSync(context, options);
      const filesDir: string = context.filesDir;
      this.downloadDir = this.readString(KEY_DOWNLOAD_DIR, filesDir + '/' + DOWNLOAD_DIR_NAME);
      this.tempDir = this.readString(KEY_TEMP_DIR, filesDir + '/' + TEMP_DIR_NAME);
      this.networkTimeout = this.readNumber(KEY_NETWORK_TIMEOUT, DEFAULT_NETWORK_TIMEOUT);
      this.maxRetry = this.readNumber(KEY_MAX_RETRY, DEFAULT_MAX_RETRY);
      this.retryDelay = this.readNumber(KEY_RETRY_DELAY, DEFAULT_RETRY_DELAY);
      this.maxSegments = this.readNumber(KEY_MAX_SEGMENTS, DEFAULT_MAX_SEGMENTS);
      this.maxParallelDownloads = this.readNumber(KEY_MAX_PARALLEL_DOWNLOADS, DEFAULT_MAX_PARALLEL_DOWNLOADS);
      this.enableSpeedLimit = this.readBoolean(KEY_ENABLE_SPEED_LIMIT, DEFAULT_ENABLE_SPEED_LIMIT);
      this.defaultDownloadSpeed = this.readNumber(KEY_DEFAULT_DOWNLOAD_SPEED, DEFAULT_DOWNLOAD_SPEED);
      this.scheduleEnabled = this.readBoolean(KEY_SCHEDULE_ENABLED, DEFAULT_SCHEDULE_ENABLED);
      this.scheduleStartMinutes = this.readNumber(KEY_SCHEDULE_START_MINUTES, DEFAULT_SCHEDULE_START_MINUTES);
      this.scheduleEndMinutes = this.readNumber(KEY_SCHEDULE_END_MINUTES, DEFAULT_SCHEDULE_END_MINUTES);
      this.scheduleDays = this.readNumber(KEY_SCHEDULE_DAYS, DEFAULT_SCHEDULE_DAYS);
      this.showProgressWindow = this.readBoolean(KEY_SHOW_PROGRESS_WINDOW, DEFAULT_SHOW_PROGRESS_WINDOW);
      this.showDownloadCompleteWindow = this.readBoolean(KEY_SHOW_DOWNLOAD_COMPLETE_WINDOW,
        DEFAULT_SHOW_DOWNLOAD_COMPLETE_WINDOW);
      // ── U4.3 新增 32 键装载（标量逐键读取 + JSON 集合解析门缓存；失败回默认，同上容错语义）──
      this.notificationTimeOut = this.readNumber(KEY_NOTIFICATION_TIME_OUT, DEFAULT_NOTIFICATION_TIME_OUT);
      this.isBrowserMonitoringEnabled = this.readBoolean(KEY_IS_BROWSER_MONITORING_ENABLED,
        DEFAULT_IS_BROWSER_MONITORING_ENABLED);
      this.showNotification = this.readBoolean(KEY_SHOW_NOTIFICATION, DEFAULT_SHOW_NOTIFICATION);
      this.fallbackUserAgent = this.readString(KEY_FALLBACK_USER_AGENT, DEFAULT_FALLBACK_USER_AGENT);
      this.language = this.readString(KEY_LANGUAGE, DEFAULT_LANGUAGE);
      this.allowSystemDarkTheme = this.readBoolean(KEY_ALLOW_SYSTEM_DARK_THEME,
        DEFAULT_ALLOW_SYSTEM_DARK_THEME);
      this.folderSelectionMode = this.readNumber(KEY_FOLDER_SELECTION_MODE, DEFAULT_FOLDER_SELECTION_MODE);
      this.fileConflictResolution = this.readNumber(KEY_FILE_CONFLICT_RESOLUTION,
        DEFAULT_FILE_CONFLICT_RESOLUTION);
      this.startDownloadAutomatically = this.readBoolean(KEY_START_DOWNLOAD_AUTOMATICALLY,
        DEFAULT_START_DOWNLOAD_AUTOMATICALLY);
      this.fetchServerTimeStamp = this.readBoolean(KEY_FETCH_SERVER_TIME_STAMP,
        DEFAULT_FETCH_SERVER_TIME_STAMP);
      this.monitorClipboard = this.readBoolean(KEY_MONITOR_CLIPBOARD, DEFAULT_MONITOR_CLIPBOARD);
      this.minVideoSize = this.readNumber(KEY_MIN_VIDEO_SIZE, DEFAULT_MIN_VIDEO_SIZE);
      this.shutdownAfterAllFinished = this.readBoolean(KEY_SHUTDOWN_AFTER_ALL_FINISHED,
        DEFAULT_SHUTDOWN_AFTER_ALL_FINISHED);
      this.keepPCAwake = this.readBoolean(KEY_KEEP_PC_AWAKE, DEFAULT_KEEP_PC_AWAKE);
      this.runCommandAfterCompletion = this.readBoolean(KEY_RUN_COMMAND_AFTER_COMPLETION,
        DEFAULT_RUN_COMMAND_AFTER_COMPLETION);
      this.afterCompletionCommand = this.readString(KEY_AFTER_COMPLETION_COMMAND, '');
      this.scanWithAntiVirus = this.readBoolean(KEY_SCAN_WITH_ANTI_VIRUS, DEFAULT_SCAN_WITH_ANTI_VIRUS);
      this.antiVirusExecutable = this.readString(KEY_ANTI_VIRUS_EXECUTABLE, '');
      this.antiVirusArgs = this.readString(KEY_ANTI_VIRUS_ARGS, '');
      this.proxyType = this.readNumber(KEY_PROXY_TYPE, DEFAULT_PROXY_TYPE);
      this.proxyHost = this.readString(KEY_PROXY_HOST, '');
      this.proxyPort = this.readNumber(KEY_PROXY_PORT, 0);
      this.proxyUser = this.readString(KEY_PROXY_USER, '');
      this.proxyPassword = this.readString(KEY_PROXY_PASSWORD, '');
      this.doubleClickOpenFile = this.readBoolean(KEY_DOUBLE_CLICK_OPEN_FILE, DEFAULT_DOUBLE_CLICK_OPEN_FILE);
      this.userSelectedDownloadFolder = this.readString(KEY_USER_SELECTED_DOWNLOAD_FOLDER, '');
      this.videoExtensions = this.parseStringListOr(
        this.readString(KEY_VIDEO_EXTENSIONS_JSON, this.serializeStringList(DEFAULT_VIDEO_EXTENSIONS)),
        DEFAULT_VIDEO_EXTENSIONS, KEY_VIDEO_EXTENSIONS_JSON);
      this.fileExtensions = this.parseStringListOr(
        this.readString(KEY_FILE_EXTENSIONS_JSON, this.serializeStringList(DEFAULT_FILE_EXTENSIONS)),
        DEFAULT_FILE_EXTENSIONS, KEY_FILE_EXTENSIONS_JSON);
      this.blockedHosts = this.parseStringListOr(
        this.readString(KEY_BLOCKED_HOSTS_JSON, this.serializeStringList(DEFAULT_BLOCKED_HOSTS)),
        DEFAULT_BLOCKED_HOSTS, KEY_BLOCKED_HOSTS_JSON);
      this.recentFolders = this.parseStringListOr(
        this.readString(KEY_RECENT_FOLDERS_JSON, this.serializeStringList([])), [],
        KEY_RECENT_FOLDERS_JSON);
      this.categories = this.parseCategoriesOr(
        this.readString(KEY_CATEGORIES_JSON, this.serializeCategories(DEFAULT_CATEGORIES)),
        DEFAULT_CATEGORIES, KEY_CATEGORIES_JSON);
      this.userCredentials = this.parseCredentialsOr(
        this.readString(KEY_USER_CREDENTIALS_JSON, this.serializeCredentials([])),
        KEY_USER_CREDENTIALS_JSON);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, 'XdmConfig', '%{public}s',
        'init failed errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
    }
  }

  getDownloadDir(): string {
    return this.downloadDir;
  }

  getTempDir(): string {
    return this.tempDir;
  }

  getNetworkTimeout(): number {
    return this.networkTimeout;
  }

  getMaxRetry(): number {
    return this.maxRetry;
  }

  getRetryDelay(): number {
    return this.retryDelay;
  }

  getMaxSegments(): number {
    return this.maxSegments;
  }

  getMaxParallelDownloads(): number {
    return this.maxParallelDownloads;
  }

  getEnableSpeedLimit(): boolean {
    return this.enableSpeedLimit;
  }

  getDefaultDownloadSpeed(): number {
    return this.defaultDownloadSpeed;
  }

  getScheduleEnabled(): boolean {
    return this.scheduleEnabled;
  }

  getScheduleStartMinutes(): number {
    return this.scheduleStartMinutes;
  }

  getScheduleEndMinutes(): number {
    return this.scheduleEndMinutes;
  }

  getScheduleDays(): number {
    return this.scheduleDays;
  }

  getShowProgressWindow(): boolean {
    return this.showProgressWindow;
  }

  getShowDownloadCompleteWindow(): boolean {
    return this.showDownloadCompleteWindow;
  }

  /** ConfigChanged 监听器注册（U4.2）：off 传同一函数引用移除；重复注册同一引用幂等 */
  onConfigChanged(listener: () => void): void {
    if (this.configListeners.indexOf(listener) < 0) {
      this.configListeners.push(listener);
    }
  }

  offConfigChanged(listener: () => void): void {
    const idx: number = this.configListeners.indexOf(listener);
    if (idx >= 0) {
      this.configListeners.splice(idx, 1);
    }
  }

  /** setter 语义：内存赋值 + putSync + flush 异步落盘（catch 记日志不阻塞）——set 即持久化 */
  setDownloadDir(value: string): void {
    this.downloadDir = value;
    this.writeString(KEY_DOWNLOAD_DIR, value);
  }

  setTempDir(value: string): void {
    this.tempDir = value;
    this.writeString(KEY_TEMP_DIR, value);
  }

  setNetworkTimeout(value: number): void {
    this.networkTimeout = value;
    this.writeNumber(KEY_NETWORK_TIMEOUT, value);
  }

  setMaxRetry(value: number): void {
    this.maxRetry = value;
    this.writeNumber(KEY_MAX_RETRY, value);
  }

  setRetryDelay(value: number): void {
    this.retryDelay = value;
    this.writeNumber(KEY_RETRY_DELAY, value);
  }

  setMaxSegments(value: number): void {
    this.maxSegments = value;
    this.writeNumber(KEY_MAX_SEGMENTS, value);
  }

  setMaxParallelDownloads(value: number): void {
    this.maxParallelDownloads = value;
    this.writeNumber(KEY_MAX_PARALLEL_DOWNLOADS, value);
  }

  /** 组合 setter（SpeedLimiterUIController.cs:22-27 写回规范化逐字）：enabled 开但 speed<=0 →
   * 落库仍 false；speed<=0 归 0。两键一次写入（源在 lock(Config) 内成对写+SaveConfig——主线程
   * 单点天然串行，D1 先例）。U4.2 追加：写盘后逐个触发 ConfigChanged 监听器（源
   * Window_OkClicked :32 BroadcastConfigChange 同位——限速窗 OK 是全仓唯一广播点；单监听器
   * 异常 try/catch 吞掉不中断广播链，参照 flushQuietly 容错风格；主线程同步回调=源
   * Dispatcher.BeginInvoke UI 线程投递在 ArkTS 主线程模型下的自然等价，设计书 §3.2）。 */
  setSpeedLimit(enabled: boolean, speedKBps: number): void {
    this.enableSpeedLimit = enabled ? speedKBps > 0 : false;
    this.defaultDownloadSpeed = speedKBps > 0 ? speedKBps : 0;
    this.writeBoolean(KEY_ENABLE_SPEED_LIMIT, this.enableSpeedLimit);
    this.writeNumber(KEY_DEFAULT_DOWNLOAD_SPEED, this.defaultDownloadSpeed);
    this.broadcastConfigChange();
  }

  /** 广播（U4.2 仅 setSpeedLimit 触发；U4.3 改 public——设置页 Save 收尾一次广播，
   * ApplicationContext.cs:109-112 BroadcastConfigChange 同位；遍历拷贝防回调内 off 注册表塌缩） */
  broadcastConfigChange(): void {
    const listeners: Array<() => void> = this.configListeners.slice();
    for (let i = 0; i < listeners.length; i++) {
      try {
        listeners[i]();
      } catch (e) {
        const err = e as BusinessError;
        hilog.error(0x0000, 'XdmConfig', '%{public}s',
          'configChanged listener failed errCode=' + String(err.code) +
          ' errMessage=' + (err.message ?? ''));
      }
    }
  }

  /** 组合 setter（D8 防御钳制——源无钳制由 UI 控件保证，U4.3 前无 UI）：分钟钳 [0,1439]、
   * daysMask &0x7F（WeekDays:byte 位域上界）。enabled 不钳（布尔原值）。 */
  setSchedule(enabled: boolean, startMinutes: number, endMinutes: number, daysMask: number): void {
    this.scheduleStartMinutes = this.clampScheduleMinutes(startMinutes);
    this.scheduleEndMinutes = this.clampScheduleMinutes(endMinutes);
    this.scheduleDays = daysMask & 0x7F;
    this.scheduleEnabled = enabled;
    this.writeBoolean(KEY_SCHEDULE_ENABLED, this.scheduleEnabled);
    this.writeNumber(KEY_SCHEDULE_START_MINUTES, this.scheduleStartMinutes);
    this.writeNumber(KEY_SCHEDULE_END_MINUTES, this.scheduleEndMinutes);
    this.writeNumber(KEY_SCHEDULE_DAYS, this.scheduleDays);
  }

  setShowProgressWindow(value: boolean): void {
    this.showProgressWindow = value;
    this.writeBoolean(KEY_SHOW_PROGRESS_WINDOW, value);
  }

  setShowDownloadCompleteWindow(value: boolean): void {
    this.showDownloadCompleteWindow = value;
    this.writeBoolean(KEY_SHOW_DOWNLOAD_COMPLETE_WINDOW, value);
  }

  // ────────────── U4.3 新增 32 键 getter/setter（§2.1-B 全表；set 即持久化语义同上） ──────────────

  getNotificationTimeOut(): number {
    return this.notificationTimeOut;
  }

  setNotificationTimeOut(value: number): void {
    this.notificationTimeOut = value;
    this.writeNumber(KEY_NOTIFICATION_TIME_OUT, value);
  }

  getIsBrowserMonitoringEnabled(): boolean {
    return this.isBrowserMonitoringEnabled;
  }

  setIsBrowserMonitoringEnabled(value: boolean): void {
    this.isBrowserMonitoringEnabled = value;
    this.writeBoolean(KEY_IS_BROWSER_MONITORING_ENABLED, value);
  }

  getShowNotification(): boolean {
    return this.showNotification;
  }

  setShowNotification(value: boolean): void {
    this.showNotification = value;
    this.writeBoolean(KEY_SHOW_NOTIFICATION, value);
  }

  getFallbackUserAgent(): string {
    return this.fallbackUserAgent;
  }

  /** set 即持久化（D3：源 ConfigIO 键表遗漏此键，鸿蒙版修复） */
  setFallbackUserAgent(value: string): void {
    this.fallbackUserAgent = value;
    this.writeString(KEY_FALLBACK_USER_AGENT, value);
  }

  /** 语言 i18n tag（'en-US'/'zh-Hans'/'default'，D1） */
  getLanguage(): string {
    return this.language;
  }

  setLanguage(value: string): void {
    this.language = value;
    this.writeString(KEY_LANGUAGE, value);
  }

  getAllowSystemDarkTheme(): boolean {
    return this.allowSystemDarkTheme;
  }

  setAllowSystemDarkTheme(value: boolean): void {
    this.allowSystemDarkTheme = value;
    this.writeBoolean(KEY_ALLOW_SYSTEM_DARK_THEME, value);
  }

  /** 枚举落库：0=Auto/1=Manual（FolderSelectionMode）——勾=Auto=0（与冲突解决相反方向） */
  getFolderSelectionMode(): number {
    return this.folderSelectionMode;
  }

  setFolderSelectionMode(value: number): void {
    this.folderSelectionMode = value;
    this.writeNumber(KEY_FOLDER_SELECTION_MODE, value);
  }

  /** 枚举落库：0=AutoRename/1=Overwrite（FileConflictResolution）——勾=Overwrite=1 */
  getFileConflictResolution(): number {
    return this.fileConflictResolution;
  }

  setFileConflictResolution(value: number): void {
    this.fileConflictResolution = value;
    this.writeNumber(KEY_FILE_CONFLICT_RESOLUTION, value);
  }

  getStartDownloadAutomatically(): boolean {
    return this.startDownloadAutomatically;
  }

  setStartDownloadAutomatically(value: boolean): void {
    this.startDownloadAutomatically = value;
    this.writeBoolean(KEY_START_DOWNLOAD_AUTOMATICALLY, value);
  }

  getFetchServerTimeStamp(): boolean {
    return this.fetchServerTimeStamp;
  }

  setFetchServerTimeStamp(value: boolean): void {
    this.fetchServerTimeStamp = value;
    this.writeBoolean(KEY_FETCH_SERVER_TIME_STAMP, value);
  }

  getMonitorClipboard(): boolean {
    return this.monitorClipboard;
  }

  setMonitorClipboard(value: boolean): void {
    this.monitorClipboard = value;
    this.writeBoolean(KEY_MONITOR_CLIPBOARD, value);
  }

  getMinVideoSize(): number {
    return this.minVideoSize;
  }

  setMinVideoSize(value: number): void {
    this.minVideoSize = value;
    this.writeNumber(KEY_MIN_VIDEO_SIZE, value);
  }

  getShutdownAfterAllFinished(): boolean {
    return this.shutdownAfterAllFinished;
  }

  setShutdownAfterAllFinished(value: boolean): void {
    this.shutdownAfterAllFinished = value;
    this.writeBoolean(KEY_SHUTDOWN_AFTER_ALL_FINISHED, value);
  }

  getKeepPCAwake(): boolean {
    return this.keepPCAwake;
  }

  setKeepPCAwake(value: boolean): void {
    this.keepPCAwake = value;
    this.writeBoolean(KEY_KEEP_PC_AWAKE, value);
  }

  getRunCommandAfterCompletion(): boolean {
    return this.runCommandAfterCompletion;
  }

  setRunCommandAfterCompletion(value: boolean): void {
    this.runCommandAfterCompletion = value;
    this.writeBoolean(KEY_RUN_COMMAND_AFTER_COMPLETION, value);
  }

  getAfterCompletionCommand(): string {
    return this.afterCompletionCommand;
  }

  setAfterCompletionCommand(value: string): void {
    this.afterCompletionCommand = value;
    this.writeString(KEY_AFTER_COMPLETION_COMMAND, value);
  }

  getScanWithAntiVirus(): boolean {
    return this.scanWithAntiVirus;
  }

  setScanWithAntiVirus(value: boolean): void {
    this.scanWithAntiVirus = value;
    this.writeBoolean(KEY_SCAN_WITH_ANTI_VIRUS, value);
  }

  getAntiVirusExecutable(): string {
    return this.antiVirusExecutable;
  }

  setAntiVirusExecutable(value: string): void {
    this.antiVirusExecutable = value;
    this.writeString(KEY_ANTI_VIRUS_EXECUTABLE, value);
  }

  getAntiVirusArgs(): string {
    return this.antiVirusArgs;
  }

  setAntiVirusArgs(value: string): void {
    this.antiVirusArgs = value;
    this.writeString(KEY_ANTI_VIRUS_ARGS, value);
  }

  getProxyType(): number {
    return this.proxyType;
  }

  setProxyType(value: number): void {
    this.proxyType = value;
    this.writeNumber(KEY_PROXY_TYPE, value);
  }

  getProxyHost(): string {
    return this.proxyHost;
  }

  setProxyHost(value: string): void {
    this.proxyHost = value;
    this.writeString(KEY_PROXY_HOST, value);
  }

  getProxyPort(): number {
    return this.proxyPort;
  }

  setProxyPort(value: number): void {
    this.proxyPort = value;
    this.writeNumber(KEY_PROXY_PORT, value);
  }

  getProxyUser(): string {
    return this.proxyUser;
  }

  setProxyUser(value: string): void {
    this.proxyUser = value;
    this.writeString(KEY_PROXY_USER, value);
  }

  getProxyPassword(): string {
    return this.proxyPassword;
  }

  setProxyPassword(value: string): void {
    this.proxyPassword = value;
    this.writeString(KEY_PROXY_PASSWORD, value);
  }

  getDoubleClickOpenFile(): boolean {
    return this.doubleClickOpenFile;
  }

  setDoubleClickOpenFile(value: boolean): void {
    this.doubleClickOpenFile = value;
    this.writeBoolean(KEY_DOUBLE_CLICK_OPEN_FILE, value);
  }

  getUserSelectedDownloadFolder(): string {
    return this.userSelectedDownloadFolder;
  }

  setUserSelectedDownloadFolder(value: string): void {
    this.userSelectedDownloadFolder = value;
    this.writeString(KEY_USER_SELECTED_DOWNLOAD_FOLDER, value);
  }

  // ────────────── U4.3 JSON 集合键（§2.2 解析门；缓存拷贝语义） ──────────────

  /** 监控页视频扩展名（15 项默认，不带点大写） */
  getVideoExtensions(): string[] {
    return this.videoExtensions.slice();
  }

  setVideoExtensions(list: string[]): void {
    this.videoExtensions = list.slice();
    this.writeString(KEY_VIDEO_EXTENSIONS_JSON, this.serializeStringList(this.videoExtensions));
  }

  /** 监控页文件类型（23 项默认） */
  getFileExtensions(): string[] {
    return this.fileExtensions.slice();
  }

  setFileExtensions(list: string[]): void {
    this.fileExtensions = list.slice();
    this.writeString(KEY_FILE_EXTENSIONS_JSON, this.serializeStringList(this.fileExtensions));
  }

  /** 屏蔽主机（3 项默认，thwawte 保真） */
  getBlockedHosts(): string[] {
    return this.blockedHosts.slice();
  }

  setBlockedHosts(list: string[]): void {
    this.blockedHosts = list.slice();
    this.writeString(KEY_BLOCKED_HOSTS_JSON, this.serializeStringList(this.blockedHosts));
  }

  /** 最近目录（登记键，无 UI） */
  getRecentFolders(): string[] {
    return this.recentFolders.slice();
  }

  setRecentFolders(list: string[]): void {
    this.recentFolders = list.slice();
    this.writeString(KEY_RECENT_FOLDERS_JSON, this.serializeStringList(this.recentFolders));
  }

  /** 分类（五预定义默认；defaultFolderName 存尾段，完整目录=downloadDir 拼接 D5） */
  getCategories(): CategoryDef[] {
    return this.categories.slice();
  }

  setCategories(list: CategoryDef[]): void {
    this.categories = list.slice();
    this.writeString(KEY_CATEGORIES_JSON, this.serializeCategories(this.categories));
  }

  /** 凭据（空表默认；U6.x 401 挑战消费） */
  getUserCredentials(): UserCredential[] {
    return this.userCredentials.slice();
  }

  setUserCredentials(list: UserCredential[]): void {
    this.userCredentials = list.slice();
    this.writeString(KEY_USER_CREDENTIALS_JSON, this.serializeCredentials(this.userCredentials));
  }

  /** Proxy 便捷组装（D6；本单元不接 HTTP 栈，U6.x HttpClient 消费） */
  getProxyInfo(): ProxyInfo {
    const proxy: ProxyInfo = {
      proxyType: this.proxyType,
      host: this.proxyHost,
      port: this.proxyPort,
      userName: this.proxyUser,
      password: this.proxyPassword
    };
    return proxy;
  }

  /** Proxy 拆写平铺 5 键（可空字段 ?? '' 同源非空文本框语义） */
  setProxyInfo(proxy: ProxyInfo): void {
    this.proxyType = proxy.proxyType;
    this.proxyHost = proxy.host ?? '';
    this.proxyPort = proxy.port;
    this.proxyUser = proxy.userName ?? '';
    this.proxyPassword = proxy.password ?? '';
    this.writeNumber(KEY_PROXY_TYPE, this.proxyType);
    this.writeString(KEY_PROXY_HOST, this.proxyHost);
    this.writeNumber(KEY_PROXY_PORT, this.proxyPort);
    this.writeString(KEY_PROXY_USER, this.proxyUser);
    this.writeString(KEY_PROXY_PASSWORD, this.proxyPassword);
  }

  /** raw 限速 setter（设计书 §0-8：设置页 NetworkSettingsView.UpdateConfig :52-56 是无规范化
   * raw 写入——与限速窗 setSpeedLimit（规范化+广播，U4.2 语义冻结）双语义并存，不得复用） */
  setEnableSpeedLimitRaw(value: boolean): void {
    this.enableSpeedLimit = value;
    this.writeBoolean(KEY_ENABLE_SPEED_LIMIT, value);
  }

  /** raw 限速 setter（速度原值直写，无 speed>0 规范化；tryParseInt 失败由调用方跳过不写） */
  setDefaultDownloadSpeedRaw(value: number): void {
    this.defaultDownloadSpeed = value;
    this.writeNumber(KEY_DEFAULT_DOWNLOAD_SPEED, value);
  }

  /** JSON 集合解析门（PieceAlgo.parseChunksJson:348-380 同款）：JSON.parse → as Doc → 逐字段
   * typeof/Array.isArray 校验 → 任一不符回默认值并 warn。禁 any、禁无门 as。 */
  private parseStringListOr(text: string, defValue: string[], key: string): string[] {
    try {
      const parsed: Object | null = JSON.parse(text);
      if (parsed === null) {
        return defValue.slice();
      }
      const doc: StringListDoc = parsed as StringListDoc;
      if (!Array.isArray(doc.items)) {
        this.warnCollectionParse(key);
        return defValue.slice();
      }
      const items: string[] = [];
      for (let i = 0; i < doc.items.length; i++) {
        const item: string = doc.items[i];
        if (typeof item !== 'string') {
          this.warnCollectionParse(key);
          return defValue.slice();
        }
        items.push(item);
      }
      return items;
    } catch (e) {
      this.warnCollectionParse(key);
      return defValue.slice();
    }
  }

  private parseCategoriesOr(text: string, defValue: CategoryDef[], key: string): CategoryDef[] {
    try {
      const parsed: Object | null = JSON.parse(text);
      if (parsed === null) {
        return defValue.slice();
      }
      const doc: CategoryListDoc = parsed as CategoryListDoc;
      if (!Array.isArray(doc.items)) {
        this.warnCollectionParse(key);
        return defValue.slice();
      }
      const result: CategoryDef[] = [];
      for (let i = 0; i < doc.items.length; i++) {
        const item: CategoryDoc = doc.items[i];
        if (typeof item.name !== 'string' || typeof item.displayName !== 'string' ||
          typeof item.defaultFolderName !== 'string' || typeof item.isPredefined !== 'boolean' ||
          !Array.isArray(item.fileExtensions)) {
          this.warnCollectionParse(key);
          return defValue.slice();
        }
        const exts: string[] = [];
        for (let j = 0; j < item.fileExtensions.length; j++) {
          const ext: string = item.fileExtensions[j];
          if (typeof ext !== 'string') {
            this.warnCollectionParse(key);
            return defValue.slice();
          }
          exts.push(ext);
        }
        result.push(new CategoryDef(item.name, item.displayName, exts, item.defaultFolderName,
          item.isPredefined));
      }
      return result;
    } catch (e) {
      this.warnCollectionParse(key);
      return defValue.slice();
    }
  }

  private parseCredentialsOr(text: string, key: string): UserCredential[] {
    try {
      const parsed: Object | null = JSON.parse(text);
      if (parsed === null) {
        return [];
      }
      const doc: UserCredentialListDoc = parsed as UserCredentialListDoc;
      if (!Array.isArray(doc.items)) {
        this.warnCollectionParse(key);
        return [];
      }
      const result: UserCredential[] = [];
      for (let i = 0; i < doc.items.length; i++) {
        const item: UserCredentialDoc = doc.items[i];
        if (typeof item.host !== 'string' || typeof item.user !== 'string' ||
          typeof item.password !== 'string') {
          this.warnCollectionParse(key);
          return [];
        }
        result.push(new UserCredential(item.host, item.user, item.password));
      }
      return result;
    } catch (e) {
      this.warnCollectionParse(key);
      return [];
    }
  }

  private serializeStringList(list: string[]): string {
    const doc: StringListDoc = { items: list };
    return JSON.stringify(doc);
  }

  private serializeCategories(list: CategoryDef[]): string {
    const doc: CategoryListDoc = { items: [] };
    for (let i = 0; i < list.length; i++) {
      const item: CategoryDoc = {
        name: list[i].name,
        displayName: list[i].displayName,
        fileExtensions: list[i].fileExtensions,
        defaultFolderName: list[i].defaultFolderName,
        isPredefined: list[i].isPredefined
      };
      doc.items.push(item);
    }
    return JSON.stringify(doc);
  }

  private serializeCredentials(list: UserCredential[]): string {
    const doc: UserCredentialListDoc = { items: [] };
    for (let i = 0; i < list.length; i++) {
      const item: UserCredentialDoc = {
        host: list[i].host,
        user: list[i].user,
        password: list[i].password
      };
      doc.items.push(item);
    }
    return JSON.stringify(doc);
  }

  private warnCollectionParse(key: string): void {
    hilog.warn(0x0000, 'XdmConfig', '%{public}s', 'collection parse failed, fallback to default: ' + key);
  }

  /** 计划分钟防御钳 [0,1439]（NaN/非有限归 0——effectiveMaxParallel 同族防御） */
  private clampScheduleMinutes(value: number): number {
    if (!Number.isFinite(value) || value < 0) {
      return 0;
    }
    if (value > SCHEDULE_MINUTES_MAX) {
      return SCHEDULE_MINUTES_MAX;
    }
    return Math.floor(value);
  }

  private readString(key: string, defValue: string): string {
    const prefs = this.prefs;
    if (prefs === undefined) {
      return defValue;
    }
    try {
      const value: preferences.ValueType = prefs.getSync(key, defValue);
      return typeof value === 'string' ? value : defValue;
    } catch (e) {
      // 读单键失败：记日志后上抛（init 的整体 catch 接住，等价 C# LoadConfig 一处失败其余键回退默认值）。
      // `as Error`：arkts-limited-throw 只接受静态类型 Error 及其类子类，BusinessError 接口不可直接 throw
      const err = e as BusinessError;
      hilog.error(0x0000, 'XdmConfig', '%{public}s',
        'read ' + key + ' failed errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
      throw err as Error;
    }
  }

  private readNumber(key: string, defValue: number): number {
    const prefs = this.prefs;
    if (prefs === undefined) {
      return defValue;
    }
    try {
      const value: preferences.ValueType = prefs.getSync(key, defValue);
      return typeof value === 'number' ? value : defValue;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, 'XdmConfig', '%{public}s',
        'read ' + key + ' failed errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
      throw err as Error;
    }
  }

  private writeString(key: string, value: string): void {
    const prefs = this.prefs;
    if (prefs === undefined) {
      return;
    }
    try {
      prefs.putSync(key, value);
      this.flushQuietly(prefs);
    } catch (e) {
      const err = e as BusinessError;
      this.logFailure('writeString ' + key, err);
    }
  }

  private writeNumber(key: string, value: number): void {
    const prefs = this.prefs;
    if (prefs === undefined) {
      return;
    }
    try {
      prefs.putSync(key, value);
      this.flushQuietly(prefs);
    } catch (e) {
      const err = e as BusinessError;
      this.logFailure('writeNumber ' + key, err);
    }
  }

  /** readNumber 的 boolean 同型（preferences.ValueType 联合含 boolean；typeof 判定模式逐字一致） */
  private readBoolean(key: string, defValue: boolean): boolean {
    const prefs = this.prefs;
    if (prefs === undefined) {
      return defValue;
    }
    try {
      const value: preferences.ValueType = prefs.getSync(key, defValue);
      return typeof value === 'boolean' ? value : defValue;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, 'XdmConfig', '%{public}s',
        'read ' + key + ' failed errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
      throw err as Error;
    }
  }

  /** writeNumber 的 boolean 同型 */
  private writeBoolean(key: string, value: boolean): void {
    const prefs = this.prefs;
    if (prefs === undefined) {
      return;
    }
    try {
      prefs.putSync(key, value);
      this.flushQuietly(prefs);
    } catch (e) {
      const err = e as BusinessError;
      this.logFailure('writeBoolean ' + key, err);
    }
  }

  /** flush 异步落盘：失败只记日志（Phase 1 无关键路径依赖 flush 时点——设计书 §8） */
  private flushQuietly(prefs: preferences.Preferences): void {
    prefs.flush().catch((err: BusinessError) => {
      hilog.error(0x0000, 'XdmConfig', '%{public}s',
        'flush failed errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
    });
  }

  private logFailure(op: string, err: BusinessError): void {
    hilog.error(0x0000, 'XdmConfig', '%{public}s',
      op + ' failed errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
  }
}
