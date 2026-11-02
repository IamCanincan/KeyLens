#!/bin/sh
# 在 Linux（WSL Debian）侧跑对拍，把结论与**退码一起落在最后一行**。
# 为什么要这个文件：从 Windows 的 Git Bash 内联问退码
#   wsl -d Debian bash -c 'sh rust/parity.sh; echo exit=$?'
# 那个 $? 在本地就被展开掉了，量到的永远是 0 —— 本轮差点据此误报"对拍的退码逻辑坏了、
# CI 那道闸形同虚设"。要 Windows 这边读，就让它落进文件（*.log 已在 .gitignore 里）。
# 用法（WSL 侧）：sh tools/wsl-parity.sh [二进制路径]，然后看 rust/parity-wsl.log 的最后一行。
cd "$(dirname "$0")/.." || exit 99
sh rust/parity.sh "$@" > rust/parity-wsl.log 2>&1
code=$?
printf 'parity exit=%s｜%s\n' "$code" "$(tail -1 rust/parity-wsl.log)" >> rust/parity-wsl.log
exit "$code"
