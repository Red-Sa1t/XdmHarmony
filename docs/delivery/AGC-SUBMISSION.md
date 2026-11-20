# AGC 上架提审材料（草稿，2026-10-15）

> 用途：AppGallery Connect 创建应用/提审时逐项复制。包名 `com.neuohos.xdm` 已定（一次绑定不可改）。
> **2026-11-20 起，上架状态与待办以仓库根 [RELEASE.md](../../RELEASE.md) 为准；商店文案以 [store-listing/应用介绍.md](../../store-listing/应用介绍.md) 为准。** 本文件保留权限用途（§3）、ACL 申请理由、开源合规（§5）与审核备注（§6）供提审时复制。

## 1. 应用基本信息

| 项 | 值 |
|---|---|
| 包名 | com.neuohos.xdm |
| 应用名称 | XDM下载管理器 / XDM Download Manager（2026-11-19 定稿，已改 app_name 三语言键与 EntryAbility 标签） |
| 分类 | 实用工具 > 下载管理（与 store-listing 一致） |
| 支持设备 | phone / 2in1（PC） |
| 版本 | 1.0.0（versionCode 1000000） |
| 开源许可 | GPL-2.0（衍生自 subhra74/xdm） |

## 2. 应用描述（商店文案）

> 已被 store-listing/应用介绍.md 取代（本节为 2026-10-15 草稿，含已移除的计划任务等描述，勿直接使用）。

**中文**：
XDM 下载管理器是开源下载工具 Xtreme Download Manager 的鸿蒙原生版本（GPL-2.0 开源）。核心能力：HTTP/HTTPS 多线程分段下载（最高 8 线程，显著提升大文件速度）、断点续传（进程中断后从断点继续）、下载队列与并发管理、全局/单任务限速、定时启停、后台保活下载（关窗不中断，任务栏实时进度通知）、复制链接自动识别、HLS/DASH 流媒体下载与自动合并（ffmpeg）、浏览器集成（配合 XDM 浏览器扩展接管下载与视频嗅探）。支持中文/英文界面与深浅色主题。PC（2in1）与手机形态均可使用。

**英文**：
XDM Download Manager is the native HarmonyOS port (GPL-2.0) of the open-source Xtreme Download Manager. Features: multi-segment HTTP/HTTPS downloads (up to 8 segments), resume after interruption, download queue with concurrency control, speed limiting, scheduler, background downloading with live progress notification, clipboard link detection, HLS/DASH streaming download with automatic remux (ffmpeg), and browser integration via the XDM extension. Chinese/English UI, dark mode, phone and 2in1 (PC) form factors.

## 3. 权限用途说明

| 权限 | 分类 | 用途说明（提审表单填写） |
|---|---|---|
| ohos.permission.INTERNET | 开放·系统授权 | 下载管理核心功能：发起 HTTP/HTTPS 请求下载用户指定文件（分段下载、断点续传、流媒体清单获取） |
| ohos.permission.KEEP_BACKGROUND_RUNNING | 开放·系统授权 | 用户关闭窗口或切后台后下载任务持续运行直至完成；配合 dataTransfer 长时任务，任务栏显示下载进度通知 |
| ohos.permission.PREPARE_APP_TERMINATE | 开放·系统授权 | 退出前检测进行中的下载任务，若有则最小化窗口保持下载，避免误关中断任务 |
| ohos.permission.READ_PASTEBOARD | **ACL 受限·用户授权**（须在 AGC 申请） | 见下方专项理由 |

**READ_PASTEBOARD ACL 申请理由**：
本应用为文件下载管理工具。用户在浏览器等应用复制文件下载直链后，应用需读取剪贴板内容识别 URL 并弹出新建下载提示（自动预填下载地址），省去用户手动切换应用粘贴的操作。读取行为仅在本应用前台、剪贴板内容变更事件触发时进行；识别结果仅用于本地 URL 合法性校验与输入框预填，**不上传、不存储、不用于任何其他用途**。此交互为下载管理类工具的标准形态（对齐桌面平台同类产品）。若申请不通过，将降级为应用内粘贴控件方案。

**ACL 通过后的配置步骤**：AGC 新建**发布 Profile 时勾选 READ_PASTEBOARD** → 下载 Profile → 打包签名（调试 Profile 与发布 Profile 分开）。

## 4. 隐私声明（草稿要点）

- **不收集任何个人信息**。应用无账号体系、无第三方统计/广告 SDK、不上传任何用户数据。
- **剪贴板**：仅在用户复制内容后应用处于前台时读取，用于识别下载链接并预填；内容不存储、不上传（ACL 权限，用户可拒绝，拒绝后仅失去自动识别功能，手动粘贴不受影响）。
- **网络访问**：仅访问用户主动提供的下载地址、其引用页（Referer/Cookie 随下载请求按需携带）及本地 127.0.0.1:8597 端口（浏览器扩展对接桥，仅本机回环，不对外网监听）。
- **本地存储**：下载记录与配置保存在应用沙箱；文件仅在用户通过系统目录选择器授权的目录内写入。
- **权限清单**：INTERNET / KEEP_BACKGROUND_RUNNING / PREPARE_APP_TERMINATE / READ_PASTEBOARD（用途见上表）。

## 5. 开源合规（GPL-2.0）

- 本应用为 [Xtreme Download Manager](https://github.com/subhra74/xdm)（GPL-2.0）的衍生作品，遵循 GPL-2.0 发布。
- 完整源码：GitCode `Red_Salt/XdmHarmony`（与上架包同源构建）；GitHub `Red-Sa1t/XdmHarmony` 为源码快照。
- 商店"开源声明"栏填写 GPL-2.0；应用内"关于"已实现（2026-11-19）：版本号、上游项目致谢、GPL-2.0 无担保声明、源码地址；仓库根 LICENSE 已补齐。

## 6. 审核备注（提审附言）

1. **8597 本地端口**：应用运行时监听 127.0.0.1:8597，用途为浏览器扩展与本应用的本机对接（XDM 官方扩展协议，地址写死于扩展内），仅本机回环通信，不对外网开放、不接收外部连接。
2. **后台行为**：仅在有活跃下载任务时申请 dataTransfer 长时任务（任务栏通知可见），任务完成即释放；无任何定时唤醒或静默后台活动。
3. **设备形态**：仅 PC（2in1）（2026-11-20 起 module.json5 只声明 2in1）。
4. **浏览器扩展（可选功能）**：浏览器接管与网页视频识别需安装配套浏览器扩展（XDM Integration Module，MV3，GPL-2.0，未上架扩展商店），安装包与说明：https://red-sa1t.github.io/XdmHarmony/extension.html 。不安装扩展时，复制下载链接后应用会自动识别剪贴板并弹出新建下载，核心下载功能均可验证。

## 7. 上架待办清单（历史记录；最新待办见 RELEASE.md）

- [ ] 真机连接 → `devecocli auth login` → `devecocli signature generate --product default`（新包名 Profile）
- [ ] AGC 提交 READ_PASTEBOARD ACL 申请（理由见 §3）
- [ ] ACL 通过 → 发布 Profile 勾选权限 → release 构建 → DELIVERY E 节重登记指纹
- [ ] AGC 创建应用（包名 com.neuohos.xdm，一次定死）→ 填 §1/§2/§4/§5 材料
- [x] 应用显示名定稿（XDM下载管理器）+ 原创图标 + 商店文案/截图（`store-listing/`）+ 隐私政策页（`docs/privacy.html`）
- [x] 隐私政策已发布（2026-11-19，同 draw.io 方式 GitHub Pages）：https://red-sa1t.github.io/XdmHarmony/privacy.html（首页 https://red-sa1t.github.io/XdmHarmony/ ）；已填入 `store-listing/应用介绍.md`，提审时填入 AGC
  - GitHub 仓库 Red-Sa1t/XdmHarmony（公开）为**源码快照**：从 GitCode main 用 `git archive` 导出，`build-profile.json5` 的 signingConfigs 置空、去掉 product 的 signingConfig（同 draw.io 公开仓库做法，不公开签名配置），Pages 源=main 分支 /docs（含 .nojekyll）。更新隐私政策或源码后按同法重新导出并推送 GitHub
  - 完整开发历史仍在 GitCode Red_Salt/XdmHarmony
- [x] 全量功能检测（2026-11-19，PC 模拟器，DELIVERY C.6）；探针页 release 包不可达；未实现入口已移除
- [ ] Phase tag → 提审
