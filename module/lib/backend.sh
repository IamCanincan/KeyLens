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
TAA_CONFLICT_MSG="检测到多个密钥库后端同时启用（Tricky Store / TEE Simulator / OhMyKeymint），模块停止运行（请只保留一个）"

# ---------- 后端装载 ----------
# 说明：把运行期变量指向指定后端，并按需加载其写入实现。
# 用法：use_backend <teesim|tricky> <模块目录>
use_backend() {
    local mdir="$2"

    TAA_PATCH="$mdir/backends/teesim.awk"

    if [ "$1" = "teesim" ]; then
        TAA_BACKEND="teesim"
        TAA_DIR="$TEESIM_DIR"
        TARGET_FILE="$TEESIM_CONFIG"
        AWK_CMD=$(find_awk)
    elif [ "$1" = "omk" ]; then
        TAA_BACKEND="omk"
        # 状态寄生在 OMK 自己的状态目录（.ts_* 前缀不会和它的 pid/restart 撞名）
        TAA_DIR="$OMK_STATE_DIR"
        TARGET_FILE="$OMK_INJECTOR"
        TAA_PATCH="$mdir/backends/omk.awk"
        AWK_CMD=$(find_awk)
        mkdir -p "$TAA_DIR" 2>/dev/null
    else
        TAA_BACKEND="tricky"
        TAA_DIR="$TSTORE_DIR"
        TARGET_FILE="$TSTORE_DIR/target.txt"
        AWK_CMD=""
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
    ST_INSTALLED="$TAA_DIR/.ts_installed_last"
    ST_INSTALLED_NEW="$TAA_DIR/.ts_installed.new"
    ST_EVER="$TAA_DIR/.ts_ever"
    ST_EVER_NEW="$TAA_DIR/.ts_ever.new"
}

# ---------- 当前目标文件里有哪些包名 ----------
# 说明：只读，给"保留人工条目"用。读不到就输出空（调用方按"文件里什么都没有"处理）。
# 用法：current_target_apps
current_target_apps() {
    [ -f "$TARGET_FILE" ] || return 0
    if [ "$TAA_BACKEND" = "teesim" ]; then
        [ -n "$AWK_CMD" ] || return 0
        $AWK_CMD -f "${TAA_PATCH%/*}/teesim_list.awk" "$TARGET_FILE" 2>/dev/null
    elif [ "$TAA_BACKEND" = "omk" ]; then
        [ -n "$AWK_CMD" ] || return 0
        $AWK_CMD -f "${TAA_PATCH%/*}/omk_list.awk" "$TARGET_FILE" 2>/dev/null
    else
        sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' "$TARGET_FILE" 2>/dev/null
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

# ---------- 把单个包名加回目标文件 ----------
# 说明：界面上的「恢复」用它，等价于你手动把包名写回文件；只动 apps 数组 /
#       target.txt，profiles 其它字段与注释原样保留。调用方必须先 detect_backend
#       并持有 webui_lock，避免和守护进程的同步互相覆盖。
# 用法：add_target_app <包名>
# 返回：0=已加入 1=本来就在 2=失败
add_target_app() {
    local pkg="$1" cur tmp out status rc=2

    cur=$(current_target_apps 2>/dev/null | sed '/^[[:space:]]*$/d')
    case "
$cur
" in
        *"
$pkg
"*) return 1 ;;
    esac

    tmp="${TAA_DIR}/.ts_restore.$$"
    if [ "$TAA_BACKEND" = "omk" ]; then
        [ -n "$AWK_CMD" ] || AWK_CMD=$(find_awk)
        [ -n "$AWK_CMD" ] && [ -f "$TAA_PATCH" ] && [ -f "$TARGET_FILE" ] || return 2
        { printf '%s\n' "$cur"; printf '%s\n' "$pkg"; } | sed '/^$/d' > "$tmp" 2>/dev/null || return 2
        omk_write_list "$tmp"; rc=$?
        rm -f "$tmp" 2>/dev/null
        return "$rc"
    fi
    if [ "$TAA_BACKEND" = "teesim" ]; then
        [ -n "$AWK_CMD" ] || AWK_CMD=$(find_awk)
        [ -n "$AWK_CMD" ] && [ -f "$TAA_PATCH" ] && [ -f "$TARGET_FILE" ] || return 2
        out="${tmp}.json"; status="${tmp}.status"
        { printf '%s\n' "$cur"; printf '%s\n' "$pkg"; } | sed '/^$/d' > "$tmp" 2>/dev/null || return 2
        rm -f "$out" "$status" 2>/dev/null
        $AWK_CMD -v listfile="$tmp" -v statusfile="$status" -f "$TAA_PATCH" "$TARGET_FILE" > "$out" 2>/dev/null
        if [ "$(cat "$status" 2>/dev/null)" = "ok" ] && [ -s "$out" ]; then
            chmod 600 "$out" 2>/dev/null
            chown root:root "$out" 2>/dev/null
            mv -f "$out" "$TARGET_FILE" 2>/dev/null && rc=0
        fi
        rm -f "$tmp" "$out" "$status" 2>/dev/null
        return "$rc"
    fi

    # Tricky Store：逐行文件，追加。原文件末尾没有换行时先补一个，
    # 否则新包名会和最后一行粘在一起。
    [ -f "$TARGET_FILE" ] || return 2
    {
        cat "$TARGET_FILE"
        [ -s "$TARGET_FILE" ] && [ -n "$(tail -c 1 "$TARGET_FILE" 2>/dev/null)" ] && echo
        printf '%s\n' "$pkg"
    } > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 2; }
    chmod 644 "$tmp" 2>/dev/null
    if mv -f "$tmp" "$TARGET_FILE" 2>/dev/null; then rc=0; fi
    rm -f "$tmp" 2>/dev/null
    return "$rc"
}

# ---------- 后端名称 ----------
# 说明：用于日志与模块描述展示
# 用法：backend_name
backend_name() {
    case "$TAA_BACKEND" in
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
    [ -n "$AWK_CMD" ] && [ -f "$TAA_PATCH" ] || return 2

    out="$(dirname "$TARGET_FILE")/.injector.toml.ts_auto.$$"
    status="${out}.status"
    uid=$(stat -c %u "$TARGET_FILE" 2>/dev/null)
    gid=$(stat -c %g "$TARGET_FILE" 2>/dev/null)
    mode=$(stat -c %a "$TARGET_FILE" 2>/dev/null)
    ctx=$(ls -Zd "$TARGET_FILE" 2>/dev/null | awk '{print $1}')

    rm -f "$out" "$status" 2>/dev/null
    $AWK_CMD -v listfile="$list" -v statusfile="$status" -f "$TAA_PATCH" "$TARGET_FILE" > "$out" 2>/dev/null
    if [ "$(cat "$status" 2>/dev/null)" = "ok" ] && [ -s "$out" ]; then
        if cmp -s "$out" "$TARGET_FILE" 2>/dev/null; then
            rc=1
        else
            [ -n "$uid" ] && [ -n "$gid" ] && chown "$uid:$gid" "$out" 2>/dev/null
            [ -n "$mode" ] && chmod "$mode" "$out" 2>/dev/null
            if [ -n "$ctx" ] && command -v chcon >/dev/null 2>&1; then
                chcon "$ctx" "$out" 2>/dev/null
            fi
            cp -p "$TARGET_FILE" "$TAA_DIR/injector.toml.bak" 2>/dev/null
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

    TAA_COUNT=0
    # awk 可能在上次探测之后才可用（例如后装了 busybox），此处按需重探
    [ -n "$AWK_CMD" ] || AWK_CMD=$(find_awk)

    if [ -f "$config" ] && [ -n "$AWK_CMD" ] && [ -f "$TAA_PATCH" ]; then
        if ! build_app_list "$tmp"; then
            log_warn "⚠️ 已装列表为空但基线非空：跳过本次写入，避免误清名单（手动同步可强制）"
            rm -f "$tmp" 2>/dev/null
            return 2
        fi
        [ -s "$tmp" ] && {
            # 生成替换后的内容；状态文件不是 "ok" 说明未定位到 apps 数组，保持原配置
            rm -f "$out" "$status" 2>/dev/null
            $AWK_CMD -v listfile="$tmp" -v statusfile="$status" -f "$TAA_PATCH" "$config" > "$out" 2>/dev/null

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

    TAA_COUNT=0
    [ -f "$config" ] || return 2
    [ -n "$AWK_CMD" ] || AWK_CMD=$(find_awk)
    [ -n "$AWK_CMD" ] && [ -f "$TAA_PATCH" ] || return 2

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

    if [ "$TAA_BACKEND" = "teesim" ]; then
        sync_teesim_config "$TARGET_FILE" "$tmp"
        rc=$?
    elif [ "$TAA_BACKEND" = "omk" ]; then
        sync_omk_injector "$TARGET_FILE" "$tmp"
        rc=$?
    elif command -v sync_target_list >/dev/null 2>&1; then
        sync_target_list "$TARGET_FILE" "$tmp"
        rc=$?
    else
        TAA_COUNT=0
    fi

    if [ "$rc" = "2" ]; then
        mark_module_failed "$prop_file"
    else
        update_module_desc "$prop_file" "$TAA_COUNT"
    fi
    return "$rc"
}
