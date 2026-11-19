/*
 * U5.1 通知决策纯函数层（设计书 §0-13/§1-#2/§3.4）：零 @kit import（Hypium 直载，
 * QueueAlgo/ScheduleAlgo 先例）。决策类判断全部抽本层，ProgressNotifier 只承载 @kit API 编排。
 * 逐函数源锚：
 *   clampProgress       —— Index.handleProgress :493 同款 [0,100] 钳位（浮点透传，模板端自渲染）
 *   finishedSize        —— Application.cs:126 Size 回退规则 1:1（recorded>0 优先，含非正数回退）
 *   shouldApplyTask     —— 0→非 0 申请锚（ApplicationCore.cs:40 ActiveDownloadCount 跃迁同构）
 *   shouldReleaseTask   —— 归零释放锚（Application.cs:152-156 ActiveDownloadCount==0 同构）
 *   shouldPublishFinish —— ShowNotification 门控只作用完成通知（拍板⑦/D6；实况窗更新不受门控）
 *   pickFinishNotificationId —— 完成通知 id 与系统长时任务返回 id 撞号避让（§0-10）
 */

/** 完成通知固定 id 基值（§0-10：与长时任务系统返回 id 区间避让；撞号则 +1） */
export const FINISH_NOTIFY_ID_BASE: number = 1001;
/** 进度钳位下界 */
export const PROGRESS_MIN: number = 0;
/** 进度钳位上界 */
export const PROGRESS_MAX: number = 100;

/** 进度钳位（[0,100]；浮点透传——Index.handleProgress :493 同款） */
export function clampProgress(progress: number): number {
  if (progress < PROGRESS_MIN) {
    return PROGRESS_MIN;
  }
  if (progress > PROGRESS_MAX) {
    return PROGRESS_MAX;
  }
  return progress;
}

/** 完成 Size 回退（Application.cs:126 `Size = downloadEntry.Size > 0 ? downloadEntry.Size : finalFileSize`
 * 1:1；回退规则含非正数——recorded<=0 一律取 finalFileSize） */
export function finishedSize(recordedSize: number, finalFileSize: number): number {
  return recordedSize > 0 ? recordedSize : finalFileSize;
}

/** 长时任务申请判定（activeCount>0 && !taskApplied——0→非 0 申请锚；幂等守卫防双申请） */
export function shouldApplyTask(activeCount: number, taskApplied: boolean): boolean {
  return activeCount > 0 && !taskApplied;
}

/** 长时任务释放判定（activeCount<=0 && taskApplied——归零释放锚；未申请不释放） */
export function shouldReleaseTask(activeCount: number, taskApplied: boolean): boolean {
  return activeCount <= 0 && taskApplied;
}

/** 完成通知发布门控（拍板⑦/D6：ShowNotification 只门完成通知，不门实况窗进度更新） */
export function shouldPublishFinish(showNotification: boolean): boolean {
  return showNotification;
}

/** 完成通知 id 避让（§0-10：系统长时任务返回 notificationId===基值时用基值+1，否则基值） */
export function pickFinishNotificationId(taskNotificationId: number): number {
  if (taskNotificationId === FINISH_NOTIFY_ID_BASE) {
    return FINISH_NOTIFY_ID_BASE + 1;
  }
  return FINISH_NOTIFY_ID_BASE;
}
