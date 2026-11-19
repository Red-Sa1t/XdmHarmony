/*
 * U1.1 数据模型：共享纯类型层（设计书 §5.1）。
 * 零 import（含 @kit）——本地 Hypium 单测（entry/src/test）可直接加载本模块。
 * 四枚举成员显式数值 = downloads 表列值编码锚（禁隐式序，防重排）：
 *   DownloadStatus   → status 列（DownloadEntries.cs:64-67：Downloading, Stopped, Finished, Waiting）
 *   ProxyType        → proxy 列（ProxyInfo.cs:18-22：System, Direct, Custom）
 *   FileNameFetchMode→ filenamefetchmode 列（Downloader/FileNameFetchMode.cs:8-13：None, FileNameAndExtension, ExtensionOnly）
 *   DownloadKind     → completed 列分型键（DownloadList.cs:59-60：GetInt32(1)==0 → InProgress，否则 Finished）
 * 三 interface 对应 C# 值类型/投影：
 *   AuthenticationInfo（AuthenticationInfo.cs:8-12 struct：UserName/Password；password 保留 string|null，
 *     C# struct 引用字段可空语义，Basic 头消费方自行 ?? ''——设计书 D14）
 *   ProxyInfo（ProxyInfo.cs:9-16 struct；ArkTS 侧为非 null interface：C# 的 null Proxy 语义由
 *     DownloadRecord 工厂默认值等价承载，add 写 proxy=0/四 null 列逐值一致）
 *   RecordData：持久化投影 15 字段（DownloadRecord implements 它；不含 downloadSpeed/eta/downloadedBytes/tempDir）
 */

/** status 列值（DownloadEntries.cs:64-67） */
export enum DownloadStatus {
  Downloading = 0,
  Stopped = 1,
  Finished = 2,
  Waiting = 3
}

/** proxy 列值（ProxyInfo.cs:18-22） */
export enum ProxyType {
  System = 0,
  Direct = 1,
  Custom = 2
}

/** filenamefetchmode 列值（Downloader/FileNameFetchMode.cs:8-13） */
export enum FileNameFetchMode {
  None = 0,
  FileNameAndExtension = 1,
  ExtensionOnly = 2
}

/** completed 列分型键：0=进行中（InProgressDownloadItem）、1=已完成（FinishedDownloadItem） */
export enum DownloadKind {
  InProgress = 0,
  Finished = 1
}

/** 对照 AuthenticationInfo.cs:8-12（struct UserName/Password） */
export interface AuthenticationInfo {
  userName: string;
  password: string | null;
}

/** 对照 ProxyInfo.cs:9-16（struct ProxyType/Host/Port/UserName/Password）；非 null interface，缺省即 System/0/null */
export interface ProxyInfo {
  proxyType: number;
  host: string | null;
  port: number;
  userName: string | null;
  password: string | null;
}

/** 持久化投影 interface（15 字段 = downloads 表映射面；DownloadRecord implements 本接口） */
export interface RecordData {
  id: string;
  kind: number;
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
  authentication: AuthenticationInfo | null;
  proxy: ProxyInfo;
}
