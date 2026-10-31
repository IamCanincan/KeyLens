#=============================================================================
# backends/keybox_check.awk - 按后端验 keybox 的**结构**
#
# 为什么不能三家共用一份判据（逐家核过各家解析器的实际行为）：
#   · Tricky   根元素必须叫 AndroidAttestation（深度 1 就判死），
#              命名空间关掉；随后要 <Keybox> / <Key algorithm=> /
#              <PrivateKey> / <CertificateChain> / <Certificate>。
#   · TEESim   解析器不看根元素名，只找
#              <Key algorithm="rsa"|"ecdsa">（小写），要 <PrivateKey>
#              和 **≥2** 个 <Certificate>；读不到就跳过该 profile，
#              这些包退回真硬件。它自家 WebUI 只轻验
#              "有 <AndroidAttestation 或 <Keybox"。
#   · OMK      不是 XML 而是四条正则：
#                                   <Key\s+algorithm="X">\s*(.*?)\s*</Key> 成对、
#                                   X∈{ec,ecdsa,rsa} 且**必须有 EC**、每个 Key 块里要有
#                                   <NumberOfCertificates>N</NumberOfCertificates>，
#                                   且**本块**的 <Certificate> 个数必须等于 N；
#                                   任一 bail 之后守护进程会把自带模板**覆盖回这个文件**。
#
# 判据一律**不严于**上游：OMK 自带模板写着 NumberOfKeyboxes=2 却只有一个 <Keybox>，
# 所以这里完全不检查 NumberOfKeyboxes —— 检查了就会把上游自己装的那份判成不合格。
# 也**不试图判证书链与私钥是否匹配**：那是 X.509 解析，界面层判不了，OMK 自己会判。
#
# 用法：awk -v backend=tricky|teesim|omk -f module/backends/keybox_check.awk <文件>
# 输出：ok                    通过（退 0）
#       err<TAB>一句话原因     拒绝（退 1）
#=============================================================================

{ buf = buf $0 "\n" }

# 说明：数正则出现的**次数**，不是行数 —— keybox 经常被整份压成一行，
#       grep -c 那种按行数法的计数器在这里会少数。
function countOf(s, re,   n, rest) {
    n = 0; rest = s
    while (match(rest, re)) { n++; rest = substr(rest, RSTART + RLENGTH) }
    return n
}

function fail(msg) { print "err\t" msg; exit 1 }

# 说明：开标签计数，允许带任意属性。<PrivateKey format="pem"> 必须算一次，
#       而 <CertificateChain> 不许被当成 <Certificate> —— 所以尾部那个
#       ([ \t][^>]*)?[>/] 是必要的：它要求标签名之后要么是空格+属性、要么直接收尾。
function tagOpen(s, name,   re) {
    re = "<" name "([ \t][^>]*)?[>/]"
    return countOf(s, re)
}

END {
    if (buf ~ /^[ \t\r\n]*$/) fail("keybox 是空文件")

    if (backend == "") backend = "tricky"
    if (backend != "tricky" && backend != "teesim" && backend != "omk") fail("不认识的后端：" backend)

    SP = "[ \t\r\n]"
    ncert  = tagOpen(buf, "Certificate")
    npriv  = tagOpen(buf, "PrivateKey")
    nchain = tagOpen(buf, "CertificateChain")
    nkeybox = tagOpen(buf, "Keybox")
    # 宽松的 Key 头（algorithm 不必是第一个属性）与 OMK 严格的 Key 头（algorithm 后必须紧跟 >）
    nkey   = countOf(buf, "<Key[ \t][^>]*algorithm" SP "*=" SP "*\"[^\"]*\"")
    nkeyOmk = countOf(buf, "<Key" SP "+algorithm" SP "*=" SP "*\"[^\"]*\">")
    nPEM   = countOf(buf, "-----BEGIN [A-Z ]*-----")
    hasRootOpen  = (match(buf, "<AndroidAttestation([ \t][^>]*)?[>/]") > 0)
    hasRootClose = (match(buf, "</AndroidAttestation" SP "*>") > 0)

    if (backend == "tricky") {
        if (!hasRootOpen || !hasRootClose) fail("Tricky 要求根元素是成对的 <AndroidAttestation>，这份没有")
        if (nkey == 0) fail("没有 <Key algorithm=\"…\"> 块，Tricky 解析不到任何密钥")
        if (nkeybox == 0) fail("没有 <Keybox> 元素，Tricky 的 depth-2 判据过不了")
        if (npriv == 0) fail("没有 <PrivateKey>")
        if (nchain == 0) fail("没有 <CertificateChain>，Tricky 只认带链的写法")
        if (ncert == 0) fail("链里没有 <Certificate>")
    } else if (backend == "teesim") {
        if (!hasRootOpen && nkeybox == 0) fail("既没有 <AndroidAttestation> 也没有 <Keybox>，不像 keybox（TEESim 自家 WebUI 的判据）")
        if (nkey == 0) fail("没有 <Key algorithm=\"…\"> 块")
        if (npriv == 0) fail("没有 <PrivateKey>")
        if (ncert < 2) fail("TEESim 运行时至少要 2 张 <Certificate>，这份只有 " ncert " 张")
        if (buf !~ /algorithm[ \t]*=[ \t]*"(rsa|ecdsa)"/) fail("TEESim 只认小写的 algorithm=\"rsa\"/\"ecdsa\"，这份里没有")
    } else {
        if (nkeyOmk == 0) fail("OMK 用正则 <Key\\s+algorithm=\"X\">…</Key> 整块取密钥，要求 algorithm 属性后面紧跟 >；这份一个都没匹配上")
        if (buf !~ /algorithm[ \t]*=[ \t]*"(ec|ecdsa)"/) fail("OMK 必须有 EC 密钥（algorithm=\"ec\" 或 \"ecdsa\"，keybox.rs:103），只有 RSA 它直接放弃")
        if (npriv == 0) fail("没有 <PrivateKey>")
        if (nPEM == 0) fail("OMK 走 PEM 解码私钥与证书，这份里没有 -----BEGIN …----- 块")
        seen = 0
        i = 1
        while (i <= length(buf)) {
            head = substr(buf, i)
            if (!match(head, "<Key" SP "+algorithm" SP "*=" SP "*\"[^\"]*\">")) break
            bodyStart = i + RSTART + RLENGTH - 1
            tail = substr(buf, bodyStart)
            if (!match(tail, "</Key" SP "*>")) fail("有一个 <Key> 块没有 </Key> 收尾，OMK 的非贪婪整块正则匹配不到它")
            # 先算下一次的起点：下面 match(body…) 会把 RSTART/RLENGTH 覆盖掉
            i = bodyStart + RSTART + RLENGTH - 1
            seen++
            body = substr(tail, 1, RSTART - 1)
            if (!match(body, "<NumberOfCertificates" SP "*>")) fail("第 " seen " 个 <Key> 块里没有 <NumberOfCertificates>")
            after = substr(body, RSTART + RLENGTH)
            if (!match(after, SP "*[0-9]+")) fail("第 " seen " 个 <Key> 块的 <NumberOfCertificates> 后面没有数字")
            expected = substr(after, RSTART, RLENGTH) + 0
            got = tagOpen(body, "Certificate")
            if (got != expected) fail("第 " seen " 个 <Key> 块声明 " expected " 张证书，实际数到 " got " 张 —— OMK 数完不等就 bail，之后守护进程会把自带模板覆盖回这个文件")
        }
    }

    print "ok"
}
