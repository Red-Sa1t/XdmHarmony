# U1.2 单线程下载+主列表+新建对话框 · 模块设计书

> 单元：U1.2（Phase 1 第 2 单元，M1 里程碑单元；探针单元 ID `P1-U2`，slug `u1-2-single-thread-download-list-dialog`）。
> 来源：xdm-migrate 工作流"模块设计师"角色，2026-09-28。
> 依据：MIGRATION_PLAN §5 结构 / §6 决策 2（事件流替代阻塞读）、决策 9（206 强校验、重定向回写最终 URL、Cookie 原始串注入、超时 30s/MaxRetry 10/RetryDelay 10s、identity）、决策 11（@Observed+@ObjectLink 列表）；UNIT_CATALOG U1.2 行（验证 [A]+[P]）；PROBE_SPEC v1；U0.2 结论（http 栈主线：requestInStream dataReceive/dataEnd 分块回调；rcp 无分块流回调仅备选）；U1.1 既有面（DownloadRecord/DownloadStore/RecordMapping/Config，设计书 §3.2 次序约束锚）；单元指令六项 + 补充约束；源码研究结论（facts + openQuestions）。
> 对照源码（本会话只读核实，未改 resourses/ 下任何文件）：`SingleSourceHTTPDownloader.cs`（:33/:49/:71-104/:111-151/:272/:330-483/:510-517/:519-530）、`PieceGrabber.cs`（:68-140/:142-157/:159-217/:219-255/:257-366/:368-397/:436-447/:449-452）、`HTTPDownloaderBase.cs`（:104-130/:210-215/:268-305/:544-555）、`WebRequestExtensions.cs`（:15-29/:72-86）、`DotNetHttpClient.cs`（:84-87/:121-150/:189-202）、`DotNetHttpSession.cs`（:26-32/:76-78/:94-98）、`HttpResponse.cs`（:16-32 ContentRangeLength=GetTotalLengthFromContentRange）、`Utils.cs:9-15`、`ErrorCode.cs:9-19`、`Config.cs:52-54/:100/:102/:120/:510-514`、`Application.cs`（:43-63/:104-116/:117-145/:290-331）、`ApplicationCore.cs`（:161-162/:382-387/:415-424）、`UI/INewDownloadDialog.cs:9-24`、`UI/NewDownloadDialogUIController.cs`（:37-73/:149-214）、`Util/Helpers.cs:45-56`、`Util/FileHelper.cs`（:15-20/:88-130/:107-124）、`Util/FormattingHelper.cs:9-41`、`Lang/English.txt`（:21-22/:46/:50-52/:56/:59/:78-79）、`Wpf.UI/Dialogs/NewDownload/NewDownloadWindow.xaml.cs:29-40`。
> API 核实（本机 SDK 6.1.1(24) d.ts，本会话执行 grep/sed）：`@ohos.net.http.d.ts`——usingCache:223、readTimeout:289、connectTimeout:311、maxRedirects:592、header?: Object:267、requestInStream(url,options?):Promise<number>:2222、destroy():2241、on/off headersReceive:2286/2311、on dataReceive:2361、on dataEnd:2411、dataReceiveProgress:2468、ResponseCode.OK=200:2767、PARTIAL:2881、HttpResponse{result:3632/responseCode:3682/header:3704/cookies:3726/performanceTiming:3740}（**无最终 URL 字段**）；`@ohos.file.fs.d.ts`——accessSync:653、lseek:3509、closeSync:817、mkdirSync(recursion):4080、moveFileSync:4898、openSync:5456、renameSync:6597、rmdirSync:6786、statSync:7061、unlinkSync:7658、writeSync:7978、WhenceType.SEEK_SET=0:11719。

## 0. 冲突与拍板注记（必读）

1. **研究事实 1 与事实 3 的重试分类矛盾（本会话源码重读澄清）**：fact 1 按 PieceGrabber.cs:98-106 读出"HttpException 携带已定义 status → DownloadException(InvalidResponse) 立即上抛（终态）"；fact 3 写"4xx/5xx 进重试循环被吞后计数"。两者对应**两条真实平台后端**：WinHttp 路径 Send 直接抛 HttpException→defined→立即 InvalidResponse 终态；**计划 §5 指定的参考模型 DotNetHttpClient**（.NET 6）路径——Send 内 `response.EnsureSuccessStatusCode()`（System.Net.Http 版，:140-147）对 4xx/5xx 抛 HttpRequestException 被 Send 吞掉、`session.Response=null`，回到 Connect():177 的 XDM 版 EnsureSuccessStatusCode 时 `Response!.StatusCode` 空引用→generic catch→**吞掉重试直至 MaxRetryFailed**。本设计拍板：**取 WinHttp 语义**（status 已收到且 ∉{200,206} → InvalidResponse 立即终态，不重试），理由：①与 fact 1 的 catch 分类读法一致；②与 XDM 实际发行版（Windows/WinHttp）用户体验一致；③避免 404 白白重试 10×10s。差异记 §4-D5。connect 阶段传输异常（DNS/拒连/超时 2300028 等，未拿到 status）→ 重试类，sleep(RetryDelay) 后重试（PieceGrabber.cs:118-124 connectPhase 语义）。
2. **重定向回写最终 URL 降级（决策 9 既定降级 + 研究 high 风险项）**：本机 d.ts:3607-3760 已核实 HttpResponse 仅 result/responseCode/header/cookies/performanceTiming，无最终 URL 字段；maxRedirects:592 仅限次数、不能关闭自动跟随。按研究 openQuestion 1 建议**降级实现**：PrimaryUrl/state.Url 恒保持原始 URL（续传重走重定向链，功能等价）；文件名以对话框输入为准（FileNameFetchMode.None 语义）。P1-U2 探针 S2 用 HttpClient 直接观测 `on('headersReceive')` 是否在 3xx 跳点触发（echo-server /redirect→/final 回显法，U0.2 S5 同款补偿）——若触发则 Phase 2 前可恢复 1:1 回写，结论回写计划。
3. **module.json5 / main_pages.json 不动（有据，非遗漏；研究 openQuestion 2 关闭）**：本会话复核 `XdmHarmony/entry/src/main/module.json5`——deviceTypes=["phone","2in1"]（:7-10）、requestPermissions=[ohos.permission.INTERNET]（:14-18）已由 U0.1 落地；U1.2 无新能力（后台长时任务/剪贴板/深链分属 U5.x）。main_pages.json 现有 `pages/Index`+`probe/ProbeIndex`（本会话读文件核实），NewDownloadDialog 走 CustomDialog 不注册页。两文件均**不列入 files 清单**（U1.1 §0-6 同口径：无改动不产无意义 diff）；编码时若发现权限缺失报错（异常态），上报主流程而非擅自改配置。
4. **单元指令"暂停/取消"的语义归一**：原版引擎只有**一个停止语义** HTTPDownloaderBase.Stop（:109-130：stopRequested 防重入→cancelFlag.Cancel→grabber.Stop(Abort 当前请求+释放写流)→OnCancelled→状态 Stopped，临时文件保留供续传）。U1.2 Downloader 暴露单一 `stop()`；UI"暂停"按钮即 stop。**cancel 不设独立入口**（若设，cancel 与 stop 行为逐字节相同，属注册死 API）；Phase 3 QueueManager 的"移除下载"语义另有入口。差异记 §4-D7。
5. **进度落库节奏修正**：研究 fact 4 摘要写"进度落库每 2s"，本会话核实源码实况：2s 门（HTTPDownloaderBase.cs:282-285）是 **SaveChunkState（分片状态文件 chunks.db）** 的节流；DB 的 `UpdateDownloadProgress` 走 Application.UpdateProgress（Application.cs:323-331），由 **ProgressChanged 事件驱动，即 >500ms 进度门（:288）每触发一次就写一次库**。U1.2 保真：每个 >500ms 进度事件 → `store.updateProgress(id, progress)` 一次（fire-and-forget）+ @Observed 字段更新。2s 门 U1.2 无载体（无 chunks.db，U2.2 落），记 §4-D8。
6. **Content-Range"偏移校验"的双检**：单元指令"暂停后 Range: bytes=N- 恢复+206 与 Content-Range 偏移校验"。原版 Connect()（:194-202）实际校验两条：非首请求 status 必须 206（否则 NonRetriable 'Resume not supported'）+ **Content-Range 总长 ≠ state.FileSize** → NonRetriable 'Content length mismatch'（总长取法已核实：HttpResponse.ContentRangeLength=GetTotalLengthFromContentRange=ContentRangeHeaderValue.Length='/' 后 total，HttpResponse.cs:29+DotNetHttpSession.cs:94-98；IsFileChangedOnServer SingleSourceHTTPDownloader.cs:510-517 做 FileSize 比对）。"偏移匹配"原版靠请求端（AddRange(offset+downloaded,·)，PieceGrabber.cs:393-394）隐式保证。本设计按单元指令**显式加第三条**：Content-Range start==请求偏移 N（防御性 hardening，期望表可观测）——记 §4-D9。
7. **CD 文件名三正则链延后（研究 fact 11 + openQuestion 3）**：U1.2 文件名恒来自对话框（原版 FileNameFetchMode.None 语义=用户改过名不覆盖），无嗅探来源。本单元只落 `sanitizeFileName`（显式无效字符枚举）与 `fileNameFromUrl` 最小推导（UrlChanged 自动填充用）；`GetContentDispositionFileName` 三正则链 + MIME 扩展名表完整翻译移至 U6.x 嗅探单元。差异记 §4-D6。
8. **探针驱动模型**：探针页只调业务公开 API（HttpClient/Downloader/DownloadStore），引擎自身**零 [XDM_PROBE] 输出**（业务禁探针红线，U1.1 §3.3 同源）；HTTP status/206/Content-Range/偏移等引擎内部事实经 **Downloader 事件接口**（对照原版 PieceConnected/ProgressChanged/Finished/Cancelled 事件面）由探针监听器采集，EXPECT 判定全在 verify 工作流。UI 渲染（对话框文案、进度条滚动、按钮）不进探针，走手册人工走查节。
9. **测试源双轨（openQuestion：4MiB 源在快链路上暂停步存在竞态）**：默认源沿用 P0-U2-echo-server.js /big.bin（4MiB 确定性字节流+Range 206，单元指令指定）；为使"暂停→Range 恢复"步骤**确定性落地**，新增配套 `docs/probe/P1-U2-download-server.js`：含同规格 /big.bin、**/slow.bin?ms=40**（每 64KB 块延迟 40ms，64 块≈2.6s，暂停窗口充足）、/redirect+/final（S2 重定向观测）。手册默认指 /slow.bin，EXPECT 对 pauseLanded=false（快源跑赢暂停）设 UNVERIFIED 分支。

## 1. 目标文件清单（按实现顺序）

| # | 文件 | 新/改 | 职责 | 对外导出 | 依赖 |
|---|---|---|---|---|---|
| 1 | `entry/src/main/ets/core/net/HttpProtocol.ets` | 新 | **纯传输协议函数层（零 @kit import，Hypium 可加载）**：六键默认头构造（SingleSourceHTTPDownloader.cs:519-530 逐键）、Referer 目录形式推导（new Uri(url,".") 语义）、206/200 白名单判定（WebRequestExtensions.cs:15-29）、isCompressed（Utils.cs:9-15）、Content-Range 解析（total='/'后 + start/end，对齐 ProbeHttpLogic.parseContentRange 语义）、resume Range 头格式化、isUriValid（Helpers.cs:45-56 端口） | `sixDefaultHeaders`、`refererOf`、`isSuccessStatus`、`isCompressed`、`parseContentRange`、`ContentRangeParts`、`resumeRangeHeader`、`isUriValid` | 无 |
| 2 | `entry/src/main/ets/core/util/FileNames.ets` | 新 | **纯文件名函数层（零 @kit import）**：sanitizeFileName（FileHelper.cs:15-20 语义：取最后一段分隔符后替换无效字符；显式枚举 `\\/:*?"<>|` 与 ASCII 控制符→'_'）、fileNameFromUrl（FileHelper.cs:88-130 最小集：路径末段，空→host '.'→'_'；MIME 表延后）、getUniqueFileName（FileHelper.cs:107-124：name_1.ext 递增，存在性探测用回调注入保纯度） | `sanitizeFileName`、`fileNameFromUrl`、`getUniqueFileName` | 无 |
| 3 | `entry/src/main/ets/core/util/Formatting.ets` | 新 | **纯格式化函数层（零 @kit import）**：formatSize（FormattingHelper.cs:21-41：1024 阶梯 K/M/G :F1 一位小数、<=0 '---'、<1024 整数 B）、formatSpeed（=formatSize(speed)+"/s"，Application.cs:309）、toHMS（FormattingHelper.cs:11-19：HH:MM:SS 两位补零） | `formatSize`、`formatSpeed`、`toHMS` | 无 |
| 4 | `entry/src/main/ets/core/engine/EngineMath.ets` | 新 | **引擎纯规则层（零 @kit import）**：EngineError（extends Error，ArkTS 有限 throw 合规）+ 错误码常量（值对照 ErrorCode.cs:9-19：GENERIC=1/NON_RESUMABLE=2/MAX_RETRY=4/INVALID_RESPONSE=5/DISK_ERROR=8）+ retriable 标志构造器 + 进度节流数学纯函数（HTTPDownloaderBase.cs:288-299 1:1：instantSpeed 整除/avgSpeed 浮点/eta 向上取整）+ 500ms 门判定 + 重试上限判定 | `EngineError`、`ERR_GENERIC`、`ERR_NON_RESUMABLE`、`ERR_MAX_RETRY`、`ERR_INVALID_RESPONSE`、`ERR_DISK_ERROR`、`instantSpeedBps`、`avgSpeedBps`、`etaSeconds`、`shouldEmitProgress`、`exceedsMaxRetry` | 无 |
| 5 | `entry/src/main/ets/core/net/HttpClient.ets` | 新 | **纯传输层（对照 DotNetHttpClient 参考模型）**：单请求封装 http.HttpRequest——open(url,headers) 走 requestInStream 回传 status+headers（headersReceive 捕获全量到数组）、dataReceive 分块回调、dataEnd 门+15s 硬顶兜底（ProbeHttp.ets:56-57 END_GATE_TIMEOUT_MS 模式）、abort()=destroy() 立即断流（等价 request.Abort）+ 生成代自增、usingCache:false、connectTimeout/readTimeout=Config.getNetworkTimeout()×1000=30000ms、**不含任何下载语义**（无文件/进度/重试/Range 生成） | `HttpClient`、`HttpResponseHead` | #1、@kit.NetworkKit、@kit.BasicServicesKit、@kit.PerformanceAnalysisKit、../Config |
| 6 | `entry/src/main/ets/core/engine/Downloader.ets` | 新 | 单线程下载引擎（对照 SingleSourceHTTPDownloader+PieceGrabber 主链路，§3.1 状态机）：start/resume/stop + 重试循环（MaxRetry 10/RetryDelay 10s/连接期 sleep）+ 206/Content-Range 三检 + 32KB→分块落盘 + 500ms 进度事件 + EOF/断流续传 + 完成拼接收尾（uniqueName→rename→清 temp）+ **零 DB 依赖**（DB 写全在事件消费方，对照 Application 层）+ 事件接口 | `Downloader`、`DownloadEvents`、`NoopDownloadEvents` | #1 #2 #4 #5、../../model/*（DownloadRecord/DownloadTypes）、../db/RecordMapping（joinTempDir）、@kit.ArkTS(util)、@kit.CoreFileKit、@kit.BasicServicesKit、@kit.PerformanceAnalysisKit、../Config |
| 7 | `entry/src/main/ets/components/NewDownloadDialog.ets` | 新 | 新建下载对话框（@CustomDialog，INewDownloadDialog 契约最小子集 §5.7）：URL/文件名输入+目录只读展示+Download Now/Cancel+两条 MSG 校验（AlertDialog）+UrlChanged 自动推导文件名+FileNameFetchMode 值设置 | `NewDownloadDialog`（@CustomDialog struct） | #2 #3、../model/DownloadRecord+DownloadTypes、../core/Config、../core/db/DownloadStore、../core/engine/Downloader |
| 8 | `entry/src/main/ets/pages/Index.ets` | 改 | 主列表页（Navigation 根 + Tabs 双列表）：aboutToAppear 先 await initialize()（U1.1 §3.2 次序约束）再 queryAll 填充；@Observed+@ObjectLink 驱动进度；持有 Map<string,Downloader>；CustomDialogController 挂新建对话框；事件消费方（progress→record+updateProgress 落库；finished→markAsFinished+列表迁移；failed→updateStatus） | `Index`（@Entry） | #3 #6 #7、../model/*、../core/db/DownloadStore、../core/Config |
| 9 | `entry/src/main/ets/probe/units/ProbeDownloadLogic.ets` | 新 | P1-U2 纯函数层（零 @kit import）：确定性字节流锚（BLOCK_SIZE=65536、expectedByteAt(offset)=floor(offset/65536)%251，与 P0-U2-echo-server.js:27-33 同值）、spotOffsets 抽查点集、文件字节抽查比对助手 | `BLOCK_SIZE`、`expectedByteAt`、`SPOT_OFFSET_COUNT`、`spotOffsetAt` | 无 |
| 10 | `entry/src/main/ets/probe/units/ProbeDownload.ets` | 新 | P1-U2 探针页（S1~S9，§6 步骤表）：TextInput 测试源（autoStart=false，ProbeHttp 同构）+ ProbePage 编排 + 会话代际守卫；S3~S7 驱动 Downloader 全链（监听器采集引擎事实），S2 用 HttpClient 直测重定向观测，S8 列表快照，S9 重启核对（runSingle 手动） | `ProbeDownload`（struct） | #5 #6 #9、../core/ProbeKit+ProbePage、../../core/db/DownloadStore、../../model/* |
| 11 | `entry/src/main/ets/probe/ProbeIndex.ets` | 改 | PROBE_UNITS 注册表追加 `{unitId:'P1-U2'}`；else-if 分支追加 `ProbeDownload()` | —（@Entry 页） | #10 |
| 12 | `entry/src/main/resources/base/element/string.json` | 改 | 追加业务文案 10 键（§2.5）+ 探针 3 键（既有 21 键不动，纯 JSON 禁尾逗号） | —（资源） | 无 |
| 13 | `entry/src/test/HttpProtocol.test.ets` | 新 | 传输协议纯函数 Hypium 用例（11 条，§7-[A]-3） | testsuite 注册函数 | #1 |
| 14 | `entry/src/test/EngineMath.test.ets` | 新 | 引擎纯规则 Hypium 用例（10 条，§7-[A]-3） | testsuite 注册函数 | #4 |
| 15 | `entry/src/test/FileNameFormat.test.ets` | 新 | 文件名+格式化 Hypium 用例（13 条，§7-[A]-3） | testsuite 注册函数 | #2 #3 |
| 16 | `entry/src/test/ProbeDownloadLogic.test.ets` | 新 | 确定性字节锚 Hypium 用例（4 条，§7-[A]-3） | testsuite 注册函数 | #9 |
| 17 | `entry/src/test/List.test.ets` | 改 | testsuite 注册 #13~#16（既有三条注册保留） | `testsuite` | #13~#16 |
| 18 | `docs/probe/P1-U2-download-server.js` | 新 | 主机侧测试源（Node≥14 零依赖单文件，启动指引同 P0-U2 手册口径）：/big.bin（4194304B 确定性流+Range 206）、**/slow.bin?ms=40**（分块延迟，暂停步确定性）、/redirect→/final（回显 url/cookie，S2 观测） | —（脚本） | #9（字节锚同值） |
| 19 | `docs/probe/PROBE-u1-2-single-thread-download-list-dialog.md` | 新 | 探针运行手册：echo 服务器启动指引（复用 P0-U2 口径）+ 测试 URL 可替换参数 + 人工 UI 走查节 + 重启两段式（AI hdc 自动 + 人工兜底双轨，U1.1 同款） + 预期序列表 | —（文档） | #10 #18 |
| 20 | `docs/probe/EXPECT-u1-2-single-thread-download-list-dialog.json` | 新 | 机器可读预期表（BEGIN+S1~S9+SUMMARY+END 共 12 条目，JSON.parse 校验） | —（JSON） | #19 |

**显式不动的文件**：`module.json5`（§0-3）、`main_pages.json`（§0-3）、`entryability/EntryAbility.ets`（U1.1 挂接已就绪，本单元无需改）、`core/db/*`、`model/*`、`probe/core/*`（isCurrent/END_GATE/ProbePage 编排直接复用）、既有 probe/units/ 三文件。**红线**：`pages/Index.ets`、`components/*`、`core/**` 的 import 图不得出现 `probe/`。

## 2. 数据模型与表结构（对照源码逐一核对）

### 2.1 数据层零改动（U1.1 面 1:1 消费）

- **downloads 表 22 列 DDL 不动**（DownloadStore.ets:32-36）；本单元写路径：`add`（对话框确认时，completed=0 强制已内建 :160-162）、`updateProgress`（每 >500ms 进度事件）、`updateStatus`（失败/停止时）、`markAsFinished`（完成收尾，SQL 对照 DownloadList.cs:340-341，bindArgs 序 folder,file,finalSize,1,id）；读路径：`queryAll`/`getDownloadById`/`queryInProgress`/`queryFinished`。
- **DownloadRecord 16 字段 + 运行时字段消费表**：

| 字段 | U1.2 写入方 | 时点 | 对照 |
|---|---|---|---|
| id / dateAdded / primaryUrl / targetDir / proxy / authentication | newDownloadRecord 工厂（对话框确认） | 新建时 | Application.AddItemToTop :43-63 |
| name | 对话框输入经 sanitizeFileName | 新建时 | SingleSourceHTTPDownloader.cs:49 TargetFileName=SanitizeFileName(info.File) |
| size | UI 事件消费方（onConnected totalSize>0 时）；markAsFinished 终值 | 连接后/完成 | PieceConnected :238-241 + DownloadFinished :126-127 |
| status | updateStatus（Stopped/Finished 值经 store）| 停止/完成 | Application.DownloadFailed :105 / —（完成走 completed 列） |
| progress | UI 事件消费方 + updateProgress 落库 | 每进度事件 | UpdateProgressOnUI :315 |
| fileNameFetchMode | 对话框（用户改过名=None(0)，否则 FileNameAndExtension(1)） | 新建时 | NewDownloadDialogUIController.cs:184 |
| maxSpeedLimitInKiB | 0（恒默认；限速 U3.2） | — | SpeedLimiter.cs:49 `if (speedLimit<1) return` → 0 即天然 no-op |
| downloadSpeed / eta | UI 事件消费方（字符串派生：formatSpeed/toHMS） | 每进度事件 | UpdateProgressOnUI :316-317 |
| downloadedBytes（运行时） | Downloader 内部主写（dataReceive 累计）；事件携带 | 引擎期 | HTTPDownloaderBase.cs:271-273 totalDownloadedBytes+piece.Downloaded |
| tempDir（运行时） | Downloader 构造时 joinTempDir(Config.getTempDir(), id) | 引擎期 | SingleSourceHTTPDownloader.cs:33 |

- **重启后历史可见的持久真值**：completed=0 行读回强制 Stopped（R2 强制规则）+ progress 列；已完成行 kind=Finished。U1.2 重启**不恢复引擎**（续传状态机恢复属 U2.2，chunks.db 尚不存在），进行中列表展示 Stopped 行即可满足验收"历史可见"。

### 2.2 引擎会话态（Downloader 实例字段，非持久化）

| 字段 | 类型 | 对照 |
|---|---|---|
| pieceId | string（util.generateRandomUUID()，start/resume 各生成一次） | SingleSourceHTTPDownloader.Start :84-91 Piece{Id=Guid} |
| pieceFile | string = tempDir/pieceId | HTTPDownloaderBase.GetPieceFile :210-214 |
| fileSize / totalSize | number（-1 未知） | state.FileSize / this.totalSize :238-241 |
| resumable | boolean（=!compressed && status===206） | CreateProbeResult :441 |
| compressed | boolean（isCompressed 头判定） | PieceGrabber.cs:181-188 |
| downloadedBytes / writtenBytes | number（累计已收/已落盘，单写者=引擎循环） | piece.Downloaded + 写流位置 |
| fd | number（-1 关闭） | targetStream :233-236 |
| generation | number（会话代际，stop() 自增；旧续体/回调过守卫即弃） | cancelFlag + ProbeKit.isCurrent 模式（ProbeKit.ets:150-152） |
| stopRequested | boolean（防重入） | HTTPDownloaderBase.cs:111-115 |
| timesRetried | number | PieceGrabber.cs:24/:113-117 |
| ticksAtStartOrResume / lastProgressUpdatedAt / lastDownloadedAt / bytesSinceStartOrResume | number（进度数学游标） | HTTPDownloaderBase.cs:268-305 |

### 2.3 HttpClient 值对象

```
HttpResponseHead { status: number; header: Record<string, string> }   // header 键小写归一由 headerOf 式取法兼容（不改变原头大小写，读取用不区分大小写取法）
```
HttpClient 另持有 `headsReceived: HttpResponseHead[]`（headersReceive 每次触发 append 一条——S2 重定向观测的载体，业务无害）。

### 2.4 string.json 新增键（对照 English.txt 行号锚）

| 键 | 值（base） | 对照 |
|---|---|---|
| nd_title | New Download | English.txt:59 |
| nd_address | Address | :50 |
| nd_file | File | :51 |
| lbl_save_in | Save in | :52 |
| nd_download_now | Download Now | :56 |
| nd_cancel | Cancel | :46 |
| msg_invalid_url | Download address is invalid or unsupported | :78 |
| msg_no_file | Please enter file name | :79 |
| lbl_active | Active | :21（ALL_UNFINISHED，进行中页签） |
| lbl_complete | Complete | :22（ALL_FINISHED，已完成页签） |
| probe_p1u2_title | 下载链路探针（P1-U2） | 探针页标题 |
| probe_p1u2_source_hint | 测试源地址（主机局域网 IP，如 http://192.168.1.20:8080） | 同 probe_http_source_hint 口径 |
| probe_p1u2_restart_hint | 完成后杀进程重启应用，再回到本页点击 S9 核对历史 | S9 手动提示 |

## 3. 关键算法翻译说明

### 3.1 下载状态机（PieceGrabber.Download2 → async 循环，逐分支对照）

```
start()/resume() → launchDownloadLoop(resumeMode)
  ├─ 准备：OnStarted（对照 Start():99/Resume():122 双路径，R2-F1）；mkdir tempDir(recursion)；
  │    resume 时 statSync(pieceFile) 校验存在，缺失→转全新 start（对照 Resume :139-143 无 pieces→Start）
  ├─ openSync(pieceFile, READ_WRITE|CREATE)（不带 TRUNC——OpenOrCreate+Seek 等价）
  │    resume 时 lseek(fd, writtenBytes, SEEK_SET)（对照 targetStream.Seek(piece.Downloaded) :236）
  └─ while (!generation 过期)：
       attempt（首请求 Range: bytes=0-，续传 Range: bytes={N}-（单分片 end 省略，对照 AddRange(0)/AddRange(off,·) :387-395））
       ├─ open 成功拿到 status：
       │    ├─ !isSuccessStatus(status) → EngineError(INVALID_RESPONSE, retriable=false)【§0-1 拍板】
       │    ├─ compressed（isCompressed）→ totalSize=-1、resumable=false、206 视作 200（:181-188 防御）
       │    ├─ 非首请求：status!==206 → INVALID_RESPONSE 终态（:194-197 原版抛
       │    │             NonRetriableException(ErrorCode.InvalidResponse)；R2-F4 修正：NonResumable(2)
       │    │             仅 :169-170 piece.Length==-1 分支可达，单分片移植不可达）
       │    │             + parseContentRange：total!==fileSize → INVALID_RESPONSE 终态 'Content length mismatch'（:198-202）
       │    │             + start!==请求偏移 → INVALID_RESPONSE 终态（§0-6 单元指令新增硬ening）
       │    └─ 每次连接成功：onConnected(status,totalSize,resumable,contentType)（对照 PieceGrabber.cs:205
       │       PieceConnected 每连接回调；探测值仅首请求携带——:234 注释，R2-F2 修正：本节原写
       │       "仅首请求"与 §6/EXPECT S6 的二次 onConnected 矛盾；续传回调 totalSize=-1/resumable=206 观测）
       ├─ body：dataReceive → writeSync(fd,chunk) 累计 writtenBytes/downloadedBytes；每块后节流进度（见 3.2）
       ├─ dataEnd 门（Promise.race[dataEnd, 15s 硬顶, abortGate]）：
       │    ├─ dataEnd 且 (fileSize<=0 || writtenBytes-fileSizeAtStart === 期望) → 正常收尾
       │    ├─ dataEnd 但已收 < 期望 → Unexpected EOF → 重试类（x==0 分支 :287-290 是 DownloadException→generic 吞→重试，续传续跑）
       │    └─ 15s 超时无 dataEnd（断流挂起防御）→ 重试类（END_GATE_TIMEOUT_MS 模式，ProbeHttp.ets:56-57）
       ├─ 收尾（唯一出口）：closeSync → mkdir(targetDir,recursion) → getUniqueFileName → renameSync(pieceFile→finalPath)
       │    （rename 失败 catch → moveFileSync 兜底，跨挂载防御）→ rmdirSync(tempDir)+逐文件 unlinkSync（catch 吞，
       │    对照 DeleteFileParts :544-555 try/catch）→ onFinished(finalSize=statSync(finalPath).size)
       └─ catch 分类（对照 Download2 :93-124）：
            ├─ generation 过期（stop）→ 静默 return（OnCancelled 已在 stop() 发出）
            ├─ EngineError.retriable===false → onFailed(errorCode) 终态
            ├─ 其余（连接期/EOF/断流）→ timesRetried++；exceedsMaxRetry(timesRetried,10) → onFailed(MAX_RETRY)
            │   连接期失败（status 未到手）→ await sleep(retryDelay×1000=10000ms, 与 abortGate race)（:118-124）
            │   body 期失败 → 立即重试（无 sleep，续传 Range）
```

- **错误分类映射**（§0-1 拍板）：EngineError{code, retriable} 单类承载原版三异常——INVALID_RESPONSE(206 缺失，:194-197 原版即 InvalidResponse——R2-F4 修正)/INVALID_RESPONSE(Content-Range 不匹配)/DISK_ERROR(写盘 13900xx)/INVALID_RESPONSE(4xx/5xx) 为 retriable=false（NonResumable(2) 仅 :169-170 piece.Length==-1 分支可达，单分片移植不可达）；Unexpected EOF/断流/超时 2300028/DNS 拒连为 retriable=true。`catch (e)` 不带注解、`e as BusinessError` 取 code（ArkTS 规则）。
- **Range 头格式**：`bytes=0-`（首）/`bytes=N-`（续传，N=writtenBytes）；单分片无上界（对照 AddRange(start) 单参 :168-177 与 :393-394 的闭区间差——单分片 length=-1 时走 open-ended，等价原版单分片实际行为）。

### 3.2 进度节流数学（HTTPDownloaderBase.cs:288-299 1:1，纯函数进 EngineMath）

```
每块落盘后（UpdateDownloadedBytesCount :268-305）：
  ticks = Date.now()                          // D11 口径：TickCount→Date.now（U1.1 同源差异）
  2s 门（SaveChunkState）→ U1.2 无 chunks.db 载体，跳过（§4-D8，U2.2 落）
  if (ticks - lastProgressUpdatedAt > 500 && ticksElapsed > 0):   // 500ms 门
    instantSpeed = instantSpeedBps(totalDownloaded - lastDownloaded, ticks - lastProgressUpdatedAt)
                 = floor(deltaBytes * 1000 / deltaMs)                    // C# 整除
    avgSpeed    = avgSpeedBps(bytesSinceStartOrResume, ticksElapsed) = bytes*1000.0/elapsedMs  // 浮点
    progress    = computeProgress(totalDownloaded, fileSize)      // 复用 U1.1 RecordMapping.computeProgress（C# 整除 floor 已锁）
    eta         = etaSeconds(fileSize, totalDownloaded, avgSpeed)
                 = fileSize<=0 ? 0 : avgSpeed<=0 ? 0 : ceil((fileSize-downloaded)/avgSpeed)   // avgSpeed<=0 守卫为 ArkTS 加固（C# 对 0 除得 Infinity 再 (long) 强转，行为未定义）
    lastProgressUpdatedAt=ticks; lastDownloaded=totalDownloaded
    → events.onProgress(id, progress, instantSpeed, eta, totalDownloaded)   // 事件消费方再做 UI 字符串派生 + DB 落库
```

### 3.3 线程模型：C# 裸 Thread → 主线程异步事件循环（TaskPool 映射预留）

- 原版：每分片裸 Thread（PieceGrabber.Download :62-66）+ 阻塞 `sourceStream.Read`（32KB BUF）+ ReaderWriterLockSlim。决策 2 已定 Phase 2 映射：SegmentWorker 走 TaskPool、dataReceive 事件流替代阻塞读、pieces 主线程单点管理消除锁。
- **U1.2 取映射的"单分片退化"**：引擎循环跑在主线程事件循环（async/await）；`dataReceive` 回调即"读"原语，`writeSync` 同步落盘（64KB 级块，无 UI 可感卡顿）；无锁（单写者=循环本体，@Observed 字段只在事件回调内变更）。**禁用 TaskPool** 的理由固化在代码注释：@Observed DownloadRecord 不可跨线程（非 Sendable），进度若经 worker 序列化回传需要整层消息协议——该协议正是 U2.1 SegmentWorker 的交付物，U1.2 不预建。
- **挂起防御三件套**（下载循环同样要防断流挂起，单元指令点名）：①`abortGate`（stop() resolve）与 open/dataEnd/sleep 全部 Promise.race——destroy() 后 requestInStream 的 Promise **不保证 settle**，无 abortGate 则旧循环协程永久泄漏；②END_GATE_TIMEOUT_MS=15000 硬顶（ProbeHttp.ets:56-57 同值模式）；③generation 守卫贯穿：循环每轮开头/每个 await 恢复后/事件回调入口/收尾前，`generation!==currentGen` 即静默 return（五守卫点模式，ProbePage.ets:77-113 同构）。

### 3.4 完成拼接收尾（AssemblePieces 单分片退化，SingleSourceHTTPDownloader.cs:330-483）

- SortAndValidatePieces 退化：单分片无需排序；targetDir 空→Config.getDownloadDir()（对话框已写入 record.targetDir，此处防御）；`Directory.CreateDirectory`→`mkdirSync(dir, true)`；AutoRename（Config.cs:510-514 枚举默认 AutoRename=0，属性未显式初始化即 0）→ `getUniqueFileName(name, dir)`（FileHelper.cs:107-124：存在探测循环 name_N.ext；**存在性探测回调注入**保纯函数——引擎侧闭包包 accessSync，测试侧注入假表）。
- 5MB 缓冲精确 len 拼接（:344-407）退化：单分片且 piece 文件即完整内容 → **renameSync(pieceFile→finalPath)**（fs d.ts:6597；本机同卷 filesDir 内）失败 catch → `moveFileSync`（:4898）兜底 → 再失败按 DISK_ERROR 终态。原版提前 EOF='File corrupted' 分支（:386-391）在 rename 退化下不存在（无二次拷贝）——记 §4-D10。
- DeleteFileParts（:544-555，`Directory.Delete(recursive)`）：rename 已移走分片文件 → `unlinkSync` 残留文件（防御）+ `rmdirSync(tempDir)`，整段 try/catch 吞掉（catch 内记日志，不改变结果）。
- FetchServerTimeStamp（LastModified 回写，:461-468）U1.2 不落（fs 无直接 mtime 设置 API，价值低）——记 §4-D11。
- markAsFinished 触发链：**引擎零 DB**；`onFinished(id, finalSize, filePath)` 事件消费方（Index/探针监听器）调 `store.markAsFinished(id, finalSize, basename(filePath), dirname(filePath))`（对照 Application.DownloadFinished :117-125 取 Path.GetFileName/GetDirectory）+ 列表迁移。原版随后 GetDownloadById+UpdateDownloadEntry 双写（:126-145）在 U1.2 为净零效果（size 列 add 时 0 → 两写均落 finalSize；name/targetDir 对话框已定）——完整双写链随 U3.1 DownloadManager 落，记 §4-D12。

### 3.5 对话框控制器翻译（NewDownloadDialogUIController → @CustomDialog 回调）

| 原版 | ArkTS |
|---|---|
| message-null 分支剪贴板预填（:57-64） | **不移植**：剪贴板监视属 U5.2（pasteboard 权限面本单元不引入）；URL/文件名全手输，UrlChanged 自动推导文件名（:65-72）保留 |
| IsUriValid 校验（:153-157）→ MSG_INVALID_URL | DownloadNow 回调内 `isUriValid(url)`（HttpProtocol 纯函数）→ `getUIContext().showAlertDialog({message: $r('app.string.msg_invalid_url'), ...})`（ShowMessageBox 等价；promptAction 全局已废弃，走 UIContext） |
| 文件名空校验（:158-162）→ MSG_NO_FILE | 同上 msg_no_file |
| FileNameFetchMode 值（:184：SelectedFileName!=fileName ? None : FileNameAndExtension） | 对话框内 fileNameTouched 标志（TextInput onChange 置位）；新建记录时按同式设 record.fileNameFetchMode（U1.2 引擎不消费该值，字段保真） |
| DisposeWindow（:213） | controller.close() |
| SetFileSizeText | U1.2 无 message 来源 → 不展示文件大小行（§3.5 第一行同源裁剪），函数面不预留 |
| SetFolderValues/SeletedFolderIndex（:18-35） | 目录恒 Config.getDownloadDir() 只读展示（Phase 5 DocumentViewPicker 接管，单元指令"最小子集"） |
| DownloadLater/QueueScheduler/UrlBlocked 事件（:98-106/:78-91） | 契约裁剪：队列/黑名单属 U3.1/U6.x，不注册死事件 |

### 3.6 Index 列表页骨架（决策 11 + 红线）

- `Navigation(this.pathStack) { ... }` 根容器（pathStack 备 Phase 4 NavDestination 路由，本单元无子页）；页签 `Tabs{ TabContent(进行中 ForEach inProgress) / TabContent(已完成 ForEach finished) }`。
- 子组件 struct `DownloadListItem`（**同文件内非导出**，Phase 4 拆独立文件为机械移动）：`@ObjectLink record: DownloadRecord`——行内 Progress（value=record.progress）+ name/formatSize(size)/formatSpeed/instantSpeed/eta（record.downloadSpeed/eta 字符串字段）。**UI 只读渲染**：record 字段变更只发生在 Downloader 事件回调（主线程单写者），@ObjectLink 一级属性变更自动刷新；ForEach 键=record.id（稳定），结构预留 LazyForEach/IDataSource 替换点（Phase 4）。
- 行按钮：进行中行 暂停/继续（按 record.downloadedBytes>0 分派 stop()/resume()，经 Index 的 downloader Map 查找）；已完成行无按钮（Phase 4 补齐删除/打开）。
- **初始化次序**（U1.1 设计书 §3.2 引用锚兑现）：`aboutToAppear` → `await DownloadStore.getInstance().initialize(ctx)` → `queryAll()` 填双列表；initialize 失败（ready 门 rejected）→ 列表留空 + 业务日志（对照 C# LoadDownloadList try/catch，Application.cs:332-341）。
- 新建对话框：`CustomDialogController({ builder: NewDownloadDialog({...}) })`；确认回调链 = 校验（3.5）→ `newDownloadRecord(sanitizedName, targetDir, 0, null, url, false, null, null)` → 覆盖 `record.fileNameFetchMode` → `store.add(record)` → `new Downloader(record, this)` 持入 Map → `start()` → push 进行中列表 → controller.close()。对照 Application.StartDownload 语义（ApplicationCore.cs:296-298 挂事件 + AddToTop）。

## 4. 有意差异清单（对照源码/计划，含已定降级项）

| # | 差异 | 依据 |
|---|---|---|
| D1 | **重定向后回写最终 URL 降级**：PrimaryUrl/state.Url 恒保持原始 URL；续传重走重定向链（功能等价）；headersReceive 3xx 跳点观测入探针 S2，若可观测则 Phase 2 前恢复 1:1 回写 | 决策 9 既定降级；d.ts:3607-3760 无最终 URL 字段（本会话核实）；研究 openQuestion 1 |
| D2 | HTTP 栈：WinHttp/DotNet 双后端 → @ohos.net.http 单栈（requestInStream 事件流） | U0.2 结论（http 主线，dataReceive/dataEnd 分块回调；rcp 无分块流回调）+ 决策 2 |
| D3 | TLS 证书错误全放行（ServerCertificateCustomValidationCallback :56）不复刻 | 计划 §3 降级 8 |
| D4 | AutomaticDecompression=All（:52）无对应物 → 强制 Accept-Encoding: identity + isCompressed 防御保留（compressed→总长-1/禁续传/206 视作 200） | 决策 3/9；PieceGrabber.cs:181-188 |
| D5 | 4xx/5xx → InvalidResponse **立即终态**（WinHttp 语义），不复刻 DotNet 路径的"null 会话→空引用→重试至 MaxRetry"退化 | §0-1 拍板（fact 1/fact 3 矛盾澄清） |
| D6 | 文件名解析最小集：sanitizeFileName+fileNameFromUrl 落地；CD 三正则链+MIME 扩展名表延后 U6.x；sanitizeFileName 修正原版 `Split('\\')` 覆盖 `'/'` 分割的死赋值语义（FileHelper.cs:17-18）为"最后一段分隔符取段" | 研究 fact 11 + openQuestion 3；U1.1 D3 同口径（不复刻 bug） |
| D7 | 停止语义单入口 stop()（暂停/取消同源）；cancel 不设独立入口 | §0-4（原版 Stop 单语义，HTTPDownloaderBase.cs:109-130） |
| D8 | 2s SaveChunkState 门无载体跳过（chunks.db 属 U2.2）；DB 进度落库为每 >500ms 进度事件一次 | §0-5（源码实况：Application.cs:323-331 逐事件写库） |
| D9 | Content-Range start==请求偏移显式校验（新增硬ening；原版仅 206+total 两检，偏移靠请求端隐式保证） | §0-6（单元指令"偏移校验"显式化） |
| D10 | AssemblePieces 5MB 缓冲拼接 → 单分片 renameSync 退化；'File corrupted' 提前 EOF 分支不存在（无二次拷贝）；moveFileSync 兜底为平台防御 | §3.4；研究 fact 7 |
| D11 | FetchServerTimeStamp（LastModified→文件 mtime 回写）不落 | fs 无 mtime 设置 API；价值低（原版受 Config.FetchServerTimeStamp 开关控制） |
| D12 | 完成链 markAsFinished 单写（原版 MarkAsFinished+GetDownloadById+UpdateDownloadEntry 双写）；完整链随 U3.1 | §3.4（U1.2 下净效果相同：add size=0） |
| D13 | 剪贴板 URL 预填不移植（U5.2）；SetFileSizeText 不预留（无 message 来源） | §3.5（契约最小子集，单元指令口径） |
| D14 | TaskPool 不用于 U1.2（主线程异步事件循环）；SegmentWorker 协议 U2.1 交付 | 决策 2 映射的单分片退化；@Observed 非 Sendable 不可跨线程 |
| D15 | Helpers.TickCount → Date.now()（墙钟，非单调钟） | U1.1 D1 同口径 |
| D16 | Cookie 注入同主机语义（手动 Cookie 不跨主机转发；d.ts 无 enableAutoCookie，起始版本 26>24） | U0.2 S5 结论；原版无此限制，公网跨主机重定向场景差异 |
| D17 | avgSpeed<=0 → eta=0 守卫（C# 对 0 除 → Infinity → (long) 强转未定义行为） | ArkTS 加固 |
| D18 | 测试源新增 P1-U2-download-server.js（/slow.bin 分块延迟），非源码对照物（测试基建） | §0-9（暂停步确定性） |
| D19 | 恢复请求发 open-ended `bytes=N-`（原版单分片恢复恒为闭区间 `bytes=N-{total-1}`，PieceGrabber.cs:393-394） | 对合规服务器行为等价（206、Content-Range start==N，S6 只校 start）；独立复核勘误：原设计书"单分片 length=-1 走 open-ended"论据不成立——恢复时 Length 已置 ResourceSize，此为平台等价简化 |
| D20 | onFailed 对 InvalidResponse 且 totalDownloadedBytes>0 未映射 SessionExpired(9)（原版 HTTPDownloaderBase.cs:498-501） | U1.2 无 UI 消费该码；U3.x 接错误文案时补映射（独立复核遗留，届时处理） |
| D21 | 未知大小下载（fileSize=-1）中断后移植版继续尝试 Range 续传，原版 :169-170 直接 NonResumable 终态 | 服务器 200 → InvalidResponse(5) 终态、206 但 total 不可解析 → start 检终态，终态可达性与源码不同；U2.3 单测覆盖该分支 |

## 5. 各文件实现要点（可直接照做的接口面）

### 5.1 core/net/HttpProtocol.ets（纯，零 @kit）

- `export function sixDefaultHeaders(url: string): Record<string, string>`——逐键对照 SingleSourceHTTPDownloader.cs:519-530：`User-Agent`=Config FallbackUserAgent 默认值字面量 `'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/97.0.4692.99 Safari/537.36'`（Config.cs:52，**常量内联本模块**，勿引 Config 保持零依赖）、`Accept: */*`、`Accept-Encoding: identity`、`Accept-Language: en-US`、`Accept-Charset: *`、`Referer=refererOf(url)`。
- `export function refererOf(url: string): string`——`new Uri(url, ".").ToString()` 语义：scheme://host 后取最后一个 '/'（含）前缀且保证尾 '/'；无路径 → host 尾 '/'。纯字符串实现（indexOf/lastIndexOf），禁正则字面量。
- `export function isSuccessStatus(status: number): boolean`——status===200 || status===206（WebRequestExtensions.cs:15-29；数字字面量配 d.ts ResponseCode.OK=200:2767/PARTIAL:2881 注释锚）。
- `export function isCompressed(header: Record<string, string>): boolean`——content-encoding 与 transfer-encoding（不区分大小写取键）值小写化后 `indexOf('gzip')>=0 || indexOf('deflate')>=0`（Utils.cs:9-15）。
- `export interface ContentRangeParts { start: number; end: number; total: number }`；`export function parseContentRange(value: string): ContentRangeParts`——语义对齐 ProbeHttpLogic.ets:66-91（业务侧独立实现，禁 import probe/）：'bytes N-M/total' 三元；`*/total`→{-1,-1,total}；无 '/' 或非法→{-1,-1,-1}。
- `export function resumeRangeHeader(offsetBytes: number): string`——`'bytes=' + String(offsetBytes) + '-'`。
- `export function isUriValid(url: string): boolean`——Helpers.cs:45-56 端口：空/无 '://'→false；scheme 小写比较仅 http/https；host 段非空。纯字符串，try/catch 包裹。

### 5.2 core/util/FileNames.ets（纯，零 @kit）

- `export function sanitizeFileName(name: string): string`——先取最后一段（`lastIndexOf('/')` 与 `lastIndexOf('\\')` 取较大者切尾段，§4-D6 修正）；无效字符 `\\ / : * ? " < > |` 与 0x00-0x1F 逐字符替换 '_'（显式枚举 switch/contains，禁正则字面量）；空结果兜底 `'file'`。
- `export function fileNameFromUrl(url: string): string`——FileHelper.cs:88-130 最小集：去 query/hash → 路径末段 decodeURIComponent（try/catch 包裹，失败用原值）→ sanitize；空 → host 段 '.'→'_'。
- `export function getUniqueFileName(file: string, dir: string, exists: (path: string) => boolean): string`——FileHelper.cs:107-124：count 递增 `name_N.ext`；纯函数（exists 注入），引擎侧传 `(p: string): boolean => accessSync(p)` 闭包。

### 5.3 core/util/Formatting.ets（纯，零 @kit）

- `formatSize(length: number): string`（GB=1073741824/MB=1048576/KB=1024，>GB `${x:F1}G` 依序，<=0 `'---'`，否则 `${Math.floor(length)}B`——FormattingHelper.cs:21-41 逐分支；一位小数用 `(x).toFixed(1)`）；
- `formatSpeed(bytesPerSec: number): string` = `formatSize(bytesPerSec) + '/s'`（Application.cs:309）；
- `toHMS(sec: number): string`（hrs/min/sec 整除+`padStart(2,'0')`，FormattingHelper.cs:11-19；负数守卫 0）。

### 5.4 core/engine/EngineMath.ets（纯，零 @kit）

- `export const ERR_GENERIC=1 / ERR_NON_RESUMABLE=2 / ERR_MAX_RETRY=4 / ERR_INVALID_RESPONSE=5 / ERR_DISK_ERROR=8`（ErrorCode.cs:9-19 序位锚，注释逐条注明）。
- `export class EngineError extends Error { readonly code: number; readonly retriable: boolean; constructor(code: number, retriable: boolean, message: string) { super(message); ... } }`（arkts-limited-throw 合规：仅 Error 子类可 throw）。
- `instantSpeedBps(deltaBytes, deltaMs)`: deltaMs<=0→0，否则 Math.floor(deltaBytes*1000/deltaMs)。
- `avgSpeedBps(bytes, elapsedMs)`: elapsedMs<=0→0，否则 bytes*1000.0/elapsedMs（浮点）。
- `etaSeconds(fileSize, downloaded, avgSpeed)`: fileSize<=0||avgSpeed<=0→0，否则 Math.ceil((fileSize-downloaded)/avgSpeed)。
- `shouldEmitProgress(ticksNow, lastUpdatedAt): boolean` = ticksNow-lastUpdatedAt>500。
- `exceedsMaxRetry(timesRetried, maxRetry): boolean` = timesRetried>maxRetry（PieceGrabber.cs:114-117 原序：先 ++ 后判，第 MaxRetry+1 次尝试失败才终态）。

### 5.5 core/net/HttpClient.ets（传输层）

```
export interface HttpResponseHead { status: number; header: Record<string, string> }

export class HttpClient {
  private readonly req: http.HttpRequest = http.createHttp();
  private readonly timeoutMs: number;                       // 构造默认 Config.getInstance().getNetworkTimeout()*1000
  private readonly endGate: Promise<boolean>;               // resolve(true)=dataEnd；resolve(false)=15s 硬顶（END_GATE_TIMEOUT_MS=15000 常量同 ProbeHttp.ets:56）
  private headsReceived: HttpResponseHead[] = [];           // headersReceive 逐次 append（S2 观测载体）
  onChunk: (chunk: ArrayBuffer) => void;                    // 调用方 open 前挂；abort 后内部守卫丢弃

  constructor(timeoutMs?: number)
  async open(url: string, header: Record<string, string>): Promise<HttpResponseHead>
      // options: { header, usingCache:false, connectTimeout/readTimeout=timeoutMs }（d.ts:223/289/311；header?:Object:267 接受 Record）
      // requestInStream:2222 的 Promise<number> 即最终 status；head 从 headsReceived 末条取（headersReceive:2286 先于 resolve）；
      // headsReceived 为空（异常路径）→ header 记空 Record 兜底（headsReceivedCount 可观测诊断，不抛错）
  async waitStreamEnd(): Promise<boolean>                   // 返回 endGate 结果（streamClosed 观测）
  getHeadsReceived(): HttpResponseHead[]
  abort(): void                                             // destroy():2241 立即断流（等价 request.Abort，PieceGrabber.cs:146）；off 全部事件；此后 onChunk 丢弃
}
```
约束：**文件/进度/重试/Range 生成禁止入内**（Phase 2 分段重构前提，UNIT_CATALOG U1.2 分层注）；HTTP 头取键不区分大小写（业务侧私有 headerOf 同 ProbeHttpLogic.ets:53-61 语义，独立实现）。

### 5.6 core/engine/Downloader.ets（引擎）

- `export interface DownloadEvents { onStarted(id: string): void; onConnected(id: string, status: number, totalSize: number, resumable: boolean, contentType: string): void; onProgress(id: string, progress: number, instantSpeed: number, etaSeconds: number, downloadedBytes: number): void; onPaused(id: string, offsetBytes: number): void; onFinished(id: string, finalFileSize: number, filePath: string): void; onFailed(id: string, errorCode: number, errorMessage: string): void; }` + `export class NoopDownloadEvents implements DownloadEvents`（空实现，默认参数）。
- `export class Downloader { constructor(record: DownloadRecord, events?: DownloadEvents) ; start(): void ; resume(): void ; stop(): void ; isRunning(): boolean }`——start/resume 为 fire-and-forget（内部 launch 私有 async loop，catch 兜底记 hilog，对照 Thread.Start :62-66/:113-150）；`isRunning` 供 UI 防重复点击。
- 禁止 import：DownloadStore（DB 写全在事件消费方，§3.4）、probe/**。
- 日志：hilog domain 0x0000 tag 'Downloader'（业务通道，绝不 [XDM_PROBE]）。
- 状态可观测：progress 数学所需游标全部私有（§2.2）；对外仅事件——保事件面稳定即 Phase 2 分片化时 UI 零改动。

### 5.7 components/NewDownloadDialog.ets

- `@CustomDialog export struct NewDownloadDialog { controller?: CustomDialogController; onConfirm: (url: string, fileName: string, fetchMode: number) => void = ...; onCancel: () => void = ... }`——内部 `@State url/fileName/fileNameTouched`；目录行只读 Text(Config.getInstance().getDownloadDir())。
- 事件面板：标题 nd_title；nd_address TextInput（onChange→url 变更+isUriValid 时 fileName=fileNameFromUrl(url)（fileNameTouched 未置位才覆盖，对照 :65-72））；nd_file TextInput（onChange→fileNameTouched=true）；lbl_save_in+目录；ND_DOWNLOAD_NOW→校验链（§3.5）→`onConfirm(url, sanitizeFileName(fileName), fileNameTouched ? FileNameFetchMode.None : FileNameFetchMode.FileNameAndExtension)`；nd_cancel→onCancel。
- fetchMode 值对照 NewDownloadDialogUIController.cs:184 同式（**以"初始推导名 vs 当前输入"比较为准**——fileNameTouched 漏标输入场景由初始名比较兜底）。
- MSG 弹窗：`this.getUIContext().showAlertDialog({ message: ..., primaryButton: { value: 'OK', action: ... } })`（等价 ShowMessageBox；具体签名编码时对照 recipes-forms 核实）。

### 5.8 pages/Index.ets（改）

- 删除 Hello World 样板；`@Entry @Component struct Index`；`private pathStack: NavPathStack = new NavPathStack()`（NavPathStack 为全局类型，勿 import）。
- `@State inProgressList: DownloadRecord[] = []`、`@State finishedList: DownloadRecord[] = []`、`private downloaders: Map<string, Downloader> = new Map()`、`private dialogController: CustomDialogController = new CustomDialogController({ builder: NewDownloadDialog({ onConfirm: ... , onCancel: ... }), autoCancel: true })`。
- aboutToAppear：async 初始化序列（§3.6）；`getUIContext().getHostContext()` 取 filesDir 供 initialize（U1.1 探针同款窄化）。
- DownloadEvents 实现（私有方法族）：onProgress→查 record→赋 progress/downloadSpeed=formatSpeed(instantSpeed)/eta=toHMS(etaSeconds)/downloadedBytes + `store.updateProgress(id, progress)` fire-and-forget（catch 记日志）；onConnected→record.size=totalSize>0?totalSize:record.size；onPaused→record.status=Stopped；onFinished→store.markAsFinished + 双列表迁移（splice/push，@State 数组 API 变更自动刷新）；onFailed→record.status=Stopped + store.updateStatus(id, Stopped)（对照 Application.DownloadFailed :104-116）。
- build：Navigation 根 → Row(标题+新建按钮) → Tabs 双列表 → DownloadListItem（@ObjectLink）行内暂停/继续按钮回调 `this.onPauseToggle(record.id)`（Map 查 Downloader：running→stop()，else downloadedBytes>0→resume()）。

### 5.9 probe/units/ProbeDownloadLogic.ets（纯，零 @kit）

- `export const BLOCK_SIZE = 65536`、`export const DOWNLOAD_BYTES = 4194304`（与 P0-U2-echo-server.js:22-23 三处同值锚）；`export function expectedByteAt(offset: number): number` = Math.floor(offset/BLOCK_SIZE) % 251（echo-server makeSlice :27-33 同式）；`export const SPOT_OFFSET_COUNT = 5` + `export function spotOffsetAt(i: number, totalBytes: number, pauseOffset: number): number`——固定抽查集 {0, pauseOffset-1(>0 时), pauseOffset, floor(total/2), total-1}（越界/负值归 0 并由用例锁定）。

### 5.10 probe/units/ProbeDownload.ets（P1-U2）

- `const DOWNLOAD_STEPS: ProbeStepDef[]`：S1~S8 autoRun=true、S9 autoRun=false（runSingle 手动）；页面顶部 TextInput 测试源（autoStart=false，ProbeHttp:489-512 同构惯例）；默认源拼 `/slow.bin?ms=40`（S3~S7）、`/big.bin`（S1）、`/redirect`（S2）。
- 每个 runner 首行捕 runId；每个 await 恢复后、emit 前过 `isCurrent(runId)`（U0.2 五守卫点）；等待类辅助 `awaitUntil(predicate, timeoutMs, pollMs)`（私有方法，轮询 sleep 10ms；超时返 false 由观测键表达）。
- 监听器：struct 持有事实袋（`Array<string>` 已格式化 kvs 片段 + 关键标量字段），Downloader 事件回调**不经 ProbeKit.emit**（事件在步骤中途到达，emit 会破坏"每步骤恰一行"）——各步骤结束统一从事实袋取值 emit。
- DB 断言走 `DownloadStore.getInstance()`（先 await initialize 幂等）。

### 5.11 ProbeIndex.ets / string.json / test 四件（改/新）

- ProbeIndex：import ProbeDownload；PROBE_UNITS 第四项 `{ unitId: 'P1-U2', title: $r('app.string.probe_p1u2_title') }`；else-if 链追加 `else if (this.selectedUnitId === 'P1-U2') { ProbeDownload() }`。
- string.json：§2.4 全 13 键追加（既有 21 键不动，纯 JSON 禁尾逗号）。
- List.test.ets：追加 `httpProtocolTest(); engineMathTest(); fileNameFormatTest(); probeDownloadLogicTest();`（既有三条注册保留）。

## 6. 探针步骤设计（P1-U2，对应手册/EXPECT）

会话形态：**会话 A**（页面输入源 URL 后点"运行全部"，S1~S8 顺序执行）→ 杀进程重启 → 二次拉起 → 点 S9（**会话 B**，单步）。verify 按 runId 取最后会话，两会话各自 BEGIN/SUMMARY/END 配对。

| 步骤 | autoRun | 操作 | 观测点（emit key=value） | 预期锚（EXPECT 判定核心） |
|---|---|---|---|---|
| BEGIN | — | begin(unitId, filesDir) | runId、filesDir | 与 END 按 runId 配对 |
| S1 源能力预检 | ✔ | 探针**自建请求**（不走引擎）GET {base}/big.bin + Range: bytes=0-（requestInStream） | sourceUrl status=206 contentLength=4194304 rangeSupported=true chunks>0 | 测试源 Range 能力成立（S5/S6 判定的环境前提；不成立→env 分流） |
| S2 重定向观测（决策 9 降级补偿） | ✔ | 用**业务 HttpClient**（六默认头）open {base}/redirect → waitStreamEnd → 读 headsReceived 全量 | requestUrl redirectFollowed=true finalStatus=200 headsReceivedCount locationSeen=<Location 或 absent> headersAtRedirect=<true/false> | redirectFollowed=true（栈自动跟随）；**headersAtRedirect = headersReceive 是否在 3xx 跳点触发的直接观测**（true→回写计划恢复 1:1 回写可行性；openQuestion 1 判定输入，不计业务 PASS/FAIL） |
| S3 新建+启动 | ✔ | newDownloadRecord(name='probe-u2-'+runId+'.bin', targetDir=Config.getDownloadDir(), size=0, url={base}/slow.bin?ms=40, startWaiting=false) → store.add（先覆盖 record.id='probe-u2-'+runId，COLD-F1 链路）→ new Downloader(record, 探针监听器) → start() → awaitUntil(onStarted&&onConnected 已达) | recordId addOk=true started=true firstRequestStatus=206 totalSize=4194304 resumable=true tempDirCreated=true pieceFileExists=true | addOk/started=true；totalSize 与源一致；**首请求带 Range: bytes=0- → 源回 206 → resumable=true**（对照 AddRange(0) PieceGrabber.cs:389 + CreateProbeResult :441——206 即原版探测续传能力的机制，U0.2 S2 同款判定） |
| S4 进度滚动 | ✔ | awaitUntil(进度事件数>=5 或 downloadedBytes>=262144) | progressTicks lastProgress lastInstantSpeed lastEta lastDownloaded dbProgress=<getDownloadById 读回 progress 列> recordSynced=<@Observed 字段==事件值> | progressTicks>=1；lastProgress∈(0,100]；dbProgress>0（每事件落库链路）；recordSynced=true |
| S5 暂停 | ✔ | awaitUntil(downloadedBytes>=262144) → stop() → awaitUntil(!isRunning) | pauseLanded=<true/false> pauseOffset=<writtenBytes> tempFileSize=<statSync(pieceFile).size> onPausedFired=true offsetMatchesTemp=<pauseOffset===tempFileSize> | **pauseLanded=false（快源跑赢）→ 该步 UNVERIFIED 分支**（换慢速源重跑，手册注明）；pauseLanded=true 时 offsetMatchesTemp=true 且 0<pauseOffset<4194304 |
| S6 恢复（206 链路） | ✔ | resume() → awaitUntil(onConnected 二次到达 且 已续传) | resumeStatus=206 contentRangeStart=<parseContentRange.start> contentRangeTotal=<.total> requestedOffset=<pauseOffset> startMatches=<contentRangeStart===requestedOffset> totalMatches=<contentRangeTotal===4194304> | **206 链路核心**：resumeStatus=206、startMatches=true、totalMatches=true（三检齐——§0-6）；若 resumeStatus=200 记 UNVERIFIED（源不支持 Range→S1 应已拦截 env） |
| S7 完成+字节抽查+落库 | ✔ | awaitUntil(onFinished 已达, 超时 60s) → 逐抽查点 openSync(finalPath)+readSync(fd,16B,{offset})+closeSync 比对 expectedByteAt → getDownloadById 读回 | finished=true finalSize=4194304 finalFileExists=true tempDirGone=true spotChecks=<5 点逐点 m/o> allSpotsMatch=<true/false> dbKind=1 dbName dbSize=4194304 dbProgress=0 | finished=true、finalSize=4194304、tempDirGone=true（rename+清 temp 收尾）；**allSpotsMatch=true 是 206 续传字节级正确性证据**（若 resume 忽略偏移，pauseOffset 处字节必错位）；dbKind=1/dbSize 一致（markAsFinished 落库链路） |
| S8 列表快照 | ✔ | store.queryAll() + queryFinished() 计数 | inProgressCount finishedCount>=1 finalPathInDb=<targetdir+name 拼接> fileAtPathExists=<accessSync> | finishedCount>=1、inProgressCount 不含 probe id、fileAtPathExists=true（列表数据源就绪；UI 渲染走手册人工走查） |
| S9 重启历史核对（手动） | ✘ | 读 pending 文件（S7 落盘 probe-P1-U2-persist.json：id/finalPath/finalSize）→ getDownloadById + queryFinished 计数 | pendingFound rowFound=true kind=1 sizeMatches=true fileStillExists=<accessSync> | 重启持久核心：rowFound=true 且 kind=1/sizeMatches（对照 P1-U1 S9 两段式） |
| SUMMARY | — | end(ok) 聚合 | 每步关键键单行 <1500B | 12 段齐全 |
| END | — | ok/steps/elapsedMs | ok=true steps=8（会话 A）；S9 单步会话 steps=1 | BEGIN/END 配对 |

- 值卫生：emit 值过 ProbeKit 消毒；URL 不含空格；布尔/数字直写；**不写 PASS/FAIL 词**（headersAtRedirect/pauseLanded 均为观测事实，判定在 EXPECT 分支）。
- 失败形态：步骤异常走 catch emit `errCode/errMessage`（2300028 超时、13900xx 盘错等原始码直接观测）；S3 的 errCode 多指向 store 未就绪或源不可达 → EXPECT 分流 business-code/env。

## 7. 单元验收测试要点

### [A] 静态门禁（编码员每轮自跑）

1. `hvigorw assembleHap` 零 error 零新 warning——ArkTS 严格子集编译期强制；自查对照 arkts-grammar-standards：禁 any/解构/正则字面量（sanitizeFileName 显式字符枚举实现）、对象字面量全带类型（HttpRequestOptions/StoreConfig/DownloadLists/EngineError 构造）、throw 仅 Error 子类（EngineError extends Error）、async 方法显式 `Promise<T>`、Record 字面量引号键、`catch (e)` 无注解 + `e as BusinessError`、成员名不撞通用属性（DownloadListItem 禁 `width/opacity` 命名）。
2. 业务零 probe 依赖：`core/**`、`model/**`、`pages/Index.ets`、`components/NewDownloadDialog.ets` import 图无 `probe/`；`HttpClient.ets`/`Downloader.ets` 无 `db/DownloadStore`（分层红线）与 `[XDM_PROBE]` 字样。
3. 纯函数 Hypium 本地用例（entry/src/test，import 路径从 src/test 出发 `'../main/ets/...'`）：
   - **HttpProtocol.test.ets（11 条）**：sixDefaultHeaders_sixKeysAndValues（逐键值，UA 字面量精确比对）；sixDefaultHeaders_refererDirectoryOfFile（`http://h/a/b?q=1` → `http://h/a/`）；sixDefaultHeaders_refererRootPath（`http://h` → `http://h/`）；sixDefaultHeaders_trailingSlashUnchanged（`http://h/a/` → `http://h/a/`）；isSuccessStatus_200_206_true；isSuccessStatus_302_404_false；isCompressed_gzipDeflate_true（含大小写与 transfer-encoding 分支）；isCompressed_identity_false；parseContentRange_fullForm（'bytes 262144-4194303/4194304'→{262144,4194303,4194304}）；parseContentRange_invalidForms（无 '/'/'bytes */N'/非数字）；isUriValid_httpHttpsOnly（http/https true；ftp/空/无 scheme false）。
   - **EngineMath.test.ets（10 条）**：errCode_values_matchSourceOrder（1/2/4/5/8）；engineError_fields；instantSpeed_floorDivision（(150000,500)→300000）；instantSpeed_zeroElapsed→0；avgSpeed_fractional（(250000,500)→500000.0）；etaSeconds_ceil（(4194304, 2097152, 1048576.0)→2）；etaSeconds_zeroSizeOrSpeed→0；shouldEmitProgress_gate（499→false、501→true）；exceedsMaxRetry_boundary（10→false、11→true，PieceGrabber.cs:114 原序）。
   - **FileNameFormat.test.ets（13 条）**：sanitizeFileName_invalidCharsReplaced（`a<b>:c?"d` → 下划线串）；sanitizeFileName_lastSegmentAfterSlashOrBackslash（`a/b\c/d.txt`→`d.txt`、`e\f.txt`→`f.txt`）；sanitizeFileName_keepsNormalDots；sanitizeFileName_emptyFallback；fileNameFromUrl_pathTail（`http://h/dir/big.bin?x=1`→`big.bin`）；fileNameFromUrl_rootFallsToHost（`http://a.b.c/`→`a_b_c`）；getUniqueFileName_noConflict；getUniqueFileName_increments（注入假 exists 表：name.ext 存在→name_1.ext，name_1 也存在→name_2.ext）；formatSize_ladder（2048→'2.0K'、5MB→'5.0M'、2GB+1→'2.0G'）；formatSize_nonPositiveDash（0/-5→'---'）；formatSize_bytesInteger（999→'999B'）；formatSpeed_suffix（`.../s`）；toHMS_padding（3661→'01:01:01'、0→'00:00:00'）。
   - **ProbeDownloadLogic.test.ets（4 条）**：expectedByteAt_blockPattern（0→0、65535→0、65536→1、131072→2，回环 251 锚）；spotOffsets_fivePoints；spotOffsetAt_clamps（total/offset 边界不越界）；constants_matchServerAnchor（BLOCK_SIZE=65536、DOWNLOAD_BYTES=4194304 与 server 同值）。
4. 诚实注记（U0.2/U1.1 同款）：本设计会话未运行本地单测执行器（工程无 hvigor wrapper、devecocli 无 test 子命令）；用例照常入库，由编码员在 IDE/hvigor LocalUnit 实跑一次并记录，不可用则注明"待 U2.3 统一回归"。

### [P] 运行时（手册承载，xdm-probe-verify 机械判定）

1. 构建+安装+拉起 → 探针首页 P1-U2 卡片 → 输入测试源（默认 `http://<主机局域网IP>:8080`）→ 运行全部 S1~S8，11 标记齐全（BEGIN/S1..S8/SUMMARY/END）。
2. EXPECT 逐条判定：S1 源 206 能力；S2 redirectFollowed=true + headersAtRedirect 观测回写计划；S3 add/启动/totalSize；S4 进度链（事件+落库+@Observed 同步）；S5 暂停偏移与 temp 文件大小一致（pauseLanded=false 走 UNVERIFIED 换源分支）；**S6 resumeStatus=206 + startMatches + totalMatches（验收核心"206 链路"）**；S7 finalSize=4194304 + allSpotsMatch + tempDirGone + dbKind=1；S8 列表快照。
3. 重启历史两段式：AI `hdc shell aa force-stop com.example.xdmharmony` → `hdc shell aa start -b com.example.xdmharmony -a EntryAbility`（人工兜底：桌面图标重启）→ S9 rowFound=true/kind=1/sizeMatches。
4. 人工 UI 走查节（手册 §人工，不计入机械判定）：新建对话框文案（ND_* 五键）+ MSG_INVALID_URL（输 `ftp://x` 触发）+ MSG_NO_FILE（空名触发）+ UrlChanged 自动推导文件名 + 列表实时进度条滚动 + 暂停/继续按钮切换 + 已完成页签可见。
5. 验证环境标注：真机优先（INTERNET 已具备），模拟器兜底；结论与 U0.2/U1.1 同口径写回计划。

## 8. 风险与备注

| 风险 | 缓解 |
|---|---|
| destroy() 后 requestInStream 的 Promise 不 settle → 旧循环协程泄漏 | abortGate 与 open/dataEnd/sleep 全 Promise.race（§3.3 三件套）；探针 S5 反复 start/stop 即其回归场 |
| 快链路下 S5 暂停跑不赢下载 | /slow.bin?ms=40 慢速源为手册默认；EXPECT pauseLanded=false→UNVERIFIED 分支；公网大文件 URL 可替换 |
| headersReceive 在 3xx 跳点的触发行为未知（openQuestion 1） | S2 独立观测不计业务判定；结论回写计划决定 Phase 2 前是否恢复 1:1 回写（D1 预留） |
| readTimeout 对"头已到、体中断流"的覆盖不保证（U0.2 S6 仅证连不上路径） | END_GATE 15s 硬顶兜底 + EOF→重试续传路径；S7 超时 60s 观测兜底 |
| 64KB 块 writeSync 在主线程的 UI 卡顿 | 4MiB 量级 64 块，单次同步写 <1ms；Phase 2 吞吐不足再入 TaskPool（决策 1 预案） |
| 模拟器内 127.0.0.1 回环误解 | 手册沿用 PROBE_SPEC 注：测试源绑 0.0.0.0 + 主机局域网 IP |
| renameSync 跨目录失败（理论：同 filesDir 卷内不会） | moveFileSync 兜底 catch（§3.4）；失败走 DISK_ERROR 终态可观测 |
| updateProgress 每事件写库（>500ms 一次）的写放大 | 量级 2 次/秒，SQLite 可承受；对照源码实况（§0-5）非设计新增 |
| 本地单测执行器不可用 | §7-[A]-4 诚实注记，编码员实跑并记录 |
| U2.x 依赖锚 | 事件面（DownloadEvents）与 HttpClient 抽象即 Phase 2 分片化接口——SegmentWorker 复用 HttpClient、PieceGrabber.ets 复用 EngineMath/HttpProtocol，UI 零改动 |

—— 完 ——
