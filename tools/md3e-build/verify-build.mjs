'use strict';
/* 新版产物的第一道验证：组件注册了吗、417 下溢出吗、图标字体真的生效吗。
   字体这一项必须量：连字串没字体就会把 "security" 原样画出来，
   而 document.fonts.check() 在部分 WebView 上会乐观返回 true，不可信。
   判据用宽度：一个连字 = 一个字形的宽度；一串拉丁字母 = 好几倍。 */
import { spawn } from 'node:child_process';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
const CHROME = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
const FILE = path.resolve(process.argv[2] || 'D:\\Github Repositories\\TS-AUTO-ADD\\webui\\dist\\index.html');
const PORT = Number(process.env.PORT || 9241);
const URL0 = 'file:///' + FILE.replace(/\\/g, '/');
const get = p => new Promise((res, rej) => { http.get({ host: '127.0.0.1', port: PORT, path: p }, r => { let b = ''; r.on('data', d => b += d); r.on('end', () => res(b)); }).on('error', rej); });
const sleep = ms => new Promise(r => setTimeout(r, ms));

const PROBE = `(function(){
  var want = ['md-top-app-bar','md-navigation-bar','md-card','md-list','md-list-item','md-button','md-switch','md-chip','md-divider','md-loading-indicator'];
  var missing = want.filter(function(t){ return !customElements.get(t); });
  /* 图标字体是否真的应用：同一个连字串分别用符号字体和系统字体量宽。
     字体生效 → 连字塌成一个字形（≈字号宽）；没生效 → 8 个拉丁字母。 */
  /* 图标字体是否真的应用 —— 一正一负两个对照：
     子集内的名字（home）应塌成一个字形；子集外的名字（security）必然还是八个字母。
     只量正例会漏掉"整个字体没落地"（那时两个都宽），只量负会误判 —— 两个一起看
     才证明的是"字体在工作"，而不是"字体在工作且这个图标刚好没有"。 */
  function w(name){
    var s = document.createElement('span');
    s.textContent = name;
    s.style.cssText = 'position:fixed;left:-9999px;top:0;font-size:24px;font-family:var(--md-icon-font-family)';
    document.body.appendChild(s);
    var r = s.getBoundingClientRect().width;
    s.remove();
    return Math.round(r);
  }
  var inSet = w('home');          // 子集内 → 一个字形 ≈ 24~30px
  var outSet = w('security');     // 子集外 → 八个字母
  var el = document.querySelector('md-list-item');
  /* 组件内部到底有没有用符号字体：遍历所有自定义元素的 shadowRoot，
     看有没有元素的计算字体解析到 Material Symbols。
     （不能 grep innerHTML —— 库的样式走 adoptedStyleSheets，不在 HTML 里；
       也不能只查一个宿主元素 —— 图标元素在哪个 shadowRoot 里是库的实现细节。） */
  var iconFam = ''; var iconWhere = '';
  var hosts = document.querySelectorAll('*');
  for (var i = 0; i < hosts.length && !iconFam; i++) {
    var sr = hosts[i].shadowRoot;
    if (!sr) continue;
    var kids = sr.querySelectorAll('*');
    for (var j = 0; j < kids.length; j++) {
      var f = getComputedStyle(kids[j]).fontFamily || '';
      if (/Material Symbols/i.test(f)) {
        iconFam = f;   /* 断言看的是族名 */
        iconWhere = hosts[i].tagName.toLowerCase() + ' > ' + kids[j].tagName.toLowerCase()
          + '.' + (typeof kids[j].className === 'string' ? kids[j].className : '');
        break;
      }
    }
  }
  var vw = Math.round(document.documentElement.clientWidth);
  var over = document.documentElement.scrollWidth - vw;
  var navItems = (document.getElementById('nav') || {}).items;
  return { missing: missing, inSet: inSet, outSet: outSet, iconFam: iconFam, iconWhere: iconWhere,
    fontsReady: document.fonts ? document.fonts.status : 'n/a',
    vw: vw, over: over, navN: navItems ? navItems.length : 0,
    listHeadline: el ? (el.getAttribute('headline') || '') : '',
    bodyBg: getComputedStyle(document.body).backgroundColor };
})()`;

async function main() {
  const chrome = spawn(CHROME, ['--headless=new', '--disable-gpu', '--hide-scrollbars',
    '--remote-debugging-port=' + PORT, '--window-size=800,1000', 'about:blank'], { stdio: 'ignore' });
  let t = null;
  for (let i = 0; i < 40 && !t; i++) { await sleep(400); try { t = JSON.parse(await get('/json/list')).find(x => x.type === 'page' && x.webSocketDebuggerUrl); } catch (e) {} }
  if (!t) { chrome.kill(); console.log('无 CDP target'); process.exit(1); }
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
  await send('Page.navigate', { url: URL0 });
  await sleep(2600);
  const ev = async e => { const r = await send('Runtime.evaluate', { expression: e, returnByValue: true, awaitPromise: true }); if (r.exceptionDetails) throw new Error(((r.exceptionDetails.exception || {}).description) || r.exceptionDetails.text); return r.result.value; };
  const p = await ev(PROBE);
  const shot = await send('Page.captureScreenshot', { format: 'png' });
  fs.writeFileSync('C:\\Users\\20653\\AppData\\Local\\Temp\\new-skeleton.png', Buffer.from(shot.data, 'base64'));

  let bad = 0;
  const chk = (name, ok, detail) => { if (!ok) bad++; console.log(`${ok ? 'ok  ' : '✗   '} ${name}${detail ? '  ' + detail : ''}`); };
  chk('10 个组件全部注册', p.missing.length === 0, p.missing.join(','));
  chk('视口钉在 417', p.vw === 417, 'vw=' + p.vw);
  chk('横向溢出 0', p.over === 0, 'over=' + p.over);
  chk('底栏四项', p.navN === 4, 'n=' + p.navN);
  chk('列表项画出来了', !!p.listHeadline, p.listHeadline);
  /* 正对照：子集内的名字塌成一个字形（≈字号宽）；负对照：子集外的仍旧是八个字母 */
  chk('图标字体生效（子集内的名字连字成单个字形）', p.inSet > 0 && p.inSet <= 34,
    `home=${p.inSet}px（24px 字号下单个字形应 ≤34px）`);
  chk('负对照成立（子集外的名字仍是字面词）', p.outSet > p.inSet * 2,
    `security=${p.outSet}px，是 home 的 ${(p.outSet / Math.max(p.inSet, 1)).toFixed(1)} 倍`);
  chk('组件内部用的就是符号字体', /Material Symbols/i.test(p.iconFam), p.iconWhere + ' → ' + p.iconFam);
  chk('页面背景吃到了 M3 角色色', /rgb|oklch/.test(p.bodyBg), p.bodyBg);
  chk('无未捕获异常', errs.length === 0, errs.slice(0, 2).join(' | '));
  console.log('\n截图：C:\\Users\\20653\\AppData\\Local\\Temp\\new-skeleton.png');
  ws.close(); chrome.kill();
  process.exit(bad ? 1 : 0);
}
main().catch(e => { console.log('失败: ' + e.message); process.exit(1); });
