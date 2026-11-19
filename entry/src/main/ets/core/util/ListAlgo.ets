/*
 * U4.1 列表排序纯函数层（设计书 §3.3/§5.3）。零 import（含 @kit）——Hypium 本地单测可直接加载。
 * 对照源码：XDM.Wpf.UI/MainWindow/MainWindow.xaml.cs——初始排序（:115-150 双列表
 * SortDescription("DateAdded", Descending)）、列头点击翻转（:453-477/:570-594：同列且当前升序→降序，
 * 否则升序；无 Tag 直接 return 由调用方不绑点击承载）、AddToTop=Append（:281-289，显示位次由视图
 * 排序决定）。
 * 实现层级差异 D9：WPF CollectionView 视图排序 → 数据源内排序投影（DownloadListDataSource）；
 * 本文件只承载比较器/插入位/翻转方向三个纯决策，可观测行为对齐（初始 DateAdded desc、列头首击
 * 升序同列再点降序、新项置顶）。
 * ArkTS 无结构化类型：DownloadRecord implements SortableRow（model→util 单向无环）后才能入参。
 * 字符串比较用关系运算符（TS/ArkTS 对 string 的 <、> 合法）；null 名按空串（C# string.Compare
 * null 语义同貌，设计书 §3.3）。
 */

/** 可排行的最小投影（id 供键值生成器；name 可空；dateAdded/size 数值键） */
export interface SortableRow {
  id: string;
  name: string | null;
  dateAdded: number;
  size: number;
}

/** 排序键（对照列头 GridViewColumnHeader.Tag：'Name'/'DateAdded'/'Size'；'%'/Status 列无 Tag 不可排） */
export type SortKey = 'Name' | 'DateAdded' | 'Size';

/** 单键比较（C# string.Compare/数值比较同貌）：升序为基准，desc 翻转结果符号。
 * 返回 <0 = a 在 b 前；=0 相等；>0 = a 在 b 后。 */
export function compareRows(a: SortableRow, b: SortableRow, key: SortKey, desc: boolean): number {
  let cmp: number = 0;
  if (key === 'Name') {
    const an: string = a.name ?? '';
    const bn: string = b.name ?? '';
    if (an < bn) {
      cmp = -1;
    } else if (an > bn) {
      cmp = 1;
    } else {
      cmp = 0;
    }
  } else if (key === 'DateAdded') {
    cmp = a.dateAdded - b.dateAdded;
  } else {
    cmp = a.size - b.size;
  }
  return desc ? -cmp : cmp;
}

/** 投影插入下标（前向线性扫）：rows 须已按 (key, desc) 有序；返回首个 row 排在其前的元素下标，
 * 全部不前置则返回 rows.length（尾插）。
 * 常态路径 O(1)：默认态 dateAdded desc 下新项 dateAdded=now 为最大 → 首元素即命中 index 0
 * （与源码 AddToTop+视图排序的置顶呈现等价，设计书 §3.3）。 */
export function sortedInsertIndex(rows: SortableRow[], row: SortableRow, key: SortKey, desc: boolean): number {
  for (let i = 0; i < rows.length; i++) {
    if (compareRows(row, rows[i], key, desc) < 0) {
      return i;
    }
  }
  return rows.length;
}

/** 列头点击翻转（MainWindow.xaml.cs:458-461/:585-587 同构）：同列且当前升序 → 降序(true)；
 * 否则（异列首击/同列当前降序）→ 升序(false)。首击恒升序——含从初始 DateAdded desc 点
 * DateAdded 转升序（:468-470：newDir 初值 Ascending，仅同列且 adorner 已 Ascending 才转 Descending）。 */
export function nextSortDirection(curKey: SortKey, curDesc: boolean, clickedKey: SortKey): boolean {
  return curKey === clickedKey && !curDesc;
}
