#=============================================================================
# backends/entry_base.awk - 目标条目 -> 基础包名
#
# 给 ever / excluded 这类只按应用身份判断的地方用：一个包的 ?/! 模式或
# @用户 变体不应让它看起来像另一个应用。uid: 条目没有包名，直接丢弃。
#
# 用法：awk -v backend=<tricky|teesim|omk> -f backends/entry_base.awk
# 输入：每行一个目标条目（可含后缀）
# 输出：每行一个基础包名（去重交给调用方 sort -u）
#=============================================================================

{
    tok = $0
    sub(/\r$/, "", tok)
    if (tok == "") next

    b = tok
    if (backend == "tricky") {
        if (b ~ /[?!]$/) b = substr(b, 1, length(b) - 1)
    } else if (backend == "teesim") {
        if (b ~ /^uid:/) b = ""
        else sub(/@[0-9]+$/, "", b)
    }
    if (b != "") print b
}
