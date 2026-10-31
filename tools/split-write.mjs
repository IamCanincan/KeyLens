/*=============================================================================
 * _harness/split-write.mjs —— 把"只有写命令才用的实现"从 webui.sh 挪进 lib/write.sh
 *
 * 为什么：真机现量，一次调用的固定地板约 123~142ms，其中约 36ms 是读+lex 这 99.9KB
 * 脚本、约 55ms 是把 200 多个函数定义建出来（对照实验：同样的字节全改成 `:` 空操作
 * 只要 62ms）。而写命令的实现占了 960 行 / 约 35KB —— 界面读状态时根本不需要它们。
 *
 * 这个脚本只做机械搬运，不改一个字节的逻辑：
 *   ① 每个函数必须**恰好出现一次**定义，且能在下一个 `^}` 处闭合；
 *   ② 函数上方紧邻的注释块跟着走（说明是代码的一部分，不能留在原地变成断头话）；
 *   ③ 搬完核对总行数：留下的 + 搬走的 == 原来的；
 *   ④ 目标文件已存在就拒绝执行（不重复搬）。
 *===========================================================================*/
import fs from 'node:fs';

const SRC = 'module/webui.sh';
const DST = 'module/lib/write.sh';
const NAMES = [
  'cmd_props_apply', 'cmd_props_switch', 'cmd_set_boot_hash',
  'cmd_restore_app', 'cmd_restore_apps', 'cmd_remove_apps', 'cmd_set_mode',
  'cmd_teesim_save', 'cmd_teesim_save_overrides',
  'cmd_omk_save_injector', 'cmd_omk_save_config',
  'cmd_tricky_save_patch', 'cmd_tricky_drop_patch',
  'cmd_keybox_save', 'cmd_sync', 'cmd_clear_log', 'cmd_omk_restart',
  'cmd_teesim_profile_new', 'cmd_teesim_profile_del',
];

if (fs.existsSync(DST)) { console.error('✗ ' + DST + ' 已存在，拒绝再搬一遍'); process.exit(1); }

const src = fs.readFileSync(SRC, 'utf8');
const eol = src.includes('\r\n') ? '\r\n' : '\n';
const lines = src.split(/\r?\n/);

const blocks = [];
for (const name of NAMES) {
  const head = name + '() {';
  const starts = lines.map((l, i) => (l === head ? i : -1)).filter(i => i >= 0);
  if (starts.length !== 1) {
    console.error('✗ ' + name + ' 的定义行命中 ' + starts.length + ' 次（要恰好 1 次）');
    process.exit(1);
  }
  const s = starts[0];
  let e = -1;
  for (let i = s + 1; i < lines.length; i++) if (lines[i] === '}') { e = i; break; }
  if (e < 0) { console.error('✗ ' + name + ' 找不到闭合的 ^}'); process.exit(1); }

  // 往上收紧邻的注释与说明块：连续注释行 + 至多一个空行分隔
  let cs = s;
  let i = s - 1;
  while (i >= 0 && (/^\s*#/.test(lines[i]) || (lines[i].trim() === '' && /^\s*#/.test(lines[i - 1] || '')))) {
    if (lines[i].trim() === '' && !/^\s*#/.test(lines[i - 1] || '')) break;
    cs = i; i--;
  }
  blocks.push({ name, from: cs, to: e });
}

// 从后往前删，避免前面的删除让后面的行号错位
blocks.sort((a, b) => a.from - b.from);
const movedLines = [];
let rawMoved = 0;
for (let k = blocks.length - 1; k >= 0; k--) {
  const b = blocks[k];
  const chunk = lines.slice(b.from, b.to + 1);
  rawMoved += chunk.length;
  movedLines.unshift(...chunk, '');
  lines.splice(b.from, b.to - b.from + 1);
}

const totalBefore = src.split(/\r?\n/).length;
const out = lines.join('\n');
const leftCount = out.split(/\r?\n/).length;
// 核对的是"真搬走的行数"，不是 movedLines 的长度（后者每块多加了一个空行分隔）
if (leftCount !== totalBefore - rawMoved) {
  console.error(`✗ 行数对不上：留下 ${leftCount} ≠ 原来 ${totalBefore} − 搬走 ${rawMoved}`);
  process.exit(1);
}

const header = [
  '#!/system/bin/sh',
  '#=============================================================================',
  '# lib/write.sh - 只有写命令才用到的实现（由 webui.sh 按命令名懒加载）',
  '#',
  '# 为什么单独一个文件：一次调用的固定地板约 123~142ms，其中约 36ms 是读+lex 那 100KB',
  '#       脚本、约 55ms 是把两百多个函数定义建出来（同样的字节数全改成 `:` 空操作只要',
  '#       62ms —— 现量对照见 CHANGELOG）。而写命令的实现占 960 行 / 约 35KB：界面读',
  '#       status / env / backend-info 时一行都不需要它们，所以搬出来，只在真的要写时',
  '#       由 webui.sh source 进来。',
  '#',
  '# 边界由 tests/write-lazy.sh 钉住：这里的函数 ↔ 界面侧 WRITE_CMDS 那张表必须一一对应，',
  '#       少一边就是"写命令找不到函数"或"读命令白背 35KB"。',
  '#',
  '# 用法：不要加进 lib/common.sh 的加载清单 —— 那等于白搬。',
  '#=============================================================================',
  '',
];
fs.writeFileSync(DST, header.join('\n') + movedLines.join('\n').replace(/\n+$/, '') + '\n');
fs.writeFileSync(SRC, out);

console.log(`搬走 ${blocks.length} 个函数 / ${rawMoved} 行（含注释）；webui.sh 从 ${totalBefore} 行变成 ${leftCount} 行`);
console.log('文件：' + DST);
