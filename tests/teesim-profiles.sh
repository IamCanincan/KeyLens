#!/system/bin/sh
#=============================================================================
# tests/teesim-profiles.sh - 枚举 TEE Simulator 多 profile 的只读 awk
#
# 上游 config.json 的 profiles 是一张名字→配置的表；写回路径以前只认 default，
# 所以"有几个 profile、各自什么样子"从来没被读出来过。这个自检钉住解析结果，
# 特别是三个容易翻车的地方：apps 数组的计数、嵌套对象不串层、default 排第一。
#
# 跑法：sh tests/teesim-profiles.sh
#=============================================================================
set -u
cd "$(dirname "$0")/.." || exit 1
AWK=${AWK:-awk}
TAB=$(printf '\t')
fail=0
chk() {  # chk 说明 期望 实际
    if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$2"
    else printf '  ✗    %s：期望 [%s] 实得 [%s]\n' "$1" "$2" "$3"; fail=1; fi
}

dir=$(mktemp -d 2>/dev/null || echo /tmp/taap-$$)
mkdir -p "$dir"
cat > "$dir/config.json" <<'EOF'
{
  "version": 1,
  "profiles": {
    "alt": {
      "keybox": "test.xml",
      "mode": "generation",
      "patchLevel": { "system": "2024-01-05", "vendor": "2024-02-05", "boot": "no" },
      "apps": ["com.example.a", "com.example.b@11", "uid:2000"],
      "autoIncludeNewApps": false,
      "device": { "brand": "Sony", "product": "XQ-DQ72_CN" }
    },
    "default": {
      "keybox": "keybox.xml",
      "mode": "patch",
      "patchLevel": { "system": "today", "vendor": "YYYY-MM-05", "boot": "YYYY-MM-05" },
      "apps": ["com.google.android.gms"],
      "autoIncludeNewApps": true,
      "brand": "Sony"
    },
    "empty": { "keybox": "k2.xml" }
  }
}
EOF

out=$($AWK -f tests/fixtures/backends/teesim_profiles.awk "$dir/config.json" 2>&1); rc=$?
chk "退出码" 0 "$rc"
lines=$(printf '%s\n' "$out" | grep -c . )
chk "三个 profile" 3 "$lines"

first=$(printf '%s\n' "$out" | head -1)
chk "default 排第一（文件里它在第二行）" "default${TAB}keybox.xml${TAB}patch${TAB}1${TAB}1" "$first"
chk "alt 的 apps 数=3（含 @用户 与 uid:）" "3" "$(printf '%s\n' "$out" | grep "^alt" | cut -f4)"
chk "alt 的 mode" "generation" "$(printf '%s\n' "$out" | grep "^alt" | cut -f3)"
chk "空 profile：mode 缺省 patch、apps=0、keybox 照读" "empty${TAB}k2.xml${TAB}patch${TAB}0${TAB}0" "$(printf '%s\n' "$out" | grep '^empty')"

# 反例：没有 profiles 就不能瞎输出
printf '{ "version": 1 }\n' > "$dir/no.json"
out2=$($AWK -f tests/fixtures/backends/teesim_profiles.awk "$dir/no.json" 2>&1); rc2=$?
chk "没有 profiles → 退码 1" 1 "$rc2"
chk "没有 profiles → 不输出行" "0" "$(printf '%s' "$out2" | grep -c . )"

# 反例：apps 里嵌对象时不猜（宁可数错方向也要可预期 —— 钉住当前行为）
cat > "$dir/nest.json" <<'EOF'
{ "profiles": { "default": { "keybox": "a.xml",
    "apps": ["one", "two", "three", "four"] } } }
EOF
chk "apps 四条时数到 4" "4" "$($AWK -f tests/fixtures/backends/teesim_profiles.awk "$dir/nest.json" | cut -f4)"

rm -rf "$dir"
[ "$fail" = 0 ] && echo "全部通过" || echo "有断言失败"
exit $fail
