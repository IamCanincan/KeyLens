import { build } from 'esbuild';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const entry = process.argv[2] || 'entry-all.js';
const out = process.argv[3] || 'probe.bundle.js';

const r = await build({
  entryPoints: [path.join(here, entry)],
  outfile: path.join(here, out),
  bundle: true,
  format: 'iife',
  minify: true,
  target: 'chrome111',
  legalComments: 'none',
  logLevel: 'warning',
  metafile: true,
});

const bytes = fs.statSync(path.join(here, out)).size;
const inputs = Object.entries(r.metafile.inputs)
  .filter(([k]) => k.includes('md3e-web'))
  .map(([k, v]) => [k.replace(/^.*md3e-web\//, ''), v.bytesInOutput || 0])
  .sort((a, b) => b[1] - a[1]);
console.log(`入口 ${entry}  →  ${out}  ${(bytes / 1024).toFixed(0)} KB（${inputs.length} 个源文件）`);
console.log('最重的 12 个：');
for (const [k, v] of inputs.slice(0, 12)) console.log(`  ${(v / 1024).toFixed(1).padStart(7)} KB  ${k}`);
