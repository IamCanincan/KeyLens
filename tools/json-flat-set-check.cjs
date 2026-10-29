'use strict';
/* json_flat_set.awk 的台架：改完必须还能 JSON.parse，且只动该动的那个键。
   删除分支要吃掉逗号与行空白 —— 这种手工偏移最容易留下 `{,}` 或 `{"a":1,,}`，
   而"看起来差不多"的 JSON 是守护进程读不出来的东西。 */
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const repo = path.resolve(__dirname, '..');
const AWK = path.join(repo, 'module/backends/json_flat_set.awk');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'jfs-'));
/* 一律换成正斜杠：gawk 的 `-v 名=值` 会对值做转义展开，Windows 路径里的
   `\Users\...\Temp\` 会被啃成 `Users20653...`，于是 awk 根本找不到 pairs 文件 ——
   报出来的是一串"escape sequence 当作普通字母"的警告，而测试只看到"什么都没改"。
   （设备上路径本来就是 /data/...，这条只影响这个台架。） */
const fwd = (p) => p.replace(/\\/g, '/');
let bad = 0;

function run(json, pairs) {
  const jf = fwd(path.join(dir, 'in.json'));
  const pf = fwd(path.join(dir, 'pairs'));
  const sf = fwd(path.join(dir, 'status'));
  fs.writeFileSync(jf, json);
  fs.writeFileSync(pf, pairs.map(p => p.join('\t')).join('\n') + (pairs.length ? '\n' : ''));
  let out;
  try {
    out = execFileSync('awk', ['-v', 'pairsfile=' + pf, '-v', 'statusfile=' + sf, '-f', AWK, jf],
      { encoding: 'utf8' });
  } catch (e) {
    const s = (b) => b ? (Buffer.isBuffer(b) ? b.toString('utf8') : String(b)) : '';
    return { status: 'CRASH', out: '', err: s(e.buffer && e.buffer.stdout) + s(e.stderr) + s(e.message) };
  }
  return { status: fs.existsSync(path.join(dir, 'status')) ? fs.readFileSync(path.join(dir, 'status'), 'utf8').trim() : '(没写状态)', out };
}

function chk(name, json, pairs, wantKeys, wantStatus) {
  const r = run(json, pairs);
  if (r.status === 'CRASH') { console.log(`✗   ${name} — awk 崩了：${r.err.split('\n')[0]}`); bad++; return; }
  let doc = null, perr = '';
  try { doc = JSON.parse(r.out); } catch (e) { perr = e.message; }
  const keys = doc ? Object.keys(doc).sort().join(',') : '(解析失败)';
  const want = wantKeys.slice().sort().join(',');
  const okStatus = !wantStatus || r.status === wantStatus;
  const ok = !perr && keys === want && okStatus;
  console.log(`${ok ? 'ok  ' : '✗   '} ${name}  状态=${r.status} 键=${keys}`
    + (perr ? `  JSON 解析失败：${perr}` : '')
    + (!okStatus && !perr ? `  期望状态 ${wantStatus}` : '')
    + (keys !== want && !perr ? `  期望键 ${want}` : ''));
  if (!ok) console.log('      产物：' + JSON.stringify(r.out));
  bad += ok ? 0 : 1;
}

const pretty = '{\n  "attestationVersion": "300",\n  "attestationSecurityLevel": "1",\n  "verifiedBootKey": "aa"\n}\n';
console.log('── 删除：中间 / 第一条 / 最后一条 / 唯一一条 ──');
chk('删中间', pretty, [['attestationVersion', '']], ['attestationSecurityLevel', 'verifiedBootKey'], 'ok');
chk('删第一条', pretty, [['attestationSecurityLevel', '']], ['attestationVersion', 'verifiedBootKey'], 'ok');
chk('删最后一条', pretty, [['verifiedBootKey', '']], ['attestationVersion', 'attestationSecurityLevel'], 'ok');
chk('删唯一一条', '{\n  "a": "1"\n}\n', [['a', '']], [], 'ok');
chk('全删空', pretty, [['attestationVersion', ''], ['attestationSecurityLevel', ''], ['verifiedBootKey', '']], [], 'ok');

console.log('── 删除：压成一行的紧凑写法 ──');
chk('紧凑·删第一条', '{"a":"1","b":"2","c":"3"}', [['a', '']], ['b', 'c'], 'ok');
chk('紧凑·删中间', '{"a":"1","b":"2","c":"3"}', [['b', '']], ['a', 'c'], 'ok');
chk('紧凑·删最后', '{"a":"1","b":"2","c":"3"}', [['c', '']], ['a', 'b'], 'ok');

console.log('── 写入与新增 ──');
chk('改一个值', pretty, [['attestationVersion', '301']], ['attestationVersion', 'attestationSecurityLevel', 'verifiedBootKey'], 'ok');
chk('加一个新键', pretty, [['moduleHash', 'bb']], ['attestationVersion', 'attestationSecurityLevel', 'verifiedBootKey', 'moduleHash'], 'ok');
chk('改+加+删混在一单', pretty, [['attestationVersion', '301'], ['osVersion', '14'], ['verifiedBootKey', '']],
  ['attestationSecurityLevel', 'attestationVersion', 'osVersion'], 'ok');
chk('空对象里加', '{}', [['a', '1']], ['a'], 'ok');
chk('值里带引号要转义', '{}', [['a', 'x"y\\z']], ['a'], 'ok');
const esc = run('{}', [['a', 'x"y\\z']]);
console.log(`${JSON.parse(esc.out).a === 'x"y\\z' ? 'ok  ' : '✗   '} 转义回来还是原值  — ${JSON.stringify(esc.out.trim())}`);
if (JSON.parse(esc.out).a !== 'x"y\\z') bad++;

console.log('── 幂等与不动其它键 ──');
chk('写回同样的值 = same', pretty, [['attestationVersion', '300']], ['attestationVersion', 'attestationSecurityLevel', 'verifiedBootKey'], 'same');
chk('删一个本来就没有的键 = same', pretty, [['nope', '']], ['attestationVersion', 'attestationSecurityLevel', 'verifiedBootKey'], 'same');
const keep = run(pretty, [['attestationVersion', '301']]);
const sameBytes = keep.out.split('\n').filter((l, i) => pretty.split('\n')[i] && l !== pretty.split('\n')[i]).length;
console.log(`${sameBytes <= 1 ? 'ok  ' : '✗   '} 只动了那一行（差异行数 ${sameBytes}）`);
if (sameBytes > 1) bad++;
/* 未知键必须原样留着：上游以后加字段，这里不能吃掉 */
chk('未知键保留', '{\n  "futureField": "x",\n  "a": "1"\n}\n', [['a', '2']], ['futureField', 'a'], 'ok');

fs.rmSync(dir, { recursive: true, force: true });
console.log(bad ? `\n✗ ${bad} 项不通过` : '\n全部通过');
process.exit(bad ? 1 : 0);
