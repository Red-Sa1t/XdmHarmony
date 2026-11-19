#!/usr/bin/env node
/*
 * P0-U2 主机侧测试源（探针运行手册配套，Node >= 14，零依赖单文件）。
 * 用法：node P0-U2-echo-server.js [port]     端口参数化，默认 8080；绑定 0.0.0.0（供模拟器/真机经局域网访问）。
 * 路由（设计书 §2.2 契约）：
 *   GET /big.bin   无 Range → 200 + Content-Length: 4194304 + Accept-Ranges: bytes；
 *                  带 Range: bytes=s- 或 bytes=s-e → 206 + Content-Range: bytes s-e/4194304 + 对应区间字节
 *                  体为确定性字节流：第 k 个 64KB 块填充 k % 251（与 ProbeHttpLogic.BIG_BIN_BYTES 同值锚）
 *   GET /echo      200 text/plain，单行 acceptEncoding=<实收头值或 absent>
 *   GET /redirect  302 + Location: http://<实收 host>/final（绝对地址，规避 client 对相对 Location 的解析差异）
 *   GET /final     200 text/plain，单行 url=http://<实收 host>/final cookie=<实收 Cookie 或 absent> acceptEncoding=<实收值或 absent>
 *   其余           404
 * 每个请求向控制台打印实收 method/path/Range/Cookie/Accept-Encoding，作 hilog 之外的第二证据。
 * 注：回显的头值先去空白（如 "gzip, deflate" → "gzip,deflate"），保证回显体单 token 可被探针
 *     parseEchoBody 按空格切分解析；去空白不改变"是否协商压缩"的观测结论。
 */

'use strict';

const http = require('http');

const BIG_BIN_BYTES = 4194304; // 与 ProbeHttpLogic.ets、EXPECT 表三处同值（verify 比对锚）
const CHUNK_SIZE = 65536;      // 64KB 分块 ≈ 64 块
const RANGE_RE = new RegExp('^bytes=(\\d+)-(\\d*)$');

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

const server = http.createServer((req, res) => {
  const rangeHeader = req.headers.range;
  const acceptEncoding = echoValue(req.headers['accept-encoding']);
  const cookie = echoValue(req.headers.cookie);
  console.log('[P0-U2] ' + req.method + ' ' + req.url +
    ' range=' + (rangeHeader === undefined ? 'absent' : rangeHeader) +
    ' cookie=' + cookie +
    ' accept-encoding=' + acceptEncoding +
    ' host=' + (req.headers.host === undefined ? 'absent' : req.headers.host));

  const base = 'http://' + (req.headers.host === undefined ? 'localhost' : req.headers.host);
  let pathname = '';
  try {
    pathname = new URL(req.url, base).pathname;
  } catch (e) {
    pathname = req.url;
  }

  if (pathname === '/big.bin') {
    const m = rangeHeader === undefined ? null : RANGE_RE.exec(String(rangeHeader));
    if (m !== null) {
      // 206：闭区间 [s, e]；bytes=s- 语义为 s 至末尾（对齐探针 S2/S4 的 Range 用法）
      const s = parseInt(m[1], 10);
      const e = (m[2] === '' || m[2] === undefined)
        ? BIG_BIN_BYTES - 1
        : Math.min(parseInt(m[2], 10), BIG_BIN_BYTES - 1);
      if (isNaN(s) || s < 0 || s >= BIG_BIN_BYTES || s > e) {
        sendText(res, 416, 'invalid range');
        return;
      }
      const length = e - s + 1;
      res.writeHead(206, {
        'Content-Type': 'application/octet-stream',
        'Content-Length': String(length),
        'Content-Range': 'bytes ' + s + '-' + e + '/' + BIG_BIN_BYTES,
        'Accept-Ranges': 'bytes'
      });
      res.end(makeSlice(s, length));
      return;
    }
    if (rangeHeader !== undefined) {
      // Range 头存在但不可解析：RFC 9110 应 416；探针不观测该形态，返回 416 并注释
      sendText(res, 416, 'unparsable range');
      return;
    }
    res.writeHead(200, {
      'Content-Type': 'application/octet-stream',
      'Content-Length': String(BIG_BIN_BYTES),
      'Accept-Ranges': 'bytes'
    });
    res.end(makeSlice(0, BIG_BIN_BYTES));
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
  console.log('[P0-U2] echo server listening on 0.0.0.0:' + port +
    '  (big.bin=' + BIG_BIN_BYTES + 'B, routes: /big.bin /echo /redirect /final)');
  console.log('[P0-U2] probe base url = http://<本机局域网IP>:' + port + '  (设备内禁用 127.0.0.1)');
});
