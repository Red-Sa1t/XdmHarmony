import { url } from '@kit.ArkTS';
import { HLS_MAX_URL_CHARS } from './HlsModel';

/*
 * Platform adapter. Reference resolution is RFC 3986 section 5.2 in plain string operations
 * (merge + remove_dot_segments), so signed query/path encoding is kept byte-for-byte and the
 * result does not depend on the platform's base-URL handling: on the target device
 * url.URL.parseURL('./', 'https://h/a/b.mpd') kept 'b.mpd' as a directory (2026-11-06,
 * DASH BaseURL "./" -> every segment 404). The SDK only validates/normalizes the final
 * absolute URL, which is parsed without a base.
 */

const ABSOLUTE_HTTP: RegExp = new RegExp('^(https?:)//([^/?#]*)([^?#]*)(\\?[^#]*)?(#.*)?$', 'i');
const REFERENCE_PARTS: RegExp = new RegExp('^([^?#]*)(\\?[^#]*)?(#.*)?$');

/** RFC 3986 5.2.4. */
export function removeDotSegments(path: string): string {
  let input: string = path;
  const output: string[] = [];
  while (input.length > 0) {
    if (input.startsWith('../')) {
      input = input.substring(3);
    } else if (input.startsWith('./')) {
      input = input.substring(2);
    } else if (input.startsWith('/./')) {
      input = input.substring(2);
    } else if (input === '/.') {
      input = '/';
    } else if (input.startsWith('/../')) {
      input = input.substring(3);
      output.pop();
    } else if (input === '/..') {
      input = '/';
      output.pop();
    } else if (input === '.' || input === '..') {
      input = '';
    } else {
      const start: number = input.startsWith('/') ? 1 : 0;
      let end: number = input.indexOf('/', start);
      if (end < 0) { end = input.length; }
      output.push(input.substring(0, end));
      input = input.substring(end);
    }
  }
  return output.join('');
}

/** RFC 3986 5.2.2 target for an http(s) base; references were pre-validated by the caller. */
function resolveReferenceText(base: string, reference: string): string {
  if (new RegExp('^[A-Za-z][A-Za-z0-9+.-]*:').test(reference)) {
    const scheme: string = reference.substring(0, reference.indexOf(':') + 1);
    const rest: RegExpExecArray | null = REFERENCE_PARTS.exec(reference.substring(scheme.length));
    if (rest === null) { throw new Error('Invalid HLS URL'); }
    const pathPart: string = rest[1];
    const authorityEnd: number = pathPart.startsWith('//') ? pathPart.indexOf('/', 2) : -1;
    const authority: string = pathPart.startsWith('//')
      ? (authorityEnd < 0 ? pathPart : pathPart.substring(0, authorityEnd)) : '';
    const path: string = pathPart.substring(authority.length);
    return scheme + authority + removeDotSegments(path) + (rest[2] ?? '') + (rest[3] ?? '');
  }
  const origin: RegExpExecArray | null = ABSOLUTE_HTTP.exec(base);
  if (origin === null) { throw new Error('Invalid HLS base URL'); }
  const scheme: string = origin[1];
  const authority: string = origin[2];
  const basePath: string = origin[3];
  const baseQuery: string = origin[4] ?? '';
  if (reference.startsWith('//')) {
    return resolveReferenceText(base, scheme + reference);
  }
  const parts: RegExpExecArray | null = REFERENCE_PARTS.exec(reference);
  if (parts === null) { throw new Error('Invalid HLS URL'); }
  const refPath: string = parts[1];
  const refQuery: string | undefined = parts[2];
  const refFragment: string = parts[3] ?? '';
  let path: string;
  let query: string;
  if (refPath.length === 0) {
    path = basePath;
    query = refQuery !== undefined ? refQuery : baseQuery;
  } else {
    if (refPath.startsWith('/')) {
      path = removeDotSegments(refPath);
    } else {
      const merged: string = basePath.length === 0
        ? '/' + refPath : basePath.substring(0, basePath.lastIndexOf('/') + 1) + refPath;
      path = removeDotSegments(merged);
    }
    query = refQuery ?? '';
  }
  return scheme + '//' + authority + path + query + refFragment;
}

export function resolveHlsUrl(base: string, reference: string): string {
  try {
    if (base.length === 0 || reference.length === 0 || base !== base.trim() || reference !== reference.trim() ||
      base.indexOf('{$') >= 0 || reference.indexOf('{$') >= 0 ||
      base.indexOf('\\') >= 0 || reference.indexOf('\\') >= 0 || base.length > HLS_MAX_URL_CHARS ||
      reference.length > HLS_MAX_URL_CHARS || new RegExp('[\\x00-\\x1f\\x7f]').test(base) ||
      new RegExp('[\\x00-\\x1f\\x7f]').test(reference)) {
      throw new Error('Invalid HLS URL');
    }
    // URL implementations can repair an empty authority (https:///host); that changes the requested resource.
    if (!new RegExp('^https?://[^/\\\\?#\\s]+', 'i').test(base) ||
      (new RegExp('^[A-Za-z][A-Za-z0-9+.-]*:').test(reference) &&
      !new RegExp('^https?://[^/\\\\?#\\s]+', 'i').test(reference)) ||
      (reference.startsWith('//') && !new RegExp('^//[^/\\\\?#\\s]+').test(reference))) {
      throw new Error('Invalid HLS authority');
    }
    const origin: url.URL = url.URL.parseURL(base);
    if ((origin.protocol !== 'http:' && origin.protocol !== 'https:') || origin.hostname.length === 0) {
      throw new Error('Invalid HLS base URL');
    }
    const target: string = resolveReferenceText(base, reference);
    const resolved: url.URL = url.URL.parseURL(target);
    if ((resolved.protocol !== 'http:' && resolved.protocol !== 'https:') || resolved.hostname.length === 0 ||
      resolved.href.length > HLS_MAX_URL_CHARS) {
      throw new Error('Invalid HLS URL');
    }
    return resolved.href;
  } catch (e) {
    // Neither the URL nor SDK exceptions may expose signed queries or credentials.
    throw new Error('HLS URL could not be resolved');
  }
}
