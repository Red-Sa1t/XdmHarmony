/*
 * U1.2 本地单测入口：testsuite 注册 HttpProtocol/EngineMath/FileNameFormat/ProbeDownloadLogic
 * （U0.2 ProbeHttpLogic 与 U1.1 DownloadTypes/RecordMapping 注册保留）。
 * U2.1 追加：PieceAlgo（分片算法纯函数，14 条——Find/Split 双边界/分裂数学/吸收四条件/
 * inactive 源码原貌/allFinished/windowOf/totalDownloadedOf/sortPiecesByOffset）。
 * U3.1 追加：QueueAlgo（队列调度纯函数，10 条——FIFO/优先级/并列/负值/空表/单元素/
 * 多趟全序/钳制三例）。
 * U3.2 追加：SpeedLimit（限速数学纯函数，13 条——SpeedLimiter.cs:46-82 逐字锚九例 +
 * perWorkerLimitKBps 均摊四例）+ ScheduleAlgo（调度纯函数，13 条——边界次序 end 先 start 后/
 * HasFlag 位匹配/星期位值表/分钟值域）。合计 127+26=153 条。
 * U4.1 追加：StatusText（状态列合成 8 条——四分支+空串视同 null+三停态标签）+
 * CategoryAlgo（分类 12 条——五集合长度/逐串抽查/GetExtension 边缘/AND 语义/iconCategoryKey
 * imageTypes 特有项）+ ListAlgo（排序 8 条——三键升降序/null 名/插入位/翻转矩阵）+
 * ToolbarAlgo（状态机 7 条——进行中 0 选/1 选 active/1 选停态/2 选、完成 1 选/0 选、
 * Waiting 归 pause 分支）。合计 153+35=188 条。
 * U4.2 追加：BatchAlgo（批量生成纯函数 13 条——字母 A-C 逐串 3/no-asterisk/reversed/missing
 * 三空 3/digit 1-3 串比对/补零 D3/负数补零 -001/000/001/两星号全量替换/非法 URL null/预览四链/
 * 预览单链）+ SpeedLimitView（限速装载规范化 6 条——开+正值/关+正值回填/开+零/开+负值/
 * 零速度保存归零投影/负值保存归零投影）。合计 188+19=207 条。
 * U4.3 追加：SettingParse（设置页纯函数 22 条——tryParseInt 10 含 ±符号/1.5/Int32 上界与
 * 2147483648 溢出/空串 + parseExtensionList 5 含不去重锚 + parseCategoryTypes 5 含 CRLF 删/
 * 去重保序 + joinForEdit/clampToRange 2）。合计 207+22=229 条。
 * U5.1 追加：NotifyAlgo（通知决策纯函数 12 条——clampProgress 钳位边界/中值 + finishedSize 回退
 * 正负路 + shouldApplyTask/shouldReleaseTask 跃迁与守卫 + shouldPublishFinish 门控 +
 * pickFinishNotificationId 撞号避让 + 常量值 + 同帧互斥组合）。合计 229+12=241 条。
 * U5.2 追加：FolderAlgo（目录解析纯函数 16 条——updateRecentFolderList 空串/头插/不重排/首插 +
 * manualDownloadFolder Auto null/命中/不在表/空回退/空表 default/边界 + downloadFolderByFileName
 * 命中/大小写/未命中/无扩展名 dotfile 门/空名 + 常量值）。合计 241+16=257 条。
 * U0.3 追加：BridgeProtocol（桥协议纯函数 31 条——parseHead 10 含跨包增量/\r 任意位置丢弃/
 * 大小写敏感键、getContentLength 严格十进制、isKeepAlive 非对称、buildResponseBytes 全字节序、
 * utf8Encode CJK/emoji 代理对、buildSyncJson 八字段序与 23/3/15 项默认表）+ ProbeBridgeLogic
 * （探针客户端纯函数 6 条——splitResponseHead 3 + parseSyncBody 3）。合计 257+36=293 条。
 * U6.1 追加：BridgeRoutes（八路由纯函数 69 条——classifyRoute 3 含 query 不剥/尾斜杠未知、
 * removeBlockedHeaders 5 含黑名单精确等值/一次删除/入参不变、utf8Decode 5 含 CJK/emoji
 * round-trip 与非法字节 U+FFFD、parseExtData 12 含双键兼容/严格类型 throw/多余字段忽略/数字头值
 * 强转收编（R2-F1 真实扩展流量契约）、parseExtDataArray 4、parseArgsArray 4 含数字元素 throw、
 * parseArgs 5 含 --url 整体替换、parseHeaderArg 3、headerValueFirst 4、getContentLengthOf 4、
 * isNormalVideo 6 含五条件逐条、parentDirUri 3、extFromMedia 5 含 audio/mpeg Equals 语义、
 * qualityText 2、getExtensionOf/generateUpdatedFileName 4）。合计 293+69=362 条。
 * U6.2 追加：VideoSniffAlgo（规则链 55 组——A 组 18 isMatchingRequest 八层+sendGate 三态+
 * 非法 URL+端口/userinfo、B 组 6 分派链谓词五件+itag 十二点边界、C 组 8 分派链全流程镜像
 * （m3u8Tabs/referer 跳过/暂态消除/init.mp4/size 门）、D 组 19 YT-DASH 配对全量怪癖
 * （range 尾随 &/同 id 配对/itag=22 短路/大写 ITAG/垃圾 itag/webm/flac mkv 缺点/去重/队尾扫描/
 * lastVid 守卫/稳态 33/最老挤出/octet 不登记/Itags 缺项 MKV/60 项/抽查）、E 组 3 sha1+LinkAccepted、
 * F2 回归 2 空串 file 源语义保留+二次回退——R1-F2）+ BridgeRoutes.test.ets 增补 BridgeConvergence 4 组（收敛 a/b/c：
 * pending 对/vid 未命中静默+命中对话框计数/vid null throw 媒体登记 contentType 空串——import
 * 含 @kit 模块，注记同 U6.1：设备侧 test runner 可跑、本地会话不可实跑）。
 * 合计 362+56+4=422 条断言组（U6.1 F7 头注计数注记随本单元同步修正；R1-F2 复核后 F2 回归 1→2）。
 * U7.1 追加：DashUtil（parseXsDuration 12 条——源测试向量 654000/负前缀/年月日系数/复合小数/
 * IgnoreCase/fallback 双例/宽松秒组与空串 throw）+ DashParser（MpdParser 逐公式 36 条——根门 6
 * 含 type 大小写敏感 quirk、周期 4 含 duration-only 中间周期源误差、三寻址 7 含 AS 级 SegmentBase
 * 被忽略与 Period 级不查、simple 6 含 $Time$ 起点=startNumber/$Bandwidth$ 原始串/$$ 字面、
 * timeline 7 含 t="0" 不重置/r=0 与 r=-1 均 1 段/init $Time$=0、格式化 2 含无 dx 按 d 偏差、
 * 组合与 trickmode 2、parsePeriodDurations 直测 2）+ AdaptivePlan 增补 13 条（buildDashPlan 交错
 * 序与 chunk 形态/尾段追列/duration=max/mime 链三段/恒等式/超预算/空段表/非法 URL/StateCodec
 * Dash roundtrip/dashMimeExtension 20 项抽查/Hls 回归）+ VideoSniffAlgo 增补 10 条（dashQuality
 * 四形态含双空格 quirk/processDashVideo 六场景含单轨首段 quirk）。
 * 合计 569+71=640 条断言组（569 基线=U6.2 后历单元注册总和，头注 422 起未逐单元回填；
 * 实际以 run-hypium.cjs 口径 test_result.txt 为准）。
 */

import downloadTypesTest from './DownloadTypes.test';
import probeHttpLogicTest from './ProbeHttpLogic.test';
import recordMappingTest from './RecordMapping.test';
import httpProtocolTest from './HttpProtocol.test';
import engineMathTest from './EngineMath.test';
import fileNameFormatTest from './FileNameFormat.test';
import probeDownloadLogicTest from './ProbeDownloadLogic.test';
import pieceAlgoTest from './PieceAlgo.test';
import queueAlgoTest from './QueueAlgo.test';
import speedLimitTest from './SpeedLimit.test';
import scheduleAlgoTest from './ScheduleAlgo.test';
import statusTextTest from './StatusText.test';
import categoryAlgoTest from './CategoryAlgo.test';
import listAlgoTest from './ListAlgo.test';
import toolbarAlgoTest from './ToolbarAlgo.test';
import batchAlgoTest from './BatchAlgo.test';
import speedLimitViewTest from './SpeedLimitView.test';
import settingParseTest from './SettingParse.test';
import notifyAlgoTest from './NotifyAlgo.test';
import folderAlgoTest from './FolderAlgo.test';
import bridgeProtocolTest from './BridgeProtocol.test';
import probeBridgeLogicTest from './ProbeBridgeLogic.test';
import bridgeRoutesTest from './BridgeRoutes.test';
import videoSniffAlgoTest from './VideoSniffAlgo.test';
import downloadRequestContextTest from './DownloadRequestContext.test';
import hlsParserTest from './HlsParser.test';
import adaptivePlanTest from './AdaptivePlan.test';
import adaptiveProtocolTest from './AdaptiveProtocol.test';
import adaptiveSchedulerTest from './AdaptiveScheduler.test';
import dashUtilTest from './DashUtil.test';
import dashParserTest from './DashParser.test';

export default function testsuite(): void {
  downloadTypesTest();
  probeHttpLogicTest();
  recordMappingTest();
  httpProtocolTest();
  engineMathTest();
  fileNameFormatTest();
  probeDownloadLogicTest();
  pieceAlgoTest();
  queueAlgoTest();
  speedLimitTest();
  scheduleAlgoTest();
  statusTextTest();
  categoryAlgoTest();
  listAlgoTest();
  toolbarAlgoTest();
  batchAlgoTest();
  speedLimitViewTest();
  settingParseTest();
  notifyAlgoTest();
  folderAlgoTest();
  bridgeProtocolTest();
  probeBridgeLogicTest();
  bridgeRoutesTest();
  videoSniffAlgoTest();
  downloadRequestContextTest();
  hlsParserTest();
  adaptivePlanTest();
  adaptiveProtocolTest();
  adaptiveSchedulerTest();
  dashUtilTest();
  dashParserTest();
}
