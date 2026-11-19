/*
 * U4.3 设置页五页 UpdateConfig 编排（设计书 §1-#3；对照 SettingsWindow.xaml.cs:68-78
 * BtnOK_Click `foreach (var page in pages) { page.UpdateConfig(); }`——pages 数组序
 * =监控→常规→网络→凭据→高级（SettingsWindow ctor :32-39）。
 * ArkUI 映射：各 Tab 页组件 aboutToAppear 自读 Config（=源 ctor foreach PopulateUI 的分散化）
 * 并 registerUpdater（注册序=页构造序=源 pages 数组序，SettingsPage TabContent 声明序）；
 * Save 钮 updateAll() 依注册序逐页回写（单页解析失败键跳过=保留旧值语义）。
 * 容错：单监听器异常 try/catch 吞掉不中断链（Config.ets broadcastConfigChange 容错风格同款）。
 * 红线：不承载 populate；本文件不 import probe/**。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

export class SettingsSession {
  /** 页回写函数注册表（序=注册序=源 pages 数组序） */
  private updaters: Array<() => void> = [];

  /** 页组件 aboutToAppear 注册（同一函数重复注册幂等） */
  registerUpdater(updater: () => void): void {
    if (this.updaters.indexOf(updater) < 0) {
      this.updaters.push(updater);
    }
  }

  /** 页组件 aboutToDisappear 注销（off 传同一函数引用移除） */
  unregisterUpdater(updater: () => void): void {
    const idx: number = this.updaters.indexOf(updater);
    if (idx >= 0) {
      this.updaters.splice(idx, 1);
    }
  }

  /** BtnOK_Click foreach 同貌：逐页 UpdateConfig；单页异常吞掉记日志，链不中断
   * （源单页异常会中断 foreach——ArkTS 侧收紧为容错续行，防一页脏态阻塞其余四页落库） */
  updateAll(): void {
    for (let i = 0; i < this.updaters.length; i++) {
      try {
        this.updaters[i]();
      } catch (e) {
        const err = e as BusinessError;
        hilog.error(0x0000, 'SettingsSession', '%{public}s',
          'updateAll page updater failed index=' + String(i) +
          ' errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
      }
    }
  }
}
