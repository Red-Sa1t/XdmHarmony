# XdmHarmony — XDM (Xtreme Download Manager) 鸿蒙 PC 迁移

XDM 2023（C#/.NET，subhra74/xdm）在 HarmonyOS PC 形态上的 ArkTS/ArkUI 跨语言重写：HTTP/HTTPS 分段多线程下载、断点续传、队列/限速/定时、完整 UI（中英 i18n+深浅色）、后台下载+通知、剪贴板监视、浏览器扩展集成（8597 桥+下载接管）、HLS、DASH+ffmpeg remux/MP3。

> **许可**：本项目是 XDM 2023（GPL-2.0）的衍生作品，分发须遵循 GPL-2.0 并提供对应源码——详见 [docs/delivery/DELIVERY.md](docs/delivery/DELIVERY.md) A.4 节。

## 环境要求

- DevEco Studio + HarmonyOS SDK **6.1.1(24)**（targetSdkVersion 6.1.1(24)）。
- **compatibleSdkVersion 钉在 6.1.0(23)**（build-profile.json5:23）：真机 MateBook Pro HAD-W24 系统为 API 23，装 API 24 包被拒（code 9568297）。**不要把它改回 24**，否则真机不可安装。
- 运行目标：2in1/phone（module.json5 deviceTypes 已含 `2in1`）。

## 构建

```powershell
cd D:\git\HarmonyPC\XdmHarmony
devecocli build --product default --modules entry --build-mode release
```

- **`--build-mode release` 必须显式**：`devecocli build` 默认 **debug**（`devecocli build --help` 实测）。
- 产物：`entry/build/default/outputs/default/entry-default-signed.hap`（当前交付指纹与 pack.info 校验值见 [DELIVERY.md](docs/delivery/DELIVERY.md) E 节；HAP 二进制不入 git）。
- **不要重跑 `devecocli signature generate`**：signingConfigs 已就绪（build-profile.json5:3-17），重跑会重写签名配置。
- 真机安装冒烟（可选）：`"D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" app install entry/build/default/outputs/default/entry-default-signed.hap`。

## 测试

单测结论**只认 run-hypium 包装口径**：

```powershell
cd D:\git\HarmonyPC\XdmHarmony
node scripts/run-hypium.cjs --expected-tests 642 --output ../migration-runs/hypium -- 'D:/Tools/DevEco Studio/tools/node/node.exe' 'D:/Tools/DevEco Studio/tools/hvigor/bin/hvigorw.js' test --no-parallel
```

- 通过判据：wrapper exit 0 且 verdict.json `ok:true`、`counts.total=642 / pass=642 / failure=0 / error=0 / ignore=0`。门禁四条件见 [scripts/HYPIUM_GATE.md](scripts/HYPIUM_GATE.md)。
- ⚠️ **不得以 hvigor 退出码或 `BUILD SUCCESSFUL` 字样判定测试通过**——`hvigor test` 存在假绿（退出码 0 但断言失败被吞，实测一次吞 5 例；2026-10-15 又实证 1 条 error 仍 BUILD SUCCESSFUL）。
- `--expected-tests 642` 钉注册总数防漏注册（2026-10-15 IR-F1/F1 回归批次 +2 起）；每轮运行在 `../migration-runs/hypium/` 留档 verdict.json 与结果指纹。
- 调整测试注册范围时同步调整该数字（HYPIUM_GATE.md:11）。

## 探针体系与文档索引

- **探针规范**：[docs/PROBE_SPEC.md](docs/PROBE_SPEC.md)（日志标记 `[XDM_PROBE][<单元ID>][<步骤号>]`、单行 <1500 字节、hilog domain 0xD001 / tag XDM_PROBE）。
- **探针会话总指引**：[docs/probe/PROBE-SESSION-ALL.md](docs/probe/PROBE-SESSION-ALL.md)（一次安装跑全部探针的次序、测试源、日志抓取；含会话#1 已跑 10/14 结论）。
- 各探针手册与预期表：`docs/probe/PROBE-*.md` + `docs/probe/EXPECT-*.json`；会话#2 待跑 15 项清单见 [DELIVERY.md](docs/delivery/DELIVERY.md) C.3。
- **单元设计书/迁移报告**（24 单元逐一）：`docs/design/u*-DESIGN.md` / `u*-REPORT.md`。
- **交付总结**（24 单元全景、里程碑、降级清单、GPL-2.0 声明、已知问题、交付物指纹、复现命令）：[docs/delivery/DELIVERY.md](docs/delivery/DELIVERY.md)。
- 计划与目录：[docs/MIGRATION_PLAN.md](docs/MIGRATION_PLAN.md)、[docs/UNIT_CATALOG.md](docs/UNIT_CATALOG.md)。
