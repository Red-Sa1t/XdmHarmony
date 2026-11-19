/* Pure production scheduling. A test receipt represents already closed/sealed resources, not real IO. */
import { describe, expect, it } from '@ohos/hypium';
import { HlsPlaylist, HlsUrlResolver } from '../main/ets/core/adaptive/HlsModel';
import { parseHlsMediaPlaylist } from '../main/ets/core/adaptive/HlsParser';
import { AdaptivePlan, AdaptiveDownloadState, AdaptivePartState, buildHlsPlan,
  partitionAdaptiveChunks } from '../main/ets/core/adaptive/AdaptivePlan';
import { newAdaptiveState, encodeAdaptiveState, decodeAdaptiveState } from '../main/ets/core/adaptive/AdaptiveStateCodec';
import { AdaptiveSchedulerLimits, AdaptiveAttemptIdentity, AdaptiveDispatch, AdaptiveSettlement,
  AdaptiveScheduler, AdaptiveQuiesced, createAdaptiveScheduler } from '../main/ets/core/adaptive/AdaptiveScheduler';

const ID: string = '01234567-89ab-cdef-0123-456789abcdef';
const PRIMARY: string = 'https://media.example/video.m3u8';
const SECONDARY: string = 'https://media.example/audio.m3u8';
const RESOLVE: HlsUrlResolver = (_base: string, reference: string): string => reference;

function media(lines: string[], url: string = PRIMARY): HlsPlaylist {
  const result: HlsPlaylist | null = parseHlsMediaPlaylist('#EXTM3U\n' + lines.join('\n'), url, RESOLVE);
  if (result === null) { throw new Error('Invalid scheduler media fixture'); } return result;
}

function stateFromPlan(plan: AdaptivePlan | null): AdaptiveDownloadState {
  if (plan === null) { throw new Error('Invalid scheduler plan fixture'); }
  const result: AdaptiveDownloadState | null = newAdaptiveState(ID, plan);
  if (result === null) { throw new Error('Invalid scheduler state fixture'); } return result;
}

function freshState(count: number = 2, known: boolean = true): AdaptiveDownloadState {
  const lines: string[] = [];
  for (let i = 0; i < count; i++) {
    if (known) { lines.push('#EXT-X-BYTERANGE:10@90'); }
    lines.push('https://media.example/s' + String(i) + '.ts');
  }
  return stateFromPlan(buildHlsPlan(PRIMARY, media(lines)));
}

function saved(part: AdaptivePartState, bytes: number, complete: boolean = false): void {
  part.downloaded = bytes; part.complete = complete; part.fileName = 'saved_' + part.chunkId + '.part';
}

function limits(segments: number = 2, retries: number = 1, delay: number = 10): AdaptiveSchedulerLimits {
  const result: AdaptiveSchedulerLimits = new AdaptiveSchedulerLimits();
  result.maxSegments = segments; result.maxRetry = retries; result.retryDelayMs = delay; return result;
}

function run(state: AdaptiveDownloadState = freshState(), segments: number = 2,
  retries: number = 1, delay: number = 10): AdaptiveScheduler {
  const result: AdaptiveScheduler | null = createAdaptiveScheduler('runA', state, limits(segments, retries, delay));
  if (result === null) { throw new Error('Invalid scheduler fixture'); } return result;
}

function identity(source: AdaptiveAttemptIdentity): AdaptiveAttemptIdentity {
  const result: AdaptiveAttemptIdentity = new AdaptiveAttemptIdentity();
  result.downloadId = source.downloadId; result.runToken = source.runToken; result.laneId = source.laneId;
  result.chunkId = source.chunkId; result.attemptId = source.attemptId; return result;
}

function receipt(dispatch: AdaptiveDispatch, outcome: string = 'complete', bytes: number = 10): AdaptiveSettlement {
  const result: AdaptiveSettlement = new AdaptiveSettlement(); result.identity = identity(dispatch.identity);
  result.outcome = outcome;
  result.errorCode = outcome === 'retryable' ? 'TransportFailure' : (outcome === 'fatal' ? 'DiskFailure' : '');
  if (bytes >= 0) {
    const part: AdaptivePartState = new AdaptivePartState(); part.chunkId = dispatch.identity.chunkId;
    part.downloaded = bytes; part.complete = outcome === 'complete'; part.fileName = dispatch.candidateFileName;
    result.sealedPart = part;
  }
  return result;
}

function quiesced(scheduler: AdaptiveScheduler): AdaptiveQuiesced {
  const result: AdaptiveQuiesced | null = scheduler.takeQuiesced();
  if (result === null) { throw new Error('Scheduler has not quiesced'); } return result;
}

function expectError(action: () => void, code: string): void {
  let actual: string = '';
  try { action(); } catch (e) { if (e instanceof Error) { actual = e.message; } }
  expect(actual).assertEqual(code);
}

function expectCodecAccepts(state: AdaptiveDownloadState, scheduler: AdaptiveScheduler): void {
  state.parts = scheduler.snapshotParts();
  expect(decodeAdaptiveState(encodeAdaptiveState(state), ID) !== null).assertTrue();
}

export default function adaptiveSchedulerTest(): void {
  describe('AdaptiveScheduler', (): void => {
    it('actual_B_partition_may_return_fewer_lanes_than_the_requested_cap', 0, (): void => {
      const state: AdaptiveDownloadState = freshState(5);
      expect(partitionAdaptiveChunks(state.parts, 4).length).assertEqual(3);
      const scheduler: AdaptiveScheduler = run(state, 4); const first: AdaptiveDispatch[] = scheduler.claim(0, 4);
      expect(first.length).assertEqual(3); expect(first[0].chunk.id).assertEqual('c0');
      expect(first[1].chunk.id).assertEqual('c2'); expect(first[2].chunk.id).assertEqual('c4');
      scheduler.settle(receipt(first[0]), 0); scheduler.settle(receipt(first[1]), 0);
      const next: AdaptiveDispatch[] = scheduler.claim(0, 4);
      expect(next.length).assertEqual(2); expect(next[0].chunk.id).assertEqual('c1'); expect(next[1].chunk.id).assertEqual('c3');
    });
    it('finished_items_are_skipped_without_changing_source_lane_order', 0, (): void => {
      const state: AdaptiveDownloadState = freshState(7);
      saved(state.parts[0], 10, true); saved(state.parts[2], 10, true);
      saved(state.parts[4], 10, true); saved(state.parts[6], 10, true);
      const scheduler: AdaptiveScheduler = run(state); const first: AdaptiveDispatch[] = scheduler.claim(0, 2);
      expect(first[0].chunk.id).assertEqual('c1'); expect(first[1].chunk.id).assertEqual('c5');
      scheduler.settle(receipt(first[0]), 0);
      expect(scheduler.claim(0, 1)[0].chunk.id).assertEqual('c3');
    });
    it('zero_duration_MAP_and_two_track_entries_are_claimed_in_plan_order', 0, (): void => {
      const plan: AdaptivePlan | null = buildHlsPlan(PRIMARY,
        media(['#EXT-X-MAP:URI="https://media.example/init.mp4"', 'https://media.example/v.ts']),
        SECONDARY, media(['https://media.example/a.m4a'], SECONDARY));
      const state: AdaptiveDownloadState = stateFromPlan(plan); const scheduler: AdaptiveScheduler = run(state, 1);
      const first: AdaptiveDispatch = scheduler.claim(0, 1)[0];
      expect(first.chunk.isInit).assertTrue(); expect(first.chunk.duration).assertEqual(0);
      scheduler.settle(receipt(first, 'complete', 1), 0);
      const second: AdaptiveDispatch = scheduler.claim(0, 1)[0]; expect(second.chunk.trackIndex).assertEqual(1);
      scheduler.settle(receipt(second, 'complete', 1), 0);
      expect(scheduler.claim(0, 1)[0].chunk.id).assertEqual('c2');
    });
    it('initially_complete_state_emits_one_assembly_intent_without_dispatch', 0, (): void => {
      const state: AdaptiveDownloadState = freshState(1); saved(state.parts[0], 10, true); state.generation = 7;
      const scheduler: AdaptiveScheduler = run(state);
      expect(scheduler.claim(0, 2).length).assertEqual(0);
      const result: AdaptiveQuiesced = quiesced(scheduler);
      expect(result.reason).assertEqual('allPartsVerified'); expect(result.readyForAssembly).assertTrue();
      expect(result.candidatesChanged).assertFalse(); expect(state.generation).assertEqual(7);
      expect(scheduler.takeQuiesced() === null).assertTrue();
    });
    it('creation_rejects_invalid_state_limits_and_unbounded_run_tokens', 0, (): void => {
      const badTokens: string[] = ['', '../run', 'run\n', 'run space', 'r'.repeat(65)];
      for (let i = 0; i < badTokens.length; i++) {
        expect(createAdaptiveScheduler(badTokens[i], freshState(), limits()) === null).assertTrue();
      }
      expect(createAdaptiveScheduler('run', freshState(), limits(0)) === null).assertTrue();
      expect(createAdaptiveScheduler('run', freshState(), limits(2, -1)) === null).assertTrue();
      expect(createAdaptiveScheduler('run', freshState(), limits(2, Number.MAX_SAFE_INTEGER)) === null).assertTrue();
      expect(createAdaptiveScheduler('run', freshState(), limits(2, 1, 0.5)) === null).assertTrue();
      const state: AdaptiveDownloadState = freshState(); saved(state.parts[0], 10, false);
      expect(createAdaptiveScheduler('run', state, limits()) === null).assertTrue();
    });
    it('B_caps_concurrency_at_64_and_available_slots_limit_only_new_claims', 0, (): void => {
      const scheduler: AdaptiveScheduler = run(freshState(64), 100);
      expect(scheduler.claim(0, 1).length).assertEqual(1);
      expect(scheduler.claim(0, 100).length).assertEqual(63);
      expect(scheduler.claim(0, 100).length).assertEqual(0);
    });
    it('claim_registers_ownership_before_return_and_zero_slots_do_not_dispatch', 0, (): void => {
      const scheduler: AdaptiveScheduler = run(); expect(scheduler.claim(0, 0).length).assertEqual(0);
      const dispatch: AdaptiveDispatch = scheduler.claim(0, 1)[0];
      expect(scheduler.isCurrentAttempt(dispatch.identity)).assertTrue();
      expect(scheduler.mayReportProgress(dispatch.identity)).assertTrue();
      expect(dispatch.identity.attemptId).assertEqual(1);
    });
    it('settlement_atomically_adopts_the_candidate_and_releases_only_its_owner', 0, (): void => {
      const scheduler: AdaptiveScheduler = run(freshState(1), 1); const dispatch: AdaptiveDispatch = scheduler.claim(0, 1)[0];
      const report: AdaptiveSettlement = receipt(dispatch, 'retryable', 4);
      expect(scheduler.settle(report, 0).candidateAccepted).assertTrue();
      expect(scheduler.isCurrentAttempt(dispatch.identity)).assertFalse();
      expect(scheduler.snapshotParts()[0].downloaded).assertEqual(4);
      expect(scheduler.nextRetryAt()).assertEqual(10);
      const next: AdaptiveDispatch = scheduler.claim(10, 1)[0];
      expect(next.prefix.downloaded).assertEqual(4); expect(next.prefix.fileName).assertEqual(dispatch.candidateFileName);
      expect(next.identity.attemptId).assertEqual(2);
    });
    it('retry_budget_is_initial_attempt_plus_maxRetry_without_partial_progress_reset', 0, (): void => {
      const budgets: number[] = [0, 1, 10];
      for (let j = 0; j < budgets.length; j++) {
        const scheduler: AdaptiveScheduler = run(freshState(1), 1, budgets[j], 0);
        for (let i = 0; i <= budgets[j]; i++) {
          const dispatch: AdaptiveDispatch = scheduler.claim(i, 1)[0];
          expect(scheduler.mayReportProgress(dispatch.identity)).assertTrue();
          scheduler.settle(receipt(dispatch, 'retryable', 1), i);
        }
        const result: AdaptiveQuiesced = quiesced(scheduler);
        expect(result.reason).assertEqual('fatal'); expect(result.failureCode).assertEqual('RetryBudgetExhausted');
        expect(result.retryFailures).assertEqual(budgets[j] + 1); expect(scheduler.claim(100, 1).length).assertEqual(0);
      }
    });
    it('recovered_retries_allow_assembly_and_each_new_chunk_has_its_own_budget', 0, (): void => {
      const scheduler: AdaptiveScheduler = run(freshState(2), 1, 1, 0);
      for (let i = 0; i < 2; i++) {
        const first: AdaptiveDispatch = scheduler.claim(0, 1)[0];
        scheduler.settle(receipt(first, 'retryable', 4), 0);
        const second: AdaptiveDispatch = scheduler.claim(0, 1)[0]; scheduler.settle(receipt(second), 0);
      }
      const result: AdaptiveQuiesced = quiesced(scheduler);
      expect(result.readyForAssembly).assertTrue(); expect(result.failureCount).assertEqual(0);
      expect(result.retryFailures).assertEqual(2); expect(result.completedParts).assertEqual(2);
    });
    it('retry_deadlines_require_explicit_time_and_repeated_wakes_do_not_duplicate_claims', 0, (): void => {
      const scheduler: AdaptiveScheduler = run(freshState(1), 1);
      const first: AdaptiveDispatch = scheduler.claim(100, 1)[0]; scheduler.settle(receipt(first, 'retryable', 4), 100);
      expect(scheduler.nextRetryAt()).assertEqual(110); expect(scheduler.claim(109, 1).length).assertEqual(0);
      expect(scheduler.claim(110, 1).length).assertEqual(1); expect(scheduler.claim(110, 1).length).assertEqual(0);
    });
    it('one_waiting_lane_does_not_block_siblings_or_claim_false_quiescence', 0, (): void => {
      const scheduler: AdaptiveScheduler = run(); const first: AdaptiveDispatch[] = scheduler.claim(0, 2);
      scheduler.settle(receipt(first[0], 'retryable', 4), 0); scheduler.settle(receipt(first[1]), 0);
      expect(scheduler.takeQuiesced() === null).assertTrue(); expect(scheduler.claim(9, 2).length).assertEqual(0);
      expect(scheduler.claim(10, 2)[0].chunk.id).assertEqual('c0');
    });
    it('pause_captures_claimed_but_not_started_owners_until_explicit_stopped_receipts', 0, (): void => {
      const scheduler: AdaptiveScheduler = run(); const first: AdaptiveDispatch[] = scheduler.claim(0, 2);
      expect(scheduler.requestPause().length).assertEqual(2); expect(scheduler.requestPause().length).assertEqual(0);
      expect(scheduler.isCurrentAttempt(first[0].identity)).assertTrue(); expect(scheduler.mayReportProgress(first[0].identity)).assertFalse();
      expect(scheduler.takeQuiesced() === null).assertTrue(); expect(scheduler.claim(1, 2).length).assertEqual(0);
      scheduler.settle(receipt(first[0], 'stopped', -1), 1); expect(scheduler.takeQuiesced() === null).assertTrue();
      scheduler.settle(receipt(first[1], 'stopped', -1), 1);
      expect(quiesced(scheduler).reason).assertEqual('pauseRequested'); expect(scheduler.takeQuiesced() === null).assertTrue();
    });
    it('pause_before_last_complete_preserves_pause_intent_and_the_completed_candidate', 0, (): void => {
      const state: AdaptiveDownloadState = freshState(1); const scheduler: AdaptiveScheduler = run(state);
      const dispatch: AdaptiveDispatch = scheduler.claim(0, 1)[0]; scheduler.requestPause();
      scheduler.settle(receipt(dispatch), 0); const result: AdaptiveQuiesced = quiesced(scheduler);
      expect(result.reason).assertEqual('pauseRequested'); expect(result.completedParts).assertEqual(1);
      expect(result.readyForAssembly).assertFalse(); expect(scheduler.snapshotParts()[0].complete).assertTrue();
      expectCodecAccepts(state, scheduler);
    });
    it('last_complete_before_pause_emits_only_one_assembly_intent', 0, (): void => {
      const scheduler: AdaptiveScheduler = run(freshState(1)); const dispatch: AdaptiveDispatch = scheduler.claim(0, 1)[0];
      scheduler.settle(receipt(dispatch), 0); expect(scheduler.requestPause().length).assertEqual(0);
      expect(quiesced(scheduler).reason).assertEqual('allPartsVerified'); expect(scheduler.takeQuiesced() === null).assertTrue();
    });
    it('fatal_stops_siblings_and_later_success_cannot_erase_the_fault', 0, (): void => {
      const state: AdaptiveDownloadState = freshState(); const scheduler: AdaptiveScheduler = run(state);
      const first: AdaptiveDispatch[] = scheduler.claim(0, 2);
      expect(scheduler.settle(receipt(first[0], 'fatal', 4), 0).stopAttempts.length).assertEqual(1);
      expect(scheduler.takeQuiesced() === null).assertTrue(); scheduler.settle(receipt(first[1]), 0);
      const result: AdaptiveQuiesced = quiesced(scheduler);
      expect(result.reason).assertEqual('fatal'); expect(result.failureCode).assertEqual('DiskFailure');
      expect(result.downloadedBytes).assertEqual(14); expect(result.completedParts).assertEqual(1);
      expect(result.readyForAssembly).assertFalse(); expectCodecAccepts(state, scheduler);
    });
    it('pause_then_sealing_failure_keeps_pause_reason_and_records_the_real_error', 0, (): void => {
      const scheduler: AdaptiveScheduler = run(freshState(1)); const dispatch: AdaptiveDispatch = scheduler.claim(0, 1)[0];
      scheduler.requestPause(); scheduler.settle(receipt(dispatch, 'fatal', -1), 0);
      const result: AdaptiveQuiesced = quiesced(scheduler);
      expect(result.reason).assertEqual('pauseRequested'); expect(result.failureCode).assertEqual('DiskFailure');
      expect(result.failureCount).assertEqual(1);
    });
    it('pause_discards_waiting_retry_eligibility_and_late_timers_cannot_restart', 0, (): void => {
      const scheduler: AdaptiveScheduler = run(freshState(1)); const dispatch: AdaptiveDispatch = scheduler.claim(0, 1)[0];
      scheduler.settle(receipt(dispatch, 'retryable', 4), 0); expect(scheduler.requestPause().length).assertEqual(0);
      expect(scheduler.nextRetryAt()).assertEqual(-1); expect(scheduler.claim(10, 1).length).assertEqual(0);
      expect(quiesced(scheduler).reason).assertEqual('pauseRequested');
    });
    it('old_attempt_and_duplicate_receipts_cannot_release_or_overwrite_the_new_owner', 0, (): void => {
      const scheduler: AdaptiveScheduler = run(freshState(1), 1, 1, 0);
      const first: AdaptiveDispatch = scheduler.claim(0, 1)[0]; scheduler.settle(receipt(first, 'retryable', 4), 0);
      const second: AdaptiveDispatch = scheduler.claim(0, 1)[0];
      expect(scheduler.settle(receipt(first), Number.NaN).accepted).assertFalse();
      expect(scheduler.isCurrentAttempt(second.identity)).assertTrue(); expect(scheduler.snapshotParts()[0].downloaded).assertEqual(4);
      scheduler.settle(receipt(second), 0);
      expect(scheduler.settle(receipt(second), 0).accepted).assertFalse(); expect(quiesced(scheduler).readyForAssembly).assertTrue();
    });
    it('foreign_run_download_chunk_and_lane_receipts_are_ignored_before_state_changes', 0, (): void => {
      const scheduler: AdaptiveScheduler = run(freshState(1)); const dispatch: AdaptiveDispatch = scheduler.claim(0, 1)[0];
      const wrongRun: AdaptiveSettlement = receipt(dispatch); wrongRun.identity.runToken = 'other';
      const wrongId: AdaptiveSettlement = receipt(dispatch); wrongId.identity.downloadId = '11234567-89ab-cdef-0123-456789abcdef';
      const wrongChunk: AdaptiveSettlement = receipt(dispatch); wrongChunk.identity.chunkId = 'c1';
      const wrongLane: AdaptiveSettlement = receipt(dispatch); wrongLane.identity.laneId = 1;
      const reports: AdaptiveSettlement[] = [wrongRun, wrongId, wrongChunk, wrongLane];
      for (let i = 0; i < reports.length; i++) { expect(scheduler.settle(reports[i], 0).accepted).assertFalse(); }
      expect(scheduler.isCurrentAttempt(dispatch.identity)).assertTrue(); expect(scheduler.takeChanges().length).assertEqual(0);
    });
    it('current_complete_without_a_sealed_candidate_is_a_fatal_invalid_receipt', 0, (): void => {
      const scheduler: AdaptiveScheduler = run(freshState(1)); const dispatch: AdaptiveDispatch = scheduler.claim(0, 1)[0];
      expect(scheduler.settle(receipt(dispatch, 'complete', -1), 0).code).assertEqual('InvalidReceipt');
      expect(scheduler.isCurrentAttempt(dispatch.identity)).assertFalse();
      expect(quiesced(scheduler).failureCode).assertEqual('InvalidReceipt'); expect(scheduler.snapshotParts()[0].downloaded).assertEqual(0);
    });
    it('known_partial_full_length_and_known_200_reset_are_invalid_receipts', 0, (): void => {
      let scheduler: AdaptiveScheduler = run(freshState(1)); let dispatch: AdaptiveDispatch = scheduler.claim(0, 1)[0];
      scheduler.settle(receipt(dispatch, 'retryable', 10), 0); expect(quiesced(scheduler).failureCode).assertEqual('InvalidReceipt');
      scheduler = run(freshState(1)); dispatch = scheduler.claim(0, 1)[0];
      const report: AdaptiveSettlement = receipt(dispatch); report.whole200Reset = true;
      scheduler.settle(report, 0); expect(quiesced(scheduler).failureCode).assertEqual('InvalidReceipt');
    });
    it('whole_200_reset_can_replace_the_old_prefix_with_a_shorter_new_complete_file', 0, (): void => {
      const state: AdaptiveDownloadState = freshState(1, false); saved(state.parts[0], 12);
      const scheduler: AdaptiveScheduler = run(state); const dispatch: AdaptiveDispatch = scheduler.claim(0, 1)[0];
      const report: AdaptiveSettlement = receipt(dispatch, 'complete', 3); report.whole200Reset = true;
      expect(scheduler.settle(report, 0).candidateAccepted).assertTrue();
      expect(quiesced(scheduler).downloadedBytes).assertEqual(3); expectCodecAccepts(state, scheduler);
    });
    it('normal_resume_cannot_regress_but_explicit_whole_200_partial_reset_can', 0, (): void => {
      const state: AdaptiveDownloadState = freshState(1, false); saved(state.parts[0], 12);
      let scheduler: AdaptiveScheduler = run(state); let dispatch: AdaptiveDispatch = scheduler.claim(0, 1)[0];
      scheduler.settle(receipt(dispatch, 'retryable', 3), 0); expect(quiesced(scheduler).failureCode).assertEqual('InvalidReceipt');
      scheduler = run(state); dispatch = scheduler.claim(0, 1)[0];
      const report: AdaptiveSettlement = receipt(dispatch, 'retryable', 3); report.whole200Reset = true;
      scheduler.settle(report, 0); expect(scheduler.claim(10, 1)[0].prefix.downloaded).assertEqual(3);
      expectCodecAccepts(state, scheduler);
    });
    it('empty_whole_complete_requires_a_real_owned_name_and_fresh_is_not_sealed', 0, (): void => {
      const state: AdaptiveDownloadState = freshState(1, false); let scheduler: AdaptiveScheduler = run(state);
      let dispatch: AdaptiveDispatch = scheduler.claim(0, 1)[0]; scheduler.settle(receipt(dispatch, 'complete', 0), 0);
      expect(quiesced(scheduler).readyForAssembly).assertTrue(); expectCodecAccepts(state, scheduler);
      scheduler = run(freshState(1, false)); dispatch = scheduler.claim(0, 1)[0];
      const report: AdaptiveSettlement = receipt(dispatch, 'retryable', 0);
      scheduler.settle(report, 0); expect(quiesced(scheduler).failureCode).assertEqual('InvalidReceipt');
    });
    it('invalid_claim_clock_or_slots_changes_neither_existing_owners_nor_sequence', 0, (): void => {
      const scheduler: AdaptiveScheduler = run(); const first: AdaptiveDispatch = scheduler.claim(1, 1)[0];
      expectError((): void => { scheduler.claim(0, 1); }, 'InvalidClock');
      expectError((): void => { scheduler.claim(Number.NaN, 1); }, 'InvalidClock');
      expectError((): void => { scheduler.claim(1, -1); }, 'InvalidSlots');
      expect(scheduler.isCurrentAttempt(first.identity)).assertTrue();
      expect(scheduler.claim(1, 1)[0].identity.attemptId).assertEqual(2);
    });
    it('invalid_settle_clock_keeps_candidate_owner_and_retry_budget_unchanged', 0, (): void => {
      const scheduler: AdaptiveScheduler = run(freshState(1), 1); const dispatch: AdaptiveDispatch = scheduler.claim(100, 1)[0];
      const report: AdaptiveSettlement = receipt(dispatch, 'retryable', 4);
      expectError((): void => { scheduler.settle(report, 99); }, 'InvalidClock');
      expect(scheduler.isCurrentAttempt(dispatch.identity)).assertTrue(); expect(scheduler.snapshotParts()[0].downloaded).assertEqual(0);
      expect(scheduler.takeChanges().length).assertEqual(0); expect(scheduler.nextRetryAt()).assertEqual(-1);
      scheduler.settle(report, 100); const next: AdaptiveDispatch = scheduler.claim(110, 1)[0];
      expect(next.identity.attemptId).assertEqual(2); scheduler.settle(receipt(next), 110);
      expect(quiesced(scheduler).readyForAssembly).assertTrue();
    });
    it('deadline_overflow_is_rejected_before_the_clock_candidate_or_owner_is_committed', 0, (): void => {
      const scheduler: AdaptiveScheduler = run(freshState(1), 1); const now: number = Number.MAX_SAFE_INTEGER - 10;
      const dispatch: AdaptiveDispatch = scheduler.claim(now, 1)[0]; const report: AdaptiveSettlement = receipt(dispatch, 'retryable', 4);
      expectError((): void => { scheduler.settle(report, now + 1); }, 'InvalidDeadline');
      expect(scheduler.isCurrentAttempt(dispatch.identity)).assertTrue(); expect(scheduler.takeChanges().length).assertEqual(0);
      expect(scheduler.snapshotParts()[0].downloaded).assertEqual(0);
      scheduler.settle(report, now); expect(scheduler.nextRetryAt()).assertEqual(Number.MAX_SAFE_INTEGER);
      expect(scheduler.claim(Number.MAX_SAFE_INTEGER, 1)[0].identity.attemptId).assertEqual(2);
    });
    it('aggregate_byte_overflow_is_transactional_and_a_valid_replacement_still_settles', 0, (): void => {
      const state: AdaptiveDownloadState = freshState(2, false); saved(state.parts[0], Number.MAX_SAFE_INTEGER - 1, true);
      const scheduler: AdaptiveScheduler = run(state); const dispatch: AdaptiveDispatch = scheduler.claim(0, 1)[0];
      const report: AdaptiveSettlement = receipt(dispatch, 'complete', 2);
      expectError((): void => { scheduler.settle(report, 0); }, 'ByteTotalOverflow');
      expect(scheduler.isCurrentAttempt(dispatch.identity)).assertTrue(); expect(scheduler.takeChanges().length).assertEqual(0);
      scheduler.settle(receipt(dispatch, 'complete', 1), 0);
      expect(quiesced(scheduler).downloadedBytes).assertEqual(Number.MAX_SAFE_INTEGER); expectCodecAccepts(state, scheduler);
    });
    it('input_dispatch_receipt_and_snapshot_mutations_cannot_rewrite_internal_state', 0, (): void => {
      const state: AdaptiveDownloadState = freshState(1); const config: AdaptiveSchedulerLimits = limits();
      const scheduler: AdaptiveScheduler | null = createAdaptiveScheduler('runA', state, config);
      if (scheduler === null) { throw new Error('Invalid isolation fixture'); }
      state.plan.chunks[0].url = 'https://changed.example/x.ts'; state.parts[0].downloaded = 9; config.maxRetry = 0;
      const dispatch: AdaptiveDispatch = scheduler.claim(0, 1)[0]; const report: AdaptiveSettlement = receipt(dispatch);
      expect(dispatch.chunk.url).assertEqual('https://media.example/s0.ts'); expect(dispatch.prefix.downloaded).assertEqual(0);
      dispatch.identity.chunkId = 'c99'; dispatch.chunk.offset = 999; dispatch.candidateFileName = 'tampered.part';
      expect(scheduler.isCurrentAttempt(report.identity)).assertTrue(); scheduler.settle(report, 0);
      const part: AdaptivePartState | null = report.sealedPart; if (part !== null) { part.downloaded = 99; }
      const snapshot: AdaptivePartState[] = scheduler.snapshotParts(); snapshot[0].downloaded = 77;
      expect(scheduler.snapshotParts()[0].downloaded).assertEqual(10);
    });
    it('dirty_candidates_are_coalesced_by_chunk_and_returned_in_source_order', 0, (): void => {
      const scheduler: AdaptiveScheduler = run(freshState(), 2, 2, 0); const first: AdaptiveDispatch[] = scheduler.claim(0, 2);
      scheduler.settle(receipt(first[1], 'retryable', 3), 0); scheduler.settle(receipt(first[0], 'retryable', 2), 0);
      const second: AdaptiveDispatch[] = scheduler.claim(0, 2); scheduler.settle(receipt(second[1], 'retryable', 4), 0);
      const changes: AdaptivePartState[] = scheduler.takeChanges(); expect(changes.length).assertEqual(2);
      expect(changes[0].chunkId).assertEqual('c0'); expect(changes[1].chunkId).assertEqual('c1'); expect(changes[1].downloaded).assertEqual(4);
      expect(scheduler.takeChanges().length).assertEqual(0); changes[1].downloaded = 9;
      expect(scheduler.snapshotParts()[1].downloaded).assertEqual(4);
    });
    it('all_owners_idle_with_unfinished_ready_work_is_not_completion', 0, (): void => {
      const scheduler: AdaptiveScheduler = run(freshState(2), 1); expect(scheduler.takeQuiesced() === null).assertTrue();
      scheduler.settle(receipt(scheduler.claim(0, 1)[0]), 0);
      expect(scheduler.takeQuiesced() === null).assertTrue(); expect(scheduler.snapshotParts()[1].complete).assertFalse();
    });
    it('unexpected_stopped_receipt_while_running_is_explicit_failure_not_false_success', 0, (): void => {
      const scheduler: AdaptiveScheduler = run(freshState(1)); const dispatch: AdaptiveDispatch = scheduler.claim(0, 1)[0];
      scheduler.settle(receipt(dispatch, 'stopped', -1), 0);
      expect(quiesced(scheduler).failureCode).assertEqual('UnexpectedStop');
    });
    it('candidate_name_collision_rejects_the_entire_claim_batch_before_registration', 0, (): void => {
      const state: AdaptiveDownloadState = freshState(); saved(state.parts[1], 1); state.parts[1].fileName = 'runA_2.part';
      const scheduler: AdaptiveScheduler = run(state);
      expectError((): void => { scheduler.claim(0, 2); }, 'CandidateNameCollision');
      const first: AdaptiveDispatch = scheduler.claim(0, 1)[0]; expect(first.identity.attemptId).assertEqual(1);
      expect(scheduler.requestPause().length).assertEqual(1);
      expect(scheduler.snapshotParts()[1].fileName).assertEqual('runA_2.part');
    });
  });
}
