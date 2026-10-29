#!/bin/sh
# 把 WebUI 推到设备，并自证真的到位（本地跑，不进刷机包）。
#
#   sh tools/deploy-webui.sh            只推已经提交过的版本
#   sh tools/deploy-webui.sh --allow-dirty   明知工作区有未提交改动也要推
#
# 为什么要这么长一条：这个 index.html 是管理器以 root 加载、里面的命令以 root 执行的。
# `adb push` 默认落 0666 —— 那等于任何应用都能改写一个以 root 跑的界面。
# 所以推完必须 chmod，而且这一条要能被机器验收，不能靠人记得。
set -u

MODDIR=/data/adb/modules/ts-auto-add
REMOTE=$MODDIR/webroot
FILES="index.html"
ALLOW_DIRTY=0
[ "${1:-}" = "--allow-dirty" ] && ALLOW_DIRTY=1

fail() { printf '✗ %s\n' "$1"; exit 1; }
ok()   { printf '  ok  %s\n' "$1"; }

command -v adb >/dev/null 2>&1 || fail "找不到 adb"
[ -d .git ] || [ -f .git ] || fail "请在仓库根目录跑（找不到 .git）"
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || fail "git rev-parse 失败"
cd "$ROOT" || fail "进不去仓库根"

# ── 入口闸门 ──────────────────────────────────────────────
dirty=""
for f in $FILES; do
  git diff --quiet -- "module/webroot/$f" 2>/dev/null || dirty="$dirty module/webroot/$f"
  git diff --cached --quiet -- "module/webroot/$f" 2>/dev/null || dirty="$dirty(已暂存) module/webroot/$f"
done
if [ -n "$dirty" ] && [ "$ALLOW_DIRTY" = 0 ]; then
  fail "这些文件有未提交改动：$dirty
  推上去的版本与仓库里的对不上，回头就没法说清设备上跑的是哪版。
  先提交，或确认要推就加 --allow-dirty"
fi
ok "工作区闸门（未提交改动：${dirty:-无}）"

for f in $FILES; do
  [ -f "module/webroot/$f" ] || fail "本地缺文件 module/webroot/$f"
done

adb get-state >/dev/null 2>&1 || fail "设备不在线（adb get-state 失败；锁屏久了要先解锁并点允许）"
# UID 在 shell 里是只读的（busybox/bash 都是），别拿它当变量名
AS_UID=$(adb shell "id -u" 2>/dev/null | tr -d '\r')
[ "$AS_UID" = "0" ] || fail "adb shell 不是 root（uid=$AS_UID）—— 先 adb root"
ok "设备在线且为 root"

adb shell "[ -d $REMOTE ]" 2>/dev/null || fail "设备上找不到 $REMOTE（模块没装？）"
ok "远端目录存在"

# ── 推、收权限、逐文件对 sha ──────────────────────────────
for f in $FILES; do
  LOCAL=$(sha256sum "module/webroot/$f" | cut -c1-64) || fail "本地算 sha 失败"
  # MSYS 会把 /data/... 改写成 D:\Git\data\... —— 这一条必须带这个变量
  MSYS2_ARG_CONV_EXCL='*' adb push "module/webroot/$f" "$REMOTE/$f" >/dev/null 2>&1 \
    || fail "adb push $f 失败"
  adb shell "chmod 644 $REMOTE/$f && chown root:root $REMOTE/$f 2>/dev/null; true" >/dev/null 2>&1

  REMOTE_SHA=$(adb shell "sha256sum $REMOTE/$f" 2>/dev/null | cut -c1-64 | tr -d '\r')
  [ "$REMOTE_SHA" = "$LOCAL" ] || fail "$f 内容对不上
  本地 $LOCAL
  设备 $REMOTE_SHA"

  MODE=$(adb shell "stat -c '%a %U:%G' $REMOTE/$f" 2>/dev/null | tr -d '\r')
  # 0777 与 0666 都算洞：这个文件以 root 身份被加载执行
  case "$MODE" in
    644*root*|444*root*) ok "$f  sha=$LOCAL  模式=$MODE" ;;
    *) fail "$f 权限过宽：模式=$MODE（应为 644 root:root —— adb push 默认落 0666，
  而这个界面由管理器以 root 加载、里面的命令以 root 执行）" ;;
  esac
done

printf '\n已部署：%s/%s\n' "$REMOTE" "$FILES"
printf '设备上重开一次 WebUI 才会读到新版（管理器不会自己重载）。\n'
