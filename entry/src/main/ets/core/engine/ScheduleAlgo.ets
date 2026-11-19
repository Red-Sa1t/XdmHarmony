/*
 * U3.2 调度纯函数层（设计书 §2.4/§3.3/§5.2；对照 Scheduler.cs + DownloadSchedule.cs）。
 * 零 @kit import——Hypium 本地单测可直接加载（PieceAlgo/QueueAlgo 同口径）。
 *
 * 源码锚（逐字保真点）：
 *   Scheduler.cs:58-63   end 边界先判先 return（end 无条件 Remove+stop）——**次序铁律**：
 *                         start==end 时 start 分支永不触达（探针 S3 §0-9 依赖此语义）
 *   Scheduler.cs:65-82   start 边界后判（activeSchedules 查重门后才 resume）
 *   Scheduler.cs:45-50   比较粒度只到 HH:MM（h/m 分离相等 ⇔ 分钟数相等，数学等价 D7）
 *   Scheduler.cs:92-98   DayOfWeek 位匹配链 + :105-107 HasFlag（(d1 & d2) == d2 逐字）
 *   DownloadSchedule.cs:17-20 WeekDays 位值表 None=0,Sun=1,Mon=2,Tue=4,Wed=8,Thu=16,
 *                         Fri=32,Sat=64（jsDayOfWeek 0=周日 与 C# DayOfWeek.Sunday=0 同基）
 *
 * 分层红线：零 probe import、零 hilog、零 [XDM_PROBE] 输出（纯函数层静默）；
 * 队列实体（U4 Queue 页）落地时本层零改动（D6 迁移路径承诺）。
 */

/** scheduledBoundary 返回值：无边界命中（该分钟既非 end 也非 start） */
export const BOUNDARY_NONE: number = 0;
/** scheduledBoundary 返回值：命中 end 边界（end 先判，Scheduler.cs:58-63） */
export const BOUNDARY_END: number = 1;
/** scheduledBoundary 返回值：命中 start 边界（start 后判，Scheduler.cs:65-82） */
export const BOUNDARY_START: number = 2;

/**
 * 一天内分钟数（Scheduler.cs:45-46 h1*60+m1 的分钟数等价物，D7 直接存分钟 0..1439）。
 * h/m 越界防御钳 0（源由 DateTime 结构保证合法；ArkTS 侧 getHours()/getMinutes() 天然合法，
 * 纯函数面兜底供单测与未来调用方）。
 */
export function minutesOfDay(hours: number, minutes: number): number {
  const h: number = hours >= 0 && hours <= 23 ? hours : 0;
  const m: number = minutes >= 0 && minutes <= 59 ? minutes : 0;
  return h * 60 + m;
}

/**
 * 星期位值（DownloadSchedule.cs WeekDays 位值表直译）：jsDayOfWeek 0=周日→1(2^0) …
 * 6=周六→64(2^6)；非法入参（<0 或 >6）→0（无位恒不匹配——None 语义）。
 * C# DateTime.Now.DayOfWeek 基 0=Sunday 与 JS Date.getDay() 基 0=Sunday 同基，直译。
 */
export function weekDayBitOf(jsDayOfWeek: number): number {
  if (jsDayOfWeek < 0 || jsDayOfWeek > 6) {
    return 0;
  }
  return 1 << jsDayOfWeek;
}

/**
 * 位匹配（Scheduler.cs:105-107 HasFlag 逐字：`((byte)d1 & (byte)d2) == (byte)d2`）。
 * daysMask=0（None）对任何 dayBit>=1 恒 false（:92-98 匹配链首即假——Days==None 永不触发）。
 */
export function matchesDay(daysMask: number, dayBit: number): boolean {
  return (daysMask & dayBit) === dayBit;
}

/**
 * 分钟双边界判定（Scheduler.cs:58-82 逐字次序）：end 精确相等→BOUNDARY_END（先判先 return）；
 * 否则 start 精确相等→BOUNDARY_START；否则 BOUNDARY_NONE。
 * start==end 时恒返 END（end 先判吞掉——§0-9 次序保真）。
 */
export function scheduledBoundary(nowMinutes: number, startMinutes: number,
  endMinutes: number): number {
  if (nowMinutes === endMinutes) {
    // :58-63 end 先判先 return
    return BOUNDARY_END;
  }
  if (nowMinutes === startMinutes) {
    // :65-82 start 后判
    return BOUNDARY_START;
  }
  return BOUNDARY_NONE;
}
