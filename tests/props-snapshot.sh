#!/bin/sh
#=============================================================================
# tests/props-snapshot.sh - 属性快照的两层实现：裁得对 + 切得对
#
# 为什么值得单独一个台子：apply_resetprop 与界面 props 页的"当前值"以前逐键取
# （真机现量：单键 getprop 15.7ms、单键 resetprop 读 32ms），期望表要补到几十行，
# 判定就只能改成"取一次快照后在 shell 内部查表"。而这条路上有两处会静默出错：
#
#   1) 准备层：真机现量，mksh 对 66897 字节的整份 dump 做一次 *"[key]: "* 匹配
#      就要十秒级（15 键实测 160307ms）。所以快照先用 grep -F 按表里的键名裁一刀
#      （66KB → 429 字节，之后 15 次查表 34ms）。**裁错/忘了裁**分别会让界面读不到
#      属性、或把开机时间变成几分钟，而两者都不会让功能测试报错。
#   2) 解析层：dump 行格式是 `[键]: [值]`，而值里可以有 ] 、[ 、空格、中文，也可以
#      为空。切错一个字符，判定就会把"vendor 分区是 userdebug"读成"不存在"，
#      于是要么漏写、要么凭空造出 stock 没有的键 —— 界面上看着一切正常。
#
# 判据不许自证：真源是"每个键一个文件"的 db。解析层把 db 拼成的整份 dump 直接装进
# KL_PROP_DUMP（绕开准备层），逐键与 db 比；准备层单独钉"行数=表里不同键数"，
# 这样"忘了 grep"会当场红，而不是等到真机开机才发现。
#
# 跑法：sh tests/props-snapshot.sh
#=============================================================================
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0
T=$(mktemp -d 2>/dev/null || echo /tmp/klps-$$)
rm -rf "$T"; mkdir -p "$T/db" "$T/bin"

ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  ✗    %s\n' "$1"; fail=1; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 [$3]，实得 [$2]）"; fi; }

# ── 真源：db 一个键一个文件；这些手写值故意踩满坑 ──────────────────────────
mkval() { printf '%s' "$2" > "$T/db/$1"; }
mkval ro.build.type                 user
mkval ro.build.type.extra           should-not-leak        # 与上一行同前缀，靠 ]: 锚才分得开
mkval ro.keylens.note               '含中文与 ] 和 [ 的值'  # 不在表里：准备层必须把它裁掉
mkval ro.odm.build.tags             'release-keys]extra'   # 值里有 ]：只许剥行尾那一个
mkval ro.product.build.fingerprint  '[Sony/XQ-DQ72'        # 值以 [ 开头
mkval ro.boot.veritymode            ''                     # 空值：dump 里是 `[]`
mkval ro.vendor.build.type          'user debug'           # 值里有空格

# ── 桩 getprop：无参数=全量 dump；带参数=单键读（另一条代码路）────────────
cat > "$T/bin/getprop" <<'EOF'
#!/bin/sh
db="${KL_DB:?}"
if [ $# -eq 0 ]; then
    for f in "$db"/*; do
        [ -f "$f" ] || continue
        printf '[%s]: [%s]\n' "${f##*/}" "$(cat "$f")"
    done
    exit 0
fi
[ -f "$db/$1" ] && cat "$db/$1"
exit 0
EOF
chmod +x "$T/bin/getprop"
PATH="$T/bin:$PATH"; export PATH KL_DB="$T/db"

. module/lib/props.sh

# ── 期望表每一行都要有样本：没手写的就现造一个含 ] 的值 ────────────────────
{
    props_expect_pairs | while read -r name _v; do [ -n "$name" ] && printf '%s\n' "$name"; done
    props_expect_rules | while read -r name _n _r; do [ -n "$name" ] && printf '%s\n' "$name"; done
} > "$T/table"
auto=0
while read -r k; do
    [ -f "$T/db/$k" ] && continue
    mkval "$k" "auto-]$k"          # 故意带 ]：漏剥行尾的实现在这里必红
    auto=$((auto + 1))
done < "$T/table"
total=$(grep -c . "$T/table")

printf '── 解析层：逐键必须等于 db 的真值（先把整份 dump 直接装进快照）──\n'
KL_PROP_DUMP="$KL_NL$(getprop)"
n=0
while read -r k; do
    props_dump_get "$k"
    want=$(cat "$T/db/$k")
    if [ "$PROP_NOW" = "$want" ]; then n=$((n + 1)); else bad "$k（期望 [$want]，实得 [$PROP_NOW]）"; fi
done < "$T/table"
chk '表里每一行都逐键相等' "$n/$total" "$total/$total"
[ "$auto" -gt 0 ] && ok "其中 $auto 行走的是含 ] 的现造样本（正对照在场）" || bad '一条现造样本都没有，说明表是空的'
for k in ro.vendor.build.type ro.product.build.fingerprint ro.odm.build.tags ro.keylens.note; do
    props_dump_get "$k"; chk "坑值样本 $k" "$PROP_NOW" "$(cat "$T/db/$k")"
done
chk '空值键读成空（不是把 ] 当值）' "$(props_dump_get ro.boot.veritymode; printf '%s' "$PROP_NOW")" ""
chk '不存在的键 → 空' "$(props_dump_get ro.not.a.key; printf '%s' "$PROP_NOW")" ""
props_dump_get ro.not.a.key; chk '不存在的键 → 仍算查过（退 0，不许触发回落）' "$?" "0"
props_dump_get ro.build.type; chk '同前缀兄弟不污染（ro.build.type 仍是 user）' "$PROP_NOW" "user"

printf '── 准备层：必须按表裁过（行数=表里不同键数），且裁完还读得对 ──\n'
KL_PROP_DUMP=""
props_dump_prepare || bad 'props_dump_prepare 失败'
distinct=$(sort -u "$T/table" | grep -c .)
lines=$(printf '%s\n' "$KL_PROP_DUMP" | grep -ac "^\[")
chk "快照只留表里的键（$lines 行 vs 表 $distinct 个不同键）" "$lines" "$distinct"
printf '%s\n' "$KL_PROP_DUMP" | grep -qa "\[ro.keylens.note\]" && bad '不在表里的键没被裁掉（grep 那一刀没起作用）'
n2=0
while read -r k; do
    props_dump_get "$k"
    want=$(cat "$T/db/$k")
    [ "$PROP_NOW" = "$want" ] && n2=$((n2 + 1)) || bad "裁后 $k（期望 [$want]，实得 [$PROP_NOW]）"
done < "$T/table"
chk '裁过的快照逐键仍等于 db' "$n2/$total" "$total/$total"

printf '── 回落层：getprop 或 grep 拿不到东西时要报"不可用" ──\n'
(
    getprop() { :; }                       # 全量输出为空
    props_dump_prepare
    [ "$?" = 1 ] || { echo BAD_PREP; exit 1; }
    [ -z "$KL_PROP_DUMP" ] || { echo BAD_CLEAR; exit 1; }
    props_dump_get ro.build.type && { echo BAD_GET; exit 1; }
    exit 0
) > "$T/fb.out" 2>&1
chk '空输出 → 退 1、清空快照、props_dump_get 拒绝作答' "$(tr '\n' ' ' < "$T/fb.out")" ""
(
    grep() { :; }                          # grep 那条路断了（裁剪拿不到东西）
    props_dump_prepare
    [ "$?" = 1 ] || { echo BAD_GREP; exit 1; }
    exit 0
) > "$T/fb2.out" 2>&1
chk 'grep 失效 → 同样退 1（不许带着空快照继续）' "$(tr '\n' ' ' < "$T/fb2.out")" ""

printf '── 变异两处：解析少剥一个 ]、准备忘了裁 ──\n'
mut_work=$(mktemp -d 2>/dev/null || echo /tmp/klpsm-$$); mkdir -p "$mut_work"
sed -n '/^props_dump_get() {/,/^}$/p' module/lib/props.sh > "$mut_work/get.orig"
sed -n '/^props_dump_prepare() {/,/^}$/p' module/lib/props.sh > "$mut_work/prep.orig"
[ -s "$mut_work/get.orig" ] || bad '抽不到 props_dump_get（锚点改了？）'
[ -s "$mut_work/prep.orig" ] || bad '抽不到 props_dump_prepare（锚点改了？）'

sed -e 's/PROP_NOW=${rest%\]}/PROP_NOW=$rest/' "$mut_work/get.orig" > "$mut_work/get.mut"
if cmp -s "$mut_work/get.orig" "$mut_work/get.mut"; then
    bad '变异①没落地（与真源逐字节相同，这条不算证据）'
else
    KL_PROP_DUMP="$KL_NL$(getprop)"
    eval "$(cat "$mut_work/get.mut")"
    props_dump_get ro.odm.build.tags
    chk '变异①解析少剥一个 ] → 值带尾巴（断言真的会响）' "$PROP_NOW" 'release-keys]extra]'
    h=0
    while read -r k; do
        [ "$k" = ro.boot.veritymode ] && continue      # 空值行本来就切不出差异
        props_dump_get "$k"; [ "$PROP_NOW" = "$(cat "$T/db/$k")" ] || h=$((h + 1))
    done < "$T/table"
    [ "$h" -gt 5 ] && ok "变异①波及表里 $h 行（不是只打中一条手写样本）" || bad "变异①只打中 $h 行，台子偏薄"
fi

sed -e 's/| grep -aF "\$@" 2>\/dev\/null/| cat/' "$mut_work/prep.orig" > "$mut_work/prep.mut"
if cmp -s "$mut_work/prep.orig" "$mut_work/prep.mut"; then
    bad '变异②没落地（grep 那一刀改不掉，这条不算证据）'
else
    KL_PROP_DUMP=""
    eval "$(cat "$mut_work/prep.mut")"
    props_dump_prepare || bad '变异②准备层失败'
    L=$(printf '%s\n' "$KL_PROP_DUMP" | grep -ac "^\[")
    [ "$L" -gt "$distinct" ] && ok "变异②忘了裁 → 快照行数 $L > 表键数 $distinct，被抓到" || bad "变异②没让行数变多（$L），这条断言是空转"
fi
rm -rf "$mut_work" "$T"

if [ "$fail" = 0 ]; then echo '全部通过'; else echo '有断言失败'; fi
exit "$fail"
