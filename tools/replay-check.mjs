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
  /* getMetrics 在 enable 之前会返回空表 —— 第一版就是这么拿到"布局 0.0ms"并差点
     把它当成"没有强制重排"的证据。仪器要先自证会出数（下面 perf 那条会断言）。 */
  await ws.send('Performance.enable');
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
      rows: document.querySelectorAll('#view .app-row').length,
      cards: document.querySelectorAll('#view md-card').length,
      text: txt, self: self, calls: (window.__replayLog||[]).length,
      quiet: (window.__replayLog||[]).filter(function (s) { return s.indexOf('exec ') !== 0; }).length,
      quietLines: (window.__replayLog||[]).filter(function (s) { return s.indexOf('exec ') !== 0; }),
      cmds: (window.__replayLog||[]).filter(function(s){return s.indexOf('exec ')===0;})
        .map(function(s){ return s.replace(/^exec .*webui\.sh /,'').split(' ')[0]; }) };
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
  /* 可信点击助手：md-list-item 会吞合成 dispatchEvent/click()（探针实测：
     事件到了 document capture、元素监听器却不响），台架一律用 CDP 的 Input
     派发真实指针事件 —— 这也更接近真手指。二级页进出靠它。 */
  const tapAt = async pos => {
    await ws.send('Input.dispatchMouseEvent', { type: 'mousePressed', x: pos.x, y: pos.y, button: 'left', clickCount: 1 });
    await ws.send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: pos.x, y: pos.y, button: 'left', clickCount: 1 });
  };
  const tapEntry = async kw => {
    const pos = await ev(`(function(){ var its=[].slice.call(document.querySelectorAll('#view md-list-item'));
      var it=its.filter(function(x){return (x.getAttribute('headline')||'').indexOf(${JSON.stringify(kw)})===0;})[0];
      if(!it) return null; var r=it.getBoundingClientRect();
      return { x: Math.round(r.left + r.width/2), y: Math.round(r.top + Math.min(r.height/2, 44)) }; })()`);
    if (!pos) return 0;
    await tapAt(pos); return 1;
  };
  const tapBack = async () => {
    const pos = await ev(`(function(){ var b=document.getElementById('bar');
      var e=b&&b.querySelector('md-icon-button[label="返回功能菜单"]'); if(!e) return null;
      var r=e.getBoundingClientRect(); return { x: Math.round(r.left + r.width/2), y: Math.round(r.top + r.height/2) }; })()`);
    if (!pos) return 0;
    await tapAt(pos); return 1;
  };

  /* 落地页现在是主页（四格：主页/后端/日志/设置）。
     名单那批断言挪到【后端】那一格去量，自检那行挪到【设置】那一格去读 ——
     它们都不在落地页上了，拿落地页的探针去找等于自证失败。 */
  const p = await ev(PROBE);
  chk('打开落在主页', (await headline()) === '主页', '顶栏=' + (await headline()));
  chk('视口钉在 417', p.vw === 417, 'vw=' + p.vw);
  /* 这条判据数的是"哪些命令真被应答过"，不是 exec 的次数：
     次数对不上形状错的调用（每次 exec 会多塞一行报错）反而更高。 */
  const gotCmds = Array.from(new Set(p.cmds || []));
  chk('首屏四类读命令真发出去并回了话',
    ['contract', 'status', 'env', 'backend-info'].every(function (c) { return gotCmds.indexOf(c) >= 0; }),
    gotCmds.join(' / ') + '（exec ' + p.calls + ' 次）');
  chk('主页画出状态条与三家矩阵', p.cards >= 2 && p.items >= 3, 'cards=' + p.cards + ' items=' + p.items);
  {
    const beVer = ((store['backend-info'].stdout || '').match(/^module_version=(.*)$/m) || [])[1] || '';
    chk('主页显示后端版本', !beVer || (p.text || '').indexOf(beVer) >= 0,
      beVer ? '找「' + beVer + '」' : 'backend-info 没给 module_version');
    const tt = await ev(`(function(){ var t=document.querySelector('#view .page-title');
      return t ? { text: (t.textContent||'').trim(), fs: getComputedStyle(t).fontSize } : null; })()`);
    chk('真机页标题在内容里且是 28px', !!tt && tt.text === '主页' && tt.fs === '28px',
      tt ? tt.text + ' / ' + tt.fs : '没读到');
  }
  chk('主页画的是真数（生效名单 ' + entries + ' 条）', !entries || (p.text || '').indexOf(entries + ' 条') >= 0,
    entries ? '找「' + entries + ' 条」' : 'backend-info 没给 target_entries');
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

  /* 功能页 = 一张菜单；长列表要点进「目标名单」二级才画。
     四项是 2026-11-04 重排的结果：自动同步并进了「目标名单」页，备份回滚搬进了「后端配置」，
     体检进了主页那张大卡片 —— 菜单从五项减到四项。这条以前写死 5，UI 一改就自己变红，
     所以判据改成"恰好这四项、且没有第五项"，比数一个数更经得起下一次重排。 */
  await goto(1); await sleep(1500);
  const pf = await ev(PROBE);
  chk('功能页是菜单（四项入口）', pf.items === 4 && /目标名单[\s\S]*后端配置[\s\S]*密钥箱 keybox[\s\S]*属性伪装/.test(pf.text || ''),
    'items=' + pf.items);
  chk('菜单摘要画的是真数（生效 ' + entries + ' 条）', !entries || (pf.text || '').indexOf('生效 ' + entries + ' 条') >= 0,
    '找「生效 ' + entries + ' 条」');
  chk('点「目标名单」进二级', await tapEntry('目标名单') === 1);
  await sleep(2500);
  const pb = await ev(PROBE);
  /* 判据要钉在**真数据**上，不是"画了点什么"：
     名单里有多少条真条目，屏上就该有多少行 —— 桥接卡住时界面仍会画出自检卡那几行，
     只看 cards/items 下限抓不到（第一次就是这么假绿的）。 */
  chk('真机名单画到屏上（不是只有框架）', pb.rows >= wantItems,
    '列表项 ' + pb.rows + '，真机名单 ' + realTargets.length + ' 条（门槛 ' + wantItems + '）');
  chk('画的是真包名，不是占位', !firstPkg || (pb.text || '').indexOf(firstPkg) >= 0, firstPkg);
  {
    const gap = await ev(`(function(){ var tf=document.querySelector('#view md-text-field'),
      l=document.querySelector('#view .app-list'); if(!tf||!l) return null;
      var a=tf.getBoundingClientRect(), b=l.getBoundingClientRect();
      return Math.round(b.top - a.bottom); })()`);
    chk('真机搜索框与名单之间有分组间距', gap != null && gap >= 18,
      gap == null ? '没找到搜索框或名单' : gap + 'px');
  }
  {
    const rowCenter = await ev(`(function(){ var it=document.querySelector('#view .app-row');
      if (!it) return null; var r=it.getBoundingClientRect(), c=it.querySelector('.app-row-text');
      if (!c) return null; var b=c.getBoundingClientRect();
      return { row: Math.round(r.top+r.height/2), text: Math.round(b.top+b.height/2) }; })()`);
    chk('真机行内文字与行中心对齐', !!rowCenter && Math.abs(rowCenter.row - rowCenter.text) <= 2,
      rowCenter ? '行中心 ' + rowCenter.row + ' / 文字中心 ' + rowCenter.text : '没读到');
  }
  chk('二级页顶栏是二级名', (await headline()) === '目标名单', '顶栏=' + (await headline()));
  /* 页首大标题在内容里；滚过 8px 顶栏才出现小标题。
     底栏是悬浮药丸：长页向下滑时下沉缩小消失，向上滑/回顶再回来。 */
  {
    const barState = () => ev(`(function(){ var b=document.getElementById('bar');
      var t=b&&b.shadowRoot&&b.shadowRoot.querySelector('.titles');
      return { c: b.classList.contains('scrolled'), vis: t?getComputedStyle(t).visibility:'', op: t?getComputedStyle(t).opacity:'' }; })()`);
    const navState = () => ev(`(function(){ var n=document.getElementById('nav'); var s=getComputedStyle(n);
      return { hidden:n.classList.contains('nav-hidden'), op:s.opacity, pe:s.pointerEvents }; })()`);
    const pill = await ev(`(function(){ var n=document.getElementById('nav'); var r=n.getBoundingClientRect(); var s=getComputedStyle(n);
      return { pos:s.position, left:Math.round(r.left), right:Math.round(r.right), radius:s.borderRadius,
        vw:Math.round(document.documentElement.clientWidth) }; })()`);
    chk('真机底栏是悬浮药丸（不贴边）',
      pill.pos === 'fixed' && pill.left >= 8 && pill.right <= pill.vw - 8 && pill.radius.indexOf('999px') >= 0,
      'left=' + pill.left + ' right=' + pill.right + ' vw=' + pill.vw + ' radius=' + pill.radius);
    const before = await barState();
    const navBefore = await navState();
    await ev('window.scrollTo(0, 260)');
    await sleep(300);
    const after = await barState();
    const navAfter = await navState();
    chk('滚动后顶栏才出小标题', after.c && after.vis === 'visible' && after.op === '1',
      'before ' + before.vis + '/' + before.op + ' → after ' + after.vis + '/' + after.op);
    chk('长页下滑后底栏收缩消失', navAfter.hidden && navAfter.op === '0' && navAfter.pe === 'none',
      'before hidden=' + navBefore.hidden + ' → after op=' + navAfter.op + ' pe=' + navAfter.pe);
    await ev('window.scrollTo(0, 0)');
    await sleep(250);
    const back = await barState();
    const navBack = await navState();
    chk('回到页首顶栏标题再次让位', !back.c && back.vis === 'hidden' && back.op === '0',
      back.vis + '/' + back.op);
    chk('回到顶部底栏回来', !navBack.hidden && navBack.op === '1',
      'hidden=' + navBack.hidden + ' op=' + navBack.op);
  }

  /* 逐格点一遍：每格都要有**那一格该出现的真东西** */
  const androidVer = (store['env'].stdout.match(/^android=(.*)$/m) || [])[1] || '';
  const PAGE_MARK = ['主页', '功能', '日志', '设置'];
  for (let i = 0; i < PAGE_MARK.length; i++) {
    await goto(i);
    await sleep(2200);
    const q = await ev(PROBE);
    const t2 = await headline();
    /* 每格钉一个"只有真数据才会出现"的东西：
       主页（英雄卡）与功能菜单（摘要）都是 backend-info 的真条数；
       日志会剥 emoji，取时间戳前缀；设置格只剩外观+自检，
       钉的是自检卡里真机的「Android <版本>」。 */
    const needle = i === 2 ? firstLog.slice(0, 15).trim()
      : i === 3 ? ('Android ' + androidVer)
      : (entries ? entries + ' 条' : '');
    const hasNeedle = needle ? (q.text || '').indexOf(needle) >= 0 : true;
    const titleOk = t2 === PAGE_MARK[i];
    chk('第 ' + i + ' 格是「' + PAGE_MARK[i] + '」且有真数据', hasNeedle && titleOk && (q.text || '').length > 40,
      '标题=' + t2 + ' 列表项=' + q.items + ' 找「' + needle + '」' + (hasNeedle ? '✓'
        : '✗ 屏上末尾是：' + JSON.stringify((q.text || '').slice(-90))));
    if (!hasNeedle || !titleOk) bad++;
  }

  /* ── 后端专属卡片：把命令层**真读到**的值钉到界面上 ──────────────────
     此前回放只保证"页面能渲染"，补丁块读成空、profile 表读成空都不响 ——
     `tricky-patches` 没解析后端（KL_PATCH 为空）那个 bug 就是这么漏过去的：
     界面把整块画成"还没有这个段"，台架一路绿。这里按当前后端取第一行真数据，
     找不到就判红。 */
  {
    await goto(1);
    await sleep(600);
    await tapEntry('后端配置');
    await sleep(1500);
    const q = await ev(PROBE);
    const be = ((store['backend-info'].stdout || '').match(/^backend=(.*)$/m) || [])[1] || '';
    if (be === 'tricky') {
      const first = (store['tricky-patches'].stdout || '').split('\n').filter(Boolean)[0] || '';
      const val = (first.split('\t')[1] || '').trim();
      chk('Tricky 补丁块画的是命令层真读到的值', !!val && val !== '-' && (q.text || '').indexOf(val) >= 0,
        val ? '找「' + val + '」（' + first.split('\t')[0] + ' 段）' : '命令层没返回任何补丁段');
      /* tee_status 有两代格式：四行（status=…）与单行（teeBroken=…）。不管哪一代，
         "自动条目现在走"都要算得出一个去向 —— 算不出就是解析少了一支。 */
      const tk = {};
      (store['tee-status'].stdout || '').split('\n').forEach(l => { const i = l.indexOf('='); if (i > 0) tk[l.slice(0, i)] = l.slice(i + 1); });
      if (tk.present === '1') {
        const tb = String(tk.tee_broken || '').toLowerCase();
        const expect = tk.status === 'AVAILABLE' ? '叶证书' : tk.status === 'FAILED' ? '证书生成'
          : tk.status === 'UNAVAILABLE' ? '不匹配'
          : tb === 'false' ? '叶证书' : tb === 'true' ? '证书生成' : '';
        if (expect) {
          chk('Tricky 的 AUTO 去向按 tee_status 算出来了', (q.text || '').indexOf(expect) >= 0,
            'tee_status：' + (tk.status ? 'status=' + tk.status : '旧格式 teeBroken=' + tb) + ' → 找「' + expect + '」');
        } else {
          console.log('     · tee_status 存在但取值无法判定（status=' + (tk.status || '空') + ' teeBroken=' + (tb || '空') + '），AUTO 断言跳过');
        }
      }
    } else if (be === 'teesim') {
      const nm = ((store['teesim-profiles'].stdout || '').split('\n').filter(Boolean)[0] || '').split('\t')[0] || '';
      chk('TEESim profile 表画的是命令层真读到的名字', !!nm && (q.text || '').indexOf(nm) >= 0,
        nm ? '找「' + nm + '」' : '命令层没返回 profile');
    } else if (be === 'omk') {
      const bk = {};
      (store['backend-info'].stdout || '').split('\n').forEach(l => { const i = l.indexOf('='); if (i > 0) bk[l.slice(0, i)] = l.slice(i + 1); });
      if (bk.omk_keymint_alive === undefined) {
        console.log('     · 命令层没有 OMK 运行状态键，跳过（设备上跑的是旧命令层？）');
      } else {
        const tr = q.text || '';
        const alive = bk.omk_keymint_alive === '1' && bk.omk_injector_alive === '1' && bk.omk_keystore_injected === '1';
        const pids = [bk.omk_keymint_daemon, bk.omk_injector_daemon, bk.omk_keystore_pid].filter(Boolean);
        const pidShown = pids.length === 3 && pids.every(x => tr.indexOf(x) >= 0);
        chk('OMK 两个 daemon 与 keystore2 注入按真值画出来',
          alive && pidShown && tr.indexOf('运行状态') >= 0 && tr.indexOf('已注入') >= 0,
          `keymint=${bk.omk_keymint_alive}(pid ${bk.omk_keymint_daemon}) injector=${bk.omk_injector_alive}(pid ${bk.omk_injector_daemon})`
            + ` keystore=${bk.omk_keystore_injected}(pid ${bk.omk_keystore_pid})`);
        chk('OMK 版本与后端模式出现在运行状态卡上',
          !!bk.module_version && tr.indexOf(bk.module_version) >= 0
            && (!bk.omk_backend || tr.indexOf(bk.omk_backend) >= 0),
          'version=' + (bk.module_version || '未上报') + ' mode=' + (bk.omk_backend || '未上报'));
      }
    } else {
      console.log('     · 当前后端是 ' + (be || '未知') + '，跳过后端专属卡片断言');
    }
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
  for (const [i, label, away] of [[0, '主页', 1], [1, '功能', 0], [3, '设置', 0]]) {
    await goto(away);
    await sleep(150);
    const mt = await measure(i);
    console.log(`     二次进入${label}：首帧 ${mt.firstMs}ms · 稳定 ${mt.ms}ms（同步 ${mt.syncMs}ms）/ ${mt.nodes} 节点`);
    if (mt.ms > 600) { bad++; console.log('✗    二次进入超过 600ms —— 真机上会更慢'); }
  }
  {
    /* 名单二级页：预热一遍（数据与图标都在 S 里），退回菜单，再走 hash →
       popstate 进二级量 —— 那也是系统返回键真正走的路。 */
    await goto(1); await sleep(400);
    await tapEntry('目标名单'); await sleep(2200);
    await tapBack(); await sleep(500);
    const mt = await ev(`(function(){ return new Promise(function(res){
      var t0=performance.now(); location.hash='#/func/targets';
      var sync=performance.now()-t0;
      requestAnimationFrame(function(){ requestAnimationFrame(function(){
        res({ ms: Math.round(performance.now()-t0), syncMs: Math.round(sync),
              nodes: document.querySelectorAll('#view *').length }); }); });
    }); })()`);
    console.log(`     二次进入名单二级（popstate 路径）：稳定 ${mt.ms}ms（同步 ${mt.syncMs}ms）/ ${mt.nodes} 节点`);
    if (mt.ms > 600) { bad++; console.log('✗    名单二级超过 600ms —— 真机上会更慢'); }
  }

  /* 图标：旧版靠 webroot/icons/*.png，新版用 <img> 指同一批文件。加载失败就是
     一个个空白块 —— 只看"有没有 img 元素"不算验过，必须看 naturalWidth。
     名单在【功能】→「目标名单」二级页里，先点进去。 */
  await goto(1);
  await sleep(800);
  await tapEntry('目标名单');
  await sleep(2500);
  const ic = await ev(`(function(){
    var imgs = [].slice.call(document.querySelectorAll('#view img.app-ic'));
    var ok = imgs.filter(function (i) { return i.naturalWidth > 0; }).length;
    var rows = document.querySelectorAll('#view .app-row').length;
    var fb = document.querySelectorAll('#view .app-ic-fallback').length;
    var srcs = imgs.map(function (i) { return i.getAttribute('src'); });
    return { total: imgs.length, ok: ok, rows: rows, fb: fb, srcs: srcs,
      sample: imgs.slice(0, 3).map(function (i) { return i.getAttribute('src') + '=' + i.naturalWidth; }) };
  })()`);
  /* 图标是运行时产物（webroot/icons/ 已 gitignore），本地只有当下后端名单里导过的几张。
     所以判据钉的是**行首一定有着落**：每个条目要么是 <img>、要么是首字块 ——
     空白行首才是 bug。像素只在"本地确实有这张图"时要求（缺图会按设计退首字块，
     不能拿它判死）。后端名单换了之后，原来那批 app 可能根本不在列表里。 */
  const iconsDir = path.join(repo, 'module', 'webroot', 'icons');
  const local = fs.existsSync(iconsDir) ? fs.readdirSync(iconsDir) : [];
  const localSet = new Set(local);
  chk('每个条目都有行首（img 或首字块），没有空白行首',
    ic.total + ic.fb >= ic.rows && ic.rows > 0,
    `img ${ic.total} + 首字块 ${ic.fb} / 行 ${ic.rows}`);
  {
    const expected = ic.srcs.filter(s => localSet.has(String(s).replace(/^icons\//, '')));
    chk('本地真有这张贴图时，img 必须渲染出像素',
      expected.length === 0 || ic.ok >= expected.length,
      expected.length
        ? `名单里 ${expected.length} 张本地贴图，有像素的 img ${ic.ok}/${ic.total}`
        : `本地贴图与当前名单没有交集（${local.length} 张本地 · ${ic.total} 个 img），这一项没测到`);
    if (!expected.length) console.log('     · 本地贴图与当前后端名单无交集，像素检查本轮跳过（不是通过）');
  }
  {
    const s0 = await ws.send('Page.captureScreenshot', { format: 'png' });
    fs.writeFileSync(path.join(OUT, 'replay-list.png'), Buffer.from(s0.data, 'base64'));
  }

  /* 轻量行一次画全：点进去 40ms 后行数就应该到全部（不再有分批挂载，
     也没有"已显示 N"）。切走再切回也不允许往回掉。 */
  await tapBack();
  await sleep(300);
  await tapEntry('目标名单');
  await sleep(40);
  const quick = await ev(`(function(){ return {
    rows: document.querySelectorAll('#view .app-row').length,
    hint: (document.getElementById('view').textContent.match(/已显示\\s*\\d+/) || [''])[0] }; })()`);
  chk('名单一次画全（40ms 后已是全部行，没有分批）',
    quick.rows >= Math.min(realTargets.length, 200) && !quick.hint,
    'rows=' + quick.rows + (quick.hint ? ' · ' + quick.hint : ''));
  await goto(3);
  await sleep(700);
  const afterCut = await ev(`document.getElementById('view').textContent.length`);
  chk('名单画全后切走不炸（设置格仍有内容）', typeof afterCut === 'number' && afterCut > 20, '文本长度 ' + afterCut);
  await goto(1);
  await sleep(400);
  await tapEntry('目标名单');
  await sleep(500);
  const done = await ev(`(function(){ return {
    rows: document.querySelectorAll('#view .app-row').length,
    hint: (document.getElementById('view').textContent.match(/共 \\d+ 条[^|]*/) || [''])[0] }; })()`);
  chk('再次进入名单仍一次画全且计数正确',
    done.rows >= Math.min(realTargets.length, 200) && /共 \d+ 条/.test(done.hint), done.hint);

  /* 日志页 300 行：用户在日志页能点的最大档，也是这页最重的形态。
     量"切走再切回"的时间——数据已在 S.log 里，量到的是渲染本身。 */
  await goto(2);
  await sleep(900);
  const picked300 = await ev(`(function(){
    var bs = [].slice.call(document.querySelectorAll('#view md-button, #view md-chip'));
    var b = bs.filter(function(x){ return (x.textContent||'').trim().indexOf('300') >= 0 || (x.getAttribute&&(x.getAttribute('label')||'').indexOf('300') >= 0); })[0];
    if (b) { b.click(); return 1; } return 0; })()`);
  await sleep(2600);
  await goto(0);
  await sleep(150);
  const logM = await measure(2);
  const logLines = await ev(`document.querySelectorAll('#view .log-line').length`);
  chk('日志页 300 行切回不卡（<400ms）', logM.ms < 400,
    `${logM.ms}ms（同步 ${logM.syncMs}ms）/ ${logM.nodes} 节点 / ${logLines} 行`
    + (picked300 ? '' : '  · 没找到 300 行按钮，量的是当前档'));
  /* ── 名单页滚动帧采样（真机 129 行，页高约万像素）───────────────────────
     为什么量这个：滚动处理器每帧要判断"这是不是长页"，写法是读
     document.documentElement.scrollHeight —— 在同一个 rAF 里先改了 class 再读
     布局量，会强制同步重排，页面越高越贵。这条判据就是为它准备的。
     仪器要先自证会动：CDP 触摸甩动如果没让页面真的滚起来，退回脚本滚动，
     并且把"是哪一种产出的数"写进判词。 */
  await goto(1); await sleep(400);
  await tapEntry('目标名单'); await sleep(2200);
  /* 1× CPU 下 p95 就贴着阈值（实测 33.0ms），分不出"每帧强制重排"和抖动 ——
     所以量之前先按 4 倍降速，这也是 verify.mjs 用的同一档。 */
  await ws.send('Emulation.setCPUThrottlingRate', { rate: 4 });
  await sleep(200);
  await ev(`(function(){
    window.__f = []; window.__lt = []; window.__last = performance.now();
    if (window.PerformanceObserver) { try {
      new PerformanceObserver(function (l) { l.getEntries().forEach(function (e) {
        window.__lt.push(Math.round(e.duration)); }); }).observe({ entryTypes: ['longtask'] });
    } catch (e) {} }
    (function tick(){ window.__f.push(performance.now() - window.__last);
      window.__last = performance.now();
      if (window.__f.length < 260) requestAnimationFrame(tick); })();
    return 1; })()`);
  const fling = async () => {
    await ws.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: 210, y: 820 }] });
    for (let i = 1; i <= 12; i++) {
      await ws.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [{ x: 210, y: 820 - i * 50 }] });
      await sleep(16);
    }
    await ws.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
  };
  /* 帧间隔看不出问题：rAF 被 vsync 锁住，主线程变慢的表现是"丢帧"而不是"间隔变长"，
     1× 与 4× 降速量出来一模一样（实测都是 p50 16.6 / p95 33）。所以改量**成本本身**：
     Performance.getMetrics 的累计 LayoutDuration / RecalcStyleDuration / ScriptDuration，
     滚动前后各取一次作差。每帧强制同步重排的那种写法，只会在这里现形。 */
  const perf = async () => {
    const r = await ws.send('Performance.getMetrics');
    const m = {}; for (const x of r.metrics) m[x.name] = x.value;
    return m;
  };
  /* 仪器自证：这四项计数器必须存在且在动（页面已经排过版），否则"0.0ms"只是没开表 */
  const pv = await perf();
  const hasK = ['LayoutDuration', 'RecalcStyleDuration', 'ScriptDuration', 'TaskDuration']
    .every(k => typeof pv[k] === 'number');
  chk('滚动量测的仪器会出数（Performance 四项计数器存在且累计 > 0）',
    hasK && (pv.LayoutDuration + pv.RecalcStyleDuration + pv.TaskDuration) > 0,
    hasK ? `Layout ${(pv.LayoutDuration * 1000).toFixed(0)}ms · Recalc ${(pv.RecalcStyleDuration * 1000).toFixed(0)}ms · Task ${(pv.TaskDuration * 1000).toFixed(0)}ms`
      : '拿不到计数器（' + Object.keys(pv).length + ' 项）');
  let p0 = await perf();
  await fling(); await sleep(500); await fling(); await sleep(400);
  let how = 'CDP 触摸甩动';
  const moved = await ev(`Math.round(window.scrollY)`);
  if (!(moved > 200)) {
    how = '脚本滚动（触摸事件没让页面滚起来）';
    p0 = await perf();
    await ev(`(function(){ var n=0; (function step(){ window.scrollBy(0, 46);
      if (++n < 120) requestAnimationFrame(step); })(); return 1; })()`);
    await sleep(2200);
  }
  const p1 = await perf();
  await ev(`window.scrollTo(0, 0)`); await sleep(300);
  const fr = await ev(`(function(){
    var raw = (window.__f || []).slice(3).filter(function (x) { return x > 0 && x < 3000; })
      .sort(function (a, b) { return a - b; });
    var q = function (p) { return raw.length ? +raw[Math.min(raw.length - 1, Math.floor(raw.length * p))].toFixed(1) : -1; };
    var over = raw.filter(function (x) { return x > 34; }).length;
    var lt = window.__lt || [];
    return { n: raw.length, p50: q(0.5), p95: q(0.95), worst: raw.length ? +raw[raw.length - 1].toFixed(1) : -1,
      over: over, ltN: lt.length, ltWorst: lt.length ? Math.max.apply(null, lt) : 0 }; })()`);
  const costMs = (((p1.LayoutDuration || 0) - (p0.LayoutDuration || 0))
    + ((p1.RecalcStyleDuration || 0) - (p0.RecalcStyleDuration || 0))) * 1000;
  const scriptMs = ((p1.ScriptDuration || 0) - (p0.ScriptDuration || 0)) * 1000;
  chk('名单页滚动不掉帧（p95 帧间隔 < 34ms，长任务不超 200ms）',
    fr.n > 40 && fr.p95 < 34 && fr.ltWorst < 200,
    `${how} · p50 ${fr.p50}ms p95 ${fr.p95}ms 最差 ${fr.worst}ms · >34ms 的帧 ${fr.over}/${fr.n} · `
    + `长任务 ${fr.ltN} 个最久 ${fr.ltWorst}ms · 布局+重算样式 ${costMs.toFixed(1)}ms · 脚本 ${scriptMs.toFixed(1)}ms`);
  await ws.send('Emulation.setCPUThrottlingRate', { rate: 1 });

  /* 整趟驱动下来，界面有没有问过台架答不了的命令？
     shim 对答不上的命令只记一行"静默不回调"就返回 undefined —— 真机上那条
     promise 永远不落地，界面会停在加载页。exec 计数抓不到它（反而多算一行），
     所以按行型单独要它为零。 */
  const q0 = await ev(PROBE);
  chk('界面问过的命令台架都答得上（无静默不回调）', q0.quiet === 0,
    q0.quiet ? q0.quietLines.slice(0, 3).join(' ⏐ ') : 'exec ' + q0.calls + ' 次全应答');
  const shot = await ws.send('Page.captureScreenshot', { format: 'png' });
  fs.writeFileSync(path.join(OUT, 'replay.png'), Buffer.from(shot.data, 'base64'));
  console.log('\n截图：' + path.join(OUT, 'replay.png'));
  ws.sock.close(); chrome.kill();
  process.exit(bad ? 1 : 0);
}
main().catch(e => { console.error('✗ ' + e.message); process.exit(1); });
