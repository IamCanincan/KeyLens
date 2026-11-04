#!/bin/sh
#=============================================================================
# tests/uninstall-scope.sh - 卸载：该删的一个不剩，不该删的一个不碰
#
# 两件事分开钉：
#   ① 覆盖面：模块在 $KL_DIR 里写的每一个运行文件，卸载后必须不在了。
#      旧实现是一张手抄的文件名清单，实测漏掉 .kl_keybox.$$（解码后的 keybox 私钥
#      材料）、所有 .kl_save.$$ / .kl_*.$$ 临时件、以及 /data/misc/keystore/omk
#      这个目录本身。现在按前缀 glob 收，目录清单从 core.sh 的 KL_BACKEND_DIRS 取
#      （单一真源：以后加第四家，卸载自动跟上）。
#   ② 射程：*.bak / rules.txt / 后端配置不属于本模块，卸载不许动。
#      旧版会删 injector.toml.bak 与 security_patch.txt.bak（那是用户唯一的回滚件，
#      keybox.xml.bak 里可能是花钱买的上一份 keybox），还会删两个后端目录里的
#      rules.txt —— 现在的模块既不读也不写它，而 Tricky Addon 那类分支把它当自己的
#      配置文件，按路径删就是替别人的模块做决定。
#
# 台架是"在沙箱里真跑一遍只改了路径的 uninstall.sh"，判据看文件系统最后剩什么，
# 不是 grep 它的文本（文本层面另有一条静态断言兜着）。
#
# 跑法：sh tests/uninstall-scope.sh
#=============================================================================
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  ✗    %s\n' "$1"; fail=1; }

# 本模块写的（卸载后必须不在）
OURS="
data/adb/teesim/.kl_lock
data/adb/teesim/.kl_lock/pid
data/adb/teesim/.kl_debounce
data/adb/teesim/.kl_tmp
data/adb/teesim/.kl_fingerprint
data/adb/teesim/.kl_installed_last
data/adb/teesim/.kl_ever
data/adb/teesim/.kl_daemon_pids.list
data/adb/teesim/.last_month
data/adb/teesim/taa_sys.txt
data/adb/tricky_store/.kl_save.4242
data/adb/tricky_store/.kl_keybox.4242
data/adb/tricky_store/.kl_restore.req.4242
data/adb/tricky_store/.kl_remove.4242
data/adb/tricky_store/.ts_installed_last
data/adb/tricky_store/.ts_rules_last
data/adb/omk/.kl_mode.4242
data/adb/omk/.kl_ov.4242
data/adb/omk/.kl_prof.4242
data/adb/omk/restart.injector
data/adb/keylens-ab/module/webui.sh
data/adb/keylens-ab/device-ab.sh
data/misc/keystore/omk/.kl_excl.4242
data/misc/keystore/omk/.kl_drop.4242
"
# 不属于本模块的（卸载后必须逐字节原样）
KEEP="
data/adb/tricky_store/target.txt
data/adb/tricky_store/keybox.xml
data/adb/tricky_store/rules.txt
data/adb/tricky_store/keybox.xml.bak
data/adb/tricky_store/security_patch.txt.bak
data/adb/teesim/config.json
data/adb/teesim/rules.txt
data/adb/teesim/overrides.json.bak
data/adb/teesim/config.json.bak
data/adb/omk/injector.toml.bak
data/adb/omk/config.toml.bak
data/adb/omk/keymint-daemon.pid
data/misc/keystore/omk/injector.toml
data/misc/keystore/omk/keybox.xml
"

# build_sandbox <根>  —— 造现场 + 放一份"只改了路径"的 uninstall.sh
build_sandbox() {
    R="$1"
    mkdir -p "$R/module/lib" || return 1
    for f in $OURS $KEEP; do
        mkdir -p "$R/$(dirname "$f")" 2>/dev/null
        case "$f" in
            *.kl_lock|*.kl_debounce|*.kl_tmp) mkdir -p "$R/$f" ;;
            *) printf '%s\n' "内容 $f" > "$R/$f" ;;
        esac
    done
    sed -e "s|/data/adb|$R/data/adb|g" -e "s|/data/misc/keystore/omk|$R/data/misc/keystore/omk|g" \
        module/uninstall.sh > "$R/module/uninstall.sh"
    sed -e "s|/data/adb|$R/data/adb|g" -e "s|/data/misc/keystore/omk|$R/data/misc/keystore/omk|g" \
        module/lib/core.sh > "$R/module/lib/core.sh"
    # 改写必须真的落到沙箱里，否则跑的是"删真机路径"的那份
    grep -q "^\\(DIRS\\|TS\\)=\"$R/data/adb" "$R/module/uninstall.sh" || return 1
    grep -q "^KL_BACKEND_DIRS=\"$R" "$R/module/lib/core.sh" || return 1
    # 夹具自证：两张清单里的每一条都真的在场。漏造一条，"全部原样/全部清除"
    # 就会对着一个不存在的文件点头（这一版本就漏造过 teesim/rules.txt）。
    for f in $OURS $KEEP; do
        [ -e "$R/$f" ] || { printf '夹具没造出 %s\n' "$f" >&2; return 1; }
    done
    return 0
}

ROOT=$(mktemp -d 2>/dev/null || echo "/tmp/klun-$$")
rm -rf "$ROOT"; mkdir -p "$ROOT"
build_sandbox "$ROOT" || { bad '沙箱没造起来（路径改写或夹具没落地）'; exit 1; }
ours_n=$(printf '%s\n' $OURS | grep -c .)
keep_n=$(printf '%s\n' $KEEP | grep -c .)
ok "沙箱就位：$ours_n 个自家文件 + $keep_n 个别人家的文件 + 改过路径的 uninstall.sh"

sh "$ROOT/module/uninstall.sh" >/dev/null 2>&1

# ── ① 该删的一个不剩 ─────────────────────────────────────────────────
left=""
for f in $OURS; do [ -e "$ROOT/$f" ] && left="$left $f"; done
if [ -z "$left" ]; then
    ok '本模块的运行文件全部清除（含 .kl_keybox.$$、.*.$$ 临时件、旧版 .ts_*、.last_month、restart.*、/data/misc/keystore/omk）'
else
    bad "还留着：$left"
fi

# ── ② 不该删的一个不碰（逐字节比内容，不是只看"名字还在"）────────────
touched=""
for f in $KEEP; do
    [ -e "$ROOT/$f" ] || { touched="$touched $f(没了)"; continue; }
    [ "$(cat "$ROOT/$f" 2>/dev/null)" = "内容 $f" ] || touched="$touched $f(被改了)"
done
if [ -z "$touched" ]; then
    ok '后端配置（target.txt / keybox.xml / injector.toml / config.json）、*.bak 回滚件、rules.txt、后端的 pid 文件全部原样'
else
    bad "被动过：$touched"
fi

# ── 变异：把"旧版的射程"种回第二份沙箱，②那条必须响 ───────────────────
M="$ROOT/mut"
build_sandbox "$M" || { bad '变异沙箱没造起来'; }
# 旧版那两行的形状：按后端路径删 rules.txt 与 .bak。必须插在 exit 0 **之前**，
# 否则追加到文件尾的那句根本不会被执行，变异就成了假阳性（本项目踩过一次）。
MUT="rm -f '$M/data/adb/tricky_store/rules.txt' '$M/data/adb/teesim/rules.txt' '$M/data/adb/omk/injector.toml.bak'"
sed "s|^exit 0\$|$MUT|" "$M/module/uninstall.sh" > "$M/mut.sh" && mv "$M/mut.sh" "$M/module/uninstall.sh"
grep -q 'tricky_store/rules.txt' "$M/module/uninstall.sh" || bad '变异没插进沙箱副本'
MTARGETS="data/adb/tricky_store/rules.txt data/adb/teesim/rules.txt data/adb/omk/injector.toml.bak"
before=0
for f in $MTARGETS; do [ -e "$M/$f" ] && before=$((before + 1)); done
[ "$before" = "3" ] || bad "变异沙箱里三件目标只在场 $before/3，下面的读数不作数"
sh "$M/module/uninstall.sh" >/dev/null 2>&1
gone=""
for f in $MTARGETS; do [ -e "$M/$f" ] || gone="$gone $(basename "$f")"; done
if [ "$before" = "3" ] && [ -n "$gone" ]; then
    ok "变异确实把不该删的删掉了（$gone）—— ②那条不是空转"
else
    bad "变异没落地（在场 $before/3、消失的是[${gone:-无}]），②的通过不能算证据"
fi
# 反向对照：变异沙箱里自家文件仍被清掉 —— 说明两条断言各自独立
mleft=""
for f in $OURS; do [ -e "$M/$f" ] && mleft="$mleft $f"; done
[ -z "$mleft" ] && ok '变异版照样清自家文件（①与②互不遮蔽）' || bad "变异版连自家都没清完：$mleft"

# ── 静态：文本层面不许再出现"按路径删 rules.txt / *.bak"的 rm 行 ───────
if grep -v '^[[:space:]]*#' module/uninstall.sh | grep -qE 'rm .*(rules\.txt|\.bak)'; then
    bad 'uninstall.sh 里还有 rm rules.txt / rm *.bak 这类删除行'
else
    ok '删除行里没有 rules.txt，也没有 *.bak'
fi
# 按前缀 glob 收，而不是又抄一张清单（抄的那张正是当年漏掉 .kl_keybox.$$ 的原因）
if grep -qE 'rm -rf "\$dir/\.(kl|ts)_"\*' module/uninstall.sh; then
    ok '清理走 .kl_*/.ts_* 前缀 glob'
else
    bad 'uninstall.sh 不再用前缀 glob —— 手抄清单会像当年一样漏掉新临时文件'
fi
# 目录清单与 core.sh 的 KL_BACKEND_DIRS 挂钩，且那一行确实有 4 个目录
cnt=$(sed -n 's/^KL_BACKEND_DIRS="\(.*\)".*/\1/p' module/lib/core.sh | tr ' \t' '\n\n' | grep -c '^/')
if grep -q 'KL_BACKEND_DIRS' module/uninstall.sh && [ "$cnt" -ge 4 ]; then
    ok "目录清单取自 core.sh 的 KL_BACKEND_DIRS（$cnt 个后端目录）"
else
    bad "卸载的目录清单没跟 KL_BACKEND_DIRS 挂上（从 core.sh 数到 $cnt 个目录）"
fi

rm -rf "$ROOT"
[ "$fail" = 0 ] && echo '全部通过' || echo '有断言失败'
exit "$fail"
