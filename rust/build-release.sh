#!/bin/sh
# 发布构建：nightly + build-std + immediate-abort。
#
# 为什么不用稳定版：
#   - `-Z build-std` 让 std 跟着 opt-level=z / panic 配置重编，产物不再带稳定版 std 的
#     那套展开/回溯机器；
#   - `-Cpanic=immediate-abort`（nightly 1.101 起是正式的 panic 策略）把 panic 的格式化
#     与展开整块去掉。
#   现量：aarch64 652,960 → 326,416 字节（-50%），发布包约 -180KB。
#
# 代价与前提：
#   - 需要 nightly + rust-src + 两个 musl target（见下面 die 的提示）；
#   - panic 时不再打印 "panicked at …"、退出码从 101 变成 SIGABRT。所有命令的错误路径
#     都走 Result + 自己的退出码（README/对拍 247 项 + 真机台子覆盖），不依赖 panic 文案。
#
# 用法：sh rust/build-release.sh   （产出 rust/target/<target>/release/keylens）
set -eu
cd "$(dirname "$0")"

TARGETS="aarch64-unknown-linux-musl x86_64-unknown-linux-musl"
FLAGS="-C linker=rust-lld -C link-self-contained=yes -Zunstable-options -Cpanic=immediate-abort"

die() { echo "✗ $*" >&2; exit 1; }

cargo +nightly --version >/dev/null 2>&1 || die "需要 nightly：
  rustup toolchain install nightly --profile minimal --component rust-src"
rustup +nightly component list --installed 2>/dev/null | grep -q '^rust-src' \
  || die "nightly 缺 rust-src：rustup +nightly component add rust-src"
for t in $TARGETS; do
  rustup +nightly target list --installed 2>/dev/null | grep -qx "$t" \
    || die "nightly 缺 target $t：rustup +nightly target add $t"
done

for t in $TARGETS; do
  upper=$(printf '%s' "$t" | tr 'a-z-' 'A-Z_')
  echo "── $t"
  env "CARGO_TARGET_${upper}_RUSTFLAGS=$FLAGS" \
    cargo +nightly build --release --target "$t" -Z build-std=std,panic_abort
done

ls -l target/aarch64-unknown-linux-musl/release/keylens target/x86_64-unknown-linux-musl/release/keylens
