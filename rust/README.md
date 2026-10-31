# rust/ — 命令层 Rust 版（分阶段迁移中）

## 本地怎么跑

Windows 上 cargo 默认走 MSVC，缺链接器时**编不出可执行文件**；用 WSL 的原生工具链：

```sh
cd "/mnt/d/Github Repositories/TS-AUTO-ADD"
~/.cargo/bin/cargo test  --manifest-path rust/Cargo.toml --release   # 单测
~/.cargo/bin/cargo build --manifest-path rust/Cargo.toml --release   # 产物
sh rust/parity.sh                                                    # 与 shell 版逐字节对拍
```

CI（`.github/workflows/rust-build.yml`）用交叉编译出 aarch64 静态二进制，并在 ubuntu 上跑同一份 `parity.sh`。

## 写源码的禁忌（踩过两次）

**不要用 PowerShell 的 `Set-Content` / `-replace | Set-Content` 改 Rust 源文件**：
它会带 BOM、也会在中文串上编码错乱，编译报 `unexpected closing delimiter` 或
`unterminated double quote string`，而 diff 看起来只有一两行。用编辑工具或 Node
的 `fs.writeFileSync`（UTF-8 无 BOM）。同理，`git checkout -- <file>` 是最快的回滚。

## 结构

| 文件 | 职责 |
|---|---|
| `main.rs` | 分发（40 条命令与 `KL_COMMANDS` 逐字同序）+ `contract`/`help` |
| `backend.rs` | 后端探测（teesim → tricky → omk → 回退）+ 路径表（`KEYLENS_ROOT` 测试缝） |
| `read_cmds.rs` | 读命令与写命令实现 |
| `json_flat.rs` | 扁平 JSON 定值写入（原位替换/整条删除/插入） |
| `payload.rs` / `b64.rs` | 界面 payload（外层 + 逐字段 base64） |
| `keybox.rs` | 按后端分叉的 keybox 结构校验 |
| `ov_valid.rs` | overrides.json 字段校验 |
| `lock.rs` | 并发锁（目录原子创建 + 持有者证据） |
| `parity.sh` | 对拍台架：抽 `webui.sh` 的**真函数**跑，夹具走 `KEYLENS_ROOT` |

## 迁移状态

已迁 29/40（明细与剩余项见 `docs/RUST-REWRITE.md`）。未迁的命令返回 2，
不假装成功；`webui.sh` 目前仍是唯一入口，Rust 二进制**尚未接入**模块。
