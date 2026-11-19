# P7-U1-F DASH 解析纯函数探针

此入口覆盖 U7.1 的纯函数面：`DashUtil.parseXsDuration`（DashUtil.cs:8-40 直译）、`DashParser` 的 `buildMpdTree`/`parseDashManifestFromEvents`（MpdParser.cs 431 行语义翻译：根门/三寻址/Timeline 状态机/多周期逆算/模板变量）与真机 `xml.parseXml`（@ohos.xml Pull 路径）的事件结构实测。四个 MPD 向量逐字取自 `XDM_Tests/DashSanityTest.cs`，以行内常量注入 `parseDashManifestFromEvents`（事件注入式，零网络）。它不验收下载、装配或播放（P7-U1-P/C 覆盖）。当前目标运行状态：待验，未生成目标 PASS 日志。

## 准备与运行

1. 本探针**无需测试源**：全部向量行内注入，无网络请求。直接构建、安装并以既有 `page=probe` want 进入 `probe/ProbeIndex`，选择"DASH 解析纯函数探针（P7-U1-F）"，点击"运行全部"依次执行 S1—S6。设备操作方式遵循 [PROBE_SPEC](../PROBE_SPEC.md)。
2. （可选交叉核对）`node docs/probe/P7-U1-dash-host.cjs --host 0.0.0.0 --port 8795` 后，可在 P7-U1-P 的源地址填 `http://<PC局域网IP>:8795`；host 同时以 `application/dash+xml` 提供同一组向量（`/mpd/smooth|bbc|sintel|multiperiod`）与反例（`/mpd/dynamic|encrypted|noperiod|wrongroot`），供人工浏览器核对向量原文，不参与本探针判定。
3. 保留一次完整 BEGIN 到 END 的原始 hilog 及派生标记，记录设备/ABI、API、应用构建哈希、时间、显示 runId。离开页面后缺失 END 是实际中断证据，不得借旧运行补全。
4. 对照 [EXPECT](EXPECT-u7-1-dash-foundation.json) 逐项判定。**S1 的 `attrCallbackOrder` 是实测钉板项**：首次真机运行记录的 token↔attr 相对序即契约值，与回贴日志不一致按 FAIL 分流。

## 步骤和自产证据

| 步骤 | 实际操作 | 关键观察 |
| --- | --- | --- |
| S1 | 真机 `xml.parseXml`（ignoreNameSpace=true、supportDoctype=false、拒 DOCDECL/ENTITY）解析 Smooth 向量，直接注册 token+attr 回调记录相对序；另经 `DashXmlFeed.decodeMpdEvents`+`buildMpdTree` 统计树 | rootName/根属性数/nodeCount/maxDepth/attrCallbackOrder（T=START_TAG、A=attr、E=END_TAG、X=TEXT，实测钉板）/selfClosingCount |
| S2 | 逐例跑 `parseXsDuration`：10 值用例（源测试向量 654000、-PT30S、PT0S、P1Y/P2M/P3D 系数、复合小数、pt1h、fallback 0 与 1.5）+2 throw 用例（"1.2.3"、空串） | durationCases=10、durationOk、pt0h10m54、throwOk |
| S3 | Smooth 向量端到端（解码→语义）；音频计数用解析器结果与独立 Σ(1+max(r,0)) 事件扫描双算一致性钉住 | videoSegmentsCount=91（init+89+1）/videoInitI/videoLastTime（末段 $Time$ 值）/audioSegmentsCount/audioSumCheck/timelineSumAll/pairCount=16 |
| S4 | Sintel 向量端到端（simple 寻址+模板变量，startNumber=0、$$ 字面 $） | videoSegmentsCount=179（init+178）/audioSegmentsCount=175（init+174）/audioMediaCount=174/startNumberZero/dollarLiteral/videoInitTail |
| S5 | 多周期向量端到端（index/list/timeline 三寻址同现）+ 行内 t="0" 小向量核 quirk | periodCount=2/p1Items=2（单轨 video，SegmentBase index 单段）/p2Pairs=4/p2ListSegments=11（init+10）/p2TimelineSegments=10/tzeroFirst=s500.ts/tzeroSecond=s600.ts/tEqualsZeroQuirk |
| S6 | dynamic/encrypted/no-period/非 MPD 四反例逐个 throw + BBC 向量（%06d 补零） | 四 rejected=true/bbcPairs=15/bbcVideoSegmentsCount=151（init+150）/bbcFirstNumber=000001 |

每步骤独立 owner + `ProbeKit.isCurrent` 会话守卫；探针无文件/网络资源，取消即作废会话。所有事实进标记行（每行 <1500 字节），无 detailFile 导出——证据即标记行本身。

## DASH 公共测试流指引（真机公网核对，人工一次）

- **双轨 static 正向流**：`https://dash.akamaized.net/dash264/TestCasesMCA/fraunhofer/xHE-AAC_Stereo/2/Sintel/sintel_audio_video_brs.mpd`（即 Sintel 向量源，video×audio 笛卡尔 4 对）；`https://rdmedia.bbc.co.uk/dash/ondemand/testcard/1/client_manifest-zeroth.mpd`（BBC 研究院测试卡，双轨 static）。公网可达性人工确认一次；把它们填入 P7-U1-P 源地址可观察真实 CDN 分段下载。
- **拒绝路径观察**：任一 `type="dynamic"` 直播清单（如 akamai live test 或 ncam.mozit.fr 的 live MPD）应被根门拒绝；含 ContentProtection 的 DRM 清单（如 BBC 的 DRM 变体）应报 encrypted。
- 向量与公共流公式不一致时，以公共流实测为准并回写 EXPECT 差异；本地验收判定一律走 host cjs 固定向量。

## 结果解释和限制

S1 的 `attrCallbackOrder`/`selfClosingCount`/`eventCount` 是 SDK 回调合同的实测事实：文档未给 token↔attr 跨回调顺序保证（SDK facts 明示），适配器对两种先后序均成立；若实测序与回贴差异导致树构建失败，属 FAIL 分流返修，不得为凑序改 EXPECT。S2—S6 全部为纯函数公式面：它们不证明 @ohos.xml 在真机的内存预算行为、不证明网络、不证明任何产物可播。S3 的 audioSegmentsCount 由解析器与独立事件扫描双算一致钉住，不预填手数；`videoLastTime=1781780000` 为公式推导值（20020000×89），量级异常即 FAIL。四反例 throw=整清单丢弃语义（源异常上抛同效），"不拒"观测照实记录。

`node --check docs/probe/P7-U1-dash-host.cjs` 与本机冒烟（段字节图案 first=20/33、Range 206）只证明主机脚本自身，不证明设备侧解析。
