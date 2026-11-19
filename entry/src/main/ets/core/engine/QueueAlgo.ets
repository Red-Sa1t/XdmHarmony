/*
 * U3.1 队列调度纯函数层（设计书 §3.4/§5.1）。
 * 零 @kit import——Hypium 本地单测（entry/src/test/QueueAlgo.test.ets）可直接加载本模块
 * （PieceAlgo.ets 同口径）。
 * 对照源码：XDM.Core/Collections/GenericOrderedDictionary.cs（:48-58 Add 已存在键不改位、
 * :96-102 Remove 双删、GetEnumerator 按 keys List 序 yield——插入序=FIFO 语义根基）；
 * XDM.Core/ApplicationCore.cs（:567-578 ProcessNextQueuedItem 每次 First() 恰取一个；
 * :262 门判定 liveDownloads.Count >= Config.Instance.MaxParallelDownloads——只数 live 不含排队）。
 * 有意差异 D3：源码本无优先级（grep 验证 queuedDownloads 值恒 bool），pickNextQueuedId 的
 * "priority DESC、插入序 ASC"是任务书"FIFO+优先级字段预留"的纯函数落法——默认全 0 时严格
 * 等价 FIFO（严格 `>` 首见胜出=并列取最旧，与 keys List 首元素同构）。
 * 有意差异 D11：effectiveMaxParallel 防御钳制（<1 归一 1）——源码无钳制（WPF 下拉枚举保证
 * 合法），U4.3 设置 UI 落地前的运行时防御。
 */

/** 队列投影行：dequeueOne 把 queueIds+queueMap 投影为本类型后交给纯函数选择（Map 不遍历，
 * ArkTS 禁 for..in——双集合经本数组桥接纯函数层）。 */
export class QueueOrderEntry {
  id: string;
  priority: number;

  constructor(id: string, priority: number) {
    this.id = id;
    this.priority = priority;
  }
}

/**
 * 取下一个应补位的排队项 id（O(n) 单趟）。
 * 规则：priority DESC、插入序 ASC——严格 `>` 比较、并列首见（最旧）胜出；
 * 默认全 0 时逐元素等价 keys[0]（GenericOrderedDictionary.First() 的严格 FIFO 同构）。
 * 空表返回 null（调用方直接 return，等价 ProcessNextQueuedItem 的 count==0 分支 :578-595）。
 */
export function pickNextQueuedId(entries: QueueOrderEntry[]): string | null {
  let best: QueueOrderEntry | null = null;
  for (let i = 0; i < entries.length; i++) {
    const e: QueueOrderEntry = entries[i];
    if (best === null || e.priority > best.priority) {
      best = e;
    }
  }
  return best === null ? null : best.id;
}

/**
 * 并发上限防御钳制：raw < 1 归一为 1（0/负值/NaN 全落 1——NaN 与 1 比较为 false 同走钳制支）。
 * 门判定唯一入口：DownloadManager 的 admitNew/resumeOne/dequeueOne 一律经本函数读
 * Config.getMaxParallelDownloads()。
 */
export function effectiveMaxParallel(raw: number): number {
  return raw >= 1 ? raw : 1;
}
