# 更新日志 (CHANGELOG)

---

### 未发布（开发中）

#### 新增

* **WebUI 控制台（Material 3 Expressive）**：模块自带 `webroot/index.html`，在支持 WebUI 的管理器里点「打开界面」即可使用。分五页——概览（后端 / 目标文件 / 可写性 / 上次写入 / 监听方式 / 守护进程 / 日志缓冲 / 伪装状态 + 界面自身的桥接信息）、常驻列表（在线编辑 `rules.txt`，实时统计有效包名与注释）、应用（生效列表与已安装第三方对照、搜索、只看未纳入、一键加入常驻）、日志（末尾 30~300 行按级别着色、清空缓冲、可选 5 秒自动刷新）、属性（当前值 / 期望值 / 是否一致）。界面为**单文件、不联网、不引外部库或字体**；配色支持跟随系统 / 浅色 / 深色，并可拖动色相滑杆实时改整套颜色。
* **WebUI 命令层 `webui.sh`**：`status` / `env` / `rules` / `targets` / `apps` / `log` / `clear-log` / `props` / `props-apply` / `props-on` / `props-off` / `save-rules` / `sync`，输出机器可读文本（`key=value` 或 TAB 分隔），复用 `lib/` 的探测与同步逻辑，界面不自行判定任何状态。文本内容一律以 base64 传入并先校验字符集，命令名与参数只参与比较、不拼进 shell。
* **开机属性伪装开关**：`/data/adb/ts_auto.props_off` 存在即表示关闭，`post-fs-data.sh` 据此跳过 `apply_resetprop`；只影响下一次开机，应用列表维护不受影响。覆盖安装模块不丢失，卸载时随其它文件一并清理。
* **只读提取脚本 `backends/teesim_list.awk`**：从 `config.json` 中取出 `profiles.default.apps` 供界面展示，定位方式与 `teesim.awk` 一致（逐级定位失败即不输出）。
* `lib/tools.sh` 新增 `find_base64()`：与 `find_awk` 同样以「实际执行一次解码」来判定可用性，避免只有 busybox 本体、没编译 applet 时被误判为可用。

* **取色跟随系统（Material You 种子色）**：界面色相与彩度由系统强调色推导。种子按 `settings get secure theme_custom_color` → 壁纸提取色（`dumpsys wallpaper` 的 `colorValue0`）→ 内置默认三级回退，取到哪一级在概览页「关于 → 取色」里照实写出（含换算后的 `#RRGGBB`、生效色相与彩度倍率）。深浅以系统实际算出的结果为准（`dumpsys uimode` 的 `mComputedNightMode`，退回 `mCurUiMode` 的夜间位，最后才是 WebView 媒体查询）。种子写法兼容 `#RRGGBB` / `#AARRGGBB` / `0x…` / 裸十六进制 / 十进制 ARGB——纯数字串按位数区分十六进制颜色与十进制整数，否则 `808080` 会被读成 `0x0C5490` 那种深蓝。近中性的种子只跟彩度、不跟色相（色相在此时没有意义）。**跟的是色相与彩度，各角色明度仍用界面内置档位**——模块侧拿不到系统算好的 12 组色调表，只能拿到种子色。

* **色相滑杆与「跟随系统」并存**：拖动即转手动，点「跟随系统」交还；偏好存 `localStorage`，取不到时退化为内存值。

#### 优化

* **`status` 不再重复算数（945ms → 615ms）**：原先 `status` 内部要跑 awk 提取（约 330ms）与 `pm list`（约 200ms）来给出「生效 / 第三方 / 常驻」三个数字，而界面为了展示列表本来就要取 `targets` / `apps` / `rules` 三份完整清单——同一件事做两遍，既慢又可能出现两份对不上的数字。现在 `status` 只报文件与运行状态，数字一律由列表数出来，英雄卡的大数字随列表（约 330ms）出现，不必等 `status`。
* **界面取数与渲染分层**：`loadX` 只写状态、`renderAll` 统一画一次（原先 status 与 env 各自重画英雄卡与三十来行列表）；三份列表合并为一次并发请求、三页共用；并发刷新共用同一个在途请求且只在成功后才记「已加载」（否则第二条链会拿空列表去画）；迟到的响应不再覆盖新一次的渲染。
* **交互细节**：搜索输入防抖 140ms（原先每敲一个字符重建两百多行）；生效集合建一次用到底；日志自动刷新走静默路径、不弹「读取中」遮罩，且内容没变就不重建节点、用户翻上去看历史时不拽回底部；主行动按钮改用 primary 角色（tertiary 是 hue+130 的对比色，跟随系统取色时可能正好是红色，会把「立即同步」画得像危险操作）。
* **属性期望值表单点维护**：从 `apply_resetprop` 的内联字符串抽成 `props_expect_pairs()` / `props_expect_rules()`，写入端与界面展示端共用同一份，不会再各写一遍后走偏。
* **界面取值方式按实测选定**：本机（XQ-DQ72，每次 fork 约 20~90ms）实测三种读法——逐个 `getprop` 17 项 277ms、一次全量 + `grep -F -f` 过滤 1692ms、一次全量 + 参数展开查表 228487ms；故采用逐个 `getprop`。`status` 与 `env` 拆成两条命令（后者含 busybox / inotify 探测与系统取色，只在打开界面时问一次）。这两步把 `status` 从 2452ms 降到约 950ms，再由上一条「`status` 不再重复算数」降到约 615ms。
* **WebUI 写操作的等锁时间**：界面侧等锁只等 6 秒（守护进程仍为 15 秒），超时提示「守护进程正在写入」——WebView 里的 `exec` 是同步的，等满 15 秒看起来就是界面卡死。
* `.gitattributes` 为 `*.html` / `*.css` / `*.js` 固定 LF。

#### 修复

* **改名替换 `rules.txt` 之后不再自动同步**：inotify 的监视点绑的是 inode，而「写临时文件再改名覆盖」正是 `vim`、`sed -i` 与本模块 WebUI 原子保存的写法。替换后旧 inode 已被 unlink，挂在它上面的监视不再上报任何事件；又因为守护进程同时还挂着 `/data/system`，`inotifyd` 的「所有监视目标都失效才退出」条件不成立，也就不会被外层循环重启 —— 表现是改了常驻列表不再同步，且只有重启才恢复。现在监听挂在**目录**上（掩码 `cwmy`），文件级监视保留作就地改写的兜底。`/data/system` 同理，`packages.list` 也是 PackageManager 用临时文件改名重写的。
  * 事件过滤从裸子串改成整字段匹配：`sed -i` 的临时文件叫 `rules.txtXXXXXX`，子串匹配会把它当成一次变更（实测一次 `sed -i` 产生的 8 条命中里 3 条是这种误触发）。
  * 掩码里 `m` 与 `y` 同时给：toybox 的 `--help` 写「m 移入、y 移出」，busybox 恰好相反，而**实测两家在「改名覆盖」时上报的都是 `y`** —— help 文本不可信，两个都带上就不必赌设备上是哪一个。
  * `inotifywait` 分支同样改挂目录并补 `close_write` / `moveto`。本机没有 `inotifywait` 可测（只有 `inotifyd`），因此加了一次 1 秒的实跑探测：参数不被接受就退回旧事件集并写警告，避免"不认识参数 → 监听进程 3 秒一轮空转"。
  * 真机逐场景验证（每次操作经 2 秒防抖后应且只应触发一次同步）：`mv` 改名替换 +1、替换之后就地追加 +1、同目录无关文件 +0、`sed -i` +1、再次 `mv` +1；原始事件每次 2~4 条（`c` / `w` / `y` / `x`），由既有防抖合并。

#### 兼容范围

* 界面依赖管理器提供的 root shell 桥接（`window.kernelsu` / `window.apatch` / `window.Magisk` / `window.bridge` 任一）；无桥接时界面显示明确提示并给出等价的 `webui.sh` 命令，模块自身行为完全不变。
* 界面不做后台轮询：数据只在进入页面、点「重新读取」或执行写操作后各取一次。
* 监听目标从「`rules.txt` 文件」改为「其所在目录」：`/data/adb/teesim` 与 `/data/adb/tricky_store` 目录里的其它文件写入会产生少量事件，但都按文件名过滤掉、不触发同步；实测该目录 10 秒内 4 条事件、命中过滤 0 条。

---

### v2.2.19.5-yuzu - 2026-09-14

#### 新增

* **本地日志缓冲**：日志除写入 `logcat`（tag `TS-AUTO`）外，另写 `/data/adb/ts_auto.log`，每行带 `月-日 时:分:秒` 时间戳。文件权限 `600`、位于 `0700` 的 `/data/adb` 下，仅 root 可读；超过 64KB 时自动只保留末尾 200 行（先写临时文件、成功后再覆盖），不会无限增长；缓冲不可写时静默退化为只写 `logcat`，不影响同步流程。

#### 优化

* **日志读取方式**：管理器的“操作”按钮优先展示缓冲内容（缓冲不存在时回退 `logcat`），并给出完整日志路径；安装完成提示与守护进程启动日志中标注日志路径。
* **换行符统一为 LF**：新增 `.gitattributes`，对 `*.sh` / `*.awk` / `*.prop` / `*.json` / `*.md` / `*.yml` 等固定 LF，避免 CRLF 导致 Android 上 shebang 解析失败（`/system/bin/sh^M: not found`）；`LICENSE` 一并由 CRLF 转为 LF。
* **CI 增加语法检查**：构建前对入口脚本、`lib/`、`backends/` 与 `META-INF` 内的脚本执行 `sh -n`，语法不通过的代码不进包。
* **仓库整理**：`.gitignore` 由 111 行精简为 26 行，并修正原先会误忽略 `module/META-INF/` 下新增文件的规则；README 增加 CI / Release / License 徽章与下载入口；GitHub 提交历史由 281 个提交（其中 236 个 merge）压缩为单一提交，各历史版本仍可通过 tag 查看。

#### 修复

* 本版无新增缺陷修复，沿用 `v2.2.19.4-yuzu` 的四项修复（常驻列表末行粘连、写入失败被误报成功、inotify 探测方式错误、`inotifyd` 监听失效）。

#### 兼容范围

* Tricky Store / Tricky Store OSS / TEE Simulator（后两者互斥；同时启用时模块停止运行）。

---

### v2.2.19.4-yuzu - 2026-09-13

#### 修复

* **常驻列表末行无换行导致粘连**：同步前自动补齐 `rules.txt` 末行换行，避免用 `echo 包名 >> rules.txt` 追加时与上一行拼成一行；同时清除文件开头的 UTF-8 BOM（会让首个包名带上不可见前缀）。
* **Tricky Store 写入失败被误报成功**：`target.txt` 替换失败（目录只读、文件被占用等）时如实返回失败，不再显示为正常状态。
* **inotify 探测方式错误**：原先对 busybox 候选执行的是 `busybox --help`（不含 applet 帮助），导致仅有 busybox 的设备被误判为“无 inotify 工具”而直接退出；现改为实际执行 applet 的 `--help`。
* **inotifyd 监听失效**：`inotifyd PROG FILE:mask` 是把 `PROG` 当程序执行，原来传 `-` 不会产生任何输出；现改用 `echo` 把事件打印给管道读取。

#### 新增

* **常驻列表支持注释**：`rules.txt` 支持以 `#` 开头的中文注释与空行，默认内容自带说明注释。
* **状态写入模块描述**：写入失败显示 `⚠️ [… 写入失败 …]`，后端冲突显示 `⛔ [模块已停止 …]`，无需查日志即可在管理器界面看到原因。

#### 优化

* **后端判定改为按模块 id**：`/data/adb/modules/tricky_store`（Tricky Store / OSS）与 `/data/adb/modules/teesim`（TEE Simulator）；带 `disable` 标记的模块不计入。两者同时启用时模块直接停止，不再做优先级选择；残留的 teesim 配置也不再劫持后端选择。
* **日志只写系统日志**：不再落地文件，改为三行 `logger` 调用（tag `TS-AUTO`）；查看 `logcat -d -s TS-AUTO`。
* **界面与日志加 emoji**：安装过程、手动同步、日志与模块描述统一用 ✅ / ⚠️ / ❌ / ⛔ 标记状态，便于快速分辨。

#### 兼容范围

* Tricky Store / Tricky Store OSS / TEE Simulator（后两者互斥；同时启用时模块停止运行）。

---

### v2.1.08.3-yuzu - 2026-09-10

#### 新增

* **TEE Simulator 后端支持**：自动探测 `/data/adb/teesim/config.json`；存在时仅替换 `profiles.default.apps`，其余字段与其它 profile 原样保留（定点替换脚本 `backends/teesim.awk`，无法定位数组时放弃写入）。TEE Simulator 与 Tricky Store 互斥，两者同时存在时优先 TEE Simulator；常驻列表随之位于 `/data/adb/teesim/rules.txt`。

#### 优化

* **模块结构分类**：文件分为「入口脚本（根目录）+ `lib/` 共享库 + `backends/` 后端实现」；后端实现各自独立成文件（`backends/tricky.sh` 写 `target.txt`、`backends/teesim.awk` 改 `config.json`），`lib/common.sh` 只保留通用逻辑。
* **代码规范化**：统一中文注释与函数文档格式（说明 / 用法 / 返回码）；日志上限与锁超时提取为常量；`sync_teesim_config` 收敛为单一出口，减少重复清理语句。
* **兼容范围**：Tricky Store / Tricky Store OSS / TEE Simulator（后两者互斥，TEE Simulator 优先）。

---

### v2.0.97.2-yuzu - 2026-09-08

#### 移除

* **安全补丁功能**：完全移除对 `security_patch.txt` 的读取、生成与修改，以及月份缓存（`.last_month`）与后台联网抓取补丁的逻辑，模块不再触碰安全补丁配置。
* **周期联网任务**：移除后台定时 ping + 拉取补丁的任务，杜绝后台网络轮询，显著降低待机功耗。

#### 修复

* **同步触发过于频繁**：新增源数据指纹（`packages.list` 包名集合 + `rules.txt`）变更检测，仅在真正发生应用安装/卸载或常驻列表变化时才执行同步，避免系统频繁改写 `packages.list` 造成重复同步与日志刷屏。

#### 优化

* **移除系统/用户区分**：`taa_sys.txt` 更名为 `rules.txt`（常驻列表，升级时自动迁移）；`target.txt` 仍为 rules.txt + 已安装第三方应用；描述与日志不再区分“系统应用/用户应用”，只显示总应用数。
* **属性伪装提前到开机早期**：`apply_resetprop` 移至 `post-fs-data.sh`（Zygote 启动前）执行，修复 `ro.build.type`（`userdebug` → `user`）等属性在 Java `Build.TYPE` 静态字段中已固化、后设无效的问题。
* **代码结构精简**：`common.sh` 统一提供日志、锁、常驻列表、应用列表同步、描述更新、inotify 探测与属性伪装函数，`action.sh` / `service.sh` / `customize.sh` / `post-fs-data.sh` 复用。
* **省电与稳定**：应用列表同步增加内容比对，仅在数据变化时落盘；两个 inotify 监听合并为单一进程，减少常驻进程数量。
* **日志路径与权限**：日志由普通应用可读的 `/data/local/tmp/ts_auto.log` 迁移至 root 专属的 `/data/adb/ts_auto.log`，并强制 `600` 权限，降低被检测应用读取的风险。
* **兼容范围收敛**：仅面向 Tricky Store / Tricky Store OSS（纯包名列表式 `target.txt`）。

---

### v1.9.86.1-yuzu - 2026-07-08

#### 新增

* **公共函数库**：新增 `common.sh`，集中管理日志、锁、日期处理、网络检测、inotify 工具探测、补丁更新核心及模块描述更新等通用逻辑，大幅减少重复代码，提高可维护性。
* **双 inotify 模式支持**：自动检测系统可用的 inotify 工具（`inotifywait` 或 `inotifyd`），并优先采用兼容模式，解决了部分精简 ROM 缺少 `inotifyd` 导致监听失效的问题。
* **事件防抖机制**：引入防抖锁（`.ts_debounce`），将短时内多次触发合并为一次同步，避免频繁写入文件，降低系统负载。
* **系统白名单分离**：新增 `taa_sys.txt` 存放需永久保留的包名（默认三个 Google 核心应用），与第三方用户应用分开管理，便于用户自定义维护。
* **本地日志记录**：所有运行日志同时写入 `/data/local/tmp/ts_auto.log`，方便离线排查问题，同时保留系统日志输出。
* **网络连通性检测**：在补丁更新前先检测网络可用性，若不可用则延迟重试，避免无效请求，提升稳定性。
* **进程统一管理**：所有守护子进程的 PID 统一记录至 `.ts_daemon_pids.list`，卸载时能一次性全部终止，不留残留。

#### 修复

* **监控组件兼容性**：解决部分设备因缺乏 `inotifyd` 导致后台监听完全失效的问题，现在若 `inotifywait` 可用则自动切换。
* **并发冲突处理**：完善锁机制（`acquire_lock`）超时逻辑，避免因异常退出造成永久死锁。
* **补丁获取失败回退**：在线获取补丁失败时，能够可靠地回退至系统日期，确保配置始终有效。
* **安装脚本错误处理**：增加对 `common.sh` 加载失败的检测，防止安装进程在不完整状态下继续。

#### 优化

* **代码架构重构**：将核心功能抽离至 `common.sh`，使 `service.sh` 和 `action.sh` 更专注于调度逻辑，代码复用率提高约 60%。
* **补丁获取源调整**：切换至 `source.android.com` 域名，并增加重试机制（最多 2 次），提高网络获取成功率。
* **补丁更新频率优化**：日常检查间隔调整为 6 小时（原 12 小时），网络不通时自动延长至 12 小时，平衡实时性与资源消耗。
* **模块描述增强**：`description` 字段现在区分显示“系统应用数”与“用户应用数”，信息更细致，便于状态评估。
* **属性注入脚本精简**：`taa_resetprop.sh` 移除 MIUI、Realme 等厂商特定属性，仅保留通用核心属性，增强跨设备兼容性，降低副作用风险。
* **应用列表生成性能**：合并文件时采用管道流式处理，减少中间临时文件操作，提升执行效率。
* **日志内容规范化**：所有日志使用统一格式，包含时间戳和级别标识，便于筛选和分析。

#### 移除

* **冗余的厂商属性**：在 `taa_resetprop.sh` 中删除 MIUI、Realme 专用属性（如 `ro.secureboot.lockstate`、`ro.boot.realmebootstate` 等），避免在不支持的设备上引起意外行为。

---

### v1.8.75.9-yuzu - 2026-07-06

#### 优化

* **安全补丁配置统一**：`security_patch.txt` 中的 `system` 字段值由固定 `prop` 改为动态日期 `$FINAL_DATE`，与 `boot`、`vendor` 保持一致，避免配置不匹配。
* **应用列表生成健壮性**：在 `do_sync()` 中增加空行过滤（`sed '/^$/d'`），防止无第三方应用时 `target.txt` 出现空白行，确保行数统计准确。

---

### v1.7.64.8-yuzu - 2026-07-06

#### 新增

* **补丁更新进程 PID 管理**：新增 `.ts_patch.pid` 文件记录安全补丁后台更新进程的 PID，解决升级或重装时旧进程残留问题。
* **`action.sh` 手动工具增强**：
  * 引入互斥锁机制（`LOCK_DIR`），避免与后台守护进程同时操作冲突。
  * 增加 `--force` / `-f` 命令行参数，支持强制清除月份缓存并重新在线获取安全补丁日期。
  * 保留 `.last_month` 月份缓存，仅在月份变更或强制模式下发起网络请求，减少不必要流量。
* **`customize.sh` 安装脚本增强**：
  * 安装前清理新增的 `.ts_patch.pid` 文件。
  * 部署 `taa_resetprop.sh` 前检查文件是否存在，避免因缺失导致报错。

#### 修复

* **Shell 兼容性修复**：将 `taa_resetprop.sh` 中的 Bash 专有语法 `[[ ... = *...* ]]` 改为 POSIX 兼容的 `case` 匹配，确保在 Android 默认 shell（mksh / ash）下正常运行。
* **空值变量引用修复**：为 `check_reset_prop` 函数中的所有变量添加双引号，避免空值导致语法错误。
* **并发锁死锁风险**：为 `acquire_lock` 增加 30 秒超时，超时后强制删除残留锁目录，防止进程意外退出导致永久死锁。
* **网络请求被拒**：为 `fetch_online_date` 中的 curl / wget 添加 `User-Agent` 头，模拟浏览器访问，降低被服务器拒绝的可能。
* **卸载脚本不完整**：`uninstall.sh` 增加对 `.ts_patch.pid` 进程的终止和文件删除，确保完全卸载无残留。

#### 优化

* **安全补丁在线获取**：`update_security_patch` 与 `action.sh` 现支持循环尝试多个备用 URL，提高网络获取成功率。
* **注释客观化**：全面梳理所有脚本注释，使用中性技术描述，移除主观修饰词，提升可读性和维护性。
* **安装日志细化**：`customize.sh` 增加 `taa_resetprop.sh` 部署状态提示，安装过程更透明。

---

### v1.6.53.7-yuzu - 2026-07-06

#### 新增

* **简介动态托管机制**：彻底弃用模块原有的静态简介，改为由 `service.sh` 与 `action.sh` 统一接管，实现运行状态数据的实时全覆盖。
* **状态看板化**：简介行更新为客观运行状态展示：`[应用数: X | 补丁: YYYY-MM-05 | 更新: HH:MM]`。
* **架构一致性**：统一了后台守护服务与手动诊断工具的数据源，确保界面显示在任何触发场景下均保持高度一致。

---

### v1.5.42.6-yuzu - 2026-07-05

#### 新增

* **内置安全属性伪装**：新增 `taa_resetprop.sh`，实现开机 boot 状态锁定与调试标记清除。
* **系统状态擦除**：自动重置 `vbmeta.device_state` 为 `locked`，`verifiedbootstate` 为 `green` 等关键状态。
* **设备指纹隐藏**：强制重置 `ro.debuggable`、`ro.build.type` 及 `tags` 属性。
* **深度清理联动**：卸载时自动移除所有相关运行脚本，确保系统环境零残留。

---

### v1.4.31.5-yuzu - 2026-07-03

#### 新增

* 首个稳定版发布。
* 基于 inotifyd 的后台守护，实时监听 `/data/system/packages.list` 变化。
* 自动维护 `/data/adb/tricky_store/target.txt`，固定保留谷歌核心三件套。
* 兼容 Magisk、KernelSU 及 APatch 环境。

---

**注**：版本号按从新到旧排列，建议所有用户更新至最新版本以获得最佳体验。