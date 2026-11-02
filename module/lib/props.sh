#!/system/bin/sh
#=============================================================================
# lib/props.sh - 系统属性伪装
#
# 说明：期望值表由本文件单点维护 —— apply_resetprop（写入）与
#       webui.sh（展示当前值/期望值）共用同一份，避免两处各写一遍后走偏。
#=============================================================================

# ---------- 期望值表 ----------
# 说明：固定属性表，每行「属性名 期望值」（属性名与值均不含空白）。
# 用法：props_expect_pairs
props_expect_pairs() {
    printf '%s\n' \
        "ro.boot.vbmeta.device_state locked" \
        "ro.boot.verifiedbootstate green" \
        "ro.boot.flash.locked 1" \
        "ro.boot.veritymode enforcing" \
        "ro.boot.warranty_bit 0" \
        "ro.warranty_bit 0" \
        "ro.debuggable 0" \
        "ro.force.debuggable 0" \
        "ro.secure 1" \
        "ro.adb.secure 1" \
        "ro.build.type user" \
        "ro.build.tags release-keys" \
        "ro.vendor.boot.warranty_bit 0" \
        "ro.vendor.warranty_bit 0" \
        "vendor.boot.warranty_bit 0"
}

# 说明：特征替换表，每行「属性名 特征值 替换值」——**就地替换**：把值里出现的每一处
#       特征值换成替换值，其余字符原样保留（以前是"整值替换"，那会把
#       `XQ-DQ72-user 15 ... test-keys` 这种描述直接写成 `release-keys` 一句话，
#       比不改更像被动过）。
#
#       这张表覆盖的是"构建身份"这一族：顶层 ro.build.type/tags 是固定表，
#       而每个分区各自还有一套 *.build.type / *.build.tags / *.build.fingerprint，
#       加上 ro.build.flavor 与 ro.build.description 的尾巴。只改顶层会留下
#       "type=user 而 ro.system.build.type=userdebug"、"fingerprint 尾巴 userdebug"
#       这类自相矛盾 —— 任何应用逐键读就能看见（DuckDetector 已把这些行印出来）。
#
#       顺序有讲究：同一个属性可以有多条规则（如 description 既可能带 userdebug
#       也可能带 test-keys），写入时按这里的顺序**链式**改一遍、只落一次盘；
#       见 props_plan。属性名不许同时出现在固定表与这张表里（tests/props-plan.sh 钉）。
#
#       有意没做的三件事，别当成遗漏来"补"：
#         · 不覆盖 eng 构建（needle 只放 userdebug / test-keys）。eng 的 ROM 在十几个
#           属性上同时露相，单把 type 说成 user 只会多出另一处对不上。
#         · 不动 ROM 身份（ro.lineage.*、flavor 里的 lineage、description 的产品名）。
#           那是"藏 ROM"而不是"自洽"：删属性会打断 LineageOS 自己的应用，而检测器的
#           Custom ROM 卡本来就从包名与服务名起火（本机现量 runtime 26 项），抹属性
#           清不掉那张卡。
#         · 不掩 service.adb.root / persist.sys.usb.config。那是主人的调试状态，不是
#           模块的形状；adbd 随时会把它写回去，掩了只是制造一处新的对不上。
# 用法：props_expect_rules
props_expect_rules() {
    printf '%s\n' \
        "ro.bootloader engineering release" \
        "ro.build.flavor userdebug user" \
        "ro.build.description userdebug user" \
        "ro.build.description test-keys release-keys" \
        "ro.bootimage.build.type userdebug user" \
        "ro.odm.build.type userdebug user" \
        "ro.product.build.type userdebug user" \
        "ro.system.build.type userdebug user" \
        "ro.system_dlkm.build.type userdebug user" \
        "ro.system_ext.build.type userdebug user" \
        "ro.vendor.build.type userdebug user" \
        "ro.vendor_dlkm.build.type userdebug user" \
        "ro.bootimage.build.tags test-keys release-keys" \
        "ro.odm.build.tags test-keys release-keys" \
        "ro.product.build.tags test-keys release-keys" \
        "ro.system.build.tags test-keys release-keys" \
        "ro.system_dlkm.build.tags test-keys release-keys" \
        "ro.system_ext.build.tags test-keys release-keys" \
        "ro.vendor.build.tags test-keys release-keys" \
        "ro.vendor_dlkm.build.tags test-keys release-keys" \
        "ro.build.fingerprint userdebug user" \
        "ro.build.fingerprint test-keys release-keys" \
        "ro.bootimage.build.fingerprint userdebug user" \
        "ro.bootimage.build.fingerprint test-keys release-keys" \
        "ro.odm.build.fingerprint userdebug user" \
        "ro.odm.build.fingerprint test-keys release-keys" \
        "ro.product.build.fingerprint userdebug user" \
        "ro.product.build.fingerprint test-keys release-keys" \
        "ro.system.build.fingerprint userdebug user" \
        "ro.system.build.fingerprint test-keys release-keys" \
        "ro.system_dlkm.build.fingerprint userdebug user" \
        "ro.system_dlkm.build.fingerprint test-keys release-keys" \
        "ro.system_ext.build.fingerprint userdebug user" \
        "ro.system_ext.build.fingerprint test-keys release-keys" \
        "ro.vendor.build.fingerprint userdebug user" \
        "ro.vendor.build.fingerprint test-keys release-keys" \
        "ro.vendor_dlkm.build.fingerprint userdebug user" \
        "ro.vendor_dlkm.build.fingerprint test-keys release-keys"
}

# ---------- 伪装开关 ----------
# 说明：开关文件存在即表示用户关闭了属性伪装。文件放在 /data/adb（与日志缓冲同级），
#       覆盖安装模块不会丢失；卸载时由 uninstall.sh 清理。仅 WebUI 写这个文件。
# 用法：props_disabled
# 返回：0=已关闭 1=未关闭
props_disabled() {
    [ -f "$KL_PROPS_OFF" ]
}

# 说明：开关属性伪装（供 webui.sh 调用）；关闭只影响下一次开机的伪装。
# 用法：set_props_masking <on|off>
# 返回：0=成功 1=失败
set_props_masking() {
    case "$1" in
        on)
            rm -f "$KL_PROPS_OFF" 2>/dev/null
            ! props_disabled
            ;;
        off)
            : > "$KL_PROPS_OFF" 2>/dev/null
            chmod 600 "$KL_PROPS_OFF" 2>/dev/null
            props_disabled
            ;;
        *)  return 1 ;;
    esac
}

# ---------- Verified Boot 哈希 ----------
# 说明：这一格有三种模式，状态就存成"$KL_BOOT_HASH 文件的样子"，不另开配置文件：
#   文件不存在          auto     —— **默认**。开机时从当前后端自己的配置里取它正在证明的
#                                    verifiedBootHash（OMK：[trust] vb_hash；
#                                    TEESim：overrides.json 的 verifiedBootHash），
#                                    只有拿到合法 hex 才写进 ro.boot.vbmeta.digest。
#   文件里是 64/128 hex  manual    —— 用户自己填的值，优先于 auto（升级前就填过的机器
#                                    行为完全不变）。
#   文件里是 "off"       off      —— 明确不写 digest。旧版「清除」的语义搬到这里。
#   文件里是别的          invalid  —— 不写，界面上照实说"配置里的值不合法"。
#
#   为什么 auto 只认 hex、且绝不缓存：OMK 的 vb_hash 允许写 "random"（每次 keymint 启动
#   重新生成）。那种情况下镜像过来的值下一开机就过期，而**过期值比空着更糟**——检测器的
#   判据是"证明里的 hash 与 prop 不一致"= Danger，与"prop 为空"同级。所以每次开机、每次
#   应用都重新读一遍后端配置，非 hex（random / null / 缺文件 / 缺字段）一律当"取不到"，
#   退回不写。
#   为什么仍然算"修复项"而不是伪装开关：digest 错的时候其它属性全对也没用，
#   所以开关关着也应用（与旧版一致）。
# 用法：boot_hash_valid <值>
boot_hash_valid() {
    case "${1:-}" in
        ''|*[!0-9a-fA-F]*) return 1 ;;
    esac
    case "${#1}" in
        64|128) return 0 ;;
        *)      return 1 ;;
    esac
}

# 说明：读文件里的手动值（去空白、转小写）；不是合法 hex 就输出空。
#       文件内容是哨兵 "off" 时输出空，由 boot_hash_mode 去区分 off 与 auto。
# 用法：boot_hash_manual
boot_hash_manual() {
    local v

    [ -f "$KL_BOOT_HASH" ] || return 0
    v=$(tr -d '[:space:]' < "$KL_BOOT_HASH" 2>/dev/null | tr 'A-F' 'a-f')
    boot_hash_valid "$v" || return 0
    printf '%s\n' "$v"
}

# 用法：boot_hash_mode → auto | manual | off | invalid
boot_hash_mode() {
    local v

    [ -f "$KL_BOOT_HASH" ] || { printf 'auto\n'; return 0; }
    v=$(tr -d '[:space:]' < "$KL_BOOT_HASH" 2>/dev/null | tr 'A-F' 'a-f')
    if boot_hash_valid "$v"; then printf 'manual\n'
    elif [ "$v" = off ]; then printf 'off\n'
    else printf 'invalid\n'; fi
}

# 说明：auto 档的取值 —— 只问**当前启用的那一家后端**，不去猜没启用的后端留下的旧配置
#       （OMK 卸载后 /data/misc/keystore/omk 可能还在，镜像那种残留值等于把一个不再被
#       证明的 hash 写进 prop）。KL_BACKEND 已探测过就直接用；没探测过时用 active 探针；
#       两样都没有（被单独 source 的台子）就当取不到，不写。
# 用法：boot_hash_source → 输出「来源<TAB>值」；取不到时输出「none<TAB>」
boot_hash_source() {
    local be="" cfg="" v=""

    if [ -n "${KL_BACKEND:-}" ]; then
        be="$KL_BACKEND"
    elif command -v omk_active >/dev/null 2>&1 && command -v teesim_active >/dev/null 2>&1; then
        # 与 detect_backend 同序（teesim → … → omk）；tricky 没有这个字段，不参与
        if teesim_active; then be=teesim
        elif omk_active; then be=omk
        else be=tricky; fi
    fi

    case "$be" in
        omk)
            cfg="${OMK_DIR:-/data/misc/keystore/omk}/config.toml"
            [ -f "$cfg" ] || { printf 'none\t\n'; return 0; }
            # 与 lib/write.sh 取旧值同一条 sed：引号可有可无，值取到行尾或引号为止
            v=$(sed -n 's/^[[:space:]]*vb_hash[[:space:]]*=[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$cfg" 2>/dev/null | head -n 1)
            ;;
        teesim)
            cfg="${TEESIM_DIR:-/data/adb/teesim}/overrides.json"
            [ -f "$cfg" ] || { printf 'none\t\n'; return 0; }
            # null 不带引号，这条模式匹配不上 ⇒ 自然当"取不到"
            v=$(sed -n 's/.*"verifiedBootHash"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$cfg" 2>/dev/null | head -n 1)
            ;;
        *) printf 'none\t\n'; return 0 ;;
    esac

    v=$(printf '%s' "$v" | tr -d '[:space:]' | tr 'A-F' 'a-f')
    boot_hash_valid "$v" || { printf 'none\t\n'; return 0; }
    printf '%s\t%s\n' "$be" "$v"
}

# 说明：这一格**实际要写进 prop 的值**（生效值）。手动优先；auto 才去派生；off/invalid 不写。
#       名字沿用旧版（boot_hash_get），post-fs-data / service / apply_boot_hash 的调用点
#       不用改——但语义从"配置里的值"变成"生效值"，这是本轮的实质改动。
# 用法：boot_hash_get
boot_hash_get() {
    local m v

    m=$(boot_hash_mode)
    case "$m" in
        manual) boot_hash_manual; return 0 ;;
        auto)   ;;
        *) return 0 ;;          # off / invalid：一个字节都不写
    esac
    v=$(boot_hash_source)
    printf '%s\n' "${v#*	}"
}

# 说明：保存配置。参数：64/128 位 hex = 手动；auto / 空 / - = 删文件回到自动（默认）；
#       off = 写哨兵，明确不写 digest。原子写，权限 600。
# 用法：set_boot_hash <值|auto|off>
# 返回：0=成功 1=值非法或写入失败
set_boot_hash() {
    local v="${1:-}" tmp

    v=$(printf '%s' "$v" | tr -d '[:space:]' | tr 'A-F' 'a-f')

    # 空值 / - / auto 都回到"没有文件"= 默认自动档
    if [ -z "$v" ] || [ "$v" = "-" ] || [ "$v" = auto ]; then
        rm -f "$KL_BOOT_HASH" 2>/dev/null
        [ ! -f "$KL_BOOT_HASH" ]
        return
    fi

    if [ "$v" != off ] && ! boot_hash_valid "$v"; then return 1; fi

    tmp="${KL_BOOT_HASH}.tmp.$$"
    printf '%s\n' "$v" > "$tmp" 2>/dev/null || return 1
    chmod 600 "$tmp" 2>/dev/null
    mv -f "$tmp" "$KL_BOOT_HASH" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
    [ -f "$KL_BOOT_HASH" ]
}

# 说明：把配置写进 ro.boot.vbmeta.digest 并读回校验；hash_alg 只在为空时补，
#       由 digest 长度决定 sha256/sha512。只用 -n：重启即回系统原值，不留持久化痕迹。
# 用法：apply_boot_hash
# 返回：0=无需处理或已写入且读回一致 1=有配置但无法写入/读回不一致
apply_boot_hash() {
    local h cur alg want now

    h=$(boot_hash_get)
    [ -n "$h" ] || return 0
    command -v resetprop >/dev/null 2>&1 || return 1

    cur=$(resetprop ro.boot.vbmeta.digest 2>/dev/null)
    [ "$cur" = "$h" ] || resetprop -n ro.boot.vbmeta.digest "$h" 2>/dev/null

    alg=$(resetprop ro.boot.vbmeta.hash_alg 2>/dev/null)
    if [ -z "$alg" ]; then
        want=sha256
        [ "${#h}" -eq 128 ] && want=sha512
        resetprop -n ro.boot.vbmeta.hash_alg "$want" 2>/dev/null
    fi

    now=$(resetprop ro.boot.vbmeta.digest 2>/dev/null)
    [ "$now" = "$h" ]
}

# ---------- 属性判定：一次 awk 出计划 ----------
# 说明：判定要读"表里每一个属性的当前值"。两条老路都上机量过，都不合用：
#   · 逐键起进程 —— 单键 getprop 15.7ms、单键 resetprop 读 32ms；这张表 52 行，
#     开机伪装与界面「写入并复核」都会进秒级（现量 old 净 433ms）。
#   · dump 进 shell 变量再参数展开查表 —— mksh 的字面匹配随字符串长度**平方级**
#     增长：66897 字节 ×15 个键 = 160307ms；先拿 grep -F 裁到 2725 字节（52 键），
#     再查 53 次仍然要 1841ms。裁小只是缓药，不是解。
# 所以现在是一次 getprop + 一次 awk：awk 吃"两张表 + 全量 dump"，吐出行数与决策，
# shell 只把该写的写下去。awk 是单遍扫描，表加多少行都不改变成本形状。
#
# 三条不许破的规矩：
#   1) 复核必须重新取一次快照（shell 侧 props_readback 新起进程；Rust 写完重新
#      prop_snapshot）——拿写前那份自证等于什么都没复核。
#   2) awk 不在，或属性区一条都没读到（ndump==0）时退 2，调用方逐键回落。
#      宁可慢，不可把"读不到"当成"属性不存在"而凭空写出一堆 stock 没有的键。
#   3) 同一个属性名不许同时出现在固定表与特征表里（两处各写各的，说不清谁赢）；
#      由 tests/props-plan.sh 钉住。
PROP_NOW=""
PROP_REWRITTEN=""

# 用法：props_substr_replace <值> <特征> <替换>；结果放在 PROP_REWRITTEN（不起进程）
# 说明：与 awk 里的 rewrite() 同语义 —— 值里每一处特征都换，其余字符原样保留。
props_substr_replace() {
    local v="$1" needle="$2" rep="$3" out=""

    while [ -n "$v" ]; do
        case "$v" in
            *"$needle"*)
                out="$out${v%%"$needle"*}$rep"
                v=${v#*"$needle"}
                ;;
            *) out="$out$v"; v="" ;;
        esac
    done
    PROP_REWRITTEN="$out"
}

# 用法：props_plan <display|write>
#   display：每行「属性名	当前值	期望值(或特征描述)	状态」，顺序 = 固定表 + 特征表
#            状态取 ok / diff / missing（固定表缺值，要凭空补出来）/ absent（特征表
#            这台机压根没有这个分区，不算缺陷、不计入 mismatch）
#   write  ：每行「属性名	应当写入的值」，只列真需要动的；同一个属性的多条特征
#            按表序链式改完，合起来只出一条
# 退 2 = 这次判定不可用（没有 awk / 属性区没读到 / 表行读不出列），调用方必须逐键回落。
#
# 说明：两张表**原样**喂给 awk，只在前面各加一行 P/R 模式标记 —— 全程 3 次 printf。
#       以前这里是 shell 逐行 printf 拼 spec：设备上 mksh 的 printf **不是内置**，
#       每一行都要 fork（真机现量 rules 38 行 = 582ms、pairs 15 行 = 269ms ≈ 850ms），
#       比 awk 本身（40ms）+ getprop（65ms）贵一个数量级。表加行就贵 15ms，
#       正是这张表要走的路。
#       按"第一个空白切出属性名，其余整段留给值"解析，所以值里带空格也不会丢列；
#       切不出值的行（没有空白）算表读不出 → 退 2 走逐键回落，不静默少掩一项。
props_plan() {
    local mode="${1:-display}" _awk="${AWK_CMD:-awk}"

    # 先把 awk 认准，再开管道。不能靠"管道右边 exec 失败"把错传出来：Git Bash 的 bash
    # 会让左边写进一条没人读的管道**永久阻塞**（实测整个台子卡死），dash 与 mksh 却立刻返回。
    # 判定这一步在开机路径上，任何"看 shell 心情"的失败模式都不许留。
    # AWK_CMD 可能是「busybox awk」两个词，所以只查第一个词。
    command -v "${_awk%% *}" >/dev/null 2>&1 || return 2

    {
        printf 'P\n'
        props_expect_pairs
        printf 'R\n'
        props_expect_rules
        printf -- '--\n'
        getprop 2>/dev/null
    } | ${_awk} -v MODE="$mode" '
        BEGIN { FS = "\t"; OFS = "\t" }
        function rewrite(v, needle, rep,   out, i) {
            out = ""
            while ((i = index(v, needle)) > 0) {
                out = out substr(v, 1, i - 1) rep
                v = substr(v, i + length(needle))
            }
            return out v
        }
        function head(rest,   i) {                # 取第一个空白前的那段
            i = index(rest, " ")
            if (i == 0) i = index(rest, "\t")
            if (i == 0) return rest
            return substr(rest, 1, i - 1)
        }
        function tail(rest,   i) {                # 去掉第一段与紧随的空白
            i = index(rest, " ")
            if (i == 0) i = index(rest, "\t")
            if (i == 0) return ""
            return substr(rest, i + 1)
        }
        sep == 0 {
            if ($0 == "--") { sep = 1; next }
            if ($0 == "P" || $0 == "R") { specmode = $0; next }
            if (specmode == "") next              # 标记之前的杂行丢掉
            name = head($0); rest = tail($0)
            sub(/^[ \t]+/, "", rest)
            if (name == "" || rest == "") { badspec = 1; next }
            np++
            if (specmode == "P") {
                t[np] = "P"; key[np] = name; expv[np] = rest
            } else {
                t[np] = "R"; key[np] = name; ndl[np] = head(rest); rpl[np] = tail(rest)
                sub(/^[ \t]+/, "", rpl[np])
                if (ndl[np] == "" || rpl[np] == "") { badspec = 1; next }
            }
            want[name] = 1
            next
        }
        {
            line = $0
            if (substr(line, 1, 1) != "[") next
            i = index(line, "]: [")
            if (i < 3) next
            k = substr(line, 2, i - 2)
            v = substr(line, i + 4)
            sub(/\]$/, "", v)                     # 只剥行尾那一个 ]，值里的 ] 留着
            if (k in want) { cur[k] = v; seen[k] = 1 }
            ndump++
            next
        }
        END {
            if (badspec) { print "props_plan: 表里有读不出列的行" > "/dev/stderr"; exit 2 }
            if (ndump == 0) { print "props_plan: 属性区一条都没读到" > "/dev/stderr"; exit 2 }
            for (n = 1; n <= np; n++) {
                k = key[n]
                # 注意：不要写成 c = (k in seen) ? cur[k] : "" 之后又往 cur[k] 里放东西，
                # 也不要把 `k in 数组` 塞进"同一个数组的赋值语句"的参数里 —— mawk 会先把
                # 左边的元素创建出来，于是 (k in goal) 恒真、底数取到空串，链式改写整条
                # 变成写空值（真机/WSL 的 mawk 上实测复现，Git Bash 的 gawk 却不会）。
                # 一律用"先取标量、再判存在"的写法，两个方言都吃得下。
                c = ""
                if (k in seen) c = cur[k]
                if (t[n] == "P") {
                    e = expv[n]
                    st = (c == "") ? "missing" : ((c == e) ? "ok" : "diff")
                    if (MODE == "display") { print k, c, e, st; continue }
                    goal[k] = e
                } else {
                    hit = 0
                    if (c != "" && index(c, ndl[n]) > 0) hit = 1
                    st = "ok"
                    if (c == "") st = "absent"
                    else if (hit) st = "diff"
                    if (MODE == "display") {
                        print k, c, "不含 " ndl[n] "（则改写为 " rpl[n] "）", st
                        continue
                    }
                    if (hit) {
                        base = c
                        if (k in goal) base = goal[k]
                        goal[k] = rewrite(base, ndl[n], rpl[n])
                    }
                }
                if (!(k in touched)) { touched[k] = 1; ord[++no] = k }
            }
            if (MODE != "write") exit 0
            for (n = 1; n <= no; n++) {
                k = ord[n]
                if (!(k in goal)) continue
                c = ""
                if (k in seen) c = cur[k]
                if (goal[k] != c) print k, goal[k]
            }
        }'
}

# ---------- 应用伪装 ----------
# 说明：判定交给 props_plan（一次 getprop + 一次 awk），这里只负责落盘。
#       供 post-fs-data.sh 在 Zygote 前调用。
# 用法：apply_resetprop
apply_resetprop() {
    local plan="" name="" value="" tab="" rc=0

    command -v resetprop >/dev/null 2>&1 || return 0

    plan=$(props_plan write 2>/dev/null); rc=$?
    if [ "$rc" != 0 ]; then
        apply_resetprop_fallback
        return 0
    fi
    tab=$(printf '\t')
    while IFS="$tab" read -r name value; do
        [ -n "$name" ] || continue
        resetprop -n "$name" "$value" 2>/dev/null
    done <<PLAN
$plan
PLAN
    return 0
}

# 说明：awk 不在（或属性区读空）时的慢路 —— 逐键读写。
#       特征行的链式改在这里靠"写一条读一次"天然成立：后一条规则读到的就是前一条
#       刚写进去的值，与 props_plan 里一次性串完的结果同序同值。
apply_resetprop_fallback() {
    local name="" expected="" needle="" replacement="" value=""

    props_expect_pairs | while read -r name expected; do
        [ -n "$name" ] && [ -n "$expected" ] || continue
        value=$(resetprop "$name" 2>/dev/null)
        if [ -z "$value" ] || [ "$value" != "$expected" ]; then
            resetprop -n "$name" "$expected" 2>/dev/null
        fi
    done

    props_expect_rules | while read -r name needle replacement; do
        [ -n "$name" ] && [ -n "$needle" ] || continue
        value=$(resetprop "$name" 2>/dev/null)
        case "$value" in
            *"$needle"*)
                props_substr_replace "$value" "$needle" "$replacement"
                resetprop -n "$name" "$PROP_REWRITTEN" 2>/dev/null ;;
        esac
    done
}
