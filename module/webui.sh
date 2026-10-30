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

# PATH 覆盖三个框架自带的 busybox 与 resetprop 目录：
# WebView 里 exec 出来的 shell 继承的是管理器的环境，不能假定 /system/bin 已在其中。
export PATH="/system/bin:/system/xbin:/odm/bin:/vendor/bin:/product/bin:/data/adb/magisk:/data/adb/ksu/bin:/data/adb/ap/bin:$PATH"

. "$MODDIR/lib/common.sh" || { echo "无法加载 lib/common.sh" >&2; exit 1; }

# 改名迁移：刷完没重启就打开界面时，界面读的启动哈希与伪装开关得是新路径上的那份。
# 幂等（新名已存在就不动），所以每次调用只是几次 stat。
migrate_legacy_paths

[ "$(id -u)" -eq 0 ] || { echo "需要 root 权限" >&2; exit 1; }

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
backend-info teesim-save omk-save-injector omk-save-config tricky-save-patch keybox-save \
sync help contract excluded teesim-profiles tee-status tricky-patches omk-restart teesim-overrides \
teesim-save-overrides"

# ---------- 通用小工具 ----------
# 说明：换行常量。查表一律用「$NL + 键 + =」作锚点做参数展开，
#       不用 while read —— 实测每次 here-doc 都要建临时文件，17 次取值多花 1000ms。
NL='
'

# 用法：kv <键> <值>
kv() { printf '%s=%s\n' "$1" "$2"; }

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
# 说明：就是逐个 getprop，别再试「批处理」——本机实测三种读法：
#         17 次 getprop                              277ms   ← 现在用的
#         一次 getprop 全量 + grep -F -f 过滤成小表  1692ms（临时文件与多模式匹配）
#         一次 getprop 全量 + 参数展开查表            228487ms（67KB 字符串上做模式匹配）
#       在 mksh 里，对大字符串做 ${var#*pattern} 展开比多起几个进程贵得多。
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
backend_state() {
    [ -d "$1" ] || { printf 'absent'; return 0; }
    if [ -f "$1/disable" ]; then printf 'disabled'; else printf 'active'; fi
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

# 说明：把刚生成的 temp 落到 target；backup 放在后端的 KL_DIR
# 用法：commit_backend_file <target> <temp> <备份名>
commit_backend_file() {
    local target="$1" temp="$2" name="$3"
    write_atomic_preserve "$target" "$temp" "${KL_DIR}/${name}"
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

# 说明：把「未纳入」或「已排除」的应用加入目标文件。等价于手动写回文件；只改 apps 数组 /
#       target.txt，别的内容原样保留。包名来自界面列表，这里仍按规则再校验一次。
cmd_restore_app() {
  local pkg="$1" rc

  require_runnable || return 1

  detect_backend "$MODDIR"
  is_target_entry "$pkg" || { echo "不是合法的目标条目：$pkg" >&2; return 1; }
  webui_lock || return 1
  add_target_app "$pkg"
  rc=$?
  release_lock "${KL_DIR}/.kl_lock"

  case "$rc" in
    0)
      # 恢复后顺手把模块描述里的条数刷新，管理器里不用等下一轮同步
      KL_COUNT=$(current_target_apps 2>/dev/null | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
      [ "${KL_COUNT:-0}" -gt 0 ] 2>/dev/null && update_module_desc "$PROP_FILE" "$KL_COUNT"
      log_info "🧩 WebUI 把 $pkg 加回目标名单"
      kv restored 1
      ;;
    1) kv restored 0 ;;
    *)
      echo "写入失败：$TARGET_FILE" >&2
      return 1
      ;;
  esac
}

# 说明：批量版。参数是逗号分隔的包名；全部校验通过后只写一次目标文件，
#       避免一条一条写把 OMK 的 injector 重载很多次。
cmd_restore_apps() {
  local raw="$1" file rc oldifs pkg n=0

  require_runnable || return 1
  [ -n "$raw" ] || { echo "参数为空" >&2; return 1; }

  detect_backend "$MODDIR"
  file="${KL_DIR}/.kl_restore.req.$$"
  : > "$file" 2>/dev/null || { echo "无法创建临时文件：$file" >&2; return 1; }

  oldifs=$IFS
  IFS=','
  for pkg in $raw; do
    [ -n "$pkg" ] || continue
    if ! is_target_entry "$pkg"; then
      IFS=$oldifs
      rm -f "$file" 2>/dev/null
      echo "不是合法的目标条目：$pkg" >&2
      return 1
    fi
    printf '%s\n' "$pkg" >> "$file"
    n=$((n + 1))
  done
  IFS=$oldifs
  if [ "$n" -eq 0 ]; then
    rm -f "$file" 2>/dev/null
    echo "没有有效包名" >&2
    return 1
  fi

  webui_lock || { rm -f "$file" 2>/dev/null; return 1; }
  add_target_apps "$file"
  rc=$?
  release_lock "${KL_DIR}/.kl_lock"
  rm -f "$file" 2>/dev/null

  case "$rc" in
    0)
      KL_COUNT=$(current_target_apps 2>/dev/null | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
      [ "${KL_COUNT:-0}" -gt 0 ] 2>/dev/null && update_module_desc "$PROP_FILE" "$KL_COUNT"
      log_info "🧩 WebUI 批量加入目标名单（$n 个包名）"
      kv restored 1
      ;;
    1) kv restored 0 ;;
    *)
      echo "写入失败：$TARGET_FILE" >&2
      return 1
      ;;
  esac
}

# 说明：批量移出。和 restore-apps 对称：全部校验通过后只写一次，避免 OMK
#       逐条重载。名单至少保留一条 —— 生成空列表会被守护进程当成写入失败。
cmd_remove_apps() {
  local raw="$1" file rc oldifs pkg n=0 after removed

  require_runnable || return 1
  [ -n "$raw" ] || { echo "参数为空" >&2; return 1; }

  detect_backend "$MODDIR"
  file="${KL_DIR}/.kl_remove.req.$$"
  : > "$file" 2>/dev/null || { echo "无法创建临时文件：$file" >&2; return 1; }

  oldifs=$IFS
  IFS=','
  for pkg in $raw; do
    [ -n "$pkg" ] || continue
    if ! is_target_entry "$pkg"; then
      IFS=$oldifs
      rm -f "$file" 2>/dev/null
      echo "不是合法的目标条目：$pkg" >&2
      return 1
    fi
    printf '%s\n' "$pkg" >> "$file"
    n=$((n + 1))
  done
  IFS=$oldifs
  if [ "$n" -eq 0 ]; then
    rm -f "$file" 2>/dev/null
    echo "没有有效包名" >&2
    return 1
  fi

  webui_lock || { rm -f "$file" 2>/dev/null; return 1; }
  remove_target_apps "$file"
  rc=$?
  after=$(current_target_apps 2>/dev/null | sed 's/\r$//' | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
  release_lock "${KL_DIR}/.kl_lock"
  rm -f "$file" 2>/dev/null

  case "$rc" in
    0)
      # 以命令层实际移出的 token 数为准：同名条目可能只留一个有效项，
      # 用 before-after 在重复行/模式合并时会算成 0。
      removed=$(printf '%s' "$KL_REMOVED_LIST" | tr ',' '\n' | sed '/^$/d' | wc -l | tr -d ' ')
      update_module_desc "$PROP_FILE" "${after:-0}"
      log_info "🧩 WebUI 从目标名单移出 $removed 个应用"
      kv removed "$removed"
      kv removed_list "${KL_REMOVED_LIST:-}"
      ;;
    1) kv removed 0; kv removed_list "" ;;
    3)
      echo "不能移出全部应用：目标名单至少保留一个" >&2
      return 1
      ;;
    *)
      echo "写入失败：$TARGET_FILE" >&2
      return 1
      ;;
  esac
}

# ---------- 后端配置写回 ----------
# 用法：teesim-save <payload_b64>
# payload 行：key=<base64(value)>，键名见下；未知键/非法值整体拒绝。
cmd_teesim_save() {
    local payload="$1" dir pairs out status st saved=0 n=0 k v

    require_runnable || return 1
    detect_backend "$MODDIR"
    if [ "$KL_BACKEND" != "teesim" ]; then echo "当前后端不是 TEE Simulator" >&2; return 1; fi
    [ -f "$TEESIM_CONFIG" ] || { echo "配置不存在：$TEESIM_CONFIG" >&2; return 1; }
    [ -n "$AWK_CMD" ] || AWK_CMD=$(find_awk)
    [ -n "$AWK_CMD" ] && [ -f "${KL_PATCH%/*}/teesim_set.awk" ] || { echo "缺少 teesim_set.awk" >&2; return 1; }

    dir="${KL_DIR}/.kl_save.$$"
    mkdir -p "$dir" 2>/dev/null && chmod 700 "$dir" 2>/dev/null || return 1
    pairs="$dir/pairs"
    parse_payload "$payload" "$pairs" || { rm -rf "$dir"; return 1; }

    # profile 是"改哪一份"，不是"改成什么" —— 先摘出来，别当未知字段拒掉。
    # 省略时仍是 default，所以旧界面发来的 payload 行为不变。
    prof=$(awk -F"$TAB" '$1=="profile"{print $2; exit}' "$pairs")
    [ -n "$prof" ] || prof=default
    case "$prof" in
        *[!A-Za-z0-9._-]*|''|*/*) echo "profile 名字不合法：$prof" >&2; rm -rf "$dir"; return 1 ;;
    esac
    grep -v "^profile$TAB" "$pairs" > "$pairs.f" 2>/dev/null && mv "$pairs.f" "$pairs"
    rm -f "$pairs.f" 2>/dev/null
    [ -s "$pairs" ] || { echo "没有可写字段" >&2; rm -rf "$dir"; return 1; }

    while IFS=$TAB read -r k v; do
        case "$k" in
            mode) [ "$v" = "patch" ] || [ "$v" = "generation" ] || { echo "模式只能是 patch / generation" >&2; rm -rf "$dir"; return 1; } ;;
            keybox) valid_keybox_name "$v" && [ -f "$TEESIM_DIR/$v" ] || { echo "keybox 文件不存在：$v" >&2; rm -rf "$dir"; return 1; } ;;
            patch_system|patch_vendor|patch_boot) valid_patch "$v" || { echo "补丁值不合法：$k = $v（留空=用采集值 / today / no=报 0 / system_property / YYYY-MM / YYYY-MM-DD / YYYYMM / YYYYMMDD；关键字不分大小写，日期里的 YYYY、MM、DD 必须大写且不能单独出现）" >&2; rm -rf "$dir"; return 1; } ;;
            os_version) valid_os_version "$v" || { echo "OS 版本不合法" >&2; rm -rf "$dir"; return 1; } ;;
            auto_include) valid_bool "$v" || { echo "auto_include 只能是 true/false" >&2; rm -rf "$dir"; return 1; } ;;
            brand|device|product|manufacturer|model|serial|imei|meid|imei2)
                valid_text "$v" 256 || { echo "字段不合法：$k" >&2; rm -rf "$dir"; return 1; } ;;
            *) echo "未知字段：$k" >&2; rm -rf "$dir"; return 1 ;;
        esac
        n=$((n + 1))
    done < "$pairs"

    webui_lock || { rm -rf "$dir"; return 1; }
    out="$TEESIM_DIR/.config.json.keylens.$$"
    status="$dir/status"
    $AWK_CMD -v pairsfile="$pairs" -v statusfile="$status" -v profile="$prof" \
        -f "${KL_PATCH%/*}/teesim_set.awk" "$TEESIM_CONFIG" > "$out" 2>/dev/null
    st=$(cat "$status" 2>/dev/null)
    case "$st" in
        ok)
            if cmp -s "$out" "$TEESIM_CONFIG" 2>/dev/null; then
                rm -f "$out" 2>/dev/null
            elif commit_backend_file "$TEESIM_CONFIG" "$out" "config.json.bak"; then
                saved=1
            else
                rm -f "$out" 2>/dev/null
                release_lock "${KL_DIR}/.kl_lock"
                rm -rf "$dir"
                echo "写入失败：$TEESIM_CONFIG" >&2
                return 1
            fi
            ;;
        same) rm -f "$out" 2>/dev/null ;;
        *)
            rm -f "$out" 2>/dev/null
            release_lock "${KL_DIR}/.kl_lock"
            rm -rf "$dir"
            echo "配置定位失败：$TEESIM_CONFIG" >&2
            return 1
            ;;
    esac
    release_lock "${KL_DIR}/.kl_lock"
    rm -rf "$dir" 2>/dev/null

    [ "$saved" = 1 ] && log_info "🧩 WebUI 更新 TEE Simulator 配置（profile=$prof，$n 项）"
    kv saved "$saved"
    kv fields "$n"
    kv profile "$prof"
}

# 用法：omk-save-injector <payload_b64>
cmd_omk_save_injector() {
    local payload="$1" dir pairs norm out status st saved=0 n=0 k v

    require_runnable || return 1
    detect_backend "$MODDIR"
    if [ "$KL_BACKEND" != "omk" ]; then echo "当前后端不是 OhMyKeymint" >&2; return 1; fi
    [ -f "$OMK_INJECTOR" ] || { echo "injector.toml 不存在" >&2; return 1; }
    [ -n "$AWK_CMD" ] || AWK_CMD=$(find_awk)
    [ -n "$AWK_CMD" ] && [ -f "${KL_PATCH%/*}/omk_set.awk" ] || { echo "缺少 omk_set.awk" >&2; return 1; }

    dir="${KL_DIR}/.kl_save.$$"
    mkdir -p "$dir" 2>/dev/null && chmod 700 "$dir" 2>/dev/null || return 1
    pairs="$dir/pairs"; norm="$dir/pairs.norm"
    parse_payload "$payload" "$pairs" || { rm -rf "$dir"; return 1; }

    while IFS=$TAB read -r k v; do
        case "$k" in
            inj_main_enabled|filter_enabled|filter_block_android|filter_allow_unknown)
                valid_bool "$v" || { echo "字段只能是 true/false：$k" >&2; rm -rf "$dir"; return 1; } ;;
            intercept_get_security_level|intercept_get_key_entry|intercept_update_subcomponent|\
            intercept_list_entries|intercept_delete_key|intercept_grant|intercept_ungrant|\
            intercept_get_number_of_entries|intercept_list_entries_batched|intercept_get_supplementary_attestation_info)
                valid_bool "$v" || { echo "字段只能是 true/false：$k" >&2; rm -rf "$dir"; return 1; } ;;
            inj_log_level) valid_inj_log_level "$v" || { echo "日志级别不合法（injector 认 off/error/warn/warning/info/debug/trace）" >&2; rm -rf "$dir"; return 1; } ;;
            filter_deny)
                valid_deny_list "$v" || { echo "拒绝包名列表不合法" >&2; rm -rf "$dir"; return 1; }
                printf '%s\t%s\n' "$k" "$DENY_NORM" >> "$norm"
                n=$((n + 1)); continue ;;
            *) echo "未知字段：$k" >&2; rm -rf "$dir"; return 1 ;;
        esac
        printf '%s\t%s\n' "$k" "$v" >> "$norm"
        n=$((n + 1))
    done < "$pairs"

    webui_lock || { rm -rf "$dir"; return 1; }
    out="$OMK_DIR/.injector.toml.keylens.$$"
    status="$dir/status"
    $AWK_CMD -v pairsfile="$norm" -v target=injector -v statusfile="$status" \
        -f "${KL_PATCH%/*}/omk_set.awk" "$OMK_INJECTOR" > "$out" 2>/dev/null
    st=$(cat "$status" 2>/dev/null)
    case "$st" in
        ok)
            if cmp -s "$out" "$OMK_INJECTOR" 2>/dev/null; then
                rm -f "$out" 2>/dev/null
            elif commit_backend_file "$OMK_INJECTOR" "$out" "injector.toml.bak"; then
                saved=1
            else
                rm -f "$out" 2>/dev/null
                release_lock "${KL_DIR}/.kl_lock"
                rm -rf "$dir"
                echo "写入失败：$OMK_INJECTOR" >&2
                return 1
            fi
            ;;
        same) rm -f "$out" 2>/dev/null ;;
        *)
            rm -f "$out" 2>/dev/null
            release_lock "${KL_DIR}/.kl_lock"
            rm -rf "$dir"
            echo "配置定位失败：$OMK_INJECTOR" >&2
            return 1
            ;;
    esac
    release_lock "${KL_DIR}/.kl_lock"
    rm -rf "$dir" 2>/dev/null
    [ "$saved" = 1 ] && { omk_restart injector; log_info "🧩 WebUI 更新 OMK injector.toml（$n 项）"; }
    kv saved "$saved"
    kv fields "$n"
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

cmd_omk_save_config() {
    local payload="$1" dir pairs out status st saved=0 n=0 k v cfg
    local old_vbk old_vbh new_vbk new_vbh keys scope note

    require_runnable || return 1
    detect_backend "$MODDIR"
    if [ "$KL_BACKEND" != "omk" ]; then echo "当前后端不是 OhMyKeymint" >&2; return 1; fi
    cfg="$OMK_DIR/config.toml"
    [ -f "$cfg" ] || { echo "config.toml 不存在" >&2; return 1; }
    [ -n "$AWK_CMD" ] || AWK_CMD=$(find_awk)
    [ -n "$AWK_CMD" ] && [ -f "${KL_PATCH%/*}/omk_set.awk" ] || { echo "缺少 omk_set.awk" >&2; return 1; }

    dir="${KL_DIR}/.kl_save.$$"
    mkdir -p "$dir" 2>/dev/null && chmod 700 "$dir" 2>/dev/null || return 1
    pairs="$dir/pairs"
    parse_payload "$payload" "$pairs" || { rm -rf "$dir"; return 1; }

    # 旧值要在写之前取：判 vb_key / vb_hash 是不是从 random 切到 auto（那要重启整机）
    old_vbk=$(sed -n 's/^[[:space:]]*vb_key[[:space:]]*=[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$cfg" | head -n 1)
    old_vbh=$(sed -n 's/^[[:space:]]*vb_hash[[:space:]]*=[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$cfg" | head -n 1)
    new_vbk="" new_vbh="" keys=""

    while IFS=$TAB read -r k v; do
        case "$k" in
            cfg_log_level) valid_log_level "$v" || { echo "日志级别不合法" >&2; rm -rf "$dir"; return 1; } ;;
            cfg_force_skip_biometric|cfg_retire_stale_keys|trust_verified_boot|trust_device_locked|dev_override_telephony)
                valid_bool "$v" || { echo "字段只能是 true/false：$k" >&2; rm -rf "$dir"; return 1; } ;;
            trust_os_version)
                valid_omk_os_version "$v" || { echo "OS 版本只能是 auto 或 0–99（MMmmss 编码值）" >&2; rm -rf "$dir"; return 1; } ;;
            trust_security_patch|trust_os_patchlevel|trust_vendor_patchlevel)
                valid_omk_patch "$v" || { echo "$k 只能是 auto / latest / YYYY-MM-DD" >&2; rm -rf "$dir"; return 1; } ;;
            trust_boot_patchlevel)
                valid_omk_boot "$v" || { echo "trust_boot_patchlevel 只能是 auto / latest / YYYY-MM-DD / 十进制数" >&2; rm -rf "$dir"; return 1; } ;;
            trust_vb_key|trust_vb_hash)
                valid_omk_hash "$v" || { echo "$k 只能是 auto / random / 64 位十六进制" >&2; rm -rf "$dir"; return 1; } ;;
            dev_brand|dev_device|dev_product|dev_manufacturer|dev_model|dev_serial|dev_imei|dev_imei2|dev_meid)
                valid_text "$v" 128 || { echo "字段不合法：$k" >&2; rm -rf "$dir"; return 1; } ;;
            *) echo "未知字段：$k" >&2; rm -rf "$dir"; return 1 ;;
        esac
        keys="$keys $k"
        [ "$k" = "trust_vb_key" ] && new_vbk="$v"
        [ "$k" = "trust_vb_hash" ] && new_vbh="$v"
        n=$((n + 1))
    done < "$pairs"

    webui_lock || { rm -rf "$dir"; return 1; }
    out="$OMK_DIR/.config.toml.keylens.$$"
    status="$dir/status"
    $AWK_CMD -v pairsfile="$pairs" -v target=config -v statusfile="$status" \
        -f "${KL_PATCH%/*}/omk_set.awk" "$cfg" > "$out" 2>/dev/null
    st=$(cat "$status" 2>/dev/null)
    case "$st" in
        ok)
            if cmp -s "$out" "$cfg" 2>/dev/null; then
                rm -f "$out" 2>/dev/null
            elif commit_backend_file "$cfg" "$out" "config.toml.bak"; then
                saved=1
            else
                rm -f "$out" 2>/dev/null
                release_lock "${KL_DIR}/.kl_lock"
                rm -rf "$dir"
                echo "写入失败：$cfg" >&2
                return 1
            fi
            ;;
        same) rm -f "$out" 2>/dev/null ;;
        *)
            rm -f "$out" 2>/dev/null
            release_lock "${KL_DIR}/.kl_lock"
            rm -rf "$dir"
            echo "配置定位失败：$cfg" >&2
            return 1
            ;;
    esac
    release_lock "${KL_DIR}/.kl_lock"
    rm -rf "$dir" 2>/dev/null
    scope=restart
    note=""
    if [ "$saved" = 1 ]; then
        scope=$(omk_apply_scope $keys)
        if [ "$scope" = hot ]; then
            # 四个补丁字段整组热生效：不重启，TA 原地更新，在途操作与 per-boot 计数不丢
            note="四个补丁字段整组热生效，没有重启 keymint"
        else
            omk_restart keymint
            note="已请求重启 keymint"
        fi
        if omk_reboot_needed "$old_vbk" "$new_vbk" "$old_vbh" "$new_vbh"; then
            scope=reboot
            note="vb_key/vb_hash 从 random 切到 auto：要重启【整机】才读得到启动元数据，重启 keymint 不够"
        fi
        log_info "🧩 WebUI 更新 OMK config.toml（$n 项，生效代价 $scope）"
    fi
    kv saved "$saved"
    kv fields "$n"
    kv apply_scope "$scope"
    [ -n "$note" ] && kv apply_note "$note"
}

# 用法：tricky-save-patch <payload_b64>（只改 security_patch.txt 的全局段）
cmd_tricky_save_patch() {
    local payload="$1" dir pairs out status st saved=0 n=0 k v target

    require_runnable || return 1
    detect_backend "$MODDIR"
    if [ "$KL_BACKEND" != "tricky" ]; then echo "当前后端不是 Tricky Store" >&2; return 1; fi
    [ -n "$AWK_CMD" ] || AWK_CMD=$(find_awk)
    [ -n "$AWK_CMD" ] && [ -f "${KL_PATCH%/*}/tricky_patch_set.awk" ] || { echo "缺少 tricky_patch_set.awk" >&2; return 1; }

    dir="${KL_DIR}/.kl_save.$$"
    mkdir -p "$dir" 2>/dev/null && chmod 700 "$dir" 2>/dev/null || return 1
    pairs="$dir/pairs"
    parse_payload "$payload" "$pairs" || { rm -rf "$dir"; return 1; }

    # scope 是"改哪一段"：省略 = 全局；给包名 = 那个 [包名] 块（没有就新建）。
    sc=$(awk -F"$TAB" '$1=="scope"{print $2; exit}' "$pairs")
    [ -n "$sc" ] || sc=global
    if [ "$sc" != "global" ]; then
        printf '%s' "$sc" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+$' \
            || { echo "scope 必须是 global 或一个合法包名：$sc" >&2; rm -rf "$dir"; return 1; }
    fi
    grep -v "^scope$TAB" "$pairs" > "$pairs.f" 2>/dev/null && mv "$pairs.f" "$pairs"
    rm -f "$pairs.f" 2>/dev/null
    [ -s "$pairs" ] || { echo "没有可写字段" >&2; rm -rf "$dir"; return 1; }

    while IFS=$TAB read -r k v; do
        case "$k" in
            patch_system|patch_vendor|patch_boot|patch_all)
                valid_tricky_patch "$v" || { echo "补丁值不合法：$k = $v（接受 YYYY-MM-DD / YYYYMMDD / YYYYMM / no / device_default / prop / YYYY、MM、DD 占位）" >&2; rm -rf "$dir"; return 1; } ;;
            *) echo "未知字段：$k" >&2; rm -rf "$dir"; return 1 ;;
        esac
        n=$((n + 1))
    done < "$pairs"

    target="$TSTORE_DIR/security_patch.txt"
    webui_lock || { rm -rf "$dir"; return 1; }
    out="$TSTORE_DIR/.security_patch.txt.keylens.$$"
    status="$dir/status"
    $AWK_CMD -v pairsfile="$pairs" -v statusfile="$status" -v scope="$sc" \
        -f "${KL_PATCH%/*}/tricky_patch_set.awk" "$target" > "$out" 2>/dev/null
    st=$(cat "$status" 2>/dev/null)
    case "$st" in
        ok)
            if [ -f "$target" ] && cmp -s "$out" "$target" 2>/dev/null; then
                rm -f "$out" 2>/dev/null
            elif commit_backend_file "$target" "$out" "security_patch.txt.bak"; then
                saved=1
            else
                rm -f "$out" 2>/dev/null
                release_lock "${KL_DIR}/.kl_lock"
                rm -rf "$dir"
                echo "写入失败：$target" >&2
                return 1
            fi
            ;;
        same) rm -f "$out" 2>/dev/null ;;
        *)
            rm -f "$out" 2>/dev/null
            release_lock "${KL_DIR}/.kl_lock"
            rm -rf "$dir"
            echo "补丁表写入失败" >&2
            return 1
            ;;
    esac
    release_lock "${KL_DIR}/.kl_lock"
    rm -rf "$dir" 2>/dev/null
    [ "$saved" = 1 ] && log_info "🧩 WebUI 更新 Tricky 补丁表（scope=$sc，$n 项）"
    kv saved "$saved"
    kv fields "$n"
    kv scope "$sc"
}

# 用法：keybox-save <base64(xml)>；写到当前后端的活动 keybox
cmd_keybox_save() {
    local enc="${1:-}" bcmd dir target tmp bytes st ac kbc kbmsg

    require_runnable || return 1
    detect_backend "$MODDIR"
    [ -n "$enc" ] || { echo "keybox 内容为空" >&2; return 1; }
    [ "${#enc}" -le 180000 ] || { echo "keybox 过大（上限约 128KB）" >&2; return 1; }
    bcmd=$(find_base64) || { echo "缺少 base64 命令" >&2; return 1; }

    backend_keybox_path
    target="$KEYBOX_PATH"
    dir="${KL_DIR}/.kl_keybox.$$"
    mkdir -p "$dir" 2>/dev/null && chmod 700 "$dir" 2>/dev/null || return 1
    tmp="${target%/*}/.${target##*/}.keylens.$$"
    printf '%s' "$enc" | $bcmd -d > "$tmp" 2>/dev/null || { rm -rf "$dir"; rm -f "$tmp"; echo "keybox 解码失败" >&2; return 1; }

    bytes=$(wc -c < "$tmp" 2>/dev/null | tr -d ' ')
    [ "${bytes:-0}" -ge 64 ] && [ "${bytes:-0}" -le 131072 ] || {
        rm -rf "$dir"; rm -f "$tmp"; echo "keybox 大小不合法" >&2; return 1;
    }
    # 结构校验按后端分叉（判据与理由见 backends/keybox_check.awk 抬头）。
    # 以前这里是共用一句 grep '<AndroidAttestation'：对 TEESim 严于上游（它不看根
    # 元素名，合法的会被误拒），对 OMK 宽于上游（它要求每个 <Key> 块自带
    # <NumberOfCertificates> 且与本块证书数相等；不符时 OMK 不是"不生效"，而是把
    # 自带模板覆盖回这个文件，用户看到的却是"我明明换过了"）。
    ac="$AWK_CMD"
    [ -n "$ac" ] || ac=$(find_awk)
    kbc="${KL_PATCH%/*}/keybox_check.awk"
    if [ -z "$ac" ] || [ ! -f "$kbc" ]; then
        rm -rf "$dir"; rm -f "$tmp"
        echo "缺少 awk 或 backends/keybox_check.awk，无法校验 keybox 结构" >&2
        return 1
    fi
    if ! kbmsg=$($ac -v backend="$KL_BACKEND" -f "$kbc" "$tmp" 2>&1); then
        rm -rf "$dir"; rm -f "$tmp"
        case "$kbmsg" in
            # 制表符在 case 里是分隔符，必须引起来，否则 `err` 与 `*)` 被当成两个词
            "err	"*) echo "keybox 结构不合格（$(backend_name)）：${kbmsg#err	}" >&2 ;;
            *)   echo "keybox 校验失败（$(backend_name)）：${kbmsg:-awk 没有给出原因}" >&2 ;;
        esac
        return 1
    fi

    webui_lock || { rm -rf "$dir"; rm -f "$tmp"; return 1; }
    if commit_backend_file "$target" "$tmp" "keybox.xml.bak"; then
        chmod 600 "$target" 2>/dev/null
        st=1
    else
        rm -f "$tmp" 2>/dev/null
        st=0
    fi
    release_lock "${KL_DIR}/.kl_lock"
    rm -rf "$dir" 2>/dev/null

    [ "$st" = 1 ] || { echo "写入失败：$target" >&2; return 1; }
    log_info "🔑 WebUI 替换 keybox：$target（$bytes 字节）"
    kv saved 1
    kv keybox_file "$target"
    kv keybox_bytes "$bytes"
    kv keybox_sha "$(sha256sum "$target" 2>/dev/null | cut -d' ' -f1)"
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
    [ -f "$f" ] || { echo "文件不存在：$f" >&2; return 1; }
    ac="$AWK_CMD"; [ -n "$ac" ] || ac=$(find_awk)
    [ -n "$ac" ] || { echo "未找到 awk，读不了补丁表" >&2; return 1; }
    [ -f "${KL_PATCH%/*}/tricky_patches.awk" ] || { echo "缺少 tricky_patches.awk" >&2; return 1; }
    $ac -f "${KL_PATCH%/*}/tricky_patches.awk" "$f"
}

# 用法：omk-restart <keymint|injector|all>
# 说明：OMK 的 config.toml 里只有四个补丁级别字段与两个开关是热生效的，其余要
#       重启 keymint 才读得到；这里给界面一个明确的出口，而不是让用户以为保存
#       完就生效。不复用 omk_restart() —— 那个在目录不存在时静默返回 0，
#       而这是用户主动点的命令，必须如实报成败。
cmd_omk_restart() {
    local which="$1" f
    require_runnable || return 1
    detect_backend "$MODDIR"
    if [ "$KL_BACKEND" != "omk" ]; then echo "当前后端不是 OhMyKeymint" >&2; return 1; fi
    case "$which" in
        keymint|injector|all) ;;
        *) echo "只能触发 keymint / injector / all（收到：$which）" >&2; return 1 ;;
    esac
    [ -d "$OMK_STATE_DIR" ] || { echo "目录不存在：$OMK_STATE_DIR（OMK 没装？）" >&2; return 1; }
    f="$OMK_STATE_DIR/restart.$which"
    : > "$f" 2>/dev/null || { echo "写入失败：$f" >&2; return 1; }
    log_info "🛠 WebUI 触发 OhMyKeymint 重载：$which"
    kv restarted "$which"
    kv trigger "$f"
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

# 写 overrides.json。可写的只有这六个字段：其余在上游是 OverrideSource.REQUIRED
# 锁死的，写进去守护进程会**丢弃并记一条日志**（Harvester.kt:403-405）——
# 静默无效比当场拒掉坏得多，所以这里直接说不通。
# 留空 = 删掉这个键（上游同义：system-controller.js:75 空值即删除，
# Harvester.kt:409 空值复位默认）。
cmd_teesim_save_overrides() {
    local payload="$1" dir pairs out status st saved=0 n=0 k v src
    local ov ha ac ed badf

    require_runnable || return 1
    detect_backend "$MODDIR"
    if [ "$KL_BACKEND" != "teesim" ]; then echo "当前后端不是 TEE Simulator" >&2; return 1; fi
    ov="$TEESIM_DIR/overrides.json"; ha="$TEESIM_DIR/harvested.json"
    ac="$AWK_CMD"; [ -n "$ac" ] || ac=$(find_awk)
    [ -n "$ac" ] || { echo "未找到 awk，写不了 overrides.json" >&2; return 1; }
    [ -f "${KL_PATCH%/*}/json_flat_set.awk" ] || { echo "缺少 json_flat_set.awk" >&2; return 1; }

    dir="${KL_DIR}/.kl_ov.$$"
    mkdir -p "$dir" 2>/dev/null && chmod 700 "$dir" 2>/dev/null || return 1
    pairs="$dir/pairs"
    parse_payload "$payload" "$pairs" || { rm -rf "$dir"; return 1; }

    badf=""
    while IFS=$TAB read -r k v; do
        case "$k" in
            attestationSecurityLevel|keymasterSecurityLevel)
                valid_ov_level "$v" || { echo "$k 只能是 0(Software) / 1(TrustedEnvironment) / 2(StrongBox)，留空表示删掉这一项；收到的是「$v」" >&2; badf=1; } ;;
            attestationVersion|keymasterVersion)
                valid_ov_version "$v" || { echo "$k 只能是 1–100000 的整数，留空表示删掉这一项；收到的是「$v」" >&2; badf=1; } ;;
            verifiedBootKey|verifiedBootHash)
                valid_ov_hex "$v" || { echo "$k 要 64 位十六进制（可带 0x 前缀）、不许全零，留空表示删掉这一项；收到的是「$v」" >&2; badf=1; }
                # 数据决定的可编辑性：只有守护进程自己那份是合成兜底值时才可改
                # （Harvester.kt:183-189）。问自家那条只读汇总，不在这里另判一套。
                if [ -z "$badf" ] && [ -n "$v" ] && [ -f "$ha" ]; then
                    ed=$($ac -v ov="$ov" -v ha="$ha" -f "${KL_PATCH%/*}/teesim_overrides.awk" 2>/dev/null \
                        | $ac -F"$TAB" -v key="$k" '$1 == key { print $3; exit }')
                    if [ -n "$ed" ] && [ "$ed" != "1" ]; then
                        echo "$k 现在不可改：harvested.json 判它的来源不是合成兜底值（上游规则，不是本模块的限制）" >&2
                        badf=1
                    fi
                fi ;;
            *)
                echo "overrides.json 里这个字段被上游锁死为 REQUIRED，写进去守护进程会直接丢弃：$k" >&2
                badf=1 ;;
        esac
        [ -n "$badf" ] && break
        n=$((n + 1))
    done < "$pairs"
    [ -n "$badf" ] && { rm -rf "$dir"; return 1; }
    [ "$n" -gt 0 ] || { echo "没有字段要保存" >&2; rm -rf "$dir"; return 1; }

    # 文件还不存在时以 {} 为底本 —— 底本写在临时目录里，不往 TEESIM_DIR 造半成品
    src="$ov"
    [ -f "$ov" ] || { printf '{}\n' > "$dir/base.json"; src="$dir/base.json"; }

    webui_lock || { rm -rf "$dir"; return 1; }
    out="$TEESIM_DIR/.overrides.json.keylens.$$"
    status="$dir/status"
    $ac -v pairsfile="$pairs" -v statusfile="$status" \
        -f "${KL_PATCH%/*}/json_flat_set.awk" "$src" > "$out" 2>/dev/null
    st=$(cat "$status" 2>/dev/null)
    case "$st" in
        ok)
            if cmp -s "$out" "$ov" 2>/dev/null; then
                rm -f "$out" 2>/dev/null
            elif commit_backend_file "$ov" "$out" "${KL_DIR}/overrides.json.bak"; then
                saved=1
                # 上游的写入器就是 0644（overrides-io.js:34-39）：守护进程以 keystore
                # 身份读这个文件，新建时留 0600 会直接读不到。私钥在 keybox.xml，不在这儿。
                chmod 644 "$ov" 2>/dev/null
            else
                rm -f "$out" 2>/dev/null
                release_lock "${KL_DIR}/.kl_lock"
                rm -rf "$dir"
                echo "写入失败：$ov" >&2
                return 1
            fi
            ;;
        same) rm -f "$out" 2>/dev/null ;;
        *)
            rm -f "$out" 2>/dev/null
            release_lock "${KL_DIR}/.kl_lock"
            rm -rf "$dir"
            echo "overrides.json 定位失败（不是可写的扁平对象？）：$ov" >&2
            return 1
            ;;
    esac
    release_lock "${KL_DIR}/.kl_lock"
    rm -rf "$dir" 2>/dev/null
    # 上游是 FileObserver 监听 overrides.json → resolveAndPush，不需要重启任何进程
    # （ConfigStore.kt:204-214）。它自家界面也是等 600ms 再回读 /status。
    [ "$saved" = 1 ] && log_info "🧩 WebUI 更新 TEESim overrides.json（$n 项，热生效无需重启）"
    kv saved "$saved"
    kv fields "$n"
    kv apply_note "$([ "$saved" = 1 ] && echo '已写入，TEESim 监听该文件自行热生效，不需要重启' || echo '内容与现有一致，未写入')"
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

# ---------- 修改 Tricky 条目模式 ----------
# 用法：set-mode <包名> <auto|leaf|generate>
cmd_set_mode() {
    local pkg="$1" mode="$2" rc

    require_runnable || return 1
    detect_backend "$MODDIR"
    if [ "$KL_BACKEND" != "tricky" ]; then
        echo "只有 Tricky Store 后端支持条目模式" >&2
        return 1
    fi
    is_pkg_token "$pkg" || { echo "不是合法的包名：$pkg" >&2; return 1; }
    case "$mode" in
        auto|leaf|generate) ;;
        *) echo "模式只能是 auto / leaf / generate" >&2; return 1 ;;
    esac

    webui_lock || return 1
    set_tricky_mode "$pkg" "$mode"
    rc=$?
    release_lock "${KL_DIR}/.kl_lock"

    case "$rc" in
        0) log_info "🧩 WebUI 把 $pkg 的模式改为 $mode"; kv changed 1 ;;
        1) kv changed 0 ;;
        *) echo "写入失败：$TARGET_FILE" >&2; return 1 ;;
    esac
}

# ---------- 后端配置摘要（只读） ----------
# 说明：三个后端各有一套配置，本模块只维护应用名单；这里把与运行相关的少量
#       字段摊开给「后端」页看，不写回任何后端配置文件。
cmd_backend_info() {
    local mdir="" keybox="" ver="" patch="" info="" n="" kb=""
    local kb_exists=0 kb_bytes="" kb_mtime="" kb_sha="" kb_list=""

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

    kv backend "$KL_BACKEND"
    kv backend_name "$(backend_name)"
    kv module_dir "$mdir"

    if [ -f "$mdir/module.prop" ]; then
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
    teesim_st=$(backend_state "$TEESIM_MODULE")
    tricky_st=$(backend_state "$TRICKY_MODULE")
    omk_st=$(backend_state "$OMK_MODULE")

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
    bname=$(backend_name)

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
    local ino uimode hex seed wc

    kv resetprop "$(command -v resetprop >/dev/null 2>&1 && echo 1 || echo 0)"
    kv awk "$(find_awk >/dev/null 2>&1 && echo 1 || echo 0)"
    kv base64 "$(find_base64 >/dev/null 2>&1 && echo 1 || echo 0)"
    ino=$(find_inotify_cmd)
    if [ -z "$ino" ]; then
        kv inotify_mode none
        kv inotify_cmd ""
    else
        kv inotify_mode "${ino%%:*}"
        kv inotify_cmd "${ino#*:}"
    fi
    kv root_user "$(id -u)"
    kv webui_sh "$MODDIR/webui.sh"

    # 设备信息（标题栏与属性页展示）
    prop_now ro.product.model;             kv device "$PROP_NOW"
    prop_now ro.product.brand;             kv brand "$PROP_NOW"
    prop_now ro.build.version.release;     kv android "$PROP_NOW"
    prop_now ro.build.version.sdk;         kv sdk "$PROP_NOW"
    prop_now ro.build.type;                kv build_type "$PROP_NOW"
    prop_now ro.boot.verifiedbootstate;    kv vbstate "$PROP_NOW"

    # ---------- 系统取色 ----------
    # 深浅：以系统算出来的结果为准。管理器的 WebView 有时被钉在浅色，
    #       只看 CSS 的 prefers-color-scheme 会跟系统不一致。
    uimode=$(dumpsys uimode 2>/dev/null | grep -m2 -o -e 'mComputedNightMode=[a-z]*' -e 'mCurUiMode=0x[0-9a-f]*')
    case "$uimode" in
        *mComputedNightMode=true*)  kv sys_dark 1; kv sys_dark_src mComputedNightMode ;;
        *mComputedNightMode=false*) kv sys_dark 0; kv sys_dark_src mComputedNightMode ;;
        *)
            # 没有该字段时退回 uiMode 的 0x20 位（UI_MODE_NIGHT_YES）
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

    # 状态栏真实高度（dp）：管理器注入的 insets 在本机可能报 0 —— 它算的是
    # "安全绘制区"，edge-to-edge 下不等于系统栏高度。界面拿它兜底，否则 22px
    # 的标题行正好钻到状态栏底下（"头被砍一半"）。WebView 的 CSS px 就是 dp，
    # 所以这里直接从 px 换算，不让界面猜 devicePixelRatio。取不到就整条不报。
    sbh=$(dumpsys window displays 2>/dev/null | sed -n 's/.*type=statusBars frame=\[[0-9]*,[0-9]*\]\[[0-9]*,\([0-9]*\)\].*/\1/p' | head -n 1)
    dens=$(wm density 2>/dev/null | sed -n 's/^Physical density: *\([0-9][0-9]*\).*/\1/p')
    [ -n "$dens" ] || dens=$(getprop ro.sf.lcd_density)
    case "$sbh" in ''|*[!0-9]*) sbh=0 ;; esac
    case "$dens" in ''|*[!0-9]*) dens=0 ;; esac
    if [ "$sbh" -gt 0 ] && [ "$dens" -gt 0 ]; then
        kv sys_statusbar_dp $(( (sbh * 160 + dens - 1) / dens ))
    fi

    # 强调色第一优先：SystemUI 运行时生成的 Material You overlay。
    # 那是系统"正在拿来画东西的那套色"，用户手选颜色时它也会被重新生成，
    # 所以比任何 setting 都权威 —— 本机 theme_custom_color 是 null、壁纸是渐变
    # (isColorExtracted=false)，前两个来源都是空的，可实际上 accent1 阶梯明明白白
    # 存在 /data/resource-cache 里（实测本机是青蓝 H≈215，不是 AOSP 默认的那支灰蓝）。
    # 文件格式是 FRRO（定长条目 + varint），shell 里没有能读它的东西；
    # 这里只做「取最新一份 + base64」，解析在界面里做（JS 十几行，且能带自检）。
    b64cmd=$(find_base64 2>/dev/null)
    # 先要 -accent-（里面是完整的 system_accent1 阶梯，界面可以拿"明度必须单调"自检）；
    # 没有才退到 -dynamic-（那是派生出来的语义色，同一支色相但阶梯不全）。
    # 实测本机两个都在，而 -dynamic- 更新一些 —— 按 mtime 取会挑到没有阶梯的那份。
    frro=$(ls -t /data/resource-cache/com.android.systemui-accent-*.frro 2>/dev/null | head -n 1)
    [ -n "$frro" ] || frro=$(ls -t /data/resource-cache/com.android.systemui-dynamic-*.frro 2>/dev/null | head -n 1)
    if [ -n "$b64cmd" ] && [ -n "$frro" ] && [ -r "$frro" ]; then
        enc=$($b64cmd < "$frro" 2>/dev/null | tr -d '\r\n')
        if [ -n "$enc" ]; then
            kv sys_frro "$enc"
            kv sys_frro_src "$frro"
        fi
    fi

    # 次选：用户手选的颜色；再退到壁纸提取色
    seed=$(settings get secure theme_custom_color 2>/dev/null)
    case "$seed" in
        ''|null|null*) seed="" ;;
    esac
    if [ -n "$seed" ]; then
        kv sys_seed_raw "$seed"
        kv sys_seed_src theme_custom_color
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

cmd_clear_log() {
    rm -f "$KL_LOG" "${KL_LOG}.tmp" 2>/dev/null
    log_info "🧹 WebUI 已清空运行日志缓冲"
    kv cleared 1
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
        printf '%s\t%s\t%s\t%s\n' "$name" "$cur" "$expected" "$st"
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
        printf '%s\t%s\t%s\t%s\n' "$name" "$cur" "不含 $needle（则改写为 $replacement）" "$st"
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

# 说明：保存/- 清除并立即应用到本次运行；清除只影响下次开机，本次运行里的
#       digest 要重启才回系统原值（我们只用 resetprop -n，不落持久化）。
cmd_set_boot_hash() {
    local v="$1" applied=0

    require_runnable || return 1
    if [ -z "$v" ] || [ "$v" = "-" ]; then
        set_boot_hash "" || { echo "清除失败：$KL_BOOT_HASH" >&2; return 1; }
        log_info "🧹 WebUI 清除 Verified Boot 哈希（下次开机不再写 digest；本次运行回原值需重启）"
        prop_now ro.boot.vbmeta.digest
        kv saved 0
        kv applied 0
        kv current "$PROP_NOW"
        return 0
    fi

    v=$(printf '%s' "$v" | tr -d '[:space:]' | tr 'A-F' 'a-f')
    boot_hash_valid "$v" || { echo "哈希必须是 64 或 128 位十六进制" >&2; return 1; }
    set_boot_hash "$v" || { echo "写入失败：$KL_BOOT_HASH" >&2; return 1; }
    apply_boot_hash && applied=1
    if [ "$applied" = 1 ]; then
        log_info "🧩 WebUI 设置 Verified Boot 哈希（${#v} 位）并已应用"
    else
        log_warn "⚠️ WebUI 保存 Verified Boot 哈希，但写入后读回不一致"
    fi
    prop_now ro.boot.vbmeta.digest
    kv saved 1
    kv applied "$applied"
    kv current "$PROP_NOW"
}

# 说明：立刻按期望表写一次属性。
#       注意：ro.build.type 等字段已被 Zygote 读进 Java 静态字段的，运行期改写不会
#       回头刷新 —— 界面上要如实提示，彻底生效仍需重启。
cmd_props_apply() {
    local out bad tab

    require_runnable || return 1
    command -v resetprop >/dev/null 2>&1 || { echo "未找到 resetprop 命令" >&2; return 1; }
    # 开关关闭时不做写入：否则界面上写着「已关闭」，点一下就又给伪装回去了
    if props_disabled; then
        echo "属性伪装已关闭，请先在界面上重新开启" >&2
        return 1
    fi

    apply_resetprop
    apply_boot_hash || echo "Verified Boot 哈希写入后读回不一致" >&2
    log_info "🛠 WebUI 触发一次属性伪装（运行期写入；已被应用读取的静态字段不会刷新）"

    # 重新起一次进程读，确保拿到的是写入后的值（本进程的属性快照已经过期）
    out=$(sh "$MODDIR/webui.sh" props)
    # 状态是每行最后一个 TAB 字段。这里用 grep 而不是 sed：\t 转义在 toybox 与
    # busybox 的 sed 里行为不一致，改用 printf 现造制表符来匹配。
    # grep 必须带 -a：属性值含中文与 emoji 时，被当作二进制文件会让 -c 恒为 0。
    tab=$(printf '\t')
    bad=$(printf '%s\n' "$out" | grep -a -c -e "${tab}diff\$" -e "${tab}missing\$" 2>/dev/null)
    kv applied 1
    kv mismatch "${bad:-0}"
    return 0
}

cmd_props_switch() {
    local want="$1"

    if [ "$want" != on ] && [ "$want" != off ]; then
        echo "参数只能是 on 或 off" >&2
        return 1
    fi
    set_props_masking "$want" || { echo "开关文件写入失败：$KL_PROPS_OFF" >&2; return 1; }

    if [ "$want" = off ]; then
        log_info "🛠 WebUI 关闭属性伪装（下次开机起不再写入期望值）"
    else
        log_info "🛠 WebUI 开启属性伪装（下次开机起恢复写入）"
    fi
    kv props_masking "$want"
}

# ---------- 手动同步 ----------
cmd_sync() {
    local rc

    require_runnable || return 1
    detect_backend "$MODDIR"
    webui_lock || return 1
    # 用户显式点了「立即同步」：允许把"读到空已装列表"当成真的清空处理；
    # 后台守护进程不加这个标记（读取失败时宁可不写）。
    KL_EMPTY_OK=1
    run_sync "$PROP_FILE" "${KL_DIR}/.kl_tmp"
    rc=$?
    release_lock "${KL_DIR}/.kl_lock"

    kv rc "$rc"
    kv count "$KL_COUNT"
    # 同步后的新描述（模块详情页与界面共用同一份状态）
    MODULE_PROP_CACHE=""
    mod_prop description; kv description "$MOD_PROP_VALUE"
    [ "$rc" = 2 ] && { echo "同步失败：未能生成或写入应用列表" >&2; return 1; }
    return 0
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
        hit=$(printf '%s\n' $want | awk -v c="$cache" '
            BEGIN { while ((getline l < c) > 0) { split(l, a, "\t"); m[a[1]] = l } }
            ($1 in m) { print m[$1] }')
        hitp=" $(printf '%s\n' "$hit" | cut -f1 | tr '\n' ' ') "
        nop=" $(printf '%s\n' "$hit" | awk -F'\t' '$3 == "" { print $1 }' | tr '\n' ' ') "
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
        printf '%s\n%s\n' "$rows" "$res2" | awk -F'\t' -v want="$want" '
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
  keybox-save <b64>      替换当前后端的 keybox.xml（base64 XML）
  sync                   立即同步一次应用列表
  contract               自报命令层契约号与命令清单
  excluded               列出被人为排除（手动删除）的包名
EOF
}

case "$CMD" in
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
    restore-apps) cmd_restore_apps "$ARG" ;;
    remove-apps) cmd_remove_apps "$ARG" ;;
    sync)        cmd_sync ;;
    help)        cmd_help ;;
    *) echo "未知命令：$CMD（可用：sh webui.sh help）" >&2; exit 1 ;;
esac
