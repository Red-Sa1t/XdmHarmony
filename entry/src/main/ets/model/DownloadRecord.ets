/*
 * U1.1 数据模型：@Observed 单一下载记录模型 + 工厂（设计书 §2.2/§5.2）。
 * 对照源码：XDM.Core/DownloadEntries.cs——DownloadItemBase 12 字段（:9-31）+ InProgressDownloadItem
 * 4 字段（:51-57）= 16 字段（有意差异 D9：单元指令写"15 项"系对源码的低估，按源码事实 16 落地；
 * DownloadSpeed/ETA 是 UI 派生非持久化列）；另加运行时字段 downloadedBytes/tempDir（单元指令要求，
 * 引擎期有效，持久真值分别是 progress 列与 Config.tempDir——重启后由消费方重算，不落库）。
 * InProgress/Finished 双 C# 类型 → 单一 @Observed 类 + kind 字段（completed 列分型键，D4；
 * UI 侧按 kind 拆双列表，MIGRATION_PLAN 决策 11 的 @Observed+@ObjectLink 消费本模型）。
 * 工厂对照 Application.AddItemToTop（Application.cs:43-63）：Progress=0、Status=startWaiting?Waiting:Stopped、
 * DateAdded=date（有意差异 D1：epoch 毫秒 Date.now() 而非 DateTime.ToBinary()）、Id=UUID
 * （util.generateRandomUUID 对照 Guid.NewGuid().ToString()）。
 * 本文件含 @Observed 与 @kit import，不进本地单测（其行为由 store 路径单测与探针覆盖）。
 * U4.1 两处增量（设计书 §5.7）：①类声明追加 implements SortableRow（core/util/ListAlgo——
 * ArkTS 无结构化类型，model→util 单向无环；compareRows/sortedInsertIndex 排序投影入参）；
 * ②追加 UI 会话字段 uiSelected（选中高亮/复选框渲染态——不实现 RecordData 接口成员、
 * rowFromRecord 不映射、不落库，重启即失，WPF 选中态同为视图态；单写者=Index 选中链，
 * 行组件经 @ObjectLink 只读观察）。其余 16+2 字段与工厂零改动。
 */

import { util } from '@kit.ArkTS';
import { SortableRow } from '../core/util/ListAlgo';
import { DownloadRequestContext } from './DownloadRequestContext';
import { AdaptiveSourceDescriptor } from './AdaptiveSource';
import {
  AuthenticationInfo,
  DownloadKind,
  DownloadStatus,
  FileNameFetchMode,
  ProxyInfo,
  ProxyType,
  RecordData
} from './DownloadTypes';

@Observed
export class DownloadRecord implements RecordData, SortableRow {
  /** 对照 Id（DownloadEntries.cs:9）；工厂置 util.generateRandomUUID() */
  id: string = '';
  /** completed 列分型键（0=进行中/1=已完成）；add 路径恒 InProgress */
  kind: number = DownloadKind.InProgress;
  /** 对照 Name（:11） */
  name: string | null = null;
  /** 对照 DateAdded（:17）；epoch 毫秒（D1） */
  dateAdded: number = 0;
  /** 对照 Size（:13） */
  size: number = 0;
  /** 对照 Status（InProgressDownloadItem.cs:53）；列值 int，add 时按 startType 置 Waiting(3)/Stopped(1) */
  status: number = DownloadStatus.Stopped;
  /** 对照 Progress（:51）；整数百分比，add 恒 0（Application.cs:55） */
  progress: number = 0;
  /** 对照 DownloadType（:19） */
  downloadType: string | null = null;
  /** 对照 FileNameFetchMode（:21） */
  fileNameFetchMode: number = FileNameFetchMode.None;
  /** 对照 MaxSpeedLimitInKiB（:31） */
  maxSpeedLimitInKiB: number = 0;
  /** 对照 TargetDir（:15） */
  targetDir: string | null = null;
  /** 对照 PrimaryUrl（:23） */
  primaryUrl: string | null = null;
  /** U6.3: persisted in download_request_context; old records retain null headers/cookies. */
  requestContext: DownloadRequestContext = new DownloadRequestContext();
  /** Additive side-table version; transport writes use optimistic concurrency. */
  requestRevision: number = 0;
  /** HLS/DASH/dual source identity (download_adaptive_source side table); null for Http. */
  adaptiveSource: AdaptiveSourceDescriptor | null = null;
  /** 对照 RefererUrl（:25） */
  refererUrl: string | null = null;
  /** 对照 Authentication（:27）；C# 可空 struct → interface|null */
  authentication: AuthenticationInfo | null = null;
  /** 对照 Proxy（:29）；非 null interface（缺省 System/0/null 等价 C# null Proxy 的入库投影） */
  proxy: ProxyInfo = {
    proxyType: ProxyType.System,
    host: null,
    port: 0,
    userName: null,
    password: null
  };
  /** 对照 DownloadSpeed（InProgressDownloadItem.cs:55）；UI 派生，非持久化列 */
  downloadSpeed: string | null = null;
  /** 对照 ETA（:57）；UI 派生，非持久化列 */
  eta: string | null = null;
  /** 运行时状态：引擎累计字节（对照 HTTPDownloaderBase.cs totalDownloadedBytes）；持久真值是 progress 列 */
  downloadedBytes: number = 0;
  /** 运行时状态：分片临时目录 = tempDir/id（对照 SingleSourceHTTPDownloader.cs:33）；引擎接管时经 joinTempDir 计算 */
  tempDir: string = '';
  /** UI 会话态：行选中高亮/复选框渲染（U4.1；不落库不入 RecordData，单写者=Index 选中链） */
  uiSelected: boolean = false;
}

/**
 * 新下载记录工厂（对照 Application.AddItemToTop，Application.cs:43-63）。
 * status 由 startWaiting 内联三元给出（同 computeInitialStatus 语义，内联避免 model→db 依赖）；
 * proxy 入参可 null → 默认 ProxyInfo（等价 C# AddNewDownload 的 Proxy?.x ?? 缺省投影）。
 * id 语义（COLD-F1）：内部恒置 util.generateRandomUUID()；需确定性 id 的调用方（探针/引擎幂等场景）
 * 在 add 落库前直接覆盖 record.id——等价 C# AddItemToTop 的 Id=id 由调用方直传（Application.cs:55）。
 */
export function newDownloadRecord(fileName: string | null, targetDir: string | null, fileSize: number,
  downloadType: string | null, primaryUrl: string, startWaiting: boolean,
  authentication: AuthenticationInfo | null, proxy: ProxyInfo | null): DownloadRecord {
  const record: DownloadRecord = new DownloadRecord();
  record.id = util.generateRandomUUID();
  record.name = fileName;
  record.dateAdded = Date.now();
  record.size = fileSize;
  record.status = startWaiting ? DownloadStatus.Waiting : DownloadStatus.Stopped;
  record.progress = 0;
  record.downloadType = downloadType;
  record.targetDir = targetDir;
  record.primaryUrl = primaryUrl;
  record.authentication = authentication;
  if (proxy !== null) {
    record.proxy = proxy;
  }
  return record;
}
