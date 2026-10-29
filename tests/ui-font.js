#!/usr/bin/env node
/*=============================================================================
 * tests/ui-font.js - WebUI 字体来源的自检（CI 跑，不需要设备）
 *
 * 机上的 WebView 156 在 system-ui 下会跟随系统字体（其它模块的 WebUI 也是这样），
 * 所以界面不再探测、复制或加载字体文件。这个测试防止有人把 @font-face /
 * 字体文件管线又加回来。
 *===========================================================================*/
'use strict';
const fs = require('fs');
const path = require('path');
const root = path.resolve(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'module/webroot/index.html'), 'utf8');
const sh = fs.readFileSync(path.join(root, 'module/webui.sh'), 'utf8');

let fail = 0;
function chk(name, cond, detail) {
  if (cond) console.log('  ok   ' + name);
  else { console.log('  ✗    ' + name + (detail ? '  → ' + detail : '')); fail = 1; }
}

console.log('── 字体来源 ──');
chk('界面字体是 system-ui',
  /--font:\s*system-ui,\s*sans-serif/.test(html));
chk('Material Web 字体令牌跟随 --font',
  /--md-ref-typeface-plain:\s*var\(--font\)/.test(html));
chk('没有 @font-face 规则', !/@font-face\s*\{/.test(html));
chk('没有字体文件加载代码',
  !/(applyFont|sysfont|ts-sys|sys_font)/.test(html));
chk('命令层不再探测字体',
  !/(sys_font|fontpkg|GoogleSansFlex|@font-face)/.test(sh));
chk('关于页显示跟随系统', /跟随系统（system-ui）/.test(html));

console.log('── 脚本语法 ──');
const scripts = [...html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)].map(m => m[1]);
chk('抽到内联脚本', scripts.length > 0, 'scripts=' + scripts.length);
scripts.forEach((code, i) => {
  try {
    new Function(code);
    chk('第 ' + (i + 1) + ' 段脚本可解析', true);
  } catch (e) {
    chk('第 ' + (i + 1) + ' 段脚本可解析', false, e.message);
  }
});

if (fail) { console.log('有断言失败'); process.exit(1); }
console.log('全部通过');
