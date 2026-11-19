#!/usr/bin/env node
/*
 * U6.1 主机侧流量模拟与自验脚本（设计书 u6-1-bridge-eight-routes-DESIGN.md §5.8 / §7-[P]-5）。
 * 用途：AI 在设备连接时代跑——经 `hdc fport tcp:18597 tcp:8597` 转发后，本脚本以扩展
 * connector.js 的 fetch 形态（POST 不带 Content-Type/Connection 头、每请求新 TCP 连接）
 * 逐一打满八路由并断言，替代真实浏览器扩展完成 U6.1 的"Node 模拟流量全绿"验收。
 *
 * 运行前提：
 *   1. 设备已连接且探针应用已安装运行（EntryAbility 常驻启动 8597 桥）；
 *   2. 主机已执行：hdc fport tcp:18597 tcp:8597（清理：hdc fport rm tcp:18597）。
 *   3. node docs/probe/P6-U1-node-client.js（在 XdmHarmony 工程根目录）。
 *
 * 判定口径（设计书 §0-1）：八条已知路由业务成功一律 200+sync JSON 应答体；未知路径与
 * 坏 JSON 请求 = **服务端关闭连接且零应答字节 = 正确**（U0.3 的 404 中间态已废止）。
 *
 * 十步（§5.8）：
 *   ①GET /sync 基线（八字段+videoList 空） ②POST /clear→200 ③POST /media（video/mp4+5MB）
 *   →/sync videoList=1 ④POST /tab-update→text 回写 ⑤POST /vid 未命中/命中 ⑥POST /download
 *   （filename 形）→200 ⑦POST /args 两组→列表增至 2 ⑧POST /link 数组→200 ⑨GET /sync?x=1
 *   →断连零字节 ⑩POST /download 'not json'→断连零字节。
 * 输出：逐项 `PASS/FAIL <编号> <观测>`，末行 `SUMMARY pass=N fail=M`；
 *   process.exitCode = fail>0 ? 1 : 0（退出码 0 = 全绿）。
 */

'use strict';

const net = require('net');

const HOST = '127.0.0.1';
const PORT = 18597;
const TIMEOUT_MS = 10000;

/** 单请求往返：新 TCP 连接 → 发原始字节 → 收应答（CL 完整或连接关闭定界）→ 关闭。
 * 返回 { closed, bytes }；连接层错误 reject（记为该步 FAIL 的 err 观测）。 */
function roundTrip(raw) {
  return new Promise((resolve, reject) => {
    const socket = net.connect({ host: HOST, port: PORT });
    const chunks = [];
    let closed = false;
    let settled = false;
    const finish = () => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      resolve({ closed: closed, bytes: Buffer.concat(chunks) });
    };
    const timer = setTimeout(() => {
      socket.destroy();
      finish();
    }, TIMEOUT_MS);
    socket.on('connect', () => {
      socket.write(raw, () => {
        // 半关闭：客户端请求发完即 shutdown 写半区，服务端 keep-alive 应答仍可达
      });
    });
    socket.on('data', (data) => {
      chunks.push(data);
      const view = splitHead(Buffer.concat(chunks));
      if (view.complete) {
        const cl = headerOf(view, 'content-length');
        const parsed = cl === '' ? -1 : Number(cl);
        if (Number.isFinite(parsed) && parsed >= 0 &&
          Buffer.concat(chunks).length >= view.bodyStart + parsed) {
          socket.end();
          // 给服务端 Connection 判定留出 close 窗口后收尾
          setTimeout(finish, 120);
        }
      }
    });
    socket.on('close', () => {
      closed = true;
      finish();
    });
    socket.on('error', (err) => {
      if (!settled) {
        settled = true;
        clearTimeout(timer);
        reject(err);
      }
    });
  });
}

/** 应答头/体切分（探针侧视图；失败 complete=false）。 */
function splitHead(buf) {
  const text = buf.toString('latin1');
  const idx = text.indexOf('\r\n\r\n');
  if (idx < 0) {
    return { complete: false, headText: '', bodyStart: buf.length, headers: [] };
  }
  const headText = text.slice(0, idx);
  const lines = headText.split('\r\n');
  const headers = [];
  for (let i = 1; i < lines.length; i++) {
    const colon = lines[i].indexOf(':');
    if (colon > 0) {
      headers.push([lines[i].slice(0, colon).trim().toLowerCase(),
        lines[i].slice(colon + 1).trim()]);
    }
  }
  return { complete: true, headText: headText, bodyStart: idx + 4, headers: headers };
}

function headerOf(view, nameLower) {
  for (const pair of view.headers) {
    if (pair[0] === nameLower) {
      return pair[1];
    }
  }
  return '';
}

function statusOf(view) {
  const tokens = view.headText.split(' ');
  return tokens.length > 1 ? Number(tokens[1]) : -1;
}

/** GET 请求（无 Connection 头——curl 默认形态；服务端缺省 close 应答后断连）。 */
function getRaw(path) {
  return 'GET ' + path + ' HTTP/1.1\r\nHost: 127.0.0.1:8597\r\n\r\n';
}

/** POST 请求（connector.js fetch 形态：Host+Content-Length，无 Content-Type/Connection）。 */
function postRaw(path, bodyText) {
  const body = Buffer.from(bodyText, 'utf8');
  const head = 'POST ' + path + ' HTTP/1.1\r\nHost: 127.0.0.1:8597\r\n' +
    'Content-Length: ' + body.length + '\r\n\r\n';
  return Buffer.concat([Buffer.from(head, 'latin1'), body]);
}

/** 断言记账 */
let pass = 0;
let fail = 0;
function check(label, ok, observed) {
  if (ok) {
    pass++;
    console.log('PASS ' + label + ' ' + observed);
  } else {
    fail++;
    console.log('FAIL ' + label + ' ' + observed);
  }
}

/** sync 应答体观测 */
function syncBodyOf(bytes) {
  const view = splitHead(bytes);
  if (!view.complete) {
    return null;
  }
  const bodyText = bytes.slice(view.bodyStart).toString('utf8');
  try {
    return JSON.parse(bodyText);
  } catch (e) {
    return null;
  }
}

async function main() {
  console.log('P6-U1 node client -> ' + HOST + ':' + PORT +
    ' (前置：hdc fport tcp:18597 tcp:8597)');

  // ①GET /sync 基线：200 + JSON 八字段 + videoList 数组
  try {
    const r = await roundTrip(getRaw('/sync'));
    const view = splitHead(r.bytes);
    const body = syncBodyOf(r.bytes);
    const fieldsOk = body !== null &&
      JSON.stringify(Object.keys(body)) === JSON.stringify(
        ['enabled', 'fileExts', 'blockedHosts', 'requestFileExts', 'mediaTypes',
          'tabsWatcher', 'videoList', 'matchingHosts']);
    const listOk = body !== null && Array.isArray(body.videoList);
    check('T01-sync-baseline',
      statusOf(view) === 200 && fieldsOk && listOk && body.videoList.length === 0,
      'status=' + statusOf(view) + ' fields=' + (body === null ? 'null' :
        Object.keys(body).join('|')) + ' videoList=' + (listOk ? body.videoList.length : 'not-array'));
  } catch (err) {
    check('T01-sync-baseline', false, 'err=' + err.message);
  }

  // ②POST /clear：200（body {} 不解析也成功）
  try {
    const r = await roundTrip(postRaw('/clear', '{}'));
    const view = splitHead(r.bytes);
    check('T02-clear', statusOf(view) === 200, 'status=' + statusOf(view));
  } catch (err) {
    check('T02-clear', false, 'err=' + err.message);
  }

  // ③POST /media（video/mp4 + 5MB Content-Length）→ 再 GET /sync：videoList=1、text 末缀 .mp4
  const mediaBody = JSON.stringify({
    url: 'https://media.example.com/v/clip.mp4',
    file: 'Node Clip',
    method: 'GET',
    tabId: '200',
    tabUrl: 'https://www.youtube.com/watch?v=node',
    cookie: 'a=b',
    requestHeaders: { 'Referer': ['https://media.example.com/page'], 'User-Agent': ['NodeUA'] },
    responseHeaders: { 'Content-Type': ['video/mp4'], 'Content-Length': ['5242880'] }
  });
  try {
    const r = await roundTrip(postRaw('/media', mediaBody));
    const view = splitHead(r.bytes);
    const s = await roundTrip(getRaw('/sync'));
    const body = syncBodyOf(s.bytes);
    const first = body !== null && body.videoList.length > 0 ? body.videoList[0] : null;
    check('T03-media-sniff',
      statusOf(view) === 200 && body !== null && body.videoList.length === 1 &&
        first !== null && first.text === 'Node Clip.mp4' &&
        typeof first.info === 'string' && first.info.indexOf('[MP4]') === 0,
      'status=' + statusOf(view) + ' videoList=' + (body === null ? 'null' : body.videoList.length) +
        ' text=' + (first === null ? 'none' : first.text) +
        ' info=' + (first === null ? 'none' : first.info));
  } catch (err) {
    check('T03-media-sniff', false, 'err=' + err.message);
  }

  // ④POST /tab-update → text 回写（tabUrl 匹配 ③ 的条目，扩展名保留）
  const tabBody = JSON.stringify({
    tabUrl: 'https://www.youtube.com/watch?v=node', tabTitle: 'Node New Title'
  });
  try {
    const r = await roundTrip(postRaw('/tab-update', tabBody));
    const s = await roundTrip(getRaw('/sync'));
    const body = syncBodyOf(s.bytes);
    const first = body !== null && body.videoList.length > 0 ? body.videoList[0] : null;
    check('T04-tab-update',
      statusOf(splitHead(r.bytes)) === 200 && first !== null &&
        first.text === 'Node New Title.mp4',
      'status=' + statusOf(splitHead(r.bytes)) + ' text=' + (first === null ? 'none' : first.text));
  } catch (err) {
    check('T04-tab-update', false, 'err=' + err.message);
  }

  // ⑤POST /vid 未命中（200 列表不变）与命中（200；auto=false→对话框事件，主机侧不可观测仅验应答）
  try {
    const miss = await roundTrip(postRaw('/vid', JSON.stringify({ vid: 'no-such-vid' })));
    const s1 = await roundTrip(getRaw('/sync'));
    const list1 = syncBodyOf(s1.bytes);
    const listBody = list1 !== null && list1.videoList.length > 0 ? list1.videoList[0] : null;
    const hit = await roundTrip(postRaw('/vid',
      JSON.stringify({ vid: listBody === null ? '' : listBody.id })));
    const s2 = await roundTrip(getRaw('/sync'));
    const list2 = syncBodyOf(s2.bytes);
    check('T05-vid-miss-hit',
      statusOf(splitHead(miss.bytes)) === 200 && statusOf(splitHead(hit.bytes)) === 200 &&
        list1 !== null && list2 !== null && list1.videoList.length === 1 &&
        list2.videoList.length === 1,
      'missStatus=' + statusOf(splitHead(miss.bytes)) + ' hitStatus=' +
        statusOf(splitHead(hit.bytes)) + ' counts=' +
        (list1 === null ? '?' : list1.videoList.length) + '/' +
        (list2 === null ? '?' : list2.videoList.length));
  } catch (err) {
    check('T05-vid-miss-hit', false, 'err=' + err.message);
  }

  // ⑥POST /download（chrome filename 形；responseHeaders Content-Length 发 number 形
  //   =app.js:225-229 真实契约 fz=+size，R2-F1 回归观测点）：200（auto=false 默认不触引擎链）
  const downloadBody = JSON.stringify({
    url: 'https://dl.example.com/node-setup.exe',
    cookie: 'sid=1',
    requestHeaders: { 'User-Agent': ['NodeUA'], 'Cookie': ['sid=1'] },
    responseHeaders: { 'Content-Length': [102400], 'Content-Type': ['application/octet-stream'] },
    filename: 'node-setup.exe',
    fileSize: 102400,
    mimeType: 'application/octet-stream'
  });
  try {
    const r = await roundTrip(postRaw('/download', downloadBody));
    const view = splitHead(r.bytes);
    const body = syncBodyOf(r.bytes);
    check('T06-download',
      statusOf(view) === 200 && body !== null,
      'status=' + statusOf(view) + ' syncJson=' + (body !== null));
  } catch (err) {
    check('T06-download', false, 'err=' + err.message);
  }

  // ⑦POST /args 两组：--media-tab-url 组回写标题；--url --media --known-* 组列表 +1（增至 2）
  const argsTab = JSON.stringify(['xdm+app://x', '--media-tab-url',
    'https://www.youtube.com/watch?v=node', '--media-tab-title', 'Args Node Title']);
  const argsMedia = JSON.stringify(['--url', 'https://h/v/args-node.mp4', '--media',
    '--known-mime-type', 'video/mp4', '--known-file-size', '2097152']);
  try {
    const r1 = await roundTrip(postRaw('/args', argsTab));
    const s1 = await roundTrip(getRaw('/sync'));
    const list1 = syncBodyOf(s1.bytes);
    const first = list1 !== null && list1.videoList.length > 0 ? list1.videoList[0] : null;
    const tabOk = statusOf(splitHead(r1.bytes)) === 200 && first !== null &&
      first.text === 'Args Node Title.mp4';
    const r2 = await roundTrip(postRaw('/args', argsMedia));
    const s2 = await roundTrip(getRaw('/sync'));
    const list2 = syncBodyOf(s2.bytes);
    check('T07-args-chain',
      tabOk && statusOf(splitHead(r2.bytes)) === 200 && list2 !== null &&
        list2.videoList.length === 2,
      'tabStatus=' + statusOf(splitHead(r1.bytes)) + ' tabText=' +
        (first === null ? 'none' : first.text) + ' mediaStatus=' +
        statusOf(splitHead(r2.bytes)) + ' videoList=' +
        (list2 === null ? '?' : list2.videoList.length));
  } catch (err) {
    check('T07-args-chain', false, 'err=' + err.message);
  }

  // ⑧POST /link 数组：200（第二项空 url 跳过；pending 列表主机侧不可观测，仅验应答）。
  //   每元素必带 requestHeaders（buildBridgeMessage 对 null→throw 断连，1:1 源 Select 内
  //   RemoveBlockedHeaders NRE——映射先于空 url 跳过，COLD-F1）
  const linkBody = JSON.stringify([
    { url: 'https://h/f/node-pack.zip', file: 'node-pack.zip',
      requestHeaders: { 'User-Agent': ['NodeUA'] } },
    { url: '', file: 'x', requestHeaders: { 'User-Agent': ['NodeUA'] } }
  ]);
  try {
    const r = await roundTrip(postRaw('/link', linkBody));
    const view = splitHead(r.bytes);
    check('T08-link', statusOf(view) === 200, 'status=' + statusOf(view));
  } catch (err) {
    check('T08-link', false, 'err=' + err.message);
  }

  // ⑨GET /sync?x=1（未知路径）：连接关闭且零应答字节 = 正确
  try {
    const r = await roundTrip(getRaw('/sync?x=1'));
    check('T09-unknown-path-closed',
      r.closed && r.bytes.length === 0,
      'closed=' + r.closed + ' bytes=' + r.bytes.length);
  } catch (err) {
    // 连接被拒/重置同样视为"无应答"形态之一，但需人工核对 fport；按 FAIL 记录 err
    check('T09-unknown-path-closed', false, 'err=' + err.message);
  }

  // ⑩POST /download 体 'not json'（坏 JSON 门）：连接关闭且零应答字节 = 正确
  try {
    const r = await roundTrip(postRaw('/download', 'not json'));
    check('T10-bad-json-closed',
      r.closed && r.bytes.length === 0,
      'closed=' + r.closed + ' bytes=' + r.bytes.length);
  } catch (err) {
    check('T10-bad-json-closed', false, 'err=' + err.message);
  }

  console.log('SUMMARY pass=' + pass + ' fail=' + fail);
  process.exitCode = fail > 0 ? 1 : 0;
}

main().catch((err) => {
  console.error('FATAL ' + err.message);
  process.exitCode = 2;
});
