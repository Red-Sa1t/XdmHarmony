# XDM 鸿蒙迁移风险深挖报告

> 版本：源码深挖收敛版（v3，2026-09-22）
> 调研基础：本地源码四路并行深挖 + 网络官方证据
> 结论：**GO**（约 60% 纯逻辑可翻译 / 25% 可重设计 / 15% 明确降级）
> 配套文档：[迁移计划](./MIGRATION_PLAN.md)

---

## 1. 调研方法与信息源

### 1.1 本地源码深挖（四路并行，逐文件分析）

| 路 | 范围 | 关键产出 |
|---|---|---|
| A：XDM.Core 总清点 | 44 根文件 + 16 子目录 | 平台依赖热点全表、HttpServer 协议、存储方案、Config 44 键 |
| B：下载引擎 | Downloader 全部 + MediaParser + YDLWrapper | 分段算法/线程模型/落盘方式/HTTP 依赖清单/ffmpeg 与 yt-dlp 真实用法 |
| C：UI 与系统集成 | XDM.Wpf.UI + XDM.Gtk.UI + NativeMessaging/App.Host/Updater/Interop.WinHttp | 窗口清单、Win32 依赖、IPC 双通道、功能全集 35 项映射 |
| D：浏览器扩展 | chrome-extension + firefox-amo 全部 JS | 完整消息协议（8 路由 + JSON 字段）、嗅探规则链、接管机制 |

### 1.2 网络官方证据

| 证据 | 来源 | 要点 |
|---|---|---|
| 鸿蒙电脑浏览器扩展支持 | 华为官方支持文档《鸿蒙电脑华为浏览器安装已下载的扩展（即：插件）》consumer.huawei.com/cn/support/content/zh-cn16082289/ | 适用笔记本、HarmonyOS 5.0+；∷ > 管理扩展程序 > 开发者模式 > 加载已解压的扩展程序（选 manifest.json 所在层）或拖拽 .crx |
| OpenHarmony FFmpeg 官方适配 | gitcode.com/openharmony-sig/tpc_c_cplusplus（原 gitee 仓库已归档迁移）`thirdparty/FFmpeg` | 版本 n6.0；已适配解码/编码/转码/复用/解复用/过滤；hap 包集成文档 docs/hap_integrate.md；配套 x264/libvpx/fdk-aac/opus 等 |
| 剪贴板监听 | OpenHarmony 官方文档 js-apis-pasteboard | `SystemPasteboard.on('update')` 公开 API（API 7+）；API 15 新增文件粘贴进度 |
| XDM 仓库侦察 | raw.githubusercontent.com + cdn.jsdelivr.net（github.com 直连被墙） | master = C#/.NET `XDM_CoreFx.sln`；README 的 Maven 说明是 2018 经典版 7.x 遗留 |

## 2. 源码深挖关键发现（改变设计的事实）

1. **原版 HLS 引擎不解密**：`HlsParser.cs:106-122` 只接受 AES-128/identity，其余（含 SAMPLE-AES）返回 null；下载器 `CreateChunk` 完全忽略 KeyUrl/IV——加密 HLS 直接拒绝，live 不支持。→ 对等功能**无需实现解密**（AES-128 解密列为可选增强）。
2. **ffmpeg 调用面极窄**（`FFmpegMediaProcessor.cs`）：仅 3 种命令——①音视频合并 `-i f1 -i f2 -acodec copy -vcodec copy -map 0 -map 1`（纯 remux）②concat（已弃用）③转 MP3 `-acodec libmp3lame`；无版本要求，只看退出码；进度用 stdout 正则解析 `time=`。→ NAPI 封装面最小化。
3. **yt-dlp 仅做元数据探测**（`YDLProcess.cs`）：命令 `--no-warnings -q -i -J [--cookies-from-browser] URL`，输出 JSON 格式清单给 4 页视频向导，**不做下载**。→ 降级影响面最终确认：仅损失"粘贴页面链接"分支，浏览器播放中视频的抓取走扩展嗅探与此无关。
4. **分段算法 = 动态分裂**（`PieceGrabber.cs` + `HTTPDownloaderBase.cs:405-466`）：启动单 Piece 发 `Range: 0-` 探测；206 则 resumable 并回填总长；之后每次找剩余量最大且 >256KB 的分片对半分裂；分片读完但响应未结束时吸收相邻分片复用连接（`ContinueAdjacentPiece`）。并发上限 = MaxSegments（默认 8）。无 ETag/If-Range，仅 Content-Length 校验（`SingleSourceHTTPDownloader.cs:510-517`）；强制 `Accept-Encoding: identity`。
5. **落盘模式与我们设计同构**：每分片独立临时文件（`TempDir/<pieceId>`，OpenOrCreate + Seek 追加，32KB 缓冲）；完成后按 Offset 排序、5MB 缓冲顺序拼接。无预分配、无单文件随机写。
6. **DualHttp 不是双连接下载**：是 DASH 的渐进式变体——两个 URL 分别为音频轨+视频轨，各自分片，最后 ffmpeg 合并。
7. **浏览器扩展协议完整破译**（可直接复用）：本地应用 = HTTP 服务端（127.0.0.1:8597），8 路由：
   - `GET /sync` → 下发 `{enabled, fileExts[], blockedHosts[], tabsWatcher[], videoList[], requestFileExts[], matchingHosts[], mediaTypes[], urlPatterns[]}`
   - `POST /media`（嗅探上报）：`{url, file(tab标题), requestHeaders{name:[v]}, responseHeaders{name:[v]}, cookie, method, userAgent, tabUrl, tabId}`
   - `POST /download`（接管下载）：`{url, cookie, requestHeaders{User-Agent,Referer}, responseHeaders{Content-Length,Content-Type}, filename, fileSize, mimeType}`
   - `POST /vid {vid}`、`/clear {}`、`/tab-update {tabUrl,tabTitle}`、`/link`（批量）、`/args`（单实例参数转发）
   - MV3 保活：12 个错峰 alarm 组合实现 ≈5s 轮询（规避 alarm 最小 1 分钟限制）；接管机制 = `chrome.downloads.onDeterminingFilename` → cancel + erase → POST /download
   - 嗅探规则链（request-watcher.js `isMatchingRequest`）：blockedHosts 排除 → 扩展名命中 → URL 正则 → Content-Type 含 mediaTypes 子串 → Content-Disposition 扩展名 → host 白名单（**无大小阈值**）
8. **架构 UI 可插拔**：XDM.Core/UI 定义 30+ `I*View` 接口 + 平台无关控制器；WPF/Gtk 双实现证明解耦（GTK 剪贴板即退化用 1s 轮询）。→ ArkUI 作为"第三平台 UI"按契约实现。
9. **四套 HTTP 栈**：WinHttp P/Invoke（Windows 默认）/ net4x / net6 DotNetHttpClient / wininet（全注释）。**DotNetHttpClient 是跨平台参考模型**（忽略 TLS 证书校验、identity 编码、Cookie 注入、NetworkCredential 认证、MaxConnectionsPerServer=100）。
10. **存储全可替换**：downloads.db（SQLite 单表）/ settings.dat / {id}.state / {id}.info / queues.db（均为手写二进制 + 自制事务 IO TransactedIO 双备份）→ RelationalStore + preferences + JSON，无需兼容原格式。
11. **平台依赖热点清单**（重写时全部绕开）：winhttp.dll P/Invoke 27 处、注册表（开机自启 HKCU Run、Chrome 查找 HKCR）、Windows 命名管道 IPC（native host）、全局命名 Mutex、SetThreadExecutionState、SHGetKnownFolderPath；**net6/Gtk 路径已提供跨平台分支，Windows 专属多处已注释**（NativeMessaging 三个 Configurer 全文注释、IpcServer 废弃）。
12. **单实例机制**：全局 Mutex `Global\XDM_Active_Instance` + 二实例把命令行 POST 到 `http://127.0.0.1:8597/args` 后退出。→ 鸿蒙应用天然单实例 + Want 传参。
13. **Config 配置键全表 44 项**（Config.cs:44-228）：通知/浏览器监控/语言/深色主题/最近文件夹/重试(MaxRetry=10, RetryDelay=10)/并发(MaxParallelDownloads=3)/视频扩展名/拦截主机/剪贴板监视/最小视频大小/超时(30)/最大分段(8)/限速/完成后关机/保持唤醒/完成后命令/杀毒/代理/双击行为/开机自启/下载目录/分类/凭据等 → Phase 4 设置页对照。

## 3. 功能 × 技术 × 鸿蒙映射完整矩阵

### 3.1 🟢 纯逻辑直接翻译（~60%）

| 功能 | 原实现 | 参考源位置 | 迁移方式 |
|---|---|---|---|
| 分段下载算法 | C# 动态分裂 + 相邻吸收 | Progressive/ | ArkTS 逐行翻译 |
| 断点续传状态机 | Piece 字典 + 事件持久化 | HTTPDownloaderBase.cs:557-618 | JSON 持久化 |
| HLS 解析 | 手写逐行解析器 | MediaParser/Hls/HlsParser.cs | ArkTS 翻译（BYTERANGE/MAP/MEDIA-SEQUENCE） |
| DASH 解析 | System.Xml XmlDocument | MediaParser/Dash/MpdParser.cs | `@ohos.util.xml` 重写（拒绝 dynamic/DRM=对等） |
| 限速 | 睡眠补偿数学 | SpeedLimiter.cs | 算法照搬，sleep 改异步 |
| 队列/调度 | QueueManager/Scheduler | XDM.Core 根 | ArkTS 事件驱动 |
| 嗅探规则服务端 | VideoUrlHelper 39.6KB + JsonMessageParser | BrowserMonitoring/ | ArkTS 翻译（配合 /sync 下发） |
| 扩展协议处理 | IpcHttpMessageProcessor 15.4KB | BrowserMonitoring/ | BridgeServer 逐端点复刻 |
| 22 个对话框控制器 | 平台无关 UIController | XDM.Core/UI/ | 按契约接 ArkUI 视图 |
| 批量下载/链接刷新/分类/导入导出 | 纯逻辑 | XDM.Core 各处 | 直接翻译 |

### 3.2 🟡 需重设计但有官方对应物（~25%）

| 功能 | 原实现 | 鸿蒙方案 | 风险点与验证 |
|---|---|---|---|
| HTTP 栈 | WinHttp/net6 双栈 | @ohos.net.http（DotNetHttpClient 为模型） | 流式/206/identity/8 并发 → **P0 验证**；备选 rcp |
| 浏览器接管 | chrome.downloads API | 扩展直接复用 | **华为浏览器 downloads API 是否开放 → P0 实测**；退化=仅嗅探+popup 手动下载 |
| ffmpeg | Process.Start 命令行 | 官方 n6.0 NAPI 静态集成 | 封装层自研（面已最小）+ HAP 体积 → P0 spike |
| 剪贴板监听 | Win32 消息链 / GTK 1s 轮询 | `pasteboard.on('update')` | ✅ 已验证，优于原版 |
| 持久化 | SQLite + 手写二进制 | RelationalStore + preferences + JSON | 低 |
| 单实例 | 全局 Mutex + /args | 应用天然单实例 + Want | 低 |
| 拉起应用 | xdm+app:// 协议 | module.json5 skills 深链 | 低（可选 UX） |
| 托盘 | NotifyIcon / StatusIcon | 鸿蒙 PC 托盘 API 待查 | 退化：任务栏 + 常驻通知 |
| TLS 证书放行 | 校验回调全放行 | 不可设 | 接受保真度差异（自签站点失败） |
| Digest 认证 | NetworkCredential 自动协商 | Basic 原生 + Digest 手写质询解析 | 可后补/降级 |
| 每分片 Thread+锁 | 裸 Thread + ReaderWriterLockSlim | TaskPool + 主线程单点状态 | P0 验证 TaskPool 内 http 可用性；架构可退化为全事件驱动 |
| 二进制序列化 | BinaryWriter 手写 | JSON | 无需兼容，低 |

### 3.3 🔴 平台专属，明确降级（~15%）

| 功能 | 原实现 | 降级方式 |
|---|---|---|
| yt-dlp 粘贴链接探测 | 外部二进制 -J | 不做；视频向导保留嗅探分支 |
| 系统代理自动检测 | WinHttpGetIEProxyConfig + WPAD/PAC | 仅手动代理配置 |
| NTLM/Negotiate 认证 | WinHttpSetCredentials | 不做（Basic+Digest 覆盖大多数场景） |
| GitHub 自动更新 | GitHub Releases API | 鸿蒙应用市场模式 |
| 完成后关机/自定义命令/杀毒 | shutdown/dbus/Process.Start | 移除 |
| 保持 PC 唤醒 | SetThreadExecutionState/caffeinate | 移除（后台长时任务覆盖下载场景） |
| MSIX 打包/启动跳板 | MsixPackaging/AutoLaunch | 移除 |
| 开机自启 | 注册表 Run / startupTask | 视鸿蒙 API 调研，可降 |
| Chrome Native Messaging 宿主 | 命名管道 + stdio | 移除（扩展走 HTTP 桥不需要） |

## 4. 风险登记册（最终版）

| # | 风险 | 等级 | 状态 / 缓解 / 退化路径 |
|---|---|---|---|
| 1 | 华为浏览器 `downloads.onDeterminingFilename` 不可用 → 下载接管失效 | 中 | P0 用真实扩展实测；退化=仅嗅探 + popup 手动下载（视频抓取主功能不受影响）；其余 6 项权限（webRequest/cookies/tabs/contextMenus/alarms/storage）同为 P0 实测项，扩展加载能力已被华为官方文档证实 |
| 2 | @ohos.net.http 流式/206/identity/并发不符预期 | 中 | P0 脚本验证（Range 0- 探测 + 8 并发 + 流式落盘）；备选 rcp（Remote Communication Kit） |
| 3 | ffmpeg NAPI 封装工作量 + HAP 体积 | 中 | 官方 n6.0 + hap 文档；调用面仅 3 命令；P0 spike；体积可裁编解码器 |
| 4 | TaskPool 内 http 模块可用性 | 低-中 | P0 验证；退化=全主线程事件驱动（并发请求天然并行，分段不依赖线程） |
| 5 | PC 模拟器不预装华为浏览器 | 中 | 扩展端真机补验；服务端 + 脚本模拟扩展流量先开发 |
| 6 | TLS 证书放行不可实现 | 低 | 接受保真度差异，报告声明 |
| 7 | Digest 认证手写复杂度 | 低 | Basic 先行，Digest 后补或降级 |
| 8 | 托盘/自启 API 不确定 | 低 | 退化：任务栏 + 常驻通知；P0 调研 |
| 9 | tpc_c_cplusplus 仓库迁移 | 已知 | 产物从 gitcode.com 新址获取 |
| 10 | GPL-2.0 传染性 | 已定论 | 衍生作品分发须 GPL-2.0；课程内使用无碍；报告声明 |
| 11 | 工作量超时（8-12 周） | 中 | 阶梯降级：P5 末（5-6 周）核心可交付版；P6/P7 各功能面独立可裁 |
| 12 | 学生验收能力弱 + AI 编码 | 中 | 可观察行为验收清单（杀进程续传等）+ 每 Phase tag + arkts_check/hvigor 强制门禁 |

### 已消除的风险（本轮深挖成果）

- ~~HLS 需实现 AES 解密~~（原版本就不解密，对等即可）
- ~~ffmpeg 调用面不确定~~（仅 3 命令）
- ~~UI 层盲重写~~（30+ 接口契约存在，照契约实现）
- ~~ArkTS 无 XML 库~~（@ohos.util.xml 现成）
- ~~扩展协议不确定~~（8 路由 + 字段规格书在手）
- ~~yt-dlp 影响面~~（仅探测场景，主功能无关）
- ~~剪贴板监听能力~~（on('update') 优于原版 GTK 轮询）
- ~~浏览器扩展能否加载~~（华为官方文档证实）
- ~~ffmpeg 鸿蒙可用性~~（OpenHarmony SIG 官方适配）

## 5. Phase 0 五项验证方案（GO 前最后闸门）

1. **扩展完整栈**：模拟器/真机加载真实 XDM MV3 扩展 → 逐项验证 webRequest(onSendHeaders/onHeadersReceived+extraHeaders)、cookies.getAll、downloads.onDeterminingFilename+cancel、contextMenus、alarms、tabs → demo HAP 绑 8597 应答 /sync 验证连通
2. **HTTP 能力**：脚本化验证 requestInStream 流式 + `Range: 0-` 探测 + 206 判定 + identity 编码 + 8 并发 + 重定向/Cookie 注入/超时
3. **ffmpeg spike**：官方 n6.0 产物集成空工程，NAPI 跑通 remux + libmp3lame
4. **环境**：PC 模拟器可用性 + 是否预装华为浏览器
5. **辅助 API**：托盘、fs 随机写、rcp（备选网络栈）

**判定规则**：1-3 全绿 → 完整推进；1 失败 → 浏览器集成退化（嗅探模式）继续；2 失败 → 切 rcp；3 失败 → DASH 降级、HLS 单轨保留。**任何组合下核心下载器（P1-P5）均不受影响。**

## 6. 结论

**GO（推荐推进）**：

1. 招牌功能链完整可行——多线程分段下载（纯逻辑翻译）+ 浏览器视频抓取（扩展加载官方证实 + 协议规格书在手 + 扩展可直接复用）
2. 剩余最高风险仅两个（downloads API、http 流式细节），均有 P0 实测方案与退化路径
3. 架构发现（UI 契约、跨平台 HTTP 参考模型、算法与设计同构）系统性降低重写风险
4. 15% 降级项全部是外围平台功能，核心下载器 100% 可对等

**工作量诚实评估**：引擎 + 核心 ~2-3 万行 ArkTS + UI ~1 万行 ArkUI；8-12 周（AI 编码 + 每周 10-15h 人工验收）。
