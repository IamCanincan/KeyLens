#!/system/bin/sh
#=============================================================================
# tests/write-lazy.sh - 写命令实现的懒加载边界：两边必须一一对应
#
# 为什么需要它：命令层的写实现被搬进 lib/write.sh，只在命令名命中 KL_WRITE_CMDS 时才
# source。这个边界一旦错位，坏法有两种，而且都不是"变慢"而是"当场炸"：
#   ① 表里少了某条命令 → 用户点保存，分派到 cmd_* 时函数不存在（command not found），
#      写入静默失败；
#   ② 表里多了、或某个读命令调用了写函数 → 读路径没 source 就调用，同样炸。
# 更隐蔽的是第三种漂移：把 write.sh 顺手加进 common.sh 的加载清单 —— 功能全对，
# 但这次优化的收益直接归零，而且没有任何一条断言会变红。
#
# 跑法：sh tests/write-lazy.sh
#=============================================================================
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0

chk() { if [ "$2" = 0 ]; then printf '  ok   %s\n' "$1"; else printf '  ✗    %s\n' "$1"; fail=1; fi; }

# ── 取两边那张表 ─────────────────────────────────────────────────────────
# 命令层侧：KL_WRITE_CMDS（跨行续行）。收束条件用"这一行以引号结尾"，不用
# "以反斜杠结尾" —— gawk 的 /\\$/ 在这里不匹配（现量：只收到第一行），而 tr -d '"\\'
# 还会警告"末尾反斜杠不可移植"并且真的不删。两处都换成 sed 的字符类。
klw=$(awk '/^KL_WRITE_CMDS=/ {f=1} f {print; if ($0 ~ /"$/) exit}' module/webui.sh \
    | tr '\n' ' ' | sed 's/^KL_WRITE_CMDS=//; s/["\\]//g')
[ -n "$klw" ]
chk '取到命令层侧的 KL_WRITE_CMDS' $?
# 界面侧：bridge.js 的 WRITE_CMDS（同样是跨行续行的字符串字面量）
uiw=$(awk '/^export const WRITE_CMDS/ {f=1} f {print; if ($0 ~ /;$/) exit}' webui/src/bridge.js \
    | tr '\n' ' ' | sed "s/^export const WRITE_CMDS = //; s/['\\\\;]//g")
[ -n "$uiw" ]
chk '取到界面侧 bridge.js 的 WRITE_CMDS' $?

a="$PWD/.klw"; b="$PWD/.uiw"
printf '%s\n' $klw | sort > "$a"; printf '%s\n' $uiw | sort > "$b"
n_kl=$(grep -c . "$a"); n_ui=$(grep -c . "$b")
cmp -s "$a" "$b"
chk "两张表逐条相同（命令层 $n_kl 条 / 界面 $n_ui 条）" $?
if [ "$fail" = 1 ] && [ ! -s "$a" -o ! -s "$b" ]; then echo '  ·  表内容：'"$klw"; fi
diff_out=$(diff "$a" "$b" | tr '\n' ' ')
[ -z "$diff_out" ]
chk "两张表的差集为空${diff_out:+（实得：$diff_out）}" $?

# ── write.sh 里的函数，必须都归这张表管，且只被分派表调用 ─────────────────
wfns=$(grep -o '^cmd_[a-z0-9_]*() {' module/lib/write.sh | sed 's/() {//' | sort)
n_fn=$(printf '%s\n' "$wfns" | grep -c .)
[ "$n_fn" -ge 15 ]
chk "lib/write.sh 里有 $n_fn 个写实现（门槛 15，防"搬家搬空了"）" $?

# 分派区 = case "$CMD" in ... esac
dsp=$(awk '/^case "\$CMD" in/{f=1} f{print} /^esac$/{if (f) exit}' module/webui.sh)
[ -n "$dsp" ]
chk '取到 webui.sh 的分派区' $?

bad=""
for f in $wfns; do
    # 分派区之外出现对该函数的调用 = 读路径会找不到函数
    hits=$(grep -n "\b$f\b" module/webui.sh | sed 's/^[0-9]*://' | grep -v '^ *#' || true)
    for h in $hits; do
        case "$dsp" in *"$h"*) : ;; *) bad="$bad $f" ;; esac
    done
done
[ -z "$bad" ]
chk "写实现只被分派表调用，读路径没有一处引用（越界引用：${bad:-无}）" $?

# 分派区里每条写命令的 arm 都要能落到 write.sh 的某个函数
# 注意窗口要"到下一个 arm 为止"，不是固定几行：set-mode 的 arm 先解两个参数、
# 第四行才调 cmd_set_mode，用 -A2 会看成"没有 arm"（第一版就是这么误报的）。
miss=""
for c in $klw; do
    arm=$(printf '%s\n' "$dsp" | awk -v pat="^    $c)" '
        f && /^    [a-z0-9-]+\)/ { exit }
        $0 ~ pat { f = 1 }
        f { print }
    ' | grep -o 'cmd_[a-z0-9_]*' | head -1)
    [ -n "$arm" ] || { miss="$miss $c(没有arm)"; continue; }
    printf '%s\n' "$wfns" | grep -qx "$arm" || miss="$miss $c→$arm不在write.sh"
done
[ -z "$miss" ]
chk "KL_WRITE_CMDS 每条都能在分派表里找到 write.sh 的实现（缺口：${miss:-无}）" $?

# ── write.sh 不许被 common.sh 顺手加载（那等于白搬）───────────────────────
grep -q 'write' module/lib/common.sh
[ "$?" = 1 ]
chk 'lib/common.sh 的加载清单里没有 write.sh' $?

# ── 变异：三条漂移各自都要点名响 ──────────────────────────────────────────
work=$(mktemp -d 2>/dev/null || echo /tmp/klwl-$$); mkdir -p "$work"
cp module/webui.sh "$work/webui.sh"; cp module/lib/write.sh "$work/write.sh"
cp module/lib/common.sh "$work/common.sh"; cp webui/src/bridge.js "$work/bridge.js"

# 用同一套判据跑"变异后的仓库"：把上面三段改成读临时目录的文件
check_against() { # check_against <说明> <期望 0=该过 / 1=该红>
    want="$2"
    kw=$(awk '/^KL_WRITE_CMDS=/ {f=1} f {print; if ($0 ~ /"$/) exit}' "$work/webui.sh" \
        | tr '\n' ' ' | sed 's/^KL_WRITE_CMDS=//; s/["\\]//g')
    uw=$(awk '/^export const WRITE_CMDS/ {f=1} f {print; if ($0 ~ /;$/) exit}' "$work/bridge.js" \
        | tr '\n' ' ' | sed "s/^export const WRITE_CMDS = //; s/['\\\\;]//g")
    printf '%s\n' $kw | sort > "$work/a"; printf '%s\n' $uw | sort > "$work/b"
    cmp -s "$work/a" "$work/b"; eq=$?
    dsp2=$(awk '/^case "\$CMD" in/{f=1} f{print} /^esac$/{if (f) exit}' "$work/webui.sh")
    bad2=""
    for f in $(grep -o '^cmd_[a-z0-9_]*() {' "$work/write.sh" | sed 's/() {//') ; do
        for h in $(grep -n "\b$f\b" "$work/webui.sh" | sed 's/^[0-9]*://' | grep -v '^ *#' || true); do
            case "$dsp2" in *"$h"*) : ;; *) bad2="$bad2 $f" ;; esac
        done
    done
    grep -q 'write' "$work/common.sh"; lazy=$?
    ok=1; [ "$eq" = 0 ] && [ -z "$bad2" ] && [ "$lazy" = 1 ] && ok=0
    if [ "$ok" = "$want" ]; then printf '  ok   变异「%s」%s\n' "$1" "$([ "$want" = 1 ] && echo "被抓到" || echo "不误报")"
    else printf '  ✗    变异「%s」判据没跟上（判成 %s，要 %s）\n' "$1" "$ok" "$want"; fail=1; fi
}

# 对照：原样必须判"通过"
check_against '原样（对照组）' 0

# M1：从表里删掉一条命令 → 表不再一一对应
sed 's/teesim-profile-new teesim-profile-del/teesim-profile-del/' "$work/webui.sh" > "$work/w2" && mv "$work/w2" "$work/webui.sh"
check_against '表里少一条 teesim-profile-new' 1

# M2：读路径里冒出一处对写实现的调用
cp module/webui.sh "$work/webui.sh"
sed 's|^cmd_contract() {|cmd_contract() {\n    cmd_keybox_save "x"|' "$work/webui.sh" > "$work/w3" && mv "$work/w3" "$work/webui.sh"
check_against 'cmd_contract 里调了 cmd_keybox_save' 1

# M3：把 write.sh 加进 common.sh 的加载清单 → 懒加载失效（收益归零，且功能一条不红）
cp module/webui.sh "$work/webui.sh"
sed 's/^for _kl_part in core lock tools applist backend props watch; do/for _kl_part in core lock tools applist backend props watch write; do/' "$work/common.sh" > "$work/c2" && mv "$work/c2" "$work/common.sh"
[ "$(grep -c 'watch write' "$work/common.sh")" = 1 ]
chk '变异 M3 落地了（common.sh 的清单里确实多了 write）' $?
check_against 'write.sh 被加进 common.sh 的加载清单' 1
grep -q 'write' module/lib/common.sh; [ "$?" = 1 ]
chk '还原后 common.sh 仍然不加载 write.sh' $?

rm -rf "$work" "$a" "$b"
if [ "$fail" = 0 ]; then echo '全部通过'; else echo '有断言失败'; fi
exit "$fail"
