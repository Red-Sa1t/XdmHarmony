#!/usr/bin/env node
/*
 * P1-U2 主机侧测试源（探针运行手册配套，Node >= 14，零依赖单文件）。
 * 用法：node P1-U2-download-server.js [port]   端口参数化，默认 8080；绑定 0.0.0.0（供模拟器/真机经局域网访问）。
 * 启动指引与 P0-U2 手册口径一致（主机侧 PowerShell/cmd 运行，设备内禁用 127.0.0.1，填主机局域网 IP）。
 * 路由（设计书 §1-#18 契约）：
 *   GET /big.bin           无 Range → 200 + Content-Length: 4194304 + Accept-Ranges: bytes（一次性整流）；
 *                          带 Range: bytes=s- 或 bytes=s-e → 206 + Content-Range + 对应区间
 *   GET /slow.bin?ms=40    同规格确定性流，但每 64KB 块间隔 ms 毫秒（默认 40，64 块 ≈ 2.6s——
 *                          使 S5 暂停步确定性落地；支持 Range 206，引擎续传路径同判定）
 *   GET /echo              200 text/plain，单行 acceptEncoding=<实收头值或 absent>（P0-U2 兼容路由）
 *   GET /redirect          302 + Location: http://<实收 host>/final（S2 观测 headersReceive 3xx 跳点）
 *   GET /final             200 text/plain，单行 url=... cookie=... acceptEncoding=...（回显观测）
 *   其余                   404
 * 字节锚：第 o 字节属于块 floor(o/65536)，值为 块号 % 251——与 ProbeDownloadLogic.ets
 * expectedByteAt / P0-U2-echo-server.js makeSlice 三处同值（S7 字节抽查的比对基准）。
 * 每个请求向控制台打印实收 method/path/Range/Cookie，作 hilog 之外的第二证据。
 */

'use strict';

const http = require('http');

const BIG_BIN_BYTES = 4194304; // 与 ProbeDownloadLogic.ets、EXPECT 表三处同值（verify 比对锚）
const CHUNK_SIZE = 65536;      // 64KB 分块（engine 分块落盘节奏的观测尺度）
const RANGE_RE = new RegExp('^bytes=(\\d+)-(\\d*)$');
const DEFAULT_SLOW_MS = 40;

/** [start, start+length) 区间的确定性字节流：字节 o 属于块 floor(o/64KB)，值为 块号 % 251 */
function makeSlice(start, length) {
  const buf = Buffer.alloc(length);
  for (let i = 0; i < length; i++) {
    buf[i] = Math.floor((start + i) / CHUNK_SIZE) % 251;
  }
  return buf;
}

/** 回显用头值：absent 兜底 + 去空白（保证单 token） */
function echoValue(value) {
  if (value === undefined || value === null || String(value).length === 0) {
    return 'absent';
  }
  return String(value).replace(new RegExp('\\s+', 'g'), '');
}

function sendText(res, status, body) {
  res.writeHead(status, {
    'Content-Type': 'text/plain',
    'Content-Length': String(Buffer.byteLength(body))
  });
  res.end(body);
}

/** 确定性流响应：闭区间 [start, end]；delayMs>0 时逐 64KB 块定时写出（块对齐切分） */
function streamBin(res, status, start, end, delayMs, extraHeaders) {
  const length = end - start + 1;
  const headers = Object.assign({
    'Content-Type': 'application/octet-stream',
    'Content-Length': String(length),
    'Accept-Ranges': 'bytes'
  }, extraHeaders || {});
  res.writeHead(status, headers);
  if (delayMs <= 0) {
    res.end(makeSlice(start, length));
    return;
  }
  let offset = start;
  function writeNext() {
    if (res.destroyed) {
      return;
    }
    if (offset > end) {
      res.end();
      return;
    }
    const chunkLen = Math.min(CHUNK_SIZE - (offset % CHUNK_SIZE), end - offset + 1);
    res.write(makeSlice(offset, chunkLen));
    offset += chunkLen;
    if (offset > end) {
      res.end();
    } else {
      setTimeout(writeNext, delayMs);
    }
  }
  writeNext();
}

const server = http.createServer((req, res) => {
  const rangeHeader = req.headers.range;
  const acceptEncoding = echoValue(req.headers['accept-encoding']);
  const cookie = echoValue(req.headers.cookie);
  console.log('[P1-U2] ' + req.method + ' ' + req.url +
    ' range=' + (rangeHeader === undefined ? 'absent' : rangeHeader) +
    ' cookie=' + cookie +
    ' accept-encoding=' + acceptEncoding +
    ' host=' + (req.headers.host === undefined ? 'absent' : req.headers.host));

  const base = 'http://' + (req.headers.host === undefined ? 'localhost' : req.headers.host);
  let pathname = '';
  let queryMs = DEFAULT_SLOW_MS;
  try {
    const parsed = new URL(req.url, base);
    pathname = parsed.pathname;
    const msParam = parseInt(parsed.searchParams.get('ms'), 10);
    if (!isNaN(msParam) && msParam >= 0) {
      queryMs = msParam;
    }
  } catch (e) {
    pathname = req.url;
  }

  const isBinPath = pathname === '/big.bin' || pathname === '/slow.bin';
  if (isBinPath) {
    const delayMs = pathname === '/slow.bin' ? queryMs : 0;
    const m = rangeHeader === undefined ? null : RANGE_RE.exec(String(rangeHeader));
    if (m !== null) {
      // 206：闭区间 [s, e]；bytes=s- 语义为 s 至末尾（对齐引擎 resumeRangeHeader 的 open-ended 形态）
      const s = parseInt(m[1], 10);
      const e = (m[2] === '' || m[2] === undefined)
        ? BIG_BIN_BYTES - 1
        : Math.min(parseInt(m[2], 10), BIG_BIN_BYTES - 1);
      if (isNaN(s) || s < 0 || s >= BIG_BIN_BYTES || s > e) {
        sendText(res, 416, 'invalid range');
        return;
      }
      streamBin(res, 206, s, e, delayMs, {
        'Content-Range': 'bytes ' + s + '-' + e + '/' + BIG_BIN_BYTES
      });
      return;
    }
    if (rangeHeader !== undefined) {
      // Range 头存在但不可解析：RFC 9110 应 416
      sendText(res, 416, 'unparsable range');
      return;
    }
    streamBin(res, 200, 0, BIG_BIN_BYTES - 1, delayMs, null);
    return;
  }

  if (pathname === '/echo') {
    sendText(res, 200, 'acceptEncoding=' + acceptEncoding);
    return;
  }

  if (pathname === '/redirect') {
    res.writeHead(302, {
      'Location': base + '/final',
      'Content-Length': '0'
    });
    res.end();
    return;
  }

  if (pathname === '/final') {
    sendText(res, 200,
      'url=' + base + '/final' + ' cookie=' + cookie + ' acceptEncoding=' + acceptEncoding);
    return;
  }

  sendText(res, 404, 'not found');
});

const port = parseInt(process.argv[2], 10) || 8080;
server.listen(port, '0.0.0.0', () => {
  console.log('[P1-U2] download server listening on 0.0.0.0:' + port +
    '  (big.bin=' + BIG_BIN_BYTES + 'B, routes: /big.bin /slow.bin?ms=40 /echo /redirect /final)');
  console.log('[P1-U2] probe base url = http://<本机局域网IP>:' + port + '  (设备内禁用 127.0.0.1)');
});
