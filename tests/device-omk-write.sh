#!/system/bin/sh
# device-omk-write：真机上验 `omk-save-config` 的**真写**那一路（夹具根，绝不碰正在用的配置）。
#
# 为什么非得上了机：这台的后端是 OhMyKeymint，写它走的是 `omk_set.awk` —— 19 份参照 awk 里
# 最复杂的一份（TOML 定点改写 + 未知键策略）。参照实现在 **设备的 toybox awk** 下与 Rust 版
# 是否仍然逐字节一致，`rust/parity.sh` 是量不到的（它跑在 WSL 的 GNU awk 上）。
# 今天生产的每一次"保存 OMK 配置"都走这条路，所以这一层值得有一台自己的台子。
#
# 夹具生成器、harness、payload 全部从 `rust/parity.sh` 原样抽取（不手抄第二份）；
# 本文件只负责：造两边夹具 → 各跑一遍 → 比输出/比文件/比备份 → 正对照与变异。
#
# 用法（手机上；模块里没有参照 awk 时用 AWKSRC 指一份）：
#   adb push rust/parity.sh /data/local/tmp/kl_parity.sh
#   adb push tests/device-omk-write.sh /data/local/tmp/kl_omkw.sh
#   for f in tests/fixtures/backends/*.awk; do adb push "$f" /data/local/tmp/kl-awk/; done
#   adb shell "MODDIR=/data/adb/modules/keylens PARITY=/data/local/tmp/kl_parity.sh \
#              AWKSRC=/data/local/tmp/kl-awk sh /data/local/tmp/kl_omkw.sh"
set -u
MOD=${MODDIR:-/data/adb/modules/keylens}
PARITY=${PARITY:-$MOD/parity.sh}
AWKSRC=${AWKSRC:-}
[ -f "$MOD/webui.sh" ] || { echo "  skip 找不到 $MOD/webui.sh"; echo "全部通过"; exit 0; }
[ -x "$MOD/bin/keylens" ] || { echo "  skip 没有 $MOD/bin/keylens"; echo "全部通过"; exit 0; }
[ "$(id -u)" = 0 ] || { echo "  skip 需要 root"; echo "全部通过"; exit 0; }
[ -f "$PARITY" ] || { echo "  ✗   没有 $PARITY（夹具要从它原样抽取，先 adb push rust/parity.sh）"; exit 1; }

D=$(mktemp -d) || exit 1
trap 'rm -rf "$D"' EXIT
fail=0
oks=0
chk() {
    if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"; oks=$((oks + 1))
    else printf '  ✗    %s\n        期望 [%s]\n        实得 [%s]\n' "$1" "$2" "$3"; fail=1; fi
}

# 仓库形状的落脚区（harness 里写死 `module/lib/core.sh` 与 $PWD/tests/fixtures/backends/*.awk）
mkdir -p "$D/tests/fixtures" "$D/w"
cp -a "$MOD" "$D/module" || { echo "  ✗   复制模块树失败"; exit 1; }
if ! ls "$D/module"/backends/*.awk >/dev/null 2>&1; then
    if [ -n "$AWKSRC" ] && ls "$AWKSRC"/*.awk >/dev/null 2>&1; then
        mkdir -p "$D/module/backends"; cp "$AWKSRC"/*.awk "$D/module/backends/"
        echo "  ·    模块里没带参照 awk，从 $AWKSRC 补了 $(ls "$AWKSRC"/*.awk | wc -l | tr -d ' ') 份"
    else
        echo "  ✗   模块里没有 backends/*.awk，也没给 AWKSRC=/path/to/tests/fixtures/backends"; exit 1
    fi
fi
ln -s "$D/module/backends" "$D/tests/fixtures/backends" || { echo "  ✗   参照链接失败"; exit 1; }
cd "$D" || exit 1
T="$D/w"
B="$D/module/bin/keylens"

grab() { sed -n "/^$1() {/,/^}\$/p" "$PARITY"; }
# payload 在 parity.sh 里是跨行的（行尾反斜杠续行）；grep 只抓第一行会得到没闭合的 $( ，
# eval 时就是 "unmatched ("（本轮真踩过）。
grab_assign() { awk -v v="$1" 'BEGIN{p=0} $0 ~ "^"v"=" {p=1} p {print; if ($0 !~ /[\\]$/) exit}' "$PARITY"; }
for fn in mk_oc_fixture mk_oc_harness pv_fp pv_harness; do
    b=$(grab "$fn")
    case "$b" in *"$fn() {"*) ;; *) echo "  ✗   从 parity.sh 抽不到 $fn"; exit 1 ;; esac
    eval "$b"; oks=$((oks + 1))
done
pv_env=$(sed -n '/^# 预览收尾/,/^fi$/p' module/webui.sh)
[ -n "$pv_env" ] || { echo "  ✗   抽不到 webui.sh 的预览信封"; exit 1; }
eval "$(grab_assign PLOC)"
eval "$(grab_assign PLOC2)"
[ -n "$PLOC" ] && [ -n "$PLOC2" ] || { echo "  ✗   payload 抽出来是空的"; exit 1; }
oks=$((oks + 1))
echo "── 夹具/生成器/payload 就位（全部取自 parity.sh 同一份真源）──"

CFG=data/misc/keystore/omk/config.toml
BAK=data/adb/omk/config.toml.bak
S="$T/oc-s"; R="$T/oc-r"
mkdir -p "$S" "$R"; mk_oc_fixture "$S"; mk_oc_fixture "$R"
mk_oc_harness "$S"
r0=$(sha256sum < "$R/$CFG")

echo "── 1 真写（toybox awk 参照 vs 二进制）──"
a=$(sh "$T/oc.sh" "$PLOC" 2>&1)
b2=$(KEYLENS_ROOT="$R" "$B" omk-save-config "$PLOC" 2>&1)
chk "两侧输出逐字节一致" "$a" "$b2"
chk "两侧写出的 config.toml 逐字节一致" "$(cat "$S/$CFG")" "$(cat "$R/$CFG")"
chk "补丁字段真写进去了（正对照：这条写不是空转）" "yes" \
    "$(grep -q 'security_patch = "2026-10-01"' "$R/$CFG" && echo yes)"
chk "Rust 侧生成了 .bak（落在 KL_DIR，不是目标文件旁边）" "yes" "$([ -f "$R/$BAK" ] && echo yes)"
chk "夹具确实被改过" "yes" "$([ "$(sha256sum < "$R/$CFG")" != "$r0" ] && echo yes)"
chk "没落到「当前后端不是 X」的错误路径" "0" "$(printf '%s\n' "$a" "$b2" | grep -c '当前后端不是')"

echo "── 2 内容相同的第二次保存（应当 saved=0 且不再落盘）──"
q0=$(sha256sum < "$R/$CFG")
b3=$(KEYLENS_ROOT="$R" "$B" omk-save-config "$PLOC" 2>&1)
chk "第二次 saved=0" "0" "$(printf '%s\n' "$b3" | sed -n 's/^saved=//p')"
chk "第二次没改文件" "$q0" "$(sha256sum < "$R/$CFG")"

echo "── 3 预览（两侧夹具一字不动 + changed>0）──"
PS="$T/p-s"; PR="$T/p-r"; mkdir -p "$PS" "$PR"; mk_oc_fixture "$PS"; mk_oc_fixture "$PR"
pv_harness mk_oc_harness oc "$PS"
f0=$(pv_fp "$PS"); g0=$(pv_fp "$PR")
pa=$(sh "$T/pv-oc.sh" "$PLOC" 2>&1 | sed -e "s|$PS||g")
pb=$(KEYLENS_ROOT="$PR" "$B" preview-omk-save-config "$PLOC" 2>&1)
chk "预览输出逐字节一致" "$pa" "$pb"
chk "shell 侧预览没落盘" "$(pv_fp "$PS")" "$f0"
chk "Rust 侧预览没落盘" "$(pv_fp "$PR")" "$g0"
chk "正对照 changed>0" "yes" \
    "$(printf '%s\n' "$pb" | sed -n 's/^changed=\([0-9]*\)$/\1/p' | awk '{print ($1 > 0) ? "yes" : "no"}')"

echo "── 4 restart / reboot 两种生效代价（只比输出，两边都不重启）──"
a4=$(sh "$T/oc.sh" "$PLOC2" 2>&1)
b4=$(KEYLENS_ROOT="$R" "$B" omk-save-config "$PLOC2" 2>&1)
chk "vb_key random→auto：两侧输出逐字节一致" "$a4" "$b4"
chk "Rust 判出 apply_scope=reboot" "reboot" "$(printf '%s\n' "$b4" | sed -n 's/^apply_scope=//p')"

echo "── 5 变异：把参照实现的字段校验改坏，两侧必须当场对不上 ──"
# 第一版改的是 omk_set.awk 里的一条映射，结果"没差别"——那条映射不是这个键实际走的路径，
# 变异等于没变异。改成动 shell 侧 write.sh 的字段校验：它会直接拒绝这个字段，差别必然可见。
WLIB="$D/module/lib/write.sh"
cp -a "$WLIB" "$T/write.sh.orig"
sed -i 's/trust_security_patch|trust_os_patchlevel|trust_vendor_patchlevel/trust_security_patchX|trust_os_patchlevel|trust_vendor_patchlevel/' "$WLIB"
if cmp -s "$WLIB" "$T/write.sh.orig"; then
    echo "  ✗    变异没落地（write.sh 里找不到那条校验分支）"; fail=1
else
    MS="$T/m-s"; MR="$T/m-r"; mkdir -p "$MS" "$MR"; mk_oc_fixture "$MS"; mk_oc_fixture "$MR"
    mk_oc_harness "$MS"
    am=$(sh "$T/oc.sh" "$PLOC" 2>&1)
    bm=$(KEYLENS_ROOT="$MR" "$B" omk-save-config "$PLOC" 2>&1)
    chk "变异后两侧输出不再一致（这条闸看得见差异）" "differs" \
        "$([ "$am" != "$bm" ] && echo differs || echo same)"
    cp -a "$T/write.sh.orig" "$WLIB"
fi

echo "── 统计"
if [ "$oks" -lt 20 ]; then
    echo "  ✗   断言数量低于下限（$oks < 20），疑似用例被删"; fail=1
fi
if [ "$fail" = 0 ]; then echo "全部通过（$oks 项）"; else echo "有断言失败"; exit 1; fi
