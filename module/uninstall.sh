#!/system/bin/sh
#=============================================================================
# uninstall.sh - 卸载清理（框架固定调用，必须位于模块根目录）
#
# 说明：只删除本模块自身的文件；target.txt / config.json 属于后端，保持不动。
#=============================================================================

TS="/data/adb/tricky_store"
SIM="/data/adb/teesim"

# ---------- 结束守护进程 ----------
for f in "$TS/.kl__daemon_pids.list" "$SIM/.kl__daemon_pids.list"; do
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
rm -rf "$TS/.kl__lock" "$TS/.kl__debounce" "$TS/.kl__tmp" \
       "$SIM/.kl__lock" "$SIM/.kl__debounce" "$SIM/.kl__tmp" \
       "/data/adb/omk/.kl__lock" "/data/adb/omk/.kl__debounce" "/data/adb/omk/.kl__tmp" 2>/dev/null
rm -f "/data/adb/omk/injector.toml.bak" 2>/dev/null
rm -f "$TS/.kl__fingerprint" "$SIM/.kl__fingerprint" 2>/dev/null
for f in .kl__installed_last .kl__rules_last .kl__written_last .kl__removed \
         .kl__installed.new .kl__rules.new .kl__written.new .kl__removed.new \
         .kl__ever .kl__ever.new .kl__fingerprint .kl__daemon_pids.list; do
    rm -f "$TS/$f" "$SIM/$f" "/data/adb/omk/$f" 2>/dev/null
done
rm -f "$TS/.last_month" "$TS/security_patch.txt.bak" 2>/dev/null
rm -f "$TS/rules.txt" "$SIM/rules.txt" "$TS/taa_sys.txt" 2>/dev/null
rm -f "/data/adb/service.d/taa_resetprop.sh" 2>/dev/null

# ---------- 删除日志缓冲、伪装开关与 boot hash ----------
# 新旧两组路径都删：改名前装的、升级后卸载的，不能把旧文件留在 /data/adb 里。
rm -f "/data/adb/keylens.log" "/data/adb/keylens.log.tmp" "/data/local/tmp/keylens.log" 2>/dev/null
rm -f "/data/adb/keylens.props_off" "/data/adb/keylens.boot_hash" 2>/dev/null
rm -f "/data/adb/ts_auto.log" "/data/adb/ts_auto.log.tmp" "/data/local/tmp/ts_auto.log" 2>/dev/null
rm -f "/data/adb/ts_auto.props_off" "/data/adb/ts_auto.boot_hash" 2>/dev/null

exit 0
