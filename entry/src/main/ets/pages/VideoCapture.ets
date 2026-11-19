/*
 * U6.2 视频捕获页（设计书 u6-2 §3.9，对照 XDM.Wpf.UI/Dialogs/MediaCapture/MediaCaptureWindow.xaml(.cs)）。
 * 布局（xaml :1-41）：列表两列 **Name(400px)/Quality(150px)** = MediaInfo.Name/Description（xaml :34-37）；
 * 底部按钮 **Close（左）/ Download / Clear（右）**（xaml :18-26）。
 * 行为（.cs :18-128）：
 *   - 构造订阅 MediaAdded/MediaUpdated + 预填 GetVideoList() 存量（:50-64）→ aboutToAppear 注册
 *     TrackerListener + tracker.getTrackedVideos() 预填；aboutToDisappear 注销（Closing :94-99）。
 *   - 事件到达**重取全表重渲染**（源 AddMedia/UpdateMedia 按 ID 增改——观测收敛等价，设计书 §4-8）。
 *   - Clear（:73-77）：tracker.clearVideoList() + 本地清空。
 *   - Download（:79-88）：源为 SelectedIndex 单选；本页按单元指令落**全选/多选增强**（§4-8，依据
 *     单元指令与 UNIT_CATALOG『全选』）：组头全选 Toggle+行 Toggle，Download 按选中序逐 id
 *     tracker.addVideoDownload(id)（**每 id 动作 1:1 源**；对话框/自动事件由 BridgeUiEvents 承载，
 *     auto=false 默认下走查观测=事件计数，U6.3 前无弹窗为预期）。
 *   - Close：pathStack.pop(true) 返回主列表。
 *   - **分组呈现**：yt/video/hls/dash 四组头（内容源=GetVideoList 拼接序+dateAdded 升序的 kind
 *     分组视图；源为平铺列表——呈现层差异登记 §4-8；/sync videoList 投影零改动）。
 *   - **降级不渲染**：Topmost 复选框（HarmonyOS 应用内 NavDestination 无窗口置顶语义）、
 *     HowTo 外链（PlatformHelper.OpenBrowser 对应物未接）——§4-8。
 *   - 状态栏无新入口；唯一入口=汉堡菜单项（源 MainWindow.xaml:65 menuMediaGrabber 同位，Index.ets）。
 * HLS/DASH 捕获页显示但不解密（MIGRATION_PLAN §3 降级沿用）。
 * OPT-1 六处资源化（设计书 §1-#9）：钮面×3→control_bg、下载失败文案→text_danger、组头底→
 * group_header_bg、行底三元→row_selected_bg/surface_bg（base 值=原 hex 逐字节零回归，
 * dark 取 DarkTheme 同键/自定值——U4.3 setColorMode 链零改动自动生效）；tracker/选择/下载链
 * 逻辑零改动。
 * ArkTS 红线：无 any/解构/for...in/正则字面量；对象字面量具 interface 类型；@State 成员名不与
 *   通用属性名冲突；ForEach 嵌套 item 参数名不同（group/row）。
 */

import { CapturedVideoTracker, TrackedVideo, TrackerListener,
  VideoDownloadSnapshot } from '../core/bridge/CapturedVideoTracker';
import { BridgeVideoItem } from '../core/bridge/BridgeProtocol';

/** 分组视图条目（呈现层模型：kind 分组 + 组内 TrackedVideo 全字段）。 */
interface VideoGroup {
  kind: string;
  label: string;
  items: TrackedVideo[];
}

/** 四组固定序（GetVideoList 拼接序 yt→video→hls→dash 的 kind 投影，设计书 §3.9）。 */
const GROUP_KINDS: string[] = ['yt', 'video', 'hls', 'dash'];
const GROUP_LABELS: string[] = ['YouTube', 'Video', 'HLS', 'DASH'];

/**
 * 视频捕获页（MediaCaptureWindow 对应物，NavDestination 内容组件——标题由 Index.ets 的
 * navDestination builder 以 msg_media_capture 设置）。
 */
@Component
export struct VideoCapturePage {
  pathStack: NavPathStack = new NavPathStack();
  /** 全表快照（事件到达/清空时重取——§4-8 全表重渲染） */
  @State videos: TrackedVideo[] = [];
  /** 选中 id 序列（勾选序即 Download 下发序；数组 indexOf 量级可忽略） */
  @State selectedIds: string[] = [];
  @State submitting: boolean = false;
  @State submitFailed: boolean = false;
  private trackerListener: TrackerListener | null = null;

  aboutToAppear(): void {
    const listener: TrackerListener = {
      onMediaAdded: (item: BridgeVideoItem): void => {
        this.refresh();
      },
      onMediaUpdated: (item: BridgeVideoItem): void => {
        this.refresh();
      }
    };
    this.trackerListener = listener;
    CapturedVideoTracker.getInstance().registerTrackerListener(listener);
    this.videos = CapturedVideoTracker.getInstance().getTrackedVideos();
  }

  aboutToDisappear(): void {
    const listener: TrackerListener | null = this.trackerListener;
    if (listener !== null) {
      CapturedVideoTracker.getInstance().unregisterTrackerListener(listener);
      this.trackerListener = null;
    }
  }

  /** 重取全表 + 剔除已消失的选中项（Clear/未命中场景防悬挂 id）。 */
  private refresh(): void {
    this.videos = CapturedVideoTracker.getInstance().getTrackedVideos();
    const alive: string[] = [];
    for (let i = 0; i < this.selectedIds.length; i++) {
      const id: string = this.selectedIds[i];
      for (let j = 0; j < this.videos.length; j++) {
        if (this.videos[j].id === id) {
          alive.push(id);
          break;
        }
      }
    }
    this.selectedIds = alive;
  }

  /** 分组视图（build 表达式位调用；四组恒在含空组——走查项"分组四节可见"）。 */
  private groups(): VideoGroup[] {
    const out: VideoGroup[] = [];
    for (let g = 0; g < GROUP_KINDS.length; g++) {
      const items: TrackedVideo[] = [];
      for (let i = 0; i < this.videos.length; i++) {
        if (this.videos[i].kind === GROUP_KINDS[g]) {
          items.push(this.videos[i]);
        }
      }
      const group: VideoGroup = { kind: GROUP_KINDS[g], label: GROUP_LABELS[g], items: items };
      out.push(group);
    }
    return out;
  }

  private isSelected(id: string): boolean {
    return this.selectedIds.indexOf(id) >= 0;
  }

  /** 勾选切换（已选移除/未选追加——勾选序即 Download 下发序）。 */
  private toggleSelect(id: string): void {
    const idx: number = this.selectedIds.indexOf(id);
    if (idx >= 0) {
      this.selectedIds.splice(idx, 1);
    } else {
      this.selectedIds.push(id);
    }
  }

  private groupAllSelected(group: VideoGroup): boolean {
    if (group.items.length === 0) {
      return false;
    }
    for (let i = 0; i < group.items.length; i++) {
      if (!this.isSelected(group.items[i].id)) {
        return false;
      }
    }
    return true;
  }

  /** 组全选切换：全选态 → 全清；否则补齐未选项（追加序=表序）。 */
  private toggleGroup(group: VideoGroup): void {
    if (this.groupAllSelected(group)) {
      for (let i = 0; i < group.items.length; i++) {
        const idx: number = this.selectedIds.indexOf(group.items[i].id);
        if (idx >= 0) {
          this.selectedIds.splice(idx, 1);
        }
      }
    } else {
      for (let i = 0; i < group.items.length; i++) {
        if (!this.isSelected(group.items[i].id)) {
          this.selectedIds.push(group.items[i].id);
        }
      }
    }
  }

  /** Download（.cs :79-88 多选增强形态）：按选中序逐 id addVideoDownload——每 id 动作 1:1 源
   * （auto=false 默认 → BridgeUiEvents.onShowVideoDownloadDialog 事件承载；U6.3 接真对话框）。 */
  private async downloadSelected(): Promise<void> {
    if (this.submitting) {
      return;
    }
    this.submitting = true;
    this.submitFailed = false;
    const selected: string[] = this.selectedIds.slice();
    try {
      const tracker: CapturedVideoTracker = CapturedVideoTracker.getInstance();
      const snapshots: VideoDownloadSnapshot[] = tracker.snapshotVideoDownloads(selected);
      for (let i = 0; i < snapshots.length; i++) {
        await tracker.submitVideoDownload(snapshots[i]);
        // A partial multi-selection retry must not duplicate already accepted requests.
        this.selectedIds = this.selectedIds.filter((id: string): boolean => id !== snapshots[i].id);
      }
    } catch (e) {
      this.submitFailed = true;
    } finally {
      this.submitting = false;
    }
  }

  /** Clear（.cs :73-77）：tracker.clearVideoList() + 本地清空。 */
  private clearAll(): void {
    CapturedVideoTracker.getInstance().clearVideoList();
    this.videos = [];
    this.selectedIds = [];
  }

  build() {
    Column() {
      // 底部按钮排（源布局 Close 左 / Download+Clear 右；置于列表上方适配 NavDestination 滚动）
      Row({ space: 8 }) {
        Button($r('app.string.msg_close'))
          .fontSize(13)
          .height(32)
          .backgroundColor($r('app.color.control_bg'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => {
            this.pathStack.pop(true);
          })
        Blank()
        Button($r('app.string.msg_download'))
          .fontSize(13)
          .height(32)
          .backgroundColor($r('app.color.control_bg'))
          .fontColor($r('app.color.text_primary'))
          .enabled(this.selectedIds.length > 0 && !this.submitting)
          .onClick(() => {
            this.downloadSelected();
          })
        Button($r('app.string.msg_clear'))
          .fontSize(13)
          .height(32)
          .backgroundColor($r('app.color.control_bg'))
          .fontColor($r('app.color.text_primary'))
          .enabled(this.videos.length > 0)
          .onClick(() => {
            this.clearAll();
          })
      }
      .width('100%')
      .padding({ bottom: 8 })

      if (this.submitFailed) {
        Text($r('app.string.msg_download_save_failed'))
          .fontSize(12)
          .fontColor($r('app.color.text_danger'))
      }

      Scroll() {
        Column() {
          // 列表两列表头（xaml GridView：Name(400px)/Quality(150px)）
          Row() {
            Text($r('app.string.sort_name'))
              .fontSize(12)
              .opacity(0.6)
              .layoutWeight(1)
            Text($r('app.string.msg_quality'))
              .fontSize(12)
              .opacity(0.6)
              .width(160)
          }
          .width('100%')
          .padding({ left: 44, right: 12, top: 4, bottom: 4 })

          ForEach(this.groups(), (group: VideoGroup) => {
            Column() {
              // 组头（全选 Toggle + 组名 + 计数；hitTestBehavior None 使点击落在组头 Row）
              Row({ space: 8 }) {
                Toggle({ type: ToggleType.Checkbox, isOn: this.groupAllSelected(group) })
                  .hitTestBehavior(HitTestMode.None)
                Text(group.label)
                  .fontSize(13)
                  .fontWeight(FontWeight.Medium)
                Text(String(group.items.length))
                  .fontSize(12)
                  .opacity(0.6)
              }
              .width('100%')
              .padding({ left: 8, right: 8, top: 8, bottom: 4 })
              .backgroundColor($r('app.color.group_header_bg'))
              .borderRadius(6)
              .onClick(() => {
                this.toggleGroup(group);
              })

              ForEach(group.items, (row: TrackedVideo) => {
                Row({ space: 8 }) {
                  Toggle({ type: ToggleType.Checkbox, isOn: this.isSelected(row.id) })
                    .hitTestBehavior(HitTestMode.None)
                  Text(row.file)
                    .fontSize(13)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                  Text(row.description)
                    .fontSize(12)
                    .maxLines(1)
                    .width(160)
                }
                .width('100%')
                .padding({ left: 8, right: 12, top: 6, bottom: 6 })
                .borderRadius(6)
                .backgroundColor(this.isSelected(row.id) ? $r('app.color.row_selected_bg')
                  : $r('app.color.surface_bg'))
                .onClick(() => {
                  this.toggleSelect(row.id);
                })
              }, (row: TrackedVideo) => row.id)
            }
            .width('100%')
            .margin({ top: 6 })
          // key 含组内条目序列：仅用 kind 时组 key 恒定，ArkUI 复用旧组节点不重跑其 builder，
          // 增量到达的新行不渲染（2026-10-18 真机 P6-U2 走查⑩实证：/sync 已有、页面不出）
          }, (group: VideoGroup) => group.kind + '|' + group.items.map((v: TrackedVideo): string => v.id).join(','))
        }
        .width('100%')
      }
      .width('100%')
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Auto)
    }
    .width('100%')
    .height('100%')
    .padding(12)
  }
}
