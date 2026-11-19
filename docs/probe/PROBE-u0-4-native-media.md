# P0-U4 原生媒体探针

本探针执行实际 `libxdm_media.so`，使用 FFmpeg n6.0 / LAME 3.100 合并 MP4、转 MP3、
验证真实 MP4 不兼容时的 Matroska 回退、取消和队列清理。探针只记录观测事实，
判定见 [EXPECT-u0-4-native-media.json](EXPECT-u0-4-native-media.json)。

工程：`D:\git\HarmonyPC\XdmHarmony`；bundle：`com.neuohos.xdm`。
入口：启动应用的探针首页并选择“原生媒体”卡片（P0-U4），S1–S6 自动执行。
安装、签名、设备选择与启动沿用 [PROBE_SPEC.md](../PROBE_SPEC.md) 的现有流程。
先完成一次构建/安装，再运行探针；不要让两套构建并发。

## 前置条件

- HAP 包含所选设备 ABI 的 `libxdm_media.so` 及系统所需 C++ 运行库；实际 ABI 以 S1 为准。
- 原生本地类型依赖和 P0-U4 注册已纳入该 HAP。宿主机编译成功不能替代这一步。
- 探针期间保持页面在前台，避免同时运行生产媒体装配任务。全局原生队列忙会如实返回 busy。
- 沙箱留出约 15 MiB 用于测试输入、20 次结果和详细证据。重复执行各自使用新目录，不覆盖旧结果。
- 不需要联网、下载用户媒体或安装设备侧 FFmpeg。样本均来自数学信号/测试图案，CC0；
  打包的三个媒体文件共 121281 B，来源和 SHA256 在 `rawfile/native-media/manifest.json`。

## 自动步骤

| 步骤 | 实际操作 | 保存的证据 |
| --- | --- | --- |
| S1 | 读取 NAPI 版本/ABI/能力，复制并哈希三个样本 | 每个输入路径、字节数、SHA256 与能力对象 |
| S2 | H.264 视频 + AAC 音频合并为 MP4 | native result、文件大小、SHA256、MP4 |
| S3 | 44100 Hz 单声道 PCM 转 MP3 | native result、文件大小、SHA256、MP3 |
| S4 | H.264 + PCM 先直接尝试 MP4，再走实际封装器回退 | 失败结果、Matroska 结果、两处失败 MP4 的存在性 |
| S5 | 缺失/无效输入、已有目标；120 秒 PCM 作业运行中取消，另一个排队作业取消 | 错误代码、取消受理与结算状态、临时文件存在性、输入和已有目标不变性 |
| S6 | 连续 20 次实际 MP3 转码，结束后再观察 1200 ms | 20 个结果、心跳次数/间隔、完成后回调数、完成后查找/取消结果 |

S5 等到 native `processedTimeMs > 0` 后请求运行中取消（最多观察约 1 秒）。若设备过快或
调度延迟导致作业已提交，探针会如实记录 `activeAccepted=false` / `success`；此轮未覆盖到
运行中取消，不能把它解释为取消通过。由主流程检查环境、重跑或调整探针后重新留证。

离开页面时仅销毁该探针自己创建的 `MediaProcessorNapi`、取消其工作并清理计时器。
它不销毁下载器单例。每个 await 之后和发标记前都检查会话是否仍有效，旧会话不继续记录。

## 抓取与导出

每步一条 `[XDM_PROBE][P0-U4][S<n>]`，另有 BEGIN/SUMMARY/END。用主流程现有
devecocli/hdc 日志方式抓取完整标记，或读取 BEGIN 中 `filesDir` 下的 `probe-latest.txt`。
大段记录不写入 hilog；每步的 `detailFile` 指向完整 JSON。

完整证据位于：

```text
<filesDir>/native-media-probe-<epoch-ms>-<sequence>/
  video.mp4
  audio.m4a
  tone-44100-mono.wav
  S1-details-...json ... S6-details-...json
  remux-...mp4
  encode-...mp3
  fallback-...mkv
  repeat-...mp3
  long-input-...wav
  existing-...mp3       # 有意预置的非媒体哨兵，不能当作成功产物分析
  invalid-...bin
```

通过已经授权的设备文件导出方式保存整轮目录，并在 PC 上保留未经修改的标记和 JSON。
成功媒体的准确路径以各 JSON 的 `results[].outputPath` 为准；失败/取消结果该字段必须为空。
`existing-*.mp3` 是测试已有目标保护的哨兵文件，保持它原样是预期行为。

## 独立媒体核验

运行中未完成这些核验时，结论保持 UNVERIFIED：

1. 检查 S1 的 ABI 与实际设备、HAP 一致；输入文件 SHA256 与打包 manifest 一致。
2. 用可用且已验证的 ffprobe 读取 S2 MP4：H.264 160×96、AAC 44100 Hz 单声道，约 2 秒；
   各轨 DTS 单调。分别解码输出与视频/音频输入，比较视频帧哈希与 PCM，确认复制内容相等。
3. 检查 S3 MP3：44100 Hz 单声道；解码后约 1 秒，非零且有限的 PCM，主频约 440 Hz。
   按编码器延迟/尾部填充解释容器时长；不能只按文件大小判可播放。
4. 检查 S4：首个错误为 `UNSUPPORTED_STREAM`，最终 Matroska 有 H.264 与 PCM16 两轨；
   解码内容分别与原始输入相同。被拒绝的 MP4 文件不应残留。
5. 检查 S5 的错误/取消/清理观察与目录实物一致；三份输入仍匹配 SHA256，哨兵仍为
   `The existing output belongs to somebody else.`。长 WAV 应仍为原始 PCM 重复 120 次。
6. 检查 S6 的 20 个成功路径各自存在且大小匹配，输出可分析/解码；完成后无持续回调。
7. 在目标环境实际播放 MP4、MP3，记录能播放、音频可听、时长与内容无截尾/明显不同步的证据。
   Matroska 的容器核验与系统播放器是否支持它分别记录；系统播放器拒绝 MKV 不能替代检查文件。

已知主机工具情况：两个尝试过的 npm 静态 ffprobe 在当前 WSL 解析 TS 时会崩溃。
本轮有效分析器为从相同已验证 n6.0 源码编译的 ffprobe；复现入口见
[tools/native/README.md](../../tools/native/README.md)。分析器崩溃、仅 HAP 编译成功、
非零文件大小以及宿主机矩阵通过，都不能代替目标运行与播放证据。

## 分流与验收边界

- S1 无法加载模块：检查 HAP 两架构库、NAPI 注册名与本地依赖，归 native/integration。
- S2/S3/S4 媒体或参数不符：保留输入/输出/JSON，归 native；不可改写预期迎合结果。
- S5 接受取消但结果 success、删除输入/哨兵、残留自有 partial：归 native/queue。
- 页面离开后仍写标记、错误分支重复 emit、计时器持续触发：归 probe/wrapper。
- `END ok=true` 只表示脚手架完成；验收还须逐步匹配 EXPECT 与独立产物分析。
- 主机 Node Worker 退出回归已覆盖 NAPI 环境清理；真实 ArkTS Worker/正常环境关闭行为尚需目标环境
  的单独证据。P0-U4 页面退出只验证本页所有者的取消，不冒充整个 NAPI 环境已销毁。
  强制结束进程不会保证 cleanup hook 执行，遗留临时文件由下载器重启恢复规则处理。
- 下载器最终文件发布、冲突避让、完成事件和输入片段删除由后续装配集成负责；本单元不执行这些动作。
