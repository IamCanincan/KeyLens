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
import '@materialwebunofficial/md3e-web/components/md-loading-indicator.js';
import '@materialwebunofficial/md3e-web/components/md-snackbar.js';

import {
  S, DEMO, findBridge, attachBridge, checkContract, ensure, loadBase, hasCmd,
} from './bridge.js';
import {
  ICON, h, renderOver, renderBackend, renderLog, renderAbout, recentCard,
  onToast, onReload,
} from './screens.js';

const PAGES = [
  { id: 'over', label: '主页', icon: ICON.over },
  { id: 'func', label: '功能', icon: ICON.func },
  { id: 'log', label: '日志', icon: ICON.log },
  { id: 'about', label: '关于', icon: ICON.about },
];

const bar = document.getElementById('bar');
const view = document.getElementById('view');
const nav = document.getElementById('nav');
nav.items = PAGES.map(function (p) { return { icon: p.icon, label: p.label }; });

/* 深/浅：库的 tokens 按 color-scheme 出两套角色色 */
function applyTheme() {
  const want = S.theme === 'auto'
    ? (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches)
    : S.theme === 'dark';
  document.documentElement.style.setProperty('color-scheme', want ? 'dark' : 'light');
}

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
  S.tab = name;
  const p = PAGES.some(function (x) { return x.id === name; }) ? name : 'over';
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
    over: renderOver, func: renderBackend, log: renderLog, about: renderAbout,
  }[S.tab] || renderOver;
  view.appendChild(body());
}
function load(name) {
  const need = { over: ['base', 'lists', 'log'], func: [S.backendInfo.backend === 'teesim' ? 'teesim' : (S.backendInfo.backend === 'tricky' ? 'tricky' : 'backend')], log: ['log'], about: ['base'] }[name] || [];
  return Promise.all(need.map(ensure)).then(draw, function () { draw(); });
}
function reloadAll() {
  S.loaded = {};
  return loadBase().then(function () { return checkContract(); }).then(function () {
    return Promise.all([ensure('lists'), ensure('log'), ensure(backendNeed())]);
  }).then(draw, draw);
}
function backendNeed() {
  const b = S.backendInfo.backend;
  return b === 'teesim' ? 'teesim' : b === 'tricky' ? 'tricky' : b === 'omk' ? 'omk' : 'backend';
}
onReload(reloadAll);

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
  Promise.resolve(checkContract()).then(loadBase).then(function () {
    return Promise.all([ensure('lists'), ensure('log'), ensure(backendNeed())]);
  }).then(function () {
    show(PAGES.some(function (p) { return p.id === start; }) ? start : 'over');
  }, function () {
    show('over');
    onToast('基础状态读取失败，界面显示的是空值', true);
  });
}
boot();
export { reloadAll, show, draw, S, DEMO };
