#!/system/bin/sh
#=============================================================================
# tests/write-hygiene.sh - 写入路径的三件卫生事：umask、awk 定位、备份名
#
# 三条都是 2026-10-31 全量审计里抓出来的，各自都"不影响功能测试跑通"，所以
# 需要一个专门钉它们的套子：
#   ① 管理器 exec 出来的 shell 继承的 umask 可能是 000（lib/applist.sh 里就记着
#      实测生成过 666 的状态文件）。而 keybox 私钥是先 `> "$tmp"` 落盘、之后才
#      由 write_atomic_preserve 恢复模式 —— 默认 666 的话，中间那几百毫秒任何应用
#      都能读走私钥。所以 webui.sh 必须在分派前 umask 077。
#   ② 这个模块专门有 find_awk（AWK_CMD），因为有的设备 /system/bin 里没有 awk。
#      但库里还有几处直接写 `awk`，那种设备上核心集合运算会静默失败。
#   ③ commit_backend_file 的第 3 个参数是"备份文件名"，它自己会拼 ${KL_DIR}/；
#      传绝对路径就会拼成 /data/adb/omk//data/adb/omk/overrides.json.bak，
#      cp 失败又被 2>/dev/null 吞掉 —— 那个文件从此没有回滚副本。
#
# 跑法：sh tests/write-hygiene.sh
#=============================================================================
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0

chk() { if [ "$2" = 0 ]; then printf '  ok   %s\n' "$1"; else printf '  ✗    %s\n' "$1"; fail=1; fi; }

# ── ① umask ──────────────────────────────────────────────────────────
u=$(grep -n '^umask 077$' module/webui.sh | head -1 | cut -d: -f1)
d=$(grep -n '^case "\$CMD" in' module/webui.sh | head -1 | cut -d: -f1)
[ -n "$u" ] && [ -n "$d" ] && [ "$u" -lt "$d" ]
chk "webui.sh 在分派前就 umask 077（第 $u 行 < 分派第 $d 行）" $?
# 需要对外可读的那两处必须各自显式 chmod，否则 077 会把它们关死
grep -q 'chmod 644 "\$dir"/\*\.png' module/webui.sh
chk '图标 PNG 有显式 chmod 644（不被新 umask 关掉）' $?
grep -q 'chmod 644 "\$ov"' module/lib/write.sh
chk 'overrides.json 有显式 chmod 644（守护进程要以 keystore 身份读）' $?

# ──  不许有裸 awk ──────────────────────────────────────────────────
# pattern 必须用单引号：放进双引号时 `${` 会被 shell 当变量展开，grep 根本没跑，
# "命中 0 处"于是是假绿（这一版差点就这样过去）。
# 判据只看"命令位置上的 awk"（`awk -…` / `awk '…'`）：这样散文里的 "awk"、
# `kv awk "$awk_v"`、文件名 `keybox_check.awk` 都不会误伤；tools.sh 是 find_awk
# 本体（它就是要拿裸 awk 去探测），所以不扫它。
files=$(ls module/lib/*.sh module/webui.sh | grep -v 'lib/tools.sh')
n=$(grep -nE "awk[ ]+(-|')" $files | grep -v 'AWK_CMD' | grep -vE ':[0-9]+:[[:space:]]*#' | grep -c . || true)
[ "$n" = 0 ]
chk "库与命令层里没有裸 awk 调用（命中 $n 处，要 0 处）" $?
[ "$n" != 0 ] && grep -nE "awk[ ]+(-|')" $files | grep -v 'AWK_CMD' | head -4
m=$(grep -c 'AWK_CMD:-awk' module/lib/*.sh | awk -F: '{s+=$2} END {print s+0}')
[ "$m" -ge 4 ]
chk "改走 \${AWK_CMD:-awk} 的位置数得到 $m 处（≥4，防判据自己数瞎）" $?

# ──  备份名必须是裸文件名 ───────────────────────────────────────────
bad=$(grep -c 'commit_backend_file "[^"]*" "[^"]*" "\${KL_DIR}' module/lib/write.sh || true)
[ "$bad" = 0 ]
chk "commit_backend_file 的第 3 参不传绝对路径（命中 $bad 处，要 0 处）" $?
g=$(grep -c 'commit_backend_file "\$ov" "\$out" "overrides.json.bak"' module/lib/write.sh)
[ "$g" = 1 ]
chk "overrides 那条确实传了裸名 overrides.json.bak（$g 处，要 1 处）" $?

# ── 变异：三条各打断一次，都要点名响 ──────────────────────────────────
work=$(mktemp -d 2>/dev/null || echo /tmp/klwh-$$); mkdir -p "$work"
cp module/webui.sh module/lib/write.sh module/lib/backend.sh "$work/"

sed '/^umask 077$/d' "$work/webui.sh" > "$work/w1"
cmp -s "$work/webui.sh" "$work/w1"; [ "$?" = 1 ]
chk '变异 ① 落地（umask 行被删）' $?
[ "$(grep -c '^umask 077$' "$work/w1")" = 0 ]
chk '变异 ①「删掉 umask 077」正是第一条判据要抓的形状' $?

sed 's|commit_backend_file "\$ov" "\$out" "overrides.json.bak"|commit_backend_file "$ov" "$out" "${KL_DIR}/overrides.json.bak"|' \
    "$work/write.sh" > "$work/w2"
cmp -s "$work/write.sh" "$work/w2"; [ "$?" = 1 ]
chk '变异 ② 落地（备份名改回绝对路径）' $?
[ "$(grep -c 'commit_backend_file "[^"]*" "[^"]*" "\${KL_DIR}' "$work/w2")" = 1 ]
chk '变异 ②「备份传绝对路径」被第三条判据抓到' $?

# 变异 ③：把一处 ${AWK_CMD:-awk} 退回裸 awk —— 用与上面**同一条**计数管道去抓它，
# 证明那条判据不是恒 0 的摆设。
cp module/lib/applist.sh "$work/applist.sh"
sed 's|\${AWK_CMD:-awk} -v adopt=|awk -v adopt=|' "$work/applist.sh" > "$work/a1"
cmp -s "$work/applist.sh" "$work/a1"; [ "$?" = 1 ]
chk '变异 ③ 落地（一处退回裸 awk）' $?
# 过滤注释：grep -n 单文件时的输出是「行号:正文」，多文件才是「路径:行号:正文」——
# 原来只写 `:[0-9]+:`，单文件那支永远匹配不上（2026-11-03 一条缩进注释把它顶成 2 处）。
n3=$(grep -nE "awk[ ]+(-|')" "$work/a1" | grep -v 'AWK_CMD' | grep -vE '(:|^)[0-9]+:[[:space:]]*#' | grep -c . || true)
[ "$n3" = 1 ]
chk "变异 ③「退回裸 awk」被同一条计数管道抓到（命中 $n3 处，要 1 处）" $?
rm -rf "$work"

if [ "$fail" = 0 ]; then echo '全部通过'; else echo '有断言失败'; fi
exit "$fail"
