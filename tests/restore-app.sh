#!/bin/sh
#=============================================================================
# tests/restore-app.sh - 「把已排除的应用加回名单」的自检（CI 跑，不需要设备）
#
# 测的是真实 lib/backend.sh 的 add_target_app 与 lib/applist.sh 的 is_pkg_name：
#   · 两个后端的写回路径（Tricky 逐行追加 / TEESim 只改 default.apps）
#   · 本来就在名单里时不落盘（返回 1，文件逐字节不变）
#   · 原文件没有结尾换行时不会把新包名粘到最后一行
#   · TEESim 的其它字段、其它 profile 原样保留
#=============================================================================
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/module/lib/applist.sh"
. "$ROOT/module/lib/backend.sh"

fail=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
KL_DIR="$T"
AWK_CMD="awk"
KL_PATCH="$ROOT/module/backends/teesim.awk"

chk() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"; else printf '  ✗    %s\n        期望 [%s]，实得 [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
chk_rc() { if [ "$2" = "$3" ]; then printf '  ok   %-34s rc=%s\n' "$1" "$3"; else printf '  ✗    %-34s 期望 rc=%s，实得 %s\n' "$1" "$2" "$3"; fail=1; fi; }
chk_pkg() { if is_pkg_name "$2"; then got=0; else got=1; fi; chk_rc "$1" "$3" "$got"; }

echo "── 1 包名形态 ──"
chk_pkg "com.termux" "com.termux" 0
chk_pkg "两段最短" "a.b" 0
chk_pkg "下划线与数字" "com.example_1.app" 0
chk_pkg "单段拒绝" "termux" 1
chk_pkg "空段拒绝" "com..x" 1
chk_pkg "前导点拒绝" ".com.x" 1
chk_pkg "结尾点拒绝" "com.x." 1
chk_pkg "段首数字拒绝" "com.1x" 1
chk_pkg "连字符拒绝" "com.x-y" 1
chk_pkg "斜杠拒绝" "com.x/y" 1
chk_pkg "空串拒绝" "" 1

echo "── 2 Tricky Store：逐行追加 ──"
KL_BACKEND="tricky"
TARGET_FILE="$T/target.txt"
printf '# keep\ncom.a\ncom.b' > "$TARGET_FILE"      # 故意不带结尾换行
add_target_app "com.c"; chk_rc "追加成功" 0 "$?"
printf '# keep\ncom.a\ncom.b\ncom.c\n' > "$T/exp"
cmp -s "$T/exp" "$TARGET_FILE" && printf '  ok   内容与顺序正确、结尾补了换行\n' \
    || { printf '  ✗   追加后的内容不对\n'; fail=1; }
before=$(sha256sum "$TARGET_FILE" | cut -d' ' -f1)
add_target_app "com.a"; chk_rc "已存在不落盘" 1 "$?"
after=$(sha256sum "$TARGET_FILE" | cut -d' ' -f1)
chk "文件逐字节未变" "$before" "$after"
rm -f "$TARGET_FILE"
add_target_app "com.a"; chk_rc "文件不存在时报失败" 2 "$?"

echo "── 3 TEESim：只改 default.apps ──"
KL_BACKEND="teesim"
TARGET_FILE="$T/config.json"
cat > "$TARGET_FILE" <<'EOF'
{
  "profiles": {
    "default": {
      "apps": [
        "com.a",
        "com.b"
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
add_target_app "com.c"; chk_rc "加回成功" 0 "$?"
chk "apps 变为 a/b/c" "com.a com.b com.c" "$(current_target_apps | tr '\n' ' ' | sed 's/ $//')"
grep -q '"mode": "keep"' "$TARGET_FILE" && printf '  ok   其它字段保留（mode）\n' || { printf '  ✗   mode 丢了\n'; fail=1; }
grep -q '"other"' "$TARGET_FILE" && printf '  ok   其它 profile 保留\n' || { printf '  ✗   other profile 丢了\n'; fail=1; }
grep -q '"extra": 1' "$TARGET_FILE" && printf '  ok   顶层其它字段保留\n' || { printf '  ✗   extra 丢了\n'; fail=1; }
before=$(sha256sum "$TARGET_FILE" | cut -d' ' -f1)
add_target_app "com.b"; chk_rc "已存在不落盘" 1 "$?"
after=$(sha256sum "$TARGET_FILE" | cut -d' ' -f1)
chk "文件逐字节未变" "$before" "$after"

echo "── 4 TEESim：数组定位不了时放弃 ──"
printf '{"profiles":{"default":{"mode":"keep"}}}' > "$T/nope.json"
TARGET_FILE="$T/nope.json"
before=$(sha256sum "$TARGET_FILE" | cut -d' ' -f1)
add_target_app "com.c"; chk_rc "定位失败返回 2" 2 "$?"
after=$(sha256sum "$TARGET_FILE" | cut -d' ' -f1)
chk "失败不改原文件" "$before" "$after"

if [ "$fail" = 0 ]; then echo "全部通过"; else echo "有断言失败"; fi
exit $fail
