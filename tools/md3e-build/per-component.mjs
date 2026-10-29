import { build } from 'esbuild';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

/* 逐个组件量"单独引它要多少字节"：共享运行时（motion/theme/utils）会被每个
   都算进去，所以这一列是上界；真正的取舍看排序，不看绝对和。 */
const here = path.dirname(fileURLToPath(import.meta.url));
const PKG = path.join(here, 'node_modules/@materialwebunofficial/md3e-web/src/components');
const names = fs.readdirSync(PKG).filter(f => f.startsWith('md-') && f.endsWith('.js')).map(f => f.replace(/\.js$/, ''));
const tmp = path.join(here, '_one.js');
const out = path.join(here, '_one.bundle.js');
const rows = [];
for (const n of names) {
  fs.writeFileSync(tmp, `import '@materialwebunofficial/md3e-web/components/${n}.js';\n`);
  await build({
    entryPoints: [tmp], outfile: out, bundle: true, format: 'iife',
    minify: true, target: 'chrome111', legalComments: 'none', logLevel: 'silent',
  });
  rows.push([n, fs.statSync(out).size]);
}
fs.rmSync(tmp, { force: true }); fs.rmSync(out, { force: true });
rows.sort((a, b) => b[1] - a[1]);
for (const [n, b] of rows) console.log(`${(b / 1024).toFixed(0).padStart(5)} KB  ${n}`);
