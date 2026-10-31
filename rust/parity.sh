#!/bin/sh
# 契约对拍：Rust 版 contract 输出必须与 webui.sh 的 KL_COMMANDS 逐字节一致。
# 用法：rust/parity.sh [二进制路径]（默认 rust/target/release/keylens）
set -eu
cd "$(dirname "$0")/.."
B=${1:-rust/target/release/keylens}
[ -x "$B" ] || { echo "缺少二进制：$B（先 cargo build --release）" >&2; exit 1; }
E=$(awk '
/^KL_COMMANDS="/{f=1; sub(/^KL_COMMANDS="/,"")}
f {
  had = /"$/
  sub(/\\$/,""); sub(/"$/,"")
  printf "%s ", $0
  if (had) exit
}' module/webui.sh | tr -s ' ' | sed 's/ $//')
A=$($B contract | sed -n 's/^commands=//p')
if [ "$E" = "$A" ]; then
  echo "PARITY OK: $(printf '%s' "$A" | wc -w) commands"
else
  echo "PARITY FAIL"
  echo "E=[$E]"
  echo "A=[$A]"
  exit 1
fi
[ "$($B contract | head -1)" = "api=4" ] || { echo "api 号不一致"; exit 1; }
echo "api=4 OK"
