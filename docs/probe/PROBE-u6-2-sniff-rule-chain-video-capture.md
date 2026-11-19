# 探针运行手册：P6-U2 嗅探规则链+视频捕获

> 工程根：D:\git\HarmonyPC\XdmHarmony ｜ bundle：com.neuohos.xdm ｜ 探针单元 ID：`P6-U2`
> hdc 未入 PATH，用全路径：`HDC="D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"`（本机已核实存在）
> 设计书：docs/design/u6-2-sniff-rule-chain-video-capture-DESIGN.md（§5.0 用例表/§6 步骤表）｜ 预期表：EXPECT-u6-2-sniff-rule-chain-video-capture.json（与本文 §4 表一一对应）
> 设备侧探针：entry/src/main/ets/probe/units/ProbeVideoSniff.ets（P6-U2 卡片，S1~S8 全自动）
> 主机侧脚本：docs/probe/P6-U2-sniff-cases.js（规则链用例表 65 例，AI 自动轨——**已在本会话实跑：SUMMARY pass=65 fail=0，退出码 0**）

## 0. 一次性准备

```bash
# 真机（推荐验证环境）：真机拒绝未签名 HAP，首次必须做——
devecocli auth login                    # 华为账号登录
#   USB 连接真机并开启开发者模式/USB 调试后：
devecocli signature generate --product default   # 注册设备+生成签名材料，自动写入 build-profile.json5
# 模拟器（兜底/形态验证）：推包不需要签名
devecocli emulator list                 # 确认实例（本机已有 "Pura 90"）
```

## 1. 启动环境

```bash
# 真机：USB 连接后直接确认；模拟器：
devecocli emulator start "Pura 90"
devecocli device list                   # 多设备时后续命令需 --device <serial>
```

## 2. 运行探针

```bash
cd /d D:\git\HarmonyPC\XdmHarmony
devecocli run --module entry            # 构建+安装+拉起应用主页（AI 已构建过时加 --skip-build）
# 打开探针页：EntryAbility 解析 want 参数 page=probe（冷/暖启动均支持）——
%HDC% shell aa start -b com.neuohos.xdm -a EntryAbility --ps page probe
```

注：本工程探针页经 **EntryAbility want 参数路由**拉起（PROBE_SPEC §1，U0.1 落地机制），
module.json5 仅注册 `EntryAbility`/`EntryBackupAbility`（本会话核实 :35-38/:62-63），不存在独立
ProbeAbility——`devecocli run --module entry --ability ProbeAbility` 形态不适用本工程，以上方
`aa start` 为准。
探针首页点 **P6-U2 卡片（嗅探规则链+视频捕获探针）** → autoStart 自动跑 S1~S8（全程无需人工交互）。
前置态说明：S1 /clear 只清 tracker 四表**不清嗅探态**（源 ClearVideoList 同貌）——S5/S6 依赖 S3/S4
写入的 m3u8Tabs/referersToSkip 前序状态属预期（设计书 §7 风险表；S4/S6 载荷 tabId 与 S3 错开避免串扰）。

## 3. 抓取标记（探针跑完后）

```bash
%HDC% shell "hilog -x | grep XDM_PROBE" > probe-P6-U2.log
# 兜底：环形缓冲被冲掉时取探针写盘结果（路径见 BEGIN 行 filesDir=）
%HDC% shell "cat <filesDir>/probe-latest.txt"
# 探针闪退时：devecocli log --crash
```

行格式契约（PROBE_SPEC §2）：`[XDM_PROBE][P6-U2][<步骤号>] <key>=<value> ...`；
verify 解析正则 `^\[XDM_PROBE\]\[([A-Z0-9-]+)\]\[([A-Za-z0-9-]+)\]\s(.+)$`；
值白名单 `[A-Za-z0-9_.:/|=?-]` 与空格，含逗号/括号值已由探针预转换（`,`→`/`、`[X]` 剥括号、
音频段 token 内空格→`_`，如 `[MP4 AUDIO]` → `MP4_AUDIO`）。

## 4. 每步骤预期日志标记表（P6-U2 一次运行的示例行）

```
[XDM_PROBE][P6-U2][BEGIN] runId=101601 filesDir=/data/app/el2/100/base/com.neuohos.xdm/haps/entry/files
[XDM_PROBE][P6-U2][S1] started=true boundPort=8597 clearStatus=200 baseVideoCount=0
[XDM_PROBE][P6-U2][S2] mediaStatus=200 secondStatus=200 jsonStatus=200 addedEvents=2 listCount=2 firstTextSuffix=.mp4 secondTextSuffix=.aac secondInfoPrefix=AAC
[XDM_PROBE][P6-U2][S3] hlsStatus1=200 hlsStatus2=200 beforeCount=2 afterCount=2 tsBlocked=true
[XDM_PROBE][P6-U2][S4] seedStatus=200 skipStatus=200 otherStatus=200 beforeCount=2 afterSkipCount=2 afterOtherCount=3
[XDM_PROBE][P6-U2][S5] audioStatus=200 videoStatus=200 dualCount=1 audioTextPrefix=MP4_AUDIO dualTextPrefix=1080p listCount=5
[XDM_PROBE][P6-U2][S6] normalStatus=200 kvStatus=200 kvTextPrefix=KV_AUDIO kvFileText=Clipmkv vidStatus=200 videoDialogEvents=1
[XDM_PROBE][P6-U2][S7] seededCount=2 kindCount=4 syncStatus=200 listCount=9 walkthroughHint=open-menu-media-capture
[XDM_PROBE][P6-U2][S8] clearStatus=200 finalVideoCount=0 fieldCount=8 fieldOrder=enabled/fileExts/blockedHosts/requestFileExts/mediaTypes/tabsWatcher/videoList/matchingHosts connections=17 requests=17 mediaAddedEvents=9 videoDialogEvents=1
[XDM_PROBE][P6-U2][SUMMARY] S1=clearStatus=200|S2=listCount=2|S3=tsBlocked=true|S4=afterOtherCount=3|S5=dualCount=1|S6=videoDialogEvents=1|S7=kindCount=4|S8=finalVideoCount=0
[XDM_PROBE][P6-U2][END] ok=true steps=8 elapsedMs=2800
```

逐步骤键与期望要点（完整 note 见 EXPECT 表；值只写观测事实，判定在 xdm-probe-verify）：

| 步骤 | 观测键 | 期望要点 |
|---|---|---|
| BEGIN | runId、filesDir | runId 非空（与 END 配对）；filesDir 非空沙箱路径 |
| S1 | started boundPort clearStatus baseVideoCount | started=true；boundPort=8597；clearStatus=200；baseVideoCount=0 |
| S2 | mediaStatus secondStatus jsonStatus addedEvents listCount firstTextSuffix secondTextSuffix secondInfoPrefix | 三次均 200；addedEvents=2（mp4+aac 登记，application/json 识别锚不登记——分派链四段独立非互斥的 YT 分支锚）；listCount=2；firstTextSuffix=.mp4；secondTextSuffix=.aac；secondInfoPrefix=AAC（audio/aac → ext=aac；设计书 §6 示例行 .m4a 为示意，按实现真值） |
| S3 | hlsStatus1 hlsStatus2 beforeCount afterCount tsBlocked | 两次均 200；beforeCount=afterCount；tsBlocked=true（.m3u8 识别+m3u8Tabs 写入后，同 tabId 的 .ts 段被 isNormalVideo 门②拦截——U6.1 §7-3 暂态消除） |
| S4 | seedStatus skipStatus otherStatus beforeCount afterSkipCount afterOtherCount | 三次均 200；afterSkipCount=beforeCount（Referer=R1 在 referersToSkip sha1 键命中 → IsMediaFragment 拦）；afterOtherCount=beforeCount+1（Referer=R2 登记） |
| S5 | audioStatus videoStatus dualCount audioTextPrefix dualTextPrefix listCount | 两次均 200；dualCount=1（同 id=oA 音频+视频配对 → yt 表 .mkv 双源）；audioTextPrefix=MP4_AUDIO（HandleDashAudio 单源 '[MP4 AUDIO] 1000B'，contentType=mime=唯一非空登记路径）；dualTextPrefix=1080p（'[1080p] 2.9K' 恒取视频侧 itag）；listCount=5（S4 后 3 + audio 单源 1 + dual 1） |
| S6 | normalStatus kvStatus kvTextPrefix kvFileText vidStatus videoDialogEvents | 三次均 200；normalStatus 对应 itag=22 短路落普通门登记 Regular.mp4；kvTextPrefix=KV_AUDIO、kvFileText=Clipmkv（'mkv' 缺前导点怪癖 1:1 保留，D13 钉死）；vidStatus=200 且 videoDialogEvents=1（auto=false 默认 → onShowVideoDownloadDialog 事件计数——U6.3 前无弹窗为预期） |
| S7 | seededCount kindCount syncStatus listCount walkthroughHint | seededCount=2（直调 addHlsVideo/addDashVideo 各 1 条——U6.4/U7.1 解析产物数据形状，走查数据）；kindCount=4（yt/video/hls/dash 四表各≥1，getTrackedVideos 富投影——/sync 投影不挂 kind）；listCount=9（S6 后 7+种子 2）；walkthroughHint=open-menu-media-capture |
| S8 | clearStatus finalVideoCount fieldCount fieldOrder connections requests mediaAddedEvents videoDialogEvents | clearStatus=200；finalVideoCount=0；fieldCount=8；fieldOrder 恰八字段契约序（事件面零破坏：/sync SyncFields 字段序契约冻结）；connections/requests 与 S1 差值互证（S1~S8 共 17 请求=S1:1+S2:3+S3:2+S4:3+S5:2+S6:3+S7:1+S8:2）；mediaAddedEvents=9（S2:2+S4:1+S5:2+S6:2+S7:2）；videoDialogEvents=1（仅 S6 一次） |
| SUMMARY | S1..S8 段聚合 | 恰 8 段，单行 <1500B |
| END | ok steps elapsedMs | ok=true；steps=8；elapsedMs>=0 |

失败形态：任一步骤 catch → 该步输出 `errCode=<code> errMessage=<msg>` 键组仍恰一行（不中断会话）。

## 5. 主机侧双轨

### 5.1 Node 用例轨（AI 已自验，首选——验收"规则链用例表全绿"）

```bash
cd /d D:\git\HarmonyPC\XdmHarmony
node docs/probe/P6-U2-sniff-cases.js
# 期望：逐用例 [A1]..[F4] pass；SUMMARY pass=65 fail=0 total=65；退出码 0
# 本会话已实跑通过（65/65，EXIT=0）——复跑用于回归确认
```

用例表分组（设计书 §5.0）：A 组 18（isMatchingRequest 八层镜像+passesSendGate 三态——**纯函数
规格件，不接 /media 服务端链**，防双重过滤）；B 组 9（分派链谓词五件+itag 十二点边界）；C 组 8
（分派链全流程：normal 登记 contentType 空串、YT JSON 锚不登记、m3u8 两表写入、同 tab .ts 拦截
=暂态消除、referer 跳过、init.mp4 分片集、size 门）；D 组 23（YT-DASH 配对全量怪癖——range 末位
丢参留尾随 '&'、同 id 配对 .mkv、itag=22 短路、大写 ITAG、垃圾 itag catch、webm/flac、(length,id)
去重、队尾扫描、lastVid 守卫、稳态 33、最老挤出、octet 不登记、Itags 缺项 MKV、60 项、抽查
137/141 双空格/82）；E 组 3（sha1 已知向量+LinkAccepted 谓词备查）；F 组 4（pending {url,file}
对+MP3 复选框门三态）。

### 5.2 curl 兜底轨（人工复核设备侧桥）

```bash
%HDC% fport rm tcp:18597
%HDC% fport tcp:18597 tcp:8597
%HDC% fport ls                          # 应列出 tcp:18597 tcp:8597
# S2 分类矩阵：
curl -s -X POST http://127.0.0.1:18597/media -d '{"url":"https://h/v/movie.mp4","file":"Movie","requestHeaders":{"User-Agent":["UA"]},"responseHeaders":{"Content-Type":["video/mp4"],"Content-Length":["5242880"]}}'
curl -s http://127.0.0.1:18597/sync     # videoList 含 Movie.mp4
# S3 暂态消除（tabId=200）：
curl -s -X POST http://127.0.0.1:18597/media -d '{"url":"https://h/list.m3u8","tabId":"200","requestHeaders":{"Referer":["R1"],"User-Agent":["UA"]},"responseHeaders":{"Content-Type":["application/vnd.apple.mpegurl"]}}'
curl -s -X POST http://127.0.0.1:18597/media -d '{"url":"https://h/seg/001.ts","tabId":"200","requestHeaders":{"User-Agent":["UA"]},"responseHeaders":{"Content-Type":["video/mp2t"],"Content-Length":["300000"]}}'
curl -s http://127.0.0.1:18597/sync     # .ts 未入 videoList
# S5 YT-DASH 配对（file=YT Video 两条同 id=oA）：
curl -s -X POST http://127.0.0.1:18597/media -d '{"url":"https://rr.googlevideo.com/videoplayback?itag=140&mime=audio%2Fmp4&clen=1000&id=oA","file":"YT Video","requestHeaders":{"User-Agent":["UA"]},"responseHeaders":{"Content-Type":["audio/mp4"]}}'
curl -s -X POST http://127.0.0.1:18597/media -d '{"url":"https://rr.googlevideo.com/videoplayback?itag=137&mime=video%2Fmp4&clen=2000&id=oA","file":"YT Video","requestHeaders":{"User-Agent":["UA"]},"responseHeaders":{"Content-Type":["video/mp4"]}}'
curl -s http://127.0.0.1:18597/sync     # audio 单源 '[MP4 AUDIO] 1000B' + dual '[1080p] 2.9K'
# 收尾：
%HDC% fport rm tcp:18597
```

## 6. VideoCapture 页人工走查清单（[H] 项，S7 种子后执行）

前置：探针 S8 会 /clear 清空视频表，故走查前从主机经 fport 18597 POST /media 种子（§5.2 命令，**正常模式冷启动后**由应用自身 8597 桥接收）。

1. 应用主页面 → 汉堡菜单 → **媒体抓取（Media grabber）**：进入视频捕获页（NavDestination，
   标题=媒体抓取；源 MainWindow.xaml:65 menuMediaGrabber → CreateAndShowMediaGrabber 同位）。
2. 分组四节可见：YouTube / Video / HLS / DASH 四组头（含空组；源平铺列表 → 分组呈现为增强差异
   设计书 §4-8）；S2~S7 的条目按表归组（Movie.mp4/Tone.aac/clip2.mp4/Regular.mp4 在 Video 组、
   YT Video.mp4+YT Video.mkv 在 YouTube 组、Stream.ts 在 HLS 组、Video.mkv 在 DASH 组）。
3. 两列呈现：Name（弹性）/ Quality（固定宽，=description，如 [MP4] 5.0M）；表头行 Name/Quality
   （xaml GridView :34-37 对照）。
4. 单选：点某行 → 行高亮+勾选态翻转（勾选序即 Download 下发序）。
5. 组头全选：点组头 → 该组全部勾选（再点全清）；恒显示组内计数。
6. Download：勾选 1 条后点 **下载** → 弹出「新建视频下载」窗为预期（U6.3 接管后与源同；2026-10-19 真机确认。
   旧口径「无弹窗」写于 U6.3 前对话框降级为 BridgeUiEvents 事件时）。
7. Clear：点 **清除** → 列表清空（tracker.clearVideoList+本地清空；/sync videoList=0 可复核）。
8. Close：点 **关闭** → pop 返回主列表（源 Window Close 同位）。
9. 降级确认：页面**无** "Always on top" 复选框、**无** "How to..." 外链（HarmonyOS 应用内
   NavDestination 无窗口置顶语义——设计书 §4-8 不渲染）。
10. 增量渲染：保持页面开着 → 主机侧再 POST 一条 /media（§5.2 命令）→ 页面实时出现新行
   （事件到达全表重渲染，源按 ID 增改的观测等价）。

## 7. 真实 HLS 测试流观测建议（U6.1 报告 §8-5，非本单元验收项）

U6.3 扩展栈就绪后用公共测试流实测（真机浏览器优先）：

- 测试流：`https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8`（公共 HLS master playlist）。
- 观测点：① .m3u8 请求被 ② 识别（业务 log 'hls manifest recognized (parser U6.4)'）+m3u8Tabs
  写入；② 同 tab 的 .ts 段不再误入 videoList（对照 U6.1 行为——暂态消除的浏览器真流量验证）；
  ③ .m3u8 页面 referer 进 referersToSkip（sha1 键）；④ U6.4 落 HlsParser 后 master 档位条目
  入 hls 表（本单元只有识别+两表写入，捕获页 HLS 组不出现解析条目为预期）。
- 兜底：无浏览器环境时用 §5.2 curl 序列模拟（已覆盖同一服务端路径）。

## 8. 回贴

把以下材料发给 AI，由 xdm-probe-verify 对照 `EXPECT-u6-2-sniff-rule-chain-video-capture.json` 逐步骤核对：
1. `probe-P6-U2.log` 全文（[XDM_PROBE] 行一律不要手工删改；多轮运行取最后 runId）。
2. Node 脚本 stdout 全文（65 例 PASS/FAIL + SUMMARY 行）——本会话已实跑 65/65 全绿。
3. 走查清单 §6 勾选结果（[H] 项，10 条）。
4. 双轨判定合并口径见 EXPECT 表 END 步 note：Node 用例轨全绿+探针轨全绿=运行时验收通过；
   捕获页走查为 [H] 人工项单独记录。
