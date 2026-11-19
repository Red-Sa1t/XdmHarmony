# U4.3 设置页全配置键 + i18n + 主题 · 单元迁移报告

> 单元：U4.3（Phase 4，UNIT_CATALOG「U4.3 设置页全配置键+i18n+主题」行）。任务书单元字段为空，归属经 XdmHarmony git 台账提交 bbc29af（「U4.3 启动」）与 UNIT_CATALOG U4.3 行双重确认。
> 配套文档：[设计书](./u4-3-settings-i18n-theme-DESIGN.md)、[探针手册](../probe/PROBE-u4-3-settings-i18n-theme.md)、[预期表](../probe/EXPECT-u4-3-settings-i18n-theme.json)、[MIGRATION_PLAN](../MIGRATION_PLAN.md)。
> 本报告证据来源：本报告员会话逐一执行的 Read/grep/sed/git 命令（下文逐处标注）；hvigor/codelinter 门禁由工作流脚本统一执行（本报告员未重跑，见 §5）。

---

## ① 单元范围与验收要点

**范围**（UNIT_CATALOG U4.3 行）：Config 44 键落地 preferences（裁剪降级项）；string.json base+zh_CN+en_US（对照 `Lang/*.txt`）；深浅色；五页设置窗（监控/常规/网络/凭据/高级）按 WPF 源逐控件对照。

**验收要点**（UNIT_CATALOG + 设计书 §5）：
1. [A] hvigor 编译门禁零 error 零新 warning；ArkTS 严格子集由 hvigor 编译期强制。
2. [A] 冻结面：Config 既有 15 键 setter/getter/`setSpeedLimit`/`setSchedule`/监听器注册表零改动；Index 既有事件面零破坏（本会话 git diff 核实，见 §5）。
3. [A] Hypium 单测 SettingParse 22 条（本会话核实 `it(` 用例恰 22 个，用例名与设计书 §7 一一对应）。
4. [P] 语言切换即时生效；深浅色；设置项读写闭环——探针 P4-U3（8 步骤）+ S5 人工走查 31 项，待人工运行回贴日志。
5. [H] Phase 级走查：对照 XDM 2023 设置五窗逐控件核对（降级控件确认隐藏）。

**产出规模**（本会话逐一核实）：业务新 9 文件 + 改 4（Config/Index/EntryAbility/List.test）+ 资源新 2 目录改 1 + 探针新 1 改 1 + 单测新 1 + 文档新 3（设计书/PROBE/EXPECT）；`module.json5`、`main_pages.json` 零改动（设计书注记 9，差异 D11）。Config 落库 47 键（设计书 §2.1 名单 47/47 命中，`grep -oE "'键名'" Config.ets | sort -u | wc -l` = 47）；三资源目录 string.json 各 **191 键**（`grep -c '"name"'`，三文件对齐）。

---

## ② 研究结论摘要（关键源码行为 → ArkTS 对应表）

研究阶段 10 组事实（研究结论 JSON）全部落入设计书并实现，关键对应关系如下（源码行号为研究/审查会话核实，抽查项本会话已复核）：

| # | 源码行为（resourses/xdm，只读） | ArkTS 对应 | 落点证据 |
|---|---|---|---|
| 1 | Config 44 属性键逐键默认值（Config.cs:44-155；标量/枚举/集合/5 预定义分类） | 47 键 = 源 38 持久化字段 1:1 + schedule 4 + Proxy 拆 5 平铺；"set 即持久化"语义 | Config.ets 47 键名名单核实；设计书 §2.1 |
| 2 | 三默认数组（视频 15/文件 23/屏蔽主机 3，`thwawte` 源拼写）+ 5 预定义分类（Config.cs:56-77/:157-226） | DEFAULT_* 常量 + categoriesJson JSON 单键落库；分类扩展名带点大写、列表键不带点 | 探针 S2 断言 `videoExts=15 fileExts=23 blockedHosts=3 categories=5` |
| 3 | 五页 OK=逐页 UpdateConfig→SaveConfig→BroadcastConfigChange("ConfigChanged")→Close；Cancel 零写入（SettingsWindow.xaml.cs:68-83） | SettingsSession.updateAll() 按页序回写 → 主题即时应用 → `broadcastConfigChange()`（已改 public）→ pop；Cancel 直接 pop | 设计书 §3.4；Settings.ets |
| 4 | 下拉值域：并发 1..50、超时 1..300s、分段 1..64、重试 1..100、最小体积 9 档 KB（GeneralSettingsView.xaml.cs:34 等） | 值域常量进 SettingParse.ets（RANGE_*、MIN_VIDEO_SIZE_CHOICES 9 档） | SettingParse.test.ets 用例 22（clampToRange_bounds 等） |
| 5 | 限速输入三件套：仅数字键入/失焦重置 "0"/保存 TryParse 失败不写 Config 保留旧值（NetworkSettingsView.xaml.cs:79-115/:52-55） | tryParseInt（Int32.TryParse 同貌）+ onChange 过滤 + onBlur 重置 + updateConfig 解析失败跳写 | 设计书 §3.3 三消费点分立；NetworkSettingsTab.ets |
| 6 | 分类/凭据/扩展列表解析：逗号 split→trim→去空，分类另去 `\r\n`+HashSet 去重（GeneralSettingsView.xaml.cs:86-87、CategoryEditWindow.xaml.cs、PasswordWindow.xaml.cs） | parseCategoryTypes（去重保序）/parseExtensionList（不去重）/joinForEdit 纯函数层，可单测 | SettingParse.ets；单测用例 11-20 锁定去重差异 |
| 7 | ProxyInfo{Type,Host,Port:int,User,Pass}，仅 Custom 档启用四输入，保存无条件整块写回（ProxyInfo.cs:14-22、NetworkSettingsView.xaml.cs:40-77） | 平铺 5 键 + getProxyInfo()/setProxyInfo() 组装；Select 三档仅 index==2 启用；端口解析失败→0 | Config.ets；NetworkSettingsTab.ets |
| 8 | 语言=TextResource 静态字典 English 兜底覆盖，改语言需重启（TextResource.cs:11-48、LanguageSettingsWindow.xaml.cs:24-85） | `i18n.System.setAppPreferredLanguage(tag)` 即时生效（D2）+ EntryAbility.onCreate 语言重放 | LanguageDialog.ets:60；EntryAbility.ets:71（本会话核实） |
| 9 | 主题仅一键 AllowSystemDarkTheme，启动期一次性（App.xaml.cs:122-134） | true→COLOR_MODE_NOT_SET / false→LIGHT；setColorMode 仅运行期有效→EntryAbility 冷启重放 | EntryAbility.ets:58-63（本会话核实：`allowSystemDarkTheme?NOT_SET:LIGHT`） |
| 10 | ISettingsPage 契约仅 PopulateUI()/UpdateConfig() 两方法；页序 0-4 默认常规页(1)（SettingsWindow.xaml.cs:27-49） | 五 Tab 各暴露 populateUI()/updateConfig()；`pushPathByName('settings', 1/0)`；Settings 走 NavDestination | Index.ets:1010-1037（三处接线）、:1223 settingsNavDestination（本会话核实） |

**消费点链条**：ConfigChanged 广播链本单元只建不消费——ClipboardMonitor 启停消费归 U5.2、进度窗限速文案消费已在 U4.2 挂 setSpeedLimit 面（研究结论事实 3）。

---

## ③ 设计决策与有意差异（引用 MIGRATION_PLAN 决策条款）

设计书 §0 拍板注记 11 条 + §4 差异清单 **D1~D14**（本会话核实 D13/D14 已入表，设计书 :238-239）。与计划条款的对应：

| 差异 | 内容 | 计划/平台依据 |
|---|---|---|
| D1 | language 键存 i18n tag（'en-US' 默认/'zh-Hans'/'default'），非源 index.txt 显示名；语言菜单 25→三选项 | 决策 11（UI 按鸿蒙机制重设计）；资源面仅中英 |
| D2 | 语言/主题即时生效（源需重启 MSG_LANG2 / 主题仅启动期）；`settings_dark_theme` 值去掉 "(Require app restart)" | UNIT_CATALOG U4.3 验收「语言切换即时生效」 |
| D3 | fallbackUserAgent 持久化——源 ConfigIO 序列化/反序列化键表均无此键（源缺陷：输入重启即失） | 修复数据丢失缺口；决策 10 存储等价延伸 |
| D4 | notificationTimeOut 默认 0（Config.cs:44 实例默认；:42 的 30000 为全仓无消费死常量，grep 核实唯一出现点=ConfigIO 序列化）；键落库无 UI | 键照源 38 字段全落 |
| D5 | categories/userCredentials 以 JSON 字符串单键落 preferences；分类目录存 defaultFolderName 尾段，Browse 占位待 U5.2 picker | 决策 10（配置存 preferences；源即整块序列化无查询需求） |
| D6 | Proxy 平铺 5 键（源单可空字段，null 语义由 type=0 承载）；本单元只落键+UI 不接 HTTP 栈 | 研究建议采纳；消费方 U6.x |
| D7 | UI 隐藏：监控页浏览器引导区、网络页 ND_SYSTEM_PROXY、高级页关机/唤醒/命令/杀毒/自启五组；RunOnLogon 不落键（源 ConfigIO 亦注释禁用）；对应 Config 键照源默认保留 | 计划 §3 降级清单 2/5/6/9 + 决策 11「设置页覆盖全部配置键（裁剪降级项）」 |
| D8 | zh_CN 全量覆盖（不保留源 215/260 缺键英文回退混合态）；en_US 目录显式建立 | 计划 §5「resources base+zh_CN+en_US」三目录结构 |
| D9 | Helpers.RunGC() 不移植 | 无对应 API 无实义 |
| D10 | 分类新增 Name 用 `util.generateRandomUUID()` 替代 `Guid.NewGuid().ToString()` | 平台对应物 |
| D11 | module.json5 / main_pages.json 零改动 | 本单元无新能力面（INTERNET/2in1 已有）；Settings 走 NavDestination |
| D12 | SETTINGS_ATUO_CAT 源拼写纠正为 settings_auto_cat | D8 拼写纠正先例（DefaltDownloadSpeed→defaultDownloadSpeed） |
| D13 | 删除交互按列表选中态实现（源 SelectedIndex 对应物） | ArkUI List 选中模型 |
| D14 | 高级页 UA Reset 钮即时写 Config（R2-F1 修复）：源 BtnUserAgentReset_Click 即写 `Config.Instance.FallbackUserAgent`；鸿蒙版同步回填 state+写 Config，规避源「Reset 后 OK 用文本框旧值覆盖」怪癖；细微差=鸿蒙 set 即持久化 vs 源仅写内存 | 源可观测行为对齐 + Config「set 即持久化」既有语义（D3 同族） |

---

## ④ 审查问题处置表（覆盖全部轮次）

对照审查两轮（round 2 approved=false 列 5 项；round 3 approved=true 无 findings），独立复核一轮（6 findings，acceptable=true）。**处置状态为本报告员会话逐项对照当前代码核实，非转录审查声明。**

| 编号 | 来源 | 严重度 | 问题摘要 | 处置 | 证据（本会话核实） |
|---|---|---|---|---|---|
| R2-F1 | 对照审查 round 2 | medium | 高级页 UA Reset 只回填文本框，源 `BtnUserAgentReset_Click` 即写 Config.Instance；Reset→Cancel→重开显示旧值 | **已修复** | AdvancedSettingsTab.ets:73-76 `handleResetUserAgent` 同时回填 state 并 `setFallbackUserAgent(DEFAULT_FALLBACK_USER_AGENT)`；源行为本会话 sed 复核（`Config.Instance.FallbackUserAgent = Config.DefaultFallbackUserAgent`，AdvancedSettingsView.xaml.cs）；差异登记设计书 §4-D14（:239） |
| R2-F2 | round 2（复核 F2 重报） | low | 编辑分类保留 old.isPredefined；源 new Category 未赋值→struct 缺省恒 false（序列化面差异，无 UI/逻辑消费点，不可观察） | **未处置**（代码未改、§4 未登记） | GeneralSettingsTab.ets:293-294 `new CategoryDef(old.name, categoryName, types, folder, old.isPredefined)`；源 GeneralSettingsView.xaml.cs:103-110 对象初始化器无 IsPredefined + Category.cs `public struct`（本会话 sed 复核）；设计书 §4 无对应行 |
| R2-F3 | round 2（复核 F3 重报） | low | 设计书 §6 写 autoStart=true，实现为 autoStart=false（探针页点「运行全部」触发），EXPECT/手册已按 false 拍板 | **未处置**（文档勘误未做） | 设计书 :264 仍写「会话模型：autoStart=true」；ProbeSettings.ets:3-4 头注与 :437 `autoStart: false`；EXPECT 表 sessions 段已按「主会话运行全部 + S5 单步」双会话模型拍板（本会话读 JSON 核实） |
| R2-F4 | round 2（复核 F4 重报） | low | indexOfMinVideoSize 注释称「钳到最近存在档」，实现 clampToRange 钳索引边界（1025→索引 8=32768 档，最近应为 1024 档）；当前存储值恒为 9 档之一，不可达 | **未处置**（注释未改） | MonitoringSettingsTab.ets:75-83（本会话复读，注释与实现不符原样保留） |
| R2-F5 | round 2（复核 F5 收敛） | low | 「跟随系统」档 OK（setAppPreferredLanguage('default')）运行期行为未实证，若抛 BusinessError 则静默卡窗；探针未覆盖 | **部分收敛**：'default' 参数合法性已由独立复核经官方文档证实（清除偏好语言→跟随系统，合法不抛错），代码无需改；**但 D2 平台语义「清除偏好语言将在应用重新启动后生效」未在 §4 登记**，S5 清单第 31 项亦未注记该档点 OK 后界面不变的预期 | LanguageDialog.ets:53-71 三档同走 setAppPreferredLanguage，catch BusinessError 不写键不关窗（本会话复读核实）；设计书 §4-D2（:227）无该平台语义登记 |
| R3 | round 3 | — | 复审结论 **approved=true，无 findings** | 通过 | 见审查全史。注意：round 3 未再列出 R2-F2~F5（视为不阻塞），但独立复核换人复查仍全部点名，其中 R2-F3/F5 的登记义务截至本报告仍未履行——两轮结论之间的该张力如实记录 |
| F1 | 独立复核 | **medium** | 常规页分类列表 ForEach 键=cat.name，编辑分类同键换对象→ArkUI ForEach 键值不变不重建组件，**会话内编辑/恢复默认后列表行不刷新**；源为 ObservableCollection 即时刷新。持久化正确（Save 落库、重开页面回显正确），属会话内可见行为偏差 | **未修复**（遗留） | GeneralSettingsTab.ets:503 键生成器 `(cat: CategoryDef) => cat.name`；编辑分支 :290-298 同 name 换对象（本会话逐行核实）。修复方向（复核给出）：键生成器纳入可变内容（如 name+'/'+displayName+'/'+fileExtensions.length，同文件 CredentialSettingsTab.ets:252-253 用 host+user+index 同思路） |
| F6 | 独立复核 | low | 探针 S1 `uaPrefix=ua.slice(0,12)`——'Mozilla/5.0' 恰 11 字符，第 12 字符是空格，发射值尾带空格；EXPECT 期望 'Mozilla/5.0'。宽匹配 verify 无碍，严格单空切分 verify 会多出空 token | **未修复**（遗留） | ProbeSettings.ets:143 `new KeyValue('uaPrefix', ua.slice(0, 12))`（本会话核实）。修复方向：`slice(0, 11)` 或切片后 trim |

**矛盾声明**（材料之间，以代码与日志为准）：实现文件清单声称「本轮仅两处改动（AdvancedSettingsTab + 设计书 D14）」，与 git 工作区一致（见 §5 冻结面）；但设计书 §6 勘误（R2-F3）虽被两轮点名且实现文件清单未声称已完成，**设计书当前状态确未勘误**——报告以门禁与逐行核实为准，登记为遗留。

---

## ⑤ 验证情况

| 验证层 | 结论 | 执行者与证据 |
|---|---|---|
| **hvigor 全量编译门禁**（`devecocli build --modules entry`） | **通过**（最终状态） | 工作流脚本统一执行（材料门禁结论）。本报告员会话未重跑，不重复声明 |
| **codelinter 辅助检查** | exit 0；Issues 19 = Errors 0 / Warnings 17 / Suggestions 2（Files checked 5）。建议级含 `hp-arkui-set-cache-count-for-lazyforeach-grid`（Index.ets:1191，LazyForEach cachedCount 提示，非缺陷） | 工作流脚本统一执行（材料门禁结论）。codelinter 不含 ArkTS 语法规则——**ArkTS 严格子集由 hvigor 编译期强制**（计划 §8 验证矩阵），本单元全部 .ets 通过该编译即合规 |
| **对照审查** | round 2 approved=false（5 findings：F1 medium + 4 low）→ 修复 F1 → round 3 approved=true | 审查全史（材料）；F1 修复本会话代码核实（§4 表） |
| **独立复核** | acceptable=true，6 findings（F1 medium + 5 low）；复核员声明：五页 UpdateConfig 与源逐行同构、Config 47 键读写/解析门、EntryAbility 调序与三值重放、'default' 参数合法性均已核实；复核员未执行 hvigor 构建（构建由脚本统一跑过，仅读码+grep/python 核对） | 独立复核结论（材料）；F1/F6 未修复状态本会话代码核实（§4 表） |
| **冻结面**（本会话实证） | `git status`：修改仅 7 文件（Config/EntryAbility/Index/ProbeIndex/base string.json/List.test/U4.2 报告文档），与设计书 §1 文件清单一致；`Config.ets` 47 键名单全命中且既有 15 键在列 | 本会话执行 `git status --short` 与 grep 名单核对 |
| **Hypium 单测**（`hvigorw test`） | SettingParse.test.ets 22 条用例存在（本会话 grep `it('` 核实 22 个，名称与设计书 §7 对应）；**用例执行结果未在门禁材料中给出，未验证** | 本会话 grep；执行结果缺失如实声明 |

---

## ⑥ 运行时验证待办（探针）

**本单元有探针 P4-U3**，已生成未运行：

- 手册：`docs/probe/PROBE-u4-3-settings-i18n-theme.md`（运行指引 + S5 人工走查清单 31 项全文）。
- 预期表：`docs/probe/EXPECT-u4-3-settings-i18n-theme.json`（8 步骤：BEGIN + S1~S5 + SUMMARY + END）。
- 会话模型（以 EXPECT/实现为准）：**autoStart=false**——探针页点「运行全部」自动跑 S1→S4（S5 占位发射），恰 8 行；回探针页勾选 31 项清单后单步 S5（验收锚=末次 runId），恰 4 行。
- 步骤概要：S1 标量键默认读回（47 键可观测子集，含 `uaPrefix`、`thwawte` 保真）/ S2 集合键计数（15/23/3/5）/ S3 写回-读回-finally 恢复闭环 / S4 语言+主题应用观测（`setAppPreferredLanguage('zh-Hans')` 读回 + setColorMode）/ S5 人工走查 31 项。
- **环境敏感项**：zh-Hans ↔ zh_CN 目录命中与否按 EXPECT observe-both 判定（界面变中文=命中；仍英文=未命中走 zh 目录退化，判 CONTINGENCY 不判 FAIL）。另注意 R2-F5 结论：「跟随系统」档清除偏好语言为**重启生效**（平台语义），S5 第 31 项如只测中文档不受影响。
- 日志回贴后用 `xdm-probe-verify` 工作流逐步骤核对（PROBE_SPEC 规范：`[XDM_PROBE][P4-U3][<步骤>] key=value`，hilog domain 0xD001、tag XDM_PROBE）。
- 按 UNIT_CATALOG 探针节奏，P4-U3 可与 P4-U1/U2 攒批在 Phase 4 末一次运行。

---

## ⑦ 遗留问题与风险

1. **【medium·遗留】常规页分类列表会话内不刷新**（复核 F1，未修复）：ForEach 键=cat.name（GeneralSettingsTab.ets:503），编辑分类同键换对象→列表行不重建。恰落在 S5 走查 ⑭~⑲ 操作区，持久化正确使「Save 重开回显」掩盖症状——**验收者如在模拟器上于同一页面会话内编辑分类，会看到「改了没反应」**，属可解释偏差非数据错误。修复为一行级（键生成器纳入可变内容），建议尽快收口。
2. **【low·遗留】两处登记义务未履行**：R2-F3（设计书 §6 autoStart=true 勘误，:264）与 R2-F5（D2 补登记「跟随系统档重启生效」平台语义）。文档与实现不一致会被验收对照时误读。
3. **【low·遗留】注释与实现语义不符**（R2-F4，MonitoringSettingsTab.ets:75-83）与**探针 uaPrefix 尾空格**（复核 F6，ProbeSettings.ets:143）。前者不可达、后者宽匹配 verify 无碍，均为一行级收口项。
4. **【登记性差异】**R2-F2：编辑分类保留 isPredefined 位（源 struct 缺省恒 false）——仅序列化面、全仓无消费点，不可观察；待 §4 登记保真取舍即可，无需改码。
5. **【环境风险】**zh-Hans ↔ zh_CN 限定词命中未实证（探针 S4 只证 setAppPreferredLanguage 系统层读回），若未命中需目录改名 `zh` 后重验（设计书注记 5 预留退化路径，不阻塞）。
6. **【验证缺口】**`hvigorw test` 单测执行结果与探针运行日志均缺位——前者待脚本/人工补跑，后者待 §6 运行后回贴。二者未完成前，本单元的 [A] 单测面与 [P] 运行时面**均不能签收为已验**。

---

## ⑧ 对下个单元的建议

1. **收口 U4.3 遗留四小项**（可并入 U5.1 首轮改动）：复核 F1 键生成器一行修复、设计书 §6 勘误、D2 补登记、R2-F4 注释勘误 + 复核 F6 `slice(0,11)`。全部为低风险改动，避免 Phase 4 走查时带病过验收。
2. **U5.1（后台长时任务+通知）必须动 module.json5**：补 `ohos.permission.KEEP_BACKGROUND_RUNNING` 与 DATA_TRANSFER bgMode——与 U4.3 的 D11「零改动」相反，配置文件改动需作为显式文件列入设计 files 清单（计划 §9 与任务书配置条款）。
3. **ConfigChanged 广播链已就绪**：`broadcastConfigChange()` 已 public、监听器注册表冻结面未动——U5.2 ClipboardWatcher 实现 `MonitorClipboard` 启停消费时直接注册监听即可，无需改 Config。
4. **探针攒批**：P4-U3 与 P4-U1/U2 一并在 Phase 4 末人工运行回贴（模拟器优先 PC 形态，2in1 自由窗口下核对设置页 Tabs 形态）。
5. **语言键三值语义**（'en-US'/'zh-Hans'/'default'）在后续涉及文案的单元中保持：EntryAbility 冷启重放已统一三值调用，新页面文案键继续走 `$r('app.string.*')` 即自动随语言。

---

## ⑨ 提交与验收说明

**代码未做 git 提交**：U4.3 全部工作位于工作区（本会话 `git status` 实证：7 个修改文件 + 12 个新文件/目录未跟踪；最新提交 bbc29af 为「U4.3 启动」台账）。待人工验收通过后由人执行单元粒度提交并按 Phase 打 tag（`phase-4`，计划 §9/§10：AI 每单元完成即 git 提交、人工验收在 Phase 级）。

---

*报告员：迁移报告员（AI）。生成于 2026-10-01。证据核实命令：Read（设计书/实现 8 文件/EXPECT）、grep（键数/用例数/接线/重放/探针注册）、sed（源码锚 3 处，只读 resourses/xdm 未改动任何源文件）、git log/status。*
