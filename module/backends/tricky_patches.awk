#=============================================================================
# backends/tricky_patches.awk - 只读解析 Tricky Store 的 security_patch.txt
#
# 上游格式（Config.kt）：全局块在最前面，之后可以有任意个 `[包名]` 块，块内的
# `system=` / `vendor=` / `boot=` 覆盖全局值；`all=` 同时写三档。以前界面只读写
# 全局那一组，按包块从来没被列出来过 —— 用户改了全局就以为改完了。
#
# 只读，不改文件。定位不到文件内容时不输出、退码 1。
#
# 用法：awk -f backends/tricky_patches.awk security_patch.txt
# 输出：每行「范围<TAB>system<TAB>vendor<TAB>boot」，范围是 global 或包名；
#       没有值的格子记成 "-"（继承上一块，不是"清空"）。
#=============================================================================
BEGIN { TAB = sprintf("%c", 9); n = 0; cur = "global" }

function flush(   i) {
    if (cur == "" ) return
    if (v_sys[cur] == "" && v_vnd[cur] == "" && v_btm[cur] == "") return
    order[++n] = cur
}

function put(key, val) {
    if (key == "system") v_sys[cur] = val
    else if (key == "vendor") v_vnd[cur] = val
    else if (key == "boot") v_btm[cur] = val
    else if (key == "all") { v_sys[cur] = val; v_vnd[cur] = val; v_btm[cur] = val }
}

{
    line = $0
    sub(/\r$/, "", line)
    # 注释：# 之后截掉（上游是整行截断，不是只认行首）
    h = index(line, "#")
    if (h > 0) line = substr(line, 1, h - 1)
    gsub(/^[ \t]+|[ \t]+$/, "", line)
    if (line == "") next

    if (line ~ /^\[[^]]+\]$/) {
        flush()
        cur = substr(line, 2, length(line) - 2)
        next
    }
    e = index(line, "=")
    if (e == 0) next                      # 裸日期行由调用方按 all 处理，这里不猜
    k = substr(line, 1, e - 1); v = substr(line, e + 1)
    gsub(/^[ \t]+|[ \t]+$/, "", k); gsub(/^[ \t]+|[ \t]+$/, "", v)
    put(k, v)
}

END {
    flush()
    if (n == 0) exit 1
    for (i = 1; i <= n; i++) {
        s = order[i]
        printf "%s%s%s%s%s%s%s\n", s, TAB,
            (v_sys[s] == "" ? "-" : v_sys[s]), TAB,
            (v_vnd[s] == "" ? "-" : v_vnd[s]), TAB,
            (v_btm[s] == "" ? "-" : v_btm[s])
    }
    exit 0
}
