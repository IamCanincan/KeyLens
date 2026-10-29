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

console.log('── 三后端条目语法 ──');
chk('名单同时取 target-meta', /call\('target-meta'\)/.test(html));
chk('target-meta 按 TAB 拆四列', /f\[0\]\] = \{ base: f\[1\] \|\| '', kind: f\[2\] \|\| 'plain', detail: f\[3\] \|\| '' \}/.test(html));
chk('有基础包名集合（判重/未纳入）', /function targetBaseSetOf\(\)/.test(html));
chk('Tricky 模式选择对话框存在', /id="modeDialog"/.test(html) && /MODE_LABEL = \{ auto: '自动', leaf: '叶证书', generate: '证书生成' \}/.test(html));
chk('set-mode 走写命令校验', /'set-mode': 'changed'/.test(html));
chk('后端页存在', /id="p-backend"/.test(html) && /function renderBackend\(\)/.test(html));
chk('backend-info 契约键', /'backend-info': 'backend backend_name target_file target_entries keybox_file keybox_exists'/.test(html));
chk('TEESim 用户/UID 标签', /'用户 ' \+ meta\.detail/.test(html) && /'UID ' \+ \(meta\.detail/.test(html));

console.log('── 后端可编辑表单 ──');
chk('三后端表单规格存在', /var BACKEND_FORMS = \{/.test(html) && /teesim: \[/.test(html) && /omk: \[/.test(html));
chk('保存走各后端写命令', /cmd: 'teesim-save'/.test(html) && /cmd: 'omk-save-injector'/.test(html)
  && /cmd: 'omk-save-config'/.test(html) && /cmd: 'tricky-save-patch'/.test(html));
chk('只提交改动字段', /if \(String\(val\) !== String\(initial\)\) payload\.push\(f\.key \+ '=' \+ b64\(String\(val\)\)\)/.test(html));
chk('keybox 粘贴对话框', /id="keyboxDialog"/.test(html) && /call\('keybox-save', b64\(xml\)\)/.test(html));
chk('保存命令有返回形状校验', /'teesim-save': 'saved fields'/.test(html) && /'keybox-save': 'saved keybox_file keybox_bytes'/.test(html));
chk('写命令清单包含后端保存', /teesim-save omk-save-injector omk-save-config tricky-save-patch keybox-save/.test(html));

console.log('── 底栏导航 ──');
const pagesSrc = (html.match(/var PAGES = \[([^\]]*)\]/) || [])[1] || '';
const pages = (pagesSrc.match(/'[a-z]+'/g) || []).map(s => s.slice(1, -1));
const tabSrc = [...html.matchAll(/data-tab="([a-z]+)" data-icon="([a-z]+)"/g)];
const iconSrc = extract('var ICON =');
chk('PAGES 抽到 6 项', pages.length === 6, JSON.stringify(pages));
chk('底栏 tab 与 PAGES 一一对应（不多不少不重）',
  tabSrc.length === pages.length && new Set(tabSrc.map(t => t[1])).size === tabSrc.length
  && pages.every(p => tabSrc.some(t => t[1] === p)),
  'tabs=' + JSON.stringify(tabSrc.map(t => t[1])));
chk('每个 tab 图标都在 ICON 表里',
  tabSrc.every(t => iconSrc.indexOf(t[2] + ": '") >= 0),
  tabSrc.filter(t => iconSrc.indexOf(t[2] + ": '") < 0).map(t => t[2]).join(','));
chk('顶栏返回钮的图标已随返回一起撤掉', iconSrc.indexOf("back: '") < 0);
chk('.tabs 钉在视口底部（含安全区）',
  /\.tabs\{position:fixed/.test(html) && /\.tabs\{[\s\S]{0,200}bottom:calc\(var\(--inset-bottom\) \+ \d+px\)/.test(html));
chk('选中项用 secondary-container 药丸', /\.tab\.is-active\{background:var\(--secondary-container\)/.test(html));
const wrapPad = +(html.match(/\.wrap\{padding:0 var\(--sp4\) calc\((\d+)px/) || [0, 0])[1];
chk('.wrap 底部留白给药丸让位（≥96px）', wrapPad >= 96, 'wrapPad=' + wrapPad);
const snackBottom = +(html.match(/\.snackbar\{[\s\S]{0,160}bottom:calc\(var\(--inset-bottom\) \+ (\d+)px/) || [0, 0])[1];
chk('提示条浮在底栏之上（≥72px）', snackBottom >= 72, 'snackBottom=' + snackBottom);
/* 断言只打在函数自己的 bodies 里：跨过去匹配会读到下一个函数，
   改坏这一个照样绿。 */
function fnBody(name) {
  const i = html.indexOf('function ' + name + '(');
  if (i < 0) throw new Error('找不到函数：' + name);
  const end = html.indexOf('\n}', i);
  if (end < 0) throw new Error('函数没有闭合：' + name);
  return html.slice(i, end);
}
chk('applyPage 同步底栏选中态', /classList\.toggle\('is-active', on\)/.test(fnBody('applyPage')));
chk('顶栏返回钮确实不再由 applyPage 控制', !/btnBack/.test(fnBody('applyPage')));
/* replaceState 不发 popstate：少了这一步，点底栏只改地址栏、屏幕不动 */
chk('goTab 自己完成切页', /showTab\(name\);/.test(fnBody('goTab')));
chk('popstate 仍然接住真实的前进/后退', /window\.addEventListener\('popstate'/.test(html));
chk('多选时底栏给批量条让位', /body\.is-selecting \.tabs\{display:none\}/.test(html));
chk('切页不往历史里堆横向条目', /try \{ history\.replaceState\(null, '', '#\/' \+ name\); \}/.test(html));
chk('概览入口列表与返回钮没有留下残骸',
  !/home-menu/.test(html) && !/id="btnBack"/.test(html) && !/data-go=/.test(html)
  && !/function goBack\(/.test(html));

if (fail) {
  console.log('有断言失败');
  process.exit(1);
}
console.log('全部通过');
