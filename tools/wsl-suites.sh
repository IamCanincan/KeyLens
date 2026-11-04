#!/bin/sh
# 在 Linux（WSL Debian）侧把 tests/*.sh 全跑一遍，结论与**逐套退码**落在 rust/../tests-wsl.log。
# 为什么要有这个文件（和 tools/wsl-parity.sh 同一个理由）：从 Windows 的 Git Bash 内联
#   wsl -d Debian sh -c 'for t in …; do … $? …'
# 里的 $? / $t 会在**本地**先被展开掉，量到的永远是空串和 0 —— 本轮就是这么拿到一份
# 四行"FAIL "（连套名都被吞掉）的假失败清单的。要 Windows 这边读，就让它落进文件。
# 用法：wsl -d Debian sh /mnt/d/<仓库路径>/tools/wsl-suites.sh   → 末行 = suites=N failures=M
cd "$(dirname "$0")/.." || exit 99
LOG=tests-wsl.log
: > "$LOG"
n=0
f=0
for t in tests/*.sh; do
    n=$((n + 1))
    sh "$t" >>"$LOG" 2>&1
    rc=$?
    if [ "$rc" != "0" ]; then
        f=$((f + 1))
        printf 'FAIL  %s (exit=%s)\n' "$t" "$rc" >>"$LOG"
    else
        printf 'ok    %s\n' "$t" >>"$LOG"
    fi
done
printf 'suites=%s failures=%s\n' "$n" "$f" >>"$LOG"
tail -1 "$LOG"
