#!/system/bin/sh
#=============================================================================
# service.sh - 后台守护（事件驱动 · 无联网）
#
# 职责：
#   1. 开机后执行一次同步并刷新模块描述
#   2. 单进程监听 /data/system/packages.list 与 rules.txt
#   3. 仅在源数据真正变化时同步（指纹比对 + 防抖）
#
# 说明：入口脚本由框架固定调用，必须位于模块根目录。
#=============================================================================

MODDIR="${0%/*}"
PROP_FILE="$MODDIR/module.prop"
WATCH_DIR="/data/system"

export PATH="/system/bin:/system/xbin:/odm/bin:/vendor/bin:/product/bin:$PATH"
. "$MODDIR/lib/common.sh" || exit 1

# ---------- 后端互斥检查 ----------
# 两者同时启用时不做任何处理，直接停止守护，并把停止状态写进模块描述
if backends_conflict; then
    log_err "⛔ $TAA_CONFLICT_MSG"
    mark_module_stopped "$PROP_FILE"
    exit 0
fi

# ---------- 后端探测 ----------
detect_backend "$MODDIR"

TMP="${TAA_DIR}/.ts_tmp"
LOCK_DIR="${TAA_DIR}/.ts_lock"
DEBOUNCE_LOCK="${TAA_DIR}/.ts_debounce"
PIDS_FILE="${TAA_DIR}/.ts_daemon_pids.list"
FP_FILE="${TAA_DIR}/.ts_fingerprint"

log_info "🔍 后端：$(backend_name)（目录：$TAA_DIR）"
if [ "$TAA_BACKEND" = "teesim" ] && [ -z "$AWK_CMD" ]; then
    log_warn "⚠️ 未找到 awk，暂时无法维护 TEE Simulator 配置"
fi

# ---------- inotify 依赖检查 ----------
INOTIFY_INFO=$(find_inotify_cmd)
if [ -z "$INOTIFY_INFO" ]; then
    log_err "❌ 未找到 inotify 工具，服务退出"
    exit 1
fi
INOTIFY_MODE="${INOTIFY_INFO%%:*}"
INOTIFY_CMD="${INOTIFY_INFO#*:}"
log_info "👀 监听方式：$INOTIFY_MODE（${INOTIFY_CMD%% *}）"

# ---------- 监听目标与掩码 ----------
# 说明：监视要挂在「目录」上，不能只挂在 rules.txt 这个文件上。
#       inotify 的监视点绑的是 inode；用「写临时文件再改名覆盖」的方式替换
#       rules.txt（vim、sed -i，以及本模块 WebUI 的原子保存都是这么干的）之后，
#       旧 inode 已被 unlink，挂在它上面的监视从此不再上报任何事件 ——
#       表现是改了常驻列表却不再自动同步，而且只有重启才恢复。
#       挂目录时，「改名进来」本身就是目录事件，监视不会随文件被替换而失效。
RULES_DIR="${RULES_FILE%/*}"

# 文件级掩码：修改 + 可写关闭（就地追加/改写用）
MASK_FILE="wc"
# 目录级掩码：修改 + 可写关闭 + 移入。
# 「移入」这个字母两家是反的：toybox 的 --help 写 m 移入 / y 移出，busybox 相反；
# 但实测两家在「临时文件改名覆盖」时上报的都是 y —— _help 文本不可信，
# 索性两个字母都带上，不必赌设备上躺的是哪一个。
MASK_DIR="cwmy"

# inotifywait 一侧要加的 -e 参数。close_write / moveto 是这次修复需要的，
# 但本机没有 inotifywait 可测（只有 inotifyd），所以先用一次 1 秒的实跑探一下：
# 事件名不被接受时 inotifywait 会直接报错退出，那就退回旧的事件集，
# 绝不能让监听进程因为参数不认而起不来（外层是 3 秒一轮的重启循环，会空转）。
WATCH_EVENTS="-e modify -e create -e delete"
if [ "$INOTIFY_MODE" = "inotifywait" ]; then
    mkdir -p "$RULES_DIR" 2>/dev/null
    if $INOTIFY_CMD -q -t 1 -e close_write -e moveto "$RULES_DIR" >/dev/null 2>&1; then
        WATCH_EVENTS="$WATCH_EVENTS -e close_write -e moveto"
    else
        log_warn "⚠️ 该 inotifywait 不支持 close_write/moveto，退回旧事件集（改名替换可能不触发）"
    fi
fi

# ---------- 变更检测 ----------
# 说明：以 packages.list 的包名集合 + rules.txt 的有效包名生成指纹，用于过滤系统
#       频繁改写 packages.list 造成的无谓同步；只改注释或空行不会触发同步。
# 用法：get_source_fingerprint
get_source_fingerprint() {
    local pkgs rules

    pkgs=$(cut -d' ' -f1 "$WATCH_DIR/packages.list" 2>/dev/null | sort -u)
    rules=$(read_rules | sort -u)

    printf '%s\n%s\n' "$pkgs" "$rules" | cksum 2>/dev/null | cut -d' ' -f1
}

# ---------- 同步核心 ----------
# 说明：指纹未变化则直接返回；失败时不记录指纹，便于下次重试。
# 用法：do_sync
do_sync() {
    local fp rc

    fp=$(get_source_fingerprint)
    if [ -n "$fp" ] && [ "$fp" = "$(cat "$FP_FILE" 2>/dev/null)" ]; then
        return 0
    fi

    log_info "🔄 开始应用列表同步"
    run_sync "$PROP_FILE" "$TMP"
    rc=$?
    case "$rc" in
        0) log_info "✅ 同步完成，应用总数：$TAA_COUNT" ;;
        2) log_warn "⚠️ 同步失败：未能生成或写入应用列表（已记入模块描述）" ;;
    esac

    if [ "$rc" != "2" ] && [ -n "$fp" ]; then
        echo "$fp" > "$FP_FILE" 2>/dev/null
    fi
}

# ---------- 防抖调度 ----------
# 说明：2 秒内的多次触发合并为一次同步。
# 用法：dispatch_sync
dispatch_sync() {
    mkdir "$DEBOUNCE_LOCK" 2>/dev/null || return 0

    (
        sleep 2
        rmdir "$DEBOUNCE_LOCK" 2>/dev/null
        acquire_lock "$LOCK_DIR" || exit 1
        do_sync
        release_lock "$LOCK_DIR"
    ) &
}

# ---------- 状态清理 ----------
# 结束上次遗留的守护进程，并清理运行文件
if [ -f "$PIDS_FILE" ]; then
    while read -r pid; do
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
    done < "$PIDS_FILE"
    rm -f "$PIDS_FILE" 2>/dev/null
fi
rm -rf "$TMP" "$LOCK_DIR" "$DEBOUNCE_LOCK" 2>/dev/null

# ---------- 启动 ----------
# 有界等待。以前这里是死等的 until：boot_completed 万一不翻，脚本就永远挂在
# 这里 —— 不记日志、不报错，看上去像"模块没反应"。上限 120 秒；到点照实记一条
# 再照原样同步：带着已知风险继续比挂着有用，因为文件变化仍会再触发同步，
# 而这一趟结果可不可信，日志里写得清楚。
tries=0
until [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ] || [ "$tries" -ge 60 ]; do
    sleep 2
    tries=$((tries + 1))
done
if [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ]; then
    log_info "🚀 开机完成（等了 $((tries * 2)) 秒），执行首次同步"
else
    log_info "⚠️ 等了 $((tries * 2)) 秒 sys.boot_completed 仍不为 1，仍继续首次同步：结果可能不完整"
fi
dispatch_sync

# ---------- 事件监听 ----------
# 说明：单进程同时监听两个目录与常驻列表文件本身；进程异常退出后自动重启。
#       packages.list 也是被 PackageManager 以「临时文件 + 改名」方式重写的，
#       所以 /data/system 同样要按目录掩码监听，光看文件会漏掉改名。
(
    while true; do
        [ -d "$WATCH_DIR" ] || { sleep 5; continue; }
        mkdir -p "$RULES_DIR" 2>/dev/null
        ensure_rules_file "$RULES_FILE"

        # 事件按名字过滤：目录里其它文件（config.json / target.txt / .ts_tmp /
        # 各框架自己的 usage.json 等）的写入会落到 case 的默认分支被丢掉，
        # 不会触发同步；本模块自己的写入也就多一次 echo 进程，不成环。
        case "$INOTIFY_MODE" in
            inotifywait)
                # 挂目录：改名替换 rules.txt 时上报的是目录事件，挂文件会随旧 inode 一起失效
                $INOTIFY_CMD -m $WATCH_EVENTS "$WATCH_DIR" "$RULES_DIR" 2>/dev/null
                ;;
            *)
                # busybox/toybox 的 inotifyd 把 PROG 当程序执行，事件作为参数传入；
                # 这里用 echo 把「事件 + 路径」打到 stdout，再由本管道读取并匹配。
                # （旧写法传 "-" 不会产生任何输出，等于监听失效）
                # 文件与目录同时挂：就地改写走文件那条，改名替换走目录那条。
                $INOTIFY_CMD echo \
                    "$WATCH_DIR:$MASK_DIR" \
                    "$RULES_DIR:$MASK_DIR" \
                    "$RULES_FILE:$MASK_FILE" 2>/dev/null
                ;;
        esac |
            while read -r line; do
                # 只认「最后一个字段正好是这两个文件名」：
                #   目录事件行如 "y /data/adb/teesim rules.txt"（名字在行尾）
                #   文件事件行如 "x /data/adb/teesim/rules.txt"（路径在行尾）
                # 不能用裸子串匹配 —— sed -i 的临时文件叫 rules.txtXXXXXX，
                # 子串会把同目录里跟本次变更无关的临时文件也算成一次触发。
                last="${line##* }"
                case "$last" in
                    packages.list|rules.txt|*/packages.list|*/rules.txt) dispatch_sync ;;
                esac
            done
        sleep 3
    done
) &
echo $! >> "$PIDS_FILE"

log_info "✅ 守护进程就绪（日志：$TAA_LOG）"
exit 0
