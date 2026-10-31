/*=============================================================================
 * tools/mutate-scope.cjs — 给 tools/module-scope-check.mjs 自己验牙
 *
 * 为什么要有它：这条闸的判据建立在"先把注释/字符串/正则摘干净"上，而摘干净这一步
 * 历史上坏过两次（一次是 URL 里的 //，一次是正则字面量里的引号）。第二次坏了以后
 * 它一边误报（说 bridge.js 用了别的模块的 target）一边**静默失明**（错位的引号把
 * 后面的真代码当字符串吃掉，那段里真正的未 import 引用一条都不响）。
 * 一条闸同时误报和失明，比没有闸更糟 —— 所以每条变异都在这里跑真的闸体。
 *
 * 用法：node tools/mutate-scope.cjs
 * 临时副本放在系统临时目录（不动工作区），每条变异只改副本。
 */
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const repo = path.resolve(__dirname, '..');
const WORK = path.join(os.tmpdir(), 'msc-mutate');
const FILES = ['webui/src/bridge.js', 'webui/src/screens.js', 'webui/src/app.js'];
const orig = {};
for (const f of FILES) orig[f] = fs.readFileSync(path.join(repo, f), 'utf8');

function sync() {
  fs.mkdirSync(path.join(WORK, 'tools'), { recursive: true });
  fs.mkdirSync(path.join(WORK, 'webui/src'), { recursive: true });
  fs.copyFileSync(path.join(repo, 'tools/module-scope-check.mjs'), path.join(WORK, 'tools/module-scope-check.mjs'));
  for (const f of FILES) fs.copyFileSync(path.join(repo, f), path.join(WORK, f));
}
function run() {
  const r = spawnSync(process.execPath, [path.join(WORK, 'tools/module-scope-check.mjs')], { encoding: 'utf8' });
  return { code: r.status, out: (r.stdout || '') + (r.stderr || '') };
}
/* 在副本里改一个文件；命中数必须恰好 1，否则这条变异本身就没落地。 */
function patch(file, from, to, expectHits) {
  const p = path.join(WORK, file);
  const src = fs.readFileSync(p, 'utf8');
  const hits = src.split(from).length - 1;
  if (hits !== expectHits) throw new Error(`变异没落地：${file} 的锚点命中 ${hits} 处（要 ${expectHits} 处）`);
  if (src.indexOf(to) >= 0) throw new Error(`变异没落地：${file} 里已经有一段改成后的代码`);
  fs.writeFileSync(p, src.replace(from, to));
}

let bad = 0;
const chk = (name, ok, detail) => { console.log(`${ok ? '✓ ' : '✗ '} ${name}${detail ? '  — ' + detail : ''}`); if (!ok) bad++; };

sync();
const base = run();
chk('基线：当前三份源码全绑定', base.code === 0, '退码 ' + base.code);

/* 1. 真阳性：screens.js 里用一个 app.js 声明的名字而不 import —— 就是当年 draw() 那一类 */
patch('webui/src/screens.js',
  'export function targetsPending() {',
  'export function _ctlDrawRef() { return draw(); }\nexport function targetsPending() {', 1);
let r = run();
chk('变异「screens.js 用了 app.js 的 draw() 没 import」→ 退码 1 且点名',
  r.code === 1 && /\bdraw\b/.test(r.out), '退码 ' + r.code);
sync();

/* 2. 变异要下在"正则字面量里有引号"之后 —— 老 strip 正是在这一点错位，
      于是把后面整段真代码当字符串吃掉。这一条证明那段现在看得见。 */
patch('webui/src/bridge.js',
  'export function loadStatus() {',
  `function _ctlQuote() { return String("x").replace(/'/g, "''"); }\n`
  + 'export function _ctlForeignRef() { return prefetchListIcons(); }\nexport function loadStatus() {', 1);
r = run();
chk('变异「带引号的正则后面，bridge.js 调了 screens.js 的 prefetchListIcons」→ 退码 1 且点名',
  r.code === 1 && /prefetchListIcons/.test(r.out), '退码 ' + r.code);
sync();

/* 3. 假阳性控制：URL 里的 // 与注释里的英文撇号都不许让字符串配对错位 */
patch('webui/src/bridge.js',
  'export function loadStatus() {',
  '/* 撇号控制：don\'t 和 http://www.w3.org/2000/svg 都不该改变引号配对 */\n'
  + 'const _CTL_URL = \'http://www.w3.org/2000/svg\';\nexport function loadStatus() {', 1);
r = run();
chk('变异「URL 与注释撇号」不产生误报 → 退码 0', r.code === 0, r.out.trim().split('\n')[0]);
sync();

/* 4. 除号不许被当成正则起点而把一行吃掉（吃掉就是失明）。
      app.js 把 screens.js 的名字都 import 了，所以这一条借 bridge.js 里
      它没 import 过的 loadTeeStatus 当"必须被看见"的参照物。 */
patch('webui/src/app.js',
  'export { reloadAll, show, draw, S, DEMO };',
  'function _ctlDiv(a, b) { var half = (1 / 2) + (a) / (b); return loadTeeStatus() + half; }\n'
  + 'export { reloadAll, show, draw, S, DEMO };', 1);
r = run();
chk('变异「除号后面接一句真引用」仍被点名 → 退码 1', r.code === 1 && /loadTeeStatus/.test(r.out),
  '退码 ' + r.code);
sync();

console.log(bad ? '\n有变异没被抓住' : `\n${4}/4 条变异按预期${''}`);
process.exit(bad ? 1 : 0);
