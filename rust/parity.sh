#!/bin/sh
# 契约/行为对拍：Rust 版与 shell 版逐字节一致才算过。
# 用法：rust/parity.sh [二进制路径]（默认 rust/target/release/keylens）
set -u
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

echo "── help（逐字节）──"
sed -n '/^cmd_help() {/,/^}/p' module/webui.sh > "$T/help.sh"
chk 'help 输出逐字节一致' "$(sh -c '. "$1"; cmd_help' sh "$T/help.sh")" "$($B help)"

echo "── log（进程内等价，取自 webui.sh 的真函数）──"
sed -n '/^clamp_int() {/,/^}/p' module/webui.sh > "$T/fn.sh"
sed -n '/^cmd_log() {/,/^}/p' module/webui.sh >> "$T/fn.sh"
printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\n' > "$T/log7"
printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7' > "$T/log7nonl"
printf 'only\n' > "$T/log1"
: > "$T/empty"
shell_log() { sh -c '. "$1"; KL_LOG="$2"; ARG="$3"; cmd_log' sh "$T/fn.sh" "$1" "$2"; }
rust_log() { KEYLENS_LOG="$1" "$B" log "$2"; }
for case in "log7:5" "log7:0" "log7:999" "log7:abc" "log7:1" "log7nonl:2" "log1:60"; do
  f=${case%%:*}; n=${case##*:}
  chk "log $f $n" "$(shell_log "$T/$f" "$n")" "$(rust_log "$T/$f" "$n")"
done
chk 'log 空文件' "$(shell_log "$T/empty" 5)" "$(rust_log "$T/empty" 5)"
chk 'log 文件不存在（logcat 兜底）' "$(shell_log "$T/nope" 5)" "$(rust_log "$T/nope" 5)"

echo "── backups（后端探测 + .bak 映射，夹具根走 KEYLENS_ROOT）──"
# shell 侧：source 真 lib + 抽 webui.sh 里的 cmd_backups / tsv / backend_keybox_path，
# 把路径常量覆盖到夹具，再跑 detect_backend + cmd_backups。
mk_harness() { # <root>
  {
    echo 'TAB=$(printf "\t")'
    echo '. module/lib/core.sh'
    echo '. module/lib/tools.sh'
    echo '. module/lib/backend.sh'
    echo "TSTORE_DIR='$1/data/adb/tricky_store'"
    echo "TEESIM_DIR='$1/data/adb/teesim'"
    echo "TEESIM_CONFIG='$1/data/adb/teesim/config.json'"
    echo "OMK_DIR='$1/data/misc/keystore/omk'"
    echo "OMK_INJECTOR='$1/data/misc/keystore/omk/injector.toml'"
    echo "OMK_STATE_DIR='$1/data/adb/omk'"
    echo "MODDIR='$PWD/module'"
  } > "$T/harness.sh"
  sed -n '/^tsv() {/,/^    }/p' module/webui.sh >> "$T/harness.sh"
  sed -n '/^cmd_backups() {/,/^}/p' module/webui.sh >> "$T/harness.sh"
  sed -n '/^backend_keybox_path() {/,/^}/p' module/webui.sh >> "$T/harness.sh"
  cat >> "$T/harness.sh" <<'EOF'
tsv() { local IFS="$TAB"; printf '%s\n' "$*"; }
detect_backend "$MODDIR"
cmd_backups
EOF
}
R="$T/root"
mkdir -p "$R/data/adb/modules/oh_my_keymint" "$R/data/misc/keystore/omk" "$R/data/adb/omk" \
         "$R/data/adb/tricky_store" "$R/data/adb/modules/tricky_store"
printf 'x' > "$R/data/misc/keystore/omk/injector.toml"
printf 'y' > "$R/data/misc/keystore/omk/config.toml"
printf 'k' > "$R/data/misc/keystore/omk/keybox.xml"
printf 'old' > "$R/data/adb/omk/injector.toml.bak"
printf 'older' > "$R/data/adb/omk/config.toml.bak"
printf 'kb' > "$R/data/adb/omk/keybox.xml.bak"
printf 'zz' > "$R/data/adb/omk/unknown.bak"
touch -d '2026-01-02 03:04:05' "$R/data/adb/omk/injector.toml.bak"
mk_harness "$R"
chk 'omk：列出 .bak 且映射正确' "$(sh "$T/harness.sh")" "$(KEYLENS_ROOT="$R" "$B" backups)"

# tricky 夹具：security_patch.txt.bak + keybox.xml.bak
R2="$T/root2"
mkdir -p "$R2/data/adb/modules/tricky_store" "$R2/data/adb/tricky_store"
printf 'a.b\n' > "$R2/data/adb/tricky_store/target.txt"
printf 'old' > "$R2/data/adb/tricky_store/security_patch.txt.bak"
printf 'kb' > "$R2/data/adb/tricky_store/keybox.xml.bak"
mk_harness "$R2"
chk 'tricky：security_patch 与 keybox 映射' "$(sh "$T/harness.sh")" "$(KEYLENS_ROOT="$R2" "$B" backups)"

# 空目录：两边都必须无输出
R3="$T/root3"
mkdir -p "$R3/data/adb/modules/teesim" "$R3/data/adb/teesim"
mk_harness "$R3"
chk 'teesim 无备份：空输出' "$(sh "$T/harness.sh")" "$(KEYLENS_ROOT="$R3" "$B" backups)"

echo
[ "$fail" = 0 ] && echo "全部通过" || { echo "有断言失败"; exit 1; }
