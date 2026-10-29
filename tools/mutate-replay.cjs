'use strict';
/* 变异台：证明 tools/replay-check.mjs 真的抓得住"桥接形状写错"这一类。
   变异 = 把 KernelSU 那一支退回**传函数对象**（就是这次上机的 bug 本身）。
   还原必须逐字节回到改前，且复跑回绿，否则这个台子自己在污染工作区。 */
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const repo = path.resolve(__dirname, '..');
const B = path.join(repo, 'webui', 'src', 'bridge.js');
const orig = fs.readFileSync(B, 'utf8');

const GOOD = "      try { BRIDGE.exec(full, '{}', name); }";
const BROKEN = "      try { BRIDGE.exec(full, '{}', function (e, o, r) { finish({ errno: e, stdout: o, stderr: r }); }); }";

function sh(args) { return execFileSync('node', args, { cwd: repo, encoding: 'utf8' }); }
function runReplay(file) {
  try { return { code: 0, out: sh([path.join('tools', 'replay-check.mjs'), file]) }; }
  catch (e) {
    const s = (b) => b ? (Buffer.isBuffer(b) ? b.toString('utf8') : String(b)) : '';
    return { code: typeof e.status === 'number' ? e.status : -1,
      out: s(e.buffer && e.buffer.stdout) + s(e.stdout) + s(e.buffer && e.buffer.stderr) + s(e.stderr) + s(e.message) };
  }
}
const fails = (o) => o.split('\n').filter(l => l.trim().startsWith('✗'));

let ok = true;
try {
  const hits = orig.split(GOOD).length - 1;
  if (hits !== 1) { console.log(`✗ 锚点命中 ${hits} 处，预期 1 —— 变异没落地`); process.exit(1); }
  fs.writeFileSync(B, orig.replace(GOOD, BROKEN));
  sh([path.join('tools', 'md3e-build', 'build.mjs')]);           // 只写 dist，不碰 webroot
  const m = runReplay(path.join('webui', 'dist', 'index.html'));
  console.log(`${m.code !== 0 ? '✓' : '✗ 不响'}  变异「exec 第三参退回函数对象」→ 退码 ${m.code}`);
  fails(m.out).slice(0, 5).forEach(l => console.log('     ' + l.trim()));
  if (m.code === 0) ok = false;
} finally {
  fs.writeFileSync(B, orig);
  if (fs.readFileSync(B, 'utf8') !== orig) { console.log('✗ 还原后仍有差异'); ok = false; }
  sh([path.join('tools', 'md3e-build', 'build.mjs'), '--ship']);
  const clean = runReplay(path.join('module', 'webroot', 'index.html'));
  console.log(`${clean.code === 0 && ok ? '✓' : '✗'}  还原后重新构建并复跑 → 退码 ${clean.code}`);
  if (clean.code !== 0) fails(clean.out).slice(0, 5).forEach(l => console.log('     ' + l.trim()));
  process.exit(clean.code === 0 && ok ? 0 : 1);
}
