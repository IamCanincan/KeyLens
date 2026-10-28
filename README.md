# TS-AUTO-ADD (v2.2.19.5-yuzu)

[![Build CI Module](https://github.com/IamCanincan/TS-AUTO-ADD/actions/workflows/build_ci.yml/badge.svg)](https://github.com/IamCanincan/TS-AUTO-ADD/actions/workflows/build_ci.yml)
[![Latest Release](https://img.shields.io/github/v/release/IamCanincan/TS-AUTO-ADD?label=release&color=blue)](https://github.com/IamCanincan/TS-AUTO-ADD/releases/latest)
[![License](https://img.shields.io/github/license/IamCanincan/TS-AUTO-ADD?color=green)](LICENSE)

TS-AUTO-ADD 是一个面向 **[Tricky Store](https://github.com/5ec1cff/TrickyStore)** / **[Tricky Store OSS](https://github.com/beakthoven/TrickyStoreOSS)** / **TEE Simulator** / **[OhMyKeymint](https://github.com/qwq233/OhMyKeymint)** 的 Magisk 辅助模块，通过后台守护进程自动维护应用包名列表，并可在开机时重置关键系统属性，有效提升 Play Integrity 通过率。

> 本模块**不再修改安全补丁**（`security_patch.txt`），仅维护应用列表与系统属性。

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
  所有后台子进程 PID 记录于 `.ts_daemon_pids.list`，卸载时可一次性全部终止，无残留。

- **运行日志（logcat + 本地缓冲）**  
  日志同时写入系统日志（`logcat`，tag 为 `TS-AUTO`）与本地缓冲文件 `/data/adb/ts_auto.log`。`logcat` 是内存环形缓冲（默认仅几百 KB 且全系统共用），系统繁忙时旧记录很快被挤掉、重启即清空；缓冲文件容量固定（超过 64KB 自动只保留末尾 200 行）、跨重启保留，权限 `600` 且位于 `0700` 的 `/data/adb`，仅 root 可读。

- **WebUI 控制台（Material 3 Expressive）**  
  模块自带 `webroot/index.html`，在支持 WebUI 的管理器里点模块的「打开界面」即可：查看运行状态、对照目标名单与已装应用、翻日志、手动同步，以及一键开关开机属性伪装。界面是单文件、不联网、不依赖任何外部库或字体。

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
│  └─ index.html          # WebUI 界面（单文件，内联样式与脚本）
│                         # 运行时会多出 webroot/icons/*.png —— 由 webui.sh icons 从桌面
│                         # 图标缓存导出，不进仓库、不进刷机包
└─ META-INF/              # 刷机包脚本

tools/                     # 不进刷机包：构建与自检
tests/watch-backoff.sh     # 监听退避的自检（CI 跑）
tools/icondump/            # 图标 dex 的源码与编译命令
```

- **入口脚本必须留在根目录**：Magisk / KernelSU / APatch 按固定路径调用 `customize.sh` / `post-fs-data.sh` / `service.sh` / `uninstall.sh`，管理器“操作”按钮调用 `action.sh`。
- `lib/` 放共享库，`backends/` 放后端实现（每个后端一个文件）；入口脚本与 `lib/common.sh` 中都不含后端专属逻辑。
- `webroot/` 是各管理器约定的 WebUI 目录（入口必须是 `index.html`）；界面不直接读文件，一律经 `webui.sh` 取数，这样状态判定与命令行排查看到的是同一份逻辑。

---

## 📥 安装与部署

### 下载
- **发行版（推荐）**：到 [Releases](https://github.com/IamCanincan/TS-AUTO-ADD/releases) 下载 `TS-AUTO-ADD-<版本>.zip`（文件名与 `update.json` 中的 `zipUrl` 一致，管理器内更新也走这一份）。
- **CI 构建**：每次推送到 `main` 会自动构建，版本号附带时间戳后缀（`-ci`）。到 [Actions](https://github.com/IamCanincan/TS-AUTO-ADD/actions/workflows/build_ci.yml) 打开最近一次运行，在页面底部 Artifacts 下载 —— 仅供测试，不要当作正式版本。

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
sh /data/adb/modules/ts-auto-add/action.sh
```

### 🖥 WebUI 控制台

在管理器的模块详情页点 **「打开界面」/「Open with WebUI」** 即可（KernelSU 主线、KernelSU Next、SukiSU、SmartPack、APatch，以及支持 WebUI 的 Magisk 管理器都有这个入口；**原版 Magisk 管理器没有**，此时仍可用下面的命令行方式）。

界面是「**概览 + 四个二级页**」，没有底栏：概览页上半是状态英雄卡、中间是入口卡（应用列表 / 运行日志 / 系统属性伪装 / 关于与自检；副标题只说这一页干什么，数字留给英雄卡与状态卡）。**四个入口是同一条路**：`#/apps`…`#/about` 各占一个 hash，进去都是顶栏左侧一个返回箭头、下半是同步链路与配置明细。点一行进入二级页，顶栏左侧出现返回箭头，回到概览会还原离开时的滚动位置。⚠ **别指望系统的边缘返回退这一级**：实测那一下是关掉整个 WebUI（`{m=CLOSE WebUIActivity}`），这是宿主 Activity 的行为，模块改不了。

| 页面 | 内容 | 能改什么 |
|------|------|----------|
| **概览** | 生效应用数（大数字）、第三方条目数、后端、目标文件与可写性、上次写入时间、监听方式、守护进程、日志缓冲、属性伪装状态。**诊断信息不在这页上** —— 它们在「关于与自检」那一页（`#/about`） | 只读 |
| **应用** | 目标名单与已安装第三方应用对照，**带桌面图标与应用显示名**（没有图标时退成首字块；没有启动器入口的应用走 `PackageManager` 取图标），名单外的已装应用标「未纳入」、被你手动删过的标「已排除」（点行尾的 **+** 可加回名单），可搜索（应用名与包名都匹配）、可「只看未纳入」 | 恢复单条被排除的应用（写回目标文件） |
| **日志** | `ts_auto.log` 末尾 30/60/120/300 行，按级别着色，可清空缓冲、可开 5 秒自动刷新（默认关） | 清空日志 |
| **属性** | 17 项属性的「当前值 / 期望值 / 是否一致」，以及 Verified Boot 哈希的当前值与保存值 | 开关开机伪装、立即应用一次、保存 / 清除 verifiedBootHash |

几点需要知道：

- **调 `enableEdgeToEdge(true)`，不调 `fullScreen(true)`**：状态栏那条缝是宿主窗口的底色（`Theme.KernelSU.WebUI` 里既没有 `statusBarColor` 也没有 `windowBackground`），页面改 CSS 碰不到它，所以让页面画到状态栏下面 —— 宿主的让位 padding 归零后，那条缝就是页面的 `--surface`，两处终于同色。内容位置不变（`appbar`/`.wrap` 吃 `env(safe-area-inset-*)`，viewport 是 `viewport-fit=cover`）。真机实测（2026-10-27）：状态栏与页面同色、顶栏没有被状态栏压住、底部没有再出现手势把手。`fullScreen(true)` 仍然不调 —— 它只是把状态栏藏掉，那根把手还在，还白白丢了时钟与电量。
- 顶栏与系统栏无关：`<meta name="theme-color">` 主线 KernelSU 根本不读（dex 里 0 次出现），所以状态栏那条缝不是改它就能接上的。
- 底部有页脚收尾（`TS-AUTO-ADD · 只在开机与文件变化时同步 · 界面不联网`），`body` 竖排 + `.wrap` 撑满 + 页脚 `margin-top:auto`：内容短时页脚贴视口底部，内容长时跟在内容后面；页面内容结束时有个明确收口。
- **没有底栏，导航就是概览页上的四行入口**：每行是图标 + 标题 + 实时副标题（生效 N · 第三方 M / 缓冲 N 行 / 开机写入开或关）+ 右侧箭头。底栏那条横滑轨道（`scroll-snap` + 指示胶囊插值 + 容器高度同步）正是「抽搐」和「切页闪」的来源，连同它一起删掉了。
- **页内返回拿不到「可预测返回」的预览**：反汇编宿主可以看到它用的是普通 `BackHandler` —— 全 dex 里 `startBackProgress`、`getBackProgress` **0 次**，也就是宿主根本没实现应用内预览；系统能画的那种预览只覆盖**跨 Activity**（从 WebUI 退回管理器就是这一种，所以那一下有预览、页内那一下没有）。网页这层也没有接口：屏幕边缘的拖动被系统手势接管，页面收不到，也没有任何 API 能把「上一页长什么样」喂给系统。所以页内返回的动效上限就是方向一致的滑入（下钻从右、返回从左）。
- **二级页的顶栏钉住**（`position:sticky`）：返回箭头是那一屏唯一的出口，长列表滚到一半不能让它滚走；概览不钉，让内容照常滚。二级页隐藏英雄卡，一屏只有标题 + 内容。下钻与返回都只滑当前面板（24px / 200ms，WAAPI 在合成器上跑，不碰高度、不盖遮罩）；返回时英雄卡跟着一起滑，否则它会硬蹦出来。
- **导航状态写在地址栏的 hash 上**（`#/over`、`#/apps`…），顶栏箭头与 `popstate` 是同一条路；宿主的返回是「`doUpdateVisitedHistory` 里读 `webView.canGoBack()` 写进状态 → 返回回调执行 `webView.goBack()`」（dex 实测），但**这条链在实测里没被走通过**：直接指定组件起第二个实例会被它自己 finish（`Displayed +61ms` 紧跟 `type=CLOSE numActivities=0`），走管理器的 `ksu://webui/…` 则是管理器起来了、却没替我们起 WebUI —— 所以系统边缘返回目前**就是关掉整个界面**，页内返回请用顶栏箭头。⚠ **也没有安卓的可预测返回预览**：预览要宿主实现 `OnBackAnimationCallback` 并驱动 `startBackProgress`，全 dex 里 `startBackProgress` / `getBackProgress` 各 **0 次** —— 系统只会为**跨 Activity**（WebUI → 管理器）那一下自己截图，页内这一档它没有画面可画，页面也没有接口能喂。滚动位置自己管（`history.scrollRestoration = 'manual'`），回概览时还原 —— 否则浏览器会把下钻前已归零的位置再恢复一次，把还原抹掉（实测 52 → 0）。
- 视觉只有一套语言：**静止形状全部对称**（按钮一律胶囊、卡片与格子一律单一圆角，切角与「叶子形」已收掉），**主色只出现在两处**——生效数字与主行动按钮；正常状态不上色（一个点即可），只有需要处理的才着色。最大的那个色块（英雄卡）现在装的是最该被看见的东西，而不是一片底色。
- **每个板块一块底**（`.grp`）：比它所在卡面抬一档（`--surface-high`，与卡面比 1.143 深 / 1.116 浅 —— 和"页底 vs 卡面"那档同量级）。色块往外铺 12、内边距补回 12，所以文字左缘还是那条 41；板块之间外距 20 > 块内 12。格子内部与图标仍然不着色。底色定义在 `:root` 而不是 `.grp` 上 —— 写在 `.grp` 上会盖掉别处的覆盖（自定义属性也是元素自己的声明赢过继承）。
- 布局按**自适应网格**排，不写断点：本机 WebView 是 **417 CSS px** 宽（1644px @630dpi；低分辨率模式 1096px @420dpi 换算后同样是 417.5dp，两套模式都是 417）。概览与「关于」的四个板块在这台机器上各排 **两列**（格子下限 `--cell:150`，列宽 158）—— 值按真机字符串最宽的 142 定，注释行改成换行而不是裁字。改布局后用 CDP 在顶层文档扫溢出（5 页 × 320/360/417 × 浅/深），别只信 `--headless --screenshot`——它给出过与真实渲染不一致的读数。
- 界面**不联网、不加载任何外部资源**（单文件，样式与脚本都在 `index.html` 里），断网、无 Play 服务的机器一样能开。
- 所有数据都来自一次 root shell 调用：`sh /data/adb/modules/ts-auto-add/webui.sh <命令>`，与命令行排查看到的是同一套判定，界面自己不算状态。可用 `sh webui.sh help` 看全部命令。
- 界面开机先问一次 `contract`（命令层自报契约号与命令清单）：**号对不上就横幅明说「界面与命令层不是同一版」，并把写命令挡在传输层外**（读命令仍放行，好让人看到现场）。需要这条是因为迭代时可以只推 `index.html` 或只推 `webui.sh`，不同版以前只会表现为"某个值怪怪的"。改任何命令的输出形状都要两侧同时把号 +1；电脑上预览可用 `?badapi=99` 验这条确实会响。
- 界面**不做后台轮询**（与模块"事件驱动、不额外耗电"的取向一致）：数字只在进入页面、点「重新读取」或执行写操作后更新。实测本机（XQ-DQ72）`status` 约 0.6 秒、`env` 约 0.77 秒（每次打开只问一次）、`targets` 约 0.33 秒、`apps` / `rules` / `log` 约 0.1~0.12 秒。
- **颜色与深浅一律跟随系统，界面不提供覆盖**（顶栏没有色相滑杆，也没有深浅切换按钮——它们只会让人不小心把界面调得和系统不一样）。深浅以系统实际算出的结果为准（`dumpsys uimode` 的 `mComputedNightMode`，取不到再退回 `mCurUiMode` 的夜间位，最后才是 WebView 的媒体查询）。
- **强调色按四级回退，取到哪一级在概览页「关于 → 取色」里照实写出**：① SystemUI 运行时生成的 Material You overlay `/data/resource-cache/com.android.systemui-accent-*.frro`（**这是系统正在用的那套色**，用户手选颜色时它同样会重新生成，所以比任何 setting 都权威；模块只做「取文件 + base64」，解析在界面里，并用「tonal 阶梯明度必须单调」当自检，不单调就整份丢掉）→ ② `settings get secure theme_custom_color` → ③ 壁纸提取色 `dumpsys wallpaper` 的 `colorValue0` → ④ 平台默认 `system_accent1`。
  界面里 `--primary` 是 `oklch(49% .19×sat hue)`，而系统 `accent1_600` 的明度就在 49% 那一档，所以 `sat = 系统实测C / .19` 即可对上——**彩度按实测比值走，不做审美放大**（放大过的版本色相差不多却完全不像一套东西）。
  需要说清楚的是：跟的是**色相与彩度**，各角色的明度档位仍用界面内置的那一套——模块侧拿不到系统算好的 12 组色调表本身，只能拿到这份 overlay 文件里的 ARGB。
- **字体也跟随系统，走的是「把系统字体文件加载进来」而不是写族名**：Chromium 在 Android 上有自己的字体映射表，**不读** ROM 的 `config_bodyFontFamily` / `fonts_customization.xml`，所以 CSS 里写 `google-sans-flex` 这个名字不会生效、会静默退回 Roboto。现在 `webui.sh env` 从字体注册表里找到该族的 ttf（本机 `/product/fonts/GoogleSansFlex-Regular.ttf`），拷进 `webroot/fonts/sys.ttf`（按大小判重，只搬一次），界面用 `@font-face` 加载并排在字体栈第一位；读不到就退回 `system-ui, sans-serif`。概览「关于 → 字体」会显示走的是哪条路。
- 松紧只由两组令牌控制：`--r-*`（圆角）与 `--sp-*`（留白），加上少量字号档位。**要整体调密度就改这几行**，不要逐条找元素——上一轮"收一档"是逐条改的，结果改完就变成"很挤"。
- 「立即应用一次」是**运行期**写属性，`ro.build.type` 这类已经被 Zygote 读进 Java 静态字段的值不会因此刷新，要彻底生效仍需重启；开机伪装开关只影响下一次开机。
- 想在电脑上预览界面：用任意本地 http 打开 `module/webroot/index.html` 并加 `?demo=1`（内置一份演示数据，不会碰真机）；加 `&seed=RRGGBB` 可模拟系统强调色、`&dark=1` 模拟系统深色、`&tab=rules` 直接进某一页、`&scheme=light|dark` 强制配色（不看系统）。

> 贡献者提示：`webroot/` 是各管理器约定的 WebUI 目录，入口文件名必须是 `index.html`；**样式与脚本不要拆成多个 css/js 文件**——部分管理器用 `file://` 加载且不解析子资源路径。唯一的例外是 `webroot/icons/*.png`：那是运行时导出的图片，读不到时界面会退成首字块，所以缺了也不影响任何功能与可读性。

### 查看运行状态
- **模块描述**：在模块详情页，`description` 字段动态显示：
  ```
  ✅ [后端 | 应用: X | 更新: HH:MM]
  ```
  写入失败时显示 `⚠️ [… 写入失败 …]`，后端冲突停止时显示 `⛔ [模块已停止 …]`。

- **运行日志**：日志同时写 `logcat`（tag `TS-AUTO`）与本地缓冲 `/data/adb/ts_auto.log`（超过 64KB 自动只保留末尾 200 行）。
  最省事的方式是在管理器里点模块的“操作”按钮：`action.sh` 会同步一次并附带打印最近 15 条日志，无需自己 `su`。

  以下命令供手动排查使用。

  设备上读日志**需要 root**（`/data/adb` 为 `0700`；在终端 App 里先 `su`，或用 `su -c '...'` 包裹）：

  ```bash
  tail -n 50 /data/adb/ts_auto.log                     # 本地缓冲，跨重启保留（推荐）
  grep -E '后端|同步|失败|停止' /data/adb/ts_auto.log   # 只看关键行
  logcat -d -s TS-AUTO | tail -n 30                    # 系统日志（重启即清空）
  logcat -s TS-AUTO                                    # 实时跟随（Ctrl+C 退出）
  logcat -c                                            # 先清空系统缓冲再操作，便于观察单次行为
  ```

  电脑上（需已开启 USB 调试；`adb` 读 `logcat` 不需要 root，读 `/data/adb` 需要）：

  ```bash
  adb logcat -s TS-AUTO                                       # 实时查看（不需要 root）
  adb shell su -c 'tail -n 50 /data/adb/ts_auto.log'          # 读本地缓冲（需要 root）
  adb shell su -c 'cat /data/adb/ts_auto.log' > ts_auto_log.txt   # 导出到电脑再慢慢看
  ```

  > 模块只在**开机**与**文件变化**（安装/卸载应用）时写日志，没有事件时不会有输出，属正常现象。缓冲文件的每行都带 `月-日 时:分:秒` 时间戳，不依赖 `logcat` 缓冲是否还在。

### 名单就是目标文件

没有第二份"常驻列表"：**目标文件本身**就是名单，同步只在上面应用增量。

| 后端 | 文件 | 改哪里 |
|------|------|--------|
| TEE Simulator | `/data/adb/teesim/config.json` 的 `profiles.default.apps` | 直接改数组；其它字段与其它 profile 原样保留 |
| Tricky Store / OSS | `/data/adb/tricky_store/target.txt` | 每行一个包名 |
| OhMyKeymint | `/data/misc/keystore/omk/injector.toml` 的 `scoop` | 直接改数组；`config.toml` 与本文件的其它段不碰 |

- **装上自动进、卸载自动出**；你手动加的条目会保留，手动删掉的不会被自动加回来。
- 算法是**快照差分**：`加入 = 本轮已装 − 上次已装`，`删除 = 上次已装 − 本轮已装`，其余（目标文件里的现有条目）原样保留。手动删掉的包仍然装着、但不在"新装"里，所以结构上就不会被回填 —— 没有墓碑文件。想恢复就把它加回文件；应用页里「已排除」的行尾有一个 **+**，点它等价于写回文件；卸载后再装一次也会重新加入。
- **OhMyKeymint 首次接入**：`scoop` 已有内容时沿用现有名单（不批量加入已装），只把当前已装记成基线；之后的新装照常加入。`scoop` 为空时才按其它后端一样加入全部已装 + 三件套。
- **空列表保护**：后台自动同步读到「已装为空、但基线非空」时会放弃这次写入（这更像一次 `pm` 读取失败，而不是真把应用全卸了），并把失败写进模块描述；点界面「立即同步」或用管理器的「操作」按钮会强制按当前已装处理。
- 首次安装后的第一次同步会把谷歌三件套（`com.android.vending` / `com.google.android.gms` / `com.google.android.gsf`）种进去**一次** —— 它们是系统应用，不会被"已装第三方"覆盖到。之后你把它们从名单里删掉，也不会再被加回来。
- 改完文件不用重启：守护进程监听 `packages.list`，下一次应用装卸时会顺带按最新内容重算；想立刻生效就点界面上的「立即同步」。
---

## 📂 数据与配置路径

运行时文件位于**当前后端目录**（TEE Simulator：`/data/adb/teesim/`；Tricky Store：`/data/adb/tricky_store/`；OhMyKeymint：本模块的 `.ts_*` 状态寄生在 OMK 自己的 `/data/adb/omk/`，配置本身在 `/data/misc/keystore/omk/`）：

| 文件 | 说明 |
|------|------|
| `config.json` | TEE Simulator 配置（模块仅维护 `profiles.default.apps`） |
| `target.txt` | Tricky Store / OSS 的应用列表（模块按增量维护：只加新装、只删卸掉的，你手动加的条目保留） |
| `injector.toml` | OhMyKeymint 的名单（模块仅维护 `scoop`；`config.toml` 不碰） |
| `.ts_daemon_pids.list` | 所有后台子进程 PID 列表 |
| `.ts_fingerprint` | 源数据指纹缓存（变更检测用） |
| `.ts_installed_last` | 上次同步看到的「已装第三方」，快照差分的基线 |
| `.ts_ever` | 历次纳入过名单的并集（判断「已排除」用；OhMyKeymint 首次沿用现有 scoop 时不能拿基线当这个集合） |
| `.ts_lock` / `.ts_debounce` / `.ts_tmp` | 运行时锁与临时文件 |

> 日志缓冲不放在后端目录，而是固定在 `/data/adb/ts_auto.log`（权限 `600`，仅 root 可读；超过 64KB 自动只保留末尾 200 行；卸载时自动删除）。
>
> 属性伪装开关同样不放在后端目录，而是 `/data/adb/ts_auto.props_off`：**文件存在 = 已关闭**，由 WebUI 的「属性」页写入/删除，覆盖安装模块不会丢失，卸载时一并清理。
>
> Verified Boot 哈希保存在 `/data/adb/ts_auto.boot_hash`（权限 `600`，内容为 64/128 位十六进制），卸载时一并清理。

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

> **提示**：不需要属性重置时，直接在模块 WebUI 的「属性」页关掉开关即可（写入 `/data/adb/ts_auto.props_off`，下次开机生效，覆盖安装模块不会丢失）；没有 WebUI 入口的话，也可以在 `post-fs-data.sh` 中删除或注释 `apply_resetprop` 调用后重启。
>
> **开机后复核**：`service.sh` 等到 `sys.boot_completed` 后会把这张表**再幂等跑一遍**（已符合的不重复写）。有些机型在 post-fs-data 之后才落锁状态 / AVB 元数据，早段写入会被系统覆盖，这一遍就是兜住它。
>
> **Verified Boot 哈希**：在「属性」页粘贴从 KeyAttestation 等处取到的 `verifiedBootHash`（64 位 = sha256，128 位 = sha512），开机时写进 `ro.boot.vbmeta.digest`，并只补空的 `ro.boot.vbmeta.hash_alg`。它和上面的伪装开关**互相独立**：只要保存了，开关关着也会应用。只用 `resetprop -n` 写本次运行，重启回系统原值；清除只影响下次开机。

---

## 🔄 更新亮点（v2.2.19.5-yuzu）

- **日志双写 + 本地缓冲**：日志除写入 `logcat` 外，另写 `/data/adb/ts_auto.log`（带时间戳，超 64KB 只保留末尾 200 行），解决 `logcat` 环形缓冲被系统刷掉后查不到记录的问题。
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
A：WebUI 需要管理器自己实现入口——原版 Magisk 管理器没有，KernelSU（主线）/ KernelSU Next / SukiSU / SmartPack / APatch 等才有。这种情况下**模块功能完全不受影响**，改用命令行即可：`sh /data/adb/modules/ts-auto-add/action.sh` 同步并打印最近日志，`sh /data/adb/modules/ts-auto-add/webui.sh status` 输出界面用的同一份结构化状态（`webui.sh help` 看全部命令）。若界面能打开但一片空白，通常是管理器的 WebView 版本过旧或禁用了 JavaScript，重新覆盖安装模块可确认 `webroot/` 是否完整。

**Q：界面提示「当前管理器没有提供可用的 exec 桥接」，但我的管理器明明有 WebUI 入口？**  
A：各家注入的桥接对象名与调用形状不一样（KernelSU 主线是 `window.ksu.exec(cmd, optionsJson, 回调函数名)` 的**异步回调**，部分是同步返回 `{errno, stdout}`）。这种情况下界面会直接把扫描结果列出来——扫到了哪些对象、各自有哪些方法，据此就能判断该认谁；把那一屏反馈给维护者即可。

**Q：怎么看模块日志？为什么 logcat 里一会儿就没了？**  
A：日志同时写 `logcat`（tag `TS-AUTO`）与本地缓冲 `/data/adb/ts_auto.log`。`logcat` 的缓冲默认只有几百 KB 且由全系统共用，系统繁忙时旧记录很快被挤掉、重启即清空 —— 这正是“一会儿就没了”的原因；缓冲文件跨重启保留，排查请优先看它（超过 64KB 会自动只保留末尾 200 行）。设备上读这两处**都需要 root**（`/data/adb` 为 `0700`，终端里先 `su`，或用 `su -c '...'`）；电脑上 `adb logcat -s TS-AUTO` 不需要 root，读缓冲文件需要 `adb shell su -c '...'`。最省事的方式是在管理器里点模块的“操作”按钮 —— `action.sh` 会附带打印最近 15 条日志。完整命令与排查步骤见上方「🛠 使用方法 → 查看运行状态」。另外模块只在**开机**与**文件变化**时写日志，没有事件时没有输出属正常现象。

**Q：安装时提示“未找到 inotify 工具”？**  
A：请确认系统是否包含 `inotifywait` 或 `inotifyd`。部分精简 ROM 可能缺失，可尝试安装 Busybox 或更换 ROM（Magisk / KernelSU / APatch 自带的 busybox 会被自动识别）。

**Q：模块描述显示“模块已停止”？**  
A：说明 Tricky Store / TEE Simulator / OhMyKeymint 中有多于一个同时启用。停用或卸载多余的，只留一个后重启即可恢复。

**Q：模块描述显示“写入失败”？**  
A：目标文件不可写（目录只读、文件被占用等），或 OhMyKeymint 的 `injector.toml` 还没生成。检查对应后端目录的权限、先打开一次 OMK 后重试（执行 `action.sh` 或等待下次事件触发）。

**Q：`target.txt` 未按预期更新？**  
A：先看本地缓冲 `tail -n 50 /data/adb/ts_auto.log`（或 `logcat -d -s TS-AUTO`）里的错误信息；确认 `pm` 命令可用；尝试手动执行 `action.sh` 测试。

**Q：OhMyKeymint 的 `injector.toml` 被改动了？**  
A：模块只改 `scoop` 数组，写入前备份到 `/data/adb/omk/injector.toml.bak`；其它段与 `config.toml` 不碰。写入后会写 `/data/adb/omk/restart.injector`，让 OMK 自己重载 injector。

**Q：如何临时禁用后台监听？**  
A：可删除后端目录下的 `.ts_daemon_pids.list` 并重启，或直接卸载模块。

---

## 📝 许可证

本模块遵循 **GPL-3.0** 开源协议，欢迎贡献代码与反馈问题。

---

**版本**：v2.2.19.5-yuzu  
**更新日期**：2026-09-14  
**维护者**：IamCanincan
