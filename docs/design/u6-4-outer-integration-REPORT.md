# U6.4/U7.1 外层集成（HLS/DASH 业务外壳）落地报告

日期：2026-11-06。范围：把已真机验证的引擎层（清单客户端、计划 B、状态 C、E1~E4、F 装配、Native remux）接成用户可用的下载功能。设计依据为 `migration-runs/202610080259/u6-4-hls-outer-integration-design.md`（O1~O8 草案）；本轮落地的是其中可独立交付的业务切片，未做的部分在第 5 节逐条登记。

## 1. 交付结果

用户在捕获页对 HLS（master 各档、media 单档、分离音轨）、DASH（视频+音频双轨）、双源（YouTube 分轨）条目点下载，弹出与普通下载相同的新建对话框（可改文件名），确认后进入下载列表，与 HTTP 任务共用并发上限、队列、暂停/继续、进度、完成通知与完成后拷贝到用户目录。下载完成的文件落在沙箱下载目录，扩展名取装配后的真实容器（.ts/.mp4/.mkv）。

## 2. 改动清单

| 层 | 文件 | 内容 |
|---|---|---|
| 模型 | model/AdaptiveSource.ets（新） | 来源描述 `AdaptiveSourceDescriptor`（hls/dash/dual 三类，schema 1）、严格校验、深拷贝、序列化；`adaptiveDownloadType` 映射 Hls/Dash/Dual；`mimeFromUrlQuery`（googlevideo `mime=`） |
| 模型 | model/DownloadCreationRequest.ets、DownloadRecord.ets | 创建请求与记录携带 `adaptive`/`adaptiveSource`；旧 inbox 载荷缺字段按 Http 处理 |
| 存储 | core/db/DownloadStore.ets | 加性旁表 `download_adaptive_source(id,payload)`；add/promote 与主行同一 IMMEDIATE 事务写入，remove 同事务删除，查询 LEFT JOIN 读回；损坏描述读为 null（不降级成 Http，下载器报 AdaptiveSourceMissing） |
| 创建 | core/engine/DownloadCreationService.ets | downloadType 按描述取 Hls/Dash/Dual，否则 Http |
| 桥 | core/bridge/BridgeRoutes.ets | **HLS 捕获接线**（此前识别后只记日志）：拉取清单 → master 每个 variant/rendition 组合一条（分离音视频 MP4、否则 TS，显示「类型 画质」）；media 列表一条（显示 [容器]）；I-frame-only 跳过 |
| 桥 | core/bridge/CapturedVideoTracker.ets | 快照（首个 await 前）附带完整描述；`adaptiveSourceOf` 由 hls/dash/yt 表条目构造 |
| 桥 | core/bridge/BridgeInbox.ets | 自适应 video inbox 确认时强制采用捕获时描述（调用方不可替换来源，也不可降级为 Http）；无描述仍拒绝 |
| 引擎 | core/engine/AdaptiveDownloader.ets（新） | 业务外壳，接口与 HTTP Downloader 相同（start/resume/stop/isRunning + 六事件）：E4 先恢复 → 仅精确 C.empty 才拉清单建计划 → 第二个 E4 子运行 → ready 租约 → F 装配 → 搬入下载目录（防重名，rename 失败回退 copy）→ 释放租约 → 清临时目录 → onFinished |
| 引擎 | core/engine/DownloadManager.ets | `ManagedDownloader` 接口 + `createManagedDownloader` 工厂（按持久化 downloadType 选择） |
| 引擎 | core/adaptive/AdaptiveRunController.ets | 只读 `progressSnapshot()`（已封存块数/字节 + 本次实际写入字节），供 UI 进度/速度 |
| 引擎 | core/adaptive/AdaptiveAttemptExecutor.ets | 拒绝响应头诊断钩子（仅块号、状态码、固定码，不含 URL/头/正文） |
| 页面 | pages/Index.ets | 有描述的自适应条目走新建对话框；无描述仍提示「暂不支持」 |

## 3. 真机验收中发现并修复的两项缺陷

| 缺陷 | 现象 | 根因 | 修复 |
|---|---|---|---|
| SDK URL 基址解析不符合 RFC 3986 | 公共 DASH `bbb_30fps.mpd`（BaseURL `./`）全部分片 404，重试耗尽 | 设备 `url.URL.parseURL('./', 'https://h/a/b.mpd')` 把 `b.mpd` 当目录；持久化描述中分片 URL 为 `…/bbb_30fps.mpd/bbb_30fps_320x180_200k/…`（从设备 downloads.db 取证） | HlsUrlResolver 改为纯字符串 RFC 3986 §5.2 合并与 remove_dot_segments，SDK 只做无基址的最终校验；主机加「仿设备缺陷」回归与 RFC 5.4.1 例表 |
| 分片 4xx 不重试（与源不一致） | 设备网络路径下 CDN 边缘偶发 404 即整任务失败 | E1 把 401/403/404/416 判为不可重试；源 HttpChunkDownloader `EnsureSuccessStatusCode` 抛错后按 MaxRetry/RetryDelay 重试 | 400–599 一律 retryable（保留固定码），1xx/2xx 其他/3xx 仍为 fatal；Hypium 与主机断言同步修订 |

## 4. 证据

主机：`node --test XdmHarmony/tests/host/` 629 项，624 通过、0 失败、5 跳过（新增 adaptive-downloader 18 项、creation-inbox 自适应 4 项、bridge HLS 捕获 3 项、Index 路由 1 项、RFC 解析 1 项）。

真机（MateBook Pro HAD-W24 · API 23，2026-11-06，`hdc rport` 使主机源对设备呈现为 127.0.0.1）。验收源 `docs/probe/E2E-adaptive-host.cjs` 用 ffmpeg 生成真实 H.264+AAC 20 秒媒体；判定用 ffprobe/ffmpeg 解码比对，原始记录见 `docs/probe/e2e-adaptive-2026-11-06.log`。

| 场景 | 结果 |
|---|---|
| HLS master 捕获 | 2 档（TS 混流、MP4 分离音轨）入捕获列表；Cookie 随清单请求 |
| HLS 单轨（TS） | 产物与 10 个分片拼接逐字节一致；视频/音频解码 MD5 与源一致 |
| HLS 双轨（视频 + AUDIO rendition） | 设备 Native remux 为 MP4；视频、音频解码 MD5 与源逐位一致 |
| DASH 双轨（fMP4） | 视频解码 MD5 与源一致；音频 PCM 与 DASH 参考逐样本一致，仅尾部按视频时长裁 1041 样本（23.6 ms，remux 行为） |
| 下载中强杀进程 → 重启 → 继续 | 重启后零清单请求，只补拉 5 个未封存分片；产物逐字节一致 |
| 应用内暂停 → 继续 | 暂停后无新请求；继续只拉 12 个未完成分片（无清单、无 init）；产物与未中断下载一致 |
| 公共 DASH（Akamai bbb_30fps 180p，修复后） | 21.2 MB / 634.57 s；视频解码 MD5 与主机按 CDN 分片自建参考一致，音频 PCM 逐样本一致，全程解码零错误 |
| 公共 HLS（Mux x36xhzz 240p） | 22.4 MB / 634.6 s；与 64 个 CDN 分片拼接逐字节一致，解码零错误 |
| 进度 UI | 列表/进度窗显示百分比、速度、剩余时间；完成前不显示 100% |

## 5. 未做与已知差距（如实登记）

| 项 | 说明 |
|---|---|
| 运行中前缀持久化（O5b） | 只有封存后的分片计入断点；单个长分片中途强杀从 0 重下（本次实测：被杀时在途的 5 个分片整片重下）。分片型流影响小，双源（整文件单分片）影响大 |
| POST 清单发现（O3） | 桥捕获仅 GET；需 POST+Base64 正文的站点不可用 |
| 每来源认证/代理（O4） | 使用捕获时 Referer/Cookie 等请求头；未兑现任务级 Basic/Digest 与手动代理；双源第二套请求头（headers2/cookies2）未使用 |
| 分片重定向 | E3 `autoRedirect:false`，分片 3xx 判 fatal（源 HttpClient 会自动跟随）；本次公共流未遇到 |
| 完成回执（O6b） | 完成写库沿用 HTTP 路径（Index.handleFinished → markAsFinished），未实现 completionId/outbox 幂等回执 |
| 双源 MIME | 无 `mime=` 时按 video/mp4、audio/mp4 推断容器 |
| 用户目录拷贝 | 沿用 U5.2 D2：Picker 临时授权重启后失效，拷贝失败留沙箱并提示（本次重启后实测 13900001） |
| 刷新链接 | 自适应任务仍提示不支持刷新（与 HTTP 刷新流程不兼容） |
