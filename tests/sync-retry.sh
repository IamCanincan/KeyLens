#!/system/bin/sh
#=============================================================================
# tests/sync-retry.sh - 守护进程拿不到锁时，这一趟同步不许被悄悄丢掉
#
# 背景：lib/lock.sh 以前的行为是"等满超时就抢"，所以 service.sh 的
#     acquire_lock "$LOCK_DIR" || exit 1 这一句在正常机器上几乎不会走到。
#     锁改成"拿不到就拒"之后，那一句变成了活的失败点：子壳直接 exit，
#     这一趟同步整个消失，而日志里一个字都没有 —— 表现是"装了应用但列表不动"。
#     （指纹没推进，下一次 packages.list 变化还会再触发，但用户可能不再装应用。）
#
# 现在 dispatch_sync 自己有界重试，全部失败才收口，并且把后果写进日志。
# 这里抽的是 module/service.sh 里的那一份实现，不是抄写：把重试改回
# `|| exit 1` 就必须响。
#
# 跑法：sh tests/sync-retry.sh
#=============================================================================
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  ✗    %s\n' "$1"; fail=1; }

W=$(mktemp -d 2>/dev/null || echo "/tmp/klretry-$$"); mkdir -p "$W"
ACQ="$W/acquire.count"
RUN="$W/dosync.count"
WRN="$W/warn.log"
: > "$ACQ"; : > "$RUN"; : > "$WRN"

# 抽真源
s=$(grep -n '^dispatch_sync() {' module/service.sh | head -1 | cut -d: -f1)
[ -n "$s" ] || { bad '抽不到 dispatch_sync'; exit 1; }
e=$(awk -v s="$s" 'NR>s && /^\}/{ print NR; exit }' module/service.sh)
[ -n "$e" ] || { bad '抽不到 dispatch_sync 的结尾'; exit 1; }
eval "$(sed -n "${s},${e}p" module/service.sh)"
command -v dispatch_sync >/dev/null 2>&1 && ok '从 service.sh 抽出 dispatch_sync' \
    || { bad 'dispatch_sync 没抽出来'; exit 1; }

# ---------- 桩 ----------
LOCK_DIR="$W/.kl_lock"
DEBOUNCE_LOCK="$W/.kl_debounce"
SYNC_DEBOUNCE_SEC=0            # 防抖窗口与重试间隔在台上都不必真等
SYNC_RETRY_GAP_SEC=0
SYNC_RETRY_MAX=3
sleep() { :; }                 # 顺带保证不依赖某个 sleep 认不认 "sleep 0"
log_warn() { printf '%s\n' "$*" >> "$WRN"; }
release_lock() { :; }
do_sync() { printf 'x\n' >> "$RUN"; }
# 默认：永远拿不到锁
acquire_lock() { printf 'x\n' >> "$ACQ"; return 1; }

n() { wc -l < "$1" | tr -d ' '; }
reset() { : > "$ACQ"; : > "$RUN"; : > "$WRN"; rm -rf "$DEBOUNCE_LOCK"; }

# ── ① 锁一直拒绝：要重试满 SYNC_RETRY_MAX 轮，且不许在无锁状态下写 ──────
reset
dispatch_sync; wait $! 2>/dev/null
[ "$(n "$ACQ")" = "$SYNC_RETRY_MAX" ] \
    && ok "锁一直拿不到 → 重试 $SYNC_RETRY_MAX 轮（旧版只试 1 轮）" \
    || bad "重试轮数应为 $SYNC_RETRY_MAX，实得 $(n "$ACQ") —— 退回了“拿不到就丢”"
[ "$(n "$RUN")" = "0" ] && ok '一次同步都没在没锁的情况下跑' || bad '拿不到锁仍然跑了 do_sync'
grep -q '跳过' "$WRN" && ok '放弃时留下一条日志，写明这一趟同步被跳过' \
    || bad '重试全失败却一个字没记 —— 又变成"装了应用列表不动"那种查不到的故障'
grep -q 'packages.list' "$WRN" && ok '日志同时写明"下一次文件变化会自动补"' \
    || bad '日志没交代后果（下一次触发才会补），读日志的人不知道该不该手动同步'

# ── ② 第二轮才拿到锁：跑一次、放一次、不许有 warn ──────────────────────
reset
acquire_lock() {
    printf 'x\n' >> "$ACQ"
    [ "$(n "$ACQ")" -ge 2 ] || return 1
    return 0
}
dispatch_sync; wait $! 2>/dev/null
[ "$(n "$RUN")" = "1" ] && ok '第 2 轮拿到锁后补上了这一趟同步' || bad "拿到锁后 do_sync 跑了 $(n "$RUN") 次（应为 1）"
[ "$(n "$ACQ")" = "2" ] && ok '拿到锁就停，不再多试' || bad "拿到锁后仍继续重试（共 $(n "$ACQ") 轮）"
[ "$(n "$WRN")" = "0" ] && ok '成功这条路不留噪音' || bad "只是慢了一轮就报 warn（$(n "$WRN") 条）：$(cat "$WRN")"

# ── ③ 防抖仍然生效：窗口内的第二次触发不起新子壳 ───────────────────────
reset
acquire_lock() { printf 'x\n' >> "$ACQ"; return 0; }
mkdir -p "$DEBOUNCE_LOCK"      # 模拟"上一颗防抖锁还没到期"
dispatch_sync
command sleep 0.2              # 真等一会儿：绕开上面那个 sleep 桩，否则子壳来不及跑就会被判成"没起"
[ "$(n "$ACQ")" = "0" ] && ok '防抖窗口内的重复触发被合并（一次锁都没碰）' \
    || bad "防抖失效：窗口内又起了 $(n "$ACQ") 次同步"

# ── ④ 变异：把实现改回旧版那一句，①的两条必须响 ────────────────────────
reset
acquire_lock() { printf 'x\n' >> "$ACQ"; return 1; }   # 换回"永远拒绝"，否则旧版也能一次成功
OLD='dispatch_sync() {
    mkdir "$DEBOUNCE_LOCK" 2>/dev/null || return 0
    (
        sleep "$SYNC_DEBOUNCE_SEC"
        rmdir "$DEBOUNCE_LOCK" 2>/dev/null
        acquire_lock "$LOCK_DIR" || exit 1
        do_sync
        release_lock "$LOCK_DIR"
    ) &
}'
eval "$OLD"
dispatch_sync; wait $! 2>/dev/null
oldacq=$(n "$ACQ"); oldwrn=$(n "$WRN")
[ "$oldacq" = "1" ] && [ "$oldwrn" = "0" ] \
    && ok "变异旧版：只试 1 轮、0 条日志（$oldacq/$oldwrn）—— ①那两条不是空转" \
    || bad "变异没复现旧行为（试 $oldacq 轮、$oldwrn 条日志），①的断言可能是空转"

# ── ⑤ 静态：线上那一句不能再退回去 ─────────────────────────────────────
if grep -qE 'acquire_lock[[:space:]]+"\$LOCK_DIR"[[:space:]]*\|\|[[:space:]]*exit' module/service.sh; then
    bad 'service.sh 里还有「拿不到锁就 exit」—— 这一趟同步会无声消失'
else
    ok 'service.sh 里没有裸的「拿不到锁就 exit」'
fi
grep -q 'SYNC_RETRY_MAX' module/service.sh && ok '重试档位是 service.sh 里的具名常量' \
    || bad 'SYNC_RETRY_MAX 没在 service.sh 里定义（本测试桩掉了变量，改错了也发现不了）'

rm -rf "$W"
[ "$fail" = 0 ] && echo '全部通过' || echo '有断言失败'
exit "$fail"
