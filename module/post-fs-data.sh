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

# ---------- 后端互斥检查 ----------
# 两者同时启用时模块停止运行：不做属性伪装，并把停止状态写进模块描述
if backends_conflict; then
    log_warn "⛔ $TAA_CONFLICT_MSG"
    mark_module_stopped "$MODDIR/module.prop"
    exit 0
fi

# ---------- 属性伪装 ----------
# 说明：用户可在模块 WebUI 里关闭伪装（开关文件为 $TAA_PROPS_OFF），
#       关闭后本阶段跳过写入，其余功能（应用列表维护）不受影响。
if props_disabled; then
    log_info "ℹ️ 属性伪装已关闭（$TAA_PROPS_OFF 存在），本次开机跳过"
    exit 0
fi

apply_resetprop

exit 0
