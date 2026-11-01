#=============================================================================
# backends/teesim_profile.awk - 新建 / 删除 TEE Simulator 的 profile
#
# 上游 config.json 的 profiles 是「名字 → 配置对象」的表。这个脚本只做两件事：
#   -v mode=new -v name=<n>   把 default 的对象整份复制一份，插在 profiles 末尾
#                              （不复制的话新 profile 缺必填字段，上游行为未定义）
#   -v mode=del -v name=<n>   删掉那个成员（连同它的逗号与换行）
# 其余字节逐字节保留；default 不许删；名字已存在时 new 报 exists。
#
# 用法：awk -v mode=new|del -v name=<n> -v statusfile=<文件> \
#           -f backends/teesim_profile.awk config.json
# 状态：ok / missing（找不到 profiles 或 default）/ exists / refused（删 default）
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

# 在 from 之后找 "key": { 这种**成员键**（不是字符串值），返回键的引号位置与对象起止
function find_member(s, from, key,   q, m, o, c) {
    while (1) {
        q = findstr(s, from, "\"" key "\"")
        if (q == 0) return 0
        m = q + length(key) + 2
        while (m <= length(s) && substr(s, m, 1) ~ /[ \t\r\n]/) m++
        if (substr(s, m, 1) == ":") {
            o = m + 1
            while (o <= length(s) && substr(s, o, 1) ~ /[ \t\r\n]/) o++
            if (substr(s, o, 1) == "{") {
                c = matchclose(s, o)
                if (c > 0) { Q = q; O = o; C = c; return 1 }
            }
        }
        from = q + length(key) + 2
    }
}

{ buf = buf $0 "\n" }

END {
    pp = findstr(buf, 1, "\"profiles\"")
    if (pp == 0) { print "missing" > statusfile; printf "%s", buf; exit }
    m = pp + 10
    while (m <= length(buf) && substr(buf, m, 1) ~ /[ \t\r\n]/) m++
    if (substr(buf, m, 1) != ":") { print "missing" > statusfile; printf "%s", buf; exit }
    pro = m + 1
    while (pro <= length(buf) && substr(buf, pro, 1) ~ /[ \t\r\n]/) pro++
    if (substr(buf, pro, 1) != "{") { print "missing" > statusfile; printf "%s", buf; exit }
    prc = matchclose(buf, pro)
    if (prc == 0) { print "missing" > statusfile; printf "%s", buf; exit }
    pobj = substr(buf, pro, prc - pro + 1)

    if (mode == "del") {
        if (name == "default") { print "refused" > statusfile; printf "%s", buf; exit }
        if (!find_member(pobj, 1, name)) { print "missing" > statusfile; printf "%s", buf; exit }
        # 绝对位置；成员键所在行的行首
        qa = pro + Q - 1
        ca = pro + C - 1
        st = qa
        while (st > 1 && substr(buf, st - 1, 1) != "\n") st--
        en = ca + 1
        while (en <= length(buf) && substr(buf, en, 1) ~ /[ \t]/) en++
        if (substr(buf, en, 1) == ",") { en++; while (en <= length(buf) && substr(buf, en, 1) ~ /[ \t]/) en++ }
        else {
            # 最后一个成员：删掉它前面的逗号，否则 JSON 多一个逗号
            k = qa - 1
            while (k > 1 && substr(buf, k, 1) ~ /[ \t\r\n]/) k--
            if (substr(buf, k, 1) == ",") st = k
        }
        if (substr(buf, en, 1) == "\n") en++
        printf "%s", substr(buf, 1, st - 1) substr(buf, en)
        print "ok" > statusfile
        exit
    }

    # mode == new
    if (find_member(pobj, 1, name)) { print "exists" > statusfile; printf "%s", buf; exit }
    if (!find_member(pobj, 1, "default")) { print "missing" > statusfile; printf "%s", buf; exit }
    dobj = substr(pobj, O, C - O + 1)
    # pobj 是从 pro 起的**子串**：下面所有下标都要用相对坐标（plen 处才是闭括号），
    # 拿绝对位置 prc 去切子串会把成员插到 profiles 的括号外面 —— JSON 直接坏掉。
    plen = prc - pro + 1
    # 成员缩进：取 default 键那一行的行首空白
    dstart = Q
    while (dstart > 1 && substr(pobj, dstart - 1, 1) != "\n") dstart--
    memberind = ""
    i = dstart
    while (i < Q && substr(pobj, i, 1) ~ /[ \t]/) { memberind = memberind substr(pobj, i, 1); i++ }
    # profiles 收尾花括号的缩进
    closeind = ""
    i = plen - 1
    while (i >= 1 && substr(pobj, i, 1) ~ /[ \t]/) { closeind = substr(pobj, i, 1) closeind; i-- }
    before = substr(pobj, 1, plen - 1)
    sub(/[ \t\r\n]+$/, "", before)
    if (before !~ /[{,]$/) before = before ","
    newpobj = before "\n" memberind "\"" name "\": " dobj "\n" closeind "}" substr(pobj, plen + 1)
    printf "%s", substr(buf, 1, pro - 1) newpobj substr(buf, prc + 1)
    print "ok" > statusfile
}
