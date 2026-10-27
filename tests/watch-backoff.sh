#!/bin/sh
#=============================================================================
# tests/watch-backoff.sh - 监听退避的自检（CI 跑，不需要设备）
#
# 说明：它 source 的就是守护进程用的那一份 lib/watch.sh，所以"测的是一份、
#       线上是另一份"这件事被结构上排除了；末尾还有一条 grep 断言，防止有人
#       把公式重新内联回 service.sh。
#=============================================================================
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/module/lib/watch.sh"

fail=0
chk() {   # chk <标签> <期望> <实际>
    if [ "$2" = "$3" ]; then
        printf '  ok   %-28s = %s\n' "$1" "$3"
    else
        printf '  ✗    %-28s 期望 %s，实得 %s\n' "$1" "$2" "$3"
        fail=1
    fi
}

echo "── next_backoff 逐档 ──"
chk "next_backoff 1" 3  "$(next_backoff 1)"
chk "next_backoff 2" 6  "$(next_backoff 2)"
chk "next_backoff 3" 12 "$(next_backoff 3)"
chk "next_backoff 4" 24 "$(next_backoff 4)"
chk "next_backoff 5" 48 "$(next_backoff 5)"
chk "next_backoff 6" 60 "$(next_backoff 6)"
chk "next_backoff 9（封顶）" 60 "$(next_backoff 9)"
chk "WATCH_ALIVE" 10 "$WATCH_ALIVE"

echo "── 只有一份公式 ──"
if grep -q 'next_backoff' "$ROOT/module/service.sh"; then
    echo "  ok   service.sh 调的是 next_backoff"
else
    echo "  ✗    service.sh 没调用 next_backoff（公式可能被内联回去了）"
    fail=1
fi
if grep -qE 'backoff=\$\(\(3 *<<' "$ROOT/module/service.sh"; then
    echo "  ✗    service.sh 里还留着一份内联的退避公式"
    fail=1
else
    echo "  ok   service.sh 里没有第二份公式"
fi

if [ "$fail" = 0 ]; then
    echo "全部通过"
else
    echo "有断言失败"
fi
exit $fail
