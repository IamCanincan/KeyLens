/*=============================================================================
 * tools/module-scope-check.mjs — "用了兄弟模块的名字却没 import"的静态闸
 *
 * 为什么需要它：产物是 esbuild 把各模块**摊平进同一个 IIFE 作用域**打出来的，
 * 于是 screens.js 里一个从没 import 的 `draw()` 在浏览器里也能跑通，而在源码这一层
 * 它是自由变量 —— 换成 rollup/vite，或哪天作用域不再摊平，就是当场 ReferenceError。
 * 台架也抓不到：它只驱动切页，那几颗按钮没人点（2026-10-30 查界面问题时撞上）。
 *
 * 判据故意收窄成"只查我们自己的三个源文件互相之间"：名字必须是**另一个文件里
 * 确实声明过的**，否则一律放过 —— 这样浏览器全局、库的组件名、局部变量都不会误报，
 * 而漏掉的那一类（调用一个两边都没声明的名字）本来就是运行时 ReferenceError，
 * 与这条闸管的是两件事。
 *
 * 用法：node tools/module-scope-check.mjs
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const FILES = ['webui/src/bridge.js', 'webui/src/screens.js', 'webui/src/app.js'];

/* 注释与字符串先摘掉：注释里的"draw()"会被当成调用点，说明文字里的名字会被当成引用 */
function strip(src) {
  return src
    .replace(/\/\*[\s\S]*?\*\//g, ' ')
    .replace(/^[ \t]*\*.*$/gm, ' ')
    /* `//` 只在不是协议冒号后面时当注释：`'http://www.w3.org/2000/svg'` 这种
       字符串里的 `//` 以前会把整行后半截吃掉，字符串引号失配后整段代码被
       吞掉，`draw` 这类自由变量检查就静默失明。 */
    .replace(/(^|[^:])\/\/[^\n]*/g, '$1 ')
    .replace(/'(?:[^'\\]|\\.)*'/g, "''")
    .replace(/"(?:[^"\\]|\\.)*"/g, '""')
    .replace(/`(?:[^`\\]|\\.)*`/g, '``');
}

function declaredNames(code) {
  const out = new Set();
  for (const m of code.matchAll(/\b(?:function|class)\s+([A-Za-z_$][\w$]*)/g)) out.add(m[1]);
  for (const m of code.matchAll(/\b(?:var|let|const)\s+([A-Za-z_$][\w$]*)/g)) out.add(m[1]);
  /* 多变量与解构声明：`const a = 1, b = 2` / `let { x, y } = …`
     漏了 `b` 的话，别处调 `b()` 会被误报成"没 import"。 */
  for (const m of code.matchAll(/\b(?:var|let|const)\s+([^;\n]+)/g))
    for (const n of m[1].matchAll(/(?:^|,|\{|\s)\s*([A-Za-z_$][\w$]*)\s*(?==|,|$|;|\})/g)) out.add(n[1]);
  /* 形参与 catch 形参也是本文件的声明 —— 不收的话 `catch (e)` 里的 e
     会被报成"那是别的模块的名字"（第一版就是这么误报的）。 */
  for (const m of code.matchAll(/function\s*[A-Za-z_$\w]*\s*\(([^)]*)\)/g))
    for (const n of m[1].matchAll(/([A-Za-z_$][\w$]*)/g)) out.add(n[1]);
  for (const m of code.matchAll(/\(([^()]*)\)\s*=>/g))
    for (const n of m[1].matchAll(/([A-Za-z_$][\w$]*)/g)) out.add(n[1]);
  for (const m of code.matchAll(/([A-Za-z_$][\w$]*)\s*=>/g)) out.add(m[1]);
  for (const m of code.matchAll(/catch\s*\(\s*([A-Za-z_$][\w$]*)/g)) out.add(m[1]);
  return out;
}
function importedNames(code) {
  const out = new Set();
  /* 字符串已经在 strip() 里被替换成 ''，所以模块路径那一格是**空的** ——
     要求 `[^'"]+` 会让整条 import 匹配不上，于是每个 import 来的名字都被误报
     （第一版就是这么把 app.js 的 h / onToast / ICON 全报成"没 import"的）。 */
  for (const m of code.matchAll(/import\s+([^;]+?)\s+from\s*['"][^'"]*['"]/g))
    for (const n of m[1].matchAll(/([A-Za-z_$][\w$]*)/g)) out.add(n[1]);
  return out;
}

const decl = {}, imp = {}, code = {};
for (const f of FILES) {
  const c = strip(fs.readFileSync(path.join(repo, f), 'utf8'));
  code[f] = c;
  decl[f] = declaredNames(c);
  imp[f] = importedNames(c);
}

let bad = 0;
for (const f of FILES) {
  const local = decl[f], fromElsewhere = new Set();
  for (const g of FILES) {
    if (g === f) continue;
    for (const name of decl[g]) {
      if (local.has(name) || imp[f].has(name)) continue;
      /* 只认"调用点"（`name(`）与"标识符点"（`name.foo`）两种用法 ——
         裸出现在别的上下文里不算（我们想让这条闸安静地守着最容易出事的那一类）。 */
      const re = new RegExp('(?:[^(\\w$.]|^)' + name.replace(/\$/g, '\\$') + '\\s*(?:\\.|\\()');
      if (re.test(code[f])) fromElsewhere.add(name);
    }
  }
  if (fromElsewhere.size) {
    bad = 1;
    console.log('✗   ' + f + ' 直接用了别的模块的名字却没 import：' + [...fromElsewhere].join(' ')
      + '\n    产物能跑是 esbuild 摊平作用域摊出来的，源码层它是自由变量 —— 要么 import，'
      + '要么照 onToast/onReload 那样由 app.js 注册回调。');
  } else {
    console.log('ok  ' + f + '  跨模块的名字都 import 或注册过（本文件声明 ' + local.size + ' 个）');
  }
}
console.log(bad ? '\n有没绑定的跨模块引用' : '\n全部绑定');
process.exit(bad);
