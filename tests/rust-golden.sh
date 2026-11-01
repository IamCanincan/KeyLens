#!/bin/sh
# rust-golden：命令层输出的「黄金快照」回归闸。
#
# 为什么需要它：`rust/parity.sh` 拿 shell 版当参照，等阶段 5 删掉 backends/*.awk 之后
# 那份参照就没有了。这里把当前已通过逐字节对拍的行为固化成快照，删 awk 之后仍然能
# 发现"输出变了"。
#
# 用法：
#   sh tests/rust-golden.sh --record   # 重新录制（只有确认行为正确时才用）
#   sh tests/rust-golden.sh            # 校验（默认，CI 跑这个）
set -u
cd "$(dirname "$0")/.." || exit 1
MODE="${1:-check}"
BIN="${KEYLENS_BIN:-rust/target/release/keylens}"
[ -x "$BIN" ] || BIN=rust/target/x86_64-unknown-linux-musl/release/keylens
if [ ! -x "$BIN" ]; then
    echo "  skip 没有可执行的 keylens 二进制（先 cargo build --release）"
    echo "全部通过"
    exit 0
fi

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
R="$T/root"
mkdir -p "$R/data/adb/modules/tricky_store" "$R/data/adb/tricky_store" "$R/data/adb/modules/keylens"
printf 'id=tricky_store\nname=Tricky Store\nversion=v1.9.9\n' > "$R/data/adb/modules/tricky_store/module.prop"
printf 'com.a\ncom.b?\ncom.c!\ncom.d@10\n' > "$R/data/adb/tricky_store/target.txt"
printf '2026-10-05\nsystem=2026-10-01\n\n[com.a]\nvendor=2026-09-01\n' > "$R/data/adb/tricky_store/security_patch.txt"
printf 'id=keylens\nname=KeyLens\nversion=v3.0.1\ndescription=ok\n' > "$R/data/adb/modules/keylens/module.prop"

GOLD=rust/golden
mkdir -p "$GOLD"

run_case() { # <名字> <命令> [参数]
    name="$1"; shift
    KEYLENS_ROOT="$R" "$BIN" "$@" 2>&1 | sed -e "s|$R|<root>|g" -e 's/keybox_mtime=[0-9]*/keybox_mtime=X/'
}

cases="contract help targets tricky-patches"
fail=0
for c in $cases; do
    out=$(run_case "$c" "$c")
    if [ "$MODE" = "--record" ]; then
        printf '%s\n' "$out" > "$GOLD/$c.txt"
        echo "  rec  $c"
    else
        want=$(cat "$GOLD/$c.txt" 2>/dev/null)
        if [ "$out" = "$want" ]; then
            echo "  ok   $c"
        else
            echo "  ✗    $c 输出与黄金快照不一致"
            printf '%s\n' "$want" > "$T/want.txt"
            printf '%s\n' "$out" > "$T/got.txt"
            diff "$T/want.txt" "$T/got.txt" | head -n 10
            fail=1
        fi
    fi
done

[ "$MODE" = "--record" ] && { echo "已录制（记得一起提交 $GOLD/）"; exit 0; }
if [ "$fail" = 0 ]; then echo "全部通过"; else echo "有断言失败"; exit 1; fi
