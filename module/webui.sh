#!/system/bin/sh
#=============================================================================
# webui.sh - WebUI 命令层（由管理器 WebView 经 root shell 调用）
#
# 用法：sh /data/adb/modules/ts-auto-add/webui.sh <命令> [参数]
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
TAA_API=2
TAA_COMMANDS="status env targets apps icons log clear-log props props-apply \
props-on props-off boot-hash props-boot-hash restore-app restore-apps sync help contract excluded"

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
        echo "$TAA_CONFLICT_MSG" >&2
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
    acquire_lock "${TAA_DIR}/.ts_lock"
    lock_rc=$?
    LOCK_TIMEOUT="$timeout"
    if [ "$lock_rc" != 0 ]; then
        echo "守护进程正在写入，请几秒后再试" >&2
        return 1
    fi
    return 0
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
  is_pkg_name "$pkg" || { echo "不是合法的包名：$pkg" >&2; return 1; }

  detect_backend "$MODDIR"
  webui_lock || return 1
  add_target_app "$pkg"
  rc=$?
  release_lock "${TAA_DIR}/.ts_lock"

  case "$rc" in
    0)
      # 恢复后顺手把模块描述里的条数刷新，管理器里不用等下一轮同步
      TAA_COUNT=$(current_target_apps 2>/dev/null | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
      [ "${TAA_COUNT:-0}" -gt 0 ] 2>/dev/null && update_module_desc "$PROP_FILE" "$TAA_COUNT"
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
  file="${TAA_DIR}/.ts_restore.req.$$"
  : > "$file" 2>/dev/null || { echo "无法创建临时文件：$file" >&2; return 1; }

  oldifs=$IFS
  IFS=','
  for pkg in $raw; do
    [ -n "$pkg" ] || continue
    if ! is_pkg_name "$pkg"; then
      IFS=$oldifs
      rm -f "$file" 2>/dev/null
      echo "不是合法的包名：$pkg" >&2
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
  release_lock "${TAA_DIR}/.ts_lock"
  rm -f "$file" 2>/dev/null

  case "$rc" in
    0)
      TAA_COUNT=$(current_target_apps 2>/dev/null | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
      [ "${TAA_COUNT:-0}" -gt 0 ] 2>/dev/null && update_module_desc "$PROP_FILE" "$TAA_COUNT"
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

cmd_contract() {
  kv api "$TAA_API"
  kv commands "$TAA_COMMANDS"
}

cmd_status() {
    local desc state masking ino p alive lines bytes mtime bname conflict
    local teesim_en tricky_en target_exists target_writable

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

    teesim_en=0; tricky_en=0
    teesim_active && teesim_en=1
    tricky_active && tricky_en=1

    target_exists=0; target_writable=0
    if [ -f "$TARGET_FILE" ]; then
        target_exists=1
        test -w "$TARGET_FILE" && target_writable=1
    elif [ -d "$TAA_DIR" ] && test -w "$TAA_DIR"; then
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
    kv backend "$TAA_BACKEND"
    kv backend_name "$bname"
    kv conflict "$conflict"
    kv teesim_enabled "$teesim_en"
    kv tricky_enabled "$tricky_en"
    kv data_dir "$TAA_DIR"
    kv target_file "$TARGET_FILE"
    kv target_exists "$target_exists"
    kv target_writable "$target_writable"
    kv target_mtime "$mtime"

    if props_disabled; then masking=off; else masking=on; fi
    kv props_masking "$masking"
    kv props_off_file "$TAA_PROPS_OFF"

    # 守护进程：pids 文件里仍存活的进程数
    alive=0; p=""
    if [ -f "${TAA_DIR}/.ts_daemon_pids.list" ]; then
        while read -r p; do
            [ -n "$p" ] && kill -0 "$p" 2>/dev/null && alive=$((alive + 1))
        done < "${TAA_DIR}/.ts_daemon_pids.list"
    fi
    kv daemon_alive "$alive"

    # 行数与字节数一次 wc 拿到（-lc 的输出顺序为「行 字节」）
    lines=""; bytes=""
    if [ -f "$TAA_LOG" ]; then
        set -- $(wc -lc < "$TAA_LOG" 2>/dev/null)
        lines="${1:-}"; bytes="${2:-}"
    fi
    kv log_file "$TAA_LOG"
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

    # ---------- 系统字体 ----------
    # Chromium / WebView 在 Android 上有自己的一套字体映射（sans-serif 默认就是 Roboto），
    # 它**不读框架的 config_bodyFontFamily**。所以 ROM 换了系统字体时，
    # 界面会悄悄退回 Roboto —— 本机就是这一种：启用了
    # org.lineageos.overlay.font.googlesansflex，系统各处是 Google Sans Flex，
    # 而这个 WebUI 是 Roboto。只能把字体名显式写进 CSS，名字从设备上读，不写死。
    # 读法：找出启用的字体 overlay → 从它的 resources.arsc 里取出候选族名
    #       → 再拿字体注册表验一遍。验不过就当没有，退回 system-ui。
    fontpkg=$(cmd overlay list 2>/dev/null | sed -n 's/^\[x\] \(.*font.*\)$/\1/p' | head -n 1)
    sys_font=""
    if [ -n "$fontpkg" ]; then
        fontapk=$(pm path "$fontpkg" 2>/dev/null | sed -n '1s/^package://p')
        if [ -n "$fontapk" ] && [ -r "$fontapk" ]; then
            # 注册表里的族名当成一个"白名单正则"，一次 grep 同时完成「取候选 + 验注册」。
            # 不这么做的话：resources.arsc 的字符串池是 UTF-16，直接 grep -o 会吐出
            # amily / edium 这类碎片（实测），而逐个族名去 grep 又要 160 次 fork。
            reg=$(cat /product/etc/fonts_customization.xml /system/etc/fonts.xml 2>/dev/null \
                  | grep -o 'name="[a-z0-9][a-z0-9-]*"' | sed 's/name="//;s/"//' \
                  | sort -u | tr '\n' '|' | sed 's/|$//')
            if [ -n "$reg" ]; then
                # 先 tr -d 把 UTF-16 的 NUL 去掉，否则族名会被拆成单字节碎片。
                # 再排掉字重/用途别名：overlay 里同时写着 config_bodyFontFamily 与
                # config_bodyFontFamilyMedium，两个族名都在注册表里，而 -medium 更长 ——
                # 不排的话"取最长"会挑到 medium（实测踩过），那是 500 字重不是正文。
                sys_font=$(unzip -p "$fontapk" resources.arsc 2>/dev/null | tr -d '\000' \
                           | grep -a -o -E "($reg)" 2>/dev/null \
                           | grep -Ev -- '-(medium|bold|black|thin|light|regular|semibold|italic|clock|condensed|text)$' \
                           | sort -u \
                           | awk '{ if (length($0) > m) { m = length($0); s = $0 } } END { print s }')
            fi
        fi
    fi
    # 族名写进 CSS 未必生效：Chromium 有自己的字体映射表，实测把族名写进去界面仍是 Roboto。
    # 所以补一条不依赖名字的路 —— 按字体注册表找到那个 ttf，拷进 webroot，
    # 由界面用 @font-face 直接加载。拷一次就够：大小一致就跳过，别每次开界面都搬 4MB。
    sys_font_file=""
    if [ -n "$sys_font" ]; then
        ff=$(awk -v fam="name=\"$sys_font\"" '
            index($0, fam) { hit = 1; next }
            hit && match($0, /[A-Za-z0-9_.-]+\.(ttf|otf)/) { print substr($0, RSTART, RLENGTH); exit }
        ' /product/etc/fonts_customization.xml 2>/dev/null)
        [ -n "$ff" ] || ff=$(awk -v fam="name=\"$sys_font\"" '
            index($0, fam) { hit = 1; next }
            hit && match($0, /[A-Za-z0-9_.-]+\.(ttf|otf)/) { print substr($0, RSTART, RLENGTH); exit }
        ' /system/etc/fonts.xml 2>/dev/null)
        src=""
        for d in /product/fonts /system/fonts; do
            if [ -n "$ff" ] && [ -f "$d/$ff" ]; then src="$d/$ff"; break; fi
        done
        if [ -n "$src" ]; then
            dst="$MODDIR/webroot/fonts/sys.ttf"
            mkdir -p "$MODDIR/webroot/fonts" 2>/dev/null
            if [ ! -f "$dst" ] || [ "$(wc -c < "$src")" != "$(wc -c < "$dst")" ]; then
                cp -f "$src" "$dst" 2>/dev/null \
                    && chmod 644 "$dst" 2>/dev/null \
                    && chcon u:object_r:system_file:s0 "$dst" 2>/dev/null
            fi
            [ -s "$dst" ] && sys_font_file="fonts/sys.ttf"
        fi
    fi
    kv sys_font_file "$sys_font_file"

    # 这个值会进 CSS：上面是「注册表原样取出的名字」，字符集已被
    # grep -o 'name="[a-z0-9][a-z0-9-]*"' 限死，引号与分号进不来。
    kv sys_font "$sys_font"
    kv sys_font_pkg "$fontpkg"

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
    if [ -f "$TAA_LOG" ]; then
        tail -n "$n" "$TAA_LOG" 2>/dev/null
        return 0
    fi
    # 缓冲不存在时回退 logcat（重启即清空，仅作兜底）
    logcat -d -s TS-AUTO 2>/dev/null | tail -n "$n"
}

cmd_clear_log() {
    rm -f "$TAA_LOG" "${TAA_LOG}.tmp" 2>/dev/null
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

    [ -f "$TAA_BOOT_HASH" ] && raw=$(tr -d '[:space:]' < "$TAA_BOOT_HASH" 2>/dev/null | tr 'A-F' 'a-f')
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
        set_boot_hash "" || { echo "清除失败：$TAA_BOOT_HASH" >&2; return 1; }
        log_info "🧹 WebUI 清除 Verified Boot 哈希（下次开机不再写 digest；本次运行回原值需重启）"
        prop_now ro.boot.vbmeta.digest
        kv saved 0
        kv applied 0
        kv current "$PROP_NOW"
        return 0
    fi

    v=$(printf '%s' "$v" | tr -d '[:space:]' | tr 'A-F' 'a-f')
    boot_hash_valid "$v" || { echo "哈希必须是 64 或 128 位十六进制" >&2; return 1; }
    set_boot_hash "$v" || { echo "写入失败：$TAA_BOOT_HASH" >&2; return 1; }
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
    set_props_masking "$want" || { echo "开关文件写入失败：$TAA_PROPS_OFF" >&2; return 1; }

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
    TAA_EMPTY_OK=1
    run_sync "$PROP_FILE" "${TAA_DIR}/.ts_tmp"
    rc=$?
    release_lock "${TAA_DIR}/.ts_lock"

    kv rc "$rc"
    kv count "$TAA_COUNT"
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
  targets                当前生效的应用列表
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
    sync)        cmd_sync ;;
    help)        cmd_help ;;
    *) echo "未知命令：$CMD（可用：sh webui.sh help）" >&2; exit 1 ;;
esac
