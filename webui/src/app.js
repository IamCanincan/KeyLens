/*=============================================================================
 * webui/src/app.js — 界面入口（构建时与 MD3E 组件一起打成一个 IIFE）
 *
 * 组件必须在这里 import：注册是副作用，少一行就会有一个标签静默降级成
 * 未知元素（什么都不画）。所以这份 import 清单同时是"用了哪些组件"的答案。
 *===========================================================================*/
import '@materialwebunofficial/md3e-web/components/md-top-app-bar.js';
import '@materialwebunofficial/md3e-web/components/md-navigation-bar.js';
import '@materialwebunofficial/md3e-web/components/md-card.js';
import '@materialwebunofficial/md3e-web/components/md-list.js';
import '@materialwebunofficial/md3e-web/components/md-button.js';
import '@materialwebunofficial/md3e-web/components/md-icon-button.js';
import '@materialwebunofficial/md3e-web/components/md-switch.js';
import '@materialwebunofficial/md3e-web/components/md-divider.js';
import '@materialwebunofficial/md3e-web/components/md-chip.js';
import '@materialwebunofficial/md3e-web/components/md-loading-indicator.js';

/* 深/浅：库的 tokens 已经按 color-scheme 出了两套角色色，这里只把系统偏好接上 */
const dark = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
document.documentElement.classList.toggle('md3e-dark', !!dark);

const NAV = [
  { icon: 'home', label: '主页' },
  { icon: 'category', label: '功能' },
  { icon: 'article', label: '日志' },
  { icon: 'info', label: '关于' },
];

const view = document.getElementById('view');
const nav = document.getElementById('nav');
const bar = document.getElementById('bar');
nav.items = NAV;
nav.addEventListener('selected-change', () => render(Number(nav.selected || 0)));

function h(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text != null) e.textContent = text;
  return e;
}

/* 骨架屏先占位：首屏在等命令回来的那 200~400ms 里不该是白板 */
function skeleton() {
  const card = h('md-card', null);
  card.append(h('div', 'sk w70'), h('div', 'sk w90'), h('div', 'sk h40'));
  return card;
}

function render(i) {
  const page = NAV[i] || NAV[0];
  bar.title = page.label;
  view.textContent = '';
  view.appendChild(skeleton());
  load().then(status => { view.textContent = ''; view.appendChild(home(status)); });
}

/* ---------- 数据 ---------- */
let cache = null;
function load() {
  if (cache) return Promise.resolve(cache);
  const q = new URLSearchParams(location.search);
  if (q.get('demo') === '1') {
    cache = { version: '—', state: 'demo', apps: 0, backend: '—' };
    return Promise.resolve(cache);
  }
  return Promise.resolve({ version: '—', state: 'unknown', apps: 0, backend: '—' });
}

function home(st) {
  const card = h('md-card');
  const list = h('md-list');
  const first = h('md-list-item');
  first.setAttribute('icon', 'https');
  first.setAttribute('headline', '后端');
  first.setAttribute('supporting-text', st.backend);
  const second = h('md-list-item');
  second.setAttribute('icon', 'group');
  second.setAttribute('headline', '生效应用');
  second.setAttribute('trailing-text', String(st.apps));
  second.setAttribute('interactive', '');
  list.append(first, second);
  card.appendChild(list);
  const btn = h('md-button');
  btn.setAttribute('variant', 'filled');
  btn.setAttribute('icon', 'refresh');
  btn.label = '立即同步';
  card.appendChild(btn);
  return card;
}

render(0);
