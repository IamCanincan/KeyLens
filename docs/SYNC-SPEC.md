# sync 规格（已读 `run_sync` 与 `sync_target_list`）

> 剩余两条命令之一。`sync` 本身只有 10 行，重活在三个后端 worker 与 `build_app_list`。

## `run_sync(prop_file, tmp)`（`backend.sh:645`）

按后端分派，三家各自实现：

| 后端 | worker | 说明 |
|---|---|---|
| teesim | `sync_teesim_config(target, tmp)`（`backend.sh:506`） | 重写 `config.json` 的 `profiles.default.apps` |
| omk | `sync_omk_injector(target, tmp)`（`backend.sh:555`） | 重写 `injector.toml` 的 `scoop` |
| tricky | `sync_target_list(target, tmp)`（`backends/tricky.sh:13`） | 整份重写 `target.txt` |

结果码 → 描述：`2`（失败/结果为空）→ `mark_module_failed`（描述写成 `⚠️ [后端 | 写入失败 | 更新: HH:MM]`）；
其它 → `update_module_desc <prop> $KL_COUNT`（`✅ [后端 | 应用: N | 更新: HH:MM]`）。

## `sync_target_list` 的语义（最完整的一份，另两家同构）

1. `build_app_list <tmp>` 生成新列表并设置 `KL_COUNT`；**失败**（已装列表为空但基线非空）→
   `log_warn "⚠️ 已装列表为空但基线非空：跳过本次写入，避免误清名单（手动同步可强制）"`，删临时文件，回 **2**；
2. 临时文件为空 → 回 **2**；
3. 与目标文件**内容相同**（`cmp -s`）→ 把 `ST_INSTALLED_NEW`→`ST_INSTALLED`、`ST_EVER_NEW`→`ST_EVER`
   各自 `mv` 并 `chmod 600`，再 `drop_legacy_state`，回 **1**（未写入）；
4. 不同 → `mv` 覆盖目标、`chmod 644`，同样搬状态文件 + `chmod 600` + `drop_legacy_state`，回 **0**；
5. `mv` 失败 → 删临时文件，回 **2**。

要点：**状态文件（installed_last / ever）只在成功路径搬到正式位置**；`drop_legacy_state` 会清掉
`.kl_written_last` / `.kl_written.new` / `.kl_removed` / `.kl_removed.new` 这些墓碑遗留。

## `cmd_sync`（`write.sh:1016`）

`require_runnable` → `detect_backend` → `webui_lock` → 设 `KL_EMPTY_OK=1`（**只有用户显式点同步才把"读到空已装列表"当真清空**；
后台守护不设）→ `run_sync "$PROP_FILE" "${KL_DIR}/.kl_tmp"` → 解锁 → 输出 `rc`、`count`。

## 还差什么

`build_app_list`（`lib/common.sh`，快照差分：新装/卸载对比 `ST_INSTALLED` 基线、`ST_EVER` 只增、`KL_COUNT`）
与 teesim/omk 两个 worker 的写回（可复用已实现的 `teesim_apps_rewrite` / `omk_scoop_rewrite`）。
