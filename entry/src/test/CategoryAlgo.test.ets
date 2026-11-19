/*
 * U4.1 CategoryAlgo 纯函数 Hypium 本地用例（设计书 §7-[A]-2 用例清单，12 条）。
 * 被测模块零 @kit import（CategoryAlgo.ets），本地测试环境可直接 import。
 * 锁定目标：
 *   - DEFAULT_CATEGORIES 五项逐串（Config.cs:157-221 本会话 sed 核实）：集合长度 7/5/13/7/4
 *     + 抽查 .CBZ/.MIDI/.TS/.XZ/.MSI；
 *   - isOfCategory/IsOfCategoryOrMatchesKeyword（Helpers.cs:190-209）：null 恒过、'.doc' 命中
 *     .DOC 大写集（GetExtension toUpperCase 后比对）、无扩展名不命中、'.zip.md'→'.md' 边缘、
 *     关键词+分类 AND 双拒/双过；
 *   - iconCategoryKeyForExtension（IconMap.cs:9-42 imageTypes 移植——与 DEFAULT_CATEGORIES 本就
 *     两套）：.zip→CAT_COMPRESSED、.m4a→CAT_MUSIC（imageTypes 特有，Music 默认分类无 .M4A）、
 *     .txt→CAT_DOCUMENTS、.bin→CAT_PROGRAMS、.xyz→Other。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  CategoryDef,
  DEFAULT_CATEGORIES,
  fileExtensionOf,
  iconCategoryKeyForExtension,
  isOfCategory,
  isOfCategoryOrMatchesKeyword
} from '../main/ets/core/util/CategoryAlgo';

/** 按扩展名（大写含点）查分类（测试辅助） */
function categoryWithExt(extUpper: string): CategoryDef | null {
  for (let i = 0; i < DEFAULT_CATEGORIES.length; i++) {
    const exts: string[] = DEFAULT_CATEGORIES[i].fileExtensions;
    for (let j = 0; j < exts.length; j++) {
      if (exts[j] === extUpper) {
        return DEFAULT_CATEGORIES[i];
      }
    }
  }
  return null;
}

export default function categoryAlgoTest(): void {
  describe('CategoryAlgo', () => {
    it('defaultCategories_fiveItems', 0, () => {
      expect(DEFAULT_CATEGORIES.length).assertEqual(5);
      expect(DEFAULT_CATEGORIES[0].name).assertEqual('CAT_DOCUMENTS');
      expect(DEFAULT_CATEGORIES[4].name).assertEqual('CAT_PROGRAMS');
      expect(DEFAULT_CATEGORIES[2].isPredefined).assertTrue();
    });

    it('defaultCategories_setLengths', 0, () => {
      // Documents 7 / Music 5 / Videos 13 / Compressed 7 / Programs 4（Config.cs:157-221）
      expect(DEFAULT_CATEGORIES[0].fileExtensions.length).assertEqual(7);
      expect(DEFAULT_CATEGORIES[1].fileExtensions.length).assertEqual(5);
      expect(DEFAULT_CATEGORIES[2].fileExtensions.length).assertEqual(13);
      expect(DEFAULT_CATEGORIES[3].fileExtensions.length).assertEqual(7);
      expect(DEFAULT_CATEGORIES[4].fileExtensions.length).assertEqual(4);
    });

    it('defaultCategories_sampleExtensions', 0, () => {
      // 逐串抽查（各集合中源码位置首尾向各取一枚）
      expect(DEFAULT_CATEGORIES[0].fileExtensions[6]).assertEqual('.CBZ');
      expect(DEFAULT_CATEGORIES[1].fileExtensions[4]).assertEqual('.MIDI');
      expect(DEFAULT_CATEGORIES[2].fileExtensions[12]).assertEqual('.TS');
      expect(DEFAULT_CATEGORIES[3].fileExtensions[5]).assertEqual('.XZ');
      expect(DEFAULT_CATEGORIES[4].fileExtensions[3]).assertEqual('.MSI');
      expect(categoryWithExt('.CBZ') !== null).assertTrue();
      expect(categoryWithExt('.MIDI') !== null).assertTrue();
    });

    it('isOfCategory_nullAlwaysTrue', 0, () => {
      // Helpers.cs:206 category==null → true
      expect(isOfCategory('movie.mp4', null)).assertTrue();
      expect(isOfCategory('noext', null)).assertTrue();
    });

    it('isOfCategory_lowerCaseMatchesUppercaseSet', 0, () => {
      // :207-208 GetExtension→ToUpperInvariant→Contains：'.doc' 命中 '.DOC'
      const documents: CategoryDef = DEFAULT_CATEGORIES[0];
      expect(isOfCategory('report.doc', documents)).assertTrue();
      expect(isOfCategory('REPORT.DOC', documents)).assertTrue();
      expect(isOfCategory('report.docx', documents)).assertTrue();
      expect(isOfCategory('report.txt', documents)).assertFalse();
    });

    it('isOfCategory_noExtension_matchesNothing', 0, () => {
      // 无扩展名 → ext='' 不属于任何集合
      expect(isOfCategory('README', DEFAULT_CATEGORIES[0])).assertFalse();
      expect(isOfCategory('README', DEFAULT_CATEGORIES[2])).assertFalse();
    });

    it('fileExtensionOf_lastDotEdge', 0, () => {
      // Path.GetExtension 语义：最后一个 '.' 起含点到串尾；无 '.' 空串
      expect(fileExtensionOf('a.zip.md')).assertEqual('.md');
      expect(fileExtensionOf('archive.tar.gz')).assertEqual('.gz');
      expect(fileExtensionOf('plainname')).assertEqual('');
      expect(fileExtensionOf('name.dot.')).assertEqual('.');
    });

    it('keywordAndCategory_andSemantics_bothReject', 0, () => {
      // :195-201 AND 语义：关键词不中→false（即使分类命中）；分类不中→false（即使关键词命中）
      const videos: CategoryDef = DEFAULT_CATEGORIES[2];
      expect(isOfCategoryOrMatchesKeyword('movie.mp4', 'nomatch', videos)).assertFalse();
      expect(isOfCategoryOrMatchesKeyword('song.mp3', 'song', videos)).assertFalse();
    });

    it('keywordAndCategory_andSemantics_bothPass', 0, () => {
      // 关键词空=恒过搜索半区；双过
      const videos: CategoryDef = DEFAULT_CATEGORIES[2];
      expect(isOfCategoryOrMatchesKeyword('movie.mp4', '', videos)).assertTrue();
      expect(isOfCategoryOrMatchesKeyword('my.movie.MP4', 'movie', videos)).assertTrue();
      expect(isOfCategoryOrMatchesKeyword('movie.mp4', 'MOVIE', null)).assertTrue();
    });

    it('iconKey_zip_compressed', 0, () => {
      expect(iconCategoryKeyForExtension('.zip')).assertEqual('CAT_COMPRESSED');
      expect(iconCategoryKeyForExtension('.7z')).assertEqual('CAT_COMPRESSED');
    });

    it('iconKey_m4a_music_imageTypesOnly', 0, () => {
      // imageTypes 特有项：.m4a 在 IconMap（IconMap.cs:12）而 DEFAULT_CATEGORIES Music 无 .M4A
      expect(iconCategoryKeyForExtension('.m4a')).assertEqual('CAT_MUSIC');
      expect(isOfCategory('song.m4a', DEFAULT_CATEGORIES[1])).assertFalse();
      expect(iconCategoryKeyForExtension('.ac3')).assertEqual('CAT_MUSIC');
    });

    it('iconKey_txtBinOther', 0, () => {
      // .txt→CAT_DOCUMENTS（imageTypes 特有）、.bin→CAT_PROGRAMS（imageTypes 特有）、未收录→Other
      expect(iconCategoryKeyForExtension('.txt')).assertEqual('CAT_DOCUMENTS');
      expect(iconCategoryKeyForExtension('.bin')).assertEqual('CAT_PROGRAMS');
      expect(iconCategoryKeyForExtension('.xyz')).assertEqual('Other');
      expect(iconCategoryKeyForExtension('')).assertEqual('Other');
    });
  });
}
