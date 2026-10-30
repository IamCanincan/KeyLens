#!/usr/bin/env node
'use strict';
/*
 * tests/ui-shape.js —— 界面源码（webui/src）的静态自检
 *
 * 2026-10-30 换版：这个套子原来叫 ui-next-shape.js，与守旧产物的 ui-shape.js /
 * ui-font.js 并存，为的是换版之前线上那一版不失去护栏。产物已经换成
 * webui/dist → module/webroot 这一条构建线，旧的两个套子与旧台架
 * （tools/ui-cdp-check.mjs）在同一个提交里退役，名字也归位。
 *
 * 这套里最值钱的是第 ② 组：**表单字段名必须被命令层的校验分支接受**。
 * 两边都是字符串，对不上时不是"少一个字段"，而是整单被 `*) echo 未知字段` 拒掉 ——
 * 用户点保存只看到一句"未知字段：xxx"，而这在运行时之前完全可以静态查出来。
 * 同类的还有：假数据的命令清单 = case 实际实现、KL_COMMANDS 声明 = 实现、
 * 界面读的 KV 键 ⊆ 命令层输出的键（后者在 tools/kv-shape-check.mjs）。
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const SRC = p => path.join(ROOT, p);
const read = p => fs.readFileSync(SRC(p), 'utf8');

const bridge = read('webui/src/bridge.js');
const screens = read('webui/src/screens.js');
const app = read('webui/src/app.js');
const css = read('webui/src/app.css');
const tpl = read('webui/src/index.html');
const sh = read('module/webui.sh');
const theme = fs.existsSync(SRC('webui/src/theme.js')) ? read('webui/src/theme.js') : '';

let fail = 0;
const chk = (name, ok, detail) => {
  if (ok) { console.log('  ok   ' + name + (detail ? '  — ' + detail : '')); }
  else { console.log('  ✗    ' + name + (detail ? '  → ' + detail : '')); fail = 1; }
};

/* ──  契约常量 ─────────────────────────────────────────────────── */
console.log('── 契约 ──');
const EXPECT_API = (bridge.match(/export const EXPECT_API *= *(\d+)/) || [])[1];
chk('EXPECT_API 读得到', !!EXPECT_API, 'api=' + EXPECT_API);
chk('EXPECT_API 与命令层一致',
  EXPECT_API === (sh.match(/^KL_API=(\d+)/m) || [])[1],
  '界面 ' + EXPECT_API + ' / 命令层 ' + (sh.match(/^KL_API=(\d+)/m) || [])[1]);
const writeCmds = ((bridge.match(/export const WRITE_CMDS = '((?:[^']|\n)+)'/) || [])[1] || '').split(/\s+/).filter(Boolean);
chk('WRITE_CMDS 读得到', writeCmds.length > 5, writeCmds.length + ' 条');

/* ──  表单字段名 ↔ 命令层校验分支（本套的核心） ─────────────────── */
console.log('── 字段名与命令层对账 ──');
/* 命令层每个 save 函数接受的键：从 `case "$k" in ... esac` 里抓分支标签。
   函数体按"从函数名那行到第一个顶格 }"切 —— 不能用花括号计数：shell 源码里
   `${VAR%/*}`、`{ echo; return 1; }` 这类花括号到处都是，数到一半就切错，
   结果是"抽不到 case 分支"这种假失败。 */
function acceptedKeys(fnName) {
  const lines = sh.split('\n');
  const start = lines.findIndex(l => l.startsWith(fnName + '() {'));
  if (start < 0) return null;
  let end = -1;
  for (let i = start + 1; i < lines.length; i++) {
    if (lines[i] === '}') { end = i; break; }
  }
  if (end < 0) return null;
  const body = lines.slice(start, end).join('\n');
  // esac 在这个仓库里是缩进的，要求它顶格会永远匹配不上（假失败）
  const cm = body.match(/case "\$k" in([\s\S]*?)\n\s*esac/);
  if (!cm) return null;
  const keys = new Set();
  cm[1].split('\n').forEach(line => {
    const m = line.match(/^\s+([A-Za-z_][A-Za-z0-9_|]*)\)/);
    if (m) m[1].split('|').forEach(k => keys.add(k));
  });
  return keys;
}
/* screens.js 里的字段规格是 [key, 取值来源, 标签, 类型, …] 四元起步；
   只按 `\['xxx'` 抓会把 select 的选项对 ['patch','补丁'] 也当成字段名 ——
   那会报出"命令层不接受 patch"这种假失败。要求第四元是已知类型才算字段。 */
const TYPES = '(text|switch|select|seg)';
function specKeys(name) {
  const m = screens.match(new RegExp('const ' + name + ' = \\[([\\s\\S]*?)\\n\\];'));
  if (!m) return null;
  return [...m[1].matchAll(new RegExp("\\['([a-z_0-9]+)', '[a-z_0-9]+', '[^']+', '" + TYPES + "'", 'g'))].map(x => x[1]);
}
const PAIRS = [
  ['F_PROFILE + F_IDENTITY', ['F_PROFILE', 'F_IDENTITY'], 'cmd_teesim_save'],
  ['F_TRICKY', ['F_TRICKY'], 'cmd_tricky_save_patch'],
  ['F_OMK_CONFIG', ['F_OMK_CONFIG'], 'cmd_omk_save_config'],
  ['F_OMK_INJECTOR', ['F_OMK_INJECTOR'], 'cmd_omk_save_injector'],
];
for (const [label, specs, fn] of PAIRS) {
  const accept = acceptedKeys(fn);
  let keys = [];
  specs.forEach(s => { keys = keys.concat(specKeys(s) || []); });
  if (!accept) { chk(label + ' → ' + fn, false, '抽不到命令层的 case 分支（结构变了？）'); continue; }
  if (!keys.length) { chk(label + ' → ' + fn, false, '抽不到字段规格'); continue; }
  const bad = keys.filter(k => !accept.has(k));
  chk(label + ' 的 ' + keys.length + ' 个键都被 ' + fn + ' 接受', bad.length === 0, bad.join(' '));
}
/* 反向：命令层收、界面没有键 —— 不是错，但要看得见（完整度账） */
const teesimAccept = acceptedKeys('cmd_teesim_save') || new Set();
const dup = [...teesimAccept].filter(k => !(specKeys('F_PROFILE') || []).concat(specKeys('F_IDENTITY') || []).includes(k));
chk('TEESim 命令层没有界面却填不出的多余键', dup.length === 0, dup.join(' '));

/* ──  写命令都在清单里，且都进了 WRITE_CMDS ─────────────────────── */
console.log('── 写命令接线 ──');
const cmds = ((sh.match(/^KL_COMMANDS="([\s\S]*?)"$/m) || [])[1] || '').replace(/\\\n/g, ' ').split(/\s+/).filter(Boolean);
const used = [...screens.matchAll(/write\('([a-z-]+)'/g)].map(m => m[1]);
const unknown = [...new Set(used)].filter(c => !cmds.includes(c));
chk('界面调用的写命令都在命令层清单里', unknown.length === 0, unknown.join(' '));
const notGated = [...new Set(used)].filter(c => !writeCmds.includes(c));
chk('每个写命令都在 WRITE_CMDS 里（否则契约不符时停不住）', notGated.length === 0, notGated.join(' '));
/* 读命令不许出现在 write() 里：它会被契约闸门误拦 */
const reads = ['status', 'env', 'targets', 'apps', 'log', 'props', 'contract', 'icons', 'target-meta',
  'backend-info', 'teesim-profiles', 'tee-status', 'tricky-patches', 'excluded', 'boot-hash'];
const misRead = [...new Set(used)].filter(c => reads.includes(c));
chk('没有把读命令当写命令调', misRead.length === 0, misRead.join(' '));

/* ── ④ KV_REQUIRED 不许给 TSV 命令编键 ───────────────────────────── */
console.log('── 形状校验 ──');
const kvBlock = (bridge.match(/export const KV_REQUIRED = \{([\s\S]*?)\n\};/) || [])[1] || '';
const kvEntries = [...kvBlock.matchAll(/'?([a-z-]+)'?:\s*'([^']*)'/g)].map(m => [m[1], m[2].trim()]);
chk('KV_REQUIRED 读得到', kvEntries.length > 5, kvEntries.length + ' 条');
const TSV = ['props', 'targets', 'apps', 'icons', 'log', 'teesim-profiles', 'tricky-patches', 'excluded'];
const tsvWrong = kvEntries.filter(([k, v]) => TSV.includes(k) && v !== '');
chk('TSV 输出的命令没有被编造 required 键', tsvWrong.length === 0,
  tsvWrong.map(x => x[0] + '=' + x[1]).join(' '));
/* 每个声明了键的命令，命令层真的要 kv 出那个键 */
kvEntries.forEach(([k, v]) => {
  if (!v) return;
  const fn = 'cmd_' + k.replace(/-/g, '_');
  if (sh.indexOf(fn + '() {') < 0) return;   // 组合键或无独立函数，跳过
  v.split(/\s+/).forEach(key => {
    // 命令层也写 `kv present 0` 这种字面值，所以值那一格允许 " $ 或数字
    if (!new RegExp('kv ' + key + ' ["$0-9]').test(sh)) {
      console.log('  ✗    ' + k + ' 声明要 ' + key + '，命令层没 kv 它'); fail = 1;
    }
  });
});
console.log('  ok   声明的 required 键命令层都会输出（逐条查过）');

/* ── ⑤ 层级与四个目的地：主页 / 功能 / 日志 / 设置（功能页带二级菜单）── */
console.log('── 层级 ──');
const pages = [...app.matchAll(/\{ id: '([a-z]+)', label: '([^']+)', icon: ICON\.([a-z]+)/g)];
chk('四个目的地', pages.length === 4, pages.map(p => p[2]).join('/'));
chk('次序是主页/功能/日志/设置', ['主页', '功能', '日志', '设置'].join('/') === pages.map(p => p[2]).join('/'));
chk('落地页是主页（打开先回答"在不在跑"）', pages[0] && pages[0][1] === 'home' && pages[0][2] === '主页',
  pages[0] && pages[0][1] + '=' + pages[0][2]);
/* 判据切的是"函数体"，而函数体靠相邻次序切出来 —— render* 一旦被打散，
   切片就会拿到空串，下面的断言全部假绿。所以先钉相邻性本身。 */
const RN = ['renderHome', 'renderFunc', 'renderFuncSub', 'renderSettings'];
const RI = RN.map(n => screens.indexOf('export function ' + n));
chk('四个页渲染函数都在，且按 主页→功能→二级→设置 相邻（切片前提）',
  RI.every(i => i >= 0) && RI[0] < RI[1] && RI[1] < RI[2] && RI[2] < RI[3], RI.join('/'));
const endSet = screens.indexOf('const BACKENDS', RI[3] < 0 ? 0 : RI[3]);
const homeBody = RI[0] >= 0 ? screens.slice(RI[0], RI[1]) : '';
const funcBody = RI[1] >= 0 ? screens.slice(RI[1], RI[2]) : '';
const subBody = RI[2] >= 0 ? screens.slice(RI[2], RI[3]) : '';
const setBody = RI[3] >= 0 && endSet > RI[3] ? screens.slice(RI[3], endSet) : '';
chk('四段函数体都切得到（切片没落空）',
  homeBody.length > 60 && funcBody.length > 60 && subBody.length > 60 && setBody.length > 60,
  [homeBody.length, funcBody.length, subBody.length, setBody.length].join('/'));
/* 2026-10-30 用户定稿：功能页 = 一张菜单集成所有功能，长列表默认收进二级 ——
   菜单页本身必须轻（落地即用），列表与表单点进去才画。 */
/* FUNC_PAGES 声明在 renderFunc 之前、落在 homeBody 切片里 —— 所以注册表查 screens；
   负面断言（"菜单页不画长列表"）要用**剥掉注释**的函数体：下一段的说明注释里
   就写着 listSection，注释不算代码。 */
const funcCode = funcBody.replace(/\/\*[\s\S]*?\*\//g, ' ');
chk('功能页是菜单：五项入口各带状态摘要，行尾是箭头不是内容',
  /export const FUNC_PAGES = \{/.test(screens)
  && ['targets', 'config', 'sync', 'keybox', 'props'].every(k => new RegExp(k + ": '[^']+'").test(screens))
  && /nav-ic/.test(funcCode) && /openSubFn\(/.test(funcCode));
chk('菜单页不画长列表（listSection 与表单卡都不在菜单函数里）',
  !/listSection|teesimProfiles|teesimOverrides|trickyBlocks|omkReload|keyboxCard|propsCards|autoSyncCard/.test(funcCode));
chk('二级页按 FUNC_PAGES 分发五个功能面',
  /'targets'\) box\.appendChild\(listSection\(\)\)/.test(subBody)
  && /'sync'\) box\.appendChild\(autoSyncCard\(\)\)/.test(subBody)
  && /'keybox'\) box\.appendChild\(keyboxCard\(\)\)/.test(subBody)
  && /'props'\) box\.appendChild\(propsCards\(\)\)/.test(subBody)
  && /teesimProfiles\(\)/.test(subBody) && /trickyBlocks\(\)/.test(subBody) && /omkReload\(\)/.test(subBody));
chk('二级走 pushState + popstate，返回箭头是顶栏 leading 槽',
  /history\.pushState\(null, '', '#\/func\/' \+ sub\)/.test(app)
  && /addEventListener\('popstate'/.test(app)
  && /slot', 'leading'/.test(app) && /history\.back\(\)/.test(app));
chk('菜单行点击经注册回调进 app（screens 不反向 import app）',
  /export function onOpenSub\(/.test(screens) && /onOpenSub\(openSub\)/.test(app));
/* "本模块附加"的定位说明住在注释里，不上屏 —— 用户原话：没必要这么强调。
   剥掉注释再查：注释里说的不算，画到屏上的字符串才算。 */
chk('界面文字不再强调"本模块附加"', !/本模块附加/.test(screens.replace(/\/\*[\s\S]*?\*\//g, ' ')));
chk('三家互斥矩阵与状态条在主页',
  /box\.appendChild\(backendMatrix\(\)\)/.test(homeBody) && /box\.appendChild\(statusStrip\(\)\)/.test(homeBody));
chk('主页不推迟挂载（落地页晚一帧就是"先空一下"）', !/setTimeout/.test(homeBody));
chk('主页只有状态两卡，不带功能',
  !/autoSyncCard|listSection|keyboxCard|propsCards|renderTheme|selfCheck/.test(homeBody.replace(/\/\*[\s\S]*?\*\//g, ' ')));
chk('名单不再是一个目的地，也不在菜单页上',
  !pages.some(p => p[1] === 'targets') && !/listSection/.test(funcCode));
chk('keybox 在二级页里，不在主页与设置',
  /appendChild\(keyboxCard\(\)\)/.test(subBody)
  && !/keyboxCard/.test(homeBody) && !/keyboxCard/.test(setBody) && !/keyboxCard/.test(funcBody));
/* 伪装/Verified Boot 是改设备状态的功能 → 功能页的二级；设置只留界面自己的事。 */
chk('伪装在功能页的二级里，设置格不再有它',
  /'props'\) box\.appendChild\(propsCards\(\)\)/.test(subBody)
  && /function propsCards\(\)/.test(screens) && !/propsCards/.test(setBody));
chk('外观与界面自检在设置格，不在别处',
  /renderTheme\(\)/.test(setBody) && /selfCheck\(\)/.test(setBody)
  && !/renderTheme/.test(homeBody) && !/selfCheck/.test(subBody) && !/selfCheck/.test(homeBody));
/* p[1] 是 id、p[2] 是 label（正则的三个捕获组按 id/label/icon 排）—— 拿 label 去比
   id 的话这条永远红，而"永远红的断言"和"没有断言"等价。 */
chk('日志仍是第三格', pages.findIndex(p => p[1] === 'log') === 2);
/* 每格取数：主页与功能菜单都只问状态与后端（长列表的数据进二级才问） */
chk('主页与功能菜单取数不含 lists/props',
  /id: 'home'[^}]*need: \[[^\]]*'base'[^\]]*'backend'/.test(app)
  && /id: 'func'[^}]*need: \[[^\]]*'base'[^\]]*'backend'/.test(app)
  && !/id: 'func'[^}]*need: \[[^\]]*'lists'/.test(app));
chk('二级页取数按需：名单要 lists、伪装要 props',
  /sub === 'targets'[^}]*'lists', 'excluded'/.test(app.replace(/\n/g, ' '))
  && /sub === 'props'[^}]*'props'/.test(app.replace(/\n/g, ' ')));
chk('路由表把四格都接上了',
  /home: renderHome/.test(app) && /func: renderFunc/.test(app) && /settings: renderSettings/.test(app));
chk('落地页与 hash 兜底都指回主页',
  /: 'home'/.test(app) && !/show\('backend'\)/.test(app));
/* screens.js 里那六处重画以前写的是没 import 的 `draw()` —— esbuild 摊平作用域才
   侥幸能跑。这条钉住"注册回调"这一形态，别再退回自由变量（module-scope-check 守全类）。 */
chk('重画走注册的回调，不写跨模块自由变量',
  /export function onDraw\(/.test(screens) && /onDraw\(draw\)/.test(app)
  /* 判"裸 draw()"：`redraw();` 里就含着 `draw();`，所以要求前面不是字母 ——
     不然这条断言会在自己人身上假红。 */
  && !/(?:^|[^A-Za-z])draw\(\);/.test(screens) && /function redraw\(\)/.test(screens));

/* ── ⑥ 三家语法差异有单一出处 ───────────────────────────────────── */
console.log('── 语法分叉 ──');
['tricky', 'teesim', 'omk'].forEach(b => {
  const m = screens.match(new RegExp(b + ': \\{ label: \'([^\']+)\''));
  chk('SYNTAX.' + b + ' 有写法说明', !!m, m && m[1]);
});
/* 判据别写成自相矛盾的样子（上一版要求 screens 里既没有 `uid: true` 又有它，
   恒假 —— 一条永远不会绿的断言和一条永远不会响的闸门一样没用）。 */
chk('uid: 只有 TEESim 认',
  /teesim: \{[^}]*uid: true/.test(screens)
  && /tricky: \{[^}]*uid: false/.test(screens)
  && /omk: \{[^}]*uid: false/.test(screens));
chk('证书模式后缀只有 Tricky 有', /tricky: \{[^}]*modes: true/.test(screens) && /omk: \{[^}]*modes: false/.test(screens));

/* ── ⑦ 桥接与安全底线 ───────────────────────────────────────────── */
console.log('── 底线 ──');
chk('桥接候选表在（连不上要能自证扫了什么）', /BRIDGE_CANDIDATES = \[[^\]]*bridge/.test(bridge));
/* 深浅两半都不能少：MD3E 的暗色盘挂在 [data-theme=dark] 上，只设 color-scheme
   界面一个颜色都不翻（2026-10-30 上机就是这个症状）；而 boot 时 env 还没回来，
   sys_dark 那时是 undefined，env 落地后必须重涂一遍，否则永远停在首次判断。 */
chk('深浅翻的是 data-theme，且 env 落地后重涂（boot 与 reloadAll 各一次）',
  /setAttribute\('data-theme', want \? 'dark' : 'light'\)/.test(app)
  && (app.match(/applyTheme\(\);/g) || []).length >= 2);
/* 安全区：管理器把 insets 注入成自定义属性 --safe-area-inset-*（dex 里挖出来的
   生成格式），这个 WebView 里 env() 恒 0 —— 只读 env 顶栏就伸不进状态栏。 */
chk('安全区读注入值与 env 的较大者',
  /--inset-top: max\(var\(--safe-area-inset-top/.test(css)
  && /--inset-bottom: max\(var\(--safe-area-inset-bottom/.test(css));
/* 管理器注入的 insets 在本机实测可能是 0 —— 22px 的标题行会正好钻进状态栏底下
   （"头被砍一半"）。命令层从 dumpsys 量真实高度换成 dp，界面落 `--statusbar-fallback`，
   --inset-top 取三者较大者。*/
chk('状态栏兜底接上了（命令层量 dp → 界面落 --statusbar-fallback）',
  /sys_statusbar_dp/.test(sh) && /--statusbar-fallback/.test(css) && /applyInsets\(\)/.test(app));
/* 顶/底栏组件把颜色画在 shadow 的 .bar 上、宿主透明，而让位 padding 加在宿主上
   —— 宿主不涂底色，padding 那条就是透明带（上机"状态栏缺一块"的另一半）。 */
chk('顶栏让位在外层包壳上，组件保持原生 64px',
  /#barwrap\{[^}]*padding-top:var\(--inset-top\)[^}]*background:var\(--md-sys-color-surface\)/.test(css)
  && !/md-top-app-bar\{[^}]*padding-top/.test(css)
  && /<div id="barwrap"><md-top-app-bar id="bar"/.test(tpl));
chk('底栏宿主是半透明模糊面（NoMount 式）',
  /md-navigation-bar\{[^}]*background:color-mix\(in srgb, var\(--navigation-container/.test(css)
  && /md-navigation-bar\{[^}]*backdrop-filter:blur/.test(css));
chk('底栏只给当前项显示文字（shadow 注入）',
  /aria-selected="false"\] \.label\{opacity:0/.test(app)
  && /aria-selected="false"\] \.icon\{top:20px/.test(app));
chk('页标题在内容里（28px），顶栏只在滚动后出 22px 小标题',
  /\.page-title\{font-size:28px/.test(css)
  && /\.headline\{font-size:22px!important/.test(app)
  && /:host\(\.scrolled\) \.titles/.test(app));
chk('页标题由 draw() 插进内容，滚动切换顶栏状态',
  /appendChild\(h\('h1', 'page-title', title\)\)/.test(app)
  && /addEventListener\('scroll'/.test(app)
  && /resetScrollState\(\)/.test(app));
/* 分组列表（参考系统设置）：一个 md-list = 一组，只有首行上角与末行下角是大圆角，
   行距 2px；行里的底色/圆角是**行内样式**，shadow 里的规则必须带 !important
   （探针实测：不带时 computed 仍是组件写的 surface/4px —— 属性看着改了、画面没变）。 */
chk('分组圆角：首行上角、末行下角大圆角',
  /md-list-item:first-child\{border-top-left-radius:22px/.test(css)
  && /md-list-item:last-child\{border-bottom-left-radius:22px/.test(css)
  && /#view md-list md-list-item\{border-radius:6px;margin-bottom:2px\}/.test(css));
chk('行面的底色与圆角用 !important 压过组件行内样式',
  /\.item\{background:var\(--md-sys-color-surface-container\)!important;border-radius:inherit!important\}/.test(screens));
chk('图标在行中轴（leading/trailing 钉到 50%）',
  /\.leading-slot\{top:50%!important;transform:translateY\(-50%\)!important\}/.test(screens)
  && /\.trailing\{top:50%!important/.test(screens));
/* 动态配色：FRRO 解析 + tonal 单调自检必须住在 theme.js（纯函数，tests/accent-theme.mjs
   在 node 里单测），app 在 data-theme 之后调 applyAccent（角色明度跟档走）。
   兜底必须是平台默认 #4b5d8b，不许退回 MD3E 自己那支紫 —— 上一版的结论。 */
chk('动态配色在 theme.js：FRRO 解析 + tonal 自检 + 平台默认兜底',
  /export function parseFrro/.test(theme) && /mono/.test(theme)
  /* 兜底色整条认：{ r/g/b } 的键名 g、b 本身是十六进制字母，字符类排不掉 */
  && /FALLBACK_RGB = \{ r: 0x4b, g: 0x5d, b: 0x8b \}/.test(theme));
chk('applyAccent 接在 data-theme 之后（切深浅要重算角色明度）',
  /applyAccent\(S\.env\)/.test(app)
  && app.indexOf('applyAccent(S.env)') > app.indexOf("setAttribute('data-theme'"));
chk('外观卡照报强调色来源（accentNote）', /accentNote\(\)/.test(screens));
chk('crypto 种子不渲染', !/root_kek_seed|kak_seed|shared_secret_seed|shared_secret_nonce|auth_token_hmac_key/.test(screens));
chk('serial/imei/meid 不进日志或提示', !/console\.log\(.*(serial|imei)/.test(screens));
chk('命令参数走单引号转义（防注入）', /String\(arg\)\.replace\(\/'\/g, "'\\\\''"\)/.test(bridge));
chk('模板有安全区样式表与 viewport-fit', /\/internal\/insets\.css/.test(tpl) && /viewport-fit=cover/.test(tpl));
chk('文本字体是 system-ui，不引网页文本字体', /--md-sys-typescale-font-family: system-ui/.test(css));
chk('图标字体族名保留（组件画连字要用）', !/--md-icon-font-family\s*:/.test(css));

/* 假数据的命令清单必须与 webui.sh 的 case 标签**一模一样**。
   上一版这里少了 teesim-overrides —— 于是 hasCmd() 在台架上一直是 false，
   overrides 那张卡永远走的是"命令层没有这条"的降级分支，而台架报的是全绿。 */
{
  const sec = sh.slice(sh.indexOf('case "$CMD" in'));
  const body = sec.slice(0, sec.indexOf('\nesac'));
  const real = [...body.matchAll(/^\s{2,4}([a-z][a-z0-9-]*)\)/gm)].map(m => m[1]);
  const fx = (bridge.match(/commands=([^\n']+)/) || ['', ''])[1].trim().split(/\s+/).filter(Boolean);
  const missing = real.filter(c => !fx.includes(c));
  const extra = fx.filter(c => !real.includes(c));
  chk('假数据的命令清单 = 命令层实际有的命令',
    missing.length === 0 && extra.length === 0 && real.length > 20,
    '命令层 ' + real.length + ' 条 · 假数据 ' + fx.length + ' 条'
    + (missing.length ? ' · 假数据缺: ' + missing.join(' ') : '')
    + (extra.length ? ' · 假数据多: ' + extra.join(' ') : ''));
}

/* 命令层的两份清单自己也要对得上：`case "$CMD"` 的标签是**真实现**，
   KL_COMMANDS 是**对外声明**（界面靠 hasCmd() 读它决定要不要摆控件）。
   声明里有而 case 里没有 → 界面摆出一个点了就报"未知命令"的按钮；
   case 里有而声明里没有 → 那条能力永远不露出（teesim-overrides 就这么被埋过一次，
   当时设备上部署的还是 32 条的旧声明）。 */
{
  const sec = sh.slice(sh.indexOf('case "$CMD" in'));
  const body = sec.slice(0, sec.indexOf('\nesac'));
  const real = [...body.matchAll(/^\s{2,4}([a-z][a-z0-9-]*)\)/gm)].map(m => m[1]);
  const dq = String.fromCharCode(34);
  const start = sh.indexOf('KL_COMMANDS=' + dq);
  let declRaw = '';
  for (const line of sh.slice(start).split('\n')) {
    declRaw += line.replace(/\\\$/g, '') + '\n';
    if (!/\\\s*$/.test(line)) break;
  }
  const declared = declRaw.replace(/\\\s*/g, ' ').split(/[\s"=]+/)
    .filter(x => /^[a-z][a-z0-9-]*$/.test(x) && x !== 'KL_COMMANDS');
  const unimpl = declared.filter(c => !real.includes(c));
  const undeclared = real.filter(c => !declared.includes(c));
  chk('KL_COMMANDS 声明 = case 实际实现',
    unimpl.length === 0 && undeclared.length === 0 && declared.length > 20,
    '声明 ' + declared.length + ' · 实现 ' + real.length
    + (unimpl.length ? ' · 声明了没实现: ' + unimpl.join(' ') : '')
    + (undeclared.length ? ' · 实现了没声明: ' + undeclared.join(' ') : ''));
}

/* ── ⑦′ keybox 判据按后端分叉（三家共用一句必然在其中一家是错的） ───── */
console.log('── keybox 判据 ──');
const kbBlock = (screens.match(/const KEYBOX_HINT = \{([\s\S]*?)\n\};/) || [])[1] || '';
['tricky', 'teesim', 'omk'].forEach(b => chk('KEYBOX_HINT 有 ' + b + ' 这条', new RegExp(b + ':').test(kbBlock)));
const kbLines = [...kbBlock.matchAll(/: '([^']+)'/g)].map(m => m[1]);
chk('三条文案互不相同（共用一条等于没分叉）', new Set(kbLines).size === kbLines.length && kbLines.length >= 3, kbLines.length + ' 条');
chk('OMK 那条写明"解析不过会被模板覆盖回去"', /覆盖/.test((kbBlock.match(/omk: '([^']+)'/) || [])[1] || ''));
/* 客户端只拦"三家都必定不收"的形状；按根元素名判死的那句是错的（TEESim 不看根元素名） */
chk('界面不再按根元素名拦 keybox', !/<Keybox'|<AndroidAttestation'/.test(screens.replace(/KEYBOX_HINT[\s\S]*?\n\};/, '')));
chk('界面留了一条三家都成立的宽判据（<Key）', /v\.indexOf\('<Key'\) < 0/.test(screens));
/* 命令层：判据只活在 awk 里，webui.sh 不得自带根元素名判据（注释行除外） */
const shCode = sh.split('\n').filter(l => !/^\s*#/.test(l)).join('\n');
chk('webui.sh 代码里没有 AndroidAttestation 字面量', !/AndroidAttestation/.test(shCode));
chk('cmd_keybox_save 调用 keybox_check.awk', /keybox_check\.awk/.test(sh));
chk('awk 校验脚本在仓库里', fs.existsSync(SRC('module/backends/keybox_check.awk')));
/* 假数据里的哈希必须是完整 sha256：截半的哈希是最像真话的假数据 */
const kbHash = (bridge.match(/keybox_hash=([0-9a-f]+)/) || [])[1] || '';
chk('假数据的 keybox_hash 是完整 64 位十六进制', /^[0-9a-f]{64}$/.test(kbHash), kbHash.length + ' 位');

/* 补丁值的说明也必须分叉：同一个 no 一家是"报 0"、一家是"整个标签不报" */
const phBlock = (screens.match(/const PATCH_HINT = \{([\s\S]*?)\n\};/) || [])[1] || '';
chk('PATCH_HINT 两家各一条', /teesim:/.test(phBlock) && /tricky:/.test(phBlock));
const phLines = [...phBlock.matchAll(/: '([^']+)'/g)].map(m => m[1]);
chk('两条说明互不相同', new Set(phLines).size === phLines.length && phLines.length === 2, phLines.length + ' 条');
chk('TEESim 那条写明 no = 报告 0', /teesim: '[^']*报告 0/.test(phBlock));
chk('Tricky 那条写明 no = 标签不报', /tricky: '[^']*标签不报/.test(phBlock));
chk('两个 PATCH_HINT 都真的挂到了对应表单上',
  /form\(cur\.isDefault[\s\S]{0,220}PATCH_HINT\.teesim/.test(screens) && /PATCH_HINT\.tricky/.test(screens));

/* 三家互斥矩阵：状态必须是三态、三家齐全，并且以字面量读出来（动态下标会脱离 kv-shape 闸） */
chk('矩阵三家齐全', /BACKENDS = \[[\s\S]*?'tricky'[\s\S]*?'teesim'[\s\S]*?'omk'/.test(screens));
['tricky_state', 'teesim_state', 'omk_state'].forEach(k =>
  chk('界面按字面量读 ' + k, new RegExp('st\\.' + k).test(screens)));
chk('三态各有说法（没装 / 已禁用 / 启用）', /active: \['ok', '启用'\]/.test(screens)
  && /disabled:/.test(screens) && /absent: \['none', '未安装'\]/.test(screens));
chk('命令层输出这三态', /kv (teesim|tricky|omk)_state/.test(sh));
chk('冲突横幅点名是哪几家', /on\.map\(function \(b\) \{ return b\[1\]; \}\)\.join/.test(screens));

/* OMK 1.2.5：主页要显示后端自己的版本；配置页要有两个 daemon 与 keystore2 注入的
   **只读**状态。三条状态都来自 backend-info，界面不自己探测进程。 */
chk('主页状态条显示后端版本', /h\('span', 'hero-ver'/.test(screens) && /backendInfo\.module_version/.test(screens));
chk('OMK 配置页有运行状态卡（两个 daemon + keystore2 注入）',
  /function omkRuntime\(\)/.test(screens) && /omkReload[\s\S]{0,200}omkRuntime\(\)/.test(screens)
  && ['omk_keymint_alive', 'omk_injector_alive', 'omk_keystore_injected'].every(k => new RegExp('bi\\.' + k).test(screens)));
chk('命令层上报 OMK daemon/注入状态',
  /kv omk_keymint_daemon/.test(sh) && /kv omk_injector_daemon/.test(sh)
  && /kv omk_keystore_pid/.test(sh) && /kv omk_keystore_injected/.test(sh));
chk('omk_info 解析 1.2.5 的 [main].backend', /omk_backend=/.test(read('module/backends/omk_info.awk')));

/* 生效代价：命令层算出来的 apply_note 必须真的被界面读走（kv-shape 那道闸看不见
   局部 parseKV 结果上的读取，所以这里单独钉一条） */
chk('write() 优先采用命令层的 apply_note', /kv && kv\.apply_note/.test(screens));
chk('命令层会报 apply_scope / apply_note', /kv apply_scope "\$scope"/.test(sh) && /kv apply_note/.test(sh));
chk('[trust] 那一单的生效代价写进了界面说明',
  /整组热生效/.test(screens) && /重启【整机】/.test(screens));

/* overrides 写回面：六个可写字段、两种"锁"要分开说、keymaster 只记录要写明 */
chk('OV_SPEC 六个可写字段齐全',
  ['attestationSecurityLevel', 'keymasterSecurityLevel', 'attestationVersion', 'keymasterVersion',
    'verifiedBootKey', 'verifiedBootHash'].every(k => new RegExp(k + ':').test(screens)));
/* 分隔那个中点不写进正则：它在源码里是一个字节、在我这里可能被规范化成另一个，
   匹配失败会伪装成"枚举写错了"。只认值与词。
   KEYSTORE 只许出现在**说明**里（那正是我们警告不要用的一套），所以判的是那一行选项。 */
const ovLevel = (screens.match(/const OV_LEVEL = \[.*\];/) || [''])[0];
chk('等级枚举是 0/1/2 = Software/TrustedEnvironment/StrongBox（不是 KM1 那套）',
  /'0', '0[^']*Software'/.test(ovLevel) && /'1', '1[^']*TrustedEnvironment'/.test(ovLevel)
  && /'2', '2[^']*StrongBox'/.test(ovLevel) && ovLevel !== '' && !/KEYSTORE/.test(ovLevel),
  ovLevel.replace(/\s+/g, ' ').slice(0, 70));
chk('keymaster 两项写明"只记录，不上线"', /OV_RECORD_ONLY = \{ keymasterSecurityLevel/.test(screens));
/* 两种锁不是一回事：一台不可改 ≠ 本模块不写。上一版把 serial（来源 supplement）
   也说成"锁死为 REQUIRED"，那是把别家的判据安到这条头上。 */
chk('两种锁的说法分开（不再一律喊 REQUIRED）',
  /来源由守护进程决定/.test(screens) && /这一台的来源不是合成兜底值/.test(screens)
  && !/上游锁死为 REQUIRED，写了守护进程会丢弃'\)/.test(screens));
chk('写命令接在表单上', /'teesim-save-overrides', null, '已写入 overrides\.json'/.test(screens));
/* 隐私底线：serial/imei/meid 是 PRIVATE 类字段，值不许进本模块自己的日志 */
const logLines = sh.split('\n').filter(l => /^\s*log_(info|warn|err)/.test(l));
const leaks = logLines.filter(l => /\$v\b|\$\{v\}|\$val\b/.test(l));
chk('log_info/log_err 不插用户填的字段值', leaks.length === 0,
  leaks.map(l => l.trim().slice(0, 60)).join(' | '));

/* ── ⑧ 不许有半成品 ─────────────────────────────────────────────── */
console.log('── 完成度（不许留空壳）──');
const todo = [...screens.matchAll(/TODO|FIXME|待接入|尚未接|还没接/g)];
chk('没有 TODO/待接入占位', todo.length === 0, todo.map(m => m[0]).join(' '));
const emptyFn = [...screens.matchAll(/function (\w+)\([^)]*\) \{\s*\}/g)];
chk('没有空函数', emptyFn.length === 0, emptyFn.map(m => m[1]).join(' '));

console.log(fail ? '\n有断言失败' : '\n全部通过');
process.exit(fail);
