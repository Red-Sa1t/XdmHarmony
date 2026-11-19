/* U6.4-B pure production plan/state tests. Absolute URI fixtures use an identity
 * resolver; these cases do not claim platform URL, disk, download or playback coverage.
 * 32 Hypium cases (U6.4-B) + 13 DASH cases (U7.1: buildDashPlan/dashMimeExtension/copyAdaptivePlan
 * Dash branch, design §6 AdaptivePlan row). Shared registration belongs to the integration owner. */
import { describe, expect, it } from '@ohos/hypium';
import { HlsMediaSegment, HlsPlaylist, HlsUrlResolver, HLS_MAX_URL_CHARS } from '../main/ets/core/adaptive/HlsModel';
import { parseHlsMediaPlaylist, HLS_MAX_SEGMENTS } from '../main/ets/core/adaptive/HlsParser';
import { AdaptivePlan, AdaptivePartState, AdaptiveDownloadState, AdaptiveChunk, AdaptiveChunkRange,
  AdaptiveProgress, ADAPTIVE_MAX_PLAN_CHARS, ADAPTIVE_MAX_STATE_CHARS, buildHlsPlan, buildDashPlan,
  copyAdaptivePlan, dashMimeExtension, isAdaptiveHttpUrl, partitionAdaptiveChunks,
  adaptiveProgress } from '../main/ets/core/adaptive/AdaptivePlan';
import { DASH_MAX_SEGMENTS } from '../main/ets/core/adaptive/DashModel';
import { newAdaptiveState, encodeAdaptiveState, decodeAdaptiveState,
  reconcileAdaptivePart } from '../main/ets/core/adaptive/AdaptiveStateCodec';

const PRIMARY: string = 'https://hls.example/video.m3u8?sig=a%2Fb';
const SECONDARY: string = 'https://hls.example/audio.m3u8?sig=a%2Bb';
const SEGMENT: string = 'https://hls.example/s.ts';
const NEXT: string = 'https://hls.example/next.ts';
const INIT: string = 'https://hls.example/init.mp4';
const AUDIO: string = 'https://hls.example/audio.m4a';
const ID: string = '01234567-89ab-cdef-0123-456789abcdef';
const OTHER_ID: string = '11234567-89ab-cdef-0123-456789abcdef';
const FIXTURE_RESOLVER: HlsUrlResolver = (_base: string, reference: string): string => reference;
// U7.1 DASH fixtures（绝对 URL，规避平台 URL 语义面）
const MANIFEST: string = 'https://dash.example/v.mpd';
const INIT_MP4: string = 'https://dash.example/v-init.mp4';
const V1: string = 'https://dash.example/v-1.m4s';
const V2: string = 'https://dash.example/v-2.m4s';
const AUDIO_MP4: string = 'https://dash.example/a-init.mp4';
const A1: string = 'https://dash.example/a-1.m4s';
const V_WEBM: string = 'https://dash.example/v-1.webm';
const A_WEBM: string = 'https://dash.example/a-1.webm';
const V_TS: string = 'https://dash.example/v-2.ts';
const A_TS: string = 'https://dash.example/a-1.ts';
type PlanMutation = (value: AdaptivePlan) => void;
type StateMutation = (value: AdaptiveDownloadState) => void;

function readMedia(lines: string[], url: string = PRIMARY): HlsPlaylist {
  const value: HlsPlaylist | null = parseHlsMediaPlaylist('#EXTM3U\n' + lines.join('\n'), url, FIXTURE_RESOLVER);
  if (value === null) { throw new Error('Unexpected invalid media fixture'); }
  return value;
}

function readPlan(lines: string[], audio: string[] | null = null): AdaptivePlan {
  const secondary: HlsPlaylist | null = audio === null ? null : readMedia(audio, SECONDARY);
  const value: AdaptivePlan | null = buildHlsPlan(PRIMARY, readMedia(lines), audio === null ? '' : SECONDARY, secondary);
  if (value === null) { throw new Error('Unexpected invalid plan fixture'); }
  return value;
}

function copyPlan(value: AdaptivePlan): AdaptivePlan {
  const copied: AdaptivePlan | null = copyAdaptivePlan(value);
  if (copied === null) { throw new Error('Unexpected invalid plan copy'); }
  return copied;
}

function freshState(lines: string[] = [SEGMENT]): AdaptiveDownloadState {
  const value: AdaptiveDownloadState | null = newAdaptiveState(ID, readPlan(lines));
  if (value === null) { throw new Error('Unexpected invalid state fixture'); }
  return value;
}

function roundTrip(value: AdaptiveDownloadState): AdaptiveDownloadState {
  const result: AdaptiveDownloadState | null = decodeAdaptiveState(encodeAdaptiveState(value), ID);
  if (result === null) { throw new Error('Unexpected invalid state round trip'); }
  return result;
}

function encodeError(value: AdaptiveDownloadState): string {
  try { encodeAdaptiveState(value); } catch (e) {
    if (e instanceof Error) { return e.message; }
    return 'Unexpected error type';
  }
  return '';
}

function rejectState(value: AdaptiveDownloadState): void {
  expect(encodeError(value)).assertEqual('Invalid adaptive state');
  expect(decodeAdaptiveState(JSON.stringify(value), ID) === null).assertTrue();
}

function savedPrefix(part: AdaptivePartState, downloaded: number, complete: boolean = false,
  fileName: string = 'owned.part'): void {
  part.downloaded = downloaded; part.complete = complete; part.fileName = fileName;
}

function parts(flags: boolean[]): AdaptivePartState[] {
  const result: AdaptivePartState[] = [];
  for (let i = 0; i < flags.length; i++) {
    const part: AdaptivePartState = new AdaptivePartState();
    part.chunkId = 'c' + String(i); part.complete = flags[i];
    part.fileName = flags[i] ? 'p' + String(i) + '.part' : '';
    result.push(part);
  }
  return result;
}

/** Direct typed metadata isolates the plan budget from the parser's input-text budget. */
function longPlaylist(count: number): HlsPlaylist {
  const value: HlsPlaylist = new HlsPlaylist();
  const prefix: string = 'https://hls.example/';
  const url: string = prefix + 'x'.repeat(HLS_MAX_URL_CHARS - prefix.length - 5) + '/s.ts';
  for (let i = 0; i < count; i++) {
    const segment: HlsMediaSegment = new HlsMediaSegment();
    segment.url = url; segment.sequence = i; value.segments.push(segment);
  }
  return value;
}

export default function adaptivePlanTest(): void {
  describe('AdaptivePlan', (): void => {
    it('single_track_preserves_snapshot_duration_and_path_extension', 0, (): void => {
      const value: AdaptivePlan = readPlan(['#EXTINF:1.25,', SEGMENT, '#EXTINF:2,',
        'https://hls.example/final.TS?token=.mp4#tail.mp4']);
      expect(value.kind).assertEqual('Hls'); expect(value.duration).assertEqual(3.25);
      expect(value.secondaryUrl).assertEqual(''); expect(value.suggestedExtension).assertEqual('.ts');
      expect(value.tracks[0].role).assertEqual('muxed'); expect(value.tracks[0].endList).assertFalse();
      expect(value.chunks[1].id).assertEqual('c1'); expect(value.chunks[1].trackOrder).assertEqual(1);
      const encoded: string = 'https://hls.example/file%2EMP4?token=.ts%2F%2B';
      const escaped: AdaptivePlan = readPlan([encoded]);
      expect(escaped.suggestedExtension).assertEqual('.mp4'); expect(escaped.chunks[0].url).assertEqual(encoded);
    });

    it('equal_tracks_interleave_and_take_maximum_duration', 0, (): void => {
      const value: AdaptivePlan = readPlan(['#EXTINF:4,', INIT, '#EXTINF:5,', INIT, '#EXT-X-ENDLIST'],
        ['#EXTINF:2,', AUDIO, '#EXTINF:3,', AUDIO]);
      expect(value.duration).assertEqual(9); expect(value.suggestedExtension).assertEqual('.mp4');
      expect(value.tracks[0].role).assertEqual('video'); expect(value.tracks[1].role).assertEqual('audio');
      expect(value.tracks[0].endList).assertTrue(); expect(value.tracks[1].endList).assertFalse();
      for (let i = 0; i < 4; i++) {
        expect(value.chunks[i].id).assertEqual('c' + String(i));
        expect(value.chunks[i].trackIndex).assertEqual(i % 2);
        expect(value.chunks[i].trackOrder).assertEqual(Math.floor(i / 2));
      }
    });

    it('unequal_tracks_append_the_longer_track_in_order', 0, (): void => {
      const primary: AdaptivePlan = readPlan([SEGMENT, NEXT, SEGMENT], [AUDIO]);
      expect(primary.chunks[2].trackIndex).assertEqual(0); expect(primary.chunks[3].trackOrder).assertEqual(2);
      const secondary: AdaptivePlan = readPlan([SEGMENT], [AUDIO, AUDIO, AUDIO]);
      expect(secondary.chunks[2].trackIndex).assertEqual(1); expect(secondary.chunks[3].trackOrder).assertEqual(2);
      expect(secondary.suggestedExtension).assertEqual('.mkv');
    });

    it('map_sequence_and_discontinuity_preserve_source_last_item', 0, (): void => {
      const value: AdaptivePlan = readPlan(['#EXT-X-MEDIA-SEQUENCE:8', '#EXT-X-DISCONTINUITY-SEQUENCE:2',
        '#EXT-X-MAP:URI="' + INIT + '"', '#EXTINF:3,', SEGMENT, '#EXT-X-DISCONTINUITY',
        '#EXT-X-MAP:URI="' + INIT + '?tail=.ts"']);
      expect(value.chunks.length).assertEqual(3); expect(value.chunks[0].isInit).assertTrue();
      expect(value.chunks[0].mediaSequence).assertEqual(8); expect(value.chunks[1].mediaSequence).assertEqual(8);
      expect(value.chunks[2].mediaSequence).assertEqual(9); expect(value.chunks[2].duration).assertEqual(0);
      expect(value.chunks[2].discontinuity).assertTrue(); expect(value.chunks[2].discontinuitySequence).assertEqual(3);
      expect(value.duration).assertEqual(3); expect(value.suggestedExtension).assertEqual('.mp4');
    });

    it('mixed_ranges_keep_resource_offsets_and_whole_resource_sentinel', 0, (): void => {
      const value: AdaptivePlan = readPlan(['#EXT-X-BYTERANGE:10@90', INIT, SEGMENT,
        '#EXT-X-BYTERANGE:5@0', INIT]);
      expect(value.chunks[0].offset).assertEqual(90); expect(value.chunks[0].length).assertEqual(10);
      expect(value.chunks[1].offset).assertEqual(0); expect(value.chunks[1].length).assertEqual(-1);
      expect(value.chunks[2].offset).assertEqual(0); expect(value.chunks[2].length).assertEqual(5);
    });

    it('range_endpoint_at_safe_integer_limit_and_overflow_are_distinct', 0, (): void => {
      const value: AdaptivePlan = readPlan(['#EXT-X-BYTERANGE:2@9007199254740990', SEGMENT]);
      expect(value.chunks[0].offset + value.chunks[0].length - 1).assertEqual(Number.MAX_SAFE_INTEGER);
      value.chunks[0].offset = Number.MAX_SAFE_INTEGER;
      expect(copyAdaptivePlan(value) === null).assertTrue();
      value.chunks[0].offset = 0; value.chunks[0].length = 0;
      expect(copyAdaptivePlan(value) === null).assertTrue();
    });

    it('builder_and_copier_do_not_alias_parser_or_caller_models', 0, (): void => {
      const media: HlsPlaylist = readMedia(['#EXT-X-BYTERANGE:5@20', SEGMENT]);
      const built: AdaptivePlan | null = buildHlsPlan(PRIMARY, media);
      if (built === null) { throw new Error('Unexpected invalid copy fixture'); }
      const copied: AdaptivePlan = copyPlan(built);
      media.segments[0].url = INIT; built.chunks[0].offset = 99; built.tracks[0].playlistUrl = SECONDARY;
      expect(copied.chunks[0].url).assertEqual(SEGMENT); expect(copied.chunks[0].offset).assertEqual(20);
      expect(copied.tracks[0].playlistUrl).assertEqual(PRIMARY);
    });

    it('encryption_cannot_hide_behind_none_or_aggregate_and_iframes_reject', 0, (): void => {
      const encrypted: HlsPlaylist = readMedia(['#EXT-X-KEY:METHOD=AES-128,URI="https://hls.example/key"',
        SEGMENT, '#EXT-X-KEY:METHOD=NONE', NEXT]);
      expect(buildHlsPlan(PRIMARY, encrypted) === null).assertTrue();
      encrypted.isEncrypted = false;
      expect(buildHlsPlan(PRIMARY, encrypted) === null).assertTrue();
      const ivOnly: HlsPlaylist = readMedia([SEGMENT]); ivOnly.segments[0].iv = '0x1';
      expect(buildHlsPlan(PRIMARY, ivOnly) === null).assertTrue();
      expect(buildHlsPlan(PRIMARY, readMedia(['#EXT-X-I-FRAMES-ONLY', SEGMENT])) === null).assertTrue();
    });

    it('every_track_needs_real_media_and_secondary_inputs_must_pair', 0, (): void => {
      const media: HlsPlaylist = readMedia([SEGMENT]);
      expect(buildHlsPlan(PRIMARY, media, SECONDARY, null) === null).assertTrue();
      expect(buildHlsPlan(PRIMARY, media, '', media) === null).assertTrue();
      expect(buildHlsPlan(PRIMARY, new HlsPlaylist()) === null).assertTrue();
      const mapOnly: HlsPlaylist = readMedia(['#EXT-X-MAP:URI="' + INIT + '"', SEGMENT]);
      mapOnly.segments.pop(); expect(buildHlsPlan(PRIMARY, mapOnly) === null).assertTrue();
    });

    it('contradictory_playlist_aggregates_and_sequence_metadata_reject', 0, (): void => {
      let media: HlsPlaylist = readMedia([SEGMENT]); media.hasByteRange = true;
      expect(buildHlsPlan(PRIMARY, media) === null).assertTrue();
      media = readMedia(['#EXT-X-BYTERANGE:5@10', SEGMENT]); media.hasByteRange = false;
      expect(buildHlsPlan(PRIMARY, media) === null).assertTrue();
      media = readMedia([SEGMENT]); media.totalDuration = 1;
      expect(buildHlsPlan(PRIMARY, media) === null).assertTrue();
      media = readMedia([SEGMENT]); media.segments[0].sequence = 2;
      expect(buildHlsPlan(PRIMARY, media) === null).assertTrue();
      media = readMedia([SEGMENT]); media.segments[0].discontinuitySequence = 1;
      expect(buildHlsPlan(PRIMARY, media) === null).assertTrue();
    });

    it('raw_http_shapes_validate_authority_ports_and_literal_urls', 0, (): void => {
      const valid: string[] = ['http://localhost:8080/s.ts', 'https://[::1]:443/s.ts',
        'https://[::ffff:127.0.0.1]/s.ts', 'https://user:pass@host/s.ts?sig=a%2Fb',
        'http://[::]/s.ts', 'http://[1::]/s.ts',
        'https://例子.test/s.ts', 'https://host/%7B$prefix%7D/s.ts'];
      for (let i = 0; i < valid.length; i++) { expect(isAdaptiveHttpUrl(valid[i])).assertTrue(); }
      const invalid: string[] = ['', 'https://', 'https:///s.ts', 'file:///s.ts', 'https:host/s.ts',
        'https://host:65536/s.ts', 'https://host:/s.ts', 'https://[:::]/s.ts', 'https://host/s ts',
        'http://[::1:]/part.ts', 'http://[:1::]/part.ts', 'http://[1::2:]/part.ts',
        'https://host/s\nts', 'https://host\\s.ts', 'https://host/{$prefix}/s.ts', 'https://bad|host/s.ts'];
      for (let i = 0; i < invalid.length; i++) { expect(isAdaptiveHttpUrl(invalid[i])).assertFalse(); }
      expect(isAdaptiveHttpUrl('https://host/' + 'x'.repeat(HLS_MAX_URL_CHARS))).assertFalse();
    });

    it('canonical_ids_track_order_roles_and_derived_values_reject_tampering', 0, (): void => {
      const original: AdaptivePlan = readPlan([SEGMENT, NEXT], [AUDIO, AUDIO]);
      const mutations: PlanMutation[] = [
        (value: AdaptivePlan): void => { value.chunks[1].id = 'c0'; },
        (value: AdaptivePlan): void => { value.chunks[0].id = 'c00'; },
        (value: AdaptivePlan): void => { value.chunks[2].trackOrder = 3; },
        (value: AdaptivePlan): void => {
          const first: AdaptiveChunk = value.chunks[0]; value.chunks[0] = value.chunks[1]; value.chunks[1] = first;
          value.chunks[0].id = 'c0'; value.chunks[1].id = 'c1';
        },
        (value: AdaptivePlan): void => { value.tracks[0].role = 'muxed'; },
        (value: AdaptivePlan): void => { value.tracks[1].playlistUrl = PRIMARY; },
        (value: AdaptivePlan): void => { value.tracks[0].container = '.mp4'; },
        (value: AdaptivePlan): void => { value.duration = 99; },
        (value: AdaptivePlan): void => { value.suggestedExtension = '.ts'; },
        (value: AdaptivePlan): void => { value.chunks[2].mediaSequence = 9; }
      ];
      for (let i = 0; i < mutations.length; i++) {
        const value: AdaptivePlan = copyPlan(original); mutations[i](value);
        expect(copyAdaptivePlan(value) === null).assertTrue();
      }
    });

    it('canonical_plan_rejects_extra_fields_and_unsafe_scalar_values', 0, (): void => {
      const original: AdaptivePlan = readPlan(['#EXT-X-BYTERANGE:10@90', SEGMENT]);
      const raw: Object | null = JSON.parse(JSON.stringify(original).replace('"kind":"Hls"', '"kind":"Hls","extra":1'));
      expect(copyAdaptivePlan(raw) === null).assertTrue();
      const mutations: PlanMutation[] = [
        (value: AdaptivePlan): void => { value.chunks[0].duration = Number.NaN; },
        (value: AdaptivePlan): void => { value.chunks[0].offset = -1; },
        (value: AdaptivePlan): void => { value.chunks[0].length = -1; },
        (value: AdaptivePlan): void => { value.chunks[0].trackIndex = 0.5; },
        (value: AdaptivePlan): void => { value.chunks[0].mediaSequence = Number.MAX_SAFE_INTEGER + 1; },
        (value: AdaptivePlan): void => { value.chunks[0].isInit = true; value.chunks[0].duration = 1; }
      ];
      for (let i = 0; i < mutations.length; i++) {
        const value: AdaptivePlan = copyPlan(original); mutations[i](value);
        expect(copyAdaptivePlan(value) === null).assertTrue();
      }
    });

    it('partition_preserves_source_finished_item_boundaries', 0, (): void => {
      const full: AdaptiveChunkRange[] = partitionAdaptiveChunks(parts([true, false, true, false, true]), 2);
      expect(full.length).assertEqual(2); expect(full[0].start).assertEqual(0); expect(full[0].end).assertEqual(1);
      expect(full[1].start).assertEqual(2); expect(full[1].end).assertEqual(3);
      const partial: AdaptiveChunkRange[] = partitionAdaptiveChunks(parts([true, false, true, false, true, false, true]), 2);
      expect(partial[0].end).assertEqual(3); expect(partial[1].start).assertEqual(4); expect(partial[1].end).assertEqual(6);
      expect(partitionAdaptiveChunks(parts([true, true]), 64).length).assertEqual(0);
      expect(partitionAdaptiveChunks([], 64).length).assertEqual(0);
    });

    it('partition_supports_64_and_normalizes_invalid_caps_without_losing_items', 0, (): void => {
      const flags: boolean[] = []; for (let i = 0; i < 64; i++) { flags.push(false); }
      const entries: AdaptivePartState[] = parts(flags);
      const caps: number[] = [1, 3, 8, 16, 17, 32, 64, 65, 0, -1, 1.5, Number.NaN, Number.POSITIVE_INFINITY];
      const maximums: number[] = [1, 3, 8, 16, 17, 32, 64, 64, 1, 1, 1, 1, 1];
      for (let i = 0; i < caps.length; i++) {
        const ranges: AdaptiveChunkRange[] = partitionAdaptiveChunks(entries, caps[i]);
        expect(ranges.length <= maximums[i]).assertTrue();
        let next: number = 0;
        for (let j = 0; j < ranges.length; j++) {
          expect(ranges[j].start).assertEqual(next); expect(ranges[j].end >= next).assertTrue();
          next = ranges[j].end + 1;
        }
        expect(next).assertEqual(64);
        if (maximums[i] === 64) { expect(ranges.length).assertEqual(64); }
      }
    });

    it('progress_counts_verified_chunks_and_committed_bytes_separately', 0, (): void => {
      const entries: AdaptivePartState[] = parts([true, false, false]);
      entries[0].downloaded = 10; entries[1].downloaded = 5;
      const value: AdaptiveProgress = adaptiveProgress(entries);
      expect(value.completed).assertEqual(1); expect(value.total).assertEqual(3);
      expect(value.percent).assertEqual(33); expect(value.downloadedBytes).assertEqual(15);
      expect(adaptiveProgress([]).percent).assertEqual(0);
      expect(adaptiveProgress(parts([true, true])).percent).assertEqual(100);
    });

    it('progress_rejects_invalid_bytes_and_sum_overflow', 0, (): void => {
      const invalid: number[] = [-1, 0.5, Number.NaN, Number.POSITIVE_INFINITY, Number.MAX_SAFE_INTEGER + 1];
      for (let i = 0; i < invalid.length; i++) {
        const entries: AdaptivePartState[] = parts([false]); entries[0].downloaded = invalid[i];
        let message: string = '';
        try { adaptiveProgress(entries); } catch (e) { if (e instanceof Error) { message = e.message; } }
        expect(message).assertEqual('Invalid adaptive progress');
      }
      const entries: AdaptivePartState[] = parts([false, false]);
      entries[0].downloaded = Number.MAX_SAFE_INTEGER; entries[1].downloaded = 1;
      let rejected: boolean = false;
      try { adaptiveProgress(entries); } catch (e) { rejected = true; }
      expect(rejected).assertTrue();
    });

    it('fresh_state_has_ordered_empty_parts_and_an_independent_plan', 0, (): void => {
      const original: AdaptivePlan = readPlan([SEGMENT, NEXT]);
      const value: AdaptiveDownloadState | null = newAdaptiveState(ID, original);
      if (value === null) { throw new Error('Unexpected invalid state'); }
      expect(value.schema).assertEqual(1); expect(value.generation).assertEqual(0); expect(value.downloadId).assertEqual(ID);
      for (let i = 0; i < value.parts.length; i++) {
        expect(value.parts[i].chunkId).assertEqual('c' + String(i)); expect(value.parts[i].fileName).assertEqual('');
        expect(value.parts[i].downloaded).assertEqual(0); expect(value.parts[i].complete).assertFalse();
      }
      original.chunks[0].url = INIT; expect(value.plan.chunks[0].url).assertEqual(SEGMENT);
      expect(newAdaptiveState('../outside', original) === null).assertTrue();
    });

    it('codec_round_trips_partial_complete_empty_and_safe_generation', 0, (): void => {
      const value: AdaptiveDownloadState = freshState(['#EXT-X-BYTERANGE:10@90', SEGMENT,
        '#EXT-X-BYTERANGE:5@20', SEGMENT, NEXT]);
      savedPrefix(value.parts[0], 4, false, 'prefix.part'); savedPrefix(value.parts[1], 5, true, 'verified.part');
      savedPrefix(value.parts[2], 0, true, 'empty.part'); value.generation = Number.MAX_SAFE_INTEGER;
      const decoded: AdaptiveDownloadState = roundTrip(value);
      expect(JSON.stringify(decoded)).assertEqual(JSON.stringify(value));
      decoded.parts[0].downloaded = 2; decoded.plan.chunks[0].url = INIT;
      expect(value.parts[0].downloaded).assertEqual(4); expect(value.plan.chunks[0].url).assertEqual(SEGMENT);
    });

    it('codec_binds_uuid_schema_and_safe_nonnegative_generation', 0, (): void => {
      expect(decodeAdaptiveState(encodeAdaptiveState(freshState()), OTHER_ID) === null).assertTrue();
      const mutations: StateMutation[] = [
        (value: AdaptiveDownloadState): void => { value.schema = 2; },
        (value: AdaptiveDownloadState): void => { value.downloadId = 'invalid'; },
        (value: AdaptiveDownloadState): void => { value.generation = -1; },
        (value: AdaptiveDownloadState): void => { value.generation = 0.5; },
        (value: AdaptiveDownloadState): void => { value.generation = Number.MAX_SAFE_INTEGER + 1; }
      ];
      for (let i = 0; i < mutations.length; i++) {
        const value: AdaptiveDownloadState = freshState(); mutations[i](value); rejectState(value);
      }
    });

    it('codec_rejects_extra_missing_prototype_and_wrong_type_fields', 0, (): void => {
      const encoded: string = encodeAdaptiveState(freshState());
      const invalid: string[] = [encoded.replace('"schema":1', '"schema":"1"'),
        encoded.replace('"generation":0', '"generation":0,"cookies":"private"'),
        encoded.replace('"kind":"Hls"', '"kind":"Hls","__proto__":{}'),
        encoded.replace('"role":"muxed"', '"role":"muxed","extra":1'),
        encoded.replace('"isInit":false', '"isInit":false,"extra":1'),
        encoded.replace('"complete":false,', ''), encoded.replace('"complete":false', '"complete":"false"'),
        encoded.replace('"downloaded":0', '"downloaded":"0"')];
      for (let i = 0; i < invalid.length; i++) { expect(decodeAdaptiveState(invalid[i], ID) === null).assertTrue(); }
    });

    it('known_range_truth_table_requires_exact_verified_completion', 0, (): void => {
      const value: AdaptiveDownloadState = freshState(['#EXT-X-BYTERANGE:10@90', SEGMENT]);
      expect(roundTrip(value).parts[0].fileName).assertEqual('');
      savedPrefix(value.parts[0], 9); expect(roundTrip(value).parts[0].downloaded).assertEqual(9);
      savedPrefix(value.parts[0], 10, true); expect(roundTrip(value).parts[0].complete).assertTrue();
      savedPrefix(value.parts[0], 10, false); rejectState(value);
      savedPrefix(value.parts[0], 11, false); rejectState(value);
      savedPrefix(value.parts[0], 9, true); rejectState(value);
      savedPrefix(value.parts[0], 0, true); rejectState(value);
      savedPrefix(value.parts[0], 1, false, ''); rejectState(value);
      savedPrefix(value.parts[0], 0, false); rejectState(value);
    });

    it('whole_resource_truth_table_distinguishes_empty_verified_from_fresh', 0, (): void => {
      const value: AdaptiveDownloadState = freshState();
      savedPrefix(value.parts[0], 0, true, 'empty.part'); expect(roundTrip(value).parts[0].complete).assertTrue();
      savedPrefix(value.parts[0], 1, false); expect(roundTrip(value).parts[0].complete).assertFalse();
      savedPrefix(value.parts[0], 1, true); expect(roundTrip(value).parts[0].complete).assertTrue();
      savedPrefix(value.parts[0], 0, false); rejectState(value);
      savedPrefix(value.parts[0], 0, true, ''); rejectState(value);
      savedPrefix(value.parts[0], 1, true, ''); rejectState(value);
      savedPrefix(value.parts[0], 1, false, ''); rejectState(value);
    });

    it('basenames_are_bounded_internal_names_and_globally_unique', 0, (): void => {
      const invalid: string[] = ['../x.part', '/x.part', 'C:\\x.part', 'x.part/child', '.part', 'x.PART',
        'x.part:stream', '中文.part', 'x'.repeat(121) + '.part', 'x.part\n'];
      for (let i = 0; i < invalid.length; i++) {
        const value: AdaptiveDownloadState = freshState(); savedPrefix(value.parts[0], 1, false, invalid[i]); rejectState(value);
      }
      const value: AdaptiveDownloadState = freshState([SEGMENT, NEXT]);
      savedPrefix(value.parts[0], 1, false, 'x'.repeat(120) + '.part');
      expect(roundTrip(value).parts[0].fileName.length).assertEqual(125);
      savedPrefix(value.parts[1], 1, true, value.parts[0].fileName); rejectState(value);
    });

    it('parts_have_exact_plan_correspondence_and_safe_total_bytes', 0, (): void => {
      let value: AdaptiveDownloadState = freshState([SEGMENT, NEXT]); value.parts.reverse(); rejectState(value);
      value = freshState([SEGMENT, NEXT]); value.parts.pop(); rejectState(value);
      value = freshState([SEGMENT, NEXT]); value.parts[0].chunkId = 'c1'; rejectState(value);
      value = freshState([SEGMENT, NEXT]);
      savedPrefix(value.parts[0], Number.MAX_SAFE_INTEGER, true, 'one.part');
      savedPrefix(value.parts[1], 1, true, 'two.part'); rejectState(value);
    });

    it('invalid_encoder_error_does_not_expose_urls_or_saved_content', 0, (): void => {
      const value: AdaptiveDownloadState = freshState();
      value.plan.primaryUrl = 'https://user:password@host/?token=hidden';
      expect(encodeError(value)).assertEqual('Invalid adaptive state');
    });

    it('decoder_rejects_malformed_primitive_and_deep_shapes', 0, (): void => {
      const invalid: string[] = ['', '{', 'null', '[]', '1', '"string"', '{"__proto__":{"polluted":true}}',
        '{"constructor":{"prototype":{"x":1}}}', '['.repeat(9) + '0' + ']'.repeat(9)];
      for (let i = 0; i < invalid.length; i++) { expect(decodeAdaptiveState(invalid[i], ID) === null).assertTrue(); }
    });

    it('reconcile_clears_short_or_missing_files_and_preserves_saved_prefix', 0, (): void => {
      const value: AdaptiveDownloadState = freshState(['#EXT-X-BYTERANGE:10@90', SEGMENT]);
      savedPrefix(value.parts[0], 4, false, 'prefix.part');
      const invalid: number[] = [-1, -2, 0, 3, Number.NaN, Number.POSITIVE_INFINITY, Number.MAX_SAFE_INTEGER + 1];
      for (let i = 0; i < invalid.length; i++) {
        const reset: AdaptivePartState = reconcileAdaptivePart(value.plan.chunks[0], value.parts[0], invalid[i]);
        expect(reset.chunkId).assertEqual('c0'); expect(reset.downloaded).assertEqual(0);
        expect(reset.fileName).assertEqual(''); expect(reset.complete).assertFalse();
      }
      const retained: AdaptivePartState = reconcileAdaptivePart(value.plan.chunks[0], value.parts[0], 100);
      expect(retained.downloaded).assertEqual(4); expect(retained.complete).assertFalse();
      retained.downloaded = 2; expect(value.parts[0].downloaded).assertEqual(4);
    });

    it('stat_never_completes_whole_resources_or_invents_verified_empty_data', 0, (): void => {
      const value: AdaptiveDownloadState = freshState();
      expect(reconcileAdaptivePart(value.plan.chunks[0], value.parts[0], 100).complete).assertFalse();
      savedPrefix(value.parts[0], 3);
      const retained: AdaptivePartState = reconcileAdaptivePart(value.plan.chunks[0], value.parts[0], 999999);
      expect(retained.downloaded).assertEqual(3); expect(retained.complete).assertFalse();
      savedPrefix(value.parts[0], 0, true, 'empty.part');
      expect(reconcileAdaptivePart(value.plan.chunks[0], value.parts[0], 0).complete).assertTrue();
      expect(reconcileAdaptivePart(value.plan.chunks[0], value.parts[0], -1).complete).assertFalse();
    });

    it('reconcile_resets_uncommitted_ranges_and_keeps_safe_verified_boundaries', 0, (): void => {
      const value: AdaptiveDownloadState = freshState(['#EXT-X-BYTERANGE:2@9007199254740990', SEGMENT]);
      savedPrefix(value.parts[0], 2, false, 'attempt.part');
      expect(reconcileAdaptivePart(value.plan.chunks[0], value.parts[0], 2).fileName).assertEqual('');
      savedPrefix(value.parts[0], 1, false, 'prefix.part');
      const partial: AdaptivePartState = reconcileAdaptivePart(value.plan.chunks[0], value.parts[0], 10);
      expect(partial.downloaded).assertEqual(1); expect(partial.complete).assertFalse();
      expect(value.plan.chunks[0].offset + partial.downloaded).assertEqual(Number.MAX_SAFE_INTEGER);
      savedPrefix(value.parts[0], 2, true, 'verified.part');
      expect(reconcileAdaptivePart(value.plan.chunks[0], value.parts[0], 3).complete).assertTrue();
      savedPrefix(value.parts[0], 3, true, 'overrun.part');
      expect(reconcileAdaptivePart(value.plan.chunks[0], value.parts[0], 3).complete).assertFalse();
    });

    it('plan_budget_counts_complete_json_and_enforces_per_track_count', 0, (): void => {
      const accepted: AdaptivePlan | null = buildHlsPlan(PRIMARY, longPlaylist(240));
      if (accepted === null) { throw new Error('Unexpected invalid budget fixture'); }
      expect(JSON.stringify(accepted).length < ADAPTIVE_MAX_PLAN_CHARS).assertTrue();
      expect(newAdaptiveState(ID, accepted) !== null).assertTrue();
      expect(256 * HLS_MAX_URL_CHARS).assertEqual(ADAPTIVE_MAX_PLAN_CHARS);
      expect(buildHlsPlan(PRIMARY, longPlaylist(256)) === null).assertTrue();
      const tooMany: HlsPlaylist = new HlsPlaylist();
      for (let i = 0; i <= HLS_MAX_SEGMENTS; i++) {
        const segment: HlsMediaSegment = new HlsMediaSegment();
        segment.url = SEGMENT; segment.sequence = i; tooMany.segments.push(segment);
      }
      expect(buildHlsPlan(PRIMARY, tooMany) === null).assertTrue();
    });

    it('state_text_budget_precedes_parsing_and_preserves_quoted_delimiters', 0, (): void => {
      expect(decodeAdaptiveState(' '.repeat(ADAPTIVE_MAX_STATE_CHARS + 1), ID) === null).assertTrue();
      const value: AdaptiveDownloadState = freshState(['https://hls.example/[brackets]{literal}.ts?quoted="x"']);
      expect(roundTrip(value).plan.chunks[0].url).assertEqual(value.plan.chunks[0].url);
    });

    // ────────────── U7.1：buildDashPlan / dashMimeExtension / copyAdaptivePlan Dash 分支 ──────────────

    it('dash_plan_interleave_and_chunk_shape', 0, (): void => {
      // CreateChunks2 交错序 + CreateChunk 恒 offset=0/length=-1/isInit=false/duration=0（§3.2）
      const plan: AdaptivePlan | null = buildDashPlan(MANIFEST,
        [INIT_MP4, V1, V2], 'video/mp4', [AUDIO_MP4, A1], 'audio/mp4', 60000, 60000);
      if (plan === null) { throw new Error('Unexpected invalid dash plan'); }
      expect(plan.kind).assertEqual('Dash');
      expect(plan.chunks.length).assertEqual(5);
      const expectedTrack: number[] = [0, 1, 0, 1, 0];
      const expectedOrder: number[] = [0, 0, 1, 1, 2];
      for (let i = 0; i < plan.chunks.length; i++) {
        expect(plan.chunks[i].id).assertEqual('c' + String(i));
        expect(plan.chunks[i].trackIndex).assertEqual(expectedTrack[i]);
        expect(plan.chunks[i].trackOrder).assertEqual(expectedOrder[i]);
        expect(plan.chunks[i].offset).assertEqual(0);
        expect(plan.chunks[i].length).assertEqual(-1);
        expect(plan.chunks[i].isInit).assertFalse();
        expect(plan.chunks[i].duration).assertEqual(0);
        expect(plan.chunks[i].mediaSequence).assertEqual(expectedOrder[i]);
        expect(plan.chunks[i].discontinuity).assertFalse();
      }
    });

    it('dash_plan_video_tail_chunks_appended', 0, (): void => {
      // :285-290 video 尾段追列（audio 短一截）
      const plan: AdaptivePlan | null = buildDashPlan(MANIFEST,
        [INIT_MP4, V1, V2], 'video/mp4', [AUDIO_MP4], 'audio/mp4', 60000, 60000);
      if (plan === null) { throw new Error('Unexpected invalid dash plan'); }
      expect(plan.chunks.length).assertEqual(4);
      expect(plan.chunks[1].trackIndex).assertEqual(1);
      expect(plan.chunks[2].trackIndex).assertEqual(0);
      expect(plan.chunks[2].trackOrder).assertEqual(1);
      expect(plan.chunks[3].trackIndex).assertEqual(0);
      expect(plan.chunks[3].trackOrder).assertEqual(2);
    });

    it('dash_plan_duration_is_max_of_tracks', 0, (): void => {
      // 源 :245 Math.Max
      const plan: AdaptivePlan | null = buildDashPlan(MANIFEST, [V1], 'video/mp4',
        [A1], 'audio/mp4', 5000, 9000);
      if (plan === null) { throw new Error('Unexpected invalid dash plan'); }
      expect(plan.duration).assertEqual(9000);
    });

    it('dash_plan_dual_mp4_mimes_pick_mp4', 0, (): void => {
      const plan: AdaptivePlan | null = buildDashPlan(MANIFEST, [V1], 'video/mp4',
        [A1], 'audio/mp4', 1000, 1000);
      if (plan === null) { throw new Error('Unexpected invalid dash plan'); }
      expect(plan.suggestedExtension).assertEqual('.mp4');
      expect(plan.tracks[0].container).assertEqual('.mp4');
      expect(plan.tracks[1].container).assertEqual('.mp4');
    });

    it('dash_plan_webm_mime_picks_mkv', 0, (): void => {
      const plan: AdaptivePlan | null = buildDashPlan(MANIFEST, [V_WEBM], 'video/webm',
        [A_WEBM], 'audio/webm', 1000, 1000);
      if (plan === null) { throw new Error('Unexpected invalid dash plan'); }
      expect(plan.suggestedExtension).assertEqual('.mkv');
      expect(plan.tracks[0].container).assertEqual('.mkv');
    });

    it('dash_plan_mime_miss_falls_back_to_last_segment_extension', 0, (): void => {
      // :61-64 链第三段 GuessContainerFormatFromPlaylist
      const plan: AdaptivePlan | null = buildDashPlan(MANIFEST, [V_TS], 'video/x-unknown',
        [A_TS], 'audio/x-unknown', 1000, 1000);
      if (plan === null) { throw new Error('Unexpected invalid dash plan'); }
      expect(plan.tracks[0].container).assertEqual('.ts');
      expect(plan.suggestedExtension).assertEqual('.ts');
    });

    it('dash_plan_suggested_equals_first_container_identity', 0, (): void => {
      // 校验器恒等式（§3.2）：suggestedExtension === tracks[0].container
      const plan: AdaptivePlan | null = buildDashPlan(MANIFEST, [V_WEBM], 'video/webm',
        [A1], 'audio/mp4', 1000, 1000);
      if (plan === null) { throw new Error('Unexpected invalid dash plan'); }
      expect(plan.suggestedExtension).assertEqual(plan.tracks[0].container);
      expect(copyAdaptivePlan(plan) === null).assertFalse();
    });

    it('dash_plan_over_budget_segment_count_rejected', 0, (): void => {
      const tooMany: string[] = [];
      for (let i = 0; i <= DASH_MAX_SEGMENTS; i++) { tooMany.push(V1); }
      expect(buildDashPlan(MANIFEST, tooMany, 'video/mp4', [A1], 'audio/mp4', 1000, 1000) === null)
        .assertTrue();
    });

    it('dash_plan_empty_audio_rejected', 0, (): void => {
      expect(buildDashPlan(MANIFEST, [V1], 'video/mp4', [], 'audio/mp4', 1000, 1000) === null)
        .assertTrue();
      expect(buildDashPlan(MANIFEST, [], 'video/mp4', [A1], 'audio/mp4', 1000, 1000) === null)
        .assertTrue();
    });

    it('dash_plan_invalid_segment_url_rejected', 0, (): void => {
      expect(buildDashPlan(MANIFEST, ['http://bad host/seg.m4s'], 'video/mp4',
        [A1], 'audio/mp4', 1000, 1000) === null).assertTrue();
      expect(buildDashPlan('not-a-url', [V1], 'video/mp4', [A1], 'audio/mp4', 1000, 1000) === null)
        .assertTrue();
    });

    it('dash_plan_state_roundtrip_via_codec', 0, (): void => {
      const plan: AdaptivePlan | null = buildDashPlan(MANIFEST, [INIT_MP4, V1], 'video/mp4',
        [AUDIO_MP4, A1], 'audio/mp4', 60000, 60000);
      if (plan === null) { throw new Error('Unexpected invalid dash plan'); }
      const state: AdaptiveDownloadState | null = newAdaptiveState(ID, plan);
      if (state === null) { throw new Error('Unexpected invalid dash state'); }
      const restored: AdaptiveDownloadState | null = decodeAdaptiveState(encodeAdaptiveState(state), ID);
      if (restored === null) { throw new Error('Unexpected invalid dash round trip'); }
      expect(restored.plan.kind).assertEqual('Dash');
      expect(restored.plan.chunks.length).assertEqual(4);
      expect(restored.parts.length).assertEqual(4);
    });

    it('dash_mime_extension_table_and_miss', 0, (): void => {
      // MimeTypes.cs video/audio 两族 20 项抽查（:28-67）
      expect(dashMimeExtension('video/mp4')).assertEqual('.mp4');
      expect(dashMimeExtension('audio/mp4')).assertEqual('.mp4');
      expect(dashMimeExtension('video/mp2t')).assertEqual('.ts');
      expect(dashMimeExtension('audio/mp2t')).assertEqual('.ts');
      expect(dashMimeExtension('video/x-matroska')).assertEqual('.mkv');
      expect(dashMimeExtension('audio/x-matroska')).assertEqual('.mkv');
      expect(dashMimeExtension('video/webm')).assertEqual('.mkv');
      expect(dashMimeExtension('audio/webm')).assertEqual('.mkv');
      expect(dashMimeExtension('video/x-msvideo')).assertEqual('.avi');
      expect(dashMimeExtension('video/mpeg')).assertEqual('.mpeg');
      expect(dashMimeExtension('audio/mpeg')).assertEqual('.mp3');
      expect(dashMimeExtension('video/unknown')).assertEqual(null);
      expect(dashMimeExtension('')).assertEqual(null);
    });

    it('hls_branch_regression_after_dash_extension', 0, (): void => {
      // Hls 分支既有校验零改动回归（kind/交错/容器强校验/和式恒等）
      const plan: AdaptivePlan = copyPlan(readPlan([SEGMENT]));
      expect(plan.kind).assertEqual('Hls');
      expect(plan.suggestedExtension).assertEqual('.ts');
      expect(newAdaptiveState(ID, plan) === null).assertFalse();
      expect(buildDashPlan(MANIFEST, [INIT_MP4, V1], 'video/mp4', [AUDIO_MP4, A1], 'audio/mp4',
        60000, 60000) === null).assertFalse();
    });
  });
}
