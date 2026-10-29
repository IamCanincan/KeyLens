#=============================================================================
# backends/omk_info.awk - 只读提取 OhMyKeymint 两份配置的摘要
#
# injector.toml：version / [main] / [filter]（enabled、deny 数量、两个开关）/
#                [intercept] 中 true 的条数
# config.toml  ：version / [main].log_level / [trust] 的补丁与验证开关
#
# 只读，不写任何文件。TOML 只处理本模块关心的标量与 deny_packages 数组，
# 其余内容（含 [crypto]）一律不读出、不打印。
#
# 用法：awk -v injector=<path> -v config=<path> -f backends/omk_info.awk <injector> <config>
#=============================================================================

function findstr(s, from, needle,   i, l) {
    l = length(needle)
    for (i = from; i + l - 1 <= length(s); i++)
        if (substr(s, i, l) == needle) return i
    return 0
}

function matchclose(s, openpos,   i, c, depth, instr, esc) {
    depth = 0; instr = 0; esc = 0
    for (i = openpos; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (instr) {
            if (esc) { esc = 0 } else if (c == "\\") { esc = 1 } else if (c == "\"") { instr = 0 }
            continue
        }
        if (c == "\"") { instr = 1; continue }
        if (c == "{" || c == "[") depth++
        else if (c == "}" || c == "]") { depth--; if (depth == 0) return i }
    }
    return 0
}

# 说明：去掉字符串外的 # 注释并 trim
function clean(s,   i, c, instr, esc, out) {
    out = ""; instr = 0; esc = 0
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (instr) {
            out = out c
            if (esc) esc = 0
            else if (c == "\\") esc = 1
            else if (c == "\"") instr = 0
            continue
        }
        if (c == "#") break
        if (c == "\"") instr = 1
        out = out c
    }
    gsub(/^[ \t]+|[ \t]+$/, "", out)
    return out
}

function unquote(v) {
    if (v ~ /^".*"$/) return substr(v, 2, length(v) - 2)
    return v
}

function kv(line,   e, k, v) {
    e = index(line, "=")
    if (e == 0) return 0
    k = substr(line, 1, e - 1); gsub(/^[ \t]+|[ \t]+$/, "", k)
    v = substr(line, e + 1);    gsub(/^[ \t]+|[ \t]+$/, "", v)
    KEY = k; VAL = unquote(v)
    return 1
}

FNR == 1 { sec = "" }   # 换文件时重新从顶层开始

FILENAME == injector { ibuf = ibuf $0 "\n" }
FILENAME == config   { cbuf = cbuf $0 "\n" }

FILENAME == injector {
    line = clean($0)
    if (line == "") next
    if (line ~ /^\[/) {
        sec = line; gsub(/^\[|\]$/, "", sec)
        next
    }
    if (!kv(line)) next
    if (sec == "" && KEY == "version") print "injector_version=" VAL
    else if (sec == "main" && KEY == "enabled") print "injector_main_enabled=" VAL
    else if (sec == "main" && KEY == "log_level") print "injector_log_level=" VAL
    else if (sec == "filter" && KEY == "enabled") print "filter_enabled=" VAL
    else if (sec == "filter" && KEY == "block_android_package") print "filter_block_android=" VAL
    else if (sec == "filter" && KEY == "allow_unknown_package") print "filter_allow_unknown=" VAL
    else if (sec == "intercept") {
        print "intercept_" KEY "=" VAL
        if (VAL == "true") intercept_true++
    }
    next
}

FILENAME == config {
    line = clean($0)
    if (line == "") next
    if (line ~ /^\[/) {
        sec = line; gsub(/^\[|\]$/, "", sec)
        next
    }
    if (!kv(line)) next
    if (sec == "" && KEY == "version") print "config_version=" VAL
    else if (sec == "main" && KEY == "log_level") print "config_log_level=" VAL
    else if (sec == "main" && KEY == "force_skip_system_biometric_hat_verification") print "cfg_force_skip_biometric=" VAL
    else if (sec == "main" && KEY == "retire_stale_keybox_bound_keys") print "cfg_retire_stale_keys=" VAL
    else if (sec == "device") {
        if (KEY == "brand") print "dev_brand=" VAL
        else if (KEY == "device") print "dev_device=" VAL
        else if (KEY == "product") print "dev_product=" VAL
        else if (KEY == "manufacturer") print "dev_manufacturer=" VAL
        else if (KEY == "model") print "dev_model=" VAL
        else if (KEY == "serial") print "dev_serial=" VAL
        else if (KEY == "imei") print "dev_imei=" VAL
        else if (KEY == "imei2") print "dev_imei2=" VAL
        else if (KEY == "meid") print "dev_meid=" VAL
        else if (KEY == "overrideTelephonyProperties") print "dev_override_telephony=" VAL
    }
    else if (sec == "trust") {
        if (KEY == "os_version") print "trust_os_version=" VAL
        else if (KEY == "security_patch") print "trust_security_patch=" VAL
        else if (KEY == "os_patchlevel") print "trust_os_patchlevel=" VAL
        else if (KEY == "vendor_patchlevel") print "trust_vendor_patchlevel=" VAL
        else if (KEY == "boot_patchlevel") print "trust_boot_patchlevel=" VAL
        else if (KEY == "vb_key") print "trust_vb_key=" VAL
        else if (KEY == "vb_hash") print "trust_vb_hash=" VAL
        else if (KEY == "verified_boot_state") print "trust_verified_boot=" VAL
        else if (KEY == "device_locked") print "trust_device_locked=" VAL
    }
    next
}

END {
    print "intercept_true=" intercept_true + 0

    # deny_packages 可能是 []、一行数组或多行数组；只数引号里的条目。
    # 键必须写在行首（允许缩进），避免匹配到注释里的同名字样。
    if (match(ibuf, /(^|\n)[ \t]*deny_packages[ \t]*=[ \t]*\[/)) {
        ob = RSTART + RLENGTH - 1
        cb = matchclose(ibuf, ob)
        if (cb > ob) {
            seg = substr(ibuf, ob + 1, cb - ob - 1)
            while (match(seg, /"[^"]*"/)) {
                deny++
                dl = dl (deny > 1 ? "," : "") substr(seg, RSTART + 1, RLENGTH - 2)
                seg = substr(seg, RSTART + RLENGTH)
            }
        }
    }
    print "filter_deny=" deny + 0
    print "filter_deny_list=" dl
}
