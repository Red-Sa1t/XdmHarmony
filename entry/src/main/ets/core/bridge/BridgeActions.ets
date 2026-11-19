/*
 * U6.2 桥动作中立件（设计书 u6-2 §3.1/§1-#2，收敛 a 的循环依赖解法）。
 * 自 BridgeRoutes 上移三件（设计书 §4-13：import 路径变更、事件语义零变化——事件面零破坏
 * 红线不受影响）：
 *   ① BridgeUiEvents 接口+监听器注册表+fireBridgeUiEvent（原 BridgeRoutes:82-118 平移；
 *      onShowBatchSelection 载荷改 PendingBatchLink[]——收敛 b，§3.6）；
 *   ② startBridgeAutoDownload（原 BridgeRoutes:526-541 平移；**唯一建链点红线不变**：/download
 *      与 /vid 自动分支、tracker.addVideoDownload 自动分支都只走本函数，Index.ets:449-459 同构）；
 *   ③ /link pending 列表+getPendingBatchLinks（原 BridgeRoutes:120-125 平移；条目改 {url,file}
 *      对——U6.1 R4-F5 勘误的收敛 b：U6.3 勾选窗消费前完成，§2.7）。
 * 拓扑（§3.1）：BridgeRoutes → CapturedVideoTracker → BridgeActions 单向无环——tracker 动作半区
 * 的自动分支要调 startBridgeAutoDownload（源 StartVideoDownload→CoreService.StartDownload 同位），
 * 若留 BridgeRoutes 则 tracker→routes 逆边成环，故上移本中立件。
 * 对照源码（本会话只读核实，未改 resourses/ 下任何文件）：
 *   ApplicationCore.cs:208-236 —— AddDownload 自动分支建链（startBridgeAutoDownload 的源位）。
 *   IpcHttpMessageProcessor.cs:158-179 —— /link pending 收集（file=sanitize(file ?? GetFileName(url))）。
 * 业务日志：hilog domain 0x0000、tag 'BridgeActions'，绝不输出探针标记（§0-6）；日志不含请求体。
 * ArkTS 红线：无 any/解构/for...in/正则字面量；对象字面量均具 interface 类型；throw 只抛 Error。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { BridgeMessage } from './BridgeJson';
import { Config } from '../Config';
import { DownloadRecord } from '../../model/DownloadRecord';
import { DownloadCreationRequest, BridgeInboxItem, cloneDownloadCreationRequest } from '../../model/DownloadCreationRequest';
import { DownloadRequestContext, cloneDownloadRequestContext } from '../../model/DownloadRequestContext';
import { DownloadCreationService } from '../engine/DownloadCreationService';
import { BridgeInbox } from './BridgeInbox';
import { BridgeHeaders } from './BridgeProtocol';

/** 业务日志面（domain 0x0000 / tag 'BridgeActions'） */
const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'BridgeActions';

/** UI 动作降级事件面（设计书 §2.4/§4-5；自 BridgeRoutes 上移，事件语义零变化）：
 * ShowNewDownloadDialog/ShowVideoDownloadDialog/ShowDownloadSelectionWindow/--quit 进程退出/
 * --first-run/--background 主窗激活的降级投影。真窗口接线 U6.3（U4.2 已有 NewDownloadDialog/
 * DownloadSelectionDialog 组件可复用）。onShowBatchSelection 载荷=PendingBatchLink[]（收敛 b）。 */
export interface BridgeUiEvents {
  onShowNewDownloadDialog?: (msg: BridgeMessage) => void;
  onShowVideoDownloadDialog?: (videoId: string, name: string, size: number,
    contentType: string) => void;
  onShowBatchSelection?: (items: PendingBatchLink[]) => void;
  onAppCommand?: (cmd: string, argv: string[]) => void;
}

/** /link 批量链接 pending 条目（收敛 b，设计书 §2.7）：file 在 handleLinkRoute 映射时已算好
 * （sanitize(msg.file ?? fileNameFromUrl(url))——U6.1 现实现丢弃只存 url，本单元存对；U6.3
 * 勾选窗按 R4-F5 消费）。 */
export interface PendingBatchLink {
  url: string;
  file: string;
}

/** 事件监听器注册表（重复引用幂等；遍历拷贝+逐监听器 try/catch，Config.onConfigChanged 同款） */
const uiListeners: BridgeUiEvents[] = [];

export function registerBridgeUiEvents(l: BridgeUiEvents): void {
  if (uiListeners.indexOf(l) < 0) {
    uiListeners.push(l);
  }
}

export function unregisterBridgeUiEvents(l: BridgeUiEvents): void {
  const idx: number = uiListeners.indexOf(l);
  if (idx >= 0) {
    uiListeners.splice(idx, 1);
  }
}

/** 逐监听器派发（回调异常吞掉不塌缩事件链，设计书 §8）——自 BridgeRoutes.fireUiEvent 平移
 * 公开化（tracker.addVideoDownload 与 BridgeRoutes.addDownloadAction 共用）。 */
export function fireBridgeUiEvent(apply: (l: BridgeUiEvents) => void): void {
  const snapshot: BridgeUiEvents[] = uiListeners.slice();
  for (let i = 0; i < snapshot.length; i++) {
    try {
      apply(snapshot[i]);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s', 'ui event listener failed errCode=' +
        String(err.code) + ' errMessage=' + (err.message ?? ''));
    }
  }
}

/** /link 批量链接 pending 累积（内存，U6.3 勾选窗消费；会话态不落盘，§3.7）——条目为
 * {url,file} 对（收敛 b）。 */
export function pendingBatchLinksOf(items: BridgeInboxItem[]): PendingBatchLink[] {
  const links: PendingBatchLink[] = [];
  for (let i = 0; i < items.length; i++) {
    if (items[i].kind !== 'batch') {
      continue;
    }
    for (let j = 0; j < items[i].requests.length; j++) {
      const request: DownloadCreationRequest = items[i].requests[j];
      const link: PendingBatchLink = { url: request.url, file: request.name };
      links.push(link);
    }
  }
  return links;
}

/** 单条入列（handleLinkRoute 循环内逐条调；file 已由调用方 sanitize）。 */
export function getPendingBatchLinks(): PendingBatchLink[] {
  return pendingBatchLinksOf(BridgeInbox.getInstance().getPending());
}

/** Capture a detached request before awaiting persistence; later tracker or message edits cannot alter it. */
export function bridgeRequestOf(fileName: string, size: number, url: string, fetchMode: number,
  headers: BridgeHeaders | null, cookies: string | null): DownloadCreationRequest {
  const request: DownloadCreationRequest = new DownloadCreationRequest();
  request.url = url;
  request.contextUrl = url;
  request.name = fileName;
  request.size = size;
  request.targetDir = Config.getInstance().getDownloadDir();
  request.fetchMode = fetchMode;
  request.requestContext.cookies = cookies;
  if (headers !== null) {
    request.requestContext.headers = { names: headers.names.slice(), values: [] };
    for (let i = 0; i < headers.values.length; i++) {
      request.requestContext.headers.values.push(headers.values[i].slice());
    }
  }
  return request;
}

export async function enqueueBridgeRequests(requests: DownloadCreationRequest[], kind: string,
  videoKind: string = '', videoId: string = ''): Promise<BridgeInboxItem> {
  const item: BridgeInboxItem = new BridgeInboxItem();
  item.kind = kind;
  item.videoKind = videoKind;
  item.videoId = videoId;
  for (let i = 0; i < requests.length; i++) {
    item.requests.push(cloneDownloadCreationRequest(requests[i]));
  }
  return await BridgeInbox.getInstance().enqueue(item);
}

/**
 * 桥自动链唯一建链点（红线：/download 与 /vid 自动分支、tracker.addVideoDownload 自动分支只走
 * 本函数，Index.ets:449-459 同构）：newDownloadRecord(startWaiting=true) → fetchMode 覆盖 →
 * store.add → admitNew。**不更新 Index 内存 DS**——record 落库+引擎运行+事件经既有事件袋流向
 * Index（handler 对未知 id 有 findById→null 守卫不崩溃，§0-7③）；完整接线 U6.3（§4-10）。
 * admitNew 在 manager 未 init 时防御 no-op（DownloadManager 既有行为；真机流程 Index 先 init）。
 */
export async function startBridgeAutoDownload(fileName: string, size: number, url: string,
  fetchMode: number, context: DownloadRequestContext): Promise<DownloadRecord> {
  const targetDir: string = Config.getInstance().getDownloadDir();
  const request: DownloadCreationRequest = new DownloadCreationRequest();
  request.name = fileName;
  request.targetDir = targetDir;
  request.size = size;
  request.url = url;
  request.contextUrl = url;
  request.fetchMode = fetchMode;
  request.requestContext = cloneDownloadRequestContext(context);
  return await DownloadCreationService.getInstance().create(request);
}
