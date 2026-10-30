/* 找出用 KL_PATCH 却没有先 detect_backend 的命令函数（每次调用都是新进程，
   KL_PATCH 只在 use_backend 里赋值 —— 没调的读命令会拿到空路径，
   真机上的表现是"缺少 xxx.awk"，而界面把它当成"这一块还没有内容"）。

   2026-10-31 由 cmd_tricky_patches 的真机 bug 提炼；除 backend_keybox_path
   （helper，调用方都已解析过后端）外，仓库里不许再出现无初始化的用法。 */
const fs = require('fs');
const src = fs.readFileSync('module/webui.sh', 'utf8').split('\n');
/* backend_keybox_path 是"调用方已解析完后端之后的 helper"：它的每个调用点
   （cmd_keybox_save）都先 detect_backend。这里显式豁免并在注释里点名，
   新增调用点要在评审里自己确认。 */
const ALLOW = new Set(['backend_keybox_path']);
const fns = [];
let cur = null;
src.forEach((line, i) => {
  if (/^[a-z_]+\s*\(\)\s*\{/.test(line) || /^function\s+[a-z_]+\s*\(\)\s*\{/.test(line)) {
    cur = { name: line.split('(')[0].trim(), start: i + 1, lines: [] };
    fns.push(cur);
  }
  if (cur) cur.lines.push(line);
});
let bad = 0;
for (const f of fns) {
  /* backend_keybox_path 是"调用方已解析完后端之后的 helper"：唯一调用点
     （cmd_keybox_save）先 detect_backend。这里显式豁免并点名；新增调用点
     要在评审里自己确认。 */
  if (f.name === 'backend_keybox_path') continue;
  const body = f.lines.join('\n');
  if (!/KL_PATCH%\/\*/.test(body)) continue;
  if (/detect_backend|use_backend/.test(body)) continue;
  console.log('✗ ' + f.name + ' (line ' + f.start + ') 用了 KL_PATCH 却没有 detect_backend');
  bad = 1;
}
console.log(bad ? '有未初始化的用法' : '所有 KL_PATCH 用户都先解析了后端');
process.exit(bad ? 1 : 0);
