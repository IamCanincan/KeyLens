#=============================================================================
# backends/teesim_info.awk - 只读提取 TEE Simulator 配置摘要
#
# 只读 config.json 中 default profile 的少量字段与 profiles 数量，供「后端」页
# 展示。不写任何东西；定位不到 profiles/default 时退出码为 1（由调用方决定
# 显示"—"还是报错）。
#
# 用法：awk -f backends/teesim_info.awk config.json
# 输出：key=value（version / profiles / default_mode / default_keybox /
#       default_patch_system / default_patch_vendor / default_patch_boot /
#       default_os_version）
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

# 说明：从 pos 之后的下一个字符串值（跳过键名与冒号）返回内容；没有则返回空
function next_string(s, pos,   i, j, c, esc) {
    i = pos
    while (i <= length(s)) {
        c = substr(s, i, 1)
        if (c == "\"") {
            j = i + 1; esc = 0
            while (j <= length(s)) {
                c = substr(s, j, 1)
                if (esc) { esc = 0 }
                else if (c == "\\") { esc = 1 }
                else if (c == "\"") return substr(s, i + 1, j - i - 1)
                j++
            }
            return ""
        }
        if (c == "{" || c == "[" || c == "}") return ""
        i++
    }
    return ""
}

# 说明：在一个 JSON 对象片段中取 "key": "字符串" 的值
function obj_string(obj, key,   p) {
    p = findstr(obj, 1, "\"" key "\"")
    if (p == 0) return ""
    p = findstr(obj, p + length(key) + 2, ":")
    if (p == 0) return ""
    return next_string(obj, p + 1)
}

# 说明：取 "key": 123 这类数字值（顶层 version 是数字，不是字符串）
function obj_number(obj, key,   p, i, c, s) {
    p = findstr(obj, 1, "\"" key "\"")
    if (p == 0) return ""
    p = findstr(obj, p + length(key) + 2, ":")
    if (p == 0) return ""
    i = p + 1
    while (i <= length(obj) && substr(obj, i, 1) ~ /[ \t\r\n]/) i++
    s = ""
    while (i <= length(obj)) {
        c = substr(obj, i, 1)
        if (c !~ /[0-9-]/) break
        s = s c
        i++
    }
    return s
}

# 说明：取 "key": true|false 的布尔值
function obj_bool(obj, key,   p, i) {
    p = findstr(obj, 1, "\"" key "\"")
    if (p == 0) return ""
    p = findstr(obj, p + length(key) + 2, ":")
    if (p == 0) return ""
    i = p + 1
    while (i <= length(obj) && substr(obj, i, 1) ~ /[ \t\r\n]/) i++
    if (substr(obj, i, 4) == "true") return "true"
    if (substr(obj, i, 5) == "false") return "false"
    return ""
}

# 说明：数一个 JSON 对象里的顶层键（只有后面跟着冒号的字符串才算键）
function count_keys(obj,   i, c, j, esc, depth) {
    depth = 0; i = 1
    while (i <= length(obj)) {
        c = substr(obj, i, 1)
        if (c == "\"") {
            j = i + 1; esc = 0
            while (j <= length(obj)) {
                c = substr(obj, j, 1)
                if (esc) esc = 0
                else if (c == "\\") esc = 1
                else if (c == "\"") break
                j++
            }
            if (depth == 1) {
                k = j + 1
                while (k <= length(obj) && substr(obj, k, 1) ~ /[ \t\r\n]/) k++
                if (substr(obj, k, 1) == ":") n++
            }
            i = j + 1
            continue
        }
        if (c == "{" || c == "[") depth++
        else if (c == "}" || c == "]") depth--
        i++
    }
    return n
}

{ buf = buf $0 "\n" }

END {
    pp = findstr(buf, 1, "\"profiles\"")
    if (pp == 0) exit 1
    pw = findstr(buf, pp + 10, "{")
    if (pw == 0) exit 1
    pc = matchclose(buf, pw)
    if (pc == 0) exit 1
    pobj = substr(buf, pw, pc - pw + 1)

    dp = findstr(buf, pp + 10, "\"default\"")
    if (dp == 0 || dp > pc) exit 1
    db = findstr(buf, dp + 9, "{")
    if (db == 0) exit 1
    dc = matchclose(buf, db)
    if (dc == 0) exit 1
    dobj = substr(buf, db, dc - db + 1)

    print "config_version=" obj_number(buf, "version")
    print "profiles=" count_keys(pobj)
    print "default_mode=" obj_string(dobj, "mode")
    print "default_keybox=" obj_string(dobj, "keybox")
    print "default_os_version=" obj_string(dobj, "osVersion")
    print "default_auto_include=" obj_bool(dobj, "autoIncludeNewApps")
    print "default_brand=" obj_string(dobj, "brand")
    print "default_device=" obj_string(dobj, "device")
    print "default_product=" obj_string(dobj, "product")
    print "default_manufacturer=" obj_string(dobj, "manufacturer")
    print "default_model=" obj_string(dobj, "model")
    print "default_serial=" obj_string(dobj, "serial")
    print "default_imei=" obj_string(dobj, "imei")
    print "default_meid=" obj_string(dobj, "meid")
    print "default_imei2=" obj_string(dobj, "imei2")

    pl = findstr(dobj, 1, "\"patchLevel\"")
    if (pl > 0) {
        pb = findstr(dobj, pl + 12, "{")
        if (pb > 0) {
            pcb = matchclose(dobj, pb)
            if (pcb > 0) {
                pobj2 = substr(dobj, pb, pcb - pb + 1)
                print "default_patch_system=" obj_string(pobj2, "system")
                print "default_patch_vendor=" obj_string(pobj2, "vendor")
                print "default_patch_boot=" obj_string(pobj2, "boot")
            }
        }
    }
}
