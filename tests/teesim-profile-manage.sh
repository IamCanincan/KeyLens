#!/system/bin/sh
#=============================================================================
# tests/teesim-profile-manage.sh - 新建 / 删除 TEESim profile（teesim_profile.awk）
#
# 判据：新建是从 default **整份复制**（不是空壳）；删除只动目标成员；两者都
# 不许碰别的 profile。阳性用例用 teesim_profiles.awk 反读结果当结构自检 ——
# 文本拼接一旦把 JSON 写坏，那份只读解析会先失败，比 grep 括号靠谱。
#
# 跑法：sh tests/teesim-profile-manage.sh
#=============================================================================
set -u
cd "$(dirname "$0")/.." || exit 1
AWK=${AWK:-awk}
fail=0
dir=$(mktemp -d 2>/dev/null || echo /tmp/tpm-$$); mkdir -p "$dir"
chk() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"; else printf '  ✗    %s：期望 [%s] 实得 [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
has() { if grep -q -- "$2" "$1"; then printf '  ok   %s\n' "$3"; else printf '  ✗    %s\n' "$3"; fail=1; fi; }
hasnt() { if grep -q -- "$2" "$1"; then printf '  ✗    %s\n' "$3"; fail=1; else printf '  ok   %s\n' "$3"; fi; }
profiles() { $AWK -f tests/fixtures/backends/teesim_profiles.awk "$1" 2>/dev/null; }
names() { profiles "$1" | cut -f1 | sort | tr '\n' ' ' | sed 's/ $//'; }

cat > "$dir/base.json" <<'EOF'
{
  "version": 1,
  "profiles": {
    "default": {
      "keybox": "alt.xml",
      "mode": "patch",
      "patchLevel": { "system": "today", "boot": "no" },
      "apps": ["com.example.a", "com.example.b"]
    },
    "alt": {
      "keybox": "keybox.xml",
      "mode": "generation",
      "apps": []
    },
    "vacant": { "keybox": "x.xml" }
  }
}
EOF

run() {  # run <mode> <name> —— 一律从 base.json 起跑
    cp "$dir/base.json" "$dir/in.json"
    runOn "$1" "$2" "$dir/in.json"
}
runOn() {  # runOn <mode> <name> <输入文件>
    # 输出先写临时文件再替换：直接 `> out.json` 会在 awk 读之前把它截断，读到空文件
    $AWK -v mode="$1" -v name="$2" -v statusfile="$dir/s" \
        -f tests/fixtures/backends/teesim_profile.awk "$3" > "$dir/out2.json" 2>/dev/null
    mv -f "$dir/out2.json" "$dir/out.json"
}

echo "── 新建：从 default 整份复制 ──"
run new beta
chk "状态 ok" "ok" "$(cat "$dir/s")"
chk "四份 profile（反读解析）" "alt beta default vacant" "$(names "$dir/out.json")"
has "$dir/out.json" "^    \"beta\": {$" "beta 是 profiles 的成员（缩进对齐）"
chk "beta 的 keybox 复制自 default" "alt.xml" "$(profiles "$dir/out.json" | awk -F'\t' '$1=="beta"{print $2}')"
chk "beta 的 mode 复制自 default" "patch" "$(profiles "$dir/out.json" | awk -F'\t' '$1=="beta"{print $3}')"
chk "beta 的 apps 数为 2" "2" "$(profiles "$dir/out.json" | awk -F'\t' '$1=="beta"{print $4}')"
chk "default 没被动" "alt.xml" "$(profiles "$dir/out.json" | awk -F'\t' '$1=="default"{print $2}')"
chk "alt 没被动" "generation" "$(profiles "$dir/out.json" | awk -F'\t' '$1=="alt"{print $3}')"

echo "── 新建的阴性对照 ──"
run new alt
chk "同名报 exists" "exists" "$(cat "$dir/s")"
cmp -s "$dir/base.json" "$dir/out.json" && printf '  ok   文件逐字节未动\n' || { printf '  ✗    文件被改了\n'; fail=1; }
run new default
chk "default 已存在（exists）" "exists" "$(cat "$dir/s")"
cmp -s "$dir/base.json" "$dir/out.json" && printf '  ok   文件逐字节未动\n' || { printf '  ✗    文件被改了\n'; fail=1; }

echo "── 删除 ──"
run del alt
chk "状态 ok" "ok" "$(cat "$dir/s")"
chk "剩三份（反读解析）" "default vacant" "$(names "$dir/out.json")"
hasnt "$dir/out.json" "\"alt\"" "alt 成员没了"
has "$dir/out.json" "\"keybox\": \"x.xml\"" "vacant 保留"
run del vacant
chk "删末尾成员 ok" "ok" "$(cat "$dir/s")"
chk "剩两份（default + alt）" "alt default" "$(names "$dir/out.json")"
run del default
chk "default 不许删（refused）" "refused" "$(cat "$dir/s")"
run del nope
chk "不存在报 missing" "missing" "$(cat "$dir/s")"
cmp -s "$dir/base.json" "$dir/out.json" && printf '  ok   文件逐字节未动\n' || { printf '  ✗    文件被改了\n'; fail=1; }

echo "── 名字是别人的子串时不许误伤 ──"
cat > "$dir/base.json" <<'EOF'
{
  "profiles": {
    "default": { "keybox": "k.xml", "apps": [] },
    "alt": { "keybox": "a.xml", "apps": [] },
    "alt2": { "keybox": "b.xml", "apps": [] }
  }
}
EOF
run del alt
chk "只删 alt 本身" "alt2 default" "$(names "$dir/out.json")"
runOn new alt "$dir/out.json"
chk "alt 已删掉，可以重建" "ok" "$(cat "$dir/s")"
chk "重建后三份" "alt alt2 default" "$(names "$dir/out.json")"

[ "$fail" = 1 ] && echo && echo "有断言失败"
exit $fail
