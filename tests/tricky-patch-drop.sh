#!/system/bin/sh
#=============================================================================
# tests/tricky-patch-drop.sh - 删除 security_patch.txt 里的 [包名] 段（-v drop=）
#
# 这段写回直接动用户线上文件，判据只有一条：**只有目标段消失，其余字节不动**。
# 所以每个用例都配一个阴性对照（缺失 / 要删全局 / 名字只是别人的前缀），
# 阴性必须"整份文件逐字节不变" —— 否则一次误删就是整套补丁静默失效。
# 正向用例里还钉了边界：紧邻**下一段**的空行与说明注释必须留下，紧贴本段段头
# 的说明注释则随段一起删（第一次实现把 "# b 段" 连同 [bbb] 的说明吃掉了）。
#
# 跑法：sh tests/tricky-patch-drop.sh
#=============================================================================
set -u
cd "$(dirname "$0")/.." || exit 1
AWK=${AWK:-awk}
fail=0
dir=$(mktemp -d 2>/dev/null || echo /tmp/tpd-$$); mkdir -p "$dir"
chk() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"; else printf '  ✗    %s：期望 [%s] 实得 [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
has() { if grep -q -- "$2" "$1"; then printf '  ok   %s\n' "$3"; else printf '  ✗    %s\n' "$3"; fail=1; fi; }
hasnt() { if grep -q -- "$2" "$1"; then printf '  ✗    %s\n' "$3"; fail=1; else printf '  ok   %s\n' "$3"; fi; }
blanks() { grep -c '^$' "$1"; }
cmp0() { cmp -s "$dir/base.txt" "$dir/out.txt" && printf '  ok   文件逐字节未动\n' || { printf '  ✗    文件被改了\n'; fail=1; }; }

cat > "$dir/base.txt" <<'EOF'
# 全局段
system = 2024-01-01
vendor = 2024-02-01

[com.example.aaa]
system = 2023-01-01

# b 段
[com.example.bbb]
boot = no
EOF

run() {
    cp "$dir/base.txt" "$dir/in.txt"
    $AWK -v drop="$1" -v pairsfile=/dev/null -v statusfile="$dir/s" \
        -f tests/fixtures/backends/tricky_patch_set.awk "$dir/in.txt" > "$dir/out.txt" 2>/dev/null
}

echo "── 删除中间段 ──"
run com.example.aaa
chk "状态 ok" "ok" "$(cat "$dir/s")"
hasnt "$dir/out.txt" "com.example.aaa" "aaa 的段头没了"
hasnt "$dir/out.txt" "system = 2023-01-01" "aaa 的块体没了"
has "$dir/out.txt" "^system = 2024-01-01$" "全局段原样保留"
has "$dir/out.txt" "^\[com.example.bbb\]$" "后一段保留"
has "$dir/out.txt" "^boot = no$" "后一段的值保留"
has "$dir/out.txt" "^# b 段$" "后一段前面的说明注释保留"
chk "只剩一个空行（段前空行收掉，段间分隔还在）" "1" "$(blanks "$dir/out.txt")"

echo "── 删除末尾段（连同它的说明注释）──"
run com.example.bbb
chk "状态 ok" "ok" "$(cat "$dir/s")"
hasnt "$dir/out.txt" "com.example.bbb" "bbb 的段头没了"
hasnt "$dir/out.txt" "# b 段" "紧贴段头的说明注释一起删"
has "$dir/out.txt" "^\[com.example.aaa\]$" "前一段保留"
chk "只剩一个空行" "1" "$(blanks "$dir/out.txt")"

echo "── 阴性对照（必须逐字节不变）──"
run com.example.a
chk "别人的前缀不算命中" "missing" "$(cat "$dir/s")"
cmp0
run nope.pkg
chk "不存在的段报 missing" "missing" "$(cat "$dir/s")"
cmp0
run global
chk "删全局段被拒（refused）" "refused" "$(cat "$dir/s")"
cmp0

echo "── 只删名字完全相等的那一段 ──"
cat > "$dir/base.txt" <<'EOF'
a = 2024-01-01

[com.example.aaa]
system = 1

[com.example.aaa.sub]
system = 2
EOF
run com.example.aaa
chk "状态 ok" "ok" "$(cat "$dir/s")"
hasnt "$dir/out.txt" "^\[com.example.aaa\]$" "aaa 段被删"
has "$dir/out.txt" "^\[com.example.aaa.sub\]$" "名字带 .sub 的邻近段保留"
has "$dir/out.txt" "^system = 2$" "邻近段的值保留"

[ "$fail" = 1 ] && echo && echo "有断言失败"
exit $fail
