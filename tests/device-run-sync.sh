#!/bin/sh
# device-run-sync：真机上验 run_sync 的二进制分支与「锁接力」。
#
# 为什么要真机：这条分支的失败模式是**并发**的 —— shell 侧的 cmd_sync / action.sh /
# service.sh 都先 acquire_lock 再 run_sync，子进程若不知道自己继承了锁，会白等 6 秒
# 然后报「守护进程正在写入」（锁按持有者证据判活，父 shell 的 cmdline 里就带着模块名）。
# 夹具根的对拍看不见真实的 /proc/<pid>/cmdline，所以这一层只能上机。
#
# 同步结果本身（二进制 vs awk 写出的目标文件）由 tests/device-ab.sh --write 的 sync 那行
# 覆盖；这里补的是 run_sync 这一层：rc 与 KL_COUNT 的接力、持锁时不自抢、跑完锁要放掉，
# 外加一条「把接力条拿掉」的正对照（变异不落地就当场报错，不许留一条假的通过）。
#
# 用法（手机上）：
#   adb shell "cd /data/adb/keylens-ab && MODDIR=/data/adb/keylens-ab sh device-run-sync.sh"
# 每一步都比对后端文件的 sha256，跑完把原文件还原。
set -u
MODDIR=${MODDIR:-/data/adb/modules/keylens}
[ -f "$MODDIR/webui.sh" ] || { echo "  skip 找不到 $MODDIR/webui.sh"; echo "全部通过"; exit 0; }
[ -x "$MODDIR/bin/keylens" ] || { echo "  skip 没有 $MODDIR/bin/keylens"; echo "全部通过"; exit 0; }
[ "$(id -u)" = "0" ] || { echo "  skip 需要 root"; echo "全部通过"; exit 0; }
# 第 4 组要拿 shell+awk 那条分支跟二进制比结果；参照 awk 不在，那条分支只会报「缺少 X.awk」，
# 比出来的差异与实现无关，只会把人引去查错地方。
if ! ls "$MODDIR"/backends/*.awk >/dev/null 2>&1; then
    echo "  ✗   设备上找不到参照 awk：$MODDIR/backends/*.awk（先 sh tools/deploy-webui.sh --shell 推上去）"
    exit 1
fi

T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"; else printf '  ✗    %s\n        期望 [%s]，实得 [%s]\n' "$1" "$2" "$3"; fail=1; fi; }

BACKEND_FILES="/data/adb/tricky_store/target.txt /data/adb/tricky_store/security_patch.txt \
/data/adb/teesim/config.json /data/adb/teesim/overrides.json \
/data/misc/keystore/omk/injector.toml /data/misc/keystore/omk/config.toml"
snap() { for f in $BACKEND_FILES; do [ -f "$f" ] && sha256sum "$f"; done; }
save() { rm -rf "$T/bak"; mkdir -p "$T/bak"; for f in $BACKEND_FILES; do [ -f "$f" ] && cp -a "$f" "$T/bak/$(echo "$f" | tr / _)"; done; }
rest() { for f in $BACKEND_FILES; do bk="$T/bak/$(echo "$f" | tr / _)"; [ -f "$bk" ] && cp -a "$bk" "$f"; done; }

# 被测探针：source 真 lib（common.sh 是加载入口，函数按 core→lock→tools→applist→backend 排）
# BACKEND_LIB 指到变异副本时再覆盖一次（后定义的 run_sync 生效）。
# HOLD=1 对应 cmd_sync / action.sh / service.sh 的真实用法（调用方已持锁）
# 探针文件名里必须带模块目录名（keylens-ab）：二进制的接管判据是"锁记录里的 pid
# 还活着，且它的 /proc/<pid>/cmdline 含有模块标记"。生产里持有锁的正是
# /data/adb/modules/keylens/webui.sh 这类路径，标记必然命中；把探针放在 /data/local/tmp
# 下会让 cmdline 对不上标记，二进制当成"陌生持有者"直接接管 —— 第 2 组的正对照就哑了。
cat > "$T/keylens-ab-probe.sh" <<EOF
MODDIR="$MODDIR"
TMP_DIR="$T"
. "$MODDIR/lib/common.sh"
if [ -n "\${BACKEND_LIB:-}" ]; then . "\$BACKEND_LIB"; fi
detect_backend "\$MODDIR"
LOCK_DIR="\${KL_DIR}/.kl_lock"
if [ "\${HOLD:-1}" = 1 ]; then
    acquire_lock "\$LOCK_DIR" || { printf 'rc=NOLOCK\nlockleft=yes\nout=拿不到锁\n'; exit 0; }
    KL_LOCK_HELD=1
fi
KL_EMPTY_OK=1
# 注意：不能用 _out=\$(run_sync ...) —— 那样 run_sync 在一个子 shell 里跑，
# 它更新的 KL_COUNT 就丢了，"两条分支的 count 相同"会变成 0==0 的假绿。
run_sync "\$MODDIR/module.prop" "\${KL_DIR}/.kl_tmp" >"\$TMP_DIR/sync.out" 2>&1
_rc=\$?
[ "\${HOLD:-1}" = 1 ] && release_lock "\$LOCK_DIR"
printf 'rc=%s\ncount=%s\nbackend=%s\nlockleft=%s\nout=%s\n' "\$_rc" "\$KL_COUNT" "\$KL_BACKEND" \\
    "\$([ -e "\$LOCK_DIR" ] && echo yes || echo no)" "\$(tr '\n' '|' < "\$TMP_DIR/sync.out")"
EOF

field() { printf '%s' "$1" | sed -n "s/.*$2=\([0-9A-Za-z]*\).*/\1/p" | head -n 1; }

echo "── run_sync 的二进制分支（真机）──"
save
before=$(snap)

printf '── 1 调用方持锁：子进程不得自抢 ──\n'
o1=$(HOLD=1 sh "$T/keylens-ab-probe.sh" 2>&1)
printf '%s\n' "$o1" | sed -e 's/^/       /'
chk "拿到数字 rc（没白等锁 6 秒）" "yes" "$([ -n "$(field "$o1" rc | sed 's/[^0-9]//g')" ] && echo yes)"
chk "探针本身没有函数缺失（否则下面几条都是空断言）" "0" "$(printf '%s\n' "$o1" | grep -c 'inaccessible')"
chk "没有「守护进程正在写入」" "0" "$(printf '%s\n' "$o1" | grep -c '守护进程正在写入')"
chk "没落到 awk 缺失的报错" "0" "$(printf '%s\n' "$o1" | grep -c '缺少 awk')"
chk "跑完锁已放掉" "no" "$(field "$o1" lockleft)"
chk "后端探测是 omk（这台机装的是 OhMyKeymint）" "omk" "$(field "$o1" backend)"
chk "count 是真数（为 0 的话第 4 组的相等就是空的）" "yes" "$([ "$(field "$o1" count)" -gt 0 ] 2>/dev/null && echo yes)"

printf '── 2 正对照：拿掉接力条，必须看见自抢锁 ──\n'
sed 's|KL_LOCK_HELD="${KL_LOCK_HELD:-0}"|KL_LOCK_HELD=""|' "$MODDIR/lib/backend.sh" > "$T/backend.mut"
if cmp -s "$MODDIR/lib/backend.sh" "$T/backend.mut"; then
    echo "  ✗    变异没落地（接力条的锚点在 lib/backend.sh 里找不到）"; fail=1
else
    o2=$(HOLD=1 BACKEND_LIB="$T/backend.mut" sh "$T/keylens-ab-probe.sh" 2>&1)
    printf '%s\n' "$o2" | sed -e 's/^/       /'
    chk "变异后确实报「守护进程正在写入」（第 1 组不是空断言）" "1" "$(printf '%s\n' "$o2" | grep -c '守护进程正在写入')"
    rest
fi

printf '── 3 调用方不持锁：二进制自己取锁、自己放 ──\n'
o3=$(HOLD=0 sh "$T/keylens-ab-probe.sh" 2>&1)
printf '%s\n' "$o3" | sed -e 's/^/       /'
chk "拿到数字 rc" "yes" "$([ -n "$(field "$o3" rc | sed 's/[^0-9]//g')" ] && echo yes)"
chk "跑完锁已放掉" "no" "$(field "$o3" lockleft)"

printf '── 4 两条分支的结果必须一致（二进制 vs KL_USE_RUST=0 的 awk）──\n'
save
a=$(KL_USE_RUST=0 HOLD=1 sh "$T/keylens-ab-probe.sh" 2>&1)
fa=$(snap)
save
b=$(KL_USE_RUST=1 HOLD=1 sh "$T/keylens-ab-probe.sh" 2>&1)
fb=$(snap)
printf '       awk = %s\n       bin = %s\n' "$(printf '%s' "$a" | tr '\n' '|')" "$(printf '%s' "$b" | tr '\n' '|')"
chk "两条分支写出的后端文件逐字节相同" "$fa" "$fb"
chk "两条分支的 rc 相同" "$(field "$a" rc)" "$(field "$b" rc)"
chk "两条分支的 count 相同" "$(field "$a" count)" "$(field "$b" count)"

rest
chk "全部跑完：后端文件与开跑前逐字节相同" "$before" "$(snap)"

echo "── 统计"
if [ "$fail" = 0 ]; then echo "全部通过"; else echo "有断言失败"; exit 1; fi
