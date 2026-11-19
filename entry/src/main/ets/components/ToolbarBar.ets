/*
 * OPT-1 工具栏行组件（设计书 §1-#4）：纯搬迁自 Index.ets:1855-1931 整行（零行为变更拆分，
 * 差异 #5）。六钮（New/ Delete/OpenFile/OpenFolder/Pause/Resume）+Blank+搜索 TextInput+
 * 搜索钮+汉堡钮；New/汉堡 bindMenu 菜单数据由 Index 装配传入（普通成员 MenuElement[]——
 * action 闭包捕获 Index this，语义与原 Index.build 内 bindMenu(this.newMenuItems()) 等价）。
 * 状态传递：toolbarState @Prop 整体快照——Index `this.toolbarState = computeToolbarState(...)`
 * 整体替换 → @Prop 同步 → 本组件重渲染（class 整体替换触发语义不变，§3.3）；searchText @Link
 * 双向（TextInput 输入回写 Index @State，触发点=搜索按钮/分类切换 D13 不变）。
 * 五回调上抛：onDeleteClick/onOpenAction/onPauseClick/onResumeClick/onSearchClick——五事件
 * 处理器与工具栏状态机逐字节留 Index（事件面零破坏红线）。钮面 $r('app.color.control_bg')
 * （§2.1 键 6，base=原 '#F1F3F5' 逐字节，dark=DarkTheme ControlBackcolor #1B1C1E）。
 * 业务文件红线：零 probe import。
 */

import { ToolbarState } from '../core/util/ToolbarAlgo';

/** 搜索框组件 id（Ctrl+F 经 focusControl.requestFocus 定位） */
export const SEARCH_INPUT_ID: string = 'xdm-search-input';

@Component
export struct ToolbarBar {
  /** 六钮 enabled+四钮 visible 快照（Index.recomputeToolbar 整体替换同步） */
  @Prop toolbarState: ToolbarState = new ToolbarState();
  /** 搜索框双向（父侧 $searchText 传入；输入即回写 Index @State） */
  @Link searchText: string;
  /** New 下拉 3 项（Index.newMenuItems() 装配传入；第 1 项开对话框/第 2 项占位禁用 D5） */
  newMenuItems: MenuElement[] = [];
  /** 汉堡菜单 12 项（Index.mainMenuItems() 装配传入） */
  mainMenuItems: MenuElement[] = [];
  onDeleteClick: () => void = (): void => {
  };
  onOpenAction: (button: string) => void = (button: string): void => {
  };
  onPauseClick: () => void = (): void => {
  };
  onResumeClick: () => void = (): void => {
  };
  onSearchClick: () => void = (): void => {
  };
  /** 搜索框获焦/失焦（Index 据此避免 Delete/Ctrl+A 等快捷键抢走文本编辑按键） */
  onSearchFocusChange: (focused: boolean) => void = (focused: boolean): void => {
  };

  build() {
    Row({ space: 6 }) {
      Button($r('app.string.desc_new'))
        .fontSize(13)
        .height(32)
        .backgroundColor($r('app.color.control_bg'))
        .fontColor($r('app.color.text_primary'))
        .bindMenu(this.newMenuItems)
      Button($r('app.string.desc_del'))
        .fontSize(13)
        .height(32)
        .backgroundColor($r('app.color.control_bg'))
        .fontColor($r('app.color.text_primary'))
        .enabled(this.toolbarState.deleteEnabled)
        .onClick(() => {
          this.onDeleteClick();
        })
      Button($r('app.string.ctx_open_file'))
        .fontSize(13)
        .height(32)
        .backgroundColor($r('app.color.control_bg'))
        .fontColor($r('app.color.text_primary'))
        .visibility(this.toolbarState.openFileVisible ? Visibility.Visible : Visibility.None)
        .enabled(this.toolbarState.openFileEnabled)
        .onClick(() => {
          this.onOpenAction('openFile');
        })
      Button($r('app.string.ctx_open_folder'))
        .fontSize(13)
        .height(32)
        .backgroundColor($r('app.color.control_bg'))
        .fontColor($r('app.color.text_primary'))
        .visibility(this.toolbarState.openFolderVisible ? Visibility.Visible : Visibility.None)
        .enabled(this.toolbarState.openFolderEnabled)
        .onClick(() => {
          this.onOpenAction('openFolder');
        })
      Button($r('app.string.menu_pause'))
        .fontSize(13)
        .height(32)
        .backgroundColor($r('app.color.control_bg'))
        .fontColor($r('app.color.text_primary'))
        .visibility(this.toolbarState.pauseVisible ? Visibility.Visible : Visibility.None)
        .enabled(this.toolbarState.pauseEnabled)
        .onClick(() => {
          this.onPauseClick();
        })
      Button($r('app.string.menu_resume'))
        .fontSize(13)
        .height(32)
        .backgroundColor($r('app.color.control_bg'))
        .fontColor($r('app.color.text_primary'))
        .visibility(this.toolbarState.resumeVisible ? Visibility.Visible : Visibility.None)
        .enabled(this.toolbarState.resumeEnabled)
        .onClick(() => {
          this.onResumeClick();
        })
      Blank()
      // 搜索行（:448-493：输入只改 @State，触发点=搜索按钮/分类切换 D13）
      TextInput({ placeholder: $r('app.string.lbl_search'), text: this.searchText })
        .width(100)
        .height(32)
        .id(SEARCH_INPUT_ID)
        .onChange((value: string) => {
          this.searchText = value;
        })
        .onFocus(() => {
          this.onSearchFocusChange(true);
        })
        .onBlur(() => {
          this.onSearchFocusChange(false);
        })
        .onSubmit(() => {
          this.onSearchClick();
        })
      Button() {
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontSize(16)
          .fontColor([$r('app.color.text_primary')])
      }
      .width(36)
      .height(32)
      .backgroundColor($r('app.color.control_bg'))
      .onClick(() => {
        this.onSearchClick();
      })
      Button() {
        SymbolGlyph($r('sys.symbol.line_3_horizontal'))
          .fontSize(16)
          .fontColor([$r('app.color.text_primary')])
      }
      .width(36)
      .height(32)
      .backgroundColor($r('app.color.control_bg'))
      .bindMenu(this.mainMenuItems)
    }
    .width('100%')
  }
}
