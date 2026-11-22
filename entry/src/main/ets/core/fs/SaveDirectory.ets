/*
 * U5.2 保存目录能力面（设计书 §1-#8/§3.4）：@kit 编排、无状态静态类。
 * 有意差异（拍板①/D1/D2）：引擎落盘恒沙箱 downloadDir（record.targetDir 不变、引擎零接触）；
 * DocumentViewPicker 选中目录 URI 为【临时授权】（应用退出/重启即失效，不做
 * persistPermission/FILE_ACCESS_PERSIST——受限开放权限课程工程不可申请），仅作完成后
 * fileIo.copy 目标；拷贝失败文件留沙箱+hilog+false（调用方 toast 提示重选），绝不先删成品再拷贝。
 * 能力面：
 *   pickSaveFolder      ← FolderBrowserDialog.ShowDialog() 的 DocumentViewPicker 投影
 *                          （selectMode=FOLDER+maxSelectNumber=1；空数组/取消→null）。
 *   applyPickedFolder   ← Helpers.cs:311-321 UpdateRecentFolderList 三动作归并（源
 *                          RecentFolders 数学+FolderSelectionMode=Manual+SaveConfig :318-320
 *                          跨 Config/Helpers 两处，目标侧归并一处）：updateRecentFolderList 数学
 *                          +setRecentFolders+setFolderSelectionMode(MANUAL)+
 *                          setUserSelectedDownloadFolder 三键持久化。
 *   copyTargetFolder    ← GetManualDownloadFolder（Helpers.cs:323-339）投影：仅 Manual 且结果
 *                          带 file:// 前缀才返回（沙箱路径/空串→''——Auto/未选目录不拷贝）。
 *   syncFinishedFile    ← 完成后拷贝（源=直接下载进所选目录的 D1 双轨投影）：copyTargetFolder
 *                          ''→true 无事；fileIo.copy(fileUri.getUriFromPath(沙箱成品), 目录URI)
 *                          （COLD-F2：dest=目录 URI 由平台落名+编码）成功 true/失败 catch→hilog+false。
 *   openFile            ← PlatformHelper.OpenFile/OpenFolder（UIActions :76-120 消费面）投影：
 *                          accessSync 预检（File.Exists :104/:92 同位）失败→false（调用方弹
 *                          msg_file_not_found）；filePreview.openPreview 单文件变体
 *                          （多文件变体 2in1 返回 801 禁用，拍板②）；openFolder 同路（D3 降级，
 *                          action 参数由调用方传 'openFolder' 供 hilog 差异登记）。
 * import 面固定：picker/fileIo/fileUri=@kit.CoreFileKit；filePreview=@kit.PreviewKit
 * （@kit.PreviewKit.d.ts:9-11 本会话核实，非 CoreFileKit）。
 * 红线：本文件 import 图禁 probe/**；业务日志 hilog domain 0x0000 tag 'SaveDirectory'，
 * 绝不输出 [XDM_PROBE]。
 */

import { picker, fileIo, fileUri } from '@kit.CoreFileKit';
import { filePreview } from '@kit.PreviewKit';
import { common, Want, wantConstant } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { updateRecentFolderList, manualDownloadFolder, categoryFolderFor, FOLDER_MODE_MANUAL } from '../util/FolderAlgo';
import { getUniqueFileName } from '../util/FileNames';
import { Config } from '../Config';

/** 业务日志面（domain 0x0000 / tag 'SaveDirectory'） */
const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'SaveDirectory';

/** file:// scheme 前缀（fileUri.getUriFromPath 产出形态；仅此前缀 URI 可作拷贝目标） */
const FILE_URI_PREFIX: string = 'file://';

/** 常见扩展名→MIME 映射（PreviewInfo.mimeType 必填——@hms.filemanagement.filepreview.d.ts
 * PreviewInfo{uri: string; mimeType: string}，hvigor 编译期强制；未命中回退 octet-stream，
 * 预览不支持类型走 openPreview 既有 13900042 catch→false 链）。键全小写含点。 */
const MIME_BY_EXT: Record<string, string> = {
  '.pdf': 'application/pdf',
  '.txt': 'text/plain',
  '.html': 'text/html',
  '.htm': 'text/html',
  '.xml': 'application/xml',
  '.json': 'application/json',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.png': 'image/png',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.bmp': 'image/bmp',
  '.mp4': 'video/mp4',
  '.mov': 'video/quicktime',
  '.avi': 'video/x-msvideo',
  '.mkv': 'video/x-matroska',
  '.webm': 'video/webm',
  '.mp3': 'audio/mpeg',
  '.flac': 'audio/flac',
  '.wav': 'audio/x-wav',
  '.m4a': 'audio/mp4',
  '.aac': 'audio/aac',
  '.ogg': 'audio/ogg',
  '.zip': 'application/zip',
  '.7z': 'application/x-7z-compressed',
  '.rar': 'application/vnd.rar',
  '.doc': 'application/msword',
  '.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '.xls': 'application/vnd.ms-excel',
  '.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  '.ppt': 'application/vnd.ms-powerpoint',
  '.pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation'
};

/** 由路径扩展名推导 MIME（小写带点；无扩展名/未命中→application/octet-stream） */
function mimeForPath(path: string): string {
  const dot: number = path.lastIndexOf('.');
  if (dot <= 0 || dot === path.length - 1) {
    return 'application/octet-stream';
  }
  const ext: string = path.slice(dot).toLowerCase();
  const mime: string | undefined = MIME_BY_EXT[ext];
  return mime !== undefined ? mime : 'application/octet-stream';
}

/** 保存目录能力面（无状态静态类：FolderAlgo 纯函数 + Config 键 + @kit IO 编排） */
export class SaveDirectory {
  /** 目录选择（FolderBrowserDialog.ShowDialog 投影；Promise 非阻塞）：FOLDER 模式单选；
   * 取消/空结果→null。ctx 由调用方窄化传入（UIAbilityContext）。 */
  static pickSaveFolder(ctx: common.UIAbilityContext): Promise<string | null> {
    const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
    const opts: picker.DocumentSelectOptions = {
      maxSelectNumber: 1,
      selectMode: picker.DocumentSelectMode.FOLDER
    };
    return documentPicker.select(opts).then((uris: Array<string>): string | null => {
      if (uris.length === 0) {
        return null;
      }
      return uris[0];
    }).catch((err: BusinessError): string | null => {
      hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s',
        'pickSaveFolder failed errCode=' + String(err.code) + ' errMessage=' + (err.message ?? ''));
      return null;
    });
  }

  /** 选中目录登记（Helpers.cs:318-320 三动作归并）：updateRecentFolderList 数学（头插/去重）
   * →setRecentFolders + setFolderSelectionMode(MANUAL) + setUserSelectedDownloadFolder。
   * 只写拷贝目标三键——绝不回填 downloadDir、绝不调 setDownloadDir（D4：防 URI 写入引擎目标键）。 */
  static applyPickedFolder(uri: string, keepMode: boolean = false): void {
    if (uri.length === 0) {
      return;
    }
    const config: Config = Config.getInstance();
    config.setRecentFolders(updateRecentFolderList(config.getRecentFolders(), uri));
    // 2026-11-22：设置页选目录只换目录、不改「根据文件类型自动选择保存位置」（keepMode）
    if (!keepMode) {
      config.setFolderSelectionMode(FOLDER_MODE_MANUAL);
    }
    config.setUserSelectedDownloadFolder(uri);
  }

  /** 用户选择的保存目录 URI（不看模式：userSelected 在 recentFolders 中优先，否则 recentFolders[0]）；未选→'' */
  static userFolder(): string {
    const config: Config = Config.getInstance();
    const folder: string | null = manualDownloadFolder(FOLDER_MODE_MANUAL, config.getRecentFolders(),
      config.getUserSelectedDownloadFolder(), '');
    if (folder === null || !folder.startsWith(FILE_URI_PREFIX)) {
      return '';
    }
    return folder;
  }

  /** 成品拷贝目标目录 URI。2026-11-22 设置可用性修复：
   *  - 手动（选过目录）：拷到所选目录；
   *  - 「根据文件类型自动选择保存位置」勾选：拷到所选目录下对应分类子文件夹（分类取设置页
   *    「下载类别」，按扩展名匹配，无匹配则所选目录本身）；未选过目录时成品留在应用内。 */
  static copyTargetFolder(fileName: string = ''): string {
    const base: string = SaveDirectory.userFolder();
    if (base.length === 0) {
      return '';
    }
    const config: Config = Config.getInstance();
    if (config.getFolderSelectionMode() === FOLDER_MODE_MANUAL || fileName.length === 0) {
      return base;
    }
    const sub: string = categoryFolderFor(fileName, config.getCategories());
    if (sub.length === 0) {
      return base;
    }
    return (base.endsWith('/') ? base : base + '/') + encodeURIComponent(sub);
  }

  /** URI → 本地路径（docs URI 的 path 段）；解析失败返回 '' */
  static pathOfUri(uri: string): string {
    try {
      return new fileUri.FileUri(uri).path;
    } catch (e) {
      return '';
    }
  }

  /** 完成成品拷贝（D1 双轨用户目录半区）：copyTargetFolder ''→resolve(true) 无事；
   * fileIo.copy 沙箱成品→用户目录；失败 catch→hilog+false——文件留沙箱不删
   * （授权失效/重启后回退，调用方 toast msg_copy_failed 提示重选，D2）。fire-and-forget：
   * 拷贝期间列表/后续下载不受阻（设计书 §3.6）。
   * 2026-11-22：分类子文件夹按需创建；「覆盖已有文件」未勾选时目标重名自动改名 name(1).ext；
   * 「从服务器获取时间戳」开启时把成品 mtime 带到拷贝件。 */
  static async syncFinishedFile(filePath: string): Promise<boolean> {
    if (filePath.length === 0) {
      return true;
    }
    const slash: number = filePath.lastIndexOf('/');
    const baseName: string = slash >= 0 ? filePath.substring(slash + 1) : filePath;
    let target: string = SaveDirectory.copyTargetFolder(baseName);
    if (target.length === 0) {
      return true;
    }
    const base: string = SaveDirectory.userFolder();
    if (target !== base) {
      const dir: string = SaveDirectory.pathOfUri(target);
      try {
        if (dir.length === 0) {
          throw new Error('bad uri');
        }
        if (!fileIo.accessSync(dir)) {
          fileIo.mkdirSync(dir);
        }
      } catch (e) {
        hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s', 'category folder unavailable, using base folder');
        target = base;
      }
    }
    const config: Config = Config.getInstance();
    const folderPath: string = SaveDirectory.pathOfUri(target);
    let destName: string = baseName;
    if (config.getFileConflictResolution() !== 1 && folderPath.length > 0) {
      destName = getUniqueFileName(baseName, folderPath, (p: string): boolean => {
        try {
          return fileIo.accessSync(p);
        } catch (e) {
          return false;
        }
      });
    }
    const srcUri: string = fileUri.getUriFromPath(filePath);
    // dest 必须是文件 URI：传目录 URI 真机拒收 13900020 Invalid argument（2026-10-18 P5-U2 走查⑤
    // 实证，文档"file or directory"措辞不成立）。basename 经 encodeURIComponent 后拼到已编码的
    // folder URI 上——文件名含空格/#/?/% 时仍是合法 URI（COLD-F2 原顾虑由编码承担）。
    const dest: string = (target.endsWith('/') ? target : target + '/') + encodeURIComponent(destName);
    try {
      await fileIo.copy(srcUri, dest);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s',
        'copy to user folder failed (file kept in sandbox) errCode=' + String(err.code) +
        ' errMessage=' + (err.message ?? ''));
      return false;
    }
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'finished file copied dest=' + dest);
    if (config.getFetchServerTimeStamp() && folderPath.length > 0) {
      try {
        const mtimeMs: number = fileIo.statSync(filePath).mtime * 1000;
        fileIo.utimes(folderPath + '/' + destName, mtimeMs);
      } catch (e) {
        // 吞：时间戳是附加信息
      }
    }
    return true;
  }

  /** 成品在用户目录中的拷贝所在文件夹 URI（按当前设置推算且文件确实存在）；没有则 '' */
  static copiedFolderOf(fileName: string): string {
    const candidates: string[] = [SaveDirectory.copyTargetFolder(fileName), SaveDirectory.userFolder()];
    for (let i = 0; i < candidates.length; i++) {
      const folder: string = candidates[i];
      if (folder.length === 0) {
        continue;
      }
      const dir: string = SaveDirectory.pathOfUri(folder);
      try {
        if (dir.length > 0 && fileIo.accessSync(dir + '/' + fileName)) {
          return folder;
        }
      } catch (e) {
        // 无权限/不存在
      }
    }
    return '';
  }

  /** 打开目录：成品已拷到用户目录时，用系统文件选择器定位到该文件夹（鸿蒙无"在文件管理器中显示"
   * 公开接口，选择器可浏览/打开该目录内文件）；否则回退为打开文件本身（D3 降级）。 */
  static async openFolder(ctx: common.UIAbilityContext, path: string): Promise<boolean> {
    const slash: number = path.lastIndexOf('/');
    const name: string = slash >= 0 ? path.substring(slash + 1) : path;
    const folder: string = SaveDirectory.copiedFolderOf(name);
    if (folder.length === 0) {
      return SaveDirectory.openFile(ctx, path, 'openFolder');
    }
    let uris: Array<string> = [];
    try {
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
      const opts: picker.DocumentSelectOptions = { maxSelectNumber: 1, defaultFilePathUri: folder };
      uris = await documentPicker.select(opts);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s', 'openFolder picker failed errCode=' + String(err.code));
      return SaveDirectory.openFile(ctx, path, 'openFolder');
    }
    if (uris.length === 0) {
      return true;
    }
    return SaveDirectory.openWithDefaultApp(ctx, uris[0], mimeForPath(uris[0]), 'openFolderPick');
  }

  /** 打开成品（Open/OpenFolder 共路）：accessSync 预检（File.Exists 同位）失败/异常→false
   * （工具栏路径弹 msg_file_not_found，完成窗路径仅 hilog D11）；openPreview 单文件变体
   * Promise fire-and-forget，失败 catch→false（13900042 不支持类型同路）。
   * PreviewInfo.mimeType 必填（hvigor 编译期强制），经 mimeForPath 由扩展名推导。
   * action 仅作 hilog 观测值（'openFile'|'openFolder'——openFolder 降级差异登记锚，D3）。 */
  static openFile(ctx: common.UIAbilityContext, path: string, action: string): Promise<boolean> {
    if (path.length === 0) {
      return Promise.resolve(false);
    }
    try {
      if (!fileIo.accessSync(path)) {
        hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s',
          'accessSync false action=' + action + ' path=' + path);
        return Promise.resolve(false);
      }
    } catch (e) {
      const err = e as BusinessError;
      hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s',
        'accessSync threw action=' + action + ' errCode=' + String(err.code) +
        ' errMessage=' + (err.message ?? ''));
      return Promise.resolve(false);
    }
    const uri: string = fileUri.getUriFromPath(path);
    const mimeType: string = mimeForPath(path);
    if (action === 'openFolder') {
      // D3 降级登记：鸿蒙无"文件管理器定位目录"公开 API，openFolder 与 openFile 同路
      hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'action=openFolder downgraded to openPreview');
    }
    // PreviewKit is optional per device: the 2in1 system image (2026-11-19 emulator) has no
    // filePreview module and dereferencing it crashed the app (JS TypeError). Without it, or when
    // preview fails, hand the file to the system default app for its type.
    if (!SaveDirectory.previewAvailable()) {
      return SaveDirectory.openWithDefaultApp(ctx, uri, mimeType, action);
    }
    const previewInfo: filePreview.PreviewInfo = { uri: uri, mimeType: mimeType };
    let pending: Promise<void>;
    try {
      // Synchronous TypeError here means the module is absent on this device.
      pending = filePreview.openPreview(ctx, previewInfo);
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s', 'openPreview unavailable action=' + action);
      return SaveDirectory.openWithDefaultApp(ctx, uri, mimeType, action);
    }
    return pending.then((): boolean => {
      return true;
    }).catch((err: BusinessError): Promise<boolean> => {
      hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s',
        'openPreview failed action=' + action + ' errCode=' + String(err.code) +
        ' errMessage=' + (err.message ?? ''));
      return SaveDirectory.openWithDefaultApp(ctx, uri, mimeType, action);
    });
  }

  private static previewAvailable(): boolean {
    try {
      return canIUse('SystemCapability.Filemanagement.FilePreview.Core');
    } catch (e) {
      return false;
    }
  }

  /** ohos.want.action.viewData with a temporary read grant: the system picks the default app. */
  private static openWithDefaultApp(ctx: common.UIAbilityContext, uri: string, mimeType: string,
    action: string): Promise<boolean> {
    const want: Want = {
      action: 'ohos.want.action.viewData',
      uri: uri,
      type: mimeType.length > 0 ? mimeType : ANY_MIME,
      flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION
    };
    try {
      return ctx.startAbility(want).then((): boolean => true).catch((err: BusinessError): boolean => {
        hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s', 'viewData failed action=' + action +
          ' errCode=' + String(err.code));
        return false;
      });
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s', 'viewData threw action=' + action +
        ' errCode=' + String(err.code));
      return Promise.resolve(false);
    }
  }
}

const ANY_MIME: string = '*' + '/' + '*';

/** 2026-11-22：用户目录 URI 的可读显示（docs URI 取 path 段并解码）；未选 → '' */
export function displayFolder(uri: string): string {
  if (uri.length === 0) {
    return '';
  }
  const path: string = SaveDirectory.pathOfUri(uri);
  try {
    return decodeURIComponent(path.length > 0 ? path : uri);
  } catch (e) {
    return path.length > 0 ? path : uri;
  }
}
