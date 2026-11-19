/*
 * U6.1 /media 嗅探纯数学模块 → U6.2 全量规则链（设计书 u6-2-sniff-rule-chain-video-capture-DESIGN.md §2/§3）。
 * U6.1 子集（零改动保留）：IsNormalVideo 五条件 + ProcessNormalVideo 纯数学（parentDirUri/
 * extFromMedia/qualityText/getExtensionOf/generateUpdatedFileName）。
 * U6.2 增量（设计书 §0-1 双镜像口径）：
 *   ① isMatchingRequest 八层镜像+passesSendGate（chrome-extension/request-watcher.js:49-98 ——
 *      "五层规则链"落位勘误：链文本在扩展端而非 VideoUrlHelper.cs，本会话只读核实）。**纯函数
 *      规格件：用例表载体+U6.3 扩展复用行为基准，禁止接入 /media 服务端链**（源拓扑该过滤只在
 *      扩展端 :105，服务端再跑即双重过滤，设计书 §0-1 红线）。
 *   ② 分派链谓词五件（VideoUrlHelper.cs:716-761）：IsYtFormat/IsHLS/IsHLSUrl/IsDASH/IsDASHUrl
 *      +IsNormalVideo(itag) 三区间（:697-700）。
 *   ③ YT-DASH 段配对全量（:409-613）：ProcessYtDashSegment/AddToQueue/AddIfNew/GetDASHPair/
 *      HandleDashAudio/CreateDualSourceHTTPDownloadInfo + Itags 表 60 项（:906-965 逐行清点，
 *      研究结论 63 为勘误，Node 用例 D22 钉死）+ DashInfo（:969-979）。
 *   ④ SHA1 纯 TS（:897-902 ComputeHash 的 FIPS 180-4 镜像；node:crypto 交叉验证
 *      sha1('abc')='a9993e36470698a983e259040d7036b31f7d5f7'——不用 cryptoFramework 保零 @kit
 *      纪律与 Node 自验能力，差异登记 §4-10）。
 * 零 @kit 引用——Hypium 本地单测可直接加载；Node 用例脚本（docs/probe 目录
 * P6-U2-sniff-cases.js）为本模块的 JS 行为镜像，双份用例表同源同验。
 * 对照源码（本会话只读核实，未改 resourses/ 下任何文件）：
 *   request-watcher.js:49-90  —— isMatchingRequest 八层（①blockedHosts host 子串 ②mediaExts
 *                pathname 大写 endsWith ③requestFileExts ④urlPatterns try/catch ⑤Content-Type
 *                mediaTypes 子串 ⑥fileExts '.'+ext endsWith ⑦Content-Disposition '.'+ext 子串
 *                ⑧matchingHosts host 子串；全不中 → 隐式 undefined=拒）。
 *   request-watcher.js:92-98  —— onSendHeadersEvent 门：GET 恒过；非 GET 需 matchingHosts 某 h
 *                使 url.indexOf(h)**严格大于 0**（下标 0 不算，源怪癖 1:1）。
 *   VideoUrlHelper.cs:26-33  —— 静态五件 → SniffState 注入化投影（U6.1 §3.8 先例）：
 *                referersToSkip 的 Dictionary<string,DateTime> 降为 Set<string>——源时间戳值只写
 *                不读（IsMediaFragment :873-886 命中即刷新但从不比较时间），键存在性即全部语义。
 *   VideoUrlHelper.cs:409-545 —— ProcessYtDashSegment：host 门（url.Host 含 '.youtube.' 或
 *                '.googlevideo.'——裸域不含前导点串不过门）→ contentType 门（首值小写含 audio//
 *                video//application/octet）→ url 门（小写含 videoplayback 且 itag）→ 参数重组
 *                （:430-484 逐行：ParseKeyValuePair(url,'?') 拆 path/query；query.Split('&') 逐项
 *                ParseKeyValuePair(str,'=')，key 空或以 'range' 开头 → continue **不追加进 yt_url**；
 *                itag/clen 精确等值键 Int32/Int64.Parse（严格十进制，垃圾 → 异常 → 外层 catch →
 *                return false 落普通视频门）；mime 以 'mime' 开头 → Uri.UnescapeDataString；
 *                **str（原始参数串）以 'id' 开头 → id=val（'identity=x' 命中怪癖）**；非跳过项
 *                追加 str 且 i<length-1 时追加 '&'——末位参数被跳过时前一参数留尾随 '&'（D6））
 *                → 短路口（itag!==0 && IsNormalVideo(itag) → return false）→ DashInfo 构造 →
 *                AddToQueue 成功 → HandleDashAudio（音频侧）/GetDASHPair/CreateDual；整段
 *                try/catch 吞异常 return false（:543 catch {}）。
 *   VideoUrlHelper.cs:547-587 —— HandleDashAudio：ext=Path.GetExtension(GetFileName(info.Url))
 *                为空 → mime 含 webm→'.webm'/mp4→'.mp4'/**否则 'mkv' 缺前导点**（怪癖 1:1 保留，
 *                设计书 §0-3：文件名 '名字mkv' 无点分隔、显示 '[KV AUDIO]'——ext.Substring(1) 吞 K）。
 *   VideoUrlHelper.cs:589-613 —— CreateDualSourceHTTPDownloadInfo：video=IsVideo 侧、audio=另一；
 *                File=sanitize(file ?? GetFileName(url))+'.mkv'；ContentLength=两段和。
 *   VideoUrlHelper.cs:697-700 —— IsNormalVideo(itag)：4<n<79 || 81<n<86 || 99<n<103。
 *   VideoUrlHelper.cs:702-714 —— AddIfNew：自**队尾**向队首按 (Length,ID) 双等值去重，命中
 *                返回 false 不入队。
 *   VideoUrlHelper.cs:763-784 —— AddToQueue：**入队前**两队列各自 Count>32 → RemoveAt(0)
 *                （稳态上限 33，非 32；1:1 保留设计书 §4-5）。
 *   VideoUrlHelper.cs:786-823 —— GetDASHPair：视频段自 audioQueue 队尾找 id 等值（无守卫）；
 *                音频段自 videoQueue 队尾找 id 等值，命中时 **lastVid!=null && lastVid.Length==di.Length
 *                → null**（同一段视频不被连续两条音频重复配对），否则 lastVid=di 返回。
 *   VideoUrlHelper.cs:888-895 —— AddToSkippedRefererList：空/null 忽略；否则写 sha1 键
 *                （编排侧 BridgeRoutes 接线，本模块只出 sha1Hex）。
 *   VideoUrlHelper.cs:904-966 —— Itags 60 项（'Hi  bitrate' 双空格 :918/:940 逐字；查不到
 *                默认 'MKV' :528 GetValueOrDefault 兜底）。
 *   ParsingHelper.cs:13-21 —— ParseKeyValuePair：Trim→首分隔符下标<1 → ('','')；两段 Trim。
 * U7.1 增量（设计书 u7-1-dash-DESIGN.md §4.9）：DASH 捕获条目映射纯函数三件——
 *   dashQuality（VideoUrlHelper.cs:298-331 GetQualityString 逐字符：双轨=高度+带宽+' '+语言段/
 *   video-only=高度+带宽/audio-only=语言+带宽（序不同）；双空格/尾随空格 quirk 钉死）+
 *   processDashVideo（:202-273 条目映射半区：多周期前缀 "N "/ext 双 mime 子串包含规则/1&1 降级
 *   dual/全量段 multi/★单轨只取 Segments[0] quirk）+ DashCaptureItem 三形态联合
 *   （网络半区在 BridgeRoutes.processDashCapture、登记半区=tracker 三写入方）。
 * 有意差异（设计书 §4）：Itags 平行数组+itagQuality（禁 Record<number,..>——ArkTS Record 键必须
 *   string）；parseInt64Gate 以 Number.MAX_SAFE_INTEGER 为上界（§4-6）；Uri.UnescapeDataString →
 *   decodeURIComponent try/catch 近似（非法序列保留原样，§4-7 尾注）；手写 hostOfUrl/urlPathOf
 *   替代 new Uri/new URL（WHATWG pathname 百分号/空路径规范化不复刻，§4-12；userinfo 剥离、端口
 *   保留按 u.host 语义；非法 URL → false=源扩展端异常中止净效果）。
 * 写入接线（§3.5）：本模块不 import tracker——第 8 步登记动作经注入回调 SegSink 上报
 *   （onSingle/onDual），BridgeRoutes 组装回调调 tracker 写入方；handleDashAudio/createDualInfo
 *   在纯函数内只产 SegSingle/SegDual 数据。
 * ArkTS 红线：无 any/解构/for...in/正则字面量（INT64 十进制门 new RegExp）；对象字面量均具
 *   interface/class 类型；throw 只抛 Error；显式返回类型。
 */

import { sanitizeFileName, fileNameFromUrl } from '../util/FileNames';
import { formatSize } from '../util/Formatting';
import { BridgeHeaders } from './BridgeProtocol';
import { BridgeMessage, headerValueFirst } from './BridgeJson';
import { DashPair, DashRepresentation } from '../adaptive/DashModel';

/** 嗅探共享状态（VideoUrlHelper.cs:26-33 五静态件的注入化投影）：
 * suspectedFragments —— 疑似 MP4 分片父目录集（isNormalVideo 条件③写入、④读取）；
 * m3u8Tabs —— 触发过 m3u8/mpd manifest 的 tab id 集（U6.2 起 BridgeRoutes 在 HLS/DASH 识别
 *             命中时写入——写入点=源 manifest 拉取之前的源序，网络无关，设计书 §0-2）；
 * referersToSkip —— 应跳过的 referer 的 sha1 键集（键存在性即全部语义，§2.2）；
 * videoQueue/audioQueue —— YT-DASH 配对双队列（:28-29 List<DashInfo>）；
 * lastVid —— 最近配出的视频段（:27，null 初始化；GetDASHPair 守卫用）。 */
export interface SniffState {
  suspectedFragments: Set<string>;
  m3u8Tabs: Set<string>;
  referersToSkip: Set<string>;
  videoQueue: DashInfo[];
  audioQueue: DashInfo[];
  lastVid: DashInfo | null;
}

/** 全新嗅探状态（三集皆空、双队列空、lastVid=null）。 */
export function createSniffState(): SniffState {
  const state: SniffState = {
    suspectedFragments: new Set<string>(),
    m3u8Tabs: new Set<string>(),
    referersToSkip: new Set<string>(),
    videoQueue: [],
    audioQueue: [],
    lastVid: null
  };
  return state;
}

/** URL 父目录规整（`new Uri(new Uri(url), ".").AbsoluteUri` 等价，VideoUrlHelper.cs:77/:82）：
 * 去 query/fragment → 取最后一个 '/'（含）前缀；末段为空（尾斜杠）→ 原样；无 '/' → 原样。
 * 样例：'https://h/a/b/init.mp4?x=1'→'https://h/a/b/'；'https://h/a/b/'→'https://h/a/b/'；
 * 'https://h/init.mp4'→'https://h/'。纯函数，Hypium 用例钉死。 */
export function parentDirUri(url: string): string {
  let clean: string = url;
  const qm: number = clean.indexOf('?');
  if (qm >= 0) {
    clean = clean.slice(0, qm);
  }
  const hash: number = clean.indexOf('#');
  if (hash >= 0) {
    clean = clean.slice(0, hash);
  }
  const slash: number = clean.lastIndexOf('/');
  if (slash < 0) {
    return clean;
  }
  return clean.slice(0, slash + 1);
}

/** IsNormalVideo 五条件 1:1（VideoUrlHelper.cs:67-90；大小写敏感性逐处保留）：
 * ① size>0 且 size<minBytes → false（minBytes=Config.MinVideoSize*1024，默认 1024KB）；
 * ② tabId 非空且 state.m3u8Tabs.has(tabId) → false；
 * ③ url.toLowerCase() 含 'init.mp4' → suspectedFragments.add(parentDirUri(url))、false
 *    （**有副作用**，单线程事件循环下安全）；
 * ④ suspectedFragments.has(parentDirUri(url)) → false；
 * ⑤ contentType 非 null 且不含 f4f/m4s、url（**原始大小写**）不含 abst/f4x/.fbcdn/
 *    http://127.0.0.1:9614 → true；contentType 为 null → false。 */
export function isNormalVideo(state: SniffState, contentType: string | null, url: string,
  size: number, tabId: string | null, minBytes: number): boolean {
  if (size > 0 && size < minBytes) {
    return false;
  }
  if (tabId !== null && tabId.length > 0 && state.m3u8Tabs.has(tabId)) {
    return false;
  }
  if (url.toLowerCase().indexOf('init.mp4') >= 0) {
    state.suspectedFragments.add(parentDirUri(url));
    return false;
  }
  if (state.suspectedFragments.has(parentDirUri(url))) {
    return false;
  }
  return contentType !== null && !(contentType.indexOf('f4f') >= 0 ||
    contentType.indexOf('m4s') >= 0 || url.indexOf('abst') >= 0 ||
    url.indexOf('f4x') >= 0 || url.indexOf('.fbcdn') >= 0 ||
    url.indexOf('http://127.0.0.1:9614') >= 0);
}

/** Content-Type/URL → 扩展名映射（VideoUrlHelper.cs:631-675 映射序逐分支；入参均已小写化，
 * 调用方负责 toLowerCase）：video/mp4→mp4、video/x-flv→flv、video/webm→mkv、含 matroska 或
 * mkv→mkv、**type==='audio/mpeg'（等值）或含 'audio/mp3'→mp3**、含 audio/aac→aac、含
 * audio/mp4→m4a、url 含 .mp4→mp4、.mkv→mkv、.ts→ts；全不中 → null（调用方 return）。 */
export function extFromMedia(typeLower: string, urlLower: string): string | null {
  if (typeLower.indexOf('video/mp4') >= 0) {
    return 'mp4';
  }
  if (typeLower.indexOf('video/x-flv') >= 0) {
    return 'flv';
  }
  if (typeLower.indexOf('video/webm') >= 0) {
    return 'mkv';
  }
  if (typeLower.indexOf('matroska') >= 0 || typeLower.indexOf('mkv') >= 0) {
    return 'mkv';
  }
  if (typeLower === 'audio/mpeg' || typeLower.indexOf('audio/mp3') >= 0) {
    return 'mp3';
  }
  if (typeLower.indexOf('audio/aac') >= 0) {
    return 'aac';
  }
  if (typeLower.indexOf('audio/mp4') >= 0) {
    return 'm4a';
  }
  if (urlLower.indexOf('.mp4') >= 0) {
    return 'mp4';
  }
  if (urlLower.indexOf('.mkv') >= 0) {
    return 'mkv';
  }
  if (urlLower.indexOf('.ts') >= 0) {
    return 'ts';
  }
  return null;
}

/** 质量描述文本（VideoUrlHelper.cs:687 逐字）：'[' + ext 大写 + '] ' + (size>0 ?
 * formatSize(size) : '')——size=0 时尾随空格保留。 */
export function qualityText(ext: string, size: number): string {
  return '[' + ext.toUpperCase() + '] ' + (size > 0 ? formatSize(size) : '');
}

/** Path.GetExtension 子集：取最后一段分隔符（'/'或'\\'较大下标）后，末段最后一个 '.' 起（含点）；
 * 末段无 '.' → ''；'.bashrc' → '.bashrc'（dotfile 视为扩展名，C# Path.GetExtension 同貌）。 */
export function getExtensionOf(name: string): string {
  const slash: number = name.lastIndexOf('/');
  const backslash: number = name.lastIndexOf('\\');
  const cut: number = slash > backslash ? slash : backslash;
  const lastSeg: string = cut >= 0 ? name.slice(cut + 1) : name;
  const dot: number = lastSeg.lastIndexOf('.');
  if (dot < 0) {
    return '';
  }
  return lastSeg.slice(dot);
}

/** 标题回写文件名合成（VideoTracker.cs:36-45 GenerateUpdatedFileName）：ext=旧文件扩展名 →
 * file=sanitizeFileName(newName) → ext 非空拼接（扩展名保留）。 */
export function generateUpdatedFileName(oldFile: string, newName: string): string {
  const ext: string = getExtensionOf(oldFile);
  let file: string = sanitizeFileName(newName);
  if (ext.length > 0) {
    file += ext;
  }
  return file;
}

/** 源 FileHelper.SanitizeFileName 的**空串语义**镜像（''→'' 空 in 空 out，FileHelper.cs:17-20
 * 对空串 Split/Join 产出 ''）：FileNames.sanitizeFileName 的 'file' 兜底（D6 修正版，UI 命名
 * 场景防空名）会把空串变非空、堵死源侧各消费点的空串行为（R1-F2）——HandleDashAudio/
 * CreateDual 的文件名在源侧空串 file 时产出裸扩展名（''+ext，VideoUrlHelper.cs:568/:608），
 * 本 helper 供嗅探登记路径取得与源一致的空串语义。 */
function sanitizeOrEmpty(name: string): string {
  return name.length === 0 ? '' : sanitizeFileName(name);
}

// ────────────── U6.2 增量：扩展端规则链纯函数规格件（设计书 §3.2，禁接业务链） ──────────────

/** isMatchingRequest 入参配置（/sync 八字段的扩展端投影，设计书 §2.3）：
 * blockedHosts ← Config.getBlockedHosts()（默认 3 项）；mediaExts/urlPatternRes ← /sync 从不发送
 * 的恒空层（保留参数位钉死层序）；requestFileExts ← getVideoExtensions()（15 项大写无点）；
 * fileExts ← getFileExtensions()（23 项）；mediaTypes ← SYNC_MEDIA_TYPES；matchingHosts ←
 * SYNC_MATCHING_HOSTS。 */
export interface SniffRuleConfig {
  blockedHosts: string[];
  mediaExts: string[];
  requestFileExts: string[];
  urlPatternRes: RegExp[];
  fileExts: string[];
  mediaTypes: string[];
  matchingHosts: string[];
}

/** URL host 投影（WHATWG u.host 语义子集，设计书 §3.2/§4-12）：'://' 后 authority（终止于
 * 首个 '/'、'?'、'#'），剥 '@' 前 userinfo、**保留端口**；无 '://' 或空 authority → ''
 * （非法 URL——源 new URL 抛异常使 webRequest 监听器中止的净效果由调用方 false 承载）。 */
export function hostOfUrl(url: string): string {
  const schemeEnd: number = url.indexOf('://');
  if (schemeEnd < 0) {
    return '';
  }
  const rest: string = url.slice(schemeEnd + 3);
  let end: number = rest.length;
  const slash: number = rest.indexOf('/');
  if (slash >= 0 && slash < end) {
    end = slash;
  }
  const qm: number = rest.indexOf('?');
  if (qm >= 0 && qm < end) {
    end = qm;
  }
  const hash: number = rest.indexOf('#');
  if (hash >= 0 && hash < end) {
    end = hash;
  }
  const authority: string = rest.slice(0, end);
  const at: number = authority.lastIndexOf('@');
  return at >= 0 ? authority.slice(at + 1) : authority;
}

/** URL pathname 投影（WHATWG u.pathname 语义子集）：authority 后首 '/' 起、至 '?'/'#' 止、不含
 * query；authority 后无 '/' → ''（源 chrome 端 upath 逐层 endsWith 比较面，空串自然不命中）。 */
export function urlPathOf(url: string): string {
  const schemeEnd: number = url.indexOf('://');
  if (schemeEnd < 0) {
    return '';
  }
  const rest: string = url.slice(schemeEnd + 3);
  const slash: number = rest.indexOf('/');
  if (slash < 0) {
    return '';
  }
  let path: string = rest.slice(slash);
  const qm: number = path.indexOf('?');
  if (qm >= 0) {
    path = path.slice(0, qm);
  }
  const hash: number = path.indexOf('#');
  if (hash >= 0) {
    path = path.slice(0, hash);
  }
  return path;
}

/** 大写名精确等值头查找（request-watcher.js:73/:82 find(h => h["name"].toUpperCase()===...)：
 * 返回 names 下标；miss → -1。 */
function indexOfHeaderUpper(h: BridgeHeaders, upperName: string): number {
  for (let i = 0; i < h.names.length; i++) {
    if (h.names[i].toUpperCase() === upperName) {
      return i;
    }
  }
  return -1;
}

/** 首值取用（chrome 头对象 {name,value} 单值语义；空值表 → ''——正常流量不触达）。 */
function firstValueOf(h: BridgeHeaders, idx: number): string {
  const vals: string[] = h.values[idx];
  return vals.length > 0 ? vals[0] : '';
}

/**
 * 扩展端请求过滤八层镜像（request-watcher.js:49-90 逐层，序数敏感逐处保留）：
 * 非法 URL（hostOfUrl ''：无 '://' 或空 authority）→ false（源 new URL 抛 → 监听器中止）；
 * ① host.indexOf(blockedHosts[i])>=0 → false（大写 host 漏屏蔽=源 indexOf 序数敏感怪癖，A17）；
 * ② upath.endsWith(mediaExts[i]) → true（/sync 恒空层，保留层序）；
 * ③ upath.endsWith(requestFileExts[i]) → true；
 * ④ urlPatternRes[i].test(url) → true（try/catch 吞执行异常，:67-71；恒空层）；
 * ⑤ CONTENT-TYPE 首值.indexOf(mediaTypes[m])>=0 → true；
 * ⑥ upath.endsWith('.'+fileExts[i]) → true；
 * ⑦ CONTENT-DISPOSITION 首值大写.indexOf('.'+fileExts[i])>=0 → true；
 * ⑧ host.indexOf(matchingHosts[i])>=0 → true；全不中 → false（源隐式 undefined）。
 * **纯函数规格件：仅供用例表与 U6.3 扩展复用对照，禁止接入 /media 服务端链（§0-1 红线——
 * 源拓扑该过滤只在扩展端 :105，服务端再跑即双重过滤）。**
 */
export function isMatchingRequest(cfg: SniffRuleConfig, url: string,
  responseHeaders: BridgeHeaders): boolean {
  const host: string = hostOfUrl(url);
  if (host.length === 0) {
    return false;
  }
  for (let i = 0; i < cfg.blockedHosts.length; i++) {
    if (host.indexOf(cfg.blockedHosts[i]) >= 0) {
      return false;
    }
  }
  const upath: string = urlPathOf(url).toUpperCase();
  for (let i = 0; i < cfg.mediaExts.length; i++) {
    if (upath.endsWith(cfg.mediaExts[i])) {
      return true;
    }
  }
  for (let i = 0; i < cfg.requestFileExts.length; i++) {
    if (upath.endsWith(cfg.requestFileExts[i])) {
      return true;
    }
  }
  try {
    for (let i = 0; i < cfg.urlPatternRes.length; i++) {
      if (cfg.urlPatternRes[i].test(url)) {
        return true;
      }
    }
  } catch (e) {
    // 源 :67-71 catch {} ——正则执行异常吞掉，继续走后续层
  }
  const ctIdx: number = indexOfHeaderUpper(responseHeaders, 'CONTENT-TYPE');
  if (ctIdx >= 0) {
    const ctVal: string = firstValueOf(responseHeaders, ctIdx);
    for (let m = 0; m < cfg.mediaTypes.length; m++) {
      if (ctVal.indexOf(cfg.mediaTypes[m]) >= 0) {
        return true;
      }
    }
  }
  for (let i = 0; i < cfg.fileExts.length; i++) {
    if (upath.endsWith('.' + cfg.fileExts[i])) {
      return true;
    }
  }
  const cdIdx: number = indexOfHeaderUpper(responseHeaders, 'CONTENT-DISPOSITION');
  if (cdIdx >= 0) {
    const cdVal: string = firstValueOf(responseHeaders, cdIdx).toUpperCase();
    for (let i = 0; i < cfg.fileExts.length; i++) {
      if (cdVal.indexOf('.' + cfg.fileExts[i]) >= 0) {
        return true;
      }
    }
  }
  for (let i = 0; i < cfg.matchingHosts.length; i++) {
    if (host.indexOf(cfg.matchingHosts[i]) >= 0) {
      return true;
    }
  }
  return false;
}

/**
 * onSendHeadersEvent 门镜像（request-watcher.js:92-98）：method==='GET' → 恒过；非 GET 需
 * matchingHosts 存在某 h 使 url.indexOf(h) **严格大于 0**（匹配在下标 0 不算——源怪癖 1:1，
 * A15；非 GET 请求仅过门才入扩展端 requestMap）。
 */
export function passesSendGate(method: string, url: string, matchingHosts: string[]): boolean {
  if (method === 'GET') {
    return true;
  }
  for (let i = 0; i < matchingHosts.length; i++) {
    if (url.indexOf(matchingHosts[i]) > 0) {
      return true;
    }
  }
  return false;
}

// ────────────── U6.2 增量：分派链谓词五件+itag 区间（VideoUrlHelper.cs:697-761） ──────────────

/** IsYtFormat（:750-761）：IsNullOrEmpty → false；否则 toLowerCase() 含 'application/json'。 */
export function isYtFormat(contentType: string | null): boolean {
  if (contentType === null || contentType.length === 0) {
    return false;
  }
  return contentType.toLowerCase().indexOf('application/json') >= 0;
}

/** IsHLS（:716-726）：contentType **原始大小写** contains 'mpegurl'/'.m3u8'/'m3u8'（序数敏感——
 * 'MPEGURL' 不命中；第三个键 'm3u8' 被 '.m3u8' 包含但仍 1:1 保留三键序）。 */
export function isHLS(contentType: string): boolean {
  return contentType.indexOf('mpegurl') >= 0 || contentType.indexOf('.m3u8') >= 0 ||
    contentType.indexOf('m3u8') >= 0;
}

/** IsHLSUrl（:728-731）：url?.toLowerCase() 含 '.m3u8'；null → false（源 ?? false）。 */
export function isHLSUrl(url: string | null): boolean {
  if (url === null) {
    return false;
  }
  return url.toLowerCase().indexOf('.m3u8') >= 0;
}

/** IsDASH（:733-743）：contentType 原始大小写 contains 'dash'（序数敏感）。 */
export function isDASH(contentType: string): boolean {
  return contentType.indexOf('dash') >= 0;
}

/** IsDASHUrl（:745-748）：url?.toLowerCase() 含 '.mpd'；null → false。 */
export function isDASHUrl(url: string | null): boolean {
  if (url === null) {
    return false;
  }
  return url.toLowerCase().indexOf('.mpd') >= 0;
}

/** IsNormalVideo(itag)（:697-700）：(4<n<79)||(81<n<86)||(99<n<103)——常规画质 itag 走
 * ProcessNormalVideo 的短路口（十二点边界：4 否/5 是/78 是/79 否/81 否/82 是/85 是/86 否/
 * 99 否/100 是/102 是/103 否，用例 B9）。 */
export function isNormalVideoItag(itag: number): boolean {
  return (itag > 4 && itag < 79) || (itag > 81 && itag < 86) || (itag > 99 && itag < 103);
}

// ────────────── U6.2 增量：SHA1 纯 TS + referer 键（:897-902，§3.4） ──────────────

/** 32 位无符号化（% 2^32，结果恒非负）。 */
function u32(x: number): number {
  return x % 0x100000000;
}

/** 循环左移（>>> 保证无符号）。 */
function rotl32(x: number, n: number): number {
  return ((x << n) | (x >>> (32 - n))) >>> 0;
}

/** 单字 8 位小写 hex。 */
function toHex8(v: number): string {
  let s: string = v.toString(16);
  while (s.length < 8) {
    s = '0' + s;
  }
  return s;
}

/**
 * SHA-1（FIPS 180-4，:897-902 ComputeHash 镜像）：UTF-8 输入、40 位小写 hex。
 * 纯 TS 实现保零 @kit 纪律与 Node 自验（node:crypto 交叉验证：sha1('abc')=
 * 'a9993e36470698a983e259040d7036b31f7d5f7'，sha1('')='da39a3ee5e6b4b0d3255bfef95601890afd80709'，
 * 差异登记 §4-10——不用 cryptoFramework）。消费方：referersToSkip 键（AddToSkippedRefererList
 * :888-895 / IsMediaFragment :873-886，编排接线在 BridgeRoutes）。
 */
export function sha1Hex(input: string): string {
  // UTF-8 编码（与 BridgeProtocol.utf8Encode 同算法；本文件独立成函数避免跨模块耦合测试面）
  const bytes: number[] = [];
  let i: number = 0;
  while (i < input.length) {
    const c: number = input.charCodeAt(i);
    if (c < 0x80) {
      bytes.push(c);
      i++;
    } else if (c < 0x800) {
      bytes.push(0xC0 | (c >> 6));
      bytes.push(0x80 | (c & 0x3F));
      i++;
    } else if (c >= 0xD800 && c <= 0xDBFF && i + 1 < input.length &&
      input.charCodeAt(i + 1) >= 0xDC00 && input.charCodeAt(i + 1) <= 0xDFFF) {
      const cp: number = 0x10000 + ((c - 0xD800) * 0x400) + (input.charCodeAt(i + 1) - 0xDC00);
      bytes.push(0xF0 | (cp >> 18));
      bytes.push(0x80 | ((cp >> 12) & 0x3F));
      bytes.push(0x80 | ((cp >> 6) & 0x3F));
      bytes.push(0x80 | (cp & 0x3F));
      i += 2;
    } else {
      bytes.push(0xE0 | (c >> 12));
      bytes.push(0x80 | ((c >> 6) & 0x3F));
      bytes.push(0x80 | (c & 0x3F));
      i++;
    }
  }
  // 填充：0x80 + 0 填至 ≡56 (mod 64) + 64 位大端位长
  const bitLen: number = bytes.length * 8;
  bytes.push(0x80);
  while (bytes.length % 64 !== 56) {
    bytes.push(0);
  }
  const hi: number = Math.floor(bitLen / 0x100000000);
  const lo: number = bitLen % 0x100000000;
  bytes.push((hi >>> 24) & 0xFF);
  bytes.push((hi >>> 16) & 0xFF);
  bytes.push((hi >>> 8) & 0xFF);
  bytes.push(hi & 0xFF);
  bytes.push((lo >>> 24) & 0xFF);
  bytes.push((lo >>> 16) & 0xFF);
  bytes.push((lo >>> 8) & 0xFF);
  bytes.push(lo & 0xFF);
  // 压缩
  let h0: number = 0x67452301;
  let h1: number = 0xEFCDAB89;
  let h2: number = 0x98BADCFE;
  let h3: number = 0x10325476;
  let h4: number = 0xC3D2E1F0;
  const w: number[] = new Array(80);
  for (let off: number = 0; off < bytes.length; off += 64) {
    for (let t = 0; t < 16; t++) {
      const j: number = off + t * 4;
      w[t] = u32(bytes[j] * 0x1000000 + bytes[j + 1] * 0x10000 + bytes[j + 2] * 0x100 + bytes[j + 3]);
    }
    for (let t = 16; t < 80; t++) {
      w[t] = rotl32(w[t - 3] ^ w[t - 8] ^ w[t - 14] ^ w[t - 16], 1);
    }
    let a: number = h0;
    let b: number = h1;
    let c: number = h2;
    let d: number = h3;
    let e: number = h4;
    for (let t = 0; t < 80; t++) {
      let f: number = 0;
      let k: number = 0;
      if (t < 20) {
        f = u32((b & c) | (~b & d));
        k = 0x5A827999;
      } else if (t < 40) {
        f = u32(b ^ c ^ d);
        k = 0x6ED9EBA1;
      } else if (t < 60) {
        f = u32((b & c) | (b & d) | (c & d));
        k = 0x8F1BBCDC;
      } else {
        f = u32(b ^ c ^ d);
        k = 0xCA62C1D6;
      }
      const temp: number = u32(rotl32(a, 5) + f + e + k + w[t]);
      e = d;
      d = c;
      c = rotl32(b, 30);
      b = a;
      a = temp;
    }
    h0 = u32(h0 + a);
    h1 = u32(h1 + b);
    h2 = u32(h2 + c);
    h3 = u32(h3 + d);
    h4 = u32(h4 + e);
  }
  return toHex8(h0) + toHex8(h1) + toHex8(h2) + toHex8(h3) + toHex8(h4);
}

// ────────────── U6.2 增量：YT-DASH 段配对（:409-613，设计书 §3.5） ──────────────

/** DashInfo（:969-979 逐字段；Headers/Cookies 自 message 注入）。 */
export class DashInfo {
  url: string;
  length: number;
  isVideo: boolean;
  itag: number;
  id: string;
  mime: string;
  headers: BridgeHeaders | null;
  cookies: string | null;

  constructor(url: string, length: number, isVideo: boolean, itag: number, id: string,
    mime: string, headers: BridgeHeaders | null, cookies: string | null) {
    this.url = url;
    this.length = length;
    this.isVideo = isVideo;
    this.itag = itag;
    this.id = id;
    this.mime = mime;
    this.headers = headers;
    this.cookies = cookies;
  }
}

/** HandleDashAudio 的登记数据（源 SingleSourceHTTPDownloadInfo+StreamingVideoDisplayInfo 拍平；
 * **唯一设 contentType 的 U6.2 写入路径**=info.mime，F3 对照面，设计书 §2.4）。 */
export interface SegSingle {
  file: string;
  size: number;
  contentType: string;
  displayText: string;
  uri: string;
  headers: BridgeHeaders | null;
  cookies: string | null;
  tabId: string;
  tabUrl: string;
}

/** CreateDualSourceHTTPDownloadInfo 的登记数据（源 DualSourceHTTPDownloadInfo+
 * StreamingVideoDisplayInfo 拍平；ContentLength 与 Size 同值投影为 size）。 */
export interface SegDual {
  file: string;
  size: number;
  displayText: string;
  uri1: string;
  uri2: string;
  headers1: BridgeHeaders | null;
  headers2: BridgeHeaders | null;
  cookies1: string | null;
  cookies2: string | null;
  tabId: string;
  tabUrl: string;
}

/** 段配对登记回调（设计书 §3.5 写入接线：本模块不 import tracker，BridgeRoutes 组装回调）。 */
export interface SegSink {
  onSingle: (seg: SegSingle) => void;
  onDual: (seg: SegDual) => void;
}

/** Int32/Int64.Parse 严格十进制门（垃圾/空/超界 → throw → 外层 catch → return false 落普通
 * 视频门；安全整数上界 Number.MAX_SAFE_INTEGER，设计书 §4-6——.NET Int64 全域不复刻，现实
 * 视频段 clen 不触发）。 */
const INT64_DECIMAL_GATE: RegExp = new RegExp('^[+-]?[0-9]+$');

function parseInt64Gate(val: string): number {
  if (!INT64_DECIMAL_GATE.test(val)) {
    throw new Error('not a decimal integer: ' + val);
  }
  const n: number = Number(val);
  if (!Number.isFinite(n) || Math.abs(n) > Number.MAX_SAFE_INTEGER) {
    throw new Error('beyond safe integer range: ' + val);
  }
  return n;
}

/** Uri.UnescapeDataString 近似（设计书 §4-7 尾注）：decodeURIComponent try/catch——非法序列
 * 保留原样（.NET Core 保留原样语义近似；真实 YT mime 参数恒合法）。 */
export function unescapeDataString(val: string): string {
  try {
    return decodeURIComponent(val);
  } catch (e) {
    return val;
  }
}

/** ParsingHelper.cs:13-21 ParseKeyValuePair 镜像：两端 Trim → 首个分隔符且下标≥1 → [key,value]
 * 两段 Trim；无分隔符/下标<1 → ['','']（**返回哨兵对**而非 null——源 KeyValuePair 结构语义）。 */
export function parseKeyValuePairOf(line: string, delimiter: string): string[] {
  const trimmed: string = line.trim();
  const index: number = trimmed.indexOf(delimiter);
  if (index < 1) {
    return ['', ''];
  }
  return [trimmed.slice(0, index).trim(), trimmed.slice(index + 1).trim()];
}

/** AddIfNew（:702-714）：自**队尾**向队首按 (Length,ID) 双等值去重——命中返回 false 不入队；
 * 否则 push 返回 true。 */
function addIfNew(info: DashInfo, queue: DashInfo[]): boolean {
  for (let i = queue.length - 1; i >= 0; i--) {
    if (queue[i].length === info.length && queue[i].id === info.id) {
      return false;
    }
  }
  queue.push(info);
  return true;
}

/** AddToQueue（:763-784）：**入队前**两队列各自 length>32 → shift()（稳态上限 33，§4-5——
 * 源 Count>32 → RemoveAt(0) 1:1，非"上限 32"）；再按 isVideo 分队 addIfNew。 */
export function addToQueue(state: SniffState, info: DashInfo): boolean {
  if (state.videoQueue.length > 32) {
    state.videoQueue.shift();
  }
  if (state.audioQueue.length > 32) {
    state.audioQueue.shift();
  }
  if (info.isVideo) {
    return addIfNew(info, state.videoQueue);
  }
  return addIfNew(info, state.audioQueue);
}

/** GetDASHPair（:786-823）：视频段自 audioQueue **队尾**找 id 等值（无守卫）；音频段自 videoQueue
 * 队尾找 id 等值，命中时 **lastVid!==null && lastVid.length===di.length → null**（同一段视频不被
 * 连续两条音频重复配对），否则 lastVid=di 返回 di（D15~D17 队尾扫描+守卫序钉死）。 */
export function getDashPair(state: SniffState, info: DashInfo): DashInfo | null {
  if (info.isVideo) {
    if (state.audioQueue.length < 1) {
      return null;
    }
    for (let i = state.audioQueue.length - 1; i >= 0; i--) {
      if (state.audioQueue[i].id === info.id) {
        return state.audioQueue[i];
      }
    }
    return null;
  }
  if (state.videoQueue.length < 1) {
    return null;
  }
  for (let i = state.videoQueue.length - 1; i >= 0; i--) {
    const di: DashInfo = state.videoQueue[i];
    if (di.id === info.id) {
      if (state.lastVid !== null && state.lastVid.length === di.length) {
        return null;
      }
      state.lastVid = di;
      return di;
    }
  }
  return null;
}

/** HandleDashAudio（:547-587，先配对前登记；源自身 try/catch 吞异常——本函数产 SegSingle 数据
 * 经 SegSink 上报）：ext=getExtensionOf(fileNameFromUrl(info.url))；为空 → mime 含 webm→'.webm'/
 * mp4→'.mp4'/否则 **'mkv' 缺前导点**（§0-3 怪癖 1:1 保留：文件名 '名字mkv' 无点分隔、
 * '[KV AUDIO]'（ext.substring(1) 吞掉 K）——对等原版零成本不修，D13 钉死）。 */
export function handleDashAudio(info: DashInfo, msg: BridgeMessage): SegSingle {
  const size: number = info.length;
  const name: string = fileNameFromUrl(info.url);
  let ext: string = getExtensionOf(name);
  if (ext.length === 0) {
    ext = info.mime.indexOf('webm') >= 0 ? '.webm' :
      (info.mime.indexOf('mp4') >= 0 ? '.mp4' : 'mkv');
  }
  const quality: string = ext.length > 1 ? ext.substring(1).toUpperCase() : '';
  const displayText: string = '[' + quality + ' AUDIO] ' + (size > 0 ? formatSize(size) : '');
  const seg: SegSingle = {
    file: sanitizeOrEmpty(msg.file !== null ? msg.file : fileNameFromUrl(
      msg.url !== null ? msg.url : '')) + ext,
    size: size,
    contentType: info.mime,
    displayText: displayText,
    uri: info.url,
    headers: info.headers,
    cookies: info.cookies,
    tabId: msg.tabId ?? '',
    tabUrl: msg.tabUrl ?? ''
  };
  return seg;
}

/** CreateDualSourceHTTPDownloadInfo（:589-613）：pair/fresh 按 isVideo 分侧；file=sanitize
 * (msg.file ?? fileNameFromUrl(msg.url))+'.mkv'；contentLength=video+audio 两段和。 */
export function createDualInfo(pair: DashInfo, fresh: DashInfo, msg: BridgeMessage): SegDual {
  let video: DashInfo = pair;
  let audio: DashInfo = fresh;
  if (!pair.isVideo) {
    video = fresh;
    audio = pair;
  }
  const seg: SegDual = {
    file: sanitizeOrEmpty(msg.file !== null ? msg.file : fileNameFromUrl(
      msg.url !== null ? msg.url : '')) + '.mkv',
    size: video.length + audio.length,
    displayText: '',
    uri1: video.url,
    uri2: audio.url,
    headers1: video.headers,
    headers2: audio.headers,
    cookies1: video.cookies,
    cookies2: audio.cookies,
    tabId: msg.tabId ?? '',
    tabUrl: msg.tabUrl ?? ''
  };
  return seg;
}

/**
 * ProcessYtDashSegment 全量（:409-545 逐行；**整段异常吞掉返回 false**=源 :543 catch{}——
 * 含 Int32/Int64.Parse 抛、Uri 构造抛，落普通视频门）：
 * ① host 门：url null（源 new Uri(null) 抛→catch）或 hostOfUrl 不含 '.youtube.'/'.googlevideo.'
 *    （裸域无前导点串不过门）→ false；
 * ② contentType 门：'Content-Type' 首值小写，null 或不含 audio//video//application/octet → false；
 * ③ url 门：url 小写同时含 'videoplayback' 与 'itag' → 否则 false；
 * ④ 参数重组（:430-484）：query 逐项，key 空或以 'range' 开头 → 剔除不追加（**末位被剔除时前一
 *    参数留尾随 '&'**，D6）；itag/clen 精确等值键严格十进制门；mime 以 'mime' 开头 → unescape；
 *    **str 原始参数串以 'id' 开头 → id=val（'identity=x' 命中怪癖）**；
 * ⑤ 短路：itag!==0 && isNormalVideoItag(itag) → false（itag=0——大写 ITAG 键不被精确等值解析——
 *    不短路，D10）；
 * ⑥ DashInfo 构造（isVideo=mime.startsWith('video') 序数敏感）→ addToQueue；
 * ⑦ 入队成功：!isVideo && mime.startsWith('audio/') → handleDashAudio 上报 onSingle；
 *    getDashPair null → return true（消费但无配对）；否则 createDualInfo+quality=
 *    itagQuality(**恒视频侧 itag**)+displayText → onDual；
 * ⑧ return true（**即使去重失败或配对失败**——消息已被消费，源 :541）。
 */
export function processYtDashSegment(state: SniffState, msg: BridgeMessage, out: SegSink): boolean {
  try {
    const rawUrl: string | null = msg.url;
    if (rawUrl === null) {
      return false;
    }
    const host: string = hostOfUrl(rawUrl);
    if (host.indexOf('.youtube.') < 0 && host.indexOf('.googlevideo.') < 0) {
      return false;
    }
    const contentType: string | null = headerValueFirst(msg.responseHeaders, 'Content-Type');
    if (contentType === null) {
      return false;
    }
    const ctLower: string = contentType.toLowerCase();
    if (!(ctLower.indexOf('audio/') >= 0 || ctLower.indexOf('video/') >= 0 ||
      ctLower.indexOf('application/octet') >= 0)) {
      return false;
    }
    const lowUrl: string = rawUrl.toLowerCase();
    if (!(lowUrl.indexOf('videoplayback') >= 0 && lowUrl.indexOf('itag') >= 0)) {
      return false;
    }
    const kv: string[] = parseKeyValuePairOf(rawUrl, '?');
    const path: string = kv[0];
    const query: string = kv[1];
    const arr: string[] = query.split('&');
    let ytUrl: string = path + '?';
    let itag: number = 0;
    let clen: number = 0;
    let id: string = '';
    let mime: string = '';
    for (let i = 0; i < arr.length; i++) {
      const str: string = arr[i];
      const kv1: string[] = parseKeyValuePairOf(str, '=');
      const key: string = kv1[0];
      const val: string = kv1[1];
      if (key.length === 0) {
        continue;
      }
      if (key.indexOf('range') === 0) {
        continue;
      }
      if (key === 'itag') {
        itag = parseInt64Gate(val);
      }
      if (key === 'clen') {
        clen = parseInt64Gate(val);
      }
      if (key.indexOf('mime') === 0) {
        mime = unescapeDataString(val);
      }
      if (str.indexOf('id') === 0) {
        id = val;
      }
      ytUrl += str;
      if (i < arr.length - 1) {
        ytUrl += '&';
      }
    }
    if (itag !== 0 && isNormalVideoItag(itag)) {
      return false;
    }
    const info: DashInfo = new DashInfo(ytUrl, clen, mime.indexOf('video') === 0, itag, id, mime,
      msg.requestHeaders, msg.cookies);
    if (addToQueue(state, info)) {
      if (!info.isVideo && mime.indexOf('audio/') === 0) {
        out.onSingle(handleDashAudio(info, msg));
      }
      const di: DashInfo | null = getDashPair(state, info);
      if (di === null) {
        return true;
      }
      const dual: SegDual = createDualInfo(di, info, msg);
      const size: number = di.length + info.length;
      const quality: string = itagQuality(info.isVideo ? info.itag : di.itag);
      dual.displayText = '[' + quality + '] ' + (size > 0 ? formatSize(size) : '');
      out.onDual(dual);
    }
    return true;
  } catch (e) {
    // 源 :543 catch {} ——整段异常吞掉（Int32/Int64.Parse 抛/Uri 构造抛），落普通视频门
    return false;
  }
}

// ────────────── U6.2 增量：Itags 表 60 项（:904-966 逐行清点，§2.8） ──────────────

/** Itags 键表（60 项，VideoUrlHelper.cs:906-965 逐项；平行数组——ArkTS Record 键必须 string，
 * 禁 Record<number,string>）。 */
export const ITAG_KEYS: number[] = [5, 133, 6, 134, 135, 136, 264, 137, 266, 139, 140, 13, 141,
  271, 272, 17, 18, 22, 278, 160, 34, 35, 36, 37, 38, 167, 168, 169, 170, 298, 43, 171, 299, 44,
  172, 45, 46, 302, 303, 308, 313, 59, 315, 78, 82, 83, 84, 85, 218, 219, 100, 101, 102, 242, 243,
  244, 245, 246, 247, 248];

/** Itags 值表（与 ITAG_KEYS 平行；'Hi  bitrate' 双空格逐字保真 :918/:940；3D 档 '360p 3D' 等）。 */
export const ITAG_VALUES: string[] = ['240p', '240p', '270p', '360p', '480p', '720p', '1440p',
  '1080p', '2160p', 'Low bitrate', 'Med bitrate', 'Small', 'Hi  bitrate', '1440p', '2160p',
  '144p', '360p', '720p', '144p', '144p', '360p', '480p', '240p', '1080p', '1080p', '360p',
  '480p', '720p', '1080p', '720p', '360p', 'Med bitrate', '2160p', '480p', 'Hi  bitrate',
  '720p', '1080p', '720p', '1080p', '1440p', '2160p', '480p', '2160p', '480p', '360p 3D',
  '480p 3D', '720p 3D', '1080p 3D', '480p', '480p', '360p 3D', '480p 3D', '720p 3D', '240p',
  '360p', '480p', '480p', '480p', '720p', '1080p'];

/** Itags.GetValueOrDefault(itag, "MKV")（:528）：线性查找（60 项量级无性能面）；查不到默认
 * 'MKV'（D21）。 */
export function itagQuality(itag: number): string {
  for (let i = 0; i < ITAG_KEYS.length; i++) {
    if (ITAG_KEYS[i] === itag) {
      return ITAG_VALUES[i];
    }
  }
  return 'MKV';
}

// ────────────── U7.1 增量：DASH 捕获条目映射（VideoUrlHelper.cs:183-331，设计书 §4.9） ──────────────

/** 双轨降级条目（DualSourceHTTPDownloadInfo :217-226 拍平；size 源不设 → 登记 0）。 */
export interface DashDualCapture {
  form: string; // 'dual'
  file: string;
  displayText: string;
  uri1: string;
  uri2: string;
  headers1: BridgeHeaders | null;
  headers2: BridgeHeaders | null;
  cookies1: string | null;
  cookies2: string | null;
}

/** 多轨条目（MultiSourceDASHDownloadInfo :238-249 拍平：全量段/duration=max/url=manifestUrl/双 mime）。 */
export interface DashMultiCapture {
  form: string; // 'multi'
  file: string;
  displayText: string;
  manifestUrl: string;
  videoSegments: string[];
  audioSegments: string[];
  duration: number;
  videoMime: string;
  audioMime: string;
  headers: BridgeHeaders | null;
  cookies: string | null;
}

/** 单轨条目（SingleSourceHTTPDownloadInfo + AddSingleItem :278-296 拍平；★只取 Segments[0]
 * ——多段单轨产物不完整的源 quirk 1:1 保留，§5-5 openQuestion 2，验收流选双轨清单规避）。 */
export interface DashSingleCapture {
  form: string; // 'single'
  file: string;
  displayText: string;
  uri: string;
  headers: BridgeHeaders | null;
  cookies: string | null;
  audioOnly: boolean;
}

/** processDashVideo 输出条目联合（BridgeRoutes 按 form 判别后 as 窄化写 tracker 三写入方）。 */
export type DashCaptureItem = DashDualCapture | DashMultiCapture | DashSingleCapture;

/**
 * GetQualityString（:298-331 逐字符对齐，双空格/尾随空格 quirk 逐用例钉死）：
 * 双轨 = 高度段 + 带宽段 + ' ' + 语言段（lang='und'/'' → 空段，双空格由此保留）；
 * video-only = 高度段 + 带宽段（无中间空格/无语言段）；audio-only = 语言段 + 带宽段（★序与双轨不同）；
 * 带宽 = 各侧 bandwidth>0 求和后整除 1024（C# long 整除 → 正数截断）。
 */
export function dashQuality(video: DashRepresentation | null, audio: DashRepresentation | null): string {
  const resolution: string = video !== null && video.height > 0 ? String(video.height) + 'p ' : '';
  let sum: number = 0;
  if (video !== null && video.bandwidth > 0) { sum += video.bandwidth; }
  if (audio !== null && audio.bandwidth > 0) { sum += audio.bandwidth; }
  const bandwidth: string = sum > 0 ? String(Math.trunc(sum / 1024)) + ' Kbps ' : '';
  const language: string = audio !== null && audio.language.length > 0 && audio.language !== 'und' ?
    audio.language + ' ' : '';
  if (video !== null && audio !== null) {
    return resolution + bandwidth + ' ' + language;
  }
  if (video !== null) {
    return resolution + bandwidth;
  }
  if (audio !== null) {
    return language + bandwidth;
  }
  return '';
}

/** AddSingleItem（:278-296）条目映射半区：ext=(MimeType+'').Contains('mp4')?'mp4':'mkv'
 * （video/mp2t→mkv 源 quirk 1:1）；quality 按 audioOnly 分侧；★uri=Segments[0]（:283）。 */
function dashSingleOf(item: DashRepresentation, audioOnly: boolean, prefix: string, file: string,
  headers: BridgeHeaders | null, cookies: string | null): DashSingleCapture {
  const fileExt: string = item.mimeType.indexOf('mp4') >= 0 ? 'mp4' : 'mkv';
  const quality: string = audioOnly ? dashQuality(null, item) : dashQuality(item, null);
  const capture: DashSingleCapture = {
    form: 'single',
    file: prefix + sanitizeOrEmpty(file) + '.' + fileExt,
    displayText: '[' + fileExt.toUpperCase() + '] ' + quality,
    uri: item.segments[0],
    headers: headers,
    cookies: cookies,
    audioOnly: audioOnly
  };
  return capture;
}

/**
 * ProcessDashVideo（:202-273）条目映射半区（纯函数；网络半区=BridgeRoutes.processDashCapture、
 * 登记半区=tracker 三写入方）：
 * 逐周期（periodIdx=count 自 0）：prefix = count===0 ? '' : count+' '（:209 多周期前缀）；
 * 逐 pair：ext（双轨）= video.mime 含 'mp4' && audio.mime 含 'mp4' ? 'mp4' : 'mkv'（:216/:237 子串包含）；
 * 双轨 v/a 段数均 1 → dual 条目（:213-234 uri1/uri2=两首段）；否则 multi 条目（:235-257 全量段、
 * duration=max(v.dur,a.dur)、url=manifestUrl、双 mime）；仅 video/仅 audio → single 条目
 * （★源 AddSingleItem 只下 Segments[0]，多段产物不完整 §5-5）；双侧皆空跳过（:269-272）。
 * displayText = '[' + ext 大写 + '] ' + dashQuality(...)（:227/:250/:289）。
 */
export function processDashVideo(periods: DashPair[][], file: string, manifestUrl: string,
  headers: BridgeHeaders | null, cookies: string | null): DashCaptureItem[] {
  const items: DashCaptureItem[] = [];
  for (let count = 0; count < periods.length; count++) {
    const prefix: string = count === 0 ? '' : String(count) + ' ';
    const pairs: DashPair[] = periods[count];
    for (let p = 0; p < pairs.length; p++) {
      const video: DashRepresentation | null = pairs[p].video;
      const audio: DashRepresentation | null = pairs[p].audio;
      if (video !== null && audio !== null) {
        const fileExt: string = video.mimeType.indexOf('mp4') >= 0 && audio.mimeType.indexOf('mp4') >= 0 ?
          'mp4' : 'mkv';
        if (video.segments.length === 1 && audio.segments.length === 1) {
          const item: DashDualCapture = {
            form: 'dual',
            file: prefix + sanitizeOrEmpty(file) + '.' + fileExt,
            displayText: '[' + fileExt.toUpperCase() + '] ' + dashQuality(video, audio),
            uri1: video.segments[0],
            uri2: audio.segments[0],
            headers1: headers,
            headers2: headers,
            cookies1: cookies,
            cookies2: cookies
          };
          items.push(item);
        } else {
          const item: DashMultiCapture = {
            form: 'multi',
            file: prefix + sanitizeOrEmpty(file) + '.' + fileExt,
            displayText: '[' + fileExt.toUpperCase() + '] ' + dashQuality(video, audio),
            manifestUrl: manifestUrl,
            videoSegments: video.segments.slice(),
            audioSegments: audio.segments.slice(),
            duration: Math.max(video.duration, audio.duration),
            videoMime: video.mimeType,
            audioMime: audio.mimeType,
            headers: headers,
            cookies: cookies
          };
          items.push(item);
        }
      } else if (video !== null) {
        items.push(dashSingleOf(video, false, prefix, file, headers, cookies));
      } else if (audio !== null) {
        items.push(dashSingleOf(audio, true, prefix, file, headers, cookies));
      }
    }
  }
  return items;
}
