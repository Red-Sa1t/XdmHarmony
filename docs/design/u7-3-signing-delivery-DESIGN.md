# U7.3 签名打包+交付文档 设计书（Phase 7 收官）

- 单元：U7.3 签名打包+交付文档（UNIT_CATALOG.md:89 Phase 7 第 3 单元，M7 交付）
- 设计日期：2026-10-11
- 目标工程：D:/git/HarmonyPC/XdmHarmony（HarmonyOS PC，targetSdk 6.1.1(24) / compatibleSdk 6.1.0(23)，bundle com.example.xdmharmony，ArkTS 严格子集）
- 对照源码：D:/git/HarmonyPC/resourses/xdm（XDM 2023，C#/.NET，GPL-2.0，只读；本单元对其仅读取 LICENSE 与既有结论，不触碰）
- 单元性质：**交付类——零业务代码、零探针、零配置改动**。全部落点为两份 Markdown（docs/delivery/DELIVERY.md 新建、README.md 新建）+ 一次 release 构建执行与产物登记。
- 前置状态：迁移本体 24/24 功能单元已全部落地（U7.1 a98e2fc 收官）；640 条单测已有两份 run-hypium 真值 verdict 全绿。

---

## 0. 事实基线（本设计书逐条实测核对，编码员可直接引用）

| # | 事实 | 证据（本会话实读/实测） |
|---|---|---|
| F1 | 签名条件已具备：signingConfigs `default`（type HarmonyOS、SHA256withECDSA、keyAlias debugKey、材料在 C:\Users\11292\.ohos\config\default_XdmHarmony_*.cer/.p7b/.p12）且 products.default 已绑定 | build-profile.json5:3-17、:19-31；PROBE-SESSION-ALL.md:76（AGC 已注册真机 UDID） |
| F2 | compatibleSdkVersion 6.1.0(23)、targetSdkVersion 6.1.1(24)——真机 MateBook Pro HAD-W24 为 API 23，装 24 被拒（code 9568297），探针会话#1 现场降级 | build-profile.json5:22-23；PROBE-SESSION-ALL.md:77-78 |
| F3 | 640 单测真值：两份 verdict.json 均 ok:true、total=640/pass=640/failure=0/error=0/ignore=0；命令为 node.exe + hvigorw.js `test --no-parallel` 经 run-hypium 包装 | D:/git/HarmonyPC/migration-runs/hypium/2026-10-10T17-58-45-814Z-*/verdict.json、2026-10-10T18-17-05-499Z-*/verdict.json（本会话实读） |
| F4 | run-hypium 门禁四条件与 --expected-tests 语义 | scripts/HYPIUM_GATE.md:21-29（实测读取）；scripts/run-hypium.cjs:56（`counts.total !== expectedTests` 即 issue） |
| F5 | `devecocli build` 默认 **debug**，必须显式 `--build-mode release`；支持 --product/--modules | `devecocli build --help` 本会话实测输出 |
| F6 | 既有 HAP 产物存在但构建模式不可证（2026-10-11 01:24 signed / 01:23 unsigned；mapping/ 无 mapping.txt 与混淆关闭一致；pack.info 实证 bundle/deviceType/apiVersion compatible 23 target 24） | entry/build/default/outputs/default/ 实测 ls + pack.info 头部实读 |
| F7 | release buildOptionSet 已存在且 obfuscation enable:false | entry/build-profile.json5:14-28 实读 |
| F8 | README.md 不存在——"更新"实为**新建**；工程根无 LICENSE/COPYING | ls 实测：`ls README.md`→No such file；LICENSE*/COPYING* 均不存在 |
| F9 | module.json5 已含 4 权限（INTERNET/KEEP_BACKGROUND_RUNNING/PREPARE_APP_TERMINATE/READ_PASTEBOARD）+ deviceTypes + backgroundModes dataTransfer，无 startupTask | entry/src/main/module.json5:7-45 grep 实测——**本单元无需改 module.json5** |
| F10 | 版本号 versionCode 1000000 / versionName 1.0.0 / vendor example | AppScope/app.json5 实读 |
| F11 | 构建产物已被 git 忽略（`**/build` 与 entry/.gitignore `/build`），HAP 天然不入 git | `.gitignore` 实读 + `git check-ignore -v` exit=0 |
| F12 | 提交史覆盖 24 单元：U0.1 0687ee1、U0.2 d686e15、U1.1 a9d98fd、U1.2 3591cd4、U2.1 b6b215d、U2.2 3c2fb22、U2.3 08cfc8a（+e720b7a/d73bee6）、U3.1 e9ee69e、U3.2 3af73ed、U4.1 2dcf823、U4.2 b02ddac+1047748、U4.3 76a6e7d、U5.1 9874c9a、U5.2 2cf4234、U0.3 cd060a3、U6.1 33e04e2+8b91992、U6.2/U6.3/U6.4/U0.4 4c02cb1、U7.1 a98e2fc；**git tag 为空** | `git log --oneline --reverse`（36 提交）与 `git tag -l`（空）实测 |
| F13 | 探针会话#1：已跑 10/14（P0-U0/P4-U3/P1-U1/P0-U2 观测全绿、P1-U2 S5 分歧、P2-U1 全绿、P2-U2 FAIL(高)、P3-U1/P3-U2 全绿、P0-U3 全绿、P4-U1 进行中）；返修清单 5 项；未跑=P4-U1 收尾/P4-U2/P5-U1/P5-U2 | docs/probe/PROBE-SESSION-ALL.md:74-101 实读 |
| F14 | 会话#2 待跑清单=会话#1 剩 4 项 + 11 份新探针手册（P0-U4、P6-U1、P6-U2、P6-U3-link-refresh、P6-U4-adaptive-{foundation,pipeline,controller}、P7-U1-dash-{foundation,pipeline,controller,dash}）= **15 项** | docs/probe/ 目录 ls 实测（PROBE-u0-4/…/u7-1-dash 共 11 份新手册 + EXPECT 同名 json） |
| F15 | P2-U2 慢滴流源零字节缺陷已返修（a39ba92），探针未重跑——"已修待复验"属实 | git log a39ba92 提交信息实测 |
| F16 | U4.2 报告将 IR-F1（完成窗单飞 medium）记为"未修"，但该状态**已过时**：实际随 1047748 闭环——代码实证为完成窗入队补弹 + 开窗失败复位 | u4-2-dialog-package-REPORT.md:114（未修快照）vs ProgressWindowDialog.ets:400-410（completedPending 入队）、:440-446（catch 复位）、:456-459（补弹）+ git log 1047748 实测 |
| F17 | U4.1 两 medium 已闭环：幽灵选中清理 + 走查项 11 文案 | Index.ets:897-902（注释"对齐 WPF AppController.cs:524-528"）实测；1047748/2dcf823 提交信息 |
| F18 | 各单元 REPORT 均有遗留节：18 份为"⑦ 遗留问题与风险"，U6.3 为"源差异与未验范围"，U6.4 为批次报告（含独立审查/冷复核行内结论） | docs/design/ 下 grep "^## " 实测 |
| F19 | GPL-2.0 许可文本：源仓库 resourses/xdm/LICENSE 为 GPL-2.0 全文；extension/LICENSE 随扩展复制入工程 | 两文件 head 实测 |
| F20 | U7.1 探针状态原话："探针 P7-U1 已生成，待人工运行回贴日志" | u7-1-dash-REPORT.md:10 实测 |

---

## 1. ①目标文件清单

### 1.1 业务/文档文件（实现顺序）

| 序 | 文件 | 新建/改动 | 职责 | 对外导出 | 依赖 |
|---|---|---|---|---|---|
| 1 | `docs/delivery/DELIVERY.md` | **新建** | 交付总结主文档（本单元核心产出）。六部分：A 迁移总结（24 单元全景表 + M1~M7 里程碑表 + GPL-2.0 许可声明）；B 降级清单（主表 9 项 + 实现级差异补充两层）；C 探针验收状态（三段：会话#1 已跑 10/14 结论表、P2-U2 已修待复验、会话#2 待跑 15 项清单）；D 已知问题（三档：已闭环 / 开放 medium / 历轮 low 一行引用）；E 交付物登记（release HAP 路径/构建模式/时间戳/大小/sha256，二进制不入 git）；F 构建与测试复现（release 命令 + run-hypium 门禁口径 + 环境约束） | 无代码导出；被 README.md 与人工验收引用 | 无（素材全部来自既有文档与本次 release 构建） |
| 2 | `README.md` | **新建**（F8：文件不存在，"更新"实为新建） | 工程入口指引。五节：项目简介与 GPL-2.0 衍生作品一句话声明（详见 DELIVERY）；环境要求（SDK 6.1.1(24)/compatibleSdk 6.1.0(23) 及原因 F2）；构建方式（devecocli，release 显式模式警示）；测试方式（run-hypium.cjs 包装口径原样 + "不得以 hvigor 退出码/BUILD SUCCESSFUL 判绿"警示）；探针体系与文档索引（PROBE-SESSION-ALL / PROBE_SPEC / docs/design 报告 / DELIVERY） | 无代码导出；面向课程验收人 | docs/delivery/DELIVERY.md（引用其详细结论，避免两文重复维护） |

### 1.2 配置文件——零改动声明（显式核对清单）

本单元**不修改任何配置文件**。逐项核对结论（编码员照此执行"验证不改"）：

| 文件 | 核对动作 | 结论 | 禁改理由 |
|---|---|---|---|
| `build-profile.json5` | 实读 :3-31 | 签名与 SDK 版本均就绪，**不改** | compatibleSdk 6.1.0(23) 是真机可装性的前提（F2），改回 24 即破坏交付；重跑 `devecocli signature generate` 会重写签名配置，**不跑**（F1：signingConfigs 已在，按单元约束"若已有 signingConfigs 则直接 build release"） |
| `entry/build-profile.json5` | 实读 :14-28 | release buildOptionSet 在位、混淆关闭，**不改** | 混淆开启需补规则文件并重新验证 native/反射面，交付收官阶段无收益只有风险 |
| `AppScope/app.json5` | 实读 | versionName 1.0.0 / versionCode 1000000 维持，**不改** | 无 bump 需求；pack.info（F6）已实证一致 |
| `entry/src/main/module.json5` | grep F9 | 权限/2in1/后台模式齐备，**不改** | 单元指令模板中"当前缺 ohos.permission.INTERNET"已过时（U0.1 0687ee1 已补） |

### 1.3 探针文件——零声明

**本单元无探针文件**（交付类单元，PROBE_SPEC 不适用；UNIT_CATALOG:104 明确 Phase 7 整机回归用正式应用而非探针页）。`entry/src/main/ets/probe/units/` 不新增不改文件。真机回归（扩展/后台/通知）由正式应用承载，归属探针会话#2 人工验收（见 §4 C 段与 §5），不在本单元自动化门禁内。

### 1.4 实现顺序与理由

```
[编码员] ① release 构建执行（命令见 §3.1）→ 取得产物时间戳/大小/sha256
        ② docs/delivery/DELIVERY.md（素材引用 §2 各表，E/F 节用 ① 的实测值回填）
        ③ README.md（引用 DELIVERY 结论；链接路径以 ② 落盘为准）
[编码员] ④ 门禁：run-hypium 640 重跑（§3.3）+ git status 核对零代码改动（§5-G）
```

先构建后写文档：DELIVERY 的交付物登记节（E）需要产物实测值，命令复现节（F）需要在干净树上验证过一次的命令面。

---

## 2. ②数据模型与表结构（DELIVERY.md 内的表逐一定义，来源已对照核对）

本单元无代码数据模型、无表结构变更。DELIVERY.md 承载的六张文档表列定义与素材来源如下（对照源码/既有文档逐一核对）：

### T1 里程碑表
列：`里程碑 | 划分（UNIT_CATALOG v2） | 达成单元 | git 提交 | 状态`。
按 UNIT_CATALOG.md:15 v2 划分填写（**不沿用提交信息里的措辞漂移**）：

| 里程碑 | 达成单元 | git 提交（F12 实测） |
|---|---|---|
| M1 真机真下载 | U1.2 | 3591cd4 |
| M2 断点续传 | U2.2 | 3c2fb22 |
| M3 队列/限速 | U3.1+U3.2 | e9ee69e、3af73ed |
| M4 完整 UI | U4.1~U4.3 | 2dcf823、1047748、76a6e7d |
| M5 核心可交付 | U5.1+U5.2 | 9874c9a、2cf4234 |
| M6 浏览器接管+HLS | U0.3+U6.1~U6.4（+U0.4 依赖解除） | cd060a3、33e04e2、4c02cb1（M6 收官功能 U7.1=a98e2fc，提交信息自称"M6 收官"系措辞漂移，表内注明） |
| M7 交付 | 本单元（U7.3） | 达成后回填 |

### T2 24 单元全景表
列：`单元 | 主题 | 单测累计 | 探针（手册/状态） | REPORT`。24 行按 UNIT_CATALOG 各 Phase 表逐行抄单元名与主题；单测累计数与探针状态从各 `docs/design/u*-REPORT.md` 头部与提交史回填；REPORT 列链接 docs/design 下对应文件。此表是"全景"的机械核对基准，不允许凭记忆填写。

### T3 降级主表（9 项，对照 MIGRATION_PLAN.md:45-55 逐条核对，不许增删改措辞主旨）
列：`# | 降级项 | 降级原因域 | 源码对应位置 | 交付现状`：

1. yt-dlp 粘贴页面链接探测（视频向导仅保留浏览器嗅探分支）——鸿蒙无该进程模型/运行时；源 YDLWrapper/YDLProcess.cs
2. 系统代理自动检测（WPAD/PAC/IE），仅保留手动代理——平台无对应检测 API
3. NTLM/Negotiate 认证——无系统凭据栈；保留 Basic 原生 + Digest 手写
4. GitHub Releases 自动更新——鸿蒙走应用市场模式
5. 下载完成后关机 / 自定义命令 / 杀毒扫描——沙箱权限模型不放开
6. 保持 PC 唤醒（SetThreadExecutionState）——无公开对应 API
7. MSIX 打包 + Chrome Native Messaging——形态不同；扩展实际走 8597 HTTP（已由 U6.x 实证）
8. TLS 证书错误放行——鸿蒙网络栈不可设；自签证书站点将失败
9. 开机自启——无 startupTask 扩展（F9 实读 module.json5 无该项，已实际落定降级）

### T4 实现级差异补充表（与 T3 分层，不混表）
列：`单元 | 差异/遗留摘要 | 等级 | 状态`。素材=各 REPORT 行为对照表的 low/medium 有意差异行 + §7 遗留节，**逐单元一行引用不复制明细**（F18 实测的节名：18 份"⑦ 遗留问题与风险"、U6.3"源差异与未验范围"、U6.4 批次报告行内结论）。典型行例：U1.2 恢复 Range 用 open-ended `bytes=N-`（有意偏离源闭区间）；U3.1 D9 DB 回声未接；U6.2 含纯 TS SHA-1 注释向量错误（low）。

### T5 探针状态表（三段，来源 PROBE-SESSION-ALL.md:74-101 + F14）
- 段 1 会话#1 已跑 10/14 结论表（列：探针 | 结果 | 要点），逐行照 PROBE-SESSION-ALL.md:84-92：P0-U0/P4-U3/P1-U1/P0-U2 观测全绿（U0.2 http 主栈定案）；P1-U2 S5 分歧（business-code 类，功能无损）；P2-U1 全绿；P2-U2 FAIL(高)（慢滴流源零字节）；P3-U1/P3-U2 全绿；P0-U3 全绿（25/25 对账）；P4-U1 进行中（A/B 段完成）。
- 段 2 已修待复验：P2-U2 缺陷已随 a39ba92 返修（HttpClient/HttpProtocol/PieceGrabber/SegmentWorker 核心返修+S5 记账收口，F15），探针未重跑；返修清单 5 项中的 1/2/3 已修（慢滴流、S5 记账、探针页徽标假象），第 4 项（U0.3 三 low）仍开放、第 5 项确认为非缺陷。
- 段 3 会话#2 待跑 15 项清单（F14）：P4-U1 收尾、P4-U2、P5-U1、P5-U2、P0-U4、P6-U1、P6-U2、P6-U3、P6-U4-adaptive-foundation、P6-U4-adaptive-pipeline、P6-U4-adaptive-controller、P7-U1-dash-foundation、P7-U1-dash-pipeline、P7-U1-dash-controller、P7-U1-dash；注明 U7.1 探针"已生成待人工回贴"（F20）。

### T6 已知问题表（三档）
- 档 1 已闭环：U4.1 两 medium（Index.ets:897-902 实证 F17）；U4.2 IR-F1 完成窗单飞（**报告"未修"快照过时**，实际随 1047748 闭环，代码实证 ProgressWindowDialog.ets:400-410/456-459，F16——此修正须在表内写明证据链）与 IR-F2；U7.1 独立复核两 medium（XML 属性先序合并、Timeline 预算门，随 a98e2fc）；P2-U2 返修（a39ba92）。
- 档 2 开放 medium：以各 REPORT §7 最终状态+提交史核对为准；本设计书实测唯一登记在案的开放 medium（IR-F1）已闭环（F16），其余如有须在编码时逐报告复核后列明，不得凭空保留也不得漏登。
- 档 3 历轮 low：逐单元一行引用 REPORT §7（u0-1、u0-2、u0-3 三 low、u1-1 两 low、u1-2 四 low、u2-1、u2-2 五 low、u2-3、u3-1 三 low+D9、u3-2、u4-3、u5-1、u5-2、u6-1 七 low、u6-2 约 ten low、u7-1 两 low），注明"明细见对应报告"。

### T7 交付物登记表
列：`产物 | 路径 | 构建模式 | 时间戳 | 大小 | sha256`。行 1=`entry-default-signed.hap`（release 重跑后的新时间戳，F6 明确旧 HAP 模式不可证、不作交付物）；行 2（如生成）=`entry-default-unsigned.hap`。注明：二进制不入 git（F11 实证已被忽略）；pack.info 关键信息（bundle com.example.xdmharmony、deviceType [phone,2in1]、apiVersion compatible 23/target 24）作为指纹一并登记。

### GPL-2.0 许可声明节（独立成节，硬性必备）
内容四要素（对照 MIGRATION_PLAN.md:203-205 §11 与 F19）：① 本工程为 XDM 2023（subhra74/xdm，GPL-2.0）的**衍生作品**（对照源码重写 + extension/ 下 chrome-extension 复用改造）；② 依 GPL-2.0 **分发本工程时必须遵循同许可证**提供对应源码；③ 课程内部教学使用不受影响；④ extension/ 目录随扩展自带 LICENSE（GPL-2.0 全文），源仓库 resourses/xdm/LICENSE 为同一许可证文本。

---

## 3. ③关键流程翻译说明（本单元无算法；流程性"算法"=可复现命令面）

本单元不引入任何纯函数、分段/偏移/限速数学或状态机（交付类）。既有数学与状态机已在 U2.1~U2.3/U3.2/U6.4/U7.1 各设计书与保真度矩阵中沉淀，640 条 Hypium 单测是它们的回归真值（F3）。本节只翻译三条流程，编码员必须照原样落进 DELIVERY.md F 节与 README.md：

### 3.1 release 构建（复现命令面，F5/F1 实测）

```powershell
cd D:\git\HarmonyPC\XdmHarmony
# 前提：signingConfigs 已就绪（build-profile.json5:3-17），勿重跑 devecocli signature generate
devecocli build --product default --modules entry --build-mode release
# 产物：entry/build/default/outputs/default/entry-default-signed.hap（以新时间戳为准）
# 指纹登记：文件大小 + sha256sum + pack.info 关键字段
```

要点：
- `--build-mode release` **必须显式**——devecocli 默认 debug（F5 --help 实测）；旧 HAP（2026-10-11 01:24）构建模式不可证（F6），不充当交付物。
- 产物核对三件：`entry-default-signed.hap` 存在（非仅 unsigned）、mapping/ 无 mapping.txt（与混淆关闭一致，F7）、pack.info 的 apiVersion compatible=23/target=24（F2 指纹）。
- 拆分预案（补充约束④）：若签名材料路径失效或设备环境不可用——DELIVERY 照常交付，交付物节改为登记上述命令清单+预期产物路径，并注明"release 构建留待环境可用时执行"；文档先行不阻塞。

### 3.2 真机安装冒烟（可选，环境可用时执行）

```powershell
"D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" app install entry/build/default/outputs/default/entry-default-signed.hap
```

真机系统为 API 23（F2），装包成功即 compatibleSdk 钉值的最终验证。失败时记录错误码，不得通过改 compatibleSdk "修复"。

### 3.3 单测真值门禁（F3/F4 口径，640 条全绿保持）

```powershell
cd D:\git\HarmonyPC\XdmHarmony
node scripts/run-hypium.cjs --expected-tests 640 --output ../migration-runs/hypium -- 'D:/Tools/DevEco Studio/tools/node/node.exe' 'D:/Tools/DevEco Studio/tools/hvigor/bin/hvigorw.js' test --no-parallel
```

- 通过判据=exit 0 且 verdict.json `ok:true`、`counts.total=640/pass=640/failure=0/error=0`（--expected-tests 640 钉注册防漏，F4 run-hypium.cjs:56）。
- **不得以 hvigor 退出码或 BUILD SUCCESSFUL 判绿**（HYPIUM_GATE.md:1-3 实测曾有假绿吞 5 例）。
- 本单元改动仅 docs+README，理论零代码影响；但 release 构建本身过一次全量编译，门禁照跑并归档 verdict。

---

## 4. ④与源码的有意差异清单

本单元自身不产生新的源码行为差异；其交付文档 DELIVERY.md 正是全部既有差异的**正式汇总点**。分层如下：

### 4.1 范围级降级（MIGRATION_PLAN §3 既有九项，T3 表承载）
yt-dlp 探测、WPAD/PAC 系统代理、NTLM/Negotiate、GitHub 自动更新、完成后关机/命令/杀毒、SetThreadExecutionState、MSIX+Native Messaging、TLS 放行、开机自启——合计约 15% 功能面，每项原因域见 §2 T3。

### 4.2 实现级有意差异（T4 表承载，各 REPORT 已登记）
代表性条目：U1.2 恢复 Range open-ended `bytes=N-`（源为闭区间，有意偏离）；U1.2 SessionExpired(9) 未复刻；U3.1 D9 DB 回声未接；U4.2 完成窗串行补弹（源为逐下载堆叠多窗——ProgressWindowDialog.ets:400 注释自称"有意差异 D 系"）；U6.x 嗅探/桥实现差异明细见对应报告对照表。

### 4.3 环境适配差异（写入 DELIVERY 环境章节）
compatibleSdk 6.1.0(23)（F2）；签名材料落 build-profile 而非 AGC 云端分发（F1）；混淆关闭（F7）。

### 4.4 本单元自身的流程决策（写入 DELIVERY 附录或 openQuestion）
- 不打 git tag：UNIT_CATALOG.md:19 规定 tag 是人工 Phase 验收动作，且探针会话#2（15 项）未过，DELIVERY 登记"tag 待人工补打"。
- 工程根不补 LICENSE 文件（F8 实测不存在）：ask 硬性要求是 DELIVERY.md 内含声明；补根 LICENSE 使分发链自洽属加分项，列为 openQuestion 待人工拍板，编码员不得擅自新增。
- HAP 二进制不入 git（F11），仅登记路径+指纹。
- README 为新建（F8），"更新"表述在交付说明中纠正。

---

## 5. ⑤对应单元验收的测试要点

UNIT_CATALOG:89 验收要点（签名 HAP 可安装；交付物齐）+ 本 ask 三条验收，逐条落为可勾选检查：

| # | 检查项 | 判据 | 方式 |
|---|---|---|---|
| A | DELIVERY 六部分齐全 | §2 T1~T7 + GPL 声明节逐节在位；24 单元全景表行数=24 | 人工走查文档 |
| B | GPL-2.0 声明四要素 | 衍生作品定性/分发义务/源仓库署名/extension 复用说明（§2 末） | 文档走查 |
| C | release 流程可复现 | §3.1 命令原样执行→新时间戳 signed HAP；T7 登记完整（模式/时间戳/大小/sha256） | 实际执行 |
| D | 640 单测全绿保持 | §3.3 命令 exit 0 且 verdict.json ok:true、640/640 | 实际执行（**唯一计分口径**） |
| E | README 三指引可照做 | 构建/测试命令从 README 复制即可执行；探针指引链接有效 | 文档走查+抽样执行 |
| F | 零代码改动 | `git status`/`git diff --stat` 仅含 `docs/delivery/` 与 `README.md` | git 核对 |
| G | 配置零改动 | diff 不含 module.json5/两个 build-profile/AppScope | git 核对 |
| H | 降级表与计划一致 | T3 九项与 MIGRATION_PLAN.md:45-55 逐条对齐 | 文档比对 |

**纯逻辑算法拆分与 Hypium 用例清单：本单元无新增纯函数，零新增用例**。回归基线=既有 640 条（F3 两份 verdict 实证），验收动作是重跑而非补写。

---

## 6. ⑥探针步骤设计

无（交付类单元，§1.3 已声明）。与探针相关的唯一动作是 DELIVERY.md 探针状态节的**登记**（T5 三段），素材取自 PROBE-SESSION-ALL.md 与 docs/probe/ 现存手册清单，不涉及 ProbeKit/探针页改动。

---

## 7. openQuestions（移交人工拍板，编码员不得自行决定）

1. **git tag 补打时机**：建议不补打（UNIT_CATALOG v2:19 人工动作 + 会话#2 未过），DELIVERY 登记"待人工补打"。
2. **工程根 GPL-2.0 LICENSE 文件**：建议补全文使分发链自洽（F8/F19），是否加由人工拍板。
3. **release HAP 交付形态**：建议只登记路径/模式/时间戳/大小/sha256，不拷贝二进制入 git；若课程要求随交付物提交 HAP 文件，请人工指定落点。

## 8. 关键约束（编码员红线）

1. compatibleSdk 6.1.0(23) 不得动（F2）；不得重跑 `devecocli signature generate`（F1）。
2. release 必须 `--build-mode release` 显式（F5）；旧 HAP 不当交付物（F6），登记用新时间戳。
3. 单测结论只用 run-hypium 口径（§3.3），禁以 hvigor 退出码/BUILD SUCCESSFUL 判绿。
4. git diff 仅允许 docs/delivery/ 与 README.md（§5-F/G）；不新增探针、不改配置、不动 resourses/。
5. 已知问题表三层分开（§2 T6）：IR-F1 按"已闭环"写并注明报告快照过时的证据链（F16），不得照抄 U4.2 报告的过时"未修"。
