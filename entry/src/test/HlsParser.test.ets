/* U6.4-A pure production HLS parser cases. All URI fixtures are absolute, so the
 * injected resolver is intentionally an identity stub, not a second URL algorithm.
 * Platform URL behavior is covered separately on host and still needs target validation.
 * 37 Hypium cases; registration in List.test.ets belongs to the integration owner. */
import { describe, expect, it } from '@ohos/hypium';
import { HlsAttributes, HlsPlaylist, HlsPlaylistContainer, HlsUrlResolver,
  HLS_MAX_URL_CHARS } from '../main/ets/core/adaptive/HlsModel';
import { parseHlsAttributes, parseHlsMasterPlaylist, parseHlsMediaPlaylist, hlsQuality,
  guessHlsContainer, HLS_MAX_ATTRIBUTES, HLS_MAX_LINE_CHARS,
  HLS_MAX_OUTPUT_CHARS } from '../main/ets/core/adaptive/HlsParser';

const BASE: string = 'https://hls.example/master.m3u8';
const SEGMENT: string = 'https://hls.example/media.mp4';
const NEXT: string = 'https://hls.example/next.mp4';
const INIT: string = 'https://hls.example/init.mp4';
const KEY: string = 'https://hls.example/key';
const FIXTURE_RESOLVER: HlsUrlResolver = (_base: string, reference: string): string => reference;

function manifest(lines: string[]): string { return '#EXTM3U\n' + lines.join('\n'); }

function readMedia(lines: string[]): HlsPlaylist {
  const result: HlsPlaylist | null = parseHlsMediaPlaylist(manifest(lines), BASE, FIXTURE_RESOLVER);
  if (result === null) { throw new Error('Unexpected invalid media fixture'); }
  return result;
}

function readMaster(lines: string[]): HlsPlaylistContainer[] {
  const result: HlsPlaylistContainer[] | null = parseHlsMasterPlaylist(manifest(lines), BASE, FIXTURE_RESOLVER);
  if (result === null) { throw new Error('Unexpected invalid master fixture'); }
  return result;
}

function rejectMedia(lines: string[]): void {
  expect(parseHlsMediaPlaylist(manifest(lines), BASE, FIXTURE_RESOLVER) === null).assertTrue();
}

/** A fixed resolver output for budget tests, deliberately not a URL resolution implementation. */
function longFixtureUrl(characters: number): string {
  const prefix: string = 'https://hls.example/';
  return prefix + 'x'.repeat(characters - prefix.length);
}

export default function hlsParserTest(): void {
  describe('HlsParser', (): void => {
    it('attributes_quotes_equals_duplicates_and_spaces', 0, (): void => {
      const result: HlsAttributes | null = parseHlsAttributes(
        ' CODECS = "avc1,mp4a",URI="s?x=a=b",NAME=" first ",NAME=" last "');
      if (result === null) { throw new Error('Unexpected invalid attributes'); }
      expect(result['CODECS']).assertEqual('avc1,mp4a');
      expect(result['URI']).assertEqual('s?x=a=b');
      expect(result['NAME']).assertEqual('last');
    });

    it('attributes_reject_malformed_and_limit_count', 0, (): void => {
      const invalid: string[] = ['URI="bad', 'URI', ',URI=s', 'URI=s,', '__proto__=x', 'lower=x'];
      for (let i = 0; i < invalid.length; i++) { expect(parseHlsAttributes(invalid[i]) === null).assertTrue(); }
      const pairs: string[] = [];
      for (let i = 0; i < HLS_MAX_ATTRIBUTES; i++) { pairs.push('X' + String(i) + '=v'); }
      expect(parseHlsAttributes(pairs.join(',')) !== null).assertTrue();
      pairs.push('EXTRA=v');
      expect(parseHlsAttributes(pairs.join(',')) === null).assertTrue();
    });

    it('master_single_stream_preserves_metadata', 0, (): void => {
      const result: HlsPlaylistContainer[] = readMaster([
        '#EXT-X-STREAM-INF:BANDWIDTH=2048,RESOLUTION=1280x720', SEGMENT]);
      expect(result.length).assertEqual(1);
      expect(result[0].videoPlaylist).assertEqual(SEGMENT);
      expect(result[0].audioPlaylist === null).assertTrue();
      expect(result[0].attributes['RESOLUTION']).assertEqual('1280x720');
    });

    it('master_all_audio_choices_and_in_band', 0, (): void => {
      const result: HlsPlaylistContainer[] = readMaster([
        '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=g,NAME=English,URI="' + NEXT + '"',
        '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=g,NAME=Muxed',
        '#EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO=g,NAME=stream', SEGMENT]);
      expect(result.length).assertEqual(2);
      expect(result[0].audioPlaylist).assertEqual(NEXT);
      expect(result[1].audioPlaylist === null).assertTrue();
      expect(result[1].videoPlaylist).assertEqual(SEGMENT);
      expect(result[0].attributes['NAME']).assertEqual('English');
    });

    it('master_audio_group_precedes_video', 0, (): void => {
      const result: HlsPlaylistContainer[] = readMaster([
        '#EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID=v,NAME=video,URI="' + INIT + '"',
        '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=a,NAME=audio,URI="' + NEXT + '"',
        '#EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO=a,VIDEO=v', SEGMENT]);
      expect(result.length).assertEqual(1);
      expect(result[0].videoPlaylist).assertEqual(SEGMENT);
      expect(result[0].audioPlaylist).assertEqual(NEXT);
    });

    it('master_video_group_reverses_track_mapping', 0, (): void => {
      const result: HlsPlaylistContainer[] = readMaster([
        '#EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID=v,NAME=video,URI="' + NEXT + '"',
        '#EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID=v,NAME=inband',
        '#EXT-X-STREAM-INF:BANDWIDTH=1,VIDEO=v', SEGMENT]);
      expect(result[0].videoPlaylist).assertEqual(NEXT);
      expect(result[0].audioPlaylist).assertEqual(SEGMENT);
      expect(result[1].videoPlaylist === null).assertTrue();
    });

    it('master_missing_group_does_not_fabricate_track', 0, (): void => {
      expect(parseHlsMasterPlaylist(manifest(['#EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO=missing', SEGMENT]),
        BASE, FIXTURE_RESOLVER) === null).assertTrue();
    });

    it('master_truncated_or_invalid_pair_rejects_whole_list', 0, (): void => {
      const invalid: string[][] = [[SEGMENT], ['#EXT-X-STREAM-INF:BANDWIDTH=1'],
        ['#EXT-X-STREAM-INF:BANDWIDTH=0', SEGMENT], ['#EXT-X-STREAM-INF:BANDWIDTH=1.5', SEGMENT],
        ['#EXT-X-STREAM-INF:BANDWIDTH=1', SEGMENT, '#EXTINF:2,'],
        ['#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=g', '#EXT-X-STREAM-INF:BANDWIDTH=1', SEGMENT]];
      for (let i = 0; i < invalid.length; i++) {
        expect(parseHlsMasterPlaylist(manifest(invalid[i]), BASE, FIXTURE_RESOLVER) === null).assertTrue();
      }
    });

    it('media_signature_bom_crlf_and_empty_rejection', 0, (): void => {
      expect(parseHlsMediaPlaylist('\ufeff\r\n#EXTM3U\r\n' + SEGMENT + '\r\n', BASE,
        FIXTURE_RESOLVER) !== null).assertTrue();
      expect(parseHlsMediaPlaylist(SEGMENT, BASE, FIXTURE_RESOLVER) === null).assertTrue();
      rejectMedia([]);
      rejectMedia(['#EXT-X-MAP:URI="' + INIT + '"']);
    });

    it('media_duration_is_consumed_once_and_live_is_finite_snapshot', 0, (): void => {
      const result: HlsPlaylist = readMedia(['#EXTINF:1.25,title', SEGMENT, NEXT]);
      expect(result.segments[0].duration).assertEqual(1.25);
      expect(result.segments[1].duration).assertEqual(0);
      expect(result.totalDuration).assertEqual(1.25);
      expect(result.endList).assertFalse();
      expect(readMedia([SEGMENT, '#EXT-X-ENDLIST']).endList).assertTrue();
    });

    it('media_map_has_zero_duration_and_does_not_increment_sequence', 0, (): void => {
      const result: HlsPlaylist = readMedia(['#EXT-X-MEDIA-SEQUENCE:9', '#EXTINF:2,',
        '#EXT-X-MAP:URI="' + INIT + '"', SEGMENT, NEXT]);
      expect(result.segments[0].isInit).assertTrue();
      expect(result.segments[0].duration).assertEqual(0);
      expect(result.segments[0].sequence).assertEqual(9);
      expect(result.segments[1].duration).assertEqual(2);
      expect(result.segments[1].sequence).assertEqual(9);
      expect(result.segments[2].sequence).assertEqual(10);
    });

    it('media_range_explicit_zero_and_implicit_previous_endpoint', 0, (): void => {
      const result: HlsPlaylist = readMedia(['#EXT-X-BYTERANGE:10@100', SEGMENT,
        '#EXT-X-BYTERANGE:5', SEGMENT, '#EXT-X-BYTERANGE:3@0', SEGMENT]);
      expect(result.segments[0].byteRange?.offset).assertEqual(100);
      expect(result.segments[1].byteRange?.offset).assertEqual(110);
      expect(result.segments[2].byteRange?.offset).assertEqual(0);
      expect(result.segments[2].byteRange?.length).assertEqual(3);
    });

    it('media_implicit_range_requires_same_resource_predecessor', 0, (): void => {
      rejectMedia(['#EXT-X-BYTERANGE:10', SEGMENT]);
      rejectMedia(['#EXT-X-BYTERANGE:10@0', SEGMENT, '#EXT-X-BYTERANGE:5', NEXT]);
    });

    it('media_whole_file_clears_range_state', 0, (): void => {
      const result: HlsPlaylist = readMedia(['#EXT-X-BYTERANGE:10@0', SEGMENT, SEGMENT]);
      expect(result.segments[1].byteRange === null).assertTrue();
      expect(result.hasByteRange).assertTrue();
      rejectMedia(['#EXT-X-BYTERANGE:10@0', SEGMENT, SEGMENT, '#EXT-X-BYTERANGE:5', SEGMENT]);
    });

    it('map_range_default_zero_is_independent_from_media_range', 0, (): void => {
      const result: HlsPlaylist = readMedia(['#EXT-X-BYTERANGE:10@100', SEGMENT,
        '#EXT-X-MAP:URI="' + INIT + '",BYTERANGE="8"', '#EXT-X-BYTERANGE:5', SEGMENT]);
      expect(result.segments[1].byteRange?.offset).assertEqual(0);
      expect(result.segments[1].byteRange?.length).assertEqual(8);
      expect(result.segments[2].byteRange?.offset).assertEqual(110);
    });

    it('media_rejects_invalid_range_and_endpoint_overflow', 0, (): void => {
      const ranges: string[] = ['0@0', '-1@0', '1@-1', '1@0@1', '1.5@0', '2@9007199254740991'];
      for (let i = 0; i < ranges.length; i++) { rejectMedia(['#EXT-X-BYTERANGE:' + ranges[i], SEGMENT]); }
      const result: HlsPlaylist = readMedia(['#EXT-X-BYTERANGE:1@9007199254740991', SEGMENT]);
      expect(result.segments[0].byteRange?.offset).assertEqual(Number.MAX_SAFE_INTEGER);
    });

    it('media_rejects_invalid_duration_duplicates_and_dangling_state', 0, (): void => {
      const values: string[] = ['-1', 'NaN', 'Infinity', '1e3'];
      for (let i = 0; i < values.length; i++) { rejectMedia(['#EXTINF:' + values[i] + ',', SEGMENT]); }
      rejectMedia([SEGMENT, '#EXTINF:1,']);
      rejectMedia(['#EXTINF:1,', '#EXTINF:2,', SEGMENT]);
      rejectMedia([SEGMENT, '#EXT-X-BYTERANGE:5@0']);
      rejectMedia([SEGMENT, '#EXT-X-I-FRAMES-ONLY:invalid']);
      rejectMedia([SEGMENT, '#EXT-X-DISCONTINUITY:invalid']);
    });

    it('media_sequence_rejects_unsafe_late_duplicate_and_overflow', 0, (): void => {
      rejectMedia(['#EXT-X-MEDIA-SEQUENCE:9007199254740992', SEGMENT]);
      rejectMedia([SEGMENT, '#EXT-X-MEDIA-SEQUENCE:1']);
      rejectMedia(['#EXT-X-MEDIA-SEQUENCE:1', '#EXT-X-MEDIA-SEQUENCE:1', SEGMENT]);
      rejectMedia(['#EXT-X-MEDIA-SEQUENCE:9007199254740991', SEGMENT, NEXT]);
    });

    it('aes_implicit_iv_changes_with_each_media_sequence', 0, (): void => {
      const result: HlsPlaylist = readMedia(['#EXT-X-MEDIA-SEQUENCE:14',
        '#EXT-X-KEY:METHOD=AES-128,URI="' + KEY + '"', SEGMENT, NEXT]);
      expect(result.isEncrypted).assertTrue();
      expect(result.segments[0].keyUrl).assertEqual(KEY);
      expect(result.segments[0].iv).assertEqual('0x0000000000000000000000000000000e');
      expect(result.segments[1].iv).assertEqual('0x0000000000000000000000000000000f');
    });

    it('aes_explicit_iv_normalizes_and_replacement_clears_old_iv', 0, (): void => {
      const result: HlsPlaylist = readMedia(['#EXT-X-KEY:METHOD=AES-128,URI="' + KEY + '",IV=0XA', SEGMENT,
        '#EXT-X-KEY:METHOD=AES-128,URI="' + KEY + '"', NEXT]);
      expect(result.segments[0].iv).assertEqual('0x0000000000000000000000000000000a');
      expect(result.segments[1].iv).assertEqual('0x00000000000000000000000000000001');
    });

    it('key_none_clears_future_segments_but_keeps_encrypted_aggregate', 0, (): void => {
      const result: HlsPlaylist = readMedia(['#EXT-X-KEY:METHOD=AES-128,URI="' + KEY + '"', SEGMENT,
        '#EXT-X-KEY:METHOD=NONE', NEXT]);
      expect(result.segments[1].keyUrl === null).assertTrue();
      expect(result.segments[1].iv === null).assertTrue();
      expect(result.isEncrypted).assertTrue();
    });

    it('unsupported_key_formats_and_bad_iv_reject_entire_playlist', 0, (): void => {
      const attrs: string[] = ['METHOD=SAMPLE-AES,URI="' + KEY + '"',
        'METHOD=AES-128,URI="' + KEY + '",KEYFORMAT="other"', 'METHOD=AES-128',
        'METHOD=AES-128,URI="' + KEY + '",IV=0xG'];
      for (let i = 0; i < attrs.length; i++) { rejectMedia([SEGMENT, '#EXT-X-KEY:' + attrs[i], NEXT]); }
    });

    it('encrypted_map_requires_explicit_iv', 0, (): void => {
      rejectMedia(['#EXT-X-KEY:METHOD=AES-128,URI="' + KEY + '"', '#EXT-X-MAP:URI="' + INIT + '"', SEGMENT]);
      const result: HlsPlaylist = readMedia(['#EXT-X-KEY:METHOD=AES-128,URI="' + KEY + '",IV=0x1',
        '#EXT-X-MAP:URI="' + INIT + '"', SEGMENT]);
      expect(result.segments[0].isInit).assertTrue();
      expect(result.segments[0].iv).assertEqual('0x00000000000000000000000000000001');
    });

    it('iframe_marker_accepts_standard_and_source_forms', 0, (): void => {
      expect(readMedia(['#EXT-X-I-FRAMES-ONLY', SEGMENT]).isKeyIFrameOnly).assertTrue();
      expect(readMedia(['#EXT-X-I-FRAMES-ONLY:', SEGMENT]).isKeyIFrameOnly).assertTrue();
      expect(readMedia([SEGMENT]).isKeyIFrameOnly).assertFalse();
    });

    it('discontinuity_boundary_and_sequence_survive_map', 0, (): void => {
      const result: HlsPlaylist = readMedia(['#EXT-X-DISCONTINUITY-SEQUENCE:3', SEGMENT,
        '#EXT-X-DISCONTINUITY', '#EXT-X-MAP:URI="' + INIT + '"', NEXT]);
      expect(result.segments[0].discontinuitySequence).assertEqual(3);
      expect(result.segments[1].discontinuity).assertTrue();
      expect(result.segments[1].discontinuitySequence).assertEqual(4);
      expect(result.segments[2].discontinuity).assertFalse();
      expect(result.segments[2].discontinuitySequence).assertEqual(4);
    });

    it('discontinuity_sequence_must_precede_media_and_boundaries', 0, (): void => {
      rejectMedia([SEGMENT, '#EXT-X-DISCONTINUITY-SEQUENCE:1']);
      rejectMedia(['#EXT-X-DISCONTINUITY', '#EXT-X-DISCONTINUITY-SEQUENCE:1', SEGMENT]);
      rejectMedia(['#EXT-X-DISCONTINUITY-SEQUENCE:9007199254740991', '#EXT-X-DISCONTINUITY', SEGMENT]);
    });

    it('line_limits_apply_even_to_ignored_comments', 0, (): void => {
      rejectMedia(['#' + 'x'.repeat(HLS_MAX_LINE_CHARS), SEGMENT]);
      expect(readMedia(['#' + 'x'.repeat(HLS_MAX_LINE_CHARS - 1), SEGMENT]).segments.length).assertEqual(1);
    });

    it('resolver_exceptions_reject_whole_manifest', 0, (): void => {
      const broken: HlsUrlResolver = (_base: string, _reference: string): string => {
        throw new Error('Fixture failure');
      };
      expect(parseHlsMediaPlaylist(manifest([SEGMENT]), BASE, broken) === null).assertTrue();
      expect(parseHlsMasterPlaylist(manifest(['#EXT-X-STREAM-INF:BANDWIDTH=1', SEGMENT]), BASE,
        broken) === null).assertTrue();
    });

    it('quality_uses_source_order_integer_bandwidth_and_label_fallback', 0, (): void => {
      const attrs: HlsAttributes = { 'RESOLUTION': '1280x720', 'BANDWIDTH': '2049', 'NAME': 'Main', 'LANGUAGE': 'en' };
      const bad: HlsAttributes = { 'BANDWIDTH': 'NaN', 'LANGUAGE': 'en' };
      expect(hlsQuality(attrs)).assertEqual('1280x720 2 Kbps Main');
      expect(hlsQuality(bad)).assertEqual('en');
      expect(hlsQuality(null) === null).assertTrue();
    });

    it('container_guess_preserves_case_normalization_and_source_extension_rules', 0, (): void => {
      expect(guessHlsContainer('.ts')).assertEqual('.ts');
      expect(guessHlsContainer('.m4s')).assertEqual('.mp4');
      expect(guessHlsContainer('.TS')).assertEqual('.ts');
      expect(guessHlsContainer('.Mp4')).assertEqual('.mp4');
      expect(guessHlsContainer('.m4a', '.mp4')).assertEqual('.mp4');
      expect(guessHlsContainer('.ts', '.m4a')).assertEqual('.mkv');
    });

    it('delta_skip_is_rejected_instead_of_misnumbered_as_full_snapshot', 0, (): void => {
      const tags: string[] = ['#EXT-X-SKIP:SKIPPED-SEGMENTS=3', '#EXT-X-SKIP:SKIPPED-SEGMENTS=0', '#EXT-X-SKIP'];
      for (let i = 0; i < tags.length; i++) {
        rejectMedia(['#EXT-X-MEDIA-SEQUENCE:100', tags[i], SEGMENT, NEXT]);
        expect(parseHlsMasterPlaylist(manifest([tags[i], '#EXT-X-STREAM-INF:BANDWIDTH=1', SEGMENT]),
          BASE, FIXTURE_RESOLVER) === null).assertTrue();
      }
      expect(readMedia(['#EXT-X-SERVER-CONTROL:CAN-SKIP-UNTIL=6', '#EXT-X-MEDIA-SEQUENCE:100',
        SEGMENT]).segments[0].sequence).assertEqual(100);
    });

    it('define_name_import_and_queryparam_are_rejected_even_without_use', 0, (): void => {
      const tags: string[] = ['#EXT-X-DEFINE:NAME="prefix",VALUE="../assets"', '#EXT-X-DEFINE:IMPORT="prefix"',
        '#EXT-X-DEFINE:QUERYPARAM="token"', '#EXT-X-DEFINE'];
      for (let i = 0; i < tags.length; i++) {
        rejectMedia([tags[i], SEGMENT]);
        expect(parseHlsMasterPlaylist(manifest([tags[i], '#EXT-X-STREAM-INF:BANDWIDTH=1', SEGMENT]),
          BASE, FIXTURE_RESOLVER) === null).assertTrue();
      }
      expect(readMedia(['# ordinary comment {$prefix}', SEGMENT]).segments.length).assertEqual(1);
    });

    it('unexpanded_variable_uris_and_attributes_reject_but_encoded_literals_survive', 0, (): void => {
      rejectMedia(['https://hls.example/{$prefix}/s.ts']);
      rejectMedia(['#EXT-X-MAP:URI="https://hls.example/{$prefix}/init.mp4"', SEGMENT]);
      rejectMedia(['#EXT-X-KEY:METHOD=AES-128,URI="https://hls.example/key?sig={$token}"', SEGMENT]);
      expect(parseHlsAttributes('NAME="{$name}"') === null).assertTrue();
      expect(parseHlsMasterPlaylist(manifest(['#EXT-X-STREAM-INF:BANDWIDTH=1',
        'https://hls.example/{$prefix}/v.m3u8']), BASE, FIXTURE_RESOLVER) === null).assertTrue();
      expect(parseHlsMasterPlaylist(manifest(['#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=g,NAME=n,URI="{$prefix}/a.m3u8"',
        '#EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO=g', SEGMENT]), BASE, FIXTURE_RESOLVER) === null).assertTrue();
      const literal: string = 'https://hls.example/%7B$prefix%7D/s.ts?sig=%2F%2B';
      expect(readMedia([literal]).segments[0].url).assertEqual(literal);
    });

    it('media_output_budget_accepts_exact_eight_mi_and_rejects_one_character_over', 0, (): void => {
      expect(HLS_MAX_OUTPUT_CHARS).assertEqual(8 * 1024 * 1024);
      const value: string = longFixtureUrl(16384);
      const fixed: HlsUrlResolver = (_base: string, reference: string): string => {
        if (reference === NEXT) { return value + 'x'; }
        if (reference === INIT) { return value.substring(0, value.length - 1); }
        return value;
      };
      const lines: string[] = [];
      for (let i = 0; i < 512; i++) { lines.push(SEGMENT); }
      expect(parseHlsMediaPlaylist(manifest(lines), BASE, fixed)?.segments.length).assertEqual(512);
      lines[511] = INIT;
      expect(parseHlsMediaPlaylist(manifest(lines), BASE, fixed)?.segments.length).assertEqual(512);
      lines[511] = NEXT;
      expect(parseHlsMediaPlaylist(manifest(lines), BASE, fixed) === null).assertTrue();
    });

    it('media_output_budget_counts_map_shared_key_and_iv_occurrences', 0, (): void => {
      const value: string = longFixtureUrl(HLS_MAX_URL_CHARS);
      const fixed: HlsUrlResolver = (_base: string, _reference: string): string => value;
      const withMap: string[] = ['#EXT-X-MAP:URI="' + INIT + '"'];
      for (let i = 0; i < 255; i++) { withMap.push(SEGMENT); }
      expect(parseHlsMediaPlaylist(manifest(withMap), BASE, fixed)?.segments.length).assertEqual(256);
      withMap.push(SEGMENT);
      expect(parseHlsMediaPlaylist(manifest(withMap), BASE, fixed) === null).assertTrue();
      const encrypted: string[] = ['#EXT-X-KEY:METHOD=AES-128,URI="' + KEY + '",IV=0x1'];
      for (let i = 0; i < 127; i++) { encrypted.push(SEGMENT); }
      expect(parseHlsMediaPlaylist(manifest(encrypted), BASE, fixed)?.segments.length).assertEqual(127);
      encrypted.push(SEGMENT);
      expect(parseHlsMediaPlaylist(manifest(encrypted), BASE, fixed) === null).assertTrue();
    });

    it('master_output_budget_counts_both_tracks_and_expanded_attribute_keys_and_values', 0, (): void => {
      const value: string = longFixtureUrl(HLS_MAX_URL_CHARS);
      const fixed: HlsUrlResolver = (_base: string, _reference: string): string => value;
      const tracks: string[] = [];
      for (let i = 0; i < 127; i++) {
        tracks.push('#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=g,NAME=n' + String(i) + ',URI="' + NEXT + '"');
      }
      const stream: string[] = ['#EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO=g', SEGMENT];
      expect(parseHlsMasterPlaylist(manifest(tracks.concat(stream)), BASE, fixed)?.length).assertEqual(127);
      tracks.push('#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=g,NAME=extra,URI="' + NEXT + '"');
      expect(parseHlsMasterPlaylist(manifest(tracks.concat(stream)), BASE, fixed) === null).assertTrue();
      const expanded: string[] = [];
      const attributes: string = 'K'.repeat(8192) + '=' + 'V'.repeat(8192);
      const largeStream: string[] = ['#EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO=g,' + attributes, SEGMENT];
      for (let i = 0; i < 400; i++) { expanded.push('#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=g,NAME=n' + String(i)); }
      expect(readMaster(expanded.concat(largeStream)).length).assertEqual(400);
      for (let i = 400; i < 512; i++) { expanded.push('#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=g,NAME=n' + String(i)); }
      expect(parseHlsMasterPlaylist(manifest(expanded.concat(largeStream)), BASE, FIXTURE_RESOLVER) === null).assertTrue();
    });

    it('master_unmatched_long_streams_are_bounded_during_collection', 0, (): void => {
      const value: string = longFixtureUrl(HLS_MAX_URL_CHARS);
      let calls: number = 0;
      const fixed: HlsUrlResolver = (_base: string, _reference: string): string => { calls++; return value; };
      const lines: string[] = [];
      for (let i = 0; i < 600; i++) { lines.push('#EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO=missing'); lines.push(SEGMENT); }
      expect(parseHlsMasterPlaylist(manifest(lines), BASE, fixed) === null).assertTrue();
      expect(calls > 1 && calls <= 258).assertTrue();
    });
  });
}
