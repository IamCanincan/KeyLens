#=============================================================================
# backends/omk_set.awk - 定点修改 OhMyKeymint 的 injector.toml / config.toml
#
# 只改请求里的键：已存在的行原位替换值（保留行内注释），不存在的插到所在段
# 末尾；段不存在时在文件末尾新建。其它行、注释、[crypto] 等段落逐字节保留。
# deny_packages 支持 []、单行数组与多行数组，整段替换成规范的单行数组。
#
# 用法：awk -v pairsfile=<key<TAB>value> -v target=<injector|config> \
#           -v statusfile=<文件> -f backends/omk_set.awk <toml>
# 状态：ok / same / missing
#=============================================================================

# 去掉字符串外的注释；返回注释（含 #）放在 COMMENT，主体放在 BODY
function split_comment(s,   i, c, instr, esc) {
    BODY = ""; COMMENT = ""; instr = 0; esc = 0
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (instr) {
            BODY = BODY c
            if (esc) esc = 0
            else if (c == "\\") esc = 1
            else if (c == "\"") instr = 0
            continue
        }
        if (c == "#") { COMMENT = substr(s, i); return }
        if (c == "\"") instr = 1
        BODY = BODY c
    }
}

function tomlesc(s,   out, i, c) {
    out = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\\") out = out "\\\\"
        else if (c == "\"") out = out "\\\""
        else if (c == "\t") out = out "\\t"
        else if (c == "\r") out = out "\\r"
        else if (c == "\n") out = out "\\n"
        else out = out c
    }
    return out
}

function fmt(v, type,   n, a, s, sep, j) {
    if (type == "bool") return (v == "true" ? "true" : "false")
    if (type == "array") {
        n = split(v, a, ",")
        s = "["; sep = ""
        for (j = 1; j <= n; j++) {
            gsub(/^[ \t]+|[ \t]+$/, "", a[j])
            if (a[j] == "") continue
            s = s sep "\"" tomlesc(a[j]) "\""
            sep = ", "
        }
        return s "]"
    }
    return "\"" tomlesc(v) "\""
}

# key 在当前段下要不要改；返回类型，空串表示不改
# 一个键的规范行
function flat_line(sec, key, type, v) {
    return key " = " fmt(v, type)
}

# key 在 injector.toml 的映射
function inj_key(k,   s) {
    if (k == "inj_main_enabled") return "main" SUBSEP "enabled"
    if (k == "inj_log_level") return "main" SUBSEP "log_level"
    if (k == "filter_enabled") return "filter" SUBSEP "enabled"
    if (k == "filter_block_android") return "filter" SUBSEP "block_android_package"
    if (k == "filter_allow_unknown") return "filter" SUBSEP "allow_unknown_package"
    if (k == "filter_deny") return "filter" SUBSEP "deny_packages"
    if (k ~ /^intercept_/) return "intercept" SUBSEP substr(k, 11)
    return ""
}

# key 在 config.toml 的映射
function cfg_key(k,   s) {
    if (k == "cfg_log_level") return "main" SUBSEP "log_level"
    if (k == "cfg_force_skip_biometric") return "main" SUBSEP "force_skip_system_biometric_hat_verification"
    if (k == "cfg_retire_stale_keys") return "main" SUBSEP "retire_stale_keybox_bound_keys"
    if (k == "trust_os_version") return "trust" SUBSEP "os_version"
    if (k == "trust_security_patch") return "trust" SUBSEP "security_patch"
    if (k == "trust_os_patchlevel") return "trust" SUBSEP "os_patchlevel"
    if (k == "trust_vendor_patchlevel") return "trust" SUBSEP "vendor_patchlevel"
    if (k == "trust_boot_patchlevel") return "trust" SUBSEP "boot_patchlevel"
    if (k == "trust_vb_key") return "trust" SUBSEP "vb_key"
    if (k == "trust_vb_hash") return "trust" SUBSEP "vb_hash"
    if (k == "trust_verified_boot") return "trust" SUBSEP "verified_boot_state"
    if (k == "trust_device_locked") return "trust" SUBSEP "device_locked"
    if (k == "dev_override_telephony") return "device" SUBSEP "overrideTelephonyProperties"
    if (k ~ /^dev_/) return "device" SUBSEP substr(k, 5)
    return ""
}

function key_type(k) {
    if (k ~ /^(inj_main_enabled|filter_enabled|filter_block_android|filter_allow_unknown)$/) return "bool"
    if (k ~ /^intercept_/) return "bool"
    if (k ~ /^(cfg_force_skip_biometric|cfg_retire_stale_keys|trust_verified_boot|trust_device_locked|dev_override_telephony)$/) return "bool"
    if (k == "filter_deny") return "array"
    return "str"
}

BEGIN {
    nw = 0
    while ((getline ln < pairsfile) > 0) {
        p = index(ln, "\t")
        if (p <= 1) continue
        k = substr(ln, 1, p - 1); v = substr(ln, p + 1)
        if (target == "injector") map = inj_key(k)
        else map = cfg_key(k)
        if (map == "") continue
        split(map, parts, SUBSEP)
        sec = parts[1]; key = parts[2]
        nw++; wsec[nw] = sec; wkey[nw] = key; wval[nw] = v; wtype[nw] = key_type(k)
        WANT[sec SUBSEP key] = wtype[nw]
    }
    close(pairsfile)
}

{ lines[++nl] = $0; buf = buf $0 "\n" }

END {
    out = ""; sec = ""; seen[""] = 1
    for (i = 1; i <= nl; i++) {
        line = lines[i]

        if (line ~ /^[ \t]*\[/) {
            flush_missing(sec)
            ob = index(line, "[")
            cb = index(line, "]")
            sec = cb > ob ? substr(line, ob + 1, cb - ob - 1) : ""
            seen[sec] = 1
            out = out line "\n"
            continue
        }

        # deny_packages：可能是多行数组，整段吃掉
        if (sec == "filter" && line ~ /^[ \t]*deny_packages[ \t]*=[ \t]*\[/) {
            indent = line; sub(/[^ \t].*$/, "", indent)
            rest = line
            start = index(rest, "[")
            close_at = index(substr(rest, start), "]")
            j = i
            while (close_at == 0 && j < nl) {
                j++
                rest = rest " " lines[j]
                close_at = index(substr(rest, start), "]")
            }
            if (close_at > 0) {
                endj = j
                v = wval_for(sec, "deny_packages")
                if (v != "\001") {
                    out = out indent flat_line(sec, "deny_packages", "array", v) "\n"
                    handled[sec SUBSEP "deny_packages"] = 1
                    i = endj
                    continue
                }
            }
        }

        # 普通 key = value
        if (line ~ /^[ \t]*[A-Za-z0-9_][A-Za-z0-9_]*[ \t]*=/) {
            split_comment(line)
            body = BODY
            key = body
            sub(/[ \t]*=.*$/, "", key)
            gsub(/^[ \t]+|[ \t]+$/, "", key)
            if ((sec SUBSEP key) in WANT && !(sec SUBSEP key in handled)) {
                indent = line; sub(/[^ \t].*$/, "", indent)
                v = wval_for(sec, key)
                if (v != "\001") {
                    out = out indent flat_line(sec, key, WANT[sec SUBSEP key], v) \
                          (COMMENT == "" ? "" : " " COMMENT) "\n"
                    handled[sec SUBSEP key] = 1
                    continue
                }
            }
        }

        out = out line "\n"
    }
    flush_missing(sec)

    # 文件里没有的段：在末尾新建
    for (j = 1; j <= nw; j++) {
        if (seen[wsec[j]]) continue
        seen[wsec[j]] = 1
        out = out "\n[" wsec[j] "]\n"
        for (t = 1; t <= nw; t++) {
            if (wsec[t] != wsec[j]) continue
            it = wsec[t] SUBSEP wkey[t]
            if (it in handled) continue
            out = out flat_line(wsec[t], wkey[t], wtype[t], wval[t]) "\n"
            handled[it] = 1
        }
    }

    if (out == buf) print "same" > statusfile
    else print "ok" > statusfile
    if (nl == 0) { print "missing" > statusfile; printf "%s", buf; exit }
    printf "%s", out
}

function flush_missing(s,   j, it) {
    for (j = 1; j <= nw; j++) {
        if (wsec[j] != s) continue
        it = wsec[j] SUBSEP wkey[j]
        if (it in handled) continue
        out = out flat_line(wsec[j], wkey[j], wtype[j], wval[j]) "\n"
        handled[it] = 1
    }
}

function wval_for(s, k,   j) {
    for (j = 1; j <= nw; j++)
        if (wsec[j] == s && wkey[j] == k) return wval[j]
    return "\001"
}
