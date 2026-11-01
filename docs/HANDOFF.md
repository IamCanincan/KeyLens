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
- 网络现状：**直连 github.com 会 DNS 解析失败，走本机代理才行**（`git` 已配
  `http.proxy/https.proxy = http://127.0.0.1:7890`，所以 `git push` / `git fetch` 直接可用）。
  两个例外：`curl` 调 GitHub API 要显式 `-x http://127.0.0.1:7890`（匿名 API 限额 60/小时，
  读日志还得要 token；配额打光时改读 HTML 页面更快）；`gh` 装好了但没登录，且它不读
  `git config` 的代理，要显式给 `HTTPS_PROXY`。`static.rust-lang.org`（rustup target）本来就可达。
- 本地工具链：Windows + WSL(Ubuntu)。**Rust 构建/测试都在 WSL 里跑**（`~/.cargo/bin/cargo`），Windows 侧没有可用链接器。
- 真机：`adb devices` 里有 `QV7709NLJ7`（arm64-v8a，`adb root` 可拿到 root，build 是 userdebug）。
  模块已装：`/data/adb/modules/keylens`（v3.0.1，OMK 后端）—— **发布的 v3.0.2 见 §3.11**，机上要变成 v3.0.2 得刷一次包。测试用的临时副本 `/data/adb/keylens-ab`
  **已按主人要求删掉**（2026-11-01 20:3x），要跑真机台子先照 §3 那一段重建（先 mkdir，再一条 deploy + 六条 push）。

## 1. 现在完成到哪

**命令层 40/40 全部用 Rust 实现**（`rust/src/*.rs`，`read_cmds.rs` 约 5.4k 行），命令契约（40 条、同序、同 kv/tsv 输出）保持不变。

| 证据 | 数值 | 怎么跑 |
|---|---|---|
| Rust 单测 | 72 项 | 见 §2 |
| shell↔Rust 逐字节对拍 | **205 项 chk**（含 preview-* 11 例 ×4 条断言、env 探针缓存一节 24 条） | `sh rust/parity.sh` |
| shell 测试套 | **50 套，两套环境全绿**（WSL 与 Windows Git Bash 各一遍；`rust-dispatch` 的 Git Bash 恒红已修，成因见 §6） | 见 §2 |
| 真机 A/B（只读 17 + 写 21） | **38/38 全过**（本轮重跑过） | `sh tests/device-ab.sh [--write]` |
| 真机 preview 对拍 | 三条腿逐字节相同（shell 原地 / 直调二进制 / 经界面入口），16 条断言全过 | 见 §4（脚本要先推到 `/data/adb/keylens-ab`） |
| 真机 run_sync 分支 | 14 条全过（含"拿掉锁接力必须看见自抢"的变异对照） | `sh tests/device-run-sync.sh`，见 §5.2 |
| 真机 env 探针缓存 | **28 条全过**：冷=热、两边互读、热跑不起 getprop/dumpsys/wm/id、FRRO 的 mtime 与路径各一条变异 | `sh tests/device-env-cache.sh`，见 §5.9 |
| 真机 OMK 写路径（`omk-save-config`） | **20 条全过**：夹具根上真写 + 二次保存不落盘 + 预览不落盘 + 把参照校验改坏的变异 | `sh tests/device-omk-write.sh`，见 §5.11 |
| 真机 teesim/tricky 六条（写 + 预览） | **83 条全过**：夹具与 harness 抽自 `parity.sh`，参照实现在设备的 toybox awk + mksh 下跑；带"改坏 shell 侧一处键名"的变异 | `sh tests/device-six.sh`，见 §5.10 |
| 装机核对（重启前） | **28 条全过**：新树无 awk、旧树 shell vs 新树二进制 17 条逐字节、预览不落盘 | 见 §3.5 |
| 黄金快照 | 10 条只读命令 | `sh tests/rust-golden.sh` |
| 静态链接判据 | NEEDED=0 / 无 INTERP | `sh tests/static-check.sh` |
| 包内二进制握手 | contract == KL_COMMANDS | `sh tests/module-bin.sh` |
| 发布包内容 | `module/backends/` 只剩 `tricky.sh`；19 份 awk 参照在 `tests/fixtures/backends/`；包里没带 `bin/keylens` 时安装中止 | `ls module/backends`、`module/customize.sh` |
| 体积 | x86_64 glibc 639 KB / x86_64 静态 musl 712 KB / aarch64 musl 629 KB | `stat -c %s` |

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
# 对拍（205 项 chk；CI 用 musl 产物，本机直接 sh rust/parity.sh 走 glibc 产物）
sh rust/parity.sh rust/target/x86_64-unknown-linux-musl/release/keylens
```

shell 测试套 **50 套**，两边都得跑，各有盲区：

| 环境 | 结果 | 盲区 |
|---|---|---|
| WSL | 50/50 绿 | 没有 node：`tools/name-residue-check.mjs` 那类静态子闸走 skip 分支（`tests/legacy-migrate.sh` 的「零残留」段就是其一） |
| Windows Git Bash（有 node） | 50/50 绿 | 没有 cargo/链接器：Rust 单测与对拍只能在这里之外的 WSL 跑；`rust/target` 里的 Linux 二进制在这儿 exec 不了，依赖它的套子会自己 skip |

> `tests/rust-dispatch.sh` 以前在 Git Bash 恒红，是台子自己用了 `env VAR=x sh -c …`：
> 这台的 `env` 会把 `env sh 脚本` 跑成**空输出且退 0**，与被测代码无关。已改成在一个 shell 里赋值。
> 教训：`env` 在这台 Windows 上不能用来给 `sh` 传变量。

Git Bash 侧逐套跑（PowerShell）与 node 闸（CI 里一共 11 条，清单见 `.github/workflows/build_ci.yml`）：

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
# 目录不存在就先建：`adb push` 会自己建父目录，但 `tools/deploy-webui.sh` 会拒绝推（它有 [ -d ] 前置）
adb shell "mkdir -p /data/adb/keylens-ab"
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
# run_sync 的二进制分支与锁接力
adb push tests/device-run-sync.sh /data/adb/keylens-ab/device-run-sync.sh
adb shell "cd /data/adb/keylens-ab && MODDIR=/data/adb/keylens-ab sh device-run-sync.sh"
# env 探针缓存（FRRO 那一段夹具机测不到，只有真机算数；见 §5.9）
adb push tests/device-env-cache.sh /data/adb/keylens-ab/device-env-cache.sh
adb shell "cd /data/adb/keylens-ab && MODDIR=/data/adb/keylens-ab sh device-env-cache.sh"
# teesim/tricky 那六条：夹具与 harness 从 parity.sh 抽，所以要把它一起推上去（见 §5.10）
adb push rust/parity.sh /data/adb/keylens-ab/parity.sh
adb push tests/device-six.sh /data/adb/keylens-ab/device-six.sh
adb shell "cd /data/adb/keylens-ab && MODDIR=/data/adb/keylens-ab sh device-six.sh"
# OMK 的写路径（真写，夹具根，不碰正在用的配置；见 §5.11）
adb push tests/device-omk-write.sh /data/adb/keylens-ab/device-omk-write.sh
adb shell "cd /data/adb/keylens-ab && MODDIR=/data/adb/keylens-ab AWKSRC=\$PWD/backends sh device-omk-write.sh"
```

## 3.5 装包后、重启前该跑的那一条（真做过一次）

```sh
node tools/build-zip.mjs && node tools/build-zip.mjs --check      # 本机就能出包（musl 产物，不用 NDK）
adb push KeyLens-v3.0.2.zip /data/local/tmp/
adb shell "/data/adb/ksud module install /data/local/tmp/KeyLens-v3.0.2.zip"
# KernelSU 把新包解到 /data/adb/modules_update/keylens，重启才落地 —— 下面这条就是趁这个窗口跑的：
adb push tests/device-install-check.sh /data/local/tmp/
adb shell "sh /data/local/tmp/device-install-check.sh"           # 28 条断言
```

`tests/device-install-check.sh` 干的事：拿**正在跑的旧树（shell+awk）**当现场参照，逐条比对新装树（只有二进制）；
核新包里确实没有 awk、安装期同步确实走的是二进制（没有 awk 可退，出了 132 就是证据）；
以及在真实生产路径上验「预览只出一份信封、后端文件一字不变」——就是 5.3 那个发布级洞的回归。
它只在"装完包、重启前"这一段时间里有意义，所以三条前置都做成 skip（CI 上不会假红）。

### 3.6 重启之后复核过（2026-11-01 17:11，v3.0.1 新树已在生产模块目录里跑）

- 落地：`/data/adb/modules/keylens` 里 awk **0 份**、`bin/keylens` 635672 字节且 sha256 与验过那份同（`f382d17e…`）、
  `modules_update` 与 `update` 标记都没了、无 `disable`。
- 开机日志一条不缺：探测 → `监听方式：inotifyd` → 等 12 秒 → 首次同步 →
  `列表内容一致，本次未落盘` → 之后 inotify 三轮全按指纹跳过。**没有 awk 还能报"一致"**，
  就是后台同步在用二进制的现场证据。
- `doctor` 11 项：守护进程 ok（1 个进程）、并发锁 ok（空闲）、keybox ok（结构通过）、
  名单 ok（已装 129 / 名单 132）、无 bad 无 warn。
- `action.sh`（手动入口）跑一次：`injector.toml` 指纹跑前跑后相同 —— 幂等，没改动名单；
  这条同时是`锁接力`在现场的测试（它先 acquire_lock 再 run_sync）。
- `preview-omk-save-config` 在生产树跑：信封恰好一份、`config.toml` 一字未变 —— 5.3 那个洞
  在装完的模块上确认关闭。
- 回滚件都在：设备上 `/data/adb/keylens-install-bak`（旧树 4.8 MB / 172 文件 / 19 份 awk）、
  本机 `KeyLens-v3.0.1.zip.bak-2026-11-01`。（**这一条记录的是当时状态**，三处都已在 §3.8 清掉。）

### 3.7 热替换二进制复核过（2026-11-01 18:46，env 探针缓存那一版）

命令层这一版只动 `bin/keylens`（`webui.sh`、`lib/*.sh`、`service.sh`、`action.sh`、
`post-fs-data.sh`、`uninstall.sh` 生产设备上与 HEAD 逐个 sha256 相同；`customize.sh` 装完不在模块目录里，
`module.prop` 的 `description=` 本来就被每次同步重写），所以**不重装、直接换二进制**：

- 生产 `/data/adb/modules/keylens/bin/keylens` → 644176 字节、sha256 `d03ef5ae…`（19:57 为修 `module.prop` 权限漂移又换过一次：644648 字节、`c9f4049d…`），
  与仓库里 `rust/target/aarch64-unknown-linux-musl/release/keylens` 逐字节相同；
  被换下的那份留在 `/data/local/tmp/keylens.prodbak`（636712 字节），要回滚就是 `cp -a` 回去 + `chmod 755`。
  （那份 .prodbak 也已删，见 §3.8 —— 现在回滚 = 从 git 重新交叉编译，本机 6 秒。）
- 生产实测（同机交替、各 5 次取最快）：经界面入口 `env` **冷 204ms / 热 70ms**（上一轮同机 334ms）；
  直调二进制热跑 69ms，壳层地板 `sh -c true` 23ms ⇒ 剩下的是"每次现取"那两条（`dumpsys uimode` + `settings get`）。
- `/data/adb/keylens.env.cache` 由新二进制重写：19 行、`-rw-------`、首行
  `v1<TAB>v1|/data/adb/modules/keylens|v3.0.1|1230768000`（模块目录与版本、build.prop mtime 都在键里）。
  旧文件那行的模块目录是 `/data/adb/keylens-ab` —— 键不同 ⇒ A/B 台子与生产各用各的缓存，不会互喂。
- `env` 冷跑与热跑逐字节相同；`status`/`doctor` 照旧（11 项无 bad 无 warn）；
  `config.toml` 与 `injector.toml` 的 sha256 跑前跑后相同（env 是只读命令）。
- 发布包重打：`KeyLens-v3.0.1.zip` 711.2 KB / 34 条目（比上一版 +5 KB，就是二进制长了 7.5 KB 再扣掉压缩）。
- **已推上去（19:02）**：`036778b..2aedde5` 共 8 个提交进 `main`。代理一开就通，
  此前 `curl -m 8` 走代理与直连都是 000（超时）—— 网络这一关的判据用 `curl -x …/meta` 的 http_code，
  别拿"代理软件开着"当"端口在听"（18:53 那次 `git push` 明确报 `connect to 127.0.0.1 port 7890 … Connection refused`）。
- **CI 第一次跑到这两条新闸**：`Build CI Module` **Run 76** 与 `Rust CLI` **Run 6** 都落在 `2aedde5` 上、
  全绿（一次推 8 个提交只各起一轮，GitHub 按最新提交合并触发）。
  `rust/parity.sh` 末尾那条 `oks < 205` 的下限闸就是"新节真的跑了"的证据：作业绿 ⇒ CI 上至少数到 205 项 chk。

### 3.8 回滚件已清空（2026-11-01 20:3x，主人点头删的）

| 删掉的东西 | 原本是什么 | 现在靠什么 |
|---|---|---|
| 设备 `/data/adb/keylens-install-bak`（4.7 MB，172 文件 / 19 份 awk） | 17:11 刷入前的旧模块树，唯一含 awk 的现场参照 | awk 参照在仓库 `tests/fixtures/backends/`（阶段 5.4 移进去的，没删）；旧实现整棵树在 git 里 |
| 设备 `/data/adb/keylens-ab`（1.9 MB） | 真机台子的 A/B 树（含推上去的 5 个 `device-*.sh` 与 `parity.sh`） | §3 那一整段就是重建流程：先 `mkdir -p`（deploy 会拒绝往不存在的目录推），再 `sh tools/deploy-webui.sh --shell`（把 MODDIR 指过去）+ 六条 `adb push` |
| 设备 `/data/local/tmp/keylens.prodbak`（624 KB） | 18:46 换下来的上一版二进制 | `RUSTFLAGS='-C linker=rust-lld -C link-self-contained=yes' cargo build --release --target aarch64-unknown-linux-musl --manifest-path rust/Cargo.toml`（本机 6 秒，不用 NDK） |
| 本机 `KeyLens-v3.0.1.zip.bak-2026-11-01` | 13:56 那次打包的 zip | `node tools/build-zip.mjs` 重打；现在的包是 711.6 KB / 34 条目（内含 `c9f4049d…` 的二进制） |
| 本机 `../keylens-unpushed-*.bundle` 共 8 只 | 代理不通时的离线兜底 | 提交已全部推到 `origin/main`，bundle 失去意义 |

**代价要说清**：设备上现在没有 A/B 树，也没有参照 awk ⇒ 五个真机台子（`device-ab` / `device-preview` /
`device-run-sync` / `device-env-cache` / `device-six`）**跑之前都要先照 §3 重建**，否则它们各自的前置检查会
报「设备上找不到参照 awk」而拒绝开跑（这是设计，不是坏了）。已装的 `/data/adb/modules/keylens` 一个文件没动，
删完当场复核：`bin/keylens` 仍是 `c9f4049d…`、`status` 正常、`doctor` 11 项 bad=0 warn=0。

### 3.9 重启后复核（2026-11-01 22:19，`c9f4049d` 这版二进制第一次经历开机）

17:11 那次开机跑的是 `f382d17e`；之后 `webui.sh`（接管点前移）与 `bin/keylens`（三版）都换过，
都没开过机。22:19 重启后逐项核对：

- **开机时间线**（`/data/adb/keylens.log`）：22:18:58 后端探测 → `监听方式：inotifyd` →
  22:19:10 `开机完成（等了 12 秒），执行首次同步` + `开机后属性复核完成` + `守护进程就绪` →
  22:19:12 起每 ~32 秒一条 `源数据与上次一致（指纹 3072251154），跳过同步`。
- ⚠ **开机那趟同步常常是空转**：指纹文件 `/data/adb/omk/.kl_fingerprint` **跨重启保留**，
  `do_sync` 一比对相同就直接返回（日志就长成上面那样），所以"重启后看到同步日志"**不等于**
  同步真的跑过。要验同步路径，得把那个指纹文件挪走逼一次真同步。
- **逼出来的那一次确实走二进制**：把指纹挪开、同时给 `bin/keylens` 套一层"记一行再 exec 回真身"的壳，
  22:25:58 日志出现 `🔄 开始应用列表同步` → `列表内容一致，本次未落盘`，壳上恰好记到一条
  `22:25:58 sync`。模块里 awk 份数是 **0**，壳层那条路本来也跑不了 —— 这条是直接证据不是推断。
  跑完立刻还原：`bin/keylens` 的 sha 回到 `c9f4049d…`、指纹回到原来的值。
- 守护进程：pid 5611（`busybox sh /data/adb/modules/keylens/service.sh`）；doctor 11 项 bad=0 warn=0 skip=1；
  无 `disable`/`remove`；`/data/adb/modules_update/` 只剩一个空目录（不影响任何东西）。
- 属性伪装：`props` 17/17 全 `ok`，与日志里 22:19:10 的「开机后属性复核完成」对得上。
- env：冷 **344ms** / 热 **91ms**，冷=热逐字节一致；缓存按生产模块目录的键重建
  （`v1|/data/adb/modules/keylens|v3.0.1|1230768000`，19 行、600）。
- `module.prop` 仍是 `-rw-r--r--`（这一趟没有重写描述：列表没变，`do_sync` 没走到 `set_module_desc`；
  这版二进制下的"改写描述"在 19:54 / 19:57 两次手动 sync 上验过）。

### 3.10 DuckDetector 复核（2026-11-01 22:52 → 22:55，两份报告对比）

靶子：`com.eltavine.duckdetector`（nightly 2026.11.01，源码在 `D:\下载\Duck-Detector-Refactoring`）。

**唯一由 KeyLens 引起、也由 KeyLens 修掉的：`ro.boot.vbmeta.digest` 是空的。**
两份报告里 Bootloader（Danger）与 TEE（Danger）引的是同一句判据：
“Attested verifiedBootHash was present, but `ro.boot.vbmeta.digest` was empty.”
用模块自带的功能补上（值取自报告里 attestation 的 verifiedBootHash，不是编的）：

```sh
sh /data/adb/modules/keylens/webui.sh props-boot-hash 0561fff01a287ce84e1591d31ae1ec17524c9fc28846710bfb2ca1e0b4d128e1
```

结果（同一台机、同一版 App，相隔 3 分钟两次扫描）：

| | 修之前 | 修之后 |
|---|---|---|
| Overall | Danger | Danger |
| Danger 数 | **4**（Bootloader / Mount / SELinux / TEE） | **2**（Mount / SELinux） |
| Bootloader | Danger，"Boot consistency: Anomaly" | **整张卡清空** |
| TEE | Danger，Score 32，"Boot: Mismatch" | Warning，Score **4**，"Boot: **Matched**"，`0 policy hard • 0 policy review` |

TEE 剩下的那条是 `Grant isolated-domain: ISOLATED_PRIVATE_READBACK_CRASH`（隔离进程读回时连不上
Keystore，探针自己崩了），报告自己写着 "Attestation and trust-path checks still aligned" —— 是探针可用性，
不是完整性证据。

**剩下两张 Danger 不是 KeyLens 的（都量过现场）：**
- **Mount**：唯一 artifact 是 `/apex/com.android.art/bin/dex2oat64` 的 mount root 写着
  `/adb/modules/zygisk_vector/bin/dex2oat64` —— **zygisk_vector** 的 bind mount 在 zygote_next 隔离视图里露出来。
  主人明确说**不动它**。
- **SELinux**：根因是 KSU 自己的 `u:r:ksu:s0` 域。`ps -Z` 现量 **15 个进程**在这个域（`zygiskd64`、
  `vectord`、OMK 三个 daemon、还有 **KeyLens 自己的 `service.sh` + `inotifyd`**）。为此做过一次 `adb unroot`
  复核：**一个都没少** —— 与"adbd 是 root"无关，有模块服务就必然有。

**两条被证伪的猜测（别再当成待办）：**
- 「属性伪装会被"原始 vs 运行期"抓到」——**不会**：`/proc/bootconfig` 在这台是 `-r--r----- root system`，
  以 `u:r:untrusted_app` 读直接 `Permission denied`，应用拿不到原始侧；而 17 条被伪装的属性里只有
  `verifiedbootstate` 在 bootconfig 里有对应键，其余（flash.locked / veritymode / warranty_bit / build.tags…）
  根本没有原始源。报告里这 13 条全是 "Cross-checked across 3 sources"（三源一致）。
- 「SELinux 那张是因为我开着 adb root」——**不是**，见上。

**顺带能让 System Properties 那张变绿的（还没做，代价是断我 adb）**：它现在挂 2 条 review ——
`service.adb.root: 1`（`adb unroot` 后下次重启自然消失）与 `persist.sys.usb.config: adb`（要关掉 USB 调试）。

### 3.11 发版 v3.0.2（2026-11-01 23:4x）

**为什么发**：查仓库时发现**已发布的 v3.0.1 资产和仓库里的包不是一回事** —— 把那份资源下下来量：
**396,854 字节、19 份 `backends/*.awk`、没有 `bin/keyelens`**（= 阶段 5 之前的纯 shell 实现）；
而 `CHANGELOG.md` 的 3.0.1 段在 `4c39bb8`（阶段 5.4）已经被改写成"命令层只剩二进制"，
`update.json` 却还停在 `cc12931`。**文档在描述一份从没上传过的包。**

改动（都在这一个提交里）：
- `module/module.prop`：`version=v3.0.2`、`versionCode=202611012340`。
- `update.json`：三处跟着走（version / versionCode / `zipUrl` → `.../v3.0.2/KeyLens-v3.0.2.zip`）。
- `CHANGELOG.md`：拆成 **3.0.2**（阶段 5 收尾 + 三笔性能 + 四条修复 + 测试网）与**修正后的 3.0.1**
  （只留真正发布过的那条"安装即接管旧名模块"，文字逐字取自 `v3.0.1` 那个 tag）。
- `README.md`：版本行 → v3.0.2。
- `.gitignore`：第 39 行原来是一行 **GBK 乱码注释**（`# Rust 锟斤拷…`），换成正常中文。
  顺带全仓扫了一遍编码：跟踪文件里只剩 `module/lib/icondump.dex` 与 `webui/src/logo.png`
  两个二进制不是 UTF-8，其余全部合法。

包：`node tools/build-zip.mjs` → **`KeyLens-v3.0.2.zip` 711.6 KB / 34 条目**，
内含 `bin/keylens`（`c9f4049d…`，与真机同字节）、**0 份 awk**、`module.prop` 里是 v3.0.2。

**资产已上传（2026-11-01 23:24）** —— `https://github.com/IamCanincan/KeyLens/releases/tag/v3.0.2`
（tag 指向 `079abf9`，非 draft / 非 prerelease）。上传方式记一下，省得下次再问：
本机 `gh` 没登录，但 **git 里存着 GitHub 凭据**，`git credential fill` 能取到 token，
只在命令里 `GH_TOKEN=…` 用一次（不落盘、不打印）：

```sh
tok=$(printf 'protocol=https\nhost=github.com\n\n' | git credential fill | sed -n 's/^password=//p')
GH_TOKEN="$tok" HTTPS_PROXY=http://127.0.0.1:7890 \
  gh release create v3.0.2 KeyLens-v3.0.2.zip --repo IamCanincan/KeyLens \
     --title "KeyLens v3.0.2" --notes-file <CHANGELOG 的 3.0.2 段>
```

上传后复核（都过了）：资产 `KeyLens-v3.0.2.zip` **728,686 字节**、`digest sha256:6fadef49…` 与本地
那份逐字节相同；`update.json` 里的 `zipUrl` 现在能直接下载（之前指向的是 404）。

刷完之后要注意：机上版本会变成 v3.0.2，env 探针缓存的键跟着变成 `…|v3.0.2|…`，
第一次打开 `env` 会冷一次（~200ms），之后就回到 70~100ms。

**同日追加的修复：管理器里不显示「更新」按钮**
**实测证据（钉死的）**：`/data/adb/ksud module list`（管理器就是这么取模块列表的，
`KsuCli.kt` 的 `listModules()` 直接跑它）里，**keylens 那条根本没有 `versionCode` 字段** ——
同目录的 nomount 是 `"versionCode": "605"`。也就是 ksud 解析 `versionCode=202611010540`（12 位）
溢出后**把这个字段丢了**；`2026110123` 这种 10 位码它对得上（< 2^31-1，到 2147 年都安全）。
管理器侧则用 `Int` 比较（`Module.versionCode: Int` + `obj.optInt`，源码
`manager/app/src/main/java/me/weishu/kernelsu/data/{model/Module.kt,repository/ModuleRepositoryImpl.kt}`），
并且 `syncModuleUpdateInfo` 只在 `ModuleUpdateSignature(updateJson, versionCode, enabled, update, remove)`
变化时才重取 —— 字段一直是缺的，签名就一直不变。

**还没钉死的一环**：按代码推，"缺 versionCode ⇒ 0 < 远程" 应该照样显示更新；可他就是没见过按钮。
要分清是"被缓存钉住了"还是别的，最省事的做法是杀一次管理器再进模块页（内存里的结论会清空）、
下拉刷新；还不出就得刷一次 v3.0.2 —— 刷完 ksud 才读得出 versionCode，签名随之变化。
（这条线索留给下次接手时接着验，别当成已经结论了。）

**已经做的**：`module.prop` / `update.json` 的 versionCode 改成 10 位 `2026110123`；
`tests/module-desc.sh` 加了范围闸 + "12 位码必须被判红"的反面样本；
资产 `--clobber` 重传：**728,684 字节 / sha256 `489af9f5…`**（旧 728,686 / `6fadef49…` 被覆盖）。

⚠ **机上那份的 versionCode 还是 `202611010540`**：若 KSU 原生侧把它钳成 `INT_MAX`，那"远程 > 本地"
永远不成立 ⇒ **要看到更新按钮，得先手动刷一次 v3.0.2**（刷完之后每次发版都能正常提示）。

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
  其余 7 次是 teesim/tricky 那六条——**这台机只装了 OhMyKeymint**，走真实入口时两边都只走到「当前后端不是 X」的错误路径，
  差异覆盖由 §5.10 那台 `tests/device-six.sh` 负责（夹具根 + 设备的 toybox awk）；
  不要为了好看往 `/data/adb/` 里塞假目录：`detect_backend` 会当场改口。
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
   - **换完产物 CI 两条都绿**：`Rust CLI` Run 3 与 `Build CI Module` Run 75（commit `fdc841b`）都是
     `completed successfully`。`rust-build.yml` 里 13 步没有一个带条件跳过 ⇒ 这道绿就是
     `Contract parity` / `Golden snapshots` / `Verify static` / `Module binary handshake`
     **第一次真跑通过**，不是"步骤被 skip 所以没红"。§5 到这里全部做完。

## 5.9 启动开销：这一轮量到并收掉的（同机交替、各取 5~6 次最快）

| 位置 | 改前 | 改后 | 为什么 |
|---|---|---|---|
| 任意命令的壳层 | 69~89ms | 25~37ms | 接管点从 1273 行挪到 54 行：mksh 边读边解析，排在函数体之后等于每条命令先建一遍 70KB 的函数定义。六个 lib 一起 load 其实只值 ~7ms（我先前判断错过一次） |
| props 页 | 311~366ms | 59~91ms | 17 次单键 `getprop`（每次 ~18ms）改成一次全量 dump 查表 |
| env 页（无缓存） | 410ms | 334ms | 同上，env 的 6 个属性字段 + 1 个密度兜底也吃快照 |
| env 页（命中缓存） | 334ms | **93ms**（直调二进制 69ms） | 见下：19 键探针缓存落到 Rust 侧 |
| `run_sync` 的后台同步 | 走 awk 链 | 走二进制 | 见 §5.2；新包里没有 awk，安装期能报出 132 就是证据 |

**env 探针缓存（`let _ = cache;` 那半刀，本轮收掉）**：`env_cmd` 现在与 `cmd_env` 共用
`/data/adb/keylens.env.cache`（`KL_ENV_CACHE` 可改），同一套 19 个键、同一个 TAB 分隔、同样
`chmod 600` + 临时文件改名落盘。缓存键 = `v1|模块目录|module.prop 的 version|/system/build.prop 的 mtime`。
深浅色（`dumpsys uimode`）与种子（`settings get`）每次现取，FRRO 按**路径 + mtime** 判重编。

顺带改掉的一处口径：Rust 原来用 `spawn("<工具> --version")` 当"可用"，shell 用的是
`command -v` + 真跑一次（`awk 'BEGIN{}'`、解一段 base64、`--help` 里找标记）。缓存是两边共用的，
两种答案写进同一份文件会互相污染，所以 Rust 改成与 shell 同语义（`cmd_available` 扫 PATH，不起进程）。
副作用只有好处：只有 busybox、且 applet 没编进去的机器，以前二进制报 `awk=0` 而 shell 报 `awk=1`。

覆盖分两层，缺一不可：
- `rust/parity.sh` 的「env 缓存」一节 24 条（冷=热、两个方向互读、热跑不起 getprop/dumpsys window/wm/id
  且**仍**起 uimode/settings、键名 19 个逐字点名、600、换版本重探）。夹具机的 `/data/resource-cache`
  是空的 ⇒ **FRRO 那一段结构性测不到**。
- `tests/device-env-cache.sh` 28 条补的就是那一段：这台有 `com.android.systemui-accent-pQcS.frro`，
  冷跑先把 base64 写进缓存，热跑逐行一致；再把缓存里的 `frro_mtime` 改成 1、`frro_path` 后面加 `.stale`，
  两次都必须重编并把真值写回（变异不落地会当场报错，不留假绿）。
- `tests/env-cache.sh` 加了 Rust 侧的静态形状闸：两份**源码里的键名名单**逐个同序。
  运行时对拍比的是输出，名单一起漂时输出不漂，只有这条会响（已拿真源改名验过它会红）。

量法（要复现就这么量）：`PATH` 前置一层"记一笔再转给 /system/bin"的壳去数外部进程，
但**只能直调二进制时用** —— `webui.sh` 会重新 `export PATH` 把 /system/bin 排到前面，
走脚本时那些壳根本不参与，会量出"0 次"的假象（我踩过一次）。设备台子里同理，
`cnt()` 先证明冷跑确实记了 4 笔，再拿"热跑 0 笔"当结论。

## 5.10 把对拍搬到手机上跑（`tests/device-six.sh`，真机 83 项全过）

这台只装 OhMyKeymint，所以 teesim/tricky 那六条写命令（`teesim-save`、`teesim-save-overrides`、
`teesim-profile-new`、`teesim-profile-del`、`tricky-save-patch`、`tricky-drop-patch`）走真实入口时
两边都只到「当前后端不是 X」的错误路径 —— 差异一行没量到。而它们原本的覆盖只在 `rust/parity.sh`，
那是 **WSL 的 GNU awk + dash**；参照实现（19 份 awk）在设备的 **toybox awk + mksh** 下行为是否一致，
以前没人量过。这一层补的就是那个。

要点三条（都是这台子能不能信的关键）：
- **夹具与 harness 从 `rust/parity.sh` 里 `sed` 原样抽出来 eval**，不在设备台子里手抄第二份 ——
  抄的那份改了不会响。每个抽出来的生成器都要先造出一只该存在的文件，造不出来当场报错。
  payload（`PL` / `PLTS` / `PLOV`）同样按行从 parity.sh 取。
- **A/B 比的是「目标文件的字节」，不是「整棵树」**：harness 在 shell 那侧把 `commit_backend_file`
  桩成了 `cp`（parity 原样），于是 shell 侧不生成 `.bak`、留着一个 `.<file>.keylens.<pid>` 临时文件、
  drop 那条还多造一个 `.pre`；Rust 侧则会写 `data/adb/keylens.log`。这些是**桩的形状**，不是实现的差异
  —— 我第一版拿整棵树比，四条红全是这个。白名单滤掉的每一类都要有一格点名验回来
  （这里就补了两条"Rust 侧确实生成了 .bak"）。
- 每条命令都带**正对照**：目标文件必须真被动过、输出里不许出现「当前后端不是」，
  最后还有一条拿真实入口跑同一条命令、断言它**只**得到那句错误 —— 记下"不建夹具就是零差异"这个事实。

变异验证（把 shell 侧的 `patch_boot` 改成 `patch_b00t`，二进制不动）：
`tricky-save-patch` 的输出一致、目标文件一致、shell 侧被写了、以及它的 preview 输出一致 **四条当场红**，
其余不动；还原后 `write.sh` 的 sha 与仓库逐字节相同，复跑 83 项全绿。

跑法（要先推两件东西上去）：
```sh
adb push rust/parity.sh   /data/adb/keylens-ab/parity.sh
adb push tests/device-six.sh /data/adb/keylens-ab/device-six.sh
adb shell "sed -i 's/\r\$//' /data/adb/keylens-ab/{parity.sh,device-six.sh} && \
           MODDIR=/data/adb/keylens-ab sh /data/adb/keylens-ab/device-six.sh"
```
顺带一处可移植性改动：`rust/parity.sh` 里 `head -n -1` 换成 `sed '$d'` —— toybox 的 `head` 不收负数，
不换的话预览 harness 在设备上直接坏掉（11 例 preview 全红，看着像实现坏了）。

## 5.11 真机验 OMK 的写路径（`tests/device-omk-write.sh`，真机 20 项全过）

这台的后端是 OhMyKeymint，界面上每一次"保存配置"都走 `omk-save-config` → `omk_set.awk`
（19 份参照里最复杂的一份：TOML 定点改写 + 未知键策略）。`rust/parity.sh` 覆盖了它，但跑在
WSL 的 **GNU awk** 上；设备上是 **toybox awk**。这一台补的就是这个差。

跑的是**真写**，但在夹具根里跑（`KEYLENS_ROOT` / harness 双份夹具），现场配置一个字节不碰：
- 两侧输出逐字节一致、写出的 `config.toml` 逐字节一致；
- 正对照：补丁字段真的写进去了、夹具真的变了、`.bak` 真的生成了（落在 **`KL_DIR`**，不是目标文件旁边）；
- 再保存一次同样的内容必须 `saved=0` 且不再落盘（写路径里 `cmp -s out cfg` 的短路）；
- 预览：两侧夹具一字不动、`changed>0`；
- `vb_key random→auto` 那条要判出 `apply_scope=reboot`（两侧输出仍逐字节一致）；
- 变异：把参照实现 `write.sh` 的字段校验改坏 → 两侧输出必须当场对不上。

两个坑记在这（都真踩了）：
1. **payload 在 `parity.sh` 里是跨行的**（行尾反斜杠续行），`grep '^PLOC='` 只抓到第一行，
   得到一个没闭合的 `$( `，`eval` 时就是 mksh 的 `syntax error: unmatched (`。要按"行尾反斜杠就继续"取整条赋值。
2. **`omk_set.awk` 里那条 `"trust" SUBSEP "security_patch"` 不是这个键实际走的路径** ——
   拿它做变异，改完两侧输出仍然一样，等于没变异；换成动 shell 侧 `write.sh` 的校验分支才真的响。
   记这条是因为"变异没落地"和"变异落了但没用"在输出上长得一模一样。

## 6. 坑（都踩过）



- **PowerShell 写文件/内联脚本**会带 BOM/CRLF、`$` 会被解析：Rust/sh 源码一律用编辑工具写，或用 `node <文件>.cjs` 脚本改；写完 `\r` 要清掉（否则 `sh` 报 `EOF unexpected`）。
- **设备上那台 shell 的两种"静默"**（本轮加 env 缓存台子时各撞一次，症状都是"实现看着坏了"）：
  - mksh 的 `${v%|*}` **不生效**（`a|b|c` 原样出来）。剥缓存键的末段要走 `sed 's/|[^|]*$//'`；
    同一条断言在 WSL 的 dash 下是正常的，所以只有上机才会看见它红。
  - toybox `grep` **不支持 BRE 的 `\|`**：`grep -c '^A\|^B'` 恒 0，两个 `-e` 或 `-E` 才对。
    凡"用 0 命中下结论"的场合，先拿一个已知会命中的样本验它能数到非零。
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
- **台子只 eval shell 那份函数，就等于在给没在跑的实现盖章**：`tests/module-desc.sh` 从 `backend.sh` 里抽出 `set_module_desc` 验"改名后把原 mode 补回去"，一直绿；而命令层默认走 `bin/keylens`，Rust 的同名函数**只 write tmp + rename、没补 mode** —— 真机上 `module.prop` 于是跟着调用者的 umask 漂（实测漂成 666，是整棵模块目录里唯一世界可写的文件）。同一族还有一条：Rust 的 tmp 名不带 pid（`module.prop.tmp` 固定名），而 `ls module.prop.tmp.*` 那种残留判据压根看不见它。现在两边都钉：行为在 cargo 单测（`set_module_desc_keeps_mode_and_other_lines`，删掉补权限那行它当场红），形状在 `tests/module-desc.sh`。
- **写"保住原权限"的测试，原权限要写得和这台机 umask 造出来的不一样**：第一版写死 644，而 WSL 的 umask 就是 022（`fs::write` 造出来也是 644）⇒ 把补权限那行删掉测试照样绿。现在先用一个 probe 文件探出"这里造出来是几"，再取一个与之不同的 mode 当原权限；探到 chmod 不生效的平台（drvfs/MSYS）就明说"没测到"并跳过，不许当通过。
- **带桩的 harness 里不要拿"整棵树一致"当 A/B 判据**：`tests/device-six.sh` 第一版比的是夹具根的文件清单，四条红 —— 全是桩的形状：shell 侧 `commit_backend_file` 被 parity 桩成 `cp`（于是不生成 `.bak`、留下 `.<file>.keylens.<pid>` 临时文件、drop 那条还多一个 `.pre`），Rust 侧则会写 `data/adb/keylens.log`。判据要收口到**目标文件的字节**，白名单滤掉的每一类都得另有一格点名验回来。
- **adb 那个 root shell 的 umask 是 000**（`touch` 出来就是 666），而 `webui.sh`/`service.sh` 里都是 `umask 077`：凡"从 adb 直接调命令层"的测试，落盘形状会与守护进程/界面那条路不一样 —— 前面那条 module.prop 权限漂成 666 就是这么来的（不是守护进程写的）。
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
| `rust/parity.sh` | 205 项逐字节对拍（含漂移闸、覆盖率、EPIPE、下限 205） |
| `tests/device-ab.sh` | 真机 A/B（含写回文件指纹） |
| `tests/device-preview.sh` | 真机 preview-* 逐字节 A/B（含「预览不许落盘」的后端文件指纹与覆盖口径） |
| `tests/device-env-cache.sh` | 真机验 env 探针缓存：冷=热、两边互读、热跑不起进程、FRRO 的 mtime/路径各一条变异（夹具机测不到 FRRO） |
| `tests/device-six.sh` | 真机跑 teesim/tricky 那六条的写与预览 A/B（夹具+harness 抽自 `parity.sh`，参照实现走设备的 toybox awk） |
| `tests/device-omk-write.sh` | 真机跑 `omk-save-config` 的真写/预览（夹具根，不碰现场配置；验 `.bak`、幂等、reboot 判据与一条变异） |
| `tests/run-sync-bin.sh` | `run_sync` 二进制分支的三条判据 + 三条变异（CI 跑，桩掉 awk 实现） |
| `tests/device-run-sync.sh` | 真机验锁接力：持锁不自抢、不持锁自取自放、两条分支结果一致、拿掉接力条的变异 |
| `tests/rust-golden.sh` + `rust/golden/` | 黄金快照（删 awk 后的回归网） |
| `tests/module-bin.sh` | 包内二进制 contract 握手 |
| `tests/static-check.sh` | 静态链接判据 |
| `docs/{RUST-REWRITE,BACKEND-INFO-SPEC,ENV-SPEC,SYNC-SPEC,OMK-SET-SPEC,TEESIM-SET-SPEC,AWK-REMOVAL}.md` | 方案、实况、各命令规格、删 awk 施工单 |

## 8. 最近提交（倒序）

（本轮 CI：`59fdcfe` 上 `Build CI Module` Run 77 / `Rust CLI` Run 7 全绿；纯 docs 的提交按
`on.push.paths` 白名单不会触发 CI，这是设计。）

```
59fdcfe 新增 tests/device-six.sh：把 teesim/tricky 那六条的写与预览搬到手机上真跑 A/B（83 项全过）
17f8a37 修 module.prop 权限漂移，并补上"闸只量 shell 那份"的盲区
7574469 文档：§3.7 的"推不动"改成实况——8 个提交已上 main，Run 76 / Run 6 全绿
2aedde5 文档：§3.7 记下生产模块热替换二进制的复核（env 冷 204ms / 热 70ms、缓存键带生产模块目录、 zip 重打 711.2 KB）与"代理仍不通"的实测读数 + 离线包判据
66449de 性能③(后半)：env 探针缓存落到二进制，真机 334ms → 93ms
bf54d4a 文档：§5.9 启动开销实测（壳层 69→27、props 366→91、env 410→338）与还没收的 env 缓存一半
fa62b95 性能③(前半)：env 页也改吃一次 getprop 快照，真机 410ms → 310ms
13a77b7 性能②：props 页从 17 次 getprop 改成一次全量 dump，真机 311ms → 59ms
a7001b0 性能①：接管点挪到 webui.sh 自己的函数体之前，每条命令省 ~54ms
072780d 文档：§3.6 重启后复核结果（新树已在生产模块目录跑，doctor 11 项无 bad、后台同步走二进制、预览不落盘、回滚件在位）
24e8fab 新增 tests/device-install-check.sh：装完包、重启前那段时间窗口的核对（真跑过，28 条全过）
036778b 清死代码：删掉"加了从不读"的 depth 计数器与三个从来没用 Paths 的函数参数
69d556f 对拍补形状：save-patch 带上"段尾空行+注释"，teesim-profiles 埋一个嵌套诱饵 + 四条绝对断言，下限 175→179
42558f2 清理：删掉 Rust 里那套已经死掉的 PREVIEW 机器（a961f8e 的残留）
0ffcb71 文档：CI 两条已全绿（Run 3 / Run 75，13 步无条件跳过=真跑过），§0 网络现状改成'走代理可用'
fdc841b 修 CI 的红（第三处，也是最实的一处）：发布产物换成 aarch64-unknown-linux-musl
9f8a703 修 CI 的第二处红：rust-build 的 Contract parity 提取器没在收尾引号处停下
ed2a2df 修 CI 红：json-flat-set-check 还指着 module/backends（重指脚本漏了 .cjs 后缀）
88efac1 小修：device-preview 的 profile-del default 那条补上目标文件参数
86b87bb 文档：bundle 不再写死文件名（给命令与 list-heads 判据），§8 补最新提交
c5eb978 修发布链自洽：build-zip 必须打进 bin/keylens，否则拒绝出包
```
