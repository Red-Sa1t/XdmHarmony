# P6-U3 链接刷新与持久化探针

运行状态：待设备验证。入口 `probe/units/ProbeLinkRefresh.ets`，期望见同目录 `EXPECT-u6-3-link-refresh.json`。

本探针直接运行生产 LinkRefresher、DownloadStore 和请求版本缓存，观测 HarmonyOS RDB 的真实事务行为。每步创建带 `probe-P6-U3-` 名称的 UUID 记录，使用 example.invalid 合成 URL/Cookie，不连接该站点、不启动下载。步骤结束只删除本步拥有的记录；`cleanup=false` 或崩溃时按日志定位留下的测试行，勿清空用户数据库。

设备可用后，先构建当前源码并记录 HAP 摘要、设备型号/系统版本和时间。使用 EntryAbility 的 `page=probe` 参数进入探针首页，选择 P6-U3。进入后顺序执行 S1–S4；自动会话期间不要操作浏览器链接刷新。离开页面会停止探针拥有的监听，已开始的事务完成后继续清理。

|步骤|观测范围|
|---|---|
|S1|大小不匹配不消费；匹配后 URL、Cookie、多值头原子读回；输入在 await 期间变更不污染已捕获请求；任务元数据不变，旧/下一轮快照分别为版本 0/1|
|S2|刷新后，旧版本整行保存被拒；名字、URL、Cookie 保持已提交内容|
|S3|旧提交开始后 Stop 并开新监听；旧操作仍持久完成但无旧通知，新监听不被旧 token 清除|
|S4|匹配但非法 URL 拒绝并可重试；删除目标后刷新拒绝，记录不复活，运行解析拒绝墓碑|

保存原始 hilog 和沙箱 `probe-latest.txt`，按最后一次完整 BEGIN/SUMMARY/END 配对逐步判定。`END ok=true` 只表示脚手架没有异常；每步实际值和 cleanup 必须符合 EXPECT。错误行或缺失步骤应保留并判为 FAIL/MISSING，不能用历史结果补齐。

本探针不覆盖进程重启、浏览器扩展、socket ACK 时序、运行中的网络分片或真实 ArkUI 窗口。当前主机证据分别位于 `tests/host/request-version.test.cjs`、`bridge-durable.test.cjs`、`run-request.test.cjs`、`link-refresh-ui.test.cjs`。设备恢复后还需执行：失效 URL → 浏览器重发同大小请求 → 同 ID 续传 → 输出摘要核对；活动刷新期间各连接继续原请求，停止后恢复使用新 Cookie/Referer；关闭/重开等待窗与浏览器往返；重启后读取新请求。真实浏览器操作以 extension 的验收手册为准。
