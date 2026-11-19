# 探针运行手册：P0-U3 扩展桥 8597 服务端探针

> 工程根：D:\git\HarmonyPC\XdmHarmony ｜ bundle：com.neuohos.xdm ｜ 预期表：[EXPECT-u0-3-extension-bridge-server.json](./EXPECT-u0-3-extension-bridge-server.json)
> hdc 未入 PATH，用全路径：HDC="D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
> 探针页形态：**autoStart=true**——进入 P0-U3 卡片即自动跑 S1/S2/S4；S3 为主机侧 curl 指引，需人工（或 AI 代执行）在主机侧执行命令后点"执行"复核。
> 连通性契约：浏览器扩展 connector.js:4 `APP_BASE_URL=http://127.0.0.1:8597`，仅 HTTP 轮询（无 Native Messaging）——本探针验证的就是该契约的服务端半边。

## 0. 一次性准备

```bash
# 真机（推荐验证环境）：真机拒绝未签名 HAP，首次必须做——
devecocli auth login                              # 华为账号登录
#   USB 连接真机并开启开发者模式/USB 调试后：
devecocli signature generate --product default    # 注册设备+生成签名材料，自动写入 build-profile.json5
# 模拟器（兜底/形态验证）：推包不需要签名
devecocli emulator list                           # 确认实例（本机已有 "Pura 90"）
```

## 1. 启动环境

```bash
devecocli emulator start "Pura 90"      # 真机 USB 连接后跳过
devecocli device list                   # 多设备时后续命令需 --device <serial>
```

## 2. 运行探针（设备侧）

```bash
cd /d D:\git\HarmonyPC\XdmHarmony
devecocli run --module entry            # 构建+安装+拉起应用主页（AI 已构建过时：加 --skip-build）
# 应用经本命令正常拉起，EntryAbility.onCreate 已启动 8597 桥服务——S1 的 alreadyStarted=true
# 本身就是"启动接线"的运行时证据。打开探针页：
hdc shell aa start -b com.neuohos.xdm -a EntryAbility --ps page probe
```

- **拉起形态说明**：本工程无独立 ProbeAbility——`devecocli run --module entry` 拉起的是唯一 ability `EntryAbility`（module.json5 mainElement），探针页 `probe/ProbeIndex` 由 EntryAbility 解析 want 参数 `page=probe` 路由（冷/暖启动均支持，ProbeIndex 经页内条件渲染进入 P0-U3 单元），与 PROBE_SPEC §1 手册模板口径一致；`main_pages.json` 仅注册 `pages/Index` 与 `probe/ProbeIndex`。

- 探针首页点 **P0-U3 扩展桥 8597 服务端探针（P0-U3）** → S1/S2/S4 自动执行（约数秒）；S3 卡片显示主机侧指引，先不点。
- U0.3 验收一律在前台执行（S3 主机 curl 时应用须在前台；退后台 socket 存活性属 U5.1 长时任务语义，设计书 §8.2 已登记）。

## 3. S3 主机侧 curl 全套命令（AI 在设备连接时代执行）

> 按顺序执行；执行完 §3 全部命令后，回探针页点 S3 的"执行"按钮产生复核 minisession（计数增长判定取该行，见 §5-S3 与 EXPECT note）。

```bash
# ① 端口转发（设备 8597 → 主机 18597）：
hdc fport tcp:18597 tcp:8597

# ② 连通性契约（/sync 合法性判定基准，扩展 res.json() 同口径）：
curl -i http://127.0.0.1:18597/sync
#   应答签名：HTTP/1.0 200 OK（恒 HTTP/1.0，与请求版本无关）＋
#   Content-Type: application/json ＋ Cache-Control: max-age=0, no-cache, must-revalidate ＋
#   Connection: keep-alive ＋ Content-Length: <N> ＋ 合法 JSON（8 字段，序见 EXPECT）。
#   注意：curl 默认不发 Connection 头，curl 收完即连接关闭——原版"应答头恒写 keep-alive 但
#   服务端按请求判定复用"的非对称签名（设计书 §3.3）。
curl -s http://127.0.0.1:18597/sync     # stdout 直接过 JSON.parse 校验（连通性契约）

# ③ 八路由逐条可达（404 也是可达证据——连接/应答/断连定界全链路）：
for %p in (/sync /download /media /tab-update /vid /clear /link /args) do @(curl -s -o NUL -w "%{http_code} %p\n" http://127.0.0.1:18597%p)
#   cmd 版或 bash 版：
for p in /sync /download /media /tab-update /vid /clear /link /args; do curl -s -o /dev/null -w "%{http_code} $p\n" http://127.0.0.1:18597$p; done
#   预期：/sync=200，其余七条=404（未实现业务路由，U6.1 补全）。

# ④ POST /sync 样例（扩展 postMessage 形态，connector.js:44-48）：
curl -s -o NUL -w "%{http_code}\n" -X POST -d "{}" http://127.0.0.1:18597/sync     # 预期 200

# ⑤ 非对称 keep-alive 签名观测（应答头写 keep-alive 但连接被服务端关闭）：
curl -v http://127.0.0.1:18597/sync 2>&1 | findstr /i "connection closed"
#   预期签名：< HTTP/1.0 200 OK、< Connection: keep-alive、连接随后被关闭（curl -v 显示 Closed）。

# ⑥ 清理：
hdc fport rm tcp:18597
```

扩展轮询时序注记（供 U6.3 对表）：connector.js:14-22 注册 12 个 `periodInMinutes:1` 的 alarm，相位 `now+1000+(i+1)*5000` 错开——合并后稳态 ≈5s 一次 `GET /sync`，首轮约 6s；主机侧 ② 执行后若持续观察，应看到每 ~5s 一次服务端计数增长（S3 复核行的 requests 反映）。

AI 代执行指引：设备连接时（`devecocli device list` 有在线设备）AI 直接执行 §3 命令并记录输出；执行完毕后需人工（或 AI 经 hdc 模拟点击不可行时人工）回探针页点 S3"执行"。

## 4. 抓取标记（探针跑完后）

```bash
# hdc 未入 PATH，用全路径（也可先 set "HDC=D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"）：
"D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" shell "hilog -x | grep XDM_PROBE" > probe-P0-U3.log
# 兜底：缓冲被冲掉时取探针写盘结果（路径见 BEGIN 行 filesDir=）
"D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" shell "cat <filesDir>/probe-latest.txt"
# S2 交叉核对（原始应答头+体证据）：
"D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" shell "cat <filesDir>/probe-P0-U3-<runId>-s2-response.txt"
# 探针闪退时：devecocli log --crash
```

## 5. 每步骤预期日志标记表（判定细则见 EXPECT 表）

hilog 过滤 `XDM_PROBE` 后应出现且仅出现 S1/S2/S4 一轮 + S3 至少一次迷你会话，行格式严格为
`[XDM_PROBE][P0-U3][<步骤>] key=value ...`（FORMAT 正则 `^\[XDM_PROBE\]\[([A-Z0-9-]+)\]\[([A-Za-z0-9-]+)\]\s(.+)$`）。
下表与 [EXPECT-u0-3-extension-bridge-server.json](./EXPECT-u0-3-extension-bridge-server.json) 的 steps 一一对应（7 条目）。

| 步骤 | 预期标记行（示例，值为观测事实判据；`<N>` 表浮动值） | 判定要点 |
|---|---|---|
| BEGIN | `[XDM_PROBE][P0-U3][BEGIN] runId=<HHmmss> filesDir=<非空沙箱files路径>` | 与 END 按 runId 配对；autoStart=true，进入 P0-U3 卡片即产生 |
| S1 | `[XDM_PROBE][P0-U3][S1] alreadyStarted=true boundPort=8597 portMismatch=false connections=0 requests=0` | alreadyStarted=true＝EntryAbility 启动接线的运行时证据（start() 幂等 memoized 复用）；portMismatch=(boundPort≠8597) 谓词 |
| S2 | `[XDM_PROBE][P0-U3][S2] status=200 contentType=application/json cacheControl=max-age=0/no-cache/must-revalidate contentLength=<N> bodyBytes=<N> jsonValid=true fieldCount=8 fieldOrder=enabled/fileExts/blockedHosts/requestFileExts/mediaTypes/tabsWatcher/videoList/matchingHosts reuseResponses=2 closeConnClosed=true detailFile=probe-P0-U3-<runId>-s2-response.txt` | verify 复算 contentLength==bodyBytes；fieldOrder 与 cacheControl 的分隔符为 `/`（探针值白名单不含逗号，emit 侧 `,`→`/`；原始逗号形在 detail 文件 fieldOrderRaw 与应答头原值保留可交叉核对）；reuseResponses=2＝keep-alive 同连接两应答（busy/pending 串行泵回归观测）；closeConnClosed=true＝Connection: close 请求后服务端主动关闭（非对称签名设备侧观测） |
| S3 | `[XDM_PROBE][P0-U3][S3] cmd1=hdc fport tcp:18597 tcp:8597 cmd2=curl http://127.0.0.1:18597/sync connections=<N> requests=<N> lastMethod=GET lastPath=/sync` | 手动步骤：主机 curl 前后各点一次"执行"，每次独立 minisession（BEGIN+S3+END）；判定取**主机 curl 执行后的最后一次 S3 行**，其 requests/connections 较 S2 后快照增长（curl 每请求 +1 连接 +1 请求） |
| S4 | `[XDM_PROBE][P0-U3][S4] syncStatus=200 downloadStatus=404 mediaStatus=404 tabUpdateStatus=404 vidStatus=404 clearStatus=404 linkStatus=404 argsStatus=404 querySyncStatus=404 postSyncStatus=200 malformedClosed=true` | **404 即可达证据**（连接/应答/断连定界全链路，U6.1 补业务后转 200）；querySyncStatus=404＝path 精确匹配不剥 query；postSyncStatus=200＝POST 同样只分发不校验 method；malformedClosed=（裸发 GARBAGE 无头块且连接被关）＝解析失败断连不回包观测 |
| SUMMARY | `[XDM_PROBE][P0-U3][SUMMARY] S1=<...>\|S2=<...>\|S3=<...>\|S4=<...>` | 恰 4 段（S1=boundPort 或 portMismatch；S2=status 或 jsonValid；S3=lastPath 或 connections；S4=syncStatus 或 malformedClosed），与步骤行互证；环形缓冲兜底锚 |
| END | `[XDM_PROBE][P0-U3][END] ok=true steps=4 elapsedMs=<N>>=0` | ok=true＝无脚手架级异常；steps=4 与步骤行数互证 |

注意：
- 任一步骤失败形态：该步行以 `errCode/errMessage` 键组替代正常键集（每步骤仍恰一行）；S4 单路由连接失败不中断循环，该路由状态记 `err<errCode>`（连接失败也是错误处理观测事实）。
- 探针标记行不含通过/失败判定词，判定全部在 EXPECT/verify 侧；布尔键均为对直接观测值的谓词编码。
- S3 产生多个 BEGIN/END（minisession 编排是 ProbePage.runSingle 既有惯例）——verify 按 runId 配对，取数口径见上表，不判 FORMAT 错误。

## 6. 环境差异分支（重跑指引）

| 现象 | 判定 | 处置 |
|---|---|---|
| S1 `portMismatch=true`（8597 被第三方占用/系统随机分配端口） | UNVERIFIED | `netstat -ano \| findstr 8597` 查占用并结束占用进程（或重启设备）后重跑；无原版 MSG_ALREADY_RUNNING UI 提示属设计拍板（§0-3），不作为 FAIL |
| S2/S4 `errCode=2300007` 系（连接被拒） | 分流 | 桥未启动＝EntryAbility 接线缺失→probe-code/business-code 返修；应用不在前台→回前台重跑 |
| S2 `reuseResponses=1`（第二次应答未达） | 分流 | keep-alive 串行泵回归点失效→business-code 返修（对照 ClientSession busy/pending） |
| S2 `closeConnClosed=false` | 分流 | 服务端未按 close 关闭→business-code 返修（isKeepAlive 判定链）；2s 宽限后仍 false 才计 |
| S4 `malformedClosed=false` | 分流 | 解析失败未断连（回了应答或连接保持）→business-code 返修（对照原版 HttpServer.cs:56-63 语义） |
| S3 复核行计数无增长 | 分流 | 主机 curl 未实际到达设备（fport 失败/应用退后台冻结）→env；重执行 §3-① 后重跑 |
| 主机 curl ② 应答非 `HTTP/1.0` 状态行 | FAIL | 应答拼装偏离 RequestContext.cs:37（恒 HTTP/1.0）→business-code 返修，勿"顺手修正"为 HTTP/1.1 |

## 7. 回贴

把 probe-P0-U3.log 全文（[XDM_PROBE] 行一律不要手工删改；S3 多个 minisession 全部保留）+ §3 主机侧命令输出发给 AI，由 xdm-probe-verify 对照 EXPECT-u0-3-extension-bridge-server.json 核对；S3 取主机 curl 后最后一次 minisession 行。
