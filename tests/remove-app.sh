#!/bin/sh
#=============================================================================
# tests/remove-app.sh - 「从名单里移出应用」的自检（CI 跑，不需要设备）
#
# 测的是真实 lib/backend.sh 的 remove_target_apps：
#   · Tricky 只删匹配行，注释、顺序与其余条目保留
#   · TEESim / OhMyKeymint 只替换数组，其它字段/段保留
#   · 本来就不在名单里返回 1 且文件逐字节不变
#   · 会清空名单时返回 3 且文件逐字节不变
#   · 目标文件损坏/定位不到数组时返回 2，不伪装成「本来就不在」
#   · 移出前把当前名单并入 ever，excluded 能认出被移出的包
#=============================================================================
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/module/lib/applist.sh"
. "$ROOT/module/lib/backend.sh"

fail=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
KL_DIR="$T/state"
mkdir -p "$KL_DIR"
ST_INSTALLED="$KL_DIR/.kl_installed_last"
ST_INSTALLED_NEW="$KL_DIR/.kl_installed.new"
ST_EVER="$KL_DIR/.kl_ever"
ST_EVER_NEW="$KL_DIR/.kl_ever.new"
AWK_CMD="awk"
OMK_STATE_DIR="$T/omk"
mkdir -p "$OMK_STATE_DIR"
log_info() { :; }
log_warn() { :; }

chk() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"; else printf '  ✗    %s\n        期望 [%s]，实得 [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
chk_rc() { if [ "$2" = "$3" ]; then printf '  ok   %-34s rc=%s\n' "$1" "$3"; else printf '  ✗    %-34s 期望 rc=%s，实得 %s\n' "$1" "$2" "$3"; fail=1; fi; }
chk_has() { grep -q -- "$2" "$1" && printf '  ok   %s\n' "$3" || { printf '  ✗    %s\n' "$3"; fail=1; }; }
chk_no() { grep -q -- "$2" "$1" && { printf '  ✗    %s\n' "$3"; fail=1; } || printf '  ok   %s\n' "$3"; }
req() { printf '%s\n' "$@" > "$T/req"; }
list() { current_target_apps | tr '\n' ' ' | sed 's/ $//'; }

echo "── 1 Tricky：只删匹配行 ──"
KL_BACKEND="tricky"
KL_PATCH="$ROOT/tests/fixtures/backends/teesim.awk"
TARGET_FILE="$T/target.txt"
: > "$ST_EVER"
printf '# keep\ncom.a\ncom.b\ncom.c' > "$TARGET_FILE"   # 故意不带结尾换行
req com.b
remove_target_apps "$T/req"; chk_rc "移出成功" 0 "$?"
printf '# keep\ncom.a\ncom.c\n' > "$T/exp"
cmp -s "$T/exp" "$TARGET_FILE" && printf '  ok   注释与剩余顺序保留、补了结尾换行\n' \
    || { printf '  ✗   移出后的内容不对\n'; fail=1; }
chk_has "$ST_EVER" '^com\.b$' "被移出的包并入了 ever"
chk "removed_list 记录 b" "com.b" "$KL_REMOVED_LIST"

before=$(sha256sum "$TARGET_FILE" | cut -d' ' -f1)
req com.d
remove_target_apps "$T/req"; chk_rc "本来就不在返回 1" 1 "$?"
chk "文件逐字节未变" "$before" "$(sha256sum "$TARGET_FILE" | cut -d' ' -f1)"
chk "未移出时 removed_list 为空" "" "$KL_REMOVED_LIST"

req com.a com.c
remove_target_apps "$T/req"; chk_rc "会清空时返回 3" 3 "$?"
chk "清空被拒后文件未变" "$before" "$(sha256sum "$TARGET_FILE" | cut -d' ' -f1)"

printf '# keep\ncom.a\ncom.b\ncom.c\n' > "$TARGET_FILE"
req com.a com.b
remove_target_apps "$T/req"; chk_rc "一次移出多条" 0 "$?"
chk "多条移出后只剩 c" "com.c" "$(list)"
chk "removed_list 记录两条" "com.a,com.b" "$KL_REMOVED_LIST"

printf '# only\n\n' > "$TARGET_FILE"
req com.a
remove_target_apps "$T/req"; chk_rc "只有注释时返回 1" 1 "$?"

printf 'not a package list\n' > "$T/req"
TARGET_FILE="$T/nope.txt"
remove_target_apps "$T/req"; chk_rc "文件不存在返回 2" 2 "$?"

echo "── 2 excluded：被移出的包仍被记住 ──"
TARGET_FILE="$T/target.txt"
printf '# keep\ncom.a\ncom.c\n' > "$TARGET_FILE"
cmd() { printf 'package:com.a\npackage:com.b\npackage:com.c\n'; }
pm() { cmd; }
chk "excluded 只含被移出的 b" "com.b" "$(excluded_apps)"
chk_no "$TARGET_FILE" '^com\.b$' "目标文件里没有 b"

echo "── 3 TEESim：只改 default.apps ──"
KL_BACKEND="teesim"
TARGET_FILE="$T/config.json"
KL_PATCH="$ROOT/tests/fixtures/backends/teesim.awk"
: > "$ST_EVER"
cat > "$TARGET_FILE" <<'EOF'
{
  "profiles": {
    "default": {
      "apps": [
        "com.a",
        "com.b",
        "com.c"
      ],
      "mode": "keep"
    },
    "other": {
      "apps": [
        "x"
      ]
    }
  },
  "extra": 1
}
EOF
req com.b
remove_target_apps "$T/req"; chk_rc "移出成功" 0 "$?"
chk "apps 变为 a/c" "com.a com.c" "$(list)"
chk_has "$TARGET_FILE" '"mode": "keep"' "其它字段保留（mode）"
chk_has "$TARGET_FILE" '"other"' "其它 profile 保留"
chk_has "$ST_EVER" '^com\.b$' "ever 含被移出的 b"

before=$(sha256sum "$TARGET_FILE" | cut -d' ' -f1)
req com.z
remove_target_apps "$T/req"; chk_rc "本来就不在返回 1" 1 "$?"
chk "文件逐字节未变" "$before" "$(sha256sum "$TARGET_FILE" | cut -d' ' -f1)"

req com.a com.c
remove_target_apps "$T/req"; chk_rc "会清空时返回 3" 3 "$?"
chk "清空被拒后文件未变" "$before" "$(sha256sum "$TARGET_FILE" | cut -d' ' -f1)"

printf '{"profiles": {"default": {}}}\n' > "$TARGET_FILE"
req com.a
remove_target_apps "$T/req"; chk_rc "定位不到 apps 返回 2" 2 "$?"

echo "── 4 OhMyKeymint：只改 scoop ──"
KL_BACKEND="omk"
TARGET_FILE="$T/injector.toml"
KL_PATCH="$ROOT/tests/fixtures/backends/omk.awk"
: > "$ST_EVER"
cat > "$TARGET_FILE" <<'EOF'
# top comment
version = 1

scoop = [
  "com.a",
  "com.b",
  "com.c",
]

[main]
enabled = true

[filter]
deny_packages = []
enabled = true

[scoop.com.a]
mode = "strict"
EOF
req com.b
remove_target_apps "$T/req"; chk_rc "移出成功" 0 "$?"
chk "scoop 变为 a/c" "com.a com.c" "$(list)"
chk_has "$TARGET_FILE" '^# top comment$' "顶部注释保留"
chk_has "$TARGET_FILE" '^version = 1$' "version 保留"
chk_has "$TARGET_FILE" '^\[main\]$' "[main] 保留"
chk_has "$TARGET_FILE" '^deny_packages = \[\]$' "其它数组保留"
chk_has "$TARGET_FILE" '^\[scoop\.com\.a\]$' "per-package 段保留"
chk_has "$KL_DIR/injector.toml.bak" '"com.b"' "写入前备份了原文件"
[ -f "$OMK_STATE_DIR/restart.injector" ] && printf '  ok   已请求 OMK 重载\n' || { printf '  ✗   没有写重启请求\n'; fail=1; }
chk_has "$ST_EVER" '^com\.b$' "ever 含被移出的 b"

before=$(sha256sum "$TARGET_FILE" | cut -d' ' -f1)
req com.z
remove_target_apps "$T/req"; chk_rc "本来就不在返回 1" 1 "$?"
chk "文件逐字节未变" "$before" "$(sha256sum "$TARGET_FILE" | cut -d' ' -f1)"

req com.a com.c
remove_target_apps "$T/req"; chk_rc "会清空时返回 3" 3 "$?"
chk "清空被拒后文件未变" "$before" "$(sha256sum "$TARGET_FILE" | cut -d' ' -f1)"

printf 'version = 1\n[main]\nenabled = true\n' > "$TARGET_FILE"
req com.a
remove_target_apps "$T/req"; chk_rc "没有 scoop 返回 2" 2 "$?"

printf 'version = 1\nscoop = ["com.a", "com.b"]\n' > "$TARGET_FILE"
req com.a
remove_target_apps "$T/req"; chk_rc "单行数组移出成功" 0 "$?"
chk "单行数组剩余 b" "com.b" "$(list)"

if [ "$fail" -eq 0 ]; then
    echo "全部通过"
else
    echo "有断言失败"
fi
exit "$fail"
