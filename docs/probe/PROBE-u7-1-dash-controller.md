# P7-U1-C DASH 运行控制与续传探针

此入口镜像 ProbeAdaptiveController（P6-U6）的步骤形态，把 E4 状态机的计划源换成 Dash 计划（`buildDashPlan`，主机固定段 URL 直构），覆盖：运行/就绪租约/装配/恢复（S1）、真实暂停与已提交前缀恢复（S2）、读者准入前暂停（S3）、读者准入后传递暂停（S4），并新增目录属主单写者核对（S5）。它不验收清单解析（P7-U1-F/P 覆盖）。当前目标运行状态：待验，未生成目标 PASS 日志。

## 准备与运行

1. 在 PC 项目目录运行固定测试源（与 P7-U1-P 同源）：

   ```powershell
   node docs/probe/P7-U1-dash-host.cjs --host 0.0.0.0 --port 8795
   ```

2. 构建、安装并以既有 `page=probe` want 进入 `probe/ProbeIndex`，选择"DASH 运行控制与续传探针（P7-U1-C）"。测试源填写 `http://<PC局域网IP>:8795`。点击"运行全部"依次执行 S1—S5；全部步骤需要源可达（真实 E4 下载）。
3. 保留一次完整 BEGIN 到 END 的原始 hilog 及派生标记；对照 [EXPECT](EXPECT-u7-1-dash-controller.json) 逐项判定。
4. 每步骤独立 owner（runs/leases 全登记）；S2 的分块停态断言依赖 4 KiBps 限速与 1000ms 暂停时序——设备过快导致分块全完成时按实际记录，不得改 EXPECT 迁就。

## 步骤和自产证据

| 步骤 | 实际操作 | 关键观察 |
| --- | --- | --- |
| S1 | Dash 双轨计划跑通 E4→ready 租约；同 downloadId 第二 run→busy 拒绝；attach→装配回填→双槽指纹不变→释放→freshPlan=null 重开恢复 | firstKind=ready/commitGeneration/leaseCurrent=true/busyErrorCode=AdaptiveOwnerBusy/readyLeaseAttach=true/asmStatus=success/drainClean=true/restoredKind=ready |
| S2 | 单轨（muxed）Dash 计划限速 4 KiBps → 1000ms pause → freshPlan=null 恢复 → 装配 → 前缀 sha256 比对 | pauseTimerFired=true/pausedKind=paused/nonzeroPrefix=true/resumedKind=ready/asmStatus=success/prefixBytesFidelity/oldPrefixUnchanged=true |
| S3 | ready 后先 pause 再 attachReader | stopRequested=true/attached=false（停止后准入拒绝）/cancelledClean=true/leaseReleased=true |
| S4 | attach 后装配中 pause → onStop 传递 | attached=true/asmStatus=success/stopNotifications>0/readerStopNotified=true/stopRequested=true |
| S5 | 同目录第二 controller（同 downloadId） | ownerRejected=AdaptiveOwnerBusy（目录属主单写者） |

## 结果解释和限制

S1 的 `busyErrorCode=AdaptiveOwnerBusy` 同时覆盖"租约持有期"与"目录属主"两个拒绝面（S5 单独钉后者）；两者都是同一主线程 Map 属主表的事实，不是跨进程文件锁。S2 的暂停时序敏感：实际 downloaded=0 或全完成都按观测记录——`nonzeroPrefix=false` 需人工复核限速是否生效，不算自动 FAIL。S3/S4 的停止传递是 lease 契约面（`attachReader` onStop 回调），不证明装配产物完整（S4 装配被取消，`asmStatus` 记录取消态属预期，EXPECT 不要求 success）。

S4 注意：`assemble(owned, run)` 在 reader 运行中触发 `run.controller.pause()`——若装配先于暂停完成，`stopNotifications=0` 如实记录，按 FAIL 分流复核主机吞吐。产物、清单或凭据不出现在标记行；sha256 只作指纹。
