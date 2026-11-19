# 探针运行手册：P4-U1 主窗口框架走查探针（U4.1 工具栏/分类树/搜索/LazyForEach/F3-D9 闭环）

> 工程根：D:\git\HarmonyPC\XdmHarmony ｜ bundle：com.neuohos.xdm ｜ 预期表：[EXPECT-u4-1-main-window-framework.json](./EXPECT-u4-1-main-window-framework.json)
> hdc 未入 PATH，用全路径：HDC="D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
> 探针页形态：**autoStart=false**——S1/S2/S3 autoRun + **S4 人工走查清单（23 项 Toggle 勾选，单步执行）**。
> 单元验收核心（UNIT_CATALOG U4.1"走查清单项可勾；列表流畅"）：§5 人工走查清单 23 项 + S1 数据源
> 行为锚 + S2 纯函数运行时佐证 + S3 排队取消回声链（F3 死按钮闭环 + D9 DB 回声端到端）。

## 0. 运行次序红线（本单元特有，必读）

**先主页面人工走查 → 再探针**（设计书 §0-11/§8-4）：

1. **先主页面走查**：启动应用主页（探针尚未运行时 manager 事件袋归 Index），按 §5 清单逐项核对，
   建议同步在纸上记下各项结果；
2. **再进探针页跑"运行全部"**（S1~S3 自动；S3 会 `manager.init` **后到者接管事件袋**——此刻起
   Index 列表不再收到引擎事件，属预期）；
3. **回探针页勾选 23 项清单 → 单步执行 S4**（发射 checked/total/unchecked）；
4. **探针会话内不切页**（S3 轮询期切回 Index 会把事件袋换走，S3 序流断流）；
5. 走查清单第 14/15 项（Waiting 行取消排队→重启持久）涉及重启——**重启后再进探针页勾选，
   重启会自然恢复 Index 事件袋**，与次序红线不冲突（重启后先勾选、再单步 S4 即可）。

## 1. 一次性准备

```bash
# 真机（推荐验证环境）：真机拒绝未签名 HAP，首次必须做——
devecocli auth login                              # 华为账号登录
#   USB 连接真机并开启开发者模式/USB 调试后：
devecocli signature generate --product default    # 注册设备+生成签名材料，自动写入 build-profile.json5
# 模拟器（兜底/形态验证）：推包不需要签名
devecocli emulator list                           # 确认实例（本机已有 "Pura 90"）
```

## 2. 测试源（主机侧，仅 S3 需要）——P1-U2-download-server.js 复用（零改动）

```bash
cd /d D:\git\HarmonyPC\XdmHarmony\docs\probe
node P1-U2-download-server.js            # 默认 8080
# 预期输出：
# [P1-U2] download server listening on 0.0.0.0:8080  (big.bin=4194304B, routes: /big.bin /slow.bin?ms=40 /echo /redirect /final)
# [P1-U2] probe base url = http://<本机局域网IP>:8080  (设备内禁用 127.0.0.1）
```

- **复用指引**：P4-U1 不新增服务器文件——直接复用 P1-U2 主机侧测试源。本探针仅 S3 消费
  `/slow.bin?ms=300`（**ms=300 由探针 URL 参数携带**，server 端 ms 参数任意整数合法，
  `P1-U2-download-server.js:112-131` 已核实，零改动复用）。S1/S2/S4 无需测试源。
- **局域网 IP 纪律**：探针页 TextInput 填**主机局域网 IP**（如 `http://192.168.1.20:8080`）；
  模拟器内 `127.0.0.1` 是自身回环；主机防火墙需放行该端口。
- ms=300 慢源用途：S3 提交 2 个慢速下载后须在首个下载完成前完成"取消排队项→停运行项"两步
  （亚秒级操作窗口 << 单分段 4MiB@ms=300 的分钟级完成时间）——时序余量充足。

## 3. 运行（设备侧）

```bash
cd /d D:\git\HarmonyPC\XdmHarmony
devecocli emulator start "Pura 90"                # 模拟器兜底（未启动时执行；真机 USB 直连跳过本行）
devecocli device list                             # 设备就绪确认（多设备时后续命令需 --device <serial>）
devecocli run --module entry                      # 构建+安装+拉起应用主页（AI 已构建过时：加 --skip-build）
```

### 3.1 主页面人工走查（先做）

按 §5 清单 23 项逐项操作核对。提示两条数据准备：

- 走查项 6/7（分类过滤/搜索）需要完成列表有不同扩展名的历史行：可先经"New"对话框从测试源
  下载几个小文件（`/big.bin` 完成后改名为不同扩展名的历史行不现实——**直接下载多个不同 URL
  小文件**，如主机侧 `python -m http.server` 目录放 a.pdf/b.mp3/c.zip/d.bin 各几十 KB）；
- 走查项 21（>50 行流畅性）：重复新建/下载或用既有历史凑满 50+ 行后滑动观察。

### 3.2 探针会话

```bash
# 打开探针页（EntryAbility 解析 want 参数 page=probe，支持冷/暖启动）：
hdc shell aa start -b com.neuohos.xdm -a EntryAbility --ps page probe
# 探针首页 → P4-U1 卡片 → 核对 TextInput 测试源（仅 S3 需要）→ 点"运行全部"（S1→S2→S3→S4 自动）
# 回探针页勾选 23 项清单 → S4 行点"执行"（单步迷你会话）
```

> 模板差异说明：通用模板写 `--ability ProbeAbility`——本工程无独立探针 Ability（module.json5 仅
> mainElement=EntryAbility），探针页由 EntryAbility 解析 want 参数 `page=probe` 拉起（U0.1 路由
> 契约；P1-U2/P2/P3 手册同款注记）。

## 4. 抓取标记（S4 单步 END 行出现后）

```bash
"D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" shell "hilog -x | grep XDM_PROBE" > probe-P4-U1.log
# 兜底：缓冲被冲掉时取探针写盘结果（路径见 BEGIN 行 filesDir=）
hdc shell "cat <filesDir>/probe-latest.txt"
# 探针闪退时：devecocli log --crash
# 业务侧诊断（引擎/manager 异常走这里，非探针标记）：
hdc shell "hilog -x | grep -E 'DownloadManager|PieceScheduler|Index'"
```

**会话形态**（一次完整流程 = 两段会话，各自 BEGIN/END 配对独立 runId）：

| 会话 | 触发 | 行序列 |
|---|---|---|
| 主会话 | 探针页"运行全部" | BEGIN+S1+S2+S3+S4+SUMMARY+END（7 行；S4 为**占位发射**——勾选面此刻多为未勾状态） |
| S4 单步会话 | S4 行"执行"按钮 | BEGIN+S4+SUMMARY+END（4 行；**验收锚**） |

xdm-probe-verify 取**末次 runId**（S4 单步会话）判 S4，取主会话判 S1~S3。

## 5. 人工走查清单 23 项对照表（渲染进 S4 勾选面；对照 XDM 走查表与设计书 §6bis + OPT-1 追加第 23 项）

| # | 走查项 | 操作 | 预期 | 差异锚 |
|---|---|---|---|---|
| 1 | 启动默认视图 | 启动应用观察 | 分类第 2 项（全部已完成）高亮 + Tabs 停在完成页 | D15（源码 ctor:104 SwitchToFinishedView） |
| 2 | 分类面板 7 项 | 目视左栏 | 全部下载中/全部已完成/Document/Music/Video/Compressed/Application | MainWindow ctor:74-80 同构 |
| 3 | 分类计数 | 目视各分类行右端计数 | 顶层两项=两列表全长；子分类=完成列表扩展名匹配数 | D2 鸿蒙增强（源码无计数） |
| 4 | 切"全部下载中" | 点击第 1 项 | 进行中列表显示；OpenFile/OpenFolder 隐藏；Pause/Resume 显示 | ApplyFilter index==0 分支 |
| 5 | 切"全部已完成" | 点击第 2 项 | 完成列表显示；OpenFile/OpenFolder 显示；Pause/Resume 隐藏 | ApplyFilter index==1 分支 |
| 6 | 子分类过滤 | 点击 Video 等 | 完成列表仅剩匹配扩展名行 | view.Filter=IsCategoryMatched |
| 7 | 搜索过滤 | 输入关键词+点搜索钮 | 完成列表按名称包含过滤；**进行中列表不变** | D13（FilterByKeyword 未接线，源码同貌） |
| 8 | 分类切换清搜索框 | 任一分类切换后 | 搜索框被清空 | xaml.cs:153 同貌 |
| 9 | 列头排序 | 点 Name/DateAdded/Size/% | Name 首击升序再击降序；DateAdded/Size 同；% 无反应 | xaml.cs:453-477；% 无 Tag |
| 10 | 新项置顶 | 新建一个下载 | 新行出现在进行中列表顶部 | AddToTop+DateAdded desc 置顶 §3.3 |
| 11 | 单选高亮 | 点行体/再点同行 | 首点高亮+Delete 启用；再点同行保持选中（WPF 同貌，取消选中经复选框） | D3 行点击=单选替换 |
| 12 | 单选状态机 | 分别选运行/停态/Waiting 行 | 运行→Pause 启用；停态→Resume 启用；Waiting→Pause 启用 | 排队算 active（:562-565） |
| 13 | 多选状态机 | 复选框勾 2 行 | Pause+Resume 均启用 | D3 多选路径；:446-450 |
| 14 | Waiting 行按钮 | 造排队行（并发占满后新建）→点其按钮 | 按钮显"取消排队"；点击后行变 Stopped+按钮变"继续" | D10/F3 修复闭环 |
| 15 | 排队取消持久 | 14 之后杀进程重启 | 该行仍为停态（重启不复活为排队/运行） | D9 DB 回声（hooks→updateStatus） |
| 16 | 工具栏 Pause/Resume | 选中行后点工具栏按钮 | 效果与行按钮一致 | §0-6 同路径零新引擎面 |
| 17 | 工具栏 Delete | 选中非运行行点 Delete 确认 | 行消失且重启不回；运行行被停不删 | D7 简版口径（完整链 U4.2） |
| 18 | 新建下拉 | 点 New | New download 打开既有对话框；Video download/Batch download 禁用 | D5（MenuElement.enabled=false） |
| 19 | 汉堡菜单 | 点 ☰ | 12 项可见且全部占位禁用 | D5 |
| 20 | 状态栏 | 目视底部 | Browser monitoring 文案+toggle+Queue and scheduler+Help 均禁用 | D12 |
| 21 | 列表流畅 | 造 50+ 行滑动双列表 | 无可感知卡顿 | LazyForEach 增量通知 §3.5 |
| 22 | 状态列合成 | 目视运行/停/排队行 | 运行='速度 - ETA'或'Downloading'；停='Stopped'；排队='Waiting' | GenerateStatusText §3.4 |
| 23 | 深色模式全界面可读 | 常规设置页勾选"深色主题"（跟随系统）→ 系统切换深色模式 → 逐界面目检（主列表/分类面板/工具栏六钮/搜索行/状态栏/双列表行/行右键菜单/新建/进度/完成/选择/删除确认对话框） | 全部界面文字与底色对比可读，无同色叠字/白底白字/黑底黑字；切回浅色与既有观感一致（分类面板未选中字色收口为唯一有意浅色变化） | OPT-1 深色语义色资源化（`app.color.*` base+dark 双份 color.json；U4.3 setColorMode 链零改动） |

## 6. 每步骤预期日志标记表（判定细则见 EXPECT 表）

hilog 过滤 `XDM_PROBE` 后一次完整流程两段会话（§4 会话形态表）。行格式严格为
`[XDM_PROBE][P4-U1][<步骤>] key=value ...`（FORMAT 正则
`^\[XDM_PROBE\]\[([A-Z0-9-]+)\]\[([A-Za-z0-9-]+)\]\s(.+)$`）。`<N>` 表浮动值；观测行不含 PASS/FAIL 判定词。

| 步骤 | 预期标记行（示例） | 判定要点 |
|---|---|---|
| BEGIN | `runId=<HHmmss> filesDir=<非空沙箱files路径>` | 与 END 按 runId 配对；两段会话独立 runId |
| S1 | `initOrder=c/a/b addIndex=0 totalCountAfterAdd=4 nameAsc=a/b/c/d nameDesc=d/c/b/a keywordFiltered=1 fullCount=4 categoryFiltered=1 removeHit=1 totalCountAfterRemove=3` | **数据源行为锚**：初始 DateAdded desc（升序喂入 t1<t2<t3 → c/a/b）；addSorted 新项插 index 0（置顶语义 §3.3）；Name 排序翻转 asc→desc；关键词过滤只动投影（fullCount=4 不蚀全量）；'.ZIP' 分类过滤命中 c.zip；removeById 命中 |
| S2 | `statNoSpeed=Downloading statSpeedOnly=1.2MB/s statEtaOnly=00:01 statBoth=1.2MB/s - 00:01 statStopped=Stopped statWaiting=Waiting ip0=del0/pv1/ofv0 ip1Active=p1/r0/del1 ip1Idle=p0/r1 ip2=p1/r1/del1 fin1=of1/pv0/del1` | **纯函数运行时佐证**（与 [A] 单测互证）：状态合成四形态+`' - '`连接符+三停态标签；状态机五场景布尔 |
| S3 | `maxParallelBefore=3 submitted=2 queuedStatusBeforeStop=3 queuedCancelEcho=1 startedCount=1 pausedEcho=1 liveAfterStops=0 queuedAfterCancel=0 dbStatusAfterEcho=1 maxParallelRestored=3` | **F3/D9 闭环锚（本单元核心验收）**：maxParallel=1 门挡 r2 入队（queuedStatusBeforeStop=3=Waiting）；queuedCancelEcho=1（isQueued 分派命中+hooks 回声恰一次）；**startedCount=1（排队取消不补位——先取消排队后停运行次序的确定性论证见 EXPECT）**；pausedEcho=1（r1 stop 的 onPaused 回声）；liveAfterStops=0；dbStatusAfterEcho=1（D9 DB 回声链端到端——注：R2 规则 completed=0 行读回恒 Stopped，本锚为链路存在性佐证，唯一性由 queuedCancelEcho=1 承担）；maxParallelRestored=3（环境恢复） |
| S4 | 主会话：`checked=<0..23> total=23 unchecked=<索引'/'串或 none>`<br>单步会话：`checked=23 total=23 unchecked=none`（全绿目标） | 勾选面发射；**验收锚=末次 runId（S4 单步会话）**；unchecked 非空→按项号分流走查返修 |
| SUMMARY | `[SUMMARY] S1=<...>|S2=<...>|S3=<...>|S4=<...>` | 恰 4 段（各段含关键键：S1=initOrder；S2=statBoth；S3=queuedCancelEcho,startedCount；S4=checked）；环形缓冲兜底锚；单行 <1500B 由 ProbeKit 两级降级保证 |
| END | `ok=true steps=4 elapsedMs=<N>>=0` | ok=true 表示本次会话无脚手架级异常（步骤级 catch 不置 false）；steps=4 与步骤行数互证 |

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
→ 测试源未启动/地址错（env）。

## 7. 环境差异分支（重跑指引）

| 现象 | 判定 | 处置 |
|---|---|---|
| S1 initOrder≠c/a/b 或 addIndex≠0 | FAIL | 分流 business-code（初始排序/插入位回归——查 DownloadListDataSource.initialize/addSorted 与 ListAlgo 比较器） |
| S1 keywordFiltered≠1 或 categoryFiltered≠1 | FAIL | 分流 business-code（过滤语义回归——查 isOfCategoryOrMatchesKeyword AND 链） |
| S2 statBoth≠`1.2MB/s - 00:01` 或任一场景布尔错 | FAIL | 分流 business-code（纯函数回归——与 StatusText/ToolbarAlgo 单测互证定位分支） |
| S3 `errCode/errMessage`（2300028/2300007） | env | 测试源未启动/地址错/防火墙——§2 重启服务器、核对局域网 IP 后重跑（仅 S3 依赖网络） |
| S3 `maxParallelBefore≠3` | **UNVERIFIED** | 上轮探针/设置残留 maxParallel（S4 恢复逻辑照常执行）——重启应用（preferences 仍残留则查 setMaxParallelDownloads 调用方）重跑 |
| S3 `queuedStatusBeforeStop≠3` | FAIL | 分流 business-code（maxParallel=1 门挡失效——查 admitNew 门判定或 startWaiting 工厂） |
| S3 `queuedCancelEcho=0` 或 `startedCount=2` | FAIL | 分流 business-code（**排队取消补位回归**——stopOne queued 分支/isQueued 分派缺失；次序红线未守则先查探针操作） |
| S3 `pausedEcho=0` 且 `liveAfterStops=0` | env→FAIL | 先查 server 控制台（下载是否异常终止/测试源可达）分流 env；server 正常再查引擎 stop 链 hilog PieceScheduler |
| S3 `dbStatusAfterEcho≠1` | FAIL | 分流 business-code（D9 回声链断——查 Index 同款 hooks→store.updateStatus 链与 RecordMapping R2 投影） |
| S4 unchecked 非空 | 按项号分流 | 走查项 1~23 逐项返修（项号→设计书 §6bis/§4 差异锚对照），返修后重走查+单步 S4 |
| 模拟器 vs 真机 | — | 真机优先（交互/滚动更真实）；结论按实际运行环境标注回写计划 |

## 8. 回贴

把 probe-P4-U1.log 全文（两段会话 [XDM_PROBE] 行一律不要手工删改）+ §5 走查清单勾选结果发给 AI，
由 xdm-probe-verify 核对（S4 取末次 runId）；结论（含验证环境：真机/模拟器）与既有单元同口径写回
MIGRATION_PLAN。本单元特有回写项：
①S1 数据源行为（初始排序/置顶插入/过滤/增量通知锚）；
②S2 纯函数运行时佐证（与 35 条 [A] 单测互证）；
③S3 F3 死按钮闭环（queuedCancelEcho=1+startedCount=1 不补位）+ D9 DB 回声（dbStatusAfterEcho=1）；
④S4 走查清单 23/23（unchecked 项号清单=返修输入）。
