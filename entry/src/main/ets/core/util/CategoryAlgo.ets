/*
 * U4.1 分类纯函数层（设计书 §2.2/§5.2/§3.2）。零 import（含 @kit）——Hypium 本地单测可直接加载。
 * 对照源码（两套扩展名集合在源码本就并存，禁混用——设计书 §2.2 注）：
 *   fileExtensionOf  ← Path.GetExtension 语义：最后一个 '.' 起含点到串尾；无 '.' 返回空串
 *                      （设计书 §3.2 拍板语义；'.zip.md' → '.md' 边缘单测锁定）
 *   CategoryDef      ← Config.cs Category（Name/DisplayName/FileExtensions/DefaultFolder/IsPredefined）
 *                      + IconMap.cs:18-29；defaultFolderName 取 DefaultFolder 尾段（完整 OS 下载目录
 *                      拼接是 Phase 5/U4.3 消费）
 *   DEFAULT_CATEGORIES ← Config.cs:157-221 DefaultCategories 五项逐串（Documents 7/Music 5/Videos 13/
 *                      Compressed 7/Programs 4；注释掉的 Other 项不移植）
 *   isOfCategory / isOfCategoryOrMatchesKeyword ← Helpers.cs:193-209（AND 语义：关键词空或 contains
 *                      不区分大小写 → 扩展名 toUpperCase 后 ∈ 集合；category null 恒过）
 *   iconCategoryKeyForExtension ← IconMap.cs:9-42 imageTypes 移植（小写集合，多 .m4a/.ac3/.mka/.m4v/
 *                      .txt/.html/.bin/.appx，少 .md/.opus 等）——图标分类键专用；'.ApplicationContext.Core'
 *                      为源码原貌移植（源工程名误入扩展名集，IconMap.cs:15 逐字核实，保留保真）
 * 消费方：DownloadListDataSource（过滤）、DownloadListItem/Index（图标键）、P4-U1 探针 S1。
 * ArkTS 合规：禁正则字面量（无正则）、显式返回类型、类字段显式类型+构造器体内赋值
 * （禁 ctor 参数属性 arkts-no-ctor-prop-decls）。
 */

/** Path.GetExtension 同貌：最后一个 '.' 起含点到串尾；无 '.' → ''（'file.' → '.'） */
export function fileExtensionOf(name: string): string {
  const dot: number = name.lastIndexOf('.');
  if (dot < 0) {
    return '';
  }
  return name.slice(dot);
}

/** 对照 Config.cs Category + IconMap.cs:18-29（name 为事件面键，CategoryChanged 保留可溯） */
export class CategoryDef {
  name: string;
  displayName: string;
  /** 大写、含点（isOfCategory 内 toUpperCase 后比对） */
  fileExtensions: string[];
  /** 对照 DefaultFolder 尾段（'Documents' 等） */
  defaultFolderName: string;
  isPredefined: boolean;

  constructor(name: string, displayName: string, fileExtensions: string[],
    defaultFolderName: string, isPredefined: boolean) {
    this.name = name;
    this.displayName = displayName;
    this.fileExtensions = fileExtensions;
    this.defaultFolderName = defaultFolderName;
    this.isPredefined = isPredefined;
  }
}

/** DEFAULT_CATEGORIES 五项（Config.cs:157-221 逐串；顺序=源码声明序，分类面板 index 2..6） */
export const DEFAULT_CATEGORIES: CategoryDef[] = [
  new CategoryDef('CAT_DOCUMENTS', 'Document',
    ['.DOC', '.DOCX', '.PDF', '.MD', '.XLSX', '.XLS', '.CBZ'], 'Documents', true),
  new CategoryDef('CAT_MUSIC', 'Music',
    ['.MP3', '.AAC', '.MPA', '.WMA', '.MIDI'], 'Music', true),
  new CategoryDef('CAT_VIDEOS', 'Video',
    ['.MP4', '.WEBM', '.OGG', '.FLV', '.MKV', '.DIVX', '.MOV', '.MPG', '.MPEG', '.OPUS', '.AVI', '.WMV', '.TS'],
    'Video', true),
  new CategoryDef('CAT_COMPRESSED', 'Compressed',
    ['.7Z', '.ZIP', '.RAR', '.BZ2', '.GZ', '.XZ', '.TAR'], 'Compressed', true),
  new CategoryDef('CAT_PROGRAMS', 'Application',
    ['.EXE', '.DEB', '.RPM', '.MSI'], 'Programs', true)
];

/** IsOfCategory 同貌（Helpers.cs:204-209）：category null → true；扩展名 toUpperCase 后线性查集合（n≤13） */
export function isOfCategory(name: string, category: CategoryDef | null): boolean {
  if (category === null) {
    return true;
  }
  const ext: string = fileExtensionOf(name).toUpperCase();
  for (let i = 0; i < category.fileExtensions.length; i++) {
    if (category.fileExtensions[i] === ext) {
      return true;
    }
  }
  return false;
}

/** IsOfCategoryOrMatchesKeyword 同貌（Helpers.cs:193-202）：搜索 AND 语义（关键词空或 contains
 * 不区分大小写）→ isOfCategory。过滤可见性判定唯一入口（DS.rebuild/addSorted 共用）。 */
export function isOfCategoryOrMatchesKeyword(name: string, keyword: string, category: CategoryDef | null): boolean {
  const searchMatched: boolean = keyword === '' || name.toLowerCase().includes(keyword.toLowerCase());
  if (!searchMatched) {
    return false;
  }
  return isOfCategory(name, category);
}

/** imageTypes 五键分类键（IconMap.cs:9-16 集合逐串；小写入参——调用方先 toLowerCase）。
 * 返回 'CAT_COMPRESSED'|'CAT_MUSIC'|'CAT_VIDEOS'|'CAT_DOCUMENTS'|'CAT_PROGRAMS'|'Other'；
 * 命中序=源码 Dictionary 声明序（GetFileType foreach Keys）。 */
export function iconCategoryKeyForExtension(extLower: string): string {
  if (extLower === '.zip' || extLower === '.gz' || extLower === '.tar' || extLower === '.xz' ||
    extLower === '.7z' || extLower === '.rar' || extLower === '.bz2') {
    return 'CAT_COMPRESSED';
  }
  if (extLower === '.mp3' || extLower === '.aac' || extLower === '.ac3' || extLower === '.wma' ||
    extLower === '.m4a' || extLower === '.ogg' || extLower === '.mka') {
    return 'CAT_MUSIC';
  }
  if (extLower === '.mp4' || extLower === '.mkv' || extLower === '.ts' || extLower === '.webm' ||
    extLower === '.avi' || extLower === '.divx' || extLower === '.mov' || extLower === '.m4v') {
    return 'CAT_VIDEOS';
  }
  if (extLower === '.docx' || extLower === '.doc' || extLower === '.pdf' || extLower === '.txt' ||
    extLower === '.xlsx' || extLower === '.xls' || extLower === '.html') {
    return 'CAT_DOCUMENTS';
  }
  if (extLower === '.exe' || extLower === '.bin' || extLower === '.appx' ||
    extLower === '.applicationcontext.core' || extLower === '.msi' || extLower === '.rpm' ||
    extLower === '.deb') {
    return 'CAT_PROGRAMS';
  }
  return 'Other';
}
