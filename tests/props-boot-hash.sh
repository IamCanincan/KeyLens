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
KL_BOOT_HASH="$T/boot_hash"
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
rm -f "$KL_BOOT_HASH"
set_boot_hash "  ${H64B}  "; chk_ok "带空白的大写值可保存" "$?"
chk "读回已转小写" "$(printf 'b%.0s' $(seq 1 64))" "$(boot_hash_get)"
mode=$(stat -c %a "$KL_BOOT_HASH" 2>/dev/null || stat -f %Lp "$KL_BOOT_HASH" 2>/dev/null)
case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) printf '  skip 权限 600（Windows 文件系统不给 Unix 位）\n' ;;
    *) chk "权限 600" 600 "$mode" ;;
esac
ls "$T".*boot_hash.tmp.* >/dev/null 2>&1 && { printf '  ✗    留下了临时文件\n'; fail=1; } || printf '  ok   没有残留临时文件\n'
set_boot_hash "$H63"; chk_rc "非法值被拒绝" 1 "$?"
chk "非法值没有覆盖原配置" "$(printf 'b%.0s' $(seq 1 64))" "$(boot_hash_get)"
set_boot_hash "-"; chk_ok "清除成功" "$?"
[ ! -f "$KL_BOOT_HASH" ] && printf '  ok   清除后文件不存在\n' || { printf '  ✗   清除后文件仍在\n'; fail=1; }
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
printf 'not-a-hash\n' > "$KL_BOOT_HASH"
rp_reset
chk "坏配置读为空" "" "$(boot_hash_get)"
apply_boot_hash; chk_ok "坏配置时返回 0（不写）" "$?"
chk "坏配置不写任何属性" 0 "$(rp_writes)"

echo "── 5 resetprop 不可用时明确失败 ──"
set_boot_hash "$H64"
( unset -f resetprop; apply_boot_hash ); chk_rc "无 resetprop 时返回失败" 1 "$?"

echo "── 6 三态与自动档（默认从当前后端的配置派生，取不到就一个字节都不写）──"
mkdir -p "$T/omk"
KL_BACKEND=omk
OMK_DIR="$T/omk"
rm -f "$KL_BOOT_HASH"
printf '[trust]\nvb_hash = "%s"\n' "$H64" > "$T/omk/config.toml"
chk "文件不在 = auto 档" auto "$(boot_hash_mode)"
chk "auto：派生值 = 后端配置里那串" "$H64" "$(boot_hash_get)"
chk "auto：来源标 omk" omk "$(boot_hash_source | cut -f1)"
rp_reset
apply_boot_hash; chk_ok "auto：应用成功" "$?"
chk "auto：digest 真写下去（免抄的落点）" "$H64" "$(cat "$RP.ro.boot.vbmeta.digest" 2>/dev/null)"

# random：OMK 允许每次启动重新生成 ⇒ 镜像过来下一开机就过期，而过期值与空值在检测器里
# 同为 Danger，所以这里必须熄火，而不是"先写上再说"
printf '[trust]\nvb_hash = "random"\n' > "$T/omk/config.toml"
chk "random：不派生" "" "$(boot_hash_get)"
rp_reset
apply_boot_hash; chk_ok "random：返回 0（不算失败）" "$?"
chk "random：一个字节都不写" 0 "$(rp_writes)"

# 解析的边界：注释行、同前缀的别的键、没有引号
printf '# vb_hash = "%s"\nother_vb_hash = "%s"\n' "$H64" "$H128" > "$T/omk/config.toml"
chk "注释行不算值" "" "$(boot_hash_get)"
printf 'vb_hash=%s\n' "$H64" > "$T/omk/config.toml"
chk "不带引号也认（与 lib/write.sh 那条 sed 同形）" "$H64" "$(boot_hash_get)"

# 不缓存：后端配置改了，下一次读立刻跟着变
printf '[trust]\nvb_hash = "%s"\n' "$H128" > "$T/omk/config.toml"
chk "不缓存：改配置后 effective 立刻是新的" "$H128" "$(boot_hash_get)"

# 手动优先
set_boot_hash "$H64"
chk "手动：模式=manual" manual "$(boot_hash_mode)"
chk "手动优先于后端配置" "$H64" "$(boot_hash_get)"

# off：明确不写（旧版"清除"的语义搬到这里）
set_boot_hash off
chk "off：模式=off" off "$(boot_hash_mode)"
chk "off：不派生" "" "$(boot_hash_get)"
rp_reset
apply_boot_hash; chk "off：一个字节都不写" 0 "$(rp_writes)"
set_boot_hash auto
[ ! -f "$KL_BOOT_HASH" ] && printf '  ok   auto 就是"没有文件"（不留哨兵）\n' || { printf '  ✗   auto 之后文件还在\n'; fail=1; }

# 没启用任何后端 ⇒ 不派生（卸载残留的配置不算）
KL_BACKEND=""
printf '[trust]\nvb_hash = "%s"\n' "$H64" > "$T/omk/config.toml"
chk "无后端可判时不派生" "" "$(boot_hash_get)"
KL_BACKEND=omk

echo "── 7 TEESim 那一侧：属性已有值必须采用守护进程那份，不拿 override 覆盖 ──"
# 上游把这条 prop 当成它自己的领地：每次 push 都强制成正在证明的值（App.kt:516-523），
# 而 overrides.json 那条 hex 只在当前是合成兜底值时才被采纳（Harvester.kt:183-189）。
# 所以"属性已有值 + override 是另一串"这一支必须采用属性里的值；写成 override 就是
# 亲手造出检测器的 vbmetaDigestMismatch。getprop 在这里存根，代表"属性现在的值"。
mkdir -p "$T/teesim"
GP_VAL=""
H64BL=$(printf 'b%.0s' $(seq 1 64))    # 派生值一律转小写，比较要用小写那串（H64B 是大写样本）
getprop() { printf '%s\n' "$GP_VAL"; }
KL_BACKEND=teesim
TEESIM_DIR="$T/teesim"
rm -f "$KL_BOOT_HASH"
printf '{"verifiedBootHash":"%s"}\n' "$H64B" > "$T/teesim/overrides.json"
chk "teesim：属性为空时来源=overrides.json" "teesim" "$(boot_hash_source | cut -f1)"
chk "teesim：属性为空时取 override 那串（老版本 TEESim 的兜底）" "$H64BL" "$(boot_hash_get)"
rp_reset
apply_boot_hash; chk_ok "teesim：这一支写成功" "$?"
chk "teesim：确实补上了 digest（正对照：为空时不是不写）" "$H64BL" "$(cat "$RP.ro.boot.vbmeta.digest" 2>/dev/null)"
# 属性已有值（守护进程强制下去的那串）⇒ 采用它，且不许写成 override
GP_VAL="$H64"
chk "teesim：属性已有值时来源=daemon" "daemon" "$(boot_hash_source | cut -f1)"
chk "teesim：生效值=属性里那串，不是 override" "$H64" "$(boot_hash_get)"
rp_reset
printf '%s' "$H64" > "$RP.ro.boot.vbmeta.digest"
apply_boot_hash; chk_ok "teesim：已有值这一支返回成功" "$?"
chk "teesim：digest 仍是守护进程那串（没被 override 换掉）" "$H64" "$(cat "$RP.ro.boot.vbmeta.digest" 2>/dev/null)"
chk "teesim：只补了 hash_alg，一次都没动 digest（写次数=1）" 1 "$(rp_writes)"
GP_VAL="zz-not-hex"
chk "teesim：属性里是脏值不算已有值（回落到 override）" "teesim" "$(boot_hash_source | cut -f1)"
GP_VAL=""
KL_BACKEND=omk

echo "── 8 变异：把「只认 hex」的守卫摘掉，random 就会被写进 prop ──"
sed -n '/^boot_hash_source() {/,/^}$/p' "$ROOT/module/lib/props.sh" > "$T/src.orig"
if [ -s "$T/src.orig" ]; then
    sed -e '/boot_hash_valid "\$v"/s/.*/    :/' "$T/src.orig" > "$T/src.mut"
    if cmp -s "$T/src.orig" "$T/src.mut"; then
        printf '  ✗   变异没落地（与真源逐字节相同，这条不算证据）\n'; fail=1
    else
        printf '[trust]\nvb_hash = "random"\n' > "$T/omk/config.toml"
        eval "$(cat "$T/src.mut")"
        chk "变异后 random 被当成值（守卫确实在拦它）" "random" "$(boot_hash_get)"
        . "$ROOT/module/lib/props.sh"      # 换回真源
        chk "换回真源后 random 又不写了" "" "$(boot_hash_get)"
    fi
else
    printf '  ✗   抽不到 boot_hash_source（锚点改了？）\n'; fail=1
fi

echo "── 9 变异：摘掉「属性已有值就采用它」那一行，override 就会覆盖守护进程 ──"
KL_BACKEND=teesim
GP_VAL="$H64"
sed -n '/^boot_hash_source() {/,/^}$/p' "$ROOT/module/lib/props.sh" > "$T/src2.orig"
if [ -s "$T/src2.orig" ]; then
    sed '/printf .daemon/d' "$T/src2.orig" > "$T/src2.mut"
    if cmp -s "$T/src2.orig" "$T/src2.mut"; then
        printf '  ✗   变异没落地（与真源逐字节相同，这条不算证据）\n'; fail=1
    else
        eval "$(cat "$T/src2.mut")"
        chk "变异后生效值变成 override 那串（守卫确实在拦覆盖）" "$H64BL" "$(boot_hash_get)"
        . "$ROOT/module/lib/props.sh"
        chk "换回真源后又采用守护进程那串" "$H64" "$(boot_hash_get)"
    fi
else
    printf '  ✗   抽不到 boot_hash_source（锚点改了？）\n'; fail=1
fi
GP_VAL=""; KL_BACKEND=omk

if [ "$fail" = 0 ]; then echo "全部通过"; else echo "有断言失败"; fi
exit $fail
