# P6-U6 自适应运行控制器与装配租约

本探针运行真实 `AdaptiveRunController`、状态存储、流式下载与 `AdaptiveAssembler`，观察运行、暂停/恢复、ready 目录权限及外层读者收尾。目标状态 **pending-device-run**。主机用例执行生产会话和真实 Node 文件/HTTP，不能代替 HarmonyOS RCP、fileIo 或 ArkUI 的运行验收。

## 运行与证据

1. 在 PC 的 `XdmHarmony` 目录启动已存在的固定数据源：

   ```powershell
   node docs/probe/P6-U5-adaptive-host.cjs --host 0.0.0.0 --port 18766
   ```

   服务数据为 524288 字节，第 i 字节为 `i % 251`。`/bytes` 支持真实单区间 Range。保留服务端每个 GET 的 Range、状态、起止位置和关闭记录。多个步骤/运行使用同一服务时，必须按执行时间分段，不能混合统计请求。

2. 使用已记录 HAP、设备与 runId，按 `docs/PROBE_SPEC.md` 启动 EntryAbility 的 `page=probe`，进入 **P6-U6**。填写设备可达的 `http://<PC局域网IP>:18766`；设备自己的 127.0.0.1 不是 PC。页面不自动开始网络请求，点击现有探针页的“全部运行”。保留完整 BEGIN→S1—S4→SUMMARY→END 原始日志。
3. 导出每步短行 `detailFile` 指向的 JSON `.part`。其中包含完整 facts、本步 UUID 根目录、runId 与 sessionToken。短行与文件事实应一致，最终 `cleanupComplete` 以证据写完后的短行为准；不得仅依据 `END ok=true` 接受步骤。记录设备/OS/API/ABI/HAP SHA256 和运行时间。

## 四步观察

| 步骤 | 实际操作 | 必须另核的证据 |
| --- | --- | --- |
| S1 | 两个 64 KiB BYTERANGE 经 E4 下载并取得 ready；同目录第二次 run 被拒绝；attach 实际 F，串接和哈希后释放；新 controller 从完整 C 状态恢复 | 131072 字节输出与固定哈希一致；原 part/两槽不变；服务端本步只收到两次 206，恢复没有新 GET；两份实际 lease 均成功释放 |
| S2 | 512 KiB 单片以 4 KiB/s 开始，约 1 秒 timer 调 pause；等实际 durable paused/released，读取旧封存前缀；新 run 恢复并经 F 输出完整文件 | timer 确实触发；旧前缀大小按实际值记录；第二次 GET 从 `pausedP0Bytes` 开始；旧 part 哈希保持不变；最终完整 pattern/hash 一致 |
| S3 | ready 后先 pause，再尝试 attach，最后 drain 和 release | attach=false，F 未开始，stopRequested=true；drain 仍是原 ready/heldForAssembly 快照；第一次 release=true，第二次=false |
| S4 | ready 后 attach F；记录输入和两槽指纹；重复 attach 被拒绝；首个真实 concat 进度回调 pause E4，租约通知取消 F | F 实际停止并关闭，通知恰好一次，Native 未开始；E4 drain 保留原 ready；读者真正结束后释放；导出文件另证原输入与槽不变 |

S2 首轮应有 `0 <= pausedP0Bytes < 524288`，`pausedP0Complete=false`。非零长度受时序影响；若 `nonzeroPrefix=false`，只证明零前缀恢复，**非零断点恢复仍未验证**，不能把该子项写 PASS。未触发 timer、直接 ready 或无合法 durable state 都与本步骤要求矛盾。

S4 的 `inputDirectory`、`beforeName0..3`、`beforeSha256_0..3` 位于完整 details，避免 1500 字节短行截断。导出这四个文件，在 PC 比较 SHA256；探针在收到停止后不再发起新的 hash 读取。不能将外部比较结果改写为探针已自行观察的字段。

固定哈希：

| 文件内容 | SHA256 |
| --- | --- |
| 前 131072 字节 | `feb1e4409d009e0ec502eaabe321f86b5197a881e9b765252ec8a75d6957596d` |
| 完整 524288 字节 | `61d1d9c5745bdaa4fab39240651bc242a5186b15393fd475082fcf6e84f400ab` |

## 生命周期和验收边界

每步创建独立 `filesDir/probe-adaptive-controller-UUID/` 根。E4 目录用 downloadId，证据位于另一个 evidence UUID 目录；不会在已归还或隔离的 E4 目录内新建证据。所有已返回的 ready 权限都先认领再检查页面/token；重复 run/drain 的 DTO 共享同一个 capability，按其引用去重。

E4 `drain` 只覆盖控制器本身。它返回 ready 不意味着 F 或哈希读取已经结束；外层必须等所有实际读者和证据 IO 结束再 release。主机测试另行卡住真实 F read，验证 E4 drain 已返回而新 owner 仍被拒绝，释放 IO 后才归还 lease。目标四步只报告实际观察，不伪造这一精确受控时序。

离开页面取消本步对象和 timer；旧 owner 继续完成实际收尾，但不再发布短行或 detailFile。失败 close 不重试，也不删除未确认拥有的文件；未知资源/不完整 F 清理将隔离目录，`cleanupComplete=false`，停止后续业务与证据 IO。保留文件便于导出，不递归删除探针根或业务数据。

本入口不承担正常 HLS 创建/选择、DownloadManager 接线、最终沙箱发布/数据库完成 ACK 或 DASH。E4 当前约 2 秒 checkpoint 只持久化已封存部分，长分片仍在下载时的崩溃损失范围大于源项目 live-prefix 行为；本探针不宣称已消除这项差距。固定二进制 pattern 不是媒体，不用于证明播放能力。
