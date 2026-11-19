/*
 * U4.1 工具栏按钮状态机纯函数（设计书 §2.4/§5.4）。零 import（含 @kit）——Hypium 本地单测可直接加载。
 * 对照源码：XDM.Core/AppController.cs:429-478 UpdateToolbarButtonState 逐分支移植——
 *   每轮重算先全禁用五键（:431-435 DisableButton×5）
 *   进行中视图（IsInProgressViewSelected=分类 index==0，MainWindow.xaml.cs:267）：
 *     OpenFile/OpenFolder 不可见（:439）、Pause/Resume 可见（:440）
 *     选中>0 → Delete 启用（:442-445）；选中>1 → Resume+Pause 均启用（:446-450）
 *     选中==1 → isActive?Pause:Resume（:451-463；isActive=IsDownloadActive=live||queued——
 *     ApplicationCore.cs:562-565 同构，排队也算 active；>1 时 Waiting 项显 Pause 无意义仍保留，
 *     resumeOne 对排队 id 幂等 return，与源码一致）
 *   完成视图：OpenFile/OpenFolder 可见（:467）、Pause/Resume 不可见（:468）
 *     选中>0 → Delete 启用（:469-472）；选中==1 → OpenFile+OpenFolder 启用（:474-478）
 *   New 钮不在状态机内（恒可用，源码同貌）。
 * Visible/Enabled 双面：xaml BtnOpen 默认 Collapsed（:387）+ 状态机全程接管两属性——
 * ArkTS 侧 Visible 映射 Visibility.None/Visible，Enabled 映射 .enabled()。
 * ToolbarState 用 class 而非 interface：@State 整体赋值触发渲染（设计书 §2.4——ArkTS 字面量
 * 装配纪律，Index.recomputeToolbar 每轮 new 一个整体替换）。
 */

/** 六钮 enabled + 四钮 visible 状态快照（十布尔字段，全字段显式默认 false） */
export class ToolbarState {
  openFileVisible: boolean = false;
  openFolderVisible: boolean = false;
  pauseVisible: boolean = false;
  resumeVisible: boolean = false;
  openFileEnabled: boolean = false;
  openFolderEnabled: boolean = false;
  pauseEnabled: boolean = false;
  resumeEnabled: boolean = false;
  deleteEnabled: boolean = false;
}

/** 状态机（AppController.cs:429-478 逐分支）：
 * inProgressViewSelected=分类 index===0；selectedCount=当前视图选中行数；
 * singleIsActive=选中恰一行时该行是否 live||queued（IsDownloadActive 同构）。 */
export function computeToolbarState(inProgressViewSelected: boolean, selectedCount: number,
  singleIsActive: boolean): ToolbarState {
  const state: ToolbarState = new ToolbarState();
  // :431-435 五键每轮先全禁用（字段默认 false，显式置位以对照源码逐行）
  state.openFileEnabled = false;
  state.openFolderEnabled = false;
  state.pauseEnabled = false;
  state.resumeEnabled = false;
  state.deleteEnabled = false;
  if (inProgressViewSelected) {
    state.openFileVisible = false;
    state.openFolderVisible = false;
    state.pauseVisible = true;
    state.resumeVisible = true;
    if (selectedCount > 0) {
      state.deleteEnabled = true;
    }
    if (selectedCount > 1) {
      state.resumeEnabled = true;
      state.pauseEnabled = true;
    } else if (selectedCount === 1) {
      if (singleIsActive) {
        state.pauseEnabled = true;
      } else {
        state.resumeEnabled = true;
      }
    }
  } else {
    state.openFileVisible = true;
    state.openFolderVisible = true;
    state.pauseVisible = false;
    state.resumeVisible = false;
    if (selectedCount > 0) {
      state.deleteEnabled = true;
    }
    if (selectedCount === 1) {
      state.openFileEnabled = true;
      state.openFolderEnabled = true;
    }
  }
  return state;
}
