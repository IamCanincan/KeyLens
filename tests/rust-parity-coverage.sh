#!/bin/sh
# rust-parity-coverage：已迁移的每条命令都必须有对拍（rust/parity.sh 里真的调用过它）。
# 理由：迁移工作最容易漏的不是实现，而是"实现了却没测"——那种命令在未迁移清单里消失、
# 却没有任何行为断言守着，之后被改坏也没人知道。
set -u
cd "$(dirname "$0")/.." || exit 1
RUST=rust/src/main.rs
PAR=rust/parity.sh
[ -f "$RUST" ] && [ -f "$PAR" ] || { echo "缺少 $RUST 或 $PAR"; exit 1; }

# 分发表里的命令名：形如  "targets" => read_cmds::targets(),
impl=$(sed -n 's/^[[:space:]]*"\([a-z-]*\)"[[:space:]]*=>[[:space:]]*read_cmds::.*/\1/p' "$RUST" | sort -u)
[ -n "$impl" ] || { echo "分发表里没解析到任何命令"; exit 1; }

miss=""
n=0
for c in $impl; do
  n=$((n + 1))
  # 对拍脚本里必须提到该命令（按整词匹配：`log` 不会误中 `log7`）
  if ! grep -qw -- "$c" "$PAR"; then
    miss="$miss $c"
  fi
done
if [ -n "$miss" ]; then
  echo "✗ 以下已迁移命令在 rust/parity.sh 里没有对拍调用：$miss"
  exit 1
fi
echo "✓ 已迁移 $n 条命令，全部有对拍调用"
