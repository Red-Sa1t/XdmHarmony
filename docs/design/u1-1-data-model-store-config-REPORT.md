# U1.1 数据模型+存储+配置骨架 · 单元迁移报告

> 单元：U1.1（Phase 1 第 1 单元，关键路径 M1 前置）｜探针单元 ID：`P1-U1`
> 报告日期：2026-09-28｜报告角色：xdm-migrate 工作流"报告员"
> 对照源码：`resourses/xdm`（XDM 2023，C#/.NET，GPL-2.0，全程只读，本单元未对其做任何写操作）
> 配套文档：[设计书](./u1-1-data-model-store-config-DESIGN.md)｜[探针手册](../probe/PROBE-u1-1-data-model-store-config.md)｜[预期表](../probe/EXPECT-u1-1-data-model-store-config.json)

**验收结论摘要**：静态验收通过——hvigor 全量编译通过（本报告会话 clean 后全新重编译复证）；对照审查第 4 轮 approved；独立复核 acceptable。运行时验收**待办**——P1-U1 探针尚未在模拟器/真机运行，建表/CRUD/重启持久的行为验证以探针回贴日志为准。遗留 2 个 low 级发现（1 个文档同步、1 个代码防御），均不阻塞验收、已列入下单元建议。

---

## ① 单元范围与验收要点

### 1.1 范围（单元指令七项）

1. `model/DownloadRecord.ets`——@Observed 数据模型，字段对照 `DownloadEntries.cs`（源码实为 12 基类 + 4 进行中 = 16 项，修正指令字面的"15 项"，见 ③-D9）+ 运行时字段 `tempDir`/`downloadedBytes`；
2. `core/db/DownloadStore.ets`——RelationalStore 建表对照 `SchemaInitializer.cs` 22 列；CRUD API 面对照 `DownloadList.cs`；
3. `core/Config.ets` 骨架——仅 Phase 1 五键（downloadDir/tempDir/networkTimeout=30/maxRetry=10/retryDelay=10），默认值对照 `Config.cs`；
4. `EntryAbility.onCreate` 挂接 `DownloadStore` 初始化（context 注入）；
5. `string.json` 补文案键；
6. 数据层探针页 P1-U1；
7. 配置文件显式不动：`module.json5`/`main_pages.json` 零改动（设计书 §0-6 有据：RelationalStore/preferences 均为免权限系统 API，无新能力引入；本报告会话复核 `entry/src/main/module.json5:7-18` 确认 deviceTypes 已含 `2in1`、`requestPermissions` 已含 `ohos.permission.INTERNET`（U0.1 落地），本单元无需追加）。

### 1.2 验收要点与达成状态

| 验收要点 | 状态 | 依据 |
|---|---|---|
| hvigor 编译过 | ✅ 静态通过 | 见 ⑤-1（本报告会话 clean 后全量重编译 BUILD SUCCESSFUL） |
| CRUD 行为逐条对照源码 | ✅ 静态通过 | 见 ② 对应表（逐方法核对 C# 源码行号）；运行时行为待探针 |
| P1-U1 探针可观测建表/CRUD/重启持久 | ⏳ 待人工运行 | 见 ⑥（探针页/手册/预期表已交付，日志未回贴） |

### 1.3 交付文件清单（16 项，状态承自工作流返修循环）

| 文件 | 新/改 | 状态 |
|---|---|---|
| `entry/src/main/ets/model/DownloadTypes.ets` | 新 | ✅（4 枚举 + 3 interface，零 import） |
| `entry/src/main/ets/model/DownloadRecord.ets` | 新 | ✅（COLD-F1 修复轮补工厂 id 语义注释） |
| `entry/src/main/ets/core/db/RecordMapping.ets` | 新 | ✅（6 纯函数 + 2 投影 interface） |
| `entry/src/main/ets/core/db/DownloadStore.ets` | 新 | ✅（DDL 双版 + 9 CRUD + ready 门） |
| `entry/src/main/ets/core/Config.ets` | 新 | ✅（preferences 五键） |
| `entry/src/main/ets/entryability/EntryAbility.ets` | 改 | ✅（onCreate 挂接，:51-55） |
| `entry/src/main/ets/probe/units/ProbeStore.ets` | 新 | ✅（COLD-F1 修复轮补 record.id 链路） |
| `entry/src/main/ets/probe/ProbeIndex.ets` | 改 | ✅（P1-U1 注册 :20/:90-91） |
| `entry/src/main/resources/base/element/string.json` | 改 | ✅（追加探针三键 :76-86） |
| `entry/src/test/DownloadTypes.test.ets` | 新 | ✅（4 用例，未实跑，见 ⑤-5） |
| `entry/src/test/RecordMapping.test.ets` | 新 | ✅（13 用例，未实跑，见 ⑤-5） |
| `entry/src/test/List.test.ets` | 改 | ✅（testsuite 注册 :11/:13） |
| `docs/design/u1-1-data-model-store-config-DESIGN.md` | 新 | ✅（COLD-F1 修复轮补 §6 S2 注记；3 处旧文未同步，见 ④-R4-F1） |
| `docs/probe/PROBE-u1-1-data-model-store-config.md` | 新 | ✅ |
| `docs/probe/EXPECT-u1-1-data-model-store-config.json` | 新 | ✅（13 条目） |
| `module.json5` / `main_pages.json` | 显式不动 | ✅（依据 §1.1-7） |

---

## ② 研究结论摘要（关键源码行为 → ArkTS 对应表）

下表"核实"列标注本报告会话是否亲自读源码/实现核对（✅=本会话已读原文核对；△=采信研究结论，未逐行复读）。

| # | 源码行为（C# 锚点） | ArkTS 对应 | 核实 |
|---|---|---|---|
| 1 | `downloads` 表 22 列 DDL + `WITHOUT ROWID` 尾缀（SchemaInitializer.cs:13-36，本会话复读确认列名/列序/尾缀逐字一致） | `DownloadStore.ets:32-36` `DDL_DOWNLOADS` 逐字保留；降级 DDL（去尾缀）`:40-44`，`createTables :123-140` 先带尾缀、报错才降级并打 hilog（D15 预案，降级实例须探针 S1 `ddlTail=absent` 观测并在单元报告注明） | ✅ |
| 2 | completed 列分型键：`GetInt32(1)==0 → InProgressDownloadItem : FinishedDownloadItem`（DownloadList.cs:59-60）；`AddNewDownload` 签名限定 InProgress 且 `@completed` 硬编码 0（:179/:199）；`MarkAsFinished` 置 1（:347） | 单一 `DownloadRecord` + `kind` 字段（D4）；`rowFromRecord` completed=data.kind（RecordMapping.ets:76）；`markAsFinished` SQL `SET targetdir=?,name=?,size=?,completed=?`（DownloadStore.ets:57/:206-217，参数序 folder,file,finalFileSize,1,id） | ✅ |
| 3 | 读回强制规则：completed=0 行 `inp.Status = DownloadStatus.Stopped` 无条件（DownloadList.cs:95/:165，本会话复读确认）；status 与 proxy_type 两列只写不读；proxy_type 写入恒 1（:219/:259）；progress 仅进行中行读入（:96） | `recordFromRow` R1-R5 强制规则（RecordMapping.ets:103-141，:105-108 即"completed=0 行无条件 Stopped / progress 仅进行中行"）；`rowFromRecord` proxyType 恒 1（:96）；**updateStatus 写入的值重启后不生效按预期判定（保真复刻非缺陷）** | ✅ |
| 4 | 枚举列值锚：DownloadStatus{Downloading=0,Stopped=1,Finished=2,Waiting=3}（DownloadEntries.cs:64-67，本会话复读确认）；ProxyType{System=0,Direct=1,Custom=2}；FileNameFetchMode{None=0,1,2} | `DownloadTypes.ets:18-43` 四枚举显式数值；Hypium 用例逐成员锁序（DownloadTypes.test.ets:14-36）防重排破坏列值对应 | ✅ |
| 5 | add = 22 列全量 INSERT，`date_added=ToBinary()`、auth=HasValue?1:0、proxy=(int)(Proxy?.ProxyType??0)（DownloadList.cs:187-219，本会话复读确认）；异常吞掉 Log.Debug→false（:223-227） | `add()` 22 绑定参数 executeSql（DownloadStore.ets:47-50/:157-174），resolve→true/catch→false 逐语义；`date_added` 存 epoch 毫秒（D1，决策 10 无原格式兼容负担） | ✅ |
| 6 | MarkAsFinished 后完成链：GetDownloadById → 构造 FinishedDownloadItem → UpdateDownloadEntry 15 列更新（Application.cs:115-140；DownloadList.cs:231-270） | `getDownloadById`（:253-272，未命中/异常返 null）+ `updateDownloadEntry`（:220-236，15 列 SET `:59-61`）——U1.2 完成链直接可用；UpdateEntryRow 类型上无 status/progress/completed 字段防"顺手多更新"（RecordMapping.ets:51-67） | △（C# 完成链 Application.cs 未逐行复读，采信研究结论；ArkTS 侧两方法已逐行核对） |
| 7 | 其余 CRUD 面（DownloadList.cs:272-295 updateProgress / :359-380 updateStatus / :448-468 RemoveDownloadById / :42 cmdFetchAll / :50 cmdFetchConditional） | `updateProgress` :177-188、`updateStatus` :192-203、`remove` :239-250、`queryAll` :275-299（completed 分型双列表）、`queryInProgress`/`queryFinished` :302-331（RdbPredicates.equalTo('completed',0/1)）；全部参数化 SQL、ResultSet 用毕 finally close | ✅ |
| 8 | 已知源码 bug：UpdateDownloadFolder 绑参数到 cmdUpdateTargetDir（:307-308）却执行 cmdUpdateProgress.ExecuteNonQuery()（:311，本会话复读确认错位存在）——targetdir 永不更新（cmdUpdateProgress 未创建时直接 NullReferenceException→false） | **不复刻**（D3，单元指令拍板）；该方法不在本单元 9 方法 API 面内，延后至 U4.x 按语义正确实现 | ✅ |
| 9 | 读回 NULL 语义：GetSafeString 对 NULL 返 null；C# 对 NULL 整数列 GetInt32 是异常路径（DBNull 抛→整表加载失败返 false）（DownloadList.cs:55-103） | `readRow` isColumnNull 归一：int→0、text→null、id null→''（DownloadStore.ets:359-385，D11/D12 防御性 hardening，单行降级不整表失败）；Int32 列用 getLong（RelationalStore 无 getInt） | ✅ |
| 10 | 模型 16 字段（DownloadItemBase 12 字段 :9-31 + InProgressDownloadItem 4 字段 :51-57，本会话复读确认；DownloadSpeed/ETA 为 UI 派生非持久化列）；add 时 Progress=0、Status=startWaiting?Waiting:Stopped、Id=Guid.NewGuid()（Application.cs:43-63） | `DownloadRecord` @Observed class 16 字段 + tempDir/downloadedBytes 运行时字段（DownloadRecord.ets:26-72）；工厂 `newDownloadRecord` :81-99（id=util.generateRandomUUID()，**调用方可在 add 前覆盖 record.id**，:78-79 注释，等价 C# Id=id 直传 Application.cs:55） | ✅ |
| 11 | Config 默认值：MaxRetry=10（Config.cs:100）、RetryDelay=10（:102）、NetworkTimeout=30（:120）——本会话复读确认；TempDir=DataDir/temp（:118+241-248）；下载目录=OS 用户 Downloads（PlatformHelper.cs:71-85） | `Config.ets`：`DEFAULT_NETWORK_TIMEOUT=30/DEFAULT_MAX_RETRY=10/DEFAULT_RETRY_DELAY=10`（:35-37）；downloadDir=`<filesDir>/Downloads`、tempDir=`<filesDir>/temp`（:73-74，D6/D7：沙箱无 OS 目录、cacheDir 跨重启可能被清）；单位语义：秒/次数/秒（U1.2 转毫秒 ×1000、sleep×1000）；preferences 实例名 `settings` 对照 settings.dat | ✅（Config.cs 三默认值；TempDir :248 与 PlatformHelper 采信研究） |
| 12 | 初始化序列：Init 建库（AppDir/downloads.db）→建表→挂 DownloadList（AppDB.cs:38-62、Application.cs:27-35）；全方法 lock(db) 串行化；LoadDownloads 异常仅记日志不崩 | `DownloadStore` 惰性单例 + memoized ready Promise 门（DownloadStore.ets:87-100；**失败同样 memoize rejected**，后续 CRUD 全走吞异常路径，等价 C# Init 失败继续运行）；lock(db) 不复刻（RelationalStore 线程安全，D8）；EntryAbility.onCreate：`Config.init(this.context)` 同步 + `initialize(this.context).catch(...)` fire-and-forget（EntryAbility.ets:51-55） | ✅（AppDB.cs 采信研究；ArkTS 侧逐行核对） |
| 13 | 探针可观测点（目标侧约定，PROBE 手册 §4）：S0 Config 默认值+roundtrip、S1 22 列+ddlTail、S2 add 计数+raw 读回、S3/S4 直写直读+强制规则、S5 分型迁移、S6 未命中 null、S7 计数复原、S8/S9 重启持久两段式 | `ProbeStore.ets` S0-S9 十步骤（:139-588），双句柄（业务单例 + 自开 raw 句柄只读观测），pending JSON 落盘（:758-789）；raw* 键为列上原值、statusRaw 与 statusMapped 并存即强制规则观测（:331-335） | ✅ |

---

## ③ 设计决策与有意差异（引用 MIGRATION_PLAN 决策条款）

**决策条款引用**（MIGRATION_PLAN.md §6）：
- **决策 10（存储）**："downloads 表对照 SchemaInitializer 建表（RelationalStore）；配置对照 Config 44 键存 preferences；下载状态 JSON（无需兼容原二进制格式）"——本单元落实前半（22 列表 + preferences 五键骨架），44 键全表留 U4.3。
- **决策 9（HTTP 客户端）**："超时 30s / MaxRetry 10 / RetryDelay 10s（对照 Config 默认值）"——本单元把三个默认值锚进 Config 骨架，单位语义随键交付（秒/次数/秒），消费换算归 U1.2。
- **决策 11（UI）**："@Observed+@ObjectLink 驱动列表进度"——DownloadRecord 以 @Observed 单类交付，U1.2 的 Index 列表按 kind 拆双列表消费。

**有意差异清单**（与设计书 §4 D1-D15 一致，标注引用）：

| # | 差异 | 依据 |
|---|---|---|
| D1 | `date_added` 存 epoch 毫秒（Date.now()）而非 DateTime.ToBinary() | 决策 10"无需兼容原二进制格式" |
| D2 | SQLite/文件 + settings.dat → RelationalStore（databaseDir/downloads.db）+ preferences | 决策 10 平台化 |
| D3 | UpdateDownloadFolder 源码 bug（DownloadList.cs:307-311 绑定/执行错位，本会话核实）不复刻；该方法延后 U4.x 按语义正确实现并注明 | 单元指令拍板（研究 openQuestion 1 关闭） |
| D4 | InProgress/Finished 双 C# 类型 → 单一 @Observed DownloadRecord + kind 字段 | 研究结论 arktsMapping（ArkTS 无结构化类型+UI 拆列消费） |
| D5 | 读回强制规则（status 强制 Stopped、status/proxy_type 只写不读、proxy_type 恒写 1）为**保真复刻非差异**；"updateStatus 写入的值重启后不生效"按预期判定 | DownloadList.cs:95/:165/:219/:259 |
| D6 | downloadDir 默认 `<filesDir>/Downloads` 而非 OS 用户 Downloads | 沙箱无 OS 目录概念；Phase 5 DocumentViewPicker 接管 |
| D7 | tempDir 落 `filesDir/temp` 而非 cacheDir | 断点续传要求临时文件跨重启存活 |
| D8 | lock(db) 串行化 → RelationalStore 线程安全 + 单例 ready Promise 门（getRdbStoreSync @since 24 存在但不采用，设计书 §0-5 论证，一行可替换） | 研究 fact 11 |
| D9 | 模型 16 字段（12+4）+ tempDir/downloadedBytes 运行时字段——修正指令字面的 15 | 源码事实（DownloadEntries.cs 本会话复读确认 12+4） |
| D10 | CRUD 面 9 方法（指令 7 + getDownloadById/updateDownloadEntry，U1.2 完成链依赖）；UpdateNameAndSize/UpdateNameAndFolder/RemoveAllFinished/UpdateDownloadFolder 延后至消费单元 U4.x | 设计书 §0-2（避免无消费方死 API） |
| D11 | C# NULL 整数列读取是整表失败异常路径；ArkTS readRow 按 isColumnNull→0/null 单行归一 | 防御性 hardening；正常 add 路径恒 22 列非空不触发 |
| D12 | id 列 NULL 归一 ''（PRIMARY KEY 实际不可达） | 同 D11 |
| D13 | string.json 本单元只追加探针三键（string.json:76-86）；真实业务文案对照 Lang/English.txt 随 U1.2 落地 | 数据层无 UI 消费方，避免死键 |
| D14 | AuthenticationInfo.password 保留 string\|null，Basic 头消费方（U1.2）自行 ?? '' | AuthenticationInfo.cs:8-12 可空语义 |
| D15 | WITHOUT ROWID 尾缀保留（建表失败才去尾缀降级，降级实例须报告注明） | SQLite 3.40.1 支持；探针 S1 ddlTail 可观测 |

---

## ④ 审查问题处置表（覆盖全部轮次）

**轮次概览**：第 3 轮对照审查 approved=false（1 medium + 2 low）→ 返修（R3-F1）+ 独立复核发现致命问题（COLD-F1）→ COLD-F1 返修 → 第 4 轮 **approved=true**（遗留 2 low）→ 独立复核 **acceptable=true**（遗留同面 2 low）。已修复编号：R3-F1、COLD-F1。

| 编号 | 严重度 | 问题 | 处置 | 证据 |
|---|---|---|---|---|
| COLD-F1 | 致命 | 探针 runS2/runS8 的确定性 id 从未赋给 record（工厂内部恒置随机 UUID），add 落库的行与后续全部按 id 的观测/操作脱节，且 ok 旗标因 C# ExecuteNonQuery"0 行受影响仍 true"语义全 true 掩蔽空转 | **已修复**：两处 add 前补 `record.id = id`（最小改动，等价 C# AddItemToTop 的 Id=id 直传语义）；DownloadRecord 工厂 doc 注释补 id 可覆盖语义；设计书 §6 S2 行补 id 链路注记 | ProbeStore.ets:228-230（runS2）、:493-495（runS8，本会话逐行核实）；DownloadRecord.ets:78-79；设计书 :242 |
| R3-F1 | medium | S8/S9 会话门用 runId 不等判"新会话"，但 ProbeKit.fmtClock 秒级粒度同秒撞号 → 同秒点 S8/S9 被误判自动会话上下文而静默跳过；且门修复后同秒重复 S8 会主键冲突 | **已修复**：门判定改为"当前会话已发标记行数>1"（与 runId 唯一性无关）；S8 持久行 id 追加 `'-'+Date.now()` 毫秒后缀 | ProbeStore.ets:85-95（门，:91 判据）、:487-489（毫秒后缀），本会话逐行核实 |
| R3-F2 | low | 设计书 §6 S7 写 `rowsAfterRemove == S2 的 rowsAfterAdd` 算术不成立（add +1 后 remove 恰抵消，应回 rowsBefore） | 未单独处置，**并入 R4-F1 同面扩大**（文档级），遗留 | 见 R4-F1 |
| R4-F1（=复核-F2，含 R3-F2） | low | 设计书三处与修复后的实现/手册/EXPECT 脱节：:127 与 :247 仍写 `rowsAfterRemove==rowsAfterAdd`（手册 §4 注①与 EXPECT S7 已按修正不变量 `rowsAfterRemove==rowsBefore` 判定）；:248 仍写 id=`probe-u1p1-<runId>` 无毫秒后缀 | **遗留未修**。本报告会话复读设计书核实三处仍为旧文（:127/:247/:248）。纯文档修改、不改机器判定面；转 U1.2 开工前随设计书同步处理（见 ⑧） | 设计书 u1-1-data-model-store-config-DESIGN.md:127/:247/:248（本会话 Read 核实）；对照：ProbeStore.ets:489、EXPECT JSON S7/S8 条目、手册 §4 注① |
| R3-F3（=R4-F2=复核-F3） | low | `add()` 写 row.completed=data.kind，仅靠设计书 §3.1"调用方保证 0"文档约定、无类型层护栏——后续单元若把 kind=1 记录传入 add 会静默写出 completed=1（C# AddNewDownload 签名限定 InProgressDownloadItem :179 + 硬编码 0 :199） | **遗留未修**。本报告会话核实：RecordMapping.ets:76 `completed: data.kind`、DownloadStore.ets:158-159 add 直接透传 rowFromRecord 无强制。现调用方（探针 S2/S8 经 newDownloadRecord，kind 恒 0）不可达；U1.2 引擎接入后它是唯一"静默写坏分型列"路径。处置建议：U1.2 开工前在 store.add() 内一行强制 `DownloadKind.InProgress`（零行为变化，见 ⑧） | RecordMapping.ets:76；DownloadStore.ets:157-174；对照 C# DownloadList.cs:179/:199（本会话复读确认） |

**矛盾核对**：审查 approved 与遗留 low 并存不构成矛盾（approved 附带 low 遗留是流程允许态）；门禁通过与 codelinter 14 条 warning 并存不构成矛盾（codelinter 属提示性辅助，非门禁项，warning 全部为 @performance/avoid-overusing-custom-component 基线同构建议）。未发现"审查说通过但门禁失败"类矛盾。

---

## ⑤ 验证情况

### 5.1 hvigor 编译门禁（主门禁）——✅ 通过

- 编排脚本门禁：`devecocli build --modules entry` 全量编译，最终状态**通过**（工作流提供）。
- 本报告会话复跑（命令与输出如实记录）：
  - `devecocli build clean` → Clean completed successfully；
  - `devecocli build --modules entry` → **BUILD SUCCESSFUL in 18s 476ms**，其中 `:entry:default@CompileArkTS... after 8 s 22 ms` 为清理后**全新编译**（非增量 UP-TO-DATE），仅 1 条 ArkTS warning：`ProbeHttp.ets:230:9 Function may throw exceptions`——属 U0.2 基线文件，非本单元产物；
  - 另有 `WARN: Will skip sign 'hos_hap'`（工程未配 signingConfigs）——模拟器推包不受影响，真机首次需按手册 §0 做一次性签名。
- 结论：**当前代码可构建**，ArkTS 严格子集编译期检查通过。

### 5.2 codelinter 辅助检查（提示性，非门禁）——编排门禁已跑，本会话未复现调用

- 编排脚本门禁输出：exit 0，`Summary: Issues: 14 | Errors: 0 | Warnings: 14 | Suggestions: 0 | Files checked: 3`，14 条 warning 全部为 `@performance/avoid-overusing-custom-component-check`（ProbeStore.ets/ProbeIndex.ets 等 @Component 结构的建议，基线同构，无阻塞项）。
- 诚实注记：本报告会话尝试用 DevEco 内置 codelinter CLI（`plugins/codelinter/index.js`）复跑未成功（`--dir` 参数格式不兼容，报 "Dir json parse error"，随后一次调用报 "Some error occurred during linting"，未产生报告；已清理失败调用在工程根产生的空目录 `undefined`）。**codelinter 结论以编排门禁输出为准，本会话未独立复跑成功。**

### 5.3 对照审查——✅ 第 4 轮 approved

第 3 轮 not approved（R3-F1 medium + F2/F3 low）→ 返修 R3-F1 → 第 4 轮 approved=true（遗留 2 low，见 ④）。

### 5.4 独立复核——✅ acceptable

结论：COLD-F1 修复闭环（探针 id 链贯通、S2~S9 按 EXPECT 全链可判定、ok 旗标不再掩蔽空操作）；weakestSpot 指向 add() completed 契约（遗留 low）与设计书失效不变量（遗留 low）。

### 5.5 本地单测——⚠️ 用例入库、未实跑

`DownloadTypes.test.ets`（4 条）+ `RecordMapping.test.ets`（13 条）已注册进 `List.test.ets:10-14`，但**本单元及本报告会话均未实际运行单测执行器**（工程无 hvigor wrapper、devecocli 无 test 子命令，诚实注记沿用 U0.2；assembleHap 不编译 src/test）。用例属纯函数断言，待 IDE/hvigor LocalUnit 实跑或 U2.3 统一回归。

### 5.6 ArkTS 合规说明

ArkTS 严格子集由 **hvigor 编译期强制**（codelinter 不含 ArkTS 语法规则）——5.1 的全新编译通过即合规证据；编码期对照 arkts-grammar-standards 自查的落点在实现中可见：无 any、对象字面量带类型注解（如 DownloadStore.ets:103-106 StoreConfig、RecordMapping.ets:74-98）、`implements RecordData` 显式继承（DownloadRecord.ets:27）、BusinessError 不可直接 throw 处用 `throw err as Error`（DownloadStore.ets:116 等，注释说明 arkts-limited-throw）、want.parameters Object 值 typeof 窄化（EntryAbility.ets:97-104）。

---

## ⑥ 运行时验证待办（探针 P1-U1）

**状态：探针三件套已交付，尚未运行——运行时行为（建表/CRUD/重启持久）当前未经设备验证。**

- 手册：`docs/probe/PROBE-u1-1-data-model-store-config.md`（运行指引全文）；
- 预期表：`docs/probe/EXPECT-u1-1-data-model-store-config.json`（13 条目：BEGIN/S0~S9/SUMMARY/END，机器可判）；
- 运行模型：**4 会话**——A=进 P1-U1 页自动跑 S0~S7（Config 闭环/建表/add/进度/状态强制/分型迁移/查询/删除）；B=点 S8 写持久行+pending JSON；`hdc shell aa force-stop com.example.xdmharmony` 杀进程 → `hdc shell aa start -b com.example.xdmharmony -a EntryAbility --ps page probe` 二次拉起；C=重启后自动会话复证；D=点 S9 核对持久行（rowFound + 字段逐项相等 + mappedStatus=1）；
- 抓取：`hdc shell "hilog -x | grep XDM_PROBE" > probe-P1-U1.log`；兜底 `cat <filesDir>/probe-latest.txt` 与 `cat <filesDir>/probe-P1-U1-persist.json`（BEGIN 行 filesDir= 给出目录）；业务侧诊断 `grep -E 'DownloadStore|XdmConfig'`；
- 关键预期（防误判）：S4/S9 的 `statusRaw=0 与 statusMapped=1 并存=预期 PASS`（读回强制规则保真复刻，D5）；S1 `ddlTail=absent` 且 CRUD 正常=D15 降级生效非 FAIL（须回写单元报告）；S9 pendingFound=false rowFound=false=UNVERIFIED（先跑 S8）；
- 回贴后由 `xdm-probe-verify` 工作流逐步骤核对，结论按真机/模拟器环境标注写回 MIGRATION_PLAN。

---

## ⑦ 遗留问题与风险

| # | 项 | 等级 | 说明 |
|---|---|---|---|
| 1 | add() 无 completed 硬编码护栏（R3-F3/R4-F2/复核-F3） | low（现不可达，U1.2 后成真路径） | 唯一"静默写坏分型列"路径；建议 U1.2 开工前一行修掉（⑧-1） |
| 2 | 设计书三处旧文（R4-F1/复核-F2）：:127/:247 失效不变量、:248 id 无毫秒后缀 | low（文档级） | 后续单元若引用设计书而非 EXPECT 会被误导；随 U1.2 设计书同步（⑧-2） |
| 3 | P1-U1 探针未运行 | 高优先待办 | 建表/CRUD/重启持久的运行时验证全部悬置；探针是一次性验收工具，应在 U1.2 编码前跑掉（结论是完成链实现输入） |
| 4 | 本地单测 17 条未实跑 | low | 执行器不可用；U2.3 统一回归（⑤-5） |
| 5 | D15 WITHOUT ROWID 降级分支未实测 | low | 目标平台 SQLite 拒绝尾缀时才触发；降级路径已有代码（DownloadStore.ets:123-140）+ 探针观测（S1 ddlTail + hilog "retry without suffix"）；若触发须在报告注明 |
| 6 | S8 每按一次累积一行持久行 | 信息 | 有意保留作证据（同 probe-http-s1.bin 先例）；如需清理由人工删库文件 |
| 7 | Config flush 异步、杀进程时机可能丢最后一次 setter | low | RelationalStore 侧（S8/S9 持久验证）不受影响；preferences 仅配置键，Phase 1 无关键路径依赖（设计书 §8） |
| 8 | getRdbStoreSync @since 24 未采用 | 信息 | ready 门已覆盖次序问题；若后续推翻是一行替换，API 面不变（设计书 §0-5/§8） |

---

## ⑧ 对下个单元（U1.2 单线程下载+主列表+新建对话框）的建议

1. **开工前先还两笔技术债**（均为一行级）：① `DownloadStore.add()` 内加 `row.completed = DownloadKind.InProgress` 强制（或运行时校验拒 kind≠0），与 C#:199 硬编码对齐——引擎接入后 add 是唯一分型列写入点，务必在消费前闭合；② 设计书 :127/:247/:248 三处同步为 `rowsAfterRemove == rowsBefore` 与 `probe-u1p1-<runId>-<epoch毫秒>`，U1.2 设计书引用本单元设计书时以 EXPECT 为准。
2. **次序约束**（设计书 §3.2）：U1.2 的列表装载必须 `await DownloadStore.getInstance().initialize(ctx)` 之后调用——C# Application.cs:31 Init→LoadDownloadList 顺序强保证在异步侧由 ready 门承接；onCreate 已 fire-and-forget 初始化，消费方 await 同一 memoized Promise 即可。
3. **完成链直接可用**：`markAsFinished → getDownloadById → updateDownloadEntry`（Application.cs:115-140 对照）三方法已就绪，U1.2 完成流程无需新增存储 API。
4. **配置消费换算**：networkTimeout 秒→毫秒 ×1000；retryDelay 秒→sleep×1000；Basic 认证头 password 用 `?? ''`（D14）；tempDir 用 `joinTempDir(config.tempDir, id)` 取 per-download 子目录。
5. **保真输入**：P1-U1 探针结论（22 列列序、读回强制规则观测）是 U1.2 的实现输入；"重启后条目一律 Stopped"直接影响 Index 列表初始状态渲染，勿按"读回 status"直觉实现。
6. **UI 面**：Index 改造为列表页时按 kind 拆双列表（@Observed+@ObjectLink，决策 11）；新建对话框对照 INewDownloadDialog 契约最小子集；业务文案此时才对照 `Lang/English.txt` 落 string.json（D13 口径）。
7. **跑探针**：U1.2 编码开始前先在模拟器跑 P1-U1 并回贴日志（探针 HAP 累积安装，一次拉起可同时复证 U0.x 探针）。

---

## ⑨ git 提交说明

本单元代码**未做 git 提交**。按单元流程，提交与打 tag 由人工执行：AI 每单元产出迁移报告作为验收输入，人工在 Phase 级验收（真机试用 + 走查）后提交并 `git tag phase-N`（MIGRATION_PLAN §9-3/§10、UNIT_CATALOG"提交与验收"节）。本单元属 Phase 1 首单元，建议人工验收（含探针回贴核对通过）后与 U1.2 一并纳入 phase-1 前的单元粒度回滚点。

—— 完 ——
