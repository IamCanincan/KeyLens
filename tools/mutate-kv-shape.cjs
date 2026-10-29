'use strict';
/* 变异台：三处各改一个键名，看 tools/kv-shape-check.mjs 会不会响。
   改完一律还原，且还原后先验"文件和改前逐字节相同"再说下一条。 */
const fs = require('fs');
const { execSync } = require('child_process');
const path=require('path');
const R = path.resolve(__dirname, '..') + '/';   // 别写死绝对路径：仓库目录一挪这台子就废
const files = { screens: R + 'webui/src/screens.js', bridge: R + 'webui/src/bridge.js' };
const orig = {};
for (const k in files) orig[k] = fs.readFileSync(files[k], 'utf8');

function swap(file, from, to, expect) {
  const t = fs.readFileSync(file, 'utf8');
  const n = t.split(from).length - 1;
  if (n !== expect) throw new Error(`${file}: "${from}" 命中 ${n} 处，预期 ${expect} —— 变异没落地，这条不算证据`);
  fs.writeFileSync(file, t.split(from).join(to));
  return n;
}
function run() {
  try { const out = execSync('node "' + R + 'tools/kv-shape-check.mjs"', { encoding: 'utf8', cwd: R }); return { code: 0, out }; }
  catch (e) { return { code: e.status, out: (e.stdout || '') + (e.stderr || '') }; }
}
function restore() { for (const k in files) fs.writeFileSync(files[k], orig[k]); }

const cases = [
  ['界面读回上游小驼峰键', files.screens, 't.tee_broken', 't.teeBroken', 2],
  ['假数据跟着一起错', files.bridge, "'tee_broken=unknown'", "'teeBroken=unknown'", 1],
  ['KV_REQUIRED 编一个不存在的键', files.bridge, "'tee-status': 'present'", "'tee-status': 'tee_status_ok'", 1],
];
let ok = 0;
for (const [name, file, from, to, expect] of cases) {
  swap(file, from, to, expect);
  const r = run();
  console.log(`${r.code !== 0 ? '✓' : '✗ 不响'}  变异「${name}」→ 退码 ${r.code}：` +
    r.out.split('\n').filter((l) => l.indexOf('✗') === 0).slice(0, 2).join(' | '));
  if (r.code !== 0) ok++;
  restore();
}
/* 还原必须逐字节回到原样，否则这个台子自己就在污染工作区 */
let drift = 0;
for (const k in files) if (fs.readFileSync(files[k], 'utf8') !== orig[k]) { console.log('✗ 还原后仍有差异：' + files[k]); drift++; }
const clean = run();
console.log(`${drift === 0 && clean.code === 0 ? '✓' : '✗'}  还原后原样 + 复跑退码 ${clean.code}`);
console.log(`三处变异里 ${ok}/3 被抓住`);
process.exit(ok === 3 && drift === 0 && clean.code === 0 ? 0 : 1);
