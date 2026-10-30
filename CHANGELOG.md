# 更新日志 (CHANGELOG)

---

### 未发布（开发中）

#### 新增

* **底栏定回四格：主页 / 后端 / 日志 / 设置**（用户拍板）。分工按"这一格回答的是什么问题"：主页 = 在不在跑（状态条 + 三家互斥矩阵 + 自动同步卡），后端 = 这一家的配置文件怎么改（名单 + 配置面 + keybox），日志 = 出了什么事，设置 = 与后端无关的模块自身开关（系统属性 + Verified Boot + 外观 + 界面自检）。两次反复的结论都留在源码注释里：自动同步**始终不占位格**（附加功能占一格 = 摆到主体前面），「伪装」也不再单列 —— 一格只放一个开关太薄。
  * **落地页换了，取数跟着换**：主页只问 `base + backend`，不再为名单 fork `targets/apps/target-meta/excluded` —— 打开模块先回答"在不在跑"，配置面的那批命令等点进【后端】再问。后端格反过来白得一个修正：进格时 `backend-info` 已在主页取过，按家取的配置数据不再拿空值猜成 omk。
  * **顺带抓出一个一直没炸的雷**：`screens.js` 里六处重画写的是没 import 的 `draw()` —— 产物能跑只是 esbuild 把三个模块摊平进同一个 IIFE 作用域，源码层它是自由变量；换打包器或哪天撞名就是当场 ReferenceError，而台架只驱动切页、点不到那几颗按钮，所以它一路绿。改成照 `onToast`/`onReload` 的套路注册回调（`onDraw`），并新增 `tools/module-scope-check.mjs` 守这一整类：专查"用了兄弟模块的名字却没 import"（判据收窄到**我们自己的三个源文件互相之间**，浏览器全局与库组件不误报）。它第一版自己就踩了两个坑：import 的模块路径被字符串剥离替换成 `''` 后，要求 `[^'"]+` 会让整条 import 匹配不上、把 app.js 里每个 import 来的名字都误报；`catch (e)` 的形参不进声明集，`e` 也被误报 —— 都修了，并拿真雷（`draw`）当正对照。
  * **新断言全部过变异**：`node tools/mutate-ui-shape.cjs` 八条刀（自动同步挪出主页 / 主页塞 setTimeout / renderTheme 挪进主页 / 日志设置换序 / propsCards 不挂 / redraw 退回自由变量（这把同时要 module-scope-check 响）/ renderSettings 摘掉 export / keybox 卡挪走），每条要求**点名的那一条**断言响，不是"退码非 0 就行"；跑完逐字节还原。变异台第一版把 8 条真变异全读成"没响" —— ui-shape 的失败行前缀是"两个空格 + ✗"，按列 0 匹配 `✗` 一条都对不上。
  * 台架与文档同步：`verify.mjs` 的 `PAGES` 改四格、逐后端 / 读失败驱动改去 index 1（它们要的块在【后端】格）、互斥矩阵那屏留在主页；`replay-check.mjs` 冷启动判据从"文本长度 > 200"改成"长出三张卡"（md-list-item 的标题都写在**属性**里，textContent 数不到，落地页一换那条阈值就是碰运气），桥接自检那行改到【设置】格去读，主页钉 `生效 N 条`（来自真机 backend-info），主页/后端/设置三格都量二次进入耗时；README 界面节整段重写（顺带修掉两处更早的过期描述：`@material/web 2.5.0`、"图形语言是内联 SVG"）。
  * 清掉上一版结构留下的死代码：`app.css` 的英雄数字区块（`.hero*`/`.recent`/`.warn-card`/`.sk`/`@keyframes pulse`，MD3E 换版后就没有人用了）、`bridge.js` 状态对象里同样没人读的 `appsSrc`/`selectMode`/`selected`/`targetSet`/`targetBaseSet`/`logSig`（多选与撤销那套界面退役时留下的）。

* **模块改名 KeyLens**：`name=TS-AUTO-ADD` → `KeyLens`，`id=ts-auto-add` → `keylens`。按"凡是代表老模块的地方都换"执行，动了约 **500 处**：`TAA_*`/`_taa_*` 标识符 → `KL_*`/`_kl_*`（`KL_DIR` 一项就 108 处），后端目录里的运行时文件 `.ts_lock` / `.ts_ever` / `.ts_fingerprint` / `.ts_installed_last` / `.ts_daemon_pids` … 全部 → `.kl_*`，`/data/adb/ts_auto.*` → `/data/adb/keylens.*`，临时文件后缀 `.ts_auto.$$` → `.keylens.$$`，logcat tag `TS-AUTO` → `KeyLens`，界面标题与 README 的日志/路径段同步。
  * **老名字只剩三处必要地方**：① 清理老版本遗留在用户机器上的文件名（`taa_sys.txt`、`service.d/taa_resetprop.sh`、`/data/adb/ts_auto.*`）—— 按旧名才找得到；② 迁移函数的源路径与它扫的旧 glob；③ 更新说明与 GitHub 仓库 URL（仓库改名由人做，`zipUrl`/徽章等它改完再动）。
  * **不靠人眼保证不漏**：`node tools/name-residue-check.mjs` 扫全部 git 跟踪文件，白名单外的旧名一律退非 0。这道闸第一版把 `ts_auto` 全局放行，于是 README 里那些已经过期的 `/data/adb/ts_auto.log` 路径被一起放过 —— 改成**按文件豁免**（只有 core.sh / uninstall.sh / customize.sh 这类"必须按旧名找东西"的文件能用旧名），当场抓出 28 处。它自己也带正对照：往 `lib/props.sh` 塞一行旧锁名 → 闸门必须响且点名文件，跑完逐字节还原（在 `tests/legacy-migrate.sh` 里）。
  * **改名把运行时状态文件名也换了，所以必须有迁移**：`ts_auto.props_off` 存在 = 用户关掉了属性伪装，`.ts_installed_last` 是快照差分的基线，`.ts_ever` 决定"手动删掉的包不再回来" —— 丢了就是静默改行为。新增 `migrate_legacy_paths`（`lib/core.sh`），在 post-fs-data / service / webui 三个入口各调一次：只在新名不存在时 `mv`，所以幂等、也不会覆盖用户在新路径上写过的东西；按目录扫 `.ts_*`，不依赖 `detect_backend` 的顺序。`tests/legacy-migrate.sh` 抽的是真函数，钉住"搬到位 / 不覆盖已有新值 / 反复调用 no-op / 缺目录退 0 / 不带点的同名文件不被误搬"。
  * **id 变了意味着必须重刷**：管理器按目录名认模块，`/data/adb/modules/ts-auto-add` 与 `keylens` 并存 = 两套 `service.sh` 同时跑、各自监听、各自写同一份后端配置。README 新增一节写明"先卸旧再刷新"，以及**旧 id 的装机收不到自动更新**（`updateJson` 按 id 走）。本轮**没有**往设备推这一版：推过去就是在那台机器上造第二个模块目录。
  * 顺带修掉 README 一句现在说反了的话："本模块**不再修改安全补丁**" —— 新版界面三家都能改补丁级别（Tricky 写 `security_patch.txt`、TEESim 写 profile 的 `patchLevel`、OMK 写 `[trust]`）。
  * `tools/rename-keylens.cjs` 留下做重放：这种规模的机械改名，手改的结果一定是"改了我记得的那几处"。
  * 回放台架同轮补了一道**采集自检**：它曾经把 Git Bash 改写路径造成的满屏 shell 报错当成"真包名画到屏上"判全绿。现在必须先证明 16 条读命令都拿到该有的键、targets 128 条形状正常，才允许去驱动界面。

* **产物从 894 KB 降到 761 KB：同一份图标字体不再落三遍**。库里 `Outlined / Rounded / Sharp` 三个族名的 `@font-face` **指向同一个 `material-symbols-rounded.woff2`**（在 `dist/tokens.min.css` 里逐条看过），整份内联就是 50 KB 字节 ×3。现在只留 Rounded 那一条：组件内部一律写 `var(--md-icon-font-family, 'Material Symbols Rounded', …)`，Rounded 在链首；库里唯一把 Outlined 放第一位的是 `md-fab`，而它不在本界面的 import 列表里。
  * 守这个前提的是**运行时量测**，不是静态扫：`verify.mjs` 现在逐个元素取 computed `font-family` 的第一个族名，查它有没有对应 `@font-face`。静态扫试过，会被库里那两条**没人用的工具类规则**（`.material-symbols-outlined{…}` / `-sharp{…}`）绊倒，判成假阳性 —— 死规则不渲染，就不该判死。
  * 变异验过（`node tools/md3e-build/mutate-fontface-gate.cjs`）：把唯一那份 Rounded 也删掉 → 台架退码 1 并报「落空: Material Symbols Rounded×13」，同时正对照也塌（`home` 从 24px 变 65px）；还原后重新构建复跑回绿，并逐字节确认 `build.mjs` 回到原样。
  * 以后真 import 了 `md-fab`，这条会在台架响，而不是等图标在手机上变成字面词才发现。

* **`THIRD_PARTY_NOTICES.md` 之前整份是假的，按产物实测重写**。它写着 `@material/web 2.5.0` + `lit` + `tslib`，还说"Material Symbols 图标字体**没有**包含，界面用自己的内联 SVG" —— 换版之后这两句**正好都反了**：上机的是 `@materialwebunofficial/md3e-web` 1.0.14（`dependencies: {}`，没有 lit），而符号字体确实内联了。
  * 现在逐条对着产物量：`@font-face` 三条→一条、每条约 50 KB、`data:font/woff2` 出现 1 次、Roboto 的 `@font-face` 全部剥掉（库带五个 Roboto 文件，SIL OFL；管理器的 WebView 里网页字体不生效，实测退回系统字体）。旧包（`@material/web` / `lit` / `tslib`）挪到"上一版产物"一段，`tools/mwc-build/` 标成历史目录。
  * 补了 `md3e-web` 自己 `NOTICE` 的实质：它是 M3 / M3 Expressive 规范的社区非官方适配，token 与色角色源自 Google LLC（Apache-2.0），部分值派生自 AOSP AndroidX Compose Material 3。

* **界面换版：`module/webroot/index.html` 现在是 `webui/src` 的 MD3E 产物**（894 KB，MD3E Web 2.5 组件 + 内联符号字体子集，零网络依赖）。同一提交里把只对旧产物有效的三个护栏退役：旧 `tests/ui-shape.js`（79 条 grep `var KV_REQUIRED` / `.grp{}` / `id="p-func"` 的断言，新产物是 ESM 压缩过的，这些锚点全不存在）、`tests/ui-font.js`、旧台架 `tools/ui-cdp-check.mjs`；并把 `tests/ui-next-shape.js` **改名成 `tests/ui-shape.js`** —— 换版之后还叫 "next" 是个谎。
  * 顺序是早就定过的："换产物的那一个提交里同时退役旧的、提升新的，不留空窗"。反过来做会留下一个**绿但什么都不测**的套件：实测把新版直接 `--ship` 到旧护栏还在的位置，`ui-shape` 在第一条抽取就中止，79 条断言一条都没跑却仍然退 0。
  * `build.mjs` 改成 `--ship` 时**两条产物一起写**（`webui/dist/index.html` 与 `module/webroot/index.html`），`--check` 两条都比。以前 `--ship` 只写 webroot，于是 dist 停在上一版，而 `verify.mjs` 默认读的正是 dist —— 台架会在一份过期产物上判"全绿"。
  * CI 改成**循环跑全套**：`tests/*.sh` 一个不漏、五个静态闸门一个不漏。以前的 step 清单是手抄的，后来新增的十个套子（keybox-shape / patch-keywords / omk-apply-scope / teesim-overrides-write / tee-status-read / payload-last-field / omk-validation / teesim-profiles / backend-edit-scope / config-write）根本没进 CI —— 本地全绿、CI 只跑其中一半，这种"绿"最坏。自检单独成 job：runner 的 awk 是 mawk，与本机 gawk、设备 toybox awk 三家可能有差异，真差异要看得见，但不该因此把刷机包卡住不发。
  * CI 触发路径从 `module/**` 扩到 `module/** webui/** tools/** tests/**` —— 改了界面源码却不动 webroot 的情况，旧配置压根不会跑。
  * 自报缺口：CI **不重建产物**（要装 npm 依赖），所以"产物与源码同版"这条只能靠本地 `build.mjs --check` 加 `check-artifact` 的"每个源码文件都从入口可达"来兜。CI 里加了一个 step 把这句话印出来，免得以后误以为 CI 查过。

* **KV 形状对账闸：界面读的那个键，命令层真的会输出吗** —— `node tools/kv-shape-check.mjs`（纯静态，CI 可跑，不需要设备）。三份真源交叉比：`webui.sh` 里 `kv <键>` 的字面量 + `backends/*.awk` 里 `print "键="` 的字面量 = 命令层实际会输出的键集；再拿①界面从 parseKV 对象上读的每个 `x.<键>`（别名只在该变量声明所在的那段函数里有效）、②`KV_REQUIRED` 要求的每个键、③**台架假数据里的每个键**去对。任何一方出现命令层从没输出过的名字就退非 0。
  * 为什么要这么绕：`tee_status` 那次是**假数据与代码互相自证** —— 我按想象的键名写了 fixture，代码也按同一个想象读，两边一起错，逐页驱动看不出来。"假数据里有、命令层从不输出"这一条就是专门用来打断自证的。
  * 三处变异各验一次（界面键名改回小驼峰 / 假数据跟着改 / `KV_REQUIRED` 编一个不存在的键）→ 三次都退非 0 且点名对应那条：`node tools/mutate-kv-shape.cjs`。
  * 写这个闸自己踩到的两个坑也记在这儿：① 别名列表为空时 `(?:S\.env|)` 会留下**空分支**，空分支匹配一切，第一版因此报出 40 多条"界面读了 S.env.createElement"；② 右边界原来取"下一个常量的位置"，而 `WRITE_CMDS` 定义在 `KV_REQUIRED` **前面**，于是切到文件末尾，把 `S` 自己的字段（`tab:'over'`）当成要求键报假警。

* **验收台架改成"逐后端各跑一遍"** —— `node tools/md3e-build/verify.mjs`。假数据按 `?backend=tricky|teesim|omk` 切整套路径与条目语法（路径取自 `lib/core.sh:7-17`，显示名取自 `backend_name()`，条目形状按各家的 awk 分类逻辑生成），每家的块要画出**只有真读到那个键才会出现的值**才判过；再加一趟 `?fail=targets`，断言"读不到"报成错误行而不是空态。
  * 以前只跑默认那一家（omk），Tricky/TEESim 的分支等于没测过 —— 这次两处真 bug 都藏在那两条没测过的分支里。
  * 台架自身的两条变异由 `tools/md3e-build/mutate-verify.mjs` 代跑（改源码 → 重新构建 → 跑 verify → 逐字节还原 → 再构建再跑一遍确认回绿），不用手动备份。
  * `check-artifact.mjs` 顺手改两处：默认查**候选**产物 `webui/dist/index.html`（新版还没换掉 `webroot/` 里的旧界面，之前它一直拿旧产物报"3 项不通过"），字节门槛用 `statSync().size` 而不是 `html.length` —— 后者是 UTF-16 码元数，904 KB 的文件量出 347"KB"，看着像被截断。

#### 修复

* **行首加彩色圆底图标，照系统设置的样子**（用户给了 Android 16 设置的截图：应做成类似这种的）。功能菜单五行与三家互斥矩阵三行、自动同步卡的两行，行首都换成 **40px 彩色圆底 + 图标** —— 底/前景用 MD3 的 tonal 容器色三组轮转（primary/secondary/tertiary-container），前两组会跟着动态配色重着色，所以圆底的颜色也是"这台机器自己的"。配对按行固定，不用全局序号 —— 重画顺序一变，同一行的颜色就换。名单里的应用图标本来就是圆形贴图，与圆底同语言。
  * 台架 37 项 + 真机回放 27 项全绿后截图逐张看过：菜单、矩阵、主页英雄卡在暗色下的层次与参考图对得上。

* **列表行之间加呼吸缝**（用户反馈：板块之间贴得太近，一点缝隙都没有）。量出来的真相：卡片与卡片之间本来就有 16px，**真正的元凶是卡里的列表行 —— 行与行 0px 堆叠**，每行又各自是一块带底色的圆角面，深色下整卡的行糊成一条。给 `#view` 里的 `md-list-item` 加 8px 的 margin（末行不加），每行的圆角终于露出来。
  * 中间踩了个值得记的坑：先在 `md-list` 上设 `display:flex; gap:8px`，computed 值明明是 `flex/8px`，布局**纹丝不动** —— md-list 的子项由它 shadow 里的容器排版，宿主的 flex 根本不参与。margin 落在子项上，哪儿都生效；探针（`_harness/list-probe.mjs`）逐行量过 rect：407→415、503→511，8px 到位。
  * 台架全绿后截图逐张看过：矩阵三行、名单二级页（129 条真机名单，每行一个独立圆角块）、属性对照，深浅两态的层次都立得住。

* **撤掉"本模块附加"的强调 + 界面润色一轮**（用户反馈：没必要这么强调、界面太简陋）。
  * **强调下屏**：菜单项与卡标题里的「· 本模块附加」全部拿掉 —— 定位说明住在源码注释里，不画在用户脸上；`ui-shape` 反向钉住"剥掉注释后源码字符串里不许再出现这五个字"。
  * **主页状态条 → 英雄卡**：原来是四段小字用 `·` 连成一行，"在不在跑、跑的是谁"要凑近读；现在是状态芯片 + **大字后端名**（headline-small 档）+ 三个小统计（版本 / 生效名单 / 属性伪装开关），小标签 + 16px 数值、`tabular-nums`。旧 `.strip-*` 样式随之退役。
  * **菜单与矩阵补图标**：功能菜单五行各配 leading 图标（group/tune/refresh/https/verified，全部在 257 连字子集内，icon-gate 构建时拦）；三家互斥矩阵的行也带上各家的图标（label/verified/extension）。台上截图逐张看过：暗色下英雄卡、菜单、矩阵层次都立得住。
  * 台架同步：主页/菜单的真数据判据从「生效 N 条」改成「N 条」（英雄卡的统计文案变了），菜单 must 去掉附加后缀。

* **【后端】格改成【功能】页：一张菜单集成所有功能，长列表默认收进二级**（用户定稿，同日第三次重排）。菜单页五项入口、各带一行**当下状态摘要**（生效条数、守护进程数、keybox 有无、伪装开关），落地即用；目标名单 / 后端配置 / 自动同步 / keybox / 属性伪装（含 Verified Boot）全部收进二级页，点进去才画。伪装与 Verified Boot 归位到【功能】—— 它们是改设备状态的功能；【设置】只留界面自己的事（外观 + 界面自检）。
  * 二级页压一层 `pushState`（`#/func/<名>`），顶栏 leading 槽出返回箭头（`md-icon-button`），系统返回键由 `popstate` 接管回菜单；一级页之间仍是 `replaceState`，深链 `#/func/targets` 直落二级。
  * **性能白赚一截**：功能菜单页不再为名单 fork `targets/apps/target-meta/excluded`、也不为伪装问 `props` —— 这些进二级才问（`loadSub` 按需取）。真机（129 条名单）：主页 22ms、功能菜单 24ms、设置 21ms，名单二级走 popstate 路径 198ms / 92 节点。
  * **台架抓出一个组件行为**：`md-list-item` 会吞合成 `dispatchEvent`/`click()` —— 探针实测事件到了 document capture、元素监听器却不响（连临时挂在同一元素上的监听器都不响）。verify 与 replay 的二级页驱动全部改成 CDP `Input.dispatchMouseEvent` 可信点击，一次就通 —— 也更接近真手指。
  * 菜单摘要只放文件名不放全路径：`/data/misc/keystore/...` 会从词中间折成三行，全路径在二级页第一行 hint 里本来就有。
  * 静态闸（`tests/ui-shape.js`）重写层级组：菜单页必须"无长列表"（负面断言剥掉注释再查 —— 下一段的说明注释里就写着 listSection）、二级页按 `FUNC_PAGES` 分发、pushState/popstate/leading 箭头、主页只有状态两卡；变异台 9 把刀全部点名抓住。README 界面节整表重写。

* **自动同步并进【后端】格**（用户定稿，同日第二次挪这张卡）。它维护的就是后端格最上面那张名单文件，跟"这一家的配置面"同格才是它的语境 —— 位置在配置面之后、keybox 之前，与 keybox 一起推迟一帧挂载（都在折叠线以下）。主页只剩状态条 + 三家矩阵，落地页更轻；主页/后端取数不变（自动同步卡的 status/env 本来就在 base 里）。台架与变异台同步：verify 的 home must 移出自动同步两条、backend must 移入；replay 冷启动判据从"三张卡"改"两张卡"；`mutate-ui-shape` 换刀（从后端批里摘掉自动同步必须点名响、往主页塞回一张也要响）。

* **界面不是动态配色**（换 MD3E 时整套丢了的第三发，用户报的）。命令层一直在报 `sys_frro`（SystemUI overlay 的 base64）与 `sys_seed_raw`，界面这头却没人读 —— 上一版的 FRRO 解析、tonal 自检、四级回退与"明度取内置、彩度按实测比值"的映射全在换版时没了，界面退回 MD3E 库默认的静态紫。
  * 新增 `webui/src/theme.js`：解析与映射照上一版搬回（判据一字未动），落点从自绘 `--hue/--sat` 换成 MD3E 的 `--md-sys-color-*` 角色 —— 只重着 accent 染出来的六个角色（primary ×4 + secondary-container ×2），primary 的彩度精确落到系统实测值，其余按"内置彩度/内置 primary 彩度"的比例跟随；角色明度用**当前深浅档**的内置令牌（所以 `applyAccent` 挂在 `data-theme` 之后，切档重算；内置值按档缓存，落 overrides 前先抄走库的值，不然读到的是自己的 override）。
  * `applyAccent` 优先级不变：frro（tonal 阶梯明度必须单调，不单调整份丢）→ `theme_custom_color` → 壁纸 `colorValue0` → 平台默认 `system_accent1`（framework-res 的 **#4b5d8b**，不是库的紫）。外观卡照报来源与落点色相。
  * 新闸 `tests/accent-theme.mjs`（CI 已挂）：拿**合成 FRRO** 验解析与自检 —— 正对照先证明台子能从合成数据里解出金标准 400 档，变异（两档对调 / 条目不足 8 / 名字不带 system_ 前缀）必须退 null；种子解析六种存法、OKLCH 换算拿 #FF0000 与框架默认 #4b5d8b 当锚点。造台子自己先踩了两脚：`lerp` 闭包拿了外面的 `t`、传第三个实参被无声忽略（"金标准"其实是另一档的值），FRRO 的 ARGB8888 带 alpha、构造时丢了就永远差 0xff000000。
  * 台架（`verify.mjs`）钉端到端：无种子 → primary 覆写成 oklch 且色相 ≈267°（平台默认）；`?seed=0xFFC00000`（demo 数据新增的种子注入路）→ 色相落到 ≈29°。真机回放里按钮已是本机的青蓝。
  * 顺带修掉 README 两处上一版留下的过期描述（`--r-*`/`--sp-*` 令牌、`?dark=1`/`&tab=` 这些已不存在的预览参数）。

* **状态栏那条是透明的，像缺了一块**（用户上机报的）。两个半截原因叠加，各自只造成"看不见的带子"：
  ① 换 MD3E 时 `app.css` 重写，安全区改成了只读 `env(safe-area-inset-*)` —— 而管理器注入 insets 用的是**自定义属性**（从管理器 APK 的 dex 里挖出 `insets.css` 的生成格式：`:root{--safe-area-inset-*: …; --window-inset-*: var(--safe-area-inset-*, 0px)}`），这个 WebView 里 `env()` 恒 0。上一版读的正是 `var(--window-inset-top, env(…))`，重写时丢了。现在两边取大者：`max(var(--safe-area-inset-*), var(--window-inset-*, env(…)))`。
  ② 顶/底栏组件把颜色画在 shadow 里的 `.bar` 上，**宿主元素是透明的**，而让位 padding 恰恰加在宿主上 —— 不给宿主涂底色，padding 那条就是透明带。给两个宿主补上与内层一致的背景。
  * 还有第三处容易踩：组件把宿主高度钉死在内容的 64px（行全是绝对定位，`height:auto` 会让宿主塌成只剩 padding），border-box 下 `padding-top` 又是从这 64 里抠 —— `.bar` 溢出宿主、正好压住页头。用 `min-height: calc(64px + inset)` 压过显式 height，padding 让给内容，不挤不溢。
  * 台架钉死（`verify.mjs`）：往 `:root` 塞假 inset —— 顶栏必须长高 40 且宿主背景不是 `rgba(0,0,0,0)`；底栏吃 `--safe-area-inset-bottom` 同理；拿掉后回原高。静态侧 `ui-shape` 钉"读注入值与 env 的较大者 + 两个宿主有底色"。

* **界面不跟随系统深色模式**（换 MD3E 时引入，用户上机当天报的）。两层叠加：
  ① MD3E 的暗色盘挂在 `[data-theme=dark]` 上（tokens.min.css 里唯一的一块），而 `applyTheme()` 只设了 `color-scheme` —— 它翻的是表单控件与滚动条，界面自己画的 99% 是 custom properties，一个都不动；换成 MD3E 前的旧版是自己映射 `--md-sys-color-*` 的，这步在换版时丢了。
  ② 就算涂对了地方也白涂：`applyTheme()` 只在 boot 跑一次，而那时 `env` 还没回来，`S.env.sys_dark` 是 undefined —— 永远停在首次判断（demo 数据里 `sys_dark=1`，台架截图却全是亮色，就是这个时序在自证）。现在 boot 与 `reloadAll` 各在 env 落地后重涂一遍。
  * 台架钉死两层各一条：demo env 报 sys_dark=1 → `data-theme=dark` 且 body 背景是暗盘的 `rgb(20,18,24)`；点「浅色」→ attribute 与 surface **一起**翻回 `rgb(254,247,255)`（证明 attribute 真的在驱动调色盘，不是碰巧同值）；点回「跟随系统」→ sys_dark=1 赢。源码层 `ui-shape` 钉 "setAttribute('data-theme') + 两处重涂"。

#### 新增

* **TEESim 的 `overrides.json` 从"只读"变成能写**：新命令 `teesim-save-overrides` + 新 awk `module/backends/json_flat_set.awk`（扁平 JSON 的定点改/插/删）。界面上那六项（两侧安全等级、两侧版本、启动键哈希两项）从只读行变成表单，其余仍按上游判定显示为不可写。
  * 判据照抄上游的 `validOverride`（`Harvester.kt:423-432`）：等级只认 **0/1/2 = Software / TrustedEnvironment / StrongBox**（`Const.kt:75-77`）—— **不是** KM1 那套 `KEYSTORE=1 / TRUSTED_ENVIRONMENT=2 / STRONGBOX=3`，写 3 上游直接丢；版本 1–100000；启动键/哈希 = 可选 `0x` + 恰好 64 位十六进制 + 非全零。等级按**数值**比（上游 `toIntOrNull` 认 `01`），按字面枚举就严于上游了。
  * 白名单外的字段当场拒：那些在上游是 `OverrideSource.REQUIRED` 锁死的，写进去守护进程**丢弃并记一条日志**（`Harvester.kt:403-405`）—— 静默收下就是让用户以为设好了。
  * 启动键/哈希的可编辑性是**数据决定**的（只有守护进程自己那份是合成兜底值时才可改，`Harvester.kt:183-189`），写之前问自家那条只读汇总，不在这里另判一套。
  * `keymasterSecurityLevel` / `keymasterVersion` 标了「只记录，不上线」：上游 `Resolver.kt` 全文不读这两项，只有 `attestation*` 会进证书。
  * 留空 = 删掉这一项（上游同义：`system-controller.js:75` 空值即删除，`Harvester.kt:409` 空值复位默认）。值一律写成**带引号的字符串** —— 上游自己的写入器就是这么落的（`overrides-io.js:34-39`），守护进程按 `Map<String,String>` 读；我们写裸数字会让界面读回另一种形状。
  * 生效方式如实报出去：上游是 `FileObserver` 监听该文件 → `resolveAndPush`（`ConfigStore.kt:204-214`），**不需要重启任何进程**，所以命令层回 `apply_note`。
  * 新建这个文件时补 `chmod 644`：守护进程以 keystore 身份读它，留成本模块默认的 600 会直接读不到（私钥在 keybox.xml，那个仍是 600）。
  * 测试：`tests/teesim-overrides-write.sh` 49 条（本地 + 设备 toybox 各一遍），三个校验函数是从 `webui.sh` **抽真身**跑的；写回那一段用真 awk 真形状，产物还要过 `JSON.parse`（手工吃逗号这种事只有解析器会立刻抓出来），并钉住"重复写 = same、产物逐字节不变、未知键原样保住"。
  * 另配一个台架 `node tools/json-flat-set-check.cjs`（19 例）：删中间/第一条/最后一条/唯一一条/全删、紧凑一行写法同样四种、改+加+删混一单、空对象插入、值里带引号要转义回来、只动一行、未知键保留。删除分支第一版就是靠它抓坏的 —— 它只吃了值没吃键名，产出 `"a": ,` 这种东西，而"看起来差不多"的 JSON 是守护进程读不出来的。
  * 顺带修一处文案 bug：`serial`（来源 `supplement`）以前被写成"上游锁死为 REQUIRED"，那是把别家的判据安到这条头上。现在两种锁分开说：这一台不可改 ≠ 本模块不写。

* **OMK 的"生效代价"改成分档算，不再一律重启 keymint**：`cmd_omk_save_config` 以前写完就 `omk_restart keymint`。上游把代价写得很清楚（`docs/CONFIGURATION.md:415-425`）：**同一次保存里只动** `security_patch` / `os_patchlevel` / `vendor_patchlevel` / `boot_patchlevel` 这四个字段时，keymint 在运行中整组热生效，已有 TA 原地更新、在途操作与 per-boot 计数器都不丢；掺进任何别的字段才重启；`vb_key`/`vb_hash` 从 `random` 改成 `auto` 要重启**整机**。现在抽出 `omk_apply_scope`（按这一单提交的字段集判 hot/restart）与 `omk_reboot_needed`（只认 random→auto 这一条），结果用 `apply_scope` / `apply_note` 报给界面，`write()` 优先采用命令层那句而不是自己写死的"已保存"。
  * `tests/omk-apply-scope.sh` 22 条：抽的是 webui.sh 里的**真函数**；分类表把"四个全动 / 只动一个 / 四个+os_version / 四个+日志级别 / 四个+[device] / 四个+vb_key / 空参数"各钉一档；重启那 7 条含反向（auto→random 不算）与"vb_key 没变但 vb_hash 变了"；最后三条钉写路径确实接上了（函数里 `omk_restart` 只许出现一次，多于一次就是又退回无条件重启）。
  * 界面 `[trust]` 那一单的说明改写成同一套规则 —— 生效代价是**算出来的**，界面写死一句话就会说错。

* **三家后端互斥矩阵：三态、三家齐全**：命令层 `status` 新增 `omk_state`，并把 `teesim_enabled`/`tricky_enabled` 换成 `teesim_state`/`tricky_state`（`active` / `disabled` / `absent`）。原来的两态旗标有个说不通的洞：`backends_conflict()` 是把 OMK 一起数的，可状态表里**没有 OMK 那一位** —— 于是"多家冲突"的横幅能亮，却答不出是哪几家；而"没装"与"装了但被禁用"给的下一步动作完全不同（去装 / 删 `disable`），两态旗标把这两件事压成一样。
  * 界面在 keybox 卡下面加一格矩阵：三行、当前那家打 `●`，冲突时红底点名"同时启用 N 家（具体哪几家）"，并复述模块自己写进 `description` 的那句停写原因。
  * 台架新增一趟 `?demo=1&backend=tricky&conflict=1`：真机上碰不到的停写画面，不造就没有任何证据它渲染得对。假数据在冲突时连 `state=stopped`、`⛔ + TAA_CONFLICT_MSG`、`daemon_alive=0` 一起改（`service.sh:30-34` 就是这么做的），不然台架看到的是"停写但还在跑"这种机器上不存在的状态。

* **keybox 结构校验按后端分叉**：新增 `module/backends/keybox_check.awk`，`cmd_keybox_save` 改成 `-v backend=$TAA_BACKEND` 调它。三家判据互不相同（逐家对着源码核过）：Tricky 要求根元素 `AndroidAttestation`（`KeyBoxUtils.kt:67` 在深度 1 就判死）；TEESim 的运行时**不看根元素名**，只要小写 `algorithm="rsa"|"ecdsa"`、`<PrivateKey>` 与 ≥2 张 `<Certificate>`（`attest.rs:63-124`）；OMK 根本不是 XML 而是四条正则，必须有 EC 密钥、每个 `<Key>` 块自带 `<NumberOfCertificates>N>` 且**本块**证书数正好等于 N（`keybox.rs:35-42,286-314`）。
  * 语料用上游真实发布的两份：`tests/fixtures/keybox-tricky-aosp.xml`（Tricky 装机时自己刷的那份 AOSP 软件密钥箱）与 `keybox-omk-template.xml`（OMK 覆盖用的模板）。**正对照必须由真文件担任**：OMK 那份模板写着 `NumberOfKeyboxes=2` 却只有一个 `<Keybox>` —— 判据若去查这个数，就会把上游自己装的东西判成不合格，这是"不许严于上游"的具体形状。
  * `tests/keybox-shape.sh` 26 条，重心是**差异对照**：同一份内容在两家必须得出不同结论（去掉根元素 → TEESim 收 / Tricky 拒；证书数声明 3 实际 2 → Tricky 与 TEESim 照收、OMK 拒），共用一套判据的话这几条必红。另有"整份压成一行"两条，钉住计数按出现次数而不是按行。本地 gawk 与**设备 toybox awk** 输出逐字节相同（把两份完整输出拉回来 diff 过）。
  * 界面那条"看起来不是 keybox XML"的猜测式前端校验删了：它按根元素名拦，会误拒 TEESim 合法的文件。改成只拦三家都必定不收的形状（连 `<Key` 都没有），其余交给命令层，理由用 toast 原样报出来。OMK 那条说明写明了**解析不过会被自带模板覆盖回去**（本模块覆盖前留 `keybox.xml.bak`）。

* **补丁值的大小写规则也按后端分叉**：`valid_patch`（TEESim）与 `valid_tricky_patch`（Tricky）改成关键字一律不分大小写（两家上游都是 `ignoreCase` 比较），但**日期模板令牌一边认小写一边不认**：TEESim 只替换大写 `YYYY/MM/DD`（`DeviceProps.kt:156` 用 `v.contains("YYYY")`），Tricky 三个 `replace` 全带 `ignoreCase = true`（`AndroidUtils.kt:167-171`）。裸令牌（单独一个 `YYYY`/`MM`/`DD`）两家都判死：替换完剩下的数字过不了上游自己的日期式子，等于静默不报，收下来就是骗用户"设好了"。
  * `tests/patch-keywords.sh` 41 条（本地 + 设备 toybox 各跑一遍，41 ok / 0 失败），最后单列一组差异对照：`yyyy-mm-dd` 必须 TEESim 拒、Tricky 收；`today` 只有 TEESim 认；`prop`/`device_default` 只有 Tricky 认。
  * 两处报错文案以前只报字段名（TEESim 那句连被拒的值都不给），现在都点名 `$k = $v` 并把可写的式子列全。
  * 界面 `PATCH_HINT` 两家各一条：同一个 `no` 在 TEESim 是"报告 0"（标签还在，值是 0），在 Tricky 是"整个组件标签不报"（`CertificateHack.kt:55`）—— 这句话以前两边都没有，用户按另一家的意思填就得到相反的现场。

* **部署 WebUI 收成一条带闸门的命令**：`sh tools/deploy-webui.sh`。起因是这次推完顺手 `ls -l` 才发现 `adb push` 把 `/data/adb/modules/ts-auto-add/webroot/index.html` 落成了 **0666** —— 这个文件由管理器以 root 加载、里面的命令以 root 执行，世界可写等于任何应用都能改写一个 root 界面。模块里其它文件都是 644/755，只有我推的那一个是洞。
  * 闸门四道，任何一道不对就退非 0 并说清原因：工作区有未提交改动就拒推（否则设备上跑的版本对不上仓库，回头说不清是哪版）；`adb get-state` 不通；`adb shell id -u` 不是 0；远端目录不存在。推完 `chmod 644` + `chown root:root`，再**逐文件比本地与远端的 sha256**，最后核模式（不是 644/444 就红）。
  * 四条闸门各造了一次"真的该响"的场景验过：改脏工作区、把 `REMOTE` 指到不存在的目录、把脚本里的 `chmod 644` 改成 666、推完再往设备文件尾部追加一个字节 —— 每次都退非 0 且点名对应那条，跑完逐字节还原，并再真部署一次把设备留在好的那一版（收尾核到 `644 root:root 386671`）。
  * 中途踩到 `UID` 在 shell 里是只读的，脚本第一版在 `UID=$(...)` 那行直接炸；改名 `AS_UID`。

* **部署脚本会吃掉自己的清单：25 个文件只推了 1 个**：`tools/deploy-webui.sh` 扩到命令层（`--shell` / `--all`）后第一次跑就报"组=shell 文件数=25"却只推成 `webui.sh` 一个 —— `while read` 的循环体里 `adb shell` 会读 stdin，把喂给循环的整份 heredoc 清单吃掉了。剩下的 24 个文件留在设备上是旧版，而脚本原本会**报成功**。
  * 修法分两层：① 清单走 **fd 3**（`read <&3` + `done 3<<EOF`），stdin 空出来谁也别想抢 —— 先给单条 `adb` 加 `</dev/null` 是不够的，命令替换里那两处照样吃；② 加数量断言 `n = want_n`，"清单 25 推成 1"这种直接失败退出。原来那句 `[ "$n" -gt 0 ]` 挡不住它，1 也大于 0。
  * 这道新闸门是**被真 bug 撞响的**，不是造的变异：修 fd 之前它退非 0 并打印"只推成 1 个"，修完 25/25、`--all` 26/26 全过。
  * 顺带把命令层纳入同一条闸门：`webui.sh` + `lib/*.sh` + `backends/*` 共 25 个文件，逐个对 sha256 与模式（`.sh`/`.awk` 收 755，界面 644）。今天前面那几次手工 `adb push` 命令层就是没这条闸门，全靠人记得 chmod。

* **命令层补四条后端能力（契约号不动，仍是 api=4）**：`teesim-profiles` / `tee-status` / `tricky-patches` / `omk-restart`，命令数 31 → 35。
  * 为什么需要：上游文档里 TEESim 的 `profiles` 是一张「名字→配置」的表（每个 profile 自带 keybox、模式、三档补丁级别、设备身份、apps、自动纳入），而写回路径以前只认 `profiles.default` —— 多 profile 这层概念在界面上根本不存在；Tricky 的 `security_patch.txt` 支持 `[包名]` 按包块覆盖全局值，也支持 `device_default` / `prop` 两种取值，以前既不读也不列；Tricky 自己写的 `tee_status`（`AVAILABLE/FAILED/UNAVAILABLE`、`teeBroken`、`serviceErrorCode`）正是"这台机器为什么只能走 leaf hack"的答案，从来没被露出来。
  * **只加不改，所以号不涨**：这四条都是新命令，没动任何既有命令的输出形状 —— 涨号会让手机上正在跑的旧界面（`EXPECT_API=4`）当场判契约不符并停写。界面按 `hasCmd()` 逐条揭示，命令层与界面不同版时最坏是少一块内容。
  * 两个新 awk：`backends/teesim_profiles.awk`（`tests/teesim-profiles.sh` 9 条，含"default 排在文件里第二行也要输出在第一行"、apps 计数、没有 profiles 时退 1 不瞎输出；本地 gawk 与**设备 toybox awk** 输出逐字节相同）、`backends/tricky_patches.awk`。踩到的坑：`close` 是 awk 内建函数名，当局部变量用会语法错 —— 是测试先撞出来的，不是看图发现的。
  * `omk-restart <keymint|injector|all>` 不复用现成的 `omk_restart()`：那个在目录不存在时静默 `return 0`，而这是用户主动点的写命令，必须如实报成败。

* **界面验收台架进仓库**：`node tools/ui-cdp-check.mjs` —— 417 / 360 / 320 × 浅 / 深 × 八页，每页断四件事（视口确实钉住、横向溢出 0 并点名越界元素、只有一个可见面板且 id 对得上、顶栏标题等于**外部**期望值），最后跑主页「最近动态」的三条退路。
  * 起因是量具自己错：`--headless --screenshot --window-size=417,975` 起出来的布局视口是 **491**，截图仍旧 834 宽 —— 看着像 417，实际是在一台宽 18% 的假手机上验收。台架第一步是 `Emulation.setDeviceMetricsOverride` 之后**回读 `clientWidth` 并断言它等于要的宽度**。
  * **标题判据不能从页面里读**：第一版拿页面自己的 `TAB_LABEL` 当期望值，而顶栏标题就是它设的 —— 把 `系统属性伪装` 改成 `属性伪装`，台架一声不响。改成台架里另存一份 `EXPECT_TITLE` 才会响（这就是"两份实现对得上若共享同一个会坏的原语，信心恰好是零"）。
  * 台架自己也被变异验过四种破坏：改标题 / 给 `.console` 塞 `min-width:900px` / 让 `applyPage` 不再藏面板 / 删能力闸门 —— 每次退码非 0 且点名对应那条，还原后回全绿。其中先试的"删 markup 里的 `hidden`"**不是台架瞎**：`applyPage` 每次切页都重设 `hidden`，那个变异本身是惰性的，换成改 `applyPage` 才真的破。
  * 只在本地跑（要 Chrome），CI 不跑；`tests/` 那 12 个静态套仍归 CI。

* **视觉层照 `material-web 2.5.0` 重做**（「完全重构，结构你自己先定」）：
  * **字阶换成包里的 `md-sys-typescale`**（`tokens/versions/latest`，34.0.21）：11 / 12 / 14 / 16 / 22 / 24 / 36 / 45。原先那套 11/12/**13**/14/16/22/**38** 里 13 与 38 根本不在表上 —— 同一屏里 12 与 13 并排，看不出区别、只觉得"没对齐"。字重上限从 700 收到 **600**：页名 24/600、英雄数字 45/600、板块标题 14/600、列表行按 M3 的 headline/supporting 分成 16/500 + 12/400。
  * **卡片改回 M3 的"三选一"**：原先描边 + 投影 + 浅底三样同时上，现在只留 1px 发丝线（outlined 那一档），投影去掉。
  * **行的按压改成 state layer**：`on-surface` 8% 悬停 / 12% 按压叠在内容上，不再整块换底色、也不再缩放 —— 深色主题里"亮起来"会被读成选中态。底栏按压从 0.92 收到 0.94（M3E 的 press 量级）。
  * 主页那张卡里只有一个「运行」板块，去掉"盒中盒"的底色；日志台去掉逐行分隔线（300 行就是一屏栅栏）。
  * **删死规则 65 行**：`.btn` 家族、`.fab`、`.icon-add`、`.app-row`、`.card-quiet`、`.hint-warn`、`.sheet`/`.dialog`，以及那套假 ripple —— 注释还写着"圆由 JS 在 pointerdown 时插入（见 wire 里的 rippleAt）"，而 `rippleAt` 早就不存在了，组件自己的 ripple 在 bundle 里。**删前删后八页逐像素 0 差异**，这是"只删了死代码"的证明。
  * 形状档核对过：卡 20 = `corner.large-increased`、英雄 28 = `extra-large`、板块 11 = 20 − 1px 边框 − 8px 间距（同心）、底栏胶囊 22 = 28 − 6（同心）。
  * 417 实测（浅色，八页）：横向溢出全 0；导航台架 14 步（四格底栏 + 四个二级页开/关 + 二级页直接切一级页）全部对上；12 个测试套全绿。

* **功能菜单拆细成四项，二级页接上系统返回**：「后端与名单」这一项太胖、菜单又只有两行太空，现在拆成 **应用名单 / 后端配置 / 系统属性伪装 / Verified Boot 哈希**。名单与配置回到各自一页（上一版合过，合起来在 OMK 126 条名单下把配置推到 7000px 之外）；Verified Boot 从属性页里那块 `.grp` 独立成页（它不受「开机重置属性」开关影响，本来就是另一件事），菜单行受命令能力门控（`boot-hash` / `props-boot-hash` 不在就不显示）。
  * **系统返回回菜单**：进二级页时 `pushState` 一条（`drillDepth`），系统返回或顶栏箭头都退这一层，落点是功能菜单；一级页上没有可退条目，返回仍是一次退出管理器。从二级页点底栏切到别的一级页时，先把这层历史退掉再落到目标页（`pendingTab`），否则一级页上会凭空多出一条可退记录。
  * `PAGES` 8 项（4 一级 + 4 二级）、`SUB_OF` 四条；`ensure('apps')` → lists、`ensure('boot')` → props（同一个命令）、`renderAll` 各画各的；`renderFunc()` 只做一件：按能力显隐 Verified Boot 那一行。`.menu-row` 自己设了 `display:flex`，补 `.menu-row[hidden]{display:none}` 才能真的关掉。
  * 417 实测：`boot / 功能 / 打开四项各一次 / 每次返回 / 二级页直接切日志 / 关于 / 主页` 全部对上（hash、标题、底栏高亮、返回箭头、唯一面板、英雄卡），横向溢出 0；进二级页 `history.length` 1 → 2，返回后菜单里四项都在。
  * `tests/ui-shape.js` 58 条；新断言做变异验证：去掉 `pushState`、删掉 `.menu-row[hidden]` 都会红。

* **底栏收成四格，功能做成二级菜单**：一级只留 `主页 / 功能 / 日志 / 关于`，后端与属性收进「功能」这张菜单（先两行，随后拆成四项，见上一条）。点进二级页后**底栏不改**、仍高亮「功能」，出口是顶栏左上的返回箭头（`#/backend`、`#/props` 各有自己的 hash，`SUB_OF` 把二者挂到 `func` 下）。
  * 药丸 **300 → 250**（四枚图标 + 一个展开的名字）；二级页隐藏英雄卡、顶栏钉住并显示返回箭头，主页仍旧随内容滚。
  * `PAGES` 变成 6 项（4 个一级 + 2 个二级），`applyPage` 用 `barTabOf(name)` 决定高亮哪个一级；`goBack()` 回到 `SUB_OF[S.tab]` 并同步 hash；`ensure('func')` 直接返回（静态菜单，不取数），`renderAll` 对它不做任何事。
  * 菜单卡 `padding:0`、行自己留 sp6，文字左缘仍旧对齐到那条 41；新增 `.menu-txt small` 一行说明（12/on-variant）。
  * 417 实测：`boot / 功能 / 后端与名单 / 返回 / 系统属性 / 日志 / 关于 / 主页` 八步全部对得上（hash、标题、底栏高亮、返回箭头可见性、面板唯一、英雄卡只在主页），横向溢出 0，药丸 250×58 落在 83…333。
  * `tests/ui-shape.js` 的导航断言按新结构重写（tab = 一级页、二级页都挂在存在的父级、功能页恰好两个菜单行、返回钮只给二级页、`goBack` 回父级），共 **54 条**；变异验证过的两条：把菜单行目标改掉、把 `barTabOf` 去掉都会红。

* **底栏回来了：六格悬浮药丸，替代「概览 → 四个二级页」的下钻**。下钻那一版把五个页藏在概览的一张入口列表后面，概览只剩「门」而没有内容；现在六个目的地并列在底栏上，每一页都能直接到。
  * **形态照 Opticon 的 FloatingNavBar**：`surface-high` 药丸 + 1px `card-line` 描边 + 8px 投影，离底 20 + 安全区；**非选中只留图标，选中那格展开成「图标 + 名字」的胶囊**（`max-width` + opacity 过渡，340ms 过冲曲线），按压缩到 0.92。六个图标 + 一个展开的名字在 417 CSS px 下放得下：实测药丸 350 ≤ 401，三后端 × 六页横向溢出都是 0。
  * **顶栏撤掉返回箭头与下钻语义**：六页平级，没有上一级；`applyPage` 只管页名、英雄卡显隐、底栏选中态（`is-active` + `aria-current`）和二级页的 sticky 标题。概览的滚动位置仍在切走前记下、切回时还原。
  * **切页只改 `#/` hash，并且走 `replaceState`**：不往历史里堆条目，`webView.canGoBack()` 保持原样 —— 系统返回（手势/返回键）一次就退回管理器，而不是逐页后退。`popstate` 只接真正的前进/后退与深链（`#/props`）。面板入场方向跟底栏的左右排布一致（往右切从右滑入），仍是 24px / 200ms 的 WAAPI 位移，不碰高度、不盖遮罩。
  * **浮层让位重新量过**：`.wrap` 的 `padding-bottom` 改成 104px + 安全区（药丸离底 20 + 高 58 + 气口），提示条抬到 `bottom: 88px + 安全区`（实测与药丸上沿留 10px）；多选时底栏整条 `display:none` 让给批量条（两者占同一条底边，叠在一起没法点）。
  * `tests/ui-shape.js` 增加「底栏导航」一组断言（PAGES 六项、tab 与 PAGES 一一对应、每个 tab 图标都在 ICON 表里、`.tabs` 钉底、选中用 `secondary-container`、`.wrap` 让位 ≥96、提示条 ≥72、`applyPage` 同步选中态、`goTab` 自己完成切页、多选让位、`replaceState`、入口列表与返回钮无残骸、滑动期间裁切），共 **50 条**全绿。
  * CDP 实测（417×900）：六页 `hash / 标题 / 英雄卡 / 选中态 / 面板` 一一对应，`history.length` 点完六页仍为 1；药丸 350×58 落在视口内，选中项标签宽 28.2、其余 0；提示条 757–812 对药丸 822（间隙 10）；滚到底时内容最后一行与药丸上沿的最小间隙 26px。

* **「应用列表」并进「后端与格式」，底栏六格 → 五格**：名单本来就长在后端的文件里（Tricky 的 `?`/`!`、TEESim 的 `@用户`、OMK 的 `scoop` 各说各的语法），把它拆成单独一页反而让「这个后端怎么记条目」分散在两处。现在后端页上半是**名单**（分段视图、搜索、选择、列表、批量条原样搬过去），下半是**配置**（条目语法说明 + 按后端渲染的可编辑字段 + keybox），两个 `.grp-t` 标题分开。
  * 底栏这一步先变成 `概览 / 后端 / 日志 / 属性 / 关于`（药丸 350 → 300），随后按下一版再收成四格；`#/apps` 深链移除，`?tab=apps` 不再可用。
  * 取数链：后端页要**同时**拿名单与配置，`ensure()` 拆成 `ensure('backend')` = 两路并发 + `ensureNeed(need)` 各自去重；`withBase` 那条基础链固定取 lists（英雄卡要用），「关于」页跳过。顺手补了 `S.apps` 的默认 `[]` —— 之前它只在取完数才建，深链直接进后端页时 `renderApps` 会抛 `Cannot read properties of undefined`。
  * 多选仍只属于名单区：离开后端页自动收起（`body.is-selecting` 时底栏整条让位给批量条）。
  * 417 实测（三后端 × 五页）：横向溢出全 0、每页只显示一个面板、英雄卡只在概览出现、药丸 300×58 落在 58…358；后端页名单 12 行、配置 2 组（TEESim），滚到底能看到「配置」分隔；多选时 `tabs display:none`、批量条 top 832。
  * `tests/ui-shape.js` 加一条「名单区与配置区同在后端页」（同时断言 `#p-apps` 已不存在），共 **51 条**；变异验证（把「名单」标题改掉）会红。

* **界面整合：同一件事只留一处**。概览的「运行 / 目标 / 日志与属性」三组合成一组（日志字节数归日志页、属性开关归属性页，目标文件与上次写入并进「运行」）；「关于」的界面自检与外观合成「界面」，设备并入「设备与路径」，删掉重复的「后端模块」格；「后端与格式」的配置表单改成**一个文件一组**（TEE Simulator 一组、Tricky 一组、OMK injector/config 各一组），目标格式与路径摘要压成两行提示，设备身份用组内小标题分隔。417 宽下三后端 × 六页横向溢出仍为 0。

* **按三个后端分别适配上可视化界面（api 4）**：名单不再把目标文件当成清一色的裸包名，而是按各上游自己的语法解析、展示与写回。
  * **Tricky Store OSS**：`target.txt` 的行内 `#` 注释、`pkg?`（强制叶证书破解）与 `pkg!`（强制证书生成）都被识别；同一个包名出现多次时按上游语义取最后一个模式。名单行尾新增 `自动 / 叶证书 / 证书生成` 模式按钮，点开即写，只改这一行的后缀并保留注释与缩进。新增命令 `set-mode <包名> <auto|leaf|generate>`（写命令，走 `webui_lock`）。
  * **TEE Simulator**：`apps` 里的 `pkg@用户` 与 `uid:数字` 原样保留；界面把前者显示成「用户 N」标签、后者显示成 `UID N` 行；按用户条目移出时只删对应 token，卸载一个包时连同它的 `@用户` 变体一起移除，`uid:` 因无法反查包名而保留。
  * **OhMyKeymint**：`scoop` 仍只接受包名；后端页展示 injector 的 filter / intercept 与 config.toml 的 trust 摘要。
  * **新增「后端与格式」二级页（可编辑）**：按当前后端分别渲染目标语法/条目分布与**可手动配置**的表单 —— TEE Simulator 的 default profile（mode、keybox、patchLevel、osVersion、autoInclude、设备身份）、Tricky 的全局补丁表、OMK 的 injector（main/filter/deny/intercept）与 config.toml（main/trust/device）；三家共用 keybox 粘贴替换。只提交改动过的字段，未知键/非法枚举/日期/包名在写盘前拒绝，写前备份；TEE Simulator/Tricky 由各自 watcher 重载，OMK 写后请求 `restart.injector` / `restart.keymint`。
  * **命令层**：新增 `target-meta`（token + 基础包名 + 类型 + 细节）、`set-mode`、`backend-info`；`targets` 对 Tricky 返回有效 token 而不是带注释的原始行。配置写回新增 `teesim-save` / `omk-save-injector` / `omk-save-config` / `tricky-save-patch` / `keybox-save`，全部走白名单+类型校验+写前备份+原子替换。契约号 2 → 4。
  * **写回实现**：`teesim_set.awk` 只改 default profile 的标量/嵌套 patchLevel，其它 profile 与 apps 原样；`omk_set.awk` 按段改 TOML 标量、把多行 deny_packages 收成单行、缺段则新建；`tricky_patch_set.awk` 只改全局段并把裸值转成 `all = …`。三个 writer 重复写返回 same 且文件逐字节不变；OMK 有改动才请求重启 injector/keymint。
  * **同步按基础包名**：`build_app_list` 的卸载判定与新装判重都用基础包名，`pkg?` / `pkg@10` 不会被当成另一个应用；`.ts_ever` 与 `excluded` 也只记基础包名。修复了带后缀/用户变体的条目在卸载后残留、新装时重复追加的问题。
  * `tests/target-tokens.sh`（接进 CI，**55 条断言**）：三个后端的解析、增删、模式改写、快照差分、ever/excluded、三个 `backend-info` 解析器与 `is_target_entry`；`tests/config-write.sh`（**39 条断言**）：三个 writer 的替换/插入/嵌套/多行数组/新段/带注释段头/幂等。`ui-shape` 48 条；`contract-pair`（api=4）全绿。
  * 桌面 417 宽（CDP `Emulation.setDeviceMetricsOverride`）实测：三后端 × 六页横向溢出均为 0；Tricky 模式按钮与对话框、TEESim 用户/UID 标签、批量选择把 token 原样带进确认框；三后端表单可编辑并保存（演示状态回读）、keybox 粘贴对话框可用；演示数据新增 `?backend=tricky|teesim|omk`。设备上用一份临时模块副本跑通五条写命令：TEESim 模式/身份、Tricky 全局补丁与 keybox、OMK injector/config，含备份、重载请求、非法值拒绝与重复保存不落盘。

* **字体改为 `system-ui`（学习机上其它 WebUI）**：参考 `nomount` 模块的 `--nm-font-family: system-ui` —— 本机 WebView 156 下 system-ui 就按系统字体（Google Sans Flex）渲染。删掉整套字体探测/复制/hash 文件/`@font-face`/`fetch` 镜像：`env` 不再输出 `sys_font*`，不再往 `webroot/fonts` 或 `webroot/icons` 写 4MB 字体文件；关于页只写「跟随系统（system-ui）」。Material Web 的 `--md-ref-typeface-plain` 仍映射到 `var(--font)`。`tests/ui-font.js` 改为 **9 条断言**，专门防止再引入 `@font-face`/字体文件管线；8 个 shell 测试与 `ui-shape` 19 条全绿。

* **全量重构 WebUI：接入 `@material/web` 2.5.0（labs/gb Expressive）**：界面控件不再自己仿 Material，直接用组件；仍是单文件、不联网。
  * 组件：`md-gb-button` / `md-gb-icon-button` / `md-gb-list` / `md-gb-list-item` / `md-gb-switch`、`md-outlined-segmented-button-set`、`md-outlined-text-field`、`md-dialog`。原生按钮、分段、开关、输入框、确认框、首页入口和应用列表全部换掉；卡片、分组、日志台、提示条保留模块自己的布局。
  * 构建：`@material/web` 2.5.0 + Lit 3.3.3 经 esbuild 打成 **190KB minified / 40KB gzip 的 IIFE**，内联进 `index.html`；`m3.css` 用 adoptedStyleSheets 注入，颜色/字体/圆角通过未分层的 `--md-sys-color-*`、`--md-ref-typeface-*`、`--md-sys-shape-*` 别名映射到现有 token。**要求 Chromium 111+ WebView**（本机 156）；更旧的 WebView 会在顶部提示升级，而不是空白。
  * 应用列表用 `static` 列表项（行内还要放 + 按钮，避免嵌套 `<button>`），选中/悬停用 `::part(list-item)` + 自定义 selbox；行高 56、头像 40，选中 `secondary-container`。列表项的 Material Symbols 勾选被构建脚本关掉（界面不装图标字体）。首页入口改为 `md-gb-list`；搜索框、批量条、属性开关/输入框、确认框、日志分段全部组件化。
  * 顺手修掉英雄卡「立即同步 / 重新读取」两个按钮一直没有 click 监听的问题（现在接到 `doSync()` / `refresh()`）。
  * 维护：`tools/mwc-build/`（npm + esbuild，构建时用，不进刷机包）；`THIRD_PARTY_NOTICES.md` 记录 Apache-2.0 / BSD-3-Clause / 0BSD。`build.mjs` 用替换函数内联，避免 bundle 里的 `$1` 被 `String.replace` 当捕获组。
  * `tests/ui-shape.js` 扩到 **19 条断言**：解析内联 bundle 与 app 两段脚本，并检查 `md-gb-button` / `md-gb-list-item` / text field / dialog 的注册；8 个 shell 测试全绿。桌面 417 宽实测：应用/日志/属性/概览/关于五页横向溢出 0；应用行 56×335、头像 40、加号 32、标签不重叠；分段/搜索/批量条/对话框/开关/加入/移出/撤销均跑通。真机只读检查 WebView 156，未做真机界面截图。

* **按 Material Web 2.5.0 的 Expressive 模板调整交互形状**：只取 `labs/gb` 的令牌与组件解剖，不把 Lit/组件库打进单文件界面（官方 All 组件包约 455KB minified，且 MWC 已进入维护模式）。
  * 按钮按下时圆角从胶囊收成 8px，350ms 使用官方 `cubic-bezier(.42, 1.67, .21, .9)` 过冲曲线，松开弹回；FAB 保留自己的 50% 形状。
  * 分段选中与列表选中改用 `secondary-container / on-secondary-container`；列表选中头像用 `primary-container`。
  * 应用列表行最小 56px、头像 40px 圆形（官方 list-item 尺寸）；入口行最小 56px。
  * 417 宽复测：横向溢出 0；行高 56、头像 40、分段/列表选中颜色取到 `secondary-container`；`.btn:active` 解析为 `border-radius: var(--r-xs)`，过渡含 350ms 官方曲线。全部静态测试与 JS 语法通过。

* **目标名单可以减了（`remove-apps`）**：应用页「名单」视图点「选择」进入多选，底部条变成红色的「移出名单」（加入模式仍是主色「加入名单」），确认后**一次写入**；全选时会拒绝并提示「至少保留一个应用」。确认框会列出前三个包名。新命令 `remove-apps <包名,...>`（能力门；`api` 仍为 2，旧命令层没有它时名单页不出现「选择」）。
  * 只删请求里的包名：Tricky 保留注释、空行与其余行顺序；TEESim/OMK 只替换数组并保留其它字段。移出前把当前名单并入 `.ts_ever`，所以手工加进文件、还没同步过的包也会在移出后显示「已排除」，下次同步不会自动加回（卸载重装仍按原规则回来）。
  * 名单不允许清空：`remove_target_apps` 在结果为空时返回 3，界面提示先取消一个；读取目标文件失败/定位不到数组返回 2，不会伪装成「本来就不在」。
  * **移出后可撤销**：命令层返回实际被移出的 `removed_list`（不是界面勾选快照），提示条在 6 秒内提供「撤销」，走 `restore-apps` 精确恢复；列表刷新过、勾选里夹着已不在文件里的包时也不会多加。
  * `tests/remove-app.sh`（接进 CI，**43 条断言**）：三个后端、一次移出多条、`removed_list` 精确记录、本来不在、会清空、目标损坏、`ever` 与 `excluded`；三处变异（去掉空名单保护 / 不检测读取失败 / 不并入 ever）都验过会红。
* **命令层返回值的形状检查**：界面每次调用后校验自己真正会读的关键键（status / env / contract / boot-hash / sync / restore / remove / props 等）；缺键时横幅「命令层返回格式不认识」并停写，不再把字段名变化静默画成空值。`tests/ui-shape.js`（接进 CI，**19 条断言**）从 `index.html` 原样抽出 `KV_REQUIRED` / `parseKV` / `kvMissing` 执行，缺键、未知命令、`call()` 接线、超时标记、两段内联脚本语法与组件注册都覆盖；两处变异（少一个必需键、`call()` 不接 `kvMissing`）都验过会红。
* **应用页刷新图标与超时文案**：应用页工具栏加了一个图标刷新（选择模式下隐藏，避免把选中状态刷掉；靠右对齐），60 秒超时从「命令超时」改成「结果未知；已重新读取当前状态」，写操作本来就统一走 `reloadAll()`。
  * 验证：417 宽下应用页横向溢出 0；刷新图标右缘与卡片内容右缘对齐；批量条四件（已选 / 全选 / 移出名单 / 取消）落在卡内；桌面演示跑通移出→已排除→撤销、加入、刷新、缺键横幅与超时文案；全部静态测试与 JS 语法通过。

* **继续简化界面**：应用页把「只看未纳入」并进分段，改成 **名单 / 已安装 / 未纳入** 三个视图，少一个按钮；日志页把「分段 + 刷新」和「清空 + 自动刷新」拆成两行有意的控制条，不再由换行决定布局；关于去掉「安全区留白」和「上次命令」两行调试细节（`call()` 不再维护没有出口的耗时记录）。
  * 验证：417 宽下三个视图分别 10/9/2 行，未纳入选中态正确；日志两条工具栏、刷新文字「刷新」；关于 4 组、界面自检 5 块、路径 5 行；横向溢出 0。

* **全站留白与减字**：每个页面的文字之间都松了一档，同时删掉只解释不提供数据的句子。
  * 间距：板块内边距 12 → 16、板块间 20 → 24；网格行距 12 → 16；键值标签下距 3 → 5、注释行距 1.55；入口行 12 → 16；应用行 5 → 7；属性行 5 → 9（行高 1.5，实测行高 37）；日志行高 1.5 → 1.7 + 3px 行距；路径行距 2 → 6；工具栏间距 8 → 12；属性行与应用行的水平内边距归零，让所有内容左缘都落在 41（入口标题、状态标签、属性键、应用头像实测同为 41）。
  * 概览：去掉顶栏下方的设备注脚（设备信息移入「关于」）、入口的副标题与从未渲染出来的图标/箭头空位、状态卡里的路径与工具注脚（数据/目标路径改列在「关于」）；英雄卡不再重复守护进程数。
  * 属性：正常项不再逐行显示「一致」（17 行重复同一个词），只在不符/未定义时显示状态与期望值；开关与 Boot hash 的提示各缩成一句，输入框占位缩短。
  * 关于：删掉契约、取色、字体、深浅、生效值下方的长解释和页脚说明，只留标签/值；拆成「界面自检 / 设备与后端 / 外观 / 路径」四块，新增设备与数据/目标路径；日志页统计去掉 64KB 规则说明，并补上一直空着的「刷新」按钮标签。
  * 分组：概览的状态明细拆成「运行 / 目标 / 日志与属性」三块；属性按「构建 / 调试与安全 / 启动与验证 / 保修位」四组排（每组一块底，组标题 + 行）；关于四块含独立的「路径」组。
  * 层次：组标题升到 13/700 on-surface 并加主色竖条；入口标题 16 + ›；键标签降为 12/500（值仍是 16/600），组底色从 surface-high 抬到 surface-highest——页面、卡、组现在是三档底色，标题、值、标签也拉开三档。
  * 验证：417 宽下五个页面横向溢出均为 0；`.grp` 块 25…392 落在卡片内；入口标题/状态标签/属性键/应用头像左缘 41；属性正常项 10 条、ok pill 0；概览/属性/关于的组数分别为 3/5/4；日志刷新文字为「刷新」。

* **支持 OhMyKeymint（第三个后端）**：模块现在识别 `/data/adb/modules/oh_my_keymint`，维护 `/data/misc/keystore/omk/injector.toml` 里的 `scoop` 数组。只替换这个数组：注释、`version`、`[main]` / `[filter]` / `[intercept]` 与每个包的 `[scoop.<包名>]` 段逐字节保留；`config.toml` 完全不碰。写入前备份到 `/data/adb/omk/injector.toml.bak`，保留原文件的 owner / mode / SELinux 上下文，成功后写 `/data/adb/omk/restart.injector` 让 OMK 自己重载 injector。
  * **首次接入沿用现有名单**：`scoop` 已有内容时只把当前已装记成基线，不把已装应用批量灌入；之后新装自动加入、卸载自动移除、手删不回。`scoop` 为空时才按其它后端一样加入全部已装 + 三件套。
  * 三方冲突：`backends_conflict` 现在统计 TEE Simulator / Tricky Store / OhMyKeymint，多于一个启用就停止模块；描述统一写「多个密钥库后端同时启用」。
  * 状态文件**寄生在 OMK 自己的 `/data/adb/omk/`**（`.ts_*` 前缀，不往 keystore 目录里塞 dotfile，也不新开顶层目录）；`targets` 命令改走 `current_target_apps`（修掉旧代码会把整份 TOML 当名单吐出来的问题）；「关于」页的后端格改用 `backend` / `backend_name`，不再只认 TEE/Tricky。
  * `tests/omk.sh`（接进 CI，**42 条断言**）：scoop 多行/单行/空/缺失读取、定点替换、其它段与 per-package 段保留、内容一致不落盘、备份与重载请求、恢复单条（含 ever 更新）、批量加入、三方冲突矩阵，以及「首次沿用整条同步不改文件、有新装时写入」。三处变异（去掉沿用、冲突阈值、整份重写）都验过会红。

* **同步模型换成快照差分，墓碑文件整个拿掉**：加入的来源从「已装但文件里没有」改成「上一轮之后新装的」（`inst − was`），删除只删「上一轮之后卸载的」（`was − inst`），文件里其余条目原样保留。手动删掉的包仍然装着、但不在"新装"里，所以**结构上就不可能被回填** —— 不再需要 `.ts_removed` 与那份"上次写了什么"的 `.ts_written_last`；差分状态只剩 `.ts_installed_last` 一份基线，另加一份 `.ts_ever`（历次纳入的并集，只用于「已排除」判定）。
  * `excluded` 改成按 `.ts_ever` 现算（`已装 ∩ 曾经纳入 ∩ ¬目标文件`）。用已装基线会在 OhMyKeymint 首次沿用现有 scoop 时把 100 多个从未纳入的应用误标成「已排除」；升级后第一次成功同步会顺手清掉旧的墓碑文件（失败不删，便于回退）。
  * **空列表保护**：已装列表读空、但基线非空时（更像一次 `pm` 读取失败，而不是真把应用全卸了），自动同步放弃本次写入（`build_app_list` 返回 1，描述标失败）；界面「立即同步」与管理器「操作」按钮会显式设 `TAA_EMPTY_OK=1` 强制按当前已装处理。首次运行（没有基线）不受影响。
  * `tests/sync-guard.sh`（接进 CI，**9 条断言**）：两个后端真实的 `sync_*` 在空列表下返回 2、目标文件逐字节不变、基线不推进；`TAA_EMPTY_OK=1` 时按当前已装写入。两处变异（去掉保护 / 忽略强制标记）都验过会红。
  * `tests/sync-incremental.sh` 按新模型重写：**16 个场景 / 38 条断言**（首次种子、目标非空不种、新装进/卸载出、手加保留、手删不回、卸载后重装回来、手加回、已装为空、清空不回填、种子只种一次、状态只写已装、旧状态清理、首次运行不误报排除、空列表保护与手动强制、OhMyKeymint 首次沿用）。本机 mksh + toybox awk 跑同一份全绿。
  * 真机端到端（本机 config.json）：换算法后跑 `sync`，内容一致（125 条），文件 sha 与测试前**逐位相同**。

* **「已排除」可以一键加回**：应用页的「已安装第三方」视图里，已排除的行尾多一个 **+** —— 点它把包名写回目标文件（TEESim / OhMyKeymint 走各自的定点 awk；Tricky 逐行追加，原文件没有结尾换行时先补一个）。命令层新增 `restore-app <包名>`（能力门，`api` 仍为 2）：包名按 Android 规则二次校验，写之前持 `webui_lock`，本来就在名单里就返回 `restored=0` 且不落盘。统计行新增「已排除 N」；恢复成功后顺便按目标文件的实际条数刷新模块描述，不用等下一轮同步。OhMyKeymint 沿用现有 scoop 后，**「未纳入」的行尾也有同一个 +**（加入名单），加入时同步并入 `.ts_ever`，以后手动删掉仍会被认作「已排除」。顺手修了一个闭包洞：以前 + 只有一行时看不出来，多行都有 + 时所有按钮都会用循环最后那个包名（实测点 A 加的是 B），现在按行传参固定。
  * **批量选择**：应用页点「选择」进入多选 —— 只列「可加入」的应用（已在名单的直接隐藏），行尾圆点选中；底部固定条显示「已选 N / 全选 / 加入名单 / 取消」。加入走新命令 `restore-apps <包名,...>`（能力门，逗号分隔，全部校验通过后**只写一次**目标文件，OMK 只重载一次），旧命令层没有它时批量按钮不出现。列表/搜索/筛选变化时选中态保留，离开应用页自动退出。
  * **列表减噪**：整屏 100 多个「未纳入」不再挂红色标签（那只会变成红字墙），「未纳入」只用行尾的 + 表达；只有你手动删过的「已排除」保留中性标签。行尾 + 去掉了底色与边框（命中区仍是 48），批量模式的行也只有头像/名称/圆点。进一步只留必要数据：每行**只显示应用名**（包名在 title 里，搜索仍匹配包名；没有显示名时才显示包名），搜索框去掉独立标签只留占位，分段缩短为「名单 / 已安装」，统计只在搜索时补「显示 N」。
  * `tests/omk.sh` 增加批量写入与 ever 断言（**42 条**）。`restore-app.sh` 仍测单条包装（25 条）；`restore-app` 变薄包装后，cur 为空时用 `NR==FNR` 会吞掉第一条新包名，测试当场抓到，已改成按 `FILENAME` 区分。
  * `tests/restore-app.sh`（接进 CI，**25 条断言**）：两个后端的写回、已存在不落盘且文件逐字节不变、原文件无结尾换行不粘连、TEESim 的 `mode` / 其它 profile / 顶层字段保留、数组定位失败时放弃且不改文件。两处变异（不落盘、不补换行）都验过会红。

* **属性页新增 Verified Boot 哈希**：粘贴 `verifiedBootHash`（64 位 = sha256 / 128 位 = sha512）后写进 `ro.boot.vbmeta.digest`，只补空的 `ro.boot.vbmeta.hash_alg`。写后读回校验，不一致会如实报失败而不是"已应用"。它和伪装开关互相独立 —— 保存了就应用；只用 `resetprop -n`，重启回系统原值；配置文件 `/data/adb/ts_auto.boot_hash`（`600`）。
  * 命令层新增 `boot-hash`（读配置 / 当前 digest / 状态）与 `props-boot-hash <值|->`（保存 / 清除并立即应用）。只加命令、不改既有输出形状，`api` 仍为 2；界面按 `commands` 能力门显示，旧命令层上整块隐藏。
  * `tests/props-boot-hash.sh`（接进 CI）：格式校验、去空白转小写、原子写、非法值不覆盖、只在不同时写 digest、`hash_alg` 只补空、读回不一致报失败、无 `resetprop` 明确失败。**33 条断言**（Windows 本机跳过权限位那一条，其余 32 条通过；Linux CI 全跑）。
  * 界面：哈希块放在属性页应用按钮下方（当前 / 已保存 / 输入 / 保存并应用 / 清除），长哈希自动换行；保存与清除都走 `confirm`/提示，非法输入在本地先挡一次。

* **开机完成后第二遍复核属性**：`service.sh` 等到 `sys.boot_completed` 后把属性表再幂等跑一遍（已符合的不重复写）。有些机型在 post-fs-data 之后才落锁状态 / AVB 元数据，早段写入会被覆盖；这一遍兜住它，digest 同样按配置复核。

* **修：属性页的「立即应用」按钮一直是个空胶囊**：`btnPropsApply` 从未设置过标签，实测 24×36 的空白按钮。现在补上 `tune` 图标 + 「立即应用」。

* **命令参数统一做 shell 转义**：`run()` 以前把参数原样拼进命令串；boot hash 是用户输入，现在一律走单引号转义（值本身另有 64/128 位十六进制校验）。

* **CI 增加五项静态自检**：`tests/contract-pair.sh`（对账 `TAA_API`/`EXPECT_API`、写命令清单、界面调用的命令名与能力门）、`tests/props-boot-hash.sh`、`tests/restore-app.sh`、`tests/sync-guard.sh` 与 `tests/omk.sh`。契约对账来自上一轮真机横幅事故（界面停在 api=1、命令层已是 2），两种单边改动都验过会红。

* **没有启动器入口的应用也有图标与显示名了**：桌面缓存（`app_icons.db`）只有**有启动器入口**的应用，GMS / GSF / WebView / AR Core / SafetyCore / 开发者身份验证工具 这类后台组件在里面一行都没有，界面只能退成首字块（实测本机 122 个第三方应用里 12 个属于这一类）。它们的图标在 APK 里，而 Google 的包资源名被混淆过（WebView 的 `base.apk` 是 260MB、图标在 `res/j_` 这种名字下），按文件名抠图不可行、解析 `resources.arsc` 又不划算。
  * 做法：带一个 **3.6KB 的 dex**（源与编译命令在 `tools/icondump/`，源码只调公开 API、隐藏 API 走反射），在 `app_process` 里调 `PackageManager.loadIcon / loadLabel` —— 自适应图标由系统渲染好，顺带拿到中文显示名。
  * 踩到并修掉的两个坑：① 这台机器的 `app_process` 跑内置 `com.android.commands.pm.Pm` 会 SIGABRT —— tombstone 里写的是 `ClassNotFoundException`，也就是说 app_process 本身没问题，只是那个类在 API 37 上没了；② `ActivityThread.systemMain()` 报 `Can't create handler ... that has not called Looper.prepare()`，补一次反射的 `Looper.prepareMainLooper()` 才通。
  * 缓存：冷路 122 个包 **2379ms**（sqlite 重写全部 PNG 约 0.4s + app_process 的 ART 启动约 1.5s），界面每次打开都会重新问图标，所以落一份 `webroot/icons/index.tsv`（`包名<TAB>显示名<TAB>相对路径`，没有图标的记空路径）并用 `app_icons.db` 的 mtime 当失效判据；快路 **321ms**。新装应用的包名不在缓存里 → 自动退回冷路。
  * 实测（真机，122 个第三方应用）：返回行数 **110 → 122**，以前没图标的那 12 个拿到真图标 + 中文名（"Android System SafetyCore"、"Android 开发者身份验证工具"、"Android System WebView"、"Google Play Services for AR"…），文件 0644。冷/快两路输出**内容一致**，只差行序（页面按包名取用，不影响）。
  * 代价与边界：dex 只补"桌面缓存里没有的"、一次最多 60 个；`app_process` 需要 root（本模块本来就在 root 下跑）。若某台机器上 `app_process` 不可用，这一段整体跳过，退回首字块 —— 不会让 `icons` 命令失败。

* **「关于 → 应用图标」自己报数**：`appAvatar` 给每张 `<img>` 记 `ok / fail / none / pending` 四态，关于页那一格显示 `加载 N · 失败 M · 无缓存 K（· 待加载 P）`。分开这三层才有意义 —— **ok**=真解码出来了；**fail**=PNG 请求到了但管理器读不出来（相对路径没被宿主的资源处理器解析，`/data/adb` 是 0700、管理器是 uid 10222，只能走它的 root 路径处理器）；**none**=桌面缓存里本来就没有这个应用（后台组件，正常）；**pending**=`loading=lazy` 还没进视口（不算失败）。
  * 自检（桩传输层 + 122 条假应用 + 故意指向不存在的 PNG）：分桶实测 `{fail:61, pending:61}`，关于页那一格显示 `加载 0 · 失败 61 · 无缓存 0 · 待加载 61` 并带说明 —— 也就是**以后"没图标"会自己说是哪一层坏**，不用再猜。
  * 已知代价：`loading=lazy` 让视口外的图保持 pending，滚动才补齐；刷新（`重新读取`）会重开 `iconAsked`、再跑一趟 ~414ms。

* **WebUI 控制台（Material 3 Expressive）**：模块自带 `webroot/index.html`，在支持 WebUI 的管理器里点「打开界面」即可使用。分五页——概览（后端 / 目标文件 / 可写性 / 上次写入 / 监听方式 / 守护进程 / 日志缓冲 / 伪装状态 + 界面自身的桥接信息）、常驻列表（在线编辑 `rules.txt`，实时统计有效包名与注释）、应用（生效列表与已安装第三方对照、搜索、只看未纳入、一键加入常驻）、日志（末尾 30~300 行按级别着色、清空缓冲、可选 5 秒自动刷新）、属性（当前值 / 期望值 / 是否一致）。界面为**单文件、不联网、不引外部库或字体**；配色支持跟随系统 / 浅色 / 深色，并可拖动色相滑杆实时改整套颜色。
* **命令层契约 `contract`**：新增一条命令，回两行 `api=1` 与 `commands=<清单>`。界面开机问一次，拿自己期望的号（`EXPECT_API`）比对：**对不上就横幅明说「界面与命令层不是同一版」，并在传输层拒绝一切写命令**（`save-rules` / `sync` / `props-apply` / `props-on` / `props-off` / `clear-log`），读命令仍然放行 —— 出问题时最需要的恰恰是还能看到现场。
  * 为什么需要：两个文件虽然打在同一个模块包里，但迭代时**可以只推其中一个**（推 `webroot/index.html` 不用重装）。以前这种不同版只在界面上表现为"某个值怪怪的"，没有任何一处会明说自己读错了格式。改任何命令的输出形状都要把号 +1（两侧同时改）。
  * 演示台留了 `?badapi=99` 当正控制：横幅、写被拒、读放行三件事都能离线验，不用把设备搞成不同版。实测 `?badapi=99` 下 `call('sync')` 报「命令层契约不匹配（界面要 api=1，命令层是 99），已拒绝写入」，而 `call('status')` 照常返回。
  * 「关于与自检」新增一格「命令层契约」，把两边的号照实写出来（不匹配时标「不匹配，已停写」）。

* **WebUI 命令层 `webui.sh`**：`status` / `env` / `rules` / `targets` / `apps` / `icons` / `log` / `clear-log` / `props` / `props-apply` / `props-on` / `props-off` / `save-rules` / `sync`，输出机器可读文本（`key=value` 或 TAB 分隔），复用 `lib/` 的探测与同步逻辑，界面不自行判定任何状态。文本内容一律以 base64 传入并先校验字符集，命令名与参数只参与比较、不拼进 shell。
* **开机属性伪装开关**：`/data/adb/ts_auto.props_off` 存在即表示关闭，`post-fs-data.sh` 据此跳过 `apply_resetprop`；只影响下一次开机，应用列表维护不受影响。覆盖安装模块不丢失，卸载时随其它文件一并清理。
* **只读提取脚本 `backends/teesim_list.awk`**：从 `config.json` 中取出 `profiles.default.apps` 供界面展示，定位方式与 `teesim.awk` 一致（逐级定位失败即不输出）。
* `lib/tools.sh` 新增 `find_base64()`：与 `find_awk` 同样以「实际执行一次解码」来判定可用性，避免只有 busybox 本体、没编译 applet 时被误判为可用。

* **取色跟随系统（Material You 种子色）**：界面色相与彩度由系统强调色推导。种子按 SystemUI 运行时 overlay（`/data/resource-cache/com.android.systemui-accent-*.frro`）→ `settings get secure theme_custom_color` → 壁纸提取色（`dumpsys wallpaper` 的 `colorValue0`）→ 平台默认 `system_accent1` 四级回退，取到哪一级在概览页「关于 → 取色 / 生效值」里照实写出（含换算后的 `#RRGGBB`、生效色相与彩度倍率）。深浅以系统实际算出的结果为准（`dumpsys uimode` 的 `mComputedNightMode`，退回 `mCurUiMode` 的夜间位，最后才是 WebView 媒体查询）。种子写法兼容 `#RRGGBB` / `#AARRGGBB` / `0x…` / 裸十六进制 / 十进制 ARGB——纯数字串按位数区分十六进制颜色与十进制整数，否则 `808080` 会被读成 `0x0C5490` 那种深蓝。近中性的种子只跟彩度、不跟色相（色相在此时没有意义）。**跟的是色相与彩度，各角色明度仍用界面内置档位**——模块侧拿不到系统算好的 12 组色调表，只能拿到 overlay 文件里那些 ARGB。

* **字体也跟随系统（从设备上读族名，不再写死）**：原先的栈是 `system-ui,-apple-system,"Segoe UI",Roboto,"Noto Sans CJK SC","Microsoft YaHei",sans-serif` —— 里面那几个**具体名字会抢在系统字体之前匹配上**。而 Chromium / WebView 在 Android 上有自己的一套字体映射（`sans-serif` 默认就是 Roboto），**根本不读框架的 `config_bodyFontFamily`**，所以 ROM 换了系统字体时界面会悄悄退回 Roboto。本机正是这一种：启用了 `org.lineageos.overlay.font.googlesansflex`（`cmd overlay dump` 里 `STATE_ENABLED`，目标包 `android`），系统各处都是 Google Sans Flex，只有这个 WebUI 是 Roboto。
  * 做法：`env` 新增 `sys_font` —— 找启用的字体 overlay → `pm path` 拿到它的 apk → 从 `resources.arsc` 里取出族名 → 用字体注册表（`/product/etc/fonts_customization.xml` 与 `/system/etc/fonts.xml` 的 `name="..."`）当白名单校验 → 界面把这个名字插到字体栈最前面。名字从设备上读，不写死，换 ROM 自动跟着变。
  * 三个坑都是实测踩到的：① `resources.arsc` 的字符串池是 UTF-16，不先 `tr -d '\000'` 就会吐出 `amily` / `edium` 这类碎片，看着"有输出"其实全废；② 逐个族名去 `grep` 验证要 160 次 fork，改成把注册表拼成一个白名单正则、一次 `grep -o -E "(...)"` 同时完成「取候选 + 验注册」；③ 「取最长」会挑到 `google-sans-flex-medium`（overlay 里 `config_bodyFontFamily` 与 `...FamilyMedium` 都在，medium 更长），那是 500 字重不是正文 —— 必须排掉 `-medium/-bold/-clock/-italic` 这类字重与用途别名。
  * 界面侧 `applyFont()` 只接受 `^[a-z][a-z0-9]*(-[a-z0-9]+)*$`（族名会进 CSS），实测 `x"; background: red` 被拒并退回 `system-ui, sans-serif`。默认栈也去掉了那几个写死的名字。
  * 代价：`env` 从 727ms 涨到 1045~1135ms（多 4 次外部命令：`cmd overlay list` 45ms、`pm path` 56ms、注册表与 arsc 各一条管道）。`env` 只在打开界面与点「重新读取」时问一次，不在任何轮询路径上。
  * 概览页「关于 → 外观」新增「字体」与「生效值」两格，直接写明用的是哪个族名、来自哪个 overlay 包；读不到时那格会照实写"WebView 默认"。
* **颜色与深浅一律强制跟随系统**：删掉顶栏的色相滑杆与深浅切换按钮，也删掉 `localStorage` 里那两份偏好。理由是这两处都在让人不小心把界面调成和系统不一样的东西 —— 而他连着几轮的抱怨正是"不像系统的一套颜色"。少两个按钮也让顶栏干净下来。
* **系统强调色新增第一优先来源：SystemUI 的运行时 overlay（`/data/resource-cache/*.frro`）**。原先的两级种子（`theme_custom_color` → 壁纸提取色）在本机**都是空的**：`settings get secure|global theme_custom_color` 均为 `null`，`dumpsys wallpaper` 是 `isColorExtracted=false`（壁纸是 SystemUI 自带的渐变），`cmd overlay list` 里也没有色彩类 overlay —— 于是界面一直落在兜底色上，而系统其实有一套在用的颜色，只是没人去读它。
  * 那份文件是 SystemUI 的 ColorService 生成的 Material You 调色板，**用户手选颜色时它同样会被重新生成**，所以它比任何 setting 都权威。实测本机解出来 `system_accent1` 是一条青蓝阶梯：`400_light #6898a4`、`600_light #356570`，色相 212–216、彩度 C≈.054。
  * 格式是 `FRRO` 魔数 + 28 字节头 + 定长条目，条目形态逐字节确认为 `12 08 08 1c 10 <varint ARGB>` 紧跟 `12 <len> 0a <len2> <资源名>`（值在前、名字在后成对交替，`08 1c` 是 `TYPE_INT_COLOR_ARGB8888`）。shell 里没有能读它的东西，所以 `env` 只做「取文件 + base64」（4KB），解析在界面里做。
  * **自检用的是明度单调性**：一条 tonal 阶梯从 0 到 1000 明度必须不回升，不单调或不足 8 档就整份丢掉、退回下一级来源。这条判据当场抓出我第一版按 mtime 取文件取错了 —— `-dynamic-` 那份比 `-accent-` 新，但它里面**根本没有 accent1 阶梯**（是派生出来的语义色），"解析出 94 条"看着挺多却一条都用不上。改成先要 `-accent-`、没有才退 `-dynamic-`。
  * 界面里 `--primary` 是 `oklch(49% .19*sat hue)`，而系统 `accent1_600` 是 L .48 C .055 —— 明度同档，所以 `sat = C/0.19` 就能对上。原先的映射 `0.35 + C/0.13*0.65` 会把本机 C=.054 算成 .62（实际彩度 .118，又是系统值的 2.2 倍），这正是"色相明明差不多、看着却不像一套"的来源，已改成直接比值。实测最终 `--primary = oklch(49% .0545 215)`。
* **应用图标与显示名**：`webui.sh icons <包名,...>` 从桌面自己的图标缓存（Launcher3 系的 `app_icons.db`，实测本机 775 行 / 130 个包 / 平均 25KB）导出 PNG 与显示名，界面在「应用」页显示**图标 + 应用名 + 包名**而不是光一串包名。设备上既没有 aapt 也没有 ImageMagick，从 APK 里抠资源这条路走不通，而这份缓存存的正是屏幕上那张图。取不到（快捷方式、系统组件、非 Launcher3 系桌面）时退成首字块，行仍然完整可读。
  * 一个包在缓存里往往有多行（每个 activity、每个快捷方式、每个微件各一张）。**只按组件名最短挑会选中快捷方式**——实测 `com.termux` 拿到的是 New session、`com.MobileTicket` 拿到的是本人车票。排序键改成三级：类名以包名开头 → 类名带点（也是真 activity）→ 都不是（快捷方式/微件，如 `new_session`、`VIEW_MY_DOWNLOADS`、`/1`），同级再按长度。改完实测拿到 Termux / 铁路12306 / Google Play 商店。
  * 内层子查询**不能先 `group by`**：那样 rank 还没参与选择就被折叠成任意一行，第一次改完仍是 New session，去掉才对上。
  * 走文件不走 base64：平均一张 25KB、base64 后 35KB，几十张就是几 MB 要从 root shell 里穿过一次 `exec`。PNG 落 `webroot/icons/` 由界面按相对路径引用，实测 10 个包 219ms、6 个 209ms（一次 sqlite3 调用整批处理；逐个查实测 44ms/次，120 个包要 5 秒以上）。
  * 包名逐个校验（只留 Android 包名字符集，并挡掉 `.`、`..`、`/`）后才进 SQL——它们同时也会被拼进 `writefile` 的路径参数。实测传 `bogus/../etc` 不会在模块目录下建出任何东西。
  * 先画行、后补图标：图标这一步慢或失败不该让整页应用列表等着。搜索同时匹配应用名与包名（列表上显示的是应用名，只搜包名会让人搜不到眼前看到的东西）。
* **常驻列表页把条目摊开**：编辑器里只有裸包名，看不出"这一条到底进没进目标列表"。编辑框下面新增一份「当前常驻项」清单，复用同一批图标与显示名，并把**没出现在目标列表里的**标成「未生效」（多半是还没同步，或该后端跳过了不可见应用）。实测演示数据 3 条全部生效故无标签；往基线里塞一条 `com.example.notinstalled` 后标签正确出现、计数从 3 变 4。
* **不像包名的行会当场报出来**：`rules.txt` 里一行写错（多个空格、结尾少个点、开头是点）不会报错，只会**静默地永远匹配不上任何应用**，而统计却把它算进「有效包名 N 条」。现在按 Android 包名形态（`.` 分段、每段以字母开头）校验，把可疑行的行号与内容列成一条警告。实测：干净文件时警告隐藏；塞入 `com.foo bar` / `not-a-package-` / `..leading` 后正确报「有 3 行不像包名」并逐条给出行号。

* **没有底栏：导航改成概览页上的四行入口（二级页下钻）**：底栏整条删掉，概览页 = 英雄卡 + 入口卡 + 同步链路/配置明细；入口卡的四行是 常驻列表 / 应用列表 / 运行日志 / 系统属性伪装，每行 图标 + 标题 + 实时副标题（常驻 N 条、生效 N · 第三方 M、缓冲 N 行、开机写入 开/关）+ 右侧箭头。点一行进入二级页，顶栏左侧出现返回箭头，内容区只有那一页的卡片。
  * 二级页的顶栏用 `position:sticky` 钉住 —— 返回箭头是那一屏唯一的出口，长列表滚到一半不能让它滚走；概览不钉，内容照常滚出去。二级页隐藏英雄卡，一屏只有标题 + 内容，卡片离顶栏补 8px。
  * 导航状态写在 hash 上（`#/over`、`#/rules`…），顶栏箭头、系统返回键、点入口三条路合成一条 `popstate`；为什么不能用 `pushState` 见下面「系统返回键在二级页什么都不做」那条。概览的滚动位置在下钻前记下、返回时还原；`history.scrollRestoration = 'manual'` 必须设 —— 浏览器默认的自动恢复会在 `popstate` 之后把还原抹成 0（实测 52 → 0）。
  * 过渡沿用上一版：下钻从右侧滑入、返回从左侧滑入（24px、200ms、opacity 0.9→1，WAAPI 在合成器上跑）；返回时英雄卡一起滑。整页滑动、遮罩、高度同步一概没有。
  * 实测（626×1000）：首页 1052px、可见面板恒为 1 个；下钻后 `hero` 隐藏、返回箭头出现、`history.state.page` 正确；返回还原滚动位置 52；从「应用」点 + 跳到常驻列表后返回落到应用列表（Back 语义）；连点两次同一入口不增加历史条数；五页溢出 0 项（对照能报 2 项）；文本对比度浅色最差 5.37、深色 5.73，0 项不达标；连点 8 次（90ms 间隔）逐帧 71 帧「0/2 个面板可见、遮罩出现」为 0。

* **概览页不再塞两张卡：把「关于」挪到版本号后面**〔这条做出的浮层后来并成了第五个二级页，见下面「「关于」从浮层并成第五个二级页」〕。量了一下才看清挤的根子不是间距，是一页塞了两张卡 —— 626×1463 下：英雄卡 114 + 运行状态 535 + **关于 437** + 页脚 34。「关于」一个人占了整屏 **30%**，而它全是桥接 / 身份 / 工具 / 取色 / 字体这类诊断信息。现在点英雄卡里的版本号打开它（浮层，`max-height:86vh` 可滚，点遮罩 / 点「关闭」/ 按 Esc 都能关），内容在打开前重画一次所以在哪一页点开都是最新的。
  * 腾出来的空间用来把剩下的卡放松，而不是留成空白：格子内边距 12→16、格子间距 12→16、组间距 16→20、卡片内边距 20→26。卡高 535 → **591**，占整屏 40%。
  * 放松后网格又掉成一列（2×250+16 正好卡在 516 的边界上），格子最小宽度 250→240 拉回两列，实测 249+249。
* **跟手拖拽切页，并顺手治了「底栏上下跳」**：原来是指尖抬起才翻页。现在五个页面横排成一条轨道，拖动时整条轨道跟着手指走，松手按位移（>30% 屏宽）或速度（>40px 且 <300ms）决定翻页还是弹回；到头了给 0.32 的阻尼。起点在输入框 / 可横向滚动容器 / 底栏里时不接管，竖向仍由浏览器自己滚（轨道上 `touch-action:pan-y`）。
  * 至于「底栏上下跳动」：量了五页，底栏的 `top` 一直是 1385、高 58，真正变的是**宽度**（296 ↔ 322，标签字数不同）。真正在跳的是**整页滚动** —— 切页时文档高度变了，滚动位置被夹回去，看起来像底栏在动。
  * 所以顺手把滚动模型换了：`body` 不再整页滚（`height:100dvh; overflow:hidden`），改成**每页自己滚**（`.panel{max-height:100%; overflow-y:auto}`）。这样切页不会再有滚动位置被夹回去，文档高度恒定，也给轨道提供了固定的裁切框。
  * 结构上踩了两个坑，都记在代码里：① 裁切和位移必须是**两个元素** —— 写成同一个时 `overflow:hidden` 会把自己的第 2~5 页一起裁掉，第 1 页看着正常、切过去一片空白；② 裁切也不能放在 `.wrap` 上，它有 16px 横向内边距，相邻页会从那 16px 里露出边。现在是 `.pager` 负责裁、`#track` 负责动。
  * 面板不再用 `hidden` 切显隐（那样没法跟手），非当前页只标 `aria-hidden`。实测：拖到 -100 / -250px 时轨道跟到位；松手落在 -568（第 2 页）；五页都落在 left≈29、宽 568；文档不产生滚动。
* **恢复整页滚动；横滑两页之间留 16px 间隙**：上一版把滚动改成"每页自己滚"是过头了 —— 英雄卡变成固定 chrome、页面不再整页滚，手感不对。现在 body 照常滚（英雄卡该滚走就滚走），面板不再内部滚动；轨道高度由 JS 同步成**当前页的高度**（不取最高那页，否则每页底下都拖一段空白），内容变化时用 `ResizeObserver` 跟上。横滑时相邻两页原来严丝合缝，现在轨道加 16px `gap`，位移按「页宽 + 间隙」算，拖动和吸附都用同一个步长。实测：切页后轨道高度分别等于各页高度（591 / 531 / 725 / 333 / 777）；松手吸附落在 −584（568 + 16）；五页都落在 left≈29；620px 高视口下文档高度随页变化（817~1063）且能滚。
* **卡顿：按手机上必然贵的三个原语下手**（桌面这边复现不出来：252→366 个节点、切页无长任务、滚动两帧 12ms，所以只能针对机制改）：① `.track` 上的 **`will-change:transform` 撤成按需** —— 常驻的话浏览器会把"五个全高页面"合成成一个巨大的图层，手机上滚动必掉帧；现在只在拖拽期间加，松手即撤。② 轨道高度**不再参与过渡** —— 原来 `transition:height` 每帧都要重排一次，比高度突变更伤。③ 给 `.panel` 加 `contain:layout paint`，改一页不会让其它四页跟着重排。另外 `syncTrackHeight()` 里读 `offsetHeight` 是强制重排，`ResizeObserver` 一次渲染可能连触发多次，所以合并到 rAF、并且高度没变就不写 style。
  * 顺带定了上一轮悬着的取舍：**切页统一滚回顶部**。整页滚动 + 每页高度不同，不回顶就会从长页切到短页时把滚动位置夹回去（那个"底栏跳一下"）。实测滚到 257 时切页 → 归 0。
* **卡顿（第二轮）：把三条路径都量了一遍，再压手机侧独有的开销**。滚动 / 横滑 / 切页逐项测：帧间隔 p50 **17ms**、p95 18ms（就是 vsync），横滑处理函数 **0ms**、切页同步耗时 **1ms** —— 桌面浏览器上三项都跑满帧，复现不出来，所以只能针对"手机独有"的那几类下手。
  * ① **底栏去掉投影**：固定定位 + 大范围 `box-shadow` 盖在滚动内容上，是安卓滚动掉帧的经典来源；它本来就有 1px 描边钉住边界，珠子不靠阴影分界。
  * ② **不再在拖拽里来回切 `will-change`**：一个"五个全高页面"的图层反复申请/释放，比不做更卡。位移本身就会触发合成层提升。
  * ③ **图标提取不再抢首帧**：切到应用页先把列表画出来，再在 `requestIdleCallback` 里跑那个 root 任务（sqlite 查询 + 写若干 PNG，手机上一两百毫秒起，抢在首帧里就是"卡一下"）。每批 120 → 40，单次停顿更短。
  * 复测：三项仍是 17ms / 0ms / 1ms，图标照常加载（6 张解码完成）。
* **卡片边界不清晰：给卡片单独一档边线**。量出来的原因在**浅色**这边 —— 原来的 `--outline-variant` 是 L85%，而页底是 L98.5%，两者对比只有约 **1.35:1**，亮屏上那根 1px 线几乎看不见（深色那边是 L42% 对 L19%，反倒清楚）。新增 `--card-line` 令牌（浅色 L79%、深色 L47%，两套 hex 回退同步补上），卡片与悬浮底栏都改用它。实测：浅色边线对页底 **1.86:1**、对卡面 1.75:1；深色 **2.71:1** / 2.53:1。
  * 量这件事本身也踩了一下：`getComputedStyle` 读回来仍是 `oklch(...)` 字符串，用正则抓数字当 RGB 会得到 157.85 这种荒唐比值 —— 改成往 canvas 画一个像素再 `getImageData` 取真值。
* **概览卡片去掉「运行状态」小标题**：下面「同步链路 / 配置与写入」已经是同级小标题，叠两层同样式的标签只是多一行、多一层没有信息的层级。卡高 591 → **561**。
* **左右切页卡顿：把合成层还回来**。上一轮我为了"别让图层太大"撤掉了 `.track` 的 `will-change:transform` —— 那是个误判：没有它，拖拽时每帧都要在**主线程**重绘整片（五个页面），手机上就是"左右切页卡"。轨道高度等于当前页高度（约 568×800 ≈ 1.8MB），常驻一层并不贵；**要点是常驻**，在拖拽里来回申请/释放图层反而更卡。
  * 同时把拖拽本身的三处浪费去掉：① 位移基准与步长在「锁定横向」的那一帧算一次，不再每帧读 `clientWidth`（布局查询）；② `touchmove` 可能比刷新还密，位移合并到 `requestAnimationFrame`，每帧只写一次 `transform`；③ 用 `translate3d` 明示走合成。实测逐帧位移 −40/−80/…/−240 连续跟手，松手吸附到 −584；边缘阻尼 200px → 64px、短拖 30px 都正常弹回。
* **左右切页卡：不再用 JS 写 transform，改成原生横向滚动 + scroll-snap**。前两轮我在这条路上试了「撤掉 will-change」「再加回 will-change」「translate3d」「touchmove 合并到 rAF」—— 都没救回来，因为**逐帧在主线程写 transform 这件事本身**在手机 WebView 上就慢。现在把 `.pager` 直接做成横向滚动容器（`overflow-x:auto` + `scroll-snap-type:x mandatory`，面板 `scroll-snap-align:start`），跟手、惯性、吸附全交给浏览器自己的合成路径，主线程一帧都不用干活；整块触摸处理代码（约 60 行）随之删掉，只留一个 `scroll` 监听把底栏和状态跟过去。
  * 结构上顺带简化：中间那层 `#track` 去掉了（它存在的唯一理由是给 JS 位移当载体）。实测 `scrollWidth` 2904 = 5×568 + 4×16；切页后 `scrollLeft` 1168 / 2336 正好对上；直接改 `scrollLeft` 模拟用户滑到第 5 页，底栏与 `S.tab` 都跟到了 `props`。
* **页面滑动与底栏动效有时差**：两处叠加 —— ① 底栏要等滚动停 90ms 才更新；② 更新后那一格的变色（220ms）与展开（340ms）还在路上，于是「页面已经到了、底栏还在半路」。现在滚动监听**跨过中点就立刻切状态**（实测滚动后 30ms 内底栏已跟上），底栏仍等停下再取数、再同步容器高度（中途改高度会让纵向位置抖）；并且用户自己滚的时候给底栏加 `is-tracking`、把过渡关掉 —— 点底栏切换不走这条路，动画照旧。
* **「还是不如 Opticon」：把 Compose 自带的三样东西补上**。对着它的源码比了一遍，差距不在布局，在**它每一块可点的 Surface 都自带的东西**我这边一样没有：
  * **按压反馈**：Compose 的 `Surface` 自带 ripple，网页这边点下去一直是"死"的。现在给 `.btn` / `.tab` / `.seg button` / `.icon-add` 加状态层（`::after` + `currentColor`）：按下**瞬间**出现、松开淡出，颜色自动跟着所在容器走；开关的 `::after` 是滑块本身，排除。
  * **弹簧动效**：Compose 走 `MotionScheme` 的弹簧，CSS 贝塞尔永远差一口气（起步与收尾没有过冲）。用 `linear()` 写了一条真正的阻尼振荡曲线（26 个采样点，峰值 1.06），Chrome 113+ 才支持 —— 不支持时整条声明作废、退回默认 ease，只是没那么弹，不会坏（已确认计算值里确实拿到 `linear(...)`）。
  * **形状档位对齐它的 `Shapes`**：8 / 12 / 16 / 20 / 28（原来是 8 / 10 / 14 / 18 / 20 / 24）。
* **抹掉最后三处「网页感」**：① `touch-action:manipulation` —— 不写的话浏览器每个点击都要等约 **300ms** 看是不是双击缩放，点哪儿都慢半拍（Compose 没这回事，这是"不如原生"最实的一刀）；② `user-select:none` —— 横滑时手指会把文字选中、冒出选择柄，是网页最明显的破绽（输入框、编辑框、日志台例外）；③ `overscroll-behavior:none` —— 划到头的回弹与发光也不要。
  * 顺带把「原生」这条路走到底试了一次：写了 Kotlin + Compose 的伴随 App（五页 + 悬浮药丸底栏，`dynamicLight/DarkColorScheme`、`PackageManager` 取图标、`HorizontalPager`），本机构建、装机、启动都验过（`Displayed +2s563ms`，无崩溃）—— 但**模块的「打开界面」按钮只能加载 `webroot/index.html`**，原生 UI 没有挂载点，所以它只能是另一个 App。既然要求"只能是模块"，这条路已撤回（提交 `2521c23` 是 revert），手机上的包也卸了。
* **按压反馈换成真 ripple**：上一版是"整块变亮"，没有起点，一眼能看出不是原生的。现在 `pointerdown` 时在**手指落点**插一个圆，直径取到最远角的两倍、扩满整块后淡出 —— 就是 Compose `Surface` 的那个效果。实测：在按钮 (20,12) 处按下，圆直径 183（按钮 111×38，最远角 91）、圆心正好落在按下的那一点，动画结束后节点自动移除。
* **底栏抽搐：选中项展开文字会让整条药丸在滑动中反复变宽变窄**。实测选中「常驻列表」时药丸 296→322，而它是 `left:50%` 居中的 —— 两边一起弹，看上去就是抽搐。改成**定宽图标 + 一个滑动的指示胶囊**：每格 52px，药丸永远 294 宽（五页实测都是 294）；胶囊的位置由**滚动进度连续插值**（位置 = scrollLeft / 页宽 × 格距），和页面同速，不是到点才跳。当前在哪一页改由顶栏大标题说（`概览 / 常驻列表 / 应用列表 / 运行日志 / 系统属性伪装`），小字那行仍是 `TS-AUTO-ADD · 设备 · Android 版本`。
  * 顺带修掉一处把我自己绊倒的错：`applyTab` 里写成了 `moveIndicator(i * TAB_PITCH)`，而 `i` 是 `showTab` 的局部变量 —— 整个 `showTab` 直接抛 ReferenceError，点底栏一下都切不了。另外 `applyTab` 会把指示胶囊拽回整格，滚动中的连续插值必须绕过它（`IN_SCROLL` 标记）。
* **底栏改成 M3 `NavigationBar` 的格子**：上一版为了消抽搐做成了纯图标，看着不像原生 —— 安卓原生底栏是**图标在上、文字在下、文字始终可见**，选中只多一圈图标后面的胶囊。现在照这个来：图标 24px、文字 11.5px 常驻、胶囊 52×32 正压在图标上（实测胶囊与图标盒的 y/高完全重合：15/32 对 15/32）；整条仍是定宽 324，滑动时不变胖瘦。窄屏 320 走媒体查询收一档（格子 52、胶囊 46），**步长改成按实际格子宽度算**（`tabPitch()`）—— 写死常数会在窄屏失配。
  * 顺带：当前页名仍在顶栏大标题里（`概览 / 常驻列表 / 应用列表 / 运行日志 / 系统属性伪装`），小字是 `TS-AUTO-ADD · 设备 · Android 版本`。
#### 优化

* **主页补一块「最近动态」，那 412 CSS px 的空白有了去处**：主页原先是英雄卡 + 一张「运行」（四格），最后一张卡下面空 **412 CSS px = 视口 975 的 42%**（逐行扫截图像素量的）。上一轮加的"短页居中"只把空白从下面挪到上下各一半，主页仍旧空 —— 因为这一屏缺的不是对齐，是内容。
  * 第三张卡给**最近 6 条日志**。它不另发命令：`ensure('over')` 一并把 `log` 拉回来，这一趟本来就是日志页要付的那一趟（`S.loaded` 认 need 不认 tab，之后进日志页不重复请求）。日志那一腿单独 `.catch()`：它只是主页的一块预览，不该让名单跟着画不出来。
  * **与日志页共用同一个 `logRow()`** —— 两处各写一遍行 DOM，时间列宽和级别图标就得各修一次。
  * 三条退路是在真页面里改状态再重画验的，不是看图猜：命令层没有 `log` → 整块 `hidden`、子节点 0、主页面板退回 208 高（不留空壳）；日志为空 → 「还没有日志 —— 模块只在开机与文件变化时写。」；读取失败 → 换成「日志读取失败，详见日志页」。有日志时 6 行 / 6 个图标、正文与 `S.log` 尾巴逐条一致。
  * `.home-recent .console{min-height:186px}`：日志只有两三行时这块会塌成一条，空白又跑回来。
  * 结果：主页空白 **412 → 56 CSS px**（417 宽，浅深两联横向溢出仍 0）。`tests/ui-shape.js` 加 7 条共 **79 条**；七条变异各红自己那条、还原后全绿。

* **板块分组从"一块底"改成 1px 描边**：后端页那张卡里两个板块（`config.json · default profile` 与 `keybox`）原本是 `--surface-highest` 的一块底，压在卡面上 —— 里面的 `md-outlined-text-field` 描边跟灰底糊在一起，11 个输入框连成一整块"看着像禁用态"的灰板。现在 `.grp` 无底色 + 1px `--outline-variant`，卡线仍旧用更深的 `--card-line`（一深一浅才不会读成双线）。`--block` 这个令牌同时下线：全文件只有 `.grp` 读它，留着就是死声明。
  * **加边框必须从内边距里扣掉那 1px**：`padding:var(--sp4)` → `calc(var(--sp4) - 1px)`，否则整块文字右移 1px、全站那条 41 的对齐线断掉。用 CDP 逐页量：后端页与属性页的板块标题左缘 **41.00**、正文左缘 **41.00**、偏移 **0px**，浅深两联一致。
  * 主页那张卡里只有一个板块，`.home-card .grp` 现在撤的是边框（原先撤底色）—— "一层卡里再套一个面就是盒中盒"这条判据没变。
  * `tests/ui-shape.js` 加 2 条（板块不吃底色、内边距扣 1px）。三条变异：`--block` 复活、内边距不扣 各红自己那条；把 `.grp` 改回底色**同时点亮两条** —— 它确实同时违反两条，不是断言重叠。
  * 417 / 360 / 320 × 浅 / 深，八页横向溢出仍全 0。

* **日志行归一：emoji 前缀换成四个统一图标，每行拆成三列对齐**：脚本在日志与状态描述里写 emoji 当级别前缀（扫 `module/**.{sh,awk}` 得到 **23 种**：⚠️🧩❌✅⛔ℹ️🚀🔄📝🧹🛠🔌📜🔍👀🎯🕒💡📁🔧📦🔁🔑）。界面照抄就等于在 Material 图标之外再养一套图形语言 —— 一个日志台里同时有 👀 和别的页的内联 SVG。
  * **只能在渲染侧做**：缓冲里已有的行早就带着 emoji 落盘了，改脚本只影响新行。`logParts()` 把一行拆成「时间 / 级别 / 正文」，`EMOJI_RE` 用 `\p{Extended_Pictographic}` 连变体选择符与 ZWJ 一起吃掉；级别仍走原来的关键词判据（`失败/超时/错误` → err，`警告/未能/不存在/未找到` → warn，`完成/就绪` → ok），带 emoji 但没命中关键词的算 info。提示条那侧加 `stripEmoji()`：`description` 是脚本写的 `✅ [...]`，而提示条自带 warn 图标。
  * **三列网格**：`.log-line{grid-template-columns:auto 16px minmax(0,1fr)}` —— 图标列恒占宽，没有级别的行也把正文对齐到同一条竖线；时间列 auto 由最长那条定宽。折行的正文不再顶到时间下面。`ok` 的图标从裸勾换成带圈的（`checkc`）：info/err 都是圆底，裸勾比它们轻一档。
  * 工具条从三行散着并成两行（分段器一行；自动刷新 + 刷新 + 清空一行），`刷新` 不再靠 `#btnLogRefresh{margin-left:auto}` 单独挂在上行右端。
  * **量具换成 CDP 钉死视口**：临时用 `--window-size=417,975 --force-device-scale-factor=2` 截的那张，布局视口其实是 **491**（截图仍旧 834 宽，所以右侧看着被切一刀）—— 一次性截图不能当验收。改用 `Emulation.setDeviceMetricsOverride` 钉到 417 后产出的主页，与之前的台架截图**逐字节相同**（md5 `713720d8…`）：说明原先那批"八页 0 溢出"本来就是在 417 上量的，结论没被推翻。这次多拿到的是「点名哪个元素越界」，以及 360/320 与深浅两联：**8 页 × {417, 360, 320} × {浅, 深} = 48 组，横向溢出全 0、越界元素 0 个**。
  * 26 条样本行（含真机 `webui.sh log 12` 的原样输出）喂进抽出来的 `logParts`：残留 emoji **0 行**，级别判定逐条对过。`tests/ui-shape.js` 加 7 条，共 **70 条**；六条新断言各做一次变异，每次都恰好只打断自己那一条、还原后全绿。

* **短页垂直居中 + 圆角同心**：功能菜单、Verified Boot、日志这类内容比一屏短的页，以前贴着顶栏、下面空一大片。现在除主页外的页在内容区里垂直居中（`.wrap.center{justify-content:safe center}`，内容超出时 safe 自动退回从顶部开始，不会被推到屏幕外）；主页保持顶部对齐 —— 英雄卡是这一屏的锚点，居中反而不像仪表盘。
  * **圆角同心**：板块色块 `.grp` 的圆角 16 → **11**。同心公式是「外卡 20（边框外沿）− 1px 边框 − 8px 间距（卡内边距 24 − 色块外扩 16）= 11」，16 会让两个圆角各转各的。逐页扫过其余嵌套（底栏 28 + 胶囊 6 间距 = 22 ✓、分段 20 + 满圆 ✓、头像/开关是圆形不适用），没有别的不同心。
  * 417 实测：功能页卡片 top 297 / bottom 621（上 245、到药丸上沿 201）；boot 页 329…602；日志 174…744；属性页内容 976 > 900，`safe` 让它仍旧从 60 开始；主页不动。横向溢出全 0。
  * `tests/ui-shape.js` 加 2 条（居中类只在非主页出现、`.grp` 圆角 = 11），共 **60 条**。

* **切页动效换成 Opticon 那套 `MotionScheme` 弹簧**：原来写死的 200ms `cubic-bezier(.2,0,0,1)` 比它快一档。现在时长与曲线取 `--d3` / `--e-spring`，弹簧参数不是凭手感编的 —— 从 Opticon 依赖的 `material3 1.5.0-alpha28` 字节码里读出 `MotionScheme.expressive`：spatial = `spring(ζ0.8, k380)`、effects = `spring(ζ1.0, k1600)`。`--e-spring` 换成前者前 340ms 的 `linear()` 采样（峰值 1.007 = 1.5% 过冲），切页的 WAAPI 直接吃这个令牌；老 WebView 用 `CSS.supports` 探一下，不认 `linear()` 就退回贝塞尔，不会因为曲线解析失败把切页弄坏。桌面 417 实测：`duration 340`、easing 是 `linear()`、药丸 top 26 帧恒 822、裁切类覆盖 22 帧后摘除。

* **移除「常驻列表」：名单只有目标文件本身**。起因是上一版的结论 —— 增量同步已经接管了"新装自动进、卸载自动出、你手工改的不动"，常驻那一层只剩两件事，而两件都可以用目标文件本身表达。现在：
  * **名单 = 目标文件**（`config.json` 的 `profiles.default.apps` / `target.txt`）。界面上的「常驻列表」页、应用页的「+」加号、「常驻 N 条」、`webui.sh` 的 `rules` / `save-rules` 两条命令全部删掉；`rules.txt` 这个文件不再创建、不再读取、不再监听。
  * **首次安装种一次种子**：目标文件还没有内容、且没有任何基线时，第一次同步把谷歌三件套（`com.android.vending` / `com.google.android.gms` / `com.google.android.gsf`）写进去。它们是**系统应用**，`pm list packages -3` 看不到，不种就永远进不了名单。种完这一次之后，你从名单里删掉它们也不会再被加回来。
  * **契约号升到 `api=2`**：命令清单少了 `rules` / `save-rules``、`status` 少了 `rules_file` / `rules_exists` 两个字段 —— 这是形状变化，按规矩升号，界面与命令层版本不匹配时仍会横幅 + 停写。
  * 仍然保留的语义：手动删掉的（墓碑）不加回来；卸载后重装算新装；手工加进目标文件的条目保留，但那个应用"装了又卸"之后会被当正常卸载删掉（以前是常驻替它兜底 —— 现在要跨装卸周期保留，就靠"卸载后再装一次会重新加入"这条）。
  * 自检 `tests/sync-incremental.sh` 按新算法重写：**12 个场景 / 27 条断言**（首次安装种种子、目标非空不种、新装进/卸载出、手工条目保留、手动删除不回来、卸载后重装回来、手动加回撤墓碑、已装为空、清空文件、种子只种一次、状态记输入）。
  * 真机：目标 125 条在部署后**没有变化**（`config.json` sha `7e694b1e1855` 前后逐位相同）；`contract` 回 `api=2`、`targets` 仍 125；守护进程重启后只有一个监视进程。
  * 过程中我自己把界面文件切坏过一次：删函数用的是"找行首 `}`"的启发式，遇到 `countRules(){ ... }` 这种**单行函数**会一路吃到后面。已恢复后改用括号深度扫描（跳过字符串与注释），并在**写盘前**把脚本塞进 `vm.Script` 过一遍语法、再断言旧标识符清零 —— 壳层那次同类事故（`sh -n` 通过、但留下两行 `c` 碎片）是**真机冒烟**（`webui.sh contract`）才抓到的，说明 `sh -n` 挡不住"多了一条命令"这种坏法。


* **界面把「你手动排除的」和「没生效的」分开了**：墓碑功能带出来一个界面谎言 —— 一个被手动从名单里删掉的常驻条目，在常驻列表页上显示的是「未生效」，读起来像故障，其实是你的决定。现在命令层新增 `excluded`（一行一个被排除的包名），界面把这类行标成 **「已排除」** 并写明恢复办法（删掉后端的 `.ts_removed`，或把它从常驻删掉再加回）；真正的「未生效」仍是原来的含义。常驻页的统计行在有排除项时多一段「已排除 N 条」。
  * 新命令**不需要升契约号**：界面先从契约的 `commands` 清单里看有没有 `excluded`，没有就整段不问、退化成只显示「未生效」—— 这正是当初留 `commands` 的用途（加能力不用改号，缺能力不会崩）。实测：契约里去掉 `excluded` 时一次都不发这条命令，加上时发 1 次。
  * 自检（桩状态 + 三条常驻项分别"在名单里 / 被排除 / 未生效"）：三行标签实测为 `(无) / 已排除 / 未生效`；把排除集合清空后第二行变回「未生效」。真机 `webui.sh excluded` 写入两条后回两行、清掉回 0 行。
  * 顺带补一个漏：`cmd_excluded` 一开始没先 `detect_backend`，导致 `$ST_REMOVED` 是空的、命令恒回空 —— 真机一测就露馅（写入两条仍回空），补上探测后正常。
  * 也顺手把 CHANGELOG 里被反复插入撞出来的**三个 `#### 优化` 头并回一个**（同一节里不该有同名小节）。


* **同步改成增量：只加新装的、只删卸掉的，手动删掉的绝不再加回来**：以前每次同步都是「常驻 ∪ 已装第三方」**整份重写**目标文件 —— 手工作任何修改都会被抹掉，而且从名单里删掉一个已装的包，下一次同步又给你加回来。现在在**当前目标文件的基础上**做集合运算：
  * **加入**当前已装的全部、当前常驻的全部
  * **删除**「上次装了、这次没了」且不在常驻里的，以及「上次在常驻、这次撤出」且没装的；删除是对集合做 `delete`，**文件里本来没有就是空操作**
  * **手动删除 = 排除**：我们上次写进去、这次文件里没有了的条目记进**墓碑**（`.ts_removed`），**下次不再加回来**。墓碑在两种情况下自动撤销：① 它又出现在文件里（你把它加回去了）② 那个应用**被卸载过**（所以"卸载后重装"会当作新安装重新加入，正是要的行为）
  * 首次运行 / 刚升级（没有上次状态）时只做并集、不删也不记墓碑 —— 那时分不清"已卸载"和"你删的"，宁可贵一点
  * 状态撑在四个文件里：`.ts_installed_last` / `.ts_rules_last`（上次的已装与常驻）、`.ts_written_last`（上次写进去的完整列表，用来识别"是你删的"）、`.ts_removed`（墓碑）。`build_app_list` 先写 `*.new`，`sync_*` **写入成功后**才提交：失败不推进，否则那次卸载事件会被当成"已处理"而永远漏掉。卸载时一并清理
  * 自检 `tests/sync-incremental.sh`（CI 里一步）：十条语义 / 21 条断言 —— 首次运行并集、新装加入、卸载删除、卸载但在常驻里保留、人工新增保留且下一轮仍在、撤出常驻且未安装则删除、**手动删除不回来**、**卸载后重装会回来**、**手动加回撤销墓碑**、以及"状态文件记的是输入与写入清单而不是最终列表"。**四处变异都验过会红**（不记手动删除 → 4 条红；卸载不清墓碑 → 2 条红；加回不撤墓碑 → 2 条红；不保留文件现有条目 → 4 条红），并在**设备上（mksh + toybox awk）跑同一份**全绿
  * 真机端到端（本机 config.json，测完已恢复到与备份**逐位相同**的 sha `7e694b1e1855`）：先跑一趟立基线（`.ts_written_last` 125 条 = 目标 125 条）→ 手动从名单删掉 `ai.x.grok` → 目标 124**且两趟 sync 都不再加回来**、墓碑里出现它 → 把备份放回去再 sync → 目标回 125、**墓碑自动清空**、sha 与测试前逐位相同
  * 代价说明：这条改的是**语义**不是省 CPU（那趟仍要 `cmd package` 重算，靠指纹门拦重复；实测白跑只占 2.6%，所以没动开销那条路）

* **开机那趟"没变化"也要记一行**：`do_sync` 在指纹一致时是直接 `return 0` 的，什么都不记 —— 于是日志里 `🚀 开机完成（等了 12 秒），执行首次同步` 后面一片空白，读的人分不清是卡住了、没跑、还是跑了但没变化。**本机 10-28 10:37 重启后正是这一种**（现算指纹与 `.ts_fingerprint` 相同）。现在记 `ℹ️ 源数据与上次一致（指纹 N），跳过同步`。
  * 测的是设备上那份函数（`sed` 抽出 `get_source_fingerprint` + `do_sync` 原样 eval，桩掉 `log_info`/`run_sync`）：一致 → 只记跳过、不碰写盘；不一致 → 记开始、调 `run_sync`、把新指纹存回。第一版测试作废过一次：只抽了 `do_sync`，`get_source_fingerprint` 找不到，两种情形都掉进"开始同步"，看着像通过其实什么都没测。

* **守护进程的运行时文件不再人人可写**：框架调 `service.sh` 时不带 umask，实测本机 `.ts_daemon_pids.list` 与 `.ts_fingerprint` 落成 **0666** —— 前者是"下次开机要 kill 哪些 PID"的名单。现在 `service.sh` 开头 `umask 077`（`customize.sh:50` 安装时本来就是 077，同一模块不该两套文件两种权限），设备上已存在的那两个也当场收成 0600；验证：`umask 077` 下新建文件实测 `-rw-------`。
  * **`webui.sh` 故意没加**：它导出的 `webroot/icons/*.png` 现在是 0644，而管理器到底怎么读到它们的（打开时把 webroot 复制出去，还是就地读）没有实测过 —— 没验过之前把 022 收紧成 077 有可能直接把图标弄黑。这条留在"待验"。

* **同步"什么都没写"这种情况以前在日志里是隐形的**：`do_sync` 的 `case` 只记 `rc=0`（落盘完成）和 `rc=2`（失败），`rc=1`（内容一致、未落盘）**一行都不记**。界面上倒是分得清（`webui.sh sync` 回 `rc=`，前端会显示"内容一致，无需写入"），所以只有守护进程的日志缺这一格 —— 想知道"有多少趟同步是白跑的"只能靠减法：本机 45 天日志里 `开始=266 / 落盘=258 / 失败=1`，推出白跑 **7 趟（2.6%）**。现在直接记 `ℹ️ 列表内容一致，本次未落盘`，这个问题下次能直接读，不用算。
  * **这条测量顺带否掉了一个"优化"**：本来打算把变更指纹从"全部包名"收窄到"只有第三方"，因为 `packages.list` 里系统包一变就整趟重跑（约 16–20 次 fork + 一次 `cmd package` binder 调用）。实测本机 45 天：白跑只占 2.6%，而一次同步整趟 <1 秒（日志里"开始"与"完成"同一秒），266 趟 ÷ 45 天 ≈ 6 趟/天。**收益 2.6%、代价是"漏同步"的风险**（`-3 -u` 的口径与按 uid 过滤 packages.list 不完全等价），所以不做。同理，批量安装下的 trailing-edge 合并也不做：每趟列表确实变了，合并只是少写几次中间态。
  * 生效时机：`service.sh` 由框架在开机时执行，**下一次开机才用新代码**（本次只把文件放到位，没有在现场重启守护，避免半路换监）。

* **监听挂了要能自己说（重启留痕 + 指数退避）**：`service.sh` 的监听循环以前是无声的 `sleep 3` 死循环 —— 监视起不来（watch 数超限、目录被卸载、参数不被接受）时日志里一个字都不会多，表现就是"装了应用但列表不动"，而排查的人只看到最后一行"守护进程就绪"。现在记连续退出次数，第 2 次起 `log_warn` 一条写明"这段时间的安装/卸载不会自动进列表"，退避 **3→6→12→24→48→60 秒封顶**；活过 `WATCH_ALIVE`（10 秒）算正常一轮、计数清零。
  * 公式抽成 `lib/watch.sh` 里的纯函数 `next_backoff`，`tests/watch-backoff.sh` 直接 source 这一份逐档断言，并加了两条 grep 断言防止有人把公式内联回 `service.sh`（"一处来源 + 一条比对判据"）；CI 新增一步 `Watcher Backoff Self-Test`。
  * **第一版公式写错，是被这条自检当场抓出的**：`3 << (fails-2)` 配一条 `>=5 直接 60` 的特例，实测序列是 `3 3 6 12 60` —— 注释里写的 24/48 两档根本不存在。改完再跑才对上 `3 6 12 24 48 60`。
  * 自检本身也验过会红：把 `<<` 的位数改一档 → 退出码 1；把公式内联回 `service.sh` → 退出码 1；还原 → 0。（中途差点被自己骗了：`sh tests/... | tail` 之后取 `$?` 拿到的是 `tail` 的退码，显示 0 —— 去掉管道才是真的 1。）

* **安全区优先取宿主给的数**：KernelSU 把安全区做成一张 CSS 让页面去取（`/internal/insets.css`，实测本机管理器 v3.3.1 的 dex 里有这个路径，内容是 `--safe-area-inset-top/bottom/left/right` 与派生的 `--window-inset-*`）。界面在认出桥是 ksu 时请求它，`--inset-top` / `--inset-bottom` 改成 `var(--window-inset-top, env(safe-area-inset-top))` —— 宿主给了就用宿主的，没给（别的宿主、或该文件取不到）退 `env()`。「关于与自检」新增一格「安全区留白」，写出当前上下留白像素与**来源**（宿主 insets.css / env()）。正控制：注入 `--window-inset-top:24px` 后 `--inset-top` 解析为 24px，撤掉后回落到 env()。

* **「关于」从浮层并成第五个二级页**：入口卡里五行看着一样、点下去不一样 —— 四行走 `goTab` + hash + 返回箭头，「关于」开的是 `.dialog` 浮层（没有返回箭头、不进 hash、Escape 是"关掉"而不是"返回"，而且它已经改了 `location.hash` 那套导航，浮层是那一套之外的例外）。现在 `#/about` 就是第五个二级页：`PAGES` / `TAB_LABEL`（标题「关于与自检」）/ hash 正则 / `renderAll` 各加一格，入口行从 `data-open` 改回 `data-go`，`openAbout` 与浮层那三条接线（关闭按钮 / 点遮罩 / Escape）整块删掉，残留计数 `aboutDlg`/`openAbout`/`aboutClose`/`aboutTitle`/`data-open` 全部 0。
  * 内容装进 `.card.panel`（和其它页同一张卡的待遇），所以板块底色回到默认的"卡面抬一档"（1.143 深 / 1.116 浅），`.sheet` 里那条 `--block` 覆盖随之删掉 —— 浮层内不再有 `.grp`，留着就是死规则。
  * `ensure('about')` 显式不取数：那一页全是界面自检（status / env / 取色 / 桥接），基础链已经取过。**不写这一条会被原来那条三元当成 `props` 去读属性表** —— 页面表从 5 变 6 之后，"其它都走 props"这个隐含假设就不成立了。
  * 概览也不再顺手重画「关于」（以前浮层要随时可开，所以画概览就得连它一起画）。
  * 实测（走真实那条路，点入口行而不是改 hash）：`data-go=about` → hash `#/about`、概览面板隐藏、标题「关于与自检」、返回箭头出现、英雄卡与设备行隐藏、顶栏 `sticky`、两块各 2 列、文字左缘 41；点返回 → `#/over`、箭头消失、标题回「概览」。
  * 复扫：**4 个宽度 × 6 页溢出全 0**（320/360/417/626）；触控六页 self<48 只在日志页那 2 个相邻分段（47，邻居接住）、cov<48 全 0；「关于」页 1 个可点控件（返回）48 见方。
  * 顺带修掉旧标记里 `.dialog` 没闭合就撞上 `</main>` 的问题（以前靠浏览器隐式补闭合）。

* **板块各一块底（他点的这一条，收回"去掉填充面"里板块那一层）**：分列之后一个板块里挤着 8 个键值，只靠 12/20 的间距分组，读不出哪儿是一组。给 `.grp` 一块底色：卡面上用 `--surface-high`（与卡面比 **1.143** 深色 / **1.116** 浅色），浮层本身已经是 `surface-high`，所以里面改用 `--surface-highest`（1.143 / 1.092）—— 两处与"页底 vs 卡面"那档 1.118/1.11 同量级，也就是他验收过的那一步。
  * 底色定义在 `:root` 而不是 `.grp` 上：写在 `.grp` 上会**盖掉**浮层那条覆盖（自定义属性也是元素自己的声明赢过继承），实测色块和浮层同色、等于没加 —— 这条是靠"量色块 vs 它所在面"的读数 1.000 抓到并当场改掉的。
  * **文字左缘不许因为加底色而挪位**：色块用负外边距往外铺 12、内边距补回 12，所以块从 x=29 起、文字仍然精确落在 41（全站那一条内容左缘）。板块之间外距 20 > 块内 12，符合"外距不小于内距"。
  * 射程就到这里：格子内部、图标、入口行仍然不着色（概览填充面 7 → 9，多的就是这两块；「当前常驻项」不是 `.grp`，不受影响）。
  * 文字对比度复核：块上 46 个文本节点最差 **5.733（深）/ 5.368（浅）**，全页最低仍是英雄卡那个数字 5.54（浅色），未被这次改动拉低。
  * 扫描器跟着修了一条：负外边距的"故意出血"以前被 PARENT 规则报成溢出。现在按算术放行 —— **只能渗到它画在哪张面上的那层内边距为止**（从父往上累加 padding，遇到有底色的祖先就停）。第一版我漏了"停在有底色那层"，结果 `bust=5`（把色块钉成右边出血 40px，而卡内边距只有 24）也不报，是条没牙的规则；补上后它报 `超出=40 可出血=24`。320/360/417/626 × 5 页现在全 0。

* **英雄卡的操作行不再靠"随机换行"**：`.hero-actions` 原来是挂在数字那行尾巴上的 `margin-left:auto`，装得下就同排、装不下就换行。本机 417 装不下（数字块 + 两个按钮要 386，内容宽 335），换行后两键右对齐，**左边空出 98px** —— 那一行看着像没排完。现在写死成"操作行自己一行、两键等宽"：417 下每键 164、左缘 41 与其它内容同一条线；宽屏用 `max-width:340` 收到右侧，所以两种宽度下按钮的物理尺寸几乎一样，布局也不再取决于会不会换行。
  * 代价（写明）：**宽屏（平板 / 横屏，≥470 一类）英雄卡高 115 → 165**。本机不受影响（本来就换行，165 不变）。选确定性而不是给宽屏留一条同排路径，理由是同排的临界点会随文案长度移动（真机副标题「常驻 3 · 第三方 122 · 守护进程 1 个」比演示数据长），一条按像素定的断点迟早会翻脸。
  * 复扫：417 / 626 概览溢出 0 项；触控 self<48 仍是 2、48 带内死点仍是 0；字号 6 档 / 字重 4 档 / 左缘三处仍是 41 / 填充面 7，全部未动。

* **每个板块分两列（`--cell` 从来没被设过）**：`.grid` 写的是 `minmax(min(var(--cell,240px),100%),1fr)`，而 `--cell` 全站没有一处赋值 —— 于是永远走 240 的兜底，本机内容宽只有 335，**四个板块（同步链路 / 配置与写入 / 界面自检 / 外观）全部排成一列**。设成 150 之后每板块两列（列宽 158，对话框里 167）。
  * 宽度是按**真机 dump 回来的字符串**量的，不是按演示数据：值最宽的是「上次写入」那行时间 142，放得进 158；被挤的是注释行（日志缓冲 180、目标文件 169、关于页的说明 204~298）。
  * 注释行原来是 `white-space:nowrap` + `text-overflow:ellipsis`，一列变两列就把路径切成 `/data/adb/teesim/conf…`。改成换行，并且**在每个 `/` 后面插一个零宽断行机会**（`title` 仍给原文）—— 只靠 `overflow-wrap:anywhere` 会从单词中间劈开，实测断成 `config.js` + `on`。改完 `/data/adb/teesim/` + `config.json` 两行，文件名整块不断。
  * 断言：每条注释「去掉零宽字符后 == 自己的 title」，5/5 通过；417 下 5 页 CLIP 0 项。  * 顺带修了扫描器自己的一条假阳性：CLIP 那条原先只看元素盒与文字宽度，日志台里 `360 下 2px` 被报成"字被裁"，而容器 `scrollWidth == clientWidth`（压根没有横向滚动条，那 2px 是 emoji 前进取整）。现在 CLIP 与 VIEWPORT 用同一条规则：**滚动容器里的内容不算溢出**（那是设计，能滚）。合成正控制仍然报 `textW=224 cw=60`，所以这条不是把阈值放宽。


  * 高度收益（417 实测）：状态明细卡 **641 → 429**（−212），「关于」浮层 **753 → 576**（−177）；入口卡 337 不变（它是列表不是网格）。
  * **「当前常驻项」不跟着分**：那一格是图标 38 + 间距 12 + 包名，真机最长的 `com.google.android.gsf` 在 12px 等宽下要 158 → 一格 208，两列要 436，而可用宽度 335 —— 分不开，硬分只会把包名劈成两行。这条按算术留着（`#rulesResolved .grid{--cell:240px}`）。

* **字号七档收进令牌，并删掉一条永不触发的断点**：`:root` 新增 `--fs11/--fs12/--fs13/--fs14/--fs16/--fs22/--fs38`，44 处 `font-size:NNpx` 字面量全部改走令牌；改完文件里 `font-size:` 后面只剩 `var(--fsNN)`（脚本当场打印残留字面量 = 0）。以前 `:root` 里只有 `--sp*`，「写进 :root，下一轮就不会自创 12.5」那一步其实一直没做。
  * 顺手清掉两处自创档位：`@media (max-width:390px)` 把 38→30、22→18 —— 本机 417，这条**永远不触发**，而它自创的两档也不在七档里，整条删掉；对话框标题 `.sheet h3` 的 18px 是第八档，落到 16（标题行高 24 → 22，这是本轮唯一一处肉眼可见的改动）。
  * 复扫：417 下概览实际渲染 6 档（12/13/14/16/22/38）、字重 400/500/600/700 四档，与声明一致。

* **溢出扫描的 CLIP 规则改用 Range 量文字**：原先写的是 `scrollWidth > clientWidth`，而可点区那种伪元素不是 `children`，却会把 `scrollWidth` 撑大 —— 于是 `.switch` 被报成「字被裁」（sw=45 cw=42），那是假阳性。现在量文字自身的排版宽度（`Range.getBoundingClientRect()`），并配一条**合成**正控制：造一个 60px 宽、装 224px 文本的叶子节点，规则必须报它。上一版正控制借的是界面里的 `.path-v`，而它在演示数据下 0×0（压根没排版），对照等于没跑。

* **图标阶位与线宽统一，聚焦不再抖一下**：
  * 图标原来自 16/17/18/20/22/24 六种宽度里随手取。现在定成一阶：**导航与列表 24、chevron 20、行内按钮 18、小件 16** —— 入口图标 22 → 24、按钮内图标 17 → 18（chevron 20、返回 24、banner 18、加号 16 本来就在阶上）。
  * 线宽：卡片/入口行/加号/描边按钮原先是 1px 与 1.5px 混用，统一 **1px**；开关 2px 与 spinner 2.5px 保留（那是部件自身的比例，不是容器边线）。
  * **输入框聚焦不再改 `border-width`**：原来 1.5 → 2.5，控件会瞬间长高 **2px**、下面的内容整体下移 2px（点一下搜索框整页抖一下）。现在 border 恒 1px，聚焦加一圈同色 `box-shadow: 0 0 0 1px`（视觉 2px，布局零位移）。实测：聚焦前后 `rulesBox` 高度都是 180，**位移 0px**。
  * 复扫：626 与 320 溢出 0 项；浅色文本对比度最低 5.54、0 项不达标。

* **卡与卡之间不小于卡内边距**：原来卡片间距 16、卡内边距 24 —— 外距比内距还小，两张卡看起来比它们自己的内容还"亲"，版面就显得局促。间距统一到 **24**（`wrap` 的 gap 与概览里两张卡的间距），复量 hero→入口卡、入口卡→状态卡都是 **24**，与卡内边距同值；626 内容 987px 仍不滚，320 溢出 0 项。

* **字号收到七档、字重去掉 800**：全页原来有 **15 个不同字号**（10.5 / 11.5 / 12 / 12.5 / 13 / 13.5 / 14 / 14.5 / 15 / 16 / 17 / 18 / 22 / 30 / 38）和 5 档字重。同一屏里 12 与 12.5 并排，肉眼分不出来，只会觉得"没对齐"。收成 **11 / 12 / 13 / 14 / 16 / 22 / 38**（断点里另有 18 与 30 两个显示档），字重只留 400 / 500 / 600 / 700 —— 大数字从 800 降到 700，页面安静一档。阶位写进 `:root` 的注释，下一轮别再随手加 12.5。
  * 实测：hero 114 → 115、入口卡 312 → 337（副标题 11.5 → 12 让每行长 0.5px，五行累计 +25）、概览仍 1000px 不滚；626 溢出 0 项。

* **颜色层次：卡面与页底拉开一档**。以前卡面/页底只有 **1.07（深）/ 1.06（浅）**，卡几乎不像卡，全靠发丝线钉边界。改法是把页底压深、卡面保持：深色 `--surface` 19% → **16.5%**（实测 sRGB `#0d0e11`），浅色 98.5% → **99.2%**（`#fbfcff`），浅色卡面 96.5% → **95.6%**（`#eff0f4`）。复量：**1.12（深）/ 1.11（浅）**，进到 M3 常见的 1.1~1.2 区间。
  * 连带把浅色发丝线从 79% 收到 **77.5%**：卡面变深后 `lineVsCard` 从 1.75 掉到 1.71，收一档拉回 **1.79**（`lineVsPage` 1.98）。
  * 三套 hex 回退（`@supports not oklch`）同步改写，免得老引擎上还是旧的两档。
  * 复扫：626 与 320 溢出 0 项；文本对比度浅色最低 **5.54**、深色 **7.31**（属性页那处），0 项不达标 —— 页底变深让"页面上"的字更清楚，卡面上的字掉了 0.15，仍远高于 AA。

* **把三张卡收到同一条网格上**：精致感最先崩在"缩进线不止一条"。量出来以前是三条 —— 英雄卡内容在 **46**、入口行的图标在 **50**、状态卡的标签/组标题在 **56**，右边箭头停在 556 而卡片内容右缘是 570。改法：入口行改成通栏（行自己左右留 `sp6`，`overflow:hidden` 把悬停底色裁进卡片圆角）、英雄卡左右内边距从 `sp4` 提到 `sp6`。复量：**四条线全部落到 54**（徽章 / 数字 / 状态标签 / 入口图标），箭头右缘与卡片内容右缘对齐在 572。
  * 间距刻度里唯一的非 4 倍数 `--sp6: 26px` 收到 **24**（卡片内边距随之 26 → 24，页面高度不变）。
  * 分组标题从 `11.5px/700 + 0.7px 字距 + uppercase` 改成 `12px/600 + 0.1px` —— 中文不吃 `uppercase`，`.7px` 字距只会显得松。
  * 复扫：626 溢出 0 项、hero 不换行（114px）、浅色对比度 0 项不达标。

* **二级页不再重复设备行、概览不再以说明收尾**：
  * 二级页原来顶栏是「设备行 + 标题」两层，而进到某一页之后那一行只是重复概览的身份 —— 现在只留大标题，顶栏高度 **52**（改前是设备行 + 标题两层）。`.kicker` 自带 `display:block` 会盖掉 `hidden` 属性，所以补了一条显式规则（跟 `.back` 同一个坑）。
  * 概览底部那句「模块只在开机与文件变化时同步…」是解释不是数据，留在卡片末尾只会拖着两条小字收尾；搬到「关于」的最底部。概览的状态卡 **469 → 403**。
  * 复扫：626 溢出 0 项（概览与属性页）、浅色对比度 0 项不达标（最差仍是那处按钮文字 5.69）。

* **状态栏那条缝：查清了来源，这次改成让页面自己画**。先确认它到底是谁画的 —— `Theme.KernelSU.WebUI` 继承 `Theme.KernelSU`，两者的资源表里**都没有** `statusBarColor`、也**没有** `windowBackground`（`aapt2 dump resources` 逐条看），所以那条缝不是任何"颜色属性"，而是宿主窗口自己的底色：管理器的调色板。而页面底色是从系统强调色推出来的（`--surface` = L19% × 强调色彩的色相/彩度）—— 两个来源，永远差一档，改 CSS 是改不到的。唯一能让它们同色的是让页面画到状态栏**下面**：调宿主暴露的 `BRIDGE.enableEdgeToEdge(true)`，把它的让位 padding 归零，背景就由页面画（`body` 的 `--surface`），那条缝于是和页面同色。内容位置不变 —— `appbar` 的 `padding-top` 与 `.wrap` 的 `padding-bottom` 都吃 `env(safe-area-inset-*)`，而 viewport 早就是 `viewport-fit=cover`。**真机实测（2026-10-27）三样都过**：状态栏那条与页面同色；顶栏没有被状态栏压住（`env(safe-area-inset-top)` 在 edge-to-edge 下确实有值）；底部没有再出现手势把手 —— 上次担心的那根白色短横条这次没有。

* **再去掉三处"面"与噪音**：
  * **入口图标不再垫底盘**：五个 36px 的填色方块（`surface-high`）一屏排开，是入口卡里最后的"面"。去掉之后就是 M3 列表项的样子 —— 24px 格子里放 22px 图标、颜色 `on-variant`，层级靠标题拉。填充面 **5 → 0**；入口行距不变（58.8px —— 24px 图标仍小于两行文字块的高度），所以这一刀只减噪、不省高度。
  * **版本号从胶囊降成单调文字**：「关于」已经有单独一行入口，英雄卡里再挂一个 32px 的可点胶囊只是多一个"面"和一个容易误触的小目标。改成 `<span class="ver mono">`、不再可点，hero 高度 **122 → 114**，`.chip` 那三条 CSS 与 `verChip` 的点击监听一并删掉（全站只剩这一处用 chip）。
  * **kicker 不再全大写 + 字距**：`text-transform:uppercase` + `.5px` 字距 + 600 字重 → 混合大小写、`.1px`、500。那一行是全屏最吵的东西，而它只是设备注脚；安静下来之后大标题才是唯一重心。
  * 复扫：626 与 320 溢出 0 项，对比度 0 项不达标（浅色最差仍是 5.69 那处按钮文字）；hero 在 626 下不再被判为换行（`wrapped:false`）。

* **拿掉状态卡的 8 个填充格**：概览一屏原来有 3 个面板 + 8 个灰底格子（后端 / 事件监听 / 守护进程 / 日志缓冲 / 常驻 / 目标文件 / 上次写入 / 属性伪装）+ 5 个图标方块，卡片面积占整页 71% —— 卡片里再套盒子，看着碎。填充格改成无底色两列（列间 `sp5`）：填充面 **8 → 0**，概览页高 **1116 → 1000**（一屏放得下）、状态卡 **469 → 425**。
  * 先试过给每格加一条发丝线做分隔，看截图发现两列的格子高度天然不同（「日志缓冲」比「守护进程」多一行小字），线是**参差**的 —— 反而更乱，所以线也不要，分层只靠组标题（同步链路 / 配置与写入）与行距。
  * 两列而不是整行 label/value：整行会在 626 画布中间拉出几百 px 空洞，那是上一轮「像被拉宽的收据」的老问题。
  * 复扫：626 与 320 溢出 0 项、对比度 0 项不达标（文字从 `surface-high` 落回卡面，对比度反而更高）；「关于」浮层里的 `.card-quiet` 同步去掉分隔线，截图核过。

* **「关于与自检」多一条入口行**：它原来只有一个入口 —— 英雄卡里那个版本号胶囊（改触控高度之前只有 27px 高，而且看着像个标签不像个按钮）。概览的入口卡因此加第五行「关于与自检 · 桥接 / 取色 / 字体 / 设备信息」，两处开同一个浮层。实测：入口 5 行、点第五行浮层打开且页面仍停在概览；概览页高 1057 → 1116，626 与 320 溢出均 0 项。

* **属性表改成一行一项**：以前键与值各占一行（那是为了治「键值粘连成 `device_statelocked一致`」而改的），代价是 12 项要 47.3px 一行、卡高 753。现在同排显示（键 · 值 · 状态，列间 `sp3`），长值走省略号 + `title` 看全文；**不符**那一行让值单独占第二行，因为期望值是这一行存在的理由，不能被省略号吃掉。实测：行距 47.3 → 29、卡高 753 → 553、演示数据 12 项里被截断的值 0 个（把值列给到 1.3fr 之后）。320 视口退回两行（键本身就要 194px），溢出 0 项；属性页文本节点 43 个，最低对比度 5.69，0 项不达标。踩到的一处：`is-diff` 那行只靠网格自动放置，那颗 `不符` 胶囊会被塞进跨两列的一行、被拉成整条 514px 宽的红条 —— 落位必须写死（键 r1c1、胶囊 r1c2 且 `justify-self:end`、值 r2 跨行）。

* **小控件的触控高度补到能按得着**：量了一遍五页上所有可点的东西 —— 工具条按钮（`btn-sm`）只有 **30px**、分段按钮 **28px**、英雄卡里的版本号胶囊 **27.3px**，都低于 Material 3 组件的 40dp 基准（安卓无障碍建议 48dp）。改成 `btn-sm` 36、`seg button` 32（整条分段 38）、`button.chip` 32；字号与圆角不动，层级仍然靠基础按钮的 38px 压住。复量：五页最小可点高度 32（原来 27.3），概览页高 1052 → 1057，五页溢出仍 0 项。

* **概览不再三处报同一个数**：入口卡的四行副标题原来是实时计数（常驻 N 条 / 生效 N · 第三方 M / 缓冲 N 行 / 开机写入 已开启），而英雄卡与下面的状态卡已经把这几个数各报了一遍 —— 一屏里「常驻」相关计数出现 3 次、`rules.txt` 3 次、日志行数 2 次。改成入口只说**这一页是干什么的**（每行一个包名 · 保存即同步 / 桌面图标与应用名 · 可加入常驻 / 末尾 30~300 行 · 可自动刷新 / 开机写入的期望值 · 可立即应用一次），数字只留在英雄卡（摘要）与状态卡（明细）。复量：常驻计数 3 → 2 处、`rules.txt` 3 → 2、`1109` 2 → 1；`renderMenu()` 整块（13 行）随之删掉，入口卡不再参与重绘。

* **切页有过渡了（但不再是横滑）**：点底栏时新页面从目标页所在的方向滑进来 —— 位移 24px（窄屏按 5% 收，320 下 16px）、透明度 0.9→1、200ms，用 WAAPI 在合成器上执行、主线程零工作；点当前页与 `prefers-reduced-motion` 下都不播。位移只加在这一张卡片上：不碰容器高度、不盖遮罩 —— 之前「闪」的三条来源（高度跳、全屏遮罩、opacity 0→1 的入场重播）一条都没回来。整页滑过去需要把五页重新横排成轨道（就是刚删掉的那套），这里只做局部位移。
  * 实测（626×1000 与 320×900）：起点 24 / 16px、opacity .9，190~210ms 内回到 0 / 1；动画期间 `scrollWidth` 保持 626 / 320，没有横向溢出；连点 7 次（45ms 间隔）后只剩一个面板可见、`transform:none`、没有残留动画；逐帧采样 70 帧「同时 0 或 2 个面板可见」「遮罩出现」仍为 **0**；`prefers-reduced-motion: reduce` 下动画帧数 0（直接切）。
* **点底栏那一下的主线程开销**：原本一次点击会把当前页**画两遍** —— `showTab` 先用缓存画一次，`runChain` 的收尾又画一次；130 行的应用列表在 4× CPU 节流下每次多花 8.2ms 主线程和一条长任务，手机上就是点下去「顿一下」。现在 `ensure()` 返回「这一趟有没有真的取数」，只有取到数（或整份刷新、或取数失败要落状态）才重画；应用列表再加一道签名（两份名单 + 筛选 + 草稿基线 + 图标数），输入没变就不重建 DOM。实测（626×1000，130 行）：切回已经画过的「应用」从 **8.6ms / renderApps×2** 降到 **0.9ms / 0 次重建**（4× 节流；1× 下 4.4 → 0.2ms）；首次进入仍是完整一次（7~8ms）。
  * 「+」按钮的图标原来是每行 `innerHTML` 解析一遍 SVG，130 行就是 130 次；改成解析一次后逐行 `cloneNode`，首次进入的长任务 **74 → 53ms**（4× 节流）。图标再补 `decoding="async"`，插入与滚动时不在主线程同步解码。
  * 功能复测：搜索、生效/已安装切换、「只看未纳入」、图标到达、整份刷新之后都仍会重建（用节点身份与行数核过）；点「+」能把包写进草稿并跳到常驻页；取数失败也重画一次，否则状态行会永远停在「读取中…」（合成一条 reject 验过：状态行落回统计文案、snackbar 显示错误）。
* **`status` 不再重复算数（945ms → 615ms）**：原先 `status` 内部要跑 awk 提取（约 330ms）与 `pm list`（约 200ms）来给出「生效 / 第三方 / 常驻」三个数字，而界面为了展示列表本来就要取 `targets` / `apps` / `rules` 三份完整清单——同一件事做两遍，既慢又可能出现两份对不上的数字。现在 `status` 只报文件与运行状态，数字一律由列表数出来，英雄卡的大数字随列表（约 330ms）出现，不必等 `status`。
* **界面取数与渲染分层**：`loadX` 只写状态、`renderAll` 统一画一次（原先 status 与 env 各自重画英雄卡与三十来行列表）；三份列表合并为一次并发请求、三页共用；并发刷新共用同一个在途请求且只在成功后才记「已加载」（否则第二条链会拿空列表去画）；迟到的响应不再覆盖新一次的渲染。
* **交互细节**：搜索输入防抖 140ms（原先每敲一个字符重建两百多行）；生效集合建一次用到底；日志自动刷新走静默路径、不弹「读取中」遮罩，且内容没变就不重建节点、用户翻上去看历史时不拽回底部；主行动按钮改用 primary 角色（tertiary 是 hue+130 的对比色，跟随系统取色时可能正好是红色，会把「立即同步」画得像危险操作）。
* **属性期望值表单点维护**：从 `apply_resetprop` 的内联字符串抽成 `props_expect_pairs()` / `props_expect_rules()`，写入端与界面展示端共用同一份，不会再各写一遍后走偏。
* **界面取值方式按实测选定**：本机（XQ-DQ72，每次 fork 约 20~90ms）实测三种读法——逐个 `getprop` 17 项 277ms、一次全量 + `grep -F -f` 过滤 1692ms、一次全量 + 参数展开查表 228487ms；故采用逐个 `getprop`。`status` 与 `env` 拆成两条命令（后者含 busybox / inotify 探测与系统取色，只在打开界面时问一次）。这两步把 `status` 从 2452ms 降到约 950ms，再由上一条「`status` 不再重复算数」降到约 615ms。
* **WebUI 写操作的等锁时间**：界面侧等锁只等 6 秒（守护进程仍为 15 秒），超时提示「守护进程正在写入」——WebView 里的 `exec` 是同步的，等满 15 秒看起来就是界面卡死。
* **界面密度收紧**（412×900 视口实测）：英雄卡 325px → **204px**（−37%），整页 1341 → **976**（−27%），概览首屏可见行 **6 → 11/12**；生效数 60px → 34px，列表行 69 → 55，标签栏 68 → 50，按钮 46 → 38，留白与圆角整体降一档（不对称圆角与弹性动效保留）。收紧后重扫对比度：浅色最差 5.18、深色最差 4.58，114 个文本节点 0 项不达标。图标按钮收在 40px——M3 建议 48dp，这里已经偏低，不再往下。
* **界面按真实画布重做（626 CSS px，不是 412）**〔这条的 626 是错的，本机是 417，见下面「真机画布量错了 1.5 倍」〕：上一条密度收紧是在 412px 视口上调的，而本机 WebView 实际宽度是 **626 CSS px**（1644px ÷ 420dpi×2.625 换算），所以「还是丑」的成因不是松，是每一行都横跨整页——概览 16 行「标签贴左、数值贴右」，中间是 400px 的空洞，整页像一张被拉宽的收据。改动：概览与「关于」改成自适应网格（`auto-fit` + `minmax`，宽屏 2 列、窄屏自动降 1 列，不设断点），一行不再横跨画布；字号分五档（34 / 22 / 15 / 13.5 / 11），数字走大号、文字走正文；正常值不再着色（原先 12 个绿胶囊等于一排红绿灯，现在只有 warn / bad / na 画点或胶囊）；英雄卡与概览的重复项去重（后端、生效数、目标文件、更新时间各出现两处），动作按钮并入数字行；标签栏等分铺满；「关于」降为脚注层级。「生效应用 / 已安装第三方」从概览移除（英雄卡与标签角标已有），属性伪装移入「配置与写入」组。
  * **属性页原本读不出来**：键与值之间没有间隔，`ro.boot.vbmeta.device_state` 与 `locked` 与「一致」连成 `device_statelocked一致`。改成属性名 + 状态一行、当前值一行，不一致时同一行补出「期望 …」。
  * **删掉旧 `.tile` 样式时漏了两个消费方**——属性页与「无法连接」诊断面板都调它，前者退化成粘连、后者会直接抛 `ReferenceError`（正是最需要它说话的那条路）。两处一并改为新网格。
  * **量测改走 CDP 顶层文档**：`chrome --headless --screenshot` 给出过与真实渲染不一致的读数（报「重新读取」按钮被裁掉，实际布局正常），一度据此去做了一处对不存在问题的修复。现在一律用 `Runtime.evaluate` 在顶层文档量，溢出扫描覆盖 5 页 × {320 / 360 / 412 / 626} × 2 配色 = **0 项**；对照用 `flex:0 0 900px` 钉死一个溢出元素，能报出 2 项并点名到元素与上限值。上一轮据此加的 `.count-cap{min-width:max-content}` 经实测对任何宽度都不改变布局，已撤回。
  * 对比度见下一条末尾的复扫结果（本条改动后浅色最差 5.18、深色最差 4.58）。
* **形状与配色收成一套（走「中性表面」这条）**：上一条把版面修好了，但「怪」还在——一屏里同时有三套互不呼应的不对称圆角（英雄卡右下切一角、状态徽章是两对角圆两对角小圆的「叶子形」、主按钮又是另一组不对称），而**最大的色块装着最少的信息**（整块 `primary-container` 薰衣草紫只放了一个数字和两个按钮），再加上「运行中」用的固定绿（色相 155）与紫色毫无关系，两块撞在一起。改法：
  * 静止形状全部对称——按钮一律胶囊（表现力留给按下那一刻的 `pill → 圆` 形变，那是一瞬间的事，不会和别的形状并排打架）、卡片与格子单一圆角档位、对话框与提示条同理；`--r-xl` 18 → 16、`--r-2xl` 22 → 18。
  * 英雄卡改中性表面（`surface-low` + 发丝线），主色只留在生效数字与「立即同步」上；「重新读取」由 `secondary-container` 改中性——次行动不需要看起来和主行动一样重要。
  * 正常状态不再上绿底：`运行中` 徽章改中性底 + 绿点，与概览里「只有 warn / bad / na 着色」的规矩统一。整页剩下的饱和色只有主按钮与「不符」红标。
  * 格子的表面从 `surface-mid` 提到 `surface-high`，卡片与格子的层级差拉开；原先两者只差 1.5% 明度，结构看起来是糊的。
  * 顺手撤掉 `.count-cap` 的 `opacity`：用透明度压层次会让对比度审计量到叠色**之前**的值，报出来的数是好听的但不是画出来的。
  * 这一轮改完的对比度与溢出复扫结果见下面「兜底色改成平台默认强调色」那条的末尾（浅色最差 5.26、深色 5.71，0 项不达标）。
* **状态栏那条缝：成因查清了，但最后选择不动**：先确认责任在谁 —— 从装好的 KernelSU 里把 `base.apk` 拉出来查，`Theme.KernelSU.WebUI` 只在浅色档设了 `windowLightStatusBar` + `windowLightNavigationBar`（夜间档 0 条覆盖），且整个 dex 里 **`theme-color` 出现 0 次**，也就是说宿主根本不读页面那个 `<meta name="theme-color">`，写什么都是白写。真正的原因是宿主默认给 WebView 加了等于系统栏高度的 padding，页面被顶到状态栏**下面**，那一条从头到尾是宿主窗口画的，所以永远接不上。改法是调官方桥的 `enableEdgeToEdge(true)` 把那个 padding 归零、由界面自己按安全区让位。**但开完之后系统的返回手势条从「宿主底栏上」变成「浮在页面背景里」，页面短的时候看着像凭空多出来一根药丸（实测 `navigation_mode=2`，屏幕底部正中那根没字的短横条）。两者是同一个开关，只能选一个 —— 实际用下来选了让状态栏那条缝回来，`enableEdgeToEdge` 不再调用。** 保留这段是因为成因结论仍然有效：那条颜色确实不是页面能决定的，`theme-color` 也确实无效。`--inset-top` / `--inset-bottom` 两个令牌留着（值就是 `env(safe-area-inset-*)`，宿主自己让位时它们本来就是 0），哪天想换回来只改这两行加一处调用。
* **兜底色不再是「我挑的紫」，改成平台默认强调色（实测换算）**：界面上报的取色来源一直是 `sys_seed_src=none` —— 本机 `settings get secure theme_custom_color` 与 `global` 都是 `null`、`dumpsys wallpaper` 是 `isColorExtracted=false`（壁纸是 SystemUI 自带的渐变，没有可提取的调色板）、`cmd overlay list` 里也没有任何色彩类 overlay。也就是说**前两级种子在这台机器上根本不存在**，第三级兜底用什么颜色就等于"这个界面看起来是什么颜色"。原先的兜底是 `hue 275 + sat 1`，即 `--primary = oklch(49% .19 275)`。把 `framework-res.apk` 拉下来实测 `color/system_accent1_600_light = #4b5d8b = oklch(48.4% .078 267.2)`：**色相只差 8°，彩度却是我用了 2.4 倍** —— 所以「没有用系统强调色」的真实成因不是色相挑错，是同一支色被拉得太艳，跟系统其它地方不像一套东西。改成 `hue 267 + sat .41`（.41 = .078/.19，两边明度几乎同档，所以这个比值是推出来的不是拍的），CSS 里 `:root` 的初始 `--hue/--sat` 一并对齐，免得 JS 生效前闪一下旧颜色。深色档也核对过：`--primary` 深色基值 `.13×sat` 得 C .053，AOSP `system_accent1_200_dark = #b8c6ee` 是 C .058。
  * 复扫对比度：浅色最差 **5.26 → 4.99**、深色 **5.71** 不变，5 页各 57~104 个文本节点仍 0 项不达标。降的那一点来自新增的首字块与包名行用了次级文字色，4.99 仍高于 AA 的 4.5。溢出扫描 5 页 × {320 / 360 / 412 / 626} × 浅/深（含强制 `data-e2e` 一轮）仍为 0 项。
* **生效列表标出「常驻」**：以前「生效 10 个」里哪几个是写在 `rules.txt` 里、不管装没装都会进目标的，哪几个只是因为装着才进来 —— 界面上分不出来，而这正是本模块的核心语义。现在带 `rules.txt` 基线的行会挂一个中性「常驻」标签（草稿没保存不算数，所以判据用磁盘基线而不是编辑器内容）。
  * 顺带修掉一处窄屏溢出：网格轨道写的是 `minmax(260px,1fr)`，容器比 260px 还窄时**下限不会退让**，格子会捅出网格右边界（320px 视口实测：网格 254px、格子 260px、右边界超 6px）。改成 `minmax(min(260px,100%),1fr)`，应用列表那条同样改。溢出扫描现在覆盖 {320 / 360 / 412 / 626}，**全部 0 项**。
* **清掉没人用的取色机制**：`--tertiary` 一族四个角色在全文件里 **0 个消费者**（上一轮把主按钮从 tertiary 改成 primary 之后就没人用了），而 `--hue3`（= hue+130 的第三色相）存在的唯一理由就是喂给它 —— 连同浅/深两套 oklch 定义与两套 hex 回退共 8 行一起删。现在整套颜色只有一个来源色相，「跟随系统」这件事在代码里也只有一条路。
  * 等宽栈同理：`--mono` 原先写死 `ui-monospace,"Roboto Mono",SFMono-Regular,Menlo,Consolas,monospace`，后三个在 Android 上永远匹配不到，属于上一轮"别写死具体字体名"的同一类问题，改成 `ui-monospace, monospace`。
  * 删掉深浅按钮后 `palette` 那个图标定义也没了使用者，一并删。
* **给页面底部一个归属（页脚）**：页面内容按 626×1463 实测只到 1275，下面近 200px 是一片空背景 —— 读完就像「没了」，看着像没画完。加了一行页脚（`TS-AUTO-ADD · 只在开机与文件变化时同步 · 界面不联网`）+ 发丝线，并把 `body` 改成竖排、`.wrap` 撑满、页脚 `margin-top:auto`：内容短时页脚贴着视口底部、内容长时跟在内容后面。实测 626×1463：页脚 1385~1419、与屏幕底边之间 44px、页面不产生滚动（pageH == vh）。
* **密度往回放一档（上一轮收得太狠）**：先「太松太大」再「很挤」，说明这两句抱怨的方向是相反的，而我把它们当成了同一个轴在调。这次不再逐条找，把松紧集中成两组令牌 —— 圆角 `--r-*` 与留白 `--sp-*`，改这两行就能整体调档。实测改动：`--sp3` 9→12、`--sp4` 12→16、`--sp6` 18→26；`--r-xl` 16→20、`--r-2xl` 18→24；字号整体上移半档到一档（生效数字 34→38、格内值 15→16、应用名 13.5→14.5、格标签 11.5→12、标题 20→22），应用图标块 34→38px。
  * 复扫：对比度浅色最差 4.99 → **4.85**、深色 5.71 → **5.70**，5 页各 53~100 个文本节点仍 **0 项不达标**（低彩度青蓝让次级文字与背景更接近，但 4.85 仍高于 AA 的 4.5）。溢出扫描 5 页 × {360 / 412 / 626} × 浅/深（含强制 `data-e2e`）**0 项**；320px 那一档有 1 处格子超出网格 6px，低于本模块任何真实目标宽度，记在这里、没有修。
* `.gitattributes` 为 `*.html` / `*.css` / `*.js` 固定 LF。

#### 优化

* **底栏从四格收成三格：自动同步不再是独立目的地**。上一轮做"完整后端控制面板"重构时把它升成了一格，但那样等于把本模块的**附加功能**摆在了主体（后端自己的配置）前面 —— 用户一句话点破："自动更新等功能完全没必要单独做一栏吧"。
  * 现在是 `后端 / 伪装 / 日志` 三格；自动同步收成后端页里的一张卡「自动同步 · 本模块附加」，位置在**该后端配置面之后**（面板的主体先说话），原来那张独立的「自动纳入新应用」卡也吸进这一段说明 —— 只有 TEESim 有这个概念，一段话带过即可。
  * 后端页的取数随之补上 `base`（这张卡要用 status/env：守护进程、事件监听、目标文件、日志）。
  * 台架与断言一起改：`verify.mjs` 的 PAGES 变三页、`replay-check.mjs` 的索引全部重排（日志页 3→2、切走用的页 2→1）；`tests/ui-shape.js` 增加"自动同步不再占一个目的地 + 它是后端页里的一张卡"，防止下一轮又被升回一格。
  * README 的"界面"一节整段重写：原来那几条还在描述**上一版界面**（四格悬浮药丸、二级页返回箭头、`md-gb-*` 组件、`.grp` 描边、hero 卡），现在逐条换成当前实现（三格、卡片顺序、分批挂载、单文件产物、417 画布、两套验收台架）。

* **后端页再压一档：首屏之外的卡片推迟一帧**。keybox / 三家矩阵 / 外观 / 自检在 975px 的视口里全在折叠线以下，晚一帧出现没人看得见；把它们从切页的关键路径上摘掉后，二次进入 **310 → 265ms（同步 98 → 78ms）**，冷启动 222–270ms。把名单分块从 40 改成 24 试过，272ms 反而略差（在噪声内），回退到 40。
  * 台架新增两个用户真正会等的读数：**冷启动**（navigate → #view 有内容，现 222–270ms）与**日志页 300 行**（1218 节点，39ms）——后者证明日志页不是瓶颈，不必虚拟化。
  * 推迟的那批用 `box.isConnected` 守卫：换页或重画后不再往卸掉的树里塞节点。

* **切到后端页从 1010ms 降到 302ms（真机 128 条名单的数据）**。先把三件事量出来：底栏几何恒定（y 911→911、高 64→64，全程 0 变化）、切页都停在页首（scrollTop=0）、**二次进入后端页 1010ms（同步 346ms）/ 448 节点** —— 其余三页只有 24–39ms。用 CDP 采样分析器看那 346ms 花在哪：`getBoundingClientRect` 8%、`contentSize`/`measure`/`_measure` 合计约 11%、`getPropertyValue` 3.8%，**全是 MD3E 组件自己在同步量布局，不是我们的渲染函数** —— 所以优化方向是"少建控件"，不是"改渲染代码"。
  * 名单**分批挂载**：先画 40 条让这一页立刻可交互，其余每帧 40 条补齐，底部小字显示"已显示 N"。换页/重画时令牌 +1，正在跑的循环看到不是自己那批就停手（不会往已经卸掉的列表里 append）。
  * OMK 的两块大表单（injector.toml 十项拦截开关 + config.toml 十几个字段）收进「编辑」折叠，卡片上先给只读摘要（拦截 N/10、日志级别、补丁级别四档）。顺手解决这一页过长的问题。
  * 结果：**1010ms → 302ms（同步 346 → 96ms），采样点节点 448 → 188**。台架里新增四条断言：底栏几何在整个切页过程恒定、每页进入时 scrollTop=0、二次进入 <400ms、分批加载被打断不炸且最终补齐到全部条目。
* **顺手抓到两条"表单读错键"的真 bug**（这次把 KV 对账扩到表单规格才发现）：`跳过生物识别` 与 `淘汰旧 keybox 绑定的密钥` 两个开关的**读键**写成了 `config_force_skip_biometric` / `config_retire_stale_keys`，而命令层输出的是 `cfg_*` —— 于是这两个开关在真机上永远显示为"关"。表单的读取是间接的（`biValue(spec, from)`），原来那道 `S.x.y` 扫描看不见，现在专门解析 `F_*` 表里的 `['提交键','读键',…]` 逐条对账（只认带标签与类型的真字段项，不然 select 的选项对 `['warning','warning']` 会被当字段 —— 第一版就这么报了个假警）。
  * 还有一条**"缺键 ≠ 关"**：真机 `config.toml` 里根本没有 `retire_stale_keybox_bound_keys` 这一行（上游默认 `true`），命令层如实不输出，而界面把空值显示成了"关" —— 又是一次显示错事实。现在显示"未设置（上游默认 true）"，并把这个"缺键状态"写进假数据，让台架能验到这条分支。

#### 修复

* **上机后四处版式是坏的，逐个修掉**（都是"看着能用、上屏才发现"的那一类）：
  * **底栏第三格「伪装」是空的**：PAGES 里写 `icon: ICON.tune`，而 ICON 表里只有 `restart: 'tune'`、没有 `tune` 这个键 —— 取出来是 undefined，组件就把那格画成一个空槽。以前的 icon 闸只认三种字符串写法（icon="x" / icon:'x' / setAttribute），盖不到 `ICON.xxx` 这种表引用；`icon-gate.mjs` 现在逐个校验 `ICON.<键>` 必须存在。
  * **属性页第二行文字漏到卡片外面、压在下一行上**：`renderProps` 往 `md-list` 里 append 了一个裸 `div.prop-cur`（而且它没有任何 CSS）—— 它不在列表的白底表面里。改成把"当前 …"写进 supporting-text：组件是 `white-space:pre-wrap`，换行正常显示、行高自己长。空态那行 `<p>` 同样从列表里挪进卡片。
  * **目标名单的标题被长路径折成三行**：`目标名单 · /data/misc/keystore/omk/injector.toml` 会在词中间断开（`injector.to` / `ml`）。标题只留「目标名单」，完整路径移到下面一行说明。
  * **四个筛选按钮挤成 3+1 两排**：换成 `md-chip variant="filter"`（MD3 里做筛选的标准控件，也窄得多）+ 两列等宽网格。顺带记一笔：md-chip 的 label **属性**和槽文本会**同时**渲染，两样都设就成了"名单 3名单 3"（md-button 只认属性，两者别混着抄）。
  * **应用图标按原图 256px 渲染，把整行撑成一个巨大方块**：图片既没进 `md-list-item` 的 `start` 槽，也没有 `.app-ic` 尺寸样式。补 32px 圆图 + 缺图时退回"首字块"（旧版本来就有这个退路，浏览器破图符不能见人）。
  * 回放台架补两条：**底栏转储**（`DUMP_NAV=1`，直接给 items/selected/渲染项 —— 光看截图分不清"图标没画"和"整项没建"）与**图标像素断言**（只看有没有 `<img>` 不算验过，要看 `naturalWidth`；本地只有两张贴图，缺的不假装通过）。`module/webroot/icons/` 是运行时产物，已加进 .gitignore。

* **改名迁移在真机上静默失效**：`migrate_legacy_paths` 原来用 `for pair in "旧|新"` 再 `${pair%%|*}` / `${pair##*|}` 切分 —— **Android 的 sh 把 `|` 当成"或"**，两个展开都变成空串，于是 `/data/adb/ts_auto.*` 那三个文件一个都不搬。本机 dash/bash 一切正常，**只有把套子推到机上跑才看得出来**。改成 `_mig 旧 新` 两条参数直传，并在 `tests/legacy-migrate.sh` 里加一条静态禁令（判代码不判注释：解释这个坑的注释里就写着这种写法，连注释一起查会自己绊自己 —— 这类假阳性本轮犯了第三次）。
  * 后果本来很实在：`ts_auto.props_off` 存在 = 用户关掉了属性伪装，`ts_auto.boot_hash` 是配置好的启动哈希 —— 不搬就是升级后静默回到默认。
  * 同轮把 20 个 shell 套子全部推到 `/data/local/tmp` 用**设备 toybox sh** 跑了一遍：修前 18 过 2 红，修后 20 全绿。
  * 三个套子的临时目录加了自报护栏：之前有一次 `teesim-overrides-write.sh` 退非 0 却**一条 ✗ 都没打** —— 只看得到"失败了"，看不到"死在哪"。现在建不出临时目录会直接点名。那次单发失败连跑两遍没能复现，记在这儿当作未结的疑点，不当作已修。

* **发布包不能用 PowerShell 打**：`Compress-Archive` 把条目名写成 `backends\teesim.awk` 这种**反斜杠**，而 zip 规范的分隔符是 `/`；busybox/recovery 的 unzip 会把反斜杠当文件名的一部分，整个目录树被摊平成一个个叫 `lib\core.sh` 的文件，`update-binary` 找不到，装机必坏。另外第一版自写的打包器漏写了中央目录的**本地头偏移**（每个条目都指向 0），`unzip -l` 报满屏 `mismatching "local" filename` —— 这种包看着能列、实际解坏。
  * 现在用 `node tools/build-zip.mjs`：正斜杠、made-by=UNIX、`.sh`/`.awk`/`update-binary` 给 0755、其余 0644；`--check` 验"没有反斜杠条目 / 装机必需文件齐 / 脚本有可执行位 / 界面产物在包里且 >400KB"，验完再做**解压回来与 `module/` 逐字节 diff** 的 round-trip。
  * 顺手发现老发布包 `mode=0o0`（没存 unix 权限）却能装 —— 说明管理器自己 chmod；新包把权限存上，只多不少。

* **台架的采集自检**：`tools/replay-check.mjs` 曾把 Git Bash 改写 adb 路径造成的满屏 shell 报错，当成"真包名画到屏上 ✓"判全绿 —— 断言拿那句错误文本当包名去匹配。现在驱动界面之前必须先证明 16 条读命令都拿到该有的键、`targets` 128 条形状正常、采集里没混进 `No such file`/`Permission denied`，否则停住不跑。一台会替错误编造成功判据的仪器，比没有仪器更坏。

* **换版后界面只剩框架（内容一条都不出来）**：桥接的调用形状写错了。KernelSU 主线（`me.weishu.kernelsu`）的 `exec(cmd, optionsJson, **回调函数名字符串**)` 第三个参数要的是**全局函数名**，新版传的是函数对象 —— 管理器找不到那个名字，于是**永远不回调**：所有命令挂到 30 秒超时，屏幕上只剩顶栏和底栏。
  * 证据不是猜的：把**机上一直能用的那一版**（`git show b918440^:module/webroot/index.html`）的 `callExec` 抠出来对照 —— 它注册 `window['tsaa_cb_N']` 再把**名字**传进去，注释还专门写了"第三个参数是回调函数名，不是函数"。这条形状本来就在旧版里，我重构时把它当"可以简化的地方"改掉了。
  * 现在按 `S.bridge.kind` 分叉：`ksu` 走函数名回调，其余仍走 `exec(cmd, callback)` / 同步返回 `{errno, stdout}`；两条路径都保留超时兜底。
  * **为什么台架完全没抓到，以及补的那件仪器**：`verify.mjs` 走 `?demo=1`，`run()` 在 DEMO 分支直接返回假数据，**根本不经过 `window.ksu.exec`** —— 桥接写错在这套台架上是不可见的。新增 `node tools/replay-check.mjs`：① 数据从**真机现读**（只读命令白名单，写命令一条都不碰）；② 注入的假桥接**照真管理器的形状**，形状不对时**像真机一样静默不回调**；③ 断言钉在真数据上（真机名单 128 条 → 屏上列表项 ≥60、画的是真包名、自动更新页有 128、日志页有真机最后一行的时间戳）。
  * 这台仪器自己被变异验过（`node tools/mutate-replay.cjs`）：把 bug 放回去 → 退码 1，并复现出用户看到的原话症状（列表项 0、自检行"api 读不到 / uid ? / Android ?"）；还原后重新构建复跑回绿。**第一版这个台架是假的**：shim 遇到非字符串回调直接 `throw`，等于把"卡死"伪装成"快速失败"，界面照样画出东西、台架照样全绿 —— 变异跑一遍才暴露。
  * 同一轮自查还抓到我自己两处仪器/操作错误：① 我拿命令扫描把 `props-apply / props-on / props-off / props-on` 在用户手机上**真跑了**（日志 02:43 那四行），已恢复成"开"，并把读/写白名单写进 replay 台架；② 扫描报的两条"未知命令"是 adb 输出带 `\r` 造成的假故障，直接重跑正常。

* **Tricky 的 `tee_status` 键名读错，界面把"探测失败原因"画成一个破折号**：命令层输出的是下划线风格（`tee_broken` / `service_error_code`），界面读的却是上游文件里的小驼峰（`teeBroken` / `serviceErrorCode`）—— 而**台架的假数据是照着我错的代码写的**，两边一起错，逐页驱动一路全绿。同场改掉的还有取值：上游写的是 Kotlin 布尔的字面量 `false/true/unknown`（`Config.kt:127-143`），不是 `1/0`，旧文案"1 = TEE 不可用"是把两种语义混成一种。
  * 顺带把 `AUTO` 说明白：它不是一种模式，是**照上次探测现算**（`Config.kt:225-229`）—— `AVAILABLE→叶证书`、`FAILED→证书生成`、`UNAVAILABLE→该条目不匹配、包根本不会被改写`。以前只显示"自动"两个字，等于什么也没说；读不到探测结果时**不许猜**，宁可显示成"未探测"。
  * 那条"自动 → 不匹配"的理由原来挂在按钮的 `title` 上 —— 触屏上没有 tooltip，等于没写，现在进列表项的 supporting 行。
  * 这类"界面读的键名 ≠ 命令层输出的键名"从此由 `tools/kv-shape-check.mjs` 静态对账，三处变异验过它三处都会响。

* **名单"读不到"被界面报成"是空的"**：`loadLists` 把三条读取的失败全吞成空数组，而命令层在目标文件缺失时正是 `return 1`（`cmd_target_meta` 报"目标文件不存在"）。于是文件没了 → 界面说"这一类现在是空的"，还把"移出"按钮照原样摆出来。现在 `S.listErr` 记下失败原因，画在「目标名单」卡的第一行，空态文案让位给"读不到，所以这一类画不出来"。
  * 这条有专门的变异：删掉错误行那一句 → 台架退码 1 并点名"错误行 缺"（`node tools/md3e-build/mutate-verify.mjs`，两处变异都被抓住）。

#### 修复

* **台架的假命令清单漏了一条，于是 overrides 那张卡一直走的是降级分支**：假数据里的 `commands=` 少了 `teesim-overrides` —— `hasCmd()` 在台架上恒为 false，那张卡永远显示"这一版命令层没有 teesim-overrides"，而逐后端驱动只看区块标题，照样报绿。同一条链上还有第二处漂移：`contract-pair.sh` 报"命令 36 条"，而 `case "$CMD"` 实际 33 条 —— 它抽取 `TAA_COMMANDS` 时没去掉续行的反斜杠，3 个 `\` 被 `wc -l` 数成了 3 条命令。
  * 两处都补了静态对账（`tests/ui-next-shape.js`）：**假数据的命令清单 = case 标签**、**`TAA_COMMANDS` 声明 = case 实际实现**，两个方向都查。前者漏一条 = 能力永远不露出；后者多一条 = 界面摆一个点了就报"未知命令"的按钮。
  * 台架的 teesim 那一趟从此要求画出 `attestationSecurityLevel` 与 `synthesized` 两个**值**，只看标题的判据被换掉；这条变异验过（把假数据里那条命令删掉 → 台架退码 1 并点名"没画出来: attestationSecurityLevel、synthesized"）。
  * `kv-shape-check.mjs` 顺手补两件事：① 扫描前先剔注释（它自己写在注释里的例子 `st.xxx` 被当成一次真读取，报了一条假警）；② **自报盲区** —— 算出来的下标 `obj[变量]` 它看不见，现在会把这种站点数打印出来。`backendMatrix` 因此改成先落 `st.tricky_state` 这类字面量再把值发给表，否则那三条读取就脱离了这道闸。

* **保存配置时最后一个字段被静默丢掉（既没写入、也没过校验）**：`parse_payload` 用 `while IFS= read -r line` 逐行解 payload，而 `read` 在**最后一行没有换行符**时会直接结束循环 —— 界面的 payload 是 `payload.join('\n')` 拼的，本来就没有尾换行，所以最后一个字段永远进不去。实测（修前）：两个字段、第二个故意放非法值 → 命令层回 `saved=1 fields=1`、退码 0，也就是"改 N 个存进 N−1 个"，而且被丢那个连校验都没跑。单字段时更幸运：直接报"没有字段"，所以这个洞以前只在多字段保存时出现，从来没被撞到过。
  * 修法是一个字符级的 `|| [ -n "$line" ]`。回归测试 `tests/payload-last-field.sh` 抽的是 webui.sh 里的**真函数**（不抄一份），四条断言分别钉：无尾换行的两字段、无尾换行的单字段、带尾换行不重复计数、含怪字符的第二条要进 pairs 交给上层校验。
  * **绿测试在证明它会红之前什么也没证明**：把修复撤掉重跑 → 3 条变红、退码 1；还原 → 全绿。变异本身也自证落地（锚点恰好命中 1 处 + 文件确实变了）。
  * 踩到的两个仪器坑记在这里：① 测试最初只抽了 `parse_payload` 没抽 `find_base64`，四条全红是**仪器缺件**不是代码有问题；② 用 `node -e` 跑变异时一个全角括号把脚本炸掉，幸好语法错误发生在写文件之前 —— 变异类脚本一律写成 `.cjs` 文件（这条早就记过，又犯了一次）。

* **OhMyKeymint 的 [trust] 字段从"任意文本"收紧到文档格式**：以前 `trust_os_version` / `trust_security_patch` / 三档 patchlevel / `trust_vb_key` / `trust_vb_hash` 全部走 `valid_text 128` —— 把 `auto` 敲成 `aut`、把年份 `2016` 填进本该是 MMmmss 编码值（0–99）的 os_version，都存得进去；而 OMK 读不懂时**静默退回默认值**，界面上完全看不出来"存进去了 ≠ 生效了"。现在按 `docs/CONFIGURATION.md` 各自校验：`auto|latest|YYYY-MM-DD`（boot 额外收十进制 u32）、`auto|random|64hex`、`auto|0..99`；injector 的 log_level 补上它独有的 `warning` 别名，config.toml 那一侧仍然拒绝。
  * `tests/omk-validation.sh` 40 条：既测好值过，更测坏值被拒（`aut`、`2024-13-01`、`2024-1-5`、`2016`、63/65 位哈希），并**单独一段钉接线** —— 只测函数本身的话，忘了在保存路径里换调用照样全绿。接线判据跟着 case 分支走（`a|b|c)` 这种并列要认，第一版只找 `key)` 漏掉了并列在中间的键）。
  * 真机端到端复核（设备后端正是 OhMyKeymint）：非法值现在回 `trust_vb_hash 只能是 auto / random / 64 位十六进制` 且 `config.toml` 的 sha 前后一致；修复前同样的 payload 是静默通过。

* **点底栏切页时底栏上下跳（实测定位到真因）**：切页入场把面板右移 24px，面板右缘到 425，比 417 的视口宽 **8.9px**；WebView 会把布局视口撑高来容纳它 —— 真机逐帧 `innerHeight` 从 **975 → 987**（第一次切页 1083），`visualViewport` 恒为 975.2，`bottom` 定位的底栏就跟着沉 **12px**，200ms 后弹回。修法：滑动这 200ms 给 `.wrap` 加 `.sliding`（`overflow-x:clip`），动画结束按计数摘掉；静止时不裁（常开会把整棵子树退回灰度抗锯齿，静止画面实测 2 万像素与不裁切不同）。`clip` 而不是 `hidden`：hidden 会把另一轴强制成 auto，整页滚动当场消失。
  * 判定方法：不猜机制，直接让页面自测。临时探针页自己切页、逐帧记录药丸 rect 与视口读数写盘，**同一次打开里**做 A/B —— 不裁的 3 次全部跳（897.71 → 909.65，首切 1005.90），开裁的 4 次全部恒定 897.71、`innerHeight` 恒 975。
  * `tests/ui-shape.js` 加 2 条断言（滑动期间 `overflow-x:clip`、结束摘掉类），共 **50 条**；两条都做了变异验证（改成 visible / 删掉 remove 都会红）。

* **首次安装的三件套被写成了同一行**：`SEED_PKGS` 是空格分隔的字符串，而名单是按行读写的 —— 结果三件套落在**一行**里（`"a b c"`），目标文件只多 1 条而不是 3 条。现在种之前先转成一行一个。**自检当时没抓到**：它把结果"按空格连接"后再比，一行三个包名与三行看起来完全一样；补了一条**按行数**的断言（首次安装应当 4 行）。真机沙箱复测：空目标 122 已装 + 3 种子 = **125 行**，非空目标**不种**（122 行）。
* **清掉删常驻留下的残渣**：`is_b64`（只被 `save-rules` 用过）及其注释、界面里三段孤儿注释、`ensure()` 里两处 `tab === 'rules'` 判断、两处注释里的 `#/rules` 示例、`find_base64` 的过时说明（它现在只用于把 SystemUI 的 .frro 传给界面）。
* **「已排除」不再用红色**：那是你自己的决定，不是错误；改成中性底（`--surface-highest`），只有真正的「未纳入」才着警示色。


* **自查增量同步时抓到的两个洞**（都在 `772313a` 之后当场修掉）：
  * **一个常驻条目被手动从目标文件删掉之后，再从常驻加回来也进不去** —— 它被记成了"手动删除"的墓碑，而墓碑没有"常驻里重新声明"这条撤销路径。现在补上：**常驻里新加了它**（上一轮的常驻集合里没有、这一轮有）就撤销墓碑。这条是真机复现过的：手动删 `com.example.rulesonly` → 墓碑里出现它 → 从常驻删掉再加回 → 改前一直为 0，改后回来。
  * **`-u` 把"卸载但保留数据"的应用算作已装** —— 那会让卸载后重装的墓碑永远清不掉（`was − inst` 看不到"卸载"），也违背"移除卸载的包名"。`cmd package list packages -3` 与 `webui.sh` 的应用列表都去掉了 `-u`。实测本机 122/122/122（三种写法条数相同），所以这条是潜在缺陷、不是现行故障。
  * 顺带：`current_target_apps` 读 tricky 的 `target.txt` 时过滤 `#` 开头的行（以前人工写一行注释会被当成包名永久带进列表）。
  * 自检从 10 条扩到 **16 个场景 / 37 条断言**，新增的正是上面这些边界：手动删除后又从文件加回、常驻新加撤销墓碑、"已装且一直在常驻"的包手动删除后手动优先、已装与常驻都为空只剩人工项、目标文件被清空即"全删"、以及清空后新装的应用仍能进。**五处变异都验过会红**（不记手动删除 4 红 / 卸载不清墓碑 2 红 / 加回不撤墓碑 2 红 / 不保留文件现有条目 4 红 / 撤掉"常驻新加"清除 3 红），并在**设备上（mksh + toybox awk）**跑同一份全绿。
  * 另记一条流程教训：真机第一次测"手动删除"时被**正在跑的守护进程**干扰 —— 它监听着 `rules.txt`，我一改就触发它用**旧代码**整份重写，把删掉的又加回来了。测这类东西要先停监视（`pkill` 时还得避开自匹配：模式串写进自己的命令行会让 pkill 杀掉自己）。顺带把守护用 `sh service.sh` 重启到了新代码，所以"事件驱动同步"现在也是新算法了，不用等下次开机。

* **应用页只给前 40 条问图标，其余永远是首字块（这才是"一大堆没图标"的真因）**：`renderApps` 里写的是 `list.slice(0, 40)` —— 列表 122 条时后面 82 条根本不发 `icons` 请求，而 `iconAsked` 又把每帧都传的同一批前 40 个标成"问过"，所以那些行**在整个会话里都不会再有图标**。文件系统里躺着 109 张 PNG 也没用：页面只认本次命令返回的行（`S.icons`）。
  * 现在问**整份可见列表**，分批仍由 `ICON_BATCH` 负责。实测（造 122 条）：批次 `[120,2]`、**122/122 全部请求**；设备上真机一次问 122 个包整趟 **414ms**（SQL 里的 `writefile` 每次重写 PNG），仍放在 `requestIdleCallback` 里跑，不抢首帧。
  * 上一轮修的那个 120 上限是**第二条**同源缺陷（分批丢尾巴），这条是**第一条**（根本只问 40）。两条叠在一起时，前 40 之外的行既没请求、也不会补 —— 只修一条仍会看着"一大堆没图标"，这就是我当时误判成"14 个后台组件 + 2 个丢尾巴"的原因。

* **图标分批时把列表尾巴静默丢了**：`loadIcons` 一次最多问 120 个包（SQL 里是 120 条 or 子句，一次 sqlite 整批处理），问满就跳出循环，剩下的这一趟不管 —— 而 `iconAsked` 已经把前 120 个标成"问过"，尾巴也不会再来。实测本机 125 个目标的列表里，排在 **#124 `sh.ppy.osulazer`、#125 `tv.danmaku.bili`** 的两个：缓存里分别有 1 行和 13 行图标，目录里却没有它们的 PNG；单独跑一次 `webui.sh icons` 就正常导出（osu! / 哔哩哔哩）。列表越长丢得越多。现在改成**分批递归**：一批问完还有没问过的就接着问下一批，`iconAsked` 保证必然收敛。
  * 自检（桩掉传输层，测的就是页面上那个 `loadIcons`）：125 个包 → 调用 `["icons:120","icons:5"]`、**125/125 全部问到**；命令失败时只调 1 次就停（不会死循环）；已问过的再调只补问剩下 5 个。修完设备上 PNG 从 109 张补到 **111 张**（= 缓存里有图的包数）。
  * **不是 bug 的那一类**：另有 **14/125** 在桌面缓存里连一行都没有 —— `com.google.android.gms` / `gsf` / `webview` / `ar.core` / `safetycore` / `verifier` / `contactkeys` / `ambient.streaming` / `as.oss` / `apps.work.clouddpc` / `apps.setupwizard.searchselector` / `breezyweather.geometriciconprovider` / 一个 tachiyomi 扩展等。这些是**没有启动器入口的后台组件**，桌面上本来就没有图标可取，降级成首字块是正确行为。设备上没有 aapt、也没有能读 APK 资源的工具，从 APK 里抠图标这条路之前就验过走不通。
  * 顺带核过、不改：降级块取的是包名**最后一段**的首字母（`monogram`，`gms`→G），不是"整页一片 C" —— 这条早就在做了，别为它再改一遍。

* **收尸的 `pkill` 匹配太宽，会杀掉别的模块的监听**：`uninstall.sh` 原来写的是 `pkill -f "inotifyd.*rules.txt"` —— 任何模块只要监听一个**叫 `rules.txt`** 的文件就会被连带停掉，而本模块的常驻列表与 Tricky Addon 之类的文件正是同名的。匹配串改成带绝对路径（`/data/adb/teesim/rules.txt` 与 `/data/adb/tricky_store/rules.txt` 两个后端目录都列）：卸载是本模块的事，不该顺手停别人的监听。
  * 顺带补一处：`service.sh` 的清理只按 `.ts_daemon_pids.list` 里的 PID 收，而记下的那个 PID 是管道**右边**的 while 子壳，左边的 `inotifyd` 不在名单上 —— 只按 PID 收会留下一个还在往管道里写的孤儿监视。现在清理阶段再按"我们自己的 rules.txt 绝对路径"精确收一次（放在启动新监视**之前**，不会误杀本轮刚起的）。

* **开机首次同步前那个 `until` 是死等的**：`service.sh` 里 `until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done` 没有上限 —— `boot_completed` 万一不翻，脚本就永远挂在那里，不记日志、不报错，看上去像"模块没反应"。改成有界（60 次 × 2 秒 = 120 秒），到点**照实记一条**再照原样同步：带着已知风险继续比挂着有用，因为文件变化仍会再触发同步，而这一趟结果可不可信日志里写得清楚。成功路径也记等待秒数。同仓库 `lib/lock.sh:15` 本来就是有界写法，这条只是把它自己定的规矩补齐。

* **真机画布量错了 1.5 倍：626 → 417 CSS px**：本轮之前界面里、文档里所有「本机 WebView 是 626 CSS px（1644px @420dpi）」的说法，都是**把两套分辨率各自的密度配错了**——1644 这个像素数属于高分辨率模式，420dpi 属于低分辨率模式。`dumpsys display` 的 `mDensityMapping` 把两套钉死：`squaredDiagonal=17448336`（=1644²+3840²）→ **density 630**（本机当前 mode 4）；`squaredDiagonal=7754816`（=1096²+2560²）→ density 420。所以 app 可见宽度 = 1644 ÷ (630/160) = **417.5dp**；低分辨率模式 1096 ÷ 2.625 也是 417.5 —— **两套模式下 CSS 宽度都是 417，不是 626**。
  * 影响一：**「宽屏 2 列」在这台机器上从来没发生过**。同一份演示数据实测：626 画布下概览两张网格各 2 列（内容宽 518），417 画布下各 **1 列**（内容宽 335）；`--measure:600px` 在本机不生效，只挡平板与横屏。
  * 影响二：上一条「应用列表自己翻成了两列」是在本机不会出现的画布上，修一个本机不会出现的问题。改成 `display:block` 没有副作用，留作窄屏兜底。
  * 影响三：历轮「626 溢出 0 项」量的都不是这台机器。本轮在 417 重扫 5 页 × 浅/深 **0 项**，320 与 360 再各扫一遍同样 **0 项**。
  * 换算：本机 1 CSS px = 1dp。之前按 626 建立的"这个尺寸看着偏大/偏小"的比例感，全部要按 0.66 折回来。

* **可点区不足 48dp：40 个可点控件里 20 个不达标**：M3 / Android 的可点区下限是 48dp，而本机 1 CSS px = 1dp —— 实测按钮 38、小按钮 36、分段 32、加号 32、开关 28、返回 40，全在下限之下。改法照 MDC：**外观一像素不动，可点区补到 48**（按钮与分段上下扩到 48 高，返回与加号补成 48 见方，开关用 `::before` 撑高，滑块仍在 `::after`）。为此涟漪不再由按钮本体裁剪（本体的 `overflow:hidden` 会把伸出去的可点区一起裁掉），改由一层 `.rip` 子元素裁剪，形状跟着 `border-radius:inherit`。
  * 判据不能再用 `getBoundingClientRect`：它量的是盒子，看不见伪元素撑出来的可点区。改成逐点问浏览器 `elementFromPoint` 这一点归谁，分**自己 / 邻居接住 / 死点**三种，三者混在一条里就会把"邻居接住了"当成缺陷。
  * 实测（417，5 页，排除 disabled）：**self<48 由 20 降到 2**，**48 带内死点由 20 降到 0**，「本体被抢」改前改后同为 0（rules 页那 2 处是禁用按钮，本来就不该响应）。剩的 2 个是日志页分段按钮 selfH=47 / covH=49 —— 最后 1px 由相邻分段接住，不丢点。
  * 代价（可一行回退）：按钮多出伪元素层后，文字会在动画期间重栅格化。逐像素核过：同一份包两次采集差 **0** 像素（所以这不是噪声地板），改前 vs 改后静止态差 **30 / 417000** 像素，全是字形边缘 ±1–3 阶的抗锯齿，位置与形状不变；按下动画中隔壁按钮的字形再多 41 个同量级的点。涟漪是否外溢按四个决定性采样点比（涟漪圆外左上、胶囊右缘外 2px、左缘外 4px、圆角缺口内），改前改后一致，**没有外溢**。

* **应用列表自己翻成了两列**：`#appsBody` 一直是 `repeat(auto-fill, minmax(258px, 1fr))` —— 626 画布下内容宽度 514，`2×258+1 = 517` 刚好够不着，所以一直排一列，这个 258 是个"刚好"的魔法数。这一轮把卡片内边距从 26 收到 24（外加 1px 边框），内容宽度变成 518，越过阈值，列表**自己翻成了两列**，每列 258px 里包名全被截断。现在显式写死一列（`display:block`），并把原因留在注释里。实测：10 行同列、行宽 518、溢出 0 项。

* **撤回一条过度推断，并回退它带出的改动**：我把一句「二级页面还是没有」读成了「边缘返回没反应」，于是拿一条 `18:04:52.189 {m=CLOSE …WebUIActivity}` 的 logcat 断言「hash 导航下边缘返回关掉的是整个界面、退不了一级」，并据此把页面之间改成整文档跳转（换 URL 重载 + 一层 sessionStorage 只读缓存 + 草稿/筛选/滚动位跨页持久化）。**他的意思一直是"没有安卓的可预测返回"，回到概览本来就是通的** —— 那条日志只证明有一次关闭发生过，证明不了当时停在二级页，我拿它当因果是用错了仪器。整文档跳转那版已整体回退（`94c5325`），代码回到 hash 路由；顺带留下的一条真结论：页内返回缺的是**预览**，而预览要宿主实现 `OnBackAnimationCallback` 并驱动 `startBackProgress`，全 dex 里 `startBackProgress` / `getBackProgress` 各 **0 次** —— 系统只为跨 Activity 自己截图，页内这一档它没有画面可画，页面也没有接口能喂。宿主那条返回链本身是清楚的：`doUpdateVisitedHistory` 读 `webView.canGoBack()` 写进状态，返回回调执行 `webView.goBack()`。

* **页内返回没有可预测预览，这条不是没做、是做不了**：把装好的 KernelSU v3.3.1 反汇编出来数了一遍 —— `startBackProgress` 与 `getBackProgress` 各 **0 次**，唯一实现 `android/window/OnBackAnimationCallback` 的类是 androidx 的兼容包装（`vl2` 包一个 `ul2`），宿主自己没有任何地方驱动预览进度。也就是说宿主的 WebView 返回走的是普通 `BackHandler`（回调里就一句 `webView.goBack()`），它自己没有实现任何应用内预览。系统那套预览只在**跨 Activity** 时由系统自己截图来画 —— 这就是「退回 KSU 有预览、二级页退回概览没有」的原因。页面这层也补不了：边缘拖动被系统手势接管（页面只会收到 CANCEL），也没有接口能把上一页的画面交给系统。要变只有一条路：宿主把 WebUIActivity 换成 `PredictiveBackHandler` 并给 WebView 历史做动画，那是改管理器本体，不是模块。

* **系统返回键在二级页退不了一级（这条最后定性为「模块改不了」）**：底栏换成下钻之后，在二级页划边缘返回，先报「无」，再报「还是没有」。先把宿主的实现挖开：反汇编装好的 KernelSU v3.3.1（targetSdk 37）看到 `WebViewClient.doUpdateVisitedHistory`（混淆名 `ym4`）里读 `webView.canGoBack()` 并 `MutableState.setValue(...)`，返回回调（`pm4.a()`，Compose 的 Function0 lambda）里就是 `webView.goBack()`。据此判断「`pushState` 不触发 `doUpdateVisitedHistory`，所以宿主的 canGoBack 恒 false」，于是把导航状态改写成 `location.hash`（真历史条目）。**然后用 logcat 量了一次，这个修法不成立**：WebUI 于 `18:04:38.983 Displayed …WebUIActivity +30ms` 打开，在二级页划边缘得到 `18:04:52.105 {m=CHANGE …WebUIActivity|FLAG_BACK_GESTURE_ANIMATED}` + `{m=TO_FRONT …MainActivity|IS_OCCLUDED|…}`，紧接 `18:04:52.189 {m=CLOSE …WebUIActivity}` —— **那一下关掉的是整个 Activity，不是退到概览**。也就是宿主的返回压根没跟着 WebView 的历史走（pushState 与 hash 都没能刷新它的 canGoBack 状态，那条 `goBack()` 回调没为这个 Activity 打开）。顺带这也把他看到的现象解释干净了：「退回 KSU 有预览」= `IS_OCCLUDED` 那张跨 Activity 的系统预览；「二级页回概览没有预览」= 那一下根本不是页内返回。结论写进代码注释与 README：**页内返回一律用顶栏箭头**，hash 只留作「在哪一页写在地址上」的排查用途。

* **首次打开时五个页面竖着全堆在一起**：删掉横向轨道之后页面改成了竖排，而初始状态没有任何地方调用 `applyPage` —— 管理器打开 `index.html`（URL 里没有 `?tab=`）时，概览下面依次跟着常驻 / 应用 / 日志 / 属性，整页 **1953px**。之前量不出来，是因为我的探针每次都带 `?tab=`，而旧版的横向轨道又恰好把后四页推到视口外，把这条路径盖住了。两处修：四块面板在标记里就带 `hidden`（JS 没跑之前也不会闪出来），boot 里再走一次 `applyPage('over')` 把标题 / 英雄卡 / 返回箭头定死。修后 `scrollHeight` **1052**、可见面板 **1** 个。

* **去掉横滑切页，底栏回到 Opticon 的形态**。「底栏抽搐」的根因不是某一条 CSS，而是横滑这个前提本身：只要页面是横排轨道，选中项一展开文字（296 ↔ 322）就会在滑动过程中反复变宽变窄，居中的药丸两边一起弹；把它压成定宽图标又「不像 Opticon」。现在横滑整套删掉 —— `.pager` 横向滚动容器、`#nav-ind` 指示胶囊、`scroll` 监听、`syncTrackHeight` 与 `ResizeObserver`、约 60 行触摸处理 —— 面板竖排、用 `hidden` 切换，切页瞬时完成：不滚、不动容器高度、没有相邻页首次绘制那一帧。
  * 底栏按 Opticon 的 `NavItem` 逐项对齐：28px 圆角、`surfaceContainerHigh` + 1dp 描边 + 8dp 投影、内边距 6/8、格距 4、选中格内边距 12/10、图标 22、文字左距 8、labelLarge（14/500/.1）。实测宽度 300（概览 / 应用 / 日志 / 属性）/ 328（常驻列表），五页底边距屏都是 20px；切页逐帧采样 70 帧 / 8 次切换，「同时 0 个或 2 个面板可见」「遮罩出现」的帧都是 **0**，`scrollY` 全程 0 且不抖。
  * 顶栏大标题已经在说当前页，面板里那三个重复的 `<h2>`（常驻应用列表 / 应用列表 / 运行日志）一并删掉 —— 否则切到某页时同一个词出现两遍，还白占一行高度。五页各自滚到底，最后一张卡片与药丸顶边分别留 171 / 232 / 37 / 429 / 18px。
  * 复扫：5 页 × 626 溢出 **0 项**（对照 `flex:0 0 900px` 能报 2 项）；可见文本节点（每页 27~51 个，排除 WCAG 例外的禁用态按钮）对比度浅色最差 **5.37**、深色 **5.73**，0 项不达标；选中格文字对胶囊 **10.11 / 6.87**，未选中图标对药丸 **5.86 / 6.56**。
  * 320px 视口兜底：选中项展开文字后药丸要 328，而 320 的屏只剩 304 —— 加一档 `max-width:344px` 把内边距与格距收紧（图标不缩），实测 276 装得下；626 上不触发。

* **切页闪一下：容器高度在一次切换里跳了两次**。逐帧量出来的：点下去那一瞬 `#pager` 高度是 **561**，下一帧 **236**（目标页还没渲染，量到半成品），再下一帧才 **725** —— 561 → 236 → 725，看上去就是闪。原因是 `showTab` 在目标页渲染之前就同步了容器高度。改法：`showTab` 先 `renderAll()` 把目标页画出来（数据没到就画骨架），再滚、再同步高度。同一条链路复测只剩 **561 → 725 一次**变化，且发生在动画的第一帧。

* **点「只看未纳入」后分段高亮在说谎**：它会把列表切到「已安装第三方」，但上面那个分段仍高亮「生效列表」（实测：`seg=targets*,apps` 而 `appsSrc=apps`）。反过来，在筛选生效时切回「生效列表」，按钮还按着不放，可那个筛选对生效列表根本不生效。现在统一走 `setAppsView(src, onlyMissing)`，来源、高亮、按下态、渲染四者永远同步；切回「生效列表」时筛选自动弹起。实测四次切换的组合全部正确。

* **底部内容被悬浮底栏挡住**：给面板写的 `padding-bottom: calc(96px + 安全区)` 被 `.card` 的 `padding: var(--sp6)` 简写按**源码顺序**盖掉了 —— `.panel` 在 155 行、`.card` 在 157 行，同权重下后者赢，实际只剩 **26px**，而底栏要占 78px，正好压住最后一个条目。改成 `.card.panel`（权重更高、与顺序无关）。实测 620px 高视口下五页各自滚到底：最后一项与底栏顶边分别留 19 / 20 / 19 / 50 / 19px。

* **字体仍然不是系统字体：族名这条路走不通，改成直接把字体文件加载进来**。「写族名」实测**不生效** —— Chromium 在 Android 上有自己的字体映射表，不读 ROM 的 `config_bodyFontFamily` / `fonts_customization.xml`，所以 `--font: "google-sans-flex", system-ui` 里的第一个名字匹配不上，静默退到 `system-ui`（也就是 Roboto）。现在改走文件：`webui.sh env` 从字体注册表里找出该族对应的 ttf（本机 `/product/fonts/GoogleSansFlex-Regular.ttf`，3,997,148 B），拷进 `webroot/fonts/sys.ttf`，界面用 `@font-face` 加载并把它排在字体栈第一位。拷贝按大小判重，只在第一次或字体更新时搬那 4MB。
  * 验证：`--font` 变成 `"ts-sys", system-ui, sans-serif`、`@font-face` 规则注入了、`document.fonts.check("16px ts-sys")` 为 true、同一串文字的 canvas 宽度从 497.4 变 506.1（glyph 真的换了）；把文件参数去掉则退回族名那条，说明负对照也成立。可变字体所以声明 `font-weight:100 900`，并加 `font-display:swap` 避免 4MB 加载期间文字不可见。
  * 概览「关于 → 字体」现在显示走的是哪条路：`系统字体文件`（ok）/ `族名 xxx`（warn，实测多半不生效）/ `WebView 默认`（na）。

* **每切一次页整屏闪一下**：真正的原因是 **「读取中」那层全屏遮罩**，不是面板动画。`goTab` 一律走 `runChain`，而它开头就 `busy(true)` —— `.busy{position:fixed;inset:0;background:var(--scrim)}` 是一层 45% 的黑，压上去再收掉，整页自然闪一下。数据其实早就缓存好了，这一趟什么也不取。现在切页一律静默（`runChain(false, true)`），首次进某页真要取数时把「读取中…」写在该页自己的状态行里。实测：连续切五页（含首次进日志/属性），`#busy` 的 `hidden` 属性**一次都没翻过**（改前有 2 次），日志 9 行、属性 12 行照常填上。
  * 顺带删掉 `.card` 的 `animation:fade`（切页时同样会重播，是第二层闪）—— 这一层单独看也是 220ms 从全透明淡回来。

* **每切一次页都会闪一下**：`.card` 上挂着 `animation:fade 220ms`（从 `opacity:0` 起），而切页是把面板从 `display:none` 切回来 —— 动画每次都会整段重播。实测切一次页 opacity 序列是 **0 → 0.028 → 1**，看上去就是闪一下。删掉面板的入场动画（连同 `@keyframes fade`）；入场效果只留给英雄卡的 `rise`，它从不被隐藏，所以只播一次。改后再量：连续切两次页，四次采样的 opacity 全是 **1**，`animationName` 为 `none`。

* **修掉一根「莫名其妙的白色药丸」—— 它是本界面自己的 snackbar**：隐藏状态只靠 `transform:translate(-50%,140%)` 挪走，而没文字时元素高度只有 16px，140% 只有 22px，**根本没挪出屏幕**。于是它在底部正中常驻成一条 32×16、18px 圆角、底色 `oklch(.99)` 的空白胶囊。实测量到的证据：`visibleNow=true`、`textContent=""`、`w=32 h=16`、`background=oklch(0.99 …)`、`data-show` 为 null —— 一条就够定案。现在用 `opacity:0` 兜底，与高度无关；`[data-show="1"]` 时恢复 `opacity:1`。正对照：调用后 opacity 1、在视口内、文字出现；移除属性后回到 0。

* **界面提示（snackbar）一次都没有出现过**：CSS 里写的是 `.snackbar[data-show=1]{transform:translate(-50%,0)}`，而**属性选择器的值不加引号时必须是合法标识符，`1` 不是** —— Chrome 不报错，直接把整条规则丢掉，于是 snackbar 永远停在初始的 `translate(-50%,140%)`，也就是始终在屏幕外。「保存成功」「同步完成」「命令失败」这些提示其实一条都没被看见过。改成 `[data-show="1"]`。实测：改前 `data-show="1"` 时计算出的 transform 仍是移出视口，改后落在视口内（626×1400 下 top 1357 / bottom 1388）。
  * 同一个坑在这条规则被写出来的同时就中招了，但**没有任何闸会响**——截图台只拍静态页面，不触发提示；补了一条自查：`grep -o '\[[a-zA-Z-]*=[0-9]'`，非空即有问题（注释里的那一处要人工排除）。
  * 顺带把「为什么这条能活下来」查清了：`[data-tone=ok]`、`[aria-checked=true]` 这些值本身是合法标识符，所以整套 tone/lvl 着色一直工作正常，只有数值型的两条中招。
* **认不出 KernelSU 主线提供的桥接，界面显示「无法连接」**：主线管理器注入的是 `window.ksu`，且 `exec(cmd, optionsJson, 回调函数名)` 是**异步**的——Java 侧算完再回调 `window[回调名](errno, stdout, stderr)`；界面原先只认 `bridge` / `kernelsu` / `apatch` / `Magisk` 四个名字上的同步 `exec`，一个都不匹配。现在按官方 `kernelsu` npm 库（3.0.2）的协议实现，并保留同步形状的分支以兼容其它管理器。附带三点：桥接对象可能晚于 `DOMContentLoaded` 才注入，故先轮询 4 秒再判失败；模块目录改由 `ksu.moduleInfo()` 推得（模块 id 变了不用改界面）；异步调用加 60 秒上限，回调万一不来不会永久转圈。
* **进「日志」「属性」页时英雄卡一片 `—`**：三个数字原先按当前页懒加载，而英雄卡在每一页都显示。现在列表随基础信息一起取（三份并发，约 350ms），切到任何一页数字都在。
* **改名替换 `rules.txt` 之后不再自动同步**：inotify 的监视点绑的是 inode，而「写临时文件再改名覆盖」正是 `vim`、`sed -i` 与本模块 WebUI 原子保存的写法。替换后旧 inode 已被 unlink，挂在它上面的监视不再上报任何事件；又因为守护进程同时还挂着 `/data/system`，`inotifyd` 的「所有监视目标都失效才退出」条件不成立，也就不会被外层循环重启 —— 表现是改了常驻列表不再同步，且只有重启才恢复。现在监听挂在**目录**上（掩码 `cwmy`），文件级监视保留作就地改写的兜底。`/data/system` 同理，`packages.list` 也是 PackageManager 用临时文件改名重写的。
  * 事件过滤从裸子串改成整字段匹配：`sed -i` 的临时文件叫 `rules.txtXXXXXX`，子串匹配会把它当成一次变更（实测一次 `sed -i` 产生的 8 条命中里 3 条是这种误触发）。
  * 掩码里 `m` 与 `y` 同时给：toybox 的 `--help` 写「m 移入、y 移出」，busybox 恰好相反，而**实测两家在「改名覆盖」时上报的都是 `y`** —— help 文本不可信，两个都带上就不必赌设备上是哪一个。
  * `inotifywait` 分支同样改挂目录并补 `close_write` / `moveto`。本机没有 `inotifywait` 可测（只有 `inotifyd`），因此加了一次 1 秒的实跑探测：参数不被接受就退回旧事件集并写警告，避免"不认识参数 → 监听进程 3 秒一轮空转"。
  * 真机逐场景验证（每次操作经 2 秒防抖后应且只应触发一次同步）：`mv` 改名替换 +1、替换之后就地追加 +1、同目录无关文件 +0、`sed -i` +1、再次 `mv` +1；原始事件每次 2~4 条（`c` / `w` / `y` / `x`），由既有防抖合并。

#### 兼容范围

* **两件事查过上游源码，确认不做**（记在这里是为了下次不再凭"应该有"的直觉去造控件）：
  * **Tricky 没有 RKP 面**：全树 `rkp|RKP|RemoteProvisioning|rkp.json|verifiedBootState` 只有一个假命中（README 里的 `FrameworkPatch`），既无实现也无文档；它也没有任何面板可触发的 canary/自检 —— 最接近的是启动时那次 `AttestUtils.probe()`（`Main.kt:24`），外部无法调用。以前计划里那条"RKP 三属性"是把 `security_patch.txt` 的**三档补丁级别**（os/vendor/boot）记错了名字 —— 那三档界面早就有了。
  * **OMK 没有密钥管理 CLI**：只装两个二进制（`keymint`、`injector`），都不解析 argv，没有 `--help`、没有子命令。密钥管理面是 binder 服务（`IOhMyKsService` / `IOhMyMaintenanceService`），而 `src/main.rs:169-178` 只放行 `uid == KEYSTORE_UID(1017)` 的对端 —— root 也调不动。所谓"KeyAdmin 15 个操作"是**测试工具** `tests/src/bin/keyadmin.rs` 的用法表，不是产品接口。顺带两条事实值得进界面文案：`clear` 与 `deleteAllKeys` 是对**真 TEE/StrongBox** 的不可逆删除；换 keybox 默认就会把它绑定的旧密钥全部作废（`retire_stale_keybox_bound_keys` 默认 true，`keybox.rs:523-532`）—— 这句已写进 keybox 卡的说明。
  * 唯一还能走的路是 `log -p e -t KeyAdmin "<op>"`（守护进程从 logd 环形缓冲里按标签取行），但它要求日志开着（README.md:104 说关了就永久关着），属于"能跑但不可靠"，本轮不做。
* 界面依赖管理器提供的 root shell 桥接（`window.ksu`（KernelSU 主线，异步回调）/ `window.bridge` / `window.kernelsu` / `window.apatch` / `window.Magisk` 任一）；无桥接时界面显示明确提示、列出扫描到的注入对象与方法，并给出等价的 `webui.sh` 命令，模块自身行为完全不变。
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