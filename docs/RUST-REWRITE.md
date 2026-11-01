# 命令层 Rust 重构：方案与阶段

> 目标：把 `module/webui.sh` + `lib/*.sh` + `backends/*.awk`（读/写/校验/keybox/锁/diff）
> 逐步迁到 Rust 静态二进制 `keylens`，**UI 与命令契约完全不变**。

## 硬约束（决定"能重构到什么程度"）

1. **入口脚本必须保留 shell**：`post-fs-data.sh` / `service.sh` / `customize.sh` /
   `action.sh` / `uninstall.sh` 是管理器在固定阶段执行的文件，这是模块规范，不是选择。
   重构后它们只是薄壳：`exec "$MODDIR/bin/keylens" <子命令>`。
2. **契约不变**：同命令名、同 `kv`/`tsv` 输出（逐字节对拍）、同 `KL_API=4`。
   `webui.sh` 保留为转发壳（`exec bin/keylens "$@"`），界面不用改一行。
3. **ABI**：发布产物用 `aarch64-unknown-linux-musl`（自带 `crt-static`，产物 `NEEDED=0` / 无 INTERP），
   **不用** `aarch64-linux-android` —— 那个 target 默认动态链 bionic，与"静态、不依赖动态库"这条判据互相矛盾
   （CI 第一次真跑就是被这个红的，2026-11-01）。本机不用 NDK 就能交叉编译（rust-lld + link-self-contained），
   armeabi-v7a / x86_64 按需再加。
4. **SELinux / 权限**：写回要复刻 `write_atomic_preserve` 的 chown/chmod/chcon 与
   `.bak` 语义；不能只换实现不换约束。

## 阶段

- **阶段 0（本目录）**：骨架。`rust/` 可编译出 `contract`，命令分发表完整（40 条），
  未迁移的命令返回 2。CI 交叉编译出 aarch64 静态二进制（artifact），不接入模块。
- **阶段 1（只读）**：`contract / env / status / backend-info / targets / target-meta /
  apps / icons / log / excluded / tee-status / teesim-profiles / tricky-patches /
  teesim-overrides / boot-hash`。每一条：实现 + 对拍（`sh webui.sh X` vs `keylens X`
  逐字节相同，含错误路径与空数据）。
- **阶段 2（写模型）**：`kv`/`tsv` 输出、payload 解析（b64）、`webui_lock`、原子写 +
  备份 + 权限/SELinux 复刻；先接 `restore-app(s)` / `remove-apps` / `set-mode`。
- **阶段 3（三家 writer + 校验）**：Tricky 行尾语法、TEESim config.json（嵌套 profile /
  patchLevel）、OMK TOML（标量/数组/多行 + `[crypto]` 不可清空）+ keybox 结构校验
  （按后端分叉的判据照抄现有 `keybox_check.awk` 规则）。四条 `*-save` 命令迁移。
- **阶段 4（daemon/同步）**：`service.sh` 的 inotifyd 循环与 `run_sync` 逻辑迁入
  Rust（保留 shell 入口启停）；`doctor` / `backups` / `backup-restore` / `diff 预览`。
- **阶段 5（切换与退役）已做完**（2026-11-01）：`webui.sh` 转发 + `run_sync` 优先二进制 + `preview-*` 交给影子根；awk 参照实现移进 `tests/fixtures/backends`（发布包不再有 awk，缺 `bin/keylens` 时安装中止）；30+ 套 shell 测试
  改为对拍测试（同一套输入，输出必须一致）；补体积/启动时间实测。

## 验收

- 每条命令：正常 / 空数据 / 错误输入三组输出与 shell 版逐字节相同；
- 写命令：沙箱文件系统上的写回结果（内容、权限、备份、重载请求）逐字节相同；
- 上机：真机 `sh webui.sh <cmd>` 与 `keylens <cmd>` 输出 diff 为空；
- 回归：现有 30+ 测试套逐套迁移或经对拍证明等价后退役。

## 现状

- 本机**没有 Rust 工具链**，构建放 CI（`.github/workflows/rust-build.yml`）。
- `rust/` 目前是阶段 0 骨架，未接入模块、不影响发布。

## 进度

- ✅ 阶段 0：分发表（40 条与 KL_COMMANDS 逐字同序）+ contract + rust/parity.sh。
- ✅ 阶段 1（部分）：help（逐字节）、log（clamp/tail/logcat 兜底，9 例）、backups（.bak 映射/tsv/mtime，3 例）、后端探测（backend.rs，4 个单测）。对拍合计 15 项全绿；后端探测带 KEYLENS_ROOT 测试缝。
- ✅ 阶段 1（只读）已完成 15 条：contract / help / log / backups / status / targets（三家）/ target-meta / apps / excluded / boot-hash / tee-status / props / tricky-patches / teesim-overrides / teesim-profiles。
- ✅ 阶段 2 已开始：并发锁（lock.rs，4 单测）、set-mode、props-on/off、props-boot-hash、omk-restart、clear-log。
- 对拍：70 项（rust/parity.sh，CI 内跑）+ 单测 16 项。
- 已迁移 **40/40**：只读 15 条 + 写侧 25 条，命令层全部在 Rust 里（`rust/src/read_cmds.rs` 约 5.4k 行）。
  - 只读：contract / help / log / backups / status / targets / target-meta / apps / excluded / boot-hash /
    tee-status / props / tricky-patches / teesim-overrides / teesim-profiles / doctor / env / backend-info / icons
  - 写侧：set-mode / props-on / props-off / props-apply / props-boot-hash / omk-restart / omk-save-injector /
    omk-save-config / clear-log / tricky-drop-patch / tricky-save-patch / teesim-save / teesim-save-overrides /
    teesim-profile-new / teesim-profile-del / keybox-save / backup-restore / restore-app / restore-apps /
    remove-apps / sync
- 未迁移清单 `LEFT` 已清空（漂移闸由分发表反推，空清单代表"没有未迁移命令"）。
- 体积（本机实测，release + strip 前）：x86_64 glibc **633 KB** / x86_64 静态 musl **730 KB**；
  aarch64 静态由 CI 的 `rust-build.yml` 产出并上传 artifact。
- 对拍：**128 项 chk**（`rust/parity.sh`，CI 内跑）+ 单测 **66 项**；另有两道闸：
  未迁移清单漂移闸（由分发表反推）与迁移覆盖率闸（`tests/rust-parity-coverage.sh`）。

## json_flat_set.awk 的规格（下一步实现用）

输入：`pairsfile`（每行 `键<TAB>值`）、`overrides.json` 文本；输出：改后的 JSON 到 stdout，状态写 `statusfile`（`ok`/`same`/`missing`）。

1. 定位顶层对象：第一个 `{` 与配对的 `}`（配对时跳过字符串内的括号与转义）。
2. 顶层扫描（深度 1 才算键）：读到 `"` 取键名，跳过空白要求 `:`，再跳过空白取**值区间**：
   - 值以 `"` 开头 → 值区间到闭合引号（含）；
   - 否则到 `,`/`}`/换行，并回退掉尾部的空格/制表/`\r`。
3. 对每个键（**按 pairs 顺序，逐个处理**，每处理一个就重新定位）：值非空 → 原区间替换为 `"转义后的值"`；值空 → **整条成员删除**（含键名、冒号、逗号与该行残留空白）：
   - 优先吃掉后面的逗号；若是最后一个成员则改吃前面那个逗号；
   - 若前后都是换行，把这一行连同换行一起删，否则只删内容保留换行。
4. 处理完已有的键后，把**不存在且值非空**的键整批插到顶层 `}` 之前：
   - 每项 `    "键": "值"`，项间 `,\n`；
   - 原对象是 `{}` → `{` + 换行 + 条目 + 换行 + `}`（不加逗号）；
   - 原对象以 `,` 结尾 → 直接接条目（不再补逗号）；
   - 否则补 `,` + 换行 + 条目 + 换行。
5. 值一律渲染成**带引号的 JSON 字符串**（数字/布尔也写成字符串）——上游守护进程按 `Map<String,String>` 读，写裸数字会造成形状不一致。
6. 转义只处理 `\` `"` `\t` `\r` `\n`；其余字符原样。
7. 一个键都没改 → `same`（不落盘）；顶层对象找不到/括号不配对 → `missing`。
8. 调用方（cmd_teesim_save_overrides）：空值=删键；`overrides.json` 不存在时以 `{}\n` 为底本；写入用 `overrides.json.bak` 备份、落盘后 `chmod 644`（守护进程以 keystore 身份读）。

## 待移植 writer 的体积清单（按行数排，决定顺序）

| 文件 | 行数 | 服务于 | 备注 |
|---|---|---|---|
| entry_base.awk | 19 | excluded / ever | 已等价实现（Rust 内联） |
| tricky_list.awk | 31 | targets | 已实现 |
| omk_list.awk | 36 | targets | 已实现 |
| tricky_info.awk | 43 | backend-info | 待做 |
| tricky_mode.awk | 47 | set-mode | 已实现 |
| tricky_patches.awk | 51 | tricky-patches | 已实现 |
| teesim_list.awk | 53 | targets | 已实现 |
| omk.awk | 66 | backend-info | 待做 |
| **keybox_check.awk** | **78** | keybox-save / backup-restore | **下一个做**（两家校验都靠它） |
| teesim_overrides.awk | 99 | teesim-overrides | 已实现 |
| teesim_profile.awk | 105 | profile-new / del | 之后 |
| tricky_patch_set.awk | 117 | tricky-save-patch | 已实现（写入分支） |
| omk_info.awk | 136 | backend-info | 之后 |
| teesim_profiles.awk | 152 | teesim-profiles | 已实现 |
| teesim_info.awk | 157 | backend-info | 之后 |
| json_flat_set.awk | 162 | teesim-save-overrides | 已实现 |
| teesim_set.awk | 178 | teesim-save | 大件 |
| omk_set.awk | 196 | omk-save-* | 最大件 |

## 体积实测（29/40 命令时）

- x86_64 release（opt-level=z + LTO + strip）：**502,400 字节（约 490 KB）**；
- 现有 shell 命令层（webui.sh + lib/*.sh + backends/*.awk）合计 **268,059 字节（约 262 KB）**；
- 刷机包现状约 397 KB，接入后预计 **约 0.9 MB**——对 KernelSU 模块仍属正常量级（「体积可控」达成，aarch64 静态会略有差异）；
- 未接入的 11 条命令实现后按当前密度估算增量 < 100 KB。

## 剩余 11 条的入口位置（下一窗口直接从这里读，省一轮定位）

| 命令 | 实现位置 | 依赖 |
|---|---|---|
| restore-app | lib/write.sh:53 | add_target_apps + 三家 writer |
| restore-apps | lib/write.sh:83 | 同上 |
| remove-apps | lib/write.sh:136 | 同上 + 「至少保留一条」 |
| teesim-save | lib/write.sh:198 | teesim_set.awk(178) + 字段白名单 |
| omk-save-injector | lib/write.sh:277 | omk_set.awk(196) + intercept 开关 |
| omk-save-config | lib/write.sh:347 | 同上 + [crypto] 不可清空 |
| sync | lib/write.sh:1016（薄壳 10 行） | 真正工作在 backend.sh:645 的 run_sync：快照差分 + 三家写入 + KL_EMPTY_OK，**不是小件** |
| backend-info | webui.sh:587 | teesim_info.awk(157) / omk_info.awk(136) / tricky_info.awk(43) |
| env | webui.sh:809 | 工具探测 + 缓存 + FRRO |
| icons | webui.sh:1098 | sqlite3 + app_process(icondump.dex) + 缓存 |
| doctor | webui.sh:1334 | 11 项聚合检查 |

## 未推送提交的备份（网络受阻时的兜底）

2026-11-01：GitHub 域名 DNS 解析失败、本机无代理监听，已有 57 个提交只存在于本机。
已导出 git bundle（仓库上一级目录）：keylens-unpushed-2026-11-01.bundle（约 86 KB）。

恢复方式（任意克隆后）：

`sh
git fetch /path/to/keylens-unpushed-2026-11-01.bundle main:recovered
git log --oneline main..recovered      # 应列出那批提交
git merge recovered                     # 或 cherry-pick
`

网络恢复后先 git push origin main，再删掉这份 bundle。

## 迁移过程中踩过的坑（写下来，别再踩第二遍）

1. **PowerShell 会毁掉源码**：`Set-Content` 带 BOM（编译报 `unexpected closing delimiter` / `unknown start of token: \u{feff}`）、
   `-replace | Set-Content` 在中文串上乱码（报 `unterminated double quote string`）、`node -e …$($arg)…` 会被
   PowerShell 先做变量插值（宏定义被吃成空规则）。**结论：只用编辑工具或 Node 写文件；写含 `$` 的代码绝不走 PowerShell 字符串。**
2. **别为消警告盲改同名绑定**：编译器说的未使用可能指另一个函数里的同名变量；盲改会把在用的名字改掉，
   直接编不过（`is_blank` / `depth` 各踩一次）。改警告要按行号逐个确认。
3. **`println!` 在管道被关时会 panic**：Rust 默认忽略 SIGPIPE，`keylens contract | head -1` 会 `Aborted`。
   全部输出已改走 `println_ok!` / `eprintln_ok!`（`writeln!` + 忽略错误），并有回归用例守着。
4. **`json_flat` 的 `span_of` 只能用于扁平对象**：拿它扫 `profiles`（值是嵌套对象）时，值对象的 `}` 会让深度算错，
   后续键永远找不到。嵌套场景要用 `member_span`（遇到 `{`/`[` 用配对跳过）。
5. **对拍夹具不能两边共用一份文件**：写命令会先改掉它，后跑的一侧就看不到原始状态（`set-mode` 踩过）。
   要么每侧各建一份，要么只比输出不比结果。
6. **删/改 JSON 成员时的逗号**：整条删除要连键名、冒号、逗号与行内空白一起吃掉；中间的成员吃后面逗号，
   最后一个成员改吃前面逗号；前后都是换行时连行删。否则留下 `a: ,` 这种守护进程读不了的东西。
7. **文档也会触发代码闸门**：`rust/README` 里写了本机绝对路径（旧仓库名），直接让残留闸变红、连带
   `legacy-migrate.sh` 的变异测试失败。文档里的路径一律用占位符。
### doctor 的检查项（已读，实现时照此逐条）

1. 权限：kl_is_root → ok/bad（bad 建议「在管理器里给 root」）；
2. 后端：探测到 → ok（ackend_name · 配置 <目标文件>），否则 bad；
3. 守护进程：.kl_daemon_pids.list 里 kl_pid_is_ours 的数量 → ok/bad（0 个时提示重启或重刷）；
4. 目标文件：存在且可写 ok / 不可写 warn / 不存在 bad；
5. 名单 vs 已装：只比数量（current_target_apps 行数 vs cmd package list packages -3 行数），名单少于已装给 warn；读不到已装 → skip；
6. keybox：ackend_keybox_path 的文件存在性 + keybox_check（按后端）→ ok/bad；
7. 其余（日志/锁/属性/哈希等）继续读 1394 之后即可。

输出：	sv 类别 状态 说明 建议，末尾 kv checks N / kv bad N / kv warn N。

#### doctor 完整检查序列（已读全，实现时按序）

| # | 类别 | 判据 | 状态 |
|---|---|---|---|
| 1 | 权限 | /proc/self/status 的 Uid 为 0（读不到退回 id -u） | ok / bad |
| 2 | 后端 | 探测成功 → ackend_name · 配置 <目标文件> | ok / bad |
| 3 | 守护进程 | .kl_daemon_pids.list 中 cmdline 认得出本模块的个数 | ok(>0) / bad |
| 4 | 目标文件 | 存在且可写 | ok / warn(不可写) / bad(不存在) |
| 5 | 名单 | current_target_apps 行数 vs cmd package list packages -3 行数（只比数量） | warn(少) / ok / skip(读不到) |
| 6 | keybox | 路径存在 + 按后端结构校验 | ok / bad(不存在或不合格) / skip(缺 awk) |
| 7 | 属性伪装 | 开关文件存在 → 关闭 ok；否则逐项比 15 条期望值 | ok / warn(有差异) |
| 8 | 启动哈希 | 未配置 skip / 格式错 bad / 相等 ok / 不等 warn | skip/ok/warn/bad |
| 9 | 监听工具 | ind_inotify_cmd 的 mode | ok / bad |
| 10 | 并发锁 | .kl_lock 是否存在、持有者是否活着 | ok(空闲) / warn(占用或残留) |
| 11 | 日志 | 文件存在 → 字节数 | ok / skip |
| — | 无后端时 | 3–11 逐条 skip 没有后端，跳过 | skip |

输出：每行 类别<TAB>状态<TAB>说明<TAB>建议，末尾 kv checks 总数 / bad / warn / skip（skip 不计入 checks）。

### 名单写入的真实落点（已探明，下一步先迁它）

- `cmd_restore_app`（`write.sh:53`）：校验 + 加锁 + 调 `add_target_app` + 刷新描述里的条数，输出 `restored 1/0`；
- `add_target_app`（`backend.sh:234`）：薄包装，把包名写成临时文件转给批量版；
- **真正的 writer：`add_target_apps`（`backend.sh:152`）** —— 按后端分叉写目标文件
  （tricky 追加行 / teesim 改 `config.json` 的 `apps` / omk 改 `scoop` 数组），并更新 ever 名单与模块描述；
- `remove_target_apps`（`backend.sh:248`）同理，额外守「整份名单不许被清空」（返回 3），
  并把实际移出的条目放进 `KL_REMOVED_LIST` 供界面撤销。

**顺序结论**：先迁这份 writer，再一次性拿下 `restore-app` / `restore-apps` / `remove-apps` 三条。

#### 但这份 writer 比看上去大：它还依赖两个"列表写入"的 awk

读完 `add_target_apps`（`backend.sh:152-233`）后确认，三条命令合起来要移植的是：

1. **去重逻辑**：按基础包名判重（tricky 去 `?`/`!`；teesim 去 `@数字`、`uid:` 丢弃），
   但 **teesim 的 `pkg@用户` 允许与裸 `pkg` 并存**（独立作用域，撤销要用），tricky 的模式与裸包名互斥；
   判重要用 `FILENAME == ARGV[1]` 语义（cur 为空时 `NR==FNR` 会把新包当成"已存在"吞掉——真机上就是返回 1）。
2. **写入分叉**：
   - tricky：`cat 目标文件` + 补末尾换行 + 追加新行；`chmod 644`、`mv` 覆盖；
   - teesim：调 `$KL_PATCH`（`teesim.awk`，**尚未移植**）按 `listfile` 重写 `config.json` 的 apps，成功后 `chmod 600` + `chown root:root`；
   - omk：调 `omk_write_list`（**尚未移植**）重写 `injector.toml` 的 scoop 数组。
3. **善后**：`entries_to_bases` + `ever_add_list` 更新 `.kl_ever`；`restore-app` 还要 `update_module_desc` 刷新描述条数。

所以正确的下一步不是直接写 `restore-app`，而是先补 **`teesim.awk` 的 listfile 模式** 与 **`omk_write_list`** 这两个列表写入器
（各自都要能对拍：给定新旧列表，写回的 `config.json` / `injector.toml` 与 shell 版逐字节一致）。

**再往下读一层（`omk_write_list`，`backend.sh:460`）**：它本身也只是个外壳——真正重写 `scoop` 的是
`$KL_PATCH`（即 `omk.awk`，196 行）；`teesim` 那条同理落在 `teesim.awk`（178 行，listfile 模式）。

所以完整依赖链是：

```
omk.awk / teesim.awk（各 ~180-200 行，TOML / 嵌套 JSON 写入）
        ↓
add_target_apps / remove_target_apps（去重 + 分叉 + ever/描述）  ← 去重部分已完成（new_target_entries + 4 单测）
        ↓
restore-app / restore-apps / remove-apps（三条命令）
```

`omk_write_list` 还额外负责保存目标文件的 **uid:gid / mode / SELinux 上下文**（`stat -c %u/%g/%a`、`ls -Zd`），
写回前 `chown`/`chmod`/`chcon`，并先 `cp -p` 到 `injector.toml.bak`；内容不变时返回 1（不写、不备份）。

## 阶段 5 已预置的开关（可做真机 A/B）

`module/webui.sh` 里有一段用 `# >>> rust-dispatch` / `# <<< rust-dispatch` 包住的转发逻辑：

- `KL_USE_RUST=1` 且 `KL_RUST_BIN`（默认 `$MODDIR/bin/keylens`）可执行时，命令先交给 Rust；
- Rust 返回 **2**（未迁移）→ 不接管，回落原 shell 分派；`preview-*` 一律不接管；
- 默认不设这两个变量 → **行为与现在完全一致**，所以可以随包发布。
- 真机验收：`KL_USE_RUST=1 sh webui.sh <cmd>` 与 `sh webui.sh <cmd>` 输出逐字节比对；
- `tests/rust-dispatch.sh` 用「按标记抽取 + 假二进制」的方式测这条通路（不需要 root，也不需要真机）。


## 阶段 5：发布包怎么带二进制

ust-build.yml 现在产出两个 artifact：

- keylens-aarch64：裸二进制（调试/替换用）；
- keylens-module-aarch64：module/ 全量 + in/keylens + in/keylens.sha256，**装机的发布包用这个**。

上机后先核对指纹：sha256sum /data/adb/modules/keylens/bin/keylens（应与包内 .sha256 一致），
再逐条 A/B：KL_USE_RUST=1 sh webui.sh <cmd> 与 sh webui.sh <cmd> 输出 diff 为空。

全部通过后再把 module/webui.sh 里的 ${KL_USE_RUST:-0} 改成 :-1（一行），
shell 分派保留一个版本作为回退；之后才动 ackends/*.awk 的删除。

## 真机 A/B 一键脚本

	ests/device-ab.sh（手机上以 root 跑）：

- 逐条对比 KL_USE_RUST=0 sh webui.sh <cmd> 与 KL_USE_RUST=1 ...，输出必须逐字节一致；
- 易变字段先归一化（更新: HH:MM、keybox_mtime、uptime、pid、N 字节）；
- 默认只跑 20 条只读命令；加 --write 会把写命令也跑一遍，并在每轮前后自动备份/还原后端文件；
- 非 root 或没有 in/keylens 时明确 skip（不制造假绿灯）。

全绿之后再改 KL_USE_RUST 的默认值 → 再删 awk（顺序见 docs/AWK-REMOVAL.md）。
