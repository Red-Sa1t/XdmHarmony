# U0.4 / U7.2 原生媒体处理迁移报告

2026-10-08：两 ABI 的实现、应用构建、打包检查和源代码/主机冷复核完成。**目标设备运行、导出媒体解码及播放仍未验收，U0.4 尚无运行 GO。**

最终实现见 [DESIGN](u0-4-native-media-DESIGN.md)。精确交付范围为工作区 `migration-runs/202610080259/native-delivery-files.json` 的296个文件，加 root 所有的构建配置、类型包依赖、探针注册和语言资源。最终共享探针范围单列在 `probe-session-repair-files-r2.json`，共20文件；新增本报告和设计是说明文件，不改已冻结业务代码。

## 验证结果

以下证据均位于工作区 `migration-runs/202610080259/`。

| 检查 | 结果 | 证据 |
| --- | --- | --- |
| 最终应用构建 | 实际 ArkTS 编译、打包、签名成功，exit 0 | `build-native-adaptive-r3.log/.exit` |
| 最终集成 Hypium | 501/501，失败/错误/忽略均0 | `hypium-native-adaptive-r3/2026-10-08T06-44-32-692Z-ad6c3527-01a5-4e69-8894-b80d21fbb768/verdict.json` |
| Native R2 受影响用例 | 普通30/30；严格 ASan/UBSan 25/25；55次原生调用 stderr 全为空 | `native-cover-tests/validation-summary.json` |
| 原始冷审反例复跑 | 最终R2全部5例通过；原始失败记录保留 | `u0-4-native-cold-review.md`、`native-cold-review/final-review-bindings.json` |
| Native及共享probe冷审 | 高0 / 中0 / 低0，范围限源码和主机 | `u0-4-native-cold-review.md` |
| 依赖及目标产物 | 两ABI构建成功，260项依赖哈希一致 | `native-napi/verification.json` |
| 最终源码绑定 | native296、probe20、adaptive10均匹配冻结版本 | `integration-r3-source-verification.json` |
| 完整目录辅助lint | 0 error / 7 warning / 2 suggestion，6个含问题文件 | `lint-native-adaptive-r2.json` |

初期核心36例、严格sanitizer36例、真实Node NAPI的20次连续任务和20次环境销毁属于各自原版本的证据，不能重新称为最终封面R2全量复跑。后续R2专门验证封面、章节及受影响输出；完整历史路径见 `native-delivery.md`。

最终签名 HAP 为10,369,079字节，SHA256 `88768fba6739247c7243eafdae668602163c5454a52264aa8c72d297a5567c5b`。`hap-native-adaptive-r3/verdict.json` 确认两 ABI 的 libxdm_media/libc++、仅 ace_napi/libc++/libc 三项 NAPI 依赖、隐藏的 FFmpeg/LAME 符号及三个原始媒体夹具。独立 CMake 输出与 HAP 内库因剥离和构建参数不同，不混用哈希。

## 已修复问题和保留边界

独立评审关闭输出路径替换、环境 teardown/TSFN release、TS 视频尺寸问题；冷审进一步关闭 PNG/JPEG attached-picture 失败和遗漏章节警告。原始反例、修复前源码及中间构建均保留。

共享probe的85处会话捕获迁移到内部 token，Kit/Page/Native 使用各自所有权，Bridge S2的全部11个业务await后复检。真实生产方法主机测试13/13，独立生命周期6/6，Bridge边界12/12，受影响Link探针4/4和取消隔离2/2通过。HHmmss仍作为日志显示ID；不完整会话没有伪造END。

编译仍有 may-throw 等提示，未为消除提示而吞错。辅助lint不代替编译或运行验收；单文件r3 lint返回filesChecked=0，不能据此断言全范围无问题。

尚待可用目标设备运行 [P0-U4](../probe/PROBE-u0-4-native-media.md)，导出实际媒体独立检查、播放并验证目标NAPI生命周期。当前无连接设备，模拟器已有镜像/commit-charge问题没有通过修改用户设置绕开。后续自适应下载器还需完成安全concat、发布和已下载片段回收，现阶段不宣称完整HLS/DASH可用。
