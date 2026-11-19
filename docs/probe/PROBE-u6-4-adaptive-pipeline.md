# P6-U5 自适应流式下载与装配探针

此入口直接运行生产 `AdaptiveRcpStream`、`AdaptiveAttemptExecutor`、共享限速器、状态存储和 `AdaptiveAssembler`。六步分别观察真实 Range 下载、长时低速传输、停止后的封存前缀、精确前缀串接、双轨 Native 合并和失败收尾。目标状态为 **pending-device-run**；目前没有目标设备 PASS 记录。

## 准备与运行

1. 在 PC 的 `XdmHarmony` 目录启动固定数据源：

   ```powershell
   node docs/probe/P6-U5-adaptive-host.cjs --host 0.0.0.0 --port 18766
   ```

   默认仅监听 `127.0.0.1:18766`，适用于本机测试。设备填写可达的 PC 局域网地址，例如 `http://<PC局域网IP>:18766`；设备自己的 127.0.0.1 不能访问 PC。服务仅有 `/health`、`/bytes`、`/whole` 三种固定响应，不读取请求路径对应的磁盘文件。

2. 按 [PROBE_SPEC](../PROBE_SPEC.md) 构建、安装并用既有 `page=probe` want 进入探针索引。滚动选择“自适应流式下载与组装探针（P6-U5）”，填写数据源，点击“运行全部”，依次执行 S1—S6。S2 约需两分钟；期间保持本页。S4—S6 使用包内样本和自产文件，不依赖网络服务。
3. 保存同一次运行完整 BEGIN、S1—S6、SUMMARY、END 的原始 hilog，以及服务端响应日志。记录设备/ABI、API、HAP 哈希、时间和 runId。页面退出、SDK 迟迟未结算或清理异常导致的缺失日志应保留为实际结果。
4. 导出各步 `detailFile` 指向的文件及该步 UUID 目录，逐项对照 [EXPECT](EXPECT-u6-4-adaptive-pipeline.json)。`details-UUID.part` 内部是 UTF-8 JSON；后缀遵循 E2 的安全候选文件规则。详情文件包含写证据之前的资源检查结果；最终短行的 `cleanupComplete` 还覆盖证据文件自身的封存和排空。两者都需要核对。

## 步骤与事实

| 步骤 | 实际操作 | 关键判据 |
| --- | --- | --- |
| S1 | 两个 64 KiB BYTERANGE 片段同时经 E3 下载；E1 接收真实回执；C 保存并重新打开 | 请求范围 0—65535 与 65536—131071；两片 complete、字节和哈希一致；generation=1 |
| S2 | `/whole` 固定返回 200 和 512 KiB；共享限速为 4 KiB/s；需求空闲超时为 2 秒 | 60 秒时 attempt 仍未完成；最终 EOF、524288 字节和整体哈希一致；队列峰值不超过 65536 |
| S3 | 同类低速传输约 1 秒后停止；等待实际回执；保存并重开合法封存前缀 | timer 确实触发、stopped、前缀小于整体、complete=false、API 关闭、限速票据清零 |
| S4 | 输入物理内容为 `abcTAIL` 和 `defMORE`，两片各只提交 3 字节；真实 F 装配 | 输出恰好 `abcdef`，6 字节，Native 未启动；原文件和两个状态槽不变 |
| S5 | 包内 video.mp4/audio.m4a 每轨分成两片，经 E2/C 后交 F 串接并调用实际共享 Native 入口 | 两条串接轨道与包内样本哈希相同；成功输出、实际大小/哈希和媒体结算事实；导出后另验容器和解码 |
| S6 | 只移除新建夹具中的一个输入触发失败；另一独立夹具在首个串接进度回调中取消 | 缺失输入失败无可发布输出、其余输入和状态槽不变；取消 stopped、原输入不变、Native 未启动 |

网络测试内容为第 i 字节 `i % 251`，总长 524288。固定 SHA256：

| 数据 | SHA256 |
| --- | --- |
| 全部 512 KiB | `61d1d9c5745bdaa4fab39240651bc242a5186b15393fd475082fcf6e84f400ab` |
| 第一个 64 KiB | `4b640d85ab3ba30fd02c9fc9db4a8928f416322ad27022ea58a65aaee68a4df2` |
| 第二个 64 KiB | `fe89f108b4028dc360cbe69ce0ccbe4d9bc8af0123f731304b77327fd495a1f6` |
| `abcdef` | `bef57ec7f53a6d40beb640a780a639c83bc29ac8a9816f1fc6c5c6dcd93c4721` |
| video.mp4 串接轨道 | `a9031eb264daacdb12b8b5f09d28cddedb41e94c59bce3bc53d30a29cfcc2254` |
| audio.m4a 串接轨道 | `bc07711e61565df03d063be18af19e2fc1ae23f36ea2845a41f21a1393ddb138` |

S3 的已写字节随时序变化，应按实际 `p0Bytes` 独立生成该长度的 pattern 并核对导出文件，不能要求某个固定前缀长度。SDK 已接收字节可能多于已写入、已封存字节；只有 C 重开后承认的前缀可以用于恢复。

## 所有权与结果解释

每步创建 `filesDir/probe-adaptive-pipeline-UUID/` 和新的 downloadId；所有 C/E2/E3/限速/F 对象在开始异步工作前登记。离开页面会取消该 owner 的工作，等待实际 IO/Native 排空；旧 token 不再写证据或发日志。gate 在其 executor 排空后释放，共享媒体单例继续由原服务管理。封存文件、轨道和验证过的 Native 输出保留用于导出，探针不递归清理目录。

关闭失败、未知 fd 状态或未验证的 Native 残留会令 `cleanupComplete=false`，并停止该 owner 后续业务 IO/证据写入。对已接受的资源仍执行必要清理；不把 `dispose()` 返回当作排空证明。失败可能没有 detailFile，不能用 SUMMARY 或 END 补出成功结果。任一步出现 `err`/`errCode`、缺少必要文件或最终清理不完整，该步不能通过。

S1 的 `a0RequestStart/End` 是请求窗口；Executor 不公开响应头，探针不会把它们写成实际响应 Content-Range/status。响应 206/200 由固定服务端日志另证。`aNApiClosed`、`aNFetchSettled`、`aNEof` 是三种不同事实。S2 的 `attemptPendingAt60` 仅表示 attempt 尚未完成，不证明同一时刻 SDK fetch Promise 未结算；终值字段另行记录。

S5 使用实际目标 Native 入口，导出的输出仍须用 ffprobe 确认视频/音频轨道，并完整解码或目标播放。扩展名可能为 `.mp4`，或既有允许回退路径的 `.mkv`；实际输出哈希照录，不以主机生成文件哈希替代目标输出。失败的未验证输出不删除、不称为成功产物。

主机 `adaptive-pipeline-probe.test.cjs` 使用真实生产探针、FS 和 HTTP，S5 的 Native 边界受控；实际 Native/FFmpeg 解码由独立 `adaptive-assembler-native.test.cjs` 验证。两组证据都不替代 HarmonyOS RCP/fileIo/ArkUI 的目标运行。本入口尚不包含 E4 RunController、完整 HLS 下载发布、DownloadManager 完成事件或 DASH。
