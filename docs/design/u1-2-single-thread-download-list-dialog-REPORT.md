# U1.2 单线程下载+主列表+新建对话框 · 单元迁移报告

> 单元：U1.2（Phase 1 第 2 单元，M1 里程碑单元）｜探针单元 ID `P1-U2`｜slug `u1-2-single-thread-download-list-dialog`
> 报告日期：2026-09-28｜撰写：迁移报告员（xdm-migrate 工作流"报告员"角色）
> 依据：单元指令 + 研究结论（facts 11 条 / openQuestions 3 条）+ 设计书 `docs/design/u1-2-single-thread-download-list-dialog-DESIGN.md` + 对照审查全史（材料所载第 2/3 轮）+ 独立复核（9 项）+ 门禁结论。
> 证据口径：本报告凡标注"本会话执行/读码核实"者为报告会话一手证据（命令与行号逐一可查）；摘自交付材料（研究结论、审查史、门禁结论）者注明"材料"；未执行的一律如实记"未运行/未核实"，不以推测填充。

---

## ① 单元范围与验收要点

### 1.1 范围（单元指令五项）

1. `core/net/HttpClient.ets` 纯传输层：GET / requestInStream dataReceive 分块回调 / 重定向回写最终 URL / Cookie 原始串注入 / 超时 30s / 回传 status+headers；不含下载语义。
2. `core/engine/Downloader.ets` 单线程下载循环：进度回调 / 暂停 / 取消 / 暂停后 `Range: bytes=N-` 恢复 + 206 与 Content-Range 偏移校验 / 完成拼接 temp→最终文件 + markAsFinished 落库。
3. `pages/Index.ets` 改造为下载列表页（进行中/已完成，实时进度）。
4. `components/NewDownloadDialog.ets`（按 INewDownloadDialog 契约最小子集：URL/文件名/目录/开始/暂停）。
5. 探针 P1-U2 下载链路观测 + 手册与预期表。

验收四条：URL 完整下载到沙箱；列表实时进度；暂停恢复（206 链路）；重启后历史可见。四条均为运行时验收，静态面已全部落地（§5），运行时判定待探针人工运行（§6）。

### 1.2 交付物清单（20 项，本会话逐一核实存在）

| # | 文件 | 新/改 | 状态（材料） | 本会话核实 |
|---|---|---|---|---|
| 1 | entry/src/main/ets/core/net/HttpProtocol.ets | 新 | done | 存在；六键头/refererOf/isSuccessStatus/isCompressed/parseContentRange/resumeRangeHeader/isUriValid 导出齐全（HttpProtocol.ets:23/37/61/110/76/136/142） |
| 2 | entry/src/main/ets/core/util/FileNames.ets | 新 | done | 存在；sanitizeFileName/fileNameFromUrl/getUniqueFileName（FileNames.ets:28/49/81） |
| 3 | entry/src/main/ets/core/util/Formatting.ets | 新 | done | 存在；formatSize/formatSpeed/toHMS（Formatting.ets:15/35/40） |
| 4 | entry/src/main/ets/core/engine/EngineMath.ets | 新 | done | 存在；错误码 1/2/4/5/8 + EngineError extends Error + 进度数学（EngineMath.ets:26-76） |
| 5 | entry/src/main/ets/core/net/HttpClient.ets | 新 | done | 存在；END_GATE_TIMEOUT_MS=15000（:24）、open/waitStreamEnd/abort/getHeadsReceived |
| 6 | entry/src/main/ets/core/engine/Downloader.ets | 新（R2 后修复 5 项） | done | 存在；事件面 :45-52、主循环 :300-478、收尾 :529-578 |
| 7 | entry/src/main/ets/components/NewDownloadDialog.ets | 新 | done | 存在；校验链 :64-78、MSG 弹窗 :85-95 |
| 8 | entry/src/main/ets/pages/Index.ets | 改 | done | 存在；Navigation 根 :274、Tabs 双列表 :288-344、事件消费方 :156-236 |
| 9 | entry/src/main/ets/probe/units/ProbeDownloadLogic.ets | 新 | done | 存在（字节锚纯函数层） |
| 10 | entry/src/main/ets/probe/units/ProbeDownload.ets | 新 | done | 存在（P1-U2 探针页） |
| 11 | entry/src/main/ets/probe/ProbeIndex.ets | 改 | done | P1-U2 注册（:22 单元表、:94 分支） |
| 12 | entry/src/main/resources/base/element/string.json | 改 | done | U1.2 新增 13 键（nd_title…lbl_complete 10 业务键 + probe_p1u2_* 3 探针键），既有 21 键保留 |
| 13-16 | entry/src/test/HttpProtocol/EngineMath/FileNameFormat/ProbeDownloadLogic.test.ets | 新 | done | 用例数 11/10/13/4（grep `it(` 计数核实） |
| 17 | entry/src/test/List.test.ets | 改 | done | testsuite 注册 7 项（:15-21，既有 3 项 + 新 4 项） |
| 18 | docs/probe/P1-U2-download-server.js | 新 | done | 存在（/big.bin、/slow.bin?ms=40、/redirect→/final） |
| 19 | docs/probe/PROBE-u1-2-single-thread-download-list-dialog.md | 新 | done | 存在 |
| 20 | docs/probe/EXPECT-u1-2-single-thread-download-list-dialog.json | 新 | done | 存在；node JSON.parse 校验通过，12 条目（BEGIN+S1~S8+SUMMARY+END） |
| 附 | docs/design/u1-2-…-DESIGN.md | 改（R2 审查要求同步） | done | §3.1 已含 R2-F1/F2/F4 修正注记（:117/:126-133） |

### 1.3 配置红线核查（本会话执行 `cat`/`grep`）

- `entry/src/main/module.json5`：deviceTypes=["phone","2in1"]（:7-10）、requestPermissions=[ohos.permission.INTERNET]（:14-18）——U0.1 已落地，U1.2 无新能力（后台/剪贴板/深链属 U5.x），按设计书 §0-3 **不改**，无无意义 diff。单元指令"当前缺 INTERNET"的表述已过时（研究 openQuestion 2 同结论，关闭）。
- `entry/src/main/resources/base/profile/main_pages.json`：仅 `pages/Index` + `probe/ProbeIndex` 两条；新建对话框走 CustomDialog 不注册页，符合"main_pages.json 只保留 Index 与探针页"约束。

---

## ② 研究结论摘要（关键源码行为→ArkTS 对应表）

"原版行为"列的关键锚点本会话以只读 `sed` 抽查一手复核（PieceGrabber.cs:114-118/194-197/205/389-394、SingleSourceHTTPDownloader.cs:99/:122/:519-530、HTTPDownloaderBase.cs:496-501，均在 `resourses/xdm/` 只读参考树内，未改任何文件）；其余行为锚摘自交付材料研究结论与设计书 §0 头注。"ArkTS 落点"列全部为本会话读码核实行号。

| # | 原版行为（源码锚） | ArkTS 落点（file:line） | 风险 |
|---|---|---|---|
| 1 | 断流重试主循环：吞异常 timesRetried++，>MaxRetry(10) 抛 MaxRetryFailed；连接期失败先 sleep(RetryDelay×1000)=10s（PieceGrabber.cs:68-140/:114-118，本会话一手核实 ：114-118） | Downloader.ets:300-478 while 循环 + catch 分类 ：421-469；:449 先 ++ 后判，:450 exceedsMaxRetry→:453 onFailed(MAX_RETRY)；:458-460 连接期 sleep 与 pauseGate race | low |
| 2 | 首请求 AddRange(0)='Range: bytes=0-'；恢复请求闭区间 AddRange(off, len-1)（PieceGrabber.cs:389/:393-394，一手核实）；非首请求必须 206 否则 NonRetriable（:194-197，一手核实） | 首请求 :314 `bytes=0-`；恢复 ：316 open-ended `bytes=N-`（有意差异 D-R，见 ④）；206/total/start 三检 ：362-379；非 206 抛 INVALID_RESPONSE 终态 ：363-367（R2-F4 修复后） | low（Range 形态见遗留） |
| 3 | 状态码白名单仅 200/206，其余抛 HttpException（WebRequestExtensions.cs:15-29） | HttpProtocol.ets:61-63 isSuccessStatus；引擎 ：338-341 非 200/206 → INVALID_RESPONSE 立即终态（§0-1 拍板 WinHttp 语义） | low |
| 4 | 进度节流：>500ms 事件门，instantSpeed 整除/avgSpeed 浮点/eta 向上取整（HTTPDownloaderBase.cs:268-305） | EngineMath.ets:45-76 纯函数 1:1；Downloader.ets:507-525 每块落盘后节流触发 onProgress；DB 落库在事件消费方 Index.ets:181（D8 每 >500ms 事件一次） | low |
| 5 | 落盘循环 OpenOrCreate+Seek 续写、写盘 IOException→DiskError、x==0→Unexpected EOF（PieceGrabber.cs:219-255/:257-366） | dataReceive→onChunk→writeChunk（Downloader.ets:485-503，openSync READ_WRITE\|CREATE 不带 TRUNC :274，resume lseek :276-280）；写错捕获 ：495-502、循环终态化 ：401-406；dataEnd 但已收<期望→Unexpected EOF 重试类 :411-416 | low |
| 6 | Stop：防重入→cancelFlag→grabber.Abort→OnCancelled，temp 保留（HTTPDownloaderBase.cs:109-130）；Resume 恢复偏移续传（SingleSourceHTTPDownloader.cs:111-151） | Downloader.ets:182-198 stop()（generation 自增+abort+onPaused）；resume() :176-178 同实例续跑，:243-251 分片缺失转全新 start；generation 五守卫点贯穿（:292/:302/:327/:397/:423/:461/:531） | low |
| 7 | 完成拼接+AutoRename 唯一名+DeleteFileParts（SingleSourceHTTPDownloader.cs:330-483、FileHelper.cs:107-124） | 单分片退化：finishAssembly（Downloader.ets:529-578）：mkdirSync→getUniqueFileName(exists 回调注入 ：545-552)→renameSync :556→moveFileSync 兜底 ：560→deleteTempDir :582-600（unlink+rmdir 吞异常）→onFinished :577 | low |
| 8 | 六键默认头（UA/Accept/identity/Accept-Language/Accept-Charset/Referer=new Uri(url,".")）+ Cookie 原始串注入 + 超时 30s（SingleSourceHTTPDownloader.cs:519-530，本会话一手核实逐键） | HttpProtocol.ets:23-33 六键逐键（UA 字面量内联）；refererOf :37-57；HttpClient.ets:73-78 usingCache:false + connectTimeout/readTimeout=Config.getNetworkTimeout()×1000=30000；Cookie 注入点=header Record 直传（HttpClient.ets:7-8 注释，U1.2 无 cookie 来源） | low |
| 9 | 重定向后回写最终 URL（PieceGrabber.cs:442-452 FinalUri→state.Url） | **降级 D1**：本机 d.ts:3607-3760 无最终 URL 字段、maxRedirects:592 仅限次（材料核实）→PrimaryUrl 恒原始 URL；HttpClient.ets:65-69 仅回传最终 status；探针 S2 观测 headersReceive 3xx 跳点补偿（headsReceived 载体 HttpClient.ets:47-48/:79-86） | high（既定降级） |
| 10 | 压缩退化：gzip/deflate→contentLength=-1、206 视作 200、Resumable=false（PieceGrabber.cs:181-188、Utils.cs:9-15） | HttpProtocol.ets:110-122 isCompressed（双键不区分大小写+值小写包含匹配）；Downloader.ets:352-357 防御分支（totalSize=-1/206 视作 200） | low |
| 11 | 文件名：SanitizeFileName/GetFileName/GetUniqueFileName（FileHelper.cs:15-20/:88-130/:107-124）；CD 三正则链（WebRequestExtensions.cs:93-121） | 最小集 D6：FileNames.ets:28 sanitizeFileName（最后一段分隔符取段+显式无效字符枚举，修正原版 ：17-18 死赋值）、:49 fileNameFromUrl、:81 getUniqueFileName（exists 注入保纯）；CD 三正则+MIME 表延后 U6.x | medium（延后非缺陷） |
| 12 | 对话框契约：IsUriValid+MSG 双校验、UrlChanged 推导名、FileNameFetchMode 同式（INewDownloadDialog.cs:9-24、NewDownloadDialogUIController.cs:37-72/:149-214/:184） | NewDownloadDialog.ets:64-78 校验链（isUriValid→msg_invalid_url；空名→msg_no_file）；:44-53 UrlChanged 自动推导（fileNameTouched 未置位才覆盖）；:73-75 fetchMode 同式；Index.ets:38-47 CustomDialogController 挂载、:100-122 确认链（newDownloadRecord→add→Downloader→start） | low |

---

## ③ 设计决策与有意差异（引用 MIGRATION_PLAN 决策条款）

依据：MIGRATION_PLAN §6 决策 2（requestInStream 事件流替代阻塞读、TaskPool 映射）、决策 3（分段算法/identity）、决策 9（HTTP 客户端：206 强校验/重定向回写/Cookie 注入/超时 30s/MaxRetry 10/RetryDelay 10s）、决策 11（@Observed+@ObjectLink 列表、Navigation）；§3 明确降级 8（TLS 证书错误放行不复刻）；§5 结构（HttpClient 纯传输层、Downloader 分层）；U0.2 探针结论（http 主线）；设计书 §0 拍板注记 1-9。

有意差异全表（照设计书 §4 D1-D18，实现落点均经本会话读码核实）：

| # | 差异 | 依据条款 | 实现落点（本会话核实） |
|---|---|---|---|
| D1 | 重定向回写最终 URL 降级：PrimaryUrl 恒原始 URL，续传重走重定向链功能等价；S2 探针观测 headersAtRedirect，可观测则 Phase 2 前恢复 1:1 回写 | 决策 9 既定降级；研究 high 风险项/openQuestion 1 | Downloader.ets:310 直发 record.primaryUrl；HttpClient 无最终 URL 面 |
| D2 | HTTP 栈 WinHttp/DotNet 双后端 → @ohos.net.http 单栈（requestInStream 事件流） | 决策 2 + U0.2 结论 | HttpClient.ets:18 @kit.NetworkKit、:102 requestInStream |
| D3 | TLS 证书错误全放行不复刻 | 计划 §3 降级 8 | 未实现证书回调（平台不可设） |
| D4 | 强制 Accept-Encoding: identity 替代 AutomaticDecompression=All；isCompressed 防御保留 | 决策 3/9 | HttpProtocol.ets:27 identity；Downloader.ets:352-357 |
| D5 | 4xx/5xx → INVALID_RESPONSE 立即终态（WinHttp 语义），不复刻 DotNet 路径"null 会话→空引用→重试至 MaxRetry"退化 | 设计书 §0-1 拍板（研究 fact1/fact3 矛盾澄清） | Downloader.ets:338-341 |
| D6 | 文件名解析最小集（sanitizeFileName+fileNameFromUrl）；CD 三正则+MIME 延后 U6.x；修正原版 sanitize 死赋值 | 研究 fact 11 + openQuestion 3；U1.1 D3 同口径 | FileNames.ets:28-79 |
| D7 | 停止语义单入口 stop()（暂停/取消同源映射原版 Stop 单语义）；cancel 不设死 API | 设计书 §0-4（HTTPDownloaderBase.cs:109-130） | Downloader.ets:182-198；无 cancel 方法 |
| D8 | 2s SaveChunkState 门无载体跳过（chunks.db 属 U2.2）；DB 进度落库每 >500ms 事件一次（修正研究 fact4"每 2s"） | 设计书 §0-5（Application.cs:323-331 逐事件写库） | Index.ets:181 每 onProgress 落库；引擎无 2s 门 |
| D9 | Content-Range start==请求偏移显式校验（单元指令"偏移校验"显式化 hardening；原版仅 206+total 两检） | 设计书 §0-6 | Downloader.ets:375-379 |
| D10 | AssemblePieces 5MB 拼接→单分片 renameSync 退化；'File corrupted' 分支不存在；moveFileSync 兜底 | 设计书 §3.4 | Downloader.ets:555-569 |
| D11 | FetchServerTimeStamp（LastModified→mtime）不落 | fs 无 mtime 设置 API | 未实现 |
| D12 | 完成链 markAsFinished 单写（原版双写净效果相同）；完整链随 U3.1 | 设计书 §3.4 | Index.ets:218 |
| D13 | 剪贴板 URL 预填不移植（U5.2）；SetFileSizeText 不预留 | 设计书 §3.5 契约最小子集 | NewDownloadDialog 无预填/无大小行 |
| D14 | TaskPool 不用于 U1.2（@Observed 非 Sendable 不可跨线程）；SegmentWorker 协议 U2.1 交付 | 决策 2 映射单分片退化 | Downloader.ets:6-8 注释固化禁用理由 |
| D15 | TickCount→Date.now()（墙钟替单调钟） | U1.1 D1 同口径 | Downloader.ets:263/:511 |
| D16 | Cookie 注入保留但不跨主机转发（d.ts 无 enableAutoCookie，起始版本 26>24） | U0.2 S5 结论 | HttpClient.ets:7-8 注释 |
| D17 | avgSpeed<=0→eta=0 守卫（C# 0 除→Infinity→(long) 未定义） | ArkTS 加固 | EngineMath.ets:61-67 |
| D18 | 测试源 P1-U2-download-server.js（/slow.bin 分块延迟使暂停步确定性）为测试基建非对照物 | 设计书 §0-9 | docs/probe/P1-U2-download-server.js |
| D-R | （审查带入，设计书 §4 尚未补行）恢复 Range open-ended `bytes=N-`（原版单分片恢复恒闭区间 AddRange(off, len-1)，一手核实 PieceGrabber.cs:393-394）；对合规服务器行为等价（206、start==N） | R2-F6/R3-F1/复核F4 | Downloader.ets:316、HttpProtocol.ets:136-138 |

---

## ④ 审查问题处置表（覆盖全部轮次）

对照审查史（交付材料所载）：第 2 轮不通过（9 项：high×2/medium×3/low×4）→ 修复 5 项后第 3 轮**通过**（4 项 low 遗留带入）；另有独立复核（9 项：medium×2/low×7）。编码期另有 HVIGOR-E1~E5 五项编译错误已修复（编号见材料；逐条细节台账未随材料提供，本报告不虚构，可见代码痕迹两处：方法签名接口禁对象字面量装配→ForwardDownloadEvents 类，Downloader.ets:75-129；openSync/lseek 可抛 API 词法 try-catch，Downloader.ets:270-286）。

| 编号 | 轮次/来源 | 严重度 | 问题摘要 | 处置 | 证据（本会话核实） |
|---|---|---|---|---|---|
| HVIGOR-E1~E5 | 编码期 | error | hvigor 编译错误 5 项 | **已修复**，最终门禁零 error | `devecocli build --modules entry` 强制重编译 BUILD SUCCESSFUL（§5.1）；代码注释痕迹 Downloader.ets:75-78/:270-272、Index.ets:72-73 |
| R2-F1 | 对照审查第 2 轮 | high | 引擎从未触发 events.onStarted（原版 Start:99/Resume:122 双路径 OnStarted，一手核实）；探针 S3 必超时、Index.handleStarted 成死代码 | **已修复** | Downloader.ets:296-298 循环前守卫后触发 onStarted（start/resume 双路径覆盖） |
| R2-F2 | 对照审查第 2 轮 | high | onConnected 仅首请求触发（原版 PieceGrabber.cs:205 每连接回调，一手核实）；facts.connectedCount 恒 1，EXPECT S6 206 链路机械判定必 FAIL | **已修复** | Downloader.ets:387-393 onConnected 移出 firstRequest 守卫，每连接触发；探针值仅首请求（totalSize/resumable/contentType），续传 -1/206 观测/''；设计书 §3.1 已同步（:126-133） |
| R2-F3 | 对照审查第 2 轮 | medium | connectPhase=false 先于 status<=0 判定，连接期失败走身体期分支不 sleep 10s | **已修复** | Downloader.ets:331-337：status<=0 throw（:334）在 connectPhase=false（:337）之前；:458-460 连接期 sleep(RetryDelay×1000) |
| R2-F4 | 对照审查第 2 轮 | medium | 非首请求非 206 抛 ERR_NON_RESUMABLE(2)，原版该分支抛 NonRetriableException(InvalidResponse=5)（PieceGrabber.cs:194-197 一手核实） | **已修复** | Downloader.ets:363-367 抛 ERR_INVALID_RESPONSE 'Resume not supported'；ERR_NON_RESUMABLE 引擎侧不再使用（EngineMath.ets:27 导出保留供测试） |
| R2-F5 | 对照审查第 2 轮 | medium | running 标志完成/终态失败路径不复位，失败后首次"继续"点击被误分派为 stop | **已修复** | Downloader.ets:604-618 closeFdQuietly 单点复位 running（注释声明仅终局路径调用）；stop():196 显式复位；:207-210 启动防重入 |
| R2-F9 | 对照审查第 2 轮 | low | docs/design/NIGHT-RUN.md 清单外改动（台账行状态更新，非单元交付物） | 无需处置，随单元一并入库 | NIGHT-RUN.md:14 现状"已续跑"，性质为工作流台账 |
| R2-F6＝R3-F1＝复核F4 | 三轮遗留 | low | 恢复 Range open-ended `bytes=N-`（原版单分片恢复恒闭区间）；设计书 §3.1:151 留存论据不准确、§4 无差异行 | **未处置**（维持实现待补 §4 行）→ ⑦ | Downloader.ets:316、HttpProtocol.ets:136-138、设计书 :151；原版闭区间 PieceGrabber.cs:393-394 一手核实 |
| R2-F7＝R3-F2＝复核F5 | 三轮遗留 | low | OnFailed 对 InvalidResponse 且已下载>0 映射 SessionExpired(9)（HTTPDownloaderBase.cs:496-501 一手核实）未复刻，恒透传 5；U1.2 无 UI 消费该码 | **未处置**（记待 U3.x）→ ⑦ | Downloader.ets:445 透传 code |
| R2-F8＝R3-F3＝复核F3 | 三轮遗留 | low | closeFdQuietly 操作共享 this.fd 且无条件复位 running、无代际守卫——同 tick stop()+resume() 时旧续体可关新 fd/清新旗标（当前调用模式跨宏任务不可达） | **未处置**→ ⑦（复核 weakestSpot） | Downloader.ets:607-618 |
| R3-F4＝复核F6 | 两轮遗留 | low | onConnected 非首请求分支 `effectiveStatus===206` 恒真（非 206 已在 ：363-367 抛终态），死分支误导维护者 | **未处置**→ ⑦ | Downloader.ets:390-393 |
| 复核F1 | 独立复核 | **medium** | timesRetried 跨启动累积不归零（原版每次 Start/Resume 经 CreatePiece 新建 grabber 预算归零）；MaxRetryFailed 后点"继续"首次瞬态失败即再判 MaxRetry，削弱暂停恢复弱网健壮性 | **未处置**→ ⑦ | Downloader.ets:152 声明/:449 递增，launchDownloadLoop :206-219 无复位点（grep 证实全文件无复位） |
| 复核F2 | 独立复核 | **medium** | END_GATE 15s 自 open() 起算＝单响应体总时长上限而非空闲超时；>15s 长下载在不支持 Range 的公网源上首次门超时后转 Range 请求得 200→'Resume not supported' 终态（原版能完成移植版必失败）；U0.2 已证 readTimeout 不覆盖体中断流，此门是唯一防线不能删 | **未处置**→ ⑦ | HttpClient.ets:70-72（buildEndGate 在 open() 内武装）、:180-182（setTimeout 自门构造起算）；快源 2.6s 永不触发故探针不可见 |
| 复核F7 | 独立复核 | low | 未知大小源（探测后 fileSize=-1）中断重试时移植版继续发 Range 尝试续传，原版 :169 直接 NonResumable(2) 终态——终态码与可达性不符 | **未处置**（低优先，设计书记录或补分支）→ ⑦ | Downloader.ets:362-379 仅 206+total+start 三检，无 fileSize<0 分流 |
| 复核F8 | 独立复核 | low | 对话框 onConfirm 透传未 trim 的 URL（C# 经 new Uri() 归一剥空白）；带空白 URL 直发 requestInStream 失败时用户体验为约 100s 连接期重试后 MaxRetry | **未处置**→ ⑦ | NewDownloadDialog.ets:76 透传 this.url 原文；isUriValid 内部 trim 仅用于校验（HttpProtocol.ets:144） |
| 复核F9 | 独立复核 | low | CustomDialogController 复用同一组件实例，@State url/fileName 等跨开合持久（aboutToAppear 仅置 saveDir），上次输入下次回显，与 WPF 每次新建窗口不一致 | **未处置**（复核据 ArkUI 通用行为判定+代码面无重置点核实；本次未运行验证）→ ⑦ | NewDownloadDialog.ets:32-38/:40-42/:64-83 关闭链无字段重置 |

统计：修复 high×2、medium×3（R2-F1~F5）+ 编译错误 5 项；无需处置×1（R2-F9）；未处置 medium×2（复核F1/F2）、low×7（复核F3/F4/F5/F6/F7/F8/F9，其中 F3/F4/F5/F6 为审查轮带入项）。

---

## ⑤ 验证情况

### 5.1 hvigor 编译门禁（ArkTS 严格子集强制点）——**通过**

本会话执行命令 `devecocli build --modules entry`（工作目录 XdmHarmony）：
- 第一次：`BUILD SUCCESSFUL in 479 ms`（增量缓存为主，CompileArkTS UP-TO-DATE）。
- 为取得"当前代码实编"证据，touch U1.2 五个 .ets（Downloader/HttpClient/HttpProtocol/NewDownloadDialog/Index）后重跑：`:entry:default@CompileArkTS... after 1 s 372 ms` 实际执行，`BUILD SUCCESSFUL in 4 s 215 ms`，**零 error**。唯一 ArkTS 告警 `probe/units/ProbeHttp.ets:230:9`（U0.2 基线文件，与实现摘要"唯一告警为 ProbeHttp.ets:230:9 基线"一致）；另有 `WARN: Will skip sign 'hos_hap'`（工程未配 signingConfigs，属环境配置非代码缺陷，真机装包前需按晨间清单签名）。
- 工作流门禁结论（材料）：hvigor 全量编译最终状态通过。两级一致。

### 5.2 codelinter 辅助检查（提示性）——**通过（0 错误）**

本会话执行 `devecocli check lint`：exit 0，`Issues: 14 | Errors: 0 | Warnings: 14 | Files checked: 3`。14 条告警全部位于探针基建基线文件（ProbePage.ets ×12 行 69/79/88/95/111/116/126/133/142/150/165/170，@performance/hp-arkui-use-local-var-to-replace-state-var；ProbeEnv.ets:24、ProbeStore.ets:78，avoid-overusing-custom-component），均为 U0.x/U1.1 遗留；**U1.2 业务文件贡献 0 条**。与门禁结论数字完全一致。

### 5.3 分层红线（本会话 grep 核实）

- 业务层（core/**、model/**、pages/Index.ets、components/NewDownloadDialog.ets）无 `import … probe` 语句（命中仅为"禁 import probe/**"注释文字）。
- core/net、core/engine 无 `import … DownloadStore`（DB 写全在事件消费方 Index.ets）。
- 业务文件中 "XDM_PROBE" 字样仅存在于注释（"绝不输出 [XDM_PROBE]" 声明），无输出语句。

### 5.4 对照审查与独立复核结论（材料）

- 对照审查：第 2 轮 9 项（high×2/medium×3/low×4）不通过 → R2-F1~F5 修复（本会话逐条读码核实落位，§4 表）→ 第 3 轮 **approved=true**（4 项 low 带入遗留）。材料未载更早轮次记录。
- 独立复核：`acceptable=true`，9 项发现（medium×2/low×7）**全部未处置**，已逐条转入 §4 处置表与 §7 遗留清单；复核 weakestSpot 引述见 §7。

### 5.5 ArkTS 合规说明

codelinter 不含 ArkTS 语法规则，严格子集由 hvigor CompileArkTS **编译期强制**——§5.1 强制重编译零 error 即当前合规证据。抽查要点（本会话读码）：throw 仅 Error 子类（EngineMath.ets:33 `EngineError extends Error`）；对象字面量全带类型（HttpProtocol.ets:24-31 Record、HttpClient.ets:73-78 HttpRequestOptions、Downloader.ets:84 等）；方法签名接口禁对象字面量装配已以类实现规避（ForwardDownloadEvents，Downloader.ets:79-129，注释注明 hvigor 实测修复）；无正则字面量（FileNames/HttpProtocol 显式字符枚举与字符串原语）；`catch (e)` 无注解 + `e as BusinessError` 取 code。

### 5.6 本地单测——**未运行**

38 条 Hypium 用例已入库（HttpProtocol 11 / EngineMath 10 / FileNameFormat 13 / ProbeDownloadLogic 4，List.test.ets 注册 7 suite）。本报告会话与交付材料均**未运行测试执行器**（工程无 hvigor test wrapper；设计书 §7-[A]-4 同款诚实注记），如实记为"未运行"，待编码员 IDE 实跑或 U2.3 统一回归补记录。

---

## ⑥ 运行时验证待办（探针）

**本单元有探针，待人工运行。**

- 手册：`XdmHarmony/docs/probe/PROBE-u1-2-single-thread-download-list-dialog.md`；预期表：`XdmHarmony/docs/probe/EXPECT-u1-2-single-thread-download-list-dialog.json`（12 条目：BEGIN+S1~S8+SUMMARY+END，node JSON.parse 校验通过）。
- 测试源：`node docs/probe/P1-U2-download-server.js`（主机侧，Node≥14 零依赖；路由 /big.bin 4MiB 确定性流+Range 206、**/slow.bin?ms=40 每 64KB 延迟 40ms**（手册默认源，保证暂停步确定性落地）、/redirect→/final 回显观测）。
- 运行指引（两段式会话）：①构建装包拉起 → 探针首页 P1-U2 卡片 → 输入测试源（主机局域网 IP，模拟器勿用 127.0.0.1）→ 点"运行全部"自动执行 S1~S8；②杀进程重启应用（`hdc shell aa force-stop com.example.xdmharmony` → `aa start -b com.example.xdmharmony -a EntryAbility`，或桌面图标）→ 回探针页点 S9 单步核对历史；③抓取 `hilog -x | grep XDM_PROBE` 全文回贴，用 xdm-probe-verify 工作流按 runId 机械核对。
- 验收四条对应关系：URL 完整下载到沙箱＝S7 finished=true/finalSize=4194304/allSpotsMatch=true；列表实时进度＝S4（事件+落库+@Observed 同步）+ 人工 UI 走查进度条滚动；暂停恢复 206 链路＝S5 pauseLanded/offsetMatchesTemp + **S6 resumeStatus=206/startMatches/totalMatches（核心）**；重启后历史可见＝S9 rowFound/kind=1/sizeMatches。
- S2 的 `headersAtRedirect` 是决策 9 降级（D1）的补偿观测：为 true 则 Phase 2 前可恢复 1:1 回写，结论须回写计划；该键为观测事实不计业务 PASS/FAIL。
- 人工 UI 走查节（手册承载，不进机械判定）：ND_* 文案、MSG_INVALID_URL（输 ftp://x）、MSG_NO_FILE（空名）、UrlChanged 自动推导、暂停/继续按钮切换、已完成页签可见。

---

## ⑦ 遗留问题与风险

**中危（2 项，独立复核提出、未处置，建议尽早处理）：**

1. **重试预算跨启动累积**（复核F1）：timesRetried 实例字段终身不归零（Downloader.ets:152/:449/:206-219），与原版"每次 Start/Resume 新建 grabber 预算归零"（PieceGrabber.cs:24 字段初始化，一手核实）不符；MaxRetryFailed 终态后恢复的有效预算=0。修复为一行：launchDownloadLoop 置 timesRetried=0。
2. **END_GATE 语义偏差**（复核F2）：15s 门自 open() 起算（HttpClient.ets:72/:180-182）＝单响应体总时长上限，非设计意图的断流空闲兜底；快源（2.6s）探针不可见，公网直链>15s 且不支持 Range 的源将从"原版能完成"变为终态失败。readTimeout 不覆盖体中断流（U0.2 结论），此门是唯一防线**不能简单删**——应改空闲超时（每次 dataReceive 重置）。

**低危（7 项）：** closeFdQuietly 共享 fd+无 gen 守卫（复核F3/weakestSpot，当前调用模式不可达的潜在竞态）；open-ended Range 差异行未补设计书 §4（复核F4）；SessionExpired(9) 映射（复核F5，U3.x 消费）；onConnected 死分支三元（复核F6）；未知大小源 NonResumable 可达性（复核F7）；URL 未 trim（复核F8）；对话框状态跨开合持久（复核F9，U4.2 统一处理为宜）。

**环境/流程风险：** 工程无签名配置（BUILD WARN skip sign），真机装包前需一次性签名；快链路下 S5 暂停步可能跑赢下载（pauseLanded=false→UNVERIFIED 分支，换 /slow.bin 重跑）；38 条本地单测未运行（§5.6）。

---

## ⑧ 对下个单元（U2.1 PieceGrabber+SegmentWorker）的建议

1. **复核F1 随分片化自然修复**：U2.1 每次启动新建 grabber 实例即等价原版预算归零——建议把"重试预算随 grabber 生命周期"写为 U2.1 设计显式约束；若 U2.1 前出补丁，launchDownloadLoop 置 timesRetried=0 即可。
2. **END_GATE 改空闲超时须在 U2.2 断点续传复用该门前定案**（复核F2）：每次 dataReceive 重置 15s，保留断流防御语义并消除总时长上限；公网直链口径同步写入手册。
3. **closeFdQuietly 代际守卫在 U2.1 必须解决**（复核F3）：分片化后多循环并发，stop()+resume() 同 tick 概率上升；改为循环体局部捕获 fd + running 复位加 gen===generation 守卫。
4. **事件面冻结**：DownloadEvents 六事件与 HttpClient 抽象是 U2.1 复用前提（SegmentWorker 复用 HttpClient、PieceGrabber.ets 复用 EngineMath/HttpProtocol，UI 零改动）；如需扩展事件参数，同步回归 Index 与探针监听器。
5. S2 探针 `headersAtRedirect` 观测结论回写 MIGRATION_PLAN（D1 预留的 1:1 回写恢复判定输入）。
6. 错误文案/SessionExpired 映射推 U3.x；CD 三正则+MIME 表推 U6.x；对话框状态重置推 U4.2 对话框包。
7. 38 条本地单测随 U2.3 引擎保真度单测统一回归，或编码员在 IDE LocalUnit 实跑补记录。

---

## ⑨ 提交说明

**本单元代码未做 git 提交。** 按当前流程：待人工完成探针运行（§6）并经 xdm-probe-verify 核对通过后，由人工提交并按 Phase 打 tag（NIGHT-RUN 台账 U1.2 行"待完成后提交"；敏捷节奏人工验收点在 Phase 级 `git tag phase-N`）。提交时 R2 修复、设计书同步与台账更新随其余交付物一并入库。

—— 完 ——
