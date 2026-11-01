#!/usr/bin/env node
/* 刷机包打包器：module/ → KeyLens-<版本>.zip
 *
 * 为什么不用 PowerShell 的 Compress-Archive：它把条目名写成 `backends\teesim.awk`
 * 这种**反斜杠**。zip 规范里路径分隔符是 `/`，busybox/recovery 的 unzip 会把反斜杠
 * 当成文件名的一部分 —— 整个目录树被摊平成一个个叫 "lib\core.sh" 的文件，
 * update-binary 找不到，装机直接坏。现场抓过一次才写下来的。
 *
 * 也顺手把 unix 权限存进去（旧包没存，mode=0o0，靠管理器自己 chmod）：
 * 目录与 .sh / awk / update-binary 给 0755，其余 0644 —— 有总比没有稳。
 *
 * 跑法：node tools/build-zip.mjs            输出 KeyLens-<version>.zip 到仓库根
 *       node tools/build-zip.mjs --check    只验现有包（正斜杠 + 必备文件 + 权限）
 */
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '..');
const MOD = path.join(repo, 'module');
const prop = fs.readFileSync(path.join(MOD, 'module.prop'), 'utf8');
/* 包名用显示名（KeyLens-v…），不是 id（keylens）—— 发布资产的命名一直是名字打头，
   和 update.json 的 zipUrl、Releases 页面上的观感保持一致。 */
const disp = (prop.match(/^name=(.*)$/m) || [])[1].trim();
const ver = (prop.match(/^version=(.*)$/m) || [])[1].trim();
const NAME = `${disp}-${ver}.zip`;
const args = process.argv.slice(2).filter(a => a !== '--check');
const CHECK = process.argv.includes('--check');
const TARGET = CHECK ? (args[0] ? path.resolve(repo, args[0]) : path.join(repo, NAME)) : path.join(repo, NAME);

/* 这个模块的 META-INF 里是 update-script（不是 updater-script）—— 与老包一致，
   装机走的是 update-binary，这个文件只是历史约定里的占位。判据照实写。 */
const REQUIRED = ['META-INF/com/google/android/update-binary', 'META-INF/com/google/android/update-script',
  'module.prop', 'customize.sh', 'service.sh', 'post-fs-data.sh', 'webui.sh', 'uninstall.sh', 'action.sh',
  'lib/common.sh', 'webroot/index.html'];

/* 装机必需文件：除了这张手抄表，还要**从代码里推**出"运行时会 source 的库文件"。
   2026-10-31 加：lib/write.sh（写命令的实现，按命令名懒加载）不在手抄表里，
   而 --check 对着一个没有它的旧包照样报「装机必需文件齐」—— 一条比字符串的闸，
   漏的恰好是"新加的那个文件"，这类清单永远会漏最新的那一项。 */
function sourcedLibs() {
  const out = new Set();
  const entry = ['webui.sh', 'service.sh', 'post-fs-data.sh', 'customize.sh', 'action.sh', 'uninstall.sh'];
  for (const f of entry) {
    const p = path.join(repo, 'module', f);
    if (!fs.existsSync(p)) continue;
    const t = fs.readFileSync(p, 'utf8');
    for (const m of t.matchAll(/\.\s+"?\$\{?(?:MODDIR|MODPATH)\}?\/lib\/([A-Za-z0-9_-]+)\.sh/g)) out.add('lib/' + m[1] + '.sh');
    /* common.sh 里的加载清单：for _kl_part in core lock tools …; do . "$_kl_lib/$_kl_part.sh" */
    for (const m of t.matchAll(/for\s+\w+\s+in\s+([^\n;]+);\s+do\s*\n?\s*\.\s+"?\$\w*\/\$_?\w*\.sh/g)) {
      for (const one of m[1].trim().split(/\s+/)) if (one) out.add('lib/' + one + '.sh');
    }
  }
  const common = path.join(repo, 'module', 'lib', 'common.sh');
  if (fs.existsSync(common)) {
    const t = fs.readFileSync(common, 'utf8');
    for (const m of t.matchAll(/for\s+\w+\s+in\s+([^\n;]+);/g))
      for (const one of m[1].trim().split(/\s+/)) if (one) out.add('lib/' + one + '.sh');
  }
  return [...out].sort();
}
const SOURCED = sourcedLibs();
/* 命令层的可执行实现（阶段 5 起是唯一实现）：19 份 awk 是参照，留在
   tests/fixtures/backends 供对拍，不再随包发布 —— 所以包里没带 bin/keylens 的 zip
   装上就是一个跑不动的命令层，装机脚本现在会直接 abort。这里在**做包的时候**就拦掉，
   不等它装到手机上才红。 */
const BIN_REL = 'bin/keylens';
const BIN_SRC = path.join(repo, 'rust', 'target', 'aarch64-linux-android', 'release', 'keylens');
const REQUIRED_ALL = [...REQUIRED, BIN_REL];
const MISSING_FROM_LIST = SOURCED.filter(s => !REQUIRED.includes(s));

const execy = (rel) => /\.sh$|\.awk$|update-binary$|updater-script$/.test(rel) || /(^|\/)keylens$/.test(rel) || rel.endsWith('/');
function walk(dir, base, out) {
  for (const name of fs.readdirSync(dir).sort()) {
    if (name === '.DS_Store' || name.endsWith('.tmp')) continue;
    const p = path.join(dir, name);
    const rel = (base ? base + '/' : '') + name;
    const st = fs.statSync(p);
    if (st.isDirectory()) { out.push({ rel: rel + '/', dir: true }); walk(p, rel, out); }
    else out.push({ rel, file: p, size: st.size });
  }
  return out;
}

/* ---- 写 zip（store/deflate 两法，deflate 更小；CRC 用 zlib.crc32） ---- */
const crc32 = zlib.crc32 || (buf => { /* Node < 20.15 兜底 */
  let c, t = [];
  for (let n = 0; n < 256; n++) { c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1; t[n] = c >>> 0; }
  let crc = 0xFFFFFFFF;
  for (const b of buf) crc = t[(crc ^ b) & 0xFF] ^ (crc >>> 8);
  return (crc ^ 0xFFFFFFFF) >>> 0;
});

function build(entries) {
  const chunks = [];
  const central = [];
  let off = 0;
  for (const e of entries) {
    const nameBuf = Buffer.from(e.rel, 'utf8');           // 正斜杠，见文件头
    const isDir = !!e.dir;
    const data = isDir ? Buffer.alloc(0) : fs.readFileSync(e.file);
    const def = isDir ? Buffer.alloc(0) : zlib.deflateRawSync(data, { level: 9 });
    const useDef = !isDir && def.length < data.length;
    const payload = isDir ? Buffer.alloc(0) : (useDef ? def : data);
    const method = isDir ? 0 : (useDef ? 8 : 0);
    const crc = crc32(data) >>> 0;
    const mode = (isDir ? 0o40755 : (execy(e.rel) ? 0o100755 : 0o100644));
    const lh = Buffer.alloc(30);
    lh.writeUInt32LE(0x04034b50, 0); lh.writeUInt16LE(20, 4); lh.writeUInt16LE(0x0800, 6); // UTF-8 名
    lh.writeUInt16LE(method, 8); lh.writeUInt16LE(0, 10); lh.writeUInt16LE(0, 12);
    lh.writeUInt32LE(crc, 14); lh.writeUInt32LE(payload.length, 18); lh.writeUInt32LE(data.length, 22);
    lh.writeUInt16LE(nameBuf.length, 26); lh.writeUInt16LE(0, 28);
    chunks.push(lh, nameBuf, payload);

    const ch = Buffer.alloc(46);
    ch.writeUInt32LE(0x02014b50, 0);
    ch.writeUInt16LE(0x031E, 4);            // made by: UNIX, zip 3.0 —— 不是 DOS
    ch.writeUInt16LE(20, 6); ch.writeUInt16LE(0x0800, 8);
    ch.writeUInt16LE(method, 10); ch.writeUInt16LE(0, 12); ch.writeUInt16LE(0, 14);
    ch.writeUInt32LE(crc, 16); ch.writeUInt32LE(payload.length, 20); ch.writeUInt32LE(data.length, 24);
    ch.writeUInt16LE(nameBuf.length, 28);
    ch.writeUInt32LE(0, 38);
    ch.writeUInt32LE((mode << 16) >>> 0, 38);   // external attrs：unix 权限
    /* 相对偏移必须写：漏了它每个条目都指向 0，unzip 会报
       `mismatching "local" filename` —— 包看着能列，实际解坏。 */
    ch.writeUInt32LE(off >>> 0, 42);
    central.push(Buffer.concat([ch, nameBuf]));
    off += lh.length + nameBuf.length + payload.length;
  }
  const cdStart = off;
  const cd = Buffer.concat(central);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(entries.length, 8); eocd.writeUInt16LE(entries.length, 10);
  eocd.writeUInt32LE(cd.length, 12); eocd.writeUInt32LE(cdStart, 16);
  return Buffer.concat([...chunks, cd, eocd]);
}

/* ---- --check：验一个现有包 ---- */
function inspect(buf) {
  const out = [];
  let i = 0;
  while ((i = buf.indexOf(Buffer.from([0x50, 0x4b, 0x01, 0x02]), i)) >= 0) {
    const ext = buf.readUInt32LE(i + 38);
    const namelen = buf.readUInt16LE(i + 28);
    const uncomp = buf.readUInt32LE(i + 24);
    const name = buf.slice(i + 46, i + 46 + namelen).toString('utf8');
    // 中央目录：偏移 4 是版本号（30），偏移 5 才是"做包的系统"（3=UNIX）—— 读错过一次
    out.push({ name, mode: (ext >>> 16) & 0xffff, madeby: buf[i + 5], uncomp });
    i += 4;
  }
  return out;
}

if (CHECK) {
  if (!fs.existsSync(TARGET)) { console.log('✗ 找不到包 ' + TARGET); process.exit(1); }
  const list = inspect(fs.readFileSync(TARGET));
  let bad = 0;
  const chk = (n, ok, d) => { if (!ok) bad++; console.log(`${ok ? 'ok  ' : '✗   '} ${n}${d ? '  — ' + d : ''}`); };
  chk('条目数 > 0', list.length > 0, list.length + ' 条');
  const bs = list.filter(e => e.name.includes('\\'));
  chk('没有反斜杠条目名（busybox unzip 会摊平目录树）', bs.length === 0, bs.slice(0, 3).map(e => e.name).join(' '));
  const names = new Set(list.map(e => e.name));
  const want = [...new Set([...REQUIRED_ALL, ...SOURCED])];   // 含 bin/keylens：没二进制的包装上就是死的
  const miss = want.filter(r => !names.has(r));
  chk('装机必需文件齐（手抄表 + 从代码推出的 source 清单）', miss.length === 0, miss.join(' '));
  chk('代码里 source 的库文件都在必需表里（漏一项就会在这里现形）',
    SOURCED.every(s => names.has(s)), '推出 ' + SOURCED.length + ' 项：' + SOURCED.join(' '));
  const noexec = list.filter(e => /\.sh$|\.awk$|update-binary$/.test(e.name) && !((e.mode & 0o111))).map(e => e.name);
  chk('脚本都带可执行位', noexec.length === 0, noexec.slice(0, 3).join(' '));
  chk('made-by 是 UNIX', list.every(e => e.madeby === 0x03), 'first=' + (list[0] || {}).madeby);
  const idx = list.find(e => e.name === 'webroot/index.html');
  chk('界面产物在包里且不是空的', !!idx && idx.uncomp > 400000, idx ? (idx.uncomp / 1024).toFixed(0) + ' KB' : '缺');
  process.exit(bad ? 1 : 0);
}

if (!fs.existsSync(BIN_SRC)) {
  console.error(`✗ 找不到命令层二进制 ${path.relative(repo, BIN_SRC)}
  自阶段 5 起 awk 参照实现不随包发布：没有 bin/keylens 的包装上就跑不动（装机脚本会 abort）。
  先交叉编译再打包：cargo build --release --target aarch64-linux-android --manifest-path rust/Cargo.toml`);
  process.exit(1);
}
const entries = walk(MOD, '', []);
/* bin/ 不在 module/ 里（产物目录），手动补两条条目：目录 + 文件，权限走 execy() */
entries.push({ rel: 'bin/', dir: true });
entries.push({ rel: BIN_REL, file: BIN_SRC, size: fs.statSync(BIN_SRC).size });
const buf = build(entries);
fs.writeFileSync(TARGET, buf);
console.log(`已打包 ${path.relative(repo, TARGET)}：${(buf.length / 1024).toFixed(1)} KB，${entries.length} 个条目（正斜杠 + unix 权限）`);
