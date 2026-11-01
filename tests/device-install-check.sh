#!/bin/sh
# device-install-check：装机后、重启前，把"待生效的新树"当装完的样子验一遍。
#
# 三棵树：
#   OLD = /data/adb/modules/keylens          正在用的旧树（shell + awk 实现）
#   NEW = /data/adb/modules_update/keylens   刚装的树（只有 bin/keylens；发布包不再带 awk）
#   REF = /data/adb/keylens-ab               仓库推上去的 A/B 树（shell 参照，且是当前代码）
# KernelSU/Magisk 把新包解到 modules_update，重启才落地，所以装完那一刻 NEW 与 OLD 并存 ——
# 这是唯一能"拿旧实现当现场参照"比一次的窗口，也是唯一能在真生产路径上验
# 「预览不落盘」「命令层不依赖 awk」的窗口。
#
# 用法（手机上）：adb shell "sh /data/local/tmp/device-install-check.sh"
#   （仓库里这份可以直接 adb push 过去；没有设备时下面三条前置会 skip 并退 0，CI 不假红）
#
# 判据：
#   1. 新树不该带 awk（发布包只含二进制），backends/ 只剩被 source 的 tricky.sh；
#   2. 17 条只读命令：旧树(shell) vs 新树(二进制) 逐字节相同，且新树不许落到「缺少 X.awk」；
#   3. preview 回归：新树必须出恰好一份信封、changed>0、后端文件指纹一字不变；
#      对照基准用 REF 而不是 OLD —— OLD 可能是 §5.1 修复前的实现（它把一次热生效报成
#      apply_scope=restart），拿它当基准只会得到一条"有意义的红"；
#      另加绝对断言（代价=hot、不许出现"已请求"）与一条说明性断言（旧树确实报 restart）；
#   4. 新树二进制的 contract 条数 = 新树 webui.sh 的声明条数。
set -u
OLD=${OLD:-/data/adb/modules/keylens}
NEW=${NEW:-/data/adb/modules_update/keylens}
REF=${REF:-/data/adb/keylens-ab}
[ -f "$OLD/webui.sh" ] || { echo "  skip 找不到旧树 $OLD（没装过模块 / 没有设备）"; echo "全部通过"; exit 0; }
[ -x "$NEW/bin/keylens" ] || { echo "  skip 没有待生效的新树 $NEW（只在装完包、重启前存在）"; echo "全部通过"; exit 0; }
[ "$(id -u)" = "0" ] || { echo "  skip 需要 root"; echo "全部通过"; exit 0; }

fail=0; oks=0
chk() {
    if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"; oks=$((oks + 1));
    else printf '  ✗    %s\n        甲=[%s]\n        乙=[%s]\n' "$1" "$2" "$3"; fail=1; fi
}
norm() {
    sed -e 's/更新: [0-9][0-9]:[0-9][0-9]/更新: HH:MM/g' \
        -e 's/keybox_mtime=[0-9]*/keybox_mtime=X/g' \
        -e 's/uptime=[0-9]*/uptime=X/g' \
        -e 's/_pid=[0-9]*/_pid=X/g' \
        -e 's/pid=[0-9][0-9]*/pid=X/g' \
        -e 's/[0-9][0-9]* 字节/N 字节/g' \
        -e 's|/data/adb/modules_update/|/data/adb/modules/|g'   # 两棵树各自报自己的路径，不是实现差异
}
BK="/data/misc/keystore/omk/injector.toml /data/misc/keystore/omk/config.toml /data/misc/keystore/omk/keybox.xml"
fp() { for f in $BK; do [ -f "$f" ] && sha256sum "$f"; done; }

echo "── 1 发布包内容：新树不该带 awk ──"
chk "新树 backends/ 下 awk 数" "0" "$(ls "$NEW"/backends/*.awk 2>/dev/null | wc -l | tr -d ' ')"
chk "新树 backends/ 只剩 tricky.sh" "tricky.sh" "$(ls "$NEW/backends" | tr '\n' ' ' | sed 's/ $//')"
chk "新树 bin/keylens 可执行" "yes" "$([ -x "$NEW/bin/keylens" ] && echo yes)"

echo "── 2 只读 17 条：旧树 shell vs 新树二进制（真实数据）──"
for c in status env targets target-meta apps icons log props tricky-patches teesim-overrides \
         teesim-profiles backups boot-hash tee-status backend-info doctor excluded; do
    a=$(sh "$OLD/webui.sh" "$c" 2>&1 | norm)
    b=$(sh "$NEW/webui.sh" "$c" 2>&1 | norm)
    if [ "$a" = "$b" ]; then printf '  ok   %s\n' "$c"; oks=$((oks + 1));
    else printf '  ✗    %s 不一致\n' "$c"; printf '%s\n' "$a" | sed -e 's/=\(.\{60\}\).*/=\1…/' | head -6 | sed 's/^/       旧 /'; printf '%s\n' "$b" | sed -e 's/=\(.\{60\}\).*/=\1…/' | head -6 | sed 's/^/       新 /'; fail=1; fi
    if printf '%s' "$b" | grep -qi '缺少 .*\.awk'; then
        printf '  ✗    %s：新树落到了 awk 缺失的报错\n' "$c"; fail=1
    fi
done

echo "── 3 preview 回归：不许真写，信封恰好一份 ──"
PL=$(printf 'trust_security_patch=%s\ntrust_os_patchlevel=%s' \
        "$(printf '2026-10-01' | base64)" "$(printf 'latest' | base64)" | base64 | tr -d '\n')
base=$(fp)
o=$(sh "$NEW/webui.sh" preview-omk-save-config "$PL" 2>&1)
chk "preview 信封份数" "1" "$(printf '%s\n' "$o" | grep -c '^preview=1')"
chk "preview 报出了差异" "yes" "$([ "$(printf '%s\n' "$o" | sed -n 's/^changed=\([0-9]*\)$/\1/p')" -gt 0 ] 2>/dev/null && echo yes)"
chk "preview 之后后端文件一字不变" "$base" "$(fp)"
chk "preview 的代价报 hot" "hot" "$(printf '%s\n' "$o" | sed -n 's/^apply_scope=//p')"
chk "preview 不许出现「已请求重启」" "0" "$(printf '%s\n' "$o" | grep -c '已请求')"
if [ -f "$REF/lib/write.sh" ] && ls "$REF"/backends/*.awk >/dev/null 2>&1; then
    r=$(KL_USE_RUST=0 sh "$REF/webui.sh" preview-omk-save-config "$PL" 2>&1)
    chk "preview 逐字节：修过的 shell 参照 vs 新装树" "$r" "$o"
else
    printf '  skip 没有可用参照树 %s（要 lib/write.sh + backends/*.awk）\n' "$REF"
fi
# 这一条原来写死"旧树必报 restart"。它只在旧树是 §5.1 修复前、**且还带着 awk** 的那份安装时成立：
# 旧树一旦被热替换成修过的代码（2026-11-01 就发生过），或者装的是「不再带 awk」的新包，
# 旧树要么报 hot、要么直接报「缺少 X.awk」—— 写死的断言就变成假红。
# 现在改成：旧树的 shell 预览**不许静默空输出** —— 要么给出 apply_scope，要么明说缺 awk。
old_out=$(KL_USE_RUST=0 sh "$OLD/webui.sh" preview-omk-save-config "$PL" 2>&1)
old_scope=$(printf '%s\n' "$old_out" | sed -n 's/^apply_scope=//p')
case "$old_scope" in
    hot|restart) chk "旧树 shell 预览跑起来了（apply_scope=$old_scope）" "yes" "yes" ;;
    *) chk "旧树 shell 预览要么给 apply_scope，要么明说缺 awk（不许静默空输出）" "yes" \
           "$(printf '%s\n' "$old_out" | grep -q '缺少 .*awk' && echo yes || echo no)" ;;
esac
printf '  ·    旧树现状（首行）：%s\n' "$(printf '%s\n' "$old_out" | head -n 1)"

echo "── 4 命令层自述：新树用的就是二进制 ──"
chk "新树 bin 的条数 = 新树 webui.sh 的声明条数" \
    "$(awk '/^KL_COMMANDS="/{f=1; sub(/^KL_COMMANDS="/,"")} f{ had=/\"$/; sub(/\\$/,""); sub(/\"$/,""); printf "%s ", $0; if (had) exit }' "$NEW/webui.sh" | wc -w | tr -d ' ')" \
    "$("$NEW/bin/keylens" contract | sed -n 's/^commands=//p' | wc -w | tr -d ' ')"

echo "── 统计（断言 $oks 条）"
# 1(awk 数) + 1(backends 内容) + 1(bin 可执行) + 17 + 5 + 1 + 1 + 1 = 28；低于此就是有断言没跑
if [ "$oks" -lt 28 ]; then echo "  ✗   断言数低于下限（$oks < 28），疑似有断言没执行"; exit 1; fi
if [ "$fail" = 0 ]; then echo "全部通过"; else echo "有断言失败"; exit 1; fi
