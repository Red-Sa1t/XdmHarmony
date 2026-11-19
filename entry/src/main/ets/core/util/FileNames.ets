/*
 * U1.2 纯文件名函数层（设计书 §5.2）：零 @kit import——Hypium 本地单测可直接加载；
 * 存在性探测经回调注入（getUniqueFileName）保纯度：引擎侧闭包包 accessSync，测试侧注入假表。
 * 对照源码锚：
 *   sanitizeFileName   ← FileHelper.cs:15-20 SanitizeFileName（取段 + Path.GetInvalidFileNameChars()
 *                        分割重组为 '_'）；D6 修正原版 :17-18 死赋值（Split('\\') 覆盖 '/' 分割结果）
 *                        为"最后一段分隔符取段"（'/' 与 '\\' 取较大下标）；无效字符显式枚举
 *                        '\\ / : * ? " < > |' 与 ASCII 控制符 0x00-0x1F → '_'（Windows 保留集）
 *   fileNameFromUrl    ← FileHelper.cs:88-130 GetFileName 最小集：去 query/hash → 路径段
 *                        decodeURIComponent（try/catch 包裹失败用原值）→ 末段 → sanitize；
 *                        空 → host 段 '.'→'_'（Content-Disposition 三正则链 + MIME 扩展名表延后 U6.x）
 *   getUniqueFileName  ← FileHelper.cs:107-124（name_N.ext 递增；File.Exists → exists 回调注入）
 * ArkTS 合规：禁正则字面量（逐字符枚举实现）、显式返回类型、无解构。
 */

/** 无效文件名字符显式枚举（对照 Windows Path.GetInvalidFileNameChars 图形段 + 控制符段） */
function isInvalidFileNameChar(ch: string): boolean {
  if (ch === '\\' || ch === '/' || ch === ':' || ch === '*' || ch === '?' ||
    ch === '"' || ch === '<' || ch === '>' || ch === '|') {
    return true;
  }
  return ch.charCodeAt(0) <= 0x1F;
}

/** 文件名消毒（FileHelper.cs:15-20 语义 + D6 修正）：先取最后一段分隔符后子串
 * （'/' 与 '\\' 较大下标），再逐字符替换无效字符为 '_'；空结果兜底 'file'。
 * 保真点：普通 '.' 不在无效集（keepsNormalDots）。 */
export function sanitizeFileName(name: string): string {
  let file: string = name;
  const slash: number = name.lastIndexOf('/');
  const backslash: number = name.lastIndexOf('\\');
  const cut: number = slash > backslash ? slash : backslash;
  if (cut >= 0) {
    file = name.slice(cut + 1);
  }
  let out: string = '';
  for (let i = 0; i < file.length; i++) {
    const ch: string = file.charAt(i);
    out += isInvalidFileNameChar(ch) ? '_' : ch;
  }
  if (out.length === 0) {
    return 'file';
  }
  return out;
}

/** URL 推导文件名（FileHelper.cs:88-130 最小集）：去 query/hash → 路径段 decodeURIComponent
 * （失败用原值）→ sanitizeFileName 末段化；路径段空 → host 段 '.'→'_' 再 sanitize。 */
export function fileNameFromUrl(url: string): string {
  let clean: string = url;
  const qm: number = clean.indexOf('?');
  if (qm >= 0) {
    clean = clean.slice(0, qm);
  }
  const hash: number = clean.indexOf('#');
  if (hash >= 0) {
    clean = clean.slice(0, hash);
  }
  const schemeEnd: number = clean.indexOf('://');
  const from: number = schemeEnd >= 0 ? schemeEnd + 3 : 0;
  const pathStart: number = clean.indexOf('/', from);
  const host: string = pathStart >= 0 ? clean.slice(from, pathStart) : clean.slice(from);
  const path: string = pathStart >= 0 ? clean.slice(pathStart + 1) : '';
  let decoded: string = path;
  if (path.length > 0) {
    try {
      decoded = decodeURIComponent(path);
    } catch (e) {
      decoded = path;
    }
  }
  if (decoded.length === 0) {
    return sanitizeFileName(host.split('.').join('_'));
  }
  return sanitizeFileName(decoded);
}

/** 唯一文件名（FileHelper.cs:107-124）：目录内冲突时 name_N.ext 递增（N 从 1 起）；
 * exists 为存在性探测回调（注入保纯：引擎传 accessSync 闭包，测试传假表）。
 * 扩展名切分：最后一个 '.'（下标 >0）后为扩展名（含点），'.bashrc' 形态视为无扩展名。 */
export function getUniqueFileName(file: string, dir: string, exists: (path: string) => boolean): string {
  const dot: number = file.lastIndexOf('.');
  const name: string = dot > 0 ? file.slice(0, dot) : file;
  const ext: string = dot > 0 ? file.slice(dot) : '';
  let count: number = 0;
  let candidate: string = file;
  while (exists(dir + '/' + candidate)) {
    count++;
    candidate = name + '_' + String(count) + ext;
  }
  return count === 0 ? file : candidate;
}
