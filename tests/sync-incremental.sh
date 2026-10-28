#!/bin/sh
#=============================================================================
# tests/sync-incremental.sh - 名单同步的语义自检（CI 跑，不需要设备）
#
# 名单只有目标文件本身（没有常驻列表了）。测的是 module/lib/applist.sh 里真实的
# build_app_list（整份 source 进来，不抄一份），只把两个外部依赖桩掉：
# `cmd package`（给一份假的已装清单）和 current_target_apps（读目标文件）。
# 状态提交用 commit() 模拟 sync_* 写入成功。
#
# 焊住的语义：
#   1 首次安装（目标文件空 + 没有基线）：种入谷歌三件套 + 已装
#   2 首次运行但目标已有内容：不种种子，只做并集
#   3 新装的应用进名单
#   4 卸载的应用从名单里删掉
#   5 手工加进目标文件的条目保留（且下一轮还在）
#   6 手动从名单删掉的已装包：下一轮不加回来
#   7 手动删掉的包：卸载过再重装，会重新加入
#   8 手动删掉后又手动加回去：撤销墓碑
#   9 已装为空：只剩手工项
#  10 目标文件被清空：算你把它们都删了
#  11 种子只种一次：从名单里删掉三件套后不再回来
#  12 状态文件记的是「本轮的已装」与「写入清单」
#=============================================================================
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/module/lib/applist.sh"

fail=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
TAA_DIR="$T"
TARGET_FILE="$T/target.txt"
ST_INSTALLED="$T/.ts_installed_last"
ST_WRITTEN="$T/.ts_written_last"
ST_REMOVED="$T/.ts_removed"
ST_INSTALLED_NEW="$T/.ts_installed.new"
ST_WRITTEN_NEW="$T/.ts_written.new"
ST_REMOVED_NEW="$T/.ts_removed.new"

FAKE_INSTALLED=""
cmd() { printf '%s\n' "$FAKE_INSTALLED" | sed 's/^/package:/'; }
pm()  { cmd; }
current_target_apps() { [ -f "$TARGET_FILE" ] && sed '/^[[:space:]]*$/d' "$TARGET_FILE"; }

reset() {
    : > "$TARGET_FILE"
    rm -f "$ST_INSTALLED" "$ST_WRITTEN" "$ST_REMOVED"
    rm -f "$ST_INSTALLED_NEW" "$ST_WRITTEN_NEW" "$ST_REMOVED_NEW"
}
put() { f="$1"; shift; printf '%s\n' "$@" > "$f"; }
run() { build_app_list "$T/out"; }
commit() {
    cp -f "$T/out" "$TARGET_FILE"
    mv -f "$ST_INSTALLED_NEW" "$ST_INSTALLED" 2>/dev/null
    mv -f "$ST_WRITTEN_NEW" "$ST_WRITTEN" 2>/dev/null
    mv -f "$ST_REMOVED_NEW" "$ST_REMOVED" 2>/dev/null
}
chk() {
    got=$(sed '/^$/d' "$T/out" | sort | tr '\n' ' ' | sed 's/ $//')
    exp=$(printf '%s\n' "$2" | tr ' ' '\n' | sed '/^$/d' | sort | tr '\n' ' ' | sed 's/ $//')
    if [ "$got" = "$exp" ]; then printf '  ok   %s\n' "$1"
    else printf '  ✗    %s\n        期望: %s\n        实得: %s\n' "$1" "$exp" "$got"; fail=1; fi
}
chk_lines() {  # chk_lines <标签> <期望行数>
    got=$(sed '/^$/d' "$T/out" | wc -l | tr -d ' ')
    if [ "$got" = "$2" ]; then printf '  ok   %s（%s 行）
' "$1" "$got"
    else printf '  ✗    %s
        期望 %s 行，实得 %s 行
' "$1" "$2" "$got"; fail=1; fi
}

chk_tomb() {
    f="$ST_REMOVED_NEW"; [ -f "$f" ] || f="$ST_REMOVED"
    got=$([ -f "$f" ] && sed '/^$/d' "$f" | sort | tr '\n' ' ' | sed 's/ $//')
    exp=$(printf '%s\n' "$2" | tr ' ' '\n' | sed '/^$/d' | sort | tr '\n' ' ' | sed 's/ $//')
    if [ "$got" = "$exp" ]; then printf '  ok   %s\n' "$1"
    else printf '  ✗    %s\n        期望: [%s]\n        实得: [%s]\n' "$1" "$exp" "$got"; fail=1; fi
}
SEED="com.android.vending com.google.android.gms com.google.android.gsf"

echo "── 1 首次安装：目标空 + 没基线 → 种入三件套 + 已装 ──"
reset; FAKE_INSTALLED="a.inst"
run; chk "三件套 + 已装 都在" "$SEED a.inst"; chk_lines "一行一个包名" 4
chk_tomb "不产生墓碑" ""

echo "── 2 首次运行但目标已有内容：不种种子 ──"
reset; put "$TARGET_FILE" "x.keep"; FAKE_INSTALLED="a.inst"
run; chk "只并集，不掺三件套" "a.inst x.keep"

echo "── 3 新装的应用进名单 ──"
reset; put "$TARGET_FILE" "a.inst"; put "$ST_INSTALLED" "a.inst"; put "$ST_WRITTEN" "a.inst"
FAKE_INSTALLED="a.inst
d.new"
run; chk "d.new 被加进去" "a.inst d.new"

echo "── 4 卸载的应用从名单里删掉 ──"
reset; put "$TARGET_FILE" "a.inst
b.inst"; put "$ST_INSTALLED" "a.inst
b.inst"; put "$ST_WRITTEN" "a.inst
b.inst"
FAKE_INSTALLED="a.inst"
run; chk "b.inst 被删" "a.inst"; chk_tomb "卸载不算手动删除" ""

echo "── 5 手工加进目标文件的条目：保留，且下一轮还在 ──"
reset; put "$TARGET_FILE" "a.inst
e.manual"; put "$ST_INSTALLED" "a.inst"; put "$ST_WRITTEN" "a.inst"
FAKE_INSTALLED="a.inst"
run; chk "e.manual 保留" "a.inst e.manual"
commit; run; chk "下一轮仍然保留" "a.inst e.manual"

echo "── 6 手动从名单删掉一个已装的包：下一轮不会加回来 ──"
reset; put "$TARGET_FILE" "a.inst
b.inst"; put "$ST_INSTALLED" "a.inst
b.inst"; put "$ST_WRITTEN" "a.inst
b.inst"
FAKE_INSTALLED="a.inst
b.inst"
run; chk "基线" "a.inst b.inst"; commit
put "$TARGET_FILE" "a.inst"
run; chk "手动删掉后不加回来" "a.inst"; chk_tomb "b.inst 记进墓碑" "b.inst"; commit
run; chk "下一轮仍然不加回来" "a.inst"; chk_tomb "墓碑保持" "b.inst"

echo "── 7 手动删掉的包：卸载过再重装，会重新加入 ──"
FAKE_INSTALLED="a.inst"
run; chk "卸载时仍然不加回来" "a.inst"; chk_tomb "卸载后墓碑被清" ""; commit
FAKE_INSTALLED="a.inst
b.inst"
run; chk "重装后重新加入" "a.inst b.inst"

echo "── 8 手动删掉后又手动加回去：撤销墓碑 ──"
reset; put "$TARGET_FILE" "a.inst
b.inst"; put "$ST_INSTALLED" "a.inst
b.inst"; put "$ST_WRITTEN" "a.inst
b.inst"; put "$ST_REMOVED" "b.inst"
FAKE_INSTALLED="a.inst
b.inst"
run; chk "又有了就保留" "a.inst b.inst"; chk_tomb "墓碑被撤销" ""

echo "── 9 已装为空：只剩手工项 ──"
reset; put "$TARGET_FILE" "a.manual
b.inst"; put "$ST_INSTALLED" "b.inst"; put "$ST_WRITTEN" "a.manual
b.inst"
FAKE_INSTALLED=""
run; chk "b 被删（卸载），手工项留下" "a.manual"

echo "── 10 目标文件被清空：算你把它们都删了 ──"
reset; put "$TARGET_FILE" ""; put "$ST_INSTALLED" "a.inst"; put "$ST_WRITTEN" "a.inst"
FAKE_INSTALLED="a.inst"
run; chk "清空后确实为空" ""; chk_tomb "记进墓碑" "a.inst"

echo "── 11 种子只种一次：删掉三件套之后不再回来 ──"
reset; FAKE_INSTALLED="a.inst"
run; chk "首次种入" "$SEED a.inst"; commit
put "$TARGET_FILE" "a.inst"          # 手动把三件套从名单里删掉
run; chk "删掉后不加回来" "a.inst"; chk_tomb "三件套进了墓碑" "$SEED"; commit
run; chk "再跑一轮也不回来" "a.inst"

echo "── 12 状态文件记的是输入，不是最终列表 ──"
reset; put "$TARGET_FILE" "a.manual"; FAKE_INSTALLED="b.inst"
run
si=$(sed '/^$/d' "$ST_INSTALLED_NEW" | sort | tr '\n' ' ')
sw=$(sed '/^$/d' "$ST_WRITTEN_NEW" | sort | tr '\n' ' ')
[ "$si" = "b.inst " ] && printf '  ok   状态-已装 = b.inst\n' || { printf '  ✗   状态-已装 = %s\n' "$si"; fail=1; }
[ "$sw" = "a.manual b.inst " ] && printf '  ok   状态-写入清单 = 完整列表\n' || { printf '  ✗   状态-写入清单 = %s\n' "$sw"; fail=1; }
grep -qx "a.manual" "$ST_INSTALLED_NEW" && { printf '  ✗   手工项混进了「已装」状态\n'; fail=1; } \
    || printf '  ok   手工项没有混进「已装」状态\n'

if [ "$fail" = 0 ]; then echo "全部通过"; else echo "有断言失败"; fi
exit $fail
