#!/system/bin/sh
#=============================================================================
# tests/teesim-overrides-write.sh - overrides.json 写回的取值与白名单
#
# 判据全部对着上游抄（TEESimulator）：
#   可写字段  只有这六个：attestationSecurityLevel / keymasterSecurityLevel /
#             attestationVersion / keymasterVersion / verifiedBootKey / verifiedBootHash
#             （Harvester.kt:127-133 SYNTHESIZED_FIELDS + :183-189 那两条按采集结果放行）
#             其余是 OverrideSource.REQUIRED 锁死的，写进去守护进程**丢弃并记日志**
#             （Harvester.kt:403-405）—— 所以这里当场拒，不静默收下。
#   等级      0..2 = Software / TrustedEnvironment / StrongBox（Const.kt:75-77）。
#             **不是** KM1 那套 KEYSTORE=1/TEE=2/STRONGBOX=3：写 3 上游会丢。
#   版本      1..100000；启动键/哈希 = 可选 0x + 恰好 64 位十六进制 + 非全零
#             （Harvester.kt:423-432,1349-1358）
#   留空      删掉这个键（system-controller.js:75；Harvester.kt:409 空值复位默认）
#   生效方式  FileObserver 监听 overrides.json → resolveAndPush，不需要重启
#             （ConfigStore.kt:204-214）
#
# 跑法：sh tests/teesim-overrides-write.sh
#=============================================================================
set -u
cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d 2>/dev/null) || T="/tmp/tov-$$"
mkdir -p "$T"
# 建不出来就自己说清楚：这里死过一次（rc≠0 却一条 ✗ 都没打），只看得出"失败了"，
# 看不出"死在哪"。
[ -d "$T" ] || { echo '  ✗    临时目录建不起来（mktemp 与 /tmp 回退都失败）'; exit 1; }
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT
fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  ✗    %s\n' "$1"; fail=1; }

# 抽 webui.sh 里的真函数（抄一份的话，改坏实现测试也不会响）
for fn in valid_ov_level valid_ov_version valid_ov_hex; do
    start=$(grep -n "^$fn() {" module/webui.sh | cut -d: -f1 | head -1)
    [ -n "$start" ] || { bad "抽不到 $fn"; exit 1; }
    end=$(awk -v s="$start" 'NR>s && /^\}/{ print NR; exit }' module/webui.sh)
    [ -n "$end" ] || { bad "$fn 找不到结尾"; exit 1; }
    eval "$(sed -n "${start},${end}p" module/webui.sh)"
done
ok "从 webui.sh 抽出三个校验函数"

# want=0 通过 / 1 拒绝
a() {
    local fn="$1" val="$2" want="$3" label="$4" rc=0
    "$fn" "$val" >/dev/null 2>&1 || rc=1
    if [ "$rc" = "$want" ]; then printf '  ok   %s：[%s] → %s\n' "$label" "$val" "$rc"
    else printf '  ✗    %s：[%s] 期望 %s，实得 %s\n' "$label" "$val" "$want" "$rc"; fail=1; fi
}

printf '── 安全等级：只认 0..2，按数值不按字面 ──\n'
a valid_ov_level ''  0 '留空=删掉这一项'
a valid_ov_level '0' 0 'Software'
a valid_ov_level '1' 0 'TrustedEnvironment'
a valid_ov_level '2' 0 'StrongBox'
a valid_ov_level '3' 1 '3 会被上游丢弃'
a valid_ov_level '01' 0 '上游 toIntOrNull 认这个'
a valid_ov_level '02' 0 '同上'
a valid_ov_level '10' 1 '两位数就是越界'
a valid_ov_level '-1' 1 '负数'
a valid_ov_level '1.0' 1 '小数'
a valid_ov_level 'Software' 1 '要数字，不收名字'
a valid_ov_level ' 1' 1 '带空格（上游 toIntOrNull 也不认）'

printf '── 版本：1..100000 ──\n'
a valid_ov_version ''       0 '留空'
a valid_ov_version '1'      0 '下界'
a valid_ov_version '100000' 0 '上界'
a valid_ov_version '0'      1 '0 不算版本'
a valid_ov_version '100001' 1 '越上界'
a valid_ov_version '300'    0 '常见值'
a valid_ov_version '1e5'    1 '科学计数法'
a valid_ov_version '999999' 1 '六位但越界'
a valid_ov_version '007'    0 '按数值是 7'

printf '── 启动键/哈希：0x + 恰好 64 位十六进制 + 非全零 ──\n'
H64=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
U64=0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF
Z64=0000000000000000000000000000000000000000000000000000000000000000
a valid_ov_hex ''            0 '留空'
a valid_ov_hex "$H64"        0 '64 位'
a valid_ov_hex "0x$H64"      0 '带 0x 前缀'
a valid_ov_hex "0X$H64"      0 '带 0X 前缀'
a valid_ov_hex "$U64"        0 '大写十六进制'
a valid_ov_hex "${H64}0"     1 '65 位'
a valid_ov_hex "${H64%??}"   1 '62 位'
a valid_ov_hex "$Z64"        1 '全零（上游按"非零"判，Harvester.kt:1349-1358）'
a valid_ov_hex "0x$Z64"      1 '带前缀的全零也算全零'
a valid_ov_hex "${H64%?}g"   1 '混进非十六进制字符'
a valid_ov_hex "0x0x$H64"    1 '前缀重复'

printf '── 白名单：锁死字段当场拒，不静默收下 ──\n'
fn=$(awk '/^cmd_teesim_save_overrides\(\) \{/,/^\}/' module/webui.sh)
[ -n "$fn" ] || { bad '抽不到 cmd_teesim_save_overrides'; echo "有断言失败"; exit 1; }
for k in attestationSecurityLevel keymasterSecurityLevel attestationVersion keymasterVersion verifiedBootKey verifiedBootHash; do
    printf '%s' "$fn" | grep -q "$k" && : || bad "六个可写字段里 $k 没出现在白名单里"
done
ok '六个可写字段都在白名单里'
printf '%s' "$fn" | grep -q 'REQUIRED' \
    && ok '兜底分支点名"上游锁死为 REQUIRED"，不是含糊的未知字段' \
    || bad '兜底分支没说清为什么这个字段写了没用'
# deviceLocked / verifiedBootState / moduleHash / 标识类都是 REQUIRED 锁死的，
# 必须落到兜底分支 —— 它们出现在任何一个 case 分支里都等于本模块在写一封
# 守护进程会丢掉的信。
arms=$(printf '%s' "$fn" | sed -n '/case "\$k" in/,/esac/p')
leak=0
for k in deviceLocked verifiedBootState moduleHash osPatchLevel vendorPatchLevel serial imei meid brand; do
    case "$arms" in
        *"$k"*) bad "锁死字段 $k 竟然出现在白名单分支里"; leak=1 ;;
    esac
done
[ "$leak" = 0 ] && ok '锁死字段（deviceLocked/verifiedBootState/moduleHash/标识类）都不在白名单里'

printf '── 数据决定的可编辑性：问自家读汇总，不另判一套 ──\n'
printf '%s' "$fn" | grep -q 'teesim_overrides.awk' \
    && ok '启动键/哈希改前先查 harvested 判的 editable' \
    || bad '没查 editable —— 会写出守护进程根本不认的值'
printf '%s' "$fn" | grep -q 'chmod 644' \
    && ok '新建 overrides.json 后补 644（守护进程以 keystore 身份读它）' \
    || bad '没补模式：新建时会留成 600，守护进程读不到'
printf '%s' "$fn" | grep -q 'apply_note' \
    && ok '把"热生效、不需要重启"如实报给界面' \
    || bad '没报生效方式'

printf '── 写回本身：真 awk + 真形状（含删除） ──\n'
cat > "$T/overrides.json" <<EOF
{
  "attestationVersion": "300",
  "attestationSecurityLevel": "1",
  "verifiedBootKey": "$H64"
}
EOF
printf 'attestationVersion\t301\nattestationSecurityLevel\t2\nverifiedBootKey\t\nfutureField\tkeep\n' > "$T/pairs"
awk -v pairsfile="$T/pairs" -v statusfile="$T/st" -f module/backends/json_flat_set.awk "$T/overrides.json" > "$T/out" 2>"$T/err"
[ -s "$T/err" ] && bad "awk 有告警：$(cat "$T/err")" || ok 'awk 一声不响'
chk=$(cat "$T/st")
[ "$chk" = ok ] && ok 'status=ok' || bad "status=$chk"
grep -q '"attestationVersion": "301"' "$T/out" && ok '版本改了' || bad '版本没改'
grep -q '"attestationSecurityLevel": "2"' "$T/out" && ok '等级改了' || bad '等级没改'
grep -q 'verifiedBootKey' "$T/out" && bad '留空没删掉这一项' || ok '留空 = 删掉这一项'
# 顺序：原有两条保持原位，新键插在末尾（进程替换是 bash 扩展，这里用管道）
tr -d '\n' < "$T/out" | grep -q 'attestationVersion.*attestationSecurityLevel.*futureField' \
    && ok '新键插在末尾且原有顺序没动' || bad '顺序/插入不对'
# 产物必须是合法 JSON —— 手工删逗号这种事只有解析器会立刻抓出来
if command -v node >/dev/null 2>&1; then
    node -e 'const fs=require("fs");const d=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
      const k=Object.keys(d).sort().join(",");
      if (k!=="attestationSecurityLevel,attestationVersion,futureField") { console.log("键集不对:"+k); process.exit(1) }
      if (d.futureField!=="keep") { console.log("未知键的值没保住"); process.exit(1) }' "$T/out" \
        && ok '产物是合法 JSON，未知键原样保住' || bad '产物 JSON 不对'
else
    printf '  ·    本机没有 node，跳过 JSON 解析这一步（设备上正常）\n'
fi
# 再跑一遍同样的 pairs：必须是 same（幂等，不重复落盘）
cp "$T/out" "$T/overrides2.json"
awk -v pairsfile="$T/pairs" -v statusfile="$T/st2" -f module/backends/json_flat_set.awk "$T/overrides2.json" > "$T/out2"
# 第二单里 verifiedBootKey 已经不存在，留空对它应是 no-op → 仍要 same
printf 'attestationVersion\t301\nattestationSecurityLevel\t2\nfutureField\tkeep\n' > "$T/pairs3"
awk -v pairsfile="$T/pairs3" -v statusfile="$T/st3" -f module/backends/json_flat_set.awk "$T/overrides2.json" > "$T/out3"
chk3=$(cat "$T/st3")
[ "$chk3" = same ] && ok '重复写同样的值 = same（不落盘）' || bad "重复写报 $chk3，应为 same"
cmp -s "$T/out3" "$T/overrides2.json" && ok 'same 那一趟产物逐字节不变' || bad 'same 却改了内容'

printf '── 命令层接线 ──\n'
grep -q 'teesim-save-overrides) cmd_teesim_save_overrides' module/webui.sh \
    && ok '分发接上了 teesim-save-overrides' || bad '命令没接进分发'
grep -q 'teesim-save-overrides' module/webui.sh \
    && ok 'KL_COMMANDS 里声明了（界面才会摆出这个输入框）' || bad '没进声明清单'

[ "$fail" = 0 ] && echo "全部通过" || echo "有断言失败"
exit $fail
