#!/system/bin/sh
#=============================================================================
# tests/env-cache.sh - env 的探针缓存：键要"只在真会变的东西变了"时失效
#
# 两次自我拆台都出在这块（都是同一天加的）：
#   ① 键里放了 module.prop 的 **mtime**，而每次同步都会 set_module_desc 重写
#      description 那一行（lib/backend.sh:616），mtime 跟着变 —— 缓存每同步一次
#      就作废一次，"命中 741ms"那种数只存在于两次同步之间。
#   ② 落盘那 19 行写成 19 个 printf，而这个 shell 里 printf 是外部命令
#      （/system/bin/printf，一次 fork 13~25ms）—— 冷路径上白付约 400ms。
# 这两条都是"优化写了等于没写"，所以判据要钉在源码形状上，光看运行时的数
# 是量不出"键选错了"的（键错了只是命中率低，单次照样快）。
#
# 跑法：sh tests/env-cache.sh
#=============================================================================
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0

chk() { if [ "$2" = 0 ]; then printf '  ok   %s\n' "$1"; else printf '  ✗    %s\n' "$1"; fail=1; fi; }

BODY=$(awk '/^cmd_env\(\) \{/,/^\}/' module/webui.sh)
[ -n "$BODY" ]
chk '从 webui.sh 抽出 cmd_env' $?

# ──  失效键 ──────────────────────────────────────────────────────────
printf '%s' "$BODY" | grep -q 'stat -c %Y "\$PROP_FILE"'
[ "$?" = 1 ]
chk '缓存键里不放 module.prop 的 mtime（每次同步都会重写它，放了等于每同步必失效）' $?
printf '%s' "$BODY" | grep -q 'mod_prop version'
chk '缓存键用 module.prop 的 version（只在刷机时变）' $?
printf '%s' "$BODY" | grep -q 'ckey="v1|\$MODDIR|'
chk '键里带 MODDIR（换模块目录不共用缓存）与 build.prop mtime（OTA 失效）' $?

# ──  落盘不许一行一次 fork ────────────────────────────────────────────
n=$(printf '%s\n' "$BODY" | grep -c "printf '[a-z_]*\\\\t" || true)
[ "$n" = 0 ]
chk "落盘块里没有逐行 printf（命中 $n 处，要 0 处）" $?
printf '%s' "$BODY" | grep -q 'print -r -- "\$cb"'
chk '整块攒成 $cb 后一次 print -r 交出去' $?
printf '%s' "$BODY" | grep -q "printf '%s\\\\n' \"\$cb\""
chk '没有 print 的 shell 有 printf 兜底（宁可用外部命令，不能不落盘）' $?

# ──  读回形状：写出去必须是 key<TAB>value，读回来用同一个分隔符 ────────
printf '%s' "$BODY" | grep -q 'IFS="\$TAB" read -r k v'
chk '读回用 IFS=$TAB read（与写出同一分隔符）' $?

# ── 变异：把键改回 mtime，必须让上面那条红 ─────────────────────────────
work=$(mktemp -d 2>/dev/null || echo /tmp/klec-$$); mkdir -p "$work"
printf '%s\n' "$BODY" > "$work/orig"
sed 's|mod_prop version||; s|${MOD_PROP_VALUE:-none}|$(stat -c %Y "$PROP_FILE" 2>/dev/null)|' \
    "$work/orig" > "$work/m1"
cmp -s "$work/orig" "$work/m1"
[ "$?" = 1 ]
chk '变异 ① 落地了（键被改回 mtime）' $?
if grep -q 'stat -c %Y "\$PROP_FILE"' "$work/m1"; then
    echo '  ok   变异 ①「键改回 module.prop mtime」被第一条判据抓到'
else
    echo '  ✗    变异 ① 没造出该被抓的形状，判据可能是空转'; fail=1
fi

# 变异：把一次 print 拆回逐行 printf
sed 's|print -r -- "\$cb"|printf '"'"'%s\\n'"'"' "$cb"|' "$work/orig" > "$work/m2"
cmp -s "$work/orig" "$work/m2"
[ "$?" = 1 ]
chk '变异 ② 落地了（一次 print 被换成 printf）' $?

# 变异：把攒块落盘改回"一行一次 printf"（就是修之前的形状）。
# 注入行用单引号 heredoc 写出来，别拿 awk/sed 的转义去拼 —— 那正是这台仪器
# 第一版坏掉的原因（变异没落地，断言却"通过"了）。
cat > "$work/inject" <<'EOF'
        printf 'resetprop\t%s\n' "$resetprop_v"
        printf 'awk\t%s\n' "$awk_v"
EOF
awk -v inj="$work/inject" '
    { print }
    /^        tmp="\$\{cache\}\.tmp\.\$\$/ && !done++ { while ((getline l < inj) > 0) print l }
' "$work/orig" > "$work/m3"
if cmp -s "$work/orig" "$work/m3"; then
    echo '  ✗    变异 ③ 没落地（注入没生效，这条不算证据）'; fail=1
else
    n3=$(grep -c "printf '[a-z_]*\\\\t" "$work/m3" || true)
    [ "$n3" = 2 ]
    chk "变异 ③「拆回逐行 printf」造出 $n3 处（要 2 处），正是计数判据要抓的形状" $?
fi
rm -rf "$work"

if [ "$fail" = 0 ]; then echo '全部通过'; else echo '有断言失败'; fi
exit "$fail"
