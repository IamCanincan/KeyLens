#!/system/bin/sh
#=============================================================================
# lib/applist.sh - 目标名单生成（快照差分增量）
#
# 名单只有目标文件本身（config.json 的 profiles.default.apps / target.txt）。
# 没有第二份"常驻列表"：你自己的增删就是名单。每轮同步只做三件事：
#   加入  上一轮之后新安装的应用
#   删除  上一轮之后卸载的应用
#   保留  文件里其余的一切（手工加的、手工删的，都不动）
#
# 为什么不再需要墓碑：加入的来源是「新装」(inst − was)，不是「缺了就补」。
# 你手动删掉的包仍然装着、但不在"新装"里，所以结构上就不会被加回来；
# 卸载后重装会重新进入"新装"，自然回到名单。
#=============================================================================

# 首次安装的种子。谷歌三件套是**系统应用**，`pm list packages -3` 看不到它们，
# 不加进来就永远进不了名单。只在"目标文件还是空的、而且没有任何基线"时用一次；
# 之后你从名单里删掉它们，也不会再被加回来（和其它包一样按手动删除处理）。
SEED_PKGS="com.android.vending com.google.android.gms com.google.android.gsf"

# ---------- 包名形态校验 ----------
# 说明：给"界面把某个包名写回文件"这类入口用。只接受字母/数字/下划线与点，
#       至少两段、每段以字母开头（Android 包名规则），挡掉空串、路径与怪字符。
# 用法：is_pkg_name <名字>
is_pkg_name() {
    local p="${1:-}" seg oldifs

    case "$p" in
        ''|.*|*.|*..*|*[!A-Za-z0-9_.]*) return 1 ;;
    esac
    case "$p" in
        *.*) ;;
        *)   return 1 ;;
    esac

    oldifs=$IFS
    IFS=.
    for seg in $p; do
        case "$seg" in
            [A-Za-z]*) ;;
            *) IFS=$oldifs; return 1 ;;
        esac
    done
    IFS=$oldifs
    return 0
}

# ---------- 应用列表生成（快照差分） ----------
# 说明：was = 上一次成功同步时见到的已装集合（.ts_installed_last）。
#   首次运行（没有基线）时 was 为空，等于把所有已装应用都当"新装"加一遍；
#   只有"目标文件为空 + 没有基线"时才加种子。
#   基线只在写成功后提交，失败不推进 —— 那次卸载事件下次仍会被看见。
# 用法：build_app_list <输出文件>
build_app_list() {
    local tmp="$1"
    local apps_raw user_list cur base seed

    mkdir -p "$TAA_DIR" 2>/dev/null

    apps_raw=$(cmd package list packages -3 --user all 2>/dev/null || pm list packages -3 2>/dev/null)
    user_list=$(printf '%s\n' "$apps_raw" | sed -n 's/^package://p' | sed '/^$/d' | sort -u)
    cur=$(current_target_apps 2>/dev/null | sed '/^[[:space:]]*$/d' | sort -u)

    # 首次安装：目标文件空 + 没有基线
    seed=""
    if [ ! -f "$ST_INSTALLED" ] && [ -z "$cur" ]; then
        # 空格分隔 → 一行一个：write_set 与 awk 都是按行读的，
        # 直接传 "a b c" 会变成**一行**三个包名（实测输出 123 行而不是 125）
        seed=$(printf "%s
" $SEED_PKGS)
    fi

    base="${tmp}.state"
    mkdir -p "$base" 2>/dev/null
    write_set() { if [ -n "$2" ]; then printf '%s\n' "$2" | sed '/^$/d' | sort -u > "$1"; else : > "$1"; fi; }
    write_set "$base/inst" "$user_list"
    write_set "$base/cur" "$cur"
    write_set "$base/seed" "$seed"
    : > "$base/was"; [ -s "$ST_INSTALLED" ] && cp -f "$ST_INSTALLED" "$base/was"

    # 一次 awk 做完全部集合运算。配置解析不了时 cur 为空，这里会算出
    # "删掉所有卸载过的"；但那样 teesim.awk 也定位不到 apps 数组、写入直接
    # 返回 2，基线不会提交 —— 由写入器兜底，不在这里靠读取命令的退码猜
    awk '
        FILENAME == ARGV[1] { inst[$0] = 1; next }
        FILENAME == ARGV[2] { cur[$0] = 1; next }
        FILENAME == ARGV[3] { seed[$0] = 1; next }
        FILENAME == ARGV[4] { was[$0] = 1; next }
        END {
            for (p in was) if (!(p in inst)) gone[p] = 1   # 这一轮之前卸载的
            for (p in cur)  keep[p] = 1                     # 手工加的、手工删的，原样
            for (p in inst) if (!(p in was)) keep[p] = 1    # 新装
            for (p in seed) keep[p] = 1
            for (p in gone) delete keep[p]
            for (p in keep) if (p != "") print p
        }
    ' "$base/inst" "$base/cur" "$base/seed" "$base/was" \
        | sort -u | sed '/^$/d' > "$tmp" 2>/dev/null
    rm -rf "$base" 2>/dev/null

    TAA_COUNT=$(wc -l < "$tmp" 2>/dev/null | tr -d ' ')

    # 只在写成功后由 sync_* 提交，失败不推进。权限显式收成 600：
    # WebUI 经管理器 exec 出来的 umask 可能是 000（实测生成过 666 的状态文件）。
    printf '%s\n' "$user_list" > "$ST_INSTALLED_NEW" 2>/dev/null
    chmod 600 "$ST_INSTALLED_NEW" 2>/dev/null
}

# ---------- 「已排除」= 已装、有基线、但目标文件里没有 ----------
# 说明：同步过一次之后，已装应用不在文件里就只可能是你手动删的。
#       基线之前从未纳入的包不算（那时 was 里还没有它）。
#       三份集合都落临时文件再交给 awk：toybox awk 的 -v 不接受换行，
#       把多行字符串当参数传会直接报 "newline in string"（设备上实测）。
# 用法：excluded_apps
excluded_apps() {
    local inst cur base

    inst=$(cmd package list packages -3 --user all 2>/dev/null || pm list packages -3 2>/dev/null)
    inst=$(printf '%s\n' "$inst" | sed -n 's/^package://p' | sed '/^$/d')
    cur=$(current_target_apps 2>/dev/null)

    # 只读命令不创建后端目录：目录不存在时不会有基线，排除表就是空
    [ -d "$TAA_DIR" ] || return 0
    base="${TAA_DIR}/.ts_excl.$$"
    mkdir -p "$base" 2>/dev/null || return 0
    printf '%s\n' "$inst" | sed '/^[[:space:]]*$/d' | sort -u > "$base/inst" 2>/dev/null
    printf '%s\n' "$cur"  | sed '/^[[:space:]]*$/d' | sort -u > "$base/cur" 2>/dev/null
    sed '/^[[:space:]]*$/d' "$ST_INSTALLED" > "$base/was" 2>/dev/null || : > "$base/was"

    awk '
        FILENAME == ARGV[1] { cur[$0] = 1; next }
        FILENAME == ARGV[2] { was[$0] = 1; next }
        {
            p = $0; sub(/\r$/, "", p)
            if (p != "" && (p in was) && !(p in cur)) print p
        }
    ' "$base/cur" "$base/was" "$base/inst" | sort -u
    rm -rf "$base" 2>/dev/null
}

# ---------- 旧版本状态清理 ----------
# 说明：墓碑模型的遗留文件，升级后不再使用。成功同步一次就删掉；
#       失败时保留，便于回退旧版本时仍读得到。
# 用法：drop_legacy_state
drop_legacy_state() {
    rm -f "$TAA_DIR/.ts_written_last" "$TAA_DIR/.ts_written.new" \
          "$TAA_DIR/.ts_removed" "$TAA_DIR/.ts_removed.new" 2>/dev/null
}
