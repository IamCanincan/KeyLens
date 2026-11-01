#=============================================================================
# backends/json_flat_set.awk - 定点修改一个**扁平** JSON 对象的顶层键
#
# 给 TEESimulator 的 overrides.json 用：那是扁平一层（安全等级、版本号、启动键哈希），
# 与 config.json 那种「profiles 套 profile 套 patchLevel」不是同一个形状，所以不复用
# teesim_set.awk，也不把两种定位逻辑搅在一起。
#
# 原则与本模块其它写回一致：**只改请求里的键**，其余字节原样保留 —— 包括未知键
# （上游以后加字段时这里不能把它吃掉）。键不存在就插到顶层对象末尾，不重建整份文件。
#
# 用法：awk -v pairsfile=<文件> -v statusfile=<文件> \
#           -f backends/json_flat_set.awk overrides.json
#   pairsfile 每行「键<TAB>值」：
#     · 值一律写成**带引号的 JSON 字符串**。这不是偷懒 —— 上游自己的写回
#       （TEESimulator module/webroot/js/data/overrides-io.js:34-39 + system-controller.js:71-82）
#       就是把每个值 String() 之后当字符串落盘，守护进程按 Map<String,String> 读
#       （OverrideStore.kt:24-42，数字/布尔会被 optString  coerce）。
#       我们写裸数字的话，界面读回来的是另一种形状，白多一类不一致。
#     · 值为**空串 = 删掉这个键**（上游同义：system-controller.js:75 空值即删除，
#       整个 map 空了就把文件删掉）。守护进程侧"空值 = 复位成默认"（Harvester.kt:409）。
#   值一律先由调用方校验，这里只负责转义与落位。
# 状态（写进 statusfile）：ok=有改动 / same=无需改 / missing=没有顶层对象
#
# 踩过的坑记在这儿：awk 的 match() 会把全局 RSTART/RLENGTH 冲掉，所以"跳过一段
# 字符串"和"取值区间"不能共用一份游标；键名与值都可能出现 { } [ ]，定位必须
# 一边扫一边记"现在在不在字符串里"。
#=============================================================================

BEGIN { TAB = sprintf("%c", 9); KS = 0; KE = 0 }

{ buf = buf $0 "\n" }

function findstr(s, from, needle,   i, l) {
    l = length(needle)
    for (i = from; i + l - 1 <= length(s); i++)
        if (substr(s, i, l) == needle) return i
    return 0
}

# 说明：从 openpos 的 { 或 [ 走到与它配平的那个 } 或 ]，字符串里的括号不算
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

# 说明：跳过 from 处那个开引号，返回**闭引号之后一位**的位置
function afterstring(s, from, end,   q, c, esc) {
    q = from + 1; esc = 0
    while (q <= end) {
        c = substr(s, q, 1)
        if (esc) esc = 0
        else if (c == "\\") esc = 1
        else if (c == "\"") return q + 1
        q++
    }
    return end + 1
}

function jesc(s,   out, i, c) {
    out = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\\") out = out "\\\\"
        else if (c == "\"") out = out "\\\""
        else if (c == "\t") out = out "\\t"
        else if (c == "\r") out = out "\\r"
        else if (c == "\n") out = out "\\n"
        else out = out c
    }
    return out
}

function render(v) {
    return "\"" jesc(v) "\""
}

# 说明：在顶层对象 [objStart,objEnd] 里找 key 的值区间，命中置全局 KS/KE 并返回 1。
#       KBS 是**键名开引号**的位置 —— 替换只需要 KS/KE，删除必须连键名一起去掉，
#       只吃值会留下 `"a": ,` 这种没人能读的东西（第一版就是这么坏的）。
#       只在深度 1 认键名；深度更深的同名字段（例如以后嵌套出去的东西）不算命中。
function spanof(s, objStart, objEnd, key,   i, c, depth, p, name, hit) {
    depth = 0; KS = 0; KE = 0; KBS = 0
    for (i = objStart; i <= objEnd; i++) {
        c = substr(s, i, 1)
        if (c == "\"") {
            if (depth != 1) { i = afterstring(s, i, objEnd) - 1; continue }
            name = substr(s, i + 1, afterstring(s, i, objEnd) - i - 2)
            p = afterstring(s, i, objEnd)
            while (p <= objEnd && substr(s, p, 1) ~ /[ \t\r\n]/) p++
            if (substr(s, p, 1) != ":") { i = afterstring(s, i, objEnd) - 1; continue }
            hit = (name == key)
            p++
            while (p <= objEnd && substr(s, p, 1) ~ /[ \t\r\n]/) p++
            if (substr(s, p, 1) == "\"") {
                c = afterstring(s, p, objEnd) - 1          # 闭引号位置
            } else {
                c = p
                while (c <= objEnd && substr(s, c, 1) !~ /[,}\n]/) c++
                while (c > p && substr(s, c - 1, 1) ~ /[ \t\r]/) c--   # 去掉尾部空白
            }
            if (hit) { KS = p; KE = c; KBS = i; return 1 }
            i = c
            continue
        }
        if (c == "{" || c == "[") depth++
        else if (c == "}" || c == "]") depth--
    }
    return 0
}

END {
    ob = findstr(buf, 1, "{")
    if (ob == 0) { print "missing" > statusfile; exit }
    oc = matchclose(buf, ob)
    if (oc == 0) { print "missing" > statusfile; exit }

    np = 0
    while ((getline line < pairsfile) > 0) {
        nf = split(line, f, TAB)
        if (nf < 1 || f[1] == "") continue
        np++
        pk[np] = f[1]; pv[np] = (nf >= 2 ? f[2] : "")
    }
    close(pairsfile)

    changed = 0
    # ① 已存在的键：空值删掉整条，否则原位替换。每处理一条就重新定位
    #    （长度变了，缓存的偏移会错位），并且闭括号位置也要跟着重算。
    for (j = 1; j <= np; j++) {
        if (!spanof(buf, ob, oc, pk[j])) continue
        if (pv[j] != "") {
            newv = render(pv[j])
            if (substr(buf, KS, KE - KS + 1) == newv) continue
            buf = substr(buf, 1, KS - 1) newv substr(buf, KE + 1)
        } else {
            # 删整条成员：连键名、逗号与"这一行剩下的空白"一起去掉，
            # 否则留下 `{,}`、`{"a":1,,}` 或 `"a": ,` —— 守护进程读不出来。
            # 先吃后面的逗号；它是最后一条时改吃前面那个。
            rs = KBS; re = KE
            p = re + 1
            while (p <= oc && substr(buf, p, 1) ~ /[ \t\r]/) p++
            if (substr(buf, p, 1) == ",") re = p
            else {
                q = rs - 1
                while (q > ob && substr(buf, q, 1) ~ /[ \t\r\n]/) q--
                if (substr(buf, q, 1) == ",") rs = q
            }
            # 这一行被清空了就连行带换行一起删；否则只删内容、保留后面的换行
            a = rs - 1
            while (a > ob && substr(buf, a, 1) ~ /[ \t\r]/) a--
            b = re + 1
            while (b <= length(buf) && substr(buf, b, 1) ~ /[ \t\r]/) b++
            if (substr(buf, a, 1) == "\n" && substr(buf, b, 1) == "\n") { rs = a + 1; re = b }
            else if (substr(buf, a, 1) == "\n") rs = a + 1
            buf = substr(buf, 1, rs - 1) substr(buf, re + 1)
        }
        oc = matchclose(buf, ob)
        changed = 1
    }

    # ② 不存在的键：整批插到顶层闭括号之前（空值的键本来就不在对象里，跳过）
    nm = 0
    for (j = 1; j <= np; j++) {
        if (pv[j] == "") continue
        if (spanof(buf, ob, oc, pk[j])) continue
        nm++
        mk[nm] = "\"" pk[j] "\": " render(pv[j])
    }
    if (nm > 0) {
        entries = ""
        for (j = 1; j <= nm; j++) entries = entries (j > 1 ? ",\n" : "") "    " mk[j]
        head = substr(buf, 1, oc - 1)
        tail = substr(buf, oc)
        ws = ""
        if (match(head, /[ \t\r\n]+$/)) {
            ws = substr(head, RSTART)
            head = substr(head, 1, RSTART - 1)
        }
        # 原对象是空的 {} 时不加逗号，否则要在上一条后面补一个
        if (head ~ /\{[ \t]*$/) buf = head "\n" entries "\n" tail
        else if (head ~ /,$/) buf = head entries ws tail
        else buf = head "," "\n" entries "\n" tail
        oc = matchclose(buf, ob)
        changed = 1
    }

    print (changed ? "ok" : "same") > statusfile
    printf "%s", buf
}
