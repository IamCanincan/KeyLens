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

# ---------- 目标条目语法 ----------
# 三个后端的 apps / target.txt / scoop 对「一个条目」的写法并不相同：
#   tricky  pkg / pkg? / pkg!
#   teesim  pkg / pkg@用户 / uid:数字
#   omk     pkg
# 界面与同步都要按「基础包名」判断一个应用是否已在名单里，同时把原 token
# 原样写回，否则 ?/! 与 @用户 会在每次同步时被当成新包名重复加入或误删。
# 用法：is_pkg_token <名字>；比 is_pkg_name 多允许每段以下划线开头（上游允许）
is_pkg_token() {
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
            [A-Za-z_]*) ;;
            *) IFS=$oldifs; return 1 ;;
        esac
    done
    IFS=$oldifs
    return 0
}

# 说明：校验界面传来的目标条目 token（按当前后端）。只允许该后端真实支持的形状。
# 用法：is_target_entry <token>
is_target_entry() {
    local t="${1:-}" pkg rest

    case "${KL_BACKEND:-}" in
        tricky)
            case "$t" in
                *\?) pkg="${t%[?]}" ;;
                *\!) pkg="${t%[!]}" ;;
                *)   pkg="$t" ;;
            esac
            is_pkg_token "$pkg"
            ;;
        teesim)
            case "$t" in
                uid:*)
                    rest="${t#uid:}"
                    case "$rest" in
                        ''|*[!0-9]*) return 1 ;;
                    esac
                    return 0
                    ;;
                *@*)
                    pkg="${t%@*}"
                    rest="${t##*@}"
                    case "$rest" in
                        ''|*[!0-9]*) return 1 ;;
                    esac
                    is_pkg_token "$pkg"
                    ;;
                *) is_pkg_token "$t" ;;
            esac
            ;;
        *) is_pkg_token "$t" ;;
    esac
}

# 说明：把目标条目文件（可能含 ?/!、@用户、uid:）转成基础包名。uid: 无包名，
#       直接丢弃；找不到解析脚本时原样输出（只有纯包名列表时才安全）。
# 用法：entries_to_bases <文件>
entries_to_bases() {
    local f="$1" patch="${KL_PATCH:-}" helper

    [ -f "$f" ] || return 0
    helper="${patch%/*}/entry_base.awk"
    if [ -n "$patch" ] && [ -f "$helper" ]; then
        "${AWK_CMD:-awk}" -v backend="${KL_BACKEND:-tricky}" -f "$helper" "$f"
    else
        sed '/^[[:space:]]*$/d' "$f"
    fi
}

# ---------- 应用列表生成（快照差分） ----------
# 说明：was = 上一次成功同步时见到的已装集合（.kl_installed_last）。
#   首次运行（没有基线）时 was 为空，等于把所有已装应用都当"新装"加一遍；
#   只有"目标文件为空 + 没有基线"时才加种子。
#   **OhMyKeymint 例外**：首次接入且 scoop 已有内容时沿用现有名单（不批量加入
#   已装应用），只把当前已装记成基线，之后的新装照常加入。
#   基线只在写成功后提交，失败不推进 —— 那次卸载事件下次仍会被看见。
# 用法：build_app_list <输出文件>
build_app_list() {
    local tmp="$1"
    local apps_raw user_list cur base seed adopt _kl_cur

    mkdir -p "$KL_DIR" 2>/dev/null

    apps_raw=$(cmd package list packages -3 --user all 2>/dev/null || pm list packages -3 2>/dev/null)
    user_list=$(printf '%s\n' "$apps_raw" | sed -n 's/^package://p' | sed '/^$/d' | sort -u)
    # 现名单必须**带着退码**一起拿：以前写成 `cur=$(current_target_apps 2>/dev/null | …)`，
    # 命令替换只看到管道最后的 sort —— awk 缺参照的退码 2 和那句报错一起被吞，
    # 于是"读不到"在这里变成"名单是空的"，而同步下一步就是把这份"空"写回目标文件。
    _kl_cur=$(current_target_apps) || { rm -f "$tmp" 2>/dev/null; return 2; }
    cur=$(printf '%s\n' "$_kl_cur" | sed '/^[[:space:]]*$/d' | sort -u)

    # 已装列表读空但基线非空：更像是一次读取失败，而不是真的把应用全卸了。
    # 自动同步放弃（不写、不提交基线）；界面「立即同步」/管理器「操作」按钮会
    # 显式设 KL_EMPTY_OK=1 强制按当前已装处理。
    if [ -z "$user_list" ] && [ -s "$ST_INSTALLED" ] && [ "${KL_EMPTY_OK:-0}" != 1 ]; then
        rm -f "$tmp" 2>/dev/null
        return 1
    fi

    # 首次安装：目标文件空 + 没有基线
    seed=""
    if [ ! -f "$ST_INSTALLED" ] && [ -z "$cur" ]; then
        # 空格分隔 → 一行一个：write_set 与 awk 都是按行读的，
        # 直接传 "a b c" 会变成**一行**三个包名（实测输出 123 行而不是 125）
        seed=$(printf "%s
" $SEED_PKGS)
    fi

    # OhMyKeymint 首次接入：scoop 已有内容时沿用现有名单，不把已装应用灌进去；
    # 以后的新装照常加入。其它后端维持原来的"首次全部加入"。
    adopt=0
    if [ "${KL_BACKEND:-}" = "omk" ] && [ ! -f "$ST_INSTALLED" ] && [ -n "$cur" ]; then
        adopt=1
    fi

    base="${tmp}.state"
    mkdir -p "$base" 2>/dev/null
    write_set() { if [ -n "$2" ]; then printf '%s\n' "$2" | sed '/^$/d' | sort -u > "$1"; else : > "$1"; fi; }
    write_set "$base/inst" "$user_list"
    write_set "$base/cur" "$cur"
    write_set "$base/seed" "$seed"
    : > "$base/was"; [ -s "$ST_INSTALLED" ] && cp -f "$ST_INSTALLED" "$base/was"

    # 一次 awk 做完全部集合运算。cur 里可能带后端语法（Tricky 的 ?/!、
    # TEESim 的 @用户/uid:），卸载判断与新装判重都按基础包名做，写回仍用
    # 原 token —— 否则卸载一个包时它的变体会留在名单里，新装时又会重复加入。
    # 配置解析不了时 cur 为空，这里会算出"删掉所有卸载过的"；但那样 teesim.awk
    # 也定位不到 apps 数组、写入直接返回 2，基线不会提交 —— 由写入器兜底，
    # 不在这里靠读取命令的退码猜。
    ${AWK_CMD:-awk} -v adopt="$adopt" -v backend="${KL_BACKEND:-tricky}" '
        FILENAME == ARGV[1] { inst[$0] = 1; next }
        FILENAME == ARGV[2] {
            tok = $0; b = tok
            if (backend == "tricky") {
                if (b ~ /[?!]$/) b = substr(b, 1, length(b) - 1)
            } else if (backend == "teesim") {
                if (b ~ /^uid:/) b = ""
                else sub(/@[0-9]+$/, "", b)
            }
            cur[++nc] = tok; curbase[tok] = b
            next
        }
        FILENAME == ARGV[3] { seed[$0] = 1; next }
        FILENAME == ARGV[4] { was[$0] = 1; next }
        END {
            for (p in was) if (!(p in inst)) gone[p] = 1   # 这一轮之前卸载的
            for (i = 1; i <= nc; i++) {
                tok = cur[i]; b = curbase[tok]
                # 包名已卸载：连同它的 ?/! 或 @用户 变体一起移除；uid: 无法反查，保留
                if (b != "" && (b in gone)) continue
                keep[tok] = 1
                if (b != "") keepbase[b] = 1
            }
            if (adopt != 1) {
                for (p in inst)
                    if (!(p in was) && !(p in keepbase)) { keep[p] = 1; keepbase[p] = 1 }
            }
            for (p in seed)
                if (!(p in keepbase)) { keep[p] = 1; keepbase[p] = 1 }
            for (p in keep) if (p != "") print p
        }
    ' "$base/inst" "$base/cur" "$base/seed" "$base/was" \
        | sort -u | sed '/^$/d' > "$tmp" 2>/dev/null
    rm -rf "$base" 2>/dev/null

    KL_COUNT=$(wc -l < "$tmp" 2>/dev/null | tr -d ' ')

    # 只在写成功后由 sync_* 提交，失败不推进。权限显式收成 600：
    # WebUI 经管理器 exec 出来的 umask 可能是 000（实测生成过 666 的状态文件）。
    printf '%s\n' "$user_list" > "$ST_INSTALLED_NEW" 2>/dev/null
    chmod 600 "$ST_INSTALLED_NEW" 2>/dev/null

    # 「曾经纳入过」的并集：排除判定用它。OhMyKeymint 首次接入时基线是全部
    # 已装、但 scoop 可能只有几条，用基线会把从未纳入的应用误标成"已排除"。
    # 这里按基础包名入册：Tricky 的 pkg? / TEESim 的 pkg@10 都归到 pkg，
    # 否则同一个应用换个模式就会被当成另一个应用。
    { cat "$ST_EVER" 2>/dev/null; entries_to_bases "$tmp" 2>/dev/null; } \
        | sed '/^[[:space:]]*$/d' | sort -u > "${ST_EVER_NEW}.tmp" 2>/dev/null \
        && mv -f "${ST_EVER_NEW}.tmp" "$ST_EVER_NEW" 2>/dev/null
    chmod 600 "$ST_EVER_NEW" 2>/dev/null
    return 0
}

# ---------- 「已排除」= 已装、曾经在名单里、但现在文件里没有 ----------
# 说明：用 ever（.kl_ever，历次写进去的并集）判断"曾经纳入"，而不是已装基线：
#       OhMyKeymint 首次接入沿用现有 scoop 时，基线包含全部已装，用基线会把
#       从未纳入的应用误标成"已排除"。
#       三份集合都落临时文件再交给 awk：toybox awk 的 -v 不接受换行，
#       把多行字符串当参数传会直接报 "newline in string"（设备上实测）。
# 用法：excluded_apps
excluded_apps() {
    local inst cur base

    # 「已排除」的宇宙是**全部已装**，不是 `-3`：系统应用现在也能进名单（§5.18），
    #   把它移出之后必须在这档里找得回来 —— 用 -3 就永远不出现，计数也不涨。
    #   同步的"新装"口径仍然按 `-3`（那是有意的，见本文件头部），两件事别混。
    inst=$(cmd package list packages --user all 2>/dev/null || pm list packages 2>/dev/null)
    inst=$(printf '%s\n' "$inst" | sed -n 's/^package://p' | sed '/^$/d')
    # 读不到就报错，不交空表：空表在界面上是「没有排除过任何应用」，那是另一句假话
    cur=$(current_target_apps 2>/dev/null) || return 2

    # 只读命令不创建状态目录；没有 ever 时排除表就是空
    [ -d "$KL_DIR" ] || return 0
    base="${KL_DIR}/.kl_excl.$$"
    mkdir -p "$base" 2>/dev/null || return 0
    printf '%s\n' "$inst" | sed '/^[[:space:]]*$/d' | sort -u > "$base/inst" 2>/dev/null
    printf '%s\n' "$cur"  | sed '/^[[:space:]]*$/d' > "$base/cur" 2>/dev/null
    # 目标里可能有 pkg? / pkg@10 / uid:，排除判定只按基础包名比
    entries_to_bases "$base/cur" | sort -u > "$base/curbase" 2>/dev/null
    sed '/^[[:space:]]*$/d' "$ST_EVER" > "$base/ever" 2>/dev/null || : > "$base/ever"

    ${AWK_CMD:-awk} '
        FILENAME == ARGV[1] { cur[$0] = 1; next }
        FILENAME == ARGV[2] { ever[$0] = 1; next }
        {
            p = $0; sub(/\r$/, "", p)
            if (p != "" && (p in ever) && !(p in cur)) print p
        }
    ' "$base/curbase" "$base/ever" "$base/inst" | sort -u
    rm -rf "$base" 2>/dev/null
}

# ---------- 旧版本状态清理 ----------
# 说明：墓碑模型的遗留文件，升级后不再使用。成功同步一次就删掉；
#       失败时保留，便于回退旧版本时仍读得到。
# 用法：drop_legacy_state
drop_legacy_state() {
    rm -f "$KL_DIR/.kl_written_last" "$KL_DIR/.kl_written.new" \
          "$KL_DIR/.kl_removed" "$KL_DIR/.kl_removed.new" 2>/dev/null
}
