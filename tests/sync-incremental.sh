#!/bin/sh
#=============================================================================
# tests/sync-incremental.sh - 增量同步的语义自检（CI 跑，不需要设备）
#
# 测的是 module/lib/applist.sh 里那个真实的 build_app_list（整份 source 进来，
# 不抄一份），只把两个外部依赖桩掉：`cmd package`（给一份假的已装清单）和
# current_target_apps（读目标文件）。
#
# 要焊住的六条语义：
#   1 首次运行（没有上次状态）只做并集，不删任何东西
#   2 新装的应用进列表
#   3 卸载的应用从列表里删掉
#   4 卸载但仍在常驻列表里的，保留
#   5 人工加进目标文件的条目保留（且下一轮还在）
#   6 从常驻列表里删掉、且没装的，跟着删
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
ST_INSTALLED_NEW="$T/.ts_installed.new"
ST_RULES_NEW="$T/.ts_rules.new"

FAKE_INSTALLED=""
cmd() { printf '%s\n' "$FAKE_INSTALLED" | sed 's/^/package:/'; }
pm()  { cmd; }
current_target_apps() { [ -f "$TARGET_FILE" ] && sed '/^[[:space:]]*$/d' "$TARGET_FILE"; }

# 每行一个包名 → 排序后一行输出，便于比较
reset() { : > "$TARGET_FILE"; : > "$RULES_FILE"; rm -f "$ST_INSTALLED" "$ST_RULES"; }
put() { f="$1"; shift; printf '%s\n' "$@" > "$f"; }   # 注意：要写全部剩余参数，不是只有 $2
run() { build_app_list "$T/out"; }

chk() {   # chk <标签> <期望（空格分隔，已排序）>
    got=$(sed '/^$/d' "$T/out" | sort | tr '\n' ' ' | sed 's/ $//')
    exp=$(printf '%s\n' "$2" | tr ' ' '\n' | sed '/^$/d' | sort | tr '\n' ' ' | sed 's/ $//')
    if [ "$got" = "$exp" ]; then
        printf '  ok   %s\n' "$1"
    else
        printf '  ✗    %s\n        期望: %s\n        实得: %s\n' "$1" "$exp" "$got"
        fail=1
    fi
}

echo "── 1 首次运行：只做并集，不删任何东西 ──"
reset
put "$TARGET_FILE" "a.manual"
FAKE_INSTALLED="b.inst"
put "$RULES_FILE" "# 注释" "c.rule"
run
chk "人工 + 已装 + 常驻 都在" "a.manual b.inst c.rule"

echo "── 2 新装的应用进列表 ──"
reset
put "$TARGET_FILE" "a.manual
b.inst
c.rule"
put "$RULES_FILE" "c.rule"
put "$ST_INSTALLED" "b.inst"
put "$ST_RULES" "c.rule"
FAKE_INSTALLED="b.inst
d.new"
run
chk "d.new 被加进去，其余不变" "a.manual b.inst c.rule d.new"

echo "── 3 卸载的应用从列表里删掉 ──"
reset
put "$TARGET_FILE" "a.manual
b.inst
c.rule
d.new"
put "$RULES_FILE" "c.rule"
put "$ST_INSTALLED" "b.inst
d.new"
put "$ST_RULES" "c.rule"
FAKE_INSTALLED="d.new"
run
chk "b.inst（已卸载）被删" "a.manual c.rule d.new"

echo "── 4 卸载但仍在常驻里：保留 ──"
reset
put "$TARGET_FILE" "b.inst
c.rule"
put "$RULES_FILE" "b.inst
c.rule"
put "$ST_INSTALLED" "b.inst"
put "$ST_RULES" "b.inst
c.rule"
FAKE_INSTALLED=""
run
chk "常驻条目不因卸载而消失" "b.inst c.rule"

echo "── 5 人工加进目标文件的条目：保留，且下一轮还在 ──"
reset
put "$TARGET_FILE" "a.manual
d.new
e.manual"
put "$RULES_FILE" ""
put "$ST_INSTALLED" "d.new"
put "$ST_RULES" ""
FAKE_INSTALLED="d.new"
run
chk "第一轮 e.manual 被保留" "a.manual d.new e.manual"
# 把这一轮的结果与状态当成下一轮的输入，确认人工项不会在第二轮被吃掉
cp -f "$T/out" "$TARGET_FILE"
mv -f "$ST_INSTALLED_NEW" "$ST_INSTALLED"
mv -f "$ST_RULES_NEW" "$ST_RULES"
run
chk "第二轮仍然保留" "a.manual d.new e.manual"

echo "── 6 从常驻里删掉、且没装的：跟着删 ──"
reset
put "$TARGET_FILE" "c.rule
d.new"
put "$RULES_FILE" ""
put "$ST_INSTALLED" "d.new"
put "$ST_RULES" "c.rule"
FAKE_INSTALLED="d.new"
run
chk "c.rule 被删（撤出常驻且未安装）" "d.new"

echo "── 状态文件写的是「本轮的已装/常驻」，不是最终列表 ──"
reset
put "$TARGET_FILE" "a.manual"
put "$RULES_FILE" "c.rule"
FAKE_INSTALLED="b.inst"
run
si=$(sed '/^$/d' "$ST_INSTALLED_NEW" | sort | tr '\n' ' ')
sr=$(sed '/^$/d' "$ST_RULES_NEW" | sort | tr '\n' ' ')
[ "$si" = "b.inst " ] && printf '  ok   状态-已装 = b.inst\n' || { printf '  ✗   状态-已装 = %s\n' "$si"; fail=1; }
[ "$sr" = "c.rule " ] && printf '  ok   状态-常驻 = c.rule\n' || { printf '  ✗   状态-常驻 = %s\n' "$sr"; fail=1; }
grep -qx "a.manual" "$ST_INSTALLED_NEW" && { printf '  ✗   人工项混进了「已装」状态（下一轮会被当成卸载删掉）\n'; fail=1; } \
    || printf '  ok   人工项没有混进「已装」状态\n'

if [ "$fail" = 0 ]; then echo "全部通过"; else echo "有断言失败"; fi
exit $fail
