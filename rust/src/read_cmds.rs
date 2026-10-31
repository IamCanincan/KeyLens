//! 读命令：status / log / backups（与 shell 版逐字节一致）。

use crate::backend::{self, Backend, BackendId, Paths, Root};
use std::path::{Path, PathBuf};
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

/// module.prop 的某个键（mod_prop）：`k=值` 的第一行。
fn mod_prop(prop_file: &Path, key: &str) -> String {
    let Ok(text) = std::fs::read_to_string(prop_file) else { return String::new() };
    let prefix = format!("{}=", key);
    for line in text.lines() {
        if let Some(v) = line.strip_prefix(&prefix) {
            return v.to_string();
        }
    }
    String::new()
}

fn backend_state(dir: &Path) -> &'static str {
    if !dir.is_dir() {
        "absent"
    } else if dir.join("disable").is_file() {
        "disabled"
    } else {
        "active"
    }
}

fn writable(path: &Path) -> bool {
    match std::fs::metadata(path) {
        Ok(md) => !md.permissions().readonly(),
        Err(_) => false,
    }
}

/// cmd_status：与 shell 版同键同序（kv 一行一个 `k=v`）。
pub fn status() {
    let root = Root::from_env();
    let p = Paths::new(&root);
    let b = backend::detect(&p);
    let desc = mod_prop(&p.module_prop, "description");
    let state = if desc.starts_with('⛔') {
        "stopped"
    } else if desc.starts_with("⚠\u{fe0f}") {
        "failed"
    } else if desc.starts_with('✅') {
        "ok"
    } else {
        "unknown"
    };
    let teesim_st = backend_state(&p.teesim_module);
    let tricky_st = backend_state(&p.tricky_module);
    let omk_st = backend_state(&p.omk_module);
    let (mut exists, mut tw) = (0, 0);
    if b.target.is_file() {
        exists = 1;
        if writable(&b.target) { tw = 1; }
    } else if b.dir.is_dir() && writable(&b.dir) {
        tw = 1;
    }
    let mtime = if b.target.is_file() {
        std::fs::metadata(&b.target).ok()
            .and_then(|m| m.modified().ok())
            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
            .map(|d| d.as_secs().to_string())
            .unwrap_or_default()
    } else { String::new() };
    let conflict = [teesim_st, tricky_st, omk_st].iter().filter(|s| **s == "active").count() > 1;
    let bname = match b.id {
        BackendId::Teesim => "TEE Simulator",
        BackendId::Omk => "OhMyKeymint",
        BackendId::Tricky => "Tricky Store",
    };
    let kv = |k: &str, v: &str| println!("{}={}", k, v);
    kv("state", state);
    kv("description", &desc);
    kv("mod_id", &mod_prop(&p.module_prop, "id"));
    kv("mod_version", &mod_prop(&p.module_prop, "version"));
    kv("backend", b.id.as_str());
    kv("backend_name", bname);
    kv("conflict", if conflict { "1" } else { "0" });
    kv("teesim_state", teesim_st);
    kv("tricky_state", tricky_st);
    kv("omk_state", omk_st);
    kv("data_dir", &b.dir.to_string_lossy());
    kv("target_file", &b.target.to_string_lossy());
    kv("target_exists", if exists == 1 { "1" } else { "0" });
    kv("target_writable", if tw == 1 { "1" } else { "0" });
    kv("target_mtime", &mtime);
    kv("props_masking", if p.props_off.is_file() { "off" } else { "on" });
    kv("props_off_file", &p.props_off.to_string_lossy());
    // 守护进程：pids 文件里仍存活的进程数（同 shell 的 kill -0）
    let mut alive = 0u32;
    if let Ok(text) = std::fs::read_to_string(b.dir.join(".kl_daemon_pids.list")) {
        for pid in text.lines().map(str::trim).filter(|s| !s.is_empty()) {
            if std::path::Path::new(&format!("/proc/{}", pid)).exists() {
                alive += 1;
            }
        }
    }
    kv("daemon_alive", &alive.to_string());
    let (mut lines, mut bytes) = (String::new(), String::new());
    if let Ok(data) = std::fs::read(&p.log) {
        lines = data.iter().filter(|b| **b == b'\n').count().to_string();
        bytes = data.len().to_string();
    }
    kv("log_file", &p.log.to_string_lossy());
    kv("log_lines", &lines);
    kv("log_bytes", &bytes);
}

/// 包名语法：与 tricky_list.awk 的正则同义（≥2 段，每段字母/下划线开头）。
fn valid_pkg(s: &str) -> bool {
    let segs: Vec<&str> = s.split('.').collect();
    if segs.len() < 2 {
        return false;
    }
    segs.iter().all(|seg| {
        let mut ch = seg.chars();
        match ch.next() {
            Some(c) if c.is_ascii_alphabetic() || c == '_' => {}
            _ => return false,
        }
        ch.all(|c| c.is_ascii_alphanumeric() || c == '_')
    })
}

/// tricky_list.awk 的等价：去 CR、剥行内 # 注释、trim、取 ?/! 后缀、包名校验，
/// 同一基础包名按**首次出现顺序**输出**最后一次**的模式。
fn tricky_tokens(text: &str) -> Vec<String> {
    let mut order: Vec<String> = Vec::new();
    let mut last: std::collections::HashMap<String, String> = std::collections::HashMap::new();
    for raw in text.split('\n') {
        let mut line = raw.strip_suffix('\r').unwrap_or(raw).to_string();
        if let Some(h) = line.find('#') {
            line.truncate(h);
        }
        let line = line.trim_matches(|c: char| c == ' ' || c == '\t').to_string();
        if line.is_empty() {
            continue;
        }
        let trimmed = line.as_str();
        let (tok, base) = match trimmed.chars().last() {
            Some(sfx @ ('?' | '!')) => {
                let b = trimmed[..trimmed.len() - 1]
                    .trim_end_matches(|c: char| c == ' ' || c == '\t')
                    .to_string();
                (format!("{}{}", b, sfx), b)
            }
            _ => (trimmed.to_string(), trimmed.to_string()),
        };
        if !valid_pkg(&base) {
            continue;
        }
        if !last.contains_key(&base) {
            order.push(base.clone());
        }
        last.insert(base, tok);
    }
    order.into_iter().map(|b| last[&b].clone()).collect()
}

/// 在 `s[from..]` 找 needle 的字节下标（等价 awk 的 findstr）。
fn find_from(s: &[u8], from: usize, needle: &[u8]) -> Option<usize> {
    if from >= s.len() || needle.is_empty() {
        return None;
    }
    s[from..]
        .windows(needle.len())
        .position(|w| w == needle)
        .map(|p| p + from)
}

/// 与 open 处的 `{`/`[` 配对的闭合下标；跳过字符串与转义（等价 awk 的 matchclose）。
fn match_close(s: &[u8], open: usize) -> Option<usize> {
    let mut depth = 0i32;
    let mut instr = false;
    let mut esc = false;
    for i in open..s.len() {
        let c = s[i];
        if instr {
            if esc {
                esc = false;
            } else if c == b'\\' {
                esc = true;
            } else if c == b'"' {
                instr = false;
            }
            continue;
        }
        if c == b'"' {
            instr = true;
            continue;
        }
        if c == b'{' || c == b'[' {
            depth += 1;
        } else if c == b'}' || c == b']' {
            depth -= 1;
            if depth == 0 {
                return Some(i);
            }
        }
    }
    None
}

/// 取一段字节里的所有 "..." 内容（等价 awk 的 while (match(seg, /"[^"]*"/))）。
fn quoted_strings(seg: &[u8]) -> Vec<String> {
    let mut out = Vec::new();
    let mut i = 0usize;
    while i < seg.len() {
        if seg[i] == b'"' {
            let start = i + 1;
            let mut j = start;
            while j < seg.len() && seg[j] != b'"' {
                j += 1;
            }
            if j < seg.len() {
                out.push(String::from_utf8_lossy(&seg[start..j]).into_owned());
                i = j + 1;
                continue;
            }
            break;
        }
        i += 1;
    }
    out
}

/// teesim_list.awk：profiles → default → {…} → "apps" → [ … ] 里的字符串。
fn teesim_apps(buf: &[u8]) -> Option<Vec<String>> {
    let pp = find_from(buf, 0, b"\"profiles\"")?;
    let dp = find_from(buf, pp, b"\"default\"")?;
    let ob = find_from(buf, dp + 9, b"{")?;
    let cb = match_close(buf, ob)?;
    let ap = find_from(buf, ob, b"\"apps\"")?;
    if ap > cb {
        return None;
    }
    let ab = find_from(buf, ap + 6, b"[")?;
    if ab > cb {
        return None;
    }
    let ae = match_close(buf, ab)?;
    if ae > cb {
        return None;
    }
    Some(quoted_strings(&buf[ab + 1..ae]))
}

/// omk_list.awk：行首（可缩进）`scoop = [` … `]` 里的字符串。
fn omk_scoop(buf: &[u8]) -> Option<Vec<String>> {
    let mut i = 0usize;
    let mut found = None;
    while i < buf.len() {
        // 行首
        let line_start = i;
        let mut j = i;
        while j < buf.len() && (buf[j] == b' ' || buf[j] == b'\t') {
            j += 1;
        }
        if buf[j..].starts_with(b"scoop") {
            let mut k = j + 5;
            while k < buf.len() && (buf[k] == b' ' || buf[k] == b'\t') {
                k += 1;
            }
            if k < buf.len() && buf[k] == b'=' {
                k += 1;
                while k < buf.len() && (buf[k] == b' ' || buf[k] == b'\t') {
                    k += 1;
                }
                if k < buf.len() && buf[k] == b'[' {
                    found = Some(k);
                    break;
                }
            }
        }
        // 下一行
        match buf[line_start..].iter().position(|b| *b == b'\n') {
            Some(nl) => i = line_start + nl + 1,
            None => break,
        }
    }
    let ob = found?;
    let cb = match_close(buf, ob)?;
    Some(quoted_strings(&buf[ob + 1..cb]))
}

/// cmd_targets：当前后端的目标列表。
pub fn targets() {
    let root = Root::from_env();
    let p = Paths::new(&root);
    let b = backend::detect(&p);
    if !b.target.is_file() {
        eprintln!("目标文件不存在：{}", b.target.display());
        std::process::exit(1);
    }
    let data = std::fs::read(&b.target).unwrap_or_default();
    match b.id {
        BackendId::Tricky => {
            let text = String::from_utf8_lossy(&data);
            for t in tricky_tokens(&text) {
                println!("{}", t);
            }
        }
        BackendId::Teesim => match teesim_apps(&data) {
            Some(v) => v.iter().for_each(|s| println!("{}", s)),
            None => std::process::exit(1),
        },
        BackendId::Omk => match omk_scoop(&data) {
            Some(v) => v.iter().for_each(|s| println!("{}", s)),
            None => std::process::exit(1),
        },
    }
}
