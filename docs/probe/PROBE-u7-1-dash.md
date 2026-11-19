# 探针运行手册：U7.1 DASH 三件套（P7-U1-F / P7-U1-P / P7-U1-C）

> 工程根：D:\git\HarmonyPC\XdmHarmony ｜ bundle：com.neuohos.xdm
> hdc 未入 PATH，用全路径（已核实存在）：
> `"D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"`

U7.1 是"一个迁移单元、三个探针入口"：一次安装覆盖，共用一个主机测试源；日志标记按探针单元 ID 分组，判定按单元分别进行。

| 探针单元 ID | 设备卡片标题（string.json:856-858） | 依赖主机测试源 | 步骤 | 分册手册 |
|---|---|---|---|---|
| P7-U1-F | DASH 解析纯函数探针（P7-U1-F） | 否（四个 MPD 向量行内注入，零网络） | S1–S6 | [PROBE-u7-1-dash-foundation.md](PROBE-u7-1-dash-foundation.md) |
| P7-U1-P | DASH 管线下载与组装探针（P7-U1-P） | 是（P7-U1-dash-host.cjs，:8795） | S1–S6 | [PROBE-u7-1-dash-pipeline.md](PROBE-u7-1-dash-pipeline.md) |
| P7-U1-C | DASH 运行控制与续传探针（P7-U1-C） | 是（同源） | S1–S5 | [PROBE-u7-1-dash-controller.md](PROBE-u7-1-dash-controller.md) |

- 本文是单元级合并运行指引 + 逐步骤预期标记表；步骤语义、结果解释与限制见各分册，逐单元判据细版见分册 EXPECT（`EXPECT-u7-1-dash-{foundation,pipeline,controller}.json`）。
- 本文步骤编号 **F-S1…F-S6、P-S1…P-S6、C-S1…C-S5** 与 [EXPECT-u7-1-dash.json](EXPECT-u7-1-dash.json) 的 `steps` 一一对应（17 个步骤行 + 每探针 BEGIN/SUMMARY/END 示例保留行 = 26 条）。
- 拉起方式说明：本工程 module.json5 只注册 **EntryAbility**（无 ProbeAbility，module.json5 abilities 列表核对），探针页不注册 main_pages，统一经 want 参数 `page=probe` 路由拉起（EntryAbility onCreate/onNewWant 均处理）——第 3 节命令按此写。

## 0. 一次性准备

真机（推荐验证环境。本机会话 2026-10-03 已沉淀以下两项，见 PROBE-SESSION-ALL.md，**跳过条件：build-profile.json5 已含签名材料且 compatibleSdkVersion=6.1.0(23)**，当前工程两条件均满足）：

```powershell
devecocli auth login                                # 华为账号登录
devecocli signature generate --product default      # 注册设备+生成签名材料（自动写入 build-profile.json5）
```

> 背景注：真机系统低于 SDK 6.1.1(24) 时安装 24 被拒（code 9568297），故工程 compatibleSdkVersion 已定为 6.1.0(23)（build-profile.json5 实读核对）；防火墙已放行 Node 入站（规则名 node-probe）。

模拟器（兜底/PC 形态验证环境，推包不需要签名）：

```powershell
devecocli emulator list
devecocli emulator start "Pura 90"
```

## 1. 启动环境

```powershell
devecocli device list                               # 多设备时记下 serial，后续 hdc 命令加 -t <serial>
```

## 2. 主机测试源（P7-U1-P / P7-U1-C 必需；P7-U1-F 不需要）

```powershell
cd /d D:\git\HarmonyPC\XdmHarmony
node docs/probe/P7-U1-dash-host.cjs --host 0.0.0.0 --port 8795
ipconfig                                            # 记下主机局域网 IPv4
```

- 脚本只自产固定 MPD 与确定性分段字节（init 1024 B、media 4096 B，字节=(轨内绝对位置+相位+i)%251，video 相位 0、audio 相位 13），无文件浏览/转发。路由：`/mpd/smooth|bbc|sintel|multiperiod|dynamic|encrypted|noperiod|wrongroot|probe.mpd`、`/seg/:repr/:name`（支持 Range 206 与整取 200）、`/health`。
- 主机自检：`curl http://127.0.0.1:8795/health` 应返回 `{"fixture":"P7-U1"}`。
- **设备上的 127.0.0.1 不是 PC**：探针源地址只填 `http://<PC局域网IP>:8795`。注意探针按固定布局请求 `origin + /mpd/probe.mpd` 与 `origin + /seg/p-*`——源地址填**主机根地址**，不要填某个 .mpd 完整地址（填公网 MPD 时 S1 起即 404）。

## 3. 运行探针（构建 + 安装 + 拉起）

```powershell
cd /d D:\git\HarmonyPC\XdmHarmony
devecocli run --module entry                        # 构建+安装+拉起应用主页；AI 已构建过时加 --skip-build
"D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" shell aa start -b com.neuohos.xdm -a EntryAbility --ps page probe
```

探针首页逐个进入（推荐次序）：

1. **P7-U1-F**：无需测试源。点"运行全部"，等 S1–S6 徽标齐 → **立即抓日志**（第 6 节）。
2. **P7-U1-P**：源地址填 `http://<PC局域网IP>:8795`（输入框默认 `http://192.168.1.20:8795` 是占位值，必须改）→ "运行全部" S1–S6 → 立即抓。
3. **P7-U1-C**：源地址同上 → "运行全部" S1–S5 → 立即抓。

约定：

- 三探针所有步骤均 autoRun、无单步按钮；点一次"运行全部" = 一个完整会话（BEGIN → 每步骤一行 → SUMMARY → END），由 ProbePage 编排。
- 重复点击产生新 runId；`xdm-probe-verify` 默认取日志中最后一个 BEGIN 块（返修对比传 rerunOf）。
- 退出探针页即作废本会话：**缺 END 的日志是实际中断证据**，不得借旧运行补全；中断先 `devecocli log --crash` 再重跑。
- 跑完一个立即抓/落盘，别攒（hilog 环形缓冲会被 UI 操作冲掉，会话 #1 教训）。

## 4. 每步骤预期日志标记表

通用判读口径（三探针通用）：

- 行格式 `[XDM_PROBE][<单元ID>][<步骤号>] key=value …`，每步骤恰好一行，单行 <1500 字节；值只写观测事实，不含 PASS/FAIL 判定。
- 示例与表中 `<实测>` / `<HHmmss>` 等尖括号是占位符（真实行内只含白名单字符）：随运行/设备变化的值只验存在性与合理性；其余为公式推导值或主机固定几何的确定值。
- 某步骤内部失败时该行出现 `errCode=…` / `err=…`（P/C 行末仍有 `cleanupComplete=…`），"每步骤恰一行"契约不变；verify 按本表判 FAIL 并分流返修。
- `[END] ok=` 只表示会话正常收尾（脚手架级未抛出）；runner 内部失败也照常收尾——**步骤是否达标以各行 key=value 对照本表判定，不以 ok= 为准**。
- `[SUMMARY]` 是各步骤聚合的兜底行：段间 `|`、段内 `,`、段首为步骤号+首个键值。P 的聚合行可能超 1500 字节，届时 ProbeKit 降级为每段仅首个 kv，两种形态均合法，判定以步骤行为准。
- P/C 每步骤行末的 `cleanupComplete=<bool>` 是资源回收事实（releaseResources 结果）；**END 行恒只有 ok/steps/elapsedMs 三个键**。

### 4.1 P7-U1-F（6 步，离线）

示例保留行（<> 为占位符）：

```
[XDM_PROBE][P7-U1-F][BEGIN] runId=142533 filesDir=/data/app/el2/100/base/com.neuohos.xdm/haps/entry/files
[XDM_PROBE][P7-U1-F][SUMMARY] S1=eventCount=<实测>,rootName=MPD,rootAttrCount=6,ignoreNameSpaceNames=1,nodeCount=189,maxDepth=6,attrCallbackOrder=<实测>,selfClosingCount=176|S2=durationCases=10,durationOk=true,pt0h10m54=654000,throwCases=2,throwOk=true|S3=periodCount=1,pairCount=16,videoSegmentsCount=91,videoInitI=true,videoLastTime=1781780000,audioSegmentsCount=90,audioSumCheck=true,timelineSumAll=268|S4=periodCount=1,pairCount=4,videoSegmentsCount=179,audioSegmentsCount=175,audioMediaCount=174,startNumberZero=true,dollarLiteral=true,videoInitTail=sintel_audio_video_brs-848x386-1500kbps_init.mp4|S5=periodCount=2,p1Items=2,p2Pairs=4,p2ListSegments=11,p2TimelineSegments=10,p1IndexSegments=1,tzeroFirst=s500.ts,tzeroSecond=s600.ts,tEqualsZeroQuirk=true|S6=dynamicRejected=true,encryptedRejected=true,noPeriodRejected=true,wrongRootRejected=true,bbcPairs=15,bbcVideoSegmentsCount=151,bbcFirstNumber=000001
[XDM_PROBE][P7-U1-F][END] ok=true steps=6 elapsedMs=812
```

| 本文步骤 | 预期标记行 | 判定要点 |
|---|---|---|
| F-S1 | `[XDM_PROBE][P7-U1-F][S1] eventCount=<实测> rootName=MPD rootAttrCount=6 ignoreNameSpaceNames=1 nodeCount=189 maxDepth=6 attrCallbackOrder=<实测钉板，≤48 字符 T/A/E/X 序> selfClosingCount=176` | attrCallbackOrder 是**实测钉板项**：首次真机运行的 token↔attr 回调相对序即契约值，后续运行必须一致；rootName=MPD 证 ignoreNameSpace 生效；nodeCount/maxDepth/selfClosingCount/rootAttrCount 为 Smooth 向量公式推导值 |
| F-S2 | `[XDM_PROBE][P7-U1-F][S2] durationCases=10 durationOk=true pt0h10m54=654000 throwCases=2 throwOk=true` | 10 值用例全中（含 -PT30S、P1Y/P2M/P3D 系数、小写 pt1h、fallback）；"1.2.3"与空串必 throw（整清单丢弃语义）；654000 为源单测向量（DashSanityTest.cs:27-31） |
| F-S3 | `[XDM_PROBE][P7-U1-F][S3] periodCount=1 pairCount=16 videoSegmentsCount=91 videoInitI=true videoLastTime=1781780000 audioSegmentsCount=90 audioSumCheck=true timelineSumAll=268` | video=1 init+89(r=88)+1=91；末段 $Time$=20020000×89=1781780000（Timeline 步进公式）；audio=1 init+89；audioSumCheck 用独立 Σ(1+max(r,0)) 双算一致钉住（268=90+89×2） |
| F-S4 | `[XDM_PROBE][P7-U1-F][S4] periodCount=1 pairCount=4 videoSegmentsCount=179 audioSegmentsCount=175 audioMediaCount=174 startNumberZero=true dollarLiteral=true videoInitTail=sintel_audio_video_brs-848x386-1500kbps_init.mp4` | simple 寻址：ceil(888000ms/5000ms)=178 video media、ceil(888000/5120)=174 audio media；startNumber=0 首媒体含 `_0.m4s`；`$$` 字面 `$`（`au$dio`）为源 quirk |
| F-S5 | `[XDM_PROBE][P7-U1-F][S5] periodCount=2 p1Items=2 p2Pairs=4 p2ListSegments=11 p2TimelineSegments=10 p1IndexSegments=1 tzeroFirst=s500.ts tzeroSecond=s600.ts tEqualsZeroQuirk=true` | 三寻址同现：index 单段整文件/List init+10 URL/Timeline 10 段；行内 t="0" 小向量钉 **t>0 严格不等号 quirk**（第二段时间 500+100=600，不重置） |
| F-S6 | `[XDM_PROBE][P7-U1-F][S6] dynamicRejected=true encryptedRejected=true noPeriodRejected=true wrongRootRejected=true bbcPairs=15 bbcVideoSegmentsCount=151 bbcFirstNumber=000001` | 四反例必 throw（=整清单丢弃，与源异常上抛同效）；BBC 5 video×3 audio=15 对、ceil(572.52/3.84)=150 media+1 init=151；首媒体编号经 $Number%06d$ 补零=000001 |

### 4.2 P7-U1-P（6 步，需测试源）

示例保留行（<> 为占位符）：

```
[XDM_PROBE][P7-U1-P][BEGIN] runId=153010 filesDir=/data/app/el2/100/base/com.neuohos.xdm/haps/entry/files
[XDM_PROBE][P7-U1-P][SUMMARY] S1=fetchStatus=ok,periodCount=1,videoSegments=3,audioSegments=3,planKind=Dash,chunkCount=6,interleaveOk=true,containerRule=.mp4,cleanupComplete=true|S2=runKind=ready,runError=,runGeneration=1,…,partsComplete=6,partSizesOk=true,leaseReleased=true,cleanupComplete=true|S3=…|S4=…|S5=…|S6=…    ← 行内省略号仅为本文排版，真实行是完整聚合；超 1500B 时降级为每段首 kv
[XDM_PROBE][P7-U1-P][END] ok=true steps=6 elapsedMs=61234
```

| 本文步骤 | 预期标记行 | 判定要点 |
|---|---|---|
| P-S1 | `[XDM_PROBE][P7-U1-P][S1] fetchStatus=ok periodCount=1 videoSegments=3 audioSegments=3 planKind=Dash chunkCount=6 interleaveOk=true containerRule=.mp4 cleanupComplete=true` | 真 ManifestClient GET `/mpd/probe.mpd` → parseDashManifest → buildDashPlan；6 chunk 交错序 v-init,a-init,v1,a1,v2,a2；Dash chunk 恒 offset=0/length=-1/isInit=false；双 .mp4 → .mp4 |
| P-S2 | `[XDM_PROBE][P7-U1-P][S2] runKind=ready runError= runGeneration=1 runParts=6 p0Bytes=1024 p0Complete=true p1Bytes=1024 p1Complete=true p2Bytes=4096 p2Complete=true p3Bytes=4096 p3Complete=true p4Bytes=4096 p4Complete=true p5Bytes=4096 p5Complete=true partsComplete=6 partSizesOk=true leaseReleased=true cleanupComplete=true` | E4 全量下载 ready；每 part 字节=主机固定几何（init 1024×2、media 4096×4，按交错序 p0..p5）；网络失败属本步 FAIL，不跳过 |
| P-S3 | `[XDM_PROBE][P7-U1-P][S3] runKind=ready asmStatus=success asmExtension=.mp4 asmBytes=9216 contentOrderMatch=true leaseReleased=true cleanupComplete=true` | 单轨 muxed Dash 计划（探针构造形态）走 AdaptiveAssembler 拼接路径；输出 1024+2×4096=9216 字节且与主机 mod-251 连续图案逐字节一致（行内另有 runParts=3、p0..p2、asmMediaStarted/drain* 等过程键照实记录，不作判定） |
| P-S4 | `[XDM_PROBE][P7-U1-P][S4] runKind=ready asmStatus=success asmExtension=<实测 .mp4\|.mkv> remuxPath=<实测 media\|fallback> asmBytes=<实测> leaseReleased=true cleanupComplete=true` | 真 MediaProcessorNapi remux；**合成字节上降级 .mkv（remuxPath=fallback）如实记录，不是 FAIL**；真实媒体 remux 与可播判据见第 5 节②③ |
| P-S5 | `[XDM_PROBE][P7-U1-P][S5] pauseTimerFired=true pausedKind=paused prefixBytes=<实测≥1> manifestRefetch=0 resumedKind=ready prefixPreserved=true leaseReleased=true cleanupComplete=true` | 限速 4 KiBps 运行 → 800ms pause → freshPlan=null 重开恢复；恢复路径不发生清单请求（manifestRefetch=0 是代码路径事实）；prefixPreserved 比对前缀文件 sha256；设备过快致分块全完成时按实际记录并 FAIL 分流时序（行内 pNBytes/pNComplete 为恢复完成后终值，note 覆盖写） |
| P-S6 | `[XDM_PROBE][P7-U1-P][S6] overBudgetRejected=true invalidUrlRejected=true singleTrackRejected=true e4Kind=rejected e4ErrorCode=InvalidAdaptiveRunInput cleanupComplete=true` | buildDashPlan 预算门（10001 段）/非法 URL/单轨 → null；空目录 E4 run → rejected/InvalidAdaptiveRunInput |

### 4.3 P7-U1-C（5 步，需测试源）

示例保留行（<> 为占位符）：

```
[XDM_PROBE][P7-U1-C][BEGIN] runId=153244 filesDir=/data/app/el2/100/base/com.neuohos.xdm/haps/entry/files
[XDM_PROBE][P7-U1-C][SUMMARY] S1=firstKind=ready,commitGeneration=1,…|S2=pauseTimerFired=true,…|S3=firstKind=ready,…|S4=firstKind=ready,…|S5=firstKind=ready,…    ← 真实行是完整聚合（本文省略排版）
[XDM_PROBE][P7-U1-C][END] ok=true steps=5 elapsedMs=43210
```

| 本文步骤 | 预期标记行 | 判定要点 |
|---|---|---|
| C-S1 | `[XDM_PROBE][P7-U1-C][S1] firstKind=ready commitGeneration=1 leaseCurrent=true busyKind=rejected busyErrorCode=AdaptiveOwnerBusy readyLeaseAttach=true asmStatus=success asmExtension=<实测> asmBytes=<实测> outputSha256=<64 位十六进制> drainClean=true leaseReleased=true restoredKind=ready restoredLeaseReleased=true cleanupComplete=true` | Dash 双轨计划跑通 E4→租约；租约持有期同 downloadId 第二 run 拒绝=AdaptiveOwnerBusy；装配前后双槽+状态文件指纹不变（drainClean=true）；释放后 freshPlan=null 重开恢复 ready |
| C-S2 | `[XDM_PROBE][P7-U1-C][S2] pauseTimerFired=true pausedKind=paused nonzeroPrefix=true resumedKind=ready asmStatus=success prefixBytesFidelity=<实测> oldPrefixUnchanged=true leaseReleased=true cleanupComplete=true` | 单轨（muxed）计划 4 KiBps + 1000ms 暂停；暂停时 2 槽中媒体槽未完成（nonzeroPrefix）；恢复后已提交前缀 sha256 前后一致；时序敏感观测按实际记录 |
| C-S3 | `[XDM_PROBE][P7-U1-C][S3] firstKind=ready stopRequested=true attached=false readerStarted=false drainedKind=<实测> leaseReleased=true leaseCurrentAfterRelease=false secondRelease=false cancelledClean=true cleanupComplete=true` | 读者准入前暂停：停止后 attachReader 被拒（attached=false，cancelledClean=true 要求成立）；二次 release=false |
| C-S4 | `[XDM_PROBE][P7-U1-C][S4] firstKind=ready attached=true asmStatus=<实测，取消形态属预期> asmExtension=<实测> stopNotifications=<实测≥1> readerStopNotified=true stopRequested=true drainedKind=<实测> leaseReleased=true cleanupComplete=true` | 读者准入后传递暂停：装配中 pause → onStop 传递给 reader（stopNotifications≥1）；装配被取消的 asmStatus 属预期不是 FAIL；若装配先于暂停完成则 stopNotifications=0 如实记录并 FAIL 分流主机吞吐 |
| C-S5 | `[XDM_PROBE][P7-U1-C][S5] firstKind=ready ownerRejected=AdaptiveOwnerBusy leaseReleased=true cleanupComplete=true` | 目录属主单写者：同 downloadId 第二 controller 被拒；主线程属主表事实，非跨进程文件锁 |

## 5. 需人工配合的步骤

1. **源地址填写**（P7-U1-P / P7-U1-C 必需，人工在设备输入框改）：填 `http://<PC局域网IP>:8795`（第 2 节 ipconfig 取值）；默认值 `http://192.168.1.20:8795` 是占位。禁 127.0.0.1。P7-U1-F 无此步骤。
2. **公共测试流人工旁路**（一次性，不作为 P/C 判定输入）：用主机或设备浏览器打开双轨 static 公共流确认可达可播——Sintel `https://dash.akamaized.net/dash264/TestCasesMCA/fraunhofer/xHE-AAC_Stereo/2/Sintel/sintel_audio_video_brs.mpd`、BBC 测试卡 `https://rdmedia.bbc.co.uk/dash/ondemand/testcard/1/client_manifest-zeroth.mpd`；拒绝路径可观察任一 `type="dynamic"` 直播清单与含 ContentProtection 的 DRM 清单。注意：P/C 探针的清单与分段 URL 固定在 host 布局（origin+`/mpd/probe.mpd`、`/seg/p-*`），源地址填公网 MPD 会在 S1 即 404——公共流只做旁路观察（与分册 foundation 手册的"人工浏览器核对向量原文"同性质）。
3. **产物人工核验（可选）**：P7-U1-P S4 输出在 `<BEGIN 行 filesDir>/probe-dash-pipeline-<uuid>/<downloadId>/`。host 合成字节不是真实媒体，`remuxPath=fallback`（.mkv 串接）且播放器拒绝属预期；"真实 DASH 流经 adaptive 管线下载+双轨 remux 产出可播文件"的业务外壳验收在 u6-4 外层集成（DashDownloader）单元，本探针证明的是解析→计划→E4 下载→装配/remux 管道本身工作正常。
4. 无剪贴板、浏览器扩展操作、授权弹窗类人工步骤；P7-U1-F 全自动离线。

## 6. 日志抓取与回贴

```powershell
# 每个探针跑完立即抓（三探针可一起抓，标记自带单元 ID）：
"D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" shell "hilog -x | grep XDM_PROBE" > probe-u7-1-dash.log

# 按单元拆分（可选）：
findstr "P7-U1-F" probe-u7-1-dash.log > probe-u7-1-f.log
findstr "P7-U1-P" probe-u7-1-dash.log > probe-u7-1-p.log
findstr "P7-U1-C" probe-u7-1-dash.log > probe-u7-1-c.log

# 兜底（hilog 环形缓冲被冲掉时；路径取对应 BEGIN 行 filesDir= 值。
# 注意 probe-latest.txt 每次新会话全量重写，只反映最近一次会话——要在跑完该探针、开下一个之前取）：
"D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" shell "cat /data/app/el2/100/base/com.neuohos.xdm/haps/entry/files/probe-latest.txt"

# 探针闪退 / 缺 END 时：
devecocli log --crash
```

回贴指引：

1. 把 `probe-u7-1-dash.log` 全文（或多段，**[XDM_PROBE] 行一律不要手工删改**）发给 AI。
2. `xdm-probe-verify` 以 `probeDoc=docs/probe/PROBE-u7-1-dash.md`（或对应分册）+ `unit=P7-U1-F` / `P7-U1-P` / `P7-U1-C` 分三次判定，逐步骤对照第 4 节表与对应 EXPECT；FORMAT-ERROR 行（不匹配标记正则）单列返修。
3. 判 FAIL 后按 fixItems 四类分流（probe-code / business-code / env / doc）返修重跑；重跑验证传 rerunOf 做增量对比。
4. 附带记录：设备型号/ABI、API 版本、应用构建标识、抓取时间、各探针 runId。
