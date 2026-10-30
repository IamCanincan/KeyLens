#!/usr/bin/env node
/* tests/accent-theme.mjs — theme.js 纯函数的单元闸（node 直接跑，不用浏览器）
 *
 * 动态配色坏的时候是"颜色悄悄不对"，肉眼看是"大概是个蓝"—— 所以判据必须钉在
 * 数上：FRRO 解析出的具体条目值、tonal 自检必须拒掉哪类坏数据、色相换算的
 * 已知答案。合成 FRRO 用的是 parseFrro 的逐字节条目格式（12 08 08 1c 10 varint
 * + 12 len 0a len2 name，与 lib 最上面那段注释一致）—— 台子自己先证明"它能
 * 解析出金标准"，才配得上当正对照。
 */
import { parseFrro, frroSeed, parseSeed, srgbToOklch } from '../webui/src/theme.js';

let fail = 0;
const chk = (name, ok, detail) => {
  if (ok) console.log('  ok   ' + name + (detail ? '  — ' + detail : ''));
  else { console.log('  ✗    ' + name + (detail ? '  → ' + detail : '')); fail = 1; }
};

/* ── 合成 FRRO ─────────────────────────────────────────────────────── */
function varint(n) {
  const out = [];
  do { let b = n & 0x7f; n >>>= 7; if (n) b |= 0x80; out.push(b); } while (n);
  return Buffer.from(out);
}
function entry(name, argb) {
  const v = varint(argb >>> 0);
  const nb = Buffer.from(name, 'latin1');
  const inner = Buffer.concat([Buffer.from([0x0a, nb.length]), nb]);
  return Buffer.concat([Buffer.from([0x12, 0x08, 0x08, 0x1c, 0x10]), v, Buffer.from([0x12, inner.length]), inner]);
}
/* 一条 tonal 阶梯：色相固定，明度随档位下降 —— 400 那档就是金标准 #FFC00000。
   坑记两处：① FRRO 的 ARGB8888 带 alpha，构造时必须带上（不然解析出来永远
   差一个 0xff000000，断言对着自己的构造错劲）；② lerp 别写成闭包拿外面的 t、
   又传第三个实参 —— 实参会被无声忽略，"金标准"其实是另一档的值。 */
const GOLD = 0xffc00000;
function ramp(dark) {
  const R = [0, 10, 50, 100, 200, 300, 400, 500, 600, 700, 800, 900, 1000];
  const parts = R.map((tone) => {
    const lerp = (a, b, u) => Math.round(a + (b - a) * u);
    const u = tone <= 400 ? tone / 400 : (tone - 400) / 600;
    const from = tone <= 400 ? [255, 255, 255] : [(GOLD >> 16) & 255, (GOLD >> 8) & 255, GOLD & 255];
    const to = tone <= 400 ? [(GOLD >> 16) & 255, (GOLD >> 8) & 255, GOLD & 255] : [0, 0, 0];
    const c = 0xff000000 | (lerp(from[0], to[0], u) << 16) | (lerp(from[1], to[1], u) << 8) | lerp(from[2], to[2], u);
    return entry('system_accent1_' + tone + '_' + (dark ? 'dark' : 'light'), c >>> 0);
  });
  return Buffer.concat(parts);
}

console.log('── FRRO 解析 ──');
const fr = parseFrro(Buffer.concat([ramp(false), ramp(true)]).toString('base64'));
chk('合成 FRRO 能解析出条目', !!fr && fr.n >= 24, fr ? fr.n + ' 条' : 'null');
chk('解析出的 400 档就是金标准值', fr && fr.map['system_accent1_400_light'] === GOLD,
  fr ? '0x' + (fr.map['system_accent1_400_light'] || 0).toString(16) : '-');
chk('名字不匹配 system_* 的条目不收', (() => {
  const b = Buffer.concat([entry('foo_bar_400_light', 0x11223344), ramp(false)]).toString('base64');
  const f = parseFrro(b);
  return f && f.map['foo_bar_400_light'] === undefined && f.map['system_accent1_400_light'] === GOLD;
})());
chk('截掉的 base64 不炸、退 null', parseFrro('!!!!') === null && parseFrro('') === null);

console.log('── tonal 自检 ──');
chk('单调阶梯 → 取 400 档当种子', (() => {
  const s = frroSeed(parseFrro(ramp(false).toString('base64')));
  return s === GOLD;
})());
chk('把阶梯里的两档对调 → 拒掉整份（退 null）', (() => {
  const e = [];
  const R = [0, 10, 50, 100, 200, 300, 400, 500, 600, 700, 800, 900, 1000];
  const raw = ramp(false);
  return frroSeed(parseFrro(raw.toString('base64'))) !== null
    && (() => { /* 真变异：300/500 两档互换，明度必不单调 */
      const mk = (tone, dark) => entry('system_accent1_' + tone + '_' + (dark ? 'dark' : 'light'),
        tone === 300 ? 0xff101010 : tone === 500 ? 0xfff0f0f0 : (tone * 991) & 0xffffff);
      const broken = Buffer.concat(R.map(t => mk(t, false)));
      return frroSeed(parseFrro(broken.toString('base64'))) === null;
    })();
})());
chk('条目不够 8 条 → 不信（退 null）', (() => {
  const few = Buffer.concat([entry('system_accent1_400_light', GOLD), entry('system_accent1_500_light', 0xff101010)]);
  return frroSeed(parseFrro(few.toString('base64'))) === null;
})());
chk('frroSeed(null) 与缺档都安全', frroSeed(null) === null && frroSeed({ map: {}, n: 0 }) === null);

console.log('── 种子解析 ──');
const C = { r: 0x67, g: 0x50, b: 0xa4 };
chk('#RRGGBB', JSON.stringify(parseSeed('#6750A4')) === JSON.stringify(C));
chk('AARRGGBB（取后 6 位）', JSON.stringify(parseSeed('FF6750A4')) === JSON.stringify(C));
chk('0x 前缀', JSON.stringify(parseSeed('0xFF6750A4')) === JSON.stringify(C));
chk('十进制 ARGB（>6 位按十进制读）', JSON.stringify(parseSeed(String(0xFF6750A4))) === JSON.stringify(C));
chk('6 位纯数字按十六进制（808080 是灰不是深蓝）',
  JSON.stringify(parseSeed('808080')) === JSON.stringify({ r: 0x80, g: 0x80, b: 0x80 }));
chk('3 位缩写', JSON.stringify(parseSeed('#F0A')) === JSON.stringify({ r: 0xff, g: 0x00, b: 0xaa }));
chk('null / none / 空串 / 乱码 → null',
  parseSeed('null') === null && parseSeed('none') === null && parseSeed('') === null && parseSeed('xyz') === null);

console.log('── OKLCH 换算 ──');
const red = srgbToOklch(255, 0, 0);
chk('#FF0000 色相 ≈ 29°', Math.abs(red.H - 29) < 3, 'H=' + red.H.toFixed(1));
chk('#FF0000 是高彩度', red.C > 0.15, 'C=' + red.C.toFixed(3));
const white = srgbToOklch(255, 255, 255);
chk('#FFFFFF 近零彩度', white.C < 0.001, 'C=' + white.C.toFixed(5));
const frame = srgbToOklch(0x4b, 0x5d, 0x8b);
chk('框架默认 #4b5d8b ≈ oklch(48.4% .078 267.2)（实测来的锚点）',
  Math.abs(frame.L - 0.484) < 0.01 && Math.abs(frame.C - 0.078) < 0.012 && Math.abs(frame.H - 267.2) < 6,
  'L=' + frame.L.toFixed(3) + ' C=' + frame.C.toFixed(3) + ' H=' + frame.H.toFixed(1));

console.log(fail ? '\n有断言失败' : '\n全部通过');
process.exit(fail);
