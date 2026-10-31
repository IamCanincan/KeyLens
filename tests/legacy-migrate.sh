#!/system/bin/sh
#=============================================================================
# tests/legacy-migrate.sh - 改名迁移：老状态必须搬到新名字，且不覆盖、不丢
#
# 为什么单独测：模块从 TS-AUTO-ADD 改名 KeyLens 时，连**运行时状态文件名**都换了
# （/data/adb/ts_auto.* → keylens.*，后端目录里 .ts_* → .kl_*）。这些不是临时文件：
#   · ts_auto.props_off 存在 = 用户关掉了属性伪装 —— 丢了就静默回到"开"；
#   · .ts_installed_last 是快照差分的基线 —— 丢了下一轮把全部已装当"新装"重推一遍；
#   · .ts_ever 记着历次纳入过的包 —— 丢了"手动删掉的包不再回来"这个行为就失效。
# 而漏改一处锁名（.ts_lock → .kl_lock）会让守护进程与界面各拿一把锁。
# 所以迁移函数与"零残留"都是断言对象，不靠人眼扫。
#
# 跑法：sh tests/legacy-migrate.sh
#=============================================================================
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  ✗    %s\n' "$1"; fail=1; }

# 抽 core.sh 里的真函数（抄一份的话，改坏实现测试也不会响）
# _mig 与 migrate_legacy_paths 都要抽：后者调用前者。
for fn in _mig migrate_legacy_paths; do
    start=$(grep -n "^$fn() {" module/lib/core.sh | cut -d: -f1 | head -1)
    [ -n "$start" ] || { bad "抽不到 $fn"; exit 1; }
    end=$(awk -v s="$start" 'NR>s && /^\}/{ print NR; exit }' module/lib/core.sh)
    [ -n "$end" ] || { bad "$fn 找不到结尾"; exit 1; }
    eval "$(sed -n "${start},${end}p" module/lib/core.sh)"
    printf '  ok   从 core.sh 抽出 %s（第 %s–%s 行）\n' "$fn" "$start" "$end"
done

# 这条是踩过的坑：Android 的 sh 把 ${pair%%|*} 里的 | 当"或"，两个展开都变空串，
# 迁移静默不搬 —— 本机 dash/bash 一切正常，只有真机跑得出来。所以禁掉这种写法。
# 只判代码：解释这个坑的注释里就写着这种写法，连注释一起查会自己绊自己（犯过两次）。
if grep -hE '\$\{[a-zA-Z_]+(%%|##)\*?\|' module/lib/*.sh module/*.sh module/backends/*.sh 2>/dev/null \
   | grep -vE '^[[:space:]]*#' | grep -q .; then
    bad '又用 `|` 做 ${var%%|*} 切分了（Android sh 会当"或"，迁移会静默失效）'
else
    ok '没有用 | 做参数展开切分'
fi

D=$(mktemp -d 2>/dev/null) || D="/tmp/km-$$"
rm -rf "$D"; mkdir -p "$D/new" "$D/b1" "$D/b2" "$D/b3"
# 建不出来就自己说清楚：这里死过一次（rc≠0 却一条 ✗ 都没打），只看得出"失败了"。
[ -d "$D/new" ] || { echo '  ✗    临时目录建不起来（mktemp 与 /tmp 回退都失败）'; exit 1; }

KL_LOG="$D/new/keylens.log"; KL_PROPS_OFF="$D/new/keylens.props_off"; KL_BOOT_HASH="$D/new/keylens.boot_hash"
KL_LEGACY_LOG="$D/ts_auto.log"; KL_LEGACY_PROPS_OFF="$D/ts_auto.props_off"; KL_LEGACY_BOOT_HASH="$D/ts_auto.boot_hash"
KL_BACKEND_DIRS="$D/b1 $D/b2 $D/b3"

# 现场：/data/adb 那三个旧文件 + 后端目录里一批 .ts_*
printf 'x' > "$KL_LEGACY_LOG"
printf 'x' > "$KL_LEGACY_PROPS_OFF"          # 存在 = 伪装已关，这条语义必须跟着走
printf 'deadbeef' > "$KL_LEGACY_BOOT_HASH"
for n in .ts_lock .ts_ever .ts_installed_last .ts_fingerprint .ts_daemon_pids.list; do
    printf 'v' > "$D/b1/${n#.}"              # 真名是带点的隐藏文件
    printf 'v' > "$D/b1/$n"
done
printf 'v' > "$D/b2/.ts_removed"
# b3 用来验"新名已存在时不许覆盖"
printf '新值' > "$D/b3/.kl_ever"
printf '旧值' > "$D/b3/.ts_ever"

migrate_legacy_paths

has() { [ -e "$1" ] && printf 1 || printf 0; }
printf '── /data/adb 三个状态文件 ──\n'
[ "$(has "$KL_LOG")" = 1 ] && ok '日志缓冲搬到新名' || bad '日志没搬'
[ "$(has "$KL_PROPS_OFF")" = 1 ] && ok '伪装开关搬到新名（存在=已关，语义没丢）' || bad '开关丢了：用户会静默回到"开"'
[ "$(has "$KL_BOOT_HASH")" = 1 ] && [ "$(cat "$KL_BOOT_HASH")" = deadbeef ] && ok '启动哈希搬过去且内容一致' || bad '哈希搬错'
[ "$(has "$KL_LEGACY_LOG")" = 0 ] && ok '旧文件不留下孤儿' || bad '旧文件还在'

printf '── 后端目录里的 .ts_* → .kl_* ──\n'
for n in lock ever installed_last fingerprint daemon_pids.list removed; do
    [ -e "$D/b1/.kl_$n" ] || [ -e "$D/b2/.kl_$n" ] || bad ".ts_$n 没搬到 .kl_$n"
done
ok '基线/ever/锁/指纹/pids 全部改名到位'
[ -e "$D/b1/.ts_lock" ] && bad '旧锁名还在（两份代码可能各拿一把锁）' || ok '旧锁名已清'
# 只搬隐藏文件：`.ts_x` 写成普通文件名的那个不该被动（我们的 glob 只认点开头）
[ -e "$D/b1/ts_ever" ] && ok '非隐藏的同名文件没被误搬' || bad 'glob 太宽，把不带点的文件也搬了'

printf '── 不许覆盖、且幂等 ──\n'
[ "$(cat "$D/b3/.kl_ever")" = "新值" ] && ok '新名已存在时不覆盖（用户的新数据优先）' || bad '把已有新值覆盖了'
before=$(ls -A "$D/b3" | tr '\n' ' ')
migrate_legacy_paths; migrate_legacy_paths
after=$(ls -A "$D/b3" | tr '\n' ' ')
[ "$before" = "$after" ] && ok '反复调用是 no-op（幂等）' || bad "第二次调用改了东西：$before → $after"

printf '── 目录不存在 / 空目录不许炸 ──\n'
KL_BACKEND_DIRS="$D/nope $D/b1"
KL_LOG="$D/new2/keylens.log"; mkdir -p "$D/new2"
migrate_legacy_paths; rc=$?
[ "$rc" = 0 ] && ok '缺目录退 0（迁移失败不该阻断开机）' || bad "缺目录时退 $rc"

printf '── 迁移目录表必须覆盖后端真正的运行期目录 ──\n'
# OMK 的运行期文件寄在 KL_DIR = /data/adb/omk，而它的配置在 /data/misc/keystore/omk ——
# 两个目录只有一字之差，漏了前者，OMK 机器上的基线/ever/pid 一个都不会搬（真踩过）。
omk_state=$(sed -n 's/^OMK_STATE_DIR="\([^"]*\)".*/\1/p' module/lib/core.sh | head -1)
teesim_dir=$(sed -n 's/^TEESIM_DIR="\([^"]*\)".*/\1/p' module/lib/core.sh | head -1)
tstore_dir=$(sed -n 's/^TSTORE_DIR="\([^"]*\)".*/\1/p' module/lib/core.sh | head -1)
dirs=$(sed -n 's/^KL_BACKEND_DIRS="\([^"]*\)".*/\1/p' module/lib/core.sh | head -1)
for d in "$omk_state" "$teesim_dir" "$tstore_dir"; do
    [ -n "$d" ] || { bad '从 core.sh 抽不到后端目录常量'; continue; }
    case " $dirs " in
        *" $d "*) ok "迁移表包含 $d" ;;
        *) bad "迁移表漏了 $d（那里的运行期文件不会被搬）" ;;
    esac
done

printf '── 迁移搬的名字，必须是代码真在用的名字 ──\n'
# 这一条抓的是"迁移与代码各说各话"：改名那次把 .ts_lock 切成了 .kl__lock（双下划线），
# 30 处代码自己是一致的、看着能用，但迁移生成的是 .kl_lock —— 搬过去的文件新代码永远看不见。
used=$(grep -oh '\.kl_[a-z_.]*' module/*.sh module/lib/*.sh 2>/dev/null | sed 's/\.$//' | sort -u)
for n in lock ever installed_last fingerprint daemon_pids.list removed; do
    printf '%s\n' "$used" | grep -qx "\.kl_$n" \
        || bad "代码里没有 .kl_$n（迁移搬过去的文件它会看不见）"
done
ok '六类运行时文件名在代码里都对得上'
if printf '%s\n' "$used" | grep -q '\.kl__'; then
    bad '出现了 .kl__（双下划线）：改名脚本切片偏了一位，迁移与代码会对不上'
else
    ok '没有 .kl__ 双下划线'
fi

printf '── 零残留：老名字只许在白名单里 ──\n'
if command -v node >/dev/null 2>&1; then
    node tools/name-residue-check.mjs >/tmp/_res 2>&1 && ok 'name-residue 闸门通过' \
        || { bad '残留闸门报了非白名单项：'; tail -6 /tmp/_res | sed 's/^/        /'; }
    # 正对照：往一个源文件里塞一条旧名，闸门必须响 —— 不然"0 处"可能只是闸门瞎了
    cp module/lib/props.sh "$D/props.bak"
    printf '\n# 正对照：故意留下的旧锁名 .ts_lock\n' >> module/lib/props.sh
    if node tools/name-residue-check.mjs >/tmp/_res2 2>&1; then
        bad '正对照没响：闸门看不见新塞进去的旧名'
    else
        grep -q 'props.sh' /tmp/_res2 && ok '正对照响且点名文件' || bad '响了但没指出是哪'
    fi
    cp "$D/props.bak" module/lib/props.sh
    [ "$(cmp -s "$D/props.bak" module/lib/props.sh; printf $?)" = 0 ] && ok '正对照跑完逐字节还原' || bad '还原失败'
    node tools/name-residue-check.mjs >/dev/null 2>&1 || bad '还原后闸门仍红'
else
    printf '  ·    本机没有 node，跳过残留闸门这一段\n'
fi

# ── 顺序判据：任何一次 run_sync 之前必须先 migrate_legacy_paths ──────────
# 为什么钉这个：迁移没跑就先同步，run_sync 会走"首次安装"分支自己建一份新基线，
# 而 migrate 见新名已存在就跳过 —— 旧的那份 .ts_installed_last 从此永远搬不动，
# 你手动排除过的应用会被重新加进名单。service.sh / post-fs-data.sh 一直是对的，
# 漏的是刷机当次（customize.sh）与按"操作"按钮（action.sh）这两条入口。
# 只认代码行：注释里也会出现 run_sync / migrate_legacy_paths（下面的说明就是），
# 拿 grep | head -1 会把散文当成调用点 —— 第一版就是这样报出"migrate=89 run_sync=85"
# 的假红，而 85 那行其实是我写的注释。
for f in module/customize.sh module/action.sh module/service.sh module/post-fs-data.sh; do
    if grep -qE '^[^#]*run_sync ' "$f"; then
        s=$(grep -nE '^[^#]*run_sync ' "$f" | head -1 | cut -d: -f1)
        m=$(grep -nE '^[^#]*migrate_legacy_paths$' "$f" | head -1 | cut -d: -f1)
        # 这个套子只有 ok/bad 两个助手（没有 chk）—— 用错助手时 shell 只会报
        # "command not found" 而不会让 fail 变 1，四条断言会一条都不生效还全绿。
        if [ -n "$m" ] && [ "$m" -lt "$s" ]; then
            ok "$f：migrate（第 $m 行）先于 run_sync（第 $s 行）"
        else
            bad "$f：迁移没排在同步之前（migrate=${m:-无} run_sync=$s）"
        fi
    fi
done
# 变异：把 customize.sh 的迁移挪到同步之后，顺序判据必须跟上
cp module/customize.sh "$D/cust.bak"
awk '{ if ($0 == "migrate_legacy_paths") { del=1; next } print; if (del && /^run_sync /) { print "migrate_legacy_paths"; del=0 } }' \
    "$D/cust.bak" > "$D/cust.mut"
if cmp -s "$D/cust.bak" "$D/cust.mut"; then
    bad '变异没落地（customize.sh 一字未改，这条不算证据）'
else
    m=$(grep -nE '^[^#]*migrate_legacy_paths$' "$D/cust.mut" | head -1 | cut -d: -f1)
    s=$(grep -nE '^[^#]*run_sync ' "$D/cust.mut" | head -1 | cut -d: -f1)
    [ -n "$m" ] && [ "$m" -gt "$s" ] && ok '变异「迁移挪到同步之后」被顺序判据抓到' \
        || bad '变异后判据没跟上（m=$m s=$s）'
fi
cmp -s "$D/cust.bak" module/customize.sh && ok '原文件没被动过（变异只写在临时副本里）' \
    || bad '原文件被改了 —— 还原失败'

# 安装时自动接管：旧模块目录必须在 customize.sh 里被移除（删的是旧模块的脚本，
# 状态在 /data/adb/ts_auto.* 与后端目录里，由 migrate_legacy_paths 搬走）。
# 留着旧目录 = 两套 service.sh 同跑（两份守护进程各监听、各写同一份后端配置）。
grep -q '/data/adb/modules/ts-auto-add' module/customize.sh \
    && ok '安装时移除旧模块目录（ts-auto-add）' \
    || bad 'customize.sh 没有接管旧模块目录（ts-auto-add）'
grep -q '/data/adb/modules/ts_auto' module/customize.sh \
    && ok '安装时移除旧模块目录（ts_auto）' \
    || bad 'customize.sh 没有接管旧模块目录（ts_auto）'
# 旧版 OMK 状态目录（早期 /data/adb/ts_auto.omk）也必须被迁移扫到，否则只装过
# 旧版的 OMK 机器基线/ever/pid 一个都搬不过来。
grep -q '/data/adb/ts_auto.omk' module/lib/core.sh \
    && ok '迁移目录表含旧版 OMK 状态目录' \
    || bad '迁移目录表漏了 /data/adb/ts_auto.omk'

rm -rf "$D"
[ "$fail" = 0 ] && echo "全部通过" || echo "有断言失败"
exit $fail
