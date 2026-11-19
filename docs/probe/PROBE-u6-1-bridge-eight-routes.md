# 探针运行手册：P6-U1 扩展桥八路由完整版

> 工程根：D:\git\HarmonyPC\XdmHarmony ｜ bundle：com.neuohos.xdm ｜ 探针单元 ID：`P6-U1`
> hdc 未入 PATH，用全路径：`HDC="D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"`（本机已核实存在）
> 设计书：docs/design/u6-1-bridge-eight-routes-DESIGN.md（§6 步骤表）｜ 预期表：EXPECT-u6-1-bridge-eight-routes.json（与本文 §4 表一一对应）
> 设备侧探针：entry/src/main/ets/probe/units/ProbeBridgeRoutes.ets（P6-U1 卡片，S1~S9 全自动）
> 主机侧脚本：docs/probe/P6-U1-node-client.js（十步打流+断言，AI 自动轨）

## 0. 一次性准备

```bash
# 真机（推荐验证环境）：真机拒绝未签名 HAP，首次必须做——
devecocli auth login                    # 华为账号登录
#   USB 连接真机并开启开发者模式/USB 调试后：
devecocli signature generate --product default   # 注册设备+生成签名材料，自动写入 build-profile.json5
# 模拟器（兜底/形态验证）：推包不需要签名
devecocli emulator list                 # 确认实例（本机已有 "Pura 90"）
```

## 1. 启动环境

```bash
# 真机：USB 连接后直接确认；模拟器：
devecocli emulator start "Pura 90"
devecocli device list                   # 多设备时后续命令需 --device <serial>
```

## 2. 运行探针

```bash
cd /d D:\git\HarmonyPC\XdmHarmony
devecocli run --module entry            # 构建+安装+拉起应用主页（AI 已构建过时加 --skip-build）
# 打开探针页：EntryAbility 解析 want 参数 page=probe（冷/暖启动均支持）——
%HDC% shell aa start -b com.neuohos.xdm -a EntryAbility --ps page probe
```

注：本工程探针页经 **EntryAbility want 参数路由**拉起（PROBE_SPEC §1，U0.1 落地机制），
module.json5 仅注册 `EntryAbility`/`EntryBackupAbility`，不存在独立 ProbeAbility——
`devecocli run --module entry --ability ProbeAbility` 形态不适用本工程，以上方 `aa start` 为准。
探针首页点 **P6-U1 卡片（扩展桥八路由探针）** → autoStart 自动跑 S1~S9（全程无需人工交互）。

## 3. 抓取标记（探针跑完后）

```bash
%HDC% shell "hilog -x | grep XDM_PROBE" > probe-P6-U1.log
# 兜底：环形缓冲被冲掉时取探针写盘结果（路径见 BEGIN 行 filesDir=）
%HDC% shell "cat <filesDir>/probe-latest.txt"
# 探针闪退时：devecocli log --crash
```

行格式契约（PROBE_SPEC §2）：`[XDM_PROBE][P6-U1][<步骤号>] <key>=<value> ...`；
verify 解析正则 `^\[XDM_PROBE\]\[([A-Z0-9-]+)\]\[([A-Za-z0-9-]+)\]\s(.+)$`；
值白名单 `[A-Za-z0-9_.:/|=?-]` 与空格，含逗号/括号值已由探针预转换（`,`→`/`、`[X]` 剥括号）。

## 4. 每步骤预期日志标记表（P6-U1 一次运行的示例行）

```
[XDM_PROBE][P6-U1][BEGIN] runId=101530 filesDir=/data/app/el2/100/base/com.neuohos.xdm/haps/entry/files
[XDM_PROBE][P6-U1][S1] started=true boundPort=8597 clearStatus=200 baseVideoCount=0 requestsBefore=0
[XDM_PROBE][P6-U1][S2] mediaStatus=200 mediaListCount=1 mediaTextSuffix=.mp4 mediaInfoPrefix=MP4 mediaAddedEvents=1 vid=3f2a91c7
[XDM_PROBE][P6-U1][S3] tabUpdateStatus=200 tabTextPrefix=New Title tabExtKept=true mediaUpdatedEvents=1
[XDM_PROBE][P6-U1][S4] vidMissStatus=200 vidMissListCount=1 vidHitStatus=200 videoDialogEvents=1
[XDM_PROBE][P6-U1][S5] downloadStatus=200 downloadDialogEvents=1 uaPreserved=true cookieStripped=true acceptStripped=true acceptEncodingPreserved=true
[XDM_PROBE][P6-U1][S6] argsTabStatus=200 argsTabPrefix=Args Title argsMediaStatus=200 argsMediaCount=2
[XDM_PROBE][P6-U1][S7] linkStatus=200 batchEvents=1 pendingLinks=1
[XDM_PROBE][P6-U1][S8] unknownClosed=true badJsonClosed=true vidMissingClosed=true
[XDM_PROBE][P6-U1][S9] syncStatus=200 fieldCount=8 fieldOrder=enabled/fileExts/blockedHosts/requestFileExts/mediaTypes/tabsWatcher/videoList/matchingHosts finalVideoCount=2 connections=13 requests=13
[XDM_PROBE][P6-U1][SUMMARY] S1=clearStatus=200|S2=mediaListCount=1|S3=tabExtKept=true|S4=videoDialogEvents=1|S5=cookieStripped=true|S6=argsMediaCount=2|S7=pendingLinks=1|S8=unknownClosed=true|S9=finalVideoCount=2
[XDM_PROBE][P6-U1][END] ok=true steps=9 elapsedMs=3420
```

逐步骤键与期望值（完整 note 见 EXPECT 表；值只写观测事实，判定在 xdm-probe-verify）：

| 步骤 | 观测键 | 期望要点 |
|---|---|---|
| BEGIN | runId、filesDir | runId 非空（与 END 配对）；filesDir 非空沙箱路径 |
| S1 | started boundPort clearStatus baseVideoCount requestsBefore | started=true；boundPort=8597；clearStatus=200；baseVideoCount=0（/clear 后）；requestsBefore>=0 |
| S2 | mediaStatus mediaListCount mediaTextSuffix mediaInfoPrefix mediaAddedEvents vid | mediaStatus=200；mediaListCount=1；mediaTextSuffix=.mp4；mediaInfoPrefix=MP4；mediaAddedEvents=1；vid=UUID 前 8 字符 |
| S3 | tabUpdateStatus tabTextPrefix tabExtKept mediaUpdatedEvents | tabUpdateStatus=200；tabTextPrefix=New Title；tabExtKept=true；mediaUpdatedEvents=1 |
| S4 | vidMissStatus vidMissListCount vidHitStatus videoDialogEvents | 两次均 200；vidMissListCount=1（未命中静默）；videoDialogEvents=1（auto=false 默认→对话框事件） |
| S5 | downloadStatus downloadDialogEvents uaPreserved cookieStripped acceptStripped acceptEncodingPreserved | downloadStatus=200；downloadDialogEvents=1；uaPreserved/cookieStripped/acceptStripped/acceptEncodingPreserved=true（头剥离四谓词；请求体 Content-Length 为 number 形=真实扩展契约） |
| S6 | argsTabStatus argsTabPrefix argsMediaStatus argsMediaCount | 两组均 200；argsTabPrefix=Args Title；argsMediaCount=2（S2+S6 累计） |
| S7 | linkStatus batchEvents pendingLinks | linkStatus=200；batchEvents=1；pendingLinks=1（空 url 项跳过；载荷每元素必带 requestHeaders——实现门对 null throw 断连，COLD-F1） |
| S8 | unknownClosed badJsonClosed vidMissingClosed | 三谓词=true：连接关闭且无完整应答头块（**零应答字节=正确**，U0.3 404 中间态已废止） |
| S9 | syncStatus fieldCount fieldOrder finalVideoCount connections requests | syncStatus=200；fieldCount=8；fieldOrder 恰八字段契约序；finalVideoCount=2；connections/requests 与 S1 差值互证（S1~S9 共 13 请求） |
| SUMMARY | S1..S9 段聚合 | 恰 9 段，单行 <1500B |
| END | ok steps elapsedMs | ok=true；steps=9；elapsedMs>=0 |

失败形态：任一步骤 catch → 该步输出 `errCode=<code> errMessage=<msg>` 键组仍恰一行（不中断会话）。

## 5. 需人工配合的步骤（主机侧双轨，AI 可代跑）

本单元 S1~S9 设备侧全自动；**主机侧打流**为独立验证轨（验收"Node 模拟流量全绿"），需人工/AI 配合：

```bash
# AI 自动轨（首选）：fport 转发后跑 Node 脚本，十步打流+断言，退出码 0=全绿
%HDC% fport rm tcp:18597
%HDC% fport tcp:18597 tcp:8597
%HDC% fport ls                          # 应列出 tcp:18597 tcp:8597
node docs/probe/P6-U1-node-client.js    # SUMMARY pass=10 fail=0；逐项 PASS/FAIL 观测
%HDC% fport rm tcp:18597                # 收尾必做
# 人工兜底轨：curl 命令集逐条对照预期现象（见本目录手册历史版本 §5 或 Node 脚本步骤注释；
#   重点：未知路径 curl 报 Empty reply from server / 连接被关 = 正确）
```

人工设备侧交互：无（S1~S9 无人工步骤；真机可再目检应用主页面正常、`devecocli log --crash` 空）。

## 6. 回贴

把以下材料发给 AI，由 xdm-probe-verify 对照 `EXPECT-u6-1-bridge-eight-routes.json` 逐步骤核对：
1. `probe-P6-U1.log` 全文（[XDM_PROBE] 行一律不要手工删改；多轮运行取最后 runId）。
2. Node 脚本 stdout 全文（十步 PASS/FAIL + SUMMARY 行）或人工 curl 逐条输出。
3. 双轨判定合并口径见 EXPECT 表 END 步 note：两轨任一全绿即 [P] 运行时验收通过。
