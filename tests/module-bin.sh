#!/bin/sh
# module-bin：包内二进制与模块分发表的一致性（发版前的握手闸）。
#
# 什么时候生效：Linux 上且 `module/bin/keylens` 存在时。CI 的 rust-build.yml 会把
# aarch64 静态产物拷到那里再跑这个脚本；本地（Windows/MSYS）没有可执行的 Linux
# 二进制，直接跳过，以免把"没打包"或"跨平台跑不了"当成失败。
set -u
cd "$(dirname "$0")/.." || exit 1
BIN=module/bin/keylens
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  ✗    $1"; echo "       want=[$3]"; echo "       got =[$2]"; fail=1; fi; }

case "$(uname -s)" in
    Linux) ;;
    *) echo "  skip 非 Linux（$(uname -s)），跳过包内二进制检查"; echo "全部通过"; exit 0 ;;
esac
if [ ! -f "$BIN" ]; then
    echo "  skip 包内没有二进制（发版构建时才会有），跳过一致性检查"
    echo "全部通过"
    exit 0
fi
[ -x "$BIN" ] || { echo "  ✗    $BIN 不可执行"; exit 1; }

# 模块里声明的命令清单（KL_COMMANDS 是带反斜杠续行的多行串，按行拼回来）
want=$(awk '
/^KL_COMMANDS="/{f=1; sub(/^KL_COMMANDS="/,"")}
f {
  had = /"$/
  sub(/\\$/,""); sub(/"$/,"")
  printf "%s ", $0
  if (had) exit
}' module/webui.sh | tr -s ' ' | sed 's/ $//')
[ -n "$want" ] || { echo "  ✗    读不到 KL_COMMANDS"; exit 1; }
got=$("$BIN" contract | sed -n 's/^commands=//p')
chk "包内二进制的 contract 与 KL_COMMANDS 逐字一致" "$got" "$want"

# help 头一行必须是用法（界面靠它判断二进制能跑）
case "$("$BIN" help 2>&1 | head -n 1)" in
    "用法："*) echo "  ok   help 可执行且首行是用法" ;;
    *) echo "  ✗    help 不可用"; fail=1 ;;
esac

[ "$fail" = 0 ] && echo "全部通过" || { echo "有断言失败"; exit 1; }
