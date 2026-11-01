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
# 判据四条：
#   1. 三条腿的 stdout 逐字节相同：shell 原地预览（KL_USE_RUST=0 走 webui.sh）、
#      直接调二进制、经 webui.sh 且开关默认开（= 真实界面走的那条路，接管段必须带着
#      preview- 前缀把它交给二进制）；
#   2. 经界面那份的信封恰好一份 preview=1（两份就是 shell 又补了一遍）；
#   3. 跑完后真实后端文件的 sha256 一个都没变（三条腿都不许落盘）；
#   4. 每条报 changed=N 与目标文件在否 —— changed>0 且文件在，才算这条预览真被覆盖到；
#      目标文件不存在的（本机只装了 OhMyKeymint，teesim/tricky 那六条就是）只对齐了错误路径，
#      那部分由夹具根的对拍负责，这里如实标成"未覆盖差异"。
# keybox 一条的差异里含设备上的真实密钥材料，默认只比哈希、不打印 diff 全文。
set -u
MODDIR=${MODDIR:-/data/adb/modules/keylens}
[ -f "$MODDIR/webui.sh" ] || { echo "  skip 找不到 $MODDIR/webui.sh"; echo "全部通过"; exit 0; }
[ -x "$MODDIR/bin/keylens" ] || { echo "  skip 没有 $MODDIR/bin/keylens（用带二进制的发布包）"; echo "全部通过"; exit 0; }
[ "$(id -u)" = "0" ] || { echo "  skip 需要 root"; echo "全部通过"; exit 0; }
# 同 device-ab：参照 awk 不随模块发布，缺了它 shell 那半边会退化成「缺少 X.awk」，
# 报出来的差异与实现无关。
if ! ls "$MODDIR"/backends/*.awk >/dev/null 2>&1; then
    echo "  ✗   设备上找不到参照 awk：$MODDIR/backends/*.awk（先 sh tools/deploy-webui.sh --shell 推上去）"
    exit 1
fi

T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT

# 台子自己的计数器：断言条数低于下限就红（上一版这里调了根本没定义的 chk，
# mksh 报 "command not found" 但不置 fail，末尾照样打「全部通过」——假绿就是这么来的）。
oks=0
fail=0
chk() {
    if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"; oks=$((oks + 1));
    else printf '  ✗    %s\n        期望 [%s]，实得 [%s]\n' "$1" "$2" "$3"; fail=1; fi
}

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
    # 第三条腿：经界面入口、开关默认开 → 必须由接管段带着 preview- 前缀交给二进制。
    # 少了这条，"剥前缀再接管"（预览变真写）这种回归在本台上是查不出来的。
    _ui=$(KL_USE_RUST=1 sh "$MODDIR/webui.sh" "preview-$_c" "$_a" 2>&1)
    _fc=$(fp)
    if [ "$_base" != "$_fa" ] || [ "$_base" != "$_fb" ] || [ "$_base" != "$_fc" ]; then
        echo "  ✗    preview-$_c 预览把真实后端文件写了（接管=$(printf '%s' "$_fc" | grep -c '^preview=1') 封）"
        fail=1; return
    fi
    _env_n=$(printf '%s\n' "$_ui" | grep -c '^preview=1')
    if [ "$_env_n" != "1" ]; then
        echo "  ✗    preview-$_c 经界面入口的信封不是恰好一份（实得 $_env_n 份）"
        printf '%s\n' "$_ui" | redact | head -n 10 | sed -e 's/^/       /'
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
    if [ "$_sh" = "$_rs" ] && [ "$_sh" = "$_ui" ]; then
        echo "  ok   preview-$_c（$_cov）"
        oks=$((oks + 1))
        printf '%s\n' "$_sh" | grep -v '^diff=' | sed -e 's/^/         /'
    else
        echo "  ✗    preview-$_c 不一致（$_cov）"
        printf '%s\n' "$_sh" | redact | head -n 12 | sed -e 's/^/       shell /'
        printf '%s\n' "$_rs" | redact | head -n 12 | sed -e 's/^/       rust  /'
        printf '%s\n' "$_ui" | redact | head -n 12 | sed -e 's/^/       ui    /'
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
PL_CFG=$(mkpl trust_security_patch=2026-10-01 trust_os_patchlevel=latest)
one omk-save-config "$PL_CFG" "$CFG"
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
one teesim-profile-new kltest "$TS"
one teesim-profile-del work "$TS"
one tricky-save-patch "$(mkpl patch_system=2026-10-07 patch_boot=no)" "$SP"
one tricky-drop-patch com.example.a "$SP"
one teesim-profile-del default "$TS"

printf '── TMPDIR 坏掉时预览仍要成立（影子根换落脚点）──\n'
# Android 上没有 /tmp，界面给的 TMPDIR 也不一定是真目录。以前的写法只认 temp_dir()：
# 建不出来 → 子进程什么都读不到 → 父进程报 changed=0 → 界面把"没有差异"当成无需确认，直接真写。
# 现在按 TMPDIR → /data/local/tmp → temp_dir 依次找落脚点；全建不出来就退 2，
# 让 webui.sh 的接管段回落到 shell 原地预览（那条在 rust/parity.sh 里钉）。
_be=$(fp)
: > "$T/not-a-dir"          # TMPDIR 的父路径是普通文件 → create_dir 必然失败（指到不存在的目录会被顺手建出来）
o=$(TMPDIR="$T/not-a-dir/sub" "$MODDIR/bin/keylens" preview-omk-save-config "$PL_CFG" 2>&1)
rc=$?
_s=$("$MODDIR/bin/keylens" preview-omk-save-config "$PL_CFG" 2>&1)
printf '       坏 TMPDIR：exit=%s 信封=%s 落脚=/data/local/tmp=%s\n' "$rc" \
    "$(printf '%s\n' "$o" | grep -c '^preview=1')" "$([ -e /data/local/tmp ] && echo 有 || echo 无)"
chk "坏 TMPDIR 时照样出一份信封" "1" "$(printf '%s\n' "$o" | grep -c '^preview=1')"
chk "坏 TMPDIR 时不是空预览（changed 与正常落脚一致）" "$(printf '%s\n' "$_s" | sed -n 's/^changed=//p')" \
                                                     "$(printf '%s\n' "$o" | sed -n 's/^changed=//p')"
chk "坏 TMPDIR 的输出与正常落脚逐字节相同" "$_s" "$o"
chk "坏 TMPDIR 也没把真实文件写了" "$_be" "$(fp)"
chk "影子根没在 /data/local/tmp 留下残骸" "0" "$(ls -d /data/local/tmp/keylens-preview-* 2>/dev/null | wc -l | tr -d ' ')"

echo "── 统计（断言 $oks 条）"
# 11 条 preview 的逐字节 + 5 条落脚点/信封断言 = 16；少了就是台子自己少跑了东西
if [ "$oks" -lt 16 ]; then echo "  ✗   断言数低于下限（$oks < 16），疑似有断言没执行"; exit 1; fi
if [ "$fail" = 0 ]; then echo "全部通过"; else echo "有断言失败"; exit 1; fi
