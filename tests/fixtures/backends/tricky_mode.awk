#=============================================================================
# backends/tricky_mode.awk - 修改 target.txt 中某个包的模式后缀
#
# Tricky Store OSS 用 pkg / pkg? / pkg! 表示 自动 / 叶证书破解 / 证书生成。
# 本脚本只改匹配包名的那一行的后缀，保留缩进、行内空白与 # 注释；其余行逐字
# 输出。同一个包名出现多次时全部改成同一个模式（它自己按包名存 Map，重复
# 条目本来也只会保留最后一个）。
#
# 用法：awk -v pkg=<包名> -v mode=<auto|leaf|generate> -v statusfile=<文件> \
#           -f backends/tricky_mode.awk target.txt
# 状态文件：ok=有改动；same=匹配但无需改；none=没有这个包
#=============================================================================

BEGIN {
    if (mode == "leaf") suffix = "?"
    else if (mode == "generate") suffix = "!"
    else suffix = ""
    changed = 0
    matched = 0
}

{
    line = $0
    sub(/\r$/, "", line)

    h = index(line, "#")
    body = h ? substr(line, 1, h - 1) : line
    if (body ~ /^[ \t]*$/) { print line; next }

    match(body, /^[ \t]*/)
    indent = substr(body, 1, RLENGTH)
    rest = substr(body, RLENGTH + 1)
    # 上游是 trim 整行后看最后一个字符，所以 "pkg ?" 也算 pkg 的 ? 模式；
    # 这里同样把整段条目（而不是第一个空格前的词）当作 token。
    tok = rest
    sub(/[ \t]+$/, "", tok)
    tail = substr(rest, length(tok) + 1)

    b = tok
    if (b ~ /[?!]$/) {
        b = substr(b, 1, length(b) - 1)
        sub(/[ \t]+$/, "", b)
    }

    if (b == pkg) {
        matched = 1
        newtok = pkg suffix
        if (newtok != tok) changed = 1
        tok = newtok
    }

    out = indent tok tail
    if (h) out = out substr(line, h)
    print out
}

END {
    if (!matched) print "none" > statusfile
    else if (changed) print "ok" > statusfile
    else print "same" > statusfile
}
