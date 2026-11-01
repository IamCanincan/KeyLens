#!/system/bin/sh
#=============================================================================
# customize.sh - 安装脚本（框架固定调用，必须位于模块根目录）
#
# 流程：依赖检查 → 探测后端并初始化目录 → 配置权限 → 清理旧版残留 → 初始同步
#=============================================================================
SKIPUNZIP=0

ui_print "================================================"
ui_print "   🚀 KeyLens 安装程序"
ui_print "================================================"

MODDIR="$MODPATH"          # 供 lib/common.sh 定位模块目录
. "$MODPATH/lib/common.sh" 2>/dev/null || abort "❌ 无法加载 lib/common.sh"

# ---------- 后端互斥检查 ----------
# 两者同时启用时直接终止安装，避免装上后模块处于停止状态
if backends_conflict; then
    abort "  ⛔ $KL_CONFLICT_MSG"
fi

# ---------- [1/5] 依赖检查 ----------
ui_print " "
ui_print "🔍 [1/5] 检查 inotify 支持"
INOTIFY_INFO=$(find_inotify_cmd)
[ -n "$INOTIFY_INFO" ] || abort "  ❌ 未检测到 inotifywait 或 inotifyd"
INOTIFY_MODE="${INOTIFY_INFO%%:*}"
INOTIFY_CMD="${INOTIFY_INFO#*:}"
ui_print "  👀 监听方式：$INOTIFY_MODE（${INOTIFY_CMD%% *}）"

# ---------- [2/5] 探测后端并初始化目录 ----------
ui_print " "
ui_print "🧩 [2/5] 探测后端并初始化目录"
detect_backend "$MODPATH"
mkdir -p "$KL_DIR" 2>/dev/null || abort "  ❌ 无法创建目录 $KL_DIR"
ui_print "  🔌 后端：$(backend_name)"
ui_print "  📁 目录：$KL_DIR"

if [ "$KL_BACKEND" = "teesim" ] || [ "$KL_BACKEND" = "omk" ]; then
    [ -n "$AWK_CMD" ] || ui_print "  ⚠️ 未找到 awk，$(backend_name) 配置将无法维护"
elif [ ! -f "$TARGET_FILE" ]; then
    touch "$TARGET_FILE" 2>/dev/null
    chmod 644 "$TARGET_FILE" 2>/dev/null
fi
if [ "$KL_BACKEND" = "omk" ] && [ ! -f "$TARGET_FILE" ]; then
    ui_print "  ⚠️ 未找到 $TARGET_FILE；先打开一次 OhMyKeymint 生成配置，再点「立即同步」"
fi

# 名单只有目标文件本身。第一次同步（见下）会在目标文件还没有内容时把谷歌三件套
# 种进去；OhMyKeymint 首次接入则沿用现有 scoop，只把当前已装记成基线。
if [ "$KL_BACKEND" = "omk" ]; then
    ui_print "  📝 名单：$TARGET_FILE（首次沿用现有 scoop，之后新装自动加入）"
else
    ui_print "  📝 名单：$TARGET_FILE（首次同步会种入谷歌三件套）"
fi

# ---------- [3/5] 脚本权限 ----------
ui_print " "
ui_print "🔧 [3/5] 配置脚本权限"
set_perm_recursive "$MODPATH" 0 0 0755 0644 || true
chmod 0755 "$MODPATH/post-fs-data.sh" 2>/dev/null
chmod 0755 "$MODPATH/service.sh" 2>/dev/null
chmod 0755 "$MODPATH/action.sh" 2>/dev/null
# 其余脚本也点名给 0755：KernelSU 解包后一律落 644（zip 里的权限位不保留），
# 而 webui.sh 由管理器按 sh 调用、backends/*.sh 会被 source、部署脚本还要核对模式 ——
# 不点名就会留一堆 644，看着能跑，一核对就红（2026-10-30 装 KeyLens 时实测如此）。
chmod 0755 "$MODPATH/webui.sh" "$MODPATH/uninstall.sh" 2>/dev/null
chmod 0755 "$MODPATH"/backends/*.sh 2>/dev/null
# 命令层的可执行实现只剩 bin/keylens：那十九份 awk 是**参照实现**，移进了
# tests/fixtures/backends 供对拍用，不再随模块发布（见 lib/backend.sh 的 KL_PATCH_DIR）。
# 所以包里没带二进制 = 装上就是一套跑不动的命令层，与其留着半残的模块等用户报"不生效"，
# 不如在这里当场收口。KernelSU 解包会把执行位抹成 644，这里点名补一次。
if [ -f "$MODPATH/bin/keylens" ]; then
    chmod 0755 "$MODPATH/bin/keylens" 2>/dev/null
    ui_print "  ⚙️ 命令层：bin/keylens（$(wc -c < "$MODPATH/bin/keylens" 2>/dev/null) 字节）"
else
    ui_print "  ✗ 这个包里没带 bin/keylens，安装中止。"
    ui_print "    自本版起 awk 参照实现不再随模块发布：没有二进制就没有命令层。"
    ui_print "    请用 CI 的 keylens-module-aarch64 产物打包，或重新下载完整包。"
    abort "缺少 bin/keylens"
fi

# ---------- [4/5] 清理旧版残留 ----------
ui_print " "
ui_print "🧹 [4/5] 清理旧版文件"
rm -rf "$TSTORE_DIR/.kl_lock" "$TSTORE_DIR/.kl_debounce" "$TSTORE_DIR/.kl_tmp" \
       "$TEESIM_DIR/.kl_lock" "$TEESIM_DIR/.kl_debounce" "$TEESIM_DIR/.kl_tmp" \
       "$OMK_STATE_DIR/.kl_lock" "$OMK_STATE_DIR/.kl_debounce" "$OMK_STATE_DIR/.kl_tmp" \
       "$TSTORE_DIR"/.kl_daemon*.pid "$TEESIM_DIR"/.kl_daemon*.pid "$OMK_STATE_DIR"/.kl_daemon*.pid 2>/dev/null
rm -f "$TSTORE_DIR/.last_month" "$TSTORE_DIR/.kl_fingerprint" "$TEESIM_DIR/.kl_fingerprint" "$OMK_STATE_DIR/.kl_fingerprint" 2>/dev/null
rm -f "$TSTORE_DIR/taa_sys.txt" 2>/dev/null
rm -f /data/adb/service.d/taa_resetprop.sh 2>/dev/null

# 旧模块目录：直接接管——状态已由下面的 migrate_legacy_paths 搬到新名字（它读的是
# /data/adb/ts_auto.* 与后端目录里的 .ts_*，与旧模块目录无关），所以这里把旧目录删掉。
# 留着就是两套 service.sh 同跑：两份守护进程各监听、各写同一份后端配置。
for _old in /data/adb/modules/ts-auto-add /data/adb/modules/ts_auto; do
    if [ -d "$_old" ]; then
        rm -rf "$_old" 2>/dev/null
        ui_print "  🗑️ 已接管旧模块目录：${_old##*/}（状态随后迁移）"
    fi
done

# ---------- [5/5] 初始同步 ----------
ui_print " "
ui_print "🔄 [5/5] 运行初始同步"
# 迁移必须排在首次同步之前：改名前那套 .ts_* 状态（已装基线、历次纳入并集）如果还
# 没搬过来，run_sync 会走"首次安装"分支自己建一份新基线，旧的那份此后永远搬不动
# （migrate 见新名已存在就跳过）—— 结果是你手动排除过的应用被重新加进名单。
# service.sh / post-fs-data.sh 里都有这一步，但刷机当次不重启就打开界面、或按
# 模块的"操作"按钮，走的是这两条路，碰不到它们。
migrate_legacy_paths
run_sync "$MODPATH/module.prop" "${KL_DIR}/.kl_tmp"
rc=$?
ui_print "  📦 应用总数：$KL_COUNT"
case "$rc" in
    0) ui_print "  ✅ 写入完成" ;;
    1) ui_print "  ℹ️ 数据与现有配置一致" ;;
    2) ui_print "  ⚠️ 未能写入（已记入模块描述），交由守护进程处理" ;;
esac

ui_print "================================================"
ui_print "  ✅ 安装完成，重启后生效"
ui_print "  📝 运行日志：$KL_LOG"
ui_print "================================================"
