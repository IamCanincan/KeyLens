import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

/* 产物自检（CI 可跑，不需要 npm/esbuild）。
 *
 * 完整的新鲜度检查要在 CI 里重建再比字节，那要装依赖；这里守的是**不需要重建也能
 * 判死**的那几类：占位符没替换、产物比源码还小、图标越界（由 icon-gate 负责）、
 * 以及源码里有文件没被 import（那等于有一屏代码永远不会进产物）。
 */
const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const SRC = path.join(repo, 'webui', 'src');
/* 默认查**候选**产物（webui/dist），因为新版还没换掉 webroot 里的旧界面；
   换版之后按 `check-artifact.mjs module/webroot/index.html` 查真正上机的那份。 */
const OUT = process.argv[2]
  ? path.resolve(repo, process.argv[2])
  : path.join(repo, 'webui', 'dist', 'index.html');

let bad = 0;
const chk = (name, ok, detail) => { if (!ok) bad++; console.log(`${ok ? 'ok  ' : '✗   '} ${name}${detail ? '  — ' + detail : ''}`); };

if (!fs.existsSync(OUT)) { console.log('✗   找不到产物 ' + OUT); process.exit(1); }
console.log('查的是：' + path.relative(repo, OUT));
const html = fs.readFileSync(OUT, 'utf8');

chk('没有未替换的占位符', !/__TOKENS__|__APP_CSS__|__BUNDLE__/.test(html));
chk('产物带 MD3E 组件注册', /customElements\.define\("md-(top-app-bar|navigation-bar|card|list)/.test(html));
chk('产物内联了符号字体（离线可用）', /@font-face[^@]{0,400}Material Symbols Rounded/.test(html) && /data:font\/woff2/.test(html));
/* 符号字体只该有一份 @font-face：库里三个族名指向同一个 woff2，内联三遍就是
   100 KB 纯重复。而删掉 Outlined/Sharp 那两条的**前提**是"没有组件把它们放在
   族名链首"—— 前提要有人守，否则以后 import 一个 md-fab 就是图标静默变成字面词。 */
const facesAll = [...html.matchAll(/@font-face\s*\{[^}]*font-family:\s*['"]?Material Symbols ([A-Za-z]+)/g)].map(m => m[1]);
chk('Material Symbols 只内联一份（不重复落字节）',
  facesAll.length === 1 && facesAll[0] === 'Rounded', facesAll.join('/'));
const firstBad = [...html.matchAll(/font-family:\s*['"]?Material Symbols (Outlined|Sharp)['"]?/g)]
  .map(m => m[1]).filter(x => x);
/* 上面那条判得太宽：库里那两个工具类（.material-symbols-outlined / -sharp）本身
   就把族名写在链首，而**没有任何被打包的组件用它们**（唯一用到的 md-fab 不在
   import 列表里）。死规则不渲染，就不该判死 —— 真正会坏的是"某个画出来的元素
   第一个族名没有对应 @font-face"，那是运行时才有的事实，交给 verify.mjs 用
   getComputedStyle 去量。这里只守静态上确定会坏的那一条：族名变量。 */
const iconVar = (html.match(/--md-icon-font-family:\s*['"]?Material Symbols ([A-Za-z]+)/) || [])[1];
chk('图标族名变量指向内联了的那一份', !iconVar || iconVar === 'Rounded', iconVar || '（产物里没有这个变量，组件走自己的回退链）');
if (firstBad.length) console.log('  ok   存在 ' + firstBad.length + ' 条 Outlined/Sharp 工具类规则（未渲染，由 verify 的量测兜）');
chk('产物里没有指向网络的字体/脚本 URL',
  !/<script[^>]+src=["']https?:/.test(html) && !/url\(["']?https?:/i.test(html),
  (html.match(/url\(["']?https?:[^)]{0,40}/i) || [])[0] || '');
/* 空分支正则扫描：扫源码（去掉注释与字符串），不扫产物 —— 产物是压缩过的，
   正则字面量早就变形了，扫它只会命中库里的噪音。命中注释也会误报，所以先剥掉
   注释：一个天天误报的闸门最后会被所有人忽略，那比没有闸门更糟。 */
const EMPTY_ALT = /\/(?:[^/\n\\]|\\.){0,60}\|\|(?:[^/\n\\]|\\.){0,60}\//;
for (const f of fs.readdirSync(SRC).filter(x => x.endsWith('.js'))) {
  const raw = fs.readFileSync(path.join(SRC, f), 'utf8');
  const code = raw.replace(/\/\*[\s\S]*?\*\//g, '').split('\n')
    .map(l => l.replace(/(^|[^:])\/\/.*$/, '$1')).join('\n');
  const hit = code.split('\n').find(l => EMPTY_ALT.test(l));
  chk('源码 ' + f + ' 没有空分支正则', !hit, hit ? hit.trim().slice(0, 56) : '');
}

/* 每个源码文件都必须被入口 import —— 漏一个就是那一屏代码进不了产物，
   而本地跑 dist 时未必看得出来（没被 import 的文件里的函数根本不存在）。 */
const entry = fs.readFileSync(path.join(SRC, 'app.js'), 'utf8');
const screens = fs.readFileSync(path.join(SRC, 'screens.js'), 'utf8');
const reached = new Set(['app.js']);
for (const m of entry.matchAll(/from '\.\/([a-z]+\.js)'/g)) reached.add(m[1]);
for (const m of screens.matchAll(/from '\.\/([a-z]+\.js)'/g)) reached.add(m[1]);
for (const f of fs.readdirSync(SRC)) {
  if (!f.endsWith('.js')) continue;
  chk('源码 ' + f + ' 被入口引用', reached.has(f), reached.has(f) ? '' : '它不会进产物');
}

/* 产物体积异常小 = 多半是构建被截断 */
/* 用**字节数**，不用 html.length：那是 UTF-16 码元数，中文按 3 字节存，
   904 KB 的文件量出 347"KB"，看着像被截断。 */
const BYTES = fs.statSync(OUT).size;
chk('产物不小于 400 KB（否则像被截断）', BYTES > 400 * 1024, (BYTES / 1024).toFixed(1) + ' KB');

console.log(bad ? '\n' + bad + ' 项不通过' : '\n全部通过');
process.exit(bad ? 1 : 0);
