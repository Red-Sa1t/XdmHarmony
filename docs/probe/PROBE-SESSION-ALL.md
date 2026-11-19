# 探针验收会话总指引（2026-10-03）

> 一次安装跑全部 14 个探针。每个探针的详细操作在各自手册（docs/probe/PROBE-*.md），本文只给全局次序与环境准备。
> 验证方式：日志全文贴回对话（或告知文件路径），AI 用 xdm-probe-verify 逐单元核对。

## 0. 一次性准备

```powershell
# 真机：USB 调试连接后
devecocli auth login
devecocli signature generate --product default
```

## 1. 主机侧测试源（网络类探针前置，开两个终端）

```powershell
cd D:\git\HarmonyPC\XdmHarmony\docs\probe
node P0-U2-echo-server.js              # 终端 1：echo 源（P0-U2 用）
node P1-U2-download-server.js          # 终端 2：下载源（P1-U2/P2-*/P3-*/P4-U2/P5-* 共用）
ipconfig                               # 记下主机局域网 IPv4（探针 URL 里填它，禁 127.0.0.1）
# 防火墙放行 Node（首次弹窗允许，或：netsh advfirewall firewall add rule name="node-probe" dir=in action=allow program="D:\Tools\Node\node.exe"）
```

## 2. 安装并打开探针页

```powershell
cd D:\git\HarmonyPC\XdmHarmony
devecocli run --module entry
"D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" shell aa start -b com.neuohos.xdm -a EntryAbility --ps page probe
```

## 3. 推荐运行次序（探针首页逐个点）

| 序 | 探针 | 内容 | 特殊要求 |
|---|---|---|---|
| 1 | P0-U0 | 环境自检 | 全自动，无 |
| 2 | P4-U3 | 设置读写持久 | 全自动 S1~S4 + S5 勾选走查 |
| 3 | P1-U1 | 数据层 CRUD | S0~S7 自动；**S8/S9 两段式**（S8 写持久行→force-stop→重开探针页跑 S9） |
| 4 | P0-U2 | HTTP 六项能力 | 填 echo 源 URL |
| 5 | P1-U2 | 下载链路 | 填下载源 URL（/big.bin） |
| 6 | P2-U1 | 8 分段并发 | 填下载源 URL |
| 7 | P2-U2 | 断点续传 | **两段式**：S1~S3 自动（慢源 ms=600）→force-stop→重开跑 S4 |
| 8 | P3-U1 | 队列上限 | 下载源（/slow.bin?ms=300） |
| 9 | P3-U2 | 限速+定时窗 | 下载源（/big.bin + /slow.bin?ms=2500），全步骤约 3 分钟 |
| 10 | P0-U3 | 8597 桥 | S1/S2/S4 自动；S3 可选做主机 curl（或设备连着时让 AI 代跑） |
| 11 | P4-U1 | 主窗走查 | **先回主页面人工走查 22 项**，再回探针页跑 |
| 12 | P4-U2 | 对话框走查 | 下载源（ms=300）+ 26 项人工走查 |
| 13 | P5-U1 | 后台存活 | 下载源（ms=2000）；armed→**关窗**等下载完→重开点 survived |
| 14 | P5-U2 | 剪贴板+目录 | READ_PASTEBOARD 授权弹窗允许；S3 人工复制直链；S4 选目录 |

force-stop 命令（两段式探针用）：
```powershell
"D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" shell aa force-stop com.neuohos.xdm
```

## 4. 抓日志（全部跑完后一次抓）

```powershell
"D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" shell "hilog -x | grep XDM_PROBE" > probe-all.log
```

兜底（缓冲被冲掉时）：逐探针在页面点"复制日志"粘贴收集；或 `hdc shell "cat <filesDir>/probe-latest.txt"`。

## 5. 回贴

把 probe-all.log 全文（或多段）贴回对话——标记自带单元 ID，我按单元批量核对并出判定表。中途任何探针崩溃：`devecocli log --crash` 输出一并贴回。

## 验收后动作（我来做）

全部 PASS 后：git tag（phase-0 ~ phase-5 + m1~m5 建议各自打）→ 剩余 7 单元（U6.1~U6.4 浏览器集成/HLS、U7.1~U7.3 DASH/ffmpeg/交付）按依赖继续。

---

## 会话 #1 状态（2026-10-03，真机 MateBook Pro HAD-W24 · API 23，因设备电量中止）

**环境（一次性，已沉淀）**：签名材料已生成写入 build-profile（AGC 已注册设备 UDID C011B9FB...）；
compatibleSdk 降至 6.1.0(23)（真机系统比 SDK 低一级，装 24 被拒 code 9568297）；防火墙已放行
Node 入站（规则名 node-probe）。测试源三件套：8080 echo / 8081 下载 / 8082 静态小文件
（D:\git\HarmonyPC\probe-static\serve.js，项 6/7 扩展名数据用）。

**已跑 10/14**（证据：probe-session-2026-10-03.log，会话内即时抓取重建——hilog 环形缓冲已被
UI 自动化冲掉，沙箱 files 无权限，教训：**每单元跑完立即落盘，别攒**）：

| 单元 | 结果 | 要点 |
|---|---|---|
| P0-U0/P4-U3/P1-U1/P0-U2 | 观测全绿 | HTTP 六项全过——**U0.2 http 主栈选型可定案**；重启持久核心 S9 通过 |
| P1-U2 | S5 分歧 | worker 异步记账滞后 fd 写位置（pauseOffset=1MiB vs 内容文件 2MiB），功能无损，business-code 类 |
| P2-U1 | 观测全绿 | 8 路并发/零重叠零缺口；ratio=0.42（快源下分段吃亏，观测值回写计划） |
| P2-U2 | **FAIL（高）** | 引擎对慢滴流源（≥600ms/块）零字节静默失败：3 次 bytes=0- 探测后无分段请求（服务器日志实锤；40/80ms 正常、600/2500ms 失败）；S4 未跑，返修后整单元重跑 |
| P3-U1/P3-U2 | 观测全绿 | 调度上限/FIFO/轮换/取消/全停 + 限速 917.8KB/s 落窗 + 分钟边界精确停启 |
| P0-U3 | 观测全绿 | 桥 25/25 与主机 curl 精确对账；R2-F1 畸形断连修复真机验证通过 |
| P4-U1 | 进行中 | A/B 段人工走查完成（项 14 未观测到：ms=80 完成太快排队窗口一闪而过——**下次用 ms=2500 死源占槽再验**）；探针 S1~S4+勾选未跑 |

**未跑**：P4-U1 收尾、P4-U2、P5-U1、P5-U2；xdm-probe-verify 批量核对未启动。

**返修清单**（verify 判定后走 xdm-migrate）：
1. 慢滴流源零字节（高，P2-U2 主证 + P3-U2 S3 佐证）
2. P1-U2 S5 异步记账对齐（onPaused 在 abort 落定后重算 Σdownloaded）
3. 探针页 S8/S9 自动会话跳过但徽标显"已完成"的 UI 假象（已致一次 UNVERIFIED 空跑）
4. U0.3 三条 low 遗留（Content-Length 溢出护栏/空状态行偏差/用例计数注释）
5. 走查确认项：进度窗堆叠=原版保真（ApplicationCore.cs:169/312 + showProgressWindow 默认 true），非缺陷

---

## 会话 #2 状态（2026-10-18，真机 MateBook Pro HAD-W24 · API 23 · `3QC0124B11000092`）

**环境**：主机测试源 8081（下载）/8082（静态）/8794（P6-U4 清单）/18766（P6-U5/U6）/8795（DASH），主机 172.22.54.166、设备 172.22.42.92。
UI 驱动走 `hdc shell uitest`（dumpLayout -b com.neuohos.xdm + uiInput click/inputText），日志每单元跑完即抓（会话#1 教训）。
**证据**：[probe-session-2026-10-18.log](probe-session-2026-10-18.log)（每单元最后一次完整 BEGIN..END，原样未删改）。
**教训**：① 测试源进程随宿主命令中断被一并终止过一次（设备侧表现为全部头超时/零字节，易误判为产品缺陷）——跑前 `netstat` 核对监听；② 网络中途断开一次（用户已恢复），ping 被主机防火墙拦截不能作连通判据，以探针 S1 为准。

**判定（修复后终版构建；逐步对照 EXPECT，字面量全比对 + 占位项人工复核）**：

| 单元 | 结果 | 要点 |
|---|---|---|
| P2-U2 断点续传（复验） | ✅ PASS | 会话#1 FAIL 根因定位并修复（见下「本会话修复」①）；ms=600 慢源 S2 暂停落地 2.5MiB/13 片、S3 双槽、force-stop 后 S4 offsetsUnchanged/从断点续传/5 抽查点全 o/tempDirGone |
| P0-U4 原生媒体 | ✅ PASS（脚手架+EXPECT） | arm64-v8a；remux MP4/MP3/MKV 回退/取消/20 连发全过；独立 ffprobe 核验与设备播放仍属人工项 |
| P5-U1 后台+通知 | ✅ PASS | 首跑 S2 applied=false 暴露缺陷并修复（②）；S5 survived：关窗 18s 后 taskAlive=1、进度 0→12、实况窗 notifyCount=1、lastCancelReason=none；另一轮关窗至下载跑完（合法分支）；X=最小化（Dock 运行指示在） |
| P6-U1 八路由 | ✅ PASS（EXPECT 修订） | S3/S6「改名」不发生=IR-F1 修复后正确行为（normal 条目无 tabUrl），EXPECT 已按源语义修订 |
| P6-U2 嗅探规则链 | ✅ PASS | 首跑 S2~S8 status=-1 为**探针缺陷**（头值写成裸串，桥按源 `Dictionary<string,List<string>>` 拒收断连），修探针后 S1~S8 全过 |
| P6-U3 链接刷新 | ✅ PASS | S1~S4 全过 |
| P6-U4 状态与清单 | ✅ PASS | 首跑 S3 302 清单 2300047 暴露缺陷并修复（③） |
| P6-U5 流式下载装配 | ✅ PASS | 首跑 S2 fatal 暴露缺陷并修复（④⑤）；512KiB@4KiB/s 124.9s 完成、60s 仍在途、整段 sha256=61d1d9…00ab；S5 真实双轨 Native remux 成功 |
| P6-U6 运行控制 | ✅ PASS | S2 非零前缀暂停（39215B）→ 恢复 ready → 装配全长哈希一致；连续 3 轮稳定 |
| P7-U1-F DASH 纯函数 | ✅ PASS | S1 attrCallbackOrder 钉板=`TAAAAAATTAAAAAAAAAAATAAATTAAETAEEETAAAAETAAAAETA`，eventCount=380（公式 378+2，实测记录） |
| P7-U1-P DASH 管线 | ✅ PASS（EXPECT 修订） | S3 首跑 leaseReleased=false 为**探针缺陷**（assemble 未登记读者结算）已修；S4 合成字节 remux=mediaError 与源一致（EXPECT 修订）；S6 错误码 EXPECT 修订 |
| P7-U1-C DASH 控制 | ⚠️ PASS+1 UNVERIFIED | S3/S4/S5 过；S1 装配面同 P7-U1-P S4；S2 为探针时序局限（4096B 段在暂停点前已完成）→ 由 P6-U6 S2 覆盖 |
| 回归 P1-U2/P2-U1/P3-U1/P3-U2 | ✅ 无回退 | HttpClient 改动后核心断言全过；**P2-U1 分段/单连接速比 0.42→1.98**（探测连接不再整段白下）；P1-U2 S7 tempDirGone=false 为会话#1 既有观测（low，非回归） |

**本会话修复（产品缺陷 5 项，均有真机插桩一手证据）**：
1. **慢源零字节（P2-U2，高）**：真机 `requestInStream` 的 status 直到整条流结束才 resolve（头/首块 11ms 到达，status 30s 才结算），且 netstack 把 `readTimeout` 当整次传输总时限（curl total=30000ms→2300028）——探测连接拿不到状态码即超时，永不分段。修：Content-Range 先行确认 206（终态核对，矛盾即断流）、末跳头到达撤状态时限、readTimeout 24h（空闲仍由 15s END_GATE 管）。
2. **长时任务申请 401（P5-U1，高）**：WantAgentInfo 缺 `actionType`，`startBackgroundRunning` 拒收 401——关窗后台下载从未生效。修：补 `OperationType.START_ABILITY`+`UPDATE_PRESENT_FLAG`。
3. **清单重定向（P6-U4，中）**：`@ohos.net.http` 的 `maxRedirects:0` 遇 3xx 直接 2300047 而非返回 3xx，HLS/DASH 清单一遇跳转即失败。修：ManifestClient 单跳改 rcp `autoRedirect:false`（错误码归一 23000xx，体积上限经 onDownloadProgress 取消保持 2300063）。
4. **rcp 头/状态序（P6-U5 S2，高）**：SDK 两种先后序都会出现，原实现「头先到」即隔离，>64KiB 分片队列满暂停后 fetch 永不结算 → 2s 后 fatal。修：头块暂存待状态码配对，终态头一致性校验保留。
5. **rcp 队列溢出丢字节（P6-U5/U6 S2，高）**：cacheSize 暂停滞后，SDK 越过 64KiB 阈值写至数百 KiB，队列满即「Abort request. Reason=Out of memory」并丢在途字节（读侧表现 1007900990，曾致 6×32768 字节缺失被整段哈希抓获）。修：物理容量 1MiB（阈值仍 64KiB）、只用 readInto 读、该码判 retryable（续传自封存前缀）。

**探针缺陷 3 项**：P6-U2 头值数组化；P7-U1-P assemble 读者结算登记；P7-U1-C S2 时序局限登记（未改探针）。

**仍待人工（需要人眼/授权，不可由 AI 代判）**：P4-U1 主窗走查 22+1 项与 S1~S4、P4-U2 对话框走查 26 项、P5-U2 剪贴板（READ_PASTEBOARD 授权弹窗+人工复制+目录选择器）、OPT-1 深色观测、P6-U2 捕获页 [H] 走查、P0-U4 产物独立 ffprobe/设备播放、P7-U1 公共 Sintel/BBC 流可播验收。

### 会话 #2 人工走查批次（2026-10-19，与用户协同：用户操作、AI 抓日志判定）

| 单元 | 结果 | 要点 |
|---|---|---|
| P5-U2 剪贴板+保存目录 | ✅ PASS（S5 checked=10/10） | READ_PASTEBOARD 随调试 Profile 已授予（不弹框，lastReadOk=true）；S3 真实跨应用复制被识别；S4 选择器回读一致+tempGone；走查⑤**修复后**通过（见下 ⑥）；S2 程序写入识别回调有延迟（落入下一窗口）记观测 |
| P4-U1 主窗口 | ✅ PASS（S4 22/23） | 会话#1 未观测的 14/15 补齐（ms=2500 死源占满 3 槽 → 第 4 条 Waiting→取消排队→Stopped；重启仍 Stopped、服务端从未收到其请求）；**第 23 项深色模式推迟到 UI 重写** |
| P4-U2 对话框包 | ✅ PASS（S1~S4 + S5 26/26） | S4 首跑 completedShown2=1 为**探针缺陷**（首窗未关时读存活态，门本身正确）已修；Don't show 持久化端到端实证（复跑 gateBefore=0）；More 在批量选择窗（单文件新建窗为 U1.2 D13 子集，无 More/Later——登记差异） |
| P6-U2 捕获页 [H] | ✅ PASS（10/10） | ⑩增量渲染**修复后**通过（见下 ⑦）；⑥点下载弹「新建视频下载」窗=U6.3 接管后的源行为（手册「无弹窗」为 U6.3 前旧口径，已改） |
| P0-U4 产物核验+播放 | ✅ PASS | hdc file recv -b 导出；ffprobe/ffmpeg：MP4 H.264+AAC 2.0s 帧/PCM MD5 与输入一致、DTS 单调；MP3 1.0s 439.5Hz；MKV H.264+PCM16 两轨内容一致；用户设备文件管理器播放 MP4/MP3 正常 |
| OPT-1 深色观测 | ⏸ 推迟 | 与 UI 统一重写同批（用户决定） |
| P7-U1 公共 DASH 流 | ⏸ 待定 | 需设备公网 + 下载整条公共流（Sintel/BBC 均为十余分钟、百 MB 级） |

**本批次修复（产品缺陷 2 项）**：
6. **完成后拷贝到用户目录失败（U5.2，medium）**：`fileIo.copy` 目标传目录 URI 真机拒收 13900020 Invalid argument（文件留沙箱+toast，降级正确但功能未达）。修：目标改为「目录 URI/encodeURIComponent(文件名)」；复测 `finished file copied dest=…/test/slow_1.bin`。
7. **捕获页不增量渲染（U6.2，medium）**：外层分组 ForEach key 仅用 kind，组节点被复用、新行不出（/sync 已有）。修：key 含组内 id 序列；复测推送后新行即时出现、组计数 2→3。

**探针缺陷 1 项**：P4-U2 S4 改以「新开或新入队」判门（host 增观测 `completedPendingCount()`）。

**登记（low / 推迟）**：剪贴板非文本内容时 `getPrimaryText()` 返回 undefined 触发 catch 日志（无功能影响）；P1-U2 S7 tempDirGone=false（会话#1 既有）；**UI 问题统一推迟到功能收敛后重写**——用户反馈：前景背景同色、弹窗无背景、弹窗拉伸、进度窗堆叠遮挡、配色致按钮难辨（Delete 等）。

### 会话 #2 补记（2026-11-06）：P7-U1 公共 DASH 流 → 阻塞

- 设备公网可达；主机经 fport 18597 向 8597 桥 POST /media（`https://dash.akamaized.net/akamai/bbb_30fps/bbb_30fps.mpd`，Content-Type application/dash+xml）→ 设备侧 ManifestClient（rcp）拉取真实 CDN 清单并解析：`dash manifest recognized` + `dash capture done multi=10`，/sync 列出 180p~2160p 共 10 档 → **捕获链路真机 PASS**。
- 用户在捕获页勾选 180p 313Kbps 点下载 → 弹「This video format is not supported yet.」：Index.openNextInbox 对 `videoKind !== 'video'` 的条目一律拒绝——**HLS/DASH 业务外壳（u6-4 外层集成 O2/O3/O7）未接线**，自适应视频在应用内不可下载。登记 DELIVERY D 档 2（高），公共流可播验收阻塞至外层集成落地。
- PROBE-u7-1-dash-pipeline.md「源地址填公共 MPD」的用法不成立（清单路径写死），已在手册更正。

### 会话 #2 补记（2026-11-06 续）：HLS/DASH 业务外壳落地 → 端到端 PASS

- 业务外壳（AdaptiveDownloader、Manager 工厂、描述旁表、HLS 捕获接线、Index 路由）落地后，经**应用内真实下载路径**验收（桥推送 → 捕获 → 新建对话框 → 下载列表 → 完成文件 `hdc file recv -b` 导出 → ffprobe/ffmpeg 解码比对），不经探针。验收源 `docs/probe/E2E-adaptive-host.cjs`（ffmpeg 生成真实 H.264+AAC），设备经 `hdc rport` 以 127.0.0.1 访问。
- PASS：HLS 单轨（与分片拼接逐字节一致）、HLS 双轨 remux、DASH 双轨（视频 MD5 一致、音频 PCM 一致仅尾裁 23.6 ms）、强杀→重启→续传（零清单请求、只补未封存分片）、应用内暂停→续传、**公共 DASH bbb_30fps 180p**、**公共 HLS Mux 240p**。
- 真机暴露并修复 2 项：设备 SDK `url.URL.parseURL('./', '…/x.mpd')` 不符合 RFC 3986（公共 DASH 全 404，取证自设备 downloads.db）；分片 4xx 不重试（与源不一致）。
- 证据：[e2e-adaptive-2026-11-06.log](e2e-adaptive-2026-11-06.log)；报告：[u6-4-outer-integration-REPORT](../design/u6-4-outer-integration-REPORT.md)。
