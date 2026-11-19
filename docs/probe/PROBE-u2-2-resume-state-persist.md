# 探针运行手册：P2-U2 断点续传探针（分片落盘+杀进程重启续传）

> 工程根：D:\git\HarmonyPC\XdmHarmony ｜ bundle：com.neuohos.xdm ｜ 预期表：[EXPECT-u2-2-resume-state-persist.json](./EXPECT-u2-2-resume-state-persist.json)
> hdc 未入 PATH，用全路径：HDC="D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
> 探针页形态：**autoStart=false + 两段式会话**——会话 A（S1~S3 自动：源预检/慢源下载到 2MiB 暂停/状态文件体检）→
> **force-stop 杀进程** → 重启拉起 → 会话 B（S4 手动单步：重启续传+字节抽查）。

## 0. 一次性准备

```bash
# 真机（推荐验证环境）：真机拒绝未签名 HAP，首次必须做——
devecocli auth login                              # 华为账号登录
#   USB 连接真机并开启开发者模式/USB 调试后：
devecocli signature generate --product default    # 注册设备+生成签名材料，自动写入 build-profile.json5
# 模拟器（兜底/形态验证）：推包不需要签名
devecocli emulator list                           # 确认实例（本机已有 "Pura 90"）
```

## 1. 测试源（主机侧，必须先启动）——P1-U2-download-server.js 复用（零改动）

```bash
cd /d D:\git\HarmonyPC\XdmHarmony\docs\probe
node P1-U2-download-server.js            # 默认 8080；node P1-U2-download-server.js 8090 可换端口
# 预期输出：
# [P1-U2] download server listening on 0.0.0.0:8080  (big.bin=4194304B, routes: /big.bin /slow.bin?ms=40 /echo /redirect /final)
# [P1-U2] probe base url = http://<本机局域网IP>:8080  (设备内禁用 127.0.0.1）
```

- **复用指引**：P2-U2 不新增服务器文件——直接复用 P1-U2 主机侧测试源。本探针消费 `/big.bin`
  （S1 预检）与 `/slow.bin?ms=600`（S2 下载、S4 续传——**ms=600 由探针 URL 参数携带**，server 端
  ms 参数任意整数合法，`P1-U2-download-server.js:100-110` 本会话核实，零改动复用）。
- **局域网 IP 纪律**：服务器绑 0.0.0.0；设备（模拟器/真机）内 `127.0.0.1` 是自身回环——探针页
  TextInput 必须填**主机局域网 IP**（如 `http://192.168.1.20:8080`）。主机防火墙需放行该端口。
- **延时对照**：探针页独立“块间隔（毫秒）”输入默认600，可填80/600/2500；必须为0至60000的整数，非法值使S2报错。S2输出`slowDelayMs`，S4沿用pending中的完整URL。80/2500仅作故障诊断，不套用默认600ms的暂停时长/持久化门验收结论。单改基础URL不能改变延时。
- **慢源说明**：`/slow.bin?ms=600` 每 64KB 块延迟 600ms，8 连接并行合计 ≈850KB/s——2MiB 暂停阈值
  ≈2.4s 到达（>2000ms：**保证暂停前 2000ms 数据门至少触发一次**，chunks.json 的 downloaded 值
  非零且滞后可观测——§6-S3 staleBytes 容差判定的成因前提）。S4 续传剩余 ≈2MiB ≈2.4s+ 完成窗口。
- 路由与字节锚：`/big.bin` 与 `/slow.bin` 同规格 4194304B 确定性流（字节 o = floor(o/65536) % 251，
  与 ProbeDownloadLogic/ProbeSegmentLogic 三处同值锚），支持 Range 206（闭区间与 open-ended 均可）。
- **服务器控制台逐请求打印实收 Range——本单元第二证据轨**（§5 表：恢复后各分片起点应 =
  offset+持久化 downloaded，与 S4 restoredLine 逐片对账）。

## 2. 运行探针——会话 A（设备侧，S1~S3 自动）

```bash
cd /d D:\git\HarmonyPC\XdmHarmony
devecocli device list                             # 设备就绪确认（多设备时后续 devecocli/hdc 命令需 --device <serial>）
devecocli run --module entry                      # 构建+安装+拉起应用主页（AI 已构建过时：加 --skip-build）
# 打开探针页（EntryAbility 解析 want 参数 page=probe，支持冷/暖启动）：
hdc shell aa start -b com.neuohos.xdm -a EntryAbility --ps page probe
# 探针首页 → P2-U2 卡片 → 核对 TextInput 测试源 → 点"运行全部"（S1~S3；S4 自动会话触达即跳过不发标记行）
```

> 模板差异说明：通用模板写 `--ability ProbeAbility`——本工程无独立探针 Ability（module.json5 仅
> mainElement=EntryAbility），探针页由 EntryAbility 解析 want 参数 `page=probe` 拉起（U0.1 路由
> 契约；P1-U2/P2-U1 手册同款注记）。

## 3. force-stop 杀进程 + 重启（本单元核心动作，双轨）

### 主轨：AI hdc 自动

```bash
HDC="D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
# S1~S3 跑完（END 行 steps=3 出现）后执行：
"$HDC" shell aa force-stop com.neuohos.xdm          # 杀进程（temp/chunks.json/pending 均在 filesDir，跨 kill 存活）
"$HDC" shell aa start -b com.neuohos.xdm -a EntryAbility --ps page probe   # 冷启动直进探针
# 探针首页 → P2-U2 卡片 → 核对 TextInput 测试源（重启后 @State 回缺省，需重填！）→ 点 S4 行的"执行"按钮
```

### 兜底：人工（AI hdc 不可用时）

1. 最近任务里划掉 XdmHarmony（等价 force-stop）；
2. 桌面图标重新拉起 → 探针首页（如未直达：`aa start ... --ps page probe` 重发或应用内导航）；
3. P2-U2 → 重填测试源 → 点 S4 行的"执行"按钮（runSingle 单步会话，BEGIN+S4+SUMMARY+END 恰 4 行）。

> **杀进程语义**：force-stop 后进程内存态（pieces Map/调度器）全部蒸发，`<filesDir>/temp/<recordId>/
> chunks.json.1/.2` 与 `<filesDir>/probe-P2-U2-persist.json` 是 S4 恢复的全部输入——这正是本单元
> 验收对象（跨进程续传 ≠ U2.1 同实例 stop→resume）。

## 4. 抓取标记（会话 B 跑完后）

```bash
"D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" shell "hilog -x | grep XDM_PROBE" > probe-P2-U2.log
# 兜底：缓冲被冲掉时取探针写盘结果（路径见各会话 BEGIN 行 filesDir=——**两会话各查各的**，
# force-stop 前的会话 A 行只能靠 hilog 已抓部分或重跑）
hdc shell "cat <filesDir>/probe-latest.txt"
# 探针闪退时：devecocli log --crash
# 业务侧诊断（StateStore/PieceScheduler 吞掉的异常走这里，非探针标记）：
hdc shell "hilog -x | grep -E 'StateStore|PieceScheduler'"
# 主机侧第二证据：P1-U2-download-server.js 控制台的逐请求 Range 打印（§5 表逐片对账）
```

## 5. 每步骤预期日志标记表（判定细则见 EXPECT 表）

hilog 过滤 `XDM_PROBE` 后：**会话 A 恰 6 行**（BEGIN+S1+S2+S3+SUMMARY+END；S4 被自动会话触达但
会话门跳过、不发标记行）、**会话 B 恰 4 行**（BEGIN+S4+SUMMARY+END）。行格式严格为
`[XDM_PROBE][P2-U2][<步骤>] key=value ...`（FORMAT 正则 `^\[XDM_PROBE\]\[([A-Z0-9-]+)\]\[([A-Za-z0-9-]+)\]\s(.+)$`）。
`<N>` 表浮动值。

| 步骤 | 预期标记行（示例） | 判定要点 |
|---|---|---|
| BEGIN | `runId=<HHmmss> filesDir=<非空沙箱files路径>` | 与 END 按 runId 配对（**A/B 两会话各自独立 runId**） |
| S1 | `sourceUrl=<base>/big.bin status=206 contentLength=4194304 rangeSupported=true chunks=<N>>0` | 测试源 Range 能力预检（探针自建 requestInStream，不走引擎）——S2~S4 环境前提；rangeSupported=false → env 分流 |
| S2 | `recordId=probe-p2u2-<runId> addOk=true pauseLanded=true pausedDownloaded=<N:0<N<4194304> pausedPieces=n=<N>>=2/... pausedPieceCount=<N>>=2 activeAfterStop=0 elapsedToPauseMs=<N>>2000` | **暂停落地+取消排空锚**：pauseLanded=true（2MiB 阈值到达）；0<pausedDownloaded<4194304（ms=600 慢源暂停窗口确定性）；pausedPieceCount≥2（分裂已发生）；activeAfterStop=0（U2.1 S5 锚复用）；elapsedToPauseMs>2000（数据门触发过的间接证据）；pausedPieces 为暂停时点快照单行（pending.pieceRows 转储原料） |
| S3 | `slot1Exists=true slot2Exists=<bool> savedPieces=<N>>=2 savedTotal=4194304 savedLine=n=<N>/<id8>.<off>.<len>.<dld>.<st>.-1--1/... staleBytes=<N>>=0 minFileOverPersisted=true pendingWritten=true` | **状态文件体检锚**：slot1Exists=true（双槽写入链路活）；savedTotal=4194304（恢复自足冗余，D1）；**minFileOverPersisted=true（§3.5 不变量直接观测：持久化 downloaded ≤ 分片文件实际字节）**；**staleBytes≥0（容差语义：stop 不补显式保存——源码 Stop :109-130 无 SaveChunkState，最旧持久化状态 ≤2s 陈旧；只判下界不判上界，EXPECT 记 UNVERIFIED 分支说明）**；pendingWritten=true；slot2Exists/savedPieces/savedLine 为观测值（≥2 次保存后轮换出 .2，事件点保存使结构无滞后） |
| S4 | `pendingFound=true rowFound=true restoredPieces=<N>>=2 restoredSum=<N>>=0 restoredLine=n=<N>/... offsetsUnchanged=true resumed=true firstProgressDownloaded=<N>>=restoredSum finished=true finalSize=4194304 tempDirGone=true spotChecks=m0=o/m<p-1>=o/m<p>=o/m2097152=o/m4194303=o allSpotsMatch=true` | **断点续传三联锚（本单元核心验收）**：pendingFound/rowFound=true（跨会话工件+DB 行存活）；**offsetsUnchanged=true（各分片 offset/length 跨重启不变——pending.pieceRows 与 restored 按 id 对拍）**；restoredSum>0（持久化分片字节非零）；**firstProgressDownloaded≥restoredSum（恢复真实从断点继续而非从零——fresh-restart 缺陷的直接判别式）**；finished=true finalSize=4194304（续传收敛）；tempDirGone=true（完成收尾 deleteTempDir 连带清理 chunks.json 工件）；**allSpotsMatch=true（续传产物字节正确性：5 抽查点含 pausedDownloaded 邻域，expectedByteAt 确定性流，任一分片错位/漏序即 x）** |
| SUMMARY | `[SUMMARY] S1=<...>|S2=<...>|S3=<...>` / `[SUMMARY] S4=<...>` | 会话 A 3 段（S1..S3）/ 会话 B 1 段（S4）；环形缓冲兜底锚 |
| END | `ok=true steps=3 elapsedMs=<N>>=0`（A）/ `ok=true steps=1 ...`（B） | 两会话 BEGIN/END 按 runId 各自配对无孤儿 |

预期标记行全文示例（占位示意值，非判定锚——判定一律以 EXPECT 表范围/存在性表述为准；两会话各成一对 BEGIN/END）：

```
[XDM_PROBE][P2-U2][BEGIN] runId=142533 filesDir=/data/app/el2/100/base/com.neuohos.xdm/haps/entry/files
[XDM_PROBE][P2-U2][S1] sourceUrl=http://192.168.1.20:8080/big.bin status=206 contentLength=4194304 rangeSupported=true chunks=1
[XDM_PROBE][P2-U2][S2] recordId=probe-p2u2-142533 addOk=true pauseLanded=true pausedDownloaded=2181038 pausedPieces=n=3/a1b2c3d4.0.1048576.65536.0.-1--1/b2c3d4e5.1048576.1048576.1048576.1.-1--1/c3d4e5f6.2097152.2097152.0.0.-1--1 pausedPieceCount=3 activeAfterStop=0 elapsedToPauseMs=2410
[XDM_PROBE][P2-U2][S3] slot1Exists=true slot2Exists=true savedPieces=3 savedTotal=4194304 savedLine=n=3/a1b2c3d4.0.1048576.65536.0.-1--1/b2c3d4e5.1048576.1048576.1048576.1.-1--1/c3d4e5f6.2097152.2097152.0.0.-1--1 staleBytes=98304 minFileOverPersisted=true pendingWritten=true
[XDM_PROBE][P2-U2][SUMMARY] S1=status=206|S2=pauseLanded=true,pausedPieceCount=3,activeAfterStop=0|S3=minFileOverPersisted=true,staleBytes=98304
[XDM_PROBE][P2-U2][END] ok=true steps=3 elapsedMs=5300
[XDM_PROBE][P2-U2][BEGIN] runId=143012 filesDir=/data/app/el2/100/base/com.neuohos.xdm/haps/entry/files
[XDM_PROBE][P2-U2][S4] pendingFound=true rowFound=true restoredPieces=3 restoredSum=2082734 restoredLine=n=3/a1b2c3d4.0.1048576.65536.0.-1--1/b2c3d4e5.1048576.1048576.1048576.1.-1--1/c3d4e5f6.2097152.2097152.0.0.-1--1 offsetsUnchanged=true resumed=true firstProgressDownloaded=2087424 finished=true finalSize=4194304 tempDirGone=true spotChecks=m0=o/m<p-1>=o/m<p>=o/m2097152=o/m4194303=o allSpotsMatch=true
[XDM_PROBE][P2-U2][SUMMARY] S4=offsetsUnchanged=true,firstProgressDownloaded=2087424,allSpotsMatch=true
[XDM_PROBE][P2-U2][END] ok=true steps=1 elapsedMs=4100
```

失败形态：步骤异常 catch emit `errCode/errMessage`（1390000x 盘错/2300028 超时/102000xx taskpool）；
S2/S4 引擎失败 emit `engineFailed=true errCode=<N> errMessage=<...>`（恢复集含 length=-1 片 →
errCode=2 NonResumable 是源码同貌边界 :169-170，EXPECT 记 Known-behavior 分支而非静默）。

## 6. 主机侧第二证据：server 控制台 Range 起点对账表

S4 恢复后，server 控制台会打印若干 `range=bytes=X-Y` 请求。逐条与 S4 restoredLine 各片
`<id8>.<offset>.<length>.<downloaded>` 对拍：**每条请求起点 X 应 = 某片 offset+downloaded（持久化值），
终点 Y 应 = offset+length-1**。手工填表（回贴给 AI 一起判定）：

| # | server 控制台 range=bytes=X-Y | 对应分片（id8/off/len/dld 取自 S4 restoredLine） | X==off+dld？ | Y==off+len-1？ |
|---|---|---|---|---|
| 1 | 例：bytes=786432-1048575 | 例：a1b2c3d4/786432/262144/0 | o | o |
| 2 | … | … | | |
| 3 | … | … | | |

> 注①：探测请求 `range=bytes=0-` 只出现在全新 start（S2），S4 恢复后**不应**出现整流开窗口请求
> （除非恢复集只有 1 片 length=-1——NonResumable 终态分支）。
> 注②：取消重派（EOF 早尽/连接期重试）会产生同片多请求，起点逐步推进均 ≤ offset+length-1，正常。

## 7. 环境差异分支（重跑指引）

| 现象 | 判定 | 处置 |
|---|---|---|
| S1 `rangeSupported=false` 或 `errCode/errMessage` | env | 测试源未启动/地址错/防火墙——§1 重启服务器、核对局域网 IP 后重跑 |
| S2 `pauseLanded=false` 或 `pausedDownloaded=0/4194304`（暂停窗口消失） | **UNVERIFIED** | 快源跑赢暂停——源固定 `/slow.bin?ms=600`；仍复现则增大 ms（改探针页 URL 后重跑 S2~S4）或换大文件源 |
| S2 `activeAfterStop>0` | FAIL | 分流 business-code（取消排空回归——U2.1 S5 同锚） |
| S3 `slot1Exists=false` 或 `savedTotal!=4194304` | FAIL | 分流 business-code（StateStore 写入链路/探测落位保存锚⑧回归——查 hilog tag `StateStore`） |
| S3 `minFileOverPersisted=false` | FAIL | 分流 business-code（§3.5 不变量破坏：持久化 downloaded > 分片文件实际字节——写入时序/文件面回归，附 savedLine 定位） |
| S3 `staleBytes<0` | FAIL | 分流 business-code（内存 Σ < 持久化 Σ——账本方向反了；>0 属正常容差不判） |
| S4 `pendingFound=false` | env | 会话 A 未跑 S3 或 pending 写失败（查 S3 pendingWritten）——重跑会话 A |
| S4 `rowFound=false` | FAIL | 分流 business-code（DB 行跨重启丢失——查 DownloadStore/getDownloadById；或 S2 addOk=false 时仍跑了 S2） |
| S4 `offsetsUnchanged=false` | FAIL | 分流 business-code（分片结构跨重启漂移——恢复桥注入回归；附 pausedPieces/savedLine/restoredLine 三拍对账） |
| S4 `firstProgressDownloaded<restoredSum` | FAIL | 分流 business-code（**fresh-restart 缺陷**：恢复从零重下而非从断点继续——恢复桥未生效/读回空） |
| S4 `resumed=false`/`finished=false`/`finalSize=0`（120s 超时） | FAIL | 分流 business-code（恢复不收敛——查 hilog PieceScheduler 续传三检/StateStore） |
| S4 `errCode=2`（NonResumable，Resume not supported） | **Known-behavior** | 恢复集含 length=-1 片（预探测状态被持久化后恢复）→ 源码 :169-170 同貌终态；检查 S3 savedLine 含 len=-1 片即确认，非缺陷 |
| S4 `tempDirGone=false` | FAIL | 分流 business-code（完成收尾 deleteTempDir 未清 temp——工件残留） |
| S4 `allSpotsMatch=false` / `spotChecks` 含 `=x` | FAIL | 分流 business-code（续传拼接字节错位——前缀覆盖幂等破坏或拼装漏序；状态文件在而分片文件被删 → sparse 零洞同此象，先核对 §6 表与 env 分流） |
| 模拟器 vs 真机 | — | 真机优先（force-stop/冷启动时序真机更真实）；结论按实际运行环境标注回写计划 |

## 8. 会话守卫冒烟（可选）

1. 会话 A 运行中（S2 下载期）按 HOME 退后台 → 暖启动重进 → 重跑：新会话标记行完整、无旧会话行串入、
   无孤儿 BEGIN/END（U0.2 同款）；
2. 本单元特有：S4 单步会话与 S1~S3 自动会话的行缓冲互不串扰（runSingle 各自 begin 重置）；
   自动会话触达 S4 被会话门跳过、不发标记行。

## 9. 回贴

把 probe-P2-U2.log 全文（[XDM_PROBE] 行一律不要手工删改；**含会话 A 与会话 B 两段**）+ §6 的
server Range 对账表发给 AI，由 xdm-probe-verify 核对；结论（含验证环境：真机/模拟器）与既有单元
同口径写回 MIGRATION_PLAN。本单元特有回写项：① staging→renameSync 双槽轮换是否实测无异常
（S3 slot1Exists/savedLine）；② 2000ms 数据门在 ms=600 慢源下的 staleBytes 实测值（容差上界
经验值回填 EXPECT 注记）；③ force-stop 后 filesDir 工件存活性（pending+chunks.json 双证）。
验收锚：杀进程重启续传链路可观测（S4 offsetsUnchanged/firstProgressDownloaded≥restoredSum/
finalSize 三联）+ 拼接产物字节正确（S4 allSpotsMatch=true）+ 每分片 offset 观测
（S2 pausedPieces/S3 savedLine/S4 restoredLine 三拍对账）。
