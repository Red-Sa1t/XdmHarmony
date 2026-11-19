# U6.3 浏览器接管、持久确认与刷新链接

本稿描述已实现的最终结构。参考源码只读，位于 `resourses/xdm/`：Chrome 扩展、`ApplicationCore.AddDownload`、`CapturedVideoTracker.AddVideoDownload`、`LinkRefresher`、`LinkRefreshDialogUIController`、`SingleSourceHTTPDownloader.SetDownloadInfo`。原 DWF 按研究、设计、实现、构建、独立审查、冷复核和探针的门禁等价执行。

## 1. 请求到下载任务

`extension/` 提供 Manifest V3 扩展，保留 8597 桥协议。扩展捕获请求头/Cookie，下载接管先等待浏览器取消原任务，再向桥提交；连接失败保留可重试状态。真实浏览器权限、加载与下载事件顺序属于外部验收项，主机替身通过不表示浏览器实测通过。

`DownloadRequestContext` 保留 null/空头、多值头与原 Cookie 串。桥的请求过滤与引擎请求合成职责分离：浏览器头保存在 side-table，`composeDownloadHeaders` 为实际请求重新拥有 Range/Accept-Encoding=identity，不让捕获的 Range 覆盖引擎窗口。每个 worker 派发及水位重开都保留已选定上下文。

`DownloadCreationRequest` 是独立的创建输入，包含 URL、名称、大小、目录、启动模式、认证、代理及与 contextUrl 绑定的请求上下文。UI 若把 URL 改成另一资源，不能继续附带旧地址捕获的凭据。所有 Http 创建走 `DownloadCreationService`：持久提交成功 → 发布 added → 队列接纳。存储失败不能发已成功事件或占用下载槽。

自动接管直接持久创建。需要用户确认的单条、批量或视频输入先写 `bridge_inbox`，然后才允许桥应答。`BridgeInbox` 是唯一待确认来源；观察性 BridgeUiEvents 不再驱动第二套普通新建弹窗。确认时使用专用 IMMEDIATE 事务一次创建选中任务并删除 inbox 项；并发确认只成功一次，失败保留可重试输入。取消只删除对应 inbox 项。

Index 在历史加载期间暂缓 admission，并合并已提交的新任务和待接纳列表；事件重放与稳定 Manager wrapper 使页面更换不会继续更新已失效的 UI。视频多选在首个 await 前为全部选择保存独立快照，后续 tracker 清空/标题更新不会改变已提交用户操作的输入。

## 2. 刷新链接规则

本阶段实现 **Http 单源**刷新，覆盖 active、queued 和 stopped。用户主动为一个任务打开刷新窗口后，系统只保留一个候选；新候选替换旧候选。

匹配沿用源规则：大小必须为相同正数，不比较域名、文件名、URL 或 Referer。因此同大小不同内容也可能匹配，这是已声明的源规则限制。消息路径要求恰好一个大小写不敏感 Content-Length 键并解析首值；超过 JavaScript 安全整数范围明确拒绝。普通视频使用其完整输入快照中的大小。

`/download` 与普通视频下载动作在创建/入 inbox 前 await LinkRefresher。匹配且提交成功时消费请求，不新建任务，不自动停止或恢复。已匹配但提交失败向上抛出，不能回退为普通创建。批量 `/link` 与仅嗅探 `/media` 不消费候选。双源、HLS 和 DASH 没有伪装为单源刷新。`/args` 仍有原协议的内层吞异常行为，不能把该路由的 ACK 当作刷新已提交的证明。

并发请求通过串行门按顺序重判当前 watch。Stop 取消本会话后续通知；已开始的数据库提交仍可以完成。旧提交、关闭回调及浏览器 Promise 只能作用于自己的 token，不能清空或关闭后来创建的窗口。监听器异常不推翻已经完成的持久化。

## 3. active 刷新的持久化和运行边界

源控制器恢复一个独立 downloader 修改其持久状态，当前 live downloader 保留自己的旧请求。本实现用三个机制对应这一行为，并防止旧对象覆盖已确认刷新：

1. 每轮 `PieceScheduler.start/resume` 在有效运行入口、onStarted 之前捕获 `DownloadRunRequest`。首探测、分裂、重试、续接都使用同一深拷贝快照；同实例下一次 resume 重新捕获。
2. Store 只在事务提交后发布每 ID 的请求快照。`DownloadRequestState` 的 committed cache 是权威来源，即使可变 record 自称更高 revision，也不能越过已提交缓存。旧查询不能倒退缓存；删除建立 tombstone，迟到查询不能复活目标。
3. 新增 `download_request_revision` 侧表，遗留记录无版本行时按 0 读取。刷新在同一事务更新 URL/context/revision；整行 update 要求调用 record 的 revision 与数据库相等，否则不写任何字段。进度、状态、完成更新不修改请求版本。

发布前开始的运行固定旧请求，发布后开始的运行固定新请求；刷新成功不改变已运行轮次。名字、目标目录、状态、大小、分片进度与任务 ID 保持既有语义。恢复 chunks 中的正 totalSize 优先于可能陈旧的 record.size，用临时候选构造匹配输入，不篡改列表元数据。

## 4. UI 和平台边界

刷新窗口先登记候选与监听，再打开持久 Referer，避免浏览器立即回传时漏接。替换窗口等待前一个 CustomDialog 销毁；浏览器打开失败仍保留可手动触发的候选。Stop、外部关闭、页面销毁及成功消息各自按 token 收口，不能由旧回调关闭新窗口。

HttpClient 具有状态获取超时、dataEnd 空闲超时与主动 abort 门，持续收到数据会刷新空闲计时器。历史慢流的 HarmonyOS 回调先后顺序仍需要设备证据，不能由主机事件替身推定已解决，也不通过改变为有限 Range 来掩盖问题。

## 5. 探针与验证

P6-U3 的四步直接调用生产 LinkRefresher/Store：刷新读回和快照隔离、旧版本整行写冲突、提交时 Stop 后重开、非法输入与删除目标。每步创建并只清理自身 UUID 行，所有异步边界检查会话；详细要求见 [探针手册](../probe/PROBE-u6-3-link-refresh.md) 和对应 EXPECT。

主机验证直接加载生产 ETS、真实宿主 SQLite 及扩展生产模块；系统 socket、TaskPool、ArkUI、Harmony RDB 与浏览器事件需要区分替身范围。发布验收还要求真实浏览器往返、设备上 active 分片请求分界、重启续传及最终文件摘要。最终证据与未验项见同目录 REPORT。
