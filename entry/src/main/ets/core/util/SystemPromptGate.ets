/*
 * 系统授权弹窗门（2026-11-20）：首次启动时通知授权（requestEnableNotification）与剪贴板授权
 * （requestPermissionsFromUser）由系统以模态 UIExtension 形式挂在本应用窗口上。此期间 ArkUI 拒绝
 * 在窗口上挂接新的对话框节点（hilog："is prohibited add child(tag Dialog) ... modalUiextension count is : 1"），
 * 但 CustomDialogController 仍报告 APPEARED——对话框不可见且不会关闭，浏览器扩展送来的新建下载提示
 * 因此卡死（promptOpen 恒 true，后续链接全部排队不弹）。
 * 授权 Promise 在用户点按时即完成，此时模态 UIExtension 尚未卸载（实测约 70ms 后才 destroyed），
 * 故计数归零后再保持 SETTLE_MS 的忙碌期，期满才通知订阅者。
 * 用法：发起系统授权前 begin()，流程终态（成功/拒绝/报错）end()；Index 在 busy() 时暂不弹收件箱
 * 对话框，订阅 idle 事件在最后一个授权弹窗结束后补弹。主线程单点使用，无需加锁。
 */
/** 授权弹窗卸载余量（毫秒） */
const SETTLE_MS: number = 600;

export class SystemPromptGate {
  private static pending: number = 0;
  private static listeners: Array<() => void> = [];
  private static settling: boolean = false;
  private static settleTimer: number = -1;

  static begin(): void {
    SystemPromptGate.pending++;
  }

  static end(): void {
    if (SystemPromptGate.pending > 0) {
      SystemPromptGate.pending--;
    }
    if (SystemPromptGate.pending > 0) {
      return;
    }
    SystemPromptGate.settling = true;
    if (SystemPromptGate.settleTimer >= 0) {
      clearTimeout(SystemPromptGate.settleTimer);
    }
    SystemPromptGate.settleTimer = setTimeout((): void => {
      SystemPromptGate.settleTimer = -1;
      SystemPromptGate.settling = false;
      if (SystemPromptGate.pending > 0) {
        return;
      }
      const snapshot: Array<() => void> = SystemPromptGate.listeners.slice();
      for (let i = 0; i < snapshot.length; i++) {
        snapshot[i]();
      }
    }, SETTLE_MS);
  }

  static busy(): boolean {
    return SystemPromptGate.pending > 0 || SystemPromptGate.settling;
  }

  static subscribeIdle(listener: () => void): void {
    if (SystemPromptGate.listeners.indexOf(listener) < 0) {
      SystemPromptGate.listeners.push(listener);
    }
  }

  static unsubscribeIdle(listener: () => void): void {
    const i: number = SystemPromptGate.listeners.indexOf(listener);
    if (i >= 0) {
      SystemPromptGate.listeners.splice(i, 1);
    }
  }
}
