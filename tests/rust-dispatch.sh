#!/bin/sh
# rust-dispatch：命令层 Rust 化开关的行为（阶段 5 预置）。
# 这段在 webui.sh 里被标记包着，测试按标记抽出来单独跑——不需要 root，也不依赖真机。
set -u
cd "$(dirname "$0")/.." || exit 1
WEBUI=module/webui.sh
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  ✗    $1"; echo "       want=[$3]"; echo "       got =[$2]"; fail=1; fi; }

# 抽出标记之间的那一段
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# 抽出标记之间的那一段（抽不到就是标记被挪走了，当场红）
awk '/^# >>> rust-dispatch/{f=1;next} /^# <<< rust-dispatch/{f=0} f' "$WEBUI" > "$tmp/dispatch.sh"
[ -s "$tmp/dispatch.sh" ] || { echo "没有找到 rust-dispatch 标记段"; exit 1; }

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
cat > "$tmp/stub1" <<'EOF'
#!/bin/sh
printf 'rust:%s\n' "$1"
echo "未知命令：$1" >&2
exit 1
EOF
chmod +x "$tmp/stub0" "$tmp/stub2" "$tmp/stub1"

# 数 argv 的桩：接管点必须把 ARG 当**一个**参数转过去。
# 界面发的是 `set-mode '包名 模式'`（webui.sh 的分派臂按第一个空格拆），所以接管点
# 一旦被人"顺手"改成不带引号的 $ARG，包名和模式就散成两个 argv，那颗按钮当场死。
cat > "$tmp/stubc" <<'EOF'
#!/bin/sh
printf 'rust:%s:argc=%d:argv2=%s\n' "$1" "$#" "${2:-}"
exit 0
EOF
chmod +x "$tmp/stubc"

# 被测段读的是变量，所以赋值必须留在同一个 shell 里：别写成 `env VAR=x sh -c …` ——
# 这台 Windows 的 env 会把 `env sh 脚本` 跑成空输出（本测试之前在 Git Bash 里恒红、
# 在 WSL 里全绿，就是这个差别，与被测代码无关）。
run() { # <bin> <cmd> [arg] [use_rust]
    {
        printf 'CMD="%s"\n' "$2"
        printf 'ARG="%s"\n' "${3:-}"
        printf 'MODDIR=/nonexistent\n'
        printf 'KL_RUST_BIN="%s"\n' "$1"
        if [ "$#" -ge 4 ] && [ -n "${4:-}" ]; then printf 'KL_USE_RUST="%s"\n' "$4"; fi
        printf '. "%s/dispatch.sh"\n' "$tmp"
        printf 'printf "shell-fallback\\n"\n'
    } > "$tmp/w.sh"
    sh "$tmp/w.sh" 2>&1
}

chk "开关打开 + 二进制存在 → 走 Rust" "$(run "$tmp/stub0" status "" 1)" "rust:status:"
chk "带参数的命令也传参" "$(run "$tmp/stub0" log 30 1)" "rust:log:30"
chk "带空格的单参数原样转发（argc 只有 2）" \
  "$(run "$tmp/stubc" set-mode 'com.a leaf' 1)" "rust:set-mode:argc=2:argv2=com.a leaf"
chk "Rust 返回 2 → 回落 shell" "$(run "$tmp/stub2" sync "" 1)" "rust:sync
shell-fallback"
chk "开关关闭 → 不接管" "$(run "$tmp/stub0" status "" 0)" "shell-fallback"
chk "默认（不设开关）→ 有二进制就用 Rust" "$(run "$tmp/stub0" status "" "")" "rust:status:"
chk "默认但二进制不存在 → 回落 shell" "$(run "$tmp/nope" status "" "")" "shell-fallback"

printf '── preview-* 的接管与回落 ──\n'
# 接管段必须整段前缀不剥：剥了再接管，二进制收到的就是真写命令（预览变真写，见 webui.sh 接管点注释）
chk "预览命令交给二进制，前缀原样传过去" "$(run "$tmp/stub0" preview-keybox-save x 1)" "rust:preview-keybox-save:x"
chk "二进制预览成功 → 不再走 shell（信封只有一份）" "$(run "$tmp/stub0" preview-omk-save-config x 1)" "rust:preview-omk-save-config:x"
chk "二进制不认识 preview-*（退 1）→ 回落 shell 原地预览" "$(run "$tmp/stub1" preview-keybox-save x 1)" "rust:preview-keybox-save
未知命令：preview-keybox-save
shell-fallback"
chk "二进制不存在 → 预览照旧走 shell" "$(run "$tmp/nope" preview-keybox-save x 1)" "shell-fallback"
chk "KL_USE_RUST=0 → 预览也留在 shell" "$(run "$tmp/stub0" preview-keybox-save x 0)" "shell-fallback"
chk "正对照：普通命令的非 0 退码要透传，不许被回落掩盖" "$(run "$tmp/stub1" status "" 1)" "rust:status
未知命令：status"

[ "$fail" = 0 ] && echo "全部通过" || { echo "有断言失败"; exit 1; }
