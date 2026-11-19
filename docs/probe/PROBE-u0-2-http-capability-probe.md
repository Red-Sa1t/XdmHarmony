# 探针运行手册：P0-U2 HTTP 能力探针

> 工程根：D:\git\HarmonyPC\XdmHarmony ｜ bundle：com.neuohos.xdm ｜ 预期表：[EXPECT-u0-2-http-capability-probe.json](./EXPECT-u0-2-http-capability-probe.json)
> hdc 未入 PATH，用全路径：HDC="D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
> 探针页形态：**autoStart=false**——先在 TextInput 填测试源地址，再点"运行全部"。

## 0. 一次性准备

```bash
# 真机（推荐验证环境）：真机拒绝未签名 HAP，首次必须做——
devecocli auth login                              # 华为账号登录
#   USB 连接真机并开启开发者模式/USB 调试后：
devecocli signature generate --product default    # 注册设备+生成签名材料，自动写入 build-profile.json5
# 模拟器（兜底/形态验证）：推包不需要签名
devecocli emulator list                           # 确认实例（本机已有 "Pura 90"）
```

## 1. 起测试源（主机侧，探针运行全程保持在线）

**主路径：echo 服务（覆盖 S1~S6 全部六步）**

```bash
cd /d D:\git\HarmonyPC\XdmHarmony
node docs\probe\P0-U2-echo-server.js 8080         # 绑 0.0.0.0:8080；端口可换，手册示例统一 8080
# 主机自检（另开一个终端）：
curl http://<主机局域网IP>:8080/echo               # 应回 acceptEncoding=...（curl 默认发 Accept: */* 不影响）
curl -s -o NUL -w "%{http_code}" -H "Range: bytes=0-" http://<主机局域网IP>:8080/big.bin   # 应 206
```

- `ipconfig` 查主机局域网 IPv4（示例用 `192.168.1.20`，**全文可替换**——探针页 TextInput 与下文所有命令中的 IP 用同一值）。
- **模拟器/真机内不能用 `127.0.0.1` 访问主机**（那是设备自身回环），必须填主机局域网 IP。
- Windows 防火墙：node 首次监听会弹"是否允许访问网络"，勾选"专用网络+公用网络"允许；错过弹窗可在"防火墙→允许应用通过防火墙"手动补。
- 控制台会实时打印每个请求的实收 method/path/Range/Cookie/Accept-Encoding——hilog 之外的第二证据。

**备选路径：http-server（仅覆盖 S1/S2/S4；S3/S5 必须回显服务，用备选源时 S3/S5 记 UNVERIFIED）**

```bash
fsutil file createnew big.bin 4194304             # 在任一空目录生成 4MiB 测试文件
npx http-server -a 0.0.0.0 -p 8080                # http-server 支持 Range；Python SimpleHTTPServer 不支持，勿用
```

## 2. 运行探针（设备侧）

```bash
cd /d D:\git\HarmonyPC\XdmHarmony
devecocli run --module entry                      # 构建+安装+拉起应用主页（AI 已构建过时：加 --skip-build）
# 打开探针页（EntryAbility 解析 want 参数 page=probe，支持冷/暖启动）：
hdc shell aa start -b com.neuohos.xdm -a EntryAbility --ps page probe
```

### 需人工配合的步骤（按单元填写）

- **真机首次**：§0 签名准备（`devecocli auth login` + `devecocli signature generate --product default`）；模拟器无需。
- **探针页内**（唯一人工输入环节）：首页点 **P0-U2 HTTP 能力探针（P0-U2）** → 顶部输入框把缺省 `http://192.168.1.20:8080` 改为主机实际局域网 IP（端口与 §1 启动端口一致，**禁 127.0.0.1**）→ 点 **运行全部**。
- 六步 S1~S6 全自动执行，无其他人工交互；S6 需等约 3 秒超时返回。
- **主机侧**：node 首次监听时 Windows 防火墙弹窗勾选"专用网络+公用网络"允许（错过可在"允许应用通过防火墙"补）。

## 3. 抓取标记（探针跑完后）

```bash
hdc shell "hilog -x | grep XDM_PROBE" > probe-P0-U2.log
# 兜底：缓冲被冲掉时取探针写盘结果（路径见 BEGIN 行 filesDir=）
hdc shell "cat <filesDir>/probe-latest.txt"
# 探针闪退时：devecocli log --crash
```

**S1 交叉核对（沙箱文件证据）**：

```bash
hdc shell "ls -l <filesDir>/probe-http-s1.bin"                          # 应为 4194304 字节
hdc shell "cat <filesDir>/probe-P0-U2-<runId>-s1-headers.txt"           # S1 响应头 JSON（runId 见 BEGIN 行）
```

## 4. 每步骤预期日志标记表（判定细则见 EXPECT 表）

`<base>` = 探针页 TextInput 值。hilog 过滤 `XDM_PROBE` 后应出现且仅出现一轮，行格式严格为
`[XDM_PROBE][P0-U2][<步骤>] key=value ...`（FORMAT 正则 `^\[XDM_PROBE\]\[([A-Z0-9-]+)\]\[([A-Za-z0-9-]+)\]\s(.+)$`）。
下表与 [EXPECT-u0-2-http-capability-probe.json](./EXPECT-u0-2-http-capability-probe.json) 的 steps 一一对应（9 条目）。

| 步骤 | 预期标记行（示例，值为观测事实判据；`<N>` 表浮动值） | 判定要点 |
|---|---|---|
| BEGIN | `[XDM_PROBE][P0-U2][BEGIN] runId=<HHmmss> filesDir=<非空沙箱files路径>` | 与 END 按 runId 配对；autoStart=false，填完 URL 点"运行全部"后才产生 |
| S1 | `[XDM_PROBE][P0-U2][S1] url=<base>/big.bin status=200 chunks=<N>=1 totalBytes=4194304 firstChunkBytes=<N>>0 writtenBytes=4194304 streamClosed=true detailFile=probe-P0-U2-<runId>-s1-headers.txt` | verify 复算 totalBytes==writtenBytes==4194304（三处同值锚）；chunks 依平台分块策略浮动只判范围；交叉核对 §3 沙箱文件 |
| S2 | `[XDM_PROBE][P0-U2][S2] url=<base>/big.bin requestRange=bytes=0- status=206 contentLength=4194304 contentRangeTotal=4194304 rangeSupported=true` | rangeSupported=(status==206) 谓词；206 为 resumable 与分段前提 |
| S3 | `[XDM_PROBE][P0-U2][S3] sent=identity serverEcho=identity contentLengthMatches=true` | serverEcho=echo 服务实收回显（去空白）；contentLengthMatches=(Content-Length 头==体字节数) 谓词 |
| S4 | `[XDM_PROBE][P0-U2][S4] concurrent=8 all206=true minDurationMs=<N>>0 maxDurationMs=<N>>=min totalBytes=4194304 firstErrCode=0` | all206=8 个 SegmentResult 全 206 谓词；TaskPool 内 http 可用性=风险#4 观测本体 |
| S5 | `[XDM_PROBE][P0-U2][S5] requestUrl=<base>/redirect status=200 redirectFollowed=true finalUrl=<base>/final cookieSeen=XDMProbeCookie=1 cookieSent=true` | redirectFollowed=finalUrl 以 /final 结尾；cookieSent=cookieSeen 含 ECHO_COOKIE；仅同主机 302 |
| S6 | `[XDM_PROBE][P0-U2][S6] timeoutSetMs=3000 timedOut=true errCode=2300028 elapsedMs=<N>>=3000` | 主判 2300028；2300007→UNVERIFIED（§5 换地址重跑）；timedOut=isTimeoutCode(errCode) |
| SUMMARY | `[XDM_PROBE][P0-U2][SUMMARY] S1=<...>\|S2=<...>\|S3=<...>\|S4=<...>\|S5=<...>\|S6=<...>` | 恰 6 段，各段关键键与步骤行互证（S1=status,streamClosed；S2=status,rangeSupported；S3=serverEcho；S4=all206；S5=redirectFollowed；S6=timedOut,errCode）；环形缓冲兜底锚 |
| END | `[XDM_PROBE][P0-U2][END] ok=true steps=6 elapsedMs=<N>>=0` | ok=true=无脚手架级异常；steps=6 与步骤行数互证 |

注意：
- PROBE_SPEC §2 示例的 S1/S2 内容与本单元步骤编号互换（本单元以单元指令为准：S1=流式落盘、S2=Range 206），SPEC 示例是示意值非契约，EXPECT 表才是唯一判定依据。
- S6 用 RFC 5737 TEST-NET-1 不可达地址（192.0.2.1），不依赖测试源；`elapsedMs` 约 3000 即视为超时控制生效。
- 任一步骤失败形态：该步行以 `errCode/errMessage` 键组替代正常键集（每步骤仍恰一行）；探针标记行不含通过/失败判定词，判定全部在 EXPECT/verify 侧。

## 5. 环境差异分支（重跑指引）

| 现象 | 判定 | 处置 |
|---|---|---|
| S6 `errCode=2300028`（Operation timeout，静默丢包） | PASS（主判） | — |
| S6 `errCode=2300007`（Failed to connect，RST/拒绝环境） | UNVERIFIED | 换不可达地址重跑：把 `ProbeHttpLogic.ets` 的 `UNREACHABLE_URL` 改用 TEST-NET-2（如 `http://198.51.100.1:8080/big.bin`）重构建；或检查主机/网络是否对 192.0.2.1 有显式 RST 行为、关代理后重跑 |
| S4 `all206=false` 且 8 个分段 `firstErrCode` 全非零 | 风险#4 实证（TaskPool 内 http 不可用） | **非 probe-code 返修**——按设计书 §8-分支 B 回写计划（U2.1 走全主线程退化路径） |
| S3 `serverEcho=absent` 或非 identity | 平台改写/剥离头 | 按设计书 §8-分支 D 回写（U1.2 不可依赖 identity 头） |
| S5 `cookieSeen=absent`（302 后服务端未实收 Cookie） | 平台"手动 Cookie 不随重定向转发"语义 | 按设计书 §8-分支 E 记录，U1.2 按原版语义每请求重注 Cookie，不需换栈 |
| 仅备选 http-server 源 | — | S3/S5 无 echo/redirect/final 路由，记 UNVERIFIED，换 echo 服务补跑 |

## 6. 会话守卫冒烟（硬要求① 的运行时验证）

1. 点"运行全部"后，S4 运行中（或任意步骤进行中）按 HOME 退后台；
2. `hdc shell aa start -b com.neuohos.xdm -a EntryAbility --ps page probe` 暖启动重进 → 探针首页 → P0-U2 → 立即点"运行全部"；
3. 预期：新会话九行完整、BEGIN/END 的 runId 单调配对、**无旧步骤标记行串入新会话、无孤儿 END**；旧会话在旧 runId 下最多残留其作废前的行（其异步续体恢复后静默退出，不产生任何新标记行）。

## 7. 回贴

把 probe-P0-U2.log 全文（[XDM_PROBE] 行一律不要手工删改）发给 AI，由 xdm-probe-verify 核对；判定后按设计书 §8 五分支模板回写 MIGRATION_PLAN §6 决策 9 与 RISK_ASSESSMENT 风险#2/#4。
