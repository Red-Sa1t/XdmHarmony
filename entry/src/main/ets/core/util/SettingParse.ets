/*
 * U4.3 设置页纯函数层（设计书 §1-#1/§3.1~3.3）。零 import（含 @kit）——Hypium 本地单测直接加载。
 * 对照源码（本会话逐行核对）：
 *   tryParseInt        ← Int32.TryParse 同貌（NetworkSettingsView.xaml.cs:52-55/:57 保存路径；
 *                          NumberStyles.Integer 默认允许前导 +/-；其余字符非法、Int32 越界返 false）
 *   parseExtensionList ← BrowserMonitoringView.xaml.cs:52-54：Split(',').Select(Trim).Where(len>0)
 *                          **不去重**（与分类不同：无 HashSet、无 CRLF 预处理）
 *   parseCategoryTypes ← GeneralSettingsView.xaml.cs:86-87/:108-109：Replace("\r\n","") 后同上
 *                          → HashSet<string>（去重；C# HashSet add-only 迭代序=插入序 → 去重保序）
 *   joinForEdit        ← :40-42 string.Join(",", ...) 显示回填同貌
 * 值域常量（下拉 Select 项数与回显钳制防御）：
 *   MIN_VIDEO_SIZE_CHOICES ← BrowserMonitoringView.xaml.cs:33 九档逐值
 *   RANGE_* / clampToRange ← GeneralSettingsView.xaml.cs:34 Enumerable.Range(1,50)、
 *                          NetworkSettingsView.xaml.cs:28-30 Range(1,300)/(1,64)/(1,100)
 * ArkTS 合规：无正则字面量（CR/LF 删除用 split+join）、显式返回类型、无解构/对象字面量。
 */

/** Int32 上界（Int32.MaxValue）与负向幅值（|Int32.MinValue|） */
const INT32_MAX: number = 2147483647;
const INT32_MIN_MAGNITUDE: number = 2147483648;

/** Int32.TryParse 同貌（设计书 §3.3）：空串/符号后无数字/含非 [0-9]（小数点/字母/空白）→ null；
 * 数值越 Int32 界 → null。限速/代理端口保存解析唯一入口。 */
export function tryParseInt(text: string): number | null {
  if (text.length === 0) {
    return null;
  }
  let idx: number = 0;
  let negative: boolean = false;
  const first: string = text.charAt(0);
  if (first === '+' || first === '-') {
    negative = first === '-';
    idx = 1;
  }
  if (idx >= text.length) {
    // '+'/'-' 后无数字（TryParse false 同貌）
    return null;
  }
  let magnitude: number = 0;
  for (; idx < text.length; idx++) {
    const code: number = text.charCodeAt(idx);
    if (code < 48 || code > 57) {
      return null;
    }
    magnitude = magnitude * 10 + (code - 48);
    if (magnitude > INT32_MIN_MAGNITUDE) {
      // 逐位早退：超幅值（含长数字串溢到 ±Infinity 前已拦截）必非法
      return null;
    }
  }
  if (negative) {
    // magnitude <= 2147483648 已由循环门保证（-2147483648 合法）
    return -magnitude;
  }
  if (magnitude > INT32_MAX) {
    return null;
  }
  return magnitude;
}

/** 监控页三列表解析（BrowserMonitoringView.xaml.cs:52-54 同貌）：逗号 split→trim→去空，
 * **不去重**（'MP4,MP4' → ['MP4','MP4'] 单测锁定）。 */
export function parseExtensionList(raw: string): string[] {
  const result: string[] = [];
  const parts: string[] = raw.split(',');
  for (let i = 0; i < parts.length; i++) {
    const item: string = parts[i].trim();
    if (item.length > 0) {
      result.push(item);
    }
  }
  return result;
}

/** 分类 FileTypes 解析（GeneralSettingsView.xaml.cs:86-87/:108-109 同貌）：先删任意 CR/LF
 * （源 Replace("\r\n","") 的逐字符删等价——TextArea 输入以 CRLF 对出现，逐字符删更稳）、
 * 再逗号 split→trim→去空→**去重保序**（C# HashSet 插入序语义）。 */
export function parseCategoryTypes(raw: string): string[] {
  const noCrLf: string = raw.split('\r').join('').split('\n').join('');
  const parts: string[] = noCrLf.split(',');
  const result: string[] = [];
  for (let i = 0; i < parts.length; i++) {
    const item: string = parts[i].trim();
    if (item.length === 0) {
      continue;
    }
    let duplicate: boolean = false;
    for (let j = 0; j < result.length; j++) {
      if (result[j] === item) {
        duplicate = true;
        break;
      }
    }
    if (!duplicate) {
      result.push(item);
    }
  }
  return result;
}

/** 显示回填（string.Join(",", ...) 同貌） */
export function joinForEdit(list: string[]): string {
  return list.join(',');
}

/** 监控页"最小视频体积"九档（BrowserMonitoringView.xaml.cs:33 逐值；单位 KB） */
export const MIN_VIDEO_SIZE_CHOICES: number[] =
  [128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768];

/** 下拉值域上界（下界恒 1）：并发 GeneralSettingsView.xaml.cs:34 / 超时·分段·重试
 * NetworkSettingsView.xaml.cs:28-30 */
export const RANGE_MIN: number = 1;
export const RANGE_MAX_PARALLEL: number = 50;
export const RANGE_TIMEOUT: number = 300;
export const RANGE_SEGMENTS: number = 64;
export const RANGE_RETRY: number = 100;

/** 下拉回显防御钳 [min,max]：越界/非有限值归边界（clampScheduleMinutes 同族防御）。
 * Select.selected(index) 只在 0..n-1 有意义，越界值由本函数归界防 UI 空显。 */
export function clampToRange(value: number, min: number, max: number): number {
  if (!Number.isFinite(value) || value < min) {
    return min;
  }
  if (value > max) {
    return max;
  }
  return value;
}
