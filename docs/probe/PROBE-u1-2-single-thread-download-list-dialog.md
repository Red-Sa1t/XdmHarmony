# 探针运行手册：P1-U2 下载链路探针（单线程下载+主列表+新建对话框）

> 工程根：D:\git\HarmonyPC\XdmHarmony ｜ bundle：com.neuohos.xdm ｜ 预期表：[EXPECT-u1-2-single-thread-download-list-dialog.json](./EXPECT-u1-2-single-thread-download-list-dialog.json)
> hdc 未入 PATH，用全路径：HDC="D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
> 探针页形态：**autoStart=false**——进入 P1-U2 页后需先填测试源地址，再点"运行全部"（S1~S8 顺序 8 步）；S9 为手动步骤（带"执行"按钮，runSingle 单步会话）。

## 0. 一次性准备

```bash
# 真机（推荐验证环境）：真机拒绝未签名 HAP，首次必须做——
devecocli auth login                              # 华为账号登录
#   USB 连接真机并开启开发者模式/USB 调试后：
devecocli signature generate --product default    # 注册设备+生成签名材料，自动写入 build-profile.json5
# 模拟器（兜底/形态验证）：推包不需要签名
devecocli emulator list                           # 确认实例（本机已有 "Pura 90"）
```

## 1. 测试源（主机侧，必须先启动）

```bash
cd /d D:\git\HarmonyPC\XdmHarmony\docs\probe
node P1-U2-download-server.js            # 默认 8080；node P1-U2-download-server.js 8090 可换端口
# 预期输出：
# [P1-U2] download server listening on 0.0.0.0:8080  (big.bin=4194304B, routes: /big.bin /slow.bin?ms=40 /echo /redirect /final)
# [P1-U2] probe base url = http://<本机局域网IP>:8080  (设备内禁用 127.0.0.1)
```

- 启动指引与 P0-U2 口径一致（`npx http-server` 通用注意事项同样适用：绑定 0.0.0.0、设备内填**主机局域网 IP**，模拟器内 `127.0.0.1` 是模拟器自身回环）。
- 路由：`/big.bin`（4194304B 确定性流，字节 o = floor(o/65536) % 251，与 ProbeDownloadLogic/EXPECT 三处同值锚）＋ Range 206；`/slow.bin?ms=40`（同规格，每 64KB 块延迟 40ms → 64 块 ≈ 2.6s，使 S5 暂停步**确定性落地**）；`/redirect`→`/final`（S2 观测 headersReceive 3xx 跳点）；`/echo`（P0-U2 兼容路由）。服务器控制台逐请求打印实收 Range/Cookie，作 hilog 之外的第二证据。
- **测试源可替换参数**：探针页顶部 TextInput 为 base URL（默认占位 `http://192.168.1.20:8080`，改为实际 `http://<主机局域网IP>:8080`）。公网直链大文件也可作 S3~S7 替换源（把 TextInput 改为公网 URL 后，S3~S7 仍走 `/slow.bin?ms=40` 拼接——注意探针按 `base + 路由` 拼接，**替换公网源需整个 base 指向支持 Range 的路径**，否则 S5 暂停步走 §5 UNVERIFIED 分支）。

## 2. 运行探针（设备侧）

```bash
cd /d D:\git\HarmonyPC\XdmHarmony
devecocli run --module entry                      # 构建+安装+拉起应用主页（AI 已构建过时：加 --skip-build）
# 打开探针页（EntryAbility 解析 want 参数 page=probe，支持冷/暖启动）：
hdc shell aa start -b com.neuohos.xdm -a EntryAbility --ps page probe
# 探针首页 → P1-U2 卡片 → 核对 TextInput 测试源 → 点"运行全部"（S1~S8）
```

> 模板差异说明：通用模板写 `devecocli run --module entry --ability ProbeAbility`——本工程无独立探针
> Ability（module.json5 仅声明 mainElement=EntryAbility），探针页由 EntryAbility 解析 want 参数
> `page=probe` 拉起（U0.1 路由契约，冷/暖启动均支持），通用模板中的 `--ability ProbeAbility` 形态
> 不适用于本工程（U1.1 手册同款注记）。

### 会话模型（两段式：会话 A → 重启 → 会话 B）

| 会话 | 触发 | 内容 |
|---|---|---|
| A | 点"运行全部" | S1~S8 顺序 8 步（源预检/重定向观测/新建启动/进度/暂停/恢复/完成抽查/列表快照，steps=8） |
| B | 杀进程重启后进页 → 点 **S9 执行** | 单步会话：读 pending JSON 核对历史行（steps=1） |

### 重启两段式（主轨 AI 自动 + 人工兜底双轨）

```bash
# 会话 A 跑完（确认 [XDM_PROBE][P1-U2][END] 行出现）后：
hdc shell aa force-stop com.neuohos.xdm    # 杀进程（等价断电，非退后台）
hdc shell aa start -b com.neuohos.xdm -a EntryAbility --ps page probe   # 二次拉起
# 探针首页 → P1-U2 → 点 S9"执行"（会话 B）
```

- **人工兜底**（设备无法 hdc 连接时）：最近任务里划掉应用（或设置-应用管理-停止）→ 桌面图标拉起 → 探针首页 → P1-U2 → 点 S9。步骤与 AI 主轨完全一致，EXPECT 的 S9 判定不区分执行者。
- pending 文件：`<filesDir>/probe-P1-U2-persist.json`（BEGIN 行 `filesDir=` 给出目录前缀；S7 写入 id/finalPath/finalSize，S9 读回核对；重跑会话 A 覆盖为最新行）。
- 重启后**不恢复引擎**（U1.2 范围外，续传状态机属 U2.2）——进行中列表展示 Stopped 历史行即满足验收"重启后历史可见"。

## 3. 抓取标记（探针跑完后）

```bash
# hdc 未入 PATH，可用全路径直呼（或先 export HDC=全路径 后用 $HDC）：
"D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" shell "hilog -x | grep XDM_PROBE" > probe-P1-U2.log
hdc shell "hilog -x | grep XDM_PROBE" > probe-P1-U2.log
# 兜底：缓冲被冲掉时取探针写盘结果（路径见 BEGIN 行 filesDir=；probe-latest.txt 只反映最后会话）
hdc shell "cat <filesDir>/probe-latest.txt"
# pending JSON 人工核对（S9 的磁盘侧第二证据）：
hdc shell "cat <filesDir>/probe-P1-U2-persist.json"
# 探针闪退时：devecocli log --crash
# 业务侧诊断（引擎/存储吞掉的异常走这里，非探针标记）：
hdc shell "hilog -x | grep -E 'Downloader|HttpClient|DownloadStore'"
# 主机侧第二证据：P1-U2-download-server.js 控制台的逐请求 Range/状态打印
```

## 4. 每步骤预期日志标记表（判定细则见 EXPECT 表）

hilog 过滤 `XDM_PROBE` 后，自动会话（A）恰 11 行（BEGIN+S1..S8+SUMMARY+END）、S9 单步会话恰 4 行，行格式严格为
`[XDM_PROBE][P1-U2][<步骤>] key=value ...`（FORMAT 正则 `^\[XDM_PROBE\]\[([A-Z0-9-]+)\]\[([A-Za-z0-9-]+)\]\s(.+)$`）。
`<N>` 表浮动值。下表与 EXPECT 表 steps 一一对应（12 条目）。

| 步骤 | 预期标记行（示例） | 判定要点 |
|---|---|---|
| BEGIN | `[XDM_PROBE][P1-U2][BEGIN] runId=<HHmmss> filesDir=<非空沙箱files路径>` | 与 END 按 runId 配对；A/B 会话各自独立 BEGIN |
| S1 | `sourceUrl=<base>/big.bin status=206 contentLength=4194304 rangeSupported=true chunks=<N>>0` | 测试源 Range 能力成立（S5/S6 判定的环境前提）；206 即续传能力（echo 源首请求状态是 206 非 200——首请求恒带 Range: bytes=0-） |
| S2 | `requestUrl=<base>/redirect redirectFollowed=true finalStatus=200 headsReceivedCount=<N> locationSeen=<Location 或 absent> headersAtRedirect=<true/false>` | redirectFollowed=true（栈自动跟随重定向）；**headersAtRedirect = headersReceive 是否在 3xx 跳点触发的直接观测**（true→Phase 2 前恢复决策 9 的 1:1 回写并回写计划；观测事实不计业务 PASS/FAIL） |
| S3 | `recordId=probe-u2-<runId> addOk=true started=true firstRequestStatus=206 totalSize=4194304 resumable=true tempDirCreated=true pieceFileExists=true` | add/启动/206 探测链路；totalSize 与源一致；resumable=true（CreateProbeResult :441 语义）；tempDirCreated/pieceFileExists（引擎接管证据） |
| S4 | `progressTicks=<N>>=1 lastProgress=<0..100> lastInstantSpeed=<N> lastEta=<N> lastDownloaded=<N>>=262144 dbProgress=<N>>0 recordSynced=true` | 进度链三线互证：引擎 >500ms 进度事件（progressTicks）→ 消费方落库（dbProgress>0，D8 每事件一次）→ @Observed 字段同步（recordSynced）；AND 谓词见注① |
| S5 | `pauseLanded=<true/false> pauseOffset=<N> pieceCount=<N> ledgerSum=<N> aggregateFileSize=<N> filesCoverLedger=<true/false> ledgerMatchesPause=<true/false> onPausedFired=true detailFile=<文件名>` | 暂停落地时 0<pauseOffset<4194304、pieceCount>=1、filesCoverLedger=true、ledgerMatchesPause=true；逐片详情见 filesDir 下 detailFile。未落地需结合失败日志分流，不能把零字节慢流当作快源。 |
| S6 | `resumeStatus=206 probeRequestStatus=206 contentRangeStart=<N> contentRangeTotal=4194304 requestedOffset=<pauseOffset> startMatches=true totalMatches=true engineResumeConnected=true` | **206 链路核心（验收主线）**：resumeStatus=206（引擎二次 onConnected）+ startMatches=true + totalMatches=true（三检齐——206+total==fileSize+start==请求偏移，§0-6）；contentRangeStart/total 来自探针自证请求（同 URL 带 Range: bytes=N-，见注②）；若 resumeStatus=200 记 UNVERIFIED（源不支持 Range→S1 应已拦截 env） |
| S7 | `finished=true finalSize=4194304 finalFileExists=true tempDirGone=true spotChecks=m0=o/m<x>=o/... allSpotsMatch=true dbKind=1 dbName=probe-u2-<runId>.bin dbSize=4194304 dbProgress=0 pendingFile=probe-P1-U2-persist.json` | rename+清 temp 收尾（tempDirGone）；**allSpotsMatch=true 是 206 续传字节级正确性证据**（若 resume 忽略偏移，pauseOffset 处字节必错位）；dbKind=1/dbSize（markAsFinished 落库链路）；dbProgress=0（完成行 R3 强制规则） |
| S8 | `inProgressCount=<N> finishedCount=<N>>=1 finalPathInDb=<targetDir>/<name> fileAtPathExists=true` | 列表数据源就绪；inProgressCount 不含 probe id 的完成行；fileAtPathExists=true（UI 渲染走 §人工走查） |
| S9 | `pendingFound=true id=probe-u2-<上次会话runId> rowFound=true kind=1 sizeMatches=true fileStillExists=true` | **重启持久核心**：rowFound=true 且 kind=1/sizeMatches（对照 P1-U1 S9 两段式）；pendingFound=false→UNVERIFIED（先跑会话 A 再重启） |
| SUMMARY | `[XDM_PROBE][P1-U2][SUMMARY] S1=<...>|S2=<...>|…` | 自动会话恰 8 段（S1..S8），S9 单步会话 1 段；环形缓冲兜底锚 |
| END | `[XDM_PROBE][P1-U2][END] ok=true steps=8 elapsedMs=<N>>=0`（自动会话）；单步会话 `[XDM_PROBE][P1-U2][END] ok=true steps=1 elapsedMs=<N>>=0` | ok=true=无脚手架级异常；steps 与该会话步骤行数互证；无孤儿 BEGIN/END |

注意：

- ① S4 谓词为 **AND**（progressCount>=1 且 lastDownloaded>=262144）：设计书 §6 表格写"或"——OR 在快源下
  progressTicks=0、慢源下 5 ticks≈整文件使 S5 暂停窗口消失；AND 同时满足 EXPECT 锚（progressTicks>=1、
  dbProgress>0）与 S5 暂停确定性（慢源 ~500ms 处暂停，剩余 ≈3.6MiB/2.2s）。设计书 §6 表格原文与实现的
  差异以本注为准（EXPECT 按实现判定）。
- ② S6 的 contentRangeStart/contentRangeTotal 来自**探针自证请求**（业务 HttpClient 带同偏移 Range 头，open
  后 abort 不消费体）；引擎事件面（DownloadEvents）不携带 Content-Range——引擎自身三检的证据是
  resumeStatus=206 且 engineResumeConnected=true 且 facts.failedFired 未置位（若三检不过引擎走 onFailed
  终态，S7 将出现 engineFailed 键组）。
- ③ S5/S6 会写 DB（onPaused→updateStatus(Stopped)、onProgress→updateProgress）——探针监听器即"事件消费方"
  （对照 Index 消费链）； restarted 后 Stopped 行读回 status=1 是 U1.1 R2 强制规则，非缺陷。
- ④ 任一步骤失败形态：该步行以 `errCode/errMessage` 键组替代正常键集（每步骤仍恰一行）；S4~S7 引擎失败快速
  emit（engineFailed=true errCode=<N>，不拖满超时）。业务侧吞掉的异常细节查 hilog tag `Downloader`/`HttpClient`
  /`DownloadStore`（domain 0x0000，非 [XDM_PROBE] 行）。

## 5. 人工 UI 走查节（不计入机械判定，随会话 A 前后顺带完成）

1. **新建对话框**：主页点"新建"→ 对话框含 ND_TITLE/ND_ADDRESS/ND_FILE/LBL_SAVE_IN/ND_DOWNLOAD_NOW/ND_CANCEL 文案；目录行只读展示 `<filesDir>/Downloads`。
2. **MSG_INVALID_URL**：地址输入 `ftp://x` → 点 Download Now → 弹 "Download address is invalid or unsupported"。
3. **MSG_NO_FILE**：合法地址 + 清空文件名 → 弹 "Please enter file name"。
4. **UrlChanged 自动推导**：地址输入 `http://<base>/slow.bin?ms=40` → 文件名自动填充 `slow.bin`（query 剥离）；手改文件名后再改地址，已改名不被覆盖（fileNameTouched 守卫）。
5. **确认链**：合法地址+默认名 → Download Now → 对话框关闭 → 进行中页签出现新行。
6. **实时进度**：进行中行进度条滚动、速度（formatSpeed）/剩余时间（toHMS）逐秒刷新。
7. **暂停/继续**：点"暂停"→ 行状态停转、按钮变"继续"；点"继续"→ 进度从停点续跑（S5/S6 的 UI 对应面）。
8. **已完成页签**：下载完成后行迁移到 Complete 页签、无按钮。
9. **重启历史可见**：§2 重启后主页进行中页签可见 Stopped 历史行（探针记录 probe-u2-<runId>.bin 或人工新建的行）。

## 6. 环境差异分支（重跑指引）

2026-10-08 口径修正：旧 S5 把首个内容分片大小与所有分片累计下载量相等作为验收，这是单线程时期遗留的错误条件。现逐片检查已报告前缀被文件覆盖，并检查逐片账本之和等于暂停回声。文件可带陈旧尾部、worker计数也可滞后，因此文件比账本大不是独立故障证据；禁止用stat尺寸回填业务账本。新detailFile保留每片数据；此改动不宣称严格暂停排空已实现，不改写历史日志。S6自证请求的总pauseOffset也不代表分片引擎的每个恢复起点，实际续传仍须由P2-U2逐片服务端Range证据与最终内容核对验收。

| 现象 | 判定 | 处置 |
|---|---|---|
| S1 `rangeSupported=false` 或 `errCode/errMessage`（源不可达 2300028/2300007） | env | 测试源未启动/地址错/防火墙——§1 重启服务器、核对局域网 IP 后重跑 |
| S5 `pauseLanded=false`（快源跑赢暂停） | **UNVERIFIED** | 换慢速源重跑：确认 TextInput 指向 `/slow.bin?ms=40`（可增大 ms 参数如 `ms=100`）；公网源则换更大文件 |
| S5 `pauseLanded=true` 但 `filesCoverLedger=false` 或 `ledgerMatchesPause=false` | FAIL | 分流 business-code（已报告前缀超过对应文件，或暂停总账与逐片账不一致）；先拉取detailFile对照每片，不用首文件大小对比总账 |
| S6 `resumeStatus=200` 或 `startMatches=false`/`totalMatches=false` | UNVERIFIED/FAIL | resumeStatus=200→源不支持 Range（S1 应已拦截，查 env）；matches=false→分流 business-code（Range 头生成/三检判定回归），附 S1/S5 键组定位 |
| S6 `engineFailed=true errCode=<N>` | FAIL | 分流 business-code：errCode=5（InvalidResponse：源状态/Content-Range 不符）、2（NonResumable）、4（MaxRetry，连接期反复失败查 env） |
| S7 `allSpotsMatch=false` / `spotChecks` 含 `=x` | FAIL | 分流 business-code（206 续传偏移错位——字节级正确性破坏），附 S5 pauseOffset/S6 startMatches 定位 |
| S7 `tempDirGone=false` | FAIL | 分流 business-code（清 temp 收尾回归；残留文件查 `<filesDir>/../temp/<id>/`） |
| S7/S8 `dbKind=-1`（行缺失） | FAIL | 分流 business-code（markAsFinished 落库链路）；先查 hilog `DownloadStore` |
| S9 `pendingFound=false rowFound=false` | UNVERIFIED | 未跑会话 A 或 pending 被清——先跑会话 A 再按 §2 重启跑会话 B |
| S9 `pendingFound=true` 但 `rowFound=false` | FAIL | 分流 business-code（杀进程后持久行丢失） |
| S2 `headersAtRedirect=false` | **观测事实** | 不计业务判定——决策 9 降级 D1 的既定分支（d.ts 无最终 URL 字段）；结论回写计划（Phase 2 前是否恢复 1:1 回写的输入） |
| 模拟器 vs 真机 | — | 真机优先（INTERNET 已具备）；结论按实际运行环境标注回写计划（与 U0.2/U1.1 同口径） |

## 7. 会话守卫冒烟（U0.2/U1.1 同款硬要求）

1. 自动会话 A 运行中（S4~S7 下载期）按 HOME 退后台；
2. 暖启动重进探针首页 → P1-U2 → 点"运行全部"（新会话）；
3. 预期：新会话标记行完整、BEGIN/END 的 runId 单调配对、**无旧会话步骤标记行串入新会话、无孤儿 END**（旧会话异步续体在 await 恢复后过 isCurrent 守卫静默退出）；
4. 会话运行中点 S9"执行"：被 ProbePage.sessionRunning 守卫忽略——等 END 后再点。

## 8. 回贴

把 probe-P1-U2.log 全文（[XDM_PROBE] 行一律不要手工删改）发给 AI，由 xdm-probe-verify 核对；
结论（含验证环境：真机/模拟器）与 U0.2/U1.1 同口径写回 MIGRATION_PLAN。本单元特有回写项：
S2 headersAtRedirect 观测值（openQuestion 1：Phase 2 前是否恢复重定向 1:1 回写）、S6 206 三检实测、
S5 暂停确定性（pauseLanded 比率）。验收锚：URL 完整下载到沙箱（S7 finalSize/字节抽查）、列表实时进度
（S4 + §5-6 走查）、暂停恢复 206 链路（S5+S6）、重启后历史可见（S9 + §5-9 走查）。
