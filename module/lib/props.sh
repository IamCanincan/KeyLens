#!/system/bin/sh
#=============================================================================
# lib/props.sh - 系统属性伪装
#
# 说明：期望值表由本文件单点维护 —— apply_resetprop（写入）与
#       webui.sh（展示当前值/期望值）共用同一份，避免两处各写一遍后走偏。
#=============================================================================

# ---------- 期望值表 ----------
# 说明：固定属性表，每行「属性名 期望值」（属性名与值均不含空白）。
# 用法：props_expect_pairs
props_expect_pairs() {
    printf '%s\n' \
        "ro.boot.vbmeta.device_state locked" \
        "ro.boot.verifiedbootstate green" \
        "ro.boot.flash.locked 1" \
        "ro.boot.veritymode enforcing" \
        "ro.boot.warranty_bit 0" \
        "ro.warranty_bit 0" \
        "ro.debuggable 0" \
        "ro.force.debuggable 0" \
        "ro.secure 1" \
        "ro.adb.secure 1" \
        "ro.build.type user" \
        "ro.build.tags release-keys" \
        "ro.vendor.boot.warranty_bit 0" \
        "ro.vendor.warranty_bit 0" \
        "vendor.boot.warranty_bit 0"
}

# 说明：特征替换表，每行「属性名 特征值 替换值」：当前值中含特征值时整体替换为该值。
# 用法：props_expect_rules
props_expect_rules() {
    printf '%s\n' \
        "ro.bootloader engineering release" \
        "ro.build.description test-keys release-keys"
}

# ---------- 伪装开关 ----------
# 说明：开关文件存在即表示用户关闭了属性伪装。文件放在 /data/adb（与日志缓冲同级），
#       覆盖安装模块不会丢失；卸载时由 uninstall.sh 清理。仅 WebUI 写这个文件。
# 用法：props_disabled
# 返回：0=已关闭 1=未关闭
props_disabled() {
    [ -f "$TAA_PROPS_OFF" ]
}

# 说明：开关属性伪装（供 webui.sh 调用）；关闭只影响下一次开机的伪装。
# 用法：set_props_masking <on|off>
# 返回：0=成功 1=失败
set_props_masking() {
    case "$1" in
        on)
            rm -f "$TAA_PROPS_OFF" 2>/dev/null
            ! props_disabled
            ;;
        off)
            : > "$TAA_PROPS_OFF" 2>/dev/null
            chmod 600 "$TAA_PROPS_OFF" 2>/dev/null
            props_disabled
            ;;
        *)  return 1 ;;
    esac
}

# ---------- Verified Boot 哈希 ----------
# 说明：用户从 KeyAttestation 等可信来源取到本机的 verifiedBootHash 后填进来，
#       我们把它写进 ro.boot.vbmeta.digest。这是修复项，不属于伪装开关：
#       只要配置了，开关关着也应用（digest 错的时候，其它属性全对也没用）。
#       只接受 64/128 位十六进制（sha256/sha512），写错比不写更糟。
# 用法：boot_hash_valid <值>
boot_hash_valid() {
    case "${1:-}" in
        ''|*[!0-9a-fA-F]*) return 1 ;;
    esac
    case "${#1}" in
        64|128) return 0 ;;
        *)      return 1 ;;
    esac
}

# 说明：读配置（去空白、转小写）；文件不存在或内容非法时输出空。
# 用法：boot_hash_get
boot_hash_get() {
    local v

    [ -f "$TAA_BOOT_HASH" ] || return 0
    v=$(tr -d '[:space:]' < "$TAA_BOOT_HASH" 2>/dev/null | tr 'A-F' 'a-f')
    boot_hash_valid "$v" || return 0
    printf '%s\n' "$v"
}

# 说明：保存或清除配置（空值 / - 表示清除）；原子写，权限 600。
# 用法：set_boot_hash <值|->
# 返回：0=成功 1=值非法或写入失败
set_boot_hash() {
    local v="${1:-}" tmp

    if [ -z "$v" ] || [ "$v" = "-" ]; then
        rm -f "$TAA_BOOT_HASH" 2>/dev/null
        [ ! -f "$TAA_BOOT_HASH" ]
        return
    fi

    v=$(printf '%s' "$v" | tr -d '[:space:]' | tr 'A-F' 'a-f')
    boot_hash_valid "$v" || return 1
    tmp="${TAA_BOOT_HASH}.tmp.$$"
    printf '%s\n' "$v" > "$tmp" 2>/dev/null || return 1
    chmod 600 "$tmp" 2>/dev/null
    mv -f "$tmp" "$TAA_BOOT_HASH" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
    [ -f "$TAA_BOOT_HASH" ]
}

# 说明：把配置写进 ro.boot.vbmeta.digest 并读回校验；hash_alg 只在为空时补，
#       由 digest 长度决定 sha256/sha512。只用 -n：重启即回系统原值，不留持久化痕迹。
# 用法：apply_boot_hash
# 返回：0=无需处理或已写入且读回一致 1=有配置但无法写入/读回不一致
apply_boot_hash() {
    local h cur alg want now

    h=$(boot_hash_get)
    [ -n "$h" ] || return 0
    command -v resetprop >/dev/null 2>&1 || return 1

    cur=$(resetprop ro.boot.vbmeta.digest 2>/dev/null)
    [ "$cur" = "$h" ] || resetprop -n ro.boot.vbmeta.digest "$h" 2>/dev/null

    alg=$(resetprop ro.boot.vbmeta.hash_alg 2>/dev/null)
    if [ -z "$alg" ]; then
        want=sha256
        [ "${#h}" -eq 128 ] && want=sha512
        resetprop -n ro.boot.vbmeta.hash_alg "$want" 2>/dev/null
    fi

    now=$(resetprop ro.boot.vbmeta.digest 2>/dev/null)
    [ "$now" = "$h" ]
}

# ---------- 应用伪装 ----------
# 说明：逐项比对后写入期望值，已符合则不重复调用 resetprop；
#       另外对含特定特征值的属性做替换。供 post-fs-data.sh 在 Zygote 前调用。
# 用法：apply_resetprop
apply_resetprop() {
    local name="" expected="" value=""

    command -v resetprop >/dev/null 2>&1 || return 0

    # 每行形如「属性名 期望值」：当前值缺失或不同才写入
    props_expect_pairs | while read -r name expected; do
        [ -n "$name" ] && [ -n "$expected" ] || continue
        value=$(resetprop "$name" 2>/dev/null)
        if [ -z "$value" ] || [ "$value" != "$expected" ]; then
            resetprop -n "$name" "$expected" 2>/dev/null
        fi
    done

    # 值中含特定特征时整体替换
    props_expect_rules | while read -r name needle replacement; do
        [ -n "$name" ] && [ -n "$needle" ] || continue
        value=$(resetprop "$name" 2>/dev/null)
        case "$value" in
            *"$needle"*) resetprop -n "$name" "$replacement" 2>/dev/null ;;
        esac
    done
}
