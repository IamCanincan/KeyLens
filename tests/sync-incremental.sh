#!/bin/sh
#=============================================================================
# tests/sync-incremental.sh - 名单同步的语义自检（CI 跑，不需要设备）
#
# 名单只有目标文件本身。build_app_list 整份 source 进来，只桩两个外部依赖：
# `cmd package`（假已装清单）与 current_target_apps（读目标文件）。
# 状态提交用 commit() 模拟 sync_* 写入成功。
#
# 快照差分模型：加入 = inst − was，删除 = was − inst，其余（cur）原样保留。
# 焊住的语义：
#   1 首次安装（目标空 + 无基线）：种三件套 + 全部已装
#   2 首次运行但目标已有内容：不种种子，已装照加
#   3 新装的应用进名单
#   4 卸载的应用从名单删掉
#   5 手工加的条目保留（且下一轮还在）
#   6 手动删掉的已装包：不加回来；excluded 认得出
#   7 卸载→重装：重新加入；卸载后 excluded 清空
#   8 手动加回去：保留（没有墓碑要撤销）
#   9 已装读空 + 有基线：自动同步放弃（防误清）；手动可强制
#  10 目标被清空：不回填；excluded 认得出
#  11 种子只种一次
#  12 状态只写「本轮已装」，不再产生墓碑/写入清单
#  13 旧版本遗留状态在成功同步后清掉
#  14 首次运行但目标非空：excluded 为空（基线之前的未纳入不算手动排除）
#  15 首次运行且已装为空：不触发「空列表保护」
#  16 OhMyKeymint 首次接入：沿用现有 scoop，不批量加入已装
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
ST_INSTALLED_NEW="$T/.ts_installed.new"
ST_EVER="$T/.ts_ever"
ST_EVER_NEW="$T/.ts_ever.new"

FAKE_INSTALLED=""
cmd() { printf '%s\n' "$FAKE_INSTALLED" | sed 's/^/package:/'; }
pm()  { cmd; }
current_target_apps() { [ -f "$TARGET_FILE" ] && sed '/^[[:space:]]*$/d' "$TARGET_FILE"; }

reset() {
    : > "$TARGET_FILE"
    rm -f "$ST_INSTALLED" "$ST_INSTALLED_NEW" "$ST_EVER" "$ST_EVER_NEW"
    rm -f "$TAA_DIR/.ts_written_last" "$TAA_DIR/.ts_written.new" \
          "$TAA_DIR/.ts_removed" "$TAA_DIR/.ts_removed.new"
}
put() { f="$1"; shift; printf '%s\n' "$@" > "$f"; }
run() { build_app_list "$T/out"; }
commit() {
    cp -f "$T/out" "$TARGET_FILE"
    mv -f "$ST_INSTALLED_NEW" "$ST_INSTALLED" 2>/dev/null
    mv -f "$ST_EVER_NEW" "$ST_EVER" 2>/dev/null
    drop_legacy_state
}
line_set() { printf '%s\n' "$2" | tr ' ' '\n' | sed '/^$/d' | sort | tr '\n' ' ' | sed 's/ $//'; }
chk() {
    got=$(sed '/^$/d' "$T/out" | sort | tr '\n' ' ' | sed 's/ $//')
    exp=$(line_set x "$2")
    if [ "$got" = "$exp" ]; then printf '  ok   %s\n' "$1"
    else printf '  ✗    %s\n        期望: %s\n        实得: %s\n' "$1" "$exp" "$got"; fail=1; fi
}
chk_lines() {  # chk_lines <标签> <期望行数>
    got=$(sed '/^$/d' "$T/out" | wc -l | tr -d ' ')
    if [ "$got" = "$2" ]; then printf '  ok   %s（%s 行）\n' "$1" "$got"
    else printf '  ✗    %s\n        期望 %s 行，实得 %s 行\n' "$1" "$2" "$got"; fail=1; fi
}
chk_excl() {  # chk_excl <标签> <期望的 excluded 集合>
    got=$(excluded_apps | sort | tr '\n' ' ' | sed 's/ $//')
    exp=$(line_set x "$2")
    if [ "$got" = "$exp" ]; then printf '  ok   %s\n' "$1"
    else printf '  ✗    %s\n        期望: [%s]\n        实得: [%s]\n' "$1" "$exp" "$got"; fail=1; fi
}
SEED="com.android.vending com.google.android.gms com.google.android.gsf"

echo "── 1 首次安装：目标空 + 没基线 → 种入三件套 + 已装 ──"
reset; FAKE_INSTALLED="a.inst"
run; chk "三件套 + 已装 都在" "$SEED a.inst"; chk_lines "一行一个包名" 4
chk_excl "没有可排除项" ""

echo "── 2 首次运行但目标已有内容：不种种子，已装照加 ──"
reset; put "$TARGET_FILE" "x.keep"; FAKE_INSTALLED="a.inst"
run; chk "已装加入，不掺三件套" "a.inst x.keep"

echo "── 3 新装的应用进名单 ──"
reset; put "$TARGET_FILE" "a.inst"; put "$ST_INSTALLED" "a.inst"
FAKE_INSTALLED="a.inst
d.new"
run; chk "d.new 被加进去" "a.inst d.new"

echo "── 4 卸载的应用从名单里删掉 ──"
reset; put "$TARGET_FILE" "a.inst
b.inst"; put "$ST_INSTALLED" "a.inst
b.inst"
FAKE_INSTALLED="a.inst"
run; chk "b.inst 被删" "a.inst"; chk_excl "卸载不算手动删除" ""

echo "── 5 手工加进目标文件的条目：保留，且下一轮还在 ──"
reset; put "$TARGET_FILE" "a.inst
e.manual"; put "$ST_INSTALLED" "a.inst"
FAKE_INSTALLED="a.inst"
run; chk "e.manual 保留" "a.inst e.manual"
commit; run; chk "下一轮仍然保留" "a.inst e.manual"

echo "── 6 手动从名单删掉一个已装的包：下一轮不会加回来 ──"
reset; put "$TARGET_FILE" "a.inst
b.inst"; put "$ST_INSTALLED" "a.inst
b.inst"; put "$ST_EVER" "a.inst
b.inst"
FAKE_INSTALLED="a.inst
b.inst"
run; chk "基线" "a.inst b.inst"; commit
put "$TARGET_FILE" "a.inst"
run; chk "手动删掉后不加回来" "a.inst"; chk_excl "b.inst 被认作手动排除" "b.inst"; commit
run; chk "下一轮仍然不加回来" "a.inst"; chk_excl "下一轮仍认得出" "b.inst"

echo "── 7 手动删掉的包：卸载过再重装，会重新加入 ──"
FAKE_INSTALLED="a.inst"
run; chk "卸载时仍然不加回来" "a.inst"; chk_excl "卸载后不再是排除项" ""; commit
FAKE_INSTALLED="a.inst
b.inst"
run; chk "重装后重新加入" "a.inst b.inst"; commit; chk_excl "重装后不再排除" ""

echo "── 8 手动删掉后又手动加回去：保留 ──"
reset; put "$TARGET_FILE" "a.inst
b.inst"; put "$ST_INSTALLED" "a.inst
b.inst"
FAKE_INSTALLED="a.inst
b.inst"
run; chk "又有了就保留" "a.inst b.inst"; chk_excl "不在排除里" ""

echo "── 9 已装读空 + 有基线：自动同步放弃，手动可强制 ──"
reset; put "$TARGET_FILE" "a.manual
b.inst"; put "$ST_INSTALLED" "b.inst"
FAKE_INSTALLED=""
run; rc=$?
if [ "$rc" = 1 ]; then printf '  ok   自动同步返回 1（放弃）\n'; else printf '  ✗   自动同步返回 %s，期望 1\n' "$rc"; fail=1; fi
[ ! -e "$T/out" ] && printf '  ok   没有生成待写列表\n' || { printf '  ✗   仍生成了待写列表\n'; fail=1; }
TAA_EMPTY_OK=1
run; unset TAA_EMPTY_OK
chk "手动强制后只剩手工项" "a.manual"

echo "── 10 目标文件被清空：算你把它们都删了 ──"
reset; put "$TARGET_FILE" ""; put "$ST_INSTALLED" "a.inst"; put "$ST_EVER" "a.inst"
FAKE_INSTALLED="a.inst"
run; chk "清空后确实为空" ""; chk_excl "a.inst 被认作手动排除" "a.inst"

echo "── 11 种子只种一次：删掉三件套之后不再回来 ──"
reset; FAKE_INSTALLED="a.inst"
run; chk "首次种入" "$SEED a.inst"; commit
put "$TARGET_FILE" "a.inst"          # 手动把三件套从名单里删掉
run; chk "删掉后不加回来" "a.inst"; chk_excl "三件套不是第三方已装，不进排除表" ""; commit
run; chk "再跑一轮也不回来" "a.inst"

echo "── 12 状态只写「本轮已装」 ──"
reset; put "$TARGET_FILE" "a.manual"; FAKE_INSTALLED="b.inst"
run
si=$(sed '/^$/d' "$ST_INSTALLED_NEW" | sort | tr '\n' ' ')
[ "$si" = "b.inst " ] && printf '  ok   状态-已装 = b.inst\n' || { printf '  ✗   状态-已装 = %s\n' "$si"; fail=1; }
grep -qx "a.manual" "$ST_INSTALLED_NEW" && { printf '  ✗   手工项混进了「已装」状态\n'; fail=1; } \
    || printf '  ok   手工项没有混进「已装」状态\n'
[ ! -f "$TAA_DIR/.ts_written.new" ] && [ ! -f "$TAA_DIR/.ts_removed.new" ] \
    && printf '  ok   不再产生写入清单/墓碑\n' \
    || { printf '  ✗   仍然产生了写入清单或墓碑\n'; fail=1; }

echo "── 13 旧版本遗留状态在成功同步后清掉 ──"
put "$TAA_DIR/.ts_written_last" "x"; put "$TAA_DIR/.ts_removed" "y"
put "$TARGET_FILE" "a.inst"; put "$ST_INSTALLED" "a.inst"; FAKE_INSTALLED="a.inst"
run; commit
if [ ! -f "$TAA_DIR/.ts_written_last" ] && [ ! -f "$TAA_DIR/.ts_removed" ]; then
    printf '  ok   墓碑与写入清单已清掉\n'
else
    printf '  ✗   旧状态文件还在\n'; fail=1
fi

echo "── 14 首次运行但目标非空：excluded 为空 ──"
reset; put "$TARGET_FILE" "x.keep"; FAKE_INSTALLED="a.inst"
run; chk_excl "基线之前的未纳入不算手动排除" ""

echo "── 15 首次运行且已装为空：不触发空列表保护 ──"
reset; put "$TARGET_FILE" "x.keep"; FAKE_INSTALLED=""
run; chk "手工项保留，不被保护拦下" "x.keep"

echo "── 16 OhMyKeymint 首次接入：沿用现有 scoop，不批量加入 ──"
reset; TAA_BACKEND=omk; put "$TARGET_FILE" "a.manual"; FAKE_INSTALLED="a.manual
b.inst"
run; chk "只保留现有条目" "a.manual"; chk_excl "从未纳入的不算排除" ""
commit; FAKE_INSTALLED="a.manual
b.inst
c.new"
run; chk "之后的新装照常加入" "a.manual c.new"
unset TAA_BACKEND

if [ "$fail" = 0 ]; then echo "全部通过"; else echo "有断言失败"; fi
exit $fail
