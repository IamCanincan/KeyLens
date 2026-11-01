# backend-info 规格（已读全 `cmd_backend_info`，实现依据）

> `webui.sh:587-722`，约 135 行。它本身不长，重活在三份 info awk（`tricky_info` 43 / `teesim_info` 157 / `omk_info` 136）。

## 输出顺序（逐字节重要）

1. **tricky 专属**：`patch_file`（security_patch.txt 路径）、`patch_exists`（0/1）；存在时再追加 `tricky_info.awk` 的输出；
2. **omk 专属**（在公共字段之前）：
   - `omk_keymint_daemon` / `omk_keymint_alive`
   - `omk_injector_daemon` / `omk_injector_alive`
   - `omk_keystore_pid` / `omk_keystore_injected`
3. **公共**：`backend`、`backend_name`、`module_dir`、`module_version`、`target_file`、`target_entries`、
   `keybox_file`、`keybox_exists`、`keybox_bytes`、`keybox_mtime`、`keybox_hash_algo`（sha256 / md5）、`keybox_hash`
4. **teesim 专属**：`keybox_files`（目录下所有 `*.xml` 的逗号列表）
5. 最后把 `info`（三份 awk 的原始输出）原样打印。

## 判定细节

- `module_dir` 是**当前后端自己的模块目录**（`$TEESIM_MODULE` / `$OMK_MODULE` / `$TRICKY_MODULE`），
  `module_version` 从它的 `module.prop` 取 `version=`——**不能用本模块的 `mod_prop`**。
- `keybox` 路径：teesim 以 `config.json` 的 `default_keybox` 为准（相对名拼到 TEESIM_DIR，绝对路径原样）；
  omk 是 `$OMK_DIR/keybox.xml`；tricky 是 `$TSTORE_DIR/keybox.xml`。
- keybox 存在才算 bytes/mtime/hash；hash 优先 `sha256sum`，没有就 `md5sum`，并如实报 `keybox_hash_algo`。
- **omk 守护进程核对**：pid 文件里的 pid 必须活着 **且** `/proc/<pid>/cmdline` 的**第 2 行**（NUL 拆分后第 2 项）
  等于 `$OMK_MODULE/daemon` / `$OMK_MODULE/daemon-injector`——只 `kill -0` 会把被复用的陌生 pid 当守护。
- **注入判定**：`pidof keystore2` 取第一个 pid，与 `injector.payload` 第一列相等且第二列非空 → `omk_keystore_injected=1`。
- `target_entries`：`current_target_apps` 的非空行数（本模块已有三家实现，可直接复用）。

## 实现建议

- 三份 info awk 的输出键可以在 Rust 里直接算（它们都只是在读 `config.json` / `injector.toml` / `security_patch.txt`），
  不必逐行翻译 awk：KeyLens 已经有 `teesim_profiles`/`teesim_overrides`/`omk_scoop`/`tricky_patches` 的解析器可复用；
- 但**键名与顺序必须与 awk 的输出一致**，所以移植前先把三份 awk 的 `printf` 清单列出来对着写；
- 对拍需要桩：`sha256sum`（真实存在即可）、`pidof`、`/proc/<pid>/cmdline`（用真实子进程最简单）。
