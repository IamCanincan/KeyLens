/* 一次性审计：界面往 md-* 元素上落的属性，组件到底认不认、认了的有没有真渲染出字。
 *
 * 起因是 §5.32 那条 `[object Object]`：提示的文字压根没落到屏上，而台架唯一碰 snackbar
 * 的断言是反向的、读数还恒空。这类洞的通用形状就两个 ——
 *   ① 属性名组件根本不 observed（设了等于没设）；
 *   ② 属性名组件认，但屏上出来的字不是我们给的那份（对象当字符串、模板没展开…）。
 * 这里两条各扫一遍，逐页扫（四格 + 功能里的每个二级页 + 三家后端）。
 *
 *   node tools/md3e-build/attr-audit.mjs [产物路径]
 */
import { spawn } from 'node:child_process';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const FILE = process.argv[2] ? path.resolve(process.argv[2]) : path.join(repo, 'webui', 'dist', 'index.html');
const CHROME = process.env.CHROME || 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
const PORT = Number(process.env.PORT || 9261);
const URL0 = 'file:///' + FILE.replace(/\\/g, '/') + '?demo=1';
const sleep = ms => new Promise(r => setTimeout(r, ms));
const get = p => new Promise((res, rej) => {
  http.get({ host: '127.0.0.1', port: PORT, path: p }, r => {
    let b = ''; r.on('data', d => b += d); r.on('end', () => res(b));
  }).on('error', rej);
});

const AUDIT = `(function(){
  var GLOBAL = {class:1,id:1,style:1,hidden:1,role:1,tabindex:1,slot:1,part:1,title:1,lang:1,dir:1,draggable:1,inputmode:1,contenteditable:1};
  /* 这些属性承载"要给人看的字"：组件认了，还得真把这份字画出来（不是 [object Object]、不是空） */
  var TEXT_ATTR = ['label','headline','supporting-text','message','text','description'];
  var dead = {}, unrendered = {}, tags = {}, skippedProp = {};
  /* md-* 不是合法的类型通配选择器（写上去当场 SyntaxError）—— 拉全部元素再按标签前缀筛。 */
  var els = [].slice.call(document.querySelectorAll('#view *, #nav *, body > *'))
    .filter(function(e){ return e.tagName.indexOf('MD-') === 0; });
  els.forEach(function(e){
    var tag = e.tagName.toLowerCase();
    tags[tag] = (tags[tag]||0)+1;
    var ctor = customElements.get(tag);
    if (!ctor) { dead[tag+'|（自定义元素没注册）'] = (dead[tag+'|（自定义元素没注册）']||0)+1; return; }
    var obs = [].concat(ctor.observedAttributes || []);
    var O = {}; obs.forEach(function(a){ O[a]=1; });
    for (var i=0;i<e.attributes.length;i++){
      var n = e.attributes[i].name, v = e.attributes[i].value;
      if (O[n] || GLOBAL[n] || n.indexOf('data-')===0 || n.indexOf('aria-')===0) continue;
      /* 组件用**属性 getter**按需读它（md-option 的 value/disabled 就是这样：不在
         observedAttributes 里，但原型上有 get value() 直接读属性）。这种不算死属性 ——
         只有"既不 observed、原型上也没这个口子"的才是真设了等于没设。 */
      if (n in e) { skippedProp[tag+'|'+n] = (skippedProp[tag+'|'+n]||0)+1; continue; }
      var k = tag+'|'+n+'='+String(v).slice(0,20);
      dead[k]=(dead[k]||0)+1;
    }
    TEXT_ATTR.forEach(function(n){
      if (!O[n]) return;
      var want = String(e.getAttribute(n)||'');
      if (!want || want === 'true' || want === '') return;
      var sr = e.shadowRoot ? String(e.shadowRoot.textContent||'') : '';
      var light = String(e.textContent||'');
      if (sr.indexOf(want) < 0 && light.indexOf(want) < 0) {
        unrendered[tag+'|'+n+' 要「'+want.slice(0,18)+'」影子里读到「'+sr.replace(/\\s+/g,' ').trim().slice(0,18)+'」']
          = (unrendered[tag+'|'+n+' 要「'+want.slice(0,18)+'」影子里读到「'+sr.replace(/\\s+/g,' ').trim().slice(0,18)+'」']||0)+1;
      }
    });
  });
  return { 元素数: els.length, 页: (document.querySelector('#view .page-title') || {}).textContent || '(无标题)',
    种类: tags, 组件不认的属性: dead, 认了却没画出字: unrendered, 属性口子放过: skippedProp };
})()`;

async function main() {
  const chrome = spawn(CHROME, ['--headless=new', '--disable-gpu', '--hide-scrollbars',
    '--remote-debugging-port=' + PORT, '--window-size=417,900', 'about:blank'], { stdio: 'ignore' });
  let t = null;
  for (let i = 0; i < 40 && !t; i++) {
    await sleep(400);
    try { t = JSON.parse(await get('/json/list')).find(x => x.type === 'page' && x.webSocketDebuggerUrl); } catch (e) {}
  }
  if (!t) { chrome.kill(); console.error('✗ 拿不到 CDP target'); process.exit(1); }
  const ws = new WebSocket(t.webSocketDebuggerUrl);
  let id = 0; const pend = new Map();
  const send = (m, p) => new Promise((res, rej) => { const n = ++id; pend.set(n, { res, rej }); ws.send(JSON.stringify({ id: n, method: m, params: p || {} })); });
  ws.onmessage = ev => {
    const d = JSON.parse(ev.data);
    if (d.id && pend.has(d.id)) { const p = pend.get(d.id); pend.delete(d.id); d.error ? p.rej(new Error(JSON.stringify(d.error))) : p.res(d.result); }
  };
  await new Promise(r => { ws.onopen = r; });
  await send('Page.enable');
  const ev = async expr => {
    const r = await send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true });
    if (r.exceptionDetails) throw new Error('页内异常：' + JSON.stringify(r.exceptionDetails.exception && r.exceptionDetails.exception.description || r.exceptionDetails.text).slice(0, 300));
    return r.result ? r.result.value : null;
  };
  const tap = async expr => {
    const pos = await ev(`(function(){ var e=${expr}; if(!e) return null;
      e.scrollIntoView({ behavior: 'instant', inline: 'center', block: 'nearest' });
      var r=e.getBoundingClientRect();
      return { x: Math.round(r.left + r.width/2), y: Math.round(r.top + Math.min(r.height/2, 44)) }; })()`);
    if (!pos) return 0;
    await send('Input.dispatchMouseEvent', { type: 'mousePressed', x: pos.x, y: pos.y, button: 'left', clickCount: 1 });
    await send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: pos.x, y: pos.y, button: 'left', clickCount: 1 });
    return 1;
  };

  const seen = { 组件不认的属性: {}, 认了却没画出字: {}, 属性口子放过: {} };
  const cov = { 次: 0, 元素: 0, 页: [] };
  const add = r => {
    if (!r) return;
    cov.次++; cov.元素 += r['元素数'] || 0;
    cov.页.push((r['页'] || '?') + '(' + (r['元素数'] || 0) + ')');
    ["组件不认的属性", "认了却没画出字", "属性口子放过"].forEach(function (k) {
      Object.keys(r[k] || {}).forEach(function (x) { seen[k][x] = (seen[k][x] || 0) + (r[k][x] || 0); });
    });
  };

  /* 仪器自测：0 命中是关于**这台仪器**的说法，不是关于界面的。现场造两个必定该被抓到的
     元素（一颗带组件不认的属性、一个把文字属性设成影子里没有的那份），两维都得各响一次，
     否则下面的"零条"不作数。 */
  await send('Page.navigate', { url: URL0 });
  await sleep(2200);
  await ev(`(function(){
    var b=document.createElement('md-button'); b.setAttribute('bogus-probe','1');
    b.setAttribute('label','自测按钮'); document.body.appendChild(b);
    var s=document.createElement('md-snackbar'); s.setAttribute('message','自测提示文字');
    document.body.appendChild(s); return 1; })()`);
  const st = await ev(AUDIT);
  const hit1 = Object.keys(st['组件不认的属性'] || {}).some(k => k.indexOf('bogus-probe') >= 0);
  const hit2 = Object.keys(st['认了却没画出字'] || {}).some(k => k.indexOf('自测提示文字') >= 0);
  console.log('══ 仪器自测：① 不认的属性 ' + (hit1 ? '响' : '**没响**')
    + ' · ② 认了没画字 ' + (hit2 ? '响' : '**没响**'));
  if (!hit1 || !hit2) {
    console.log('   ①读数: ' + JSON.stringify(Object.keys(st['组件不认的属性'] || {})).slice(0, 300));
    console.log('   ②读数: ' + JSON.stringify(Object.keys(st['认了却没画出字'] || {})).slice(0, 300));
  }
  await ev(`(function(){ [].slice.call(document.body.children)
      .filter(function(e){ return e.hasAttribute('bogus-probe') || (e.tagName === 'MD-SNACKBAR' && e.getAttribute('message') === '自测提示文字'); })
      .forEach(function(e){ e.remove(); }); return 1; })()`);
  if (!hit1) { console.error('✗ 自测失败：①这一维看不见东西，"零条"不作数'); ws.close(); chrome.kill(); process.exit(2); }

  for (const qs of ['', '&backend=tricky', '&backend=teesim', '&many=1']) {
    await send('Page.navigate', { url: URL0 + qs });
    await sleep(2200);
    for (let tab = 0; tab < 4; tab++) {
      await ev(`(function(){ var n=document.getElementById('nav');
        n.dispatchEvent(new CustomEvent('change',{detail:{index:${tab}},bubbles:true})); return 1; })()`);
      await sleep(700);
      add(await ev(AUDIT));;
      if (tab !== 1) continue;
      /* 功能格：把每个二级页都走一遍（列表项只认真指针事件） */
      const names = await ev(`[].slice.call(document.querySelectorAll('#view md-list-item')).map(function(x){return x.getAttribute('headline')||'';})`);
      for (let k = 0; k < (names || []).length; k++) {
        await ev(`(function(){ var n=document.getElementById('nav');
          n.dispatchEvent(new CustomEvent('change',{detail:{index:1},bubbles:true})); return 1; })()`);
        await sleep(500);
        await tap(`(function(){ var its=[].slice.call(document.querySelectorAll('#view md-list-item')); return its[${k}]; })()`);
        await sleep(900);
        add(await ev(AUDIT));;
        /* 名单页的五个芯片档也各扫一次 */
        const chips = await ev(`[].slice.call(document.querySelectorAll('#view md-chip')).length`);
        if (chips >= 3) {
          for (let c = 0; c < chips; c++) {
            await tap(`(function(){ var cs=[].slice.call(document.querySelectorAll('#view md-chip')); return cs[${c}]; })()`);
            await sleep(700);
            add(await ev(AUDIT));;
          }
        }
      }
    }
  }

  console.log('══ 组件不认的属性（设了等于没设）');
  const d = Object.keys(seen['组件不认的属性'] || {});
  if (!d.length) console.log('  （零条）');
  d.forEach(k => console.log('  ' + k + '   ×' + seen['组件不认的属性'][k]));
  console.log('══ 组件认了、屏上却没画出那份字');
  const u = Object.keys(seen['认了却没画出字'] || {});
  if (!u.length) console.log('  （零条）');
  u.forEach(k => console.log('  ' + k + '   ×' + seen['认了却没画出字'][k]));
  console.log('══ 放过的那些（组件用属性 getter 按需读，不算死属性）');
  const s = Object.keys(seen['属性口子放过'] || {});
  if (!s.length) console.log('  （零条）');
  s.forEach(k => console.log('  ' + k + '   ×' + seen['属性口子放过'][k]));
  /* 覆盖自证：0 命中只有在真扫过东西时才算数（第一版就是拿一个非法选择器扫出"零条"的）。 */
  console.log('══ 覆盖：扫了 ' + cov.次 + ' 屏 / 累计 ' + cov.元素 + ' 个 md-* 元素');
  console.log('   ' + cov.页.join(' '));
  if (cov.次 < 20 || cov.元素 < 200) {
    console.error('✗ 覆盖不够（要 ≥20 屏、累计 ≥200 个元素），上面的"零条"不作数');
    ws.close(); chrome.kill(); process.exit(2);
  }
  ws.close(); chrome.kill();
  process.exit(d.length + u.length ? 1 : 0);
}
main().catch(e => { console.error('✗ ' + e.message); process.exit(1); });
