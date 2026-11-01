#=============================================================================
# backends/tricky_list.awk - 只读提取 Tricky Store OSS target.txt 的有效条目
#
# Tricky Store OSS 的 target.txt 每一行是一个包名，后面可以带一个模式后缀：
#   pkg      自动
#   pkg?     强制叶证书破解（LEAF_HACK）
#   pkg!     强制证书生成（GENERATE）
# 行内 # 之后是注释，空行与无法通过包名校验的行会被它忽略。
# 同一个包名出现多次时，后出现的模式覆盖前面的（它内部用 Map 保存）。
#
# 本脚本按同样的语义输出「有效条目」：每行一个 token（含后缀），按首次出现
# 的顺序，同一个基础包名只输出最后一次的模式。
#
# 用法：awk -f backends/tricky_list.awk target.txt
# 输出：每行一个 token（pkg / pkg? / pkg!）
#=============================================================================

{
    line = $0
    sub(/\r$/, "", line)

    # 行内注释：Tricky 用 substringBefore('#') 再 trim
    h = index(line, "#")
    if (h > 0) line = substr(line, 1, h - 1)
    gsub(/^[ \t]+/, "", line)
    gsub(/[ \t]+$/, "", line)
    if (line == "") next

    suffix = ""
    c = substr(line, length(line), 1)
    if (c == "?" || c == "!") {
        suffix = c
        line = substr(line, 1, length(line) - 1)
        gsub(/[ \t]+$/, "", line)
    }

    # 与 Tricky Store OSS 的 packageNameRegex 一致
    if (line !~ /^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+$/) next

    if (!(line in seen)) order[++n] = line
    seen[line] = 1
    tok[line] = line suffix
}

END {
    for (i = 1; i <= n; i++) print tok[order[i]]
}
