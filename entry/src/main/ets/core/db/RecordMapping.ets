/*
 * U1.1 数据层：表结构映射纯函数模块（设计书 §2.3/§3.1）。
 * 约束：零 @kit import、不 import @Observed 的 DownloadRecord（保证 entry/src/test 的 Hypium
 * 用例可直接加载本模块——U0.2 已验证该模式）；只用 DownloadTypes 的纯类型。
 * 列名/列序根基：SchemaInitializer.cs:13-36 的 22 列 DDL（含 WITHOUT ROWID 尾缀），SELECT * 按序
 * 读与探针 S1 观测全以此为锚（有意的列序变更必须改 DDL 并在单元报告注明，禁静默重排）。
 *
 * 保真强制规则（复刻非差异，全部来自 DownloadList.cs 读回路径 :55-103——"不许顺手修复"）：
 *   R1 kind 分型：completed==0 → InProgress(0)，否则 Finished(1)（:59-60）
 *   R2 status 读回强制：completed=0 行无条件 Stopped(1)，raw status 丢弃（:95/:165）；completed=1 行
 *      保留 raw 值（C# 对完成行不读 status，此处读取仅为单模型字段完整性）
 *   R3 progress 仅 completed=0 行读入，完成行置 0（:96）
 *   R4 proxy 无条件构造（:84-90，缺省 System(0)/port 0/其余 null）
 *   R5 auth==1 且 user!=null 才构造 AuthenticationInfo（:71-83，pass 可 null——D14）
 *   R6 proxy_type 列恒写 1 不读（:219/:259 add/update 恒硬编码；status 列同样只写不读的 R2 已覆盖）
 *   R7 C# NULL 整数列读取是异常路径（GetInt32 on DBNull 抛→整表加载失败）；ArkTS readRow（store 侧）
 *      按 isColumnNull→0/null 单行归一（防御性 hardening D11/D12）——本模块入参 DownloadRow 已完成归一，
 *      int 列不携带 null。
 */

import { AuthenticationInfo, DownloadKind, DownloadStatus, ProxyInfo, RecordData } from '../../model/DownloadTypes';

/** downloads 表 22 列定序投影（字段名 = 列名驼峰化，序 = DDL 列序 = INSERT 参数序） */
export interface DownloadRow {
  id: string;
  completed: number;
  name: string | null;
  dateAdded: number;
  size: number;
  status: number;
  progress: number;
  downloadType: string | null;
  fileNameFetchMode: number;
  maxSpeedLimitInKiB: number;
  targetDir: string | null;
  primaryUrl: string | null;
  refererUrl: string | null;
  auth: number;
  user: string | null;
  pass: string | null;
  proxy: number;
  proxyHost: string | null;
  proxyPort: number;
  proxyUser: string | null;
  proxyPass: string | null;
  proxyType: number;
}

/** UpdateDownloadEntry 的 15 列更新投影（DownloadList.cs:239-243 列清单；id 作 WHERE 参数不在投影内
 * ——用类型结构防"顺手多更新 status/progress/completed 一列"） */
export interface UpdateEntryRow {
  name: string | null;
  dateAdded: number;
  size: number;
  downloadType: string | null;
  targetDir: string | null;
  primaryUrl: string | null;
  auth: number;
  user: string | null;
  pass: string | null;
  proxy: number;
  proxyHost: string | null;
  proxyPort: number;
  proxyUser: string | null;
  proxyPass: string | null;
  proxyType: number;
}

/** INSERT 面（对照 DownloadList.cs:187-219 逐参数）：completed=data.kind（add 路径调用方保证 0，
 * C# AddNewDownload 固定收 InProgressDownloadItem）、status=data.status 直写、dateAdded 直通、
 * auth=authentication!==null?1:0、user/pass=authentication?.x??null、proxy=proxy.proxyType（非 null
 * 接口下等价 ??0）、proxyPort=proxy.port（等价 ??0）、proxyType 恒硬编码 1（:219） */
export function rowFromRecord(data: RecordData): DownloadRow {
  const row: DownloadRow = {
    id: data.id,
    completed: data.kind,
    name: data.name,
    dateAdded: data.dateAdded,
    size: data.size,
    status: data.status,
    progress: data.progress,
    downloadType: data.downloadType,
    fileNameFetchMode: data.fileNameFetchMode,
    maxSpeedLimitInKiB: data.maxSpeedLimitInKiB,
    targetDir: data.targetDir,
    primaryUrl: data.primaryUrl,
    refererUrl: data.refererUrl,
    auth: data.authentication !== null ? 1 : 0,
    user: data.authentication?.userName ?? null,
    pass: data.authentication?.password ?? null,
    proxy: data.proxy.proxyType,
    proxyHost: data.proxy.host,
    proxyPort: data.proxy.port,
    proxyUser: data.proxy.userName,
    proxyPass: data.proxy.password,
    proxyType: 1
  };
  return row;
}

/** 读回面（对照 DownloadList.cs:55-103 逐字段 + 强制规则 R1-R5）。
 * 入参 DownloadRow 已由 store 的 readRow 完成 NULL 归一（int→0、text→null、id null→''）。 */
export function recordFromRow(row: DownloadRow): RecordData {
  const kind: number = row.completed === 0 ? DownloadKind.InProgress : DownloadKind.Finished;
  // R2：completed=0 行 status 无条件 Stopped(1)（raw 丢弃）；完成行保留 raw 值
  const status: number = row.completed === 0 ? DownloadStatus.Stopped : row.status;
  // R3：progress 仅进行中行读入
  const progress: number = row.completed === 0 ? row.progress : 0;
  // R5：auth==1 且 user!==null 才构造（pass 可 null）
  let authentication: AuthenticationInfo | null = null;
  if (row.auth === 1 && row.user !== null) {
    const info: AuthenticationInfo = { userName: row.user, password: row.pass };
    authentication = info;
  }
  // R4：proxy 无条件构造
  const proxy: ProxyInfo = {
    proxyType: row.proxy,
    host: row.proxyHost,
    port: row.proxyPort,
    userName: row.proxyUser,
    password: row.proxyPass
  };
  const data: RecordData = {
    id: row.id,
    kind: kind,
    name: row.name,
    dateAdded: row.dateAdded,
    size: row.size,
    status: status,
    progress: progress,
    downloadType: row.downloadType,
    fileNameFetchMode: row.fileNameFetchMode,
    maxSpeedLimitInKiB: row.maxSpeedLimitInKiB,
    targetDir: row.targetDir,
    primaryUrl: row.primaryUrl,
    refererUrl: row.refererUrl,
    authentication: authentication,
    proxy: proxy
  };
  return data;
}

/** 15 列更新投影（对照 DownloadList.cs:239-259）：proxyType 恒 1（:259），auth/user/pass/proxy 规则同 rowFromRecord */
export function updateEntryRowFromRecord(data: RecordData): UpdateEntryRow {
  const row: UpdateEntryRow = {
    name: data.name,
    dateAdded: data.dateAdded,
    size: data.size,
    downloadType: data.downloadType,
    targetDir: data.targetDir,
    primaryUrl: data.primaryUrl,
    auth: data.authentication !== null ? 1 : 0,
    user: data.authentication?.userName ?? null,
    pass: data.authentication?.password ?? null,
    proxy: data.proxy.proxyType,
    proxyHost: data.proxy.host,
    proxyPort: data.proxy.port,
    proxyUser: data.proxy.userName,
    proxyPass: data.proxy.password,
    proxyType: 1
  };
  return row;
}

/** 进度百分比：fileSize<=0 → 0；否则 floor 截断（对照 HTTPDownloaderBase.cs:296
 * `(int)(totalDownloadedBytes*100/FileSize)` 的 C# 整数除法截断——两操作数非负时与 Math.floor 等价） */
export function computeProgress(downloadedBytes: number, fileSize: number): number {
  if (fileSize <= 0) {
    return 0;
  }
  return Math.floor(downloadedBytes * 100 / fileSize);
}

/** 初始状态（对照 Application.cs:56 `startType == DownloadStartType.Waiting ? Waiting : Stopped`） */
export function computeInitialStatus(startWaiting: boolean): number {
  return startWaiting ? DownloadStatus.Waiting : DownloadStatus.Stopped;
}

/** 分片临时目录拼接（对照 SingleSourceHTTPDownloader.cs:33 `Path.Combine(Config.Instance.TempDir, Id)`） */
export function joinTempDir(baseTempDir: string, id: string): string {
  return baseTempDir + '/' + id;
}
