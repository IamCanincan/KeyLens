'use strict';
/* KeyLens 改名：把内部前缀也换干净（TAA_/_taa_/.ts_ → KL_/_kl_/.kl_）。
 *
 * 为什么用脚本而不是手改：`.ts_lock` 有 30 处、`TAA_DIR` 有 108 处，散在 12 个文件里。
 * 人眼扫一遍的结果一定是"改了我记得的那几处"—— 漏一处锁名 = 守护进程与界面各拿
 * 一把锁 = 同时写坏配置文件，而且这种坏只在特定时序下出现。漏改由 tools/
 * name-residue-check.mjs 那道闸门判死，不由我保证。
 *
 * 保留老名字的"必要地方"（脚本里显式跳过，residue 闸门也把它们列进白名单）：
 *   · taa_sys.txt / taa_resetprop.sh —— 老版本留在用户机器上的**文件名**，
 *     清理它们就必须按旧名找；
 *   · KL_LEGACY_* 的取值 —— 改名迁移的源路径；
 *   · uninstall.sh 里旧路径那一组 rm —— 升级后卸载不能留孤儿文件；
 *   · CHANGELOG.md / RELEASE_NOTES.md / update.json / README 的仓库 URL —— 更新说明
 *     与 GitHub 仓库名（仓库改名由人来做，不是我）。
 *
 * 跑法：node tools/rename-keylens.cjs          （就地改）
 *       node tools/rename-keylens.cjs --dry    （只报会改多少处）
 */
const fs = require('fs');
const path = require('path');

const repo = path.resolve(__dirname, '..');
const DRY = process.argv.includes('--dry');

/* 规则按"先长后短"排，避免 .ts_ 把 .ts_auto 切成半截 */
const RULES = [
  [/\bTAA_LEGACY_PROPS_OFF\b/g, 'KL_LEGACY_PROPS_OFF'],
  [/\bTAA_LEGACY_BOOT_HASH\b/g, 'KL_LEGACY_BOOT_HASH'],
  [/\bTAA_LEGACY_LOG\b/g, 'KL_LEGACY_LOG'],
  [/\bTAA_[A-Z_]+\b/g, m => 'KL_' + m.slice(4)],
  [/\b_taa_log_append\b/g, '_kl_log_append'],
  [/\b_taa_log\b/g, '_kl_log'],
  [/\b_taa_lib\b/g, '_kl_lib'],
  [/\b_taa_part\b/g, '_kl_part'],
  [/\.ts_[a-z_]+/g, m => '.kl_' + m.slice(3)],
];

/* 扫这些目录/文件；产物与依赖不碰（产物由 build 重新生成） */
const TARGETS = [];
function walk(dir, filter) {
  for (const name of fs.readdirSync(dir)) {
    if (name === 'node_modules' || name === 'dist' || name === '.git') continue;
    const p = path.join(dir, name);
    const st = fs.statSync(p);
    if (st.isDirectory()) walk(p, filter);
    else if (filter(name)) TARGETS.push(p);
  }
}
walk(path.join(repo, 'module'), n => /\.(sh|awk|pro)$/.test(n) || n === 'update-binary');
walk(path.join(repo, 'tests'), n => /\.(sh|js)$/.test(n));
walk(path.join(repo, 'tools'), n => /\.(mjs|cjs|sh)$/.test(n) && n !== 'rename-keylens.cjs');
walk(path.join(repo, 'webui', 'src'), n => /\.(js|css|html)$/.test(n));
TARGETS.push(path.join(repo, 'service.sh'));

let files = 0, hits = 0;
const perFile = [];
for (const f of TARGETS) {
  if (!fs.existsSync(f)) continue;
  const before = fs.readFileSync(f, 'utf8');
  let after = before;
  for (const [re, to] of RULES) {
    after = after.replace(re, typeof to === 'function' ? to : to);
  }
  if (after !== before) {
    const n = (before.match(/(\.ts_|TAA_|_taa_)/g) || []).length;
    files++; hits += n;
    perFile.push([path.relative(repo, f).replace(/\\/g, '/'), n]);
    if (!DRY) fs.writeFileSync(f, after);
  }
}
perFile.sort((a, b) => b[1] - a[1]);
console.log(`${DRY ? '将改' : '已改'} ${files} 个文件、约 ${hits} 处旧前缀`);
perFile.forEach(([f, n]) => console.log(`   ${String(n).padStart(4)}  ${f}`));
