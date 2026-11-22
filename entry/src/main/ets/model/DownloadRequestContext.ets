/* U6.3-A: transport context survives database reload without depending on bridge or UI.
 * Source: SingleSourceHTTPDownloader state.Headers/Cookies (null headers != empty headers),
 * DotNetHttpClient.SetHeader (all values; Content-Type omitted for GET).
 * Harmony HTTP accepts string values: ordinary repeated fields join with ', ', Cookie with '; '.
 * Engine-owned Range and identity override browser values. Never log serialized contexts.
 */
import { sixDefaultHeaders } from '../core/net/HttpProtocol';
import { AuthSetting, authorizationFor } from '../core/net/TransportPolicy';

export interface DownloadRequestHeaders {
  names: string[];
  values: string[][];
}

export class DownloadRequestContext {
  headers: DownloadRequestHeaders | null = null;
  cookies: string | null = null;
}

interface RequestContextDocument {
  schema: number;
  headers: DownloadRequestHeaders | null;
  cookies: string | null;
}

export function cloneDownloadRequestContext(context: DownloadRequestContext): DownloadRequestContext {
  const result: DownloadRequestContext = new DownloadRequestContext();
  result.cookies = context.cookies;
  if (context.headers !== null) {
    const headers: DownloadRequestHeaders = { names: context.headers.names.slice(), values: [] };
    for (let i = 0; i < context.headers.values.length; i++) {
      headers.values.push(context.headers.values[i].slice());
    }
    result.headers = headers;
  }
  return result;
}

/** Invalid/corrupt payload returns null; callers must not silently replace it with an empty context. */
export function parseDownloadRequestContext(text: string): DownloadRequestContext | null {
  try {
    const parsed: Object | null = JSON.parse(text);
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
      return null;
    }
    const doc: RequestContextDocument = parsed as RequestContextDocument;
    if (doc.schema !== 1 || (doc.cookies !== null && typeof doc.cookies !== 'string')) {
      return null;
    }
    if (doc.cookies !== null && containsLineBreak(doc.cookies)) {
      return null;
    }
    if (doc.headers !== null) {
      if (typeof doc.headers !== 'object' || !Array.isArray(doc.headers.names) ||
        !Array.isArray(doc.headers.values) || doc.headers.names.length !== doc.headers.values.length) {
        return null;
      }
      for (let i = 0; i < doc.headers.names.length; i++) {
        const name: string = doc.headers.names[i];
        const values: string[] = doc.headers.values[i];
        if (typeof name !== 'string' || !new RegExp("^[!#$%&'*+.^_`|~0-9A-Za-z-]+$").test(name) ||
          !Array.isArray(values)) {
          return null;
        }
        for (let j = 0; j < values.length; j++) {
          if (typeof values[j] !== 'string' || containsLineBreak(values[j])) {
            return null;
          }
        }
      }
    }
    const context: DownloadRequestContext = new DownloadRequestContext();
    context.headers = doc.headers;
    context.cookies = doc.cookies;
    return cloneDownloadRequestContext(context);
  } catch (e) {
    return null;
  }
}

export function serializeDownloadRequestContext(context: DownloadRequestContext): string {
  const doc: RequestContextDocument = { schema: 1, headers: context.headers, cookies: context.cookies };
  const text: string = JSON.stringify(doc);
  if (parseDownloadRequestContext(text) === null) {
    throw new Error('Invalid download request context');
  }
  return text;
}

/** Returns a fresh HTTP dictionary. Range is exclusively supplied by the engine, never the browser. */
export function composeDownloadHeaders(url: string, context: DownloadRequestContext,
  range: string | null = null, auth: AuthSetting | null = null): Record<string, string> {
  // Validate before any request, including contexts that have not yet gone through persistence.
  serializeDownloadRequestContext(context);
  const result: Record<string, string> = {};
  const names: string[] = [];
  const valueLists: string[][] = [];
  if (context.headers === null) {
    const defaults: Record<string, string> = sixDefaultHeaders(url);
    const defaultNames: string[] = Object.keys(defaults);
    for (let i = 0; i < defaultNames.length; i++) {
      names.push(defaultNames[i].toLowerCase());
      valueLists.push([defaults[defaultNames[i]]]);
    }
  } else {
    for (let i = 0; i < context.headers.names.length; i++) {
      const name: string = context.headers.names[i].toLowerCase();
      const index: number = names.indexOf(name);
      if (index < 0) {
        names.push(name);
        valueLists.push(context.headers.values[i].slice());
      } else {
        for (let j = 0; j < context.headers.values[i].length; j++) {
          valueLists[index].push(context.headers.values[i][j]);
        }
      }
    }
  }
  for (let i = 0; i < names.length; i++) {
    const name: string = names[i];
    if (name === 'range' || name === 'accept-encoding' || name === 'content-type' ||
      (name === 'cookie' && context.cookies !== null) || valueLists[i].length === 0) {
      continue;
    }
    // HTTP names are case-insensitive; avoid the ordinary object's __proto__ setter.
    const outputName: string = name === '__proto__' ? '__Proto__' : name;
    result[outputName] = valueLists[i].join(name === 'cookie' ? '; ' : ', ');
  }
  // 2026-11-22：手动添加（无浏览器头）时 UA 取设置页用户代理（见 sixDefaultHeaders）；未带
  // Authorization 时用下载自带认证或设置页「密码管理」中该主机的凭据（Basic）
  if (names.indexOf('authorization') < 0) {
    const authorization: string = authorizationFor(url, auth);
    if (authorization.length > 0) {
      result['Authorization'] = authorization;
    }
  }
  result['Accept-Encoding'] = 'identity';
  if (context.cookies !== null) {
    result['Cookie'] = context.cookies;
  }
  if (range !== null) {
    if (containsLineBreak(range)) {
      throw new Error('Invalid engine range');
    }
    result['Range'] = range;
  }
  return result;
}

function containsLineBreak(value: string): boolean {
  return value.indexOf('\r') >= 0 || value.indexOf('\n') >= 0 || value.indexOf('\u0000') >= 0;
}
