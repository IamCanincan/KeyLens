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
oks=0
chk() { if [ "$2" = "$3" ]; then echo "  ok   $1"; oks=$((oks + 1)); else echo "  ✗    $1"; echo "       shell=[$2]"; echo "       rust =[$3]"; fail=1; fi; }

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

echo "── tee-status（无尾换行的四行键值）──"
TS3="$T/ts3"
mkdir -p "$TS3/data/adb/tricky_store"
printf 'status=ok\ncategory=tee\nserviceErrorCode=0\nteeBroken=false' > "$TS3/data/adb/tricky_store/tee_status"
cat > "$T/tee.sh" <<'EOF'
. module/lib/core.sh
. module/lib/backend.sh
kv() { printf '%s=%s\n' "$1" "$2"; }
TSTORE_DIR="$1"
EOF
sed -n '/^cmd_tee_status() {/,/^}/p' module/webui.sh >> "$T/tee.sh"
echo 'cmd_tee_status' >> "$T/tee.sh"
chk 'tee-status：四行含无尾换行' "$(sh "$T/tee.sh" "$TS3/data/adb/tricky_store")" "$(KEYLENS_ROOT="$TS3" "$B" tee-status)"
rm -f "$TS3/data/adb/tricky_store/tee_status"
chk 'tee-status：文件缺失 present=0' "$(sh "$T/tee.sh" "$TS3/data/adb/tricky_store")" "$(KEYLENS_ROOT="$TS3" "$B" tee-status)"

echo "── props（15 固定 + 2 特征替换）──"
cat > "$T/bin/getprop" <<'EOF'
#!/bin/sh
case "$1" in
  ro.boot.vbmeta.device_state) echo locked ;;
  ro.boot.verifiedbootstate) echo green ;;
  ro.boot.flash.locked) echo 1 ;;
  ro.boot.veritymode) echo enforcing ;;
  ro.boot.warranty_bit) echo 0 ;;
  ro.warranty_bit) echo 0 ;;
  ro.debuggable) echo 1 ;;
  ro.force.debuggable) echo 0 ;;
  ro.secure) : ;;
  ro.adb.secure) echo 1 ;;
  ro.build.type) echo user ;;
  ro.build.tags) echo release-keys ;;
  ro.vendor.boot.warranty_bit) echo 0 ;;
  ro.vendor.warranty_bit) echo 0 ;;
  vendor.boot.warranty_bit) echo 0 ;;
  ro.bootloader) echo engineering ;;
  ro.build.description) echo test-keys ;;
esac
EOF
chmod +x "$T/bin/getprop"
cat > "$T/pr.sh" <<'EOF'
. module/lib/props.sh
tsv() { local IFS="$(printf '\t')"; printf '%s\n' "$*"; }
prop_now() { PROP_NOW=$(getprop "$1" 2>/dev/null); [ -n "$PROP_NOW" ] || PROP_NOW=""; }
EOF
sed -n '/^cmd_props() {/,/^}/p' module/webui.sh >> "$T/pr.sh"
echo 'cmd_props' >> "$T/pr.sh"
chk 'props：missing/diff/ok 与规则行' "$(PATH="$T/bin:$PATH" sh "$T/pr.sh")" "$(PATH="$T/bin:$PATH" "$B" props)"

echo "── tricky-patches（global + 包段 + all=）──"
TP="$T/tproot"
mkdir -p "$TP/data/adb/modules/tricky_store" "$TP/data/adb/tricky_store"
cat > "$TP/data/adb/tricky_store/security_patch.txt" <<'EOF'
# 注释
2026-10-05
system=2026-10-01
[vendor]
vendor=2026-09-05
boot=2026-08-01
[com.example.a]
all=2026-07-01
# 行尾注释
[com.example.b]
system = 2026-06-01
EOF
cat > "$T/tp.sh" <<'EOF'
. module/lib/core.sh
. module/lib/tools.sh
. module/lib/backend.sh
MODDIR="$PWD/module"
EOF
sed -n '/^cmd_tricky_patches() {/,/^}/p' module/webui.sh >> "$T/tp.sh"
cat >> "$T/tp.sh" <<'EOF'
TSTORE_DIR="$1"
KL_PATCH="$PWD/module/backends/tricky.awk"
detect_backend "$MODDIR"
cmd_tricky_patches
EOF
chk 'tricky-patches：global/包段/all' "$(sh "$T/tp.sh" "$TP/data/adb/tricky_store")" "$(KEYLENS_ROOT="$TP" "$B" tricky-patches)"

echo "── teesim-overrides（overrides + harvested 可编辑性）──"
TO="$T/toroot"
mkdir -p "$TO/data/adb/modules/teesim" "$TO/data/adb/teesim"
cat > "$TO/data/adb/teesim/overrides.json" <<'EOF'
{"attestationSecurityLevel":2,"verifiedBootKey":"abc123","verifiedBootHash":null}
EOF
cat > "$TO/data/adb/teesim/harvested.json" <<'EOF'
{"overrides":{"attestationSecurityLevel":{"editable":false,"source":"required"},"verifiedBootKey":{"editable":true,"source":"synthesized"},"verifiedBootHash":{"editable":true,"source":"harvested"}}}
EOF
cat > "$T/to.sh" <<'EOF'
. module/lib/core.sh
. module/lib/tools.sh
. module/lib/backend.sh
MODDIR="$PWD/module"
KL_PATCH="$PWD/module/backends/teesim.awk"
TEESIM_DIR="$1"
TEESIM_CONFIG="$1/config.json"
TEESIM_MODULE="$1/../modules/teesim"
TRICKY_MODULE="$1/../modules/none-tricky"
OMK_MODULE="$1/../modules/none-omk"
detect_backend "$MODDIR"
EOF
sed -n '/^cmd_teesim_overrides() {/,/^}/p' module/webui.sh >> "$T/to.sh"
echo 'cmd_teesim_overrides' >> "$T/to.sh"
chk 'teesim-overrides：字段/可编辑/来源' "$(sh "$T/to.sh" "$TO/data/adb/teesim")" "$(KEYLENS_ROOT="$TO" "$B" teesim-overrides)"

echo "── teesim-profiles（多 profile 列表）──"
TSP="$T/tsp"
mkdir -p "$TSP/data/adb/modules/teesim" "$TSP/data/adb/teesim"
cat > "$TSP/data/adb/teesim/config.json" <<'EOF'
{"version":1,"profiles":{"work":{"keybox":"kb.xml","mode":"leaf","apps":["com.a","com.b"]},"default":{"apps":["com.x@10"]},"strong":{"mode":"generate","apps":[]}}}
EOF
cat > "$T/tsp.sh" <<'EOF'
. module/lib/core.sh
. module/lib/tools.sh
. module/lib/backend.sh
MODDIR="$PWD/module"
KL_PATCH="$PWD/module/backends/teesim.awk"
TEESIM_DIR="$1"
TEESIM_CONFIG="$1/config.json"
TEESIM_MODULE="$1/../modules/teesim"
TRICKY_MODULE="$1/../modules/none-tricky"
EOF
sed -n '/^cmd_teesim_profiles() {/,/^}/p' module/webui.sh >> "$T/tsp.sh"
echo 'detect_backend "$MODDIR"; cmd_teesim_profiles' >> "$T/tsp.sh"
chk 'teesim-profiles：default 在前 + 其余顺序' "$(sh "$T/tsp.sh" "$TSP/data/adb/teesim")" "$(KEYLENS_ROOT="$TSP" "$B" teesim-profiles)"

echo "── clear-log（删缓冲 + 写一条记录）──"
cat > "$T/cl.sh" <<'EOF'
. module/lib/core.sh
kv() { printf '%s=%s\n' "$1" "$2"; }
KL_LOG="$1"
EOF
sed -n '/^cmd_clear_log() {/,/^}/p' module/lib/write.sh >> "$T/cl.sh"
echo 'cmd_clear_log' >> "$T/cl.sh"
CLR="$T/clroot"
mkdir -p "$CLR/data/adb"
printf 'old line 1\nold line 2\n' > "$CLR/data/adb/keylens.log"
chk 'clear-log：stdout' "$(sh "$T/cl.sh" "$CLR/data/adb/keylens.log")" "$(KEYLENS_ROOT="$CLR" "$B" clear-log)"
chk 'clear-log：缓冲区只剩新记录' "$(grep -c '已清空运行日志缓冲' "$CLR/data/adb/keylens.log")" "1"

echo "── omk-restart（写 restart.<范围>，含拒绝路径）──"
mk_omk_harness() { # <root>
  {
    echo '. module/lib/core.sh'
    echo '. module/lib/tools.sh'
    echo '. module/lib/backend.sh'
    echo 'kv() { printf "%s=%s\n" "$1" "$2"; }'
    echo 'log_info() { :; }'
    echo "MODDIR='$PWD/module'"
    echo "TSTORE_DIR='$1/data/adb/tricky_store'"
    echo "TEESIM_DIR='$1/data/adb/teesim'"
    echo "TEESIM_CONFIG='$1/data/adb/teesim/config.json'"
    echo "OMK_DIR='$1/data/misc/keystore/omk'"
    echo "OMK_INJECTOR='$1/data/misc/keystore/omk/injector.toml'"
    echo "OMK_STATE_DIR='$1/data/adb/omk'"
    echo "TRICKY_MODULE='$1/data/adb/modules/tricky_store'"
    echo "TEESIM_MODULE='$1/data/adb/modules/teesim'"
    echo "OMK_MODULE='$1/data/adb/modules/oh_my_keymint'"
  } > "$T/omk.sh"
  sed -n '/^require_runnable() {/,/^}/p' module/webui.sh >> "$T/omk.sh"
  sed -n '/^cmd_omk_restart() {/,/^}/p' module/lib/write.sh >> "$T/omk.sh"
  echo 'cmd_omk_restart "$1"' >> "$T/omk.sh"
}
OKR="$T/okr"
mkdir -p "$OKR/data/adb/modules/oh_my_keymint" "$OKR/data/adb/omk"
mk_omk_harness "$OKR"
chk 'omk-restart：成功路径（含触发文件）' "$(sh "$T/omk.sh" keymint 2>&1)" "$(KEYLENS_ROOT="$OKR" "$B" omk-restart keymint 2>&1)"
chk 'omk-restart：触发文件已创建' "$([ -f "$OKR/data/adb/omk/restart.keymint" ] && echo yes)" "yes"
chk 'omk-restart：非法范围' "$(sh "$T/omk.sh" nope 2>&1)" "$(KEYLENS_ROOT="$OKR" "$B" omk-restart nope 2>&1)"
OKR2="$T/okr2"
mkdir -p "$OKR2/data/adb/modules/tricky_store" "$OKR2/data/adb/tricky_store"
mk_omk_harness "$OKR2"
chk 'omk-restart：后端不是 OMK' "$(sh "$T/omk.sh" all 2>&1)" "$(KEYLENS_ROOT="$OKR2" "$B" omk-restart all 2>&1)"
OKR3="$T/okr3"
mkdir -p "$OKR3/data/adb/modules/oh_my_keymint" "$OKR3/data/adb/modules/tricky_store" "$OKR3/data/adb/tricky_store" "$OKR3/data/adb/omk"
mk_omk_harness "$OKR3"
chk 'omk-restart：后端冲突拒绝' "$(sh "$T/omk.sh" all 2>&1)" "$(KEYLENS_ROOT="$OKR3" "$B" omk-restart all 2>&1)"

echo "── set-mode（Tricky 后缀改写 + 锁）──"
mk_mode_harness() { # <root>
  {
    echo 'TAB=$(printf "\t")'
    echo 'NL=$(printf "\nX"); NL=${NL%X}'
    echo '. module/lib/core.sh'
    echo '. module/lib/tools.sh'
    echo '. module/lib/backend.sh'
    echo '. module/lib/applist.sh'
    echo '. module/lib/lock.sh'
    echo 'kv() { printf "%s=%s\n" "$1" "$2"; }'
    echo 'log_info() { :; }'
    echo "MODDIR='$PWD/module'"
    echo "KL_PATCH='$PWD/module/backends/tricky.awk'"
    echo "TSTORE_DIR='$1/data/adb/tricky_store'"
    echo "TEESIM_DIR='$1/data/adb/teesim'"
    echo "TEESIM_CONFIG='$1/data/adb/teesim/config.json'"
    echo "OMK_DIR='$1/data/misc/keystore/omk'"
    echo "OMK_INJECTOR='$1/data/misc/keystore/omk/injector.toml'"
    echo "OMK_STATE_DIR='$1/data/adb/omk'"
    echo "TRICKY_MODULE='$1/data/adb/modules/tricky_store'"
    echo "TEESIM_MODULE='$1/data/adb/modules/teesim'"
    echo "OMK_MODULE='$1/data/adb/modules/oh_my_keymint'"
    echo "LOCK_TIMEOUT=2"
  } > "$T/md.sh"
  sed -n '/^webui_lock() {/,/^}/p' module/webui.sh >> "$T/md.sh"
  sed -n '/^require_runnable() {/,/^}/p' module/webui.sh >> "$T/md.sh"
  sed -n '/^cmd_set_mode() {/,/^}/p' module/lib/write.sh >> "$T/md.sh"
  echo 'detect_backend "$MODDIR"; cmd_set_mode "$1" "$2"' >> "$T/md.sh"
}
MD="$T/mdr"
mk_md_fixture() { # <dir>
  mkdir -p "$1/data/adb/modules/tricky_store" "$1/data/adb/tricky_store"
  printf 'com.a\ncom.b?\n# 注释\n  com.c   \n' > "$1/data/adb/tricky_store/target.txt"
}
MDS="$MD-s"; MDR="$MD-r"
mk_md_fixture "$MDS"; mk_md_fixture "$MDR"
mk_mode_harness "$MDS"
chk 'set-mode：改 auto→leaf（输出）' "$(sh "$T/md.sh" com.a leaf 2>&1)" "$(KEYLENS_ROOT="$MDR" "$B" set-mode com.a leaf 2>&1)"
chk 'set-mode：两侧写回结果逐字节一致' "$(cat "$MDS/data/adb/tricky_store/target.txt")" "$(cat "$MDR/data/adb/tricky_store/target.txt")"
chk 'set-mode：注释/缩进/行尾空白保留' "$(sed -n '3,4p' "$MDR/data/adb/tricky_store/target.txt")" "# 注释
  com.c   "
chk 'set-mode：同模式再改（changed=0）' "$(sh "$T/md.sh" com.a leaf 2>&1)" "$(KEYLENS_ROOT="$MDR" "$B" set-mode com.a leaf 2>&1)"
chk 'set-mode：不存在的包（changed=0）' "$(sh "$T/md.sh" com.zzz auto 2>&1)" "$(KEYLENS_ROOT="$MDR" "$B" set-mode com.zzz auto 2>&1)"
chk 'set-mode：非法包名' "$(sh "$T/md.sh" bad..pkg auto 2>&1)" "$(KEYLENS_ROOT="$MDR" "$B" set-mode bad..pkg auto 2>&1)"

echo "── props-on / props-off（开关文件）──"
mk_props_harness() { # <root>
  {
    echo '. module/lib/core.sh'
    echo '. module/lib/props.sh'
    echo 'kv() { printf "%s=%s\n" "$1" "$2"; }'
    echo 'log_info() { :; }'
    echo "KL_PROPS_OFF='$1/data/adb/keylens.props_off'"
  } > "$T/po.sh"
  sed -n '/^cmd_props_switch() {/,/^}/p' module/lib/write.sh >> "$T/po.sh"
  echo 'cmd_props_switch "$1"' >> "$T/po.sh"
}
PO="$T/po-root/data/adb"
mkdir -p "$PO"
mk_props_harness "$T/po-root"
chk 'props-off：输出一致' "$(sh "$T/po.sh" off 2>&1)" "$(KEYLENS_ROOT="$T/po-root" "$B" props-off 2>&1)"
chk 'props-off：开关文件存在且 600' "$(stat -c '%a' "$PO/keylens.props_off" 2>/dev/null)" "600"
chk 'props-on：输出一致' "$(sh "$T/po.sh" on 2>&1)" "$(KEYLENS_ROOT="$T/po-root" "$B" props-on 2>&1)"
chk 'props-on：开关文件已删除' "$([ -e "$PO/keylens.props_off" ] && echo exists || echo gone)" "gone"

echo "── props-boot-hash（保存/清除 + resetprop 应用）──"
BH="$T/bh-root"
mkdir -p "$BH/data/adb" "$T/rpdb"
cat > "$T/bin/resetprop" <<'EOF'
#!/bin/sh
db="${RP_DB:?}"
if [ "$1" = "-n" ]; then mkdir -p "$db"; printf '%s' "$3" > "$db/$2"; exit 0; fi
[ -f "$db/$1" ] && cat "$db/$1"
EOF
chmod +x "$T/bin/resetprop"
cat > "$T/pb.sh" <<'EOF'
. module/lib/core.sh
. module/lib/backend.sh
. module/lib/props.sh
kv() { printf "%s=%s\n" "$1" "$2"; }
log_info() { :; }
log_warn() { :; }
prop_now() { PROP_NOW=$(resetprop "$1" 2>/dev/null); [ -n "$PROP_NOW" ] || PROP_NOW=""; }
KL_BOOT_HASH="$1"
EOF
sed -n '/^require_runnable() {/,/^}/p' module/webui.sh >> "$T/pb.sh"
sed -n '/^cmd_set_boot_hash() {/,/^}/p' module/lib/write.sh >> "$T/pb.sh"
echo 'cmd_set_boot_hash "$2"' >> "$T/pb.sh"
H64B=1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef
chk 'props-boot-hash：设置并应用' "$(PATH="$T/bin:$PATH" RP_DB="$T/rpdb" sh "$T/pb.sh" "$BH/data/adb/keylens.boot_hash" "$H64B" 2>&1)" "$(PATH="$T/bin:$PATH" RP_DB="$T/rpdb" KEYLENS_ROOT="$BH" "$B" props-boot-hash "$H64B" 2>&1)"
chk 'props-boot-hash：文件存在且 600' "$(stat -c '%a' "$BH/data/adb/keylens.boot_hash")" "600"
chk 'props-boot-hash：非法哈希' "$(PATH="$T/bin:$PATH" RP_DB="$T/rpdb" sh "$T/pb.sh" "$BH/data/adb/keylens.boot_hash" zzzz 2>&1)" "$(PATH="$T/bin:$PATH" RP_DB="$T/rpdb" KEYLENS_ROOT="$BH" "$B" props-boot-hash zzzz 2>&1)"
chk 'props-boot-hash：清除' "$(PATH="$T/bin:$PATH" RP_DB="$T/rpdb" sh "$T/pb.sh" "$BH/data/adb/keylens.boot_hash" - 2>&1)" "$(PATH="$T/bin:$PATH" RP_DB="$T/rpdb" KEYLENS_ROOT="$BH" "$B" props-boot-hash - 2>&1)"
chk 'props-boot-hash：清除后文件消失' "$([ -e "$BH/data/adb/keylens.boot_hash" ] && echo exists || echo gone)" "gone"

echo "── props-apply（写一次 + 复核）──"
PA="$T/pa-root"
mkdir -p "$PA/data/adb" "$T/rpdb2"
cat > "$T/pa.sh" <<'EOF'
. module/lib/core.sh
. module/lib/backend.sh
. module/lib/props.sh
kv() { printf "%s=%s\n" "$1" "$2"; }
log_info() { :; }
log_warn() { :; }
tsv() { local IFS="$(printf '\t')"; printf '%s\n' "$*"; }
TAB=$(printf '\t')
prop_now() { PROP_NOW=$(resetprop "$1" 2>/dev/null); [ -n "$PROP_NOW" ] || PROP_NOW=""; }
props_readback() { props; }
KL_PROPS_OFF="$1"
KL_BOOT_HASH="$2"
EOF
sed -n '/^require_runnable() {/,/^}/p' module/webui.sh >> "$T/pa.sh"
sed -n '/^cmd_props() {/,/^}/p' module/webui.sh >> "$T/pa.sh"
sed -n '/^cmd_props_apply() {/,/^}/p' module/lib/write.sh >> "$T/pa.sh"
echo 'props_readback() { cmd_props; }' >> "$T/pa.sh"
echo 'cmd_props_apply' >> "$T/pa.sh"
# 期望表里故意留两项错的、一项缺的
cat > "$T/bin/resetprop" <<'EOF'
#!/bin/sh
db="${RP_DB:?}"
if [ "$1" = "-n" ]; then mkdir -p "$db"; printf '%s' "$3" > "$db/$2"; exit 0; fi
if [ "$1" = "--version" ]; then echo fake; exit 0; fi
[ -f "$db/$1" ] && cat "$db/$1"
EOF
chmod +x "$T/bin/resetprop"
mkdir -p "$T/rpdb2"
printf '0' > "$T/rpdb2/ro.debuggable"
printf 'user' > "$T/rpdb2/ro.build.type"
printf 'engineering-x' > "$T/rpdb2/ro.bootloader"
chk 'props-apply：写一次后复核（输出）' "$(PATH="$T/bin:$PATH" RP_DB="$T/rpdb2" sh "$T/pa.sh" "$PA/data/adb/keylens.props_off" "$PA/data/adb/keylens.boot_hash" 2>&1)" "$(PATH="$T/bin:$PATH" RP_DB="$T/rpdb2" KEYLENS_ROOT="$PA" "$B" props-apply 2>&1)"
chk 'props-apply：写入后的值' "$(cat "$T/rpdb2/ro.debuggable")/$(cat "$T/rpdb2/ro.bootloader")" "0/release"
mkdir -p "$PA/data/adb"; : > "$PA/data/adb/keylens.props_off"
chk 'props-apply：开关关闭时拒绝' "$(PATH="$T/bin:$PATH" RP_DB="$T/rpdb2" sh "$T/pa.sh" "$PA/data/adb/keylens.props_off" "$PA/data/adb/keylens.boot_hash" 2>&1)" "$(PATH="$T/bin:$PATH" RP_DB="$T/rpdb2" KEYLENS_ROOT="$PA" "$B" props-apply 2>&1)"
rm -f "$PA/data/adb/keylens.props_off"

echo "── tricky-drop-patch（删 [scope] 段）──"
mk_drop_harness() { # <root>
  {
    echo '. module/lib/core.sh'
    echo '. module/lib/tools.sh'
    echo '. module/lib/backend.sh'
    echo '. module/lib/lock.sh'
    echo 'kv() { printf "%s=%s\n" "$1" "$2"; }'
    echo 'log_info() { :; }'
    echo 'commit_backend_file() { cp "$1" "$1.pre"; cp "$2" "$1"; }'
    echo "MODDIR='$PWD/module'"
    echo "KL_PATCH='$PWD/module/backends/tricky.awk'"
    echo "TSTORE_DIR='$1/data/adb/tricky_store'"
    echo "TEESIM_DIR='$1/data/adb/teesim'"
    echo "TEESIM_CONFIG='$1/data/adb/teesim/config.json'"
    echo "OMK_DIR='$1/data/misc/keystore/omk'"
    echo "OMK_INJECTOR='$1/data/misc/keystore/omk/injector.toml'"
    echo "OMK_STATE_DIR='$1/data/adb/omk'"
    echo "TRICKY_MODULE='$1/data/adb/modules/tricky_store'"
    echo "TEESIM_MODULE='$1/data/adb/modules/teesim'"
    echo "OMK_MODULE='$1/data/adb/modules/oh_my_keymint'"
    echo "LOCK_TIMEOUT=2"
  } > "$T/dp.sh"
  sed -n '/^webui_lock() {/,/^}/p' module/webui.sh >> "$T/dp.sh"
  sed -n '/^require_runnable() {/,/^}/p' module/webui.sh >> "$T/dp.sh"
  sed -n '/^cmd_tricky_drop_patch() {/,/^}/p' module/lib/write.sh >> "$T/dp.sh"
  echo 'detect_backend "$MODDIR"; cmd_tricky_drop_patch "$1"' >> "$T/dp.sh"
}
DP="$T/dp-root"
mk_dp_fixture() {
  mkdir -p "$1/data/adb/modules/tricky_store" "$1/data/adb/tricky_store"
  cat > "$1/data/adb/tricky_store/security_patch.txt" <<'EOF'
2026-10-05
system=2026-10-01

# 说明：下面按包覆盖
[com.example.a]
all=2026-07-01

[com.example.b]
system=2026-06-01
EOF
  mkdir -p "$1/data/adb/tricky_store"
}
DPS="$DP-s"; DPR="$DP-r"
mk_dp_fixture "$DPS"; mk_dp_fixture "$DPR"
mk_drop_harness "$DPS"
chk 'drop-patch：删段输出' "$(sh "$T/dp.sh" com.example.a 2>&1)" "$(KEYLENS_ROOT="$DPR" "$B" tricky-drop-patch com.example.a 2>&1)"
chk 'drop-patch：两侧结果逐字节一致' "$(cat "$DPS/data/adb/tricky_store/security_patch.txt")" "$(cat "$DPR/data/adb/tricky_store/security_patch.txt")"
chk 'drop-patch：备份已生成' "$([ -f "$DPR/data/adb/tricky_store/security_patch.txt.bak" ] && echo yes)" "yes"
chk 'drop-patch：段不存在' "$(sh "$T/dp.sh" com.nothere 2>&1)" "$(KEYLENS_ROOT="$DPR" "$B" tricky-drop-patch com.nothere 2>&1)"
chk 'drop-patch：拒绝全局段' "$(sh "$T/dp.sh" global 2>&1)" "$(KEYLENS_ROOT="$DPR" "$B" tricky-drop-patch global 2>&1)"

echo "── tricky-save-patch（payload 写入）──"
mk_save_harness() { # <root>
  {
    echo 'TAB=$(printf "\t")'
    echo 'CR=$(printf "\r")'
    echo 'NL=$(printf "\nX"); NL=${NL%X}'
    echo '. module/lib/core.sh'
    echo '. module/lib/tools.sh'
    echo '. module/lib/backend.sh'
    echo '. module/lib/lock.sh'
    echo 'kv() { printf "%s=%s\n" "$1" "$2"; }'
    echo 'log_info() { :; }'
    echo 'lower() { printf "%s" "$1" | tr "A-Z" "a-z"; }'
    echo 'commit_backend_file() { cp "$2" "$1"; }'
    echo "MODDIR='$PWD/module'"
    echo "KL_PATCH='$PWD/module/backends/tricky.awk'"
    echo "TSTORE_DIR='$1/data/adb/tricky_store'"
    echo "TEESIM_DIR='$1/data/adb/teesim'"
    echo "TEESIM_CONFIG='$1/data/adb/teesim/config.json'"
    echo "OMK_DIR='$1/data/misc/keystore/omk'"
    echo "OMK_INJECTOR='$1/data/misc/keystore/omk/injector.toml'"
    echo "OMK_STATE_DIR='$1/data/adb/omk'"
    echo "TRICKY_MODULE='$1/data/adb/modules/tricky_store'"
    echo "TEESIM_MODULE='$1/data/adb/modules/teesim'"
    echo "OMK_MODULE='$1/data/adb/modules/oh_my_keymint'"
    echo "LOCK_TIMEOUT=2"
  } > "$T/sv.sh"
  sed -n '/^webui_lock() {/,/^}/p' module/webui.sh >> "$T/sv.sh"
  sed -n '/^require_runnable() {/,/^}/p' module/webui.sh >> "$T/sv.sh"
  sed -n '/^valid_tricky_patch() {/,/^}/p' module/webui.sh >> "$T/sv.sh"
  sed -n '/^parse_payload() {/,/^}/p' module/webui.sh >> "$T/sv.sh"
  sed -n '/^cmd_tricky_save_patch() {/,/^}/p' module/lib/write.sh >> "$T/sv.sh"
  echo 'detect_backend "$MODDIR"; cmd_tricky_save_patch "$1"' >> "$T/sv.sh"
}
SP="$T/sv-root"
mk_sp_fixture() {
  mkdir -p "$1/data/adb/modules/tricky_store" "$1/data/adb/tricky_store"
  printf '2026-10-05\nsystem=2026-10-01\n\n[com.example.a]\nsystem=2026-09-01\n' > "$1/data/adb/tricky_store/security_patch.txt"
}
SPS="$SP-s"; SPR="$SP-r"
mk_sp_fixture "$SPS"; mk_sp_fixture "$SPR"
mk_save_harness "$SPS"
# payload: patch_system -> 2026-10-07, patch_boot -> no
PL=$(printf 'patch_system=%s\npatch_boot=%s' "$(printf '2026-10-07' | base64)" "$(printf 'no' | base64)" | base64 | tr -d '\n')
chk 'save-patch：写入输出' "$(sh "$T/sv.sh" "$PL" 2>&1)" "$(KEYLENS_ROOT="$SPR" "$B" tricky-save-patch "$PL" 2>&1)"
chk 'save-patch：两侧结果逐字节一致' "$(cat "$SPS/data/adb/tricky_store/security_patch.txt")" "$(cat "$SPR/data/adb/tricky_store/security_patch.txt")"
chk 'save-patch：备份已生成' "$([ -f "$SPR/data/adb/tricky_store/security_patch.txt.bak" ] && echo yes)" "yes"
BAD=$(printf 'patch_system=%s' "$(printf '2026-13-01' | base64)" | base64 | tr -d '\n')
chk 'save-patch：非法补丁值' "$(sh "$T/sv.sh" "$BAD" 2>&1)" "$(KEYLENS_ROOT="$SPR" "$B" tricky-save-patch "$BAD" 2>&1)"

echo "── teesim-save-overrides（payload + 可编辑性 + 备份）──"
mk_ov_harness() { # <root>
  {
    echo 'TAB=$(printf "\t")'
    echo 'CR=$(printf "\r")'
    echo 'NL=$(printf "\nX"); NL=${NL%X}'
    echo '. module/lib/core.sh'
    echo '. module/lib/tools.sh'
    echo '. module/lib/backend.sh'
    echo '. module/lib/lock.sh'
    echo 'kv() { printf "%s=%s\n" "$1" "$2"; }'
    echo 'log_info() { :; }'
    echo 'lower() { printf "%s" "$1" | tr "A-Z" "a-z"; }'
    echo 'commit_backend_file() { cp "$2" "$1"; }'
    echo "MODDIR='$PWD/module'"
    echo "KL_PATCH='$PWD/module/backends/teesim.awk'"
    echo "TSTORE_DIR='$1/data/adb/tricky_store'"
    echo "TEESIM_DIR='$1/data/adb/teesim'"
    echo "TEESIM_CONFIG='$1/data/adb/teesim/config.json'"
    echo "OMK_DIR='$1/data/misc/keystore/omk'"
    echo "OMK_INJECTOR='$1/data/misc/keystore/omk/injector.toml'"
    echo "OMK_STATE_DIR='$1/data/adb/omk'"
    echo "TRICKY_MODULE='$1/data/adb/modules/none-tricky'"
    echo "TEESIM_MODULE='$1/data/adb/modules/teesim'"
    echo "OMK_MODULE='$1/data/adb/modules/none-omk'"
    echo "LOCK_TIMEOUT=2"
  } > "$T/ovs.sh"
  sed -n '/^webui_lock() {/,/^}/p' module/webui.sh >> "$T/ovs.sh"
  sed -n '/^require_runnable() {/,/^}/p' module/webui.sh >> "$T/ovs.sh"
  sed -n '/^valid_ov_level() {/,/^}/p' module/webui.sh >> "$T/ovs.sh"
  sed -n '/^valid_ov_version() {/,/^}/p' module/webui.sh >> "$T/ovs.sh"
  sed -n '/^valid_ov_hex() {/,/^}/p' module/webui.sh >> "$T/ovs.sh"
  sed -n '/^parse_payload() {/,/^}/p' module/webui.sh >> "$T/ovs.sh"
  sed -n '/^cmd_teesim_save_overrides() {/,/^}/p' module/lib/write.sh >> "$T/ovs.sh"
  echo 'detect_backend "$MODDIR"; cmd_teesim_save_overrides "$1"' >> "$T/ovs.sh"
}
OVS="$T/ovs-root"
mk_ov_fixture() {
  mkdir -p "$1/data/adb/modules/teesim" "$1/data/adb/teesim"
  printf '{\n    "attestationSecurityLevel": "1",\n    "attestationVersion": "300"\n}\n' > "$1/data/adb/teesim/overrides.json"
}
OVSS="$OVS-s"; OVSR="$OVS-r"
mk_ov_fixture "$OVSS"; mk_ov_fixture "$OVSR"
mk_ov_harness "$OVSS"
HX=$(printf '%064d' 0 | tr '0' 'a')
PLOV=$(printf 'attestationSecurityLevel=%s' "$(printf 2 | base64)" | base64 | tr -d '\n')
chk 'save-overrides：输出' "$(sh "$T/ovs.sh" "$PLOV" 2>&1)" "$(KEYLENS_ROOT="$OVSR" "$B" teesim-save-overrides "$PLOV" 2>&1)"
chk 'save-overrides：两侧文件逐字节一致' "$(cat "$OVSS/data/adb/teesim/overrides.json")" "$(cat "$OVSR/data/adb/teesim/overrides.json")"
chk 'save-overrides：备份已生成' "$([ -f "$OVSR/data/adb/teesim/overrides.json.bak" ] && echo yes)" "yes"
printf '{"overrides":{"verifiedBootHash":{"editable":false,"source":"harvested"}}}\n' > "$OVSR/data/adb/teesim/harvested.json"
printf '{"overrides":{"verifiedBootHash":{"editable":false,"source":"harvested"}}}\n' > "$OVSS/data/adb/teesim/harvested.json"
BADOV=$(printf 'verifiedBootHash=%s' "$(printf '%s' "$HX" | base64 | tr -d '\n')" | base64 | tr -d '\n')
chk 'save-overrides：不可编辑字段拒绝' "$(sh "$T/ovs.sh" "$BADOV" 2>&1)" "$(KEYLENS_ROOT="$OVSR" "$B" teesim-save-overrides "$BADOV" 2>&1)"

echo "── keybox-save（结构校验 + 备份 + 600）──"
mk_kb_harness() { # <root>
  {
    echo 'TAB=$(printf "\t")'
    echo 'NL=$(printf "\nX"); NL=${NL%X}'
    echo '. module/lib/core.sh'
    echo '. module/lib/tools.sh'
    echo '. module/lib/backend.sh'
    echo '. module/lib/lock.sh'
    echo 'kv() { printf "%s=%s\n" "$1" "$2"; }'
    echo 'log_info() { :; }'
    echo 'commit_backend_file() { [ -f "$1" ] && cp "$1" "$1.bak"; cp "$2" "$1"; }'
    echo 'backend_name() { case "$KL_BACKEND" in teesim) echo "TEE Simulator";; omk) echo "OhMyKeymint";; *) echo "Tricky Store";; esac; }'
    echo "MODDIR='$PWD/module'"
    echo "KL_PATCH='$PWD/module/backends/tricky.awk'"
    echo "TSTORE_DIR='$1/data/adb/tricky_store'"
    echo "TEESIM_DIR='$1/data/adb/teesim'"
    echo "TEESIM_CONFIG='$1/data/adb/teesim/config.json'"
    echo "OMK_DIR='$1/data/misc/keystore/omk'"
    echo "OMK_INJECTOR='$1/data/misc/keystore/omk/injector.toml'"
    echo "OMK_STATE_DIR='$1/data/adb/omk'"
    echo "TRICKY_MODULE='$1/data/adb/modules/tricky_store'"
    echo "TEESIM_MODULE='$1/data/adb/modules/none-teesim'"
    echo "OMK_MODULE='$1/data/adb/modules/none-omk'"
    echo "LOCK_TIMEOUT=2"
  } > "$T/kb.sh"
  sed -n '/^webui_lock() {/,/^}/p' module/webui.sh >> "$T/kb.sh"
  sed -n '/^require_runnable() {/,/^}/p' module/webui.sh >> "$T/kb.sh"
  sed -n '/^backend_keybox_path() {/,/^}/p' module/webui.sh >> "$T/kb.sh"
  sed -n '/^cmd_keybox_save() {/,/^}/p' module/lib/write.sh >> "$T/kb.sh"
  echo 'detect_backend "$MODDIR"; backend_keybox_path; cmd_keybox_save "$1"' >> "$T/kb.sh"
}
KB="$T/kb-root"
mk_kb_fixture() {
  mkdir -p "$1/data/adb/modules/tricky_store" "$1/data/adb/tricky_store"
  printf '<AndroidAttestation><Keybox><Key algorithm="ec"><PrivateKey>p</PrivateKey><CertificateChain><Certificate>c</Certificate></CertificateChain></Key></Keybox></AndroidAttestation>\n' > "$1/data/adb/tricky_store/keybox.xml"
}
KBS="$KB-s"; KBR="$KB-r"
mk_kb_fixture "$KBS"; mk_kb_fixture "$KBR"
mk_kb_harness "$KBS"
NEWKB='<AndroidAttestation><Keybox><Key algorithm="ec"><PrivateKey>NEWPRIV</PrivateKey><CertificateChain><Certificate>c1</Certificate></CertificateChain></Key></Keybox></AndroidAttestation>'
KBPL=$(printf '%s' "$NEWKB" | base64 | tr -d '\n')
chk 'keybox-save：输出' "$(sh "$T/kb.sh" "$KBPL" 2>&1 | sed 's/kb-root-[sr]/kb-root/g')" "$(KEYLENS_ROOT="$KBR" "$B" keybox-save "$KBPL" 2>&1 | sed 's/kb-root-[sr]/kb-root/g')"
chk 'keybox-save：两侧文件逐字节一致' "$(cat "$KBS/data/adb/tricky_store/keybox.xml")" "$(cat "$KBR/data/adb/tricky_store/keybox.xml")"
chk 'keybox-save：备份已生成' "$([ -f "$KBS/data/adb/tricky_store/keybox.xml.bak" ] && echo yes)" "$([ -f "$KBR/data/adb/tricky_store/keybox.xml.bak" ] && echo yes)"
BADKB='<Keybox><Key algorithm="ec"/></Keybox>'
BADPL=$(printf '%s' "$BADKB" | base64 | tr -d '\n')
chk 'keybox-save：结构不合格拒绝' "$(sh "$T/kb.sh" "$BADPL" 2>&1 | sed 's/kb-root-[sr]/kb-root/g')" "$(KEYLENS_ROOT="$KBR" "$B" keybox-save "$BADPL" 2>&1 | sed 's/kb-root-[sr]/kb-root/g')"

echo "── backup-restore（还原 + 保留权限）──"
mk_br_harness() { # <root>
  {
    echo '. module/lib/core.sh'
    echo '. module/lib/tools.sh'
    echo '. module/lib/backend.sh'
    echo '. module/lib/lock.sh'
    echo 'kv() { printf "%s=%s\n" "$1" "$2"; }'
    echo 'log_info() { :; }'
    echo "MODDIR='$PWD/module'"
    echo "KL_PATCH='$PWD/module/backends/tricky.awk'"
    echo "TSTORE_DIR='$1/data/adb/tricky_store'"
    echo "TEESIM_DIR='$1/data/adb/teesim'"
    echo "TEESIM_CONFIG='$1/data/adb/teesim/config.json'"
    echo "OMK_DIR='$1/data/misc/keystore/omk'"
    echo "OMK_INJECTOR='$1/data/misc/keystore/omk/injector.toml'"
    echo "OMK_STATE_DIR='$1/data/adb/omk'"
    echo "TRICKY_MODULE='$1/data/adb/modules/tricky_store'"
    echo "TEESIM_MODULE='$1/data/adb/modules/none-teesim'"
    echo "OMK_MODULE='$1/data/adb/modules/none-omk'"
    echo "LOCK_TIMEOUT=2"
  } > "$T/br.sh"
  sed -n '/^webui_lock() {/,/^}/p' module/webui.sh >> "$T/br.sh"
  sed -n '/^require_runnable() {/,/^}/p' module/webui.sh >> "$T/br.sh"
  sed -n '/^backend_keybox_path() {/,/^}/p' module/webui.sh >> "$T/br.sh"
  sed -n '/^cmd_backup_restore() {/,/^}/p' module/lib/write.sh >> "$T/br.sh"
  echo 'detect_backend "$MODDIR"; cmd_backup_restore "$1"' >> "$T/br.sh"
}
BR="$T/br-root"
mk_br_fixture() {
  mkdir -p "$1/data/adb/modules/tricky_store" "$1/data/adb/tricky_store"
  printf 'new\n' > "$1/data/adb/tricky_store/security_patch.txt"
  printf 'old\n' > "$1/data/adb/tricky_store/security_patch.txt.bak"
  chmod 640 "$1/data/adb/tricky_store/security_patch.txt"
}
BRS="$BR-s"; BRR="$BR-r"
mk_br_fixture "$BRS"; mk_br_fixture "$BRR"
mk_br_harness "$BRS"
chk 'backup-restore：输出' "$(sh "$T/br.sh" security_patch.txt.bak 2>&1)" "$(KEYLENS_ROOT="$BRR" "$B" backup-restore security_patch.txt.bak 2>&1)"
chk 'backup-restore：两侧文件逐字节一致' "$(cat "$BRS/data/adb/tricky_store/security_patch.txt")" "$(cat "$BRR/data/adb/tricky_store/security_patch.txt")"
chk 'backup-restore：权限保留 640' "$(stat -c '%a' "$BRS/data/adb/tricky_store/security_patch.txt")" "$(stat -c '%a' "$BRR/data/adb/tricky_store/security_patch.txt")"
chk 'backup-restore：非法备份名' "$(sh "$T/br.sh" '../etc/passwd' 2>&1)" "$(KEYLENS_ROOT="$BRR" "$B" backup-restore '../etc/passwd' 2>&1)"
chk 'backup-restore：后端无关的备份名' "$(sh "$T/br.sh" nope.bak 2>&1)" "$(KEYLENS_ROOT="$BRR" "$B" backup-restore nope.bak 2>&1)"

echo "── teesim-profile-del（删 profiles.<name>）──"
mk_pd_harness() { # <root>
  {
    echo 'TAB=$(printf "\t")'
    echo 'NL=$(printf "\nX"); NL=${NL%X}'
    echo '. module/lib/core.sh'
    echo '. module/lib/tools.sh'
    echo '. module/lib/backend.sh'
    echo '. module/lib/lock.sh'
    echo 'kv() { printf "%s=%s\n" "$1" "$2"; }'
    echo 'log_info() { :; }'
    echo 'commit_backend_file() { [ -f "$1" ] && cp "$1" "$1.bak"; cp "$2" "$1"; }'
    echo "MODDIR='$PWD/module'"
    echo "KL_PATCH='$PWD/module/backends/teesim.awk'"
    echo "TSTORE_DIR='$1/data/adb/tricky_store'"
    echo "TEESIM_DIR='$1/data/adb/teesim'"
    echo "TEESIM_CONFIG='$1/data/adb/teesim/config.json'"
    echo "OMK_DIR='$1/data/misc/keystore/omk'"
    echo "OMK_INJECTOR='$1/data/misc/keystore/omk/injector.toml'"
    echo "OMK_STATE_DIR='$1/data/adb/omk'"
    echo "TRICKY_MODULE='$1/data/adb/modules/none-tricky'"
    echo "TEESIM_MODULE='$1/data/adb/modules/teesim'"
    echo "OMK_MODULE='$1/data/adb/modules/none-omk'"
    echo "LOCK_TIMEOUT=2"
  } > "$T/pd.sh"
  sed -n '/^webui_lock() {/,/^}/p' module/webui.sh >> "$T/pd.sh"
  sed -n '/^require_runnable() {/,/^}/p' module/webui.sh >> "$T/pd.sh"
  sed -n '/^cmd_teesim_profile_del() {/,/^}/p' module/lib/write.sh >> "$T/pd.sh"
  echo 'detect_backend "$MODDIR"; cmd_teesim_profile_del "$1"' >> "$T/pd.sh"
}
PD="$T/pd-root"
mk_pd_fixture() {
  mkdir -p "$1/data/adb/modules/teesim" "$1/data/adb/teesim"
  printf '{\n    "profiles": {\n        "default": {"apps": []},\n        "work": {"apps": ["com.a"]},\n        "lab": {"apps": ["com.b"]}\n    }\n}\n' > "$1/data/adb/teesim/config.json"
}
PDS="$PD-s"; PDR="$PD-r"
mk_pd_fixture "$PDS"; mk_pd_fixture "$PDR"
mk_pd_harness "$PDS"
chk 'profile-del：删中间成员输出' "$(sh "$T/pd.sh" work 2>&1)" "$(KEYLENS_ROOT="$PDR" "$B" teesim-profile-del work 2>&1)"
chk 'profile-del：两侧 config 逐字节一致' "$(cat "$PDS/data/adb/teesim/config.json")" "$(cat "$PDR/data/adb/teesim/config.json")"
chk 'profile-del：备份已生成' "$([ -f "$PDR/data/adb/teesim/config.json.bak" ] && echo yes)" "yes"
chk 'profile-del：不存在' "$(sh "$T/pd.sh" nope 2>&1)" "$(KEYLENS_ROOT="$PDR" "$B" teesim-profile-del nope 2>&1)"
chk 'profile-del：拒绝 default' "$(sh "$T/pd.sh" default 2>&1)" "$(KEYLENS_ROOT="$PDR" "$B" teesim-profile-del default 2>&1)"

echo "── teesim-profile-new（复制 default）──"
mk_pn_harness() { # <root>
  {
    echo 'TAB=$(printf "\t")'
    echo 'NL=$(printf "\nX"); NL=${NL%X}'
    echo '. module/lib/core.sh'
    echo '. module/lib/tools.sh'
    echo '. module/lib/backend.sh'
    echo '. module/lib/lock.sh'
    echo 'kv() { printf "%s=%s\n" "$1" "$2"; }'
    echo 'log_info() { :; }'
    echo 'commit_backend_file() { [ -f "$1" ] && cp "$1" "$1.bak"; cp "$2" "$1"; }'
    echo "MODDIR='$PWD/module'"
    echo "KL_PATCH='$PWD/module/backends/teesim.awk'"
    echo "TSTORE_DIR='$1/data/adb/tricky_store'"
    echo "TEESIM_DIR='$1/data/adb/teesim'"
    echo "TEESIM_CONFIG='$1/data/adb/teesim/config.json'"
    echo "OMK_DIR='$1/data/misc/keystore/omk'"
    echo "OMK_INJECTOR='$1/data/misc/keystore/omk/injector.toml'"
    echo "OMK_STATE_DIR='$1/data/adb/omk'"
    echo "TRICKY_MODULE='$1/data/adb/modules/none-tricky'"
    echo "TEESIM_MODULE='$1/data/adb/modules/teesim'"
    echo "OMK_MODULE='$1/data/adb/modules/none-omk'"
    echo "LOCK_TIMEOUT=2"
  } > "$T/pn.sh"
  sed -n '/^webui_lock() {/,/^}/p' module/webui.sh >> "$T/pn.sh"
  sed -n '/^require_runnable() {/,/^}/p' module/webui.sh >> "$T/pn.sh"
  sed -n '/^cmd_teesim_profile_new() {/,/^}/p' module/lib/write.sh >> "$T/pn.sh"
  echo 'detect_backend "$MODDIR"; cmd_teesim_profile_new "$1"' >> "$T/pn.sh"
}
PN="$T/pn-root"
mk_pn_fixture() {
  mkdir -p "$1/data/adb/modules/teesim" "$1/data/adb/teesim"
  printf '{\n    "profiles": {\n        "default": {"apps": ["com.a"]}\n    }\n}\n' > "$1/data/adb/teesim/config.json"
}
PNS="$PN-s"; PNR="$PN-r"
mk_pn_fixture "$PNS"; mk_pn_fixture "$PNR"
mk_pn_harness "$PNS"
chk 'profile-new：输出' "$(sh "$T/pn.sh" work 2>&1)" "$(KEYLENS_ROOT="$PNR" "$B" teesim-profile-new work 2>&1)"
chk 'profile-new：两侧 config 逐字节一致' "$(cat "$PNS/data/adb/teesim/config.json")" "$(cat "$PNR/data/adb/teesim/config.json")"
chk 'profile-new：备份已生成' "$([ -f "$PNR/data/adb/teesim/config.json.bak" ] && echo yes)" "yes"
chk 'profile-new：已存在' "$(sh "$T/pn.sh" work 2>&1)" "$(KEYLENS_ROOT="$PNR" "$B" teesim-profile-new work 2>&1)"
chk 'profile-new：拒绝 default' "$(sh "$T/pn.sh" default 2>&1)" "$(KEYLENS_ROOT="$PNR" "$B" teesim-profile-new default 2>&1)"

echo "── 未迁移命令的契约（必须返回 2，不许假装成功）──"
LEFT="icons"
for c in $LEFT; do
  out=$($B "$c" 2>&1) ; rc=$?
  if [ "$rc" = 2 ] && printf '%s' "$out" | grep -q '尚未迁移'; then
    echo "  ok   $c 返回 2 且说明未迁移"
  else
    echo "  ✗    $c 期望返回 2 + 尚未迁移，实际 rc=$rc out=[$out]"; fail=1
  fi
done

echo "── 未迁移清单与实际实现的漂移闸 ──"
# 用空的 KEYLENS_ROOT 跑一遍，任何写命令都只会落在临时目录里，没有副作用。
mkdir -p "$T/empty" 2>/dev/null || true
ACTUAL=""
for c in $($B contract | sed -n 's/^commands=//p'); do
  KEYLENS_ROOT="$T/empty" "$B" "$c" >/dev/null 2>&1
  [ "$?" = 2 ] && ACTUAL="$ACTUAL $c"
done
ACTUAL=$(printf '%s' "$ACTUAL" | tr ' ' '\n' | sed '/^$/d' | sort | tr '\n' ' ' | sed 's/ $//')
DECL=$(printf '%s' "$LEFT" | tr ' ' '\n' | sed '/^$/d' | sort | tr '\n' ' ' | sed 's/ $//')
if [ "$ACTUAL" = "$DECL" ]; then
  echo "  ok   未迁移清单与实现一致（$(printf '%s' "$ACTUAL" | wc -w) 条）"
else
  echo "  ✗   清单漂移"; echo "       声明: $DECL"; echo "       实际: $ACTUAL"; fail=1
fi

echo "── 输出健壮性（EPIPE 不 panic）──"
$B contract 2>"$T/epipe.err" | head -1 >/dev/null
if grep -q panicked "$T/epipe.err"; then
  echo "  ✗   管道被下游关掉时 panic 了：$(head -1 "$T/epipe.err")"; fail=1
else
  echo "  ok   contract | head -1 不 panic"; oks=$((oks + 1))
fi

echo "── doctor（11 项自检）──"
mk_doc_harness() { # <root>
  {
    echo 'TAB=$(printf "\t")'
    echo 'CR=$(printf "\r")'
    echo 'NL=$(printf "\nX"); NL=${NL%X}'
    echo '. module/lib/core.sh'
    echo '. module/lib/tools.sh'
    echo '. module/lib/backend.sh'
    echo '. module/lib/props.sh'
    echo '. module/lib/applist.sh'
    echo '. module/lib/lock.sh'
    echo 'kv() { printf "%s=%s\n" "$1" "$2"; }'
    echo 'tsv() { local IFS="$(printf "\t")"; printf "%s\n" "$*"; }'
    echo 'print() { while [ "${1#-}" != "$1" ]; do shift; done; printf "%s\n" "$*"; }'
    echo 'log_info() { :; }'
    echo 'backend_name() { case "$KL_BACKEND" in teesim) echo "TEE Simulator";; omk) echo "OhMyKeymint";; *) echo "Tricky Store";; esac; }'
    echo "MODDIR='$PWD/module'"
    echo "KL_PATCH='$PWD/module/backends/tricky.awk'"
    echo "TSTORE_DIR='$1/data/adb/tricky_store'"
    echo "TEESIM_DIR='$1/data/adb/teesim'"
    echo "TEESIM_CONFIG='$1/data/adb/teesim/config.json'"
    echo "OMK_DIR='$1/data/misc/keystore/omk'"
    echo "OMK_INJECTOR='$1/data/misc/keystore/omk/injector.toml'"
    echo "OMK_STATE_DIR='$1/data/adb/omk'"
    echo "KL_LOG='$1/data/adb/keylens.log'"
    echo "KL_PROPS_OFF='$1/data/adb/keylens.props_off'"
    echo "KL_BOOT_HASH='$1/data/adb/keylens.boot_hash'"
    echo "PROP_FILE='$1/data/adb/modules/keylens/module.prop'"
    echo "TRICKY_MODULE='$1/data/adb/modules/tricky_store'"
    echo "TEESIM_MODULE='$1/data/adb/modules/none-teesim'"
    echo "OMK_MODULE='$1/data/adb/modules/none-omk'"
    echo "LOCK_TIMEOUT=2"
  } > "$T/doc.sh"
  sed -n '/^backend_keybox_path() {/,/^}/p' module/webui.sh >> "$T/doc.sh"
  sed -n '/^prop_now() {/,/^}/p' module/webui.sh >> "$T/doc.sh"
  sed -n '/^cmd_doctor() {/,/^}/p' module/webui.sh >> "$T/doc.sh"
  cat >> "$T/doc.sh" <<'EOF'
detect_backend "$MODDIR"
cmd_doctor
EOF
}
DOCR="$T/doc-root"
mk_doc_fixture() {
  mkdir -p "$1/data/adb/modules/tricky_store" "$1/data/adb/tricky_store"
  printf 'com.a\n' > "$1/data/adb/tricky_store/target.txt"
  printf '<AndroidAttestation><Keybox><Key algorithm="ec"><PrivateKey>p</PrivateKey><CertificateChain><Certificate>c</Certificate></CertificateChain></Key></Keybox></AndroidAttestation>\n' > "$1/data/adb/tricky_store/keybox.xml"
}
DOCS="$DOCR-s"; DOCRR="$DOCR-r"
mk_doc_fixture "$DOCS"; mk_doc_fixture "$DOCRR"
mk_doc_harness "$DOCS"
cat > "$T/bin/cmd" <<'EOF'
#!/bin/sh
printf 'package:com.a\npackage:com.b\n'
EOF
chk 'doctor：11 项逐行一致' "$(PATH="$T/bin:$PATH" sh "$T/doc.sh" 2>&1 | sed 's/doc-root-[sr]/doc-root/g')" "$(PATH="$T/bin:$PATH" KEYLENS_ROOT="$DOCRR" "$B" doctor 2>&1 | sed 's/doc-root-[sr]/doc-root/g')"

echo "── restore-app（名单 writer：tricky 追加）──"
mk_ra_harness() { # <root>
  {
    echo 'TAB=$(printf "\t")'
    echo 'CR=$(printf "\r")'
    echo 'NL=$(printf "\nX"); NL=${NL%X}'
    echo '. module/lib/core.sh'
    echo '. module/lib/tools.sh'
    echo '. module/lib/backend.sh'
    echo '. module/lib/applist.sh'
    echo '. module/lib/lock.sh'
    echo 'kv() { printf "%s=%s\n" "$1" "$2"; }'
    echo 'log_info() { :; }'
    echo "MODDIR='$PWD/module'"
    echo "KL_PATCH='$PWD/module/backends/tricky.awk'"
    echo "TSTORE_DIR='$1/data/adb/tricky_store'"
    echo "TEESIM_DIR='$1/data/adb/teesim'"
    echo "TEESIM_CONFIG='$1/data/adb/teesim/config.json'"
    echo "OMK_DIR='$1/data/misc/keystore/omk'"
    echo "OMK_INJECTOR='$1/data/misc/keystore/omk/injector.toml'"
    echo "OMK_STATE_DIR='$1/data/adb/omk'"
    echo "PROP_FILE='$1/data/adb/modules/keylens/module.prop'"
    echo "TRICKY_MODULE='$1/data/adb/modules/tricky_store'"
    echo "TEESIM_MODULE='$1/data/adb/modules/none-teesim'"
    echo "OMK_MODULE='$1/data/adb/modules/none-omk'"
    echo "LOCK_TIMEOUT=2"
  } > "$T/ra.sh"
  sed -n '/^webui_lock() {/,/^}/p' module/webui.sh >> "$T/ra.sh"
  sed -n '/^require_runnable() {/,/^}/p' module/webui.sh >> "$T/ra.sh"
  sed -n '/^cmd_restore_app() {/,/^}/p' module/lib/write.sh >> "$T/ra.sh"
  echo 'detect_backend "$MODDIR"; cmd_restore_app "$1"' >> "$T/ra.sh"
}
RA="$T/ra-root"
mk_ra_fixture() {
  mkdir -p "$1/data/adb/modules/tricky_store" "$1/data/adb/tricky_store" "$1/data/adb/modules/keylens"
  printf 'com.a\ncom.b?\n' > "$1/data/adb/tricky_store/target.txt"
  printf 'id=keylens\nversion=v3.0.1\ndescription=ok\n' > "$1/data/adb/modules/keylens/module.prop"
}
RAS="$RA-s"; RAR="$RA-r"
mk_ra_fixture "$RAS"; mk_ra_fixture "$RAR"
mk_ra_harness "$RAS"
chk 'restore-app：输出' "$(sh "$T/ra.sh" com.c 2>&1)" "$(KEYLENS_ROOT="$RAR" "$B" restore-app com.c 2>&1)"
chk 'restore-app：目标文件逐字节一致' "$(cat "$RAS/data/adb/tricky_store/target.txt")" "$(cat "$RAR/data/adb/tricky_store/target.txt")"
chk 'restore-app：ever 名单一致' "$(cat "$RAS/data/adb/tricky_store/.kl_ever" 2>/dev/null)" "$(cat "$RAR/data/adb/tricky_store/.kl_ever" 2>/dev/null)"
chk 'restore-app：已在名单（restored=0）' "$(sh "$T/ra.sh" 'com.a?' 2>&1)" "$(KEYLENS_ROOT="$RAR" "$B" restore-app 'com.a?' 2>&1)"
chk 'restore-app：非法条目' "$(sh "$T/ra.sh" 'bad..pkg' 2>&1)" "$(KEYLENS_ROOT="$RAR" "$B" restore-app 'bad..pkg' 2>&1)"

echo "── restore-apps（批量，一次落盘）──"
mk_ras_harness() { # <root>
  {
    echo 'TAB=$(printf "\t")'
    echo 'CR=$(printf "\r")'
    echo 'NL=$(printf "\nX"); NL=${NL%X}'
    echo '. module/lib/core.sh'
    echo '. module/lib/tools.sh'
    echo '. module/lib/backend.sh'
    echo '. module/lib/applist.sh'
    echo '. module/lib/lock.sh'
    echo 'kv() { printf "%s=%s\n" "$1" "$2"; }'
    echo 'log_info() { :; }'
    echo "MODDIR='$PWD/module'"
    echo "KL_PATCH='$PWD/module/backends/tricky.awk'"
    echo "TSTORE_DIR='$1/data/adb/tricky_store'"
    echo "TEESIM_DIR='$1/data/adb/teesim'"
    echo "TEESIM_CONFIG='$1/data/adb/teesim/config.json'"
    echo "OMK_DIR='$1/data/misc/keystore/omk'"
    echo "OMK_INJECTOR='$1/data/misc/keystore/omk/injector.toml'"
    echo "OMK_STATE_DIR='$1/data/adb/omk'"
    echo "PROP_FILE='$1/data/adb/modules/keylens/module.prop'"
    echo "TRICKY_MODULE='$1/data/adb/modules/tricky_store'"
    echo "TEESIM_MODULE='$1/data/adb/modules/none-teesim'"
    echo "OMK_MODULE='$1/data/adb/modules/none-omk'"
    echo "LOCK_TIMEOUT=2"
  } > "$T/ras.sh"
  sed -n '/^webui_lock() {/,/^}/p' module/webui.sh >> "$T/ras.sh"
  sed -n '/^require_runnable() {/,/^}/p' module/webui.sh >> "$T/ras.sh"
  sed -n '/^cmd_restore_apps() {/,/^}/p' module/lib/write.sh >> "$T/ras.sh"
  echo 'detect_backend "$MODDIR"; cmd_restore_apps "$1"' >> "$T/ras.sh"
}
RASS="$T/ras-root-s"; RASR="$T/ras-root-r"
mk_ras_fixture() {
  mkdir -p "$1/data/adb/modules/tricky_store" "$1/data/adb/tricky_store" "$1/data/adb/modules/keylens"
  printf 'com.a\n' > "$1/data/adb/tricky_store/target.txt"
  printf 'id=keylens\nversion=v3.0.1\ndescription=ok\n' > "$1/data/adb/modules/keylens/module.prop"
}
mk_ras_fixture "$RASS"; mk_ras_fixture "$RASR"
mk_ras_harness "$RASS"
chk 'restore-apps：批量输出' "$(sh "$T/ras.sh" 'com.b,com.c' 2>&1)" "$(KEYLENS_ROOT="$RASR" "$B" restore-apps 'com.b,com.c' 2>&1)"
chk 'restore-apps：目标文件逐字节一致' "$(cat "$RASS/data/adb/tricky_store/target.txt")" "$(cat "$RASR/data/adb/tricky_store/target.txt")"
chk 'restore-apps：全都已在名单（restored=0）' "$(sh "$T/ras.sh" 'com.a' 2>&1)" "$(KEYLENS_ROOT="$RASR" "$B" restore-apps 'com.a' 2>&1)"
chk 'restore-apps：参数为空' "$(sh "$T/ras.sh" '' 2>&1)" "$(KEYLENS_ROOT="$RASR" "$B" restore-apps '' 2>&1)"

echo "── remove-apps（批量移出 + 至少保留一条）──"
mk_rm_harness() { # <root>
  {
    echo 'TAB=$(printf "\t")'
    echo 'CR=$(printf "\r")'
    echo 'NL=$(printf "\nX"); NL=${NL%X}'
    echo '. module/lib/core.sh'
    echo '. module/lib/tools.sh'
    echo '. module/lib/backend.sh'
    echo '. module/lib/applist.sh'
    echo '. module/lib/lock.sh'
    echo 'kv() { printf "%s=%s\n" "$1" "$2"; }'
    echo 'log_info() { :; }'
    echo "MODDIR='$PWD/module'"
    echo "KL_PATCH='$PWD/module/backends/tricky.awk'"
    echo "TSTORE_DIR='$1/data/adb/tricky_store'"
    echo "TEESIM_DIR='$1/data/adb/teesim'"
    echo "TEESIM_CONFIG='$1/data/adb/teesim/config.json'"
    echo "OMK_DIR='$1/data/misc/keystore/omk'"
    echo "OMK_INJECTOR='$1/data/misc/keystore/omk/injector.toml'"
    echo "OMK_STATE_DIR='$1/data/adb/omk'"
    echo "PROP_FILE='$1/data/adb/modules/keylens/module.prop'"
    echo "TRICKY_MODULE='$1/data/adb/modules/tricky_store'"
    echo "TEESIM_MODULE='$1/data/adb/modules/none-teesim'"
    echo "OMK_MODULE='$1/data/adb/modules/none-omk'"
    echo "LOCK_TIMEOUT=2"
  } > "$T/rm.sh"
  sed -n '/^webui_lock() {/,/^}/p' module/webui.sh >> "$T/rm.sh"
  sed -n '/^require_runnable() {/,/^}/p' module/webui.sh >> "$T/rm.sh"
  sed -n '/^cmd_remove_apps() {/,/^}/p' module/lib/write.sh >> "$T/rm.sh"
  echo 'detect_backend "$MODDIR"; cmd_remove_apps "$1"' >> "$T/rm.sh"
}
RMS="$T/rm-root-s"; RMR="$T/rm-root-r"
mk_rm_fixture() {
  mkdir -p "$1/data/adb/modules/tricky_store" "$1/data/adb/tricky_store" "$1/data/adb/modules/keylens"
  printf '# 注释\ncom.a\ncom.b?\n\ncom.c\n' > "$1/data/adb/tricky_store/target.txt"
  printf 'id=keylens\nversion=v3.0.1\ndescription=ok\n' > "$1/data/adb/modules/keylens/module.prop"
}
mk_rm_fixture "$RMS"; mk_rm_fixture "$RMR"
mk_rm_harness "$RMS"
# shell 侧的 removed 计数曾用 `tr ',' '\n' | wc -l`（无尾换行 → 单项得 0、多项少 1），
# 已在 module/lib/write.sh 修成按逗号数 +1；两边现在应当逐字一致。
chk 'remove-apps：移出一条（输出，含 removed 计数）' "$(sh "$T/rm.sh" 'com.b' 2>&1)" "$(KEYLENS_ROOT="$RMR" "$B" remove-apps 'com.b' 2>&1)"
chk 'remove-apps：目标文件逐字节一致' "$(cat "$RMS/data/adb/tricky_store/target.txt")" "$(cat "$RMR/data/adb/tricky_store/target.txt")"
chk 'remove-apps：注释与空行保留' "$(sed -n '1p' "$RMR/data/adb/tricky_store/target.txt")" "# 注释"
chk 'remove-apps：不能移出全部' "$(sh "$T/rm.sh" 'com.a,com.c' 2>&1)" "$(KEYLENS_ROOT="$RMR" "$B" remove-apps 'com.a,com.c' 2>&1)"
# 这一条只比 stdout：shell 版在"本来就不在"分支会漏一句 stderr（wc: 文件不存在），
# 那是它的瑕疵，Rust 版不复制，所以两边 stderr 不做逐字节比较。
chk 'remove-apps：本来就不在（removed=0）' "$(sh "$T/rm.sh" 'com.zzz' 2>/dev/null)" "$(KEYLENS_ROOT="$RMR" "$B" remove-apps 'com.zzz' 2>/dev/null)"

echo "── teesim-save（嵌套 profiles.<name> 写入）──"
mk_ts_harness() { # <root>
  {
    echo 'TAB=$(printf "\t")'
    echo 'CR=$(printf "\r")'
    echo 'NL=$(printf "\nX"); NL=${NL%X}'
    echo '. module/lib/core.sh'
    echo '. module/lib/tools.sh'
    echo '. module/lib/backend.sh'
    echo '. module/lib/lock.sh'
    echo 'kv() { printf "%s=%s\n" "$1" "$2"; }'
    echo 'log_info() { :; }'
    echo 'lower() { printf "%s" "$1" | tr "A-Z" "a-z"; }'
    echo 'commit_backend_file() { [ -f "$1" ] && cp "$1" "$1.bak"; cp "$2" "$1"; }'
    echo "MODDIR='$PWD/module'"
    echo "KL_PATCH='$PWD/module/backends/teesim.awk'"
    echo "TSTORE_DIR='$1/data/adb/tricky_store'"
    echo "TEESIM_DIR='$1/data/adb/teesim'"
    echo "TEESIM_CONFIG='$1/data/adb/teesim/config.json'"
    echo "OMK_DIR='$1/data/misc/keystore/omk'"
    echo "OMK_INJECTOR='$1/data/misc/keystore/omk/injector.toml'"
    echo "OMK_STATE_DIR='$1/data/adb/omk'"
    echo "TRICKY_MODULE='$1/data/adb/modules/none-tricky'"
    echo "TEESIM_MODULE='$1/data/adb/modules/teesim'"
    echo "OMK_MODULE='$1/data/adb/modules/none-omk'"
    echo "LOCK_TIMEOUT=2"
  } > "$T/ts.sh"
  sed -n '/^webui_lock() {/,/^}/p' module/webui.sh >> "$T/ts.sh"
  sed -n '/^require_runnable() {/,/^}/p' module/webui.sh >> "$T/ts.sh"
  for fn in parse_payload valid_patch valid_os_version valid_bool valid_keybox_name valid_text; do
    sed -n "/^$fn() {/,/^}/p" module/webui.sh >> "$T/ts.sh"
  done
  sed -n '/^cmd_teesim_save() {/,/^}/p' module/lib/write.sh >> "$T/ts.sh"
  echo 'detect_backend "$MODDIR"; cmd_teesim_save "$1"' >> "$T/ts.sh"
}
TSS="$T/ts-root-s"; TSR="$T/ts-root-r"
mk_ts_fixture() {
  mkdir -p "$1/data/adb/modules/teesim" "$1/data/adb/teesim"
  printf '{\n    "profiles": {\n        "default": {\n            "mode": "patch",\n            "keybox": "keybox.xml",\n            "apps": ["com.a"]\n        }\n    }\n}\n' > "$1/data/adb/teesim/config.json"
  printf '<k/>\n' > "$1/data/adb/teesim/keybox.xml"
}
mk_ts_fixture "$TSS"; mk_ts_fixture "$TSR"
mk_ts_harness "$TSS"
PLTS=$(printf 'mode=%s\npatch_system=%s\nauto_include=%s' "$(printf 'generation' | base64 | tr -d '\n')" "$(printf '2026-10-01' | base64 | tr -d '\n')" "$(printf 'true' | base64 | tr -d '\n')" | base64 | tr -d '\n')
chk 'teesim-save：输出' "$(sh "$T/ts.sh" "$PLTS" 2>&1)" "$(KEYLENS_ROOT="$TSR" "$B" teesim-save "$PLTS" 2>&1)"
chk 'teesim-save：两侧 config 逐字节一致' "$(cat "$TSS/data/adb/teesim/config.json")" "$(cat "$TSR/data/adb/teesim/config.json")"
chk 'teesim-save：备份已生成' "$([ -f "$TSR/data/adb/teesim/config.json.bak" ] && echo yes)" "yes"
BADTS=$(printf 'patch_system=%s' "$(printf 'harvested' | base64 | tr -d '\n')" | base64 | tr -d '\n')
chk 'teesim-save：harvested 拒绝' "$(sh "$T/ts.sh" "$BADTS" 2>&1)" "$(KEYLENS_ROOT="$TSR" "$B" teesim-save "$BADTS" 2>&1)"

echo "── omk-save-injector（TOML 定值写入）──"
mk_oi_harness() { # <root>
  {
    echo 'TAB=$(printf "\t")'
    echo 'CR=$(printf "\r")'
    echo 'NL=$(printf "\nX"); NL=${NL%X}'
    echo '. module/lib/core.sh'
    echo '. module/lib/tools.sh'
    echo '. module/lib/backend.sh'
    echo '. module/lib/applist.sh'
    echo '. module/lib/lock.sh'
    echo 'kv() { printf "%s=%s\n" "$1" "$2"; }'
    echo 'log_info() { :; }'
    echo 'commit_backend_file() { [ -f "$1" ] && cp "$1" "$1.bak"; cp "$2" "$1"; }'
    echo "MODDIR='$PWD/module'"
    echo "KL_PATCH='$PWD/module/backends/omk.awk'"
    echo "TSTORE_DIR='$1/data/adb/tricky_store'"
    echo "TEESIM_DIR='$1/data/adb/teesim'"
    echo "TEESIM_CONFIG='$1/data/adb/teesim/config.json'"
    echo "OMK_DIR='$1/data/misc/keystore/omk'"
    echo "OMK_INJECTOR='$1/data/misc/keystore/omk/injector.toml'"
    echo "OMK_STATE_DIR='$1/data/adb/omk'"
    echo "TRICKY_MODULE='$1/data/adb/modules/none-tricky'"
    echo "TEESIM_MODULE='$1/data/adb/modules/none-teesim'"
    echo "OMK_MODULE='$1/data/adb/modules/oh_my_keymint'"
    echo "LOCK_TIMEOUT=2"
  } > "$T/oi.sh"
  sed -n '/^webui_lock() {/,/^}/p' module/webui.sh >> "$T/oi.sh"
  sed -n '/^require_runnable() {/,/^}/p' module/webui.sh >> "$T/oi.sh"
  for fn in parse_payload valid_bool valid_inj_log_level valid_deny_list; do
    sed -n "/^$fn() {/,/^}/p" module/webui.sh >> "$T/oi.sh"
  done
  sed -n '/^cmd_omk_save_injector() {/,/^}/p' module/lib/write.sh >> "$T/oi.sh"
  sed -n '/^omk_restart() {/,/^}/p' module/webui.sh >> "$T/oi.sh"
  echo 'detect_backend "$MODDIR"; cmd_omk_save_injector "$1"' >> "$T/oi.sh"
}
OIS="$T/oi-root-s"; OIR="$T/oi-root-r"
mk_oi_fixture() {
  mkdir -p "$1/data/adb/modules/oh_my_keymint" "$1/data/misc/keystore/omk" "$1/data/adb/omk"
  printf '[main]\nenabled = true\nlog_level = "info"\n\n[filter]\nenabled = true\ndeny_packages = ["com.x"]\n' > "$1/data/misc/keystore/omk/injector.toml"
}
mk_oi_fixture "$OIS"; mk_oi_fixture "$OIR"
mk_oi_harness "$OIS"
PLOI=$(printf 'inj_main_enabled=%s\nfilter_deny=%s\ninj_log_level=%s' \
  "$(printf 'false' | base64 | tr -d '\n')" \
  "$(printf 'com.a, com.b' | base64 | tr -d '\n')" \
  "$(printf 'debug' | base64 | tr -d '\n')" | base64 | tr -d '\n')
chk 'omk-save-injector：输出' "$(sh "$T/oi.sh" "$PLOI" 2>&1)" "$(KEYLENS_ROOT="$OIR" "$B" omk-save-injector "$PLOI" 2>&1)"
chk 'omk-save-injector：两侧 injector 逐字节一致' "$(cat "$OIS/data/misc/keystore/omk/injector.toml")" "$(cat "$OIR/data/misc/keystore/omk/injector.toml")"
chk 'omk-save-injector：备份已生成' "$([ -f "$OIR/data/adb/omk/injector.toml.bak" ] && echo yes)" "yes"

echo "── omk-save-config（复用同一 TOML 引擎 + apply_scope）──"
mk_oc_harness() { # <root>
  {
    echo 'TAB=$(printf "\t")'
    echo 'CR=$(printf "\r")'
    echo 'NL=$(printf "\nX"); NL=${NL%X}'
    echo '. module/lib/core.sh'
    echo '. module/lib/tools.sh'
    echo '. module/lib/backend.sh'
    echo '. module/lib/lock.sh'
    echo 'kv() { printf "%s=%s\n" "$1" "$2"; }'
    echo 'log_info() { :; }'
    echo 'commit_backend_file() { [ -f "$1" ] && cp "$1" "$1.bak"; cp "$2" "$1"; }'
    echo "MODDIR='$PWD/module'"
    echo "KL_PATCH='$PWD/module/backends/omk.awk'"
    echo "TSTORE_DIR='$1/data/adb/tricky_store'"
    echo "TEESIM_DIR='$1/data/adb/teesim'"
    echo "TEESIM_CONFIG='$1/data/adb/teesim/config.json'"
    echo "OMK_DIR='$1/data/misc/keystore/omk'"
    echo "OMK_INJECTOR='$1/data/misc/keystore/omk/injector.toml'"
    echo "OMK_STATE_DIR='$1/data/adb/omk'"
    echo "TRICKY_MODULE='$1/data/adb/modules/none-tricky'"
    echo "TEESIM_MODULE='$1/data/adb/modules/none-teesim'"
    echo "OMK_MODULE='$1/data/adb/modules/oh_my_keymint'"
    echo "LOCK_TIMEOUT=2"
  } > "$T/oc.sh"
  sed -n '/^webui_lock() {/,/^}/p' module/webui.sh >> "$T/oc.sh"
  sed -n '/^require_runnable() {/,/^}/p' module/webui.sh >> "$T/oc.sh"
  for fn in parse_payload valid_log_level valid_bool valid_omk_os_version valid_omk_patch valid_omk_boot valid_omk_hash valid_text valid_omk_date omk_apply_scope omk_reboot_needed; do
    sed -n "/^$fn() {/,/^}/p" module/webui.sh >> "$T/oc.sh"
  done
  sed -n '/^cmd_omk_save_config() {/,/^}/p' module/lib/write.sh >> "$T/oc.sh"
  sed -n '/^omk_restart() {/,/^}/p' module/webui.sh >> "$T/oc.sh"
  echo 'detect_backend "$MODDIR"; cmd_omk_save_config "$1"' >> "$T/oc.sh"
}
OCS="$T/oc-root-s"; OCR="$T/oc-root-r"
mk_oc_fixture() {
  mkdir -p "$1/data/adb/modules/oh_my_keymint" "$1/data/misc/keystore/omk" "$1/data/adb/omk"
  printf '[main]\nlog_level = "info"\n\n[trust]\nsecurity_patch = "2026-09-01"\nos_patchlevel = "auto"\nvb_key = "random"\nvb_hash = "random"\n' > "$1/data/misc/keystore/omk/config.toml"
}
mk_oc_fixture "$OCS"; mk_oc_fixture "$OCR"
mk_oc_harness "$OCS"
PLOC=$(printf 'trust_security_patch=%s\ntrust_os_patchlevel=%s' \
  "$(printf '2026-10-01' | base64 | tr -d '\n')" \
  "$(printf 'latest' | base64 | tr -d '\n')" | base64 | tr -d '\n')
chk 'omk-save-config：只动补丁字段（hot）' "$(sh "$T/oc.sh" "$PLOC" 2>&1)" "$(KEYLENS_ROOT="$OCR" "$B" omk-save-config "$PLOC" 2>&1)"
chk 'omk-save-config：两侧 config 逐字节一致' "$(cat "$OCS/data/misc/keystore/omk/config.toml")" "$(cat "$OCR/data/misc/keystore/omk/config.toml")"
PLOC2=$(printf 'trust_vb_key=%s' "$(printf 'auto' | base64 | tr -d '\n')" | base64 | tr -d '\n')
chk 'omk-save-config：vb_key random→auto（需要重启整机）' "$(sh "$T/oc.sh" "$PLOC2" 2>&1)" "$(KEYLENS_ROOT="$OCR" "$B" omk-save-config "$PLOC2" 2>&1)"

echo "── backend-info（三家摘要）──"
mk_bi_harness() { # <root>
  {
    echo 'TAB=$(printf "\t")'
    echo 'CR=$(printf "\r")'
    echo 'NL=$(printf "\nX"); NL=${NL%X}'
    echo '. module/lib/core.sh'
    echo '. module/lib/tools.sh'
    echo '. module/lib/backend.sh'
    echo '. module/lib/applist.sh'
    echo 'kv() { printf "%s=%s\n" "$1" "$2"; }'
    echo 'tsv() { local IFS="$(printf "\t")"; printf "%s\n" "$*"; }'
    echo 'log_info() { :; }'
    echo "MODDIR='$PWD/module'"
    echo "KL_PATCH='$PWD/module/backends/tricky.awk'"
    echo "TSTORE_DIR='$1/data/adb/tricky_store'"
    echo "TEESIM_DIR='$1/data/adb/teesim'"
    echo "TEESIM_CONFIG='$1/data/adb/teesim/config.json'"
    echo "OMK_DIR='$1/data/misc/keystore/omk'"
    echo "OMK_INJECTOR='$1/data/misc/keystore/omk/injector.toml'"
    echo "OMK_STATE_DIR='$1/data/adb/omk'"
    echo "TRICKY_MODULE='$1/data/adb/modules/tricky_store'"
    echo "TEESIM_MODULE='$1/data/adb/modules/teesim'"
    echo "OMK_MODULE='$1/data/adb/modules/oh_my_keymint'"
  } > "$T/bi.sh"
  sed -n '/^backend_name() {/,/^}/p' module/lib/backend.sh >> "$T/bi.sh"
  sed -n '/^cmd_backend_info() {/,/^}/p' module/webui.sh >> "$T/bi.sh"
  echo 'detect_backend "$MODDIR"; cmd_backend_info' >> "$T/bi.sh"
}
BIS="$T/bi-root-s"; BIR="$T/bi-root-r"
mk_bi_fixture() {
  mkdir -p "$1/data/adb/modules/tricky_store" "$1/data/adb/tricky_store"
  printf 'id=tricky_store\nversion=v1.9.9\n' > "$1/data/adb/modules/tricky_store/module.prop"
  printf 'com.a\ncom.b?\n' > "$1/data/adb/tricky_store/target.txt"
  printf '2026-10-05\nsystem=2026-10-01\n\n[com.a]\nvendor=2026-09-01\n' > "$1/data/adb/tricky_store/security_patch.txt"
  printf '<k/>\n' > "$1/data/adb/tricky_store/keybox.xml"
}
mk_bi_fixture "$BIS"; mk_bi_fixture "$BIR"
mk_bi_harness "$BIS"
chk 'backend-info（tricky）：逐行一致' "$(sh "$T/bi.sh" 2>&1 | sed -e 's/bi-root-[sr]/bi-root/g' -e 's/keybox_mtime=[0-9]*/keybox_mtime=X/')" "$(KEYLENS_ROOT="$BIR" "$B" backend-info 2>&1 | sed -e 's/bi-root-[sr]/bi-root/g' -e 's/keybox_mtime=[0-9]*/keybox_mtime=X/')"

echo "── env（探测 + 深浅色 + 强调色/种子）──"
ENV_ROOT="$T/env-root"
mkdir -p "$ENV_ROOT/data/adb/modules/keylens" "$ENV_ROOT/data/resource-cache" "$T/envbin"
printf 'id=keylens\nversion=v3.0.1\n' > "$ENV_ROOT/data/adb/modules/keylens/module.prop"
cat > "$T/envbin/getprop" <<'EOF'
#!/bin/sh
case "$1" in
  ro.product.model) echo XQ-DQ72 ;;
  ro.product.brand) echo Sony ;;
  ro.build.version.release) echo 15 ;;
  ro.build.version.sdk) echo 35 ;;
  ro.build.type) echo user ;;
  ro.boot.verifiedbootstate) echo green ;;
  ro.sf.lcd_density) echo 420 ;;
esac
EOF
cat > "$T/envbin/resetprop" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$T/envbin/id" <<'EOF'
#!/bin/sh
echo 0
EOF
cat > "$T/envbin/dumpsys" <<'EOF'
#!/bin/sh
case "$1" in
  uimode) echo 'mCurUiMode=0x21' ;;
  window) echo 'type=statusBars frame=[0,0][1080,66]' ;;
  wallpaper) echo 'colorValue0=-16777216' ;;
esac
EOF
cat > "$T/envbin/wm" <<'EOF'
#!/bin/sh
echo 'Physical density: 420'
EOF
cat > "$T/envbin/settings" <<'EOF'
#!/bin/sh
echo null
EOF
chmod +x "$T/envbin"/*
cat > "$T/env.sh" <<SH
TAB=\$(printf "\t")
NL=\$(printf "\nX"); NL=\${NL%X}
. module/lib/core.sh
. module/lib/tools.sh
. module/lib/backend.sh
kv() { printf "%s=%s\n" "\$1" "\$2"; }
MODDIR="$PWD/module"
PROP_FILE="$ENV_ROOT/data/adb/modules/keylens/module.prop"
KL_ENV_CACHE="$ENV_ROOT/data/adb/keylens.env.cache"
SH
sed -n '/^mod_prop() {/,/^}/p' module/webui.sh >> "$T/env.sh"
sed -n '/^prop_now() {/,/^}/p' module/webui.sh >> "$T/env.sh"
sed -n '/^cmd_env() {/,/^}/p' module/webui.sh >> "$T/env.sh"
echo 'cmd_env' >> "$T/env.sh"
chk 'env：逐行一致' "$(PATH="$T/envbin:$PATH" KEYLENS_MODDIR="$PWD/module" sh "$T/env.sh" 2>&1 | sed -e 's|/data/resource-cache/|/data/resource-cache/|')" "$(PATH="$T/envbin:$PATH" KEYLENS_MODDIR="$PWD/module" KEYLENS_ROOT="$ENV_ROOT" "$B" env 2>&1)"

echo "── sync（快照差分 + 写回 + 状态提交）──"
mk_sy_harness() { # <root>
  {
    echo 'TAB=$(printf "\t")'
    echo 'CR=$(printf "\r")'
    echo 'NL=$(printf "\nX"); NL=${NL%X}'
    echo '. module/lib/core.sh'
    echo '. module/lib/tools.sh'
    echo '. module/lib/backend.sh'
    echo '. module/lib/applist.sh'
    echo '. module/lib/lock.sh'
    echo '. module/backends/tricky.sh'
    echo 'kv() { printf "%s=%s\n" "$1" "$2"; }'
    echo 'log_info() { :; }'
    echo 'log_warn() { :; }'
    echo 'update_module_desc() { :; }'
    echo 'mark_module_failed() { :; }'
    echo "MODDIR='$PWD/module'"
    echo "KL_PATCH='$PWD/module/backends/tricky.awk'"
    echo "TSTORE_DIR='$1/data/adb/tricky_store'"
    echo "TEESIM_DIR='$1/data/adb/teesim'"
    echo "TEESIM_CONFIG='$1/data/adb/teesim/config.json'"
    echo "OMK_DIR='$1/data/misc/keystore/omk'"
    echo "OMK_INJECTOR='$1/data/misc/keystore/omk/injector.toml'"
    echo "OMK_STATE_DIR='$1/data/adb/omk'"
    echo "PROP_FILE='$1/data/adb/modules/keylens/module.prop'"
    echo "TRICKY_MODULE='$1/data/adb/modules/tricky_store'"
    echo "TEESIM_MODULE='$1/data/adb/modules/none-teesim'"
    echo "OMK_MODULE='$1/data/adb/modules/none-omk'"
    echo "LOCK_TIMEOUT=2"
  } > "$T/sy.sh"
  sed -n '/^webui_lock() {/,/^}/p' module/webui.sh >> "$T/sy.sh"
  sed -n '/^require_runnable() {/,/^}/p' module/webui.sh >> "$T/sy.sh"
  sed -n '/^cmd_sync() {/,/^}/p' module/lib/write.sh >> "$T/sy.sh"
  echo 'detect_backend "$MODDIR"; cmd_sync' >> "$T/sy.sh"
}
SYS="$T/sy-root-s"; SYR="$T/sy-root-r"
mk_sy_fixture() {
  mkdir -p "$1/data/adb/modules/tricky_store" "$1/data/adb/tricky_store" "$1/data/adb/modules/keylens"
  printf 'com.a\n' > "$1/data/adb/tricky_store/target.txt"
  printf 'com.a\n' > "$1/data/adb/tricky_store/.kl_installed_last"
  printf 'id=keylens\nversion=v3.0.1\ndescription=ok\n' > "$1/data/adb/modules/keylens/module.prop"
}
mk_sy_fixture "$SYS"; mk_sy_fixture "$SYR"
mk_sy_harness "$SYS"
mkdir -p "$T/sybin"
cat > "$T/sybin/cmd" <<'EOF'
#!/bin/sh
printf 'package:com.a\npackage:com.b\n'
EOF
chmod +x "$T/sybin/cmd"
chk 'sync：新装应用被加入（输出）' "$(PATH="$T/sybin:$PATH" sh "$T/sy.sh" 2>/dev/null | grep -E '^(rc|count)=')" "$(PATH="$T/sybin:$PATH" KEYLENS_ROOT="$SYR" "$B" sync 2>&1)"
chk 'sync：两侧目标文件逐字节一致' "$(cat "$SYS/data/adb/tricky_store/target.txt")" "$(cat "$SYR/data/adb/tricky_store/target.txt")"
chk 'sync：基线已提交' "$(cat "$SYR/data/adb/tricky_store/.kl_installed_last")" "$(cat "$SYS/data/adb/tricky_store/.kl_installed_last")"
chk 'sync：ever 已更新' "$(cat "$SYR/data/adb/tricky_store/.kl_ever" 2>/dev/null)" "$(cat "$SYS/data/adb/tricky_store/.kl_ever" 2>/dev/null)"

echo
# 下限保护：对拍只许增加、不许被悄悄删掉（新命令迁移时同步抬高这个数）
if [ "$oks" -lt 125 ]; then
  echo "  ✗   对拍数量低于下限（$oks < 125），疑似用例被删"; fail=1
fi
[ "$fail" = 0 ] && echo "全部通过（chk 用例 $oks 项）" || { echo "有断言失败"; exit 1; }
