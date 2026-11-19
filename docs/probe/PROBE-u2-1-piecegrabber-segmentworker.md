# 探针运行手册：P2-U1 分段并发探针（PieceGrabber+SegmentWorker）

> 工程根：D:\git\HarmonyPC\XdmHarmony ｜ bundle：com.neuohos.xdm ｜ 预期表：[EXPECT-u2-1-piecegrabber-segmentworker.json](./EXPECT-u2-1-piecegrabber-segmentworker.json)
> hdc 未入 PATH，用全路径：HDC="D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
> 探针页形态：**autoStart=false**——进入 P2-U1 页后需先填测试源地址，再点"运行全部"（S1~S5 顺序 5 步，单会话，无重启步——分片持久化属 U2.2）。

## 0. 一次性准备

```bash
# 真机（推荐验证环境）：真机拒绝未签名 HAP，首次必须做——
devecocli auth login                              # 华为账号登录
#   USB 连接真机并开启开发者模式/USB 调试后：
devecocli signature generate --product default    # 注册设备+生成签名材料，自动写入 build-profile.json5
# 模拟器（兜底/形态验证）：推包不需要签名
devecocli emulator list                           # 确认实例（本机已有 "Pura 90"）
```

## 1. 测试源（主机侧，必须先启动）——P1-U2-download-server.js 复用

```bash
cd /d D:\git\HarmonyPC\XdmHarmony\docs\probe
node P1-U2-download-server.js            # 默认 8080；node P1-U2-download-server.js 8090 可换端口
# 预期输出：
# [P1-U2] download server listening on 0.0.0.0:8080  (big.bin=4194304B, routes: /big.bin /slow.bin?ms=40 /echo /redirect /final)
# [P1-U2] probe base url = http://<本机局域网IP>:8080  (设备内禁用 127.0.0.1)
```

- **复用指引**：P2-U1 不新增服务器文件——直接复用 P1-U2 主机侧测试源（路由规格一致）。本探针消费
  `/big.bin`（S1 预检）与 `/slow.bin`（S2 `?ms=40`、S4 `?ms=40`、S5 `?ms=80`）；`/redirect`/`/echo`/
  `/final` 本单元不消费（P1-U2 归档探针在用，服务器保持全路由）。
- **局域网 IP 纪律**：服务器绑 0.0.0.0；设备（模拟器/真机）内 `127.0.0.1` 是自身回环——探针页
  TextInput 必须填**主机局域网 IP**（如 `http://192.168.1.20:8080`）。主机防火墙需放行该端口。
- **慢源说明**：`/slow.bin?ms=N` 每 64KB 块延迟 N 毫秒（4MiB=64 块）。S2/S4 用 `ms=40`（≈2.6s 全量）
  ——8 连接并行分摊每块延迟是 ratio>1 的成因；S5 用 `ms=80`（≈5.2s 全量）扩大暂停窗口使
  `downloaded>=262144` 后 stop 落在下载中段（确定性暂停）。快源（ms=0 或公网快链路）下 262144B
  分片秒完，maxConcurrent 观测退化（§7 UNVERIFIED 分支）。
- 路由与字节锚：`/big.bin` 与 `/slow.bin` 同规格 4194304B 确定性流（字节 o = floor(o/65536) % 251，
  与 ProbeDownloadLogic/ProbeSegmentLogic 三处同值锚），支持 Range 206（闭区间与 open-ended 均可）。
  服务器控制台逐请求打印实收 Range——**8 分段并行的第二证据**（同刻多条 `range=bytes=X-Y` 打印）。
- **测试 URL 可替换参数**：探针页顶部 TextInput 为 base URL（默认占位 `http://192.168.1.20:8080`）。
  探针按 `base + 路由` 拼接；公网大文件源需整个 base 指向支持 Range 的路径且文件 ≥ 数 MB，否则
  piecesCount/maxConcurrent 观测退化（§7 分支）。

## 2. 运行探针（设备侧）

```bash
cd /d D:\git\HarmonyPC\XdmHarmony
devecocli run --module entry                      # 构建+安装+拉起应用主页（AI 已构建过时：加 --skip-build）
# 打开探针页（EntryAbility 解析 want 参数 page=probe，支持冷/暖启动）：
hdc shell aa start -b com.neuohos.xdm -a EntryAbility --ps page probe
# 探针首页 → P2-U1 卡片 → 核对 TextInput 测试源 → 点"运行全部"（S1~S5）
```

> 模板差异说明：通用模板写 `--ability ProbeAbility`——本工程无独立探针 Ability（module.json5 仅
> mainElement=EntryAbility），探针页由 EntryAbility 解析 want 参数 `page=probe` 拉起（U0.1 路由
> 契约；P1-U2 手册同款注记）。

### 会话模型（单会话 A）

| 会话 | 触发 | 内容 |
|---|---|---|
| A | 填源后点"运行全部" | S1~S5 顺序 5 步（源预检/8 分段并行+抽查/区间完整性/吞吐对比/暂停-恢复，steps=5） |

无重启步（分片进度 JSON 持久化+杀进程续传属 U2.2）。

## 3. 抓取标记（探针跑完后）

```bash
"D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" shell "hilog -x | grep XDM_PROBE" > probe-P2-U1.log
# 兜底：缓冲被冲掉时取探针写盘结果（路径见 BEGIN 行 filesDir=）
hdc shell "cat <filesDir>/probe-latest.txt"
# 探针闪退时：devecocli log --crash
# 业务侧诊断（调度器/worker 吞掉的异常走这里，非探针标记）：
hdc shell "hilog -x | grep -E 'PieceScheduler|HttpClient'"
# 主机侧第二证据：P1-U2-download-server.js 控制台的逐请求 Range 打印（并行窗口/闭区间形态直观可见）
```

## 4. 每步骤预期日志标记表（判定细则见 EXPECT 表）

hilog 过滤 `XDM_PROBE` 后，会话 A 恰 8 行（BEGIN+S1..S5+SUMMARY+END），行格式严格为
`[XDM_PROBE][P2-U1][<步骤>] key=value ...`（FORMAT 正则 `^\[XDM_PROBE\]\[([A-Z0-9-]+)\]\[([A-Za-z0-9-]+)\]\s(.+)$`）。
`<N>` 表浮动值。下表与 EXPECT 表 steps 一一对应（9 条目）。

| 步骤 | 预期标记行（示例） | 判定要点 |
|---|---|---|
| BEGIN | `[XDM_PROBE][P2-U1][BEGIN] runId=<HHmmss> filesDir=<非空沙箱files路径>` | 与 END 按 runId 配对 |
| S1 | `sourceUrl=<base>/big.bin status=206 contentLength=4194304 rangeSupported=true chunks=<N>>0` | 测试源 Range 能力预检（探针自建 requestInStream，不走引擎）——S2~S5 环境前提；rangeSupported=false → env 分流（§1 检查服务器/IP） |
| S2 | `recordId=probe-p2u1-<runId> addOk=true finished=true piecesCount=16 maxConcurrent=8 connectedCount=<N>>=17 finalSize=4194304 elapsedMs=<N> segBps=<N>>0 spotChecks=m0=o/m2097152=o/m4194303=o allSpotsMatch=true` | **8 分段并行验收核心锚**：maxConcurrent=8（快源环境退化 ≥4 → §7 UNVERIFIED 换源分支）；piecesCount=16±1（分裂收敛数学：4194304/262144=16 片，findMaxChunk 严格 `>` 使 rem==262144 不再分裂）；connectedCount≥17（1 探测+16 分片连接，取消重派再加）；allSpotsMatch=true=**多分片拼接字节级正确性证据**（expectedByteAt 确定性流，任一分片错位即 x） |
| S3 | `snapshotLines=n=16/<id8>.<off>.<len>.<dld>.<st>.<wS>-<wE>/... maxOverlapAcrossSnapshots=0 finalGapCount=0 coveredBytes=4194304 sourceBytes=4194304 coverageComplete=true` | **区间不重叠+全覆盖验收锚（全程每瞬时成立）**：maxOverlapAcrossSnapshots=0（任一瞬时 pieces Map 均为 [0,total) 的不交覆盖——分裂=一窗换两半窗保性质，取消重派后亦然）；finalGapCount=0/coverageComplete=true（最终快照口径）；snapshotLines 为最终快照单行（≤16 片 ≈900B <1500B） |
| S4 | `requestUrl=<base>/slow.bin?ms=40 status=200 singleBytes=4194304 streamEnded=true singleElapsedMs=<N> singleBps=<N>>0 segBps=<N>>0 ratio=<N>` | **吞吐可测验收锚**：singleBps>0 且 segBps>0；ratio 为观测值不判定（慢源下期望 >1——8 连接并行分摊 40ms/块延迟；快源/空载机器下 ≈1，EXPECT 记 UNVERIFIED 分支说明） |
| S5 | `recordId=probe-p2u1-s5-<runId> pausedOffset=<N> activeAfterStop=0 resumed=true finalSize=4194304 maxConcurrentBefore=<N> spotChecks=... allSpotsMatch2=true` | **取消排空锚**：activeAfterStop=0（taskpool.cancel 协作取消+records 清空——stop 即清 D9）；0<pausedOffset<4194304（ms=80 慢源暂停窗口确定性）；resumed=true（恢复后 onFinished）；allSpotsMatch2=true（暂停-恢复跨多分片字节正确——抽查点含 pausedOffset-1/pausedOffset） |
| SUMMARY | `[XDM_PROBE][P2-U1][SUMMARY] S1=<...>|S2=<...>|…` | 5 段齐全（S1..S5，各段含关键键）；环形缓冲兜底锚 |
| END | `[XDM_PROBE][P2-U1][END] ok=true steps=5 elapsedMs=<N>>=0` | ok=true=无脚手架级异常；steps=5 与步骤行数互证 |

注意：

- ① S2/S5 的 maxConcurrent/piecesCount 采样口径：awaitUntil 谓词轮询循环内每 30ms 附带取样
  （activeSegmentCount 取 max + 同轮抓瞬时快照序列，S3 消费）——单计时器，无双计时器漂移。
- ② S3 双口径：maxOverlapAcrossSnapshots 对**每个瞬时快照**逐帧校验取 max；finalGapCount/
  coveredBytes/coverageComplete 对**最终快照**（完成时点全片终值）。不可对"全程快照并集"校验——
  历史大窗与其分裂半窗天然重叠（分裂取消时旧窗口残留历史帧），并集必 overlap>0。
- ③ 任一步骤失败形态：该步行以 `errCode/errMessage` 键组替代正常键集（每步骤仍恰一行）；S2/S5
  引擎失败快速 emit（engineFailed=true errCode=<N>，不拖满超时）。**S2 errCode 含 10200024**
  （taskpool onReceiveData 未注册）→ business-code 分流（dispatchPiece 的 record 先入 Map 再 execute
  回归点）；10200023/10200024 出现在 worker 侧 → progress 降级路径（§7 观测回写项）。业务侧吞掉的
  异常细节查 hilog tag `PieceScheduler`（domain 0x0000，非 [XDM_PROBE] 行）。
- ④ S4 基线请求无 Range 头（普通 GET → 200 全量 4MiB），与 S2 引擎下载同源同延迟参数（ms=40）
  ——ratio 的分母分子同源可比。

## 5. 需人工配合的步骤（S1~S5 全 autoRun；人工动作仅环境与输入）

1. **主机侧启动测试源**（§1 的 node 命令）——S1~S5 共同前置；未启动则 S1 直接以 errCode/errMessage
   键组收场（env 分流），S2~S5 无判定意义。
2. **填测试源地址**：进入 P2-U1 页后在顶部 TextInput 填 `http://<主机局域网IP>:8080`（禁
   127.0.0.1——模拟器内回环是自身），再点"运行全部"（autoStart=false；S1~S5 顺序全自动执行，
   下载/抽查/校验/暂停恢复均无人工步骤）。
3. **会话守卫冒烟配合**（可选，§8）：会话运行中（S2/S5 下载期）按 HOME 退后台 → 暖启动重进 → 重跑。
4. 本单元不触达浏览器/剪贴板/通知等能力——无其它人工步骤（对照 PROBE_SPEC 模板 §4 逐项裁剪）。

## 6. 分片算法行为对照（verify 附加判定输入，对照 PieceGrabber.cs/HTTPDownloaderBase.cs 逐条）

1. **探测→206→分裂收敛**（SingleSourceHTTPDownloader.cs:228-293 + HTTPDownloaderBase.cs:307-332）：
   S2 connectedCount 首连（探测，携带 totalSize=4194304/resumable=true）后逐连接分裂——服务器控制台
   第二证据：`range=bytes=0-`（探测）→ 闭区间 `range=bytes=X-Y` 逐条出现，窗口逐轮对半细化。
2. **阈值双边界**（HTTPDownloaderBase.cs:422 `>` / :439 `<`）：S2 piecesCount=16 恰为 4194304/262144
   ——rem==262144 时 Find 不选，收敛在 16 片（8 是并发上限非片数）。
3. **失败重派**（:351-403）：GetInactivePiece 排除在途/Finished/downloaded==length；
   GetInactiveChunkCount 缺 downloaded==length 排除项是源码原貌（D16，U2.3 用例锁定）。
4. **取消重派区间不重叠**（设计书 §3.6 三支柱）：分裂命中在途分片 → cancel+立即重派下半区——
   S3 maxOverlapAcrossSnapshots=0 全程成立是三支柱未被破坏的直接证据；S5 allSpotsMatch2=true 是
   前缀覆盖幂等的字节级证据。
5. **worker 消息面**（设计书 §0-1/§0-2）：connected 消息=原版 PieceConnected（每连接一次分裂驱动）；
   progress 消息 250ms 周期（S2 progressCount 与 elapsedMs 互证 ≥ 数次；若降级触发——progress 计数
   归零但下载正常完成——按 §7 观测回写项记录，不判 FAIL）。

## 7. 环境差异分支（重跑指引）

| 现象 | 判定 | 处置 |
|---|---|---|
| S1 `rangeSupported=false` 或 `errCode/errMessage`（源不可达 2300028/2300007） | env | 测试源未启动/地址错/防火墙——§1 重启服务器、核对局域网 IP 后重跑 |
| S2 `maxConcurrent` 4~7（快源窗口不可观测） | **UNVERIFIED** | 换更慢源重跑：S2 源固定 `/slow.bin?ms=40`——若仍不足，检查设备负载；或改用公网大文件源（base 整体替换）后重跑 S2 |
| S2 `maxConcurrent` ≤3 或 piecesCount 异常（≠16±1） | FAIL | 分流 business-code（分裂调度/重派回归），附 snapshotLines（S3 行）与服务器控制台 Range 序列定位 |
| S2 `allSpotsMatch=false` / `spotChecks` 含 `=x` | FAIL | 分流 business-code（多分片拼接错位——三支柱任一被破坏），附 S3 区间键组定位 |
| S2 `engineFailed=true errCode=<N>` | FAIL | 分流 business-code：5（InvalidResponse：源状态/Content-Range 三检不过）、2（NonResumable：闭窗口未知大小——派发前 length 落位回归）、4（MaxRetry：连接期反复失败查 env）、8（DiskError：盘满/写盘失败）、10200024（taskpool 消息注册——business-code 回归点） |
| S3 `maxOverlapAcrossSnapshots>0` | FAIL | 分流 business-code（区间重叠——分裂取消-重派三支柱破坏；对照 S2 spotChecks 若同时 =x 则数据已错位） |
| S3 `finalGapCount>0` 或 `coverageComplete=false` | FAIL | 分流 business-code（覆盖不全——片丢失/拼装遗漏；coveredBytes 与 sourceBytes 差值即缺口规模） |
| S4 `singleBps=0` 或 `segBps=0`（吞吐不可测） | **UNVERIFIED** | 基线流异常（streamEnded=false → 查源延迟/超时）；重跑 S4 或增大 ms 参数 |
| S4 `ratio` ≤1（快源/空载机器） | **观测事实** | 不判 FAIL——慢源下期望 >1；ratio≈1 说明并行收益被源带宽/设备调度吃掉，结论按环境标注回写 |
| S5 `activeAfterStop>0` | FAIL | 分流 business-code（取消排空回归——stop 即清 records/任务 cancel 未生效） |
| S5 `pausedOffset=0` 或 `=4194304`（暂停窗口消失） | **UNVERIFIED** | 快源跑赢暂停——S5 源固定 `/slow.bin?ms=80`；仍复现则增大 ms（改探针页 URL 后重跑 S5）或换大文件源 |
| S5 `allSpotsMatch2=false` | FAIL | 分流 business-code（暂停-恢复跨分片字节错位——前缀覆盖幂等破坏；附 pausedOffset 与 spotChecks 定位） |
| S2/S5 下载正常但 progress 事件稀疏（250ms 消息降级） | **观测回写项** | worker sendData 定时器回调被平台拒（10200023/10200024）→ 降级为完成时回报（设计书 §0-2/§8 预案）——正确性不受影响；实测结论回写计划（设计书 §8 风险表首行） |
| 模拟器 vs 真机 | — | 真机优先（吞吐数据真机才有意义）；结论按实际运行环境标注回写计划 |

## 8. 会话守卫冒烟（U0.2/U1.1/U1.2 同款硬要求）

1. 自动会话 A 运行中（S2/S5 下载期）按 HOME 退后台；
2. 暖启动重进探针首页 → P2-U1 → 点"运行全部"（新会话）；
3. 预期：新会话标记行完整、BEGIN/END 的 runId 单调配对、**无旧会话步骤标记行串入新会话、无孤儿 END**；
4. 预期（引擎侧）：旧会话的 Downloader 实例不再发事件（探针事实袋随会话重建）；旧 taskpool 任务由
   stop/generation 守卫静默消化，无跨会话 onFinished 串扰。

## 9. 回贴

把 probe-P2-U1.log 全文（[XDM_PROBE] 行一律不要手工删改）发给 AI，由 xdm-probe-verify 核对；
结论（含验证环境：真机/模拟器）与既有单元同口径写回 MIGRATION_PLAN。本单元特有回写项：
① §0-2 sendData 定时器回调限制的降级是否实际触发（progress 消息密度）；② fileIo 在 taskpool
worker 的可用性（理论低风险——错误经结果 JSON errCode 观测，触发即 business-code/env 分流）；
③ ratio 实测值（分段收益，Phase 2 验收"大文件吞吐显著优于 U1.2"的量化输入）。验收锚：
8 分段并行（S2 maxConcurrent=8）、区间不重叠+全覆盖（S3）、多分片拼接字节正确（S2/S5 allSpotsMatch）、
暂停-恢复取消排空（S5 activeAfterStop=0）。
