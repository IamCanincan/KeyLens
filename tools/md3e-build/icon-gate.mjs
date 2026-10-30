import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

/* 图标名闸门。
 *
 * MD3E 自带的是**子集**图标字体（257 个连字，50KB；全量圆体 5.3MB，不可能内联）。
 * 组件把图标名当连字文本画：名字不在子集里，界面就把 "security"、"DASHBOARD"
 * 这种字面词原样画在屏幕上 —— 不是降级，是脏。
 * 所以凡是"以名字传图标"的地方（navigation-bar 的 items、各组件的 icon 属性、
 * 我们自己 JS 里的图标常量）都必须落在子集内，这一条在构建时把关。
 * 需要子集外的图形时走 slot（md-list-item 有 start/end 槽），我们自己画内联 SVG。
 *
 *   node tools/md3e-build/icon-gate.mjs            检查 webui/src，非 0 表示有名字越界
 *   node tools/md3e-build/icon-gate.mjs --list     只打印子集
 */
const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
/* npm 包只发 dist/src/types，子集清单 icons.txt 不在里面，所以仓库里存了一份
   vendor 副本（257 个名字，就是这份字体能用哪些图标的唯一答案）。
   两处都在时以 vendor 为准 —— 它是随产物提交的，CI 上也能跑。 */
const HERE_LIST = path.join(here, 'vendor', 'icons.txt');
const PKG_LIST = path.join(here, 'node_modules/@materialwebunofficial/md3e-web/tools/material-symbols/icons.txt');
const LIB_ICONS = fs.existsSync(HERE_LIST) ? HERE_LIST : PKG_LIST;
const SRC = path.join(repo, 'webui', 'src');

if (!fs.existsSync(LIB_ICONS)) {
  console.error('✗ 找不到子集清单：' + LIB_ICONS + '\n  把库的 tools/material-symbols/icons.txt 复制到 tools/md3e-build/vendor/');
  process.exit(1);
}
const allow = new Set(fs.readFileSync(LIB_ICONS, 'utf8').split(/\s+/).filter(Boolean));
if (process.argv.includes('--list')) { console.log([...allow].sort().join(' ')); process.exit(0); }

const used = new Map();          // name -> [where]
const add = (name, where) => {
  if (!name || !/^[a-z0-9_]+$/.test(name)) return;
  if (!used.has(name)) used.set(name, new Set());
  used.get(name).add(where);
};

for (const f of fs.readdirSync(SRC)) {
  const p = path.join(SRC, f);
  const text = fs.readFileSync(p, 'utf8');
  const rel = 'webui/src/' + f;
  /* 图标名表（export const ICON = { … }）里的每个值都是图标名 —— 这里的键叫
     sync/over/backend，不匹配下面那三种"icon"写法。上一版就是因为只认
     icon="x" / icon:'x' / setAttribute('icon','x')，7 个名字只看到 4 个。 */
  const tbl = text.match(/export const ICON = \{([\s\S]*?)\n\};/);
  if (tbl) {
    for (const m of tbl[1].matchAll(/:\s*'([a-z0-9_]+)'/g)) add(m[1], rel + ' ICON 表');
  }
  text.split('\n').forEach((line, i) => {
    const at = rel + ':' + (i + 1);
    /* 三种写法都要盖住，漏一种就是闸门有个静默的洞：
       icon="x"（HTML）、icon: 'x'（对象字面量）、setAttribute('icon', 'x')（JS） */
    for (const m of line.matchAll(/\bicon\s*[:=]\s*['"]([a-z0-9_]+)['"]/g)) add(m[1], at);
    for (const m of line.matchAll(/['"]icon['"]\s*,\s*['"]([a-z0-9_]+)['"]/g)) add(m[1], at);
    for (const m of line.matchAll(/"icon"\s*:\s*"([a-z0-9_]+)"/g)) add(m[1], at);
    /* 单引号 JSON 串里（items='[{"icon":"home"}]'）已经被上面第二条覆盖 */
  });
}

/* 第二件：`ICON.xxx` 引用的键必须在表里存在。缺键**不报错**——取出来是 undefined，
   组件就把那一格画成空槽。2026-10-30 底栏「伪装」整格空了，就是 PAGES 里写了
   ICON.tune 而表里只有 restart:'tune'；上面那三种字符串写法一个都盖不到它。 */
const iconKeys = new Set();
const iconUses = [];
for (const f of fs.readdirSync(SRC)) {
  const text = fs.readFileSync(path.join(SRC, f), 'utf8');
  const rel = 'webui/src/' + f;
  const tbl = text.match(/export const ICON = \{([\s\S]*?)\n\};/);
  if (tbl) for (const m of tbl[1].matchAll(/([A-Za-z]+)\s*:/g)) iconKeys.add(m[1]);
  text.split('\n').forEach((line, i) => {
    for (const m of line.matchAll(/ICON\.([A-Za-z]+)/g)) iconUses.push(rel + ':' + (i + 1) + '  ICON.' + m[1]);
  });
}
const missingKeys = iconUses.filter(u => !iconKeys.has(u.split('ICON.')[1]));

const bad = [...used.entries()].filter(([n]) => !allow.has(n)).sort();
console.log(`子集 ${allow.size} 个连字；界面用到 ${used.size} 个名字；ICON 表 ${iconKeys.size} 个键、引用 ${iconUses.length} 处`);
if (missingKeys.length) {
  console.log('✗ 引用了 ICON 表里不存在的键（取出来是 undefined，那一格会画成空槽）：');
  for (const m of missingKeys) console.log('   ' + m);
  process.exit(1);
}
if (!bad.length) { console.log('ok 全部在子集内，ICON 引用都能对上'); process.exit(0); }
console.log('✗ 这些名字不在子集里，界面上会画成字面词：');
for (const [n, wh] of bad) console.log(`   ${n.padEnd(22)} ${[...wh].join(', ')}`);
console.log('\n可选做法：换成子集内的名字（--list 看全表），或改用 slot 自己画 SVG。');
process.exit(1);
