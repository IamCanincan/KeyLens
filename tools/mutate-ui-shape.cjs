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
const files = { screens: R + 'webui/src/screens.js', app: R + 'webui/src/app.js',
  css: R + 'webui/src/app.css', bridge: R + 'webui/src/bridge.js' };
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
/* 中途抛异常/被中断也不能把刀留在源码里（上一轮就因为进程被打断，
   boot 的 ensure 行被留在删除状态，后面的变异台自己找不到锚点）。 */
process.on('exit', restore);

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
  ['设置页外观与自检同帧画完（不推迟挂载）', files.screens,
    '  box.appendChild(selfCheck());\n',
    '  setTimeout(function () { if (box.isConnected) box.appendChild(selfCheck()); }, 0);\n', 1],
  ['次序是主页/功能/日志/设置', files.app,
    "  { id: 'log', label: '日志', icon: ICON.log, need: ['log'] },\n  { id: 'settings', label: '设置', icon: ICON.settings, need: [] },",
    "  { id: 'settings', label: '设置', icon: ICON.settings, need: [] },\n  { id: 'log', label: '日志', icon: ICON.log, need: ['log'] },", 1],
  ['伪装在功能页的二级里，设置格不再有它', files.screens,
    "  if (sub === 'props') box.appendChild(propsCards());", '', 1],
  ['重画走注册的回调，不写跨模块自由变量', files.screens, 'redraw();', 'draw();', 5, SCOPE],
  ['四个页渲染函数都在，且按 主页→功能→二级→设置 相邻（切片前提）', files.screens,
    'export function renderSettings()', 'function renderSettingsX()', 1],
  ['keybox 在二级页里，不在主页与设置', files.screens,
    "  if (sub === 'keybox') box.appendChild(keyboxCard());", '', 1],
  ['主页状态条显示后端版本', files.screens,
    "  if (S.backendInfo && S.backendInfo.module_version) {\n    id.appendChild(h('span', 'hero-ver', S.backendInfo.module_version));\n  }", '', 1],
  ['OMK 配置页有运行状态卡（两个 daemon + keystore2 注入）', files.screens,
    '  const rt = omkRuntime();\n  if (rt) box.appendChild(rt);\n', '', 1],
  ['目标名单首次进入先预取应用名/图标再画（无首帧闪动）', files.app,
    '    return prefetchListIcons().then(function (didIcons) {\n      if (force || wasPending || did || didIcons) finishLoad(key);\n    });',
    '    finishLoad(key);', 1],
  ['缓存命中不重画当前页（没有新数据就跳过第二次构建）', files.app,
    '      if (force || wasPending || did) finishLoad(key);',
    '      finishLoad(key);', 1],
  ['重页面首进先骨架后构建，重复进入直接贴回缓存', files.app,
    "  const cached = (S.tab === 'func' && S.sub && changed && !pagePending) ? cachedPage(S.sub) : null;",
    '  const cached = null;', 1],
  ['大块内容切换用旧页淡出过渡（不是瞬换）', files.app,
    '  if (fromPending && !pagePending) fadeOldPage(prev);',
    '  if (false) fadeOldPage(prev);', 1],
  ['打开 WebUI 有品牌启动页并淡出', files.app,
    "    splash.classList.add('out');\n", "    splash.remove();\n", 1],
  ['其余二级页首进也等数据再画（不先画"读不到/全部一致"）', files.app,
    '  if (sub === \'props\') return !!S.loaded.props;',
    '  if (sub === \'props\') return true;', 1],
  ['加载态覆盖日志，文案说清在等什么', files.app,
    "  if (p === 'log') setPagePending(!S.loaded.log && !S.log.length);",
    "  if (p === 'log') setPagePending(false);", 1],
  ['取数只清自己那一页的占位（按页 key 归属）', files.app,
    "  if (pendingKey === key) { pagePending = false; pendingKey = ''; }",
    '  pagePending = false;', 1],
  ['切页后不被旧页面的取数结果重画（不打断输入）', files.app,
    "  if (key !== S.tab + '/' + S.sub) return;\n", '', 1],
  ['Tricky 名单与 tee_status 一起取（自动→首进就判定）', files.app,
    "    if (S.backendInfo.backend === 'tricky') need.push('teestatus');\n", '', 1],
  ['启动并行取基础状态/后端信息，契约一到先画壳', files.app,
    '  const statusP = ensure(\'status\');\n', '  const statusP = Promise.resolve();\n', 1],
  ['主页/功能菜单数据没到先画骨架', files.app,
    "  if (S.tab === 'home' && pagePending) {", "  if (false) {", 1],
  ['写后 reloadAll 重取当前二级页', files.app,
    '    return S.sub ? loadSub(S.sub, true) : load(S.tab);',
    '    return load(S.tab);', 1],
  ['写后 reloadAll 也重取 backend-info（条数不落后）', files.app,
    "    return ensure('backend').then(function () {}, function () {});\n", '', 1],
  ['日志自动刷新真的重读（不是命中 ensure 缓存）', files.app,
    "    loadLog().then(function () { if (S.tab === 'log') draw(); },\n      function () { if (S.tab === 'log') draw(); });",
    "    ensure('log').then(draw);", 1],
  ['功能菜单不把未读取的属性对照报成 0 项', files.screens,
    "      + (st.props_masking === 'on' && S.props.length ? ' · ' + S.props.length + ' 项对照' : '')],",
    "      + (st.props_masking === 'on' ? ' · ' + S.props.length + ' 项对照' : '')],", 1],
  ['长页入场不缩放/不上下位移（切页动画只横向）', files.css,
    '@keyframes page-in{from{opacity:0;transform:translate3d(var(--page-dx,16px),0,0)}to{opacity:1;transform:none}}',
    '@keyframes page-in{from{opacity:0;transform:translate3d(var(--page-dx,16px),10px,0) scale(.992)}to{opacity:1;transform:none}}', 1],
  ['首进是过渡骨架页（名单/日志/表单各有形状）', files.screens,
    '    w.appendChild(skRows(7));\n', '    w.appendChild(skRows(2));\n', 1],
  ['目标名单用轻量行一次画全（不建 md-list-item、不分批）', files.screens,
    "    const r = h('div', 'app-row');", "    const r = h('md-list-item', 'app-row');", 1],
  ['名单搜索只重画行，不整页重建（保焦点/保查询）', files.screens,
    '    searchTimer = setTimeout(function () { if (tf.isConnected) paintRows(); }, 90);',
    '    redraw();', 1],
  /* 把"读不到"那个分支摘掉，属性页就会在 props 失败时画成「全部一致」——
     那正是这次修掉的假状态，刀必须被点名。 */
  ['属性对照读不到时报"读不到"，不报"全部一致"', files.screens,
    "  const s1 = section('系统属性 · ' + (S.propsErr ? '读不到' : diff.length ? diff.length + ' 项不符' : '全部一致'), ICON.tune);",
    "  const s1 = section('系统属性 · ' + (diff.length ? diff.length + ' 项不符' : '全部一致'), ICON.tune);", 1],
  /* ── 2026-10-31「假数 / 假承诺 / 整页重建 / 闸的盲区」四条新判据各自的刀 ── */
  ['daemon_alive 只在 bridge 的三态 helper 里出现', files.screens,
    "      daemonLabel(st) + ' · 上次写入 ' + timeLabel(st.target_mtime)],",
    "      (st.daemon_alive === '0' ? '守护进程未运行' : st.daemon_alive + ' 个进程') + ' · 上次写入 ' + timeLabel(st.target_mtime)],", 1],
  ['failText 不再承诺它管不到的事', files.bridge,
    "  if (r && r.timeout) return '命令超时（30 秒未返回），结果未知';",
    "  if (r && r.timeout) return '命令超时，结果未知；已重新读取当前状态';", 1],
  ['超时的确重读（write 的失败分支里真调 reload）', files.screens,
    '      if (r.timeout) reload();\n', '\n', 1],
  ['同页重建前 capture、换页时作废、重建后还光标', files.app,
    '  if (changed) clearEdits(); else captureEdits(prev);\n', '\n', 1],
  ['变更判定拿服务端值当基准，不是回填后的显示值', files.screens,
    "        init: String(cur) === 'true' ? 'true' : 'false' });",
    "        init: sw.checked ? 'true' : 'false' });", 1],
  /* 这一把是"闸的盲区"的证据：旧版 ui-shape 只 grep `write('x'`，而 omk-save-config
     是经 form(spec, fields, cmd, …) 的第三个参数进来的 —— 把它从 WRITE_CMDS 里删掉，
     旧闸一声不响（契约不符时这条写命令就停不住）。现在扫调用点，必须点名响。 */
  ['日志关键字按显示文本匹配，且只重画日志台', files.screens,
    'stripEmoji(l).toLowerCase().indexOf(q) >= 0', 'l.toLowerCase().indexOf(q) >= 0', 1],
  ['日志切级别只重画日志台，不整页重建', files.screens,
    '      paintLogRows(console_);\n', '      redraw();\n', 1],
  ['每个写命令都在 WRITE_CMDS 里（否则契约不符时停不住）', files.bridge,
    'omk-save-injector omk-save-config tricky-save-patch \\', 'omk-save-injector tricky-save-patch \\', 1],
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
