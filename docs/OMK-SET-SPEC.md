# omk_set.awk 规格地图（`omk-save-injector` / `omk-save-config` 的实现依据）

> 196 行，20 个函数。这里只做**地图**：下一窗口按函数逐个读、逐个移植，不必从头摸。

## 函数清单（行号）

| 函数 | 行 | 作用 |
|---|---|---|
| `split_comment` | 14 | 按 `#` 切出值与注释，跳过字符串内的 `#`（TOML 的 `#` 在引号里不算注释） |
| `tomlesc` | 31 | TOML 字符串转义（`\ " \t \r \n`） |
| `fmt` | 45 | 按值类型格式化：字符串加引号并转义、布尔/数字裸写、数组按类型分隔 |
| `flat_line` | 63 | 生成 `key = value` 一行 |
| `inj_key` | 68 | payload 键 → injector.toml 的键/section 映射 |
| `cfg_key` | 80 | payload 键 → config.toml 的键/section 映射 |
| `key_type` | 98 | 键的取值类型（bool / int / string / array / log level） |
| `flush_missing` | 207 | 把「文件里还没有」的键补进对应 section |
| `wval_for` | 217 | 取某个键应写的字面量 |

## 命令骨架（两个命令共用）

1. `cmd_omk_save_injector`（`write.sh:277`）/ `cmd_omk_save_config`（`:347`）：
   校验后端是 omk → 目标文件存在 → `parse_payload` → 逐字段白名单校验；
2. **injector 的字段集**：`inj_main_enabled`、`filter_enabled`、`filter_block_android`、`filter_allow_unknown`
   （布尔）；10 个 `intercept_*`（布尔）；`inj_log_level`（`off/error/warn/warning/info/debug/trace`）；
   `filter_deny`（逗号分隔包名，归一化后写 `DENY_NORM`）；
3. 写入：`omk_set.awk -v pairsfile=… -v target=injector|config -v statusfile=…` → `ok`/`same`/其它；
4. `ok` 且内容不同 → `commit_backend_file … "injector.toml.bak"` / `"config.toml.bak"`；`same` → 不写；
   其它 → 「配置定位失败：<路径>」；
5. 成功后 **`omk_restart injector`**（预览模式 `KL_PREVIEW=1` 时跳过）并记日志；
6. 输出：`saved`（0/1）、`fields`（字段数）。

## config.toml 的额外约束

`[crypto]` 段里的五个种子（密钥材料）**不可清空**——写空会让 OMK 丢密钥；
`cmd_omk_save_config` 在校验阶段就拒绝这类清空请求。字段含 `cfg_log_level`、`cfg_force_skip_biometric`、
`cfg_retire_stale_keys`、`trust_security_patch` / `trust_os_patchlevel` / `trust_vendor_patchlevel` /
`trust_boot_patchlevel`、设备身份（`dev_product` / `dev_device` / `dev_manufacturer` / `dev_model` / `dev_serial` / …）。

## 已完成的部分

- `valid_inj_log_level`、`valid_deny_list`（含归一化）、`valid_bool`、`valid_text`、`valid_patch`、
  `valid_os_version`、`valid_keybox_name` 均已在 `read_cmds.rs` 实现并有单测；
- `payload::parse`（外层/逐字段 base64、错误文案）已实现；
- 还差：`omk_set.awk` 的 TOML 读改定值（`split_comment`/`fmt`/`key_type`/`flush_missing`/`wval_for` 那一套）。
