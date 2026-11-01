#!/bin/sh
#=============================================================================
# tests/sh-syntax.sh - 每一个上机的 shell 文件都要能"被读完整"（CI，不需要设备）
#
# 抓的是什么：命令层拆成 webui.sh + lib/write.sh 之后，写实现只在真要写时才
#     source 进来。50bf9fb 那次把裸 awk 批量换成 ${AWK_CMD:-awk}，替换把行首的
#     "$(" 一起吃掉了两行 —— write.sh 当场不能解析，而：
#       · 界面侧的自检是"抽单个函数出来 eval"，坏行不在被抽的那段里就永远不响；
#       · 真机上每次写都会 sh: source error，只有装机后才看得见。
#     也就是说：整套 tests/*.sh 全绿 + 设备上的写路径全废，是可以同时成立的。
#     CI 里有 sh -n 那一步，但 CI 只在 push 时跑（本地攒了几百个提交没推），
#     所以这一步挪进 tests/*.sh：本地一条 `for t in tests/*.sh` 就带着它。
#
# 跑法：sh tests/sh-syntax.sh
#=============================================================================
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  ✗    %s\n' "$1"; fail=1; }

W=$(mktemp -d 2>/dev/null || echo "/tmp/klsyn-$$"); mkdir -p "$W"

# ── 清单从目录推，不手抄（手抄的那份会漏掉下一个新文件）────────────────
FILES="$W/files"
: > "$FILES"
for f in module/*.sh module/lib/*.sh module/backends/*.sh \
         module/META-INF/com/google/android/update-binary; do
    [ -f "$f" ] && printf '%s\n' "$f" >> "$FILES"
done
n=$(grep -c . "$FILES")
[ "$n" -ge 12 ] && ok "扫到 $n 个要过 sh -n 的机上文件（清单是 glob 推出来的）" \
    || bad "只扫到 $n 个（<12）—— glob 或路径写错了，这道闸现在数瞎"
grep -qx 'module/lib/write.sh' "$FILES" && ok 'lib/write.sh 在范围内（坏的就是它）' \
    || bad 'lib/write.sh 没进检查范围 —— 正是当初漏掉的那一个'
grep -qx 'module/webui.sh' "$FILES" && ok 'webui.sh 在范围内' || bad 'webui.sh 没进范围'

# ── 逐个 sh -n ────────────────────────────────────────────────────────
broken=""
while IFS= read -r f; do
    [ -n "$f" ] || continue
    if ! sh -n "$f" 2>"$W/err"; then
        broken="$broken $f"
        printf '       %s → %s\n' "$f" "$(tr '\n' ' ' < "$W/err")"
    fi
done < "$FILES"
if [ -z "$broken" ]; then
    ok "全部 $n 个文件语法通过"
else
    bad "语法错误：$broken"
fi

# ── 变异：把当年那个真实损坏原样种回一份副本，闸必须响 ──────────────────
# 原故障：`prof=$(awk …)` → `prof=${AWK_CMD:-awk} …)`（$ 被吞、行尾多一个 ) ）
sed 's|prof=$(\${AWK_CMD:-awk}|prof=${AWK_CMD:-awk}|' module/lib/write.sh > "$W/damaged"
before=$(grep -c 'prof=$(\${AWK_CMD:-awk}' module/lib/write.sh || true)
after=$(grep -c '^    prof=${AWK_CMD:-awk}' "$W/damaged" || true)
if [ "$before" = "1" ] && [ "$after" = "1" ] && ! cmp -s module/lib/write.sh "$W/damaged"; then
    ok "变异落地（真源那一句命中 $before 处、副本改成 $after 处，两文件确有差异）"
else
    bad "变异没落地（真源命中 $before，副本命中 $after）—— 下面那条通过不代表闸有牙"
fi
if sh -n "$W/damaged" 2>/dev/null; then
    bad '变异后的 write.sh 仍然"语法通过" —— 这道闸对这类损坏是瞎的'
else
    ok 'sh -n 抓得到变异后的 write.sh（就是当年那两行的形状）'
fi

# ── 变异 ②：写命令的实现文件根本没进包也要能被上面那条清单抓到 ──────────
# （build-zip 的必需文件清单已从代码推导，这里只保证 glob 本身不是空的）
libn=$(ls module/lib/*.sh 2>/dev/null | wc -l | tr -d ' ')
backn=$(ls module/backends/* 2>/dev/null | wc -l | tr -d ' ')
[ "$libn" -ge 5 ] && ok "lib/ 下 $libn 个 .sh 全在 glob 里" || bad "lib/ 只扫到 $libn 个 .sh（<5）"
[ "$backn" -ge 3 ] && ok "backends/ 下 $backn 个文件全在 glob 里" || bad "backends/ 只扫到 $backn 个（<3）"

rm -rf "$W"
[ "$fail" = 0 ] && echo '全部通过' || echo '有断言失败'
exit "$fail"
