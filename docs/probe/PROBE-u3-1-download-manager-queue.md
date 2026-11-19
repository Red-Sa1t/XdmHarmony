# 探针运行手册：P3-U1 队列调度+并发上限探针（DownloadManager 排队/补位/停止路径）

> 工程根：D:\git\HarmonyPC\XdmHarmony ｜ bundle：com.neuohos.xdm ｜ 预期表：[EXPECT-u3-1-download-manager-queue.json](./EXPECT-u3-1-download-manager-queue.json)
> hdc 未入 PATH，用全路径：HDC="D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
> 探针页形态：**autoStart=false + 单会话自动 S1→S4**（四步全 autoRun，无人工设备侧中断点）——
> 填测试源 → 点"运行全部"，一次跑完门参数/基线/源预检 → 6 下载提交即时集合 → 拥挤窗口轮询
> maxConcurrent+补位序列 → 停止/取消路径。
> 单元验收核心（UNIT_CATALOG U3.1"排队正确（PROBE 记录并发数不超 3）"）：S2 `liveAfterSubmit=3
> queuedAfterSubmit=3`（上限即时锚）+ S3 `peakLive<=3` 且 `swapTargets=4/5/6`（FIFO 补位序锚）
> + S4 排队取消不补位/队列空 stop 无补位。

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

- **复用指引**：P3-U1 不新增服务器文件——直接复用 P1-U2 主机侧测试源。本探针消费
  `/slow.bin?ms=0`（S1 源预检，bytes=0-0 单字节探活）与 `/slow.bin?ms=300`（S2/S3/S4 全部下载
  ——**ms=300 由探针 URL 参数携带**，server 端 ms 参数任意整数合法，`P1-U2-download-server.js:112-131`
  已核实，零改动复用）。
- **局域网 IP 纪律**：服务器绑 0.0.0.0；设备（模拟器/真机）内 `127.0.0.1` 是自身回环——探针页
  TextInput 必须填**主机局域网 IP**（如 `http://192.168.1.20:8080`）。主机防火墙需放行该端口。
- **拥挤窗口说明**：`/slow.bin?ms=300` 每 64KB 块延迟 300ms，单下载 8 连接并行 ≈3-5s 完成——
  6 个快速提交后前 3 个占满并发槽（默认 maxParallelDownloads=3）、后 3 个排队；首个完成距提交
  >2s，S2 即时集合读取窗口（提交完立即读）必然落在拥挤期内。S3 轮询 90s 预算充裕（6 个下载
  最坏 ≈2×5s+排队 3×5s≈25s）。
- 24 连接压力注记：3 并发×8 分段=24 个 HTTP 连接打 Node 单线程测试源——ms=300 下服务端仅串行
  写块，风险低；若 S3 出现 failed>0，按 §5 分流 env（改探针页 URL 为 ms=600 或减提交数重跑）。
- 服务器控制台逐请求打印实收 Range——第二证据轨（补位次序可交叉核对：每个完成事件后应见
  新的 `bytes=0-` 探测请求，属排队项起跑）。

## 2. 运行探针（设备侧，S1→S4 单会话自动）

```bash
cd /d D:\git\HarmonyPC\XdmHarmony
devecocli emulator start "Pura 90"                # 模拟器兜底（未启动时执行；真机 USB 直连跳过本行）
devecocli device list                             # 设备就绪确认（多设备时后续 devecocli/hdc 命令需 --device <serial>）
devecocli run --module entry                      # 构建+安装+拉起应用主页（AI 已构建过时：加 --skip-build）
# 打开探针页（EntryAbility 解析 want 参数 page=probe，支持冷/暖启动）：
hdc shell aa start -b com.neuohos.xdm -a EntryAbility --ps page probe
# 探针首页 → P3-U1 卡片 → 核对 TextInput 测试源 → 点"运行全部"（单会话自动 S1→S4）
```

> 模板差异说明：通用模板写 `--ability ProbeAbility`——本工程无独立探针 Ability（module.json5 仅
> mainElement=EntryAbility），探针页由 EntryAbility 解析 want 参数 `page=probe` 拉起（U0.1 路由
> 契约；P1-U2/P2-U1/P2-U2 手册同款注记）。

> **会话纪律（设计书 §8-1）**：探针会话内不切页——P3-U1 四步连续运行，探针 S1 已通过
> manager.init"后到者接管"事件面；会话中途回 Index 页（aboutToAppear 再 init）会把事件袋换回
> Index，S3 轮询虽继续但事件序流断流（swapTargets 观测缺失）。跑完后再切页无碍。

### 需人工配合的步骤（本单元仅环境侧，设备侧无中断动作）

1. **主机侧**：启动测试源 `node P1-U2-download-server.js`（§1）并放行防火墙端口——唯一环境前置；
2. **设备侧**：探针页 TextInput 填**主机局域网 IP**（禁 127.0.0.1，模拟器内 127.0.0.1 是自身回环）→
   点"运行全部"——此后 S1→S4 单会话全自动，无人工设备侧动作（无复制文本/浏览器/通知类步骤）；
3. **会话内不切页**（见上会话纪律）；S1 `liveBaseline/queuedBaseline` 非零时杀进程重启应用再点运行
   （双集合纯内存，重启即清空）。

## 3. 抓取标记（END 行出现后）

```bash
"D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" shell "hilog -x | grep XDM_PROBE" > probe-P3-U1.log
# 兜底：缓冲被冲掉时取探针写盘结果（路径见 BEGIN 行 filesDir=）
hdc shell "cat <filesDir>/probe-latest.txt"
# 探针闪退时：devecocli log --crash
# 业务侧诊断（manager/引擎吞掉的异常走这里，非探针标记）：
hdc shell "hilog -x | grep -E 'DownloadManager|PieceScheduler|PieceGrabber'"
# 主机侧第二证据：P1-U2-download-server.js 控制台逐请求 Range 打印（补位次序交叉核对）
```

## 4. 每步骤预期日志标记表（判定细则见 EXPECT 表）

hilog 过滤 `XDM_PROBE` 后：**恰 7 行**（BEGIN+S1+S2+S3+S4+SUMMARY+END，单会话）。行格式严格为
`[XDM_PROBE][P3-U1][<步骤>] key=value ...`（FORMAT 正则 `^\[XDM_PROBE\]\[([A-Z0-9-]+)\]\[([A-Za-z0-9-]+)\]\s(.+)$`）。
`<N>` 表浮动值；观测行不含 PASS/FAIL 判定词。

| 步骤 | 预期标记行（示例） | 判定要点 |
|---|---|---|
| BEGIN | `runId=<HHmmss> filesDir=<非空沙箱files路径>` | 与 END 按 runId 配对；单会话独立 runId |
| S1 | `sourceUrl=<base>/slow.bin?ms=0 maxParallel=3 liveBaseline=0 queuedBaseline=0 sourceStatus=206 chunks=1` | **门默认值实测锚（Config.getMaxParallelDownloads=3，Config.cs:104）+单例干净基线锚**（liveBaseline/queuedBaseline=0——上轮探针残留会话则非零，见 §5 分流）；sourceStatus=206 测试源可达+Range 能力（探针自建 requestInStream，不走引擎）；chunks=1（bytes=0-0 单字节体） |
| S2 | `submitted=6 submitOrder=1/2/3/4/5/6 liveAfterSubmit=3 queuedAfterSubmit=3 activeAfterSubmit=6 queuedOrder=4/5/6` | **上限即时锚（本单元核心验收之一）**：liveAfterSubmit=3（门过 3 个 launchStart）、queuedAfterSubmit=3（门挡 3 个入队——门判定在 admitNew 单调用栈同步完成）、activeAfterSubmit=6（:40 口径 live+queued）、queuedOrder=4/5/6（FIFO 插入序）；submitOrder=1/2/3/4/5/6（await 串行提交序） |
| S3 | `samples=<N> peakLive=3 queuedPeak=3 swapCount=3 swapTargets=4/5/6 swapSources=1/2/3 startedFirstOrder=1/2/3 allFinished=6 failed=0 paused=0 started=6 elapsedMs=<N>` | **并发峰值+补位序锚（本单元核心验收之二）**：peakLive<=3（轮询采样上限——补位与完成在同一事件栈内同步完成，轮询只见满槽或空）；swapCount=3+swapTargets=4/5/6（onFinished 后紧邻 onStarted 的补位对，FIFO 取队首，priority 全 0）；swapSources=1/2/3 为观测值**不判定次序**（服务端响应次序非确定）；allFinished=6 failed=0（全收敛） |
| S4 | `submittedMore=4 liveAfterSubmit2=3 queuedAfterSubmit2=1 cancelledQueued=10 queuedAfterCancel=0 liveAfterCancel=3 newStartsAfterCancel=0 queuedCancelledEcho=1 pausedCount=3 liveAfterStop=0 newStartsAfterStop=0 failed=0` | **停止/取消路径锚（本单元核心验收之三）**：liveAfterSubmit2=3+queuedAfterSubmit2=1（#7/#8/#9 live+#10 排队）；queuedAfterCancel=0（排队取消即时摘除）；**newStartsAfterCancel=0（排队取消不补位——源码 StopDownloads :360-369 无 ProcessNextQueuedItem）**；queuedCancelledEcho=1（ManagerHooks.onQueuedCancelled 回声恰一次）；pausedCount=3（3 个 live stop 的 onPaused 回声）；liveAfterStop=0+newStartsAfterStop=0（**队列空 stop 无补位**） |
| SUMMARY | `[SUMMARY] S1=<...>|S2=<...>|S3=<...>|S4=<...>` | 恰 4 段（S1..S4，各段含关键键：S1=maxParallel,sourceStatus；S2=liveAfterSubmit,queuedAfterSubmit；S3=peakLive,swapCount；S4=newStartsAfterCancel,newStartsAfterStop）；环形缓冲兜底锚；单行 <1500B 由 ProbeKit 两级降级保证 |
| END | `ok=true steps=4 elapsedMs=<N>>=0` | ok=true 表示本次会话无脚手架级异常（步骤级 catch 不置 false）；steps=4 与步骤行数互证；ok=false→分流 probe-code |

预期标记行全文示例（占位示意值，非判定锚——判定一律以 EXPECT 表范围/存在性表述为准）：

```
[XDM_PROBE][P3-U1][BEGIN] runId=153012 filesDir=/data/app/el2/100/base/com.neuohos.xdm/haps/entry/files
[XDM_PROBE][P3-U1][S1] sourceUrl=http://192.168.1.20:8080/slow.bin?ms=0 maxParallel=3 liveBaseline=0 queuedBaseline=0 sourceStatus=206 chunks=1
[XDM_PROBE][P3-U1][S2] submitted=6 submitOrder=1/2/3/4/5/6 liveAfterSubmit=3 queuedAfterSubmit=3 activeAfterSubmit=6 queuedOrder=4/5/6
[XDM_PROBE][P3-U1][S3] samples=214 peakLive=3 queuedPeak=3 swapCount=3 swapTargets=4/5/6 swapSources=1/2/3 startedFirstOrder=1/2/3 allFinished=6 failed=0 paused=0 started=6 elapsedMs=16782
[XDM_PROBE][P3-U1][S4] submittedMore=4 liveAfterSubmit2=3 queuedAfterSubmit2=1 cancelledQueued=10 queuedAfterCancel=0 liveAfterCancel=3 newStartsAfterCancel=0 queuedCancelledEcho=1 pausedCount=3 liveAfterStop=0 newStartsAfterStop=0 failed=0
[XDM_PROBE][P3-U1][SUMMARY] S1=maxParallel=3,sourceStatus=206|S2=liveAfterSubmit=3,queuedAfterSubmit=3|S3=peakLive=3,swapCount=3,swapTargets=4/5/6|S4=newStartsAfterCancel=0,newStartsAfterStop=0
[XDM_PROBE][P3-U1][END] ok=true steps=4 elapsedMs=22500
```

失败形态：步骤异常 catch emit `errCode/errMessage`（2300028 超时/2300007 拒连/1390000x 盘错）；
S2 引擎失败走 S3 的 failed 计数（`failed>0`）——查 hilog PieceScheduler/PieceGrabber。

## 5. 环境差异分支（重跑指引）

| 现象 | 判定 | 处置 |
|---|---|---|
| S1 `sourceStatus≠206` 或 `errCode/errMessage` | env | 测试源未启动/地址错/防火墙——§1 重启服务器、核对局域网 IP 后重跑 |
| S1 `maxParallel≠3` | FAIL | 分流 business-code（门默认值被改——查 Config 第 7 键 init 读取链/DEFAULT 常量；或上轮 setMaxParallelDownloads 残留 preferences） |
| S1 `liveBaseline>0 或 queuedBaseline>0` | **UNVERIFIED** | 上轮探针/业务会话残留运行中下载——杀进程重启应用后重跑（双集合纯内存，重启即清空） |
| S2 `liveAfterSubmit<3` 或 `queuedAfterSubmit≠3` | FAIL | 分流 business-code（门判定穿透/入队丢失——查 hilog DownloadManager admitNew 与 QueueAlgo pickNext；若首发窗口被首完成击穿见下行 UNVERIFIED） |
| S2 `liveAfterSubmit=3` 但 S3 `peakLive<3` 且 `allFinished=6` | **UNVERIFIED** | <3 并发窗口被首完成击穿（设备网络栈握手慢）——上限正确性由 S2 即时集合独立保证，增大 ms（改探针页 URL ms=600）重跑 |
| S3 `swapCount≠3` 或 `swapTargets≠4/5/6` | FAIL | 分流 business-code（FIFO 补位序破坏——查 DownloadManager.dequeueOne/QueueAlgo pickNextQueuedId 严格 `>` 首见胜出；附事件序流） |
| S3 超时（`allFinished<6` 或 `elapsedMs`≈90000） | FAIL | 分流 business-code（补位停摆/下载不收敛——查 hilog DownloadManager/PieceScheduler；先排除测试源过慢：server 控制台有无持续输出） |
| S3 `failed>0` | env→FAIL | 先查 server 控制台（24 连接压力/超时）分流 env（ms=600 或减 SUBMIT_COUNT 重跑）；server 无异常再查引擎 hilog |
| S4 `liveAfterSubmit2≠3 或 queuedAfterSubmit2≠1` | FAIL | 分流 business-code（S3 收尾态残留 live/queued——S3 未排空即进 S4，查 S3 超时分支） |
| S4 `newStartsAfterCancel≠0` | FAIL | 分流 business-code（**排队取消补位回归**——stopOne queued 分支误入补位路径） |
| S4 `queuedCancelledEcho≠1` | FAIL | 分流 business-code（ManagerHooks 回声缺失/多次——排队取消回声链回归） |
| S4 `pausedCount≠3` 或 `liveAfterStop≠0` | FAIL | 分流 business-code（停止排空回归——onPaused 回声缺失/取消排空不净，查 hilog PieceScheduler stop 链） |
| S4 `newStartsAfterStop≠0` | FAIL | 分流 business-code（队列空 stop 补位回归——dequeueOne 空队列 no-op 失效） |
| 模拟器 vs 真机 | — | 真机优先（并发/时序更真实）；结论按实际运行环境标注回写计划 |

## 6. 主机侧第二证据：server 控制台补位次序交叉核对

S3 期间，server 控制台每个下载完成点后应出现新一批 `range=bytes=0-` 探测请求（排队项起跑的
首个探测）。手工对账（可选，回贴时一并给 AI）：

| # | 完成下载（序号） | 随后出现的新探测请求 | 对应 swapTarget（S3 swapTargets 序） | 一致？ |
|---|---|---|---|---|
| 1 | 例：#2 | bytes=0-（新连接批） | 4 | o |
| 2 | … | … | … | |

> 注：探测请求 `range=bytes=0-` 只出现在全新 start（首发三元组与各补位项）；已暂停记录恢复
> （本探针不涉及）才是 bytes=s- 续传形态。

## 7. 会话守卫冒烟（可选）

1. 探针会话运行中（S3 轮询期）按 HOME 退后台 → 暖启动重进 → 重跑：新会话标记行完整、无旧会话
   行串入、无孤儿 BEGIN/END（U0.2 会话代际守卫同款）；
2. 重跑残留：S1 `liveBaseline/queuedBaseline` 非零即上轮残留——杀进程重启后重跑（§5 分流）。

## 8. 回贴

把 probe-P3-U1.log 全文（[XDM_PROBE] 行一律不要手工删改）+ §6 对账表（可选）发给 AI，由
xdm-probe-verify 核对；结论（含验证环境：真机/模拟器）与既有单元同口径写回 MIGRATION_PLAN。
本单元特有回写项：①S1 门默认值实测（maxParallel=3——Config 第 7 键 init 链实测锚）；
②S2 即时集合（liveAfterSubmit=3/queuedAfterSubmit=3——上限与排队实测吻合）；
③S3 补位序（swapTargets=4/5/6——FIFO 落地证据）；④S4 停止/取消路径（排队取消不补位+队列空
stop 无补位）。
验收锚：排队与上限实测吻合（S2+S3）+ 事件面零破坏佐证（S2~S4 全程探针事件袋与业务共面——
若 Index 列表状态翻转/落库链路被 manager 破坏，探针 failed/paused 计数即异常）。
