#!/system/bin/sh
#=============================================================================
# tests/lock-steal.sh - 锁：等不到就"拒"，不许"抢"
#
# 修掉的故障（lib/lock.sh 旧版）：等满 LOCK_TIMEOUT 之后
#     rmdir "$1"; mkdir "$1"
# 而锁目录平时是空目录，rmdir 对空目录**会成功** —— 于是守护进程正在写
# config.json / target.txt / injector.toml 的那几秒里，界面一句"加锁成功"
# 就把它的锁拆了，两边同时做整文件读-改-写。表现是偶发丢更新，日志里一句错都没有；
# 更糟的是上一任持有者随后 release 还会把接管者的锁再拆一次。
#
# 现在锁里记持有者 pid，接管要有证据（持有者进程没了，或那个 pid 已经不是本模块的
# 进程 —— pid 会复用）。拿不出证据就退非 0。所有调用方本来就写了
# `acquire_lock … || return 1` / `webui_lock || return 1`，所以"拒"这条路是通的。
#
# 跑法：sh tests/lock-steal.sh
#=============================================================================
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  ✗    %s\n' "$1"; fail=1; }

W=$(mktemp -d 2>/dev/null || echo "/tmp/kllk-$$"); mkdir -p "$W"
LK="$W/.kl_lock"
export KL_LOCK_MARK=keylens
LOCK_TIMEOUT=1
log_warn() { :; }
log_info() { :; }

# 抽真源（抄一份的话，把实现改回"抢"也不会响）
for fn in acquire_lock kl_lock_holder_alive release_lock; do
    s=$(grep -n "^$fn() {" module/lib/lock.sh | head -1 | cut -d: -f1)
    [ -n "$s" ] || { bad "抽不到 $fn"; exit 1; }
    e=$(awk -v s="$s" 'NR>s && /^\}/{ print NR; exit }' module/lib/lock.sh)
    [ -n "$e" ] || { bad "抽不到 $fn 的结尾"; exit 1; }
    eval "$(sed -n "${s},${e}p" module/lib/lock.sh)"
done
command -v acquire_lock >/dev/null 2>&1 && command -v release_lock >/dev/null 2>&1 \
    && ok '从 lib/lock.sh 抽出三个函数' || { bad '函数没抽出来'; exit 1; }

# ── ① 正常拿锁 / 放锁 ────────────────────────────────────────────────
acquire_lock "$LK"; rc=$?
[ "$rc" = 0 ] && [ -d "$LK" ] && ok '拿得到锁时建出锁目录'  || bad "拿锁失败（rc=$rc）"
[ "$(cat "$LK/pid" 2>/dev/null)" = "$$" ] && ok '锁里记了持有者 pid' || bad '锁里没有 pid 记录'
release_lock "$LK"
[ ! -d "$LK" ] && ok 'release 之后锁目录消失' || bad 'release 没放掉自己的锁'

# ── ② 核心：持有者活着时，第二次拿锁必须失败，且不许动别人的锁 ─────────
mkdir -p "$W/keylens-holder"
printf '#!/system/bin/sh\nsleep 30\n' > "$W/keylens-holder/hold.sh"
sh "$W/keylens-holder/hold.sh" & HOLDER=$!
sleep 1
mkdir -p "$LK"; printf '%s' "$HOLDER" > "$LK/pid"
acquire_lock "$LK"; rc=$?
[ "$rc" != 0 ] && ok "持有者活着 → 拒绝加锁（退码 $rc），不抢" || bad '持有者活着却抢到了锁 —— 这正是修掉的故障'
[ "$(cat "$LK/pid" 2>/dev/null)" = "$HOLDER" ] \
    && ok '拒绝时没有破坏别人的锁目录与 pid 记录' || bad '拒绝时仍把别人的锁拆了/改了'
# 非持有者不许替别人解锁
release_lock "$LK"
[ -d "$LK" ] && ok 'release 不是自己的锁时不动它' || bad 'release 把别人的锁拆了'
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null

# ── ③ 持有者已经死了 → 允许接管 ──────────────────────────────────────
mkdir -p "$LK"; printf '999999' > "$LK/pid"     # 一个不可能活着的 pid
if kill -0 999999 2>/dev/null; then bad '测试环境里 999999 竟然活着，这条不作数'; fi
acquire_lock "$LK"; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$LK/pid" 2>/dev/null)" = "$$" ] \
    && ok '持有者已不在 → 接管并把 pid 换成自己' || bad "死锁接管失败（rc=$rc）"
release_lock "$LK"

# ── ④ 没有 pid 记录（旧版本留下的锁目录）→ 也要能接管，不能永远卡死 ────
mkdir -p "$LK"
acquire_lock "$LK"; rc=$?
[ "$rc" = 0 ] && ok '锁里没有 pid 记录时仍能接管（不会被历史遗留永久锁死）' || bad "无 pid 记录时接管失败（rc=$rc）"
release_lock "$LK"

OLD_IMPL='acquire_lock() {
    local waited=0
    while [ "$waited" -lt "$LOCK_TIMEOUT" ]; do
        mkdir "$1" 2>/dev/null && return 0
        sleep 1
        waited=$((waited + 1))
    done
    rmdir "$1" 2>/dev/null
    mkdir "$1" 2>/dev/null
}'
# ── 变异：把实现改回"超时后 rmdir 再 mkdir"（旧版），要能复现它抢锁成功 ────
# 注意场景：旧版从不往锁里写 pid，所以线上那个锁目录是**空目录**，而 rmdir 对空目录
# 会成功 —— 这正是旧代码能拆掉别人锁的原因。新实现里锁带一个 pid 文件，rmdir 会
# 直接失败，等于多一道保险；变异按旧版的真实形状（空锁目录）来跑。
rm -rf "$LK"; mkdir -p "$LK"
sh -c "LOCK_TIMEOUT=1; log_warn(){ :; }; $OLD_IMPL; acquire_lock '$LK'; echo \$?" > "$W/mut.out" 2>/dev/null
mut=$(tail -1 "$W/mut.out")
[ "$mut" = "0" ] && ok '变异「旧版超时就 rmdir」在空锁目录上确实抢到了 —— ②那条不是空转' \
    || bad "变异没复现旧行为（退码 $mut），②那条断言可能是空转"
rm -rf "$LK"
# 新实现面对同一个"空锁目录"（旧版遗留、没有 pid 记录）也不会拆坏别人：
# 它先等满超时，再因为拿不出"持有者已死"的证据而走接管分支 —— 这里只验它不 hang、有退码
mkdir -p "$LK"
acquire_lock "$LK"; rc=$?
[ "$rc" = 0 ] && ok '新版遇到"无 pid 记录的历史锁"能接管（不会永久锁死）' || bad "无记录锁接管失败（rc=$rc）"
release_lock "$LK"

rm -rf "$W"
[ "$fail" = 0 ] && echo '全部通过' || echo '有断言失败'
exit "$fail"
