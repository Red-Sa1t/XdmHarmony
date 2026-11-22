/*
 * 2026-11-22 设置可用性修复：把设置页的「用户代理 / 代理服务器 / 密码管理」与新建下载"更多"里的
 * 单任务认证、代理接入实际请求。纯函数层，零 @kit import（host 单测可直接加载）。
 * 主线程由 Config 在载入与相应 setter 时调用 configureTransport() 同步；worker 不读本模块状态
 * （头由主线程合成，代理经 WorkerParams 传值）。
 * 对照源：Config.FallbackUserAgent（无浏览器头时使用）；Config.Proxy（ProxyType System/Direct/Custom）；
 * Config.UserCredentials（按主机匹配，下载自带 Authentication 优先）。
 */

import { AuthenticationInfo, ProxyInfo } from '../../model/DownloadTypes';

/** 与 Config.UserCredential 同形（避免本模块依赖 Config 产生环） */
export interface SavedCredential {
  host: string;
  user: string;
  password: string;
}

/** 设置/下载记录侧类型（仅类型引用，host 单测转译时省略该 import） */
export type ProxySetting = ProxyInfo;
export type AuthSetting = AuthenticationInfo;

/** 传给 HttpClient 的代理决策：mode 0=系统代理 1=直连 2=自定义 */
export interface TransportProxy {
  mode: number;
  host: string;
  port: number;
  user: string;
  password: string;
}

export const PROXY_SYSTEM: number = 0;
export const PROXY_DIRECT: number = 1;
export const PROXY_CUSTOM: number = 2;

export const BUILTIN_USER_AGENT: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/97.0.4692.99 Safari/537.36';

let fallbackUserAgent: string = BUILTIN_USER_AGENT;
let globalProxy: TransportProxy = { mode: PROXY_SYSTEM, host: '', port: 0, user: '', password: '' };
let savedCredentials: SavedCredential[] = [];

export function configureTransport(userAgent: string, proxy: ProxySetting, credentials: SavedCredential[]): void {
  const ua: string = userAgent.trim();
  fallbackUserAgent = ua.length > 0 && !hasLineBreak(ua) ? ua : BUILTIN_USER_AGENT;
  globalProxy = toTransportProxy(proxy);
  savedCredentials = credentials.slice();
}

export function currentFallbackUserAgent(): string {
  return fallbackUserAgent;
}

export function currentGlobalProxy(): TransportProxy {
  return copyProxy(globalProxy);
}

/** 单任务代理：新建下载"更多"选了直连/自定义时覆盖全局；System（缺省）跟随设置页全局代理 */
export function resolveProxy(perDownload: ProxySetting | null): TransportProxy {
  const type: number | undefined = perDownload?.proxyType;
  if (perDownload !== null && type !== undefined && type !== PROXY_SYSTEM) {
    return toTransportProxy(perDownload);
  }
  return copyProxy(globalProxy);
}

function toTransportProxy(proxy: ProxySetting): TransportProxy {
  const host: string = (proxy.host ?? '').trim();
  const port: number = Number.isSafeInteger(proxy.port) ? proxy.port : 0;
  let mode: number = proxy.proxyType;
  if (mode !== PROXY_DIRECT && mode !== PROXY_CUSTOM) {
    mode = PROXY_SYSTEM;
  }
  // 自定义但主机/端口无效：按直连处理，避免每次请求都失败
  if (mode === PROXY_CUSTOM && (host.length === 0 || port <= 0 || port > 65535 || hasLineBreak(host))) {
    mode = PROXY_DIRECT;
  }
  return {
    mode: mode,
    host: mode === PROXY_CUSTOM ? host : '',
    port: mode === PROXY_CUSTOM ? port : 0,
    user: mode === PROXY_CUSTOM ? (proxy.userName ?? '') : '',
    password: mode === PROXY_CUSTOM ? (proxy.password ?? '') : ''
  };
}

function copyProxy(p: TransportProxy): TransportProxy {
  return { mode: p.mode, host: p.host, port: p.port, user: p.user, password: p.password };
}

/** URL 主机名（小写，去端口/用户信息）；无法解析返回 '' */
export function hostOfUrl(url: string): string {
  let rest: string = url.trim();
  const scheme: number = rest.indexOf('://');
  if (scheme >= 0) {
    rest = rest.slice(scheme + 3);
  }
  let end: number = rest.length;
  const stops: string[] = ['/', '?', '#'];
  for (let i = 0; i < stops.length; i++) {
    const at: number = rest.indexOf(stops[i]);
    if (at >= 0 && at < end) {
      end = at;
    }
  }
  let authority: string = rest.slice(0, end);
  const at: number = authority.lastIndexOf('@');
  if (at >= 0) {
    authority = authority.slice(at + 1);
  }
  if (authority.startsWith('[')) {
    const close: number = authority.indexOf(']');
    return close > 0 ? authority.slice(0, close + 1).toLowerCase() : '';
  }
  const colon: number = authority.indexOf(':');
  if (colon >= 0) {
    authority = authority.slice(0, colon);
  }
  return authority.toLowerCase();
}

/** 设置页保存的凭据按主机匹配（凭据主机可写成 example.com 或 https://example.com/…） */
export function savedCredentialFor(url: string): SavedCredential | null {
  const host: string = hostOfUrl(url);
  if (host.length === 0) {
    return null;
  }
  for (let i = 0; i < savedCredentials.length; i++) {
    const c: SavedCredential = savedCredentials[i];
    const entry: string = c.host.indexOf('://') >= 0 ? hostOfUrl(c.host) : hostOfUrl('x://' + c.host);
    if (entry.length > 0 && entry === host && c.user.length > 0) {
      return c;
    }
  }
  return null;
}

/** Authorization 值：下载自带认证优先，其次设置页凭据；都没有返回 '' */
export function authorizationFor(url: string, auth: AuthSetting | null): string {
  if (auth !== null && auth !== undefined && typeof auth.userName === 'string' && auth.userName.length > 0) {
    return basicAuthorization(auth.userName, auth.password ?? '');
  }
  const saved: SavedCredential | null = savedCredentialFor(url);
  if (saved !== null) {
    return basicAuthorization(saved.user, saved.password);
  }
  return '';
}

export function basicAuthorization(user: string, password: string): string {
  return 'Basic ' + base64Utf8(user + ':' + password);
}

const B64: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

export function base64Utf8(text: string): string {
  const bytes: number[] = [];
  for (let i = 0; i < text.length; i++) {
    let code: number = text.charCodeAt(i);
    if (code >= 0xd800 && code <= 0xdbff && i + 1 < text.length) {
      const low: number = text.charCodeAt(i + 1);
      if (low >= 0xdc00 && low <= 0xdfff) {
        code = 0x10000 + ((code - 0xd800) << 10) + (low - 0xdc00);
        i++;
      }
    }
    if (code < 0x80) {
      bytes.push(code);
    } else if (code < 0x800) {
      bytes.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
    } else if (code < 0x10000) {
      bytes.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
    } else {
      bytes.push(0xf0 | (code >> 18), 0x80 | ((code >> 12) & 0x3f), 0x80 | ((code >> 6) & 0x3f),
        0x80 | (code & 0x3f));
    }
  }
  let out: string = '';
  for (let i = 0; i < bytes.length; i += 3) {
    const b0: number = bytes[i];
    const b1: number = i + 1 < bytes.length ? bytes[i + 1] : 0;
    const b2: number = i + 2 < bytes.length ? bytes[i + 2] : 0;
    out += B64.charAt(b0 >> 2);
    out += B64.charAt(((b0 & 3) << 4) | (b1 >> 4));
    out += i + 1 < bytes.length ? B64.charAt(((b1 & 15) << 2) | (b2 >> 6)) : '=';
    out += i + 2 < bytes.length ? B64.charAt(b2 & 63) : '=';
  }
  return out;
}

/** Last-Modified（RFC 7231 IMF-fixdate 等 Date.parse 可识别格式）→ 毫秒；无效返回 -1 */
export function parseHttpDate(value: string): number {
  const v: string = value.trim();
  if (v.length === 0) {
    return -1;
  }
  const ms: number = Date.parse(v);
  return Number.isFinite(ms) && ms > 0 ? ms : -1;
}

function hasLineBreak(value: string): boolean {
  return value.indexOf('\r') >= 0 || value.indexOf('\n') >= 0 || value.indexOf('\u0000') >= 0;
}
