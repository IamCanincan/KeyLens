#!/usr/bin/env node
/*
 * 界面验收台架（本地跑，CI 不跑：需要 Chrome）
 *
 *   node tools/ui-cdp-check.mjs                     默认 417/360/320 × 浅/深 × 八页
 *   node tools/ui-cdp-check.mjs --w=417 --scheme=light --shot
 *
 * 为什么要有这一份：量具自己会错。用 `--window-size=417,975` 起 headless Chrome
 * 量到的布局视口其实是 **491**（比真机宽 18%），而截图仍旧是 834 宽 —— 于是
 * "八页 0 溢出"是在一台不存在的手机上验的，而同一张图看上去又像是 417。
 * 这里唯一可信的做法是 CDP `Emulation.setDeviceMetricsOverride` 把视口钉死。
 *
 * 检查四件事，任何一件不对就退非 0：
 *   1 视口确实是被钉住的那个宽度
 *   2 每页横向溢出 0（并点名越界元素）
 *   3 每页只有一个可见面板、顶栏标题与 TAB_LABEL 对得上
 *   4 主页「最近动态」的三条退路（有能力 / 无能力 / 空日志）
 */
import { spawn } from 'node:child_process';
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

/* 别用 import.meta.url 的 pathname：路径里的空格会被百分号编码成 %20。 */
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const FILE = path.join(ROOT, 'module', 'webroot', 'index.html');
const arg = (k, d) => {
  const hit = process.argv.slice(2).find(a => a.startsWith('--' + k + '='));
  return hit ? hit.split('=').slice(1).join('=') : d;
};
const flag = k => process.argv.slice(2).includes('--' + k);

if (!fs.existsSync(FILE)) { console.error('找不到 ' + FILE); process.exit(1); }
const CHROME = arg('chrome', process.env.CHROME || 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe');
if (!fs.existsSync(CHROME)) { console.error('找不到 Chrome：' + CHROME + '（用 --chrome= 指定）'); process.exit(1); }
if (typeof WebSocket !== 'function') { console.error('需要 Node 21+（全局 WebSocket）'); process.exit(1); }

const PORT = Number(arg('port', 9223));
const WIDTHS = arg('w', '417,360,320').split(',').map(Number);
const HEIGHT = Number(arg('h', 975));
const SCHEMES = arg('scheme', 'light,dark').split(',');
const PAGES = arg('pages', 'over,func,apps,backend,props,boot,log,about').split(',');
const SHOT = flag('shot');
const SHOT_DIR = SHOT ? path.resolve(arg('shots-to', path.join(os.tmpdir(), 'ui-cdp-check'))) : null;
if (SHOT_DIR) fs.mkdirSync(SHOT_DIR, { recursive: true });
/* demo=1：不碰真桥接，用页面自带的演示数据。量布局够用，量不到真机数据形状。 */
const URL0 = 'file:///' + FILE.replace(/\\/g, '/') + '?demo=1';

/* 期望标题必须写在这里，不能从页面里读：顶栏标题本来就是页面用 TAB_LABEL 设的，
   拿它自己当判据永远对得上 —— 改名这种破坏会静默通过。放一份外部期望值，
   两边漂开时这里先响。 */
const EXPECT_TITLE = {
  over: '主页', func: '功能', apps: '应用名单', backend: '后端与格式',
  props: '系统属性伪装', boot: 'Verified Boot 哈希', log: '运行日志', about: '关于与自检',
};
/* 请求的页必须有外部期望标题：漏一条，那一页的标题检查就是空转 */
const noTitle = PAGES.filter(p => !EXPECT_TITLE[p]);
if (noTitle.length) { console.error('EXPECT_TITLE 缺：' + noTitle.join(', ') + '（标题检查不能空转）'); process.exit(1); }
const get = (p) => new Promise((res, rej) => {
  http.get({ host: '127.0.0.1', port: PORT, path: p }, r => {
    let b = ''; r.on('data', d => b += d); r.on('end', () => res(b));
  }).on('error', rej);
});
const sleep = ms => new Promise(r => setTimeout(r, ms));

const PROBE = `(function(){
  var vw = Math.round(document.documentElement.clientWidth);
  var bad = [];
  document.querySelectorAll('.panel:not([hidden]) *').forEach(function (e) {
    var r = e.getBoundingClientRect();
    if (r.width > 0 && r.right > vw + 0.5) {
      var cn = (e.className && typeof e.className === 'string') ? '.' + e.className.trim().split(/\\s+/).join('.') : '';
      bad.push(e.tagName.toLowerCase() + (e.id ? '#' + e.id : '') + cn + '@' + Math.round(r.right));
    }
  });
  var shown = [].filter.call(document.querySelectorAll('.panel'), function (p) { return !p.hidden; })
    .map(function (p) { return p.id; });
  var h1 = document.querySelector('.appbar h1');
  return { vw: vw, scrollW: document.documentElement.scrollWidth, bad: bad.slice(0, 5),
           shown: shown, title: h1 ? h1.textContent : '' };
})()`;

async function main() {
  const chrome = spawn(CHROME, ['--headless=new', '--disable-gpu', '--hide-scrollbars',
    '--remote-debugging-port=' + PORT, '--window-size=800,1000', 'about:blank'], { stdio: 'ignore' });
  let target = null;
  for (let i = 0; i < 40 && !target; i++) {
    await sleep(400);
    try { target = JSON.parse(await get('/json/list')).find(t => t.type === 'page' && t.webSocketDebuggerUrl); } catch (e) {}
  }
  if (!target) { chrome.kill(); console.error('拿不到 CDP target（Chrome 是否被别的实例占住端口？）'); process.exit(1); }

  const ws = new WebSocket(target.webSocketDebuggerUrl);
  let id = 0; const pending = new Map(); const errors = [];
  const send = (method, params) => new Promise((res, rej) => {
    const n = ++id; pending.set(n, { res, rej });
    ws.send(JSON.stringify({ id: n, method, params: params || {} }));
  });
  ws.onmessage = ev => {
    const m = JSON.parse(ev.data);
    if (m.method === 'Runtime.exceptionThrown') {
      errors.push(((m.params.exceptionDetails.exception || {}).description) || m.params.exceptionDetails.text);
    }
    if (m.id && pending.has(m.id)) {
      const p = pending.get(m.id); pending.delete(m.id);
      m.error ? p.rej(new Error(JSON.stringify(m.error))) : p.res(m.result);
    }
  };
  await new Promise(r => { ws.onopen = r; });
  await send('Page.enable'); await send('Runtime.enable');

  const ev = async expr => {
    const r = await send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true });
    if (r.exceptionDetails) {
      const d = ((r.exceptionDetails.exception || {}).description) || r.exceptionDetails.text || '';
      throw new Error('页面里执行失败: ' + d + '\n  表达式: ' + expr.slice(0, 90));
    }
    return r.result.value;
  };
  /* 先把页面起起来再进循环：target 刚连上时还停在 about:blank */
  await send('Page.navigate', { url: URL0 });
  await sleep(2200);

  let bad = 0;
  const fail = msg => { bad++; console.log('  ✗ ' + msg); };

  for (const w of WIDTHS) {
    await send('Emulation.setDeviceMetricsOverride', { width: w, height: HEIGHT, deviceScaleFactor: 2, mobile: true });
    for (const scheme of SCHEMES) {
      await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: scheme }] });
      await send('Page.navigate', { url: URL0 });
      await sleep(2200);
      console.log(`── ${w}px · ${scheme} ──`);
      for (const p of PAGES) {
        await ev(`(function(){ try { openPage('${p}'); } catch (e) { return 'ERR ' + e.message; } return 1; })()`);
        await sleep(600);
        const m = await ev(PROBE);
        const tag = `${p.padEnd(8)} vw=${m.vw}`;
        const before = bad;
        if (m.vw !== w) fail(`${tag} 视口没钉住（要 ${w}，得 ${m.vw}）—— 别用 --window-size 量宽度`);
        if (m.scrollW - m.vw > 0) fail(`${tag} 横向溢出 ${m.scrollW - m.vw}px  越界: ${m.bad.join(' ')}`);
        if (m.shown.length !== 1) fail(`${tag} 可见面板 ${m.shown.length} 个：${m.shown.join(',')}`);
        else if (m.shown[0] !== 'p-' + p) fail(`${tag} 可见面板是 ${m.shown[0]}，不是 p-${p}`);
        if (m.title !== EXPECT_TITLE[p]) fail(`${tag} 标题「${m.title}」≠外部期望「${EXPECT_TITLE[p]}」`);
        if (SHOT) {
          const s = await send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true });
          fs.writeFileSync(path.join(SHOT_DIR, `${w}-${scheme}-${p}.png`), Buffer.from(s.data, 'base64'));
        }
        /* 这一页没新增失败才打 ok —— 用全局 bad 判的话，第一处红了后面七页就
           一声不响，看不出它们到底过了没。 */
        if (bad === before) console.log(`  ok ${tag} 溢出=0 面板=1 标题=${m.title}`);
      }
    }
  }

  /* 主页「最近动态」的三条路：改页面状态再重画，读回 DOM 判定 */
  console.log('── 主页「最近动态」三条退路 ──');
  await send('Emulation.setDeviceMetricsOverride', { width: WIDTHS[0], height: HEIGHT, deviceScaleFactor: 2, mobile: true });
  await send('Page.navigate', { url: URL0 });
  await sleep(2200);
  await ev(`(function(){ openPage('over'); return 1; })()`);
  await sleep(1000);
  const happy = await ev(`(function(){
    var r = document.getElementById('overRecent'), rows = r.querySelectorAll('.log-line');
    var tail = S.log.slice(-RECENT_N), same = rows.length === tail.length;
    for (var i = 0; i < rows.length; i++) if (rows[i].querySelector('.log-msg').textContent !== logParts(tail[i]).text) same = false;
    return JSON.stringify({ hidden: r.hidden, n: rows.length, icons: r.querySelectorAll('.log-lvl svg').length, same: same });
  })()`);
  const h = JSON.parse(happy);
  if (h.hidden || h.n === 0 || h.icons !== h.n || !h.same) fail('有日志时没画满/图标缺/与尾巴不一致: ' + happy);
  else console.log(`  ok 有日志：${h.n} 行、${h.icons} 个图标、与 S.log 尾巴一致`);

  const gated = await ev(`(function(){
    var keep = S.contract.commands;
    S.contract.checked = true; S.contract.commands = 'status env apps props';
    renderOver();
    var r = document.getElementById('overRecent');
    var out = { hidden: r.hidden, kids: r.childElementCount };
    S.contract.commands = keep; renderOver();
    return JSON.stringify(out);
  })()`);
  const g = JSON.parse(gated);
  if (!g.hidden || g.kids !== 0) fail('命令层没有 log 时没整块撤掉: ' + gated);
  else console.log('  ok 无 log 能力：整块 hidden、子节点 0');

  const empty = await ev(`(function(){
    var k = S.log, ke = S.logErr;
    S.log = []; S.logErr = false; renderOver();
    var a = (document.querySelector('#overRecent .recent-empty') || {}).textContent || '';
    S.logErr = true; renderOver();
    var b = (document.querySelector('#overRecent .recent-empty') || {}).textContent || '';
    S.log = k; S.logErr = ke; renderOver();
    return JSON.stringify({ 空: a, 失败: b });
  })()`);
  const e2 = JSON.parse(empty);
  if (!/还没有日志/.test(e2['空']) || !/读取失败/.test(e2['失败'])) fail('空态/失败态文案不对: ' + empty);
  else console.log(`  ok 空态「${e2['空']}」/ 失败态「${e2['失败']}」`);

  if (errors.length) fail('页面抛过未捕获异常：\n     ' + errors.slice(0, 5).join('\n     '));
  else console.log('  ok 全程无未捕获异常');

  ws.close(); chrome.kill();
  if (SHOT) console.log('截图目录：' + SHOT_DIR);
  console.log(bad ? `\n${bad} 项不通过` : '\n全部通过');
  process.exit(bad ? 1 : 0);
}
main().catch(e => { console.error('台架失败: ' + e.message); try { } catch (_) {} process.exit(1); });
