#!/system/bin/sh
#=============================================================================
# lib/core.sh - 基础设施：路径常量、运行期状态、日志（logcat + 本地缓冲）
#=============================================================================

# ---------- 路径常量 ----------
TSTORE_DIR="/data/adb/tricky_store"      # Tricky Store / OSS 的数据目录
TEESIM_DIR="/data/adb/teesim"            # TEE Simulator 的数据目录
TEESIM_CONFIG="$TEESIM_DIR/config.json"  # TEE Simulator 配置文件

OMK_DIR="/data/misc/keystore/omk"        # OhMyKeymint 的运行时配置目录
OMK_INJECTOR="$OMK_DIR/injector.toml"    # 目标名单（scoop）所在文件
OMK_STATE_DIR="/data/adb/omk"            # OhMyKeymint 自己的守护进程状态目录（本模块也把 .kl_* 寄生在这里）
OMK_MODULE="/data/adb/modules/oh_my_keymint"

TRICKY_MODULE="/data/adb/modules/tricky_store"   # Tricky Store / OSS 模块 id
TEESIM_MODULE="/data/adb/modules/teesim"         # TEE Simulator 模块 id

LOCK_TIMEOUT=15               # 锁等待上限（秒）

# 日志缓冲（本地文件，用于事后排查 logcat 丢失的记录）
# 2026-10-30 改名 KeyLens：这三个文件从 ts_auto.* 换成 keylens.*。它们是**用户状态**，
# 不是临时文件 —— 属性伪装开关（存在=已关）与启动哈希丢了就是静默回到默认，
# 所以留一组 LEGACY 变量 + 一次性迁移，升级后行为不变。
KL_LOG="/data/adb/keylens.log"     # /data/adb 为 0700，仅 root 可读，其它应用无法访问
KL_LOG_MAX=65536                   # 缓冲上限（字节，64KB）
KL_LOG_KEEP=200                    # 超限后保留的末尾行数

# 属性伪装开关（文件存在 = 已关闭）：与日志缓冲同级，覆盖安装模块不会丢失
KL_PROPS_OFF="/data/adb/keylens.props_off"

# Verified Boot 哈希（文件不存在 = 不应用 ro.boot.vbmeta.digest）
KL_BOOT_HASH="/data/adb/keylens.boot_hash"

# 改名前的旧路径（只用于迁移与卸载清理，运行期不再读它们）
KL_LEGACY_LOG="/data/adb/ts_auto.log"
KL_LEGACY_PROPS_OFF="/data/adb/ts_auto.props_off"
KL_LEGACY_BOOT_HASH="/data/adb/ts_auto.boot_hash"

# 说明：旧名 → 新名的一次性搬家。只在**新名不存在**时动，所以反复调用是 no-op，
#       也不会覆盖用户已经在新路径上写过的东西。
#       后端目录里那批 .ts_* 是**运行期状态**（基线名单、ever 名单、指纹、已移除清单），
#       丢了不只是难看：手删过的应用会重新被加回名单，快照差分会当成第一次运行。
#       这里按目录扫，不依赖 detect_backend 的顺序（迁移在探测之前就要能跑）。
KL_BACKEND_DIRS="/data/adb/teesim /data/adb/tricky_store /data/misc/keystore/omk"

# 说明：一条搬家：只在新名不存在时 mv，源不存在就什么都不做。
#       为什么不用 `for pair in "旧|新"` 再 ${pair%%|*} 切：**Android 的 sh 把 | 当成"或"**，
#       两个展开都变成空串，迁移静默什么都不搬（本机 dash/bash 正常，所以只有真机测得出来）。
_mig() {
    [ -e "$1" ] || return 0
    [ -e "$2" ] && return 0
    mv -f "$1" "$2" 2>/dev/null
    return 0
}

migrate_legacy_paths() {
    local dir f base
    _mig "$KL_LEGACY_LOG" "$KL_LOG"
    _mig "$KL_LEGACY_PROPS_OFF" "$KL_PROPS_OFF"
    _mig "$KL_LEGACY_BOOT_HASH" "$KL_BOOT_HASH"
    for dir in $KL_BACKEND_DIRS; do
        [ -d "$dir" ] || continue
        for f in "$dir"/.ts_*; do
            [ -e "$f" ] || continue
            base=".kl_${f##*/.ts_}"
            [ -e "$dir/$base" ] && continue
            mv -f "$f" "$dir/$base" 2>/dev/null
        done
    done
    return 0
}

# ---------- 运行期状态 ----------
# 以下变量由 detect_backend 填充，其余为同步过程的中间结果
KL_BACKEND=""                # 当前后端：teesim | tricky | omk
KL_DIR=""                    # 后端目录（目标文件与运行文件所在）
TARGET_FILE=""                # 后端目标文件路径
AWK_CMD=""                    # 可用的 awk 命令（可能为空）
KL_PATCH=""                  # TEE Simulator 定点替换脚本路径
KL_COUNT=0                   # 最近一次生成的应用总数

# ---------- 日志 ----------
# 说明：日志写两处 —— logcat（tag 为 KeyLens）与本地缓冲文件 $KL_LOG。
#       写本地缓冲的原因：logcat 是内存环形缓冲，系统繁忙时旧记录会被挤掉、重启即清空，
#       事后排查往往已经看不到；缓冲文件容量固定、跨重启保留，更适合事后翻查。
#       缓冲文件位于 /data/adb（0700，仅 root 可读），超过 $KL_LOG_MAX 后自动裁剪为
#       末尾 $KL_LOG_KEEP 行，不会无限增长；不可写时静默退化为只写 logcat。
#       仅在开机与文件变化时写日志，无事件不写，因此不产生额外耗电。
# 用法：log_info|log_warn|log_err <消息>

# 说明：向缓冲文件追加一行；超过上限时先裁剪为末尾若干行。任何失败都静默忽略。
# 用法：_kl_log_append <整行文本>
_kl_log_append() {
    local size keep_tmp="${KL_LOG}.tmp"

    [ -d "${KL_LOG%/*}" ] || return 0

    if [ ! -f "$KL_LOG" ]; then
        : > "$KL_LOG" 2>/dev/null || return 0
        chmod 600 "$KL_LOG" 2>/dev/null
    else
        # 超限时裁剪：先写临时文件，成功才覆盖，避免裁剪失败导致日志全丢
        # （wc 的输出可能带空白或文件名，这里只保留数字，避免比较时出错）
        size=$(wc -c < "$KL_LOG" 2>/dev/null | tr -dc '0-9')
        if [ -n "$size" ] && [ "$size" -gt "$KL_LOG_MAX" ] 2>/dev/null; then
            if tail -n "$KL_LOG_KEEP" "$KL_LOG" > "$keep_tmp" 2>/dev/null; then
                chmod 600 "$keep_tmp" 2>/dev/null
                mv -f "$keep_tmp" "$KL_LOG" 2>/dev/null
            fi
            rm -f "$keep_tmp" 2>/dev/null
        fi
    fi

    printf '%s\n' "$1" >> "$KL_LOG" 2>/dev/null
}

# 说明：双写一条日志（level 为 logger 的级别名：info / warn / err）
# 用法：_kl_log <level> <消息>
_kl_log() {
    local level="$1" ts
    shift

    logger -t KeyLens -p "$level" "$*" 2>/dev/null || true

    ts=$(date '+%m-%d %H:%M:%S' 2>/dev/null)
    _kl_log_append "${ts:+$ts }$*"
}

log_info() { _kl_log info "$@"; }
log_warn() { _kl_log warn "$@"; }
log_err()  { _kl_log err  "$@"; }
