#!/usr/bin/env node
/* 改名残留闸门：老模块名只许出现在**白名单**里。
 *
 * 为什么需要这道闸：KeyLens 改名一共动了约 500 处（`.ts_lock` 30 处、`KL_DIR`
 * 原来叫 TAA_DIR 108 处…），散在 23 个文件里。靠人眼保证的结果一定是"改了我记得
 * 的那几处"，而漏一处锁名 = 守护进程与界面各拿一把锁 = 同时写坏配置文件，
 * 这种坏只在特定时序下出现，测试未必撞得到。所以把"不许有残留"变成一条会红的断言。
 *
 * 白名单 = 保留老名字是**功能必需**的地方：
 *   · 清理老版本遗留在用户机器上的文件名（taa_sys.txt / taa_resetprop.sh /
 *     /data/adb/ts_auto.*）——按旧名才找得到；
 *   · 迁移函数的源路径与它读的旧 glob；
 *   · 更新说明与仓库 URL（CHANGELOG / RELEASE_NOTES / update.json / README 的
 *     github.com/IamCanincan/TS-AUTO-ADD —— 仓库改名由人做，不是我）。
 *
 * 跑法：node tools/name-residue-check.mjs   （有非白名单残留就退 1）
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '..');

const OLD = /ts-auto-add|TS-AUTO-ADD|ts_auto|\bTAA_|_taa_|\.ts_[a-z*]/;
/* 产物是压缩过的一整行，`.ts_x` / `TAA_` 这种模式会在噪音里乱咬；
   对产物只查**身份字符串**（标题、路径、模块 id），那才是真会跟着上机的东西。 */
const OLD_ARTIFACT = /ts-auto-add|TS-AUTO-ADD|ts_auto/;
const isArtifact = (rel) => rel === 'module/webroot/index.html';

/* 整文件豁免 */
const SKIP_FILES = new Set([
  'CHANGELOG.md', 'RELEASE_NOTES.md', 'update.json',
  'tools/rename-keylens.cjs',            // 改名脚本自己当然认得旧名
  'tools/name-residue-check.mjs',        // 本文件
]);
/* 整目录/产物豁免（产物由 build 重新生成；依赖不是我们的代码） */
const SKIP_DIR = /(node_modules|[/\\]dist[/\\]|[/\\]\.git[/\\])/;
/* 行级豁免按**文件**给：全局放行 `ts_auto` 会把 README 里过期的日志路径一起放过，
   那道闸就成了假闸。旧名字只许出现在"必须按旧名找东西"的那几个文件里。 */
const LINE_OK_ANY = [
  /改名|旧名|老名字|上一版|旧版|原 TS-AUTO-ADD/,   // 讲改名这件事本身的说明文字
  /github\.com\/IamCanincan\/TS-AUTO-ADD/,        // 仓库 URL：改名由人做
  /img\.shields\.io|actions\/workflows|releases\/download/, // 徽章/发布链接
];
const LINE_OK_BY_FILE = {
  'module/lib/core.sh': [/KL_LEGACY_/, /ts_auto/, /\.ts_\*/],       // 迁移源路径与它的 glob
  'module/uninstall.sh': [/ts_auto/],                                // 升级后卸载要清旧文件
  'module/customize.sh': [/taa_sys|taa_resetprop/],                   // 老版本遗留文件名
  'tools/deploy-webui.sh': [/ts-auto-add/, /ts_auto/],
  'tools/replay-check.mjs': [/ts-auto-add/, /ts_auto/],
  'tools/rename-keylens.cjs': [/.*/],
  'tests/legacy-migrate.sh': [/\.ts_|ts_auto|taa_|TAA_/],   // 迁移测试必须点名旧文件才能测
  'README.md': [/改名|旧名/],
  '.gitignore': [/.*/],
};

/* 文件清单只认 git 跟踪的那些：仓库根目录里那两个对话导出 .md 不是项目文件，
   未跟踪的临时产物也不该参与判定 —— 闸门的语料必须是"会发出去的东西"。 */
import { execFileSync } from 'node:child_process';
const tracked = new Set(execFileSync('git', ['ls-files'], { cwd: repo, encoding: 'utf8' })
  .split('\n').map(s => s.trim()).filter(Boolean));

const walk = (dir, out) => {
  for (const name of fs.readdirSync(dir)) {
    const p = path.join(dir, name);
    if (SKIP_DIR.test(p)) continue;
    const rel = path.relative(repo, p).replace(/\\/g, '/');
    const st = fs.statSync(p);
    if (st.isDirectory()) { walk(p, out); continue; }
    if (SKIP_FILES.has(rel)) continue;
    if (!tracked.has(rel)) continue;
    if (!/\.(sh|awk|js|mjs|cjs|md|json|pro|html|yml|txt)$/.test(name) && !/(update-binary|installer-script)/.test(name)) continue;
    out.push(rel);
  }
  return out;
};

let bad = 0, checked = 0;
const hits = [];
const byFile = {};
for (const rel of walk(repo, [])) {
  checked++;
  const pat = isArtifact(rel) ? OLD_ARTIFACT : OLD;
  const lines = fs.readFileSync(path.join(repo, rel), 'utf8').split('\n');
  const allow = (LINE_OK_BY_FILE[rel] || []).concat(LINE_OK_ANY);
  lines.forEach((l, i) => {
    if (!pat.test(l)) return;
    if (allow.some(re => re.test(l))) return;
    byFile[rel] = (byFile[rel] || 0) + 1;
    hits.push(`${rel}:${i + 1}  ${l.trim().slice(0, 96)}`);
  });
}
bad = hits.length;
console.log(`扫了 ${checked} 个 git 跟踪的文件，老名字残留：${hits.length} 处（白名单外）`);
Object.entries(byFile).sort((a, b) => b[1] - a[1]).forEach(([f, n]) => console.log(`   ${String(n).padStart(4)}  ${f}`));
hits.slice(0, 20).forEach(h => console.log('✗   ' + h));
if (hits.length > 20) console.log(`    …另 ${hits.length - 20} 处`);
console.log(bad ? '✗ 有非白名单残留' : '✓ 老名字只留在白名单里（更新说明、旧文件名清理、仓库 URL）');
process.exit(bad ? 1 : 0);
