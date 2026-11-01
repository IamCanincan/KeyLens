# 交接文档（KeyLens 命令层 Rust 化）

> 给接手的人/agent：这份文档是当前会话的完整状态。**先读「怎么验证」一节跑一遍闸门**，再按「剩余工作」继续。
> 代码都在 `main` 分支上，126 个提交**尚未推送**（本机无法访问 github.com）。

## 0. 仓库与环境

- 仓库：本机这个 clone（模块的 name/id 都已改 KeyLens；**目录名仍是改名前的旧名**，本文按残留闸的要求不复述它）
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
| Rust 单测 | 71 项 | 见 §2 |
| shell↔Rust 逐字节对拍 | 173 项 chk（含 preview-* 11 例 ×4 条断言） | `sh rust/parity.sh` |
| shell 测试套 | 44 套：WSL 0 失败；Git Bash 1 红（`rust-dispatch`，环境性，干净工作树同红） | 见 §2 |
| 真机 A/B（只读 17 + 写 21） | **38/38 全过**（本轮重跑过） | `sh tests/device-ab.sh [--write]` |
| 真机 preview 对拍 | 11 次调用**逐字节相同**；4 次真有差异，7 次只对齐错误路径 | 见 §4（脚本要先推到 `/data/adb/keylens-ab`） |
| 黄金快照 | 10 条只读命令 | `sh tests/rust-golden.sh` |
| 静态链接判据 | NEEDED=0 / 无 INTERP | `sh tests/static-check.sh` |
| 包内二进制握手 | contract == KL_COMMANDS | `sh tests/module-bin.sh` |
| 体积 | x86_64 glibc 637 KB / x86_64 静态 musl 713 KB / aarch64 musl 620 KB | `stat -c %s` |

已实现的关键设施：
- 后端探测（teesim/omk/tricky，含 disable 与冲突检测）、并发锁（证据式接管）、base64/payload、`json_flat`、keybox 三家校验；
- `omk_set` TOML 引擎、teesim 嵌套 JSON 编辑（`member_span`）、`tricky_info`/`teesim_info`/`omk_info` 摘要；
- `sync` 的 `build_app_list` 快照差分（读空保护、OMK adopt、gone/keep、状态文件提交）；
- `env`（探测 + 深浅色 + FRRO + seed + statusbar dp）、`icons`（桌面库 SQL + app_process 补缺 + 缓存）；
- `lcs_diff`（与 shell `kl_capture_diff` 逐字节一致）+ **preview 影子根**（见 §4）。

## 2. 本地怎么验证

都在**仓库根目录**跑。WSL 下的路径是 `/mnt/<盘>/…/<clone 目录>`，本机 clone 目录名沿用改名前的旧名，本文不复述（改名残留闸会响，见 §6）。

```sh
# 以下都在 WSL 里（Windows 侧没有可用链接器）
~/.cargo/bin/cargo test  --manifest-path rust/Cargo.toml --release
~/.cargo/bin/cargo build --manifest-path rust/Cargo.toml --release
# aarch64 静态（本机没 NDK，用 musl + rust-lld；真机上可直接跑）
RUSTFLAGS='-C linker=rust-lld -C link-self-contained=yes' ~/.cargo/bin/cargo build --manifest-path rust/Cargo.toml --release --target aarch64-unknown-linux-musl
# 对拍（173 项 chk；CI 用 musl 产物，本机直接 sh rust/parity.sh 走 glibc 产物）
sh rust/parity.sh rust/target/x86_64-unknown-linux-musl/release/keylens
```

shell 测试套 **43 套**，两边都得跑，各有盲区：

| 环境 | 结果 | 盲区 |
|---|---|---|
| WSL | 43/43 绿 | 没有 node：`tools/name-residue-check.mjs` 那类静态子闸走 skip 分支（`tests/legacy-migrate.sh` 的「零残留」段就是其一） |
| Windows Git Bash（有 node） | `tests/rust-dispatch.sh` 恒红（`run` 取到空串；HEAD 干净工作树里同样红，与代码无关） | 这一条要按 WSL 的结果读 |

Git Bash 侧逐套跑（PowerShell）与两份 node 闸：

```powershell
$fail=0; foreach ($t in (Get-ChildItem tests\*.sh).Name) { & "D:\Git\bin\bash.exe" "tests/$t" *> $null; if ($LASTEXITCODE -ne 0) { $fail++; Write-Host "FAIL $t" } }; "failures=$fail"
node tests/ui-shape.js; node tools/doc-consistency.mjs
```

## 3. 真机怎么验证

```sh
adb root                     # 设备是 userdebug，可用
adb shell "id"               # 应为 uid=0
# 在 Git Bash 里先 export MSYS2_ARG_CONV_EXCL='*'，否则 adb 的远端路径会被 MSYS 改写
# 把工作树和二进制推到临时目录（不动已安装的模块）
adb push module/. /data/adb/keylens-ab/
adb push rust/target/aarch64-unknown-linux-musl/release/keylens /data/adb/keylens-ab/bin/keylens   # 注意路径写全
adb shell "chmod 755 /data/adb/keylens-ab/bin/keylens"
adb push tests/device-ab.sh /data/adb/keylens-ab/device-ab.sh
# 只读 17 条 A/B
adb shell "cd /data/adb/keylens-ab && MODDIR=/data/adb/keylens-ab sh device-ab.sh"
# 写命令 21 条（每轮自动备份/还原 6 个后端文件，并比对写回文件 sha256）
adb shell "cd /data/adb/keylens-ab && MODDIR=/data/adb/keylens-ab sh device-ab.sh --write"
# preview-* 逐字节 A/B（跑完自己核对 7 个后端文件的 sha256 没变；见 §4 的覆盖口径）
adb push tests/device-preview.sh /data/adb/keylens-ab/device-preview.sh
adb shell "cd /data/adb/keylens-ab && MODDIR=/data/adb/keylens-ab sh device-preview.sh"
```

## 4. preview 的实现方式（重要）

`preview-<cmd>` 白名单 9 条：`teesim-save`、`teesim-save-overrides`、`teesim-profile-new`、`teesim-profile-del`、
`omk-save-injector`、`omk-save-config`、`tricky-save-patch`、`tricky-drop-patch`、`keybox-save`。

Rust 侧**没有**改 17 处写回点，而是走「影子根」（`rust/src/main.rs` 的 `preview_run`）：

1. 建临时根，复制可能被写的文件 + `module.prop` + **模块目录结构和锁/状态目录**（不复制会认错后端、误报「守护进程在写入」）；
2. 用 `KEYLENS_ROOT=<影子>` 起子进程跑同一条命令（子进程看 `KL_PREVIEW_CHILD=1` 不再递归）；
3. 父进程 `lcs_diff` 比对真实 vs 影子，输出 `preview=1` / `changed=N` / `diff=<base64>`；
4. 输出里把影子路径还原成真实路径；`keybox_sha` 用**真实文件**的 sha256（子进程看到的是新内容）。

影子根的三个口径问题（本轮对拍抓出来的，都已修）：
- **`lcs_diff` 的切行**：awk 按记录读文件，尾换行不算一行；原来按 `split('\n')` 切会给旧文多造一条空记录，
  预览里凭空多一行 `- `（`changed` 多 1）。改成 `lines()`，单测 `trailing_newline_is_not_a_record` 钉住。
- **`keybox_sha` 的还原**：父进程原来拿「抹掉影子前缀之后的路径」去 `sha256sum`。真机上 `KEYLENS_ROOT` 就是 `/`，
  那句话碰巧对；夹具根下它指向一个不存在的路径，`sha256sum` 静默失败 → 把影子里**新内容**的哈希当成真实哈希打出去。
  现在按 `KEYLENS_ROOT` 重新拼真实路径，真实文件不存在时（新建 keybox）与 shell 一样报空串。
- **子进程不许谎称已副作用**：`omk_save_config` 的 `restart`/`reboot` 臂原来无论如何都写 `restart.keymint`
  并打 `apply_note=已请求重启 keymint`。影子根里那个文件随影子一起删，等于没请求，话却是说给用户听的真话。
  现在子进程（`preview_child()`）只报 `apply_scope`、不打这句 note；shell 侧同步改（见下）。

**shell 侧顺带修的一处界面谎报**：`cmd_omk_save_config` 整块生效代价判定原来留在 `KL_PREVIEW != 1` 的闸门后，
于是预览把一次「四个补丁字段整组热生效」（真写时报 `hot`）报成 `apply_scope=restart`，界面据此提示要重启 keymint。
代价是判据不是副作用，现在预览照算；留在闸门后的只剩重启请求与日志条目（「还没真写，不能留假条目」这条要求不变）。

验证记录（两条台子，覆盖不同）：
- 夹具根：`sh rust/parity.sh` 里 preview-* 11 例 ×4 断言（逐字节 / 两侧夹具不落盘 / `changed>0` 正对照），
  含 `omk-save-config` 的 hot、restart、reboot 三条臂。变异验证：把台子里的 `KL_PREVIEW=1` 改成 0，
  22 条 chk 当场红（其中 11 条就是「夹具没被落盘」）。
- 真机：`adb shell "cd /data/adb/keylens-ab && MODDIR=/data/adb/keylens-ab sh device-preview.sh"` → 11 次调用逐字节相同，
  其中 `preview-omk-save-config`（hot 臂 `changed=4` / restart 臂 `changed=2`）、`preview-omk-save-injector`（`changed=2`）、
  `preview-keybox-save`（`changed=92`，`keybox_sha` 与真实文件 `sha256sum` 逐位对上）真有差异；
  其余 7 次是 teesim/tricky 那六条——**这台机只装了 OhMyKeymint**，两边都只走到「当前后端不是 X」的错误路径，
  差异覆盖由夹具根那半边负责（补装另两家才能在这里验，不要为了好看往 `/data/adb/` 里塞假目录：`detect_backend` 会当场改口）。
  keybox 一条的 diff 全文含设备真实密钥材料，台子默认只比全文、打印时折掉 `diff=` 行。

## 5. 剩余工作（按顺序）

1. ~~真机对拍其余 `preview-*`~~ **本轮做完**（夹具根 11 例 ×4 断言 + 真机 11 次调用逐字节相同，见 §4；顺带修出三处口径问题）。
2. **`run_sync` 接回"优先调用二进制"**：`module/lib/backend.sh` 的 `run_sync` 里加
   `_kl_bin="${KL_BIN:-${MODDIR:-}/bin/keylens}"; if [ -x "$_kl_bin" ]; then ... "$_kl_bin" sync ...; return rc; fi`
   ——这样 `service.sh` 的后台同步不再依赖 awk。（上一次做过，随回滚一起撤了。）
3. **preview 交给二进制**：`webui.sh` 的 rust-dispatch 守卫现在明确**不接管** `preview-*`（`[ "${CMD#preview-}" = "$CMD" ]`），
   而 shell 侧算差异靠 `kl_capture_diff` → `AWK_CMD`。删 awk 之前必须先把这条守卫放开，
   否则九条预览一起变成「没有差异」。（放开时 `tests/rust-dispatch.sh` 的「预览命令不接管」那条要跟着改判据，别删。）
4. **删 `module/backends/*.awk`**（19 份）。步骤与影响面见 `docs/AWK-REMOVAL.md`。
   注意：上次直接删导致真机 A/B 从 38/38 掉到全挂，已 `git revert`（`1838f8b`）；
   删之前必须先做完第 2、3 步，另外 shell 回退路径也依赖 awk。
5. 清理无用的 shell 函数（删 awk 之后 `grep` 确认零引用再删）。
6. 推送 + 看 CI：`rust-build.yml` 里有三道新闸门（`Verify static`、`Module binary handshake`、`Golden snapshots`），**它们的首次真实运行还没发生过**。

## 6. 坑（都踩过）

- **PowerShell 写文件/内联脚本**会带 BOM/CRLF、`$` 会被解析：Rust/sh 源码一律用编辑工具写，或用 `node <文件>.cjs` 脚本改；写完 `\r` 要清掉（否则 `sh` 报 `EOF unexpected`）。
- **从源码抽函数当台子时，sed 的结束锚要写 `^}$` 而不是 `^}`**：`kl_capture_diff` 里那句 awk 程序以 `}' "$1" "$2" 2>/dev/null` 收尾，`^}` 会在那一行截断，抽出来的函数少个尾巴，症状是 shell 侧整条命令报 `Syntax error: end of file unexpected (expecting "}")`（对拍里表现为"输出不一致"，很容易被误读成实现有问题）。
- **文档自己会撞改名残留闸**：上一轮的 `docs/HANDOFF.md` 把仓库绝对路径与三个守护进程标记原样写进去，`tools/name-residue-check.mjs` 当场报 6 处 → `tests/legacy-migrate.sh` 红。这条闸只在**有 node 的环境**里才真的响（WSL 没 node，走 skip 分支），所以两套环境都得跑。
- **`tests/rust-dispatch.sh` 在 Windows Git Bash 下恒红**（`run` 取到空串），WSL 下全绿；HEAD 干净工作树里同样红，别把它当成新改动引入的失败。
- `KL_COMMANDS` 是**带反斜杠续行的多行串**，单行 `sed` 取不到；`tests/module-bin.sh` 里有正确的 awk 提取。
- 真机上"模块目录"不能硬编码：Rust 用 `KEYLENS_MODDIR` → 「二进制在 `bin/` 下就取上一级」→ 兜底 `/data/adb/modules/keylens`。
- `doctor` 判守护进程用固定标记表（照 shell 的 `KL_OUR_MARKS`：新名 + 两个改名前的旧名，共三个；旧名不在这里复述），不要用模块路径。
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
| `tests/device-preview.sh` | 真机 preview-* 逐字节 A/B（含「预览不许落盘」的后端文件指纹与覆盖口径） |
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
