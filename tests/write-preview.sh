#!/bin/sh
#=============================================================================
# tests/write-preview.sh - 写前 diff 预览的闸门（CI 跑，不需要设备）
#
#   commit_backend_file 在 KL_PREVIEW=1 时：不落盘、不建 .bak、不调用
#   write_atomic_preserve，把「现文件 → 新文件」的行级差异攒进 $KL_PREVIEW_DIFF；
#   预览关闭时照常走原子写。webui.sh 侧另钉 preview 前缀白名单与信封三条 kv，
#   且 preview-* 不进 KL_COMMANDS 声明（分派表里没有它们的 arm，声明必须=实现）。
#=============================================================================
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/module/lib/core.sh"
. "$ROOT/module/lib/write.sh"
AWK_CMD="awk"

fail=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
WROTE=0
write_atomic_preserve() { WROTE=$((WROTE + 1)); cp -f "$2" "$1"; return 0; }

chk() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"; else printf '  ✗    %s\n        期望 [%s]，实得 [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
chk_has() { grep -q -- "$2" "$1" && printf '  ok   %s\n' "$3" || { printf '  ✗    %s\n' "$3"; fail=1; }; }
chk_no() { grep -q -- "$2" "$1" && { printf '  ✗    %s\n' "$3"; fail=1; } || printf '  ok   %s\n' "$3"; }

printf 'alpha=1\nbeta=keep\ngamma=old\n' > "$T/tgt"
printf 'alpha=2\nbeta=keep\ngamma=new\ndelta=add\n' > "$T/new"

echo "── 1 预览：不落盘、差异进 KL_PREVIEW_DIFF ──"
KL_PREVIEW=1
KL_PREVIEW_DIFF=""
WROTE=0
commit_backend_file "$T/tgt" "$T/new" "config.json.bak"; rc=$?
chk "返回 0" "0" "$rc"
printf 'alpha=1\nbeta=keep\ngamma=old\n' > "$T/exp"
cmp -s "$T/exp" "$T/tgt" && printf '  ok   目标文件逐字节不变\n' || { printf '  ✗    预览把文件写了\n'; fail=1; }
chk "没走原子写" "0" "$WROTE"
[ -f "$T/config.json.bak" ] && { printf '  ✗    预览不该建 .bak\n'; fail=1; } || printf '  ok   没建 .bak\n'
printf '%s' "$KL_PREVIEW_DIFF" > "$T/diff"
chk_has "$T/diff" "^- gamma=old" "旧行在差异里"
chk_has "$T/diff" "^+ gamma=new" "新行在差异里"
chk_has "$T/diff" "^+ delta=add" "新增行在差异里"
chk_no "$T/diff" "beta=keep" "未变的行不进差异"

echo "── 2 关预览：照常走原子写 ──"
KL_PREVIEW=0
KL_PREVIEW_DIFF=""
printf 'alpha=2\nbeta=keep\ngamma=new\ndelta=add\n' > "$T/new"
commit_backend_file "$T/tgt" "$T/new" "config.json.bak"; rc=$?
chk "返回 0" "0" "$rc"
chk "原子写被调用" "1" "$WROTE"
cmp -s "$T/new" "$T/tgt" && printf '  ok   目标已更新\n' || { printf '  ✗    目标没更新\n'; fail=1; }

echo "── 3 webui.sh：preview 前缀、信封、声明卫生 ──"
chk_has "$ROOT/module/webui.sh" "KL_PREVIEW=1" "分发里认 preview- 前缀"
chk_has "$ROOT/module/webui.sh" 'keybox-save " | grep -q' "白名单钉死在写命令上"
chk_has "$ROOT/module/webui.sh" "kv preview 1" "信封报 preview"
chk_has "$ROOT/module/webui.sh" "kv diff" "信封带 diff"
# 声明必须=实现：preview-* 在分派表里没有自己的 arm（走重定向），
# 所以不能进 KL_COMMANDS —— 否则 ui-shape 的「声明=实现」当场红。
for c in teesim-save teesim-save-overrides teesim-profile-new teesim-profile-del omk-save-injector omk-save-config tricky-save-patch tricky-drop-patch keybox-save; do
  chk_no "$ROOT/module/webui.sh" "preview-$c" "KL_COMMANDS 不含 preview-$c"
done

if [ "$fail" = 1 ]; then printf '有断言失败\n'; exit 1; fi
printf '全部通过\n'
