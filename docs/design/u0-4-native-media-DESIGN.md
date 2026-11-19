# U0.4 / U7.2 原生媒体处理设计

当前实现提供本地文件 remux、MP3 转换、进度查询和取消。目标依赖为 FFmpeg n6.0 与 LAME 3.100，包含 arm64-v8a、x86_64；应用集成和主机验证已经完成，目标运行验收另见报告。

## 对照与接口

只读参考 `resourses/xdm/app/XDM/XDM.Core/Downloader/MediaProcessor/FFmpegMediaProcessor.cs` 及 BaseMediaProcessor。原外部命令面收敛为 `MediaProcessorNapi.remux`、`remuxWithFallback`、`toMp3`、`cancel`、`progress`。媒体核心位于 `entry/src/main/cpp/media/`，`napi_init.cpp` 桥接，`core/media/MediaProcessorNapi.ets` 管理 ArkTS 队列。

输入限普通本地文件。双轨先由下载器按轨拼接，再交给原生层；原生层不下载、不删除输入、不发布到用户目录。调用者显式提供独立临时输出路径和 fallback 路径，不能以输出扩展名猜测成功格式。

remux 使用 stream copy，保留流映射、DTS、不同起点及不等长尾部。MP3 使用 decode/resample/FIFO/libmp3lame encode，冲刷解码、重采样和编码尾部。MP4 真实容器不兼容时允许使用单独的 Matroska 路径；取消或 IO 错误不会任意变成格式回退。

## 所有权与并发

ArkTS 单实例 FIFO 为一个活动任务加最多十六个等待任务。原生注册表跨环境限制活动处理，jobId 绑定取消和进度。NAPI 使用受限原生线程、一个完成 TSFN 和异步环境清理；`napi_closing` 不再重复 release。最终释放等待线程退出后回收状态，不访问已销毁 JS 环境。

原生以 fd-backed AVIO 读写。输出由本次调用独占创建，完成时校验路径仍指向所打开文件的 device/inode/size；替换、删除、重命名导致错误并保留外部替换文件。提交后的取消不伪造失败，输入不参与清理。最终发布及下载片段回收由后续下载器提交协议负责。

## 格式边界

无视频解码器的 TS 输入通过受限公共 parser 补齐 H264/HEVC 尺寸，并回放全部保留包。PNG/JPEG attached picture 通过有界实际头部解析得到尺寸；不宣称解码并验证任意图像像素。支持的封面用于 MP3/容器写入，异常或不支持的可选 MP3 封面产生固定警告。章节复制尚未实现，发现章节时返回 `CHAPTERS_NOT_COPIED`。

Matroska 的 AAC priming 行为与源等价 FFmpeg CLI 一致：相关用例相对 M4A 解码多1024样本，报告保留差异，未额外裁剪。依赖许可证、来源、哈希和构建脚本位于 `entry/src/main/cpp/thirdparty/`、`tools/native/`。

## 验证接口

[P0-U4 探针](../probe/PROBE-u0-4-native-media.md)及其 EXPECT 提供目标 remux/MP3/取消/生命周期记录与可导出媒体。共享 ProbeKit 保留 HHmmss 显示 ID，内部 UUID/序号 token 独立限定会话和计时器所有权。探针退出不会以旧回调污染新会话，也不补造 END。

设计、修复和精确文件清单见工作区 `migration-runs/202610080259/native-delivery.md`、`native-delivery-files.json`、`probe-session-repair-design.md`。本文件描述最终实现，不以早期 async_work spike 方案作为当前契约。
