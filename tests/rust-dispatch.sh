#!/bin/sh
# rust-dispatch：命令层 Rust 化开关的行为（阶段 5 预置）。
# 这段在 webui.sh 里被标记包着，测试按标记抽出来单独跑——不需要 root，也不依赖真机。
set -u
cd "$(dirname "$0")/.." || exit 1
WEBUI=module/webui.sh
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  ✗    $1"; echo "       want=[$3]"; echo "       got =[$2]"; fail=1; fi; }

# 抽出标记之间的那一段
awk '/^# >>> rust-dispatch/{f=1;next} /^# <<< rust-dispatch/{f=0} f' "$WEBUI" > /tmp/kl_dispatch.sh
[ -s /tmp/kl_dispatch.sh ] || { echo "没有找到 rust-dispatch 标记段"; exit 1; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
# 假二进制：把参数写进文件后按指定退码退出
cat > "$tmp/stub0" <<'EOF'
#!/bin/sh
printf 'rust:%s:%s\n' "$1" "${2:-}"
exit 0
EOF
cat > "$tmp/stub2" <<'EOF'
#!/bin/sh
printf 'rust:%s\n' "$1"
exit 2
EOF
chmod +x "$tmp/stub0" "$tmp/stub2"

run() { # <bin> <cmd> [arg] [use_rust]
  env CMD="$2" ARG="${3:-}" MODDIR=/nonexistent \
      KL_RUST_BIN="$1" KL_USE_RUST="${4:-1}" \
      sh -c '. /tmp/kl_dispatch.sh; printf "shell-fallback\n"' 2>&1
}

chk "开关打开 + 二进制存在 → 走 Rust" "$(run "$tmp/stub0" status "" 1)" "rust:status:"
chk "带参数的命令也传参" "$(run "$tmp/stub0" log 30 1)" "rust:log:30"
chk "Rust 返回 2 → 回落 shell" "$(run "$tmp/stub2" sync "" 1)" "rust:sync
shell-fallback"
chk "开关关闭 → 不接管" "$(run "$tmp/stub0" status "" 0)" "shell-fallback"
chk "预览命令不接管" "$(run "$tmp/stub0" preview-keybox-save "" 1)" "shell-fallback"

rm -f /tmp/kl_dispatch.sh
[ "$fail" = 0 ] && echo "全部通过" || { echo "有断言失败"; exit 1; }
