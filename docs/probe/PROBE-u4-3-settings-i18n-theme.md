# 探针运行手册：P4-U3 设置页全配置键+i18n+主题走查探针

> 工程根：D:\git\HarmonyPC\XdmHarmony ｜ bundle：com.neuohos.xdm ｜ 预期表：[EXPECT-u4-3-settings-i18n-theme.json](./EXPECT-u4-3-settings-i18n-theme.json)
> hdc 未入 PATH，用全路径：HDC="D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
> 探针页形态：**autoStart=false**——S1/S2/S3/S4 autoRun + **S5 人工走查清单（31 项 Toggle 勾选，单步执行）**。
> 单元验收核心（UNIT_CATALOG U4.3"语言切换即时生效；深浅色；设置项读写闭环"）：
> S1 标量键默认读回锚 + S2 集合键读回锚 + S3 写回-读回-恢复闭环锚 + S4 语言/主题应用观测锚 +
> S5 走查清单 31 项（设置五页逐控件 + 语言/主题/读写闭环三验收项）。
> 前置人工步骤：**无**（纯本机面，无需测试源/主机服务器）。

## 0. 运行次序（本单元）

先设置页人工走查（S5 清单 1~30 项），后探针（S4 会改语言/主题运行态并即时恢复）：

1. **先设置页走查**：主页 → 汉堡菜单（右上三横线按钮）→ `Settings`（开常规页签）或
   `Browser monitoring`（开监控页签），按 §5 清单 1~30 项逐项核对；建议纸上记录；
2. **进探针页**：`hdc shell aa start -b com.neuohos.xdm -a EntryAbility --ps page probe`
   → P4-U3 卡片 → 点"运行全部"（S1→S4 自动+S5 占位发射；S4 会把系统语言切到 zh-Hans 再恢复、
   主题切 LIGHT 再恢复——探针页文案可能闪变中文，属预期）；
3. **回探针页勾选 31 项清单 → S5 行点"执行"**（单步迷你会话，验收锚）；
4. 清单第 31 项（语言即时切换）可在探针 S4 跑完后单独验证：主页 → 汉堡菜单 → `Language` →
   选"中文" → OK → 主界面文案即时变中文（若仍英文=zh_CN 目录未命中，判 CONTINGENCY 登记
   zh 目录退化，不判 FAIL）。

## 1. 一次性准备

```bash
# 真机（推荐验证环境）：真机拒绝未签名 HAP，首次必须做——
devecocli auth login                              # 华为账号登录
#   USB 连接真机并开启开发者模式/USB 调试后：
devecocli signature generate --product default    # 注册设备+生成签名材料，自动写入 build-profile.json5
# 模拟器（兜底/形态验证）：推包不需要签名
devecocli emulator list                           # 确认实例（本机已有 "Pura 90"）
```

## 2. 测试源

**本单元无网络面**（S1~S4 纯本机 Config 读写与系统 API；S5 走查亦无下载动作）——无需启动
P0-U2/P1-U2 服务器。

## 3. 运行（设备侧）

```bash
cd /d D:\git\HarmonyPC\XdmHarmony
devecocli emulator start "Pura 90"                # 模拟器兜底（未启动时执行；真机 USB 直连跳过本行）
devecocli device list                             # 设备就绪确认（多设备时后续命令需 --device <serial>）
devecocli run --module entry                      # 构建+安装+拉起应用主页（AI 已构建过时：加 --skip-build）
```

### 3.1 设置页人工走查（先做，清单 1~30 项）

按 §5 清单逐项操作核对。入口提示：

- 监控页：汉堡菜单 → `Browser monitoring`（对应源 ShowBrowserMonitoringDialog 开页签 0）；
- 其余四页：汉堡菜单 → `Settings`（默认开常规页签，页签栏点切换）；
- 保存链：每页改值后点 `Save`（五页一次全落库+主题即时应用+广播一次+关窗）；
  对照组用 `Cancel`（零写入）验证第 30 项。

### 3.2 探针会话

```bash
# 打开探针页（EntryAbility 解析 want 参数 page=probe，支持冷/暖启动）：
hdc shell aa start -b com.neuohos.xdm -a EntryAbility --ps page probe
# 探针首页 → P4-U3 卡片 → 点"运行全部"（S1→S4 自动，S5 占位发射）
# 回 P4-U3 页勾选 31 项清单 → S5 行点"执行"（单步迷你会话）
```

> 模板差异说明：通用模板写 `--ability ProbeAbility`——本工程无独立探针 Ability（module.json5 仅
> mainElement=EntryAbility），探针页由 EntryAbility 解析 want 参数 `page=probe` 拉起（U0.1 路由
> 契约；P1-U2/P2/P3/P4-U1/P4-U2 手册同款注记）。

## 4. 抓取标记（S5 单步 END 行出现后）

```bash
"D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" shell "hilog -x | grep XDM_PROBE" > probe-P4-U3.log
# 兜底：缓冲被冲掉时取探针写盘结果（路径见 BEGIN 行 filesDir=）
hdc shell "cat <filesDir>/probe-latest.txt"
# 探针闪退时：devecocli log --crash
# 业务侧诊断（Config/设置页异常走这里，非探针标记）：
hdc shell "hilog -x | grep -E 'XdmConfig|SettingsSession|SettingsPage'"
```

**会话形态**（一次完整流程 = 两段会话，各自 BEGIN/END 配对独立 runId）：

| 会话 | 触发 | 行序列 |
|---|---|---|
| 主会话 | 探针页"运行全部" | BEGIN+S1+S2+S3+S4+S5+SUMMARY+END（8 行；S5 为**占位发射**——勾选面此刻多为未勾状态） |
| S5 单步会话 | S5 行"执行"按钮 | BEGIN+S5+SUMMARY+END（4 行；**验收锚**） |

xdm-probe-verify 取**末次 runId**（S5 单步会话）判 S5，取主会话判 S1~S4。

## 5. 人工走查清单 31 项对照表（渲染进 S5 勾选面；对照设计书 §6）

| # | 页 | 走查项 | 操作 | 预期 | 差异锚 |
|---|---|---|---|---|---|
| 1 | 监控 | 三列表默认值原文回显 | 开监控页签 | 文件类型 23 项/视频 15 项逗号串；屏蔽主机含 `thwawte.com`（源拼写原样） | §2.1-B thwawte 保真 |
| 2 | 监控 | 三个"默认"钮回填 | 乱改列表后点默认钮 | 回填 Config.Default* join 串 | BtnDefault1/2/3 :147-160 |
| 3 | 监控 | 改扩展保存→重进保持 | 改列表→Save→重进 | 修改保持（parseExtensionList 不去重——含重复项原样保持） | §3.2 |
| 4 | 监控 | 最小体积 9 档 | 点开下拉 | 128..32768 九档可选且回显当前档 | ctor :33 |
| 5 | 监控 | 三 Toggle | 剪贴板/时间戳/媒体通知 | 回显+保存重进保持 | :44-46 |
| 6 | 监控 | 浏览器引导区不渲染 | 目检监控页 | 无六浏览器按钮/URL 复制/引导文案 | D7 降级 |
| 7 | 常规 | 进度窗/完成窗/自动开始 | 三 Toggle | 回显+保存 | PopulateUI :39-41 |
| 8 | 常规 | 覆盖已有=Overwrite | 勾选→Save→重进 | 勾=覆盖已有文件（不勾=自动重命名） | §2.3 枚举方向 |
| 9 | 常规 | 深色主题 Toggle | 切换→Save | 主题即时应用（非重启） | D2 |
| 10 | 常规 | 两目录文本回显 | 目检 | 临时文件夹/默认下载文件夹=Config 值 | :44/:47 |
| 11 | 常规 | 最大并发 1..50 | 点开下拉 | 1..50 可选且回显 | ctor :34 |
| 12 | 常规 | 自动分类 Toggle | 勾=自动选择保存位置 | 勾=Auto=0（与项 8 的 0 值方向相反） | §2.3 枚举方向 |
| 13 | 常规 | 双击行为两项 | 点开下拉 | 打开目录/打开文件两项回显 | :48 |
| 14 | 常规 | 分类默认 5 项 | 目检列表 | Document/Music/Video/Compressed/Application | §2.1-B categoriesJson |
| 15 | 常规 | 新增校验三弹 | 添加：依次空名/空类型/空目录点 OK | 三提示逐一弹出且窗不关 | CategoryEditWindow :84-100 |
| 16 | 常规 | 新增成功 | 填全后 OK | 入列表（'.MP4,.MP4,.MKV' 类输入去重显示 2 项） | CatAdd :75-90 |
| 17 | 常规 | 编辑保留 Name | 编辑已新增项改显示名 OK | 列表刷新（ForEach 键=UUID 不变） | CatEdit :92-113 |
| 18 | 常规 | 删除按选中 | 选中行点删除 | 该行消失 | CatDel :115-122（D13） |
| 19 | 常规 | 恢复默认 | 点默认钮 | 回 5 项 | CatDef :124-135 |
| 20 | 网络 | 三 Select 回显 | 开网络页签 | 超时 30/分段 8/重试 10 | PopulateUI :35-37 |
| 21 | 网络 | 限速仅数字 | 输入字母/符号 | 非数字不进输入框 | :79-82（①过滤） |
| 22 | 网络 | 失焦重置 | 清空/输非法后失焦 | 文本重置 "0" | :100-115（②失焦） |
| 23 | 网络 | 保存非法不回写 | 输入清空不合法直接 Save→重进 | 限速值保持旧值（③保存解析跳过） | :52-55 |
| 24 | 网络 | 代理三档 | 切三档→填值→Save→重进 | 仅 Manual 启用四输入；保存回显（全空也整块写回） | :73-77/:57-65 |
| 25 | 凭据 | 增/改/删 | 三操作 | 列表同步 | :48-91 |
| 26 | 凭据 | 空 Host 校验 | 空 Host 点 OK | "未填写主机名"弹窗不关窗 | PasswordWindow :75-79 |
| 27 | 凭据 | 空 User 校验 | 空 User 点 OK | "需要用户名"弹窗不关窗 | :80-84 |
| 28 | 高级 | UA 回显+Reset | 改 UA 点 Reset | 回填 Chrome/97 原串 | :73-76 |
| 29 | 高级 | 降级五组不渲染 | 目检高级页 | 无关机/唤醒/命令/杀毒/自启控件 | D7 降级 |
| 30 | 全局 | 保存闭环+取消零写入 | 改值 Save 重进见新值；改值 Cancel 重进见旧值 | 读写闭环 | BtnOK/Cancel :68-83 |
| 31 | 全局 | 语言即时切换 | 汉堡菜单→Language→中文→OK | 主界面文案即时变中文（zh_CN 目录命中判定点；**未命中=CONTINGENCY** 登记 zh 目录退化） | D1/D2 |

> 走查清单 31 项同时是 S5 勾选面逐项全文（探针页 UI 渲染同文）。

## 6. 每步骤预期日志标记表（判定细则见 EXPECT 表）

hilog 过滤 `XDM_PROBE` 后一次完整流程两段会话（§4 会话形态表）。行格式严格为
`[XDM_PROBE][P4-U3][<步骤>] key=value ...`。观测行不含 PASS/FAIL 判定词。

| 步骤 | 预期标记行（示例值） | 判定要点 |
|---|---|---|
| BEGIN | `runId=<HHmmss> filesDir=<非空沙箱files路径>` | 与 END 按 runId 配对；两段会话独立 runId |
| S1 | `notificationTimeOut=0 isBrowserMonitoring=true showNotification=true lang=en-US darkTheme=true maxParallel=3 timeout=30 segments=8 retry=10 retryDelay=10 minVideo=1024 folderSel=0 conflict=0 startAuto=false fetchTs=false monitorClip=false dblClick=false shutdown=false keepAwake=true runCmd=false antivirus=false proxyType=0 proxyPort=0 uaPrefix=Mozilla/5.0 userSelFolder=0 credCount=0` | **47 键可观测子集锚**（§2.1 全表逐一对照；userSelFolder=串长 0 表空串；UA 只发前缀 12 字符） |
| S2 | `videoExts=15 fileExts=23 blockedHosts=3 blockedHost0=update.microsoft.com blockedHost2=thwawte.com categories=5 catVideosExts=13 catDocsExts=7 recentFolders=0 videoFirst=MP4 videoLast=MPD` | **集合键锚**：15/23/3/5 计数+thwawte 保真+CAT_VIDEOS 13/CAT_DOCUMENTS 7+首尾 MP4/MPD |
| S3 | `timeoutW=120 timeoutR=120 timeoutRestored=30 segmentsW=16 segmentsR=16 segmentsRestored=8 minVideoW=2048 minVideoR=2048 minVideoRestored=1024 proxyW=2 proxyR=2 proxyHostR=10.0.0.1 proxyPortR=8080 proxyRestored=0 conflictW=1 conflictR=1 conflictRestored=0 catW=6 catR=6 catParseDedup=2 catRestored=5 credW=1 credR=1 credRestored=0` | **写回-读回-恢复闭环锚**：三写读一致；proxy Custom 全字段；conflict=1(Overwrite)；catParseDedup=2（'.MP4,.MP4,.MKV' 去重）；全部 restored=S1 基线（30/8/1024/0/0/5/0） |
| S4 | `langBefore=en-US langSet=zh-Hans langReadback=zh-Hans langRestored=en-US langAfterReadback=en-US themeApply1=light themeApply2=notset themeKeyBaseline=true` | **语言/主题应用锚**：setAppPreferredLanguage('zh-Hans') 系统层读回=zh-Hans；恢复后读回（'default' 恢复时 langAfterReadback=系统语言属合法观测）；themeApply2 按基线映射（true→notset/false→light） |
| S5 | 主会话：`checked=<0..31> total=31 unchecked=<索引'/'串或 none>`<br>单步会话：`checked=31 total=31 unchecked=none`（全绿目标） | 勾选面发射；**验收锚=末次 runId（S5 单步会话）**；unchecked 非空→按项号分流走查返修 |
| SUMMARY | `[SUMMARY] S1=<...>|S2=<...>|S3=<...>|S4=<...>|S5=<...>` | 恰 5 段；环形缓冲兜底锚 |
| END | `ok=true steps=<主会话5|单步会话1> elapsedMs=<N>>=0` | ok=true=无脚手架级异常；steps 与步骤行数互证 |

预期标记行全文示例（占位示意值，非判定锚——判定一律以 EXPECT 表范围/存在性表述为准）：

```
[XDM_PROBE][P4-U3][BEGIN] runId=143012 filesDir=/data/app/el2/100/base/com.neuohos.xdm/haps/entry/files
[XDM_PROBE][P4-U3][S1] notificationTimeOut=0 isBrowserMonitoring=true showNotification=true lang=en-US darkTheme=true maxParallel=3 timeout=30 segments=8 retry=10 retryDelay=10 minVideo=1024 folderSel=0 conflict=0 startAuto=false fetchTs=false monitorClip=false dblClick=false shutdown=false keepAwake=true runCmd=false antivirus=false proxyType=0 proxyPort=0 uaPrefix=Mozilla/5.0 userSelFolder=0 credCount=0
[XDM_PROBE][P4-U3][S2] videoExts=15 fileExts=23 blockedHosts=3 blockedHost0=update.microsoft.com blockedHost2=thwawte.com categories=5 catVideosExts=13 catDocsExts=7 recentFolders=0 videoFirst=MP4 videoLast=MPD
[XDM_PROBE][P4-U3][S3] timeoutW=120 timeoutR=120 timeoutRestored=30 segmentsW=16 segmentsR=16 segmentsRestored=8 minVideoW=2048 minVideoR=2048 minVideoRestored=1024 proxyW=2 proxyR=2 proxyHostR=10.0.0.1 proxyPortR=8080 proxyRestored=0 conflictW=1 conflictR=1 conflictRestored=0 catW=6 catR=6 catParseDedup=2 catRestored=5 credW=1 credR=1 credRestored=0
[XDM_PROBE][P4-U3][S4] langBefore=en-US langSet=zh-Hans langReadback=zh-Hans langRestored=en-US langAfterReadback=en-US themeApply1=light themeApply2=notset themeKeyBaseline=true
[XDM_PROBE][P4-U3][S5] checked=0 total=31 unchecked=1/2/.../31
[XDM_PROBE][P4-U3][SUMMARY] S1=notificationTimeOut=0|S2=videoExts=15|S3=timeoutRestored=30|S4=langReadback=zh-Hans|S5=checked=0
[XDM_PROBE][P4-U3][END] ok=true steps=5 elapsedMs=812
（S5 单步会话，第二次运行）
[XDM_PROBE][P4-U3][BEGIN] runId=143640 filesDir=...
[XDM_PROBE][P4-U3][S5] checked=31 total=31 unchecked=none
[XDM_PROBE][P4-U3][SUMMARY] S5=checked=31
[XDM_PROBE][P4-U3][END] ok=true steps=1 elapsedMs=9
```

失败形态：步骤异常 catch emit `errCode/errMessage`。S4 的 `setAppPreferredLanguage` 抛
890001（非法 tag）/401 → errMessage 观测；探针值全 ASCII 消毒（CJK 经 `?` 占位，非故障）。

## 7. 环境差异分支（重跑指引）

| 现象 | 判定 | 处置 |
|---|---|---|
| S1 任一默认值不符 | FAIL | 分流 business-code（Config 新增键默认值/init 读链回归——对照设计书 §2.1-B 全表） |
| S2 任一计数/串不符（含 thwawte） | FAIL | 分流 business-code（默认 JSON 串/解析门回归）；若历史运行已写回非默认值→先确认 restored 链完整再重装应用复测 |
| S3 任一 W≠R | FAIL | 分流 business-code（对应 setter/getter 缓存链） |
| S3 任一 restored≠基线 | FAIL | 分流 business-code（try/finally 恢复链） |
| S4 langReadback≠zh-Hans | FAIL | 分流 business-code（i18n API 调用链/异常吞没） |
| S4 langAfterReadback≠en-US | CONTINGENCY | langBefore='default' 时恢复=跟随系统，读回为系统语言（如 zh-CN）——对照 langBefore 判定，非缺陷 |
| S4 themeApply=err<code> | FAIL | 分流 business-code（ApplicationContext.setColorMode 调用面） |
| **S5 项 31 界面未变中文（S4 langReadback=zh-Hans 时）** | **CONTINGENCY（observe-both）** | `setAppPreferredLanguage('zh-Hans')` 未命中 `resources/zh_CN` 限定词——退化路径：目录改名 `zh`（语言级限定词，命中面更宽）后重验；不阻塞编码 |
| S5 unchecked 非空 | 按项号分流 | 走查项 1~31 逐项返修（项号→§5 对照表→设计书 §6），返修后重走查+单步 S5 |
| 模拟器 vs 真机 | — | 真机优先（i18n/深浅色跟随系统行为更真实）；结论按实际运行环境标注回写计划 |

## 8. 回贴

把 probe-P4-U3.log 全文（两段会话 [XDM_PROBE] 行一律不要手工删改）+ §5 走查清单勾选结果发给 AI，
由 xdm-probe-verify 核对（S5 取末次 runId）；结论（含验证环境：真机/模拟器）与既有单元同口径写回
MIGRATION_PLAN。本单元特有回写项：
①S1/S2 47 键默认读回运行时锚（thwawte 保真/15-23-3-5 计数/UA 前缀）；
②S3 写回-读回-恢复闭环（含 catParseDedup=2 去重运行时锚）；
③S4 语言系统层读写（zh-Hans 命中 zh_CN 与否=目录退化决策输入）+主题即时应用；
④S5 走查 31/31（unchecked 项号清单=返修输入）；
⑤ConfigChanged 广播面（Save 一次广播）消费延迟登记（本单元无新消费者，U5.2 ClipboardWatcher 接管）。
