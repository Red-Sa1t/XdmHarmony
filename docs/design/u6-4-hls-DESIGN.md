# U6.4 HLS 迁移设计：解析、状态、下载执行与装配

当前 A 解析器、B 计划/状态codec、C 异步状态IO、D 清单GET、E1协议/纯调度、E2候选文件、E3流式执行/共享限速和F装配均已实现，相关批次通过独立审查、SDK构建及冷复核。P6-U4和P6-U5提供已注册探针；E4运行控制器及P6-U6已实现并通过主机检查，正在完成SDK集成验收。业务入口、最终发布与桥/UI接线尚未完成。

## 源对照与数据流

只读依据为 XDM 的 HlsParser、HlsHelper、MultiSourceHLSDownloader、Adaptive下载状态/分块逻辑。完整引用和取舍见工作区 `migration-runs/202610080259/u6-4-hls-source-facts.md`、`u6-4-hls-parser-design.md`、`u6-4-hls-plan-design.md`。

`HlsParser.ets` 解析 master/media、rendition组合、BYTERANGE、MAP、key/IV元数据、sequence及discontinuity。URI由 `HlsUrlResolver.ets` 使用SDK URL解析；保留签名查询和转义语义，限定HTTP(S)。解析器输出键元数据不代表已经实现解密，执行计划明确拒绝加密和I-frame-only播放列表。有限live快照对齐源行为，不轮询录制。

不支持的SKIP/delta、DEFINE和未展开变量明确拒绝。输入字符、累计输出和中间master展开均受预算约束，禁止通过小输入产生无界组合和复制。

## 计划和状态约束

`AdaptivePlan.ets` 按源交错排列一或双轨片段，保留MAP位置、不等长尾部、轨内顺序、范围起点和长度。容器推断与源Last()一致，包括尾部MAP和解码后的路径扩展名。每轨最多10,000块，总计20,000；并行上限64。

计划、分片状态和JSON envelope经过严格字段/数值/顺序校验，计划最多8Mi字符，状态最多16Mi字符；在20,000项文件名和字节计数增长后仍满足预算。纯URL形状门支持有效IPv6并拒绝残缺边缘单冒号，传输层仍必须使用SDK解析器。

`AdaptiveStateCodec.ets` 将下载ID、generation、固定计划和逐块进度绑定。每个非空part文件名必须唯一，范围已满但complete=false非法。恢复时文件缺失或短于保存前缀重置该项；文件多出的尾部不自动增加持久进度。codec只做纯转换和校验，不写文件，不据此保证掉电持久化。

## 状态IO与清单请求

C `AdaptiveStateStore.ets` 使用独立双槽状态文件，选择最高有效generation，预期generation CAS提交；同目录串行容量2，未知slot IO错误阻止写入。读取及part检查均有界，rename成功后dispose不撤销已提交结果；只清理由本操作创建的staging。非空part在引用前必须停止写入并成功fsync/close。进程内主线程队列不等于跨进程排他锁。详见运行目录已接受的 `u6-4-adaptive-state-io-design.md`。

D `ManifestClient.ets` 每hop显式 `maxRedirects=0`，只跟随301/302/303/307/308，最多30跳；最后一次实际GET地址为finalUrl，用于相对片段解析。请求上下文在首个await前深复制；跨origin后永久移除Authorization/Proxy-Authorization/Cookie，跳回也不恢复。不使用未承诺effective URL的FINAL_RESPONSE上下文。

整条跳转链共用8Mi字节预算及一个可取消总时限；只有最终完整200进行严格UTF-8解码，最多2Mi UTF-16字符。旧请求/回调/计时器不能销毁取消后复用实例的新请求。浏览器POST/request-body捕获另行接线，不能用未知GET回放代替。

P6-U4 的S1/S2在独占UUID目录验证真实状态IO、只读短part修复和按generation回退；S3/S4使用固定HTTP源验证清单、跳转、错误、取消及复用。每个step同时使用run token和独立owner，退出仍完成自己资源的清理。所有目标设备观测当前待运行。

## 协议、调度与候选文件

E1 `AdaptiveProtocol.ets` 将远端Range与本地prefix分开，检查实际received/written/EOS和响应framing；满长但缺少完成证据不能标complete，whole200重置只能写新候选。`AdaptiveScheduler.ets` 在返回dispatch前登记owner，只在最终settled回执后归还lane；维护有限重试、停止顺序和一次收束。readyForAssembly只是候选齐备，不改变C generation，也不发完成事件。

E2 `AdaptiveAttemptFile.ets` 每实例管理一个候选，64KiB有界append、同步输入快照、并发busy；只复制已提交旧prefix，忽略物理尾部。候选只有在长度核验、fsync、成功close后才seal；dispose清理自己拥有的未封存文件，sealed文件保持不变。close不确定与cleanup失败分别记录，不盲目重试fd。详见运行目录两个已接受设计及最终报告。

P6-U4 S5使用显式synthetic HTTP facts，将实际E1协议/调度、E2封存和C CAS/reopen串接；S6核对旧槽/旧prefix不变、新候选只copy8再append8、碰撞和dispose/drain后的实际文件。两步不替代真实RCP网络，manual/EXPECT保持pending-device-run。

## 后续接线契约

C最大20,000片快照的主机同步捕获约1.8至2.4秒；异步文件API不消除该CPU成本。E4必须合并checkpoint并保持至多一次save在途，不得每个chunk/progress事件全量序列化。当前E1/E2只在attempt结束时交付sealed候选；周期保存已seal变化不等于源每2秒持久化live chunk的恢复粒度，长单片异常退出损失窗口要在后续报告显式记录。

后续调度在主线程维护状态，worker只传递快照和结果；安全concat/native/用户目录发布构成另一个提交边界。只有目标媒体可播、重启续传和实际浏览器接线验证后，才能完成U6.4验收。

## 流式执行与装配

E3由 `AdaptiveRcpStream.ets`、`AdaptiveAttemptExecutor.ets` 和 `AdaptiveDownloadThrottle.ets` 组成。可信响应头及E1协议接纳先于正文写入；完成还要求最终响应、实际fetch结算、end及队列排空。应用读取/写入块有界，不据此声称SDK或整个进程内存有同样上限。每模块最多256个未结算fetch许可，只有实际Promise结算或可证明尚未启动才归还；API close不冒充网络已经结束。

限速按同一download/run的全部lane、retry实际新增写入字节累计，取有效任务与全局上限的最小值；取消单次等待不抹去已欠额度。网络需求空闲、文件写入、旧prefix复制和限速等待分别处理。主机真实HTTP慢流持续约120秒已验证，不替代目标RCP的时序、缓冲与物理连接证据。

F `AdaptiveAssembler.ets` 捕获完整已提交状态，只读各part的downloaded前缀，忽略物理尾部；输入和输出按64KiB块串行处理。单轨直接拼接，双轨经现有MediaProcessor/NAPI执行remux及受限容器fallback。已封存轨文件和已核实native成功输出先记录事实再处理取消。未核实的预留输出残留只审计、不认领或删除；只有实际ENOENT证明不存在。装配返回不等于用户目录发布或业务完成。

C首次文件close失败后保留sticky资源不确定，停止新/排队IO，未知fd不重试关闭，未知staging不删除。有效另一状态槽可继续提供数据，但不能消除该不确定事实。Media层的取消意图独立于native取消ACK，ACK为false或抛错也禁止启动后续fallback，并保留真实native终值。

P6-U5六步覆盖真实Range下载、慢流、停止与封存、已提交前缀拼接、双轨native入口和失败/取消处理；证据IO在业务资源排空后独立封存。P6-U6继续验证E4 ready lease与F读取/哈希的实际交接，必须等真实读者结束才释放目录所有权。所有设备EXPECT仍为pending-device-run。

后续外层按 `u6-4-hls-outer-integration-design.md` 推进。O1清单请求生命周期详细设计已接受，候选改造尚未计入产品验收；O2–O8是待细化框架。必须完成双源描述及捕获POST上下文、认证/代理、真实live-prefix持久化、沙箱发布和持久回执、Store条件提交/ACK、Manager/UI消费，不能以E4 ready或F输出替代最终完成。
