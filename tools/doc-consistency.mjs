#!/usr/bin/env node
/* 文档一致性闸门：许可、版本、链接、文档声明 vs 实现。
 * 为什么需要：README 曾经写着 GPL-3.0 而 LICENSE 文件是 MIT、宣称"批量增删/6 秒撤销"
 * 而那套界面早已退役 —— 文档过时不会让任何测试变红，只会让用户读到假话。
 * 跑法：node tools/doc-consistency.mjs   （有不一致退 1）
 */
import fs from 'node:fs';
import { execFileSync } from 'node:child_process';

const read = f => fs.readFileSync(f, 'utf8');
let bad = 0;
const chk = (name, ok, detail) => { if (!ok) bad++; console.log(`${ok ? 'ok  ' : '✗   '} ${name}${detail !== undefined ? '  — ' + detail : ''}`); };

/* A. 许可证：LICENSE 文件是权威，README 必须与之一致 */
const lic = read('LICENSE');
const isMIT = /^MIT License/.test(lic);
const isGPL = /GNU GENERAL PUBLIC LICENSE/.test(lic);
chk('LICENSE 是已知许可（MIT / GPL-3.0）', isMIT || isGPL);
const rd = read('README.md');
chk('README 许可表述与 LICENSE 一致',
  isMIT ? !/GPL/.test(rd) : /GPL-3\.0/.test(rd),
  (rd.match(/^[^\n]*(GPL|MIT)[^\n]*$/m) || [])[0]);
chk('THIRD_PARTY_NOTICES 列了 @material/web 的 Apache-2.0',
  /@material\/web/.test(read('module/THIRD_PARTY_NOTICES.md')));

/* B. 版本：四处必须一致 */
const mp = read('module/module.prop');
const vMp = (mp.match(/^version=(.*)$/m) || [])[1];
const cMp = (mp.match(/^versionCode=(.*)$/m) || [])[1];
const uj = JSON.parse(read('update.json'));
chk('module.prop ↔ update.json 版本一致', vMp === uj.version && Number(cMp) === uj.versionCode,
  `${vMp}/${cMp} vs ${uj.version}/${uj.versionCode}`);
chk('README 页脚版本一致', rd.includes(vMp));
/* CHANGELOG 的形状：允许顶上挂**一条**「未发布」，但它下面第一个已发布条目
   必须就是 module.prop 那个版本 —— 原来这条闸只认"顶层 = 当前版本"，于是
   两次发版之间的工作没法进 CHANGELOG（只能等发版时才补，文档就落后于代码）。 */
const clHeads = [...read('CHANGELOG.md').matchAll(/^### ([^\n]+)$/gm)].map(m => m[1]);
const clTop = clHeads[0];
const unreleased = clHeads.filter(h => /未发布/.test(h));
const firstReleased = clHeads.find(h => !/未发布/.test(h));
chk('CHANGELOG 最多一条「未发布」，且只能在最顶上',
  unreleased.length <= 1 && (unreleased.length === 0 || /未发布/.test(clTop)),
  `未发布 ${unreleased.length} 条 / 顶层=${clTop}`);
chk('CHANGELOG 第一个已发布条目 = module.prop 的版本',
  !!firstReleased && firstReleased.startsWith(vMp.slice(1)),
  `首个已发布=${firstReleased} vs ${vMp}`);
chk('update.json zipUrl 指向本仓库与当前版本',
  uj.zipUrl.includes(vMp) && uj.zipUrl.startsWith('https://github.com/IamCanincan/KeyLens/'));
chk('module.prop updateJson 指向本仓库', /IamCanincan\/KeyLens/.test(mp));

/* C. README 声明 vs 实现 */
chk('README 不再宣称批量增删/撤销（已退役）', !/批量增删|6 秒内撤销/.test(rd));
chk('多选/撤销确实已退役（bridge.js 的说明）', /退役/.test(read('webui/src/bridge.js')));
chk('README 的自动同步页描述与实现一致', /守护进程状态、上次写入时间/.test(rd));
chk('module.prop 描述含三家后端',
  /Tricky Store/.test((mp.match(/^description=(.*)$/m) || [])[1] || ''));

/* D. 文档引用的文件存在 */
chk('README 引用的 LICENSE 存在', fs.existsSync('LICENSE'));

/* E. 会随代码漂移的计数：文档写的对拍条数必须等于台子里的下限常量。
   本轮就同时存在过 242 / 261 / 266 / 269 几种说法 —— 每加一条 chk 文档就过期一次，
   而"文档落后于代码"不会让任何东西变红，只会让用户读到假话。
   注意是**所有**出现处（正文表格 + §2 的跑法注释），漏一处就等于没钉。 */
const pf = (read('rust/parity.sh').match(/\[ "\$oks" -lt (\d+) \]/) || [])[1];
const docCounts = [...read('docs/HANDOFF.md').matchAll(/(\d+) 项 chk/g)].map(m => m[1]);
chk('HANDOFF 里每一处对拍条数都 = parity.sh 的下限',
  !!pf && docCounts.length >= 2 && docCounts.every(c => c === pf),
  `文档=${docCounts.join('/') || '没写'} vs 下限=${pf || '没找到'}`);

console.log(bad ? `\n${bad} 处不一致` : '\n全部一致');
process.exit(bad ? 1 : 0);
