# 命令层 Rust 重构：方案与阶段

> 目标：把 `module/webui.sh` + `lib/*.sh` + `backends/*.awk`（读/写/校验/keybox/锁/diff）
> 逐步迁到 Rust 静态二进制 `keylens`，**UI 与命令契约完全不变**。

## 硬约束（决定"能重构到什么程度"）

1. **入口脚本必须保留 shell**：`post-fs-data.sh` / `service.sh` / `customize.sh` /
   `action.sh` / `uninstall.sh` 是管理器在固定阶段执行的文件，这是模块规范，不是选择。
   重构后它们只是薄壳：`exec "$MODDIR/bin/keylens" <子命令>`。
2. **契约不变**：同命令名、同 `kv`/`tsv` 输出（逐字节对拍）、同 `KL_API=4`。
   `webui.sh` 保留为转发壳（`exec bin/keylens "$@"`），界面不用改一行。
3. **ABI**：至少 `aarch64-linux-android`（静态 musl），体积目标 < 2 MB；
   armeabi-v7a / x86_64 按需再加（CI 交叉编译，不依赖本机工具链）。
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
- **阶段 5（切换与退役）**：`webui.sh` 改为转发；awk 文件删除；30+ 套 shell 测试
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
- 已迁移 29/40：只读 15 条 + 写侧 14 条（set-mode / props-on/off / props-apply / props-boot-hash / omk-restart / clear-log / tricky-drop-patch / tricky-save-patch / teesim-save-overrides / keybox-save / backup-restore / teesim-profile-new / teesim-profile-del）。
- ⏳ 余项：只读 env / backend-info / icons / doctor；写 props-apply / restore-app(s) / remove-apps / 四条 *-save / keybox-save / backup-restore / sync；KL_PREVIEW 预览。

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
| sync | lib/write.sh:1016 | run_sync / 快照差分 |
| backend-info | webui.sh:587 | teesim_info.awk(157) / omk_info.awk(136) / tricky_info.awk(43) |
| env | webui.sh:809 | 工具探测 + 缓存 + FRRO |
| icons | webui.sh:1098 | sqlite3 + app_process(icondump.dex) + 缓存 |
| doctor | webui.sh:1334 | 11 项聚合检查 |
