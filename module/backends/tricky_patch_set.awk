#=============================================================================
# backends/tricky_patch_set.awk - 修改 security_patch.txt 的某一段（全局或按包）
#
# scope 省略或 =global：动第一个 [包名] 之前的全局段。
# scope=<包名>：只动那个 [包名] 块；块不存在时连段头一起新建在文件末尾。
# 已有键原位替换值（保留行内注释），没有的插到该段末尾；其它段、注释与其余行
# 逐字节保留。文件不存在时按请求新建。
# 单个裸值（"20241101" 这种 all 写法）在需要混写键值时会先转成 all = 值。
#
# 用法：awk -v pairsfile=<key<TAB>value> -v statusfile=<文件> \
#           [-v scope=global|<包名>] -f backends/tricky_patch_set.awk security_patch.txt
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
    # 段头一览。scope=global 改全局段；scope=<包名> 改（或新建）那个 [包名] 块。
    # 上游允许按包覆盖全局 —— 以前这里只认全局段，改了全局并不等于那个包生效。
    nsec = 0
    for (i = 1; i <= nl; i++) {
        if (lines[i] ~ /^[ \t]*\[[A-Za-z0-9_.-]+\][ \t]*$/) {
            nm = lines[i]; sub(/^[ \t]*\[/, "", nm); sub(/\][ \t]*$/, "", nm)
            nsec++; secl[nsec] = i; secn[nsec] = nm
        }
    }
    want = (scope == "" ? "global" : scope)

    # 删除模式：-v drop=<包名> 时只删那个 [包名] 块（段头 + 块体 + 块前的一个空行）。
    # 全局段不许删 —— 它就是补丁表的主体，删掉等于清空整张表。
    #   状态：ok / missing（没有这一段）/ refused（要删全局段）
    if (drop != "") {
        if (drop == "global") { print "refused" > statusfile; for (i = 1; i <= nl; i++) print lines[i]; exit }
        idx = 0
        for (s = 1; s <= nsec; s++) if (secn[s] == drop) { idx = s; break }
        if (!idx) { print "missing" > statusfile; for (i = 1; i <= nl; i++) print lines[i]; exit }
        lo = secl[idx]; hi = (idx < nsec ? secl[idx + 1] : nl + 1)
        # 块尾：紧邻下一个段头的空行/注释属于**下一段**（"# b 段" 这种说明），留着。
        while (hi - 1 >= lo && (lines[hi - 1] ~ /^[ \t]*$/ || lines[hi - 1] ~ /^[ \t]*#/)) hi--
        # 块头：紧贴段头的说明注释算这个块的；再往前那个空行也一起收掉。
        lo2 = lo
        while (lo2 - 1 >= 1 && lines[lo2 - 1] ~ /^[ \t]*#/) lo2--
        if (lo2 - 1 >= 1 && lines[lo2 - 1] ~ /^[ \t]*$/) lo2--
        for (i = 1; i <= nl; i++) {
            if (i >= lo2 && i < hi) continue
            print lines[i]
        }
        print "ok" > statusfile
        exit
    }

    newblk = ""
    if (want == "global") { lo = 1; hi = (nsec ? secl[1] : nl + 1) }
    else {
        blk = 0
        for (s = 1; s <= nsec; s++) if (secn[s] == want) { blk = s; break }
        if (blk) { lo = secl[blk] + 1; hi = (blk < nsec ? secl[blk + 1] : nl + 1) }
        else { lo = nl + 1; hi = nl + 1; newblk = want }   # 还没有这个块：末尾新建
    }

    # 读目标段：找出 system/vendor/boot/all 的行号与裸值行号
    bare = 0
    for (i = lo; i < hi; i++) {
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

    # 新键按请求顺序插到目标段末尾；新建块时连段头一起写
    ins = ""
    for (p = 1; p <= nmiss; p++) {
        k = pk[miss[p]]
        ins = ins k " = " pv[miss[p]] "\n"
        changed = 1
    }
    if (newblk != "" && ins != "") ins = "[" newblk "]\n" ins
    if (ins == "" && !changed && nl > 0) { print "same" > statusfile; for (i = 1; i <= nl; i++) print lines[i]; exit }

    at = hi         # 插在目标段末尾（新建块时即文件末尾）
    for (i = 1; i <= nl; i++) {
        if (i == at && ins != "") printf "%s", ins
        print lines[i]
    }
    if (at == nl + 1 && ins != "") printf "%s", ins
    print "ok" > statusfile
}
