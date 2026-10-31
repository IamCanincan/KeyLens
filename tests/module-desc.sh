#!/system/bin/sh
#=============================================================================
# tests/module-desc.sh - module.prop 的 description 只许"改名"落盘
#
# 修掉的故障：set_module_desc 先用 sed 写到 tmp，然后 `cat "$tmp_file" > "$prop_file"`
# —— 那一步照样先把真文件截断再写。写到一半掉电/被杀就留下空文件或半截
# module.prop，管理器里整块模块显示成坏的。现在改成 chmod 保持权限 + mv。
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

rm -rf "$W"
[ "$fail" = 0 ] && echo '全部通过' || echo '有断言失败'
exit "$fail"
