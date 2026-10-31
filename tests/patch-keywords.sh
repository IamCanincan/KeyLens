#!/system/bin/sh
#=============================================================================
# tests/patch-keywords.sh - 补丁值的大小写规则必须**按后端分叉**
#
# 上游逐行核过的事实（2026-10-30）：
#   · 关键字 no / today / system_property / device_default / prop
#     两家都是 ignoreCase 比较（TEESimulator DeviceProps.kt:116-131、
#     TrickyStoreOSS AndroidUtils.kt:148-156）→ 校验不能大小写敏感，否则误拒合法值。
#   · 日期模板令牌的大小写**两家相反**：
#       TEESim  DeviceProps.kt:156  `v.contains("YYYY")` —— 只认大写；
#       Tricky  AndroidUtils.kt:167-171 三个 replace 全带 ignoreCase = true。
#     所以 `yyyy-mm-dd` 在 Tricky 那边真能用，在 TEESim 这边不会被替换、
#     随后解析失败、该标签被**静默省略**。
#   · 裸令牌（`YYYY` / `MM` / `DD` 单独出现）替换完只剩两三位数字，过不了
#     上游自己的 \d{6}|\d{8}|\d{4}-\d{2}… 判据 → 静默不报。收下来等于骗用户
#     "设好了"，所以判死。
#   · `no` 的含义两家**相反**：TEESim 报 0（DeviceProps.kt:116），
#     Tricky 是 DO_NOT_REPORT、整个组件标签被省略（CertificateHack.kt:55）。
#
# 跑法：sh tests/patch-keywords.sh
#=============================================================================
set -u
cd "$(dirname "$0")/.." || exit 1
. tests/lib/kl-src.sh        # 命令层实现分两份（webui.sh + lib/write.sh），见该文件说明
fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  ✗    %s\n' "$1"; fail=1; }

# 抽 webui.sh 里的真函数来跑（抄一份的话，改坏了实现测试也不会响）
extract() {
    local start end
    start=$(grep -n "^$1() {" "$KL_SRC" | cut -d: -f1 | head -1)
    [ -n "$start" ] || { echo "抽不到 $1" >&2; return 1; }
    end=$(awk -v s="$start" 'NR>s && /^\}/{ print NR; exit }' "$KL_SRC")
    [ -n "$end" ] || { echo "$1 找不到结尾" >&2; return 1; }
    sed -n "${start},${end}p" "$KL_SRC"
    printf '%s\n' "$1 第 ${start}-${end} 行" >&2
}

eval "$(extract lower 2>/dev/null)" || exit 1
eval "$(extract valid_patch 2>/dev/null)" || exit 1
eval "$(extract valid_tricky_patch 2>/dev/null)" || exit 1
command -v valid_patch >/dev/null 2>&1 || { echo '  ✗    两个校验函数没抽出来'; exit 1; }

# 断言工具：want = 0 期望通过，1 期望拒绝；实际值一律打出来，防止"永远返回 1"的假绿
a() {
    local fn="$1" val="$2" want="$3" label="$4" rc=0
    "$fn" "$val" >/dev/null 2>&1 || rc=1
    if [ "$rc" = "$want" ]; then ok "$label：[$val] → ${rc}"; else bad "$label：[$val] 期望 ${want}，实得 ${rc}"; fi
}

printf '── TEESim：关键字不分大小写，日期令牌只认大写 ──\n'
a valid_patch 'no' 0 'TEESim'
a valid_patch 'NO' 0 'TEESim 大写关键字'
a valid_patch 'No' 0 'TEESim 混合大小写关键字'
a valid_patch 'today' 0 'TEESim'
a valid_patch 'TODAY' 0 'TEESim'
a valid_patch 'system_property' 0 'TEESim'
a valid_patch 'SYSTEM_PROPERTY' 0 'TEESim'
a valid_patch '' 0 'TEESim 留空=用采集值'
a valid_patch 'YYYY-MM-05' 0 'TEESim 默认模板'
a valid_patch 'YYYY-MM-DD' 0 'TEESim'
a valid_patch '2024-01-05' 0 'TEESim'
a valid_patch '20240105' 0 'TEESim'
a valid_patch '202401' 0 'TEESim'
a valid_patch 'yyyy-mm-dd' 1 'TEESim 小写日期令牌（上游不替换它）'
a valid_patch 'YYYY' 1 'TEESim 裸令牌'
a valid_patch 'MM' 1 'TEESim 裸令牌'
a valid_patch 'DD' 1 'TEESim 裸令牌'
a valid_patch 'harvested' 1 'TEESim 那个写法守护进程没实现'
a valid_patch '2024-13-01' 1 'TEESim 月份越界'
a valid_patch 'nonsense' 1 'TEESim'

printf '── Tricky：关键字与令牌都不分大小写 ──\n'
a valid_tricky_patch 'no' 0 'Tricky'
a valid_tricky_patch 'NO' 0 'Tricky 大写关键字'
a valid_tricky_patch 'device_default' 0 'Tricky'
a valid_tricky_patch 'DEVICE_DEFAULT' 0 'Tricky 大写关键字'
a valid_tricky_patch 'prop' 0 'Tricky'
a valid_tricky_patch 'PROP' 0 'Tricky 大写关键字'
a valid_tricky_patch 'YYYY-MM-DD' 0 'Tricky'
a valid_tricky_patch 'yyyy-mm-dd' 0 'Tricky 小写令牌（replace 带 ignoreCase）'
a valid_tricky_patch 'YyYy-Mm-Mm-05' 1 'Tricky 交错大小写不属任何一种式子'
a valid_tricky_patch '2024-01' 0 'Tricky'
a valid_tricky_patch '2024-01-05' 0 'Tricky'
a valid_tricky_patch '20240105' 0 'Tricky'
a valid_tricky_patch '202401' 0 'Tricky'
a valid_tricky_patch 'YYYY' 1 'Tricky 裸令牌'
a valid_tricky_patch 'mm' 1 'Tricky 裸令牌（小写也算裸）'
a valid_tricky_patch 'today' 1 'Tricky 没有 today 这个关键字'

printf '── 差异对照：同一条输入，两家结论必须不同 ──\n'
# 这条是整个套子的意义所在：如果两个函数其实共用一套判据，这里必红。
if valid_patch 'yyyy-mm-dd'; then bad '小写日期令牌在 TEESim 侧竟然通过（差异对照失效）'; else ok '小写日期令牌：TEESim 拒'; fi
if valid_tricky_patch 'yyyy-mm-dd'; then ok '小写日期令牌：Tricky 收'; else bad '小写日期令牌在 Tricky 侧被拒（差异对照失效）'; fi
if valid_patch 'today' && ! valid_tricky_patch 'today'; then ok 'today 只有 TEESim 认'; else bad 'today 的分叉没体现出来'; fi
if valid_tricky_patch 'prop' && ! valid_patch 'prop'; then ok 'prop/device_default 只有 Tricky 认'; else bad 'prop 的分叉没体现出来'; fi

printf '── 报错文案带上了被拒的字段与值（只说"不合法"用户没法改） ──\n'
n=$(grep -ac '补丁值不合法：$k = $v' "$KL_SRC")
if [ "$n" -ge 2 ]; then ok "两处写路径都点名 \$k = \$v（命中 ${n} 处）"; else bad "只有 ${n} 处点名，另一家还停在只报字段名"; fi

[ "$fail" = 0 ] && echo "全部通过" || echo "有断言失败"
exit $fail
