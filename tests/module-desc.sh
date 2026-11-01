#!/system/bin/sh
#=============================================================================
# tests/module-desc.sh - module.prop 的 description 只许"改名"落盘
#
# 修掉的故障：set_module_desc 先用 sed 写到 tmp，然后 `cat "$tmp_file" > "$prop_file"`
# —— 那一步照样先把真文件截断再写。写到一半掉电/被杀就留下空文件或半截
# module.prop，管理器里整块模块显示成坏的。现在改成 chmod 保持权限 + mv。
#
# 2026-11-01 补：同一处故障在**二进制的同名函数**里又长回来了一次（只 write tmp + rename，
# 没补 mode），而命令层默认走 bin/keylens —— 也就是说这台子当时量的是没在跑的那份。
# 现在 shell 与 Rust 两边都钉：行为在 cargo 单测，形状在这里。
#
# 跑法：sh tests/module-desc.sh
#=============================================================================
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  ✗    %s\n' "$1"; fail=1; }

W=$(mktemp -d 2>/dev/null || echo "/tmp/kldesc-$$"); mkdir -p "$W"

# 抽真源（从 backend.sh 里取 set_module_desc 本体）
s=$(grep -n '^set_module_desc() {' module/lib/backend.sh | head -1 | cut -d: -f1)
[ -n "$s" ] || { bad '抽不到 set_module_desc'; exit 1; }
e=$(awk -v s="$s" 'NR>s && /^\}/{ print NR; exit }' module/lib/backend.sh)
eval "$(sed -n "${s},${e}p" module/lib/backend.sh)"
command -v set_module_desc >/dev/null 2>&1 && ok '从 backend.sh 抽出 set_module_desc' \
    || { bad '函数没抽出来'; exit 1; }

P="$W/module.prop"
printf 'id=keylens\nname=KeyLens\nversion=v1\nversionCode=1\ndescription=旧描述\n' > "$P"
chmod 644 "$P"
BEFORE=$(stat -c %a "$P" 2>/dev/null)
umask 077                       # 线上 service.sh/webui.sh 就是这个 umask
set_module_desc "$P" '✅ [OMK | 应用: 12 | 更新: 12:34]'
[ "$?" = 0 ] && ok '改写成功' || bad '改写失败'
grep -q '^description=✅ \[OMK | 应用: 12 | 更新: 12:34\]$' "$P" \
    && ok 'description 换成新值' || bad 'description 没换'
[ "$(grep -c . "$P")" = 5 ] && ok '其它行一条没丢（5 行）' || bad "行数不对：$(grep -c . "$P")"
[ "$(grep -c '^id=keylens$' "$P")" = 1 ] && ok 'id 还在' || bad 'id 丢了'
# 权限：改名会带上 tmp 的权限，函数在 mv 之后要把它补回原值。
# MSYS 上 chmod 会被 umask 再收一次，这条**验不了**——那种情况明说跳过，不算通过。
chmod 644 "$P" 2>/dev/null; : > "$W/cap"; chmod 644 "$W/cap"
if [ "$(stat -c %a "$W/cap" 2>/dev/null)" = 644 ]; then
    AFTER=$(stat -c %a "$P" 2>/dev/null)
    [ "$AFTER" = "$BEFORE" ] && ok "权限保持 $BEFORE（umask 077 下）" \
        || bad "权限从 $BEFORE 变成 $AFTER（管理器可能读不到）"
else
    printf '  --   跳过权限断言：这个平台 chmod 敌不过 umask（MSYS），只算"没测到"\n'
fi
ls "$W"/module.prop.tmp.* >/dev/null 2>&1 && bad '留下了 tmp 文件' || ok '没有 tmp 残留'

# 静态：落盘那一步不许退回 cat 覆盖。先证明判据抓得到旧形态（否则"没命中"分不清干净还是瞎）
printf 'cat "$tmp_file" > "$prop_file"\n' | grep -q 'cat "\$tmp_file" > "\$prop_file"' \
    && ok '静态判据的正对照：旧形态能被抓到' || bad '静态判据抓不到旧形态（闸是瞎的）'
if grep -v '^[[:space:]]*#' module/lib/backend.sh | grep -qE 'cat "\$tmp_file" >'; then
    bad 'backend.sh 里还用 cat 覆盖 module.prop（非原子）'
else
    ok 'backend.sh 不再用 cat 覆盖 module.prop'
fi
grep -q 'mv -f "\$tmp_file" "\$prop_file"' module/lib/backend.sh \
    && ok '落盘走 mv（同一目录内改名，原子）' || bad 'backend.sh 里找不到 mv 落盘'

# ── 二进制的同名函数 ────────────────────────────────────────────────────
# 这台子以前只 eval backend.sh 那份，而命令层现在默认走 bin/keylens —— 真正在跑的那份没人看。
# 漏的正是这条：Rust 版只 write tmp + rename，没把原 mode 补回去，module.prop 的权限跟着
# 调用者的 umask 漂（生产机上实测漂成 666，是整棵模块目录里唯一世界可写的文件）。
# 行为断言在 cargo 单测里（set_module_desc_keeps_mode_and_other_lines，已拿"删掉补权限那行"
# 验过它会红）；这里再钉一条静态形状闸，防止有人日后把那三行"顺手简化"掉。
RB=$(awk '/^fn set_module_desc\(/,/^\}/' rust/src/read_cmds.rs)
[ -n "$RB" ] && ok '从 read_cmds.rs 抽出 set_module_desc' || bad '抽不到 Rust 的 set_module_desc'
printf '%s\n' "$RB" | grep -q 'keep_mode' \
    && ok 'Rust 版在改名前记下原 mode' || bad 'Rust 版没记原 mode'
printf '%s\n' "$RB" | grep -q 'std::fs::set_permissions(prop, std::fs::Permissions::from_mode(m))' \
    && ok 'Rust 版改名后把 mode 补回去' || bad 'Rust 版改名后没补 mode（会跟着 umask 漂）'
printf '%s\n' "$RB" | grep -q 'tmp\.{}' \
    && ok 'Rust 版的 tmp 带 pid（两个进程不会踩同一个临时文件）' || bad 'Rust 版的 tmp 名不带 pid'
# 正对照：把"补 mode"那行拿掉，上面的判据必须变红（不然分不清是干净还是瞎）
RB_MUT=$(printf '%s\n' "$RB" | grep -v 'std::fs::set_permissions(prop')
if [ "$(printf '%s\n' "$RB_MUT" | grep -c 'std::fs::set_permissions(prop')" = 0 ] \
   && [ -n "$RB" ] && printf '%s\n' "$RB" | grep -q 'std::fs::set_permissions(prop'; then
    ok '静态判据的正对照：删掉补权限那行它就抓得到'
else
    bad '静态判据是瞎的：造不出该被抓的形状'
fi

rm -rf "$W"

# ── module.prop 的 versionCode 必须在 32 位有符号范围内 ──────────────────
# KernelSU 的管理器用 Int 解析它（Module.versionCode: Int / obj.optInt，源码 v3.3.1），
# 12 位的日期码（如 202611012340）会溢出：更新检查的 `versionCode <= module.versionCode`
# 于是判成"没有新版"，模块列表里永远不出现更新按钮（其它模块的 10 位码都正常）。
# 约定：10 位 YYYYMMDDHH（2026-11-01 23 点 = 2026110123），上限到 2147 年都安全。
VC=$(sed -n 's/^versionCode=//p' module/module.prop | head -n 1)
case "$VC" in ''|*[!0-9]*) bad "module.prop 的 versionCode 不是纯数字：[$VC]" ;; esac
[ "$VC" -lt 2147483647 ] \
    && ok "versionCode=$VC 在 Int 范围内（更新检查才认得出" \
    || bad "versionCode=$VC 超过 2^31-1 —— KernelSU 按 Int 解析会溢出，更新按钮永远不出现"
# 反面样本：拿一个 12 位码过同一条判据，必须被判红（否则这条闸是瞎的）
[ 202611012340 -lt 2147483647 ] \
    && bad "闸是瞎的：12 位码居然被放过" \
    || ok "反面样本：12 位码 $((202611012340)) 会被判红"
[ "$fail" = 0 ] && echo '全部通过' || echo '有断言失败'
exit "$fail"
