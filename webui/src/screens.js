/*=============================================================================
 * webui/src/screens.js — 各屏的渲染
 *
 * 结构按三家后端**文档里的能力面**排，不按上一版的菜单形状排：
 *  - TEESim 的 profiles 是一张名字→配置表（上一版只写 default）；
 *  - Tricky 有 tee_status（为什么只能走 leaf hack）与按包 [包名] 补丁块；
 *  - OMK 的字段分"热生效 / 要重启 keymint / 要重启手机"三档，界面上必须标出来。
 *===========================================================================*/
import { S, hasCmd, b64, bytesLabel, timeLabel, call, parseKV, failText } from './bridge.js';

/* 图标名一律取自库自带的子集（见 tools/md3e-build/vendor/icons.txt）。
   越界的名字会被组件当**字面词**画出来，icon-gate 在构建时就会拒绝。 */
export const ICON = {
  over: 'home', func: 'category', log: 'article', about: 'info',
  sync: 'refresh', read: 'download', backend: 'settings', list: 'group',
  keybox: 'https', patch: 'label', tee: 'verified', restart: 'tune',
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

/* ── 主页 ─────────────────────────────────────────────────────────── */
export function renderOver() {
  const st = S.status, env = S.env;
  const box = h('div', 'stack');

  const hero = card('hero');
  const [tone, label] = toneOfState(st.state);
  const top = h('div', 'hero-top');
  top.appendChild(h('span', 'chip chip-' + tone, label));
  top.appendChild(h('span', 'ver', st.mod_version || '—'));
  hero.appendChild(top);
  const big = h('div', 'hero-count');
  big.appendChild(h('span', 'num', S.loaded.lists ? String(S.targets.length) : '—'));
  big.appendChild(h('span', 'unit', '生效应用数'));
  hero.appendChild(big);
  const acts = h('div', 'acts');
  acts.appendChild(button('立即同步', { variant: 'filled', icon: ICON.sync, on: () => write('sync', '已请求同步') }));
  acts.appendChild(button('重新读取', { variant: 'tonal', icon: ICON.read, on: () => reload() }));
  hero.appendChild(acts);
  box.appendChild(hero);

  const ino = !env.inotify_mode ? '读取中' : env.inotify_mode === 'none' ? '未找到 inotify 工具' : env.inotify_mode;
  const run = card();
  const rs = section('运行', ICON.backend);
  rs.appendChild(list([
    item({ headline: '后端', trailing: st.backend_name || '—', tone: st.conflict === '1' ? 'bad' : 'ok' }),
    item({ headline: '事件监听', trailing: ino, tone: !env.inotify_mode ? 'none' : (env.inotify_mode === 'none' ? 'bad' : 'ok') }),
    item({ headline: '守护进程', trailing: st.daemon_alive === '0' ? '未运行' : st.daemon_alive + ' 个', tone: st.daemon_alive === '0' ? 'bad' : 'ok' }),
    item({ headline: '目标文件', trailing: (st.target_exists === '1' ? '存在' : '不存在') + (st.target_writable === '1' ? ' · 可写' : ' · 不可写'), tone: st.target_exists === '1' && st.target_writable === '1' ? 'ok' : 'bad', supporting: '上次写入 ' + timeLabel(st.target_mtime) }),
  ]));
  run.appendChild(rs);
  box.appendChild(run);

  box.appendChild(recentCard());
  return box;
}

/* 最近动态：与日志页共用同一个行渲染器，两处不会长得不一样 */
export function recentCard() {
  const c = card('recent');
  c.appendChild(section('最近动态', ICON.log));
  const box = h('div', 'console');
  const lines = S.log.slice(-5);
  if (!lines.length) {
    box.appendChild(h('p', 'empty', S.logErr ? '日志读取失败，详见日志页' : '还没有日志 —— 模块只在开机与文件变化时写。'));
  } else {
    lines.forEach(function (l) { box.appendChild(logRow(l)); });
  }
  c.appendChild(box);
  return c;
}

/* ── 日志行（时间 · 级别图标 · 正文） ───────────────────────────────── */
const EMOJI_RE = /\p{Extended_Pictographic}(?:\uFE0F)?(?:\u200D\p{Extended_Pictographic}(?:\uFE0F)?)*\s?/gu;
export function stripEmoji(s) { return String(s == null ? '' : s).replace(EMOJI_RE, ''); }
/* 级别判据一律用 \u 转义写，不放裸 emoji：上一版在这里掉了 ⛔ 那个字符，
   留下 `/❌||失败/` 这种**空分支** —— 空分支匹配任意字符串，于是每一行都判成
   错误、整屏涂红，而正则本身语法完全合法，扫不出来。 */
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

/* ── 后端页：三家各自的能力面 ──────────────────────────────────────── */
export function renderBackend() {
  const box = h('div', 'stack');
  const bi = S.backendInfo;
  const sum = card();
  sum.appendChild(section('当前后端 · ' + (bi.backend_name || '读取中'), ICON.backend));
  sum.appendChild(list([
    item({ headline: '目标文件', supporting: bi.target_file || '—', trailing: (bi.target_entries || '0') + ' 条' }),
    item({ headline: 'keybox', supporting: bi.keybox_file || '—', trailing: bi.keybox_exists === '1' ? '存在' : '不存在', tone: bi.keybox_exists === '1' ? 'ok' : 'warn' }),
  ]));
  box.appendChild(sum);

  if (bi.backend === 'teesim') box.appendChild(teesimProfiles());
  if (bi.backend === 'tricky') box.appendChild(trickyBlocks());
  if (bi.backend === 'omk') box.appendChild(omkReload());

  if (S.contract.bad) {
    const w = card('warn-card');
    w.appendChild(h('p', 'warn-text', '命令层契约不匹配（界面要 api=' + S.contract.api + '）：已停止一切写入，把模块整体重装一次。'));
    box.appendChild(w);
  }
  return box;
}

/* TEESim：profiles 是一张表，不是"一个 default" */
function teesimProfiles() {
  const c = card();
  const s = section('Profile 表', ICON.list);
  if (!S.profiles.length) {
    s.appendChild(h('p', 'empty', hasCmd('teesim-profiles')
      ? '读不到 profile 列表。'
      : '这一版命令层没有 teesim-profiles —— 重装模块后可以列出全部 profile。'));
  } else {
    s.appendChild(list(S.profiles.map(function (p) {
      return item({
        icon: p.isDefault ? 'star' : 'label',
        headline: p.name + (p.isDefault ? '（默认）' : ''),
        supporting: 'keybox ' + p.keybox + ' · ' + (p.mode === 'generation' ? '证书生成' : '补丁') + ' · 生效代价：保存后由守护进程热重载',
        trailing: p.apps + ' 条',
      });
    })));
    s.appendChild(h('p', 'hint', '上一版界面只读写 default 这一个 profile；其余 profile 在文件里存在但界面上从来看不见。编辑其它 profile 尚未接到新版界面上。'));
  }
  c.appendChild(s);
  return c;
}

/* Tricky：tee_status 是只读事实，按包补丁块是可编辑面 */
function trickyBlocks() {
  const c = card();
  const s = section('TEE 探测结果', ICON.tee);
  const t = S.teeStatus;
  if (!t) {
    s.appendChild(h('p', 'empty', hasCmd('tee-status') ? '读不到 tee_status。' : '这一版命令层没有 tee-status。'));
  } else {
    s.appendChild(list([
      item({ headline: 'status', trailing: t.status || '—', tone: t.status === 'AVAILABLE' ? 'ok' : 'bad' }),
      item({ headline: 'teeBroken', trailing: t.teeBroken || '—', tone: t.teeBroken === '1' ? 'warn' : 'ok', supporting: '1 = 这台机器的 TEE 不可用，Tricky 只能走 leaf hack' }),
      item({ headline: 'category', trailing: t.category || '—' }),
      item({ headline: 'serviceErrorCode', trailing: t.serviceErrorCode || '—' }),
    ]));
  }
  c.appendChild(s);

  const p = card();
  const ps = section('补丁级别（全局与按包）', ICON.patch);
  if (!S.trickyPatches.length) {
    ps.appendChild(h('p', 'empty', 'security_patch.txt 里没有读到块。'));
  } else {
    ps.appendChild(list(S.trickyPatches.map(function (b) {
      return item({
        headline: b.scope === 'global' ? '全局' : b.scope,
        supporting: 'system ' + b.system + ' · vendor ' + b.vendor + ' · boot ' + b.boot,
        tone: b.scope === 'global' ? '' : 'warn',
      });
    })));
    ps.appendChild(h('p', 'hint', '带包名的块覆盖全局值 —— 只改全局不等于那个包生效。编辑按包块尚未接到新版界面上。'));
  }
  p.appendChild(ps);
  c.appendChild(p);
  return c;
}

/* OMK：字段的生效代价分三档，界面上必须说清 */
function omkReload() {
  const c = card();
  const s = section('生效代价与重载', ICON.restart);
  s.appendChild(list([
    item({ icon: 'check', headline: '热生效', supporting: '三档补丁级别 + os_patchlevel、跳过生物识别、回收旧 keybox 绑定的密钥' }),
    item({ icon: 'refresh', headline: '要重启 keymint', supporting: '其余 [trust] 与 [device] 字段：保存后需触发 restart.keymint', tone: 'warn' }),
    item({ icon: 'warning', headline: '要重启手机', supporting: 'vb_key / vb_hash 从 random 改回 auto', tone: 'bad' }),
    item({ icon: 'https', headline: '界面上永不显示', supporting: '[crypto] 的五个种子是密钥材料' }),
  ]));
  if (hasCmd('omk-restart')) {
    const acts = h('div', 'acts');
    ['keymint', 'injector', 'all'].forEach(function (w) {
      acts.appendChild(button('触发 restart.' + w, { variant: w === 'all' ? 'tonal' : 'outlined', icon: ICON.restart, on: () => write('omk-restart', w, '已请求重载：' + w) }));
    });
    s.appendChild(acts);
  }
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
    bar.appendChild(button(String(n) + ' 行', { variant: n === S.tail ? 'filled' : 'text', on: function () { S.tail = n; S.loaded.log = false; reload(); } }));
  });
  bar.appendChild(button('刷新', { variant: 'tonal', icon: ICON.read, on: function () { S.loaded.log = false; reload(); } }));
  s.appendChild(bar);
  s.appendChild(h('p', 'hint', '末尾 ' + S.log.length + ' 行 · 缓冲 ' + bytesLabel(S.status.log_bytes)));
  const console_ = h('div', 'console tall');
  if (!S.log.length) console_.appendChild(h('p', 'empty', S.logErr ? '日志读取失败。' : '还没有日志 —— 模块只在开机与文件变化时写。'));
  else S.log.forEach(function (l) { console_.appendChild(logRow(l)); });
  s.appendChild(console_);
  c.appendChild(s);
  box.appendChild(c);
  return box;
}

/* ── 关于页：界面自检（桥接、契约、执行身份） ───────────────────────── */
export function renderAbout() {
  const box = h('div', 'stack');
  const c = card();
  const s = section('界面自检', ICON.about);
  s.appendChild(list([
    item({ headline: '桥接', trailing: S.bridge.kind || '未找到', tone: S.bridge.kind ? 'ok' : 'bad', supporting: '扫过：' + (S.bridge.seen.join(' ') || '无') }),
    item({ headline: '命令层契约', trailing: 'api ' + (S.contract.api === null ? '读不到' : S.contract.api), tone: S.contract.bad ? 'bad' : 'ok', supporting: '命令 ' + S.contract.commands.split(' ').filter(Boolean).length + ' 条' }),
    item({ headline: '主题', trailing: S.theme }),
    item({ headline: '视口', trailing: Math.round(document.documentElement.clientWidth) + ' CSS px' }),
  ]));
  c.appendChild(s);
  box.appendChild(c);
  return box;
}

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
