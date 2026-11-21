/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/*
 * U0.1：want 参数路由探针页。
 * 冷启动：onCreate 解析 want.parameters['page'] → onWindowStageCreate 按 targetPage loadContent。
 * 暖启动：onNewWant 仅在显式 page=probe 时切探针页；不带参数（桌面图标）保持当前页。
 * U1.1：onCreate 挂接数据层初始化（设计书 §3.2/§5.6）——Config.init 同步（getPreferencesSync）+
 * DownloadStore.initialize fire-and-forget（Promise ready 门，失败也 memoize：后续 CRUD 全走
 * catch 返 false/null/空表，等价 C# Init 失败继续运行，AppDB.cs:56-60）。U1.2 的 LoadDownloadList
 * 必须 await initialize() 之后调用（C# Application.cs:31 Init→LoadDownloadList 顺序的异步承接）。
 * 红线：本文件不 import probe/ 下任何文件（业务与探针零依赖）；路由日志沿用模板 domain 0x0000/tag
 * testTag，绝不输出 [XDM_PROBE] 标记行（ProbeKit 是唯一出口，防 verify 解析到未配对标记）。
 * U4.3（设计书 §1-#15）：onCreate 调序修复——Config.init 提前到主题应用之前；主题重放
 * setColorMode(allowSystemDarkTheme?NOT_SET:LIGHT)（替换 U0.1 的无条件 NOT_SET）；语言重放
 * i18n.System.setAppPreferredLanguage(Config.getLanguage()) 先于 loadContent。want 路由/
 * 数据层挂接/Scheduler 启动零改动。
 * U5.1 三处只加不改（设计书 §1-#9，U4.3 调序红线——onCreate 既有语句序零改动）：
 * ①onCreate 尾部追加 ProgressNotifier.init(this.context)（Scheduler.start() 之后）；
 * ②loadTarget loadContent 成功回调内追加 requestEnableNotification（通知授权前置，仅可在
 * loadContent 成功后调用；拒绝后 1600004 不再弹——只记日志不重试，D7）；
 * ③新增 onPrepareToTerminate(): boolean（活跃下载>0 拦截+主窗 minimize=关窗后下载继续，
 * 空闲放行正常退出，§3.1；需 ohos.permission.PREPARE_APP_TERMINATE，module.json5 已配）。
 * U5.2 只加不改（设计书 §1-#11）：onCreate 尾部（ProgressNotifier.init 之后）追加
 * ClipboardWatcher.init(this.context)+syncFromConfig()——对照 Application.cs:34 WindowLoaded
 * 后启动监视同位；默认 MonitorClipboard=false 故默认不订阅；Config 监听 app-lifetime 不 off。
 * 其余语句序零改动。
 * U0.3 只加不改（设计书 §5.3）：onCreate 尾部（ClipboardWatcher.syncFromConfig() 之后）追加
 * BridgeServer.getInstance().start()——8597 扩展桥常驻启动，对照原版 ApplicationCore Init 尾部
 * StartScheduler() 后 StartBrowserMonitoring() 的次序；start() 幂等 memoized，bind 失败系统
 * 随机分配端口的失配仅日志（原版 MSG_ALREADY_RUNNING 的无 UI 等价物，§0-3）。红线不破：
 * BridgeServer 属 core/bridge/（不 import probe/，日志不含 [XDM_PROBE] 子串）。
 */

import { AbilityConstant, bundleManager, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { i18n } from '@kit.LocalizationKit';
import { notificationManager } from '@kit.NotificationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Config } from '../core/Config';
import { DownloadStore } from '../core/db/DownloadStore';
import { Scheduler } from '../core/engine/Scheduler';
import { DownloadManager } from '../core/engine/DownloadManager';
import { ProgressNotifier } from '../core/notify/ProgressNotifier';
import { ClipboardWatcher } from '../core/clipboard/ClipboardWatcher';
import { BridgeServer } from '../core/bridge/BridgeServer';
import { SystemPromptGate } from '../core/util/SystemPromptGate';

const DOMAIN = 0x0000;
const DEFAULT_PAGE_PATH: string = 'pages/Index';
const PROBE_PAGE_PATH: string = 'probe/ProbeIndex';

export default class EntryAbility extends UIAbility {
  private targetPage: string = DEFAULT_PAGE_PATH;
  private windowStage: window.WindowStage | undefined = undefined;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.resolveTargetPage(want);
    // U4.3 调序修复（设计书 §1-#15 硬要求）：Config.init 必须先于主题应用——现版 setColorMode
    // 在 Config.init 之前读不到 allowSystemDarkTheme；init 未调用前 getter 返回默认值的时序契约
    // 由本调序兑现。want 路由/数据层挂接/Scheduler 启动零改动。
    Config.getInstance().init(this.context);
    const config: Config = Config.getInstance();
    try {
      // U4.3 主题重放（设计书 §0-11）：allowSystemDarkTheme=true→NOT_SET（跟随系统）/
      // false→LIGHT；faqs-arkui-1266 setColorMode 仅运行期有效 → 每次冷启按 Config 键重放
      const appContext = this.context.getApplicationContext();
      if (config.getAllowSystemDarkTheme()) {
        appContext.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
      } else {
        appContext.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
      }
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    // U4.3 语言重放（差异 D2/D1）：'en-US'/'zh-Hans'/'default' 三值统一调用；先于 loadContent
    // 保证首帧资源命中（main-thread API，onCreate 主线程合规）；失败不阻断启动
    try {
      i18n.System.setAppPreferredLanguage(config.getLanguage());
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set preferred language. Cause: %{public}s',
        JSON.stringify(err));
    }
    // U1.1 数据层挂接：DownloadStore ready 门异步建库建表（Config.init 已上移先行）
    DownloadStore.getInstance().initialize(this.context).catch((err: BusinessError) => {
      hilog.error(DOMAIN, 'testTag', '%{public}s',
        'DownloadStore initialize failed errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
    });
    // U3.2 定时启停调度器常驻启动（对照 ApplicationCore.cs:64 初始化序列调 StartScheduler
    // :597-601——"核心初始化即启动"，非 UI 页加载时；start() 幂等——探针 S3 stop()+start()
    // 重定相位后生产语义自愈，D9）。红线不破：Scheduler 属 core/engine/（不 import probe/）。
    Scheduler.getInstance().start();
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    // U5.1 尾部追加（设计书 §1-#9①）：通知编排单例 init（存 UIAbilityContext + 装载完成通知
    // 标题 notify_finished_title，失败回退常量）——冷启动/暖启动皆经 onCreate，幂等无害
    ProgressNotifier.getInstance().init(this.context);
    // U5.2 尾部追加（设计书 §1-#11）：剪贴板监视单例 init（存 context+Config.onConfigChanged
    // app-lifetime）+syncFromConfig（MonitorClipboard ? start : stop；默认 false 不订阅）——
    // Application.cs:34 WindowLoaded 后启动监视同位；运行期开关由设置页 Save 广播触达
    ClipboardWatcher.getInstance().init(this.context);
    ClipboardWatcher.getInstance().syncFromConfig();
    // U0.3 只加不改（设计书 §5.3）：8597 扩展桥常驻启动——对照原版 Init 尾部 StartScheduler 后
    // StartBrowserMonitoring 的次序；start() 幂等 memoized，端口失配仅日志（§0-3）
    BridgeServer.getInstance().start().catch((err: BusinessError) => {
      hilog.error(DOMAIN, 'testTag', '%{public}s',
        'BridgeServer start failed errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
    });
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onNewWant');
    if (!this.isProbeRoute(want)) {
      // 不带参数的暖启动（桌面图标）保持当前页，不打断用户；'默认仍进 Index' 约束的是冷启动
      return;
    }
    this.resolveTargetPage(want);
    this.loadTarget();
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  /**
   * U5.1 关窗拦截状态机（设计书 §3.1；MainWindow.xaml.cs:674-678 e.Cancel+Hide 的鸿蒙投影）。
   * faqs-ability-151（SDK UIAbility.d.ts:788 核实）：仅 2in1 生效 + 需
   * ohos.permission.PREPARE_APP_TERMINATE；回调触发点=窗口 X 关闭与 Dock/托盘右键退出两者。
   * 拍板③（D3/D10）：activeDownloadCount>0 → 主窗 minimize（faqs-arkui-889：主窗最小化 Dock
   * 可还原，下载由长时任务保活继续）+ return true 拦截；==0 → return false 放行正常关闭。
   * 互斥规则三清空（§0-3）：本工程不实现 onPrepareToTerminateAsync、无
   * AbilityStage.onPrepareTermination*、无 windowStageClose 监听。getMainWindowSync 可能抛错
   * （窗口态异常）——catch 吞掉仍 return true（窗口保持打开属无害降级）。
   * 真机若回调不触发 → 降级"最小化即后台继续"（保活语义不变，D13——P5-U1 S5 走查实证）。
   */
  onPrepareToTerminate(): boolean {
    const activeCount: number = DownloadManager.getInstance().activeDownloadCount();
    if (activeCount > 0) {
      const stage = this.windowStage;
      if (stage !== undefined) {
        try {
          stage.getMainWindowSync().minimize().catch((err: BusinessError) => {
            hilog.error(DOMAIN, 'testTag', '%{public}s', 'minimize on prepareToTerminate failed errCode=' +
              String(err.code) + ' errMessage=' + (err.message ?? ''));
          });
        } catch (e) {
          const err = e as BusinessError;
          hilog.error(DOMAIN, 'testTag', '%{public}s', 'getMainWindowSync on prepareToTerminate failed errCode=' +
            String(err.code) + ' errMessage=' + (err.message ?? ''));
        }
      }
      return true;
    }
    return false;
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    this.windowStage = windowStage;
    this.loadTarget();
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }

  /** want 显式携带 page=probe（want.parameters 为 Record<string,Object>，Object 值须 typeof 窄化，不得直接 as） */
  private isProbeRoute(want: Want): boolean {
    const params: Record<string, Object> | undefined = want.parameters;
    if (params === undefined) {
      return false;
    }
    const page: Object = params['page'];
    if (!(typeof page === 'string' && page === 'probe')) {
      return false;
    }
    // 上架整改（2026-11-19）：探针页仅调试包可达；release 包（appInfo.debug=false）忽略 page=probe
    if (!EntryAbility.isDebugBuild()) {
      hilog.warn(DOMAIN, 'testTag', '%{public}s', 'route: page=probe ignored in release build');
      return false;
    }
    return true;
  }

  private static isDebugBuild(): boolean {
    try {
      return bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION).appInfo.debug;
    } catch (e) {
      return false;
    }
  }

  /** 冷启动目标页解析：page=probe → 探针首页；其余（含无参）→ 默认 Index */
  private resolveTargetPage(want: Want): void {
    if (this.isProbeRoute(want)) {
      this.targetPage = PROBE_PAGE_PATH;
      hilog.info(DOMAIN, 'testTag', '%{public}s', 'route: want page=probe, target=' + PROBE_PAGE_PATH);
      return;
    }
    this.targetPage = DEFAULT_PAGE_PATH;
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'route: default target=' + DEFAULT_PAGE_PATH);
  }

  private loadTarget(): void {
    const stage = this.windowStage;
    if (stage === undefined) {
      return;
    }
    // 通知授权弹窗占用系统授权门（loadContent 前登记，首帧收件箱弹窗即可看到 busy）
    SystemPromptGate.begin();
    stage.loadContent(this.targetPage, (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        SystemPromptGate.end();
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
      // U5.1 尾部追加（设计书 §1-#9②/§3.5）：通知授权前置——文档硬约束"仅可在 loadContent 成功后
      // 调用"；授权弹窗仅首次，拒绝后 1600004 无法再弹（D7：openNotificationSettingsWithResult
      // 不实装，只记日志不重试）；非首次调用恒成功，冷/暖启动重复调用无害
      notificationManager.requestEnableNotification(this.context).then((): void => {
        SystemPromptGate.end();
      }).catch((notifyErr: BusinessError) => {
        SystemPromptGate.end();
        hilog.info(DOMAIN, 'testTag', '%{public}s', 'requestEnableNotification errCode=' +
          String(notifyErr.code) + ' errMessage=' + (notifyErr.message ?? ''));
      });
    });
  }
}
