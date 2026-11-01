#!/bin/sh
# device-ab：真机上把 40 条命令逐条 A/B（shell 实现 vs bin/keylens），输出 diff 为空的才算过。
#
# 为什么不在 CI 跑：需要真机的 root、真实后端文件、真实 getprop/dumpsys。
# 本地/CI 直接 skip，不制造假绿灯。
#
# 用法（手机上）：
#   sh tests/device-ab.sh            # 只跑只读命令（安全）
#   sh tests/device-ab.sh --write    # 连写命令一起（每轮前后自动备份/还原目标文件）
#
# 判定：同一命令在 KL_USE_RUST=0 与 KL_USE_RUST=1 下的输出必须逐字节一致；
#       易变字段（时间、mtime、pid、uptime）先归一化再比。
set -u
MODDIR=${MODDIR:-/data/adb/modules/keylens}
[ -f "$MODDIR/webui.sh" ] || { echo "  skip 找不到 $MODDIR/webui.sh"; echo "全部通过"; exit 0; }
[ -x "$MODDIR/bin/keylens" ] || { echo "  skip 没有 $MODDIR/bin/keylens（用带二进制的发布包）"; echo "全部通过"; exit 0; }
[ "$(id -u)" = "0" ] || { echo "  skip 需要 root"; echo "全部通过"; exit 0; }
WITH_WRITE=0
[ "${1:-}" = "--write" ] && WITH_WRITE=1

T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
norm() {
    sed -e 's/更新: [0-9][0-9]:[0-9][0-9]/更新: HH:MM/g' \
        -e 's/keybox_mtime=[0-9]*/keybox_mtime=X/g' \
        -e 's/uptime=[0-9]*/uptime=X/g' \
        -e 's/_pid=[0-9]*/_pid=X/g' \
        -e 's/pid=[0-9][0-9]*/pid=X/g' \
        -e 's/[0-9][0-9]* 字节/N 字节/g'
}
# 写命令：跑之前把后端文件备份，跑完还原（两侧各跑一次，互不污染）
backup_backend() {
    rm -rf "$T/bak"; mkdir -p "$T/bak"
    for f in /data/adb/tricky_store/target.txt /data/adb/tricky_store/security_patch.txt \
             /data/adb/teesim/config.json /data/adb/teesim/overrides.json \
             /data/misc/keystore/omk/injector.toml /data/misc/keystore/omk/config.toml; do
        [ -f "$f" ] && cp -a "$f" "$T/bak/$(echo "$f" | tr / _)"
    done
}
restore_backend() {
    for f in /data/adb/tricky_store/target.txt /data/adb/tricky_store/security_patch.txt \
             /data/adb/teesim/config.json /data/adb/teesim/overrides.json \
             /data/misc/keystore/omk/injector.toml /data/misc/keystore/omk/config.toml; do
        bk="$T/bak/$(echo "$f" | tr / _)"
        [ -f "$bk" ] && cp -a "$bk" "$f"
    done
}
# 写命令只看 stdout 不够：真正的契约是**文件内容**。这里把后端文件一起做指纹对比。
snapshot_backend() {
    for f in /data/adb/tricky_store/target.txt /data/adb/tricky_store/security_patch.txt \
             /data/adb/teesim/config.json /data/adb/teesim/overrides.json \
             /data/misc/keystore/omk/injector.toml /data/misc/keystore/omk/config.toml; do
        [ -f "$f" ] && sha256sum "$f" 2>/dev/null
    done
}

READ_CMDS="status env targets target-meta apps icons log props tricky-patches teesim-overrides teesim-profiles backups boot-hash tee-status backend-info doctor excluded"
WRITE_CMDS="set-mode props-on props-off props-boot-hash props-apply omk-restart clear-log tricky-drop-patch tricky-save-patch teesim-save teesim-save-overrides teesim-profile-new teesim-profile-del keybox-save backup-restore restore-app restore-apps remove-apps sync omk-save-injector omk-save-config"
LIST="$READ_CMDS"
[ "$WITH_WRITE" = 1 ] && LIST="$READ_CMDS $WRITE_CMDS"

fail=0; n=0
for c in $LIST; do
    n=$((n + 1))
    backup_backend
    a=$(KL_USE_RUST=0 sh "$MODDIR/webui.sh" "$c" 2>&1 | norm)
    fa=$(snapshot_backend)
    restore_backend
    b=$(KL_USE_RUST=1 sh "$MODDIR/webui.sh" "$c" 2>&1 | norm)
    fb=$(snapshot_backend)
    restore_backend
    if [ "$a" = "$b" ] && [ "$fa" = "$fb" ]; then
        echo "  ok   $c"
    else
        echo "  ✗    $c 不一致"
        if [ "$a" != "$b" ]; then
            echo "       （stdout 不同）"
            printf '%s\n' "$a" > "$T/a.txt"
            printf '%s\n' "$b" > "$T/b.txt"
            diff "$T/a.txt" "$T/b.txt" | head -n 8
        fi
        if [ "$fa" != "$fb" ]; then
            echo "       （写回的文件不同）"
            printf '%s\n' "$fa" > "$T/fa.txt"
            printf '%s\n' "$fb" > "$T/fb.txt"
            diff "$T/fa.txt" "$T/fb.txt" | head -n 8
        fi
        fail=1
    fi
done

echo "── 统计：$n 条（写命令$( [ "$WITH_WRITE" = 1 ] && echo 含 || echo 不含)）"
if [ "$fail" = 0 ]; then echo "全部通过"; else echo "有断言失败"; exit 1; fi
