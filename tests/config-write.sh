#!/bin/sh
#=============================================================================
# tests/config-write.sh - 后端配置写回的定点替换自检（CI 跑，不需要设备）
#
#   teesim_set.awk       default profile 标量/嵌套 patchLevel；插入新键；其它
#                        profile、apps、未知字段保留；重复写 status=same
#   omk_set.awk          injector/config 标量、多行 deny_packages、新段插入；
#                        注释与其它段保留；重复写 status=same
#   tricky_patch_set.awk 全局键替换/插入、裸值转 all、[包名] 段保留
#=============================================================================
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"; else printf '  ✗    %s\n        期望 [%s]，实得 [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
chk_has() { grep -q -- "$2" "$1" && printf '  ok   %s\n' "$3" || { printf '  ✗    %s\n' "$3"; fail=1; }; }
chk_no() { grep -q -- "$2" "$1" && { printf '  ✗    %s\n' "$3"; fail=1; } || printf '  ok   %s\n' "$3"; }
pairs() { printf '%s\n' "$@" > "$T/pairs"; }
run() { awk -v pairsfile="$T/pairs" -v statusfile="$T/st" -v target="${3:-}" -f "$1" "$2" > "$T/out"; echo "$(cat "$T/st")"; }

echo "── 1 TEESim：替换 + 插入 + 保留 ──"
cat > "$T/c.json" <<'EOF'
{
  "version": 1,
  "profiles": {
    "default": {
      "keybox": "keybox.xml",
      "mode": "patch",
      "patchLevel": { "system": "today", "vendor": "YYYY-MM-05", "boot": "YYYY-MM-05" },
      "apps": ["com.a", "com.b@10"],
      "autoIncludeNewApps": false
    },
    "work": { "apps": ["com.c"] }
  }
}
EOF
pairs 'mode	generation' 'patch_system	today' 'brand	Pixel "9"' 'auto_include	true'
chk "首次 status" "ok" "$(run "$ROOT/module/backends/teesim_set.awk" "$T/c.json")"
chk_has "$T/out" '"mode": "generation"' "mode 原位替换"
chk_has "$T/out" '"brand": "Pixel \\"9\\""' "brand 插入并转义"
chk_has "$T/out" '"autoIncludeNewApps": true' "布尔原位替换"
chk_has "$T/out" '"work"' "其它 profile 保留"
chk_has "$T/out" '"com.b@10"' "apps 条目保留"
cp "$T/out" "$T/c2.json"
chk "重复 status" "same" "$(run "$ROOT/module/backends/teesim_set.awk" "$T/c2.json")"
cmp -s "$T/c2.json" "$T/out" && printf '  ok   重复写逐字节不变\n' || { printf '  ✗   重复写变了\n'; fail=1; }

echo "── 2 TEESim：没有 patchLevel 时插入对象 ──"
printf '%s' '{"profiles":{"default":{"apps":["a"]}}}' > "$T/mini.json"
pairs 'patch_system	today' 'patch_boot	no'
chk "status" "ok" "$(run "$ROOT/module/backends/teesim_set.awk" "$T/mini.json")"
chk_has "$T/out" '"patchLevel"' "插入 patchLevel"
chk_has "$T/out" '"boot": "no"' "boot 写入"

echo "── 3 OMK injector：标量 / 多行数组 / 注释 ──"
cat > "$T/inj.toml" <<'EOF'
# header
version = 1
scoop = [
  "com.a",
]
[main]
enabled = true
log_level = "debug"
[filter]
enabled = true
deny_packages = [
  "com.old",
  "com.older",
]
block_android_package = true
[intercept]
delete_key = true
EOF
pairs 'filter_enabled	false' 'filter_deny	com.bad, com.worse' 'inj_log_level	info' 'intercept_delete_key	false'
chk "status" "ok" "$(run "$ROOT/module/backends/omk_set.awk" "$T/inj.toml" injector)"
chk_has "$T/out" '^deny_packages = \["com.bad", "com.worse"\]$' "多行数组换成单行"
chk_has "$T/out" '^log_level = "info"$' "injector 日志级别"
chk_has "$T/out" '^delete_key = false$' "intercept 改写"
chk_has "$T/out" '^# header$' "注释保留"
chk_has "$T/out" '^scoop = \[$' "scoop 保留"
cp "$T/out" "$T/i2.toml"
chk "重复 status" "same" "$(run "$ROOT/module/backends/omk_set.awk" "$T/i2.toml" injector)"
cmp -s "$T/i2.toml" "$T/out" && printf '  ok   重复写逐字节不变\n' || { printf '  ✗   重复写变了\n'; fail=1; }

echo "── 4 OMK config：trust / device / 新段 ──"
cat > "$T/cfg.toml" <<'EOF'
version = 2
[main]
log_level = "debug"
[trust]
os_version = "auto"
[device]
brand = "Sony"
EOF
pairs 'cfg_log_level	info' 'trust_security_patch	2024-11-01' 'dev_serial	XYZ' 'dev_override_telephony	true'
chk "status" "ok" "$(run "$ROOT/module/backends/omk_set.awk" "$T/cfg.toml")"
chk_has "$T/out" '^security_patch = "2024-11-01"$' "trust 新键插入"
chk_has "$T/out" '^serial = "XYZ"$' "device 新键插入"
chk_has "$T/out" '^overrideTelephonyProperties = true$' "布尔写入"
printf 'version = 1\n[filter] # note\nenabled = true\n' > "$T/hdr.toml"
pairs 'filter_enabled	false'
chk "段头带注释 status" "ok" "$(run "$ROOT/module/backends/omk_set.awk" "$T/hdr.toml" injector)"
chk "段头带注释不重复建段" "1" "$(grep -c '^\[filter\]' "$T/out")"
chk_has "$T/out" '^enabled = false$' "段头带注释仍能替换"

printf 'version = 1\n' > "$T/empty.toml"
pairs 'dev_brand	Pixel'
chk "新建段 status" "ok" "$(run "$ROOT/module/backends/omk_set.awk" "$T/empty.toml")"
chk_has "$T/out" '^\[device\]$' "新建 [device] 段"
chk_has "$T/out" '^brand = "Pixel"$' "新段字段"

echo "── 5 Tricky security_patch：全局与包段 ──"
printf '# global\nsystem=2024-01-05\nboot = no # keep\n[com.pkg]\nsystem=2020-01-01\n' > "$T/sp.txt"
pairs 'patch_system	2024-02-01' 'patch_all	20241101'
chk "status" "ok" "$(run "$ROOT/module/backends/tricky_patch_set.awk" "$T/sp.txt")"
chk_has "$T/out" '^system = 2024-02-01$' "system 替换"
chk_has "$T/out" '^all = 20241101$' "all 插入"
chk_has "$T/out" '^boot = no # keep$' "行内注释与无关键保留"
chk_has "$T/out" '^\[com.pkg\]$' "包段保留"
chk_has "$T/out" '^system=2020-01-01$' "包段内容逐字节保留"
cp "$T/out" "$T/sp2.txt"
chk "重复 status" "same" "$(run "$ROOT/module/backends/tricky_patch_set.awk" "$T/sp2.txt")"
printf '20241101\n' > "$T/bare.txt"
pairs 'patch_system	2024-12-01'
chk "裸值 status" "ok" "$(run "$ROOT/module/backends/tricky_patch_set.awk" "$T/bare.txt")"
chk_has "$T/out" '^all = 20241101$' "裸值转成 all"
chk_has "$T/out" '^system = 2024-12-01$' "再写 system"

[ "$fail" = 0 ] && echo "全部通过" || { echo "有断言失败"; exit 1; }
