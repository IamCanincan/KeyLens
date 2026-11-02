#!/usr/bin/env node
/* 变异台：证明"逐后端驱动"那条闸真的会响。
 *
 * 为什么要它：tee_status 的键名读错（上游是小驼峰，命令层输出下划线）这一类
 * 错误，上一版一路绿到上线前 —— 因为假数据是照着我错的代码写的，两边互相自证。
 * 静态那份闸（tools/kv-shape-check.mjs）抓键名，这份抓"值真的画到屏上了"。
 *
 * 每一步都自证落地：命中数必须恰好等于预期，否则这条变异不算证据。
 * 跑法：node tools/md3e-build/mutate-verify.mjs
 */
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const SRC = path.join(repo, 'webui', 'src', 'screens.js');
const orig = fs.readFileSync(SRC, 'utf8');

function swap(from, to, expect) {
  const t = fs.readFileSync(SRC, 'utf8');
  const n = t.split(from).length - 1;
  if (n !== expect) throw new Error(`变异没落地："${from}" 命中 ${n} 处，预期 ${expect}`);
  fs.writeFileSync(SRC, t.split(from).join(to));
}
function sh(args) {
  return execFileSync('node', args, { cwd: repo, encoding: 'utf8' });
}
function runVerify() {
  try { return { code: 0, out: sh([path.join(here, 'verify.mjs')]) }; }
  catch (e) {
    /* execFileSync 报错时 stdout 在 e.buffer.stdout（Uint8Array）或 e.stdout，
       两个都试：只读一个的话，退码红了却看不到"为什么红"，等于把证据扔掉。 */
    const s = (b) => b ? (Buffer.isBuffer(b) ? b.toString('utf8') : String(b)) : '';
    return { code: typeof e.status === 'number' ? e.status : -1,
      out: s(e.buffer && e.buffer.stdout) + s(e.stdout) + s(e.buffer && e.buffer.stderr) + s(e.stderr) + s(e.message) };
  }
}
function failed(out) {
  return out.split('\n').filter((l) => l.trim().startsWith('✗'));
}

let ok = true;
try {
  /* ① 界面读回上游的小驼峰键 —— 逐后端那一格必须变红 */
  swap('t.tee_broken', 't.teeBroken', 2);
  sh([path.join(here, 'build.mjs')]);
  const m1 = runVerify();
  const f1 = failed(m1.out);
  console.log(`${m1.code !== 0 ? '✓' : '✗ 不响'}  变异「界面读回小驼峰键」→ 退码 ${m1.code}`);
  f1.slice(0, 3).forEach((l) => console.log('     ' + l.trim()));
  if (m1.code === 0) ok = false;
  fs.writeFileSync(SRC, orig);

  /* ② 名单读失败被吞成空态 —— 那条专用断言必须变红 */
  swap("if (S.listErr) s.appendChild(h('p', 'read-err', '名单读不到：' + S.listErr));", '', 1);
  sh([path.join(here, 'build.mjs')]);
  const m2 = runVerify();
  const f2 = failed(m2.out);
  console.log(`${m2.code !== 0 ? '✓' : '✗ 不响'}  变异「读失败不再报错误行」→ 退码 ${m2.code}`);
  f2.slice(0, 3).forEach((l) => console.log('     ' + l.trim()));
  if (m2.code === 0) ok = false;
  fs.writeFileSync(SRC, orig);
  /* ③ absent 那一行退回"不是 ok 就是不符"的分派 —— 属性页那条行级断言必须变红。
     这一类形状只有真画一次才看得见：命令层新增第四种状态时，界面里的三元 else
     会把 absent 一起吞进"不符"，而命令层报的是 mismatch=0。 */
  swap("p.st === 'absent' ? 'absent' : 'diff'", "p.st === 'absent' ? 'diff' : 'diff'", 1);
  sh([path.join(here, 'build.mjs')]);
  const m3 = runVerify();
  const f3 = failed(m3.out);
  console.log(`${m3.code !== 0 ? '✓' : '✗ 不响'}  变异「absent 行标成不符」→ 退码 ${m3.code}`);
  f3.slice(0, 3).forEach((l) => console.log('     ' + l.trim()));
  if (m3.code === 0) ok = false;
  fs.writeFileSync(SRC, orig);

  /* ④ 标题的筛选退回"不是 ok 就计数" —— 标题那条断言必须变红（13 项不符 vs 9 项）。
     与 ③ 分开设：一个管行上的颜色，一个管卡片标题的数。 */
  swap("const bad = S.props.filter(function (p) { return p.st === 'diff' || p.st === 'missing'; });",
    "const bad = S.props.filter(function (p) { return p.st !== 'ok'; });", 1);
  sh([path.join(here, 'build.mjs')]);
  const m4 = runVerify();
  const f4 = failed(m4.out);
  console.log(`${m4.code !== 0 ? '✓' : '✗ 不响'}  变异「标题把 absent 算成不符」→ 退码 ${m4.code}`);
  f4.slice(0, 3).forEach((l) => console.log('     ' + l.trim()));
  if (m4.code === 0) ok = false;
  fs.writeFileSync(SRC, orig);
  /* ⑤ 属性行少画一行（这里让 absent 那族整族不上屏）—— "53 行逐行画出来"必须变红。
     这条专门盯探针自己：行数是数文案数出来的，改一句措辞就可能少数几行而断言不响。 */
  swap('S.props.forEach(function (p) {',
    "S.props.filter(function (p) { return p.st !== 'absent'; }).forEach(function (p) {", 1);
  sh([path.join(here, 'build.mjs')]);
  const m5 = runVerify();
  const f5 = failed(m5.out);
  console.log(`${m5.code !== 0 ? '✓' : '✗ 不响'}  变异「absent 那族不上屏」→ 退码 ${m5.code}`);
  f5.slice(0, 3).forEach((l) => console.log('     ' + l.trim()));
  if (m5.code === 0) ok = false;
  fs.writeFileSync(SRC, orig);
  /* ⑥ 界面把 auto 档说回"未设置"（= 修之前的两态形状）—— auto 那条断言必须变红。
     这一条守的是本轮的实质承诺：新用户一个字不填，界面也要说清"已自动派生并写入"。 */
  swap("'自动 · 取自' + srcName", "'未设置'", 1);
  sh([path.join(here, 'build.mjs')]);
  const m6 = runVerify();
  const f6 = failed(m6.out);
  console.log(`${m6.code !== 0 ? '✓' : '✗ 不响'}  变异「auto 档界面退回未设置」→ 退码 ${m6.code}`);
  f6.slice(0, 3).forEach((l) => console.log('     ' + l.trim()));
  if (m6.code === 0) ok = false;
  fs.writeFileSync(SRC, orig);
} finally {
  fs.writeFileSync(SRC, orig);
  if (fs.readFileSync(SRC, 'utf8') !== orig) { console.log('✗ 还原失败，工作区还带着变异'); ok = false; }
  sh([path.join(here, 'build.mjs')]);
  const clean = runVerify();
  console.log(`${clean.code === 0 && ok ? '✓' : '✗'}  还原后重新构建并复跑 → 退码 ${clean.code}`);
  if (clean.code !== 0) { failed(clean.out).slice(0, 5).forEach((l) => console.log('     ' + l.trim())); ok = false; }
}
process.exit(ok ? 0 : 1);
