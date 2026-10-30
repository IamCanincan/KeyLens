/*=============================================================================
 * webui/src/theme.js — 动态配色：把系统强调色映射进 MD3E 的颜色角色
 *
 * 数据链路：webui.sh env 报 sys_frro（SystemUI 运行时 overlay 的 base64）与
 * sys_seed_raw（用户手选 / 壁纸提取色）；解析与映射全在界面里做（shell 里没有
 * 能读 FRRO 的东西，JS 十几行且能带自检）。这套判据是上一版在线上跑过的，
 * 2026-10-30 换 MD3E 时整套丢了（界面退回库的静态紫），这里照原样搬回，
 * 落点从自绘 --hue/--sat 换成 MD3E 的 --md-sys-color-* 角色。
 *
 * 映射的规矩（沿用上一版的结论）：
 *  - 明度档位用界面内置的那一套 —— 模块侧拿不到系统算好的 12 组色调表本身，
 *    只拿得到 overlay 里的 ARGB；换明度就是审美重排。
 *  - 彩度按实测比值走，不做审美放大 —— primary 的彩度精确落到系统实测值，
 *    其余角色按"内置彩度 / 内置 primary 彩度"的比例跟随（上一版放大 2.2 倍
 *    那次，结论就是"看着和系统其它地方不是一套"）。
 *===========================================================================*/

/* 只重着色"accent 染出来的"那几个角色：主行动按钮（primary ×4）与选中态
   （secondary-container ×2）。tertiary/error/surface 系不动 —— 状态着色与
   表面层次跟色相无关。 */
const ROLES = ['primary', 'on-primary', 'primary-container', 'on-primary-container',
  'secondary-container', 'on-secondary-container'];

/* 取不到系统种子时的兜底：不是"我喜欢的紫"（MD3E 的默认就是那支紫），
   而是这台机器框架自己的默认强调色 —— framework-res.apk 的
   color/system_accent1_600_light = #4b5d8b = oklch(48.4% .078 267.2)，实测来的。 */
const FALLBACK_RGB = { r: 0x4b, g: 0x5d, b: 0x8b };
const HUE_NEAR_NEUTRAL = 267.2;   // 近中性时 atan2 给不出色相，留平台默认那支的

/* ── sRGB → OKLCH ─────────────────────────────────────────────────── */
/* 系统给的是 ARGB 整数，要换成 L、C、H 才能驱动这套令牌（MD3E 认 oklch()） */
export function srgbToOklch(r, g, b){
  var f = function (v){ v /= 255; return v <= 0.04045 ? v/12.92 : Math.pow((v + 0.055)/1.055, 2.4); };
  var R = f(r), G = f(g), B = f(b);
  var l = Math.cbrt(0.4122214708*R + 0.5363325363*G + 0.0514459929*B);
  var m = Math.cbrt(0.2119034982*R + 0.6806995451*G + 0.1073969566*B);
  var s = Math.cbrt(0.0883024619*R + 0.2817188376*G + 0.6299787005*B);
  return {
    L: 0.2104542553*l + 0.7936177850*m - 0.0040720468*s,
    C: Math.sqrt(Math.pow(1.9779984951*l - 2.4285922050*m + 0.4505937099*s, 2)
      + Math.pow(0.0259040371*l + 0.7827717662*m - 0.8086757660*s, 2)),
    H: (Math.atan2(0.0259040371*l + 0.7827717662*m - 0.8086757660*s,
      1.9779984951*l - 2.4285922050*m + 0.4505937099*s) * 180/Math.PI + 360) % 360,
  };
}

/* 种子色的存法各系统不统一：#RRGGBB / #AARRGGBB / 0x… / 裸十六进制 / 十进制 ARGB。
   纯数字到底哪一种要分开：6 位及以内的按十六进制颜色看（"808080" 是灰色），
   超过 6 位的按十进制整数看（"16711680" 是 0xFF0000 红色）—— 反过来就会把灰色
   读成 0x0C5490 这种莫名其妙的深蓝。 */
export function parseSeed(raw){
  var s = String(raw == null ? '' : raw).trim();
  if (!s || s === 'null' || s === 'none') return null;
  if (s.charAt(0) === '#') s = s.slice(1);
  var v = NaN, digits = s.replace(/^-/, '');
  if (/^0[xX][0-9a-fA-F]+$/.test(s)) v = parseInt(s.slice(2), 16);
  else if (/^-?\d+$/.test(s) && digits.length > 6) v = parseInt(s, 10) >>> 0;
  else if (/^[0-9a-fA-F]{8}$/.test(s)) v = parseInt(s.slice(2), 16);
  else if (/^[0-9a-fA-F]{6}$/.test(s)) v = parseInt(s, 16);
  else if (/^[0-9a-fA-F]{3}$/.test(s)) v = parseInt(s.replace(/./g, function (c){ return c + c; }), 16);
  else if (/^-?\d+$/.test(s)) v = parseInt(s, 10) >>> 0;
  if (isNaN(v)) return null;
  v = v >>> 0;
  return { r: (v >> 16) & 255, g: (v >> 8) & 255, b: v & 255 };
}

/* ── SystemUI 运行时 overlay（FRRO）解析 ──────────────────────────── */
/* 条目形态（上一版在本机逐字节确认过）：12 08 08 1c 10 <varint ARGB> 紧跟
   12 <len> 0a <len2> <资源名> —— 值在前、名字在后成对交替；08 1c 是 ResType
   TYPE_INT_COLOR_ARGB8888。这是系统"正在拿来画东西的那套色"，用户手选颜色时
   它也会被重新生成，所以比任何 setting 都权威。 */
function b64ToBytes(s){
  var bin;
  try { bin = atob(String(s).replace(/\s+/g, '')); } catch (e){ return null; }
  var out = new Uint8Array(bin.length);
  for (var i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
export function parseFrro(b64){
  var b = b64ToBytes(b64);
  if (!b || b.length < 16) return null;
  var map = {}, n = 0, i = 0;
  while (i + 8 < b.length) {
    if (b[i] === 0x12 && b[i+1] === 0x08 && b[i+2] === 0x08 && b[i+3] === 0x1c && b[i+4] === 0x10) {
      var j = i + 5, v = 0, sh = 0, c, bad = false;
      do {
        if (j >= b.length) { bad = true; break; }
        c = b[j++]; v += (c & 0x7f) * Math.pow(2, sh); sh += 7;
      } while (c & 0x80);
      if (!bad && b[j] === 0x12) {
        var nl = b[j+1], k = j + 2;
        if (b[k] === 0x0a) {
          var sl = b[k+1], name = '';
          for (var q = 0; q < sl && k+2+q < b.length; q++) name += String.fromCharCode(b[k+2+q]);
          if (/^system_[a-z0-9_]+$/.test(name)) { map[name] = v >>> 0; n++; }
          i = k + nl;
          continue;
        }
      }
    }
    i++;
  }
  return n ? { map: map, n: n } : null;
}

/* 自检：一条 tonal 阶梯的明度必须从 0 到 1000 单调下降。
   不单调 = 配对错位，这份数据就不能信 —— 宁可退回默认，也不要画一个错颜色。
   （上一版第一次写解析时就是靠这条抓出把 -dynamic- 当成 -accent- 用的：
     那份里根本没有 accent1 阶梯，"解析出 94 条"看着挺多却一条都用不上。） */
var RAMP = [0, 10, 50, 100, 200, 300, 400, 500, 600, 700, 800, 900, 1000];
export function frroSeed(fr){
  if (!fr) return null;
  for (var t = 0; t < 2; t++) {
    var cfg = t ? 'dark' : 'light', prev = null, mono = true, got = 0, seed = null;
    for (var i = 0; i < RAMP.length; i++) {
      var v = fr.map['system_accent1_' + RAMP[i] + '_' + cfg];
      if (v === undefined) continue;
      got++;
      var o = srgbToOklch((v >> 16) & 255, (v >> 8) & 255, v & 255);
      if (prev !== null && o.L > prev + 0.005) { mono = false; break; }
      prev = o.L;
      if (RAMP[i] === 400) seed = v;
    }
    if (mono && got >= 8 && seed !== null) return seed;
  }
  return null;
}

/* ── 应用到 MD3E 的角色 ───────────────────────────────────────────── */
/* 内置值按"当前深浅档"缓存：第一次要落 overrides 之前先把库自己的值读走
   （落完再读读到的是我们自己的 override，不是库的）。 */
let roleDefaults = {};   // 'light' | 'dark' -> { role: {L,C,H} }
let note = '';

function readRoleDefaults(theme){
  const st = document.documentElement.style;
  ROLES.forEach(function (r){ st.removeProperty('--md-sys-color-' + r); });
  const cs = getComputedStyle(document.documentElement);
  const out = {};
  ROLES.forEach(function (r){
    const v = (cs.getPropertyValue('--md-sys-color-' + r) || '').trim();
    const m = /^#([0-9a-fA-F]{6})$/.exec(v);
    out[r] = m ? srgbToOklch(parseInt(m[1].slice(0, 2), 16), parseInt(m[1].slice(2, 4), 16), parseInt(m[1].slice(4, 6), 16)) : null;
  });
  return out;
}

/* 给界面的自检卡用：强调色从哪来、落了什么 */
export function accentNote(){ return note; }

export function applyAccent(env){
  env = env || {};
  const st = document.documentElement.style;
  const theme = document.documentElement.getAttribute('data-theme') || 'light';
  if (!roleDefaults[theme]) roleDefaults[theme] = readRoleDefaults(theme);
  const d = roleDefaults[theme];
  if (!d.primary) { note = 'MD3E 令牌读不到，配色保持库默认'; return; }

  let rgb = null, src = '';
  const fv = frroSeed(parseFrro(env.sys_frro));
  if (fv !== null) { rgb = { r: (fv >> 16) & 255, g: (fv >> 8) & 255, b: fv & 255 }; src = 'SystemUI overlay'; }
  if (!rgb) { const s = parseSeed(env.sys_seed_raw); if (s) { rgb = s; src = env.sys_seed_src || 'seed'; } }
  let hue;
  if (!rgb) {
    rgb = FALLBACK_RGB; src = '平台默认 system_accent1（框架 #4b5d8b）';
    hue = HUE_NEAR_NEUTRAL;
  } else {
    const a = srgbToOklch(rgb.r, rgb.g, rgb.b);
    /* 近中性时色相没有意义（atan2 会乱转），只跟彩度、色相留默认 */
    hue = a.C < 0.02 ? HUE_NEAR_NEUTRAL : a.H;
  }
  const a = srgbToOklch(rgb.r, rgb.g, rgb.b);
  const hex = '#' + [rgb.r, rgb.g, rgb.b].map(function (v){ return (v < 16 ? '0' : '') + v.toString(16); }).join('');
  /* 彩度锚在 primary 上：primary 精确落到系统实测彩度，其余角色按内置比例跟随 */
  const ratio = Math.max(0, Math.min(1.5, a.C / d.primary.C));
  ROLES.forEach(function (r){
    if (!d[r]) return;
    st.setProperty('--md-sys-color-' + r,
      'oklch(' + (d[r].L * 100).toFixed(1) + '% ' + Math.min(0.37, d[r].C * ratio).toFixed(4) + ' ' + hue.toFixed(1) + ')');
  });
  note = '强调色 ' + hex + '（' + src + '）· 色相 ' + Math.round(hue) + '°';
}
