# P7-U1-P DASH 管线下载与组装探针

此入口用真 HTTP 驱动冻结的 adaptive 管线（E4 RunController + F Assembler）执行 DASH 计划：主机固定 MPD → `DashXmlFeed.parseDashManifest` → `buildDashPlan` → 全量下载 → 单轨拼接/双轨真 MediaProcessorNapi remux → 暂停恢复 → 管线拒绝。它不验收业务外壳（DashDownloader 随 u6-4 外层集成）与物理掉电持久化。当前目标运行状态：待验，未生成目标 PASS 日志。

## 准备与运行

1. 在 PC 项目目录运行固定测试源：

   ```powershell
   node docs/probe/P7-U1-dash-host.cjs --host 0.0.0.0 --port 8795
   ```

   不带参数默认仅监听 127.0.0.1:8795。设备运行时使用设备可达的 PC 局域网地址；设备上的 127.0.0.1 不是 PC。脚本只提供固定自产 MPD 与确定性分段字节（init 1024 B、media 4096 B，字节=(轨内绝对位置+相位+i)%251，video 相位 0、audio 相位 13），无文件浏览或转发服务。

2. 构建、安装并以既有 `page=probe` want 进入 `probe/ProbeIndex`，选择"DASH 管线下载与组装探针（P7-U1-P）"。测试源填写 `http://<PC局域网IP>:8795`。点击"运行全部"依次执行 S1—S6（S6 需要源可达以解析 URL 前缀；S2—S5 需要源可达以下载分段）。
3. 保留一次完整 BEGIN 到 END 的原始 hilog 及派生标记；对照 [EXPECT](EXPECT-u7-1-dash-pipeline.json) 逐项判定。
4. 每步骤独立 owner（runs/leases/clients 全登记）；页面退出即 pause+cancel+drain。

## 步骤和自产证据

| 步骤 | 实际操作 | 关键观察 |
| --- | --- | --- |
| S1 | ManifestClient GET `/mpd/probe.mpd` → parseDashManifest → buildDashPlan | fetchStatus/periodCount/videoSegments=3/audioSegments=3/planKind=Dash/chunkCount=6/interleaveOk（trackIndex/trackOrder 交错序+恒 offset=0/length=-1/isInit=false）/containerRule=.mp4 |
| S2 | newAdaptiveState → AdaptiveRunController(freshPlan) 全量下载 | runKind=ready/partsComplete=6/partSizesOk（1024/1024/4096×4）/generation=1/leaseReleased |
| S3 | 单轨 Dash 计划（探针构造 muxed 形态，业务单轨不进计划）→ E4 → AdaptiveAssembler 单轨拼接 → 读输出文件与固定图案逐字节比对 | asmStatus=success/asmExtension=.mp4/asmBytes=9216/contentOrderMatch=true |
| S4 | 双轨计划 → E4 → 真 MediaProcessorNapi remux（合成字节的降级路径如实记录） | asmStatus=success/asmExtension=.mp4 或 .mkv/remuxPath=media 或 fallback/asmBytes |
| S5 | 限速 4 KiBps 运行 → 800ms pause → freshPlan=null 重开恢复 | pauseTimerFired=true/pausedKind=paused/prefixBytes>0/manifestRefetch=0/resumedKind=ready/prefixPreserved=true |
| S6 | 超预算（10001 段）/非法 URL/单轨 buildDashPlan → null；空目录 E4 run | 三个 rejected=true/e4Kind=rejected/e4ErrorCode=InvalidAdaptiveRunInput |

## 结果解释和限制

S3 的 `contentOrderMatch` 用主机确定性字节图案（连续模 251）证明"分块按计划序拼接"，这是本次构造时序下的事实，不证明任意 DASH 流的拼接正确性。S4 在合成字节上 MediaProcessorNapi remux 预期失败并降级 `.mkv`（串接），`remuxPath` 如实记录观测值——**降级不是 FAIL**；真实 remux 成功与产物可播的判定走下方公共测试流。S5 的恢复路径 `freshPlan=null`，不发生清单重取（manifestRefetch=0 是代码路径事实）；`prefixPreserved` 比对 sha256。S6 的单轨拒绝（`singleTrackRejected`）钉住"buildDashPlan 仅接受双轨"契约。

### DASH 公共测试流端到端（可播验收，人工）

**【2026-11-06 更正】本探针不能直接跑公共 MPD**：清单路径写死为 `<源地址>/mpd/probe.mpd`，S4 双轨计划由主机 `/seg` 段直构。公共流端到端须经业务链路（桥捕获 → 捕获页下载），而该链路的 HLS/DASH 业务外壳尚未接线（DELIVERY D 档 2）。以下原文保留作历史：把源地址直接填公共 MPD（Sintel：`https://dash.akamaized.net/dash264/TestCasesMCA/fraunhofer/xHE-AAC_Stereo/2/Sintel/sintel_audio_video_brs.mpd`；BBC 测试卡：`https://rdmedia.bbc.co.uk/dash/ondemand/testcard/1/client_manifest-zeroth.mpd`）运行 S1→S2→S4：真实 CDN 分段、双轨 remux 产出 `.mp4`，用设备侧播放器打开 `<filesDir>/probe-dash-pipeline-*/<downloadId>/` 下 `asm` 输出确认可播。公网可达性人工确认一次；产物路径见 S4 的输出目录（探针记录的 base/downloadId）。

`node --check` 与主机冒烟不证明设备侧网络、fileIo、MediaProcessorNapi 或 URL 语义；这些以本探针真机日志为准。
