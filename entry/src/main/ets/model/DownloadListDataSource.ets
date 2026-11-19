/*
 * U4.1 双列表数据源（设计书 §2.3/§5.6/§3.3）：WPF ObservableCollection + ListCollectionView 同构。
 *   records 全量数组 = ObservableCollection（AddToTop 仅 Append，MainWindow.xaml.cs:281-289）
 *   visible 排序过滤投影 = CollectionView（SortDescriptions + Filter 视图，D9 实现层级差异）
 * 内存结构：sortKey/sortDesc 对照初始 SortDescription("DateAdded", Descending)（:115-150）；
 * filterKeyword 对照 TxtSearch.Text（ApplyFilter 只作用于本列表）；filterCategory 对照 view.Filter
 * 的 category 闭包参（IsCategoryMatched → Helpers.IsOfCategoryOrMatchesKeyword）。
 * 通知纪律（设计书 §3.5）：高频路径增量通知——addSorted→notifyDataAdd(idx)、removeById→notifyDataDelete(idx)；
 * 过滤/排序/初始化重算投影走 notifyDataReloaded；字段级刷新零通知（@Observed+@ObjectLink 直驱，
 * notifyDataChange 禁用防双通道）。结构变更在调用栈内同步完成（store Promise 的 .then 边界内、
 * 事件回调内），LazyForEach 通知与数组状态永不撕裂。
 * 计数口径（D2 鸿蒙增强）：fullCount/countByExtensions 按 records 未过滤全长（不受 filter 影响）。
 * 纯内存视图层不落盘：DB 真值全在 DownloadStore（本单元零新 DB API）。
 * 业务文件红线：零 probe import、零 [XDM_PROBE] 输出。
 */

import { CategoryDef, fileExtensionOf, isOfCategoryOrMatchesKeyword } from '../core/util/CategoryAlgo';
import { SortKey, compareRows, nextSortDirection, sortedInsertIndex } from '../core/util/ListAlgo';
import { DownloadRecord } from './DownloadRecord';
import { BasicDataSource } from './BasicDataSource';

/** 表头箭头渲染原料（sortState 只读快照——design §5.6） */
export interface SortStateSnapshot {
  key: SortKey;
  desc: boolean;
}

export class DownloadListDataSource extends BasicDataSource<DownloadRecord> {
  /** 全量（对照 ObservableCollection；AddToTop=Append 语义由此承载） */
  private records: DownloadRecord[] = [];
  /** 投影（对照 CollectionView 排序+Filter 视图；LazyForEach 直读此数组） */
  private visible: DownloadRecord[] = [];
  private sortKey: SortKey = 'DateAdded';
  private sortDesc: boolean = true;
  private filterKeyword: string = '';
  private filterCategory: CategoryDef | null = null;

  totalCount(): number {
    return this.visible.length;
  }

  /** 边界守卫（越界 undefined）；getData 内零排序/过滤/格式化（devecocli docs 实测告诫） */
  getData(index: number): DownloadRecord | undefined {
    if (index >= 0 && index < this.visible.length) {
      return this.visible[index];
    }
    return undefined;
  }

  /** 装载（initLists 消费）：全量拷贝 + 初始排序态（DateAdded desc，xaml.cs:115-150 同构）
   * + 重算投影 + notifyDataReloaded */
  initialize(records: DownloadRecord[]): void {
    this.records = records.slice();
    this.sortKey = 'DateAdded';
    this.sortDesc = true;
    this.rebuild();
    this.notifyDataReloaded();
  }

  /** 新项入源（§3.3）：全量 Append（AddToTop :281-289 同构）→ 过过滤判定 → 投影按当前排序/过滤
   * 找位插入（sortedInsertIndex 前向线性扫；dateAdded desc 默认态新项 O(1) 命中 index 0=置顶呈现）
   * → notifyDataAdd(idx)。不过滤条件则只入全量不动投影（不整表重排，保 O(1) 常态路径）。 */
  addSorted(record: DownloadRecord): void {
    this.records.push(record);
    if (!isOfCategoryOrMatchesKeyword(record.name ?? '', this.filterKeyword, this.filterCategory)) {
      return;
    }
    const insertIndex: number = sortedInsertIndex(this.visible, record, this.sortKey, this.sortDesc);
    this.visible.splice(insertIndex, 0, record);
    this.notifyDataAdd(insertIndex);
  }

  /** 按 id 删除：全量删 + 投影删（命中才 notifyDataDelete）；未命中 false（幂等——双数据源
   * 盲删/按钮双击无害）。 */
  removeById(id: string): boolean {
    let recordIdx: number = -1;
    for (let i = 0; i < this.records.length; i++) {
      if (this.records[i].id === id) {
        recordIdx = i;
        break;
      }
    }
    if (recordIdx < 0) {
      return false;
    }
    this.records.splice(recordIdx, 1);
    for (let i = 0; i < this.visible.length; i++) {
      if (this.visible[i].id === id) {
        this.visible.splice(i, 1);
        this.notifyDataDelete(i);
        break;
      }
    }
    return true;
  }

  /** 过滤（§3.2）：重算投影 + notifyDataReloaded；keyword 调用方先 trim，category null=全部 */
  applyFilter(keyword: string, category: CategoryDef | null): void {
    this.filterKeyword = keyword;
    this.filterCategory = category;
    this.rebuild();
    this.notifyDataReloaded();
  }

  /** 清过滤（分类 index 0/1 分支，§3.1） */
  clearFilter(): void {
    this.filterKeyword = '';
    this.filterCategory = null;
    this.rebuild();
    this.notifyDataReloaded();
  }

  /** 列头点击排序（§3.3）：nextSortDirection 翻转（首击恒升序/同列再点降序）→ 重算投影 → reload */
  toggleSort(key: SortKey): void {
    this.sortDesc = nextSortDirection(this.sortKey, this.sortDesc, key);
    this.sortKey = key;
    this.rebuild();
    this.notifyDataReloaded();
  }

  /** 全量线性查（事件消费方/选中链按 id 定位 record——同一引用即 records 成员） */
  getRecordById(id: string): DownloadRecord | null {
    for (let i = 0; i < this.records.length; i++) {
      if (this.records[i].id === id) {
        return this.records[i];
      }
    }
    return null;
  }

  /** 全量 id 快照（清除全部已完成：源 ClearAllFinishedClicked 作用于未过滤全集） */
  allIds(): string[] {
    const ids: string[] = [];
    for (let i = 0; i < this.records.length; i++) {
      ids.push(this.records[i].id);
    }
    return ids;
  }

  /** 未过滤全长（D2 计数口径；空态驱动由 Index.recomputeCounts 转 @State） */
  fullCount(): number {
    return this.records.length;
  }

  /** 子分类计数（D2）：遍历全量按扩展名大写匹配计数（exts 为大写集——CategoryDef.fileExtensions） */
  countByExtensions(exts: string[]): number {
    let count: number = 0;
    for (let i = 0; i < this.records.length; i++) {
      const ext: string = fileExtensionOf(this.records[i].name ?? '').toUpperCase();
      for (let j = 0; j < exts.length; j++) {
        if (exts[j] === ext) {
          count++;
          break;
        }
      }
    }
    return count;
  }

  /** 当前排序态只读快照（表头箭头渲染原料；重渲染触发由 Index @State sortVersion 承担） */
  sortState(): SortStateSnapshot {
    const snapshot: SortStateSnapshot = { key: this.sortKey, desc: this.sortDesc };
    return snapshot;
  }

  /** 选中态清屏（Index.clearSelection 消费）：遍历全量置 uiSelected=false（@Observed 只刷新
   * 曾置 true 的行；false 幂等赋值）。UI 会话态辅助，与持久化零关联。 */
  clearUiSelection(): void {
    for (let i = 0; i < this.records.length; i++) {
      this.records[i].uiSelected = false;
    }
  }

  /** 重算投影：records 按可见性过滤 + 排序（O(n log n)）；仅 initialize/applyFilter/toggleSort
   * 触发——高频路径 addSorted/removeById 走增量通知不经此。 */
  private rebuild(): void {
    const next: DownloadRecord[] = [];
    for (let i = 0; i < this.records.length; i++) {
      const record: DownloadRecord = this.records[i];
      if (isOfCategoryOrMatchesKeyword(record.name ?? '', this.filterKeyword, this.filterCategory)) {
        next.push(record);
      }
    }
    next.sort((x: DownloadRecord, y: DownloadRecord): number => compareRows(x, y, this.sortKey, this.sortDesc));
    this.visible = next;
  }
}
