'use strict';
/* 变异台：给 tests/ui-shape.js 的「层级」那一组（2026-10-30 四格重排新写的）逐条上刀。
 *
 * 为什么每条都要点名：只看"退码非 0"是不够的 —— 一条断言被**别的**断言碰响，
 * 和"它自己会响"是两件事。所以每条变异都要求输出里出现**那一条的名字**。
 * 第 6 条同时验 tools/module-scope-check.mjs：把 redraw() 退回没 import 的 draw()，
 * 两个台子都要响。
 *
 * 跑法：node tools/mutate-ui-shape.cjs        （会临时改 webui/src，改完逐字节还原）
 */
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
const R = path.resolve(__dirname, '..') + '/';
const files = { screens: R + 'webui/src/screens.js', app: R + 'webui/src/app.js' };
const orig = {};
for (const k in files) orig[k] = fs.readFileSync(files[k], 'utf8');

function swap(file, from, to, expect) {
  const t = fs.readFileSync(file, 'utf8');
  const n = t.split(from).length - 1;
  if (n !== expect) throw new Error(`${file}: "${from}" 命中 ${n} 处，预期 ${expect} —— 变异没落地，这条不算证据`);
  fs.writeFileSync(file, t.split(from).join(to));
  return n;
}
function run(cmd) {
  try { return { code: 0, out: execSync(cmd, { encoding: 'utf8', cwd: R }) }; }
  catch (e) { return { code: e.status, out: (e.stdout || '') + (e.stderr || '') }; }
}
const SHAPE = 'node "' + R + 'tests/ui-shape.js"';
const SCOPE = 'node "' + R + 'tools/module-scope-check.mjs"';
function restore() { for (const k in files) fs.writeFileSync(files[k], orig[k]); }

/* [点名哪条断言必须响, 文件, 原文, 改成, 预期命中处数, 附带要响的第二把闸] */
const cases = [
  ['二级页按 FUNC_PAGES 分发五个功能面', files.screens,
    "  if (sub === 'sync') box.appendChild(autoSyncCard());\n", '\n', 1],
  ['主页只有状态两卡，不带功能', files.screens,
    '  box.appendChild(statusStrip());', '  box.appendChild(statusStrip());\n  box.appendChild(autoSyncCard());', 1],
  ['主页不推迟挂载（落地页晚一帧就是"先空一下"）', files.screens,
    '  box.appendChild(statusStrip());', '  setTimeout(function () { }, 0);\n  box.appendChild(statusStrip());', 1],
  ['外观与界面自检在设置格，不在别处', files.screens,
    '  box.appendChild(backendMatrix());', '  box.appendChild(backendMatrix());\n  box.appendChild(renderTheme());', 1],
  ['次序是主页/功能/日志/设置', files.app,
    "  { id: 'log', label: '日志', icon: ICON.log, need: ['log'] },\n  { id: 'settings', label: '设置', icon: ICON.settings, need: [] },",
    "  { id: 'settings', label: '设置', icon: ICON.settings, need: [] },\n  { id: 'log', label: '日志', icon: ICON.log, need: ['log'] },", 1],
  ['伪装在功能页的二级里，设置格不再有它', files.screens,
    "  if (sub === 'props') box.appendChild(propsCards());", '', 1],
  ['重画走注册的回调，不写跨模块自由变量', files.screens, 'redraw();', 'draw();', 7, SCOPE],
  ['四个页渲染函数都在，且按 主页→功能→二级→设置 相邻（切片前提）', files.screens,
    'export function renderSettings()', 'function renderSettingsX()', 1],
  ['keybox 在二级页里，不在主页与设置', files.screens,
    "  if (sub === 'keybox') box.appendChild(keyboxCard());", '', 1],
  ['主页状态条显示后端版本', files.screens,
    "  if (S.backendInfo && S.backendInfo.module_version) {\n    top.appendChild(h('span', 'hero-ver', S.backendInfo.module_version));\n  }", '', 1],
  ['OMK 配置页有运行状态卡（两个 daemon + keystore2 注入）', files.screens,
    '  const rt = omkRuntime();\n  if (rt) box.appendChild(rt);\n', '', 1],
];

/* ui-shape 的失败行前缀是"两个空格 + ✗ + 四个空格"，直接判 `l[0] === '✗'`
   一条都匹配不上（第一版就是这么把 8 条真变异读成"没响"的）。 */
const failLines = out => out.split('\n').filter(l => /^\s*✗/.test(l));
let ok = 0;
for (const [name, file, from, to, expect, extra] of cases) {
  swap(file, from, to, expect);
  const r = run(SHAPE);
  const fired = r.code !== 0 && failLines(r.out).some(l => l.indexOf(name) >= 0);
  let extraOk = true, extraOut = '';
  if (extra) { const x = run(extra); extraOk = x.code !== 0; extraOut = failLines(x.out)[0] || ''; }
  console.log(`${fired ? '✓' : '✗ 没点名响'}  变异「${name}」→ ui-shape 退码 ${r.code}`
    + (fired ? '' : '  实际响的是: ' + failLines(r.out).slice(0, 2).map(l => l.trim()).join(' | '))
    + (extra ? `\n     另一把闸: ${extraOk ? '✓ 也响' : '✗ 不响'} ${extraOut.trim()}` : ''));
  if (fired && extraOk) ok++;
  restore();
}
/* 还原必须逐字节回到原样，否则这个台子自己就在污染工作区 */
let drift = 0;
for (const k in files) if (fs.readFileSync(files[k], 'utf8') !== orig[k]) { console.log('✗ 还原后仍有差异：' + files[k]); drift++; }
const clean = run(SHAPE);
console.log(`${drift === 0 && clean.code === 0 ? '✓' : '✗'}  还原后原样 + 复跑退码 ${clean.code}`);
console.log(`${ok}/${cases.length} 条变异被点名抓住`);
process.exit(ok === cases.length && drift === 0 && clean.code === 0 ? 0 : 1);
