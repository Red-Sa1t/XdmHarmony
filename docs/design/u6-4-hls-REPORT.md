# U6.4 HLS 基础模块迁移报告

2026-10-09：A解析器、B计划/状态codec、C异步状态IO、D有界清单GET、E1协议/纯调度、E2候选文件、E3流式执行/限速、F装配及P6-U4/P6-U5已经编译、测试并通过独立审查及冷复核。E4运行控制器与P6-U6已通过主机检查，新的SDK集成验收正在进行。完整HLS业务接线、最终媒体发布和设备播放尚未完成。

业务文件为 `core/adaptive/HlsModel.ets`、`HlsParser.ets`、`HlsUrlResolver.ets`、`AdaptivePlan.ets`、`AdaptiveStateCodec.ets`。另含对应host/Hypium测试和List注册，共10项集成文件，精确SHA256在工作区 `migration-runs/202610080259/adaptive-integration-prebuild-r3.json`。[设计](u6-4-hls-DESIGN.md)区分当前实现和后续契约。

| 验证 | 结果 | 运行目录证据 |
| --- | --- | --- |
| 最终应用构建 | 实际CompileArkTS、打包、签名成功 | `build-native-adaptive-r3.log/.exit` |
| 实际Hypium门禁 | 501/501 = 原432 + HLS37 + Plan32；failure/error/ignore0 | `hypium-native-adaptive-r3/2026-10-08T06-44-32-692Z-ad6c3527-01a5-4e69-8894-b80d21fbb768/verdict.json` |
| Parser生产源码host | 53/53；独立复跑及9项附加回归通过 | `u6-4-hls-parser-independent-review.md` |
| Plan/codec生产源码host | 34/34，包括执行32个实际Hypium测试体 | `u6-4-hls-plan-independent-review.md` |
| 源算法枚举 | 30,705分区比较、2,047进度比较、100项parser→plan | 同上 |
| 新鲜冷复核 | 高0/中0/低0；最终43/43，含12种合法IPv6对照 | `u6-4-hls-cold-review.md`、`hls-cold-files-r2.json` |
| 最终源码核对 | 10项与最终构建前清单一致 | `integration-r3-source-verification.json` |

运行目录为 `migration-runs/202610080259/`。独立评审曾发现并关闭delta语义、变量处理、累计展开预算、并行上界、状态真值表和文件名唯一性问题；冷审补充三种非法IPv6边缘形式，最终最小修复保留全部合法形式。原始反例和前序结果保留。

综合host r2为179/179；之后仅B IPv6门修改，已用最终B34、冷审43和全501 Hypium验证，没有将旧179项重新标为新跑。完整目录辅助lint r2报告0error/7warning/2suggestion；Plan单文件r3返回0issue但filesChecked=0，不作为覆盖结论。

以上是已接受A/B版本的历史集成证据。后续C/D/P6-U4批次新增 `AdaptiveStateStore.ets`、`ManifestClient.ets`、`ProbeAdaptiveFoundation.ets`、对应host/wire测试、固定HTTP源、注册资源及探针文档。最终13文件指纹为 `u6-4-adaptive-foundation-cold-files.json`。

| C/D/P6-U4 验证 | 结果 | 运行目录证据 |
| --- | --- | --- |
| 实际应用构建 | exit0，CompileArkTS/打包/签名；三个新模块均有编译产物 | `build-adaptive-foundation-r1.log/.exit` |
| 最终Hypium | 501/501，严格逐项门禁接受，无failure/error/ignore | `hypium-adaptive-foundation-r2/2026-10-08T08-16-26-760Z-9679a603-7ef0-4108-ad05-c913811f6823/verdict.json` |
| 综合host | 259/259 = 原179 + C40 + D31 + wire9 | `host-adaptive-foundation-r2.log/.exit` |
| 独立实现审查 | 高0/中0/低0待处理，独立99/99；含324次IO边界取消场景 | `u6-4-adaptive-cd-independent-review.md` |
| 新鲜冷复核 | 高0/中0/低0待处理，新增10/10生产源码/真实文件/loopback回归 | `u6-4-adaptive-foundation-cold-review.md` |
| 辅助lint | 0errors/7warnings/2suggestions，6个finding文件；不是零warning构建 | `lint-adaptive-foundation-r1.json` |
| 最终来源核对 | native296、probe20、A/B10、本批13全部匹配 | `adaptive-foundation-final-source-verification.json` |
| 签名HAP静态检查 | 10,696,289字节，两ABI/libc++及fixture检查通过 | `hap-adaptive-foundation-r1/verdict.json` |

独立与冷审计数不再加到综合host的259项。冷审仅发现一处手册写了不存在的单步按钮，已改为实际“运行全部”入口；最终12文件保持原hash，只有该文档一行改变，无运行代码变化，因此没有重复SDK构建。

Hypium foundation r1因Previewer的GC/JSAPP输出交错污染class名而被严格门禁拒绝，虽然其内存汇总为501/501。原始stdout、结果和失败verdict完整保留；独立调用实际SDK提取器在内存逐字节复现。未改产品、测试、SDK或gate的单次新执行r2通过，详见 `hypium-foundation-r1-investigation.md`。r1没有被事后“修正”为通过。

C最大20,000片快照同步捕获在主机约1.8至2.4秒，后续必须合并保存。C队列仅保证同主线程域内串行，不声称跨进程排他；D跨origin凭据剥离是明确的目标策略。HAP SHA256为 `880bf0a044d7914ad842423e3fe338fc51537890be96eaeadb09c58c7e82e8bb`，原生二进制与之前接受的r3一致，更多原生范围见 [原生报告](u0-4-native-media-REPORT.md)。

E1/E2及P6-U4 S5/S6的最终12文件范围见 `u6-4-adaptive-attempt-cold-files.json`。新实现为AdaptiveProtocol、AdaptiveScheduler、AdaptiveAttemptFile，另含三份host、两份Hypium测试、List注册及probe/两文档。S5的HTTP头/接收数/EOS明确为合成输入，文件与状态接线使用实际产品模块。

| E1/E2/S5/S6 验证 | 结果 | 运行目录证据 |
| --- | --- | --- |
| 实际应用构建 | exit0，真实CompileArkTS/打包/签名；四模块12项编译产物 | `build-adaptive-attempts-r1.log/.exit`、`adaptive-attempts-compiled-artifacts-r1.json` |
| 实际Hypium | 569/569 = 原501 + Protocol34 + Scheduler34；failure/error/ignore0 | `hypium-adaptive-attempts-r1/2026-10-08T09-21-10-185Z-e7b1a10f-5faf-47a7-bc23-e03cf5838302/verdict.json` |
| 作者host与独立复跑 | E1 43/43；E2 100项为98pass/2文件symlink权限skip，0fail | E1/E2作者报告、`review-adaptive-attempt-unit-r1.json` |
| 独立实现审查 | 高0/中0/低0待处理；新增20/20，含376个内部IO取消场景 | `u6-4-adaptive-attempt-independent-review.md` |
| 新鲜冷复核 | 高0/中0/低0待处理；新增8/8一次通过 | `u6-4-adaptive-attempt-cold-review.md` |
| 辅助lint | 0errors/7warnings/2suggestions，6个finding文件，均不在本批12文件内 | `lint-adaptive-attempts-r1.json` |
| 最终源绑定 | 历史依赖加当前批次346个独立文件匹配；四处旧版本明确替换 | `adaptive-attempts-source-verification-r1.json` |
| 签名HAP静态检查 | 10,882,068字节，两ABI/libc++与夹具检查通过 | `hap-adaptive-attempts-r1/verdict.json` |

本批HAP SHA256为 `b8b00936a9e5957bb3682a2713b812bc820b7983b8001e72456b48183a7d7fea`；Hypium新结果SHA256为 `5bc26e6248cdfda368813dd97b75261231f1f417f0b157c3496b8c186c0b4ff1`。作者143项、主审新增20项、内部376场景、冷审8项和569个Hypium分别计证，没有混加。两个文件symlink跳过项仍未验，实际目录junction有主机覆盖。实际编译仍有may-throw提示，辅助lint零error不代表构建零warning。

这些历史结果不证明HarmonyOS目标网络/文件系统的实际探针、物理掉电恢复、设备续传或媒体播放；P6-U4 EXPECT仍待设备运行。E3/F与C资源修复的后续验收记录如下。

| E3/F/C/Media/P6-U5 验证 | 结果 | 运行目录证据 |
| --- | --- | --- |
| 实际应用构建 | exit0，CompileArkTS/打包/签名；9个可达模块27项编译产物 | `build-adaptive-pipeline-r1.log/.exit`、`adaptive-pipeline-compiled-artifacts-r1.json` |
| 实际Hypium | 569/569，failure/error/ignore0，child0，issues为空 | `hypium-adaptive-pipeline-r1/2026-10-08T11-50-06-975Z-e78d7523-3e0a-4eaf-ab3d-0444c91a9b7f/verdict.json` |
| E3独立主审 | 接受，高/中/低0；最终85/85、真实约120秒慢流及5项额度修复对照 | `u6-4-adaptive-stream-backend-implementation-review.md`、`u6-4-adaptive-stream-sdk-binding-review.md` |
| F独立主审 | 接受，高/中/低0；65项host与5项真实native检查通过 | `u6-4-adaptive-assembly-implementation-review.md` |
| C与Media修复 | C独立18/18并复验既有集成20/20；Media取消12/12 | `u6-4-adaptive-c-resource-fix-review.md`、`u6-4-media-fallback-cancel-fix-review.md` |
| P6-U5独立主审 | 实际pipeline9/9、marker5/5、资源边界4/4 | `u6-4-adaptive-stream-assembly-probe-implementation-review.md` |
| 新鲜冷复核 | 接受，高/中/低0；新增7/7真实FS/HTTP及控制边界 | `u6-4-adaptive-pipeline-cold-review.md` |
| 辅助lint | 0errors/8warnings/2suggestions，7个finding文件；仍有编译may-throw提示 | `lint-adaptive-pipeline-r1.json` |
| 冻结与来源核对 | 本批26个变化文件、364个独立当前依赖；旧材料保留历史版本 | `adaptive-pipeline-prebuild-r1.json`、`u6-4-adaptive-pipeline-cold-verification.json` |
| 签名HAP静态检查 | 11,242,197字节，两ABI/libc++和三份样本完整 | `hap-adaptive-pipeline-r1/verdict.json` |

该批HAP SHA256为 `468f0a3eb34c109f4b5f729a20407b10eff437b86eefd46f82a453d103068527`。冷复核另核对完整784项材料清单；材料数、测试内场景、作者复跑与新增测试分别计证，没有相加。已关闭问题包括准入前clock失败泄漏额度、未知close处理、取消后继续fallback，以及native失败后的未核实输出残留。原始反例和被替代源码证据保留。

E4源与主机主审接受，高/中/低0；作者41项独立复跑及17个新增成立场景见 `u6-4-adaptive-orchestrator-implementation-review.md`。P6-U6作者18/18、独立18/18已完成，注册和后续SDK证据属于新12文件批次，不能借用上表作为E4编译通过结论。

仍须完成真实约2秒live-prefix持久化、业务请求/双源选择、最终沙箱发布、Store完成ACK及Manager/UI链路。当前sealed-only保存与源live保存的崩溃恢复窗口存在明确差异。DASH目前仅完成源与SDK XML接口研究。最新设备列表为空；全体目标探针、实际浏览器接管、目标解码/播放仍未验。
