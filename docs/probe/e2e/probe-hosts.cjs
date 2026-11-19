'use strict';
// Starts every host-side probe source in one process tree (full acceptance runs, 2026-11-13).
//   8083 echo (P0-U2; 8080 is taken on this host)   8081 download (P1-U2/P2/P3/P4-U2/P5)
//   8082 static small files (P4 extension data)     8794 manifest (P6-U4)
//   18766 adaptive (P6-U5/U6)                       8795 DASH (P7-U1)
// For an emulator/device reached through hdc, forward each port with `hdc rport tcp:N tcp:N` and
// use 127.0.0.1 in probe URLs. Usage: node docs/probe/e2e/probe-hosts.cjs
const { spawn } = require('node:child_process');
const path = require('node:path');
const probe = path.resolve(__dirname, '..');
const root = path.resolve(__dirname, '..', '..', '..', '..');
const servers = [
  ['echo', [path.join(probe, 'P0-U2-echo-server.js'), '8083']],
  ['download', [path.join(probe, 'P1-U2-download-server.js'), '8081']],
  ['static', [path.join(root, 'probe-static', 'serve.js')]],
  ['manifest', [path.join(probe, 'P6-U4-manifest-host.cjs'), '--host', '0.0.0.0', '--port', '8794']],
  ['adaptive', [path.join(probe, 'P6-U5-adaptive-host.cjs'), '--host', '0.0.0.0', '--port', '18766']],
  ['dash', [path.join(probe, 'P7-U1-dash-host.cjs'), '--host', '0.0.0.0', '--port', '8795']]
];
const children = servers.map(([name, args]) => {
  const child = spawn(process.execPath, args, { stdio: ['ignore', 'pipe', 'pipe'] });
  const tag = data => data.toString().split('\n').filter(Boolean).forEach(line => console.log(`[${name}] ${line}`));
  child.stdout.on('data', tag); child.stderr.on('data', tag);
  child.on('exit', code => console.log(`[${name}] exited ${code}`));
  return child;
});
const stop = () => { children.forEach(c => c.kill()); process.exit(0); };
process.on('SIGINT', stop); process.on('SIGTERM', stop);
