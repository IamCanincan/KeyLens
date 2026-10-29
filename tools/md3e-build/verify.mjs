/* 构建验收：证明产物真的能跑，而不是"文件存在"。
 *
 * 判据一律对着**渲染出来的 DOM**，不 grep 源码字符串 —— 上一版骨架就是那样蒙过去的：
 * 底栏只数了 items.length，而事件名接错（库发的是 change + detail.index，我接的
 * selected-change），点了根本不会切页，台架照样全绿。所以这一版必须真的驱动导航。
 *
 *   node tools/md3e-build/verify.mjs [产物路径]
 */
import { spawn } from 'node:child_process';
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const FILE = process.argv[2] ? path.resolve(process.argv[2]) : path.join(repo, 'webui', 'dist', 'index.html');
const CHROME = process.env.CHROME || 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
const PORT = Number(process.env.PORT || 9251);
const URL0 = 'file:///' + FILE.replace(/\\/g, '/') + '?demo=1';
const SHOT_DIR = path.join(os.tmpdir(), 'md3e-verify');

if (!fs.existsSync(FILE)) { console.error('✗ 找不到产物 ' + FILE + '，先跑 build.mjs'); process.exit(1); }
if (!fs.existsSync(CHROME)) { console.error('✗ 找不到 Chrome：' + CHROME); process.exit(1); }
if (typeof WebSocket !== 'function') { console.error('✗ 需要 Node 21+（全局 WebSocket）'); process.exit(1); }
fs.mkdirSync(SHOT_DIR, { recursive: true });

const get = p => new Promise((res, rej) => {
  http.get({ host: '127.0.0.1', port: PORT, path: p }, r => {
    let b = ''; r.on('data', d => b += d); r.on('end', () => res(b));
  }).on('error', rej);
});
const sleep = ms => new Promise(r => setTimeout(r, ms));

const WANT = ['md-top-app-bar', 'md-navigation-bar', 'md-card', 'md-list',
  'md-list-item', 'md-button', 'md-loading-indicator', 'md-snackbar'];
/* 顺序 = 底栏四格的顺序。must 是这一页必须出现的区块标题：
   功能页那几块正是三家后端各自的能力面，缺一个就说明分支渲染没跑到。 */
const PAGES = [
  { id: 'over', title: '主页', must: ['最近动态', '运行'], items: true },
  { id: 'func', title: '功能', must: ['当前后端', 'Profile 表'], items: true },
  /* 日志页画的是日志台（.log-line），本来就没有列表项 —— 这条判据对它无意义，
     所以按页声明，而不是一刀切要求 items>0。 */
  { id: 'log', title: '日志', must: ['运行日志', '同步完成'], items: false },
  { id: 'about', title: '关于', must: ['界面自检', '命令层契约'], items: true },
];

const PROBE = `(function(){
  var vw = Math.round(document.documentElement.clientWidth);
  function w(name){
    var s = document.createElement('span'); s.textContent = name;
    s.style.cssText = 'position:fixed;left:-9999px;font-size:24px;font-family:var(--md-icon-font-family)';
    document.body.appendChild(s); var r = s.getBoundingClientRect().width; s.remove(); return Math.round(r);
  }
  var fam = '';
  document.querySelectorAll('*').forEach(function(e){
    if (fam || !e.shadowRoot) return;
    e.shadowRoot.querySelectorAll('*').forEach(function(n){
      var f = getComputedStyle(n).fontFamily || '';
      if (/Material Symbols/i.test(f)) fam = f;
    });
  });
  /* 人眼看到的文字 = 文本节点 + 列表项的属性（headline/supporting/trailing 是画在
     shadow DOM 里的，textContent 拿不到 —— 只比 textContent 会把"关于"页自己的
     标题判成缺失）。 */
  var txt = (document.getElementById('view')||{}).textContent || '';
  document.querySelectorAll('#view md-list-item').forEach(function(n){
    txt += '|' + (n.getAttribute('headline')||'') + (n.getAttribute('supporting-text')||'') + (n.getAttribute('trailing-text')||'');
  });
  /* 顶栏标题要读**渲染出来的**那一行，不能读 .title —— 那是原生 tooltip，
     组件其实认 headline 属性。上一版就是 set 了 .title、界面上顶栏是空的，
     而台架读 .title 读到值，跟着一起判"通过"。 */
  var bar = document.getElementById('bar');
  var head = '';
  if (bar && bar.shadowRoot) {
    var hn = bar.shadowRoot.querySelector('.headline-line');
    if (hn) head = (hn.textContent || '').trim();
  }
  return { vw: vw, scrollW: document.documentElement.scrollWidth,
    missing: ${JSON.stringify(WANT)}.filter(function(t){ return !customElements.get(t); }),
    title: head, tip: bar ? (bar.getAttribute('title') || '') : '',
    text: txt,
    items: document.querySelectorAll('#view md-list-item').length,
    cards: document.querySelectorAll('#view md-card').length,
    inSet: w('home'), outSet: w('security'), fam: fam };
})()`;

async function main() {
  const chrome = spawn(CHROME, ['--headless=new', '--disable-gpu', '--hide-scrollbars',
    '--remote-debugging-port=' + PORT, '--window-size=800,1000', 'about:blank'], { stdio: 'ignore' });
  let t = null;
  for (let i = 0; i < 40 && !t; i++) {
    await sleep(400);
    try { t = JSON.parse(await get('/json/list')).find(x => x.type === 'page' && x.webSocketDebuggerUrl); } catch (e) {}
  }
  if (!t) { chrome.kill(); console.error('✗ 拿不到 CDP target'); process.exit(1); }

  const ws = new WebSocket(t.webSocketDebuggerUrl);
  let id = 0; const pend = new Map(); const errs = [];
  const send = (m, p) => new Promise((res, rej) => { const n = ++id; pend.set(n, { res, rej }); ws.send(JSON.stringify({ id: n, method: m, params: p || {} })); });
  ws.onmessage = ev => {
    const m = JSON.parse(ev.data);
    if (m.method === 'Runtime.exceptionThrown') errs.push(((m.params.exceptionDetails.exception || {}).description) || m.params.exceptionDetails.text);
    if (m.id && pend.has(m.id)) { const q = pend.get(m.id); pend.delete(m.id); m.error ? q.rej(new Error(JSON.stringify(m.error))) : q.res(m.result); }
  };
  await new Promise(r => { ws.onopen = r; });
  await send('Page.enable'); await send('Runtime.enable');
  await send('Emulation.setDeviceMetricsOverride', { width: 417, height: 975, deviceScaleFactor: 2, mobile: true });
  const ev = async e => {
    const r = await send('Runtime.evaluate', { expression: e, returnByValue: true, awaitPromise: true });
    if (r.exceptionDetails) throw new Error(((r.exceptionDetails.exception || {}).description) || r.exceptionDetails.text);
    return r.result.value;
  };

  await send('Page.navigate', { url: URL0 });
  await sleep(2800);

  let bad = 0;
  const chk = (name, ok, detail) => { if (!ok) bad++; console.log(`${ok ? 'ok  ' : '✗   '} ${name}${detail ? '  — ' + detail : ''}`); };

  const p0 = await ev(PROBE);
  chk('组件全部注册', p0.missing.length === 0, p0.missing.join(','));
  chk('视口钉在 417', p0.vw === 417, 'vw=' + p0.vw);
  chk('主页横向不溢出', p0.scrollW - p0.vw <= 0, '溢出 ' + (p0.scrollW - p0.vw) + 'px');
  chk('主页画出卡片与列表项', p0.cards >= 3 && p0.items >= 4, 'cards=' + p0.cards + ' items=' + p0.items);
  chk('图标字体生效（子集内名字 = 一个字形）', p0.inSet > 0 && p0.inSet <= 34, 'home=' + p0.inSet + 'px');
  chk('负对照成立（子集外名字 = 字面词）', p0.outSet > p0.inSet * 2, 'security=' + p0.outSet + 'px，' + (p0.outSet / Math.max(p0.inSet, 1)).toFixed(1) + ' 倍');
  chk('组件内部解析到符号字体', /Material Symbols/i.test(p0.fam), p0.fam || '没找到');

  console.log('── 逐页驱动（真的点导航）──');
  for (let i = 0; i < PAGES.length; i++) {
    const want = PAGES[i];
    await ev(`(function(){ var n=document.getElementById('nav');
      n.dispatchEvent(new CustomEvent('change',{detail:{index:${i}},bubbles:true})); return 1; })()`);
    await sleep(900);
    const p = await ev(PROBE);
    const miss = want.must.filter(s => p.text.indexOf(s) < 0);
    const ok = p.title === want.title && !miss.length && p.scrollW - p.vw <= 0
      && (!want.items || p.items > 0);
    if (!ok) bad++;
    console.log(`${ok ? 'ok  ' : '✗   '} 第 ${i} 格 → ${want.title}  标题=${p.title} 列表项=${p.items} 溢出=${p.scrollW - p.vw}px`
      + (miss.length ? '  缺区块: ' + miss.join('、') : ''));
    const shot = await send('Page.captureScreenshot', { format: 'png' });
    fs.writeFileSync(path.join(SHOT_DIR, 'new-' + want.id + '.png'), Buffer.from(shot.data, 'base64'));
  }
  chk('无未捕获异常', errs.length === 0, errs.slice(0, 2).join(' | '));
  console.log('\n截图：' + SHOT_DIR);
  ws.close(); chrome.kill();
  process.exit(bad ? 1 : 0);
}
main().catch(e => { console.error('✗ ' + e.message); process.exit(1); });
