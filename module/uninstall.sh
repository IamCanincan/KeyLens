#!/system/bin/sh
#=============================================================================
# uninstall.sh - 卸载清理（框架固定调用，必须位于模块根目录）
#
# 说明：只删除本模块自身的文件；target.txt / config.json 属于后端，保持不动。
#=============================================================================

# ---------- 目录清单与"核过 cmdline 才杀" ----------
# 目录清单取自 lib/core.sh 的 KL_BACKEND_DIRS（单一真源）；取不到就用同一份字面值。
MODDIR="${0%/*}"
DIRS="/data/adb/teesim /data/adb/tricky_store /data/adb/omk /data/misc/keystore/omk"
if [ -f "$MODDIR/lib/core.sh" ]; then
    _d=$(sed -n 's/^KL_BACKEND_DIRS="\([^"]*\)".*/\1/p' "$MODDIR/lib/core.sh" 2>/dev/null)
    [ -n "$_d" ] && DIRS="$_d"
    # kl_kill_pid / kl_pid_is_ours 只有这一份实现（core.sh）—— 不在这里抄第二份：
    # 那个函数守的是"pid 被复用时别杀到别人"，抄一份就等于多一个会走样的判据。
    . "$MODDIR/lib/core.sh" 2>/dev/null
fi
unset _d
command -v kl_kill_pid >/dev/null 2>&1 || kl_kill_pid() {
    # 连 core.sh 都读不到（模块目录残缺）时不按 pid 动手：此刻"名单里的号还是不是我们"
    # 已经无从证明，而误杀一个不相干的进程比多留一个守护（下次开机就被清）代价大。
    echo "找不到 lib/core.sh，跳过按 pid 收进程：$1" >&2
    return 1
}
command -v log_warn >/dev/null 2>&1 || log_warn() { echo "$*" >&2; }

# ---------- 结束守护进程 ----------
# 名单跟着后端走：旧版这里只列了 TS/SIM 两个目录，OMK 机器上卸载会**留下守护进程**，
# 它还在按名单改 injector.toml —— 用户卸了模块，配置却继续被改。
for dir in $DIRS; do
    f="$dir/.kl_daemon_pids.list"
    [ -f "$f" ] || continue
    while read -r pid; do
        [ -n "$pid" ] && kl_kill_pid "$pid" TERM
    done < "$f"
    rm -f "$f" 2>/dev/null
done
unset f

# ---------- 结束残留的 inotify 进程 ----------
# 说明：匹配串必须带**我们自己的绝对路径**，不能用通名 "rules.txt"。
#       以前那两条是 inotifyd.*rules.txt —— 任何模块只要监听一个叫 rules.txt
#       的文件就会被一起杀掉（本模块的常驻列表与 Tricky Addon 之类正是同名）。
#       卸载是本模块的事，不该顺手停别人的监听。两个后端目录都列出来，
#       因为常驻列表跟着后端走。
pkill -f "inotifyd.*/data/adb/teesim/rules.txt" 2>/dev/null
pkill -f "inotifywait.*/data/adb/teesim/rules.txt" 2>/dev/null
pkill -f "inotifyd.*/data/adb/tricky_store/rules.txt" 2>/dev/null
pkill -f "inotifywait.*/data/adb/tricky_store/rules.txt" 2>/dev/null

# ---------- 删除本模块的运行文件 ----------
# 说明：按**前缀 glob** 收，不再手抄文件名。以前那张清单是抄的，而写文件的地方
#       散在 lib/ 与 webui.sh 里 —— 加一个新临时名不会有人想起回头补一行，
#       实测漏掉的包括 `.kl_keybox.$$`（里面是解码后的 keybox 私钥材料）和全部
#       `.kl_save.$$ / .kl_*.$$` 临时目录。前缀是本模块自己的（kl = KeyLens），
#       后端与别的模块都不往这些目录里写 `.kl_*`。
#       `.ts_*` 是改名前那版（ts-auto-add）的同一批文件：升级路径由
#       migrate_legacy_paths 搬走，但"只装过旧版、没升级就卸"的机器上它还躺着。
# 目录清单在前面（结束守护进程那一段）已经算好，这里直接用。
for dir in $DIRS; do
    [ -d "$dir" ] || continue
    rm -rf "$dir/.kl_"* "$dir/.ts_"* 2>/dev/null
    # 旧版留下的、名字不带我们前缀的两个运行文件：v2.2.19.4 那代按"本月已打过补丁"
    # 记的 .last_month，和更早上一代当"生效列表"用的 taa_sys.txt（前缀 taa_ 只有我们
    # 用过）。customize.sh 装机时也在收它们，卸载同样收掉；除我们没人写这些路径。
    rm -f "$dir/.last_month" "$dir/taa_sys.txt" 2>/dev/null
done
# 我们写给 OhMyKeymint 的重启请求（`>` 出来的空文件，消费方读完自己删）：
# 卸载后留着一个 pending 请求，下一次开机可能被当成"有人还要我重载"。
rm -f "/data/adb/omk/restart."* 2>/dev/null
# 我们的 A/B 参照树：deploy 时推上去的整份模块副本 + 真机台子（2 MB）。模块运行时
# 不碰它，但卸载后它同样是"我们留在 /data/adb 里的东西"（普通用户没有这个目录）。
rm -rf "/data/adb/keylens-ab" 2>/dev/null

# ---------- 明确不删的东西（归属不在本模块）----------
# · target.txt / config.json / injector.toml / keybox.xml —— 后端的配置与密钥。
#   卸载本模块不该改后端的状态，这些一直不碰。
# · *.bak —— 我们覆盖后端文件之前留的回滚副本（keybox.xml.bak 可能是用户花钱买的
#   上一份 keybox，injector.toml.bak 里可能带着 token）。旧版会顺手删掉
#   injector.toml.bak 与 security_patch.txt.bak：那是把用户唯一的回滚件销毁，
#   而它们本来就待在 0700 的目录里，留着比删掉安全。
# · rules.txt —— 上一版本模块的"常驻列表"，用户可以手编；而同名文件对
#   Tricky Addon 那类分支是**它自己的配置文件**。现在的模块既不读也不写 rules.txt，
#   再按路径把它删掉，等于替别人的模块做决定。旧版在这里删过，收手。
# · 反例：taa_sys.txt / .last_month 虽然不带 .kl_ 前缀，但那两个名字只有我们写过
#   （已在上面的循环里收掉）；/data/adb/service.d/taa_resetprop.sh 同理。
rm -f "/data/adb/service.d/taa_resetprop.sh" 2>/dev/null

# ---------- 删除日志缓冲、伪装开关与 boot hash ----------
# 新旧两组路径都删：改名前装的、升级后卸载的，不能把旧文件留在 /data/adb 里。
rm -f "/data/adb/keylens.log" "/data/adb/keylens.log.tmp" "/data/local/tmp/keylens.log" 2>/dev/null
rm -f "/data/adb/keylens.props_off" "/data/adb/keylens.boot_hash" 2>/dev/null
# env 的静态探针缓存（键里只有工具路径/机型/状态栏高度与 FRRO 原文，没有密钥），
# 连同落盘时的 .tmp.<pid> 一起清掉 —— 卸载后 /data/adb 里不该留模块的文件。
rm -f "/data/adb/keylens.env.cache" /data/adb/keylens.env.cache.tmp.* 2>/dev/null
rm -f "/data/adb/ts_auto.log" "/data/adb/ts_auto.log.tmp" "/data/local/tmp/ts_auto.log" 2>/dev/null
rm -f "/data/adb/ts_auto.props_off" "/data/adb/ts_auto.boot_hash" 2>/dev/null

exit 0
