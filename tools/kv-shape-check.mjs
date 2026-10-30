#!/usr/bin/env node
/* KV 形状对照：界面读的那个键名，命令层真的会输出吗？
 *
 * 这一类 bug 已经出现过两次：
 *  - 界面读 t.serviceErrorCode / t.teeBroken，命令层输出 service_error_code / tee_broken
 *    —— 因为**我自己写的台架假数据也是 camelCase**，两边一起错，台架全绿。
 *  - 我凭空给 KV_REQUIRED 编过键名，真机上会把全部写入冻掉。
 * 所以这次不靠眼看：从三个真源里各抽一份键名，交叉比。
 *
 *   1) module/webui.sh  →  `kv <key>` 字面量（命令层实际输出的键）
 *   2) module/backends/*.awk + webui/src/*.js 的假数据  →  对照样本
 *   3) webui/src/screens.js →  从 parseKV 对象上读出来的 `.key`
 *
 * 跑法：node tools/kv-shape-check.mjs   （有偏差就退 1）
 *
 * 它的盲区（判词必须自己说清看不见什么）：**算出来的下标看不见**。
 * `st.tee_broken` 能被扫到，`obj[table[i]]` 扫不到 —— 所以界面里凡是按表取 KV 键的
 * 地方，都要先落一个字面量读数（见 screens.js 的 backendMatrix：
 * `{ tricky: st.tricky_state, ... }`），否则那条读取就脱离了这道闸。
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '..');
const read = (p) => fs.readFileSync(path.join(repo, p), 'utf8');

const SH = read('module/webui.sh');

/* ── 1. 命令层实际会输出的键 ─────────────────────────────────────── */
/* kv 的调用形状：kv <键> <值>；键一律是字面量（不是 $1 那种）。 */
const emitted = new Set();
for (const m of SH.matchAll(/(?<![\w$-])kv\s+([A-Za-z_][A-Za-z0-9_]*)\s/g)) emitted.add(m[1]);
/* awk 脚本里 print "键=值" 的形状：'key=" ... 以及 printf "%s=...". 这里只认
   明确的 `print "k="` / `printf "k=` 字面量，避免把 shell 变量名当键。 */
const awkDir = path.join(repo, 'module', 'backends');
const awkKeys = new Set();
if (fs.existsSync(awkDir)) {
  for (const f of fs.readdirSync(awkDir)) {
    if (!f.endsWith('.awk')) continue;
    const t = fs.readFileSync(path.join(awkDir, f), 'utf8');
    for (const m of t.matchAll(/(?:print|printf)\s*\(?\s*"([A-Za-z_][A-Za-z0-9_]*)=/g)) awkKeys.add(m[1]);
  }
}
/* 上游文件的键也算命令层键：cmd_tee_status 之类的 case 分支按上游键名读，
   但对外输出的是 kv 的那个名字，所以 case 里的名字**不该**进白名单。 */
const KNOWN = new Set([...emitted, ...awkKeys]);

/* ── 2. 界面从 KV 对象上读了哪些键 ───────────────────────────────── */
/* 注释要先剔掉：这道闸自己写在注释里的例子（`st.xxx`）会被它自己当成一次读取 ——
   第一版就这么被自己判了一次假警。 */
const stripComments = (t) => t.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/^\s*\/\/.*$/gm, ' ');
/* parseKV 出来的对象在 screens.js 里的变量名有限，逐个追：
     const x = S.<stateField>          → x.<key>
     S.<stateField>.<key>              → 直接读
   stateField 只要最终来自 parseKV 就纳入（backendInfo/status/env/teeStatus/boot）。 */
const KV_STATE = ['status', 'env', 'backendInfo', 'teeStatus', 'boot', 'contract', 'bridge'];
const screensRaw = read('webui/src/screens.js');
const screens = stripComments(screensRaw + '\n' + read('webui/src/app.js'));
const reads = [];
const esc = (s) => s.replace(/[$]/g, '\\$');
/* 别名只在自己那个函数里有效：screens.js 里 `t`、`s`、`bi` 这类短名反复用作
   回调参数，跨函数比会到处认错。取"声明处 → 下一个顶格 }"当作它的作用域。 */
function scopeOf(src, idx) {
  const end = src.indexOf('\n}', idx);
  return src.slice(idx, end < 0 ? src.length : end);
}
for (const field of KV_STATE) {
  for (const m of screens.matchAll(new RegExp('(?:const|var|let)\\s+([A-Za-z_$][\\w$]*)\\s*=\\s*S\\.' + field + '\\b', 'g'))) {
    const name = m[1];
    for (const k of scopeOf(screens, m.index).matchAll(new RegExp('\\b' + esc(name) + '\\.([A-Za-z_$][\\w$]*)', 'g'))) {
      reads.push({ field, key: k[1] });
    }
  }
  for (const m of screens.matchAll(new RegExp('S\\.' + field + '\\.([A-Za-z_$][\\w$]*)', 'g'))) {
    reads.push({ field, key: m[1] });
  }
}

/* 桥接层的 KV_REQUIRED 也要能对上（写入命令要求的键名写错＝永远不匹配） */
const bridge = read('webui/src/bridge.js');
const kvReq = [];
const kvStart = bridge.indexOf('export const KV_REQUIRED');
/* 截到本表的 `};` 为止。原来用下一个常量的位置当右边界，而 WRITE_CMDS
   定义在 KV_REQUIRED **前面**，于是右边界掉到文件末尾，把 S 的字段
   （tab:'over'、theme:'auto'…）当成要求键报了一堆假警。 */
const kvEnd = bridge.indexOf('\n};', kvStart);
const block = bridge.slice(kvStart, kvEnd < 0 ? kvStart : kvEnd);
for (const m of block.matchAll(/'?([a-z][a-z-]*)'?:\s*'([A-Za-z_, ]+)'/g)) {
  for (const k of m[2].split(/[,\s]+/).filter(Boolean)) kvReq.push({ cmd: m[1], key: k });
}

/* 台架假数据的键：假数据里有、命令层从不输出的键 = 台架在说谎 */
const fixtureStart = bridge.indexOf('function demoResult');
const fixture = bridge.slice(fixtureStart, bridge.indexOf('\n}', bridge.indexOf('return body === undefined')));
const fixtureKeys = new Set();
for (const m of fixture.matchAll(/'([A-Za-z_][A-Za-z0-9_]*)=/g)) fixtureKeys.add(m[1]);

/* ── 3. 交叉比 ───────────────────────────────────────────────────── */
let bad = 0;
const localFields = new Set();
for (const m of bridge.matchAll(/S\.(\w+)\s*=\s*\{([^}]*)\}/g)) {
  for (const k of m[2].matchAll(/(\w+)\s*:/g)) localFields.add(m[1] + '.' + k[1]);
}
/* 直接写在 screens.js 里赋给状态对象的派生字段（S.x = ... 之外的写法很少） */
const seen = new Set();
for (const r of reads) {
  const id = r.field + '.' + r.key;
  if (seen.has(id)) continue;
  seen.add(id);
  if (KNOWN.has(r.key) || localFields.has(id)) continue;
  /* bridge.js 里给同一个对象补过的字段也算合法（例如 boot 的派生值） */
  if (new RegExp('\\b' + r.key + '\\s*:').test(bridge)) continue;
  console.log(`✗   界面读了 S.${r.field}.${r.key}，命令层没有任何地方输出 "${r.key}"`);
  bad++;
}

for (const q of kvReq) {
  if (!KNOWN.has(q.key)) {
    console.log(`✗   KV_REQUIRED['${q.cmd}'] 要求键 "${q.key}"，命令层没有输出过这个键名`);
    bad++;
  }
}

for (const k of fixtureKeys) {
  if (!KNOWN.has(k)) {
    console.log(`✗   台架假数据里有 "${k}"，命令层从来不输出它 —— 假数据在替我背书`);
    bad++;
  }
}

/* 算出来的下标（obj[变量]）看不见，这一句把"看不见"量化出来：数字变大就说明
   有新的 KV 读取从字面量退成了动态下标，那部分就不再受这道闸保护。 */
const bracketKeys = new Set();
for (const m of screens.matchAll(/\w+\['([A-Za-z_][A-Za-z0-9_]*)'\]/g)) bracketKeys.add(m[1]);
const dyn = [...screens.matchAll(/\b\w+\[\w+(\.\w+|\[[^\]]*\])\]/g)];
console.log(`（字面量下标读到 ${bracketKeys.size} 个键名；算出来的下标 ${dyn.length} 处 —— 后者这道闸看不见）`);
for (const k of bracketKeys) {
  if (!KNOWN.has(k)) { console.log(`✗   界面按 st['${k}'] 读，命令层没有输出过这个键名`); bad++; }
}

/* 表单规格里的"读键"也要对账：F_* 表每项是 ['提交键', '读键', 标签, …]，读键是
   间接传给 biValue(spec, from) 的 —— 上面那种 `S.x.y` 的扫描看不见它。这一格漏过真 bug：
   两条开关的读键写成 config_force_skip_biometric / config_retire_stale_keys，
   而命令层输出的是 cfg_* —— 于是这两个开关在真机上永远显示为"关"。 */
const formReads = [];
for (const m of screensRaw.matchAll(/const (F_[A-Z_]+) = \[([\s\S]*?)\n\];/g)) {
  /* 只认"字段项"：['提交键', '读键', '标签', '类型', …]。不这么限定的话，
     select 的选项对 ['warning','warning'] 也会被当成字段 —— 第一版就这么报了个假警。 */
  for (const r of m[2].matchAll(/\['([a-z_]+)',\s*'([a-z_]+)',\s*'[^']*',\s*'(?:text|switch|select|seg)'/g)) {
    formReads.push({ table: m[1], post: r[1], read: r[2] });
  }
}
/* 这些读键来自 JS 侧自己算出来的值，不是命令层输出（目前没有；留着这条口子时要写清理由） */
const FORM_READ_OK = new Set([]);
for (const f of formReads) {
  if (KNOWN.has(f.read) || FORM_READ_OK.has(f.read)) continue;
  console.log(`✗   ${f.table} 的读键 "${f.read}"（提交键 ${f.post}）命令层从没输出过 —— 这格在真机上永远是空`);
  bad++;
}
const used = new Set(reads.map((r) => r.key));
const unused = [...KNOWN].filter((k) => !used.has(k) && !k.startsWith('ok') && !['present', 'restored', 'applied', 'cleared', 'saved', 'written', 'removed', 'added', 'restarted', 'cleared_log'].includes(k));

console.log(`命令层输出键 ${KNOWN.size} 个（webui.sh kv ${emitted.size} · awk ${awkKeys.size}）`);
console.log(`界面读取 ${seen.size} 个字段 · KV_REQUIRED ${kvReq.length} 条 · 假数据键 ${fixtureKeys.size} 个`);
if (unused.length) console.log(`（其中命令层输出但界面暂未读取的 ${unused.length} 个：${unused.slice(0, 20).join(' ')}${unused.length > 20 ? ' …' : ''}）`);
console.log(bad ? `✗ 有 ${bad} 处对不上` : '✓ 界面读的键命令层都会输出');
process.exit(bad ? 1 : 0);
