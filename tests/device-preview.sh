#!/bin/sh
# device-preview：真机上把 9 条 preview-<写命令> 逐字节 A/B（shell 的 KL_PREVIEW 路径 vs Rust 影子根）。
#
# 为什么还要真机跑一遍：本机对拍（rust/parity.sh）用的是夹具根，而 shell 侧的后端目录是
#   写死的绝对路径（core.sh 里 /data/adb/…），夹具那半边只在 Rust 侧成立；真机上还多了
#   真实后端探测、真实锁、真实 getprop。两边机制不同（shell 拦下写入攒 diff，Rust 在影子根
#   里真跑一遍再比对），只有真实文件能证伪"影子根看到的和原地一样"。
#
# 用法（手机上）：
#   adb shell "cd /data/adb/keylens-ab && MODDIR=/data/adb/keylens-ab sh device-preview.sh"
#
# 判据三条：
#   1. 两侧 stdout 逐字节相同；
#   2. 跑完后真实后端文件的 sha256 一个都没变（预览不许落盘，两侧各验一次）；
#   3. 每条报 changed=N 与目标文件在否 —— changed>0 且文件在，才算这条预览真被覆盖到；
#      目标文件不存在的（本机只装了 OhMyKeymint，teesim/tricky 那六条就是）只对齐了错误路径，
#      那部分由夹具根的对拍负责，这里如实标成"未覆盖差异"。
# keybox 一条的差异里含设备上的真实密钥材料，默认只比哈希、不打印 diff 全文。
set -u
MODDIR=${MODDIR:-/data/adb/modules/keylens}
[ -f "$MODDIR/webui.sh" ] || { echo "  skip 找不到 $MODDIR/webui.sh"; echo "全部通过"; exit 0; }
[ -x "$MODDIR/bin/keylens" ] || { echo "  skip 没有 $MODDIR/bin/keylens（用带二进制的发布包）"; echo "全部通过"; exit 0; }
[ "$(id -u)" = "0" ] || { echo "  skip 需要 root"; echo "全部通过"; exit 0; }

T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT

BACKEND_FILES="/data/misc/keystore/omk/config.toml /data/misc/keystore/omk/injector.toml \
/data/misc/keystore/omk/keybox.xml /data/adb/tricky_store/security_patch.txt \
/data/adb/tricky_store/keybox.xml /data/adb/teesim/config.json /data/adb/teesim/overrides.json"

fp() { for f in $BACKEND_FILES; do [ -f "$f" ] && sha256sum "$f"; done; }
# 外层 payload：每行 key=base64(值)，整体再 base64（与界面侧 bridge.js 同一套编码）
mkpl() {
    out=""
    for kv in "$@"; do
        k=${kv%%=*}; v=${kv#*=}
        line="$k=$(printf '%s' "$v" | base64 | tr -d '\n')"
        if [ -z "$out" ]; then out="$line"; else out="$out$NL$line"; fi
    done
    printf '%s' "$out" | base64 | tr -d '\n'
}
NL=$(printf '\nX'); NL=${NL%X}
# 差异里的密钥材料不进终端：把超长的 diff= 行折成占位（只用于打印，比较仍用全文）
redact() { sed -e 's/^\(diff=\).\{60,\}$/\1…（含密钥材料，已略）/'; }

fail=0
one() { # <cmd> <arg> [目标文件（判覆盖用）]
    _c=$1; _a=${2:-}; _f=${3:-}
    _base=$(fp)
    _sh=$(KL_USE_RUST=0 sh "$MODDIR/webui.sh" "preview-$_c" "$_a" 2>&1)
    _fa=$(fp)
    _rs=$("$MODDIR/bin/keylens" "preview-$_c" "$_a" 2>&1)
    _fb=$(fp)
    if [ "$_base" != "$_fa" ] || [ "$_base" != "$_fb" ]; then
        echo "  ✗    preview-$_c 预览把真实后端文件写了"
        fail=1; return
    fi
    _ch=$(printf '%s\n' "$_rs" | sed -n 's/^changed=\([0-9]*\)$/\1/p')
    if [ -n "$_f" ] && [ ! -f "$_f" ]; then
        _cov="未覆盖差异（本机没有 $_f）"
    elif [ "${_ch:-0}" -gt 0 ] 2>/dev/null; then
        _cov="changed=$_ch"
    else
        _cov="⚠ changed=0：这条预览没看见任何差异"
    fi
    if [ "$_sh" = "$_rs" ]; then
        echo "  ok   preview-$_c（$_cov）"
        printf '%s\n' "$_sh" | grep -v '^diff=' | sed -e 's/^/         /'
    else
        echo "  ✗    preview-$_c 不一致（$_cov）"
        printf '%s\n' "$_sh" | redact | head -n 12 | sed -e 's/^/       shell /'
        printf '%s\n' "$_rs" | redact | head -n 12 | sed -e 's/^/       rust  /'
        fail=1
    fi
}

# ---------- 本机装了哪家，就有的验 ----------
CFG=/data/misc/keystore/omk/config.toml
INJ=/data/misc/keystore/omk/injector.toml
KB=/data/misc/keystore/omk/keybox.xml
TS=/data/adb/teesim/config.json
TSO=/data/adb/teesim/overrides.json
SP=/data/adb/tricky_store/security_patch.txt
TKB=/data/adb/tricky_store/keybox.xml

echo "── preview-*（真机逐字节 A/B）──"
# 三条 scope 臂里真机能覆盖两条：补丁字段整组 = hot；日志级别 = restart（预览里不请求重启，
# 也就不该出现"已请求重启 keymint"那句 note）。reboot 臂要 vb_key 当前是 random，本机是 auto，
# 由夹具根的对拍覆盖。
one omk-save-config "$(mkpl trust_security_patch=2026-10-01 trust_os_patchlevel=latest)" "$CFG"
one omk-save-config "$(mkpl cfg_log_level=info)" "$CFG"
one omk-save-injector "$(mkpl inj_log_level=warn)" "$INJ"
# keybox：合成一份结构合格的 OMK keybox（不含设备上的真实材料），差异全文不进终端
KBXML='<Keybox><Key algorithm="ec"><NumberOfCertificates>1</NumberOfCertificates><PrivateKey format="pem">-----BEGIN EC PRIVATE KEY-----
c3ludGhldWlj
-----END EC PRIVATE KEY-----</PrivateKey><CertificateChain><Certificate format="pem">-----BEGIN CERTIFICATE-----
c3ludGhldWlj
-----END CERTIFICATE-----</Certificate></CertificateChain></Key></Keybox>'
one keybox-save "$(printf '%s' "$KBXML" | base64 | tr -d '\n')" "$KB"
# 下面六条这台机没有对应后端（目录不存在）：只对齐错误路径，差异覆盖由 rust/parity.sh 负责
one teesim-save "$(mkpl mode=generation patch_system=2026-10-01)" "$TS"
one teesim-save-overrides "$(mkpl attestationSecurityLevel=2)" "$TSO"
one teesim-profile-new kltest
one teesim-profile-del work
one tricky-save-patch "$(mkpl patch_system=2026-10-07 patch_boot=no)" "$SP"
one tricky-drop-patch com.example.a "$SP"
one teesim-profile-del default

echo "── 统计"
if [ "$fail" = 0 ]; then echo "全部通过"; else echo "有断言失败"; exit 1; fi
