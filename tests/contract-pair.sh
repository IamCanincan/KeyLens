#!/bin/sh
#=============================================================================
# tests/contract-pair.sh - 界面与命令层的契约对账（CI 跑，不需要设备）
#
# 说明：KL_API（webui.sh）与 EXPECT_API（index.html）是一对手写的号，两边
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
# 源码里的值可能**跨行续写**（WRITE_CMDS 就是三行），所以不能按"一行到分号"截 ——
# 换版那一刻 WRITE_CMDS 抽成空，这个套子把"读不到"当成"对不上"报了一次假漂移。
grab() {   # grab <名字>
    local name="$1" v=""
    [ -f "$UI_SRC" ] && v=$(awk -v n="export const $name" '
        index($0, n) == 1 && $0 ~ /=/ {
            sub(/^[^=]*=[ \t]*/, "")
            buf = $0
            if (buf ~ /\\$/) { while (getline line > 0) { buf = buf " " line; if (line !~ /\\$/) break } }
            gsub(/\\[ \t]*\n?/, "", buf)
            # 首尾的引号与结尾的分号要一起剥掉：只剥一个字符的话，结尾那个分号
            # 会留下一个孤零零的引号，那条写命令就查无此人。
            # 程序里的单引号一律写成 \047 —— 整个 awk 程序在 shell 的单引号里，
            # 直接放一个单引号会把引号截断（第一次就是这么炸的）。
            gsub(/^[ \t\047"]+/, "", buf)
            gsub(/[ ;\047"]+$/, "", buf)
            print buf; exit
        }' "$UI_SRC")
    [ -n "$v" ] || v=$(sed -n "s/.*var ${name} *= *'\{0,1\}\([^';]*\)'\{0,1\};.*/\1/p" "$HTML" | head -1)
    printf '%s' "$v"
}

api_sh=$(sed -n 's/^KL_API=\([0-9][0-9]*\).*/\1/p' "$SH_FILE" | head -1)
api_ui=$(grab EXPECT_API)

# KL_COMMANDS 跨行续写：从开引号攒到闭引号
cmds=$(awk '/^KL_COMMANDS="/ {
    sub(/^KL_COMMANDS="/, "")
    buf = $0
    while (buf !~ /"$/) { getline; buf = buf " " $0 }
    sub(/"$/, "", buf)
    # 续行的反斜杠要一起去掉：留着它，末尾那句"命令 N 条"会把 3 个反斜杠数成
    # 3 条命令（36 vs 真实的 33）。判"有没有"不受影响，但报出来的数是假的。
    gsub(/\\/, "", buf)
    print buf
    exit
}' "$SH_FILE")

writes=$(grab WRITE_CMDS)

echo "── 契约号 ──"
chk "webui.sh KL_API 读得到" 1 "$([ -n "$api_sh" ] && echo 1 || echo 0)"
chk "index.html EXPECT_API 读得到" 1 "$([ -n "$api_ui" ] && echo 1 || echo 0)"
chk "两侧契约号一致" "$api_sh" "$api_ui"

echo "── 命令清单 ──"
chk "KL_COMMANDS 读得到" 1 "$([ -n "$cmds" ] && echo 1 || echo 0)"
chk "WRITE_CMDS 读得到" 1 "$([ -n "$writes" ] && echo 1 || echo 0)"
for w in $writes; do
    chk_has "写命令 $w" "$cmds" "$w"
done

# 界面真正 call() 出去的命令名（call(cmd, arg) 这种转发不算）
# 从**源码**抓：产物是 ESM 压缩过的，`call('targets')` 这种字面量在产物里可能已经
# 变成双引号或被改名 —— 从产物抓会抓成空，而"抓成空"在这里等于全过（假绿）。
# 所以先源码、后产物，并且**抽干就判失败**。
grab_used() {   # grab_used <文件> <正则> <sed 脚本>
    grep -o "$2" "$1" 2>/dev/null | sed "$3" | sort -u
}
used=$(grab_used "$UI_SRC" "call('[a-z][a-z-]*'" "s/call('//; s/'//")
[ -n "$used" ] || used=$(grab_used "$HTML" "call('[a-z-][a-z-]*'" "s/call('//; s/'//")
if [ -z "$used" ]; then
    printf '  ✗    %-30s 一条都没抽到（抽取器坏了，不是没问题）\n' "界面调用的命令"
    fail=1
fi
n_used=$(printf '%s\n' $used | grep -c . )
printf '  ok   %-30s 抽到 %s 条\n' "界面调用的命令" "$n_used"
for u in $used; do
    chk_has "界面调用 $u" "$cmds" "$u"
done

# 界面按 contract.commands 逐条放行的能力门（如 excluded）
gated=$(grep "S.contract.commands" "$UI_SRC" "$HTML" 2>/dev/null | grep -o "hasCmd('[a-z][a-z-]*')" \
    | sed "s/hasCmd('//; s/')//" | sort -u)
for g in $gated; do
    chk_has "能力门 $g" "$cmds" "$g"
done

# 写入口的参数形状：write('命令', 参数) 直发的参数只有两种 —— 明文（包名/模式/
# 名字/哈希）或外层 base64（keybox 内容、payload）。发错形状时命令名、清单都能
# 对上，命令层也会执行到校验那一步才拒绝：界面上就是"点了保存没反应"，而 demo
# 台架不过桥、真机又没人逐颗按钮点，所以坏很久都没人发现（props-boot-hash 真发过
# base64，命令层要明文十六进制）。这里把"哪些命令允许直发 base64"钉成清单。
SCREENS=$ROOT/webui/src/screens.js
direct=$(grep -oE "write\('[a-z-]+'" "$SCREENS" 2>/dev/null | sed "s/write('//; s/'//" | sort -u)
chk "界面 write() 调用抽得到" 1 "$([ -n "$direct" ] && echo 1 || echo 0)"
for d in $direct; do
    chk_has "写入口 $d" "$cmds" "$d"
    chk_has "写命令清单 $d" "$writes" "$d"
done
B64_OK="keybox-save omk-save-injector teesim-save teesim-save-overrides omk-save-config tricky-save-patch"
b64sent=$(grep -oE "write\('[a-z-]+', *b64\(" "$SCREENS" 2>/dev/null \
    | sed "s/write('//; s/', *b64(//" | sort -u)
for c in $b64sent; do
    case " $B64_OK " in
        *" $c "*) printf '  ok   %-30s 允许直发 base64\n' "写入口 $c" ;;
        *) printf '  ✗    %-30s 发了 base64，命令层收的是明文\n' "写入口 $c"; fail=1 ;;
    esac
done

# 演示数据里的契约号不能再写死：写死就会与 EXPECT_API 漂开，
# 桌面预览于是永远"匹配"，横幅永远演不出来（这次就是这么漏的）
# 旧产物用 `QUERY.get('badapi') || String(EXPECT_API)`，新源码直接 `'api=' + EXPECT_API`
# —— 两种都算数，判的是"有没有跟着常量"，不是哪一种写法。
if grep -q "QUERY.get('badapi') || String(EXPECT_API)" "$HTML" \
   || grep -q "'api=' + EXPECT_API" "$HTML" \
   || grep -q "'api=' + EXPECT_API" "$UI_SRC"; then
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
