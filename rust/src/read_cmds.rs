//! 读命令：log / backups（与 shell 版逐字节一致）。

use crate::backend::{self, Backend, BackendId, Paths, Root};
use std::path::PathBuf;
use std::time::UNIX_EPOCH;

/// shell 的 `clamp_int <值> <默认> <最小> <最大>`：空/非数字 → 默认；否则夹取。
pub fn clamp_int(v: &str, d: i64, lo: i64, hi: i64) -> i64 {
    let digits = !v.is_empty() && v.bytes().all(|b| b.is_ascii_digit());
    if !digits {
        return d;
    }
    v.parse::<i64>().unwrap_or(d).max(lo).min(hi)
}

/// `tail -n <n>` 的等价：按行切分，保留各自的行尾，取末尾 n 行原样输出。
pub fn tail_bytes(data: &[u8], n: usize) -> Vec<u8> {
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

/// cmd_log：优先读缓冲文件；不存在时退回 `logcat -d -s KeyLens`。
pub fn log(arg: &str) {
    let n = clamp_int(arg, 60, 1, 400) as usize;
    let root = Root::from_env();
    let p = Paths::new(&root);
    let path = std::env::var("KEYLENS_LOG").map(PathBuf::from).unwrap_or_else(|_| p.log.clone());
    if let Ok(data) = std::fs::read(&path) {
        let _ = std::io::stdout().write_all(&tail_bytes(&data, n));
        return;
    }
    if let Ok(out) = std::process::Command::new("logcat").args(["-d", "-s", "KeyLens"]).output() {
        let _ = std::io::stdout().write_all(&tail_bytes(&out.stdout, n));
    }
}

use std::io::Write;

/// backup_target_for：备份名 → 它对应的后端文件；未映射返回 None（shell 里是 continue）。
/// 注：teesim 的 keybox 自定义文件名（default_keybox）暂按标准名处理。
fn backup_target(b: &Backend, p: &Paths, name: &str) -> Option<PathBuf> {
    match name {
        "config.json.bak" if b.id == BackendId::Teesim => Some(p.teesim_config.clone()),
        "overrides.json.bak" if b.id == BackendId::Teesim => Some(p.teesim_dir.join("overrides.json")),
        "injector.toml.bak" if b.id == BackendId::Omk => Some(p.omk_injector.clone()),
        "config.toml.bak" if b.id == BackendId::Omk => Some(p.omk_dir.join("config.toml")),
        "keybox.xml.bak" => Some(match b.id {
            BackendId::Teesim => p.teesim_dir.join("keybox.xml"),
            BackendId::Omk => p.omk_dir.join("keybox.xml"),
            BackendId::Tricky => p.tstore_dir.join("keybox.xml"),
        }),
        "security_patch.txt.bak" if b.id == BackendId::Tricky => Some(p.tstore_dir.join("security_patch.txt")),
        _ => None,
    }
}

/// cmd_backups：列当前后端目录里的 .bak（名称<TAB>字节<TAB>mtime<TAB>目标文件）。
pub fn backups() {
    let root = Root::from_env();
    let p = Paths::new(&root);
    let b = backend::detect(&p);
    let mut names: Vec<String> = match std::fs::read_dir(&b.dir) {
        Ok(rd) => rd
            .filter_map(|e| {
                let e = e.ok()?;
                let n = e.file_name().into_string().ok()?;
                if n.ends_with(".bak") && e.path().is_file() { Some(n) } else { None }
            })
            .collect(),
        Err(_) => Vec::new(),
    };
    names.sort();
    for name in names {
        let Some(tgt) = backup_target(&b, &p, &name) else { continue };
        let path = b.dir.join(&name);
        let md = match std::fs::metadata(&path) { Ok(m) => m, Err(_) => continue };
        let mt = md.modified().ok()
            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
            .map(|d| d.as_secs())
            .unwrap_or(0);
        println!("{}\t{}\t{}\t{}", name, md.len(), mt, tgt.display());
    }
}
