#=============================================================================
# backends/teesim_profiles.awk - 只读枚举 TEE Simulator 的所有 profile
#
# 为什么单独一个命令：上游 config.json 的 `profiles` 是一张「名字 → 配置」的表，
# 一个 profile 自带 keybox / mode / 三档补丁级别 / 设备身份 / apps / 自动纳入。
# 而写回路径以前只认 `profiles.default` —— 多 profile 是 TEESim 的核心概念，
# 界面上却根本不存在这一层。这里先把"有几个、各是什么"读出来。
#
# 只读，不写任何东西。解析不到 profiles 时不输出、退出码 1（调用方决定怎么显示）。
#
# 用法：awk -f backends/teesim_profiles.awk config.json
# 输出：每行「名字<TAB>keybox<TAB>mode<TAB>apps数<TAB>是否默认(1|0)」，
#       default 排在第一行，其余按文件里出现的顺序。
#=============================================================================

function findstr(s, from, needle,   i, l) {
    l = length(needle)
    for (i = from; i + l - 1 <= length(s); i++)
        if (substr(s, i, l) == needle) return i
    return 0
}

# 说明：从 openpos 处的 { 或 [ 找到与之配对的闭合位置（跳过字符串内的括号）
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

# 说明：从 pos 之后取下一个字符串值的内容（跳过空白与冒号）
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

function obj_string(obj, key,   p) {
    p = findstr(obj, 1, "\"" key "\"")
    if (p == 0) return ""
    p = findstr(obj, p + length(key) + 2, ":")
    if (p == 0) return ""
    return next_string(obj, p + 1)
}

# 说明：数 "key": [ "a", "b" ] 里的条目数。只数顶层数组里的字符串，
#       所以嵌套对象里的字符串不会被误算进来。
function count_array(obj, key,   p, open, cl, body, i, c, n, instr, esc) {
    p = findstr(obj, 1, "\"" key "\"")
    if (p == 0) return 0
    p = findstr(obj, p + length(key) + 2, ":")
    if (p == 0) return 0
    i = p + 1
    while (i <= length(obj) && substr(obj, i, 1) ~ /[ \t\r\n]/) i++
    if (substr(obj, i, 1) != "[") return 0
    open = i
    cl = matchclose(obj, open)
    if (cl == 0) return 0
    body = substr(obj, open + 1, cl - open - 1)
    n = 0; instr = 0; esc = 0
    for (i = 1; i <= length(body); i++) {
        c = substr(body, i, 1)
        if (instr) {
            if (esc) { esc = 0 }
            else if (c == "\\") { esc = 1 }
            else if (c == "\"") { instr = 0; n++ }   # 每个闭合的字符串算一条
            continue
        }
        if (c == "\"") { instr = 1; continue }
        if (c == "{" || c == "[") return n            # 顶层就遇到对象：不猜
    }
    return n    # 每个字符串只在闭合那次计数，所以不折半
}

BEGIN { TAB = sprintf("%c", 9); s = ""; def = ""; nd = 0 }

{ s = s $0 "\n" }

END {
    p = findstr(s, 1, "\"profiles\"")
    if (p == 0) exit 1
    p = findstr(s, p + 10, ":")
    if (p == 0) exit 1
    i = p + 1
    while (i <= length(s) && substr(s, i, 1) ~ /[ \t\r\n]/) i++
    if (substr(s, i, 1) != "{") exit 1
    pend = matchclose(s, i)
    if (pend == 0) exit 1
    obj = substr(s, i, pend - i + 1)

    # 扫 profiles 对象的一层：每个 "名字" 后面跟 : 和 { 才算一个 profile
    depth = 0; instr = 0; esc = 0; j = 2
    while (j <= length(obj)) {
        c = substr(obj, j, 1)
        if (instr) {
            if (esc) { esc = 0 } else if (c == "\\") { esc = 1 } else if (c == "\"") { instr = 0 }
            j++; continue
        }
        if (c == "\"") {
            # 只有"键"才配冒号；值字符串（keybox 里的名字等）跳过
            k = j + 1; q = ""
            while (k <= length(obj)) {
                cc = substr(obj, k, 1)
                if (esc2 = (cc == "\\")) { q = q substr(obj, k + 1, 1); k += 2; continue }
                if (cc == "\"") break
                q = q cc; k++
            }
            m = k + 1
            while (m <= length(obj) && substr(obj, m, 1) ~ /[ \t\r\n]/) m++
            if (substr(obj, m, 1) == ":" && q != "") {
                o = m + 1
                while (o <= length(obj) && substr(obj, o, 1) ~ /[ \t\r\n]/) o++
                if (substr(obj, o, 1) == "{") {
                    e = matchclose(obj, o)
                    if (e > 0) {
                        sub_obj = substr(obj, o, e - o + 1)
                        nd++
                        d_name[nd] = q
                        d_kb[nd] = obj_string(sub_obj, "keybox")
                        d_mode[nd] = obj_string(sub_obj, "mode")
                        d_apps[nd] = count_array(sub_obj, "apps")
                        j = e + 1
                        continue
                    }
                }
            }
            j = k + 1
            continue
        }
        if (c == "{" || c == "[") depth++
        else if (c == "}" || c == "]") depth--
        j++
    }

    for (t = 1; t <= nd; t++) {
        if (d_name[t] == "default") { def = t; break }
    }
    if (def) emit(def)
    for (t = 1; t <= nd; t++) if (t != def) emit(t)
    exit(nd > 0 ? 0 : 1)
}

function emit(t) {
    printf "%s%s%s%s%s%s%s%s%s\n", d_name[t], TAB, \
        (d_kb[t] == "" ? "-" : d_kb[t]), TAB, \
        (d_mode[t] == "" ? "patch" : d_mode[t]), TAB, d_apps[t] + 0, TAB, \
        (d_name[t] == "default" ? 1 : 0)
}
