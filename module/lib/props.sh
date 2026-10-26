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
