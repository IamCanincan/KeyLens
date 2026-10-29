import { build } from 'esbuild';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

/* 留一法量"边际成本"：单个组件的绝对值把共享运行时重复算了 46 遍，
   真正该看的是"从这套里拿掉它，整包能小多少"。 */
const here = path.dirname(fileURLToPath(import.meta.url));
const SET = fs.readFileSync(path.join(here, 'entry.js'), 'utf8')
  .split('\n').map(l => (l.match(/components\/(md-[a-z-]+)\.js/) || [])[1]).filter(Boolean);
const tmp = path.join(here, '_loo.js');
const out = path.join(here, '_loo.bundle.js');

async function sizeOf(list) {
  fs.writeFileSync(tmp, list.map(n => `import '@materialwebunofficial/md3e-web/components/${n}.js';`).join('\n') + '\n');
  await build({ entryPoints: [tmp], outfile: out, bundle: true, format: 'iife', minify: true, target: 'chrome111', legalComments: 'none', logLevel: 'silent' });
  return fs.statSync(out).size;
}

const full = await sizeOf(SET);
console.log(`这套 ${SET.length} 个组件：${(full / 1024).toFixed(0)} KB\n`);
const rows = [];
for (const n of SET) rows.push([n, full - await sizeOf(SET.filter(x => x !== n))]);
rows.sort((a, b) => b[1] - a[1]);
for (const [n, d] of rows) console.log(`  拿掉 ${n.padEnd(24)} 省 ${(d / 1024).toFixed(0).padStart(4)} KB`);
fs.rmSync(tmp, { force: true }); fs.rmSync(out, { force: true });
