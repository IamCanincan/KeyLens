//! KeyLens 命令层（Rust 版）。
//!
//! 契约与 shell 版逐字一致：`KL_API=4`、`KL_COMMANDS` 40 条、`contract` 输出
//! `api=4` 与 `commands=<空格分隔>`。未迁移的命令返回 2（不假装成功），
//! 便于对拍时区分「还没做」与「做错了」。

mod b64;
mod backend;
mod json_flat;
mod keybox;
mod payload;
mod lock;
mod ov_valid;
mod read_cmds;

use std::process::exit;

/// 往 stdout 写一段文本，写不进去（管道被关、EPIPE 等）就静静放弃。
/// 与 shell 版行为一致：`cmd | head -1` 不该让命令崩掉。
fn emit(s: &str) {
    use std::io::Write;
    let _ = std::io::stdout().write_all(s.as_bytes());
}

const KL_API: &str = "4";

/// 与 `module/webui.sh` 的 `KL_COMMANDS` 逐字同序（对拍要求）。
const COMMANDS: &[&str] = &[
    "status", "env", "targets", "target-meta", "apps", "icons", "log", "clear-log",
    "props", "props-apply", "props-on", "props-off", "boot-hash", "props-boot-hash",
    "restore-app", "restore-apps", "remove-apps", "set-mode", "backend-info",
    "teesim-save", "omk-save-injector", "omk-save-config", "tricky-save-patch",
    "tricky-drop-patch", "keybox-save", "sync", "help", "contract", "excluded",
    "teesim-profiles", "tee-status", "tricky-patches", "omk-restart",
    "teesim-overrides", "teesim-save-overrides", "teesim-profile-new",
    "teesim-profile-del", "doctor", "backups", "backup-restore",
];

const USAGE: &str = "\
用法：sh webui.sh <命令> [参数]
  status                 全部运行状态（key=value）
  env                    环境能力（resetprop / awk / base64 / inotify）
  targets                当前生效的应用列表（保留 pkg? / pkg! / pkg@用户 / uid: 原样）
  target-meta            目标条目元数据（token<TAB>base<TAB>kind<TAB>detail）
  apps                   已安装的第三方应用
  icons <包名,...>       从桌面图标缓存导出 PNG 与显示名（包名<TAB>显示名<TAB>相对路径）
  log <行数>             日志缓冲末尾内容
  clear-log              清空日志缓冲
  props                  属性名/当前值/期望值/状态（TAB 分隔）
  props-apply            立刻按期望表写一次属性
  props-on|props-off     开关开机属性伪装
  boot-hash              读取 Verified Boot 哈希配置与当前 digest
  props-boot-hash <值|-> 保存并立即应用 verifiedBootHash（- 清除）
  restore-app <包名>     把未纳入或已排除的应用加入目标名单
  restore-apps <包名,...> 批量加入（逗号分隔；只写一次目标文件）
  remove-apps <包名,...> 批量移出（逗号分隔；只写一次；至少保留一条）
  set-mode <包名> <模式>  Tricky 专用：auto / leaf / generate
  backend-info           当前后端的配置摘要
  teesim-profiles        TEE Simulator：列出所有 profile（名字/关键/模式/条目数/是否默认）
  tee-status             Tricky：读它自己写的 TEE 探测结果（present/status/teeBroken…）
  teesim-overrides       TEE Simulator：读 overrides.json（安全等级/版本/启动键哈希，含各项可否编辑）
  tricky-patches         Tricky：列出 security_patch.txt 的全局与按包补丁块
  omk-restart <范围>     OhMyKeymint：触发重载，范围 = keymint | injector | all
  teesim-save <b64>      TEE Simulator default profile 字段（payload）
  omk-save-injector <b64> OhMyKeymint injector.toml 字段（payload）
  omk-save-config <b64>  OhMyKeymint config.toml 字段（payload）
  tricky-save-patch <b64> Tricky security_patch.txt 全局值（payload）
  tricky-drop-patch <包名> 删掉 Tricky security_patch.txt 里的 [包名] 段
  teesim-profile-new <名字> 复制 default 新建一份 TEESim profile
  teesim-profile-del <名字> 删除一个 TEESim profile（default 不可删）
  keybox-save <b64>      替换当前后端的 keybox.xml（base64 XML）
  sync                   立即同步一次应用列表
  contract               自报命令层契约号与命令清单
  excluded               列出被人为排除（手动删除）的包名
";

/// 预览：在影子根里跑同一条命令，事后比对差异（不碰真实文件）。
fn preview_run(cmd: &str, arg: &str) -> ! {
    use std::path::PathBuf;
    let real = std::env::var("KEYLENS_ROOT").unwrap_or_default();
    let real_base: PathBuf = if real.is_empty() { PathBuf::from("/") } else { PathBuf::from(&real) };
    let shadow = std::env::temp_dir().join(format!("keylens-preview-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&shadow);
    // 参与比对的候选文件：三家后端配置 + keybox + module.prop
    let candidates = [
        "/data/adb/tricky_store/target.txt",
        "/data/adb/tricky_store/security_patch.txt",
        "/data/adb/tricky_store/keybox.xml",
        "/data/adb/teesim/config.json",
        "/data/adb/teesim/overrides.json",
        "/data/adb/teesim/keybox.xml",
        "/data/misc/keystore/omk/injector.toml",
        "/data/misc/keystore/omk/config.toml",
        "/data/misc/keystore/omk/keybox.xml",
        "/data/adb/modules/keylens/module.prop",
    ];
    for rel in candidates {
        let src = real_base.join(rel.trim_start_matches('/'));
        if !src.is_file() {
            continue;
        }
        let dst = shadow.join(rel.trim_start_matches('/'));
        if let Some(dir) = dst.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let _ = std::fs::copy(&src, &dst);
    }
    // 锁目录 / 状态目录也要在影子根里存在，否则"加锁失败"会误报成守护进程在写
    for d in [
        "/data/adb/omk",
        "/data/adb/tricky_store",
        "/data/adb/teesim",
        "/data/misc/keystore/omk",
    ] {
        let src = real_base.join(d.trim_start_matches('/'));
        if src.is_dir() {
            let _ = std::fs::create_dir_all(shadow.join(d.trim_start_matches('/')));
        }
    }
    // 后端探测看模块目录是否存在：影子根里也要有同样的目录结构，否则会认错后端
    for md in [
        "/data/adb/modules/oh_my_keymint",
        "/data/adb/modules/teesim",
        "/data/adb/modules/tricky_store",
        "/data/adb/modules/keylens",
    ] {
        let src = real_base.join(md.trim_start_matches('/'));
        if !src.is_dir() {
            continue;
        }
        let dst = shadow.join(md.trim_start_matches('/'));
        let _ = std::fs::create_dir_all(&dst);
        for f in ["module.prop", "disable"] {
            let sp = src.join(f);
            if sp.is_file() {
                let _ = std::fs::copy(&sp, dst.join(f));
            }
        }
    }
    // 影子根下的同一条命令（用环境变量防止再递归）
    let exe = std::env::current_exe().unwrap_or_else(|_| PathBuf::from("keylens"));
    let out = std::process::Command::new(exe)
        .arg(cmd)
        .arg(arg)
        .env("KEYLENS_ROOT", shadow.to_string_lossy().into_owned())
        .env("KL_PREVIEW_CHILD", "1")
        .output();
    let mut lines: Vec<String> = Vec::new();
    match out {
        Ok(o) => {
            let text = String::from_utf8_lossy(&o.stdout).into_owned();
            for line in text.lines() {
                // 子进程看到的是影子根，输出里的路径要还原成真实路径
                let sp = shadow.to_string_lossy().into_owned();
                lines.push(line.replace(&sp, ""));
            }
            let err = String::from_utf8_lossy(&o.stderr).into_owned();
            if !err.trim().is_empty() {
                eprint!("{}", err);
            }
        }
        Err(e) => {
            eprintln!("预览失败：{}", e);
        }
    }
    // keybox_sha 要报"真实文件"的哈希：子进程看到的是影子根，里面已经是新内容
    let mut real_kb = String::new();
    for line in &lines {
        if let Some(v) = line.strip_prefix("keybox_file=") {
            real_kb = v.to_string();
            break;
        }
    }
    let real_sha = if real_kb.is_empty() {
        String::new()
    } else {
        std::process::Command::new("sha256sum")
            .arg(&real_kb)
            .output()
            .ok()
            .map(|o| String::from_utf8_lossy(&o.stdout).split_whitespace().next().unwrap_or("").to_string())
            .unwrap_or_default()
    };
    for line in &lines {
        if !real_sha.is_empty() {
            if line.starts_with("keybox_sha=") {
                println!("keybox_sha={}", real_sha);
                continue;
            }
        }
        println!("{}", line);
    }
    // 差异
    let mut diff: Vec<String> = Vec::new();
    for rel in candidates {
        let a = real_base.join(rel.trim_start_matches('/'));
        let b = shadow.join(rel.trim_start_matches('/'));
        if !b.is_file() {
            continue;
        }
        let old = std::fs::read(&a).unwrap_or_default();
        let new = std::fs::read(&b).unwrap_or_default();
        if old == new {
            continue;
        }
        let old_s = String::from_utf8_lossy(&old).into_owned();
        let new_s = String::from_utf8_lossy(&new).into_owned();
        diff.extend(read_cmds::lcs_diff(&old_s, &new_s));
    }
    let changed = diff.iter().filter(|l| l.starts_with('+') || l.starts_with('-')).count();
    let body = diff.join("\n");
    println!("preview=1");
    println!("changed={}", changed);
    println!("diff={}", crate::b64::encode_bytes(body.as_bytes()));
    let _ = std::fs::remove_dir_all(&shadow);
    std::process::exit(0);
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let cmd = args.get(1).map(|s| s.as_str()).unwrap_or("help");
    let arg = args.get(2).map(|s| s.as_str()).unwrap_or("");

    // 写前预览：preview-<写命令> 走同一条实现，但只出 diff 不落盘
    let mut cmd = cmd;
    if let Some(base) = cmd.strip_prefix("preview-") {
        const PREVIEWABLE: &[&str] = &[
            "teesim-save", "teesim-save-overrides", "teesim-profile-new", "teesim-profile-del",
            "omk-save-injector", "omk-save-config", "tricky-save-patch", "tricky-drop-patch", "keybox-save",
        ];
        if PREVIEWABLE.contains(&base) {
            if std::env::var("KL_PREVIEW_CHILD").is_ok() {
                // 子进程：正常执行，写入落在影子根里
                cmd = base;
            } else {
                preview_run(base, arg);
            }
        } else {
            eprintln!("未知命令：preview-{}", base);
            std::process::exit(1);
        }
    }
    match cmd {
        "contract" => {
            // 用 write_all 而不是 println!：Rust 默认忽略 SIGPIPE，管道被下游关掉时
            // println! 会 panic（`keylens contract | head -1` 就能复现）。这类失败
            // 不需要处理，但绝不能变成崩溃 + 栈回溯。
            emit(&format!("api={}\n", KL_API));
            emit(&format!("commands={}\n", COMMANDS.join(" ")));
        }
        "log" => read_cmds::log(arg),
        "status" => read_cmds::status(),
        "targets" => read_cmds::targets(),
        "target-meta" => read_cmds::target_meta(),
        "apps" => read_cmds::apps(),
        "excluded" => read_cmds::excluded(),
        "boot-hash" => read_cmds::boot_hash(),
        "tee-status" => read_cmds::tee_status(),
        "props" => read_cmds::props(),
        "clear-log" => read_cmds::clear_log(),
        "omk-restart" => read_cmds::omk_restart(arg),
        "set-mode" => read_cmds::set_mode(arg, args.get(3).map(|s| s.as_str()).unwrap_or("")),
        "props-on" => read_cmds::props_switch("on"),
        "props-off" => read_cmds::props_switch("off"),
        "props-boot-hash" => read_cmds::props_boot_hash(arg),
        "props-apply" => read_cmds::props_apply(),
        "tricky-drop-patch" => read_cmds::tricky_drop_patch(arg),
        "tricky-save-patch" => read_cmds::tricky_save_patch(arg),
        "tricky-patches" => read_cmds::tricky_patches(),
        "teesim-overrides" => read_cmds::teesim_overrides(),
        "teesim-save-overrides" => read_cmds::teesim_save_overrides(arg),
        "keybox-save" => read_cmds::keybox_save(arg),
        "backup-restore" => read_cmds::backup_restore(arg),
        "teesim-profile-del" => read_cmds::teesim_profile_del(arg),
        "teesim-profile-new" => read_cmds::teesim_profile_new(arg),
        "doctor" => read_cmds::doctor(),
        "restore-app" => read_cmds::restore_app(arg),
        "restore-apps" => read_cmds::restore_apps(arg),
        "remove-apps" => read_cmds::remove_apps(arg),
        "teesim-save" => read_cmds::teesim_save(arg),
        "omk-save-injector" => read_cmds::omk_save_injector(arg),
        "omk-save-config" => read_cmds::omk_save_config(arg),
        "backend-info" => read_cmds::backend_info(),
        "env" => read_cmds::env_cmd(),
        "sync" => read_cmds::sync(),
        "icons" => read_cmds::icons(arg),
        "teesim-profiles" => read_cmds::teesim_profiles(),
        "backups" => read_cmds::backups(),
        "help" => print!("{}", USAGE),
        // 尚未迁移的命令：明确返回 2，别假装成功。
        _ if COMMANDS.contains(&cmd) => {
            eprintln!("{}：尚未迁移（阶段 1 进行中）", cmd);
            exit(2);
        }
        other => {
            eprintln!("未知命令：{}（可用：keylens help）", other);
            exit(1);
        }
    }

    // 预览收尾：差异交给界面（base64，免得换行破坏 kv 的逐行解析）
    if read_cmds::preview_on() {
        read_cmds::preview_tail();
    }
}
