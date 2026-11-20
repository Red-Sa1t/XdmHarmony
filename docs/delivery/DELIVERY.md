# XDM 鸿蒙迁移 · 交付总结（U7.3，Phase 7 收官）

- 单元：U7.3 签名打包+交付文档（UNIT_CATALOG.md:89 Phase 7 第 3 单元，M7 交付）
- 交付日期：2026-10-11
- 目标工程：D:/git/HarmonyPC/XdmHarmony（HarmonyOS PC，targetSdk 6.1.1(24) / compatibleSdk 6.1.0(23)，bundle `com.neuohos.xdm`（2026-10-12 由 com.example.xdmharmony 更名上架包名），ArkTS 严格子集）
- 对照源码：D:/git/HarmonyPC/resourses/xdm（XDM 2023，subhra74/xdm，C#/.NET，GPL-2.0，全程只读）
- 证据约定：本文凡标注「本会话实测」的数字、哈希、行号均为 2026-10-11 交付会话亲自执行/读取所得；引自既有文档者注明出处。本单元自身为零代码/零配置/零探针改动的交付类单元，全部差异是既有登记的**正式汇总**，不产生新的源码行为差异。

---

## A. 迁移总结

### A.1 总览

XDM 2023（C#/.NET，WPF+Gtk# 双 UI 共享 XDM.Core）已按 MIGRATION_PLAN §6 的十一条技术决策以 ArkTS/ArkUI 跨语言重写于鸿蒙 PC 形态：**24/24 功能单元全部落地**（U7.1 于 a98e2fc 收官迁移本体），累计 **642 条 Hypium 单测**（2026-10-15 IR-F1/F1 修复批次 +2 回归后），最近一轮 run-hypium 真值门禁全绿 `ok:true, 642/642`（2026-10-18 修复后终版，见 F.3；此前 2026-10-15 同口径及 640 口径三轮全绿归档）。交付形态为签名 release HAP（E 节；2026-10-17 完成新包名重签+release 重建+真机装包启动冒烟）。**2026-10-18 探针会话#2 真机执行**：自动化可跑的 12 个待验单元全部判定、另 4 个引擎回归单元复跑（C.4），由此暴露并修复 5 项产品缺陷（慢源零字节根因、长时任务 401、清单重定向、rcp 头序、rcp 队列溢出丢字节，D 档 1），修复后门禁 642/642 全绿、主机套件 599/0、release 重建并真机冒烟，2026-10-19 与用户协同完成人工走查（P5-U2/P4-U1/P4-U2/P6-U2/P0-U4 播放），再修 2 项（完成后拷贝、捕获页增量渲染），E 节第 9 条为终局登记；仅 OPT-1 深色观测（随 UI 统一重写）与 P7-U1 公共流可播待定（C.4）。**2026-11-06**：HLS/DASH 业务外壳落地，P7-U1 公共流随之 PASS（见下方更正与闭环注记）。

功能面覆盖：HTTP/HTTPS 分段多线程下载（动态分裂/吸收）、断点续传、失败重试、Basic+Digest 认证、手动代理、队列调度（并发上限 3）、限速、定时启停、完整 UI（主窗口+对话框包+全配置键设置页+中英 i18n+深浅色）、后台长时任务+常驻通知、剪贴板监视、保存目录、浏览器扩展集成（8597 八路由桥 + MV3 扩展复用 + 下载接管）、HLS、DASH+ffmpeg remux/mp3。

> **2026-11-06 更正（真机端到端验收发现）**：HLS/DASH 的**引擎层**（清单解析、计划、E1~E4 下载与运行控制、F 装配、Native remux）已真机验证可用（P6-U4/U5/U6、P7-U1-F/P/C、P0-U4），但**业务外壳未接线**——u6-4 设计的外层集成 O2/O3/O7（HlsDownloader/DashDownloader 业务类、DownloadManager 工厂、最终沙箱发布、Store 完成回执、续传与 UI 链路）从未落地：捕获页对 HLS/DASH/双源/YouTube 分轨条目点下载，Index.openNextInbox 弹「This video format is not supported yet.」。即**用户当前无法在应用内下载 HLS/DASH**。见 D 档 2。上文与 T2 表中「HlsDownloader」「DashDownloader（迁移本体收官）」指引擎单元交付，不代表端到端可用。

> **2026-11-06 闭环（同日）**：业务外壳已落地并真机端到端验收——HLS 捕获接线（此前识别后只记日志）、来源描述持久化（加性旁表 `download_adaptive_source`）、`AdaptiveDownloader` 业务类、DownloadManager 工厂、Index 走新建对话框；HLS 单轨/双轨 remux、DASH、强杀重启续传、应用内暂停续传、**公共 DASH（Akamai bbb_30fps 180p）与公共 HLS（Mux x36xhzz 240p）**全部以解码比对判 PASS。真机验收另暴露并修复 2 项（设备 SDK URL 基址解析不符合 RFC 3986 致 BaseURL `./` 的 DASH 全部 404；分片 4xx 不重试与源不一致）。未做部分（运行中前缀持久化 O5b、POST 清单发现、每来源认证/代理、分片重定向、outbox 完成回执）如实登记于 D 档 2。报告：[u6-4-outer-integration-REPORT](../design/u6-4-outer-integration-REPORT.md)；证据：[e2e-adaptive-2026-11-06.log](../probe/e2e-adaptive-2026-11-06.log)。

### A.2 里程碑（T1 表）

按 UNIT_CATALOG.md:15 v2 关键路径划分填写；git 提交哈希经本会话 `git log --oneline --reverse`（36 提交）实测。

| 里程碑 | 划分（UNIT_CATALOG v2:15） | 达成单元 | git 提交 | 状态 |
|---|---|---|---|---|
| M1 真机真下载（进度+续传雏形） | U1.2 | U1.2 | 3591cd4 | ✅ 达成 |
| M2 断点续传 | U2.2 | U2.2 | 3c2fb22 | ✅ 达成 |
| M3 队列/限速 | U3.1 → U3.2 | U3.1+U3.2 | e9ee69e、3af73ed | ✅ 达成 |
| M4 完整 UI | U4.1~U4.3 | U4.1~U4.3 | 2dcf823、1047748、76a6e7d | ✅ 达成 |
| M5 核心可交付 | U5.1 → U5.2 | U5.1+U5.2 | 9874c9a、2cf4234 | ✅ 达成 |
| M6 浏览器接管+HLS | U0.3 → U6.1~U6.4（U0.4 解除 ffmpeg 依赖） | U0.3+U6.1~U6.4 | cd060a3、33e04e2、4c02cb1 | ✅ 达成 |
| M6 收官功能（DASH） | （随 Phase 7 序列） | U7.1 | a98e2fc | ✅ 达成 |
| M7 交付 | U7.1~U7.3 | 本单元（U7.3） | —（见注） | ✅ 本单元达成；**git tag 待人工补打** |

> 注 1：a98e2fc 提交信息自称「M6 收官」系措辞漂移——按 UNIT_CATALOG v2 划分，M6=浏览器接管+HLS（U6.4 止），DASH（U7.1）属 Phase 7/M7 序列；本表按 v2 校正口径登记。
> 注 2：git tag 至今为空（本会话 `git tag -l` 实测）。UNIT_CATALOG v2:19 规定 tag 是人工 Phase 级验收动作，且探针会话#2（15 项）尚未执行，故 M7 的 tag 不由本单元补打（openQuestion #1）。

### A.3 24 单元全景（T2 表）

单元名与主题按 UNIT_CATALOG 各 Phase 表逐行抄录；单测数从各单元提交信息与 REPORT 回填；REPORT 链接 docs/design/ 下对应文件。

| # | 单元 | 主题 | 单测（新增/累计，提交口径） | 探针手册 / 状态 | REPORT |
|---|---|---|---|---|---|
| 1 | U0.1 | 工程基座修正+探针基建 | —（脚手架单元，0） | P0-U0｜会话#1 观测全绿 | [u0-1-foundation-probe-infra-REPORT](../design/u0-1-foundation-probe-infra-REPORT.md) |
| 2 | U0.2 | HTTP 能力探针 | +16 | P0-U2｜会话#1 全绿——**http 主栈定案** | [u0-2-http-capability-probe-REPORT](../design/u0-2-http-capability-probe-REPORT.md) |
| 3 | U0.3 | 扩展桥 8597 服务端 | 累计 293（cd060a3） | P0-U3｜会话#1 桥 25/25 对账全绿 | [u0-3-extension-bridge-server-REPORT](../design/u0-3-extension-bridge-server-REPORT.md) |
| 4 | U0.4 | ffmpeg spike（人工主导，含 U7.2 封装面） | 非 Hypium：native 30/30 + ASan/UBSan 25/25 | P0-U4｜会话#2 待跑 | [u0-4-native-media-REPORT](../design/u0-4-native-media-REPORT.md) |
| 5 | U0.5 | 平台辅助调研（去流程化） | —（纯调研） | —（无探针，[A]+[H]） | [U0.5-PLATFORM-RESEARCH](../research/U0.5-PLATFORM-RESEARCH.md) |
| 6 | U1.1 | 数据模型+存储+配置骨架 | +17 | P1-U1｜会话#1 全绿（S8/S9 两段式重启持久） | [u1-1-data-model-store-config-REPORT](../design/u1-1-data-model-store-config-REPORT.md) |
| 7 | U1.2 | 单线程下载+主列表+新建对话框 | +38（M1） | P1-U2｜会话#1 S5 分歧（business-code，功能无损） | [u1-2-single-thread-download-list-dialog-REPORT](../design/u1-2-single-thread-download-list-dialog-REPORT.md) |
| 8 | U2.1 | PieceGrabber+SegmentWorker 并发 | +14（分片算法） | P2-U1｜会话#1 全绿（8 路并发零重叠零缺口） | [u2-1-piecegrabber-segmentworker-REPORT](../design/u2-1-piecegrabber-segmentworker-REPORT.md) |
| 9 | U2.2 | 分片落盘+断点续传+进度持久化 | +24（chunks） | P2-U2｜会话#1 FAIL(高)→a39ba92 返修**待复验**（C.2） | [u2-2-resume-state-persist-REPORT](../design/u2-2-resume-state-persist-REPORT.md) |
| 10 | U2.3 | 引擎保真度对照单测收口 | 117 实跑全绿（+22） | —（纯单测单元）；另产 [保真度矩阵 46 项](../design/u2-3-fidelity-matrix.md)（✅39 ⚖️5 ⛔2） | [u2-3-engine-fidelity-REPORT](../design/u2-3-engine-fidelity-REPORT.md) |
| 11 | U3.1 | 队列调度+并发上限 | +10（调度） | P3-U1｜会话#1 全绿（上限/FIFO/轮换/取消） | [u3-1-download-manager-queue-REPORT](../design/u3-1-download-manager-queue-REPORT.md) |
| 12 | U3.2 | 限速+重试+定时调度 | +26（累计 153） | P3-U2｜会话#1 全绿（917.8KB/s 落窗+分钟边界停启） | [u3-2-speed-limit-retry-scheduler-REPORT](../design/u3-2-speed-limit-retry-scheduler-REPORT.md) |
| 13 | U4.1 | 主窗口框架 | +35（四纯函数层） | P4-U1｜会话#1 进行中（A/B 段走查完成） | [u4-1-main-window-framework-REPORT](../design/u4-1-main-window-framework-REPORT.md) |
| 14 | U4.2 | 对话框包 | 累计 207 | P4-U2｜会话#2 待跑 | [u4-2-dialog-package-REPORT](../design/u4-2-dialog-package-REPORT.md) |
| 15 | U4.3 | 设置页全配置键+i18n+主题（M4） | +22（累计 229） | P4-U3｜会话#1 全绿（写回-读回-重启持久） | [u4-3-settings-i18n-theme-REPORT](../design/u4-3-settings-i18n-theme-REPORT.md) |
| 16 | U5.1 | 后台长时任务+通知 | +12（累计 241） | P5-U1｜会话#2 待跑 | [u5-1-background-task-notification-REPORT](../design/u5-1-background-task-notification-REPORT.md) |
| 17 | U5.2 | 剪贴板监视+保存目录（M5） | +16（累计 257） | P5-U2｜会话#2 待跑 | [u5-2-clipboard-save-dir-REPORT](../design/u5-2-clipboard-save-dir-REPORT.md) |
| 18 | U6.1 | BridgeServer 八路由完整版 | +67（累计 360） | P6-U1｜会话#2 待跑（Node 流量模拟自验 10/10 已过） | [u6-1-bridge-eight-routes-REPORT](../design/u6-1-bridge-eight-routes-REPORT.md) |
| 19 | U6.2 | 嗅探规则+视频捕获 | +46 Hypium；另 Node 用例表 65 例全绿 | P6-U2｜会话#2 待跑 | [u6-2-sniff-rule-chain-video-capture-REPORT](../design/u6-2-sniff-rule-chain-video-capture-REPORT.md) |
| 20 | U6.3 | 扩展复用+端到端接管 | 批次内门禁 462/462（原 432+HLS 解析 30） | P6-U3-link-refresh｜会话#2 待跑 | [u6-3-browser-takeover-REPORT](../design/u6-3-browser-takeover-REPORT.md) |
| 21 | U6.4 | HlsDownloader | 批次内门禁 501/501 → 569/569 | P6-U4-adaptive-{foundation,pipeline,controller}｜会话#2 待跑 | [u6-4-hls-REPORT](../design/u6-4-hls-REPORT.md) |
| 22 | U7.1 | DashDownloader（迁移本体收官） | +52（累计 640，两份 run-hypium verdict 全绿） | P7-U1-dash-{foundation,pipeline,controller,dash}｜**已生成待人工回贴**（u7-1 报告原话） | [u7-1-dash-REPORT](../design/u7-1-dash-REPORT.md) |
| 23 | U7.2 | MediaProcessorNapi | 与 U0.4 同报告（native 用例承载） | P0-U4 承载｜会话#2 待跑 | [u0-4-native-media-REPORT](../design/u0-4-native-media-REPORT.md) |
| 24 | U7.3 | 签名打包+交付文档（本单元） | 0 新增（回归基线 640 保持，F 节） | 无探针（UNIT_CATALOG.md:104：Phase 7 整机回归用正式应用） | 本文档 |

> 注：累计数为各单元提交信息/报告当时口径。早期单元（U0.2~U2.2）存在声明与仓库实测的计数口径差（U2.3 报告实测：提交声明「38 条」实为 95 条），不影响最终结论——**最终单测真值一律以 run-hypium verdict 642/642 为准**（F 节；2026-10-15 起 642 口径，此前历轮为 640 口径）。

### A.4 GPL-2.0 许可声明（四要素，硬性必备）

1. **衍生作品定性**：本工程是 XDM 2023（subhra74/xdm，GPL-2.0）的**衍生作品**——对照源码以 ArkTS 跨语言重写（MIGRATION_PLAN §11「对照源码的重写」）+ `extension/` 下 chrome-extension MV3 扩展的复用改造（U6.3 落地）。
2. **分发义务**：依 GPL-2.0 分发本工程（含 HAP 二进制形态）时，**必须遵循 GPL-2.0 同许可证并提供对应源码**；本仓库即对应源码。课程内部教学使用不受影响。
3. **源仓库署名**：对照源码仓库为 resourses/xdm（subhra74/xdm），其 `LICENSE` 文件为 GNU GPL v2 全文（本会话 head 实测：`GNU GENERAL PUBLIC LICENSE / Version 2, June 1991`）。
4. **extension/ 复用说明**：`extension/LICENSE` 为随扩展复制的同一 GPL-2.0 全文（本会话实测在位），扩展目录的分发链自洽；工程根目录 LICENSE 已于 2026-11-19 上架整改补齐（GPL-2.0 全文，取自 resourses/xdm/LICENSE；openQuestion #2 闭环）；应用内「关于」同步展示版本、GPL-2.0 无担保声明、上游致谢与源码地址。

---

## B. 降级清单

### B.1 范围级降级主表（9 项，对照 MIGRATION_PLAN.md:45-55 §3 逐条承载）

合计约 15% 功能面。源码锚点经本会话 grep 实测定位（逐条见「源码对应位置」列）。

| # | 降级项 | 降级原因域 | 源码对应位置 | 交付现状 |
|---|---|---|---|---|
| 1 | yt-dlp 粘贴页面链接探测（视频向导仅保留浏览器嗅探分支） | 鸿蒙无该进程模型/运行时（无 .NET 进程拉起外部 yt-dlp 的等价能力） | app/XDM/YDLWrapper/YDLProcess.cs（MIGRATION_PLAN §4：仅 `-J` 元数据探测，不做下载） | 已降级；视频捕获走浏览器嗅探+8597 桥（U6.2/U6.3） |
| 2 | 系统代理自动检测（WPAD/PAC/IE），仅保留手动代理 | 平台无对应检测 API；.NET 侧系统代理解析随 WinInet/运行时自带 | app/XDM/XDM.Core/Clients/Http/ProxyHelper.cs:13（`GetProxy(ProxyInfo?)`）+ Config.cs:142（`Proxy` 键） | 已降级；手动代理配置面保留 |
| 3 | NTLM/Negotiate 认证（保留 Basic 原生 + Digest 手写） | 无系统凭据栈；源走 WinInet 系统认证 | app/XDM/XDM.Core/Clients/Http/WinInetClient.cs:1122（NTLM/MSN 注释）、:1612（Digest 选项） | 已降级；Basic 原生 + Digest 手写已落地 |
| 4 | GitHub Releases 自动更新 | 鸿蒙走应用市场模式 | app/XDM/XDM.Core/AppController.cs、IPlatformUIService.cs（grep `github.com\|updater\|CheckUpdate` 命中） | 已降级 |
| 5 | 下载完成后关机 / 自定义命令 / 杀毒扫描 | 沙箱权限模型不放开 | app/XDM/XDM.Core/Config.cs、ApplicationCore.cs（grep `Shutdown\|antivirus\|CustomCommand` 命中） | 已降级 |
| 6 | 保持 PC 唤醒（SetThreadExecutionState） | 无公开对应 API | app/XDM/XDM.Core/Util/PlatformHelper.cs（grep 实测命中） | 已降级 |
| 7 | MSIX 打包 + Chrome Native Messaging 协议 | 形态不同；扩展实际走 8597 HTTP（chrome-extension/connector.js，MIGRATION_PLAN §4 已证非 Native Messaging） | app/XDM/NativeMessaging/IpcClient.cs（grep 实测命中） | 已降级；extension/ 直接复用，8597 桥由 U0.3/U6.1 落地 |
| 8 | TLS 证书错误放行（原版全放行） | 鸿蒙网络栈不可设；自签证书站点将失败 | app/XDM/XDM.Wpf.UI/App.xaml.cs（`ServerCertificateValidationCallback`，grep 实测命中） | 已降级；此差异用户可感知（自签证书站点下载失败） |
| 9 | 开机自启 | 无 startupTask 扩展——module.json5 无该项（F9 实读），已实际落定降级 | app/XDM/XDM.Core/Util/PlatformHelper.cs、Config.cs（grep `autostart` 命中） | 已降级 |

### B.2 实现级差异补充表（与 B.1 分层，不混表）

素材=各 REPORT 行为对照表的 low/medium 有意差异行 + §7 遗留节，**逐单元一行引用不复制明细**（明细一律见对应报告）。状态为「开放」的项归入 D 节三档账。

| 单元 | 差异/遗留摘要（一行引用） | 等级 | 状态 |
|---|---|---|---|
| U0.1 | 探针页脚手架为迁移新增（源无对应物）；deprecated pasteboard API、设计书笔误等 | low | 见报告 ⑦（D.3） |
| U0.2 | 探针结论「http 栈」为平台选型记录；无界 endGate 教训转产品侧硬约束（U1.2 END_GATE 已改空闲超时对冲） | medium→对冲 | 已对冲（3591cd4）+ 探针全绿 |
| U0.3 | 桥服务端为 ArkTS 字节级增量解析重写；Content-Length 溢出护栏/空状态行/用例计数注释三 low；端口失配无 UI 提示（设计书 §0-3 有意拍板） | low | 开放（D.3） |
| U0.4/U7.2 | ffmpeg NAPI 封装面=remux+转 MP3 最小命令面；两 ABI 落地 | — | **目标设备运行未验收（U0.4 尚无运行 GO）**，归属会话#2 |
| U1.1 | add() completed 强制防御为超源护栏；WITHOUT ROWID 降级分支未实测；Config flush 异步窗口 | low | 部分已修（a9d98fd），余见报告 ⑦ |
| U1.2 | 恢复 Range 用 open-ended `bytes=N-`（**有意偏离**源闭区间）；SessionExpired(9) 未复刻；重试预算/END_GATE 两项 | low/medium | 两项已随 3591cd4 主会话修复；其余见报告 ⑦ |
| U2.1 | 探测回执跨通道次序假设（复核F1 medium）+ 缺 Content-Range 边缘 206 误判等 low | medium/low | 复核F1 已随 b6b215d 主会话补修；low 见报告 ⑦ |
| U2.2 | 状态文件在而分片文件被删→sparse 零洞（源同病）；恢复 length=-1 片 NonResumable（源同貌） | low | 源同貌差异，登记接受（报告 ⑦） |
| U2.3 | 保真度矩阵 46 项（✅39 ⚖️5 ⛔2）；COLD-F1 小文件热修（跨红线授权 D25） | — | 已闭环（08cfc8a/e720b7a） |
| U3.1 | D9 DB 回声未接（排队取消仅内存态，manager 零 DB 写红线）；探针检查口径、死簿记等三 low | low | 开放（D.3） |
| U3.2 | 指数退避勘误（源实为固定间隔，MaxRetry=10/RetryDelay=10s 对齐）；探测派发限速注释偏差 | low | 开放（D.3） |
| U4.1 | 幽灵选中清理+走查项 11 文案两 medium；A3/A4/A5 视觉类三 low | medium/low | 两 medium 已闭环（2dcf823 主会话修复，Index.ets:899-902 注释实证）；low 开放 |
| U4.2 | 完成窗**串行补弹**（源为逐下载堆叠多窗——有意差异 D 系，components/ProgressWindowDialog.ets:402 注释自称）；INT-F5~F8、IR-F3/F4 low | medium/low | IR-F1 已闭环（D.1）；low 开放 |
| U4.3 | 常规页分类列表会话内不刷新（复核F1 medium）；R2-F3/F5 登记义务、注释语义等 low | medium/low | medium 已随 76a6e7d 主会话修复；low 开放 |
| U5.1 | apply/release IPC 交错窗口失同步（复核F1 medium）；瞬态误删等 low | medium/low | medium 已随 9874c9a 主会话修复；low 开放 |
| U5.2 | 排队守卫单方向（L1）、走查文案与源矛盾（L2）、OpenAction 落点（L3）、行数口径（L4）、FolderAlgo 点尾（L5）、探针 S1 永久置位（L6） | low×6 | 开放（D.3） |
| U6.1 | 桥下载暂不带浏览器 cookie（★4，U6.3 接通）+ pending 结构等七 low | low | 接通项已由 U6.3 消化；low 见报告 ⑦ |
| U6.2 | 双镜像口径交付（isMatchingRequest 八层规格件 + 分派链五锚真实现）；IR-F1 medium **已闭环**（2026-10-15 修码+2 回归，D.1）+ SHA-1 注释向量错误等约十 low | medium/low | IR-F1 已闭环（D.1，2026-10-15 批次）；low 开放（D.3） |
| U6.3 | 真实浏览器与设备验收未执行；「源差异与未验范围」节承载（批次报告形态） | — | 归属会话#2 |
| U6.4 | 冷审 IPv6 边缘最小修复；foundation r1 曾被严格门禁拒绝且未被事后修正（流程记录） | low | 登记于报告（D.3） |
| U7.1 | R5 登记性差异：单轨 DASH 只下 Segments[0]（源 quirk 1:1）、POST 清单延后（GET-only）、负数模板补零 sign+幅值、预算设界为源所无新增；XML 属性先序合并+Timeline 预算门两 medium | medium/low | 两 medium 已随 a98e2fc 闭环；low 见报告 ⑦ |

### B.3 环境适配差异（交付形态）

- **compatibleSdkVersion 6.1.0(23)**（build-profile.json5:23 实读）：真机 MateBook Pro HAD-W24 系统为 API 23，装 API 24 包被拒（code 9568297，PROBE-SESSION-ALL.md:77-78），探针会话#1 现场降级。**该钉值是交付可装性的前提，任何「升回 24」的改动都会破坏真机安装。**
- 签名材料落 build-profile.json5 本地路径（build-profile.json5:3-17，本会话实读）而非 AGC 云端分发。
- 混淆关闭（entry/build-profile.json5:14-28 `obfuscation.enable:false`，本会话实读）；开启需补规则文件并重验 native/反射面，收官阶段无收益只有风险。

---

## C. 探针验收状态（三段）

### C.1 会话#1 已跑 10/14（2026-10-03，真机 MateBook Pro HAD-W24 · API 23，因设备电量中止）

素材=docs/probe/PROBE-SESSION-ALL.md:84-92 与 probe-session-2026-10-03.log（本会话实读）。

| 探针 | 结果 | 要点 |
|---|---|---|
| P0-U0 / P4-U3 / P1-U1 / P0-U2 | 观测全绿 | HTTP 六项全过——**U0.2 http 主栈选型定案**；重启持久核心 S9 通过 |
| P1-U2 | S5 分歧 | worker 异步记账滞后 fd 写位置（pauseOffset=1MiB vs 内容文件 2MiB），功能无损，business-code 类 |
| P2-U1 | 观测全绿 | 8 路并发/零重叠零缺口；ratio=0.42（快源下分段吃亏，观测值回写计划） |
| P2-U2 | **FAIL（高）** | 引擎对慢滴流源（≥600ms/块）零字节静默失败：3 次 bytes=0- 探测后无分段请求（服务器日志实锤；40/80ms 正常、600/2500ms 失败） |
| P3-U1 / P3-U2 | 观测全绿 | 调度上限/FIFO/轮换/取消/全停 + 限速 917.8KB/s 落窗 + 分钟边界精确停启 |
| P0-U3 | 观测全绿 | 桥 25/25 与主机 curl 精确对账；R2-F1 畸形断连修复真机验证通过 |
| P4-U1 | 进行中 | A/B 段人工走查完成（项 14 未观测到：ms=80 完成太快——下次用 ms=2500 死源占槽再验）；探针 S1~S4+勾选未跑 |

### C.2 P2-U2 慢滴流源零字节（2026-10-18 根因修复并复验 PASS，见 C.4）

- 缺陷已随 **a39ba92** 返修（git log 实测）：HttpClient/HttpProtocol/PieceGrabber/SegmentWorker 核心返修 + S5 异步记账分歧收口 + 探针基建守卫修复 + HttpProtocol 用例 +20。
- 探针未重跑——**「已修待复验」属实**，整单元重跑归属会话#2。
- **2026-10-18 更正**：a39ba92 只修了生命周期（tests/host/README 原已注明「持续慢流失败未解决」），会话#2 复验仍零字节；插桩证实根因为 `requestInStream` 状态码要到整条流结束才结算 + `readTimeout` 被当总时限，修复后 S1~S4 全 PASS（D 档 1）。
- 会话#1 返修清单 5 项进度：1/2/3 已修（慢滴流、S5 记账、探针页徽标假象）；第 4 项（U0.3 三 low）仍开放（D.3）；第 5 项确认为非缺陷（进度窗堆叠=原版保真，ApplicationCore.cs:169/312 + showProgressWindow 默认 true）。

### C.3 会话#2 待跑 15 项清单

= 会话#1 剩 4 项 + 11 份新探针手册（docs/probe/ 目录 ls 实测：PROBE-u0-4 / u6-1 / u6-2 / u6-3-link-refresh / u6-4-adaptive-{foundation,pipeline,controller} / u7-1-dash-{foundation,pipeline,controller,dash} 共 11 份 + 同名 EXPECT json）：

| # | 待跑项 | # | 待跑项 |
|---|---|---|---|
| 1 | P4-U1 收尾（S1~S4+勾选；走查项 14 用 ms=2500 死源占槽） | 9 | P6-U4-adaptive-foundation |
| 2 | P4-U2（26 项人工走查） | 10 | P6-U4-adaptive-pipeline |
| 3 | P5-U1（后台存活，关窗等下载完→survived） | 11 | P6-U4-adaptive-controller |
| 4 | P5-U2（剪贴板+目录，READ_PASTEBOARD 授权） | 12 | P7-U1-dash-foundation |
| 5 | P0-U4（ffmpeg remux/mp3 真机） | 13 | P7-U1-dash-pipeline |
| 6 | P6-U1（八路由） | 14 | P7-U1-dash-controller |
| 7 | P6-U2（嗅探规则链） | 15 | P7-U1-dash（合并手册 17 步骤） |
| 8 | P6-U3-link-refresh（刷新链接） | — | — |

> U7.1 报告（u7-1-dash-REPORT.md:10）探针状态原话：「探针 P7-U1 已生成，待人工运行回贴日志」。真机整机回归（扩展/后台/通知）用正式应用承载，归属会话#2 人工验收（UNIT_CATALOG.md:104）。

### C.4 会话#2 结果（2026-10-18，真机 HAD-W24 · API 23）

完整判定表、修复说明与教训见 [PROBE-SESSION-ALL.md](../probe/PROBE-SESSION-ALL.md)「会话 #2 状态」；原始日志 [probe-session-2026-10-18.log](../probe/probe-session-2026-10-18.log)。

| 范围 | 结论 |
|---|---|
| P2-U2 / P0-U4 / P5-U1 / P6-U1 / P6-U2 / P6-U3 / P6-U4 / P6-U5 / P6-U6 / P7-U1-F / P7-U1-P | ✅ PASS（P6-U1、P7-U1-P 为按源语义修订 EXPECT 后通过；P6-U2、P7-U1-P S3 为修探针后通过） |
| P7-U1-C | ⚠️ PASS + S2 UNVERIFIED（探针时序局限，能力由 P6-U6 S2 覆盖） |
| 回归 P1-U2 / P2-U1 / P3-U1 / P3-U2 | ✅ 无回退；P2-U1 分段速比 0.42→1.98 |
| 人工走查（2026-10-19 与用户协同） | ✅ P5-U2 10/10、P4-U1 22/23、P4-U2 26/26、P6-U2 捕获页 10/10、P0-U4 产物 ffprobe 核验+设备播放；修复 2 项（完成后拷贝、捕获页增量渲染） |
| 深色观测（OPT-1 / P4-U1 第 23 项） | ✅ 2026-11-13 PC 模拟器复核（见 C.5），修复图标同色后通过 |
| P7-U1 公共流可播 | ✅ **2026-11-06 PASS**（业务外壳落地后经应用内真实下载路径验收，不经探针：公共 DASH bbb_30fps 180p 21.2 MB/634.57 s，视频解码 MD5 与主机按 CDN 分片自建参考一致、音频 PCM 逐样本一致；公共 HLS Mux 240p 与 64 个 CDN 分片拼接逐字节一致）；另 HLS/DASH 本地真实媒体、强杀续传、暂停续传全部 PASS，见 [e2e-adaptive-2026-11-06.log](../probe/e2e-adaptive-2026-11-06.log) |

---

### C.5 PC 模拟器验收（2026-11-13，真机租期到期后）

DevEco 模拟器「MateBook Pro」（pc_all_x86，HarmonyOS 6.1.1 API 24，devicetype=2in1，3120×2080 与租用真机一致，x86_64；安装包已含 x86_64 原生库）。驱动脚本 `docs/probe/e2e/`，记录 [emulator-pc-2026-11-13.log](../probe/emulator-pc-2026-11-13.log)。

| 范围 | 结论 |
|---|---|
| HTTP / HLS 单轨 / HLS 双轨 remux / DASH | ✅ 字节或解码 MD5 与源一致（DASH 音频同真机：尾裁 1041 样本） |
| 强杀重启续传 / 应用内暂停续传 | ✅ 零清单请求、只补未封存分片、产物逐字节一致（首轮在任何分片封存前强杀=全量重下，属已登记 O5b 限制，非缺陷） |
| 公共 DASH bbb 180p / 公共 HLS Mux 240p | ✅ 与真机产物哈希完全一致，解码零错误 |
| UI 浅色+深色截图复核 | ✅ 深色经临时强制深色测试构建（已还原，未改系统设置）；发现并修复 4 项（D 档 1） |
| 模拟器覆盖不到 | 真实网络路径与性能、PC 实机文件夹授权与后台保活、真实浏览器页面捕获——留待真机 |

### C.6 全量功能检测（2026-11-19，上架前，PC 模拟器）

范围＝下载以外的全部功能：全部探针单元（P0~P7）＋ UI 菜单/对话框逐项走查。驱动 `docs/probe/e2e/`（probe-hosts / probe-run / plog / baseline-diff / expect-show），对照 2026-10-18 真机基线。记录 [emulator-pc-2026-11-13.log](../probe/emulator-pc-2026-11-13.log) §2026-11-19。

| 范围 | 结论 |
|---|---|
| 探针 P0-U2/U3/U4、P1-U1/U2、P2-U1/U2、P3-U1/U2、P4-U1/U2/U3、P5-U1/U2、P6-U1~U6、P7-U1-F/P/C | ✅ 全部通过（与真机基线一致；P5-U1 关窗后台续下 0→12%） |
| UI 走查：新建菜单、批量、语言、设置各页保存、分类筛选、排序、删除（含/不含文件）、打开、行内暂停/继续、收件箱 | ✅（修复 3 项产品缺陷 + 2 项探针缺陷，见 D 档 1） |
| 未实现的占位项（导出/导入、帮助、报告问题、检查更新、视频向导、队列/计划任务） | 上架整改：**移除禁用占位**（不在商店版中出现不可用入口）；「移除已完成的任务」「关于」接线实现 |
| 探针页 | release 包忽略 `page=probe`（appInfo.debug=false），实测 release 包落主界面 |
| 改名与图标（参照 draw.io 上架驳回经验：审核指南 1.20 名称/图标一致、9.4/9.5 商标） | 应用名定为「XDM下载管理器 / XDM Download Manager」（AppScope 三语 + EntryAbility 标签，窗口标题栏/任务栏一致，去掉含华为商标的 XdmHarmony）；原创分层图标（`scripts/make-icon.py` 生成，替换 DevEco 模板默认图标）；关于页改为“基于…修改开发”。商店素材 `store-listing/`、隐私政策 `docs/privacy.html` |
| 模拟器覆盖不到 | 右键菜单（uitest 无右键注入，真机已覆盖）、真实浏览器页面捕获、PC 实机目录授权持久化 |

## D. 已知问题（三档，与 B 节降级三层分开）

### 档 1 已闭环（登记证据链）

| 问题 | 等级 | 闭环证据链 |
|---|---|---|
| U4.1 幽灵选中清理 + 走查项 11 文案（两 medium） | medium | 2dcf823 主会话修复；Index.ets:899-902 注释「对齐 WPF AppController.cs:524-528」本会话实读 |
| U4.2 **IR-F1 完成窗单飞**（medium） | medium | **U4.2 报告 ：114 的「未修」快照已过时**——实际随 **1047748** 闭环：代码实证 entry/src/main/ets/components/ProgressWindowDialog.ets:400-410（「入队待前一窗关闭后补弹…有意差异 D 系」注释 + completedPending.push:408）、:457-461（关闭后 shift 补弹:458），本会话实读；git log 1047748「完成窗单飞吞通知（队列补弹+开窗失败复位标志）」实测 |
| U4.2 IR-F2 选择链 Now/Later 极性颠倒 | medium | R4-F1 已修复（U4.2 报告 ：115 处置列「已修复」实测） |
| U7.1 XML 属性先序合并 + Timeline 大 r 预算门（独立复核两 medium） | medium | 随 a98e2fc 主会话修复（git log 实测） |
| U4.3 分类列表会话内不刷新（复核F1） | medium | 随 76a6e7d 主会话修复（git log 实测） |
| U5.1 apply/release 簿记失同步（复核F1） | medium | 随 9874c9a 主会话修复（git log 实测） |
| U2.1 探测回执互逆次序挂起（复核F1） | medium | 随 b6b215d 主会话补修（git log 实测） |
| U1.2 重试预算跨启动累积 + END_GATE 语义偏差 | medium | 随 3591cd4 主会话修复（git log 实测） |
| U0.2 无界 endGate 产品侧风险 | medium | 产品侧硬约束落地为空闲超时（3591cd4）；探针 P0-U2 会话#1 全绿 |
| P2-U2 慢滴流源零字节（探针 FAIL 高） | 高 | 返修 a39ba92 已落地（编译/单测门禁过）；**探针复验 pending**（C.2），故同时挂在 C 节待复验账上 |
| U2.3 COLD-F1 小文件探测零派发挂起 | high（热修） | e720b7a（跨红线授权 D25） |
| U6.2 IR-F1 + 同面 F1（processNormalVideo 登记携带 tabUrl 致 /tab-update 可误改 normal 条目名；`--media-tab-url` 缺 title 键仍执行改名） | medium | **2026-10-15 主会话修码闭环**（无真机批次）：BridgeRoutes.ets processNormalVideo 登记改传 tabUrl=''（镜像源 ProcessNormalVideo 不设 TabUrl，VideoUrlHelper.cs:688-694；仅 TabId）、dispatchArgs 缺 `--media-tab-title` 键整体中止（镜像源 ArgsProcessor.cs:23-24 取 title 先于 UpdateMediaTitle、缺键 KeyNotFoundException 被 :130-133 吞→零改名；原缺省 '' 兜底会经 sanitizeFileName('') 统一误改 'file'）；HandleDashAudio/dual 路径仍带 tabUrl 保持可改名。+2 回归用例（convergence_normalVideoImmuneToTabUpdateRename / convergence_argsMediaTabUrlMissingTitleAborts，BridgeRoutes.test.ets BridgeConvergence 组尾）；门禁 642/642 全绿（F.3，首跑 1 error 为用例自身 /args body 格式笔误、真值 wrapper 拦截后转绿） |

| P2-U2 慢源零字节**根因**（a39ba92 仅修生命周期） | 高 | **2026-10-18 真机插桩闭环**：HttpClient 以 Content-Range 先行确认 206（终态核对）、末跳头撤状态时限、readTimeout 24h；host http-client 16/16；P2-U2 S1~S4 PASS |
| U5.1 长时任务申请 401（关窗后台下载从未生效） | 高 | **2026-10-18**：ProgressNotifier WantAgentInfo 补 actionType/actionFlags；P5-U1 S2 applied=true、S5 survived taskAlive=1/advanced=true |
| U6.4 清单 302 失败（http maxRedirects:0 → 2300047） | medium | **2026-10-18**：ManifestClient 单跳改 rcp autoRedirect:false；host manifest 40/40；P6-U4 S3 PASS |
| U6.4 rcp 头/状态先后序隔离致 >64KiB 分片 fatal | 高 | **2026-10-18**：AdaptiveRcpStream 头块暂存配对；P6-U5 S2 PASS |
| U6.4 rcp 队列溢出丢在途字节（cacheSize 暂停滞后） | 高 | **2026-10-18**：物理容量 1MiB、readInto、1007900990 判 retryable；P6-U5/U6 S2 PASS（整段哈希一致，P6-U6 连续 3 轮） |
| 探针缺陷 ×2（P6-U2 头值裸串、P7-U1-P 读者结算未登记） | — | 2026-10-18 修探针后复跑 PASS |
| U5.2 完成后拷贝到用户目录失败（fileIo.copy 目标传目录 URI → 13900020） | medium | **2026-10-19 走查⑤**：SaveDirectory 目标改为文件 URI（basename 编码）；真机复测拷入所选目录 |
| U6.2 捕获页不增量渲染（分组 ForEach key 恒定致节点复用） | medium | **2026-10-19 走查⑩**：key 含组内 id 序列；真机复测推送即显 |
| 探针缺陷（P4-U2 S4 首窗存活读数） | — | 2026-10-19 改判「新开或新入队」后复跑 PASS |
| **HLS/DASH 业务外壳未接线**（自适应视频不可下载） | 高 | **2026-11-06 落地**：AdaptiveDownloader + DownloadManager 工厂 + 描述旁表 + HLS 捕获接线 + Index 路由；主机 629/624/0/5、Hypium 642/642；真机本地与公共 HLS/DASH、强杀/暂停续传全部解码比对 PASS（[报告](../design/u6-4-outer-integration-REPORT.md)） |
| 设备 SDK URL 基址解析不符合 RFC 3986（`parseURL('./', '…/x.mpd')` 把 x.mpd 当目录） | 高 | **2026-11-06**：公共 DASH 全部分片 404，从设备 downloads.db 取证分片 URL 为 `…/bbb_30fps.mpd/…`；HlsUrlResolver 改纯字符串 RFC 3986 §5.2 解析（SDK 只校验最终绝对 URL）；主机仿设备缺陷回归 + RFC 5.4.1 例表；复测公共流 PASS |
| 分片 HTTP 4xx 不重试（与源 HttpChunkDownloader 不一致） | medium | **2026-11-06**：设备网络路径 CDN 偶发 404 即整任务失败；400–599 改 retryable（MaxRetry/RetryDelay 预算内，保留固定码），1xx/其他 2xx/3xx 仍 fatal；Hypium/主机断言同步 |
| UI 统一整改（走查反馈：按钮白字浅底不可读、弹窗无背景/横向拉伸、多进度窗完全重叠、浏览按钮仅「...」、捕获页/设置页内容垂直居中留白、底栏浏览器监视开关恒禁用） | medium | **2026-11-06**：新增主题色 text_primary/dialog_bg（浅/深两套）；工具栏、底栏、捕获页按钮显式字色；openCustomDialog 三窗（进度/限速/完成）内容自带面板（定宽、dialog_bg、圆角、阴影），CustomDialogController 九处统一 width+不透明背景+关闭模糊；进度窗按序错位层叠；「...」改本地化 Browse…；Scroll 顶对齐；底栏监视开关接 Config（写配置+广播，监听设置页变更）。真机截图复核主窗/新建/进度/完成/设置/捕获页；**深色模式未真机复核**（不擅改系统主题，留用户验收） |
| 模拟器验收发现的 UI 4 项（深色下分类/文件类型/工具栏图标恒黑与背景同色；空列表占位硬编码中文；未知剩余时间显示 00:00:00；非模态完成窗无关闭控件、跨页残留） | medium | **2026-11-13**：SymbolGlyph 统一 text_primary；占位改字符串资源 empty_finished/empty_in_progress（三语）；ETA≤0 显示 ---；完成窗加 Close。PC 模拟器浅/深色复核通过，门禁 642/642、主机 629/624/0/5 |
| 全量检测发现（打开文件在 2in1 镜像崩溃：filePreview 不可用；语言下拉框空白；多选删除/批量移除只删部分——并发 IMMEDIATE 事务 14800015） | 高/medium | **2026-11-19**：openFile 先判 canIUse(FilePreview)，不可用/失败回落系统「打开方式」（viewData + 读授权）；Select 显式 value；removeRecords 改逐条串行。模拟器复测：打开不崩、语言即时生效、15/15 与 6/6 删除且重启后持久 |
| 探针缺陷 ×2（P4-U3 S3 读回变量未赋值；P1-U2 S7 accessSync 返回值被忽略致 tempDirGone 恒 false——10-03 起的 low 登记项实为探针误报，引擎清理正确） | — | 2026-11-19 修探针后复跑 PASS（tempDirGone=true；timeoutR/segmentsR/minVideoR 与写入一致） |
| **分片引擎重复下载**（大文件临时目录膨胀：1.2GB 文件临时目录 3GB、2.4GB 文件 3.8GB 直至磁盘写满；进度条长时间停在 0%） | 高 | **2026-11-19**：根因=worker 在 setInterval 回调内 Task.sendData 报进度，本平台抛错后 reportDisabled，主线程 piece.downloaded 恒为 0、按 0 盲分裂，被分裂片往往已近写满→整段重下。改为 SharedArrayBuffer 共享状态（已写字节数+取消标志），主线程每 250ms 及分裂前轮询；进度消息只接受单调前进值。实测：300MB 文件临时目录峰值 301MB（修前 370MB）、500MB 限速下载暂停→恢复 MD5 一致、500MB 强杀重启续传 MD5 一致；P1-U2/P2-U1/P2-U2(S4)/P3-U1/P3-U2 与基线一致 |
| 运行时切换语言后状态列/进度窗仍为旧语言；删除任务后进度窗残留；进度窗长 URL 只显示到最后一个 '/' | medium | **2026-11-19**：语言切换回调刷新缓存标签（状态列经 AppStorage 版本号重渲染）；删除时关闭对应进度窗；URL 按字符截断加省略号。模拟器复测通过 |
| 上架风险项（设备类型声明了未测试的 phone；PC 端无任何键盘快捷键——draw.io 曾因此被驳回） | medium | **2026-11-20**：module.json5 deviceTypes 仅 2in1；主窗口 Ctrl+N/Ctrl+A/Delete/Esc/Ctrl+F（搜索框获焦时让出编辑键）。模拟器实测 Ctrl+A/Esc/Delete/Ctrl+N 生效，Ctrl+F 未实测（输入法隐私协议） |
| 默认界面语言为英文（Config 默认 en-US 且每次启动强制应用，中文系统全新安装也显示英文） | medium | **2026-11-20**：默认改为 zh-Hans（面向国内应用市场）；已选过语言的用户不受影响。英文系统模拟器全新安装实测中文界面；主机 630/625/0/5、Hypium 642/642（runDir `2026-11-20T08-30-28-122Z-a5f2925e`） |

### 档 2 开放 medium

| 问题 | 等级 | 证据链 | 处置去向 |
|---|---|---|---|
| ~~HLS/DASH 业务外壳未接线~~ | ~~高~~ | **已闭环，移入档 1（2026-11-06）**。原证据：公共 DASH 流 bbb_30fps.mpd 经桥捕获成功（`dash capture done multi=10`，rcp 清单客户端在真实 CDN 上实测可用），捕获页点下载 → 「not supported yet」（Index.ets openNextInbox `videoKind !== 'video'` 分支）；u7-1 报告 :23/:66、u6-4 报告 :3/:74 原已写明外层集成未做，但交付总结未如实披露 | 待办：落地 u6-4 外层集成 O2/O3/O7 后做公共流端到端可播验收（P7-U1 公共流项随之解阻） |
| 自适应：运行中前缀不持久（O5b） | medium | 仅已封存分片计入断点；在途分片强杀后整片重下（2026-11-06 实测 5 个在途分片重下）。分片型 HLS/DASH 影响小，双源（整文件单分片）影响大 | 后续单元：E2/E3/E4/C 联合协议（u6-4 外层设计 §6.5） |
| 自适应：POST 清单发现、每来源认证/代理、双源第二套请求头 | medium | 桥捕获仅 GET；请求只带捕获时 Referer/Cookie 等头，未兑现任务级 Basic/Digest、手动代理；yt 双源 headers2/cookies2 未用 | 后续单元 O3/O4 |
| 自适应：分片 3xx 不跟随 | low | E3 `autoRedirect:false`，分片重定向判 fatal（源 HttpClient 自动跟随）；本次公共流未遇到 | 需要时在 E3 加有界跳转（凭据跨域剥离规则同 ManifestClient） |
| 自适应：完成回执沿用 HTTP 路径 | low | 未实现 completionId/outbox 幂等回执（O6b），完成写库与 HTTP 相同（Index.handleFinished→markAsFinished） | 后续单元 O6b |

其余历轮登记的 medium 经逐报告复核（B.2 表 + 档 1 证据链核对）已全部在后续提交闭环或对冲；**开放 medium 至此清零**（2026-11-06 新增开放高项「HLS/DASH 业务外壳未接线」已于同日闭环；其后登记的是自适应业务外壳的范围差距，见上表）（U6.2 IR-F1/F1 为最后一项，2026-10-15 批次闭环）；P2-U2 探针复验（C.2）开放的是「复验」而非「缺陷」（返修 a39ba92 已落地）。首轮登记曾漏 U6.2 IR-F1（其登记位在报告 §4 处置表而非 §7 遗留节，首轮提取未覆盖），审查指出后本档已补登——如人工复查发现其他开放 medium，在此登记。

### 档 3 历轮 low（逐单元一行引用，明细见对应报告 §7）

| 单元 | 一行摘要（本会话实读该报告 ⑦ 节） |
|---|---|
| U0.1 | deprecated pasteboard API、lastLine 死代码、设计书笔误、PROBE_SPEC 值白名单等 8 项（⑦） |
| U0.2 | runId 秒级精度、文档修订 5 项清单、单测 runner 缺位、S6 环境分叉等 7 项（⑦） |
| U0.3 | Content-Length 溢出护栏、空状态行、用例计数注释三 low + 端口失配无 UI 提示（有意拍板）（⑦） |
| U1.1 | 设计书旧文、WITHOUT ROWID 分支未实测、Config flush 异步窗口等（⑦；add() 护栏已随 a9d98fd 修） |
| U1.2 | 重试预算/END_GATE 已随 3591cd4 修；SessionExpired(9) 未复刻等余项见 ⑦ |
| U2.1 | 缺 Content-Range 边缘 206 误判、worker 写盘错不短路、fd 泄漏防御死码等（⑦） |
| U2.2 | sparse 零洞（源同病）、length=-1 片 NonResumable（源同貌）、停摆边界（⑦） |
| U2.3 | 小文件热修运行时真实验证待探针（⑦；单测面 117 全绿已收口） |
| U3.1 | 探针检查口径、stopIntent 死簿记、排队行按钮死态三 low + D9 DB 回声（⑦） |
| U3.2 | 探测派发限速注释偏差、启动边界不探（任务书口径）等（⑦） |
| U4.1 | quirks 注释、分类底色、0 分类搜索覆写、僵死 Waiting 标签等（⑦；B1/B2 已闭环） |
| U4.2 | INT-F5~F8（代理回退/死回调/死监听器/Show progress 门）+ IR-F3/F4（catch 复位/开关竞态）（⑦） |
| U4.3 | R2-F3/F5 登记义务、注释语义、uaPrefix 尾空格等（⑦；复核F1 已闭环） |
| U5.1 | 瞬态误删、clampProgress 措辞、EXPECT 分支覆盖、文档同步（⑦；复核F1 已闭环） |
| U5.2 | L1~L6（排队守卫方向/走查文案/OpenAction 落点/行数口径/FolderAlgo 点尾/探针 S1 置位）（⑦） |
| U6.1 | 七 low（畸形/兼容流量或文档面）+ LinkAccepted 未迁移等已登记差异（⑦） |
| U6.2 | 规格件红线边界、SHA-1 注释向量错误等约十 low（⑦）；IR-F1/F1（medium）不属本档，登记见 D.2 |
| U6.3 | 「源差异与未验范围」节：真实浏览器与设备验收待执行（批次报告形态）（§） |
| U6.4 | 冷审 IPv6 边缘、r1 门禁拒绝流程记录等（⑦/§） |
| U7.1 | R3~R4 low + R5 登记性差异 + R7 codelinter/warning 既有基线（⑦） |
| U0.4/U7.2 | 目标设备运行、导出媒体解码及播放未验收（报告头「U0.4 尚无运行 GO」） |

---

## E. 交付物登记（T7 表）

**release 构建于 2026-10-11 10:21 由本会话以 §F.1 命令实际执行并即时登记**（`BUILD SUCCESSFUL in 19 s 397 ms`，PackageHap/SignHap/PackingCheck/CollectDebugSymbol 全部 Finished；完整 stdout 留档 `D:\git\HarmonyPC\migration-runs\build-release-u7-3-20261011T1013.log` 供独立复核）。

**产物时间线**：01:23/01:24（首轮产物，模式不可证，设计书 F6）→ 09:01（本单元首次 release 构建，BUILD SUCCESSFUL in 4 min 44 s 785 ms）→ 09:44（登记后被覆写，未登记）→ 10:05（本单元重跑 release，BUILD SUCCESSFUL in 12 s 747 ms，曾登记）→ 10:08（再次被覆写：hvigor 守护日志 `~/.hvigor/daemon/log/6.24.4/daemon-35192.log` :320/:337 实证 10:08:11 收到 assembleHap 请求、exitCode=0、7.3s；其 unsigned 产物 11,685,203 B 与 09:44 对**逐字节同尺寸**，而同源树本单元三次 release 构建 unsigned 均 8,805,794 B——同输入不同输出即不同 buildOptionSet，判定为门禁默认模式（debug）构建，**非交付构建，未登记**）→ 10:21（本单元重跑 release，曾登记）→ 10:23（测试真值门禁覆写，R2-F1 实证）→ **11:08（终局 release 构建——全部构建活动结束后的最后一次 §F.1 执行，以下表为终局交付登记；此后仅剩 git tag 与探针会话#2，均不再触发构建）**。

**登记时序约定（R2-F1 修订）**：
1. 本表登记**最近一次交付构建（§F.1 release 命令）**的实测指纹，登记在该构建完成后立即执行，构建日志留档 migration-runs。
2. 管线门禁每轮后会以默认模式 assembleHap 覆写 `entry/build/default/outputs/default/`（10:08 实证），属验证行为、**不是交付构建**，不触发本表更新，但会使磁盘产物偏离本表。判别特征：门禁产物 zip **22 条目**含 `ets/sourceMaps.map`+`ets/symbolMap.map`、unsigned 11,685,203 B；交付 release 产物 **21 条目**仅含 `ets/symbolMap.map`、unsigned 8,805,794 B。
3. **终局登记**：全部构建活动结束后，由人工执行 §F.1 一次并按实测回填本表；或确认最后一次构建即为 release 交付构建后按实测重测回填。验收发现磁盘与本表不一致时，先按第 2 条判别特征区分门禁覆写与真实失配。
4. **R2-F1 终局闭环（2026-10-11 11:08）**：探针会话#2 前执行最后一次 §F.1 release 构建并按实测回填本表（下表）；该构建后仅剩 git tag（不触发构建）与探针会话#2（安装运行，不构建）——本表自此为终局登记，后续任何再构建须重测回填。
5. **包名变更（2026-10-12，上架准备）**：bundleName 由 `com.example.xdmharmony` 更名为 `com.neuohos.xdm`（vendor → neuohos），源级改动三处（AppScope/app.json5、ProgressNotifier wantAgent、运行文档命令）。**上表 11:08 指纹随之作废**——旧产物为旧包名；新包名须（a）设备连接后重跑 `devecocli signature generate --product default` 生成新 Profile（签名材料绑定 bundleName），（b）重跑 §F.1 release 构建，按约定第 4 条重测三件套回填本表。改名的构建验证（未签名 debug）已通过。
6. **权限申请结论更正（2026-10-15，官方文档比对定论）**：改名批次提交说明中「4 权限均为开放权限、无需 AGC 权限申请页操作」**有误**，更正为——INTERNET / KEEP_BACKGROUND_RUNNING / PREPARE_APP_TERMINATE 三项为开放权限（系统授权，声明即用，不在 AGC 申请页属正常）；**READ_PASTEBOARD 为 ACL 受限权限**，须在 AGC 提交受限权限申请（理由文案备好：剪贴板链接监视为核心功能）；被拒降级方案为移除该权限改用 PasteButton 组件（用户主动粘贴）。**2026-10-17 一手验证补充**：signature generate 工具链提示该受限权限「随 app release 一同审核」，且随**调试 Profile 装包不拒**（F.2 实测 install successfully）——「未获批正式分发被拒」的触发点在 AGC 发布证书/上架审核，不在装机。完整提审材料见 [AGC-SUBMISSION.md](AGC-SUBMISSION.md)（2026-10-15 新建）。
7. **新包名终局登记（2026-10-17，重签闭环）**：真机连接后按第 5 条流程完成（a）`devecocli signature generate --product default` 生成绑定 `com.neuohos.xdm` 的新 Profile（signingConfigs 自动回填 build-profile.json5；材料文件名沿用工程名 `default_XdmHarmony_*` 属正常——名随工程、内容随包名）；（b）§F.1 release 构建实测（`BUILD SUCCESSFUL in 3 min 19 s 790 ms`）；（c）三件套实测回填下表【新】——**本表自此接替 11:08 旧表成为终局登记**（旧表降级为旧包名历史记录）；（d）真机装包+启动冒烟通过（F.2）。此后仅剩探针会话#2（安装运行，不构建）与 git tag，任何再构建须重测回填。

12. **全量检测 + 上架整改 + 改名/图标 + 分片引擎修复后终局登记（2026-11-19 晚）**：门禁 642/642（runDir `2026-11-19T15-36-08-615Z-b552abf9-*`，2026-11-20 设备类型+快捷键后复跑）、主机套件 630/625/0/5（+1 YouTube DASH 音视频成对登记用例），§F.1 release（`BUILD SUCCESSFUL in 7 min 5 s 351 ms`），PC 模拟器装包启动通过、`page=probe` 被忽略。本条接替第 11 条指纹表。

| 产物（2026-11-19 终局） | 路径 | 构建模式 | 时间戳 | 大小 | sha256 |
|---|---|---|---|---|---|
| entry-default-signed.hap | entry/build/default/outputs/default/ | **release** | 2026-11-20 02:47:22 +1100 | 8,999,226 B | `f2160e245d39a76ed422be6ab59bfa1939761d9acb8cc6ea15239ccbe55d0bc1` |
| entry-default-unsigned.hap | entry/build/default/outputs/default/ | release（未签名伴生） | 2026-11-20 02:47:04 +1100 | 8,865,183 B | `6b220dcd7fc765a5e2fbc118e5a0d58c6324e1867b49e2ec32fd4a0732f98b92` |

- 21 条目、无 sourceMaps.map（仅 symbolMap.map）。

**第 11 条历史记录**：

11. **PC 模拟器验收修复后终局登记（2026-11-13）**：门禁 642/642（runDir `2026-11-13T11-11-00-867Z-1b1cee41-*`）、主机套件 629/624/0/5，§F.1 release（`BUILD SUCCESSFUL in 22 s 2 ms`），PC 模拟器装包启动通过（真机租期已到期，本次冒烟在模拟器上）。本条接替第 10 条指纹表。

| 产物（2026-11-13 终局） | 路径 | 构建模式 | 时间戳 | 大小 | sha256 |
|---|---|---|---|---|---|
| entry-default-signed.hap | entry/build/default/outputs/default/ | **release** | 2026-11-13 22:12:29 +1100 | 9,023,554 B | `6508a2a7abfe409e6c414b1dbbf91f073efe70f8e395a49a0ed5a06a3686b59e` |
| entry-default-unsigned.hap | entry/build/default/outputs/default/ | release（未签名伴生） | 2026-11-13 22:12:28 +1100 | 8,890,616 B | `b0283be9b576bfcb844afb6a5d0c38a065e53bb5560c34afd2da30870f8cc651` |

- 21 条目、无 sourceMaps.map。

**第 10 条历史记录**：

10. **HLS/DASH 业务外壳 + UI 统一整改后终局登记（2026-11-06）**：门禁 642/642（runDir `2026-11-06T09-27-20-911Z-c7aa0bd6-*`）、主机套件 629/624/0/5，之后 §F.1 release（`devecocli build --product default --modules entry --build-mode release`，`BUILD SUCCESSFUL in 14 s 159 ms`），真机装包 install successfully + 启动 start successfully（pid 在位）。本条接替第 9 条指纹表（第 9 条降级为历史记录）。

| 产物（2026-11-06 终局） | 路径 | 构建模式 | 时间戳 | 大小 | sha256 |
|---|---|---|---|---|---|
| entry-default-signed.hap | entry/build/default/outputs/default/ | **release** | 2026-11-06 20:28:15 +1100（=17:28:15 +0800） | 9,024,946 B | `0837f4c78ba8827c3def4cf2ff7fb06eb7531ad69e2b589c6ac4a56c9b42688a` |
| entry-default-unsigned.hap | entry/build/default/outputs/default/ | release（未签名伴生） | 2026-11-06 20:28:15 +1100 | 8,888,659 B | `3bd7d1dae4621e4b384374f62e652237ac05ffe367cf61fee4884ada7334a0a7` |

- pack.info：com.neuohos.xdm / 1.0.0 / compatible 23 · target 24 · Release；21 条目、无 sourceMaps.map。

**第 9 条历史记录**：

9. **人工走查批次修复后终局登记（2026-10-19）**：SaveDirectory/VideoCapture 修复后门禁 642/642（runDir `2026-10-19T07-23-37-173Z-*`）、主机套件 599/0/5，之后 §F.1 release（`BUILD SUCCESSFUL in 13 s 775 ms`，stdout `migration-runsuild-release-20261019-final.log`），真机 install+启动冒烟通过——**本表接替第 8 条表成为终局登记**（第 8 条表降级为历史）。

| 产物（2026-10-19 终局） | 路径 | 构建模式 | 时间戳 | 大小 | sha256 |
|---|---|---|---|---|---|
| entry-default-signed.hap | entry/build/default/outputs/default/ | **release** | 2026-10-19 00:24:22 -0700（=15:24:22 +0800） | 8,977,365 B | `f931e05ca99c27ec7087a8f86e61488b5c698e1876be9a396b3bd07b92024522` |
| entry-default-unsigned.hap | entry/build/default/outputs/default/ | release（未签名伴生） | 2026-10-19 00:24:22 -0700 | 8,847,633 B | `fafb94bd44bfaf3e4d2f91317c307c601d2bee856258748e809cb8737befd041` |

- pack.info：com.neuohos.xdm / 1.0.0 / compatible 23 · target 24 · Release；21 条目、无 sourceMaps.map。

**第 8 条历史记录**：

8. **探针会话#2 修复后终局登记（2026-10-18）**：5 项产品缺陷修复后，门禁（642/642，F.3）之后最后执行 §F.1 release 构建（`BUILD SUCCESSFUL in 5 s 899 ms`，增量；stdout 留档 `migration-runsuild-release-20261018-final.log`）并实测回填下表【新】——**本表接替 10-17 表成为终局登记**（10-17 表降级为修复前历史记录）；真机 `install -r`+启动冒烟通过（F.2）。签名未重跑（Profile 不变）。

| 产物（2026-10-18 修复后，2026-10-19 作废） | 路径 | 构建模式 | 时间戳 | 大小 | sha256 |
|---|---|---|---|---|---|
| entry-default-signed.hap | entry/build/default/outputs/default/ | **release**（显式 `--build-mode release`） | 2026-10-18 22:58:26 -0700（=10-19 13:58:26 +0800） | 8,977,881 B | `7b91091851e8301f8fe545c0fdea4379866f5d4389db27c1c8df8e3a1407fd25` |
| entry-default-unsigned.hap | entry/build/default/outputs/default/ | release（未签名伴生产物） | 2026-10-18 22:58:25 -0700 | 8,846,802 B | `7528319bccc6136a9bf9570ab49aa1233cad27289a4294cf1b41c88fe2d66517` |

- pack.info（实测）：bundleName `com.neuohos.xdm`、version 1000000/1.0.0、deviceType phone/2in1、apiVersion compatible 23 / target 24、releaseType Release；zip **21 条目**、不含 `ets/sourceMaps.map`（release 判别特征）。

**修复前历史记录（2026-10-17 新包名重签终局，10-18 修复后作废）**：

| 产物（2026-10-17 新包名终局） | 路径 | 构建模式 | 时间戳（+0800） | 大小 | sha256 |
|---|---|---|---|---|---|
| entry-default-signed.hap | entry/build/default/outputs/default/ | **release**（`devecocli build --modules entry --build-mode release` 显式，实测） | 2026-10-17 08:46:14 | 8,972,414 B | `ff8294460eb32e51d61ab20a6abe9b61df55607fe51ced03addd56414c19d308` |
| entry-default-unsigned.hap | entry/build/default/outputs/default/ | release（未签名伴生产物） | 2026-10-17 08:46:11 | 8,842,911 B | `608619980c03dc789f6811a1c55bc09810f9c9ab289f68fe2912afb2c014ba24` |

- **pack.info 指纹**（自本次 signed HAP 内解包实测）：bundleName **`com.neuohos.xdm`**，version code `1000000` / name `1.0.0`，moduleName `entry`，deviceType `["phone","2in1"]`，apiVersion `compatible 23 / target 24`，releaseType `Release`。
- zip 完整性：signed HAP 实测合法 zip、**21 条目**（含 pack.info 与 `ets/symbolMap.map`、不含 `ets/sourceMaps.map`，python zipfile 校验）——符合登记时序约定第 2 条的 release 交付构建判别特征。

**旧包名历史记录（11:08 终局，2026-10-12 改名后作废，留档不复验）**：

| 产物 | 路径 | 构建模式 | 时间戳（+0800） | 大小 | sha256 |
|---|---|---|---|---|---|
| entry-default-signed.hap | entry/build/default/outputs/default/ | **release**（`--build-mode release` 显式，11:08 终局实测） | 2026-10-11 11:08:04 | 8,937,128 B | `73db0c0f35fd5fc981e35d78cedd4a48b3ff5d9fc7cac1fd4f5f26593c428b62` |
| entry-default-unsigned.hap | entry/build/default/outputs/default/ | release（未签名伴生产物） | 2026-10-11 11:08:03 | 8,805,794 B | `6d190c1232a088f1459f5e105dc8a2915fd8daa0e30e435d877067ea2a1d1eec` |

- 旧包名 pack.info 指纹（历史）：bundleName `com.example.xdmharmony`，其余字段（version/apiVersion/releaseType/deviceType）与本次新表一致。
- 产物核对三件（设计书 §3.1）：signed HAP 在位 ✅；mapping/ 无 mapping.txt（仅 sourceMaps.map，与混淆关闭一致 F7）✅；pack.info apiVersion compatible=23/target=24 ✅。
- **二进制不入 git**：`.gitignore:5 **/build` 与 entry/.gitignore:4 `/build` 已忽略（`git check-ignore -v` exit=0 实测）——本表登记路径/模式/时间戳/大小/sha256 即可复验。
- zip 完整性：signed HAP 实测为合法 zip、**21 条目**（含 pack.info 与 `ets/symbolMap.map`、不含 `ets/sourceMaps.map`，python zipfile 校验；条目差异判别特征见登记时序约定第 2 条）。

---

## F. 构建与测试复现

### F.1 release 构建（本会话已实测复现）

```powershell
cd D:\git\HarmonyPC\XdmHarmony
# 前提：signingConfigs 已就绪（2026-10-17 重签回填，绑定 com.neuohos.xdm）；无改名等需求勿重跑
# devecocli signature generate（会重写签名配置与材料）
devecocli build --product default --modules entry --build-mode release
# 产物：entry/build/default/outputs/default/entry-default-signed.hap
# 指纹登记：文件大小 + sha256sum + pack.info 关键字段（见 E 节）
```

- `--build-mode release` **必须显式**：`devecocli build --help` 实测默认 `debug`（本会话复证，devecocli 1.3.0-stable）。
- 交付构建实测输出（10:21 终轮，完整 stdout 留档 `D:\git\HarmonyPC\migration-runs\build-release-u7-3-20261011T1013.log`）：`Finished :entry:default@SignHap... after 357 ms` → `Finished :entry:default@CollectDebugSymbol` → `Finished :entry:assembleHap` → `BUILD SUCCESSFUL in 19 s 397 ms` → `Build completed successfully`。同命令历史轮：09:01 全量 4 min 44 s 785 ms（未留档）、10:05 增量 12 s 747 ms（`build-release-u7-3-20261011.log`）。WARN 仅为探针文件与 ClipboardWatcher/ManifestClient 的 may-throw 既有基线（U7.1 报告 R7 已登记为非本单元引入）。
- 已知环境怪癖（间歇）：09:01 轮曾出现 hvigor 任务完成后 devecocli/hvigorw 客户端进程滞留在守护进程握手不退出（产物已完整落盘，终了滞留进程后退出码 0）；10:05/10:21 轮均自行正常退出。若复现，终了滞留进程即可，产物完整性按 E 节三项核对。

### F.2 真机安装冒烟（可选，环境可用时执行）

```powershell
"D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" app install entry/build/default/outputs/default/entry-default-signed.hap
```

真机系统为 API 23（B.3），装包成功即 compatibleSdk 钉值的最终验证。失败时记录错误码，**不得通过改 compatibleSdk「修复」**。

**已于 2026-10-17 执行通过**（新包名终局产物，真机 MateBook Pro HAD-W24 `3QC0124B11000092`）：`app install entry-default-signed.hap` → `install bundle successfully`（compatibleSdk 6.1.0(23) 钉值最终验证 ✅，**READ_PASTEBOARD ACL 声明随调试 Profile 装包不拒**——与 signature generate 工具链提示一致：受限权限审核随**发布**进行而非装机）；`aa start -b com.neuohos.xdm -a EntryAbility` → `start ability successfully`（启动冒烟 ✅，bm dump 确认 apiReleaseType Release 在装）。注意 hdc 须自工程根用相对路径传 HAP（绝对路径会被拼接成 `工程根+绝对路径` 双拼而报 no such file，实测）。

**2026-10-19 再次执行通过**（E 节第 9 条终局产物）：install+`aa start` 成功。

**2026-10-18 执行通过**（E 节第 8 条产物）：`install -r` → `install bundle successfully`；`aa start` → `start ability successfully`，bm dump `apiReleaseType: Release`。

### F.3 单测真值门禁（唯一计分口径）

```powershell
cd D:\git\HarmonyPC\XdmHarmony
node scripts/run-hypium.cjs --expected-tests 642 --output ../migration-runs/hypium -- 'D:/Tools/DevEco Studio/tools/node/node.exe' 'D:/Tools/DevEco Studio/tools/hvigor/bin/hvigorw.js' test --no-parallel
```

- 通过判据=exit 0 且 verdict.json `ok:true`、`counts.total=642/pass=642/failure=0/error=0/ignore=0`（`--expected-tests 642` 钉注册防漏，run-hypium.cjs:56；门禁四条件见 scripts/HYPIUM_GATE.md:21-29）。**642 口径自 2026-10-15 起**（IR-F1/F1 修复批次 +2 回归）；此前历轮为 640 口径，防漏钉值须随之更新。
- **不得以 hvigor 退出码或 BUILD SUCCESSFUL 判绿**——hvigor test 存在假绿（退出码 0 且 BUILD SUCCESSFUL 但断言失败被吞，实测一次吞 5 例，HYPIUM_GATE.md:1-3）。本批次又实证一例门禁价值：首跑 642 中 1 条 **error**（新增用例 /args body 误传裸串非 JSON 数组）而 hvigor 仍 BUILD SUCCESSFUL，真值 wrapper 以 `ok:false` 拦截（runDir `migration-runs\hypium\2026-10-15T15-18-28-314Z-*`，实测 641 pass/1 error）；修用例后复跑转绿。
- **归档证据（2026-11-20，设备类型 2in1 + 键盘快捷键后终版，642 口径）**：runDir `D:gitHarmonyPCmigration-runshypium6-11-19T15-36-08-615Z-b552abf9-6a06-4bcb-bf10-cb9353b32c41`，ok:true 642/642；主机套件 630/625/0/5。
- **归档证据（2026-11-19 晚，改名+引擎修复后终版，642 口径）**：runDir `D:gitHarmonyPCmigration-runshypium6-11-19T11-08-50-654Z-15d23d22-1ae1-41db-82cb-3038b943fbfb`，ok:true 642/642；主机套件 630/625/0/5。
- **归档证据（2026-11-13 PC 模拟器验收修复后终版，642 口径）**：runDir `D:gitHarmonyPCmigration-runshypium6-11-13T11-11-00-867Z-1b1cee41-80c0-4657-a474-094b69c01fd1`，ok:true 642/642；主机套件 629/624/0/5。
- **归档证据（2026-11-06 UI 统一整改后终版，642 口径）**：runDir `D:gitHarmonyPCmigration-runshypium6-11-06T09-27-20-911Z-c7aa0bd6-7a26-4ac9-9b92-cbf11c8dfe5e`，ok:true 642/642；主机套件 629/624/0/5。
- **归档证据（2026-11-06 HLS/DASH 业务外壳落地后，642 口径）**：runDir `D:\git\HarmonyPC\migration-runs\hypium\2026-11-06T09-13-35-398Z-5cdbd3e6-8c54-4954-a0d2-845e11a91912`，`HYPIUM_GATE {"ok":true,"counts":{"total":642,"failure":0,"error":0,"pass":642,"ignore":0}}`；主机套件 629 项 624/0/5。
- **归档证据（2026-10-19 人工走查修复后终版，642 口径）**：runDir `D:gitHarmonyPCmigration-runshypium6-10-19T07-23-37-173Z-2b9e55a4-ee54-4817-844b-d86feb2190ac`，ok:true 642/642；主机套件 599/0/5。
- 归档证据（2026-10-18 修复后版，642 口径）：runDir `D:gitHarmonyPCmigration-runshypium6-10-19T05-57-20-302Z-23184d4a-418e-47a8-a35a-369e4ad12319`，`HYPIUM_GATE {"ok":true,"counts":{"total":642,"failure":0,"error":0,"pass":642,"ignore":0}}`。另：主机套件 `node --test XdmHarmony/tests/host/` **604 项 599 pass / 0 fail / 5 skipped**（本批次顺带修复 U7.1 起 adaptive 主机 harness 缺 `./DashModel` 依赖导致的整组不可运行；HttpClient/rcp/清单相关用例按真机事实改写）。
- 归档证据（2026-10-15 批次实测，642 口径）：runDir `D:\git\HarmonyPC\XdmHarmony\test-results\hypium\2026-10-15T15-29-53-446Z-9ff0798d-09d3-4968-bc95-ef90de1c385f`，`HYPIUM_GATE {"ok":true,"counts":{"total":642,"failure":0,"error":0,"pass":642,"ignore":0}}`。历史归档（640 口径）：2026-10-11 `migration-runs\hypium\2026-10-11T01-36-22-318Z-*` 全绿 + 两份 2026-10-10 全绿（`2026-10-10T17-58-45-814Z-*`、`2026-10-10T18-17-05-499Z-*`），本档历史会话实读均 640/640。

### F.4 环境约束（拦截性提醒）

1. **compatibleSdkVersion 6.1.0(23) 不得改回 24**（B.3：真机 HAD-W24 装 24 被拒 code 9568297）。
2. **签名状态（2026-10-17 重签闭环）**：新包名 Profile 已生成（signature generate 实测，signingConfigs 自动回填 build-profile.json5，材料 `C:\Users\11292\.ohos\config\default_XdmHarmony_*` 内容绑定 com.neuohos.xdm）；release 重建+真机装包+启动冒烟均通过（E 节第 7 条/F.2）。**除非再改名，勿重跑 signature generate**（会重写配置与材料）。READ_PASTEBOARD 受限权限已随 Profile 带入，正式发布审核时随上架材料一并审（E 节第 6 条）。
3. `devecocli build` 默认 debug——release 必须显式 `--build-mode release`。

---

## G. openQuestions（移交人工拍板）

1. **git tag 补打时机**：建议会话#2 全部通过后人工补打（UNIT_CATALOG v2:19 人工动作 + 探针会话#2 15 项未过前不补），本表 M7 行已登记「tag 待人工补打」。
2. **工程根 GPL-2.0 LICENSE 文件**：~~实测不存在（F8）~~ **2026-11-19 已补**（上架分发必需）。原文：实测不存在（F8）。建议补 GPL-2.0 全文使分发链自洽（A.4 要素 4）；是否新增由人工拍板——编码员按红线未擅自创建。
3. **release HAP 交付形态**：建议只登记路径/模式/时间戳/大小/sha256（E 节），二进制不入 git；若课程要求随交付物提交 HAP 文件，请人工指定落点。
4. **probe/ 目录整体移除时机**：（2026-11-19：release 包已在路由层屏蔽探针页，不影响上架；目录是否物理移除仍待拍板）PROBE_SPEC.md:24 约定「交付打包前整体移除 probe/」（u0-1/u0-2 报告 ⑦ 亦引用为 U7.3 挂起项）。本单元按零探针改动红线**未执行**，且会话#2 待跑 15 项仍依赖探针页，现在移除会阻断验收——建议会话#2 全部通过、整机回归完成后，由人工拍板移除并重新出包。
5. **管线统一构建门禁的覆写问题**：实测该门禁每轮后以默认模式 assembleHap 覆写 `entry/build/default/outputs/default/`（09:44/10:08 两次，证据链见 E 节时间线），必然使磁盘产物偏离 T7 登记。可选收敛：门禁改用 `--build-mode release` 或独立输出目录（不覆写 outputs/default），或接受「终局登记=人工在全部构建活动结束后执行 §F.1 一次」（E 节约定第 3 条）——属基础设施决策，移交人工拍板。

## H. 附录：配置零改动声明（本单元验证不改清单）

| 文件 | 本会话核对 | 结论 |
|---|---|---|
| build-profile.json5 | 实读 :3-31 | signingConfigs `default`（HarmonyOS/SHA256withECDSA/keyAlias debugKey）+ products.default 绑定 + targetSdk 6.1.1(24)/compatibleSdk 6.1.0(23) 均就绪，**零改动** |
| entry/build-profile.json5 | 实读 :14-28 | release buildOptionSet 在位、obfuscation enable:false，**零改动** |
| AppScope/app.json5 | 实读 | versionCode 1000000 / versionName 1.0.0 / vendor example 维持，**零改动** |
| entry/src/main/module.json5 | grep 实测 :7-45 | deviceTypes 含 2in1、4 权限（INTERNET/KEEP_BACKGROUND_RUNNING/PREPARE_APP_TERMINATE/READ_PASTEBOARD）、backgroundModes dataTransfer 齐备，**零改动** |
| entry/src/main/ets/probe/ | 目录核对 | 未新增未修改（交付类单元无探针；移除时机见 openQuestion #4） |

> 注：本表为 U7.3 会话（2026-10-11）时点的零改动核对快照。**2026-10-12 包名更名批次已改变其中两项**：build-profile.json5 signingConfigs（2026-10-17 重签回填新包名 Profile，F.4 第 2 条）、AppScope/app.json5 bundleName→`com.neuohos.xdm`/vendor→neuohos（E 节第 5 条）——以该两处登记为准。
