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
  # 这里**不用** `env VAR=… cargo`：这台 Windows 机上 `~/.local/bin/env`（uv 装的）排在 PATH
  # 前面，那个脚本只改 PATH、不执行参数，于是 `env … cargo …` 原地退 0 且一个字节都没编 ——
  # 脚本"全部通过"，产物还是上一轮的旧二进制（2026-11-03 就这么骗过我一整轮）。
  export "CARGO_TARGET_${upper}_RUSTFLAGS=$FLAGS"
  cargo +nightly build --release --target "$t" -Z build-std=std,panic_abort
done

# 自证"这一轮真的编译了"：产物不许比源码旧（与 parity.sh 开头那条守卫同款）。
# 上面那条坑的现场就是"rc=0 + 无输出 + 产物没动"，只看退码抓不到它。
for t in $TARGETS; do
  b="target/$t/release/keylens"
  [ -f "$b" ] || die "没有产出 $b"
  stale=$(find src Cargo.toml -newer "$b" 2>/dev/null | head -1)
  if [ -n "$stale" ]; then
    die "$b 比源码旧（$stale 在其之后改过）—— 这一轮没有真编译，别拿这个产物装机/对拍"
  fi
done

ls -l target/aarch64-unknown-linux-musl/release/keylens target/x86_64-unknown-linux-musl/release/keylens
