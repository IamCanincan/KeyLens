#!/system/bin/sh
#=============================================================================
# lib/applist.sh - 目标名单生成（增量 + 手动删除尊重）
#
# 名单**只有目标文件本身**（config.json 的 profiles.default.apps / target.txt）。
# 没有第二份"常驻列表"了：你自己的增删就是名单，同步只在上面应用增量。
#=============================================================================

# 首次安装的种子。谷歌三件套是**系统应用**，`pm list packages -3` 看不到它们，
# 不加进来就永远进不了名单。只在"目标文件还是空的、而且没有任何基线"时用一次；
# 之后你从名单里删掉它们，也不会再被加回来（和别的条目一样按手动删除处理）。
SEED_PKGS="com.android.vending com.google.android.gms com.google.android.gsf"

# ---------- 应用列表生成（增量 + 手动删除尊重） ----------
# 说明：在**当前目标文件的基础上**只应用增量：
#   保留  文件里现在的一切（手工加的条目天然保留）
#   加入  当前已装的全部（首次安装再加种子）
#   删除  「上次装了、这次没了」的
#   **手动删除＝排除**：我们上次写进去、这次文件里没有了的条目，记进墓碑
#     （.ts_removed）并且下次不再加回来。墓碑在三种情况下自动撤销：
#       · 又出现在文件里（你把它加回去了）
#       · 那个应用被卸载过（这样以后重装就算"新安装"，会重新加入）
#   没有上次状态（首次运行/刚升级）时不删也不记墓碑，只做并集。
# 用法：build_app_list <输出文件>
build_app_list() {
    local tmp="$1"
    local apps_raw user_list cur base tn seed

    mkdir -p "$TAA_DIR" 2>/dev/null

    apps_raw=$(cmd package list packages -3 --user all 2>/dev/null || pm list packages -3 2>/dev/null)
    user_list=$(printf '%s\n' "$apps_raw" | sed -n 's/^package://p' | sed '/^$/d' | sort -u)
    cur=$(current_target_apps 2>/dev/null | sed '/^[[:space:]]*$/d' | sort -u)

    # 首次安装：目标文件空 + 没有基线
    seed=""
    if [ ! -f "$ST_WRITTEN" ] && [ -z "$cur" ]; then
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
    : > "$base/was";    [ -s "$ST_INSTALLED" ] && cp -f "$ST_INSTALLED" "$base/was"
    : > "$base/wrote";  [ -s "$ST_WRITTEN" ] && cp -f "$ST_WRITTEN" "$base/wrote"
    : > "$base/tomb";   [ -s "$ST_REMOVED" ] && cp -f "$ST_REMOVED" "$base/tomb"

    # 一次 awk 做完全部集合运算。墓碑写到单独的文件（$tn），由 sync_* 在
    # 写入成功后提交 —— 与列表本身一样，失败不推进。
    tn="$ST_REMOVED_NEW"
    : > "$tn" 2>/dev/null
    awk -v tfile="$tn" '
        FILENAME == ARGV[1] { inst[$0] = 1; next }
        FILENAME == ARGV[2] { cur[$0] = 1; next }
        FILENAME == ARGV[3] { seed[$0] = 1; next }
        FILENAME == ARGV[4] { was[$0] = 1; next }
        FILENAME == ARGV[5] { wrote[$0] = 1; next }
        FILENAME == ARGV[6] { tomb[$0] = 1; next }
        END {
            # 我们上次写过、这次文件里没有 => 你手动删的。
            # 配置解析不了时这里会算出"全删"，但那样 teesim.awk 也定位不到 apps
            # 数组、写入直接返回 2，状态与墓碑都不会提交 —— 由写入器兜底，
            # 不在这里靠读取命令的退码猜（实测那个退码并不可靠）
            for (p in wrote) if (p != "" && !(p in cur)) tomb[p] = 1
            # 又出现在文件里 => 撤销标记
            for (p in cur) delete tomb[p]
            # 卸载过 => 撤销标记（重装应算新安装，重新加入）
            for (p in was) if (!(p in inst)) delete tomb[p]

            for (p in cur)   keep[p] = 1
            for (p in inst)  keep[p] = 1
            for (p in seed)  keep[p] = 1
            for (p in tomb)  delete keep[p]                       # 手动删除=排除
            for (p in was)   if (!(p in inst)) delete keep[p]      # 卸载

            for (p in keep) if (p != "") print p
            for (p in tomb) if (p != "") print p > tfile
        }
    ' "$base/inst" "$base/cur" "$base/seed" "$base/was" "$base/wrote" "$base/tomb" \
        | sort -u | sed '/^$/d' > "$tmp" 2>/dev/null
    sort -u "$tn" -o "$tn" 2>/dev/null || { sort -u "$tn" > "$tn.s" 2>/dev/null && mv -f "$tn.s" "$tn"; }
    rm -rf "$base" 2>/dev/null

    TAA_COUNT=$(wc -l < "$tmp" 2>/dev/null | tr -d ' ')

    # 这两份只在写成功后由 sync_* 提交，失败不推进
    printf '%s\n' "$user_list" > "$ST_INSTALLED_NEW" 2>/dev/null
    cp -f "$tmp" "$ST_WRITTEN_NEW" 2>/dev/null
}
