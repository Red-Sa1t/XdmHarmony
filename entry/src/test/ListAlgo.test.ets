/*
 * U4.1 ListAlgo 纯函数 Hypium 本地用例（设计书 §7-[A]-2 用例清单，8 条）。
 * 被测模块零 @kit import（ListAlgo.ets），本地测试环境可直接 import。
 * 锁定目标：
 *   - compareRows 三键升降序（Name 关系比较/null 名按空串——asc 空串最小前置、desc 尾置；
 *     DateAdded/Size 数值；desc 翻转符号）；
 *   - sortedInsertIndex：dateAdded desc 新最大→0（置顶，AddToTop 呈现等价 §3.3）、
 *     中位插入、asc 插尾；
 *   - nextSortDirection 翻转矩阵（MainWindow.xaml.cs:458-461/:585-587 同构）：同列升→降、
 *     同列降→升、异列→升（初始 DateAdded desc 态点 DateAdded 转升）。
 */

import { describe, it, expect } from '@ohos/hypium';
import { SortableRow, compareRows, nextSortDirection, sortedInsertIndex } from '../main/ets/core/util/ListAlgo';

/** 测试行构造（SortableRow 类型化字面量） */
function row(id: string, name: string | null, dateAdded: number, size: number): SortableRow {
  const r: SortableRow = { id: id, name: name, dateAdded: dateAdded, size: size };
  return r;
}

/** names 排序后投影（断言辅助） */
function namesOf(rows: SortableRow[]): string[] {
  const names: string[] = [];
  for (let i = 0; i < rows.length; i++) {
    names.push(rows[i].name ?? '');
  }
  return names;
}

export default function listAlgoTest(): void {
  describe('ListAlgo', () => {
    it('compareRows_nameAsc', 0, () => {
      expect(compareRows(row('a', 'a.zip', 1, 0), row('b', 'b.mp3', 2, 0), 'Name', false)).assertEqual(-1);
      expect(compareRows(row('b', 'b.mp3', 2, 0), row('a', 'a.zip', 1, 0), 'Name', false)).assertEqual(1);
      expect(compareRows(row('a', 'same', 1, 0), row('b', 'same', 2, 0), 'Name', false)).assertEqual(0);
    });

    it('compareRows_nameDesc', 0, () => {
      expect(compareRows(row('a', 'a.zip', 1, 0), row('b', 'b.mp3', 2, 0), 'Name', true)).assertEqual(1);
      expect(compareRows(row('b', 'b.mp3', 2, 0), row('a', 'a.zip', 1, 0), 'Name', true)).assertEqual(-1);
    });

    it('compareRows_nameNullTreatedAsEmpty', 0, () => {
      // null 名按空串：asc 最小前置；desc 尾置（设计书 §3.3，C# string.Compare 同貌）
      const named: SortableRow = row('n', 'a.zip', 1, 0);
      const unnamed: SortableRow = row('u', null, 2, 0);
      expect(compareRows(unnamed, named, 'Name', false)).assertEqual(-1);
      expect(compareRows(unnamed, named, 'Name', true)).assertEqual(1);
      expect(compareRows(unnamed, unnamed, 'Name', false)).assertEqual(0);
    });

    it('compareRows_dateAdded', 0, () => {
      expect(compareRows(row('a', null, 100, 0), row('b', null, 200, 0), 'DateAdded', false)).assertEqual(-100);
      expect(compareRows(row('a', null, 100, 0), row('b', null, 200, 0), 'DateAdded', true)).assertEqual(100);
      expect(compareRows(row('a', null, 200, 0), row('b', null, 200, 0), 'DateAdded', true)).assertEqual(0);
    });

    it('compareRows_size', 0, () => {
      expect(compareRows(row('a', null, 0, 10), row('b', null, 0, 20), 'Size', false)).assertEqual(-10);
      expect(compareRows(row('a', null, 0, 10), row('b', null, 0, 20), 'Size', true)).assertEqual(10);
    });

    it('sortedInsertIndex_descNewMax_hitsZero', 0, () => {
      // dateAdded desc 默认态：新项 dateAdded 最大 → index 0（置顶语义 §3.3，O(1) 常态路径）
      const view: SortableRow[] = [row('c', 'c.zip', 300, 0), row('b', 'b.mp3', 200, 0), row('a', 'a.pdf', 100, 0)];
      expect(sortedInsertIndex(view, row('d', 'd.bin', 400, 0), 'DateAdded', true)).assertEqual(0);
      // 更旧项尾插
      expect(sortedInsertIndex(view, row('e', 'e.iso', 50, 0), 'DateAdded', true)).assertEqual(3);
      // 中位插入
      expect(sortedInsertIndex(view, row('f', 'f.msi', 150, 0), 'DateAdded', true)).assertEqual(2);
    });

    it('sortedInsertIndex_ascTailAndSorted', 0, () => {
      // asc 下有序投影逐位插入：最小→0、最大→尾
      let view: SortableRow[] = [];
      view = [row('b', 'b.mp3', 0, 0)];
      expect(sortedInsertIndex(view, row('a', 'a.pdf', 0, 0), 'Name', false)).assertEqual(0);
      expect(sortedInsertIndex(view, row('c', 'c.zip', 0, 0), 'Name', false)).assertEqual(1);
    });

    it('nextSortDirection_matrix', 0, () => {
      // 同列且当前升序→降序；同列且当前降序→升序；异列→升序（首击恒升序）
      expect(nextSortDirection('Name', false, 'Name')).assertTrue();
      expect(nextSortDirection('Name', true, 'Name')).assertFalse();
      expect(nextSortDirection('DateAdded', true, 'Name')).assertFalse();
      // 初始 DateAdded desc 态点 DateAdded → 转升序（xaml.cs:468-470 同构）
      expect(nextSortDirection('DateAdded', true, 'DateAdded')).assertFalse();
    });
  });
}
