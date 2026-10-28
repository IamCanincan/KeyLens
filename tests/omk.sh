#!/bin/sh
#=============================================================================
# tests/omk.sh - OhMyKeymint 后端的自检（CI，不需要设备）
#
# 测真实的 lib/backend.sh + backends/omk*.awk：
#   · scoop 数组的读取（多行 / 单行 / 空 / 缺失）
#   · 定点替换只动 scoop，注释、version、[main]/[filter]/[scoop.x] 原样保留
#   · 内容一致不落盘；成功改动写备份并请求 OMK injector 重载
#   · 「恢复」只加一条，已存在不落盘
#   · 三个后端的冲突矩阵（任一两个以上启用即冲突）
#=============================================================================
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/module/lib/applist.sh"
. "$ROOT/module/lib/backend.sh"

fail=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
TAA_DIR="$T/state"
mkdir -p "$TAA_DIR"
TARGET_FILE="$T/injector.toml"
TAA_PATCH="$ROOT/module/backends/omk.awk"
AWK_CMD="awk"
TAA_BACKEND="omk"
ST_INSTALLED="$TAA_DIR/.ts_installed_last"
ST_INSTALLED_NEW="$TAA_DIR/.ts_installed.new"
ST_EVER="$TAA_DIR/.ts_ever"
ST_EVER_NEW="$TAA_DIR/.ts_ever.new"
FAKE=""
cmd() { printf '%s\n' "$FAKE"; }
pm()  { cmd; }
log_info() { :; }
log_warn() { :; }
OMK_STATE_DIR="$T/omk"
mkdir -p "$OMK_STATE_DIR"

chk() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"; else printf '  ✗    %s\n        期望 [%s]，实得 [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
chk_rc() { if [ "$2" = "$3" ]; then printf '  ok   %-34s rc=%s\n' "$1" "$3"; else printf '  ✗    %-34s 期望 rc=%s，实得 %s\n' "$1" "$2" "$3"; fail=1; fi; }
chk_has() { grep -q -- "$2" "$1" && printf '  ok   %s\n' "$3" || { printf '  ✗    %s\n' "$3"; fail=1; }; }
chk_no() { grep -q -- "$2" "$1" && { printf '  ✗    %s\n' "$3"; fail=1; } || printf '  ok   %s\n' "$3"; }
list() { printf '%s\n' "$@" > "$T/list"; }

fixture() {
    cat > "$TARGET_FILE" <<'EOF'
# top comment
version = 1

scoop = [
  "com.a",
  "com.b",
]

[main]
enabled = true

[filter]
deny_packages = []
enabled = true

[scoop.com.a]
mode = "strict"
EOF
}

echo "── 1 读取 scoop ──"
fixture
chk "多行数组" "com.a com.b" "$(current_target_apps | tr '\n' ' ' | sed 's/ $//')"
printf 'version = 1\nscoop = ["x.y", "z.w"]\n' > "$TARGET_FILE"
chk "单行数组" "x.y z.w" "$(current_target_apps | tr '\n' ' ' | sed 's/ $//')"
printf 'scoop = []\n' > "$TARGET_FILE"
chk "空数组" "" "$(current_target_apps)"
printf 'version = 1\n[main]\nenabled = true\n' > "$TARGET_FILE"
chk "没有 scoop" "" "$(current_target_apps)"
awk -f "$ROOT/module/backends/omk_list.awk" "$TARGET_FILE" >/dev/null 2>&1
chk_rc "没有 scoop 时读取器退出 1" 1 "$?"

echo "── 2 只替换 scoop，其它原样保留 ──"
fixture
list com.c com.d
omk_write_list "$T/list"; chk_rc "写入成功" 0 "$?"
chk "读取回新列表" "com.c com.d" "$(current_target_apps | tr '\n' ' ' | sed 's/ $//')"
chk_has "$TARGET_FILE" '^# top comment$' "顶部注释保留"
chk_has "$TARGET_FILE" '^version = 1$' "version 保留"
chk_has "$TARGET_FILE" '^\[main\]$' "[main] 保留"
chk_has "$TARGET_FILE" '^deny_packages = \[\]$' "其它数组保留"
chk_has "$TARGET_FILE" '^\[scoop\.com\.a\]$' "per-package 段保留"
chk_has "$TARGET_FILE" '^mode = "strict"$' "per-package 内容保留"
chk_has "$TARGET_FILE" '^  "com\.c",$' "元素缩进两格"
chk_has "$TARGET_FILE" '^\]$' "闭合括号回到行首"
chk_has "$TAA_DIR/injector.toml.bak" '"com.a"' "写入前备份了原文件"
[ -f "$OMK_STATE_DIR/restart.injector" ] && printf '  ok   已请求 OMK 重载\n' || { printf '  ✗   没有写重启请求\n'; fail=1; }

before=$(sha256sum "$TARGET_FILE" | cut -d' ' -f1)
omk_write_list "$T/list"; chk_rc "内容一致返回 1" 1 "$?"
chk "内容一致不落盘" "$before" "$(sha256sum "$TARGET_FILE" | cut -d' ' -f1)"

printf 'version = 1\n[main]\nenabled = true\n' > "$TARGET_FILE"
before=$(sha256sum "$TARGET_FILE" | cut -d' ' -f1)
omk_write_list "$T/list"; chk_rc "没有 scoop 时失败" 2 "$?"
chk "失败不改文件" "$before" "$(sha256sum "$TARGET_FILE" | cut -d' ' -f1)"

echo "── 3 「恢复」单条 ──"
fixture
add_target_app "com.g"; chk_rc "加回成功" 0 "$?"
chk "列表包含新条目" "com.a com.b com.g" "$(current_target_apps | tr '\n' ' ' | sed 's/ $//')"
chk_has "$TARGET_FILE" '^\[filter\]$' "其它段仍在"
grep -qx "com.g" "$ST_EVER" && printf '  ok   加入的条目并入了 ever\n' || { printf '  ✗   ever 没有更新\n'; fail=1; }
add_target_app "com.a"; chk_rc "已存在返回 1" 1 "$?"

echo "── 4 冲突矩阵（三个后端） ──"
M="$T/mods"; mkdir -p "$M/teesim" "$M/tricky_store" "$M/oh_my_keymint"
TEESIM_MODULE="$M/teesim"; TRICKY_MODULE="$M/tricky_store"; OMK_MODULE="$M/oh_my_keymint"
backends_conflict; chk_rc "三个都启用 = 冲突" 0 "$?"
rm -rf "$M/teesim"; backends_conflict; chk_rc "两个启用 = 冲突" 0 "$?"
touch "$M/tricky_store/disable"; backends_conflict; chk_rc "只剩一个启用 = 不冲突" 1 "$?"
rm -f "$M/tricky_store/disable"; touch "$M/oh_my_keymint/disable"; backends_conflict; chk_rc "另一个启用 = 不冲突" 1 "$?"
rm -rf "$M/tricky_store"; backends_conflict; chk_rc "只剩 OMK = 不冲突" 1 "$?"

chk "后端名称" "OhMyKeymint" "$(TAA_BACKEND=omk; backend_name)"

echo "── 5 整条同步：首次沿用不动文件 ──"
fixture
before=$(sha256sum "$TARGET_FILE" | cut -d' ' -f1)
FAKE="package:com.a
package:com.b"
rm -f "$ST_INSTALLED" "$ST_INSTALLED_NEW" "$ST_EVER" "$ST_EVER_NEW"
sync_omk_injector "$TARGET_FILE" "$T/tmp"; chk_rc "首次沿用返回 1（不写）" 1 "$?"
chk "文件逐字节未变" "$before" "$(sha256sum "$TARGET_FILE" | cut -d' ' -f1)"
[ -s "$ST_INSTALLED" ] && printf '  ok   基线已提交\n' || { printf '  ✗   基线没提交\n'; fail=1; }
chk "ever 记的是现有名单" "com.a com.b" "$(sort "$ST_EVER" | tr '\n' ' ' | sed 's/ $//')"
FAKE="package:com.a
package:com.b
package:com.c"
sync_omk_injector "$TARGET_FILE" "$T/tmp"; chk_rc "有新装时写入" 0 "$?"
chk "新装已加入" "com.a com.b com.c" "$(current_target_apps | sort | tr '\n' ' ' | sed 's/ $//')"

if [ "$fail" = 0 ]; then echo "全部通过"; else echo "有断言失败"; fi
exit $fail
