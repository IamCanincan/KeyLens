/*=============================================================================
 * webui/src/screens.js — 各屏的渲染
 *
 * 结构按三家后端**文档里的能力面**排，不按上一版的菜单形状排：
 *  - TEESim 的 profiles 是一张名字→配置表（上一版只写 default）；
 *  - Tricky 有 tee_status（为什么只能走 leaf hack）与按包 [包名] 补丁块；
 *  - OMK 的字段分"热生效 / 要重启 keymint / 要重启手机"三档，界面上必须标出来。
 *===========================================================================*/
import { S, EXPECT_API, hasCmd, b64, bytesLabel, timeLabel, call, parseKV, failText, loadIcons } from './bridge.js';
import { loadOverrides } from './bridge.js';

/* 图标名一律取自库自带的子集（见 tools/md3e-build/vendor/icons.txt）。
   越界的名字会被组件当**字面词**画出来，icon-gate 在构建时就会拒绝。 */
export const ICON = {
  over: 'home', func: 'category', log: 'article', about: 'info',
  sync: 'refresh', read: 'download', backend: 'settings', list: 'group',
  keybox: 'https', patch: 'label', tee: 'verified', restart: 'tune', save: 'save',
  addPkg: 'add', moon: 'dark_mode', edit: 'edit', tune: 'tune',
  ok: 'check', warn: 'warning', bad: 'error', none: 'help',
};

export function h(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text != null) e.textContent = String(text);
  return e;
}
export function attr(e, o) { for (const k in o) e.setAttribute(k, o[k]); return e; }

export function card(cls) { const c = h('md-card', 'card ' + (cls || '')); return c; }

export function section(title, icon) {
  const wrap = h('section', 'sec');
  const head = h('div', 'sec-h');
  if (icon) head.appendChild(attr(h('span', 'sec-i'), { 'aria-hidden': 'true' })).textContent = icon;
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
  if (o.interactive) it.setAttribute('interactive', '');
  return it;
}

export function list(items) {
  const l = h('md-list');
  items.forEach(function (x) { if (x) l.appendChild(x); });
  return l;
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
    item({ headline: '主题', trailing: S.theme, supporting: '视口 ' + Math.round(document.documentElement.clientWidth) + ' CSS px · 系统深色 ' + (S.env.sys_dark === '1' ? '是' : '否') }),
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
    default: return { to: '', tone: 'warn', note: 'tee_status.status=' + (tee.status || '空') + '，不认识的取值，无法判定' };
  }
}

/* 返回 { el, note }：note 要写进条目的 supporting 行 —— 触屏上没有 tooltip，
   藏在 title 里等于没写。 */
function modeButton(tok, meta, tee) {
  const kind = (meta && meta.kind) || 'auto';
  const r = kind === 'auto' ? resolveAuto(tee) : { to: kind, tone: kind === 'generate' ? 'warn' : 'ok', note: '' };
  const label = kind === 'auto'
    ? '自动 → ' + (r.to === 'none' ? '不匹配' : (MODE_LABEL[r.to] || '未探测'))
    : MODE_LABEL[kind];
  const el = button(label, { variant: 'text', on: function () {
      const order = ['auto', 'leaf', 'generate'];
      const next = order[(order.indexOf(kind) + 1) % 3];
      write('set-mode', baseOf(tok) + ' ' + next, '已切换为' + MODE_LABEL[next]);
    } });
  el.setAttribute('data-tone', r.tone);
  return { el: el, note: r.note };
}

let askedIcons = {};
/* 名单分批挂载的令牌：换页/重画时 +1，正在跑的分批循环看到它不是自己那批就停手
   （否则会往已经卸掉的列表里继续 append，白烧一帧还可能报错）。 */
let listToken = 0;
function loadIconsFor(shown) {
  const need = [];
  shown.forEach(function (t) { const b = baseOf(t); if (b && !S.icons[b] && !askedIcons[b]) { need.push(b); askedIcons[b] = 1; } });
  if (need.length) loadIcons(need.slice(0, 120));
}

/* ── 伪装页：属性对照 + Verified Boot（这两件事不受后端影响，独立成一格）── */
export function renderProps() {
  const box = h('div', 'stack');
  const diff = S.props.filter(function (p) { return p.st !== 'ok'; });

  const c1 = card();
  const s1 = section('系统属性 · ' + (diff.length ? diff.length + ' 项不符' : '全部一致'), ICON.tune);
  s1.appendChild(list([
    item({ headline: '开机重置属性', trailing: S.status.props_masking === 'on' ? '已开启' : '已关闭',
      tone: S.status.props_masking === 'on' ? 'ok' : 'warn',
      supporting: '关闭后下次开机不再写入' }),
    button(S.status.props_masking === 'on' ? '关闭开机写入' : '开启开机写入',
      { variant: 'tonal', on: function () { write(S.status.props_masking === 'on' ? 'props-off' : 'props-on', '', '已切换'); } }),
    button('立即应用一次', { variant: 'filled', icon: ICON.sync, on: function () { write('props-apply', '', '已写入并复核'); } }),
  ]));
  const l = h('md-list');
  S.props.forEach(function (p) {
    l.appendChild(item({
      headline: p.name,
      /* "当前"这行必须写在 supporting-text 里（组件是 white-space:pre-wrap，换行会
         正常显示、行高自己长）。以前是往 md-list 里 append 一个裸 div —— 它不在
         md-list 的白底表面里，于是第二行字漏到卡片外面、压在下一行上。 */
      supporting: '期望 ' + (p.want || '—') + (p.st === 'diff' ? '\n当前 ' + (p.cur || '—') : ''),
      trailing: p.st === 'ok' ? '一致' : p.st === 'missing' ? '读不到' : '不符',
      tone: p.st === 'ok' ? '' : (p.st === 'missing' ? 'warn' : 'bad'),
    }));
  });
  s1.appendChild(l);
  c1.appendChild(s1);
  box.appendChild(c1);

  const bt = S.boot;
  const c2 = card();
  const s2 = section('Verified Boot 哈希', ICON.tee);
  s2.appendChild(list([
    item({ headline: '当前 ro.boot.vbmeta.digest', supporting: (bt && bt.current) || '读不到' }),
    item({ headline: '模块应用值', supporting: (bt && bt.configured) || '未设置（不写 vbmeta.digest）',
      tone: bt && bt.configured ? 'ok' : 'warn' }),
  ]));
  /* 这个值要能改：旧版有 props-boot-hash 这条写命令，新版不给入口就是退步。
     校验按十六进制 64 位来，与命令层一致；清空 = 不应用。 */
  const tf = h('md-text-field');
  tf.setAttribute('label', '要应用的 digest（64 位十六进制，留空 = 不应用）');
  tf.value = (bt && bt.configured) || '';
  s2.appendChild(tf);
  const acts2 = h('div', 'acts');
  acts2.appendChild(button('保存并应用', { variant: 'filled', icon: ICON.save, on: function () {
    const v = String(tf.value || '').trim();
    if (v && !/^[0-9a-fA-F]{64}$/.test(v)) { toastFn('digest 必须是 64 位十六进制（或留空取消）', true); return; }
    write('props-boot-hash', b64(v), v ? '已写入并将在下次开机生效' : '已取消应用 vbmeta.digest');
  } }));
  s2.appendChild(acts2);
  c2.appendChild(s2);
  box.appendChild(c2);
  return box;
}

/* ── 后端控制面板：这就是主体，也是落地页 ───────────────────────────── */
/* 层级说明（这一版重排的原因）：本模块首先是一个**后端控制面板** —— 名单
   （target.txt / apps[] / scoop）本来就是三家后端自己的配置文件之一，控制它
   属于面板职责；"自动更新应用列表"才是我们附加上去的功能。上一版把生效数当
   英雄数字、把"立即同步"当主按钮、把名单提成独立一格，等于把附加功能放在了
   主体前面。现在：状态条 → 名单 → 该后端的配置面 → keybox → 只读状态 → 自检。 */
export function renderBackend() {
  const bi = S.backendInfo;
  const box = h('div', 'stack');
  box.appendChild(statusStrip());
  box.appendChild(listSection());
  if (bi.backend === 'teesim') { box.appendChild(teesimProfiles()); box.appendChild(teesimOverrides()); }
  if (bi.backend === 'tricky') { box.appendChild(trickyBlocks()); }
  if (bi.backend === 'omk') { box.appendChild(omkReload()); }
  /* 首屏之外的卡（keybox / 三家矩阵 / 外观 / 自检）推迟一帧再挂。
     975px 高的视口里它们都在折叠线以下，晚一帧出现没人看得见；而把它们的
     md-list-item / md-button 从切页的关键路径上摘掉，同步渲染与布局都能少一截。
     box 已经不在页面上（换页或重画了）就整批放弃 —— 不往卸掉的树里塞节点。 */
  setTimeout(function () {
    if (!box.isConnected) return;
    const frag = document.createDocumentFragment();
    frag.appendChild(keyboxCard());
    frag.appendChild(backendMatrix());
    frag.appendChild(renderTheme());
    frag.appendChild(selfCheck());
    box.appendChild(frag);
  }, 0);
  return box;
}

/* 三家互斥矩阵：抢的是同一个 keymint HAL，同时启用时本模块直接停止写入。
   状态报三态（active/disabled/absent）而不是"开/关"，因为下一步动作不一样：
   没装是去装，被禁是把 disable 删掉。以前命令层只报 teesim/tricky 两家、
   而 backends_conflict() 把 OMK 也数进去了 —— 于是横幅能亮却说不清是哪几家。 */
const BACKENDS = [
  ['tricky', 'Tricky Store', 'tricky_state', '证书改写走它自己的 target.txt 与 keybox.xml'],
  ['teesim', 'TEE Simulator', 'teesim_state', '多 profile，配置在 config.json + overrides.json'],
  ['omk', 'OhMyKeymint', 'omk_state', '名单在 injector.toml 的 scoop 段，另有 config.toml'],
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
  const s = section('三家后端 · 同一时刻只能一家在跑', ICON.backend);
  s.appendChild(list(BACKENDS.map(function (b) {
    const cur = st.backend === b[0];
    const rep = BSTATE[sv[b[0]]] || ['none', '读不到状态'];
    return item({
      headline: b[1],
      supporting: cur ? '当前生效的就是这一家 · ' + b[3] : b[3],
      trailing: (cur ? '● ' : '') + (sv[b[0]] ? rep[1] : '读不到'),
      tone: cur ? 'ok' : rep[0],
    });
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
function statusStrip() {
  const st = S.status;
  const [tone, label] = toneOfState(st.state);
  const c = card('strip');
  const row = h('div', 'strip-row');
  row.appendChild(h('span', 'chip chip-' + tone, label));
  row.appendChild(h('span', 'strip-k', st.backend_name || '未探测到后端'));
  row.appendChild(h('span', 'strip-k', st.mod_version || '—'));
  row.appendChild(h('span', 'strip-k', '生效 ' + (bi_entries() || '—') + ' 条'));
  c.appendChild(row);
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
  const s = section('目标名单', ICON.list);
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
    seg.appendChild(chip(v[1], v[0] === S.view, function () { S.view = v[0]; draw(); }));
  });
  s.appendChild(seg);
  const src = S.view === 'apps' ? S.apps
    : S.view === 'missing' ? S.apps.filter(function (a) { return !baseSet[a]; })
    : S.view === 'excluded' ? S.excluded : S.targets;
  const q = (S.search || '').toLowerCase();
  const shown = q ? src.filter(function (t) {
    return String(t).toLowerCase().indexOf(q) >= 0 || baseOf(t).toLowerCase().indexOf(q) >= 0
      || ((S.icons[baseOf(t)] || {}).label || '').toLowerCase().indexOf(q) >= 0;
  }) : src;
  const tf = h('md-text-field');
  tf.setAttribute('label', '搜索包名或应用名');
  tf.addEventListener('input', function () { S.search = String(tf.value || ''); draw(); });
  s.appendChild(tf);
  const l = h('md-list');
  const LIMIT = 200;
  const CHUNK = 40;
  const page = shown.slice(0, LIMIT);
  function rowOf(tok) {
    const b = baseOf(tok), ic = S.icons[b];
    const meta = (S.targetMeta || {})[tok];
    const isTrickyTargets = S.view === 'targets' && bi.backend === 'tricky' && syn.modes;
    const m = isTrickyTargets ? modeButton(tok, meta, S.teeStatus) : null;
    const detail = (ic && ic.label ? tok : '') || (meta && meta.detail ? (meta.kind === 'user' ? '用户 ' + meta.detail : 'UID ' + meta.detail) : '');
    const it = item({
      headline: (ic && ic.label) || b || tok,
      supporting: [detail, m && m.note].filter(Boolean).join(' · '),
      interactive: true,
    });
    if (ic && ic.src) {
      /* 必须进 start 槽并给尺寸：裸 img 落在默认槽里会按原图 256px 渲染，
         整行被一个巨大图标撑开（截图里 Grok 那张就是这样）。 */
      const img = h('img', 'app-ic'); img.src = ic.src; img.alt = '';
      img.setAttribute('slot', 'start');
      img.loading = 'lazy'; img.decoding = 'async';
      /* 图标文件缺失时不要留浏览器的破图符：退回"首字块"（旧版就是这个退路）。 */
      img.addEventListener('error', function () {
        const letter = ((ic.label || b || tok).trim().charAt(0) || '?').toUpperCase();
        const fb = h('span', 'app-ic-fallback', letter);
        fb.setAttribute('slot', 'start');
        if (img.parentNode) img.parentNode.replaceChild(fb, img);
      });
      it.appendChild(img);
    }
    if (m) {
      it.appendChild(m.el);
    } else {
      it.appendChild(S.view === 'targets'
        ? button('移出', { variant: 'text', on: function () { write('remove-apps', b || tok, '已移出：' + (b || tok)); } })
        : button('加入', { variant: 'text', on: function () { write('restore-apps', b || tok, '已加入：' + (b || tok)); } }));
    }
    return it;
  }
  page.slice(0, CHUNK).forEach(function (t) { l.appendChild(rowOf(t)); });
  s.appendChild(l);
  /* 空态也放 md-list **外面**：裸节点塞进列表没有白底、还会压到相邻行上。 */
  if (!shown.length) s.appendChild(h('p', 'empty', S.listErr ? '读不到，所以这一类画不出来。' : '这一类现在是空的。'));
  const overLimit = shown.length > LIMIT ? '（只画前 ' + LIMIT + ' 条）' : '';
  const countHint = h('p', 'hint', '共 ' + shown.length + ' 条' + overLimit);
  s.appendChild(countHint);
  c.appendChild(s);
  /* 剩下的分批挂上去。为什么：一次建 144 个 md-list-item 会让"点底栏切页"卡到 1 秒
     —— 实测 1010ms / 448 节点，采样分析器显示耗时在组件自己 getBoundingClientRect /
     contentSize / 读 CSS 变量，不在我们的渲染函数里。先画 40 条让这一页立刻可交互，
     其余每帧 40 条补齐；换页或重画时 token 变了就停，不会往已经卸掉的列表里塞节点。 */
  if (page.length > CHUNK) {
    const token = ++listToken;
    let i = CHUNK;
    const step = function () {
      if (token !== listToken) return;
      const end = Math.min(i + CHUNK, page.length);
      const frag = document.createDocumentFragment();
      for (; i < end; i++) frag.appendChild(rowOf(page[i]));
      l.appendChild(frag);
      loadIconsFor(page.slice(0, i));
      countHint.textContent = '共 ' + shown.length + ' 条' + overLimit + ' · 已显示 ' + i;
      if (i < page.length) setTimeout(step, 16);
      else countHint.textContent = '共 ' + shown.length + ' 条' + overLimit;
    };
    setTimeout(step, 16);
  } else {
    loadIconsFor(page);
  }
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
export function renderAutoSync() {
  const st = S.status, env = S.env;
  const box = h('div', 'stack');
  const c = card();
  const s = section('自动更新应用列表', ICON.sync);
  s.appendChild(h('p', 'hint', '这是本模块附加的功能：三家后端自己都不主动改名单，模块在开机与文件变化时'
    + '把已装应用同步进当前后端的名单文件。后端配置本身在「后端」那一格。'));
  const ino = !env.inotify_mode ? '读取中' : env.inotify_mode === 'none' ? '未找到 inotify 工具' : env.inotify_mode;
  s.appendChild(list([
    item({ headline: '守护进程', trailing: st.daemon_alive === '0' ? '未运行' : st.daemon_alive + ' 个', tone: st.daemon_alive === '0' ? 'bad' : 'ok' }),
    item({ headline: '事件监听', trailing: ino, tone: env.inotify_mode === 'none' ? 'bad' : 'ok' }),
    item({ headline: '目标文件', trailing: (st.target_exists === '1' ? '存在' : '不存在') + (st.target_writable === '1' ? ' · 可写' : ' · 不可写'),
      tone: st.target_exists === '1' && st.target_writable === '1' ? 'ok' : 'bad', supporting: '上次写入 ' + timeLabel(st.target_mtime) }),
    item({ headline: '日志', trailing: bytesLabel(st.log_bytes), supporting: (st.log_lines || '?') + ' 行 · ' + (st.log_file || '') }),
  ]));
  const acts = h('div', 'acts');
  acts.appendChild(button('立即同步一次', { variant: 'filled', icon: ICON.sync, on: function () { write('sync', '', '已请求同步'); } }));
  acts.appendChild(button('重新读取', { variant: 'tonal', icon: ICON.read, on: function () { reload(); } }));
  s.appendChild(acts);
  s.appendChild(h('p', 'hint', '最近一次描述：' + (stripEmoji(st.description || '') || '—')));
  c.appendChild(s);
  box.appendChild(c);

  /* 自动纳入：OMK/Tricky 没有这个概念，只有 TEESim 的 autoIncludeNewApps 有 */
  const a = card();
  const as = section('自动纳入新应用', ICON.addPkg);
  as.appendChild(h('p', 'hint', '只有 TEE Simulator 有这一项（profile 级 autoIncludeNewApps）。'
    + '它依赖一份只冻结一次的基线包名表，且只在守护进程 rescan 时展开 —— 开关打开不等于立刻生效。'));
  as.appendChild(h('p', 'empty', S.backendInfo.backend === 'teesim' ? '当前后端：TEE Simulator，可在下方 profile 里逐份设置。'
    : '当前后端不是 TEE Simulator，这一项不适用。'));
  a.appendChild(as);
  box.appendChild(a);
  return box;
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
    if (type === 'switch') {
      const row = h('div', 'row');
      row.appendChild(h('span', 'row-t', label));
      const sw = h('md-switch');
      sw.checked = String(cur) === 'true';
      row.appendChild(sw);
      wrap.appendChild(row);
      ctrls.push({ key: key, get: function () { return sw.checked ? 'true' : 'false'; }, init: sw.checked ? 'true' : 'false' });
    } else if (type === 'select' || type === 'seg') {
      const row = h('div', 'row');
      row.appendChild(h('span', 'row-t', label));
      const sel = h('md-select');
      (opts || []).forEach(function (o) { const op = h('md-option'); op.value = o[0]; op.textContent = o[1]; sel.appendChild(op); });
      sel.value = cur == null || cur === '' ? (opts && opts[0] ? opts[0][0] : '') : String(cur);
      row.appendChild(sel);
      wrap.appendChild(row);
      ctrls.push({ key: key, get: function () { return String(sel.value || ''); }, init: String(sel.value || '') });
    } else {
      const tf = h('md-text-field');
      tf.setAttribute('label', label);
      tf.value = cur == null ? '' : String(cur);
      wrap.appendChild(tf);
      ctrls.push({ key: key, get: function () { return String(tf.value || ''); }, init: String(tf.value || '') });
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
  const seg = h('div', 'acts');
  S.profiles.forEach(function (p) {
    seg.appendChild(button(p.name + (p.isDefault ? '（默认）' : '') + ' · ' + p.apps + ' 条', {
      variant: p.name === S.profile ? 'filled' : 'text',
      on: function () { S.profile = p.name; draw(); },
    }));
  });
  s.appendChild(seg);
  s.appendChild(h('p', 'hint', '上一版界面只读写 default 这一份；其余 profile 在文件里存在但界面上从来看不见。'));
  c.appendChild(s);
  box.appendChild(c);

  const cur = S.profiles.filter(function (p) { return p.name === S.profile; })[0] || S.profiles[0];
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
      item({ headline: 'status', trailing: t.status || '—', tone: r.tone, supporting: r.note }),
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
      on: function () { S.scope = o.scope; draw(); } }));
  });
  seg.appendChild(button('新按包段', { variant: 'tonal', icon: ICON.addPkg, on: function () { S.scope = S.newPkg || 'com.example'; draw(); } }));
  ps.appendChild(seg);
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

function omkReload() {
  const box = h('div', 'stack');
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
  const is = section('injector.toml · 名单与路由', ICON.backend);
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
    const ic = h('div', 'acts');
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
    /* 这一项在真机的 config.toml 里**本来就没有那一行**（上游默认 true），
       命令层如实不输出。把空值显示成"关"就是错的事实 —— 如实写"未设置（默认 true）"。 */
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
    item({ headline: '指纹', supporting: bi.keybox_hash || '—' }),
  ]));
  s.appendChild(h('p', 'hint', KEYBOX_HINT[bi.backend] || KEYBOX_HINT.tricky));
  const ta = h('textarea', 'kb-paste');
  ta.placeholder = '粘贴新的 keybox.xml 全文，覆盖前会自动备份';
  ta.spellcheck = false;
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
export function renderLog() {
  const box = h('div', 'stack');
  const c = card();
  const s = section('运行日志', ICON.log);
  const bar = h('div', 'acts');
  [30, 60, 120, 300].forEach(function (n) {
    bar.appendChild(button(String(n) + ' 行', { variant: n === S.tail ? 'filled' : 'text',
      on: function () { S.tail = n; S.loaded.log = false; reload(); } }));
  });
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
  if (!S.log.length) console_.appendChild(h('p', 'empty', S.logErr ? '日志读取失败。' : '还没有日志 —— 模块只在开机与文件变化时写。'));
  else S.log.forEach(function (l) { console_.appendChild(logRow(l)); });
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
    seg.appendChild(button(v[1], { variant: v[0] === S.theme ? 'filled' : 'text',
      on: function () { S.theme = v[0]; applyThemeFn(); draw(); } }));
  });
  s.appendChild(seg);
  s.appendChild(h('p', 'hint', '跟随系统时读 env 的 sys_dark（管理器报告的 mComputedNightMode），'
    + '不是只看 CSS 的 prefers-color-scheme。'));
  if (S.env.sys_seed_src && S.env.sys_seed_src !== 'none') {
    s.appendChild(h('p', 'hint', '系统强调色来源：' + S.env.sys_seed_src));
  }
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
    if (r.ok) { toast((kv && kv.apply_note) || note || '已完成'); reload(); }
    else toast(failText(r), true);
  }, function (e) { toast(String((e && e.message) || e), true); });
}
let toastFn = function () {};
export function onToast(fn) { toastFn = fn; }
function toast(text, bad) { toastFn(text, !!bad); }
let reloadFn = function () {};
export function onReload(fn) { reloadFn = fn; }
function reload() { return reloadFn(); }
