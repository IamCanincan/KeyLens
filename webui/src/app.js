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
import '@materialwebunofficial/md3e-web/components/md-switch.js';
import '@materialwebunofficial/md3e-web/components/md-text-field.js';
import '@materialwebunofficial/md3e-web/components/md-select.js';
import '@materialwebunofficial/md3e-web/components/md-loading-indicator.js';
import '@materialwebunofficial/md3e-web/components/md-snackbar.js';

import {
  S, DEMO, findBridge, attachBridge, checkContract, ensure, loadBase, hasCmd,
} from './bridge.js';
import {
  ICON, h, renderOver, renderTargets, renderBackend, renderProps, renderLog,
  onToast, onReload, onAuto, onApplyTheme,
} from './screens.js';

/* 五格，按"用户来这儿要办的事"分，不按上一版的"功能二级菜单"分：
   名单是最高频、后端配置是三家里差异最大的、属性伪装与后端无关所以独立一格。
   界面自检收进"状态"页底部 —— 它不是一个目的地，是一屏说明。 */
const PAGES = [
  { id: 'over', label: '状态', icon: ICON.over, need: ['base', 'lists', 'log'] },
  { id: 'targets', label: '名单', icon: ICON.list, need: ['lists', 'backend', 'excluded'] },
  { id: 'backend', label: '后端', icon: ICON.backend, need: ['backend'] },
  { id: 'props', label: '伪装', icon: ICON.tune, need: ['props'] },
  { id: 'log', label: '日志', icon: ICON.log, need: ['log'] },
];

const bar = document.getElementById('bar');
const view = document.getElementById('view');
const nav = document.getElementById('nav');
nav.items = PAGES.map(function (p) { return { icon: p.icon, label: p.label }; });

/* 深/浅：跟随系统时优先用管理器报的 sys_dark —— CSS 的 prefers-color-scheme
   在部分 WebView 里不跟着系统的"深色模式"开关走，而 env.sys_dark 是它自己的真值。 */
function applyTheme() {
  const want = S.theme === 'auto'
    ? (S.env.sys_dark === '1' || (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches))
    : S.theme === 'dark';
  document.documentElement.style.setProperty('color-scheme', want ? 'dark' : 'light');
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
    over: renderOver, targets: renderTargets, backend: renderBackend,
    props: renderProps, log: renderLog,
  }[S.tab] || renderOver;
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
    return load(S.tab);
  });
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
  /* 首屏只走一条路：契约 → 基础状态 → show()。show() 自己会按目标页取数，
     这里再 load 一次就是同一批命令问两遍（本机每条 fork 20~90ms）。 */
  Promise.resolve(checkContract()).then(loadBase).then(function () {
    show(PAGES.some(function (p) { return p.id === start; }) ? start : 'over');
  }, function () {
    show('over');
    onToast('基础状态读取失败，界面显示的是空值', true);
  });
}
boot();
export { reloadAll, show, draw, S, DEMO };
