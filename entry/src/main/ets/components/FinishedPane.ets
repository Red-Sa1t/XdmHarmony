/*
 * OPT-1 完成列表组件（设计书 §1-#6）：纯搬迁自 Index.ets:1759-1798 FinishedPane @Builder
 * （零行为变更拆分，差异 #5）。与 InProgressPane 同构但 showToggle=false（完成行无 %/状态/
 * 按钮——Tab 语义保留）且**无 bindContextMenu**（现状完成列表无右键菜单，Index.ets:1771-1790
 * 核实，§1-#6 拍板保持）。DS 传递纪律/表头注入/三行回调上抛与 InProgressPane 同款（头注详见
 * InProgressPane.ets——ds 普通成员按引用、@BuilderParam 闭包注入、keyGenerator 恒 record.id）。
 * 空态判 finishedCount（Index.recomputeCounts 同步）；文案 '暂无已完成下载' 原样搬迁（不做
 * i18n，纯搬迁口径）。
 * 业务文件红线：零 probe import。
 */

import { DownloadRecord } from '../model/DownloadRecord';
import { DownloadListDataSource } from '../model/DownloadListDataSource';
import { StatusLabels } from '../core/util/StatusText';
import { DownloadListItem } from './DownloadListItem';

@Component
export struct FinishedPane {
  /** 双列表数据源（按引用普通成员——禁 @Prop/@Link，红线见 InProgressPane 头注） */
  ds: DownloadListDataSource = new DownloadListDataSource();
  /** 状态列标签（Index aboutToAppear 装配终值后传入） */
  statusLabels: StatusLabels = {
    downloading: 'Downloading',
    stopped: 'Stopped',
    finished: 'Finished',
    waiting: 'Waiting'
  };
  /** 空态切换（Index.recomputeCounts 整体替换同步） */
  @Prop finishedCount: number = 0;
  /** 表头箭头重渲染触发锚（值不消费） */
  @Prop sortVersion: number = 0;
  /** 表头（Index.HeaderRow(false) 闭包注入）。类型必须 `() => void` 而非 CustomBuilder——
   * hvigor 实证：CustomBuilder=(() => any)|void 联合含 void 分支，调用点 this.headerBuilder()
   * 报 10505001 "This expression is not callable. Type 'void' has no call signatures"。 */
  @BuilderParam headerBuilder: () => void;
  onSelectRow: (id: string) => void = (id: string): void => {
  };
  onToggleRowSelect: (id: string) => void = (id: string): void => {
  };
  onToggle: (id: string) => void = (id: string): void => {
  };

  build() {
    Column() {
      this.headerBuilder()
      if (this.finishedCount === 0) {
        Text($r('app.string.empty_finished'))
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
                showToggle: false,
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
