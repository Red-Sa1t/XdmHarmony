# XDM下载管理器（鸿蒙 PC）：上架准备清单（包名 com.neuohos.xdm）

## 当前上架状态（2026-11-20）

**应用名称**：XDM下载管理器（英文 XDM Download Manager）　**包名**：`com.neuohos.xdm`　**版本**：1.0.0（1000000）　**vendor**：`neuohos`　**设备类型**：仅 2in1（PC）

已就绪：
- **功能与质量**：除下载外的全部功能已在 PC 模拟器（2in1，API 24）全量检测，探针单元 P0~P7 全过并与真机基线一致；主机测试 630 项（625 通过、5 跳过）、Hypium 642/642（2026-11-20 runDir `2026-11-19T15-36-08-615Z-b552abf9`）。检测与修复明细见 `docs/delivery/DELIVERY.md` C.6 与 D 档 1。
- **release 构建**：`entry-default-signed.hap` 8,999,226 B，sha256 `f2160e245d39a76ed422be6ab59bfa1939761d9acb8cc6ea15239ccbe55d0bc1`（2026-11-20，21 条目，无 sourceMaps；模拟器装包启动通过，bm dump deviceTypes=[2in1]）。注意：此包用**调试证书 + 调试 Profile** 签名，只能装机自测，**不能上传 AGC**（见"提交前仍需完成"第 2、3 项）。
- **名称与图标**：参照 draw.io 的审核驳回（指南 1.20 名称/图标一致、9.4/9.5 他人商标），应用名改为「XDM下载管理器 / XDM Download Manager」，去掉含华为商标 Harmony 的旧名 XdmHarmony；AppScope 三语 `app_name`、EntryAbility 标签、窗口标题栏、任务栏一致（模拟器已确认）。图标为原创分层图标（蓝青渐变底 + 白色下载箭头与托盘），替换了 DevEco 模板默认图标；源文件 `store-listing/icon/`，由 `scripts/make-icon.py` 生成。
- **商店素材**（`store-listing/`）：介绍文案 `应用介绍.md`（名称、简介、分类、关键词、介绍、新版本特性）；商店图标 1024/216；5 张配文展示图（1920×1080、1280×720、800×450 三种尺寸，`screenshots-promo/`，`scripts/make-promo.py` 生成）及原始截图 `raw/`。截图中的文件均为演示数据。
- **隐私政策**：https://red-sa1t.github.io/XdmHarmony/privacy.html （源 `docs/privacy.html`，GitHub Pages）。浏览器扩展安装说明：https://red-sa1t.github.io/XdmHarmony/extension.html （扩展压缩包 `docs/xdm-browser-extension-3.3.zip`）。
- **源码公开（GPL-2.0）**：完整历史在 GitCode https://gitcode.com/Red_Salt/XdmHarmony （main `d522252` 起）；GitHub https://github.com/Red-Sa1t/XdmHarmony 为源码快照（签名配置已移除，同 draw.io 公开仓库做法）。仓库根有 GPL-2.0 `LICENSE`；应用内"关于"展示版本、GPL-2.0 无担保声明、上游致谢与源码地址。
- **键盘快捷键**（2026-11-20）：Ctrl+N 新建下载、Ctrl+A 全选当前列表、Delete 删除选中（弹确认）、Esc 取消选择、Ctrl+F 定位搜索框；搜索框获焦时 Delete/Ctrl+A/Esc 留给文本编辑。模拟器实测 Ctrl+A、Esc、Delete、Ctrl+N 生效；Ctrl+F 未实测（模拟器聚焦输入框会弹第三方输入法隐私协议，未代为同意）。
- **商店版界面**：不可用的占位入口已移除（导出/导入、帮助、报告问题、检查更新、视频向导、队列/计划任务）；"移除已完成的任务"与"关于"已实现；内部测试页在 release 包中不可达（实测 `--ps page probe` 落主界面）。

- **上传包（.app）**：`artifacts/XdmDownloadManager-1.0.0-release-signed.app`（2026-11-20 构建，3,885,391 B，SHA-256 `89caeb638fb83e70a71f85504b35553c3a2b8f6a41747462d5be8e3851d20795`）。发布证书签名（Release 证书，有效期至 2029-10-15，链至 Huawei CBG Root CA G2）；内嵌 Profile 与 `xdm_publishRelease.p7b` 逐字节一致（type release、app_gallery、`com.neuohos.xdm`、allowed-acls 含 READ_PASTEBOARD）；`hap-sign-tool verify-app` 校验 .app 通过，同次构建的发布签名 HAP 也校验通过。pack.info：Release、compatible 23 / target 24；包内 HAP `buildMode=release`、`debug=false`、deviceTypes 仅 2in1。.app 内的 HAP 为未签名形态，由 .app 整包签名覆盖（当前 SDK 的打包方式）。发布签名包不能直接装机，回归仍用调试签名包。

## 提交前仍需完成（需开发者本人在 AGC 操作）

1. ~~READ_PASTEBOARD 受限权限（ACL）申请~~、~~发布证书~~、~~发布 Profile~~：已完成（本机 `C:\Users\<用户>\.ohos\publish\xdm\` 下有 xdm.p12、xdm_publish.cer、xdm_publishRelease.p7b，2026-11-20；Profile 已含 READ_PASTEBOARD，说明 ACL 已获批）。
2. ~~构建上架 .app~~：已完成，见上文"上传包"。重新构建方法见文末"更新流程"。
3. （保留编号）
4. **APP 备案**（中国大陆上架必需）：在 AGC/工信部备案系统完成，取得备案号后填入 AGC。
5. **AGC 创建应用并提交**：包名 `com.neuohos.xdm`（创建后不可改）→ 上传 .app → 按 `store-listing/应用介绍.md` 填名称、简介、介绍、关键词、新版本特性、分类（实用工具 > 下载管理），上传 216 图标与 `screenshots-promo/` 展示图 → 隐私政策链接填上面的地址 → 权限用途按 AGC-SUBMISSION §3 → 开源声明填 GPL-2.0 → 完成内容分级问卷 → 审核备注粘贴 AGC-SUBMISSION §6（8597 本地端口、后台行为、设备形态）→ 提交审核。

## 需要你决定（可能导致驳回的风险项）

1. ~~设备类型~~：已改为只声明 2in1（2026-11-20）。
2. ~~键盘快捷键~~：已补（2026-11-20，见上文）。若审核仍提出快捷键问题，按其具体条目补充。
3. **浏览器扩展**（2026-11-20 已缓解）：扩展仍只能手动加载（未上架任何浏览器扩展商店，也未在真实浏览器页面上验证过）。已做：项目站点提供安装说明与扩展压缩包 https://red-sa1t.github.io/XdmHarmony/extension.html ；商店文案、第 4 张展示图副标题、AGC 审核备注（AGC-SUBMISSION §6 第 4 条）均标明扩展为可选并给出获取方式，同时说明不装扩展时可靠剪贴板识别新建下载；隐私政策补充扩展的数据说明。仍可选做：把扩展发布到浏览器扩展商店（需你的开发者账号）。
4. **名称里的"XDM"**：上游项目名，GPL 允许沿用；若审核认为与原项目混淆，备选改为纯描述性名称。
5. **GitCode 历史中的签名配置**：GitCode 仓库历史里含 `build-profile.json5` 的签名配置（加密口令与本机证书路径，证书文件本身不在仓库）。如果该仓库是公开的，可考虑改为私有或清理历史；GitHub 快照不含这些内容。

## 已完成工作明细

| 日期 | 内容 | 证据 |
|---|---|---|
| 2026-11-13 | PC 模拟器验收（真机租期到期后）：HTTP/HLS/DASH 下载、强杀与暂停续传、公共流解码比对全过；UI 4 项修复（深色图标、空列表文案、ETA、完成窗关闭） | `docs/probe/emulator-pc-2026-11-13.log`，提交 6dd0520 |
| 2026-11-19 | 全量功能检测（除下载外全部功能）：修 3 项产品缺陷（2in1 镜像打开文件崩溃、语言下拉框空白、多选删除/批量移除只删一部分）与 2 项探针缺陷 | DELIVERY C.6，提交 f1ed9fc |
| 2026-11-19 | 上架整改：移除不可用入口，实现"移除已完成的任务"与"关于"，release 包屏蔽测试页，补 GPL-2.0 LICENSE | 提交 f1ed9fc |
| 2026-11-19 | 改名「XDM下载管理器」、原创图标、商店文案与截图、隐私政策 | 提交 1fda3ca |
| 2026-11-19 | **修复分片引擎重复下载**：进度回报在本平台失效导致主线程按 0 盲分裂、近写满的分片被整段重下（1.2GB 文件临时目录 3GB，2.4GB 文件写满磁盘），改为共享内存回报进度；500MB 暂停续传与强杀重启续传 MD5 一致 | DELIVERY D 档 1，提交 1fda3ca |
| 2026-11-19 | 运行时切换语言刷新状态列与进度窗；删除任务关闭其进度窗；进度窗长网址省略号 | 提交 1fda3ca |
| 2026-11-19 | 展示图加配文（三种尺寸） | 提交 087dce7 |
| 2026-11-19 | 隐私政策发布到 GitHub Pages；GitHub 源码快照；GitCode 推送到最新 | 提交 aada263、d522252 |
| 2026-11-20 | 设备类型收窄为 2in1；主窗口键盘快捷键（Ctrl+N/Ctrl+A/Delete/Esc/Ctrl+F） | 本文件"已就绪"，DELIVERY D 档 1 |
| 2026-11-20 | 浏览器扩展：Pages 安装说明与压缩包，文案/展示图/审核备注标明可选 | 提交 e5bf818 |
| 2026-11-20 | 发布签名构建上架 .app（工程级 assembleApp），verify-app 通过、内嵌 Profile 与发布 Profile 一致 | 本文件"上传包" |

模拟器覆盖不到、留待真机的项：真实网络路径与性能、PC 实机目录授权持久化与后台保活、真实浏览器页面捕获、右键菜单（此前已在真机上验证）。

## 文件索引

| 路径 | 内容 |
|---|---|
| `store-listing/应用介绍.md` | AGC 文案（名称、简介、分类、关键词、介绍、新版本特性、隐私链接、截图说明） |
| `store-listing/icon/` | 商店图标 1024/216、应用内分层图标源文件 |
| `store-listing/screenshots-promo/` | 配文展示图（三种尺寸，推荐上传） |
| `store-listing/raw/` | 模拟器原始截图（备用，也是展示图的来源） |
| `docs/privacy.html`、`docs/index.html`、`docs/extension.html` | 隐私政策、Pages 首页、浏览器扩展安装说明 |
| `docs/xdm-browser-extension-3.3.zip` | 浏览器扩展压缩包（由 `extension/` 打包，扩展有改动时需重新打包） |
| `docs/delivery/AGC-SUBMISSION.md` | 权限用途、ACL 申请理由、审核备注、开源合规 |
| `docs/delivery/DELIVERY.md` | 交付登记（测试证据、缺陷闭环、构建指纹） |
| `scripts/make-icon.py`、`scripts/make-promo.py` | 重新生成图标与展示图 |

## 更新流程

- **改了截图或配文**：替换 `store-listing/raw/` 中的原图或改 `scripts/make-promo.py` 里的标题，运行 `python scripts/make-promo.py`。
- **改了隐私政策或要更新 GitHub 源码**：在本仓库提交后，用 `git archive main` 导出到临时目录，把 `build-profile.json5` 的 `signingConfigs` 置为 `[]` 并删掉 product 的 `signingConfig` 行，再提交推送到 GitHub `Red-Sa1t/XdmHarmony` 的 main；Pages 会在几分钟内自动更新。
- **重新构建上架 .app**：发布签名配置只存在于本机工作区的 `build-profile.json5`（`release` signingConfig，keyAlias `xdm`，口令为 hvigor 密文，**不提交入库**），平时 product 指向调试签名 `default`。构建时临时把 product 的 `signingConfig` 改为 `'release'`，设置 `DEVECO_SDK_HOME=D:\Tools\DevEco Studio\sdk`，执行
  `node "D:/Tools/DevEco Studio/tools/hvigor/bin/hvigorw.js" --mode project -p product=default -p buildMode=release assembleApp --no-daemon`，
  产物 `build/outputs/default/XdmHarmony-default-signed.app`；用 `hap-sign-tool.jar verify-app` 校验后复制到 `artifacts/` 并登记 SHA-256，最后把 product 改回 `'default'`。
- **改了代码**：跑主机测试（`node --test XdmHarmony/tests/host/`，在上级目录执行）与 Hypium 门禁（DELIVERY F.3），再做 release 构建并在 DELIVERY E 节登记指纹。
