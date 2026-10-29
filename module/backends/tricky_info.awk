#=============================================================================
# backends/tricky_info.awk - 只读提取 security_patch.txt 的摘要
#
# Tricky Store OSS：全局设置写在第一个 [包名] 之前，之后每个 [包名] 段覆盖该
# 应用。这里只读全局值（system / vendor / boot / all）与包级段数量，不写文件。
#
# 用法：awk -f backends/tricky_info.awk security_patch.txt
# 输出：patch_lines=N / patch_packages=N / patch_system=… / patch_vendor=…
#       patch_boot=… / patch_all=…
#=============================================================================

{
    line = $0
    sub(/\r$/, "", line)
    h = index(line, "#")
    if (h > 0) line = substr(line, 1, h - 1)
    gsub(/^[ \t]+|[ \t]+$/, "", line)
    if (line == "") next
    n++

    if (line ~ /^\[[A-Za-z0-9_.-]+\]$/) {
        cur = substr(line, 2, length(line) - 2)
        npkg++
        next
    }

    if (cur == "") {
        e = index(line, "=")
        if (e == 0) {
            if (allval == "") allval = line
        } else {
            k = tolower(substr(line, 1, e - 1))
            v = substr(line, e + 1)
            gsub(/^[ \t]+|[ \t]+$/, "", k)
            gsub(/^[ \t]+|[ \t]+$/, "", v)
            if (k == "system") sysval = v
            else if (k == "vendor") venval = v
            else if (k == "boot") bootval = v
            else if (k == "all") allval = v
        }
    }
}

END {
    print "patch_lines=" n
    print "patch_packages=" npkg
    if (sysval != "")  print "patch_system=" sysval
    if (venval != "")  print "patch_vendor=" venval
    if (bootval != "") print "patch_boot=" bootval
    if (allval != "")  print "patch_all=" allval
}
