/*
 * OPT-1 分类面板组件（设计书 §1-#3）：纯搬迁自 Index.ets:115-155 常量区 + :1827-1851 面板区 +
 * :1639-1643 CategoryIcon @Builder（零行为变更拆分，差异 #5 鸿蒙化结构等价变换）。
 * 行底色三元 $r('app.color.category_highlight'/'category_normal_bg')（§2.1 键 3/4——原 Index
 * :157/:158 两常量删除；'#E3F2FD' 同值不同义拆 category_normal_bg/row_selected_bg 两键，
 * dark 侧分叉 #1B1C1E vs #114C7B，拍板 4）；行字色双态显式（键 5/11）：选中
 * category_selected_text / 未选中 text_secondary——ask ③a 对比度收口项，浅色未选中字由
 * 系统黑变 #5B6B79 为全单元唯一有意浅色可见变化（差异 #2）。
 * 事件面上抛唯一口：onSelectCategory → Index.selectCategory（分类状态机逻辑逐字节留 Index）；
 * 计数经 @Prop categoryCounts 同步（Index.recomputeCounts 整体替换赋值语义不变）。
 * 业务文件红线：零 probe import。
 */

/** 分类面板项（7 项：2 顶层+5 预定义，MainWindow.xaml.cs:74-80 categories 构造同构） */
interface CategoryPanelItem {
  index: number;
  panelKey: string;
  label: ResourceStr;
  iconKey: string;
}

/** 分类面板常量表（顶层复用 lbl_active/lbl_complete——与源键 ALL_UNFINISHED/ALL_FINISHED 同值 D11） */
const CATEGORY_PANEL: CategoryPanelItem[] = [
  { index: 0, panelKey: 'cat0', label: $r('app.string.lbl_active'), iconKey: 'ALL_ACTIVE' },
  { index: 1, panelKey: 'cat1', label: $r('app.string.lbl_complete'), iconKey: 'ALL_FINISHED' },
  { index: 2, panelKey: 'cat2', label: $r('app.string.cat_documents'), iconKey: 'CAT_DOCUMENTS' },
  { index: 3, panelKey: 'cat3', label: $r('app.string.cat_music'), iconKey: 'CAT_MUSIC' },
  { index: 4, panelKey: 'cat4', label: $r('app.string.cat_videos'), iconKey: 'CAT_VIDEOS' },
  { index: 5, panelKey: 'cat5', label: $r('app.string.cat_compressed'), iconKey: 'CAT_COMPRESSED' },
  { index: 6, panelKey: 'cat6', label: $r('app.string.cat_programs'), iconKey: 'CAT_PROGRAMS' }
];

/** 分类面板图标（GetVectorNameForCategory 同构映射；sys.symbol 名对照本机 SDK 系统资源表核实） */
function categoryIconResource(iconKey: string): Resource {
  if (iconKey === 'ALL_ACTIVE') {
    return $r('sys.symbol.arrow_down');
  }
  if (iconKey === 'ALL_FINISHED') {
    return $r('sys.symbol.checkmark');
  }
  if (iconKey === 'CAT_DOCUMENTS') {
    return $r('sys.symbol.doc_plaintext');
  }
  if (iconKey === 'CAT_MUSIC') {
    return $r('sys.symbol.music_note_list');
  }
  if (iconKey === 'CAT_VIDEOS') {
    return $r('sys.symbol.video');
  }
  if (iconKey === 'CAT_COMPRESSED') {
    return $r('sys.symbol.archivebox');
  }
  return $r('sys.symbol.hammer_fill');
}

@Component
export struct CategoryPanel {
  /** 选中高亮（Index @State 同步；默认 1=已完成视图，与 Index D15 默认一致） */
  @Prop activeCategoryIndex: number = 1;
  /** 7 槽计数（Index.recomputeCounts 整体替换 → @Prop 深拷贝同步 → 行计数刷新） */
  @Prop categoryCounts: number[] = [0, 0, 0, 0, 0, 0, 0];
  onSelectCategory: (index: number) => void = (index: number): void => {
  };

  /** 分类面板图标格（原 Index.CategoryIcon 原样搬迁） */
  @Builder
  CategoryIcon(iconKey: string) {
    SymbolGlyph(categoryIconResource(iconKey))
      .fontSize(18)
      .fontColor([$r('app.color.text_primary')])
  }

  build() {
    Column({ space: 2 }) {
      ForEach(CATEGORY_PANEL, (item: CategoryPanelItem) => {
        Row({ space: 8 }) {
          this.CategoryIcon(item.iconKey)
          Text(item.label)
            .fontSize(13)
            .maxLines(1)
            .layoutWeight(1)
            .fontColor(item.index === this.activeCategoryIndex
              ? $r('app.color.category_selected_text')
              : $r('app.color.text_secondary'))
          Text(String(this.categoryCounts[item.index]))
            .fontSize(12)
            .opacity(0.6)
        }
        .width('100%')
        .padding({ left: 10, right: 10, top: 8, bottom: 8 })
        .borderRadius(8)
        .backgroundColor(item.index === this.activeCategoryIndex
          ? $r('app.color.category_highlight')
          : $r('app.color.category_normal_bg'))
        .onClick(() => {
          this.onSelectCategory(item.index);
        })
      }, (item: CategoryPanelItem) => item.panelKey)
    }
    .width(190)
    .height('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 4 })
  }
}
