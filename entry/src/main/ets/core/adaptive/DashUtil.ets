/*
 * U7.1 XS duration 解析（设计书 u7-1-dash-DESIGN.md §4.1）。
 * 源 MediaParser/Dash/DashUtil.cs:8-40 直译：
 *   - 正则逐字符保持（两段 T 部件串联原样；IgnoreCase）；模式文本保留命名组作对照锚，
 *     实际按**位置组**读取（ArkTS 运行时 groups 命名组对象不可用——真机实测，位置号
 *     1/3/5/7/10/12/14 与 C# 组号逐一对齐；第二段 T 部件组号 ≥15 从不读取）；
 *   - 年/月系数（月=30.4368 天、年=365.242 天）逐值保留（源 :19-32 注释同文）；
 *   - millis=(long)(seconds*1000) 截断 → Math.trunc；负号只认组 1 前缀 '-'；
 *   - 未匹配 fallback：Double.Parse(value)*3600*1000 截断（按小时数解释）；解析失败 throw
 *     （C# Double.FormatException → 清单丢弃同效）。
 * 有意差异（设计书 §5-4）：数值组件统一严格十进制复核——秒组 [0-9.]* 宽松形态 "1.2.3"
 *   在 .NET Double.Parse 抛 FormatException、JS parseFloat 得 1.2，故用 ^[0-9]*\.?[0-9]*$
 *   复核后 parseFloat，异常形态 throw；fallback 同理用严格十进制门（.NET 宽松空白/指数/文化
 *   形态被拒——平台差异登记，合法 xs:duration/小时数不触发）。
 * C# Double.Parse 受运行文化影响（源事实已登记）；parseFloat 恒点号——非行为分支。
 * 零 @kit 导入。ArkTS 红线：正则用 new RegExp；throw 只抛 Error。
 */

/** DashUtil.cs:8-11 XS_DURATION_PATTERN 逐字符直译（IgnoreCase；命名组对齐组号 1/3/5/7/10/12/14）。 */
const XS_DURATION_PATTERN: RegExp =
  new RegExp('^(-)?P(([0-9]*)Y)?(([0-9]*)M)?(([0-9]*)D)?(T(([0-9]*)H)?(([0-9]*)M)?(([0-9.]*)S)?)?' +
    '(T(([0-9]*)H)?(([0-9]*)M)?(([0-9.]*)S)?)?$', 'i');

/** 秒组宽松形态复核（设计书 §4.1：[0-9.]* 命中 "1.2.3" → throw 对齐 .NET FormatException）。 */
const SECONDS_SHAPE: RegExp = new RegExp('^[0-9]*\\.?[0-9]*$');

/** fallback 严格十进制门（§5-4）：允许 [+-]、整数/小数；拒绝空白/指数/其余 .NET 宽松形态。 */
const STRICT_DECIMAL: RegExp = new RegExp('^[+-]?([0-9]+(\\.[0-9]*)?|\\.[0-9]+)$');

function component(value: string, multiplier: number): number {
  if (value.length === 0) {
    return 0;
  }
  const parsed: number = parseFloat(value);
  if (Number.isNaN(parsed)) {
    throw new Error('Invalid xs duration component');
  }
  return parsed * multiplier;
}

/** 位置组读取（ArkTS 运行时 RegExpExecArray.groups 命名组对象不可用——真机实测；
 * 位置号 1/3/5/7/10/12/14 与 C# 组号逐一对齐，命名组仅保留在模式文本中作对照锚）。 */
function positional(match: RegExpExecArray, index: number): string {
  return typeof match[index] === 'string' ? match[index] as string : '';
}

/**
 * ParseXsDuration（DashUtil.cs:13-40 直译）：匹配 → 秒系数累加 ×1000 截断（负前缀取反）；
 * 未匹配 → 严格十进制复核后 parseFloat(value)*3600*1000 截断；NaN/非法形态 → throw=清单丢弃。
 * 用例锚：PT0H10M54.00S→654000（XDM_Tests/DashSanityTest.cs:27-31）；-PT30S→-30000；
 * P1Y=31556908000 / P2M=5259478000 / P3D=259200000；"1.5"→5400000；"1.2.3"/''→throw。
 */
export function parseXsDuration(value: string): number {
  const match: RegExpExecArray | null = XS_DURATION_PATTERN.exec(value);
  if (match !== null) {
    const negated: boolean = positional(match, 1).length > 0;
    let durationSeconds: number = component(positional(match, 3), 31556908);
    durationSeconds += component(positional(match, 5), 2629739);
    durationSeconds += component(positional(match, 7), 86400);
    durationSeconds += component(positional(match, 10), 3600);
    durationSeconds += component(positional(match, 12), 60);
    const seconds: string = positional(match, 14);
    if (seconds.length > 0) {
      // 宽松组 [0-9.]* 命中 "1.2.3" → .NET Double.Parse 抛错 → 复核后 parseFloat（§4.1）
      if (!SECONDS_SHAPE.test(seconds)) {
        throw new Error('Invalid xs duration seconds');
      }
      const parsed: number = parseFloat(seconds);
      if (Number.isNaN(parsed)) {
        throw new Error('Invalid xs duration seconds');
      }
      durationSeconds += parsed;
    }
    const durationMillis: number = Math.trunc(durationSeconds * 1000);
    return negated ? -durationMillis : durationMillis;
  }
  if (!STRICT_DECIMAL.test(value)) {
    throw new Error('Invalid xs duration');
  }
  const fallback: number = parseFloat(value);
  if (Number.isNaN(fallback)) {
    throw new Error('Invalid xs duration');
  }
  return Math.trunc(fallback * 3600 * 1000);
}
