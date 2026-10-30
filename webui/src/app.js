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
  ICON, h, renderHome, renderBackend, renderLog, renderSettings,
  onToast, onReload, onAuto, onApplyTheme, onDraw,
} from './screens.js';

/* 四格，2026-10-30 定：主页 / 后端 / 日志 / 设置。
   分工按"这一格回答的是什么问题"：
     主页 —— 在不在跑、哪一家在跑、附加的自动同步上次做了什么（状态条 + 三家矩阵 + 自动同步卡）；
     后端 —— 当前这一家的配置文件怎么改（名单 + 配置面 + keybox）；
     日志 —— 出了什么事；
     设置 —— 与后端无关的模块自身开关（属性伪装 / Verified Boot 哈希）+ 外观 + 界面自检。
   上一版把面板本体放在落地页、把伪装单列一格，打开先是一屏配置表；现在落地页
   只回答"状态"，配置按家收进【后端】，伪装并进【设置】—— 一格只放一个开关太薄。
   自动同步仍旧不占位格：它是附加功能，不是目的地。 */
const PAGES = [
  { id: 'home', label: '主页', icon: ICON.home, need: ['base', 'backend'] },
  { id: 'backend', label: '后端', icon: ICON.backend, need: ['base', 'backend', 'lists', 'excluded'] },
  { id: 'log', label: '日志', icon: ICON.log, need: ['log'] },
  { id: 'settings', label: '设置', icon: ICON.settings, need: ['props'] },
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
function show(name) {
  const p = PAGES.some(function (x) { return x.id === name; }) ? name : 'home';
  /* S.tab 存**校正过**的那一格：存原始 hash 的话，draw() 里的表查不到会悄悄画主页，
     而顶栏标题、取数、#hash 说的是另一格 —— 四格各说各话。 */
  S.tab = p;
  /* 顶栏标题走 headline 属性 —— `bar.title = x` 设的是原生 tooltip，界面上
     什么都不画（上一版就是这么错的，而台架读 .title 读得到值，跟着一起被骗）。 */
  const label = (PAGES.filter(function (x) { return x.id === p; })[0] || PAGES[0]).label;
  bar.setAttribute('headline', label);
  nav.selected = String(PAGES.findIndex(function (x) { return x.id === p; }));
  try { history.replaceState(null, '', '#/' + p); } catch (e) { location.hash = '#/' + p; }
  draw();
  load(p);
}
function draw() {
  view.textContent = '';
  const body = {
    home: renderHome,
    backend: renderBackend,
    log: renderLog,
    settings: renderSettings,
  }[S.tab] || renderHome;
  view.appendChild(body());
}
function pageOf(id) { return PAGES.filter(function (p) { return p.id === id; })[0] || PAGES[0]; }
function load(name) {
  let need = pageOf(name).need.slice();
  if (name === 'backend') {
    const b = S.backendInfo.backend;
    need = need.concat([b === 'teesim' ? 'teesim' : b === 'tricky' ? 'tricky' : 'omk']);
  }
  return Promise.all(need.map(ensure)).then(draw, function () { draw(); });
}
function reloadAll() {
  S.loaded = {};
  return loadBase().then(function () { return checkContract(); }).then(function () {
    applyTheme();
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
  const start = (location.hash || '').replace(/^#\//, '');
  view.appendChild(h('md-loading-indicator'));
  /* 首屏只走一条路：契约 → 基础状态 → show()。show() 自己会按目标页取数，
     这里再 load 一次就是同一批命令问两遍（本机每条 fork 20~90ms）。 */
  Promise.resolve(checkContract()).then(loadBase).then(function () {
    applyTheme();   /* env.sys_dark 这时才到 —— boot 里第一次涂色时它还是 undefined */
    show(PAGES.some(function (p) { return p.id === start; }) ? start : 'home');
  }, function () {
    show('home');
    onToast('基础状态读取失败，界面显示的是空值', true);
  });
}
boot();
export { reloadAll, show, draw, S, DEMO };
