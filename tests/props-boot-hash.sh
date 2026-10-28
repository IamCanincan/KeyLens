#!/bin/sh
#=============================================================================
# tests/props-boot-hash.sh - Verified Boot 哈希的自检（CI 跑，不需要设备）
#
# 测的是 module/lib/props.sh 里真实的校验/保存/应用函数，只把 resetprop 换成
# 一个记写入次数的桩。要焊住的点：
#   1 只接受 64/128 位十六进制（sha256/sha512）
#   2 保存会去空白、转小写、原子写、权限 600
#   3 清除后不再应用；非法值不会覆盖已有配置
#   4 apply 只在值不同时写 digest；hash_alg 只补空值
#   5 写后读回不一致要返回失败（不能让界面报"已应用"）
#   6 没配置时不碰属性
#=============================================================================
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
TAA_BOOT_HASH="$T/boot_hash"
. "$ROOT/module/lib/props.sh"

fail=0
chk() {
    if [ "$2" = "$3" ]; then printf '  ok   %-34s = %s\n' "$1" "$3"
    else printf '  ✗    %-34s 期望 %s，实得 %s\n' "$1" "$2" "$3"; fail=1; fi
}
chk_ok() {  # chk_ok <标签> <应得的退出码>
    if [ "$2" = 0 ]; then printf '  ok   %s\n' "$1"
    else printf '  ✗    %s（返回 %s）\n' "$1" "$2"; fail=1; fi
}
chk_rc() {  # chk_rc <标签> <期望退出码> <实际退出码>
    if [ "$2" = "$3" ]; then printf '  ok   %-34s rc=%s\n' "$1" "$3"
    else printf '  ✗    %-34s 期望 rc=%s，实得 %s\n' "$1" "$2" "$3"; fail=1; fi
}

H64=$(printf 'a%.0s' $(seq 1 64))
H64B=$(printf 'B%.0s' $(seq 1 64))
H128=$(printf 'c%.0s' $(seq 1 128))
H63=$(printf 'a%.0s' $(seq 1 63))

# resetprop 桩：-n 写；单参数读。RP_DROP=1 时吞掉写入（模拟读回不一致）
RP="$T/rp"
RP_COUNT="$T/rp.count"
resetprop() {
    case "$1" in
        -n)
            [ "${RP_DROP:-0}" = 1 ] && return 0
            printf '%s\n' "$3" > "$RP.$2"
            echo x >> "$RP_COUNT"
            ;;
        *)
            [ -f "$RP.$1" ] && cat "$RP.$1"
            ;;
    esac
}
rp_reset() { rm -f "$RP".* "$RP_COUNT"; }
rp_writes() { [ -f "$RP_COUNT" ] && wc -l < "$RP_COUNT" | tr -d ' ' || echo 0; }

echo "── 1 格式校验 ──"
chk_rc "64 位接受" 0 "$(boot_hash_valid "$H64"; echo $?)"
chk_rc "128 位接受" 0 "$(boot_hash_valid "$H128"; echo $?)"
chk_rc "63 位拒绝" 1 "$(boot_hash_valid "$H63"; echo $?)"
chk_rc "65 位拒绝" 1 "$(boot_hash_valid "${H64}a"; echo $?)"
chk_rc "含非十六进制字符拒绝" 1 "$(boot_hash_valid "$(printf 'g%.0s' $(seq 1 64))"; echo $?)"
chk_rc "带 0x 前缀拒绝" 1 "$(boot_hash_valid "0x$H64"; echo $?)"
chk_rc "空值拒绝" 1 "$(boot_hash_valid ""; echo $?)"

echo "── 2 保存 / 读取 / 清除 ──"
rm -f "$TAA_BOOT_HASH"
set_boot_hash "  ${H64B}  "; chk_ok "带空白的大写值可保存" "$?"
chk "读回已转小写" "$(printf 'b%.0s' $(seq 1 64))" "$(boot_hash_get)"
mode=$(stat -c %a "$TAA_BOOT_HASH" 2>/dev/null || stat -f %Lp "$TAA_BOOT_HASH" 2>/dev/null)
case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) printf '  skip 权限 600（Windows 文件系统不给 Unix 位）\n' ;;
    *) chk "权限 600" 600 "$mode" ;;
esac
ls "$T".*boot_hash.tmp.* >/dev/null 2>&1 && { printf '  ✗    留下了临时文件\n'; fail=1; } || printf '  ok   没有残留临时文件\n'
set_boot_hash "$H63"; chk_rc "非法值被拒绝" 1 "$?"
chk "非法值没有覆盖原配置" "$(printf 'b%.0s' $(seq 1 64))" "$(boot_hash_get)"
set_boot_hash "-"; chk_ok "清除成功" "$?"
[ ! -f "$TAA_BOOT_HASH" ] && printf '  ok   清除后文件不存在\n' || { printf '  ✗   清除后文件仍在\n'; fail=1; }
chk "清除后读为空" "" "$(boot_hash_get)"

echo "── 3 应用：只在需要时写 ──"
rp_reset
apply_boot_hash; chk_ok "没配置时返回 0" "$?"
chk "没配置时不写属性" 0 "$(rp_writes)"

set_boot_hash "$H64"; rp_reset
apply_boot_hash; chk_ok "64 位应用成功" "$?"
chk "digest 已写入" "$H64" "$(cat "$RP.ro.boot.vbmeta.digest" 2>/dev/null)"
chk "hash_alg 补为 sha256" sha256 "$(cat "$RP.ro.boot.vbmeta.hash_alg" 2>/dev/null)"
chk "写了 digest + hash_alg 两次" 2 "$(rp_writes)"
apply_boot_hash; chk_ok "重复应用成功" "$?"
chk "已一致时不重复写" 2 "$(rp_writes)"

rm -f "$RP".* "$RP_COUNT"
set_boot_hash "$H128"
apply_boot_hash; chk_ok "128 位应用成功" "$?"
chk "128 位的 hash_alg 是 sha512" sha512 "$(cat "$RP.ro.boot.vbmeta.hash_alg" 2>/dev/null)"

rm -f "$RP".* "$RP_COUNT"
printf 'blake2b\n' > "$RP.ro.boot.vbmeta.hash_alg"
apply_boot_hash; chk_ok "已有 hash_alg 时应用成功" "$?"
chk "不覆盖已存在的 hash_alg" blake2b "$(cat "$RP.ro.boot.vbmeta.hash_alg" 2>/dev/null)"

echo "── 4 读回失败与坏配置 ──"
rm -f "$RP".* "$RP_COUNT"
set_boot_hash "$H64"
RP_DROP=1 apply_boot_hash; chk_rc "读回不一致时返回失败" 1 "$?"
RP_DROP=0
printf 'not-a-hash\n' > "$TAA_BOOT_HASH"
rp_reset
chk "坏配置读为空" "" "$(boot_hash_get)"
apply_boot_hash; chk_ok "坏配置时返回 0（不写）" "$?"
chk "坏配置不写任何属性" 0 "$(rp_writes)"

echo "── 5 resetprop 不可用时明确失败 ──"
set_boot_hash "$H64"
( unset -f resetprop; apply_boot_hash ); chk_rc "无 resetprop 时返回失败" 1 "$?"

if [ "$fail" = 0 ]; then echo "全部通过"; else echo "有断言失败"; fi
exit $fail
