#!/usr/bin/env node
'use strict';
/*
 * tests/ui-next-shape.js —— 新版界面源码（webui/src）的静态自检
 *
 * 为什么不改 tests/ui-shape.js 而是另开一套：ui-shape 守的是**当前线上那一版**
 * （module/webroot/index.html，grep `var X =`、`.grp{}`、`id="p-func"` 这些锚点）。
 * 新版产物是 ESM 压缩过的，那些锚点全没了 —— 直接改写会让旧产物在换版之前失去护栏。
 * 所以两套并存：换版那一个提交里同时退役旧的、提升新的，不留空窗。
 *
 * 这套里最值钱的是第 ② 组：**表单字段名必须被命令层的校验分支接受**。
 * 两边都是字符串，对不上时不是"少一个字段"，而是整单被 `*) echo 未知字段` 拒掉 ——
 * 用户点保存只看到一句"未知字段：xxx"，而这在运行时之前完全可以静态查出来。
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
  EXPECT_API === (sh.match(/^TAA_API=(\d+)/m) || [])[1],
  '界面 ' + EXPECT_API + ' / 命令层 ' + (sh.match(/^TAA_API=(\d+)/m) || [])[1]);
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
const cmds = ((sh.match(/^TAA_COMMANDS="([\s\S]*?)"$/m) || [])[1] || '').replace(/\\\n/g, ' ').split(/\s+/).filter(Boolean);
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

/* ── ⑤ 层级与目的地：主体是后端面板 ─────────────────────────────── */
console.log('── 层级 ──');
const pages = [...app.matchAll(/\{ id: '([a-z]+)', label: '([^']+)', icon: ICON\.([a-z]+)/g)];
chk('四格目的地', pages.length === 4, pages.map(p => p[2]).join('/'));
chk('落地页是后端控制面板', pages[0] && pages[0][1] === 'backend' && pages[0][2] === '后端', pages[0] && pages[0][1] + '=' + pages[0][2]);
chk('自动更新排在面板之后（它是附加功能，不是主体）',
  pages.findIndex(p => p[1] === 'autosync') === 1);
chk('名单在后端面板内，不是独立目的地',
  !pages.some(p => p[1] === 'targets') && /function listSection\(\)/.test(screens));
chk('自动更新那一格在第二位', pages.findIndex(p => p[1] === 'props') === 2);
chk('自动更新页明说这是本模块附加的', /这是本模块附加的功能/.test(screens));
chk('落地页取数含名单与后端', /id: 'backend'[^}]*need: \[[^\]]*'backend'[^\]]*'lists'/.test(app));

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
chk('crypto 种子不渲染', !/root_kek_seed|kak_seed|shared_secret_seed|shared_secret_nonce|auth_token_hmac_key/.test(screens));
chk('serial/imei/meid 不进日志或提示', !/console\.log\(.*(serial|imei)/.test(screens));
chk('命令参数走单引号转义（防注入）', /String\(arg\)\.replace\(\/'\/g, "'\\\\''"\)/.test(bridge));
chk('模板有安全区样式表与 viewport-fit', /\/internal\/insets\.css/.test(tpl) && /viewport-fit=cover/.test(tpl));
chk('文本字体是 system-ui，不引网页文本字体', /--md-sys-typescale-font-family: system-ui/.test(css));
chk('图标字体族名保留（组件画连字要用）', !/--md-icon-font-family\s*:/.test(css));

/* ── ⑧ 不许有半成品 ─────────────────────────────────────────────── */
console.log('── 完成度（不许留空壳）──');
const todo = [...screens.matchAll(/TODO|FIXME|待接入|尚未接|还没接/g)];
chk('没有 TODO/待接入占位', todo.length === 0, todo.map(m => m[0]).join(' '));
const emptyFn = [...screens.matchAll(/function (\w+)\([^)]*\) \{\s*\}/g)];
chk('没有空函数', emptyFn.length === 0, emptyFn.map(m => m[1]).join(' '));

console.log(fail ? '\n有断言失败' : '\n全部通过');
process.exit(fail);
