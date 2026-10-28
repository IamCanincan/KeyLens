#!/system/bin/sh
#=============================================================================
# service.sh - 后台守护（事件驱动 · 无联网）
#
# 职责：
#   1. 开机后执行一次同步并刷新模块描述
#   2. 单进程监听 /data/system/packages.list
#   3. 仅在源数据真正变化时同步（指纹比对 + 防抖）
#
# 说明：入口脚本由框架固定调用，必须位于模块根目录。
#=============================================================================

MODDIR="${0%/*}"
PROP_FILE="$MODDIR/module.prop"
WATCH_DIR="/data/system"

# 框架调 service.sh 时不带 umask（实测本机运行时文件落成了 0666），而本模块
# 的运行时文件（pids 名单、指纹、临时文件）只给 root 自己看。customize.sh:50
# 安装时就是 umask 077，这里对齐，别让同一模块的两套文件两种权限。
# 注意：**webui.sh 不加这条** —— 它导出的 webroot/icons/*.png 现在是 0644，
# 管理器怎么读到它们的（复制 webroot 还是就地读）没有实测过，
# 在没验之前把 022 收紧成 077 有可能直接把图标弄黑。
umask 077

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
# 说明：现在只监听一个东西 —— /data/system/packages.list（安装/卸载的唯一信号）。
#       常驻那一层已经去掉，名单只有目标文件本身，不需要第二个监视点。
#       监视挂在**目录**上：这个文件是「写临时文件再改名」替换的，而 inotify 的
#       监视点绑 inode，挂文件会随旧 inode 一起失效。
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

# ---------- 变更检测 ----------
# 说明：以 packages.list 的包名集合生成指纹，用于过滤系统频繁改写这个文件造成的
#       无谓同步。名单只有目标文件，这里不再掺别的输入。
# 用法：get_source_fingerprint
get_source_fingerprint() {
    cut -d' ' -f1 "$WATCH_DIR/packages.list" 2>/dev/null | sort -u | cksum 2>/dev/null | cut -d' ' -f1
}

# ---------- 同步核心 ----------
# 说明：指纹未变化则直接返回；失败时不记录指纹，便于下次重试。
# 用法：do_sync
do_sync() {
    local fp rc old

    fp=$(get_source_fingerprint)
    old=$(cat "$FP_FILE" 2>/dev/null)
    if [ -n "$fp" ] && [ "$fp" = "$old" ]; then
        # 这一行必须有：否则"开机执行首次同步"后面一片空白，读日志的人分不清
        # 是卡住了、没跑、还是跑了但没变化（实测本机重启后就是这种情况）。
        log_info "ℹ️ 源数据与上次一致（指纹 $fp），跳过同步"
        return 0
    fi

    log_info "🔄 开始应用列表同步"
    run_sync "$PROP_FILE" "$TMP"
    rc=$?
    case "$rc" in
        0) log_info "✅ 同步完成，应用总数：$TAA_COUNT" ;;
        1) log_info "ℹ️ 列表内容一致，本次未落盘" ;;
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
# 结束上次遗留的守护进程，并清理运行文件。
# 记在名单里的是那个 while 子壳；管道左边的 inotifyd / inotifywait 不在名单里，
# 只按 PID 收会留下一个还在往管道里写的孤儿监视。所以下面再按旧版的监视规格收一次。
if [ -f "$PIDS_FILE" ]; then
    while read -r pid; do
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
    done < "$PIDS_FILE"
    rm -f "$PIDS_FILE" 2>/dev/null
fi
# 旧版（还有 rules.txt 那一层时）起的监视挂着 rules.txt，升级后必须收掉，
# 否则会有两个守护同时触发同步。这里写死旧路径 —— RULES_FILE 已经删了，
# 用空变量会变成 "inotifyd.*" 而把系统里所有 inotifyd 都杀掉。
pkill -f "inotifyd.*/data/adb/teesim/rules.txt" 2>/dev/null
pkill -f "inotifywait.*/data/adb/teesim/rules.txt" 2>/dev/null
pkill -f "inotifyd.*/data/adb/tricky_store/rules.txt" 2>/dev/null
pkill -f "inotifywait.*/data/adb/tricky_store/rules.txt" 2>/dev/null
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
#
#       重启要**留痕并退避**。以前这里是无声的 3 秒一轮：监视起不来（watch 数
#       超限、目录被卸载、参数不被接受）时日志里一个字都不会多，表现就是
#       "装了应用但列表不动"，而排查的人只看到最后一行"守护进程就绪"。
#       活过 WATCH_ALIVE 秒算正常一轮、计数清零；连续失败按 lib/watch.sh 的
#       next_backoff 退避（3→6→12→24→48→60 秒封顶），第 2 次起记一条 warn。
#       公式放在 lib/watch.sh 里而不是这里：那是个纯函数，tests/watch-backoff.sh
#       直接 source 它逐档断言，线上跑的就是被测的那一份。
watch_fails=0
(
    while true; do
        [ -d "$WATCH_DIR" ] || { sleep 5; continue; }
        watch_started=$(date +%s 2>/dev/null)

        # 事件按名字过滤：目录里其它文件（config.json / target.txt / .ts_tmp /
        # 各框架自己的 usage.json 等）的写入会落到 case 的默认分支被丢掉，
        # 不会触发同步；本模块自己的写入也就多一次 echo 进程，不成环。
        case "$INOTIFY_MODE" in
            inotifywait)
                $INOTIFY_CMD -m $WATCH_EVENTS "$WATCH_DIR" 2>/dev/null
                ;;
            *)
                # busybox/toybox 的 inotifyd 把 PROG 当程序执行，事件作为参数传入；
                # 这里用 echo 把「事件 + 路径」打到 stdout，再由本管道读取并匹配。
                $INOTIFY_CMD echo "$WATCH_DIR:$MASK_DIR" 2>/dev/null
                ;;
        esac |
            while read -r line; do
                # 只认「最后一个字段正好是 packages.list」（目录事件行把名字放在行尾）。
                # 不能用裸子串匹配 —— /data/system 里还有别的文件在频繁写。
                last="${line##* }"
                case "$last" in
                    packages.list|*/packages.list) dispatch_sync ;;
                esac
            done

        # 走到这里说明监听进程退出了（正常情况下它永不返回）
        now=$(date +%s 2>/dev/null)
        if [ -n "$watch_started" ] && [ -n "$now" ] && [ $((now - watch_started)) -ge $WATCH_ALIVE ]; then
            watch_fails=0                       # 活够久了：算正常一轮，清零
        else
            watch_fails=$((watch_fails + 1))
        fi
        backoff=$(next_backoff "$watch_fails")     # 一次取值，日志与 sleep 用同一个数
        if [ "$watch_fails" -ge 2 ]; then
            log_warn "⚠️ 监听进程第 $watch_fails 次退出，$backoff 秒后重启：这段时间的安装/卸载不会自动进列表"
        fi
        sleep $backoff
    done
) &
echo $! >> "$PIDS_FILE"

log_info "✅ 守护进程就绪（日志：$TAA_LOG）"
exit 0
