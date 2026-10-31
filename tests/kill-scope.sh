#!/system/bin/sh
#=============================================================================
# tests/kill-scope.sh - 按 pid 收进程之前，必须先证明"这是我们的"
#
# 修掉的故障：守护进程的 pid 名单是上一次运行写下的，隔一段时间/重启后那些号
# 可能已经属于别人。旧代码是 `kill -0 $pid && kill -9 $pid` —— pid 复用时会
# 杀掉一个毫不相干的进程（极端情况是 zygote）。现在统一走 core.sh 的
# kl_kill_pid：/proc/<pid>/cmdline 里认得出本模块（或改名前的旧名）才动。
#
# 跑法：sh tests/kill-scope.sh
#=============================================================================
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  ✗    %s\n' "$1"; fail=1; }

W=$(mktemp -d 2>/dev/null || echo "/tmp/klkill-$$"); mkdir -p "$W"
WRN="$W/warn.log"; : > "$WRN"
log_warn() { printf '%s\n' "$*" >> "$WRN"; }

# 抽真源（抽一份抄的在台子里改，是测不出线上那份走样的）
s=$(grep -n '^KL_OUR_MARKS=' module/lib/core.sh | head -1 | cut -d: -f1)
[ -n "$s" ] && eval "$(sed -n "${s}p" module/lib/core.sh)"
for fn in kl_pid_is_ours kl_kill_pid; do
    s=$(grep -n "^$fn() {" module/lib/core.sh | head -1 | cut -d: -f1)
    [ -n "$s" ] || { bad "抽不到 $fn"; exit 1; }
    e=$(awk -v s="$s" 'NR>s && /^\}/{ print NR; exit }' module/lib/core.sh)
    [ -n "$e" ] || { bad "抽不到 $fn 的结尾"; exit 1; }
    eval "$(sed -n "${s},${e}p" module/lib/core.sh)"
done
command -v kl_kill_pid >/dev/null 2>&1 && ok "从 core.sh 抽出 kl_kill_pid（标记：$KL_OUR_MARKS）" \
    || { bad '函数没抽出来'; exit 1; }

# ── ① 不相干的进程：拒绝，且必须还活着 ────────────────────────────────
sleep 60 & DECOY=$!
command sleep 0.2
kl_kill_pid "$DECOY" KILL; rc=$?
[ "$rc" = 1 ] && ok 'cmdline 认不出的进程 → 拒杀（退码 1）' || bad "拒杀退码应为 1，实得 $rc"
kill -0 "$DECOY" 2>/dev/null && ok '不相干的进程还活着（没被杀）' || bad '不相干的进程被杀掉了 —— 这正是修掉的故障'
grep -q '不是本模块' "$WRN" && ok '拒杀时留下一条说明（日志里看得出为什么没杀）' \
    || bad '拒杀却一个字没记'
kill -9 "$DECOY" 2>/dev/null; wait "$DECOY" 2>/dev/null

# ── ② 自己的进程：杀掉（新名 keylens）────────────────────────────────
mkdir -p "$W/keylens-hold"
printf '#!/system/bin/sh\nsleep 60\n' > "$W/keylens-hold/h.sh"; chmod 700 "$W/keylens-hold/h.sh"
sh "$W/keylens-hold/h.sh" & OURS=$!
command sleep 0.3
kl_kill_pid "$OURS" TERM; rc=$?
i=0; while [ "$i" -lt 20 ] && kill -0 "$OURS" 2>/dev/null; do command sleep 0.1; i=$((i + 1)); done
[ "$rc" = 0 ] && ok '自己的进程 → 照常结束（退码 0）' || bad "自己的进程退码应为 0，实得 $rc"
kill -0 "$OURS" 2>/dev/null && bad '自己的进程没被杀掉' || ok '自己的进程确实结束了'
wait "$OURS" 2>/dev/null

# ── ③ 升级侧：改名前的旧名也认（否则旧守护永远收不掉）────────────────
mkdir -p "$W/ts-auto-add-hold"
printf '#!/system/bin/sh\nsleep 60\n' > "$W/ts-auto-add-hold/h.sh"; chmod 700 "$W/ts-auto-add-hold/h.sh"
sh "$W/ts-auto-add-hold/h.sh" & OLDP=$!
command sleep 0.3
kl_kill_pid "$OLDP" KILL; rc=$?
[ "$rc" = 0 ] && ok 'cmdline 里是旧名 ts-auto-add → 也认作自己的（升级后收得掉）' \
    || bad "旧名进程被拒杀（退码 $rc）—— 升级上来的机器会留下旧守护"
kill -9 "$OLDP" 2>/dev/null; wait "$OLDP" 2>/dev/null

# ── ④ 边角：死 pid / 垃圾内容 / 空串 都不许报错、也不许杀 ─────────────
kl_kill_pid 999999 KILL; [ "$?" = 0 ] && ok '已经不在的 pid → 直接返回 0（不算失败）' || bad '死 pid 报了失败'
kl_kill_pid 'abc' KILL;  [ "$?" = 0 ] && ok '名单里的垃圾内容 → 直接跳过' || bad '垃圾内容导致失败'
kl_kill_pid '' KILL;     [ "$?" = 0 ] && ok '空 pid → 直接跳过' || bad '空 pid 导致失败'

# ── ⑤ 变异：把"证明"这一步摘掉，①必须响 ──────────────────────────────
sleep 60 & DECOY2=$!
command sleep 0.2
s=$(grep -n '^kl_kill_pid() {' module/lib/core.sh | head -1 | cut -d: -f1)
e=$(awk -v s="$s" 'NR>s && /^\}/{ print NR; exit }' module/lib/core.sh)
sed -n "${s},${e}p" module/lib/core.sh | sed 's/if ! kl_pid_is_ours "\$p"; then/if false; then/' > "$W/mut.sh"
grep -q 'if false; then' "$W/mut.sh" && . "$W/mut.sh" || bad '变异没落地（改写后的函数没生成）'
kl_kill_pid "$DECOY2" KILL
i=0; while [ "$i" -lt 20 ] && kill -0 "$DECOY2" 2>/dev/null; do command sleep 0.1; i=$((i + 1)); done
kill -0 "$DECOY2" 2>/dev/null && bad '变异没生效（照旧拒绝），⑤这条不作数' \
    || ok '变异「摘掉 cmdline 证明」后，不相干的进程当场被杀 —— ①那条不是空转'
kill -9 "$DECOY2" 2>/dev/null; wait "$DECOY2" 2>/dev/null

# ── ⑥ 静态：这两处不许再退回裸 kill ─────────────────────────────────
# 先证明这条 grep 抓得到旧形态（否则"没命中"分不清是干净还是瞎）
printf 'kill -9 "$pid" 2>/dev/null\n' | grep -qE 'kill -(9|TERM|KILL) "\$pid"' \
    && ok '静态判据的正对照：旧形态能被抓到' || bad '静态判据自己抓不到旧形态（这条闸是瞎的）'
for f in module/service.sh module/uninstall.sh; do
    if grep -v '^[[:space:]]*#' "$f" | grep -qE 'kill -(9|TERM|KILL) "\$pid"'; then
        bad "$f 里还有对名单 pid 的裸 kill"
    else
        ok "$f 不按裸 pid 杀进程"
    fi
    grep -q 'kl_kill_pid' "$f" && ok "$f 走 kl_kill_pid" || bad "$f 没接 kl_kill_pid"
done
# uninstall 的 pid 名单要覆盖全部后端目录（旧版只收 TS/SIM，OMK 机器卸了模块
# 守护进程还在按名单改 injector.toml）
grep -q 'for dir in \$DIRS; do' module/uninstall.sh && grep -q 'kl_daemon_pids.list' module/uninstall.sh \
    && ok '卸载按 DIRS 逐个收 pid 名单（不再只有两个目录）' \
    || bad '卸载仍在手抄两个目录的 pid 名单'

rm -rf "$W"
[ "$fail" = 0 ] && echo '全部通过' || echo '有断言失败'
exit "$fail"
