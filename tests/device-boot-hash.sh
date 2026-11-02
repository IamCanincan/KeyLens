#!/bin/sh
# device-boot-hash：真机上证明"新用户一个字不填也能对齐"，并且 random 那家必须熄火。
#
# 为什么必须上机：自动档的取值来自**这台机自己的后端配置**。夹具能证明两侧算法一致，
# 证不了"OMK 现在正在证明的那个 hash，就是我们该写进 ro.boot.vbmeta.digest 的那串"。
#
# 全程只读：不搬主人的 boot_hash 文件、不写任何属性。派生路径用夹具根跑
# （把真实的 config.toml 复制进夹具），所以既拿到真实数据，又不动现场。
#
# 用法（手机上）：
#   adb shell "cd /data/adb/keylens-ab && MODDIR=/data/adb/modules/keylens sh device-boot-hash.sh"
set -u
export PATH="/system/bin:/system/xbin:/data/adb/magisk:/data/adb/ksu/bin:/data/adb/ap/bin:$PATH"
MODDIR=${MODDIR:-/data/adb/modules/keylens}
BIN=${KL_BIN:-$MODDIR/bin/keylens}
REAL_OMK_CFG=${REAL_OMK_CFG:-/data/misc/keystore/omk/config.toml}
REAL_HASH_FILE=${REAL_HASH_FILE:-/data/adb/keylens.boot_hash}
# 跑前记下"这一格现在是什么档"：默认档（auto）本来就没有文件，不能把它当成"文件丢了"
HAD_HASH_FILE=$([ -f "$REAL_HASH_FILE" ] && echo yes || echo no)

[ "$(id -u)" = "0" ] || { echo "  skip 需要 root（现在 uid=$(id -u)）"; echo '全部通过'; exit 0; }
[ -f "$MODDIR/lib/props.sh" ] || { echo "  skip 找不到 $MODDIR/lib/props.sh"; echo '全部通过'; exit 0; }
[ -x "$BIN" ] || { echo "  skip 没有可执行的 $BIN"; echo '全部通过'; exit 0; }

T=$(mktemp -d /data/local/tmp/kldbh.XXXXXX) || exit 1
trap 'rm -rf "$T"' EXIT
fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  ✗    %s\n' "$1"; fail=1; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 [$3]，实得 [$2]）"; fi; }
kv_of() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

# 夹具根：把真实的后端配置复制进来（只复制，不改动原件）
R="$T/root"
mkdir -p "$R/data/adb" "$R/data/adb/modules/oh_my_keymint" "$R/data/misc/keystore/omk"
if [ -f "$REAL_OMK_CFG" ]; then cp -a "$REAL_OMK_CFG" "$R/data/misc/keystore/omk/config.toml"; fi

# shell 侧台子：把绝对路径指到夹具根
cat > "$T/bh.sh" <<EOF
. $MODDIR/lib/core.sh
. $MODDIR/lib/backend.sh
. $MODDIR/lib/props.sh
kv() { printf '%s=%s\n' "\$1" "\$2"; }
prop_now() { PROP_NOW=\$(getprop "\$1" 2>/dev/null); [ -n "\$PROP_NOW" ] || PROP_NOW=""; }
ROOT="\$1"
KL_BOOT_HASH="\$ROOT/data/adb/keylens.boot_hash"
OMK_MODULE="\$ROOT/data/adb/modules/oh_my_keymint"
TEESIM_MODULE="\$ROOT/data/adb/modules/teesim"
TRICKY_MODULE="\$ROOT/data/adb/modules/tricky_store"
OMK_DIR="\$ROOT/data/misc/keystore/omk"
TEESIM_DIR="\$ROOT/data/adb/teesim"
EOF
sed -n '/^cmd_boot_hash() {/,/^}/p' "$MODDIR/webui.sh" >> "$T/bh.sh"
echo 'cmd_boot_hash' >> "$T/bh.sh"

sh_bh() { sh "$T/bh.sh" "$1" 2>&1; }
rs_bh() { KEYLENS_ROOT="$1" "$BIN" boot-hash 2>&1; }

printf '── 生产现场：主人这一格是什么档 ──\n'
PROD=$(MODDIR="$MODDIR" "$BIN" boot-hash 2>&1)
p_mode=$(kv_of "$PROD" mode); p_eff=$(kv_of "$PROD" effective); p_st=$(kv_of "$PROD" status)
printf '  ·   mode=%s status=%s effective=%s\n' "$p_mode" "$p_st" "${p_eff:0:16}…"
case "$p_mode" in manual|auto) : ;; *) bad "mode 不是 manual/auto（$p_mode）";; esac
chk "生产上 status=ok（digest 与生效值一致）" "$p_st" "ok"

printf '── 自动档在真机上算出的值（正对照：新用户免抄）──\n'
if [ -f "$R/data/misc/keystore/omk/config.toml" ]; then
    A=$(sh_bh "$R"); B=$(rs_bh "$R")
    chk "夹具（只有后端配置、没有 boot_hash 文件）两侧输出逐字节相同" "$A" "$B"
    chk "夹具里 mode=auto" "$(kv_of "$A" mode)" "auto"
    chk "夹具里 source=omk（值确实来自当前后端自己的配置）" "$(kv_of "$A" source)" "omk"
    # 参照值按现场档位选：手动档取主人手抄那串；默认的自动档没有文件，就取"已经在 prop 里
    # 生效的那串" —— 它同时必然等于 OMK 配置里的 hex，两者任一不同都说明这一档算错了。
    # 以前这里只有手动档一条路，现场切到 auto 之后它会把"没测"报成失败（2026-11-03 实测）。
    if [ -f "$REAL_HASH_FILE" ]; then
        ref=$(tr -d '[:space:]' < "$REAL_HASH_FILE" | tr 'A-F' 'a-f')
        what="主人手抄那串"
    else
        ref=$(getprop ro.boot.vbmeta.digest | tr -d '[:space:]' | tr 'A-F' 'a-f')
        what="现场已经生效的那串（默认档没有手填文件）"
    fi
    chk "auto 派生出的值 = $what（逐字节）" "$(kv_of "$A" effective)" "$ref"
    chk "auto 派生值合法（64 或 128 位十六进制）" \
        "$(. "$MODDIR/lib/props.sh"; KL_BOOT_HASH="$T/x"; v=$(kv_of "$A" effective); boot_hash_valid "$v" && echo yes || echo no)" "yes"
else
    bad "缺 $REAL_OMK_CFG，这条正对照跑不了（不是通过，是没测）"
fi

printf '── TEESim 那一支：属性已有值时必须采用守护进程那串（§5.15，真机现量）──\n'
# 夹具里放一份 teesim 模块目录 + 一个**诱饵** override（与 live 属性不同的一串）。
# 上游每次 push 都把这条 prop 强制成它正在证明的值（App.kt:510-523），而 override 只在
# 当前是合成兜底值时才被采纳（Harvester.kt:183-189）⇒ 属性有值时取属性、不取诱饵。
# 诱饵长度错了会直接落进"不合法"那一支，下面的断言当场就红 —— 它自带自证。
E64=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
R3="$T/teesim-adopt"; mkdir -p "$R3/data/adb" "$R3/data/adb/modules/teesim" "$R3/data/adb/teesim"
printf '{"verifiedBootHash":"%s"}\n' "$E64" > "$R3/data/adb/teesim/overrides.json"
A3=$(sh_bh "$R3"); B3=$(rs_bh "$R3")
chk "teesim 夹具两侧输出逐字节相同" "$A3" "$B3"
live=$(getprop ro.boot.vbmeta.digest | tr -d '[:space:]' | tr 'A-F' 'a-f')
if [ "$(KL_BOOT_HASH="$T/x" sh -c ". $MODDIR/lib/props.sh; boot_hash_valid '$live' && echo yes || echo no")" = "yes" ]; then
    chk "属性已有合法值 ⇒ source=daemon（不取诱饵）" "$(kv_of "$A3" source)" "daemon"
    chk "生效值 = 属性里那串，不是诱饵" "$(kv_of "$A3" effective)" "$live"
    chk "这一支 status=ok（属性与生效值本来就一致）" "$(kv_of "$A3" status)" "ok"
else
    chk "属性为空/不合法 ⇒ source=teesim，取诱饵那串（兜底支）" "$(kv_of "$A3" source)" "teesim"
    chk "生效值 = 诱饵（这一支确实会补）" "$(kv_of "$A3" effective)" "$E64"
fi
printf '  ·   本机 digest=%s（决定上面走的是哪一支）\n' "${live:0:16}…"

printf '── random 必须熄火（过期值比空着更糟）──\n'
R2="$T/random"; mkdir -p "$R2/data/adb" "$R2/data/adb/modules/oh_my_keymint" "$R2/data/misc/keystore/omk"
printf '[trust]\nvb_hash = "random"\n' > "$R2/data/misc/keystore/omk/config.toml"
A2=$(sh_bh "$R2"); B2=$(rs_bh "$R2")
chk "random：两侧输出逐字节相同" "$A2" "$B2"
chk "random：effective 为空（不写）" "$(kv_of "$A2" effective)" ""
chk "random：status=unset，不是 mismatch" "$(kv_of "$A2" status)" "unset"
chk "random：source=none" "$(kv_of "$A2" source)" "none"

printf '── off 是明确不写 ──\n'
R3="$T/off"; mkdir -p "$R3/data/adb" "$R3/data/adb/modules/oh_my_keymint" "$R3/data/misc/keystore/omk"
cp -a "$REAL_OMK_CFG" "$R3/data/misc/keystore/omk/config.toml" 2>/dev/null
printf 'off\n' > "$R3/data/adb/keylens.boot_hash"
A3=$(sh_bh "$R3"); B3=$(rs_bh "$R3")
chk "off：两侧输出逐字节相同" "$A3" "$B3"
chk "off：mode=off、status=off、effective 空" \
    "$(kv_of "$A3" mode)/$(kv_of "$A3" status)/$(kv_of "$A3" effective)" "off/off/"

printf '── 手动优先，且文件里是坏值时不写 ──\n'
R4="$T/manual"; mkdir -p "$R4/data/adb" "$R4/data/adb/modules/oh_my_keymint" "$R4/data/misc/keystore/omk"
cp -a "$REAL_OMK_CFG" "$R4/data/misc/keystore/omk/config.toml" 2>/dev/null
printf 'deadbeef\n' > "$R4/data/adb/keylens.boot_hash"
A4=$(sh_bh "$R4")
chk "坏值：mode=invalid、effective 空（不写半个值进去）" \
    "$(kv_of "$A4" mode)/$(kv_of "$A4" effective)" "invalid/"

printf '── 现场没被动过 ──\n'
chk "跑完现场的档位没变（boot_hash 文件在不在，跑前跑后一致）" "$([ -f "$REAL_HASH_FILE" ] && echo yes || echo no)" "$HAD_HASH_FILE"
chk "真实后端配置未被改写" "$(sha256sum < "$REAL_OMK_CFG" 2>/dev/null | cut -c1-16)" \
    "$(sha256sum < "$R/data/misc/keystore/omk/config.toml" 2>/dev/null | cut -c1-16)"
chk "digest 现值仍是生效值" "$(getprop ro.boot.vbmeta.digest)" "$p_eff"

if [ "$fail" = 0 ]; then echo '全部通过'; else echo '有断言失败'; fi
exit "$fail"
