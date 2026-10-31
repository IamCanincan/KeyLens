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

echo "── status（探测 + 文件/进程/日志计数）──"
mk_status_harness() { # <root>
  {
    echo 'TAB=$(printf "\t")'
    echo 'NL=$(printf "\nX"); NL=${NL%X}'
    echo '. module/lib/core.sh'
    echo '. module/lib/tools.sh'
    echo '. module/lib/backend.sh'
    echo '. module/lib/props.sh'
    echo "TSTORE_DIR='$1/data/adb/tricky_store'"
    echo "TEESIM_DIR='$1/data/adb/teesim'"
    echo "TEESIM_CONFIG='$1/data/adb/teesim/config.json'"
    echo "OMK_DIR='$1/data/misc/keystore/omk'"
    echo "OMK_INJECTOR='$1/data/misc/keystore/omk/injector.toml'"
    echo "OMK_STATE_DIR='$1/data/adb/omk'"
    echo "TRICKY_MODULE='$1/data/adb/modules/tricky_store'"
    echo "TEESIM_MODULE='$1/data/adb/modules/teesim'"
    echo "OMK_MODULE='$1/data/adb/modules/oh_my_keymint'"
    echo "KL_LOG='$1/data/adb/keylens.log'"
    echo "KL_PROPS_OFF='$1/data/adb/keylens.props_off'"
    echo "MODDIR='$PWD/module'"
    echo "PROP_FILE='$1/data/adb/modules/keylens/module.prop'"
    echo 'MODULE_PROP_CACHE=""'
  } > "$T/h2.sh"
  sed -n '/^mod_prop() {/,/^}/p' module/webui.sh >> "$T/h2.sh"
  sed -n '/^backend_state() {/,/^}/p' module/webui.sh >> "$T/h2.sh"
  sed -n '/^cmd_status() {/,/^}/p' module/webui.sh >> "$T/h2.sh"
  sed -n '/^backend_keybox_path() {/,/^}/p' module/webui.sh >> "$T/h2.sh"
  cat >> "$T/h2.sh" <<'EOF'
kv() { printf '%s=%s\n' "$1" "$2"; }
detect_backend "$MODDIR"
cmd_status
EOF
}
S="$T/sroot"
mkdir -p "$S/data/adb/modules/oh_my_keymint" "$S/data/adb/modules/keylens" \
         "$S/data/misc/keystore/omk" "$S/data/adb/omk"
printf 'id=keylens\nversion=v3.0.1\ndescription=✅ [OhMyKeymint | 应用: 3]\n' > "$S/data/adb/modules/keylens/module.prop"
printf 'scoop = ["a"]\n' > "$S/data/misc/keystore/omk/injector.toml"
printf 'a\nb\n' > "$S/data/adb/keylens.log"
sleep 300 & SPID=$!
trap 'kill $SPID 2>/dev/null; rm -rf "$T"' EXIT
printf '%s\n' "$SPID" > "$S/data/adb/omk/.kl_daemon_pids.list"
mk_status_harness "$S"
chk 'status：omk 正常态' "$(sh "$T/h2.sh")" "$(KEYLENS_ROOT="$S" "$B" status)"

# 冲突 + 关闭属性伪装 + 目标文件缺失
S2="$T/sroot2"
mkdir -p "$S2/data/adb/modules/teesim" "$S2/data/adb/modules/tricky_store" \
         "$S2/data/adb/modules/oh_my_keymint" "$S2/data/adb/modules/keylens" "$S2/data/adb/omk"
printf 'id=keylens\nversion=v3.0.1\ndescription=⛔ 同时启用了多个后端\n' > "$S2/data/adb/modules/keylens/module.prop"
: > "$S2/data/adb/keylens.props_off"
mk_status_harness "$S2"
chk 'status：冲突/stopped/关闭伪装/目标缺失' "$(sh "$T/h2.sh")" "$(KEYLENS_ROOT="$S2" "$B" status)"

echo "── targets（tricky：注释/后缀/重复/坏行）──"
mk_targets_harness() { # <root>
  {
    echo 'TAB=$(printf "\t")'
    echo 'NL=$(printf "\nX"); NL=${NL%X}'
    echo '. module/lib/core.sh'
    echo '. module/lib/tools.sh'
    echo '. module/lib/backend.sh'
    echo "TSTORE_DIR='$1/data/adb/tricky_store'"
    echo "TEESIM_DIR='$1/data/adb/teesim'"
    echo "TEESIM_CONFIG='$1/data/adb/teesim/config.json'"
    echo "OMK_DIR='$1/data/misc/keystore/omk'"
    echo "OMK_INJECTOR='$1/data/misc/keystore/omk/injector.toml'"
    echo "OMK_STATE_DIR='$1/data/adb/omk'"
    echo "TRICKY_MODULE='$1/data/adb/modules/tricky_store'"
    echo "TEESIM_MODULE='$1/data/adb/modules/teesim'"
    echo "OMK_MODULE='$1/data/adb/modules/oh_my_keymint'"
    echo "MODDIR='$PWD/module'"
    echo "KL_PATCH='$PWD/module/backends/tricky.awk'"
  } > "$T/h3.sh"
  sed -n '/^cmd_targets() {/,/^}/p' module/webui.sh >> "$T/h3.sh"
  cat >> "$T/h3.sh" <<'EOF'
detect_backend "$MODDIR"
cmd_targets
EOF
}
TT="$T/troot"
mkdir -p "$TT/data/adb/modules/tricky_store" "$TT/data/adb/tricky_store"
cat > "$TT/data/adb/tricky_store/target.txt" <<'EOF'
# 注释行
com.example.a
com.example.b?
com.example.b!   # 行尾注释
  com.example.c!
com.example.d
bad_line
com..x
com.example.a?
com.example.e   ?   
EOF
mk_targets_harness "$TT"
chk 'tricky target.txt 解析' "$(sh "$T/h3.sh")" "$(KEYLENS_ROOT="$TT" "$B" targets)"
# 目标文件缺失：两边都要报错退出 1
TT2="$T/troot2"
mkdir -p "$TT2/data/adb/modules/tricky_store"
mk_targets_harness "$TT2"
sh "$T/h3.sh" >/dev/null 2>"$T/e1"; rc1=$?
KEYLENS_ROOT="$TT2" "$B" targets >/dev/null 2>"$T/e2"; rc2=$?
chk '目标文件缺失：退出码一致' "$rc1" "$rc2"
chk '目标文件缺失：报错文案一致' "$(cat "$T/e1")" "$(cat "$T/e2")"

# teesim：profiles.default.apps（work 的 apps 不许出现；default 内有嵌套对象）
TS="$T/tsroot"
mkdir -p "$TS/data/adb/modules/teesim" "$TS/data/adb/teesim"
cat > "$TS/data/adb/teesim/config.json" <<'EOF'
{"version":1,"profiles":{"work":{"apps":["should.not.appear"]},"default":{"patchLevel":{"system":"today"},"apps":["com.a","com.b@10"]}}}
EOF
mk_targets_harness "$TS"
chk 'teesim default.apps（跳过嵌套与其它 profile）' "$(sh "$T/h3.sh")" "$(KEYLENS_ROOT="$TS" "$B" targets)"

# omk：scoop 数组（注释/多行/[scoop.pkg] 段不误匹配）
OS="$T/osroot"
mkdir -p "$OS/data/adb/modules/oh_my_keymint" "$OS/data/misc/keystore/omk"
cat > "$OS/data/misc/keystore/omk/injector.toml" <<'EOF'
# comment
[main]
log_level = "info"

scoop = [
  "com.x",
  "com.y",
]

[scoop.com.z]
deny = true
EOF
mk_targets_harness "$OS"
chk 'omk scoop 数组（注释/多行/段名不误匹配）' "$(sh "$T/h3.sh")" "$(KEYLENS_ROOT="$OS" "$B" targets)"

echo "── target-meta（三家 tok/base/kind/detail）──"
mk_meta_harness() { # <root>
  {
    echo 'TAB=$(printf "\t")'
    echo 'NL=$(printf "\nX"); NL=${NL%X}'
    echo '. module/lib/core.sh'
    echo '. module/lib/tools.sh'
    echo '. module/lib/backend.sh'
    echo "TSTORE_DIR='$1/data/adb/tricky_store'"
    echo "TEESIM_DIR='$1/data/adb/teesim'"
    echo "TEESIM_CONFIG='$1/data/adb/teesim/config.json'"
    echo "OMK_DIR='$1/data/misc/keystore/omk'"
    echo "OMK_INJECTOR='$1/data/misc/keystore/omk/injector.toml'"
    echo "OMK_STATE_DIR='$1/data/adb/omk'"
    echo "TRICKY_MODULE='$1/data/adb/modules/tricky_store'"
    echo "TEESIM_MODULE='$1/data/adb/modules/teesim'"
    echo "OMK_MODULE='$1/data/adb/modules/oh_my_keymint'"
    echo "MODDIR='$PWD/module'"
    echo "KL_PATCH='$PWD/module/backends/tricky.awk'"
  } > "$T/h4.sh"
  sed -n '/^cmd_targets() {/,/^}/p' module/webui.sh >> "$T/h4.sh"
  sed -n '/^cmd_target_meta() {/,/^}/p' module/webui.sh >> "$T/h4.sh"
  cat >> "$T/h4.sh" <<'EOF'
detect_backend "$MODDIR"
cmd_target_meta
EOF
}
# tricky：沿用 $TT（?→leaf、!→generate、其余 auto）
mk_meta_harness "$TT"
chk 'meta tricky：leaf/generate/auto' "$(sh "$T/h4.sh")" "$(KEYLENS_ROOT="$TT" "$B" target-meta)"
# teesim：@用户 / uid: 两种
TS2="$T/ts2"
mkdir -p "$TS2/data/adb/modules/teesim" "$TS2/data/adb/teesim"
cat > "$TS2/data/adb/teesim/config.json" <<'EOF'
{"profiles":{"default":{"apps":["com.a","com.b@10","uid:10123"]}}}
EOF
mk_meta_harness "$TS2"
chk 'meta teesim：user/uid/plain' "$(sh "$T/h4.sh")" "$(KEYLENS_ROOT="$TS2" "$B" target-meta)"
# omk：一律 plain
mk_meta_harness "$OS"
chk 'meta omk：plain' "$(sh "$T/h4.sh")" "$(KEYLENS_ROOT="$OS" "$B" target-meta)"

echo "── apps（cmd/pm 输出 → 去前缀/去[N]/排序去重）──"
mkdir -p "$T/bin"
cat > "$T/bin/cmd" <<'EOF'
#!/bin/sh
printf 'package:com.b\npackage:com.a\npackage:com.a\npackage:com.c[10]\npackage:com.d[2]\n'
EOF
chmod +x "$T/bin/cmd"
sed -n '/^cmd_apps() {/,/^}/p' module/webui.sh > "$T/apps.sh"
chk 'apps：去重/去[N]/排序' "$(PATH="$T/bin:$PATH" sh -c '. "$1"; cmd_apps' sh "$T/apps.sh")" "$(PATH="$T/bin:$PATH" "$B" apps)"

echo "── excluded（已装 ∩ ever ∖ 当前目标）──"
ex_harness() { # <root>
  {
    echo 'TAB=$(printf "\t")'
    echo 'NL=$(printf "\nX"); NL=${NL%X}'
    echo '. module/lib/core.sh'
    echo '. module/lib/tools.sh'
    echo '. module/lib/backend.sh'
    echo '. module/lib/applist.sh'
    echo "TSTORE_DIR='$1/data/adb/tricky_store'"
    echo "TEESIM_DIR='$1/data/adb/teesim'"
    echo "TEESIM_CONFIG='$1/data/adb/teesim/config.json'"
    echo "OMK_DIR='$1/data/misc/keystore/omk'"
    echo "OMK_INJECTOR='$1/data/misc/keystore/omk/injector.toml'"
    echo "OMK_STATE_DIR='$1/data/adb/omk'"
    echo "TRICKY_MODULE='$1/data/adb/modules/tricky_store'"
    echo "TEESIM_MODULE='$1/data/adb/modules/teesim'"
    echo "OMK_MODULE='$1/data/adb/modules/oh_my_keymint'"
    echo "MODDIR='$PWD/module'"
    echo "KL_PATCH='$PWD/module/backends/tricky.awk'"
  } > "$T/h5.sh"
  sed -n '/^cmd_excluded() {/,/^}/p' module/webui.sh >> "$T/h5.sh"
  cat >> "$T/h5.sh" <<'EOF'
detect_backend "$MODDIR"
cmd_excluded
EOF
}
EX="$T/exroot"
mkdir -p "$EX/data/adb/modules/tricky_store" "$EX/data/adb/tricky_store"
printf 'com.a\ncom.b?\n' > "$EX/data/adb/tricky_store/target.txt"
printf 'com.a\ncom.b\ncom.c\ncom.d\n' > "$EX/data/adb/tricky_store/.kl_ever"
cat > "$T/bin/cmd" <<'EOF'
#!/bin/sh
printf 'package:com.a\npackage:com.b\npackage:com.c\npackage:com.d\npackage:com.e\n'
EOF
ex_harness "$EX"
chk 'excluded：ever 内但不在目标里' "$(PATH="$T/bin:$PATH" sh "$T/h5.sh")" "$(PATH="$T/bin:$PATH" KEYLENS_ROOT="$EX" "$B" excluded)"

# 无 ever 文件：两边都必须空
EX2="$T/exroot2"
mkdir -p "$EX2/data/adb/modules/tricky_store" "$EX2/data/adb/tricky_store"
printf 'com.a\n' > "$EX2/data/adb/tricky_store/target.txt"
ex_harness "$EX2"
chk 'excluded：无 ever 时为空' "$(PATH="$T/bin:$PATH" sh "$T/h5.sh")" "$(PATH="$T/bin:$PATH" KEYLENS_ROOT="$EX2" "$B" excluded)"

echo "── boot-hash（configured/current/status）──"
H64=1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef
mkdir -p "$T/bhroot/data/adb"
printf '%s' "$H64" > "$T/bhroot/data/adb/keylens.boot_hash"
{ echo '#!/bin/sh'; echo "printf '%s\n' '$H64'"; } > "$T/bin/getprop"
chmod +x "$T/bin/getprop"
cat > "$T/bh.sh" <<'EOF'
. module/lib/props.sh
kv() { printf '%s=%s\n' "$1" "$2"; }
prop_now() { PROP_NOW=$(getprop "$1" 2>/dev/null); [ -n "$PROP_NOW" ] || PROP_NOW=""; }
EOF
sed -n '/^cmd_boot_hash() {/,/^}/p' module/webui.sh >> "$T/bh.sh"
echo 'cmd_boot_hash' >> "$T/bh.sh"
chk 'boot-hash：ok' "$(PATH="$T/bin:$PATH" KL_BOOT_HASH="$T/bhroot/data/adb/keylens.boot_hash" sh "$T/bh.sh")" "$(PATH="$T/bin:$PATH" KEYLENS_ROOT="$T/bhroot" "$B" boot-hash)"
rm -f "$T/bhroot/data/adb/keylens.boot_hash"
chk 'boot-hash：unset' "$(PATH="$T/bin:$PATH" KL_BOOT_HASH="$T/bhroot/data/adb/keylens.boot_hash" sh "$T/bh.sh")" "$(PATH="$T/bin:$PATH" KEYLENS_ROOT="$T/bhroot" "$B" boot-hash)"

echo
[ "$fail" = 0 ] && echo "全部通过" || { echo "有断言失败"; exit 1; }
