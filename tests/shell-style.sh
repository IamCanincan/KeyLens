#!/system/bin/sh
#=============================================================================
# tests/shell-style.sh - shell 文件里不许有 C 风格注释
#
# 为什么单开一条：`/* … */` 在 sh 里不是注释，是**命令**。`sh -n` 照样通过
# （`/*` 会被当成一个词），只有真跑到那一行才报 "/adb_keys: inaccessible"。
# 2026-10-30 装 KeyLens 时我把一段说明写成 /* */，四行全被当成命令执行，
# 语法检查一点没拦住 —— 这类错误只能靠"看见才报"，所以做成静态闸。
#
# 跑法：sh tests/shell-style.sh
#=============================================================================
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  ✗    %s\n' "$1"; fail=1; }

n=0
for f in $(git ls-files '*.sh' 'module/*.sh' 'module/lib/*.sh' 'module/backends/*.sh' 2>/dev/null | sort -u); do
    [ -f "$f" ] || continue
    n=$((n + 1))
    # `/*)` 单独一行是 case 的"绝对路径"模式，不是注释 —— 只有它放行，
    # 真正的 `/* … */` 说明照旧要报。（grep 单文件时输出是「行号:正文」，
    # 多文件才是「路径:行号:正文」—— 两种都要认，这个坑 write-hygiene 那里也踩过。）
    hit=$(grep -nE '^[[:space:]]*(/\*|\*/)' "$f" 2>/dev/null | grep -vE '(:|^)[0-9]+:[[:space:]]*/\*\)[[:space:]]*$' | head -2)
    [ -n "$hit" ] && { bad "C 风格注释（会被当成命令执行）：$f"; printf '        %s\n' "$hit"; }
done
[ "$n" -gt 10 ] && ok "扫了 $n 个 shell 文件，没有 C 风格注释" || bad "只扫到 $n 个文件（清单不对？）"

[ "$fail" = 0 ] && echo "全部通过" || echo "有断言失败"
exit $fail
