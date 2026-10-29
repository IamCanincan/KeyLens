#!/system/bin/sh
#=============================================================================
# tests/omk-validation.sh - OhMyKeymint 字段校验必须真的会拒绝坏值
#
# 背景：这些字段以前一律走 valid_text 128，"auto" 敲成 "aut" 也存得进去，而 OMK
#       读不懂时静默退回默认值 —— 存进去了不等于生效了，界面上还看不出来。
# 所以这里不只测"好值过"，重点测"坏值被拒"：一条只放好值的测试等于没测。
#
# 跑法：sh tests/omk-validation.sh
#=============================================================================
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0

# 把 webui.sh 里那段校验函数抽出来跑（不 source 整个文件 —— 它末尾有 dispatch）。
# 起点取 valid_log_level 而不是 valid_omk_date：最后那组断言要同时跑
# config.toml 与 injector.toml 两条级别校验，只抽一条会调到不存在的函数，
# 得到的是"函数没定义"而不是"校验放过了坏值"。
start=$(grep -n '^valid_log_level() {' module/webui.sh | cut -d: -f1)
end=$(grep -n '^valid_inj_log_level() {' module/webui.sh | tail -1 | cut -d: -f1)
end=$(awk -v s="$end" 'NR>=s && /^\}/{ print NR; exit }' module/webui.sh)
if [ -z "$start" ] || [ -z "$end" ]; then
    printf '  ✗    抽不到校验函数（webui.sh 结构变了？）\n'; exit 1
fi
eval "$(sed -n "${start},${end}p" module/webui.sh)"
for f in valid_log_level valid_inj_log_level valid_omk_patch valid_omk_boot valid_omk_hash valid_omk_os_version; do
    # 每个函数都要真的存在，缺一个就是抽漏了
    if ! command -v "$f" >/dev/null 2>&1; then
        printf '  ✗    没抽到 %s\n' "$f"; exit 1
    fi
done
printf '  ok   从 webui.sh 抽出校验函数（第 %s–%s 行，原样跑，不是抄一份）\n' "$start" "$end"

HEX64=$(printf '%064d' 0 | sed 's/0/a/g')     # 正好 64 个 a

# chk 判据 期望 实际：期望 0=应通过 1=应拒绝
t() {  # t 函数名 值 期望(0|1) 说明
    "$1" "$2" 2>/dev/null; got=$?
    if [ "$got" = "$3" ]; then printf '  ok   %s(%s) %s\n' "$1" "$2" "$4"
    else printf '  ✗    %s(%s) 期望拒绝=%s 实得拒绝=%s ｜ %s\n' "$1" "$2" "$3" "$got" "$4"; fail=1; fi
}

printf '── 补丁级别（auto | latest | YYYY-MM-DD）──\n'
t valid_omk_patch auto 0 "关键字"
t valid_omk_patch latest 0 "关键字"
t valid_omk_patch 2024-01-05 0 "合法日期"
t valid_omk_patch aut 1 "少一个字母 —— 旧代码会放过去"
t valid_omk_patch 2024-13-01 1 "月份越界"
t valid_omk_patch 2024-00-10 1 "月份为 0"
t valid_omk_patch 2024-1-5 1 "没补零"
t valid_omk_patch 20240105 1 "紧凑写法 OMK 不认"
t valid_omk_patch '' 1 "空值"
t valid_omk_patch 'latest ; rm -rf /' 1 "混进分隔符"

printf '── boot 额外收十进制 u32 ──\n'
t valid_omk_boot auto 0 "关键字"
t valid_omk_boot 20240105 0 "紧凑写法在这里合法"
t valid_omk_boot 4 0 "单位数"
t valid_omk_boot 12345678901 1 "超过 u32 位数"
t valid_omk_boot -5 1 "负数"

printf '── vbmeta 键与哈希（auto | random | 64 hex）──\n'
t valid_omk_hash auto 0 "关键字"
t valid_omk_hash random 0 "关键字"
t valid_omk_hash "$HEX64" 0 "64 位十六进制"
t valid_omk_hash "${HEX64}a" 1 "65 位"
t valid_omk_hash "${HEX64%?}" 1 "63 位"
t valid_omk_hash "$(printf 'g%.0s' $(seq 1 64))" 1 "非十六进制"
t valid_omk_hash rnd 1 "拼错的关键字"

printf '── OS 版本是 MMmmss 编码值（0–99），不是年份 ──\n'
t valid_omk_os_version auto 0 "关键字"
t valid_omk_os_version 0 0 "下界"
t valid_omk_os_version 99 0 "上界"
t valid_omk_os_version 100 1 "越界"
t valid_omk_os_version 2016 1 "把年份填进来 —— 旧代码会放过去"
t valid_omk_os_version -1 1 "负数"

printf '── injector 的 log_level 多一个 warning 别名 ──\n'
t valid_inj_log_level warning 0 "config.toml 没有的别名"
t valid_inj_log_level trace 0 "共有值"
t valid_inj_log_level verbose 1 "不存在的级别"
valid_log_level warning 2>/dev/null
if [ $? = 1 ]; then printf '  ok   config.toml 那一侧仍然拒绝 warning（两条没被并成一条）\n'
else printf '  ✗    valid_log_level 竟然收了 warning —— 两条校验收敛成一条了\n'; fail=1; fi

printf '── 接线：校验函数必须真的挂在保存路径上 ──\n'
# 上面那些只证明"函数本身对"。如果 cmd_omk_save_config 里忘了换调用，
# 这些断言照样全绿，而坏值仍旧能存进去 —— 所以这一段单独钉"谁被调用了"。
body=$(awk '/^cmd_omk_save_config\(\) \{/,/^\}/' module/webui.sh)
if [ -z "$body" ]; then printf '  ✗    抽不到 cmd_omk_save_config 函数体\n'; fail=1; fi
# 判据要跟着 case 分支走：一个分支可能并列多个键（`a|b|c)`），
# 所以"键后面紧跟右括号"那种写法会漏掉并列在中间的键。
wired() {  # wired 键 校验函数 —— 命中该键的那一行之后、下一个分支之前的动作里找函数名
    printf '%s\n' "$body" | awk -v k="$1" -v f="$2" '
        /^[ \t]*[A-Za-z_|]+[ \t]*\)/ {
            if (arm) { exit }                 # 上一个分支的动作里没找到 → 停
            if (index($0, k ")") || index($0, k "|")) arm = 1
            next
        }
        arm && index($0, f) { found = 1; exit }
        END { exit found ? 0 : 1 }'
}
for pair in "trust_os_version:valid_omk_os_version" "trust_vb_key:valid_omk_hash" \
            "trust_security_patch:valid_omk_patch" "trust_os_patchlevel:valid_omk_patch" \
            "trust_vendor_patchlevel:valid_omk_patch" "trust_boot_patchlevel:valid_omk_boot"; do
    keys=${pair%:*}; fn=${pair#*:}
    if wired "$keys" "$fn"; then printf '  ok   %s → %s\n' "$keys" "$fn"
    else printf '  ✗    %s 没接上 %s（校验函数存在但没人调）\n' "$keys" "$fn"; fail=1; fi
done
inj=$(awk '/^cmd_omk_save_injector\(\) \{/,/^\}/' module/webui.sh)
if printf '%s' "$inj" | grep -q 'inj_log_level) valid_inj_log_level'; then
    printf '  ok   inj_log_level → valid_inj_log_level（带 warning 别名那条）\n'
else
    printf '  ✗    inj_log_level 没换到新校验\n'; fail=1
fi

[ "$fail" = 0 ] && echo "全部通过" || echo "有断言失败"
exit $fail
