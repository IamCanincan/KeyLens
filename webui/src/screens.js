/*=============================================================================
 * webui/src/screens.js — 各屏的渲染
 *
 * 结构按三家后端**文档里的能力面**排，不按上一版的菜单形状排：
 *  - TEESim 的 profiles 是一张名字→配置表（上一版只写 default）；
 *  - Tricky 有 tee_status（为什么只能走 leaf hack）与按包 [包名] 补丁块；
 *  - OMK 的字段分"热生效 / 要重启 keymint / 要重启手机"三档，界面上必须标出来。
 *===========================================================================*/
import { S, EXPECT_API, hasCmd, b64, bytesLabel, timeLabel, call, parseKV, failText, loadIcons, loadDoctor,
  daemonLabel, daemonDown, propsMaskLabel } from './bridge.js';
import { loadOverrides } from './bridge.js';
import { accentNote } from './theme.js';
/* Opticon 同模板的 KL 标识：淡粉底 #FCE4EC + 墨色字 #031019，构建时内联为 data URL */
import logoUrl from './logo.png';

/* 图标名一律取自库自带的子集（见 tools/md3e-build/vendor/icons.txt）。
   越界的名字会被组件当**字面词**画出来，icon-gate 在构建时就会拒绝。 */
export const ICON = {
  home: 'home', func: 'category', log: 'article', settings: 'settings',
  back: 'arrow_back', next: 'chevron_right',
  about: 'info',
  sync: 'refresh', read: 'download', list: 'group',
  keybox: 'https', patch: 'label', tee: 'verified', restart: 'tune', save: 'save',
  addPkg: 'add', del: 'delete', moon: 'dark_mode', edit: 'edit', tune: 'tune',
  ok: 'check', warn: 'warning', bad: 'error', none: 'help',
};

export function h(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text != null) e.textContent = String(text);
  return e;
}
export function card(cls) { const c = h('md-card', 'card ' + (cls || '')); return c; }

export function section(title) {
  const wrap = h('section', 'sec');
  const head = h('div', 'sec-h');
  head.appendChild(h('b', null, title));
  wrap.appendChild(head);
  return wrap;
}

export function item(o) {
  const it = h('md-list-item');
  if (o.icon) it.setAttribute('icon', o.icon);
  it.setAttribute('headline', o.headline);
  if (o.supporting != null) it.setAttribute('supporting-text', String(o.supporting));
  if (o.trailing != null) it.setAttribute('trailing-text', String(o.trailing));
  if (o.tone) it.setAttribute('data-tone', o.tone);
  if (o.mono) it.setAttribute('data-mono', '');
  if (o.interactive) it.setAttribute('interactive', '');
  /* 行标题 16px/500：照 NoMount 的行（比系统设置的 19px 安静一档）。
     组件的 headline 字号写死在 shadow 里，四个 typescale 变量都撬不动
     （var-probe 逐个试过），只能注入构造样式表 —— item() 是所有行的唯一出口。 */
  try { it.shadowRoot.adoptedStyleSheets = it.shadowRoot.adoptedStyleSheets.concat([rowSkin()]); } catch (e) {}
  return it;
}
let skinSheet = null;
function rowSkin() {
  if (!skinSheet) {
    skinSheet = new CSSStyleSheet();
    /* 三件事（都只能从 shadow 里改，外层够不到）：
       ① 行标题 16px/500 —— 组件写死 16px/400，typescale 变量逐个试过都撬不动；
       ② 行底色 surface-container、圆角继承宿主 —— 参考图的行是一块面，
          分组圆角（首/末行大角）由外层按 :first-child/:last-child 设给宿主；
       ③ 图标与行尾垂直居中 —— 组件把 leading/trailing 绝对定位并对着
          **首行**排，多行行里图标就偏上（探针量到 -22px）；钉到 50% 才对得上
          "图标在中轴上"。 */
    skinSheet.replaceSync(
      '.headline{font-size:16px;font-weight:500;line-height:22px;letter-spacing:0}'
      + '.supporting-text{font-size:14px;line-height:20px}'
      /* 技术值（包名、摘要、指纹）走等宽字，和正文分开 —— 这是 KeyLens 的仪表感 */
      + ':host([data-mono]) .supporting-text{font-family:var(--kl-mono);font-size:13px;letter-spacing:0}'
      + ':host([data-tone="ok"]) .trailing{color:var(--kl-ok)!important}'
      + ':host([data-tone="warn"]) .trailing{color:var(--kl-warn)!important}'
      + ':host([data-tone="bad"]) .trailing{color:var(--kl-bad)!important}'
      + '.item{background:var(--md-sys-color-surface-container)!important;border-radius:inherit!important}'
      + '.leading-slot{top:50%!important;transform:translateY(-50%)!important}'
      /* 组件把正文块按 top:14px 定死：单行行只剩上半截字，双行也偏上。
         和图标/行尾一样在 50% 处居中，行高变化时文字仍在视觉中轴。 */
      + '.content{top:50%!important;transform:translateY(-50%)!important}'
      + '.trailing{top:50%!important;transform:translateY(-50%)!important;font:500 13px/18px system-ui,sans-serif}'
    );
  }
  return skinSheet;
}

export function list(items) {
  const l = h('md-list');
  items.forEach(function (x) { if (x) l.appendChild(x); });
  return l;
}

/* 系统设置那种"彩色圆底 + 图标"的行首（2026-10-31 用户给的对照图 + "学得不够到位"）。
   配色不用 tonal 容器色 —— 那套在深色下又暗又灰，跟参考图对不上；参考图是
   **亮圆底 + 深色图形，深浅两态同一套**（Android 设置正是这么干的），所以这里
   放固定色值。interactive 的主色（按钮/选中态）仍走动态配色。 */
/* 行首图标：单色小方块（NoMount 的语言）。以前每个入口一种粉彩色，
   五个入口并排时颜色比内容还抢眼；彩色只留给状态与操作。 */
export function avatar(iconName) {
  const s = h('span', 'ic-avatar', iconName);
  s.setAttribute('slot', 'start');
  s.setAttribute('aria-hidden', 'true');
  return s;
}

/* 属性行的状态点：比整颗彩色圆底轻 —— 17 行挨着排，圆底会吵，色点刚好。
   tone: ok / warn / bad / none */
export function dot(tone) {
  const s = h('span', 'dot dot-' + (tone || 'none'));
  s.setAttribute('slot', 'start');
  s.setAttribute('aria-hidden', 'true');
  return s;
}

export function button(label, o) {
  const b = h('md-button');
  b.setAttribute('variant', (o && o.variant) || 'text');
  if (o && o.icon) b.setAttribute('icon', o.icon);
  if (o && o.size) b.setAttribute('size', o.size);
  if (o && o.disabled) b.setAttribute('disabled', '');
  /* 标签走 label **属性**（库的用法示例就是 label="…"）；设成 DOM 属性不一定反映。 */
  b.setAttribute('label', label);
  b.textContent = label;
  if (o && o.on) b.addEventListener('click', o.on);
  return b;
}

/* 筛选芯片：四颗 md-button 在 417px 里放不下，会折成两排（截图里第四颗掉到第二行）。
   md-chip 的 filter 变体正是 MD3 里做筛选的标准控件，宽度也只到按钮的三分之二。 */
export function chip(label, selected, on) {
  const c = h('md-chip');
  c.setAttribute('variant', 'filter');
  /* 只设 label 属性：md-chip 会把属性**和**槽里的文本都画出来，两样都设就变成
     "名单 3名单 3"（md-button 不会，它只认属性 —— 两者别混着抄）。 */
  c.setAttribute('label', label);
  if (selected) c.setAttribute('selected', '');
  if (on) c.addEventListener('click', on);
  return c;
}

/* 状态 → 语气。规则沿用上一版：正常不上色（一个点就够），只有要处理的才着色。 */
export function toneOfState(st) {
  if (st === 'ok') return ['ok', '运行中'];
  if (st === 'failed') return ['bad', '写入失败'];
  if (st === 'stopped') return ['bad', '已停止'];
  if (st === 'conflict') return ['warn', '两个后端同时启用'];
  return ['none', '状态未知'];
}

/* 顶部让位到底用了哪个数 —— 自检卡照实报：生效值、管理器注入值、dumpsys 兜底。
   "头被切"这类问题没有这行就只能靠猜（哪一路给了多少 px）。 */
function insetNote() {
  const cs = getComputedStyle(document.documentElement);
  const g = k => (cs.getPropertyValue(k) || '').trim() || '—';
  /* --inset-top 是 max() 表达式，自定义属性取出来不解析；要读**用出来的**值
     就量包壳的 padding-top。 */
  const used = (getComputedStyle(document.getElementById('barwrap')).paddingTop || '').trim() || '0px';
  return '顶部让位 ' + used + '（注入 ' + g('--safe-area-inset-top')
    + ' / 兜底 ' + g('--statusbar-fallback') + '）';
}

/* 界面自检：不再是独立的一格目的地 —— 它是排障材料，跟着状态页走更顺手。
   报的是"界面自己看到了什么"：桥接扫过哪些名字、契约号与命令数、当前视口。 */
function selfCheck() {
  const c = card();
  const s = section('界面自检', ICON.about);
  s.appendChild(list([
    item({ headline: '桥接', trailing: S.bridge.kind || '未找到', tone: S.bridge.kind ? 'ok' : 'bad',
      supporting: '扫过：' + (S.bridge.seen.join(' ') || '无') }),
    item({ headline: '命令层契约', trailing: 'api ' + (S.contract.api === null ? '读不到' : S.contract.api),
      tone: S.contract.bad ? 'bad' : 'ok',
      supporting: '命令 ' + S.contract.commands.split(' ').filter(Boolean).length + ' 条 · 界面要 api=' + EXPECT_API }),
    item({ headline: '执行身份', trailing: S.env.root_user === '0' ? 'root' : 'uid ' + (S.env.root_user || '?') }),
    item({ headline: '设备与系统', supporting: (S.env.device || '?') + ' · Android ' + (S.env.android || '?') + ' (sdk ' + (S.env.sdk || '?') + ', ' + (S.env.build_type || '?') + ')' }),
    item({ headline: '主题', trailing: S.theme, supporting: '视口 ' + Math.round(document.documentElement.clientWidth) + ' CSS px · 系统深色 ' + (S.env.sys_dark === '1' ? '是' : '否') + ' · ' + insetNote() }),
  ]));
  c.appendChild(s);
  return c;
}

/* ── 名单页：语法按后端分叉，这是文档里最实在的差异 ─────────────────── */
/* Tricky 只吃包名 + ?/!；TEESim 额外认 pkg@用户 与 uid:数字；OMK 的 scoop
   只吃精确包名（明确不支持 @user / uid / 后缀）。用同一套输入框去接三家，
   就会让用户写出某一后端根本读不懂的条目。 */
export const SYNTAX = {
  tricky: { label: '包名，结尾 ? = 叶证书、! = 证书生成', users: false, uid: false, modes: true },
  teesim: { label: '包名 / 包名@用户号 / uid:数字', users: true, uid: true, modes: false },
  omk: { label: '只吃精确包名（不支持 @用户、uid、后缀）', users: false, uid: false, modes: false },
};
export const MODE_LABEL = { auto: '自动', leaf: '叶证书', generate: '证书生成' };

export function baseOf(tok) {
  var t = String(tok);
  if (/^uid:/.test(t)) return '';
  return t.replace(/[?!]$/, '').replace(/@[0-9]+$/, '');
}
export function tokenValidFor(backend, tok) {
  var s = SYNTAX[backend] || SYNTAX.omk;
  if (!tok) return '空的';
  if (/^uid:/.test(tok)) return s.uid ? '' : '这个后端不认 uid: 条目';
  if (/[?!]$/.test(tok)) return s.modes ? '' : '这个后端没有证书模式后缀';
  var m = tok.match(/^(.*)@(\d+)$/);
  if (m) return s.users ? (/^[A-Za-z_][A-Za-z0-9_.]*$/.test(m[1]) ? '' : '包名部分不合法') : '这个后端不认 @用户 写法';
  return /^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$/.test(tok) ? '' : '不是合法包名';
}

/* AUTO 不是一种模式，是"照当下 TEE 探测结果现算"（Config.kt:225-229）：
   AVAILABLE→叶证书、FAILED→证书生成、UNAVAILABLE→**不匹配**（这个包根本不会被改写）。
   只显示"自动"等于什么也没说 —— 用户要的是"那台机器上它到底走哪条"。
   探测结果读不到时不许猜：宁可不显示，也不能把 UNAVAILABLE 当成会走叶证书。
   读的是上游写下的 tee_status 文件，不是此刻重新探测 —— 所以标注"上次探测"。 */
export function resolveAuto(tee, why) {
  if (!tee) return { to: '', tone: 'warn', note: why || S.teeWhy || '读不到 tee_status，无法判定' };
  switch (tee.status) {
    case 'AVAILABLE': return { to: 'leaf', tone: 'ok', note: '上次探测：TEE 可用 → 自动走叶证书' };
    case 'FAILED': return { to: 'generate', tone: 'warn', note: '上次探测：TEE 探测失败 → 自动退到证书生成' };
    case 'UNAVAILABLE': return { to: 'none', tone: 'bad', note: '上次探测：TEE 不可用 → 自动条目不匹配，包不会被改写' };
  }
  /* 两代 Tricky 的 tee_status 格式不一样：
       - TrickyStore（原版，含 OSS v3.1.0 这一代）：**只有一行** teeBroken=true|false|unknown；
       - OSS 新主分支：四行 status/category/serviceErrorCode/teeBroken。
     只认 status 的话，旧格式会落进"不认识"——真机实测 OSS v3.1.0 就是单行，
     界面于是显示"无法判定"，而 teeBroken 明明就在文件里。这里按 teeBroken
     回退（true=探测失败→生成、false=可用→叶证书、unknown=不判定）。 */
  const tb = String(tee.tee_broken || '').toLowerCase();
  if (tb === 'false') return { to: 'leaf', tone: 'ok', note: '上次探测：teeBroken=false（旧版 tee_status 只有这一行）→ 自动走叶证书' };
  if (tb === 'true') return { to: 'generate', tone: 'warn', note: '上次探测：teeBroken=true（旧版 tee_status 只有这一行）→ 自动退到证书生成' };
  if (tb === 'unknown') return { to: '', tone: 'warn', note: '上次探测：teeBroken=unknown（旧版格式），无法判定' };
  return { to: '', tone: 'warn', note: 'tee_status.status=' + (tee.status || '空') + '，不认识的取值，无法判定' };
}

/* 返回 { el, note }：note 要写进条目的 supporting 行 —— 触屏上没有 tooltip，
   藏在 title 里等于没写。 */
function modeButton(tok, meta, tee) {
  const kind = (meta && meta.kind) || 'auto';
  const r = kind === 'auto' ? resolveAuto(tee) : { to: kind, tone: kind === 'generate' ? 'warn' : 'ok', note: '' };
  const label = kind === 'auto'
    ? '自动 → ' + (r.to === 'none' ? '不匹配' : (MODE_LABEL[r.to] || '未探测'))
    : MODE_LABEL[kind];
  /* 名单行尾的三态按钮也走轻量 <button>：129 行各带一个 md-button 时，
     光组件本身就能把进页面拖到几百毫秒（见 listSection 的实测）。 */
  const el = h('button', 'app-row-mode', label);
  el.type = 'button';
  el.setAttribute('data-tone', r.tone);
  el.addEventListener('click', function () {
    const order = ['auto', 'leaf', 'generate'];
    const next = order[(order.indexOf(kind) + 1) % 3];
    write('set-mode', baseOf(tok) + ' ' + next, '已切换为' + MODE_LABEL[next]);
  });
  return { el: el, note: r.note };
}

let askedIcons = {};
/* 取过一轮仍然没有图标的包：同一屏里不再重问（每次都是 root 命令），
   但**重新进入名单页会清空并重试一次** —— 以前 askedIcons 一置位就永远不撤，
   一次失败就让那个包在这一整轮里一直是首字块，只能重开界面。 */
let iconFailed = {};
function iconsSettled(list) {
  list.forEach(function (b) {
    if (S.icons[b]) delete iconFailed[b];
    else { iconFailed[b] = 1; delete askedIcons[b]; }
  });
}
function loadIconsFor(shown) {
  const need = [];
  shown.forEach(function (t) { const b = baseOf(t); if (b && !S.icons[b] && !askedIcons[b] && !iconFailed[b]) { need.push(b); askedIcons[b] = 1; } });
  if (!need.length) return;
  /* 图标异步到货后**原位替换**首字块，不整页重画：重画会打断滚动，
     名单一大时还会把已经建好的行全拆掉重建。 */
  const batch = need.slice(0, 120);
  loadIcons(batch).then(function () { swapIcons(); iconsSettled(batch); },
    function () { iconsSettled(batch); });
}
/* 首进名单的预取：先拿 lists 的包名，再一次性取图标/显示名，最后才画列表。
   这样第一帧就是应用名 + 图标，不会先露出包名再原位替换。
   预取范围就是**当前档**要画的那 200 条（与 listSection 的 LIMIT 对齐）；
   切档后新增的那些仍由 loadIconsFor 增量补。 */
const PREFETCH_ICONS = 200;
/* 当前档位的数据源：与 listSection 的 src 同一套规则（targets / apps / missing / excluded）。
   两处各写一份的话，预取与真正画出来的集合一旦分叉，就会出现"预取了没画"或
   "画了没预取" —— 后者正是首帧闪一下。 */
function listSource() {
  if (S.view === 'apps') return S.apps;
  if (S.view === 'excluded') return S.excluded;
  if (S.view === 'missing') {
    const baseSet = {};
    S.targets.forEach(function (t) { const b = baseOf(t); if (b) baseSet[b] = 1; });
    return S.apps.filter(function (a) { return !baseSet[a]; });
  }
  return S.targets;
}
function listBases() {
  const bases = [], seen = {};
  listSource().forEach(function (t) {
    const b = baseOf(t);
    if (!b || seen[b]) return;
    seen[b] = 1;
    bases.push(b);
  });
  return bases;
}
/* 返回 true = 这次进入还需要等：lists 还没到、Tricky 的 tee_status 还没到，
   或这一档前 200 个包的应用名/图标还没被问过。 */
export function targetsPending() {
  if (!S.loaded || !S.loaded.lists) return true;
  /* Tricky 行尾「自动 →」的判定读 tee_status：名单页也要等它，
     否则首进显示"未探测"、逛过一次后端配置再回来才正确。 */
  if (S.backendInfo.backend === 'tricky' && !S.loaded.teestatus) return true;
  const bases = listBases().slice(0, PREFETCH_ICONS);
  for (let i = 0; i < bases.length; i++) {
    /* 取过但失败的（iconFailed）不再算"还要等" —— 否则图标命令一失败，
       这一页就永远停在骨架屏上，而它本来可以带着首字块先画出来。 */
    if (!askedIcons[bases[i]] && !iconFailed[bases[i]]) return true;
  }
  return false;
}
export function prefetchListIcons() {
  /* 每次"进入/重读"都清一次失败表：这是重试的唯一入口（同一屏内不重问，
     见 loadIconsFor），否则一次网络/权限抖动就永久少几个图标。 */
  iconFailed = {};
  const need = [];
  listBases().slice(0, PREFETCH_ICONS).forEach(function (b) {
    if (askedIcons[b]) return;
    askedIcons[b] = 1;
    need.push(b);
  });
  if (!need.length) return Promise.resolve(false);
  /* true = 这次真的发起了图标读取（调用方据此决定要不要重画）；
     命令失败也返回 true —— 数据没变也要把首字块状态画定。 */
  return loadIcons(need).then(function () { iconsSettled(need); return true; },
    function () { iconsSettled(need); return true; });
}
/* 打开 WebUI 的启动页：品牌标识先出来，壳和数据在下面就位后整层淡出。
   不用裸 spinner —— 空页面突然换成主页就是用户说的"很生硬"。 */
export function bootSplash() {
  const s = h('div', 'boot-splash');
  s.setAttribute('role', 'status');
  s.setAttribute('aria-label', 'KeyLens 正在启动');
  const brand = h('div', 'boot-brand');
  const logo = h('img', 'kl-logo boot-logo');
  logo.src = logoUrl;
  logo.alt = '';
  brand.appendChild(logo);
  brand.appendChild(h('b', 'boot-name', 'KeyLens'));
  brand.appendChild(h('span', 'boot-sub', '正在读取设备状态…'));
  brand.appendChild(h('span', 'boot-spin'));
  s.appendChild(brand);
  return s;
}

/* 过渡加载页（骨架屏）：不是一小张转圈卡 —— 骨架填满首屏、和真实内容同构，
   数据到齐后整页替换，等待时看起来是"正在长出一页"而不是"卡住了"。
   名单 / 日志 / 表单各有自己的形状。 */
function skLine(width) {
  const l = h('span', 'sk-line');
  l.style.width = width;
  return l;
}
function skRow() {
  const r = h('div', 'sk-row');
  r.appendChild(h('span', 'sk-ic'));
  const lines = h('div', 'sk-lines');
  lines.appendChild(skLine('54%'));
  lines.appendChild(skLine('32%'));
  r.appendChild(lines);
  return r;
}
function skRows(n) {
  const w = h('div', 'sk-rows');
  for (let i = 0; i < n; i++) w.appendChild(skRow());
  return w;
}
function skChips() {
  const w = h('div', 'sk-chips');
  [64, 64, 72, 64].forEach(function (px) {
    const c = h('span', 'sk-chip');
    c.style.width = px + 'px';
    w.appendChild(c);
  });
  return w;
}
function skConsole() {
  const c = h('div', 'sk-console');
  [62, 44, 78, 55, 38, 70, 48, 60, 36, 52].forEach(function (pct) {
    const l = h('span', 'sk-cline');
    l.style.width = pct + '%';
    c.appendChild(l);
  });
  return c;
}
export function renderPending(text, kind) {
  const box = h('div', 'stack');
  const w = h('div', 'load-card');
  if (kind === 'home') {
    /* 与主页同构：英雄卡（标识 + 品牌行 + 三格统计）+ 三家矩阵 */
    const hero = h('div', 'sk-hero');
    const top = h('div', 'sk-hero-top');
    top.appendChild(h('span', 'sk-hero-logo'));
    const lines = h('div', 'sk-lines');
    lines.appendChild(skLine('40%'));
    lines.appendChild(skLine('62%'));
    top.appendChild(lines);
    hero.appendChild(top);
    const stats = h('div', 'sk-hero-stats');
    [['版本', '42%'], ['生效名单', '48%'], ['属性伪装', '38%']].forEach(function (s) {
      const d = h('div', 'sk-stat');
      d.appendChild(skLine(s[1]));
      d.appendChild(skLine('34%'));
      stats.appendChild(d);
    });
    hero.appendChild(stats);
    w.appendChild(hero);
    w.appendChild(skRows(3));
  } else if (kind === 'list') {
    /* 与名单页同构：两行说明 → 筛选芯片 → 搜索框 → 分组行 */
    const hints = h('div', 'sk-hints');
    hints.appendChild(skLine('72%'));
    hints.appendChild(skLine('46%'));
    w.appendChild(hints);
    w.appendChild(skChips());
    w.appendChild(h('div', 'sk-search'));
    w.appendChild(skRows(7));
  } else if (kind === 'console') {
    w.appendChild(skChips());
    w.appendChild(skConsole());
  } else {
    const hints = h('div', 'sk-hints');
    hints.appendChild(skLine('34%'));
    w.appendChild(hints);
    w.appendChild(skRows(5));
  }
  box.appendChild(w);
  box.appendChild(h('p', 'hint', text || '正在读取…'));
  return box;
}

export function swapIcons() {
  if (S.tab !== 'func' || S.sub !== 'targets') return;
  [].forEach.call(document.querySelectorAll('#view .app-row[data-base]'), function (it) {
    const b = it.getAttribute('data-base');
    const ic = S.icons[b];
    if (!ic) return;
    /* 显示名也一起补：首次进入若先画了包名，图标到货后标题要原位变成应用名，
       否则会和第二次进入（缓存命中、直接画应用名）长得不一样。 */
    const sup = (function () {
      if (!ic.label) return '';
      const tok = it.getAttribute('data-tok') || b || '';
      const note = it.getAttribute('data-note') || '';
      return [tok, note].filter(Boolean).join(' · ');
    })();
    if (ic.label) {
      const t = it.querySelector('.app-row-title');
      if (t) t.textContent = ic.label;
      it.setAttribute('headline', ic.label);
      it.setAttribute('supporting-text', sup);
      const tx = it.querySelector('.app-row-text');
      let s = it.querySelector('.app-row-sub');
      if (!s && sup && tx) { s = h('span', 'app-row-sub', sup); tx.appendChild(s); }
      else if (s) s.textContent = sup;
    }
    if (!ic.src || it.querySelector('img.app-ic')) return;
    const fb = it.querySelector('.app-ic-fallback');
    if (!fb) return;
    const img = h('img', 'app-ic'); img.src = ic.src; img.alt = '';
    img.loading = 'lazy'; img.decoding = 'async';
    img.addEventListener('error', function () { /* 贴图打不开就保持首字块 */ });
    fb.parentNode.replaceChild(img, fb);
  });
}

/* ── 设置页里的"伪装"两块：属性对照 + Verified Boot ───────────────────── */
/* 这两件事与后端无关（三家共用一份属性表），所以不跟在某一家的配置面后面；
   2026-10-30 四格重排时从独立目的地并进"设置"—— 一格只有一个开关太薄，
   而它本来就是"模块自己的开关"这一类。返回 fragment 而不是 stack：外层已经有
   stack 了，套两层 div 会让 .stack 的 flex gap 只作用在外层，卡片间距变成两级。 */
function propsCards() {
  const frag = document.createDocumentFragment();
  const diff = S.props.filter(function (p) { return p.st !== 'ok'; });

  const c1 = card();
  /* 读不到时既不能说"全部一致"也不能说"0 项不符" —— 那是把"我不知道"画成
     "没问题"。写法与名单页的 S.listErr 同一条路（.read-err 一行说明）。 */
  const s1 = section('系统属性 · ' + (S.propsErr ? '读不到' : diff.length ? diff.length + ' 项不符' : '全部一致'), ICON.tune);
  if (S.propsErr) s1.appendChild(h('p', 'read-err', '属性对照读不到：这一屏没有比对结果，"一致 / 不符"都无从判断。'));
  s1.appendChild(list([
    item({ headline: '开机重置属性', trailing: maskKnown(S.status) ? (maskOn(S.status) ? '已开启' : '已关闭') : '读不到',
      tone: maskOn(S.status) ? 'ok' : maskKnown(S.status) ? 'warn' : 'bad',
      supporting: maskKnown(S.status) ? '关闭后下次开机不再写入' : 'status 那一次没读到，这里不猜方向；下面「立即应用一次」不依赖它' }),
  ]));
  /* 动作按钮别塞进 md-list：组件会把行里的控件居中，看着像另一行数据。
     读不到时不给那颗"切换"键 —— 它得先知道现在是开还是关才知道发哪条命令，
     拿"当成关"去补一个默认值，用户点下去可能是**开启**了他没打算动的写入。 */
  const acts1 = h('div', 'acts');
  if (maskKnown(S.status)) {
    acts1.appendChild(button(maskOn(S.status) ? '关闭开机写入' : '开启开机写入',
      { variant: 'tonal', on: function () { write(maskOn(S.status) ? 'props-off' : 'props-on', '', '已切换'); } }));
  }
  acts1.appendChild(button('立即应用一次', { variant: 'filled', icon: ICON.sync, on: function () { write('props-apply', '', '已写入并复核'); } }));
  s1.appendChild(acts1);
  const l = h('md-list');
  S.props.forEach(function (p) {
    const it = item({
      headline: p.name,
      /* "当前"这行必须写在 supporting-text 里（组件是 white-space:pre-wrap，换行会
         正常显示、行高自己长）。以前是往 md-list 里 append 一个裸 div —— 它不在
         md-list 的白底表面里，于是第二行字漏到卡片外面、压在下一行上。 */
      supporting: '期望 ' + (p.want || '—') + (p.st === 'diff' ? '\n当前 ' + (p.cur || '—') : ''),
      trailing: p.st === 'ok' ? '一致' : p.st === 'missing' ? '读不到' : '不符',
      tone: p.st === 'ok' ? '' : (p.st === 'missing' ? 'warn' : 'bad'),
    });
    it.appendChild(dot(p.st === 'ok' ? 'ok' : p.st === 'missing' ? 'warn' : 'bad'));
    l.appendChild(it);
  });
  s1.appendChild(l);
  c1.appendChild(s1);
  frag.appendChild(c1);

  const bt = S.boot;
  const c2 = card();
  const s2 = section('Verified Boot 哈希', ICON.tee);
  s2.appendChild(list([
    (function () {
      const it = item({ headline: '当前 ro.boot.vbmeta.digest', supporting: (bt && bt.current) || '读不到',
        mono: !!(bt && bt.current) });
      it.appendChild(dot(bt && bt.current ? 'ok' : 'warn'));
      return it;
    })(),
    item({ headline: '模块应用值', supporting: (bt && bt.configured) || '未设置（不写 vbmeta.digest）',
      tone: bt && bt.configured ? 'ok' : 'warn', mono: !!(bt && bt.configured) }),
  ]));
  /* 这个值要能改：旧版有 props-boot-hash 这条写命令，新版不给入口就是退步。
     校验按十六进制 64 位来，与命令层一致；清空 = 不应用。 */
  const tf = h('md-text-field');
  tf.setAttribute('variant', 'filled');
  tf.setAttribute('single-line', '');
  tf.setAttribute('label', '要应用的 digest（64 位十六进制，留空 = 不应用）');
  tf.value = (bt && bt.configured) || '';
  s2.appendChild(tf);
  const acts2 = h('div', 'acts');
  acts2.appendChild(button('保存并应用', { variant: 'filled', icon: ICON.save, on: function () {
    const v = String(tf.value || '').trim();
    if (v && !/^[0-9a-fA-F]{64}$/.test(v)) { toastFn('digest 必须是 64 位十六进制（或留空取消）', true); return; }
    /* 这条命令收的是明文十六进制或 '-'，不是 base64 —— 以前从 keybox 那条抄了
       编码，真机上点保存只会得到"必须是 64 或 128 位十六进制"。契约闸门把它钉住。 */
    write('props-boot-hash', v, v ? '已写入并立即应用' : '已取消应用 vbmeta.digest');
  } }));
  s2.appendChild(acts2);
  c2.appendChild(s2);
  frag.appendChild(c2);
  return frag;
}

/* ── 三个目的地各一个 render*（ui-shape 按这段的相邻次序切函数体，别打散）── */

/* 主页：打开就看到"还在不在跑、哪一家在跑"。两张卡都是十几二十个节点，
   没有一项需要推迟挂载 —— 推迟是给名单那种上百行的列表用的，这里推迟
   只会让落地页"先空一帧再长出来"。 */
export function renderHome() {
  const box = h('div', 'stack');
  box.appendChild(statusStrip());
  box.appendChild(backendMatrix());
  return box;
}

/* ── 功能页：一张菜单 + 各功能的二级页（ui-shape 按这段的相邻次序切函数体，别打散）── */

/* 二级页注册表：id → 标题。app.js 的路由、hash、返回箭头都读它；
   长列表（名单、属性）默认只在这里留一个入口，点进去才画 —— 菜单页本身
   必须轻，落地即用。 */
export const FUNC_PAGES = {
  targets: '目标名单',
  config: '后端配置',
  sync: '自动同步',
  keybox: 'keybox',
  props: '属性伪装',
};

/* 菜单页：所有功能集中在这里，每项带一行**当下的状态摘要**（不是说明书 ——
   用户不开进二级页就该看到"现在是什么情况"）。二级页里才是长列表与表单。 */
export function renderFunc() {
  const bi = S.backendInfo, st = S.status;
  const cfgDesc = { teesim: 'Profile 表 + overrides.json', tricky: 'TEE 探测 + 补丁表', omk: 'config.toml + injector.toml' }[bi.backend] || '';
  /* 摘要里只放文件名不放全路径：/data/misc/keystore/... 会从词中间折成三行，
     全路径在二级页的第一行 hint 里本来就有。 */
  const base = p => String(p || '').split('/').filter(Boolean).pop() || '—';
  const entries = [
    ['targets', 'list', '目标名单', '当前生效 ' + (bi_entries() || '—') + ' 条 · ' + base(bi.target_file)],
    ['config', 'tune', '后端配置 · ' + (bi.backend_name || '—'), cfgDesc],
    ['sync', 'refresh', '自动同步',
      daemonLabel(st) + ' · 上次写入 ' + timeLabel(st.target_mtime)],
    ['keybox', 'https', '密钥箱 keybox', bi.keybox_exists === '1' ? '已设置 · ' + base(bi.keybox_file) : '未设置'],
    /* 对照表进过属性页才有数据；没读过时不能把未知报成 0 项。
       用行数而不是 loaded：写入后 reloadAll 会清 loaded，但已读到的对照表仍然有效。 */
    ['props', 'verified', '属性伪装', propsMaskLabel(st)
      + (st.props_masking === 'on' && S.props.length ? ' · ' + S.props.length + ' 项对照' : '')],
  ];
  /* 页标题已经在顶栏（28px），菜单不再套一层同名分组标题 —— 那会变成
     "功能 / 功能" 两行，信息重复而层级反而更浅。 */
  const box = h('div', 'stack');
  const l = h('md-list');
  entries.forEach(function (e) {
    const it = item({ headline: e[2], supporting: e[3], interactive: true });
    it.appendChild(avatar(e[1]));
    const ic = h('span', 'nav-ic', ICON.next);
    ic.setAttribute('slot', 'end');
    it.appendChild(ic);
    it.addEventListener('click', function () { openSubFn(e[0]); });
    l.appendChild(it);
  });
  box.appendChild(l);
  return box;
}

/* 二级页：按 FUNC_PAGES 的 id 画对应的功能面。长列表在这里才整批挂出来
   （listSection 自带 16 条分批）；短卡直接画。 */
export function renderFuncSub(sub) {
  const bi = S.backendInfo;
  const box = h('div', 'stack');
  if (sub === 'targets') box.appendChild(listSection());
  if (sub === 'config') {
    if (bi.backend === 'teesim') { box.appendChild(teesimProfiles()); box.appendChild(teesimOverrides()); }
    if (bi.backend === 'tricky') { box.appendChild(trickyBlocks()); }
    if (bi.backend === 'omk') { box.appendChild(omkReload()); }
  }
  if (sub === 'sync') box.appendChild(autoSyncCard());
  if (sub === 'keybox') box.appendChild(keyboxCard());
  if (sub === 'props') box.appendChild(propsCards());
  return box;
}

/* 菜单项点击 → app.js 的 openSub（pushState + 返回箭头都在壳那一层）。
   照 onToast/onReload 的套路注册，screens 不反向 import app。 */
let openSubFn = function () {};
export function onOpenSub(fn) { openSubFn = fn; }

/* 设置：界面自己的事（外观）+ 排障材料（界面自检）。
   属性伪装 / Verified Boot 是**功能**（改设备状态），2026-10-30 起在【功能】页；
   这里只留"界面偏好与自检"。 */
/* 体检卡：只读、可重跑，结果留在 S.doctor 里，切页回来还在。 */
function doctorCard() {
  const c = card();
  const s = section('体检', ICON.ok);
  s.appendChild(h('p', 'hint', '逐层查"为什么没生效"：只读，不改任何文件。每行末尾是下一步。'));
  const acts = h('div', 'acts');
  acts.appendChild(button(S.doctor ? '重新体检' : '运行体检', { variant: 'filled', icon: ICON.ok, on: run }));
  s.appendChild(acts);
  const box = h('div');
  s.appendChild(box);
  const LABEL = { ok: '正常', warn: '注意', bad: '有问题', skip: '跳过' };
  function run() {
    box.textContent = '';
    box.appendChild(h('p', 'hint', '正在体检…（约 1 秒）'));
    loadDoctor().then(paint);
  }
  function paint() {
    box.textContent = '';
    if (S.doctorErr) { box.appendChild(h('p', 'read-err', '体检命令读失败 —— 命令层可能不是这一版。')); return; }
    if (!S.doctor) { box.appendChild(h('p', 'hint', '点上面的按钮开始。')); return; }
    const kv = S.doctor.kv || {};
    box.appendChild(h('p', 'hint', '共 ' + (kv.checks || '?') + ' 项 · 有问题 ' + (kv.bad || '0')
      + ' · 注意 ' + (kv.warn || '0') + ' · 跳过 ' + (kv.skip || '0')));
    const l = h('md-list');
    S.doctor.rows.forEach(function (r) {
      const st = r[1];
      /* skip 不染色：它既不是成功也不是问题，涂绿会让人以为"这项也查过了" */
      const tone = st === 'bad' ? 'bad' : st === 'warn' ? 'warn' : st === 'ok' ? 'ok' : '';
      l.appendChild(item({ headline: r[0], trailing: LABEL[st] || st, tone: tone || undefined,
        supporting: (r[2] || '') + (r[3] ? ' · 下一步：' + r[3] : '') }));
    });
    box.appendChild(l);
  }
  if (S.doctor || S.doctorErr) paint(); else box.appendChild(h('p', 'hint', '点上面的按钮开始。'));
  c.appendChild(s);
  return c;
}
export function renderSettings() {
  const box = h('div', 'stack');
  box.appendChild(renderTheme());
  /* 自检卡不再推迟一帧：它只有五行本地数据，同帧画完页面高度就是最终值；
     推迟挂会让页面进场后再长高约 400px（实测 243 → 641），看起来同样是"拉高"。 */
  box.appendChild(selfCheck());
  box.appendChild(doctorCard());
  return box;
}

/* 三家互斥矩阵：抢的是同一个 keymint HAL，同时启用时本模块直接停止写入。
   状态报三态（active/disabled/absent）而不是"开/关"，因为下一步动作不一样：
   没装是去装，被禁是把 disable 删掉。以前命令层只报 teesim/tricky 两家、
   而 backends_conflict() 把 OMK 也数进去了 —— 于是横幅能亮却说不清是哪几家。 */
const BACKENDS = [
  ['tricky', 'Tricky Store', 'tricky_state', 'target.txt + keybox.xml', 'label'],
  ['teesim', 'TEE Simulator', 'teesim_state', '多 profile · config.json', 'verified'],
  ['omk', 'OhMyKeymint', 'omk_state', 'injector.toml + config.toml', 'extension'],
];
const BSTATE = { active: ['ok', '启用'], disabled: ['warn', '已禁用（模块目录里有 disable）'], absent: ['none', '未安装'] };
function backendMatrix() {
  const st = S.status;
  /* 键名先按字面量读一遍：kv-shape-check.mjs 只看得见 `st.xxx` 这种写法，
     `st[b[2]]` 这种算出来的下标是它的盲区 —— 与其让这三条读取脱离闸门，
     不如在这里落三个字面量，再把值发给表。 */
  const sv = { tricky: st.tricky_state, teesim: st.teesim_state, omk: st.omk_state };
  const on = BACKENDS.filter(function (b) { return sv[b[0]] === 'active'; });
  const c = card();
  const s = section('三家后端');
  s.appendChild(list(BACKENDS.map(function (b) {
    const cur = st.backend === b[0];
    const rep = BSTATE[sv[b[0]]] || ['none', '读不到状态'];
    const it = item({
      headline: b[1],
      supporting: cur ? '当前生效的就是这一家 · ' + b[3] : b[3],
      trailing: (cur ? '● ' : '') + (sv[b[0]] ? rep[1] : '读不到'),
      tone: cur ? 'ok' : rep[0],
    });
    it.appendChild(avatar(b[4]));
    return it;
  })));
  if (st.conflict === '1') {
    s.appendChild(h('p', 'read-err', '同时启用 ' + (on.length || '?') + ' 家（'
      + (on.length ? on.map(function (b) { return b[1]; }).join('、') : '具体哪几家读不到')
      + '）—— 它们抢同一个 keymint HAL，模块已经停在这里。把多余的禁用或卸载，只留一家。'));
  } else {
    s.appendChild(h('p', 'hint', '只想换一家：先在 Manager 里把现在这家禁用（或卸载），再启用目标那家，然后回到本页重新读取。'));
  }
  c.appendChild(s);
  return c;
}

/* 状态条：一行讲清"还在不在跑、写的哪一版"，不再占一整屏 */
/* 状态条：主页的英雄卡。以前是四段小字用 · 连起来 —— 信息都在，
   但"在不在跑、跑的是谁"要凑近看；现在芯片 + 大字后端名 + 三个小统计。 */
function statusStrip() {
  const st = S.status;
  const [tone, label] = toneOfState(st.state);
  const c = card('hero');
  const top = h('div', 'hero-top');
  /* 品牌标识直接沿用 Opticon 的图标模板：淡粉底 + 墨色 KL，只换字符。 */
  const badge = h('img', 'kl-logo');
  badge.src = logoUrl;
  badge.alt = 'KL';
  top.appendChild(badge);
  const id = h('div', 'hero-id');
  id.appendChild(h('span', 'brand-eyebrow', 'KEYLENS'));
  id.appendChild(h('b', 'hero-name', st.backend_name || '未探测到后端'));
  /* 后端自己的版本（module.prop 的 version）与 KeyLens 版本是两件事：
     换后端 / 升级后端之后，第一眼要能看出设备上现在跑的是哪一版。 */
  if (S.backendInfo && S.backendInfo.module_version) {
    id.appendChild(h('span', 'hero-ver', S.backendInfo.module_version));
  }
  top.appendChild(id);
  top.appendChild(h('span', 'chip chip-' + tone + ' hero-state', label));
  c.appendChild(top);
  const stats = h('div', 'hero-stats');
  [['版本', st.mod_version || '—'],
   ['生效名单', (bi_entries() || '—') + ' 条'],
   ['属性伪装', maskKnown(st) ? (maskOn(st) ? '开' : '关') : '?']].forEach(function (s) {
    const d = h('div', 'hero-stat');
    d.appendChild(h('span', 'hero-k', s[0]));
    d.appendChild(h('b', 'hero-v', s[1]));
    stats.appendChild(d);
  });
  c.appendChild(stats);
  /* 契约不匹配横幅：写命令已在传输层被拦，这里只负责说清楚 */
  if (S.contract.bad) {
    c.appendChild(h('p', 'warn-text', '命令层契约不匹配（界面要 api=' + EXPECT_API + '，命令层是 '
      + (S.contract.api === null ? '读不到' : S.contract.api) + '）：已停止一切写入，把模块整体重装一次。'));
  }
  return c;
}
function bi_entries() { return S.backendInfo.target_entries || ''; }

/* 名单：作为后端配置的一部分呈现（语法跟着后端走） */
function listSection() {
  const bi = S.backendInfo, syn = SYNTAX[bi.backend] || SYNTAX.omk;
  const baseSet = {};
  S.targets.forEach(function (t) { const b = baseOf(t); if (b) baseSet[b] = 1; });
  const c = card();
  /* 二级页标题已经是「目标名单」，这里不再重复同名分组标题；
     第一行直接给目标文件与写法，信息密度更自然。 */
  const s = h('div');
  /* 读不到时不许说"是空的" —— 命令层在目标文件缺失时就是 return 1，
     这条错误必须在名单卡的第一行，而不是滚到页尾的黄条里。 */
  if (S.listErr) s.appendChild(h('p', 'read-err', '名单读不到：' + S.listErr));
  /* 路径不再塞进标题：`/data/misc/keystore/omk/injector.toml` 会把标题折成三行，
     而且从词中间断开（截图里 "injector.to" / "ml"）。放说明行里整条给。 */
  s.appendChild(h('p', 'hint', '目标文件：' + (bi.target_file || '—')));
  s.appendChild(h('p', 'hint', '这个后端接受的写法：' + syn.label));
  const seg = h('div', 'acts filter-grid');
  [['targets', '名单 ' + S.targets.length], ['apps', '已装 ' + S.apps.length],
   ['missing', '未纳入 ' + S.apps.filter(function (a) { return !baseSet[a]; }).length],
   ['excluded', '已排除 ' + S.excluded.length]].forEach(function (v) {
    seg.appendChild(chip(v[1], v[0] === S.view, function () { S.view = v[0]; redraw(); }));
  });
  s.appendChild(seg);
  const tf = h('md-text-field');
  tf.setAttribute('variant', 'filled');
  tf.setAttribute('single-line', '');
  tf.setAttribute('label', '搜索包名或应用名');
  /* 保留上一次的搜索词：整页重画/重新进入后输入框和过滤结果要一致。 */
  tf.value = S.search || '';
  /* 只在输入框下面换行，不重画整页 —— 重画会把输入框连同焦点一起换掉，
     打第二个字就丢焦点；90ms 防抖只用来合并连续按键。 */
  let searchTimer = 0;
  tf.addEventListener('input', function () {
    S.search = String(tf.value || '');
    clearTimeout(searchTimer);
    searchTimer = setTimeout(function () { if (tf.isConnected) paintRows(); }, 90);
  });
  s.appendChild(tf);
  /* 名单行不用 md-list-item：129 行时，轻量 div 行构建+布局 43ms，
     md-list-item 要 881ms（4 倍 CPU 限速同机实测）—— 后者就是"点进二级页
     卡一下"的根因。轻量行一次画全，页面高度第一帧就是最终值，也不再分批撑高。 */
  const l = h('div', 'app-list');
  const empty = h('p', 'empty');
  empty.hidden = true;
  const countHint = h('p', 'hint');
  const LIMIT = 200;
  function letterBlock(text) {
    return h('span', 'app-ic-fallback', (String(text || '?').trim().charAt(0) || '?').toUpperCase());
  }
  function leading(ic, title) {
    if (ic && ic.src) {
      /* 图片必须有尺寸（CSS 里 40px）：裸 img 会按原图 256px 渲染，整行被撑开。 */
      const img = h('img', 'app-ic'); img.src = ic.src; img.alt = '';
      img.loading = 'lazy'; img.decoding = 'async';
      /* 图标文件缺失时不要留浏览器的破图符：退回"首字块"。 */
      img.addEventListener('error', function () {
        const fb = letterBlock(ic.label || title);
        if (img.parentNode) img.parentNode.replaceChild(fb, img);
      });
      return img;
    }
    return letterBlock((ic && ic.label) || title);
  }
  function rowOf(tok) {
    const b = baseOf(tok), ic = S.icons[b];
    const meta = (S.targetMeta || {})[tok];
    const isTrickyTargets = S.view === 'targets' && bi.backend === 'tricky' && syn.modes;
    const m = isTrickyTargets ? modeButton(tok, meta, S.teeStatus) : null;
    const detail = (ic && ic.label ? tok : '') || (meta && meta.detail ? (meta.kind === 'user' ? '用户 ' + meta.detail : 'UID ' + meta.detail) : '');
    const title = (ic && ic.label) || b || tok;
    const note = m ? (m.note || '') : '';
    const sup = [detail, note].filter(Boolean).join(' · ');
    const r = h('div', 'app-row');
    /* 行属性给台架读（真实文字在下面的 DOM 里）：headline / supporting-text
       与旧 md-list-item 的属性同形，第一/第二次进入的对照不用改判据。 */
    r.setAttribute('headline', title);
    r.setAttribute('supporting-text', sup);
    r.setAttribute('data-base', b || tok);
    r.setAttribute('data-tok', tok);
    r.setAttribute('data-note', note);
    r.setAttribute('data-mono', '');
    r.appendChild(leading(ic, title));
    const tx = h('div', 'app-row-text');
    tx.appendChild(h('b', 'app-row-title', title));
    if (sup) tx.appendChild(h('span', 'app-row-sub', sup));
    r.appendChild(tx);
    if (m) {
      r.appendChild(m.el);
    } else {
      /* 行尾图标按钮（照系统设置）：文本"移出/加入"夹在标题后面会把行撑乱，
         而且小屏上最想一眼看全的是应用名。标签走 aria-label，无障碍不丢。
         两个写命令用**字面量**分支调用：写成三目会让 ui-shape 的 write('…')
         扫描看不见它们（算出来的参数是那道闸的盲区）。 */
      const isTargets = S.view === 'targets';
      const act = h('button', 'app-row-act');
      act.type = 'button';
      act.setAttribute('aria-label', (isTargets ? '移出 ' : '加入 ') + (b || tok));
      act.appendChild(h('span', 'app-row-act-ic', isTargets ? 'remove' : 'add'));
      act.addEventListener('click', function () {
        if (isTargets) write('remove-apps', b || tok, '已移出：' + (b || tok));
        else write('restore-apps', b || tok, '已加入：' + (b || tok));
      });
      r.appendChild(act);
    }
    return r;
  }
  /* 搜索/切档只重画行：输入框、芯片和页面容器都留在原地。 */
  function paintRows() {
    const src = listSource();
    const q = (S.search || '').toLowerCase();
    const shown = q ? src.filter(function (t) {
      return String(t).toLowerCase().indexOf(q) >= 0 || baseOf(t).toLowerCase().indexOf(q) >= 0
        || ((S.icons[baseOf(t)] || {}).label || '').toLowerCase().indexOf(q) >= 0;
    }) : src;
    const page = shown.slice(0, LIMIT);
    l.textContent = '';
    page.forEach(function (t) { l.appendChild(rowOf(t)); });
    if (!shown.length) {
      empty.textContent = S.listErr ? '读不到，所以这一类画不出来。' : '这一类现在是空的。';
      empty.hidden = false;
    } else {
      empty.hidden = true;
    }
    const overLimit = shown.length > LIMIT ? '（只画前 ' + LIMIT + ' 条）' : '';
    countHint.textContent = '共 ' + shown.length + ' 条' + overLimit;
    loadIconsFor(page);
  }
  s.appendChild(l);
  /* 空态也放列表 **外面**：裸节点塞进列表没有白底、还会压到相邻行上。 */
  s.appendChild(empty);
  s.appendChild(countHint);
  c.appendChild(s);
  paintRows();
  return c;
}

/* TEESim 的第二块可写面：overrides.json（上一版完全没有） */
/* 本模块允许写的只有这六个（其余在上游是 REQUIRED 锁死的，写了守护进程会丢弃
   并记一条日志 —— Harvester.kt:403-405）。等级只认 0/1/2 = Software /
   TrustedEnvironment / StrongBox（Const.kt:75-77），**不是** KM1 那套
   KEYSTORE=1 / TRUSTED_ENVIRONMENT=2 / STRONGBOX=3 —— 写 3 上游直接丢。 */
const OV_LEVEL = [['', '留空 = 删掉这一项'], ['0', '0 · Software'], ['1', '1 · TrustedEnvironment'], ['2', '2 · StrongBox']];
const OV_SPEC = {
  attestationSecurityLevel: ['select', OV_LEVEL, 'attestation 侧安全等级'],
  keymasterSecurityLevel: ['select', OV_LEVEL, 'keymaster 侧安全等级'],
  attestationVersion: ['text', null, 'attestation 版本（1–100000）'],
  keymasterVersion: ['text', null, 'keymaster 版本（1–100000）'],
  verifiedBootKey: ['text', null, 'verifiedBootKey（64 位十六进制）'],
  verifiedBootHash: ['text', null, 'verifiedBootHash（64 位十六进制）'],
};
/* 上游 Resolver 只读 attestation* 那几条，keymaster* 写了不进证书（Resolver.kt 全文
   没有 keymasterSecurityLevel / keymasterVersion）—— 不写明白，用户会以为改了生效。 */
const OV_RECORD_ONLY = { keymasterSecurityLevel: 1, keymasterVersion: 1 };
function teesimOverrides() {
  const c = card();
  const s = section('overrides.json · 安全等级与版本', ICON.patch);
  s.appendChild(h('p', 'hint', '这块与 profile 是硬边界：设备标识只能在 profile 里改，安全等级/版本/启动键哈希只能在这里。'
    + 'verifiedBootKey / verifiedBootHash 只有当守护进程自己那份是合成兜底值时才可编辑。'));
  if (!S.overrides.length) {
    s.appendChild(h('p', 'empty', hasCmd('teesim-overrides')
      ? '读不到 overrides.json 与 harvested.json 的 overrides 段。'
      : '这一版命令层没有 teesim-overrides —— 重装模块后可以读出各项当前值与可否编辑。'));
    c.appendChild(s); return c;
  }
  const canWrite = hasCmd('teesim-save-overrides');
  const edit = [], locked = [];
  S.overrides.forEach(function (o) {
    if (canWrite && o.editable && OV_SPEC[o.field]) edit.push(o); else locked.push(o);
  });
  if (locked.length) {
    s.appendChild(list(locked.map(function (o) {
      /* 两种"锁"不是一回事，别说成一种：
           · 在白名单里但这一台不可改 —— 启动键/哈希的来源不是合成兜底值
           · 根本不在白名单里 —— 上游按 REQUIRED / SUPPLEMENT 决定，本模块不写 */
      const why = OV_SPEC[o.field]
        ? ' · 这一台的来源不是合成兜底值，上游判为不可改'
        : ' · 来源由守护进程决定（' + o.source + '），本模块不提供写入';
      return item({
        headline: o.field,
        supporting: '来源 ' + o.source + why,
        trailing: o.value || '（空）',
        tone: OV_SPEC[o.field] ? 'warn' : 'none',
      });
    })));
  }
  if (edit.length) {
    const spec = {};
    edit.forEach(function (o) { spec[o.field] = o.value; });
    const fields = edit.map(function (o) {
      const sp = OV_SPEC[o.field];
      return [o.field, o.field, sp[2] + (OV_RECORD_ONLY[o.field] ? '（只记录，不上线）' : ''), sp[0], null, sp[1]];
    });
    s.appendChild(form(spec, fields, 'teesim-save-overrides', null, '已写入 overrides.json'));
    s.appendChild(h('p', 'hint', '可编辑性是**数据决定**的：启动键/哈希只有当守护进程自己那份是合成兜底值时才可改，'
      + '所以这两格随来源变化，不是写死的开关。留空 = 删掉这一项（守护进程复位成默认）。'));
    s.appendChild(h('p', 'hint', 'keymaster 那两项上游 Resolver 从不读取，写进去只影响记录，不改线上证书内容。'
      + '保存后 TEESim 监听该文件自行热生效，不需要重启任何进程。'));
  } else if (canWrite) {
    s.appendChild(h('p', 'empty', '这一台目前没有任何一项处于可编辑状态 —— 上面每一格的来源都不是合成兜底值。'));
  } else {
    s.appendChild(h('p', 'hint', '这一版命令层还不能写 overrides.json（只有只读汇总）—— 重装模块后可以改。'));
  }
  c.appendChild(s);
  return c;
}

/* ── 自动更新：本模块附加的功能，不是后端自带的 ─────────────────────── */
/* 自动同步：本模块附加的功能，不是后端自带的能力。
   2026-10-30 用户定稿：它在**后端格里**、配置面之后 —— 它维护的就是这一格的
   名单文件，跟"这一家的配置面"同格才是它的语境；不占独立目的地（附加功能
   占一格 = 摆到主体前面）。这里同时吸掉了原来那张"自动纳入"卡：
   只有 TEESim 有这个概念，用一段说明带过即可。 */
function autoSyncCard() {
  const st = S.status, env = S.env;
  const c = card();
  /* 二级页标题就是「自动同步」，不再套同名分组标题。 */
  const s = h('div');
  s.appendChild(h('p', 'hint', '三家后端自己都不主动改名单：模块在开机与文件变化时把已装应用同步进'
    + '当前后端的名单文件（「目标名单」里那份）。后端自己的配置在「后端配置」里。'));
  const ino = !env.inotify_mode ? '读取中' : env.inotify_mode === 'none' ? '未找到 inotify 工具' : env.inotify_mode;
  /* 四行压成两行：这四项都是一句话的事，行数就是切页成本（实测约 1.2ms/节点）。 */
  const rows = list([
    item({ headline: '运行', trailing: daemonLabel(st) + ' · ' + ino,
      tone: daemonDown(st) || env.inotify_mode === 'none' ? 'bad' : 'ok',
      supporting: '目标文件 ' + (st.target_exists == null || st.target_exists === '' ? '读不到'
        : st.target_exists === '1' ? '存在' : '不存在')
        + (st.target_exists === '1' ? (st.target_writable === '1' ? ' · 可写' : ' · 不可写') : '')
        + ' · 上次写入 ' + timeLabel(st.target_mtime) }),
    item({ headline: '日志', trailing: bytesLabel(st.log_bytes),
      supporting: (st.log_lines || '?') + ' 行 · ' + (st.log_file || '') }),
  ]);
  rows.children[0].appendChild(avatar('refresh'));
  rows.children[1].appendChild(avatar('article'));
  s.appendChild(rows);
  const acts = h('div', 'acts');
  acts.appendChild(button('立即同步一次', { variant: 'filled', icon: ICON.sync, on: function () { write('sync', '', '已请求同步'); } }));
  acts.appendChild(button('重新读取', { variant: 'tonal', icon: ICON.read, on: function () { reload(); } }));
  s.appendChild(acts);
  s.appendChild(h('p', 'hint', '最近一次描述：' + (stripEmoji(st.description || '') || '—')));
  if (S.backendInfo.backend === 'teesim') {
    s.appendChild(h('p', 'hint', '「自动纳入新应用」在「后端配置」里逐份设置（profile 级 autoIncludeNewApps）。'));
  }
  c.appendChild(s);
  return c;
}

/* 同一个 `no` 在两家意思相反，同一个 `yyyy` 在两家一边能认一边不认 ——
   这套值不能共用一句说明（判据与出处见 webui.sh 的 valid_patch / valid_tricky_patch
   与 tests/patch-keywords.sh）。 */
const PATCH_HINT = {
  teesim: '补丁值的写法：留空 = 用采集值 · today · no = **报告 0**（标签还在，值是 0）· system_property · YYYY-MM / YYYY-MM-DD / YYYYMM / YYYYMMDD。关键字不分大小写；日期里的模板令牌必须大写，单独一个 YYYY/MM/DD 会被拒（替换完过不了上游自己的日期判据，等于静默不报）。',
  tricky: '补丁值的写法：prop（默认，跟着系统安全补丁属性）· device_default = 保留设备真值 · no = **整个组件标签不报**（与 TEESim 的「no = 报 0」不同）· YYYY-MM / YYYY-MM-DD / YYYYMM / YYYYMMDD。这一家连模板令牌都不分大小写（AndroidUtils.kt:167-171 的 replace 带 ignoreCase）。',
};

/* ── 编辑表单：字段规格集中一份，渲染与提交都读它 ───────────────────── */
/* [key, 取值来源, 标签, 类型, 分组小标题?]
   key 必须与命令层校验表逐字对上（webui.sh 的 cmd_*_save 里那个 case），
   对不上就是"未知字段"整单被拒。 */
const F_PROFILE = [
  ['mode', 'default_mode', '模式', 'seg', null, [['patch', '补丁'], ['generation', '证书生成']]],
  ['keybox', 'default_keybox', '密钥箱文件名', 'text'],
  ['patch_system', 'default_patch_system', 'system 补丁', 'text'],
  ['patch_vendor', 'default_patch_vendor', 'vendor 补丁', 'text'],
  ['patch_boot', 'default_patch_boot', 'boot 补丁', 'text'],
  ['os_version', 'default_os_version', 'OS 版本', 'text'],
  ['auto_include', 'default_auto_include', '自动纳入新应用', 'switch'],
];
const F_IDENTITY = [
  ['brand', 'default_brand', '品牌', 'text', '设备身份'],
  ['device', 'default_device', '设备', 'text'],
  ['product', 'default_product', '产品', 'text'],
  ['manufacturer', 'default_manufacturer', '制造商', 'text'],
  ['model', 'default_model', '型号', 'text'],
  ['serial', 'default_serial', '序列号', 'text'],
  ['imei', 'default_imei', 'IMEI', 'text'],
  ['meid', 'default_meid', 'MEID', 'text'],
  ['imei2', 'default_imei2', 'IMEI2', 'text'],
];
const F_TRICKY = [
  ['patch_system', 'patch_system', 'system', 'text'],
  ['patch_vendor', 'patch_vendor', 'vendor', 'text'],
  ['patch_boot', 'patch_boot', 'boot', 'text'],
  ['patch_all', 'patch_all', 'all（三项共用）', 'text'],
];
const LOG_LEVELS = [['off', 'off'], ['error', 'error'], ['warn', 'warn'], ['info', 'info'], ['debug', 'debug'], ['trace', 'trace']];
const F_OMK_CONFIG = [
  ['cfg_log_level', 'config_log_level', '日志级别', 'select', null, LOG_LEVELS],
  ['cfg_force_skip_biometric', 'cfg_force_skip_biometric', '跳过生物识别校验（不推荐）', 'switch'],
  ['cfg_retire_stale_keys', 'cfg_retire_stale_keys', '淘汰旧 keybox 绑定的密钥', 'switch'],
  ['trust_os_version', 'trust_os_version', 'OS 版本（auto 或 0–99）', 'text', '信任链 [trust]'],
  ['trust_security_patch', 'trust_security_patch', '安全补丁（auto|latest|YYYY-MM-DD）', 'text'],
  ['trust_os_patchlevel', 'trust_os_patchlevel', '系统补丁级别', 'text'],
  ['trust_vendor_patchlevel', 'trust_vendor_patchlevel', 'vendor 补丁级别', 'text'],
  ['trust_boot_patchlevel', 'trust_boot_patchlevel', 'boot 补丁级别', 'text'],
  ['trust_vb_key', 'trust_vb_key', 'vb_key（auto|random|64 hex）', 'text'],
  ['trust_vb_hash', 'trust_vb_hash', 'vb_hash（auto|random|64 hex）', 'text'],
  ['trust_verified_boot', 'trust_verified_boot', 'verified_boot_state', 'text'],
  ['trust_device_locked', 'trust_device_locked', 'device_locked', 'switch'],
  ['dev_brand', 'dev_brand', '品牌', 'text', '设备身份 [device]'],
  ['dev_device', 'dev_device', '设备', 'text'],
  ['dev_product', 'dev_product', '产品', 'text'],
  ['dev_manufacturer', 'dev_manufacturer', '制造商', 'text'],
  ['dev_model', 'dev_model', '型号', 'text'],
  ['dev_serial', 'dev_serial', '序列号', 'text'],
  ['dev_imei', 'dev_imei', 'IMEI', 'text'],
  ['dev_meid', 'dev_meid', 'MEID', 'text'],
  ['dev_imei2', 'dev_imei2', 'IMEI2', 'text'],
];
const F_OMK_INJECTOR = [
  ['inj_main_enabled', 'injector_main_enabled', '启用 injector', 'switch'],
  ['inj_log_level', 'injector_log_level', '日志级别（可写 warning）', 'select', null,
    LOG_LEVELS.concat([['warning', 'warning']])],
  ['filter_enabled', 'filter_enabled', '启用过滤器', 'switch', '过滤 [filter]'],
  ['filter_block_android', 'filter_block_android', '拦截 android 包', 'switch'],
  ['filter_allow_unknown', 'filter_allow_unknown', '允许未知包', 'switch'],
  ['filter_deny', 'filter_deny_list', '拒绝包名（逗号分隔）', 'text'],
];
/* OMK 的 10 个拦截方法：文档说它们是各自独立的路由开关，界面就一项一开关，
   不做"全选/常用"这种合并 —— 合并等于替用户猜他要拦哪几个。 */
const OMK_INTERCEPTS = ['get_security_level', 'get_key_entry', 'update_subcomponent', 'list_entries',
  'delete_key', 'grant', 'ungrant', 'get_number_of_entries', 'list_entries_batched',
  'get_supplementary_attestation_info'];

/* 通用表单渲染：值从 bi 里取，提交时只发改动过的键 */
function form(spec, fields, cmd, extra, note) {
  const wrap = h('div', 'form');
  const ctrls = [];
  fields.forEach(function (f) {
    const key = f[0], from = f[1], label = f[2], type = f[3], sub = f[4], opts = f[5];
    if (sub) wrap.appendChild(h('div', 'form-sub', sub));
    const cur = biValue(spec, from);
    const ek = cmd + '|' + key;          // 草稿按"哪条命令的哪个字段"存，见文件末尾
    if (type === 'switch') {
      const row = h('div', 'row');
      row.appendChild(h('span', 'row-t', label));
      const sw = h('md-switch');
      sw.checked = String(cur) === 'true';
      row.appendChild(sw);
      wrap.appendChild(row);
      fieldKey(sw, ek);
      ctrls.push({ key: key, get: function () { return sw.checked ? 'true' : 'false'; },
        /* init 取**服务端值**而不是回填后的显示值：草稿一旦变成基准，保存时就被
           判成"没有改动"，用户改的东西反而不进 payload。 */
        init: String(cur) === 'true' ? 'true' : 'false' });
    } else if (type === 'select' || type === 'seg') {
      const row = h('div', 'row');
      row.appendChild(h('span', 'row-t', label));
      const sel = h('md-select');
      (opts || []).forEach(function (o) { const op = h('md-option'); op.value = o[0]; op.textContent = o[1]; sel.appendChild(op); });
      sel.value = cur == null || cur === '' ? (opts && opts[0] ? opts[0][0] : '') : String(cur);
      const baseSel = String(sel.value || '');
      row.appendChild(sel);
      wrap.appendChild(row);
      fieldKey(sel, ek);
      ctrls.push({ key: key, get: function () { return String(sel.value || ''); }, init: baseSel });
    } else {
      const tf = h('md-text-field');
  tf.setAttribute('variant', 'filled');
  tf.setAttribute('single-line', '');
      tf.setAttribute('label', label);
      tf.value = cur == null ? '' : String(cur);
      const baseTxt = String(tf.value || '');
      wrap.appendChild(tf);
      fieldKey(tf, ek);
      ctrls.push({ key: key, get: function () { return String(tf.value || ''); }, init: baseTxt });
    }
  });
  const acts = h('div', 'acts');
  const btn = button('保存', { variant: 'filled', icon: ICON.save });
  btn.addEventListener('click', function () {
    const payload = [];
    if (extra) extra.forEach(function (kv) { payload.push(kv[0] + '=' + b64(kv[1])); });
    ctrls.forEach(function (c) {
      const v = c.get();
      if (v !== c.init) payload.push(c.key + '=' + b64(v));
    });
    if (!payload.length) { toastFn('没有改动'); return; }
    write(cmd, b64(payload.join('\n')), note || '已保存');
  });
  acts.appendChild(btn);
  wrap.appendChild(acts);
  return wrap;
}
function biValue(spec, from) { return spec[from]; }

/* ── 日志行（时间 · 级别图标 · 正文） ───────────────────────────────── */
const EMOJI_RE = /\p{Extended_Pictographic}(?:\uFE0F)?(?:\u200D\p{Extended_Pictographic}(?:\uFE0F)?)*\s?/gu;
export function stripEmoji(s) { return String(s == null ? '' : s).replace(EMOJI_RE, ''); }
/* 级别判据一律用 \u 转义 + new RegExp 写，源码里不出现裸 emoji：上一版在这里掉了
   一个字符，正则字面量就退化成"空分支"（两个竖线之间什么都没有），而空分支匹配
   任意字符串 —— 于是每一行日志都判成错误、整屏涂红，语法检查一声不响。
   check-artifact.mjs 会扫这一类形状。 */
var RE_BAD = new RegExp('[\\u274C\\u26D4]|失败|超时|错误');
var RE_WARN = new RegExp('\\u26A0|警告|未能|不存在|未找到');
var RE_OK = new RegExp('\\u2705|完成|就绪');
export function logLevel(line) {
  if (RE_BAD.test(line)) return 'bad';
  if (RE_WARN.test(line)) return 'warn';
  if (RE_OK.test(line)) return 'ok';
  return '';
}
export function logParts(line) {
  var s = String(line);
  var m = s.match(/^(\d\d-\d\d\s+\d\d:\d\d:\d\d)\s+/);
  var time = '';
  if (m) { time = m[1]; s = s.slice(m[0].length); }
  var bare = stripEmoji(s);
  var lv = logLevel(line);
  if (!lv && bare !== s) lv = 'none';
  return { time: time, text: bare, lvl: lv };
}
export function logRow(line) {
  const p = logParts(line);
  const d = h('div', 'log-line' + (p.lvl ? ' t-' + p.lvl : ''));
  d.appendChild(h('span', 'log-time', p.time));
  d.appendChild(h('span', 'log-lvl', p.lvl ? { bad: '✕', warn: '!', ok: '✓', none: '·' }[p.lvl] : ''));
  d.appendChild(h('span', 'log-msg', p.text));
  return d;
}

/* TEESim：profiles 是一张表 —— 先选哪一份，再编辑那一份 */
function teesimProfiles() {
  const box = h('div', 'stack');
  const c = card();
  const s = section('Profile 表', ICON.list);
  if (!S.profiles.length) {
    s.appendChild(h('p', 'empty', hasCmd('teesim-profiles') ? '读不到 profile 列表。'
      : '这一版命令层没有 teesim-profiles —— 重装模块后可以列出并编辑全部 profile。'));
    c.appendChild(s); box.appendChild(c); return box;
  }
  const cur = S.profiles.filter(function (p) { return p.name === S.profile; })[0] || S.profiles[0];
  const seg = h('div', 'acts');
  S.profiles.forEach(function (p) {
    seg.appendChild(button(p.name + (p.isDefault ? '（默认）' : '') + ' · ' + p.apps + ' 条', {
      variant: p.name === S.profile ? 'filled' : 'text',
      on: function () { S.profile = p.name; redraw(); },
    }));
  });
  s.appendChild(seg);
  /* 管理：新建（复制 default 的整份配置）+ 删除当前选中的（default 不可删）。
     删除把选择挪回 default —— 删掉的正好是选中那份时，编辑区的标题和表单
     不能指向一个已经不存在的 profile。 */
  const mg = h('div', 'acts');
  if (!cur.isDefault) {
    mg.appendChild(button('删除 · ' + cur.name, { variant: 'text', icon: ICON.del, on: function () {
      const n = cur.name; S.profile = 'default';
      write('teesim-profile-del', n, '已删除 profile：' + n);
    } }));
  }
  s.appendChild(mg);
  s.appendChild(fold(function () {
    const w = h('div', 'form');
    const tf = h('md-text-field');
    tf.setAttribute('variant', 'filled');
    tf.setAttribute('single-line', '');
    tf.setAttribute('label', '新 profile 的名字（字母数字 . _ -，不能叫 default）');
    fieldKey(tf, 'teesim-profile-new|name');
    w.appendChild(tf);
    const a = h('div', 'acts');
    a.appendChild(button('新建（复制 default）', { variant: 'filled', icon: ICON.addPkg, on: function () {
      const n = String(tf.value || '').trim();
      if (!/^[A-Za-z0-9._-]+$/.test(n)) { toast('名字只能用字母、数字、. _ -', true); return; }
      S.profile = n;
      write('teesim-profile-new', n, '已新建 profile：' + n);
    } }));
    w.appendChild(a);
    return w;
  }, '新建 profile'));
  s.appendChild(h('p', 'hint', 'profile 是名字→配置的表：每份自带 keybox、模式、三档补丁级别与设备身份。新建的 profile 复制 default 的整份配置，再逐项改。'));
  c.appendChild(s);
  box.appendChild(c);

  const e = card();
  const es = section('编辑 profile · ' + cur.name, ICON.patch);
  /* 表单读的是 backend-info 里 default profile 的那批字段；非 default 的字段值
     命令层还没逐份上报，所以这里明确说"当前值未知，留空即不改"，不假装看得见。 */
  es.appendChild(h('p', 'hint', cur.isDefault ? '下面显示的是该 profile 的当前值。'
    : '命令层目前只上报 default 的字段值 —— 非默认 profile 的输入框是空的，留空的字段不会被改动。'));
  e.appendChild(es);
  e.appendChild(form(cur.isDefault ? S.backendInfo : {}, F_PROFILE.concat(F_IDENTITY),
    'teesim-save', [['profile', cur.name]], '已保存 profile：' + cur.name));
  e.appendChild(h('p', 'hint', PATCH_HINT.teesim));
  box.appendChild(e);
  return box;
}

/* Tricky：全局段 + 按包段；tee_status 是只读事实 */
/* 上游写的是 Kotlin 布尔的字面量（Config.kt:127-143）：AVAILABLE→false、
   FAILED→true、UNAVAILABLE→unknown。命令层把键改成下划线风格输出，
   所以这里读 tee_broken / service_error_code，不是文件里的 teeBroken。 */
const TEE_BROKEN = {
  'false': ['ok', 'false = 探测成功，证书来自 TEE'],
  'true': ['warn', 'true = 探测失败，Tricky 退到自建证书'],
  'unknown': ['bad', 'unknown = 上游没给出探测结论，自动条目不会被改写'],
};
function trickyBlocks() {
  const box = h('div', 'stack');
  const t = S.teeStatus;
  const c = card();
  const s = section('TEE 探测结果', ICON.tee);
  if (t) {
    const [btone, bsup] = TEE_BROKEN[t.tee_broken] || ['none', '取值不在 false/true/unknown 里，按原样显示'];
    const r = resolveAuto(t);
    s.appendChild(list([
      item({ headline: 'status', trailing: t.status || '—', tone: r.tone,
        supporting: t.status ? r.note : '旧格式 tee_status 只有 teeBroken 一行 · ' + r.note }),
      item({ headline: 'tee_broken', trailing: t.tee_broken || '—', tone: btone, supporting: bsup }),
      item({ headline: 'category', trailing: t.category || '—',
        supporting: '上游用文字描述失败原因（not_run、aaid_timeout、异常名…），不是编号' }),
      item({ headline: 'service_error_code', trailing: t.service_error_code || '—' }),
      item({ headline: '自动条目现在走', trailing: r.to === 'none' ? '不匹配' : (MODE_LABEL[r.to] || '未探测'),
        tone: r.tone, supporting: '这个值是按下表现算的，不是写在 target.txt 里的' }),
    ]));
    s.appendChild(h('p', 'hint', '来源文件：' + (t.file || '—') + '（探测之后才写，可能比此刻的探测旧）'));
  } else {
    s.appendChild(list([item({ headline: 'tee_status', trailing: '读不到', tone: 'warn',
      supporting: S.teeWhy || (hasCmd('tee-status') ? '文件不存在或后端不是 Tricky' : '这一版命令层没有 tee-status') })]));
  }
  c.appendChild(s); box.appendChild(c);

  const p = card();
  const ps = section('补丁级别', ICON.patch);
  const seg = h('div', 'acts');
  const scopes = [{ scope: 'global', label: '全局' }].concat(S.trickyPatches.filter(function (b) { return b.scope !== 'global'; })
    .map(function (b) { return { scope: b.scope, label: b.scope }; }));
  scopes.forEach(function (o) {
    seg.appendChild(button(o.label, { variant: o.scope === S.scope ? 'filled' : 'text',
      on: function () { S.scope = o.scope; redraw(); } }));
  });
  /* 「新按包段」以前直接落到 'com.example'：S.newPkg 全工程没有输入口，
     点下去等于替用户编了一个包名，保存后文件里就真多出那一段。现在给它一个
     真的输入框（草稿机制会保住正在打的字），校验过才切过去。 */
  /* 按包段可删：先把选择挪回全局，再发删除 —— 删掉的正好是当前选中的段时，
     表单不该还指着一个已经不存在的作用域。全局段不给删（命令层也会拒）。 */
  if (S.scope !== 'global') {
    seg.appendChild(button('删除这一段', { variant: 'text', icon: ICON.del, on: function () {
      const sc = S.scope; S.scope = 'global';
      write('tricky-drop-patch', sc, '已删除补丁段：' + sc);
    } }));
  }
  ps.appendChild(seg);
  const nsRow = h('div', 'row');
  const nsTf = h('md-text-field');
  nsTf.setAttribute('variant', 'filled');
  nsTf.setAttribute('single-line', '');
  nsTf.setAttribute('label', '新按包段：包名');
  fieldKey(nsTf, 'tricky-save-patch|newscope');
  nsRow.appendChild(nsTf);
  nsRow.appendChild(button('新建这一段', { variant: 'tonal', icon: ICON.addPkg, on: function () {
    const v = String(nsTf.value || '').trim();
    if (!/^[A-Za-z0-9._]+$/.test(v)) { toast('包名只能用字母、数字、. 和 _', true); return; }
    S.scope = v;
    redraw();
  } }));
  ps.appendChild(nsRow);
  const cur = S.trickyPatches.filter(function (b) { return b.scope === S.scope; })[0];
  ps.appendChild(h('p', 'hint', cur ? '本段当前：system ' + cur.system + ' · vendor ' + cur.vendor + ' · boot ' + cur.boot
    : (S.scope === 'global' ? '全局段还没有值。' : '还没有 [' + S.scope + '] 这个段 —— 保存会新建它。')));
  p.appendChild(ps);
  p.appendChild(form(cur ? { patch_system: cur.system === '-' ? '' : cur.system,
    patch_vendor: cur.vendor === '-' ? '' : cur.vendor, patch_boot: cur.boot === '-' ? '' : cur.boot } : {},
    F_TRICKY, 'tricky-save-patch', [['scope', S.scope]], '已保存补丁段：' + S.scope));
  p.appendChild(h('p', 'hint', PATCH_HINT.tricky));
  box.appendChild(p);
  return box;
}

/* OMK：两份 toml 分开编辑，因为它们的生效代价不同 */
/* 折叠块：默认只给一个「编辑」按钮，点开才建控件。
   为什么不在进页面时就建：真机 128 条名单下切到后端页要 1010ms，采样分析器显示
   大头是 md-text-field / md-switch 自己的布局测量（getBoundingClientRect 8%、
   contentSize/measure 11%），不是我们的渲染函数。这两块表单 30 多个控件，
   用户不点「编辑」时没必要付这笔钱；顺便也让这一页从 7000px 缩回可读长度。 */
function fold(build, openText) {
  const wrap = h('div', 'fold');
  const head = h('div', 'acts');
  const btn = button(openText || '编辑', { variant: 'tonal', icon: ICON.edit });
  const body = h('div', 'fold-body');
  body.hidden = true;
  let built = false;
  btn.addEventListener('click', function () {
    if (!built) { body.appendChild(build()); built = true; }
    body.hidden = !body.hidden;
    btn.textContent = body.hidden ? (openText || '编辑') : '收起';
  });
  head.appendChild(btn);
  wrap.appendChild(head);
  wrap.appendChild(body);
  return wrap;
}

/* OMK 1.2.5 起 keymint / injector 是两个独立 daemon，keystore2 由 injector 注入。
   这三条是"证书为什么没生效"的第一现场；命令层只读上报，旧命令层没有这批键时
   整张卡不画 —— 不拿"读不到"冒充"未运行"。 */
function omkRuntime() {
  const bi = S.backendInfo;
  if (bi.omk_keymint_alive === undefined) return null;
  const km = bi.omk_keymint_alive === '1';
  const inj = bi.omk_injector_alive === '1';
  const ks = bi.omk_keystore_injected === '1';
  const pid = function (v) { return v ? 'PID ' + v : 'PID 读不到'; };
  const c = card();
  const s = section('运行状态', ICON.tee);
  s.appendChild(list([
    item({ headline: 'keymint 守护进程', trailing: km ? pid(bi.omk_keymint_daemon) : '未运行',
      tone: km ? 'ok' : 'bad',
      supporting: km ? 'OMK 自己的 keymint daemon，证书由它提供' : 'daemon 没起来：检查 OMK 模块是否启用、是否需要重启' }),
    item({ headline: 'injector 守护进程', trailing: inj ? pid(bi.omk_injector_daemon) : '未运行',
      tone: inj ? 'ok' : 'bad',
      supporting: inj ? '负责把 OMK 注入 keystore2' : '没有它，keystore2 不会加载 OMK' }),
    item({ headline: 'keystore2 注入', trailing: ks ? '已注入' : '未注入',
      tone: ks ? 'ok' : 'bad',
      supporting: 'keystore2 ' + (bi.omk_keystore_pid ? 'PID ' + bi.omk_keystore_pid : 'PID 读不到')
        + ' · 依据 injector.payload 里的 pid 与标识' }),
  ]));
  const mode = bi.omk_backend ? ' · 后端 ' + bi.omk_backend : '';
  s.appendChild(h('p', 'hint', 'OMK ' + (bi.module_version || '版本读不到') + ' · config v'
    + (bi.config_version || '?') + mode + ' —— 下面「生效代价」的按钮就是让这两个 daemon 重载。'));
  if (!km || !inj || !ks) {
    s.appendChild(h('p', 'read-err', '有状态不正常：先重启一次 OMK 模块或手机，再回来读；仍红就看 '
      + '/data/misc/keystore/omk/logs/ 里的 keymint.log / injector.log。'));
  }
  c.appendChild(s);
  return c;
}

function omkReload() {
  const box = h('div', 'stack');
  const rt = omkRuntime();
  if (rt) box.appendChild(rt);
  const c = card();
  const s = section('生效代价', ICON.restart);
  s.appendChild(list([
    item({ icon: 'check', headline: '热生效', supporting: '三档补丁级别 + os_patchlevel、跳过生物识别、回收旧 keybox 绑定的密钥' }),
    item({ icon: 'refresh', headline: '要重启 keymint', supporting: '其余 [trust] 与 [device] 字段：保存后触发 restart.keymint', tone: 'warn' }),
    item({ icon: 'warning', headline: '要重启手机', supporting: 'vb_key / vb_hash 从 random 改回 auto', tone: 'bad' }),
    item({ icon: 'https', headline: '界面上永不显示', supporting: '[crypto] 的五个种子是密钥材料' }),
  ]));
  if (hasCmd('omk-restart')) {
    const acts = h('div', 'acts');
    ['keymint', 'injector', 'all'].forEach(function (w) {
      acts.appendChild(button('触发 restart.' + w, { variant: w === 'all' ? 'tonal' : 'outlined',
        icon: ICON.restart, on: function () { write('omk-restart', w, '已请求重载：' + w); } }));
    });
    s.appendChild(acts);
  }
  c.appendChild(s); box.appendChild(c);

  const i = card();
  const is = section('injector.toml · 名单与路由', ICON.func);
  is.appendChild(h('p', 'hint', 'scoop 就是目标名单本身，只吃精确包名 —— 加/减包请在「名单」那一格做。'));
  const onN = OMK_INTERCEPTS.filter(function (m) { return String(S.backendInfo['intercept_' + m]) === 'true'; }).length;
  is.appendChild(list([
    item({ headline: '拦截方法', trailing: onN + ' / ' + OMK_INTERCEPTS.length + ' 开启' }),
    item({ headline: '主开关', trailing: S.backendInfo.injector_main_enabled || '—' }),
    item({ headline: '日志级别', trailing: S.backendInfo.injector_log_level || '—' }),
  ]));
  i.appendChild(is);
  i.appendChild(fold(function () {
    const f = h('div');
    f.appendChild(form(S.backendInfo, F_OMK_INJECTOR, 'omk-save-injector', null, '已保存 injector.toml'));
    /* 10 个独立开关放在自己的 .form 面里纵向排 —— 原来用的是 .acts（横向换行
       flex），每一行成了 flex 项，于是两三个开关挤在同一行、宽度参差。 */
    const ic = h('div', 'form');
    ic.appendChild(h('div', 'form-sub', '拦截方法 [intercept] · 10 项独立开关'));
    OMK_INTERCEPTS.forEach(function (m) {
      const row = h('div', 'row');
      row.appendChild(h('span', 'row-t', m));
      const sw = h('md-switch');
      sw.checked = String(S.backendInfo['intercept_' + m]) === 'true';
      sw.addEventListener('change', function () {
        write('omk-save-injector', b64('intercept_' + m + '=' + b64(sw.checked ? 'true' : 'false')), m + ' → ' + (sw.checked ? '拦' : '不拦'));
      });
      row.appendChild(sw);
      ic.appendChild(row);
    });
    f.appendChild(ic);
    return f;
  }, '编辑 injector.toml'));
  box.appendChild(i);

  const k = card();
  const ks = section('config.toml · 信任链与设备身份', ICON.tune);
  ks.appendChild(h('p', 'hint', '生效代价按这一单里动了哪些字段算（CONFIGURATION.md:415-425）：'
    + '只动四个补丁级别 → keymint 运行中整组热生效；掺进别的字段 → 重启 keymint；'
    + 'vb_key / vb_hash 从 random 改成 auto → 要重启【整机】。保存后的真实结果以提示条为准。'));
  ks.appendChild(list([
    item({ headline: '日志级别', trailing: S.backendInfo.config_log_level || '—' }),
    item({ headline: '跳过生物识别', trailing: S.backendInfo.cfg_force_skip_biometric || '未设置' }),
    /* 上游只在显式配置时才写这一行（旧配置里没有），命令层如实不输出。
       把空值显示成"关"就是错的事实 —— 如实写"未设置（默认 true）"。 */
    item({ headline: '回收旧 keybox 绑定的密钥', trailing: S.backendInfo.cfg_retire_stale_keys || '未设置（上游默认 true）' }),
    item({ headline: '补丁级别', supporting: 'security ' + (S.backendInfo.trust_security_patch || '—')
      + ' · os ' + (S.backendInfo.trust_os_patchlevel || '—')
      + ' · vendor ' + (S.backendInfo.trust_vendor_patchlevel || '—')
      + ' · boot ' + (S.backendInfo.trust_boot_patchlevel || '—') }),
  ]));
  k.appendChild(ks);
  k.appendChild(fold(function () {
    return form(S.backendInfo, F_OMK_CONFIG, 'omk-save-config', null, '已保存 config.toml');
  }, '编辑 config.toml'));
  box.appendChild(k);
  return box;
}

/* keybox：三家都有，路径与指纹来自 backend-info */
/* 三家的 keybox 判据互不相同，共用一句校验必然在其中一家是错的
   （判据与出处见 module/backends/keybox_check.awk 抬头）。 */
const KEYBOX_HINT = {
  tricky: 'Tricky 的解析器要求根元素是 <AndroidAttestation>，里面要有 <Keybox>、<Key algorithm>、<PrivateKey> 与 <CertificateChain>。解析不过会留用上一份，不会覆盖。',
  teesim: 'TEESim 运行时不看根元素名，只认 <Key algorithm="rsa"|"ecdsa">（小写）、<PrivateKey> 与至少两张 <Certificate>；读不懂就跳过这个 profile，名单里的应用退回真硬件。',
  omk: 'OMK 按整块正则取每个 <Key algorithm="…">…</Key>：必须有 EC 密钥，且每块自带 <NumberOfCertificates>N</NumberOfCertificates>、本块证书数正好等于 N。解析不过时守护进程会把自带模板【覆盖回这个文件】（本模块覆盖前留 keybox.xml.bak，可还原）。另：换 keybox 会把它绑定的旧密钥全部作废（默认 retire_stale_keybox_bound_keys = true），应用要重新注册一次才能再用。',
};
function keyboxCard() {
  const bi = S.backendInfo;
  const c = card();
  const s = section('密钥箱 keybox', ICON.keybox);
  const kbNote = bi.backend === 'teesim' && S.profile && S.profile !== 'default'
    ? '这份属于 default profile；当前选中的是 ' + S.profile + '，它的 keybox 是另一个文件。' : '';
  s.appendChild(list([
    item({ headline: '路径', supporting: (bi.keybox_file || '—') + (kbNote ? ' · ' + kbNote : ''),
      trailing: bi.keybox_exists === '1' ? '存在' : '不存在', tone: bi.keybox_exists === '1' ? 'ok' : 'bad' }),
    item({ headline: '大小与指纹', supporting: (bi.keybox_bytes || '?') + ' 字节 · ' + (bi.keybox_hash_algo || 'sha256') }),
    item({ headline: '指纹', supporting: bi.keybox_hash || '—', mono: !!bi.keybox_hash }),
  ]));
  s.appendChild(h('p', 'hint', KEYBOX_HINT[bi.backend] || KEYBOX_HINT.tricky));
  /* 多行输入也走 MD3 文本框（min/max-lines 决定高度），不再用裸 textarea ——
     裸标签在深色主题下是浏览器默认样式：灰底、字被裁、和整页不是一个语言。 */
  const ta = h('md-text-field');
  ta.setAttribute('variant', 'filled');
  ta.setAttribute('min-lines', '6');
  ta.setAttribute('max-lines', '14');
  ta.setAttribute('label', '粘贴新的 keybox.xml 全文');
  ta.setAttribute('supporting-text', '覆盖前会自动备份为 keybox.xml.bak');
  ta.setAttribute('class', 'kb-field');
  fieldKey(ta, 'keybox-save|xml');
  s.appendChild(ta);
  const acts = h('div', 'acts');
  acts.appendChild(button('替换 keybox', { variant: 'filled', icon: ICON.save, on: function () {
    const v = ta.value || '';
    /* 只拦"三家都必定不收"的形状（少了 <Key 块），判据比命令层宽；
       具体结构由 keybox_check.awk 按当前后端判，理由用 toast 原样报出来。 */
    if (v.indexOf('<Key') < 0) { toast('三家都要求至少一个 <Key algorithm="…"> 块，这段里一个也没有', true); return; }
    write('keybox-save', b64(v), '已替换 keybox');
  } }));
  s.appendChild(acts);
  c.appendChild(s);
  return c;
}

/* ── 日志页 ───────────────────────────────────────────────────────── */
/* 只重画日志台（不动芯片/按钮/开关）。切级别档以前走 redraw() —— 整页重建，
   60 行日志（每行三个节点）重造一遍，还会把滚动位置与焦点一起丢掉。 */
function paintLogRows(console_) {
  console_.textContent = '';
  /* 级别档 + 关键字两层过滤；关键字对"显示出来的文本"匹配（日志行里的 emoji
     在渲染时会被剥掉，按原文匹配会让用户搜他看得见的字却搜不到）。 */
  const q = String(S.logQuery || '').trim().toLowerCase();
  const shown = S.log.filter(function (l) {
    if (S.logFilter !== 'all') {
      const k = logLevel(l);
      if (S.logFilter === 'bad' ? k !== 'bad' : (k !== 'bad' && k !== 'warn')) return false;
    }
    if (!q) return true;
    return stripEmoji(l).toLowerCase().indexOf(q) >= 0;
  });
  if (!S.log.length) console_.appendChild(h('p', 'empty', S.logErr ? '日志读取失败。' : '还没有日志 —— 模块只在开机与文件变化时写。'));
  else if (!shown.length) console_.appendChild(h('p', 'empty',
    q ? '没有匹配「' + S.logQuery.trim() + '」的行（' + S.log.length + ' 行里）。' : '这一档没有行（' + S.log.length + ' 行里没有符合的）。'));
  else shown.forEach(function (l) { console_.appendChild(logRow(l)); });
}
export function renderLog() {
  const box = h('div', 'stack');
  const c = card();
  const s = section('运行日志', ICON.log);
  const bar = h('div', 'acts');
  /* 行数档位是筛选性质的（四选一），用芯片；刷新/清空仍是动作按钮 */
  const tailRow = h('div', 'acts filter-grid');
  [30, 60, 120, 300].forEach(function (n) {
    tailRow.appendChild(chip(String(n) + ' 行', n === S.tail, function () { S.tail = n; S.loaded.log = false; reload(); }));
  });
  s.appendChild(tailRow);
  /* 级别筛选：排障时只想看要处理的（问题 = 警告 + 错误）。计数写在芯片上，
     点一下就知道这一档有没有东西，不用滚到底再找颜色。 */
  const lv = { bad: 0, issue: 0 };
  S.log.forEach(function (l) {
    const k = logLevel(l);
    if (k === 'bad') { lv.bad++; lv.issue++; } else if (k === 'warn') lv.issue++;
  });
  const lvRow = h('div', 'acts filter-grid');
  const lvChips = [];
  [['all', '全部 ' + S.log.length], ['issue', '问题 ' + lv.issue], ['bad', '错误 ' + lv.bad]].forEach(function (v) {
    lvChips.push({ v: v[0], el: chip(v[1], S.logFilter === v[0], function () {
      S.logFilter = v[0];
      /* 芯片的选中态就地改：整页重建会把正在看的那一屏连同滚动位置一起重来。 */
      lvChips.forEach(function (o) {
        o.el.selected = (o.v === v[0]);
        if (o.v === v[0]) o.el.setAttribute('selected', ''); else o.el.removeAttribute('selected');
      });
      paintLogRows(console_);
    }) });
    lvRow.appendChild(lvChips[lvChips.length - 1].el);
  });
  s.appendChild(lvRow);
  /* 关键字过滤：只重画日志台（与级别芯片同一个理由），查询词存在 S 里，
     整页重建/重新进入后不丢。 */
  const qTf = h('md-text-field');
  qTf.setAttribute('variant', 'filled');
  qTf.setAttribute('single-line', '');
  qTf.setAttribute('label', '在日志里搜（包名、错误词、命令名）');
  qTf.value = S.logQuery || '';
  qTf.addEventListener('input', function () {
    S.logQuery = String(qTf.value || '');
    paintLogRows(console_);
  });
  s.appendChild(qTf);
  bar.appendChild(button('刷新', { variant: 'tonal', icon: ICON.read,
    on: function () { S.loaded.log = false; reload(); } }));
  bar.appendChild(button('清空缓冲', { variant: 'text',
    on: function () { write('clear-log', '', '已清空日志缓冲'); } }));
  s.appendChild(bar);
  /* 自动刷新：5 秒一次。开与关都要把定时器收掉，否则切走页面它还在跑。 */
  const row = h('div', 'row');
  row.appendChild(h('span', 'row-t', '自动刷新（5 秒）'));
  const sw = h('md-switch');
  sw.checked = !!S.autoTimer;
  sw.addEventListener('change', function () { setAuto(sw.checked); });
  row.appendChild(sw);
  s.appendChild(row);
  s.appendChild(h('p', 'hint', '末尾 ' + S.log.length + ' 行 · 缓冲 ' + bytesLabel(S.status.log_bytes)
    + '（' + (S.status.log_lines || '?') + ' 行）· 文件 ' + (S.status.log_file || '/data/adb/keylens.log')));
  const console_ = h('div', 'console tall');
  paintLogRows(console_);
  s.appendChild(console_);
  c.appendChild(s);
  box.appendChild(c);
  return box;
}
let autoFn = function () {};
export function onAuto(fn) { autoFn = fn; }
function setAuto(on) { autoFn(!!on); }

/* ── 主题与外观（旧版有，新版不能少） ─────────────────────────────── */
export function renderTheme() {
  const c = card();
  const s = section('外观', ICON.moon);
  const seg = h('div', 'acts');
  [['auto', '跟随系统'], ['light', '浅色'], ['dark', '深色']].forEach(function (v) {
    seg.appendChild(chip(v[1], v[0] === S.theme, function () { S.theme = v[0]; applyThemeFn(); redraw(); }));
  });
  s.appendChild(seg);
  s.appendChild(h('p', 'hint', '跟随系统时用管理器报告的系统深浅；强调色自动取系统主题色。'));
  if (S.env.sys_seed_src && S.env.sys_seed_src !== 'none') {
    s.appendChild(h('p', 'hint', '系统强调色来源：' + S.env.sys_seed_src));
  }
  /* 落了什么色由 theme.js 算（frro 解析 + tonal 自检 + 明度取内置），这里只照报 */
  s.appendChild(h('p', 'hint', accentNote()));
  c.appendChild(s);
  return c;
}
let applyThemeFn = function () {};
export function onApplyTheme(fn) { applyThemeFn = fn; }

/* 写操作：统一走契约闸门，成功后重读 */
function write(cmd, arg, note) {
  return call(cmd, arg).then(function (r) {
    /* 命令层可以改口：写了 apply_note 就以它为准。OMK 的生效代价是算出来的
       （只动 [trust] 那四个补丁字段 = 整组热生效、不重启），
       界面这边写死一句"已保存"就会说错话。 */
    var kv = r.ok ? parseKV(r.text || '') : null;
    if (r.ok) { toast((kv && kv.apply_note) || note || '已完成'); dropEdits(cmd); reload(); }
    else {
      /* 超时 ≠ 没写成：命令可能在守护进程那边跑完了，只是回调没回来。
         以前 failText 自己写着"已重新读取当前状态"，而这一句谁都没重读 ——
         屏幕上留的还是旧值。现在文案与动作对齐：这里真的重读一次。 */
      toast(failText(r) + (r.timeout ? '；正在重新读取当前状态' : ''), true);
      if (r.timeout) reload();
    }
  }, function (e) { toast(String((e && e.message) || e), true); });
}
let toastFn = function () {};
export function onToast(fn) { toastFn = fn; }
function toast(text, bad) { toastFn(text, !!bad); }
let reloadFn = function () {};
export function onReload(fn) { reloadFn = fn; }
function reload() { return reloadFn(); }
/* 重画当前页（切视图/改搜索词/换 profile 与主题都要立刻重排）。
   以前这六处直接写 `draw()` —— 那是个没 import 的自由变量，产物能跑只是 esbuild
   把三个模块摊进了同一个 IIFE 作用域；换打包器或撞名就当场 ReferenceError，
   而台架只驱动切页、点不到这些按钮，所以它一路绿。守这一类的是
   tools/module-scope-check.mjs。 */
let drawFn = function () {};
export function onDraw(fn) { drawFn = fn; }
function redraw() { drawFn(); }

/* props_masking 是三态：'on' / 'off' / 根本没读到（status 那次失败）。
   两态写法 `=== 'on' ? 开 : 关` 会把"读不到"画成"关"，而那颗切换键于是
   默认要"开" —— 用户点下去动的是他没打算动的东西。 */
function maskOn(st) { return !!(st && st.props_masking === 'on'); }
function maskKnown(st) { return !!(st && st.props_masking != null && st.props_masking !== ''); }

/* ── 草稿：正在输入但还没保存的值，跨"同一页重建"存活 ─────────────────
   写入后的 reloadAll、切视图芯片、换 profile 都会整页重建，以前把它一并抹掉：
   OMK 那一页有 config.toml 与 injector.toml 两份表单，存一份就把另一份正在粘的
   内容吃掉；keybox 页粘完整份 XML 再点一下 profile 芯片也一样没。
   做法：重建前把当前页上带 data-ek 的控件按 key 收进 S.edits（app.js 的 draw()
   调 captureEdits），重建时同名 key 回填（fieldKey），保存成功只清那一条命令的
   key（dropEdits），换页则整个作废（clearEdits）—— 草稿只在本页内活着，
   不会哪天回到这页突然冒出一周前输入的半截东西。 */
let editFocus = '';
export function fieldKey(el, key) {
  el.setAttribute('data-ek', key);
  const p = S.edits[key];
  if (p == null) return el;
  if (el.localName === 'md-switch') el.checked = (p === 'true'); else el.value = p;
  return el;
}
export function captureEdits(root) {
  if (!root || !root.querySelectorAll) return;
  const act = document.activeElement;
  root.querySelectorAll('[data-ek]').forEach(function (el) {
    const k = el.getAttribute('data-ek');
    S.edits[k] = el.localName === 'md-switch' ? String(!!el.checked) : String(el.value == null ? '' : el.value);
    if (el === act) editFocus = k;
  });
}
export function clearEdits() { S.edits = {}; editFocus = ''; }
export function dropEdits(cmd) {
  const pre = cmd + '|';
  Object.keys(S.edits).forEach(function (k) { if (k.indexOf(pre) === 0) delete S.edits[k]; });
}
/* 重建后把光标还给原来那一格（用户正在打字时被一次写入打断，不该掉回页首）。 */
export function restoreEditFocus(root) {
  const k = editFocus;
  if (!k || !root || !root.querySelector) { editFocus = ''; return; }
  const el = root.querySelector('[data-ek="' + k + '"]');
  editFocus = '';
  if (el && el.focus) { try { el.focus(); } catch (e) { } }
}
