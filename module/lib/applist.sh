#!/system/bin/sh
#=============================================================================
# lib/applist.sh - 常驻列表与应用列表生成
#
# rules.txt 规则：
#   每行一个包名；以 # 开头的行视为注释；空行忽略；行首行尾空白会去掉。
#=============================================================================

# ---------- 常驻列表 ----------
# 说明：rules.txt 不存在时写入默认内容（Google 三件套 + 中文说明注释）
# 用法：ensure_rules_file <rules.txt 路径>
ensure_rules_file() {
    local file="$1"

    [ -f "$file" ] && return 0

    printf '%s\n' \
        "# TS-AUTO-ADD 常驻应用列表" \
        "# 每行一个包名；以 # 开头的行是注释，空行会被忽略。" \
        "# 这里列出的包名会始终并入目标列表（即使应用当前未安装）。" \
        "" \
        "com.android.vending" \
        "com.google.android.gms" \
        "com.google.android.gsf" > "$file" 2>/dev/null

    chmod 640 "$file" 2>/dev/null
    chown root:root "$file" 2>/dev/null
    chcon system_data_file "$file" 2>/dev/null || true
}

# ---------- 规则文件规范化 ----------
# 说明：修正两类会污染包名的写法问题（尽力而为，失败不影响后续流程）：
#       1) 末行缺少换行符——否则用户再用「echo 包名 >> rules.txt」追加时，
#          新包名会与最后一行粘成一行；
#       2) 文件开头带 UTF-8 BOM——会让第一个包名带上不可见前缀。
# 用法：normalize_rules_file <rules.txt 路径>
normalize_rules_file() {
    local file="$1"

    [ -f "$file" ] || return 0

    # 末行换行：tail -c1 取最后一个字节，取不到内容说明已以换行结尾
    if [ -n "$(tail -c 1 "$file" 2>/dev/null)" ]; then
        echo >> "$file" 2>/dev/null
    fi

    # UTF-8 BOM：与 BOM 三字节直接比较，命中则从第 4 字节起重写文件
    if [ "$(head -c 3 "$file" 2>/dev/null)" = "$(printf '\357\273\277')" ]; then
        if tail -c +4 "$file" > "${file}.bom" 2>/dev/null; then
            chmod 640 "${file}.bom" 2>/dev/null
            chown root:root "${file}.bom" 2>/dev/null
            chcon system_data_file "${file}.bom" 2>/dev/null || true
            mv -f "${file}.bom" "$file" 2>/dev/null
        fi
        rm -f "${file}.bom" 2>/dev/null
    fi

    return 0
}

# ---------- 读取常驻列表 ----------
# 说明：输出 rules.txt 中有效的包名：去掉行首行尾空白、忽略注释行与空行。
# 用法：read_rules
read_rules() {
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//; /^#/d; /^$/d' "$RULES_FILE" 2>/dev/null
}

# ---------- 应用列表生成（增量） ----------
# 说明：不再"用 常驻 ∪ 已装 整份重写"，改成在**当前目标文件的基础上只应用增量**：
#   保留  文件里现在的一切（所以人工加进去的条目天然不会被抹掉 —— 以前会被）
#   加入  当前已装的全部、当前常驻的全部
#   删除  上次装了、这次没了的（且不在常驻里）
#         上次在常驻、这次从常驻里删掉的（且没装）
#   "没有该包名的话就算了"：删除是对集合做 delete，文件里没有就是空操作。
#   没有上次状态（首次运行/刚升级）时不删任何东西，只做并集 —— 那时分不清
#   "已卸载"和"人工加的"，宁可贵一点。
# 用法：build_app_list <输出文件>
build_app_list() {
    local tmp="$1"
    local apps_raw user_list rules_now cur base

    mkdir -p "$TAA_DIR" 2>/dev/null
    ensure_rules_file "$RULES_FILE"
    normalize_rules_file "$RULES_FILE"

    apps_raw=$(cmd package list packages -3 -u --user all 2>/dev/null || pm list packages -3 2>/dev/null)
    user_list=$(printf '%s\n' "$apps_raw" | sed -n 's/^package://p' | sed '/^$/d' | sort -u)
    rules_now=$(read_rules | sed '/^$/d' | sort -u)
    cur=$(current_target_apps | sed '/^[[:space:]]*$/d' | sort -u)

    base="${tmp}.state"
    mkdir -p "$base" 2>/dev/null
    write_set() { if [ -n "$2" ]; then printf '%s\n' "$2" | sed '/^$/d' | sort -u > "$1"; else : > "$1"; fi; }
    write_set "$base/inst" "$user_list"
    write_set "$base/rules" "$rules_now"
    write_set "$base/cur" "$cur"
    : > "$base/was";    [ -s "$ST_INSTALLED" ] && cp -f "$ST_INSTALLED" "$base/was"
    : > "$base/wrules"; [ -s "$ST_RULES" ] && cp -f "$ST_RULES" "$base/wrules"

    # 一次 awk 做完全部集合运算
    awk '
        FILENAME == ARGV[1] { inst[$0] = 1; next }
        FILENAME == ARGV[2] { rules[$0] = 1; next }
        FILENAME == ARGV[3] { cur[$0] = 1; next }
        FILENAME == ARGV[4] { was[$0] = 1; next }
        FILENAME == ARGV[5] { wrules[$0] = 1; next }
        END {
            for (p in cur)    keep[p] = 1
            for (p in inst)   keep[p] = 1
            for (p in rules)  keep[p] = 1
            for (p in was)    if (!(p in inst) && !(p in rules)) delete keep[p]
            for (p in wrules) if (!(p in rules) && !(p in inst)) delete keep[p]
            for (p in keep) print p
        }
    ' "$base/inst" "$base/rules" "$base/cur" "$base/was" "$base/wrules" \
        | sort -u | sed '/^$/d' > "$tmp" 2>/dev/null
    rm -rf "$base" 2>/dev/null

    TAA_COUNT=$(wc -l < "$tmp" 2>/dev/null | tr -d ' ')

    # 这两份只在写成功后由 sync_* 提交，失败不推进
    printf '%s\n' "$user_list" > "$ST_INSTALLED_NEW" 2>/dev/null
    printf '%s\n' "$rules_now" > "$ST_RULES_NEW" 2>/dev/null
}
