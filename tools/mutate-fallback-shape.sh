#!/bin/sh
# tools/mutate-fallback-shape.sh —— 给 tests/fallback-shape.sh 做变异测试（本地按需跑，不进 CI）
#
# 目的：证明这套闸"有牙"。每一颗变异就是把这一轮修好的那一行**改回修之前的写法**，
# 套件的对应断言必须变红；还原之后必须重新全绿。
# 每颗变异都自证命中数（恰好 1 处）+ 自证落地（原文再无残留）——
# 命中 0 处时你拿到的是"6 条断言全红"这种假信号，而不是"这颗变异没生效"。
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
B="$ROOT/module/lib/backend.sh"
A="$ROOT/module/lib/applist.sh"
W="$ROOT/module/webui.sh"
S="$ROOT/tests/fallback-shape.sh"
BK=$(mktemp -d)
LOG="$BK/log"
cp "$B" "$BK/backend.sh"; cp "$A" "$BK/applist.sh"; cp "$W" "$BK/webui.sh"; cp "$S" "$BK/suite.sh"
GLOBAL_FAIL=0

restore() { cp "$BK/backend.sh" "$B"; cp "$BK/applist.sh" "$A"; cp "$BK/webui.sh" "$W"; cp "$BK/suite.sh" "$S"; }
trap 'restore; rm -rf "$BK"' EXIT

hitcount() { grep -c -a -F "$2" "$1"; }        # -F 字面量；-a 见 memory：中文日志会被当二进制

apply() {   # apply <文件> <原文> <改后> —— 命中数必须恰好 1，且改完必须没有残留
    n=$(hitcount "$1" "$2")
    if [ "$n" != "1" ]; then
        printf '  ✗ 变异没落地：%s 在 %s 里命中 %s 处（应为 1）\n' "$2" "${1##*/}" "$n"
        GLOBAL_FAIL=1; return 1
    fi
    sed -i "s%$2%$3%" "$1"
    if [ "$(hitcount "$1" "$2")" != "0" ]; then
        printf '  ✗ 变异没写进 %s\n' "${1##*/}"; GLOBAL_FAIL=1; return 1
    fi
    if [ ! -s "$1" ]; then printf '  ✗ %s 被 sed 清空了（立刻还原）\n' "${1##*/}"; restore; GLOBAL_FAIL=1; return 1; fi
    return 0
}

report() {   # report <变异名> <日志> <必须变红的断言关键字…>
    # 关键字要写**失败分支**那句：chk/chk_rc 失败时打印的是 no "名字"，而形如
    # `[ x ] && ok "A" || no "B"` 的断言，A 和 B 是两个不同的说法 —— 拿 A 当判据
    # 会得到"变异没被抓住"的假信号（这一版里连错三处：M2/M4/M3c）。
    _name="$1"; _log="$2"; shift 2
    _miss=""
    for _k in "$@"; do
        grep -q -a "✗.*$_k" "$_log" || _miss="$_miss「$_k」"
    done
    if [ -z "$_miss" ]; then
        printf '  ok   %-4s 抓住：%s\n' "$_name" "$*"
    else
        printf '  ✗    %-4s 没被这套闸抓住：%s\n' "$_name" "$_miss"
        grep -a -E '^(──|  ✗)' "$_log" | sed 's/^/         /'
        GLOBAL_FAIL=1
    fi
    restore
}

run_suite() { sh "$S" > "$LOG" 2>&1; }

echo "── 变异：把修好的一行改回修之前的写法，套件必须变红 ──"

# M1 current_target_apps 缺参照时又「return 0」（把空名单当成功交回去）
if apply "$B" 'kl_ref_ok omk_list.awk || return 2' 'kl_ref_ok omk_list.awk || return 0'; then
    run_suite; report M1 "$LOG" "omk：退码非 0" "只缺 list 参照时读仍然报错"
fi

# M2 add_target_apps 又拿读不到的基线去写 —— 这次 129 条事故的正主
if apply "$B" '_cta=$(current_target_apps) || return 2' '_cta=$(current_target_apps 2>/dev/null || true)'; then
    run_suite; report M2 "$LOG" "基线读不到 → 加入必须拒绝" "原有条目被吃掉了" "名单没被重写成只剩新加的那一条"
fi

# M3a build_app_list 的守卫单点删除 —— 同步还有第二道守卫（sync_omk_injector 自己带退码），
#     所以这一颗变异**预期是绿的**（纵深防御，不是漏检）。写在这里是为了下一次谁想"把
#     冗余的那道删掉"时能看到：删了它，M3b 就会从绿变红。
if apply "$A" '_kl_cur=$(current_target_apps) || { rm -f "$tmp" 2>/dev/null; return 2; }' '_kl_cur=$(current_target_apps 2>/dev/null || true)'; then
    run_suite
    if grep -q -a '✗' "$LOG"; then
        printf '  ok   M3a  单删 applist 守卫也被抓住了（比预期更严）\n'
    else
        printf '  ok   M3a  单删 applist 守卫仍全绿 —— 由 sync_omk_injector 那道兜住（记录：两道守卫是纵深，不是重复）\n'
    fi
    restore
fi

# M3b 只删 sync_omk_injector 那道守卫 —— 和 M3a 对称：还剩 applist 那道，预期也是绿的。
#     两颗"单删"记在这里是有原因的：它说明同步这条路有两道独立守卫，谁想省事删一道，
#     看到的不是红，而是 M3c 会从绿变红这件事变成唯一防线。
if apply "$B" '_cn=$(current_target_apps 2>/dev/null) || { rm -f "$tmp" 2>/dev/null; return 2; }' '_cn=$(current_target_apps 2>/dev/null || true)'; then
    run_suite
    if grep -q -a '✗' "$LOG"; then
        printf '  ok   M3b  单删 sync 守卫也被抓住了（比预期更严）\n'
    else
        printf '  ok   M3b  单删 sync 守卫仍全绿 —— 由 applist 那道兜住\n'
    fi
    restore
fi

# M3c 两道守卫一起删 —— 这才是"一次同步把 129 条写成 1 条"的真形状，必须红
if apply "$A" '_kl_cur=$(current_target_apps) || { rm -f "$tmp" 2>/dev/null; return 2; }' '_kl_cur=$(current_target_apps 2>/dev/null || true)' \
   && apply "$B" '_cn=$(current_target_apps 2>/dev/null) || { rm -f "$tmp" 2>/dev/null; return 2; }' '_cn=$(current_target_apps 2>/dev/null || true)'; then
    run_suite; report M3c "$LOG" "基线读不到时 run_sync 返回 0" "名单没被同步这条路改动"
fi

# M4 分派又不带出退码（真机症状里"退码 0"那一半）
if apply "$W" 'exit "$_rc"' 'exit 0'; then
    run_suite; report M4 "$LOG" "webui.sh 不再带出退码"
fi

# M5 扫描器自己被判据名改坏（恒 0）—— 这时 3.3/3.4 会安静地全绿，只有开火对照会响
if apply "$S" 'if (index(g, "current_target_apps") == 0) next' 'if (index(g, "current_target_appX") == 0) next'; then
    run_suite; report M5 "$LOG" "扫描器对已知的管道写法开火" "扫描器对已知的吞 stderr 写法开火"
fi

echo "── 还原后必须重新全绿 ──"
run_suite
if [ $? -eq 0 ] && ! grep -q -a '✗' "$LOG"; then
    printf '  ok   还原后套件全绿（%s 条）\n' "$(grep -a -c '^  ok' "$LOG")"
else
    printf '  ✗    还原后仍有红：\n'; grep -a -n '✗' "$LOG"; GLOBAL_FAIL=1
fi

echo "── 生产文件与变异前逐字节一致 ──"
for pair in "$B|backend.sh" "$A|applist.sh" "$W|webui.sh" "$S|suite.sh"; do
    _f=${pair%|*}; _b=${pair#*|}
    if cmp -s "$_f" "$BK/$_b"; then printf '  ok   %s\n' "${_f##*/}"; else printf '  ✗    %s 没还原干净\n' "${_f##*/}"; GLOBAL_FAIL=1; fi
done
exit "$GLOBAL_FAIL"
