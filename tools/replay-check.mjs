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
const SH_PATH = '/data/adb/modules/ts-auto-add/webui.sh';
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
for (const c of READ) store[c] = cap(c, c === 'log' ? '60' : '');
/* icons 要包名参数：拿 targets 的头几个真包名去要，形状才是屏幕上会看到的形状 */
const pkgs = (store.targets.stdout || '').split('\n').map(s => s.trim()).filter(Boolean).slice(0, 12);
store.icons = pkgs.length ? cap('icons', pkgs.join(' ')) : { errno: 0, stdout: '', stderr: '' };
const okN = Object.values(store).filter(r => r.errno === 0).length;
console.log(`  ${serial}：${Object.keys(store).length} 条命令现读完成，${okN} 条退 0`
  + `（读命令失败的那几条本来就该失败，比如后端不是 TEESim）`);
for (const [k, r] of Object.entries(store)) {
  if (r.errno !== 0) console.log(`     · ${k} 退 ${r.errno}: ${(r.stderr || r.stdout).split('\n')[0].slice(0, 52)}`);
}

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
  await sleep(3500);

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

  const p = await ev(PROBE);
  /* 判据要钉在**真数据**上，不是"画了点什么"：
     名单里有多少条真条目，屏上就该有多少行 —— 桥接卡住时界面仍会画出自检卡那几行，
     只看 cards/items 下限抓不到（第一次就是这么假绿的）。 */
  const realTargets = (store['targets'].stdout || '').split('\n').map(s => s.trim()).filter(Boolean);
  const wantItems = Math.min(realTargets.length, 60);
  const firstPkg = realTargets[0] || '';
  const firstLog = (store['log'].stdout || '').split('\n').filter(Boolean).pop() || '';
  chk('视口钉在 417', p.vw === 417, 'vw=' + p.vw);
  chk('桥接被认成 ksu（不是"未找到"）', /ksu/i.test(p.self || ''), p.self || '自检行没读到');
  chk('真的把命令发出去了', p.calls >= 6, 'exec 调用 ' + p.calls + ' 次');
  chk('真机名单画到屏上（不是只有框架）', p.items >= wantItems,
    '列表项 ' + p.items + '，真机名单 ' + realTargets.length + ' 条（门槛 ' + wantItems + '）');
  chk('画的是真包名，不是占位', !firstPkg || (p.text || '').indexOf(firstPkg) >= 0, firstPkg);
  chk('没有"命令超时"', (p.text || '').indexOf('超时') < 0, '');
  chk('没有"桥接未就绪"', (p.text || '').indexOf('桥接未就绪') < 0, '');
  chk('没有"读不到"', (p.text || '').indexOf('读不到') < 0, '');
  chk('横向不溢出', p.scrollW - p.vw <= 0, '溢出 ' + (p.scrollW - p.vw) + 'px');
  chk('无未捕获异常', !(ws.errs || []).length, (ws.errs || []).slice(0, 2).join(' | '));

  /* 逐格点一遍：每格都要有**那一格该出现的真东西** */
  const PAGE_MARK = ['后端', '自动更新', '伪装', '日志'];
  for (let i = 0; i < 4; i++) {
    await ev(`(function(){ var n=document.getElementById('nav');
      n.dispatchEvent(new CustomEvent('change',{detail:{index:${i}},bubbles:true})); return 1; })()`);
    await sleep(2600);
    const q = await ev(PROBE);
    const t2 = await ev(`(function(){var b=document.getElementById('bar');return b&&b.shadowRoot&&b.shadowRoot.querySelector('.headline-line')?b.shadowRoot.querySelector('.headline-line').textContent.trim():''})()`);
    /* 日志页要出现真机最后一行；其余页要出现真机第一条包名或真机属性 */
    /* 每格钉一个"只有真数据才会出现"的东西：
       日志页会剥 emoji（stripEmoji），所以取时间戳前缀而不是整行；
       自动更新页不显示包名，钉的是真机名单条数。 */
    const needle = i === 3 ? firstLog.slice(0, 15).trim() : (i === 2 ? 'ro.' : (i === 1 ? String(realTargets.length) : firstPkg));
    const hasNeedle = needle ? (q.text || '').indexOf(needle) >= 0 : true;
    chk('第 ' + i + ' 格有真数据', hasNeedle && (q.text || '').length > 40,
      '标题=' + t2 + ' 列表项=' + q.items + ' 找「' + needle + '」' + (hasNeedle ? '✓'
        : '✗ 屏上末尾是：' + JSON.stringify((q.text || '').slice(-90))));
    if (!hasNeedle) bad++;
  }
  const shot = await ws.send('Page.captureScreenshot', { format: 'png' });
  fs.writeFileSync(path.join(OUT, 'replay.png'), Buffer.from(shot.data, 'base64'));
  console.log('\n截图：' + path.join(OUT, 'replay.png'));
  ws.sock.close(); chrome.kill();
  process.exit(bad ? 1 : 0);
}
main().catch(e => { console.error('✗ ' + e.message); process.exit(1); });
