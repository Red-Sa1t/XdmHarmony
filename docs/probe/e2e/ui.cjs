// Emulator UI helper. usage:
//   node ui.cjs shot <name>            screenshot -> shots/<name>.png
//   node ui.cjs dump [regex]           list text/button nodes
//   node ui.cjs tap <text> [type]      click center of first node with exact text
//   node ui.cjs click <x> <y>          raw click
//   node ui.cjs row <rowText> [click]  show row cells / click its last button
const {execFileSync}=require("child_process");const fs=require("fs");const path=require("path");
const H="D:/Tools/DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe";const T=["-t",process.env.XDM_T||"127.0.0.1:5555"];
const dir=process.env.XDM_E2E_WORK||process.cwd();fs.mkdirSync(path.join(dir,"shots"),{recursive:true});const hdc=a=>execFileSync(H,T.concat(a)).toString();
// recv into an absolute local path: run in the target folder with a bare file name (a restarted hdc server
// joins the client cwd onto absolute local paths)
const recv=(remote,local)=>execFileSync(H,T.concat(["file","recv",remote,path.basename(local)]),{cwd:path.dirname(local)}).toString();
function nodes(){hdc(["shell","uitest dumpLayout -b com.neuohos.xdm -p /data/local/tmp/l.json"]);recv("/data/local/tmp/l.json",path.join(dir,"layout.json"));
 const j=JSON.parse(fs.readFileSync(path.join(dir,"layout.json"),"utf8"));const all=[];
 (function w(n){const a=n.attributes||{};const m=/\[(\d+),(\d+)\]\[(\d+),(\d+)\]/.exec(a.bounds||"");if(m)all.push({t:a.type,x:a.text,id:a.id,b:m.slice(1).map(Number)});(n.children||[]).forEach(w);})(j);return all;}
const click=(x,y)=>hdc(["shell",`uitest uiInput click ${x} ${y}`]);
const ctr=b=>[(b[0]+b[2])>>1,(b[1]+b[3])>>1];
const [cmd,a1,a2]=process.argv.slice(2);
if(cmd==="shot"){hdc(["shell",`uitest screenCap -p /data/local/tmp/${a1}.png`]);recv(`/data/local/tmp/${a1}.png`,path.join(dir,"shots",a1+".png"));console.log("shots/"+a1+".png");}
else if(cmd==="dump"){const re=a1?new RegExp(a1):null;for(const n of nodes())if((n.x||n.t==="Button")&&(!re||re.test(n.x||"")||re.test(n.t)))console.log(n.t,"|",n.x,"|",n.b.join(","),"|",n.id||"");}
else if(cmd==="tap"){const n=nodes().find(n=>n.x===a1&&(!a2||n.t===a2));if(!n){console.log("not found:",a1);process.exit(1);}click(...ctr(n.b));console.log("tapped",a1);}
else if(cmd==="click"){click(a1,a2);}
else if(cmd==="row"){const all=nodes();const r=all.find(n=>n.x===a1&&n.t==="Text"&&n.b[0]<all.reduce((m,n)=>Math.max(m,n.b[2]),0)*0.5);if(!r){console.log("row not found");process.exit(1);}
 const cy=(r.b[1]+r.b[3])/2;const cells=all.filter(e=>e.b[1]<=cy&&e.b[3]>=cy&&e.b[0]>r.b[2]-10&&(e.x||e.t==="Button"||e.t==="Progress"));
 console.log(cells.map(c=>c.t+":"+c.x).join(" | "));if(a2==="click"){const b=cells.filter(c=>c.t==="Button").pop();click(...ctr(b.b));console.log("clicked",b.x);}}
