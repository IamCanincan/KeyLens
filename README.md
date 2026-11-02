# KeyLens

[![Build CI Module](https://github.com/IamCanincan/KeyLens/actions/workflows/build_ci.yml/badge.svg)](https://github.com/IamCanincan/KeyLens/actions/workflows/build_ci.yml)
[![Latest Release](https://img.shields.io/github/v/release/IamCanincan/KeyLens?label=release&color=blue)](https://github.com/IamCanincan/KeyLens/releases/latest)
[![License](https://img.shields.io/github/license/IamCanincan/KeyLens?color=green)](LICENSE)

> 密钥认证后端控制台：**Tricky Store / TEE Simulator / OhMyKeymint** 三家统一读写——名单、补丁级别、keybox、伪装属性，一个界面管完。

KeyLens 不替代任何后端，而是站在三家密钥认证后端之上做统一控制台：

- **名单**：按各后端的真实语法读写（Tricky 的 `pkg?` / `pkg!`、TEESim 的 `@用户` / `uid:`、OMK 的 `scoop`），单条增删、按视图筛选与搜索；
- **后端配置**：补丁级别、keybox、profile / overrides / injector / config 都能编辑，**保存前先看 diff**；
- **自动同步**：开机与名单文件变化时，把已装应用同步进当前后端的目标名单（守护进程跑着就在维护，失败会记日志）；
- **属性伪装**：17 项开机写入的状态属性（locked / green / warranty_bit …）；
- **体检与回滚**：`doctor` 11 项只读体检；覆盖前自动留 `.bak`，界面一键回滚。

## 安装

**前置**：已安装以下**任意一家**后端（三个路径任一存在即可）：

| 后端 | 目标文件 |
|---|---|
| Tricky Store / Tricky Store OSS | `/data/adb/tricky_store/target.txt` |
| TEE Simulator | `/data/adb/teesim/config.json` |
| OhMyKeymint | `/data/misc/keystore/omk/injector.toml`（先打开一次 OMK 生成配置） |

1. 到 [Releases](https://github.com/IamCanincan/KeyLens/releases) 下载 `KeyLens-<版本>.zip`；
2. 在 KernelSU / Magisk / APatch 管理器里刷入，重启生效；
3. 之后的版本更新走管理器内更新（`update.json` 指向本仓库），不用手动下载。

> **从旧版 TS-AUTO-ADD 升级**：直接刷 zip 即可。安装脚本会先把旧状态（`ts_auto.*` 与后端目录里的 `.ts_*`）迁到新名字，再移除旧模块目录——不需要手动卸载。

## 界面

四个目的地：**主页 / 功能 / 日志 / 设置**。「功能」是一张菜单，五项各进二级页：

| 入口 | 做什么 |
|---|---|
| 目标名单 | 名单 / 已安装 / 未纳入 三视图，带图标与显示名 |
| 后端配置 | 按当前后端渲染可编辑字段（含 keybox），保存前看 diff |
| 自动同步 | 守护进程状态、上次写入时间、立即同步一次 |
| keybox | 粘贴替换、当前指纹、备份 |
| 属性伪装 | 17 项属性、开机写入、Verified Boot 哈希 |

## 使用要点

- 名单就是后端的**目标文件**本身，改完即生效；Tricky / TEESim 由各自 watcher 重载，OMK 部分字段热生效、部分需重启 keymint（界面会提示）；
- 保存后端配置前会显示行级 diff（`+` 新增 / `−` 删除），确认才落盘；
- 三家后端**不要同时启用**：同时开启多于一家时模块会停止运行，并在模块描述里提示；
- 出问题先看「设置 → 体检」：11 项逐层报 ok / warn / bad。

## 路径

| 内容 | 路径 |
|---|---|
| 运行日志 | `/data/adb/keylens.log` |
| 运行期状态 | 后端目录里的 `.kl_*`（基线、ever 名单、指纹、锁） |
| 模块目录 | `/data/adb/modules/keylens` |

## 常见问题

- **更新没提示？** 旧名 `ts-auto-add` 的安装照样能收到提示（它配置里的更新地址改名后仍解析到当前 `update.json`）；点更新即可完成迁移与接管。若你的管理器不认跨 id 更新，手动刷一次 zip 效果相同。
- **界面打不开 / 一直转圈？** 确认后端模块在、`inotifywait` 或 `inotifyd` 至少有其一，再用「设置 → 体检」看哪一层红。
- **改完不生效？** 看「日志」页与「主页」的上次写入时间；属性伪装看是否开了开机写入。

## 许可证

MIT，欢迎贡献代码与反馈问题。

---

**版本** v3.0.3 · **更新日期** 2026-11-03 · **维护者** IamCanincan
