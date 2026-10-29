'use strict';
/* 变异台：证明 verify 新加的那条"画出来的图标都有对应字体面"真的会响。
   变异 = 让 build 把**唯一那份** Rounded 也删掉 —— 界面所有图标元素的第一个族名
   就都没有字体面了。还原后必须回绿，且逐字节确认还原成功。 */
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const repo = path.resolve(__dirname, '../..');
const B = path.join(repo, 'tools/md3e-build/build.mjs');
const orig = fs.readFileSync(B, 'utf8');
const ANCHOR = "css = css.replace(/@font-face\\s*\\{[^}]*font-family:\\s*['\"]?Roboto['\"]?[^}]*\\}/g, '');";

function sh(args) { return execFileSync('node', args, { cwd: repo, encoding: 'utf8' }); }
function runVerify() {
  try { return { code: 0, out: sh([path.join('tools', 'md3e-build', 'verify.mjs'), path.join('webui', 'dist', 'index.html')]) }; }
  catch (e) {
    const s = (b) => b ? (Buffer.isBuffer(b) ? b.toString('utf8') : String(b)) : '';
    return { code: typeof e.status === 'number' ? e.status : -1, out: s(e.buffer && e.buffer.stdout) + s(e.stdout) + s(e.message) };
  }
}
let ok = true;
try {
  const hits = orig.split(ANCHOR).length - 1;
  if (hits !== 1) { console.log(`✗ 锚点命中 ${hits} 处，预期 1 —— 变异没落地，这条不算证据`); process.exit(1); }
  fs.writeFileSync(B, orig.replace(ANCHOR, ANCHOR + "\ncss = css.replace(/@font-face\\s*\\{[^}]*Material Symbols Rounded[^}]*\\}/g, '');"));
  sh([path.join('tools', 'md3e-build', 'build.mjs')]);
  const m = runVerify();
  const lines = m.out.split('\n').filter(l => l.trim().startsWith('✗'));
  console.log(`${m.code !== 0 ? '✓' : '✗ 不响'}  变异「唯一那份字体面也被删掉」→ 退码 ${m.code}`);
  lines.slice(0, 4).forEach(l => console.log('     ' + l.trim()));
  if (m.code === 0) ok = false;
} finally {
  fs.writeFileSync(B, orig);
  if (fs.readFileSync(B, 'utf8') !== orig) { console.log('✗ 还原失败'); ok = false; }
  sh([path.join('tools', 'md3e-build', 'build.mjs'), '--ship']);
  const clean = runVerify();
  console.log(`${clean.code === 0 && ok ? '✓' : '✗'}  还原后重新构建并复跑 → 退码 ${clean.code}`);
  if (clean.code !== 0) clean.out.split('\n').filter(l => l.trim().startsWith('✗')).slice(0, 4).forEach(l => console.log('     ' + l.trim()));
  process.exit(clean.code === 0 && ok ? 0 : 1);
}
