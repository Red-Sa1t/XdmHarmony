# U6.3 浏览器接管与刷新链接迁移报告

日期：2026-10-08。实现、目标编译、主机回归和独立冷复核完成；真实浏览器及 HarmonyOS 设备验收仍待执行。所有改动尚未自动提交。

## 实现结果

- 新增 MV3 `extension/`，包含桥连接、请求捕获、下载取消后接管、手动提交和生产模块测试。
- 保存原 Cookie/Referer/多值请求头，引擎统一生成 Range/identity；worker 重开保持上下文。
- 新增统一 `DownloadCreationService` 和持久 `BridgeInbox`，自动创建提交后接纳、手动确认一次事务提升，桥成功应答等待持久结果；UI 使用单一 inbox 消费路径。
- 实现 Http 单源 LinkRefresher，支持 active/queued/stopped；当前运行固定旧请求，下次 start/resume 使用新提交；CAS、committed cache 和删除 tombstone 防止旧记录覆盖刷新。
- Index/RefreshLinkDialog 的 token 生命周期和 P6-U3 探针完成。任务类型仍明确区分，不把 HLS/DASH/双源输入错误创建为普通 Http。

最终设计见 [DESIGN](u6-3-browser-takeover-DESIGN.md)。源码范围包括 model 的请求/创建/运行快照、core/db/DownloadStore、core/engine 的创建/请求状态/Manager/分片网络链、core/bridge 的动作/inbox/refresher/routes/tracker、相关对话框/Index/VideoCapture、ProbeIndex/P6-U3、三个语言资源及 host/Hypium/extension 测试。精确范围与哈希保存在下列运行证据清单，不能只用 Git tracked diff 代替新增文件清单。

## 证据

运行根目录：工作区 `migration-runs/202610080259/`，在本 Git 项目之外。

|门禁|实际结果|证据|
|---|---|---|
|最终应用集成|ArkTS、原生编译、打包、签名均成功；exit 0|`build-native-link-r1.log/.exit`|
|真实 Hypium 门禁|462/462；failure/error/ignore 均0；包含原432项和HLS解析30项|`hypium-native-link/2026-10-08T05-18-02-063Z-58d0e96a-026e-47c2-8527-8691e0911103/verdict.json`|
|Link 主机组合回归|70/70 Node runner entries；其中3个脚本入口另含14/4/15个检查，不重复计数|`host-link-r1.log/.exit`|
|扩展生产模块|22/22，独立冷复核接受|`u6-3-extension-cold-review.md` 及其证据引用|
|C 持久创建/Inbox/UI|最终432/432 Hypium及21项UI时序回归；冷复核无开放高/中|`u6-3-c-cold-review.md`、`build-c-r4.*`、`hypium-c-final/`、`index-c-r4.log`|
|Link 独立冷复核|高0/中0/低1；37/37 runner entries（SQLite脚本内部15项）；P6-U3 4/4；新增取消/清理隔离2/2|`u6-3-link-refresh-cold-review.md`、`link-refresh-cold-*.log/.exit`|
|源码目录辅助 lint|0 errors、19 warnings、2 suggestions；工具报告7个含问题文件|`lint-native-link-full.json/.log/.exit`|
|所审版本|15个 Link 范围文件与 build 前清单一致|`link-refresh-prebuild-files.json`、`link-refresh-cold-files.json`|

编译另报告 may-throw 与设备能力提示；这些不是编译错误。Store 内部事务异常向外层 catch 传播，不为消除提示而吞掉失败。辅助 lint 亦不代替 ArkTS 编译或业务验收。

## 源差异与未验范围

- 请求版本与持久 inbox 是迁移到异步平台后的可靠性机制；旧整行写冲突明确失败，不能静默重试旧载荷。
- Http 单源刷新采用源的同正大小规则，未增域名/名称/内容身份比较。原双源刷新需同时持久化两套输入，仍待后续单元；未通过只更新主 URL 冒充支持。
- `/args` 的既有错误吞咽仍是应答例外。P6-U3 不替代 socket ACK 或真实浏览器验收。
- 主机真实 SQLite 并非 Harmony RDB，TaskPool/网络/ArkUI 受控替身不能证明目标事件顺序。当前无可用设备，模拟器的既有镜像版本和内存提交问题未通过修改用户设置绕开。
- 待设备补验：浏览器取消/提交/弹窗；带 Cookie/Referer 下载；active 刷新后本轮继续旧请求、下轮用新请求；关闭/重开窗口；进程重启与文件摘要。历史慢流仍缺平台时序证据。
- 冷审唯一低项：BridgeRoutes/Tracker 的若干历史注释仍写 LinkAccepted 未迁移。实际拦截已验证；后续同文件接线时同步更新这些迁移注释。

本报告的通过范围为所记录代码版本的实现、构建和主机审查。未将用户真实浏览器、设备运行或完整 HLS/DASH 下载标为通过。
