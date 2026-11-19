// P7-U1-F observes DASH pure-function formulas and the real xml.parseXml event surface.
// Vector MPDs are inline fixtures from XDM_Tests/DashSanityTest.cs; EXPECT values are
// formula-derived and pinned after a device run (attr callback order is an observed fact).
import { xml, util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { ProbeKit, KeyValue } from '../core/ProbeKit';
import { ProbePage, ProbeStepDef } from '../core/ProbePage';
import { DashPair } from '../../core/adaptive/DashModel';
import { parseXsDuration } from '../../core/adaptive/DashUtil';
import { buildMpdTree, DASH_EVENT_START, DashXmlNode, DashXmlEvent,
  parseDashManifestFromEvents } from '../../core/adaptive/DashParser';
import { decodeMpdEvents } from '../../core/adaptive/DashXmlFeed';
import { resolveHlsUrl } from '../../core/adaptive/HlsUrlResolver';

const FOUNDATION_STEPS: ProbeStepDef[] = [
  { stepNo: 'S1', title: 'XML 结构与树（事件序实测）', autoRun: true },
  { stepNo: 'S2', title: 'parseXsDuration 时长表', autoRun: true },
  { stepNo: 'S3', title: 'Smooth Timeline 展开', autoRun: true },
  { stepNo: 'S4', title: 'Sintel simple+模板', autoRun: true },
  { stepNo: 'S5', title: '三寻址+多周期', autoRun: true },
  { stepNo: 'S6', title: '拒绝门+BBC 向量', autoRun: true }
];

/** DashSanityTest.cs TestCase 1 原文（5598 字符） */
const SMOOTH_MPD: string = `<?xml version="1.0" encoding="utf-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" profiles="urn:mpeg:dash:profile:isoff-live:2011" type="static" mediaPresentationDuration="PT2M59.281S" minBufferTime="PT3S"><Period><AdaptationSet id="1" group="1" profiles="ccff" bitstreamSwitching="false" segmentAlignment="true" contentType="video" mimeType="video/mp4" codecs="avc1.640028" maxWidth="1920" maxHeight="1080" startWithSAP="1"><SegmentTemplate timescale="10000000" media="QualityLevels($Bandwidth$)/Fragments(video=$Time$,format=mpd-time-csf)" initialization="QualityLevels($Bandwidth$)/Fragments(video=i,format=mpd-time-csf)"><SegmentTimeline><S d="20020000" r="88"/><S d="10343666"/></SegmentTimeline></SegmentTemplate><Representation id="1_V_video_1" bandwidth="5977913" width="1920" height="1080"/><Representation id="1_V_video_2" bandwidth="4681440" width="1920" height="1080"/><Representation id="1_V_video_3" bandwidth="3385171" codecs="avc1.64001F" width="1280" height="720"/><Representation id="1_V_video_4" bandwidth="2238364" codecs="avc1.64001F" width="960" height="540"/><Representation id="1_V_video_5" bandwidth="1490441" codecs="avc1.64001F" width="960" height="540"/><Representation id="1_V_video_6" bandwidth="991868" codecs="avc1.64001E" width="640" height="360"/><Representation id="1_V_video_7" bandwidth="642832" codecs="avc1.64001E" width="640" height="360"/><Representation id="1_V_video_8" bandwidth="393546" codecs="avc1.64000D" width="320" height="180"/></AdaptationSet><AdaptationSet id="2" group="5" profiles="ccff" bitstreamSwitching="false" segmentAlignment="true" contentType="audio" mimeType="audio/mp4" codecs="mp4a.40.2"><Label>AAC_und_ch2_128kbps</Label><SegmentTemplate timescale="10000000" media="QualityLevels($Bandwidth$)/Fragments(AAC_und_ch2_128kbps=$Time$,format=mpd-time-csf)" initialization="QualityLevels($Bandwidth$)/Fragments(AAC_und_ch2_128kbps=i,format=mpd-time-csf)"><SegmentTimeline><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361" r="1"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361" r="1"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361" r="1"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361" r="1"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361" r="1"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361" r="1"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361" r="1"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="15092971"/></SegmentTimeline></SegmentTemplate><Representation id="5_A_AAC_und_ch2_128kbps_1" bandwidth="125615" audioSamplingRate="44100"/></AdaptationSet><AdaptationSet id="3" group="5" profiles="ccff" bitstreamSwitching="false" segmentAlignment="true" contentType="audio" mimeType="audio/mp4" codecs="mp4a.40.2"><Label>AAC_und_ch2_56kbps</Label><SegmentTemplate timescale="10000000" media="QualityLevels($Bandwidth$)/Fragments(AAC_und_ch2_56kbps=$Time$,format=mpd-time-csf)" initialization="QualityLevels($Bandwidth$)/Fragments(AAC_und_ch2_56kbps=i,format=mpd-time-csf)"><SegmentTimeline><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361" r="1"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361" r="1"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361" r="1"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361" r="1"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361" r="1"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361" r="1"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361" r="1"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="20201361"/><S d="20201360"/><S d="15092971"/></SegmentTimeline></SegmentTemplate><Representation id="5_A_AAC_und_ch2_56kbps_1" bandwidth="53620" audioSamplingRate="44100"/></AdaptationSet></Period></MPD>
`;

/** DashSanityTest.cs TestCase 2 原文（2077 字符） */
const BBC_MPD: string = `<?xml version="1.0" encoding="UTF-8"?>
<MPD type="static" xmlns="urn:mpeg:dash:schema:mpd:2011" profiles="urn:mpeg:dash:profile:isoff-live:2011" minBufferTime="PT0.451S" mediaPresentationDuration="PT9M32.520S">
<!-- MPEG DASH ISO BMFF test stream with avc3 -->
<!-- BBC Research & Development -->
<!-- For more information see http://rdmedia.bbc.co.uk -->
<ProgramInformation>
	<Title>Adaptive Bitrate Test Stream from BBC Research and Development - Full stream with separate initialisation segments</Title>
	<Source>BBC Research and Development</Source>
</ProgramInformation>
<Period duration="PT9M32.520S" start="PT0S">
	<AdaptationSet startWithSAP="2" segmentAlignment="true" id="1" sar="1:1" frameRate="25" scanType="progressive" mimeType="video/mp4" >
		<BaseURL>avc3/</BaseURL>
		<SegmentTemplate timescale="1000" duration="3840" media="$RepresentationID$/$Number%06d$.m4s" initialization="$RepresentationID$/IS.mp4" />
		<Representation id="1920x1080p25" codecs="avc3.640028" height="1080" width="1920" bandwidth="4741120" />
		<Representation id="896x504p25" codecs="avc3.64001f" height="504" width="896" bandwidth="1416688" />
		<Representation id="704x396p25" codecs="avc3.4d401e" height="396" width="704" bandwidth="843768" />
		<Representation id="512x288p25" codecs="avc3.4d4015" height="288" width="512" bandwidth="449480" />
		<Representation id="1280x720p25" codecs="avc3.640020" height="720" width="1280" bandwidth="2656696" />
	</AdaptationSet>
	<AdaptationSet startWithSAP="2" segmentAlignment="true" id="3" codecs="mp4a.40.2" audioSamplingRate="48000" lang="eng" mimeType="audio/mp4" >
		<AudioChannelConfiguration schemeIdUri="urn:mpeg:dash:23003:3:audio_channel_configuration:2011" value="2"/>
		<BaseURL>audio/</BaseURL>
		<SegmentTemplate timescale="1000" duration="3840" media="$RepresentationID$/$Number%06d$.m4s" initialization="$RepresentationID$/IS.mp4" />
		<Representation id="160kbps" bandwidth="160000" />
		<Representation id="96kbps" bandwidth="96000" />
		<Representation id="128kbps" bandwidth="128000" />
	</AdaptationSet>
</Period>
</MPD>`;

/** DashSanityTest.cs TestCase 3 原文（1743 字符） */
const SINTEL_MPD: string = `<?xml version="1.0" encoding="utf-8"?>
<MPD xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns="urn:mpeg:dash:schema:mpd:2011" xsi:schemaLocation="urn:mpeg:DASH:schema:MPD:2011 DASH-MPD.xsd" profiles="urn:mpeg:dash:profile:isoff-on-demand:2011" minBufferTime="PT15S" type="static" mediaPresentationDuration="PT14M48S">
  <Period start="PT0S">
    <AdaptationSet codecs="mp4a.40.42" contentType="audio" mimeType="audio/mp4" lang="en" segmentAlignment="true" bitstreamSwitching="true" audioSamplingRate="48000">
      <AudioChannelConfiguration schemeIdUri="urn:mpeg:mpegB:cicp:ChannelConfiguration" value="2"/>
      <SegmentTemplate timescale="48000" duration="245760" initialization="sintel_audio_video_brs-$RepresentationID$_init.mp4" media="sintel_au$dio_video_brs-$RepresentationID$_$Number$.m4s" startNumber="0"/>
      <Representation id="eng-2-xheaac-16kbps" bandwidth="17188"/>
      <Representation id="eng-2-xheaac-32kbps" bandwidth="33538"/>
      <Representation id="eng-2-xheaac-64kbps" bandwidth="66115"/>
      <Representation id="eng-2-xheaac-128kbps" bandwidth="129717"/>
    </AdaptationSet>
    <AdaptationSet codecs="avc1.42c01e" contentType="video" frameRate="24/1" width="848" height="386" mimeType="video/mp4" par="21:9" segmentAlignment="true" bitstreamSwitching="true">
      <SegmentTemplate timescale="24" duration="120" initialization="sintel_audio_video_brs-$RepresentationID$_init.mp4" media="sintel_audio_video_brs-$RepresentationID$_$Number$.m4s" startNumber="0"/>
      <Representation id="848x386-1500kbps" bandwidth="1422029" sar="1:1"/>
    </AdaptationSet>
  </Period>
</MPD>
<!--	https://dash.akamaized.net/dash264/TestCasesMCA/fraunhofer/xHE-AAC_Stereo/2/Sintel/sintel_audio_video_brs.mpd  -->
`;

/** DashSanityTest.cs TestCase 4 原文（4524 字符） */
const MULTIPERIOD_MPD: string = `<?xml version="1.0"  encoding="utf-8"?>
<MPD >
    <Period duration="PT30S">
        <BaseURL>ad/</BaseURL>
        <!-- Everything in one Adaptation Set -->
        <AdaptationSet mimeType="video/mp2t">
            <!-- 720p Representation at 3.2 Mbps -->
            <Representation id="720p" bandwidth="3200000" width="1280" height="720">
                <!-- Just use one segment, since the ad is only 30 seconds long -->
                <BaseURL>720p.ts</BaseURL>
                <SegmentBase>
                    <RepresentationIndex sourceURL="720p.sidx"/>
                </SegmentBase>
            </Representation>
            <!-- 1080p Representation at 6.8 Mbps -->
            <Representation id="1080p" bandwidth="6800000" width="1920"
                            height="1080">
                <BaseURL>1080p.ts</BaseURL>
                <SegmentBase>
                    <RepresentationIndex sourceURL="1080p.sidx"/>
                </SegmentBase>
            </Representation>
        </AdaptationSet>
    </Period>
    <!-- Normal Content -->
    <Period duration="PT10M">
        <BaseURL>main/</BaseURL>
        <!-- Just the video -->
        <AdaptationSet mimeType="video/mp2t">
            <BaseURL>video/</BaseURL>
            <!-- 720p Representation at 3.2 Mbps -->
            <Representation id="720p" bandwidth="3200000" width="1280" height="720">
                <BaseURL>720p/</BaseURL>
                <!-- First, we'll just list all of the segments -->
                <!-- Timescale is "ticks per second", so each segment is 1 minute
                     long -->
                <SegmentList timescale="90000" duration="5400000">
                    <RepresentationIndex sourceURL="representation-index.sidx"/>
                    <SegmentURL media="segment-1.ts"/>
                    <SegmentURL media="segment-2.ts"/>
                    <SegmentURL media="segment-3.ts"/>
                    <SegmentURL media="segment-4.ts"/>
                    <SegmentURL media="segment-5.ts"/>
                    <SegmentURL media="segment-6.ts"/>
                    <SegmentURL media="segment-7.ts"/>
                    <SegmentURL media="segment-8.ts"/>
                    <SegmentURL media="segment-9.ts"/>
                    <SegmentURL media="segment-10.ts"/>
                </SegmentList>
            </Representation>
            <!-- 1080p Representation at 6.8 Mbps -->
            <Representation id="1080p" bandwidth="6800000" width="1920"
                            height="1080">
                <BaseURL>1080/</BaseURL>
                <!-- Since all of our segments have similar names, this time
                     we'll use a SegmentTemplate -->
                <SegmentTemplate media="segment-$Number$.ts" timescale="90000">
                    <RepresentationIndex sourceURL="representation-index.sidx"/>
                    <!-- Let's add a SegmentTimeline so the client can easily see
                         how many segments there are -->
                    <SegmentTimeline>
                        <!-- r is the number of repeats _after_ the first one, so
                             this reads:
                             Starting from time 0, there are 10 (9 + 1) segments
                             with a duration of (5400000 / @timescale) seconds. -->
                        <S t="0" r="9" d="5400000"/>
                    </SegmentTimeline>
                </SegmentTemplate>
            </Representation>
        </AdaptationSet>
        <!-- Just the audio -->
        <AdaptationSet mimeType="audio/mp2t">
            <BaseURL>audio/</BaseURL>
            <!-- We're just going to offer one audio representation, since audio
                 bandwidth isn't very important. -->
            <Representation id="audio" bandwidth="128000">
                <SegmentTemplate media="segment-$Number$.ts" timescale="90000">
                    <RepresentationIndex sourceURL="representation-index.sidx"/>
                    <SegmentTimeline>
                        <S t="0" r="9" d="5400000"/>
                    </SegmentTimeline>
                </SegmentTemplate>
            </Representation>
            <Representation id="audio2" bandwidth="128000">
                <SegmentTemplate media="segment-$Number$.ts" timescale="90000" duration="5400000">
                    <RepresentationIndex sourceURL="representation-index.sidx"/>
                </SegmentTemplate>
            </Representation>
        </AdaptationSet>
    </Period>
</MPD>
`;

const DYNAMIC_MPD: string = `<?xml version="1.0" encoding="utf-8"?>
<MPD type="dynamic" mediaPresentationDuration="PT60S"><Period duration="PT60S"><AdaptationSet mimeType="video/mp4"><Representation id="v" bandwidth="1000"/></AdaptationSet></Period></MPD>`;

const ENCRYPTED_MPD: string = `<?xml version="1.0" encoding="utf-8"?>
<MPD type="static" mediaPresentationDuration="PT60S"><Period duration="PT60S"><AdaptationSet mimeType="video/mp4"><ContentProtection schemeIdUri="urn:mpeg:dash:mp4protection:2011"/><Representation id="v" bandwidth="1000"/></AdaptationSet></Period></MPD>`;

const NOPERIOD_MPD: string = `<?xml version="1.0" encoding="utf-8"?>
<MPD type="static" mediaPresentationDuration="PT60S"><ProgramInformation><Title>no period</Title></ProgramInformation></MPD>`;

const WRONGROOT_MPD: string = `<?xml version="1.0" encoding="utf-8"?>
<foo><bar/></foo>`;

const TZERO_MPD: string = `<?xml version="1.0" encoding="utf-8"?>
<MPD type="static" mediaPresentationDuration="PT1S"><Period duration="PT1S"><AdaptationSet mimeType="video/mp4"><SegmentTemplate timescale="1" media="s$Time$.ts" initialization="i.mp4"><SegmentTimeline><S t="500" d="100"/><S t="0" d="100"/></SegmentTimeline></SegmentTemplate><Representation id="v" bandwidth="1000"/></AdaptationSet></Period></MPD>`;

/** 探针固定基址（仅锚定相对段引用；不发起网络请求）。 */
const SMOOTH_URL: string = 'https://probe.invalid/p7u1/smooth.mpd';
const BBC_URL: string = 'https://probe.invalid/p7u1/bbc.mpd';
const MULTIPERIOD_URL: string = 'https://probe.invalid/p7u1/multiperiod.mpd';
const TZERO_URL: string = 'https://probe.invalid/p7u1/tzero.mpd';
/** Sintel 向量沿用源测试 playlistUrl（DashSanityTest.cs:179，尾随空格按 §5-13 修剪）。 */
const SINTEL_URL: string =
  'https://dash.akamaized.net/dash264/TestCasesMCA/fraunhofer/xHE-AAC_Stereo/2/Sintel/sintel_audio_video_brs.mpd';

/** S2 时长表 10 值用例（设计书 §6 DashUtil 行；另有 2 throw 用例在用例尾）。 */
class DurationCase {
  input: string = '';
  millis: number = 0;

  constructor(input: string, millis: number) {
    this.input = input;
    this.millis = millis;
  }
}

const DURATION_CASES: DurationCase[] = [
  new DurationCase('PT0H10M54.00S', 654000),
  new DurationCase('-PT30S', -30000),
  new DurationCase('PT0S', 0),
  new DurationCase('P1Y', 31556908000),
  new DurationCase('P2M', 5259478000),
  new DurationCase('P3D', 259200000),
  new DurationCase('PT4H5M6.5S', 14706500),
  new DurationCase('pt1h', 3600000),
  new DurationCase('0', 0),
  new DurationCase('1.5', 5400000)
];

/** 树统计（S1 nodeCount/maxDepth 观测）。 */
class TreeStats {
  nodes: number = 0;
  maxDepth: number = 0;
}

class FoundationDetails {
  unit: string = 'P7-U1-F';
  step: string = '';
  runId: string = '';
  sessionToken: string = '';
  facts: KeyValue[] = [];
}

function measureTree(node: DashXmlNode, depth: number, stats: TreeStats): void {
  stats.nodes++;
  if (depth > stats.maxDepth) { stats.maxDepth = depth; }
  for (let i = 0; i < node.children.length; i++) {
    measureTree(node.children[i], depth + 1, stats);
  }
}

/** 独立 Σ 公式（设计书 §7.1：音频计数用解析器与独立 Σ 双算一致性钉住）：
 * Σ over 全部 <S> of (1 + max(r,0))——与解析器状态机无共享代码路径。 */
function timelineMediaSum(events: DashXmlEvent[]): number {
  let sum: number = 0;
  for (let i = 0; i < events.length; i++) {
    const event: DashXmlEvent = events[i];
    if (event.kind === DASH_EVENT_START && event.name === 'S') {
      const raw: string = event.attrs['r'] ?? '-1';
      const repeat: number = Number(raw);
      sum += 1 + (Number.isFinite(repeat) && repeat > 0 ? repeat : 0);
    }
  }
  return sum;
}

/** 观测 URL 中的模板时间值（Smooth media 形态 Fragments(video=<time>,...)）。 */
function templateTimeOf(url: string): string {
  const key: string = 'video=';
  const at: number = url.indexOf(key);
  if (at < 0) { return ''; }
  let end: number = url.indexOf(',', at + key.length);
  if (end < 0) { end = url.length; }
  return url.substring(at + key.length, end);
}

/** 取 URL 末段（bbcFirstNumber 观测用）。 */
function tailOf(url: string): string {
  const slash: number = url.lastIndexOf('/');
  return slash >= 0 ? url.substring(slash + 1) : url;
}

function countPairs(periods: DashPair[][]): number {
  let total: number = 0;
  for (let i = 0; i < periods.length; i++) { total += periods[i].length; }
  return total;
}

function parseEvents(text: string, url: string): DashPair[][] {
  return parseDashManifestFromEvents(decodeMpdEvents(text), url, resolveHlsUrl);
}

/** 抛错观测（反例门）：返回 throw=true / passed=<thrown message unreachable>。 */
function rejects(text: string, url: string): boolean {
  try {
    parseEvents(text, url);
    return false;
  } catch (e) {
    return true;
  }
}

/** 每步骤独立 owner；P7-U1-F 无 IO/网络资源，取消只需作废会话。 */
class DashFoundationSession {
  readonly facts: KeyValue[] = [];
  private readonly token: string;
  private readonly kit: ProbeKit = ProbeKit.getInstance();
  private cancelled: boolean = false;

  constructor(token: string) {
    this.token = token;
  }

  isCurrent(): boolean { return !this.cancelled && this.kit.isCurrent(this.token); }

  cancel(): void { this.cancelled = true; }

  noteFailure(error: BusinessError): void {
    this.facts.push(new KeyValue('exception', 'true'));
    this.facts.push(new KeyValue('err', 'DashFoundationProbeFailure'));
  }

  private check(): void {
    if (!this.isCurrent()) { throw new Error('DashFoundationProbeStopped'); }
  }

  /** S1：真机 xml.parseXml 结构实测（token↔attr 相对序=EXPECT 钉板项）+ 树统计。 */
  private xmlStructure(): void {
    this.check();
    const events: DashXmlEvent[] = decodeMpdEvents(SMOOTH_MPD);
    this.facts.push(new KeyValue('eventCount', String(events.length)));
    const root: DashXmlNode = buildMpdTree(events);
    this.facts.push(new KeyValue('rootName', root.name));
    this.facts.push(new KeyValue('rootAttrCount', String(Object.keys(root.attrs).length)));
    this.facts.push(new KeyValue('ignoreNameSpaceNames', root.name === 'MPD' ? '1' : '0'));
    const stats: TreeStats = new TreeStats();
    measureTree(root, 1, stats);
    this.facts.push(new KeyValue('nodeCount', String(stats.nodes)));
    this.facts.push(new KeyValue('maxDepth', String(stats.maxDepth)));
    // 直接 parseXml 记录回调相对序（适配器对两种先后序均成立；实测序钉进 EXPECT）
    const encoder: util.TextEncoder = util.TextEncoder.create('utf-8');
    const encoded: Uint8Array = encoder.encodeInto(SMOOTH_MPD);
    const order: string[] = [];
    let selfClosing: number = 0;
    const onToken = (eventType: xml.EventType, parseInfo: xml.ParseInfo): boolean => {
      if (eventType === xml.EventType.START_TAG) {
        order.push('T');
        if (parseInfo.isEmptyElementTag()) { selfClosing++; }
      } else if (eventType === xml.EventType.END_TAG) {
        order.push('E');
      } else if (eventType === xml.EventType.TEXT) {
        order.push('X');
      }
      return true;
    };
    const onAttribute = (name: string, value: string): boolean => {
      order.push('A');
      return true;
    };
    const parser: xml.XmlPullParser = new xml.XmlPullParser(encoded.buffer as ArrayBuffer, 'UTF-8');
    const options: xml.ParseOptions = {
      supportDoctype: false,
      ignoreNameSpace: true,
      tokenValueCallbackFunction: onToken,
      attributeValueCallbackFunction: onAttribute
    };
    parser.parseXml(options);
    let sequence: string = '';
    const cap: number = Math.min(order.length, 48);
    for (let i = 0; i < cap; i++) { sequence += order[i]; }
    this.facts.push(new KeyValue('attrCallbackOrder', sequence));
    this.facts.push(new KeyValue('selfClosingCount', String(selfClosing)));
  }

  /** S2：parseXsDuration 表（10 值 + 2 throw）。 */
  private durationTable(): void {
    this.check();
    let ok: number = 0;
    for (let i = 0; i < DURATION_CASES.length; i++) {
      const value: number = parseXsDuration(DURATION_CASES[i].input);
      if (value === DURATION_CASES[i].millis) { ok++; }
    }
    this.facts.push(new KeyValue('durationCases', String(DURATION_CASES.length)));
    this.facts.push(new KeyValue('durationOk', String(ok === DURATION_CASES.length)));
    this.facts.push(new KeyValue('pt0h10m54', String(parseXsDuration('PT0H10M54.00S'))));
    let thrown: number = 0;
    try { parseXsDuration('1.2.3'); } catch (e) { thrown++; }
    try { parseXsDuration(''); } catch (e) { thrown++; }
    this.facts.push(new KeyValue('throwCases', '2'));
    this.facts.push(new KeyValue('throwOk', String(thrown === 2)));
  }

  /** S3：Smooth Timeline 端到端（video 91=init+89+1；音频计数 Σ 双算一致性）。 */
  private timelineExpand(): void {
    this.check();
    const events: DashXmlEvent[] = decodeMpdEvents(SMOOTH_MPD);
    const periods: DashPair[][] = parseEvents(SMOOTH_MPD, SMOOTH_URL);
    this.facts.push(new KeyValue('periodCount', String(periods.length)));
    this.facts.push(new KeyValue('pairCount', String(countPairs(periods))));
    const video = periods[0][0].video;
    const audio = periods[0][0].audio;
    if (video === null || audio === null) { throw new Error('DashFoundationPairUnavailable'); }
    this.facts.push(new KeyValue('videoSegmentsCount', String(video.segments.length)));
    this.facts.push(new KeyValue('videoInitI', String(video.segments[0].indexOf('video=i') >= 0)));
    this.facts.push(new KeyValue('videoLastTime', templateTimeOf(video.segments[video.segments.length - 1])));
    this.facts.push(new KeyValue('audioSegmentsCount', String(audio.segments.length)));
    const sum: number = timelineMediaSum(events);
    const videoMedia: number = video.segments.length - 1;
    const audioMedia: number = audio.segments.length - 1;
    this.facts.push(new KeyValue('audioSumCheck', String(sum === videoMedia + 2 * audioMedia)));
    this.facts.push(new KeyValue('timelineSumAll', String(sum)));
  }

  /** S4：Sintel simple 寻址+模板变量（startNumber=0/$$ 字面 $）。 */
  private simpleTemplate(): void {
    this.check();
    const periods: DashPair[][] = parseEvents(SINTEL_MPD, SINTEL_URL);
    this.facts.push(new KeyValue('periodCount', String(periods.length)));
    this.facts.push(new KeyValue('pairCount', String(countPairs(periods))));
    const video = periods[0][0].video;
    const audio = periods[0][0].audio;
    if (video === null || audio === null) { throw new Error('DashFoundationPairUnavailable'); }
    this.facts.push(new KeyValue('videoSegmentsCount', String(video.segments.length)));
    this.facts.push(new KeyValue('audioSegmentsCount', String(audio.segments.length)));
    this.facts.push(new KeyValue('audioMediaCount', String(audio.segments.length - 1)));
    this.facts.push(new KeyValue('startNumberZero', String(video.segments[1].indexOf('_0.m4s') >= 0)));
    this.facts.push(new KeyValue('dollarLiteral', String(audio.segments[1].indexOf('au$dio') >= 0)));
    this.facts.push(new KeyValue('videoInitTail', tailOf(video.segments[0]).replace(new RegExp('[^A-Za-z0-9_.-]', 'g'), '?')));
  }

  /** S5：三寻址+多周期（index/list/timeline 同现；t="0" 不重置 quirk）。 */
  private addressingMultiPeriod(): void {
    this.check();
    const periods: DashPair[][] = parseEvents(MULTIPERIOD_MPD, MULTIPERIOD_URL);
    this.facts.push(new KeyValue('periodCount', String(periods.length)));
    this.facts.push(new KeyValue('p1Items', String(periods[0].length)));
    this.facts.push(new KeyValue('p2Pairs', String(periods[1].length)));
    this.facts.push(new KeyValue('p2ListSegments', String(periods[1][0].video?.segments.length ?? -1)));
    this.facts.push(new KeyValue('p2TimelineSegments', String(periods[1][2].video?.segments.length ?? -1)));
    this.facts.push(new KeyValue('p1IndexSegments', String(periods[0][0].video?.segments.length ?? -1)));
    const tzero: DashPair[][] = parseEvents(TZERO_MPD, TZERO_URL);
    const tzeroVideo = tzero[0][0].video;
    if (tzeroVideo === null) { throw new Error('DashFoundationTzeroUnavailable'); }
    const first: string = tailOf(tzeroVideo.segments[1]);
    const second: string = tailOf(tzeroVideo.segments[2]);
    this.facts.push(new KeyValue('tzeroFirst', first));
    this.facts.push(new KeyValue('tzeroSecond', second));
    this.facts.push(new KeyValue('tEqualsZeroQuirk', String(first === 's500.ts' && second === 's600.ts')));
  }

  /** S6：dynamic/encrypted/no-period/非 MPD 四反例 + BBC 向量（%06d 补零实测）。 */
  private gatesAndBbc(): void {
    this.check();
    this.facts.push(new KeyValue('dynamicRejected', String(rejects(DYNAMIC_MPD, TZERO_URL))));
    this.facts.push(new KeyValue('encryptedRejected', String(rejects(ENCRYPTED_MPD, TZERO_URL))));
    this.facts.push(new KeyValue('noPeriodRejected', String(rejects(NOPERIOD_MPD, TZERO_URL))));
    this.facts.push(new KeyValue('wrongRootRejected', String(rejects(WRONGROOT_MPD, TZERO_URL))));
    const periods: DashPair[][] = parseEvents(BBC_MPD, BBC_URL);
    this.facts.push(new KeyValue('bbcPairs', String(countPairs(periods))));
    const video = periods[0][0].video;
    if (video === null) { throw new Error('DashFoundationBbcUnavailable'); }
    this.facts.push(new KeyValue('bbcVideoSegmentsCount', String(video.segments.length)));
    this.facts.push(new KeyValue('bbcFirstNumber', tailOf(video.segments[1]).replace('.m4s', '')));
  }

  async execute(step: string): Promise<void> {
    this.check();
    if (step === 'S1') { this.xmlStructure(); }
    else if (step === 'S2') { this.durationTable(); }
    else if (step === 'S3') { this.timelineExpand(); }
    else if (step === 'S4') { this.simpleTemplate(); }
    else if (step === 'S5') { this.addressingMultiPeriod(); }
    else if (step === 'S6') { this.gatesAndBbc(); }
    else { throw new Error('Unknown foundation probe step'); }
    this.check();
  }

  details(step: string, runId: string): string {
    const detail: FoundationDetails = new FoundationDetails();
    detail.step = step;
    detail.runId = runId;
    detail.sessionToken = this.token;
    detail.facts = this.facts.slice();
    return JSON.stringify(detail, null, 2);
  }
}

@Component
export struct ProbeDashFoundation {
  private alive: boolean = false;
  private owner: DashFoundationSession | undefined = undefined;

  aboutToAppear(): void { this.alive = true; }

  aboutToDisappear(): void {
    this.alive = false;
    this.owner?.cancel();
  }

  private async runStep(step: string): Promise<void> {
    if (!this.alive) { return; }
    const kit: ProbeKit = ProbeKit.getInstance();
    const token: string = kit.getSessionToken();
    if (!kit.isCurrent(token)) { return; }
    this.owner?.cancel();
    const session: DashFoundationSession = new DashFoundationSession(token);
    this.owner = session;
    try {
      try {
        await session.execute(step);
      } catch (error) {
        session.noteFailure(error as BusinessError);
      }
      if (!this.alive || this.owner !== session || !session.isCurrent()) { return; }
      kit.emit(step, session.facts);
    } finally {
      session.cancel();
      if (this.owner === session) { this.owner = undefined; }
    }
  }

  build() {
    Column({ space: 12 }) {
      Text($r('app.string.probe_p7u1_foundation_title')).fontSize(14).opacity(0.8).width('100%')
      ProbePage({
        unitId: 'P7-U1-F', pageTitle: $r('app.string.probe_p7u1_foundation_title'),
        steps: FOUNDATION_STEPS, autoStart: false,
        runStep: (step: string): Promise<void> => this.runStep(step)
      }).layoutWeight(1)
    }.width('100%').height('100%').padding(16)
  }
}
