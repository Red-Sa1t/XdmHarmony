/*
 * U4.1 ToolbarAlgo 纯函数 Hypium 本地用例（设计书 §7-[A]-2 用例清单，7 条）。
 * 被测模块零 @kit import（ToolbarAlgo.ets），本地测试环境可直接 import。
 * 锁定目标（AppController.cs:429-478 UpdateToolbarButtonState 逐分支）：
 *   进行中视图：0 选=delete0+pv1/ofv0；1 选 active=p1/r0/del1；1 选停态=p0/r1；2 选=p1/r1/del1；
 *   完成视图：1 选=of1/ofF1/pv0/del1；0 选=delete0；
 *   singleIsActive=true（Waiting/排队算 active，IsDownloadActive :562-565 同构）归 pause 分支。
 */

import { describe, it, expect } from '@ohos/hypium';
import { ToolbarState, computeToolbarState } from '../main/ets/core/util/ToolbarAlgo';

export default function toolbarAlgoTest(): void {
  describe('ToolbarAlgo', () => {
    it('inProgress_zeroSelected', 0, () => {
      // :437-445：Pause/Resume 可见均禁用；Delete 禁用；OpenFile/OpenFolder 不可见
      const state: ToolbarState = computeToolbarState(true, 0, false);
      expect(state.pauseVisible).assertTrue();
      expect(state.resumeVisible).assertTrue();
      expect(state.pauseEnabled).assertFalse();
      expect(state.resumeEnabled).assertFalse();
      expect(state.deleteEnabled).assertFalse();
      expect(state.openFileVisible).assertFalse();
      expect(state.openFolderVisible).assertFalse();
      expect(state.openFileEnabled).assertFalse();
      expect(state.openFolderEnabled).assertFalse();
    });

    it('inProgress_singleActive_pauseEnabled', 0, () => {
      // :451-463 选中 1 个运行中行（isActive）→ Pause
      const state: ToolbarState = computeToolbarState(true, 1, true);
      expect(state.pauseEnabled).assertTrue();
      expect(state.resumeEnabled).assertFalse();
      expect(state.deleteEnabled).assertTrue();
    });

    it('inProgress_singleIdle_resumeEnabled', 0, () => {
      // :459-462 选中 1 个停态行 → Resume
      const state: ToolbarState = computeToolbarState(true, 1, false);
      expect(state.pauseEnabled).assertFalse();
      expect(state.resumeEnabled).assertTrue();
      expect(state.deleteEnabled).assertTrue();
    });

    it('inProgress_multiSelected_bothEnabled', 0, () => {
      // :446-450 选中 >1 → Pause+Resume 均启用（复选框路径可达，D3；状态机本体 1:1）
      const state: ToolbarState = computeToolbarState(true, 2, false);
      expect(state.pauseEnabled).assertTrue();
      expect(state.resumeEnabled).assertTrue();
      expect(state.deleteEnabled).assertTrue();
    });

    it('finished_singleSelected_openEnabled', 0, () => {
      // :465-478：OpenFile/OpenFolder 可见+启用；Pause/Resume 不可见；Delete 启用
      const state: ToolbarState = computeToolbarState(false, 1, false);
      expect(state.openFileVisible).assertTrue();
      expect(state.openFolderVisible).assertTrue();
      expect(state.openFileEnabled).assertTrue();
      expect(state.openFolderEnabled).assertTrue();
      expect(state.pauseVisible).assertFalse();
      expect(state.resumeVisible).assertFalse();
      expect(state.deleteEnabled).assertTrue();
    });

    it('finished_zeroSelected_deleteDisabled', 0, () => {
      // :469-478：0 选 → Open 可见但禁用、Delete 禁用
      const state: ToolbarState = computeToolbarState(false, 0, false);
      expect(state.openFileVisible).assertTrue();
      expect(state.openFolderVisible).assertTrue();
      expect(state.openFileEnabled).assertFalse();
      expect(state.openFolderEnabled).assertFalse();
      expect(state.deleteEnabled).assertFalse();
    });

    it('inProgress_waitingCountsAsActive_pauseBranch', 0, () => {
      // Waiting/排队行算 active（IsDownloadActive=live||queued）→ pause 分支；
      // 与 1 选停态反相（D17：resumeOne 对排队 id 幂等 return 的死态不复现）
      const activeState: ToolbarState = computeToolbarState(true, 1, true);
      expect(activeState.pauseEnabled).assertTrue();
      expect(activeState.resumeEnabled).assertFalse();
      const idleState: ToolbarState = computeToolbarState(true, 1, false);
      expect(idleState.pauseEnabled).assertFalse();
      expect(idleState.resumeEnabled).assertTrue();
    });
  });
}
