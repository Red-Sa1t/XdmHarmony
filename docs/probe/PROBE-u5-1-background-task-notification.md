# 探针运行手册：P5-U1 后台长时任务+通知探针

> 工程根：D:\git\HarmonyPC\XdmHarmony ｜ bundle：com.neuohos.xdm ｜ 预期表：[EXPECT-u5-1-background-task-notification.json](./EXPECT-u5-1-background-task-notification.json)
> hdc 未入 PATH，用全路径：HDC="D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
> 探针页形态：**autoStart=false**——S1~S4 autoRun + **S5 后台存活两阶段（armed→survived）单步执行**。
> 单元验收核心（UNIT_CATALOG U5.1"关窗后下载继续；常驻通知；完成通知"）：S2 申请锚（长时任务
> 申请成功性/系统返回 id）+ S3 实况窗 publish 观测（500ms 门直发成功率/耗时/通知存在）+
> S4 完成→释放锚（任务释放/通知数迁移）+ S5 后台存活（任务在/进度推进/未收到系统取消）。
> 前置人工：**启动主机测试源**（P1-U2-download-server.js 零改动复用）。

## 0. 运行次序（本单元）

主会话先跑（S1 挂事件袋+manager.init，探针事件消费方就位），再做 S5 两阶段走查：

1. **启动测试源**（主机侧）：`node docs/probe/P1-U2-download-server.js`（零改动复用）；
2. **主会话**：探针页 → P5-U1 卡片 → 输入测试源地址（默认占位 `http://192.168.1.20:8080`，
   改成主机局域网 IP）→ 点"运行全部"（S1→S4 自动跑完 3×/slow.bin?ms=300 全链；
   S5 发**占位行** phase=placeholder，无副作用）；
3. **S5-armed 单步**：S5 行点"执行"（第 1 次）——提交 1 个长下载（/slow.bin?ms=2000 ≈16-60s，
   视分段数与机型）并申请长时任务，emit `phase=armed`；
4. **人工走查（S5 armed 后立刻做）**：**点窗口 X 关闭 → 等 15-20s → Dock/任务栏点应用图标
   恢复窗口 → 回到探针页 P5-U1**（进程不死是前提——恢复后探针页状态应原样保留）；
5. **S5-survived 单步**：S5 行再点"执行"（第 2 次）——读系统任务表+store 进度+LastCancel，
   emit `phase=survived`（验收锚）；
6. **§5 人工走查清单 8 项**：其中项①②③已在步骤 4 覆盖（走查时顺带观察通知面板），项④⑤⑥
   可在主会话完成后或另起下载验证，项⑦⑧可选（真机附加/设置页 D6 锚）。

## 1. 一次性准备

```bash
# 真机（推荐验证环境：后台保活/通知/2in1 X 拦截都更真实）：真机拒绝未签名 HAP，首次必须做——
devecocli auth login                              # 华为账号登录
#   USB 连接真机并开启开发者模式/USB 调试后：
devecocli signature generate --product default    # 注册设备+生成签名材料，自动写入 build-profile.json5
# 模拟器（兜底/形态验证）：推包不需要签名
devecocli emulator list                           # 确认实例（本机已有 "Pura 90"）
```

> 环境差异：`onPrepareToTerminate`（X 拦截=最小化）**仅 2in1/PC 形态生效**（faqs-ability-151；
> SDK UIAbility.d.ts:788 "takes effect only on 2-in-1 devices"）。模拟器 "Pura 90" 若非 2in1
> 形态，项①走查会观察为"X 直接关闭、下载随后被杀"——走查项①②③按 §7 分支表标注环境后
> 用 2in1 设备/模拟器复验，保活链本身（S5 taskAlive/advanced）两环境均可验。

## 2. 测试源

主机侧零改动复用 P1-U2-download-server.js：

```bash
cd /d D:\git\HarmonyPC\XdmHarmony
node docs/probe/P1-U2-download-server.js
# 路由：/big.bin（4MiB 即回）/slow.bin?ms=N（每 64KB 块间隔 N 毫秒，N 任意非负整数合法）
# 本单元消费：S2 = 3×/slow.bin?ms=300；S5-armed = 1×/slow.bin?ms=2000
```

## 3. 运行（设备侧）

```bash
cd /d D:\git\HarmonyPC\XdmHarmony
devecocli emulator start "Pura 90"                # 模拟器兜底（未启动时执行；真机 USB 直连跳过本行）
devecocli device list                             # 设备就绪确认（多设备时后续命令需 --device <serial>）
devecocli run --module entry                      # 构建+安装+拉起应用主页（AI 已构建过时：加 --skip-build）
```

### 3.1 探针会话

```bash
# 打开探针页（EntryAbility 解析 want 参数 page=probe，支持冷/暖启动）：
hdc shell aa start -b com.neuohos.xdm -a EntryAbility --ps page probe
# 探针首页 → P5-U1 卡片 → 填测试源地址 → "运行全部"（主会话）
# → S5 行"执行"（armed）→ 人工关窗/恢复 → S5 行"执行"（survived）
```

> 模板差异说明：通用模板写 `--ability ProbeAbility`——本工程无独立探针 Ability（module.json5 仅
> mainElement=EntryAbility），探针页由 EntryAbility 解析 want 参数 `page=probe` 拉起（U0.1 路由
> 契约；P1-U2/P2/P3/P4 手册同款注记）。
> 首次运行系统会弹**通知授权对话框**（EntryAbility loadContent 成功后 requestEnableNotification
> 触发）——点允许；拒绝后该接口无法再弹（err 1600004，D7），S1 notifyEnabled=false 且 S3
> publishFail 增长、通知面板不可见，需卸载重装复位授权再跑。

## 4. 抓取标记（S5-survived 单步 END 行出现后）

```bash
"D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" shell "hilog -x | grep XDM_PROBE" > probe-P5-U1.log
# 兜底：缓冲被冲掉时取探针写盘结果（路径见 BEGIN 行 filesDir=）
hdc shell "cat <filesDir>/probe-latest.txt"
# 探针闪退时：devecocli log --crash
# 业务侧诊断（长时任务/通知异常走这里，非探针标记）：
hdc shell "hilog -x | grep -E 'ProgressNotifier|BackgroundTaskManager'"
```

**会话形态**（一次完整流程 = 三段会话，各自 BEGIN/END 配对独立 runId）：

| 会话 | 触发 | 行序列 |
|---|---|---|
| 主会话 | 探针页"运行全部" | BEGIN+S1+S2+S3+S4+S5+SUMMARY+END（8 行；S5 为**占位发射** phase=placeholder） |
| S5 单步会话 #1 | S5 行"执行"（armed 快照空） | BEGIN+S5+SUMMARY+END（4 行；phase=armed） |
| S5 单步会话 #2 | 关窗/恢复后 S5 行"执行" | BEGIN+S5+SUMMARY+END（4 行；phase=survived，**验收锚**） |

xdm-probe-verify 取**主会话**判 S1~S4（S1~S4 锚），取**末次 runId**（survived 段）判 S5。
survived emit 后 armed 快照复位——再点"执行"会开启新一轮 armed。

## 5. 人工走查清单 8 项对照表（设计书 §5 [P]；项①②③与 S5 两阶段同窗口执行）

| # | 走查项 | 操作 | 预期 | 差异锚 |
|---|---|---|---|---|
| 1 | 活跃下载时点 X | S5-armed 后立即点窗口 X | 窗口**最小化**而非退出（2in1 生效；Dock 可还原） | D3 拍板③ |
| 2 | 实况窗进度刷新 | 打开通知面板观察 | 常驻实况窗可见、文件名/百分比随下载刷新（500ms 门直发） | D2/D11 |
| 3 | 关窗 30s 后下载推进 | 关窗→等 30s→恢复窗口→查列表/探针 S5 | 下载进度已推进（DB 进度/列表读数；S5-survived advanced=true） | 保活链主锚 |
| 4 | 完成通知替换实况窗 | 等下载全部完成 | 进度实况窗消失、完成通知出现（"Download finished"+文件名） | D5 新通道 |
| 5 | 空闲时点 X | 无活跃下载时点窗口 X | 应用正常退出（无拦截） | D10（WPF 空闲也常驻托盘——有意差异） |
| 6 | 汉堡菜单 Exit | 汉堡菜单→Exit | 应用退出；有活跃下载时下载一并终止（WPF Environment.Exit(0) 同貌） | D4 拍板④ |
| 7 | 锁屏后下载继续 | （真机附加）下载中锁屏→等 1min→解锁 | 下载推进、任务未被系统取消（lastCancelReason=none） | 长时任务保活 |
| 8 | ShowNotification 门控 | 设置页关掉 ShowNotification→保存→再跑下载至完成 | 完成**通知消失**（门控生效），进度**实况窗仍在**（不受门控） | D6 拍板⑦ |

> 项 8 复位：走查完把 ShowNotification 打回 true（设置页 Save），避免污染后续会话判定。

## 6. 每步骤预期日志标记表（判定细则见 EXPECT 表）

hilog 过滤 `XDM_PROBE` 后一次完整流程三段会话（§4 会话形态表）。行格式严格为
`[XDM_PROBE][P5-U1][<步骤>] key=value ...`。观测行不含 PASS/FAIL 判定词。

| 步骤 | 预期标记行（示例值） | 判定要点 |
|---|---|---|
| BEGIN | `runId=<HHmmss> filesDir=<非空沙箱files路径>` | 与 END 按 runId 配对；三段会话独立 runId |
| S1 | `notifyEnabled=true notifyBaseline=0 taskBaseline=0 taskModes=none cancelListener=on` | 授权态/通知基线/任务基线锚；notifyEnabled=false=授权被拒（1600004 路径，§7 分支） |
| S2 | `submitted=3 applied=true notificationId=<系统值> continuousTaskId=<值\|none> taskCount=1 mode0=dataTransfer abilityName=EntryAbility` | **申请锚**：轮询 ≤10s 至 notifier.taskNotificationId()>=0（真实注册完成锚，R2-F1——isTaskApplied 是 IPC 往返前的乐观簿记值，不作锚）；notificationId=系统返回（探针不选 id）；taskCount=1（全应用单长时任务实例）；mode0=dataTransfer |
| S3 | `progressEvents=<n> publishOk=<n> publishFail=0 publishMsMax=<ms> notifyCount=1` | **实况窗锚**：progressEvents/publishOk 为 500ms 门直发口径（publishOk=全会话累计、progressEvents=S3 窗口 delta）；notifyCount=1（实况窗在） |
| S4 | `finishedCount=3 released=true taskCountAfter=0 finishId=1001 notifyCountWithFinish=1 notifyCountAfterCancel=0 lastCancelReason=none` | **释放锚**：activeCount 归零且系统侧 getAllContinuousTasks 轮询至 0（真实释放完成锚，R2-F1——isTaskApplied 乐观复位点早于 stop IPC 往返完成，不作锚）；实况窗移除、完成通知（id=1001/1002）在；探针 cancel 后归零；lastCancelReason=none=系统未取消 |
| S5 armed | `phase=armed applied=true notificationId=<值> progressAtArmed=0 recordId=probe-p5u1-<runId>-s5` | armed 快照写入锚；progressAtArmed=起跑初期读数（0 或首个 500ms 门值） |
| S5 占位（主会话内） | `phase=placeholder armedState=<none\|armed> recordId=<id\|none>` | 无副作用占位行（主会话 S1 置位标记识别） |
| S5 survived | `phase=survived taskAlive=1 progressAtArmed=0 progressNow=<n> advanced=true downloadFinished=false recordId=probe-p5u1-<runId>-s5 notifyCount=1 lastCancelReason=none` | **后台存活验收锚**：任务在（taskAlive≥1）、进度推进（progressNow>progressAtArmed）、未收系统取消（lastCancelReason=none） |
| SUMMARY | `[SUMMARY] S1=<...>|S2=<...>|S3=<...>|S4=<...>|S5=<...>` | 恰 5 段；环形缓冲兜底锚 |
| END | `ok=true steps=<主会话5\|单步会话1> elapsedMs=<N>>=0` | ok=true=无脚手架级异常；steps 与步骤行数互证 |

预期标记行全文示例（占位示意值，非判定锚——判定一律以 EXPECT 表范围/存在性表述为准）：

```
[XDM_PROBE][P5-U1][BEGIN] runId=150102 filesDir=/data/app/el2/100/base/com.neuohos.xdm/haps/entry/files
[XDM_PROBE][P5-U1][S1] notifyEnabled=true notifyBaseline=0 taskBaseline=0 taskModes=none cancelListener=on
[XDM_PROBE][P5-U1][S2] submitted=3 applied=true notificationId=23 continuousTaskId=none taskCount=1 mode0=dataTransfer abilityName=EntryAbility
[XDM_PROBE][P5-U1][S3] progressEvents=31 publishOk=31 publishFail=0 publishMsMax=4 notifyCount=1
[XDM_PROBE][P5-U1][S4] finishedCount=3 released=true taskCountAfter=0 finishId=1001 notifyCountWithFinish=1 notifyCountAfterCancel=0 lastCancelReason=none
[XDM_PROBE][P5-U1][S5] phase=placeholder armedState=none recordId=none
[XDM_PROBE][P5-U1][SUMMARY] S1=notifyEnabled=true|S2=applied=true|S3=notifyCount=1|S4=released=true|S5=phase=placeholder
[XDM_PROBE][P5-U1][END] ok=true steps=5 elapsedMs=34210
（S5 单步会话 #1——armed）
[XDM_PROBE][P5-U1][BEGIN] runId=150840 filesDir=...
[XDM_PROBE][P5-U1][S5] phase=armed applied=true notificationId=25 progressAtArmed=0 recordId=probe-p5u1-150840-s5
[XDM_PROBE][P5-U1][SUMMARY] S5=phase=armed
[XDM_PROBE][P5-U1][END] ok=true steps=1 elapsedMs=1210
（人工走查：点 X 关窗→等 15-20s→Dock 恢复→回探针页）
（S5 单步会话 #2——survived，验收锚）
[XDM_PROBE][P5-U1][BEGIN] runId=151105 filesDir=...
[XDM_PROBE][P5-U1][S5] phase=survived taskAlive=1 progressAtArmed=0 progressNow=24 advanced=true downloadFinished=false recordId=probe-p5u1-150840-s5 notifyCount=1 lastCancelReason=none
[XDM_PROBE][P5-U1][SUMMARY] S5=phase=survived
[XDM_PROBE][P5-U1][END] ok=true steps=1 elapsedMs=98
```

失败形态：步骤异常 catch emit `errCode/errMessage`（S1 权限缺配 201 / S2 申请验证失败
9800005、通知校验失败 9800006 等）。探针值全 ASCII 消毒（CJK 经 `?` 占位，非故障）。

## 7. 环境差异分支（重跑指引）

| 现象 | 判定 | 处置 |
|---|---|---|
| S1 notifyEnabled=false | ENV+重跑 | 通知授权被拒（1600004 不再弹）——卸载重装复位授权后重跑；S3 publishFail 会同涨（D7 链） |
| S2 applied=false | FAIL | 分流 business-code（module.json5 backgroundModes/KEEP_BACKGROUND_RUNNING 权限/申请链——对照设计书 §3.2） |
| S2 errCode=9800005/9800006 | FAIL | 分流 business-code（长时任务验证失败/通知校验失败——五要素 publish 链与 id 簿记） |
| S3 notifyCount=0（S1 notifyEnabled=true 时） | **observe-both** | 通知开关关闭时 publish 无报错但不显示——回读 S1 notifyEnabled 判环境；真机通知中心开关一并检查 |
| S3 publishOk=0 且 progressEvents>0 | FAIL | 分流 business-code（实况窗五要素 publish 链/id 簿记——注意 applied 前提） |
| S4 released=false | FAIL | 分流 business-code（释放链/竞态回补——stopBackgroundRunning 调用面） |
| S4 notifyCountWithFinish=0 | **observe-both** | ShowNotification=false（D6 门控只关完成通知）或通知开关关闭——回读设置页与 S1 |
| S5 advanced=false | FAIL | 分流 business-code（保活链——任务申请态/事件袋 DB 回声/关窗路径） |
| S5 taskAlive=0 且 downloadFinished=true | 合法观测 | 下载在后台已跑完——**关窗后下载继续的直接证据，不判 FAIL**（ms=2000 时长 16-60s，短于走查窗口即此形态） |
| S5 lastCancelReason=<数字> | 按数字分流 | 系统取消了任务（reason 只记数字不做枚举名映射——12=26+ detailedReason 数据传输未更新，API 24 上仅观测）；非 12 值对照后台任务文档登记 |
| X 关窗直接退出（S5 advanced=false 同时） | ENV（非 2in1） | onPrepareToTerminate 仅 2in1 生效——改用 2in1 形态复验项①；保活链（S5 taskAlive/advanced）本环境仍可验（手动最小化=后台继续） |
| 模拟器 vs 真机 | — | 真机优先（后台保活/通知/锁屏更真实）；结论按实际运行环境标注回写计划 |

## 8. 回贴

把 probe-P5-U1.log 全文（三段会话 [XDM_PROBE] 行一律不要手工删改）+ §5 走查清单 8 项结果发给 AI，
由 xdm-probe-verify 核对（S1~S4 取主会话、S5 取末次 runId）；结论（含验证环境：真机/模拟器、
2in1 形态与否）与既有单元同口径写回 MIGRATION_PLAN。本单元特有回写项：
①S2 长时任务申请运行时锚（系统返回 notificationId/taskCount=1/mode0=dataTransfer）；
②S3 实况窗 500ms 门直发成功率与耗时（publishMsMax——D11 二次节流偏差的实证输入）；
③S4 释放/通知数迁移/lastCancelReason=none（系统未取消）；
④S5 后台存活（taskAlive/advanced/downloadFinished——关窗后下载继续直接证据）+ D13 走查判定
（onPrepareToTerminate 是否按预期拦截）；
⑤走查 8 项勾选结果（项⑦⑧环境差异按 §7 标注）。
