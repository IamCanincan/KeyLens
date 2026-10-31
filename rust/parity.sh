#!/bin/sh
# 契约/行为对拍：Rust 版与 shell 版逐字节一致才算过。
# 用法：rust/parity.sh [二进制路径]（默认 rust/target/release/keylens）
set -eu
cd "$(dirname "$0")/.."
B=${1:-rust/target/release/keylens}
[ -x "$B" ] || { echo "缺少二进制：$B（先 cargo build --release）" >&2; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  ✗    $1"; echo "       shell=[$2]"; echo "       rust =[$3]"; fail=1; fi; }

echo "── contract ──"
E=$(awk '
/^KL_COMMANDS="/{f=1; sub(/^KL_COMMANDS="/,"")}
f {
  had = /"$/
  sub(/\\$/,""); sub(/"$/,"")
  printf "%s ", $0
  if (had) exit
}' module/webui.sh | tr -s ' ' | sed 's/ $//')
A=$($B contract | sed -n 's/^commands=//p')
chk 'commands 列表逐字一致' "$E" "$A"
chk 'api 号一致' "api=4" "$($B contract | head -1)"

echo "── log（进程内等价，取自 webui.sh 的真函数）──"
# 抽真函数（抄一份的话，改坏实现测试也不会响）
sed -n '/^clamp_int() {/,/^}/p' module/webui.sh > "$T/fn.sh"
sed -n '/^cmd_log() {/,/^}/p' module/webui.sh >> "$T/fn.sh"
# 夹具：7 行 + 结尾无换行的那份（tail 语义的分界）
printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\n' > "$T/log7"
printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7' > "$T/log7nonl"
printf 'only\n' > "$T/log1"
shell_log() { # <file> <arg>
  sh -c '. "$1"; KL_LOG="$2"; ARG="$3"; cmd_log' sh "$T/fn.sh" "$1" "$2"
}
rust_log() { KEYLENS_LOG="$1" "$B" log "$2"; }
for case in "log7:5" "log7:0" "log7:999" "log7:abc" "log7:1" "log7nonl:2" "log1:60"; do
  f=${case%%:*}; n=${case##*:}
  chk "log $f $n" "$(shell_log "$T/$f" "$n")" "$(rust_log "$T/$f" "$n")"
done
# 空文件 / 文件不存在（退回 logcat，本机没有 → 两边都必须空）
: > "$T/empty"
chk 'log 空文件' "$(shell_log "$T/empty" 5)" "$(rust_log "$T/empty" 5)"
chk 'log 文件不存在（logcat 兜底）' "$(shell_log "$T/nope" 5)" "$(rust_log "$T/nope" 5)"

echo
[ "$fail" = 0 ] && echo "全部通过" || { echo "有断言失败"; exit 1; }
