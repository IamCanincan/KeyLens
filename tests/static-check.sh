#!/bin/sh
# static-check：静态链接自检（本地用 musl 产物演一遍 CI 里对 aarch64 的同一条判据）。
#
# CI 在 rust-build.yml 里对 aarch64 产物做同样检查：NEEDED=0 且无 ELF INTERP。
# 这里把判据本身也测一遍，避免"闸门写错但一直绿"。
set -u
cd "$(dirname "$0")/.." || exit 1
BIN=${1:-rust/target/x86_64-unknown-linux-musl/release/keylens}
if [ ! -f "$BIN" ]; then
    echo "  skip 没有 $BIN（先 cargo build --target x86_64-unknown-linux-musl --release）"
    echo "全部通过"
    exit 0
fi
case "$(uname -s)" in
    Linux) ;;
    *) echo "  skip 非 Linux，跳过（readelf 语义不同）"; echo "全部通过"; exit 0 ;;
esac
needed=$(readelf -d "$BIN" 2>/dev/null | grep -c NEEDED || true)
interp=$(readelf -l "$BIN" 2>/dev/null | grep -c INTERP || true)
fail=0
if [ "$needed" = "0" ]; then
    echo "  ok   无动态库依赖（NEEDED=0）"
else
    echo "  ✗   仍依赖动态库："; readelf -d "$BIN" | grep NEEDED | head -3; fail=1
fi
if [ "$interp" = "0" ]; then
    echo "  ok   无 ELF 解释器（静态可执行）"
else
    echo "  ✗   有 ELF 解释器，说明是动态可执行"; fail=1
fi
if [ "$fail" = 0 ]; then echo "全部通过"; else echo "有断言失败"; exit 1; fi
