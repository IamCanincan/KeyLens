#!/bin/sh
# device-ab：真机上把 41 条命令逐条 A/B（shell 实现 vs bin/keylens），输出 diff 为空的才算过。
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
# 参照 awk 自阶段 5 起不随模块发布（在 tests/fixtures/backends），A/B 的 shell 那半边靠它。
# 实测少了它不是沉默通过，而是 17 条里 6 条红、差异看着像 Rust 实现写坏了（targets 整列空、
# backend-info 的 target_entries=0…）。与其让人去查代码，不如开跑前一句说清缺什么。
if ! ls "$MODDIR"/backends/*.awk >/dev/null 2>&1; then
    echo "  ✗   设备上找不到参照 awk：$MODDIR/backends/*.awk"
    echo "      推上去再来（sh tools/deploy-webui.sh --shell 会连参照一起推进 backends/）"
    exit 1
fi
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

READ_CMDS="status env targets target-meta apps icons log props tricky-patches teesim-overrides teesim-profiles backups boot-hash tee-status backend-info doctor excluded exclude-suggest"
WRITE_CMDS="set-mode props-on props-off props-boot-hash props-apply omk-restart clear-log tricky-drop-patch tricky-save-patch teesim-save teesim-save-overrides teesim-profile-new teesim-profile-del keybox-save backup-restore restore-app restore-apps remove-apps sync omk-save-injector omk-save-config"
LIST="$READ_CMDS"
[ "$WITH_WRITE" = 1 ] && LIST="$READ_CMDS $WRITE_CMDS"

# 用户状态（不是后端文件）：属性伪装开关与 Verified Boot 哈希配置。--write 那串里有
# props-on / props-off / props-boot-hash，跑完会停在"最后一条命令"的形状 —— 2026-11-01 就这么
# 把主人的属性伪装关掉、boot hash 清空了一次，直到重启后属性全变 diff/missing 才暴露。
# 所以单独快照 + 还原，并且**断言还原到位**（状态类副作用不许靠人记得）。
snapshot_flags() {
    _po=no; [ -f /data/adb/keylens.props_off ] && _po=yes
    _bh=""; [ -f /data/adb/keylens.boot_hash ] && _bh=$(tr -d '[:space:]' < /data/adb/keylens.boot_hash)
    _pc=$(sh "$MODDIR/webui.sh" props 2>/dev/null | awk -F'\t' 'NF>1 && $4!="ok" {c++} END{print c+0}')
    # 运行期属性值本身也要快照：props-apply 的"正确结果"就是改它们。2026-11-02 期望表
    # 补了分区 type/flavor/fingerprint 之后，第一次 --write 就报"跑前 10、跑后 0"——
    # 那条不变量是对的，缺的是还原。键名取自表本身（props 页的第一列），不写死清单。
    sh "$MODDIR/webui.sh" props 2>/dev/null | cut -f1 | LC_ALL=C sort -u > "$T/props.keys"
    while read -r k; do
        [ -n "$k" ] || continue
        printf '%s\t%s\n' "$k" "$(getprop "$k")"
    done < "$T/props.keys" > "$T/props.vals"
    _nkeys=$(grep -ac . "$T/props.vals")
}
restore_flags() {
    if [ "$_po" = yes ]; then
        : > /data/adb/keylens.props_off; chmod 600 /data/adb/keylens.props_off 2>/dev/null
    else
        rm -f /data/adb/keylens.props_off
    fi
    if [ -n "$_bh" ]; then
        sh "$MODDIR/webui.sh" props-boot-hash "$_bh" >/dev/null 2>&1
    else
        rm -f /data/adb/keylens.boot_hash
    fi
    # props-off 不回滚运行期值、props-boot-hash - 会清 digest ⇒ 跑完再应用一次
    sh "$MODDIR/webui.sh" props-apply >/dev/null 2>&1
    # 再把运行期属性逐个退回快照值（resetprop -n 只改内存，重启回系统原值）
    while IFS='	' read -r k v; do
        [ -n "$k" ] || continue
        [ "$(getprop "$k")" = "$v" ] || resetprop -n "$k" "$v" 2>/dev/null
    done < "$T/props.vals"
}

fail=0; n=0
[ "$WITH_WRITE" = 1 ] && snapshot_flags
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

if [ "$WITH_WRITE" = 1 ]; then
    restore_flags
    _po2=no; [ -f /data/adb/keylens.props_off ] && _po2=yes
    _bh2=""; [ -f /data/adb/keylens.boot_hash ] && _bh2=$(tr -d '[:space:]' < /data/adb/keylens.boot_hash)
    _pc2=$(sh "$MODDIR/webui.sh" props 2>/dev/null | awk -F'\t' 'NF>1 && $4!="ok" {c++} END{print c+0}')
    # 逐个属性值再比一次（比"差项数相同"强：数一样但值被换过，这条会抓）
    while read -r k; do
        [ -n "$k" ] || continue
        printf '%s\t%s\n' "$k" "$(getprop "$k")"
    done < "$T/props.keys" > "$T/props.vals2"
    [ "$_po" = "$_po2" ] && echo "  ok   属性伪装开关已还原（props_off=$_po）" \
        || { echo "  ✗   属性伪装开关没还原：跑前 $_po、跑后 $_po2"; fail=1; }
    [ "$_bh" = "$_bh2" ] && echo "  ok   boot_hash 已还原（${_bh:-未配置}）" \
        || { echo "  ✗   boot_hash 没还原：跑前 [${_bh}]、跑后 [${_bh2}]"; fail=1; }
    if cmp -s "$T/props.vals" "$T/props.vals2"; then
        echo "  ok   运行期属性逐个回到跑前（$_nkeys 个键逐字节相同）"
    else
        echo "  ✗   运行期属性没回到跑前，差异：$(awk 'NR==FNR{a[FNR]=$0;n=FNR;next} FNR<=n && a[FNR]!=$0 {print; exit}' "$T/props.vals" "$T/props.vals2")"
        fail=1
    fi
    [ "$_pc" = "$_pc2" ] && echo "  ok   属性差项数与跑前相同（非 ok = $_pc）" \
        || { echo "  ✗   属性差项数变了：跑前 $_pc、跑后 $_pc2"; fail=1; }
fi

echo "── 统计：$n 条（写命令$( [ "$WITH_WRITE" = 1 ] && echo 含 || echo 不含)）"
if [ "$fail" = 0 ]; then echo "全部通过"; else echo "有断言失败"; exit 1; fi
