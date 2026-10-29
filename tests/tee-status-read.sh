#!/system/bin/sh
#=============================================================================
# tests/tee-status-read.sh - tee_status 的第四行必须读得到
#
# 上游写这个文件是四行一次写出、不留尾换行（TrickyStoreOSS config/Config.kt:140-143）。
# `while read` 在最后一行缺换行符时直接结束循环，丢的正好是 teeBroken ——
# 也就是"这台机器为什么只能走叶证书"的那个答案。真机验过旧写法只读到三行。
#
# 跑法：sh tests/tee-status-read.sh
#=============================================================================
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0

# 抽 cmd_tee_status 的真身来跑（不抄一份）：抄的那份怎么改都不会响
start=$(grep -n '^cmd_tee_status() {' module/webui.sh | cut -d: -f1)
end=$(awk -v s="$start" 'NR>s && /^\}/{ print NR; exit }' module/webui.sh)
[ -n "$start" ] && [ -n "$end" ] || { echo '  ✗    抽不到 cmd_tee_status'; exit 1; }
eval "$(sed -n "${start},${end}p" module/webui.sh)"
command -v cmd_tee_status >/dev/null 2>&1 || { echo '  ✗    函数没定义'; exit 1; }
kv() { printf '%s=%s\n' "$1" "$2"; }
printf '  ok   从 webui.sh 抽出 cmd_tee_status（第 %s–%s 行）\n' "$start" "$end"

dir=$(mktemp -d 2>/dev/null || echo /tmp/tts-$$); mkdir -p "$dir"
TSTORE_DIR="$dir"

# ① 上游的真实形状：四行、无尾换行
printf 'status=UNAVAILABLE\ncategory=not_run\nserviceErrorCode=none\nteeBroken=unknown' > "$dir/tee_status"
out=$(cmd_tee_status)
n=$(printf '%s\n' "$out" | grep -c .)
# present + file + 上游那四项 = 6 行
if [ "$n" = 6 ]; then printf '  ok   无尾换行时四行全读到\n'
else printf '  ✗    只读到 %s 行（最后一行被吞）：\n%s\n' "$n" "$out"; fail=1; fi
printf '%s' "$out" | grep -q '^tee_broken=unknown$' \
    && printf '  ok   tee_broken 在（值 unknown）\n' \
    || { printf '  ✗    tee_broken 丢了\n'; fail=1; }
printf '%s' "$out" | grep -q '^category=not_run$' \
    && printf '  ok   category 原样透传（它是开放集合，不能当封闭枚举校验）\n' \
    || { printf '  ✗    category 没读到\n'; fail=1; }
# 正对照：上游文件里是 serviceErrorCode（小驼峰），命令层输出的是 service_error_code。
# 界面读的是后者 —— 只断言"读到了某行"的话，把键名改回小驼峰也不会响。
printf '%s' "$out" | grep -q '^service_error_code=none$' \
    && printf '  ok   serviceErrorCode → service_error_code（命令层键名与界面一致）\n' \
    || { printf '  ✗    service_error_code 没按命令层键名输出：\n%s\n' "$out"; fail=1; }
printf '%s' "$out" | grep -q '^serviceErrorCode=' \
    && { printf '  ✗    输出里混进了上游的小驼峰键，界面读不到\n'; fail=1; } \
    || printf '  ok   输出不含上游小驼峰键\n'

# ② 带尾换行也要正常（别把修好变成只对一半）
printf 'status=AVAILABLE\ncategory=none\nserviceErrorCode=13\nteeBroken=false\n' > "$dir/tee_status"
printf '%s' "$(cmd_tee_status)" | grep -q '^tee_broken=false$' \
    && printf '  ok   带尾换行同样读到第四行\n' || { printf '  ✗    带尾换行反而读不到\n'; fail=1; }

# ③ 文件不存在：present=0，不是报错（Tricky 没装是正常状态）
rm -f "$dir/tee_status"
o3=$(cmd_tee_status); rc3=$?
if [ "$o3" = "present=0" ] && [ "$rc3" = 0 ]; then printf '  ok   文件不存在 → present=0 且退 0\n'
else printf '  ✗    文件不存在时行为不对：[%s] rc=%s\n' "$o3" "$rc3"; fail=1; fi

# ④ 只有两行的残缺文件：读到什么报什么，不瞎补
printf 'status=FAILED\nteeBroken=true' > "$dir/tee_status"
o4=$(cmd_tee_status)
printf '%s' "$o4" | grep -q '^status=FAILED$' && printf '%s' "$o4" | grep -q '^tee_broken=true$' \
    && printf '  ok   残缺文件：有的键照报，缺的键不编\n' || { printf '  ✗    残缺文件读错：\n%s\n' "$o4"; fail=1; }

rm -rf "$dir"
[ "$fail" = 0 ] && echo "全部通过" || echo "有断言失败"
exit $fail
