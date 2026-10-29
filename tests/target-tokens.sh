#!/bin/sh
#=============================================================================
# tests/target-tokens.sh - 三个后端的目标条目语法自检（CI 跑，不需要设备）
#
# 覆盖：
#   · Tricky target.txt：行内注释、?/! 后缀、非法行忽略、同包重复取最后模式
#   · Tricky 增删：按基础包名判重/移出；set_tricky_mode 三种模式与注释保留
#   · TEESim apps：pkg / pkg@用户 / uid:数字 的原样读写与按用户精确移出
#   · 快照差分：卸载时连同 ?/!/@用户 变体一起移除；uid: 保留；新装不重复
#   · excluded / ever 只记基础包名
#   · backend-info 的三个只读解析器
#=============================================================================
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/module/lib/applist.sh"
. "$ROOT/module/lib/backend.sh"

fail=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
AWK_CMD="awk"
log_info() { :; }
log_warn() { :; }
cmd() { printf '%s\n' "${FAKE_INSTALLED:-}" | sed 's/^/package:/'; }
pm()  { cmd; }
current_stub() { [ -f "$TARGET_FILE" ] && sed '/^[[:space:]]*$/d' "$TARGET_FILE"; }

chk() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"; else printf '  ✗    %s\n        期望 [%s]，实得 [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
chk_rc() { if [ "$2" = "$3" ]; then printf '  ok   %-38s rc=%s\n' "$1" "$3"; else printf '  ✗    %-38s 期望 rc=%s，实得 %s\n' "$1" "$2" "$3"; fail=1; fi; }
chk_has() { grep -q -- "$2" "$1" && printf '  ok   %s\n' "$3" || { printf '  ✗    %s\n' "$3"; fail=1; }; }
chk_no() { grep -q -- "$2" "$1" && { printf '  ✗    %s\n' "$3"; fail=1; } || printf '  ok   %s\n' "$3"; }
list() { current_target_apps | tr '\n' ' ' | sed 's/ $//'; }
req() { printf '%s\n' "$@" > "$T/req"; }
state() { KL_DIR="$T/state"; mkdir -p "$KL_DIR"; ST_INSTALLED="$KL_DIR/.kl__installed_last"; ST_INSTALLED_NEW="$KL_DIR/.kl__installed.new"; ST_EVER="$KL_DIR/.kl__ever"; ST_EVER_NEW="$KL_DIR/.kl__ever.new"; : > "$ST_EVER"; }
state

echo "── 1 Tricky target.txt：注释 / 后缀 / 非法行 ──"
KL_BACKEND="tricky"
KL_PATCH="$ROOT/module/backends/teesim.awk"    # 只作为 backends/ 目录锚点
TARGET_FILE="$T/target.txt"
cat > "$TARGET_FILE" <<'EOF'
# google
com.a
com.b?
com.b!          # 后出现的模式生效
com.c # trailing comment
bad line
com google
EOF
chk "有效条目只剩 3 条，b 取最后模式" "com.a com.b! com.c" "$(list)"
chk "行内注释不会被当成条目" "" "$(current_target_apps | grep -F '#' || true)"

echo "── 2 Tricky：增删按基础包名 ──"
req com.b com.d?
add_target_apps "$T/req"; chk_rc "b 已存在（同包不同模式）跳过，只加 d?" 0 "$?"
chk "名单内容" "com.a com.b! com.c com.d?" "$(list)"
req com.b
remove_target_apps "$T/req"; chk_rc "移出 com.b 会连模式行一起删" 0 "$?"
chk "b 已不在名单" "com.a com.c com.d?" "$(list)"
chk "removed_list 报的是实际 token" "com.b!" "$KL_REMOVED_LIST"
chk_has "$TARGET_FILE" '^com\.c # trailing comment$' "其它行内注释原样保留"
chk_has "$ST_EVER" '^com\.b$' "ever 记基础包名 b"

echo "── 3 Tricky：set_tricky_mode ──"
printf 'com.d? # keep\ncom.e\n' > "$TARGET_FILE"
set_tricky_mode com.d leaf;  chk_rc "已经是叶证书" 1 "$?"
set_tricky_mode com.d generate; chk_rc "改成证书生成" 0 "$?"
chk_has "$TARGET_FILE" '^com\.d! # keep$' "后缀换了，注释保留"
set_tricky_mode com.d auto; chk_rc "改回自动" 0 "$?"
chk_has "$TARGET_FILE" '^com\.d # keep$' "自动模式去掉后缀"
set_tricky_mode com.zz leaf; chk_rc "没有这个包" 1 "$?"
printf 'com.s ? # spaced\n' > "$TARGET_FILE"
set_tricky_mode com.s generate; chk_rc "后缀前有空格的写法也能改" 0 "$?"
chk_has "$TARGET_FILE" '^com\.s! # spaced$' "改成规范写法，注释保留"

echo "── 4 TEESim：@用户 / uid: 原样 ──"
KL_BACKEND="teesim"
TARGET_FILE="$T/config.json"
KL_PATCH="$ROOT/module/backends/teesim.awk"
printf '%s' '{"profiles":{"default":{"apps":["com.a","com.b@10","uid:10123"]},"work":{"apps":["x"]}}}' > "$TARGET_FILE"
chk "读取原样 token" "com.a com.b@10 uid:10123" "$(list)"
req com.b com.c
add_target_apps "$T/req"; chk_rc "b 已有 @10 变体，只加 c" 0 "$?"
chk "加入后的 apps" "com.a com.b@10 com.c uid:10123" "$(list)"
req com.b@10
remove_target_apps "$T/req"; chk_rc "按用户精确移出 b@10" 0 "$?"
chk "只少了 b@10，a/c/uid 都在" "com.a com.c uid:10123" "$(list)"
chk_has "$TARGET_FILE" '"work"' "其它 profile 保留"
printf 'com.b@10\n' > "$T/req"
add_target_apps "$T/req"; chk_rc "撤销：裸 b 不存在，@10 可以加回" 0 "$?"
chk "撤销后的 apps" "com.a com.b@10 com.c uid:10123" "$(list)"
printf 'com.a@10\n' > "$T/req"
add_target_apps "$T/req"; chk_rc "@用户 与同包裸条目并存" 0 "$?"
chk "并存后的 apps" "com.a com.a@10 com.b@10 com.c uid:10123" "$(list)"

echo "── 5 快照差分：卸载清变体、uid 保留、新装不重复 ──"
KL_BACKEND="teesim"
TARGET_FILE="$T/config2.json"
printf '%s' '{"profiles":{"default":{"apps":["com.a","com.b@10","uid:10123"]}}}' > "$TARGET_FILE"
printf 'com.a\ncom.b\n' > "$KL_DIR/.kl__installed_last"
FAKE_INSTALLED="com.a"
build_app_list "$T/out"; chk "卸载 b 后 @10 一起消失，uid 保留" "com.a uid:10123" "$(sed '/^$/d' "$T/out" | tr '\n' ' ' | sed 's/ $//')"
chk_has "$ST_EVER_NEW" '^com\.b$' "ever 记的是 b（不是 b@10）"

KL_BACKEND="tricky"
TARGET_FILE="$T/target2.txt"
printf 'com.a\ncom.b?\n' > "$TARGET_FILE"
printf 'com.a\ncom.b\n' > "$KL_DIR/.kl__installed_last"
FAKE_INSTALLED="com.a"
build_app_list "$T/out"; chk "卸载 b 后 b? 一起消失" "com.a" "$(sed '/^$/d' "$T/out")"

printf 'com.a\ncom.b@10\n' > "$TARGET_FILE"
printf 'com.a\ncom.b\n' > "$KL_DIR/.kl__installed_last"
KL_BACKEND="teesim"
printf '%s' '{"profiles":{"default":{"apps":["com.a","com.b@10"]}}}' > "$TARGET_FILE"
FAKE_INSTALLED="com.a
com.b"
build_app_list "$T/out"; chk_no "$T/out" '^com\.b$' "已有 @10 变体时不再追加裸 com.b"

echo "── 6 excluded：只按基础包名 ──"
TARGET_FILE="$T/target3.txt"
KL_BACKEND="tricky"
printf 'com.a\n' > "$TARGET_FILE"
printf 'com.b\n' > "$ST_EVER"
FAKE_INSTALLED="com.a
com.b"
chk "excluded 只含 b" "com.b" "$(excluded_apps)"

echo "── 7 backend-info 解析器 ──"
cat > "$T/teesim.json" <<'EOF'
{"version":1,"profiles":{"default":{"keybox":"a.xml","mode":"generation","patchLevel":{"system":"today","vendor":"YYYY-MM-05","boot":"no"},"apps":["com.a"]},"work":{"apps":["com.c"]}}}
EOF
info=$(awk -f "$ROOT/module/backends/teesim_info.awk" "$T/teesim.json")
chk "config_version" "1" "$(printf '%s\n' "$info" | sed -n 's/^config_version=//p')"
chk "profiles 数量" "2" "$(printf '%s\n' "$info" | sed -n 's/^profiles=//p')"
chk "default mode" "generation" "$(printf '%s\n' "$info" | sed -n 's/^default_mode=//p')"
chk "default keybox" "a.xml" "$(printf '%s\n' "$info" | sed -n 's/^default_keybox=//p')"
chk "patch system" "today" "$(printf '%s\n' "$info" | sed -n 's/^default_patch_system=//p')"
chk "patch boot" "no" "$(printf '%s\n' "$info" | sed -n 's/^default_patch_boot=//p')"

printf '20241101\n[com.google.android.gms]\nsystem=2024-10-01\n[com.foo]\nboot=no\n' > "$T/patch.txt"
info=$(awk -f "$ROOT/module/backends/tricky_info.awk" "$T/patch.txt")
chk "Tricky 全局 all" "20241101" "$(printf '%s\n' "$info" | sed -n 's/^patch_all=//p')"
chk "Tricky 包级段数量" "2" "$(printf '%s\n' "$info" | sed -n 's/^patch_packages=//p')"
chk "Tricky 行数" "5" "$(printf '%s\n' "$info" | sed -n 's/^patch_lines=//p')"

cat > "$T/injector.toml" <<'EOF'
version = 1
scoop = [
  "com.a",
  "com.b",
]
[main]
enabled = true
log_level = "debug"
[filter]
enabled = true
deny_packages = ["com.bad", "com.worse"]
block_android_package = true
allow_unknown_package = false
[intercept]
get_key_entry = true
delete_key = false
grant = true
EOF
cat > "$T/omk-config.toml" <<'EOF'
version = 2
[main]
log_level = "debug"
[trust]
os_version = "auto"
security_patch = "auto"
os_patchlevel = "auto"
vendor_patchlevel = "auto"
boot_patchlevel = "no"
verified_boot_state = true
device_locked = true
EOF
info=$(awk -v injector="$T/injector.toml" -v config="$T/omk-config.toml" \
    -f "$ROOT/module/backends/omk_info.awk" "$T/injector.toml" "$T/omk-config.toml")
chk "injector version" "1" "$(printf '%s\n' "$info" | sed -n 's/^injector_version=//p')"
chk "deny 数量" "2" "$(printf '%s\n' "$info" | sed -n 's/^filter_deny=//p')"
chk "intercept true 数量" "2" "$(printf '%s\n' "$info" | sed -n 's/^intercept_true=//p')"
chk "config version" "2" "$(printf '%s\n' "$info" | sed -n 's/^config_version=//p')"
chk "trust boot patchlevel" "no" "$(printf '%s\n' "$info" | sed -n 's/^trust_boot_patchlevel=//p')"

echo "── 8 entry_base：变体归到基础包名 ──"
cat > "$T/toks" <<'EOF'
com.a
com.b?
com.c!
com.d@10
uid:10123
EOF
got=$(awk -v backend=tricky -f "$ROOT/module/backends/entry_base.awk" "$T/toks" | tr '\n' ' ' | sed 's/ $//')
chk "tricky 变体" "com.a com.b com.c com.d@10 uid:10123" "$got"
got=$(awk -v backend=teesim -f "$ROOT/module/backends/entry_base.awk" "$T/toks" | tr '\n' ' ' | sed 's/ $//')
chk "teesim 变体（uid 丢弃）" "com.a com.b? com.c! com.d" "$got"

echo "── 9 is_target_entry：按后端校验 ──"
KL_BACKEND=tricky
is_target_entry 'com.a?' && ok=1 || ok=0; chk "tricky 接受 ?" 1 "$ok"
is_target_entry 'com.a@10' && ok=1 || ok=0; chk "tricky 拒绝 @用户" 0 "$ok"
KL_BACKEND=teesim
is_target_entry 'com.a@10' && ok=1 || ok=0; chk "teesim 接受 @用户" 1 "$ok"
is_target_entry 'uid:10123' && ok=1 || ok=0; chk "teesim 接受 uid:" 1 "$ok"
is_target_entry 'com.a?' && ok=1 || ok=0; chk "teesim 拒绝模式后缀" 0 "$ok"
KL_BACKEND=omk
is_target_entry 'com.a' && ok=1 || ok=0; chk "omk 接受包名" 1 "$ok"
is_target_entry 'com.a?' && ok=1 || ok=0; chk "omk 拒绝后缀" 0 "$ok"

if [ "$fail" = 0 ]; then echo "全部通过"; else echo "有断言失败"; exit 1; fi
