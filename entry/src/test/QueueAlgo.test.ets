/*
 * U3.1 QueueAlgo 纯函数 Hypium 本地用例（设计书 §7-[A]-2 用例清单，10 条）。
 * 被测模块零 @kit import（QueueAlgo.ets），本地测试环境可直接 import（PieceAlgo.test.ets 同口径）。
 * 锁定目标：
 *   - pickNextQueuedId 的"priority DESC、插入序 ASC"字典序（严格 `>` 首见胜出）：
 *     全 0 严格 FIFO（=GenericOrderedDictionary keys List 首元素/First() 同构）、并列最旧胜出、
 *     负值低位、多趟全序抽取=优先级群组间按序+群组内 FIFO；
 *   - effectiveMaxParallel 防御钳制三例（正数透传/0 归 1/负数归 1——D11，源码无钳制的运行时防御）。
 * 断言注记：数组期望经 JSON.stringify 比对（PieceAlgo.test.ets roundtrip_16 同款——hypium
 * assertEqual 对引用类型按引用比较，不可直接比数组）。
 */

import { describe, it, expect } from '@ohos/hypium';
import { QueueOrderEntry, pickNextQueuedId, effectiveMaxParallel } from '../main/ets/core/engine/QueueAlgo';

/** 测试辅助构造（生产由 dequeueOne 投影装配，测试用确定 id/priority） */
function makeEntry(id: string, priority: number): QueueOrderEntry {
  return new QueueOrderEntry(id, priority);
}

/** 多趟全序抽取驱动器：反复 pickNext+摘除，返回 id 抽取序列（模拟"3 个完成事件=3 次补位"的
 * 连续出队节奏；pool 拷贝不动入参） */
function drainAll(entries: QueueOrderEntry[]): string[] {
  const pool: QueueOrderEntry[] = entries.slice();
  const order: string[] = [];
  while (pool.length > 0) {
    const id: string | null = pickNextQueuedId(pool);
    if (id === null) {
      break;
    }
    order.push(id);
    let idx: number = -1;
    for (let i = 0; i < pool.length; i++) {
      if (pool[i].id === id) {
        idx = i;
        break;
      }
    }
    if (idx >= 0) {
      pool.splice(idx, 1);
    }
  }
  return order;
}

export default function queueAlgoTest(): void {
  describe('QueueAlgo', () => {
    it('pickNext_empty_returnsNull', 0, () => {
      // 空表 null（调用方 dequeueOne 直接 return，等价 ProcessNextQueuedItem count==0 分支）
      expect(pickNextQueuedId([])).assertNull();
    });

    it('pickNext_single_returnsIt', 0, () => {
      // 单元素恒返（任意 priority）
      expect(pickNextQueuedId([makeEntry('only', 0)])).assertEqual('only');
      expect(pickNextQueuedId([makeEntry('only', 7)])).assertEqual('only');
      expect(pickNextQueuedId([makeEntry('only', -2)])).assertEqual('only');
    });

    it('pickNext_allZero_strictFifo', 0, () => {
      // 全 0 五元素：单趟取首（插入序最旧）+ 多趟抽取全序=严格插入序（keys List 同构）
      const entries: QueueOrderEntry[] = [
        makeEntry('a', 0), makeEntry('b', 0), makeEntry('c', 0), makeEntry('d', 0), makeEntry('e', 0)
      ];
      expect(pickNextQueuedId(entries)).assertEqual('a');
      expect(JSON.stringify(drainAll(entries))).assertEqual(JSON.stringify(['a', 'b', 'c', 'd', 'e']));
    });

    it('pickNext_priority_beatsOrder', 0, () => {
      // 旧 0 新 5 → 新者胜（priority DESC 压倒插入序）
      const entries: QueueOrderEntry[] = [makeEntry('old', 0), makeEntry('new', 5)];
      expect(pickNextQueuedId(entries)).assertEqual('new');
      // 反向排布（新 0 旧 5）同样 priority 胜——与插入序无关
      const flipped: QueueOrderEntry[] = [makeEntry('high', 5), makeEntry('low', 0)];
      expect(pickNextQueuedId(flipped)).assertEqual('high');
    });

    it('pickNext_tie_oldestWins', 0, () => {
      // 同 priority 并列 → 先插入（最旧）者胜（严格 `>` 首见不改 best）
      const entries: QueueOrderEntry[] = [makeEntry('first', 3), makeEntry('second', 3)];
      expect(pickNextQueuedId(entries)).assertEqual('first');
      // 三方并列 + 混排同值群组：群组内仍 FIFO
      const trio: QueueOrderEntry[] = [
        makeEntry('a', 1), makeEntry('b', 2), makeEntry('c', 2), makeEntry('d', 1)
      ];
      expect(JSON.stringify(drainAll(trio))).assertEqual(JSON.stringify(['b', 'c', 'a', 'd']));
    });

    it('pickNext_negative_lowerLoses', 0, () => {
      // 0 vs -1 → 0 胜（负优先级低于缺省 0）
      const entries: QueueOrderEntry[] = [makeEntry('zero', 0), makeEntry('neg', -1)];
      expect(pickNextQueuedId(entries)).assertEqual('zero');
      // 全负值群组内仍取最大（-1 胜 -5）
      const negatives: QueueOrderEntry[] = [makeEntry('n5', -5), makeEntry('n1', -1)];
      expect(pickNextQueuedId(negatives)).assertEqual('n1');
    });

    it('pickNext_mixed_fullOrder', 0, () => {
      // 五元素混合多趟全序：priority 群组间 DESC、群组内 FIFO——
      // 5 群组 {b,d}（插入序 b 先）→ 3 群组 {e} → 0 群组 {a,c}（a 先）
      const entries: QueueOrderEntry[] = [
        makeEntry('a', 0), makeEntry('b', 5), makeEntry('c', 0), makeEntry('d', 5), makeEntry('e', 3)
      ];
      expect(pickNextQueuedId(entries)).assertEqual('b');
      expect(JSON.stringify(drainAll(entries))).assertEqual(JSON.stringify(['b', 'd', 'e', 'a', 'c']));
      // 原数组不被多趟抽取破坏（drainAll 拷贝语义——manager 侧入队/摘除走集合单点，投影只读）
      expect(entries.length).assertEqual(5);
      expect(entries[0].id).assertEqual('a');
    });

    it('effectiveMax_positive_passthrough', 0, () => {
      // 正数透传（下界 1 本身也透传）
      expect(effectiveMaxParallel(3)).assertEqual(3);
      expect(effectiveMaxParallel(1)).assertEqual(1);
      expect(effectiveMaxParallel(16)).assertEqual(16);
    });

    it('effectiveMax_zero_clampsToOne', 0, () => {
      // 0 归 1（0>=1 为 false 走钳制支——门判定永不为"全不跑"）
      expect(effectiveMaxParallel(0)).assertEqual(1);
    });

    it('effectiveMax_negative_clampsToOne', 0, () => {
      // 负数归 1（-5）；防御面兜底：NaN>=1 为 false 同归 1
      expect(effectiveMaxParallel(-5)).assertEqual(1);
      expect(effectiveMaxParallel(NaN)).assertEqual(1);
    });
  });
}
