# 探针运行手册：OPT-1 前端优化（深色资源化 + Index 拆分 + UX 三项收口——经 P4-U1 探针 23 项清单版验收）

> 工程根：D:\git\HarmonyPC\XdmHarmony ｜ bundle：com.neuohos.xdm ｜ 预期表：[EXPECT-opt-1-frontend-polish.json](./EXPECT-opt-1-frontend-polish.json)
> hdc 未入 PATH，用全路径（本会话已核实存在）：
> `"D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"`

**本单元与探针的关系（必读）**：OPT-1 是 24 单元外交接单元，**无新探针文件**——运行时验收复用
[P4-U1 主窗口走查探针](PROBE-u4-1-main-window-framework.md)，其走查清单已随本单元从 22 项同步为
23 项（`probe/units/ProbeMainWindow.ets:58` 步骤标题、`:62-86` CHECKLIST_TITLES 追加第 23 项"深色
模式全界面可读"；`total` 取 `checkedFlags.length` 自适应，`ProbeMainWindow.ets:412`）。因此：

- **全部日志标记行的单元段恒为 `P4-U1`**（`ProbeMainWindow.ets:531` `unitId: 'P4-U1'`）——日志里不会
  出现 `[XDM_PROBE][OPT-1]` 行，这是预期，不是漏打；
- `xdm-probe-verify` 调用时 **`unit` 参数填 `P4-U1`**（缺省取日志最后 BEGIN 单元亦为 P4-U1），
  `probeDoc` 指向本文档；
- S1/S2/S3 逻辑与 OPT-1 前逐字节一致（设计书 §1-#15 "S1/S2/S3 逻辑与 :524 探针 border hex 零改动"），
  在本文档中作为**拆分/清扫零回归锚**复判；S4 是 OPT-1 的核心新增锚（total=23 + 第 23 项深色观测）。

探针页形态：**autoStart=false**——S1/S2/S3 autoRun + S4 人工走查清单（23 项 Toggle 勾选，单步执行）。
S3 需主机侧测试源（仅此一步依赖网络）；S1/S2/S4 纯内存/纯 UI。

## 0. 运行次序红线（沿用 P4-U1，深色走查插入点见第 3 步）

**先主页面人工走查 → 再探针**（P4-U1 手册 §0 同款，S3 的 `manager.init` 后到者接管事件袋）：

1. **先主页面走查**：启动应用主页（探针尚未运行时 manager 事件袋归 Index），按
   [PROBE-u4-1 §5 清单 23 项](PROBE-u4-1-main-window-framework.md#5-人工走查清单-23-项对照表渲染进-s4-勾选面对照-xdm-走查表与设计书-6bis--opt-1-追加第-23-项)
   逐项核对，建议同步在纸上记下各项结果；
2. **深色专项在第 1 步内完成**：走查项 23 需在系统深色模式 + 系统浅色模式两种状态下完成全部界面
   目检后才能勾选（操作见 §3.2——切系统深浅色要离开应用去系统设置，必须在探针会话开始**之前**做完，
   否则违反红线 4）；
3. **再进探针页跑"运行全部"**（S1~S3 自动；S3 会 `manager.init` **后到者接管事件袋**——此刻起
   Index 列表不再收到引擎事件，属预期）；
4. **探针会话内不切页**（S3 轮询期切回 Index 会把事件袋换走，S3 序流断流；同理不得中途切系统深浅色）；
5. 走查项 14/15（Waiting 行取消排队→重启持久）涉及重启——**重启后再进探针页勾选**（重启会自然恢复
   Index 事件袋，与次序红线不冲突），先勾满 23 项、再单步执行 S4。

## 1. 一次性准备

```bash
# 真机（推荐验证环境）：真机拒绝未签名 HAP，首次必须做——
devecocli auth login                              # 华为账号登录
#   USB 连接真机并开启开发者模式/USB 调试后：
devecocli signature generate --product default    # 注册设备+生成签名材料，自动写入 build-profile.json5
# 模拟器（兜底/形态验证）：推包不需要签名
devecocli emulator list                           # 确认实例（本机已有 "Pura 90"，P4-U1 手册同款口径）
```

跳过条件（本机已沉淀，PROBE-SESSION-ALL.md §0 / U7.1 手册 §0 同口径）：build-profile.json5 已含签名
材料（本会话核实：signingConfigs material 已配 certpath/profile）即可跳过真机准备两行。

## 2. 测试源（主机侧，仅 S3 需要）——P1-U2-download-server.js 复用（零改动）

```bash
cd /d D:\git\HarmonyPC\XdmHarmony\docs\probe
node P1-U2-download-server.js            # 默认 8080
# 预期输出：
# [P1-U2] download server listening on 0.0.0.0:8080  (big.bin=4194304B, routes: /big.bin /slow.bin?ms=40 /echo /redirect /final)
# [P1-U2] probe base url = http://<本机局域网IP>:8080  (设备内禁用 127.0.0.1）
```

- 本探针仅 S3 消费 `/slow.bin?ms=300`（ms=300 由探针 URL 参数携带，`ProbeMainWindow.ets:47`
  SLOW_MS=300；server 端 ms 参数任意整数合法，零改动复用）。S1/S2/S4 无需测试源。
- **局域网 IP 纪律**：探针页 TextInput 填**主机局域网 IP**（如 `http://192.168.1.20:8080`，
  `ProbeMainWindow.ets:44` 缺省占位）；模拟器内 `127.0.0.1` 是自身回环；主机防火墙需放行该端口。
- 慢源同时服务于走查项 14 造排队行（§3.2 UX-b）。

## 3. 运行（设备侧）

```bash
cd /d D:\git\HarmonyPC\XdmHarmony
devecocli emulator start "Pura 90"                # 模拟器兜底（未启动时执行；真机 USB 直连跳过本行）
devecocli device list                             # 设备就绪确认（多设备时后续命令需 --device <serial>）
devecocli run --module entry                      # 构建+安装+拉起应用主页（AI 已构建过时：加 --skip-build）
# 打开探针页（EntryAbility 解析 want 参数 page=probe，支持冷/暖启动）：
hdc shell aa start -b com.neuohos.xdm -a EntryAbility --ps page probe
```

> 模板差异说明：通用模板写 `devecocli run --module entry --ability ProbeAbility`——本工程无独立探针
> Ability（module.json5 仅 mainElement=EntryAbility，本会话 grep 核实），探针页由 EntryAbility 解析
> want 参数 `page=probe` 拉起（U0.1 路由契约，EntryAbility.ets:62-63 PROBE_PAGE_PATH；P4-U1/U7.1
> 手册同款注记）。

### 3.1 主页面人工走查（先做；PROBE-u4-1 §5 清单 1~23 项）

按 P4-U1 手册 §5 清单 23 项逐项操作核对。数据准备两条（P4-U1 手册 §3.1 同款）：

- 走查项 6/7（分类过滤/搜索）需要完成列表有不同扩展名的历史行：经"New"对话框从测试源下载多个不同
  URL 小文件（主机侧 `python -m http.server` 目录放 a.pdf/b.mp3/c.zip/d.bin 各几十 KB）；
- 走查项 21（>50 行流畅性）：重复新建/下载或用既有历史凑满 50+ 行后滑动观察。

### 3.2 OPT-1 专项人工步骤（三项 UX 收口 + 深色全界面目检）

以下操作全部发生在主页面走查阶段（探针会话开始前），结果计入对应走查项的勾选判据：

**a) 深色模式全界面可读（走查项 23，OPT-1 新增项——分四步）**：

1. 应用主页 → ☰ 汉堡菜单 → **Settings**（启用项，`Index.ets:1595-1601` pushPathByName('settings')）
   → **常规页签** → 勾选 **"Use dark theme if possible"**（Toggle，
   `GeneralSettingsTab.ets:480`；文案 string.json settings_dark_theme）→ **OK 保存**——保存即生效
   （`Settings.ets:54` handleSave → `:59-70` applyThemeNow → setColorMode(NOT_SET)，应用转为跟随系统）；
2. **系统设置切深色模式**（模拟器/真机的系统 设置→显示→深色模式）→ 回应用逐界面目检：
   主列表双列表行、分类面板（未选中/选中两态）、工具栏六钮、搜索行、状态栏、行右键菜单，以及
   新建/进度/完成/选择/删除确认对话框、视频捕获页（三钮/错误文案/组头/行选中底）、设置页分类选中底。
   判据：**全部界面文字与底色对比可读，无同色叠字/白底白字/黑底黑字**（OPT-1 语义色 base+dark 双份
   color.json 各 12 键资源化的验收面，键表见设计书 §2.1）；
3. **系统切回浅色模式** → 再目检：全界面与 OPT-1 前既有观感一致，**唯一有意浅色变化 = 分类面板
   未选中行字色由系统黑收口为中性灰（#5B6B79，text_secondary）**；选中行黑字浅蓝底不变。若发现
   其余任何可见色差 → 深浅色资源回归，记入第 23 项不勾并按 §7 分流；
4. 目检完成后回探针页勾选第 23 项（深色专项期间离开应用属走查阶段操作，不触碰探针会话）。

**b) 僵死 Waiting 行收口（走查项 14/15，判据不变、语义随 OPT-1 清扫增强）**：

1. 造排队行：测试源慢源占槽——经 New 对话框连建 3 个 `/slow.bin?ms=300` 下载（占满默认并发上限
   3，`Config.ets:219` DEFAULT_MAX_PARALLEL_DOWNLOADS=3），再新建第 4 个 → 其状态列显 **Waiting**。
   **必须用慢源**：2026-10-03 会话教训（PROBE-SESSION-ALL.md:92）——快源完成太快，排队窗口一闪而过；
2. 点排队行按钮 → 显"取消排队"→ 点击后行变 Stopped + 按钮变"继续"（项 14）；
3. 杀进程重启（等价断电，非退后台）：
   `hdc shell aa force-stop com.neuohos.xdm` → 重新拉起应用 → 该行仍为停态（项 15，DB 回声）；
4. OPT-1 增量负向观测：重启装载后列表不出现"状态列 Waiting 但按钮/队列语义错位"的僵尸行
   （启动清扫 `sweepOrphanWaiting` 在 admission drain 之后执行，`Index.ets:444-446`）——待接纳/排队行
   不闪现误标 Stopped；若观察到排队行启动即 Stopped 且无法继续，为反向僵尸回归，按 §7 分流。

**c) 搜索早退（并入走查项 7 的勾选判据——OPT-1 前该项只验"完成列表过滤"，OPT-1 后须加验早退）**：

1. 切分类第 1 项"全部下载中"（分类 0，进行中视图）→ 搜索框输入任意关键词 → 点搜索钮 →
   **无任何变化**（`Index.ets:1019-1021` 分类 0 早退，对齐源 ApplyFilter index==0 零过滤分支）；
2. 切"全部已完成" → 完成列表**无过滤残留**（OPT-1 前：进行中视图下点搜索会隐式改写完成 DS 投影，
   切回完成页才显形）；
3. 再切子分类（如 Video）→ 输入关键词点搜索 → 完成列表按名称包含过滤正常（项 7 原判据）。
   三条全过才勾选项 7。

## 4. 抓取标记（S4 单步 END 行出现后）

```bash
"D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" shell "hilog -x | grep XDM_PROBE" > probe-OPT-1.log
# 兜底：缓冲被冲掉时取探针写盘结果（路径见 BEGIN 行 filesDir=）
hdc shell "cat <filesDir>/probe-latest.txt"
# 探针闪退时：devecocli log --crash
# 业务侧诊断（引擎/manager 异常走这里，非探针标记）：
hdc shell "hilog -x | grep -E 'DownloadManager|PieceScheduler|Index'"
```

**会话形态**（一次完整流程 = 两段会话，各自 BEGIN/END 配对独立 runId；与 P4-U1 手册 §4 同款）：

| 会话 | 触发 | 行序列 |
|---|---|---|
| 主会话 | 探针页"运行全部" | BEGIN+S1+S2+S3+S4+SUMMARY+END（7 行；S4 为**占位发射**——勾选面此刻多为未勾状态） |
| S4 单步会话 | S4 行"执行"按钮 | BEGIN+S4+SUMMARY+END（4 行；**验收锚**） |

xdm-probe-verify 取**末次 runId**（S4 单步会话）判 S4，取主会话判 S1~S3。
探针页卡片：探针首页 → **"P4-U1 主窗口走查探针"**（string.json probe_p4u1_title）；
勾选面提示"主页面走查完成后逐项勾选，再点击 S4 执行"（probe_p4u1_check_hint）。

## 5. OPT-1 相关走查项对照（全表见 PROBE-u4-1 §5；此处只列本单元判据有增量的四行）

| # | 走查项 | 操作 | 预期（OPT-1 判据） | 差异锚 |
|---|---|---|---|---|
| 7 | 搜索过滤 | §3.2-c 三步 | 完成/子分类过滤正常 + 分类 0 点搜索零变化 + 切回完成页无过滤残留 | Index.ets:1019-1021 早退 = 源 ApplyFilter index==0 零过滤分支 |
| 14 | Waiting 行按钮 | §3.2-b 步 1~2 | 慢源占槽造排队行 →"取消排队"→ 行变 Stopped+按钮"继续" | F3/D10（U4.1 既有）；OPT-1 清扫不改变本项判据 |
| 15 | 排队取消持久 | §3.2-b 步 3~4 | 重启后该行仍停态；装载后无 Waiting 僵尸行、待接纳行不闪现 Stopped | D9 DB 回声 + OPT-1 initLists 装载清扫（Index.ets:444-446/:483-491） |
| 23 | 深色模式全界面可读 | §3.2-a 四步 | 深浅两态全部界面可读，无同色叠字；切回浅色唯一有意变化=分类面板未选中字色收口 | OPT-1 深色语义色资源化（app.color.* base+dark 双份 color.json；U4.3 setColorMode 链零改动） |

走查项 1~6/8~13/16~22 判据与 OPT-1 前完全一致——它们是**Index 拆分纯搬迁的回归面**（事件面零破坏），
任何一项 FAIL 即拆分回归（设计书 §5.3）。全表操作/预期/差异锚见
[PROBE-u4-1-main-window-framework.md §5](PROBE-u4-1-main-window-framework.md)。

## 6. 每步骤预期日志标记表（判定细则见 EXPECT-opt-1-frontend-polish.json）

hilog 过滤 `XDM_PROBE` 后一次完整流程两段会话（§4 会话形态表）。行格式严格为
`[XDM_PROBE][P4-U1][<步骤>] key=value ...`（FORMAT 正则
`^\[XDM_PROBE\]\[([A-Z0-9-]+)\]\[([A-Za-z0-9-]+)\]\s(.+)$`；日志无 `[XDM_PROBE][OPT-1]` 行属预期，
见头部说明）。`<N>` 表浮动值；观测行不含 PASS/FAIL 判定词。
S1/S2/S3 期望串与 OPT-1 前逐字节一致（探针代码零改动锚）。

| 步骤 | 预期标记行（示例） | 判定要点 |
|---|---|---|
| BEGIN | `runId=<非空HHmmss> filesDir=<非空沙箱files路径>` | 与 END 按 runId 配对；两段会话独立 runId |
| S1 | `initOrder=c/a/b addIndex=0 totalCountAfterAdd=4 nameAsc=a/b/c/d nameDesc=d/c/b/a keywordFiltered=1 fullCount=4 categoryFiltered=1 removeHit=1 totalCountAfterRemove=3` | **数据源行为锚（零改动回归）**：初始 DateAdded desc/置顶插入/排序翻转/关键词与分类过滤/增量删除——拆分与清扫不触碰 DS 路径，期望与 EXPECT-u4-1 一致；任一偏差=拆分回归 → 分流 business-code |
| S2 | `statNoSpeed=Downloading statSpeedOnly=1.2MB/s statEtaOnly=00:01 statBoth=1.2MB/s - 00:01 statStopped=Stopped statWaiting=Waiting ip0=del0/pv1/ofv0 ip1Active=p1/r0/del1 ip1Idle=p0/r1 ip2=p1/r1/del1 fin1=of1/pv0/del1` | **纯函数运行时佐证（零改动回归）**：状态合成六分支+`' - '`连接符+工具栏五场景——ToolbarAlgo/StatusText 本单元锁定不动，偏差=回归 → 分流 business-code（与既有单测互证） |
| S3 | `maxParallelBefore=3 submitted=2 queuedStatusBeforeStop=3 queuedCancelEcho=1 startedCount=1 pausedEcho=1 liveAfterStops=0 queuedAfterCancel=0 dbStatusAfterEcho=1 maxParallelRestored=3` | **F3/D9 闭环锚（零改动回归；唯一网络步骤）**：排队取消不补位+DB 回声链；errCode/errMessage（2300028/2300007）→ env（测试源未启动/地址错/防火墙）；maxParallelBefore≠3 → UNVERIFIED（残留 preferences，重启重跑） |
| S4 | 主会话：`checked=<0..23> total=23 unchecked=<项号'/'串或 none>；单步会话（验收锚）：checked=23 total=23 unchecked=none（全绿目标）` | **OPT-1 核心锚**：`total=23`（22→23 同步铁律——`total=22` 即设备上 HAP 非本单元同步版，重跑 `devecocli run --module entry` 后重验）；unchecked 非空→按项号分流（7=搜索早退、14/15=僵死 Waiting、23=深色可读，其余 1~22=拆分回归，见 §5/§7）；**验收锚=末次 runId（S4 单步会话）** |
| SUMMARY | `[SUMMARY] S1=<...>|S2=<...>|S3=<...>|S4=<...>` | 恰 4 段（S1..S4，各段含关键键：S1=initOrder；S2=statBoth；S3=queuedCancelEcho,startedCount；S4=checked）；环形缓冲兜底锚；单行 <1500B 由 ProbeKit 两级降级保证 |
| END | `ok=true steps=<主会话4|单步会话1> elapsedMs=<非负整数ms>` | ok=true 表示本次会话无脚手架级异常（步骤级 catch 不置 false）；steps 与步骤行数互证 |

预期标记行全文示例（占位示意值，非判定锚——判定一律以 EXPECT 表范围/存在性表述为准）：

```
[XDM_PROBE][P4-U1][BEGIN] runId=153012 filesDir=/data/app/el2/100/base/com.neuohos.xdm/haps/entry/files
[XDM_PROBE][P4-U1][S1] initOrder=c/a/b addIndex=0 totalCountAfterAdd=4 nameAsc=a/b/c/d nameDesc=d/c/b/a keywordFiltered=1 fullCount=4 categoryFiltered=1 removeHit=1 totalCountAfterRemove=3
[XDM_PROBE][P4-U1][S2] statNoSpeed=Downloading statSpeedOnly=1.2MB/s statEtaOnly=00:01 statBoth=1.2MB/s - 00:01 statStopped=Stopped statWaiting=Waiting ip0=del0/pv1/ofv0 ip1Active=p1/r0/del1 ip1Idle=p0/r1 ip2=p1/r1/del1 fin1=of1/pv0/del1
[XDM_PROBE][P4-U1][S3] maxParallelBefore=3 submitted=2 queuedStatusBeforeStop=3 queuedCancelEcho=1 startedCount=1 pausedEcho=1 liveAfterStops=0 queuedAfterCancel=0 dbStatusAfterEcho=1 maxParallelRestored=3
[XDM_PROBE][P4-U1][S4] checked=0 total=23 unchecked=1/2/3/4/5/6/7/8/9/10/11/12/13/14/15/16/17/18/19/20/21/22/23
[XDM_PROBE][P4-U1][SUMMARY] S1=initOrder=c/a/b|S2=statBoth=1.2MB/s - 00:01|S3=queuedCancelEcho=1,startedCount=1|S4=checked=0
[XDM_PROBE][P4-U1][END] ok=true steps=4 elapsedMs=23500
（S4 单步会话，第二次运行）
[XDM_PROBE][P4-U1][BEGIN] runId=154210 filesDir=...
[XDM_PROBE][P4-U1][S4] checked=23 total=23 unchecked=none
[XDM_PROBE][P4-U1][SUMMARY] S4=checked=23
[XDM_PROBE][P4-U1][END] ok=true steps=1 elapsedMs=15
```

失败形态：步骤异常 catch emit `errCode/errMessage`；S3 网络类异常（2300028 超时/2300007 拒连）
→ 测试源未启动/地址错（env）。S4 行异常（勾选面读数失败）→ 分流 probe-code。

## 7. 环境差异分支（重跑指引）

| 现象 | 判定 | 处置 |
|---|---|---|
| S4 `total=22`（或出现 `[XDM_PROBE][OPT-1]` 行） | env | 设备上 HAP 非 OPT-1 同步版（探针三处同步未随包构建）——去掉 `--skip-build` 重跑 `devecocli run --module entry` 后重验；若仍 22 查 ProbeMainWindow.ets CHECKLIST_TITLES 是否 23 项（probe-code） |
| S4 unchecked 含 23 | 按目检结果分流 | 先确认 §3.2-a 四步是否做完（env）；做完仍有同色叠字/白底白字 → 分流 business-code（查 color.json base+dark 双份 12 键与组件 $r 消费点——设计书 §2.1 键表）；仅"切回浅色有可见色差"且变化面超出分类面板未选中字色 → 同分流 |
| S4 unchecked 含 7 | FAIL | 分流 business-code（搜索早退回归——查 Index.ets onSearchClick 头部 `activeCategoryIndex === 0` 早退分支与 selectCategory 清框） |
| S4 unchecked 含 14/15 | FAIL | 分流 business-code（清扫回归——查 sweepOrphanWaiting 调用点时序（须在 setAdmissionReady(true) 之后）与 isLive/isQueued 保护；或造行操作未用慢源 → env 重做） |
| S4 unchecked 含其余 1~22 | 按项号分流 | 拆分回归——对照 PROBE-u4-1 §5 差异锚逐项返修（事件处理器/工具栏状态机/防回环应逐字节未动，先查拆分接线） |
| S1/S2/S3 任一偏差 | 同 P4-U1 手册 §7 | 零改动锚失守=拆分/清扫引入回归 → 分流 business-code（S3 网络类 errCode 先分 env） |
| 深色下个别界面不可读但第 23 项已勾 | 复核 | 勾选前必须完成 §3.2-a 全部界面目检——误勾先纠正操作再重验（UNVERIFIED） |
| 模拟器 vs 真机 | — | 真机优先（深浅色切换/交互更真实）；结论按实际运行环境标注回写计划 |

## 8. 非日志门禁（OPT-1 验收的 [A] 面——不经探针日志，编码会话内执行）

1. **编译门禁**：hvigor 全量构建零 error 零新 warning（ArkTS 严格子集编译期强制；重点自查面见设计书
   §5.1：`rowBackground(): Resource` 返回类型、三元两侧同为 Resource、@Prop class/数组、CustomBuilder
   闭包、@Link searchText）。既有口径：`devecocli build --modules entry` → BUILD SUCCESSFUL。
2. **单测真值（唯一计分口径，数量钉死 640）**：
   `node scripts/run-hypium.cjs --expected-tests 640 --output ../migration-runs/hypium -- 'D:/Tools/DevEco Studio/tools/node/node.exe' 'D:/Tools/DevEco Studio/tools/hvigor/bin/hvigorw.js' test --no-parallel`
   ——四条件全满足（result 文件 + 完成标记 + expectedTests 钉死 + exit 0）方为通过；**不得以 hvigor
   退出码或 BUILD SUCCESSFUL 判绿**（scripts/HYPIUM_GATE.md；hvigor test 存在假绿）。本单元零新增
   测试文件，`--expected-tests 640` 不得改动（设计书 §0-7/§5.2）。

## 9. 回贴

把 probe-OPT-1.log 全文（两段会话 [XDM_PROBE] 行一律不要手工删改）+ §5 四项走查结果（含 §3.2 专项
操作记录：深色目检的界面清单与浅色对照结论）发给 AI，由 xdm-probe-verify 核对——**参数：
`probeDoc=XdmHarmony/docs/probe/PROBE-opt-1-frontend-polish.md`，`unit=P4-U1`**（S4 取末次 runId）。
结论（含验证环境：真机/模拟器）与既有单元同口径写回 MIGRATION_PLAN。本单元特有回写项：

①S4 total=23 与 23/23 全绿（unchecked 项号清单=返修输入；total=22 记 env 未同步）；
②第 23 项深色观测结论（深色全界面可读 + 浅色零回归且唯一有意变化=分类面板未选中字色收口）；
③UX 三项收口：对比度（并入②）、僵死 Waiting（14/15 复走 + 装载后无僵尸行负向观测）、搜索早退
（分类 0 点搜索完成投影零残留）；
④S1/S2/S3 零改动锚全绿=拆分事件面零破坏的探针侧证据（与 hvigor 编译门禁、640 单测共同构成验收）。
