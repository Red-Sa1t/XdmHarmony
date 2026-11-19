/*
 * U7.1 纯 DASH 元数据与预算常量（设计书 u7-1-dash-DESIGN.md §3.1/§3.3）。
 * 零 @kit 导入——Hypium 本地单测与探针可直接加载。
 * DashRepresentation 逐字段镜像源 MediaParser/Dash/Representation.cs:6-28 八只读属性：
 *   List<Uri> Segments → segments: string[]（源解析期已 Resolve；Uri.ToString→string，含 init/首段，绝对 URL）；
 *   int Width/Height → number（缺省 -1：Int32.Parse(width ?? "-1")，MpdParser.cs:174/199/243/298）；
 *   string Codec → string（属性缺省 C# null → ArkTS 统一 ''，映射层判空，无观测差异）；
 *   long Bandwidth → number（缺省 -1；$Bandwidth$ 替换仍用原始属性串 :156/:344，原始串不进本模型）；
 *   long Duration → number（=periodDuration 毫秒，三寻址共用）；
 *   string MimeType → string（小写化后 audio/video 前缀门 :153/:160）；
 *   string Language → string（同 Codec 缺省处理）。
 * DashPair{video,audio} ↔ KeyValuePair<Representation?,Representation?>（MpdParser.cs:109-125）。
 * DashPeriodAttrs：多周期时长反算（MpdParser.cs:361-397）的输入形态——duration/start 属性串，
 *   缺省 null（C# Attributes[".."]?.Value 的 null 语义）。
 * 预算常量组（§3.3）：源无界且依赖 .NET 异常路径 → 目标全套有界，超限 throw=整清单丢弃
 *   （与源异常丢弃同效，设计书 §5-4）。
 * ArkTS 红线：无 any/解构/for...in/正则字面量；throw 只抛 Error；显式返回类型。
 */

/** trickmode guideline URI（MpdParser.cs:17 trickModeUri 逐字；ContainsTrickMode :399-420 精确等值比较） */
export const DASH_TRICK_MODE_URI: string = 'http://dashif.org/guidelines/trickmode';

/** 清单字符预算（=HLS_MAX_MANIFEST_CHARS；ManifestClient.ets:12 字节预算 8Mi 的 UTF-16 面一致） */
export const DASH_MAX_MANIFEST_CHARS: number = 2097152;
/** XML 树节点数界（研究结论边界清单；HlsParser 行数界同量级） */
export const DASH_MAX_NODES: number = 20000;
/** XML 树深度界 */
export const DASH_MAX_DEPTH: number = 64;
/** 每节点属性数界（=HLS_MAX_ATTRIBUTES） */
export const DASH_MAX_ATTRS_PER_NODE: number = 256;
/** 单段文本字符界（=HLS_MAX_LINE_CHARS） */
export const DASH_MAX_TEXT_CHARS: number = 32768;
/** Period 数界 */
export const DASH_MAX_PERIODS: number = 256;
/** 每周期 AdaptationSet 数界 */
export const DASH_MAX_ADAPTATION_SETS: number = 256;
/** 每周期 Representation 总数界（=HLS_MAX_VARIANTS 量级） */
export const DASH_MAX_REPRESENTATIONS: number = 2048;
/** 每轨段数界（=HLS_MAX_SEGMENTS；simple 寻址 segmentCount 与 Timeline 累计 push 共用） */
export const DASH_MAX_SEGMENTS: number = 10000;
/** 每周期 video×audio 组合界（笛卡尔积防炸；超出部分条目丢弃，设计书 §3.3——非 throw） */
export const DASH_MAX_PAIRS: number = 2048;
/** 周期内累计展开 URL 字符界（=HLS_MAX_OUTPUT_CHARS） */
export const DASH_MAX_OUTPUT_URL_CHARS: number = 8388608;

/** Representation.cs 八属性的 ArkTS 镜像（构造参数序与 C# ctor :17-19 一致）。 */
export class DashRepresentation {
  segments: string[];
  width: number;
  height: number;
  codec: string;
  bandwidth: number;
  duration: number;
  mimeType: string;
  language: string;

  constructor(segments: string[], width: number, height: number, codec: string,
    bandwidth: number, duration: number, mimeType: string, language: string) {
    this.segments = segments;
    this.width = width;
    this.height = height;
    this.codec = codec;
    this.bandwidth = bandwidth;
    this.duration = duration;
    this.mimeType = mimeType;
    this.language = language;
  }
}

/** KeyValuePair<Representation?,Representation?> 的 ArkTS 镜像（MpdParser.cs:109-125 笛卡尔序载体）。 */
export class DashPair {
  video: DashRepresentation | null;
  audio: DashRepresentation | null;

  constructor(video: DashRepresentation | null, audio: DashRepresentation | null) {
    this.video = video;
    this.audio = audio;
  }
}

/** 多周期输入形态（MpdParser.cs:374-375 sduration/sstart 两属性串；缺省 null=C# null）。 */
export interface DashPeriodAttrs {
  duration: string | null;
  start: string | null;
}
