/*
 * U5.2 目录解析纯函数层（设计书 §1-#2/§3.3）：零 @kit import——Hypium 本地单测可直接加载
 * （QueueAlgo/ScheduleAlgo/NotifyAlgo 先例）。FolderBrowserDialog 数学对照（本会话逐行核对）：
 *   updateRecentFolderList    ← Helpers.cs:311-321 UpdateRecentFolderList 表操作半区：
 *                               空串原表拷贝返回（:312-314 空 return）；不含→头插（:315-317
 *                               Insert(0, folder)）；含→原序拷贝不重排不去重。
 *                               Manual 置位（:318 FolderSelectionMode=Manual）与 SaveConfig（:320）
 *                               归调用方 applyPickedFolder 一处（源本就跨 Config/Helpers 两处）。
 *   manualDownloadFolder      ← Helpers.cs:323-339 GetManualDownloadFolder 逐条：mode!=Manual→null；
 *                               userSelected 非空且在表→userSelected（:327-329）；否则表[0]（:330-331）；
 *                               空表→DefaultDownloadFolder（:332-333）。
 *   downloadFolderByFileName  ← FileHelper.cs:23-41 GetDownloadFolderByFileName：扩展名=末个下标>0
 *                               的 '.' 起子串 toUpperCase 带点（Path.GetExtension 同貌：'.bashrc'
 *                               形态=无扩展名）；命中 category.FileExtensions→返回类别目录
 *                               （源 DefaultFolder=完整 OS 目录；目标侧 defaultFolderName 存尾段，
 *                               D5 尾段拼接 downloadDir+'/'+defaultFolderName=等价投影）；
 *                               未命中/空名→downloadDir（:39 回退 DefaultDownloadFolder）。
 * 常量：FOLDER_MODE_AUTO=0/FOLDER_MODE_MANUAL=1（Config.cs:505-508 FolderSelectionMode 枚举同值；
 * Config.ets DEFAULT_FOLDER_SELECTION_MODE=0 同锚）。
 * ArkTS 合规：禁解构、显式返回类型、数组拷贝用 slice()、禁正则字面量（无正则）。
 */

import { CategoryDef } from './CategoryAlgo';

/** Config.cs:505-508 FolderSelectionMode.Auto=0（勾=Auto=0，GeneralSettingsTab 同锚） */
export const FOLDER_MODE_AUTO: number = 0;
/** Config.cs:505-508 FolderSelectionMode.Manual=1 */
export const FOLDER_MODE_MANUAL: number = 1;

/** UpdateRecentFolderList 表操作半区（Helpers.cs:311-321 数学 1:1）：folder 空→原表拷贝；
 * !contains→头插（Insert(0)）；含→原序拷贝（不重排不去重）。纯函数——不改入参数组；
 * Manual 置位与持久化归调用方（applyPickedFolder）。 */
export function updateRecentFolderList(folders: string[], folder: string): string[] {
  const copy: string[] = folders.slice();
  if (folder.length === 0) {
    return copy;
  }
  if (!copy.includes(folder)) {
    copy.unshift(folder);
  }
  return copy;
}

/** GetManualDownloadFolder（Helpers.cs:323-339 逐条）：mode!=Manual→null（Auto：调用方退化
 * 类别解析）；userSelected 非空且在表→userSelected；否则表[0]；空表→defaultFolder。 */
export function manualDownloadFolder(mode: number, recentFolders: string[], userSelected: string,
  defaultFolder: string): string | null {
  if (mode !== FOLDER_MODE_MANUAL) {
    return null;
  }
  if (recentFolders.length > 0) {
    if (userSelected.length > 0 && recentFolders.includes(userSelected)) {
      return userSelected;
    }
    return recentFolders[0];
  }
  return defaultFolder;
}

/** GetDownloadFolderByFileName（FileHelper.cs:23-41）：末个下标>0 的 '.' 起取扩展名 toUpperCase
 * 带点；命中 category.fileExtensions→downloadDir+'/'+defaultFolderName（D5 尾段拼接）；
 * 未命中/空名→downloadDir（:39 回退）。try/catch 保真源形态（:41 catch 回退 DefaultDownloadFolder
 * ——纯字符串实现不抛，catch 分支语义由回退值承载）。 */
export function downloadFolderByFileName(fileName: string, categories: CategoryDef[],
  downloadDir: string): string {
  try {
    const dot: number = fileName.lastIndexOf('.');
    const ext: string = dot > 0 ? fileName.slice(dot).toUpperCase() : '';
    if (ext.length > 0) {
      for (let i = 0; i < categories.length; i++) {
        const category: CategoryDef = categories[i];
        if (category.fileExtensions.includes(ext)) {
          return downloadDir + '/' + category.defaultFolderName;
        }
      }
    }
  } catch (e) {
    // FileHelper.cs:41 catch→Log.Debug→fallthrough 同貌：任何异常回退默认目录
  }
  return downloadDir;
}
