//! KeyLens 命令层（Rust 版）。
//!
//! 契约与 shell 版逐字一致：`KL_API=4`、`KL_COMMANDS` 40 条、`contract` 输出
//! `api=4` 与 `commands=<空格分隔>`。未迁移的命令返回 2（不假装成功），
//! 便于对拍时区分「还没做」与「做错了」。

mod backend;
mod read_cmds;

use std::process::exit;

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
KeyLens 命令层（Rust）

用法：keylens <命令> [参数]

  contract            打印契约号与命令清单
  log <行数>          日志缓冲末尾内容（默认 60，夹取 1..400）
  backups             .bak 列表：名称<TAB>字节<TAB>mtime<TAB>目标文件
  help                打印本帮助

读命令：status env targets target-meta apps icons log props boot-hash excluded
        backend-info teesim-profiles tee-status tricky-patches teesim-overrides
        doctor backups
写命令：props-apply props-on props-off props-boot-hash restore-app restore-apps
        remove-apps set-mode teesim-save teesim-save-overrides omk-save-injector
        omk-save-config tricky-save-patch tricky-drop-patch keybox-save sync
        clear-log omk-restart teesim-profile-new teesim-profile-del backup-restore
";

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let cmd = args.get(1).map(|s| s.as_str()).unwrap_or("help");
    let arg = args.get(2).map(|s| s.as_str()).unwrap_or("");

    match cmd {
        "contract" => {
            println!("api={}", KL_API);
            println!("commands={}", COMMANDS.join(" "));
        }
        "log" => read_cmds::log(arg),
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
}
