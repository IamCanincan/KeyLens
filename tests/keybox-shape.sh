#!/system/bin/sh
#=============================================================================
# tests/keybox-shape.sh - keybox 的结构校验必须**按后端分叉**
#
# 起因：命令层以前对三家共用一句判据 —— `grep -q '<AndroidAttestation'`。
# 对照上游源码逐家核过之后，
# 那句对 Tricky 是对的，对 TEESim **严于**上游（它不看根元素名，会被误拒），
# 对 OMK **宽于**上游（它要求每个 <Key> 块自带 <NumberOfCertificates>N</NumberOfCertificates>
# 且本块证书数与之相等；不符时 OMK 不只是不生效 —— 会把自带模板**覆盖回这个文件**）。
#
# 语料用上游真实发布的两份：
#   tests/fixtures/keybox-tricky-aosp.xml  = TrickyStoreOSS/module/keybox.xml（装机时自己刷的那份 AOSP 软件密钥箱）
#   tests/fixtures/keybox-omk-template.xml = OhMyKeymint/template/keybox.xml（OMK 覆盖用的那份模板）
# 正对照必须由**真文件**担任：自己造的样本只会证明代码符合我自己的想象。
#
# 跑法：sh tests/keybox-shape.sh
#=============================================================================
set -u
cd "$(dirname "$0")/.." || exit 1
. tests/lib/kl-src.sh        # 命令层实现分两份（webui.sh + lib/write.sh），见该文件说明
AWK=${AWK:-awk}
fail=0
AWKF=module/backends/keybox_check.awk
F1=tests/fixtures/keybox-tricky-aosp.xml
F2=tests/fixtures/keybox-omk-template.xml
D=$(mktemp -d 2>/dev/null || echo /tmp/kbs-$$); mkdir -p "$D"
# 建不出来就自己说清楚：这里死过一次（rc≠0 却一条 ✗ 都没打），只看得出"失败了"。
[ -d "$D" ] || { echo '  ✗    临时目录建不起来（mktemp 与 /tmp 回退都失败）'; exit 1; }

# 跑一次校验，结果放 LAST（"ok" 或 "err<TAB>原因"），退码放 RC
run() {
  LAST=$( $AWK -v backend="$2" -f "$AWKF" "$1" 2>&1 )
  RC=$?
}
expect_ok() {
  run "$2" "$3"
  if [ "$RC" = 0 ] && [ "$LAST" = "ok" ]; then printf '  ok   %s · %s\n' "$1" "$3"
  else printf '  ✗    %s · %s 本该通过，实得[%s] rc=%s\n' "$1" "$3" "$LAST" "$RC"; fail=1; fi
}
# want=原因里必须出现的关键词：只判"退码非 0"的话，任何理由都能把测试做绿
expect_err() {
  local k="$4"
  run "$2" "$3"
  if [ "$RC" != 0 ] && [ "${LAST#err	}" != "$LAST" ] && printf '%s' "$LAST" | grep -q "$k"; then
    printf '  ok   %s · %s 被拒且点名判据\n' "$1" "$3"
  else
    printf '  ✗    %s · %s 本该因"%s"被拒，实得[%s] rc=%s\n' "$1" "$3" "$k" "$LAST" "$RC"; fail=1
  fi
}
# 变异必须自证落地：命中数不等于预期就说明这一条根本没改到，测了也是假测
mutate() {
  local out="$1" src="$2" pat="$3" rep="$4" want="$5" n
  n=$( $AWK -v p="$pat" -v r="$rep" '{ t += gsub(p, r) } END { print t + 0 }' "$src" )
  if [ "$n" != "$want" ]; then
    printf '  ✗    变异没落地：%s 命中 %s 处，预期 %s\n' "$pat" "$n" "$want"; fail=1; return 1
  fi
  $AWK -v p="$pat" -v r="$rep" '{ gsub(p, r); print }' "$src" > "$out" || { printf '  ✗    变异写出失败\n'; fail=1; return 1; }
  [ -s "$out" ] || { printf '  ✗    变异产物是空的\n'; fail=1; return 1; }
  return 0
}

[ -f "$AWKF" ] || { printf '  ✗    找不到 %s\n' "$AWKF"; exit 1; }
[ -s "$F1" ] && [ -s "$F2" ] || { printf '  ✗    缺上游语料，这份测试就没有正对照\n'; exit 1; }

printf '── 正对照：上游真实发布的两份 keybox ──\n'
for b in tricky teesim omk; do expect_ok 'AOSP 软件密钥箱' "$F1" "$b"; done
for b in tricky teesim omk; do expect_ok 'OMK 自带模板' "$F2" "$b"; done
# OMK 模板写着 NumberOfKeyboxes=2 却只有一个 <Keybox>：判据若去查这个数，
# 就会把上游自己装的那份判成不合格 —— 这条是专门钉"不许严于上游"的。
printf '  ok   （OMK 模板的 NumberOfKeyboxes=2 与实际 1 个 <Keybox> 不符，校验故意不看它）\n'

printf '── 差异对照：同一份内容，两家结论必须不同 ──\n'
# ① 只有 <Keybox> 根、没有 <AndroidAttestation>：TEESim 不看根元素名（attest.rs 用 roxmltree
#    直接找 <Key>），Tricky 在深度 1 就判死。共用判据必然在其中一家是错的。
mutate "$D/rootbox.xml" "$F1" '</AndroidAttestation>' '</KeyboxRoot>' 1 || exit 1
mutate "$D/rootbox2.xml" "$D/rootbox.xml" '<AndroidAttestation>' '<KeyboxRoot>' 1 || exit 1
expect_ok  '无 AndroidAttestation 根' "$D/rootbox2.xml" teesim
expect_err '无 AndroidAttestation 根' "$D/rootbox2.xml" tricky '根元素'
# ② 声明 3 张证书、实际 2 张：OMK 数不等就 bail（然后覆盖你的文件），
#    Tricky/TEESim 不看这个数，必须照收。
mutate "$D/over.xml" "$F2" '<NumberOfCertificates>2</NumberOfCertificates>' '<NumberOfCertificates>3</NumberOfCertificates>' 2 || exit 1
expect_ok  '证书数声明 3 实际 2' "$D/over.xml" tricky
expect_ok  '证书数声明 3 实际 2' "$D/over.xml" teesim
expect_err '证书数声明 3 实际 2' "$D/over.xml" omk '声明 3 张证书'
# ③ 算法名大写：TEESim 只比小写 rsa/ecdsa，OMK 的 match 表里没有 EC
#    （输出文件不能和输入同名：awk 正在读的时候 shell 已经把那份截空了）
mutate "$D/upper.xml" "$F1" 'algorithm="ecdsa"' 'algorithm="ECDSA"' 1 || exit 1
mutate "$D/upper2.xml" "$D/upper.xml" 'algorithm="rsa"' 'algorithm="RSA"' 1 || exit 1
expect_err '算法名大写' "$D/upper2.xml" teesim '小写'
expect_err '算法名大写' "$D/upper2.xml" omk 'EC 密钥'
# ④ 少一张证书（TEESim 运行时要求 ≥2）：删掉第一个 <Certificate 开标签
mutate "$D/few.xml" "$F2" '<Certificate format="pem">' 'X' 4 || exit 1
expect_err '证书数 0' "$D/few.xml" teesim '至少'
expect_err '证书数 0' "$D/few.xml" omk '声明 2 张证书，实际数到 0'
# ⑤ 缺 <NumberOfCertificates>：OMK 当必需项，另两家可选
mutate "$D/nocount.xml" "$F2" '<NumberOfCertificates>[0-9]*</NumberOfCertificates>' '' 2 || exit 1
expect_err '没有 NumberOfCertificates' "$D/nocount.xml" omk '没有 <NumberOfCertificates>'
expect_ok  '没有 NumberOfCertificates' "$D/nocount.xml" tricky
expect_ok  '没有 NumberOfCertificates' "$D/nocount.xml" teesim
# ⑥ <Key> 没有 </Key> 收尾：OMK 的整块正则取不到 body
mutate "$D/unbalanced.xml" "$F2" '</Key>' '' 2 || exit 1
expect_err 'Key 块不闭合' "$D/unbalanced.xml" omk '没有 </Key> 收尾'
# ⑦ 空文件与不认识的后端名
: > "$D/empty.xml"
expect_err '空文件' "$D/empty.xml" tricky '空文件'
expect_err '空文件' "$D/empty.xml" omk '空文件'
run "$F1" "nope"
[ "$RC" != 0 ] && printf '  ok   不认识的后端名直接拒（防止 case 打错就默认放行）\n' \
  || { printf '  ✗    backend=nope 竟然通过：[%s]\n' "$LAST"; fail=1; }

# ⑨ 整份压成一行：计数必须按**出现次数**，不能按行（grep -c 那种写法在这里会少数）
$AWK '{ printf "%s", $0 }' "$F2" > "$D/oneline.xml"
expect_ok  '单行化的 OMK 模板' "$D/oneline.xml" omk
expect_ok  '单行化的 OMK 模板' "$D/oneline.xml" tricky
# 单行 + 声明 3 张：仍要抓出"实际 2 张"，证明按行计数没混进来
mutate "$D/oneline3.xml" "$D/oneline.xml" '<NumberOfCertificates>2</NumberOfCertificates>' '<NumberOfCertificates>3</NumberOfCertificates>' 2 || exit 1
expect_err '单行化 + 证书数不符' "$D/oneline3.xml" omk '声明 3 张证书'

# ⑧ 旧的共用判据必须被这条打回：只 grep AndroidAttestation 的话，
#    ②③④⑤⑥ 这一堆 OMK 会当场 bail 并被覆盖的文件全都进得去。
printf '── 命令层是否还留着那份共用判据 ──\n'
# 先剔掉注释行：这条判的是"代码里还有没有那句共用判据"，不是"文件里有没有这个字"。
# 第一版没剔，被自己写在 webui.sh 里的那句说明顶了回来，差点去改掉注释。
if grep -vE '^[[:space:]]*#' "$KL_SRC" | grep -q 'AndroidAttestation'; then
  printf '  ✗    webui.sh 的代码里还留着按根元素名判死的旧写法，应改为调用 keybox_check.awk\n'; fail=1
else
  printf '  ok   webui.sh 不再自带 keybox 判据\n'
fi
grep -q 'keybox_check.awk' "$KL_SRC" \
  && printf '  ok   cmd_keybox_save 接上了分叉后的 awk 校验\n' \
  || { printf '  ✗    cmd_keybox_save 没调用 keybox_check.awk\n'; fail=1; }

rm -rf "$D"
[ "$fail" = 0 ] && echo "全部通过" || echo "有断言失败"
exit $fail
