#!/bin/sh
#=============================================================================
# tests/sync-incremental.sh - 增量同步的语义自检（CI 跑，不需要设备）
#
# 测的是 module/lib/applist.sh 里那个真实的 build_app_list（整份 source 进来，
# 不抄一份），只把两个外部依赖桩掉：`cmd package`（给一份假的已装清单）和
# current_target_apps（读目标文件）。state 的提交用 commit() 模拟 sync_* 成功。
#
# 焊住的语义：
#   1 首次运行（没有上次状态）只做并集，不删任何东西
#   2 新装的应用进列表
#   3 卸载的应用从列表里删掉
#   4 卸载但仍在常驻列表里的，保留
#   5 人工加进目标文件的条目保留（且下一轮还在）
#   6 从常驻列表里删掉、且没装的，跟着删
#   7 **手动从名单里删掉的包，下一轮不会自动加回来**
#   8 手动删掉的包，若"卸载过再重装"则会重新加入（卸载时清墓碑）
#   9 手动删掉后又手动加回去的，撤销墓碑
#  10 状态文件写的是「本轮的已装/常驻/写入清单」，不是最终列表
#=============================================================================
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/module/lib/applist.sh"

fail=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
TAA_DIR="$T"
RULES_FILE="$T/rules.txt"
TARGET_FILE="$T/target.txt"
ST_INSTALLED="$T/.ts_installed_last"
ST_RULES="$T/.ts_rules_last"
ST_WRITTEN="$T/.ts_written_last"
ST_REMOVED="$T/.ts_removed"
ST_INSTALLED_NEW="$T/.ts_installed.new"
ST_RULES_NEW="$T/.ts_rules.new"
ST_WRITTEN_NEW="$T/.ts_written.new"
ST_REMOVED_NEW="$T/.ts_removed.new"

FAKE_INSTALLED=""
cmd() { printf '%s\n' "$FAKE_INSTALLED" | sed 's/^/package:/'; }
pm()  { cmd; }
current_target_apps() { [ -f "$TARGET_FILE" ] && sed '/^[[:space:]]*$/d' "$TARGET_FILE"; }

reset() {
    : > "$TARGET_FILE"; : > "$RULES_FILE"
    rm -f "$ST_INSTALLED" "$ST_RULES" "$ST_WRITTEN" "$ST_REMOVED"
    rm -f "$ST_INSTALLED_NEW" "$ST_RULES_NEW" "$ST_WRITTEN_NEW" "$ST_REMOVED_NEW"
}
put() { f="$1"; shift; printf '%s\n' "$@" > "$f"; }   # 写全部剩余参数，不是只有 $2
run() { build_app_list "$T/out"; }
# 模拟 sync_* 写入成功后的提交
commit() {
    cp -f "$T/out" "$TARGET_FILE"
    mv -f "$ST_INSTALLED_NEW" "$ST_INSTALLED" 2>/dev/null
    mv -f "$ST_RULES_NEW" "$ST_RULES" 2>/dev/null
    mv -f "$ST_WRITTEN_NEW" "$ST_WRITTEN" 2>/dev/null
    mv -f "$ST_REMOVED_NEW" "$ST_REMOVED" 2>/dev/null
}
chk() {   # chk <标签> <期望（空格分隔）>
    got=$(sed '/^$/d' "$T/out" | sort | tr '\n' ' ' | sed 's/ $//')
    exp=$(printf '%s\n' "$2" | tr ' ' '\n' | sed '/^$/d' | sort | tr '\n' ' ' | sed 's/ $//')
    if [ "$got" = "$exp" ]; then printf '  ok   %s\n' "$1"
    else printf '  ✗    %s\n        期望: %s\n        实得: %s\n' "$1" "$exp" "$got"; fail=1; fi
}
chk_tomb() {  # chk_tomb <标签> <期望的墓碑（空格分隔）>
    # 这一轮刚算出来的墓碑在 *.new 里；已经 commit 过就读已提交的那份
    f="$ST_REMOVED_NEW"; [ -f "$f" ] || f="$ST_REMOVED"
    got=$([ -f "$f" ] && sed '/^$/d' "$f" | sort | tr '\n' ' ' | sed 's/ $//')
    exp=$(printf '%s\n' "$2" | tr ' ' '\n' | sed '/^$/d' | sort | tr '\n' ' ' | sed 's/ $//')
    if [ "$got" = "$exp" ]; then printf '  ok   %s\n' "$1"
    else printf '  ✗    %s\n        期望: [%s]\n        实得: [%s]\n' "$1" "$exp" "$got"; fail=1; fi
}

echo "── 1 首次运行：只做并集，不删任何东西 ──"
reset; put "$TARGET_FILE" "a.manual"; FAKE_INSTALLED="b.inst"; put "$RULES_FILE" "# 注释" "c.rule"
run; chk "人工 + 已装 + 常驻 都在" "a.manual b.inst c.rule"; chk_tomb "不产生墓碑" ""

echo "── 2 新装的应用进列表 ──"
reset; put "$TARGET_FILE" "a.manual
b.inst
c.rule"; put "$RULES_FILE" "c.rule"
put "$ST_INSTALLED" "b.inst"; put "$ST_RULES" "c.rule"; put "$ST_WRITTEN" "a.manual
b.inst
c.rule"
FAKE_INSTALLED="b.inst
d.new"
run; chk "d.new 被加进去，其余不变" "a.manual b.inst c.rule d.new"

echo "── 3 卸载的应用从列表里删掉 ──"
reset; put "$TARGET_FILE" "a.manual
b.inst
c.rule
d.new"; put "$RULES_FILE" "c.rule"
put "$ST_INSTALLED" "b.inst
d.new"; put "$ST_RULES" "c.rule"; put "$ST_WRITTEN" "a.manual
b.inst
c.rule
d.new"
FAKE_INSTALLED="d.new"
run; chk "b.inst（已卸载）被删" "a.manual c.rule d.new"; chk_tomb "卸载不算手动删除，不留墓碑" ""

echo "── 4 卸载但仍在常驻里：保留 ──"
reset; put "$TARGET_FILE" "b.inst
c.rule"; put "$RULES_FILE" "b.inst
c.rule"
put "$ST_INSTALLED" "b.inst"; put "$ST_RULES" "b.inst
c.rule"; put "$ST_WRITTEN" "b.inst
c.rule"
FAKE_INSTALLED=""
run; chk "常驻条目不因卸载而消失" "b.inst c.rule"

echo "── 5 人工加进目标文件的条目：保留，且下一轮还在 ──"
reset; put "$TARGET_FILE" "a.manual
d.new
e.manual"; put "$RULES_FILE" ""
put "$ST_INSTALLED" "d.new"; put "$ST_RULES" ""; put "$ST_WRITTEN" "a.manual
d.new"
FAKE_INSTALLED="d.new"
run; chk "第一轮 e.manual 被保留" "a.manual d.new e.manual"
commit; run; chk "第二轮仍然保留" "a.manual d.new e.manual"

echo "── 6 从常驻里删掉、且没装的：跟着删 ──"
reset; put "$TARGET_FILE" "c.rule
d.new"; put "$RULES_FILE" ""
put "$ST_INSTALLED" "d.new"; put "$ST_RULES" "c.rule"; put "$ST_WRITTEN" "c.rule
d.new"
FAKE_INSTALLED="d.new"
run; chk "c.rule 被删（撤出常驻且未安装）" "d.new"

echo "── 7 手动从名单删掉一个已装的包：下一轮不会加回来 ──"
reset
put "$TARGET_FILE" "a.inst
b.inst"
put "$RULES_FILE" ""
put "$ST_INSTALLED" "a.inst
b.inst"; put "$ST_RULES" ""; put "$ST_WRITTEN" "a.inst
b.inst"
FAKE_INSTALLED="a.inst
b.inst"
run; chk "基线：两个都在" "a.inst b.inst"; commit
put "$TARGET_FILE" "a.inst"          # 用户手动删掉 b.inst
run; chk "手动删掉后不再加回来" "a.inst"; chk_tomb "b.inst 记进墓碑" "b.inst"; commit
run; chk "下一轮仍然不加回来" "a.inst"; chk_tomb "墓碑保持" "b.inst"

echo "── 8 手动删掉的包：卸载过再重装，会重新加入 ──"
FAKE_INSTALLED="a.inst"             # b 被卸载
run; chk "卸载时仍然不加回来" "a.inst"; chk_tomb "卸载后墓碑被清（为重装铺路）" ""; commit
FAKE_INSTALLED="a.inst
b.inst"                             # b 重新安装
run; chk "重装后重新加入" "a.inst b.inst"

echo "── 9 手动删掉后又手动加回去：撤销墓碑 ──"
reset
put "$TARGET_FILE" "a.inst
b.inst"; put "$RULES_FILE" ""
put "$ST_INSTALLED" "a.inst
b.inst"; put "$ST_RULES" ""; put "$ST_WRITTEN" "a.inst
b.inst"; put "$ST_REMOVED" "b.inst"
FAKE_INSTALLED="a.inst
b.inst"
run; chk "文件里又有了，就保留" "a.inst b.inst"; chk_tomb "墓碑被撤销" ""

echo "── 10 状态文件写的是「本轮的输入/写入清单」，不是别的 ──"
reset; put "$TARGET_FILE" "a.manual"; put "$RULES_FILE" "c.rule"; FAKE_INSTALLED="b.inst"
run
si=$(sed '/^$/d' "$ST_INSTALLED_NEW" | sort | tr '\n' ' ')
sr=$(sed '/^$/d' "$ST_RULES_NEW" | sort | tr '\n' ' ')
sw=$(sed '/^$/d' "$ST_WRITTEN_NEW" | sort | tr '\n' ' ')
[ "$si" = "b.inst " ] && printf '  ok   状态-已装 = b.inst\n' || { printf '  ✗   状态-已装 = %s\n' "$si"; fail=1; }
[ "$sr" = "c.rule " ] && printf '  ok   状态-常驻 = c.rule\n' || { printf '  ✗   状态-常驻 = %s\n' "$sr"; fail=1; }
[ "$sw" = "a.manual b.inst c.rule " ] && printf '  ok   状态-写入清单 = 完整列表\n' || { printf '  ✗   状态-写入清单 = %s\n' "$sw"; fail=1; }
grep -qx "a.manual" "$ST_INSTALLED_NEW" && { printf '  ✗   人工项混进了「已装」状态\n'; fail=1; } \
    || printf '  ok   人工项没有混进「已装」状态\n'

if [ "$fail" = 0 ]; then echo "全部通过"; else echo "有断言失败"; fi
exit $fail
