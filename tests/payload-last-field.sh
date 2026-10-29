#!/system/bin/sh
#=============================================================================
# tests/payload-last-field.sh - payload 的最后一个字段不能被静默丢掉
#
# 实测过的故障（修前）：界面 payload 是 join('\n') 拼的，没有尾换行；而
# `while IFS= read -r line` 在最后一行缺换行符时直接结束循环 —— 于是"改 N 个字段
# 只存进 N-1 个"，丢的正是最后一个，而且它连校验都没跑：
#   两个字段、第二个故意非法 → saved=1 fields=1，rc=0（静默通过）。
# 这类 bug 只在多字段保存时出现，单字段会直接报"没有字段"，所以以前没被撞到。
#
# 跑法：sh tests/payload-last-field.sh
#=============================================================================
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0

NL='
'
TAB=$(printf '\t')
CR=$(printf '\r')

# 抽真源，不抄一份：抄的那份怎么改都不会响
# parse_payload 依赖 find_base64，只抽它自己会在"缺少 base64 命令"那行早退，
# 四条断言全红 —— 那是仪器缺件，不是被测代码有问题。
bs=$(grep -n '^find_base64() {' module/lib/tools.sh | cut -d: -f1)
be=$(awk -v s="$bs" 'NR>s && /^\}/{ print NR; exit }' module/lib/tools.sh)
[ -n "$bs" ] && [ -n "$be" ] || { echo '  ✗    抽不到 find_base64'; exit 1; }
eval "$(sed -n "${bs},${be}p" module/lib/tools.sh)"
start=$(grep -n '^parse_payload() {' module/webui.sh | cut -d: -f1)
end=$(awk -v s="$start" 'NR>s && /^\}/{ print NR; exit }' module/webui.sh)
[ -n "$start" ] && [ -n "$end" ] || { echo '  ✗    抽不到 parse_payload'; exit 1; }
eval "$(sed -n "${start},${end}p" module/webui.sh)"
command -v parse_payload >/dev/null 2>&1 || { echo '  ✗    parse_payload 没定义'; exit 1; }
printf '  ok   从 webui.sh 抽出 parse_payload（第 %s–%s 行）\n' "$start" "$end"

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
work=$(mktemp -d 2>/dev/null || echo /tmp/tpl-$$); mkdir -p "$work"
out="$work/pairs"

# ① 无尾换行的两个字段：必须都解析出来
enc=$(printf 'a=%s\nb=%s' "$(b64 one)" "$(b64 two)" | base64 | tr -d '\n')
if parse_payload "$enc" "$out" >/dev/null 2>&1; then
    n=$(grep -c . "$out")
    got_b=$(printf '%s' "$TAB" | { IFS= read -r t; grep "^b${t}" "$out" | cut -f2; })
    [ "$n" = 2 ] && printf '  ok   两个字段（无尾换行）都解析到，b=%s\n' "$got_b" \
        || { printf '  ✗    只解析到 %s 个字段（最后一个被吞）\n' "$n"; fail=1; }
else
    echo '  ✗    两个字段（无尾换行）解析失败'; fail=1
fi

# ② 单字段无尾换行：旧代码在这里回"没有字段"
enc1=$(printf 'a=%s' "$(b64 solo)" | base64 | tr -d '\n')
if parse_payload "$enc1" "$out" >/dev/null 2>&1 && [ "$(cut -f2 "$out")" = solo ]; then
    printf '  ok   单字段（无尾换行）解析到：%s\n' "$(cut -f2 "$out")"
else
    echo '  ✗    单字段（无尾换行）没解析到'; fail=1
fi

# ③ 有尾换行时行为不变（别把修好变成修坏）
enc2=$(printf 'a=%s\nb=%s\n' "$(b64 x)" "$(b64 y)" | base64 | tr -d '\n')
parse_payload "$enc2" "$out" >/dev/null 2>&1 && [ "$(grep -c . "$out")" = 2 ] \
    && echo '  ok   带尾换行仍是 2 个字段（没有重复计数）' \
    || { echo '  ✗    带尾换行的路径被改坏了'; fail=1; }

# ④ 坏值必须走到校验而不是被吞掉：这是这次故障的正面教训
#    （fields 数对不上 = 有一个字段既没保存也没校验）
enc3=$(printf 'a=%s\nb=%s' "$(b64 ok)" "$(b64 '$(rm -rf)')" | base64 | tr -d '\n')
parse_payload "$enc3" "$out" >/dev/null 2>&1
[ "$(grep -c . "$out")" = 2 ] && echo '  ok   第二条含怪字符也进了 pairs（交给上层校验，不是静默丢）' \
    || { echo '  ✗    第二条被吞了'; fail=1; }

rm -rf "$work"
[ "$fail" = 0 ] && echo "全部通过" || echo "有断言失败"
exit $fail
