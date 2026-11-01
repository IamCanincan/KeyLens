# 交接文档（KeyLens 命令层 Rust 化）

> 给接手的人/agent：这份文档是当前会话的完整状态。**先读「怎么验证」一节跑一遍闸门**，再按「剩余工作」继续。
> 代码都在 `main` 分支上，126 个提交**尚未推送**（本机无法访问 github.com）。

## 0. 仓库与环境

- 仓库：`D:\Github Repositories\TS-AUTO-ADD`（旧名 TS-AUTO-ADD，模块名已改 KeyLens）
- 分支：`main`，HEAD 见 `git log -1`
- 未推送提交：126 个（`git rev-list --count origin/main..main`）
- 离线兜底：`D:\Github Repositories\keylens-unpushed-2026-11-01.bundle`（只覆盖到生成时刻）
  - 恢复：`git fetch <bundle> main:recovered`
- 网络现状：**github.com DNS 解析失败**；`static.rust-lang.org` / `baidu` 可达。所以 `rustup target add` 能用，`git push` 不能。
- 本地工具链：Windows + WSL(Ubuntu)。**Rust 构建/测试都在 WSL 里跑**（`~/.cargo/bin/cargo`），Windows 侧没有可用链接器。
- 真机：`adb devices` 里有 `QV7709NLJ7`（arm64-v8a，`adb root` 可拿到 root，build 是 userdebug）。
  模块已装：`/data/adb/modules/keylens`（v3.0.1，OMK 后端）。测试用的临时副本在 `/data/adb/keylens-ab`。

## 1. 现在完成到哪

**命令层 40/40 全部用 Rust 实现**（`rust/src/*.rs`，`read_cmds.rs` 约 5.4k 行），命令契约（40 条、同序、同 kv/tsv 输出）保持不变。

| 证据 | 数值 | 怎么跑 |
|---|---|---|
| Rust 单测 | 70 项 | 见 §2 |
| shell↔Rust 逐字节对拍 | 129 项 chk | `sh rust/parity.sh` |
| shell 测试套 | 46 套 0 失败 | 见 §2 |
| 真机 A/B（只读 17 + 写 21） | **38/38 全过** | `sh tests/device-ab.sh [--write]` |
| 真机 preview 对拍 | `preview-keybox-save` **逐字节相同** | 见 §4 |
| 黄金快照 | 10 条只读命令 | `sh tests/rust-golden.sh` |
| 静态链接判据 | NEEDED=0 / 无 INTERP | `sh tests/static-check.sh` |
| 包内二进制握手 | contract == KL_COMMANDS | `sh tests/module-bin.sh` |
| 体积 | x86_64 glibc 633 KB / 静态 musl 730 KB / aarch64 musl 619 KB | `stat -c %s` |

已实现的关键设施：
- 后端探测（teesim/omk/tricky，含 disable 与冲突检测）、并发锁（证据式接管）、base64/payload、`json_flat`、keybox 三家校验；
- `omk_set` TOML 引擎、teesim 嵌套 JSON 编辑（`member_span`）、`tricky_info`/`teesim_info`/`omk_info` 摘要；
- `sync` 的 `build_app_list` 快照差分（读空保护、OMK adopt、gone/keep、状态文件提交）；
- `env`（探测 + 深浅色 + FRRO + seed + statusbar dp）、`icons`（桌面库 SQL + app_process 补缺 + 缓存）；
- `lcs_diff`（与 shell `kl_capture_diff` 逐字节一致）+ **preview 影子根**（见 §4）。

## 2. 本地怎么验证（WSL，全部要在仓库根目录）

```sh
# Rust 单测
wsl -e sh -c "cd '/mnt/d/Github Repositories/TS-AUTO-ADD' && ~/.cargo/bin/cargo test --manifest-path rust/Cargo.toml --release"

# 构建（x86_64）
wsl -e sh -c "cd '/mnt/d/Github Repositories/TS-AUTO-ADD' && ~/.cargo/bin/cargo build --manifest-path rust/Cargo.toml --release"

# aarch64 静态（本机没 NDK，用 musl + rust-lld；真机上可直接跑）
wsl -e sh -c "cd '/mnt/d/Github Repositories/TS-AUTO-ADD' && RUSTFLAGS='-C linker=rust-lld -C link-self-contained=yes' ~/.cargo/bin/cargo build --manifest-path rust/Cargo.toml --release --target aarch64-unknown-linux-musl"

# 对拍（用 musl 产物，和 CI 一致）
wsl -e sh rust/parity.sh rust/target/x86_64-unknown-linux-musl/release/keylens   # 或直接 sh rust/parity.sh
```

shell 测试套在 **Windows 的 Git Bash** 下逐套跑（WSL 里没有 node，静态闸门会跳过）：

```powershell
$fail=0; foreach ($t in (Get-ChildItem tests\*.sh).Name) { & "D:\Git\bin\bash.exe" "tests/$t" *> $null; if ($LASTEXITCODE -ne 0) { $fail++; Write-Host "FAIL $t" } }; "failures=$fail"
node tests/ui-shape.js; node tools/doc-consistency.mjs
```

## 3. 真机怎么验证

```sh
adb root                     # 设备是 userdebug，可用
adb shell "id"               # 应为 uid=0
# 把工作树和二进制推到临时目录（不动已安装的模块）
adb push module/. /data/adb/keylens-ab/
adb push rust/target/aarch64-unknown-linux-musl/release/keylen /data/adb/keylens-ab/bin/keylens   # 注意路径写全
adb shell "chmod 755 /data/adb/keylens-ab/bin/keylens"
adb push tests/device-ab.sh /data/adb/keylens-ab/device-ab.sh
# 只读 17 条 A/B
adb shell "cd /data/adb/keylens-ab && MODDIR=/data/adb/keylens-ab sh device-ab.sh"
# 写命令 21 条（每轮自动备份/还原 6 个后端文件，并比对写回文件 sha256）
adb shell "cd /data/adb/keylens-ab && MODDIR=/data/adb/keylens-ab sh device-ab.sh --write"
```

## 4. preview 的实现方式（重要）

`preview-<cmd>` 白名单 9 条：`teesim-save`、`teesim-save-overrides`、`teesim-profile-new`、`teesim-profile-del`、
`omk-save-injector`、`omk-save-config`、`tricky-save-patch`、`tricky-drop-patch`、`keybox-save`。

Rust 侧**没有**改 17 处写回点，而是走「影子根」（`rust/src/main.rs` 的 `preview_run`）：

1. 建临时根，复制可能被写的文件 + `module.prop` + **模块目录结构和锁/状态目录**（不复制会认错后端、误报「守护进程在写入」）；
2. 用 `KEYLENS_ROOT=<影子>` 起子进程跑同一条命令（子进程看 `KL_PREVIEW_CHILD=1` 不再递归）；
3. 父进程 `lcs_diff` 比对真实 vs 影子，输出 `preview=1` / `changed=N` / `diff=<base64>`；
4. 输出里把影子路径还原成真实路径；`keybox_sha` 用**真实文件**的 sha256（子进程看到的是新内容）。

真机验证记录：`preview-keybox-save` 的输出（含 base64 diff 全文）与 shell 侧 `cmp` **相同**。

## 5. 剩余工作（按顺序）

1. **真机对拍其余 8 条 `preview-*`**（影子根是通用的，但要一条条验）。
2. **`run_sync` 接回"优先调用二进制"**：`module/lib/backend.sh` 的 `run_sync` 里加
   `_kl_bin="${KL_BIN:-${MODDIR:-}/bin/keylens}"; if [ -x "$_kl_bin" ]; then ... "$_kl_bin" sync ...; return rc; fi`
   ——这样 `service.sh` 的后台同步不再依赖 awk。（上一次做过，随回滚一起撤了。）
3. **删 `module/backends/*.awk`**（19 份）。步骤与影响面见 `docs/AWK-REMOVAL.md`。
   注意：上次直接删导致真机 A/B 从 38/38 掉到全挂，已 `git revert`（`1838f8b`）；
   删之前必须先做完第 1、2 步，另外 `webui.sh` 的 `preview-*` 与 shell 回退路径都依赖 awk。
4. 清理无用的 shell 函数（删 awk 之后 `grep` 确认零引用再删）。
5. 推送 + 看 CI：`rust-build.yml` 里有三道新闸门（`Verify static`、`Module binary handshake`、`Golden snapshots`），**它们的首次真实运行还没发生过**。

## 6. 坑（都踩过）

- **PowerShell 写文件/内联脚本**会带 BOM/CRLF、`$` 会被解析：Rust/sh 源码一律用编辑工具写，或用 `node <文件>.cjs` 脚本改；写完 `\r` 要清掉（否则 `sh` 报 `EOF unexpected`）。
- `KL_COMMANDS` 是**带反斜杠续行的多行串**，单行 `sed` 取不到；`tests/module-bin.sh` 里有正确的 awk 提取。
- 真机上"模块目录"不能硬编码：Rust 用 `KEYLENS_MODDIR` → 「二进制在 `bin/` 下就取上一级」→ 兜底 `/data/adb/modules/keylens`。
- `doctor` 判守护进程用固定标记 `keylens ts-auto-add ts_auto`（对齐 shell 的 `KL_OUR_MARKS`），不要用模块路径。
- `sync` 的输出比 `rc`/`count` 多一行 `description=`；对拍里因 harness 把 `update_module_desc` 桩住，只比 rc/count 并单独断言描述行。
- 对拍 harness 的 fixture 必须两侧独立（写入会互相污染），路径用 `sed` 归一。
- shell 侧移除 awk 后若 `module/backends` 没有 `*.awk`，`use_backend` 会回退到 `tests/fixtures/backends`（仅仓库内有效；该逻辑在回滚里已撤，若重做需一并恢复）。

## 7. 关键文件

| 文件 | 作用 |
|---|---|
| `rust/src/main.rs` | 分派、`COMMANDS`、`USAGE`、preview 影子根 |
| `rust/src/read_cmds.rs` | 40 条命令实现 + 校验器 + `lcs_diff` + preview 基础设施 |
| `rust/src/backend.rs` | `Root`/`Paths`/后端探测/冲突 |
| `rust/src/{b64,payload,json_flat,keybox,lock,ov_valid}.rs` | 基础件 |
| `rust/parity.sh` | 129 项逐字节对拍（含漂移闸、覆盖率、EPIPE、下限 129） |
| `tests/device-ab.sh` | 真机 A/B（含写回文件指纹） |
| `tests/rust-golden.sh` + `rust/golden/` | 黄金快照（删 awk 后的回归网） |
| `tests/module-bin.sh` | 包内二进制 contract 握手 |
| `tests/static-check.sh` | 静态链接判据 |
| `docs/{RUST-REWRITE,BACKEND-INFO-SPEC,ENV-SPEC,SYNC-SPEC,OMK-SET-SPEC,TEESIM-SET-SPEC,AWK-REMOVAL}.md` | 方案、实况、各命令规格、删 awk 施工单 |

## 8. 最近提交（倒序）

```
7eeb941 preview 走影子根，真机与 shell 逐字节相同
a961f8e preview 基础设施（PREVIEW/commit_target/preview_tail），keybox-save 接入
19cb0dd lcs_diff（与 kl_capture_diff 一致，含 awk 怪癖），4 单测
1838f8b Revert "删掉模块内 19 份 awk…"
6404192 删掉模块内 19 份 awk…（已回滚，勿再直接照做）
04cd9bf 对拍：sync 比 rc/count + 单独断言描述行，下限 129
d4666bd sync 补打 description 行（真机写命令 21/21）
4f9e753 模块目录按二进制位置推导 + doctor 标记对齐（真机只读 17/17）
be3c14d 真机 A/B 比对写回文件指纹
a602731 黄金快照扩到 10 条只读命令
fb3fb2c aarch64 静态链接 CI 判据 + 本地 static-check
```
