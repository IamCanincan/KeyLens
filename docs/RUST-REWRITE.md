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
- 对拍：58 项（rust/parity.sh，CI 内跑）+ 单测 8 项。
- ⏳ 余项：只读 env / backend-info / icons / doctor；写 props-apply / restore-app(s) / remove-apps / 四条 *-save / keybox-save / backup-restore / sync；KL_PREVIEW 预览。
