#!/system/bin/sh
#=============================================================================
# lib/backend.sh - 后端探测、后端写入、模块描述、同步入口
#
# 后端（Tricky Store / TEE Simulator / OhMyKeymint 互斥；多于一个启用时模块直接停止）：
#   teesim -> /data/adb/teesim/config.json        仅替换 profiles.default.apps
#   tricky -> /data/adb/tricky_store/target.txt   整体重写为纯包名列表
#   omk    -> /data/misc/keystore/omk/injector.toml  仅替换 scoop 数组（config.toml 不碰）
#   写入实现分别位于 backends/teesim.awk、backends/tricky.sh 与 backends/omk.awk
#=============================================================================

# ---------- 模块探测 ----------
# 说明：按 /data/adb/modules 下的模块 id（目录名）判定：
#       Tricky Store / Tricky Store OSS 的模块 id 为 tricky_store
#       TEE Simulator 的模块 id 为 teesim
#       带 disable 标记表示被管理器停用，不计入；TEE Simulator 安装时会停用旧的
#       Tricky Store，因此这种“已停用的残留目录”不算冲突。
# 用法：teesim_active / tricky_active
# 返回：0=已安装且启用 1=未安装或已停用
teesim_active() {
    [ -d "$TEESIM_MODULE" ] && [ ! -f "$TEESIM_MODULE/disable" ]
}

tricky_active() {
    [ -d "$TRICKY_MODULE" ] && [ ! -f "$TRICKY_MODULE/disable" ]
}

omk_active() {
    [ -d "$OMK_MODULE" ] && [ ! -f "$OMK_MODULE/disable" ]
}

# ---------- 后端冲突 ----------
# 说明：三个后端互斥；同时启用多于一个时不做任何处理，直接停止模块。
#       各入口据此中止自身流程。
# 用法：backends_conflict
# 返回：0=多于一个启用 1=未冲突
backends_conflict() {
    local n=0
    teesim_active && n=$((n + 1))
    tricky_active && n=$((n + 1))
    omk_active   && n=$((n + 1))
    [ "$n" -gt 1 ]
}

# 冲突时的统一提示文案（各入口共用）
KL_CONFLICT_MSG="检测到多个密钥库后端同时启用（Tricky Store / TEE Simulator / OhMyKeymint），模块停止运行（请只保留一个）"

# ---------- 后端装载 ----------
# 说明：把运行期变量指向指定后端，并按需加载其写入实现。
# 用法：use_backend <teesim|tricky> <模块目录>
use_backend() {
    local mdir="$2"

    KL_PATCH="$mdir/backends/teesim.awk"

    if [ "$1" = "teesim" ]; then
        KL_BACKEND="teesim"
        KL_DIR="$TEESIM_DIR"
        TARGET_FILE="$TEESIM_CONFIG"
        AWK_CMD=$(find_awk)
    elif [ "$1" = "omk" ]; then
        KL_BACKEND="omk"
        # 状态寄生在 OMK 自己的状态目录（.kl_* 前缀不会和它的 pid/restart 撞名）
        KL_DIR="$OMK_STATE_DIR"
        TARGET_FILE="$OMK_INJECTOR"
        KL_PATCH="$mdir/backends/omk.awk"
        AWK_CMD=$(find_awk)
        mkdir -p "$KL_DIR" 2>/dev/null
    else
        KL_BACKEND="tricky"
        KL_DIR="$TSTORE_DIR"
        TARGET_FILE="$TSTORE_DIR/target.txt"
        # target.txt 现在要解析注释与 ?/! 后缀，和另外两个后端一样需要 awk
        AWK_CMD=$(find_awk)
        # 仅在选用该后端时加载其写入实现，避免无用开销
        if [ -f "$mdir/backends/tricky.sh" ]; then
            . "$mdir/backends/tricky.sh"
        else
            log_warn "缺少后端脚本 backends/tricky.sh"
        fi
    fi

    # 状态：上次成功同步时见到的「已装第三方」+ 历次写进去的并集（ever）。
    # 由 build_app_list 写到 *.new，再由 sync_* 在**写入成功后**提交；
    # 失败不推进，否则那次卸载事件会被当成"已经处理过"而永远漏掉。
    ST_INSTALLED="$KL_DIR/.kl_installed_last"
    ST_INSTALLED_NEW="$KL_DIR/.kl_installed.new"
    ST_EVER="$KL_DIR/.kl_ever"
    ST_EVER_NEW="$KL_DIR/.kl_ever.new"
}

# ---------- 当前目标文件里有哪些包名 ----------
# 说明：只读，给"保留人工条目"用。读不到就输出空（调用方按"文件里什么都没有"处理）。
# 用法：current_target_apps
current_target_apps() {
    [ -f "$TARGET_FILE" ] || return 0
    if [ "$KL_BACKEND" = "teesim" ]; then
        [ -n "$AWK_CMD" ] || return 0
        $AWK_CMD -f "${KL_PATCH%/*}/teesim_list.awk" "$TARGET_FILE" 2>/dev/null
    elif [ "$KL_BACKEND" = "omk" ]; then
        [ -n "$AWK_CMD" ] || return 0
        $AWK_CMD -f "${KL_PATCH%/*}/omk_list.awk" "$TARGET_FILE" 2>/dev/null
    else
        # Tricky Store OSS：行内 # 注释、?/! 模式后缀都按它自己的解析规则处理；
        # 同一个包名出现多次时后出现的模式生效（与它的 Map 一致）。
        [ -n "$AWK_CMD" ] || AWK_CMD=$(find_awk)
        [ -n "$AWK_CMD" ] || return 0
        $AWK_CMD -f "${KL_PATCH%/*}/tricky_list.awk" "$TARGET_FILE" 2>/dev/null
    fi
}

# ---------- 后端探测 ----------
# 说明：优先按已启用模块判定；都没有时，回退到配置文件判定
#       （兼容未装模块但已存在 teesim 配置的场景）。
# 用法：detect_backend <模块目录>
detect_backend() {
    if teesim_active; then
        use_backend teesim "$1"
    elif tricky_active; then
        use_backend tricky "$1"
    elif omk_active; then
        use_backend omk "$1"
    elif [ -f "$TEESIM_CONFIG" ]; then
        use_backend teesim "$1"
    else
        use_backend tricky "$1"
    fi
}

# 说明：把一批包名并入 ever；由「加入/恢复」在持锁时调用，保证下一轮 excluded
#       仍认得出它们。只影响界面标签，失败静默，不影响名单本身。
# 用法：ever_add_list <每行一个包名的文件>
ever_add_list() {
    local list="$1" tmp

    [ -n "${ST_EVER:-}" ] || return 0
    [ -f "$list" ] || return 0
    tmp="${ST_EVER}.tmp.$$"
    { cat "$ST_EVER" 2>/dev/null; sed '/^[[:space:]]*$/d' "$list"; } \
        | sort -u > "$tmp" 2>/dev/null \
        && mv -f "$tmp" "$ST_EVER" 2>/dev/null
    rm -f "$tmp" 2>/dev/null
    chmod 600 "$ST_EVER" 2>/dev/null
    return 0
}

# ---------- 把一批包名加入目标文件 ----------
# 说明：界面单条「+」与批量「加入」共用；一次写入，只动 apps 数组 / target.txt /
#       scoop，其余原样保留。调用方必须先 detect_backend 并持有 webui_lock。
# 用法：add_target_apps <每行一个包名的文件>
# 返回：0=至少加入一个 1=这些包本来都在 2=失败
add_target_apps() {
    local list="$1" cur dir out status rc=2
    [ -f "$list" ] || return 2

    cur=$(current_target_apps 2>/dev/null | sed '/^[[:space:]]*$/d')
    dir="${KL_DIR}/.kl_restore.$$"
    mkdir -p "$dir" 2>/dev/null || return 2
    printf '%s\n' "$cur" | sed '/^$/d' | sort -u > "$dir/cur" 2>/dev/null
    sed '/^[[:space:]]*$/d' "$list" | sort -u > "$dir/req" 2>/dev/null
    # 判重按基础包名：Tricky 的 pkg? / TEESim 的 pkg@10 已经代表这个应用在名单里，
    # 不能再追加一条裸 pkg（Tricky 会变成同包两个模式，TEESim 会重复覆盖）。
    # 用 FILENAME 而不是 NR==FNR：cur 为空时，第二个文件的第一条记录会让
    # NR==FNR 仍为真，把新包名当成"已在名单"吞掉（实测：文件不存在时返回 1）。
    awk -v backend="${KL_BACKEND:-tricky}" '
        FILENAME == ARGV[1] {
            tok = $0; b = tok
            if (backend == "tricky") { if (b ~ /[?!]$/) b = substr(b, 1, length(b) - 1) }
            else if (backend == "teesim") { if (b ~ /^uid:/) b = ""; else sub(/@[0-9]+$/, "", b) }
            exact[tok] = 1
            if (b != "") base[b] = 1
            next
        }
        {
            tok = $0; b = tok
            if (backend == "tricky") { if (b ~ /[?!]$/) b = substr(b, 1, length(b) - 1) }
            else if (backend == "teesim") { if (b ~ /^uid:/) b = ""; else sub(/@[0-9]+$/, "", b) }
            if (tok == "" || (tok in exact)) next
            if (b != "" && (b in base)) {
                # TEESim 的 @用户 是独立作用域，可以与该包的裸条目并存（撤销要用）；
                # Tricky 的模式与裸包名互斥（同一个 Map 键），其余情况按已存在处理。
                if (!(backend == "teesim" && tok ~ /@[0-9]+$/)) next
            }
            print tok
            exact[tok] = 1
            if (b != "") base[b] = 1
        }
    ' "$dir/cur" "$dir/req" > "$dir/new" 2>/dev/null
    if [ ! -s "$dir/new" ]; then
        rm -rf "$dir" 2>/dev/null
        return 1
    fi
    { cat "$dir/cur"; cat "$dir/new"; } | sort -u > "$dir/combo" 2>/dev/null

    if [ "$KL_BACKEND" = "omk" ]; then
        [ -n "$AWK_CMD" ] || AWK_CMD=$(find_awk)
        if [ -n "$AWK_CMD" ] && [ -f "$KL_PATCH" ] && [ -f "$TARGET_FILE" ]; then
            omk_write_list "$dir/combo"; rc=$?
        fi
    elif [ "$KL_BACKEND" = "teesim" ]; then
        [ -n "$AWK_CMD" ] || AWK_CMD=$(find_awk)
        if [ -n "$AWK_CMD" ] && [ -f "$KL_PATCH" ] && [ -f "$TARGET_FILE" ]; then
            $AWK_CMD -v listfile="$dir/combo" -v statusfile="$dir/status" \
                -f "$KL_PATCH" "$TARGET_FILE" > "$dir/out" 2>/dev/null
            if [ "$(cat "$dir/status" 2>/dev/null)" = "ok" ] && [ -s "$dir/out" ]; then
                chmod 600 "$dir/out" 2>/dev/null
                chown root:root "$dir/out" 2>/dev/null
                mv -f "$dir/out" "$TARGET_FILE" 2>/dev/null && rc=0
            fi
        fi
    else
        if [ -f "$TARGET_FILE" ]; then
            {
                cat "$TARGET_FILE"
                [ -s "$TARGET_FILE" ] && [ -n "$(tail -c 1 "$TARGET_FILE" 2>/dev/null)" ] && echo
                cat "$dir/new"
            } > "$dir/out" 2>/dev/null || { rm -rf "$dir" 2>/dev/null; return 2; }
            chmod 644 "$dir/out" 2>/dev/null
            mv -f "$dir/out" "$TARGET_FILE" 2>/dev/null && rc=0
        fi
    fi

    if [ "$rc" = 0 ]; then
        entries_to_bases "$dir/new" > "$dir/newbase" 2>/dev/null
        ever_add_list "$dir/newbase"
    fi
    rm -rf "$dir" 2>/dev/null
    return "$rc"
}

# 说明：单条包名是上面那个函数的薄包装（界面「+」用）。
# 用法：add_target_app <包名>
# 返回：0=已加入 1=本来就在 2=失败
add_target_app() {
    local f="${KL_DIR}/.kl_restore.one.$$" rc

    mkdir -p "${f%/*}" 2>/dev/null
    printf '%s\n' "$1" > "$f" 2>/dev/null || { rm -f "$f" 2>/dev/null; return 2; }
    add_target_apps "$f"; rc=$?
    rm -f "$f" 2>/dev/null
    return "$rc"
}

# ---------- 从目标文件里移出一批包名 ----------
# 说明：只删请求里的包名；其余条目、注释与格式保持原样。目标名单不允许清空：
#       生成空列表会与守护进程的空列表保护混在一起，界面会一直显示写入失败，
#       用户也看不出「我确实删光了」和「读取失败」的区别。
# 用法：remove_target_apps <每行一个包名的文件>
# 返回：0=至少移出一个 1=这些包本来都不在 2=失败 3=会清空名单
remove_target_apps() {
    local list="$1" cur dir removed rc=2

    KL_REMOVED_LIST=""
    [ -f "$list" ] || return 2
    [ -f "$TARGET_FILE" ] || return 2
    [ -n "$AWK_CMD" ] || AWK_CMD=$(find_awk)
    [ -n "$AWK_CMD" ] || return 2

    # 读取失败（文件损坏、定位不到数组）不能当成「名单是空的」：
    # 否则会返回 1「本来就不在」，把一次失败伪装成成功。
    if ! cur=$(current_target_apps 2>/dev/null); then
        return 2
    fi
    cur=$(printf '%s\n' "$cur" | sed 's/\r$//' | sed '/^[[:space:]]*$/d')

    dir="${KL_DIR}/.kl_remove.$$"
    mkdir -p "$dir" 2>/dev/null || return 2
    printf '%s\n' "$cur" | sed '/^$/d' > "$dir/cur" 2>/dev/null
    sed '/^[[:space:]]*$/d' "$list" | sort -u > "$dir/req" 2>/dev/null

    # 实际被移出的条目（去重、保留原顺序），界面「撤销」用它精确恢复；
    # 不能用界面勾选的那一份：列表可能已经刷新过，勾选里可能夹着已不在文件里的包。
    # Tricky 的模式同属一个应用（它内部按包名存 Map），所以按基础包名匹配；
    # TEESim 的 pkg@10 是一个独立作用域，按 token 精确匹配，避免误删同包的其他用户。
    if ! $AWK_CMD -v backend="${KL_BACKEND:-tricky}" -v removedfile="$dir/removed" '
        FILENAME == ARGV[1] {
            tok = $0; b = tok
            if (backend == "tricky") { if (b ~ /[?!]$/) b = substr(b, 1, length(b) - 1) }
            else if (backend == "teesim") { if (b ~ /^uid:/) b = ""; else sub(/@[0-9]+$/, "", b) }
            reqexact[tok] = 1
            if (b != "") reqbase[b] = 1
            next
        }
        {
            tok = $0; b = tok
            if (backend == "tricky") { if (b ~ /[?!]$/) b = substr(b, 1, length(b) - 1) }
            else if (backend == "teesim") { if (b ~ /^uid:/) b = ""; else sub(/@[0-9]+$/, "", b) }
            hit = (tok in reqexact) || (backend == "tricky" && b != "" && (b in reqbase))
            if (hit) { if (!(tok in seen)) { print tok > removedfile; seen[tok] = 1 } }
            else keep[++n] = tok
        }
        END { for (i = 1; i <= n; i++) print keep[i] }
    ' "$dir/req" "$dir/cur" > "$dir/combo" 2>/dev/null; then
        rm -rf "$dir" 2>/dev/null
        return 2
    fi
    removed=$(wc -l < "$dir/removed" 2>/dev/null | tr -d ' ')
    if [ "${removed:-0}" = "0" ]; then
        rm -rf "$dir" 2>/dev/null
        return 1
    fi
    KL_REMOVED_LIST=$(tr '\n' ',' < "$dir/removed" 2>/dev/null | sed 's/,$//')

    if [ ! -s "$dir/combo" ]; then
        rm -rf "$dir" 2>/dev/null
        return 3
    fi

    if [ "$KL_BACKEND" = "omk" ]; then
        if [ -f "$KL_PATCH" ]; then
            omk_write_list "$dir/combo"; rc=$?
            # 请求里明明有可移出的条目，writer 却说内容一致：按失败处理，
            # 不能让调用方以为删掉了。
            [ "$rc" = 1 ] && rc=2
        fi
    elif [ "$KL_BACKEND" = "teesim" ]; then
        if [ -f "$KL_PATCH" ]; then
            $AWK_CMD -v listfile="$dir/combo" -v statusfile="$dir/status" \
                -f "$KL_PATCH" "$TARGET_FILE" > "$dir/out" 2>/dev/null
            if [ "$(cat "$dir/status" 2>/dev/null)" = "ok" ] && [ -s "$dir/out" ]; then
                chmod 600 "$dir/out" 2>/dev/null
                chown root:root "$dir/out" 2>/dev/null
                mv -f "$dir/out" "$TARGET_FILE" 2>/dev/null && rc=0
            fi
        fi
    else
        # Tricky：只删匹配的条目行，注释、空行与其余条目原样保留。
        # 模式后缀属于同一个应用，按基础包名删；行内注释不参与比较。
        if $AWK_CMD '
            FILENAME == ARGV[1] {
                tok = $0; b = tok
                if (b ~ /[?!]$/) b = substr(b, 1, length(b) - 1)
                reqexact[tok] = 1
                if (b != "") reqbase[b] = 1
                next
            }
            {
                orig = $0
                line = $0; sub(/\r$/, "", line)
                h = index(line, "#"); body = h ? substr(line, 1, h - 1) : line
                gsub(/^[ \t]+|[ \t]+$/, "", body)
                tok = body; b = tok
                if (b ~ /[?!]$/) {
                    b = substr(b, 1, length(b) - 1)
                    sub(/[ 	]+$/, "", b)
                }
                if ((tok in reqexact) || (b != "" && (b in reqbase))) next
                print orig
            }
        ' "$dir/req" "$TARGET_FILE" > "$dir/out" 2>/dev/null; then
            chmod 644 "$dir/out" 2>/dev/null
            mv -f "$dir/out" "$TARGET_FILE" 2>/dev/null && rc=0
        fi
    fi

    # 移出前把当前名单并入 ever：手工加进文件、还没同步过的包也被记住，
    # 移出后才能在「已安装」里显示成「已排除」，而不是凭空消失。
    if [ "$rc" = 0 ]; then
        entries_to_bases "$dir/cur" > "$dir/curbase" 2>/dev/null
        ever_add_list "$dir/curbase"
    fi
    rm -rf "$dir" 2>/dev/null
    return "$rc"
}

# ---------- 修改 Tricky 条目的模式 ----------
# 说明：Tricky Store OSS 的 target.txt 支持 ?（强制叶证书破解）与 !（强制证书
#       生成），不带后缀为自动。只改这一行的后缀，注释与其余条目原样保留；
#       写完由 Tricky 自己的 FileObserver 重载（MOVED_TO）。
# 用法：set_tricky_mode <包名> <auto|leaf|generate>
# 返回：0=已修改 1=无需修改/没有这个包 2=失败
set_tricky_mode() {
    local pkg="$1" mode="$2" dir out status rc=2

    [ "${KL_BACKEND:-}" = "tricky" ] || return 2
    is_pkg_token "$pkg" || return 2
    case "$mode" in auto|leaf|generate) ;; *) return 2 ;; esac
    [ -f "$TARGET_FILE" ] || return 2
    [ -n "${AWK_CMD:-}" ] || AWK_CMD=$(find_awk)
    [ -n "$AWK_CMD" ] && [ -f "${KL_PATCH%/*}/tricky_mode.awk" ] || return 2

    dir="${KL_DIR}/.kl_mode.$$"
    mkdir -p "$dir" 2>/dev/null || return 2
    out="$dir/out"; status="$dir/status"
    $AWK_CMD -v pkg="$pkg" -v mode="$mode" -v statusfile="$status" \
        -f "${KL_PATCH%/*}/tricky_mode.awk" "$TARGET_FILE" > "$out" 2>/dev/null

    case "$(cat "$status" 2>/dev/null)" in
        ok)
            chmod 644 "$out" 2>/dev/null
            mv -f "$out" "$TARGET_FILE" 2>/dev/null && rc=0
            ;;
        same|none) rc=1 ;;
        *) rc=2 ;;
    esac
    rm -rf "$dir" 2>/dev/null
    return "$rc"
}

# ---------- 原子替换并保留目标文件属性 ----------
# 说明：界面改后端配置时用。new 必须与 target 在同一目录（rename 才是原子的）；
#       先按原文件的 owner / mode / SELinux 上下文修正 new，有备份就先 cp -p，
#       最后 mv。目标不存在时按 600 root 落地。
# 用法：write_atomic_preserve <目标> <新文件> <备份路径|"">
# 返回：0=成功 1=失败
write_atomic_preserve() {
    local target="$1" new="$2" backup="$3"
    local uid gid mode ctx

    [ -f "$new" ] || return 1

    if [ -f "$target" ]; then
        uid=$(stat -c %u "$target" 2>/dev/null)
        gid=$(stat -c %g "$target" 2>/dev/null)
        mode=$(stat -c %a "$target" 2>/dev/null)
        ctx=$(ls -Zd "$target" 2>/dev/null | awk '{print $1}')
        [ -n "$uid" ] && [ -n "$gid" ] && chown "$uid:$gid" "$new" 2>/dev/null
        [ -n "$mode" ] && chmod "$mode" "$new" 2>/dev/null
        if [ -n "$ctx" ] && command -v chcon >/dev/null 2>&1; then
            chcon "$ctx" "$new" 2>/dev/null
        fi
        if [ -n "$backup" ]; then
            cp -p "$target" "$backup" 2>/dev/null && chmod 600 "$backup" 2>/dev/null
        fi
    else
        chmod 600 "$new" 2>/dev/null
    fi

    mv -f "$new" "$target" 2>/dev/null
}

# ---------- 后端名称 ----------
# 说明：用于日志与模块描述展示
# 用法：backend_name
backend_name() {
    case "$KL_BACKEND" in
        teesim) echo "TEE Simulator" ;;
        omk)    echo "OhMyKeymint" ;;
        *)      echo "Tricky Store" ;;
    esac
}

# ---------- OhMyKeymint 写入 ----------
# 说明：只替换 injector.toml 里的 scoop 数组；其余字节、owner/mode 与 SELinux
#       上下文原样保留；内容一致不落盘。成功改动后给 OMK 的 injector 守护进程
#       写一个重启请求（它自己的 restart.injector 机制），让新名单生效。
# 用法：omk_write_list <每行一个包名的文件>
# 返回：0=已写入 1=内容一致 2=失败
omk_write_list() {
    local list="$1" out status uid gid mode ctx rc=2

    [ -f "$TARGET_FILE" ] || return 2
    [ -n "$AWK_CMD" ] || AWK_CMD=$(find_awk)
    [ -n "$AWK_CMD" ] && [ -f "$KL_PATCH" ] || return 2

    out="$(dirname "$TARGET_FILE")/.injector.toml.keylens.$$"
    status="${out}.status"
    uid=$(stat -c %u "$TARGET_FILE" 2>/dev/null)
    gid=$(stat -c %g "$TARGET_FILE" 2>/dev/null)
    mode=$(stat -c %a "$TARGET_FILE" 2>/dev/null)
    ctx=$(ls -Zd "$TARGET_FILE" 2>/dev/null | awk '{print $1}')

    rm -f "$out" "$status" 2>/dev/null
    $AWK_CMD -v listfile="$list" -v statusfile="$status" -f "$KL_PATCH" "$TARGET_FILE" > "$out" 2>/dev/null
    if [ "$(cat "$status" 2>/dev/null)" = "ok" ] && [ -s "$out" ]; then
        if cmp -s "$out" "$TARGET_FILE" 2>/dev/null; then
            rc=1
        else
            [ -n "$uid" ] && [ -n "$gid" ] && chown "$uid:$gid" "$out" 2>/dev/null
            [ -n "$mode" ] && chmod "$mode" "$out" 2>/dev/null
            if [ -n "$ctx" ] && command -v chcon >/dev/null 2>&1; then
                chcon "$ctx" "$out" 2>/dev/null
            fi
            cp -p "$TARGET_FILE" "$KL_DIR/injector.toml.bak" 2>/dev/null
            mv -f "$out" "$TARGET_FILE" 2>/dev/null && rc=0
        fi
    fi
    rm -f "$out" "$status" 2>/dev/null
    [ "$rc" = 0 ] && omk_request_reload
    return "$rc"
}

# 说明：给 OMK 的 injector 守护进程写重启请求（它自己的机制，消费后删除）。
# 用法：omk_request_reload
omk_request_reload() {
    [ -d "$OMK_STATE_DIR" ] || return 0
    : > "$OMK_STATE_DIR/restart.injector" 2>/dev/null
}

# ---------- TEE Simulator 后端写入 ----------
# 说明：调用 backends/teesim.awk 定点替换 config.json 中 default profile 的 apps；
#       其它字段与其它 profile 原样保留；无法可靠定位数组时放弃写入，不改动原文件。
# 用法：sync_teesim_config <config.json> <临时文件>
# 返回：0=已写入 1=内容一致未写入 2=失败或结果为空
sync_teesim_config() {
    local config="$1" tmp="$2"
    local out="${tmp}.json" status="${tmp}.status"
    local rc=2

    KL_COUNT=0
    # awk 可能在上次探测之后才可用（例如后装了 busybox），此处按需重探
    [ -n "$AWK_CMD" ] || AWK_CMD=$(find_awk)

    if [ -f "$config" ] && [ -n "$AWK_CMD" ] && [ -f "$KL_PATCH" ]; then
        if ! build_app_list "$tmp"; then
            log_warn "⚠️ 已装列表为空但基线非空：跳过本次写入，避免误清名单（手动同步可强制）"
            rm -f "$tmp" 2>/dev/null
            return 2
        fi
        [ -s "$tmp" ] && {
            # 生成替换后的内容；状态文件不是 "ok" 说明未定位到 apps 数组，保持原配置
            rm -f "$out" "$status" 2>/dev/null
            $AWK_CMD -v listfile="$tmp" -v statusfile="$status" -f "$KL_PATCH" "$config" > "$out" 2>/dev/null

            if [ "$(cat "$status" 2>/dev/null)" = "ok" ] && [ -s "$out" ]; then
                if cmp -s "$out" "$config" 2>/dev/null; then
                    rc=1                       # 内容一致，无需落盘
                else
                    chmod 600 "$out" 2>/dev/null
                    chown root:root "$out" 2>/dev/null
                    mv -f "$out" "$config" 2>/dev/null && rc=0
                fi
                # 内容与目标文件一致（刚写进去或本来就一样），这一趟的增量就算生效了：
                # 提交基线，下次按新基线算。写失败（rc=2）不推进，否则卸载事件会漏。
                if [ "$rc" != "2" ]; then
                    mv -f "$ST_INSTALLED_NEW" "$ST_INSTALLED" 2>/dev/null
                    chmod 600 "$ST_INSTALLED" 2>/dev/null
                    mv -f "$ST_EVER_NEW" "$ST_EVER" 2>/dev/null
                    chmod 600 "$ST_EVER" 2>/dev/null
                    drop_legacy_state
                fi
            fi
        }
    fi

    rm -f "$tmp" "$out" "$status" 2>/dev/null
    return "$rc"
}

# ---------- OhMyKeymint 后端写入 ----------
# 说明：与 TEE Simulator 同一套基线/ever 提交语义；文件替换由 omk_write_list 负责。
# 用法：sync_omk_injector <injector.toml> <临时文件>
# 返回：0=已写入 1=内容一致未写入 2=失败或结果为空
sync_omk_injector() {
    local config="$1" tmp="$2" rc cur_now new_now

    KL_COUNT=0
    [ -f "$config" ] || return 2
    [ -n "$AWK_CMD" ] || AWK_CMD=$(find_awk)
    [ -n "$AWK_CMD" ] && [ -f "$KL_PATCH" ] || return 2

    if ! build_app_list "$tmp"; then
        log_warn "⚠️ 已装列表为空但基线非空：跳过本次写入，避免误清名单（手动同步可强制）"
        rm -f "$tmp" 2>/dev/null
        return 2
    fi
    [ -s "$tmp" ] || { rm -f "$tmp" 2>/dev/null; return 2; }

    # 集合相同就不落盘：首次接入沿用现有 scoop 时集合本来就没变，
    # 不该为了统一排版去改用户的 injector.toml（也不该触发 OMK 重载）。
    cur_now=$(current_target_apps 2>/dev/null | sed '/^[[:space:]]*$/d' | sort -u)
    new_now=$(sed '/^[[:space:]]*$/d' "$tmp" 2>/dev/null | sort -u)
    if [ "$cur_now" = "$new_now" ]; then
        rc=1
    else
        omk_write_list "$tmp"; rc=$?
    fi
    if [ "$rc" != "2" ]; then
        mv -f "$ST_INSTALLED_NEW" "$ST_INSTALLED" 2>/dev/null
        chmod 600 "$ST_INSTALLED" 2>/dev/null
        mv -f "$ST_EVER_NEW" "$ST_EVER" 2>/dev/null
        chmod 600 "$ST_EVER" 2>/dev/null
        drop_legacy_state
    fi
    rm -f "$tmp" 2>/dev/null
    [ "$rc" = 0 ] && log_info "🔁 已请求 OhMyKeymint 重载 injector"
    return "$rc"
}

# ---------- 模块描述 ----------
# 说明：把 description 字段替换为指定文本（写入前先落临时文件，成功才覆盖）。
# 用法：set_module_desc <module.prop> <描述文本>
# 返回：0=成功 1=失败
set_module_desc() {
    local prop_file="$1" desc="$2"
    local tmp_file

    [ -f "$prop_file" ] || return 1

    tmp_file="${prop_file}.tmp.$$"
    if sed "s/^description=.*/description=$desc/" "$prop_file" > "$tmp_file" 2>/dev/null; then
        cat "$tmp_file" > "$prop_file"
        rm -f "$tmp_file" 2>/dev/null
        return 0
    fi

    rm -f "$tmp_file" 2>/dev/null
    return 1
}

# 说明：把运行状态写回 description：后端 / 应用总数 / 更新时间
# 用法：update_module_desc <module.prop> <应用总数>
# 返回：0=成功 1=失败
update_module_desc() {
    set_module_desc "$1" "✅ [$(backend_name) | 应用: $2 | 更新: $(date '+%H:%M')]"
}

# 说明：写入失败时把失败状态写进 description，避免界面仍显示成正常状态
# 用法：mark_module_failed <module.prop>
# 返回：0=成功 1=失败
mark_module_failed() {
    set_module_desc "$1" "⚠️ [$(backend_name) | 写入失败 | 更新: $(date '+%H:%M')]"
}

# 说明：因后端冲突停止运行时，把停止提示写进 description，
#       这样无需看日志，在管理器界面即可直接看到模块已停止。
# 用法：mark_module_stopped <module.prop>
# 返回：0=成功 1=失败
mark_module_stopped() {
    set_module_desc "$1" "⛔ [模块已停止 | 多个密钥库后端同时启用]"
}

# ---------- 同步入口 ----------
# 说明：按当前后端写入目标文件，随后刷新模块描述；写入失败时描述标注失败状态。
# 用法：run_sync <module.prop> <临时文件>
# 返回：0=已写入 1=内容一致未写入 2=失败或结果为空
run_sync() {
    local prop_file="$1" tmp="$2"
    local rc=2

    if [ "$KL_BACKEND" = "teesim" ]; then
        sync_teesim_config "$TARGET_FILE" "$tmp"
        rc=$?
    elif [ "$KL_BACKEND" = "omk" ]; then
        sync_omk_injector "$TARGET_FILE" "$tmp"
        rc=$?
    elif command -v sync_target_list >/dev/null 2>&1; then
        sync_target_list "$TARGET_FILE" "$tmp"
        rc=$?
    else
        KL_COUNT=0
    fi

    if [ "$rc" = "2" ]; then
        mark_module_failed "$prop_file"
    else
        update_module_desc "$prop_file" "$KL_COUNT"
    fi
    return "$rc"
}
