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

## 三份 info awk 的输出键（已逐行核对，照此顺序打印）

**tricky_info.awk（43 行）**
```
patch_lines=<N>
patch_packages=<N>
patch_system=<值>    # 仅当非空
patch_vendor=<值>    # 仅当非空
patch_boot=<值>      # 仅当非空
patch_all=<值>       # 仅当非空
```
`patch_lines` = security_patch.txt 行数，`patch_packages` = `[包名]` 段数；
system/vendor/boot/all 取**全局段**的值（`all=` 同时写三档）。

**teesim_info.awk（157 行）**
```
config_version=<number>          # config.json 的 "version"
profiles=<N>                     # profiles 下 profile 个数
default_mode=<str>
default_keybox=<str>
default_os_version=<str>
default_auto_include=<bool 裸值>
default_brand / default_device / default_product / default_manufacturer
default_model / default_serial / default_imei / default_meid / default_imei2
default_patch_system / default_patch_vendor / default_patch_boot   # patchLevel 内三档
```
注意 `patchLevel` 是嵌套对象，`osVersion`/`autoIncludeNewApps` 是驼峰键名。

**omk_info.awk（136 行）**——先 injector 再 config，最后两个统计：
```
injector_version / injector_main_enabled / injector_log_level
filter_enabled / filter_block_android / filter_allow_unknown
intercept_<方法名>=<true|false>            # 每个 [intercept] 键一条，按文件顺序
config_version / omk_backend / config_log_level
cfg_force_skip_biometric / cfg_retire_stale_keys
dev_brand / dev_device / dev_product / dev_manufacturer / dev_model / dev_serial
dev_imei / dev_imei2 / dev_meid / dev_override_telephony
trust_os_version / trust_security_patch / trust_os_patchlevel
trust_vendor_patchlevel / trust_boot_patchlevel / trust_vb_key / trust_vb_hash
trust_verified_boot / trust_device_locked
intercept_true=<N>        # [intercept] 里值为 true 的个数
filter_deny=<N>           # deny_packages 的条目数
filter_deny_list=<csv>    # deny_packages 原样（逗号分隔）
```
键名映射与 `docs/OMK-SET-SPEC.md` 的 `cfg_key`/`inj_key` 同源，可直接复用 `read_cmds.rs` 里那两张表。
