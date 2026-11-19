/*
 * U4.2 批量下载对话框（设计书 §3.1/§5.8；对照 BatchDownloadUIController.cs +
 * BatchDownloadWindow.xaml.cs，本会话逐行核对）。
 * 形态：@CustomDialog 非模态（源 Show() Run :42-45 → isModal:false，
 * custom_dialog_controller.d.ts:371 核实）；宿主=Index 单实例 controller。
 * 双 tab（TabControl）：tab0=Pattern 工作页、tab1=Links 死页——源 IsBatchMode=SelectedIndex==0
 * （xaml.cs:29），tab1 时 OK no-op（UIController.cs:49 门），死 UI 渲染静态文案不接线（差异 #7
 * 源码同貌：BAT_PASTE_LINK 文案 + 无输入控件绑定）。
 * Pattern 页控件面（xaml）：地址输入（LBL_BATCH_DESC 提示）、CmbType（Letters/Numbers 双项）、
 * CmbLetterFrom/To（26 项 A..Z，UIController ctor :22-27 SetStartLetterRange/SetEndLetterRange）、
 * TxtNumberFrom/To（ParseIntSafe 失败=0）、ChkLeadingZero+TxtLeadingZero、
 * 三预览（BAT_FILE1/2/N）+BatchSize 计数。
 * 重算触发五点（xaml.cs TxtAddress_TextChanged/CmbType_SelectionChanged/CmbLetter*_SelectionChanged/
 * ChkLeadingZero Checked+Unchecked/TxtLostFocus → PatternChanged）：地址 onChange/模式切换/字母选择/
 * 补零勾选/数字框 onBlur——无防抖（源码即时重算，§3.1 线程模型）。
 * OK（OnOKClicked :47-66 1:1）：非 Pattern tab 直接 return；links 空/null → BAT_SELECT_ITEMS
 * 提示不关窗；否则 onConfirm(links)+close（Index 回调里开选择窗——顺序=源 DestroyWindow→
 * ShowDownloadSelectionWindow）。
 * 数字输入整数过滤（源 TxtPreviewTextInput 按键拦截）→ onChange 剥非数字重写（差异 #15 等价）。
 * 红线：本文件 import 图禁 probe/**；零 [XDM_PROBE] 输出。
 */

import { BatchParams, BatchPreview, generateBatchLinks, computeBatchPreview } from '../core/util/BatchAlgo';
import { isUriValid } from '../core/net/HttpProtocol';

/** 26 字母表（UIController ctor :20 arr 同源） */
const LETTERS: string[] = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split('');

@CustomDialog
export struct BatchDownloadDialog {
  controller?: CustomDialogController;
  /** 确认回调：生成链接串（Index 关本窗后开选择窗） */
  onConfirm: (links: string[]) => void = (links: string[]) => {
  };
  onCancel: () => void = () => {
  };
  /** TabControl.SelectedIndex（IsBatchMode=0 门） */
  @State activeTab: number = 0;
  @State url: string = '';
  @State isLetterMode: boolean = true;
  /** 字母下标（-1=未选，C# SelectedIndex<0 → char? null 同构） */
  @State startLetterIndex: number = -1;
  @State endLetterIndex: number = -1;
  @State startNumberText: string = '0';
  @State endNumberText: string = '0';
  @State useLeadingZero: boolean = false;
  @State leadingZeroText: string = '0';
  @State preview: BatchPreview = new BatchPreview();

  /** ParseIntSafe 等价（ParsingHelper.cs:47 失败=0；整数过滤后恒数字或空） */
  private parseSafeInt(text: string): number {
    if (text.length === 0) {
      return 0;
    }
    const parsed: number = Number(text);
    if (!Number.isFinite(parsed)) {
      return 0;
    }
    return Math.trunc(parsed);
  }

  private letterOf(index: number): string {
    return index >= 0 && index < LETTERS.length ? LETTERS[index] : '';
  }

  /** 表单→BatchParams 投影（§2.3 八字段） */
  private currentParams(): BatchParams {
    const params: BatchParams = new BatchParams();
    params.url = this.url;
    params.isLetterMode = this.isLetterMode;
    params.startLetter = this.letterOf(this.startLetterIndex);
    params.endLetter = this.letterOf(this.endLetterIndex);
    params.startNumber = this.parseSafeInt(this.startNumberText);
    params.endNumber = this.parseSafeInt(this.endNumberText);
    params.useLeadingZero = this.useLeadingZero;
    params.leadingZeroCount = this.parseSafeInt(this.leadingZeroText);
    return params;
  }

  /** 预览重算（OnBatchPatternChange :68-103 语义 1:1）：null 与 [] 统一**静默清空**预览
   * （R2-F2 勘误：源公共 GenerateBatchLink :108-116 catch 全部异常返回 Empty，
   * OnBatchPatternChange 的 catch(UriFormatException) :95-98 不可达——运行时预览从不弹窗；
   * ArkTS 侧暂态非法（含 '*' 且候选非法）若弹模态框会反复打断输入。null 语义仅保留给
   * BatchAlgo 纯函数单测/OK 路径消费——OK 路径 null/[] 均 BAT_SELECT_ITEMS 不变） */
  private recomputePreview(): void {
    const links: string[] | null = generateBatchLinks(this.currentParams(), isUriValid);
    if (links === null || links.length === 0) {
      this.preview = new BatchPreview();
      return;
    }
    this.preview = computeBatchPreview(links);
  }

  /** OK（OnOKClicked :47-66：IsBatchMode 门 → 空生成 BAT_SELECT_ITEMS → 确认链） */
  private handleOk(): void {
    // :49 IsBatchMode 门——Links 死 tab OK no-op（差异 #7 源码同貌）
    if (this.activeTab !== 0) {
      return;
    }
    const links: string[] | null = generateBatchLinks(this.currentParams(), isUriValid);
    if (links === null || links.length === 0) {
      this.showMsg($r('app.string.bat_select_items'));
      return;
    }
    this.onConfirm(links);
    this.controller?.close();
  }

  private handleCancel(): void {
    this.onCancel();
    this.controller?.close();
  }

  private showMsg(message: ResourceStr): void {
    this.getUIContext().showAlertDialog({
      message: message,
      primaryButton: {
        value: 'OK',
        action: () => {
        }
      }
    });
  }

  /** 字母 26 项下拉源（SetStartLetterRange/SetEndLetterRange 同源） */
  private letterOptions(): SelectOption[] {
    const options: SelectOption[] = [];
    for (let i = 0; i < LETTERS.length; i++) {
      const option: SelectOption = { value: LETTERS[i] };
      options.push(option);
    }
    return options;
  }

  build() {
    Column({ space: 10 }) {
      Tabs({ index: this.activeTab, barPosition: BarPosition.Start }) {
        TabContent() {
          // ── Pattern 工作页 ──
          Column({ space: 8 }) {
            Text($r('app.string.lbl_batch_desc'))
              .fontSize(11)
              .opacity(0.7)
              .width('100%')
            TextInput({ text: this.url, placeholder: 'http://' })
              .onChange((value: string) => {
                this.url = value;
                this.recomputePreview();
              })
              .width('100%')
            Row({ space: 8 }) {
              Text($r('app.string.lbl_batch_asterisk'))
                .fontSize(13)
              Column({ space: 6 }) {
                Row({ space: 8 }) {
                  Radio({ value: 'letters', group: 'batchMode' })
                    .checked(this.isLetterMode)
                    .onChange((value: boolean) => {
                      if (value && !this.isLetterMode) {
                        this.isLetterMode = true;
                        this.recomputePreview();
                      }
                    })
                  Text($r('app.string.lbl_batch_letter'))
                    .fontSize(13)
                  Radio({ value: 'numbers', group: 'batchMode' })
                    .checked(!this.isLetterMode)
                    .onChange((value: boolean) => {
                      if (value && this.isLetterMode) {
                        this.isLetterMode = false;
                        this.recomputePreview();
                      }
                    })
                  Text($r('app.string.lbl_batch_num'))
                    .fontSize(13)
                }
                .width('100%')

                if (this.isLetterMode) {
                  Row({ space: 8 }) {
                    Text($r('app.string.lbl_batch_from'))
                      .fontSize(12)
                    Select(this.letterOptions())
                      .selected(this.startLetterIndex)
                      .value(this.letterOf(this.startLetterIndex))
                      .onSelect((index: number, value: string) => {
                        this.startLetterIndex = index;
                        this.recomputePreview();
                      })
                      .layoutWeight(1)
                    Text($r('app.string.lbl_batch_to'))
                      .fontSize(12)
                    Select(this.letterOptions())
                      .selected(this.endLetterIndex)
                      .value(this.letterOf(this.endLetterIndex))
                      .onSelect((index: number, value: string) => {
                        this.endLetterIndex = index;
                        this.recomputePreview();
                      })
                      .layoutWeight(1)
                  }
                  .width('100%')
                } else {
                  Row({ space: 8 }) {
                    Text($r('app.string.lbl_batch_from'))
                      .fontSize(12)
                    TextInput({ text: this.startNumberText })
                      .layoutWeight(1)
                      .onChange((value: string) => {
                        this.startNumberText = value.replace(new RegExp('[^0-9]', 'g'), '');
                      })
                      .onBlur(() => {
                        this.recomputePreview();
                      })
                    Text($r('app.string.lbl_batch_to'))
                      .fontSize(12)
                    TextInput({ text: this.endNumberText })
                      .layoutWeight(1)
                      .onChange((value: string) => {
                        this.endNumberText = value.replace(new RegExp('[^0-9]', 'g'), '');
                      })
                      .onBlur(() => {
                        this.recomputePreview();
                      })
                  }
                  .width('100%')
                }

                Row({ space: 8 }) {
                  Toggle({ type: ToggleType.Checkbox, isOn: this.useLeadingZero })
                    .onChange((value: boolean) => {
                      this.useLeadingZero = value;
                      this.recomputePreview();
                    })
                  Text($r('app.string.bat_leading_zero'))
                    .fontSize(12)
                  TextInput({ text: this.leadingZeroText })
                    .width(60)
                    .onChange((value: string) => {
                      this.leadingZeroText = value.replace(new RegExp('[^0-9]', 'g'), '');
                    })
                    .onBlur(() => {
                      this.recomputePreview();
                    })
                }
                .width('100%')
              }
              .layoutWeight(1)
            }
            .width('100%')

            Column({ space: 4 }) {
              Text($r('app.string.lbl_batch_file1'))
                .fontSize(12)
                .width('100%')
              Text(this.preview.first.length > 0 ? this.preview.first : '-')
                .fontSize(11)
                .opacity(0.7)
                .maxLines(1)
                .width('100%')
              Text($r('app.string.lbl_batch_file2'))
                .fontSize(12)
                .width('100%')
              Text(this.preview.second.length > 0 ? this.preview.second : '-')
                .fontSize(11)
                .opacity(0.7)
                .maxLines(1)
                .width('100%')
              Text($r('app.string.lbl_batch_filen'))
                .fontSize(12)
                .width('100%')
              Text(this.preview.last.length > 0 ? this.preview.last : '-')
                .fontSize(11)
                .opacity(0.7)
                .maxLines(1)
                .width('100%')
            }
            .width('100%')

            Row({ space: 12 }) {
              Button($r('app.string.nd_cancel'))
                .onClick(() => {
                  this.handleCancel();
                })
              Button($r('app.string.msg_ok'))
                .onClick(() => {
                  this.handleOk();
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.End)
          }
          .width('100%')
          .padding(4)
        }
        .tabBar($r('app.string.bat_pattern'))

        TabContent() {
          // ── Links 死页（差异 #7：源 :49 IsBatchMode 门=死 UI，渲染静态文案不接线） ──
          Column({ space: 8 }) {
            Text($r('app.string.bat_paste_link'))
              .fontSize(13)
              .width('100%')
            Text('-')
              .fontSize(12)
              .opacity(0.6)
              .width('100%')
          }
          .width('100%')
          .padding(4)
        }
        .tabBar($r('app.string.bat_links'))
      }
      .onChange((index: number) => {
        this.activeTab = index;
      })
      .barWidth('100%')
      .width('100%')
    }
    .width(420)
    .padding(16)
  }
}
