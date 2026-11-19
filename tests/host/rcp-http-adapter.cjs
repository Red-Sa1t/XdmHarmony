'use strict';
// Test-only bridge: production ManifestClient speaks RCP (Session per hop, autoRedirect=false,
// body bound through onDownloadProgress), while the manifest suites keep their established
// @ohos.net.http-shaped fakes. Each Session wraps exactly one fake HttpRequest; cancel/close map
// to a single destroy so the existing "released once" assertions keep their meaning.
function rcpOverHttp(http) {
  let sequence = 0;
  class Request {
    constructor(url, method, headers) {
      this.url = url; this.method = method; this.headers = headers; this.id = 'rcp-' + (++sequence);
    }
  }
  function createSession(configuration) {
    const requestConfiguration = (configuration && configuration.requestConfiguration) || {};
    const transfer = requestConfiguration.transfer || {};
    const timeout = transfer.timeout || {};
    const handlers = (requestConfiguration.tracing && requestConfiguration.tracing.httpEventsHandler) || {};
    const inner = http.createHttp();
    let released = false, rejectFetch;
    const release = () => { if (!released) { released = true; inner.destroy(); } };
    return {
      fetch(outgoing) {
        const options = {
          method: outgoing.method, header: outgoing.headers, usingCache: false,
          expectDataType: http.HttpDataType.ARRAY_BUFFER,
          connectTimeout: timeout.connectMs, readTimeout: timeout.transferMs,
          maxRedirects: transfer.autoRedirect === false ? 0 : 30,
          onProgress: handlers.onDownloadProgress
        };
        return new Promise((resolve, reject) => {
          rejectFetch = reject;
          Promise.resolve(inner.request(outgoing.url, options)).then(result => resolve({
            request: outgoing, statusCode: result.responseCode, headers: result.header, body: result.result
          }), reject);
        });
      },
      // RCP cancel rejects the pending fetch (1007900042 = 1007900000 + CURLE_ABORTED_BY_CALLBACK).
      cancel() { if (rejectFetch) rejectFetch({ code: 1007900042 }); release(); },
      close() { release(); }
    };
  }
  return { Request, createSession };
}

module.exports = { rcpOverHttp };
