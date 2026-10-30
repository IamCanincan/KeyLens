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
import {
  ICON, h, renderBackend, renderProps, renderLog,
  onToast, onReload, onAuto, onApplyTheme,
} from './screens.js';

/* 五格，按"用户来这儿要办的事"分，不按上一版的"功能二级菜单"分：
   名单是最高频、后端配置是三家里差异最大的、属性伪装与后端无关所以独立一格。
   界面自检收进"状态"页底部 —— 它不是一个目的地，是一屏说明。 */
/* 四格，主体是后端控制面板：本模块首先是一个后端面板，名单本来就是三家各自的
   配置文件之一（target.txt / apps[] / scoop），控制它属于面板职责；
   "自动更新应用列表"是我们附加的功能，所以排在面板之后，不占落地页。
   上一版把生效数当英雄数字、把"立即同步"当主按钮、把名单提成独立目的地，
   等于把附加功能放在了主体前面。 */
const PAGES = [
  { id: 'backend', label: '后端', icon: ICON.backend, need: ['base', 'backend', 'lists', 'excluded'] },
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
  const p = PAGES.some(function (x) { return x.id === name; }) ? name : 'backend';
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
    backend: renderBackend,
    props: renderProps, log: renderLog,
  }[S.tab] || renderBackend;
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
    show(PAGES.some(function (p) { return p.id === start; }) ? start : 'backend');
  }, function () {
    show('backend');
    onToast('基础状态读取失败，界面显示的是空值', true);
  });
}
boot();
export { reloadAll, show, draw, S, DEMO };
