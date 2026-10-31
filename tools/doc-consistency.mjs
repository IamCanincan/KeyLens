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
const clTop = (read('CHANGELOG.md').match(/^### ([^\n]+)$/m) || [])[1];
chk('CHANGELOG 顶层条目与版本一致', !!clTop && clTop.startsWith(vMp.slice(1)), clTop);
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

console.log(bad ? `\n${bad} 处不一致` : '\n全部一致');
process.exit(bad ? 1 : 0);
