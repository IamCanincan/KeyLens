/*=============================================================================
 * webui/src/bridge.js — 传输层与数据层
 *
 * 这一份是从线上跑着的那版里搬过来的判据，不是重新发明的：
 *  - 桥接探测要把**看到的全部**记下来（连不上时界面要能自证扫了哪些名字）；
 *  - 契约号对不上就停写，而不是拿旧解析画新数据；
 *  - 每条命令的返回形状要校验（缺键 = 版本不匹配），停在传输层这一处，
 *    以后多加一个写入口就少漏一个。
 *===========================================================================*/

export const QUERY = new URLSearchParams(location.search);
export const MODDIR = QUERY.get('mod') || '/data/adb/modules/keylens';
export const SH = 'sh ' + MODDIR + '/webui.sh';
export const DEMO = QUERY.get('demo') === '1';
/* 台架专用的两个开关，只在 demo=1 时有效：真机界面永远走不到这里。
   backend 决定假数据是哪一家后端（三家各自的能力面只有切过去才画得出来），
   fail 用来把某一条读取打成失败（"读不到"必须和"是空的"长得不一样）。 */
export const DEMO_BACKEND = DEMO ? (QUERY.get('backend') || 'omk') : '';
export const DEMO_FAIL = DEMO ? (QUERY.get('fail') || '') : '';
/* conflict=1：三家都"启用"，用来把互斥横幅那一条画出来给台架看 —— 那是模块
   停写的状态，平时真机上碰不到，不造就没有任何证据它渲染得对。 */
export const DEMO_CONFLICT = DEMO && QUERY.get('conflict') === '1';

/* 界面期望的契约号。命令层只加命令、不改输出形状时这个号不动 —— 涨号会让手机上
   正在跑的旧界面当场判"契约不符"并停写。 */
export const EXPECT_API = 4;

/* 写命令：契约不符时全部拒绝。新增写入口必须同时加进这里。 */
export const WRITE_CMDS = 'props-apply props-on props-off props-boot-hash restore-app restore-apps \
remove-apps set-mode teesim-save teesim-save-overrides omk-save-injector omk-save-config tricky-save-patch keybox-save \
sync clear-log omk-restart';

/* 每条命令必须出现的键 —— 这张表是从线上那版抄的，键名以真机 `webui.sh status`
   的实际输出为准。自己凭想象写一份的后果：每条命令都会被判"形状不符"，
   契约闸门随即停写，整个界面变成只读。
   TSV 输出的命令（props / targets / apps / icons / log / teesim-profiles /
   tricky-patches / excluded）没有键，一律留空 —— 给它们编一个 required 键
   等于永远判失败。 */
export const KV_REQUIRED = {
  status: 'state backend mod_version target_file target_exists daemon_alive',
  env: 'resetprop awk base64 inotify_mode root_user',
  contract: 'api commands',
  'boot-hash': 'configured current status',
  sync: 'rc count description',
  'restore-app': 'restored',
  'restore-apps': 'restored',
  'remove-apps': 'removed',
  'set-mode': 'changed',
  'teesim-save': 'saved fields',
  'teesim-save-overrides': 'saved fields',
  'omk-save-injector': 'saved fields',
  'omk-save-config': 'saved fields',
  'tricky-save-patch': 'saved fields',
  'keybox-save': 'saved keybox_file keybox_bytes',
  'backend-info': 'backend backend_name target_file target_entries keybox_file keybox_exists',
  'props-apply': 'applied mismatch',
  'props-on': 'props_masking',
  'props-off': 'props_masking',
  'props-boot-hash': 'saved applied current',
  'clear-log': 'cleared',
  'tee-status': 'present',
  'omk-restart': 'restarted trigger',
};

export const BRIDGE_CANDIDATES = ['bridge', 'kernelsu', 'apatch', 'Magisk', 'magisk', 'ksu'];

function ownKeys(o) {
  var a = [];
  try { a = Object.getOwnPropertyNames(o) || []; } catch (e) {}
  return a;
}
export function methodsOf(o) {
  return ownKeys(o).filter(function (k) {
    try { return typeof o[k] === 'function'; } catch (e) { return false; }
  });
}

/* 找桥：不只"找一个能用的"，把看到的全部留下 —— 排查时"扫了哪些名字、各自有
   什么方法"比"失败了"有用。 */
export function findBridge() {
  var seen = [];
  for (var i = 0; i < BRIDGE_CANDIDATES.length; i++) {
    var name = BRIDGE_CANDIDATES[i];
    var obj = null;
    try { obj = window[name]; } catch (e) { obj = null; }
    if (!obj || typeof obj !== 'object') continue;
    var ms = methodsOf(obj);
    seen.push(name + '[' + ms.join(',') + ']');
    if (typeof obj.exec === 'function') return { obj: obj, kind: name, label: name, seen: seen };
  }
  return { obj: null, kind: '', label: '', seen: seen };
}

export const S = {
  /* 每个字段都要有读它的地方 —— 曾经躺着但已没人用的那几个
     （appsSrc / selectMode / selected / targetSet / targetBaseSet / logSig）随
     多选与撤销那套界面一起退役，留在这里只会被下一个人当成"还有这条路子"。 */
  status: {}, env: {}, tab: 'home', sub: '',
  contract: { api: null, commands: '', bad: false, shape: '', checked: false },
  bridge: { kind: '', label: '', seen: [] },
  targets: [], apps: [], targetMeta: {}, listErr: '',
  backendInfo: {}, profiles: [], teeStatus: null, teeWhy: '', trickyPatches: [],
  view: 'targets', search: '',
  profile: 'default', scope: 'global', newPkg: '', overrides: [],
  icons: {}, log: [], logErr: false, logFilter: 'all', tail: 60, props: [], boot: null,
  excluded: [], theme: 'auto',
  loaded: {}, seq: 0,
};

let BRIDGE = null;
const inflight = {};

export function hasCmd(name) {
  return (' ' + S.contract.commands + ' ').indexOf(' ' + name + ' ') >= 0;
}

export function parseKV(text) {
  var out = {};
  String(text == null ? '' : text).split('\n').forEach(function (line) {
    var i = line.indexOf('=');
    if (i <= 0) return;
    var k = line.slice(0, i);
    if (!(k in out)) out[k] = line.slice(i + 1);   // 重复键取第一条
  });
  return out;
}
export function splitLines(text) {
  return String(text == null ? '' : text).split('\n').filter(function (l) { return l.length > 0; });
}
export function b64(str) {
  var s = String(str), out = '';
  for (var i = 0; i < s.length; i++) out += '%' + ('00' + s.charCodeAt(i).toString(16)).slice(-2);
  return btoa(unescape(decodeURIComponent(escape(out))));
}
export function bytesLabel(n) {
  n = Number(n) || 0;
  if (n < 1024) return n + ' B';
  if (n < 1048576) return (n / 1024).toFixed(1) + ' KB';
  return (n / 1048576).toFixed(1) + ' MB';
}
export function timeLabel(epoch) {
  var e = Number(epoch) || 0;
  if (!e) return '从未';
  var d = new Date(e * 1000);
  var p = function (x) { return ('0' + x).slice(-2); };
  return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate())
    + ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
}
export function failText(r) {
  if (r && r.timeout) return '命令超时，结果未知；已重新读取当前状态';
  var t = String((r && r.text) || '').trim().split('\n').filter(Boolean).slice(-2).join(' ');
  return t || ('命令失败（退出码 ' + ((r && r.code) || '?') + '）');
}

/* 桥接的调用形状按管理器分叉，这里踩过一次大的：
 *   · KernelSU 主线（me.weishu.kernelsu）的 exec(cmd, optionsJson, **回调函数名字符串**)
 *     —— 第三个参数给函数对象的话，它不认，回调永远不触发，界面就停在"只有框架"，
 *     30 秒后才报超时。这是从**机上能用的那一版**里抠出来的形状。
 *   · 其余（APatch / Magisk）：exec(cmd, callback)，或同步直接返回 {errno, stdout}。
 * 台架以前走 ?demo=1，压根不经过这条路 —— 所以这个 bug 台架永远看不见。
 * 现在由 tools/replay-check.mjs 用真机数据 + 真形状（函数名回调）驱动整页。 */
var cbSeq = 0;

function run(cmd, arg) {
  if (DEMO) return Promise.resolve(demoResult(cmd, arg));
  if (!BRIDGE) return Promise.resolve({ errno: 1, stdout: '', stderr: '桥接未就绪' });
  var full = SH + ' ' + cmd + (arg != null && arg !== '' ? " '" + String(arg).replace(/'/g, "'\\''") + "'" : '');
  return new Promise(function (resolve) {
    var done = false, timer = null, sync;
    function finish(v) {
      if (done) return;
      done = true;
      if (timer) { clearTimeout(timer); timer = null; }
      v = v || {};
      resolve({ errno: Number(v.errno) | 0, stdout: String(v.stdout == null ? '' : v.stdout),
        stderr: String(v.stderr == null ? '' : v.stderr), timeout: !!v.timeout });
    }
    timer = setTimeout(function () { finish({ errno: 124, stdout: '', stderr: '命令超时（30 秒未返回）', timeout: true }); }, 30000);

    if (S.bridge.kind === 'ksu') {
      var name = 'tsaa_cb_' + (cbSeq++) + '_' + Date.now();
      window[name] = function (errno, stdout, stderr) {
        delete window[name];
        var out = String(stdout == null ? '' : stdout);
        if (stderr) out += String(stderr);          // 命令侧已 2>&1，这里兜一手
        finish({ errno: errno, stdout: out });
      };
      try { BRIDGE.exec(full, '{}', name); }
      catch (e) { delete window[name]; finish({ errno: 1, stderr: String((e && e.message) || e) }); }
      return;
    }

    try { sync = BRIDGE.exec(full, function (v) { finish(v); }); }
    catch (e) { finish({ errno: 1, stderr: String((e && e.message) || e) }); return; }
    if (sync !== undefined) finish(sync);
  });
}

function kvMissing(cmd, text) {
  var need = KV_REQUIRED[cmd];
  if (!need) return null;
  var kv = parseKV(text), miss = [];
  need.split(' ').forEach(function (k) { if (k && !(k in kv)) miss.push(k); });
  return miss.length ? miss : null;
}

export function call(cmd, arg) {
  if (S.contract.bad && (' ' + WRITE_CMDS + ' ').indexOf(' ' + cmd + ' ') >= 0) {
    return Promise.reject(new Error(S.contract.shape
      ? (S.contract.shape + '，已拒绝写入')
      : '命令层契约不匹配（界面要 api=' + EXPECT_API + '，命令层是 '
        + (S.contract.api === null ? '读不到' : S.contract.api) + '），已拒绝写入'));
  }
  return run(cmd, arg).then(function (r) {
    var res = { ok: r.errno === 0, code: r.errno, text: r.stdout, timeout: !!r.timeout };
    if (res.ok) {
      var miss = kvMissing(cmd, res.text);
      if (miss) {
        res.ok = false; res.shape = true;
        res.text = '命令层返回格式不一致（' + cmd + ' 缺少 ' + miss.join('、') + '），可能界面与命令层不是同一版';
        S.contract.bad = true; S.contract.shape = res.text;
      }
    }
    return res;
  });
}

export function checkContract() {
  return call('contract').then(function (r) {
    S.contract.checked = true;
    if (!r.ok) { S.contract.api = null; S.contract.bad = true; if (r.shape) S.contract.shape = r.text; return; }
    var kv = parseKV(r.text);
    S.contract.api = kv.api || null;
    S.contract.commands = kv.commands || '';
    S.contract.shape = '';
    S.contract.bad = (S.contract.api !== String(EXPECT_API));
  }, function () { S.contract.checked = true; });
}

/* ── 数据装载 ─────────────────────────────────────────────────────── */
export function loadBase() {
  return Promise.all([
    call('status').then(function (r) { if (r.ok) S.status = parseKV(r.text); }),
    call('env').then(function (r) { if (r.ok) S.env = parseKV(r.text); }),
  ]);
}
export function loadLists() {
  var errs = [];
  function note(name) {
    return function (r) {
      if (!r.ok) errs.push(name + '：' + failText(r));
      return r;
    };
  }
  return Promise.all([
    call('targets').then(function (r) { S.targets = r.ok ? splitLines(r.text) : []; return r; }).then(note('targets')),
    call('apps').then(function (r) { S.apps = r.ok ? splitLines(r.text) : []; return r; }).then(note('apps')),
    call('target-meta').then(function (r) {
      S.targetMeta = {};
      if (!r.ok) return r;
      splitLines(r.text).forEach(function (line) {
        var f = line.split('\t');
        if (f.length >= 4) S.targetMeta[f[0]] = { base: f[1] || '', kind: f[2] || 'plain', detail: f[3] || '' };
      });
      return r;
    }).then(note('target-meta')),
  ]).then(function () {
    /* "读不到"与"名单是空的"是两件事：以前三处失败都吞成空数组，界面照样
       说"这一类现在是空的"。命令层在目标文件缺失时正是这么退的（return 1）。 */
    S.listErr = errs.join('；');
  });
}
export function loadLog() {
  return call('log', String(S.tail)).then(function (r) {
    S.log = r.ok ? splitLines(r.text) : [];
    S.logErr = !r.ok;
  });
}
export function loadBackend() {
  return call('backend-info').then(function (r) { if (r.ok) S.backendInfo = parseKV(r.text); });
}
/* 三家各自的能力面：命令层没有就不问（问了会拿到"未知命令"，白白红一次） */
export function loadTeesimProfiles() {
  if (S.contract.checked && !hasCmd('teesim-profiles')) { S.profiles = []; return Promise.resolve(); }
  return call('teesim-profiles').then(function (r) {
    S.profiles = r.ok ? splitLines(r.text).map(function (line) {
      var f = line.split('\t');
      return { name: f[0] || '', keybox: f[1] || '', mode: f[2] || '', apps: Number(f[3] || 0) || 0, isDefault: f[4] === '1' };
    }) : [];
  }, function () { S.profiles = []; });
}
export function loadTeeStatus() {
  if (S.contract.checked && !hasCmd('tee-status')) { S.teeStatus = null; S.teeWhy = '这一版命令层没有 tee-status 命令'; return Promise.resolve(); }
  return call('tee-status').then(function (r) {
    var kv = r.ok ? parseKV(r.text) : null;
    if (kv && kv.present === '1') {
      S.teeStatus = kv; S.teeWhy = '';
    } else if (kv) {
      // 上游只在探测之后写这个文件（Config.kt:127），从没探测过就是不存在
      S.teeStatus = null; S.teeWhy = '还没有 tee_status 文件：Tricky 守护进程没跑过探测，或后端不是 Tricky';
    } else {
      S.teeStatus = null; S.teeWhy = 'tee-status 命令读失败：' + failText(r);
    }
  }, function (e) { S.teeStatus = null; S.teeWhy = 'tee-status 命令执行失败：' + e; });
}
export function loadTrickyPatches() {
  if (S.contract.checked && !hasCmd('tricky-patches')) { S.trickyPatches = []; return Promise.resolve(); }
  return call('tricky-patches').then(function (r) {
    S.trickyPatches = r.ok ? splitLines(r.text).map(function (line) {
      var f = line.split('\t');
      return { scope: f[0] || '', system: f[1] || '-', vendor: f[2] || '-', boot: f[3] || '-' };
    }) : [];
  }, function () { S.trickyPatches = []; });
}

export function loadProps() {
  return call('props').then(function (r) {
    S.props = r.ok ? splitLines(r.text).map(function (line) {
      var f = line.split('\t');
      return { name: f[0] || '', cur: f[1] || '', want: f[2] || '', st: f[3] || 'missing' };
    }) : [];
  }, function () { S.props = []; });
}
export function loadIcons(pkgs) {
  if (!pkgs.length || (S.contract.checked && !hasCmd('icons'))) return Promise.resolve();
  return call('icons', pkgs.join(',')).then(function (r) {
    if (!r.ok) return;
    splitLines(r.text).forEach(function (line) {
      var f = line.split('\t');
      if (f.length >= 3 && f[0]) S.icons[f[0]] = { label: f[1] || '', src: f[2] };
    });
  }, function () {});
}
export function loadExcluded() {
  if (S.contract.checked && !hasCmd('excluded')) { S.excluded = []; return Promise.resolve(); }
  return call('excluded').then(function (r) { S.excluded = r.ok ? splitLines(r.text) : []; },
    function () { S.excluded = []; });
}

export function loadOverrides() {
  if (S.contract.checked && !hasCmd('teesim-overrides')) { S.overrides = []; return Promise.resolve(); }
  return call('teesim-overrides').then(function (r) {
    S.overrides = r.ok ? splitLines(r.text).map(function (line) {
      var f = line.split('\t');
      return { field: f[0] || '', value: f[1] || '-', editable: f[2] === '1', source: f[3] || 'unset' };
    }) : [];
  }, function () { S.overrides = []; });
}

export function ensure(what) {
  if (S.loaded[what]) return Promise.resolve(false);
  if (inflight[what]) return inflight[what];
  var fn = {
    base: loadBase, lists: loadLists, log: loadLog, backend: loadBackend,
    props: function () { return Promise.all([loadProps(), call('boot-hash').then(function (r) {
      S.boot = r.ok ? parseKV(r.text) : null;
    }, function () { S.boot = null; })]); },
    excluded: loadExcluded,
    teesim: function () { return Promise.all([loadBackend(), loadTeesimProfiles(), loadOverrides()]); },
    tricky: function () { return Promise.all([loadBackend(), loadTeeStatus(), loadTrickyPatches()]); },
    omk: loadBackend,
  }[what];
  if (!fn) return Promise.resolve(false);
  inflight[what] = fn().then(function () { S.loaded[what] = true; inflight[what] = null; return true; },
    function (e) { inflight[what] = null; throw e; });
  return inflight[what];
}

/* ── 演示数据：让台架在没有 root 的桌面 Chrome 上也能跑完全部路径 ─────── */
/* 键名与真机 `webui.sh status|env|backend-info` 的实际输出对齐（2026-10-29 从
   QV7709NLJ7 上抓的），不再凭想象编 —— 上一版这里编的键和 KV_REQUIRED 编的键
   互相自证一致，两边一起错，台架全绿而真机会停写。
   语料也带上三家后端各自才有的形状（profiles 表、tee_status、按包补丁块），
   否则那几条分支等于没测过。 */
/* 路径取自 module/lib/core.sh:7-17 与 backend.sh:59-72，显示名取自 backend_name()，
   不在这里另编一套 —— 台架用的路径一旦是想象的，它就再也证不了任何东西。 */
function demoFiles() {
  var o = {
    omk: { backend: 'omk', name: 'OhMyKeymint', mod: '/data/adb/modules/oh_my_keymint',
      dir: '/data/misc/keystore/omk', target: 'injector.toml', kb: 'keybox.xml', ver: '1.2.0-a1f3241' },
    tricky: { backend: 'tricky', name: 'Tricky Store', mod: '/data/adb/modules/tricky_store',
      dir: '/data/adb/tricky_store', target: 'target.txt', kb: 'keybox.xml', ver: '1.4.1' },
    teesim: { backend: 'teesim', name: 'TEE Simulator', mod: '/data/adb/modules/teesim',
      dir: '/data/adb/teesim', target: 'config.json', kb: 'keybox.xml', ver: '4.5.0' },
  };
  return o[DEMO_BACKEND] || o.omk;
}

function demoResult(cmd, arg) {
  var T = '\t';
  if (DEMO_FAIL && cmd === DEMO_FAIL) {
    return { errno: 1, stdout: '', stderr: '目标文件不存在：' + demoFiles().dir + '/' + demoFiles().target };
  }
  /* 三家各有一套路径与条目语法。台架默认 omk，切 ?backend=tricky 才会画到
     tee_status、按包补丁块和 ?/! 后缀那一套分支 —— 上一版只跑 omk，
     结果 Tricky 分支里的键名读错也没人看见。 */
  var B = demoFiles();
  var toks = {
    omk: ['com.android.vending', 'app.mihon', 'com.tencent.mm'],
    tricky: ['com.android.vending', 'app.mihon?', 'com.tencent.mm!'],
    teesim: ['com.android.vending', 'com.google.android.gms@11', 'uid:10123'],
  }[B.backend] || [];
  var meta = toks.map(function (tok) {
    var b = tok, kind = 'plain', detail = '', m;
    if (B.backend === 'tricky') {
      if (/[?!]$/.test(tok)) { kind = tok.charAt(tok.length - 1) === '?' ? 'leaf' : 'generate'; b = tok.slice(0, -1); }
      else kind = 'auto';
    } else if (B.backend === 'teesim') {
      if (/^uid:/.test(tok)) { kind = 'uid'; b = ''; detail = tok.slice(4); }
      else if ((m = tok.match(/^(.*)@(\d+)$/))) { kind = 'user'; b = m[1]; detail = m[2]; }
    }
    return tok + T + b + T + kind + T + detail;
  });
  var bi = ['backend=' + B.backend, 'backend_name=' + B.name, 'module_dir=' + B.mod,
    'module_version=' + B.ver, 'target_file=' + B.dir + '/' + B.target, 'target_entries=' + toks.length,
    'keybox_file=' + B.dir + '/' + B.kb, 'keybox_exists=1', 'keybox_bytes=5573',
    'keybox_hash_algo=sha256',
    /* 真机原值（QV7709NLJ7，2026-10-30 现量）：这台上的 keybox 就是 OMK 自带模板，
       与 tests/fixtures/keybox-omk-template.xml 同一份字节。截半的哈希是最像真话的假数据。 */
    'keybox_hash=4166677843448ea03fa5983c9cba554318c06bbaac8bd075ee18f6cedfba2dfa'];
  if (B.backend === 'omk') bi = bi.concat(['injector_version=1', 'injector_main_enabled=true',
    'injector_log_level=debug', 'filter_enabled=true', 'filter_block_android=true', 'filter_allow_unknown=false',
    /* 真机现值（2026-10-30 现读）。注意 cfg_retire_stale_keys **故意不写**：
       那台 config.toml 里本来就没有这一行（上游默认 true），命令层如实不输出 ——
       假数据摆出这个"缺键"状态，才能验出界面有没有把"未设置"说成"关"。 */
    'config_log_level=debug', 'cfg_force_skip_biometric=false',
    'trust_os_version=auto', 'trust_security_patch=auto', 'trust_os_patchlevel=auto',
    'trust_vendor_patchlevel=auto', 'trust_boot_patchlevel=auto',
    'trust_vb_key=auto', 'trust_vb_hash=auto', 'trust_verified_boot=true', 'trust_device_locked=true']);
  if (B.backend === 'tricky') bi = bi.concat(['patch_file=' + B.dir + '/security_patch.txt', 'patch_exists=1',
    'patch_lines=4', 'patch_packages=1', 'patch_system=2024-01-05', 'patch_vendor=2024-01-05']);
  var body = {
    contract: 'api=' + EXPECT_API + '\ncommands=status env targets target-meta apps icons log clear-log props props-apply props-on props-off boot-hash props-boot-hash restore-app restore-apps remove-apps set-mode backend-info teesim-save omk-save-injector omk-save-config tricky-save-patch keybox-save sync help contract excluded teesim-profiles tee-status tricky-patches omk-restart teesim-overrides teesim-save-overrides',
    status: ['state=' + (DEMO_CONFLICT ? 'stopped' : 'ok'),
      /* 冲突时模块是真的停：service.sh:30-34 写 ⛔ + KL_CONFLICT_MSG 并 mark_module_stopped，
         所以这里连 description / daemon_alive 一起改，不然台架看到的是"停写但还在跑"这种
         机器上根本不存在的状态。 */
      'description=' + (DEMO_CONFLICT
        ? '⛔ 检测到多个密钥库后端同时启用（Tricky Store / TEE Simulator / OhMyKeymint），模块停止运行（请只保留一个）'
        : '✅ [' + B.name + ' | 应用: ' + toks.length + ' | 更新: 16:52]'),
      'mod_id=keylens', 'mod_version=v2.2.19.5-yuzu', 'backend=' + B.backend, 'backend_name=' + B.name,
      'conflict=' + (DEMO_CONFLICT ? 1 : 0),
      /* 三态与三家：真机现量是 tricky=absent / teesim=absent / oh_my_keymint=active。
         conflict=1 时三家全成 active —— 那是台架唯一能看到互斥横幅的时刻。 */
      'teesim_state=' + (DEMO_CONFLICT || B.backend === 'teesim' ? 'active' : 'absent'),
      'tricky_state=' + (DEMO_CONFLICT || B.backend === 'tricky' ? 'active' : 'absent'),
      'omk_state=' + (DEMO_CONFLICT || B.backend === 'omk' ? 'active' : 'absent'),
      'data_dir=' + B.dir, 'target_file=' + B.dir + '/' + B.target,
      'target_exists=1', 'target_writable=1', 'target_mtime=1793263964',
      'props_masking=on', 'daemon_alive=' + (DEMO_CONFLICT ? 0 : 1), 'log_file=/data/adb/keylens.log',
      'log_lines=492', 'log_bytes=33933'].join('\n'),
    env: ['resetprop=1', 'awk=1', 'base64=1', 'inotify_mode=inotifyd', 'inotify_cmd=inotifyd',
      'root_user=0', 'device=XQ-DQ72', 'brand=Sony', 'android=17', 'sdk=37', 'build_type=user',
      'vbstate=green', 'sys_dark=1', 'sys_dark_src=mComputedNightMode', 'sys_statusbar_dp=28',
      /* seed=…（?demo=1 专用）：台架的种子注入路 —— 不带它就是"系统没有可读强调色"，
         走平台默认那条兜底；带它走 parseSeed + 映射，verify 用它验端到端。 */
      'sys_seed_raw=' + (QUERY.get('seed') || ''), 'sys_seed_src=' + (QUERY.get('seed') ? 'theme_custom_color' : 'none')].join('\n'),
    targets: toks.join('\n'),
    apps: ['com.android.vending', 'app.mihon', 'com.tencent.mm', 'io.legado.app'].join('\n'),
    'target-meta': meta.join('\n'),
    log: ['10-29 16:52:43 🔄 开始应用列表同步', '10-29 16:52:44 ✅ 同步完成，应用总数：128',
      '10-29 19:30:50 ℹ️ 源数据与上次一致（指纹 905773947），跳过同步',
      '10-26 17:38:02 ⚠️ 未找到 awk，暂时无法维护 TEE Simulator 配置',
      '10-26 17:55:20 ❌ 写入失败：/data/adb/teesim/config.json 不可替换'].join('\n'),
    'backend-info': bi.join('\n'),
    /* props 是 TSV「名字<TAB>当前<TAB>期望<TAB>状态」，没有键 —— 台架必须用
       真形状，否则解析分支等于没测。 */
    props: ['ro.product.brand' + T + 'Sony' + T + 'Sony' + T + 'ok',
      'ro.product.model' + T + 'XQ-DQ72' + T + 'XQ-DQ72' + T + 'ok',
      'ro.build.fingerprint' + T + 'Sony/XQ-DQ72/XQ-DQ72:17' + T + 'Sony/XQ-DQ72/XQ-DQ72:16' + T + 'diff',
      'ro.boot.verifiedbootstate' + T + 'green' + T + 'green' + T + 'ok',
      'ro.serialno' + T + '' + T + 'FAKE0000' + T + 'missing'].join('\n'),
    'boot-hash': 'configured=\ncurrent=9f2c4d8e7a1b3c5d\nstatus=unset',
    excluded: 'io.legado.app',
    'teesim-profiles': ['default' + T + 'keybox.xml' + T + 'patch' + T + '10' + T + '1',
      'alt' + T + 'test.xml' + T + 'generation' + T + '3' + T + '0'].join('\n'),
    'tee-status': ['present=1', 'file=/data/adb/tricky_store/tee_status', 'status=UNAVAILABLE',
      'category=keystore2_unavailable', 'service_error_code=none', 'tee_broken=unknown'].join('\n'),
    /* 一份"纯软件兜底设备"的 overrides 汇总。source 只有三种取值
       （OverrideSource 枚举：required / supplement / synthesized，没有 original），
       且 **source=required 而 editable=1 是真实存在的组合**：启动键/哈希在设备上报
       全零时是兜底值，此时可改（Harvester.kt:86-102,175-189）。
       假数据把这种组合摆出来，才能验出界面有没有拿 source 反推可编辑性。 */
    'teesim-overrides': [
      'attestationSecurityLevel' + T + '1' + T + '1' + T + 'synthesized',
      'keymasterSecurityLevel' + T + '1' + T + '1' + T + 'synthesized',
      'attestationVersion' + T + '300' + T + '1' + T + 'synthesized',
      'keymasterVersion' + T + '300' + T + '1' + T + 'synthesized',
      'verifiedBootKey' + T + '4166677843448ea03fa5983c9cba554318c06bbaac8bd075ee18f6cedfba2dfa' + T + '1' + T + 'required',
      'verifiedBootHash' + T + '9f2c4d8e7a1b3c5d9f2c4d8e7a1b3c5d9f2c4d8e7a1b3c5d9f2c4d8e7a1b3c5d' + T + '1' + T + 'required',
      'deviceLocked' + T + 'true' + T + '0' + T + 'required',
      'verifiedBootState' + T + '0' + T + '0' + T + 'required',
      'moduleHash' + T + '0b6e' + T + '0' + T + 'required',
      'serial' + T + 'FAKE0000' + T + '0' + T + 'supplement'].join('\n'),
    'teesim-save-overrides': ['saved=1', 'fields=2',
      'apply_note=已写入，TEESim 监听该文件自行热生效，不需要重启'].join('\n'),
    'tricky-patches': ['global' + T + 'today' + T + 'YYYY-MM-05' + T + 'YYYY-MM-05',
      'com.android.vending' + T + '2024-01-05' + T + '-' + T + '-'].join('\n'),
    'omk-restart': 'restarted=' + (arg || 'all') + '\ntrigger=/data/adb/omk/restart.' + (arg || 'all'),
    icons: ['app.mihon' + T + 'Mihon' + T + 'icons/app.mihon.png',
      'com.android.vending' + T + 'Google Play 商店' + T + 'icons/com.android.vending.png'].join('\n'),
  }[cmd];
  return body === undefined
    ? { errno: 1, stdout: '', stderr: '未知命令：' + cmd }
    : { errno: 0, stdout: body, stderr: '' };
}

export function attachBridge(hit) {
  BRIDGE = hit.obj;
  S.bridge = { kind: hit.kind, label: hit.label, seen: hit.seen };
  /* 边到边 + 藏掉管理器自己的标题栏：安全区由 /internal/insets.css 给 */
  try { if (BRIDGE && typeof BRIDGE.hideTitle === 'function') BRIDGE.hideTitle(); } catch (e) {}
  try { if (BRIDGE && typeof BRIDGE.enableEdgeToEdge === 'function') BRIDGE.enableEdgeToEdge(true); } catch (e) {}
}
export function bridgeOf() { return BRIDGE; }
