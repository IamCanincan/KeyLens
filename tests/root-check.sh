#!/system/bin/sh
#=============================================================================
# tests/root-check.sh - root 那道门：不许放行错的人，也不许把自己关在外面
#
# 为什么单独一条套子：kl_is_root 是整条命令层的看门人，而它刚从 `$(id -u)`（真机现量
# 一次 68ms，占每次调用固定成本 115ms 的六成）改成读 /proc/self/status 的 Uid 行 ——
# 省的是钱，冒的险是**把非 root 放进来**。所以判据正反都要钉：
#   ① Uid=0 放行；② Uid=1000 必须拒绝（安全断言，最要紧的一条）；
#   ③ 多个 id 时取第一个（real uid），不许被后面的 0 蒙过去；
#   ④ 文件里没有 Uid 行 / 文件读不到 → 必须退回 id -u（用桩 id 证明这条路真走到了），
#      而不是"读不到就当不是 root"把模块锁死。
# 三条变异分别把 ①②④ 打断，每条都要求点名响；另有两条静态闸钉"入口还在用它"和
# "别退回裸 $(id -u)"。
#
# 跑法：sh tests/root-check.sh
#=============================================================================
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0

chk() { # chk <说明> <0=通过>
    if [ "$2" = 0 ]; then printf '  ok   %s\n' "$1"; else printf '  ✗    %s\n' "$1"; fail=1; fi
}
# verdict <说明> <期望 0=放行 / 1=拒绝>
verdict() {
    if kl_is_root >/dev/null 2>&1; then got=0; else got=1; fi
    [ "$got" = "$2" ]
    chk "$1（期望$([ "$2" = 0 ] && echo "放行" || echo "拒绝")，实得$([ "$got" = 0 ] && echo "放行" || echo "拒绝")）" $?
}

# ── 从真源抽函数，不抄一份（抄的那份怎么改都不会响）────────────────────────
s=$(grep -n '^kl_is_root() {' module/lib/core.sh | head -1 | cut -d: -f1)
[ -n "$s" ] || { echo '  ✗    core.sh 里找不到 kl_is_root'; exit 1; }
e=$(awk -v s="$s" 'NR>s && /^\}/{ print NR; exit }' module/lib/core.sh)
[ -n "$e" ] || { echo '  ✗    抽不到 kl_is_root 的结尾'; exit 1; }
BODY=$(sed -n "${s},${e}p" module/lib/core.sh)
eval "$BODY"
command -v kl_is_root >/dev/null 2>&1
chk "从 core.sh 抽出 kl_is_root（第 $s–$e 行）" $?

work=$(mktemp -d 2>/dev/null || echo /tmp/klrc-$$); mkdir -p "$work"
ORIG="$work/.orig"; printf '%s\n' "$BODY" > "$ORIG"

printf 'Name:sh\nState:R (running)\nTgid:1234\nUid:\t0\t0\t0\t0\nGid:\t0\t0\t0\t0\n' > "$work/root"
printf 'Name:sh\nState:R (running)\nUid:\t1000\t1000\t1000\t1000\nGid:\t2000\t2000\n' > "$work/user"
printf 'Uid:\t1000\t0\t0\t0\n' > "$work/first"          # real uid 是 1000，后面三个 0 是有效/保存/setuid
printf 'Name:sh\nState:R (running)\nGid:\t0\t0\t0\t0\n' > "$work/nouid"   # 没有 Uid 行

# ── 变异台：改真源的文本 → 自证落地 → eval 覆盖（之后由调用方跑断言）────────
# 没落地就返回 1：调用方必须跳过那组断言，否则会拿"未变异的真源"去比"变异后应有的
# 失败"，得到一条假的"抓到了"或假的红。
mutate() { # mutate <文件名> <awk 脚本>
    awk "$2" "$ORIG" > "$work/$1" || return 1
    if cmp -s "$ORIG" "$work/$1"; then
        printf '  ✗    变异 %s 没落地（与真源逐字节相同，这条断言等于没测）\n' "$1"
        fail=1; return 1
    fi
    eval "$(cat "$work/$1")"
}
restore() { eval "$BODY"; }

# ── ① ② ③ 真值表 ────────────────────────────────────────────────────────
restore
KL_PROC_STATUS="$work/root";  verdict 'Uid 行是 0 的进程要放行' 0
KL_PROC_STATUS="$work/user";  verdict 'Uid 行是 1000 的进程要拒绝' 1
KL_PROC_STATUS="$work/first"; verdict 'Uid 行有多个 id 时取第一个（real uid）' 1
KL_PROC_STATUS="$work/root";  verdict '同一个 shell 连查两次结果一致（无残留状态）' 0

# ── ④ 兜底：没有 Uid 行 / 文件读不到，都必须去问 id -u ────────────────────
id() { echo 1000; }
KL_PROC_STATUS="$work/nouid";          verdict '没有 Uid 行时退回 id -u（桩说非 root）' 1
KL_PROC_STATUS="$work/does-not-exist"; verdict '文件读不到时退回 id -u（桩说非 root）' 1
id() { echo 0; }
KL_PROC_STATUS="$work/nouid";          verdict '没有 Uid 行时退回 id -u（桩说是 root）' 0
unset -f id 2>/dev/null || true

# ── 变异 ①：不截第一个数字段 → "0\t0\t0\t0" 不再等于 0 → root 被误拒 ───────
if mutate m1.sh '{ if ($0 !~ /uid="\$\{uid%%\[!0-9\]\*\}"/) print }'; then
    KL_PROC_STATUS="$work/root"
    if kl_is_root >/dev/null 2>&1; then bad=1; else bad=0; fi
    [ "$bad" = 0 ]
    chk '变异 M1「不截第一个数字段」→ Uid=0 被误拒（bad=0 才算抓到）' $?
fi
restore

# ── 变异 ②：「= 0」放宽成「非空」→ 1000 被误放行（安全侧最坏的错）──────────
if mutate m2.sh '{ gsub(/\[ "\$uid" = 0 \]/, "[ -n \"$uid\" ]"); print }'; then
    KL_PROC_STATUS="$work/user"
    if kl_is_root >/dev/null 2>&1; then bad=1; else bad=0; fi
    [ "$bad" = 1 ]
    chk '变异 M2「非空就当 root」→ Uid=1000 被误放行，抓到了' $?
fi
restore

# ── 变异 ③：摘掉 id -u 兜底 → 读不到 Uid 时不再拒绝 ───────────────────────
if mutate m3.sh '{ if ($0 !~ /\[ "\$\(id -u\)" -eq 0 \]/) print }'; then
    id() { echo 1000; }
    KL_PROC_STATUS="$work/nouid"
    if kl_is_root >/dev/null 2>&1; then bad=1; else bad=0; fi
    unset -f id 2>/dev/null || true
    [ "$bad" = 1 ]
    chk '变异 M3「摘掉 id -u 兜底」→ 没有 Uid 行时不再拒绝，抓到了' $?
fi
restore

# ── 静态闸：入口还在用它，且没退回每命令一次 fork ─────────────────────────
grep -q '^kl_is_root || ' module/webui.sh
chk 'webui.sh 入口仍走 kl_is_root（这道门没被删）' $?
# webui.sh 里唯一允许留下的 $(id -u) 是 cmd_env 冷路径那一次（它自己已被缓存盖住）
hits=$(grep -n '^[^#]*\$(id -u)' module/webui.sh | sed 's/^[0-9]*://' | tr '\n' '|')
n=$(printf '%s' "$hits" | tr '|' '\n' | grep -c . || true)
[ "$n" = 1 ] && printf '%s' "$hits" | grep -q 'root_v='
chk "webui.sh 里裸的 \$(id -u) 只剩 cmd_env 缓存块那 1 处（实得 $n 处：$hits）" $?
m=$(grep -c '^[^#]*\$(id -u)' module/lib/core.sh || true)
[ "$m" = 1 ]
chk "core.sh 里那条兜底的 \$(id -u) 还在（命中 $m 处，要 1 处）" $?

rm -rf "$work"
if [ "$fail" = 0 ]; then echo '全部通过'; else echo '有断言失败'; fi
exit "$fail"
