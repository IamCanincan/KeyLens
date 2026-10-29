#!/usr/bin/env node
/*=============================================================================
 * tests/ui-shape.js - WebUI 关键字段契约的自检（CI 跑，不需要设备）
 *
 * 从 module/webroot/index.html 里**原样抽出** KV_REQUIRED / parseKV / kvMissing
 * 执行，证明缺键会被点名；同时静态确认 call() 真的接上了它、超时标记真的带到了
 * call()。不是另抄一份规则，抽出失败就当场报错。
 *===========================================================================*/
'use strict';
const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'module/webroot/index.html'), 'utf8');

let fail = 0;
function chk(name, cond, detail) {
  if (cond) {
    console.log('  ok   ' + name);
  } else {
    console.log('  ✗    ' + name + (detail ? '  → ' + detail : ''));
    fail = 1;
  }
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
    else if (c === '}') {
      depth--;
      if (depth === 0) return html.slice(i, j + 1);
    }
  }
  throw new Error('源码块没有闭合：' + start);
}

let kvMissing;
try {
  const code = [
    extract('var KV_REQUIRED ='),
    extract('function parseKV'),
    extract('function kvMissing')
  ].join('\n');
  /* 直接执行抽出来的真实源码；不是复制一份规则 */
  kvMissing = new Function(code + '\nreturn kvMissing;')();
} catch (e) {
  console.log('  ✗    抽取/执行 KV_REQUIRED 失败：' + e.message);
  process.exit(1);
}

const goodStatus = 'state=ok\nbackend=teesim\nmod_version=2.2.19.5\n' +
  'target_file=/data/adb/teesim/config.json\ntarget_exists=1\ndaemon_alive=1';

console.log('── 缺键识别 ──');
chk('合法 status 不报', kvMissing('status', goodStatus) === null);
chk('缺 daemon_alive 只点名它',
  JSON.stringify(kvMissing('status', goodStatus.replace('daemon_alive=1', ''))) === JSON.stringify(['daemon_alive']));
chk('空响应点名全部 6 个键',
  (kvMissing('status', '') || []).length === 6,
  JSON.stringify(kvMissing('status', '')));
chk('合法 remove-apps 不报', kvMissing('remove-apps', 'removed=2') === null);
chk('缺 removed 会点名',
  JSON.stringify(kvMissing('remove-apps', '')) === JSON.stringify(['removed']));
chk('未知命令（targets）不校验', kvMissing('targets', 'com.a\ncom.b') === null);
chk('合法 contract 不报', kvMissing('contract', 'api=2\ncommands=status') === null);
chk('缺 commands 会点名',
  JSON.stringify(kvMissing('contract', 'api=2\n')) === JSON.stringify(['commands']));

console.log('── 接线 ──');
chk('call() 用 kvMissing 校验返回值', /kvMissing\(cmd, res\.text\)/.test(html));
chk('S.contract 有 shape 字段', /shape: ''/.test(html));
chk('横幅分支读 S.contract.shape', /S\.contract\.shape/.test(html));
chk('超时标记从 callExec 带到 call',
  /timeout: true/.test(html) && /timeout: !!r\.timeout/.test(html));

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
chk('Material Web bundle 含 gb 按钮', html.indexOf('customElements.define("md-gb-button"') >= 0);
chk('Material Web bundle 含列表项', html.indexOf('customElements.define("md-gb-list-item"') >= 0);
chk('Material Web bundle 含文本域', html.indexOf('md-outlined-text-field') >= 0);
chk('Material Web bundle 含对话框', html.indexOf('md-dialog') >= 0);

if (fail) {
  console.log('有断言失败');
  process.exit(1);
}
console.log('全部通过');
