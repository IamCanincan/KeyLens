#!/bin/sh
# device-props-mask：真机上把整张期望表**真的应用一次**，看属性区到底变成什么，跑完还原。
#
# 为什么必须上机：CI 与夹具机都只能证明"两侧算法一致"，证明不了
#   · 这台机的 `ro.system.build.type` 是不是真从 userdebug 变成了 user（正对照）；
#   · 表里那些"本机压根没有的分区"会不会被凭空写出来（absent → 破绽）；
#   · 设备上那个 awk（toybox）与 busybox awk 对同一段程序给出**一样**的结果吗
#     —— 本轮就是在 mawk 上撞到一个方言差（数组元素在赋值语句里被提前创建），
#     gawk 绿、mawk 红，而真机跑的正是非 gawk 那一族。
#
# 用法（手机上，A/B 树已按 §3 重建）：
#   adb shell "cd /data/adb/keylens-ab && MODDIR=/data/adb/keylens-ab sh tests_dir/device-props-mask.sh --write"
# 不加 --write 直接拒绝：这个台子会动运行期属性，哪怕跑完就还原。
#
# 不在真机上时整段 skip（不制造假绿灯）。
set -u
MODDIR=${MODDIR:-/data/adb/modules/keylens}
D=${KL_ABDIR:-/data/local/tmp}
BUSYBOX=${KL_BUSYBOX:-/data/adb/ksu/bin/busybox}

# 顺序要紧：先判"在不在真机上"（不在就 skip，CI 与本机都绿），再判 --write。
# 反过来写会让 tests/*.sh 的全跑在 CI 上恒红（踩过一次）。
[ -f "$MODDIR/lib/props.sh" ] || { echo "  skip 找不到 $MODDIR/lib/props.sh"; echo '全部通过'; exit 0; }
[ -x "$MODDIR/bin/keylens" ] || { echo "  skip 没有 $MODDIR/bin/keylens"; echo '全部通过'; exit 0; }
[ "$(id -u)" = "0" ] || { echo "  skip 需要 root（现在 uid=$(id -u)）"; echo '全部通过'; exit 0; }
if [ "${1:-}" != "--write" ]; then
    echo "  skip 这个台子会改运行期属性，要显式 --write 才跑（不制造假绿灯，也不算红）"
    echo '全部通过'
    exit 0
fi
command -v resetprop >/dev/null 2>&1 || command -v /data/adb/ksu/bin/resetprop >/dev/null 2>&1 || {
    echo "  ✗   设备上找不到 resetprop，属性伪装这一段测不了"; exit 1; }
export PATH="/system/bin:/system/xbin:/data/adb/magisk:/data/adb/ksu/bin:/data/adb/ap/bin:$PATH"

T="$D/kldpm-$$"
rm -rf "$T"; mkdir -p "$T" || exit 1

fail=0
tab=$(printf '\t')
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  ✗    %s\n' "$1"; fail=1; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 [$3]，实得 [$2]）"; fi; }

. "$MODDIR/lib/props.sh"
props_expect_pairs | while read -r n v; do [ -n "$n" ] && printf '%s\n' "$n"; done > "$T/kp"
props_expect_rules | while read -r n a b; do [ -n "$n" ] && printf '%s\n' "$n"; done > "$T/kr"
sort -u "$T/kp" "$T/kr" > "$T/keys"
nkeys=$(grep -ac . "$T/keys")

snap_keys() { getprop | sed -n 's/^\[\([^]]*\)\]: .*/\1/p' | LC_ALL=C sort; }
snap_vals() { while read -r k; do printf '%s=[%s]\n' "$k" "$(getprop "$k")"; done < "$T/keys"; }

# 逐行比两个快照，数出不同的行数。**不能用 diff**：这台机的 toybox diff 输出里没有
# `^>` 那种行（实测 changed 恒 0，正对照直接红），照抄 Linux 习惯的判据在设备上会瞎。
count_diff() { # <a> <b> → 不同行数
    awk 'NR==FNR { a[FNR] = $0; n = FNR; next } FNR <= n { if (a[FNR] != $0) c++ } END { print c + 0 }' "$1" "$2"
}
# 正对照：计数器必须能数出"改了一行"，否则上面那条判据是死的
printf 'x=[1]\ny=[2]\n' > "$T/c.a"
printf 'x=[1]\ny=[3]\n' > "$T/c.b"
if [ "$(count_diff "$T/c.a" "$T/c.b")" = "1" ] && [ "$(count_diff "$T/c.a" "$T/c.a")" = "0" ]; then
    ok '比对计数器自证（能数出 1，也能数出 0）'
else
    bad '比对计数器不可信（正对照没通过，后面的 changed 判据都不算证据）'
fi

snap_keys > "$T/keys.before"
snap_vals > "$T/vals.orig"        # 主人现场的原样：最终还原以它为准
cp "$T/vals.orig" "$T/vals.before"

# 无论走到哪一步炸了，现场先还原再说（这台机是主人的日常机）
restore_all() {
    # 用现成的读回式还原，不经过引号地狱：逐行读，值里有空格也照样传
    while IFS='=' read -r k v; do
        [ -n "$k" ] || continue
        v=${v#\[}; v=${v%]}
        cur=$(getprop "$k")
        [ "$cur" = "$v" ] || resetprop -n "$k" "$v" 2>/dev/null
    done < "$T/vals.orig"
    snap_vals > "$T/vals.after"
    if cmp -s "$T/vals.orig" "$T/vals.after"; then
        ok "现场已还原（$nkeys 个属性逐字节回到跑前）"
    else
        bad "还原后仍与跑前不同 —— 立即人工核对：$(diff "$T/vals.orig" "$T/vals.after" | head -4 | tr '\n' ' ')"
    fi
}
trap 'restore_all; rm -rf "$T"' EXIT

printf '── 表在真机上的形状（%s 个属性名）──\n' "$nkeys"
present=$(while read -r k; do [ -n "$(getprop "$k")" ] && printf '%s\n' "$k"; done < "$T/keys" | grep -ac .)
chk '本机存在的表内属性 > 0（一个都没有就是桩没接上）' \
    "$([ "$present" -gt 0 ] && printf yes || printf no)" "yes"
printf '  ·   本机存在 %s / 表内 %s 个（差的就是 absent 那一组）\n' "$present" "$nkeys"

printf '── 应用前：自己造出"待改状态"（不能指望现场正好在泄漏）──\n'
# 这台机很可能已经被上一次开机或上一次 --write 掩好了；那时臂 A 无从改变任何东西，
# "changed>0" 那条正对照就是空的 —— 报"没测到"是对的，但那样整台子就退化成只比两侧一致。
# 所以这里主动把几个特征塞回去，跑完 restore_all 会逐个退回 vals.before（含这几行）。
seed_leaks() {
    for p in bootimage odm product system system_dlkm system_ext vendor vendor_dlkm; do
        [ -n "$(getprop "ro.$p.build.type")" ] && resetprop -n "ro.$p.build.type" userdebug 2>/dev/null
    done
    [ -n "$(getprop ro.build.flavor)" ] && resetprop -n ro.build.flavor "$(getprop ro.build.flavor)-userdebug" 2>/dev/null
    fp=$(getprop ro.system.build.fingerprint)
    [ -n "$fp" ] && resetprop -n ro.system.build.fingerprint "$(printf '%s' "$fp" | sed 's/:user\//:userdebug\//')" 2>/dev/null
    [ -n "$(getprop ro.system.build.tags)" ] && resetprop -n ro.system.build.tags test-keys 2>/dev/null
}
seed_leaks
# 种完之后重新取"起点"：两臂必须从**同一个状态**出发（否则臂 A 从已种状态开始、
# 臂 B 从种之前开始，两臂末尾差的就是我自己种下去的那一行，不是实现差）
snap_vals > "$T/vals.before"
leak_before=$(getprop | grep -a -c userdebug)
leak_testkeys=$(getprop | grep -a -c test-keys)
printf '  ·   造完之后：含 userdebug 的行数 = %s，含 test-keys 的行数 = %s\n' "$leak_before" "$leak_testkeys"
if [ "$leak_before" -le 0 ] || [ "$leak_testkeys" -le 0 ]; then
    bad "造不出待改状态（userdebug=$leak_before test-keys=$leak_testkeys）—— 这台子的正对照不成立"
fi

printf '── 臂 A：shell + 设备 awk 走一遍 ──\n'
ta0=$(toybox date +%s%3N)
apply_resetprop
ta1=$(toybox date +%s%3N)
snap_vals > "$T/vals.A"
changed_A=$(count_diff "$T/vals.before" "$T/vals.A")
printf '  ·   臂 A 改写了 %s 个属性\n' "$changed_A"
chk '臂 A 真的改变了属性（changed>0，不是空转）' \
    "$([ "$changed_A" -gt 0 ] && printf yes || printf no)" "yes"
chk '分区 build.type 不再是 userdebug' \
    "$(getprop | grep -a -e '\.build\.type.*userdebug' | grep -ac .)" "0"
chk 'flavor 尾巴不再是 userdebug' \
    "$(getprop ro.build.flavor | grep -ac userdebug)" "0"
chk '系统分区指纹尾巴不再是 userdebug' \
    "$(getprop ro.system.build.fingerprint | grep -ac userdebug)" "0"
chk '分区 tags 里的 test-keys 被就地换成 release-keys（正对照）' \
    "$(getprop | grep -a -e '\.build\.tags.*test-keys' | grep -ac .)" "0"
chk '顶层 ro.build.type 仍是 user（没被顺手改坏）' "$(getprop ro.build.type)" "user"

printf '── 臂 B：bin/keylens 走同一张表 ──\n'
# 先把现场退回跑前，再让二进制跑（两臂必须同起点）
while IFS='=' read -r k v; do
    [ -n "$k" ] || continue
    v=${v#\[}; v=${v%]}
    [ "$(getprop "$k")" = "$v" ] || resetprop -n "$k" "$v" 2>/dev/null
done < "$T/vals.before"
tb0=$(toybox date +%s%3N)
KEYLENS_MODDIR="$MODDIR" "$MODDIR/bin/keylens" props-apply > "$T/rust.out" 2>&1
tb1=$(toybox date +%s%3N)
applied=$(sed -n 's/^applied=//p' "$T/rust.out")
mism=$(sed -n 's/^mismatch=//p' "$T/rust.out")
chk '二进制报 applied=1' "$applied" "1"
chk '二进制报 mismatch=0（absent 的分区不扣分）' "$mism" "0"
snap_vals > "$T/vals.B"
chk '两臂跑完之后，表内每一个属性逐字节相同' "$(count_diff "$T/vals.A" "$T/vals.B")" "0"

printf '── 不许凭空造出属性 ──\n'
snap_keys > "$T/keys.after"
newkeys=$(comm -13 "$T/keys.before" "$T/keys.after" | grep -ac .)
chk '属性区里没有新增键（凭空写出的分区属性本身就是破绽）' "$newkeys" "0"
if [ "$newkeys" != "0" ]; then
    printf '  ·   新增的键： %s\n' "$(comm -13 "$T/keys.before" "$T/keys.after" | tr '\n' ' ')"
fi

printf '── awk 方言对照（真机跑的正是非 gawk 那一族）──\n'
[ -x "$BUSYBOX" ] || bad "找不到 $BUSYBOX，跳过方言对照（这条只能证明设备 awk 自己）"
for mode in display write; do
    if [ -x "$BUSYBOX" ]; then
        AWK_CMD="awk" props_plan "$mode" > "$T/plan.$mode.toybox" 2>&1
        AWK_CMD="$BUSYBOX awk" props_plan "$mode" > "$T/plan.$mode.busybox" 2>&1
        if cmp -s "$T/plan.$mode.toybox" "$T/plan.$mode.busybox"; then
            ok "props_plan $mode：toybox awk 与 busybox awk 逐字节相同"
        else
            bad "props_plan $mode：两种 awk 结果不同 —— $(diff "$T/plan.$mode.toybox" "$T/plan.$mode.busybox" | head -3 | tr '\n' ' ')"
        fi
    fi
done
n_absc=$(props_plan display | grep -ac "${tab}absent$")
# 这台机 43 个表内属性全存在 ⇒ absent 本该是 0；判据写成恒等式，换台缺分区的机器
# 也一样成立，不会因为"这台演示不出 absent"而假红或假绿。
# absent 那一组本身在 tests/props-plan.sh（夹具里造出缺分区）与对拍里钉死。
chk 'absent 行数 = 本机不存在的表内属性数（恒等式，不靠运气）' \
    "$n_absc" "$((nkeys - present))"

printf '── 成本（同机、同一张表，awk 路 vs 逐键回落路）──\n'
i=0; bestawk=99999999; bestfb=99999999
while [ $i -lt 3 ]; do
    i=$((i+1))
    while IFS='=' read -r k v; do
        [ -n "$k" ] || continue
        v=${v#\[}; v=${v%]}
        [ "$(getprop "$k")" = "$v" ] || resetprop -n "$k" "$v" 2>/dev/null
    done < "$T/vals.before"
    s=$(toybox date +%s%3N); apply_resetprop; e=$(toybox date +%s%3N)
    d=$((e-s)); [ "$d" -lt "$bestawk" ] && bestawk=$d
    s=$(toybox date +%s%3N); AWK_CMD="$T/no-such-awk" apply_resetprop; e=$(toybox date +%s%3N)
    d=$((e-s)); [ "$d" -lt "$bestfb" ] && bestfb=$d
done
printf '  ·   回落（逐键 %s 行）= %sms；awk 路 = %sms；省 %sms\n' "$nkeys" "$bestfb" "$bestawk" "$((bestfb-bestawk))"
chk 'awk 路确实比逐键回落快（这张表的意义就在这）' \
    "$([ "$bestawk" -lt "$bestfb" ] && printf yes || printf no)" "yes"

if [ "$fail" = 0 ]; then echo '全部通过'; else echo '有断言失败'; fi
exit "$fail"
