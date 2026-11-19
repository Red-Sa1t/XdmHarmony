/* Pure production HTTP facts. No transport, filesystem, SDK or device acceptance is implied. */
import { describe, expect, it } from '@ohos/hypium';
import { AdaptiveChunk } from '../main/ets/core/adaptive/AdaptivePlan';
import { AdaptiveRequestWindow, AdaptiveResponseHead, AdaptiveBodyFacts, AdaptiveTransferCheck,
  AdaptiveContentRange, createAdaptiveWindow, parseAdaptiveContentRange, inspectAdaptiveHead,
  inspectAdaptiveTransfer } from '../main/ets/core/adaptive/AdaptiveProtocol';

function windowOf(length: number = 10, offset: number = 90, prefix: number = 0,
  total: number = -1): AdaptiveRequestWindow {
  const chunk: AdaptiveChunk = new AdaptiveChunk();
  chunk.id = 'c0'; chunk.url = 'https://media.example/s.ts'; chunk.length = length; chunk.offset = offset;
  const result: AdaptiveRequestWindow | null = createAdaptiveWindow(chunk, prefix, total);
  if (result === null) { throw new Error('Invalid protocol fixture'); } return result;
}

function response(status: number = 206, range: string = 'bytes 90-99/100',
  length: string = '10'): AdaptiveResponseHead {
  const result: AdaptiveResponseHead = new AdaptiveResponseHead(); result.status = status;
  if (range !== '') { result.contentRange.push(range); }
  if (length !== '') { result.contentLength.push(length); } return result;
}

function body(received: number, written: number = -1, ended: boolean = true): AdaptiveBodyFacts {
  const result: AdaptiveBodyFacts = new AdaptiveBodyFacts();
  result.receivedBytes = received; result.writtenBytes = written === -1 ? received : written;
  result.streamEnded = ended; return result;
}

export default function adaptiveProtocolTest(): void {
  describe('AdaptiveProtocol', (): void => {
    it('range_window_separates_remote_offset_and_local_prefix', 0, (): void => {
      const value: AdaptiveRequestWindow = windowOf(500, 1000, 120);
      expect(value.remoteStart).assertEqual(1120); expect(value.remoteEnd).assertEqual(1499);
      expect(value.prefixBytes).assertEqual(120); expect(windowOf(1, 0).remoteEnd).assertEqual(0);
    });
    it('window_rejects_full_partial_negative_and_unsafe_arithmetic', 0, (): void => {
      const chunk: AdaptiveChunk = new AdaptiveChunk(); chunk.id = 'c0'; chunk.url = 'https://media.example/s.ts';
      chunk.length = 10; chunk.offset = 90;
      const invalid: number[] = [-1, 10, 11, 0.5, Number.NaN, Number.MAX_SAFE_INTEGER + 1];
      for (let i = 0; i < invalid.length; i++) { expect(createAdaptiveWindow(chunk, invalid[i]) === null).assertTrue(); }
      chunk.offset = Number.MAX_SAFE_INTEGER;
      expect(createAdaptiveWindow(chunk, 0) === null).assertTrue();
      chunk.offset = 0; chunk.length = 0; expect(createAdaptiveWindow(chunk, 0) === null).assertTrue();
    });
    it('safe_last_byte_endpoint_does_not_require_unsafe_end_plus_one', 0, (): void => {
      const value: AdaptiveRequestWindow = windowOf(2, Number.MAX_SAFE_INTEGER - 1, 1);
      expect(value.remoteStart).assertEqual(Number.MAX_SAFE_INTEGER);
      expect(value.remoteEnd).assertEqual(Number.MAX_SAFE_INTEGER);
      const head: AdaptiveResponseHead = response(206, 'bytes 9007199254740991-9007199254740991/*', '1');
      expect(inspectAdaptiveTransfer(value, head, body(1)).kind).assertEqual('completeBytes');
    });
    it('whole_window_keeps_open_ended_suffix_and_zero_offset', 0, (): void => {
      const value: AdaptiveRequestWindow = windowOf(-1, 0, 12);
      expect(value.remoteStart).assertEqual(12); expect(value.remoteEnd).assertEqual(-1);
      expect(windowOf(-1, 0).remoteStart).assertEqual(0);
      const chunk: AdaptiveChunk = new AdaptiveChunk(); chunk.id = 'c0'; chunk.url = 'https://media.example/s.ts';
      chunk.offset = 1; expect(createAdaptiveWindow(chunk, 0) === null).assertTrue();
    });
    it('content_range_parses_ows_case_and_decimal_zeroes', 0, (): void => {
      const value: AdaptiveContentRange = parseAdaptiveContentRange(' \tBYTES\t0090-0099/0100\t ');
      expect(value.kind).assertEqual('range'); expect(value.start).assertEqual(90);
      expect(value.end).assertEqual(99); expect(value.total).assertEqual(100);
    });
    it('unknown_total_and_unsatisfied_range_are_distinct_from_invalid', 0, (): void => {
      expect(parseAdaptiveContentRange('bytes 0-9/*').kind).assertEqual('range');
      expect(parseAdaptiveContentRange('bytes 0-9/*').total).assertEqual(-1);
      expect(parseAdaptiveContentRange('bytes */0').kind).assertEqual('unsatisfied');
      expect(parseAdaptiveContentRange('bytes */0').total).assertEqual(0);
      expect(parseAdaptiveContentRange('bytes */*').kind).assertEqual('invalid');
    });
    it('content_range_rejects_garbage_reversed_bounds_and_unsafe_numbers', 0, (): void => {
      const invalid: string[] = ['bytes0-9/10', 'bytes 0-/10', 'bytes -1-9/10', 'bytes 9-0/10',
        'bytes 0-9/9', 'bytes 0-9/0', 'bytes 0-9/1e1', 'bytes +0-9/10', 'bytes 0-9/0x10',
        'bytes 0-9/9007199254740992', 'bytes 0-9007199254740991/*', 'other 0-9/10', 'bytes 0-9/10 junk'];
      for (let i = 0; i < invalid.length; i++) { expect(parseAdaptiveContentRange(invalid[i]).kind).assertEqual('invalid'); }
    });
    it('content_range_rejects_controls_and_bounded_input_excess', 0, (): void => {
      const invalid: string[] = ['bytes 0-9/10\n', 'bytes 0-9/10\r', 'bytes 0-9/10\u0000',
        'bytes 0-9/10\u0085', ' '.repeat(16385)];
      for (let i = 0; i < invalid.length; i++) { expect(parseAdaptiveContentRange(invalid[i]).kind).assertEqual('invalid'); }
    });
    it('known_206_requires_exact_remote_window_and_local_write_base', 0, (): void => {
      const value: AdaptiveRequestWindow = windowOf(10, 90, 4);
      const head: AdaptiveResponseHead = response(206, 'bytes 94-99/100', '6');
      expect(inspectAdaptiveHead(value, head).kind).assertEqual('accept');
      expect(inspectAdaptiveHead(value, head).writeBase).assertEqual(4);
      expect(inspectAdaptiveHead(value, head).expectedBytes).assertEqual(6);
    });
    it('known_206_rejects_wrong_start_end_total_and_body_length', 0, (): void => {
      const value: AdaptiveRequestWindow = windowOf(10, 90, 4, 100);
      const ranges: string[] = ['bytes 93-99/100', 'bytes 94-98/100', 'bytes 94-99/101', 'bytes 94-99/*'];
      for (let i = 0; i < ranges.length; i++) { expect(inspectAdaptiveHead(value, response(206, ranges[i], '')).kind).assertEqual('reject'); }
      expect(inspectAdaptiveHead(value, response(206, 'bytes 94-99/100', '100')).code).assertEqual('LengthMismatch');
    });
    it('known_window_never_accepts_200_even_from_offset_zero', 0, (): void => {
      expect(inspectAdaptiveHead(windowOf(10, 0), response(200, '', '10')).code).assertEqual('RangeNotHonored');
    });
    it('whole_200_uses_a_new_zero_based_candidate_and_new_length', 0, (): void => {
      const value: AdaptiveRequestWindow = windowOf(-1, 0, 12, 20);
      const result: AdaptiveTransferCheck = inspectAdaptiveTransfer(value, response(200, '', '3'), body(3));
      expect(result.kind).assertEqual('completeBytes'); expect(result.resetPrefix).assertTrue();
      expect(result.writeBase).assertEqual(0); expect(result.prefixLimit).assertEqual(3);
      expect(value.prefixBytes).assertEqual(12);
      expect(inspectAdaptiveHead(value, response(200, 'bytes 0-2/3', '3')).kind).assertEqual('reject');
    });
    it('whole_206_tail_proves_extent_and_appends_only_the_suffix', 0, (): void => {
      const result: AdaptiveTransferCheck = inspectAdaptiveTransfer(windowOf(-1, 0, 4),
        response(206, 'bytes 4-9/10', '6'), body(6));
      expect(result.kind).assertEqual('completeBytes'); expect(result.prefixLimit).assertEqual(10);
      expect(result.writeBase).assertEqual(4); expect(result.resetPrefix).assertFalse();
    });
    it('whole_206_nonterminal_and_unknown_total_never_complete_at_eos', 0, (): void => {
      const ranges: string[] = ['bytes 4-9/20', 'bytes 4-9/*'];
      for (let i = 0; i < ranges.length; i++) {
        const result: AdaptiveTransferCheck = inspectAdaptiveTransfer(windowOf(-1, 0, 4), response(206, ranges[i], '6'), body(6));
        expect(result.kind).assertEqual('partialBytes'); expect(result.code).assertEqual('WholeExtentUnproven');
        expect(result.prefixLimit).assertEqual(10);
      }
    });
    it('known_resource_total_does_not_allow_star_to_bypass_length_conflict', 0, (): void => {
      const value: AdaptiveRequestWindow = windowOf(-1, 0, 4, 10);
      expect(inspectAdaptiveHead(value, response(206, 'bytes 4-9/*', '6')).kind).assertEqual('reject');
      expect(inspectAdaptiveHead(value, response(206, 'bytes 4-9/20', '6')).kind).assertEqual('reject');
      expect(inspectAdaptiveHead(value, response(206, 'bytes 4-9/10', '6')).kind).assertEqual('accept');
    });
    it('content_length_distinguishes_absent_zero_and_equal_duplicates', 0, (): void => {
      const value: AdaptiveRequestWindow = windowOf(-1, 0);
      const head: AdaptiveResponseHead = response(200, '', '');
      expect(inspectAdaptiveHead(value, head).expectedBytes).assertEqual(-1);
      head.contentLength = ['00', '0']; expect(inspectAdaptiveHead(value, head).expectedBytes).assertEqual(0);
      expect(inspectAdaptiveTransfer(value, head, body(0)).kind).assertEqual('completeBytes');
      head.contentLength = ['0010', '10']; expect(inspectAdaptiveHead(value, head).expectedBytes).assertEqual(10);
    });
    it('content_length_rejects_conflicting_and_nondecimal_values', 0, (): void => {
      const head: AdaptiveResponseHead = response(200, '', '');
      const invalid: string[] = ['', '-1', '+1', '1e1', '1.0', '0x10', 'Infinity', 'NaN', '10,10', '9007199254740992'];
      for (let i = 0; i < invalid.length; i++) {
        head.contentLength = [invalid[i]]; expect(inspectAdaptiveHead(windowOf(-1, 0), head).kind).assertEqual('reject');
      }
      head.contentLength = ['10', '11']; expect(inspectAdaptiveHead(windowOf(-1, 0), head).kind).assertEqual('reject');
    });
    it('duplicate_or_unsatisfied_content_range_cannot_be_success', 0, (): void => {
      const head: AdaptiveResponseHead = response(); head.contentRange.push('bytes 90-99/100');
      expect(inspectAdaptiveHead(windowOf(), head).kind).assertEqual('reject');
      head.contentRange = ['bytes */100']; expect(inspectAdaptiveHead(windowOf(), head).kind).assertEqual('reject');
    });
    it('only_missing_or_single_identity_content_encoding_is_accepted', 0, (): void => {
      const head: AdaptiveResponseHead = response();
      expect(inspectAdaptiveHead(windowOf(), head).kind).assertEqual('accept');
      head.contentEncoding = [' IDENTITY\t']; expect(inspectAdaptiveHead(windowOf(), head).kind).assertEqual('accept');
      const invalid: string[] = ['gzip', 'deflate', 'br', '', 'identity,gzip'];
      for (let i = 0; i < invalid.length; i++) {
        head.contentEncoding = [invalid[i]]; expect(inspectAdaptiveHead(windowOf(), head).kind).assertEqual('reject');
      }
      head.contentEncoding = ['identity', 'identity']; expect(inspectAdaptiveHead(windowOf(), head).kind).assertEqual('reject');
    });
    it('chunked_requires_unambiguous_framing_without_content_length', 0, (): void => {
      const head: AdaptiveResponseHead = response(200, '', ''); head.transferEncoding = [' chunked '];
      expect(inspectAdaptiveHead(windowOf(-1, 0), head).kind).assertEqual('accept');
      head.contentLength = ['10']; expect(inspectAdaptiveHead(windowOf(-1, 0), head).code).assertEqual('InvalidFraming');
      head.contentLength = []; head.transferEncoding = ['gzip, chunked'];
      expect(inspectAdaptiveHead(windowOf(-1, 0), head).kind).assertEqual('reject');
      head.transferEncoding = ['chunked', 'chunked']; expect(inspectAdaptiveHead(windowOf(-1, 0), head).kind).assertEqual('reject');
    });
    it('critical_header_counts_characters_and_scalar_types_are_bounded', 0, (): void => {
      const head: AdaptiveResponseHead = response(); head.contentLength = [];
      for (let i = 0; i < 9; i++) { head.contentLength.push('10'); }
      expect(inspectAdaptiveHead(windowOf(), head).code).assertEqual('InvalidHead');
      head.contentLength = ['0'.repeat(16385)]; expect(inspectAdaptiveHead(windowOf(), head).code).assertEqual('InvalidHead');
      const raw: Object = JSON.parse(JSON.stringify(response()).replace('"contentLength":["10"]', '"contentLength":[10]'));
      expect(inspectAdaptiveHead(windowOf(), raw as AdaptiveResponseHead).code).assertEqual('InvalidHead');
    });
    it('http_error_states_never_accept_their_bodies_as_chunks', 0, (): void => {
      // Source HttpChunkDownloader retries every HTTP error status within MaxRetry (EnsureSuccessStatusCode).
      const retryable: number[] = [0, 401, 403, 404, 408, 416, 429, 500, 502, 503, 504];
      for (let i = 0; i < retryable.length; i++) {
        const result: AdaptiveTransferCheck = inspectAdaptiveTransfer(windowOf(), response(retryable[i], '', ''), body(10));
        expect(result.kind).assertEqual('retryable'); expect(result.allowNewPrefix).assertFalse();
      }
      const rejected: number[] = [201, 204, 301, 302, 304];
      for (let i = 0; i < rejected.length; i++) {
        expect(inspectAdaptiveTransfer(windowOf(), response(rejected[i], '', ''), body(10)).kind).assertEqual('reject');
      }
    });
    it('exact_range_body_with_real_eos_has_only_byte_completion_eligibility', 0, (): void => {
      const result: AdaptiveTransferCheck = inspectAdaptiveTransfer(windowOf(), response(), body(10));
      expect(result.kind).assertEqual('completeBytes'); expect(result.prefixLimit).assertEqual(10);
      expect(result.allowNewPrefix).assertTrue();
    });
    it('short_body_or_missing_eos_retains_only_strict_known_prefix', 0, (): void => {
      expect(inspectAdaptiveTransfer(windowOf(), response(), body(9)).kind).assertEqual('partialBytes');
      const result: AdaptiveTransferCheck = inspectAdaptiveTransfer(windowOf(), response(), body(10, 10, false));
      expect(result.kind).assertEqual('partialBytes'); expect(result.prefixLimit).assertEqual(9);
      const one: AdaptiveTransferCheck = inspectAdaptiveTransfer(windowOf(1, 90), response(206, 'bytes 90-90/91', '1'), body(1, 1, false));
      expect(one.prefixLimit).assertEqual(0); expect(one.kind).assertEqual('partialBytes');
    });
    it('overlong_received_body_rejects_even_when_written_bytes_were_capped', 0, (): void => {
      const result: AdaptiveTransferCheck = inspectAdaptiveTransfer(windowOf(10, 90, 4),
        response(206, 'bytes 94-99/100', '6'), body(7, 6));
      expect(result.code).assertEqual('BodyTooLong'); expect(result.kind).assertEqual('reject');
      expect(result.allowNewPrefix).assertFalse(); expect(result.prefixLimit).assertEqual(4);
    });
    it('pending_and_short_writes_cannot_claim_complete', 0, (): void => {
      const value: AdaptiveBodyFacts = body(10); value.writesPending = true;
      expect(inspectAdaptiveTransfer(windowOf(), response(), value).kind).assertEqual('pending');
      value.writesPending = false; value.writtenBytes = 7;
      const result: AdaptiveTransferCheck = inspectAdaptiveTransfer(windowOf(), response(), value);
      expect(result.kind).assertEqual('partialBytes'); expect(result.prefixLimit).assertEqual(7);
    });
    it('disk_failure_is_fatal_and_never_upgrades_a_full_file', 0, (): void => {
      const value: AdaptiveBodyFacts = body(10); value.diskErrorCode = 1;
      const result: AdaptiveTransferCheck = inspectAdaptiveTransfer(windowOf(), response(), value);
      expect(result.kind).assertEqual('reject'); expect(result.code).assertEqual('DiskFailure');
      expect(result.prefixLimit).assertEqual(9);
      value.writesPending = true; expect(inspectAdaptiveTransfer(windowOf(), response(), value).kind).assertEqual('pending');
    });
    it('late_transport_failure_after_valid_headers_prevents_completion', 0, (): void => {
      const head: AdaptiveResponseHead = response(); head.transportErrorCode = 1;
      const result: AdaptiveTransferCheck = inspectAdaptiveTransfer(windowOf(), head, body(10));
      expect(result.kind).assertEqual('retryable'); expect(result.code).assertEqual('TransportFailure');
      expect(result.prefixLimit).assertEqual(9);
    });
    it('controlled_stop_without_headers_keeps_only_the_saved_prefix', 0, (): void => {
      const value: AdaptiveBodyFacts = body(4, 4, false); value.stopRequested = true;
      const result: AdaptiveTransferCheck = inspectAdaptiveTransfer(windowOf(10, 90, 4), response(0, '', ''), value);
      expect(result.code).assertEqual('Stopped'); expect(result.kind).assertEqual('partialBytes');
      expect(result.allowNewPrefix).assertFalse(); expect(result.prefixLimit).assertEqual(4);
    });
    it('whole_200_partial_reset_never_adds_the_old_prefix_length', 0, (): void => {
      const result: AdaptiveTransferCheck = inspectAdaptiveTransfer(windowOf(-1, 0, 12), response(200, '', '20'), body(3));
      expect(result.kind).assertEqual('partialBytes'); expect(result.prefixLimit).assertEqual(3);
      expect(result.resetPrefix).assertTrue();
    });
    it('unknown_content_length_completes_only_on_real_eos_including_empty', 0, (): void => {
      expect(inspectAdaptiveTransfer(windowOf(-1, 0), response(200, '', ''), body(15)).kind).assertEqual('completeBytes');
      expect(inspectAdaptiveTransfer(windowOf(-1, 0), response(200, '', ''), body(0)).kind).assertEqual('completeBytes');
      expect(inspectAdaptiveTransfer(windowOf(-1, 0), response(200, '', ''), body(15, 15, false)).kind).assertEqual('partialBytes');
    });
    it('body_counts_reject_negative_fractional_unsafe_and_written_over_received', 0, (): void => {
      const invalid: number[] = [-1, 0.5, Number.NaN, Number.POSITIVE_INFINITY, Number.MAX_SAFE_INTEGER + 1];
      for (let i = 0; i < invalid.length; i++) {
        const value: AdaptiveBodyFacts = body(0); value.receivedBytes = invalid[i];
        expect(inspectAdaptiveTransfer(windowOf(), response(), value).code).assertEqual('InvalidBody');
      }
      expect(inspectAdaptiveTransfer(windowOf(), response(), body(2, 3)).code).assertEqual('InvalidBody');
      expect(inspectAdaptiveTransfer(windowOf(-1, 0, Number.MAX_SAFE_INTEGER),
        response(206, 'bytes 9007199254740991-9007199254740991/*', '1'), body(1)).code).assertEqual('InvalidBody');
    });
    it('final_transfer_rechecks_headers_instead_of_trusting_an_earlier_accept', 0, (): void => {
      const head: AdaptiveResponseHead = response(); expect(inspectAdaptiveHead(windowOf(), head).kind).assertEqual('accept');
      head.contentRange = ['bytes 0-9/100'];
      expect(inspectAdaptiveTransfer(windowOf(), head, body(10)).kind).assertEqual('reject');
    });
    it('pause_intent_does_not_erase_already_proven_normal_eos', 0, (): void => {
      const value: AdaptiveBodyFacts = body(10); value.stopRequested = true;
      expect(inspectAdaptiveTransfer(windowOf(), response(), value).kind).assertEqual('completeBytes');
      value.diskErrorCode = 1;
      expect(inspectAdaptiveTransfer(windowOf(), response(), value).code).assertEqual('DiskFailure');
    });
  });
}
