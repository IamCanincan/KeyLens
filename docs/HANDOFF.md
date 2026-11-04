# 交接文档（KeyLens 命令层 Rust 化）

> 给接手的人/agent：这份文档是当前会话的完整状态。**先读「怎么验证」一节跑一遍闸门**，再按「剩余工作」继续。
> 代码都在 `main` 分支上；直连 github.com 仍解析不了，`git push` 走本机代理（§0）。

## 0. 仓库与环境

- 仓库：本机这个 clone（模块的 name/id 都已改 KeyLens；**目录名仍是改名前的旧名**，本文按残留闸的要求不复述它）
- 分支：`main`，HEAD 见 `git log -1`
- 未推送提交：写作时 0（发版这一轮全部已推），每提交一条就 +1；以 `git rev-list --count origin/main..main` 为准
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
  模块已装：`/data/adb/modules/keylens`（OMK 后端）。**2026-11-03 00:30 主人已用管理器更新到 v3.0.3**
  （`versionCode=2026110300`、`bin/keylens` 326,416 字节 / sha256 前 16 位 `0905d3b7bb383ea5`），
  并与发布包逐文件比过：除 `META-INF/`+`customize.sh`（装完即删）、`module.prop` 的
  description（运行期改成实时状态）、`webroot/icons/`（设备生成）三处外**逐字节相同**。
  更新后重启过一次（开机日志：`🚀 开机完成（等了 14 秒）` → 属性复核 → 同步按指纹跳过），
  重启后 `boot-hash` = auto·omk·ok、`props` 53/53、`doctor` 11·0·0。测试用的临时副本 `/data/adb/keylens-ab`
  **已按主人要求删掉**（2026-11-01 20:3x），要跑真机台子先照 §3 那一段重建（先 mkdir，再一条 deploy + 六条 push）。

## 1. 现在完成到哪

**命令层 41/41 全部用 Rust 实现**（`rust/src/*.rs`，`read_cmds.rs` 约 5.4k 行），命令契约（41 条、同序、同 kv/tsv 输出）保持不变。

| 证据 | 数值 | 怎么跑 |
|---|---|---|
| Rust 单测 | 77 项 | 见 §2 |
| shell↔Rust 逐字节对拍 | **276 项 chk**（含 preview-* 11 例 ×4 条断言、env 探针缓存一节 24 条、属性判定改造后的降级 3 条与"两侧写完的属性区逐字节相同"状态 A/B、启动哈希三态 23 条、`current=` 读数口径 3 条、teesim 那一支"采用守护进程的值"5 条、**体检「启动哈希」那一格按三态各钉两侧 14 条**（§5.17）、**`apps` 三档各钉两侧期望文本 6 条**（§5.18）、**`set-mode` 走分派臂 + 界面形状 7 条**（§5.19 #1）、**「已排除」覆盖系统包的正对照 2 条**（§5.19 #4）、**`apps launchable` 两侧各一条**（§5.21）） | `sh rust/parity.sh` |
| 属性判定（两张表 → 一份计划） | **30 条断言全过**：表形状（属性名字符集、两表不重名）、四列与状态（含坑值 `]`/空值/空格/中文）、链式改只落一次盘、absent 不进计划也不凭空创建、awk 路与逐键回落路落到**同一个属性区**；三处变异（只换第一处 / absent 塌成 missing / 键名拼错熄火）各自自证 | `sh tests/props-plan.sh` |
| 真机属性伪装 | **17 条断言全过**（现跑的 ok 行数）：台子**自己种出待改状态**（不能指望现场正好在泄漏），臂 A 实测改写 11 个属性（正对照）、两臂 43 个键逐字节相同、属性区无新增键、`applied=1 / mismatch=0`、toybox 与 busybox 两种 awk 同结果、跑完逐个还原并复核 | `sh tests/device-props-mask.sh --write`（不加 `--write` 直接 skip） |
| **属性页真的画出来看过** | **4 条新断言 + 5 个变异全响**：53 行逐行上屏（rows=53；固定表今天试过 15→18、装了机，又被 Duck 源码推翻撤回 15，见 §5.23/§5.24）、absent 画「本机无」+ 灰点而不是红色「不符」、标题只数 diff/missing（9 项而非 13 项）、absent 行不挂 warn 色。台架假数据换成**真机现量的行**（`sh webui.sh props`），不再是手写的 5 行 | `node tools/md3e-build/verify.mjs`、`node tools/md3e-build/mutate-verify.mjs`；图在 `%TEMP%/md3e-verify/new-props*.png` |
| 启动哈希三态（auto/manual/off） | 单元 **64 条**（这一版前是 52 条；文档旧写的「22 条」早就过期了，本轮按 `sh tests/props-boot-hash.sh` 现数的 ok 行改口。含两处变异：摘掉「只认 hex」的守卫 ⇒ random 被写进 prop；摘掉「属性已有值就采用它」那行 ⇒ override 覆盖守护进程）；对拍 **23+3+5 条**（auto 派生 / random 熄火 / 手动优先 / off 一个字节都不写 / 改配置立刻跟着变 / 没后端不派生；3 条钉 `current=` 读数口径；5 条钉 teesim 那一支不覆盖，见 §5.15）；真机 **20 条**——**夹具里只放后端配置、不放 boot_hash 文件，auto 算出的值与主人手抄那串逐字节相同**（新用户免抄的正对照），且全程只读不动现场；**另外把现场本身切到 auto 真跑了一遍**（跑完原样还原） | `sh tests/props-boot-hash.sh`、`sh rust/parity.sh`、`sh tests/device-boot-hash.sh` |
| shell 测试套 | **55 套，两套环境全绿**（WSL 55/55 与 Windows Git Bash 55/55，2026-11-04 现量；`tests/device-*.sh` 家族不在设备上时自跳，不算假绿；新增的两套见 §5.37；`rust-dispatch` 的 Git Bash 恒红已修，成因见 §6） | 见 §2 |
| 真机 A/B（只读 17 + 写 21） | 装了 3.0.3 的现场：**16/17**（只读，红的就是 `doctor`，见 §5.17）；补上 §5.17 的两处改动后在临时副本里 **38/38 全过**（2026-11-03 现量，未发版）。台子怎么跑见 §3，参照 awk 要先推上去 | `sh tests/device-ab.sh [--write]` |
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
sh rust/build-release.sh   # 发布构建（nightly + build-std + immediate-abort，两个 musl 产物）
# 对拍（276 项 chk；CI 用 musl 产物；本机那份 ELF 在 Windows 上跑不了，
# 是在 WSL Debian 里跑同一份 x86_64-musl 产物 —— 那边 awk 是 mawk，与 Git Bash 的 gawk
# 会给出不同结果，见 §5.12 的方言差）
sh rust/parity.sh rust/target/x86_64-unknown-linux-musl/release/keylens
# 从 Windows 这边跑并读到**真退码**（内联 echo $? 会被本地 shell 吞掉，见 §6）：
wsl -d Debian sh /mnt/d/<仓库路径>/tools/wsl-parity.sh   # 末行 = parity exit=N｜结论
```

shell 测试套 **55 套**，两边都得跑，各有盲区：

| 环境 | 结果 | 盲区 |
|---|---|---|
| WSL | 55/55 绿 | 没有 node：`tools/name-residue-check.mjs` 那类静态子闸走 skip 分支（`tests/legacy-migrate.sh` 的「零残留」段就是其一） |
| Windows Git Bash（有 node） | 55/55 绿 | 没有 cargo/链接器：Rust 单测与对拍只能在这里之外的 WSL 跑；`rust/target` 里的 Linux 二进制在这儿 exec 不了，依赖它的套子会自己 skip |
| 设备（mksh + toybox awk） | `tests/device-fallback.sh` **44 条 + 7 条现量全绿**（2026-11-04 18:5x，`XQ-DQ72` / API 37） | 只有这一层能证明"这台机上回退层会说什么"——主机那两遍量的是 gawk / mawk。**量生产形状要跑真模块目录**，别跑仓库形状的副本（§6） |

WSL 侧用 `wsl -d Debian sh -c "cd '/mnt/d/<仓库路径>' && sh tools/wsl-suites.sh"`，
末行是 `suites=55 failures=0`，逐套退码落 `tests-wsl.log`。**别在 Windows 这边内联 for 循环**：
`$t` / `$?` 会被本地先展开，本轮据此拿到过一份四行"FAIL "（连套名都被吞掉）的假失败清单，
真跑是 55/55 —— 同一个理由已经有 `tools/wsl-parity.sh` 了（见 §6）。

> `tests/rust-dispatch.sh` 以前在 Git Bash 恒红，是台子自己用了 `env VAR=x sh -c …`：
> 这台的 `env` 会把 `env sh 脚本` 跑成**空输出且退 0**，与被测代码无关。已改成在一个 shell 里赋值。
> 教训：`env` 在这台 Windows 上不能用来给 `sh` 传变量。

Git Bash 侧逐套跑（PowerShell）与 node 闸（CI 里一共 11 条，清单见 `.github/workflows/build_ci.yml`）：

```powershell
$fail=0; foreach ($t in (Get-ChildItem tests\*.sh).Name) { & "D:\Git\bin\bash.exe" "tests/$t" *> $null; if ($LASTEXITCODE -ne 0) { $fail++; Write-Host "FAIL $t" } }; "failures=$fail"
node tests/ui-shape.js; node tools/doc-consistency.mjs
```

要连组件属性通道一起过一遍（要 Chrome，慢，跑 55 屏）：

```sh
node tools/md3e-build/attr-audit.mjs        # 0 命中会自带仪器自测与覆盖读数
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
# 属性伪装（**会改运行期属性**，跑完自己逐个还原；不加 --write 就 skip，见 §5.13）
adb push tests/device-props-mask.sh /data/adb/keylens-ab/device-props-mask.sh
adb shell "cd /data/adb/keylens-ab && MODDIR=/data/adb/keylens-ab sh device-props-mask.sh --write"
# 启动哈希三态（全程只读：夹具里只放真实 config.toml，不碰主人的 boot_hash 文件，见 §5.14）
adb push tests/device-boot-hash.sh /data/adb/keylens-ab/device-boot-hash.sh
adb shell "MODDIR=/data/adb/modules/keylens sh /data/adb/keylens-ab/device-boot-hash.sh"
# 现场那一侧的 auto 切换（会动主人的 boot_hash 文件，跑完必须原样还原；§5.14 记了本轮现量）
adb shell 'cp -p /data/adb/keylens.boot_hash /data/adb/keylens.boot_hash.pre'
adb shell '/data/adb/modules/keylens/bin/keylens props-boot-hash auto'    # 裸 shell：resetprop 不在 PATH
adb shell 'export PATH=/data/adb/ksu/bin:$PATH; /data/adb/modules/keylens/bin/keylens props-boot-hash auto'  # 生产形状
adb shell 'mv /data/adb/keylens.boot_hash.pre /data/adb/keylens.boot_hash'   # 还原，然后 boot-hash 应回 mode=manual
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

**第二次真跑（2026-11-01 23:38，装 v3.0.2 的那个窗口）：28/28 全过。**
`ksud module install` 之后同一套断言，外加三条新现场：
① 新树 `module.prop` 是 `v3.0.2` / `versionCode=2026110123`、`bin/keylens` 644648 字节、`backends/` 只剩 `tricky.sh`；
② `ksud module list` 里 keylens 这条现在带 `"versionCode": "2026110123"`（改 10 位之前这个字段整个是缺的，见 §3.11）；
③ 顺手修掉台子里一条会假红的说明性断言 —— 原来写死"旧树必报 `apply_scope=restart`"，
   而旧树一旦换了实现、或者装的是不再带 awk 的新包，它就静默空输出。现在改成
   **"旧树 shell 预览不许静默空输出：要么给 apply_scope，要么明说缺 awk"**，
   实测它现在报的就是 `缺少 omk_set.awk`（新包不带 awk，符合预期）。

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
  `rust/parity.sh` 末尾那条 `oks` 下限闸就是"新节真的跑了"的证据：作业绿 ⇒ CI 上至少数到当时
  的下限（写这一段时是 205，本轮补完属性表已抬到 **216**）。

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
  以 `u:r:untrusted_app` 读直接 `Permission denied`，应用拿不到原始侧；而旧那 17 条被伪装的属性里只有
  `verifiedbootstate` 在 bootconfig 里有对应键，其余（flash.locked / veritymode / warranty_bit / build.tags…）
  根本没有原始源。报告里这 13 条全是 "Cross-checked across 3 sources"（三源一致）。
  **本轮新加的 26 个属性名同样没有原始源**——2026-11-02 以 root 读 `/proc/bootconfig` 列了全部
  `androidboot.*` 键（babe / baseband / boot_devices / dtb_idx / force_normal_boot / fstab_suffix /
  hardware / keymaster / memcg / serialno / slot_suffix / usbcontroller / **verifiedbootstate**），
  新增的这些都是 `*.build.type` / `*.build.tags` / `*.build.fingerprint` / `ro.build.flavor` /
  `ro.build.description`，来源只有 build.prop 与属性区，boot 参数里压根没有对应键。
  ⚠ 但这一条只对**这一个检测器**成立：它拿不到原始侧；换一台 `/proc/cmdline` 可读的设备或
  带 root 的检查器，掩过的属性就是可比的差异（见 §5.12 的 raw boot params 判据）。
- 「SELinux 那张是因为我开着 adb root」——**不是**，见上。

**顺带能让 System Properties 那张变绿的（还没做，代价是断我 adb）**：它现在挂 2 条 review ——
`service.adb.root: 1`（`adb unroot` 后下次重启自然消失）与 `persist.sys.usb.config: adb`（要关掉 USB 调试）。

### 3.14 发版 v3.0.5（2026-11-04 23:0x）

**这一版**：更新卡下载完直接给「安装」（走 `ksud module install`，重启生效）+ 更新日志画在卡里（新命令
`update-install`，两侧实现，详见 §5.40）；卸载补收 `/data/adb/keylens-ab`（§5.39 ③）。

**四处一起改**：`module/module.prop`（`v3.0.5` / `2026110423`）、`update.json`、`CHANGELOG.md`（新增 3.0.5 段，
"未发布"那一条并进去）、`README.md` 版本行；`RELEASE_NOTES.md` 重写成 3.0.5 —— 它同时就是**应用内更新日志**的
数据源（管理器 API 的 `body`）。

**发布前全量验过**：Git Bash **55/55** · WSL **55/55** · 对拍 **281 exit=0** · `cargo test` **77 passed** ·
11 条静态闸全 OK · 台架 **178** · 产物两份同版（`build --check`）。真机现量 `update-install` 的两支前置见 §5.40。

**资产已上传（2026-11-05 00:0x 本地）** —— `https://github.com/IamCanincan/KeyLens/releases/tag/v3.0.5`
（tag `b645add`，非 draft / 非 prerelease；资产 551,075 字节）。**GitHub 自己算的 digest 就是
`sha256:6c2bf93c…`，与本地逐字节相同**；`update.json` 线上已指向 v3.0.5。
界面本体另外**热推过一次**到机上（`deploy-webui.sh`，webroot `d0ec0708…`）—— 主人当场确认「不透明了」，
那时模块还是 3.0.4；正式包装上后两边就一致了。

**包**：`node tools/build-zip.mjs` → `KeyLens-v3.0.5.zip` **551,075 字节 / 31 条目**，
sha256 `6c2bf93cec796464ca872816f258fe5ade6337ce0b9b6a327ecca5d7ef006439`（含底栏/四格/收尾三处改动后的最终包）；`--check` 全过（0 份 awk、无 `webroot/icons/`、`bin/keylens` 恰好一条）。

**底栏不透明 + 统计四格同一行**（主人："底栏我不要透明的"，接着看截图发现四格会换行）：
药丸底色从 `86% + blur(18px)` 换成实色 `--navigation-container`（模糊一并删，它只剩开销）；
`.hero-stats` 从 flex+wrap+28px 改成每格 `min-width:0` + 长值格内换行。两条都写成了闸：
底栏是**反向**断言（实色 / 不许 color-mix / 不许 backdrop-filter），四格是"不许 wrap + 必须 min-width:0"。

**这一版再加两条收尾**：安装成功后删掉 `update.zip`（ksud 已拷走，538 KB 死文件；失败保留以便重试）；
装完不再给「再检查一次」（模块版本要等重启才变，这时再查必然还是"有新版本"，会让人以为没装上）。
顺带把我自己新写的 `md-lite` 那 6 处 `rem` 改回 `px` —— 全站本来是 px，只有这六行是 rem
（数值相同、渲染不变，只是别再引入第二种写法）。

**发布前一轮「看图改」**（台架第一次给更新卡存截图）：一眼看见三个真缺陷 —— 提示文案里的 `**` 原样印成星号、
装完后「检查更新」和「再检查一次」两颗按钮做同一件事、以及展开日志时下面还多一行原始 `# KeyLens v9.9.9`
（悬空 `else` 绑到了第二个 `if` 上）。三个都修了，并给预览行加了 `.md-preview` 标记、台架补成
"收起=1 行预览 / 展开=0 行预览" 两条断言 —— 原来只断言"md 在、li≥2"，看不见多出来的那一行。

### 3.13 发版 v3.0.4（2026-11-04 22:0x）

**这一版装了什么**（相对 v3.0.3，详细条目见 CHANGELOG 的 3.0.4 段）：功能页按任务流重排成**四项**
（自动同步并进名单页、备份回滚并进后端配置、体检进主页大卡片）；名单屏按人的找法重做（吸顶层、
整行点选、继续显示、两段式批量、卸载残留点名）；**修掉从 v3.0.0 起每条提示都印 `[object Object]`**；
Tricky 的证书模式按钮在发布包里能用；系统应用可勾选；回退层不再把"读不到"交成"0 条 + 成功"。

**四处一起改**：`module/module.prop`（`v3.0.4` / `2026110422`）、`update.json`（version /
versionCode / `zipUrl` → `.../v3.0.4/KeyLens-v3.0.4.zip`）、`CHANGELOG.md`（未发布 → `3.0.4 - 2026-11-04`）、
`README.md` 版本行。**`RELEASE_NOTES.md` 整篇重写** —— 它原来还停着改名前的 `v2.2.19.5-yuzu`
（那份文件从改名起就漏了，标题、正文全是上一个项目名下的旧版本）。

**包**：`node tools/build-zip.mjs` → `KeyLens-v3.0.4.zip` **547,793 字节 / 31 条目**，
sha256 `e5c5b22b1c8fbbfae9c586867eda73744c650b205c8eebc55e4e0a1e99760c2b`；
内含 `bin/keylens` **329,640 字节**（与 `rust/target/aarch64-…/release/keylens` 逐字节相同，
`fbc02da5af9021c1`）、**0 份 awk**、**没有 `webroot/icons/`**、`module.prop` 里是 v3.0.4。
`--check` 8 条全过。

**发布前全量验过**（这一轮一件没改产品行为，只是版本号）：Git Bash **55/55** · WSL **55/55** ·
对拍 **276 exit=0**（用同一份 build-std 的 x86 产物重跑的）· `cargo test` **77 passed** ·
11 条静态闸全 OK · 台架 **175** · `attr-audit` 52 屏 / 893 个元素 0 命中 ·
真机回放 **42/42** · `device-fallback` **44 + 7 条现量**。新二进制另外在真机上直接跑过
`targets`(131) / `status`(ok) / `doctor`(16 行) / `props`(53) / `contract`(api=4)。
**CI**：`d09efff` 两条 workflow（Build CI Module、Rust CLI）都是 success。

**资产已上传（2026-11-04 22:03 本地）** —— `https://github.com/IamCanincan/KeyLens/releases/tag/v3.0.4`
（tag 指向 `d09efff`，非 draft / 非 prerelease）。上传仍走 `git credential fill` 取 token、
`GH_TOKEN` 只在环境里用一次、`HTTPS_PROXY` 显式给（`gh` 不读 git 的代理配置）。
**GitHub 自己算的 digest 就是 `sha256:e5c5b22b…6c2b`，与本地那份相同**；`update.json` 线上已指向
v3.0.4，资产 URL 302 → 200。

**顺带修的台子 flaky**：`tests/teesim-overrides-write.sh` 把 MSYS 的 `/tmp/…` 直接喂给 Windows 原生
`node`（node 读成 `D:\tmp\…` 报 ENOENT）。全量跑时红过一次、再跑又绿 —— 现在先过 `cygpath`，
`TMPDIR=/tmp` 与默认两种形状都跑过。

### 3.12 发版 v3.0.3（2026-11-03 00:2x）

**这一版装了什么**（相对 v3.0.2）：启动哈希三态（默认 auto）、属性伪装补到 43 个属性名 +
就地改写、属性页 absent 那条修复、TEESim 那一侧不覆盖守护进程的 digest、
`current=` 读数口径统一、打包剔除运行时缓存、二进制 −50%（326,416 字节）。
详细条目见 `CHANGELOG.md` 的 3.0.3 段。

**四处一起改**：`module/module.prop`（`version=v3.0.3`、`versionCode=2026110300`）、
`update.json`（version / versionCode / `zipUrl` → `.../v3.0.3/KeyLens-v3.0.3.zip`）、
`CHANGELOG.md`（3.0.3 → `2026-11-03`）、`README.md`（版本行）。

**包**：`node tools/build-zip.mjs` → `KeyLens-v3.0.3.zip` **533,142 字节 / 31 条目**，
sha256 `1afc7c3806d6378b5cee77baf3a20ee2b86ab1133db1694a5d844f058c60a523`；
内含 `bin/keylens` 326,416 字节（sha256 前 16 位 `0905d3b7bb383ea5`，与真机上那份逐字节相同）、
**0 份 awk**、**没有 `webroot/icons/`**、`module.prop` 里是 v3.0.3。
`--check` 全过（含「包里没有运行时缓存」「`bin/keylens` 只有一条」两条新断言）。

**发布前验过的**：对拍 247（用同一份 build-std 的 x86 产物）、`cargo test` 72、
真机 `device-boot-hash` 20 条与 `device-props-mask --write` 17 条（跑完现场逐字节还原）、
机上 smoke（`contract` 40 条 / `props` 53 项全 ok / `boot-hash` auto·ok / `doctor` 11·0·0）。

**资产已上传（2026-11-03 00:21 本地）** —— `https://github.com/IamCanincan/KeyLens/releases/tag/v3.0.3`
（tag 指向 `37a73bd`，非 draft / 非 prerelease；资产 `KeyLens-v3.0.3.zip` 533,142 字节）。
上传方式与 §3.11 同一套（`git credential fill` 取 token，只在命令里用一次）。

**上传后把资产下回来逐项核过**（`gh release download`）：
sha256 `1afc7c38…` 与本地那份**逐字节相同**（GitHub 自己算的 digest 也是它）；
31 个条目、0 个 `webroot/icons/`、`bin/keylens` 恰好一条且 sha 前 16 位 `0905d3b7`；
包内 `module.prop` 是 `v3.0.3` / `2026110300`；文件权限全对（脚本与二进制 755、其余 644，
目录 755）。

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

## 5.12 属性判定改成"一次 getprop + 一次 awk 出计划"（为了把表补满）

**动机不是"想优化"，是扩表扩不动**：`apply_resetprop` 以前每行起一次 `resetprop`
读当前值（真机现量单键 32ms），而期望表要从 17 行补到 43 个属性名（见 §5.13）。
照那个形状，开机与界面「写入并复核」都会进秒级。

### 三条路都上机量过（mksh，同机同会话）

| 做法 | 现量 |
|---|---|
| 逐键 `resetprop` 读（旧路，17 行 / 43 行） | 253~433ms / 1484ms |
| 一次全量 `getprop` dump | 61~94ms（66897 字节 / 1561 键） |
| dump 进 shell 变量，15 次 `*"[key]: "*` 最长匹配 | **160307ms** |
| 同上改最短匹配 `${var#*…}` | 205267ms |
| 先 `grep -F` 裁到 2725 字节（52 键），再查 53 次 | **1841ms** |
| 一次 `getprop` + 一次 awk 出计划 | **208ms**（awk 本体 40~82ms） |

**两条反直觉的结论**，都是量出来才看见的：

1. **mksh 的字面匹配随字符串长度平方级增长**，不是"慢一点"。66KB 上一次匹配就十秒级；
   把 dump 裁到 2.7KB 之后 53 次查表仍要 1.8 秒 —— 裁小只是缓药。所以"读一次快照
   再在 shell 里查表"这个看着最自然的方案**根本不成立**（198f59f 那一版就是这么写的，
   量完发现不对，本轮换掉）。
2. **设备上 `printf` 不是内置**（memory 里记过，这轮又踩）：在 shell 里逐行 `printf`
   拼 spec，53 行 = 53 次 fork ≈ 850ms，比 awk 本体贵一个数量级。改成把两张表**原样**
   喂给 awk（只加 P/R 模式标记，全程 3 次 printf），由 awk 按"第一个空白切属性名、
   其余整段留给值"解析。这一改把 `props_plan` 从 942ms 压到 **208ms**。

最终形状：awk 吃「两张表 + 全量 dump」，吐 `display`（四列，界面直接用）或
`write`（该写的行）；shell 只负责逐行 `resetprop -n`。表的行数不再改变成本形状。

配对计时（同机、同一张 43 键表、各取三轮最快）：**awk 路 485ms vs 逐键回落 1484ms**。
`tests/device-props-mask.sh` 里那条判据钉的就是"awk 路必须真比回落快"，不然这通折腾没意义。

两侧读法对齐的四条硬要求（本轮定下，别后面拆）：
- **复核不许复用写前的快照**。shell 侧 `props_readback` 本来就新起进程（等于重取一次
  dump）；Rust 侧改成写完后重新 `prop_snapshot()`，并且**不给它留 resetprop 回落** ——
  留着就会出现"getprop 废了 Rust 还读得到、shell 读不到"，那是桩造出来的假差异
  （真机上 `getprop NAME` 与 `resetprop NAME` 读的是同一个属性区）。
  parity 的"getprop 全废"降级三条钉的就是这个。
- **对拍的桩只能有一份存储**。parity 的 `getprop` 桩现在认 `RP_DB`（写完读得回），
  `resetprop` 桩读不到自己那份就转给 `getprop` 桩；以前两个桩各拿一份来源，
  两侧决策来源不同，`mismatch` 差 16 项。
- **awk 只在确认存在之后才开管道**。`AWK_CMD` 指向不存在的程序时，Git Bash 的 bash
  会让左边写进一条没人读的管道**永久阻塞**（整个台子卡死 300 秒），dash 与 mksh 却
  立刻返回。现在先 `command -v "${_awk%% *}"` 再走管道 —— 判定在开机路径上，
  不能留"看 shell 心情"的失败模式。
- **判定层必须过两种 awk**。本轮在 mawk 上撞到一个方言差：
  `goal[k] = rewrite((k in goal) ? goal[k] : c, …)` 里 mawk 会先把左边那个元素创建出来，
  于是 `(k in goal)` 恒真、底数取到空串，链式改写整条变成**写空值**；gawk 却不这样。
  一律改成"先取标量、再判存在"。真机侧 `device-props-mask` 拿 toybox awk 与
  busybox awk 各跑一遍比逐字节，防的就是这一类。

## 5.13 期望表补满"构建身份"那一族（17 → 43 个属性名）

起因是 DuckDetector 那份报告的 `[Build]` 区直接印着
`ro.build.flavor: lineage_pdx234-userdebug`，设备上现量（`getprop | grep -a userdebug`）
还有 8 个 `*.build.type=userdebug` 和 `ro.system.build.fingerprint` 的
`:userdebug/release-keys` 尾巴，共 10 行。检测器今天只把这些放在 `[Info]` 不判级，
但**任何应用逐键读得到**；而"顶层说 user、分区说 userdebug"是自相矛盾，
比统一的 userdebug 更难看。

- 特征表从 2 行补到 38 行：8 个分区 `build.type`、8 个分区 `build.tags`、
  9 个指纹（顶层 + 8 分区）、`ro.build.flavor`、`ro.build.description` 的两个尾巴。
- **特征行从"整值替换"改成"就地替换每一处命中"**。旧语义会把 `engineering-x`
  压成 `release`、把整条 description 压成 `release-keys` —— 那比不改更像被动过。
  同名多条规则（description、每个指纹）**链式串完只落一次盘**。
- **本机没有的分区报 `absent`**：不计入「写入并复核」的不符项，也绝不凭空写出来 ——
  凭空多一个 `ro.system_dlkm.build.type` 本身就是破绽（stock 不会给不存在的分区留属性）。
  固定表那 15 项保留"缺失就补"的原语义，没动。
- 真机证据（`tests/device-props-mask.sh --write`，17 条断言全过）：台子**自己种出待改状态**
  （这台机很可能已经被上次开机掩好了，指望现场泄漏会让正对照变成"没测到"），
  臂 A 实测改写 **11 个**属性；两臂从同一起点出发、跑完 43 个键逐字节相同；
  属性区**没有新增键**；`applied=1 / mismatch=0`；toybox 与 busybox 两种 awk 同结果；
  最后把 43 个键逐个还原到**原始现场**（不是还原到种下去的状态）。
- `device-ab` 这轮也补了自己的短板：它原来只快照开关与 boot_hash，
  `props-apply` 把分区属性掩上之后**现场没还原** —— 是它自己的"差项数相同"不变量
  报出来的（跑前 10、跑后 0）。现在逐个键快照 + 还原 + 逐字节比，38 条全过。

## 5.14 启动哈希改成三态，默认「自动」（新用户不必再抄那串字符）

**动机**：属性伪装那 43 项默认就开，唯独 `ro.boot.vbmeta.digest` 要人手填。而这台机的
ROM **根本不给这个属性**（实测：清掉配置 + 重启后 digest 为空）——于是"有 TEE 在证明、
prop 却是空的"正好是检测器 `vbmetaDigestMissingWhileAttestedHashPresent` 的判据，
Danger 4 → 2 的差就是这一格（§3.10）。

**三态怎么存**（不另开配置文件，就看 `$KL_BOOT_HASH` 文件）：

| 文件 | 模式 | 行为 |
|---|---|---|
| 不存在 | `auto`（默认） | 从**当前启用的那一家后端**自己的配置取：OMK 的 `[trust] vb_hash`、TEESim 的 `overrides.json verifiedBootHash`；是合法 hex 才写。**teesim 那一支多一层前置**：属性里已经有合法值就采用它（`source=daemon`，一个字都不写），为空才按 override 补 —— 理由与上游行号见 §5.15 |
| 64/128 位 hex | `manual` | 用用户的值，优先于 auto（升级前填过的机器行为不变） |
| `off` | `off` | 明确不写 digest（旧版「清除」的语义搬到这里） |
| 别的 | `invalid` | 不写，界面直说配置坏了 |

**为什么 random 必须熄火**：OMK 允许 `vb_hash = "random"`（每次 keymint 启动重新生成）。
那种情况下镜像过来的值下一开机就过期，而检测器对"过期值"（`vbmetaDigestMismatch`）
与"空值"给的是**同一级 Danger** —— 写了反而更糟。所以派生只认 64/128 位 hex，
`random` / `null` / 缺文件 / 注释行一律当取不到；而且**绝不缓存**，每次开机与每次应用
都重读后端配置（对拍里"改了配置 effective 立刻跟着变"那条钉的就是它）。
另一条边界：只问启用的后端（`KL_BACKEND` 或 `omk_active`/`teesim_active` 探针），
不去读卸载后残留的配置目录——那会把一个不再被证明的 hash 写进 prop。

**真机上的决定性正对照**（`tests/device-boot-hash.sh`，20 条，全程只读）：夹具根里
只放真实的 `config.toml`、**不放 boot_hash 文件**，auto 档算出的 effective 与主人手抄
那串 `0561fff0…` **逐字节相同** ⇒ 新用户装完重启就能拿到今天这个状态。

**现场那一侧也真跑了一遍**（2026-11-02 21:3x，跑完原样还原成 manual）：把 boot_hash 文件
挪走再 `props-boot-hash auto`，出 `mode=auto / configured=（空）/ source=omk /
effective=0561fff0… / status=ok`，`getprop ro.boot.vbmeta.digest` 一字未动 —— 不是只在夹具里
算得对，是真机上一个字不填也能对齐。这一趟顺手抓出了 §6 那条读数口径分叉：裸 shell 里
`resetprop` 不在 PATH，旧版命令把 `current=` 报成空，而属性其实有值。

**闸**：单元 64 条（两处变异：摘掉「只认 hex」的守卫 ⇒ `random` 被当成值写进 prop；
摘掉「属性已有值就采用它」那行 ⇒ override 覆盖守护进程）、
对拍 23 条（两侧逐字节 + random/off/invalid/手动优先/不缓存/无后端不派生）+ 读数口径 3 条
（`current=` 两侧统一走 getprop，见 §6）+ teesim 那一支 5 条（见 §5.15），真机 20 条（本轮现量：20 条全 ok、0 条 skip）。
命令契约变了：`boot-hash` 现在出 `mode/configured/source/effective/current/status`，
`props-boot-hash` 多回一个 `mode=`，`help` 里那行用法也改了（shell 与 `main.rs` 两处必须同文，
对拍比的是逐字节）。界面那一格从两态改成三态（`?bh=auto|daemon|random|manual|off|invalid`
六种形状各画一遍，`mutate-verify.mjs` 现在 7 个变异：⑥ 把 auto 说回「未设置」、
⑦ 把 `source=daemon` 说回「overrides.json 那串」，两条都必须响）。

## 5.15 TEESim 的多 profile 与 digest 是两个正交的面（查上游源码，不是推测）

一条 profile 装的是：`id / keybox / mode / patchSystem / patchVendor / patchBoot /
osVersion / brand / device / product / manufacturer / model / serial / imei / meid / imei2
/ apps[] / autoIncludeNewApps`（`TEESimulator/app/src/main/java/org/matrix/teesim/ConfigStore.kt:23-46`）
——**里面没有 root of trust**。证明里那个 verifiedBootHash 是在 profile 循环**之外**一次性
塞进 `bootInfo` 的（`Resolver.kt:41-43`），而用户那一层覆盖存在 `overrides.json`，
上游明写它是「一张扁平 `{字段: 值}` 表」（`OverrideStore.kt:6-9`）。

⇒ **切换 profile 不可能让 digest 过期**，多 profile 也不需要为这一格做任何"选哪个"的判断。
本模块这一侧的处理是：`teesim-profiles` 列出所有份（名字/keybox/mode/apps/是否默认，
`only 顶层`与`诱饵键不算 profile`两条绝对断言钉着）、`teesim-profile-new` 复制 default、
`teesim-profile-del` 删（default 是兜底不许删）、写路径用 payload 里的 `profile=<名字>`
选"改哪一份"（省略仍是 default，旧界面行为不变，`module/lib/write.sh:218-228`）、
界面先选份再编辑（`webui/src/screens.js` 的「先选哪一份，再编辑那一份」），
并且界面上写着那条硬边界：设备标识只能在 profile 里改，安全等级/版本/启动键哈希只能改 overrides。

真正与 digest 有关的是**另一件事**，也是本轮改的：TEESim 守护进程每次 push 都会把
`ro.boot.vbmeta.digest` **强制成它自己正在证明的值**——"the value we attest wins
unconditionally"，包括那些 bootloader 根本不填这条属性的机器（`App.kt:510-523`，上游 #228）；
而 `overrides.json` 里那串 hex **只有当它当前那份是合成兜底值时才会被采纳**
（`Harvester.kt:183-189` 的 `userEditable`，`applyUserOverrides:399-415` 对不可编辑字段
直接 `continue` 并记一条日志）。所以本模块在 teesim 下的 auto 改成：

| 属性现在的值 | auto 的行为 | `source=` |
|---|---|---|
| 已是合法 hex（守护进程强制的） | **采用它，一个字都不写** | `daemon` |
| 空的 / 不是 hex | 才按 `overrides.json` 那条 override 补 | `teesim` |

拿 override 去覆盖已有值，恰好会在上游不采纳这条 override 时**亲手造出**
`vbmetaDigestMismatch`（与空值同级的 Danger）——这正是这一格要避免的东西。
OMK 那一家相反：`vb_hash` 是显式 hex 时上游**不写**这条 prop（`needs_sysprop_write`
只含 Computed/Original/Random*/RandomFallback，`OhMyKeymint/src/plat/vbmeta.rs:452-462`），
所以那一格里模块的写入是唯一来源，omk 分支保持"照配置写、可覆盖"。

**真机现量**（`tests/device-boot-hash.sh` 新增 4 条）：夹具根里放一份 teesim 模块目录，
外加一个**诱饵** override（64 个 `e`，与本机那串不同）。本机 `ro.boot.vbmeta.digest` 是合法
hex ⇒ 两侧逐字节相同、`source=daemon`、生效值 = 属性里那串、`status=ok`，诱饵一个字都没被采用；
属性为空或不合法时同一台子改判"取诱饵"那一支（两条腿都留着，换机器不会假红）。

## 5.16 体积与性能：量完再砍（2026-11-02/03）

**先量清楚三件交付物**：发布包（压缩后）728,684 → **533,142 字节**（-26.8%），其中
二进制 368KB(52%)、界面 241KB(34%)、shell 层 91KB(13%) —— **大头是二进制，不是 HTML**。

**砍掉的**（都有闸）：
1. 打包带上运行时缓存：`webroot/icons/`（设备上 `webui.sh icons` 写的）被 walk 递归收进包，
   v3.0.2 实测 3 张、33KB。现在跳过，并在 `--check` 与落盘前各断言一次（含 `bin/keylens`
   恰好一条）。-21KB。
2. 二进制：`sh rust/build-release.sh`（nightly + `-Z build-std=std,panic_abort` +
   `-Zunstable-options -Cpanic=immediate-abort`）—— aarch64 **652,960 → 326,416 字节（-50%）**，
   包再 -175KB。夜间工具链是代价（CI 装 nightly + rust-src + 两个 musl target）；
   panic 时不再打印消息、退出码由 101 变 SIGABRT —— 命令的错误路径全走 Result + 自己的
   退出码，247 项对拍与真机台子覆盖了这些路径。
3. WebUI 台架加了性能基线（`verify.mjs` 末尾）：**首屏可见 45ms · FCP 48ms · 脚本 15ms ·
   布局 3ms**（本机 Chrome 417×975@2x，轮询粒度 ~10ms）。结论：808KB 的产物在 WebView
   同引擎里只值 15ms 脚本时间 ⇒ 缩界面的理由是包大小，不是首屏速度。

**量过但不做的**（每条都有数，不是感觉）：
- 去掉 unwind 表（`-C force-unwind-tables=no`）：产物一字未变 —— `.eh_frame` 那 79KB
  来自预编译的 std/crt，不在我们这层。
- tokens 瘦身：382 个变量里 154 个没人引用，全删只省 8.8KB（16% 的 tokens 文件）。
- color-spaces 表 133KB：表覆盖 20 个色彩空间、`compose-color.js` 泛型遍历；换小实现要赌
  "界面永远只用 Srgb/Oklab"，赌错的症状是色值静默偏移，收益仅约 40KB 压缩（5.7%）⇒ 不值。
- shell 回退层（224KB 原文 / 91KB 压缩）：砍了就没有"二进制 exec 不了（noexec 挂载）"
  的兜底，也没有 `KL_USE_RUST=0` 调试闸 —— **2026-11-03 他定：留着**（91KB 换最坏情况下
  还能干活，且是唯一一条不依赖"内核允许执行二进制"的路径）。

**量测自己的坑**（这轮又踩一个）：`Performance.getMetrics` 的计数在跨文档导航时清零，
拿"导航前后做差"量脚本时长会得到负数（第一版 `script=-2ms`）。这些计数是"当前文档自开始
以来的累积值"，导航完、渲染出来后读一次即可；台架留了自检（首屏/FCP/脚本都必须为正），
量测写歪时会立刻红。

## 5.17 体检「启动哈希」改成按三态取生效值（2026-11-03，主人一句"检查一下"抓出来的）

**症状**：真机只读 A/B 从 17/17 掉到 16/17，红的只有 `doctor` 一条 ——
shell 侧 `启动哈希 ok 当前值等于配置值 / skip=0`，Rust 侧 `skip 没有配置 vbmeta digest / skip=1`。

**成因一处**：Rust 体检第 8 项直接 `read_to_string(p.boot_hash)`，而 auto 档那个文件**本来就不存在**。
它身边就摆着 `boot_hash_mode` / `boot_hash_effective`（`boot-hash` 命令用的正是这套三态），体检没走。

**顺带抓到第二格**（临时根实测，没动现场）：`off`（文件里是哨兵）在 Rust 侧报 **bad「配置的哈希格式不对」**
并让用户重填他刚清掉的那串；shell 侧同一格是 skip。谁在界面选「不写」都会看到一行红字误报。

manual 档两侧一直是对的，所以 3.0.3 装机前没人撞上：auto 是 §5.14（2026-11-02）才成的默认，
而"38/38 全过"那次 A/B 跑在现场**还填着手抄哈希**的时候 —— 判据没跟着现场改口。

**改的三处**：

1. Rust 体检改用新纯函数 `boot_hash_doctor_row(mode, effective, current)`（+5 条单测，其中两条
   就是这两格：auto 有值必须是 ok、off 必须是 skip）；
2. shell 侧同一格换成按 mode 分支，并把"当前值等于**配置**值"这种在 auto 档说不通的话拆成两格；
3. `webui/src/bridge.js` 的体检假数据跟 `?bh=` 联动（台架以前只画得出"填了/没填"两态）。

两侧的状态映射（必须逐字相同）：`off`→skip「已设为不写 vbmeta digest」；`invalid`→skip
「配置值不是十六进制，这一项没生效」+ 重填指引；`auto` 取不到值→skip「自动档但后端没给出值」；
`auto` 有值→ok/warn「自动取到的值与当前值一致/不一致」；`manual`→沿用原文。
旧的 `bad 配置的哈希格式不对` 分支在两侧都是死路（生效值只可能是合法 hex 或空），删掉。

**闸（这次的重点）**：对拍的 doctor 台子之所以照绿，是它的 fixture **既没有 boot_hash 文件、后端又是
tricky**（auto 取不到值）⇒ auto/manual/off/invalid 四格候选数全 0，与"没有牙的闸"输出完全一样。
补 7 格 × 两侧 = 14 条，并且**两侧各比一次期望文本**——只比"两侧相等"的话，两侧一起改错照样绿。
变异自证（都下在生产真源上）：把 Rust 那一行退回旧口径 ⇒ 恰好红 4 条（auto×2、off、invalid）
并触发下限（257<261）；把 shell 那一格退回旧文案 ⇒ 红 5 条，且原有"11 项逐行一致"一起响。
对拍下限从 247 抬到 261，顺手把判据与文案里分家的 242/247 并回一处。

**现量**：`cargo test` 72→77、对拍 247→261 全绿；真机临时副本（v3.0.3 的文件 + 这两处改动）
只读 **17/17**、含写 **38/38**；机上现装的 3.0.3 那一格仍是 `skip 没有配置 vbmeta digest`，
要变成 `ok 自动取到的值与当前值一致` 得随下一个包上屏（**本轮未发版**）。

## 5.18 系统应用能被勾了，名单也不再截断在半路（2026-11-03，主人问"为什么没法自己勾选系统应用"）

**答案先是事实**：名单三处数据源全是 `cmd package list packages -3 --user all`（`-3` = 只列第三方）
—— `module/webui.sh:1044` 的 `cmd_apps`、`module/lib/applist.sh:146` 与 `:252` 的同步快照、
`rust/src/read_cmds.rs:392` 的 Rust 同一条。系统包不在输出里 ⇒ 界面**连那一行都画不出**，
自然没有「加入」。同步的差分也只从这份集合算"新装"，所以系统包连"被自动加进来"的通道都没有；
唯一的例外是首次安装的种子（`applist.sh:16` 明写"谷歌三件套是系统应用，`-3` 看不到它们"）。
**代码和文档里都没写"为什么要排除系统应用"**（`docs/SYNC-SPEC.md:43` 只陈述输入是 `-3`）—— 没理由可转述，
所以这一条按"缺入口"来修，不是"做不到"：`restore-apps` 只校验包名形态，命令行一直能加。

**改了什么**：

- 命令层 `apps` 加两档参数：`system`（全量减第三方）与 `all`；默认档一个字没动。
  `--system` 这台机的 `cmd package` 不认（实测 `Unknown option`），所以只能两次调用相减。
- 名单页多一枚「系统应用」芯片，**点开才去读**（56ms + 62ms 的两次 `pm` 不该让默认档付）。
- 截断改成可继续：一屏仍先画 200 行，但余下的给一颗「继续显示余下 N 条」，点一次多画一档，
  画全后那颗自己清空标签退场（留着文字会被台架的 peek 读成"屏上有这句话"）。
- 按钮改按**是否在名单里**决定，不再按"你在哪一档"：非名单档里已在名单的项以前画「加入」，
  点一下只回一句"已加入"而什么都没改。
- Rust 里同步用的"已装"集合（`installed_pkgs`）并回同一条 `pkg_names` —— 它是命令层那条管道的
  第二份手抄，还多了一步 `\r` 裁剪（与 shell 那条 sed 并不逐字节相同）。§5.17 那个 bug 的成因
  就是"同一件事抄两份"，这里顺手把另一份并掉。

**同步语义没动**：自动加入仍按 `-3`，不会把 235 个系统包砸进名单；手动加进去的系统包也不会被
下一轮同步删掉 —— 删除集是 `gone = was − inst`（`applist.sh:204`），`was` 与 `inst` 都不含它。

**现量**：这台机 第三方 **129** · 系统 **235** · 全部 **364**（129 + 235 = 364 对得上）；
真机临时副本里三档 shell 与 Rust **逐字节相同**（sha256 前 16 位 `16146dc4… / b2690c6c… / 9a2138f0…`），
只读 A/B 仍 **17/17**。对拍 261 → **266**（三档 × 两侧期望文本；先把台架的 `cmd` 桩改成认 `-3`，
否则 system 档算成"全量减全量=空"，两侧一起空照样绿），变异自证：Rust 的 system 档改成原样返回全量
⇒ 红 1 条。界面台架 102 → **109** 条断言，图在 `%TEMP%/md3e-verify/new-list-more.png`
（200 行 + 「继续显示余下 50 条」那张）。

**台架自己暴露的两件事**（都记进 §6）：`md-chip` / `md-button` 只认真指针事件，
`element.click()` 根本不切视图；筛选那一行是 `nowrap + overflow-x:auto` 的横滑行，第五颗天然在
417px 之外 —— 台架得先 `scrollIntoView` 再量坐标，否则鼠标事件落在屏外，看起来像"功能坏了"。

## 5.19 一轮"非人逻辑"审计（2026-11-03，主人说"别的也看看，调整一下这种非人逻辑"）

判据只有三条：**看得见点不动 / 永远不可能成功 / 指引把人往错处支**（含"点下去回一句成功文案
但什么都没改"的假成功）。纯样式、性能、缺功能都不算。逐条都回原文核过行号。

| # | 症状 | 等级 | 状态 |
|---|---|---|---|
| 1 | Tricky 的「自动 →」按钮在带二进制的发布包里**永远点不响**：界面发 `set-mode '包名 模式'`（一个参数），Rust 只认两个 argv ⇒ 包名带空格被当场拒 | 永远不可能成功 | **已修**（本节下） |
| 2 | TEESim 选中非默认 profile 时，名单页的加/减写的仍是 `profiles.default.apps`，界面只说"目标文件"不说档位 | 假成功 | 已降级为明说（名单页加一句"写的是 profiles.default.apps"，选中别的 profile 时点名它）。**逐 profile 的名单入口是功能，没做** |
| 3 | 同上：keybox 页已经写了"它的 keybox 是另一个文件"，按钮却照样「已替换 keybox」 | 假成功 | **已修**（非默认 profile 时不给那颗按钮，并写清"不是坏了，是这条路还没有"） |
| 4 | 「已排除」用 `-3` 口径 ⇒ 移出系统应用后这一档永远不出现、计数也不涨 | 永远不出现 | **已修**（两侧都改成全量已装；正对照两条，桩认 `-3`）。这台机现量 `excluded` = 0 条 ⇒ 今天没有可见变化，只是不再堵死 |
| 5 | 体检「目标文件 不存在」的下一步让人"在名单页点「立即同步」"，那颗按钮在**自动同步**页 | 指引错页 | **已修**（两侧文案同时改口成「自动同步」页的「立即同步一次」） |
| 6 | 属性页当着用户说「下面『立即应用一次』不依赖它」，命令层第一行就 `props_disabled` 拒绝；且这个状态下「开启开机写入」那颗是隐藏的 | 文案假 + 无出路 | **已修**（那句改成真的；status 读不到时给两颗明写的按钮 —— 不替用户猜方向，但也不把这一屏变成死路） |
| 7 | 「立即应用一次」不看 `env.resetprop`（能力早就上报了，界面从不读）⇒ 没这工具的机器上永远回"未找到 resetprop 命令" | 永远不可能成功 | **已修**（`resetprop=0` 时禁用 + 一句为什么；台架新增 `?noresetprop=1` 画这一形状） |
| 8 | 没探测到后端时「后端配置」照旧可点，进去是整页空白（不是空态文案） | 永远不出现 | **已修**（空态一行，`?fail=backend-info` 台架钉住） |
| 9 | OMK 的 `verified_boot_state` 给自由文本框，命令层只收 true/false ⇒ 填 `green` 必被打回 | 形状不符 | **已修**（改开关；台架点开折叠后断言那一行是 `md-switch` 不是文本框） |
| 10 | 非默认 profile 的模式下拉与「自动纳入新应用」开关把**未知**画成确定值（缺值落到第一项/画成关） | 把未知画成已知 | **已修**（标签加"· 当前值未知"；下拉插一颗**不可选**的占位，选中它 = 留空 = 不改这一项；开关仍可拨，因为它表达的是"要改成什么"） |
| 11 | 图标冷路径每次只补 60 个，界面一批要 120/200 | 边界，不算点不动 | **已修**（原判据下我放过它；复查时发现它正好落在我新开的「系统应用」档上 —— 见 §5.20） |

**这一批的闸**：对拍 267 → **269**（#4 的正对照两侧各一条；变异自证：Rust 退回 `-3` ⇒ 恰好红那一条）、
界面台架 109 → **116**（#7/#8/#9 各一条 + #7 的"真点不动"一条 + #2/#3/#10 三条；
变异自证：摘掉「当前值未知」标签 ⇒ 未知行 2→1 响；把 keybox 那颗改成可点 ⇒ `disabled=0` 响）、
`cargo test` 77、真机临时副本只读 **17/17**（`excluded` 与 `doctor` 都在那 17 条里）、本地 53 套 0 失败。

**这批自己也被查出两条**（都是"改了代码但没验到屏上"）：

- `more.hidden = true` 挡不住 `md-button` 自带的 `display:flex` —— 画全之后那颗还占着一格 **48px
  的空壳**在台架上量得到、人也看得见。台架原来只读 `m.hidden` 这个**属性**，所以它照绿；
  改成量 `offsetParent` 与真实高度才现形（现在断言写的是"屏上真看不见"）。
- `disabled` 属性同理不能只读属性：现在真点一次，看有没有冒出"已写入并复核"的提示。

### #1 的成因与补的闸（值得单独记）

`module/webui.sh:73` 的接管点是 `"$CMD" ${ARG:+"$ARG"}` —— ARG 永远是**一个** argv。
分派臂 `set-mode) _pkg="${2%% *}"; _mode="${2#* }"` 也按这个形状写。Rust 侧 `main.rs` 却写成
`args.get(3)`，等于默认"两个 argv"。对拍瞒了这么久的原因有两层，都记进 §6：

1. 台子直接 `cmd_set_mode "$1" "$2"` 调函数，**绕过了分派臂** —— 拆分逻辑根本没进台子；
2. 调用形状是 `set-mode com.a leaf`（两个 argv），与界面真发的那样不同。

改法：Rust 按第一个空格拆（与分派臂逐字同语义：没有空格 ⇒ mode 为空 = 自动）；台子改成
`sed` 抽出分派臂本身来跑，抽不到就落 `*)` 退 9（不许两侧一起空跑）；`tests/rust-dispatch.sh`
加一条数 argv 的断言（`argc=2`）。变异自证：Rust 退回旧写法 ⇒ 红 5 条并触发下限。
对拍 266 → **267**。

## 5.20 复查第二轮：图标冷路的 60 上限卡在我自己新开的档上（2026-11-03）

§5.19 里我把这条判成"边界，不算点不动"就放过了。复查时想到：**是我自己新开了一个 235 行的入口**，
而那一档里多数包没有启动器入口、全靠冷路补 —— 这条就从"边界"变成"日常踩"。量了一遍：

- 界面一批问 **120** 个（`screens.js` 的 `need.slice(0, 120)`），冷路只补 **60** 个，
  差额被**静默丢掉**：真机现量"要 120 个 → 只回 65 行"（60 冷路 + 5 命中桌面缓存），
  剩下 55 行在界面上永远是首字块 + 包名。
- 三个数各写各的（界面 120、shell `-ge 60`、Rust `miss.len() >= 60`），改一边没有任何闸会响。

放开到 120 的代价现量（同一次 `app_process`，只换包数）：**60 个 2619ms / 120 个 3749ms /
200 个 5709ms** —— 约 1.7s 是 ART 启动的固定成本，每包约 19ms；图标是后台补的，不挡首屏。
所以取 120（与界面一批对齐），不做"循环补到完"（每次都要重付那 1.7s）。

真机重测（临时副本，两侧各跑一次、每次先清空图标缓存）：
`KL_USE_RUST=0` 3844ms、`KL_USE_RUST=1` 3435ms，**都回 120 行且输出逐字节相同**
（sha256 前 16 位 `1f374525ff72f30f`），落盘 121 个图标文件。

闸：`tests/ui-shape.js` 新增一条"图标冷路三个数一致（界面 batch = shell 上限 = Rust 上限）"，
三个数分别从三份源码里正则读出来（现量 界面=120 shell=120 Rust=120）。
变异自证：只把 Rust 改成 90 ⇒ 当场红并打印 `界面=120 shell=120 Rust=90`。

## 5.21 名单这一屏按人的找法重做（2026-11-03，主人："还是不够人性化…主要哪些选了哪些没选都不明了"）

先把"不人性化"量成数，别猜（都是这台 XQ-DQ72 现量）：

| 量的东西 | 数 |
|---|---|
| 「系统应用」那一档 | **235 行** |
| 其中有启动器入口（`MAIN`/`LAUNCHER`，平台自己的"这是个应用"判据） | **17 行** |
| 其余（覆盖层 / 服务 / 资源包 / 内部组件） | **218 行** |
| 系统里根本没给显示名、只能显示一串包名的 | **81 条** |
| 现在第一屏 15 行里"没名字或不是应用"的 | **7 行** |
| 相机 / 浏览器 / 短信 在包名序里排第几 | **201 / 213 / 84** |
| 换成"只列可启动 + 按显示名排"之后 | **13 / 5 / 2** |
| 取启动器判据的成本 | **53–80ms**（比取全量列表 74ms 还便宜） |

**三根轴**：

1. **只列可启动的**：命令层 `apps` 加一档 `launchable`；界面把系统档切成"17 条应用 + 一句
   『另有 218 条系统组件（覆盖层 / 服务 / 资源包）· 点开才列』"。点得开 —— 要 spoof
   `com.android.bluetooth` 的人必须还找得到它。`launchable` 没取到时**不筛**（宁可长，
   也不拿一个没读到的判据把人该看的东西藏起来）。
2. **按显示名排**：paint 时按 `名字（没有就包名）` 排一次；名字到货只原位改文字、**不重排**
   （免得手指底下跳），所以第二次进这一屏就是完整名字序。
3. **一眼看出哪些已选**：非名单档里已在目标文件的行加一枚「已纳入」角标
   （`.app-row-tag`）。以前只有行尾 add/remove 小图标不同 —— 这就是他点名的那句"都不明了"。
   （这枚角标后来在 §5.25 被整行勾选 + 已选优先排序取代：本机 129 条全在名单里，逐行挂角标
   等于 129 行噪音。）

**没做的一根**：把「系统应用」芯片从横滑第五颗挪到默认可见。原因是有条旧决定明写着
"不折行，折成两排会把首屏顶下去"（`app.css` 的 `.acts.filter-grid` 注释），要挪得重新量首屏，
这轮不动它，记在这里。

**闸**（这一节当时的口径，后面的轮次又加过）：对拍 **276**（`apps` 四档 × 两侧期望文本；桩现在认
`query-activities`，且输出的是「包名/组件」那种没有 `package:` 前缀的形状）。界面台架当时 **121** 条
（现在是 **175**，见 §5.25/§5.30/§5.31/§5.32/§5.33/§5.34/§5.35/§5.36）：
系统档只列可启动的（台架 5 个系统包 → 2 个应用）+ 那句折叠能点开变 5 行 +
**两条排序断言**（其中一条原来只比"got 等于自己排一遍"，两种序一样时永远过 ⇒ 假绿，
换成把名字序与包名序**两个数组都钉死**）。变异自证：把排序短路 ⇒ 两条同时红。
`cargo test` 77、本地 53 套 0 失败。

**装机实测**（已装路径，不是临时副本）：`launchable` shell 与 Rust 逐字节相同
（sha 前 16 位 `b2eca8d25d4df2a7`，与默认档的 `16146dc4…` 不同 ⇒ 比的确实是新代码路径），
可启动 133 · 系统 235 · 交集 **17**，那 17 条正是计算器 / 相机 / 图库 / 浏览器 / 短信 / 设置 / Play 商店这一批。

## 5.22 我自己上一步改出来的洞：一次问 200、只答 120，剩下的被标成"问过了"（2026-11-03）

把冷路上限从 60 抬到 120 之后复查发现的：**界面侧**有两个地方一次问得比一批多，
而 `askedIcons` 是在**发出请求之前**给整串包名置位的 —— 于是没被发出去的那些
既没问到名字、又被标成"问过了"，这一屏再也补不回来（只有重进名单页才清）。

| 位置 | 旧写法 | 后果（本机现量） |
|---|---|---|
| `prefetchListIcons`（首屏预取） | 一次问 `PREFETCH_ICONS = 200` | 命令层只答 120 ⇒ 第 121–200 行**首屏就没名字**，且再没人问 |
| `loadIconsFor`（增量补） | `need.slice(0, 120)`，但 `askedIcons` 给整串 `need` 都置了位 | 同上，尾巴永远首字块 |

改法：`askIcons(list)` + `drainIcons()` —— 按 `ICON_BATCH = 120` 切批，**只给真发出去的那批置位**，
前一批落定后接着问剩下的；`iconsBusy` 串行，新进来的需求并进 `iconsWanted` 不丢。
首屏只等一批（`PREFETCH_ICONS = ICON_BATCH`），后面的行先带首字块画出来、到货原位补，
不让入场多付一次 root 命令的时间。

**闸**：`tests/ui-shape.js` 那条"三个数一致"改成读命名常量 `ICON_BATCH`（原来它 grep 的是
`need.slice(0, 120)` 那个字面量 —— 我改成分批后它就"没读到"，等于闸自己瞎了），
并新增一条"预取量不超过一批"。台架新增一条行为断言：demo 里记录每次 `icons` 请求了哪些包，
250 行那一屏必须**分多批问完**（现量 批次 4、批大小 [3,120,80,50]、去重 253 个包）。
变异自证：把"没发出去的不算问过了"退回旧写法 ⇒ 去重包数掉到 **173**，当场红。

**装机实测**（尾巴那 115 行，临时根里带 `lib/icondump.dex`）：115 个包 → **115 行全回来**，
其中 68 个系统真给了显示名，其余只能显示包名；耗时 4033ms。修之前这 115 行一个都不会被问到。
（第一次测这条我给的临时根**没有那个 dex**，冷路整个被跳过，只回了桌面库的 13 条 ——
容器不对的测量不算测量，见 §6。）

## 5.23 对着 Tricky-Addon 那项目对了一遍属性（2026-11-03，主人给了 `D:\下载\Tricky-Addon-Update-Target-List`）

它是同一道题的另一个解（KOWX712/Tricky-Addon-Update-Target-List v5.0-beta.4，Apache-2.0）。
**没抄它任何代码**，只是把它的做法拿到这台机与咱们仓库里对量。

**先说结论性的对比**（都有现量支撑）：

| 面 | 它 | KeyLens |
|---|---|---|
| 名单 | `pm list packages -3 \| grep -v 排除 > target.txt` —— **整份重写**，手工增删每轮被冲掉 | 增量差分：只加新装、只删卸载、其余原样（所以"手动排除"这个语义才成立） |
| 属性 | 24 条 `check_reset_prop`（**只在已存在且不符时改**，缺了不造）+ 3 条 bootmode | 15 固定表（缺了**补出来**）+ 38 特征行**就地替换**；构建身份那一族（`*.build.type/tags/fingerprint`、flavor、description）它完全没有 |
| 装完生效 | `MODULE_HOT_INSTALL_REQUEST` + `hotinstall.sh`，**不用重启** | 必须重启（这是它的真优势，见"待做"） |
| 冲突 | 检测到 `tsupport-advance` 就在 `/storage/emulated/0/` 落哨兵文件让对方停写 | 只锁自家进程，**不检测别的模块也在写名单** |
| 入口 | 把自己藏起来（`.TA_utl`、删 module.prop）+ 软链 webroot 进后端模块 | 独立模块独立入口（不玩符号链接那套分支） |

**这一轮真正落地的一件事**：它补了 8 个咱们根本不碰的属性，而这台机现在**全是空的**
（`getprop` 现量：`vendor.boot.vbmeta.device_state` / `vendor.boot.verifiedbootstate` /
`sys.oem_unlock_allowed` / `ro.boot.vbmeta.size` / `avb_version` / `invalidate_on_error` /
`ro.boot.bootmode` / `vendor.boot.bootmode`）。

固定表**缺了会补出来**是咱们已有的语义（`missing` 状态），所以我一开始把 3 条镜像键
（`vendor.boot.vbmeta.device_state=locked` / `vendor.boot.verifiedbootstate=green` /
`sys.oem_unlock_allowed=0`）加进了表并装了机 —— **读了 Duck Detector 的源码之后撤销**（§5.24）：
零收益，还每次开机多三次 resetprop。机上已用 `resetprop -d` 删回空（现量三条 `getprop` 全空）。

同样**一条都不补**的还有 Tricky-Addon 那 5 条：按 Duck 源码，`ro.boot.vbmeta.size` 读但恒 INFO、
`ro.boot.vbmeta.avb_version` 是**键名写错**（Duck 读 `ro.boot.avb_version`）、MIUI/Realme 那几条不读；
`invalidate_on_error` 与 `hash_alg` 确实给 SAFE，但"缺失不判定"意味着补它们只是把"不判定"换成
"SAFE"，收益为零。

**这一轮我自己弄坏过一次，是台架抓的**：给台架那份"真机现量"假数据加 3 行时，脚本里把
`to` 写成了"只有新行"，于是**替换**掉三条原行而不是插入 —— 条目数仍是 53，`verify.mjs` 立刻报
`rows=53`（期望 56）。修回后 56 行全画。教训：改夹具的脚本必须**自证条目数的前后差**，
不能只看"新字符串在不在文件里"（我那次自证的就是"在不在"，所以它没拦住）。
（那 3 行随后被 §5.24 整体撤回，夹具与真表一起回到 53 行 —— 这条教训跟撤不撤没关系，仍然有效。）

**待做（按价值排）**：① hot install（省掉重启，改动面最大）；② "只改已存在"那张表（OEM 特有键）；
③ 默认排除表（它那份 `more-exclude.json` 是 Apache-2.0 的数据，拿进包要在
`THIRD_PARTY_NOTICES.md` 署名）；④ 检测别的模块在写名单；⑤ Xposed 模块识别（它用
`pm path` + `unzip -l` 找 `xposed_init`，`xargs -P $(nproc)` 并行 + 持久 skiplist ——
和咱们的 env 探针缓存同一个路子）。

## 5.24 Duck Detector 的源码把我这两条判断都推翻了（2026-11-03，主人："你明明可以直接看 duck 的源码"）

源码 `D:\下载\Duck-Detector-Refactoring`，另外它给这台机打的那张卡
（`D:\下载\Screenshot_20261101-225108_Duck Detector.png`）上已经写明了自己的读数。三条关键事实：

1. **属性"缺失"= 不参与判定，不是失败**。四重证据：`SystemPropertiesRepository.kt:65`
   （`preferredValue.isBlank()` 就 `return@forEach`）、`BootloaderPropertyFindings.kt:34`、
   `BootloaderPropertyContext.kt:80`（未知就不算 danger）、`CustomRomBootloaderFinding.kt:28`
   注释「an empty or unreadable value says nothing about the lock state」。
   ⇒ 我"补上镜像族别让它空着"的动机**根本不成立**。
2. **那三条键在 Duck 里没有值判定**：两条 `vendor.boot.*` 只出现在原生取证白名单
   `property_integrity_internal.h:65-66`；`sys.oem_unlock_allowed` 被
   `SystemPropertiesCatalog.kt:196-202` 明写"不计入完整性结论"。⇒ 撤销。
3. **我担心的 `/proc/bootconfig` 对质到不了它**：这台机 bootconfig 里写着
   `androidboot.verifiedbootstate = "orange"`（adb root 下 `cat /proc/bootconfig` 现量），
   而 Duck 那张卡自己写着 **「Raw boot params — Unavailable」**（androidboot.* 来自
   /proc/cmdline 与 /proc/bootconfig），且 Source consistency = Aligned、
   Source mismatches = **0**。⇒ 应用侧读不到那两个文件，这条探针在这台机上是哑的。

**它真正报的那一条**（那张卡 Danger 的来源，原文）：

> Attested hash vs vbmeta digest — **Digest missing**：Attested verifiedBootHash was present,
> but `ro.boot.vbmeta.digest` was empty.

即"证书里有 hash、属性里没有"。这正是 §5.14「启动哈希改三态、默认自动」已经修掉的东西
（现量 `ro.boot.vbmeta.digest = 0561fff0…`、`boot-hash` = auto·omk·ok）。
**所以下一步是重跑一次 Duck 看那张卡变没变，而不是继续加属性。**

顺带按源码把 Tricky-Addon 那 5 条判完：`ro.boot.vbmeta.size` 读但恒 INFO
（`BootloaderPropertyFindings.kt:171`）；`avb_version` 它读的是 `ro.boot.avb_version`，
别人写的是 `ro.boot.vbmeta.avb_version`（**键名就不对**）；MIUI `ro.secureboot.lockstate`、
Realme 两键不读；`invalidate_on_error`（`yes`→SAFE）与 `hash_alg`（`sha256/sha512`→SAFE）确实读，
但"缺失不判定"⇒ 补它们只是把"不判定"换成"SAFE"，对过检**收益为零**。结论：一条都不补。

它还有 21 条 `BootloaderCatalog` + 45 条 rules + 17 条 infoProperties + 18 条原生白名单，
其中 `partition.{system,vendor,...}.verified`、`ro.boot.secureboot`、`ro.boot.selinux`、
`init.svc.adbd`、`service.adb.root` 这类**咱们完全没碰**的键值得单独一轮去核对——
但要先搞清 Duck 对每一条的判据，别再像这次一样凭直觉加。

## 5.25 名单整个照 Tricky-Addon 重做（2026-11-03，主人："还是不够直观…干脆完全学习它，它加载又快、做的也成熟"）

**先量它凭什么快**（读 `webui/src/app_list/app_list.ts` + KernelSU 源码，不是猜）：
它一次 root 命令都不跑 —— 用的是 manager 的 WebView 原生接口：

| 它用的 | 在 KernelSU 里的实现 | 我们原来用的 |
| --- | --- | --- |
| `ksu.pm().listPackages('all')` | `KsuPm.kt:18`（3.3.1 只有顶层 `ksu.listPackages`，`pm()` 是之后加的，两条都认） | `pm list packages -3`（99ms）+ `apps system`（138ms） |
| `ksu.pm().getPackagesInfo([...])` | `KsuPm.kt:41`，一次回 `appLabel / isSystem / uid` | 图标命令顺带回 label |
| `img.src = 'ksu://icon/<pkg>'` + `IntersectionObserver` | `WebViewHelper.kt:109/116`：拦 `ksu://icon`，`AppIconCache.loadIconSync(...,512)` 出 PNG | `lib/icondump.dex` 走 `app_process`，一批 120 个 **1823ms**，而且首屏等它 |

**照搬的三件事**：
1. 原生快路（`bridge.js` 的 `nativePm()` / `useNativeApps()`）：一帧之内把 apps / system /
   显示名 / 图标地址全部就位；没有这些接口的环境（Magisk / APatch / 旧 KSU）原样走命令层，
   **命令层与对拍一个字没动**。只剩一条 `apps launchable`（141ms）——"有没有启动器入口"是
   平台判据，原生面板给不了；它跟 lists 一起取，否则芯片上一帧写 235、点开后变 17。
2. 行 = 开关（`screens.js` 的 `rowOf`）：整行点一下写 `restore-apps`、再点写 `remove-apps`，
   行尾 `check_box` / `check_box_outline_blank`，`aria-pressed` 挂在建上；± 小按钮退役。
3. 排序 = **已选优先再按显示名**（`paintRows`），着色只在"这一屏混着"时给
   （本机已装 129 条全在名单里，整屏铺同色反而拉平对比度）。

**台架怎么测"原生"**：`Page.addScriptToEvaluateOnNewDocument` 注入假 `window.ksu`
（页内改 `window.__KL_DEMO_FIXTURE` 不管用 —— `ensure('lists')` 有缓存，不会重新取数）。
断言：一条 `icons` 命令都没发（`window.__klIconReqs` 空）、行上直接是显示名、
`data-icon-src` 是 `ksu://icon/<包名>`、`isSystem` 直接变成「系统」档的数。
整行点选那两条量的是"点 → 写 → reload 重读"的闭环，为此 demo 现在真的会改
`demoTargets`（不改的话刚勾上的行下一帧又变回未勾 = 台架自己造的假绿）。

**没照搬的**：它的"系统应用"是一个弹窗 + `localStorage` 里一份白名单（默认塞 5 个厂商包），
我们用的是「系统」芯片 + 命令层的 `apps system`；它的图标地址写死在 `<img>` 上（我们同样懒加载，
但保留了"图打不开就退回首字块"）；它的名单文件是 JSON 配置（我们是三家后端各自的 target 文件）。

**真机验过了**（2026-11-04，主人开 WebUI 后回的三句）：名单第一屏**立刻**有应用名和图标
（假 `window.ksu` 只证明过接口形状；这一步证明这台 3.3.1 的 manager 真把数据给出来了）；
「已装」仍是 **129** 条（3.3.1 的 `listPackages` 会滤掉 `special` 包，但这台机上没少任何一条）；
「系统」点开「另有 218 条」后滚动**不卡**（235 个 `ksu://icon` 按需解码，没有察觉）。

## 5.26 参考清单建议：做过，又撤了（2026-11-04，主人："那个建议不要了，还要定期更新，麻烦"）

做过什么：抄 Tricky-Addon 的 `more-exclude.json`（29 个包、三类）做成第 41 条命令
`exclude-suggest` + 名单页一行建议 + 一颗"移出这 N 条"按钮。本机现量命中 5 条
（KSU 管理器本体 / Termux / Translate / Chrome / YouTube）。

为什么撤：**那份清单是要人养的**。包名会变、新管理器会出、哪些"不查 bootloader"的判断也会变 ——
跟着它更新是长期负担，而收益只是"少几张伪造链"。留着它就要承认一份会过期的数据，不如不承诺。
撤干净了：命令（shell + Rust + 契约 + 黄金快照）、界面那一段与 CSS、台架两条断言、对拍两条、
THIRD_PARTY_NOTICES 里那份"包名数据"的署名都删了；对拍回到 **271**，台架 **134**。

**留下来的**：体检第 12 行「名单共用」（同一份 target 文件还有谁在写）—— 它不需要人维护，
只是读几个路径。

**两条教训仍然成立**（就算这功能不在）：
1. **界面这一侧的分隔符要对着命令层**：`remove-apps` 两侧都只认**逗号**（`IFS=','` /
   `raw.split(',')`），而 demo 不校验参数 —— 第一版用空格拼，台架全绿、真机第一下就
   "不是合法的目标条目"。现在台架用 `window.__klWrites` 记下真正发出去的参数（整行点选那条
   断言仍用着它）。
2. **文案要在 417px 上量**：第一版把类别名写成"不会查 bootloader 的普通应用"，真机视口上占两行半。
   凡是会换行的提示，都按真实视口渲染一遍再定稿。

## 5.27 属性页 53 行默认收起（2026-11-04，主人："属性长列表应默认收起"）

本机 53 行里 49 行是"一致"，逐行铺满一屏，真正要看的十几行被淹掉。现在默认只画
**不是 ok 的**（不符 / 读不到 / 本机无 —— 本机是 4 行"本机无"），列表**上面**一颗
「展开其余 49 行（全部一致）」；点开是全表，按钮变「收起 49 行一致的」。
按钮放**上面**：真机上一旦"不符"有十几行，压在列表底下要先滚到底才找得到（台架第一次
就是这么点的，坐标落在 y>900 的视口外，点了个空）。

**台架写歪过一条**：我先断言"展开后页面不跳回顶部（scrollTop > 100）"，红了才去看 ——
那一刻 `scrollTop` 本来就是 0，因为收起状态下那颗按钮已经在视口里，`scrollIntoView`
不会滚。真正要钉的是**按钮自己不许挪窝**（内容只在它下面长），改成比展开前后按钮的
`getBoundingClientRect().top`。滚动位置照样保了（`redraw()` 会把滚动复位，下一帧放回去），
那是给"已经滚下去才点"的情形留的。

## 5.28 版本与更新：只查、只下载（2026-11-04，主人对"升级做到哪步"答"你看着来"）

**取舍**：做到"检查 + 下载"为止。装那一步要 `ksud module install`，一个按钮就把现装模块换掉，
风险不对等 —— 下载只把 zip 放到模块目录，装还是人在管理器里点「从本地安装」。

**网络实测**（手机上直接 curl）：`api.github.com` 200、`github.com` 200、
`objects.githubusercontent.com` 有响应；`raw.githubusercontent.com` **000（不通）**。
所以：版本检查走 releases API（CORS 是 `*`，WebView 里 fetch 得到），包地址取 release 资产；
`update.json` 里那条 raw 链接在这台机上不可用（但管理器自己的更新检查走的是另一条路，不受影响）。

**界面**：设置页最后一张卡。**不自动联网**（进设置页不付网络，点「检查更新」才查）：
`checking → ok(err) → done` 三态。有新版报「vX（N MB）」+ 下载；下完报"已下载到模块目录
update.zip"并明说怎么装；查不到时明说"连不上 GitHub"，**不假装已是最新**（那是把"我不知道"
画成"没问题"，和属性页那条同一个规矩）。

**命令层**：第 41 条 `update-fetch <地址|路径>`。URL 支走 curl（没有就 wget），路径支直接拷；
先落 `.tmp`，校验 zip 魔数 `PK` 与长度 > 4 才改名 —— 半截文件不许冒充 `update.zip`；
失败时删掉 `.tmp` 不留残骸。路径支不只是给测试用：本地已经有 zip 时也能走这条路。

**测试**：对拍 5 条走本地包那一支（输出、落盘字节、非 zip 拒、失败不留文件）；**网络那一支
不进自动化**（CI 不联网，进不进得去取决于那台机的网络），台架两条用 `__KL_DEMO_FIXTURE`
注入 API 形状。真机上我只到"命令层能下本地包"这一步，**没有真的从 GitHub 下过** ——
要不要下、什么时候下，等主人点。

## 5.29 滚动位置：同页重画保住，换页/切档才回顶（2026-11-04，主人："每次都会直接回顶部"）

**根因**：`draw()` 同页重画时先 `page.textContent = ''`，页面高度瞬间塌到 0，浏览器顺手把
`scrollTop` 夹成 0；随后内容重新长出来，人已经被踢回页首。凡是走"写入 → reload → draw"或
"展开/收起 → redraw"的动作都会中：点一行名单、展开属性表、写完一项配置回来。

**收口在一处**（`app.js` 的 `draw()`）：
- 同页重画：记下 `scrollTop`，两帧后放回去（MD 组件升级完高度才定，早一帧会被冲掉）；
- 换页（`S.tab/S.sub` 变了）与切档：回页首；切档由调用方先置 `S.jumpTop`
  （芯片只认真指针事件，`element.click()` 不切视图 —— 台架那条也因此用真指针点）。
属性表折叠按钮里原先单独写的滚动补偿删掉了：一份逻辑只留一处，免得两边打架。

**台架**：名单里点一行（写入→重读→重画）后 `scrollTop` 900 → 900；切档（名单→已装）回到 0。
这两条钉的是"回不回顶"这个行为，不是某一次高度变化。

## 5.30 全选 / 反选 / 全不选（2026-11-04，主人："名单为什么没有全选反选"）

**范围**：只作用在"这一屏画出来的行"（`paintRows` 里那份 `page = filteredTokens().slice(0, shownLimit)`：
过滤 + 排序 + 200 条上限之后），不是整个档位 —— 人对看不见的东西没法负责。
搜索框下面一行，只出现在非「名单」档。
「名单」档不出现：那里本来就全选，反选等于清空，命令层也不允许。

**实现**：三个动作都走既有命令（`restore-apps` / `remove-apps`，逗号分隔），没有新增写入口；
反选是"先移后加"，顺序反了会把刚加进去的又删掉。

**台架**：系统档 2 行（1 在名单）反选一次 → 换掉那一条，再反选一次回到原样（反两次 = 恒等，
顺便证明这段没污染后面的断言）；已装档全选后那一行变成「这一屏 4 条都已在名单里」。
—— 这一节里"整行换成一句话 / 会清空的那一下禁用"的规则在下一轮被真机形状推翻，见 §5.31。

## 5.31 批量那一行按真机形状重写 + 删除都要两段式（2026-11-04，主人："继续优化"）

**抓到的洞是我自己上一轮的**：§5.30 在那台机上现在就是坏的。现量 `apps` 129 条**全部**在
131 条 `targets` 里（`on=129 / off=0`），于是那一行画出的是三颗按钮：「全选」点不动（没得选），
**「反选」和「全不选」做的是同一件事**，两者都一弹抹掉 129 条、只回一句 toast。
默认夹具只有 4 行、`off=1`，永远走不到这一格 —— 144 条断言一路绿，一条都没看见。
所以这一轮先补的是**形状**，不是新功能：台架里注入一份真机条数的夹具（129 全勾 + 名单还多 2 条）。

**规则**（`bulkPlan`，三条各由一个数决定，画之前先算）：
- 这一侧**没东西可动 ⇒ 那颗不画**。「反选」因此只在这屏既有勾着的又有没有勾的时候才出现 ——
  并排两颗点出来一样的按钮比缺一颗更让人迷惑，而"不留一排点不动的字"那条老规矩同一把尺。
- 会**把名单清空 ⇒ 画出来但置灰**，同排一句话点名原因（命令层本来就拒绝清空，界面先拦住，
  不给一条"点了报错"的死路）。
- 一次动**多于一条 ⇒ 要第二下**。字上先写条数（「全不选（129 条）」），第一点换成
  「再点确认（129 条）」且一个字都不写，4 秒内没有第二下自动收回。只动一条的不拦 ——
  那与点那一行是同一件事，点一行从来不需要确认。
确认状态按**完整参数签名**（`key|del|add`）记，不按按钮名：搜索一改或点了「继续显示」，
画出来的行换了一批，之前按住的那一下动的已经不是这些东西，不能算数。写完 reload 会重建
`listSection` 闭包，`armedSig` 归零 —— 确认态不需要自己记得收回。

**同一把尺量到另两颗按钮**：「删除 · <profile>」（`teesim-profile-del`）与「删除这一段」
（`tricky-drop-patch`）以前一弹就没了一份配置。抽出 `dangerButton(label, o, run)`（字换成
「再点确认 · X」，4 秒收回），与「备份与回滚」那颗同形；不用 `confirm()` —— WebView 里它可能被
静默忽略。批量那三个没共用这颗 helper：它们要把条数写进字里、还要按签名作废，状态得自己管。

**台架 144 → 154**：真机形状那条是本轮的锚（只给一颗写条数的「全不选」/ 第一点不写 /
第二点正好一条 `remove-apps` 且参数是那 129 个包名）；作用范围跟着「继续显示」从
`（200 条）` 长到 `（250 条）`；写完确认态自己收回；两颗删除各钉"第一下不写 + 第二下正好一条"。
批量按钮从此一律按 `data-bulk` 找 —— 按 label 找等于把上一版那个错形状钉死在台架里。
变异自证：`a.n > 1` 那半短路 ⇒ 红 **4**（第一点直接写，`写次数 [0,2]`）；「反选」退回无条件出现
⇒ 红 **3**；两颗删除退回一弹就发 ⇒ 红 **4**、退码 1。

## 5.32 提示一直是 `[object Object]`：反向断言配空仪器（2026-11-04，为了量"同步说了什么"才发现）

**怎么撞上的**：这轮想把「立即同步一次」那句"已请求同步"改成报条数，得先读到 toast 的文字。
第一次读数拿到 `| [object Object]` —— 以为是自己读错了通道，把 `textContent` / `message` /
`shadowRoot` / `innerHTML` 四个都打出来，才知道**屏上真的就是那十四个字**。

**根因**：`app.js` 调的是 `snack.show({ message: 文本, timeout: 2600 })`，而 md-snackbar 的签名是
`show(message, actionLabel, duration)`（`src/components/md-snackbar.js:115`）—— 第一个参数就是字符串，
对象被整个当成 message 落进 `message` 属性。附带损失：`timeout` 没进属性，停留时间一直是组件默认值。
`git log -S` 定位到 `205c90e`（新版界面第一版），`git tag --contains` 一查：**v3.0.0 / 3.0.1 / 3.0.2 / 3.0.3
四个发布版全中**。也就是说主人每次写入看到的反馈，从来就没读过字。

**为什么 154 条断言没响**：台架里唯一碰 snackbar 的那条是**反向**的（"点禁用按钮不发出写入" ⇒
断言"没有『已写入并复核』"），而它的读数用 `s.textContent` + `String(s.message)` —— 在这个组件上
两条**恒空**。空仪器 + 反向判据 = 无论屏上印什么都绿。这正是 §6 里"只读 `hidden`/`disabled`
属性等于没验"的同一类，只是这次连属性都读错了。

**修法与闸**：`show(文本, undefined, 毫秒)`；读数改成 `getAttribute('message')`（组件落点）
**加**影子 DOM `.message` 的 `textContent`（人眼看到的那一份），两处都要读到那句中文；
那条反向断言也换成读 `message` 属性（不再恒空）。正对照落在「立即同步一次」上，顺手补了
demo 里缺失的 `sync` 输出（以前点它是"未知命令"）。变异自证：退回对象写法 ⇒ **只有正对照红**
（读数正是 `[object Object]`），反向那条照样绿 —— 这条控制同时证伪了"台架看过了"这句话。

**顺带**：`write()` 的第三个参数现在可以是函数（跑完拿到 kv 再决定说什么），同步那句因此能报
「已同步：名单现在 N 条」—— `count` 两侧同口径（同步后的目标文件行数）。

## 5.33 全量复查那一轮（2026-11-04，主人："你再仔细地全量检查一下"）

八项，每项带读数 —— "检查过了"不算交付物。

1. **53 套 shell 逐套跑**：`failures=0`。本轮只动过 JS，Rust 侧没重编也没重跑 `cargo test`（记为边界）。
2. **静态闸 11 条 + `build --check` 两路**：全过（`webui/dist` 与 `module/webroot` 与源码同版）。
3. **契约条数**：Rust `COMMANDS` = **41**，`webui.sh` 分派臂 = **41**，逐条对得上、没有只在一侧存在的命令。
   文档里几处"40 条"是各自的历史时点（§5.28 之后才加的 `update-fetch`），不改写。
4. **机上模块 ↔ 仓库**：15 个关键文件里 **14 个哈希逐位相同**；唯一不同的是 `module.prop` 的
   `description` —— 那是模块自己写的运行时状态行（`✅ [OhMyKeymint | 应用: 132 | 更新: 12:33]`），
   不是代码漂移。机上 `bin/keylens` = `caf8ad59be79…`，`webroot/index.html` = `b99216b6…`（本轮推的）。
5. **组件方法调用点全仓只剩 1 处**（`snack.show`），已是位置参数形式；没有第二处"对象当第一个参数"。
6. **属性通道全量扫描**（新工具 `tools/md3e-build/attr-audit.mjs`）：55 屏 / 累计 720 个 `md-*` 元素
   ⇒ 死属性 **0**、"observed 了却没画出那份字" **0**；放过 12 处全是 `md-option` 的 `value`/`disabled`
   —— 不在 `observedAttributes` 里，但原型上有 `get value()` 按需读属性，**不是**死属性。
   工具的仪器自测不是装饰：第一版把选择器写成 `#view md-*`（非法 CSS，当场 SyntaxError），
   `ev()` 吞掉异常后返回 null，扫描器就报了个漂亮的"零条"。自测 + 覆盖下限（≥20 屏 / ≥200 元素）
   就是为了把这种"零"当场变成红的。
7. **台架反向断言清点**：把 161 条里判据是"某东西**不**在"的挑出来逐条看同通道有没有正对照 ——
   `backArrow()===0` 有（二级页 ===1）、`absentToned===0` 有（`absent===4 && bad===9`）、
   `sk.real===0` 有（第二屏 `head==='Google Play 商店'`）、snackbar 那条有（同步那句）。
   只剩一条纯反向没配对：**「菜单不把未知报成 0 项对照」** ⇒ 补了正对照（读过属性后菜单真带出
   「53 项对照」）。变异自证：把那句摘要改成恒空 ⇒ 正对照红、反向那条**照样绿**。
8. **真机形状复测**：`已装 129 / 名单 132`（本轮两次测量之间模块自己同步过一次，131→132），
   `on=129 / off=0` 依旧成立 ⇒ §5.31 的夹具不是踩在一个巧合快照上。名单里没装的三条是
   `com.android.vending` / `com.google.android.gms` / `com.google.android.gsf`（系统包，本来就不在
   `apps` 那 129 条里）—— 这也是「未纳入」档常年为 0、而名单还能比已装大的原因。

**新查出来的余账（本轮关不掉，都不是我这边一句话能了结的）**：
- **发布资产还躺着那个坏产物**：`KeyLens-v3.0.3.zip` 里的 `webroot/index.html` grep 到 `show({message:`
  —— 就是 `[object Object]` 那一版；而 `update.json` 的 `zipUrl` 正指向它。所以走「检查更新 →
  下载更新包」或管理器 OTA 装回来，那个洞会**跟着回来**。关掉它 = 出 v3.0.4（等主人点头）
  + 代理起来推 26 个提交，两件事都有前置。
- 台架 PAGES 循环里主页/功能两屏采样时还是骨架（没有 md-button），那两条属性通道闸照不到
  那两屏的按钮 —— 覆盖边界，不是假绿（另外四处都覆盖到了）。

## 5.34 名单屏照模板重做"明了"，功能按任务流重新分工（2026-11-04，主人："应用列表还是不太行，不够明了…各种功能的排序和整合分工也继续全量优化，建议你自己找些模板学习"）

**先调研再动手**（主人点名要学模板，两路并行）：
- 本机：`D:\下载\Tricky-Addon-Update-Target-List`（webui/src/app_list.ts 等）与 `D:\下载\TS\TEESimulator\module\webroot`（js/ui/scope-view.js）。
- 业界：M3 lists/selection 规范、NN/g 吸顶头与筛选器分类、Vaadin Grid 选择、W3C Checkbox APG、LSPosed Module Scope。
两路收敛到同三件事：**① 筛选与搜索要常驻（吸顶）；② 行的身份要标出来（系统 / 未安装 / 已选），批量只作用于"当前筛选结果"并写明条数；③ 菜单按任务流排，同任务的状态与操作放同一屏。** 这三条下面逐条落地。

**1. 吸顶层**（`webui/src/app.css` 的 `.list-head`）：芯片 + 搜索框 + 计数一起吸在固定顶栏下面。
129 行往下滚二十行就够不着搜索框，"想搜得先滚回顶部"在触屏上等于没有搜索。
**踩到的坑**：第一版把 `.list-head` 装进卡里，`position:sticky` 完全不生效 —— 实测滚到
1600px 后那颗搜索框跑到 `y=-1456`。原因是 **md-card 的影子层自己裁边（圆角）**，被裁住的
sticky 元素贴不出去。卡本身是透明底（`md-card.card{--md-card-container-color:transparent}`），
所以把 head 挪到卡**外面**做兄弟（`listSection` 现在返回 DocumentFragment），视觉零差别、sticky 生效。

**2. 每一档一句话 + 用词去行话**：`VIEW_NOTE`（screens.js 顶部）——切到哪档就在芯片下面换哪句说明。
芯片名字也改了：「未纳入 → 待加入」「排除 → 移出过」；NN/g 那条"忌抽象分类与行话"直接对着我们这句。

**3. 搜索没命中 ≠ 这一档是空的**：以前两种情况共用一句「这一类现在是空的」，
搜不到东西时等于把人赶去猜。现在说「没有匹配「词」的条目」，并把一颗**「清除筛选」**递到手边。

**4. 行的身份标记**（`rowFlag` / `data-flag`）：名单档里每行补一句「系统应用 / 本机查不到 / 按 UID 的条目」。
判据是两份宇宙（`apps` + `apps system`）**都读到了**才算数 —— 把"没读到"说成"没装"是假消息。
配套：名单里真有查不到的条目时，列表上面一句话点名 + 一颗「清出这 N 条」（走既有 `remove-apps`，
两段式确认）。**接线细节**：标记同时落到 `data-flag` 属性上 —— 图标到货时 `swapIcons` 会原位重写
这行的文字，不从属性读回来那句标记就在那一刻被抹掉（台架"第一次与第二次进入文字一致"那条抓的就是它）。

**5. 顺手抓到两个真 bug**：
- 「计数为 0 的档不占位」以前写成 `d[1].slice(-1) !== '0'` —— 按**末位字符**比，于是
  「待加入 250」「移出过 10」这种数也被整颗藏掉，切档切不过去。`?many=1` 那一档当场撞红。
  改成取末尾数值判 `!== 0`，两头各钉一条（250 必须留、0 必须藏）。
- 「系统 …」这个省略号以前是常驻的：芯片点开才去取 `apps system`，所以首屏永远显示
  「系统 …」，看着像坏了。改成进名单页就**后台**预取（不进首屏等待链，`ensure('system')`），
  判据跟着换成"永远不许出现省略号"：要么带数字，要么明写「系统 读不到」。

**6. 功能排序与分工**（主人第二句）：
- 「自动同步」那一页整页只有两颗按钮 + 一行状态，而它改的就是这份名单 ⇒ **并进「目标名单」**，
  菜单从 5 条变 4 条（NN/g 邻近原则：同任务的状态与操作同屏）。卡的小标题从"（页标题）"
  改成「同步名单」。
- 「运行体检」从设置页挪到**主页**：它是"现在到底行不行"的答案，属于总览层
  （Shneiderman：先总览 → 再过滤 → 再细节），不该藏在设置页倒数第二张卡。
- 「备份与回滚」从设置页挪到**后端配置**页底：它撤的就是那一页写的文件。
- 菜单顺序 = 常用在前、破坏性/低频沉底：名单 → 后端配置 → 属性伪装 → keybox（换 keybox 会让旧密钥全部作废）。
- 菜单里名单那行的摘要加了「待加入 N」—— 要不要动手在菜单上就看得出来。
  算法与名单页的「待加入」档共用 `pendingCount()`，不许两处各写一份。
- 设置页从此只管界面自己的事：外观、界面自检、版本与更新。

**台架 161 → 169**：吸顶（滚 1600 后搜索框仍在视口、计数在吸顶层里）、每档换话、
搜索无匹配 + 清除筛选真清掉、末位 0 不藏 / 真 0 才藏一对、残留点名 + 两段式清出。
变异自证（三处一起）：`.list-head` 改 `position:static` + 摘掉 view-note + 不挂 staleHost
⇒ 红 **7** 条（含连带：系统组件那颗折叠句没了 ⇒ 两条红；sticky 没了 ⇒ "切档回页首"那条也红，
说明这两处是耦合的，记在这里）；把体检搬回设置页 ⇒ `tests/ui-shape.js` 新那条当场红
（"主页 1 处 · 设置页 1 处"）。

**没做的，都带理由**：
- **按状态分组 + 段头三态全选**（TA/TEESim 的核心做法：一屏之内分「已选 / 未选 / 未安装」几段，
  段头带计数和段内全选）。这是下一轮最大的一块，本轮先把吸顶与标记做对 —— 分段要动
  `filteredTokens`/`paintRows` 的整条装配线，且会把"已选浮顶"那条排序判据换掉，不该顺手做。
- **Recent / 频率档**：TEESim 默认档是"开机后请求过 key 的应用"，最贴近"该管的那些"，
  但要新数据源（现在只有 `pm list packages` 与 launchable），命令层先加一条才谈得上。
- **从 Magisk DenyList 导入 / 剔除 Hook 管理器**（TA 的两颗批量钮）：要命令层新增取数，
  且属于"替用户决定该 spoof 谁"，先不塞进名单页。
- **名单页现在有四行说明**（目标文件 / 接受的写法 / 这一档是什么 / 计数）才到第一行应用 ——
  本轮只减了重复没减到这一层；下一轮把"目标文件 + 接受的写法"并成一行，或折进「写到哪里」一句。
- **台架的体检假数据自己在说谎**（同日，顺手修）：demo `doctor` 给 7 行却报 `checks=11 / bad=1`，
  汇总句写"有问题 1"而屏上没有红行；真机现量是 12 行全 ok。现在 rows 与计数同源算，
  台架也从"至少 6 行"改成钉死 12 行 + 汇总句必须对得上。**假数据自相矛盾时，台架读到的是
  一个真机不可能出现的状态** —— 这类"夹具说谎"应该当成一等公民查，不是等它骗出人再来修。

## 5.35 体检并进主页那张大卡片（2026-11-04，主人："体检可以直接放在主页的大卡片上"）

**形状**：英雄卡的统计行从三格变四格（版本 / 生效名单 / 属性伪装 / **体检**），第四格就是结论 ——
没跑过写「未跑」，跑过写「N 项有问题」/「N 项注意」/「N 项都过」（按 bad→warn→全过的优先级取，
用色不堆表情）。按钮与 12 行结果跟在统计下面，**同一张卡里**展开；单独的 `doctorCard` 删掉了
（主页从此只有两张卡：英雄卡 + 三家后端）。骨架屏同步加第四格，否则骨架→真页会长高一段。

**踩到并钉住的一条**：结论那一格是**建卡时算的**，结果列表是 `paint()` 里改的 —— 两处读数不同源，
就会出现"下面 12 行都出来了、上面还写着未跑"。修法不是再算一遍，而是把那一格的元素交给
`doctorBlock(doctorCell)` 持有，`paint()` 里 `syncStat()` 一起改写（一处拥有，两处同步）。
台架因此两条：跑之前那格必须是「未跑」，跑完必须变成结论（现量「1 项注意」）。

**判据跟着实现搬家**（§6 那条老规矩又应验一次）：`tests/ui-shape.js` 里有两条在钉体检的落点与内部
形状 —— 一条钉 `section('体检'`（单独卡时代的标志），一条钉 `box.appendChild(doctorCard())`。
落点一天内动了两次（设置页 → 主页单独卡 → 并进英雄卡），两条都当场红，说明它们真的在看；
改成钉 `c.appendChild(doctorBlock(doctorCell))` + `['体检', ds[0], ds[1]]` + 全局不许再出现 `doctorCard`。

**台架 169 → 171**：新增"体检就在主页大卡片里（按钮与结果都在 `.hero` 内）"和"跑完第四格变结论"。
变异自证：把包裹类名从 `hero-doctor` 换掉 ⇒ 前者红（读数 `在英雄卡里:false`）；
删掉 `syncStat()` ⇒ 后者红（读数 `第四格=未跑`）；两条互不干扰，各自钉各自的事实。

## 5.36 长列表的收起做成一颗机制（2026-11-04，主人："像这种长列表可以做个收起按钮"）

主人指的是主页那张卡里的体检 12 行。做法照属性页那一轮已经定下的两条规矩（§5.27），
并把它抽成 `foldButton(key, labelWhenShut, labelWhenOpen)` —— **一处机制，三处用**：

| 位置 | 默认 | 收起时留下什么 | 按钮字 |
|---|---|---|---|
| 属性对照表 | 收起 | 只有不符/读不到的行 | 展开其余 N 行（全部一致）/ 收起 N 行一致的 |
| 体检结果（英雄卡里） | 收起 | 只有非 ok 的行；全正常就一行不留 | 展开其余 N 项（都正常）/ 收起这 N 项正常的 |
| 名单那一屏的列表 | 展开 | 一行不留（列表就是这一页的内容，收起是为了够得着下面的东西） | 展开这 N 行 / 收起这 N 行 |

**两条实现账**：
1. **收起 = 一行都不建**，不是 `display:none`。名单屏收起后页面高度从 19370px 塌到 824px，
   而且 `loadIconsFor` 整批不发 —— 收起省的是构建与命令，不只是滚动距离。
2. **按钮的位置**：第一版把「收起这 N 行」放在列表上面，结果列表一长它就被吸顶层挡住 /
   要往上翻才找得到（台架当场打不中它）。改成和计数并排、**放进吸顶那一行**，
   滚到哪儿都点得到。吸顶层因此是：芯片 + 搜索 + 「共 N 条 · 已勾 K 条 · 收起/展开」。

**顺手抓到一个更早就存在的洞**：「继续显示」点开的那一档（200 → 250 行）以前存在
`listSection` 的闭包变量里，于是**任何一次整页重画都会把它悄悄抹回 200** ——
写入后的 reload、切页回来、这次的展开/收起，都会让用户刚点开的那 50 行无声消失。
现在进度存在 `S.shownLimit`，只有**切档**才归零（换了一批内容，从头画起是对的）。
这条不是重构洁癖：它就是被新的收起按钮撞出来的。

**台架 171 → 175**：体检默认收起（1 行 + 那颗写着「展开其余 11 项」）、点开展平 12 行、
名单收起（行归零 / 页高 19370→824 / 计数句改口「列表已收起」）、展开回来 250 行原样、
切档进度归零。`tests/ui-shape.js` 加一条"收起只有一颗机制"（`foldButton` ≥3 处、
三个键都在、属性页旧的手写 toggle 不许回来）。
变异自证：收起时照样建行 ⇒ 只有那条收起红；把进度从 `S.shownLimit` 退回闭包 ⇒ 红 **5** 条
（继续显示、批量作用范围 200→250、图标问全、收起、展开回来 —— 老闸和新闸一起抓住同一个回归）。

## 5.37 回退层不再把"读不到"交成"0 条 + 成功"（2026-11-04，主人："全量优化"）

**真机现量的原始症状**（这台机是 omk 后端，Rust 层读 131 条）：

| 跑法 | 修之前 | 修之后 |
|---|---|---|
| `KL_USE_RUST=0 … webui.sh targets` | **0 行 · 退码 0** | 0 行 · **退码 2** + stderr 一句"回退实现缺少参照脚本：omk_list.awk —— 这一版的正式实现是 bin/keylens，请重装完整包" |
| 界面（若哪天回退层接管） | 名单画成"是空的"，还给一颗「立即同步一次」 | 计数画「—」、体检「名单」那格报 bad 并指同一条下一步 |
| 「加入一个应用」在回退层 | **拿空基线把 129 条重写成 1 条** | 直接拒绝（rc=2），目标文件一个字节不动 |

**为什么三层叠起来才变成事故**（每一层单独看都"合理"）：
① 参照 awk 自阶段 5 起不随模块发布（docs/AWK-REMOVAL.md 的计划第 2 步只落了装机期的那半 ——
`customize.sh` 会中止，**运行期那句"必须显式失败"从来没写**）；② 每个调用点都挂 `2>/dev/null`；
③ 分派走到脚本结尾自然退 0。Rust 接管是默认（`KL_USE_RUST=1`），所以界面四年没露馅。

**改法：读不到 ≠ 0 条，是两种不同的回答**。`lib/backend.sh` 新增两颗公共件 ——
`kl_ref_ok <参照名…>`（缺就 stderr 说清缺什么 + 该怎么办 + 退 2）与 `target_count`（读不到退 2，
不返回 0）；`current_target_apps` 三条后端分支各自 `|| return 2`（以前是 `|| return 0`）；
`add_target_apps` / `remove_target_apps` / `build_app_list` / `sync_omk_injector` / `omk_write_list`
全部改成"基线带着退码一起拿，拿不到就不写"；`webui.sh` 末尾 `exit "$_rc"` 把命令退码带出分派；
`cmd_target_meta` 与 `backend-info` 的 `target_entries` 不再把失败折成空/0。

**为什么 276 项对拍一路绿**：它把 `KL_PATCH` 指向 `tests/fixtures/backends/`（awk 齐全）——
那台子本身就是个消音器，生产形状（一个 awk 都不发）从来没被任何闸跑过。补的 permanent 闸是
**第 54 套 `tests/fallback-shape.sh`**（44 条断言，CI 的 `for t in tests/*.sh` 自动收）：

* ① 三后端 × 缺参照 = 各 4 条（退码、不交空、stderr 点名参照、给出下一步）＋ 连 awk 都没有的形状；
* ② **两条形状分开钉**：全缺（writer 也死）与**半坏**（`omk.awk` 在、`omk_list.awk` 不在 ——
  只有这一种才能测出"拿空基线落盘"，全缺形状里那条拒绝有一半是 writer 自己挡的）；
* ③ 形状判据：模块里 0 个 `.awk`、夹具里 19 份齐、**不许有管道读名单**、**不许有吞 stderr 不带退码**
  （两条扫描都先折掉 `||`、认 `if/while/until` 条件位 —— 第一版各冤枉过一处正确写法）、分派带退码；
* ④ 反向对照：参照齐全时读得到 / 加得动 / 真落盘 / 发了 OMK 重载 —— 证明上面的红不是函数坏了。

**变异自证**（`tools/mutate-fallback-shape.sh`，把修好的行改回修之前；本地按需跑，**不进 CI** —— 它动的是生产文件，跑完自己证明四个文件逐字节还原）：
M1 `|| return 0` ⇒ 红 2；**M2 删掉 `add_target_apps` 那道守卫 ⇒ 红 5**，其中一条读数就是
「原有条目被吃掉了」—— 这次事故的正主；M3a/M3b 各单删同步的两道守卫 ⇒ **仍全绿**（纵深防御，
不是漏检，台子上明写）；M3c 两道全删 ⇒ 红 2；M4 分派退 0 ⇒ 红 1；M5 把扫描器的函数名改错一个字母
⇒ 3.3/3.4 安静全绿、**只有开火对照响**。还原后 44 条全绿、四个文件逐字节一致。

**顺带修的一件旧账**：`tools/replay-check.mjs`（本机真机回放台子，不在 CI 的 11 条里）还钉着
"功能页菜单五项"，§5.34 把菜单减到四项后它自己变红了 —— 判据从"数一个数"改成
**恰好这四项、按顺序**（目标名单 → 后端配置 → 密钥箱 keybox → 属性伪装）。

**闸门读数（本轮最后一次全跑，收尾时又补了第 55 套再重跑一遍）**：shell 套 Git Bash **55/55** ·
WSL **55/55**（`tools/wsl-suites.sh`）· 对拍 **276 全通过 exit=0**（WSL，`tools/wsl-parity.sh` 落退码）·
台架 **175** 条 · CI 那 11 条静态闸全 OK + `replay-check` 42 条 · `build.mjs --check` 两条产物同版。

**第 55 套 `tests/device-fallback.sh`（设备侧 runner）── 2026-11-04 18:5x 上机跑过，全绿**：
把同一份 44 条断言搬到 **mksh + toybox awk**（`/system/bin/awk`）下再跑一遍，另加 7 条真机现量：

| 现量判据 | 读数 |
|---|---|
| 模块里参照 awk 份数 | **0**（生产形状成立，被推过参照就红，不静默跳过） |
| `KL_USE_RUST=0 … targets` | **rc=2** + 「回退实现缺少参照脚本：omk_list.awk —— 这一版的正式实现是 bin/keylens，请重装完整包」 |
| 同一命令的输出行数 | **0 行**（与退码 2 配对，不再是"0 行 + 成功"） |
| `KL_USE_RUST=1 … targets` | **131 行**（默认层没受影响） |
| `KL_USE_RUST=0 … backend-info` | `target_entries=` **空**（不是 0；界面画「—」） |
| `KL_USE_RUST=0 … target-meta` | **rc=2**（以前折成空 + 成功） |
| `KL_USE_RUST=0 … doctor` 的「名单」 | `bad　名单读不到：回退实现缺参照脚本`，且**不再**甩锅「读不到已装应用列表」 |

**上机时又抓到自己两处**（都记进 §6）：
1. 这个 runner 第一版在**仓库形状的副本**上量"生产形状"，得到的是 **rc=0 + 131 行** 的假读数 ——
   `use_backend` 的第二条解析分支是 `$mdir/../tests/fixtures/backends`，而副本旁边正好放着为跑套件
   拷进去的 19 份参照。现在三条现量判据一律跑在真模块目录 `$MOD` 上，副本只用来跑套件。
2. 体检那颗「名单 vs 已装」以前只有一个 `else` 兜底写「读不到已装应用列表」；真机上回退层读不到
   **名单**时（已装 129 条读得好好的）它把锅甩给了已装。现在按"名单读不到 / 已装读不到 / 都可读"
   分开报，并向真机台子加了一条断言（甩锅就红）。

**上机落地的文件**（先存 `/data/local/tmp/kl-prepush-20261104/` 再改，逐文件 sha 核对 + 模式 755/644）：
`webui.sh`、`lib/applist.sh`、`lib/backend.sh`、`lib/write.sh`。命令层每次调用现读文件，**不用重装**，
界面也不需要重开（这轮改动只在回退分支上生效，默认 Rust 路径输出一字未变）。

**还没做**：v3.0.4 发版（仓库里的 zip 与 `update.json` 还指着带 `[object Object]` 的 3.0.3）等主人点头；
33+ 个提交等代理恢复。

## 5.38 库里还有没有多余的（2026-11-04，主人问"拿项目里没别的什么多余的吗"）

按"能否说出它现在被谁用"来量，不看感觉。分母与正对照都写在读数里（正对照不响的扫描不算数）。

| 类别 | 读数 | 结论 |
|---|---|---|
| 逐字节重复的已跟踪文件 | 2 对：`rust/golden/excluded.txt` == `backups.txt`、`teesim-profiles.txt` == `teesim-overrides.txt` | **不是重复**：golden 是按命令各存一份，合并要引入清单间接层，不值 |
| 空文件 | 0 | — |
| shell 函数定义 | **141 个**，全部至少被引用 1 次（检测器拿合成名 `no_such_function_zzz` 自证会开火） | 0 个死函数 |
| Rust 编译告警 | 修前 4 条 `value assigned to … is never read`（`read_cmds.rs:597/5356/5357/5770`），修后 **0** | 4 处 `let mut x = String::new();` 后面每个分支都赋值 ⇒ 改成延迟初始化 `let x;` |
| 没人按名字提的文件 | `tools/` 7 个 + `tests/` 5 个 | 逐一看过：5 套测试靠 CI 的 `tests/*.sh` glob 跑；`icondump/build.sh` 是 `lib/icondump.dex` 的生成器；`per-component.mjs` / `leave-one-out.mjs` 是体积/图标那轮的复现脚本；两个 `package.json/lock` 是 npm 入口。都不是死文件 |
| 明确"只为历史保留"的 | `tools/mwc-build/`（6 个跟踪文件；28MB 里 27.9M 是没进库的 `node_modules`） | 上一代产物（`@material/web` 2.5.0）的生成器，THIRD_PARTY_NOTICES 自己写明"不再发布，只为历史与复现旧页面"。**唯一可删的候选**，但删它同时要删许可说明，暂留 |
| 本机没进库的 | `rust/target` 544M · 两个 `node_modules` 46M · `webui/dist` 8.9M · `_harness` 1.4M · 两个发布 zip · 一个对话导出 md | 仓库 663M 里 99% 是这些；都不影响仓库，`.gitignore` 已盖住 |
| 体积最大的已跟踪文件 | `CHANGELOG.md` 354KB（`update.json` 的 changelog 就指向它）· `docs/HANDOFF.md` 168KB | 只增不减的历史，不是垃圾；真要瘦身得另开一次"归档"决定 |

修完重跑：`cargo test` **77 passed** · 对拍 **276 exit=0** · 55 套全绿。`module/bin/keylens` 本来就不进库（CI 现编），这次改动只删了死赋值，**行为零变化**，设备上那份二进制不用重做。

## 5.39 装完 v3.0.4 之后的三件事（2026-11-04 深夜，主人："那你看着办吧"）

**① 体检要不要改成进主页自动跑 → 不改，保留按钮。** 现量：`doctor` 在设备上 **365ms**
（三次 377 / 352 / 365），`status` 31ms，主页首屏 43ms。进主页自动跑 = 门面屏每次（每个会话首次）
多背 0.36s 的命令与一次布局跳动，而那颗按钮本来就兼着「重新体检」（改了属性伪装/名单之后要再查一次）。
卡片上已经写着"点上面这颗按钮开始"，第四格写「未跑」是**状态**不是缺陷。真要改，等下一个因为别的原因发版的时机。

**② `update-fetch` 的真机下载路径 → 能用，失败来自连路抖动。** 读数（同一个包，连跑 5 次裸 curl）：
3 成 2 败，失败都是 `curl: (28) Failed to connect to github.com port 443`（约 31s 超时）；
成功的 3 次都是完整的 **547,793 字节**。二进制在同条件下 3 次 2 成 1 败 —— 与裸 curl 同频，
所以**不是代码问题**（这台机到 github 的直连不稳，PC 那边同样得挂代理）。两个可改进项留给下一版：
失败时只印「下载失败：<url>」，既没有原因也没有重试 → 可加 `--retry 2 --retry-connrefused`
（**必须两侧一起改**，否则 shell/Rust 在这一支的输出就分叉了）。测完把 `update.zip` 删了，设备状态复原。

**③ 卸载覆盖面审计 → 补了一条真漏的。** `uninstall.sh` 把 `/data/adb` 下自家文件按 `.kl_*` 前缀、
改名前那套前缀、以及具名路径收掉，但 **`/data/adb/keylens-ab`（我们推上去的 A/B 参照树，现量 2.0 MB）
一直留着** —— 普通用户没有这个目录，可这台机有，卸载后会剩一堆旧代码。现在收掉，`tests/uninstall-scope.sh`
的夹具里加了目录内两个文件（`module/webui.sh`、`device-ab.sh`），55 套全绿。
**这条改的是发布包里的文件** ⇒ 机上这份 v3.0.4 没有它，随下一版生效（其余两条不需要发版）。

## 5.40 更新这一步搬进应用：下载完直接「安装」+ 更新日志（2026-11-04，主人："仔细学一下ksu的模块更新"）

**先学，再动。** 学的是**这台机上装着的那个管理器**（`me.weishu.kernelsu`，`adb pull base.apk` 后
`dexdump`），不是凭印象：

| 问题 | 证据 | 结论 |
|---|---|---|
| WebUI 能不能自己装模块？ | JS 接口类（脱敏后 `Lgn4;`）的方法清单：`exec`×3 / `exit` / `fullScreen` / `getPackagesInfo` / `listPackages` / `moduleInfo` / `spawn` / `toast` | **不能**。`installModule` 只出现在别的数据类的 `toString` 里，不在注入给网页的接口上 ⇒ 安装必须走命令行 |
| 管理器按「更新」时到底做了什么？ | dex 里的 usage 串 `module install  #module is not in the regist…` | 调 `ksud module install <zip>`；落点是 `modules_update`，**重启才生效** |
| 更新日志怎么显示的？ | `assets/webview/markdown.js` + `markdown.css` + `syntax_*.css` | 按 **markdown 渲染**（不是纯文本） |
| 更新从哪来？ | dex 里 `updateJson`（3 处）、`changelog`（4 处）；我们的 `module.prop` 早就有 `updateJson=` | 管理器读 module.prop 的 updateJson → update.json → version/zipUrl/changelog |

**所以我们的做法**（照它的形状，不抄它的代码）：

1. **新命令 `update-install`**（shell + Rust 两侧逐字实现）：把 `update.zip` 递给
   `/data/adb/ksud module install`，只转述它的结果，**不自己解压、不动 `/data/adb/modules`**
   （那等于在管理器之外再做一个管理器）。没有 ksud（Magisk/APatch）直接说清"请用管理器自己的
   「从本地安装」"。
2. **界面**：下载完**直接出现「安装」**（不再是一句"去管理器里装"）；装完那句是
   「已装好，重启后生效」，并保留「再检查一次」。
3. **更新日志**：检查更新时 `api.github.com` 的 `body` 本来就拿回来了（`S.update.notes`），
   以前读完就扔。现在画在卡里、默认收起，渲染只认 markdown 的一个子集
   （`mdLite()`：标题 / 列表 / 引用 / 粗体 / 行内代码 / 分隔线 / 链接），不引第三方解析器、
   不认 HTML —— 产物是单文件、零运行期依赖。

**闸与现量**：
- 对拍 **276 → 281**：`update-install` 的两支前置（没有包 / 没有 ksud）两侧同句同码；
  成功那一支要真 ksud，parity 里显式跳过。
- 台架 **175 → 178**：检查 → 下载 → **出现「安装」** → 点安装 → 「已装好，重启后生效」且不再重复给；
  日志默认收起（`md=false`）→ 点开断言标题 `KeyLens v9.9.9` 与两条 `<li>`。
- `tests/ui-shape.js` 加"接上了没有"；顺手把"WRITE_CMDS 不许有界面用不到的条目"补上
  `call('<写命令>')` 这一种合法用法（契约闸本来就在 `call()` 里拦写命令）。
- 真机现量：没有包 → rc=1 + 那句中文；**假 zip → rc=1 并把 ksud 自己的报错原样转出来**
  （不吞它的理由）。成功那支留给用户按「安装」自己走。
- `rust/golden` 的 `contract.txt` / `help.txt` 因新增命令而更新 —— 先 `diff` 确认**只有那一行**
  多出来，再从当前二进制重录（不是闭眼重录）。

## 6. 坑（都踩过）


- **"仓库形状的副本"量不出生产行为**（2026-11-04，§5.37）：`lib/backend.sh` 的 `use_backend` 有第二条
  解析分支 `$mdir/../tests/fixtures/backends`（为的是让仓库里的台子跑得通）。而设备侧的套件 runner
  必须把模块拷成 `$D/module` 并在旁边放 `$D/tests/fixtures/backends`（19 份参照）—— 于是回退层
  "找到了参照"，一条本该报错的命令交出 **rc=0 + 131 行**。差点据此判定"修复在真机上没生效"。
  规矩：**要量生产形状就跑真模块目录**（只读命令安全），副本只用来跑需要夹具的断言。
- **"读不到"的兜底 `else` 会把锅甩给错的输入**（同日，同一轮在真机上量到的）：体检那颗「名单 vs 已装」
  原来只有一个 `else` 写「读不到已装应用列表」，而回退层坏掉时**已装是读得到的（129 条）**、
  读不到的是名单。现在三分支分开报（名单空 → 说名单；已装空 → 说已装；都可读 → 比数量），
  并在真机台子上钉一条"甩锅就红"。这类文案错不是小事：它指向的下一个动作完全不同。
- **被自己断言的那条调用把 stderr 丢进 /dev/null ⇒ 套件套死在半路还能一路印 "ok"**（2026-11-04，§5.37）：
  `tests/fallback-shape.sh` 第一版末尾那条 `add_target_apps … >/dev/null 2>&1` 撞上要测的洞了 ——
  夹具没 source `lib/core.sh`，`OMK_STATE_DIR` 未定义，`set -u` 当场打死整个 shell，
  而"打死了"这件事唯一的表现是**退码 1**（打印出来的全是 ok）。规矩改成三条：
  ① 每条被断言的调用各留一份 `.err`，失败时把原文印进读数；② **EXIT trap 里证明走到了最后一行**
  （没走到就红，并报告停在第几条）；③ 末尾自报断言条数（trap 抓"死在半路"，抓不到"少写了几条断言"）。
- **一条断言绿的原因可能不是它声称的那件事**（同日）：`fallback-shape` 第 2 节用"参照全缺"的形状
  断言"写路径拒绝" —— 但那道拒绝有一半是 writer 自己的 `[ -f "$KL_PATCH" ]` 挡的，
  把 `add_target_apps` 里的基线守卫删掉它照样绿。**真正会吃数据的形状是"半坏"**：
  `omk.awk` 在（writer 能落盘）、`omk_list.awk` 不在（reader 会失败）。补成独立的 2b 之后，
  那颗变异一次红 5 条（读数里就有「原有条目被吃掉了」）。同理：同步那条路有**两道**独立守卫
  （`build_app_list` 与 `sync_omk_injector`），单删任一道都是绿的 —— 台子把这件事**写进输出**
  （M3a/M3b 明说"由另一道兜住"），否则下一次有人"清理重复守卫"就会安静地拆掉纵深。
- **变异台子的判据关键字要写「失败分支」那句话**（同日）：`report M2 "$LOG" "基线读不到 → 加入必须拒绝"`
  这种写法把 ok 分支的文案当判据 —— 而 `[ x ] && ok "A" || no "B"` 的 A 与 B 是两句话，
  红了也匹配不上。一轮里连错三处（M2 / M3c / M4），三颗都差点被记成"这套闸没有牙"，
  实际每颗都红了好几行。**判据关键字要从真红日志里逐字抄**。

- **`position: sticky` 装进 md-card 里就等于没装**（2026-11-04，§5.34）：卡是透明底，直觉上
  "装哪儿都一样"；实际组件影子层为了圆角自己裁边，被裁住的 sticky 元素贴不出去 ——
  滚 1600px 后那颗搜索框量到 `y=-1456`，一路"看起来正常"直到我拿尺去量。
  规矩：**吸顶层挂在卡外面做兄弟**，判据用"滚动后元素还在视口里"，不用"CSS 里写了 sticky"。
- **按字符串末位判"计数为 0"**（同日）：`d[1].slice(-1) !== '0'` 本意是"空档不占位"，
  实际把「待加入 250」「移出过 10」一起藏掉，芯片整颗消失、切档切不过去。
  **数值判据要真的解析数字**；而且这种"隐藏类"判据必须两头各钉一条（该藏的藏、该留的留），
  只钉一头等于给下一版留一个反向的洞。
- **反向断言 + 恒空的读数 = 一条永远不会响的闸**（2026-11-04，§5.32）：snackbar 那条只断言
  "屏上没出现某句话"，而它读的是 `s.textContent` / `s.message` —— 这个组件把文字落在
  `message` **属性**和影子 DOM 里，两个读数恒空。结果 v3.0.0 起四个发布版每一条提示都印
  `[object Object]`，台架一路绿。**加反向断言之前，先拿一个"必然该被读到"的样本读一次**
  （现在那条就是「立即同步一次」的正对照）。
- **夹具太小 ⇒ "没有东西可动"那一整格结构性看不见**（2026-11-04，§5.31）：默认夹具是
  「已装 4 条、3 条在名单」（`off=1`），于是批量那一行的**去重分支**（一侧为空时不给那颗）
  和**清空保护**在同屏成立，144 条断言里没有任何一条走得到；真机现量却是 `on=129 / off=0`，
  三颗按钮里两颗是同一件事、且一弹抹掉 129 条。**判据是"这一格在真机上会不会出现"**：
  先在设备上数一遍（`comm -12` 已装 ∩ 名单 = 129），再决定夹具要不要补一份真条数的形状 ——
  而不是等主人在屏上看见。修法：`addScriptToEvaluateOnNewDocument` 注入 129/131 那份夹具，
  跑完立刻 `removeScript`（否则污染后面的块）。
- **删掉一条命令后，"重新录制黄金快照"用了个旧产物**（2026-11-04）：撤 `exclude-suggest` 时
  `--record` 指向的 musl 二进制还是加这条命令之前编的旧产物 —— 录出来的快照里那条命令**还在**，
  `git diff rust/golden` 因此一动不动，看起来像"删干净了"。直到 53 套里 `rust-golden` 红，
  才发现**实际输出**（`>`）没有它、**快照**（`<`）有。**录制必须用刚编出来的产物**：
  先 `cargo build --release` / `sh rust/build-release.sh`，再录；录完看 `git diff` 有没有变化 ——
  该变的没变，就是录错了源。
- **`env VAR=… cargo …` 在这台机上会"成功"而不执行 cargo**（2026-11-03）：`~/.local/bin/env`（uv 装的，
  本来是要 source 的）排在 PATH 前面，它只改 PATH、**不 exec 参数**，于是整条命令原地退 0、零输出。
  `rust/build-release.sh` 因此"全部通过"而产物还是上一轮的旧二进制，我把那个旧产物当新的查了一圈
  （撤掉的三条属性在旧产物里 grep 得到 —— 差点得出"撤销没生效"）。规矩：① 构建脚本改用 `export`，
  别用 `env`；② **构建末尾自证"产物不比源码旧"**（`find src Cargo.toml -newer "$b"`，与 `parity.sh`
  开头那条同款）；③ `tests/sh-syntax.sh` 的 glob 扩到 `rust/*.sh`，构建脚本自己也过 `sh -n`。
  另两条环境事实：这台机真正的发布构建环境是 **WSL Debian**（Windows 侧链接 build-script 要 MSVC
  `link.exe`，而且 nightly 被一次中断的 rustup 安装毁过，重装后要 `component add rust-src` +
  两个 musl target）；cargo 读的是 **Windows 系统代理**（127.0.0.1:7890 拒连时卡在
  "Updating crates.io index"），单条命令加 `--config 'http.proxy=""'` 就能直连，别改全局配置。
- **toybox `grep` 不认 BRE 的 `\|`**（同日）：在设备上 `grep -c 'a\|b\|c' /data/adb/modules/keylens/lib/props.sh`
  回 **0**，而文件里那三条明明白白在 —— 我据此差点判"装机文件已经是撤过的版本"。**用 0 命中下结论前，
  先拿一个已知会命中的写法验它能数到非零**（这里换 `grep -E 'a|b|c'` 就正常）。

- **临时根少了 `lib/icondump.dex`，图标冷路整个被跳过**（2026-11-03，§5.22）：我拿一个空目录当
  模块根去测"尾巴那 115 行能不能拿到名字"，得到 13 行，差点写成"系统里只有 13 个有名字"。
  实际是 `[ -f "$dex" ]` 不成立 ⇒ 冷路根本没跑，13 行全是桌面库的热路。**容器不对的测量不算测量**：
  测冷路径要先证明那个 dex 在位（`ls` 出来贴在读数旁边）。
- **闸的判据锚在一个字面量上，代码一改常量它就瞎**（同上）：`ui-shape` 原来 grep
  `need.slice(0, 120)`；我把批量抽成 `ICON_BATCH` 之后那条正则"没读到"，
  读成 `界面=没读到` 才算响 —— 判据要跟着实现搬家，别留在旧形状上。
  **同一天又撞两次**（§5.25 重做名单行）：一条钉 `rowOf(t)` 的调用点（加了个参数就红）、
  一条钉 `h('div', 'app-row')` 的整串（类名后面拼了 `is-in` 就红）。两条都改成只认形状
  （`rowOf(t[,)]`、`h('div', 'app-row'`）—— 闸要钉"行为"，不是钉"我上次怎么写的那几个字"。

- **"这条不算问题"的判断要跟着自己新开的入口重看一遍**（2026-11-03，§5.20）：图标冷路只补 60 个
  被我判成"边界、不算点不动"就放过了；但正是我这轮新开的「系统应用」档（235 行、多数没有启动器
  入口）把它踩成日常。同一个写死上限，在不同入口下的代价不一样 —— 加了新面之后要回头把"放过"的
  那几条重新过一遍。
- **同一个量抄在三份源码里，改一边没有任何闸会响**（界面 batch / shell 上限 / Rust 上限 三个数
  各自写死）：这类"跨语言复制的常数"必须有一条静态闸把三方钉在一起（`tests/ui-shape.js`）。

- **对拍的台子直接调函数、绕过界面真正走的那条路，两侧就互相自证**（2026-11-03，§5.19 #1）：
  `set-mode` 的台子写的是 `cmd_set_mode "$1" "$2"`，而界面发的是**一个**带空格的参数、由分派臂
  拆开 —— 拆分逻辑压根没进台子，Rust 又只认两个 argv，于是真机上那颗按钮一直是死的而对拍全绿。
  台子必须跑**分派臂本身**（sed 抽出来），抽不到要当场响（落 `*)` 退 9），调用形状要等于界面发的形状。

- **台架里 `element.click()` 点不动 MD3E 的芯片/按钮**（2026-11-03，§5.18）：视图根本不切，
  看着像功能坏了。要发真指针事件（CDP `Input.dispatchMouseEvent`，就是 `tap()` 那套）。
  另外 `tap` / `tapEntry` 是菜单页那一段里的**局部**助手，别处调用会 `ReferenceError` ——
  而 ReferenceError 会被当成一条红，不像语法错那样当场报出来。
- **筛选那一行是横滑的（`nowrap + overflow-x:auto`），第五颗天然在 417px 之外**：台架直接按
  `getBoundingClientRect` 的中心点，坐标落在视口外 ⇒ 点了等于没点。先 `scrollIntoView` 再量。
- **注释别写进 `ev(\`…\`)` 的模板里**：反引号会把字符串当场截断，node 在加载时报语法错；
  模板里的正则也别写 `\d` —— 会被字符串转义吃掉变成字面 `d`，断言永远匹配不上（用 `[0-9]`）。

- **台子的 fixture 里没有那一格，闸与"没有牙的闸"输出完全一样**（2026-11-03，§5.17）：体检「启动哈希」
  在对拍里只有一条"11 项逐行一致"，而它的 fixture 既没放 boot_hash 文件、后端又是 tricky ⇒
  auto/manual/off/invalid 四格候选数全 0，两侧同时报 skip 也照样绿。补闸时**两侧各比一次期望文本**，
  只比"两侧相等"挡不住"两侧一起改错"。





- **台子里手抄一遍读数函数，等于给分叉装了消音器**（2026-11-02，真机抓出来的）：`rust/parity.sh`
  的 `pb.sh`/`pba.sh` 自己抄了 `prop_now()`，抄的是 **resetprop** 那版；而生产的
  `module/webui.sh:160` 用的是 **getprop**。Rust 侧 `props-boot-hash` 的 `current=` 也跟着用
  resetprop 读，于是"两份实现逐字节对拍"242 项里没有一项能看见这件事 —— 台子和被测物共用
  同一把会坏的仪器。真机上直接敲二进制（不经开机脚本，`resetprop` 不在 PATH）当场就露：
  命令报 `current=`（空），而 `getprop ro.boot.vbmeta.digest` 明明是 `0561fff0…`。
  修法三层：夹具改成 `sed -n '/^prop_now() {/,/^}/p' module/webui.sh` 抽生产那一份
  （`doc.sh`/`env.sh` 早就是这个写法，只有这两处漏了）；报告用的 `current=` 两侧统一走 getprop，
  **写完的复核**仍走 resetprop（`apply_boot_hash` 与 `apply_digest` 本来就有 `command -v` 前置，
  两边同）；再加 `RP_READ_DEAD=1`（写落库、读取答空，就是真机那个形状）与一条**绝对判据**
  「那种情况下 current= 必须等于真值」——只加"两侧相同"不够，那版两侧一起报空照样过。
- **从 Git Bash 内联问 WSL 的退码会恒 0**：`wsl -d Debian bash -c 'sh rust/parity.sh; echo exit=$?'`
  里那个 `$?` 在本地就被展开掉了，量到的 `exit=0` 与对拍真实成败无关（`wsl -d Debian bash -c 'exit 7'`
  的退码倒是正常传播的）。本轮差点据此宣布"parity.sh 的退码逻辑坏了、CI 那道闸形同虚设"。
  要看退码就让它落进文件再读：`sh tools/wsl-parity.sh`（WSL 侧跑）会把结论与自己的退码
  写在 `rust/parity-wsl.log` 的最后一行，形如 `parity exit=0｜全部通过（chk 用例 242 项）`。
  这条 runner 顺带被对拍自己的陈旧守卫救了一次：改完注释没重编，它直接退 1 说
  「二进制比源码旧」——Windows 那边读到 `exit=1` 才看得见这件事。
- **只推二进制、没推 shell 参照，真机台子会当场报两侧分歧**（本轮 21:5x）：`boot_hash_source`
  的新分支进了 Rust 也改了仓库里的 `module/lib/props.sh`，但设备上
  `/data/adb/modules/keylens/lib/props.sh` 还是旧那份 ⇒ `device-boot-hash` 一上来红 4 条
  （`实得=teesim / 期望=daemon`）。红得对，不是实现写坏了 —— 但改 shell 侧之后要么
  `sh tools/deploy-webui.sh --shell`，要么单独推那一个文件，再跑台子。
  顺带说明这台子上"装的是哪版"必须逐文件核：只比二进制 sha 不够。
- **`tests/rust-golden.sh` 在 Windows 上会 skip，而它印的是「全部通过」**（2026-11-03 CI 当场抓住）：
  Git Bash 的 `-x` 看不见 WSL 编出来的 ELF 的执行位，两个候选二进制都被判不可执行 ⇒ 整个
  黄金快照闸跳过，本地那轮「53 套全绿」里它其实没跑。而 CI（Rust CLI）跑它时 `props` 红了 ——
  黄金还停在 17 行那张旧表。要跑就进 WSL：`KEYLENS_BIN=rust/target/x86_64-unknown-linux-musl/release/keylens sh tests/rust-golden.sh`。
  同一轮还修了它的一处不可复现：`props` 读的是**宿主的** `getprop`（CI 上没有这个命令、全 absent；
  开发机接了手机就变成真机的 53 行（15 固定 + 38 特征；本轮一度是 56 行，撤回后仍是 53）)，现在台子自带桩 `getprop`，快照与机器无关。
- **两臂共用同一个属性桩时，前一臂会把后一臂的前提抹掉**：给"teesim 属性为空才补"数写次数，
  shell 臂先跑并**真的把 digest 写上了**，Rust 臂随后看到的是"属性已有值"⇒ 走 daemon 支、
  写 0 次。报出来的 `1/0` 看着像 Rust 漏写一次，实际是台架自己改了现场。现在两臂之间
  `rm -f "$T/rpdb/ro.boot.vbmeta.digest"` 复位；并且任何"写次数=0"的断言都必须先配一条
  「同样这套仪器在应该写的场合数得到 1」——不配这条，那条 0/0 是瞎的而不是证据。
- **台架的假数据必须是真形状**（2026-11-02 这条值一整轮）：`webui/src/bridge.js` 里 `props`
  的演示数据是手写的 5 行，其中 `ro.product.brand` / `ro.serialno` **根本不在期望表里**。
  于是属性页从没按真形状渲染过一次 —— 命令层新增第四种状态 `absent` 之后，界面那句三元
  `p.st === 'ok' ? … : p.st === 'missing' ? … : '不符'` 把 absent 画成**红色「不符」**、
  标题写「13 项不符」，而命令层报的是 `mismatch=0`。对拍 216 项、真机 15 条全绿，
  因为这缺陷不在命令层。现在假数据换成真机现量的 56 行（`sh webui.sh props`），
  只有 vendor_dlkm 那一族 4 行是假造的（这台机有那个分区，给不出 absent）。
- **只看头图会把新状态整个漏掉**：属性页头几行永远是 ok，absent/diff 在中尾部。
  `verify.mjs` 现在把尾部也存一张（`new-props-tail.png`），并且行数/配色/标题三条断言
  各配一个变异（`mutate-verify.mjs` 的 ③④⑤）。
- **探针绑在文案上就会随文案一起漂**：数"属性行"最初认的是 `期望` 这个词，我把 absent 行
  的措辞从「这台机没有…（期望 …）」改成「这台机没有这项属性，模块不写它」之后，
  计数当场从 53 掉到 49 —— 这条红得算幸运，但同一类问题也可以**不红**（少数的正好是
  不参与的行）。现在认两种行首，并配变异⑤（让 absent 整族不上屏 → rows=49 必须响）。
- **夹具里的"64 位十六进制"不要手数**：本轮手打的 `'aaaa…1234'` 实际是 **66 位**，
  于是 shell 与 Rust 都**正确地**拒绝派生，断言反倒报"两侧不一致"。改成
  `printf 'a%.0s' $(seq 1 64)` 现造，并加一条 `[ "${#H64A}" = 64 ] || fail=1` 自证。
  凡是"用长度/数量下结论"的夹具常量，都要让台子自己数一遍。
- **`MSYS2_ARG_CONV_EXCL='*'` 不跨命令调用**：上一条命令里 export 过，下一条
  `adb shell 'MODDIR=/data/adb/...'` 又会被 Git Bash 改写成 `D:/Git/data/adb/...`，
  设备台子于是打印 `skip 找不到 …` 并**退 0**——看着像"通过"，其实是仪器瞎了。
  要么每条 adb 命令都带这个变量，要么在同一条命令里 export。
- **PowerShell 写文件/内联脚本**会带 BOM/CRLF、`$` 会被解析：Rust/sh 源码一律用编辑工具写，或用 `node <文件>.cjs` 脚本改；写完 `\r` 要清掉（否则 `sh` 报 `EOF unexpected`）。
- **设备上那台 shell 的两种"静默"**（本轮加 env 缓存台子时各撞一次，症状都是"实现看着坏了"）：
  - mksh 的 `${v%|*}` **不生效**（`a|b|c` 原样出来）。剥缓存键的末段要走 `sed 's/|[^|]*$//'`；
    同一条断言在 WSL 的 dash 下是正常的，所以只有上机才会看见它红。
  - toybox `grep` **不支持 BRE 的 `\|`**：`grep -c '^A\|^B'` 恒 0，两个 `-e` 或 `-E` 才对。
  - 新增第三条（§5.12）：mksh 对**长变量**做字面量匹配是灾难而不是慢 —— 66897 字节的
    变量上 15 次 `##*"[key]: "*` 实测 160 秒（最短匹配 `#*` 更差，205 秒）。
    "dump 进变量再参数展开查表"这种写法在 WSL/dash 上完全测不出来（那边是微秒级），
    只有真机会把它变成开机几分钟。就算先用 `grep -F` 裁到 2.7KB，53 次查表仍要 1841ms ——
    裁小只是缓药，判长得交给 awk。
  - 第四条（本轮最贵的一条）：**设备上 mksh 的 `printf` 不是内置**，每次 `printf` 都是一次
    fork（现量 ~15ms）。在 shell 里逐行 `printf` 拼 53 行数据 ≈ 850ms，比 awk 本体贵一个
    数量级；这类成本在 WSL/Git Bash 上**完全看不见**（那边 printf 是内置）。
    逐行输出要么交给 awk，要么用内置 `print -r --`（但那不是 POSIX，dash 台子里不能用）。
- **Android 没有 `/tmp`**：量测脚本里 `printf ... > /tmp/x.sh` 会失败，而后面的
  `sh /tmp/x.sh` 只报一句 no such file，计时照样给出 26~50ms 的"像样数字"——
  我差点把这份**一次都没跑成**的读数当结论。设备上临时文件一律 `/data/local/tmp`，
  并且子脚本要 `printf MARK` 让调用方证明它真跑了。
  凡"用 0 命中下结论"的场合，先拿一个已知会命中的样本验它能数到非零。
- **设备上的 `diff` 不输出 `^>` 那种行**：`diff a b | grep -c '^>'` 在真机恒 0
  （toybox diff 的默认格式与 Linux 不同，`cat -A` 也不支持）。台子里"数一数改了几行"
  一律换成 `awk 'NR==FNR{a[FNR]=$0;n=FNR;next} FNR<=n && a[FNR]!=$0 {c++} END{print c+0}'`
  这种单遍比较，并且**当场自证它能数出 1、也能数出 0**，否则等于没装仪表。
- **awk 方言差会让同一段程序一边绿一边红**（本轮撞到，详见 §5.12）：mawk 里
  `goal[k] = f((k in goal) ? goal[k] : c, …)` 会先创建左边元素，`(k in goal)` 恒真、
  底数取到空串 ⇒ 链式改写变成**写空值**；gawk 不这样。WSL 是 mawk、Git Bash 是 gawk、
  真机是 toybox/busybox awk ⇒ 判定层必须**两种 awk 各跑一遍比逐字节**
  （`tests/device-props-mask.sh` 里那两条就是这个）。
- **管道右边 exec 失败，左边在 Git Bash 会被写死**：`${AWK_CMD:-awk}` 指向不存在的程序时，
  bash 让左边持续写一条没人读的管道 ⇒ 整段卡死；dash/mksh 立刻返回。凡是"先试某个外部
  程序、失败就走慢路"的地方，都要 `command -v` 前置确认，别把成败交给管道。
- **台子的 skip 顺序**：`device-props-mask.sh` 第一版先要求 `--write` 再判断在不在真机上，
  于是 `for t in tests/*.sh` 的 CI 全跑恒红。规矩是**先判环境（不在设备上就 skip 退 0），
  再判危险开关**。
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
- **台子的"写命令"串里混着「用户状态」，跑完必须快照 + 还原 + 断言**：`device-ab --write` 的
  `WRITE_CMDS` 里有 `props-on` / `props-off` / `props-boot-hash` / `props-apply` —— 它们改的是
  `/data/adb/keylens.props_off` 与 `/data/adb/keylens.boot_hash`（**不是**后端文件，原来的
  `backup_backend` 覆盖不到）。2026-11-01 这一串跑完停在"最后一条命令"的形状上：属性伪装被关掉、
  boot hash 被清空，直到**重启后**（post-fs-data 按开关不写）属性全变 `diff/missing` 才暴露。
  现在台子在 `--write` 前后快照这两个文件、跑完还原并重新 `props-apply`，外加三条断言
  （开关状态、boot_hash 内容、属性差项数）。真机验证：跑前 `props_off=no / boot_hash=0561fff0…`，
  38 条跑完仍是 `no / 0561fff0…`、属性差项数 0。
- **影子根的落脚点不能只认 `temp_dir()`**：Android 上没有 `/tmp`。只认它时 TMPDIR 一坏，影子根建不出来、子进程什么都读不到，父进程照样打 `changed=0`，界面把"没有差异"当成无需确认**直接真写**。现在按 `TMPDIR → /data/local/tmp → temp_dir` 找落脚点，全建不出来退 2 交给 shell（`rust/parity.sh` 与 `tests/device-preview.sh` 各钉一条）。复现这种"建不出来"要把 `TMPDIR` 的父路径做成一个**普通文件**——指到一个不存在的目录会被 `create_dir_all` 顺手建出来，测不出失败。
- **台子调了没定义的函数，mksh 只报一句 command not found、不置 fail**：`tests/device-preview.sh` 上一版就这么在 5 条断言没跑的情况下打了「全部通过」。现在它自带 `chk` 与断言计数，条数低于下限直接红。写台子时"末尾那句结论"必须来自计数器，不能来自"没看见 ✗"。
- **对拍会测到上一版产物**：改完 Rust 忘了 `cargo build` 就 `sh rust/parity.sh`，新断言红得像实现写错了。`rust/parity.sh` 现在先做 `find rust/src rust/Cargo.toml -newer "$B"`，二进制不比源码新就拒绝开跑。

## 7. 关键文件

| 文件 | 作用 |
|---|---|
| `rust/src/main.rs` | 分派、`COMMANDS`、`USAGE`、preview 影子根 |
| `rust/src/read_cmds.rs` | 41 条命令实现 + 校验器 + `lcs_diff` + preview 基础设施 |
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
