# env 规格（已读 `cmd_env`，`webui.sh:809-1000`）

## 缓存

- 缓存文件 `$KL_ENV_CACHE`，每行 `键<TAB>值`；
- 失效键 `ckey = "v1|<MODDIR>|<module.prop 的 version>|stat -c %Y /system/build.prop"`，
  与缓存里的 `v1` 行比对；不同就重新探测并标记 `cache_dirty`。
  （注释里写明：以前用 module.prop 的 **mtime**，但每次同步都会重写描述行，缓存等于白设。）

## 缓存里的探测项（变了才重算）

| 键 | 含义 |
|---|---|
| `resetprop` / `awk` / `base64` / `base64_cmd` | 工具可用性与具体路径 |
| `ino_mode` / `ino_cmd` | inotify 工具（`find_inotify_cmd` 的 `mode:cmd`） |
| `root_user` | `id -u` |
| `webui_sh` | `$MODDIR/webui.sh` |
| `device` / `brand` / `android` / `sdk` / `build_type` | 六个 `getprop` |
| `vbstate` | `ro.boot.verifiedbootstate` |
| `statusbar_dp` | 由 `dumpsys window displays` 的 statusBars 高度 + `wm density`（缺失退回 `ro.sf.lcd_density`）算 dp：`(sbh*160+dens-1)/dens`，两者都 >0 才算 |
| `frro_path` / `frro_mtime` / `frro_b64` | 强调色 FRRO 与它的 base64 |

## 每次都要现取的项

1. `sys_dark` / `sys_dark_src`：`dumpsys uimode` 里 `mComputedNightMode=true|false` 优先；
   否则从 `mCurUiMode=0x..` 取十六进制、`& 32` 判夜间；都取不到 → `sys_dark=`（空）+ `sys_dark_src=none`；
2. `sys_frro` / `sys_frro_src`：`ls -t /data/resource-cache/com.android.systemui-accent-*.frro`，
   没有再试 `-dynamic-*.frro`；路径与 mtime 都没变就复用缓存里的 base64，否则重新 `base64` 整份
   （去掉 `\r\n`）。文件消失时把缓存三元组清空。
3. `sys_seed_raw` / `sys_seed_src`：
   - `settings get secure theme_custom_color` 非空（且不是 `null`）→ `src=theme_custom_color`；
   - 否则若有 FRRO → `sys_seed_raw=`（**空**）+ `src=none`（不当退路用，因为 FRRO 才是权威）；
   - 否则 `dumpsys wallpaper` 里 `colorValue0=` → `src=wallpaper_color0`；再没有 → 空 + `none`。

## 输出顺序（末尾一批 kv）

`resetprop`、`awk`、`base64`、`inotify_mode`、`inotify_cmd`、`root_user`、`webui_sh`、
`device`、`brand`、`android`、`sdk`、`build_type`、`vbstate`、`statusbar_dp`，
再加前面的 `sys_dark`/`sys_dark_src`/`sys_frro`/`sys_frro_src`/`sys_seed_raw`/`sys_seed_src`。
（具体顺序以 960 行之后的 `kv` 序列为准，实现前再核一遍尾部。）

## 对拍要点

需要桩：`getprop`、`resetprop`、`awk`、`base64`、`id`、`inotifywait`/`inotifyd`、`dumpsys`、`wm`、
`settings`、`stat`（真实即可）、`ls -t`（真实）。建议用 `PATH` 前置一个桩目录，
再用 `KEYLENS_ROOT` 夹具控制缓存路径，两侧跑同一套桩。

## 已核实的输出尾部顺序（`webui.sh:954-964`）

```
kv sdk <sdk>
kv build_type <build_type>
kv vbstate <vbstate>
[ -n "$sb_dp_v" ] && kv sys_statusbar_dp <dp>   # 只有算出来才打这一行
```

也就是说完整顺序是：
`sys_dark`、`sys_dark_src`、（有 FRRO 时）`sys_frro`、`sys_frro_src`、`sys_seed_raw`、`sys_seed_src`、
`resetprop`、`awk`、`base64`、`inotify_mode`、`inotify_cmd`、`root_user`、`webui_sh`、
`device`、`brand`、`android`、`sdk`、`build_type`、`vbstate`、（可选）`sys_statusbar_dp`。

## 缓存写入

- 仅当 `cache_dirty=1` 且缓存目录存在且可写时落盘；
- 内容是一个整串（`v1<TAB>ckey` 起，其后每行 `键<TAB>值`；连同首行共 **19 行**：resetprop/awk/base64/base64_cmd/
  ino_mode/ino_cmd/root_user/webui_sh/device/brand/android/sdk/build_type/vbstate/statusbar_dp/
  frro_path/frro_mtime/frro_b64）；
- 写临时文件 → `chmod 600` → `mv` 覆盖；注意 **`statusbar_dp` 为 0 时写空串**（与输出时"不打这一行"不同）。

## 两边共用这一份缓存（`bin/keylens env` 已实现）

命令层默认走二进制，但缓存文件与 `cmd_env` 是同一个。由此定下两条硬规矩：

1. **探测口径必须与 shell 一致**：`command -v`（带 `/` 按路径判，否则扫 `$PATH`，不起进程）
   加上"真跑一次"的验证（`awk 'BEGIN{}'`、解一段 `aGk=`、`--help` 里找 `--monitor`/`inotifyd`）。
   Rust 以前用 `spawn("<工具> --version")` 当可用判据，那种机器上 shell 报 `awk=1`、二进制报 `awk=0`，
   两种答案会先后写进同一份文件。
2. **键名与顺序必须逐个同序**（`rust/src/read_cmds.rs` 的 `rows` 数组 ↔ `webui.sh` 的 `cb` 拼装）：
   名单漂了不会改变输出（两边一起漂），只有 `tests/env-cache.sh` 的两份源码名单比对会响。

覆盖分两层：`rust/parity.sh` 的「env 缓存」一节（冷=热、两个方向互读、热跑不起
`getprop`/`dumpsys window`/`wm`/`id` 且仍起 `dumpsys uimode`/`settings get`、19 个键名逐字点名、
换 `module.prop` 版本必须重探）；FRRO 那一段在夹具机上**结构性测不到**（`/data/resource-cache` 是空的），
由 `tests/device-env-cache.sh` 补：真机冷跑写满、热跑逐行一致，再把缓存里的 `frro_mtime`、`frro_path`
各改坏一次，必须重编并把真值写回。

