/*
 * U5.2 剪贴板监视（设计书 §1-#9/§3.1/§3.2）：应用级单例（源 IPlatformClipboardMonitor+
 * IClipboardMonitor 两层合一——鸿蒙无 per-window 平台适配器，系统剪贴板即唯一平台面）。
 * 生命周期状态机（ClipboardMonitor.cs:25-74 逐条，本会话逐行核对）：
 *   ctor: ApplicationContext.ApplicationEvent += (ConfigChanged ? Start : Stop)
 *                              → init(): Config.onConfigChanged（app-lifetime 永不 off——源事件
 *                                随对象存活同构；设置页 Save→broadcastConfigChange 触达）
 *   syncFromConfig             → MonitorClipboard ? Start : Stop（:33-45 1:1）
 *   Start() :47-48 幂等守卫     → start(): if (active) return;
 *              :49 内部再查门   →          if (!Config.getMonitorClipboard()) return;
 *   cm.StartClipboardMonitoring→ pasteboard.getSystemPasteboard().on('update', onUpdateHandler)
 *   isClipboardMonitorActive   → active = true；随后权限申请 fire-and-forget（鸿蒙特有 D9）
 *   Stop() :56-57 幂等守卫      → stop(): if (!active) return;
 *   cm.StopClipboardMonitoring → pasteboard...off('update', onUpdateHandler)（同一成员引用）
 * 命中链（Cm_ClipboardChanged :64-72 + ApplicationCore.AddDownload :208-236 投影）：
 *   onUpdate（系统回调，无载荷）→ getData().then(data => clipboardChanged(data.getPrimaryText()))
 *     catch → readOk=false + hilog + 保持订阅不重弹权限（D9 降级：监视链空转）
 *   clipboardChanged(text): 三重过滤短路序逐条 1:1——非空 && isUriValid && text!==lastClipboardText
 *     通过才 lastClipboardText=text（:70 次序红线：无效文本不更新）→ detectCount++ →
 *     urlHandler?.(text)（= AddDownload(new Message{Url}) 单订阅者投影）
 *     不通过 → filteredCount++（重复复制/无效文本/浏览器 URL 全归此）
 * setUrlHandler 后到者接管（cm.ClipboardChanged += / -= 单订阅者语义；manager.init 同款——
 *   Index/探针页谁后挂载谁接管，应用级单例无泄漏面）。
 * 观测面（探针 P5-U2 消费，非源行为）：isActive/detectCount/filteredCount/lastDetectedUrl/lastReadOk。
 * 红线：on/off('update') 与 Config.onConfigChanged 回调恒存成员箭头函数字段同引用（内联匿名=
 * off 失配订阅泄漏）；业务日志 domain 0x0000 tag 'ClipboardWatcher'、零 probe import、
 * 绝不输出 [XDM_PROBE]。
 */

import { pasteboard } from '@kit.BasicServicesKit';
import { abilityAccessCtrl, common, Permissions, PermissionRequestResult } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Config } from '../Config';
import { isUriValid } from '../net/HttpProtocol';

/** 业务日志面（domain 0x0000 / tag 'ClipboardWatcher'） */
const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'ClipboardWatcher';

/** 剪贴板监视单例（对应源 ClipboardMonitor；per-URL 单实例集/openPrompts 在 Index 侧） */
export class ClipboardWatcher {
  private static instance: ClipboardWatcher | undefined = undefined;

  /** requestPermissionsFromUser 的 context（IPlatformClipboardMonitor 平台适配器上下文投影） */
  private context: common.UIAbilityContext | undefined = undefined;
  /** isClipboardMonitorActive（幂等守卫半区，ClipboardMonitor.cs:26） */
  private active: boolean = false;
  /** 去重锚（三重过滤第三条；无效文本不更新——:70 次序红线） */
  private lastClipboardText: string = '';
  /** ClipboardChanged 事件的单订阅者投影（Index/探针后到者接管） */
  private urlHandler: ((url: string) => void) | undefined = undefined;
  /** READ_PASTEBOARD 会话级一次申请守卫（鸿蒙特有，WPF 无权限概念 D9） */
  private permissionRequested: boolean = false;
  /** ConfigChanged→syncFromConfig（成员箭头函数字段——onConfigChanged 注册引用，app-lifetime 不 off） */
  private readonly configListener: () => void = (): void => {
    this.syncFromConfig();
  };
  /** on('update')/off('update') 共用同一成员引用（内联匿名=off 失配订阅泄漏，红线） */
  private readonly onUpdateHandler: () => void = (): void => {
    this.onUpdate();
  };
  /** ── 观测面（探针/诊断消费；方法名与字段名错开防同类成员重名）── */
  private detectTotal: number = 0;
  private filteredTotal: number = 0;
  private lastUrl: string = '';
  private readOk: boolean = true;

  private constructor() {
  }

  static getInstance(): ClipboardWatcher {
    if (ClipboardWatcher.instance === undefined) {
      ClipboardWatcher.instance = new ClipboardWatcher();
    }
    return ClipboardWatcher.instance;
  }

  /** 应用级 init（源 ctor ApplicationEvent += 同构；EntryAbility.onCreate 尾部调用）：
   * 存 context + 注册 ConfigChanged 监听（永不 off——源事件随对象存活，无 dispose 面）。 */
  init(context: common.UIAbilityContext): void {
    this.context = context;
    Config.getInstance().onConfigChanged(this.configListener);
  }

  /** 配置同步（:33-45 1:1）：MonitorClipboard ? start : stop。EntryAbility.onCreate 尾部 +
   * 设置页 Save 广播（ConfigChanged）双触达。 */
  syncFromConfig(): void {
    if (Config.getInstance().getMonitorClipboard()) {
      this.start();
    } else {
      this.stop();
    }
  }

  /** 订阅命中回调（ClipboardChanged += / -= 单订阅者；后到者接管，传 undefined 摘除） */
  setUrlHandler(handler: ((url: string) => void) | undefined): void {
    this.urlHandler = handler;
  }

  /** Start()（:47-59 逐条）：active 幂等守卫 → Config 内部再查门（:49）→ 订阅 → 置位 →
   * 权限申请 fire-and-forget（订阅不依赖权限：拒绝后监视链空转仅记日志，D9）。 */
  start(): void {
    if (this.active) {
      return;
    }
    if (!Config.getInstance().getMonitorClipboard()) {
      return;
    }
    pasteboard.getSystemPasteboard().on('update', this.onUpdateHandler);
    this.active = true;
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'clipboard monitoring started');
    this.requestReadPermission();
  }

  /** Stop()（:56-59 逐条）：!active 幂等守卫 → 退订（同一成员引用）→ 复位。 */
  stop(): void {
    if (!this.active) {
      return;
    }
    pasteboard.getSystemPasteboard().off('update', this.onUpdateHandler);
    this.active = false;
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'clipboard monitoring stopped');
  }

  // ---------- 观测面（探针 P5-U2 / 诊断消费） ----------

  isActive(): boolean {
    return this.active;
  }

  detectCount(): number {
    return this.detectTotal;
  }

  filteredCount(): number {
    return this.filteredTotal;
  }

  lastDetectedUrl(): string {
    return this.lastUrl;
  }

  lastReadOk(): boolean {
    return this.readOk;
  }

  /** 权限申请已发起观测（探针 S1 permRequested 锚；会话级一次申请守卫的只读投影） */
  permissionRequestedOnce(): boolean {
    return this.permissionRequested;
  }

  // ---------- 私有实现 ----------

  /** on('update') 回调（无载荷）→ getData 读文本；读失败只记日志不重弹权限、不退订（D9）。 */
  private onUpdate(): void {
    pasteboard.getSystemPasteboard().getData().then((data: pasteboard.PasteData): void => {
      this.readOk = true;
      this.clipboardChanged(data.getPrimaryText());
    }).catch((err: BusinessError): void => {
      // 201 权限被拒/系统异常：保持订阅，监视链空转（每次 update 读失败计数）
      this.readOk = false;
      hilog.warn(LOG_DOMAIN, LOG_TAG, '%{public}s',
        'getData failed errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
    });
  }

  /** 命中链（Cm_ClipboardChanged :66-71 逐条）：三重过滤短路序不可重排——
   * 非空 → isUriValid（仅 http/https，scheme 小写比较）→ !== lastClipboardText。
   * 通过才更新 lastClipboardText（无效文本不更新=重复复制同 URL 只在首次弹）→
   * detectCount++/lastUrl → urlHandler（= AddDownload(new Message{Url=text})）。 */
  private clipboardChanged(text: string): void {
    if (text.length === 0 || !isUriValid(text) || text === this.lastClipboardText) {
      this.filteredTotal++;
      return;
    }
    this.lastClipboardText = text;
    this.detectTotal++;
    this.lastUrl = text;
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'download url detected');
    if (this.urlHandler !== undefined) {
      this.urlHandler(text);
    }
  }

  /** READ_PASTEBOARD 显式申请入口（R3-F1）：监视启动（start）与用户主动消费点（New 菜单预填等）
   * 共用同一 permissionRequested 会话级一次守卫——已申请时立即 resolve 不重弹；无 context 降级
   * resolve（start 内部同貌）。resolve 于申请流程终态（granted/denied 都只记日志不 reject——
   * 调用方 getData 自行按 201 降级，订阅与命中链不受影响，D9）。 */
  requestReadPermission(): Promise<void> {
    if (this.permissionRequested) {
      return Promise.resolve();
    }
    this.permissionRequested = true;
    const ctx = this.context;
    if (ctx === undefined) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, '%{public}s', 'permission request skipped: no context');
      return Promise.resolve();
    }
    const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    const perms: Array<Permissions> = ['ohos.permission.READ_PASTEBOARD'];
    return atManager.requestPermissionsFromUser(ctx, perms).then(
      (result: PermissionRequestResult): void => {
        // PermissionRequestResult 字段面（security/PermissionRequestResult.d.ts:43-113）：
        // permissions/authResults（0=授予，-1=拒绝，2=无效）/dialogShownResults?——无 grantedPermissions
        let granted: number = 0;
        for (let i = 0; i < result.authResults.length; i++) {
          if (result.authResults[i] === 0) {
            granted++;
          }
        }
        hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s',
          'permission requested granted=' + String(granted) +
          '/' + String(result.permissions.length));
      }).catch((err: BusinessError): void => {
      // COLD-F3：错误路径守卫复位——onCreate 早期申请（syncFromConfig→start，先于窗口就绪）
      // 若因窗口未就绪等报错，复位后 New 菜单（D18 显式入口）仍可达申请；仅 start()/New 菜单
      // 显式触发（D9 用户拒绝路径 flag 保持 true 不重弹），复位不造成重弹循环
      this.permissionRequested = false;
      hilog.warn(LOG_DOMAIN, LOG_TAG, '%{public}s',
        'permission request failed errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
    });
  }
}
