#!/system/bin/sh
#=============================================================================
# lib/lock.sh - 并发锁
#
# 用途：串行化同一后端的写入操作（守护进程、手动同步、安装脚本之间互斥）。
#=============================================================================

# ---------- 加锁 ----------
# 用法：acquire_lock <锁目录>
# 返回：0=取得锁，非 0=拿不到（调用方必须放弃这次写入，不能继续）
#
# 说明：以「目录原子创建」实现互斥。**超时不等于可以抢**：
#       以前等满 LOCK_TIMEOUT 就 rmdir 掉别人的锁再 mkdir —— 而 rmdir 对
#       "非空目录"会失败、对空目录会成功，锁目录平时正是空的，所以这一步
#       真的会把守护进程手里那把锁拆掉，然后我们"加锁成功"，两边同时做
#       整文件读-改-写（config.json / target.txt / injector.toml）。
#       表现是偶发的丢更新，且日志里一句错都没有。
#       现在锁里记持有者 pid，接管要有证据：持有者进程不在了，或者那个 pid
#       已经不是本模块的进程（pid 会被复用）。拿不出证据就退非 0。
acquire_lock() {
    local waited=0 pid=""

    while [ "$waited" -lt "$LOCK_TIMEOUT" ]; do
        if mkdir "$1" 2>/dev/null; then
            printf '%s' "$$" > "$1/pid" 2>/dev/null
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done

    pid=$(cat "$1/pid" 2>/dev/null)
    case "$pid" in ''|*[!0-9]*) pid="" ;; esac
    if [ -n "$pid" ] && kl_lock_holder_alive "$pid"; then
        log_warn "锁被进程 $pid 持有（等了 ${LOCK_TIMEOUT}s 仍不释放），这次不写入：$1"
        return 1
    fi
    log_warn "锁的持有者已不在（pid=${pid:-无记录}），接管：$1"
    rm -f "$1/pid" 2>/dev/null
    rmdir "$1" 2>/dev/null
    if mkdir "$1" 2>/dev/null; then
        printf '%s' "$$" > "$1/pid" 2>/dev/null
        return 0
    fi
    return 1
}

# 这个 pid 是否"确实是还活着的本模块进程"。两个条件都要满足：
#   kill -0 活着，且 /proc/<pid>/cmdline 里有本模块目录名（pid 会被复用，
#   单看 kill -0 会把一个毫不相干的进程当成持有者 —— 那样又会永远抢不到锁）。
# 读不到 cmdline 时按"活着"处理：宁可这次不写，也不能踩别人的锁。
kl_lock_holder_alive() {
    local p="$1" cl m mark="${KL_LOCK_MARK:-${MODDIR##*/}}"

    [ -n "$mark" ] && [ "$mark" != "/" ] || mark=keylens
    kill -0 "$p" 2>/dev/null || return 1
    if [ -r "/proc/$p/cmdline" ]; then
        cl=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)
        # 认的标记与"按 pid 收进程"共用同一份清单（core.sh 的 KL_OUR_MARKS）：
        # 升级前起的守护进程 cmdline 里还是旧名，只认新名会把它当成别人的进程。
        for m in "$mark" ${KL_OUR_MARKS:-}; do
            [ -n "$m" ] || continue
            case "$cl" in *"$m"*) return 0 ;; esac
        done
        return 1
    fi
    return 0
}

# ---------- 解锁 ----------
# 说明：只有"这把锁的 pid 记录是我"才释放。不是自己拿的锁就什么都不做 ——
#       否则超时后接管者的锁会被上一任持有者的一句 release_lock 拆掉。
# 用法：release_lock <锁目录>
release_lock() {
    local p
    p=$(cat "$1/pid" 2>/dev/null)
    [ "$p" = "$$" ] || return 0
    rm -f "$1/pid" 2>/dev/null
    rmdir "$1" 2>/dev/null || true
    return 0
}
