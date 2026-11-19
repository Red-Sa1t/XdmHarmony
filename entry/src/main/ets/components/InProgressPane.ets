/*
 * OPT-1 进行中列表组件（设计书 §1-#5）：纯搬迁自 Index.ets:1711-1756 InProgressPane @Builder
 * （零行为变更拆分，差异 #5）。空态/List+LazyForEach(inProgressDS)+行装配（showToggle=true）
 * +bindContextMenu（行右键菜单 R2-F1 手法保持）。
 * DS 传递纪律（红线）：ds 普通成员按引用传 pane——禁 @Prop/@Link 包装（装饰器拷贝/代理会破坏
 * "DS 引用不变、内部 DataChangeListener 驱动 LazyForEach"模型，§3.3）；keyGenerator 恒 record.id；
 * 行组件 @ObjectLink 只读、Index 恒 record 字段唯一写者（三行回调 onSelectRow/onToggleRowSelect/
 * onToggle 上抛 Index，闭包链多一跳、逻辑逐字节不变——DownloadListItem onSelect/onToggleSelect/
 * onToggle 同款先例）。
 * 表头/右键菜单注入：headerBuilder/rowMenuBuilder 经 @BuilderParam（`() => void` 类型——
 * hvigor 实证 CustomBuilder 联合含 void 分支调用点不可调用，见成员注）收 Index 闭包
 * （`(): void => { this.HeaderRow(true) }` 箭头捕获 Index this——"禁直接传方法引用
 * （this 丢失）"CustomBuilder 标准手法，§3.3）；@Prop sortVersion 仅作重渲染触发锚（值不消费，
 * 与 Index.sortArrow version 参数同款语义）——sortVersion++ → Index 重渲染 → @Prop 同步 →
 * 本组件重渲染 → 重调 builder 读最新 DS.sortState。onRowContextAppear 上抛 Index.
 * handleRowContextAppear（写 contextMenuRowId+selectRow，Index.ets:1417-1420 零改动）。
 * 空态文案 '暂无进行中下载' 原样搬迁（不做 i18n，纯搬迁口径）。
 * 业务文件红线：零 probe import。
 */

import { DownloadRecord } from '../model/DownloadRecord';
import { DownloadListDataSource } from '../model/DownloadListDataSource';
import { StatusLabels } from '../core/util/StatusText';
import { DownloadListItem } from './DownloadListItem';

@Component
export struct InProgressPane {
  /** 双列表数据源（按引用普通成员——禁 @Prop/@Link，红线见头注） */
  ds: DownloadListDataSource = new DownloadListDataSource();
  /** 状态列标签（Index aboutToAppear 装配终值后传入——构造期取得，与原 @Builder 内联同语义） */
  statusLabels: StatusLabels = {
    downloading: 'Downloading',
    stopped: 'Stopped',
    finished: 'Finished',
    waiting: 'Waiting'
  };
  /** 空态切换（Index.recomputeCounts 整体替换同步） */
  @Prop inProgressCount: number = 0;
  /** 表头箭头重渲染触发锚（值不消费，头注） */
  @Prop sortVersion: number = 0;
  /** 表头（Index.HeaderRow(true) 闭包注入）。类型必须 `() => void` 而非 CustomBuilder——
   * hvigor 实证：CustomBuilder=(() => any)|void 联合含 void 分支，调用点 this.headerBuilder()
   * 报 10505001 "This expression is not callable. Type 'void' has no call signatures"。 */
  @BuilderParam headerBuilder: () => void;
  /** 行右键菜单（Index.RowContextMenu 闭包注入——按 Index.contextMenuRowId 分派；同款 () => void） */
  @BuilderParam rowMenuBuilder: () => void;
  onSelectRow: (id: string) => void = (id: string): void => {
  };
  onToggleRowSelect: (id: string) => void = (id: string): void => {
  };
  onToggle: (id: string) => void = (id: string): void => {
  };
  onRowContextAppear: (id: string) => void = (id: string): void => {
  };

  build() {
    Column() {
      this.headerBuilder()
      if (this.inProgressCount === 0) {
        Text($r('app.string.empty_in_progress'))
          .fontSize(13)
          .opacity(0.5)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding(24)
      } else {
        List({ space: 2 }) {
          LazyForEach(this.ds, (record: DownloadRecord) => {
            ListItem() {
              DownloadListItem({
                record: record,
                showToggle: true,
                labels: this.statusLabels,
                onSelect: (id: string): void => {
                  this.onSelectRow(id);
                },
                onToggleSelect: (id: string): void => {
                  this.onToggleRowSelect(id);
                },
                onToggle: (id: string): void => {
                  this.onToggle(id);
                }
              })
            }
            .bindContextMenu(this.rowMenuBuilder, ResponseType.RightClick,
              {
                onAppear: (): void => {
                  this.onRowContextAppear(record.id);
                }
              })
          }, (record: DownloadRecord) => record.id)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
      }
    }
    .width('100%')
    .height('100%')
  }
}
