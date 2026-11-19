# 探针运行手册：P0-U0 环境自检（U0.1 工程基座 + 探针基建）

> 工程根：`D:\git\HarmonyPC\XdmHarmony` ｜ bundle：`com.neuohos.xdm` ｜ 探针单元 ID：`P0-U0`
> 探针页：`probe/ProbeIndex`（探针首页）→ 卡片「环境自检（P0-U0）」→ 进入即自动运行 S1~S5
> hdc 未入 PATH，用全路径：
> `set "HDC=D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"`（本会话已核实该文件存在）
> 机器可读预期表：`docs/probe/EXPECT-u0-1-foundation-probe-infra.json`（与本手册 §4 步骤表一一对应）

## 0. 命令口径修订说明（必读）

PROBE_SPEC v1 §3 模板 §2 的 `devecocli run --module entry --ability ProbeAbility` **已废弃**：本工程不注册独立 ProbeAbility（设计书 `docs/design/u0-1-foundation-probe-infra-DESIGN.md` §0 拍板，探针走单一 EntryAbility + want 参数路由；`devecocli run` 无法携带 want 参数）。本手册一律使用修订命令：

```
hdc shell "aa start -b com.neuohos.xdm -a EntryAbility --ps page probe"
```

`--ps page probe` 即 want 参数 `page=probe`，由 `EntryAbility.ets` 的 `isProbeRoute` 解析（`params['page']` 经 `typeof === 'string'` 窄化后等于 `'probe'`）。主流程须在 U0.1 验收后同步修订 PROBE_SPEC.md:19/:91 与 §3 模板 §2。

## 1. 一次性准备

```bat
:: 真机（推荐验证环境）：真机拒绝未签名 HAP，首次必须做——
devecocli auth login                                :: 华为账号登录
:: USB 连接真机并开启开发者模式/USB 调试后：
devecocli signature generate --product default      :: 注册设备+生成签名材料，自动写入 build-profile.json5

:: 模拟器（兜底/PC 形态验证）：推包不需要签名
devecocli emulator list                             :: 确认实例（PROBE_SPEC 记录本机有 "Pura 90"，以实际输出为准）
devecocli emulator start "Pura 90"
```

## 2. 运行探针

```bat
cd /d D:\git\HarmonyPC\XdmHarmony
devecocli device list                               :: 记 serial；多设备时后续 hdc/aa 命令需 -t <serial>
devecocli run --module entry                        :: 构建+安装+拉起（默认落 pages/Index，属正常回归路径）
:: AI 已构建过时：devecocli run --module entry --skip-build

:: 路由到探针首页（冷启动直进；应用在后台时经 onNewWant 切页）：
%HDC% shell "aa start -b com.neuohos.xdm -a EntryAbility --ps page probe"
```

页面操作（唯一人工动作）：在探针首页点击卡片 **「P0-U0 环境自检（P0-U0）」** → 进入后自动运行 S1~S5（无其他人工步骤）。探针完成后页内可见 8 行标记回显；可点「复制日志」粘贴到备忘录核对（按钮变为「已复制」）。

## 3. 抓取标记（探针跑完后）

```bat
%HDC% shell "hilog -x | grep XDM_PROBE" > probe-P0-U0.log
```

- 兜底（hilog 环形缓冲被冲掉时；路径取 BEGIN 行 `filesDir=` 的值）：
  ```bat
  %HDC% shell "cat <filesDir>/probe-latest.txt"
  ```
- 写盘自检产物确认（S5 产生，应存在且内容为 `<runId> P0-U0 selftest`）：
  ```bat
  %HDC% shell "cat <filesDir>/probe-selftest.txt"
  ```
- 探针闪退排查：`devecocli log --crash`
- 回贴原文：hilog 行自带时间戳/进程/域标签前缀列，`[XDM_PROBE]` 行请整行保留，**不要手工截改**；verify 解析时提取消息列并按 `^\[XDM_PROBE\]\[([A-Z0-9-]+)\]\[([A-Za-z0-9-]+)\]\s(.+)$` 判定，未配对/残缺行会记 FORMAT-ERROR。

## 4. 预期标记序列（共 8 行：BEGIN + S1~S5 + SUMMARY + END）

> 以下值均为模拟器（2-in1，API 24 镜像）下的**典型观测示例，非期望断言**；`<...>` 为按设备变化的占位。判定要点与 EXPECT JSON 的 `note` 一一对应。

| 行序 | 步骤 | 示例标记行 | 判定要点 |
|---|---|---|---|
| 1 | BEGIN | `[XDM_PROBE][P0-U0][BEGIN] runId=142533 filesDir=/data/app/el2/100/base/com.neuohos.xdm/haps/entry/files` | runId 为 6 位 HHmmss；filesDir 与兜底文件路径一致；BEGIN/END 配对（多次运行取最后 runId） |
| 2 | S1 设备形态 | `[XDM_PROBE][P0-U0][S1] deviceType=2in1 osFullName=HarmonyOS-6.1.1` | deviceType 属合法形态枚举（模拟器预期 2in1）；osFullName 非空，白名单外字符被消毒为 `?` |
| 3 | S2 API 版本 | `[XDM_PROBE][P0-U0][S2] sdkApiVersion=24 firstApiVersion=<n>` | sdkApiVersion 本模拟器镜像判 24（真机镜像更新可 >24，记实际值）；firstApiVersion 只判存在且为正整数 |
| 4 | S3 产品系列 | `[XDM_PROBE][P0-U0][S3] marketName=HarmonyOS PC` | marketName 非空且可含空格（空格在值白名单内）；为空记 UNVERIFIED 观测 |
| 5 | S4 应用包信息 | `[XDM_PROBE][P0-U0][S4] bundleName=com.neuohos.xdm versionName=1.0.0 versionCode=1000000` | 三键与 AppScope/app.json5（versionName=1.0.0、versionCode=1000000）一致；异常时本行输出 errCode/errMessage 键组 |
| 6 | S5 沙箱写盘自检 | `[XDM_PROBE][P0-U0][S5] probeFile=probe-selftest.txt writeBytes=21 readBackBytes=21` | writeBytes 与 readBackBytes 均为正整数且**两值相等**（由 verify 比对，探针不输出 match/differs 判定词）；写读失败输出 errCode/errMessage |
| 7 | SUMMARY | `[XDM_PROBE][P0-U0][SUMMARY] S1=deviceType=2in1,osFullName=HarmonyOS-6.1.1|S2=sdkApiVersion=24,firstApiVersion=<n>|S3=marketName=HarmonyOS PC|S4=bundleName=com.neuohos.xdm,versionName=1.0.0,versionCode=1000000|S5=probeFile=probe-selftest.txt,writeBytes=21,readBackBytes=21` | 段间 `\|` 分隔、段内 kv 用 `,` 连接（保留该步全部 kv）；各段值与 S1~S5 行一致；单行 <1500 字节 |
| 8 | END | `[XDM_PROBE][P0-U0][END] ok=true steps=5 elapsedMs=12` | steps 恰为 5；ok=true 仅指无脚手架级异常（步骤级失败以 err= 观测呈现，不产 PASS/FAIL 词）；elapsedMs 为非负整数 |

## 5. 需人工配合的步骤

S1~S5 全部 `autoRun=true`，**无强制人工步骤**。人工动作仅两处：

- 点击探针首页「环境自检（P0-U0）」卡片（进入即自动运行）。
- （可选）点「复制日志」把 8 行标记粘贴到备忘录，与 hilog 抓取结果互相印证。

路由行为验收点（对应 EntryAbility 实现）：

| 场景 | 预期 |
|---|---|
| 冷启动执行 `aa start ... --ps page probe` | 直进探针首页 |
| 探针页退后台后再执行同一命令（暖启动显式带参） | onNewWant 切回探针首页 |
| 桌面图标点开（暖启动不带参） | 保持当前页，不打断 |
| 无参冷启动（`devecocli run` 拉起） | 落 `pages/Index`（Hello World） |

## 6. 回贴

把 `probe-P0-U0.log` 全文（`[XDM_PROBE]` 行一律不要手工删改；必要时附 `cat <filesDir>/probe-latest.txt` 输出）发给 AI，由 `xdm-probe-verify` 工作流对照 `EXPECT-u0-1-foundation-probe-infra.json` 逐步骤判定 PASS / FAIL / UNVERIFIED / MISSING，并给出 fixItems 分流（probe-code / business-code / env / doc）。

## 7. 判定要点与常见坑

- **grep 锚恒为 `XDM_PROBE`**：探针标记行 hilog tag 为 `XDM_PROBE`、domain 0xD001；非标记诊断行（兜底写盘失败等）用 tag `XdmProbeKit`/`XdmProbePage`，不会被锚定，也不会产生未配对标记。
- **值白名单** `[A-Za-z0-9_.:/|= -]` 与空格：白名单外字符（如 CJK）逐字符替换为 `?`，属接受的观测损失；单行 <1500 字节由 ProbeKit 强制（SUMMARY 两级降级）。
- **同秒重跑 runId 撞号**：由 BEGIN/END 配对 + verify 取最后 runId 吸收；重跑前先抓日志。
- **每次标记行变更即全量重写 `<filesDir>/probe-latest.txt`**：探针中途 jscrash 也留痕，兜底优先级最高。
- **不做 PASS/FAIL 判定是红线**：探针只输出观测事实（含 errCode/errMessage），判定全部在 verify 对照本手册 §4 与 EXPECT JSON。
- **交付红线**：交付打包前整体移除 `entry/src/main/ets/probe/`（U7.3 执行，现阶段保留）。
