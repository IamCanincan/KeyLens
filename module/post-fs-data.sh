#!/system/bin/sh
#=============================================================================
# post-fs-data.sh - 开机早期属性伪装（框架固定调用，必须位于模块根目录）
#
# 说明：必须在 Zygote 启动前执行，否则 ro.build.type / ro.build.tags 等属性
#       已被固化进 Java 的 Build.TYPE / Build.TAGS 静态字段（如 userdebug）。
#=============================================================================

MODDIR="${0%/*}"

# 覆盖各框架的 resetprop 所在目录，确保能定位到该命令
export PATH="/system/bin:/system/xbin:/data/adb/magisk:/data/adb/ksu/bin:/data/adb/ap/bin:$PATH"

. "$MODDIR/lib/common.sh" 2>/dev/null || exit 0

# ---------- 改名迁移 ----------
# 模块从 TS-AUTO-ADD 改名 KeyLens：日志缓冲、属性伪装开关、启动哈希这三个是
# **用户状态**，先搬到新路径，后面所有读写才看得见用户原来的设置。
migrate_legacy_paths

# ---------- 后端互斥检查 ----------
# 两者同时启用时模块停止运行：不做属性伪装，并把停止状态写进模块描述
if backends_conflict; then
    log_warn "⛔ $KL_CONFLICT_MSG"
    mark_module_stopped "$MODDIR/module.prop"
    exit 0
fi

# ---------- Verified Boot 哈希 ----------
# 说明：digest 是修复项，不属于伪装开关：只要配置了，开关关着也应用。
#       失败不阻断开机（下一阶段还会复核一次），但要在日志里留下证据。
if [ -n "$(boot_hash_get)" ]; then
    if apply_boot_hash; then
        log_info "🧩 已按配置写入 ro.boot.vbmeta.digest"
    else
        log_warn "⚠️ Verified Boot 哈希写入后读回不一致（见 $KL_BOOT_HASH）"
    fi
fi

# ---------- 属性伪装 ----------
# 说明：用户可在模块 WebUI 里关闭伪装（开关文件为 $KL_PROPS_OFF），
#       关闭后本阶段跳过写入，其余功能（应用列表维护）不受影响。
if props_disabled; then
    log_info "ℹ️ 属性伪装已关闭（$KL_PROPS_OFF 存在），本次开机跳过"
    exit 0
fi

apply_resetprop

exit 0
