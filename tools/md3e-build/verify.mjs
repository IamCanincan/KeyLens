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

const WANT = ['md-top-app-bar', 'md-card', 'md-list',
  'md-list-item', 'md-button', 'md-snackbar'];
/* 顺序 = 底栏四格的顺序（主页 / 功能 / 日志 / 设置）。
   must 是这一页必须出现的区块标题：缺一个就说明那一格的分支渲染没跑到。 */
const PAGES = [
  /* 主页回答"在不在跑"：状态条 + 三家互斥矩阵。 */
  { id: 'home', title: '主页', must: ['三家后端', '未安装', '当前生效的就是这一家'], items: true },
  /* 功能格是一张菜单：所有功能集中在这里，每项带状态摘要；
     长列表在二级页里，菜单页本身落地即用。 */
  { id: 'func', title: '功能', must: ['目标名单', '后端配置 ·', '自动同步', '密钥箱 keybox', '属性伪装'], items: true },
  { id: 'log', title: '日志', must: ['运行日志', '同步完成'], items: false },
  /* 设置格只留界面自己的事：外观 + 界面自检（伪装/Verified Boot 在【功能】里）。 */
  { id: 'settings', title: '设置', must: ['外观', '界面自检'], items: true },
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
  /* 图标字体真正的验收：把**画出来的**每个元素拿出来，看它计算样式里打头的那个
     族名有没有对应的 @font-face。产物里留着 .material-symbols-outlined / -sharp
     两条死规则（没有组件用它们），静态扫会被它们绊倒；运行时只看真实元素，
     以后谁 import 了 md-fab，这里就会响，而不是图标静默变成字面词。 */
  var declared = {};
  try { for (const ff of document.fonts) declared[(ff.family || '').replace(/["']/g, '').trim()] = 1; } catch (e) {}
  var missing = {};
  function scan(root) {
    (root || document).querySelectorAll('*').forEach(function (e) {
      var own = e.childElementCount === 0 && (e.textContent || '').trim().length > 0;
      if (!own) return;
      var f = getComputedStyle(e).fontFamily || '';
      var first = (f.split(',')[0] || '').replace(/["']/g, '').trim();
      if (/^Material Symbols/i.test(first) && !declared[first]) missing[first] = (missing[first] || 0) + 1;
      if (e.shadowRoot) scan(e.shadowRoot);
    });
  }
  scan(document);
  var missFam = Object.keys(missing).map(function (k) { return k + '×' + missing[k]; }).join(' ');
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
    rows: document.querySelectorAll('#view .app-row').length,
    cards: document.querySelectorAll('#view md-card').length,
    inSet: w('home'), outSet: w('security'), fam: fam,
    missFam: missFam, declared: Object.keys(declared).join(' ') };
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
  /* 需要看底栏内部时：DUMP_NAV=1 node tools/md3e-build/verify.mjs
     底栏是自定义元素，光看截图分不清"图标没画"和"整项没建" —— 转储直接给结论。 */
  if (process.env.DUMP_NAV) {
    const nav = await ev(`(function(){ var n=document.getElementById('nav'); if(!n) return 'no nav';
      var o={items:n.items, selected:n.selected, kids:[], shadow:[]};
      [].forEach.call(n.children,function(c,i){o.kids.push(i+':'+c.tagName+':icon='+(c.getAttribute('icon')||'-')+':label='+(c.getAttribute('label')||'-')+':active='+(c.hasAttribute('active')?'y':'n'))});
      if (n.shadowRoot) {
        [].forEach.call(n.shadowRoot.querySelectorAll('*'), function(e){
          var t=(e.textContent||'').trim();
          var ff=(getComputedStyle(e).fontFamily||'').split(',')[0];
          if (t && t.length < 16) o.shadow.push(e.tagName+'['+t+'] ff='+ff+' w='+Math.round(e.getBoundingClientRect().width));
        });
      }
      return o; })()`);
    console.log('── 底栏转储 ──');
    console.log(JSON.stringify(nav, null, 1).slice(0, 3000));
  }
  chk('组件全部注册', p0.missing.length === 0, p0.missing.join(','));
  chk('视口钉在 417', p0.vw === 417, 'vw=' + p0.vw);
  chk('主页横向不溢出', p0.scrollW - p0.vw <= 0, '溢出 ' + (p0.scrollW - p0.vw) + 'px');
  chk('主页画出状态条与三家矩阵', p0.cards >= 2 && p0.items >= 3, 'cards=' + p0.cards + ' items=' + p0.items);
  chk('主页显示后端版本（不是 KeyLens 自己的版本）', (p0.text || '').indexOf('1.2.5-17b0eb6') >= 0,
    '找「1.2.5-17b0eb6」');
  {
    const pageTitle = await ev(`(function(){ var t=document.querySelector('#view .page-title');
      return t ? { fs: getComputedStyle(t).fontSize, text: (t.textContent||'').trim() } : null; })()`);
    chk('页标题在内容里且是 28px 大标题（随页滚走）',
      !!pageTitle && pageTitle.fs === '28px' && pageTitle.text === '主页',
      pageTitle ? pageTitle.fs + ' / ' + pageTitle.text : '没读到');
    const brand = await ev(`(function(){ var b=document.querySelector('#view .brand-eyebrow');
      var img=document.querySelector('#view .kl-logo');
      return { text: b ? (b.textContent||'').trim() : '',
        alt: img ? (img.getAttribute('alt')||'') : '',
        src: img ? (img.getAttribute('src')||'') : '' }; })()`);
    chk('主页有 KL 标识与品牌眉题',
      brand.text === 'KEYLENS' && brand.alt === 'KL' && brand.src.indexOf('data:image/png') === 0,
      brand.text + ' / alt=' + brand.alt + ' / src=' + brand.src.slice(0, 22));
    const barTitles = await ev(`(function(){ var b=document.getElementById('bar');
      var t=b&&b.shadowRoot&&b.shadowRoot.querySelector('.titles');
      return t ? { vis: getComputedStyle(t).visibility, op: getComputedStyle(t).opacity } : null; })()`);
    chk('页首顶栏标题让位（滚动后才出现）',
      !!barTitles && barTitles.vis === 'hidden' && barTitles.op === '0',
      barTitles ? barTitles.vis + '/' + barTitles.op : '没读到');
    const navInfo = await ev(`(function(){ var n=document.getElementById('nav');
      return [].slice.call(n.children).map(function(b){
        var l=b.querySelector('.nav-label'); var s=getComputedStyle(l);
        return { active:b.classList.contains('active'), op:s.opacity, max:s.maxWidth }; }); })()`);
    chk('底栏只给当前项显示文字',
      navInfo[0].active && navInfo[0].op === '1'
      && navInfo.slice(1).every(function(x){ return !x.active && x.op === '0'; }),
      navInfo.map(function(x){ return (x.active ? '*' : '') + x.op; }).join(' / '));
    const navTr = await ev(`(function(){ var n=document.getElementById('nav'); var b=n.children[1];
      var l=b&&b.querySelector('.nav-label'); var s=l?getComputedStyle(l):null;
      return { tp:s?s.transitionProperty:'', td:s?s.transitionDuration:'', max:s?s.maxWidth:'' }; })()`);
    chk('底栏文字侧移是过渡（不是一跳一跳）',
      /max-width/.test(navTr.tp) && /opacity/.test(navTr.tp) && /transform/.test(navTr.tp)
      && parseFloat(navTr.td) > 0,
      navTr.tp + ' ' + navTr.td);
    {
      const geo = await ev(`(function(){ var n=document.getElementById('nav'), item=n.children[0];
        var halo=item.querySelector('.nav-halo'), icon=item.querySelector('.nav-icon'), lab=item.querySelector('.nav-label');
        var nr=n.getBoundingClientRect(), ir=item.getBoundingClientRect(), hr=halo.getBoundingClientRect();
        var cr=icon.getBoundingClientRect(), lr=lab.getBoundingClientRect();
        var cx=function(r){ return r.left+r.width/2; }, cy=function(r){ return r.top+r.height/2; };
        return { outerCap:cx(nr)-nr.width/2 + nr.height/2, itemCap:cx(ir)-ir.width/2 + ir.height/2,
          halo:cx(hr), icon:cx(cr), v:cy(nr)-cy(hr), labelLeft:lr.left, haloRight:hr.right }; })()`);
      chk('底栏图标在中轴、文字在侧边、活动圆与胶囊/药丸端同心',
        Math.abs(geo.outerCap - geo.halo) <= 2 && Math.abs(geo.itemCap - geo.halo) <= 1
        && Math.abs(geo.icon - geo.halo) <= 1 && Math.abs(geo.v) <= 1
        && geo.labelLeft >= geo.haloRight - 1,
        '圆心 ' + geo.outerCap + '/' + geo.itemCap + '/' + geo.halo + '/' + geo.icon
        + ' · 垂直差 ' + geo.v + ' · 文字左 ' + Math.round(geo.labelLeft));
    }
    const pill = await ev(`(function(){ var n=document.getElementById('nav'); var r=n.getBoundingClientRect();
      var s=getComputedStyle(n); return { pos:s.position, left:Math.round(r.left), right:Math.round(r.right),
        radius:s.borderRadius, vw:Math.round(document.documentElement.clientWidth) }; })()`);
    chk('底栏是悬浮药丸（不贴边）',
      pill.pos === 'fixed' && pill.left >= 8 && pill.right <= pill.vw - 8 && pill.radius.indexOf('999px') >= 0,
      'left=' + pill.left + ' right=' + pill.right + ' vw=' + pill.vw + ' radius=' + pill.radius);
    const rowSize = await ev(`(function(){ var it=document.querySelector('#view md-list-item');
      var h=it&&it.shadowRoot&&it.shadowRoot.querySelector('.headline');
      return h ? getComputedStyle(h).fontSize : ''; })()`);
    chk('行标题 16px', rowSize === '16px', rowSize || '没读到');
    const rowCenter = await ev(`(function(){ var it=document.querySelector('#view md-list-item');
      if (!it||!it.shadowRoot) return null; var r=it.shadowRoot.querySelector('.item'), c=it.shadowRoot.querySelector('.content');
      if (!r||!c) return null; var a=r.getBoundingClientRect(), b=c.getBoundingClientRect();
      return { row: Math.round(a.top+a.height/2), text: Math.round(b.top+b.height/2) }; })()`);
    chk('行内文字与行中心对齐（不靠上）',
      !!rowCenter && Math.abs(rowCenter.row - rowCenter.text) <= 2,
      rowCenter ? '行中心 ' + rowCenter.row + ' / 文字中心 ' + rowCenter.text : '没读到');
  }
  chk('图标字体生效（子集内名字 = 一个字形）', p0.inSet > 0 && p0.inSet <= 34, 'home=' + p0.inSet + 'px');
  chk('负对照成立（子集外名字 = 字面词）', p0.outSet > p0.inSet * 2, 'security=' + p0.outSet + 'px，' + (p0.outSet / Math.max(p0.inSet, 1)).toFixed(1) + ' 倍');
  chk('组件内部解析到符号字体', /Material Symbols/i.test(p0.fam), p0.fam || '没找到');
  chk('画出来的图标都有对应字体面（没有族名落空）', !p0.missFam,
    p0.missFam ? '落空: ' + p0.missFam : '已声明: ' + p0.declared);

  /* 长按底栏活动圆 → 横向拖到第二格 → 松手切页。用真实鼠标事件走
     pointerdown/move/up，不是直接 dispatch change —— 那样测不到手势。 */
  {
    const pts = await ev(`(function(){ var n=document.getElementById('nav');
      var a=n.children[0].querySelector('.nav-halo').getBoundingClientRect();
      var b=n.children[1].getBoundingClientRect();
      return { x1:Math.round(a.left+a.width/2), y1:Math.round(a.top+a.height/2),
        x2:Math.round(b.left+b.width/2), y2:Math.round(b.top+b.height/2) }; })()`);
    await send('Input.dispatchMouseEvent', { type: 'mousePressed', x: pts.x1, y: pts.y1, button: 'left', clickCount: 1 });
    await sleep(30);
    await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: pts.x2, y: pts.y2, button: 'left', buttons: 1 });
    await sleep(80);
    await send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: pts.x2, y: pts.y2, button: 'left', clickCount: 1 });
    await sleep(800);
    const pd = await ev(PROBE);
    chk('直接拖活动圆到第二格 → 切页（无需长按）', pd.title === '功能', '标题=' + pd.title);
    chk('拖拽后没有残留 ghost', (await ev(`document.querySelectorAll('.nav-ghost').length`)) === 0);
    await ev(`(function(){ var n=document.getElementById('nav');
      n.dispatchEvent(new CustomEvent('change',{detail:{index:0},bubbles:true})); return 1; })()`);
    await sleep(700);
  }

  console.log('── 逐页驱动（真的点导航）──');
  /* 切页三件事一起量，都是用户在手机上真正会感觉到的：
       ① 底栏（md-navigation-bar）在切页前后的 rect 会不会变 —— "点底栏时底栏上下跳"
          那类 bug 只在切页瞬间出现，静态截图看不出来；
       ② 切过去是不是停在页首（scrollTop 必须回 0，否则你会落在上页滚到的位置）；
       ③ 二次进入同一页要多久（数据已缓存，这条最接近真机上点底栏的手感）。 */
  const navRects = [];
  const switchMs = [];
  for (let i = 0; i < PAGES.length; i++) {
    const want = PAGES[i];
    if (i === 3) {
      /* 设置页的自检卡曾经推迟一帧挂：进场第一帧只有外观卡，随后页面从
         243px 长到 641px。切页与采样放在同一个任务里，逐帧量页面高度。 */
      const hs = await ev(`new Promise(function(res){ var t0=performance.now(), out=[];
        var n=document.getElementById('nav');
        n.dispatchEvent(new CustomEvent('change',{detail:{index:3},bubbles:true}));
        function step(){ var p=document.querySelector('#view > .page');
          if (p) out.push(Math.round(p.getBoundingClientRect().height));
          if (performance.now()-t0 < 350) requestAnimationFrame(step); else res(out); }
        requestAnimationFrame(step); })`);
      const span = hs && hs.length ? Math.max.apply(null, hs) - Math.min.apply(null, hs) : 999;
      chk('设置页进场后不再长高（外观与自检同帧画完）',
        hs && hs.length >= 5 && span <= 2, 'h=' + (hs || []).slice(0, 6).join('/') + '… 跨度 ' + span + 'px');
    } else {
      await ev(`(function(){ var n=document.getElementById('nav');
        n.dispatchEvent(new CustomEvent('change',{detail:{index:${i}},bubbles:true})); return 1; })()`);
    }
    if (i === 1) {
      const an = await ev(`(function(){ var p=document.querySelector('#view > .page');
        if (!p) return null; var s=getComputedStyle(p);
        return { cls:p.classList.contains('page-in'), name:s.animationName, dur:s.animationDuration,
          title:!!p.querySelector('.page-title'), dx:p.style.getPropertyValue('--page-dx') }; })()`);
      chk('切页有入场动画，标题/内容一起动', !!an && an.cls && an.name === 'page-in'
        && parseFloat(an.dur) > 0 && an.title && Math.abs(parseFloat(an.dx)) > 0,
        an ? an.name + ' ' + an.dur + ' · title=' + an.title + ' dx=' + an.dx : '没读到');
    }
    await sleep(900);
    const p = await ev(PROBE);
    const miss = want.must.filter(s => p.text.indexOf(s) < 0);
    const ok = p.title === want.title && !miss.length && p.scrollW - p.vw <= 0
      && !p.missFam && (!want.items || p.items > 0);
    if (!ok) bad++;
    console.log(`${ok ? 'ok  ' : '✗   '} 第 ${i} 格 → ${want.title}  标题=${p.title} 列表项=${p.items} 溢出=${p.scrollW - p.vw}px`
      + (miss.length ? '  缺区块: ' + miss.join('、') : '')
      + (p.missFam ? '  字体落空: ' + p.missFam : ''));

    /* 量"二次进入"：先切走再切回来，此时数据已在 S 里，量到的就是渲染本身 */
    await ev(`(function(){ var n=document.getElementById('nav');
      n.dispatchEvent(new CustomEvent('change',{detail:{index:${(i + 1) % PAGES.length}},bubbles:true})); return 1; })()`);
    await sleep(120);
    const m = await ev(`(function(){ return new Promise(function(res){
      var n = document.getElementById('nav');
      var before = n.getBoundingClientRect();
      var t0 = performance.now();
      n.dispatchEvent(new CustomEvent('change',{detail:{index:${i}},bubbles:true}));
      var sync = performance.now() - t0;      /* 同步渲染：我们的 draw() 本身 */
      requestAnimationFrame(function(){ requestAnimationFrame(function(){
        var after = n.getBoundingClientRect();
        var view = document.getElementById('view');
        res({ ms: Math.round(performance.now() - t0), syncMs: Math.round(sync),
              topBefore: +before.top.toFixed(1), topAfter: +after.top.toFixed(1),
              hBefore: +before.height.toFixed(1), hAfter: +after.height.toFixed(1),
              scrollTop: view ? Math.round(view.scrollTop) : -1,
              nodes: document.querySelectorAll('#view *').length });
      });});
    }); })()`);
    navRects.push([m.topBefore, m.topAfter, m.hBefore, m.hAfter]);
    switchMs.push([want.id, m.ms, m.nodes, m.syncMs]);
    const stable = m.topBefore === m.topAfter && m.hBefore === m.hAfter;
    const atTop = m.scrollTop === 0;
    if (!stable || !atTop) bad++;
    console.log(`     ${stable ? 'ok  ' : '✗   '} 底栏不跳  y ${m.topBefore}→${m.topAfter} · 高 ${m.hBefore}→${m.hAfter}`
      + `  ${atTop ? 'ok  ' : '✗   '} 停在页首 scrollTop=${m.scrollTop}`
      + `  ·  二次进入 ${m.ms}ms（同步 ${m.syncMs}ms）/ ${m.nodes} 节点`);
    /* 上面刚做了一次“切走再切回”的计时，标签还在 0.26s 的展开过渡里；
       截图等它落定，否则会拍到上一条的半个字（台架截图不是运行时状态）。 */
    await sleep(320);
    const shot = await send('Page.captureScreenshot', { format: 'png' });
    fs.writeFileSync(path.join(SHOT_DIR, 'new-' + want.id + '.png'), Buffer.from(shot.data, 'base64'));
  }
  {
    const ys = navRects.map(r => r[0]).concat(navRects.map(r => r[1]));
    const hs = navRects.map(r => r[2]).concat(navRects.map(r => r[3]));
    const dy = Math.max(...ys) - Math.min(...ys);
    const dh = Math.max(...hs) - Math.min(...hs);
    chk('底栏几何在整个切页过程里恒定', dy === 0 && dh === 0, `y 范围 ${dy}px · 高范围 ${dh}px`);
    const slow = switchMs.filter(s => s[1] > 400);
    chk('二次进入没有超过 400ms 的页', slow.length === 0,
      switchMs.map(s => `${s[0]}=${s[1]}ms/${s[2]}节点`).join(' '));
  }
  /* ── 深浅：MD3E 的暗色盘挂在 [data-theme=dark]，只设 color-scheme 一个颜色都不翻 ──
     demo 的 env 报 sys_dark=1，所以"env 落地后重涂过"的直接证据就是整页进了暗色盘。
     再点设置里的「浅色」翻回去 —— attribute 与 surface 必须一起动，证明 attribute
     真的在驱动调色盘，而不是碰巧同值；最后点回「跟随系统」，sys_dark=1 应当赢。 */
  {
    const surf = () => ev(`(function(){ return { t: document.documentElement.getAttribute('data-theme'),
      s: getComputedStyle(document.body).backgroundColor }; })()`);
    /* md-button / md-chip 都可能吞合成 click（列表行那类行为），统一走 CDP 可信点击 */
    const press = async label => {
      const pos = await ev(`(function(){
        var bs=[].slice.call(document.querySelectorAll('#view md-button, #view md-chip'));
        /* md-button 的画法文本在 textContent；md-chip 只认 label 属性（槽里不写文本） */
        var b=bs.filter(function(x){var t=(x.textContent||'').trim(); return t===${JSON.stringify(label)} || (x.getAttribute('label')||'')===${JSON.stringify(label)};})[0];
        if(!b) return null; var r=b.getBoundingClientRect();
        return { x: Math.round(r.left + r.width/2), y: Math.round(r.top + r.height/2) }; })()`);
      if (!pos) return 0;
      await send('Input.dispatchMouseEvent', { type: 'mousePressed', x: pos.x, y: pos.y, button: 'left', clickCount: 1 });
      await send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: pos.x, y: pos.y, button: 'left', clickCount: 1 });
      return 1;
    };
    const dk = await surf();
    chk('env 报 sys_dark=1 → 界面真的进了暗色盘（data-theme=dark）', dk.t === 'dark', JSON.stringify(dk));
    const pressed = await press('浅色');
    const lt = await surf();
    chk('点「浅色」→ attribute 与 surface 一起翻回亮色',
      pressed === 1 && lt.t === 'light' && lt.s !== dk.s, JSON.stringify(lt));
    const back = await press('跟随系统');
    const au = await surf();
    chk('点回「跟随系统」→ sys_dark=1 赢，仍是暗色', back === 1 && au.t === 'dark' && au.s === dk.s, JSON.stringify(au));
  }
  /* ── 安全区：管理器注入的是**自定义属性** --safe-area-inset-*，不是 env() ──
     往 :root 塞一个假 inset：顶栏必须跟着长高（让位 padding 在吃这个值），
     且宿主自身有底色（组件把颜色画在 shadow 的 .bar 上，宿主透明的话
     padding 那条就是透明带 —— 2026-10-30 上机"状态栏缺一块"的症状）。 */
  {
    const wrapInfo = () => ev(`(function(){ var w=document.getElementById('barwrap'), b=document.getElementById('bar');
      var wr=w.getBoundingClientRect(), br=b.getBoundingClientRect(), cs=getComputedStyle(w);
      return { wrapH: Math.round(wr.height), barH: Math.round(br.height), bg: cs.backgroundColor }; })()`);
    const before = await wrapInfo();
    /* demo 的 env 报 sys_statusbar_dp=28、注入 insets 为 0 —— 让位必须由外层
       包壳给出，顶栏组件自己保持原生 64px（在组件宿主上改 padding/min-height
       会把它内部的行定位算错，上机实测标题被自己的裁切框切掉上沿）。 */
    const fallback = await ev(`getComputedStyle(document.documentElement).getPropertyValue('--statusbar-fallback').trim()`);
    chk('状态栏兜底生效（注入 insets 为 0 时按系统栏高度让位）',
      fallback === '28px' && before.wrapH === 92 && before.barH === 64,
      'fallback=' + fallback + ' wrap=' + before.wrapH + ' bar=' + before.barH);
    await ev(`(function(){ document.documentElement.style.setProperty('--safe-area-inset-top','60px'); return 1; })()`);
    const grown = await wrapInfo();
    await ev(`(function(){ document.documentElement.style.removeProperty('--safe-area-inset-top'); return 1; })()`);
    const after = await wrapInfo();
    chk('注入值更大时取注入值（60px 赢过兜底 28px），组件高度不变',
      grown.wrapH === 124 && grown.barH === 64, `wrap=${grown.wrapH} bar=${grown.barH}`);
    chk('包壳有底色（让位那条不是透明带）', before.bg !== 'rgba(0, 0, 0, 0)' && before.bg !== 'transparent', before.bg);
    chk('拿掉假 inset 后回兜底高度', after.wrapH === before.wrapH, `after=${after.wrapH} before=${before.wrapH}`);
    /* 悬浮药丸不是靠 padding-bottom 长高，而是整体抬离手势条：
       注入了 --safe-area-inset-bottom 时，药丸的底边应再上移同样的距离。 */
    const navInfo = () => ev(`(function(){ var n=document.getElementById('nav'); var r=n.getBoundingClientRect(); var cs=getComputedStyle(n);
      return { h: Math.round(r.height), bottom: Math.round(window.innerHeight - r.bottom), bg: cs.backgroundColor }; })()`);
    const nb = await navInfo();
    await ev(`(function(){ document.documentElement.style.setProperty('--safe-area-inset-bottom','24px'); return 1; })()`);
    const ng = await navInfo();
    await ev(`(function(){ document.documentElement.style.removeProperty('--safe-area-inset-bottom'); return 1; })()`);
    chk('悬浮底栏吃得到注入的 --safe-area-inset-bottom 且宿主有底色',
      ng.bottom === nb.bottom + 24 && ng.h === nb.h && nb.bg !== 'rgba(0, 0, 0, 0)' && nb.bg !== 'transparent',
      `bottom ${nb.bottom}→${ng.bottom} h=${nb.h} bg=${nb.bg}`);
  }

  /* ── 动态配色：强调色要落到 MD3E 的角色上，不是库默认那支紫 ──────────
     demo 不带 seed：env 报 sys_seed_src=none → 走平台默认兜底 #4b5d8b（色相 ≈267°）；
     带 ?seed= 走 parseSeed → 映射，色相必须落到种子上。判据读的是**算出来的**
     --md-sys-color-primary 的色相数字，不是"看着像不像"。 */
  {
    const hueOf = s => { const m = /oklch\([\d.]+% [\d.]+ ([\d.]+)\)/.exec(s || ''); return m ? parseFloat(m[1]) : NaN; };
    const prim = async () => hueOf(await ev(`getComputedStyle(document.documentElement).getPropertyValue('--md-sys-color-primary')`));
    const pDefault = await prim();
    chk('动态配色生效（primary 被覆写成 oklch，不再验库默认值）', !isNaN(pDefault), 'H=' + pDefault);
    chk('无种子 → 平台默认强调色（#4b5d8b → 色相 ≈267°）', Math.abs(pDefault - 267.2) < 6, 'H=' + pDefault);
    await send('Page.navigate', { url: URL0 + '&seed=0xFFC00000' });
    await sleep(1800);
    const pSeed = await prim();
    chk('?seed=0xFFC00000 → primary 色相落到种子（红 ≈29°）', Math.abs(pSeed - 29) < 4, 'H=' + pSeed);
  }
  chk('无未捕获异常', errs.length === 0, errs.slice(0, 2).join(' | '));

  /* ── 二级页驱动：菜单页落地即用，长列表在点进去之后才画 ─────────────
     菜单行点开 → 顶栏出二级标题与返回箭头；返回箭头点回去 → 菜单复原。
     这是"长列表默认收进二级菜单"的运行时证据，静态闸看不到行为。
     注意点击方式：md-list-item 会吞掉合成 dispatchEvent/click()（探针实测
     监听器不响），必须用 CDP 的**可信点击** —— 这也正好更接近真手指。 */
  {
    const tap = async expr => {
      const pos = await ev(`(function(){ var e=${expr}; if(!e) return null; var r=e.getBoundingClientRect();
        return { x: Math.round(r.left + r.width/2), y: Math.round(r.top + Math.min(r.height/2, 44)) }; })()`);
      if (!pos) return 0;
      await send('Input.dispatchMouseEvent', { type: 'mousePressed', x: pos.x, y: pos.y, button: 'left', clickCount: 1 });
      await send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: pos.x, y: pos.y, button: 'left', clickCount: 1 });
      return 1;
    };
    const gotoFunc = () => ev(`(function(){ var n=document.getElementById('nav');
      n.dispatchEvent(new CustomEvent('change',{detail:{index:1},bubbles:true})); return 1; })()`);
    const headlineText = async () => (await ev(PROBE)).title;
    const tapEntry = kw => tap(`(function(){ var its=[].slice.call(document.querySelectorAll('#view md-list-item'));
      return its.filter(function(x){return (x.getAttribute('headline')||'').indexOf(${JSON.stringify(kw)})===0;})[0]; })()`);
    const tapBack = () => tap(`document.getElementById('bar').querySelector('md-icon-button[label="返回功能菜单"]')`);
    const backArrow = () => ev(`(function(){ var b=document.getElementById('bar');
      return b && b.querySelector('md-icon-button[label="返回功能菜单"]') ? 1 : 0; })()`);
    await gotoFunc(); await sleep(700);
    chk('菜单页没有返回箭头（它不是二级页）', await backArrow() === 0);
    /* 属性对照表进过属性页才读。没读过时摘要不能把未知报成"0 项对照"——
       那是个会一直停在屏上的错数，不是一闪而过。 */
    {
      const pf = await ev(PROBE);
      chk('功能菜单不把未读取的属性对照报成 0 项',
        !/0 项对照/.test(pf.text || ''),
        (pf.text.match(/开机写入[^|\n]*/g) || []).slice(0, 2).join(' / '));
    }
    chk('点「目标名单」真的进二级', await tapEntry('目标名单') === 1);
    /* 入场动画对长页面只做横向推入：整页 scale/translateY 以页中心为原点，
       名单上百行时视口顶部的标题会被带着上下跳几十像素（用户报的"突然拉高"）。
       这里在点进去后的 380ms 内逐帧量标题 top，必须是一条水平线。 */
    {
      const tops = await ev(`new Promise(function(res){ var t0=performance.now(), out=[];
        function step(){ var t=document.querySelector('#view .page-title');
          if (t) out.push(Math.round(t.getBoundingClientRect().top*10)/10);
          if (performance.now()-t0 < 380) requestAnimationFrame(step); else res(out); }
        requestAnimationFrame(step); })`);
      const span = tops && tops.length ? Math.max.apply(null, tops) - Math.min.apply(null, tops) : 999;
      chk('进入名单页时标题纵向稳定（长页入场不缩放/不纵向位移）',
        tops && tops.length >= 5 && span <= 2,
        'top=' + (tops || []).slice(0, 6).join('/') + '… 跨度 ' + span.toFixed(1) + 'px');
    }
    /* 预取的行为证据：进去后的第一帧只能是"载入占位"或"已带应用名"，
       不能先画包名、等图标到货再原位替换（用户看到的闪一下）。 */
    {
      const early = await ev(`(function(){
        if (document.querySelector('#view .load-card')) return { loading: 1 };
        var it = document.querySelector('#view .app-row[data-base="com.android.vending"]');
        return { loading: 0, head: it ? it.getAttribute('headline') : '' };
      })()`);
      chk('名单第一帧不闪包名（载入占位或已是应用名）',
        !!(early && (early.loading || early.head === 'Google Play 商店')), JSON.stringify(early));
    }
    await sleep(1600);
    const pT = await ev(PROBE);
    chk('二级页标题与返回箭头都在', (await headlineText()) === '目标名单' && await backArrow() === 1,
      '标题=' + (await headlineText()) + ' 箭头=' + (await backArrow()));
    chk('名单二级页画出了真实的数据行', pT.rows >= 2 && /目标文件：|这个后端接受的写法/.test(pT.text || ''),
      'rows=' + pT.rows + '（这两行 hint 的值来自 backend-info，空壳画不出）');
    chk('名单一次画全（没有分批挂载的"已显示 N"）',
      pT.rows >= 2 && !/已显示\s*\d+/.test(pT.text || ''), 'rows=' + pT.rows);
    {
      const gap = await ev(`(function(){ var tf=document.querySelector('#view md-text-field'),
        l=document.querySelector('#view .app-list'); if(!tf||!l) return null;
        var a=tf.getBoundingClientRect(), b=l.getBoundingClientRect();
        return Math.round(b.top - a.bottom); })()`);
      chk('搜索框与名单之间有分组间距（不同类版块不紧贴）',
        gap != null && gap >= 18, gap == null ? '没找到搜索框或名单' : gap + 'px');
    }
    {
      const mono = await ev(`(function(){ var s=document.querySelector('#view .app-row[data-mono] .app-row-sub');
        return s ? getComputedStyle(s).fontFamily : ''; })()`);
      chk('包名等技术值走等宽字', /mono/i.test(mono), mono || '没找到等宽 supporting 行');
    }
    /* 搜索：真实敲两个字，输入框不能被换掉/丢焦点；清空后复原。 */
    {
      await ev(`(function(){ var tf=document.querySelector('#view md-text-field'); if(!tf) return 0;
        tf.__klMark=1; tf.focus(); var inp=tf.shadowRoot&&tf.shadowRoot.querySelector('input'); if(inp) inp.focus(); return 1; })()`);
      await send('Input.insertText', { text: 'mi' });
      await sleep(280);
      const se = await ev(`(function(){ var tf=document.querySelector('#view md-text-field');
        var rows=[].slice.call(document.querySelectorAll('#view .app-row')).map(function(r){return r.getAttribute('headline');});
        return { same: !!(tf && tf.__klMark), val: tf?tf.value:'', active: document.activeElement?document.activeElement.tagName:'', rows: rows }; })()`);
      chk('搜索输入不丢焦点/不被换掉，结果按行过滤',
        se.same && se.val === 'mi' && se.active === 'MD-TEXT-FIELD' && se.rows.length === 1 && se.rows[0] === 'Mihon',
        JSON.stringify(se));
      for (let i = 0; i < 2; i++) {
        await send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Backspace', code: 'Backspace', windowsVirtualKeyCode: 8, nativeVirtualKeyCode: 8 });
        await send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Backspace', code: 'Backspace', windowsVirtualKeyCode: 8, nativeVirtualKeyCode: 8 });
      }
      await sleep(280);
      const sb = await ev(`(function(){ var tf=document.querySelector('#view md-text-field');
        return { val: tf?tf.value:'', rows: document.querySelectorAll('#view .app-row').length }; })()`);
      chk('清空搜索后名单复原', sb.val === '' && sb.rows >= 2, JSON.stringify(sb));
    }
    /* 芯片切视图：行数变，选中态跟着走；再切回名单供后面的对照。 */
    {
      const tapChip = kw => tap(`(function(){ var cs=[].slice.call(document.querySelectorAll('#view md-chip'));
        return cs.filter(function(c){return (c.getAttribute('label')||'').indexOf(${JSON.stringify(kw)})===0;})[0]; })()`);
      chk('点「已装」芯片能切视图', await tapChip('已装') === 1);
      await sleep(400);
      const cv = await ev(`(function(){ var cs=[].slice.call(document.querySelectorAll('#view md-chip'));
        function sel(k){ return cs.filter(function(c){return (c.getAttribute('label')||'').indexOf(k)===0;}).map(function(c){return c.hasAttribute('selected');})[0]; }
        return { rows: document.querySelectorAll('#view .app-row').length, apps: sel('已装'), targets: sel('名单') }; })()`);
      chk('芯片选中态跟着走，行数切到已装', cv.rows === 4 && cv.apps === true && cv.targets === false, JSON.stringify(cv));
      await tapChip('名单');
      await sleep(400);
    }
    const captureRows = () => ev(`(function(){ var out=[];
      [].slice.call(document.querySelectorAll('#view .app-row[data-base]')).slice(0, 5).forEach(function(it){
        out.push([it.getAttribute('headline')||'', it.getAttribute('supporting-text')||'']); });
      return out; })()`);
    const rows1 = await captureRows();
    await tapBack();
    await sleep(500);
    await tapEntry('目标名单');
    await sleep(1200);
    const rows2 = await captureRows();
    chk('第一次进入与第二次进入的名单文字一致（图标到货后标题要原位更新）',
      JSON.stringify(rows1) === JSON.stringify(rows2),
      '第一次 ' + JSON.stringify(rows1).slice(0, 100) + ' / 第二次 ' + JSON.stringify(rows2).slice(0, 100));
    await tapBack();
    await sleep(500);
    chk('返回箭头把人送回菜单', (await headlineText()) === '功能' && /目标名单/.test((await ev(PROBE)).text || ''));
    /* 属性伪装页：列表 → 两按钮 → 属性列表 → 列表 → 输入框 → 保存。
       用户点名"按钮贴属性列表、输入框贴应用值"；这里直接量四段异类间距。 */
    chk('点「属性伪装」进二级', await tapEntry('属性伪装') === 1);
    await sleep(900);
    {
      const pg = await ev(`(function(){
        var ls=[].slice.call(document.querySelectorAll('#view md-list'));
        var as=[].slice.call(document.querySelectorAll('#view .acts'));
        var tf=document.querySelector('#view md-text-field');
        if (ls.length < 3 || as.length < 2 || !tf) return null;
        var r=function(e){ return e.getBoundingClientRect(); };
        return { above: Math.round(r(as[0]).top - r(ls[0]).bottom),
          below: Math.round(r(ls[1]).top - r(as[0]).bottom),
          input: Math.round(r(tf).top - r(ls[2]).bottom),
          save: Math.round(r(as[1]).top - r(tf).bottom) };
      })()`);
      chk('属性伪装的按钮与上下两段列表都分开',
        !!pg && pg.above >= 18 && pg.below >= 18,
        pg ? '上 ' + pg.above + 'px / 下 ' + pg.below + 'px' : '没找到列表或按钮');
      chk('Verified Boot 输入框与应用值列表、保存按钮都分开',
        !!pg && pg.input >= 18 && pg.save >= 12,
        pg ? '列表→输入 ' + pg.input + 'px / 输入→保存 ' + pg.save + 'px' : '没找到输入框');
      /* 属性页的**行数与状态**必须对着真形状核。这一屏以前只喂过 5 行手写假数据
         （ro.product.brand / ro.serialno 根本不在表里），所以命令层新增的第四种状态
         absent 会掉进界面"不是 ok 就算不符"的 else 里 —— 画成红色「不符」，标题写
         「13 项不符」，而命令层报的是 mismatch=0。这种错只有真画一次才现形。 */
      const pv = await ev(`(function(){
        /* 文字在属性里，不在 textContent 里（本文件上面第 90 行同一条读法）——
           拿 textContent 数会得到 rows=0，看着像"界面没画"，其实是探针瞎了。 */
        var items = [].slice.call(document.querySelectorAll('#view md-list-item'));
        var txt = function(i){ return (i.getAttribute('headline')||'') + '|' +
          (i.getAttribute('supporting-text')||'') + '|' + (i.getAttribute('trailing-text')||''); };
        var rows = 0, absent = 0, bad = 0, absentToned = 0;
        items.forEach(function(i){ var t = txt(i);
          /* 数"属性行"要认**两种**文案（期望… / 这台机没有…）：只认"期望"的话，
             改一次 absent 的措辞就会把 4 行数丢，看着像界面少画了行。 */
          var sup = i.getAttribute('supporting-text') || '';
          if (/^期望 /.test(sup) || /^这台机没有这项属性/.test(sup)) rows++;
          if (t.indexOf('本机无') >= 0) { absent++; if (i.getAttribute('data-tone')) absentToned++; }
          if (t.indexOf('|不符') >= 0) bad++;
        });
        var bar = document.getElementById('bar');
        var title = '';
        items.forEach(function(i){ var h = i.getAttribute('headline')||'';
          if (/^系统属性 · /.test(h)) title = h; });
        var t0 = (document.getElementById('view')||{}).textContent || '';
        var m = t0.match(/系统属性 · ([^\\n]*)/);
        if (!title && m) title = m[1];
        return { rows: rows, absent: absent, bad: bad, absentToned: absentToned, title: title, items: items.length };
      })()`);
      chk('属性页把台架那 53 行对照逐行画出来（一行都不吞）', pv.rows === 53, 'rows=' + pv.rows);
      chk('absent 标「本机无」而不是红色「不符」（命令层 mismatch=0 的口径）',
        pv.absent === 4 && pv.bad === 9, 'absent=' + pv.absent + ' 不符行=' + pv.bad);
      chk('absent 行不挂 warn/bad 色（"没有这个分区"不是待办也不是风险）',
        pv.absentToned === 0, 'absentToned=' + pv.absentToned);
      chk('标题只数 diff/missing（9 项不符），不把 absent 算进去',
        /^9 项不符/.test(pv.title), 'title=' + pv.title);
      /* 启动哈希那一格的三态必须各画各的：auto（新用户默认形状）、random（取不到）、
         manual（用户填过）、off（明确不写）、invalid（配置坏了）。
         旧版界面只有"填了/没填"两态，命令层改成三态后如果界面不动，新用户会看到
         "未设置（不写 vbmeta.digest）"——而实际上 digest 已经写进去了。 */
      const openProps = async (q) => {
        await send('Page.navigate', { url: URL0 + q });
        await sleep(1400);
        await ev(`(function(){ var n=document.getElementById('nav');
          n.dispatchEvent(new CustomEvent('change',{detail:{index:1},bubbles:true})); return 1; })()`);
        await sleep(450);
        await tapEntry('属性伪装');
        await sleep(1100);
        return ev(`(function(){
          var out = [];
          document.querySelectorAll('#view md-list-item').forEach(function(i){
            out.push(((i.getAttribute('headline')||'') + '|' + (i.getAttribute('supporting-text')||'')));
          });
          var btns = [];
          document.querySelectorAll('#view md-button').forEach(function(b){ btns.push((b.getAttribute('label')||b.textContent||'').trim()); });
          var tf = document.querySelector('#view md-text-field');
          return { rows: out.join('\\n'), buttons: btns.join(','), tfv: tf ? String(tf.value) : null };
        })()`);
      };
      const bhAuto = await openProps('&bh=auto');
      chk('auto 档界面说"自动 · 取自 OhMyKeymint"并印出派生值',
        /自动 · 取自OhMyKeymint/.test(bhAuto.rows) && /1122334455667788/.test(bhAuto.rows), bhAuto.rows.split('\n').filter(l => /模块应用值/.test(l)).join(''));
      chk('界面给出三个动作：保存并应用 / 改为自动 / 不写 digest',
        /保存并应用/.test(bhAuto.buttons) && /改为自动/.test(bhAuto.buttons) && /不写 digest/.test(bhAuto.buttons), bhAuto.buttons);
      const bhDaemon = await openProps('&bh=daemon');
      /* daemon = TEESim 那一支：属性里那串是守护进程自己强制的（App.kt:516-523），
         模块采用它而不是覆盖。界面必须说清"取的是它正在证明的值"，不能读成"本模块写的"，
         也不能退回成 omk 那句 —— 那会让人以为换了后端也还是同一套来源。 */
      chk('TEESim 那一支（daemon）说"取自…正在证明的值…不覆盖"，不冒用 OMK 那句',
        /自动 · 取自TEE Simulator 正在证明的值/.test(bhDaemon.rows) && !/取自OhMyKeymint/.test(bhDaemon.rows),
        bhDaemon.rows.split('\n').filter(l => /模块应用值/.test(l)).join(''));
      const bhRandom = await openProps('&bh=random');
      chk('random（取不到）说清"没有可取的固定值，所以不写"，不谎报已应用',
        /没有可取的固定值/.test(bhRandom.rows) && !/1122334455667788/.test(bhRandom.rows), '');
      const bhManual = await openProps('&bh=manual');
      chk('manual 档把用户填的值显示出来，输入框也带着它',
        /1122334455667788/.test(bhManual.rows) && /^11223344/.test(bhManual.tfv || ''), 'tf=' + bhManual.tfv);
      const bhOff = await openProps('&bh=off');
      chk('off 档说"按你的设置不写 digest"，不是"未设置"',
        /按你的设置不写 digest/.test(bhOff.rows), '');
      const bhBad = await openProps('&bh=invalid');
      chk('invalid 档直说配置坏了（不是 64/128 位十六进制）',
        /不是 64\/128 位十六进制/.test(bhBad.rows), '');
      await openProps('');
      const pv2 = await ev(`(function(){ return { rows: document.querySelectorAll('#view md-list-item').length }; })()`);
      chk('回到默认（auto）后属性页仍是完整一屏（切档不吞行）', pv2.rows > 50, 'rows=' + pv2.rows);
      const shotP = await send('Page.captureScreenshot', { format: 'png' });
      fs.writeFileSync(path.join(SHOT_DIR, 'new-props.png'), Buffer.from(shotP.data, 'base64'));
      /* 再存一张尾部图：53 行的头几行永远是 ok，absent / diff 那几行在中间与尾部。
         只看头图会把"新状态画成什么样"这件事整个漏掉 —— 本轮的 absent 标红缺陷
         就藏在尾部，头图看着一切正常。 */
      await ev(`(function(){ var it=[].slice.call(document.querySelectorAll('#view md-list-item'));
        var last=it[it.length-1]; if(last) last.scrollIntoView({block:'end'}); return 1; })()`);
      await sleep(400);
      const shotT = await send('Page.captureScreenshot', { format: 'png' });
      fs.writeFileSync(path.join(SHOT_DIR, 'new-props-tail.png'), Buffer.from(shotT.data, 'base64'));
      await ev('window.scrollTo(0, 0)');
      await sleep(300);
      /* 长页阅读模式：向下滑 → 药丸下沉缩小消失；向上滑/回顶 → 回来 */
      const navState = () => ev(`(function(){ var n=document.getElementById('nav'); var s=getComputedStyle(n);
        return { hidden:n.classList.contains('nav-hidden'), op:s.opacity, pe:s.pointerEvents,
          scroll:Math.round(window.scrollY), long:document.documentElement.scrollHeight > window.innerHeight + 160 }; })()`);
      await ev('window.scrollTo(0, 420)');
      await sleep(350);
      const navH = await navState();
      chk('长页下滑后底栏收缩消失', navH.hidden && navH.op === '0' && navH.pe === 'none',
        'scroll=' + navH.scroll + ' long=' + navH.long + ' op=' + navH.op + ' pe=' + navH.pe);
      await ev('window.scrollTo(0, 0)');
      await sleep(350);
      const navS = await navState();
      chk('回到顶部底栏回来', !navS.hidden && navS.op === '1',
        'scroll=' + navS.scroll + ' op=' + navS.op);
    }
    await tapBack(); await sleep(400);
    /* keybox 二级页单验一条：换 keybox 作废旧密钥的警告必须画出来 */
    chk('点「密钥箱 keybox」进二级', await tapEntry('密钥箱 keybox') === 1);
    await sleep(900);
    const pK = await ev(PROBE);
    chk('keybox 二级页有换箱代价的警告', (await headlineText()) === 'keybox'
      && /旧密钥全部作废|替换 keybox/.test(pK.text || ''), '标题=' + (await headlineText()));
    await tapBack(); await sleep(500);
  }

  /* ── 逐后端驱动：三家各自的能力面只在 backend=<家> 时才画得出来 ──────
     上一版只跑默认那一家（omk），Tricky 分支里 `t.teeBroken` 读错键名
     一路绿到上线前都没人看见 —— 假数据与代码互相自证，两边一起错。
     must 里除了区块标题，还钉了**只有真读了那个键才会出现的值**。 */
  const BACKENDS = [
    { id: 'tricky', q: 'tricky', must: ['TEE 探测结果', '补丁级别', 'keystore2_unavailable',
      '自动条目现在走', '不匹配', '上次探测：TEE 不可用', 'target.txt',
      /* 这一句只有从 tee_broken 这个键读到值才会出现：键名一读回上游的
         小驼峰，这一家就画不出它 —— 静态闸抓键名，这条抓"真的画到屏上了"。 */
      '上游没给出探测结论',
      /* 补丁值的说明：这一句只在 Tricky 那条 hint 里，画出来才证明分叉的文案
         真的到了对应那一家的页面上。 */
      '整个组件标签不报'] , tail: '补丁级别' },
    { id: 'teesim', q: 'teesim', must: ['Profile 表', '编辑 profile · default',
      'overrides.json · 安全等级与版本',
      '报告 0', '模板令牌必须大写',
      /* overrides 表真画出值才算走到了非降级分支：以前假数据的命令清单里
         漏了 teesim-overrides，hasCmd() 恒 false，这张卡永远显示"命令层没有这条"，
         而台架只看区块标题，照样绿。 */
      /* overrides 现在要能**写**：可编辑的那几条变成表单控件（字段名不再原样出现在
         屏上，标签是中文），锁死的那几条仍是列表行 —— 两边各钉一个只有真读到
         假数据才会出现的值。 */
      'attestation 侧安全等级', '留空 = 删掉这一项', 'TrustedEnvironment', '只记录，不上线',
      'deviceLocked', 'supplement', '本模块不提供写入'] , tail: 'overrides.json ·' },
    { id: 'omk', q: 'omk', must: ['运行状态', 'keymint 守护进程', 'injector 守护进程', 'keystore2 注入', '已注入',
      'config.toml · 信任链与设备身份', 'injector.toml · 名单与路由', 'injector.toml'],
      tail: 'config.toml ·' },
  ];
  console.log('── 逐后端驱动（换 ?backend= 重新载入，画那一家的块）──');
  const tapEntry = async kw => {
    const pos = await ev(`(function(){ var its=[].slice.call(document.querySelectorAll('#view md-list-item'));
      var it=its.filter(function(x){return (x.getAttribute('headline')||'').indexOf(${JSON.stringify(kw)})===0;})[0];
      if(!it) return null; var r=it.getBoundingClientRect();
      return { x: Math.round(r.left + r.width/2), y: Math.round(r.top + Math.min(r.height/2, 44)) }; })()`);
    if (!pos) return 0;
    await send('Input.dispatchMouseEvent', { type: 'mousePressed', x: pos.x, y: pos.y, button: 'left', clickCount: 1 });
    await send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: pos.x, y: pos.y, button: 'left', clickCount: 1 });
    return 1;
  };
  for (const b of BACKENDS) {
    await send('Page.navigate', { url: URL0 + '&backend=' + b.q });
    await sleep(1400);
    /* 各家配置面在【功能】→「后端配置」二级页里：先到菜单（index 1）再点进去 */
    await ev(`(function(){ var n=document.getElementById('nav');
      n.dispatchEvent(new CustomEvent('change',{detail:{index:1},bubbles:true})); return 1; })()`);
    await sleep(700);
    await tapEntry('后端配置');
    await sleep(900);
    const p = await ev(PROBE);
    const miss = b.must.filter(s => p.text.indexOf(s) < 0);
    const ok = miss.length === 0 && p.scrollW - p.vw <= 0 && !p.missFam && p.items >= 4;
    if (!ok) bad++;
    console.log(`${ok ? 'ok  ' : '✗   '} 后端 ${b.id}  列表项=${p.items} 溢出=${p.scrollW - p.vw}px`
      + (miss.length ? '  没画出来: ' + miss.join('、') : '')
      + (p.missFam ? '  字体落空: ' + p.missFam : ''));
    const shot = await send('Page.captureScreenshot', { format: 'png' });
    fs.writeFileSync(path.join(SHOT_DIR, 'new-backend-' + b.id + '.png'), Buffer.from(shot.data, 'base64'));
    /* 页尾那张卡（overrides / tee_status / config.toml）在首屏之外 —— 再滚过去截一张，
       不然"画出来了"只有判词、没有能看的东西。 */
    const scrolled = await ev(`(function(){ var els=[].slice.call(document.querySelectorAll('#view md-card'));
      var t=els.filter(function(e){return (e.textContent||'').indexOf(${JSON.stringify(b.tail || '')})>=0;})[0];
      if (t) t.scrollIntoView(true); return t?1:0; })()`);
    if (scrolled) {
      await sleep(400);
      const s2 = await send('Page.captureScreenshot', { format: 'png' });
      fs.writeFileSync(path.join(SHOT_DIR, 'new-backend-' + b.id + '-tail.png'), Buffer.from(s2.data, 'base64'));
    }
    /* Tricky 名单行尾的「自动 →」要 tee_status 才能判定：只有首进名单时就把
       tee-status 和 lists 一起取到，才会显示"不匹配"而不是"未探测"。 */
    if (b.id === 'tricky') {
      const back = await ev(`(function(){ var br=document.getElementById('bar');
        var e=br && br.querySelector('md-icon-button[label="返回功能菜单"]'); if(!e) return null;
        var r=e.getBoundingClientRect(); return { x:Math.round(r.left+r.width/2), y:Math.round(r.top+r.height/2) }; })()`);
      if (back) {
        await send('Input.dispatchMouseEvent', { type: 'mousePressed', x: back.x, y: back.y, button: 'left', clickCount: 1 });
        await send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: back.x, y: back.y, button: 'left', clickCount: 1 });
        await sleep(500);
      }
      await tapEntry('目标名单');
      await sleep(900);
      const pt = await ev(PROBE);
      chk('Tricky 名单的「自动→」首进就判定（tee_status 与名单一起取）',
        /自动 → 不匹配/.test(pt.text || '') && !/未探测/.test(pt.text || ''),
        '屏上：' + ((pt.text.match(/自动 → [^|\n]*/g) || []).slice(0, 2).join(' / ')));
    }
  }

  /* OMK daemon 死掉的红态：真机上不能故意杀，只能造 —— 红态不验，等于只保证
     "正常时好看"，出了问题界面照样可能说人话。 */
  await send('Page.navigate', { url: URL0 + '&backend=omk&omk=dead' });
  await sleep(1400);
  await ev(`(function(){ var n=document.getElementById('nav');
    n.dispatchEvent(new CustomEvent('change',{detail:{index:1},bubbles:true})); return 1; })()`);
  await sleep(700);
  await tapEntry('后端配置');
  await sleep(900);
  const pd = await ev(PROBE);
  chk('OMK daemon 死掉时运行状态卡报红（不冒充已注入）',
    pd.text.indexOf('未运行') >= 0 && pd.text.indexOf('未注入') >= 0
    && pd.text.indexOf('已注入') < 0 && pd.text.indexOf('有状态不正常') >= 0,
    '屏上命中：' + ((pd.text.match(/未运行|已注入|未注入|有状态不正常/g) || []).join('、')));
  {
    const sD = await send('Page.captureScreenshot', { format: 'png' });
    fs.writeFileSync(path.join(SHOT_DIR, 'new-omk-dead.png'), Buffer.from(sD.data, 'base64'));
  }

  /* 读失败与"真的是空的"必须长得不一样 */
  await send('Page.navigate', { url: URL0 + '&backend=tricky&fail=targets' });
  await sleep(1400);
  /* 名单在【功能】→「目标名单」二级页里：错误行要钉在那张卡的第一行 */
  await ev(`(function(){ var n=document.getElementById('nav');
    n.dispatchEvent(new CustomEvent('change',{detail:{index:1},bubbles:true})); return 1; })()`);
  await sleep(700);
  await tapEntry('目标名单');
  await sleep(900);
  const pf = await ev(PROBE);
  const hasErr = pf.text.indexOf('名单读不到') >= 0;
  const hasEmpty = pf.text.indexOf('这一类现在是空的') >= 0;
  chk('目标文件缺失报成错误，不是"这一类是空的"', hasErr && !hasEmpty,
    '错误行 ' + (hasErr ? '在' : '缺') + ' · 空态文案 ' + (hasEmpty ? '还在（等于自相矛盾）' : '已让位'));
  const shotF = await send('Page.captureScreenshot', { format: 'png' });
  fs.writeFileSync(path.join(SHOT_DIR, 'new-readfail.png'), Buffer.from(shotF.data, 'base64'));

  /* 旧格式 tee_status（只有一行 teeBroken=，TrickyStore 原版与 OSS v3.1.0 都这样）：
     AUTO 的去向必须按 teeBroken 算出来 —— 真机上第一份四行格式之外的证据就是它。 */
  await send('Page.navigate', { url: URL0 + '&backend=tricky&tee=old' });
  await sleep(1400);
  await ev(`(function(){ var n=document.getElementById('nav');
    n.dispatchEvent(new CustomEvent('change',{detail:{index:1},bubbles:true})); return 1; })()`);
  await sleep(700);
  await tapEntry('后端配置');
  await sleep(900);
  const pt = await ev(PROBE);
  chk('旧版单行 tee_status → AUTO 仍能判出"证书生成"',
    (pt.text || '').indexOf('证书生成') >= 0 && (pt.text || '').indexOf('旧版 tee_status') >= 0,
    '缺「证书生成」或「旧版 tee_status」说明 —— 屏上 ' + JSON.stringify((pt.text || '').slice(-80)));
  {
    const sT = await send('Page.captureScreenshot', { format: 'png' });
    fs.writeFileSync(path.join(SHOT_DIR, 'new-tee-old.png'), Buffer.from(sT.data, 'base64'));
  }

  /* 互斥那一屏：真机上碰不到，只能造 —— 不造就没有任何证据它渲染得对。 */
  await send('Page.navigate', { url: URL0 + '&backend=tricky&conflict=1' });
  await sleep(1400);
  await ev(`(function(){ var n=document.getElementById('nav');
    n.dispatchEvent(new CustomEvent('change',{detail:{index:0},bubbles:true})); return 1; })()`);
  await sleep(900);
  const pc = await ev(PROBE);
  const mustC = ['三家后端', '抢同一个 keymint HAL，模块已经停在这里',
    'Tricky Store、TEE Simulator、OhMyKeymint', '已停止'];
  const missC = mustC.filter(s => pc.text.indexOf(s) < 0);
  chk('三家同时启用 → 矩阵点名是哪几家', missC.length === 0 && pc.scrollW - pc.vw <= 0,
    missC.length ? '没画出来: ' + missC.join('、') : '溢出 ' + (pc.scrollW - pc.vw) + 'px');
  const shotC = await send('Page.captureScreenshot', { format: 'png' });
  fs.writeFileSync(path.join(SHOT_DIR, 'new-conflict.png'), Buffer.from(shotC.data, 'base64'));
  /* 矩阵在页面中段，视口只有一屏 —— 滚到那张卡再截一张，人才看得到判词的依据 */
  await ev(`(function(){ var els=[].slice.call(document.querySelectorAll('#view md-card'));
    var t=els.filter(function(e){return (e.textContent||'').indexOf('同一时刻只能一家在跑')>=0;})[0];
    if (t) t.scrollIntoView(true); return t?1:0; })()`);
  await sleep(400);
  const shotC2 = await send('Page.captureScreenshot', { format: 'png' });
  fs.writeFileSync(path.join(SHOT_DIR, 'new-conflict-matrix.png'), Buffer.from(shotC2.data, 'base64'));

  /* 过渡加载页：把 icons 命令延后 900ms（?slow=icons），点进名单先看到骨架屏，
     数据到齐后换成完整名单 —— 等待时不是一小张转圈卡，也不会先画包名。 */
  await send('Page.navigate', { url: URL0 + '&slow=icons' });
  await sleep(1600);
  await ev(`(function(){ var n=document.getElementById('nav');
    n.dispatchEvent(new CustomEvent('change',{detail:{index:1},bubbles:true})); return 1; })()`);
  await sleep(600);
  await tapEntry('目标名单');
  await sleep(120);
  const sk = await ev(`(function(){ return {
    load: !!document.querySelector('#view .load-card'),
    rows: document.querySelectorAll('#view .sk-row').length,
    search: !!document.querySelector('#view .sk-search'),
    chips: document.querySelectorAll('#view .sk-chip').length,
    real: document.querySelectorAll('#view .app-row').length }; })()`);
  chk('名单首进先显示骨架加载页（不是一小张转圈卡）',
    sk.load && sk.rows >= 5 && sk.search && sk.chips >= 3 && sk.real === 0, JSON.stringify(sk));
  {
    const sS = await send('Page.captureScreenshot', { format: 'png' });
    fs.writeFileSync(path.join(SHOT_DIR, 'new-loading-skeleton.png'), Buffer.from(sS.data, 'base64'));
  }
  await sleep(1200);
  const sk2 = await ev(`(function(){ var it=document.querySelector('#view .app-row[data-base="com.android.vending"]');
    return { load: !!document.querySelector('#view .load-card'),
      rows: document.querySelectorAll('#view .app-row').length,
      head: it ? (it.getAttribute('headline')||'') : '' }; })()`);
  chk('骨架页在数据到齐后换成完整名单',
    !sk2.load && sk2.rows > 0 && sk2.head === 'Google Play 商店', JSON.stringify(sk2));

  /* 打开 WebUI 的启动页：把 env 延后 900ms（?slow=env），先看到品牌页；
     数据就绪后启动页淡出，主页已经在下面画好。 */
  await send('Page.navigate', { url: URL0 + '&slow=env' });
  await sleep(200);
  const bs = await ev(`(function(){ return { splash: !!document.querySelector('.boot-splash'),
    brand: !!document.querySelector('.boot-brand'), logo: !!document.querySelector('.boot-logo'),
    page: !!document.querySelector('#view > .page') }; })()`);
  chk('打开 WebUI 先显示品牌启动页', bs.splash && bs.brand && bs.logo, JSON.stringify(bs));
  {
    const sB = await send('Page.captureScreenshot', { format: 'png' });
    fs.writeFileSync(path.join(SHOT_DIR, 'new-boot-splash.png'), Buffer.from(sB.data, 'base64'));
  }
  await sleep(1600);
  const bs2 = await ev(`(function(){ return { splash: !!document.querySelector('.boot-splash'),
    page: !!document.querySelector('#view > .page'), cards: document.querySelectorAll('#view md-card').length }; })()`);
  chk('数据就绪后启动页淡出并露出主页',
    !bs2.splash && bs2.page && bs2.cards >= 2, JSON.stringify(bs2));

  /* 壳先出、数据后台填：把 status 延后（?slow=status），启动页淡出后主页那块位置是
     骨架屏而不是空屏；状态到齐才换成真主页。以前是"数据全齐才让壳出来"，
     命令层慢 1 秒就是空屏 1 秒。 */
  await send('Page.navigate', { url: URL0 + '&slow=status' });
  await sleep(220);
  const hs = await ev(`(function(){ return { hero: !!document.querySelector('#view .sk-hero'),
    stats: document.querySelectorAll('#view .sk-stat').length,
    rows: document.querySelectorAll('#view .sk-row').length,
    cards: document.querySelectorAll('#view md-card').length,
    empty: !document.querySelector('#view > .page') }; })()`);
  chk('契约一到就画壳：状态未到时主页位置已是骨架（不是空屏）',
    hs.hero && !hs.empty && hs.stats === 3 && hs.rows >= 3 && hs.cards === 0, JSON.stringify(hs));
  /* 再等到启动页真的开始淡出 —— DOM 里有骨架不等于屏上看得见。status 被延后到
     900ms，所以"淡出"与"骨架换成真页"之间还剩一段窗口，截图要落在那一段里。 */
  for (let i = 0; i < 14; i++) {
    const fading = await ev(`!!(!document.querySelector('.boot-splash') || document.querySelector('.boot-splash.out'))`);
    if (fading) break;
    await sleep(50);
  }
  await sleep(160);
  const hsShot = await ev(`(function(){ var s = document.querySelector('.boot-splash');
    return { hero: !!document.querySelector('#view .sk-hero'),
      cards: document.querySelectorAll('#view md-card').length,
      opacity: s ? getComputedStyle(s).opacity : '0' }; })()`);
  chk('启动页淡出那一刻屏上就是主页骨架（不是空屏）',
    hsShot.hero && hsShot.cards === 0 && Number(hsShot.opacity) < 0.6, JSON.stringify(hsShot));
  {
    const sH = await send('Page.captureScreenshot', { format: 'png' });
    fs.writeFileSync(path.join(SHOT_DIR, 'new-home-skeleton.png'), Buffer.from(sH.data, 'base64'));
  }
  await sleep(1000);
  const hs2 = await ev(`(function(){ return { hero: !!document.querySelector('#view .sk-hero'),
    cards: document.querySelectorAll('#view md-card').length }; })()`);
  chk('状态到齐后骨架换成真主页', !hs2.hero && hs2.cards >= 2, JSON.stringify(hs2));

  /* props 命令失败的那一次：属性页要说"读不到"。静态那条闸只钉写法，这一条钉
     真跑出来的一屏 —— 失败被吞成空数组时，标题会写成「系统属性 · 全部一致」。 */
  await send('Page.navigate', { url: URL0 + '&fail=props' });
  await sleep(1500);
  await ev(`(function(){ var n=document.getElementById('nav');
    n.dispatchEvent(new CustomEvent('change',{detail:{index:1},bubbles:true})); return 1; })()`);
  await sleep(500);
  await tapEntry('属性伪装');
  await sleep(1200);
  const pfail = await ev(`(function(){ var t = (document.getElementById('view').textContent || '');
    return { saysUnread: t.indexOf('属性对照读不到') >= 0,
      titleUnread: /系统属性 · 读不到/.test(t),
      liesOk: /系统属性 · 全部一致/.test(t),
      rows: document.querySelectorAll('#view md-list-item').length }; })()`);
  chk('props 读失败时属性页报"读不到"，不谎报"全部一致"',
    pfail.saysUnread && pfail.titleUnread && !pfail.liesOk, JSON.stringify(pfail));

  /* status 读失败的那一次：功能菜单不许打「undefined 个进程」，也不许把未知
     写成"开机写入已关闭"。daemon_alive 是三态，读不到 ≠ 没在跑。 */
  await send('Page.navigate', { url: URL0 + '&fail=status' });
  await sleep(1500);
  await ev(`(function(){ var n=document.getElementById('nav');
    n.dispatchEvent(new CustomEvent('change',{detail:{index:1},bubbles:true})); return 1; })()`);
  await sleep(700);
  await tapEntry('自动同步');
  await sleep(900);
  /* 行的文字是 md-list-item 的 **属性**（headline/trailing-text），渲染在 shadow 里 ——
     `view.textContent` 看不见它们。这一屏的判据必须把属性一起捞进来，
     否则"行没了"和"行是空的"读起来一模一样（上一版就是这么误判过一次）。 */
  const ALLTEXT = `(function(){ var v=document.getElementById('view');
    var t = v.textContent || '';
    [].slice.call(v.querySelectorAll('md-list-item')).forEach(function(x){
      t += '|' + (x.getAttribute('headline')||'') + (x.getAttribute('supporting-text')||'') + (x.getAttribute('trailing-text')||''); });
    return t.replace(/\\s+/g, ' '); })()`;
  const sfail = await ev(`(function(){ var v=document.getElementById('view');
    var t = v.textContent || '';
    [].slice.call(v.querySelectorAll('md-list-item')).forEach(function(x){
      t += '|' + (x.getAttribute('headline')||'') + (x.getAttribute('supporting-text')||'') + (x.getAttribute('trailing-text')||''); });
    return { undef: /undefined|NaN/.test(t), unread: t.indexOf('运行状态读不到') >= 0,
      claimsOff: t.indexOf('开机写入已关闭') >= 0, claimsOn: t.indexOf('开机写入已开启') >= 0,
      peek: t.replace(/\\s+/g, ' ').slice(-200) }; })()`);
  chk('status 读失败：自动同步页报"运行状态读不到"，屏上没有 undefined，也不猜开关方向',
    !sfail.undef && sfail.unread && !sfail.claimsOff && !sfail.claimsOn, JSON.stringify(sfail));
  /* 正对照：同一份判据在 status 正常时必须看得见「N 个进程」。
     没有这一条，上面那个 unread=false 既可能是"没显示读不到"也可能是"探针看不见属性"。 */
  await send('Page.navigate', { url: URL0 });
  await sleep(1500);
  await ev(`(function(){ var n=document.getElementById('nav');
    n.dispatchEvent(new CustomEvent('change',{detail:{index:1},bubbles:true})); return 1; })()`);
  await sleep(700);
  await tapEntry('自动同步');
  await sleep(900);
  const sok = await ev(ALLTEXT);
  chk('正对照：status 正常时同一行看得见「N 个进程」（上面那条判据不是瞎的）',
    /\d+ 个进程/.test(sok), String(sok).slice(-120));

  /* 整页重建不该吃掉正在输入的表单：改一个带 data-ek 的输入 → 点同一页的
     profile 芯片（那是 redraw，不取数）→ 新建的同一个 key 要回填草稿。
     OMK 那一页有 config.toml 与 injector.toml 两份表单，以前存一份另一份就没了。 */
  await send('Page.navigate', { url: URL0 + '&backend=teesim' });
  await sleep(1500);
  await ev(`(function(){ var n=document.getElementById('nav');
    n.dispatchEvent(new CustomEvent('change',{detail:{index:1},bubbles:true})); return 1; })()`);
  await sleep(700);
  await tapEntry('后端配置');
  await sleep(1400);
  const dr1 = await ev(`(function(){ /* 取文本框：mode 那一格是 md-select，给它塞中文会被自己抹平 */
    var el = document.querySelector('#view md-text-field[data-ek]');
    if (!el) return { found: 0 };
    el.value = '草稿得留着';
    if (el.focus) { try { el.focus(); } catch (e) { } }
    var cs = [].slice.call(document.querySelectorAll('#view md-chip, #view md-button'));
    return { found: 1, key: el.getAttribute('data-ek'), n: cs.length }; })()`);
  chk('配置页的输入框都登记了草稿 key（data-ek）', !!dr1.found, JSON.stringify(dr1).slice(0, 160));
  let dr2 = { kept: '没找到可点的芯片' };
  if (dr1.found) {
    const pos = await ev(`(function(){ var cs=[].slice.call(document.querySelectorAll('#view md-chip, #view md-button'));
      var b=cs.filter(function(x){var t=((x.getAttribute('label')||'') + (x.textContent||''));return /default/.test(t);})[0];
      if (!b) return null; var r=b.getBoundingClientRect();
      return { x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2) }; })()`);
    if (pos) {
      await send('Input.dispatchMouseEvent', { type: 'mousePressed', x: pos.x, y: pos.y, button: 'left', clickCount: 1 });
      await send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: pos.x, y: pos.y, button: 'left', clickCount: 1 });
    }
    await sleep(1000);
    const sel = '#view [data-ek="' + dr1.key + '"]';
    dr2 = await ev('(function(){ var el=document.querySelector(' + JSON.stringify(sel) + ');'
      + ' var a=document.activeElement;'
      + ' return { kept: el ? String(el.value) : "元素没了", focus: a && a.getAttribute ? a.getAttribute("data-ek") : null }; })()');
    chk('同页重画后草稿回填，正在输入的内容没被吃掉',
      dr2.kept === '草稿得留着', JSON.stringify(dr2) + ' key=' + dr1.key);
  }

  console.log('\n截图：' + SHOT_DIR);
  /* 体检：设置页点「运行体检」，demo 里应出 6 行、其中"名单"是 warn 档。
     同时验它按 TSV 行画成了行（不是一坨文本）。 */
  await send('Page.navigate', { url: URL0 });
  await sleep(1500);
  await ev(`(function(){ var n=document.getElementById('nav');
    n.dispatchEvent(new CustomEvent('change',{detail:{index:3},bubbles:true})); return 1; })()`);
  await sleep(800);
  const dbtn = await ev(`(function(){ var bs=[].slice.call(document.querySelectorAll('#view md-button'));
    var b=bs.filter(function(x){return (x.textContent||'').indexOf('运行体检')>=0;})[0];
    if(!b) return null; var r=b.getBoundingClientRect();
    return { x: Math.round(r.left + r.width/2), y: Math.round(r.top + r.height/2) }; })()`);
  if (dbtn) {
    await send('Input.dispatchMouseEvent', { type: 'mousePressed', x: dbtn.x, y: dbtn.y, button: 'left', clickCount: 1 });
    await send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: dbtn.x, y: dbtn.y, button: 'left', clickCount: 1 });
  }
  await sleep(1200);
  const doc = await ev(`(function(){ var rows=[].slice.call(document.querySelectorAll('#view md-list-item'));
    var tone=function(x){return x.getAttribute('data-tone')||'';};
    var warn=rows.filter(function(x){return tone(x)==='warn';}).map(function(x){return x.getAttribute('headline');});
    return { n: rows.length, warn: warn.join(','),
      hasSummary: (document.getElementById('view').textContent||'').indexOf('共 ')>=0 }; })()`);
  chk('体检：点一次出 6 行 TSV，名单那行是 warn 档，且有汇总句',
    dbtn && doc.n >= 6 && doc.warn.indexOf('名单') >= 0 && doc.hasSummary, JSON.stringify(doc).slice(0, 220));

  /* 备份列表：设置页点「刷新列表」，demo 里应出两行 .bak 且带对应文件。 */
  const bbtn = await ev(`(function(){ var bs=[].slice.call(document.querySelectorAll('#view md-button'));
    var b=bs.filter(function(x){return (x.textContent||'').indexOf('刷新列表')>=0;})[0];
    if(!b) return null; b.scrollIntoView({ block: 'center' }); var r=b.getBoundingClientRect();
    return { x: Math.round(r.left + r.width/2), y: Math.round(r.top + r.height/2) }; })()`);
  await sleep(400);
  if (bbtn) {
    await send('Input.dispatchMouseEvent', { type: 'mousePressed', x: bbtn.x, y: bbtn.y, button: 'left', clickCount: 1 });
    await send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: bbtn.x, y: bbtn.y, button: 'left', clickCount: 1 });
  }
  await sleep(900);
  const bks = await ev(`(function(){ var rows=[].slice.call(document.querySelectorAll('#view md-list-item'));
    var names=rows.map(function(x){return x.getAttribute('headline')||'';}).filter(function(n){return /.bak$/.test(n);});
    return { n: names.length, names: names.join(','), confirm: (document.getElementById('view').textContent||'').indexOf('再点确认')>=0 }; })()`);
  chk('备份列表：点刷新出两行 .bak（未点回滚时没有"再点确认"）',
    !!bbtn && bks.n >= 2 && bks.names.indexOf('injector.toml.bak') >= 0 && !bks.confirm, JSON.stringify(bks).slice(0, 160));

  ws.close(); chrome.kill();
  process.exit(bad ? 1 : 0);
}
main().catch(e => { console.error('✗ ' + e.message); process.exit(1); });
