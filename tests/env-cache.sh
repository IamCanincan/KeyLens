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

# ── Rust 那半边 ────────────────────────────────────────────────────────
# 命令层现在默认走 bin/keylens，缓存由两个实现共用同一个文件。上面那些坑
# 一个都没过期：键选错在 Rust 侧同样只会表现为"命中率低"，量一次是量不出来的；
# 而两份实现各写各的键名，坏法是"互相把对方的缓存当空的"，跑起来只是慢，不报错。
echo "── Rust 侧（env_cmd）──"
RBODY=$(awk '/^pub fn env_cmd\(\) \{/,/^\}/' rust/src/read_cmds.rs)
[ -n "$RBODY" ]
chk '从 read_cmds.rs 抽出 env_cmd' $?
printf '%s' "$RBODY" | grep -q 'mod_prop(&Path::new(&moddir).join("module.prop"), "version")'
chk 'Rust 的键也用 module.prop 的 version' $?
printf '%s' "$RBODY" | grep -q 'mtime_secs(Path::new("/system/build.prop"))'
chk 'Rust 的键用 /system/build.prop 的 mtime 做 OTA 失效' $?
printf '%s' "$RBODY" | grep -q 'format!("v1|{}|{}|{}"'
chk 'Rust 的键带 v1 前缀与 moddir（三段拼法与 shell 同形）' $?
printf '%s' "$RBODY" | grep -q 'mtime_secs.*module\.prop'
[ "$?" = 1 ]
chk 'Rust 的键里也不放 module.prop 的 mtime（同一个坑不踩第二遍）' $?
nw=$(printf '%s\n' "$RBODY" | grep -c 'std::fs::write(' || true)
[ "$nw" = 1 ]
chk "Rust 落盘一次写完（std::fs::write 命中 $nw 处，要 1 处）" $?
printf '%s' "$RBODY" | grep -q 'std::fs::rename(&tmp, &cache)'
chk 'Rust 走临时文件 + 改名（读的一方不会看见半份缓存）' $?
printf '%s' "$RBODY" | grep -q 'from_mode(0o600)'
chk 'Rust 落盘收权限 600' $?
printf '%s' "$RBODY" | grep -q 'line.split_once('
chk 'Rust 读回按 TAB 切（与写出同一分隔符）' $?

# 键名清单：shell 与 Rust 必须逐个同序。这一条比的是**源码里的两份名单**，
# 对拍比的是运行时的输出 —— 名单漂了而输出没漂（两边一起漂）时，只有这条会响。
SK=$(printf '%s\n' "$BODY" | sed -n 's/^[[:space:]]*cb="v1[$]{TAB}.*/v1/p; s/^[[:space:]]*cb="[$]{cb}[$]{NL}\([a-z_0-9]*\)[$]{TAB}.*/\1/p' | tr '\n' ',' | sed 's/,$//')
RK=$(printf '%s\n' "$RBODY" | sed -n '/let rows: \[(&str, &str);/,/\];/p' | sed -n 's/^[[:space:]]*("\([a-z_0-9]*\)".*/\1/p' | tr '\n' ',' | sed 's/,$//')
nk=$(printf '%s' "$SK" | tr ',' '\n' | grep -c .)
[ "$nk" = 19 ]
chk "从 webui.sh 抽出落盘键名清单（$nk 个，要 19 个）" $?
[ "$(printf '%s' "$RK" | tr ',' '\n' | grep -c .)" = 19 ]
chk '从 read_cmds.rs 抽出 rows 键名清单（19 个）' $?
if [ "$SK" = "$RK" ]; then
    printf '  ok   两份名单逐个同序：%s\n' "$SK"
    list_ok=0
else
    printf '  ✗    名单不一致\n        shell=[%s]\n        rust =[%s]\n' "$SK" "$RK"
    list_ok=1
fi
chk '两份名单同序（shell 写的每个键 Rust 都读得到）' "$list_ok"
# 变异：把 Rust 名单里挑一个键改名，上面那条必须变红（不改则名单比对是空转）
MUT=$(printf '%s\n' "$RK" | sed 's/,base64_cmd,/,base64_cmd_mut,/')
[ "$MUT" != "$SK" ]
chk '变异 ④「改一个键名」确实会让名单比对变红' $?

if [ "$fail" = 0 ]; then echo '全部通过'; else echo '有断言失败'; fi
exit "$fail"
