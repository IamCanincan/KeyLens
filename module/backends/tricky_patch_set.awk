#=============================================================================
# backends/tricky_patch_set.awk - 修改 security_patch.txt 的全局设置
#
# 只动第一个 [包名] 之前的全局段：已有键原位替换值（保留行内注释），没有的
# 插到全局段末尾；[包名] 段、注释与其它行逐字节保留。文件不存在时按请求新建。
# 单个裸值（"20241101" 这种 all 写法）在需要混写键值时会先转成 all = 值。
#
# 用法：awk -v pairsfile=<key<TAB>value> -v statusfile=<文件> \
#           -f backends/tricky_patch_set.awk security_patch.txt
# 状态：ok / same
#=============================================================================

function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }

# 拆出主体与注释：# 之后原样保留
function split_line(s,   h) {
    h = index(s, "#")
    if (h > 0) { BODY = substr(s, 1, h - 1); TAIL = substr(s, h) }
    else { BODY = s; TAIL = "" }
}

BEGIN {
    np = 0
    while ((getline ln < pairsfile) > 0) {
        p = index(ln, "\t")
        if (p <= 1) continue
        k = substr(ln, 1, p - 1); v = substr(ln, p + 1)
        if (k == "patch_system") k = "system"
        else if (k == "patch_vendor") k = "vendor"
        else if (k == "patch_boot") k = "boot"
        else if (k == "patch_all") k = "all"
        else continue
        np++; pk[np] = k; pv[np] = v
    }
    close(pairsfile)
}

{ line = $0; sub(/$/, "", line); lines[++nl] = line }

END {
    firstsec = nl + 1
    for (i = 1; i <= nl; i++) {
        if (lines[i] ~ /^[ \t]*\[[A-Za-z0-9_.-]+\][ \t]*$/) { firstsec = i; break }
    }

    # 读全局段：找出 system/vendor/boot/all 的行号与裸值行号
    bare = 0
    for (i = 1; i < firstsec; i++) {
        split_line(lines[i])
        b = trim(BODY)
        if (b == "" || b ~ /^\[/) continue
        e = index(b, "=")
        if (e > 0) {
            k = trim(substr(b, 1, e - 1))
            if (k == "system" || k == "vendor" || k == "boot" || k == "all") keyline[k] = i
        } else bare = i
    }

    # 有裸值又要混写键：先把它转成 all = 旧值，保住其它分量
    if (bare && np > 0) {
        split_line(lines[bare])
        old = trim(BODY)
        lines[bare] = "all = " old (TAIL == "" ? "" : " " TAIL)
        keyline["all"] = bare
    }

    # 逐个键：已有则原位换值，没有则记到待插入
    nmiss = 0
    for (p = 1; p <= np; p++) {
        k = pk[p]; v = pv[p]
        if (k in keyline) {
            i = keyline[k]
            split_line(lines[i])
            ind = BODY; sub(/[^ \t].*$/, "", ind)
            if (trim(BODY) != k " = " v) {
                lines[i] = ind k " = " v (TAIL == "" ? "" : " " TAIL)
                changed = 1
            }
        } else {
            miss[++nmiss] = p
        }
    }

    # 新键按 system / vendor / boot / all 的固定顺序插到全局段末尾
    ins = ""
    for (p = 1; p <= nmiss; p++) {
        k = pk[miss[p]]
        ins = ins k " = " pv[miss[p]] "\n"
        changed = 1
    }
    if (ins == "" && !changed && nl > 0) { print "same" > statusfile; for (i = 1; i <= nl; i++) print lines[i]; exit }

    at = firstsec   # 插在第一个段之前（文件没有段时插在末尾）
    for (i = 1; i <= nl; i++) {
        if (i == at && ins != "") printf "%s", ins
        print lines[i]
    }
    if (at == nl + 1 && ins != "") printf "%s", ins
    print "ok" > statusfile
}
