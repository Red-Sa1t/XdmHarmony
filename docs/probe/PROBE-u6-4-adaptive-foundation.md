# P6-U4 自适应状态与清单探针

此入口覆盖 `AdaptiveStateStore`、`ManifestClient` 和 `AdaptiveAttemptFile` 的 HarmonyOS 文件/网络边界，以及 `AdaptiveProtocol` / `AdaptiveScheduler` 的本地接线，令这些模块在同一应用构建中可达。S5 的 HTTP 头、接收数和结束事实为显式合成输入，文件写入、封存、调度和状态提交则调用实际产品模块。它不验收完整HLS下载、物理掉电持久化或媒体播放。当前目标运行状态：待验，未生成目标PASS日志。

## 准备与运行

1. 在PC项目目录运行固定测试源：

   ```powershell
   node docs/probe/P6-U4-manifest-host.cjs --host 0.0.0.0 --port 8794
   ```

   不带参数默认仅监听127.0.0.1:8794，供本机回归。设备运行时使用设备可达的PC局域网地址；设备上的127.0.0.1不是PC。脚本只提供固定自产响应，无文件浏览或转发服务。

2. 构建、安装并以既有 `page=probe` want进入 `probe/ProbeIndex`，选择“P6-U4 自适应状态与清单探针”。设备操作方式遵循 [PROBE_SPEC](../PROBE_SPEC.md)。不必修改设备镜像或系统配置来执行源代码/主机检查。
3. 测试源填写 `http://<PC局域网IP>:8794`。界面默认地址只是占位值；仅接受没有用户信息、query、fragment或路径前缀的HTTP(S)源地址。点击“运行全部”依次执行S1—S6。S1/S2/S5/S6无需网络源可达。
4. 保留一次完整BEGIN到END的原始hilog及派生标记，记录设备/ABI、API、应用构建哈希、时间、显示runId。离开页面后缺失END是实际中断证据，不得借旧运行补全。
5. 导出每步 `detailFile` 指定的自产目录和JSON，对照 [EXPECT](EXPECT-u6-4-adaptive-foundation.json)逐项判定。主机测试输出不能填充这张目标期望表。

## 步骤和自产证据

| 步骤 | 实际操作 | 关键观察 |
| --- | --- | --- |
| S1 | 创建独立UUID目录；保存空generation0；写16字节普通part并fsync/close；保存generation1；新实例load；旧CAS | 保存/重开状态及generation、16字节complete、旧写conflict |
| S2 | 另一独立目录准备两代；将自己的part改为4字节；load；比对两槽和part；按已读generation破坏自己的最新槽；再load | repair只读、part仍4字节、旧generation0回退 |
| S3 | GET direct与302跨目录清单；固定虚拟Cookie/Referer/多值头；以实际finalUrl解析相对片段 | 两次ok、最终目录及片段URI匹配、Unicode和布尔头回声 |
| S4 | 非法UTF8、8Mi+1字节、404、150ms总超时；slow取消；同实例复用direct | 各固定结果码、实际耗时、取消timer是否触发、复用ok |
| S5 | 新建range为1000—1015的generation0；实际调度领取；E2写16字节并核对调用者缓冲快照和busy；合成206/EOS输入交实际协议检查；封存并settle；C CAS及重开 | syntheticHttpFacts=true、窗口/协议结果、sealed/closed、内容匹配、一次收束、generation1和完整part |
| S6 | 另一目录封存16字节旧文件，只提交8字节前缀；新候选复制8并追加8、封存并提交；尝试旧名碰撞；另一个未封存候选append后立即dispose/drain | copiedPrefixBytes=8、generation2、旧槽仍引用前缀、新旧文件各自字节、collision、实际候选缺失、两槽不变 |

每步拥有独立owner对象，即使同一轮共享sessionToken，旧步骤callback也不能继续写入新步骤。页面退出取消本步D、dispose本步C和全部E2 writer并等待已接纳操作drain；局部fd在finally关闭。封存成功的文件保留，未封存候选只由所属E2实例清理。S4在复用client前作废取消timer，已排队callback也不能取消新请求。

文件只位于 `filesDir/probe-adaptive-<新UUID>/` 内。mkdir碰撞不认领；每次修改前核对固定自产路径及普通文件，拒绝符号链接/目录。S5/S6只登记本owner由调度器或内部UUID生成的候选basename，不能通过返回的任意路径读取文件。S2不读取业务下载目录或删除下载数据。每步保留少量文件用于导出，不进行递归清理；导出后可由操作者按具体自产目录手动管理。

状态JSON含固定 `probe.invalid` 夹具URL，不使用真实下载记录。服务器只返回预定虚拟头是否匹配的布尔标志，不返回原始头值。详情和hilog记录固定状态、数值、布尔及自产路径；不保存响应正文或用户输入的凭据。

## 结果解释和限制

S2证明构造损坏现场下的恢复与只读校正。真实进程终止时机、目录落盘、断电持久性和最大状态的UI心跳需遵循运行目录 `u6-4-adaptive-state-io-device-manual.md` 另行验证。约20,000片的最大快照主机耗时不能替代设备性能。

S5的 `readyForAssembly=true` 只是调度器报告全部候选齐备，尚未装配、发布输出或发出下载完成事件。`syntheticHttpFacts=true` 必须保留；此步不能证明网络流、Range传输或低速背压已经通过。S6实际比较两个封存文件和两个状态槽，证明的是这次构造时序下的前缀不可变和未封存候选清理。真实SDK关闭失败、取消未排空等情况必须如实记录异常，不能凭调用dispose推断成功。

SDK若未按maxRedirects=0返回单跳、未按ARRAY_BUFFER返回、maxLimit错误码不同或取消迟迟不退出，应保留实际结果进行诊断，不能修改EXPECT使错误变成PASS。服务器慢请求意外提前完成时探针照实记录ok；取消timer未触发不能当作cancelled。

`tests/host/manifest-wire.test.cjs` 用真实Node HTTP传输运行生产ManifestClient，另有受控时序测试。两者验证各自适配器和生产控制流，均不等于HarmonyOS网络、fileIo、URL或TextDecoder已经运行通过。
