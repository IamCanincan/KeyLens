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
const subMap = [...((html.match(/var SUB_OF = \{([^}]*)\}/) || [])[1] || '').matchAll(/([a-z]+):\s*'([a-z]+)'/g)]
  .map(m => ({ child: m[1], parent: m[2] }));
const subPages = subMap.map(s => s.child);
const topPages = pages.filter(p => subPages.indexOf(p) < 0);
chk('PAGES 抽到 8 项（4 个一级 + 4 个二级）', pages.length === 8, JSON.stringify(pages));
/* 名单与配置是两页：名单页只有名单，配置页只有表单 */
chk('名单页与配置页各自独立',
  (function (){
    const a = html.indexOf('id="p-apps"'), b = html.indexOf('id="p-backend"');
    if (a < 0 || b < a) return false;
    const listPage = html.slice(a, b);
    const confPage = html.slice(b, b + 4000);
    return listPage.indexOf('id="appsBody"') >= 0 && listPage.indexOf('id="backendBody"') < 0
      && confPage.indexOf('id="backendBody"') >= 0 && confPage.indexOf('id="appsBody"') < 0;
  })());
chk('底栏 tab = 一级页（不多不少不重）',
  tabSrc.length === topPages.length && new Set(tabSrc.map(t => t[1])).size === tabSrc.length
  && topPages.every(p => tabSrc.some(t => t[1] === p)),
  'tabs=' + JSON.stringify(tabSrc.map(t => t[1])) + ' top=' + JSON.stringify(topPages));
chk('四个二级页都挂在底栏存在的父级下',
  subMap.length === 4 && subMap.every(s => pages.indexOf(s.child) >= 0
    && topPages.indexOf(s.parent) >= 0),
  JSON.stringify(subMap));
chk('功能页菜单行恰好覆盖四个二级页',
  (function (){
    const rows = [...html.matchAll(/class="menu-row" data-go="([a-z]+)"/g)].map(m => m[1]);
    return /id="p-func"/.test(html) && rows.length === 4
      && subPages.every(p => rows.indexOf(p) >= 0)
      && rows.every(p => subPages.indexOf(p) >= 0);
  })());
chk('Verified Boot 是独立一页', /id="p-boot"[\s\S]{0,600}id="bootHashBox"/.test(html)
  && !/id="bootHashGrp"/.test(html));
/* .menu-row 自己设了 display:flex，[hidden] 会被盖掉 —— 少了这条，能力门就关不掉 */
chk('菜单行支持 hidden', /\.menu-row\[hidden\]\{display:none\}/.test(html));
chk('每个 tab 图标都在 ICON 表里',
  tabSrc.every(t => iconSrc.indexOf(t[2] + ": '") >= 0),
  tabSrc.filter(t => iconSrc.indexOf(t[2] + ": '") < 0).map(t => t[2]).join(','));
chk('返回钮只给二级页用（图标与位置都在）',
  iconSrc.indexOf("back: '") >= 0 && /id="btnBack"/.test(html)
  && /btnBack\.innerHTML = svg\('back'\)/.test(html));
chk('.tabs 钉在视口底部（含安全区）',
  /\.tabs\{position:fixed/.test(html) && /\.tabs\{[\s\S]{0,200}bottom:calc\(var\(--inset-bottom\) \+ \d+px\)/.test(html));
chk('选中项用 secondary-container 药丸', /\.tab\.is-active\{background:var\(--secondary-container\)/.test(html));
/* 底栏上下跳的真因：切页入场把面板右移 24px，文档比视口宽 8.9px，WebView 把
   布局视口撑高（真机 975 → 987，首切 1083），bottom 定位的底栏跟着沉。滑动这
   200ms 必须裁掉横向溢出；静止时不裁（常开会改变整页文字的次像素抗锯齿）。 */
chk('滑动期间裁掉横向溢出', /\.wrap\.sliding\{overflow-x:clip/.test(html));
chk('滑动结束摘掉裁切类', /classList\.add\('sliding'\)/.test(fnBody('pageSlide'))
  && /classList\.remove\('sliding'\)/.test(fnBody('pageSlide')));
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
chk('applyPage 同步底栏选中态（二级页高亮父级）',
  /classList\.toggle\('is-active', on\)/.test(fnBody('applyPage'))
  && /barTabOf\(name\)/.test(fnBody('applyPage')));
chk('返回钮只由二级页控制', /btnBack\.hidden = !SUB_OF\[name\]/.test(fnBody('applyPage')));
/* replaceState 不发 popstate：少了这一步，点底栏只改地址栏、屏幕不动 */
chk('goTab 自己完成切页', /showTab\(name\);/.test(fnBody('goTab')));
chk('goBack 退掉二级页那一层历史', /SUB_OF\[S\.tab\]/.test(fnBody('goBack')) && /history\.back\(\)/.test(fnBody('goBack')));
/* 进二级页要压一条历史，系统返回才有东西可退（退回来就是功能菜单） */
chk('进二级页压历史、一级页只替换',
  /history\.pushState\(null, '', '#\/' \+ name\)/.test(fnBody('openPage'))
  && /navTo\(name\)/.test(fnBody('openPage')));
chk('从二级页切一级页先退掉那层历史', /pendingTab = name;\s*history\.back\(\)/.test(fnBody('goTab'))
  && /if \(pendingTab\)/.test(html));
chk('popstate 仍然接住真实的前进/后退', /window\.addEventListener\('popstate'/.test(html));
chk('多选时底栏给批量条让位', /body\.is-selecting \.tabs\{display:none\}/.test(html));
chk('切页不往历史里堆横向条目', /try \{ history\.replaceState\(null, '', '#\/' \+ name\); \}/.test(html));
chk('菜单行都接上了切页', /row\.addEventListener\('click'/.test(html) && /row\.dataset\.go/.test(html) && /openPage\(to\)/.test(html));

if (fail) {
  console.log('有断言失败');
  process.exit(1);
}
console.log('全部通过');
