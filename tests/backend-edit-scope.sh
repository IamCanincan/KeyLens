#!/system/bin/sh
#=============================================================================
# tests/backend-edit-scope.sh - 定点写回：改一个 profile / 一个包，别碰其余
#
# 这两个 awk 直接改用户线上配置，判据只有一条：请求之外的字节必须一模一样。
# 所以每个用例都同时断言"目标变了"和"别处没变"，并放几个专门用来勾引误伤的样本
# （profile 名叫 alt，而 default 里有个字符串值也叫 alt）。
#
# 跑法：sh tests/backend-edit-scope.sh
#=============================================================================
set -u
cd "$(dirname "$0")/.." || exit 1
AWK=${AWK:-awk}
TAB=$(printf '\t')
fail=0
dir=$(mktemp -d 2>/dev/null || echo /tmp/tbes-$$); mkdir -p "$dir"

ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  ✗    %s\n' "$1"; fail=1; }
same() {  # same 说明 期望串 实际串
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1：
        期望 [$2]
        实得 [$3]"; fi
}

# ── TEESim：改非 default 的 profile ─────────────────────────────────
cat > "$dir/c1.json" <<'EOF'
{
  "version": 1,
  "profiles": {
    "default": { "keybox": "alt.xml", "mode": "patch", "apps": ["com.a", "com.b"] },
    "alt": { "keybox": "keybox.xml", "mode": "patch", "patchLevel": { "system": "today" }, "apps": [] }
  }
}
EOF
printf 'mode%sgeneration\n' "$TAB" > "$dir/p1"
$AWK -v pairsfile="$dir/p1" -v statusfile="$dir/s1" -v profile=alt \
     -f tests/fixtures/backends/teesim_set.awk "$dir/c1.json" > "$dir/o1.json" 2>/dev/null
same "TEESim 状态" "ok" "$(cat "$dir/s1")"
same "alt 的 mode 被改" "generation" \
  "$(printf '%s' "$(grep -A4 '"alt"' "$dir/o1.json")" | grep -o '"mode": "[a-z]*"' | head -1 | cut -d'"' -f4)"
same "default 一个字节没动（它里面那个 keybox=alt.xml 也没被当成目标）" \
  '"default": { "keybox": "alt.xml", "mode": "patch", "apps": ["com.a", "com.b"] },' \
  "$(grep '"default"' "$dir/o1.json" | sed 's/[[:space:]]*$//;s/^ *//')"
same "apps 数组仍在" "2" "$(grep -o 'com\.[ab]' "$dir/o1.json" | wc -l | tr -d ' ')"

# 不存在的 profile：必须整份原样吐回，不能新建也不能改到 default
$AWK -v pairsfile="$dir/p1" -v statusfile="$dir/s2" -v profile=ghost \
     -f tests/fixtures/backends/teesim_set.awk "$dir/c1.json" > "$dir/o2.json" 2>/dev/null
same "找不到目标 profile → status=missing" "missing" "$(cat "$dir/s2")"
same "找不到时文件逐字节不变" "$(sha256sum < "$dir/c1.json" | cut -c1-16)" "$(sha256sum < "$dir/o2.json" | cut -c1-16)"

# 省略 profile：行为与旧版一致（改 default）
printf 'mode%sgeneration\n' "$TAB" > "$dir/p3"
$AWK -v pairsfile="$dir/p3" -v statusfile="$dir/s3" \
     -f tests/fixtures/backends/teesim_set.awk "$dir/c1.json" > "$dir/o3.json" 2>/dev/null
same "不带 profile 时仍改 default" "ok" "$(cat "$dir/s3")"
same "  default 的 mode 变了" "generation" \
  "$(printf '%s' "$(grep '"default"' "$dir/o3.json")" | grep -o '"mode": "[a-z]*"' | cut -d'"' -f4)"
# 与输入文件逐字节比，而不是比一个我数出来的长度
same "  alt 整行与输入完全相同" \
  "$(grep '"alt"' "$dir/c1.json")" "$(grep '"alt"' "$dir/o3.json")"

# ── Tricky：全局段 / 按包段 / 新建段 ────────────────────────────────
cat > "$dir/t1.txt" <<'EOF'
# 全局注释，必须原样留着
system = today
vendor = 2024-01-05

[com.example.a]
boot = 2023-06-01

[com.example.b]
system = no
EOF
printf 'patch_system%s2025-02-03\n' "$TAB" > "$dir/tp1"

# 取"全局段"里的某一行：必须只看第一个 [ 之前，否则会把按包块里的同名键混进来
glob() { awk -v k="$2" '/^\[/{exit} $0 ~ "^"k" "{print}' "$1" | head -1 | sed 's/[[:space:]]*$//'; }

$AWK -v pairsfile="$dir/tp1" -v statusfile="$dir/ts1" \
     -f tests/fixtures/backends/tricky_patch_set.awk "$dir/t1.txt" > "$dir/to1.txt" 2>/dev/null
same "Tricky 全局段状态" "ok" "$(cat "$dir/ts1")"
same "  全局 system 被改" "system = 2025-02-03" "$(glob "$dir/to1.txt" system)"
same "  全局 vendor 未动" "vendor = 2024-01-05" "$(glob "$dir/to1.txt" vendor)"
same "  注释未动" "# 全局注释，必须原样留着" "$(head -1 "$dir/to1.txt")"
same "  按包块未动" "boot = 2023-06-01" "$(grep -A1 '\[com.example.a\]' "$dir/to1.txt" | tail -1)"

$AWK -v pairsfile="$dir/tp1" -v statusfile="$dir/ts2" -v scope=com.example.b \
     -f tests/fixtures/backends/tricky_patch_set.awk "$dir/t1.txt" > "$dir/to2.txt" 2>/dev/null
same "scope=com.example.b → ok" "ok" "$(cat "$dir/ts2")"
same "  该块的 system 被改" "system = 2025-02-03" \
  "$(awk '/^\[com.example.b\]/{f=1;next} f&&/^\[/{f=0} f&&/^system/{print}' "$dir/to2.txt" | sed 's/[[:space:]]*$//')"
same "  全局 system 没被误改" "system = today" "$(glob "$dir/to2.txt" system)"
same "  另一个块没被误改" "boot = 2023-06-01" "$(grep -A1 '\[com.example.a\]' "$dir/to2.txt" | tail -1)"

printf 'patch_boot%sdevice_default\n' "$TAB" > "$dir/tp3"
$AWK -v pairsfile="$dir/tp3" -v statusfile="$dir/ts3" -v scope=com.new.pkg \
     -f tests/fixtures/backends/tricky_patch_set.awk "$dir/t1.txt" > "$dir/to3.txt" 2>/dev/null
same "新建块 → ok" "ok" "$(cat "$dir/ts3")"
same "  新块段头建出来了" "1" "$(grep -c '^\[com.new.pkg\]$' "$dir/to3.txt")"
same "  新块落在文件末尾" "1" "$(tail -2 "$dir/to3.txt" | head -1 | grep -c '^\[com.new.pkg\]$')"
same "  新块里的值" "boot = device_default" "$(tail -1 "$dir/to3.txt" | sed 's/[[:space:]]*$//')"
same "  原有两个段都还在 + 新建一个 = 3 段" "3" "$(grep -c '^\[' "$dir/to3.txt")"

# 非法 scope 由命令层拦（这里只验 awk 不会自己瞎建段）：给个不存在的合法包名再改回来
rm -rf "$dir"
[ "$fail" = 0 ] && echo "全部通过" || echo "有断言失败"
exit $fail
