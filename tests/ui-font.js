#!/usr/bin/env node
/*=============================================================================
 * tests/ui-font.js - WebUI 系统字体链的自检（CI 跑，不需要设备）
 *
 * 从 index.html 原样抽出 applyFont 执行，证明：
 *   · 字体文件名带哈希时生成唯一的 @font-face 族名，换文件不复用旧族名
 *   · --font 里同时带文件族名、系统族名和 system-ui 兜底
 *   · document.fonts.load 成功/失败会落到 THEME.fontLoaded
 *   · loadEnv、visibilitychange 重读与关于页状态确实接上了
 *============================================================================*/
'use strict';
const fs = require('fs');
const path = require('path');
const root = path.resolve(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'module/webroot/index.html'), 'utf8');

let fail = 0;
function chk(name, cond, detail) {
  if (cond) console.log('  ok   ' + name);
  else { console.log('  ✗    ' + name + (detail ? '  → ' + detail : '')); fail = 1; }
}
function extract(start) {
  const i = html.indexOf(start);
  if (i < 0) throw new Error('找不到源码块：' + start);
  const b = html.indexOf('{', i);
  if (b < 0) throw new Error('找不到左花括号：' + start);
  let depth = 0, quote = null, esc = false;
  for (let j = b; j < html.length; j++) {
    const c = html[j];
    if (quote) {
      if (esc) esc = false;
      else if (c === '\\') esc = true;
      else if (c === quote) quote = null;
      continue;
    }
    if (c === '"' || c === "'" || c === '`') { quote = c; continue; }
    if (c === '{') depth++;
    else if (c === '}') { depth--; if (depth === 0) return html.slice(i, j + 1); }
  }
  throw new Error('源码块没有闭合：' + start);
}
function fakeDoc(loadImpl) {
  const style = {};
  let tag = null;
  let added = 0;
  const doc = {
    documentElement: { style: { setProperty(k, v){ style[k] = v; } } },
    head: { appendChild(){ } },
    getElementById(id){ return id === 'sysfont' ? tag : null; },
    createElement(){ tag = { id: '', textContent: '' }; return tag; },
    fonts: {
      load(){ return loadImpl(); },
      add(){ added++; },
      delete(){ }
    }
  };
  return { doc, style, tag: () => tag, added: () => added };
}
const tick = () => new Promise(r => setTimeout(r, 0));

let code;
try {
  code = extract('function applyFont') + '\nreturn applyFont;';
} catch (e) {
  console.log('  ✗    抽取 applyFont 失败：' + e.message);
  process.exit(1);
}
function load(doc, theme, state, render) {
  return new Function('document', 'THEME', 'S', 'renderAbout', code)(doc, theme, state, render);
}

(async function (){
  console.log('── 文件字体 ──');
  const theme = {}, state = { tab: 'apps' };
  let rendered = 0;
  const a = fakeDoc(() => Promise.resolve([{}]));
  const fn = load(a.doc, theme, state, () => rendered++);
  const use1 = fn('google-sans-flex', 'pkg', 'fonts/font-abc123.ttf');
  await tick();
  chk('返回按文件生成的族名', use1 === '"ts-sys-font-abc123"', use1);
  chk('THEME 记录了文件与族名', theme.fontFile === 'fonts/font-abc123.ttf' && theme.font === 'google-sans-flex');
  chk('@font-face 用了同一族名', /font-family:"ts-sys-font-abc123"/.test(a.tag().textContent));
  chk('@font-face 先试 local 系统族名', /src:local\("google-sans-flex"\)/.test(a.tag().textContent));
  chk('@font-face 指向字体文件', /url\("fonts\/font-abc123\.ttf"\)/.test(a.tag().textContent));
  chk('--font 带文件族名、系统族名与 system-ui',
    /"ts-sys-font-abc123"/.test(a.style['--font']) &&
    /"google-sans-flex"/.test(a.style['--font']) &&
    /system-ui, sans-serif/.test(a.style['--font']), a.style['--font']);
  chk('加载成功记 true', theme.fontLoaded === true);
  chk('不在关于页时不重画', rendered === 0);

  const use2 = fn('arial', 'pkg2', 'fonts/font-def456.ttf');
  await tick();
  chk('换文件后族名必变', use2 !== use1, use2);
  chk('--font 跟着换', /"ts-sys-font-def456"/.test(a.style['--font']), a.style['--font']);

  const use3 = fn('arial', 'pkg', 'fonts/../evil.ttf');
  chk('非法路径退回族名', use3 === '"arial"', use3);
  chk('非法路径不记录文件', theme.fontFile === '');

  console.log('── 加载失败 ──');
  const t2 = {}, s2 = { tab: 'about' };
  let rendered2 = 0;
  const b = fakeDoc(() => Promise.reject(new Error('missing')));
  const fn2 = load(b.doc, t2, s2, () => rendered2++);
  fn2('google-sans-flex', 'pkg', 'fonts/font-missing.ttf');
  await tick();
  chk('字体加载失败记 false', t2.fontLoaded === false);
  chk('关于页会重画一次', rendered2 === 1);

  console.log('── CSS 失败、fetch 兜底 ──');
  const t3 = {}, s3 = { tab: 'apps' };
  const c = fakeDoc(() => Promise.reject(new Error('css blocked')));
  global.window = {
    FontFace: class {
      constructor(family, buf, opts){ this.family = family; this.buf = buf; this.opts = opts; }
      load(){ return Promise.resolve(this); }
    },
    fetch: () => Promise.resolve({ ok: true, arrayBuffer: () => Promise.resolve(new ArrayBuffer(8)) })
  };
  const fn3 = load(c.doc, t3, s3, () => {});
  fn3('google-sans-flex', 'pkg', 'fonts/font-ok.ttf');
  await tick();
  await tick();
  chk('CSS 失败时 fetch 字节兜底成功', t3.fontLoaded === true);
  chk('FontFace 已加入 document.fonts', c.added() === 1);

  console.log('── icons 镜像兜底 ──');
  const t4 = {}, s4 = { tab: 'apps' };
  const e = fakeDoc(() => Promise.reject(new Error('css blocked')));
  global.window.fetch = (url) => {
    if (url.indexOf('icons/') === 0) {
      return Promise.resolve({ ok: true, arrayBuffer: () => Promise.resolve(new ArrayBuffer(8)) });
    }
    return Promise.reject(new Error('ttf blocked'));
  };
  const fn4 = load(e.doc, t4, s4, () => {});
  fn4('google-sans-flex', 'pkg', 'fonts/font-x.ttf', 'icons/font-x.png');
  await tick();
  await tick();
  chk('主路径失败后试 icons 镜像', t4.fontLoaded === true);
  chk('镜像 FontFace 已加入', e.added() === 1);
  delete global.window;

  console.log('── 接线 ──');
  chk('loadEnv 传入了 sys_font_file 与 icons 镜像', /applyFont\(S\.env\.sys_font, S\.env\.sys_font_pkg, S\.env\.sys_font_file, S\.env\.sys_font_alt\)/.test(html));
  chk('可见时重读 env', /visibilitychange/.test(html) && /loadEnv\(\)\.then/.test(html));
  chk('关于页读 fontLoaded', /THEME\.fontLoaded === false/.test(html));
  chk('字体文件名允许带哈希', html.indexOf('[a-z0-9-]+\\.ttf') >= 0);

  if (fail) { console.log('有断言失败'); process.exit(1); }
  console.log('全部通过');
})();
