#=============================================================================
# backends/teesim_list.awk - 只读提取 TEE Simulator 的应用列表
#
# 职责：从 config.json 中取出 profiles.default.apps 的包名，供 WebUI 展示。
#       与 teesim.awk 用同样的逐级定位方式，但本脚本不写任何东西。
#
# 用法：awk -f backends/teesim_list.awk config.json
# 输出：每行一个包名；无法定位 apps 数组时无输出且退出码为 1
#=============================================================================

# 说明：在字符串 s 中自 from 位置起查找 needle，返回下标（从 1 起），未找到返回 0
function findstr(s, from, needle,   i, l) {
    l = length(needle)
    for (i = from; i + l - 1 <= length(s); i++)
        if (substr(s, i, l) == needle) return i
    return 0
}

# 说明：返回与 openpos 处左括号配对的右括号下标；跳过字符串内的括号与转义字符
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

# ---------- 读入整个配置文件 ----------
{ buf = buf $0 "\n" }

# ---------- 定位并抽取 default profile 的 apps 数组 ----------
END {
    # 逐级定位 profiles -> default -> default 内的 apps 数组，任一步失败即放弃
    pp = findstr(buf, 1, "\"profiles\"")
    if (pp == 0) exit 1
    dp = findstr(buf, pp, "\"default\"")
    if (dp == 0) exit 1
    ob = findstr(buf, dp + 9, "{")
    if (ob == 0) exit 1
    cb = matchclose(buf, ob)
    if (cb == 0) exit 1
    ap = findstr(buf, ob, "\"apps\"")
    if (ap == 0 || ap > cb) exit 1
    ab = findstr(buf, ap + 6, "[")
    if (ab == 0 || ab > cb) exit 1
    ae = matchclose(buf, ab)
    if (ae == 0 || ae > cb) exit 1

    # 数组区间内的字符串项即包名（逐个匹配 "..."，跳过其间的键名与符号）
    seg = substr(buf, ab + 1, ae - ab - 1)
    while (match(seg, /"[^"]*"/)) {
        print substr(seg, RSTART + 1, RLENGTH - 2)
        seg = substr(seg, RSTART + RLENGTH)
    }
}
