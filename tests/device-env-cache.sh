#!/bin/sh
# device-env-cache：真机上验 env 探针缓存。
#
# 为什么要真机：这台有真实的 SystemUI FRRO（/data/resource-cache/com.android.systemui-accent-*.frro），
# 而夹具机上那个目录是空的 —— 缓存里最要紧的一段（强调色按 mtime 失效、路径与 base64 成对更新、
# 两边共用同一份文件）在 rust/parity.sh 里**结构性测不到**。对拍能证的是键名、fork 计数与冷=热；
# FRRO 那半段只有上机才算数。
#
# 用法（手机上）：
#   adb shell "sh /data/adb/keylens-ab/tests-env-cache.sh"   # 或先推到模块目录再跑
# 全程只用 KL_ENV_CACHE 指到临时文件，不碰生产的 /data/adb/keylens.env.cache。
set -u
MODDIR=${MODDIR:-/data/adb/modules/keylens}
[ -f "$MODDIR/webui.sh" ] || { echo "  skip 找不到 $MODDIR/webui.sh"; echo "全部通过"; exit 0; }
[ -x "$MODDIR/bin/keylens" ] || { echo "  skip 没有 $MODDIR/bin/keylens"; echo "全部通过"; exit 0; }
[ "$(id -u)" = "0" ] || { echo "  skip 需要 root"; echo "全部通过"; exit 0; }

T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
TAB=$(printf '\t')
fail=0
oks=0
chk() {
    if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"; oks=$((oks + 1))
    else printf '  ✗    %s\n        期望 [%s]，实得 [%s]\n' "$1" "$2" "$3"; fail=1; fi
}
# 密钥材料不进终端：env 的输出里有整张 FRRO 的 base64，打印时折掉（比较仍用全文）
redact() { sed -e 's/^\(sys_frro=\).\{60,\}$/\1…（FRRO base64，已略）/'; }

# 进程计数器：包装 /system/bin 的那几个探针命令，先记一行再原样 exec。
# 只对"直接调二进制"这条腿有效 —— webui.sh 第 42 行把 /system/bin 拼在 $PATH 之前，
# 壳层跑起来真二进制先命中，计数会是假的 0。所以下面只对二进制腿下计数断言，
# 并且先证明这个计数器在冷跑里响过。
# 两台子上都踩过的坑，写在这：
#   · mksh 的 ${v%|*} 不生效（`|` 被当成别的），剥末段一律走 sed；
#   · toybox grep 不支持 BRE 的 `\|`，命中数会静默变 0 —— 要么 -E，要么多个 -e。
W="$T/wrap"
mkdir -p "$W"
for p in getprop dumpsys wm id settings; do
    cat > "$W/$p" <<EOF
#!/system/bin/sh
printf '$p %s\n' "\$*" >> "$T/log.\$KL_ENV_TAG" 2>/dev/null
exec /system/bin/$p "\$@"
EOF
done
chmod 755 "$W"/*
# 与 webui.sh 同一份 PATH（少一段就会让 resetprop= 这类行在两条腿之间不一样，
# 那测的是仪器不是实现）
RPATH="$W:/system/bin:/system/xbin:/odm/bin:/vendor/bin:/product/bin:/data/adb/magisk:/data/adb/ksu/bin:/data/adb/ap/bin:/system/bin"
BIN="$MODDIR/bin/keylens"

benv() { # <cache> <日志后缀>
    KL_ENV_TAG="$2" PATH="$RPATH" KEYLENS_MODDIR="$MODDIR" KL_ENV_CACHE="$1" "$BIN" env 2>&1
}
senv() { # <cache>
    KL_USE_RUST=0 PATH="$RPATH" MODDIR="$MODDIR" KL_ENV_CACHE="$1" sh "$MODDIR/webui.sh" env 2>&1
}
cnt() { # <模式> <日志后缀> —— 日志文件不存在就是 0
    if [ -f "$T/log.$2" ]; then grep -c -- "$1" "$T/log.$2"; else echo 0; fi; }
kcol() { cut -f1 "$1" | tr '\n' ',' | sed 's/,$//'; }
# 缓存键的前三段（v1|模块目录|版本）；末段是 /system/build.prop 的 mtime，按机器算，不比
ckh() { awk -F"$TAB" 'NR==1{print $2}' "$1" | sed 's/|[^|]*$//'; }

echo "── 1 二进制：冷跑一遍、热跑一遍（真 FRRO 在场）──"
C1="$T/b.cache"
benv "$C1" b1 > "$T/b1.out"
benv "$C1" b2 > "$T/b2.out"
redact < "$T/b1.out" | sed 's/^/       /'
# 覆盖率的正对照：这台必须有 FRRO，否则这一节与夹具机等价，白测。
chk "这台有强调色 FRRO（sys_frro 两行都在）" "2" "$(grep -c '^sys_frro' "$T/b1.out")"
chk "计数器能响：冷跑起了 getprop/dumpsys window/wm/id" "4" \
    "$(( $(cnt '^getprop' b1) + $(cnt '^dumpsys window' b1) + $(cnt '^wm' b1) + $(cnt '^id' b1) ))"
chk "热跑不再起 getprop" "0" "$(cnt '^getprop' b2)"
chk "热跑不再起 dumpsys window" "0" "$(cnt '^dumpsys window' b2)"
chk "热跑不再起 wm" "0" "$(cnt '^wm' b2)"
chk "热跑不再起 id" "0" "$(cnt '^id' b2)"
chk "热跑仍现取深浅色（dumpsys uimode）" "1" "$(cnt '^dumpsys uimode' b2)"
chk "热跑仍现取种子（settings get）" "1" "$(cnt '^settings get' b2)"
chk "冷=热：逐行一致（FRRO 的 base64 也在里面）" "$(cat "$T/b1.out")" "$(cat "$T/b2.out")"
chk "热跑仍交出整张 overlay" "2" "$(grep -c '^sys_frro' "$T/b2.out")"

echo "── 2 落盘形状（键名逐个点名，不只跟 shell 比）──"
chk "缓存 19 行" "19" "$(wc -l < "$C1" | tr -d ' ')"
chk "键名与顺序" \
    "v1,resetprop,awk,base64,base64_cmd,ino_mode,ino_cmd,root_user,webui_sh,device,brand,android,sdk,build_type,vbstate,statusbar_dp,frro_path,frro_mtime,frro_b64" \
    "$(kcol "$C1")"
chk "权限 600" "600" "$(stat -c %a "$C1" 2>/dev/null)"
chk "不留 .tmp.*（改名落盘）" "0" "$(ls "$C1".tmp.* 2>/dev/null | wc -l | tr -d ' ')"
ver=$(sed -n 's/^version=//p' "$MODDIR/module.prop" | head -n 1)
chk "缓存键带模块目录与版本" "v1|$MODDIR|$ver" "$(ckh "$C1")"
chk "FRRO 路径与 base64 成对写进缓存" "2" "$(grep -c -e "^frro_path$TAB/" -e "^frro_b64$TAB[A-Za-z0-9+/=]" "$C1")"

echo "── 3 交叉：二进制写的缓存，shell 腿要读出同样的行 ──"
S0="$T/s0.cache"; S1="$T/s1.cache"
senv "$S0" > "$T/s0.out"                       # shell 自己冷跑
senv "$S1" > "$T/s1.out"; senv "$S1" > "$T/s2.out"   # shell 冷→热
chk "shell 冷=热" "$(cat "$T/s0.out")" "$(cat "$T/s2.out")"
chk "shell 冷 vs 二进制冷（真机全量逐行）" "$(cat "$T/s0.out")" "$(cat "$T/b1.out")"
benv "$S0" b3 > "$T/b3.out"
chk "二进制读 shell 写的缓存 → 逐行一致" "$(cat "$T/s0.out")" "$(cat "$T/b3.out")"
senv "$C1" > "$T/s3.out"
chk "shell 读二进制写的缓存 → 逐行一致" "$(cat "$T/b1.out")" "$(cat "$T/s3.out")"

echo "── 4 失效：FRRO 的 mtime 记错了要重编（这是夹具测不到的那段）──"
real_mt=$(awk -F"$TAB" '$1=="frro_mtime"{print $2}' "$C1")
awk -F"$TAB" -v mt=1 'BEGIN{OFS=FS} $1=="frro_mtime"{$2=mt} {print}' "$C1" > "$T/m.cache"
if cmp -s "$C1" "$T/m.cache"; then
    echo "  ✗    变异没落地（缓存里 frro_mtime 改不动）"; fail=1
else
    benv "$T/m.cache" m1 > "$T/m1.out"
    chk "mtime 记错 → 重新编码并把真值写回" "$real_mt" "$(awk -F"$TAB" '$1=="frro_mtime"{print $2}' "$T/m.cache")"
    chk "mtime 变异不改变答案" "$(cat "$T/b1.out")" "$(cat "$T/m1.out")"
    # 换主题的样子 = 路径变了。缓存里存一个不存在的同名文件，重跑必须把它掰回真路径。
    real_path=$(awk -F"$TAB" '$1=="frro_path"{print $2}' "$C1")
    awk -F"$TAB" -v p="$real_path.stale" 'BEGIN{OFS=FS} $1=="frro_path"{$2=p} {print}' "$C1" > "$T/q.cache"
    if cmp -s "$C1" "$T/q.cache"; then
        echo "  ✗    变异没落地（缓存里 frro_path 改不动）"; fail=1
    else
        benv "$T/q.cache" q1 > "$T/q1.out"
        chk "路径记错 → 重挑并把真路径写回" "$real_path" "$(awk -F"$TAB" '$1=="frro_path"{print $2}' "$T/q.cache")"
        chk "路径变异不改变答案" "$(cat "$T/b1.out")" "$(cat "$T/q1.out")"
        chk "重烧后 base64 仍在缓存里" "1" "$(grep -c -e "^frro_b64$TAB[A-Za-z0-9+/=]" "$T/q.cache")"
    fi
fi

echo "── 5 失效：缓存键里的模块目录（A/B 树与生产树不互喂）──"
awk -F"$TAB" 'BEGIN{OFS=FS} NR==1{$2="v1|/nonexistent-dir|zz|zz"} {print}' "$C1" > "$T/k.cache"
benv "$T/k.cache" k1 > "$T/k1.out"
chk "键对不上 → 重探（getprop 又起来了）" "1" "$(cnt '^getprop' k1)"
chk "键对不上不改变答案" "$(cat "$T/b1.out")" "$(cat "$T/k1.out")"
chk "重探后缓存键回到本机本目录" "v1|$MODDIR|$ver" "$(ckh "$T/k.cache")"

echo "── 统计"
if [ "$oks" -lt 28 ]; then
    echo "  ✗   断言数量低于下限（$oks < 28），疑似用例被删"; fail=1
fi
if [ "$fail" = 0 ]; then echo "全部通过（$oks 项）"; else echo "有断言失败"; exit 1; fi
