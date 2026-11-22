/* 2026-11-22：设置页代理 → rcp 会话代理配置（HLS/DASH 清单与分段请求）。rcp 仅作类型引用。 */
import { rcp } from '@kit.RemoteCommunicationKit';
import { currentGlobalProxy, TransportProxy, PROXY_CUSTOM, PROXY_DIRECT } from '../net/TransportPolicy';

/** 2026-11-22：设置页代理 → rcp 代理配置（系统/直连/自定义 http://[user:pass@]host:port） */
export function rcpProxyOf(proxy: TransportProxy): rcp.ProxyConfiguration {
  if (proxy.mode === PROXY_DIRECT) {
    return 'no-proxy';
  }
  if (proxy.mode === PROXY_CUSTOM) {
    const auth: string = proxy.user.length > 0
      ? encodeURIComponent(proxy.user) + ':' + encodeURIComponent(proxy.password) + '@' : '';
    const web: rcp.WebProxy = { url: 'http://' + auth + proxy.host + ':' + String(proxy.port) };
    return web;
  }
  return 'system';
}

export function currentRcpProxy(): rcp.ProxyConfiguration {
  return rcpProxyOf(currentGlobalProxy());
}
