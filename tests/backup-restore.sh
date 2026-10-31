#!/system/bin/sh
#=============================================================================
# tests/backup-restore.sh - 备份回滚：只认映射表、拒绝越界/空备份、往返一致
#
# 回滚是**破坏性**操作（把备份内容写回后端文件）。这条闸钉三件最容易出事的事：
#   ① 名字必须是映射表里的（不许用 ../ 之类的路径拼出任意文件）；
#   ② 空备份必须拒绝 —— 否则"回滚"会把目标文件清空；
#   ③ 回滚前先把当前文件存成 <名>.pre-restore，回滚本身可撤销。
#=============================================================================
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  ✗    %s\n' "$1"; fail=1; }

W=$(mktemp -d 2>/dev/null || echo "/tmp/klbak-$$"); mkdir -p "$W"
KL_DIR="$W"; KL_BACKEND=omk; OMK_INJECTOR="$W/injector.toml"; MODDIR="$W"
require_runnable() { :; }; detect_backend() { :; }; webui_lock() { :; }
release_lock() { :; }; kv() { :; }; log_info() { :; }; find_awk() { echo awk; }
KL_PATCH="/nonexistent/teesim.awk"

extract() {   # 文件 函数名
    s=$(grep -n "^$2() {" "$1" | head -1 | cut -d: -f1)
    [ -n "$s" ] || return 1
    e=$(awk -v s="$s" 'NR>s && /^\}/{ print NR; exit }' "$1")
    [ -n "$e" ] || return 1
    eval "$(sed -n "${s},${e}p" "$1")"
}
extract module/lib/backend.sh backup_target_for || { bad '抽不到 backup_target_for'; exit 1; }
extract module/lib/write.sh cmd_backup_restore || { bad '抽不到 cmd_backup_restore'; exit 1; }

printf '现在的值\n' > "$OMK_INJECTOR"
printf '备份里的值\n' > "$W/injector.toml.bak"
cmd_backup_restore 'injector.toml.bak'; rc=$?
[ "$rc" = 0 ] && ok '合法备份回滚成功' || bad "回滚退码 $rc"
[ "$(cat "$OMK_INJECTOR")" = '备份里的值' ] && ok '目标文件内容换成了备份内容' || bad '内容没换'
[ -f "$W/injector.toml.bak.pre-restore" ] \
    && [ "$(cat "$W/injector.toml.bak.pre-restore")" = '现在的值' ] \
    && ok '回滚前把当前文件存成了 .pre-restore' || bad '没有 .pre-restore（回滚不可撤销）'

printf 'x\n' > "$W/other.bak"
cmd_backup_restore 'other.bak' 2>/dev/null; [ "$?" != 0 ] && ok '映射表外的名字被拒' || bad '任意名字都能回滚'
cmd_backup_restore '../module.prop' 2>/dev/null; [ "$?" != 0 ] && ok '带 ../ 的名字被拒' || bad '../ 路径被放行'
cmd_backup_restore 'injector.toml.bak/../injector.toml.bak' 2>/dev/null; [ "$?" != 0 ] && ok '带 / 的名字被拒' || bad '带斜杠的名字被放行'

: > "$W/injector.toml.bak"
printf '目标不该被清空\n' > "$OMK_INJECTOR"
cmd_backup_restore 'injector.toml.bak' 2>/dev/null; [ "$?" != 0 ] \
    && [ "$(cat "$OMK_INJECTOR")" = '目标不该被清空' ] \
    && ok '空备份被拒，目标文件没被清空' || bad '空备份把目标文件清空了'

# 变异：把"备份非空"那条去掉，空备份必须能把文件清空 —— 否则上面那条是空转
extract module/lib/write.sh cmd_backup_restore
eval "$(grep -q '\[ -s "\$src" \]' module/lib/write.sh && echo ': 保留')" 2>/dev/null
body=$(sed -n "/^cmd_backup_restore() {/,/^}/p" module/lib/write.sh | sed 's/\[ -s "$src" \] || { echo "备份不存在或为空：$src" >&2; return 1; }/:/')
eval "$body"
printf '变异前\n' > "$OMK_INJECTOR"; : > "$W/injector.toml.bak"
cmd_backup_restore 'injector.toml.bak' 2>/dev/null
[ ! -s "$OMK_INJECTOR" ] && ok '变异「去掉非空校验」后空备份确实清空了目标 —— 上面那条不是空转' \
    || bad '变异没生效，空备份那条断言可能是空转'

rm -rf "$W"
[ "$fail" = 0 ] && echo '全部通过' || echo '有断言失败'
exit "$fail"
