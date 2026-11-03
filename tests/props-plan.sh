#!/bin/sh
#=============================================================================
# tests/props-plan.sh - 属性判定的两张表 → 一份计划；awk 路与逐键回落路必须同值
#
# 这层为什么值得单独一个台子（三处都会静默坏，界面上看不出来）：
#
#  1) 判定既不能逐键读、也不能"dump 进变量再查表"，两条都上机量过：逐键 53 行要秒级
#     （单键 resetprop 读 32ms）；mksh 的字面匹配随字符串长度**平方级**增长
#     （66897 字节 ×15 键 = 160307ms；先裁到 2725 字节 ×53 键仍要 1841ms）。
#     所以现在一次 getprop + 一次 awk 出计划，shell 只负责落盘。
#  2) 特征表是**就地替换**，且同一个属性可以有多条规则（description 的尾巴既可能带
#     userdebug 也可能带 test-keys）。链式改必须"串完只落一次盘"，否则后一条会拿
#     写前的旧值覆盖前一条的成品。
#  3) "这台机压根没有的分区"要报 absent：不计入「写入并复核」的不符项，更不许凭空
#     写出来 —— 凭空多出的 `ro.system_dlkm.build.type` 本身就是破绽（stock 不会给
#     一个不存在的分区留属性）。
#
# 判据不许自证：真值是"一个键一个文件"的 db，写入落在另一份 store，断言直接读
# store。awk 路与回落路（AWK_CMD 指向不存在的 awk）各跑一遍比 store —— 回落不是摆设。
# 复核计数的契约（只认 diff/missing）用**真的** lib/write.sh 源码验，不在台子里
# 手抄那份 grep（抄错了这里就不会响，踩过）。
#
# 跑法：sh tests/props-plan.sh
#=============================================================================
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0
T=$(mktemp -d 2>/dev/null || echo /tmp/klpp-$$)
rm -rf "$T"; mkdir -p "$T/db" "$T/store" "$T/bin"

ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  ✗    %s\n' "$1"; fail=1; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 [$3]，实得 [$2]）"; fi; }
tab=$(printf '\t')

. module/lib/props.sh

{
    props_expect_pairs | while read -r n v; do [ -n "$n" ] && printf '%s\n' "$n"; done
    props_expect_rules | while read -r n _a _b; do [ -n "$n" ] && printf '%s\n' "$n"; done
} > "$T/table"
sort -u "$T/table" > "$T/table.u"
n_pairs=$(props_expect_pairs | grep -ac .)
n_rules=$(props_expect_rules | grep -ac .)

seed() { # 两条路各跑一次，起点必须一模一样
    rm -rf "$T/store" "$T/db"; mkdir -p "$T/store" "$T/db"
    while read -r k; do
        case "$k" in
            ro.secure) : ;;                                              # 不铺：属性压根不存在（固定表要凭空补出来）
            *dlkm*) : ;;                                                 # 不铺：这台机没这个分区 = absent 组
            ro.build.type) printf 'user' > "$T/db/$k" ;;                 # 已经对的（不许多写）
            ro.adb.secure) printf '1' > "$T/db/$k" ;;
            *) printf 'WRONG' > "$T/db/$k" ;;
        esac
    done < "$T/table.u"
    printf 'engineering-x' > "$T/db/ro.bootloader"
    printf 'lineage_pdx234-userdebug' > "$T/db/ro.build.flavor"
    printf 'XQ-DQ72-userdebug 17 userdebug-suffix test-keys' > "$T/db/ro.build.description"
    printf 'a/b/17/CP2A:userdebug/test-keys' > "$T/db/ro.build.fingerprint"
    printf 'c/d/17:1[user]x:userdebug/release-keys' > "$T/db/ro.system.build.fingerprint"
    printf 'e/f/15:user/release-keys' > "$T/db/ro.vendor.build.fingerprint"
    printf 'test-keys' > "$T/db/ro.system.build.tags"
    for p in bootimage odm product system_ext vendor; do printf 'userdebug' > "$T/db/ro.$p.build.type"; done
    # ro.system_dlkm.* / ro.vendor_dlkm.* 以及若干 tags/fingerprint 键故意不铺 = absent 组
}

# 桩：getprop 读 db∪store（store 优先 → 写完读得回）；resetprop 写 store、读同一条路
cat > "$T/bin/getprop" <<EOF
#!/bin/sh
# 桩里一次 \$(cat) 就是一个 fork；Git Bash 上 fork 贵到能把这个台子拖成"看着像挂住"
# （实测 20 秒都没跑完一段），所以逐行取值一律用内置的 read < 文件。
_v=
if [ \$# -eq 0 ]; then
    for f in "$T/db"/*; do
        [ -f "\$f" ] || continue
        k=\${f##*/}
        [ -f "$T/store/\$k" ] && continue
        _v=; read -r _v < "\$f"
        printf '[%s]: [%s]\n' "\$k" "\$_v"
    done
    for f in "$T/store"/*; do
        [ -f "\$f" ] || continue
        _v=; read -r _v < "\$f"
        printf '[%s]: [%s]\n' "\${f##*/}" "\$_v"
    done
    exit 0
fi
if [ -f "$T/store/\$1" ]; then _v=; read -r _v < "$T/store/\$1"; printf '%s\n' "\$_v"; exit 0; fi
if [ -f "$T/db/\$1" ]; then _v=; read -r _v < "$T/db/\$1"; printf '%s\n' "\$_v"; exit 0; fi
exit 0
EOF
cat > "$T/bin/resetprop" <<'EOF'
#!/bin/sh
if [ "$1" = "-n" ]; then
    # 正对照用的旋钮：让某一个键"写了但落不下去"，看复核计数会不会动。
    # 用 db 改值不行 —— 写盘在前、改值在后会被覆盖掉，那样这条对照恒不响。
    [ -n "${KL_SKIP:-}" ] && [ "$2" = "$KL_SKIP" ] && exit 0
    printf '%s' "$3" > "$KLSTORE/$2"; exit 0
fi
if [ "$1" = "--version" ]; then echo fake; exit 0; fi
_v=
[ -f "$KLSTORE/$1" ] && { read -r _v < "$KLSTORE/$1"; printf '%s\n' "$_v"; exit 0; }
[ -f "$KLDB/$1" ] && { read -r _v < "$KLDB/$1"; printf '%s\n' "$_v"; exit 0; }
exit 0
EOF
chmod +x "$T/bin/getprop" "$T/bin/resetprop"
PATH="$T/bin:$PATH"; export PATH KLSTORE="$T/store" KLDB="$T/db"

store_dump() {
    local f v
    ( cd "$T/store" 2>/dev/null && for f in *; do
        [ -f "$f" ] || continue
        v=; read -r v < "$f"
        printf '%s=[%s]\n' "$f" "$v"
      done ) 2>/dev/null
}

printf '── 表形状（决定 awk spec 流会不会错位）──\n'
badname=$({ props_expect_pairs; props_expect_rules; } | awk '{print $1}' | grep -av '^[-A-Za-z0-9_.:]*$' | tr '\n' ' ')
chk '属性名字符集合法（名字里不许有空白/制表符）' "$badname" ""
props_expect_pairs | awk '{print $1}' | sort -u > "$T/kp"
props_expect_rules | awk '{print $1}' | sort -u > "$T/kr"
chk '固定表自身没有重复行' "$(props_expect_pairs | awk '{print $1}' | sort | uniq -d)" ""
chk '特征表与固定表没有重名属性（重名=两处各写各的，谁赢说不清）' \
    "$(comm -12 "$T/kp" "$T/kr" | tr '\n' ' ')" ""
chk '表行数 = 界面行数 = 复核分母的来源' "$n_pairs/$n_rules" "18/38"

printf '── 判定：props_plan display 的四列与状态 ──\n'
seed
out=$(props_plan display 2>&1) || bad "props_plan 退非 0：$out"
chk '行数 = 固定表 + 特征表' "$(printf '%s\n' "$out" | grep -ac .)" "$((n_pairs + n_rules))"
chk '值里的 ] 与空格不被切错（只剥行尾那一个）' \
    "$(printf '%s\n' "$out" | grep -a "^ro.system.build.fingerprint$tab" | sed -n 1p | cut -d"$tab" -f2)" \
    'c/d/17:1[user]x:userdebug/release-keys'
chk '没有的分区报 absent（不报 missing）' \
    "$(printf '%s\n' "$out" | grep -a "^ro.system_dlkm.build.type$tab" | sed -n 1p | cut -d"$tab" -f4)" "absent"
chk '命中特征的行报 diff' \
    "$(printf '%s\n' "$out" | grep -a "^ro.build.description$tab" | sed -n 1p | cut -d"$tab" -f4)" "diff"
chk '固定表里缺失的键报 missing' \
    "$(printf '%s\n' "$out" | grep -a "^ro.secure$tab" | cut -d"$tab" -f4)" "missing"

printf '── 计划：props_plan write 的绝对判据 ──\n'
plan=$(props_plan write 2>&1) || bad "write 计划退非 0：$plan"
chk '链式改：ro.build.description 只出一条' \
    "$(printf '%s\n' "$plan" | grep -ac "^ro.build.description$tab")" "1"
chk '链式改 + 每一处都换：两条特征都清掉，其余原样' \
    "$(printf '%s\n' "$plan" | grep -a "^ro.build.description$tab" | cut -d"$tab" -f2)" \
    "XQ-DQ72-user 17 user-suffix release-keys"
chk '指纹里两处特征同时清' \
    "$(printf '%s\n' "$plan" | grep -a "^ro.build.fingerprint$tab" | cut -d"$tab" -f2)" \
    "a/b/17/CP2A:user/release-keys"
chk '值中间的 ] 不被吃掉' \
    "$(printf '%s\n' "$plan" | grep -a "^ro.system.build.fingerprint$tab" | cut -d"$tab" -f2)" \
    "c/d/17:1[user]x:user/release-keys"
chk '已符合的属性不进计划' "$(printf '%s\n' "$plan" | grep -ac "^ro.build.type$tab")" "0"
chk '固定表缺失的要补出来' \
    "$(printf '%s\n' "$plan" | grep -a "^ro.secure$tab" | cut -d"$tab" -f2)" "1"
chk 'absent 的分区一条都不进计划' "$(printf '%s\n' "$plan" | grep -ac dlkm)" "0"

printf '── 两条路落到同一个属性区：awk 路 vs 逐键回落路 ──\n'
seed; apply_resetprop
awk_store=$(store_dump)
[ -n "$awk_store" ] || bad 'awk 路一个字节都没写（桩没接上，后面那条"相同"是空转）'
chk 'awk 路：分区 type 改成 user' "$(cat "$T/store/ro.vendor.build.type")" "user"
chk 'awk 路：description 链式改完落盘' "$(cat "$T/store/ro.build.description")" "XQ-DQ72-user 17 user-suffix release-keys"
chk 'awk 路：没凭空写出 dlkm 键' "$(printf '%s\n' "$awk_store" | grep -ac dlkm)" "0"
seed
AWK_CMD="$T/bin/no-such-awk" apply_resetprop
fb_store=$(store_dump)
[ -n "$fb_store" ] || bad '回落路一个字节都没写（回落根本没跑）'
chk '回落路与 awk 路逐字节同值' "$fb_store" "$awk_store"

printf '── 复核计数的契约：只认 diff/missing，absent 不扣分 ──\n'
cat > "$T/apply.sh" <<EOF
. module/lib/core.sh
. module/lib/backend.sh
. module/lib/props.sh
kv() { printf '%s=%s\n' "\$1" "\$2"; }
log_info() { :; }
log_warn() { :; }
tsv() { local IFS='	'; printf '%s\n' "\$*"; }
prop_now() { PROP_NOW=\$(getprop "\$1" 2>/dev/null); [ -n "\$PROP_NOW" ] || PROP_NOW=""; }
props_readback() { sh "$T/webui-lite.sh" props 2>/dev/null; }
KL_PROPS_OFF="$T/props_off"
KL_BOOT_HASH="$T/boot_hash"
EOF
sed -n '/^require_runnable() {/,/^}/p' module/webui.sh >> "$T/apply.sh"
sed -n '/^cmd_props_apply() {/,/^}/p' module/lib/write.sh >> "$T/apply.sh"
cat > "$T/webui-lite.sh" <<'EOF'
. module/lib/props.sh
tsv() { local IFS='	'; printf '%s\n' "$*"; }
prop_now() { PROP_NOW=$(getprop "$1" 2>/dev/null); [ -n "$PROP_NOW" ] || PROP_NOW=""; }
EOF
sed -n '/^cmd_props() {/,/^}/p' module/webui.sh >> "$T/webui-lite.sh"
echo 'cmd_props' >> "$T/webui-lite.sh"
echo 'cmd_props_apply' >> "$T/apply.sh"
seed; apply_resetprop
out=$(sh "$T/apply.sh" 2>&1) || true
chk '复核跑成了（applied=1）' "$(printf '%s\n' "$out" | sed -n 's/^applied=//p')" "1"
chk 'absent 不扣分：mismatch=0' "$(printf '%s\n' "$out" | sed -n 's/^mismatch=//p')" "0"
# 计数表达式只点名 diff/missing —— 这条从真源里抽，不在台子里手抄一遍 grep
expr=$(sed -n '/bad=$(printf/p' module/lib/write.sh)
chk '抽到了 write.sh 里的计数表达式（锚点还在）' "$([ -n "$expr" ] && printf yes || printf no)" "yes"
chk '计数表达式点名 diff 与 missing' \
    "$(printf '%s' "$expr" | grep -qa diff && printf y; printf '%s' "$expr" | grep -qa missing && printf y)" "yy"
chk '计数表达式里没有 absent（有了就等于把"没这个分区"扣分）' \
    "$(printf '%s' "$expr" | grep -qa absent && printf yes)" ""
# 正对照：让某一项"写了但落不下去"（resetprop 桩的 KL_SKIP 旋钮），复核必须数到它。
# 不能靠改 db 值来做这条对照 —— apply 先把 db 修好，改值恒被覆盖，对照永远不响。
KL_SKIP=ro.debuggable; export KL_SKIP
seed
out2=$(sh "$T/apply.sh" 2>&1) || true
unset KL_SKIP
chk '正对照：真有一项落不下去时 mismatch 会动（不是恒 0 的死闸）' \
    "$(printf '%s\n' "$out2" | sed -n 's/^mismatch=//p' | awk '{print ($1 > 0) ? "yes" : "no"}')" "yes"

printf '── 变异三处 ──\n'
seed   # 变异要在"待改状态"上看；前面几轮已经落过盘，不重铺就看不见差别
W=$(mktemp -d 2>/dev/null || echo /tmp/klppm-$$); mkdir -p "$W"
sed -n '/^props_plan() {/,/^}$/p' module/lib/props.sh > "$W/plan.orig"
[ -s "$W/plan.orig" ] || bad '抽不到 props_plan（锚点改了？）'

sed -e 's#while ((i = index(v, needle)) > 0)#if ((i = index(v, needle)) > 0)#' "$W/plan.orig" > "$W/plan.mut"
if cmp -s "$W/plan.orig" "$W/plan.mut"; then
    bad '变异①没落地（与真源逐字节相同，不算证据）'
else
    eval "$(cat "$W/plan.mut")"
    chk '变异①"只换第一处"→ 第二处 userdebug 留在成品里（断言真的会响）' \
        "$(props_plan write 2>/dev/null | grep -a "^ro.build.description$tab" | cut -d"$tab" -f2)" \
        "XQ-DQ72-user 17 userdebug-suffix release-keys"
fi
. module/lib/props.sh

sed -e 's/st = "absent"/st = "missing"/' "$W/plan.orig" > "$W/plan2.mut"
if cmp -s "$W/plan.orig" "$W/plan2.mut"; then
    bad '变异②没落地（不算证据）'
else
    eval "$(cat "$W/plan2.mut")"
    chk '变异②absent 全塌成 missing（界面与计数的分水岭就这一个词）' \
        "$(props_plan display 2>/dev/null | grep -ac "${tab}absent$")" "0"
    chk '变异②写盘计划仍不凭空造 absent 分区（展示判据与写盘判据是两回事）' \
        "$(props_plan write 2>/dev/null | grep -ac dlkm)" "0"
fi
. module/lib/props.sh

sed -e 's/"ro.system.build.type userdebug user"/"ro.system.build.type userdbg user"/' \
    module/lib/props.sh > "$W/tbl.mut"
if cmp -s module/lib/props.sh "$W/tbl.mut"; then
    bad '变异③没落地（不算证据）'
else
    if ( . "$W/tbl.mut"; props_plan write 2>/dev/null | grep -qa "^ro.system.build.type$tab" ); then
        bad '变异③键名拼错后那条规则还在开火（说明计划根本没读这张表）'
    else
        ok '变异③键名拼错 → 那条规则熄火（计划确实逐条读表）'
    fi
fi

rm -rf "$W" "$T"
if [ "$fail" = 0 ]; then echo '全部通过'; else echo '有断言失败'; fi
exit "$fail"
