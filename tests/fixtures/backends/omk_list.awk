#=============================================================================
# backends/omk_list.awk - 只读提取 OhMyKeymint injector.toml 的 scoop 数组
#
# 职责：从 injector.toml 中取出 `scoop = [ "pkg", ... ]` 里的包名，供 WebUI
#       展示与快照差分使用。只认裸键 `scoop = [`（OhMyKeymint 的写法），
#       不会把 `[scoop.<pkg>]` 段当成数组。
#
# 用法：awk -f backends/omk_list.awk injector.toml
# 输出：每行一个包名；无法定位 scoop 数组时无输出且退出码为 1
#=============================================================================

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

{ buf = buf $0 "\n" }

END {
    # 键必须在行首（允许缩进），避免匹配到注释或字符串里的 "scoop = ["
    if (!match(buf, /(^|\n)[ \t]*scoop[ \t]*=[ \t]*\[/)) exit 1
    ob = RSTART + RLENGTH - 1
    cb = matchclose(buf, ob)
    if (cb == 0) exit 1

    # 数组区间内的字符串项即包名（跳过键名、逗号与注释）
    seg = substr(buf, ob + 1, cb - ob - 1)
    while (match(seg, /"[^"]*"/)) {
        print substr(seg, RSTART + 1, RLENGTH - 2)
        seg = substr(seg, RSTART + RLENGTH)
    }
}
