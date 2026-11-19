/*
 * U2.1 分片算法纯函数 Hypium 本地用例（设计书 §7-[A]-4 用例清单，14 条；U2.3 保真度对照的前置）。
 * 被测模块零 @kit import，本地测试环境可直接 import。
 * 锁定目标（对照 HTTPDownloaderBase.cs 逐条）：
 *   - FindMaxChunk `max > 256*1024` 与 SplitPiece `rem < 256*1024` 双边界（:422/:439——rem==262144
 *     时 Find 不选、Split 允许，两个不同边界禁"顺手统一"）；
 *   - splitPiece len=rem/2 整除下取整、新片取上半区、原片保下半区且 downloaded 保留（:443-455）；
 *   - ContinueAdjacentPiece 四条件（:167-171）含"超 maxByteRange"例——D6 闭区间窗口不可达论证的锁定；
 *   - GetInactiveChunkCount 缺 Downloaded==Length 排除项的源码原貌（:378-379 vs :394，D16）。
 * 注：设计书 §7-4 括号例"{length:1000,downloaded:600}→原片{length:800,…}"的数字不满足
 * SPLIT_THRESHOLD（rem=400<262144 不可能分裂）——本用例按阈值前提取修正数字
 * （{length:1000000,downloaded:600}）验证同一断言目标"downloaded 保留"。
 * U2.2 追加：describe('chunksJson') 10 条（设计书 §7-[A]-4）——roundtrip_16/roundtrip_totalsize/
 * empty_map/truncated_json/garbage_text/field_type_error/initial_piece_doc/state_ordinal/schema_gate/
 * nonfinite_gate；畸形输入经紧凑 JSON 子串手术构造（JSON.stringify 无空格，字段级可定位）。
 * 执行注记（U2.3 更新 2026-09-28）：U2.3 设计会话已接通 `hvigorw test` 脚本化入口并实跑——
 * BUILD SUCCESSFUL、本套 24 条（PieceAlgo 14+chunksJson 10）全绿；实跑前修两处：
 * ①8 套 import 由 '@ohos.hypium'（点形态，SDK 6.1.1 下不可解析）改 '@ohos/hypium'（斜杠形态，
 * 对照 DevEco 自带 previewProject 模板）；②hypium 1.0.25 Assert 面无 assertNotNull（hvigor
 * UnitTestArkTS 实测 10505001），chunksJson 各例改谓词等价断言（RecordMapping.test.ets:169 同款）。
 * 详见 docs/design/u2-3-engine-fidelity-DESIGN.md §3.7。
 * U2.3 追加：describe('pieceMath') 7 条（设计书 §5.4）——分裂序列收敛+三不变量（Σlength 恒定/
 * 覆盖连续/downloaded 守恒）/窗口端点/maxByteRange/NonResumable/读长封顶，收口缺口清单
 * ①④ 的 PieceAlgo 侧（设计书 §7-[A]-6）。序列期望值经确定性模拟锁定（15 次分裂收敛 16 片）。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  SEG_NOT_STARTED,
  SEG_FINISHED,
  SEG_DOWNLOADING,
  SEG_FAILED,
  STREAM_PRIMARY,
  STREAM_SECONDARY,
  SPLIT_THRESHOLD,
  READ_BUF_LEN,
  EnginePiece,
  createInitialPiece,
  findMaxChunk,
  splitPiece,
  continueAdjacentPiece,
  allFinished,
  getInactiveChunkCount,
  getInactivePiece,
  sortPiecesByOffset,
  windowOf,
  totalDownloadedOf,
  maxByteRangeOf,
  isNonResumableResume,
  cappedReadLen,
  buildChunksJson,
  parseChunksJson,
  RestoredPieces
} from '../main/ets/core/engine/PieceAlgo';

/** 测试辅助构造（Piece 对象装配；生产 id 由 util.generateRandomUUID 生成，测试用确定字符串） */
function makePiece(id: string, offset: number, length: number, downloaded: number,
  state: number, streamType: number): EnginePiece {
  const p: EnginePiece = new EnginePiece();
  p.id = id;
  p.offset = offset;
  p.length = length;
  p.downloaded = downloaded;
  p.state = state;
  p.streamType = streamType;
  return p;
}

/** Map.get 窄化辅助（ArkTS 禁非空断言） */
function mustGet(pieces: Map<string, EnginePiece>, id: string): EnginePiece {
  const p = pieces.get(id);
  if (p === undefined) {
    throw new Error('piece not found: ' + id);
  }
  return p;
}

/** U2.3 序列驱动器（CreatePiece 分裂节奏纯函数重放，设计书 §5.4）：while(findMaxChunk!=null)
 * splitPiece，返回分裂次数。新片 id 按 'n'+序号（生产 id 由调度器 util.generateRandomUUID 生成）。 */
function driveSplitSequence(pieces: Map<string, EnginePiece>, maxRounds: number): number {
  let splits: number = 0;
  while (splits < maxRounds) {
    const target: string | null = findMaxChunk(pieces, true);
    if (target === null) {
      break;
    }
    splitPiece(pieces, target, 'n' + String(splits + 1));
    splits++;
  }
  return splits;
}

/** U2.3 三不变量核验（设计书 §3.4）：Σlength==totalLen、按 offset 排序后覆盖连续无重叠
 * （[0,totalLen] 全覆盖）、Σdownloaded==expectedDownloaded。返回首违例描述，''=全过。 */
function invariantViolation(pieces: Map<string, EnginePiece>, totalLen: number,
  expectedDownloaded: number): string {
  let sumLen: number = 0;
  let sumDl: number = 0;
  pieces.forEach((piece: EnginePiece) => {
    sumLen += piece.length;
    sumDl += piece.downloaded;
  });
  if (sumLen !== totalLen) {
    return 'sumLength=' + String(sumLen);
  }
  if (sumDl !== expectedDownloaded) {
    return 'sumDownloaded=' + String(sumDl);
  }
  const sorted: EnginePiece[] = sortPiecesByOffset(pieces);
  if (sorted.length > 0 && sorted[0].offset !== 0) {
    return 'firstOffset=' + String(sorted[0].offset);
  }
  for (let i = 1; i < sorted.length; i++) {
    if (sorted[i - 1].offset + sorted[i - 1].length !== sorted[i].offset) {
      return 'gapAt=' + String(i);
    }
  }
  const last: EnginePiece = sorted[sorted.length - 1];
  if (last.offset + last.length !== totalLen) {
    return 'lastEnd=' + String(last.offset + last.length);
  }
  return '';
}

export default function pieceAlgoTest(): void {
  describe('PieceAlgo', () => {
    it('createInitialPiece_probeShape', 0, () => {
      // SingleSourceHTTPDownloader.cs:84-92：{Offset=0,Length=-1,Downloaded=0,NotStarted}
      const p: EnginePiece = createInitialPiece('id0');
      expect(p.id).assertEqual('id0');
      expect(p.offset).assertEqual(0);
      expect(p.length).assertEqual(-1);
      expect(p.downloaded).assertEqual(0);
      expect(p.state).assertEqual(SEG_NOT_STARTED);
      expect(p.streamType).assertEqual(STREAM_PRIMARY);
    });

    it('constants_enumOrderAndThreshold', 0, () => {
      // SegmentState.cs:3-7 枚举序位锚（禁重排）+ Piece.cs:34-37 + :422/:439 256*1024
      expect(SEG_NOT_STARTED).assertEqual(0);
      expect(SEG_FINISHED).assertEqual(1);
      expect(SEG_DOWNLOADING).assertEqual(2);
      expect(SEG_FAILED).assertEqual(3);
      expect(STREAM_PRIMARY).assertEqual(0);
      expect(STREAM_SECONDARY).assertEqual(1);
      expect(SPLIT_THRESHOLD).assertEqual(262144);
    });

    it('findMaxChunk_thresholdStrictGreater', 0, () => {
      // :422 `max > 256*1024` 严格：rem=262144 → null（Find 不选）
      const piecesA: Map<string, EnginePiece> = new Map<string, EnginePiece>();
      piecesA.set('a', makePiece('a', 0, 262144, 0, SEG_NOT_STARTED, STREAM_PRIMARY));
      expect(findMaxChunk(piecesA, true)).assertNull();
      // rem=262145 → 该片 id
      const piecesB: Map<string, EnginePiece> = new Map<string, EnginePiece>();
      piecesB.set('b', makePiece('b', 0, 262145, 0, SEG_NOT_STARTED, STREAM_PRIMARY));
      expect(findMaxChunk(piecesB, true)).assertEqual('b');
      // splittingAllowed=false 恒 null（§0-4/D4 整流模式单点守卫）
      expect(findMaxChunk(piecesB, false)).assertNull();
    });

    it('findMaxChunk_maxRemAndInsertOrderTie', 0, () => {
      const pieces: Map<string, EnginePiece> = new Map<string, EnginePiece>();
      pieces.set('small', makePiece('small', 0, 500000, 100000, SEG_NOT_STARTED, STREAM_PRIMARY));
      pieces.set('big', makePiece('big', 500000, 900000, 0, SEG_NOT_STARTED, STREAM_PRIMARY));
      // rem: small=400000, big=900000 → 取最大者
      expect(findMaxChunk(pieces, true)).assertEqual('big');
      // 并列取 Map 插入序首个（C# Dictionary 实践序等价，D16）
      const tie: Map<string, EnginePiece> = new Map<string, EnginePiece>();
      tie.set('first', makePiece('first', 0, 524288, 0, SEG_NOT_STARTED, STREAM_PRIMARY));
      tie.set('second', makePiece('second', 524288, 524288, 0, SEG_NOT_STARTED, STREAM_PRIMARY));
      expect(findMaxChunk(tie, true)).assertEqual('first');
    });

    it('splitPiece_evenHalves', 0, () => {
      // :443-455：{offset:0,length:4194304,downloaded:0} → 原片 {0,2097152,0}，新片 {2097152,2097152,0}
      const pieces: Map<string, EnginePiece> = new Map<string, EnginePiece>();
      pieces.set('o', makePiece('o', 0, 4194304, 0, SEG_NOT_STARTED, STREAM_PRIMARY));
      const newId: string | null = splitPiece(pieces, 'o', 'n1');
      expect(newId).assertEqual('n1');
      const orig: EnginePiece = mustGet(pieces, 'o');
      expect(orig.offset).assertEqual(0);
      expect(orig.length).assertEqual(2097152);
      expect(orig.downloaded).assertEqual(0);
      const created: EnginePiece = mustGet(pieces, 'n1');
      expect(created.id).assertEqual('n1');
      expect(created.offset).assertEqual(2097152);
      expect(created.length).assertEqual(2097152);
      expect(created.downloaded).assertEqual(0);
      expect(created.state).assertEqual(SEG_NOT_STARTED);
      expect(created.streamType).assertEqual(STREAM_PRIMARY);
    });

    it('splitPiece_oddFloorAndDownloadedKept', 0, () => {
      // 奇数 rem=1048575 → len=floor(1048575/2)=524287（C# long 整除截断）；
      // 新片 offset=100+1048575-524287=524388
      const pieces: Map<string, EnginePiece> = new Map<string, EnginePiece>();
      pieces.set('o', makePiece('o', 100, 1048575, 0, SEG_NOT_STARTED, STREAM_PRIMARY));
      splitPiece(pieces, 'o', 'n');
      const created: EnginePiece = mustGet(pieces, 'n');
      expect(created.length).assertEqual(524287);
      expect(created.offset).assertEqual(524388);
      // 原片 downloaded 保留（:445 chunk.Length-=len 后 Downloaded 不动）——
      // 设计书 §7-4 括号例数字不满足 SPLIT_THRESHOLD，按阈值前提取修正数字验证同一目标
      const pieces2: Map<string, EnginePiece> = new Map<string, EnginePiece>();
      pieces2.set('p', makePiece('p', 0, 1000000, 600, SEG_NOT_STARTED, STREAM_PRIMARY));
      splitPiece(pieces2, 'p', 'q');
      const orig: EnginePiece = mustGet(pieces2, 'p');
      expect(orig.downloaded).assertEqual(600);
      expect(orig.length).assertEqual(500300);
      expect(mustGet(pieces2, 'q').downloaded).assertEqual(0);
    });

    it('splitPiece_dualBoundary', 0, () => {
      // **Find/Split 双边界锁定**（:422 `>` vs :439 `<`——两个不同边界）：
      // rem==262144：Find 不选（上一用例）、Split 允许（262144 不 < 262144）→ len=131072
      const piecesA: Map<string, EnginePiece> = new Map<string, EnginePiece>();
      piecesA.set('a', makePiece('a', 0, 262144, 0, SEG_NOT_STARTED, STREAM_PRIMARY));
      const idA: string | null = splitPiece(piecesA, 'a', 'na');
      expect(idA).assertEqual('na');
      expect(mustGet(piecesA, 'na').length).assertEqual(131072);
      expect(mustGet(piecesA, 'a').length).assertEqual(131072);
      // rem==262143 → null（`<` 严格命中）
      const piecesB: Map<string, EnginePiece> = new Map<string, EnginePiece>();
      piecesB.set('b', makePiece('b', 0, 262143, 0, SEG_NOT_STARTED, STREAM_PRIMARY));
      expect(splitPiece(piecesB, 'b', 'nb')).assertNull();
      // chunkId null → null（:435 分支）
      const piecesC: Map<string, EnginePiece> = new Map<string, EnginePiece>();
      expect(splitPiece(piecesC, null, 'nc')).assertNull();
    });

    it('continueAdjacentPiece_absorb', 0, () => {
      // :167-184：邻片 downloaded==0 && offset==position && streamType 同 &&
      // (offset+length)<=maxByteRange → 删邻片、chunk.length 扩
      const pieces: Map<string, EnginePiece> = new Map<string, EnginePiece>();
      pieces.set('c', makePiece('c', 0, 1000, 0, SEG_NOT_STARTED, STREAM_PRIMARY));
      pieces.set('adj', makePiece('adj', 1000, 500, 0, SEG_NOT_STARTED, STREAM_PRIMARY));
      const absorbed: boolean = continueAdjacentPiece(pieces, 'c', 1500);
      expect(absorbed).assertTrue();
      expect(pieces.has('adj')).assertFalse();
      expect(mustGet(pieces, 'c').length).assertEqual(1500);
    });

    it('continueAdjacentPiece_breakConditions', 0, () => {
      // 条件破例逐项：streamType 异
      const p1: Map<string, EnginePiece> = new Map<string, EnginePiece>();
      p1.set('c', makePiece('c', 0, 1000, 0, SEG_NOT_STARTED, STREAM_PRIMARY));
      p1.set('adj', makePiece('adj', 1000, 500, 0, SEG_NOT_STARTED, STREAM_SECONDARY));
      expect(continueAdjacentPiece(p1, 'c', 999999)).assertFalse();
      // downloaded>0
      const p2: Map<string, EnginePiece> = new Map<string, EnginePiece>();
      p2.set('c', makePiece('c', 0, 1000, 0, SEG_NOT_STARTED, STREAM_PRIMARY));
      p2.set('adj', makePiece('adj', 1000, 500, 1, SEG_NOT_STARTED, STREAM_PRIMARY));
      expect(continueAdjacentPiece(p2, 'c', 999999)).assertFalse();
      // 不相邻（offset != position）
      const p3: Map<string, EnginePiece> = new Map<string, EnginePiece>();
      p3.set('c', makePiece('c', 0, 1000, 0, SEG_NOT_STARTED, STREAM_PRIMARY));
      p3.set('adj', makePiece('adj', 1001, 500, 0, SEG_NOT_STARTED, STREAM_PRIMARY));
      expect(continueAdjacentPiece(p3, 'c', 999999)).assertFalse();
      // 超 maxByteRange（D6 不可达论证锁定：adj.offset+adj.length=1500 > 1499 → false 且邻片保留）
      const p4: Map<string, EnginePiece> = new Map<string, EnginePiece>();
      p4.set('c', makePiece('c', 0, 1000, 0, SEG_NOT_STARTED, STREAM_PRIMARY));
      p4.set('adj', makePiece('adj', 1000, 500, 0, SEG_NOT_STARTED, STREAM_PRIMARY));
      expect(continueAdjacentPiece(p4, 'c', 1499)).assertFalse();
      expect(p4.has('adj')).assertTrue();
      // pieceId 不存在 → false（防御）
      expect(continueAdjacentPiece(p4, 'ghost', 999999)).assertFalse();
    });

    it('inactiveRules_pieceExclusions', 0, () => {
      // :394 排除 在途 / Finished / Downloaded==Length
      const pieces: Map<string, EnginePiece> = new Map<string, EnginePiece>();
      pieces.set('inflight', makePiece('inflight', 0, 1000, 100, SEG_NOT_STARTED, STREAM_PRIMARY));
      pieces.set('done', makePiece('done', 1000, 500, 500, SEG_FINISHED, STREAM_PRIMARY));
      pieces.set('fullNotFinished', makePiece('fullNotFinished', 2000, 300, 300,
        SEG_NOT_STARTED, STREAM_PRIMARY));
      pieces.set('candidate', makePiece('candidate', 3000, 400, 10, SEG_NOT_STARTED, STREAM_PRIMARY));
      const active: Set<string> = new Set<string>();
      active.add('inflight');
      expect(getInactivePiece(pieces, active)).assertEqual('candidate');
      const activeAll: Set<string> = new Set<string>();
      activeAll.add('inflight');
      activeAll.add('candidate');
      expect(getInactivePiece(pieces, activeAll)).assertNull();
    });

    it('inactiveRules_countKeepsSourceQuirk', 0, () => {
      // :378-379 源码原貌锁定（D16）：count 条件**缺** Downloaded==Length 排除项——
      // fullNotFinished（downloaded==length 但 state!=FINISHED 且不在途）被计入
      const pieces: Map<string, EnginePiece> = new Map<string, EnginePiece>();
      pieces.set('inflight', makePiece('inflight', 0, 1000, 100, SEG_NOT_STARTED, STREAM_PRIMARY));
      pieces.set('done', makePiece('done', 1000, 500, 500, SEG_FINISHED, STREAM_PRIMARY));
      pieces.set('fullNotFinished', makePiece('fullNotFinished', 2000, 300, 300,
        SEG_NOT_STARTED, STREAM_PRIMARY));
      const active: Set<string> = new Set<string>();
      active.add('inflight');
      expect(getInactiveChunkCount(pieces, active)).assertEqual(1);
      // 空 Map → count=0 / piece=null
      const empty: Map<string, EnginePiece> = new Map<string, EnginePiece>();
      expect(getInactiveChunkCount(empty, new Set<string>())).assertEqual(0);
      expect(getInactivePiece(empty, new Set<string>())).assertNull();
    });

    it('allFinished_semantics', 0, () => {
      // :334-349：全 FINISHED true；含 NOT_STARTED false；空 Map true（C# 空循环语义）
      const pieces: Map<string, EnginePiece> = new Map<string, EnginePiece>();
      pieces.set('a', makePiece('a', 0, 100, 100, SEG_FINISHED, STREAM_PRIMARY));
      pieces.set('b', makePiece('b', 100, 100, 100, SEG_FINISHED, STREAM_PRIMARY));
      expect(allFinished(pieces)).assertTrue();
      pieces.set('c', makePiece('c', 200, 100, 0, SEG_NOT_STARTED, STREAM_PRIMARY));
      expect(allFinished(pieces)).assertFalse();
      const empty: Map<string, EnginePiece> = new Map<string, EnginePiece>();
      expect(allFinished(empty)).assertTrue();
    });

    it('windowAndTotal_math', 0, () => {
      // :393-394 闭窗口数学：[offset+downloaded, offset+length-1]
      const p: EnginePiece = makePiece('p', 1000, 500, 200, SEG_NOT_STARTED, STREAM_PRIMARY);
      const win: number[] = windowOf(p);
      expect(win.length).assertEqual(2);
      expect(win[0]).assertEqual(1200);
      expect(win[1]).assertEqual(1499);
      // :515-526 TicksAndSizeAtResume 同式：Σ downloaded
      const pieces: Map<string, EnginePiece> = new Map<string, EnginePiece>();
      pieces.set('a', makePiece('a', 0, 1000, 100, SEG_NOT_STARTED, STREAM_PRIMARY));
      pieces.set('b', makePiece('b', 1000, 1000, 250, SEG_NOT_STARTED, STREAM_PRIMARY));
      expect(totalDownloadedOf(pieces)).assertEqual(350);
    });

    it('sortPiecesByOffset_ascendingStable', 0, () => {
      // SingleSourceHTTPDownloader.cs:295-303 排序器：offset 升序；稳定排序（相等保插入序）
      const pieces: Map<string, EnginePiece> = new Map<string, EnginePiece>();
      pieces.set('b', makePiece('b', 2000, 100, 0, SEG_NOT_STARTED, STREAM_PRIMARY));
      pieces.set('a', makePiece('a', 0, 100, 0, SEG_NOT_STARTED, STREAM_PRIMARY));
      pieces.set('c', makePiece('c', 500, 100, 0, SEG_NOT_STARTED, STREAM_PRIMARY));
      const sorted: EnginePiece[] = sortPiecesByOffset(pieces);
      expect(sorted.length).assertEqual(3);
      expect(sorted[0].id).assertEqual('a');
      expect(sorted[1].id).assertEqual('c');
      expect(sorted[2].id).assertEqual('b');
      const tie: Map<string, EnginePiece> = new Map<string, EnginePiece>();
      tie.set('x', makePiece('x', 100, 10, 0, SEG_NOT_STARTED, STREAM_PRIMARY));
      tie.set('y', makePiece('y', 100, 20, 0, SEG_NOT_STARTED, STREAM_PRIMARY));
      const tieSorted: EnginePiece[] = sortPiecesByOffset(tie);
      expect(tieSorted[0].id).assertEqual('x');
      expect(tieSorted[1].id).assertEqual('y');
    });
  });

  // U2.2 追加：chunks JSON 纯函数用例（设计书 §7-[A]-4，10 条）。
  describe('chunksJson', () => {
    it('roundtrip_16', 0, () => {
      // WriteChunkState/ReadChunkState :557-590 往返等价：16 片覆盖 [0,4194304)，downloaded 混
      // 0/部分/满、state 混 0/1 → 逐片六字段相等且 Map 插入序=原序（D16）
      const pieces: Map<string, EnginePiece> = new Map<string, EnginePiece>();
      const order: string[] = [];
      for (let i = 0; i < 16; i++) {
        const id: string = 'piece-' + String(i);
        const len: number = 262144;
        let downloaded: number = 0;
        if (i % 4 === 1) {
          downloaded = 1000 * i;
        } else if (i % 4 === 2) {
          downloaded = len;
        }
        const state: number = downloaded === len ? SEG_FINISHED : SEG_NOT_STARTED;
        pieces.set(id, makePiece(id, i * len, len, downloaded, state, STREAM_PRIMARY));
        order.push(id);
      }
      const text: string = buildChunksJson(pieces, 4194304);
      const restored: RestoredPieces | null = parseChunksJson(text);
      // hypium 1.0.25 Assert 面无 assertNotNull（hvigor UnitTestArkTS 实测 10505001）——谓词等价
      // 断言（RecordMapping.test.ets:169 同款）
      expect(restored === null).assertEqual(false);
      const r = restored as RestoredPieces;
      expect(r.totalSize).assertEqual(4194304);
      expect(r.pieces.size).assertEqual(16);
      const restoredOrder: string[] = [];
      r.pieces.forEach((p: EnginePiece, k: string) => {
        restoredOrder.push(k);
      });
      expect(JSON.stringify(restoredOrder)).assertEqual(JSON.stringify(order));
      for (let i = 0; i < order.length; i++) {
        const orig: EnginePiece = mustGet(pieces, order[i]);
        const back: EnginePiece = mustGet(r.pieces, order[i]);
        expect(back.id).assertEqual(orig.id);
        expect(back.downloaded).assertEqual(orig.downloaded);
        expect(back.length).assertEqual(orig.length);
        expect(back.offset).assertEqual(orig.offset);
        expect(back.state).assertEqual(orig.state);
        expect(back.streamType).assertEqual(orig.streamType);
      }
    });

    it('roundtrip_totalsize', 0, () => {
      // totalSize 两例往返：4194304（已探测）与 -1（未知大小/预探测，D1 冗余字段值域）
      const pieces: Map<string, EnginePiece> = new Map<string, EnginePiece>();
      pieces.set('a', makePiece('a', 0, 100, 40, SEG_NOT_STARTED, STREAM_PRIMARY));
      const restoredKnown: RestoredPieces | null = parseChunksJson(buildChunksJson(pieces, 4194304));
      expect(restoredKnown === null).assertEqual(false);
      expect((restoredKnown as RestoredPieces).totalSize).assertEqual(4194304);
      const restoredUnknown: RestoredPieces | null = parseChunksJson(buildChunksJson(pieces, -1));
      expect(restoredUnknown === null).assertEqual(false);
      expect((restoredUnknown as RestoredPieces).totalSize).assertEqual(-1);
    });

    it('empty_map', 0, () => {
      // 空 Map → build → parse → 空 Map（等价无状态语义，对照 pieces.Count==0 全新 start）
      const pieces: Map<string, EnginePiece> = new Map<string, EnginePiece>();
      const restored: RestoredPieces | null = parseChunksJson(buildChunksJson(pieces, 4194304));
      expect(restored === null).assertEqual(false);
      expect((restored as RestoredPieces).pieces.size).assertEqual(0);
      expect((restored as RestoredPieces).totalSize).assertEqual(4194304);
    });

    it('truncated_json', 0, () => {
      // 合法产物截半 → null（TransactedIO END. 标记三检的 JSON 等价：截断→parse 失败/结构门弃，D2）
      const pieces: Map<string, EnginePiece> = new Map<string, EnginePiece>();
      pieces.set('a', makePiece('a', 0, 262144, 65536, SEG_NOT_STARTED, STREAM_PRIMARY));
      const text: string = buildChunksJson(pieces, 4194304);
      expect(parseChunksJson(text.slice(0, Math.floor(text.length / 2)))).assertNull();
    });

    it('garbage_text', 0, () => {
      // 非 JSON 文本 → null（绝不抛）
      expect(parseChunksJson('not a json at all')).assertNull();
      expect(parseChunksJson('')).assertNull();
    });

    it('field_type_error', 0, () => {
      // 类型门逐项：downloaded 为字符串（手工拼 JSON）→ null；缺 offset 字段 → null；id 空串 → null
      const pieces: Map<string, EnginePiece> = new Map<string, EnginePiece>();
      pieces.set('a', makePiece('a', 0, 262144, 65536, SEG_NOT_STARTED, STREAM_PRIMARY));
      const text: string = buildChunksJson(pieces, 4194304);
      // JSON.stringify 紧凑输出（无空格），子串替换即字段级手术
      expect(parseChunksJson(text.replace('"downloaded":65536', '"downloaded":"65536"'))).assertNull();
      expect(parseChunksJson(text.replace(',"offset":0', ''))).assertNull();
      expect(parseChunksJson(text.replace('"id":"a"', '"id":""'))).assertNull();
    });

    it('initial_piece_doc', 0, () => {
      // {offset:0,length:-1,downloaded:0,state:0} 往返合法（预探测状态可持久化——§3.4 边界前提：
      // 恢复集含 length=-1 片走 NonResumable 终态是 :169-170 同貌）
      const pieces: Map<string, EnginePiece> = new Map<string, EnginePiece>();
      pieces.set('init', makePiece('init', 0, -1, 0, SEG_NOT_STARTED, STREAM_PRIMARY));
      const restored: RestoredPieces | null = parseChunksJson(buildChunksJson(pieces, -1));
      expect(restored === null).assertEqual(false);
      const back: EnginePiece = mustGet((restored as RestoredPieces).pieces, 'init');
      expect(back.offset).assertEqual(0);
      expect(back.length).assertEqual(-1);
      expect(back.downloaded).assertEqual(0);
      expect(back.state).assertEqual(SEG_NOT_STARTED);
    });

    it('state_ordinal', 0, () => {
      // state=1 往返仍 1（SegmentState.cs:3-7 枚举序不重排锚，D8）；读回不校验范围（源码 int 直转
      // 同貌——4 也原样往返，合法性由消费方语义兜底）
      const pieces: Map<string, EnginePiece> = new Map<string, EnginePiece>();
      pieces.set('f', makePiece('f', 0, 100, 100, SEG_FINISHED, STREAM_PRIMARY));
      const restored: RestoredPieces | null = parseChunksJson(buildChunksJson(pieces, 100));
      expect(restored === null).assertEqual(false);
      expect(mustGet((restored as RestoredPieces).pieces, 'f').state).assertEqual(1);
      const text: string = buildChunksJson(pieces, 100);
      expect(parseChunksJson(text.replace('"state":1', '"state":4')) === null).assertEqual(false);
    });

    it('schema_gate', 0, () => {
      // schema=2 → null（版本门，决策 10 前向兼容锚）
      const pieces: Map<string, EnginePiece> = new Map<string, EnginePiece>();
      pieces.set('a', makePiece('a', 0, 100, 10, SEG_NOT_STARTED, STREAM_PRIMARY));
      const text: string = buildChunksJson(pieces, 100);
      expect(parseChunksJson(text.replace('"schema":1', '"schema":2'))).assertNull();
    });

    it('nonfinite_gate', 0, () => {
      // length 为 1e999（parse 后 Infinity）→ null（有限数门；截断修复场景的数值越界防御）
      const pieces: Map<string, EnginePiece> = new Map<string, EnginePiece>();
      pieces.set('a', makePiece('a', 0, 262144, 65536, SEG_NOT_STARTED, STREAM_PRIMARY));
      const text: string = buildChunksJson(pieces, 4194304);
      expect(parseChunksJson(text.replace('"length":262144', '"length":1e999'))).assertNull();
    });
  });

  // U2.3 追加：分裂序列/恢复偏移数学（设计书 §5.4，7 条）。序列用例按 CreatePiece 驱动节奏
  // （SS.cs:292 每连接一次 → HB.cs:307-332 while(FindMaxChunk) SplitPiece）在纯函数层重放：
  // findMaxChunk 选最大 rem（严格 >，并列取插入序首个）+ splitPiece 对半切——期望值经确定性
  // 模拟锁定（15 次分裂收敛 16 片）。驱动器/不变量辅助在模块顶层（禁嵌套函数声明）。
  describe('pieceMath', () => {
    it('splitSequence_converge_4MiB_to_16', 0, () => {
      // SS.cs:292 + HB.cs:307-332：4MiB 初始片经 findMaxChunk+splitPiece 循环 15 次 →
      // 16 片×262144（每片 rem=262144 不满足 findMaxChunk 严格 `>` → null，数学收敛点）；
      // 终止时 findMaxChunk→null（rem==262144 时 Find 不选——与 splitPiece `<` 的双边界呼应）
      const pieces: Map<string, EnginePiece> = new Map<string, EnginePiece>();
      pieces.set('p0', makePiece('p0', 0, 4194304, 0, SEG_NOT_STARTED, STREAM_PRIMARY));
      const splits: number = driveSplitSequence(pieces, 100);
      expect(splits).assertEqual(15);
      expect(pieces.size).assertEqual(16);
      expect(findMaxChunk(pieces, true)).assertNull();
      // 不变量：Σlength 恒定 4194304（分裂只切不移）+ 覆盖连续
      expect(invariantViolation(pieces, 4194304, 0)).assertEqual('');
      // 全部片长收敛 262144（=SPLIT_THRESHOLD）
      let nonThreshold: number = 0;
      pieces.forEach((piece: EnginePiece) => {
        if (piece.length !== SPLIT_THRESHOLD) {
          nonThreshold++;
        }
      });
      expect(nonThreshold).assertEqual(0);
    });

    it('splitSequence_invariants_withDownloaded', 0, () => {
      // :443-455 splitPiece 原片保下半区且 Downloaded 保留：初始 downloaded=600 → 全程
      // Σdownloaded=600 守恒（分裂把 downloaded 留在下半区）+ Σlength 恒定 + 覆盖连续；
      // 每次分裂后即时核验三不变量（确定性模拟：15 次分裂收敛 16 片，downloaded 集中于
      // 首片 p0，其 length=262707=262144+600）
      const pieces: Map<string, EnginePiece> = new Map<string, EnginePiece>();
      pieces.set('p0', makePiece('p0', 0, 4194304, 600, SEG_NOT_STARTED, STREAM_PRIMARY));
      for (let round: number = 0; round < 100; round++) {
        const target: string | null = findMaxChunk(pieces, true);
        if (target === null) {
          break;
        }
        splitPiece(pieces, target, 'm' + String(round + 1));
        expect(invariantViolation(pieces, 4194304, 600)).assertEqual('');
      }
      expect(pieces.size).assertEqual(16);
      expect(findMaxChunk(pieces, true)).assertNull();
      expect(totalDownloadedOf(pieces)).assertEqual(600);
      // downloaded 留在下半区首片：p0={offset:0,length:262707,downloaded:600}，其余片 downloaded=0
      const p0: EnginePiece = mustGet(pieces, 'p0');
      expect(p0.downloaded).assertEqual(600);
      expect(p0.length).assertEqual(262707);
      let othersWithDownloaded: number = 0;
      pieces.forEach((piece: EnginePiece, pid: string) => {
        if (pid !== 'p0' && piece.downloaded !== 0) {
          othersWithDownloaded++;
        }
      });
      expect(othersWithDownloaded).assertEqual(0);
    });

    it('windowOf_endpointBoundaries', 0, () => {
      // :393-394 端点边界：downloaded=0 → [O, O+L-1]；downloaded=L-1 → 单字节窗；
      // downloaded=L → 空窗（公式原样输出——getInactivePiece 的 Downloaded==Length 排除项
      // 保证不派发，:387-403）
      const start: EnginePiece = makePiece('p', 1000, 500, 0, SEG_NOT_STARTED, STREAM_PRIMARY);
      const winStart: number[] = windowOf(start);
      expect(winStart[0]).assertEqual(1000);
      expect(winStart[1]).assertEqual(1499);
      const single: EnginePiece = makePiece('p', 1000, 500, 499, SEG_NOT_STARTED, STREAM_PRIMARY);
      const winSingle: number[] = windowOf(single);
      expect(winSingle[0]).assertEqual(1499);
      expect(winSingle[1]).assertEqual(1499);
      const empty: EnginePiece = makePiece('p', 1000, 500, 500, SEG_NOT_STARTED, STREAM_PRIMARY);
      const winEmpty: number[] = windowOf(empty);
      expect(winEmpty[0]).assertEqual(1500);
      expect(winEmpty[1]).assertEqual(1499);
    });

    it('maxByteRangeOf_sourceFormula', 0, () => {
      // PG.cs:203-204 逐字：contentLength<=0 ? -1 : pieceOffset+contentLength
      expect(maxByteRangeOf(1000, 500)).assertEqual(1500);
      expect(maxByteRangeOf(1000, 0)).assertEqual(-1);
      expect(maxByteRangeOf(1000, -1)).assertEqual(-1);
      // READ_BUF_LEN 常量锚（:259 BUF = 32*1024）放本 describe 兜底（readBufLen_constant 详测）
    });

    it('isNonResumableResume_closedUnknownSize', 0, () => {
      // :169-170（Length==-1 && !firstRequest）+ 调度器泛化形 :426-427（!openWindow &&
      // length<=0，D20）：闭窗口派发未知大小 → true（NonResumable 终态）；开窗口豁免
      // （探测/整流类派发）；length==0 泛化锚（仅恢复畸形数据可达）；正常片长 → false
      expect(isNonResumableResume(false, -1)).assertEqual(true);
      expect(isNonResumableResume(true, -1)).assertEqual(false);
      expect(isNonResumableResume(false, 0)).assertEqual(true);
      expect(isNonResumableResume(false, 100)).assertEqual(false);
    });

    it('cappedReadLen_bufCapAndSmallRemainder', 0, () => {
      // :284-285 Math.Min(BUF.Length, remaining)：大余量封顶缓冲长；小余量按余量；
      // 相等边界；remaining<=0 守卫返 0（域内由 :270-279 先行分支消化）
      expect(cappedReadLen(32768, 1000000000)).assertEqual(32768);
      expect(cappedReadLen(32768, 1000)).assertEqual(1000);
      expect(cappedReadLen(32768, 32768)).assertEqual(32768);
      expect(cappedReadLen(32768, 0)).assertEqual(0);
    });

    it('readBufLen_constant', 0, () => {
      // :259 BUF = 32*1024
      expect(READ_BUF_LEN).assertEqual(32768);
    });
  });
}
