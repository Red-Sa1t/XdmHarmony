# 探针运行手册：P4-U2 对话框包走查探针（U4.2 进度窗/批量/选择/删除/凭据/刷新链接/完成窗/限速）

> 工程根：D:\git\HarmonyPC\XdmHarmony ｜ bundle：com.neuohos.xdm ｜ 预期表：[EXPECT-u4-2-dialog-package.json](./EXPECT-u4-2-dialog-package.json)
> hdc 未入 PATH，用全路径：HDC="D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
> 探针页形态：**autoStart=false**——S1/S2/S3/S4 autoRun + **S5 人工走查清单（26 项 Toggle 勾选，单步执行）**。
> 单元验收核心（UNIT_CATALOG U4.2"各对话框开合/回调对照源码；工具栏触发链贯通；事件面零破坏"）：
> §5 人工走查清单 26 项逐对话框开合/回调 + S1 批量算法锚 + S2 限速规范化/Config 回读锚 +
> S3 进度窗生命周期锚（慢源实跑）+ S4 完成窗触发门锚。

## 0. 运行次序红线（本单元特有，必读）

**先主页面人工走查 → 再探针**（P4-U1 同款次序，S3 会 `manager.init` 后到者接管事件袋）：

1. **先主页面走查**：启动应用主页（探针尚未运行时 manager 事件袋归 Index），按 §5 清单 1-25 项
   逐项核对（清单第 26 项后半=Credential 步骤在探针页做，见 3.1）；建议同步在纸上记下各项结果；
2. **再进探针页跑"运行全部"**（S1→S4 自动；S3 会接管事件袋并实跑一个慢源下载——此刻起 Index
   列表不再收到引擎事件，属预期）；
3. **回探针页勾选 26 项清单 → 单步执行 S5**（发射 checked/total/unchecked）；
4. **探针会话内不切页**（S3 轮询期切回 Index 会把事件袋换走，S3 序流断流）。

## 1. 一次性准备

```bash
# 真机（推荐验证环境）：真机拒绝未签名 HAP，首次必须做——
devecocli auth login                              # 华为账号登录
#   USB 连接真机并开启开发者模式/USB 调试后：
devecocli signature generate --product default    # 注册设备+生成签名材料，自动写入 build-profile.json5
# 模拟器（兜底/形态验证；2in1 PC 形态鼠标右键上下文菜单走查更真实）：推包不需要签名
devecocli emulator list                           # 确认实例（本机已有 "Pura 90"）
```

## 2. 测试源（主机侧，仅 S3 需要）——P1-U2-download-server.js 复用（零改动）

```bash
cd /d D:\git\HarmonyPC\XdmHarmony\docs\probe
node P1-U2-download-server.js            # 默认 8080
# 预期输出：
# [P1-U2] download server listening on 0.0.0.0:8080  (big.bin=4194304B, routes: /big.bin /slow.bin?ms=40 /echo /redirect /final)
```

- **复用指引**：P4-U2 不新增服务器文件。S3 消费 `/slow.bin?ms=300`（**ms=300 由探针 URL 参数
  携带**，`P1-U2-download-server.js:112-131` ms 参数任意整数合法，零改动复用）。S1/S2/S4/S5 无需
  测试源。走查清单 8/23 项（主页面 Download Now/小文件完成）也用此源（`/big.bin` 完成约十秒级）。
- **局域网 IP 纪律**：探针页 TextInput 填**主机局域网 IP**（如 `http://192.168.1.20:8080`）；
  模拟器内 `127.0.0.1` 是自身回环；主机防火墙需放行该端口。

## 3. 运行（设备侧）

```bash
cd /d D:\git\HarmonyPC\XdmHarmony
devecocli emulator start "Pura 90"                # 模拟器兜底（未启动时执行；真机 USB 直连跳过本行）
devecocli device list                             # 设备就绪确认（多设备时后续命令需 --device <serial>）
devecocli run --module entry                      # 构建+安装+拉起应用主页（AI 已构建过时：加 --skip-build）
```

### 3.1 主页面人工走查（先做，清单 1-25 项）

按 §5 清单逐项操作核对。数据准备提示：

- 批量窗走查（项 1-5）：地址模板填 `http://<主机IP>:8080/big*.bin` 之类的含 `*` 地址即可触发
  预览刷新（预览不发起网络请求，纯本地生成）；
- Download Now 起跑（项 8）：批量生成 1-2 条真实 URL（如字母 A-B 两链 `.../bigA.bin`——404 也会
  建行进入失败重试，仅验证"行建出+起跑"面；或用数字区间命中真实路由）；
- 小文件完成（项 23）：直接经 New 对话框下载 `/big.bin`（4MiB，完成窗触发）；
- 进度窗走查（项 15-22）：下载进行中右键行 → Show progress；Pause/Resume/Hide/Stop 按项操作；
- Delete 两分支（项 25）：进行中视图与完成视图各选行点 Delete 分别核对；
- **Credential 步骤（项 26 后半）在探针页做**：进探针页 P4-U2 → "打开凭据窗"按钮——先留空点
  OK（应弹 "User name required" 且窗不关）→ 填名+密码点 OK（按钮旁回显 `userName=<名>`）→
  重新打开后点 Cancel（回显"未确认"）；同排"打开删除确认窗"按钮核对 Delete files from disk
  勾选回显（deleteFiles=0/1）。

### 3.2 探针会话

```bash
# 打开探针页（EntryAbility 解析 want 参数 page=probe，支持冷/暖启动）：
hdc shell aa start -b com.neuohos.xdm -a EntryAbility --ps page probe
# 探针首页 → P4-U2 卡片 → 核对 TextInput 测试源（仅 S3 需要）→ 点"运行全部"（S1→S5 自动）
# 回探针页勾选 26 项清单 → S5 行点"执行"（单步迷你会话）
```

> 模板差异说明：通用模板写 `--ability ProbeAbility`——本工程无独立探针 Ability（module.json5 仅
> mainElement=EntryAbility），探针页由 EntryAbility 解析 want 参数 `page=probe` 拉起（U0.1 路由
> 契约；P1-U2/P2/P3/P4-U1 手册同款注记）。

## 4. 抓取标记（S5 单步 END 行出现后）

```bash
"D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" shell "hilog -x | grep XDM_PROBE" > probe-P4-U2.log
# 兜底：缓冲被冲掉时取探针写盘结果（路径见 BEGIN 行 filesDir=）
hdc shell "cat <filesDir>/probe-latest.txt"
# 探针闪退时：devecocli log --crash
# 业务侧诊断（对话框/引擎异常走这里，非探针标记）：
hdc shell "hilog -x | grep -E 'ProgressWindowHost|DownloadManager|Index'"
```

**会话形态**（一次完整流程 = 两段会话，各自 BEGIN/END 配对独立 runId）：

| 会话 | 触发 | 行序列 |
|---|---|---|
| 主会话 | 探针页"运行全部" | BEGIN+S1+S2+S3+S4+S5+SUMMARY+END（8 行；S5 为**占位发射**——勾选面此刻多为未勾状态） |
| S5 单步会话 | S5 行"执行"按钮 | BEGIN+S5+SUMMARY+END（4 行；**验收锚**） |

xdm-probe-verify 取**末次 runId**（S5 单步会话）判 S5，取主会话判 S1~S4。

## 5. 人工走查清单 26 项对照表（渲染进 S5 勾选面；对照设计书 §6bis/§4 差异清单）

| # | 走查项 | 操作 | 预期 | 差异锚 |
|---|---|---|---|---|
| 1 | 批量窗入口 | New 下拉第 3 项 Batch download | 批量窗打开且非模态（主窗可继续操作） | §3.8 非模态六窗（Show() 分型 1:1） |
| 2 | 批量预览刷新 | 地址含 `*` 输入/改模式/选字母/勾补零/数字框失焦 | 三预览+数量即时刷新；抹掉 `*` 预览清空 | OnBatchPatternChange 五触发点 §3.1 |
| 3 | Letters/Numbers 切换 | 切两模式 | Letters：From/To 下拉各 26 项 A..Z；Numbers：From/To 变数字输入 | UIController ctor:20-27 同源 |
| 4 | 补零预览 | 勾补零+位数 3，数字区间 1-3 | 预览出现 001/002/003 前导零 | padDigits C# D 格式（负号外置） |
| 5 | 批量 OK 校验 | 无生成（无 `*` 或空区间）点 OK | "Select items to download" 提示且窗不关；有生成 → 批量窗关、选择窗开 | OnOKClicked :47-66 门 |
| 6 | 选择窗默认选中 | 打开选择窗 | 条目默认全选中；全选框不勾但条目已全选（源码同貌）；取消若干条后 OK 只下被选条目数 | xaml.cs:189 selected=true 同貌 |
| 7 | 选择窗空选校验 | 全不选点 OK | "Select items to download" 提示不关窗 | DownloadSelectedItems :121-125 |
| 8 | Download Now | 选择窗确认 | 选择窗关、进行中列表新增行并起跑 | StartDownload :126-186 同序 |
| 9 | Download Later | Download Later → Do not use queue | 新行 Stopped 不起跑，手动继续可跑（源码 startType 缺省 Waiting 仅对 Now 生效，勘误） | SaveForLater :198-200 同位（差异 #9 队列清单恒空） |
| 10 | More 高级窗 | 点 More | 有 No Proxy/Manual Proxy 与认证两输入，**无 System Proxy 项** | 差异 #10（§3-2 降级隐藏+限速死值裁剪） |
| 11 | More 回填链 | 填 user/pass+Manual host/port 确认 → Download Now | 新行建出（行为不因裁剪中断） | AddDownload :99-112 消费面 |
| 12 | 行右键菜单 | 进行中行右键 | 菜单含 Refresh link/Show progress 两项 | 差异 #17（源 10 项，本单元两项） |
| 13 | Refresh link 开窗 | 右键 Refresh link（Http 记录） | 等待窗打开；窗显 "Waiting for download link..." | LinkRefreshDialog 分型 §3.7 |
| 14 | 刷新窗 Stop | 点 Stop | 窗关无残留 | BtnStop+WatchingStopped §3.7 |
| 15 | Show progress 幂等 | 右键 Show progress 后重复点击 | 进度窗开；重复点击不弹第二窗 | GetProgressWindow 复用同构 §3.3 |
| 16 | 进度窗内容一致 | 对照主列表行 | 文件名/URL/进度/速度/ETA 与主列表行一致 | DownloadProgressChanged :359-371 五字段 |
| 17 | 限速文本初始 | 打开进度窗 | 限速文本 "No speed limit"；点击 → 限速窗打开（非模态） | SetSpeedLimitText :177-186；差异 #2 autoCancel:false |
| 18 | 限速写回刷新 | 限速窗勾选+输入 100 → OK | 进度窗限速文本变 "Speed limit - 100K/S"（ConfigChanged 刷新） | BroadcastConfigChange 同位 §3.2 |
| 19 | 限速输入过滤 | 输入非整数/清空失焦 | 非整数被滤除；清空失焦 → 勾选自动取消 | 差异 #15（onChange 重写+onBlur） |
| 20 | 进度窗 Pause/Resume | 点 Pause → 再点 Resume | Pause：状态 "Download stopped"+按钮变 Resume，下载停；Resume：续跑按钮回 Pause | BtnPause_Click :206-235 |
| 21 | 进度窗 Hide | 点 Hide | 窗关下载继续（主列表进度仍在走） | BtnHide_Click :233-238 |
| 22 | 进度窗 Stop | 点 Stop | 窗关下载停（行变 Stopped） | BtnStop_Click :227-230 |
| 23 | 完成窗触发 | 小文件下载完成 | 进度窗自动关 + 完成窗弹出（Download Complete+文件名/目录） | DownloadFinished :393-419 门 §3.6 |
| 24 | 完成窗交互 | Open/Open folder/Don't show | Open/Open folder 点击不崩溃（占位）；Don't show → 窗关，再次完成不再弹 | 差异 #6 占位；差异 #14 持久化 |
| 25 | Delete 进行中分支 | 进行中视图选行 Delete | 行先被停 → 确认框（无删文件选项）→ 确认后行消失且重启不回；Cancel 则行保留（但已停） | UIActions.cs:21-38 先停后确认 §3.4 |
| 26 | Delete 完成分支+Credential | 完成视图选行 Delete；探针页"打开凭据窗" | 确认框带 "Delete files from disk" 选项 → 确认后行消失；凭据：空用户名 OK → "User name required" 不关窗，填名+密码 OK 回显 userName，Cancel 无回显 | UIActions.cs:40-54；差异 #11/#6 |

> 走查清单 26 项同时是 S5 勾选面逐项全文（探针页 UI 渲染同文）。

## 6. 每步骤预期日志标记表（判定细则见 EXPECT 表）

hilog 过滤 `XDM_PROBE` 后一次完整流程两段会话（§4 会话形态表）。行格式严格为
`[XDM_PROBE][P4-U2][<步骤>] key=value ...`（FORMAT 正则
`^\[XDM_PROBE\]\[([A-Z0-9-]+)\]\[([A-Za-z0-9-]+)\]\s(.+)$`）。观测行不含 PASS/FAIL 判定词。

| 步骤 | 预期标记行（示例） | 判定要点 |
|---|---|---|
| BEGIN | `runId=<HHmmss> filesDir=<非空沙箱files路径>` | 与 END 按 runId 配对；两段会话独立 runId |
| S1 | `letterAC=3 noAsterisk=0 letterReversed=0 letterMissing=0 digit123=file1.bin/file2.bin/file3.bin digit123Count=3 digitPad=file001.bin/file002.bin/file003.bin digitNeg=file-001.bin/file000.bin/file001.bin twoStars=2 invalid=null previewFirst=fileA.bin previewSecond=fileB.bin previewLast=fileD.bin previewSize=4` | **批量算法锚**（与 [A] 13 条单测互证）：字母 A-C 计数 3；三空场景（无星号/反序/缺选）均 0 且非 null；数字 1-3 逐串；补零 D3；负数补零 -001/000/001（负号外置）；两星号全量替换数 2；非法 URL 恒 null；四链预览 first/second/last/size |
| S2 | `viewOn=1/100 viewOffCfg=0/50 viewZero=0/0 viewNeg=0/-5 setTrue100=1/100 setTrue0=0/0 setFalse50=0/50 listenerFired=3 restored=<快照值>` | **限速规范化+Config 回读锚**：装载四场景（SpeedLimiterUIController.cs:12-13 同式——禁用回填原值/零门/负值门）；三次 setSpeedLimit 读回（组合 setter 规范化：true+0→0/0、false+50→0/50）；listenerFired=3（ConfigChanged 广播恰三次）；restored=快照恢复 |
| S3 | `submitted=1 opened=1 fileName=p4u2-r1.bin statusPrefix=Downloading pausedResumable=1 pausedStatus=Download stopped resumedResumable=1 closedCount=0 liveAfter=0 startedEcho=2 pausedEcho=2` | **进度窗生命周期锚（慢源实跑）**：探针自持 host 经 onStarted 转发开窗（opened=1）；模型 fileName/statusText 前缀；stopOne→onPaused 回声写停态（pausedResumable=1+pausedStatus 精确值）；resumeOne→onStarted 回声复位（resumedResumable=1 表示已回 false）；stopOne+closeFor→closedCount=0；liveAfter=0。startedEcho/pausedEcho 为引擎回声计数佐证（start+resume 两次 onStarted / stop+stop 两次 onPaused，浮窗观测不受影响） |
| S4 | `gateBefore=1 completedShown1=1 windowCountAfter=0 gateAfterDisable=0 completedShown2=0 restored=1` | **完成窗触发门锚**：fake-id 不存在进度窗（windowCountAfter=0 不误关）；开闸→completedShown1=1；关闸→再调 completedShown2=0；恢复 true 读回 |
| S5 | 主会话：`checked=<0..26> total=26 unchecked=<索引'/'串或 none>`<br>单步会话：`checked=26 total=26 unchecked=none`（全绿目标） | 勾选面发射；**验收锚=末次 runId（S5 单步会话）**；unchecked 非空→按项号分流走查返修 |
| SUMMARY | `[SUMMARY] S1=<...>|S2=<...>|S3=<...>|S4=<...>|S5=<...>` | 恰 5 段（各段含关键键：S1=letterAC；S2=setTrue100；S3=pausedStatus；S4=completedShown1；S5=checked）；环形缓冲兜底锚 |
| END | `ok=true steps=<主会话5|单步会话1> elapsedMs=<N>>=0` | ok=true 表示本次会话无脚手架级异常；steps 与步骤行数互证 |

预期标记行全文示例（占位示意值，非判定锚——判定一律以 EXPECT 表范围/存在性表述为准）：

```
[XDM_PROBE][P4-U2][BEGIN] runId=101532 filesDir=/data/app/el2/100/base/com.neuohos.xdm/haps/entry/files
[XDM_PROBE][P4-U2][S1] letterAC=3 noAsterisk=0 letterReversed=0 letterMissing=0 digit123=file1.bin/file2.bin/file3.bin digit123Count=3 digitPad=file001.bin/file002.bin/file003.bin digitNeg=file-001.bin/file000.bin/file001.bin twoStars=2 invalid=null previewFirst=fileA.bin previewSecond=fileB.bin previewLast=fileD.bin previewSize=4
[XDM_PROBE][P4-U2][S2] viewOn=1/100 viewOffCfg=0/50 viewZero=0/0 viewNeg=0/-5 setTrue100=1/100 setTrue0=0/0 setFalse50=0/50 listenerFired=3 restored=0/0
[XDM_PROBE][P4-U2][S3] submitted=1 opened=1 fileName=p4u2-r1.bin statusPrefix=Downloading pausedResumable=1 pausedStatus=Download stopped resumedResumable=1 closedCount=0 liveAfter=0 startedEcho=2 pausedEcho=2
[XDM_PROBE][P4-U2][S4] gateBefore=1 completedShown1=1 windowCountAfter=0 gateAfterDisable=0 completedShown2=0 restored=1
[XDM_PROBE][P4-U2][S5] checked=0 total=26 unchecked=1/2/3/4/5/6/7/8/9/10/11/12/13/14/15/16/17/18/19/20/21/22/23/24/25/26
[XDM_PROBE][P4-U2][SUMMARY] S1=letterAC=3|S2=setTrue100=1/100|S3=pausedStatus=Download stopped|S4=completedShown1=1|S5=checked=0
[XDM_PROBE][P4-U2][END] ok=true steps=5 elapsedMs=41200
（S5 单步会话，第二次运行）
[XDM_PROBE][P4-U2][BEGIN] runId=103014 filesDir=...
[XDM_PROBE][P4-U2][S5] checked=26 total=26 unchecked=none
[XDM_PROBE][P4-U2][SUMMARY] S5=checked=26
[XDM_PROBE][P4-U2][END] ok=true steps=1 elapsedMs=12
```

失败形态：步骤异常 catch emit `errCode/errMessage`；S3 网络类异常（2300028 超时/2300007 拒连）
→ 测试源未启动/地址错（env）。

## 7. 环境差异分支（重跑指引）

| 现象 | 判定 | 处置 |
|---|---|---|
| S1 任一计数/串不符 | FAIL | 分流 business-code（BatchAlgo 回归——与 13 条单测互证定位分支；null/[] 双语义混淆查 generateBatchLinks 门序） |
| S2 装载/读回值不符 | FAIL | 分流 business-code（speedLimitView/Config.setSpeedLimit 规范化回归）；listenerFired≠3 → ConfigChanged 广播链回归 |
| S2 restored≠快照 | FAIL | 分流 business-code（快照恢复链；注意真机上轮 S2 残留已被恢复逻辑覆盖） |
| S3 `errCode/errMessage`（2300028/2300007） | env | 测试源未启动/地址错/防火墙——§2 重启服务器、核对局域网 IP 后重跑 |
| S3 `opened=0` | FAIL | 分流 business-code（onStarted 转发门/Config.showProgressWindow/isInteractive/openFor 链） |
| S3 `pausedStatus≠Download stopped` 或 `pausedResumable=0` | FAIL | 分流 business-code（host.onPaused 状态机写） |
| S3 `resumedResumable=0` | FAIL | 分流 business-code（onStarted 复位 resumable 的转发缺失） |
| S3 `closedCount≠0` 或 `liveAfter≠0` | FAIL | 分流 business-code（closeFor/stopOne 链） |
| S4 `completedShown1=0`（gateBefore=1 时） | FAIL | 分流 business-code（完成窗门/host.onDownloadFinished） |
| S4 `completedShown2=1` | FAIL | 分流 business-code（Config 门未生效——setShowDownloadCompleteWindow） |
| S5 unchecked 非空 | 按项号分流 | 走查项 1~26 逐项返修（项号→§5 对照表→设计书 §6bis/§4 差异锚），返修后重走查+单步 S5 |
| 模拟器 vs 真机 | — | 真机优先（右键菜单/多窗交互更真实）；结论按实际运行环境标注回写计划 |

## 8. 回贴

把 probe-P4-U2.log 全文（两段会话 [XDM_PROBE] 行一律不要手工删改）+ §5 走查清单勾选结果发给 AI，
由 xdm-probe-verify 核对（S5 取末次 runId）；结论（含验证环境：真机/模拟器）与既有单元同口径写回
MIGRATION_PLAN。本单元特有回写项：
①S1 批量算法运行时锚（null/[] 双语义+负号外置+两星号全量替换）；
②S2 限速装载/保存规范化+ConfigChanged 广播（listenerFired=3）；
③S3 进度窗生命周期（开窗→停态→复位→关窗；@Observed+@ObjectLink 刷新机制实跑验证）；
④S4 完成窗触发门（Config 键端到端）；
⑤S5 走查清单 26/26（unchecked 项号清单=返修输入——含 Credential/删除确认探针页回显）。
