#!/bin/sh
# 把模块文件推到设备，并自证真的到位（本地跑，不进刷机包）。
#
#   sh tools/deploy-webui.sh            只推界面（module/webroot/index.html）
#   sh tools/deploy-webui.sh --shell    推命令层（webui.sh + lib/*.sh + backends/*）
#   sh tools/deploy-webui.sh --all      两者都推
#   sh tools/deploy-webui.sh --allow-dirty   明知工作区有未提交改动也要推
#
# 为什么要这么长一条：
#  1) `adb push` 默认把文件落成 0666。这个模块的 index.html 由管理器以 root 加载、
#     里面的命令以 root 执行 —— 世界可写等于任何应用都能改写一个 root 界面；
#     webui.sh 同理。所以"收权限 + 核模式"是硬闸门，不靠人记得 chmod。
#  2) 分文件推最容易出的事故是"两边不同版"。所以推之前拒绝未提交的改动
#     （设备上跑的版本必须对得上仓库里的某个提交），推之后逐文件比 sha256。
set -u

MODDIR=/data/adb/modules/ts-auto-add
MODE_HTML=644
MODE_SH=755
GROUP=webui
ALLOW_DIRTY=0

for a in "$@"; do
    case "$a" in
        --shell) GROUP=shell ;;
        --all) GROUP=all ;;
        --webui) GROUP=webui ;;
        --allow-dirty) ALLOW_DIRTY=1 ;;
        *) printf '用法：sh tools/deploy-webui.sh [--shell|--all] [--allow-dirty]\n'; exit 2 ;;
    esac
done

fail() { printf '✗ %s\n' "$1"; exit 1; }
ok()   { printf '  ok  %s\n' "$1"; }

command -v adb >/dev/null 2>&1 || fail "找不到 adb"
[ -d .git ] || [ -f .git ] || fail "请在仓库根目录跑（找不到 .git）"
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || fail "git rev-parse 失败"
cd "$ROOT" || fail "进不去仓库根"

# ── 要推的文件清单（相对仓库根 → 设备上 mode）────────────────────────
FILES=""
add() { FILES="$FILES
$1|$2"; }
want_webui=0; want_shell=0
case "$GROUP" in
    webui) want_webui=1 ;;
    shell) want_shell=1 ;;
    all)   want_webui=1; want_shell=1 ;;
esac
[ "$want_webui" = 1 ] && add module/webroot/index.html "$MODE_HTML"
if [ "$want_shell" = 1 ]; then
    add module/webui.sh "$MODE_SH"
    for f in module/lib/*.sh; do   [ -f "$f" ] && add "$f" "$MODE_SH"; done
    for f in module/backends/*; do [ -f "$f" ] && add "$f" "$MODE_SH"; done
fi
FILES=$(printf '%s\n' "$FILES" | grep -v '^$')
[ -n "$FILES" ] || fail "这一组没有要推的文件（清单空 —— 宁可失败也不要推了个寂寞）"

# ── 入口闸门 ──────────────────────────────────────────────────────────
dirty=""
while IFS='|' read -r rel mode; do
    [ -n "$rel" ] || continue
    [ -f "$rel" ] || fail "本地缺文件 $rel"
    git diff --quiet -- "$rel" 2>/dev/null || dirty="$dirty $rel"
    git diff --cached --quiet -- "$rel" 2>/dev/null || dirty="$dirty(已暂存) $rel"
done <<EOF
$FILES
EOF
if [ -n "$dirty" ] && [ "$ALLOW_DIRTY" = 0 ]; then
    fail "这些文件有未提交改动：$dirty
  推上去的版本与仓库里的对不上，回头就没法说清设备上跑的是哪版。
  先提交，或确认要推就加 --allow-dirty"
fi
ok "工作区闸门（组=$GROUP 文件数=$(printf '%s\n' "$FILES" | grep -c .) 未提交改动=${dirty:-无}）"

adb get-state >/dev/null 2>&1 || fail "设备不在线（adb get-state 失败；锁屏久了要先解锁并点允许）"
AS_UID=$(adb shell "id -u" 2>/dev/null | tr -d '\r')
[ "$AS_UID" = "0" ] || fail "adb shell 不是 root（uid=$AS_UID）—— 先 adb root"
ok "设备在线且为 root"

adb shell "[ -d $MODDIR ]" 2>/dev/null || fail "设备上找不到 $MODDIR（模块没装？）"
ok "远端模块目录存在"

# ── 推、收权限、逐文件对 sha 与模式 ───────────────────────────────────
# 说明：循环体里的每个 adb 调用都必须 `< /dev/null`。adb shell 会读 stdin，
#       不加这一步它会把喂给 while 的整份清单吃掉 —— 实测"组=shell 文件数=25"
#       却只推了 1 个文件就收工，剩下 24 个留在设备上过期。
n=0
want_n=$(printf '%s\n' "$FILES" | grep -c .)
# 清单走 fd 3，不占 stdin：adb 会读 stdin，靠"每条都记得加 </dev/null"是
# 一个会漏的约定（实测加了那一处仍然只推成 1 个 —— 命令替换里那两处还在吃）。
while IFS='|' read -r rel want <&3; do
    [ -n "$rel" ] || continue
    dest="$MODDIR/${rel#module/}"
    LOCAL=$(sha256sum "$rel" | cut -c1-64) || fail "本地算 sha 失败：$rel"
    # MSYS 会把 /data/... 改写成 D:\Git\data\... —— 这一条必须带这个变量
    MSYS2_ARG_CONV_EXCL='*' adb push "$rel" "$dest" >/dev/null 2>&1 || fail "adb push $rel 失败"
    adb shell "chmod $want $dest && chown root:root $dest 2>/dev/null; true" >/dev/null 2>&1

    REMOTE_SHA=$(adb shell "sha256sum $dest" 2>/dev/null | cut -c1-64 | tr -d '\r')
    [ "$REMOTE_SHA" = "$LOCAL" ] || fail "$rel 内容对不上
  本地 $LOCAL
  设备 $REMOTE_SHA"

    MODE=$(adb shell "stat -c '%a' $dest" 2>/dev/null | tr -d '\r')
    [ "$MODE" = "$want" ] || fail "$rel 权限不对：模式=$want 实得 $MODE（adb push 默认落 0666，
  而这个模块的文件由 root 加载执行，世界可写就是洞）"
    n=$((n + 1))
    ok "$(printf '%-42s' "$rel") sha=${LOCAL:0:12}… 模式=$MODE"
done 3<<EOF
$FILES
EOF

# 数量必须对上：n>0 这种判据挡不住"25 个只推了 1 个"
[ "$n" = "$want_n" ] || fail "清单上有 $want_n 个文件，只推成 $n 个 —— 剩下的在设备上是旧版"
printf '\n已部署 %s/%s 个文件到 %s（组=%s）\n' "$n" "$want_n" "$MODDIR" "$GROUP"
printf '界面上屏需要重开一次 WebUI；命令层是每次调用现读文件，不用重装。\n'
