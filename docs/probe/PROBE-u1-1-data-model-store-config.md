# 探针运行手册：P1-U1 数据层探针（数据模型+存储+配置骨架）

> 工程根：D:\git\HarmonyPC\XdmHarmony ｜ bundle：com.neuohos.xdm ｜ 预期表：[EXPECT-u1-1-data-model-store-config.json](./EXPECT-u1-1-data-model-store-config.json)
> hdc 未入 PATH，用全路径：HDC="D:\Tools\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
> 探针页形态：**autoStart=true**——进入 P1-U1 页即自动跑 S0~S7（8 步）；S8/S9 为手动步骤（各带"执行"按钮，runSingle 单步会话）。

## 0. 一次性准备

```bash
# 真机（推荐验证环境）：真机拒绝未签名 HAP，首次必须做——
devecocli auth login                              # 华为账号登录
#   USB 连接真机并开启开发者模式/USB 调试后：
devecocli signature generate --product default    # 注册设备+生成签名材料，自动写入 build-profile.json5
# 模拟器（兜底/形态验证）：推包不需要签名
devecocli emulator list                           # 确认实例（本机已有 "Pura 90"）
```

## 1. 测试源

**无外部测试源**——S0~S9 全部是应用沙箱内操作（RelationalStore `databaseDir/downloads.db` +
preferences `settings` + filesDir pending 文件），不依赖主机服务、不依赖网络。

## 2. 运行探针（设备侧）

```bash
cd /d D:\git\HarmonyPC\XdmHarmony
devecocli run --module entry                      # 构建+安装+拉起应用主页（AI 已构建过时：加 --skip-build）
# 打开探针页（EntryAbility 解析 want 参数 page=probe，支持冷/暖启动）：
hdc shell aa start -b com.neuohos.xdm -a EntryAbility --ps page probe
```

> 模板差异说明：本工程无独立探针 Ability（module.json5 仅声明 mainElement=EntryAbility）——探针页由
> EntryAbility 解析 want 参数 `page=probe` 拉起（U0.1 路由契约，冷/暖启动均支持），通用模板中的
> `--ability ProbeAbility` 形态不适用于本工程。

### 会话模型（4 会话，每会话独立 BEGIN/SUMMARY/END 按 runId 配对）

| 会话 | 触发 | 内容 |
|---|---|---|
| A | 进入 P1-U1 页自动 | S0~S7 顺序 8 步（Config 闭环/建表/add/进度/状态/完成/查询/删除） |
| B | 点 **S8 执行** | 单步会话：写持久行 + pending JSON 落盘（steps=1） |
| C | 杀进程后再次进入页自动 | S0~S7 顺序 8 步（同 A，顺带复证自动步骤在重启后仍绿） |
| D | 点 **S9 执行** | 单步会话：读 pending JSON 核对持久行（steps=1） |

### 两段式重启持久（主轨 AI 自动 + 人工兜底双轨）

```bash
# 会话 B：探针页 P1-U1 → 点 S8"执行"（确认 [XDM_PROBE][P1-U1][S8] 行出现）
hdc shell aa force-stop com.neuohos.xdm    # 杀进程（等价断电，非退后台）
hdc shell aa start -b com.neuohos.xdm -a EntryAbility --ps page probe   # 二次拉起
# 会话 C 自动跑完后进入 P1-U1 → 点 S9"执行"（会话 D）
```

- **人工兜底**（设备无法 hdc 连接时）：最近任务里划掉应用（或设置-应用管理-停止）→ 桌面图标拉起 → 探针首页 → P1-U1 → 点 S9。步骤与 AI 主轨完全一致，EXPECT 的 S8/S9 判定不区分执行者。
- pending 文件：`<filesDir>/probe-P1-U1-persist.json`（BEGIN 行 `filesDir=` 给出目录前缀），供 S9 与人工核对。
- **S8 可重复按**：每按一次累积一行持久行（不移除，保留作证据，同 probe-http-s1.bin 先例）；pending JSON 每次覆盖为最新行，S9 核对的是最新一行。

### 需人工配合的步骤

- 探针页内点 **S8 执行**（S8 前）与 **S9 执行**（重启拉起后）——页面顶部两行提示文案即操作指引。
- 重启动作：主轨由 AI 用上面两条 hdc 命令自动完成；仅 hdc 不可用时人工兜底。
- 真机首次：§0 签名准备；模拟器无需。

## 3. 抓取标记（探针跑完后）

```bash
hdc shell "hilog -x | grep XDM_PROBE" > probe-P1-U1.log
# 兜底：缓冲被冲掉时取探针写盘结果（路径见 BEGIN 行 filesDir=；注意 probe-latest.txt 只反映最后会话）
hdc shell "cat <filesDir>/probe-latest.txt"
# pending JSON 人工核对（S9 的磁盘侧第二证据）：
hdc shell "cat <filesDir>/probe-P1-U1-persist.json"
# 探针闪退时：devecocli log --crash
# 业务侧诊断（建库/建表/CRUD 吞掉的异常走这里，非探针标记）：
hdc shell "hilog -x | grep -E 'DownloadStore|XdmConfig'"
```

## 4. 每步骤预期日志标记表（判定细则见 EXPECT 表）

hilog 过滤 `XDM_PROBE` 后，自动会话（A/C）各 11 行、S8/S9 单步会话各 4 行，行格式严格为
`[XDM_PROBE][P1-U1][<步骤>] key=value ...`（FORMAT 正则 `^\[XDM_PROBE\]\[([A-Z0-9-]+)\]\[([A-Za-z0-9-]+)\]\s(.+)$`）。
`<N>` 表浮动值。下表与 EXPECT 表 steps 一一对应（13 条目）。

| 步骤 | 预期标记行（示例） | 判定要点 |
|---|---|---|
| BEGIN | `[XDM_PROBE][P1-U1][BEGIN] runId=<HHmmss> filesDir=<非空沙箱files路径>` | 与 END 按 runId 配对；A/C 会话进页自动产生，S8/S9 各自独立 BEGIN |
| S0 | `networkTimeout=30 maxRetry=10 retryDelay=10 roundtrip=true downloadDirSuffix=/Downloads tempDirSuffix=/temp` | 默认值锚 Config.cs:120/100/102；roundtrip=setMaxRetry(7)→get=7→恢复10→get=10 的 preferences 写读闭环；目录后缀为 pathSuffix 观测 |
| S1 | `colCount=22 columns=id/completed/name/date_added/size/status/progress/download_type/filenamefetchmode/maxspeedlimitinkib/targetdir/primary_url/referer_url/auth/user/pass/proxy/proxy_host/proxy_port/proxy_user/proxy_pass/proxy_type ddlTail=WITHOUT ROWID` | 22 列名与顺序逐项（SchemaInitializer.cs:13-36 根基）；ddlTail 缺失→§5 D15 分支 |
| S2 | `id=probe-u1-<runId> rowAdded=true rowsBefore=<N> rowsAfterAdd=<N>+1 rawName=probe-u1-<runId> rawStatus=1 rawCompleted=0 rawDateAdded=<epoch毫秒>` | rowsAfterAdd=rowsBefore+1（raw COUNT 互证）；rawCompleted=0（add 恒 0）；rawStatus=1（startWaiting=false→Stopped）；raw* 为列上原值（自开句柄绕过映射） |
| S3 | `id=probe-u1-<runId> progressWritten=55 progressRaw=55` | 进度直写直读（DownloadList.cs:272-295），progressRaw=列上原值 |
| S4 | `id=probe-u1-<runId> statusWritten=0 statusRaw=0 statusMapped=1 inProgressCount=<N>>=1` | **强制规则观测**：statusRaw=0（写入生效）与 statusMapped=1（completed=0 行读回一律 Stopped，:95）并存=保真复刻非缺陷；inProgressCount 含 S8 累积行时 >1，statusMapped 按 id 匹配项判定 |
| S5 | `id=probe-u1-<runId> markOk=true inProgressBefore=<N> inProgressAfter=<N>-1 allCount=<M> rawCompleted=1 rawName=probe-u1-final.bin rawSize=1000` | completed 0→1 分型迁移；allCount==S2 的 rowsAfterAdd（S2~S5 间无增删）；rawName/rawSize 为 markAsFinished 落库值 |
| S6 | `id=probe-u1-<runId> found=true foundKind=1 foundName=probe-u1-final.bin notFoundNull=true` | 未命中返 null（:114-177）；完成行 kind=1 |
| S7 | `id=probe-u1-<runId> removeOk=true rowsAfterRemove=<N>` | **rowsAfterRemove == S2 的 rowsBefore**（remove 恰抵消 add；设计书 §6 表格写"==rowsAfterAdd"系算术笔误——add 使计数 +1、remove 抵消该行，EXPECT 按修正不变量判定，见本节注①） |
| S8 | `id=probe-u1p1-<runId>-<epoch毫秒> addOk=true progressOk=true statusOk=true persistenceFile=probe-P1-U1-persist.json rawProgress=50 rawStatus=0` | 单步会话（steps=1）；rawProgress=50/rawStatus=0 为列上原值（写入生效）；持久行不移除；id 毫秒后缀使同秒重复 S8 主键唯一（R3-F1）；pending JSON 供 S9 与人工核对 |
| S9 | `pendingFound=true id=probe-u1p1-<上次会话runId>-<epoch毫秒> rowFound=true nameMatches=true sizeMatches=true dateAddedMatches=true rawCompleted=0 rawProgress=50 rawStatus=0 mappedStatus=1` | **重启持久核心**：rowFound=true 且 name/size/dateAdded 逐项相等；mappedStatus=1（重启路径读回强制规则成立）与 rawStatus=0（列上原值仍在）并存 |
| SUMMARY | `[XDM_PROBE][P1-U1][SUMMARY] S0=<...>|S1=<...>|…` | 自动会话恰 8 段（S0..S7），S8/S9 单步会话各 1 段；环形缓冲兜底锚 |
| END | 自动会话 `ok=true steps=8 elapsedMs=<N>>=0`；单步会话 `ok=true steps=1` | ok=true=无脚手架级异常；steps 与该会话步骤行数互证；无孤儿 BEGIN/END |

注意：

- ① S7 不变量修正：设计书 §6 表格"rowsAfterRemove == S2 的 rowsAfterAdd"算术上不可能成立（rowsAfterAdd=rowsBefore+1，remove 后回到 rowsBefore），且 S8 累积持久行会抬高 rowsBefore——正确不变量为 **rowsAfterRemove == S2 的 rowsBefore**，EXPECT 按修正值判定。
- ② S8/S9 会话门：自动会话按数组序也会触达 S8/S9，但分派层跳过（不发标记行，END steps=8）——探针页上 S8/S9 徽标此时显示"已完成"属 UI 外观，**以 hilog 标记行为准**（自动会话内不应出现 S8/S9 标记行）。
- ③ S4/S9 的 statusMapped=1 是"completed=0 行读回一律 Stopped"强制规则的观测事实（保真复刻，设计书 D5）——**updateStatus 写入的值重启后不生效是预期行为**，判 PASS 不判 FAIL；探针标记行不含通过/失败判定词，判定全部在 EXPECT/verify 侧。
- ④ 任一步骤失败形态：该步行以 `errCode/errMessage` 键组替代正常键集（每步骤仍恰一行）；业务侧吞掉的异常细节查 hilog tag `DownloadStore`/`XdmConfig`（domain 0x0000，非 [XDM_PROBE] 行）。

## 5. 环境差异分支（重跑指引）

| 现象 | 判定 | 处置 |
|---|---|---|
| S1 `ddlTail=absent` 且 S2~S7 CRUD 正常 | D15 降级生效（WITHOUT ROWID 尾缀被目标平台 SQLite 拒绝，store 去尾缀重试成功） | **非 FAIL**——查 hilog `DownloadStore` 有 "retry without suffix" 行佐证，回写单元报告注明降级实例 |
| S0/S1/S2 步行出现 `errCode/errMessage`（建库/建表失败，ready 门 memoize rejected） | FAIL | 分流 business-code/probe-code：先查 hilog `DownloadStore` 业务日志定位（库文件权限/磁盘满/SQL 语法） |
| S9 `pendingFound=false rowFound=false` | UNVERIFIED | 未跑过 S8 或 pending 文件被清——先跑会话 B（S8）再按 §2 重启跑会话 D（S9） |
| S9 `pendingFound=true` 但 `rowFound=false` | FAIL | 分流 business-code（杀进程后持久行丢失——RelationalStore 落盘/沙箱清理问题） |
| S9 各 matches 出现 false（rowFound=true 时） | FAIL | 分流 business-code（读回映射错误或 dateAdded 落库精度问题），附 raw* 键组定位 |
| S4 `inProgressCount` 不含 id 匹配项（statusMapped=-1） | FAIL | 分流 probe-code/business-code（S2 行未落库或 completed 列写值错误） |
| 模拟器 vs 真机 | — | 本单元无设备差异面（本地库操作）；结论按实际运行环境标注回写计划（与 U0.2 同口径） |

## 6. 会话守卫冒烟（U0.2 同款硬要求）

1. 自动会话 A 运行中（任一步骤进行中）按 HOME 退后台；
2. 暖启动重进探针首页 → P1-U1（autoStart 会开新一轮会话）；
3. 预期：新会话标记行完整、BEGIN/END 的 runId 单调配对、**无旧会话步骤标记行串入新会话、无孤儿 END**（旧会话异步续体在 await 恢复后过 isCurrent 守卫静默退出）；
4. 自动会话运行中点 S8/S9"执行"：被 ProbePage.sessionRunning 守卫忽略（不产生会话）——等 END 后再点。

## 7. 回贴

把 probe-P1-U1.log 全文（[XDM_PROBE] 行一律不要手工删改）发给 AI，由 xdm-probe-verify 核对；
结论（含验证环境：真机/模拟器）与 U0.2 同口径写回 MIGRATION_PLAN，DDL 列序/读回强制规则的观测事实
作为 U1.2 完成链（MarkAsFinished→GetDownloadById→UpdateDownloadEntry）的实现输入。
