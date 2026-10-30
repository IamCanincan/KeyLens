# KeyLens (v2.2.19.5-yuzu)

[![Build CI Module](https://github.com/IamCanincan/TS-AUTO-ADD/actions/workflows/build_ci.yml/badge.svg)](https://github.com/IamCanincan/TS-AUTO-ADD/actions/workflows/build_ci.yml)
[![Latest Release](https://img.shields.io/github/v/release/IamCanincan/TS-AUTO-ADD?label=release&color=blue)](https://github.com/IamCanincan/TS-AUTO-ADD/releases/latest)
[![License](https://img.shields.io/github/license/IamCanincan/TS-AUTO-ADD?color=green)](LICENSE)

KeyLens 是一个面向 **[Tricky Store](https://github.com/5ec1cff/TrickyStore)** / **[Tricky Store OSS](https://github.com/beakthoven/TrickyStoreOSS)** / **TEE Simulator** / **[OhMyKeymint](https://github.com/qwq233/OhMyKeymint)** 的 Magisk 辅助模块：主体是这四家的**统一控制面板**（名单、补丁级别、keybox、系统属性伪装都在界面里读写），附加功能是通过后台守护进程自动维护应用包名列表。

> 安全补丁级别**可以**在界面里改（Tricky 写 `security_patch.txt`、TEESim 写 profile 的 `patchLevel`、OMK 写 `config.toml` 的 `[trust]`）—— 早期版本"不再修改安全补丁"的说法已经过期。三家后端同时启用时模块自动停止。

### 🔌 三后端自动探测

| 后端 | 判定依据（`/data/adb/modules` 下的模块 id） | 维护目标 |
|------|----------------------------------------------|----------|
| **TEE Simulator** | `teesim` | `/data/adb/teesim/config.json` 的 `profiles.default.apps` |
| **Tricky Store / OSS** | `tricky_store` | `/data/adb/tricky_store/target.txt` |
| **OhMyKeymint** | `oh_my_keymint` | `/data/misc/keystore/omk/injector.toml` 的 `scoop` 数组（`config.toml` 不碰） |

TEE Simulator 模式下**只替换 `default` profile 的 `apps`**，其余字段（`keybox` / `mode` / `patchLevel` / 设备信息等）与其它 profile 一律原样保留；无法可靠定位数组时放弃写入。OhMyKeymint 同样**只替换 `scoop` 数组**，注释、`version`、`[main]` / `[filter]` / `[intercept]` 与每个包的 `[scoop.<包名>]` 段逐字节保留。两者的目标文件在被写入前会先备份（OhMyKeymint 的备份在 `/data/adb/omk/injector.toml.bak`，与 OMK 自己的状态文件放在一起）。

> OhMyKeymint 第一次接入时，如果 `scoop` 里**已有内容**，模块会沿用这份名单（只把当前已装记成基线，不批量灌入），之后新装自动加入、卸载自动移除；只有 `scoop` 为空时才按其它后端一样加入全部已装 + 谷歌三件套。

> ⛔ 三个后端中**多于一个启用**时，模块直接停止运行（不做优先级选择），并把停止状态写入模块描述。

---

## ✨ 核心功能

- **增量维护目标名单**  
  名单**只有目标文件本身**（`config.json` 的 `profiles.default.apps` / `target.txt` / `injector.toml` 的 `scoop`）：装上的应用自动进、卸载的自动出；你手工加进去的条目不会被抹掉，你手工删掉的也不会被自动加回来（除非那个应用卸载过又重新安装）。其它后端首次同步会把谷歌三件套种进去一次 —— 它们是系统应用，`pm list packages -3` 看不到；OhMyKeymint 首次接入沿用现有 `scoop`（见上）。

- **事件驱动实时监听**  
  自动探测 `inotifywait` 或 `inotifyd`，只监听 `/data/system/packages.list`（安装/卸载的唯一信号）。内置 2 秒防抖与内容指纹比对，避免系统频繁改写该文件造成无谓同步。

- **系统属性伪装**  
  开机早期（Zygote 启动前，`post-fs-data.sh`）执行属性重置，模拟设备处于锁定、绿标状态（如 `ro.build.type`、`ro.boot.verifiedbootstate`、`ro.debuggable` 等），确保 `Build.TYPE` 等静态字段在应用启动前即为干净值；开机完成后再幂等复核一次。WebUI 的「属性」页还可以填写 **verifiedBootHash**（64/128 位十六进制），开机时写进 `ro.boot.vbmeta.digest`。

- **统一进程管理**  
  所有后台子进程 PID 记录于 `.kl_daemon_pids.list`，卸载时可一次性全部终止，无残留。

- **运行日志（logcat + 本地缓冲）**  
  日志同时写入系统日志（`logcat`，tag 为 `KeyLens`）与本地缓冲文件 `/data/adb/keylens.log`。`logcat` 是内存环形缓冲（默认仅几百 KB 且全系统共用），系统繁忙时旧记录很快被挤掉、重启即清空；缓冲文件容量固定（超过 64KB 自动只保留末尾 200 行）、跨重启保留，权限 `600` 且位于 `0700` 的 `/data/adb`，仅 root 可读。

- **WebUI 控制台（Material 3 Expressive）**  
  模块自带 `webroot/index.html`，在支持 WebUI 的管理器里点模块的「打开界面」即可：主页看运行状态与**当前后端版本**、后端格里对照目标名单与已装应用并配置当前后端、日志页排障、设置页里一键开关开机属性伪装与 Verified Boot 哈希。「后端」格按当前后端分别适配并可**手动配置**：TEE Simulator 的 default profile（模式、keybox 文件名、补丁级别、OS 版本、自动纳入、设备身份）、Tricky Store OSS 的全局补丁表（`system / vendor / boot / all`）、OhMyKeymint 的 injector（过滤、拒绝包、10 个拦截方法）与 config.toml（日志、trust、设备身份）；OMK 配置页顶部还有**运行状态**（keymint / injector 两个 daemon 的 pid 与存活、keystore2 是否已注入，来自 1.2.5 的 daemon 架构），异常时直接给排障指引。三家都支持粘贴替换 keybox.xml。保存只提交改动过的字段，写前备份，Tricky/TEE Simulator 由各自的 watcher 重载，OMK 通过自己的 `restart.injector / restart.keymint` 生效。名单里 Tricky 的条目带 `自动 / 叶证书 / 证书生成` 选择，TEE Simulator 的 `pkg@用户` 与 `uid:数字` 会显示成对应标签。界面是单文件、不联网；MD3E Web 1.0.14 的组件与符号字体子集已内联进产物（不需要联网加载任何库或字体）。

- **兼容性广泛**  
  支持 Magisk、KernelSU、APatch，并自动适配 `inotifywait` / `inotifyd` 两种监控模式（含各框架自带的 busybox）。

---

## 🧩 模块结构

```
module/
├─ module.prop            # 模块元数据
├─ customize.sh           # 安装入口（框架按固定路径调用）
├─ post-fs-data.sh        # 开机早期入口：Zygote 前属性伪装
├─ service.sh             # 后台守护入口
├─ action.sh              # 手动同步入口（管理器“操作”按钮）
├─ webui.sh               # WebUI 命令层（界面经 root shell 调用，输出机器可读文本）
├─ uninstall.sh           # 卸载入口
├─ lib/
│  ├─ common.sh           # 函数库加载入口
│  ├─ core.sh             # 路径常量、运行期状态、日志（logcat + 本地缓冲）
│  ├─ lock.sh             # 并发锁
│  ├─ tools.sh            # 外部工具定位（awk / base64 / inotify）
│  ├─ applist.sh          # 目标名单生成（增量 + 手动删除尊重）
│  ├─ backend.sh          # 后端探测、后端写入、模块描述、同步入口
│  ├─ props.sh            # 系统属性伪装（期望值表 + 伪装开关）
│  ├─ icondump.dex        # 取图标用的小 dex（源在 tools/icondump/，可重放）
│  └─ watch.sh            # 监听重启退避（纯函数，被 tests/ 直接 source）
├─ backends/
│  ├─ tricky.sh           # Tricky Store 后端实现：写 target.txt
│  ├─ teesim.awk          # TEE Simulator 后端实现：定点替换 default.apps
│  ├─ teesim_list.awk     # TEE Simulator 只读提取：取出 default.apps 供界面展示
│  ├─ omk.awk             # OhMyKeymint 后端实现：定点替换 scoop 数组
│  └─ omk_list.awk        # OhMyKeymint 只读提取：取出 scoop 供界面展示
├─ webroot/
│  └─ index.html          # WebUI 界面（单文件；内联样式、脚本与 Material Web bundle）
│                         # 运行时会多出 webroot/icons/*.png —— 由 webui.sh icons 从桌面
│                         # 图标缓存导出，不进仓库、不进刷机包
└─ META-INF/              # 刷机包脚本

tools/                     # 不进刷机包：构建与自检
tests/                     # 静态自检（CI 跑）
tools/icondump/            # 图标 dex 的源码与编译命令
tools/mwc-build/          # 生成旧版 index.html 里的 Material Web bundle —— 已不再使用，留作历史
tools/md3e-build/         # MD3E Web 组件包 → 内联 bundle（npm + esbuild），含图标闸门与验收台架
webui/src/                # 界面源码（index.html / app.css / bridge.js / screens.js / app.js）
webui/dist/index.html     # 候选产物（build.mjs 每次都写，verify.mjs 默认读它）

> **2026-10-30 换版已完成**：`module/webroot/index.html` 现在就是 `webui/src` 的产物
> （894 KB，MD3E Web 2.5 + 内联符号字体子集）。同一次提交里退役了三个只对旧产物有效的
> 护栏 —— 旧 `tests/ui-shape.js`（79 条 grep `var KV_REQUIRED` / `.grp{}` / `id="p-func"`
> 的断言）、`tests/ui-font.js`、旧台架 `tools/ui-cdp-check.mjs` —— 并把新套子
> `ui-next-shape.js` **改名成 `tests/ui-shape.js`**：换版之后"next"是个谎。
> 现在守界面的是：`tests/ui-shape.js`（表单字段 ↔ 命令层 case 对账 + 结构底线）、
> `tools/kv-shape-check.mjs`（界面读的键 ⊆ 命令层输出的键，含假数据那一侧）、
> `tools/md3e-build/icon-gate.mjs`（图标名必须在 257 连字子集内）、
> `tools/md3e-build/check-artifact.mjs`（占位符 / 内联字体 / 离线 / 源码可达 / 字节下限）、
> `tools/md3e-build/verify.mjs`（CDP 真点导航 + 逐后端驱动 + 读失败与互斥两屏）。
> 构建：`node tools/md3e-build/build.mjs --ship`（不带 `--ship` 只出候选，不碰上机产物）；
> 新鲜度：`node tools/md3e-build/build.mjs --check` 同时比 `webui/dist` 与 `module/webroot`
> 两条 —— CI 不装 npm 依赖、重建不了，这条只能本地跑。
tools/md3e-build/verify.mjs  # 界面验收台架：CDP 钉死 417 视口，逐页 + 逐后端驱动，截图到系统临时目录
tools/deploy-webui.sh        # 推 WebUI / 命令层上机：入口闸门 + chmod 644 + 逐文件对 sha256
THIRD_PARTY_NOTICES.md       # 内联 bundle 的第三方许可
```

- **入口脚本必须留在根目录**：Magisk / KernelSU / APatch 按固定路径调用 `customize.sh` / `post-fs-data.sh` / `service.sh` / `uninstall.sh`，管理器“操作”按钮调用 `action.sh`。
- `lib/` 放共享库，`backends/` 放后端实现（每个后端一个文件）；入口脚本与 `lib/common.sh` 中都不含后端专属逻辑。
- `webroot/` 是各管理器约定的 WebUI 目录（入口必须是 `index.html`）；界面不直接读文件，一律经 `webui.sh` 取数，这样状态判定与命令行排查看到的是同一份逻辑。

---

## 📥 安装与部署

### 下载
- **发行版（推荐）**：到 [Releases](https://github.com/IamCanincan/TS-AUTO-ADD/releases) 下载 `TS-AUTO-ADD-<版本>.zip`（文件名与 `update.json` 中的 `zipUrl` 一致，管理器内更新也走这一份）。
- **CI 构建**：每次推送到 `main` 会自动构建，版本号附带时间戳后缀（`-ci`）。到 [Actions](https://github.com/IamCanincan/TS-AUTO-ADD/actions/workflows/build_ci.yml) 打开最近一次运行，在页面底部 Artifacts 下载 —— 仅供测试，不要当作正式版本。

### 从旧版 TS-AUTO-ADD 升级（模块改名 KeyLens，id 也变了）

模块 id 从旧名 `ts-auto-add` 改成 `keylens`，管理器是按 **id（也就是模块目录名）** 认模块的，所以：

- **先卸载旧模块，再刷 KeyLens 的 zip**。两个目录并存 = 两套 `service.sh`/`post-fs-data.sh` 同时跑：两份守护进程各自监听、各自写同一份后端配置，行为不可预期。
- 卸载旧模块**不会**丢设置：属性伪装开关、启动哈希、基线名单这些不在模块目录里，改名后由 `migrate_legacy_paths` 一次性搬到新名字（`/data/adb/ts_auto.*` → `/data/adb/keylens.*`，后端目录里 `.ts_*` → `.kl_*`），迁移只在新名字不存在时动，反复调用是 no-op。
- `update.json` 的更新通道按 id 走，**旧 id 的装机收不到 KeyLens 的自动更新** —— 这一版要靠手动刷入。GitHub 仓库名仍是 `TS-AUTO-ADD`（改名要在仓库设置里做，`zipUrl`/徽章 URL 等它改完再一起动）。

### 前置条件

- 已安装以下**任一**后端模块：
  - **[Tricky Store](https://github.com/5ec1cff/TrickyStore)** 或 **[Tricky Store OSS](https://github.com/beakthoven/TrickyStoreOSS)**（模块 id `tricky_store`），`/data/adb/tricky_store/target.txt` 存在（可为空）；
  - **TEE Simulator**（模块 id `teesim`），`/data/adb/teesim/config.json` 存在；
  - **[OhMyKeymint](https://github.com/qwq233/OhMyKeymint)**（模块 id `oh_my_keymint`），`/data/misc/keystore/omk/injector.toml` 存在（先打开一次 OMK 让它生成配置）。
- 系统具备 `inotifywait` 或 `inotifyd` 其中之一（绝大多数 Android 系统已内置；Magisk / KernelSU / APatch 自带的 busybox 亦可）。
- **三个后端不要同时启用**：同时启用多于一个时模块会停止运行，并在模块描述中提示。

### 安装步骤
1. 在 Magisk 管理器中刷入本模块 ZIP 包。
2. 安装脚本将自动：
   - 检测 inotify 支持，若无则中止安装。
   - 按模块 id 探测后端并初始化工作目录。
   - 执行一次初始同步并更新模块描述信息；目标文件还没有内容时，这次同步会把谷歌三件套种进去（只种这一次）。
3. **重启设备** 以启动后台守护服务。

---

## 🛠 使用方法

### 手动同步
若需立即触发一次完整同步（应用列表），执行：

```bash
sh /data/adb/modules/keylens/action.sh
```

### 🖥 WebUI 控制台

在管理器的模块详情页点 **「打开界面」/「Open with WebUI」** 即可（KernelSU 主线、KernelSU Next、SukiSU、SmartPack、APatch，以及支持 WebUI 的 Magisk 管理器都有这个入口；**原版 Magisk 管理器没有**，此时仍可用下面的命令行方式）。

界面是**四个目的地 + 一条 MD3 底栏**：`主页 / 功能 / 日志 / 设置`。分工按"这一格回答的是什么问题"，不按功能清单排：主页回答**在不在跑**，功能是**一张菜单集成所有功能**（点进去是二级页，长列表默认收在二级里，菜单页本身落地即用），日志回答**出了什么事**，设置只留**界面自己的事**（外观 + 界面自检）。切页只改地址栏 hash（`#/home`、`#/func`、`#/log`、`#/settings`，`replaceState`；二级页 `#/func/<名>` 走 `pushState`，顶栏出返回箭头，系统返回键回菜单），一级页上没有可退的历史，系统返回一次就退回管理器。视觉语言参考 NoMount 的留白与节奏：**28px 页标题在内容里随页滚走，顶栏滚动后才出 22px 小标题；16/14px 行排版、单色轮廓行首图标、14px 主色分组标签**；主页英雄卡是中性 `surface-container-high`；底栏是悬浮药丸（左右留边、模糊+阴影），只给当前项显示文字，活动图标在胶囊里；长页向下滑时药丸下沉缩小消失，向上滑/回顶恢复。KeyLens 自己的识别是 **KL**：沿用 Opticon 的图标模板（淡粉 `#FCE4EC` 底 + 墨色 `#031019` 字，只换字符），分组标签带镜头光圈点、页脚也有镜头点；状态色收回成“正常=动态主色、注意=琥珀、问题=error”，动态取色仍保留；包名、摘要、keybox 指纹等技术值走等宽字。

| 页面 | 内容 | 能改什么 |
|------|------|----------|
| **主页** | 英雄卡（状态芯片 + **大字后端名 + 后端版本** + 三个小统计：KeyLens 版本 / 生效名单 / 属性伪装开关；契约不匹配时横幅就在这张卡上）、三家互斥矩阵（`Tricky Store / TEE Simulator / OhMyKeymint` 各一行，带图标，三态**启用 / 已禁用（模块目录里有 disable）/ 未安装**，当前生效那行标 ●；三家同开时横幅点名是哪几家，并说清抢的是同一个 keymint HAL） | — |
| **功能**（菜单） | 五项入口：**单色轮廓图标 + 一行当下的状态摘要** —— 目标名单（生效条数 · 目标文件名）、后端配置 · 当前后端（各家的能力面一句话）、自动同步（守护进程数 · 上次写入时间）、密钥箱 keybox（已设置/未设置 · 文件名）、属性伪装（开机写入开/关 · 项数）。点进去才是对应的功能面 | 二级页里各自可改的东西见下 |
| ↳ **目标名单** | **名单 / 已装 / 未纳入 / 已排除** 四颗筛选芯片 + 搜索包名或应用名 + 桌面图标与显示名；Tricky 的条目行尾是 `自动 / 叶证书 / 证书生成` 三态按钮，`自动` 那行直接把上次 TEE 探测算出的去向写在旁边；读不到时第一行是**错误**而不是"这一类是空的" | 名单逐条加入 / 移出 |
| ↳ **后端配置** | 按当前后端渲染：TEESim 的 Profile 表 + overrides.json；Tricky 的 TEE 探测结果 + 全局与按包补丁；OhMyKeymint 的运行状态（keymint / injector daemon + keystore2 注入）+ config.toml + injector.toml + 生效代价 + 重载按钮（keymint / injector / all） | 各家配置字段 |
| ↳ **自动同步** | 守护进程数与事件监听方式 · 目标文件存在与可写 · 上次写入时间 · 日志字节与行数 · 最近一次描述（这是本模块附加的能力，维护的就是「目标名单」里那份文件；强调不上屏） | 立即同步一次 / 重新读取 |
| ↳ **密钥箱 keybox** | 粘贴替换 keybox.xml，三家的判据与文案分叉（见下面「keybox」） | 替换 keybox |
| ↳ **属性伪装** | 系统属性对照（期望值与「当前」两行写在同一项的 supporting 里，只在不符 / 读不到时着色）+ Verified Boot 哈希（当前 digest 与模块应用值） | 开关开机属性伪装、立即应用一次、保存并应用 verifiedBootHash |
| **日志** | `keylens.log` 末尾 30/60/120/300 行。每行拆成「时间 · 级别图标 · 正文」三列对齐，级别只有四个统一图标（信息 / 完成 / 警告 / 错误），正文里的 emoji 前缀在渲染时剥掉；按级别着色，可开 5 秒自动刷新（默认关） | 清空缓冲 |
| **设置** | 外观（跟随系统 / 浅色 / 深色，深浅与强调色都跟随系统）、界面自检（桥接扫过哪些名字、契约号与命令数、执行身份、设备与系统、视口与系统深色） | — |

几点需要知道：

- **调 `enableEdgeToEdge(true)`，不调 `fullScreen(true)`**：状态栏那条缝是宿主窗口的底色（`Theme.KernelSU.WebUI` 里既没有 `statusBarColor` 也没有 `windowBackground`），页面改 CSS 碰不到它，所以让页面画到状态栏下面 —— 宿主的让位 padding 归零后，那条缝就是页面的 `--surface`，两处终于同色。内容位置不变（`appbar`/`.wrap` 吃 `env(safe-area-inset-*)`，viewport 是 `viewport-fit=cover`）。真机实测（2026-10-27）：状态栏与页面同色、顶栏没有被状态栏压住、底部没有再出现手势把手。`fullScreen(true)` 仍然不调 —— 它只是把状态栏藏掉，那根把手还在，还白白丢了时钟与电量。
- 顶栏与系统栏无关：`<meta name="theme-color">` 主线 KernelSU 根本不读（dex 里 0 次出现），所以状态栏那条缝不是改它就能接上的。
- 底部给底栏让位（`.wrap` 的 `padding-bottom` = 104px + 安全区），所以滚到最后一屏时最后一行也完全露得出来；页面背景一直铺到屏幕底边（让位只加在内容容器上，`body` 不留空白带）。
- **底栏四个目的地**：`主页 / 功能 / 日志 / 设置`（自绘四格悬浮药丸，仍监听 `change` + `detail.index` 以兼容台架）。图标固定在各按钮 52px 胶囊的垂直中轴；活动项向左端扩出一个 44px 圆，圆心与 26px 胶囊端、外层 32px 药丸端同心，文字从圆的右侧淡入（不再上下跳）。**功能页是一张菜单**（2026-10-30 用户定稿）：所有功能集中成五项入口，每项带一行状态摘要；长列表（名单、属性对照）默认收进二级页，点进去才画 —— 菜单页本身落地即用。二级页压一层 `pushState`，顶栏 leading 槽出返回箭头、系统返回键回菜单（`popstate` 接管）；**伪装/Verified Boot 是改设备状态的功能，在【功能】页；设置格只留外观与界面自检**。
- **每格从上的顺序**：主页 = 状态条 → 三家互斥矩阵（**都不推迟**，落地页晚一帧就是"打开先空一下"）；功能 = 一张菜单（无长列表）；二级页各自是一到两张功能卡（名单自带 16 条分批）；设置 = 外观 → 界面自检（自检推迟一帧）。
- **长名单分批挂载**：先画 16 条让这一页立刻可交互，其余每帧 16 条补齐，底部小字显示"已显示 N"；换页或重画时令牌 +1，旧循环自己停手。块大小是量出来的：真机 129 条名单下，首帧 40 / 24 / 16 条分别是 259 / 186 / 143ms（稳定 415 / 288 / 250ms），16 条已经超出首屏能露的 6~7 行。OMK 的两块大表单收进「编辑」折叠 —— 控件不点就不建（采样分析器显示耗时主要在组件自己的布局测量，不在我们的渲染函数）。**台架点二级菜单必须用 CDP 可信点击**：md-list-item 会吞合成 `dispatchEvent`/`click()`（探针实测：事件到了 document capture、元素监听器却不响），`Input.dispatchMouseEvent` 一次就通 —— 这也更接近真手指。
- **单文件产物**：MD3E Web 1.0.14 按需 tree-shake + 内联符号字体子集（257 个连字 / 50KB，三个族名指向同一份文件，只内联一次）+ 内联 design tokens，**零网络请求**。图标名必须在子集内（`tools/md3e-build/icon-gate.mjs` 构建第一步就拦），越界会把字面词画在屏幕上；应用图标从 `webroot/icons/*.png` 取，缺图退"首字块"，不露浏览器的破图符。
- **417 CSS px 的画布**：`enableEdgeToEdge(true)`（不调 `fullScreen(true)`，那会白白丢时钟与电量），安全区由 `viewport-fit=cover` + `env(safe-area-inset-*)` 接；深色跟随管理器报的 `env.sys_dark`（CSS 的 `prefers-color-scheme` 在部分 WebView 里不跟系统开关走）；页名记在地址栏 hash（`#/home`、`#/func`、`#/log`、`#/settings`，`replaceState`；二级页 `#/func/<名>` 走 `pushState`，系统返回键回菜单）。
- **界面怎么验收**：`node tools/md3e-build/verify.mjs`（417 钉视口、逐页真点导航、逐后端驱动、底栏几何恒定、切页停在页首、二次进入计时）+ `node tools/replay-check.mjs`（真机数据回放、真桥接形状、图标像素与名单条数断言）。
- **视觉取自 MD3E 自己的令牌**（`@materialwebunofficial/md3e-web` 1.0.14，`dist/tokens.min.css`）：字阶、色角色、形状、动效都用库的默认值，文本字体是 `system-ui`（库里 Roboto 的 `@font-face` 在构建时剥掉 —— 管理器的 WebView 里网页字体不生效，实测退回系统字体）。主色只出现在主行动按钮与选中态；状态着色只给"需要处理"的行（`tone`）。
- **卡与列表由组件负责形状**：`md-card` / `md-list` / `md-list-item` / `md-button` / `md-chip` / `md-switch` / `md-text-field` / `md-select` 全部是 MD3E 自定义元素，模块自己只写布局（`.stack` / `.acts` / `.row`）。**别把裸节点塞进 `md-list`**：它不在列表的白底表面里，会漏到卡片外面压住相邻行（属性页的"当前 …"踩过）；两行文本交给 `supporting-text`（组件是 `white-space:pre-wrap`，换行会正常显示）。
- 布局按**自适应网格**排，不写断点：本机 WebView 是 **417 CSS px** 宽（1644px @630dpi；低分辨率模式 1096px @420dpi 换算后同样是 417.5dp，两套模式都是 417）。改布局后跑 `node tools/md3e-build/verify.mjs`（逐页驱动 + 逐后端驱动，每页断"视口确实钉住、横向溢出 0、渲染出来的区块与标题对得上"）。**别用 `--headless --screenshot --window-size=417` 量宽度**：那样起出来的布局视口其实是 **491**（截图仍旧 834 宽，看着就像 417），溢出检查会静默地在一台不存在的手机上通过。台架里唯一可信的做法是 CDP `Emulation.setDeviceMetricsOverride`，而且它第一步就断言"量到的宽度确实等于要的宽度"。
- **图形语言只有一套**：界面图标全部走 MD3E 的**符号字体连字**（`ICON` 表里的名字必须在 257 连字子集内，`icon-gate.mjs` 构建第一步就拦，越界会把 `security` 这种字面词画在屏上），所以脚本写进日志与状态描述里的 emoji 前缀（`ℹ️ ✅ ⚠️ ❌ 🔄 👀 …`，实测 23 种）在渲染时一律剥掉、换成四个级别图标之一。这一步只能在界面做：缓冲里已有的行早就带着 emoji 落盘了，改脚本只影响新行。
- **短页不做垂直居中**：`.view` 只保证"至少一屏高"（背景一直铺到底栏让位处），内容一律顶部对齐 —— 居中会让同一页的首屏位置随内容多少上下跳，而底栏是 fixed 的，居中省不下什么。
- 界面**不联网、不加载任何外部资源**（单文件；样式、脚本与内联的 Material Web bundle 都在 `index.html` 里，字体直接交给 WebView 的 `system-ui`），断网、无 Play 服务的机器一样能开。WebView 需要 **Chromium 111+** 才能解析 Material Web 2.5；更旧的 WebView 会在顶部直接提示升级，而不是空白页。
- 所有数据都来自一次 root shell 调用：`sh /data/adb/modules/keylens/webui.sh <命令>`，与命令行排查看到的是同一套判定，界面自己不算状态。可用 `sh webui.sh help` 看全部命令。
- 界面开机先问一次 `contract`（命令层自报契约号与命令清单）：**号对不上就横幅明说「界面与命令层不是同一版」，并把写命令挡在传输层外**（读命令仍放行，好让人看到现场）。另外每次调用会校验界面真正要读的关键键（`status` / `env` / `boot-hash` / `sync` / `restore-*` / `remove-apps` 等）：字段名变了会横幅「命令层返回格式不认识」并停写，不会静默画成空值。需要这条是因为迭代时可以只推 `index.html` 或只推 `webui.sh`，不同版以前只会表现为"某个值怪怪的"。改任何命令的输出形状仍要两侧同时把号 +1；电脑上预览可用 `?badapi=99` 验契约号，形状检查可在演示数据里临时改坏一个键验证。
- 界面**不做后台轮询**（与模块"事件驱动、不额外耗电"的取向一致）：数字只在进入页面、点「重新读取」或执行写操作后更新。实测本机（XQ-DQ72）`status` 约 0.6 秒、`env` 约 0.77 秒（每次打开只问一次）、`targets` 约 0.33 秒、`apps` / `rules` / `log` 约 0.1~0.12 秒。
- **颜色与深浅跟随系统**：深浅以系统实际算出的结果为准（`dumpsys uimode` 的 `mComputedNightMode`，取不到再退回 `mCurUiMode` 的夜间位，最后才是 WebView 的媒体查询），落到 MD3E 的 `[data-theme=dark]` 上；外观卡提供 跟随系统/浅色/深色 三档覆盖（只影响本次打开）。
- **强调色是动态的（Material You）**，四级回退，取到哪一级在外观卡里照实写出：① SystemUI 运行时生成的 Material You overlay `/data/resource-cache/com.android.systemui-accent-*.frro`（**这是系统正在用的那套色**，用户手选颜色时它同样会重新生成，所以比任何 setting 都权威；模块只做「取文件 + base64」，解析在界面里，并用「tonal 阶梯明度必须单调」当自检，不单调就整份丢掉）→ ② `settings get secure theme_custom_color` → ③ 壁纸提取色 `dumpsys wallpaper` 的 `colorValue0` → ④ 平台默认 `system_accent1`（framework-res 的 #4b5d8b，**不是** MD3E 库自己那支紫）。映射规矩：各角色的明度档位用界面内置的那套，只换色相；彩度按实测比值走（primary 精确落到系统实测彩度，其余角色按内置比例跟随），不做审美放大。
  界面里 `--primary` 是 `oklch(49% .19×sat hue)`，而系统 `accent1_600` 的明度就在 49% 那一档，所以 `sat = 系统实测C / .19` 即可对上——**彩度按实测比值走，不做审美放大**（放大过的版本色相差不多却完全不像一套东西）。
  需要说清楚的是：跟的是**色相与彩度**，各角色的明度档位仍用界面内置的那一套——模块侧拿不到系统算好的 12 组色调表本身，只能拿到这份 overlay 文件里的 ARGB。
- **字体直接使用 WebView 的 `system-ui`**（与机上 `nomount` 等模块的 WebUI 一致）：本机 WebView 156 下 system-ui 就按系统字体（当前 overlay 的 `config_bodyFontFamily` 是 `google-sans-flex`）渲染。界面不再探测/复制/加载 ttf，也不写 `@font-face`；Material Web 组件通过 `--md-ref-typeface-plain: var(--font)` 使用同一份字体。**字号**仍按界面自己的七档 px，不跟随系统 `font_scale`。
- 松紧交给 MD3E 的令牌与组件（间距 `--md-sys-spacing-*`、形状、字阶都是库的默认值），本模块自己的布局层只有壳与排版（`.stack` / `.acts` / `.row` / `.console`，加上 `--bar-h` / `--nav-h` / `--gap` / `--line` 四个变量）——**别复制一份 MD3 数值进 app.css**，复制了就会有两套，改一处漏一处。
- 「立即应用一次」是**运行期**写属性，`ro.build.type` 这类已经被 Zygote 读进 Java 静态字段的值不会因此刷新，要彻底生效仍需重启；开机伪装开关只影响下一次开机。
- 想在电脑上预览界面：`node tools/md3e-build/build.mjs` 之后用 Chrome 打开 `webui/dist/index.html?demo=1`（内置一份演示数据，不会碰真机）。参数：`&backend=tricky|teesim|omk` 切假后端、`&fail=targets` 造一次读失败、`&conflict=1` 造三家同开、`&seed=0xAARRGGBB` 模拟系统强调色。正式验收跑 `node tools/md3e-build/verify.mjs`（逐页真点导航 + 逐后端驱动 + 深浅/安全区/配色三组运行时断言）。

> 贡献者提示：`webroot/` 是各管理器约定的 WebUI 目录，入口文件名必须是 `index.html`；**样式与脚本不要拆成多个 css/js 文件**——部分管理器用 `file://` 加载且不解析子资源路径。Material Web bundle 也是内联的；`tools/mwc-build/` 只用于维护时重新生成它（`npm install && npm run build`），不会进刷机包。唯一的运行时子资源例外是 `webroot/icons/*.png`：那是运行时导出的图片，读不到时界面会退成首字块，所以缺了也不影响任何功能与可读性。第三方许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

### 改完界面怎么上机、怎么验收

三条命令，各自退非 0：

```sh
node tools/md3e-build/icon-gate.mjs      # 图标名必须在 257 连字子集内（越界直接拒绝出产物）
node tools/md3e-build/build.mjs --ship   # webui/src → webui/dist + module/webroot/index.html（不带 --ship 只出候选）
node tools/md3e-build/build.mjs --check  # 两条产物是否都由当前源码构建（CI 不重建，靠这条兜）
node tools/md3e-build/verify.mjs         # 417 钉视口：逐页驱动 + 逐后端驱动 + "读不到 ≠ 是空的" + 互斥那一屏
node tools/md3e-build/check-artifact.mjs # 占位符 / 字体内联 / 源码可达 / 字节数下限
node tools/kv-shape-check.mjs            # 界面读的键、KV_REQUIRED 要的键、假数据里的键 ⊆ 命令层实际输出的键
node tests/ui-shape.js                   # 表单字段 ↔ webui.sh 的 case 逐条对账 + 结构底线
node tools/json-flat-set-check.cjs       # 扁平 JSON 定点改写（含"留空即删除"的四种位置）
sh tests/*.sh                            # 19 个 shell 套子（CI 里循环全跑，一个都不漏）
sh tools/deploy-webui.sh                 # 推界面 + chmod 644 + 逐文件对 sha256（--shell 推命令层，--all 两者）
```

- **新版（`webui/src/`）的验收线是"逐后端各跑一遍"**：`verify.mjs` 用 `?backend=tricky|teesim|omk` 切假数据，每家的块要画出**只有真读到那个键才会出现的值**才算过；`?fail=targets` 那一趟专门钉"读不到"与"是空的"是两种画面。理由是一次真事故：界面按上游文件的小驼峰键名（`teeBroken`）去读命令层下划线风格的输出（`tee_broken`），而假数据是照着这段错代码写的，两边互相自证，逐页驱动一路全绿。
- **键名不再靠眼看**：`node tools/kv-shape-check.mjs` 把 `webui.sh` 的 `kv <键>` 与 `backends/*.awk` 的 `print "键="` 汇成"命令层实际会输出"的集合，再拿界面读取、`KV_REQUIRED`、假数据三边去对；它自己由 `node tools/mutate-kv-shape.cjs` 变异验过三处都会响。

- **`adb push` 默认把文件落成 0666**，而这个 `index.html` 由管理器以 root 加载、里面的命令以 root 执行 —— 世界可写等于任何应用都能改写一个 root 界面。所以"模式不是 644/444 就退非 0"是部署脚本的硬闸门，不靠人记得 `chmod`。脚本还会拒绝"工作区有未提交改动"（否则设备上跑的版本对不上仓库，回头说不清），并要求 `adb shell` 是 root。
- **量布局别用 `--headless --screenshot --window-size=417`**：那样起出来的布局视口是 **491**，截图仍旧 834 宽，看着像 417 —— 溢出检查会静默地在一台不存在的手机上通过。台架用 CDP `Emulation.setDeviceMetricsOverride` 钉死，并且第一步就断言"量到的宽度确实等于要的宽度"。
- 台架与闸门都用变异验过：往 `.console` 塞 `min-width:900px`、让 `applyPage` 不再藏面板、把 `chmod` 改成 666、推完再往设备文件尾部追加一个字节 —— 每一种都让对应的检查退非 0 并点名。
- **新版（`webui/src/` → MD3E Web）有一条硬约束：图标名必须在字体子集里。** 库自带的是**子集**符号字体（`tools/md3e-build/vendor/icons.txt`，257 个连字 / 50KB；全量圆体 5.3MB，不可能内联），而组件把图标名当**连字文本**画 —— 名字不在子集里，界面就把 `security`、`DASHBOARD` 原样画在屏幕上（不是降级，是脏）。所以 `icon-gate.mjs` 是构建的第一步，越界名字直接拒绝出产物。子集内可用的有 `home` `category` `article` `info` `https` `group` `refresh` `settings` `tune` `verified` `download` `delete` `edit` `history` `error` `warning` `check` `expand_more` `chevron_right` `more_vert` `search` `label` `folder` `schedule`；**不在**子集的：`sync` `apps` `dashboard` `security` `build` `shield` `key` `dns` `storage` `phone_android` —— 要这类图形就走 slot 自己画内联 SVG。构建验收（`verify-build.mjs`）带一正一负两个对照：子集内的名字量出来必须是一个字形的宽度，子集外的仍旧是八个字母 —— 只量正则会漏掉"整个字体没落地"。

### 查看运行状态
- **模块描述**：在模块详情页，`description` 字段动态显示：
  ```
  ✅ [后端 | 应用: X | 更新: HH:MM]
  ```
  写入失败时显示 `⚠️ [… 写入失败 …]`，后端冲突停止时显示 `⛔ [模块已停止 …]`。

- **运行日志**：日志同时写 `logcat`（tag `KeyLens`）与本地缓冲 `/data/adb/keylens.log`（超过 64KB 自动只保留末尾 200 行）。
  最省事的方式是在管理器里点模块的“操作”按钮：`action.sh` 会同步一次并附带打印最近 15 条日志，无需自己 `su`。

  以下命令供手动排查使用。

  设备上读日志**需要 root**（`/data/adb` 为 `0700`；在终端 App 里先 `su`，或用 `su -c '...'` 包裹）：

  ```bash
  tail -n 50 /data/adb/keylens.log                     # 本地缓冲，跨重启保留（推荐）
  grep -E '后端|同步|失败|停止' /data/adb/keylens.log   # 只看关键行
  logcat -d -s KeyLens | tail -n 30                    # 系统日志（重启即清空）
  logcat -s TS-AUTO                                    # 实时跟随（Ctrl+C 退出）
  logcat -c                                            # 先清空系统缓冲再操作，便于观察单次行为
  ```

  电脑上（需已开启 USB 调试；`adb` 读 `logcat` 不需要 root，读 `/data/adb` 需要）：

  ```bash
  adb logcat -s TS-AUTO                                       # 实时查看（不需要 root）
  adb shell su -c 'tail -n 50 /data/adb/keylens.log'          # 读本地缓冲（需要 root）
  adb shell su -c 'cat /data/adb/keylens.log' > keylens_log.txt   # 导出到电脑再慢慢看
  ```

  > 模块只在**开机**与**文件变化**（安装/卸载应用）时写日志，没有事件时不会有输出，属正常现象。缓冲文件的每行都带 `月-日 时:分:秒` 时间戳，不依赖 `logcat` 缓冲是否还在。

### 名单就是目标文件

没有第二份"常驻列表"：**目标文件本身**就是名单，同步只在上面应用增量。

| 后端 | 文件 | 改哪里 |
|------|------|--------|
| TEE Simulator | `/data/adb/teesim/config.json` 的 `profiles.default.apps` | 直接改数组；其它字段与其它 profile 原样保留 |
| Tricky Store / OSS | `/data/adb/tricky_store/target.txt` | 每行一个包名；可带 `?` / `!` 模式与 `#` 注释 |
| OhMyKeymint | `/data/misc/keystore/omk/injector.toml` 的 `scoop` | 直接改数组；`config.toml` 与本文件的其它段不碰 |

三个后端的条目语法并不相同，模块按各自上游的解析规则处理，而不是把它们都当成裸包名：

- **Tricky Store OSS**：`pkg` / `pkg?`（强制叶证书破解）/ `pkg!`（强制证书生成），`#` 之后是行内注释；同一个包名出现多次时后出现的模式生效。界面「名单」行尾可直接切换模式，只改这一行的后缀，注释与其它行保留。
- **TEE Simulator**：`apps` 支持 `pkg` / `pkg@用户` / `uid:数字`，模块原样保留这些 token；卸载一个包时连同它的 `@用户` 变体一起移除，`uid:` 条目因为无法反查包名而保留。
- **OhMyKeymint**：`scoop` 只接受包名。
- 同步的「加入 / 删除」按**基础包名**判断：`pkg?`、`pkg@10` 都算 `pkg` 已在名单里，不会因为换了个写法被重复加入或误删。

### 后端配置（WebUI 手动编辑）

「后端与格式」页的配置区按当前后端渲染可编辑字段，只提交改动过的项；未知字段、非法枚举/日期/包名会在写盘前拒绝，写前备份到后端数据目录：

> **payload 的最后一个字段以前会被静默丢掉**：`parse_payload` 用 `while read` 逐行解，而 `read` 在最后一行**没有换行符**时直接结束循环 —— 界面拼的正是 `join('\n')`（无尾换行），于是"改 N 个存进 N−1 个"，丢的那个连校验都没过。现已修掉并配了回归测试（`tests/payload-last-field.sh`，含"撤掉修复必须变红"的自证）。
>
> OhMyKeymint 的 `[trust]` 字段现在按上游文档校验（`auto|latest|YYYY-MM-DD`、`auto|random|64hex`、`os_version` 是 0–99 的 MMmmss 编码值而不是年份）；以前一律 `valid_text 128`，写错的关键字 OMK 读不懂时会静默退回默认值。

三条只读命令已经把三家文档里的能力面读出来了，**界面还没画它们**（在新版重构里）：`teesim-profiles`（TEESim 的多 profile 表，写回路径以前只认 `default`）、`tricky-patches`（`security_patch.txt` 的全局与 `[包名]` 按包块）、`tee-status`（Tricky 自己的 TEE 探测结果，即"为什么只能走 leaf hack"）；写命令多一条 `omk-restart <keymint|injector|all>`。契约号仍是 **4** —— 只加命令、不改任何既有输出形状，涨号会让手机上旧界面当场停写。

| 后端 | 可编辑项 | 备份 / 生效 |
|------|----------|-------------|
| TEE Simulator | default profile：`mode`、`keybox`、`patchLevel.system/vendor/boot`、`osVersion`、`autoIncludeNewApps`；brand / device / product / manufacturer / model / serial / imei / meid / imei2 | `config.json.bak`；TEE Simulator 的目录 watcher 自动重载 |
| Tricky Store OSS | `security_patch.txt` 全局 `system / vendor / boot / all`（包级段保留）；keybox.xml | `security_patch.txt.bak` / `keybox.xml.bak`；文件 watcher 自动重载 |
| OhMyKeymint | injector.toml：`[main]` 开关与日志、`[filter]` 开关/拒绝包、`[intercept]` 10 项；config.toml：`[main]` 日志与两个开关、`[trust]` 补丁/密钥/验证开关、`[device]` 身份 | `injector.toml.bak` / `config.toml.bak`；写后请求 `restart.injector` / `restart.keymint`（OMK 自己的机制） |

- keybox 用「粘贴替换」：接受 `<AndroidAttestation>…</AndroidAttestation>`，上限 128KB；TEE Simulator 写到 config 当前指定的文件名，选择其它已存在的 `*.xml` 改 keybox 文件名即可。
- 名单与 Tricky 的条目模式仍在「应用列表」维护；配置页不写 `apps` / `scoop`，避免和自动同步互相覆盖。

- **装上自动进、卸载自动出**；你手动加的条目会保留，手动删掉的不会被自动加回来。
- 算法是**快照差分**：`加入 = 本轮已装 − 上次已装`，`删除 = 上次已装 − 本轮已装`，其余（目标文件里的现有条目）原样保留。手动删掉的包仍然装着、但不在"新装"里，所以结构上就不会被回填 —— 没有墓碑文件。想恢复就把它加回文件；应用页里名单外的行尾有一个 **+**（加入）、「已排除」的行另有中性标签和 **+**（加回），等价于写回文件；在「名单」视图点「选择」可以多选移出（一次写入、至少保留一条），移出前会把当前名单并入 `.kl_ever`，所以移出的包仍显示为「已排除」而不会被自动加回；移出后 6 秒内可在提示条点「撤销」精确恢复。卸载后再装一次也会重新加入。
- **OhMyKeymint 首次接入**：`scoop` 已有内容时沿用现有名单（不批量加入已装），只把当前已装记成基线；之后的新装照常加入。`scoop` 为空时才按其它后端一样加入全部已装 + 三件套。
- **空列表保护**：后台自动同步读到「已装为空、但基线非空」时会放弃这次写入（这更像一次 `pm` 读取失败，而不是真把应用全卸了），并把失败写进模块描述；点界面「立即同步」或用管理器的「操作」按钮会强制按当前已装处理。
- 首次安装后的第一次同步会把谷歌三件套（`com.android.vending` / `com.google.android.gms` / `com.google.android.gsf`）种进去**一次** —— 它们是系统应用，不会被"已装第三方"覆盖到。之后你把它们从名单里删掉，也不会再被加回来。
- 改完文件不用重启：守护进程监听 `packages.list`，下一次应用装卸时会顺带按最新内容重算；想立刻生效就点界面上的「立即同步」。
---

## 📂 数据与配置路径

运行时文件位于**当前后端目录**（TEE Simulator：`/data/adb/teesim/`；Tricky Store：`/data/adb/tricky_store/`；OhMyKeymint：本模块的 `.kl_*` 状态寄生在 OMK 自己的 `/data/adb/omk/`，配置本身在 `/data/misc/keystore/omk/`）：

| 文件 | 说明 |
|------|------|
| `config.json` | TEE Simulator 配置（模块仅维护 `profiles.default.apps`） |
| `target.txt` | Tricky Store / OSS 的应用列表（模块按增量维护：只加新装、只删卸掉的，你手动加的条目保留） |
| `injector.toml` | OhMyKeymint 的名单（模块仅维护 `scoop`；`config.toml` 不碰） |
| `.kl_daemon_pids.list` | 所有后台子进程 PID 列表 |
| `.kl_fingerprint` | 源数据指纹缓存（变更检测用） |
| `.kl_installed_last` | 上次同步看到的「已装第三方」，快照差分的基线 |
| `.kl_ever` | 历次纳入过名单的并集（判断「已排除」用；OhMyKeymint 首次沿用现有 scoop 时不能拿基线当这个集合） |
| `.kl_lock` / `.kl_debounce` / `.kl_tmp` | 运行时锁与临时文件 |

> 日志缓冲不放在后端目录，而是固定在 `/data/adb/keylens.log`（权限 `600`，仅 root 可读；超过 64KB 自动只保留末尾 200 行；卸载时自动删除）。
>
> 属性伪装开关同样不放在后端目录，而是 `/data/adb/keylens.props_off`：**文件存在 = 已关闭**，由 WebUI 的「属性」页写入/删除，覆盖安装模块不会丢失，卸载时一并清理。
>
> Verified Boot 哈希保存在 `/data/adb/keylens.boot_hash`（权限 `600`，内容为 64/128 位十六进制），卸载时一并清理。

---

## ⚙️ 属性重置覆盖清单

开机早期（`post-fs-data.sh`，Zygote 启动前）强制重置以下属性：

| 属性名 | 重置值 | 作用 |
|--------|--------|------|
| `ro.build.type` | `user` | 设置为用户版（修复 `Build.TYPE` 显示 userdebug） |
| `ro.build.tags` | `release-keys` | 发布密钥 |
| `ro.boot.vbmeta.device_state` | `locked` | 模拟 Bootloader 锁定 |
| `ro.boot.verifiedbootstate` | `green` | 模拟验证状态为绿标 |
| `ro.boot.flash.locked` | `1` | 锁定闪存状态 |
| `ro.boot.veritymode` | `enforcing` | 强制开启 verity |
| `ro.boot.warranty_bit` | `0` | 清除保修位 |
| `ro.warranty_bit` | `0` | 同上 |
| `ro.debuggable` | `0` | 关闭可调试 |
| `ro.force.debuggable` | `0` | 强制关闭调试 |
| `ro.secure` | `1` | 启用安全模式 |
| `ro.adb.secure` | `1` | 启用 ADB 安全 |
| `ro.vendor.boot.warranty_bit` | `0` | 供应商保修位清零 |
| `ro.vendor.warranty_bit` | `0` | 同上 |
| `vendor.boot.warranty_bit` | `0` | 同上 |
| `ro.bootloader`（若含 `engineering`） | `release` | 隐藏工程版 Bootloader |
| `ro.build.description`（若含 `test-keys`） | `release-keys` | 隐藏测试密钥 |

> **提示**：不需要属性重置时，直接在模块 WebUI 的「属性」页关掉开关即可（写入 `/data/adb/keylens.props_off`，下次开机生效，覆盖安装模块不会丢失）；没有 WebUI 入口的话，也可以在 `post-fs-data.sh` 中删除或注释 `apply_resetprop` 调用后重启。
>
> **开机后复核**：`service.sh` 等到 `sys.boot_completed` 后会把这张表**再幂等跑一遍**（已符合的不重复写）。有些机型在 post-fs-data 之后才落锁状态 / AVB 元数据，早段写入会被系统覆盖，这一遍就是兜住它。
>
> **Verified Boot 哈希**：在「属性」页粘贴从 KeyAttestation 等处取到的 `verifiedBootHash`（64 位 = sha256，128 位 = sha512），开机时写进 `ro.boot.vbmeta.digest`，并只补空的 `ro.boot.vbmeta.hash_alg`。它和上面的伪装开关**互相独立**：只要保存了，开关关着也会应用。只用 `resetprop -n` 写本次运行，重启回系统原值；清除只影响下次开机。

---

## 🔄 更新亮点（v2.2.19.5-yuzu）

- **日志双写 + 本地缓冲**：日志除写入 `logcat` 外，另写 `/data/adb/keylens.log`（带时间戳，超 64KB 只保留末尾 200 行），解决 `logcat` 环形缓冲被系统刷掉后查不到记录的问题。
- **工程整理**：换行符统一为 LF（新增 `.gitattributes`），CI 增加 `sh -n` 语法检查，README 增加 CI / Release / License 徽章与下载入口。
- **新增 TEE Simulator 后端**：按模块 id `teesim` 探测，仅替换 `config.json` 中 `profiles.default.apps`，其余字段与其它 profile 原样保留。
- **后端冲突即停止**：Tricky Store 与 TEE Simulator 同时启用时模块停止运行，并把状态写入模块描述（`⛔`）。
- **常驻列表支持注释**：`rules.txt` 支持 `#` 中文注释与空行；同步前自动补齐末行换行、清除 UTF-8 BOM，避免包名被污染。
- **写入失败可见**：写入失败会标注到模块描述（`⚠️`），手动同步退出码为 `1`，不再“显示正常但其实没写进去”。
- **监听修复**：修正 inotify 探测方式（busybox 设备不再被误判为“无 inotify 工具”）与 `inotifyd` 事件的读取方式。
- **省电稳定**：无后台联网轮询；单进程 inotify 监听；内容指纹比对，仅在数据真实变化时同步。
- **属性伪装提前**：`apply_resetprop` 在 `post-fs-data.sh`（Zygote 前）执行，修复 `Build.TYPE` 检测。

更早的改动（后端判定改为按模块 id、移除安全补丁、`taa_sys.txt` 更名 `rules.txt`、模块结构分层等）见 `CHANGELOG.md` 的 `v2.2.19.4-yuzu` / `v2.1.08.3-yuzu` / `v2.0.97.2-yuzu` 条目。

详细变更请参阅模块根目录下的 `CHANGELOG.md`。

---

## ❓ 常见问题

**Q：点「打开界面」没有反应，或界面提示“当前管理器不支持 WebUI”？**  
A：WebUI 需要管理器自己实现入口——原版 Magisk 管理器没有，KernelSU（主线）/ KernelSU Next / SukiSU / SmartPack / APatch 等才有。这种情况下**模块功能完全不受影响**，改用命令行即可：`sh /data/adb/modules/keylens/action.sh` 同步并打印最近日志，`sh /data/adb/modules/keylens/webui.sh status` 输出界面用的同一份结构化状态（`webui.sh help` 看全部命令）。若界面能打开但一片空白，通常是管理器的 WebView 版本过旧（Material Web 需要 Chromium 111+，可在系统里更新 Android System WebView）或禁用了 JavaScript；重新覆盖安装模块可确认 `webroot/` 是否完整。

**Q：界面提示「当前管理器没有提供可用的 exec 桥接」，但我的管理器明明有 WebUI 入口？**  
A：各家注入的桥接对象名与调用形状不一样（KernelSU 主线是 `window.ksu.exec(cmd, optionsJson, 回调函数名)` 的**异步回调**，部分是同步返回 `{errno, stdout}`）。这种情况下界面会直接把扫描结果列出来——扫到了哪些对象、各自有哪些方法，据此就能判断该认谁；把那一屏反馈给维护者即可。

**Q：怎么看模块日志？为什么 logcat 里一会儿就没了？**  
A：日志同时写 `logcat`（tag `KeyLens`）与本地缓冲 `/data/adb/keylens.log`。`logcat` 的缓冲默认只有几百 KB 且由全系统共用，系统繁忙时旧记录很快被挤掉、重启即清空 —— 这正是“一会儿就没了”的原因；缓冲文件跨重启保留，排查请优先看它（超过 64KB 会自动只保留末尾 200 行）。设备上读这两处**都需要 root**（`/data/adb` 为 `0700`，终端里先 `su`，或用 `su -c '...'`）；电脑上 `adb logcat -s TS-AUTO` 不需要 root，读缓冲文件需要 `adb shell su -c '...'`。最省事的方式是在管理器里点模块的“操作”按钮 —— `action.sh` 会附带打印最近 15 条日志。完整命令与排查步骤见上方「🛠 使用方法 → 查看运行状态」。另外模块只在**开机**与**文件变化**时写日志，没有事件时没有输出属正常现象。

**Q：安装时提示“未找到 inotify 工具”？**  
A：请确认系统是否包含 `inotifywait` 或 `inotifyd`。部分精简 ROM 可能缺失，可尝试安装 Busybox 或更换 ROM（Magisk / KernelSU / APatch 自带的 busybox 会被自动识别）。

**Q：模块描述显示“模块已停止”？**  
A：说明 Tricky Store / TEE Simulator / OhMyKeymint 中有多于一个同时启用。停用或卸载多余的，只留一个后重启即可恢复。

**Q：模块描述显示“写入失败”？**  
A：目标文件不可写（目录只读、文件被占用等），或 OhMyKeymint 的 `injector.toml` 还没生成。检查对应后端目录的权限、先打开一次 OMK 后重试（执行 `action.sh` 或等待下次事件触发）。

**Q：`target.txt` 未按预期更新？**  
A：先看本地缓冲 `tail -n 50 /data/adb/keylens.log`（或 `logcat -d -s KeyLens`）里的错误信息；确认 `pm` 命令可用；尝试手动执行 `action.sh` 测试。

**Q：OhMyKeymint 的 `injector.toml` 被改动了？**  
A：模块只改 `scoop` 数组，写入前备份到 `/data/adb/omk/injector.toml.bak`；其它段与 `config.toml` 不碰。写入后会写 `/data/adb/omk/restart.injector`，让 OMK 自己重载 injector。

**Q：如何临时禁用后台监听？**  
A：可删除后端目录下的 `.kl_daemon_pids.list` 并重启，或直接卸载模块。

---

## 📝 许可证

本模块遵循 **GPL-3.0** 开源协议，欢迎贡献代码与反馈问题。

---

**版本**：v2.2.19.5-yuzu  
**更新日期**：2026-09-14  
**维护者**：IamCanincan
