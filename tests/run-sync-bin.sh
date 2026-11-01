#!/bin/sh
#=============================================================================
# tests/run-sync-bin.sh - run_sync 的"优先走二进制"分支的闸门（CI 跑，不需要设备）
#
#   run_sync 是 service.sh 的后台同步、action.sh 的手动入口、安装期 customize.sh
#   共用的同步入口。它现在先看 ${KL_BIN:-$MODDIR/bin/keylens}：可执行、KL_USE_RUST 没被
#   关掉、且输出里有 `rc=` 那一行 —— 就用二进制的结果（返回码与 KL_COUNT），并**跳过**
#   mark_module_failed / update_module_desc（模块描述由二进制自己写）。
#   其余一切情况（二进制不存在、KL_USE_RUST=0、跑起来了但没给出 rc=：锁被占 / 后端冲突）
#   都回退到原来的 shell+awk 实现，不把"环境问题"报成"同步失败"。
#
#   KL_LOCK_HELD 是接力条：调用方（cmd_sync / action.sh / service.sh 的 dispatch_sync）
#   已经持有 $KL_DIR/.kl_lock，必须让子进程知道，否则子进程自己抢自己的锁
#   （锁按持有者证据判活，父 shell 的 cmdline 里就带着模块名）。
#   接力本身在真机上验（见 docs/HANDOFF.md §5.2 的记录），这里钉的是"分支选择的判据"
#   与"KL_LOCK_HELD 原样进子进程环境"。
#=============================================================================
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0

chk() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"; else printf '  ✗    %s\n        期望 [%s]，实得 [%s]\n' "$1" "$2" "$3"; fail=1; fi; }

# ---------- 模块目录 + 二进制桩 ----------
MOD="$T/module"
mkdir -p "$MOD/bin" "$T/kldir"
cat > "$MOD/bin/keylens" <<'STUB'
#!/bin/sh
printf 'lock=%s\nargs=%s\n' "${KL_LOCK_HELD:-}" "$*" > "$STUB_ENV"
# STUB_NO_RC=1：模拟"跑起来了但没给出 rc="（锁被占 / 后端冲突 / 起不来）
if [ -n "${STUB_NO_RC:-}" ]; then
    echo "守护进程正在写入，请几秒后再试" >&2
    exit 1
fi
echo "rc=${STUB_RC:-0}"
echo "count=${STUB_COUNT:-7}"
echo "description=⚡ [OhMyKeymint | 7 | 更新: 00:00]"
STUB
chmod +x "$MOD/bin/keylens"

# ---------- 被测脚本：真 source core.sh + backend.sh，回退路径的 awk 实现桩成计数器 ----------
cat > "$T/base.sh" <<EOF
# 位置参数就是本例的环境赋值（KL_LOCK_HELD=1 这种）；必须 export，
# 否则 base.sh 里的 shell 变量传不到 bin/keylens 桩那一层子进程。
for _kv in "\$@"; do export "\$_kv"; done
. "$ROOT/module/lib/core.sh"
. "$ROOT/module/lib/backend.sh"
MODDIR="$MOD"
KL_DIR="$T/kldir"
KL_BACKEND=omk
TARGET_FILE="$T/kldir/injector.toml"
KL_COUNT=0
fallback_hits=0
sync_omk_injector() { fallback_hits=\$((fallback_hits + 1)); KL_COUNT=3; return 1; }
sync_teesim_config() { fallback_hits=\$((fallback_hits + 1)); KL_COUNT=4; return 1; }
sync_target_list() { fallback_hits=\$((fallback_hits + 1)); KL_COUNT=5; return 1; }
desc_hits=0
failed_hits=0
update_module_desc() { desc_hits=\$((desc_hits + 1)); }
mark_module_failed() { failed_hits=\$((failed_hits + 1)); }
run_sync "\$MODDIR/module.prop" "\$KL_DIR/.kl_tmp"; _rc=\$?
printf 'rc=%s\nkl_count=%s\nfallback=%s\ndesc=%s\nfailed=%s\nheld=%s\nlock=%s\nargs=%s\n' \\
    "\$_rc" "\$KL_COUNT" "\$fallback_hits" "\$desc_hits" "\$failed_hits" "\${KL_LOCK_HELD:-}" \\
    "\$(sed -n 's/^lock=//p' "$T/env.txt" 2>/dev/null)" \\
    "\$(sed -n 's/^args=//p' "$T/env.txt" 2>/dev/null)"
EOF

run_case() { # <传给被测进程的环境赋值，可为空>
    rm -f "$T/env.txt"
    : > "$T/kldir/injector.toml"
    # 赋值走位置参数：这台机器的 env 拿 sh 当命令时不执行脚本（试过，输出为空且退 0）
    STUB_ENV="$T/env.txt" sh "$T/base.sh" $1 > "$T/out.txt" 2>&1
}
get() { sed -n "s/^$1=//p" "$T/out.txt" | head -n 1; }

printf '── 1 二进制可用：结果取自二进制，描述也交给二进制 ──\n'
run_case ''
chk "返回码取自二进制的 rc=" "0" "$(get rc)"
chk "KL_COUNT 取自二进制的 count=" "7" "$(get kl_count)"
chk "没回退到 awk 实现" "0" "$(get fallback)"
chk "没再刷模块描述（二进制自己写）" "0" "$(get desc)"
chk "rc=0 时不标失败" "0" "$(get failed)"
chk "调用方没持锁时接力条是空" "" "$(get held)"
chk "传给子进程的是锁条 0" "0" "$(get lock)"
chk "子进程收到的命令是 sync" "sync" "$(get args)"

printf '── 2 接力条 KL_LOCK_HELD 原样进子进程环境 ──\n'
run_case 'KL_LOCK_HELD=1'
chk "二进制看到锁在调用方手上" "1" "$(get lock)"

printf '── 3 rc=2：失败标注二进制已经做过，shell 不重复 ──\n'
run_case 'STUB_RC=2'
chk "返回 2" "2" "$(get rc)"
chk "没调 mark_module_failed" "0" "$(get failed)"
chk "没刷描述" "0" "$(get desc)"

printf '── 4 回退：KL_USE_RUST=0（命令层整个回 shell 的调试闸不许漏）──\n'
run_case 'KL_USE_RUST=0'
chk "走了 awk 实现" "1" "$(get fallback)"
chk "shell 路径照常刷描述" "1" "$(get desc)"
chk "KL_COUNT 来自 awk 实现" "3" "$(get kl_count)"

printf '── 5 回退：二进制不存在 ──\n'
mv "$MOD/bin/keylens" "$T/keylens.away"
run_case ''
chk "走了 awk 实现" "1" "$(get fallback)"
mv "$T/keylens.away" "$MOD/bin/keylens"

printf '── 6 回退：跑起来了但没给出 rc=（锁被占 / 后端冲突）──\n'
run_case 'STUB_NO_RC=1'
chk "不把环境问题报成同步失败" "1" "$(get fallback)"
chk "回退后仍走 shell 的描述刷新" "1" "$(get desc)"

printf '── 7 正对照：三条判据各自变异一次，必须各自改变读数 ──\n'
# 变异一律下在生产那份 lib/backend.sh 上（台子里手抄的副本怎么改都不响）
mutate() { # <sed 表达式> <采集字段>
    sed "$1" "$ROOT/module/lib/backend.sh" > "$T/backend.mut"
    if cmp -s "$ROOT/module/lib/backend.sh" "$T/backend.mut"; then
        printf 'MUT-NOT-LANDED %s\n' "$1"; return
    fi
    sed "s|\. \"$ROOT/module/lib/backend\.sh\"|. \"$T/backend.mut\"|" "$T/base.sh" > "$T/base.mut.sh"
    rm -f "$T/env.txt"; : > "$T/kldir/injector.toml"
    STUB_ENV="$T/env.txt" sh "$T/base.mut.sh" > "$T/out.mut.txt" 2>&1
    sed -n "s/^$2=//p" "$T/out.mut.txt" | head -n 1
}
chk "M1 摘掉分支判据 → 走回退（第 1 组确实在测那条分支）" "1" \
    "$(mutate 's|if \[ "${KL_USE_RUST:-1}" = "1" \] \&\& \[ -x "$_bin" \]; then|if [ -n "${KL_NEVER_SET:-}" ] \&\& [ -x "$_bin" ]; then|' fallback)"
chk "M2 拿掉 rc= 的提取 → 走回退" "1" \
    "$(mutate 's|-n "$_synced_rc"|-n ""|' fallback)"
chk "M3 拿掉接力条 → 子进程看到的锁条变空（第 2 组不是空断言）" "" \
    "$(mutate 's|KL_LOCK_HELD="${KL_LOCK_HELD:-0}"|KL_LOCK_HELD=""|' lock)"

echo
if [ "$fail" = 0 ]; then echo "全部通过"; else echo "有断言失败"; exit 1; fi
