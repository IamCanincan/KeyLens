/*=============================================================================
 * tools/md3e-build/build.mjs — 把 webui/ 的源码打成 module/webroot/index.html
 *
 * 为什么分源码又合产物：
 *  - 单文件是**已验证能跑**的形态（管理器只喂 webroot 下的文件，JS/CSS/字体走
 *    相对路径没验过），所以产物仍旧是一个 index.html；
 *  - 但 386KB 的单文件手改不可维护，所以源码拆成 index.html / app.css / app.js，
 *    组件与字体由这里注入。
 *
 * 用法：
 *   node tools/md3e-build/build.mjs            构建并写入 module/webroot/index.html
 *   node tools/md3e-build/build.mjs --check    只重建到临时文件，与已提交产物比对
 *                                              不一致就退非 0（CI 的新鲜度闸门）
 *
 * 字体：tokens.min.css 里 @font-face 指向 ./fonts/*.woff2。产物是单文件，没有
 * 相对路径可解析，所以这里把它们换成 data: URL 内联。Roboto 那几条直接删掉 ——
 * 管理器的 WebView 里网页字体不生效（实测退回系统字体），文本一律走 system-ui。
 * Material Symbols 不能删：组件内部的图标是连字串（expand_more / arrow_back），
 * 字体没落地就会把字面词画在界面上。
 *===========================================================================*/
import { build } from 'esbuild';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const src = path.join(repo, 'webui', 'src');
const pkg = path.join(here, 'node_modules/@materialwebunofficial/md3e-web');
const OUT_DEV = path.join(repo, 'webui', 'dist', 'index.html');
/* 换版之后（2026-10-30）：候选产物与上机产物**每次都一起写**。
   以前 --ship 只写 webroot，于是 dist 停在上一版，而 verify.mjs 默认读的正是 dist
   —— 台架会在一份过期产物上判"全绿"。现在两条路都写，--check 也两条都比。 */
const OUT_SHIP = path.join(repo, 'module', 'webroot', 'index.html');
const SHIP = process.argv.includes('--ship');
const CHECK = process.argv.includes('--check');

function die(msg) { console.error('✗ ' + msg); process.exit(1); }
fs.existsSync(pkg) || die('缺依赖：先在 tools/md3e-build 里跑 npm install');
fs.existsSync(path.join(src, 'app.js')) || die('缺 ' + path.join(src, 'app.js'));

/* ── 0. 图标名闸门：越界的连字名会被组件当字面词画出来，先拦住再构建 ── */
import { spawnSync } from 'node:child_process';
const gate = spawnSync(process.execPath, [path.join(here, 'icon-gate.mjs')], { encoding: 'utf8' });
if (gate.status !== 0) {
  process.stdout.write(gate.stdout + gate.stderr);
  die('图标名不在子集内 —— 产物会画出字面词，先改名字或改用 slot');
}

/* ── 1. JS：我们的 app.js 连同它 import 的 MD3E 组件一起打成一个 IIFE ── */
const bundleDir = path.join(repo, 'webui', 'dist');
fs.mkdirSync(bundleDir, { recursive: true });
const bundleOut = path.join(bundleDir, 'app.bundle.js');
await build({
  entryPoints: [path.join(src, 'app.js')],
  outfile: bundleOut,
  /* app.js 在 webui/src，依赖装在 tools/md3e-build/node_modules —— esbuild 默认
     从导入方往上找 node_modules，跨目录就找不到，所以显式给它一条解析路径。 */
  nodePaths: [path.join(here, 'node_modules')],
  bundle: true, format: 'iife', minify: true, target: 'chrome111',
  /* 品牌 KL 图随 JS 内联成 data URL —— 产物仍是单文件，webroot 不需要多推一张 PNG */
  loader: { '.png': 'dataurl' },
  legalComments: 'none', logLevel: 'warning',
});
const js0 = fs.readFileSync(bundleOut, 'utf8');
/* 内联进 <script> 的 JS 里若出现 </script，浏览器会在这里就把标签关掉，
   产物直接烂掉 —— 压缩后的字符串常量里完全可能出现，所以先转义再拼。 */
const js = js0.replace(/<\/script/gi, '<\\/script');
if (js !== js0) console.log('注意：JS 里有 </script 字面量，已转义 '
  + (js0.match(/<\/script/gi) || []).length + ' 处');

/* ── 2. 字体 → data: URL ───────────────────────────────────────────── */
const dataUrl = f => {
  const p = path.join(pkg, 'dist', 'fonts', f);
  fs.existsSync(p) || die('缺字体 ' + p);
  return 'data:font/woff2;charset=utf-8;base64,' + fs.readFileSync(p).toString('base64');
};

/* ── 3. tokens.css：删掉用不上的 Roboto 面，把符号字体内联 ─────────── */
let css = fs.readFileSync(path.join(pkg, 'dist', 'tokens.min.css'), 'utf8');
const before = css.length;
css = css.replace(/@font-face\s*\{[^}]*font-family:\s*['"]?Roboto['"]?[^}]*\}/g, '');
const robotoGone = before - css.length;
/* 库里三个符号字体族名（Outlined / Rounded / Sharp）的 @font-face **都指向同一个
   material-symbols-rounded.woff2**（在 dist/tokens.min.css 里逐条看过）。整份内联
   就是同一批 50 KB 字节落三遍 —— 915 KB 的产物里 100 KB 是纯重复。
   只留 Rounded 那一条：组件内部一律写 var(--md-icon-font-family, 'Material Symbols
   Rounded', …)，Rounded 在链首；库里唯一把 Outlined 放第一位的是 md-fab 的
   .material-symbols-outlined，而它不在本界面的 import 列表里。
   守这个前提的是 **verify.mjs 的运行时量测**（"画出来的图标都有对应字体面"：逐个
   元素取 computed font-family 的第一个族名，查它有没有 @font-face），不是静态扫 ——
   静态扫会被上面那两条**没人用的工具类规则**绊倒，判成假阳性。
   变异验过：把唯一那份 Rounded 也删掉 → 台架报"落空: Material Symbols Rounded×13"。 */
css = css.replace(/@font-face\s*\{[^}]*font-family:\s*['"]?Material Symbols (Outlined|Sharp)['"]?[^}]*\}/g, '');
let faces = 0;
css = css.replace(/url\((['"]?)\.\/fonts\/([a-z0-9-]+\.woff2)\1\)/g, (_, q, file) => {
  faces++;
  return 'url(' + dataUrl(file).replace(/[()]/g, s => '\\' + s) + ')';
});
/* 组件内部写的是 var(--md-icon-font-family, 'Material Symbols Rounded', …)，
   字体族名由库自己定，这里只保证它拿得到文件。 */

/* ── 4. 我们的样式与模板 ───────────────────────────────────────────── */
const appCss = fs.readFileSync(path.join(src, 'app.css'), 'utf8');
let html = fs.readFileSync(path.join(src, 'index.html'), 'utf8');
for (const [slot, text] of [['/*__TOKENS__*/', css], ['/*__APP_CSS__*/', appCss], ['/*__BUNDLE__*/', js]]) {
  if (!html.includes(slot)) die('模板里找不到占位符 ' + slot);
  html = html.replace(slot, () => text);
}
if (html.includes('__TOKENS__') || html.includes('__APP_CSS__') || html.includes('__BUNDLE__')) {
  die('产物里还留着未替换的占位符');
}

/* ── 5. 写出，或只做新鲜度比对 ─────────────────────────────────────── */
const kb = n => (n / 1024).toFixed(0) + ' KB';
if (CHECK) {
  let stale = 0;
  for (const [label, f] of [['webui/dist/index.html', OUT_DEV], ['module/webroot/index.html', OUT_SHIP]]) {
    const cur = fs.existsSync(f) ? fs.readFileSync(f, 'utf8') : '';
    if (cur === html) { console.log('ok   ' + label + ' 与 webui/ 源码一致'); continue; }
    console.error('✗ ' + label + (cur ? ' 与源码不一致（差了 ' + kb(Math.abs(html.length - cur.length)) + '）' : ' 不存在')
      + '\n  跑：node tools/md3e-build/build.mjs --ship 然后把产物一起提交。');
    stale = 1;
  }
  process.exit(stale);
}
for (const f of SHIP ? [OUT_DEV, OUT_SHIP] : [OUT_DEV]) {
  fs.mkdirSync(path.dirname(f), { recursive: true });
  fs.writeFileSync(f, html);
  console.log('已构建 ' + path.relative(repo, f) + '：' + kb(html.length));
}
console.log('  （JS ' + kb(js.length) + ' · tokens ' + kb(css.length) + ' · 内联字体 ' + faces + ' 个 · 省掉 Roboto ' + kb(robotoGone) + '）');
