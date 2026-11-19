# 探针运行手册：P5-U2 剪贴板监视+保存目录探针

> 工程根：D:\git\HarmonyPC\XdmHarmony ｜ bundle：com.neuohos.xdm ｜ 预期表：[EXPECT-u5-2-clipboard-save-dir.json](./EXPECT-u5-2-clipboard-save-dir.json)
> hdc 未入 PATH，用全路径：HDC="D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
> 探针页形态：**autoStart=false**——S1/S2 autoRun（主会话）+ **S3/S4/S5 单步执行**。
> 单元验收核心（UNIT_CATALOG U5.2"复制直链弹提示；文件落用户目录"）：S1 监视订阅+READ_PASTEBOARD
> 申请锚 + S2 程序写入直链三连（识别/去重/过滤——ClipboardMonitor.cs:66-71 三重过滤链）+
> S3 人工复制轨（跨应用复制被识别）+ S4 保存目录选择三键回读+StateStore 目录级清理观测 +
> S5 人工走查清单 10 项发射。
> 前置人工：**无测试源需求**（本单元不下载；S2 仅程序写入剪贴板，startDownloadAutomatically
> 默认 false 不触发下载）。首次运行 S1 会弹 **READ_PASTEBOARD 授权框（点允许）**。

## 0. 运行次序（本单元）

主会话先跑（S1 置 MonitorClipboard=true 并**保持不恢复**——S2/S3 与走查①同向依赖；S2 后
detectBaseline 刷新），再做人工单步：

1. **主会话**：探针页 → P5-U2 卡片 → 点"运行全部"（S1→S5 依表自动跑完；**首跑 S1 弹
   READ_PASTEBOARD 授权框——点允许**；S3/S4/S5 发占位行 mode=mainSessionPlaceholder，无副作用）；
2. **S3 单步（人工复制轨）**：先在**系统内任意应用**（浏览器/备忘录）复制任意一条 http(s) 直链
   （**与 S2 写入的 `http://192.168.1.20:8080/big.bin` 不同**）→ 回探针页 P5-U2 → S3 行点"执行"
   （用户复制动作已触发 onUpdate）；
3. **S4 单步**：S4 行点"执行" → 系统弹**目录 picker** → 人工选一个目录（点取消也是合法观测，
   见 §7）；探针随后自动做 StateStore 清理观测（probe-p5u2-<runId>/ 目录建删，无残留）；
4. **人工走查（正常应用模式）**：按 §5 清单 10 项——**先退出探针页回正常应用模式**（Home 出应用
   → `hdc shell aa start -b com.neuohos.xdm -a EntryAbility` 或点桌面图标进 Index 主页；
   走查①~⑩需要 Index/设置页在场，探针冷启动模式下 Index 不在（page=probe 路由））；
5. **S5 单步（发射）**：走查完成后回探针页（`hdc shell aa start ... --ps page probe`），把 §5
   清单逐项勾选 → S5 行点"执行"发射 `checked/total/unchecked`。

## 1. 一次性准备

```bash
# 真机（推荐验证环境：剪贴板跨应用复制/用户目录落盘/预览都更真实）：真机拒绝未签名 HAP，首次必须做——
devecocli auth login                              # 华为账号登录
#   USB 连接真机并开启开发者模式/USB 调试后：
devecocli signature generate --product default    # 注册设备+生成签名材料，自动写入 build-profile.json5
# 模拟器（兜底/形态验证）：推包不需要签名
devecocli emulator list                           # 确认实例（本机已有 "Pura 90"）
```

> 环境差异：S3 人工复制轨要求剪贴板 `on('update')` 跨应用触发——真机/模拟器均可用（系统级
> 回调）；模拟器可完整验 S1/S2/S4 与目录 picker。真机上 READ_PASTEBOARD 授权框为系统真弹窗。

## 2. 测试源

**无**——本单元不发起下载（S2 仅 `setData` 程序写入剪贴板，无需权限 D14；
`startDownloadAutomatically` 默认 false，剪贴板命中走弹窗分支）。走查⑤（完成拷贝入用户目录）
如需真实下载可零改动复用 P1-U2-download-server.js（见 PROBE-u5-1 手册 §2）。

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
# 探针首页 → P5-U2 卡片 → "运行全部"（主会话；首跑弹 READ_PASTEBOARD 点允许）
# → （复制 http(s) 直链）S3 行"执行" → S4 行"执行"（弹目录 picker）
# → （正常模式走查 §5 后回探针页勾选）S5 行"执行"
```

> 模板差异说明：通用模板写 `--ability ProbeAbility`——本工程无独立探针 Ability（module.json5 仅
> mainElement=EntryAbility），探针页由 EntryAbility 解析 want 参数 `page=probe` 拉起（U0.1 路由
> 契约；U5.1 等既有手册同款注记）。
> **READ_PASTEBOARD 指引**：S1 期间弹出（`requestPermissionsFromUser` fire-and-forget，S1 行
> 发射时弹窗可能仍在屏上）——**点允许**（该申请与正常模式 New 菜单预填共用同一会话级守卫
> requestReadPermission——任一处已授权，另一处不再弹）。拒绝后果：`getData()` 报 201 → `lastReadOk=false`、
> S2 `detectDelta=0`（监视链空转，订阅保持不重弹 D9）——需到系统设置授予剪贴板读取权限（或
> 卸载重装）后重跑；**拒绝不阻断 S4**（picker/StateStore 清理与剪贴板读权限无关）。
> **S3 人工复制轨指引**：在任意应用复制一条 http(s) 直链（建议浏览器地址栏文件直链或备忘录中
> 预置文本），**不要复制 S2 已写入的同一条**（lastClipboardText 去重锚会吞掉——想验去重请直接
> 看 S2 的 dedupDetectDelta=0）；复制后**立刻**回探针页点 S3"执行"（拖太久可能被后续复制覆盖）。

## 4. 抓取标记（S5 单步 END 行出现后）

```bash
"D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" shell "hilog -x | grep XDM_PROBE" > probe-P5-U2.log
# 兜底：缓冲被冲掉时取探针写盘结果（路径见 BEGIN 行 filesDir=）
hdc shell "cat <filesDir>/probe-latest.txt"
# 探针闪退时：devecocli log --crash
# 业务侧诊断（监视/拷贝/打开异常走这里，非探针标记）：
hdc shell "hilog -x | grep -E 'ClipboardWatcher|SaveDirectory'"
```

**会话形态**（一次完整流程 = 四段会话，各自 BEGIN/END 配对独立 runId）：

| 会话 | 触发 | 行序列 |
|---|---|---|
| 主会话 | 探针页"运行全部" | BEGIN+S1+S2+S3+S4+S5+SUMMARY+END（8 行；S3/S4/S5 为**占位发射** mode=mainSessionPlaceholder） |
| S3 单步会话 | S3 行"执行" | BEGIN+S3+SUMMARY+END（4 行；人工复制轨观测） |
| S4 单步会话 | S4 行"执行" | BEGIN+S4+SUMMARY+END（4 行；picker+清理观测） |
| S5 单步会话 | S5 行"执行" | BEGIN+S5+SUMMARY+END（4 行；走查计数发射） |

xdm-probe-verify 取**主会话**判 S1~S2，取**各单步会话末次 runId**判 S3/S4/S5。
主/单步区分锚：主会话内 S1 记录其 runId，S3/S4/S5 比对当前 runId 即知是占位发射还是真观测。

## 5. 人工走查清单 10 项对照表（设计书 §5 [P]；在正常应用模式执行）

| # | 走查项 | 操作 | 预期 | 差异锚 |
|---|---|---|---|---|
| 1 | 复制直链弹窗+预填 | 设置页勾选 Monitor clipboard→Save→复制直链 | 新建下载对话框弹出，URL/文件名已预填（Index 正常模式接线层；探针 S2 覆盖不到） | 拍板⑦ |
| 2 | 同 URL 不重复弹窗 | 不关对话框，再复制同一条 URL | 不再弹（openPrompts/lastClipboardText 双锚） | D10/拍板③ |
| 3 | 关闭后可再弹 | 关掉对话框→再复制同 URL | 再次弹出（PromptClosed 摘除锚） | 拍板⑥ |
| 4 | 自动开始 | 设置页勾选 Start download automatically→Save→复制直链 | 无弹窗、直接开始下载 | D7 |
| 5 | 目录登记+完成拷贝 | 设置页 General → Default download folder 行右侧「...」（即 Browse；输入框**不回填**为设计 D4）→picker 选目录→toast→跑一个下载至完成 | toast 出现；完成后文件出现在所选用户目录（文件管理器可见）；沙箱 Downloads 同有原件 | D1/D2/D4 |
| 6 | 工具栏 Open | 完成列表选中行→工具栏 Open | 预览打开成品文件 | 拍板② |
| 7 | Open folder 降级 | 工具栏 Open folder | 同路预览打开文件（鸿蒙无"定位到目录"公开 API） | D3 |
| 8 | 删记录清理残留 | 删除一个进行中记录→确认→重启应用 | 记录不恢复、无 tempDir/<id> 残留（StateStore.removeById） | 拍板⑧/R3-F1 |
| 9 | 停行不开进度窗 | 停止/排队行右键 Show progress | 不开窗（isLive 门，queued 不算 live） | INT-F6 |
| 10 | 刷新窗停止单发 | 对 **Http** 记录（非 Http 弹「不可用」为 U6.3 设计）刷新链接窗 Stop 或点外部关闭 | 窗关无报错；恰一次由 RefreshLinkDialog stoppedSent 守卫+host `refresh dialog reports its captured token exactly once` 保证（实现不打 WatchingStopped 日志，旧锚已废） | INT-F5 |

> 走查复位：项 4 走查完把 Start download automatically 打回 false，避免污染后续剪贴板会话
> （否则复制直链直接开下载）。项 1 依赖 MonitorClipboard=true——S1 已置 true（不恢复），亦可
> 由设置页 Save 广播触达（syncFromConfig 链）。

## 6. 每步骤预期日志标记表（判定细则见 EXPECT 表）

hilog 过滤 `XDM_PROBE` 后一次完整流程四段会话（§4 会话形态表）。行格式严格为
`[XDM_PROBE][P5-U2][<步骤>] key=value ...`。观测行不含 PASS/FAIL 判定词。

| 步骤 | 预期标记行（示例值） | 判定要点 |
|---|---|---|
| BEGIN | `runId=<HHmmss> filesDir=<非空沙箱files路径>` | 与 END 按 runId 配对；四段会话独立 runId |
| S1 | `cfgBefore=false cfgAfter=true watcherActive=true permRequested=true detectBase=0 filteredBase=0` | 订阅建立/权限申请发起/基线计数锚；S1 置 true 后**不恢复**（S2/S3/走查①依赖） |
| S2 | `url1=http://192.168.1.20:8080/big.bin detectDelta=1 dedupDetectDelta=0 filteredUrl=ftp://host/f.bin filteredDelta=1 lastDetectedUrl=http://.../big.bin lastReadOk=true` | 识别/去重/过滤三段事实锚；lastReadOk=false+detectDelta=0=权限被拒 observe-both（§7） |
| S3 | `lastDetectedUrl=<用户复制URL> detectDelta=1 lastReadOk=true probeHandlerFired=<n>` | 跨应用人工复制被识别锚；detectDelta 对 S2 后基线 |
| S4 | `pickedUri=file://... folderCount=1 selectionMode=1 userSelected=file://... tempGone=true` | picker URI/三键回读/目录级删除锚；pickedUri=null=用户取消 observe-both |
| S5 | `checked=<n> total=10 unchecked=<项号'/'串\|none>` | 走查完成度发射（1 基项号；ProbeDialogs S5 同式） |
| SUMMARY | `[SUMMARY] S1=<...>|S2=<...>|S3=<...>|S4=<...>|S5=<...>` | 恰 5 段；环形缓冲兜底锚 |
| END | `ok=true steps=<主会话5\|单步会话1> elapsedMs=<N>>=0` | ok=true=无脚手架级异常；steps 与步骤行数互证 |

预期标记行全文示例（占位示意值，非判定锚——判定一律以 EXPECT 表范围/存在性表述为准）：

```
[XDM_PROBE][P5-U2][BEGIN] runId=161205 filesDir=/data/app/el2/100/base/com.neuohos.xdm/haps/entry/files
[XDM_PROBE][P5-U2][S1] cfgBefore=false cfgAfter=true watcherActive=true permRequested=true detectBase=0 filteredBase=0
[XDM_PROBE][P5-U2][S2] url1=http://192.168.1.20:8080/big.bin detectDelta=1 dedupDetectDelta=0 filteredUrl=ftp://host/f.bin filteredDelta=1 lastDetectedUrl=http://192.168.1.20:8080/big.bin lastReadOk=true
[XDM_PROBE][P5-U2][S3] mode=mainSessionPlaceholder
[XDM_PROBE][P5-U2][S4] mode=mainSessionPlaceholder
[XDM_PROBE][P5-U2][S5] mode=mainSessionPlaceholder
[XDM_PROBE][P5-U2][SUMMARY] S1=cfgAfter=true|S2=detectDelta=1|S3=mode=mainSessionPlaceholder|S4=mode=mainSessionPlaceholder|S5=mode=mainSessionPlaceholder
[XDM_PROBE][P5-U2][END] ok=true steps=5 elapsedMs=1523
（S3 单步会话——人工复制轨）
[XDM_PROBE][P5-U2][BEGIN] runId=161840 filesDir=...
[XDM_PROBE][P5-U2][S3] lastDetectedUrl=http://192.168.1.20:8080/movie.mp4 detectDelta=1 lastReadOk=true probeHandlerFired=2
[XDM_PROBE][P5-U2][SUMMARY] S3=detectDelta=1
[XDM_PROBE][P5-U2][END] ok=true steps=1 elapsedMs=3
（S4 单步会话——目录 picker+清理观测）
[XDM_PROBE][P5-U2][BEGIN] runId=162011 filesDir=...
[XDM_PROBE][P5-U2][S4] pickedUri=file://docs/storage/Users/currentUser/Download folderCount=1 selectionMode=1 userSelected=file://docs/storage/Users/currentUser/Download tempGone=true
[XDM_PROBE][P5-U2][SUMMARY] S4=tempGone=true
[XDM_PROBE][P5-U2][END] ok=true steps=1 elapsedMs=8210
（S5 单步会话——走查发射）
[XDM_PROBE][P5-U2][BEGIN] runId=170002 filesDir=...
[XDM_PROBE][P5-U2][S5] checked=10 total=10 unchecked=none
[XDM_PROBE][P5-U2][SUMMARY] S5=checked=10
[XDM_PROBE][P5-U2][END] ok=true steps=1 elapsedMs=2
```

失败形态：步骤异常 catch emit `errCode/errMessage`（S1 权限缺配 201 → module.json5 漏配分流
business-code；S4 picker/文件异常）。探针值全 ASCII 消毒（CJK 经 `?` 占位，非故障——S3 人工
复制 URL 若含中文即此形态）。

## 7. 环境差异分支（重跑指引）

| 现象 | 判定 | 处置 |
|---|---|---|
| S1 errCode=201 | FAIL | 分流 business-code（module.json5 READ_PASTEBOARD 缺配/reason 缺失——对照设计书 §1-#1） |
| S2 lastReadOk=false 且 detectDelta=0 | **observe-both** | 权限被拒（用户在弹窗点了拒绝）——回读 S1 permRequested；到系统设置授剪贴板权限（或卸载重装复位授权）后重跑；S3 同此形态 |
| S2 lastReadOk=true 且 detectDelta=0 | FAIL | 分流 business-code（on('update') 订阅链/isUriValid/clipboardChanged 过滤链——对照设计书 §3.1/§3.2） |
| S2 dedupDetectDelta≠0 | FAIL | 分流 business-code（lastClipboardText 去重锚——:70 次序红线） |
| S2 filteredDelta=0 | FAIL | 分流 business-code（isUriValid 过滤——scheme 白名单链） |
| 同一应用会话内重跑主会话 S2 detectDelta=0 | 合法观测（重跑伪影） | lastClipboardText 进程内去重锚仍持上轮 URL——杀进程（或重装）后重跑即复得 detectDelta=1；verify 用 rerunOf 对比时人工标注 |
| S3 detectDelta=0 且 lastDetectedUrl 未变 | **observe-both** | 用户复制了非 http(s) 文本或与 S2 同 URL（去重锚吞）——按手册换一条新直链重做 |
| S3 弹窗预填未验 | 合法分工 | page=probe 冷启动下 S3 只验"识别+计数"，弹窗预填层由走查①承担（设计书 §6 分工，防假 PASS） |
| S4 pickedUri=null | **observe-both** | 用户在 picker 点了取消/返回——重跑 S4 选一个目录即可；三键回读保持上次值 |
| S4 tempGone=false | FAIL | 分流 business-code（StateStore.removeById 目录级删除链——listFileSync/unlinkSync/rmdirSync） |
| S4 errCode=13900032 | FAIL | 分流 business-code（rmdirSync 非空=逐文件 unlink 未净——removeById 链） |
| 模拟器 vs 真机 | — | 真机优先（跨应用剪贴板复制/用户目录落盘/预览更真实）；模拟器可验 S1/S2/S4 与 picker；结论按实际运行环境标注回写计划 |

## 8. 回贴

把 probe-P5-U2.log 全文（四段会话 [XDM_PROBE] 行一律不要手工删改）+ §5 走查清单 10 项勾选结果
发给 AI，由 xdm-probe-verify 核对（S1/S2 取主会话、S3/S4/S5 取各单步会话末次 runId）；结论
（含验证环境：真机/模拟器）与既有单元同口径写回 MIGRATION_PLAN。本单元特有回写项：
①S1 订阅建立+READ_PASTEBOARD 运行期申请锚（watcherActive/permRequested）；
②S2 三重过滤链三段事实（识别 detectDelta=1/去重 dedupDetectDelta=0/过滤 filteredDelta=1）；
③S3 跨应用人工复制识别（lastDetectedUrl）+ 弹窗预填层走查①结果；
④S4 picker 三键回读（recentFolders[0]/selectionMode=1/userSelected）+ StateStore 目录级清理
（tempGone=true）；
⑤走查 10 项勾选结果（含权限拒绝/用户取消等 observe-both 项的最终状态）。
