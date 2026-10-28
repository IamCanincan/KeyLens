#=============================================================================
# backends/omk.awk - OhMyKeymint injector.toml 定点替换
#
# 职责：只替换 injector.toml 里 `scoop = [ ... ]` 的数组内容；
#       文件其余部分（注释、version、[main]/[filter]/[intercept]、[scoop.x] 段）
#       逐字节保留。无法可靠定位数组时原样输出并标记 fail。
#
# 用法：awk -v listfile=<每行一个包名> -v statusfile=<状态文件> \
#           -f backends/omk.awk injector.toml
# 状态文件：成功写 "ok"；定位失败写 "fail"（此时原样输出，不做修改）
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

# 说明：定位失败时的统一出口——原样输出并标记 fail，确保配置不被修改
function bail() {
    print "fail" > statusfile
    printf "%s", buf
    exit
}

BEGIN {
    n = 0
    while ((getline ln < listfile) > 0) {
        sub(/\r$/, "", ln)
        if (ln != "") { n++; items[n] = ln }
    }
    close(listfile)
}

{ buf = buf $0 "\n" }

END {
    # 必须定位到行首的裸键 scoop = [（[scoop.x] 段没有等号，不会误中）
    if (!match(buf, /(^|\n)[ \t]*scoop[ \t]*=[ \t]*\[/)) bail()
    ob = RSTART + RLENGTH - 1
    cb = matchclose(buf, ob)
    if (cb == 0) bail()

    # 取 scoop 那一行的缩进；数组元素在此基础上再缩进两格
    ls = RSTART
    if (substr(buf, ls, 1) == "\n") ls++
    while (ls > 1 && substr(buf, ls - 1, 1) != "\n") ls--
    ind = ""
    i = ls
    while (i < ob) {
        c = substr(buf, i, 1)
        if (c != " " && c != "\t") break
        ind = ind c
        i++
    }
    itemind = ind "  "

    body = "\n"
    for (i = 1; i <= n; i++) {
        s = items[i]
        gsub(/\\/, "\\\\", s)
        gsub(/"/, "\\\"", s)
        body = body itemind "\"" s "\"," "\n"
    }
    body = body ind

    printf "%s%s%s", substr(buf, 1, ob), body, substr(buf, cb)
    print "ok" > statusfile
}
