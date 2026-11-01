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

`build_app_list`（`applist.sh:140`，快照差分：新装/卸载对比 `ST_INSTALLED` 基线、`ST_EVER` 只增、`KL_COUNT`）
与 teesim/omk 两个 worker 的写回（可复用已实现的 `teesim_apps_rewrite` / `omk_scoop_rewrite`）。

## `build_app_list(tmp)` 算法（`applist.sh:140-243`）

输入：`cmd package list packages -3` 的已装列表、`current_target_apps` 的当前条目、`ST_INSTALLED` 基线。

1. `user_list` = 已装包名（去前缀、去空、排序去重）；`cur` = 当前条目（去空、排序去重）；
2. **读空保护**：`user_list` 为空且基线非空且 `KL_EMPTY_OK != 1` → 删临时文件、返回 **1**（视为读取失败）；
3. **首次安装种子**：基线不存在且 `cur` 为空 → `seed = $SEED_PKGS`（按行展开，不能当空格串传）；
4. **OMK 首次接入**：`KL_BACKEND=omk` 且基线不存在且 `cur` 非空 → `adopt=1`（沿用现有 scoop，不灌已装）；
5. 四份集合落临时文件：`inst`（已装）、`cur`（当前 token + 基础名映射）、`seed`、`was`（基线）；
6. 一次 awk 做集合运算：
   - `gone` = 基线里已不在已装的包（这一轮之前卸载的）；
   - 遍历 `cur`：基础名在 `gone` 里 → 连 `?`/`!`/`@用户` 变体一起丢弃（`uid:` 无法反查，保留）；否则 `keep`；
   - `adopt != 1` 时：已装里"新出现的"（不在 `was`、基础名也不在 `keepbase`）加入 `keep`；
   - `seed` 里不在 `keepbase` 的也加入；
   - 输出 `keep` → `sort -u` → 写 `$tmp`；
7. `KL_COUNT` = `$tmp` 行数；
8. **只在写成功后**由 `sync_*` 提交：`ST_INSTALLED_NEW`（= `user_list`，600）与
   `ST_EVER_NEW`（= 旧 `ST_EVER` ∪ `entries_to_bases($tmp)`，按基础包名，去重，600）。

要点：状态文件权限显式 600（管理器 exec 的 umask 可能是 000，实测生成过 666）；
`ST_EVER` 用**基础包名**（`pkg?` / `pkg@10` 都归到 `pkg`），否则换模式会被当成另一个应用。

