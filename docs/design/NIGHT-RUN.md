# 夜间运行台账（2026-09-27 夜）

> 模式：用户睡眠，AI 全自动接力。每个工作流运行完成后：git 提交该单元 → 启动下一单元。串行执行（同一工作区+构建门禁，禁止并行运行）。
> 探针/真机事项全部推迟到晨间，由用户执行（见文末清单）。

## 夜间序列（关键路径，全部无需真机）

| 序 | 单元 | 状态 | 提交 |
|---|---|---|---|
| 0 | U0.1 基座+探针基建 | ✅ 完成（含 COLD-F1 修复） | 0687ee1 |
| 0.5 | U0.2 HTTP 能力探针 | ✅ 完成（两轮审查；独立复核 medium「dataEnd 无超时挂起」已由主会话修复并重过编译门禁） | 本次提交 |
| — | U0.5 平台调研 | ✅ 完成（befa818；要点：rcp 支持跳过 TLS 校验但**无分块流回调**——研究员初步倾向 http 主栈、rcp 退化备选，晨间探针定案） | befa818 |
| 1 | U1.1 数据模型+存储+配置 | ✅ 完成（三轮审查修复 runId 同秒撞号；主会话补 add() completed 强制防御与设计文档同步） | 本次提交 |
| 2 | U1.2 单线程下载+主列表+对话框 | ✅ 完成（M1 里程碑：20 文件；审查修复 2 high+3 medium；主会话再修 2 个复核遗留 medium：END_GATE 改空闲超时、timesRetried 每次启动重置；另修 URL trim 与设计文档 D19-D21 差异入账） | 本次提交 |
| 3 | U2.1 PieceGrabber+SegmentWorker | ✅ 完成（中途撞 5h 配额上限、重置后自动恢复走完；审查修复 2 high+2 medium；主会话补修探测消息互逆次序挂起（复核 medium）） | 本次提交 |
| 4 | U2.2 分片落盘+断点续传 | ✅ 完成（切模型后续跑顺畅；R1-F1 同实例预探测钉死修复；主会话清理 nul） | 本次提交 |
| 5 | U2.3 引擎保真度单测收口 | ✅ 完成（hvigorw test 打通：117 条用例实跑全绿；四大缺口补齐；保真度矩阵 46 项回填 ✅39+⚖️5+⛔2；**Phase 2 收口**） | 上次提交 |
| 6 | U3.1 队列调度+并发上限 | ✅ 完成（DownloadManager 双集合调度器+QueueAlgo 纯函数+10 条单测+P3-U1 探针；审查修复 2 个探针假 FAIL 缺陷；4 路并行研究首秀提效明显） | e9ee69e |
| 5 | U2.3 引擎保真度纯函数单测 | 待启动 | |
| 7 | U3.2 限速+重试+定时 | ✅ 完成（SpeedLimiter 数学逐字+SegmentWorker 限速开环+Scheduler 60s 状态机+26 条新用例累计 153；主会话修复启动分钟竞态吞调度窗；**Phase 3 收口**） | 3af73ed |
| 8 | U4.1 主窗口框架 | ✅ 完成（工具栏状态机/分类树/LazyForEach 数据源/35 条单测/P4-U1 走查探针；主会话修复幽灵选中+走查文案） | 2dcf823 |
| 9 | U4.2 对话框包 | ✅ 完成（八对话框+触发链接线+19 条单测累计 207；审查修复右键定位/预览误弹/完成窗门；主会话修复 Now-Later 颠倒+完成窗单飞） | 1047748 |
| 10 | U4.3 设置页+i18n+主题 | ✅ 完成（Config 47 键全表+五页签设置窗+中英资源 191 键对齐+语言/主题切换+P4-U3 探针；主会话修复分类列表 ForEach 键编辑不刷新；**M4 达成，Phase 4 收口**） | 76a6e7d |
| 11 | U5.1 后台长时任务+通知 | ✅ 完成（dataTransfer 长时任务+实况窗通知+关窗拦截继续下载+P5-U1 后台存活探针；主会话修复 apply/release 异步窗口失同步） | 9874c9a |
| 12 | U5.2 剪贴板+保存目录 | ✅ 完成（ClipboardWatcher 三重过滤链+SaveDirectory 文件能力+StateStore.removeById 收口+16 条单测累计 257；审查修复 kind 门会话内失效；**M5 达成，Phase 5 收口**） | 2cf4234 |
| 13 | U0.3 扩展桥服务端 | ✅ 完成（BridgeProtocol 字节级解析+BridgeServer 8597+八路由骨架+/sync 应答+37 条单测累计 293；审查修复解析失败分支死代码） | cd060a3 |

**链子暂停于 U0.3**（用户转入探针验收，2026-10-03）。剩余待跑：U6.1~U6.4、U7.1~U7.3。夜间总战果：26 提交、17/24 单元、293 条单测、14 个待验收探针、M1~M5 全部达成。
| 8 | U4.1 主窗口框架 | 待启动 | |
| 9 | U4.2 对话框包 | 待启动 | |
| 10 | U4.3 设置页+i18n+主题 | 待启动 | |

推进到 U4.3 或用户醒来为止。U0.3（桥服务）按敏捷计划仍在 U6.1 前；U0.4（ffmpeg）人工主导仍延后。

## 异常处置策略

- 运行停滞（network_error 重试）：等待，系统自动退避重试，不干预。
- 运行 errored：AmendWorkflow 修复脚本接缓存续跑。
- 运行 stopped(provider/user)：查明原因后续跑（ResumeWorkflowRun）。
- 每单元完成先核对：gatesOk=true 且结论无"不可构建"字样才提交。

## 晨间清单（用户，约 20 分钟）

1. 一次性签名：真机开 USB 调试连接 → `devecocli auth login` → `devecocli signature generate --product default`
2. `devecocli run --module entry` 装包 → `hdc shell aa start -b com.neuohos.xdm -a EntryAbility --ps page probe`
3. 探针首页依次跑 P0-U0（环境自检）与 P0-U2（HTTP，需先按手册起本地测试源 `npx http-server -a 0.0.0.0`）
4. 抓日志：`"D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" shell "hilog -x | grep XDM_PROBE" > probe-night.log`，全文发回对话
5. AI 批量核对（xdm-probe-verify 一次验多个单元）→ U0.2 栈选型结论定案 → 决定 U1.2 传输层是否改 rcp
6. Phase 0 出口确认 + `git tag phase-0`

## 会话间补录（2026-10-08，其他 agent 完成，经主会话盘点确认）

| 单元 | 内容 | 状态 |
|---|---|---|
| P2-U2 返修 | 慢滴流源零字节引擎缺陷修复（HttpClient/HttpProtocol/PieceGrabber/SegmentWorker 等核心文件返修）+P1-U2/P2-U2 探针文档修订+S5 异步记账分歧收口 | ✅ 工作树待提交 |
| U6.3 浏览器接管 | extension/ 复制改造+BridgeInbox+LinkRefresher+DownloadCreationService+model 三件（CreationRequest/RequestContext/RunRequest）+P6-U3 link-refresh 探针 | ✅ 设计/报告/探针齐 |
| U6.4 HLS | core/adaptive/ 14 文件（HlsParser/HlsModel/HlsUrlResolver/ManifestClient/AdaptivePlan/Protocol/Scheduler/RunController/Assembler/AttemptExecutor/AttemptFile/Throttle/StateCodec/RcpStream）+AdaptiveStateStore+P6-U4 三探针（foundation/pipeline/controller）+两个主机 cjs | ✅ 设计/报告/探针齐（remux 走降级分支） |
| U0.4 native media | core/media/MediaProcessorNapi+rawfile/native-media+tools/native+P0-U4 探针 | ✅ 设计/报告/探针齐（ffmpeg 集成完成！U6.4/U7.2 remux 依赖解除） |
| Hypium 真值门禁 | scripts/run-hypium.cjs+HYPIUM_GATE.md——发现 hvigor test 假绿问题（退出 0 但断言失败被吞，实测 r2 有 5 例），包装脚本以结果文件为准 | ✅ 基建（此前全绿结论需按此口径复核） |

单测总数 569 条（421→569：HLS 37+AdaptivePlan 32+AdaptiveProtocol 34+AdaptiveScheduler 34+DownloadRequestContext 9+VideoSniff 56+增量）。

## 会话间补录（2026-10-12~15，主会话：包名更名批次+无真机收官批次）

| 事项 | 内容 | 状态 |
|---|---|---|
| 包名更名（2026-10-12） | bundleName `com.example.xdmharmony` → `com.neuohos.xdm`（vendor→neuohos）：AppScope/app.json5、ProgressNotifier wantAgent、运行文档命令；旧签名材料随改名作废，build-profile signingConfigs 清空待重签（提交 26e12e3；DELIVERY E 节第 5 条登记流程） | ✅ 已提交 |
| 权限结论更正（2026-10-15） | 26e12e3 提交说明「4 权限均开放」有误：INTERNET/KEEP_BACKGROUND_RUNNING/PREPARE_APP_TERMINATE 为开放权限，**READ_PASTEBOARD 为 ACL 受限权限**须 AGC 申请（被拒则降级 PasteButton）；提审材料全量落在 docs/delivery/AGC-SUBMISSION.md | ✅ 已定论入档 |
| U6.2 IR-F1/F1 修码（2026-10-15） | processNormalVideo 登记改传 tabUrl=''（镜像源不设 TabUrl）+ dispatchArgs 缺 --media-tab-title 键整体中止（镜像源 KeyNotFoundException 吞→零改名）；+2 回归用例（BridgeConvergence 组尾）；门禁 642/642 全绿（首跑 1 error 为用例 /args body 格式笔误，真值 wrapper 拦截实证价值）；开放 medium 至此清零 | ✅ 本批次提交 |
| 探针手册包名清扫（2026-10-15） | 15 个 PROBE-*.md 全量 sed 为新包名（0 残留实测）+probe-page.png 意外入库截图删除 | ✅ 本批次提交 |
| DELIVERY/README 收官刷新（2026-10-15） | 单测口径 640→642（A.1/F.3/README）、IR-F1 移入 D 档1、开放 medium 清零声明、F.4 签名条目按改名后状态重写、E 节第 6 条权限更正、H 附录加时点注记、晨间清单旧包名修正 | ✅ 本批次提交 |

**当前挂起（需真机/AGC，用户侧）**：① 设备连接重跑 signature generate（新包名 Profile）→ release 重建 → E 节重登记；② AGC 提交 READ_PASTEBOARD ACL 申请+创建应用 com.neuohos.xdm；③ 探针会话#2（P7-U1 三探针+新增 7 个+P2-U2 返修复验+4 走查+OPT-1 深色观测）；④ Phase tag phase-0~6。无真机可做的工作至此全部完成。

## 真机重签批次（2026-10-17，设备已连接）

| 事项 | 结果 |
|---|---|
| signature generate（新包名 Profile） | ✅ signingConfigs 自动回填；工具链提示 READ_PASTEBOARD 受限权限「随 app release 一同审核」——印证 E 节第 6 条更正结论 |
| release 重建 | ✅ BUILD SUCCESSFUL 3 min 19.8 s；signed 8,972,414 B / sha256 ff8294…308；pack.info bundleName=com.neuohos.xdm、Release、compatible23/target24、21 条目（release 判别特征） |
| 真机装包+启动冒烟（F.2） | ✅ install bundle successfully + start ability successfully（MateBook Pro 3QC0124B11000092，API23 compatibleSdk 终验过；**ACL 声明随调试 Profile 装包不拒**）；坑：hdc 传 HAP 须自工程根相对路径，绝对路径会被双拼报 no such file |
| E 节登记 | ✅ 第 7 条新包名终局指纹表接替 11:08 旧表（旧表降级历史记录）；F.1 前提/F.2 执行记录/F.4 第 2 条/A.1/H 注记同步刷新 |

**挂起转移至用户侧**：探针会话#2（手册包名已更新，装的就是本次产物，可直接 `aa start -b com.neuohos.xdm -a EntryAbility --ps page probe`）→ 回贴日志批量核对；AGC（READ_PASTEBOARD ACL 申请+创建应用+显示名定稿）；Phase tag phase-0~6。

## 探针会话#2 批次（2026-10-18，真机，AI 经 uitest 自动驱动）

| 事项 | 结果 |
|---|---|
| 自动可跑单元判定 | ✅ 12 个待验单元 + 4 个引擎回归全部判定（PROBE-SESSION-ALL 会话#2 段；证据 probe-session-2026-10-18.log） |
| 产品缺陷修复 5 项 | ✅ 慢源零字节根因（HttpClient）/长时任务 401（ProgressNotifier）/清单 302（ManifestClient→rcp）/rcp 头序配对/rcp 队列溢出丢字节（AdaptiveRcpStream）——均真机插桩取证、修后复跑 PASS |
| 探针与 EXPECT | ✅ 探针缺陷 2 项已修；EXPECT 按源语义修订 4 份（u6-1/u6-4-pipeline/u7-1-dash-pipeline/u7-1-dash-controller）+ executionStatus 更新 |
| 门禁 | ✅ Hypium 642/642（终版）；主机套件 599/0/5（修复 U7.1 起 adaptive harness 缺 DashModel 依赖） |
| 交付物 | ✅ release 重建 + 真机冒烟，DELIVERY E 节第 8 条终局登记（signed 8,977,881 B / 7b910918…fd25） |

**挂起（用户侧）**：P4-U1/P4-U2/OPT-1 人工走查、P5-U2（授权弹窗）、P6-U2 捕获页 [H]、P0-U4 产物播放、P7-U1 公共流；AGC 提审；Phase tag 与 probe/ 移除（G 节 #1/#4）。
