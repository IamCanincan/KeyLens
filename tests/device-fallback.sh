#!/system/bin/sh
# device-fallback：把 tests/fallback-shape.sh 原样搬到**设备上**再跑一遍（生产形状）。
#
# 为什么要单独一个 runner 而不是"主机跑过就算了"：同一批 shell 函数今天只在三种 awk 下被量过
# —— Git Bash 的 gawk、WSL 的 mawk（`rust/parity.sh` 那边），而**设备上是 toybox awk**，
# 且发布包里的模块压根不带 awk（参照实现留在仓库夹具，docs/AWK-REMOVAL.md 的阶段 5）。
# 这次真机事故的原始读数就是设备上量到的：`KL_USE_RUST=0 … targets` → 0 行 + 退码 0，
# 而 Rust 层同一命令 131 行。主机那套再绿也证不了"这台机上回退层会说什么"。
#
# 判定全部在 tests/fallback-shape.sh 里（44 条），本文件只做三件事：
#   ① 造一份"仓库形状"的临时根（模块树 + 夹具 awk），因为套件按 `$0/..` 找 module/ 与 tests/；
#   ② 自证这确实是生产形状：模块里没有 *.awk（有就说明这台被推过参照，红，不是悄悄跳过）；
#   ③ 把套件的输出原样带出来，退码一致。
#
# 用法（手机上；夹具要先推一份，因为它不随模块发布）：
#   adb push tests/fallback-shape.sh /data/local/tmp/kl_fb_suite.sh
#   adb push tests/device-fallback.sh /data/local/tmp/kl_fb.sh
#   for f in tests/fixtures/backends/*.awk; do adb push "$f" /data/local/tmp/kl-awk/; done
#   adb shell "AWKSRC=/data/local/tmp/kl-awk sh /data/local/tmp/kl_fb.sh"
set -u
MOD=${MODDIR:-/data/adb/modules/keylens}
SUITE=${SUITE:-/data/local/tmp/kl_fb_suite.sh}
AWKSRC=${AWKSRC:-}

# skip 的口径与同族 device-*.sh 一致：**不在设备上**才跳过（CI/主机跑这套件时不能制造假红），
# 在设备上但形状不对一律红。
[ -f "$MOD/webui.sh" ] || { echo "  skip 找不到 $MOD/webui.sh（不在设备上，或模块没装）"; echo "全部通过"; exit 0; }
[ -x "$MOD/bin/keylens" ] || { echo "  skip 模块里没有 bin/keylens（这是回退层的台子，但默认层要用作对照）"; echo "全部通过"; exit 0; }
[ "$(id -u)" = "0" ] || { echo "  skip 需要 root（读 /data/adb/modules 与 /data/misc/keystore）"; echo "全部通过"; exit 0; }
[ -f "$SUITE" ] || { echo "  ✗   在设备上但没找到 $SUITE：先 adb push tests/fallback-shape.sh /data/local/tmp/kl_fb_suite.sh"; exit 1; }
[ -n "$AWKSRC" ] && ls "$AWKSRC"/*.awk >/dev/null 2>&1 || {
    echo "  ✗   在设备上但没给 AWKSRC=<装了参照 awk 的目录>：套件的反向对照（§4）要拷一份 omk.awk"
    echo "      adb push tests/fixtures/backends/… 见文件头"
    exit 1
}

D=$(mktemp -d) || exit 1
trap 'rm -rf "$D"' EXIT

# 仓库形状：module/ + tests/fixtures/backends/ + tests/fallback-shape.sh
mkdir -p "$D/module" "$D/tests/fixtures/backends"
cp -a "$MOD"/. "$D/module/" || { echo "  ✗   复制模块树失败"; exit 1; }
cp "$AWKSRC"/*.awk "$D/tests/fixtures/backends/" || { echo "  ✗   拷参照 awk 失败"; exit 1; }
cp "$SUITE" "$D/tests/fallback-shape.sh" || { echo "  ✗   拷套件失败"; exit 1; }

n_awk=$(ls "$D/module"/backends/*.awk 2>/dev/null | wc -l | tr -d ' ')
if [ "$n_awk" != "0" ]; then
    echo "  ✗   这台上的模块带 $n_awk 份参照 awk —— 不是生产形状（发布包不发货）"
    echo "      要么重装发布包，要么把这 $n_awk 份从副本里清掉再跑（别在真模块上动手）"
    exit 1
fi
printf '  ok   形状确认：模块里 0 份 awk（回退层永远走"缺参照"分支）\n'
printf '  ·    设备侧 awk：%s\n' "$(command -v awk || echo 没有)"
printf '  ·    设备侧 shell：%s\n' "$(readlink /proc/$$/exe 2>/dev/null || echo 未知)"

# 真机现量的那三条判据（不靠 awk）：回退层必须报错，默认层必须照旧读出真数。
# **必须跑在 $MOD 上，不是上面那份副本**：`use_backend` 有第二条解析分支
# 「仓库布局：$mdir/../tests/fixtures/backends」，而这份副本正是为了跑套件而造的仓库形状
# （$D/tests/fixtures/backends 里就放着 19 份参照）—— 在它上面量"生产形状"会得到假的 rc=0 + 131 行。
# 这个坑就是本文件第一版在真机上量到的：判据红，但红的是台子，不是产品。
out=$(KL_USE_RUST=0 sh "$MOD/webui.sh" targets 2>&1); rc=$?
rows=$(printf '%s\n' "$out" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
if [ "$rc" = "0" ] && [ "$rows" = "0" ]; then
    echo "  ✗   回退层又交回「0 行 + 退码 0」—— 这次的事故原样复现了"
    exit 1
fi
[ "$rc" != "0" ] && printf '  ok   KL_USE_RUST=0 targets 退码非 0（rc=%s）\n' "$rc" \
    || { echo "  ✗   KL_USE_RUST=0 targets 退了 0，读数：$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-100)"; exit 1; }
printf '%s\n' "$out" | grep -q "bin/keylens" && printf '  ok   stderr 说了下一步（正式实现是 bin/keylens）\n' \
    || { echo "  ✗   stderr 没给下一步，读数：$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-120)"; exit 1; }

rust_out=$(KL_USE_RUST=1 sh "$MOD/webui.sh" targets 2>/dev/null)
rust_rows=$(printf '%s\n' "$rust_out" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
[ "$rust_rows" -gt 0 ] && printf '  ok   默认（Rust）层仍读出真名单：%s 行\n' "$rust_rows" \
    || { echo "  ✗   默认层读出 0 行 —— 这台机没装后端文件？那 A/B 没有对照，先别跑写路径"; exit 1; }

# 体检那一格：名单读不到时必须说"名单读不到"，不许甩锅给已装列表。
# （这条只能在真机上量 —— 判据要用真的 `cmd package`，台架里那颗是桩。）
doc0=$(KL_USE_RUST=0 sh "$MOD/webui.sh" doctor 2>/dev/null)
printf '%s\n' "$doc0" | grep -q "名单读不到" && printf '  ok   回退层体检：名单那一格说"名单读不到"\n' \
    || { echo "  ✗   回退层体检没说名单读不到，读数：$(printf '%s' "$doc0" | grep -a 名单 | tr '\n' ' ' | cut -c1-120)"; exit 1; }
printf '%s\n' "$doc0" | grep -q "读不到已装应用列表" \
    && { echo "  ✗   体检把「名单读不到」甩锅成了「读不到已装应用列表」（已装其实读得到 $rust_rows 条）"; exit 1; } \
    || printf '  ok   没有把"名单读不到"甩锅给已装列表\n'

echo "── 下面把套件原样跑一遍（toybox awk + 设备 shell）──"
( cd "$D" && sh tests/fallback-shape.sh )
rc=$?
printf 'fallback-shape on device: exit=%s\n' "$rc"
exit "$rc"
