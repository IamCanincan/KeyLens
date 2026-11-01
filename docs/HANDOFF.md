# 交接文档（KeyLens 命令层 Rust 化）

> 给接手的人/agent：这份文档是当前会话的完整状态。**先读「怎么验证」一节跑一遍闸门**，再按「剩余工作」继续。
> 代码都在 `main` 分支上，126 个提交**尚未推送**（本机无法访问 github.com）。

## 0. 仓库与环境

- 仓库：本机这个 clone（模块的 name/id 都已改 KeyLens；**目录名仍是改名前的旧名**，本文按残留闸的要求不复述它）
- 分支：`main`，HEAD 见 `git log -1`
- 未推送提交：写作时 129 个，每提交一条就 +1；以 `git rev-list --count origin/main..main` 为准
- 离线兜底：别再在这里写死文件名（每提交一次就过期）。要备份就跑
  `git bundle create "D:\Github Repositories\keylens-unpushed-<日期-时刻>.bundle" main && git bundle verify <同一个文件>`
  ——`main` 是全历史，几百 KB 到 3 MB 级别；恢复：`git fetch <bundle> main:recovered`。
  本机现有几份（`…-1500.bundle` 最新、`…-1415`、`…-1305`、`…-2026-11-01.bundle` 最早那份），都没删，
  用 `git bundle list-heads <文件>` 看各覆盖到哪个提交。
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
| shell 测试套 | **46 套，两套环境全绿**（WSL 与 Windows Git Bash 各一遍；`rust-dispatch` 的 Git Bash 恒红本轮修掉了，成因见 §6） | 见 §2 |
| 真机 A/B（只读 17 + 写 21） | **38/38 全过**（本轮重跑过） | `sh tests/device-ab.sh [--write]` |
| 真机 preview 对拍 | 三条腿逐字节相同（shell 原地 / 直调二进制 / 经界面入口），16 条断言全过 | 见 §4（脚本要先推到 `/data/adb/keylens-ab`） |
| 真机 run_sync 分支 | 14 条全过（含"拿掉锁接力必须看见自抢"的变异对照） | `sh tests/device-run-sync.sh`，见 §5.2 |
| 黄金快照 | 10 条只读命令 | `sh tests/rust-golden.sh` |
| 静态链接判据 | NEEDED=0 / 无 INTERP | `sh tests/static-check.sh` |
| 包内二进制握手 | contract == KL_COMMANDS | `sh tests/module-bin.sh` |
| 发布包内容 | `module/backends/` 只剩 `tricky.sh`；19 份 awk 参照在 `tests/fixtures/backends/`；包里没带 `bin/keylens` 时安装中止 | `ls module/backends`、`module/customize.sh` |
| 体积 | x86_64 glibc 639 KB / x86_64 静态 musl 712 KB / aarch64 musl 620 KB | `stat -c %s` |

已实现的关键设施：
- 后端探测（teesim/omk/tricky，含 disable 与冲突检测）、并发锁（证据式接管）、base64/payload、`json_flat`、keybox 三家校验；
- `omk_set` TOML 引擎、teesim 嵌套 JSON 编辑（`member_span`）、`tricky_info`/`teesim_info`/`omk_info` 摘要；
- `sync` 的 `build_app_list` 快照差分（读空保护、OMK adopt、gone/keep、状态文件提交）；
- `env`（探测 + 深浅色 + FRRO + seed + statusbar dp）、`icons`（桌面库 SQL + app_process 补缺 + 缓存）；
- `lcs_diff`（与 shell `kl_capture_diff` 逐字节一致，含 awk 的记录语义）+ **preview 影子根**（见 §4）；
- `run_sync` 优先走二进制（`sync` 这条后台链路不再依赖 awk），带 `KL_LOCK_HELD` 锁接力与"拿不到 `rc=` 就回退 shell"（见 §5.2）。

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

shell 测试套 **46 套**，两边都得跑，各有盲区：

| 环境 | 结果 | 盲区 |
|---|---|---|
| WSL | 46/46 绿 | 没有 node：`tools/name-residue-check.mjs` 那类静态子闸走 skip 分支（`tests/legacy-migrate.sh` 的「零残留」段就是其一） |
| Windows Git Bash（有 node） | 46/46 绿 | 没有 cargo/链接器：Rust 单测与对拍只能在这里之外的 WSL 跑 |

> `tests/rust-dispatch.sh` 以前在 Git Bash 恒红，是台子自己用了 `env VAR=x sh -c …`：
> 这台的 `env` 会把 `env sh 脚本` 跑成**空输出且退 0**，与被测代码无关。已改成在一个 shell 里赋值。
> 教训：`env` 在这台 Windows 上不能用来给 `sh` 传变量。

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
# 参照 awk 不在模块里了（阶段 5 起在 tests/fixtures/backends），三个真机台子都要它当 shell 参照
for f in tests/fixtures/backends/*.awk; do adb push "$f" "/data/adb/keylens-ab/backends/$(basename "$f")"; done   # 或 sh tools/deploy-webui.sh --shell
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
2. ~~`run_sync` 接回"优先调用二进制"~~ **本轮做完**，落点是这样的（下一条接着做时要知道这几条都在）：
   - `module/lib/backend.sh` 的 `run_sync` 开头先看 `${KL_BIN:-$MODDIR/bin/keylens}`：可执行、`KL_USE_RUST` 没被关掉、
     且输出里有 `rc=` 那一行，才采用二进制的结果（返回码 + `KL_COUNT`）并**跳过** `mark_module_failed` /
     `update_module_desc`（描述由二进制自己写）。其余一切情况——二进制不在、`KL_USE_RUST=0`、
     跑起来了但没给出 `rc=`（锁被占、后端冲突）——都回退原来的 shell+awk 实现，**不把环境问题报成同步失败**。
   - `KL_LOCK_HELD=1` 是锁的接力条：`cmd_sync`（write.sh）、`action.sh`、`service.sh` 的 `do_sync` 三个调用点
     都已经先 `acquire_lock`，不设这条，子进程会自己抢自己的锁（白等 6 秒后报「守护进程正在写入」）。
     Rust 侧只认 `KL_LOCK_HELD=1`（见 `read_cmds.rs` 的 `sync()`），`0` 或没设都照常自己取锁。
   - 安装期的 `customize.sh` **不持锁**，所以那条路径由二进制自己取锁、自己放 ✓。
   - 闸：`tests/run-sync-bin.sh`（分支选择三条 + 三条各自变异）与真机 `tests/device-run-sync.sh`（14 条，含锁接力变异）。
3. ~~preview 交给二进制~~ **本轮做完，顺带修掉一个发布包级的洞**：
   接管点原来排在「剥 `preview-` 前缀」之后 —— 二进制收到的是不带前缀的**写命令**，
   于是界面上点「预览」会直接真写（真机复现：`preview-omk-save-config` 把 `security_patch`
   从 `auto` 写成 `2026-10-01`，输出 `saved=1`、连 diff 都没有）。已把接管段整体移到剥前缀之前，
   并让它认识 `preview-*`：成功 → 直接 `exit 0`（信封由二进制打印，shell 再补就成两份）；
   非 0（老命令层不认识 `preview-*`、或它自己失败）→ 回落 shell 原地预览。
   装了的模块目前 `bin/` 是空的，所以这个洞还没上到真机上，但**带二进制的发布包一装就会中招** ——
   这也是 §5 剩下那条"首次真实 CI 运行"必须尽快跑的原因之一。
   闸：`tests/rust-dispatch.sh`（preview 接管/回落 6 条 + 普通命令退码透传的正对照）、
   `tests/device-preview.sh`（三条腿逐字节 + 信封恰好一份 + 三条腿都不许落盘）。
4. ~~删 `module/backends/*.awk`~~ **本轮做完（阶段 5 收尾）**：19 份 awk 用 `git mv` 移进
   `tests/fixtures/backends/`，**发布包里不再有 awk**，模块目录只剩 `tricky.sh`。
   - `lib/backend.sh` 的 `use_backend` 现在解析 `KL_PATCH_DIR`：模块目录里有 awk（老安装，或真机台子把参照推进去）→ 用它；
     否则找仓库布局的 `../tests/fixtures/backends`；两个都没有就照旧报「缺少 X.awk」。
     所有调用点都是 `${KL_PATCH%/*}` 派生的，所以运行时代码只改了这两行。
   - `customize.sh`：包里没带 `bin/keylens` 就 **abort**（没有二进制 = 没有命令层），带着就点名 `chmod 0755`。
   - 真机台子的前提：`backends/*.awk` 要在 A/B 树里，否则 shell 那半边退化成「缺少 X.awk」，
     报出来的差异看着像实现坏了（实测 device-ab 17 条里红 6 条）。三个真机台子都加了这条前置，
     `sh tools/deploy-webui.sh --shell` 会把参照一起推进 `backends/`。
   - 对拍网**没有**被拆掉：`rust/parity.sh` 175 项照旧全绿（它抽的 shell 参照还在仓库里，只是不在发布包了）。
5. ~~清理无用的 shell 函数~~ **实测没有可删的**（2026-11-01，别为了交差造工作量）：
   用脚本把 `module/**/*.sh` 里 133 个 `^[a-z_]*() {` 定义逐个数非定义、非注释的引用，
   **零 module 引用的 = 0 个**；引用最少的 18 个都是一次调用的真用户
   （`cmd_*` 被 webui.sh 的分派表调、`kl_capture_diff` 被 `commit_backend_file` 调、
   `next_backoff` 被 service.sh 的退避循环调……）。复测方法：临时写一个 `.cjs`
   按 `\b名\b` 逐行数（跳过定义行与 `#` 开头的行），要同时打印"引用次数最少的 N 个"，
   只报"0 个"不报分布就是没自证仪器。
   真正还悬着的是**另一件事**：`use_backend` 的 `KL_PATCH_DIR` 那条"仓库布局兜底"
   让 module 代码在设备上找不到参照时会往 `../tests/fixtures` 看——那是"参照只装在仓库里"的
   必然代价，不是死代码。
6. ~~推送 + 看 CI~~ **推送做了（139 个提交已上 main），CI 真跑了，而且当场抓到两处"闸门自己坏"**：
   - `Build CI` 红在静态闸：批量重指 awk 路径的脚本后缀过滤写的是 `.sh|.mjs|.js|.yml`，
     `.cjs` 不以 `.js` 结尾整类被跳过 ⇒ `tools/json-flat-set-check.cjs` 还找搬走的老路径。
     已跟指到 `tests/fixtures/backends` 并加"参照文件不在就一句话报清"的前置（原来红成 19 条各自崩）。
   - `Rust CLI` 红两道：① Contract parity 的 awk 没有"见收尾引号就 exit"，把 `KL_COMMANDS` 之后的
     整份 webui.sh（59KB 源码）当命令清单比 ⇒ 换成 `module-bin.sh`/`parity.sh` 那份带 exit 的提取器，
     外加"提取结果含 `#` 就是越界"的结构自检；② 产物选错 target（下面这条）。
   - **发布产物已从 `aarch64-linux-android` 换成 `aarch64-unknown-linux-musl`**：
     `rustc --print cfg --target aarch64-linux-android` 里**没有** `target_feature="crt-static"`，
     Android target 默认动态链 bionic ⇒ CI 那道 `NEEDED=0` 判据对它永远不成立，闸门与产物互相不认识。
     musl target 默认带 crt-static，而且**本机不用 NDK 就能造**
     （`RUSTFLAGS='-C linker=rust-lld -C link-self-contained=yes'`，见 §2）；真机全部证据
     （device-ab 38、device-preview 16、device-run-sync 14）跑的正是这份产物。
     已本机真出一只包：705 KB / 34 条目，`--check` 全绿，包里 `bin/keylens` 的 sha256
     与手机上那份逐字节相同（`c3d6f41dcd5a7c03…`）。**上一版文档里"要配 NDK / 只能从 CI artifact 取"那句作废。**

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
- **`_x=$(run_sync …)` 会吞掉 `KL_COUNT`**：run_sync 是在子 shell 里更新的，主 shell 读到的一直是初值 0。真机台子第一次就这么写的，于是"两条分支的 count 相同"变成 `0 == 0` 的假绿（改成就地把输出重定向到文件才有读数）。凡是"函数返回值 + 副作用变量"的探针，都别用命令替换去接。
- **锁接管判据看的是 cmdline，不是目录**：二进制判定持有者死活时比的是模块标记（默认取 module.prop 所在目录名）是否出现在 `/proc/<pid>/cmdline` 里。测试探针放在 `/data/local/tmp/` 下，cmdline 对不上标记，二进制会把"自己人"当陌生持有者直接接管——正对照当场哑掉。探针脚本的文件名要带模块目录名（生产里持有锁的本来就是 `/data/adb/modules/keylens/webui.sh` 这类路径）。
- **`adb push` 批量推多个文件时，别拿"命令没报错"当"文件已更新"**：这一轮一批推送里有 `backend.sh` 没落地、退出码却是 0。推到真机的每一步都要在远端 `grep -c` 一遍新代码里才有的字面量（本轮是 `KL_USE_RUST`），只看 size/mtime 不够。
- **接管段的顺序就是功能正确性**：`webui.sh` 里「剥 `preview-` 前缀」和「二进制接管」的先后，决定预览是预览还是真写（本轮 §5.3 修的就是这个）。动这两段之前先跑 `sh tests/rust-dispatch.sh`，它的 6 条 preview 判据就是钉这个顺序的。
- **影子根的落脚点不能只认 `temp_dir()`**：Android 上没有 `/tmp`。只认它时 TMPDIR 一坏，影子根建不出来、子进程什么都读不到，父进程照样打 `changed=0`，界面把"没有差异"当成无需确认**直接真写**。现在按 `TMPDIR → /data/local/tmp → temp_dir` 找落脚点，全建不出来退 2 交给 shell（`rust/parity.sh` 与 `tests/device-preview.sh` 各钉一条）。复现这种"建不出来"要把 `TMPDIR` 的父路径做成一个**普通文件**——指到一个不存在的目录会被 `create_dir_all` 顺手建出来，测不出失败。
- **台子调了没定义的函数，mksh 只报一句 command not found、不置 fail**：`tests/device-preview.sh` 上一版就这么在 5 条断言没跑的情况下打了「全部通过」。现在它自带 `chk` 与断言计数，条数低于下限直接红。写台子时"末尾那句结论"必须来自计数器，不能来自"没看见 ✗"。
- **对拍会测到上一版产物**：改完 Rust 忘了 `cargo build` 就 `sh rust/parity.sh`，新断言红得像实现写错了。`rust/parity.sh` 现在先做 `find rust/src rust/Cargo.toml -newer "$B"`，二进制不比源码新就拒绝开跑。

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
| `tests/run-sync-bin.sh` | `run_sync` 二进制分支的三条判据 + 三条变异（CI 跑，桩掉 awk 实现） |
| `tests/device-run-sync.sh` | 真机验锁接力：持锁不自抢、不持锁自取自放、两条分支结果一致、拿掉接力条的变异 |
| `tests/rust-golden.sh` + `rust/golden/` | 黄金快照（删 awk 后的回归网） |
| `tests/module-bin.sh` | 包内二进制 contract 握手 |
| `tests/static-check.sh` | 静态链接判据 |
| `docs/{RUST-REWRITE,BACKEND-INFO-SPEC,ENV-SPEC,SYNC-SPEC,OMK-SET-SPEC,TEESIM-SET-SPEC,AWK-REMOVAL}.md` | 方案、实况、各命令规格、删 awk 施工单 |

## 8. 最近提交（倒序）

```
c5eb978 修发布链自洽：build-zip 必须打进 bin/keylens，否则拒绝出包
4c39bb8 阶段 5.4：awk 参照实现移出发布包，命令层实现只剩 bin/keylens
21c04e6 文档：AWK-REMOVAL 第 1 步实测作废
199ba6d 文档：HANDOFF 记下本轮三个提交与新的离线 bundle
8c01f42 阶段 5.3：预览交给二进制，并修掉"点预览却真写"这个发布包级的洞
6eb58c5 阶段 5.2：run_sync 优先走二进制，后台同步链路从此不吃 awk；补锁接力 KL_LOCK_HELD
4f6b8f2 阶段 5.1：preview-* 全九条对拍落地，影子根修出三处口径
f3c61f3 文档：交接说明（状态/验证方式/剩余工作/踩过的坑），供其他 agent 接手
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
