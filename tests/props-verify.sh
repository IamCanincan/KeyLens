#!/system/bin/sh
#=============================================================================
# tests/props-verify.sh - 「写入并复核」的复核必须真跑过，不能把空读数当 0 项不符
#
# 修掉的故障：cmd_props_apply 原先无条件
#     out=$(sh webui.sh props); bad=$(printf … | grep -c diff|missing); kv applied 1
# 而那次重读**失败或输出被截断**时，grep -c 会规规矩矩给出 0 —— 界面于是收到
# applied 1 + mismatch 0，toast 写「已写入并复核」，而实际上一次复核都没跑成。
# 属性伪装是"看起来生效最重要"的那一类，假绿比红屏坏得多。
#
# 判据走 props_readback 这个缝：测试把它换成三种坏读数（空 / 行数不足 / 退码非 0），
# 每种都要求 applied 0 且命令退非 0。最后一条变异把守卫摘掉，证明这三条断言
# 不是空转（旧代码在同样三个场景下都会报 applied 1）。
#
# 跑法：sh tests/props-verify.sh
#=============================================================================
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0

chk() { if [ "$2" = 0 ]; then printf '  ok   %s\n' "$1"; else printf '  ✗    %s\n' "$1"; fail=1; fi; }

BODY=$(awk '/^cmd_props_apply\(\) \{/,/^\}/' module/lib/write.sh)
[ -n "$BODY" ]
chk '从 lib/write.sh 抽出 cmd_props_apply' $?
printf '%s' "$BODY" | grep -q 'out=$(props_readback)'
chk '复核走 props_readback 这个缝（测试才换得动）' $?
printf '%s' "$BODY" | grep -q 'want=$(props_expect_pairs | grep -c \.)'
chk '期望行数是算出来的，不是写死的数字' $?

# ── 环境桩：只桩到"这条命令能跑起来"，判据逻辑用真源 ──────────────────────
MODDIR=/nonexistent
require_runnable() { return 0; }
props_disabled() { return 1; }
apply_resetprop() { :; }
apply_boot_hash() { return 0; }
log_info() { :; }
log_warn() { :; }
kv() { printf '%s=%s\n' "$1" "$2"; }
resetprop() { return 0; }                 # 让 command -v resetprop 命中
props_expect_pairs() {
    printf 'ro.product.model Pixel\nro.build.type user\nro.boot.verifiedbootstate green\n'
}
props_expect_rules() { :; }

# 三行全一致的 props 输出（制表符分列，最后一列是状态）
good_readback() {
    printf 'ro.product.model\tPixel\tPixel\tok\n'
    printf 'ro.build.type\tuser\tuser\tok\n'
    printf 'ro.boot.verifiedbootstate\tgreen\tgreen\tok\n'
}
diff_readback() {
    printf 'ro.product.model\tPixel\tPixel\tok\n'
    printf 'ro.build.type\teng\tuser\tdiff\n'
    printf 'ro.boot.verifiedbootstate\t\tgreen\tmissing\n'
}
empty_readback() { :; }
short_readback() { printf 'ro.product.model\tPixel\tPixel\tok\n'; }
rc_readback() { good_readback; return 3; }

# ── 跑一次：返回 "退码|输出" ─────────────────────────────────────────────
run_apply() {
    eval "$BODY"
    out=$(cmd_props_apply 2>/dev/null); rc=$?
    printf '%s|%s|%s\n' "$rc" "$(printf '%s' "$out" | grep -m1 '^applied=' | cut -d= -f2)" \
        "$(printf '%s' "$out" | grep -m1 '^mismatch=' | cut -d= -f2)"
}
# expect <说明> <期望退码> <期望 applied> <函数体>
expect() {
    got=$(run_apply)
    want="$2|$3|"
    [ "${got%|*}" = "${want%|*}" ]
    chk "$1（期望 退码$2 applied=$3，实得 $got）" $?
}

printf '── 复核真跑过的两种情况 ──\n'
props_readback() { good_readback; }
expect '全一致 → applied 1 / mismatch 0' 0 1
props_readback() { diff_readback; }
expect '两行不符 → applied 1 / mismatch 2' 0 1

printf '── 复核没跑成的三种情况（这次修的就是它们）──\n'
props_readback() { empty_readback; }
expect '重读输出为空 → applied 0，不许报 mismatch 0' 1 0
props_readback() { short_readback; }
expect '重读只回 1/3 行 → applied 0' 1 0
props_readback() { rc_readback; }
expect '重读退码非 0 → applied 0' 1 0

printf '── 变异：把守卫摘掉（退回修之前那句无条件 applied 1）──\n'
work=$(mktemp -d 2>/dev/null || echo /tmp/klpv-$$); mkdir -p "$work"
printf '%s\n' "$BODY" > "$work/orig"
awk 'BEGIN{skip=0}
     skip==0 && /\[ "\$rc" != 0 \]/ { skip=1; next }
     skip==1 { if ($0 ~ /^    fi$/) skip=0; next }
     skip==0 { print }' "$work/orig" > "$work/mut"
if cmp -s "$work/orig" "$work/mut"; then
    echo '  ✗    变异没落地（与真源逐字节相同，这条不算证据）'; fail=1
else
    BODY=$(cat "$work/mut")
    props_readback() { empty_readback; }
    got=$(run_apply)
    case "$got" in
        0\|1\|0*) echo '  ok   变异「摘掉复核守卫」→ 空读数又变成 applied 1 / mismatch 0，被抓到' ;;
        *) printf '  ✗    变异后仍然报 applied 0（%s）—— 上面那三条断言是空转\n' "$got"; fail=1 ;;
    esac
fi
rm -rf "$work"

if [ "$fail" = 0 ]; then echo '全部通过'; else echo '有断言失败'; fi
exit "$fail"
