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
/* 顺序 = 底栏四格的顺序（主页 / 功能 / 日志 / 设置）。
   must 是这一页必须出现的区块标题：缺一个就说明那一格的分支渲染没跑到。 */
const PAGES = [
  /* 主页回答"在不在跑"：状态条 + 三家互斥矩阵。 */
  { id: 'home', title: '主页', must: ['三家后端 · 同一时刻只能一家在跑', '未安装', '当前生效的就是这一家'], items: true },
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
  chk('图标字体生效（子集内名字 = 一个字形）', p0.inSet > 0 && p0.inSet <= 34, 'home=' + p0.inSet + 'px');
  chk('负对照成立（子集外名字 = 字面词）', p0.outSet > p0.inSet * 2, 'security=' + p0.outSet + 'px，' + (p0.outSet / Math.max(p0.inSet, 1)).toFixed(1) + ' 倍');
  chk('组件内部解析到符号字体', /Material Symbols/i.test(p0.fam), p0.fam || '没找到');
  chk('画出来的图标都有对应字体面（没有族名落空）', !p0.missFam,
    p0.missFam ? '落空: ' + p0.missFam : '已声明: ' + p0.declared);

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
    await ev(`(function(){ var n=document.getElementById('nav');
      n.dispatchEvent(new CustomEvent('change',{detail:{index:${i}},bubbles:true})); return 1; })()`);
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
    const press = async label => ev(`(function(){
      var bs=[].slice.call(document.querySelectorAll('#view md-button'));
      var b=bs.filter(function(x){return (x.textContent||'').trim()===${JSON.stringify(label)};})[0];
      if(!b) return 0; b.click(); return 1; })()`);
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
    const barInfo = () => ev(`(function(){ var b=document.getElementById('bar');
      var r=b.getBoundingClientRect(), cs=getComputedStyle(b);
      return { h: Math.round(r.height), bg: cs.backgroundColor }; })()`);
    const before = await barInfo();
    /* demo 的 env 报 sys_statusbar_dp=28、注入 insets 为 0 —— 顶栏必须自己
       让出这 28px，否则 22px 的标题行正好钻进状态栏底下（"头被砍一半"）。 */
    const fallback = await ev(`getComputedStyle(document.documentElement).getPropertyValue('--statusbar-fallback').trim()`);
    chk('状态栏兜底生效（注入 insets 为 0 时按系统栏高度让位）',
      fallback === '28px' && before.h === 92, 'fallback=' + fallback + ' barH=' + before.h);
    await ev(`(function(){ document.documentElement.style.setProperty('--safe-area-inset-top','60px'); return 1; })()`);
    const grown = await barInfo();
    await ev(`(function(){ document.documentElement.style.removeProperty('--safe-area-inset-top'); return 1; })()`);
    const after = await barInfo();
    chk('注入值更大时取注入值（60px 赢过兜底 28px）',
      grown.h === 124, `before=${before.h} grown=${grown.h} after=${after.h}`);
    chk('顶栏宿主有底色（padding 那条不是透明带）',
      before.bg !== 'rgba(0, 0, 0, 0)' && before.bg !== 'transparent', before.bg);
    chk('拿掉假 inset 后顶栏回兜底高度', after.h === before.h, `after=${after.h} before=${before.h}`);
    /* 底栏同一类：fixed + padding-bottom，宿主也要有底色，手势条那一条不能透明 */
    const navInfo = () => ev(`(function(){ var n=document.getElementById('nav'); var cs=getComputedStyle(n);
      return { h: Math.round(n.getBoundingClientRect().height), bg: cs.backgroundColor }; })()`);
    const nb = await navInfo();
    await ev(`(function(){ document.documentElement.style.setProperty('--safe-area-inset-bottom','24px'); return 1; })()`);
    const ng = await navInfo();
    await ev(`(function(){ document.documentElement.style.removeProperty('--safe-area-inset-bottom'); return 1; })()`);
    chk('底栏吃得到注入的 --safe-area-inset-bottom 且宿主有底色',
      ng.h === nb.h + 24 && nb.bg !== 'rgba(0, 0, 0, 0)' && nb.bg !== 'transparent',
      `before=${nb.h} grown=${ng.h} bg=${nb.bg}`);
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
    chk('点「目标名单」真的进二级', await tapEntry('目标名单') === 1);
    await sleep(1600);
    const pT = await ev(PROBE);
    chk('二级页标题与返回箭头都在', (await headlineText()) === '目标名单' && await backArrow() === 1,
      '标题=' + (await headlineText()) + ' 箭头=' + (await backArrow()));
    chk('名单二级页画出了真实的数据行', pT.items >= 2 && /目标文件：|这个后端接受的写法/.test(pT.text || ''),
      'items=' + pT.items + '（这两行 hint 的值来自 backend-info，空壳画不出）');
    await tapBack();
    await sleep(500);
    chk('返回箭头把人送回菜单', (await headlineText()) === '功能' && /目标名单/.test((await ev(PROBE)).text || ''));
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
    { id: 'omk', q: 'omk', must: ['config.toml · 信任链与设备身份', 'injector.toml · 名单与路由', 'injector.toml'],
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

  /* 互斥那一屏：真机上碰不到，只能造 —— 不造就没有任何证据它渲染得对。 */
  await send('Page.navigate', { url: URL0 + '&backend=tricky&conflict=1' });
  await sleep(1400);
  await ev(`(function(){ var n=document.getElementById('nav');
    n.dispatchEvent(new CustomEvent('change',{detail:{index:0},bubbles:true})); return 1; })()`);
  await sleep(900);
  const pc = await ev(PROBE);
  const mustC = ['三家后端 · 同一时刻只能一家在跑', '抢同一个 keymint HAL，模块已经停在这里',
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

  console.log('\n截图：' + SHOT_DIR);
  ws.close(); chrome.kill();
  process.exit(bad ? 1 : 0);
}
main().catch(e => { console.error('✗ ' + e.message); process.exit(1); });
