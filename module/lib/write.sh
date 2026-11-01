#!/system/bin/sh
#=============================================================================
# lib/write.sh - 只有写命令才用到的实现（由 webui.sh 按命令名懒加载）
#
# 为什么单独一个文件：一次调用的固定地板约 123~142ms，其中约 36ms 是读+lex 那 100KB
#       脚本、约 55ms 是把两百多个函数定义建出来（同样的字节数全改成 `:` 空操作只要
#       62ms —— 现量对照见 CHANGELOG）。而写命令的实现占 960 行 / 约 35KB：界面读
#       status / env / backend-info 时一行都不需要它们，所以搬出来，只在真的要写时
#       由 webui.sh source 进来。
#
# 边界由 tests/write-lazy.sh 钉住：这里的函数 ↔ 界面侧 WRITE_CMDS 那张表必须一一对应，
#       少一边就是"写命令找不到函数"或"读命令白背 35KB"。
#
# 用法：不要加进 lib/common.sh 的加载清单 —— 那等于白搬。
#=============================================================================
# 说明：把「未纳入」或「已排除」的应用加入目标文件。等价于手动写回文件；只改 apps 数组 /
#       target.txt，别的内容原样保留。包名来自界面列表，这里仍按规则再校验一次。
# ---------- 写前 diff 预览 ----------
# 说明：KL_PREVIEW=1 时 commit_backend_file 不落盘，把「现文件 → 新文件」的行级
#       差异（LCS，一次 awk 跑完，不逐行 fork）攒进 $KL_PREVIEW_DIFF 交给界面确认；
#       照常返回 0，调用方的 saved=1 / 日志 / 重启请求由各自的 KL_PREVIEW 闸门拦住。
# 用法：kl_capture_diff <旧文件> <新文件>   → stdout："- 旧行" / "+ 新行"
kl_capture_diff() {
    [ -f "$1" ] || return 0
    [ -n "${AWK_CMD:-}" ] || AWK_CMD=$(find_awk)
    [ -n "$AWK_CMD" ] || return 0
    "$AWK_CMD" 'FILENAME == ARGV[1] { old[++n] = $0; next }
{ new[++m] = $0 }
END {
  for (i = 0; i <= n; i++) L[i, 0] = 0
  for (j = 0; j <= m; j++) L[0, j] = 0
  for (i = 1; i <= n; i++) for (j = 1; j <= m; j++) L[i, j] = (old[i] == new[j]) ? L[i-1, j-1] + 1 : ((L[i-1, j] >= L[i, j-1]) ? L[i-1, j] : L[i, j-1])
  i = n; j = m; k = 0
  while (i > 0 && j > 0) {
    if (old[i] == new[j]) { i--; j--; continue }
    if (L[i-1, j] >= L[i, j-1]) { o[++k] = "- " old[i]; i-- }
    else { o[++k] = "+ " new[j]; j-- }
  }
  while (i > 0) { o[++k] = "- " old[i--] }
  while (j > 0) { o[++k] = "+ " new[j--] }
  for (i = k; i >= 1; i--) print o[i]
}' "$1" "$2" 2>/dev/null
}
commit_backend_file() {
    local target="$1" temp="$2" name="$3"
    if [ "${KL_PREVIEW:-0}" = "1" ]; then
        KL_PREVIEW_DIFF="${KL_PREVIEW_DIFF:-}$(kl_capture_diff "$target" "$temp")"
        rm -f "$temp" 2>/dev/null
        return 0
    fi
    write_atomic_preserve "$target" "$temp" "${KL_DIR}/${name}"
}
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
      # 注意不能用 `tr ',' '\n' | wc -l`：KL_REMOVED_LIST 是逗号拼接、**没有尾换行**，
      # 单项时 wc -l 得 0、多项时少 1 —— 界面会显示「移出 0 个」但实际删掉了。
      case "$KL_REMOVED_LIST" in
        '') removed=0 ;;
        *)  removed=$(( $(printf '%s' "$KL_REMOVED_LIST" | tr -cd ',' | wc -c) + 1 )) ;;
      esac
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
    prof=$(${AWK_CMD:-awk} -F"$TAB" '$1=="profile"{print $2; exit}' "$pairs")
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
    [ "$saved" = 1 ] && [ "${KL_PREVIEW:-0}" != "1" ] && { omk_restart injector; log_info "🧩 WebUI 更新 OMK injector.toml（$n 项）"; }
    kv saved "$saved"
    kv fields "$n"
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
        # 「生效代价」是判据不是副作用，预览也要算给用户看：以前整块留在非预览闸门后，
        # 于是预览里把一次「四个补丁字段整组热生效」报成 apply_scope=restart（界面据此
        # 提示要重启 keymint），与同一条命令真写时的答复相反。
        # 留在闸门后的是副作用：重启请求、日志条目（还没真写，不能留假条目）。
        scope=$(omk_apply_scope $keys)
        if [ "$scope" = hot ]; then
            # 四个补丁字段整组热生效：不重启，TA 原地更新，在途操作与 per-boot 计数不丢
            note="四个补丁字段整组热生效，没有重启 keymint"
        elif [ "${KL_PREVIEW:-0}" = "1" ]; then
            note=""          # 预览不请求重启，也就不能谎称「已请求」
        else
            omk_restart keymint
            note="已请求重启 keymint"
        fi
        if omk_reboot_needed "$old_vbk" "$new_vbk" "$old_vbh" "$new_vbh"; then
            scope=reboot
            note="vb_key/vb_hash 从 random 切到 auto：要重启【整机】才读得到启动元数据，重启 keymint 不够"
        fi
        [ "${KL_PREVIEW:-0}" = "1" ] || log_info "🧩 WebUI 更新 OMK config.toml（$n 项，生效代价 $scope）"
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
    sc=$(${AWK_CMD:-awk} -F"$TAB" '$1=="scope"{print $2; exit}' "$pairs")
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
    # 全新装的 Tricky 还没有这张表（它只在用户第一次保存时才存在）。awk 打不开
    # 输入文件会**在 END 之前就退出**，"文件不存在时按请求新建"那段根本跑不到 ——
    # 真机上第一次保存直接报"补丁表写入失败"。先落一个空文件让 awk 有得读。
    if [ ! -f "$target" ]; then
        mkdir -p "$TSTORE_DIR" 2>/dev/null
        : > "$target" 2>/dev/null || { echo "补丁表不存在且无法创建：$target" >&2; rm -rf "$dir"; return 1; }
    fi
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

# 用法：tricky-drop-patch <包名>；删掉 security_patch.txt 里那个 [包名] 块
cmd_tricky_drop_patch() {
    local scope="${1:-}" target out status st dir

    require_runnable || return 1
    detect_backend "$MODDIR"
    if [ "$KL_BACKEND" != "tricky" ]; then echo "当前后端不是 Tricky Store" >&2; return 1; fi
    case "$scope" in
        ''|global) echo "只能删按包段（[包名]）；全局段是补丁表的主体，不能删" >&2; return 1 ;;
    esac
    printf '%s' "$scope" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+$' \
        || { echo "scope 必须是合法包名：$scope" >&2; return 1; }
    [ -n "$AWK_CMD" ] || AWK_CMD=$(find_awk)
    [ -n "$AWK_CMD" ] && [ -f "${KL_PATCH%/*}/tricky_patch_set.awk" ] || { echo "缺少 tricky_patch_set.awk" >&2; return 1; }

    target="$TSTORE_DIR/security_patch.txt"
    [ -f "$target" ] || { echo "补丁表不存在：$target" >&2; return 1; }
    dir="${KL_DIR}/.kl_drop.$$"
    mkdir -p "$dir" 2>/dev/null && chmod 700 "$dir" 2>/dev/null || return 1
    out="$TSTORE_DIR/.security_patch.txt.keylens.$$"
    status="$dir/status"
    webui_lock || { rm -rf "$dir"; return 1; }
    $AWK_CMD -v drop="$scope" -v pairsfile=/dev/null -v statusfile="$status" \
        -f "${KL_PATCH%/*}/tricky_patch_set.awk" "$target" > "$out" 2>/dev/null
    st=$(cat "$status" 2>/dev/null)
    case "$st" in
        ok)
            if cmp -s "$out" "$target" 2>/dev/null; then
                rm -f "$out" 2>/dev/null
            elif ! commit_backend_file "$target" "$out" "security_patch.txt.bak"; then
                rm -f "$out" 2>/dev/null
                release_lock "${KL_DIR}/.kl_lock"
                rm -rf "$dir"
                echo "写入失败：$target" >&2
                return 1
            fi
            ;;
        missing)
            rm -f "$out" 2>/dev/null
            release_lock "${KL_DIR}/.kl_lock"
            rm -rf "$dir"
            echo "补丁表里没有 [$scope] 这一段" >&2
            return 1
            ;;
        *)
            rm -f "$out" 2>/dev/null
            release_lock "${KL_DIR}/.kl_lock"
            rm -rf "$dir"
            echo "补丁表删除失败" >&2
            return 1
            ;;
    esac
    release_lock "${KL_DIR}/.kl_lock"
    rm -rf "$dir" 2>/dev/null
    log_info "🧩 WebUI 删除 Tricky 补丁段（scope=$scope）"
    kv dropped 1
    kv scope "$scope"
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

# 用法：teesim-profile-new <名字>；把 default 的对象整份复制成一份新 profile。
# 复制而不是新建空白：上游 profile 有一批必填字段（keybox / mode / patchLevel /
# apps），缺了行为未定义；从 default 复制出来至少是一份能用、能再改的配置。
cmd_teesim_profile_new() {
    local name="${1:-}" out status st dir

    require_runnable || return 1
    detect_backend "$MODDIR"
    if [ "$KL_BACKEND" != "teesim" ]; then echo "当前后端不是 TEE Simulator" >&2; return 1; fi
    [ -f "$TEESIM_CONFIG" ] || { echo "配置不存在：$TEESIM_CONFIG" >&2; return 1; }
    case "$name" in
        ''|default) echo "名字不能为空，也不能叫 default" >&2; return 1 ;;
    esac
    printf '%s' "$name" | grep -Eq '^[A-Za-z0-9._-]+$' \
        || { echo "名字只能用字母、数字、. _ -：$name" >&2; return 1; }
    [ -n "$AWK_CMD" ] || AWK_CMD=$(find_awk)
    [ -n "$AWK_CMD" ] && [ -f "${KL_PATCH%/*}/teesim_profile.awk" ] || { echo "缺少 teesim_profile.awk" >&2; return 1; }

    dir="${KL_DIR}/.kl_prof.$$"
    mkdir -p "$dir" 2>/dev/null && chmod 700 "$dir" 2>/dev/null || return 1
    out="$TEESIM_DIR/.config.json.keylens.$$"
    status="$dir/status"
    webui_lock || { rm -rf "$dir"; return 1; }
    $AWK_CMD -v mode=new -v name="$name" -v statusfile="$status" \
        -f "${KL_PATCH%/*}/teesim_profile.awk" "$TEESIM_CONFIG" > "$out" 2>/dev/null
    st=$(cat "$status" 2>/dev/null)
    case "$st" in
        ok)
            if ! commit_backend_file "$TEESIM_CONFIG" "$out" "config.json.bak"; then
                rm -f "$out" 2>/dev/null
                release_lock "${KL_DIR}/.kl_lock"
                rm -rf "$dir"
                echo "写入失败：$TEESIM_CONFIG" >&2
                return 1
            fi
            ;;
        exists)
            rm -f "$out" 2>/dev/null
            release_lock "${KL_DIR}/.kl_lock"
            rm -rf "$dir"
            echo "profile 已存在：$name" >&2
            return 1
            ;;
        *)
            rm -f "$out" 2>/dev/null
            release_lock "${KL_DIR}/.kl_lock"
            rm -rf "$dir"
            echo "新建 profile 失败（配置里找不到 profiles.default？）" >&2
            return 1
            ;;
    esac
    release_lock "${KL_DIR}/.kl_lock"
    rm -rf "$dir" 2>/dev/null
    log_info "🧰 WebUI 新建 TEESim profile（$name，复制自 default）"
    kv created 1
    kv profile "$name"
}

# 用法：teesim-profile-del <名字>；删掉那个 profile（default 不许删）
cmd_teesim_profile_del() {
    local name="${1:-}" out status st dir

    require_runnable || return 1
    detect_backend "$MODDIR"
    if [ "$KL_BACKEND" != "teesim" ]; then echo "当前后端不是 TEE Simulator" >&2; return 1; fi
    [ -f "$TEESIM_CONFIG" ] || { echo "配置不存在：$TEESIM_CONFIG" >&2; return 1; }
    case "$name" in
        ''|default) echo "default 是兜底 profile，不能删" >&2; return 1 ;;
    esac
    printf '%s' "$name" | grep -Eq '^[A-Za-z0-9._-]+$' \
        || { echo "名字只能用字母、数字、. _ -：$name" >&2; return 1; }
    [ -n "$AWK_CMD" ] || AWK_CMD=$(find_awk)
    [ -n "$AWK_CMD" ] && [ -f "${KL_PATCH%/*}/teesim_profile.awk" ] || { echo "缺少 teesim_profile.awk" >&2; return 1; }

    dir="${KL_DIR}/.kl_prof.$$"
    mkdir -p "$dir" 2>/dev/null && chmod 700 "$dir" 2>/dev/null || return 1
    out="$TEESIM_DIR/.config.json.keylens.$$"
    status="$dir/status"
    webui_lock || { rm -rf "$dir"; return 1; }
    $AWK_CMD -v mode=del -v name="$name" -v statusfile="$status" \
        -f "${KL_PATCH%/*}/teesim_profile.awk" "$TEESIM_CONFIG" > "$out" 2>/dev/null
    st=$(cat "$status" 2>/dev/null)
    case "$st" in
        ok)
            if ! commit_backend_file "$TEESIM_CONFIG" "$out" "config.json.bak"; then
                rm -f "$out" 2>/dev/null
                release_lock "${KL_DIR}/.kl_lock"
                rm -rf "$dir"
                echo "写入失败：$TEESIM_CONFIG" >&2
                return 1
            fi
            ;;
        missing)
            rm -f "$out" 2>/dev/null
            release_lock "${KL_DIR}/.kl_lock"
            rm -rf "$dir"
            echo "没有这个 profile：$name" >&2
            return 1
            ;;
        *)
            rm -f "$out" 2>/dev/null
            release_lock "${KL_DIR}/.kl_lock"
            rm -rf "$dir"
            echo "删除 profile 失败" >&2
            return 1
            ;;
    esac
    release_lock "${KL_DIR}/.kl_lock"
    rm -rf "$dir" 2>/dev/null
    log_info "🧰 WebUI 删除 TEESim profile（$name）"
    kv removed 1
    kv profile "$name"
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
            elif commit_backend_file "$ov" "$out" "overrides.json.bak"; then
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

cmd_clear_log() {
    rm -f "$KL_LOG" "${KL_LOG}.tmp" 2>/dev/null
    log_info "🧹 WebUI 已清空运行日志缓冲"
    kv cleared 1
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
        # 界面的成功提示会以这条为准：保存成功不等于这次运行里已经应用上
        kv apply_note "已保存到配置，但立即应用失败（写入后读回不一致）；下次开机仍会再写一次"
    fi
    prop_now ro.boot.vbmeta.digest
    kv saved 1
    kv applied "$applied"
    kv current "$PROP_NOW"
}

# 说明：立刻按期望表写一次属性。
#       注意：ro.build.type 等字段已被 Zygote 读进 Java 静态字段的，运行期改写不会
#       回头刷新 —— 界面上要如实提示，彻底生效仍需重启。
# 复核用的那一次重读：单独一个函数，测试可以换成"退码非 0"或"只读到两行"的假读数。
# 为什么必须重新起进程读：本进程已经缓存过 module.prop 与属性快照，写完再读同一份
# 进程里的值等于拿旧快照自证。
props_readback() {
    sh "$MODDIR/webui.sh" props 2>/dev/null
}

cmd_props_apply() {
    local out bad tab rc want got

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
    out=$(props_readback); rc=$?
    # 复核必须"真读到一整屏"才算数。以前不管读没读到都往下走：子进程失败或输出被截
    # 成空时，下面那个 grep -c 会规规矩矩给出 0，于是界面收到 applied 1 + mismatch 0，
    # 把"复核根本没跑成"报成"写入并复核通过、0 项不符"。行数按期望表自己算，
    # 不写死数字（属性表加一行就会让这个判据变松）。
    want=$(props_expect_pairs | grep -c .)
    got=$(printf '%s\n' "$out" | grep -c .)
    if [ "$rc" != 0 ] || [ "${got:-0}" -lt "$want" ]; then
        echo "写入后复核失败（重读退码 $rc，读到 $got/$want 行），不能报已生效" >&2
        kv applied 0
        kv mismatch -1
        return 1
    fi
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
    # webui_lock 已经在这个进程手上，接力给可能被子进程（run_sync → bin/keylens sync）看到
    local KL_LOCK_HELD=1

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

# ---------- 备份回滚 ----------
# 三件必须做的事：① 只认映射表里的名字；② 回滚前把当前文件另存为
# <名>.pre-restore（600），这一步本身可撤销；③ 落盘用**目标文件**的属主与权限
# （OMK 的 injector.toml 属于 keystore:keystore，cp 成 root 会让 OMK 读不了）。
# keybox 另过一遍结构校验：回滚一份坏 keybox 比不回滚更糟。
# 用法：backup-restore <备份文件名>
cmd_backup_restore() {
    local name="$1" src tgt tmp pre own mode ac kbc msg ok_=0 rc=0

    require_runnable || return 1
    detect_backend "$MODDIR"
    case "$name" in ''|*/*|*..*) echo "备份名不合法：$name" >&2; return 1 ;; esac
    src="$KL_DIR/$name"
    tgt=$(backup_target_for "$name") || { echo "当前后端没有这个备份：$name" >&2; return 1; }
    [ -n "$tgt" ] || { echo "当前后端没有这个备份：$name" >&2; return 1; }
    [ -s "$src" ] || { echo "备份不存在或为空：$src" >&2; return 1; }
    if [ "$name" = "keybox.xml.bak" ]; then
        ac="${AWK_CMD:-$(find_awk)}"
        kbc="${KL_PATCH%/*}/keybox_check.awk"
        if [ -n "$ac" ] && [ -f "$kbc" ]; then
            msg=$("$ac" -v backend="$KL_BACKEND" -f "$kbc" "$src" 2>&1) && ok_=1
            [ "$ok_" = 1 ] || { echo "这份 keybox 备份结构不合格：${msg#err	}" >&2; return 1; }
        fi
    fi

    webui_lock || return 1
    own=$(stat -c %u:%g "$tgt" 2>/dev/null)
    mode=$(stat -c %a "$tgt" 2>/dev/null)
    pre="$KL_DIR/$name.pre-restore"
    tmp="$KL_DIR/.kl_restore.bak.$$"
    [ -f "$tgt" ] && cp -p "$tgt" "$pre" 2>/dev/null && chmod 600 "$pre" 2>/dev/null
    if cp -p "$src" "$tmp" 2>/dev/null && mv -f "$tmp" "$tgt" 2>/dev/null; then
        [ -n "$own" ] && chown "$own" "$tgt" 2>/dev/null
        [ -n "$mode" ] && chmod "$mode" "$tgt" 2>/dev/null
    else
        rm -f "$tmp" 2>/dev/null
        rc=1
    fi
    release_lock "${KL_DIR}/.kl_lock"
    if [ "$rc" != 0 ]; then echo "回滚失败：$tgt 没被改动" >&2; return 1; fi
    log_info "♻️ WebUI 用备份还原了 ${tgt##*/}（来源 $name）"
    kv restored 1
    kv name "$name"
}
