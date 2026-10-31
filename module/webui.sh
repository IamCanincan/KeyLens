#!/system/bin/sh
#=============================================================================
# webui.sh - WebUI 命令层（由管理器 WebView 经 root shell 调用）
#
# 用法：sh /data/adb/modules/keylens/webui.sh <命令> [参数]
#
# 输出约定（供 webroot/index.html 解析，不面向人阅读）：
#   status / env / sync / props-apply / props-on / props-off / clear-log
#          key=value，每行一项
#   boot-hash
#          key=value（configured / current / status=ok|mismatch|unset|invalid）
#   props  「属性名<TAB>当前值<TAB>期望值<TAB>状态」，状态为 ok|diff|missing
#   icons  「包名<TAB>显示名<TAB>相对路径」，同时把 PNG 写进 webroot/icons/
#   targets / apps / log
#          原文逐行，不加装饰性文字（管理器按钮用的 action.sh 才带图标提示）
#   contract
#          key=value（api=<契约号> commands=<清单>），界面按自己期望的号比对
#
# 退出码：0=成功；1=参数非法、模块已停止、环境异常或写入失败
#
# 安全：命令名与参数只参与比较，不拼进任何 shell 命令；数字参数先夹取范围，
#       boot hash 先按 64/128 位十六进制校验；界面侧对参数统一做单引号转义。
#
# 性能：界面上每次刷新都对应一次本脚本调用，而本机每次 fork 要 20~90ms
#       （实测 17 次 getprop 共 397ms）。因此所有批量读取都遵循
#       「一次外部命令 + 参数展开取值」，不再逐项起子壳。
#=============================================================================

MODDIR="${0%/*}"
PROP_FILE="$MODDIR/module.prop"

# 权限：管理器 exec 出来的 shell 继承的 umask 可能是 000（实测生成过 666 的状态文件，
#       见 lib/applist.sh 的注释），而这个命令层会把 **keybox 私钥**解码到临时文件
#       （lib/write.sh:566 的 `> "$tmp"`）—— 默认 666 意味着从落盘到 chmod 之间那几百
#       毫秒里，任何应用都能读到私钥。这里对齐 service.sh 的 umask 077。
#       需要对外可读的那两处（图标 PNG、overrides.json）本来就各自显式 chmod 644，
#       其余目标文件的属主/模式/上下文由 write_atomic_preserve 从原件恢复，不受影响。
umask 077

# PATH 覆盖三个框架自带的 busybox 与 resetprop 目录：
# WebView 里 exec 出来的 shell 继承的是管理器的环境，不能假定 /system/bin 已在其中。
export PATH="/system/bin:/system/xbin:/odm/bin:/vendor/bin:/product/bin:/data/adb/magisk:/data/adb/ksu/bin:/data/adb/ap/bin:$PATH"

. "$MODDIR/lib/common.sh" || { echo "无法加载 lib/common.sh" >&2; exit 1; }

# 改名迁移：刷完没重启就打开界面时，界面读的启动哈希与伪装开关得是新路径上的那份。
# 幂等（新名已存在就不动），所以每次调用只是几次 stat。
migrate_legacy_paths

kl_is_root || { echo "需要 root 权限" >&2; exit 1; }

CMD="${1:-help}"
ARG="${2:-}"

# 图标缓存落在 webroot 下的这个子目录里（界面按相对路径引用）
ICONS_SUBDIR="icons"

# ---------- 命令层契约 ----------
# 说明：界面与命令层虽然打在同一个模块包里，但迭代时是**分别推文件**的
#       （只推 webroot/index.html 不用重装，或反之）。以前这种不同版只会
#       在界面上表现为"某个值怪怪的"，没有任何一处会明说自己读错了格式。
#       所以命令层自报一个号，界面拿自己期望的号比：对不上就横幅 + 停写，
#       而不是拿旧解析去画新数据。改任何命令的**输出形状**都要 +1。
KL_API=4
KL_COMMANDS="status env targets target-meta apps icons log clear-log props props-apply \
props-on props-off boot-hash props-boot-hash restore-app restore-apps remove-apps set-mode \
backend-info teesim-save omk-save-injector omk-save-config tricky-save-patch tricky-drop-patch keybox-save \
sync help contract excluded teesim-profiles tee-status tricky-patches omk-restart teesim-overrides \
teesim-save-overrides teesim-profile-new teesim-profile-del doctor backups backup-restore"

# ---------- 通用小工具 ----------
# 说明：换行常量。查表一律用「$NL + 键 + =」作锚点做参数展开，
#       不用 while read —— 实测每次 here-doc 都要建临时文件，17 次取值多花 1000ms。
NL='
'

# 用法：kv <键> <值>
# 说明：Android 的 mksh **没有 printf 内置命令**（`type printf` → /system/bin/printf → toybox），
#       所以以前每写一行 kv 就 fork+exec 一次进程：真机实测一行约 21ms，status 21 行、
#       env 30 行、backend-info 23 行 —— 每条命令白付 400~600ms，这是"打开比别家慢一拍"的大头
#       （对照：同机 DuckToolbox 的 status 约 200ms）。
#       mksh 的 `print -r --` 是内置的、且不展开反斜杠转义，字节形状与 printf '%s=%s\n' 一致；
#       没有 print 的 shell（换 busybox/dash 时）退回 printf 那条老路。
if print -r -- '' >/dev/null 2>&1; then
    kv() { print -r -- "$1=$2"; }
else
    kv() { printf '%s=%s\n' "$1" "$2"; }
fi

# 用法：tsv <列…> —— 一行 TSV。账同 kv：这个 shell 里 printf 是外部命令，
#       真机实测一行约 13~21ms，而 props 一页有三十多行。
if print -r -- '' >/dev/null 2>&1; then
    tsv() { local IFS="$TAB"; print -r -- "$*"; }
else
    tsv() { local IFS="$TAB"; printf '%s\n' "$*"; }
fi

# ---------- module.prop ----------
# 说明：整份读入后按锚点取值；逐字段 grep 会把同一个文件读三遍。
#       （module.prop 由 .gitattributes 固定为 LF，故不做 \r 清理）
# 用法：mod_prop <字段名>；结果放在 $MOD_PROP_VALUE
#       —— 用返回值而不是 $(mod_prop …)：命令替换会起子壳，缓存留在子壳里，
#          实测因此把同一份文件反复读了好几遍。
MODULE_PROP_CACHE=""
MOD_PROP_VALUE=""

mod_prop() {
    local rest

    MOD_PROP_VALUE=""
    [ -n "$MODULE_PROP_CACHE" ] || MODULE_PROP_CACHE="$NL$(cat "$PROP_FILE" 2>/dev/null)"
    case "$MODULE_PROP_CACHE" in
        *"$NL$1="*)
            rest="${MODULE_PROP_CACHE#*"$NL$1="}"
            MOD_PROP_VALUE="${rest%%"$NL"*}" ;;
    esac
    return 0
}

# ---------- 属性取值 ----------
# 用法：prop_now <属性名>；结果放在 $PROP_NOW（空串表示未定义或读不到）
# 说明：就是逐个 getprop，别再试「批处理」——本机实测四种读法：
#         17 次 getprop                              277ms   ← 现在用的
#         一次 getprop 全量 + grep -F -f 过滤成小表  1692ms（临时文件与多模式匹配）
#         一次 getprop 全量 + 参数展开查表            228487ms（67KB 字符串上做模式匹配）
#         一次 getprop 全量 | grep -E "^\[(k1|k2|…)\]: "   270~297ms（2026-10-31 重测）
#       在 mksh 里，对大字符串做 ${var#*pattern} 展开比多起几个进程贵得多；而"便宜的
#       dump（115ms）+ 贵的过滤"正好抵掉"贵的逐个 fork（18ms×17）"，四种里没有一种赢。
PROP_NOW=""

prop_now() {
    PROP_NOW=$(getprop "$1" 2>/dev/null)
    return 0
}

# 说明：把参数夹取为 [min,max] 内的整数，非法或越界时退回默认值
# 用法：clamp_int <值> <默认> <最小> <最大>
clamp_int() {
    local v="${1:-}" d="$2" lo="$3" hi="$4"

    case "$v" in
        ''|*[!0-9]*) printf '%s' "$d"; return 0 ;;
    esac
    [ "$v" -lt "$lo" ] && v="$lo"
    [ "$v" -gt "$hi" ] && v="$hi"
    printf '%s' "$v"
}

# 说明：模块因后端互斥而停止时，写类命令一律拒绝执行
# 用法：require_runnable
require_runnable() {
    if backends_conflict; then
        echo "$KL_CONFLICT_MSG" >&2
        return 1
    fi
    return 0
}

# 说明：界面侧的加锁。等锁只等 6 秒（守护进程用的是 LOCK_TIMEOUT=15）：
#       WebView 里的 exec 是同步的，等满 15 秒看起来就是界面卡死。
#       调用前必须先 detect_backend，否则锁路径不对、永远拿不到。
# 用法：webui_lock
webui_lock() {
    local timeout="$LOCK_TIMEOUT" lock_rc

    LOCK_TIMEOUT=6
    acquire_lock "${KL_DIR}/.kl_lock"
    lock_rc=$?
    LOCK_TIMEOUT="$timeout"
    if [ "$lock_rc" != 0 ]; then
        echo "守护进程正在写入，请几秒后再试" >&2
        return 1
    fi
    return 0
}

# ---------- 后端配置写回：公共工具 ----------
# 说明：界面把一个分组里的字段打成
#         key=<base64(value)>  每行一项
#       再整体 base64 后作为**一个**参数传进来（run() 只接受一个参数）。
#       这里先解外层，再逐行解 value；未知键、非法值在写盘前整体拒绝。
TAB=$(printf '\t')
CR=$(printf '\r')

# 用法：valid_text <值> [最大长度]；拒绝换行/制表/其它控制字符
valid_text() {
    local v="${1:-}" max="${2:-256}"
    case "$v" in *"$NL"*|*"$TAB"*|*"$CR"*) return 1 ;; esac
    [ "${#v}" -le "$max" ] || return 1
    printf '%s' "$v" | grep -q '[[:cntrl:]]' && return 1
    return 0
}

valid_bool() { [ "${1:-}" = "true" ] || [ "${1:-}" = "false" ]; }

# 说明：三家的启用状态报成三态，不是"开/关"两态 —— 界面上"没装"与"装了但被你
#       禁了"要给不同的下一步（去下载 / 把 disable 删掉）。以前的
#       teesim_enabled/tricky_enabled 只有 0/1，而且**根本没有 OMK 那一位**，
#       可 backends_conflict() 是把 OMK 一起数的 —— 于是"两家冲突"的横幅能亮，
#       却说不清是哪两家。没有任何界面读过那两个旧键（机上那版只在假数据里写它们），
#       所以直接换成 *_state。
# 用法：backend_state <模块目录>；结果放在 $BACKEND_STATE_VALUE
#       —— 取值走全局而不是 $(backend_state …)：命令替换要起子壳，真机实测一次约 40ms，
#          而 status 三家各一次（与上面 kv 那笔 fork 是同一类账）。mod_prop 早就是这个写法。
BACKEND_STATE_VALUE=""
backend_state() {
    BACKEND_STATE_VALUE=absent
    [ -d "$1" ] || return 0
    if [ -f "$1/disable" ]; then BACKEND_STATE_VALUE=disabled; else BACKEND_STATE_VALUE=active; fi
}

valid_log_level() {
    case "${1:-}" in off|error|warn|info|debug|trace) return 0 ;; esac
    return 1
}

# 说明：把关键字折成小写再比。两家上游的关键字比较都是 ignoreCase
#       （TEESimulator DeviceProps.kt:116-131 / TrickyStoreOSS AndroidUtils.kt:148-156），
#       这里再按大小写敏感判就会把上游合法的值误拒 —— 与 keybox 那轮"闸门严于上游"
#       是同一类错。但**日期模板令牌的大小写两家不一样**：
#         · TEESim 只替换大写的 YYYY/MM/DD（DeviceProps.kt:156 用 v.contains("YYYY")），
#           小写 yyyy 不会被替换，随后解析失败 → 该标签静默省略；
#         · Tricky 三个 replace 全带 ignoreCase = true（AndroidUtils.kt:167-171），
#           所以 yyyy-mm-dd 在 Tricky 那边是真能用的。
lower() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'; }

# TEE Simulator 的补丁占位与日期
valid_patch() {
    # `harvested` 这个字面量上游的 UI 校验表收了、README 也写了，但守护进程里
    # 没有对应分支（DeviceProps.resolvePatch / Resolver 都没有 equals("harvested")），
    # 写进去等于"该标签省略"，而它真正的"用采集值"写法是**空串**。
    # 与其静默收下让用户以为设好了，不如明确拒绝并给出正确写法。
    if [ "$(lower "${1:-}")" = "harvested" ]; then
        echo "harvested 这个写法上游守护进程并没有实现（写进去等于省略该标签）；要用采集值请留空" >&2
        return 1
    fi
    # 关键字（大小写不敏感）。no 在 TEESim 里是"报告 0"，不是"不报告" —— 与 Tricky 相反。
    case "$(lower "${1:-}")" in
        ''|today|no|system_property) return 0 ;;
    esac
    # 裸令牌：substituteDateTemplates 把它替换成"今天"的某一段之后，剩下的数字
    # 过不了上游自己的 \\d{6}|\\d{8}|\\d{4}-\\d{2}… 判据 → 标签被**静默省略**。
    case "${1:-}" in
        YYYY|MM|DD|yyyy|mm|dd) return 1 ;;
    esac
    case "${1:-}" in
        [0-9][0-9][0-9][0-9]|[0-9][0-9][0-9][0-9][0-9][0-9]|\
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) return 0 ;;
    esac
    printf '%s' "${1:-}" | grep -Eq '^(YYYY|[0-9]{4})-(0[1-9]|1[0-2]|MM)(-(0[1-9]|[12][0-9]|3[01]|DD))?$'
}

# Tricky 的补丁值与 TEESim 那套 mini 语言不同：它另有 device_default / prop 两个
# 关键字（AndroidUtils.kt:148-156），以前复用 valid_patch 会把这两个合法值拒掉。
valid_tricky_patch() {
    case "$(lower "${1:-}")" in
        no|device_default|prop) return 0 ;;
    esac
    # 裸令牌在这里同样过不了 parsePatchLevelValue（AndroidUtils.kt:176），
    # 结果是不匹配 = 该组件不带补丁标签；与 TEESim 的 no=0 是两回事。
    case "$(lower "${1:-}")" in
        yyyy|mm|dd) return 1 ;;
    esac
    # Tricky 的令牌替换不分大小写，所以整串折小写后按同一套日期式子判
    printf '%s' "$(lower "${1:-}")" | grep -Eq '^[0-9]{6}$|^[0-9]{8}$|^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$|^(yyyy|[0-9]{4})-(mm|0[1-9]|1[0-2])(-(dd|[0-3][0-9]))?$'
}

valid_os_version() {
    case "${1:-}" in
        ''|harvested|system_property) return 0 ;;
    esac
    printf '%s' "${1:-}" | grep -Eq '^[0-9]+(\.[0-9]+){0,2}$'
}

# ---------- OhMyKeymint 的 [trust] 字段格式 ----------
# 说明：这些以前一律走 valid_text 128 —— 把 "auto" 敲成 "aut" 也能存进去，而 OMK
#       读不懂时静默退回默认值，界面上完全看不出来（存进去了 ≠ 生效了）。收紧到
#       文档格式，校验不过就在屏幕上说清是哪个字段、接受什么。
valid_omk_date() {
    printf '%s' "${1:-}" | grep -Eq '^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$'
}
# auto | latest | YYYY-MM-DD
valid_omk_patch() {
    case "${1:-}" in auto|latest) return 0 ;; esac
    valid_omk_date "${1:-}"
}
# boot 额外收十进制 u32（OMK 在链路上给 HAL 的是数字，文档同时给了两种写法）
valid_omk_boot() {
    valid_omk_patch "${1:-}" && return 0
    printf '%s' "${1:-}" | grep -Eq '^[0-9]{1,10}$'
}
# auto | random | 64 位十六进制
valid_omk_hash() {
    case "${1:-}" in auto|random) return 0 ;; esac
    printf '%s' "${1:-}" | grep -Eq '^[0-9a-fA-F]{64}$'
}
# auto | 0..99（os_version 是 MMmmss 的编码值，不是年份）
valid_omk_os_version() {
    case "${1:-}" in auto) return 0 ;; esac
    printf '%s' "${1:-}" | grep -Eq '^([0-9]|[1-9][0-9])$'
}
# injector.toml 的 log_level 比 config.toml 多一个 warning 别名
valid_inj_log_level() {
    case "${1:-}" in off|error|warn|warning|info|debug|trace) return 0 ;; esac
    return 1
}

valid_keybox_name() {
    case "${1:-}" in
        ''|*[!A-Za-z0-9._-]*|*/*) return 1 ;;
        *.xml) return 0 ;;
    esac
    return 1
}

# 逗号分隔的包名列表 -> DENY_NORM；空列表合法
valid_deny_list() {
    local raw="${1:-}" p out=""

    case "$raw" in
        *"$NL"*|*"$TAB"*|*"$CR"*) return 1 ;;
    esac
    local oldifs="$IFS"
    IFS=','
    for p in $raw; do
        p=$(printf '%s' "$p" | tr -d ' \t')
        [ -n "$p" ] || continue
        is_pkg_name "$p" || { IFS="$oldifs"; return 1; }
        out="$out${out:+,}$p"
    done
    IFS="$oldifs"
    DENY_NORM="$out"
    return 0
}

# 解外层 payload 到 pairs 文件（key<TAB>value）
parse_payload() {
    local enc="${1:-}" out="$2" raw="$2.raw" line k v bcmd n=0

    [ -n "$enc" ] || { echo "参数为空" >&2; return 1; }
    [ "${#enc}" -le 131072 ] || { echo "配置过大" >&2; return 1; }
    bcmd=$(find_base64) || { echo "缺少 base64 命令" >&2; return 1; }
    printf '%s' "$enc" | $bcmd -d > "$raw" 2>/dev/null || { rm -f "$raw"; echo "payload 解码失败" >&2; return 1; }

    : > "$out"
    # 说明：`|| [ -n "$line" ]` 不能省。while read 在最后一行没有换行符时会直接
    #       结束循环，那一行就丢了 —— 而界面的 payload 是 join('\n') 拼的，本来
    #       就没有尾换行。实测（改两个字段、第二个故意放非法值）旧代码回
    #       saved=1 fields=1：最后一个字段既没保存、也没过校验，静默通过。
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        k="${line%%=*}"
        [ "$k" != "$line" ] || { rm -f "$raw" "$out"; echo "payload 行格式错误" >&2; return 1; }
        v=$(printf '%s' "${line#*=}" | $bcmd -d 2>/dev/null) || { rm -f "$raw" "$out"; echo "字段解码失败：$k" >&2; return 1; }
        case "$v" in
            *"$NL"*|*"$TAB"*|*"$CR"*) rm -f "$raw" "$out"; echo "字段含控制字符：$k" >&2; return 1 ;;
        esac
        printf '%s\t%s\n' "$k" "$v" >> "$out"
        n=$((n + 1))
    done < "$raw"
    rm -f "$raw"
    [ "$n" -gt 0 ] || { echo "没有字段" >&2; return 1; }
    return 0
}

# 说明：当前后端的 keybox 路径（TEESim 以 config 里的文件名为准）
backend_keybox_path() {
    local kb=""

    KEYBOX_PATH=""
    case "$KL_BACKEND" in
        teesim)
            if [ -f "$TEESIM_CONFIG" ] && [ -n "$AWK_CMD" ] && [ -f "${KL_PATCH%/*}/teesim_info.awk" ]; then
                kb=$($AWK_CMD -f "${KL_PATCH%/*}/teesim_info.awk" "$TEESIM_CONFIG" 2>/dev/null \
                     | sed -n 's/^default_keybox=//p')
            fi
            [ -n "$kb" ] || kb="keybox.xml"
            case "$kb" in /*) KEYBOX_PATH="$kb" ;; *) KEYBOX_PATH="$TEESIM_DIR/$kb" ;; esac
            ;;
        omk) KEYBOX_PATH="$OMK_DIR/keybox.xml" ;;
        *)   KEYBOX_PATH="$TSTORE_DIR/keybox.xml" ;;
    esac
}


# 说明：写完后让 OMK 自己重载对应组件
omk_restart() {
    [ -d "$OMK_STATE_DIR" ] || return 0
    : > "$OMK_STATE_DIR/restart.$1" 2>/dev/null
}

# ---------- 状态 ----------
# 说明：一次返回界面所需的全部状态；只读，不创建文件、不触发同步。
# 说明：列出「已装、有基线、但目标文件里没有」的包名，一行一个。界面用它把
#       「未生效」和「你手动删过」分开 —— 两者都不在目标列表里，但原因相反。
#       同步过一次之后，已装却不在文件里的就只可能是手动删除；不需要墓碑文件。
cmd_excluded() {
  detect_backend "$MODDIR"     # 基线路径是探测后端时才定的
  excluded_apps
}






# 用法：omk-save-config <payload_b64>
# 说明：OMK 的生效代价不是一句"重启 keymint"。上游文档（docs/CONFIGURATION.md:415-425）
#       把 [trust] 的四个补丁字段单列一档：**同一次保存里只动这四个**时，keymint 在运行中
#       整组热生效，已有的 TA 原地更新、在途操作与 per-boot 计数器都不丢；只要掺进任何
#       别的字段，就退回"重启 keymint"。以前这里无条件重启，等于每次改一个日期就把
#       用户在途的密钥操作打断一次。
# 用法：omk_apply_scope <提交的字段...>   → hot | restart
omk_apply_scope() {
    local k
    [ "$#" -gt 0 ] || { echo restart; return 0; }
    for k in "$@"; do
        case "$k" in
            trust_security_patch|trust_os_patchlevel|trust_vendor_patchlevel|trust_boot_patchlevel) ;;
            *) echo restart; return 0 ;;
        esac
    done
    echo hot
}

# 说明：vb_key / vb_hash 从 "random" 改成 "auto" 要**重启整机**（要重新读启动元数据），
#       光重启 keymint 不够。这条只能提示，绝不能替用户重启。
# 用法：omk_reboot_needed <旧 vb_key> <新 vb_key> <旧 vb_hash> <新 vb_hash>  → 0 = 需要重启整机
omk_reboot_needed() {
    [ "$1" = "random" ] && [ "$2" = "auto" ] && return 0
    [ "$3" = "random" ] && [ "$4" = "auto" ] && return 0
    return 1
}





# ---------- 后端能力补全（只读枚举 + 显式重载） ----------
# 说明：前三条只读各后端自己的文件，不改任何东西；第四条是写命令，但写的只是
#       一个"请重载"的触发文件。界面按 hasCmd 逐条揭示，所以命令层与界面不同版
#       时最坏是少一块内容，不会拿旧解析画新数据。

# 输出：每行「名字<TAB>keybox<TAB>mode<TAB>apps数<TAB>是否默认」，default 在首行。
# 为什么需要：上游 profiles 是「名字→配置」的表，一个 profile 自带 keybox、模式、
#       三档补丁级别与设备身份；写回路径以前只认 default，多 profile 这层在界面上
#       根本不存在。
cmd_teesim_profiles() {
    local ac
    detect_backend "$MODDIR"
    if [ "$KL_BACKEND" != "teesim" ]; then echo "当前后端不是 TEE Simulator" >&2; return 1; fi
    [ -f "$TEESIM_CONFIG" ] || { echo "配置不存在：$TEESIM_CONFIG" >&2; return 1; }
    ac="$AWK_CMD"; [ -n "$ac" ] || ac=$(find_awk)
    [ -n "$ac" ] || { echo "未找到 awk，读不了 profile 列表" >&2; return 1; }
    [ -f "${KL_PATCH%/*}/teesim_profiles.awk" ] || { echo "缺少 teesim_profiles.awk" >&2; return 1; }
    $ac -f "${KL_PATCH%/*}/teesim_profiles.awk" "$TEESIM_CONFIG"
}



# 输出：present=0|1，另有 status / category / service_error_code / tee_broken。
# tee_status 是 Tricky 自己写的探测结果 —— 它就是"这台机器为什么只能走 leaf hack"
# 的答案，以前界面没有任何一处把它露出来。
cmd_tee_status() {
    local f="$TSTORE_DIR/tee_status" k rest
    [ -f "$f" ] || { kv present 0; return 0; }
    kv present 1
    kv file "$f"
    # 上游写这个文件时**不留尾换行**（Config.kt:140-143 是四行一次写出），
    # 而 `while read` 在最后一行缺换行符时会直接结束循环 —— 丢的正好是最后一行
    # teeBroken，也就是"这台机器为什么只能走叶证书"的那个答案。
    # 真机验过：旧写法只读到三行，加 `|| [ -n "$k" ]` 才读到第四行。
    while IFS='=' read -r k rest || [ -n "$k" ]; do
        case "$k" in
            status)           kv status "$rest" ;;
            category)         kv category "$rest" ;;
            serviceErrorCode) kv service_error_code "$rest" ;;
            teeBroken)        kv tee_broken "$rest" ;;
        esac
    done < "$f"
}

# 输出：每行「范围<TAB>system<TAB>vendor<TAB>boot」，范围是 global 或包名。
# 按包块（`[包名]` 段）以前不读也不写：全局值改了不等于那个包生效了。
cmd_tricky_patches() {
    local f="$TSTORE_DIR/security_patch.txt" ac
    # KL_PATCH 由 use_backend 赋值，而每次调用都是新进程 —— 不像 save 那几条
    # 自己解析后端的话，这里拿到的是空路径（真机上表现成"缺少 tricky_patches.awk"，
    # 界面据此把补丁块画成"还没有这个段"，错得很安静）。
    detect_backend "$MODDIR"
    [ "$KL_BACKEND" = "tricky" ] || { echo "当前后端不是 Tricky Store" >&2; return 1; }
    [ -f "$f" ] || { echo "文件不存在：$f" >&2; return 1; }
    ac="$AWK_CMD"; [ -n "$ac" ] || ac=$(find_awk)
    [ -n "$ac" ] || { echo "未找到 awk，读不了补丁表" >&2; return 1; }
    [ -f "${KL_PATCH%/*}/tricky_patches.awk" ] || { echo "缺少 tricky_patches.awk" >&2; return 1; }
    $ac -f "${KL_PATCH%/*}/tricky_patches.awk" "$f"
}


# 输出：每行「字段<TAB>当前值<TAB>可编辑(1|0)<TAB>来源」。
# 为什么单独一条：overrides.json 是与 config.json 互斥的第二块可写面（安全等级、
# 版本、启动键哈希只能改这里；设备标识只能在 profile 里改），而可编辑性是
# 数据决定的 —— 启动键哈希只有守护进程自己那份是合成兜底值时才可改。
cmd_teesim_overrides() {
    local ac
    detect_backend "$MODDIR"
    if [ "$KL_BACKEND" != "teesim" ]; then echo "当前后端不是 TEE Simulator" >&2; return 1; fi
    ac="$AWK_CMD"; [ -n "$ac" ] || ac=$(find_awk)
    [ -n "$ac" ] || { echo "未找到 awk，读不了 overrides" >&2; return 1; }
    [ -f "${KL_PATCH%/*}/teesim_overrides.awk" ] || { echo "缺少 teesim_overrides.awk" >&2; return 1; }
    $ac -v ov="$TEESIM_DIR/overrides.json" -v ha="$TEESIM_DIR/harvested.json" \
        -f "${KL_PATCH%/*}/teesim_overrides.awk"
}

# 说明：overrides.json 的取值范围照抄上游的 validOverride（Harvester.kt:423-432）。
#   等级只认 0..2 —— 0=Software、1=TrustedEnvironment、2=StrongBox（Const.kt:75-77）。
#   **不是** KM1 那套 KEYSTORE=1 / TRUSTED_ENVIRONMENT=2 / STRONGBOX=3：写 3 上游会丢。
valid_ov_level() {
    local v="${1:-}"
    [ -z "$v" ] && return 0
    case "$v" in *[!0-9]*) return 1 ;; esac
    # 上游是 value.toIntOrNull() in 0..2 —— "01" 会解析成 1 被接受，
    # 所以这里按数值比，不按字面枚举（按字面就严于上游了）
    [ "$v" -le 2 ]
}
valid_ov_version() {
    local v="${1:-}"
    [ -z "$v" ] && return 0
    printf '%s' "$v" | grep -Eq '^[0-9]{1,6}$' || return 1
    [ "$v" -ge 1 ] && [ "$v" -le 100000 ]
}
# 启动键/哈希：可带 0x 前缀、去掉前缀后必须恰好 64 位十六进制，且不许全零
valid_ov_hex() {
    local v="${1:-}"
    [ -z "$v" ] && return 0
    case "$v" in 0x*) v="${v#0x}" ;; 0X*) v="${v#0X}" ;; esac
    printf '%s' "$v" | grep -Eq '^[0-9a-fA-F]{64}$' || return 1
    printf '%s' "$v" | grep -Eiq '^0+$' && return 1
    return 0
}


cmd_contract() {
  kv api "$KL_API"
  kv commands "$KL_COMMANDS"
}

# ---------- 目标条目元数据 ----------
# 说明：targets 输出的是「原样 token」（Tricky 的 pkg?/pkg!、TEESim 的 pkg@10
#       与 uid:10123）。界面要按基础包名判重、给条目挂模式/用户标签，所以这里
#       一次把 token、base、类型、细节都给它。
# 输出：token<TAB>base<TAB>kind<TAB>detail
#   tricky  kind = auto|leaf|generate
#   teesim  kind = plain|user|uid，detail = 用户号或 UID
#   omk     kind = plain
cmd_target_meta() {
    local ac

    detect_backend "$MODDIR"
    [ -f "$TARGET_FILE" ] || { echo "目标文件不存在：$TARGET_FILE" >&2; return 1; }
    ac="$AWK_CMD"
    [ -n "$ac" ] || ac=$(find_awk)
    [ -n "$ac" ] || return 1

    current_target_apps | $ac -v backend="$KL_BACKEND" '
        {
            tok = $0; b = tok; kind = "plain"; detail = ""
            if (backend == "tricky") {
                if (b ~ /\?$/) { kind = "leaf"; b = substr(b, 1, length(b) - 1) }
                else if (b ~ /!$/) { kind = "generate"; b = substr(b, 1, length(b) - 1) }
                else kind = "auto"
            } else if (backend == "teesim") {
                if (b ~ /^uid:/) { kind = "uid"; detail = substr(b, 5); b = "" }
                else if (b ~ /@[0-9]+$/) {
                    i = index(b, "@"); detail = substr(b, i + 1)
                    kind = "user"; b = substr(b, 1, i - 1)
                }
            }
            printf "%s\t%s\t%s\t%s\n", tok, b, kind, detail
        }'
}


# ---------- 后端配置摘要（只读） ----------
# 说明：三个后端各有一套配置，本模块只维护应用名单；这里把与运行相关的少量
#       字段摊开给「后端」页看，不写回任何后端配置文件。
cmd_backend_info() {
    local mdir="" keybox="" ver="" patch="" info="" n="" kb=""
    local kb_exists=0 kb_bytes="" kb_mtime="" kb_sha="" kb_list=""
    local omk_d1="" omk_d2="" omk_ks="" omk_pay_pid="" omk_pay_id=""
    local omk_d1_alive=0 omk_d2_alive=0 omk_injected=0

    detect_backend "$MODDIR"

    case "$KL_BACKEND" in
        teesim)
            mdir="$TEESIM_MODULE"
            keybox="$TEESIM_DIR/keybox.xml"
            if [ -f "$TEESIM_CONFIG" ] && [ -n "$AWK_CMD" ] && [ -f "${KL_PATCH%/*}/teesim_info.awk" ]; then
                info=$($AWK_CMD -f "${KL_PATCH%/*}/teesim_info.awk" "$TEESIM_CONFIG" 2>/dev/null)
                kb=$(printf '%s\n' "$info" | sed -n 's/^default_keybox=//p')
                [ -n "$kb" ] && case "$kb" in /*) keybox="$kb" ;; *) keybox="$TEESIM_DIR/$kb" ;; esac
            fi
            ;;
        omk)
            mdir="$OMK_MODULE"
            keybox="$OMK_DIR/keybox.xml"
            if [ -n "$AWK_CMD" ] && [ -f "${KL_PATCH%/*}/omk_info.awk" ]; then
                local inj cfg
                inj="$OMK_INJECTOR"; cfg="$OMK_DIR/config.toml"
                [ -f "$inj" ] || inj=/dev/null
                [ -f "$cfg" ] || cfg=/dev/null
                if [ -f "$OMK_INJECTOR" ] || [ -f "$OMK_DIR/config.toml" ]; then
                    info=$($AWK_CMD -v injector="$OMK_INJECTOR" -v config="$OMK_DIR/config.toml" \
                        -f "${KL_PATCH%/*}/omk_info.awk" "$inj" "$cfg" 2>/dev/null)
                fi
            fi
            ;;
        *)
            mdir="$TRICKY_MODULE"
            keybox="$TSTORE_DIR/keybox.xml"
            patch="$TSTORE_DIR/security_patch.txt"
            kv patch_file "$patch"
            if [ -f "$patch" ]; then
                kv patch_exists 1
                if [ -n "$AWK_CMD" ] && [ -f "${KL_PATCH%/*}/tricky_info.awk" ]; then
                    $AWK_CMD -f "${KL_PATCH%/*}/tricky_info.awk" "$patch" 2>/dev/null
                fi
            else
                kv patch_exists 0
            fi
            ;;
    esac

    # OMK 1.2.5 起 keymint 与 injector 是两个独立 daemon，keystore2 由 injector
    # 注入。这两条只读状态由本模块自己看（OMK 没有自报），pid 文件里的 pid 还要
    # 核对 cmdline —— PID 会被复用，单看 kill -0 会把陌生进程当成 daemon。
    if [ "$KL_BACKEND" = "omk" ]; then
        # pid 文件用内置 read 取（$(cat …) 是一次子壳，真机约 40ms；这两个文件每次
        # backend-info 都要读）
        omk_d1=""; omk_d2=""
        [ -f "$OMK_STATE_DIR/keymint-daemon.pid" ] && \
            { IFS= read -r omk_d1 < "$OMK_STATE_DIR/keymint-daemon.pid" 2>/dev/null || :; }
        [ -f "$OMK_STATE_DIR/injector-daemon.pid" ] && \
            { IFS= read -r omk_d2 < "$OMK_STATE_DIR/injector-daemon.pid" 2>/dev/null || :; }
        if [ -n "$omk_d1" ] && kill -0 "$omk_d1" 2>/dev/null \
           && [ "$(tr '\0' '\n' < "/proc/$omk_d1/cmdline" 2>/dev/null | sed -n '2p')" = "$OMK_MODULE/daemon" ]; then
            omk_d1_alive=1
        fi
        if [ -n "$omk_d2" ] && kill -0 "$omk_d2" 2>/dev/null \
           && [ "$(tr '\0' '\n' < "/proc/$omk_d2/cmdline" 2>/dev/null | sed -n '2p')" = "$OMK_MODULE/daemon-injector" ]; then
            omk_d2_alive=1
        fi
        # pidof 可能给多个 pid，取第一个 —— 用 set -- 拿，省掉管道里的 awk
        omk_ks=""; set -- $(pidof keystore2 2>/dev/null); omk_ks="${1:-}"
        if [ -n "$omk_ks" ] && [ -f "$OMK_STATE_DIR/injector.payload" ]; then
            read -r omk_pay_pid omk_pay_id < "$OMK_STATE_DIR/injector.payload" 2>/dev/null
            [ "$omk_pay_pid" = "$omk_ks" ] && [ -n "$omk_pay_id" ] && omk_injected=1
        fi
        kv omk_keymint_daemon "$omk_d1"
        kv omk_keymint_alive "$omk_d1_alive"
        kv omk_injector_daemon "$omk_d2"
        kv omk_injector_alive "$omk_d2_alive"
        kv omk_keystore_pid "$omk_ks"
        kv omk_keystore_injected "$omk_injected"
    fi

    kv backend "$KL_BACKEND"
    backend_name_into; kv backend_name "$KL_BACKEND_NAME"
    kv module_dir "$mdir"

    if [ -f "$mdir/module.prop" ]; then
        # 注意：$mdir 是**当前后端**的模块目录（OMK/Tricky/TEESim 自己的），不是本模块，
        #      所以这里不能用 mod_prop（那个读的是 $PROP_FILE = 我们自己的 module.prop）。
        ver=$(sed -n 's/^version=//p' "$mdir/module.prop" 2>/dev/null | head -n 1)
    fi
    kv module_version "$ver"

    if [ -f "$TARGET_FILE" ]; then
        n=$(current_target_apps 2>/dev/null | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
    fi
    kv target_file "$TARGET_FILE"
    kv target_entries "${n:-0}"

    if [ -n "$keybox" ] && [ -f "$keybox" ]; then
        kb_exists=1
        kb_bytes=$(wc -c < "$keybox" 2>/dev/null | tr -d ' ')
        kb_mtime=$(stat -c %Y "$keybox" 2>/dev/null)
    fi
    kv keybox_file "$keybox"
    kv keybox_exists "$kb_exists"
    kv keybox_bytes "$kb_bytes"
    kv keybox_mtime "$kb_mtime"

    # 哈希给界面认「换没换过」；sha256sum 不在就退回 md5sum（两者至少有一个）
    kb_sha=""
    if [ "$kb_exists" = 1 ]; then
        if command -v sha256sum >/dev/null 2>&1; then
            kb_sha=$(sha256sum "$keybox" 2>/dev/null | cut -d' ' -f1)
            kv keybox_hash_algo sha256
        elif command -v md5sum >/dev/null 2>&1; then
            kb_sha=$(md5sum "$keybox" 2>/dev/null | cut -d' ' -f1)
            kv keybox_hash_algo md5
        fi
    fi
    kv keybox_hash "$kb_sha"

    # TEE Simulator 允许在目录里放多份 keybox，config 里选文件名
    if [ "$KL_BACKEND" = "teesim" ]; then
        kb_list=""
        for f in "$TEESIM_DIR"/*.xml; do
            [ -f "$f" ] || continue
            n="${f##*/}"
            kb_list="$kb_list${kb_list:+,}$n"
        done
        kv keybox_files "$kb_list"
    fi

    # 解析器输出的字段（Tricky 的 patch_*、TEESim 的 default_*、OMK 的 trust_*）
    [ -n "$info" ] && printf '%s\n' "$info"
    return 0
}

cmd_status() {
    local desc state masking ino p alive lines bytes mtime bname conflict
    local teesim_st tricky_st omk_st target_exists target_writable

    detect_backend "$MODDIR"

    # 状态取自 description —— 它是模块对外表达运行结果的唯一通道
    mod_prop description
    desc="$MOD_PROP_VALUE"
    case "$desc" in
        ⛔*) state=stopped ;;
        ⚠️*) state=failed ;;
        ✅*) state=ok ;;
        *)   state=unknown ;;
    esac

    # 三态与 OMK 那一位：conflict 是三家里数出来的，状态表也必须是三家
    backend_state "$TEESIM_MODULE"; teesim_st="$BACKEND_STATE_VALUE"
    backend_state "$TRICKY_MODULE"; tricky_st="$BACKEND_STATE_VALUE"
    backend_state "$OMK_MODULE";    omk_st="$BACKEND_STATE_VALUE"

    target_exists=0; target_writable=0
    if [ -f "$TARGET_FILE" ]; then
        target_exists=1
        test -w "$TARGET_FILE" && target_writable=1
    elif [ -d "$KL_DIR" ] && test -w "$KL_DIR"; then
        target_writable=1
    fi

    # 生效条目数、第三方应用数都不在这里算：
    # 它们各自要跑 awk(约 330ms) / pm list(约 200ms) / grep(约 60ms)，而界面本来就要
    # 取 targets / apps 两条完整列表，数量由那些列表直接数出来即可。
    # 在这里再算一遍只会让每次刷新多等一倍时间，且两份数字可能互相对不上。
    mtime=""
    [ -f "$TARGET_FILE" ] && mtime=$(stat -c %Y "$TARGET_FILE" 2>/dev/null)

    conflict=0
    backends_conflict && conflict=1
    backend_name_into; bname="$KL_BACKEND_NAME"

    kv state "$state"
    kv description "$desc"
    mod_prop id;    kv mod_id "$MOD_PROP_VALUE"
    mod_prop version; kv mod_version "$MOD_PROP_VALUE"
    kv backend "$KL_BACKEND"
    kv backend_name "$bname"
    kv conflict "$conflict"
    kv teesim_state "$teesim_st"
    kv tricky_state "$tricky_st"
    kv omk_state "$omk_st"
    kv data_dir "$KL_DIR"
    kv target_file "$TARGET_FILE"
    kv target_exists "$target_exists"
    kv target_writable "$target_writable"
    kv target_mtime "$mtime"

    if props_disabled; then masking=off; else masking=on; fi
    kv props_masking "$masking"
    kv props_off_file "$KL_PROPS_OFF"

    # 守护进程：pids 文件里仍存活的进程数
    alive=0; p=""
    if [ -f "${KL_DIR}/.kl_daemon_pids.list" ]; then
        while read -r p; do
            [ -n "$p" ] && kill -0 "$p" 2>/dev/null && alive=$((alive + 1))
        done < "${KL_DIR}/.kl_daemon_pids.list"
    fi
    kv daemon_alive "$alive"

    # 行数与字节数一次 wc 拿到（-lc 的输出顺序为「行 字节」）
    lines=""; bytes=""
    if [ -f "$KL_LOG" ]; then
        set -- $(wc -lc < "$KL_LOG" 2>/dev/null)
        lines="${1:-}"; bytes="${2:-}"
    fi
    kv log_file "$KL_LOG"
    kv log_lines "${lines:-}"
    kv log_bytes "${bytes:-}"
    return 0
}

# ---------- 环境与设备 ----------
# 说明：这些探针每次都要起外部命令（busybox --help、getprop 全量等），但它们只在
#       安装模块/换工具/换设备时才变，所以与 status 分开 —— 界面每次打开只问一次，
#       省下 status 里约 400ms。
cmd_env() {
    local cache="$KL_ENV_CACHE" cache_ok=0 cache_dirty=0
    local ckey ckey_cached v k
    local resetprop_v awk_v base64_v base64_cmd_v ino_mode_v ino_cmd_v root_v sh_v
    local dev_v brand_v android_v sdk_v build_v vb_v sb_dp_v
    local frro_path_v="" frro_mtime_v="" frro_b64_v=""
    local ino uimode hex seed wc sbh dens frro mtime enc tmp

    # cache_key：模块更新（module.prop 的 version）或系统 OTA（build.prop mtime）时失效。
    # 这里以前用 module.prop 的 **mtime** —— 但每次同步都会 set_module_desc 重写这一行
    # 描述（backend.sh:616），mtime 跟着变，缓存于是每同步一次就作废一次，等于白设。
    # version 只在刷机时变，正是"工具/机型可能变了"的那个信号。
    mod_prop version
    ckey="v1|$MODDIR|${MOD_PROP_VALUE:-none}|$(stat -c %Y /system/build.prop 2>/dev/null)"

    if [ -f "$cache" ]; then
        while IFS="$TAB" read -r k v; do
            case "$k" in
                v1) ckey_cached="$v" ;;
                resetprop) resetprop_v="$v" ;;
                awk) awk_v="$v" ;;
                base64) base64_v="$v" ;;
                base64_cmd) base64_cmd_v="$v" ;;
                ino_mode) ino_mode_v="$v" ;;
                ino_cmd) ino_cmd_v="$v" ;;
                root_user) root_v="$v" ;;
                webui_sh) sh_v="$v" ;;
                device) dev_v="$v" ;;
                brand) brand_v="$v" ;;
                android) android_v="$v" ;;
                sdk) sdk_v="$v" ;;
                build_type) build_v="$v" ;;
                vbstate) vb_v="$v" ;;
                statusbar_dp) sb_dp_v="$v" ;;
                frro_path) frro_path_v="$v" ;;
                frro_mtime) frro_mtime_v="$v" ;;
                frro_b64) frro_b64_v="$v" ;;
            esac
        done < "$cache"
        [ -n "$ckey_cached" ] && [ "$ckey_cached" = "$ckey" ] && cache_ok=1
    fi

    if [ "$cache_ok" = 0 ]; then
        resetprop_v=$(command -v resetprop >/dev/null 2>&1 && echo 1 || echo 0)
        awk_v=$(find_awk >/dev/null 2>&1 && echo 1 || echo 0)
        base64_cmd_v=$(find_base64 2>/dev/null)
        [ -n "$base64_cmd_v" ] && base64_v=1 || base64_v=0
        ino=$(find_inotify_cmd)
        if [ -n "$ino" ]; then
            ino_mode_v="${ino%%:*}"
            ino_cmd_v="${ino#*:}"
        else
            ino_mode_v=none
            ino_cmd_v=""
        fi
        root_v=$(id -u)
        sh_v="$MODDIR/webui.sh"
        prop_now ro.product.model;             dev_v="$PROP_NOW"
        prop_now ro.product.brand;             brand_v="$PROP_NOW"
        prop_now ro.build.version.release;     android_v="$PROP_NOW"
        prop_now ro.build.version.sdk;         sdk_v="$PROP_NOW"
        prop_now ro.build.type;                build_v="$PROP_NOW"
        prop_now ro.boot.verifiedbootstate;    vb_v="$PROP_NOW"
        sb_dp_v=""
        sbh=$(dumpsys window displays 2>/dev/null | sed -n 's/.*type=statusBars frame=\[[0-9]*,[0-9]*\]\[[0-9]*,\([0-9]*\)\].*/\1/p' | head -n 1)
        dens=$(wm density 2>/dev/null | sed -n 's/^Physical density: *\([0-9][0-9]*\).*/\1/p')
        [ -n "$dens" ] || dens=$(getprop ro.sf.lcd_density)
        case "$sbh" in ''|*[!0-9]*) sbh=0 ;; esac
        case "$dens" in ''|*[!0-9]*) dens=0 ;; esac
        if [ "$sbh" -gt 0 ] && [ "$dens" -gt 0 ]; then
            sb_dp_v=$(( (sbh * 160 + dens - 1) / dens ))
        fi
        cache_dirty=1
    fi

    # 深浅模式会随系统开关变化，每次都现取（约 50ms）
    uimode=$(dumpsys uimode 2>/dev/null | grep -m2 -o -e 'mComputedNightMode=[a-z]*' -e 'mCurUiMode=0x[0-9a-f]*')
    case "$uimode" in
        *mComputedNightMode=true*)  kv sys_dark 1; kv sys_dark_src mComputedNightMode ;;
        *mComputedNightMode=false*) kv sys_dark 0; kv sys_dark_src mComputedNightMode ;;
        *)
            hex="${uimode#*mCurUiMode=0x}"
            hex="${hex%%[!0-9a-fA-F]*}"
            if [ -n "$hex" ]; then
                if [ $(( 0x$hex & 32 )) -ne 0 ]; then kv sys_dark 1; else kv sys_dark 0; fi
                kv sys_dark_src mCurUiMode
            else
                kv sys_dark ""
                kv sys_dark_src none
            fi
            ;;
    esac

    # 强调色：SystemUI 的 FRRO 是权威来源；文件/mtime 不变就复用缓存里的 base64
    frro=$(ls -t /data/resource-cache/com.android.systemui-accent-*.frro 2>/dev/null | head -n 1)
    [ -n "$frro" ] || frro=$(ls -t /data/resource-cache/com.android.systemui-dynamic-*.frro 2>/dev/null | head -n 1)
    mtime=""
    [ -n "$frro" ] && mtime=$(stat -c %Y "$frro" 2>/dev/null)
    if [ -n "$frro" ] && [ "$frro" = "$frro_path_v" ] && [ "$mtime" = "$frro_mtime_v" ] && [ -n "$frro_b64_v" ]; then
        enc="$frro_b64_v"
    else
        enc=""
        if [ -n "$frro" ] && [ -r "$frro" ]; then
            [ -n "$base64_cmd_v" ] || base64_cmd_v=$(find_base64 2>/dev/null)
            if [ -n "$base64_cmd_v" ]; then
                enc=$($base64_cmd_v < "$frro" 2>/dev/null | tr -d '\r\n')
            fi
        fi
        if [ -n "$enc" ]; then
            frro_path_v="$frro"; frro_mtime_v="$mtime"; frro_b64_v="$enc"; cache_dirty=1
        elif [ -z "$frro" ] && [ -n "$frro_path_v" ]; then
            frro_path_v=""; frro_mtime_v=""; frro_b64_v=""; cache_dirty=1
        fi
    fi

    if [ -n "$frro_b64_v" ]; then
        kv sys_frro "$frro_b64_v"
        kv sys_frro_src "$frro_path_v"
    fi
    # seed 这条永远读（settings 取一个键很便宜）：FRRO 在的时候它是"我们的解析器
    # 认不出这张 overlay"的唯一退路 —— 以前有 FRRO 就把 sys_seed_raw 写成空，等于
    # 把退路一起省掉了。慢的是 dumpsys wallpaper，只在没有 FRRO 时才跑。
    seed=$(settings get secure theme_custom_color 2>/dev/null)
    case "$seed" in ''|null|null*) seed="" ;; esac
    if [ -n "$seed" ]; then
        kv sys_seed_raw "$seed"
        kv sys_seed_src theme_custom_color
    elif [ -n "$frro_b64_v" ]; then
        kv sys_seed_raw ""
        kv sys_seed_src none
    else
        wc=$(dumpsys wallpaper 2>/dev/null | grep -m1 -o 'colorValue0=[0-9-]*' | cut -d= -f2)
        if [ -n "$wc" ]; then
            kv sys_seed_raw "$wc"
            kv sys_seed_src wallpaper_color0
        else
            kv sys_seed_raw ""
            kv sys_seed_src none
        fi
    fi

    kv resetprop "$resetprop_v"
    kv awk "$awk_v"
    kv base64 "$base64_v"
    kv inotify_mode "$ino_mode_v"
    kv inotify_cmd "$ino_cmd_v"
    kv root_user "$root_v"
    kv webui_sh "$sh_v"
    kv device "$dev_v"
    kv brand "$brand_v"
    kv android "$android_v"
    kv sdk "$sdk_v"
    kv build_type "$build_v"
    kv vbstate "$vb_v"
    [ -n "$sb_dp_v" ] && kv sys_statusbar_dp "$sb_dp_v"

    # 首次 / 失效 / 换主题时才落盘；以后每次打开只读缓存 + 现取深浅
    if [ "$cache_dirty" = 1 ] && [ -d "${cache%/*}" ] && [ -w "${cache%/*}" ]; then
        tmp="${cache}.tmp.$$"
        # 整块攒成一个字符串、一次交出去：以前是 19 个 printf，而这个 shell 里
        # printf 是外部命令（/system/bin/printf）—— 落一次盘白付 19 次 fork。
        cb="v1${TAB}${ckey}"
        cb="${cb}${NL}resetprop${TAB}${resetprop_v}"
        cb="${cb}${NL}awk${TAB}${awk_v}"
        cb="${cb}${NL}base64${TAB}${base64_v}"
        cb="${cb}${NL}base64_cmd${TAB}${base64_cmd_v}"
        cb="${cb}${NL}ino_mode${TAB}${ino_mode_v}"
        cb="${cb}${NL}ino_cmd${TAB}${ino_cmd_v}"
        cb="${cb}${NL}root_user${TAB}${root_v}"
        cb="${cb}${NL}webui_sh${TAB}${sh_v}"
        cb="${cb}${NL}device${TAB}${dev_v}"
        cb="${cb}${NL}brand${TAB}${brand_v}"
        cb="${cb}${NL}android${TAB}${android_v}"
        cb="${cb}${NL}sdk${TAB}${sdk_v}"
        cb="${cb}${NL}build_type${TAB}${build_v}"
        cb="${cb}${NL}vbstate${TAB}${vb_v}"
        cb="${cb}${NL}statusbar_dp${TAB}${sb_dp_v}"
        cb="${cb}${NL}frro_path${TAB}${frro_path_v}"
        cb="${cb}${NL}frro_mtime${TAB}${frro_mtime_v}"
        cb="${cb}${NL}frro_b64${TAB}${frro_b64_v}"
        if print -r -- "$cb" > "$tmp" 2>/dev/null; then :; else printf '%s\n' "$cb" > "$tmp" 2>/dev/null; fi
        chmod 600 "$tmp" 2>/dev/null && mv -f "$tmp" "$cache" 2>/dev/null
        rm -f "$tmp" 2>/dev/null
    fi
    return 0
}

# ---------- 当前生效列表 ----------
cmd_targets() {
    detect_backend "$MODDIR"
    [ -f "$TARGET_FILE" ] || { echo "目标文件不存在：$TARGET_FILE" >&2; return 1; }
    # 读取逻辑集中在 current_target_apps：三个后端的格式各自处理，注释在
    # Tricky 的逐行文件里剥掉；这里不再各写一份（以前 OMK 会整份 TOML 吐出来）。
    current_target_apps
}

# ---------- 已安装第三方应用 ----------
cmd_apps() {
    (cmd package list packages -3 --user all 2>/dev/null || pm list packages -3 2>/dev/null) \
        | sed -n 's/^package://p' | sed 's/\[[0-9]*\]$//' | sort -u
}

# ---------- 日志 ----------
cmd_log() {
    local n

    n=$(clamp_int "$ARG" 60 1 400)
    if [ -f "$KL_LOG" ]; then
        tail -n "$n" "$KL_LOG" 2>/dev/null
        return 0
    fi
    # 缓冲不存在时回退 logcat（重启即清空，仅作兜底）
    logcat -d -s KeyLens 2>/dev/null | tail -n "$n"
}


# ---------- 属性 ----------
# 说明：期望值表来自 lib/props.sh，与 apply_resetprop 同源；当前值取自属性快照。
cmd_props() {
    local name expected needle replacement cur st

    while read -r name expected; do
        [ -n "$name" ] || continue
        prop_now "$name"; cur="$PROP_NOW"
        if [ -z "$cur" ]; then st=missing
        elif [ "$cur" = "$expected" ]; then st=ok
        else st=diff
        fi
        tsv "$name" "$cur" "$expected" "$st"
    done <<PAIRS
$(props_expect_pairs)
PAIRS

    while read -r name needle replacement; do
        [ -n "$name" ] || continue
        prop_now "$name"; cur="$PROP_NOW"
        case "$cur" in
            '')          st=missing ;;
            *"$needle"*) st=diff ;;
            *)           st=ok ;;
        esac
        tsv "$name" "$cur" "不含 $needle（则改写为 $replacement）" "$st"
    done <<RULES
$(props_expect_rules)
RULES
}

# ---------- Verified Boot 哈希（ro.boot.vbmeta.digest） ----------
# 说明：这是修复项，不属于上面的伪装开关：只要配置了，开关关着也应用。
#       值由用户从 KeyAttestation 等可信来源取到后填进来；只接受 64/128 位
#       十六进制（sha256/sha512），避免把错串写进属性。
cmd_boot_hash() {
    local raw="" current status

    [ -f "$KL_BOOT_HASH" ] && raw=$(tr -d '[:space:]' < "$KL_BOOT_HASH" 2>/dev/null | tr 'A-F' 'a-f')
    prop_now ro.boot.vbmeta.digest; current="$PROP_NOW"
    if [ -z "$raw" ]; then
        status=unset
    elif ! boot_hash_valid "$raw"; then
        status=invalid
    elif [ "$current" = "$raw" ]; then
        status=ok
    else
        status=mismatch
    fi
    kv configured "$raw"
    kv current "$current"
    kv status "$status"
}





# ---------- 应用图标与显示名 ----------
# 数据源是桌面自己的图标缓存（Launcher3 系的 app_icons.db）：里面存的就是真 PNG
# 与显示名。设备上既没有 aapt 也没有 ImageMagick，从 APK 里抠资源这条路走不通，
# 而缓存是现成的、且正是屏幕上那张图。
#
# 为什么落文件而不是 base64 回传：实测平均一张 25KB、最大 98KB，
# base64 后约 35KB/张，几十张就是几 MB 要从 root shell 里穿过一次 exec。
# PNG 写进 webroot/icons/ 由界面按相对路径引用，同一个 handler 既发 index.html
# 也发兄弟文件，浏览器还会自己缓存。
#
# 为什么一次 sqlite3 调用处理整批：实测单次查询约 44ms（主要是 fork），
# 120 个包逐个查要 5 秒以上；一条 GROUP BY 一次跑完约 0.3 秒。
#
# 用法：sh webui.sh icons <pkg>,<pkg>,...
# 输出：「包名<TAB>显示名<TAB>icons/<包名>.png」逐行；缓存不可用时输出空并回 0
cmd_icons() {
    local db dir sql chain p out

    [ -n "$ARG" ] || return 0

    db=""
    for p in /data/data/com.android.launcher3/databases/app_icons.db \
             /data/data/com.google.android.apps.nexuslauncher/databases/app_icons.db; do
        [ -f "$p" ] && { db="$p"; break; }
    done
    if [ -z "$db" ]; then
        db=$(ls -d /data/data/*/databases/app_icons.db 2>/dev/null | head -n 1)
    fi
    [ -f "$db" ] || { echo "未找到桌面图标缓存 app_icons.db" >&2; return 0; }
    command -v sqlite3 >/dev/null 2>&1 || { echo "未找到 sqlite3，无法读图标缓存" >&2; return 0; }

    dir="$MODDIR/webroot/$ICONS_SUBDIR"
    mkdir -p "$dir" 2>/dev/null || { echo "无法创建 $dir" >&2; return 1; }

    # 包名逐个校验后才允许进 SQL：只留 Android 包名字符集，并挡掉 "." 与 ".."
    # （它们会变成文件名，"../x" 就能写到目录外面去）
    chain=""
    want=""
    out="$ARG"
    while [ -n "$out" ]; do
        p="${out%%,*}"
        [ "$p" = "$out" ] && out="" || out="${out#*,}"
        case "$p" in
            [A-Za-z]*) ;;
            *) continue ;;
        esac
        case "$p" in
            *[!A-Za-z0-9._-]*|*..*|*/*) continue ;;
        esac
        want="$want $p"
        chain="${chain:+$chain or }componentName like '$p/%'"
    done
    [ -n "$chain" ] || return 0

    # 一个包在缓存里往往有多行：应用自己的启动 activity、每个快捷方式、每个微件都各存一张。
    # 只按"组件名最短"挑会选中快捷方式（实测 com.termux 会拿到 New session 而不是 Termux，
    # com.MobileTicket 会拿到 本人车票 而不是 铁路12306）。排序键改成三级：
    #   类名以包名开头（真 activity）→ 类名带点（也是真 activity）→ 都不是（快捷方式/微件）
    # 同级再按组件名长度。快捷方式的类名是 new_session、1、VIEW_MY_DOWNLOADS 这种没有点的。
    # 整行由 SQL 拼成单一列输出，避免 list 模式的分隔符与转义问题；
    # 显示名里的 TAB / 换行就地换成空格，不然会撑坏逐行解析。
    # 内层不能先 group by —— 那样 rank 还没参与选择就被折叠成任意一行（踩过一次）。
    sql="select p || char(9) || l || char(9) || 'icons/' || p || '.png' from ("
    sql="$sql select p, min(rank) r, l, writefile('$dir/' || p || '.png', ic) w from ("
    sql="$sql select substr(componentName, 1, instr(componentName, '/') - 1) p,"
    sql="$sql (case when instr(substr(componentName, instr(componentName, '/') + 1), '.') = 0 then 900000"
    sql="$sql when substr(componentName, instr(componentName, '/') + 1) like"
    sql="$sql substr(componentName, 1, instr(componentName, '/') - 1) || '.%' then 0 else 100000 end)"
    sql="$sql + length(componentName) rank,"
    sql="$sql replace(replace(label, char(9), ' '), char(10), ' ') l, icon ic"
    sql="$sql from icons where componentName not like '%#%' and ($chain)"
    sql="$sql ) group by p ) where w > 0;"

    # ── 快路：桌面库没更新过 + 请求的包都在缓存里（图标仍在盘上）就直接回缓存 ──
    # 为什么需要：冷路要跑一次 sqlite（重写全部 PNG，约 0.4s）再加一次 app_process
    # （ART 启动约 1.5s，用来补没有启动器入口的那几个）。界面每次打开都会重新问一遍
    # 图标，如果每次都走冷路，开一页就白付 2 秒。
    cache="$dir/index.tsv"
    dbm=$(stat -c %Y "$db" 2>/dev/null)
    if [ -f "$cache" ] && [ -n "$dbm" ] && [ "$dbm" = "$(cat "$dir/.dbmtime" 2>/dev/null)" ]; then
        hit=$(printf '%s\n' $want | ${AWK_CMD:-awk} -v c="$cache" '
            BEGIN { while ((getline l < c) > 0) { split(l, a, "\t"); m[a[1]] = l } }
            ($1 in m) { print m[$1] }')
        hitp=" $(printf '%s\n' "$hit" | cut -f1 | tr '\n' ' ') "
        nop=" $(printf '%s\n' "$hit" | ${AWK_CMD:-awk} -F'\t' '$3 == "" { print $1 }' | tr '\n' ' ') "
        ok=1
        for p in $want; do
            case "$hitp" in *" $p "*) ;; *) ok=0; break ;; esac
            case "$nop" in *" $p "*) continue ;; esac      # 本来就没有图标的，不要求 PNG
            [ -f "$dir/$p.png" ] || { ok=0; break; }
        done
        if [ "$ok" = 1 ] && [ -n "$hit" ]; then
            printf '%s\n' "$hit"
            return 0
        fi
    fi

    # ── 冷路：桌面库 ──
    rows=$(sqlite3 "$db" "$sql" 2>/dev/null)
    [ -n "$rows" ] && printf '%s\n' "$rows"

    # ── 冷路：桌面缓存里没有的，用 PackageManager 补 ──────────────
    # 桌面缓存只有**有启动器入口**的应用：GMS / GSF / WebView / AR Core 这类
    # 后台组件在里面一行都没有，界面只能退成首字块。它们的图标在 APK 里，而
    # Google 的包资源名被混淆过（WebView 的 base.apk 里是 res/j_ 这种名字），
    # 按文件名抠图不可行、解析 resources.arsc 又不划算。所以带一个小 dex
    # （源与编译命令在 tools/icondump/），在 app_process 里调
    # PackageManager.loadIcon —— 顺带拿到显示名，自适应图标也由系统渲染好。
    # 只补"缺的"、一次最多 60 个：实测 12 个包约 2s，其中约 1.5s 是 ART 启动。
    dex="$MODDIR/lib/icondump.dex"
    res2=""
    if [ -n "$want" ] && [ -f "$dex" ] && command -v app_process >/dev/null 2>&1; then
        have=" $(printf '%s\n' "$rows" | cut -f1 | tr '\n' ' ') "
        miss=""
        mn=0
        for p in $want; do
            case "$have" in *" $p "*) continue ;; esac
            miss="$miss,$p"
            mn=$((mn + 1))
            [ "$mn" -ge 60 ] && break
        done
        miss="${miss#,}"
        if [ -n "$miss" ]; then
            res2=$(app_process -Djava.class.path="$dex" /system/bin IconDump \
                "$miss" "$dir" 192 2>/dev/null)
            [ -n "$res2" ] && printf '%s\n' "$res2"
        fi
    fi

    # ── 落缓存：请求了什么、拿到什么 ──
    # 没有图标的也记一行（第三列为空），否则它们每次都会逼着重跑 app_process，
    # 白付一次 ART 启动。db 的 mtime 当失效判据：桌面缓存一更新，整份重来。
    if [ -n "$dbm" ]; then
        printf '%s\n%s\n' "$rows" "$res2" | ${AWK_CMD:-awk} -F'\t' -v want="$want" '
            NF >= 2 && !seen[$1]++ { print; have[$1] = 1 }
            END { n = split(want, w, " "); for (i = 1; i <= n; i++)
                  if (w[i] != "" && !(w[i] in have)) print w[i] "\t\t" }
        ' > "$cache" 2>/dev/null
        printf '%s\n' "$dbm" > "$dir/.dbmtime" 2>/dev/null
    fi

    # 界面经 WebView 读这些文件：writefile 建的默认是 666，收成 644 并把上下文
    # 对齐模块内其它文件
    chmod 644 "$dir"/*.png >/dev/null 2>&1
    chmod 644 "$dir/index.tsv" "$dir/.dbmtime" >/dev/null 2>&1
    chmod 755 "$dir" >/dev/null 2>&1
    chcon -R u:object_r:system_file:s0 "$dir" >/dev/null 2>&1
    return 0
}

cmd_help() {
    cat <<EOF
用法：sh webui.sh <命令> [参数]
  status                 全部运行状态（key=value）
  env                    环境能力（resetprop / awk / base64 / inotify）
  targets                当前生效的应用列表（保留 pkg? / pkg! / pkg@用户 / uid: 原样）
  target-meta            目标条目元数据（token<TAB>base<TAB>kind<TAB>detail）
  apps                   已安装的第三方应用
  icons <包名,...>       从桌面图标缓存导出 PNG 与显示名（包名<TAB>显示名<TAB>相对路径）
  log <行数>             日志缓冲末尾内容
  clear-log              清空日志缓冲
  props                  属性名/当前值/期望值/状态（TAB 分隔）
  props-apply            立刻按期望表写一次属性
  props-on|props-off     开关开机属性伪装
  boot-hash              读取 Verified Boot 哈希配置与当前 digest
  props-boot-hash <值|-> 保存并立即应用 verifiedBootHash（- 清除）
  restore-app <包名>     把未纳入或已排除的应用加入目标名单
  restore-apps <包名,...> 批量加入（逗号分隔；只写一次目标文件）
  remove-apps <包名,...> 批量移出（逗号分隔；只写一次；至少保留一条）
  set-mode <包名> <模式>  Tricky 专用：auto / leaf / generate
  backend-info           当前后端的配置摘要
  teesim-profiles        TEE Simulator：列出所有 profile（名字/关键/模式/条目数/是否默认）
  tee-status             Tricky：读它自己写的 TEE 探测结果（present/status/teeBroken…）
  teesim-overrides       TEE Simulator：读 overrides.json（安全等级/版本/启动键哈希，含各项可否编辑）
  tricky-patches         Tricky：列出 security_patch.txt 的全局与按包补丁块
  omk-restart <范围>     OhMyKeymint：触发重载，范围 = keymint | injector | all
  teesim-save <b64>      TEE Simulator default profile 字段（payload）
  omk-save-injector <b64> OhMyKeymint injector.toml 字段（payload）
  omk-save-config <b64>  OhMyKeymint config.toml 字段（payload）
  tricky-save-patch <b64> Tricky security_patch.txt 全局值（payload）
  tricky-drop-patch <包名> 删掉 Tricky security_patch.txt 里的 [包名] 段
  teesim-profile-new <名字> 复制 default 新建一份 TEESim profile
  teesim-profile-del <名字> 删除一个 TEESim profile（default 不可删）
  keybox-save <b64>      替换当前后端的 keybox.xml（base64 XML）
  sync                   立即同步一次应用列表
  contract               自报命令层契约号与命令清单
  excluded               列出被人为排除（手动删除）的包名
EOF
}

# ---------- 写命令的实现按需加载 ----------
# 说明：写命令的实现有 949 行 / 42.8KB，原来占这份脚本的四成。界面读 status / env /
#       backend-info 时一行都用不到，却每次都要付"读 + lex + 建函数定义"的几十毫秒
#       （现量对照：同样字节数全改成 `:` 空操作 62ms，真脚本 142ms）。所以把它们搬进
#       lib/write.sh，只有命令名命中下面这张表才 source 进来。
#       这张表与界面侧 bridge.js 的 WRITE_CMDS 必须一一对应 —— 少一边就是"写命令找不到
#       函数"或"读命令白背 42.8KB"，由 tests/write-lazy.sh 逐条核对。
# 写前 diff 预览：preview-<写命令> 走同一条实现，但只出差异不落盘
#（commit_backend_file 里拦）。白名单钉死在九条写命令上；这里不另开 case ——
# 分派表是仓库闸门定位「写实现只被分派表调用」的锚，多一个 case 它就瞎了。
if [ "${CMD#preview-}" != "$CMD" ]; then
    base="${CMD#preview-}"
    if printf '%s' " teesim-save teesim-save-overrides teesim-profile-new teesim-profile-del omk-save-injector omk-save-config tricky-save-patch tricky-drop-patch keybox-save " | grep -q " $base "; then
        KL_PREVIEW=1
        KL_PREVIEW_DIFF=""
        CMD="$base"
    else
        echo "未知命令：$CMD" >&2
        exit 1
    fi
fi

KL_WRITE_CMDS="props-apply props-on props-off props-boot-hash restore-app restore-apps \
remove-apps set-mode teesim-save teesim-save-overrides omk-save-injector omk-save-config \
tricky-save-patch tricky-drop-patch keybox-save sync clear-log omk-restart \
teesim-profile-new teesim-profile-del backup-restore"

for _kl_c in $KL_WRITE_CMDS; do
    if [ "$_kl_c" = "$CMD" ]; then
        . "$MODDIR/lib/write.sh" || { echo "无法加载 lib/write.sh" >&2; exit 1; }
        break
    fi
done
unset _kl_c

# ---------- 备份列表（只读） ----------
# 输出：名称 <TAB> 字节 <TAB> mtime <TAB> 它对应的后端文件
# 只列"属于当前后端"的那些（映射表说了算），别的后端的备份在这里没有意义。
cmd_backups() {
    local f name tgt sz mt

    detect_backend "$MODDIR"   # 读命令分派不会替它探测（与 backend-info / doctor 一致）

    for f in "$KL_DIR"/*.bak; do
        [ -f "$f" ] || continue
        name="${f##*/}"
        tgt=$(backup_target_for "$name") || continue
        [ -n "$tgt" ] || continue
        sz=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
        mt=$(stat -c %Y "$f" 2>/dev/null)
        tsv "$name" "${sz:-0}" "${mt:-0}" "$tgt"
    done
}

# ---------- 体检（只读） ----------
# 说明：用户说"不生效"时，最费时间的是判断坏在哪一层。这里按依赖顺序把各层过一遍，
#       每项给 ok/warn/bad/skip 和一句"下一步"。**只读**：不写任何文件、不重启后端，
#       所以可以随便点。skip 不是失败，是"这一家/这一环境没有这个面"。
# 输出：先 4 行汇总 kv（checks/bad/warn/skip），再每项一行 TSV：
#       名称 <TAB> 状态 <TAB> 说明 <TAB> 下一步
# 用法：cmd_doctor
cmd_doctor() {
    local rows="" have_backend=0 np=0 pid pfile lk p nl_ ni dif cur raw ino counts

    detect_backend "$MODDIR"   # 读路径的分派不会代替命令自己探测（与 backend-info 一致）

    _doc() {
        rows="$rows$1$TAB$2$TAB$3$TAB${4:-}$NL"
    }

    if kl_is_root; then _doc '权限' ok '以 root 运行' ''
    else _doc '权限' bad '不是 root' '在管理器里给本模块 / WebUI root 权限'; fi

    if [ -n "$KL_BACKEND" ]; then
        have_backend=1
        _doc '后端' ok "$(backend_name) · 配置 $TARGET_FILE" ''
    else
        _doc '后端' bad '没探测到已启用的后端' '装好 OMK / TEESimulator / TrickyStore 之一并启用'
    fi

    if [ "$have_backend" = 1 ]; then
        # 守护进程：只数"cmdline 认得出本模块"的（名单里的旧 pid 可能已经被复用）
        pfile="${KL_DIR}/.kl_daemon_pids.list"
        if [ -f "$pfile" ]; then
            while read -r pid; do
                [ -n "$pid" ] && kl_pid_is_ours "$pid" && np=$((np + 1))
            done < "$pfile"
        fi
        if [ "$np" -gt 0 ]; then _doc '守护进程' ok "$np 个进程在跑" ''
        else _doc '守护进程' bad '没有守护进程在跑' '现在装/卸应用不会自动进名单：重启一次，或重新刷入模块'; fi

        if [ -f "$TARGET_FILE" ]; then
            if [ -w "$TARGET_FILE" ]; then _doc '目标文件' ok "$TARGET_FILE 存在且可写" ''
            else _doc '目标文件' warn "$TARGET_FILE 不可写" '检查是否被别的模块或后端改成了只读'; fi
        else
            _doc '目标文件' bad "不存在：$TARGET_FILE" '让后端先跑一轮生成默认文件，或在名单页点「立即同步」'
        fi

        # 名单 vs 已装：**只比数量**（不逐个对），所以文案里写清"可能"
        nl_=$(current_target_apps 2>/dev/null | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
        ni=$(cmd package list packages -3 --user all 2>/dev/null | grep -c . )
        if [ "${ni:-0}" -gt 0 ]; then
            if [ "${nl_:-0}" -lt "$ni" ]; then
                _doc '名单' warn "已装 $ni 个 · 名单 $nl_ 条（只比数量，可能只是你手动排除过）" '点「立即同步一次」，或等下一次安装/卸载自动触发'
            else
                _doc '名单' ok "已装 $ni 个 · 名单 $nl_ 条" ''
            fi
        else
            _doc '名单' skip '读不到已装应用列表' ''
        fi

        backend_keybox_path
        if [ ! -f "$KEYBOX_PATH" ]; then
            _doc 'keybox' bad "不存在：$KEYBOX_PATH" '在「密钥箱」页粘贴一份，或让后端生成默认 keybox'
        else
            raw="${AWK_CMD:-$(find_awk)}"
            if [ -n "$raw" ] && [ -f "${KL_PATCH%/*}/keybox_check.awk" ]; then
                if ino=$($raw -v backend="$KL_BACKEND" -f "${KL_PATCH%/*}/keybox_check.awk" "$KEYBOX_PATH" 2>&1); then
                    _doc 'keybox' ok "${KEYBOX_PATH##*/} 结构通过校验" ''
                else
                    _doc 'keybox' bad "结构不合格：${ino#err$TAB}" '在「密钥箱」页重新粘贴一份完整的 keybox.xml'
                fi
            else
                _doc 'keybox' skip '缺少 awk 或校验脚本，跳过结构检查' ''
            fi
        fi

        if props_disabled; then
            _doc '属性伪装' ok '开机写入已关闭（开关文件存在）' ''
        else
            dif=0
            while read -r p raw; do
                [ -n "$p" ] || continue
                prop_now "$p"; cur="$PROP_NOW"
                [ -n "$cur" ] && [ "$cur" = "$raw" ] || dif=$((dif + 1))
            done <<PAIRS
$(props_expect_pairs)
PAIRS
            if [ "${dif:-0}" -gt 0 ]; then
                _doc '属性伪装' warn "开机写入已开启，$dif 项与期望值不符" '点「立即应用一次」；仍不符就看属性页里那几行的当前值'
            else
                _doc '属性伪装' ok '开机写入已开启，对照项全部一致' ''
            fi
        fi

        raw=$(boot_hash_get)
        prop_now ro.boot.vbmeta.digest; cur="$PROP_NOW"
        if [ -z "$raw" ]; then
            _doc '启动哈希' skip '没有配置 vbmeta digest' ''
        elif ! boot_hash_valid "$raw"; then
            _doc '启动哈希' bad '配置的哈希格式不对' '只接受 64/128 位十六进制，在「属性伪装」页重填'
        elif [ "$(printf '%s' "$cur" | tr 'A-F' 'a-f')" = "$raw" ]; then
            _doc '启动哈希' ok '当前值等于配置值' ''
        else
            _doc '启动哈希' warn '当前值与配置值不一致' '点「保存并应用」重写一次；重启后仍不一致说明这台设备的值变了'
        fi

        ino=$(find_inotify_cmd)
        if [ -n "$ino" ]; then _doc '监听工具' ok "${ino%%:*}" ''
        else _doc '监听工具' bad '没找到 inotify 工具' '模块靠它感知安装/卸载；这期间只能手动同步'; fi

        lk="${KL_DIR}/.kl_lock"
        if [ -d "$lk" ]; then
            p=$(cat "$lk/pid" 2>/dev/null)
            if [ -n "$p" ] && kl_lock_holder_alive "$p"; then
                _doc '并发锁' warn "正在写入（pid $p）" '等几秒再试；长期不释放的会在日志里留一条'
            else
                _doc '并发锁' warn '有残留锁，持有者已不在' '不用管，下一次写入会自动接管'
            fi
        else
            _doc '并发锁' ok '空闲' ''
        fi

        if [ -f "$KL_LOG" ]; then
            _doc '日志' ok "${KL_LOG##*/} $(wc -c < "$KL_LOG" 2>/dev/null | tr -d ' ') 字节" ''
        else
            _doc '日志' skip '还没有日志文件（没发生过同步）' ''
        fi
    else
        for p in '守护进程' '目标文件' '名单' 'keybox' '属性伪装' '启动哈希' '监听工具' '并发锁' '日志'; do
            _doc "$p" skip '没有后端，跳过' ''
        done
    fi

    counts=$(printf '%s' "$rows" | ${AWK_CMD:-awk} -F"$TAB" '{c[$2]++} END {printf "%d %d %d %d\n", c["ok"]+0, c["warn"]+0, c["bad"]+0, c["skip"]+0}')
    set -- $counts
    kv checks "$((${1:-0} + ${2:-0} + ${3:-0} + ${4:-0}))"
    kv bad "${3:-0}"
    kv warn "${2:-0}"
    kv skip "${4:-0}"
    print -r -- "$rows"
}

case "$CMD" in
    doctor)      cmd_doctor ;;
    backups)     cmd_backups ;;
    contract)    cmd_contract ;;
    excluded)    cmd_excluded ;;
    status)      cmd_status ;;
    env)         cmd_env ;;
    targets)     cmd_targets ;;
    target-meta) cmd_target_meta ;;
    # 命令层只收到一个经过单引号转义的参数：`包名 模式`。包名不含空格，
    # 所以在这里按第一个空格拆开，界面不需要第二套参数编码。
    set-mode)
        _pkg="${2%% *}"
        _mode="${2#* }"
        [ "$_mode" = "$2" ] && _mode=""
        cmd_set_mode "$_pkg" "$_mode"
        ;;
    backend-info) cmd_backend_info ;;
    teesim-profiles) cmd_teesim_profiles ;;
    tee-status)    cmd_tee_status ;;
    teesim-overrides) cmd_teesim_overrides ;;
    teesim-save-overrides) cmd_teesim_save_overrides "$ARG" ;;
    tricky-patches) cmd_tricky_patches ;;
    omk-restart)   cmd_omk_restart "$ARG" ;;
    teesim-save) cmd_teesim_save "$ARG" ;;
    omk-save-injector) cmd_omk_save_injector "$ARG" ;;
    omk-save-config) cmd_omk_save_config "$ARG" ;;
    tricky-save-patch) cmd_tricky_save_patch "$ARG" ;;
    tricky-drop-patch) cmd_tricky_drop_patch "$ARG" ;;
    teesim-profile-new) cmd_teesim_profile_new "$ARG" ;;
    teesim-profile-del) cmd_teesim_profile_del "$ARG" ;;
    keybox-save) cmd_keybox_save "$ARG" ;;
    apps)        cmd_apps ;;
    icons)       cmd_icons ;;
    log)         cmd_log ;;
    clear-log)   cmd_clear_log ;;
    props)       cmd_props ;;
    props-apply) cmd_props_apply ;;
    props-on)    cmd_props_switch on ;;
    props-off)   cmd_props_switch off ;;
    boot-hash)   cmd_boot_hash ;;
    props-boot-hash) cmd_set_boot_hash "$ARG" ;;
    restore-app) cmd_restore_app "$ARG" ;;
    backup-restore) cmd_backup_restore "$ARG" ;;
    restore-apps) cmd_restore_apps "$ARG" ;;
    remove-apps) cmd_remove_apps "$ARG" ;;
    sync)        cmd_sync ;;
    help)        cmd_help ;;
    *) echo "未知命令：$CMD（可用：sh webui.sh help）" >&2; exit 1 ;;
esac

# 预览收尾：差异交给界面（base64，免得换行破坏 kv 的逐行解析）
if [ "${KL_PREVIEW:-0}" = "1" ]; then
    changed=$(printf '%s' "${KL_PREVIEW_DIFF:-}" | grep -c '^[-+]') || changed=0
    kv preview 1
    kv changed "$changed"
    kv diff "$(printf '%s' "${KL_PREVIEW_DIFF:-}" | base64 | tr -d '\n' 2>/dev/null)"
fi
