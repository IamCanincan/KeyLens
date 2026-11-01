#=============================================================================
# backends/teesim_overrides.awk - 只读汇总 TEESimulator 的 overrides.json
#
# 为什么单独一条：overrides.json 是与 config.json 互斥的第二块可写面 ——
# 设备标识只能在 profile 里改，安全等级/版本/启动键哈希只能改这里，
# 而 harvested.json 里那些 id 类字段写了会被守护进程丢弃并记日志
# （Harvester.kt:117-125,403-405）。上一版界面完全没有这一块。
#
# 可编辑性是**数据决定**的，不是写死的：verifiedBootKey / verifiedBootHash
# 只有当守护进程自己那份是合成兜底值时才可改（Harvester.kt:139-143,183-189）。
# 所以这里把 harvested.json 的 overrides.<字段>.{editable,source} 一起报出来，
# 让界面照实显示，而不是自己猜一个"能不能编辑"。
#
# 用法：awk -f backends/teesim_overrides.awk [-v ov=overrides.json] [-v ha=harvested.json]
# 输出：每行「字段<TAB>当前值<TAB>可编辑(1|0)<TAB>来源」；两个文件都读不到时退 1。
#=============================================================================
BEGIN { TAB = sprintf("%c", 9); n = 0 }

# 读一个扁平 JSON 对象里某键的原始值（数字或带引号字符串），没有则返回 ""
function flat(obj, key,   p, i, c, s) {
    p = findstr(obj, 1, "\"" key "\"")
    if (p == 0) return ""
    p = findstr(obj, p + length(key) + 2, ":")
    if (p == 0) return ""
    i = p + 1
    while (i <= length(obj) && substr(obj, i, 1) ~ /[ \t\r\n]/) i++
    if (substr(obj, i, 1) == "\"") {
        s = ""; i++
        while (i <= length(obj) && substr(obj, i, 1) != "\"") { s = s substr(obj, i, 1); i++ }
        return s
    }
    s = ""
    # true / false / null 也是合法值。只认引号和数字的话，"editable": false
    # 会被读成空串，于是一个"不可编辑"的字段在界面上报成可编辑 ——
    # 这恰好是最要紧的那一格报错。
    if (substr(obj, i, 5) == "false") return "false"
    if (substr(obj, i, 4) == "true") return "true"
    if (substr(obj, i, 4) == "null") return "null"
    while (i <= length(obj) && substr(obj, i, 1) ~ /[0-9.eE+-]/) { s = s substr(obj, i, 1); i++ }
    return s
}

function findstr(s, from, needle,   i, l) {
    l = length(needle)
    for (i = from; i + l - 1 <= length(s); i++)
        if (substr(s, i, l) == needle) return i
    return 0
}

# 取 harvested.json 里 "overrides" 对象内某字段的子对象文本
function sub_obj(root, field,   p, o, e) {
    p = findstr(root, 1, "\"" field "\"")
    if (p == 0) return ""
    o = findstr(root, p + length(field) + 2, "{")
    if (o == 0) return ""
    e = matchclose(root, o)
    if (e == 0) return ""
    return substr(root, o, e - o + 1)
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

function slurp(f,   line, s) {
    s = ""
    while ((getline line < f) > 0) s = s line "\n"
    close(f)
    return s
}

BEGIN {
    FIELDS = "attestationSecurityLevel keymasterSecurityLevel attestationVersion keymasterVersion verifiedBootKey verifiedBootHash"
    ovtxt = (ov != "" ? slurp(ov) : "")
    hatxt = (ha != "" ? slurp(ha) : "")
    if (ovtxt == "" && hatxt == "") { exit 1 }
    # harvested.json 的 overrides 段（可编辑性与来源都在这里）
    hp = findstr(hatxt, 1, "\"overrides\"")
    hobj = ""
    if (hp > 0) {
        ho = findstr(hatxt, hp + 11, "{")
        if (ho > 0) { he = matchclose(hatxt, ho); if (he > 0) hobj = substr(hatxt, ho, he - ho + 1) }
    }
    split(FIELDS, fl, " ")
    for (i = 1; i <= 6; i++) {
        f = fl[i]
        v = flat(ovtxt, f)
        sobj = sub_obj(hobj, f)
        ed = "1"; src = "unset"
        if (sobj != "") {
            s2 = flat(sobj, "source"); if (s2 != "") src = s2
            e2 = flat(sobj, "editable")
            if (e2 == "false") ed = "0"
            else if (e2 == "true") ed = "1"
            else if (src == "required") ed = "1"
        }
        # 根信任两项上游明确不可改（deviceLocked / verifiedBootState 不在本表内，
        # 这里兜一句：万一 harvested 标了 editable 也不给编辑）
        if (f == "verifiedBootKey" || f == "verifiedBootHash") {
            if (src != "synthesized" && src != "supplement") ed = "0"
        }
        printf "%s%s%s%s%s%s%s\n", f, TAB, (v == "" ? "-" : v), TAB, ed, TAB, src
    }
    exit 0
}
