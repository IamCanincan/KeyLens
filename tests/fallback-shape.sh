#!/bin/sh
#=============================================================================
# tests/fallback-shape.sh - 回退层的「生产形状」自检（CI 跑，不需要设备）
#
# 为什么单独一整套：参照 awk 自阶段 5 起**不随模块发布**（docs/AWK-REMOVAL.md），
# 所以真机上的 shell 回退层永远处于"缺参照"的形状。而其余 53 套与 276 项对拍都把
# KL_PATCH 指向 tests/fixtures/backends/ —— 那儿 awk 齐全，于是"缺参照时该说什么"
# 这条分支从来没被任何闸跑过。真机上量到的结果是：
#   KL_USE_RUST=0 … targets → 0 行、退码 0   （Rust 层同一命令 131 行）
# 界面把那份空画成"名单是空的"，而「加入一个应用」会拿这份空当基线重写文件。
#
# 这一套用**没有 awk 的临时根**跑同一批函数，钉两件事：
#   ① 读不到必须报错（退码非 0 + 一句说清缺什么、该怎么办），不许交空结果；
#   ② 写路径必须因此拒绝，且**目标文件一个字节都不许变**。
#
# 套件自己立的四条规矩（前三条第一版都踩过）：
#   · 被断言的调用**不许把 stderr 丢进 /dev/null**。第一次跑是 add_target_apps 撞上
#     set -u 的未定义变量、当场打死整个 shell，stderr 被吞 ⇒ 输出一路 "ok" 却退 1，
#     看不出坏在哪一行。现在每条调用各留一份 .err，失败时原样印出来。
#   · 走不到最后一行就是红（下面的 EXIT trap）："全部 ok + 退码不对"也是另一种假绿。
#   · 被测文件和副作用的落点必须分开。第一版把 TARGET_FILE 当 module.prop 喂给
#     run_sync，mark_module_failed 就顺手 sed 改了正要检查的那个文件 —— 因为 toml 里
#     没有 description= 行，cksum 恰好没变，这条检查等于自己蒙自己。
#   · 源码扫描必须自带开火对照（3.6）：扫描器被改坏成"恒 0"时，3.3/3.4 会安静地一直绿，
#     和"这仓库本来就干净"输出完全一样。
#=============================================================================
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/module/lib/applist.sh"
. "$ROOT/module/lib/backend.sh"

fail=0
n_chk=0
reached_end=""
T=$(mktemp -d)
on_exit() {
    _rc=$?
    if [ -z "$reached_end" ]; then
        printf '  ✗    套件没走到最后一行（打到第 %s 条就死了）—— 这不是"通过"\n' "$n_chk"
        _rc=1
    fi
    rm -rf "$T"
    exit "$_rc"
}
trap on_exit EXIT

# 这一整套测的就是回退层，显式关掉 Rust 快路：否则哪天主机上出现一个 keylens，
# run_sync 会去调它，测的就不再是 shell 分支。
KL_USE_RUST=0
AWK_CMD="awk"
FAKE_FIND_AWK="awk"
find_awk() { printf '%s\n' "$FAKE_FIND_AWK"; }   # 由每条断言决定"这台机有没有 awk"
log_info() { :; }
log_err() { :; }
log_warn() { :; }
cmd() { printf '%s\n' "${FAKE_INSTALLED:-}"; }
pm() { cmd; }

ok() { n_chk=$((n_chk + 1)); printf '  ok   %s\n' "$1"; }
no() { n_chk=$((n_chk + 1)); printf '  ✗    %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; fail=1; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "期望 [$2]，实得 [$3]"; fi; }
# chk_rc <名> <期望退码> <实得退码> [stderr 文件]
chk_rc() {
    if [ "$2" = "$3" ]; then ok "$(printf '%-40s rc=%s' "$1" "$3")"
    else no "$(printf '%-40s' "$1")" "期望 rc=$2，实得 $3${4:+ ｜ stderr=$(tr '\n' ' ' < "$4" 2>/dev/null)}"; fi
}
# run <函数…>：stdout 进 _o，退码进 _rc，stderr 落到 T/_err（调用方自己改名保存）
run() { _o=$("$@" 2>"$T/_err"); _rc=$?; }

count_lines() { printf '%s\n' "$1" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' '; }

# 源码扫描：把每个可疑写法连「文件名:行号」一起印出来 —— 变红时下一步该改哪一行就写在输出里。
# 用法：scan_sources <pipe|silent> <文件…>
# 一律用 index() 找符号，不写转义竖线：这套件的写法在编辑器里被改坏过两次（gsub 的正则、
# grep 的模式都变过形），index() 里没有可转义的字符，坏了会直接变成"开火对照不响"而被 3.6 抓住。
scan_sources() {
    _mode="$1"; shift
    awk -v mode="$_mode" '
        {
            g = $0
            sub(/^[ \t]*#.*/, "", g)                          # 注释行不参与
            if (index(g, "current_target_apps") == 0) next
            if (mode == "pipe") {
                x = g
                while ((k = index(x, "||")) > 0)               # 先折掉双竖线（正确写法的一部分）
                    x = substr(x, 1, k - 1) " " substr(x, k + 2)
                if (index(x, "|") > 0) print FILENAME ":" FNR
            } else if (mode == "silent") {
                if (index(g, "2>/dev/null") == 0) next          # 没吞 stderr 就不算这一类
                if (index(g, "||") > 0) next                    # 自己带退了码
                if (g ~ /^[ \t]*(if|while|until)/) next         # 站在条件位上，退码由 then/else 消化
                print FILENAME ":" FNR
            }
        }' "$@"
}

# ── 生产形状：backends/ 目录里一份 awk 都没有（就像装机那样） ──
mkdir -p "$T/state" "$T/backends"
KL_DIR="$T/state"
ST_INSTALLED="$KL_DIR/.kl_installed_last"; : > "$ST_INSTALLED"
ST_INSTALLED_NEW="$KL_DIR/.kl_installed.new"
ST_EVER="$KL_DIR/.kl_ever"; : > "$ST_EVER"
ST_EVER_NEW="$KL_DIR/.kl_ever.new"
KL_BACKEND="omk"
KL_PATCH="$T/backends/omk.awk"          # 锚点：目录存在、里面没有 *.awk
TARGET_FILE="$T/injector.toml"
printf 'version = 1\nscoop = [\n  "com.a",\n  "com.b",\n]\n' > "$TARGET_FILE"
PROP="$T/module.prop"
printf 'id=keylens\ndescription=旧文案\n' > "$PROP"
# lib/core.sh 在生产里给、这套件不 source 它就得自己补的变量。第一次跑就是漏了
# OMK_STATE_DIR：add_target_apps 写成功后要发重载请求，set -u 当场打死整个 shell。
OMK_STATE_DIR="$T/omk"
mkdir -p "$OMK_STATE_DIR"
# 已装列表：真机上永远不是空的。留空的话同步这条路会在"已装为空"那一档就先放弃，
# 后面所有"基线读不到所以必须拒绝"的断言都会**因为错误的原因**通过（空候选的闸）。
FAKE_INSTALLED="package:com.zzz"

echo "── 1 读：三个后端在缺参照时都必须报错，不许交空结果 ──"
for _b in omk teesim tricky; do
    KL_BACKEND="$_b"
    run current_target_apps
    mv -f "$T/_err" "$T/e1" 2>/dev/null
    chk_rc "$_b：退码非 0" "2" "$_rc" "$T/e1"
    chk "$_b：没把空名单当成正常结果交回" "" "$_o"
    grep -q -- "${_b}_list.awk" "$T/e1" && ok "$_b：stderr 点名缺哪个参照" \
        || no "$_b：stderr 没点名参照" "stderr=$(tr '\n' ' ' < "$T/e1")"
    grep -q -- "bin/keylens" "$T/e1" && ok "$_b：stderr 给出下一步（正式实现是 bin/keylens）" \
        || no "$_b：stderr 没给下一步" "stderr=$(tr '\n' ' ' < "$T/e1")"
done
# 另一种真机形状：这台机上连 awk 都找不到（精简 root / 未装 busybox），同样不许交空结果。
KL_BACKEND="omk"
AWK_CMD=""
FAKE_FIND_AWK=""
run current_target_apps
mv -f "$T/_err" "$T/e2" 2>/dev/null
chk_rc "没有 awk 时同样退 2" "2" "$_rc" "$T/e2"
chk "没有 awk 时也交回空以外的东西" "" "$_o"
grep -q -- "awk 命令" "$T/e2" && ok "stderr 说的是缺 awk 命令（不是缺脚本）" \
    || no "stderr 没点名 awk" "stderr=$(tr '\n' ' ' < "$T/e2")"
FAKE_FIND_AWK="awk"
AWK_CMD="awk"

echo "── 2 写：三条写路径都必须拒绝，且文件一个字节不变 ──"
before=$(cksum "$TARGET_FILE")
printf 'com.c\n' > "$T/req"
add_target_apps "$T/req" >"$T/o" 2>"$T/e3"; rc=$?
chk_rc "add_target_apps 拒绝（不拿空基线重写）" "2" "$rc" "$T/e3"
chk "目标文件没被动过（加入）" "$before" "$(cksum "$TARGET_FILE")"

remove_target_apps "$T/req" >"$T/o" 2>"$T/e4"; rc=$?
[ "$rc" != "0" ] && ok "remove_target_apps 也拒绝（rc=$rc）" \
    || no "remove_target_apps 在缺参照时返回 0" "stderr=$(tr '\n' ' ' < "$T/e4")"
chk "目标文件没被动过（移出）" "$before" "$(cksum "$TARGET_FILE")"

KL_EMPTY_OK=1 run_sync "$PROP" "$T/tmp" >"$T/o" 2>"$T/e5"; rc=$?
chk_rc "run_sync 连「读到空当真处理」也拒绝" "2" "$rc" "$T/e5"
chk "目标文件没被动过（同步）" "$before" "$(cksum "$TARGET_FILE")"
grep -q '^description=.*写入失败' "$PROP" && ok "同步失败如实写进模块描述（不是静默）" \
    || no "模块描述没标失败" "prop=$(tr '\n' ' ' < "$PROP")"
KL_EMPTY_OK=0

echo "── 2b 半坏的 installation：writer 还在、reader 没了 —— 这才是 129 条被写成 1 条的那条路 ──"
# 上面第 2 节里 writer（omk.awk）和 reader（omk_list.awk）一起缺，所以"拒绝"有一半是 writer
# 自己挡的；真机上更危险的是**参照脚本只剩一半**：读会失败，而写完全能落盘。那时如果
# add_target_apps 不带退码地拿 cur，combo 就只剩新加的那一条，一次「加入一个应用」把整份
# 名单换掉。这一节用"只拷走 omk.awk"造出这个形状，删掉那行 `|| return 2` 就会当场变红。
mkdir -p "$T/partial"
cp "$ROOT/tests/fixtures/backends/omk.awk" "$T/partial/omk.awk"
KL_PATCH="$T/partial/omk.awk"
run current_target_apps
mv -f "$T/_err" "$T/e8" 2>/dev/null
chk_rc "只缺 list 参照时读仍然报错" "2" "$_rc" "$T/e8"
chk "writer 可用（否则这一节测不到落盘）" "0" "$([ -f "$KL_PATCH" ] && echo 0 || echo 1)"
before_b=$(cksum "$TARGET_FILE")
add_target_apps "$T/req" >"$T/o" 2>"$T/e9"; rc=$?
chk_rc "基线读不到 → 加入必须拒绝" "2" "$rc" "$T/e9"
chk "名单没被重写成只剩新加的那一条" "$before_b" "$(cksum "$TARGET_FILE")"
grep -q '"com.b"' "$TARGET_FILE" && ok "原有两条还在" || no "原有条目被吃掉了" "目标文件=$(tr '\n' ' ' < "$TARGET_FILE")"
remove_target_apps "$T/req" >"$T/o" 2>"$T/e10"; rc=$?
[ "$rc" != "0" ] && ok "基线读不到 → 移出也拒绝（rc=$rc）" \
    || no "基线读不到时 remove_target_apps 返回 0" "stderr=$(tr '\n' ' ' < "$T/e10")"
chk "名单没被移出这条路改动" "$before_b" "$(cksum "$TARGET_FILE")"
PROP2="$T/module2.prop"
printf 'id=keylens\ndescription=旧文案\n' > "$PROP2"
KL_EMPTY_OK=1 run_sync "$PROP2" "$T/tmp2" >"$T/o" 2>"$T/e11"; rc=$?
[ "$rc" != "0" ] && ok "基线读不到 → 同步也拒绝（rc=$rc）" \
    || no "基线读不到时 run_sync 返回 0" "stderr=$(tr '\n' ' ' < "$T/e11")"
chk "名单没被同步这条路改动" "$before_b" "$(cksum "$TARGET_FILE")"
KL_EMPTY_OK=0
KL_PATCH="$T/backends/omk.awk"     # 后面两节各自再改回自己的形状

echo "── 3 形状本身：这几条判据不许靠运气成立 ──"
# 3.1 发布出去的模块里确实没有 awk（否则上面测的就不是生产形状）
chk "module/ 里不打包 awk（回退层永远走缺参照分支）" "0" "$(count_lines "$(find "$ROOT/module" -name '*.awk')")"
# 3.2 参照实现只在夹具里，且 19 份齐全（对拍与 A/B 靠它，不能顺手删）
n_ref=$(count_lines "$(ls "$ROOT/tests/fixtures/backends/"*.awk 2>/dev/null)")
[ "$n_ref" -ge 19 ] && ok "参照实现仍在 tests/fixtures/backends（$n_ref 份）" \
    || no "参照实现不见了（$n_ref 份）—— 对拍会一起失效"
# 3.3 管道形状会把退码吃掉：`current_target_apps … | …` 这种写法一条都不许留。
#     先折掉 `||` 再找单管道 —— 否则 `$(current_target_apps) || return 2`
#     这种**正确**写法会被自己的判据冤枉（第一版就误报了 12 处）。
hits_pipe=$(scan_sources pipe "$ROOT"/module/webui.sh "$ROOT"/module/lib/*.sh)
chk "没有一处用管道读名单（退码会被管道最后一条吃掉）" "0" "$(count_lines "$hits_pipe")"
[ -z "$hits_pipe" ] || printf '        %s\n' "$hits_pipe"
# 3.4 吞 stderr 的那几处必须自己带退码：既没有 `||`，也不在 if/while/until 的条件位上，
#     那"读不到"就又变成"空名单 + 成功"。
#     条件位这一支不能漏：第一版只认 `||`，把 webui.sh 里三处正确的
#     `if _te=$(current_target_apps 2>/dev/null); then` 冤枉成违规（同 3.3 一类冤案）。
hits_silent=$(scan_sources silent "$ROOT"/module/webui.sh "$ROOT"/module/lib/*.sh)
chk "没有一处吞掉名单读取的 stderr 却不带退码" "0" "$(count_lines "$hits_silent")"
[ -z "$hits_silent" ] || printf '        %s\n' "$hits_silent"
# 3.5 分派必须把命令的退码带出去（以前脚本走到结尾自然退 0）
grep -Eq 'exit +.{0,2}_rc' "$ROOT/module/webui.sh" \
    && ok '分派结果按退码带出（webui.sh 末尾带着 _rc 退出）' \
    || no 'webui.sh 不再带出退码 —— 所有失败都会被吞成 0'
# 3.6 上面两条扫描的开火对照：拿一段已知形状的样本喂同一个判据，必须各抓到设计好的条数。
#     样本 5 行：只有那行 `… 2>/dev/null | wc -l` 是管道（pipe 抓 1）；它和下一行的裸
#     `… 2>/dev/null` 都吞 stderr 又不带退码（silent 抓 2）；`if _t=$(…)` 那行不算；
#     最后一行 `$(…) || return 2` 是正确写法，两个判据都不许抓。
cat > "$T/scan-probe.sh" <<'PROBE'
#!/bin/sh
n=$(current_target_apps 2>/dev/null | wc -l)
m=$(current_target_apps 2>/dev/null)
if _t=$(current_target_apps 2>/dev/null); then :; fi
q=$(current_target_apps) || return 2
PROBE
p_pipe=$(scan_sources pipe "$T/scan-probe.sh")
p_silent=$(scan_sources silent "$T/scan-probe.sh")
chk "扫描器对已知的管道写法开火（样本 1 处）" "1" "$(count_lines "$p_pipe")"
chk "扫描器对已知的吞 stderr 写法开火（样本 2 处；if 那行与 || 那行都不许冤枉）" "2" "$(count_lines "$p_silent")"

echo "── 4 反向对照：参照齐全时同一批函数必须正常工作（上面的红不是函数坏了） ──"
KL_PATCH="$ROOT/tests/fixtures/backends/omk.awk"
# 重载请求文件先清掉：上面 2b 那节一旦有哪条写路径没拒绝干净，它会先被写出来，
# 这一节末尾那条"写完请求了 OMK 重载"就会拿别人的成果自证（空候选的闸）。
rm -f "$OMK_STATE_DIR/restart.injector"
run current_target_apps
mv -f "$T/_err" "$T/e7" 2>/dev/null
chk_rc "参照在 → 读得到" "0" "$_rc" "$T/e7"
chk "参照在 → 读出两条" "com.a com.b" "$(printf '%s\n' "$_o" | tr '\n' ' ' | sed 's/ $//')"
add_target_apps "$T/req" >"$T/o" 2>"$T/e6"; rc=$?
chk_rc "参照在 → 加得动" "0" "$rc" "$T/e6"
grep -q 'com.c' "$TARGET_FILE" && ok "参照在 → 真的写进去了" \
    || no "参照在却没写进去" "目标文件=$(tr '\n' ' ' < "$TARGET_FILE")"
# 写入这条链路末尾还要给 OMK 发重载请求；反向对照要证明整条路活着，不只是读得到。
[ -f "$OMK_STATE_DIR/restart.injector" ] && ok "参照在 → 写完请求了 OMK 重载" \
    || no "参照在却没写重载请求" "OMK_STATE_DIR=$OMK_STATE_DIR"

# 自覆盖：这一套到底断言了几条。trap 抓得到"死在半路"，抓不到"少写了几条断言"，
# 所以最后自己数一次（本轮实测 37 条，门槛留到 25）。
[ "$n_chk" -ge 25 ] && ok "本套件断言 $n_chk 条（≥25：少一节就是假绿）" \
    || no "本套件只断言了 $n_chk 条（<25）—— 有整节没跑到"
printf '  检查数=%s\n' "$n_chk"
reached_end=1
exit $fail
