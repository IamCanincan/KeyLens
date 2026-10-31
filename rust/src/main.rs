//! KeyLens 命令层（Rust 版）——阶段 0：分发表 + `contract`；阶段 1：`log`。
//!
//! 契约与 shell 版逐字一致：`KL_API=4`、`KL_COMMANDS` 40 条、`contract` 输出
//! `api=4` 与 `commands=<空格分隔>`。未迁移的命令返回 2（不假装成功），
//! 便于对拍时区分「还没做」与「做错了」。

mod backend;

use std::io::Write;
use std::process::{exit, Command};

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
  help                打印本帮助

读命令：status env targets target-meta apps icons log props boot-hash excluded
        backend-info teesim-profiles tee-status tricky-patches teesim-overrides
        doctor backups
写命令：props-apply props-on props-off props-boot-hash restore-app restore-apps
        remove-apps set-mode teesim-save teesim-save-overrides omk-save-injector
        omk-save-config tricky-save-patch tricky-drop-patch keybox-save sync
        clear-log omk-restart teesim-profile-new teesim-profile-del backup-restore
";

/// shell 的 `clamp_int <值> <默认> <最小> <最大>`：空/非数字 → 默认；否则夹取。
fn clamp_int(v: &str, d: i64, lo: i64, hi: i64) -> i64 {
    let digits = !v.is_empty() && v.bytes().all(|b| b.is_ascii_digit());
    if !digits {
        return d;
    }
    v.parse::<i64>().unwrap_or(d).max(lo).min(hi)
}

/// `tail -n <n>` 的等价：按行切分，保留各自的行尾，取末尾 n 行原样输出。
fn tail_bytes(data: &[u8], n: usize) -> Vec<u8> {
    let mut lines: Vec<&[u8]> = data.split_inclusive(|b| *b == b'\n').collect();
    if lines.len() > n {
        lines.drain(..lines.len() - n);
    }
    let mut out = Vec::new();
    for l in lines {
        out.extend_from_slice(l);
    }
    out
}

/// 与 shell 版一致：优先读缓冲文件；不存在时退回 `logcat -d -s KeyLens`。
fn cmd_log(arg: &str) {
    let n = clamp_int(arg, 60, 1, 400) as usize;
    let path = std::env::var("KEYLENS_LOG").unwrap_or_else(|_| "/data/adb/keylens.log".to_string());
    if let Ok(data) = std::fs::read(&path) {
        let _ = std::io::stdout().write_all(&tail_bytes(&data, n));
        return;
    }
    if let Ok(out) = Command::new("logcat")
        .args(["-d", "-s", "KeyLens"])
        .output()
    {
        let _ = std::io::stdout().write_all(&tail_bytes(&out.stdout, n));
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let cmd = args.get(1).map(|s| s.as_str()).unwrap_or("help");
    let arg = args.get(2).map(|s| s.as_str()).unwrap_or("");

    match cmd {
        "contract" => {
            println!("api={}", KL_API);
            println!("commands={}", COMMANDS.join(" "));
        }
        "log" => cmd_log(arg),
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
