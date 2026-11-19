# 探针运行手册：P3-U2 限速+定时调度探针（SpeedLimiter 异步睡眠补偿 + Scheduler 定时启停）

> 工程根：D:\git\HarmonyPC\XdmHarmony ｜ bundle：com.neuohos.xdm ｜ 预期表：[EXPECT-u3-2-speed-limit-retry-scheduler.json](./EXPECT-u3-2-speed-limit-retry-scheduler.json)
> hdc 未入 PATH，用全路径：HDC="D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
> 探针页形态：**autoStart=false + 单会话自动 S1→S4**（四步全 autoRun，无人工设备侧中断点）——
> 填测试源 → 点"运行全部"，一次跑完参数装配/源预检 → 限速速率区间观测（引擎直驱 4MiB@1024KB/s）
> → 定时窗停止观测（含 60~120s 分钟边界等待）→ 环境恢复。**总时长 ≈4 分钟**（S2 ≈5s + S3 边界
> 等待 ≤2min + 排空轮询；超时预算 S3=210s）。
> 单元验收核心（UNIT_CATALOG U3.2"限速实测吻合；定时窗行为对照源码"）：S2 `avgRateKBs∈[716.8,1331.2]`
> （1024±30%）+ `activeSegmentMax=1`（单分段口径）+ `burstReopenCount=0`（4MiB<8MiB 水位必不触达）
> ；S3 `liveAfter=0 queuedAfter=0 pausedEcho=1 queuedCancelledEcho=2 resumedEcho=0`（end 边界全停，
> 对照 StopDownloads :347-380 双分支）+ `tickCountAfter>tickCountBefore`（定时器活性）。

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

- **复用指引**：P3-U2 不新增服务器文件——直接复用 P1-U2 主机侧测试源。本探针消费
  `/big.bin`（S1 源预检 bytes=0-0 + **S2 限速步全速源**——无 Range 时 200 一次性整流 4MiB、
  带 Range 206 区间流，S2 单分段闭窗请求 bytes=0-4194303）与 `/slow.bin?ms=2500`
  （**S3 定时窗长活源**——每 64KB 块间隔 2500ms，64 块 ≈160s > 边界最晚 120s，保证 live 在
  界内；`P1-U2-download-server.js:112-131` ms 参数任意非负整数合法，零改动复用）。
- **局域网 IP 纪律**：服务器绑 0.0.0.0；设备（模拟器/真机）内 `127.0.0.1` 是自身回环——探针页
  TextInput 必须填**主机局域网 IP**（如 `http://192.168.1.20:8080`）。主机防火墙需放行该端口。
- **网络带宽前提**：S2 限速判定要求**网络快于限额**（1024KB/s ≈1MB/s——局域网/真机 WiFi 均满足；
  网络慢于限额时引擎无从超速，avgRate 落下界外，见 §5 env 分流）。
- 服务器控制台逐请求打印实收 Range——第二证据轨（S3 边界停止后应见 live 连接断开即无新请求）。

### 可替换参数（源码常量，改后需重装 HAP；默认值即验收口径）

| 参数 | 文件 | 默认 | 说明 |
|---|---|---|---|
| `LIMIT_KBPS` | `entry/src/main/ets/probe/units/ProbeSpeedLimit.ets` | 1024 | S2 限速限额（KB/s）；±30% 判定窗随之换算（EXPECT 同步改） |
| `SLOW_MS` | 同上 | 2500 | S3 长活源块间隔（ms）；160s>边界最晚 120s 需保持 `64×ms/1000 > 120` |
| `BOUNDARY_OFFSET_MIN` | 同上 | 2 | S3 目标分钟偏移（当前+2）；>1 保证重定相位后至少一拍落入 |
| `S2_TIMEOUT_MS` / `S3_TIMEOUT_MS` / `POLL_MS` | 同上 | 60000/210000/100 | 步骤超时与轮询周期 |

## 2. 运行探针（设备侧，S1→S4 单会话自动）

```bash
cd /d D:\git\HarmonyPC\XdmHarmony
devecocli emulator start "Pura 90"                # 模拟器兜底（未启动时执行；真机 USB 直连跳过本行）
devecocli device list                             # 设备就绪确认（多设备时后续 devecocli/hdc 命令需 --device <serial>）
devecocli run --module entry                      # 构建+安装+拉起应用主页（AI 已构建过时：加 --skip-build）
# 打开探针页（EntryAbility 解析 want 参数 page=probe，支持冷/暖启动）：
hdc shell aa start -b com.neuohos.xdm -a EntryAbility --ps page probe
# 探针首页 → P3-U2 卡片 → 核对 TextInput 测试源 → 点"运行全部"（单会话自动 S1→S4）
```

> 模板差异说明：通用模板写 `--ability ProbeAbility`——本工程无独立探针 Ability（module.json5 仅
> mainElement=EntryAbility），探针页由 EntryAbility 解析 want 参数 `page=probe` 拉起（U0.1 路由
> 契约；既有单元同款注记）。

> **会话纪律**：探针会话内不切页——P3-U2 四步连续运行（≈4 分钟），探针 S1 已通过 manager.init
> "后到者接管"事件面；会话中途回 Index 页会把事件袋换回 Index，S3 的 pausedEcho/resumedEcho
> 回声断流。跑完后再切页无碍。

> **时间窗纪律（S3 确定性前提）**：**避开午夜 ±2min 运行**（23:58~00:02）——目标分钟=当前+2 跨日
> 时 dayBit 仍取当日位，跨日后的 tick 位匹配失败（S3 超时假 FAIL，见 §5 env 分流）。设备时钟
> 与本地时区一致即可（Scheduler 用设备本地时钟，对照源 DateTime.Now）。

### 需人工配合的步骤（本单元仅环境侧，设备侧无中断动作）

1. **主机侧**：启动测试源 `node P1-U2-download-server.js`（§1）并放行防火墙端口——唯一环境前置；
2. **设备侧**：探针页 TextInput 填**主机局域网 IP**（禁 127.0.0.1）→ 点"运行全部"——此后
   S1→S4 单会话全自动（S3 含 ≤2 分钟边界等待，勿中途杀进程/切页）；
3. S1 `liveBaseline/queuedBaseline` 非零时杀进程重启应用再点运行（双集合纯内存，重启即清空）。

## 3. 抓取标记（END 行出现后）

```bash
"D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" shell "hilog -x | grep XDM_PROBE" > probe-P3-U2.log
# 兜底：缓冲被冲掉时取探针写盘结果（路径见 BEGIN 行 filesDir=）
hdc shell "cat <filesDir>/probe-latest.txt"
# 探针闪退时：devecocli log --crash
# 业务侧诊断（Scheduler/引擎吞掉的异常走这里，非探针标记）：
hdc shell "hilog -x | grep -E 'Scheduler|PieceScheduler|DownloadManager'"
# 主机侧第二证据：P1-U2-download-server.js 控制台——S3 边界到点后 slow.bin 连接断开（无新 Range 请求）
```

## 4. 每步骤预期日志标记表（判定细则见 EXPECT 表）

hilog 过滤 `XDM_PROBE` 后：**恰 7 行**（BEGIN+S1+S2+S3+S4+SUMMARY+END，单会话）。行格式严格为
`[XDM_PROBE][P3-U2][<步骤>] key=value ...`（FORMAT 正则 `^\[XDM_PROBE\]\[([A-Z0-9-]+)\]\[([A-Za-z0-9-]+)\]\s(.+)$`）。
`<N>` 表浮动值；观测行不含 PASS/FAIL 判定词。

| 步骤 | 预期标记行（示例） | 判定要点 |
|---|---|---|
| BEGIN | `runId=<HHmmss> filesDir=<非空沙箱files路径>` | 与 END 按 runId 配对；单会话独立 runId |
| S1 | `sourceUrl=<base>/big.bin limitKBps=1024 maxSegments=1 maxParallel=3 liveBaseline=0 queuedBaseline=0 sourceStatus=206 chunks=1 scheduleEnabledBefore=false speedBefore=0` | **限速装配锚**：setSpeedLimit(true,1024) 生效回显（Config 第 8/9 键写入链）+ setMaxSegments(1)（S2 单分段口径）；liveBaseline/queuedBaseline=0 单例干净基线（非零→UNVERIFIED 杀进程重启）；sourceStatus=206 测试源可达+Range 能力；scheduleEnabledBefore/speedBefore=S1 前原值（默认 false/0——S4 恢复对照） |
| S2 | `bytes=4194304 elapsedMs=<N≈4000-5000> avgRateKBs=<N.n∈[716.8,1331.2]> instantMinKBs=<N> instantMaxKBs=<N> activeSegmentMax=1 sleepCount=<N>>=1 sleepTotalMs=<N> peakQueuedBytes=<N> burstReopenCount=0 finished=true` | **限速实测锚（本单元核心验收之一）**：avgRateKBs∈[716.8,1331.2]（4096KB/elapsed 落 1024±30%——限速数学时限流，D3 双形态下聚合网络速率均收敛 share）；activeSegmentMax=1（maxSegments=1 时 COLD-F1 直派单片闭窗）；burstReopenCount=0（4MiB<8MiB 水位必不触达）；finished=true（onStarted→onProgress→onFinished 完成链走通=零回归佐证）；sleepCount>=1（超速睡眠确实发生——1024KB/s 限额对局域网全速源必睡）；sleepTotalMs/peakQueuedBytes/instantMin/Max 为事实项：peakQueuedBytes≈0=平台有原生背压（纯睡眠补偿形态）；接近 4MiB=无背压走 burst-chasing（断流排空形态）——**两者均合法不判 FAIL**（D3 结论回写项） |
| S3 | `targetMinute=<HH:MM> dayBit=<N> submitted=3 liveBefore=1 queuedBefore=2 liveAfter=0 queuedAfter=0 pausedEcho=1 queuedCancelledEcho=2 resumedEcho=0 tickCountBefore=<N> tickCountAfter=<N>>tickCountBefore elapsedMs=<N≈120000-130000>` | **定时窗停止锚（本单元核心验收之二）**：liveBefore=1+queuedBefore=2（maxParallel=1 门即时集合）；**liveAfter=0+queuedAfter=0（end 边界全停）**；pausedEcho=1（live 整停 onPaused 回声——Scheduler stopAll 两趟：排队先行清退、live 停止回声补位对空队列 no-op）；queuedCancelledEcho=2（排队清退 hooks 回声——StopDownloads :360-369 双分支）；**resumedEcho=0（start==end 且 end 先判先 return——start 分支永不触达，源码 :58-63 次序保真佐证）**；tickCountAfter>tickCountBefore（定时器活性——重定相位后至少一拍） |
| S4 | `restoredLimit=0 restoredLimitEnabled=false restoredMaxSegments=8 restoredMaxParallel=3 restoredScheduleEnabled=false schedulerRunning=true` | **环境恢复锚**：S1 快照回写读回校验（默认态 restoredLimit=0/enabled=false=限速关闭——生产默认路径零回归保证）；schedulerRunning=true（生产态常驻——S3 重定相位后 start() 幂等保持运行） |
| SUMMARY | `[SUMMARY] S1=<...>|S2=<...>|S3=<...>|S4=<...>` | 恰 4 段（S1..S4，各段含关键键：S1=limitKBps,sourceStatus；S2=avgRateKBs,activeSegmentMax,burstReopenCount；S3=liveAfter,pausedEcho,resumedEcho；S4=restoredLimit,schedulerRunning）；环形缓冲兜底锚；单行 <1500B 由 ProbeKit 两级降级保证 |
| END | `ok=true steps=4 elapsedMs=<N>>=0` | ok=true 表示本次会话无脚手架级异常；steps=4 与步骤行数互证；ok=false→分流 probe-code |

预期标记行全文示例（占位示意值，非判定锚——判定一律以 EXPECT 表范围/存在性表述为准）：

```
[XDM_PROBE][P3-U2][BEGIN] runId=153012 filesDir=/data/app/el2/100/base/com.neuohos.xdm/haps/entry/files
[XDM_PROBE][P3-U2][S1] sourceUrl=http://192.168.1.20:8080/big.bin limitKBps=1024 maxSegments=1 maxParallel=3 liveBaseline=0 queuedBaseline=0 sourceStatus=206 chunks=1 scheduleEnabledBefore=false speedBefore=0
[XDM_PROBE][P3-U2][S2] bytes=4194304 elapsedMs=4218 avgRateKBs=971.2 instantMinKBs=612 instantMaxKBs=1394 activeSegmentMax=1 sleepCount=31 sleepTotalMs=2100 peakQueuedBytes=1638400 burstReopenCount=0 finished=true
[XDM_PROBE][P3-U2][S3] targetMinute=15:32 dayBit=32 submitted=3 liveBefore=1 queuedBefore=2 liveAfter=0 queuedAfter=0 pausedEcho=1 queuedCancelledEcho=2 resumedEcho=0 tickCountBefore=260 tickCountAfter=263 elapsedMs=121904
[XDM_PROBE][P3-U2][S4] restoredLimit=0 restoredLimitEnabled=false restoredMaxSegments=8 restoredMaxParallel=3 restoredScheduleEnabled=false schedulerRunning=true
[XDM_PROBE][P3-U2][SUMMARY] S1=limitKBps=1024,sourceStatus=206|S2=avgRateKBs=971.2,activeSegmentMax=1,burstReopenCount=0|S3=liveAfter=0,pausedEcho=1,resumedEcho=0|S4=restoredLimit=0,schedulerRunning=true
[XDM_PROBE][P3-U2][END] ok=true steps=4 elapsedMs=128116
```

失败形态：步骤异常 catch emit `errCode/errMessage`（2300028 超时/2300007 拒连/1390000x 盘错）；
S2 未完成走 `finished=false`（超时观测，EXPECT 分流）。

## 5. 环境差异分支（重跑指引）

| 现象 | 判定 | 处置 |
|---|---|---|
| S1 `sourceStatus≠206` 或 `errCode/errMessage` | env | 测试源未启动/地址错/防火墙——§1 重启服务器、核对局域网 IP 后重跑 |
| S1 `liveBaseline>0 或 queuedBaseline>0` | **UNVERIFIED** | 上轮探针/业务会话残留运行中下载——杀进程重启应用后重跑（双集合纯内存） |
| S2 `avgRateKBs<716.8 且 sleepCount=0` | env | 网络慢于限额（引擎无从超速）——换更快网络（真机 WiFi/有线共享）或调低 `LIMIT_KBPS`（如 256，EXPECT 窗随之 ×256/1024）重跑 |
| S2 `avgRateKBs>1331.2` 且 `sleepTotalMs=0` | FAIL | 分流 business-code（限速未生效——查 dispatchPiece share 注入/SpeedLimiter isEnabled/throttleEnabled 门） |
| S2 `activeSegmentMax≠1` | FAIL | 分流 business-code（单分段口径破坏——查 setMaxSegments 生效链/COLD-F1 直派分支） |
| S2 `burstReopenCount≠0` | FAIL | 分流 business-code（4MiB 用例水位必不触达——查 8388608 水位门/泵消费速率） |
| S2 `finished=false`（60s 超时） | FAIL | 分流 business-code（引擎直驱完成链断——查 hilog PieceScheduler；先排除源不可达：S1 已过则查盘空间） |
| S2 `peakQueuedBytes` 极端值 | — | 观测事实不判定（≈0=有原生背压；≈文件长=无背压 burst-chasing）——结论回写设计书 D3 与 RISK_ASSESSMENT（主会话动作） |
| S3 超时且 `tickCountAfter==tickCountBefore` | FAIL | 分流 business-code（定时器死——查 Scheduler.start/EntryAbility 启动链） |
| S3 超时且 `tickCountAfter>tickCountBefore` | FAIL | 分流 business-code（边界数学/位匹配错——查 ScheduleAlgo.scheduledBoundary/matchesDay；纯函数面已由单测锁定，重点查 Config 六键读回） |
| S3 在 23:58~00:02 窗口运行且超时 | env | 午夜跨界 dayBit 失配（目标分钟跨日）——避开午夜 ±2min 重跑（§2 时间窗纪律） |
| S3 `liveBefore≠1 或 queuedBefore≠2` | FAIL | 分流 business-code（maxParallel=1 门判定破坏——对照 P3-U1 S2 排查路径） |
| S3 `resumedEcho≠0` | FAIL | 分流 business-code（start 分支误触——查 scheduledBoundary end-先判次序/start==end 配置写入） |
| S3 `pausedEcho≠1 或 queuedCancelledEcho≠2` | FAIL | 分流 business-code（stopAll 两趟次序/回声链回归——查 Scheduler.stopAllAsync 与 manager stopOne 双分支） |
| 模拟器 vs 真机 | — | 真机优先（网络形态更真实）；结论按实际运行环境标注回写计划 |

## 6. 主机侧第二证据：server 控制台连接轨迹交叉核对

S2 期间应见 `range=bytes=0-`（探测）+ `range=bytes=0-4194303`（单分段闭窗）各一次；S3 期间见
3 个 slow.bin 请求（1 个进入流式传输、2 个排队无请求），**边界到点（targetMinute）后流式连接
断开（Node 控制台无新块写出/连接 close）且无任何新 Range 请求**（resume 未发生佐证）。手工
对账（可选，回贴时一并给 AI）：

| # | 时点 | server 控制台观测 | 对应探针标记 | 一致？ |
|---|---|---|---|---|
| 1 | S2 | bytes=0- + bytes=0-4194303 各一次 | S2 bytes=4194304 finished=true | |
| 2 | S3 提交 | 1 个 slow.bin 流式开始 | S3 liveBefore=1 | |
| 3 | targetMinute | 流式连接断开、无新请求 | S3 liveAfter=0 resumedEcho=0 | |

## 7. 会话守卫冒烟（可选）

1. 探针会话运行中（S3 边界等待期）按 HOME 退后台 → 暖启动重进 → 重跑：新会话标记行完整、无旧
   会话行串入、无孤儿 BEGIN/END（U0.2 会话代际守卫同款）；
2. 重跑残留：S1 `liveBaseline/queuedBaseline` 非零即上轮残留——杀进程重启后重跑（§5 分流）；
   DB 行每轮 +4（probe-p3u2-<runId>-* 主键不冲突）不清理，与既有探针同口径。

## 8. 回贴

把 probe-P3-U2.log 全文（[XDM_PROBE] 行一律不要手工删改）+ §6 对账表（可选）发给 AI，由
xdm-probe-verify 核对；结论（含验证环境：真机/模拟器）与既有单元同口径写回 MIGRATION_PLAN。
本单元特有回写项：①S2 限速实测吻合（avgRateKBs 落窗 + sleepCount>=1——SpeedLimiter.cs:46-82
数学逐字落地证据）；②S2 背压形态结论（peakQueuedBytes 二值分布——D3 设计书的开放问题闭环，
回写设计书 D3 与 RISK_ASSESSMENT）；③S3 定时窗停止（end 先判次序 + stopAll 双分支 + 定时器
活性）；④S4 环境恢复（限速默认关闭态回写=零回归保证）。
验收锚：限速实测吻合（S2）+ 定时窗行为对照源码（S3）+ 既有行为不回归佐证（S2 完成链 + S4
默认态恢复）。
