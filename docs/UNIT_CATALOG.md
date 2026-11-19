# XDM 鸿蒙迁移 · 单元目录（Unit Catalog）

> 版本：v1（2026-09-26，经全量审查后确立）。配套 [MIGRATION_PLAN.md](./MIGRATION_PLAN.md) 与 [PROBE_SPEC.md](./PROBE_SPEC.md)。
> 执行方式：每单元一次 ZCode 工作流 `xdm-migrate` 运行（源码研究 → 模块设计 → ArkTS 编码 → 对照审查 + 独立复核 + 报告，hvigor 编译门禁）。
> 单元粒度：一次运行 3~6 个文件，约等于人类 1~3 天工作量；24 单元 ≈ 计划的 8~12 周。

验证方式图例：**[A]**=AI 静态门禁可验（hvigor 编译 + codelinter 辅助 + 纯逻辑单测）；**[P]**=需生成探针、人工在**真机（优先）或模拟器**运行后回贴日志（`xdm-probe-verify` 核对；真机需一次性签名准备，设备侧无需任何开发工具）；**[H]**=纯人工环节（GUI 操作/材料/签核）。PC 形态相关验证（2-in1 自由窗口等）用模拟器。

## 敏捷批次与里程碑（v2 修订，2026-09-27）

> v1 的单元粒度经全量审查成立，予以保留；本节只改**执行节奏**：关键路径重排、人工验收点后移、非关键单元延后/去流程化。

**关键路径（走通骨架，尽快出真机可用里程碑）**：
U0.1 ✅ → U0.2（真机探针定栈）→ U1.1 → U1.2 → **M1：真机真下载（进度+续传雏形）**
→ U2.1 → U2.2 → **M2：断点续传** → U3.1 → U3.2 → **M3：队列/限速** → U4.1~U4.3 → **M4：完整 UI** → U5.1 → U5.2 → **M5：核心可交付（对齐原计划 Phase 5 末）** → U0.3 → U6.1~U6.3 → U6.4 → **M6：浏览器接管+HLS** → U7.1~U7.3 → **M7：交付**

**节奏调整**：
1. **Phase 0 不再全绿才进 Phase 1**：U0.2 探针 PASS 即开 Phase 1；U0.3 延后到 U6.1 之前，U0.4（人工主导）延后到 U6.4 之前，与主线并行补课。
2. **提交与验收**：AI 每单元完成即 git 提交（单元粒度回滚点），人工验收移到 **Phase 级**（每 Phase 末真机试用 + 走查 + `git tag phase-N`）——人从 24 个验收点降到 8 个。
3. **U0.5 去流程化**：纯调研文档工作，不占四 Agent 流水线，由主会话直接完成，结论写回计划。
4. **探针节奏**：按"探针运行节奏（省力原则）"节——一次性、批量、AI 驱动；关键结论型探针（U0.2）跑完才开依赖它的单元。

## Phase 0 环境与五项验证（5 单元）

| 单元 | 范围 | 对照源码 | 目标落点 | 验收要点 | 前置 | 验证 |
|---|---|---|---|---|---|---|
| **U0.1 工程基座修正+探针基建** | module.json5：deviceTypes 补 `2in1`、补 `ohos.permission.INTERNET`；EntryAbility 支持 want 参数路由探针页；探针基建 `entry/src/main/ets/probe/core/ProbeKit.ets` + `ProbePage.ets` + `ProbeIndex.ets` + main_pages.json 注册；首批 string.json 键 | —（脚手架修正） | module.json5、EntryAbility.ets、probe/、main_pages.json | 编译过；模拟器可装可启动；探针页可经参数拉起并输出 `[XDM_PROBE]` 标记 | 无 | [A]+[H]冒烟 |
| **U0.2 HTTP 能力探针** | requestInStream 流式落盘、`Range: 0-`→206 判定、identity 编码、TaskPool 内 8 并发（兼验风险 #4）、重定向回写最终 URL、Cookie 注入、30s 超时；产出"http 还是 rcp"结论回写计划 | DotNetHttpClient.cs | probe/units/ProbeHttp.ets + docs/probe/PROBE-P0-U2.md + EXPECT-P0-U2.json | 六步骤标记齐全；结论明确 | U0.1 | [A]+[P] |
| **U0.3 扩展桥 8597 服务端探针** | TCPSocket 监听 8597 + 最小 HTTP 解析 + 应答 `/sync` 最小字段（对照原版手写 HttpServer）；主机侧 `hdc fport` + curl 模拟扩展流量 | HttpServer/HttpParser.cs、LineReader.cs、IpcHttpMessageProcessor.cs:51-73、chrome-extension/connector.js | core/bridge/BridgeServer.ets 雏形 + 探针 | curl GET /sync 得到合法 JSON；模拟器内自连通过 | U0.1 | [A]+[P] |
| **U0.4 ffmpeg spike**（人工主导） | gitcode 下载 n6.0 产物、按 hap_integrate.md 集成、NAPI 跑通 remux+libmp3lame；AI 写 NAPI 封装面与探针 | FFmpegMediaProcessor.cs（244 行，3 命令） | libc/ + napi 雏形 + ProbeFfmpeg | remux 退出码 0、产物可播；HAP 体积记录 | U0.1 | [H]集成+[P]验 remux |
| **U0.5 平台辅助调研** | 托盘 API、startupTask 自启、fs 随机写、rcp 能力面；真机/模拟器是否预装华为浏览器（人工目检，真机优先）；结论写回计划/风险文档 | — | docs 调研结论 | 每项 GO/退化结论明确 | U0.1 | [A]+[H]浏览器目检 |

**Phase 0 出口**：U0.2 结论（http/rcp）、U0.3+U6.3 前置结论（接管/仅嗅探）、U0.4 结论（完整/单轨）、U0.1 冒烟、U0.5 文档——五项各有明确结论。

## Phase 1 工程骨架 + 单线程下载（2 单元）

| 单元 | 范围 | 对照源码 | 目标落点 | 验收要点 | 前置 | 验证 |
|---|---|---|---|---|---|---|
| **U1.1 数据模型+存储+配置骨架** | model/DownloadRecord.ets（@Observed，字段对照 DownloadEntries.cs 15 项）；core/db/DownloadStore.ets（RelationalStore 建表对照 SchemaInitializer.cs 22 列；CRUD API 面对照 DownloadList.cs）；core/Config.ets 骨架（Phase 1 所需键，默认值对照 Config.cs:100-122）；EntryAbility onCreate 初始化挂接；base string.json 业务文案键 | DataAccess/SchemaInitializer.cs、AppDB.cs、DownloadList.cs、DownloadEntries.cs、Config.cs | model/DownloadRecord.ets、core/db/DownloadStore.ets、core/Config.ets、EntryAbility.ets（改）、string.json（改） | 编译过；探针验证建表+CRUD+重启持久 | U0.1 | [A]+[P] |
| **U1.2 单线程下载+主列表+新建对话框** | core/net/HttpClient.ets（**纯传输层**：GET/重定向回写/Cookie 注入/超时 30s/requestInStream dataReceive 回调/回传 status+headers；栈选型按 U0.2 结论；identity）；core/engine/Downloader.ets（单线程循环：进度/暂停/取消/暂停后 `Range: bytes=N-` 恢复+206 校验/完成拼接 temp→最终文件+markAsFinished）；Index 改造为列表页（@Observed+@ObjectLink，为 LazyForEach 预留）；components/NewDownloadDialog.ets（按 INewDownloadDialog 契约最小子集） | Clients/Http/DotNetHttpClient.cs、HttpRequest.cs、HttpResponse.cs、IHttpClient.cs、Downloader/Progressive/SingleHttp/SingleSourceHTTPDownloader.cs、UI/INewDownloadDialog.cs、UI/NewDownloadDialogUIController.cs、Wpf.UI/Dialogs/NewDownload/、Lang/English.txt | core/net/HttpClient.ets、core/engine/Downloader.ets、pages/Index.ets（改）、components/NewDownloadDialog.ets | 完整下载到沙箱；实时进度；暂停恢复（Range 206 链路）；重启后历史可见；PROBE 标记 DL_START/PROGRESS/PAUSE/RESUME(206)/COMPLETE | U0.2、U1.1 | [A]+[P] |

> 分层依据：原版 `DotNetHttpClient.cs`（204 行）是纯传输层，暂停/取消/进度/分片全部在 `HTTPDownloaderBase.cs`（636 行）——HttpClient 不承载下载语义，否则 Phase 2 引入 TaskPool 多分段时必须重构。

## Phase 2 分段并发 + 断点续传（3 单元）

| 单元 | 范围 | 对照源码 | 目标落点 | 验收要点 | 前置 | 验证 |
|---|---|---|---|---|---|---|
| **U2.1 PieceGrabber+SegmentWorker 并发** | 动态分裂逐行翻译（单 Piece `Range:0-` 探测→206 判 resumable→最大剩余分片对半分裂、阈值 256KB）；相邻分片吸收 ContinueAdjacentPiece；TaskPool 并发（MaxSegments=8） | Downloader/Progressive/PieceGrabber.cs（472 行）、HTTPDownloaderBase.cs:405-466、Piece.cs、SegmentState.cs | core/engine/PieceGrabber.ets、SegmentWorker.ets | 8 分段并行日志；大文件吞吐显著优于 U1.2 | U1.2 | [A]+[P] |
| **U2.2 分片落盘+断点续传+进度持久化** | 每分片独立临时文件追加写、完成按 Offset 排序 5MB 缓冲拼接；进度 JSON 持久化（决策 4）；杀进程重启续传 | HTTPDownloaderBase.cs:557-618、SingleSourceHTTPDownloader.cs 落盘段 | engine 扩展 + core/db/StateStore.ets | 杀进程→重启→断点续传（PROBE 记录每分片 offset） | U2.1 | [A]+[P] |
| **U2.3 引擎保真度对照单测** | 分裂/吸收/续传偏移计算抽成纯函数模块，对照原版算法做用例表 | PieceGrabber.cs、HTTPDownloaderBase.cs | core/engine 纯函数 + 本地测试用例 | 用例全绿；与源码行为逐条对照表 | U2.1 | [A] |

## Phase 3 队列/调度/限速/重试（2 单元）

| 单元 | 范围 | 对照源码 | 目标落点 | 验收要点 | 前置 | 验证 |
|---|---|---|---|---|---|---|
| **U3.1 队列调度+并发上限** | 并发上限 3 + 排队 + 状态机 + 优先级 | QueueManager.cs（123 行）、DownloadQueue.cs（83 行） | core/engine/DownloadManager.ets | 排队正确（PROBE 记录并发数不超 3） | U2.2 | [A]+[P] |
| **U3.2 限速+重试+定时调度** | 睡眠补偿限速改异步 sleep；固定间隔重试（MaxRetry=10/RetryDelay=10s——源码核实无指数退避，勘误）；Scheduler 定时启停 | SpeedLimiter.cs（89 行）、Scheduler.cs（119 行）、Config.cs | core/engine/SpeedLimiter.ets、Scheduler.ets | 限速实测吻合；断网恢复自动续跑；定时窗启停 | U3.1 | [A]+[P] |

## Phase 4 UI 对齐 + 国际化（3 单元）

| 单元 | 范围 | 对照源码 | 目标落点 | 验收要点 | 前置 | 验证 |
|---|---|---|---|---|---|---|
| **U4.1 主窗口框架** | 双列表（进行中/完成）、分类树、搜索、工具栏；Navigation/NavDestination 路由定案；DownloadListItem + LazyForEach/IDataSource | Wpf.UI/MainWindow.xaml(.cs)、Core/UI/IApplicationWindow.cs、IFinishedDownloadRow/IInProgressDownloadRow | pages/、components/ | 走查清单项可勾；列表流畅 | U3.1 | [A]+[P]走查 |
| **U4.2 对话框包** | 按契约实现操作类对话框（Progress/Selection/Batch/RefreshLink/Credential/DeleteConfirm/Completed/SpeedLimiter 等，降级项隐藏） | Core/UI/ 各 I*View + Wpf.UI/Dialogs/ | pages/dialogs、components | 各对话框开合/回调接通控制器逻辑 | U4.1 | [A]+[P]走查 |
| **U4.3 设置页全配置键+i18n+主题** | Config 44 键落地 preferences（裁剪降级项）；string.json base+zh_CN+en_US（对照 Lang/）；深浅色 | Config.cs:44-228、Wpf.UI/Dialogs/Settings/、Lang/*.txt | pages/Settings、resources/ | 语言切换即时生效；深浅色；设置项读写闭环 | U4.1、U1.1 | [A]+[P]走查 |

## Phase 5 系统集成（2 单元）

| 单元 | 范围 | 对照源码 | 目标落点 | 验收要点 | 前置 | 验证 |
|---|---|---|---|---|---|---|
| **U5.1 后台长时任务+通知** | DATA_TRANSFER 长时任务（bgMode + KEEP_BACKGROUND_RUNNING 权限补入 module.json5）；常驻进度通知 + 完成通知 | ClipboardMonitor.cs（系统侧语义）、原版 NotifyIcon 通知语义 | core/notify/ProgressNotifier.ets、module.json5 | 关窗后下载继续；通知进度刷新 | U3.1 | [A]+[P] |
| **U5.2 剪贴板监视+保存目录** | pasteboard.on('update') 订阅 + 直链识别弹提示；DocumentViewPicker 选目录 + 写用户目录 | ClipboardMonitor.cs、IPlatformClipboardMonitor.cs | core/clipboard/ClipboardWatcher.ets | 复制直链弹提示；文件落用户目录 | U5.1、U4.1 | [A]+[P] |

## Phase 6 浏览器集成 + HLS（4 单元）

| 单元 | 范围 | 对照源码 | 目标落点 | 验收要点 | 前置 | 验证 |
|---|---|---|---|---|---|---|
| **U6.1 BridgeServer 八路由完整版** | 八路由补全（/sync /media /download /vid /clear /tab-update /link /args）；/sync 配置字段逐一对照 + 响应头剥离规则 | IpcHttpMessageProcessor.cs、HttpServer/*.cs、ExtensionData.cs | core/bridge/BridgeServer.ets | Node/curl 模拟八路由流量全绿（AI 本地可自验） | U0.3 | [A]+[P]端到端 |
| **U6.2 嗅探规则+视频捕获** | VideoUrlHelper 规则链翻译（blockedHosts→扩展名→URL 正则→mediaTypes→Content-Disposition→host 白名单）；CapturedVideoTracker；视频捕获页 | VideoUrlHelper.cs（980 行）、CapturedVideoTracker.cs（242 行）、Wpf.UI/Dialogs/MediaCapture | core/bridge/VideoUrlHelper.ets、pages/VideoCapture | 规则链用例表全绿（纯逻辑单测）；样例 URL 分类正确 | U6.1 | [A]+[P] |
| **U6.3 扩展复用+端到端接管** | chrome-extension/ 复制入 extension/（AI 可做）；接管链路 downloads.onDeterminingFilename→cancel→POST /download；无浏览器则退化"仅嗅探+popup 手动" | chrome-extension/（main.js、request-watcher.js、connector.js、manifest.json） | extension/ | 真浏览器播视频→扩展弹窗→应用带 cookies 下载 | U6.1、U6.2、U0.3 | [A]复制改造+[H]浏览器实测（关键人工环节） |
| **U6.4 HlsDownloader** | HlsParser（EXT-X-STREAM-INF/BYTERANGE/MAP/MEDIA-SEQUENCE）+ chunk 区间认领调度 + 双轨 concat + remux + .mkv 降级 | MediaParser/Hls/HlsParser.cs（269 行）、HlsHelper.cs、Downloader/Adaptive/Hls/MultiSourceHLSDownloader.cs（373 行） | core/adaptive/HlsDownloader.ets | 公共 HLS 测试流下载可播 | U2.2、U0.4 | [A]+[P] |

## Phase 7 ffmpeg/DASH + 收尾（3 单元）

| 单元 | 范围 | 对照源码 | 目标落点 | 验收要点 | 前置 | 验证 |
|---|---|---|---|---|---|---|
| **U7.1 DashDownloader** | MpdParser（@ohos.util.xml 重写，拒绝 dynamic/ContentProtection）；SegmentBase/List/Template 三寻址 + Timeline 展开 + 模板变量（含补零）；video×audio 组合 UI | MediaParser/Dash/MpdParser.cs（431 行）、DashUtil.cs、Representation.cs、Adaptive/Dash/MultiSourceDASHDownloader.cs | core/adaptive/DashDownloader.ets | DASH 测试流多轨合并可播 | U6.4、U7.2 | [A]+[P] |
| **U7.2 MediaProcessorNapi** | remux（copy/copy）+ 转 MP3（libmp3lame）最小命令面 NAPI 封装；失败降级 .mkv；退出码判定 | FFmpegMediaProcessor.cs、BaseMediaProcessor.cs | core/media/MediaProcessorNapi.ets + libc/ | remux/mp3 产物可播；降级路径生效 | U0.4 | [A]+[P] |
| **U7.3 签名打包+交付文档** | 签名打包（材料人工提供）；迁移报告含 15% 降级清单与原因、GPL-2.0 声明（§11）；真机回归扩展/后台/通知 | — | release HAP + docs | 签名 HAP 可安装；交付物齐 | 全部 | [H]+[P]回归 |

## AI 流水线不可独立完成项与对策

| # | 不可独立完成项 | 对策 |
|---|---|---|
| 1 | ffmpeg native 产物获取与 NAPI 集成环境（U0.4） | 人工下载产物+首次 native 编译；AI 写封装面与探针；失败降级：DASH 降级、HLS 单轨 |
| 2 | 模拟器/真机行为验收（装包、后台、剪贴板、通知、杀进程续传、限速读数） | 探针页 + PROBE 标记 + 人工回贴日志，`xdm-probe-verify` 机械核对 |
| 3 | 浏览器扩展真栈实测（U0.3 部分、U6.3） | 服务端逻辑 AI 用 curl/Node 模拟流量先行自验；扩展侧人工加载实测；模拟器无浏览器→真机补验或退化"仅嗅探" |
| 4 | 签名材料（U7.3） | 人工 `devecocli auth login` + `signature generate`（模拟器推包不需要签名） |
| 5 | 公网/本地测试源（HLS/DASH 测试流、Range 源 `npx http-server -a 0.0.0.0`，注意模拟器内不能用 127.0.0.1 访问主机） | 本地源 AI 脚本化进探针基建；公网可达性人工确认一次 |
| 6 | 每 Phase tag 与验收签核 | git 提交/tag 由人工执行；AI 每单元产出迁移报告作为验收输入 |

## 探针运行节奏（省力原则）

探针是**一次性验收工具，不是回归测试**：每个探针单元 PASS 后即归档，结论写回计划供后续单元引用，不重复运行（Phase 7 整机回归用正式应用，不用探针页）。日常防回归由每轮自动重跑的 hvigor 编译门禁与审查承担，不经人工。

1. **AI 直接驱动**：devecocli/hdc 都在 PC 侧——真机 USB 连接并解锁后，安装、拉起探针页、抓取日志由 AI 在会话内自动执行；人工只做设备侧交互步骤（复制文本、浏览器装扩展、点按钮）与最终验收。
2. **批量运行**：探针 HAP 是累积的（一次安装含全部已生成探针），一份日志可同时验证多个单元（标记自带单元 ID），攒到 Phase 末一次跑即可。
3. **仅两类探针必须提前跑**：结论是后续单元实现前提的——U0.2（HTTP 栈选型 → U1.2 开写前）、U0.4（ffmpeg 集成结论 → U6.4/U7.2）。

按此节奏，全程人工介入约 7~8 次（Phase 0 两次、其后每 Phase 末一次），每次 5~10 分钟。

## 运行模板

每个单元运行 `xdm-migrate` 时，从本目录对应行复制参数：`unit`＝单元名+范围+验收要点；`source`＝对照源码（分号分隔）；`target`＝目标落点；`notes`＝前置探针结论与决策条款（如"U0.2 结论：http 栈可用，requestInStream 分块行为见 EXPECT-P0-U2"）。执行顺序严格按"前置"列。
