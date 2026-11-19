# XDM 鸿蒙迁移 · 探针规范（PROBE_SPEC）

> 版本：v1（2026-09-26）。作用：把"必须到鸿蒙系统里 1:1 运行才能核实的行为"固化为可机械核对的探针闭环。
> 闭环：`xdm-migrate` 生成探针代码 + PROBE.md + 预期表 → 人工在模拟器运行探针 → 回贴日志 → `xdm-probe-verify` 工作流逐步骤判定 → FAIL 分流返修。

## 1. 探针形态与放置

探针作为**主工程 entry 模块内的探针页**（已评估优于独立探针工程：与业务共享同一套 hvigor 门禁、ffmpeg NAPI 只需验证一次、同 bundle 结论直接适用）：

```
entry/src/main/ets/probe/
├── core/ProbeKit.ets          # 标记工具：DOMAIN/TAG 常量、runId、emit(step, kvs)、SUMMARY 聚合、写 files/probe-latest.txt 兜底
├── core/ProbePage.ets         # 通用探针页脚手架（步骤列表 + 自动运行开关 + 手动步骤按钮）
├── ProbeIndex.ets             # 探针首页：列出全部单元，点击进入
└── units/
    └── Probe<Name>.ets        # 每个探针单元一个文件
```

配套（U0.1 已落地）：探针页经 **EntryAbility want 参数路由**拉起（`want.parameters.page=probe` → `probe/ProbeIndex`，onCreate/onNewWant 均处理）；`main_pages.json` 注册 `probe/ProbeIndex`；`module.json5` deviceTypes 含 `2in1`。

约定：
- 探针首页自动运行无需交互的步骤；需人工的步骤（复制文本、浏览器操作）在页面给按钮与提示。
- 探针**只输出观测事实（key=value），不做 PASS/FAIL 判定**——判定全部在 `xdm-probe-verify` 对照期望表进行，防止期望写死在探针代码里造成假 PASS。
- 业务页面禁止 import probe/（审查规则）；交付打包前整体移除 probe/。

### 运行环境：真机优先

- **设备侧零工具依赖**：构建、安装、日志抓取全部在 PC 上执行（devecocli/hdc/hilog）；真机只需要能运行 HAP——探针本身就是一个普通 HarmonyOS 应用，不需要设备上装任何编程工具。设备上的人工动作只有：点探针按钮、复制文本、浏览器内操作、看通知，全部是鸿蒙系统原生操作。
- **真机优先**：探针默认在真机运行（网络吞吐、后台保活、通知、剪贴板、浏览器行为都比模拟器真实）；模拟器作为兜底与形态验证环境（2-in1 自由窗口等 PC 形态行为）。结论一律标注验证环境。
- **真机一次性准备（关键差异）**：真机拒绝安装未签名 HAP（模拟器不需要签名）。首次：`devecocli auth login` → USB 连接真机并开启开发者模式/USB 调试 → `devecocli signature generate --product default`（注册设备并生成签名材料，自动写入 build-profile.json5）。之后流程与模拟器完全一致。U0.1 的环境自检探针会输出 deviceType/API 版本等信息，自动摸清真机形态。
- **AI 直接驱动**：探针是**一次性**验收工具（PASS 即归档，结论写回计划，不重复运行）。devecocli/hdc 在 PC 侧可用时，安装、拉起、日志抓取由 AI 在会话内自动执行——本手册的命令同时就是 AI 的执行脚本；人工只做设备侧交互步骤（复制文本、浏览器操作）与最终验收。探针 HAP 累积所有已生成探针，一份日志可验多个单元，攒到 Phase 末批量跑。

## 2. 日志标记规范（机器可 grep 的唯一契约）

日志通道：`hilog.info(0xD001, 'XDM_PROBE', '%{public}s', marker)`（domain 0xD001、tag XDM_PROBE、强制 %{public}s 防 private 脱敏）。

行格式：

```
[XDM_PROBE][<单元ID>][<步骤号>] <key>=<value> [key=value ...]
```

- 单元 ID：`P0-U2` 格式（大写、连字符）。步骤号 `S1`…`S99`，另有三个保留步骤号：
  - `[BEGIN] runId=<HHmmss> filesDir=<沙箱 files 路径>` —— 运行开始
  - `[SUMMARY] S1=<关键值>|S2=<关键值>|…` —— 全部步骤结果聚合单行（环形缓冲被冲掉时兜底；必须 <1500 字节）
  - `[END] ok=<true|false> steps=<n> elapsedMs=<ms>` —— 运行结束
- value 字符集白名单：`[A-Za-z0-9_.:/|=?-]` 与空格（`?` 为消毒占位符：含白名单外字符如 CJK 的观测值经 ProbeKit 消毒后以 `?` 替换呈现）；URL 不含空格；布尔 `true/false`；数字带单位（`bytes=`、`ms=`）。
- 每步骤恰好一行，单行 <1500 字节（hilog 单条 4096 字节截断留余量）；grep 锚恒为 `XDM_PROBE`。
- 大段数据（如响应头全量）不进 hilog：写沙箱 `files/probe-<unit>-<runId>.txt`，标记行只记 `detailFile=<文件名>`。

内部会话身份使用 `ProbeKit.getSessionToken()`，与可重复的 HHmmss 显示编号分开。异步步骤、会话缓存和临时文件名使用 token；BEGIN 及详情中的 `runId` 保持 HHmmss，详情可另存 `sessionToken`。临时文件名可将上述模板的 runId 替换为 token，防止同秒重跑或进程重启覆盖旧证据。退出页面会作废自己的会话，保留缺 END 的真实中断记录；旧异步回调不得发射新会话的步骤或 END。

示例（一次 P0-U2 运行）：

```
[XDM_PROBE][P0-U2][BEGIN] runId=142533 filesDir=/data/app/el2/100/base/com.neuohos.xdm/haps/entry/files
[XDM_PROBE][P0-U2][S1] url=http://192.168.1.20:8080/big.bin status=206 contentLength=10485760 rangeSupported=true
[XDM_PROBE][P0-U2][S2] chunks=312 totalBytes=10485760 firstChunkBytes=65536 streamClosed=true
[XDM_PROBE][P0-U2][S3] acceptEncoding=identity serverEcho=identity contentLengthMatches=true
[XDM_PROBE][P0-U2][S4] concurrent=8 all206=true minDurationMs=180 maxDurationMs=612
[XDM_PROBE][P0-U2][S5] redirectFollowed=true finalUrl=... cookieSent=true
[XDM_PROBE][P0-U2][S6] timeoutSetMs=3000 timedOut=true errorCode=2300028
[XDM_PROBE][P0-U2][SUMMARY] S1=status=206|S2=chunks=312|S3=identity|S4=all206=true|S5=cookieSent=true|S6=timedOut=true
[XDM_PROBE][P0-U2][END] ok=true steps=6 elapsedMs=5213
```

`xdm-probe-verify` 的解析正则：`^\[XDM_PROBE\]\[([A-Z0-9-]+)\]\[([A-Za-z0-9-]+)\]\s(.+)$`，不匹配的 XDM_PROBE 行记 FORMAT-ERROR 反馈返修。

## 3. PROBE.md 用户操作手册模板

每个探针单元由工作流生成 `XdmHarmony/docs/probe/PROBE-<单元slug>.md`，模板如下（命令已按本机实测核实）：

```markdown
# 探针运行手册：<单元ID> <单元名>

> 工程根：D:\git\HarmonyPC\XdmHarmony ｜ bundle：com.neuohos.xdm
> hdc 未入 PATH，用全路径：HDC="D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"

## 0. 一次性准备
# 真机（推荐验证环境）：真机拒绝未签名 HAP，首次必须做——
devecocli auth login                    # 华为账号登录
#   USB 连接真机并开启开发者模式/USB 调试后：
devecocli signature generate --product default   # 注册设备+生成签名材料，自动写入 build-profile.json5
# 模拟器（兜底/形态验证）：推包不需要签名
devecocli emulator list                 # 确认实例（本机已有 "Pura 90"）

## 1. 启动环境
# 真机：USB 连接后直接确认；模拟器：
devecocli emulator start "Pura 90"
devecocli device list                   # 多设备时后续命令需 --device <serial>

## 2. 运行探针
cd /d D:\git\HarmonyPC\XdmHarmony
devecocli run --module entry            # 构建+安装+拉起应用主页
# AI 已构建过时：加 --skip-build
# 打开探针页（EntryAbility 解析 want 参数 page=probe，支持冷/暖启动）：
hdc shell aa start -b com.neuohos.xdm -a EntryAbility --ps page probe

## 3. 抓取标记（探针跑完后）
hdc shell "hilog -x | grep XDM_PROBE" > probe-<单元ID>.log
# 兜底：缓冲被冲掉时取探针写盘结果（路径见 BEGIN 行 filesDir=）
hdc shell "cat <filesDir>/probe-latest.txt"
# 探针闪退时：devecocli log --crash

## 4. 需人工配合的步骤（按单元填写）
- （例）P0-U4 剪贴板：在模拟器任意应用复制一段文本 → 回探针页点"已复制"。
- （例）P0-U1 桥：主机侧 hdc fport tcp:18597 tcp:8597 && curl http://127.0.0.1:18597/sync

## 5. 回贴
把 probe-*.log 全文（[XDM_PROBE] 行一律不要手工删改）发给 AI，由 xdm-probe-verify 核对。
```

注意：模拟器内 `127.0.0.1` 是模拟器自身回环——模拟器访问主机测试源用主机局域网 IP（`npx http-server -a 0.0.0.0`）；主机访问模拟器内服务用 `hdc fport`。

## 4. 验证闭环（xdm-probe-verify 工作流）

- 输入：`probeDoc`（PROBE 文档路径）、`logInput`（日志文本或 .log 文件路径）、可选 `unit`、`rerunOf`（返修重跑对比）。
- 流程：脚本先**确定性正则解析**全部标记行（FORMAT-ERROR 单列、BEGIN/END 配对检查）→ 验证 agent 对照 PROBE 文档期望表逐步骤判定 PASS / FAIL / UNVERIFIED / MISSING → 产出 `fixItems`（返修对象四类：probe-code / business-code / env / doc）与 nextAction。
- 返修分流：probe-code → 重跑 `xdm-migrate`（unit="返修探针 <ID>"，notes 附失败标记与 fixItems）；business-code → 先更新计划/设计结论，再走 `xdm-migrate` 正常返修；env → 执行用户操作后原样重验；doc → 修期望表后重验。
- 重跑验证传 `rerunOf` 做增量对比；探针判定看板（probe-status）持续记录每单元最新判定，对应 MIGRATION_PLAN §8 验证矩阵的"运行"行。

## 5. 已知风险与缓解

| 风险 | 缓解 |
|---|---|
| hilog 环形缓冲冲掉早期标记 | SUMMARY 单行兜底（最后写）；每步骤即时单行输出；探针同步写 `files/probe-latest.txt`；抓取赶在重跑前 |
| 单条日志 >4096 字节截断 | 单行 <1500B 硬约束；白名单字符；大段数据写文件只记文件名 |
| hilog 默认 private 脱敏 | ProbeKit 强制 %{public}s |
| 未签名 HAP 安装 | **真机必须签名**（一次性 auth login + signature generate，手册步骤 0）；模拟器不需要签名 |
| 模拟器无华为浏览器 → 扩展栈验不了 | 服务端探针 100% 自动化先行；扩展侧优先在真机实测（真机浏览器通常预装，U0.5 目检确认）；退化"仅嗅探"判定规则预写（风险登记册 #1） |
| 模拟器内 127.0.0.1 回环误解 | 自连验证服务端；fport 转发；测试源绑 0.0.0.0 + 局域网 IP |
| 多设备命令失败 | 先 `devecocli device list` 记 serial，命令带 --device |
| 假 PASS | 期望不写进探针代码；判定全在 verify 工作流对照期望表 |
| 多次运行标记混杂 | runId + BEGIN/END 配对；verify 取最后 runId 或 rerunOf 对比 |
