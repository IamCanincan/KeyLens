#!/system/bin/sh
#=============================================================================
# tests/omk-apply-scope.sh - OMK 的"生效代价"必须按这一单动了哪些字段算
#
# 上游规则（OhMyKeymint docs/CONFIGURATION.md:415-425）：
#   [trust].security_patch / os_patchlevel / vendor_patchlevel / boot_patchlevel
#     → **同一次保存里只动这四个**时 keymint 运行中整组热生效（已有 TA 原地更新，
#       在途操作与 per-boot 计数器不丢）；掺进别的字段就退回重启 keymint。
#   [trust].os_version、其余 [trust]、[main].log_level、[device]、[crypto] → 重启 keymint
#   vb_key / vb_hash 从 random → auto → 重启【整机】
#
# 以前 cmd_omk_save_config 无条件 omk_restart keymint：改一个补丁日期也会把用户在途
# 的密钥操作打断一次。
#
# 跑法：sh tests/omk-apply-scope.sh
#=============================================================================
set -u
cd "$(dirname "$0")/.." || exit 1
. tests/lib/kl-src.sh        # 命令层实现分两份（webui.sh + lib/write.sh），见该文件说明
fail=0

# 抽 webui.sh 里的真函数（抄一份的话，改坏实现测试也不会响）
for fn in omk_apply_scope omk_reboot_needed; do
    start=$(grep -n "^$fn() {" "$KL_SRC" | cut -d: -f1 | head -1)
    [ -n "$start" ] || { printf '  ✗    抽不到 %s\n' "$fn"; exit 1; }
    end=$(awk -v s="$start" 'NR>s && /^\}/{ print NR; exit }' "$KL_SRC")
    [ -n "$end" ] || { printf '  ✗    %s 找不到结尾\n' "$fn"; exit 1; }
    eval "$(sed -n "${start},${end}p" "$KL_SRC")"
    printf '  ok   从 webui.sh 抽出 %s（第 %s–%s 行）\n' "$fn" "$start" "$end"
done

chk() {  # chk <名字> <期望> <实际>
    if [ "$2" = "$3" ]; then printf '  ok   %s → %s\n' "$1" "$3"
    else printf '  ✗    %s 期望 %s，实得 %s\n' "$1" "$2" "$3"; fail=1; fi
}

P4="trust_security_patch trust_os_patchlevel trust_vendor_patchlevel trust_boot_patchlevel"
printf '── 分类：哪些字段组合能整组热生效 ──\n'
chk '四个补丁字段全动'        hot     "$(omk_apply_scope $P4)"
chk '只动其中一个'            hot     "$(omk_apply_scope trust_boot_patchlevel)"
chk '动两个'                  hot     "$(omk_apply_scope trust_security_patch trust_vendor_patchlevel)"
chk '四个 + os_version'       restart "$(omk_apply_scope $P4 trust_os_version)"
chk '四个 + 日志级别'         restart "$(omk_apply_scope $P4 cfg_log_level)"
chk '四个 + 生物识别开关'     restart "$(omk_apply_scope $P4 cfg_force_skip_biometric)"
chk '四个 + [device] 字段'    restart "$(omk_apply_scope $P4 dev_brand)"
chk '四个 + vb_key'           restart "$(omk_apply_scope $P4 trust_vb_key)"
chk '只动 os_version'         restart "$(omk_apply_scope trust_os_version)"
# 空参数：这条正常走不到（没字段就不会 saved=1），但**不许**报成 hot ——
# 报成 hot 就等于"什么都没做却告诉用户已经热生效"。
chk '空参数保守起见走 restart' restart "$(omk_apply_scope)"

printf '── vb_key / vb_hash：random → auto 才要重启整机 ──\n'
omk_reboot_needed random auto "" "" ; chk 'vb_key random→auto 需要重启整机' 0 "$?"
omk_reboot_needed "" "" random auto ; chk 'vb_hash random→auto 需要重启整机' 0 "$?"
omk_reboot_needed auto random "" "" ; chk '反向 auto→random 不算' 1 "$?"
omk_reboot_needed random "deadbeef" "" "" ; chk 'random→显式十六进制不算' 1 "$?"
omk_reboot_needed auto auto auto auto ; chk '两边都是 auto 不算' 1 "$?"
omk_reboot_needed "" "" "" "" ; chk '没提交这两个字段不算' 1 "$?"
omk_reboot_needed random random random auto ; chk 'vb_key 没变但 vb_hash 变了 → 仍要重启' 0 "$?"

printf '── 写路径确实接上了分类，不再无条件重启 ──\n'
fn=$(awk '/^cmd_omk_save_config\(\) \{/,/^\}/' "$KL_SRC")
printf '%s' "$fn" | grep -q 'omk_apply_scope \$keys' \
    && printf '  ok   保存路径按提交的字段集算代价\n' \
    || { printf '  ✗    cmd_omk_save_config 没调用 omk_apply_scope\n'; fail=1; }
printf '%s' "$fn" | grep -q 'omk_reboot_needed' \
    && printf '  ok   保存路径会单独判"要重启整机"那一档\n' \
    || { printf '  ✗    没判 random→auto\n'; fail=1; }
# omk_restart 只许出现在"不是 hot"那一支里：出现两次以上说明又退回无条件重启
r=$(printf '%s' "$fn" | grep -c 'omk_restart keymint')
chk '函数里只有一处 omk_restart' 1 "$r"
printf '%s' "$fn" | grep -q 'kv apply_scope' \
    && printf '  ok   结果回报给界面（apply_scope / apply_note）\n' \
    || { printf '  ✗    没把生效代价报出去\n'; fail=1; }

[ "$fail" = 0 ] && echo "全部通过" || echo "有断言失败"
exit $fail
