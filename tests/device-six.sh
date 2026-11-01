#!/system/bin/sh
# device-six：真机上给 teesim / tricky 那六条写命令（连同各自的 preview 双胞胎）做 A/B。
#
# 为什么非得上了机：这台只装 OhMyKeymint，走真实入口时这六条两边都只到「当前后端不是 X」
# 的错误路径（实测 rc=1 + 那句中文），差异一行没量到。夹具侧的覆盖一直只有 `rust/parity.sh`，
# 而它跑在 WSL 的 GNU awk + dash 上 —— 参照实现（19 份 awk）在**设备的 toybox awk + mksh**
# 下行为是否一致，从来没人量过。这一层补的就是那个。
#
# 夹具与 harness **从 rust/parity.sh 里原样抽出来 eval**（不手抄第二份）：
# 手抄的那份改了不会响，正是这类台子最容易烂掉的方式。每条抽出来的生成器都要先造出一只
# 该存在的文件，造不出来当场报错。
#
# 用法（手机上）：
#   adb push rust/parity.sh /data/adb/keylens-ab/parity.sh
#   adb push tests/device-six.sh /data/adb/keylens-ab/device-six.sh
#   adb shell "MODDIR=/data/adb/keylens-ab sh /data/adb/keylens-ab/device-six.sh"
set -u
MOD=${MODDIR:-/data/adb/modules/keylens}
PARITY=${PARITY:-$MOD/parity.sh}
[ -f "$MOD/webui.sh" ] || { echo "  skip 找不到 $MOD/webui.sh"; echo "全部通过"; exit 0; }
[ -x "$MOD/bin/keylens" ] || { echo "  skip 没有 $MOD/bin/keylens"; echo "全部通过"; exit 0; }
[ "$(id -u)" = 0 ] || { echo "  skip 需要 root"; echo "全部通过"; exit 0; }
if ! ls "$MOD"/backends/*.awk >/dev/null 2>&1; then
    echo "  ✗   设备上找不到参照 awk：$MOD/backends/*.awk（sh tools/deploy-webui.sh --shell 会连参照一起推进去）"
    exit 1
fi
[ -f "$PARITY" ] || { echo "  ✗   没有 $PARITY —— 夹具与 harness 要从它原样抽取，先 adb push rust/parity.sh 上来"; exit 1; }

D=$(mktemp -d) || exit 1
trap 'rm -rf "$D"' EXIT
fail=0
oks=0
chk() {
    if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"; oks=$((oks + 1))
    else printf '  ✗    %s\n        期望 [%s]\n        实得 [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
names_of() { # <root> → 相对文件名清单（滤掉 harness 桩与日志造成的形状差，见 six_case 里那段注释）
    ( cd "$1" && find . -type f | LC_ALL=C sort ) 2>/dev/null \
      | sed -e '/\.keylens\.[0-9]*$/d' \
            -e '/\/keylens\.log$/d' -e '/\.bak$/d' -e '/\.pre$/d' -e '/\/\.kl_/d'
}

# ── 仓库形状的落脚区 ────────────────────────────────────────────────────
# harness 生成的脚本里写死了 `module/lib/core.sh` 与 `$PWD/tests/fixtures/backends/*.awk`，
# 所以先把安装树复制成仓库布局（复制而不是软链：写命令会碰 module.prop，别糟蹋真树）。
mkdir -p "$D/tests/fixtures" "$D/w"
cp -a "$MOD" "$D/module" || { echo "  ✗   复制模块树失败"; exit 1; }
ln -s "$D/module/backends" "$D/tests/fixtures/backends" || { echo "  ✗   参照 awk 链接失败"; exit 1; }
cd "$D" || exit 1
T="$D/w"
B="$D/module/bin/keylens"

# ── 从 parity.sh 抽生成器 ───────────────────────────────────────────────
grab() { sed -n "/^$1() {/,/^}\$/p" "$PARITY"; }
need_fn() { # <函数名>
    b=$(grab "$1")
    case "$b" in
        *"${1}() {"*) ;;
        *) printf '  ✗    从 parity.sh 抽不到 %s（锚点改了？）\n' "$1"; fail=1; return ;;
    esac
    eval "$b"
    command -v "$1" >/dev/null 2>&1 && oks=$((oks + 1)) || { printf '  ✗    %s eval 后没定义\n' "$1"; fail=1; }
}
for fn in mk_sp_fixture mk_save_harness mk_dp_fixture mk_drop_harness \
          mk_ts_fixture mk_ts_harness mk_ov_fixture mk_ov_harness \
          mk_pn_fixture mk_pn_harness mk_pd_fixture mk_pd_harness pv_fp pv_harness; do
    need_fn "$fn"
done
[ "$fail" = 0 ] || { echo "生成器没抽全，下面不跑了"; exit 1; }
# 预览信封与三条 payload 也照 parity.sh 原样取
pv_env=$(sed -n '/^# 预览收尾/,/^fi$/p' module/webui.sh)
[ -n "$pv_env" ] || { echo "  ✗   抽不到 webui.sh 的预览信封"; exit 1; }
eval "$(grep '^PL=' "$PARITY" | head -1)"
eval "$(grep '^PLTS=' "$PARITY" | head -1)"
eval "$(grep '^PLOV=' "$PARITY" | head -1)"
[ -n "$PL" ] && [ -n "$PLTS" ] && [ -n "$PLOV" ] || { echo "  ✗   payload 抽出来是空的"; exit 1; }
echo "── 生成器与 payload 就位（14 个函数 + 3 条 payload，全部取自 parity.sh 同一份真源）──"

six_case() { # <命令> <夹具生成器> <harness 生成器> <文件标签> <参数> <目标文件（相对夹具根）>
    _c=$1; _fx=$2; _hn=$3; _tag=$4; _arg=$5; _tgt=$6
    _s="$T/s-$_tag"; _r="$T/r-$_tag"
    rm -rf "$_s" "$_r"
    $_fx "$_s"; $_fx "$_r"
    # 抽取是否完整的自证：夹具生成器必须真的造出这一只文件
    chk "$_c：夹具文件已造出" "yes" "$([ -f "$_s/$_tgt" ] && echo yes)"
    $_hn "$_s"
    _t0=$(sha256sum < "$_s/$_tgt" | cut -d' ' -f1)
    _u0=$(sha256sum < "$_r/$_tgt" | cut -d' ' -f1)
    _so=$(sh "$T/$_tag.sh" "$_arg" 2>&1)
    _ro=$(KEYLENS_ROOT="$_r" "$B" "$_c" "$_arg" 2>&1)
    chk "$_c：两侧输出逐字节一致" "$_so" "$_ro"
    # 比的是**目标文件的字节**，不比整棵树：harness 在 shell 那一侧把 commit_backend_file 桩成了
    # `cp`（parity 原样），于是 shell 侧没有 .bak、留着一个 .keylens.<pid> 临时文件、
    # drop 那条还多造一个 .pre；Rust 侧则会写 data/adb/keylens.log。这些都是桩的形状不是实现的差异。
    chk "$_c：两侧写出的目标文件逐字节一致" "$(cat "$_s/$_tgt")" "$(cat "$_r/$_tgt")"
    # 正对照：目标文件必须真被动过 —— 两边都"什么都没写"也是上面两条相等的样子
    chk "$_c：shell 侧目标文件被写了" "yes" \
        "$([ "$(sha256sum < "$_s/$_tgt" | cut -d' ' -f1)" != "$_t0" ] && echo yes)"
    chk "$_c：Rust 侧目标文件被写了" "yes" \
        "$([ "$(sha256sum < "$_r/$_tgt" | cut -d' ' -f1)" != "$_u0" ] && echo yes)"
    # 覆盖自证：走错到「当前后端不是 X」的分支，上面全绿也是空的
    chk "$_c：没落到「当前后端不是 X」的错误路径" "0" "$(printf '%s\n' "$_so" "$_ro" | grep -c '当前后端不是')"
    # 没往夹具里乱写：两侧文件名清单（按上面那三条桩的差异过滤掉）要一致
    _ns=$(names_of "$_s"); _nr=$(names_of "$_r")
    chk "$_c：两侧新增/遗留的文件名清单一致（滤掉 .bak/.pre/.keylens.<pid>/keylens.log/.kl_*）" "$_ns" "$_nr"

    # 预览双胞胎：同一份夹具，两侧都必须一字不变，而且 changed 要真大于 0
    _ps="$T/p-$_tag-s"; _pr="$T/p-$_tag-r"
    rm -rf "$_ps" "$_pr"; $_fx "$_ps"; $_fx "$_pr"
    pv_harness "$_hn" "$_tag" "$_ps"
    _f0=$(pv_fp "$_ps"); _g0=$(pv_fp "$_pr")
    _pa=$(sh "$T/pv-$_tag.sh" "$_arg" 2>&1 | sed -e "s|$_ps||g")
    _pb=$(KEYLENS_ROOT="$_pr" "$B" "preview-$_c" "$_arg" 2>&1)
    chk "preview-$_c：夹具没被 shell 侧落盘" "$(pv_fp "$_ps")" "$_f0"
    chk "preview-$_c：夹具没被 Rust 侧落盘" "$(pv_fp "$_pr")" "$_g0"
    chk "preview-$_c：输出逐字节一致" "$_pa" "$_pb"
    chk "preview-$_c：正对照 changed>0" \
        "$(printf '%s\n' "$_pb" | sed -n 's/^changed=\([0-9]*\)$/\1/p' | awk '{print ($1 > 0) ? "yes" : "no"}')" "yes"
}

echo "── Tricky Store 两条（写 + 预览）──"
six_case tricky-save-patch  mk_sp_fixture mk_save_harness sv  "$PL"              data/adb/tricky_store/security_patch.txt
six_case tricky-drop-patch  mk_dp_fixture mk_drop_harness dp  com.example.a      data/adb/tricky_store/security_patch.txt
echo "── TEE Simulator 四条（写 + 预览）──"
six_case teesim-save           mk_ts_fixture mk_ts_harness ts   "$PLTS"          data/adb/teesim/config.json
six_case teesim-save-overrides mk_ov_fixture mk_ov_harness ovs  "$PLOV"          data/adb/teesim/overrides.json
six_case teesim-profile-new    mk_pn_fixture mk_pn_harness pn   work             data/adb/teesim/config.json
six_case teesim-profile-del    mk_pd_fixture mk_pd_harness pd   work             data/adb/teesim/config.json

# 上面 names_of 那条滤掉了 `.bak`（shell 侧被桩成 cp，不会生成备份 —— 是桩的形状不是实现的差异）。
# 滤掉的东西得有一格点名验回来，否则这条白名单就把"备份没生成"这类真故障也一起滤掉了。
chk "白名单自查：Rust 侧确实生成了 security_patch.txt.bak" "yes" \
    "$([ -f "$T/r-sv/data/adb/tricky_store/security_patch.txt.bak" ] && echo yes)"
_nb=0
for bk in "$T/r-ts/data/adb/teesim/config.json.bak" "$T/r-ovs/data/adb/teesim/overrides.json.bak"; do
    [ -f "$bk" ] && _nb=$((_nb + 1))
done
chk "白名单自查：teesim 两条也生成了各自的 .bak" "2" "$_nb"

echo "── 对照：拿一台只装 OhMyKeymint 的真实入口跑同一条，应当只得到那句错误"
# 这一条是给"上面 42 条不是空转"兜底的：不加夹具直接跑，两侧都只会走到错误路径，
# 输出虽然也相同，但差异量为零 —— 记录这个事实，免得以后有人以为不建夹具也能测。
_e=$(sh "$D/module/webui.sh" teesim-save-overrides "$PLOV" 2>&1)
chk "不经夹具时确实只得到「当前后端不是 TEE Simulator」" "1" "$(printf '%s\n' "$_e" | grep -c '当前后端不是 TEE Simulator')"

echo "── 统计"
if [ "$oks" -lt 83 ]; then
    echo "  ✗   断言数量低于下限（$oks < 83），疑似用例被删"; fail=1
fi
if [ "$fail" = 0 ]; then echo "全部通过（$oks 项）"; else echo "有断言失败"; exit 1; fi
