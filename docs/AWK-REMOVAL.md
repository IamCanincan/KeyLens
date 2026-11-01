# 删 awk 的施工单（阶段 5 最后一步）

> **2026-11-01 已执行完（本文件留档）。** 实际做法与本单有一处不同，且是刻意的：
> 19 份 awk **移进 `tests/fixtures/backends/` 而不是删除**——shell 参照实现留着，
> `rust/parity.sh` 那 175 项"两套实现逐字节对拍"这张网才没被拆掉；发布包里不再有 awk，
> 效果与删除等价。第 2 步（回退路径改成"必须有二进制"）落在 `customize.sh`：包里没带
> `bin/keylens` 直接 `abort`。第 4 步（退役 parity 的 shell 侧）**没做**，也不需要——
> 参照仍在仓库里。第 5 步（清理无人调用的 shell 函数）仍待做。
> 唯一新增的前提：**真机台子要先把参照推进 A/B 树**（`sh tools/deploy-webui.sh --shell`
> 或 HANDOFF §3 的那一行），三个 device 台子都加了这条前置并在缺失时报红而不是沉默。

> 当初的现状：19 份 `module/backends/*.awk`，被 `module/` 里 30 余处调用；Rust 侧已 40/40 等价实现。
> 删除**不能一把梭**：shell 分派仍是回退路径，删早了会把回退路径打断。

## 依赖面（实测）

| awk | 引用文件数 | 备注 |
|---|---|---|
| `teesim.awk` | 11 | 最大件：`apps` 数组读写、条目录入/移除 |
| `keybox_check.awk` | 7 | 写前校验（`keybox-save` 的闸门） |
| `omk.awk` | 6 | scoop 读写 |
| `tricky_patch_set.awk` | 6 | 全局段写入 |
| `omk_info` / `teesim_set` / `omk_set` / `entry_base` | 4-5 | 摘要与定值 |
| 其余（`*_list`、`tricky_mode`、`teesim_profile(s)`、`tricky_patches`…） | 3-4 | 只读枚举 |

`tests/` 里直接依赖 awk 的：`backend-edit-scope`、`backup-restore`、`config-write`、`keybox-shape`、`omk`、`remove-app`。

## 安全顺序（每步都可回滚）

1. **先删"没有 shell 调用者"的**：核对每个 awk 的调用点，只有 Rust 侧用到的先删（`verify`：`grep -rn '<名>.awk' module/` 为空）；
2. **再把 shell 调用点改成"必须有二进制"**：`require_runnable` 之后加一句——若 `$MODDIR/bin/keylens` 不存在就明确报错「本版本需要 bin/keylens，请重新安装完整包」。这样回退路径从"跑 awk"变成"报错"，不会静默写坏文件；
3. **删剩余 awk**，同时把 `tests/` 里 6 个依赖 awk 的用例改为：对拍（若仍有 shell 参照）+ 黄金快照（已就位）；
4. **退役 `rust/parity.sh` 的 shell 侧**：删 awk 后 harness 抽不到 shell 函数，改用 `tests/rust-golden.sh` + 单测；`parity.sh` 保留 contract/EPIPE/漂移闸三项（它们不依赖 awk）；
5. **最后**把 `module/lib/*.sh` 里不再被调用的函数删掉（先 `grep` 确认零引用）。

## 删除前的最后确认

- 真机上 `KL_USE_RUST=1` 与 `KL_USE_RUST=0` 的 40 条命令输出 diff 为空（**未做**，需要设备）；
- `keylens-module-aarch64` artifact 里 `bin/keylens` 的 sha256 与 `.sha256` 一致（装完后核对）；
- CI 两条闸（`tests/module-bin.sh`、`tests/rust-golden.sh`）都在跑。

## 现在就能做的一步

> **2026-11-01 实测：这一步已经不存在了。** 按 `grep -rl <名>.awk module --include=*.sh` 重数一遍，
> 19 份 awk **每一份都还有 shell 引用**（含下表的 `entry_base.awk`，它现在是 `lib/applist.sh:124`
> 的 `helper="${patch%/*}/entry_base.awk"`）。也就是说第 1 步能删的个数为 0，
> 剩下的 2/3/4 步（回退路径改成"必须有二进制" → 删 awk → 退役 parity 的 shell 侧）
> 是一个**拆不开的原子改动**：删了 awk，parity.sh 那 175 项里靠抽 shell 函数比对的绝大部分同时失去参照。
> 下面这张旧表留着当历史，数字别再引用。

第 1 步（删无人调用的 awk）不需要设备。但要注意：**只删"module/ 里零引用"的**——
若某个 awk 仍被 shell 调用，删了会让回退路径在设备上直接报「缺少 xxx.awk」。

### 实测调用点（`grep KL_PATCH` 计的 shell 调用处）

| awk | shell 调用 | awk | shell 调用 |
|---|---|---|---|
| `entry_base.awk` | **0** | `teesim_profile.awk` | 4 |
| `json_flat_set.awk` | 2 | `teesim_profiles.awk` | 2 |
| `keybox_check.awk` | 4 | `teesim_set.awk` | 2 |
| `omk.awk` | 1 | `tricky_info.awk` | 2 |
| `omk_info.awk` | 2 | `tricky_list.awk` | 1 |
| `omk_list.awk` | 1 | `tricky_mode.awk` | 2 |
| `omk_set.awk` | 4 | `tricky_patch_set.awk` | 4 |
| `teesim.awk` | 1 | `tricky_patches.awk` | 2 |
| `teesim_info.awk` | 4 | `teesim_overrides.awk` | 3 |
| `teesim_list.awk` | 1 | | |

`entry_base.awk` 是唯一零 shell 调用点的，但它是**别的 awk 的公共函数库**（被 `-f` 一起加载），
删它之前要先确认那些 awk 是否还有 shell 调用者 —— 结论：**在打开 Rust 开关并验证之前，一份都不能删**。
这也说明"先真机 A/B，再删 awk"的顺序不是保守，而是必须。

