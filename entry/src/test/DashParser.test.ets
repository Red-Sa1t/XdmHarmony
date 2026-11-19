/* U7.1 MpdParser 逐公式 Hypium 用例（设计书 u7-1-dash-DESIGN.md §6 DashParser 行 + §4 逐公式表）。
 * 事件注入式：直接构造 DashXmlEvent[]（零 @kit——xml 适配层不入本地用例，结构面由真机探针
 * P7-U1-F 覆盖）；恒等 resolver + 绝对引用规避 URL 语义面。
 * 计 34 断言组：根门 6（含 type 大小写敏感 quirk）/周期 4（含 duration-only 中间周期源误差钉死）/
 * 三寻址 7/simple 6/timeline 7（t="0" 不重置、r=0 与 r=-1 均 1 段、init $Time$=0）/
 * 格式化 2（%06d/%0Nx/无 dx 按 d 偏差 §5-1）/组合与 trickmode 2。
 * 源锚：MpdParser.cs（行号随用例标注）；★=源 quirk 钉死。
 * ArkTS 红线：无 any/解构/for...in/正则字面量；Record 字面量键加引号；显式返回类型。
 */

import { describe, it, expect } from '@ohos/hypium';
import { DashPair, DashPeriodAttrs } from '../main/ets/core/adaptive/DashModel';
import { DASH_EVENT_END, DASH_EVENT_START, DashUrlResolver, DashXmlEvent,
  buildMpdTree, parseDashManifestFromEvents, parseDashTemplate, parsePeriodDurations } from '../main/ets/core/adaptive/DashParser';

const MPD_URL: string = 'https://d.test/v.mpd';
const NO_ATTRS: Record<string, string> = {};
const RESOLVER: DashUrlResolver = (_base: string, reference: string): string => reference;

function eStart(name: string, attrs: Record<string, string>): DashXmlEvent {
  const event: DashXmlEvent = new DashXmlEvent();
  event.kind = DASH_EVENT_START;
  event.name = name;
  event.attrs = attrs;
  return event;
}

function eEnd(name: string): DashXmlEvent {
  const event: DashXmlEvent = new DashXmlEvent();
  event.kind = DASH_EVENT_END;
  event.name = name;
  return event;
}

function oneAttr(key: string, value: string): Record<string, string> {
  const attrs: Record<string, string> = {};
  attrs[key] = value;
  return attrs;
}

function attrsOf(keys: string[], values: string[]): Record<string, string> {
  const attrs: Record<string, string> = {};
  for (let i = 0; i < keys.length; i++) { attrs[keys[i]] = values[i]; }
  return attrs;
}

function asEvents(asAttrs: Record<string, string>, body: DashXmlEvent[]): DashXmlEvent[] {
  const out: DashXmlEvent[] = [eStart('AdaptationSet', asAttrs)];
  for (let i = 0; i < body.length; i++) { out.push(body[i]); }
  out.push(eEnd('AdaptationSet'));
  return out;
}

function reprEvents(reprAttrs: Record<string, string>, inner: DashXmlEvent[]): DashXmlEvent[] {
  const out: DashXmlEvent[] = [eStart('Representation', reprAttrs)];
  for (let i = 0; i < inner.length; i++) { out.push(inner[i]); }
  out.push(eEnd('Representation'));
  return out;
}

function segmentBaseRepr(id: string, bandwidth: string, mime: string): DashXmlEvent[] {
  return asEvents(oneAttr('mimeType', mime), reprEvents(attrsOf(['id', 'bandwidth'], [id, bandwidth]),
    [eStart('SegmentBase', NO_ATTRS), eEnd('SegmentBase')]));
}

function dualBody(): DashXmlEvent[] {
  const body: DashXmlEvent[] = segmentBaseRepr('v1', '100', 'video/mp4');
  const audio: DashXmlEvent[] = segmentBaseRepr('a1', '50', 'audio/mp4');
  for (let i = 0; i < audio.length; i++) { body.push(audio[i]); }
  return body;
}

function parsePeriods(periodAttrs: Record<string, string>[], bodies: DashXmlEvent[][],
  rootAttrs: Record<string, string>): DashPair[][] {
  const events: DashXmlEvent[] = [eStart('MPD', rootAttrs)];
  for (let p = 0; p < periodAttrs.length; p++) {
    events.push(eStart('Period', periodAttrs[p]));
    for (let i = 0; i < bodies[p].length; i++) { events.push(bodies[p][i]); }
    events.push(eEnd('Period'));
  }
  events.push(eEnd('MPD'));
  return parseDashManifestFromEvents(events, MPD_URL, RESOLVER);
}

function parse(body: DashXmlEvent[], rootAttrs: Record<string, string> = NO_ATTRS): DashPair[][] {
  return parsePeriods([NO_ATTRS], [body], rootAttrs);
}

function countPairs(periods: DashPair[][]): number {
  let total: number = 0;
  for (let i = 0; i < periods.length; i++) { total += periods[i].length; }
  return total;
}

function expectThrows(call: () => void): void {
  let thrown: boolean = false;
  try {
    call();
  } catch (e) {
    thrown = true;
  }
  expect(thrown).assertTrue();
}

function firstVideoOf(periods: DashPair[][]): DashPair {
  return periods[0][0];
}

function templateRepr(media: string, templateAttrs: Record<string, string>,
  reprAttrs: Record<string, string>): DashXmlEvent[] {
  return asEvents(oneAttr('mimeType', 'video/mp4'), [
    eStart('SegmentTemplate', withMedia(templateAttrs, media)),
    eEnd('SegmentTemplate'),
    ...reprEvents(reprAttrs, [])
  ]);
}

function withMedia(attrs: Record<string, string>, media: string): Record<string, string> {
  attrs['media'] = media;
  return attrs;
}

function timelineTemplate(templateAttrs: Record<string, string>, sElements: DashXmlEvent[]): DashXmlEvent[] {
  const inner: DashXmlEvent[] = [eStart('SegmentTemplate', templateAttrs),
    eStart('SegmentTimeline', NO_ATTRS)];
  for (let i = 0; i < sElements.length; i++) { inner.push(sElements[i]); }
  inner.push(eEnd('SegmentTimeline'));
  inner.push(eEnd('SegmentTemplate'));
  return asEvents(oneAttr('mimeType', 'video/mp4'),
    [...inner, ...reprEvents(attrsOf(['id', 'bandwidth'], ['v1', '100']), [])]);
}

function sElement(attrs: Record<string, string>): DashXmlEvent {
  return eStart('S', attrs);
}

export default function dashParserTest(): void {
  describe('dashParserTest', (): void => {
    // ────────────── 根门 6（MpdParser.cs:32-51） ──────────────
    it('root_gate_non_mpd_throws', 0, (): void => {
      const events: DashXmlEvent[] = [eStart('foo', NO_ATTRS), eEnd('foo')];
      expectThrows((): void => { parseDashManifestFromEvents(events, MPD_URL, RESOLVER); });
    });
    it('root_gate_dynamic_rejected', 0, (): void => {
      expectThrows((): void => { parse(dualBody(), oneAttr('type', 'dynamic')); });
    });
    it('root_gate_dynamic_case_sensitive_quirk', 0, (): void => {
      // ★"Dynamic" 不拒（:34 精确等值），用例钉死
      const periods: DashPair[][] = parse(dualBody(), oneAttr('type', 'Dynamic'));
      expect(countPairs(periods)).assertEqual(1);
    });
    it('root_gate_content_protection_any_depth', 0, (): void => {
      const body: DashXmlEvent[] = [
        eStart('AdaptationSet', oneAttr('mimeType', 'video/mp4')),
        eStart('ContentProtection', oneAttr('schemeIdUri', 'urn:x')),
        eEnd('ContentProtection'),
        ...reprEvents(attrsOf(['id', 'bandwidth'], ['v1', '100']), []),
        eEnd('AdaptationSet')
      ];
      expectThrows((): void => { parse(body); });
    });
    it('root_gate_no_period_throws', 0, (): void => {
      // MPD 下无 Period 子节点（parse([]) 是空 Period 体，不触发 :51 门）
      const events: DashXmlEvent[] = [eStart('MPD', NO_ATTRS),
        eStart('ProgramInformation', NO_ATTRS), eEnd('ProgramInformation'), eEnd('MPD')];
      expectThrows((): void => { parseDashManifestFromEvents(events, MPD_URL, RESOLVER); });
    });
    it('root_gate_empty_document_throws', 0, (): void => {
      expectThrows((): void => { buildMpdTree([]); });
    });

    // ────────────── 周期 4（:41-64/:69-128/:361-397） ──────────────
    it('period_single_uses_media_presentation_duration', 0, (): void => {
      const periods: DashPair[][] = parse(dualBody(), oneAttr('mediaPresentationDuration', 'PT10S'));
      expect(firstVideoOf(periods).video?.duration).assertEqual(10000);
    });
    it('period_dual_start_reverse_order', 0, (): void => {
      // 逆文档序逆算后 Reverse 正序（:363-396）
      const periods: DashPair[][] = parsePeriods(
        [oneAttr('start', 'PT0S'), oneAttr('start', 'PT30S')],
        [dualBody(), dualBody()], oneAttr('mediaPresentationDuration', 'PT60S'));
      expect(periods[0][0].video?.duration).assertEqual(30000);
      expect(periods[1][0].video?.duration).assertEqual(30000);
    });
    it('period_duration_only_middle_source_error_quirk', 0, (): void => {
      // ★duration-only 中间周期混合形态：last=total-dur 源误差 1:1（:380-386）
      const periods: DashPair[][] = parsePeriods(
        [oneAttr('duration', 'PT10S'), oneAttr('start', 'PT20S'), oneAttr('duration', 'PT30S')],
        [dualBody(), dualBody(), dualBody()], oneAttr('mediaPresentationDuration', 'PT100S'));
      expect(periods[0][0].video?.duration).assertEqual(10000);
      expect(periods[1][0].video?.duration).assertEqual(50000);
      expect(periods[2][0].video?.duration).assertEqual(30000);
    });
    it('period_both_missing_throws', 0, (): void => {
      // 双缺 throw（:376-379）；单周期路径不进反算，须多周期触发
      expectThrows((): void => { parsePeriods([NO_ATTRS, NO_ATTRS], [dualBody(), dualBody()],
        oneAttr('mediaPresentationDuration', 'PT60S')); });
    });

    // ────────────── 三寻址 7（:151-306 判定顺序固定） ──────────────
    it('addressing_segmentbase_single_segment', 0, (): void => {
      const periods: DashPair[][] = parse(dualBody());
      expect(firstVideoOf(periods).video?.segments.length).assertEqual(1);
      expect(firstVideoOf(periods).video?.segments[0]).assertEqual(MPD_URL);
    });
    it('addressing_period_level_flag_applies', 0, (): void => {
      // :83 Period 级 child::SegmentBase 布尔标志下传（repr 无自有 SegmentBase）
      const body: DashXmlEvent[] = [eStart('SegmentBase', NO_ATTRS), eEnd('SegmentBase'),
        ...segmentBaseRepr('v1', '100', 'video/mp4')];
      const periods: DashPair[][] = parse(body);
      expect(firstVideoOf(periods).video?.segments.length).assertEqual(1);
    });
    it('addressing_as_level_segmentbase_ignored_quirk', 0, (): void => {
      // ★AdaptationSet 级 SegmentBase 不被检查（:83 只查 Period 级）→ 落 template 分支
      const body: DashXmlEvent[] = [
        eStart('SegmentBase', NO_ATTRS), eEnd('SegmentBase'),
        eStart('SegmentTemplate', attrsOf(['media', 'timescale', 'duration'],
          ['s$Number$.ts', '1', '5'])),
        eEnd('SegmentTemplate'),
        ...reprEvents(attrsOf(['id', 'bandwidth'], ['v1', '100']), [])
      ];
      const events: DashXmlEvent[] = [eStart('MPD', oneAttr('mediaPresentationDuration', 'PT10S')),
        eStart('Period', NO_ATTRS)];
      const wrapped: DashXmlEvent[] = asEvents(oneAttr('mimeType', 'video/mp4'), body);
      for (let i = 0; i < wrapped.length; i++) { events.push(wrapped[i]); }
      events.push(eEnd('Period'));
      events.push(eEnd('MPD'));
      const periods: DashPair[][] = parseDashManifestFromEvents(events, MPD_URL, RESOLVER);
      // simple 寻址 10s/5s → 2 段（若 AS 级 SegmentBase 被误用则只有 1 段）
      expect(firstVideoOf(periods).video?.segments.length).assertEqual(2);
    });
    it('addressing_list_init_wins_over_representation_index', 0, (): void => {
      // :184-185 Initialization ?? RepresentationIndex 取首优先
      const inner: DashXmlEvent[] = [eStart('SegmentList', NO_ATTRS),
        eStart('Initialization', oneAttr('sourceURL', 'i1.init')), eEnd('Initialization'),
        eStart('RepresentationIndex', oneAttr('sourceURL', 'r1.idx')), eEnd('RepresentationIndex'),
        eStart('SegmentURL', oneAttr('media', 's1.ts')), eEnd('SegmentURL'),
        eStart('SegmentURL', oneAttr('media', 's2.ts')), eEnd('SegmentURL'),
        eEnd('SegmentList')];
      const periods: DashPair[][] = parse(asEvents(oneAttr('mimeType', 'video/mp4'),
        reprEvents(attrsOf(['id', 'bandwidth'], ['v1', '100']), inner)));
      const video = firstVideoOf(periods).video;
      expect(video?.segments.length).assertEqual(3);
      expect(video?.segments[0]).assertEqual('i1.init');
      expect(video?.segments[1]).assertEqual('s1.ts');
    });
    it('addressing_list_zero_segments_null', 0, (): void => {
      // :199 总段数 0 → repr=null（无 init 无 SegmentURL）
      const inner: DashXmlEvent[] = [eStart('SegmentList', NO_ATTRS), eEnd('SegmentList')];
      const periods: DashPair[][] = parse(asEvents(oneAttr('mimeType', 'video/mp4'),
        reprEvents(attrsOf(['id', 'bandwidth'], ['v1', '100']), inner)));
      expect(countPairs(periods)).assertEqual(0);
    });
    it('addressing_list_media_range_ignored', 0, (): void => {
      // :194 仅读 media；mediaRange/indexRange 不消费
      const inner: DashXmlEvent[] = [eStart('SegmentList', NO_ATTRS),
        eStart('SegmentURL', attrsOf(['media', 'mediaRange'], ['s1.ts', '100-200'])),
        eEnd('SegmentURL'), eEnd('SegmentList')];
      const periods: DashPair[][] = parse(asEvents(oneAttr('mimeType', 'video/mp4'),
        reprEvents(attrsOf(['id', 'bandwidth'], ['v1', '100']), inner)));
      expect(firstVideoOf(periods).video?.segments[0]).assertEqual('s1.ts');
    });
    it('addressing_template_parent_fallback_period_not_queried', 0, (): void => {
      // ③ repr ?? 父 AS（:206-207）；Period 级 SegmentTemplate 不查（repr → null）
      const asLevel: DashXmlEvent[] = asEvents(oneAttr('mimeType', 'video/mp4'), [
        eStart('SegmentTemplate', attrsOf(['media', 'timescale', 'duration'],
          ['s$Number$.ts', '1', '1'])),
        eEnd('SegmentTemplate'),
        ...reprEvents(attrsOf(['id', 'bandwidth'], ['v1', '100']), [])
      ]);
      expect(countPairs(parse(asLevel, oneAttr('mediaPresentationDuration', 'PT2S')))).assertEqual(1);
      const periodLevel: DashXmlEvent[] = [
        eStart('SegmentTemplate', attrsOf(['media', 'timescale', 'duration'],
          ['s$Number$.ts', '1', '1'])),
        eEnd('SegmentTemplate'),
        ...asEvents(oneAttr('mimeType', 'video/mp4'),
          reprEvents(attrsOf(['id', 'bandwidth'], ['v1', '100']), []))
      ];
      expect(countPairs(parse(periodLevel))).assertEqual(0);
    });

    // ────────────── simple 6（:212-245） ──────────────
    it('simple_default_triple_values', 0, (): void => {
      // timescale/duration/startNumber 缺省 1/1/1（:214-216）；segmentCount=ceil(pd/1000/1)
      const wrapped: DashXmlEvent[] = templateRepr('s$Number$.ts',
        attrsOf(['timescale', 'duration'], ['1', '1']),
        attrsOf(['id', 'bandwidth'], ['v1', '100']));
      const events: DashXmlEvent[] = [eStart('MPD', oneAttr('mediaPresentationDuration', 'PT10S')),
        eStart('Period', NO_ATTRS)];
      for (let i = 0; i < wrapped.length; i++) { events.push(wrapped[i]); }
      events.push(eEnd('Period'));
      events.push(eEnd('MPD'));
      const periods: DashPair[][] = parseDashManifestFromEvents(events, MPD_URL, RESOLVER);
      const video = firstVideoOf(periods).video;
      expect(video?.segments.length).assertEqual(10);
      expect(video?.segments[0]).assertEqual('s1.ts');
      expect(video?.segments[9]).assertEqual('s10.ts');
    });
    it('simple_time_starts_at_start_number_quirk', 0, (): void => {
      // ★:220 time=startNumber（非 0）——$Time$ 首值=startNumber
      const body: DashXmlEvent[] = asEvents(oneAttr('mimeType', 'video/mp4'), [
        eStart('SegmentTemplate', attrsOf(['media', 'timescale', 'duration', 'startNumber'],
          ['n$Number$-t$Time$.ts', '1', '1', '3'])),
        eEnd('SegmentTemplate'),
        ...reprEvents(attrsOf(['id', 'bandwidth'], ['v1', '100']), [])
      ]);
      const periods: DashPair[][] = parse(body, oneAttr('mediaPresentationDuration', 'PT2S'));
      expect(firstVideoOf(periods).video?.segments[0]).assertEqual('n3-t3.ts');
    });
    it('simple_ceil_math_sintel_888', 0, (): void => {
      // ceil(888000/1000 / (120/24)) = ceil(177.6) = 178（DashSanityTest.cs:77 Sintel video）
      const body: DashXmlEvent[] = templateRepr('v$Number$.m4s',
        attrsOf(['timescale', 'duration'], ['24', '120']),
        attrsOf(['id', 'bandwidth'], ['v1', '100']));
      const periods: DashPair[][] = parse(body, oneAttr('mediaPresentationDuration', 'PT14M48S'));
      expect(firstVideoOf(periods).video?.segments.length).assertEqual(178);
    });
    it('simple_dollar_dollar_literal_quirk', 0, (): void => {
      // ★$$→\u0000→恢复 $（:222-223/:231/:238）
      const body: DashXmlEvent[] = templateRepr('sintel_au$$dio_$Number$.m4s',
        attrsOf(['timescale', 'duration'], ['1', '1']),
        attrsOf(['id', 'bandwidth'], ['v1', '100']));
      const periods: DashPair[][] = parse(body, oneAttr('mediaPresentationDuration', 'PT1S'));
      expect(firstVideoOf(periods).video?.segments[0]).assertEqual('sintel_au$dio_1.m4s');
    });
    it('simple_bandwidth_raw_string_quirk', 0, (): void => {
      // ★$Bandwidth$ 用原始属性串（:156 旁路/:344）——前导零保留
      const body: DashXmlEvent[] = templateRepr('q$Bandwidth$-$Number$.m4s',
        attrsOf(['timescale', 'duration'], ['1', '1']),
        attrsOf(['id', 'bandwidth'], ['v1', '0123456']));
      const periods: DashPair[][] = parse(body, oneAttr('mediaPresentationDuration', 'PT1S'));
      expect(firstVideoOf(periods).video?.segments[0]).assertEqual('q0123456-1.m4s');
    });
    it('simple_representation_id_substitution', 0, (): void => {
      const body: DashXmlEvent[] = templateRepr('$RepresentationID$-$Number$.m4s',
        attrsOf(['timescale', 'duration'], ['1', '1']),
        attrsOf(['id', 'bandwidth'], ['vid1', '100']));
      const periods: DashPair[][] = parse(body, oneAttr('mediaPresentationDuration', 'PT1S'));
      expect(firstVideoOf(periods).video?.segments[0]).assertEqual('vid1-1.m4s');
    });

    // ────────────── timeline 7（:247-301） ──────────────
    it('timeline_missing_d_throws', 0, (): void => {
      // :273 Attributes["d"].Value 缺失 → NRE → 清单丢弃
      const body: DashXmlEvent[] = timelineTemplate(
        attrsOf(['media'], ['m$Number$.ts']),
        [sElement(NO_ATTRS), eEnd('S')]);
      expectThrows((): void => { parse(body); });
    });
    it('timeline_t_zero_does_not_reset_quirk', 0, (): void => {
      // ★:276 t>0 严格不等号——t="0" 不重置（第二段时间=500+100 而非 0）
      const body: DashXmlEvent[] = timelineTemplate(
        attrsOf(['media'], ['s$Time$.ts']),
        [sElement(attrsOf(['t', 'd'], ['500', '100'])), eEnd('S'),
        sElement(attrsOf(['t', 'd'], ['0', '100'])), eEnd('S')]);
      const periods: DashPair[][] = parse(body);
      const video = firstVideoOf(periods).video;
      expect(video?.segments.length).assertEqual(2);
      expect(video?.segments[0]).assertEqual('s500.ts');
      expect(video?.segments[1]).assertEqual('s600.ts');
    });
    it('timeline_r_positive_expands', 0, (): void => {
      // :285-295 r>0 重复 r 次（r=2 → 3 段）
      const body: DashXmlEvent[] = timelineTemplate(
        attrsOf(['media'], ['s$Time$.ts']),
        [sElement(attrsOf(['t', 'r', 'd'], ['0', '2', '10'])), eEnd('S')]);
      const periods: DashPair[][] = parse(body);
      const video = firstVideoOf(periods).video;
      expect(video?.segments.length).assertEqual(3);
      expect(video?.segments[2]).assertEqual('s20.ts');
    });
    it('timeline_r_zero_single_segment_quirk', 0, (): void => {
      // ★r=0 只发 1 段（源未实现规范"重复至周期末"语义 1:1）
      const body: DashXmlEvent[] = timelineTemplate(
        attrsOf(['media'], ['s$Time$.ts']),
        [sElement(attrsOf(['t', 'r', 'd'], ['0', '0', '10'])), eEnd('S')]);
      const periods: DashPair[][] = parse(body);
      expect(firstVideoOf(periods).video?.segments.length).assertEqual(1);
    });
    it('timeline_r_negative_single_segment_quirk', 0, (): void => {
      // ★r=-1 只发 1 段（哨兵缺省值路径）
      const body: DashXmlEvent[] = timelineTemplate(
        attrsOf(['media'], ['s$Time$.ts']),
        [sElement(attrsOf(['t', 'r', 'd'], ['0', '-1', '10'])), eEnd('S')]);
      const periods: DashPair[][] = parse(body);
      expect(firstVideoOf(periods).video?.segments.length).assertEqual(1);
    });
    it('timeline_start_number_carried', 0, (): void => {
      // :254 number=startNumber ?? 1
      const body: DashXmlEvent[] = timelineTemplate(
        attrsOf(['media', 'startNumber'], ['m$Number$.ts', '7']),
        [sElement(attrsOf(['d'], ['10'])), eEnd('S')]);
      const periods: DashPair[][] = parse(body);
      expect(firstVideoOf(periods).video?.segments[0]).assertEqual('m7.ts');
    });
    it('timeline_init_time_zero_quirk', 0, (): void => {
      // ★:255 time=0 先于 init 展开（:263-268）——init 段 $Time$=0
      const body: DashXmlEvent[] = timelineTemplate(
        attrsOf(['media', 'initialization'], ['m$Number$.ts', 'i$Time$.mp4']),
        [sElement(attrsOf(['d'], ['10'])), eEnd('S')]);
      const periods: DashPair[][] = parse(body);
      const video = firstVideoOf(periods).video;
      expect(video?.segments[0]).assertEqual('i0.mp4');
      expect(video?.segments[1]).assertEqual('m1.ts');
    });

    // ────────────── 格式化 2（:308-359 parseDashTemplate 直测） ──────────────
    it('template_percent06d_pads_and_recovers_dollar', 0, (): void => {
      expect(parseDashTemplate('p$Number%06d$.m4s', 1, 0, '100', 'v')).assertEqual('p000001.m4s');
      // $$ 转义恢复
      expect(parseDashTemplate('a$$b$Number$.ts', 5, 0, '1', 'v')).assertEqual('a$b5.ts');
    });
    it('template_percent0Nx_hex_and_nodx_as_decimal_deviation', 0, (): void => {
      // %0Nx 小写 hex 补零（12→000c）；★无 dx 形态按 d 十进制补零（§5-1 偏差——不复刻
      // .NET ToString("4") 字面量输出缺陷）
      // 注：$Number%0Nx$（N 为规范元变量字面量，非数字）在源 .NET 正则同样不匹配不替换——
      // 补零形态须落具体宽度，如 %04x
      expect(parseDashTemplate('$Number%04x$.m4s', 12, 0, '1', 'v')).assertEqual('000c.m4s');
      expect(parseDashTemplate('$Number%04$.m4s', 12, 0, '1', 'v')).assertEqual('0012.m4s');
      // $Bandwidth$ 原始串 + $RepresentationID$
      expect(parseDashTemplate('$RepresentationID$-$Bandwidth$', 1, 0, '077', 'rep'))
        .assertEqual('rep-077');
    });

    // ────────────── 组合与 trickmode 2（:103-126/:138-141/:399-420） ──────────────
    it('cartesian_video_outer_audio_inner_order', 0, (): void => {
      // 双 video AS + 双 audio AS（每 AS 一 repr，贴近源组分类）→ 4 对，序=video 外层 × audio 内层
      const periods: DashPair[][] = parsePeriods([NO_ATTRS], [[
        ...asEvents(oneAttr('mimeType', 'video/mp4'),
          reprEvents(attrsOf(['id', 'bandwidth'], ['v1', '100']),
            [eStart('SegmentBase', NO_ATTRS), eEnd('SegmentBase')])),
        ...asEvents(oneAttr('mimeType', 'video/mp4'),
          reprEvents(attrsOf(['id', 'bandwidth'], ['v2', '200']),
            [eStart('SegmentBase', NO_ATTRS), eEnd('SegmentBase')])),
        ...asEvents(oneAttr('mimeType', 'audio/mp4'),
          reprEvents(attrsOf(['id', 'bandwidth'], ['a1', '10']),
            [eStart('SegmentBase', NO_ATTRS), eEnd('SegmentBase')])),
        ...asEvents(oneAttr('mimeType', 'audio/mp4'),
          reprEvents(attrsOf(['id', 'bandwidth'], ['a2', '20']),
            [eStart('SegmentBase', NO_ATTRS), eEnd('SegmentBase')]))
      ]], NO_ATTRS);
      expect(countPairs(periods)).assertEqual(4);
      expect(periods[0][0].video?.bandwidth).assertEqual(100);
      expect(periods[0][0].audio?.bandwidth).assertEqual(10);
      expect(periods[0][1].video?.bandwidth).assertEqual(100);
      expect(periods[0][1].audio?.bandwidth).assertEqual(20);
      expect(periods[0][2].video?.bandwidth).assertEqual(200);
      expect(periods[0][3].video?.bandwidth).assertEqual(200);
    });
    it('trickmode_group_dropped', 0, (): void => {
      // :138-141/:399-420 EssentialProperty schemeIdUri 精确等值 → 整组返回空
      const body: DashXmlEvent[] = [
        ...asEvents(oneAttr('mimeType', 'video/mp4'), [
          eStart('EssentialProperty', oneAttr('schemeIdUri', 'http://dashif.org/guidelines/trickmode')),
          eEnd('EssentialProperty'),
          ...reprEvents(attrsOf(['id', 'bandwidth'], ['v1', '100']), [])
        ]),
        ...asEvents(oneAttr('mimeType', 'audio/mp4'),
          reprEvents(attrsOf(['id', 'bandwidth'], ['a1', '50']),
            [eStart('SegmentBase', NO_ATTRS), eEnd('SegmentBase')]))
      ];
      const periods: DashPair[][] = parse(body);
      expect(countPairs(periods)).assertEqual(1);
      expect(periods[0][0].video === null).assertTrue();
      expect(periods[0][0].audio?.bandwidth).assertEqual(50);
    });

    // ────────────── parsePeriodDurations 直测（逆算口径补钉） ──────────────
    it('period_durations_reverse_direct', 0, (): void => {
      const attrs: DashPeriodAttrs[] = [
        { duration: null, start: 'PT0S' },
        { duration: null, start: 'PT30S' }
      ];
      const list: number[] = parsePeriodDurations(attrs, 60000);
      expect(list.length).assertEqual(2);
      expect(list[0]).assertEqual(30000);
      expect(list[1]).assertEqual(30000);
    });
    it('period_durations_both_missing_direct_throws', 0, (): void => {
      const attrs: DashPeriodAttrs[] = [{ duration: null, start: null }];
      expectThrows((): void => { parsePeriodDurations(attrs, 60000); });
    });
  });
}
