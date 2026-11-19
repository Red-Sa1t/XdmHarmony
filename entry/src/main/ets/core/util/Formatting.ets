/*
 * U1.2 纯格式化函数层（设计书 §5.3）：零 @kit import——Hypium 本地单测可直接加载。
 * 对照源码锚（FormattingHelper.cs:9-41 逐分支）：
 *   formatSize  ← :21-41：<=0 → '---'；>GB(1073741824) → x:F1 'G'；>MB(1048576) → 'M'；
 *                 >KB(1024) → 'K'；否则 (long)length 'B'（C# 整数强转截断 = Math.floor，两操作数非负）。
 *                 C# $"{x:F1}" 一位小数 → toFixed(1)。
 *   toHMS       ← :11-19：hrs=sec/3600、min=(sec%3600)/60、sec=sec%60，逐段 PadLeft(2,'0')；
 *                 负数守卫按 0（ArkTS 加固，C# 负秒会产出负时分秒串）。
 *   formatSpeed ← Application.cs:309：FormattingHelper.FormatSize(speed) + "/s"
 *                 （UpdateProgressOnUI 消费，U1.2 由 Index 事件回调派生）。
 *   formatDate   ← U4.1 追加（非源码函数）：DateAdded 列 StringFormat=d（xaml:620/:696 文化相关）
 *                 → 'YYYY-MM-DD' 平台化固定（D8），见函数注。
 * ArkTS 合规：模板字面量合法、显式返回类型、无对象字面量。
 */

/** 字节阶梯格式化（FormattingHelper.cs:21-41 逐分支 1:1） */
export function formatSize(length: number): string {
  const GB: number = 1073741824;
  const MB: number = 1048576;
  const KB: number = 1024;
  if (length <= 0) {
    return '---';
  }
  if (length > GB) {
    return `${(length / GB).toFixed(1)}G`;
  }
  if (length > MB) {
    return `${(length / MB).toFixed(1)}M`;
  }
  if (length > KB) {
    return `${(length / KB).toFixed(1)}K`;
  }
  return `${Math.floor(length)}B`;
}

/** 速度格式化（Application.cs:309）：formatSize + "/s" */
export function formatSpeed(bytesPerSec: number): string {
  return formatSize(bytesPerSec) + '/s';
}

/** 时长 HH:MM:SS（FormattingHelper.cs:11-19；负数守卫 0） */
export function toHMS(sec: number): string {
  const total: number = sec > 0 ? Math.floor(sec) : 0;
  const hrs: number = Math.floor(total / 3600);
  const min: number = Math.floor((total % 3600) / 60);
  const rem: number = total % 60;
  return String(hrs).padStart(2, '0') + ':' + String(min).padStart(2, '0') + ':' + String(rem).padStart(2, '0');
}

/**
 * 日期列渲染（U4.1 追加，设计书 §1-#8/§4-D8）：epoch 毫秒 → 'YYYY-MM-DD'（本地时区）。
 * 源载体：MainWindow.xaml DateAdded 列 StringFormat=d（:620/:696——文化相关短日期格式，
 * WPF 跟随系统区域）；鸿蒙侧拍板固定 'YYYY-MM-DD'（平台化差异 D8，跨区域稳定可走查）。
 * 消费方：DownloadListItem 日期列；零 @kit（与本文件纯函数纪律一致）。
 */
export function formatDate(epochMs: number): string {
  const date: Date = new Date(epochMs);
  const year: string = String(date.getFullYear()).padStart(4, '0');
  const month: string = String(date.getMonth() + 1).padStart(2, '0');
  const day: string = String(date.getDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
}
