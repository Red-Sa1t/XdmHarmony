/*
 * U4.2 批量下载生成纯函数层（设计书 §2.3/§3.1/§5.1）。
 * 零 import（含 @kit）——Hypium 本地单测（entry/src/test）可直接加载本模块。
 * 对照源码锚（XDM.Core/UI/BatchDownloadUIController.cs，本会话逐行核对）：
 *   generateBatchLinks ← GenerateBatchLink 双重载（:105-159 逐行）：
 *     - 无 '*' → Enumerable.Empty（:107）→ []
 *     - 字母模式缺 From/To → ArgumentException（:124）→ 外层 catch 空（:115-118）→ []
 *     - startChar >= endChar → 空表（:128-132）；startNum >= endNum → 空表（:144-148）
 *     - 循环内 new Uri(...)（:138/:152-154）单条抛 UriFormatException 中止全批
 *   null 与 [] 语义分离（设计书 §3.1 红线）：null=URL 非法（预览路径弹 MSG_INVALID_URL，
 *     OnBatchPatternChange :100-102 的 catch(UriFormatException) 分流）；[]=无星号/空区间
 *     （OK 路径 OnOKClicked :49-53 links 空弹 BAT_SELECT_ITEMS）。all-or-nothing：任一候选
 *     URL 非法 → 整体 null（与 C# 单条抛出中止全批同构）。isUriValid 作入参注入保模块零依赖
 *     （core/net/HttpProtocol.ets 的 isUriValid 由调用方传入）。
 *   padDigits ← C# i.ToString($"D{n}")（:152-154）：最少 n 位十进制、不足补零、
 *     负号不占位（(-5).ToString("D3")="-005"；JS padStart 会产出 "0-5"，必须负号外置）。
 *   string.Replace('*') 换全部出现（C# 语义）→ split('*').join(x) 全量替换
 *     （JS replace 只换首个 '*'，两星号 URL 单测锁定，设计书 §3.1 差异点）。
 *   computeBatchPreview ← OnBatchPatternChange :72-93 逐行：c==0→first；c==1→second；
 *     last 恒更新；size=c 计数；c>1 才回填 last。
 * ArkTS 合规：零 import、无正则字面量、显式返回类型、索引 for 循环。
 */

/** 批量参数（对照 IBatchDownloadView 投影；全字段显式默认，BatchDownloadDialog 表单镜像） */
export class BatchParams {
  /** 含 '*' 的地址模板 */
  url: string = '';
  /** ctor 初始 true（UIController.cs:26 IsLetterMode=true） */
  isLetterMode: boolean = true;
  /** 'A'..'Z'，空串=未选（C# char? HasValue=false 同构） */
  startLetter: string = '';
  endLetter: string = '';
  /** ParseIntSafe 失败=0（ParsingHelper.cs:47——WPF StartNumber 属性同源） */
  startNumber: number = 0;
  endNumber: number = 0;
  useLeadingZero: boolean = false;
  leadingZeroCount: number = 0;
}

/** 预览产物（first/second/last 三地址 + 计数；second/last 仅链数足够时非空） */
export class BatchPreview {
  first: string = '';
  second: string = '';
  last: string = '';
  size: number = 0;
}

/** C# D 格式整数（负号外置）：(-5,3)→'-005'；(5,3)→'005'；(5,0)→'5' */
export function padDigits(value: number, count: number): string {
  const digits: string = String(Math.abs(Math.trunc(value))).padStart(count, '0');
  return (value < 0 ? '-' : '') + digits;
}

/**
 * 批量链接生成（GenerateBatchLink :105-159 逐行翻译）。
 * 返回 null=候选 URL 非法（all-or-nothing）；[]=无 '*' 或区间空（含字母缺选）。
 * isUriValid 由调用方注入（HttpProtocol.isUriValid 先例语义）。
 */
export function generateBatchLinks(params: BatchParams,
  isUriValid: (url: string) => boolean): string[] | null {
  if (!params.url.includes('*')) {
    // :107 无 '*' → Enumerable.Empty
    return [];
  }
  if (params.isLetterMode) {
    // :124 ArgumentException → 外层 catch → 空（设计书 §3.1 拍板取 []）
    if (params.startLetter.length === 0 || params.endLetter.length === 0) {
      return [];
    }
    const startChar: number = params.startLetter.charCodeAt(0);
    const endChar: number = params.endLetter.charCodeAt(0);
    // :128-132 startChar >= endChar → 空表
    if (startChar >= endChar) {
      return [];
    }
    const list: string[] = [];
    for (let c = startChar; c <= endChar; c++) {
      // :138 url.Replace('*', i)——C# 换全部出现 → split/join
      const candidate: string = params.url.split('*').join(String.fromCharCode(c));
      if (!isUriValid(candidate)) {
        return null;
      }
      list.push(candidate);
    }
    return list;
  }
  // :144-148 startNum >= endNum → 空表
  if (params.startNumber >= params.endNumber) {
    return [];
  }
  const list: string[] = [];
  for (let i = params.startNumber; i <= params.endNumber; i++) {
    // :152-154 补零分支：D{n} 格式（padDigits 负号外置）
    const replacement: string = params.useLeadingZero
      ? padDigits(i, params.leadingZeroCount)
      : String(i);
    const candidate: string = params.url.split('*').join(replacement);
    if (!isUriValid(candidate)) {
      return null;
    }
    list.push(candidate);
  }
  return list;
}

/** 预览聚合（OnBatchPatternChange :72-93 逐行）：c==0→first；c==1→second；last 恒更新；c>1 才回填 */
export function computeBatchPreview(urls: string[]): BatchPreview {
  const preview: BatchPreview = new BatchPreview();
  let c: number = 0;
  let last: string = '';
  for (let i = 0; i < urls.length; i++) {
    const url: string = urls[i];
    if (c === 0) {
      preview.first = url;
    } else if (c === 1) {
      preview.second = url;
    }
    last = url;
    c++;
  }
  preview.size = c;
  if (c > 1) {
    preview.last = last;
  }
  return preview;
}
