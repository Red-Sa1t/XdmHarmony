/*
 * U5.2 FolderAlgo 纯函数 Hypium 本地用例（设计书 §7 用例清单，16 条）。
 * 被测模块零 @kit import（core/util/FolderAlgo.ets），本地测试环境可直接 import。
 * 锁定目标：
 *   - updateRecentFolderList 四例（空串不变/头插/已存在不重排/空表首插——Helpers.cs:311-321）；
 *   - manualDownloadFolder 六例（Auto null/userSelected 命中/不在表回退[0]/空回退[0]/
 *     空表回退 default/边界组合——Helpers.cs:323-339）；
 *   - downloadFolderByFileName 五例（命中/大小写归一/未命中/无扩展名含 dotfile 门/空名
 *     ——FileHelper.cs:23-41）；
 *   - 常量值（Config.cs:505-508 枚举同值）。
 * 断言注记：数组期望经 JSON.stringify 比对（QueueAlgo.test.ets 同款——hypium 无数组深度相等）。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  updateRecentFolderList,
  manualDownloadFolder,
  downloadFolderByFileName,
  FOLDER_MODE_AUTO,
  FOLDER_MODE_MANUAL
} from '../main/ets/core/util/FolderAlgo';
import { CategoryDef } from '../main/ets/core/util/CategoryAlgo';

/** 测试类别表（DEFAULT_CATEGORIES[0] 语义投影：Documents 尾段；含点大写扩展名） */
function testCategories(): CategoryDef[] {
  const cats: CategoryDef[] = [];
  cats.push(new CategoryDef('CAT_DOCUMENTS', 'Document', ['.DOC', '.DOCX', '.PDF'], 'Documents', true));
  return cats;
}

export default function folderAlgoTest(): void {
  describe('FolderAlgo', () => {
    // ── 1 updateRecentFolderList 空串不变（:312-314 空 return） ──
    it('updateRecent_emptyFolder', 0, () => {
      expect(JSON.stringify(updateRecentFolderList(['a'], '')))
        .assertEqual(JSON.stringify(['a']));
    });

    // ── 2 updateRecentFolderList 头插（Insert(0) :315-317） ──
    it('updateRecent_headInsert', 0, () => {
      expect(JSON.stringify(updateRecentFolderList(['a', 'b'], 'c')))
        .assertEqual(JSON.stringify(['c', 'a', 'b']));
    });

    // ── 3 updateRecentFolderList 已存在不重排（contains 短路） ──
    it('updateRecent_noReorder', 0, () => {
      expect(JSON.stringify(updateRecentFolderList(['a', 'b'], 'a')))
        .assertEqual(JSON.stringify(['a', 'b']));
    });

    // ── 4 updateRecentFolderList 空表首插 ──
    it('updateRecent_emptyList', 0, () => {
      expect(JSON.stringify(updateRecentFolderList([], 'x')))
        .assertEqual(JSON.stringify(['x']));
    });

    // ── 5 manualDownloadFolder Auto 恒 null（:338-339） ──
    it('manualFolder_autoNull', 0, () => {
      expect(manualDownloadFolder(FOLDER_MODE_AUTO, ['a'], 'a', 'def')).assertNull();
    });

    // ── 6 manualDownloadFolder Manual+userSelected 在表（:327-329） ──
    it('manualFolder_userSelectedHit', 0, () => {
      expect(manualDownloadFolder(FOLDER_MODE_MANUAL, ['a', 'b'], 'b', 'def')).assertEqual('b');
    });

    // ── 7 manualDownloadFolder userSelected 不在表回退[0]（:330-331 条件含 Contains） ──
    it('manualFolder_userSelectedMiss', 0, () => {
      expect(manualDownloadFolder(FOLDER_MODE_MANUAL, ['a', 'b'], 'zzz', 'def')).assertEqual('a');
    });

    // ── 8 manualDownloadFolder userSelected 空回退[0]（:326 空串门） ──
    it('manualFolder_userSelectedEmpty', 0, () => {
      expect(manualDownloadFolder(FOLDER_MODE_MANUAL, ['a', 'b'], '', 'def')).assertEqual('a');
    });

    // ── 9 manualDownloadFolder 空表回退 default（:332-333） ──
    it('manualFolder_emptyListDefault', 0, () => {
      expect(manualDownloadFolder(FOLDER_MODE_MANUAL, [], '', 'def')).assertEqual('def');
    });

    // ── 10 manualDownloadFolder 边界组合（userSelected 不在空表+空表→default） ──
    it('manualFolder_boundaryCombo', 0, () => {
      expect(manualDownloadFolder(FOLDER_MODE_MANUAL, [], 'zzz', 'def')).assertEqual('def');
    });

    // ── 11 downloadFolderByFileName 命中分类（带点大写匹配 FileHelper.cs:27-33） ──
    it('downloadFolder_categoryHit', 0, () => {
      expect(downloadFolderByFileName('file.PDF', testCategories(), '/d')).assertEqual('/d/Documents');
    });

    // ── 12 downloadFolderByFileName 大小写不敏感（toUpperCase 归一） ──
    it('downloadFolder_caseInsensitive', 0, () => {
      expect(downloadFolderByFileName('file.pdf', testCategories(), '/d')).assertEqual('/d/Documents');
    });

    // ── 13 downloadFolderByFileName 未命中回退（:39 回退 DefaultDownloadFolder） ──
    it('downloadFolder_missFallback', 0, () => {
      expect(downloadFolderByFileName('file.xyz', testCategories(), '/d')).assertEqual('/d');
    });

    // ── 14 downloadFolderByFileName 无扩展名回退（dot>0 门=Path.GetExtension dotfile 同貌） ──
    it('downloadFolder_noExtension', 0, () => {
      expect(downloadFolderByFileName('file', testCategories(), '/d')).assertEqual('/d');
      expect(downloadFolderByFileName('.bashrc', testCategories(), '/d')).assertEqual('/d');
    });

    // ── 15 downloadFolderByFileName 空文件名回退 ──
    it('downloadFolder_emptyName', 0, () => {
      expect(downloadFolderByFileName('', testCategories(), '/d')).assertEqual('/d');
    });

    // ── 16 常量值（Config.cs:505-508 枚举同值） ──
    it('folderConstants_values', 0, () => {
      expect(FOLDER_MODE_AUTO).assertEqual(0);
      expect(FOLDER_MODE_MANUAL).assertEqual(1);
    });
  });
}
