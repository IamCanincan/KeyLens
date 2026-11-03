#!/bin/sh
# 契约/行为对拍：Rust 版与 shell 版逐字节一致才算过。
# 用法：rust/parity.sh [二进制路径]（默认 rust/target/release/keylens）
set -u
cd "$(dirname "$0")/.."
B=${1:-rust/target/release/keylens}
[ -x "$B" ] || { echo "缺少二进制：$B（先 cargo build --release）" >&2; exit 1; }
# 二进制比源码新才有资格当被测对象。本轮踩过一次：改完 main.rs 忘了重新 cargo build，
# 两条新断言当场红，看着像实现写错了，其实对拍在测上一版产物。这里直接拒绝。
_stale=$(find rust/src rust/Cargo.toml -newer "$B" 2>/dev/null | head -n 1)
if [ -n "$_stale" ]; then
    echo "二进制 $B 比源码旧（$_stale 在其之后改过）——先 cargo build --release 再对拍" >&2
    exit 1
fi
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
    echo "KL_PATCH='$PWD/tests/fixtures/backends/tricky.awk'"
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
    echo "KL_PATCH='$PWD/tests/fixtures/backends/tricky.awk'"
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

echo "── apps（cmd/pm 输出 → 去前缀/去[N]/排序去重；默认/system/all 三档）──"
mkdir -p "$T/bin"
cat > "$T/bin/cmd" <<'EOF'
#!/bin/sh
case "$*" in
  *query-activities*)
    # --components 的真实形状是「包名/组件」，没有 package: 前缀；同一个包可以多个入口
    printf 'com.a/.MainActivity\ncom.android.systemui/.recents.RecentsActivity\ncom.b/.StubActivity\ncom.a/.SecondActivity\n'
    exit 0 ;;
esac
# 带 -3 只给第三方；不带就是全量（后面三个是系统包）。桩要认参数，
# 否则 system 档会算出"全量减全量"= 空，两侧一起空照样绿。
third=""
for a in "$@"; do [ "$a" = "-3" ] && third=1; done
printf 'package:com.b\npackage:com.a\npackage:com.a\npackage:com.c[10]\npackage:com.d[2]\n'
[ -z "$third" ] && printf 'package:com.android.systemui\npackage:com.android.vending[11]\npackage:com.sonyericsson.elm\n'
exit 0
EOF
chmod +x "$T/bin/cmd"
{ sed -n '/^kl_pkg_names() {/,/^}/p' module/webui.sh; sed -n '/^kl_launchable_names() {/,/^}/p' module/webui.sh; \
  sed -n '/^cmd_apps() {/,/^}/p' module/webui.sh; printf 'AWK_CMD="awk"\n'; } > "$T/apps.sh"
apps_sh() { PATH="$T/bin:$PATH" sh -c '. "$1"; cmd_apps "$2"' sh "$T/apps.sh" "$1"; }
apps_rs() { PATH="$T/bin:$PATH" "$B" apps "$1"; }
APPS_THIRD=$(printf 'com.a\ncom.b\ncom.c\ncom.d')
APPS_ALL=$(printf 'com.a\ncom.android.systemui\ncom.android.vending\ncom.b\ncom.c\ncom.d\ncom.sonyericsson.elm')
APPS_SYSTEM=$(printf 'com.android.systemui\ncom.android.vending\ncom.sonyericsson.elm')
APPS_LAUNCH=$(printf 'com.a\ncom.android.systemui\ncom.b')
for arm in "" system all launchable; do
  case "$arm" in
    '')           want="$APPS_THIRD" ;;
    system)       want="$APPS_SYSTEM" ;;
    all)          want="$APPS_ALL" ;;
    launchable)   want="$APPS_LAUNCH" ;;
  esac
  label=${arm:-默认档}
  chk "apps：${label}（shell=期望）" "$want" "$(apps_sh "$arm")"
  chk "apps：${label}（Rust=期望）" "$want" "$(apps_rs "$arm")"
done

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
    echo "KL_PATCH='$PWD/tests/fixtures/backends/tricky.awk'"
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

# 正对照（§5.19 #4）：被移出的是**系统包**时「已排除」必须还看得见它。
# 旧口径 inst 取 `-3` ⇒ 系统包压根不在 inst 里 ⇒ 移出后这一档永远不出现、计数也不涨，
# 而名单页刚加的「系统应用」档让人正好会去移系统包。只比"两侧相等"抓不到（两侧一起看不见），
# 所以这两条钉的是**期望文本**，桩也必须认 -3（不认参数的话两侧都当全量，照样自证）。
EXSY="$T/exroot-sys"
mkdir -p "$EXSY/data/adb/modules/tricky_store" "$EXSY/data/adb/tricky_store"
printf 'com.a\n' > "$EXSY/data/adb/tricky_store/target.txt"
printf 'com.a\ncom.android.systemui\n' > "$EXSY/data/adb/tricky_store/.kl_ever"
cat > "$T/bin/cmd" <<'EOF'
#!/bin/sh
for a in "$@"; do [ "$a" = "-3" ] && third=1; done
if [ "${third:-}" = 1 ]; then printf 'package:com.a\n'
else printf 'package:com.a\npackage:com.android.systemui\n'; fi
EOF
chmod +x "$T/bin/cmd"
ex_harness "$EXSY"
chk 'excluded：移出的是系统包也要在（shell=期望）' 'com.android.systemui' "$(PATH="$T/bin:$PATH" sh "$T/h5.sh")"
chk 'excluded：移出的是系统包也要在（Rust=期望）' 'com.android.systemui' "$(PATH="$T/bin:$PATH" KEYLENS_ROOT="$EXSY" "$B" excluded)"
# 把这一段原来那份桩恢复回去：后面的台子按它写期望，留着这份会改到别人的读数
cat > "$T/bin/cmd" <<'EOF'
#!/bin/sh
printf 'package:com.a\npackage:com.b\npackage:com.c\npackage:com.d\npackage:com.e\n'
EOF
chmod +x "$T/bin/cmd"

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

echo "── props（18 固定 + 38 特征就地替换 = 56 行）──"
# 表驱动的桩：同一份值既服务单键查询（shell 参照走的）也服务全量 dump（Rust 的 props 页走的）。
# 值只有一个来源，否则两侧会各自漂；GETPROP_LOG 记每次调用，用来钉"到底起了几个进程"。
TBL_PROPS='ro.boot.vbmeta.device_state|locked
ro.boot.verifiedbootstate|green
ro.boot.flash.locked|1
ro.boot.veritymode|enforcing
ro.boot.warranty_bit|0
ro.warranty_bit|0
ro.debuggable|1
ro.force.debuggable|0
ro.secure|
ro.adb.secure|1
ro.build.type|user
ro.build.tags|release-keys
ro.vendor.boot.warranty_bit|0
ro.vendor.warranty_bit|0
vendor.boot.warranty_bit|0
ro.bootloader|engineering
ro.build.description|test-keys
ro.build.flavor|lineage_pdx234-userdebug
ro.system.build.type|userdebug
ro.vendor.build.type|userdebug
ro.product.build.type|userdebug
ro.system_ext.build.type|userdebug
ro.odm.build.type|userdebug
ro.bootimage.build.type|userdebug
ro.system.build.tags|test-keys
ro.build.fingerprint|Sony/XQ-DQ72/XQ-DQ72:17/CP2A.260605.016/a3e55c6845:userdebug/test-keys
ro.system.build.fingerprint|Sony/XQ-DQ72/XQ-DQ72:17/CP2A.260605.016/a3e55c6845:userdebug/release-keys
ro.vendor.build.fingerprint|Sony/XQ-DQ72/XQ-DQ72:15/67.2.A.3.178/067002A003017800521143226:user/release-keys'
# 注意：ro.system_dlkm.* 与 ro.vendor_dlkm.* 故意不给 —— 那两条规则必须报 absent
# （这台机没这个分区），既不能计入「写入并复核」的不符项，也不能凭空把属性写出来。
{
  printf '#!/bin/sh\nTBL=%s\n' "'$TBL_PROPS'"
  cat <<'EOF'
if [ -n "${GETPROP_LOG:-}" ]; then printf '%s\n' "${1:-<dump>}" >> "$GETPROP_LOG"; fi
if [ "${GETPROP_DEAD:-0}" = 1 ]; then exit 0; fi
# 值有两个来源：RP_DB（resetprop 桩写进去的那份）优先，其次固定表。
# 为什么：两侧现在都用同一次 getprop dump 做判定与复核，桩必须"写完读得回"，
# 否则复核读的是没被写过的固定表 —— 那这条台子就只是在比两份一样的东西。
val() {
    if [ -n "${RP_DB:-}" ] && [ -f "$RP_DB/$1" ]; then cat "$RP_DB/$1"; return 0; fi
    printf '%s\n' "$TBL" | while IFS='|' read -r k v; do
        [ "$k" = "$1" ] && printf '%s' "$v"
    done
    return 0
}
if [ $# -eq 0 ]; then
    printf '%s\n' "$TBL" | while IFS='|' read -r k _v; do
        [ -n "$k" ] || continue
        printf '[%s]: [%s]\n' "$k" "$(val "$k")"
    done
    if [ -n "${RP_DB:-}" ]; then
        for f in "$RP_DB"/*; do
            [ -f "$f" ] || continue
            k=${f##*/}
            printf '%s\n' "$TBL" | grep -qa "^$k|" && continue     # 表里已有，上面那份带权威值打过了
            printf '[%s]: [%s]\n' "$k" "$(cat "$f")"
        done
    fi
    exit 0
fi
val "$1"
exit 0
EOF
} > "$T/bin/getprop"
chmod +x "$T/bin/getprop"
cat > "$T/pr.sh" <<'EOF'
. module/lib/props.sh
tsv() { local IFS="$(printf '\t')"; printf '%s\n' "$*"; }
prop_now() { PROP_NOW=$(getprop "$1" 2>/dev/null); [ -n "$PROP_NOW" ] || PROP_NOW=""; }
EOF
sed -n '/^cmd_props() {/,/^}/p' module/webui.sh >> "$T/pr.sh"
echo 'cmd_props' >> "$T/pr.sh"
chk 'props：missing/diff/ok 与规则行' "$(PATH="$T/bin:$PATH" sh "$T/pr.sh")" "$(PATH="$T/bin:$PATH" "$B" props)"
# 输出相同不代表没白 fork：这条台子把"起了几个进程"也钉住。
# 两侧现在都读一次全量 dump（各 1 次）。以前 shell 参照是逐键取（17 次），
# 那是"第二份独立实现"的一部分；换成 dump 之后，独立性不再靠两条不同的读法，
# 改由 tests/props-snapshot.sh 守 —— 那里真源是"一键一个文件"的 db，dump 由 db
# 拼出来，被测的查表解析必须逐键等于 db，且期望表每一行都自动拿到含 ] 的样本。
rm -f "$T/gp.rust" "$T/gp.shell"
GETPROP_LOG="$T/gp.rust" PATH="$T/bin:$PATH" "$B" props >/dev/null 2>&1
GETPROP_LOG="$T/gp.shell" PATH="$T/bin:$PATH" sh "$T/pr.sh" >/dev/null 2>&1
chk 'props：Rust 侧只起一次 getprop（快照）' "1" "$(wc -l < "$T/gp.rust" | tr -d ' ')"
chk 'props：shell 侧同样只起一次（不再逐键 17 次）' "1" "$(wc -l < "$T/gp.shell" | tr -d ' ')"
chk 'props：shell 那一次是无参数 dump' "$(cat "$T/gp.shell")" "<dump>"
# absent（这台机压根没这个分区）必须存在且不为 0，否则"absent 不计入不符"那条是空转。
# 写成一条 chk 是为了让它也进 oks 计数（parity 里只有 chk 会数）。
_pab_tab=$(printf '\t')
_pa_shell=$(PATH="$T/bin:$PATH" sh "$T/pr.sh" | grep -ac "${_pab_tab}absent$")
_pa_rust=$(PATH="$T/bin:$PATH" "$B" props | grep -ac "${_pab_tab}absent$")
chk 'props：absent 行数两侧相同且 > 0（夹具故意不给 dlkm 分区）' \
    "$([ "$_pa_shell" -gt 0 ] && printf yes || printf no)/$_pa_shell/$_pa_rust" \
    "yes/$_pa_shell/$_pa_shell"

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
KL_PATCH="$PWD/tests/fixtures/backends/tricky.awk"
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
KL_PATCH="$PWD/tests/fixtures/backends/teesim.awk"
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
{"version":1,"profiles":{"work":{"keybox":"kb.xml","mode":"leaf","apps":["com.a","com.b"]},"default":{"apps":["com.x@10"]},"strong":{"limits":{"max_apps":{"mode":"decoy"},"n":1},"mode":"generate","apps":[]}}}
EOF
cat > "$T/tsp.sh" <<'EOF'
. module/lib/core.sh
. module/lib/tools.sh
. module/lib/backend.sh
MODDIR="$PWD/module"
KL_PATCH="$PWD/tests/fixtures/backends/teesim.awk"
TEESIM_DIR="$1"
TEESIM_CONFIG="$1/config.json"
TEESIM_MODULE="$1/../modules/teesim"
TRICKY_MODULE="$1/../modules/none-tricky"
EOF
sed -n '/^cmd_teesim_profiles() {/,/^}/p' module/webui.sh >> "$T/tsp.sh"
echo 'detect_backend "$MODDIR"; cmd_teesim_profiles' >> "$T/tsp.sh"
chk 'teesim-profiles：default 在前 + 其余顺序' "$(sh "$T/tsp.sh" "$TSP/data/adb/teesim")" "$(KEYLENS_ROOT="$TSP" "$B" teesim-profiles)"
# 绝对断言（不能只比"两侧相同"）：夹具里 profiles.strong.limits.max_apps 是个诱饵 ——
# 只要实现肯往下钻一层，"limits"/"max_apps" 就会被当成 profile 列出来，
# 而两侧一起错的话上面那条逐字节相同照样绿。参照 awk 靠"命中就把整块跳过去"停在顶层；
# 它那个 depth 计数器加了从来不读，Rust 侧原来照抄了同一个死计数器。
chk 'teesim-profiles：只列顶层三个 profile' \
    "$(KEYLENS_ROOT="$TSP" "$B" teesim-profiles | cut -f1 | tr '\n' ',' )" "default,work,strong,"
chk 'teesim-profiles：诱饵键没被当成 profile' \
    "$(KEYLENS_ROOT="$TSP" "$B" teesim-profiles | grep -c 'limits\|max_apps')" "0"

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
    echo "KL_PATCH='$PWD/tests/fixtures/backends/tricky.awk'"
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
  # 台子走**分派臂本身**（sed 抽出来跑），不在台子里重抄一遍拆分逻辑 —— 重抄就等于给分叉
  # 装消音器（这条正是被"台子按两个 argv 调"瞒了很久的：界面发的是一个参数）。
  # 抽不到时必须有响：落到 `*)` 退 9，否则两侧一起空跑照样绿。
  echo 'detect_backend "$MODDIR"' >> "$T/md.sh"
  echo 'main() { set -- set-mode "$1"; CMD="$1"; case "$CMD" in' >> "$T/md.sh"
  sed -n '/^    set-mode)$/,/^        ;;$/p' module/webui.sh >> "$T/md.sh"
  echo '  *) echo "set-mode 分派臂没抽到（改名/挪位了？）" >&2; return 9 ;;' >> "$T/md.sh"
  echo 'esac; }' >> "$T/md.sh"
  echo 'main "$@"' >> "$T/md.sh"
}
MD="$T/mdr"
mk_md_fixture() { # <dir>
  mkdir -p "$1/data/adb/modules/tricky_store" "$1/data/adb/tricky_store"
  printf 'com.a\ncom.b?\n# 注释\n  com.c   \n' > "$1/data/adb/tricky_store/target.txt"
}
MDS="$MD-s"; MDR="$MD-r"
mk_md_fixture "$MDS"; mk_md_fixture "$MDR"
mk_mode_harness "$MDS"
chk 'set-mode：改 auto→leaf（输出，界面那一发的形状）' "$(sh "$T/md.sh" 'com.a leaf' 2>&1)" "$(KEYLENS_ROOT="$MDR" "$B" set-mode 'com.a leaf' 2>&1)"
chk 'set-mode：两侧写回结果逐字节一致' "$(cat "$MDS/data/adb/tricky_store/target.txt")" "$(cat "$MDR/data/adb/tricky_store/target.txt")"
chk 'set-mode：注释/缩进/行尾空白保留' "$(sed -n '3,4p' "$MDR/data/adb/tricky_store/target.txt")" "# 注释
  com.c   "
chk 'set-mode：同模式再改（changed=0）' "$(sh "$T/md.sh" 'com.a leaf' 2>&1)" "$(KEYLENS_ROOT="$MDR" "$B" set-mode 'com.a leaf' 2>&1)"
chk 'set-mode：不存在的包（changed=0）' "$(sh "$T/md.sh" 'com.zzz auto' 2>&1)" "$(KEYLENS_ROOT="$MDR" "$B" set-mode 'com.zzz auto' 2>&1)"
chk 'set-mode：非法包名' "$(sh "$T/md.sh" 'bad..pkg auto' 2>&1)" "$(KEYLENS_ROOT="$MDR" "$B" set-mode 'bad..pkg auto' 2>&1)"
chk 'set-mode：只给包名（=自动，两侧同形）' "$(sh "$T/md.sh" 'com.a' 2>&1)" "$(KEYLENS_ROOT="$MDR" "$B" set-mode 'com.a' 2>&1)"

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
if [ "$1" = "-n" ]; then
    [ -n "${RP_LOG:-}" ] && printf '%s\n' "$2" >> "$RP_LOG"
    mkdir -p "$db"; printf '%s' "$3" > "$db/$2"; exit 0
fi
# RP_READ_DEAD=1：写仍落库，但**读**答空 —— 真机上 resetprop 不在 PATH 时就是这个形状。
# 这条控制存在的理由：current= 曾经两侧都用 resetprop 读，属性其实有值却报成空。
[ "${RP_READ_DEAD:-0}" = 1 ] && exit 0
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
KL_BOOT_HASH="$1"
EOF
# prop_now 从 webui.sh 抽那一份，不在这里手抄：手抄过 resetprop 的那版，
# 于是生产用 getprop、台子用 resetprop，读数口径分叉时两侧"照样一致"。
sed -n '/^prop_now() {/,/^}/p' module/webui.sh >> "$T/pb.sh"
sed -n '/^require_runnable() {/,/^}/p' module/webui.sh >> "$T/pb.sh"
sed -n '/^cmd_set_boot_hash() {/,/^}/p' module/lib/write.sh >> "$T/pb.sh"
echo 'cmd_set_boot_hash "$2"' >> "$T/pb.sh"
H64B=1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef
chk 'props-boot-hash：设置并应用' "$(PATH="$T/bin:$PATH" RP_DB="$T/rpdb" sh "$T/pb.sh" "$BH/data/adb/keylens.boot_hash" "$H64B" 2>&1)" "$(PATH="$T/bin:$PATH" RP_DB="$T/rpdb" KEYLENS_ROOT="$BH" "$B" props-boot-hash "$H64B" 2>&1)"
chk 'props-boot-hash：文件存在且 600' "$(stat -c '%a' "$BH/data/adb/keylens.boot_hash")" "600"
chk 'props-boot-hash：非法哈希' "$(PATH="$T/bin:$PATH" RP_DB="$T/rpdb" sh "$T/pb.sh" "$BH/data/adb/keylens.boot_hash" zzzz 2>&1)" "$(PATH="$T/bin:$PATH" RP_DB="$T/rpdb" KEYLENS_ROOT="$BH" "$B" props-boot-hash zzzz 2>&1)"
chk 'props-boot-hash：清除' "$(PATH="$T/bin:$PATH" RP_DB="$T/rpdb" sh "$T/pb.sh" "$BH/data/adb/keylens.boot_hash" - 2>&1)" "$(PATH="$T/bin:$PATH" RP_DB="$T/rpdb" KEYLENS_ROOT="$BH" "$B" props-boot-hash - 2>&1)"
chk 'props-boot-hash：清除后文件消失' "$([ -e "$BH/data/adb/keylens.boot_hash" ] && echo exists || echo gone)" "gone"

# 读数口径的正对照：resetprop 读不回时（真机上不在 PATH 就是这个形状），current= 仍要
# 报属性的真值。这一条在"两侧都用 resetprop 读"的那版上是恒空的 —— 那版只会把一起报空
# 当成一致，所以除了两侧相同，还必须钉一个绝对判据。
rm -rf "$T/rpdb"; mkdir -p "$T/rpdb"
PATH="$T/bin:$PATH" RP_DB="$T/rpdb" KEYLENS_ROOT="$BH" "$B" props-boot-hash "$H64B" >/dev/null 2>&1
rd_shell=$(PATH="$T/bin:$PATH" RP_READ_DEAD=1 RP_DB="$T/rpdb" sh "$T/pb.sh" "$BH/data/adb/keylens.boot_hash" "$H64B" 2>&1)
rd_rust=$(PATH="$T/bin:$PATH" RP_READ_DEAD=1 RP_DB="$T/rpdb" KEYLENS_ROOT="$BH" "$B" props-boot-hash "$H64B" 2>&1)
chk '读数口径：resetprop 读不回时两侧仍逐字节相同' "$rd_shell" "$rd_rust"
chk '读数口径：那种情况下 current= 报真值而不是空（正对照）' \
    "$(printf '%s\n' "$rd_rust" | sed -n 's/^current=//p')" "$H64B"
chk '读数口径：那种情况下如实报 applied=0' \
    "$(printf '%s\n' "$rd_rust" | sed -n 's/^applied=//p')" "0"

# ── 自动档（默认）：从当前后端自己的配置派生 digest ────────────────────────
# 三态：文件不在=auto / 文件里是 hex=manual / 文件里是 off=不写。
# 这一节钉的是"新用户一个字都不用填也能对齐"，以及**取不到就一个字节都不写**：
# OMK 允许 vb_hash="random"（每次 keymint 启动重新生成），那种情况下镜像过来的值
# 下一开机就过期，而过期值与空值在检测器里同为 Danger —— 所以 random 必须熄火。
# 两侧读同一份夹具：shell 侧把 OMK_DIR/TEESIM_DIR 指到根下，Rust 侧靠 KEYLENS_ROOT。
echo "── boot-hash 自动档（派生 / random 熄火 / 手动优先 / 不缓存）──"
BA="$T/ba-root"
H64BA="$T/h64a"
H64BC="$T/h64c"
# 常量用 printf 现造，不手数（这一版一开始把 'aaaa…1234' 当成 64 位，实际 66 位，
# 于是两侧都正确地拒了，断言反倒像"实现不一致"）
printf 'a%.0s' $(seq 1 64) > "$H64BA"
printf 'c%.0s' $(seq 1 64) > "$H64BC"
H64A=$(cat "$H64BA")
H64C=$(cat "$H64BC")
[ "${#H64A}" = 64 ] && [ "${#H64C}" = 64 ] || { echo "  ✗   夹具常量不是 64 位（${#H64A}/${#H64C}），这条台子不算证据"; fail=1; }
rm -rf "$BA"; mkdir -p "$BA/data/adb" "$BA/data/adb/modules/oh_my_keymint" \
    "$BA/data/misc/keystore/omk" "$BA/data/adb/teesim"
cat > "$T/pba.sh" <<'EOF'
. module/lib/core.sh
. module/lib/backend.sh
. module/lib/props.sh
kv() { printf '%s=%s\n' "$1" "$2"; }
log_info() { :; }
log_warn() { :; }
ROOT="$1"; ACT="$2"; ARG="$3"
KL_BOOT_HASH="$ROOT/data/adb/keylens.boot_hash"
OMK_MODULE="$ROOT/data/adb/modules/oh_my_keymint"
TEESIM_MODULE="$ROOT/data/adb/modules/teesim"
TRICKY_MODULE="$ROOT/data/adb/modules/tricky_store"
OMK_DIR="$ROOT/data/misc/keystore/omk"
TEESIM_DIR="$ROOT/data/adb/teesim"
EOF
# 同 pb.sh：prop_now 用生产那一份（getprop），不手抄
sed -n '/^prop_now() {/,/^}/p' module/webui.sh >> "$T/pba.sh"
sed -n '/^require_runnable() {/,/^}/p' module/webui.sh >> "$T/pba.sh"
sed -n '/^cmd_boot_hash() {/,/^}/p' module/webui.sh >> "$T/pba.sh"
sed -n '/^cmd_set_boot_hash() {/,/^}/p' module/lib/write.sh >> "$T/pba.sh"
echo 'case "$ACT" in show) cmd_boot_hash ;; set) cmd_set_boot_hash "$ARG" ;; esac' >> "$T/pba.sh"

ba_shell() { PATH="$T/bin:$PATH" RP_DB="$1" sh "$T/pba.sh" "$2" "$3" "${4:-}" 2>&1; }
ba_rust()  { PATH="$T/bin:$PATH" RP_DB="$1" KEYLENS_ROOT="$2" "$B" "$3" ${4:+"$4"} 2>&1; }

# 1) OMK 配置里是合法 hex ⇒ auto 直接派生，两侧逐字节
printf '[trust]\nvb_hash = "%s"\n' "$H64A" > "$BA/data/misc/keystore/omk/config.toml"
chk 'auto：OMK 的 vb_hash 是 hex → 两侧 boot-hash 逐字节相同' \
    "$(ba_shell "$T/rpdb" "$BA" show)" "$(ba_rust "$T/rpdb" "$BA" boot-hash)"
chk 'auto：派生出的值就是后端配置里那串（绝对判据）' \
    "$(ba_shell "$T/rpdb" "$BA" show | sed -n 's/^effective=//p')" "$H64A"
chk 'auto：来源标成 omk' \
    "$(ba_shell "$T/rpdb" "$BA" show | sed -n 's/^source=//p')" "omk"
chk 'auto：模式标成 auto 且没写过文件' \
    "$([ -e "$BA/data/adb/keylens.boot_hash" ] && echo exists || echo gone)/$(ba_shell "$T/rpdb" "$BA" show | sed -n 's/^mode=//p')" "gone/auto"
# 正对照：auto 档下按「立即应用」真的会把 digest 写下去（不是只算出来好看）
rm -rf "$T/rpdb"; mkdir -p "$T/rpdb"
chk 'auto：props-boot-hash auto 两侧输出相同' \
    "$(ba_shell "$T/rpdb" "$BA" set auto)" "$(ba_rust "$T/rpdb" "$BA" props-boot-hash auto)"
chk 'auto：digest 真被写成派生值（正对照）' \
    "$(cat "$T/rpdb/ro.boot.vbmeta.digest")" "$H64A"
chk 'auto：hash_alg 按长度补成 sha256' "$(cat "$T/rpdb/ro.boot.vbmeta.hash_alg")" "sha256"

# 2) random ⇒ 一个字节都不写（过期值比空着更糟）
printf '[trust]\nvb_hash = "random"\n' > "$BA/data/misc/keystore/omk/config.toml"
rm -rf "$T/rpdb"; mkdir -p "$T/rpdb"
chk 'random：两侧 boot-hash 逐字节相同' \
    "$(ba_shell "$T/rpdb" "$BA" show)" "$(ba_rust "$T/rpdb" "$BA" boot-hash)"
chk 'random：effective 必须是空（不写）' \
    "$(ba_shell "$T/rpdb" "$BA" show | sed -n 's/^effective=//p')" ""
chk 'random：status 报 unset，不报 mismatch' \
    "$(ba_shell "$T/rpdb" "$BA" show | sed -n 's/^status=//p')" "unset"
chk 'random：props-boot-hash auto 之后 digest 仍是空的（正对照：不许写随机串）' \
    "$(ba_shell "$T/rpdb" "$BA" set auto >/dev/null; ls "$T/rpdb" | grep -ac 'vbmeta.digest')" "0"

# 3) 后端配置变了 ⇒ 下次读就跟着变（绝不缓存）
printf '[trust]\nvb_hash = "%s"\n' "$H64C" > "$BA/data/misc/keystore/omk/config.toml"
chk '不缓存：改了后端配置，effective 立刻跟着变' \
    "$(ba_shell "$T/rpdb" "$BA" show | sed -n 's/^effective=//p')" "$H64C"

# 4) 手动优先于自动
printf '[trust]\nvb_hash = "%s"\n' "$H64A" > "$BA/data/misc/keystore/omk/config.toml"
rm -rf "$T/rpdb"; mkdir -p "$T/rpdb"
printf '%s\n' "$H64C" > "$BA/data/adb/keylens.boot_hash"
chk '手动优先：effective 用文件里的值而不是后端配置' \
    "$(ba_shell "$T/rpdb" "$BA" show | sed -n 's/^effective=//p')" "$H64C"
chk '手动优先：模式=manual、两侧逐字节相同' \
    "$(ba_shell "$T/rpdb" "$BA" show)" "$(ba_rust "$T/rpdb" "$BA" boot-hash)"

# 5) off = 明确不写（旧版「清除」的语义现在搬到这里）
rm -rf "$T/rpdb"; mkdir -p "$T/rpdb"
chk 'off：两侧 props-boot-hash off 输出相同' \
    "$(ba_shell "$T/rpdb" "$BA" set off)" "$(ba_rust "$T/rpdb" "$BA" props-boot-hash off)"
chk 'off：文件里是哨兵 off，模式也是 off' \
    "$(tr -d '[:space:]' < "$BA/data/adb/keylens.boot_hash")/$(ba_shell "$T/rpdb" "$BA" show | sed -n 's/^mode=//p')" "off/off"
chk 'off：digest 一个字节都没写（正对照）' "$(ls "$T/rpdb" | grep -ac 'vbmeta')" "0"
chk 'off：status=off（界面据此说"不写 digest"）' \
    "$(ba_shell "$T/rpdb" "$BA" show | sed -n 's/^status=//p')" "off"
# 从 off 回到 auto：删文件即可
rm -f "$BA/data/adb/keylens.boot_hash"
chk 'off→auto：删掉哨兵就回到自动档' \
    "$(ba_shell "$T/rpdb" "$BA" show | sed -n 's/^mode=//p')/$(ba_shell "$T/rpdb" "$BA" show | sed -n 's/^effective=//p')" "auto/$H64A"

# 6) TEESim 那一家：**属性已有值时必须采用它**，属性为空才按 overrides.json 补。
#    理由在上游：守护进程每次 push 都把 ro.boot.vbmeta.digest 强制成它自己证明的值
#    （App.kt:516-523），而 overrides.json 那条 hex 只在它当前是合成兜底值时才被采纳
#    （Harvester.kt:183-189、applyUserOverrides:399-415 对非 editable 直接 continue）。
#    拿 override 去覆盖一个已有值，正好会在上游不采纳时造出"证明与 prop 不符"那一格 Danger。
rm -rf "$BA/data/adb/modules/oh_my_keymint"
printf '{"verifiedBootKey":"aa","verifiedBootHash":"%s"}\n' "$H64C" > "$BA/data/adb/teesim/overrides.json"
mkdir -p "$BA/data/adb/modules/teesim"
rm -f "$T/rpdb/ro.boot.vbmeta.digest"          # 属性为空 = 老版本 TEESim（没有 #228 那条强制）
chk 'auto(teesim)：两侧 boot-hash 逐字节相同' \
    "$(ba_shell "$T/rpdb" "$BA" show)" "$(ba_rust "$T/rpdb" "$BA" boot-hash)"
chk 'auto(teesim)：属性为空时来源与值都取自 overrides.json' \
    "$(ba_shell "$T/rpdb" "$BA" show | sed -n 's/^source=//p')/$(ba_shell "$T/rpdb" "$BA" show | sed -n 's/^effective=//p')" "teesim/$H64C"
# 先证"计数器会数"：属性为空这一支两侧都必须各写 digest 一次，否则下面那条 0/0 是瞎的
rm -rf "$T/rpboh1"; mkdir -p "$T/rpboh1"; : > "$T/rpboh1/log"; : > "$T/rpboh1/log2"
PATH="$T/bin:$PATH" RP_LOG="$T/rpboh1/log" RP_DB="$T/rpdb" sh "$T/pba.sh" "$BA" set auto >/dev/null 2>&1
c_shell=$(grep -ac 'ro.boot.vbmeta.digest' "$T/rpboh1/log")
rm -f "$T/rpdb/ro.boot.vbmeta.digest"      # 上一臂把它写上了 ⇒ 清空，两臂才真的同源
PATH="$T/bin:$PATH" RP_LOG="$T/rpboh1/log2" RP_DB="$T/rpdb" KEYLENS_ROOT="$BA" "$B" props-boot-hash auto >/dev/null 2>&1
c_rust=$(grep -ac 'ro.boot.vbmeta.digest' "$T/rpboh1/log2")
chk 'auto(teesim)：属性为空时两侧各写 digest 一次（计数器自证）' "$c_shell/$c_rust" "1/1"
printf '%s' "$H64A" > "$T/rpdb/ro.boot.vbmeta.digest"   # 守护进程已经把它写成 H64A
chk 'auto(teesim)：属性已有值那一支两侧逐字节相同' \
    "$(ba_shell "$T/rpdb" "$BA" show)" "$(ba_rust "$T/rpdb" "$BA" boot-hash)"
chk 'auto(teesim)：已有值就采用它，不拿 override 覆盖（正对照：防覆盖守护进程）' \
    "$(ba_shell "$T/rpdb" "$BA" show | sed -n 's/^source=//p')/$(ba_shell "$T/rpdb" "$BA" show | sed -n 's/^effective=//p')" "daemon/$H64A"
rm -rf "$T/rpboh2"; mkdir -p "$T/rpboh2"
: > "$T/rpboh2/log"; : > "$T/rpboh2/log2"      # 先把两份日志放空：一边一次都没写时文件根本不会被创建，
                                            # 那时 grep 报"没有这个文件"会被读成"写了一次"
PATH="$T/bin:$PATH" RP_LOG="$T/rpboh2/log" RP_DB="$T/rpdb" sh "$T/pba.sh" "$BA" set auto >/dev/null 2>&1
PATH="$T/bin:$PATH" RP_LOG="$T/rpboh2/log2" RP_DB="$T/rpdb" KEYLENS_ROOT="$BA" "$B" props-boot-hash auto >/dev/null 2>&1
chk 'auto(teesim)：这一支一次都没写 digest（两侧按属性名点名，hash_alg 不算）' \
    "$(grep -ac 'ro.boot.vbmeta.digest' "$T/rpboh2/log")/$(grep -ac 'ro.boot.vbmeta.digest' "$T/rpboh2/log2")" "0/0"
chk 'auto(teesim)：跑完 digest 仍是守护进程那串（没被 override 换掉）' \
    "$(cat "$T/rpdb/ro.boot.vbmeta.digest")" "$H64A"
rm -f "$T/rpdb/ro.boot.vbmeta.digest"          # 回到"属性为空"再测 override 自己的形状
printf '{"verifiedBootKey":"aa","verifiedBootHash":null}\n' > "$BA/data/adb/teesim/overrides.json"
chk 'auto(teesim)：null 不算值（JSON 里没引号那条模式自然匹配不上）' \
    "$(ba_shell "$T/rpdb" "$BA" show | sed -n 's/^effective=//p')" ""
# 7) 三家都没启用 ⇒ 不派生（不镜像卸载后残留的配置）
rm -rf "$BA/data/adb/modules/teesim"
chk '无后端：不派生任何值（卸载残留的配置不算）' \
    "$(ba_shell "$T/rpdb" "$BA" show | sed -n 's/^source=//p')/$(ba_shell "$T/rpdb" "$BA" show | sed -n 's/^effective=//p')" "none/"

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
# 回落用的单键读必须和生产同一条工具（getprop），不能拿 resetprop 桩糊：
# 以前这里写成 resetprop，getprop 全废那条降级就变成"shell 读得到、Rust 读不到"，
# 两侧报出来的 mismatch 差 16 项 —— 差异是桩造的，不是实现造的。
# 复核仍然是"读得回刚写的值"：上面的 getprop 桩认 RP_DB（写完读得回）。
prop_now() { PROP_NOW=$(getprop "$1" 2>/dev/null); [ -n "$PROP_NOW" ] || PROP_NOW=""; }
props_readback() { props; }
KL_PROPS_OFF="$1"
KL_BOOT_HASH="$2"
EOF
sed -n '/^require_runnable() {/,/^}/p' module/webui.sh >> "$T/pa.sh"
sed -n '/^cmd_props() {/,/^}/p' module/webui.sh >> "$T/pa.sh"
sed -n '/^cmd_props_apply() {/,/^}/p' module/lib/write.sh >> "$T/pa.sh"
echo 'props_readback() { cmd_props; }' >> "$T/pa.sh"
echo 'cmd_props_apply' >> "$T/pa.sh"
# 期望表里故意留几项错的；dlkm 两个分区故意不给（absent 那条路必须走）
cat > "$T/bin/resetprop" <<'EOF'
#!/bin/sh
db="${RP_DB:?}"
if [ "$1" = "-n" ]; then
    [ -n "${RP_LOG:-}" ] && printf '%s\n' "$2" >> "$RP_LOG"
    mkdir -p "$db"; printf '%s' "$3" > "$db/$2"; exit 0
fi
if [ "$1" = "--version" ]; then echo fake; exit 0; fi
[ -f "$db/$1" ] && { cat "$db/$1"; exit 0; }
# 读不到自己那份就转给 getprop 桩：真机上这两个工具读的是同一个属性区，
# 桩各拿一份来源就会让"两侧决策不同"变成桩造的假差异（本条之前就是这么红的）。
getprop "$1"
EOF
chmod +x "$T/bin/resetprop"
mkdir -p "$T/rpdb2"
printf '0' > "$T/rpdb2/ro.debuggable"
printf 'user' > "$T/rpdb2/ro.build.type"
printf 'engineering-x' > "$T/rpdb2/ro.bootloader"
chk 'props-apply：写一次后复核（输出）' "$(PATH="$T/bin:$PATH" RP_DB="$T/rpdb2" sh "$T/pa.sh" "$PA/data/adb/keylens.props_off" "$PA/data/adb/keylens.boot_hash" 2>&1)" "$(PATH="$T/bin:$PATH" RP_DB="$T/rpdb2" KEYLENS_ROOT="$PA" "$B" props-apply 2>&1)"
# 就地替换：值里命中的那一段换掉，其余原样留着（以前的整值替换会把 engineering-x 压成 release）
chk 'props-apply：写入后的值（就地替换）' "$(cat "$T/rpdb2/ro.debuggable")/$(cat "$T/rpdb2/ro.bootloader")" "0/release-x"

# ── 状态 A/B：两侧各拿一份全新的属性区跑完，逐字节比"跑完之后长什么样" ──
# 输出相同只证明说话一样，属性区相同才证明动手一样：少写、多写、把 absent
# 的分区凭空写出来，都只在这条上现形。
rm -rf "$T/rpdb4" "$T/rpdb5" "$T/rpw4" "$T/rpw5"; mkdir -p "$T/rpdb4" "$T/rpdb5"
for d in "$T/rpdb4" "$T/rpdb5"; do
    printf '0' > "$d/ro.debuggable"
    printf 'user' > "$d/ro.build.type"
    printf 'engineering-x' > "$d/ro.bootloader"
done
PATH="$T/bin:$PATH" RP_LOG="$T/rpw4" RP_DB="$T/rpdb4" sh "$T/pa.sh" "$PA/data/adb/keylens.props_off" "$PA/data/adb/keylens.boot_hash" >/dev/null 2>&1
PATH="$T/bin:$PATH" RP_LOG="$T/rpw5" RP_DB="$T/rpdb5" KEYLENS_ROOT="$PA" "$B" props-apply >/dev/null 2>&1
store_of() { ( cd "$1" && for f in *; do printf '%s=[%s]\n' "$f" "$(cat "$f")"; done ); }
chk 'props-apply：两侧写完的属性区逐字节相同' "$(store_of "$T/rpdb4")" "$(store_of "$T/rpdb5")"
chk 'props-apply：链式改只落一次盘（ro.build.fingerprint 两条规则合成一次写）' \
    "$(grep -ac '^ro.build.fingerprint$' "$T/rpw4")/$(grep -ac '^ro.build.fingerprint$' "$T/rpw5")" "1/1"
chk 'props-apply：链式改的最终值两处特征都没了（绝对判据，不是互读）' \
    "$(cat "$T/rpdb4/ro.build.fingerprint")/$(cat "$T/rpdb5/ro.build.fingerprint")" \
    "Sony/XQ-DQ72/XQ-DQ72:17/CP2A.260605.016/a3e55c6845:user/release-keys/Sony/XQ-DQ72/XQ-DQ72:17/CP2A.260605.016/a3e55c6845:user/release-keys"
chk 'props-apply：absent 的分区没被凭空创建（dlkm 一个都不许出现）' \
    "$(ls "$T/rpdb4" "$T/rpdb5" | grep -ac dlkm)/$(ls "$T/rpdb4" "$T/rpdb5" | grep -ac dlkm)" "0/0"
chk 'props-apply：分区 type 真的被改写（正对照）' \
    "$(cat "$T/rpdb4/ro.system.build.type")/$(cat "$T/rpdb5/ro.system.build.type")" "user/user"
# 再点一次：一切都已到位，absent 的那批分区不许被算成不符
chk 'props-apply：跑完再点一次 = applied 1 / mismatch 0（absent 不扣分）' \
    "$(PATH="$T/bin:$PATH" RP_DB="$T/rpdb4" sh "$T/pa.sh" "$PA/data/adb/keylens.props_off" "$PA/data/adb/keylens.boot_hash" 2>&1 | tr '\n' '|')" \
    "applied=1|mismatch=0|"
mkdir -p "$PA/data/adb"; : > "$PA/data/adb/keylens.props_off"
chk 'props-apply：开关关闭时拒绝' "$(PATH="$T/bin:$PATH" RP_DB="$T/rpdb2" sh "$T/pa.sh" "$PA/data/adb/keylens.props_off" "$PA/data/adb/keylens.boot_hash" 2>&1)" "$(PATH="$T/bin:$PATH" RP_DB="$T/rpdb2" KEYLENS_ROOT="$PA" "$B" props-apply 2>&1)"
rm -f "$PA/data/adb/keylens.props_off"

# getprop 整个废掉（dump 空 → 判定逐键回落 resetprop，复核读不到任何东西）。
# 这条要钉的是"不许一边靠另一边的工具装绿"：两侧都必须照实报满屏读不到，
# 而写入本身仍要发生（回落还在用 resetprop）。
echo "── props-apply：getprop 全废的降级 ──"
rm -rf "$T/rpdb3"; mkdir -p "$T/rpdb3"
printf '1' > "$T/rpdb3/ro.debuggable"
printf 'user' > "$T/rpdb3/ro.build.type"
printf 'engineering-x' > "$T/rpdb3/ro.bootloader"
chk '降级：输出逐字节一致' \
    "$(PATH="$T/bin:$PATH" GETPROP_DEAD=1 RP_DB="$T/rpdb3" sh "$T/pa.sh" "$PA/data/adb/keylens.props_off" "$PA/data/adb/keylens.boot_hash" 2>&1)" \
    "$(PATH="$T/bin:$PATH" GETPROP_DEAD=1 RP_DB="$T/rpdb3" KEYLENS_ROOT="$PA" "$B" props-apply 2>&1)"
chk '降级：复核读不到 → mismatch 必须非 0（不许报 0 项不符）' \
    "$(PATH="$T/bin:$PATH" GETPROP_DEAD=1 RP_DB="$T/rpdb3" sh "$T/pa.sh" "$PA/data/adb/keylens.props_off" "$PA/data/adb/keylens.boot_hash" 2>&1 | sed -n 's/^mismatch=//p')" "18"
chk '降级：写入仍发生（就地替换后的值）' \
    "$(cat "$T/rpdb3/ro.debuggable")/$(cat "$T/rpdb3/ro.bootloader")" "0/release-x"

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
    echo "KL_PATCH='$PWD/tests/fixtures/backends/tricky.awk'"
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
    echo "KL_PATCH='$PWD/tests/fixtures/backends/tricky.awk'"
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
  printf '2026-10-05\nsystem=2026-10-01\n\n# 说明：下面按包名覆盖\n\n[com.example.a]\nsystem=2026-09-01\n\n' > "$1/data/adb/tricky_store/security_patch.txt"
}
SPS="$SP-s"; SPR="$SP-r"
mk_sp_fixture "$SPS"; mk_sp_fixture "$SPR"
mk_save_harness "$SPS"
# payload: patch_system -> 2026-10-07, patch_boot -> no
PL=$(printf 'patch_system=%s\npatch_boot=%s' "$(printf '2026-10-07' | base64)" "$(printf 'no' | base64)" | base64 | tr -d '\n')
chk 'save-patch：写入输出' "$(sh "$T/sv.sh" "$PL" 2>&1)" "$(KEYLENS_ROOT="$SPR" "$B" tricky-save-patch "$PL" 2>&1)"
chk 'save-patch：两侧结果逐字节一致' "$(cat "$SPS/data/adb/tricky_store/security_patch.txt")" "$(cat "$SPR/data/adb/tricky_store/security_patch.txt")"
chk 'save-patch：备份已生成' "$([ -f "$SPR/data/adb/tricky_store/security_patch.txt.bak" ] && echo yes)" "yes"
# 防空转：上面两条都比"两侧相同"，两侧都"什么都没写"也能过。夹具这次特意带上了
# 空行 + 注释行 + 段尾空行（tricky_patch_set.awk 第 4/5 步要回缩的那种形状，Rust 侧没有
# 同形的回缩代码），所以必须钉住"新键真落在全局段内、在原段头之前"和"注释行没被吃掉"。
chk 'save-patch：新键写在全局段内（段头之前）' \
    "$(awk '/^boot = no$/{b=NR} /^\[com\.example\.a\]$/{s=NR} END{print (b > 0 && s > 0 && b < s) ? "yes" : "no"}' "$SPR/data/adb/tricky_store/security_patch.txt")" "yes"
chk 'save-patch：夹具里的注释行还在' \
    "$(grep -c '^# 说明：下面按包名覆盖$' "$SPR/data/adb/tricky_store/security_patch.txt")" "1"
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
    echo "KL_PATCH='$PWD/tests/fixtures/backends/teesim.awk'"
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
    echo "KL_PATCH='$PWD/tests/fixtures/backends/tricky.awk'"
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
    echo "KL_PATCH='$PWD/tests/fixtures/backends/tricky.awk'"
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
    echo "KL_PATCH='$PWD/tests/fixtures/backends/teesim.awk'"
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
    echo "KL_PATCH='$PWD/tests/fixtures/backends/teesim.awk'"
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
LEFT=""
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
    echo "KL_PATCH='$PWD/tests/fixtures/backends/tricky.awk'"
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

# ── doctor「启动哈希」按三态取生效值（2026-11-03 真机红过的就是这一格）──
# 症状：Rust 那半直接读 keylens.boot_hash，于是 auto 档（文件本来就不存在）报成 skip、
#       off 档（文件里是哨兵 "off"）报成 bad「格式不对」并让用户重填刚清掉的那串。
# 上面那条「11 项逐行一致」为什么照绿：它的台子里既没有 boot_hash 文件、也没有能取到值的
#       后端（KL_BACKEND=tricky，auto 取不到 ⇒ 两侧都走 skip），auto/manual/off/invalid
#       这四格候选数=0。所以这里逐格钉，并且**两侧各比一次期望文本**——
#       只比"两侧相等"的话，两侧一起改错照样绿。
[ -f "$T/bin/getprop" ] && cp "$T/bin/getprop" "$T/getprop.bak"
BH_WARN_N='点「保存并应用」重写一次；重启后仍不一致说明这台设备的值变了'
bh_stub_getprop() { # <ro.boot.vbmeta.digest 的桩值>
  cat > "$T/bin/getprop" <<EOS
#!/bin/sh
if [ "\${1:-}" = "ro.boot.vbmeta.digest" ]; then printf '%s\n' "$1"; else printf '\n'; fi
EOS
  chmod +x "$T/bin/getprop"
}
bh_prep_root() { # <root> <boot_hash 内容|-> <后端 teesim|omk|tricky> <omk 配置里的 vb_hash|->
  local root="$1" bh="$2" be="$3" cfg="$4"
  rm -rf "$root"; mk_doc_fixture "$root"; mkdir -p "$root/data/adb"
  if [ "$bh" = "-" ]; then rm -f "$root/data/adb/keylens.boot_hash"
  else printf '%s\n' "$bh" > "$root/data/adb/keylens.boot_hash"; fi
  # 模块目录名两侧各自硬编码（shell 走台子给的 none-*，Rust 走真实名），两边都建才都认
  case "$be" in
    teesim) mkdir -p "$root/data/adb/modules/none-teesim" "$root/data/adb/modules/teesim" ;;
    omk)    rm -rf "$root/data/adb/modules/tricky_store"
            mkdir -p "$root/data/adb/modules/none-omk" "$root/data/adb/modules/oh_my_keymint" \
                     "$root/data/misc/keystore/omk"
            printf 'vb_hash = "%s"\n' "$cfg" > "$root/data/misc/keystore/omk/config.toml" ;;
  esac
}
bh_row_sh() { mk_doc_harness "$1"; PATH="$T/bin:$PATH" sh "$T/doc.sh" 2>&1 \
  | awk -F'\t' '$1=="启动哈希"{print $2"|"$3"|"$4}'; }
bh_row_rs() { KEYLENS_ROOT="$1" PATH="$T/bin:$PATH" "$B" doctor 2>&1 \
  | awk -F'\t' '$1=="启动哈希"{print $2"|"$3"|"$4}'; }
bh_case() { # <标签> <boot_hash|-> <后端> <桩 digest> <omk 配置值|-> <期望 状态|说明|下一步>
  bh_prep_root "$DOCR-bhs" "$2" "$3" "$5"
  bh_prep_root "$DOCR-bhr" "$2" "$3" "$5"
  bh_stub_getprop "$4"
  chk "doctor 启动哈希：$1（shell=期望）" "$6" "$(bh_row_sh "$DOCR-bhs")"
  chk "doctor 启动哈希：$1（Rust=期望）" "$6" "$(bh_row_rs "$DOCR-bhr")"
}
bh_case 'auto·后端给的值等于当前' '-' teesim "$H64" - "ok|自动取到的值与当前值一致|"
bh_case 'auto·omk 值与当前不一致' '-' omk "$H64" 1111111111111111111111111111111111111111111111111111111111111111 \
  "warn|自动取到的值与当前值不一致|$BH_WARN_N"
bh_case 'auto·后端没给出值' '-' tricky "$H64" - "skip|自动档但后端没给出值|"
bh_case 'manual·等于当前' "$H64" tricky "$H64" - "ok|当前值等于配置值|"
bh_case 'manual·与当前不一致' "$H64" tricky \
  2222222222222222222222222222222222222222222222222222222222222222 - \
  "warn|当前值与配置值不一致|$BH_WARN_N"
bh_case 'off·明确不写' off tricky "$H64" - "skip|已设为不写 vbmeta digest|"
bh_case '配置文件里是废值' zzzz tricky "$H64" - \
  "skip|配置值不是十六进制，这一项没生效|在「属性伪装」页重填，或改回自动"
if [ -f "$T/getprop.bak" ]; then cp "$T/getprop.bak" "$T/bin/getprop"; else rm -f "$T/bin/getprop"; fi

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
    echo "KL_PATCH='$PWD/tests/fixtures/backends/tricky.awk'"
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
    echo "KL_PATCH='$PWD/tests/fixtures/backends/tricky.awk'"
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
    echo "KL_PATCH='$PWD/tests/fixtures/backends/tricky.awk'"
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
    echo "KL_PATCH='$PWD/tests/fixtures/backends/teesim.awk'"
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
    echo "KL_PATCH='$PWD/tests/fixtures/backends/omk.awk'"
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
    echo "KL_PATCH='$PWD/tests/fixtures/backends/omk.awk'"
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
    echo "KL_PATCH='$PWD/tests/fixtures/backends/tricky.awk'"
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
# 表驱动：单键查询（shell 参照）与全量 dump（Rust 的 env 快照）共用同一份值
ENV_TBL='ro.product.model|XQ-DQ72
ro.product.brand|Sony
ro.build.version.release|15
ro.build.version.sdk|35
ro.build.type|user
ro.boot.verifiedbootstate|green
ro.sf.lcd_density|420'
{
    printf '#!/bin/sh\nTBL=%s\n' "'$ENV_TBL'"
    cat <<'EOF'
if [ -n "${ENV_LOG:-}" ]; then printf 'getprop %s\n' "${1:-<dump>}" >> "$ENV_LOG"; fi
if [ $# -eq 0 ]; then
    printf '%s\n' "$TBL" | while IFS='|' read -r k v; do printf '[%s]: [%s]\n' "$k" "$v"; done
    exit 0
fi
printf '%s\n' "$TBL" | while IFS='|' read -r k v; do [ "$k" = "$1" ] && printf '%s\n' "$v"; done
exit 0
EOF
} > "$T/envbin/getprop"
cat > "$T/envbin/resetprop" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$T/envbin/id" <<'EOF'
#!/bin/sh
if [ -n "${ENV_LOG:-}" ]; then printf 'id %s\n' "$*" >> "$ENV_LOG"; fi
echo 0
EOF
cat > "$T/envbin/dumpsys" <<'EOF'
#!/bin/sh
if [ -n "${ENV_LOG:-}" ]; then printf 'dumpsys %s\n' "$*" >> "$ENV_LOG"; fi
case "$1" in
  uimode) echo 'mCurUiMode=0x21' ;;
  window) echo 'type=statusBars frame=[0,0][1080,66]' ;;
  wallpaper) echo 'colorValue0=-16777216' ;;
esac
EOF
cat > "$T/envbin/wm" <<'EOF'
#!/bin/sh
if [ -n "${ENV_LOG:-}" ]; then printf 'wm %s\n' "$*" >> "$ENV_LOG"; fi
echo 'Physical density: 420'
EOF
cat > "$T/envbin/settings" <<'EOF'
#!/bin/sh
if [ -n "${ENV_LOG:-}" ]; then printf 'settings %s\n' "$*" >> "$ENV_LOG"; fi
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
MODDIR="\${KL_TEST_MODDIR:-$PWD/module}"
PROP_FILE="\${MODDIR}/module.prop"
KL_ENV_CACHE="\${KL_ENV_CACHE:-$ENV_ROOT/data/adb/keylens.env.cache}"
SH
sed -n '/^mod_prop() {/,/^}/p' module/webui.sh >> "$T/env.sh"
sed -n '/^prop_now() {/,/^}/p' module/webui.sh >> "$T/env.sh"
sed -n '/^cmd_env() {/,/^}/p' module/webui.sh >> "$T/env.sh"
echo 'cmd_env' >> "$T/env.sh"
# 两边各用一份空缓存：这条必须是「冷 vs 冷」，否则 shell 先落盘、Rust 直接读缓存，
# 看着像对拍其实只证了"读缓存读得对"。冷热与互读在下面单独一节钉住。
rm -f "$ENV_ROOT/cold.shell" "$ENV_ROOT/cold.rust"
KL_ENV_CACHE="$ENV_ROOT/cold.shell" PATH="$T/envbin:$PATH" KEYLENS_MODDIR="$PWD/module" \
    sh "$T/env.sh" > "$ENV_ROOT/cold.shell.out" 2>&1
KL_ENV_CACHE="$ENV_ROOT/cold.rust" PATH="$T/envbin:$PATH" KEYLENS_MODDIR="$PWD/module" \
    KEYLENS_ROOT="$ENV_ROOT" "$B" env > "$ENV_ROOT/cold.rust.out" 2>&1
chk 'env：逐行一致（冷 vs 冷）' "$(cat "$ENV_ROOT/cold.shell.out")" "$(cat "$ENV_ROOT/cold.rust.out")"

echo "── env 缓存（两边共用一个文件、同一套键）──"
# 缓存文件是 shell 与 Rust 共用的：任何一边的探测口径不同，就会把两种答案写进同一份文件
# 互相污染。这一节证三件事：冷=热（缓存不改答案）、互读（谁写的都能被对方读出一样的行）、
# 热了真的不起那些进程（只看输出一样是证不出省了 fork 的）。
EMOD="$ENV_ROOT/data/adb/modules/keylens"
es() { KL_TEST_MODDIR="$EMOD" KL_ENV_CACHE="$1" ENV_LOG="$2" PATH="$T/envbin:$PATH" sh "$T/env.sh" 2>&1; }
er() { KL_ENV_CACHE="$1" ENV_LOG="$2" PATH="$T/envbin:$PATH" KEYLENS_MODDIR="$EMOD" KEYLENS_ROOT="$ENV_ROOT" "$B" env 2>&1; }
rm -f "$ENV_ROOT/ks.cache" "$ENV_ROOT/kr.cache"
es "$ENV_ROOT/ks.cache" "$ENV_ROOT/log.s1" > "$ENV_ROOT/s1.out"
es "$ENV_ROOT/ks.cache" "$ENV_ROOT/log.s2" > "$ENV_ROOT/s2.out"
er "$ENV_ROOT/kr.cache" "$ENV_ROOT/log.r1" > "$ENV_ROOT/r1.out"
er "$ENV_ROOT/kr.cache" "$ENV_ROOT/log.r2" > "$ENV_ROOT/r2.out"
chk 'env 冷（同一个模块根）：shell vs Rust 逐行一致' "$(cat "$ENV_ROOT/s1.out")" "$(cat "$ENV_ROOT/r1.out")"
chk 'env 缓存：shell 冷=热（缓存不改答案）' "$(cat "$ENV_ROOT/s1.out")" "$(cat "$ENV_ROOT/s2.out")"
chk 'env 缓存：Rust 冷=热（缓存不改答案）' "$(cat "$ENV_ROOT/r1.out")" "$(cat "$ENV_ROOT/r2.out")"
chk 'env 缓存互读：shell 写的缓存 Rust 读出同样的行' "$(cat "$ENV_ROOT/s1.out")" "$(er "$ENV_ROOT/ks.cache" "$ENV_ROOT/log.x1")"
chk 'env 缓存互读：Rust 写的缓存 shell 读出同样的行' "$(cat "$ENV_ROOT/r1.out")" "$(es "$ENV_ROOT/kr.cache" "$ENV_ROOT/log.x2")"
# 起了几个进程：热跑一次都不许再碰 getprop / dumpsys window / wm / id
cnt() { if [ -f "$2" ]; then grep -c -- "$1" "$2"; else echo 0; fi; }
chk 'env 热：Rust 不再起 getprop' "0" "$(cnt '^getprop' "$ENV_ROOT/log.r2")"
chk 'env 热：Rust 不再起 dumpsys window' "0" "$(cnt '^dumpsys window' "$ENV_ROOT/log.r2")"
chk 'env 热：Rust 不再起 wm' "0" "$(cnt '^wm' "$ENV_ROOT/log.r2")"
chk 'env 热：Rust 不再起 id' "0" "$(cnt '^id' "$ENV_ROOT/log.r2")"
# 反面对照：热跑仍要起"每次现取"的那两条，否则上面四个 0 可能只是日志压根没写
chk 'env 热：Rust 仍现取深浅色（dumpsys uimode）' "1" "$(cnt '^dumpsys uimode' "$ENV_ROOT/log.r2")"
chk 'env 热：Rust 仍现取种子（settings get）' "1" "$(cnt '^settings get' "$ENV_ROOT/log.r2")"
chk 'env 冷：Rust 只起一次 getprop（全量快照）' "1" "$(cnt '^getprop <dump>' "$ENV_ROOT/log.r1")"
chk 'env 冷：Rust 逐键取为零' "0" "$(cnt '^getprop [^<]' "$ENV_ROOT/log.r1")"
chk 'env 冷：shell 参照仍是逐键取（6 次）' "6" "$(cnt '^getprop [^<]' "$ENV_ROOT/log.s1")"
chk 'env 冷：shell 参照起 dumpsys window + wm + id' "3" "$(( $(cnt '^dumpsys window' "$ENV_ROOT/log.s1") + $(cnt '^wm' "$ENV_ROOT/log.s1") + $(cnt '^id' "$ENV_ROOT/log.s1") ))"
# 落盘形状：19 行、键名逐个点名（只跟 shell 比会让两边一起漂）
chk 'env 缓存：键名与顺序（19 个，逐字）' \
  "v1,resetprop,awk,base64,base64_cmd,ino_mode,ino_cmd,root_user,webui_sh,device,brand,android,sdk,build_type,vbstate,statusbar_dp,frro_path,frro_mtime,frro_b64" \
  "$(cut -f1 "$ENV_ROOT/kr.cache" | tr '\n' ',' | sed 's/,$//')"
chk 'env 缓存：键名与顺序（shell 写的同一份）' \
  "$(cut -f1 "$ENV_ROOT/ks.cache" | tr '\n' ',' | sed 's/,$//')" \
  "$(cut -f1 "$ENV_ROOT/kr.cache" | tr '\n' ',' | sed 's/,$//')"
# 缓存键 = v1|模块目录|module.prop 的 version|/system/build.prop 的 mtime。
# 末段按宿主机自己算（WSL/Git Bash 没有 /system），所以比前三段。
# 剥末段走 sed 不走 ${v%|*}：真机的 mksh 里那个写法不生效（设备台子上实测出来的）。
v1r=$(awk -F'\t' 'NR==1{print $2}' "$ENV_ROOT/kr.cache" | sed 's/|[^|]*$//')
chk 'env 缓存：缓存键带模块目录与版本' "v1|$EMOD|v3.0.1" "$v1r"
chk 'env 缓存：权限 600' "600" "$(stat -c %a "$ENV_ROOT/kr.cache" 2>/dev/null || echo 无)"
chk 'env 缓存：改名落盘，不留 .tmp.*' "0" "$(ls "$ENV_ROOT"/kr.cache.tmp.* 2>/dev/null | wc -l | tr -d ' ')"
# 正对照：改 module.prop 的 version → 缓存必须作废（重探），输出仍逐行一致
printf 'id=keylens\nversion=v9.9.9\n' > "$EMOD/module.prop"
er "$ENV_ROOT/kr.cache" "$ENV_ROOT/log.r3" > "$ENV_ROOT/r3.out"
chk 'env 缓存：换模块版本 → 重探（getprop 又起了一次）' "1" "$(cnt '^getprop <dump>' "$ENV_ROOT/log.r3")"
v1r3=$(awk -F'\t' 'NR==1{print $2}' "$ENV_ROOT/kr.cache" | sed 's/|[^|]*$//')
chk 'env 缓存：换版本后缓存键跟着走' "v1|$EMOD|v9.9.9" "$v1r3"
chk 'env 缓存：换版本不改变答案（版本不进输出）' "$(cat "$ENV_ROOT/r1.out")" "$(cat "$ENV_ROOT/r3.out")"
er "$ENV_ROOT/kr.cache" "$ENV_ROOT/log.r4" > "$ENV_ROOT/r4.out"
chk 'env 缓存：改完一轮后重新命中（热跑回到零 getprop）' "0" "$(cnt '^getprop' "$ENV_ROOT/log.r4")"
printf 'id=keylens\nversion=v3.0.1\n' > "$EMOD/module.prop"

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
    echo "KL_PATCH='$PWD/tests/fixtures/backends/tricky.awk'"
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
  sed -n '/^mod_prop() {/,/^}/p' module/webui.sh >> "$T/sy.sh"
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
chk 'sync：新装应用被加入（输出）' "$(PATH="$T/sybin:$PATH" sh "$T/sy.sh" 2>/dev/null | grep -E '^(rc|count)=')" "$(PATH="$T/sybin:$PATH" KEYLENS_ROOT="$SYR" "$B" sync 2>&1 | grep -E '^(rc|count)=')"
chk 'sync：两侧目标文件逐字节一致' "$(cat "$SYS/data/adb/tricky_store/target.txt")" "$(cat "$SYR/data/adb/tricky_store/target.txt")"
chk 'sync：基线已提交' "$(cat "$SYR/data/adb/tricky_store/.kl_installed_last")" "$(cat "$SYS/data/adb/tricky_store/.kl_installed_last")"
chk 'sync：ever 已更新' "$(cat "$SYR/data/adb/tricky_store/.kl_ever" 2>/dev/null)" "$(cat "$SYS/data/adb/tricky_store/.kl_ever" 2>/dev/null)"
# harness 里 update_module_desc 是桩，description 两侧不可比；单独断言 Rust 会打这一行
chk 'sync：Rust 打出同步后的描述行' "$(PATH="$T/sybin:$PATH" KEYLENS_ROOT="$SYR" "$B" sync 2>&1 | grep -c '^description=')" '1'

echo "── icons（桌面库 → PNG + 显示名，缓存）──"
ICS="$T/ic-mod-s"; ICR="$T/ic-mod-r"
mkdir -p "$ICS/webroot" "$ICR/webroot" "$T/icbin"
cat > "$T/icbin/sqlite3" <<'EOF'
#!/bin/sh
echo 'com.a	应用A	icons/com.a.png'
EOF
cat > "$T/icbin/app_process" <<'EOF'
#!/bin/sh
echo 'com.b	应用B	icons/com.b.png'
EOF
chmod +x "$T/icbin"/*
# 空环境：两侧都找不到桌面库，应打印同一条提示（shell 侧固定读真实 /data/data）
ICNONE="$T/ic-none"; mkdir -p "$ICNONE"
cat > "$T/ic.sh" <<SH
TAB=\$(printf "\t")
NL=\$(printf "\nX"); NL=\${NL%X}
. module/lib/core.sh
. module/lib/tools.sh
MODDIR="$ICS"
ICONS_SUBDIR=icons
ARG="com.a,com.b"
SH
sed -n '/^cmd_icons() {/,/^}/p' module/webui.sh >> "$T/ic.sh"
echo 'cmd_icons' >> "$T/ic.sh"
chk 'icons：缺桌面库时提示一致' "$(PATH="$T/icbin:$PATH" sh "$T/ic.sh" 2>&1)" "$(PATH="$T/icbin:$PATH" KEYLENS_MODDIR="$ICR" KEYLENS_ROOT="$ICNONE" "$B" icons 'com.a,com.b' 2>&1)"
# 有库时 shell 侧读不到夹具（路径写死 /data/data），这半边只断言 Rust 的行为
mkdir -p "$ICNONE/data/data/com.android.launcher3/databases"
printf 'db' > "$ICNONE/data/data/com.android.launcher3/databases/app_icons.db"
chk 'icons（Rust）：SQL 行 + 缓存占位' "$(PATH="$T/icbin:$PATH" KEYLENS_MODDIR="$ICR" KEYLENS_ROOT="$ICNONE" "$B" icons 'com.a,com.b' 2>&1 | head -2 | tr '\n' '|')" "com.a	应用A	icons/com.a.png|"
chk 'icons（Rust）：缓存含缺图占位行' "$(grep -c 'com.b' "$ICR/webroot/icons/index.tsv" 2>/dev/null)" "1"

echo "── preview-*（shell 攒 diff vs Rust 影子根，逐字节）──"
# 两侧机制完全不同：shell 在 commit_backend_file 的 KL_PREVIEW 闸门处拦下落盘、把行级差异
# 攒进 KL_PREVIEW_DIFF；Rust 把整条命令在影子根里真跑一遍，事后 lcs_diff 比「真实 vs 影子」。
# 这里复用上面每条命令自己的夹具与 harness（同一份真源，不手抄），只换三件事：
#   1) commit_backend_file / kl_capture_diff 用 lib/write.sh 的真实现（原 harness 把它 cp 桩掉了）
#   2) 末尾接上 webui.sh 的预览信封（sed 原样抽取，锚点改了要当场报错，不许静默空转）
#   3) 打开 KL_PREVIEW=1
# 判据四条：输出逐字节相同；changed>0（正对照——这条预览得真的看见差异）；
#           两侧夹具跑完一个字节都没变（预览不许落盘）。
pv_env=$(sed -n '/^# 预览收尾/,/^fi$/p' module/webui.sh)
[ -n "$pv_env" ] || { echo "  ✗   抽不到 webui.sh 的预览信封（锚点改了？）"; fail=1; }

pv_fp() { # <root> → 每个文件的 sha256（相对路径，顺序固定）
    ( cd "$1" && find . -type f | LC_ALL=C sort | while read -r f; do
        printf '%s  %s\n' "$(sha256sum < "$f" | cut -d' ' -f1)" "$f"
      done )
}
pv_harness() { # <harness-fn> <file-tag> <root>
    $1 "$3"
    tail -n 1 "$T/$2.sh" > "$T/pv-call"
    # 去掉最后一行用 sed 不用 `head -n -1`：toybox 的 head 不收负数（这台子要在真机上原样跑，见 §5.10）
    sed '$d' "$T/$2.sh" > "$T/pv-$2.sh"
    {
        echo 'AWK_CMD=awk'
        # 结束锚必须严格到行尾：kl_capture_diff 里的 awk 程序有一行是 `}' "$1" "$2" ...`，
        # 用 /,/^}/ 会在那一行截断，函数少个尾巴（症状是 shell 侧 EOF expecting "}").
        sed -n '/^kl_capture_diff() {/,/^}$/p' module/lib/write.sh
        sed -n '/^commit_backend_file() {/,/^}$/p' module/lib/write.sh
        echo 'KL_PREVIEW=1'
        echo 'KL_PREVIEW_DIFF=""'
        cat "$T/pv-call"
        printf '%s\n' "$pv_env"
    } >> "$T/pv-$2.sh"
}
pv_case() { # <cmd> <fixture-fn> <harness-fn> <file-tag> <arg> [用例名]
    _s="$T/pv-$4-s"; _r="$T/pv-$4-r"
    _l="preview-$1${6:+（$6）}"
    rm -rf "$_s" "$_r"; $2 "$_s"; $2 "$_r"
    pv_harness "$3" "$4" "$_s"
    _f0=$(pv_fp "$_s")
    _a=$(sh "$T/pv-$4.sh" "$5" 2>&1 | sed -e "s|$_s||g")
    chk "$_l：夹具没被 shell 侧落盘" "$(pv_fp "$_s")" "$_f0"
    _g0=$(pv_fp "$_r")
    _b=$(KEYLENS_ROOT="$_r" "$B" "preview-$1" "$5" 2>&1)
    chk "$_l：夹具没被 Rust 侧落盘" "$(pv_fp "$_r")" "$_g0"
    chk "$_l：输出逐字节一致" "$_a" "$_b"
    chk "$_l：正对照 changed>0" \
        "$(printf '%s\n' "$_b" | sed -n 's/^changed=\([0-9]*\)$/\1/p' | awk '{print ($1 > 0) ? "yes" : "no"}')" "yes"
}
pv_case keybox-save           mk_kb_fixture mk_kb_harness   kb  "$KBPL"
pv_case tricky-save-patch     mk_sp_fixture mk_save_harness sv  "$PL"
pv_case tricky-drop-patch     mk_dp_fixture mk_drop_harness dp  com.example.a
pv_case teesim-save           mk_ts_fixture mk_ts_harness   ts  "$PLTS"
pv_case teesim-save-overrides mk_ov_fixture mk_ov_harness   ovs "$PLOV"
pv_case teesim-profile-new    mk_pn_fixture mk_pn_harness   pn  work
pv_case teesim-profile-del    mk_pd_fixture mk_pd_harness   pd  work
pv_case omk-save-injector     mk_oi_fixture mk_oi_harness   oi  "$PLOI"
pv_case omk-save-config       mk_oc_fixture mk_oc_harness   oc  "$PLOC"
# 「生效代价」有三臂（hot / restart / reboot），预览与真写必须同一口径：
# 只验 hot 那一臂的话，restart 臂里 Rust 会替用户请求重启并谎称「已请求」，reboot 臂没人验过。
PLCLOG=$(printf 'cfg_log_level=%s' "$(printf 'debug' | base64 | tr -d '\n')" | base64 | tr -d '\n')
pv_case omk-save-config mk_oc_fixture mk_oc_harness oc "$PLCLOG" 'restart 臂'
pv_case omk-save-config mk_oc_fixture mk_oc_harness oc "$PLOC2"  'reboot 臂'

# 影子根落脚点全不可用时，绝不能打一份 changed=0 的空信封：界面把"没有差异"当成无需确认，
# 直接就真写了。夹具机上没有 /data/local/tmp，所以把 TMPDIR 的父路径做成一个**普通文件**
# （create_dir_all 必然 ENOTDIR；指到不存在的目录可不行，那会被它顺手建出来）。
: > "$T/not-a-dir"
_pv_no=$(TMPDIR="$T/not-a-dir/sub" KEYLENS_ROOT="$KBR" "$B" preview-keybox-save "$KBPL" 2>&1); _pv_rc=$?
chk 'preview：落脚点全不可用 → 退 2 交给 shell' "2" "$_pv_rc"
chk 'preview：落脚点全不可用 → 不打印空信封' "0" "$(printf '%s\n' "$_pv_no" | grep -c '^changed=0')"

echo
# 下限保护：对拍只许增加、不许被悄悄删掉（新命令迁移时同步抬高这个数）
# 129 → 173：新增 preview-* 的 11 个用例 ×4 条断言（逐字节 / 两侧夹具不落盘 / changed>0 正对照）
# 173 → 175：影子根落脚点全不可用时的两条（退 2 / 不许打空信封）
# 179 → 181：props 的"起了几次 getprop"计数断言（Rust 1 次快照 vs shell 17 次逐键）
# 175 → 177：save-patch 的两条防空转断言（新键落在全局段内 / 注释行没被吃掉）
# 181 → 205：env 探针缓存一节（冷=热 / 互读 / 热跑不起 getprop·dumpsys·wm·id / 键名逐个点名 / 换版本重探）
# 177 → 179：teesim-profiles 的两条绝对断言（只列顶层 / 诱饵键不算 profile）
# 205 → 209：属性判定改成一次 dump（shell 侧不再逐键 17 次）+ getprop 全废的降级 3 条
# 209 → 216：判定换成一次 awk 出计划 + 期望表补满"构建身份"那一族（状态 A_B、链式只落一次、absent 不凭空创建）
# 216 → 239：启动哈希三态（auto 从当前后端配置派生 / random 与 null 必须熄火 /
#             手动优先 / off 一个字节都不写 / 改配置立刻跟着变 / 没后端不派生）
# 242 → 247：TEESim 那一侧改成"属性已有值就采用守护进程那份"（不拿 overrides.json 覆盖）
# 239 → 242：current= 的读数口径（两侧都用生产那份 getprop，不再手抄 resetprop；
#             外加"resetprop 读不回时仍报真值"的正对照 —— 真机上就是这么报出过一次假空）
# 247 → 261：体检「启动哈希」那一格改成按三态取生效值。上面几条 242/247 的注释是历史留下的
#             旧数字（判据早于它们），文案与判据分家本身就是这条闸的毛病，这里顺手并回一处。
# 261 → 266：apps 的三档（默认/system/all）各钉两侧**期望文本**。桩原来不认参数 ——
#             那会让 system 档算成"全量减全量=空"，两侧一起空照样绿，所以先把桩改成认 -3。
# 266 → 267：set-mode 的台子改成走**分派臂**（sed 抽 webui.sh 那一段），调用形状改成界面
#             真发的那样：`set-mode '包名 模式'` 一个参数。以前台子按两个 argv 调，
#             而 Rust 只认两个 argv —— 两边互相自证，真机上那颗「自动 →」按钮一直是死的。
# 267 → 269：「已排除」的已装宇宙从 -3 改成全量（§5.19 #4）：移出系统包后这一档必须还看得见。
#             正对照的桩认 -3，所以"退回旧口径"这一刀会被两侧各自钉住。
# 269 → 271：apps 再加一档 launchable（平台的"这是个应用"判据，§5.21）。桩要认
#             query-activities，且输出的是「包名/组件」那种形状（没有 package: 前缀）。
if [ "$oks" -lt 271 ]; then
  echo "  ✗   对拍数量低于下限（$oks < 271），疑似用例被删"; fail=1
fi
[ "$fail" = 0 ] && echo "全部通过（chk 用例 $oks 项）" || { echo "有断言失败"; exit 1; }
