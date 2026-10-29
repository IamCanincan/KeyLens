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
  addPkg: 'add', moon: 'dark_mode',
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
      supporting: '期望 ' + (p.want || '—'),
      trailing: p.st === 'ok' ? '一致' : p.st === 'missing' ? '读不到' : '不符',
      tone: p.st === 'ok' ? '' : (p.st === 'missing' ? 'warn' : 'bad'),
    }));
    if (p.st === 'diff') l.appendChild(h('div', 'prop-cur', '当前 ' + p.cur));
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
  box.appendChild(keyboxCard());
  box.appendChild(renderTheme());
  box.appendChild(selfCheck());
  return box;
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
  if (st.conflict === '1') {
    c.appendChild(h('p', 'warn-text', '检测到两个后端同时启用，模块已停止 —— 先只留一个。'));
  }
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
  const s = section('目标名单 · ' + (bi.target_file || '—'), ICON.list);
  /* 读不到时不许说"是空的" —— 命令层在目标文件缺失时就是 return 1，
     这条错误必须在名单卡的第一行，而不是滚到页尾的黄条里。 */
  if (S.listErr) s.appendChild(h('p', 'read-err', '名单读不到：' + S.listErr));
  s.appendChild(h('p', 'hint', '这个后端接受的写法：' + syn.label));
  const seg = h('div', 'acts');
  [['targets', '名单 ' + S.targets.length], ['apps', '已装 ' + S.apps.length],
   ['missing', '未纳入 ' + S.apps.filter(function (a) { return !baseSet[a]; }).length],
   ['excluded', '已排除 ' + S.excluded.length]].forEach(function (v) {
    seg.appendChild(button(v[1], { variant: v[0] === S.view ? 'filled' : 'text',
      on: function () { S.view = v[0]; draw(); } }));
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
  shown.slice(0, 200).forEach(function (tok) {
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
      const img = h('img', 'app-ic'); img.src = ic.src; img.alt = '';
      img.loading = 'lazy'; img.decoding = 'async';
      it.appendChild(img);
    }
    if (m) {
      it.appendChild(m.el);
    } else {
      it.appendChild(S.view === 'targets'
        ? button('移出', { variant: 'text', on: function () { write('remove-apps', b || tok, '已移出：' + (b || tok)); } })
        : button('加入', { variant: 'text', on: function () { write('restore-apps', b || tok, '已加入：' + (b || tok)); } }));
    }
    l.appendChild(it);
  });
  if (!shown.length) l.appendChild(h('p', 'empty', S.listErr ? '读不到，所以这一类画不出来。' : '这一类现在是空的。'));
  s.appendChild(l);
  s.appendChild(h('p', 'hint', '共 ' + shown.length + ' 条' + (shown.length > 200 ? '（只画前 200 条）' : '')));
  c.appendChild(s);
  loadIconsFor(shown);
  return c;
}

/* TEESim 的第二块可写面：overrides.json（上一版完全没有） */
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
  const rows = S.overrides.map(function (o) {
    return item({
      headline: o.field,
      supporting: '来源 ' + o.source + (o.editable ? '' : ' · 上游判定为不可改'),
      trailing: o.value,
      tone: o.editable ? 'ok' : 'warn',
    });
  });
  rows.push(item({ headline: 'deviceLocked / verifiedBootState',
    supporting: '根信任，上游明确不可改（REQUIRED 锁定）—— 只显示，不给输入框',
    trailing: '只读' }));
  s.appendChild(list(rows));
  s.appendChild(h('p', 'hint', '可编辑性是**数据决定**的：启动键/哈希只有当守护进程自己那份是合成兜底值时才可改，'
    + '所以这两格随来源变化，不是写死的开关。'));
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
  ['cfg_force_skip_biometric', 'config_force_skip_biometric', '跳过生物识别校验（不推荐）', 'switch'],
  ['cfg_retire_stale_keys', 'config_retire_stale_keys', '淘汰旧 keybox 绑定的密钥', 'switch'],
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
  box.appendChild(p);
  return box;
}

/* OMK：两份 toml 分开编辑，因为它们的生效代价不同 */
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
  i.appendChild(is);
  i.appendChild(form(S.backendInfo, F_OMK_INJECTOR, 'omk-save-injector', null, '已保存 injector.toml'));
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
  i.appendChild(ic);
  box.appendChild(i);

  const k = card();
  const ks = section('config.toml · 信任链与设备身份', ICON.tune);
  ks.appendChild(h('p', 'hint', '保存后 OMK 会重启 keymint —— 除四个补丁级别与两个开关外，其余字段都要这一步才读得到。'));
  k.appendChild(ks);
  k.appendChild(form(S.backendInfo, F_OMK_CONFIG, 'omk-save-config', null, '已保存 config.toml'));
  box.appendChild(k);
  return box;
}

/* keybox：三家都有，路径与指纹来自 backend-info */
function keyboxCard() {
  const bi = S.backendInfo;
  const c = card();
  const s = section('密钥箱 keybox', ICON.keybox);
  s.appendChild(list([
    item({ headline: '路径', supporting: bi.keybox_file || '—',
      trailing: bi.keybox_exists === '1' ? '存在' : '不存在', tone: bi.keybox_exists === '1' ? 'ok' : 'bad' }),
    item({ headline: '大小与指纹', supporting: (bi.keybox_bytes || '?') + ' 字节 · ' + (bi.keybox_hash_algo || 'sha256') }),
    item({ headline: '指纹', supporting: bi.keybox_hash || '—' }),
  ]));
  const ta = h('textarea', 'kb-paste');
  ta.placeholder = '粘贴新的 keybox.xml 全文，覆盖前会自动备份';
  ta.spellcheck = false;
  s.appendChild(ta);
  const acts = h('div', 'acts');
  acts.appendChild(button('替换 keybox', { variant: 'filled', icon: ICON.save, on: function () {
    const v = ta.value || '';
    if (v.indexOf('<Keybox') < 0 && v.indexOf('<AndroidAttestation') < 0) { toastFn('看起来不是 keybox XML', true); return; }
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
    + '（' + (S.status.log_lines || '?') + ' 行）· 文件 ' + (S.status.log_file || '/data/adb/ts_auto.log')));
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
    if (r.ok) { toast(note || '已完成'); reload(); }
    else toast(failText(r), true);
  }, function (e) { toast(String((e && e.message) || e), true); });
}
let toastFn = function () {};
export function onToast(fn) { toastFn = fn; }
function toast(text, bad) { toastFn(text, !!bad); }
let reloadFn = function () {};
export function onReload(fn) { reloadFn = fn; }
function reload() { return reloadFn(); }
