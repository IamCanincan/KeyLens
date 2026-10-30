#!/usr/bin/env node
/* 真机回放台架 —— 补上 verify.mjs 天生看不见的那一整类 bug。
 *
 * 为什么需要它：verify.mjs 走 ?demo=1，`run()` 在 DEMO 分支直接返回假数据，
 * **根本不经过 window.ksu.exec**。于是"桥接调用形状写错"这类故障 —— 手机上表现为
 * 只剩框架、内容永远不出来 —— 台架全绿。2026-10-30 就是这么撞上的：
 * KernelSU 主线的 exec 第三个参数要的是**回调函数名（字符串）**，我传了函数对象。
 *
 * 这个台架做三件 verify.mjs 做不到的事：
 *   ① 数据从**真机现读**（只读命令，一条写命令都不碰）；
 *   ② 桥接按**该管理器真实的形状**注入（函数名回调 + 异步），不是理想形状；
 *   ③ 断言的是渲染结果：桥接认出来了、内容有画出来、没有超时、没有未捕获异常。
 *
 * 跑法：node tools/replay-check.mjs        （要连着 adb 和 Chrome）
 * 产物：截图写到系统临时目录的 ksu-replay/，**不落仓库**（真机数据含设备标识）。
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import { spawn, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '..');
const CHROME = process.env.CHROME || 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
const PORT = Number(process.env.PORT || 9253);
// 改名过渡期：已装着的机器还在旧目录下，用 MODDIR 指过去；默认是新名。
const SH_PATH = (process.env.MODDIR || '/data/adb/modules/keylens') + '/webui.sh';
const OUT = path.join(os.tmpdir(), 'ksu-replay');
fs.mkdirSync(OUT, { recursive: true });

/* 只读命令。写命令一律不进来 —— 上一轮我拿扫描跑过 props-apply/props-on/props-off，
   在用户手机上真动了手，这条清单就是用来不再犯第二次的。 */
const READ = ['contract', 'status', 'env', 'backend-info', 'targets', 'target-meta', 'apps',
  'excluded', 'props', 'boot-hash', 'tee-status', 'tricky-patches', 'teesim-profiles',
  'teesim-overrides', 'log'];

function adb(...args) {
  return execFileSync('adb', args, { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
}
function cap(cmd, arg) {
  const a = ['exec-out', 'sh', SH_PATH, cmd];
  if (arg) a.push(arg);
  try { return { errno: 0, stdout: adb(...a).replace(/\r/g, ''), stderr: '' }; }
  catch (e) {
    const s = (b) => b ? (Buffer.isBuffer(b) ? b.toString('utf8') : String(b)) : '';
    return { errno: (e.status === undefined ? 1 : e.status), stdout: s(e.stdout), stderr: s(e.stderr) };
  }
}

console.log('── 从真机现读 ──');
let serial = '';
try { serial = adb('get-serialno').trim(); } catch (e) { console.error('✗ adb 不可用：' + e.message); process.exit(1); }
if (!serial || serial === 'unknown') { console.error('✗ 没有连上的设备'); process.exit(1); }
const store = {};
for (const c of READ) store[c] = cap(c, c === 'log' ? '300' : '');
/* icons 要包名参数：拿 targets 的头几个真包名去要，形状才是屏幕上会看到的形状 */
const pkgs = (store.targets.stdout || '').split('\n').map(s => s.trim()).filter(Boolean).slice(0, 12);
store.icons = pkgs.length ? cap('icons', pkgs.join(',')) : { errno: 0, stdout: '', stderr: '' };
const okN = Object.values(store).filter(r => r.errno === 0).length;
console.log(`  ${serial}：${Object.keys(store).length} 条命令现读完成，${okN} 条退 0`
  + `（读命令失败的那几条本来就该失败，比如后端不是 TEESim）`);
for (const [k, r] of Object.entries(store)) {
  if (r.errno !== 0) console.log(`     · ${k} 退 ${r.errno}: ${(r.stderr || r.stdout).split('\n')[0].slice(0, 52)}`);
}

/* 采集自检：先证明"读回来的确实是真数据"，再去驱动界面。
   第一版没有这一段：Git Bash 把 /data/adb/... 改写成了 D:/Git/data/adb/...，
   于是每条命令都返回错误文本，而断言拿那句错误当"真包名"去匹配 —— 全绿。
   一台会替错误编造成功判据的仪器，比没有仪器更坏。 */
console.log('── 采集自检 ──');
const problems = [];
const needKV = (cmd, keys) => {
  const t = store[cmd].stdout || '';
  for (const k of keys) if (!new RegExp('^' + k + '=', 'm').test(t)) problems.push(`${cmd} 的输出里没有 ${k}=`);
};
if (store.contract.errno !== 0) problems.push('contract 读失败');
needKV('contract', ['api', 'commands']);
needKV('status', ['state', 'backend', 'daemon_alive']);
needKV('env', ['resetprop', 'root_user']);
needKV('backend-info', ['backend', 'target_file']);
needKV('boot-hash', ['status']);
const apiVal = (store.contract.stdout.match(/^api=(\S+)/m) || [])[1];
if (apiVal !== '4') problems.push(`契约号不是 4，是 ${apiVal}（设备上跑的是旧版命令层？）`);
const tgt = (store.targets.stdout || '').split('\n').map(s => s.trim()).filter(Boolean);
const badTgt = tgt.filter(s => !/^[A-Za-z0-9_.:@!?-]+$/.test(s));
if (badTgt.length) problems.push(`targets 里有不像条目的行：${JSON.stringify(badTgt[0].slice(0, 60))}`);
if (/\bNo such file\b|adb:|command not found|Permission denied/.test(Object.values(store).map(r => r.stdout + r.stderr).join(' ')))
  problems.push('采集里混进了 shell 报错（路径被 MSYS 改写？adb 掉线？没 root？）');
if (problems.length) {
  problems.forEach(p => console.log('✗   ' + p));
  console.log('✗ 采集不像真数据，停在这里 —— 不去驱动界面');
  process.exit(1);
}
console.log(`  ok   ${Object.keys(store).length} 条都读到了该有的键，targets ${tgt.length} 条形状正常`);

console.log('── 驱动界面 ──');

/* 注入的假桥接：**照 KernelSU 主线的形状** —— exec(cmd, optionsJson, 回调函数名)。
   形状不对的时候必须**像真机那样静默不回调**：真管理器拿到一个函数对象不会抛错，
   它只是找不到那个全局名，于是永远不回来。第一版这里写成 throw，等于把"卡死"
   伪装成"快速失败"，界面照样画出东西、台架照样全绿 —— 假台架比没台架更坏。 */
const shim = `(function(){
  var STORE = ${JSON.stringify(store)};
  var log = [];
  function norm(s){ return String(s == null ? '' : s).replace(/\\r/g, ''); }
  window.ksu = {
    exec: function (cmd, opts, cb) {
      log.push('exec ' + norm(cmd));
      var r = null, key = '';
      if (typeof cb === 'string') {
        var m = /webui\\.sh ([a-z-]+)(?: '(.*)')?$/.exec(norm(cmd));
        key = m ? m[1] : '';
        r = STORE[key];
      }
      if (!r) { log.push('丢给真机也会静默不回调：cb 类型=' + typeof cb + ' key=' + key); return undefined; }
      /* 真机是异步回调：同步调用 window[cb] 会绕过所有"没回来怎么办"的路径 */
      setTimeout(function () {
        var fn = window[cb];
        if (typeof fn === 'function') fn(r.errno | 0, norm(r.stdout), norm(r.stderr));
      }, 5 + Math.random() * 60);
      return undefined;
    },
    hideTitle: function () {}, enableEdgeToEdge: function () {},
    toast: function () {}, showToast: function () {},
    rootShell: function () {}, getRootShell: function () { return 'sh'; }
  };
  window.__replayLog = log;
})();`;

function waitPort(p, tries) {
  return new Promise(res => {
    let n = 0;
    (function tick() {
      const s = net.connect(p, '127.0.0.1');
      s.on('connect', () => { s.destroy(); res(true); });
      s.on('error', () => { if (++n < (tries || 40)) setTimeout(tick, 250); else res(false); });
    })();
  });
}
/* Node 没有 XMLHttpRequest，调试端口列表用 http.get 取 */
const http = await import('node:http');
const jsonList = () => new Promise((res, rej) => {
  http.get({ host: '127.0.0.1', port: PORT, path: '/json/list' }, r => {
    let b = ''; r.on('data', d => b += d); r.on('end', () => { try { res(JSON.parse(b)); } catch (e) { rej(e); } });
  }).on('error', rej);
});

class Ws {
  constructor(url) {
    this.url = url; this.id = 0; this.pend = new Map(); this.handlers = new Map();
    this.open = new Promise((res, rej) => {
      this.sock = new WebSocket(url);
      this.sock.onopen = res; this.sock.onerror = rej;
      this.sock.onmessage = (ev) => {
        const m = JSON.parse(ev.data);
        if (m.id && this.pend.has(m.id)) {
          const q = this.pend.get(m.id); this.pend.delete(m.id);
          m.error ? q.rej(new Error(JSON.stringify(m.error))) : q.res(m.result);
        } else if (m.method && this.handlers.has(m.method)) {
          this.handlers.get(m.method)(m.params);
        } else if (m.method === 'Runtime.exceptionThrown') {
          (this.errs = this.errs || []).push(JSON.stringify(m.params.exceptionDetails).slice(0, 300));
        }
      };
    });
  }
  send(method, params) {
    return new Promise((res, rej) => { const n = ++this.id; this.pend.set(n, { res, rej }); this.sock.send(JSON.stringify({ id: n, method, params: params || {} })); });
  }
  on(method, fn) { this.handlers.set(method, fn); }
}
const sleep = ms => new Promise(r => setTimeout(r, ms));

const FILE = process.argv[2] ? path.resolve(repo, process.argv[2]) : path.join(repo, 'module', 'webroot', 'index.html');
const URL0 = 'file:///' + FILE.replace(/\\/g, '/');

async function main() {
  if (!fs.existsSync(FILE)) { console.error('✗ 找不到 ' + FILE); process.exit(1); }
  const chrome = spawn(CHROME, ['--headless=new', '--disable-gpu', '--no-sandbox',
    '--remote-debugging-port=' + PORT, '--window-size=800,1000', 'about:blank'], { stdio: 'ignore' });
  if (!await waitPort(PORT)) { chrome.kill(); console.error('✗ Chrome 调试端口没起来'); process.exit(1); }
  const list = await jsonList();
  const t = list.find(x => x.type === 'page' && x.webSocketDebuggerUrl);
  const ws = new Ws(t.webSocketDebuggerUrl);
  await ws.open;
  await ws.send('Runtime.enable');
  await ws.send('Page.enable');
  await ws.send('Page.addScriptToEvaluateOnNewDocument', { source: shim });
  await ws.send('Emulation.setDeviceMetricsOverride', { width: 417, height: 975, deviceScaleFactor: 1, mobile: true });

  let bad = 0;
  const chk = (name, ok, detail) => { if (!ok) bad++; console.log(`${ok ? 'ok  ' : '✗   '} ${name}${detail ? '  — ' + detail : ''}`); };

  await ws.send('Page.navigate', { url: URL0 });
  /* 冷启动：从 navigate 到落地页（现在是主页）真长出三张卡 —— 用户打开 WebUI 等的就是这一段。
     判据不用"文本长度 > 200"那种一刀切：md-list-item 的标题/supporting 都写在**属性**里，
     textContent 数不到，四格重排后落地页换了，那条阈值就成了碰运气。 */
  const tNav = Date.now();
  let coldMs = -1;
  for (let i = 0; i < 100; i++) {
    await sleep(100);
    const r = await ws.send('Runtime.evaluate', {
      expression: `(function(){ var v=document.getElementById('view'); if(!v) return 0;
        var c=v.querySelectorAll('md-card').length, t=(v.textContent||'').length;
        return (c >= 2 && t > 40) ? 1 : 0; })()`,
      returnByValue: true,
    });
    if (r.result.value === 1) { coldMs = Date.now() - tNav; break; }
  }
  chk('冷启动能看到内容（<3s）', coldMs > 0 && coldMs < 3000, coldMs > 0 ? coldMs + 'ms' : '10 秒内没出内容');
  await sleep(2500);   // 让分批挂载与图标补齐

  const PROBE = `(function(){
    var vw = Math.round(document.documentElement.clientWidth);
    var txt = (document.getElementById('view')||{}).textContent || '';
    document.querySelectorAll('#view md-list-item').forEach(function(n){
      txt += '|' + (n.getAttribute('headline')||'') + (n.getAttribute('supporting-text')||'') + (n.getAttribute('trailing-text')||'');
    });
    var self = '';
    document.querySelectorAll('#view md-list-item').forEach(function(n){
      if ((n.getAttribute('headline')||'') === '桥接') self = (n.getAttribute('trailing-text')||'') + '|' + (n.getAttribute('supporting-text')||'');
    });
    return { vw: vw, scrollW: document.documentElement.scrollWidth,
      items: document.querySelectorAll('#view md-list-item').length,
      cards: document.querySelectorAll('#view md-card').length,
      text: txt, self: self, calls: (window.__replayLog||[]).length };
  })()`;
  const ev = async e => { const r = await ws.send('Runtime.evaluate', { expression: e, returnByValue: true, awaitPromise: true }); return r.result.value; };

  const realTargets = (store['targets'].stdout || '').split('\n').map(s => s.trim()).filter(Boolean);
  const wantItems = Math.min(realTargets.length, 60);
  const firstPkg = realTargets[0] || '';
  const firstLog = (store['log'].stdout || '').split('\n').filter(Boolean).pop() || '';
  /* 主页钉的是 backend-info 报的真条数：`生效 N 条` 只有真读到 target_entries 才会出现 */
  const entries = (store['backend-info'].stdout.match(/^target_entries=(\S*)/m) || [])[1] || '';
  const headline = () => ev(`(function(){var b=document.getElementById('bar');
    return b&&b.shadowRoot&&b.shadowRoot.querySelector('.headline-line')?(b.shadowRoot.querySelector('.headline-line').textContent||'').trim():''})()`);
  const goto = i => ev(`(function(){ var n=document.getElementById('nav');
    n.dispatchEvent(new CustomEvent('change',{detail:{index:${i}},bubbles:true})); return 1; })()`);

  /* 落地页现在是主页（四格：主页/后端/日志/设置）。
     名单那批断言挪到【后端】那一格去量，自检那行挪到【设置】那一格去读 ——
     它们都不在落地页上了，拿落地页的探针去找等于自证失败。 */
  const p = await ev(PROBE);
  chk('打开落在主页', (await headline()) === '主页', '顶栏=' + (await headline()));
  chk('视口钉在 417', p.vw === 417, 'vw=' + p.vw);
  chk('真的把命令发出去了', p.calls >= 6, 'exec 调用 ' + p.calls + ' 次');
  chk('主页画出状态条与三家矩阵', p.cards >= 2 && p.items >= 3, 'cards=' + p.cards + ' items=' + p.items);
  chk('主页画的是真数（生效 ' + entries + ' 条）', !entries || (p.text || '').indexOf('生效 ' + entries + ' 条') >= 0,
    entries ? '找「生效 ' + entries + ' 条」' : 'backend-info 没给 target_entries');
  chk('没有"命令超时"', (p.text || '').indexOf('超时') < 0, '');
  chk('没有"桥接未就绪"', (p.text || '').indexOf('桥接未就绪') < 0, '');
  chk('主页没有"读不到"', (p.text || '').indexOf('读不到') < 0, '');
  chk('横向不溢出', p.scrollW - p.vw <= 0, '溢出 ' + (p.scrollW - p.vw) + 'px');
  chk('无未捕获异常', !(ws.errs || []).length, (ws.errs || []).slice(0, 2).join(' | '));

  /* 界面自检从落地页搬进【设置】之后，"桥接被认成什么"只能在设置格读 */
  await goto(3); await sleep(900);
  const ps = await ev(PROBE);
  chk('桥接被认成 ksu（不是"未找到"）', /ksu/i.test(ps.self || ''), ps.self || '自检行没读到');
  {
    const s3 = await ws.send('Page.captureScreenshot', { format: 'png' });
    fs.writeFileSync(path.join(OUT, 'replay-settings.png'), Buffer.from(s3.data, 'base64'));
  }

  await goto(1); await sleep(1500);
  const pb = await ev(PROBE);
  /* 判据要钉在**真数据**上，不是"画了点什么"：
     名单里有多少条真条目，屏上就该有多少行 —— 桥接卡住时界面仍会画出自检卡那几行，
     只看 cards/items 下限抓不到（第一次就是这么假绿的）。 */
  chk('真机名单画到屏上（不是只有框架）', pb.items >= wantItems,
    '列表项 ' + pb.items + '，真机名单 ' + realTargets.length + ' 条（门槛 ' + wantItems + '）');
  chk('画的是真包名，不是占位', !firstPkg || (pb.text || '').indexOf(firstPkg) >= 0, firstPkg);

  /* 逐格点一遍：每格都要有**那一格该出现的真东西** */
  const PAGE_MARK = ['主页', '后端', '日志', '设置'];
  for (let i = 0; i < PAGE_MARK.length; i++) {
    await goto(i);
    await sleep(2600);
    const q = await ev(PROBE);
    const t2 = await headline();
    /* 每格钉一个"只有真数据才会出现"的东西：
       主页 = backend-info 的真条数；后端 = 真机第一条包名；
       日志会剥 emoji，所以取时间戳前缀而不是整行；设置 = 真机属性名前缀 ro. */
    const needle = i === 0 ? (entries ? '生效 ' + entries + ' 条' : '')
      : i === 1 ? firstPkg : i === 2 ? firstLog.slice(0, 15).trim() : 'ro.';
    const hasNeedle = needle ? (q.text || '').indexOf(needle) >= 0 : true;
    const titleOk = t2 === PAGE_MARK[i];
    chk('第 ' + i + ' 格是「' + PAGE_MARK[i] + '」且有真数据', hasNeedle && titleOk && (q.text || '').length > 40,
      '标题=' + t2 + ' 列表项=' + q.items + ' 找「' + needle + '」' + (hasNeedle ? '✓'
        : '✗ 屏上末尾是：' + JSON.stringify((q.text || '').slice(-90))));
    if (!hasNeedle || !titleOk) bad++;
  }

  /* 切页手感：数据已缓存时"二次进入"要多久（含同步渲染与组件布局）。
     后端格仍是全场最重的一页（真机名单上百条），主页则是打开就看到的那一屏 ——
     两页都要有数，四格重排之后"落地页变轻了"这件事得能被量出来。 */
  const measure = i => ev(`(function(){ return new Promise(function(res){
    var n=document.getElementById('nav'), t0=performance.now();
    n.dispatchEvent(new CustomEvent('change',{detail:{index:${i},bubbles:true}}));
    var sync=performance.now()-t0;
    var first=-1;
    requestAnimationFrame(function(){ first=Math.round(performance.now()-t0);
      requestAnimationFrame(function(){
      res({ ms: Math.round(performance.now()-t0), firstMs: first, syncMs: Math.round(sync),
            nodes: document.querySelectorAll('#view *').length });
    });});
  }); })()`);
  for (const [i, label, away] of [[0, '主页', 1], [1, '后端', 0], [3, '设置', 0]]) {
    await goto(away);
    await sleep(150);
    const mt = await measure(i);
    console.log(`     二次进入${label}：首帧 ${mt.firstMs}ms · 稳定 ${mt.ms}ms（同步 ${mt.syncMs}ms）/ ${mt.nodes} 节点`);
    if (mt.ms > 600) { bad++; console.log('✗    二次进入超过 600ms —— 真机上会更慢'); }
  }

  /* 图标：旧版靠 webroot/icons/*.png，新版用 <img> 指同一批文件。加载失败就是
     一个个空白块 —— 只看"有没有 img 元素"不算验过，必须看 naturalWidth。
     名单现在在【后端】那一格（index 1），探针要跟着搬。 */
  await goto(1);
  await sleep(2500);
  const ic = await ev(`(function(){
    var imgs = [].slice.call(document.querySelectorAll('#view img.app-ic'));
    var ok = imgs.filter(function (i) { return i.naturalWidth > 0; }).length;
    return { total: imgs.length, ok: ok,
      sample: imgs.slice(0, 3).map(function (i) { return i.getAttribute('src') + '=' + i.naturalWidth; }) };
  })()`);
  /* 本地只有几张贴图（webroot/icons/ 是运行时产物、已 gitignore），所以判据分两截：
     ① 每个包都建出了 <img> 且 src 是 icons/<包名>.png —— 这一条永远可判；
     ② 本地真有那张图时，像素必须 > 0（证明路径解析对）。缺图不假装通过，报出来。 */
  const iconsDir = path.join(repo, 'module', 'webroot', 'icons');
  const local = fs.existsSync(iconsDir) ? fs.readdirSync(iconsDir) : [];
  chk('名单里的应用都建出了 <img>（src 指向 icons/<包名>.png）',
    ic.total > 0, `${ic.total} 个 img · ${ic.sample.join(' ')}`);
  chk('本地有贴图的图标真的渲染出了像素', ic.ok > 0 || local.length === 0,
    `本地贴图 ${local.length} 张 · 有像素的 img ${ic.ok}/${ic.total}`);
  {
    const s0 = await ws.send('Page.captureScreenshot', { format: 'png' });
    fs.writeFileSync(path.join(OUT, 'replay-list.png'), Buffer.from(s0.data, 'base64'));
  }

  /* 分批挂载的两个风险，都要有断言：
     ① 打到一半切走 —— 不许往已经卸掉的列表里继续 append，也不许抛异常；
     ② 不打断时最后必须补齐到全部条目（不能悄悄停在 40 条）。 */
  await goto(1);
  await sleep(40);
  await goto(3);
  await sleep(900);
  const afterCut = await ev(`document.getElementById('view').textContent.length`);
  chk('分批加载被打断后不炸（切到设置格仍有内容）', typeof afterCut === 'number' && afterCut > 20, '文本长度 ' + afterCut);
  await goto(1);
  await sleep(2500);
  const done = await ev(`(function(){ return {
    items: document.querySelectorAll('#view md-list-item').length,
    hint: (document.getElementById('view').textContent.match(/共 \\d+ 条[^|]*/) || [''])[0] }; })()`);
  chk('分批加载最终补齐到全部条目', done.items >= Math.min(realTargets.length, 200), done.hint);

  /* 日志页 300 行：用户在日志页能点的最大档，也是这页最重的形态。
     量"切走再切回"的时间——数据已在 S.log 里，量到的是渲染本身。 */
  await goto(2);
  await sleep(900);
  const picked300 = await ev(`(function(){
    var bs = [].slice.call(document.querySelectorAll('#view md-button'));
    var b = bs.filter(function(x){ return (x.textContent||'').trim().indexOf('300') >= 0; })[0];
    if (b) { b.click(); return 1; } return 0; })()`);
  await sleep(2600);
  await goto(0);
  await sleep(150);
  const logM = await measure(2);
  const logLines = await ev(`document.querySelectorAll('#view .log-line').length`);
  chk('日志页 300 行切回不卡（<400ms）', logM.ms < 400,
    `${logM.ms}ms（同步 ${logM.syncMs}ms）/ ${logM.nodes} 节点 / ${logLines} 行`
    + (picked300 ? '' : '  · 没找到 300 行按钮，量的是当前档'));
  const shot = await ws.send('Page.captureScreenshot', { format: 'png' });
  fs.writeFileSync(path.join(OUT, 'replay.png'), Buffer.from(shot.data, 'base64'));
  console.log('\n截图：' + path.join(OUT, 'replay.png'));
  ws.sock.close(); chrome.kill();
  process.exit(bad ? 1 : 0);
}
main().catch(e => { console.error('✗ ' + e.message); process.exit(1); });
