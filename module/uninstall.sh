#!/system/bin/sh
#=============================================================================
# uninstall.sh - 卸载清理（框架固定调用，必须位于模块根目录）
#
# 说明：只删除本模块自身的文件；target.txt / config.json 属于后端，保持不动。
#=============================================================================

TS="/data/adb/tricky_store"
SIM="/data/adb/teesim"

# ---------- 结束守护进程 ----------
for f in "$TS/.ts_daemon_pids.list" "$SIM/.ts_daemon_pids.list"; do
    [ -f "$f" ] || continue
    while read -r pid; do
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null
            sleep 0.1
            kill -9 "$pid" 2>/dev/null
        fi
    done < "$f"
    rm -f "$f" 2>/dev/null
done

# ---------- 结束残留的 inotify 进程 ----------
# 说明：匹配串必须带**我们自己的绝对路径**，不能用通名 "rules.txt"。
#       以前那两条是 inotifyd.*rules.txt —— 任何模块只要监听一个叫 rules.txt
#       的文件就会被一起杀掉（本模块的常驻列表与 Tricky Addon 之类正是同名）。
#       卸载是本模块的事，不该顺手停别人的监听。两个后端目录都列出来，
#       因为常驻列表跟着后端走。
pkill -f "inotifyd.*/data/adb/teesim/rules.txt" 2>/dev/null
pkill -f "inotifywait.*/data/adb/teesim/rules.txt" 2>/dev/null
pkill -f "inotifyd.*/data/adb/tricky_store/rules.txt" 2>/dev/null
pkill -f "inotifywait.*/data/adb/tricky_store/rules.txt" 2>/dev/null

# ---------- 删除本模块运行文件与常驻列表 ----------
rm -rf "$TS/.ts_lock" "$TS/.ts_debounce" "$TS/.ts_tmp" \
       "$SIM/.ts_lock" "$SIM/.ts_debounce" "$SIM/.ts_tmp" \
       "/data/adb/omk/.ts_lock" "/data/adb/omk/.ts_debounce" "/data/adb/omk/.ts_tmp" 2>/dev/null
rm -f "/data/adb/omk/injector.toml.bak" 2>/dev/null
rm -f "$TS/.ts_fingerprint" "$SIM/.ts_fingerprint" 2>/dev/null
for f in .ts_installed_last .ts_rules_last .ts_written_last .ts_removed \
         .ts_installed.new .ts_rules.new .ts_written.new .ts_removed.new \
         .ts_ever .ts_ever.new .ts_fingerprint .ts_daemon_pids.list; do
    rm -f "$TS/$f" "$SIM/$f" "/data/adb/omk/$f" 2>/dev/null
done
rm -f "$TS/.last_month" "$TS/security_patch.txt.bak" 2>/dev/null
rm -f "$TS/rules.txt" "$SIM/rules.txt" "$TS/taa_sys.txt" 2>/dev/null
rm -f "/data/adb/service.d/taa_resetprop.sh" 2>/dev/null

# ---------- 删除日志缓冲、伪装开关与 boot hash ----------
rm -f "/data/adb/ts_auto.log" "/data/adb/ts_auto.log.tmp" "/data/local/tmp/ts_auto.log" 2>/dev/null
rm -f "/data/adb/ts_auto.props_off" "/data/adb/ts_auto.boot_hash" 2>/dev/null

exit 0
