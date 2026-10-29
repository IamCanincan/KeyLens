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
} finally {
  fs.writeFileSync(SRC, orig);
  if (fs.readFileSync(SRC, 'utf8') !== orig) { console.log('✗ 还原失败，工作区还带着变异'); ok = false; }
  sh([path.join(here, 'build.mjs')]);
  const clean = runVerify();
  console.log(`${clean.code === 0 && ok ? '✓' : '✗'}  还原后重新构建并复跑 → 退码 ${clean.code}`);
  if (clean.code !== 0) { failed(clean.out).slice(0, 5).forEach((l) => console.log('     ' + l.trim())); ok = false; }
}
process.exit(ok ? 0 : 1);
