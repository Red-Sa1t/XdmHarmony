/*
 * U4.1 下载行组件（设计书 §5.8；自 Index.ets:348-393 内嵌卡片布局抽出重写）。
 * 列结构对照 MainWindow.xaml 进行中模板（:590-650）：Name200[图标 24×24+名]/DateAdded80/
 * Size60/%50(ProgressBar 高 5，:640-647 模板同构 D18)/Status150——状态列=generateStatusText
 * 单 Text（xaml:641 DisplayMemberBinding=StatusText 同貌，U1.2 卡片遗形移除 D18）；
 * 完成模板（:650-712）：Name400/DateAdded80/Size60（名称列 flex4 vs 进行中 flex3 同比例）。
 * 行为（D3 混合方案）：行内容区点击=单选替换（onSelect，见 build 注——点击面排除 Checkbox/按钮列）；
 * 行内 Checkbox=多选开关（onToggleSelect）；
 * 行按钮三分支（D17/D10）：Downloading→暂停 / Waiting→取消排队（btn_cancel_queue 新键）/
 * 否则→继续，点击 onToggle 上抛 Index.handleToggle。
 * @ObjectLink 只读红线：record 字段在本组件内零写入（回调全部上抛 Index 单写者）；
 * 字段级刷新（progress/status/uiSelected）由 @Observed 直驱，零 notifyDataChange。
 * 图标载体（D8）：iconCategoryKeyForExtension 映射规则 1:1（CategoryAlgo 单测锁定）；
 * Vector Path→SymbolGlyph——sys.symbol 名已对照本机 SDK 系统资源表核实
 * （openharmony/previewer/common/resources/entry/resources.txt，符号字体段代码点 0xF 系）；
 * 'Other' 键与无扩展名 → 扩展名首字母大写 Text 兜底（设计书 §5.8/§8-1）。
 * 列格常量导出供 Index 表头行共用（§5.9 禁两处魔法数漂移）。
 * OPT-1 四处资源化（设计书 §1-#8）：行底两常量删除改语义色资源（base 值=原 hex 逐字节浅色零回归，
 * dark 取 DarkTheme ListViewSelectedBackcolor #114C7B/ListViewBackcolor #232428——U4.3
 * setColorMode 切换链零改动自动生效）；日期/大小次文本 fontColor 改 $r('app.color.text_secondary')
 * （dark=#B5BCC9=DarkTheme ListViewForecolor）。rowBackground 返回类型 string→Resource（三元两侧
 * 同为 Resource，ArkTS 编译期强制）。@ObjectLink 只读/toggleLabel 三分支/列常量导出零改动。
 */

import { fileExtensionOf, iconCategoryKeyForExtension } from '../core/util/CategoryAlgo';
import { StatusLabels, generateStatusText } from '../core/util/StatusText';
import { DownloadStatus } from '../model/DownloadTypes';
import { DownloadRecord } from '../model/DownloadRecord';
import { formatDate, formatSize } from '../core/util/Formatting';

/** 列格常量（Index 表头行与行组件共用同一组——§5.9；宽度对照 xaml 列宽比例 + 图标 24×24 Margin 5,5） */
export const COL_CHECKBOX_WIDTH: number = 28;
export const COL_ICON_WIDTH: number = 34;
export const COL_BUTTON_WIDTH: number = 76;
export const COL_FLEX_NAME_INPROGRESS: number = 3;
export const COL_FLEX_NAME_FINISHED: number = 4;
export const COL_FLEX_DATE: number = 1;
export const COL_FLEX_SIZE: number = 1;
export const COL_FLEX_PROGRESS: number = 0.8;
export const COL_FLEX_STATUS: number = 1.5;

// OPT-1：原 ROW_SELECTED_BG/ROW_NORMAL_BG 两行底常量删除改语义色资源（设计书 §1-#8"两常量删除"）
// ——'#E3F2FD' 行选中底与 Index 分类面板常态底同值不同义，拆 row_selected_bg/row_normal_bg
// 两键使 dark 侧分叉（#114C7B vs #1B1C1E，设计书 §0-4 拍板）；$r 内联于 rowBackground()。

@Component
export struct DownloadListItem {
  @ObjectLink record: DownloadRecord;
  /** 运行时切换语言后由 Index 自增（labels 原地改写不触发重渲染，靠此依赖刷新状态列） */
  @StorageProp('xdmLabelsVersion') labelsVersion: number = 0;
  /** 进行中 true / 完成 false（Tab 语义保留：完成行无 %/状态/按钮） */
  showToggle: boolean = false;
  /** 状态列标签（Index 装配一次传入——getStringSync 或英文常量；行内零资源查询） */
  labels: StatusLabels = {
    downloading: 'Downloading',
    stopped: 'Stopped',
    finished: 'Finished',
    waiting: 'Waiting'
  };
  onSelect: (id: string) => void = (id: string): void => {
  };
  onToggleSelect: (id: string) => void = (id: string): void => {
  };
  onToggle: (id: string) => void = (id: string): void => {
  };

  /** 行底（WPF ListViewItem 选中/常态背景同位；OPT-1 返回类型 string→Resource——三元两侧同为
   * Resource，深浅色经资源限定词自动解析） */
  private rowBackground(): Resource {
    return this.record.uiSelected ? $r('app.color.row_selected_bg') : $r('app.color.row_normal_bg');
  }

  private nameFlex(): number {
    return this.showToggle ? COL_FLEX_NAME_INPROGRESS : COL_FLEX_NAME_FINISHED;
  }

  /** 行按钮标签三分支（D17/D10）：Waiting→取消排队新键 */
  private toggleLabel(): ResourceStr {
    if (this.record.status === DownloadStatus.Downloading) {
      return $r('app.string.menu_pause');
    }
    if (this.record.status === DownloadStatus.Waiting) {
      return $r('app.string.btn_cancel_queue');
    }
    return $r('app.string.menu_resume');
  }

  /** FileTypeIcon 分类键（IconMap.GetVectorNameForFileType 同构：GetExtension→lower→imageTypes） */
  private iconKey(): string {
    return iconCategoryKeyForExtension(fileExtensionOf(this.record.name ?? '').toLowerCase());
  }


  /** 文件类型图标 24×24（D8：五分类键→SymbolGlyph；Other/异常→通用文件图标 sys.symbol.doc） */
  @Builder
  FileTypeIcon() {
    if (this.iconKey() === 'CAT_COMPRESSED') {
      SymbolGlyph($r('sys.symbol.archivebox_fill')).fontSize(24).fontColor([$r('app.color.text_primary')])
    } else if (this.iconKey() === 'CAT_MUSIC') {
      SymbolGlyph($r('sys.symbol.music_note_list_fill')).fontSize(24).fontColor([$r('app.color.text_primary')])
    } else if (this.iconKey() === 'CAT_VIDEOS') {
      SymbolGlyph($r('sys.symbol.video_fill')).fontSize(24).fontColor([$r('app.color.text_primary')])
    } else if (this.iconKey() === 'CAT_DOCUMENTS') {
      SymbolGlyph($r('sys.symbol.doc_plaintext_fill')).fontSize(24).fontColor([$r('app.color.text_primary')])
    } else if (this.iconKey() === 'CAT_PROGRAMS') {
      SymbolGlyph($r('sys.symbol.hammer_fill')).fontSize(24).fontColor([$r('app.color.text_primary')])
    } else {
      // 2026-11-19：其他类型由首字母兜底改为通用文件图标（单个字母在列表中辨识度差）
      SymbolGlyph($r('sys.symbol.doc')).fontSize(24).fontColor([$r('app.color.text_primary')])
    }
  }

  /** 名称列（源 Name 列含图标+名——图标独立定宽列后本列只承载文本；ellipsis 单行） */
  @Builder
  NameCell() {
    Text(this.record.name ?? '')
      .fontSize(14)
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .layoutWeight(this.nameFlex())
  }

  build() {
    // 行选择点击面（R2-F2 修正）：外层行不挂 onClick——本 SDK ClickEvent 无 stopPropagation
    // （common.d.ts:11591 区段仅 preventDefault；stopPropagation 属 HoverEvent:11918/MouseEvent:
    // 12119/TouchEvent:12772，onClick 回调参型是 ClickEvent:22591——上轮事件拦截方案编译不可达）。
    // 结构性隔离：onSelect 挂内容区 Row（排除 Checkbox 列与按钮列），Checkbox/按钮点击天然
    // 不触发行单选替换，多选路径（走查项 13）确定性成立；表头列对齐不变量保持——内容区
    // layoutWeight(1) 后列 flex 分配的剩余宽度与表头（扣除同三段定宽格）完全一致。
    Row() {
      // Checkbox 区（多选开关，D3）。selected 态走 .select() 属性（CheckboxOptions 无 selected
      // 字段——checkbox.d.ts 核实），record.uiSelected（@Observed）变化 → 行重渲染 → select 同步。
      Row() {
        Checkbox({ name: this.record.id, group: 'downloadList' })
          .select(this.record.uiSelected)
          .onChange((value: boolean) => {
            // 程序化 .select(uiSelected) 回写若触发 onChange：与现值相同即吞（R2-F2 防选中态振荡）
            if (value === this.record.uiSelected) {
              return;
            }
            this.onToggleSelect(this.record.id);
          })
      }
      .width(COL_CHECKBOX_WIDTH)

      // 内容区=行选择点击面（图标+名称/日期/大小/%/状态列；WPF ListView 子项点击皆选中同貌）
      Row() {
        Row() {
          this.FileTypeIcon()
        }
        .width(COL_ICON_WIDTH)

        this.NameCell()

        Text(formatDate(this.record.dateAdded))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .layoutWeight(COL_FLEX_DATE)

        Text(formatSize(this.record.size))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .layoutWeight(COL_FLEX_SIZE)

        if (this.showToggle) {
          // % 列（xaml:640-647 ProgressBar Height=5 模板同构 D18；行内不再另画全宽进度条）
          Progress({ value: this.record.progress, total: 100, type: ProgressType.Linear })
            .height(5)
            .layoutWeight(COL_FLEX_PROGRESS)

          // 状态列=单 Text（xaml:641 StatusText 同貌；speed/eta 合成见 StatusText.ets）
          Text(this.labelsVersion >= 0 ?
            generateStatusText(this.record.status, this.record.downloadSpeed, this.record.eta, this.labels) : '')
            .fontSize(12)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(COL_FLEX_STATUS)
        }
      }
      .layoutWeight(1)
      .onClick(() => {
        this.onSelect(this.record.id);
      })

      if (this.showToggle) {
        Row() {
          Button(this.toggleLabel())
            .fontSize(12)
            .height(26)
            .padding({ left: 8, right: 8 })
            .onClick(() => {
              this.onToggle(this.record.id);
            })
        }
        .width(COL_BUTTON_WIDTH)
        .justifyContent(FlexAlign.End)
      }
    }
    .width('100%')
    .padding({ left: 6, right: 6, top: 8, bottom: 8 })
    .borderRadius(8)
    .backgroundColor(this.rowBackground())
  }
}
