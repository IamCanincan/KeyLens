#!/bin/sh
#=============================================================================
# tests/contract-pair.sh - 界面与命令层的契约对账（CI 跑，不需要设备）
#
# 说明：TAA_API（webui.sh）与 EXPECT_API（index.html）是一对手写的号，两边
#       各推各的文件时最容易只改一边 —— 上线表现就是界面顶部挂一条"不是同一
#       版"的横幅，而代码本身没有任何错。这里把这对号、以及"界面会调的命令
#       必须在命令层清单里"变成一条静态断言，不必等真机看见横幅。
#
# 用法：sh tests/contract-pair.sh [webui.sh] [index.html]
#
# 契约常量现在有两种写法：旧产物里是 `var EXPECT_API = 4;`，新版源码
# （webui/src/bridge.js）是 `export const EXPECT_API = 4;`。两边都要认 ——
# 只认一种的话，换产物的那一刻这个套子会静默读不到值，而"读不到"在它眼里
# 和"对不上"是同一种失败，容易误判成契约漂移。
#=============================================================================
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SH_FILE=${1:-$ROOT/module/webui.sh}
HTML=${2:-$ROOT/module/webroot/index.html}
UI_SRC=$ROOT/webui/src/bridge.js

fail=0
chk() {   # chk <标签> <期望> <实际>
    if [ "$2" = "$3" ]; then
        printf '  ok   %-30s = %s\n' "$1" "$3"
    else
        printf '  ✗    %-30s 期望 %s，实得 %s\n' "$1" "$2" "$3"
        fail=1
    fi
}
chk_has() {   # chk_has <标签> <清单(空格分隔)> <名字>
    case " $2 " in
        *" $3 "*) printf '  ok   %-30s 在清单里\n' "$1" ;;
        *) printf '  ✗    %-30s %s 不在命令层清单里\n' "$1" "$3"; fail=1 ;;
    esac
}

# 双写法抽取：先问源码（可读、带 export），再退回产物（旧版 var）
grab() {   # grab <名字> <正则号=1>
    local name="$1" v=""
    [ -f "$UI_SRC" ] && v=$(sed -n "s/.*export const ${name} *= *\([^;]*\);.*/\1/p" "$UI_SRC" | head -1)
    [ -n "$v" ] || v=$(sed -n "s/.*var ${name} *= *'\{0,1\}\([^';]*\)'\{0,1\};.*/\1/p" "$HTML" | head -1)
    printf '%s' "$v"
}

api_sh=$(sed -n 's/^TAA_API=\([0-9][0-9]*\).*/\1/p' "$SH_FILE" | head -1)
api_ui=$(grab EXPECT_API)

# TAA_COMMANDS 跨行续写：从开引号攒到闭引号
cmds=$(awk '/^TAA_COMMANDS="/ {
    sub(/^TAA_COMMANDS="/, "")
    buf = $0
    while (buf !~ /"$/) { getline; buf = buf " " $0 }
    sub(/"$/, "", buf)
    print buf
    exit
}' "$SH_FILE")

writes=$(grab WRITE_CMDS)

echo "── 契约号 ──"
chk "webui.sh TAA_API 读得到" 1 "$([ -n "$api_sh" ] && echo 1 || echo 0)"
chk "index.html EXPECT_API 读得到" 1 "$([ -n "$api_ui" ] && echo 1 || echo 0)"
chk "两侧契约号一致" "$api_sh" "$api_ui"

echo "── 命令清单 ──"
chk "TAA_COMMANDS 读得到" 1 "$([ -n "$cmds" ] && echo 1 || echo 0)"
chk "WRITE_CMDS 读得到" 1 "$([ -n "$writes" ] && echo 1 || echo 0)"
for w in $writes; do
    chk_has "写命令 $w" "$cmds" "$w"
done

# 界面真正 call() 出去的命令名（call(cmd, arg) 这种转发不算）
used=$(grep -o "call('[a-z-][a-z-]*'" "$HTML" | sed "s/call('//; s/'//" | sort -u)
for u in $used; do
    chk_has "界面调用 $u" "$cmds" "$u"
done

# 界面按 contract.commands 逐条放行的能力门（如 excluded）
gated=$(grep "S.contract.commands" "$HTML" | grep -o "indexOf(' [a-z-][a-z-]* ')" \
    | sed "s/indexOf(' //; s/ ')//" | sort -u)
for g in $gated; do
    chk_has "能力门 $g" "$cmds" "$g"
done

# 演示数据里的契约号不能再写死：写死就会与 EXPECT_API 漂开，
# 桌面预览于是永远"匹配"，横幅永远演不出来（这次就是这么漏的）
if grep -q "QUERY.get('badapi') || String(EXPECT_API)" "$HTML"; then
    printf '  ok   %-30s 跟随 EXPECT_API\n' "演示数据 api="
else
    printf '  ✗    %-30s 演示数据把 api 写死了\n' "演示数据 api="
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "全部通过（api=$api_sh，命令 $(( $(printf '%s\n' $cmds | wc -l) )) 条）"
else
    echo "有断言失败"
fi
exit "$fail"
