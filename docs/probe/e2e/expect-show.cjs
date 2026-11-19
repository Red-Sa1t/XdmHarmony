// node docs/probe/e2e/expect-show.cjs <slug-substring> [maxChars]  -> compact view of an EXPECT file
const fs = require('fs'); const path = require('path');
const dir = path.resolve(__dirname, '..'); const max = Number(process.argv[3] || 260);
const f = fs.readdirSync(dir).find(n => n.startsWith('EXPECT-') && n.includes(process.argv[2]));
const j = JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8'));
const s = v => (typeof v === 'string' ? v : JSON.stringify(v)).replace(/\s+/g, ' ');
console.log('#', f);
for (const [k, v] of Object.entries(j)) {
  if (Array.isArray(v)) { console.log('##', k); for (const e of v) console.log('-', s(e).slice(0, max)); }
  else console.log(k + ':', s(v).slice(0, max * 2));
}
