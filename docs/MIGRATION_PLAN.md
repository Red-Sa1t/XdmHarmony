# XDM (Xtreme Download Manager) 鸿蒙 PC 迁移计划

> 版本：源码深挖收敛版（v3，2026-09-22）
> 决策结论：**GO（推荐推进）**，前置条件为 Phase 0 五项技术验证
> 配套文档：[风险深挖报告](./RISK_ASSESSMENT.md)

---

## 1. 背景与目标

将开源下载管理器 Xtreme Download Manager（XDM 2023，`subhra74/xdm`，GPL-2.0）在鸿蒙 PC 形态上以 ArkTS/ArkUI 重新实现，目标功能完整对等。

- **源码参考**：`D:\git\HarmonyPC\resourses\xdm`（只读，不参与编译）
- **目标工程**：`D:\git\HarmonyPC\XdmHarmony`（本工程，API 24 / SDK 6.1.1(24)，bundle `com.example.xdmharmony`；**2026-10-12 已更名 `com.neuohos.xdm` 备上架**，本文档以下旧名均为历史写作时点记录——现状以 DELIVERY.md 头注为准）
- **执行方式**：编码全部由 AI build agent 完成；学生每周 10-15 小时监督验收
- **验证环境**：鸿蒙真机优先（更真实；需一次性签名准备；设备侧无需开发工具，探针即普通 HAP）；DevEco Studio PC 模拟器为兜底与 PC 形态验证（2-in1 自由窗口）；结论标注环境

**产出物**：可在 PC 模拟器安装运行的 HAP 应用；分阶段 git 里程碑（每 Phase 一个 tag）；课程交付物（迁移报告、演示）。

## 2. 总体判断

**这不是"移植"而是"跨语言重写"**：XDM 2023 为 C#/.NET（WPF + Gtk# 双 UI，共享 XDM.Core），鸿蒙 NEXT 无 .NET 运行时，原代码只能作为参考规格逐模块对照翻译。

**难度：7/10**（深度调研后从 8/10 下调）。估算 8-12 周。功能分布：

| 分类 | 占比 | 说明 |
|---|---|---|
| 纯逻辑可直接对照翻译 | ~60% | 分段算法、HLS/DASH 解析、限速、队列/调度、配置、嗅探规则、扩展协议、UI 控制器逻辑 |
| 需按鸿蒙 API 重设计（有官方对应物） | ~25% | HTTP 栈、持久化、剪贴板、托盘/通知、单实例、深链、ffmpeg |
| 平台专属，明确降级 | ~15% | 见 §3 降级清单 |

## 3. 范围与非目标

### 范围内
- HTTP/HTTPS 分段多线程下载、断点续传、失败重试、Basic+Digest 认证、手动代理
- 下载队列、并发上限（默认 3）、速度限制、计划任务（定时启停）
- 完整 UI（对照 XDM.Wpf.UI 的 22 个对话框）+ 中英文国际化 + 深浅色主题
- 剪贴板 URL 监视（`pasteboard.on('update')`）
- 后台常驻下载、系统通知进度、文件保存到用户选择目录
- 浏览器集成：8597 回环桥（8 路由）+ XDM 官方扩展直接复用（含下载接管，视 Phase 0 实测）
- HLS 流媒体下载（不含解密——对等原版行为）
- DASH 流媒体 + ffmpeg remux 合并（OpenHarmony 官方 FFmpeg n6.0）
- FTP（可选，可降级）

### 明确降级（约 15%，交付报告中逐条声明）
1. yt-dlp 粘贴页面链接探测（视频向导仅保留浏览器嗅探分支）
2. 系统代理自动检测（WPAD/PAC/IE）——仅保留手动代理配置
3. NTLM/Negotiate 认证（Basic 原生 + Digest 手写）
4. GitHub Releases 自动更新（鸿蒙走应用市场模式）
5. 下载完成后关机 / 自定义命令 / 杀毒扫描
6. 保持 PC 唤醒（SetThreadExecutionState）
7. MSIX 打包机制、Chrome Native Messaging 协议（扩展实际不需要）
8. TLS 证书错误放行（原版全放行，鸿蒙不可设；自签证书站点将失败）
9. 开机自启（视鸿蒙 API 调研结论，可降）

## 4. 关键调研证据（详见风险报告）

| 事实 | 来源 |
|---|---|
| 鸿蒙电脑华为浏览器支持开发者模式加载解压扩展 | 华为官方支持文档 consumer.huawei.com/cn/support/content/zh-cn16082289/（HarmonyOS 5.0+，笔记本） |
| OpenHarmony SIG 官方 FFmpeg n6.0 适配，hap 包集成 | gitcode.com/openharmony-sig/tpc_c_cplusplus（原 gitee 仓库已归档迁移） |
| 剪贴板变更订阅 `on('update')` 为公开 API（API 7+） | OpenHarmony 官方文档 js-apis-pasteboard |
| 扩展 ↔ 应用通信 = `http://127.0.0.1:8597` HTTP 轮询（非 Native Messaging） | 源码 chrome-extension/connector.js |
| XDM 2023 = C#/.NET（README 的 Maven 说明是 2018 经典版遗留） | 源码 app/XDM/XDM_CoreFx.sln |
| 原版 HLS 引擎不解密（EXT-X-KEY 只解析不使用） | 源码 MediaParser/Hls/HlsParser.cs |
| ffmpeg 仅 3 种调用（remux 合并/弃用 concat/转 MP3） | 源码 Downloader/MediaProcessor/FFmpegMediaProcessor.cs |
| yt-dlp 仅做元数据探测（`-J`），不做下载 | 源码 YDLWrapper/YDLProcess.cs |

## 5. 目标工程结构

```
XdmHarmony/
├── entry/src/main/
│   ├── module.json5              # 权限：INTERNET、KEEP_BACKGROUND_RUNNING；skills 深链
│   ├── resources/                # base + zh_CN + en_US string.json（对照 XDM Lang/*.txt）
│   └── ets/
│       ├── entryability/EntryAbility.ets
│       ├── pages/                # Index(主列表)/NewDownload/Settings/VideoCapture/Queue/Scheduler...
│       ├── components/DownloadListItem.ets
│       ├── model/DownloadRecord.ets      # @Observed 数据模型
│       └── core/
│           ├── engine/DownloadManager.ets   # 队列/调度（对照 QueueManager/Scheduler）
│           ├── engine/PieceGrabber.ets      # 动态分裂算法（对照 PieceGrabber.cs）
│           ├── engine/SegmentWorker.ets     # @Concurrent TaskPool
│           ├── net/HttpClient.ets           # 对照 DotNetHttpClient
│           ├── adaptive/HlsDownloader.ets   # 对照 HlsParser + MultiSourceHLSDownloader
│           ├── adaptive/DashDownloader.ets  # MpdParser（@ohos.util.xml）
│           ├── media/MediaProcessorNapi.ets # ffmpeg remux/mp3 最小命令面
│           ├── db/DownloadStore.ets         # RelationalStore（对照 SchemaInitializer）
│           ├── clipboard/ClipboardWatcher.ets
│           ├── notify/ProgressNotifier.ets
│           └── bridge/BridgeServer.ets      # 8597 八路由桥
├── extension/                    # 复用 XDM chrome-extension/（MV3，GPL 兼容）
├── libc/                         # ffmpeg n6.0 NAPI 产物
└── docs/                         # 本目录：计划与风险文档
```

### 对照规格书（源码位置索引）

| 领域 | 参考源（resourses/xdm/app/XDM/ 下） |
|---|---|
| 分段引擎 | XDM.Core/Downloader/Progressive/（HTTPDownloaderBase 21K、PieceGrabber 18.5K） |
| HLS/DASH | XDM.Core/Downloader/Adaptive/ + XDM.Core/MediaParser/ |
| ffmpeg 调用 | XDM.Core/Downloader/MediaProcessor/FFmpegMediaProcessor.cs |
| HTTP 客户端参考模型 | XDM.Core/Clients/Http/DotNetHttpClient.cs（net6 跨平台版） |
| 桥协议规格书 | XDM.Core/BrowserMonitoring/IpcHttpMessageProcessor.cs + HttpServer/ |
| 嗅探规则 | XDM.Core/BrowserMonitoring/VideoUrlHelper.cs（39.6K）+ chrome-extension/request-watcher.js |
| 配置键全表 | XDM.Core/Config.cs（44 键） |
| UI 接口契约 | XDM.Core/UI/I*View（30+ 接口 + 平台无关控制器） |
| 界面参照 | XDM.Wpf.UI/Dialogs/（22 个对话框） |

## 6. 关键技术决策

1. **下载引擎（ArkTS 主线，不用 C++ NAPI 写引擎）**：性能瓶颈在网络 IO；TaskPool 并行分段够用；AI agent 对 ArkTS 迭代验证最快。Phase 2 实测吞吐不足再评估 NAPI（预案非主线）。
2. **线程模型重构**：原版每分片裸 Thread + 阻塞读 + ReaderWriterLockSlim → SegmentWorker 走 TaskPool；`requestInStream` 的 `dataReceive` 事件流替代阻塞读；pieces 字典由主线程单点管理（消除锁）；限速沿用"睡眠补偿"数学但改异步 sleep。
3. **分段算法精确翻译**：动态分裂（启动单 Piece `Range:0-` 探测 → 206 则 resumable → 找最大剩余分片对半分裂）+ 相邻分片吸收复用连接；强制 `Accept-Encoding: identity`；无 ETag/If-Range（仅 Content-Length 校验）——对等原版。
4. **分片落盘**：与原版同构——每分片独立临时文件 + 追加写 + 完成后顺序拼接；进度持久化 JSON 化（替代二进制 chunks.db）。
5. **浏览器集成**：BridgeServer 复刻 8597 八路由（`/sync /media /download /vid /clear /tab-update /link /args`），`/sync` 响应配置字段逐一对照（含响应头剥离规则）；扩展直接复用（8597 地址不变）；接管依赖 `chrome.downloads.onDeterminingFilename`（Phase 0 实测点）；register.html 自定义协议注册流程评估后预计可省略；拉起应用改深链（可选 UX）。
6. **HLS**：对照 HlsParser（EXT-X-STREAM-INF/BYTERANGE/MAP/MEDIA-SEQUENCE）+ chunk 区间认领调度；加密流提示不支持（对等原版）；AES-128 解密列为可选增强（cryptoFramework 现成）。
7. **DASH**：MpdParser 用 `@ohos.util.xml` 重写；拒绝 dynamic/ContentProtection（对等原版）；SegmentBase/List/Template 三种寻址 + Timeline 展开 + `$Number$/$Time$/$RepresentationID$/$Bandwidth$` 模板变量（含补零）；产出 video×audio 笛卡尔组合供 UI 选择。
8. **ffmpeg**：官方 n6.0 NAPI 集成，封装面仅 remux（`-acodec copy -vcodec copy`）+ 转 MP3（libmp3lame）；合并失败降级 .mkv 容器（对照原版）。
9. **HTTP 客户端**：以 DotNetHttpClient 为参考模型；206 强校验；重定向后回写最终 URL；Cookie 原始串注入；超时 30s / MaxRetry 10 / RetryDelay 10s（对照 Config 默认值）。
10. **存储**：downloads 表对照 SchemaInitializer 建表（RelationalStore）；配置对照 Config 44 键存 preferences；下载状态 JSON（无需兼容原二进制格式）。
11. **UI**：按 XDM.Core/UI 的 I*View 接口契约实现 ArkUI 版（"第三平台 UI"——WPF/Gtk 双实现已证明可插拔）；设置页覆盖全部配置键（裁剪降级项）；`@Observed`+`@ObjectLink` 驱动列表进度；LazyForEach + IDataSource；Navigation/NavDestination。

## 7. 执行序列（八阶段）

### Phase 0：环境与五项技术验证（1 周）
1. DevEco Studio + PC 模拟器启动（deveco-cli）；工程基座修正（deviceTypes 补 2in1、补 ohos.permission.INTERNET）与探针基建（单元 U0.1，见 UNIT_CATALOG.md）
2. **浏览器扩展完整栈实测**（用真实 XDM MV3 扩展）：加载 → webRequest(onSendHeaders/onHeadersReceived+extraHeaders) → cookies.getAll → **downloads.onDeterminingFilename+cancel（接管关键）** → contextMenus → alarms → tabs；demo HAP 绑 8597 应答 /sync 测连通
3. **HTTP 能力验证**：requestInStream 流式 + Range(0-)/206 判定 + identity 编码 + 8 并发连接 + 重定向/Cookie 注入 + 超时控制
4. **ffmpeg spike**：gitcode tpc_c_cplusplus n6.0 产物按 hap_integrate.md 集成，NAPI 跑通 remux + libmp3lame
5. 模拟器是否预装华为浏览器；托盘 API、fs 随机写、rcp 备选调研
6. git 里程碑基线；补齐 Wpf.UI/Gtk.UI 行数与 VideoUrlHelper 规则清单
- **验收**：五项各有明确结论（GO 项全绿或退化路径激活）

### Phase 1：工程骨架 + 单线程下载（1 周）
DownloadRecord 模型 + downloads 表；HttpClient 单线程流式下载；主列表 + 新建对话框。
- **验收**：URL 完整下载到沙箱；实时进度；重启历史可见

### Phase 2：分段并发 + 断点续传（1.5 周，对照 Progressive/）
PieceGrabber 动态分裂逐行翻译；TaskPool 并行；分片临时文件 + 拼接；进度 JSON 持久化；暂停/恢复。
- **验收**：大文件吞吐显著优于单线程；杀进程重启续传（测试源需支持 Range：`npx http-server`，Python SimpleHTTPServer 不支持）

### Phase 3：队列/调度/限速/重试（1 周）
并发上限 3 + 排队优先级；异步限速；固定间隔重试（MaxRetry=10/RetryDelay=10s，源码核实无指数退避）；Scheduler 定时启停。
- **验收**：排队正确；限速实测吻合；断网恢复

### Phase 4：UI 对齐 + 国际化（1.5 周，对照 Wpf.UI + UI 契约）
主窗口（双列表/分类树/搜索/工具栏）；22 对话框按契约实现（降级项隐藏）；设置页全配置键；zh_CN + en_US；深浅色。
- **验收**：对照 XDM 走查表逐项勾选；语言/主题切换生效

### Phase 5：系统集成（1 周）
DATA_TRANSFER 长时任务 + 常驻通知；ClipboardWatcher（on('update')）；DocumentViewPicker 保存目录；完成通知；（视调研）托盘/自启。
- **验收**：关窗后台继续下载；复制直链弹提示；文件入用户目录

### Phase 6：浏览器集成 + HLS（2 周）
1. BridgeServer 八路由（对照 IpcHttpMessageProcessor 逐端点）
2. extension/ 复用 + 按 Phase 0 结论适配；接管流程或退化（仅嗅探 + popup 手动下载）
3. 嗅探规则服务端对照 VideoUrlHelper
4. 视频捕获窗口 + videoList 管理（对照 MediaCaptureWindow/VideoTracker）
5. HlsDownloader（BYTERANGE/MAP/双轨 concat + remux + .mkv 降级）
- **验收**：浏览器播视频 → 扩展弹窗 → 应用带 cookies 完整下载；公共 HLS 测试流可播

### Phase 7：ffmpeg/DASH + 收尾（1.5 周）
MediaProcessorNapi（remux/mp3）；DashDownloader；FTP（可选可砍）；签名打包（deveco-cli）；交付文档（含 15% 降级清单与原因）。
- **验收**：DASH 测试流多轨合并可播；课程交付

## 8. 验证矩阵

| 层级 | 方法 | 频率 |
|---|---|---|
| 静态检查 | hvigor 编译期 ArkTS 严格子集检查（主）；codelinter 辅助（性能/安全规则，实测不含 ArkTS 语法规则） | 每功能点 |
| 编译 | hvigor 构建，零 error 零新 warning | 每功能点 |
| 运行 | PC 模拟器安装运行，无崩溃/jscrash | 每 Phase |
| 功能 | 各 Phase 验收清单（Range 本地服务器 + 公网大文件 + HLS/DASH 公共测试流） | 每 Phase |
| 对照 | 与 XDM 2023 原版功能走查表比对 | Phase 4/7 |
| 扩展桥 | Phase 0 六项 API 实测 + Phase 6 端到端（含 cookies/接管） | 两次 |
| 原生库 | ffmpeg spike（P0）+ remux/mp3 单元验证（P7） | 两次 |
| 保真度 | 引擎行为对照源码单测（分裂/续传/限速算法） | Phase 2-3 |
| 性能 | 吞吐/内存记录无回归 | Phase 2 起 |

所有结论标注验证环境（真机/模拟器）；真机全程可用，探针默认在真机运行，Phase 7 前再做一次整机回归（重点：扩展、后台、通知）。

## 9. AI Agent 执行工作流（单元粒度，全程 AI）

> 单元划分见 [UNIT_CATALOG.md](./UNIT_CATALOG.md)（Phase 0~7 共 24 单元）；执行工具为 ZCode 工作流 `xdm-migrate`（源码研究 → 模块设计 → ArkTS 编码 → 对照审查，含 hvigor 门禁与返修循环，外加独立复核与单元报告）。

1. 每单元一次工作流运行：研究员产出源码行为事实与 API 对应 → 设计师产出设计书（含探针设计）落 docs/design/ → 编码员实现 → 对照审查员核对保真度 → 独立复核换人挑错 → 报告员产出单元迁移报告
2. 对照 `resourses/xdm` 对应模块**读逻辑、不抄语法**（扩展 JS 直接复制改造），用 ArkTS 重写
3. 门禁：每轮返修后全量 hvigor 构建（ArkTS 严格子集在编译期强制；codelinter 仅辅助）；AI 每单元完成即 git 提交（单元粒度回滚点），人工验收在 Phase 级（真机试用+走查后 `git tag phase-N`）
4. 运行时行为验证走探针：工作流生成探针页 + PROBE.md + 预期表（规范见 [PROBE_SPEC.md](./PROBE_SPEC.md)），人工在模拟器运行后回贴日志，`xdm-probe-verify` 工作流逐步骤判定并分流返修
5. 模拟器/设备管理用 deveco-cli 技能；每 Phase 验收通过后 `git tag phase-N`

## 10. 回滚策略

- 工程独立目录 + 独立 git 仓库；`resourses/xdm`、`libc/` 只读不参与业务编译
- 每 Phase tag（`phase-0` … `phase-7`）；任一阶段失败 `git reset` 回上一 tag
- 浏览器集成 / HLS / DASH+ffmpeg / FTP 四功能面互不依赖，任意裁剪不动其他
- 里程碑天然递增：Phase 5 末（约 5-6 周）即有核心可交付版
- 最坏情况：删除 `XdmHarmony/` 目录即完全清理

## 11. 许可证声明

XDM 为 GPL-2.0。对照源码的重写与扩展 JS 复用均属衍生作品，**分发必须遵循 GPL-2.0**（课程内部使用不受影响）。交付报告中需明确声明。
