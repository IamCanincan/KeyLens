# teesim_set.awk 规格（`teesim-save` 的实现依据）

> 已读全 196 行；照着这份写 Rust 版，不需要再读 awk。

## 定位要写的 profile 对象

1. 找 `"profiles"`；找不到 → 状态 `missing`（调用方报「配置定位失败」）。
2. `pname` = 请求里的 `profile`（省略时 `default`），`pkey` = `"<pname>"`。
3. 从 `profiles` 之后**逐个**找 `pkey`，只有当它后面（跳过空白）是 `:`、再跳过空白是 `{` 时才算
   profile 对象——**必须是键而不是某个字符串值**（profile 叫 `alt`/`default` 时，`apps`、keybox 名等
   地方都可能出现同名串；认错位置就写坏用户配置）。找不到 → `missing`。
4. 用配对括号取到对象文本 `dobj`。

## `patchLevel`（嵌套对象）

- 只要请求里有任一 `patch_system` / `patch_vendor` / `patch_boot`：
  - 若 `dobj` 里已有 `"patchLevel"` `:` `{`：取该子对象 `pobj`，对 `system`/`vendor`/`boot`
    逐个 **有则原位替换**（`replace_scalar`）、**无则插入**（`insert_member`），再拼回 `dobj`；
  - 若没有 `patchLevel`：造一个字面量 `{"system": "…", "vendor": "…", "boot": "…"}`（存在的项才写、
    分隔符 `", "`），整体作为 `patchLevel` 插入 `dobj`。

## 顶层字段

对每个非 `patch_*` 字段：`os_version` → `osVersion`；`auto_include` → `autoIncludeNewApps`
（值渲染成裸 `true`/`false`）；其余键名不变、值渲染成**带引号的转义字符串**。
同样「有则原位替换、无则插入」。

## 两个原语的语义

- `replace_scalar(obj, key, literal)`：用 `"key"[ \t\r\n]*:` 定位 → 跳过值前空白 → `value_end` 求值区间 →
  整段换成 `literal`；返回是否命中，`CHANGED` 表示新旧是否不同。
- `insert_member(obj, key, literal)`：从末尾 `}` 回退取「收尾缩进」`closeind`（`}` 前不是换行就退化成两空格）；
  成员缩进 = `closeind + "  "`；去掉 `}` 前的尾部空白，末尾不是 `{`/`,` 就补逗号；
  插入 `"\n" + ind + "key": literal + "\n" + closeind + "}"`。

## 状态与落盘

- 有改动 → `ok`；无改动 → `same`；定位失败 → `missing`。
- 调用方：`ok` 且内容与原文相同 → 不写；不同 → `config.json.bak` 备份后原子替换；
  `same` → 不写；`missing` → 「配置定位失败：<路径>」。
- 输出：`saved`（0/1）、`fields`（字段数）、`profile`（本次写的 profile 名）。

## 字段校验（已实现，`read_cmds.rs`）

`valid_patch`（三态，`harvested` 单独拒绝）、`valid_os_version`、`valid_bool`、
`valid_keybox_name`（必须以 `.xml` 结尾、不许带路径）、`valid_text`（≤256、无控制字符）。
`mode` 只认 `patch` / `generation`；`keybox` 还要求 `TEESIM_DIR/<名字>` 真实存在。
