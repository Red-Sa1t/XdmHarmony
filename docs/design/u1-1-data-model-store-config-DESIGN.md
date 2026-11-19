# U1.1 数据模型+存储+配置骨架 · 模块设计书

> 单元：U1.1（Phase 1 第 1 单元，关键路径 M1 前置；探针单元 ID `P1-U1`，slug `u1-1-data-model-store-config`）。
> 来源：xdm-migrate 工作流"模块设计师"角色，2026-09-28。
> 依据：MIGRATION_PLAN §5 结构 / §6 决策 10（downloads 表对照 SchemaInitializer 建表，RelationalStore；配置存 preferences）、决策 9 默认值锚（NetworkTimeout=30/MaxRetry=10/RetryDelay=10）；UNIT_CATALOG U1.1 行（验证 [A]+[P]，需数据层探针页）；PROBE_SPEC v1；单元指令七项；源码研究结论（research facts + openQuestions）；U0.2 设计书/EXPECT 的基建惯例（会话代际守卫 isCurrent、dataEnd 超时兜底、纯函数零 @kit import 模式）。
> 对照源码（本会话只读核实，未改 resourses/ 下任何文件）：`XDM.Core/DataAccess/SchemaInitializer.cs:13-47`、`AppDB.cs:38-62`、`DownloadList.cs:15-477`、`XDM.Core/DownloadEntries.cs:7-68`、`ProxyInfo.cs`、`AuthenticationInfo.cs:8-13`、`Downloader/FileNameFetchMode.cs:8-14`、`Application.cs:27-64,114-145,320-345`、`Config.cs:100-122,235-248,152-155`、`Util/PlatformHelper.cs:71-85`、`Downloader/Progressive/HTTPDownloaderBase.cs:296`、`SingleHttp/SingleSourceHTTPDownloader.cs:33`。
> API 核实（本机 SDK 6.1.1(24) d.ts，本会话执行）：`@ohos.data.relationalStore.d.ts` getRdbStore(context,config):Promise（@since 9，:9198）/ getRdbStoreSync（@since 24，:9225）/ StoreConfig.securityLevel（:310）/ SecurityLevel.S1（:1153）/ executeSql(sql,bindArgs?):Promise<void>（:6471）/ insert（:4692）/ update(values,predicates):Promise<number>（:5356）/ querySql（:5967）/ query(predicates)（:5834）/ ResultSet.columnNames（:2760 附近）/ getColumnIndex（:2975）/ getString（:3524）/ getLong（:3584）/ isColumnNull（:4059）/ goToNextRow（:3356）/ close（:4087）/ ValueType 含 null（:201）/ RdbPredicates(name)（:1970）.equalTo(field,value)（:2019）；`@ohos.data.preferences.d.ts` getPreferencesSync（:452）/ getSync（:1114）/ putSync（:1480）/ flush():Promise（:1733）；`@ohos.util.d.ts` generateRandomUUID（:336）。

## 0. 冲突与拍板注记（必读）

1. **模型字段数 15 vs 16**：单元指令写"字段对照 DownloadEntries.cs 15 项"，源码实为 **12 基类字段（DownloadItemBase.cs:9-31）+ 4 进行中字段（InProgressDownloadItem.cs:51-57）= 16 项**（DownloadSpeed/ETA 是 UI 派生、非持久化列）。本设计按 16 项如实声明（研究结论已指出），另加运行时字段 tempDir/downloadedBytes（单元指令要求）。**这是对指令的如实修正，不是扩权**。
2. **CRUD 面单 7 vs 9**：指令点名 add/updateProgress/updateStatus/markAsFinished/remove/queryAll/queryInProgress 七方法；研究结论（DownloadList.cs:332-357 fact）明确 **UpdateDownloadEntry 按同列清单一并实现（U1.2 完成链 Application.cs:117-140 要用）**，且 markAsFinished 完成链同样依赖 **GetDownloadById**。故本单元 API 面 = 指令七方法 + getDownloadById + updateDownloadEntry 共 **9 方法**，与 DownloadList.cs 的其余四方法（UpdateNameAndSize/UpdateNameAndFolder/RemoveAllFinished/UpdateDownloadFolder）**延后至消费单元（U4.x）**——避免注册无消费方的死 API；延后决定记录于 §4 差异表。
3. **UpdateDownloadFolder 源码 bug（研究 openQuestion 1）**：单元指令已拍板——**不复刻**（DownloadList.cs:297-311 绑参数到 cmdUpdateTargetDir 却执行 cmdUpdateProgress，必然异常返 false），按语义正确实现并在迁移报告"有意差异"注明。该方法不在本单元 API 面内（见注记 2），本设计书把该拍板写入 §4，防止后续单元照抄 bug。
4. **重启持久探针的两段式归属（研究 openQuestion 2）**：手册按"AI 自动为主 + 人工兜底"双轨写——AI 会话内用 `hdc shell aa force-stop` + `hdc shell aa start` 完成杀进程/二次拉起并抓日志；人工仅在网络/设备不可自动化时按手册 §4 手动执行同样的两步。EXPECT 的 S8/S9 判定不区分执行者。probeFile（pending JSON）路径由 S8 标记行输出，供人工二次拉起后核对。
5. **getRdbStoreSync @since 24 存在但不采用**：本机 d.ts:9225 核实该同步取库 API 恰好 @since 24（即本工程 API 级）。仍按研究结论用 **异步 getRdbStore + ready Promise 门**：①官方样例与社区基线全是 Promise 形态，@since 24 属临界新 API，运行期行为未经本单元验证；②ready 门同时吸收"CRUD 早于 initialize 调用"的次序问题（U1.2 引擎并发调 store 时天然受保护）；③若对照审查偏好同步版，是一行级替换（§8 备注），不需要返工架构。
6. **module.json5 / main_pages.json 不动（有据，非遗漏）**：本单元引入 RelationalStore/preferences（均为免权限系统 API，本会话 d.ts 核实无 requestPermissions 要求）；无网络/后台任务/剪贴板/深链新能力。module.json5 现状（本会话复核）：deviceTypes=["phone","2in1"]、requestPermissions=[ohos.permission.INTERNET] 已由 U0.1 落地。main_pages.json 只保留 Index 与探针首页（探针子页走页内条件渲染惯例，PROBE_SPEC §1，ProbeIndex.ets:16-19 同构）。若编码时发现缺权限报错（异常态），上报主流程而非擅自改配置。
7. **string.json "业务文案键" 的口径**：U1.1 是纯数据层（无 UI 消费方），本单元只追加 P1-U1 探针三键（标题+两条手动步骤提示）；真实业务文案（下载列表/新建对话框）对照源在 `Lang/English.txt`，随 U1.2 的 UI 落地——避免注册无消费方的死键。已列入 §4 差异表。

## 1. 目标文件清单（按实现顺序）

| # | 文件 | 新/改 | 职责 | 对外导出 | 依赖 |
|---|---|---|---|---|---|
| 1 | `entry/src/main/ets/model/DownloadTypes.ets` | 新 | 共享纯类型层：3+1 个枚举（列值编码锚）+ 3 个 interface（AuthenticationInfo/ProxyInfo/RecordData）。**零 import**，本地单测可直接加载 | `DownloadStatus`、`ProxyType`、`FileNameFetchMode`、`DownloadKind`、`AuthenticationInfo`、`ProxyInfo`、`RecordData` | 无 |
| 2 | `entry/src/main/ets/model/DownloadRecord.ets` | 新 | @Observed 数据模型（16 字段 + tempDir/downloadedBytes 运行时字段）+ 工厂 `newDownloadRecord`（id=util.generateRandomUUID，dateAdded=Date.now，status 按 startType） | `DownloadRecord`（@Observed class）、`newDownloadRecord` | #1、@kit.ArkTS(util) |
| 3 | `entry/src/main/ets/core/db/RecordMapping.ets` | 新 | **纯函数模块（零 @kit import、不 import #2 的 @Observed 类）**：22 列行投影 DownloadRow / 15 列更新投影 UpdateEntryRow + 6 个纯函数（rowFromRecord/recordFromRow/updateEntryRowFromRecord/computeProgress/computeInitialStatus/joinTempDir） | `DownloadRow`、`UpdateEntryRow` 及上述 6 函数 | #1 |
| 4 | `entry/src/main/ets/core/db/DownloadStore.ets` | 新 | RelationalStore 单例（对照 AppDB 双检锁单例 + DownloadList 全方法面）：DDL 逐字建表 + 9 CRUD 方法 + initialize(context) ready 门；异常吞掉返 false/null/空表 | `DownloadStore`、`DownloadLists`、`DOWNLOADS_DB_NAME` | #1 #2 #3、@kit.ArkData、@kit.AbilityKit、@kit.PerformanceAnalysisKit |
| 5 | `entry/src/main/ets/core/Config.ets` | 新 | 配置骨架（preferences，仅 Phase 1 五键）：懒加载单例 + init(context) 同步加载 + 5 getter/5 setter（set 即持久化） | `Config`、`DEFAULT_NETWORK_TIMEOUT/MAX_RETRY/RETRY_DELAY`、`DOWNLOAD_DIR_NAME/TEMP_DIR_NAME`、`CONFIG_PREF_NAME` | @kit.ArkData、@kit.AbilityKit、@kit.PerformanceAnalysisKit |
| 6 | `entry/src/main/ets/entryability/EntryAbility.ets` | 改 | onCreate 挂接：`Config.getInstance().init(this.context)`（同步）+ `DownloadStore.getInstance().initialize(this.context)`（Promise 门，catch 记日志） | —（能力入口） | #4 #5 |
| 7 | `entry/src/main/ets/probe/units/ProbeStore.ets` | 新 | P1-U1 探针页（S0~S9，§6 步骤表）：业务 API 走 #4 单例，原始观测走自开 RdbStore 句柄；S8/S9 手动步骤（runSingle 单步会话）；持久行 pending JSON 落盘 | `ProbeStore`（struct） | #2 #4 #5 #3、probe/core/*、@kit.ArkData、@kit.CoreFileKit |
| 8 | `entry/src/main/ets/probe/ProbeIndex.ets` | 改 | PROBE_UNITS 注册表追加 `{unitId:'P1-U1'}`；else-if 分支追加 `ProbeStore()` | —（@Entry 页） | #7 |
| 9 | `entry/src/main/resources/base/element/string.json` | 改 | 追加 3 键：`probe_p1u1_title`、`probe_p1u1_persist_hint`、`probe_p1u1_verify_hint`（既有键不动，纯 JSON 禁尾逗号） | —（资源） | 无 |
| 10 | `entry/src/test/DownloadTypes.test.ets` | 新 | 枚举列值编码 Hypium 用例（4 条，§7-[A]-2） | default 注册函数 | #1 |
| 11 | `entry/src/test/RecordMapping.test.ets` | 新 | 映射/状态计算纯函数 Hypium 用例（13 条，§7-[A]-3） | default 注册函数 | #3 #1 |
| 12 | `entry/src/test/List.test.ets` | 改 | testsuite 注册 #10 #11（既有 probeHttpLogicTest 注册保留） | `testsuite` | #10 #11 |
| 13 | `docs/probe/PROBE-u1-1-data-model-store-config.md` | 新 | 探针运行手册：无外部测试源依赖；两段式重启持久（AI hdc 自动 + 人工兜底双轨）；预期日志序列表 | —（文档） | #7 #9 |
| 14 | `docs/probe/EXPECT-u1-1-data-model-store-config.json` | 新 | 机器可读预期表（BEGIN/S0~S9/SUMMARY/END 共 13 条目） | —（JSON，须通过 JSON.parse 校验） | #13 |

**显式不动的文件**：`module.json5`（§0-6）、`main_pages.json`（§0-6）、`pages/Index.ets`（U1.2 才改为主列表）、`probe/core/*`（基建业务语义勿动，本单元零修改——U0.2 的 isCurrent/超时兜底直接复用）、`probe/units/ProbeEnv.ets`、`ProbeHttp.ets`、`ProbeHttpLogic.ets`。

## 2. 数据模型与表结构（对照源码逐一核对）

### 2.1 downloads 表：22 列，DDL 逐字对照（SchemaInitializer.cs:13-36）

| # | 列名 | 类型 | 序号读点（LoadDownloads/GetDownloadById） | 写入点 | ArkTS 映射 |
|---|---|---|---|---|---|
| 0 | id | TEXT PRIMARY KEY | 读（GetSafeString(0)） | add（entry.Id） | string |
| 1 | completed | INT | 读（==0 判分型，:59） | add 恒 0（:199）；markAsFinished 置 1（:347） | number（0/1，DownloadKind） |
| 2 | name | TEXT | 读 | add / markAsFinished(file) / UpdateDownloadEntry | string \| null |
| 3 | date_added | INT | 读（FromBinary(GetInt64)） | add（ToBinary，:201）/ UpdateDownloadEntry | number（**epoch 毫秒**，§4-D1） |
| 4 | size | INT | 读（GetInt64） | add / markAsFinished(finalFileSize) / UpdateDownloadEntry | number |
| 5 | status | INT | **不读**（:95 读回强制 Stopped） | add（(int)Status，:203）/ updateStatus | number（DownloadStatus int） |
| 6 | progress | INT | 读（仅 completed=0 行，:96） | add（=0）/ updateProgress | number |
| 7 | download_type | TEXT | 读 | add / UpdateDownloadEntry | string \| null |
| 8 | filenamefetchmode | INT | 读（枚举强转） | add | number（FileNameFetchMode int） |
| 9 | maxspeedlimitinkib | INT | 读 | add | number |
| 10 | targetdir | TEXT | 读 | add / markAsFinished(folder) / UpdateDownloadEntry | string \| null |
| 11 | primary_url | TEXT | 读 | add / UpdateDownloadEntry | string \| null |
| 12 | referer_url | TEXT | 读 | add | string \| null |
| 13 | auth | INT | 读（==1 才进认证分支，:71） | add（HasValue?1:0）/ UpdateDownloadEntry | number |
| 14 | user | TEXT | 读（仅 auth=1 且非 null） | add / UpdateDownloadEntry | string \| null |
| 15 | pass | TEXT | 读（可为 null） | add / UpdateDownloadEntry | string \| null |
| 16 | proxy | INT | 读（ProxyType 强转，:85） | add（(int)(Proxy?.ProxyType??0)）/ UpdateDownloadEntry | number（ProxyType int） |
| 17 | proxy_host | TEXT | 读 | add / UpdateDownloadEntry | string \| null |
| 18 | proxy_port | INT | 读 | add（??0）/ UpdateDownloadEntry | number |
| 19 | proxy_user | TEXT | 读 | add / UpdateDownloadEntry | string \| null |
| 20 | proxy_pass | TEXT | 读 | add / UpdateDownloadEntry | string \| null |
| 21 | proxy_type | INT | **不读** | add 恒硬编码 1（:219）/ UpdateDownloadEntry 恒 1（:259） | number（恒 1） |

- DDL 文本：`CREATE TABLE IF NOT EXISTS downloads(id TEXT PRIMARY KEY, completed INT, name TEXT, date_added INT, size INT, status INT, progress INT, download_type TEXT, filenamefetchmode INT, maxspeedlimitinkib INT, targetdir TEXT, primary_url TEXT, referer_url TEXT, auth INT, user TEXT, pass TEXT, proxy INT, proxy_host TEXT, proxy_port INT, proxy_user TEXT, proxy_pass TEXT, proxy_type INT) WITHOUT ROWID`——列名/顺序/`WITHOUT ROWID` 尾缀**逐字**保留（决策 10）。列序是 SELECT * 按序号读与探针 S1 观测的根基。
- WITHOUT ROWID 降级预案（研究结论）：目标平台 SQLite（3.40.1）若建表报错 → 去尾缀重试，CRUD 等价，仅无 ORDER BY 的 SELECT 自然序语义变化；探针 S1 输出 `ddlTail=` 观测、S0 输出 `errCode=`，出现即按 EXPECT 分支判定并回写。
- 初始化序列对照 AppDB.Init（AppDB.cs:38-62）：文件不存在则建 → 打开 → 建表 → 挂 DownloadList。ArkTS 侧 getRdbStore 自动建库文件（等价前两步）→ executeSql(DDL)（第三步）→ 单例持有（第四步）。库文件落平台 `databaseDir/downloads.db`（对照原版 `AppDir/downloads.db`，Application.cs:29；平台路径差异见 §4-D8）。

### 2.2 DownloadRecord 模型（DownloadEntries.cs:7-58 对照）

@Observed class `DownloadRecord implements RecordData`，字段默认值表：

| 字段 | 类型 | 默认 | 对照 | 说明 |
|---|---|---|---|---|
| id | string | '' | Id（:9） | 工厂置 util.generateRandomUUID()（对照 Guid.NewGuid().ToString()，研究 fact） |
| kind | number | DownloadKind.InProgress(0) | 类分型（InProgress=0/Finished=1） | 单类替代 C# 双类型（§4-D4）；UI 侧按 kind 拆双列表 |
| name | string \| null | null | Name（:11） | |
| dateAdded | number | 0 | DateAdded（:17） | epoch 毫秒 |
| size | number | 0 | Size（:13） | |
| status | number | DownloadStatus.Stopped(1) | Status（:53） | 列值 int；add 时按 startType 置 Waiting(3)/Stopped(1) |
| progress | number | 0 | Progress（:51） | 整数百分比；add 恒 0（Application.cs:55） |
| downloadType | string \| null | null | DownloadType（:19） | |
| fileNameFetchMode | number | FileNameFetchMode.None(0) | FileNameFetchMode（:21） | |
| maxSpeedLimitInKiB | number | 0 | MaxSpeedLimitInKiB（:31） | |
| targetDir | string \| null | null | TargetDir（:15） | |
| primaryUrl | string \| null | null | PrimaryUrl（:23） | |
| refererUrl | string \| null | null | RefererUrl（:25） | |
| authentication | AuthenticationInfo \| null | null | Authentication（:27） | interface{userName: string; password: string \| null}（AuthenticationInfo.cs:8-12） |
| proxy | ProxyInfo | {System, null, 0, null, null} | Proxy（:29） | interface{proxyType: number; host; port; userName; password}（ProxyInfo.cs）；**非 null 接口**：C# 的 null Proxy 语义由工厂默认值等价承载（add 写 proxy=0/四 null 列，逐值一致） |
| downloadSpeed | string \| null | null | DownloadSpeed（:55） | UI 派生，非持久化列 |
| eta | string \| null | null | ETA（:57） | UI 派生，非持久化列 |
| downloadedBytes | number | 0 | **运行时状态**（HTTPDownloaderBase.cs:33 totalDownloadedBytes） | 引擎期有效；重启后的持久真值是 progress 列 |
| tempDir | string | '' | **运行时状态**（SingleSourceHTTPDownloader.cs:33 = TempDir/Id） | joinTempDir(config.tempDir, id) 计算，引擎接管 |

枚举（DownloadTypes.ets，数值即列值，配 Hypium 断言锁序防重排）：
`DownloadStatus{Downloading=0, Stopped=1, Finished=2, Waiting=3}`（DownloadEntries.cs:64-67）、`ProxyType{System=0, Direct=1, Custom=2}`（ProxyInfo.cs:18-22）、`FileNameFetchMode{None=0, FileNameAndExtension=1, ExtensionOnly=2}`（FileNameFetchMode.cs:8-13）、`DownloadKind{InProgress=0, Finished=1}`（completed 列分型键，DownloadList.cs:59-60）。

工厂 `newDownloadRecord(fileName, targetDir, fileSize, downloadType, primaryUrl, startWaiting, authentication, proxy)`：对照 Application.AddItemToTop（Application.cs:43-63）——Progress=0、Status=startWaiting?Waiting(3):Stopped(1)、DateAdded=Date.now()、Id=UUID；proxy 入参可 null→默认 ProxyInfo。

### 2.3 纯类型与行投影（RecordMapping.ets / DownloadTypes.ets）

- `RecordData`（DownloadTypes.ets）：持久化投影 interface，15 字段 = §2.2 前 15 行（不含 downloadSpeed/eta/downloadedBytes/tempDir 三个非持久字段）。DownloadRecord `implements RecordData`（ArkTS 无结构化类型，必须显式 implements）。
- `DownloadRow`（RecordMapping.ets）：22 列定序投影 interface，字段名 = 列名驼峰化（id/completed/name/dateAdded/size/status/progress/downloadType/fileNameFetchMode/maxSpeedLimitInKiB/targetDir/primaryUrl/refererUrl/auth/user/pass/proxy/proxyHost/proxyPort/proxyUser/proxyPass/proxyType）。**契约**：int 列的 NULL→0、TEXT 列的 NULL→null 归一化发生在 store 的 readRow（ResultSet 侧，非纯函数），DownloadRow 本身不携带 null 整数。
- `UpdateEntryRow`（RecordMapping.ets）：UpdateDownloadEntry 的 15 列更新投影（name/dateAdded/size/downloadType/targetDir/primaryUrl/auth/user/pass/proxy/proxyHost/proxyPort/proxyUser/proxyPass/proxyType + id 作 WHERE 参数），**无 status/progress/completed 字段**（DownloadList.cs:239-243 列清单）——用类型结构防"顺手多更新一列"。

### 2.4 Config 骨架五键（Config.cs:100-122,248 对照）

| 键（preferences key） | 默认值 | 对照锚 | 单位/语义 |
|---|---|---|---|
| networkTimeout | 30 | Config.cs:120 `= 30` | **秒**（SingleSourceHTTPDownloader.cs:101 FromSeconds）；U1.2 转毫秒 ×1000 |
| maxRetry | 10 | Config.cs:100 `= 10` | **次数上限**（timesRetried>MaxRetry 抛 MaxRetryFailed） |
| retryDelay | 10 | Config.cs:102 `= 10` | **秒**（sleep(RetryDelay*1000)） |
| downloadDir | `<filesDir>/Downloads` | Config.cs:155 DefaultDownloadFolder=PlatformHelper.GetOsDefaultDownloadFolder()（PlatformHelper.cs:71-85，Windows 已知文件夹/Linux ~/Downloads） | 沙箱无 OS 用户目录概念 → filesDir 下固定名（§4-D7）；Phase 5 DocumentViewPicker 接管 |
| tempDir | `<filesDir>/temp` | Config.cs:248 `TempDir = Path.Combine(DataDir, "temp")`；DataDir=Config.cs:241 | **用 filesDir 不用 cacheDir**：断点续传要求临时文件跨重启存活，cacheDir 可能被系统清理（研究结论）；per-download 子目录 = tempDir/id（:33） |

存储：`@ohos.data.preferences`，实例名 `settings`（对照原版 settings.dat 命名，Config.cs:284 TransactedIO.ReadBytes("settings.dat",...)），`getPreferencesSync` 同步取实例（@since 10，已核实）+ `getSync(key, defValue)` 首跑兜底默认值 + setter `putSync` + `flush()` 异步落盘（catch 记日志不阻塞）。44 键全表留 U4.3（决策 10），本单元只落这 5 键。

### 2.5 观测键 ↔ 源码语义映射（EXPECT 判定式的依据）

| 探针观测键 | 直接来源 | 语义锚 |
|---|---|---|
| colCount / columns / ddlTail | ResultSet.columnNames（querySql LIMIT 0）+ sqlite_master.sql | DDL 列数 22、列名序、WITHOUT ROWID 尾缀 |
| rowsBefore/rowsAfterAdd/rowsAfterRemove | raw COUNT(*) | add +1 / remove -1（同会话内 rowsAfterRemove == rowsBefore，即 remove 恰抵消 add；勘误：曾误写 rowsAfterRemove==rowsAfterAdd，与手册注①同源） |
| raw*（rawStatus/rawProgress/rawCompleted/rawName/rawSize/rawDateAdded） | 自开句柄 querySql WHERE id | **列上原值**（绕过映射强制规则的真值） |
| statusRaw/statusMapped | raw 读 vs queryInProgress 映射记录 | **强制规则观测**：completed=0 行 mapped 恒 1（Stopped），与写入值无关（DownloadList.cs:95,165） |
| inProgressBefore/After、allCount | queryInProgress()/queryAll() | markAsFinished 的 completed 0→1 分型迁移 |
| notFoundNull | getDownloadById(不存在 id) | 未命中返回 null（DownloadList.cs:175） |
| 持久组（S9：rowFound/mappedStatus/rawStatus/rawProgress/dateAddedMatches/…） | 重启后按 pending JSON 的 id 查 | 杀进程重启后行仍在 + 读回强制 Stopped 在重启路径同样成立 |

## 3. 关键算法翻译说明

### 3.1 表结构映射纯函数（RecordMapping.ets——无 IO、零 @kit、可 Hypium）

- `rowFromRecord(data: RecordData): DownloadRow`：INSERT 面（对照 DownloadList.cs:187-219 逐参数）——completed=data.kind（add 路径调用方保证 0）、status=data.status、dateAdded 直通、auth=authentication!==null?1:0、user/pass=authentication?.x??null、proxy=data.proxy.proxyType（非 null 接口下等价 `?? 0`）、proxyPort=data.proxy.port（等价 `?? 0`）、**proxyType=1 恒硬编码**（:219）。
- `recordFromRow(row: DownloadRow): RecordData`：读回面（对照 :55-103）——**强制规则四条**：①kind=row.completed===0?InProgress:Finished；②completed=0 行 status 无条件置 Stopped(1)（raw status 丢弃；completed=1 行保留 raw 值，C# 对完成行不读 status，此处读取仅为单模型字段完整性）；③progress 仅 completed=0 行读入，完成行置 0；④proxy 无条件构造（缺省 System(0)/port 0/其余 null），auth===1 且 user!==null 才构造 AuthenticationInfo（pass 可 null）。id 为 null 归一 ''（PRIMARY KEY 实际不可达，防御）。
- `updateEntryRowFromRecord(data: RecordData): UpdateEntryRow`：15 列更新投影，proxyType=1 恒硬编码（:259），auth/user/pass/proxy 同 rowFromRecord 规则。
- `computeProgress(downloadedBytes, fileSize): number`：fileSize<=0 → 0；否则 `Math.floor(downloadedBytes*100/fileSize)`（对照 HTTPDownloaderBase.cs:296 `(int)(totalDownloadedBytes*100/FileSize)` 的 C# 整数截断，两操作数非负时与 floor 等价）。
- `computeInitialStatus(startWaiting): number`：startWaiting?Waiting(3):Stopped(1)（Application.cs:56）。
- `joinTempDir(baseTempDir, id): string`：`baseTempDir + '/' + id`（对照 Path.Combine(Config.Instance.TempDir, Id)，SingleSourceHTTPDownloader.cs:33）。

### 3.2 线程模型：C# 锁 → 单例 ready 门（对照 AppDB.cs:16-36 双检锁 + DownloadList 全方法 lock(db)）

- C# 的 lock(db) 串行化**不复刻**：RelationalStore 本身线程安全且官方明确不支持 Worker（研究结论引 faqs-local-database-management-42）；主线程单例 + Promise 串行即可，自建锁是负资产。
- `DownloadStore.initialize(context): Promise<void>` memoized ready 门：首次调用 `getRdbStore(context, {name:'downloads.db', securityLevel:S1})` → 成功持有 store → `executeSql(DDL)`；**失败也 memoize**（readyPromise 保持 rejected）——等价 C# Init 失败后应用继续跑、后续所有操作吞异常返 false 的语义（AppDB.cs:56-60 catch + Application.LoadDownloadList 的 try/catch）。
- EntryAbility.onCreate（同步函数）挂接：`Config.getInstance().init(this.context)`（getPreferencesSync，同步无门）+ `DownloadStore.getInstance().initialize(this.context).catch(hilog.error)`（fire-and-forget，不阻塞窗口创建）；store 方法内部 `await this.readyPromise` 再操作，CRUD 早于建表完成时天然排队。
- 异步语义差说明：C# Init 是同步阻塞启动（Application.cs:31 Init→LoadDownloadList 顺序强保证）；ArkTS 侧 LoadDownloadList（U1.2 的 Index 列表填充）必须在 `await initialize()` 之后调用——该次序约束写入本节，U1.2 设计书引用。

### 3.3 异常吞掉语义（C# catch→false 的 1:1 翻译）

DownloadList.cs 全部 11 个公开方法都是 `try{...return true}catch{Log.Debug; return false}`（或 GetDownloadById catch→null、LoadDownloads catch→空表+false）。ArkTS 侧统一形态：

```ts
// 写方法模板（add/updateProgress/updateStatus/markAsFinished/updateDownloadEntry/remove）
try { const s = await this.store(); await s.executeSql(SQL, bindArgs); return true; }
catch (e) { hilog.error(...errCode/errMessage...); return false; }
// 读方法：getDownloadById catch→null；queryAll/queryInProgress/queryFinished catch→空数组（记日志）
```

- 写操作用 `executeSql(sql, bindArgs)`（不返回受影响行数）——C# `ExecuteNonQuery()` 返回值同样被丢弃（0 行受影响也返 true），逐语义一致，避免用 `update()` 的 rowcount 引入"0 行判失败"的偏差。
- 读操作：All=`querySql('SELECT * FROM downloads')`（无谓词，对照 cmdFetchAll）；InProgress/Finished=`RdbPredicates('downloads').equalTo('completed', 0|1)`+`query()`（对照 cmdFetchConditional）；按 id=`querySql('SELECT * FROM downloads WHERE id=?',[id])`。行读取用 `getColumnIndex(name)`+`getString/getLong`（RelationalStore **无 getInt**，Int32 列用 getLong，已核实）+`isColumnNull` 判空（GetSafeString 的 null 语义）。ResultSet 用毕 `close()`（finally）。
- 日志通道：DownloadStore/Config 用 hilog domain 0x0000、tag 'DownloadStore'/'XdmConfig'（业务日志，**绝不**输出 [XDM_PROBE] 前缀——ProbeKit 是唯一探针出口，EntryAbility 红线同源）。

### 3.4 探针会话模型（复用 U0.1/U0.2 基建，零基建改动）

- ProbeStore 复用 `ProbePage`（begin→顺序 await steps→end(ok) 编排 + autoRun=false 步骤的 runSingle 单步会话）与 `ProbeKit`（emit/SUMMARY/probe-latest.txt 兜底）。
- **每个 runner 捕获 runId，每个 await 恢复后、emit 前过 `isCurrent(runId)` 守卫**（U0.2 模式，ProbeHttp.ets:8-9 注释同源）——本探针每个步骤都含 ≥2 个 await（store ready/查询/文件 IO），守卫点必须逐 await 落。
- 无外部测试源依赖（纯本库操作），autoStart=true：页面拉起即自动跑 S0~S7；S8/S9 autoRun=false 按钮触发。

## 4. 有意差异清单（对照源码/计划，含已定降级项）

| # | 差异 | 依据 |
|---|---|---|
| D1 | date_added 存 epoch 毫秒（Date.now()）而非 DateTime.ToBinary() 二进制 | 决策 10"无需兼容原二进制格式"（研究 fact 5） |
| D2 | 持久化引擎 SQLite/文件 → RelationalStore（库文件在平台 databaseDir 而非 AppDir）；配置 settings.dat 二进制 → preferences | 决策 10、§0-6 |
| D3 | UpdateDownloadFolder 源码 bug（DownloadList.cs:307-311 绑定/执行错位必然失败）**不复刻**；该方法延后至 U4.x，实现时按语义正确执行 targetdir 更新并在单元报告注明 | 单元指令拍板（研究 openQuestion 1 关闭） |
| D4 | InProgressDownloadItem/FinishedDownloadItem 双类型 → 单一 @Observed DownloadRecord + kind 字段 | 研究 fact 2 arktsMapping |
| D5 | 读回强制 status=Stopped、status/proxy_type 只写不读、proxy_type 恒写 1——**保真复刻非差异**；updateStatus 写入的值重启后不生效是预期行为（EXPECT 按此判定） | 研究 fact 3 |
| D6 | downloadDir 默认 `<filesDir>/Downloads` 而非 OS 用户 Downloads 目录 | 沙箱无 OS 目录概念；Phase 5 DocumentViewPicker 接管（研究 fact 10） |
| D7 | tempDir 落 filesDir/temp（不用 cacheDir） | 断点续传跨重启存活（研究 fact 10） |
| D8 | lock(db) 串行化 → RelationalStore 线程安全 + 单例 ready 门（不自建锁） | 研究 fact 11 arktsMapping |
| D9 | 模型 16 字段（12+4）+ tempDir/downloadedBytes 运行时字段，非指令字面的 15 | 源码事实（§0-1） |
| D10 | CRUD 面 9 方法（指令 7 + getDownloadById/updateDownloadEntry），UpdateNameAndSize/UpdateNameAndFolder/RemoveAllFinished/UpdateDownloadFolder 延后至消费单元 | §0-2 |
| D11 | C# NULL 整数列读取是异常路径（GetInt32 对 DBNull 抛异常→整个 LoadDownloads 失败返 false）；ArkTS readRow 对 isColumnNull→0/null 归一，单行降级不整表失败 | 防御性 hardening；正常 add 写入路径恒 22 列非空，不触发 |
| D12 | id 列 NULL 归一 ''（C# GetSafeString 可返 null） | 同 D11，PRIMARY KEY 实际不可达 |
| D13 | string.json 本单元只追加探针三键；业务文案随 U1.2（对照 Lang/English.txt） | §0-7 |
| D14 | AuthInfo.pass 映射保留 string \| null（C# struct 引用类型可空语义），消费方（U1.2 Basic 头）自行 `?? ''` | AuthenticationInfo.cs:8-12 + DownloadList.cs:75-82 |
| D15 | WITHOUT ROWID 尾缀保留，失败才降级去尾（降级时在单元报告注明） | 研究 fact 1 |

## 5. 各文件实现要点（可直接照做的接口面）

### 5.1 model/DownloadTypes.ets（新）
枚举与 interface 全量签名见 §2.2/§2.3。约束：全文件零 import；所有类型 export；枚举成员必须带显式 `= 数值` 初始化（列值锚，禁隐式序）。

### 5.2 model/DownloadRecord.ets（新）
- `@Observed export class DownloadRecord implements RecordData { ... }`：字段与默认值按 §2.2 表逐行；proxy 字段默认值用带类型注解的对象字面量（ArkTS 要求字面量有目标类型）。
- `export function newDownloadRecord(fileName: string | null, targetDir: string | null, fileSize: number, downloadType: string | null, primaryUrl: string, startWaiting: boolean, authentication: AuthenticationInfo | null, proxy: ProxyInfo | null): DownloadRecord`——id=util.generateRandomUUID()、dateAdded=Date.now()、status=computeInitialStatus 同款三元（内联，避免 model→db 依赖）、progress=0、downloadedBytes=0、tempDir=''、proxy=null→默认 ProxyInfo。
- 本文件 import @kit.ArkTS(util)，**不进本地单测**（@Observed + @kit 双重原因）；其行为由 #4/#11 的 store 路径与探针覆盖。

### 5.3 core/db/RecordMapping.ets（新）
签名见 §3.1。约束：零 @kit import、不 import DownloadRecord（保证 src/test 可加载）；DownloadRow/UpdateEntryRow interface 全字段显式类型（含 null 联合）；禁正则字面量（本模块用不到，防患）。

### 5.4 core/db/DownloadStore.ets（新）
- `export const DOWNLOADS_DB_NAME: string = 'downloads.db'`（Application.cs:29）；`const DDL_DOWNLOADS` 按 §2.1 逐字；`export interface DownloadLists { inProgress: DownloadRecord[]; finished: DownloadRecord[] }`。
- `export class DownloadStore`：`private static instance`（getInstance() 惰性，对照 AppDB.cs:23-36 单例）；`private store: relationalStore.RdbStore | undefined`；`private readyPromise: Promise<void> | undefined`。
- 方法面（9+1）：`initialize(context: common.Context): Promise<void>`（memoized，§3.2）；`add(record: DownloadRecord): Promise<boolean>`（INSERT 22 列，参数序 = rowFromRecord 字段序 = cmdInsertOne 列序 DownloadList.cs:187-196）；`updateProgress(id: string, progress: number): Promise<boolean>`；`updateStatus(id: string, status: DownloadStatus): Promise<boolean>`；`markAsFinished(id: string, finalFileSize: number, file: string, folder: string): Promise<boolean>`（SQL 文本与参数序对照 :340-347）；`updateDownloadEntry(record: DownloadRecord): Promise<boolean>`（15 列 SET 对照 :239-243）；`remove(id: string): Promise<boolean>`（对照 RemoveDownloadById）；`getDownloadById(id: string): Promise<DownloadRecord | null>`；`queryAll(): Promise<DownloadLists>`（对照 LoadDownloads(QueryMode.All) 双列表填充）；`queryInProgress(): Promise<DownloadRecord[]>`；`queryFinished(): Promise<DownloadRecord[]>`（对照 QueryMode.Finished，DownloadList.cs:471-476）。
- 行装配：`private readRow(rs): DownloadRow`（getColumnIndex by name + isColumnNull 归一）→ `recordFromRow` → `new DownloadRecord()` 字段拷贝（RecordData→@Observed 实例）。
- SQL 语句全部参数化（bindArgs），禁字符串拼接 id（探针传入的 runId 派生 id 亦走参数绑定）。

### 5.5 core/Config.ets（新）
- 常量：`CONFIG_PREF_NAME='settings'`、五键名常量（键名=原版属性名 downloadDir/tempDir/networkTimeout/maxRetry/retryDelay）、`DEFAULT_NETWORK_TIMEOUT=30 / DEFAULT_MAX_RETRY=10 / DEFAULT_RETRY_DELAY=10`、`DOWNLOAD_DIR_NAME='Downloads'`、`TEMP_DIR_NAME='temp'`。
- `export class Config`：`static getInstance(): Config`；`init(context: common.Context): void`（getPreferencesSync 取实例 → filesDir 算出两目录默认 → getSync 逐键读取，ValueType 需 typeof 窄化为 number/string）；getter 五个（getDownloadDir/getTempDir/getNetworkTimeout/getMaxRetry/getRetryDelay）；setter 五个（内存赋值 + putSync + `flush()` 异步 catch 记日志）。
- init 未调用前 getter 返回默认值常量（目录键返 ''）——EntryAbility onCreate 保证先于任何消费方。

### 5.6 entryability/EntryAbility.ets（改）
onCreate 在 resolveTargetPage 之后追加两行挂接（§3.2），catch 用既有 hilog(domain 0x0000, tag 'testTag') 形态记 errCode/errMessage。红线不变：本文件禁 import probe/（U0.1 注释同款）；不发任何 [XDM_PROBE] 标记。

### 5.7 probe/units/ProbeStore.ets（新）
- `const STORE_STEPS: ProbeStepDef[]`：S0~S7 autoRun=true，S8/S9 autoRun=false（title 用行内中文串，同 ProbeHttp 惯例；页面标题/提示用 $r 三键）。
- struct 内 `private probeKit: ProbeKit`；`runStep` 分派到 runS0~runS9；每 runner 首行 `const runId: string = this.probeKit.getRunId()`。
- 双句柄：业务 API 走 `DownloadStore.getInstance()`（先 `await initialize(ctx)` memoized 幂等）；原始观测走自开句柄 `relationalStore.getRdbStore(ctx, {name: DOWNLOADS_DB_NAME, securityLevel: S1})`（S1/S2/S3/S4/S5/S7/S8/S9 的 raw 读 + S0 的 Config；两句柄同库文件，业务先 ready 再开原始句柄，只读不写避免交叉）。
- S8 落盘 `probe-P1-U1-persist.json`（filesDir 下）：`interface PersistPayload { id: string; name: string; size: number; dateAdded: number; progressWritten: number; statusWritten: number }`，fileIo.openSync/writeSync/closeSync（try/finally），标记行只记文件名（PROBE_SPEC §2 大段数据走文件）。
- S9 读 pending 文件（缺失时 emit `pendingFound=false rowFound=false` 即返，合法状态）；JSON.parse 后 `as PersistPayload`（ArkTS 窄化）。

### 5.8 ProbeIndex.ets / string.json / test 三件（改/新）
- ProbeIndex：import ProbeStore；PROBE_UNITS 追加第三项 `{ unitId: 'P1-U1', title: $r('app.string.probe_p1u1_title') }`；build 的 else-if 链追加 `else if (this.selectedUnitId === 'P1-U1') { ProbeStore() }`。
- string.json 追加（既有 19 键不动）：`probe_p1u1_title`="数据层探针（P1-U1）"、`probe_p1u1_persist_hint`="点击 S8 写入重启持久行，然后杀进程重启应用"、`probe_p1u1_verify_hint`="重启拉起本页后点击 S9 核对持久行"。
- List.test.ets：追加 `downloadTypesTest(); recordMappingTest();` 两行注册。

## 6. 探针步骤设计（P1-U1，对应手册/EXPECT）

会话形态：**会话 A**（autoStart，S0~S7 顺序执行）→ 人工/AI 点 S8（**会话 B**，单步）→ 杀进程 → 二次拉起（**会话 C**，S0~S7 自动重跑，顺带复证自动步骤）→ 点 S9（**会话 D**，单步）。每个会话独立 BEGIN/SUMMARY/END 配对，verify 按 runId 取最后会话。

| 步骤 | autoRun | 操作 | 观测点（emit key=value） | 预期锚（EXPECT 判定核心） |
|---|---|---|---|---|
| BEGIN | — | begin(unitId, filesDir) | runId、filesDir | 与 END 按 runId 配对 |
| S0 Config 默认值与读写闭环 | ✔ | init 幂等确认 → 读 3 数值键与 2 目录键 → setMaxRetry(7)→get→setMaxRetry(10)→get | networkTimeout=30 maxRetry=10 retryDelay=10 roundtrip=true downloadDirSuffix=/Downloads tempDirSuffix=/temp | 默认值锚 Config.cs:100/102/120；roundtrip=true 证 preferences 写读闭环 |
| S1 建表 schema | ✔ | 自开句柄 querySql('SELECT * FROM downloads LIMIT 0') 取 columnNames；querySql sqlite_master 取建表 SQL | colCount=22 columns=id/completed/.../proxy_type ddlTail=WITHOUT ROWID | 列数 22 + 列名序逐项；ddlTail 含 WITHOUT ROWID（缺失→§2.1 降级分支或 init 失败分流） |
| S2 add 全 22 列插入 | ✔ | newDownloadRecord(name='probe-u1-'+runId, size=1000, url, startWaiting=false, null auth, null proxy) → store.add() → raw COUNT(*) + raw 按行读回 | id rowAdded=true rowsBefore rowsAfterAdd rawName rawStatus rawCompleted rawDateAdded | rowsAfterAdd=rowsBefore+1；rawCompleted=0；rawStatus=1（Stopped，startWaiting=false）；**id 链路：record.id 必须等于探针 id（工厂内部生成随机 UUID，须在 add 前覆盖；C# AddItemToTop 的 Id=id 直传语义，Application.cs:55）——否则 S2~S8/S9 全部按从未插入的行空转且 ok 旗标全 true（C# ExecuteNonQuery 0 行受影响仍 true，COLD-F1）** |
| S3 updateProgress | ✔ | store.updateProgress(id, 55) → raw 读 progress | progressWritten=55 progressRaw=55 | 列值与写入一致（:272-295 直写直读） |
| S4 updateStatus + 读回强制 | ✔ | store.updateStatus(id, Downloading=0) → raw 读 status → store.queryInProgress() 找同 id 取映射 status | statusWritten=0 statusRaw=0 statusMapped=1 inProgressCount=1 | **statusMapped=1 与写入值 0 无关**（DownloadList.cs:95 强制规则，单会话内实证） |
| S5 markAsFinished + 分型迁移 | ✔ | store.markAsFinished(id, 1000, 'probe-u1-final.bin', filesDir/Downloads) → queryInProgress/queryAll 计数 → raw 读回 | markOk=true inProgressBefore=1 inProgressAfter=0 allCount=1 rawCompleted=1 rawName=probe-u1-final.bin rawSize=1000 | completed 0→1；进行中列表 −1、全表不变（:332-357 + :59-60 分型） |
| S6 getDownloadById 命中/未命中 | ✔ | store.getDownloadById(id)（S5 后的完成行）→ 记 kind；store.getDownloadById('probe-u1-missing-'+runId) | found=true foundKind=1 foundName=probe-u1-final.bin notFoundNull=true | 未命中返 null（:114-177）；完成行 kind=1 |
| S7 remove + 计数复原 | ✔ | store.remove(id) → raw COUNT(*) | removeOk=true rowsAfterRemove | rowsAfterRemove == S2 的 rowsBefore（remove 恰抵消 add，同会话确定性互证） |
| S8 重启持久行写入（手动） | ✘ | id='probe-u1p1-'+runId+'-'+Date.now()（毫秒后缀防同秒重复主键冲突，R3-F1）；add(name='probe-persist-'+runId, size=2000, dateAdded=Date.now()) → updateProgress(id,50) → updateStatus(id, Downloading=0) → raw 读回 → 写 pending JSON 文件 | id persistenceFile=probe-P1-U1-persist.json rawProgress=50 rawStatus=0 | 行**不移除**（持久证据，S8 每按一次累积一行，量级=人工次数，可接受）；pending 文件供 S9 与人工核对 |
| S9 重启后核对（手动） | ✘ | 读 pending JSON → store.getDownloadById(id) → raw 读回同 id 行 | pendingFound rowFound nameMatches sizeMatches dateAddedMatches rawCompleted=0 rawProgress=50 rawStatus=0 mappedStatus=1 | **重启持久核心**：rowFound=true 且各字段逐项相等；mappedStatus=1（重启路径的读回强制规则成立，即"updateStatus 写入的值重启后不生效"） |
| SUMMARY | — | end(ok) 聚合 | 每步关键键单行 <1500B | 12 步段齐全 |
| END | — | ok/steps/elapsedMs | ok=true steps=8 | 自动会话含 S0~S7 共 8 步；S8/S9 为 runSingle 单步会话（steps=1），各自 BEGIN/SUMMARY/END 配对 |

- 值卫生：所有 emit 值经 ProbeKit 消毒（白名单 [A-Za-z0-9_.:/|=-] 与空格）；路径/文件名 ASCII；**不写 PASS/FAIL 词**（S4/S9 的 statusMapped=1 是观测事实，判定在 EXPECT）。
- 会话守卫：S0~S9 每 runner 捕获 runId；每个 await（initialize/querySql/executeSql/fileIo/flush）恢复后 emit 前过 `isCurrent(runId)`，失败静默 return（U0.2 五守卫点模式）。
- 失败形态：任何步骤异常走 catch emit `errCode/errMessage`（观察值，不外抛）；S0~S2 的 errCode 通常指向 store 未就绪/建表失败 → EXPECT 分流 business-code（含 D15 降级分支）。

## 7. 单元验收测试要点

### [A] 静态门禁（编码员每轮自跑）
1. `hvigorw assembleHap`（或 IDE 构建）零 error 零新 warning——ArkTS 严格子集编译期强制（禁 any、对象字面量需类型、无结构化类型等对照 arkts-grammar-standards 自查，codelinter 不含语法规则）。
2. 业务零 probe 依赖：`pages/Index.ets`、`entryability/EntryAbility.ets`、`core/**`、`model/**` 的 import 图不得出现 `probe/`（EntryAbility 只 import core/db + core/Config）。
3. 纯函数 Hypium 本地用例（entry/src/test/，import 路径**从 src/test 出发** `'../main/ets/...'`——U0.2 审查已抓过 `../..` 错；被测模块零 @kit import 已在 #1/#3 落实）：
   - **DownloadTypes.test.ets（4 条）**：downloadStatus_values_matchColumnEncoding（0/1/2/3）；proxyType_values_matchColumnEncoding（0/1/2）；fileNameFetchMode_values_matchColumnEncoding（0/1/2）；downloadKind_values_matchCompletedColumn（0/1）。
   - **RecordMapping.test.ets（13 条）**：rowFromRecord_addPath_defaults（completed=0、proxyType=1 硬编码、auth=0、user/pass=null、proxy=0）；rowFromRecord_withAuthAndProxy（auth=1/user/pass + proxy=2/host/port 透传）；recordFromRow_inProgress_forcesStopped（raw status=0、progress=55 → status=1、progress=55、kind=0）；recordFromRow_finished_noProgress（completed=1 → kind=1、progress=0、status=raw）；recordFromRow_authGate（auth=1+user=null→null；auth=1+user='u'+pass=null→{userName:'u',password:null}；auth=0→null）；recordFromRow_proxyUnconditional（全缺省→System/0/null；有值→透传）；recordFromRow_nullTextPassThrough（name/targetDir/refererUrl=null 保留）；roundTrip_addShape_forcesStoppedOnReload（status=Waiting(3) 的记录 rowFromRecord→recordFromRow 后 status==1——重启读回强制的纯函数级证明）；computeProgress_truncates（50/100→50；1/3→33；299/300→99；300/300→100）；computeProgress_nonPositiveSize_returnsZero（(100,0)→0；(100,-5)→0）；computeInitialStatus（true→3、false→1）；joinTempDir（base+id 拼接）；updateEntryRowFromRecord_15colShape（proxyType=1、auth/user/pass 规则、无 status/progress/completed 字段）。
4. 诚实注记（沿用 U0.2）：本设计会话未运行本地单测执行器（工程无 hvigor wrapper、devecocli 无 test 子命令）；用例照常入库（assembleHap 不编译 src/test），由编码员在 IDE/hvigor LocalUnit 实跑一次并记录，若不可用注明"待 U2.3 统一回归"。

### [P] 运行时（手册承载，xdm-probe-verify 机械判定）
1. 探针 HAP 安装拉起 → 探针首页出现 P1-U1 卡片（ProbeIndex 注册生效）→ 进入自动会话 S0~S7 十一标记齐全（BEGIN/S0..S7/SUMMARY/END）。
2. EXPECT 逐条判定：S1 colCount=22 + 列名序 + ddlTail；S2 计数 +1 与 raw 读回；S3 进度直写直读；S4 statusRaw=0/statusMapped=1 强制规则；S5 分型迁移计数；S6 未命中 null；S7 计数复原。
3. 重启持久两段式：S8（会话 B）→ `hdc shell aa force-stop com.example.xdmharmony` → 二次拉起 → S9（会话 D）rowFound=true + 字段逐项相等 + mappedStatus=1。probeFile=`<filesDir>/probe-P1-U1-persist.json`（BEGIN 行 filesDir= 给出目录）供人工 cat 核对。
4. 验证环境标注：真机优先（探针即普通 HAP）；模拟器兜底。结论与 U0.2 同口径写回计划。

## 8. 风险与备注

| 风险 | 缓解 |
|---|---|
| WITHOUT ROWID 在 RelationalStore 建表失败 | S1 ddlTail + S0 errCode 观测；降级预案 §2.1（去尾缀，CRUD 等价）；降级属 D15 需在单元报告注明 |
| getRdbStoreSync @since 24 未采用（§0-5） | ready 门已覆盖次序问题；如审查推翻本决策，initialize 内一行替换，API 面不变 |
| 探针自开第二 RdbStore 句柄同库并发读 | WAL 默认多读者安全；业务句柄先 ready 再开原始句柄；原始句柄只读不写 |
| S8 累积持久行 | 每按一次累积一行（人工次数量级）；保留作证据（同 probe-http-s1.bin 先例）；如需清理由人工删库文件 |
| probe-latest.txt 只反映最后会话 | 既有 ProbeKit 契约（逐行全量重写）；手册指明 hilog grep 为主、文件兜底；S9 会话结束前不覆盖 S0~S7 证据（hilog 环形缓冲内） |
| init 失败被 memoize 后 CRUD 全 false | 等价 C# 语义（§3.2）；探针 S0~S2 的 errCode 可观测定位 |
| Preferences flush 异步丢失（杀进程时机） | S8 依赖的是 store（RelationalStore 自身事务落盘），非 preferences；Config 的 flush 仅影响配置键，Phase 1 无关键路径依赖 |
| 本地单测执行器不可用 | §7-[A]-4 诚实注记，编码员实跑并记录 |
| U1.2 依赖本单元的次序约束 | §3.2：LoadDownloadList 必须 await initialize() 之后；本节为 U1.2 设计书的引用锚 |

—— 完 ——
