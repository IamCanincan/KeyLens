#!/system/bin/sh
#=============================================================================
# tests/kv-writer.sh - 每行输出不许 fork 一次进程
#
# 实测过的账（真机 QV7709NLJ7，Android 的 mksh R59）：`type printf` 的答案是
# /system/bin/printf → **这个 shell 没有 printf 内置命令**，所以以前
#   kv() { printf '%s=%s\n' "$1" "$2"; }
# 每写一行就 fork+exec 一次：一行约 21ms，status 21 行、env 30 行、
# backend-info 23 行 —— 每条命令白付 400~600ms（
# "打开慢一拍"的大头就在这）。换成内置的 `print -r --`：21 行合计 <15ms，
# 实测 status 810→240ms、env(缓存命中) 733→301ms、backend-info 992→606ms，
# 且六条读命令的输出与旧写法逐行相同（backend-info 61 行一字不差）。
#
# 这条闸守三件事：① kv 的主路径必须是内置 print -r；② 必须留 printf 兜底并带运行时
# 探测（换 busybox/dash 时 print 可能不存在，那时宁可慢也不能不输出）；
# ③ backend_state 这类"每命令调用几次的小函数"不许用 $( ) 取值（一次子壳约 40ms）。
#
# 跑法：sh tests/kv-writer.sh
#=============================================================================
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0

chk() { # chk <说明> <真则 0/非0>
    if [ "$2" = 0 ]; then printf '  ok   %s\n' "$1"; else printf '  ✗    %s\n' "$1"; fail=1; fi
}

# 抽真源里的 kv 定义块（含 if/else/fi），不抄一份：抄的那份怎么改都不会响
# 注意：kv 与 tsv 用的是同一个"探测 + 兜底"形状，grep 会命中两处 —— 只取第一处，
# 否则 start 变成两行数字，sed 的范围就成了乱码（第一版就是这么自己瞎的）。
start=$(grep -n '^if print -r' module/webui.sh | head -1 | cut -d: -f1)
[ -n "$start" ] || start=$(grep -n '^kv() {' module/webui.sh | cut -d: -f1)
end=$(awk -v s="${start:-0}" 'NR>=s && /^fi$/ { print NR; exit }' module/webui.sh)
[ -n "$start" ] && [ -n "$end" ] || { echo '  ✗    抽不到 kv 的定义块'; exit 1; }
KV_BLOCK=$(sed -n "${start},${end}p" module/webui.sh)
printf '  ok   从 webui.sh 抽出 kv 定义块（第 %s–%s 行）\n' "$start" "$end"

# 判定函数：对任意一份 kv 定义块给出"是否既走内置、又留了兜底"
kv_ok() {
    printf '%s' "$1" | grep -q 'print -r -- "\$1=\$2"' || return 1
    printf '%s' "$1" | grep -q "printf '%s=%s\\\\n' \"\\\$1\" \"\\\$2\"" || return 1
    printf '%s' "$1" | grep -q '^if print -r' || return 1
    return 0
}

kv_ok "$KV_BLOCK"; chk 'kv 主路径是内置 print -r，且留了 printf 兜底与运行时探测' $?

# 变异 ①：把主路径改回纯 printf（就是这次修掉的那个形状）—— 必须让判定响
MUT1=$(printf '%s' "$KV_BLOCK" | sed 's/print -r -- "\$1=\$2"/printf "%s=%s\\n" "$1" "$2"/')
if [ "$MUT1" = "$KV_BLOCK" ]; then
    echo '  ✗    变异 ① 没落地（sed 没改动任何字节，这条断言等于没测）'; fail=1
elif kv_ok "$MUT1"; then
    echo '  ✗    变异 ①「kv 改回每行 printf」没被抓出来'; fail=1
else
    echo '  ok   变异 ①「kv 改回每行 printf」被点名'
fi

# 变异 ②：摘掉兜底分支（只留 print -r）—— 换 shell 时会静默不输出，必须响
MUT2=$(printf '%s' "$KV_BLOCK" | grep -v "printf '%s=%s")
if [ "$MUT2" = "$KV_BLOCK" ]; then
    echo '  ✗    变异 ② 没落地'; fail=1
elif kv_ok "$MUT2"; then
    echo '  ✗    变异 ②「摘掉 printf 兜底」没被抓出来'; fail=1
else
    echo '  ok   变异 ②「摘掉 printf 兜底」被点名'
fi

# ③ 小函数取值不许起子壳：backend_state 走全局，且全仓没有 $(backend_state …)
#    （计数式判据要能区分"真没有"和"抽不到所以没数"，所以先钉一处已知的直接调用）
grep -q 'BACKEND_STATE_VALUE=absent' module/webui.sh
chk 'backend_state 把结果放进全局 BACKEND_STATE_VALUE' $?
d=$(grep -c 'backend_state "\$TEESIM_MODULE"' module/webui.sh || true)
[ "$d" = 1 ]; chk "数得到 status 里那一处 backend_state 调用（命中 $d 处，要 1 处；0 处说明判据自己瞎了）" $?
n=$(grep -c '^[^#]*\$(backend_state' module/webui.sh || true)
[ "$n" = 0 ]; chk "status 里不再用 \$(backend_state …) 取值（命中 $n 处，要 0 处）" $?

# ④ 这条闸自己也要能被"整块删掉"叫醒：定义块里若没有 if 探测，说明有人把
#    两条分支合并成一条 —— 那正是最容易顺手做的"简化"
printf '%s' "$KV_BLOCK" | grep -q '^else$'
chk '探测失败时确实有一条 else 分支' $?

# ⑤ tsv 是同一形状，props 那两行不许退回每行 printf（一行约 13~21ms，一页三十多行）
t_start=$(grep -n '    tsv() {' module/webui.sh | head -1 | cut -d: -f1)
[ -n "$t_start" ]; chk 'tsv 有定义（与 kv 同一"探测 + 兜底"形状）' $?
printf '%s' "$(sed -n "${t_start:-1},$((t_start + 3))p" module/webui.sh)" | grep -q 'print -r -- "\$\*"'
chk 'tsv 的主路径也是内置 print -r' $?
p=$(grep -c "^[^#]*printf '%s\\\\t%s\\\\t%s\\\\t%s" module/webui.sh || true)
[ "$p" = 0 ]; chk "cmd_props 不再逐行 printf 拼 TSV（命中 $p 处，要 0 处）" $?

if [ "$fail" = 0 ]; then echo '全部通过'; else echo '有断言失败'; fi
exit "$fail"
