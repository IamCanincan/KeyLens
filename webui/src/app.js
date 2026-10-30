/*=============================================================================
 * webui/src/app.js — 入口：注册组件、装壳、路由
 *
 * import 清单就是"这版用了哪些组件"的唯一答案 —— 少一行，那个标签会静默降级成
 * 未知元素（什么都不画）。刻意不引 barrel：库的 index 会把 46 个组件全拖进来，
 * 实测 2962 KB，单文件页面扛不住。
 *===========================================================================*/
import '@materialwebunofficial/md3e-web/components/md-top-app-bar.js';
import '@materialwebunofficial/md3e-web/components/md-navigation-bar.js';
import '@materialwebunofficial/md3e-web/components/md-card.js';
import '@materialwebunofficial/md3e-web/components/md-list.js';
import '@materialwebunofficial/md3e-web/components/md-button.js';
import '@materialwebunofficial/md3e-web/components/md-chip.js';
import '@materialwebunofficial/md3e-web/components/md-icon-button.js';
import '@materialwebunofficial/md3e-web/components/md-switch.js';
import '@materialwebunofficial/md3e-web/components/md-text-field.js';
import '@materialwebunofficial/md3e-web/components/md-select.js';
import '@materialwebunofficial/md3e-web/components/md-loading-indicator.js';
import '@materialwebunofficial/md3e-web/components/md-snackbar.js';

import {
  S, DEMO, findBridge, attachBridge, checkContract, ensure, loadBase, hasCmd,
} from './bridge.js';
import { applyAccent } from './theme.js';
import {
  ICON, h, renderHome, renderFunc, renderFuncSub, renderLog, renderSettings, FUNC_PAGES,
  onToast, onReload, onAuto, onApplyTheme, onDraw, onOpenSub,
} from './screens.js';

/* 四格，2026-10-30 定：主页 / 功能 / 日志 / 设置。
   分工按"这一格回答的是什么问题"：
     主页 —— 在不在跑、哪一家在跑（状态条 + 三家矩阵）；
     功能 —— 所有功能集中成一张菜单，点进去是二级页；长列表（名单、属性对照）
             默认只留一个入口，点进去才画，菜单页本身落地即用；
     日志 —— 出了什么事；
     设置 —— 界面自己的事：外观 + 界面自检（属性伪装/Verified Boot 是改设备状态的
             **功能**，在【功能】页的二级里）。
   二级页压一层 pushState：顶栏出返回箭头、系统返回键回菜单（popstate 接管），
   一级页之间仍是 replaceState，系统返回一次就退回管理器。 */
const PAGES = [
  { id: 'home', label: '主页', icon: ICON.home, need: ['base', 'backend'] },
  { id: 'func', label: '功能', icon: ICON.func, need: ['base', 'backend'] },
  { id: 'log', label: '日志', icon: ICON.log, need: ['log'] },
  { id: 'settings', label: '设置', icon: ICON.settings, need: [] },
];

const bar = document.getElementById('bar');
const view = document.getElementById('view');
const nav = document.getElementById('nav');
nav.items = PAGES.map(function (p) { return { icon: p.icon, label: p.label }; });

/* 深/浅：跟随系统时优先用管理器报的 sys_dark —— CSS 的 prefers-color-scheme
   在部分 WebView 里不跟着系统的"深色模式"开关走，而 env.sys_dark 是它自己的真值。
   两处都别省：
   ① MD3E 的暗色盘挂在 [data-theme=dark] 上（tokens.min.css 里唯一的一块），只设
      color-scheme 翻的是表单控件与滚动条，界面自己画的 99% 是 custom properties，
      一个都不动 —— 上机当天就是这样的：env 报 sys_dark=1，界面全亮。
   ② boot 里 applyTheme() 跑在 env 回来之前，S.env.sys_dark 那时还是 undefined；
      env 落地后必须再涂一遍（boot 与 reloadAll 各一次），否则永远停在首次判断。 */
function applyTheme() {
  const want = S.theme === 'auto'
    ? (S.env.sys_dark === '1' || (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches))
    : S.theme === 'dark';
  document.documentElement.setAttribute('data-theme', want ? 'dark' : 'light');
  document.documentElement.style.setProperty('color-scheme', want ? 'dark' : 'light');
  /* 动态配色跟在深浅后面：角色明度要从**当前档**的内置令牌里读，
     切档后必须重算（theme.js 里按档缓存，落 overrides 前先抄走库的值）。 */
  applyAccent(S.env);
}
onApplyTheme(applyTheme);

/* 状态栏兜底：管理器注入的 insets 在本机可能报 0（它算的是"安全绘制区"），
   而 22px 的标题行会正好钻进状态栏底下 —— "头被砍一半"。命令层从 dumpsys
   量出真实高度并换算成 dp，这里落成 CSS 值，与注入值取大（见 app.css 的
   --inset-top）。 */
function applyInsets() {
  const dp = parseFloat(S.env.sys_statusbar_dp);
  const st = document.documentElement.style;
  if (dp > 0) st.setProperty('--statusbar-fallback', dp + 'px');
  else st.removeProperty('--statusbar-fallback');
}

/* 自动刷新：只在日志页开着时才该有这一个定时器；离开页面必须收掉，
   否则它会一直在后台 fork 命令。 */
onAuto(function (on) {
  if (S.autoTimer) { clearInterval(S.autoTimer); S.autoTimer = null; }
  if (!on) return;
  S.autoTimer = setInterval(function () {
    if (S.tab !== 'log') { clearInterval(S.autoTimer); S.autoTimer = null; return; }
    ensure('log').then(draw);
  }, 5000);
});

/* ── snackbar ──────────────────────────────────────────────────────── */
let snack = document.getElementById('snack');
if (!snack) {
  snack = h('md-snackbar');
  snack.id = 'snack';
  document.body.appendChild(snack);
}
onToast(function (text, bad) {
  try {
    snack.show({ message: (bad ? '✕ ' : '') + text, timeout: bad ? 5200 : 2600 });
  } catch (e) { /* 组件没提供该方法时退回 DOM，不让提示把主流程带崩 */
    snack.textContent = text;
    snack.setAttribute('open', '');
    setTimeout(function () { snack.removeAttribute('open'); }, 2600);
  }
});

/* ── 路由 ──────────────────────────────────────────────────────────── */
/* 顶栏返回箭头：只在二级页出现。组件把 leading 槽里的按钮画在标题左边，
   系统返回键走 popstate —— 两条路都回菜单。 */
const backBtn = h('md-icon-button');
backBtn.setAttribute('slot', 'leading');
backBtn.setAttribute('icon', ICON.back);
backBtn.setAttribute('label', '返回功能菜单');
backBtn.addEventListener('click', function () { history.back(); });

function headline() {
  const p = PAGES.filter(function (x) { return x.id === S.tab; })[0] || PAGES[0];
  /* 二级页标题用二级名：顶栏与底栏各说各话才叫迷路 */
  bar.setAttribute('headline', S.sub ? FUNC_PAGES[S.sub] : p.label);
}
function syncBackBtn() {
  const on = !!S.sub;
  if (on && !backBtn.parentNode) bar.appendChild(backBtn);
  if (!on && backBtn.parentNode) backBtn.parentNode.removeChild(backBtn);
}
function show(name) {
  const p = PAGES.some(function (x) { return x.id === name; }) ? name : 'home';
  /* S.tab 存**校正过**的那一格：存原始 hash 的话，draw() 里的表查不到会悄悄画主页，
     而顶栏标题、取数、#hash 说的是另一格 —— 四格各说各话。 */
  S.tab = p;
  S.sub = '';
  headline();
  syncBackBtn();
  nav.selected = String(PAGES.findIndex(function (x) { return x.id === p; }));
  try { history.replaceState(null, '', '#/' + p); } catch (e) { location.hash = '#/' + p; }
  draw();
  load(p);
}
/* 二级页入口（功能菜单的行点进来）：压一层历史，系统返回键回菜单。
   数据按需取 —— 菜单页不问 lists/props，进二级才问。 */
function openSub(sub) {
  if (!FUNC_PAGES[sub]) return;
  S.tab = 'func';
  S.sub = sub;
  headline();
  syncBackBtn();
  try { history.pushState(null, '', '#/func/' + sub); } catch (e) { location.hash = '#/func/' + sub; }
  draw();
  loadSub(sub);
}
/* 系统返回键 / 顶栏返回箭头都会走到这：按当前 hash 校正二级状态，
   不对 hash 编故事 —— hash 不在表里就当菜单。
   （正则与 || 拆两行：check-artifact 的空分支扫描按"整行"粗筛，
     写一行会被当成 `(?:|x)` 那类空分支误伤。） */
window.addEventListener('popstate', function () {
  if (S.tab !== 'func') return;
  const raw = (location.hash || '').replace(/^#\//, '');
  const m = /^func\/([a-z]+)$/.exec(raw);
  S.sub = m && FUNC_PAGES[m[1]] ? m[1] : '';
  headline();
  syncBackBtn();
  draw();
  loadSub(S.sub);
});
onOpenSub(openSub);
function draw() {
  view.textContent = '';
  let body = {
    home: renderHome,
    func: renderFunc,
    log: renderLog,
    settings: renderSettings,
  }[S.tab] || renderHome;
  if (S.tab === 'func' && S.sub) body = function () { return renderFuncSub(S.sub); };
  view.appendChild(body());
}
function pageOf(id) { return PAGES.filter(function (p) { return p.id === id; })[0] || PAGES[0]; }
function load(name) {
  const need = pageOf(name).need.slice();
  return Promise.all(need.map(ensure)).then(draw, function () { draw(); });
}
/* 二级页取数：名单要 lists+excluded+各家的能力面命令；伪装要 props。 */
function loadSub(sub) {
  const need = [];
  if (sub === 'targets') need.push('lists', 'excluded');
  if (sub === 'props') need.push('props');
  if (sub === 'config' || sub === 'keybox') {
    const b = S.backendInfo.backend;
    need.push(b === 'teesim' ? 'teesim' : b === 'tricky' ? 'tricky' : 'omk');
  }
  if (!need.length) return Promise.resolve();
  return Promise.all(need.map(ensure)).then(draw, function () { draw(); });
}
function reloadAll() {
  S.loaded = {};
  return loadBase().then(function () { return checkContract(); }).then(function () {
    applyTheme();
    applyInsets();
    return load(S.tab);
  });
}
onReload(reloadAll);
/* screens.js 里切视图/改搜索词/换 profile 与主题之后要立刻重排。以前那几处直接写
   `draw()` —— 一个没 import 的自由变量，产物能跑只是 esbuild 把三个模块摊进了同一个
   IIFE 作用域；换打包器或哪天撞名就是当场 ReferenceError，而台架只驱动切页、点不到
   那几颗按钮。注册回调与 onToast/onReload 同一套路，守这一类的是
   tools/module-scope-check.mjs。 */
onDraw(draw);

/* 库的事件是 change + detail.index（不是 selected-change —— 上一版骨架按后者接，
   点了不会切页而台架没抓到，因为台架只数了 items.length）。 */
nav.addEventListener('change', function (e) {
  const i = (e && e.detail && typeof e.detail.index === 'number') ? e.detail.index : Number(nav.selected);
  if (!isNaN(i) && PAGES[i]) show(PAGES[i].id);
});

/* ── 启动 ──────────────────────────────────────────────────────────── */
function boot() {
  applyTheme();
  const hit = findBridge();
  attachBridge(hit);
  /* 深链支持 #/func/<二级>：直接落到那个功能的二级页（再按一次返回回菜单） */
  const rawStart = (location.hash || '').replace(/^#\//, '');
  const m = /^([a-z]+)(?:\/([a-z]+))?$/.exec(rawStart) || [];
  const start = PAGES.some(function (p) { return p.id === m[1]; }) ? m[1] : 'home';
  const startSub = start === 'func' && m[2] && FUNC_PAGES[m[2]] ? m[2] : '';
  view.appendChild(h('md-loading-indicator'));
  /* 首屏只走一条路：契约 → 基础状态 → show()。show() 自己会按目标页取数，
     这里再 load 一次就是同一批命令问两遍（本机每条 fork 20~90ms）。 */
  Promise.resolve(checkContract()).then(loadBase).then(function () {
    applyTheme();   /* env.sys_dark 这时才到 —— boot 里第一次涂色时它还是 undefined */
    applyInsets();  /* 状态栏高度也是 env 带回来的 */
    show(start);
    if (startSub) openSub(startSub);
  }, function () {
    show('home');
    onToast('基础状态读取失败，界面显示的是空值', true);
  });
}
boot();
export { reloadAll, show, draw, S, DEMO };
