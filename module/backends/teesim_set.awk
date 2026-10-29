#=============================================================================
# backends/teesim_set.awk - 定点修改 TEE Simulator 某个 profile 的字段
#
# 只改请求里的键：已存在的标量原位替换，不存在的插到目标 profile 对象末尾；
#   apps 数组、其它 profile、其它字段逐字节保留。
# 字符串值由调用方先校验，这里只负责 JSON 转义。
#
# 用法：awk -v pairsfile=<key<TAB>value> -v statusfile=<文件> \
#           [-v profile=<名字>] -f backends/teesim_set.awk config.json
#   profile 省略时是 default —— 上游 profiles 是一张「名字→配置」的表，
#   以前这里写死只改 default，其余 profile 在界面上根本改不动。
# 状态：ok=有改动；same=无需改；missing=定位不到 profiles.<profile>
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

function jesc(s,   out, i, c) {
    out = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\\") out = out "\\\\"
        else if (c == "\"") out = out "\\\""
        else if (c == "\n") out = out "\\n"
        else if (c == "\r") out = out "\\r"
        else if (c == "\t") out = out "\\t"
        else out = out c
    }
    return out
}

# 值（字符串或字面量）结束位置的后一位
function value_end(s, i,   c, esc) {
    c = substr(s, i, 1)
    if (c == "\"") {
        i++; esc = 0
        while (i <= length(s)) {
            c = substr(s, i, 1)
            if (esc) esc = 0
            else if (c == "\\") esc = 1
            else if (c == "\"") return i + 1
            i++
        }
        return length(s) + 1
    }
    while (i <= length(s)) {
        c = substr(s, i, 1)
        if (c == "," || c == "}" || c == "]" || c == "\n") return i
        i++
    }
    return i
}

# 替换对象里的 "key": <value>；没有这个键返回 0
function replace_scalar(obj, key, literal,   pat, i, e, old) {
    pat = "\"" key "\"[ \t\r\n]*:"
    if (!match(obj, pat)) return 0
    i = RSTART + RLENGTH
    while (i <= length(obj) && substr(obj, i, 1) ~ /[ \t]/) i++
    e = value_end(obj, i)
    old = substr(obj, i, e - i)
    REPLACED = substr(obj, 1, i - 1) literal substr(obj, e)
    CHANGED = (old != literal)
    return 1
}

# 在对象末尾插入 "key": <literal>
function insert_member(obj, key, literal,   cend, i, before, ind, closeind) {
    cend = length(obj)
    while (cend > 1 && substr(obj, cend, 1) != "}") cend--
    closeind = ""
    i = cend - 1
    while (i >= 1 && substr(obj, i, 1) ~ /[ \t]/) { closeind = substr(obj, i, 1) closeind; i-- }
    if (i >= 1 && substr(obj, i, 1) != "\n") closeind = "  "
    ind = closeind "  "

    before = substr(obj, 1, cend - 1)
    sub(/[ \t\r\n]+$/, "", before)
    if (before !~ /[{,]$/) before = before ","
    INSERTED = before "\n" ind "\"" key "\": " literal "\n" closeind "}" substr(obj, cend + 1)
}

BEGIN {
    np = 0
    while ((getline ln < pairsfile) > 0) {
        p = index(ln, "\t")
        if (p > 1) { np++; pk[np] = substr(ln, 1, p - 1); pv[np] = substr(ln, p + 1) }
    }
    close(pairsfile)
}

{ buf = buf $0 "\n" }

END {
    pp = findstr(buf, 1, "\"profiles\"")
    if (pp == 0) { print "missing" > statusfile; printf "%s", buf; exit }
    pname = (profile == "" ? "default" : profile)
    pkey = "\"" pname "\""
    # 必须确认找到的是"键"而不是某个字符串值（profile 叫 alt/default 时，
    # 文件里 apps、keybox 名等地方都可能出现同名串）—— 只有后面紧跟冒号
    # 再跟 { 的才算一个 profile 对象。认错位置的代价是写坏用户配置。
    from = pp + 10; dp = 0; db = 0
    while (1) {
        q = findstr(buf, from, pkey)
        if (q == 0) break
        m = q + length(pkey)
        while (m <= length(buf) && substr(buf, m, 1) ~ /[ \t\r\n]/) m++
        if (substr(buf, m, 1) == ":") {
            o = m + 1
            while (o <= length(buf) && substr(buf, o, 1) ~ /[ \t\r\n]/) o++
            if (substr(buf, o, 1) == "{") { dp = q; db = o; break }
        }
        from = q + length(pkey)
    }
    if (dp == 0) { print "missing" > statusfile; printf "%s", buf; exit }
    dc = matchclose(buf, db)
    if (dc == 0) { print "missing" > statusfile; printf "%s", buf; exit }

    dobj = substr(buf, db, dc - db + 1)
    changed = 0

    # ---------- patchLevel（嵌套对象） ----------
    have_ps = have_pv = have_pb = 0
    for (i = 1; i <= np; i++) {
        if (pk[i] == "patch_system") { have_ps = 1; ps = pv[i] }
        else if (pk[i] == "patch_vendor") { have_pv = 1; pv2 = pv[i] }
        else if (pk[i] == "patch_boot") { have_pb = 1; pb = pv[i] }
    }
    if (have_ps || have_pv || have_pb) {
        plpat = "\"patchLevel\"[ \t\r\n]*:"
        if (match(dobj, plpat)) {
            i = RSTART + RLENGTH
            while (i <= length(dobj) && substr(dobj, i, 1) ~ /[ \t]/) i++
            if (substr(dobj, i, 1) == "{") {
                pe = matchclose(dobj, i)
                pobj = substr(dobj, i, pe - i + 1)
                if (have_ps) {
                    if (replace_scalar(pobj, "system", "\"" jesc(ps) "\"")) { pobj = REPLACED; if (CHANGED) changed = 1 }
                    else { insert_member(pobj, "system", "\"" jesc(ps) "\""); pobj = INSERTED; changed = 1 }
                }
                if (have_pv) {
                    if (replace_scalar(pobj, "vendor", "\"" jesc(pv2) "\"")) { pobj = REPLACED; if (CHANGED) changed = 1 }
                    else { insert_member(pobj, "vendor", "\"" jesc(pv2) "\""); pobj = INSERTED; changed = 1 }
                }
                if (have_pb) {
                    if (replace_scalar(pobj, "boot", "\"" jesc(pb) "\"")) { pobj = REPLACED; if (CHANGED) changed = 1 }
                    else { insert_member(pobj, "boot", "\"" jesc(pb) "\""); pobj = INSERTED; changed = 1 }
                }
                dobj = substr(dobj, 1, i - 1) pobj substr(dobj, pe + 1)
            }
        } else {
            lit = "{"
            sep = ""
            if (have_ps) { lit = lit sep "\"system\": \"" jesc(ps) "\""; sep = ", " }
            if (have_pv) { lit = lit sep "\"vendor\": \"" jesc(pv2) "\""; sep = ", " }
            if (have_pb) { lit = lit sep "\"boot\": \"" jesc(pb) "\"" }
            lit = lit "}"
            insert_member(dobj, "patchLevel", lit); dobj = INSERTED; changed = 1
        }
    }

    # ---------- 顶层字段 ----------
    for (i = 1; i <= np; i++) {
        k = pk[i]; v = pv[i]
        if (k == "patch_system" || k == "patch_vendor" || k == "patch_boot") continue
        jk = k
        if (k == "os_version") jk = "osVersion"
        else if (k == "auto_include") {
            jk = "autoIncludeNewApps"
            lit = (v == "true" ? "true" : "false")
        }
        if (k != "auto_include") lit = "\"" jesc(v) "\""
        if (replace_scalar(dobj, jk, lit)) { dobj = REPLACED; if (CHANGED) changed = 1 }
        else { insert_member(dobj, jk, lit); dobj = INSERTED; changed = 1 }
    }

    if (changed) { print "ok" > statusfile }
    else { print "same" > statusfile }
    printf "%s%s%s", substr(buf, 1, db - 1), dobj, substr(buf, dc + 1)
}
