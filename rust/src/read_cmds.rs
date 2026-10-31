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

/// cmd_apps：已装第三方应用（`cmd package …`，失败退回 `pm list`），去前缀、
/// 去 `[N]` 尾缀、排序去重。
pub fn apps() {
    let run = |prog: &str, args: &[&str]| -> Option<Vec<u8>> {
        std::process::Command::new(prog).args(args).output().ok().map(|o| o.stdout)
    };
    let out = run("cmd", &["package", "list", "packages", "-3", "--user", "all"])
        .filter(|o| !o.is_empty())
        .or_else(|| run("pm", &["list", "packages", "-3"]))
        .unwrap_or_default();
    let text = String::from_utf8_lossy(&out);
    let mut names: Vec<&str> = Vec::new();
    for line in text.lines() {
        let Some(rest) = line.strip_prefix("package:") else { continue };
        // 去掉结尾的 [数字]（多用户/多 profile 的编号）
        let mut name = rest;
        if let Some(open) = name.rfind('[') {
            if name.ends_with(']') && name[open + 1..name.len() - 1].bytes().all(|c| c.is_ascii_digit()) {
                name = &name[..open];
            }
        }
        if !name.is_empty() {
            names.push(name);
        }
    }
    names.sort_unstable();
    names.dedup();
    for n in names {
        println!("{}", n);
    }
}

/// 目标条目 → 基础包名（entry_base.awk 的等价）。
fn entry_base(tok: &str, id: BackendId) -> String {
    match id {
        BackendId::Tricky => tok.trim_end_matches(['?', '!']).to_string(),
        BackendId::Teesim => {
            if tok.starts_with("uid:") {
                String::new()
            } else {
                match tok.rfind('@') {
                    Some(at) if tok[at + 1..].bytes().all(|c| c.is_ascii_digit()) => tok[..at].to_string(),
                    _ => tok.to_string(),
                }
            }
        }
        BackendId::Omk => tok.to_string(),
    }
}

/// cmd_excluded：已装 ∩ ever ∖ 当前目标（按基础包名）；无 KL_DIR / 无 ever 时为空。
pub fn excluded() {
    let root = Root::from_env();
    let p = Paths::new(&root);
    let b = backend::detect(&p);
    let run = |prog: &str, args: &[&str]| -> Option<Vec<u8>> {
        std::process::Command::new(prog).args(args).output().ok().map(|o| o.stdout)
    };
    let out = run("cmd", &["package", "list", "packages", "-3", "--user", "all"])
        .filter(|o| !o.is_empty())
        .or_else(|| run("pm", &["list", "packages", "-3"]))
        .unwrap_or_default();
    let inst: Vec<String> = String::from_utf8_lossy(&out)
        .lines()
        .filter_map(|l| l.strip_prefix("package:").map(|s| s.trim_end_matches('\r').to_string()))
        .filter(|s| !s.is_empty())
        .collect();
    if !b.dir.is_dir() {
        return;
    }
    let tokens: Vec<String> = if b.target.is_file() {
        let data = std::fs::read(&b.target).unwrap_or_default();
        match b.id {
            BackendId::Tricky => tricky_tokens(&String::from_utf8_lossy(&data)),
            BackendId::Teesim => teesim_apps(&data).unwrap_or_default(),
            BackendId::Omk => omk_scoop(&data).unwrap_or_default(),
        }
    } else {
        Vec::new()
    };
    let curbase: std::collections::HashSet<String> = tokens
        .iter()
        .map(|t| entry_base(t, b.id))
        .filter(|s| !s.is_empty())
        .collect();
    let ever: std::collections::HashSet<String> = std::fs::read_to_string(b.dir.join(".kl_ever"))
        .map(|t| t.lines().map(|l| l.trim_end_matches('\r').to_string()).filter(|s| !s.is_empty()).collect())
        .unwrap_or_default();
    let mut res: Vec<String> = inst
        .into_iter()
        .filter(|p| ever.contains(p) && !curbase.contains(p))
        .collect();
    res.sort();
    res.dedup();
    for r in res {
        println!("{}", r);
    }
}

/// boot_hash_valid：长度 64/128 且全是十六进制。
fn boot_hash_valid(s: &str) -> bool {
    matches!(s.len(), 64 | 128) && s.bytes().all(|b| b.is_ascii_hexdigit())
}

/// cmd_boot_hash：configured（去空白→小写）/ current（getprop）/ status。
pub fn boot_hash() {
    let root = Root::from_env();
    let p = Paths::new(&root);
    let raw: String = std::fs::read_to_string(&p.boot_hash)
        .map(|t| t.chars().filter(|c| !c.is_whitespace()).collect::<String>().to_ascii_lowercase())
        .unwrap_or_default();
    let current = std::process::Command::new("getprop")
        .arg("ro.boot.vbmeta.digest")
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default();
    let status = if raw.is_empty() {
        "unset"
    } else if !boot_hash_valid(&raw) {
        "invalid"
    } else if current == raw {
        "ok"
    } else {
        "mismatch"
    };
    println!("configured={}", raw);
    println!("current={}", current);
    println!("status={}", status);
}

/// 期望值表（与 lib/props.sh 的 props_expect_pairs 单点对齐，由对拍守着）。
const PROPS_PAIRS: &[(&str, &str)] = &[
    ("ro.boot.vbmeta.device_state", "locked"),
    ("ro.boot.verifiedbootstate", "green"),
    ("ro.boot.flash.locked", "1"),
    ("ro.boot.veritymode", "enforcing"),
    ("ro.boot.warranty_bit", "0"),
    ("ro.warranty_bit", "0"),
    ("ro.debuggable", "0"),
    ("ro.force.debuggable", "0"),
    ("ro.secure", "1"),
    ("ro.adb.secure", "1"),
    ("ro.build.type", "user"),
    ("ro.build.tags", "release-keys"),
    ("ro.vendor.boot.warranty_bit", "0"),
    ("ro.vendor.warranty_bit", "0"),
    ("vendor.boot.warranty_bit", "0"),
];

const PROPS_RULES: &[(&str, &str, &str)] = &[
    ("ro.bootloader", "engineering", "release"),
    ("ro.build.description", "test-keys", "release-keys"),
];

fn getprop(name: &str) -> String {
    std::process::Command::new("getprop")
        .arg(name)
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim_end_matches('\n').to_string())
        .unwrap_or_default()
}

/// cmd_props：name<TAB>当前<TAB>期望<TAB>状态（先固定表，再特征替换表）。
pub fn props() {
    for (name, expected) in PROPS_PAIRS {
        let cur = getprop(name);
        let st = if cur.is_empty() {
            "missing"
        } else if &cur == expected {
            "ok"
        } else {
            "diff"
        };
        println!("{}\t{}\t{}\t{}", name, cur, expected, st);
    }
    for (name, needle, replacement) in PROPS_RULES {
        let cur = getprop(name);
        let st = if cur.is_empty() {
            "missing"
        } else if cur.contains(needle) {
            "diff"
        } else {
            "ok"
        };
        println!("{}\t{}\t不含 {}（则改写为 {}）\t{}", name, cur, needle, replacement, st);
    }
}

/// tricky_patches.awk 的等价：global + `[包名]` 段，system/vendor/boot/all，
/// 输出「范围<TAB>system<TAB>vendor<TAB>boot」，空值记 "-"；无任何值退出 1。
fn tricky_patches_rows(text: &str) -> Vec<(String, String, String, String)> {
    use std::collections::HashMap;
    let mut order: Vec<String> = Vec::new();
    let mut v_sys: HashMap<String, String> = HashMap::new();
    let mut v_vnd: HashMap<String, String> = HashMap::new();
    let mut v_btm: HashMap<String, String> = HashMap::new();
    let mut cur = "global".to_string();
    let mut flush = |cur: &String, order: &mut Vec<String>, a: &HashMap<String, String>, b: &HashMap<String, String>, c: &HashMap<String, String>| {
        if cur.is_empty() {
            return;
        }
        let s = a.get(cur).map(|v| !v.is_empty()).unwrap_or(false)
            || b.get(cur).map(|v| !v.is_empty()).unwrap_or(false)
            || c.get(cur).map(|v| !v.is_empty()).unwrap_or(false);
        if s {
            order.push(cur.clone());
        }
    };
    for raw in text.split('\n') {
        let mut line = raw.strip_suffix('\r').unwrap_or(raw).to_string();
        if let Some(h) = line.find('#') {
            line.truncate(h);
        }
        let line = line.trim_matches(|c: char| c == ' ' || c == '\t').to_string();
        if line.is_empty() {
            continue;
        }
        if line.len() >= 3 && line.starts_with('[') && line.ends_with(']') && !line[1..line.len() - 1].contains(']') {
            flush(&cur, &mut order, &v_sys, &v_vnd, &v_btm);
            cur = line[1..line.len() - 1].to_string();
            continue;
        }
        let Some(e) = line.find('=') else { continue };
        let k = line[..e].trim_matches(|c: char| c == ' ' || c == '\t').to_string();
        let v = line[e + 1..].trim_matches(|c: char| c == ' ' || c == '\t').to_string();
        match k.as_str() {
            "system" => { v_sys.insert(cur.clone(), v); }
            "vendor" => { v_vnd.insert(cur.clone(), v); }
            "boot" => { v_btm.insert(cur.clone(), v); }
            "all" => {
                v_sys.insert(cur.clone(), v.clone());
                v_vnd.insert(cur.clone(), v.clone());
                v_btm.insert(cur.clone(), v);
            }
            _ => {}
        }
    }
    flush(&cur, &mut order, &v_sys, &v_vnd, &v_btm);
    order
        .into_iter()
        .map(|s| {
            let get = |m: &HashMap<String, String>| m.get(&s).filter(|v| !v.is_empty()).cloned().unwrap_or_else(|| "-".to_string());
            (s.clone(), get(&v_sys), get(&v_vnd), get(&v_btm))
        })
        .collect()
}

const TEESIM_FIELDS: &[&str] = &[
    "attestationSecurityLevel",
    "keymasterSecurityLevel",
    "attestationVersion",
    "keymasterVersion",
    "verifiedBootKey",
    "verifiedBootHash",
];

/// flat(obj, key)：扁平对象里某键的原始值（字符串/数字/true/false/null），没有则 ""。
fn flat(obj: &[u8], key: &str) -> String {
    let needle = format!("\"{}\"", key);
    let Some(p) = find_from(obj, 0, needle.as_bytes()) else { return String::new() };
    let Some(cpos) = find_from(obj, p + needle.len(), b":") else { return String::new() };
    let mut i = cpos + 1;
    while i < obj.len() && matches!(obj[i], b' ' | b'\t' | b'\r' | b'\n') {
        i += 1;
    }
    if i < obj.len() && obj[i] == b'"' {
        let start = i + 1;
        let mut j = start;
        while j < obj.len() && obj[j] != b'"' {
            j += 1;
        }
        return String::from_utf8_lossy(&obj[start..j]).into_owned();
    }
    for lit in [b"false".as_slice(), b"true".as_slice(), b"null".as_slice()] {
        if obj[i..].starts_with(lit) {
            return String::from_utf8_lossy(lit).into_owned();
        }
    }
    let mut s = String::new();
    while i < obj.len() && matches!(obj[i], b'0'..=b'9' | b'.' | b'e' | b'E' | b'+' | b'-') {
        s.push(obj[i] as char);
        i += 1;
    }
    s
}

/// sub_obj(root, field)：root 里 \"field\" 后的 {...} 文本。
fn sub_obj(root: &[u8], field: &str) -> Vec<u8> {
    if root.is_empty() {
        return Vec::new();
    }
    let needle = format!("\"{}\"", field);
    let Some(p) = find_from(root, 0, needle.as_bytes()) else { return Vec::new() };
    let Some(o) = find_from(root, p + needle.len(), b"{") else { return Vec::new() };
    let Some(e) = match_close(root, o) else { return Vec::new() };
    root[o..=e].to_vec()
}

/// obj_string(obj, key)：键后配对 `:`，再取下一个字符串值。
fn obj_string(obj: &[u8], key: &str) -> String {
    let needle = format!("\"{}\"", key);
    let Some(p) = find_from(obj, 0, needle.as_bytes()) else { return String::new() };
    let Some(cpos) = find_from(obj, p + needle.len(), b":") else { return String::new() };
    let mut i = cpos + 1;
    while i < obj.len() {
        let c = obj[i];
        if c == b'"' {
            let start = i + 1;
            let mut j = start;
            let mut esc = false;
            while j < obj.len() {
                if esc {
                    esc = false;
                } else if obj[j] == b'\\' {
                    esc = true;
                } else if obj[j] == b'"' {
                    return String::from_utf8_lossy(&obj[start..j]).into_owned();
                }
                j += 1;
            }
            return String::new();
        }
        if c == b'{' || c == b'[' || c == b'}' {
            return String::new();
        }
        i += 1;
    }
    String::new()
}

/// count_array(obj, key)：`key: [ … ]` 顶层字符串条目数；顶层遇对象/数组即停。
fn count_array(obj: &[u8], key: &str) -> usize {
    let needle = format!("\"{}\"", key);
    let Some(p) = find_from(obj, 0, needle.as_bytes()) else { return 0 };
    let Some(cpos) = find_from(obj, p + needle.len(), b":") else { return 0 };
    let mut i = cpos + 1;
    while i < obj.len() && matches!(obj[i], b' ' | b'\t' | b'\r' | b'\n') {
        i += 1;
    }
    if i >= obj.len() || obj[i] != b'[' {
        return 0;
    }
    let Some(cl) = match_close(obj, i) else { return 0 };
    let body = &obj[i + 1..cl];
    let mut n = 0usize;
    let mut instr = false;
    let mut esc = false;
    for &c in body {
        if instr {
            if esc {
                esc = false;
            } else if c == b'\\' {
                esc = true;
            } else if c == b'"' {
                instr = false;
                n += 1;
            }
            continue;
        }
        if c == b'"' {
            instr = true;
            continue;
        }
        if c == b'{' || c == b'[' {
            return n;
        }
    }
    n
}

/// cmd_teesim_profiles：profiles 的（名字 / keybox / mode / apps 数 / 是否默认）。
pub fn teesim_profiles() {
    let root = Root::from_env();
    let p = Paths::new(&root);
    let b = backend::detect(&p);
    if b.id != BackendId::Teesim {
        eprintln!("当前后端不是 TEE Simulator");
        std::process::exit(1);
    }
    if !p.teesim_config.is_file() {
        eprintln!("配置不存在：{}", p.teesim_config.display());
        std::process::exit(1);
    }
    let s = std::fs::read(&p.teesim_config).unwrap_or_default();
    let Some(pp) = find_from(&s, 0, b"\"profiles\"") else { std::process::exit(1) };
    let Some(colon) = find_from(&s, pp + 10, b":") else { std::process::exit(1) };
    let mut i = colon + 1;
    while i < s.len() && matches!(s[i], b' ' | b'\t' | b'\r' | b'\n') {
        i += 1;
    }
    if i >= s.len() || s[i] != b'{' {
        std::process::exit(1);
    }
    let Some(pend) = match_close(&s, i) else { std::process::exit(1) };
    let obj = &s[i..=pend];
    // profiles 对象的一层：深 1 处 `"名字" : { … }`
    let mut entries: Vec<(String, Vec<u8>)> = Vec::new();
    let mut j = 1usize;
    let mut depth = 0i32;
    let mut instr = false;
    let mut esc = false;
    while j < obj.len() {
        let c = obj[j];
        if instr {
            if esc {
                esc = false;
            } else if c == b'\\' {
                esc = true;
            } else if c == b'"' {
                instr = false;
            }
            j += 1;
            continue;
        }
        if c == b'"' {
            // 读键（含转义），随后要求 `:` 与 `{`
            let start = j + 1;
            let mut k = start;
            while k < obj.len() && obj[k] != b'"' {
                k += 1;
            }
            let name = String::from_utf8_lossy(&obj[start..k]).into_owned();
            let mut m = k + 1;
            while m < obj.len() && matches!(obj[m], b' ' | b'\t' | b'\r' | b'\n') {
                m += 1;
            }
            if m < obj.len() && obj[m] == b':' {
                m += 1;
                while m < obj.len() && matches!(obj[m], b' ' | b'\t' | b'\r' | b'\n') {
                    m += 1;
                }
                if m < obj.len() && obj[m] == b'{' {
                    if let Some(e) = match_close(obj, m) {
                        entries.push((name, obj[m..=e].to_vec()));
                        j = e + 1;
                        continue;
                    }
                }
            }
            j = k + 1;
            continue;
        }
        if c == b'{' || c == b'[' {
            depth += 1;
        } else if c == b'}' || c == b']' {
            depth -= 1;
        }
        j += 1;
    }
    if entries.is_empty() {
        std::process::exit(1);
    }
    let emit = |name: &str, sub: &[u8]| {
        let kb = obj_string(sub, "keybox");
        let mode = obj_string(sub, "mode");
        let apps = count_array(sub, "apps");
        println!(
            "{}\t{}\t{}\t{}\t{}",
            name,
            if kb.is_empty() { "-" } else { &kb },
            if mode.is_empty() { "patch" } else { &mode },
            apps,
            if name == "default" { 1 } else { 0 }
        );
    };
    let mut def_done = false;
    for (name, sub) in &entries {
        if name == "default" {
            emit(name, sub);
            def_done = true;
        }
    }
    let _ = def_done;
    for (name, sub) in &entries {
        if name != "default" {
            emit(name, sub);
        }
    }
}

/// cmd_teesim_overrides：overrides.json + harvested.json → 字段/值/可编辑/来源。
pub fn teesim_overrides() {
    let root = Root::from_env();
    let p = Paths::new(&root);
    let b = backend::detect(&p);
    if b.id != BackendId::Teesim {
        eprintln!("当前后端不是 TEE Simulator");
        std::process::exit(1);
    }
    let ov = std::fs::read(p.teesim_dir.join("overrides.json")).unwrap_or_default();
    let ha = std::fs::read(p.teesim_dir.join("harvested.json")).unwrap_or_default();
    if ov.is_empty() && ha.is_empty() {
        std::process::exit(1);
    }
    let hobj = sub_obj(&ha, "overrides");
    for f in TEESIM_FIELDS {
        let v = flat(&ov, f);
        let sobj = sub_obj(&hobj, f);
        let mut ed = "1";
        let mut src = "unset".to_string();
        if !sobj.is_empty() {
            let s2 = flat(&sobj, "source");
            if !s2.is_empty() {
                src = s2;
            }
            let e2 = flat(&sobj, "editable");
            if e2 == "false" {
                ed = "0";
            } else if e2 == "true" {
                ed = "1";
            } else if src == "required" {
                ed = "1";
            }
        }
        if (*f == "verifiedBootKey" || *f == "verifiedBootHash") && src != "synthesized" && src != "supplement" {
            ed = "0";
        }
        println!("{}\t{}\t{}\t{}", f, if v.is_empty() { "-".to_string() } else { v }, ed, src);
    }
}

/// cmd_tricky_patches：只读解析 security_patch.txt。
pub fn tricky_patches() {
    let root = Root::from_env();
    let p = Paths::new(&root);
    let b = backend::detect(&p);
    if b.id != BackendId::Tricky {
        eprintln!("当前后端不是 Tricky Store");
        std::process::exit(1);
    }
    let f = p.tstore_dir.join("security_patch.txt");
    if !f.is_file() {
        eprintln!("文件不存在：{}", f.display());
        std::process::exit(1);
    }
    let rows = tricky_patches_rows(&std::fs::read_to_string(&f).unwrap_or_default());
    if rows.is_empty() {
        std::process::exit(1);
    }
    for (s, a, b2, c) in rows {
        println!("{}\t{}\t{}\t{}", s, a, b2, c);
    }
}

const CONFLICT_MSG: &str =
    "检测到多个密钥库后端同时启用（Tricky Store / TEE Simulator / OhMyKeymint），模块停止运行（请只保留一个）";

/// 后端互斥：同时启用多于一家。
fn backends_conflict(p: &Paths) -> bool {
    [&p.teesim_module, &p.tricky_module, &p.omk_module]
        .iter()
        .filter(|m| backend::active(m))
        .count()
        > 1
}

/// log_info：向运行日志追加一条带时间戳的记录（无日志文件时创建）。
fn log_line(p: &Paths, msg: &str) {
    let ts = std::process::Command::new("date")
        .arg("+%m-%d %H:%M:%S")
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim_end_matches('\n').to_string())
        .unwrap_or_default();
    let line = format!("{}{}\n", if ts.is_empty() { String::new() } else { format!("{} ", ts) }, msg);
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&p.log) {
        let _ = f.write_all(line.as_bytes());
    }
}

/// is_pkg_token：包名语法（与 applist.sh 同义）。
fn is_pkg_token(p: &str) -> bool {
    !p.is_empty()
        && !p.starts_with('.')
        && !p.ends_with('.')
        && !p.contains("..")
        && p.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'.')
        && p.contains('.')
}

/// tricky_mode.awk 的等价：只改匹配行（保留缩进/行尾空白/注释），返回 (新内容, 状态)。
fn tricky_mode_rewrite(text: &str, pkg: &str, mode: &str) -> (String, &'static str) {
    let suffix = match mode {
        "leaf" => "?",
        "generate" => "!",
        _ => "",
    };
    let mut matched = false;
    let mut changed = false;
    let mut out = String::new();
    for raw in text.split('\n') {
        let line = raw.strip_suffix('\r').unwrap_or(raw);
        let h = line.find('#');
        let body = match h {
            Some(i) => &line[..i],
            None => line,
        };
        if body.trim_matches(|c: char| c == ' ' || c == '\t').is_empty() {
            out.push_str(line);
            out.push('\n');
            continue;
        }
        let indent_len = body.len() - body.trim_start_matches([' ', '\t']).len();
        let indent = &body[..indent_len];
        let rest = &body[indent_len..];
        let tok_len = rest.trim_end_matches([' ', '\t']).len();
        let mut tok = rest[..tok_len].to_string();
        let tail = &rest[tok_len..];
        let mut b = tok.clone();
        if b.ends_with('?') || b.ends_with('!') {
            b.pop();
            b = b.trim_end_matches([' ', '\t']).to_string();
        }
        if b == pkg {
            matched = true;
            let newtok = format!("{}{}", pkg, suffix);
            if newtok != tok {
                changed = true;
            }
            tok = newtok;
        }
        out.push_str(indent);
        out.push_str(&tok);
        out.push_str(tail);
        if let Some(i) = h {
            out.push_str(&line[i..]);
        }
        out.push('\n');
    }
    // 与 awk 的 print 一致：最后一行有换行时 split 会多出空串，去掉它带来的多余行
    if text.ends_with('\n') {
        out.pop();
    }
    let status = if !matched {
        "none"
    } else if changed {
        "ok"
    } else {
        "same"
    };
    (out, status)
}

fn resetprop(args: &[&str]) -> String {
    std::process::Command::new("resetprop")
        .args(args)
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim_end_matches('\n').to_string())
        .unwrap_or_default()
}

/// cmd_props_boot_hash：保存/清除 verifiedBootHash 并立即应用（resetprop -n）。
pub fn props_boot_hash(arg: &str) {
    let root = Root::from_env();
    let p = Paths::new(&root);
    if backends_conflict(&p) {
        eprintln!("{}", CONFLICT_MSG);
        std::process::exit(1);
    }
    if arg.is_empty() || arg == "-" {
        let _ = std::fs::remove_file(&p.boot_hash);
        if p.boot_hash.exists() {
            eprintln!("清除失败：{}", p.boot_hash.display());
            std::process::exit(1);
        }
        log_line(&p, "🧹 WebUI 清除 Verified Boot 哈希（下次开机不再写 digest；本次运行回原值需重启）");
        let cur = resetprop(&["ro.boot.vbmeta.digest"]);
        println!("saved=0");
        println!("applied=0");
        println!("current={}", cur);
        return;
    }
    let v: String = arg.chars().filter(|c| !c.is_whitespace()).collect::<String>().to_ascii_lowercase();
    if !boot_hash_valid(&v) {
        eprintln!("哈希必须是 64 或 128 位十六进制");
        std::process::exit(1);
    }
    let tmp = format!("{}.tmp.{}", p.boot_hash.display(), std::process::id());
    let wrote = std::fs::write(&tmp, format!("{}\n", v)).is_ok();
    if wrote {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600));
        }
    }
    let ok = wrote && std::fs::rename(&tmp, &p.boot_hash).is_ok() && p.boot_hash.is_file();
    if !ok {
        let _ = std::fs::remove_file(&tmp);
        eprintln!("写入失败：{}", p.boot_hash.display());
        std::process::exit(1);
    }
    // apply_boot_hash：写 digest（不同才写）、hash_alg 为空时按长度补，最后读回比对
    let mut applied = 0;
    let cur = resetprop(&["ro.boot.vbmeta.digest"]);
    if cur != v {
        let _ = resetprop(&["-n", "ro.boot.vbmeta.digest", &v]);
    }
    let alg = resetprop(&["ro.boot.vbmeta.hash_alg"]);
    if alg.is_empty() {
        let want = if v.len() == 128 { "sha512" } else { "sha256" };
        let _ = resetprop(&["-n", "ro.boot.vbmeta.hash_alg", want]);
    }
    let now = resetprop(&["ro.boot.vbmeta.digest"]);
    if now == v {
        applied = 1;
    }
    if applied == 1 {
        log_line(&p, &format!("🧩 WebUI 设置 Verified Boot 哈希（{} 位）并已应用", v.len()));
    } else {
        log_line(&p, "⚠️ WebUI 保存 Verified Boot 哈希，但写入后读回不一致");
        println!("apply_note=已保存到配置，但立即应用失败（写入后读回不一致）；下次开机仍会再写一次");
    }
    println!("saved=1");
    println!("applied={}", applied);
    println!("current={}", now);
}

/// cmd_props_apply：按期望表写一次（缺/不符才写），复核后输出 applied / mismatch。
pub fn props_apply() {
    let root = Root::from_env();
    let p = Paths::new(&root);
    if backends_conflict(&p) {
        eprintln!("{}", CONFLICT_MSG);
        std::process::exit(1);
    }
    if std::process::Command::new("resetprop").arg("--version").output().is_err() {
        eprintln!("未找到 resetprop 命令");
        std::process::exit(1);
    }
    if p.props_off.is_file() {
        eprintln!("属性伪装已关闭，请先在界面上重新开启");
        std::process::exit(1);
    }
    // apply_resetprop：缺或不同才写；特征值整体替换
    for (name, expected) in PROPS_PAIRS {
        let cur = resetprop(&[name]);
        if cur.is_empty() || cur != *expected {
            let _ = resetprop(&["-n", name, expected]);
        }
    }
    for (name, needle, replacement) in PROPS_RULES {
        let cur = resetprop(&[name]);
        if !cur.is_empty() && cur.contains(needle) {
            let _ = resetprop(&["-n", name, replacement]);
        }
    }
    apply_boot_hash_quiet(&p);
    log_line(&p, "🛠 WebUI 触发一次属性伪装（运行期写入；已被应用读取的静态字段不会刷新）");

    // 复核：重新读一遍（Rust 侧没有进程内属性快照，直接读即最新）
    let mut rows: Vec<(String, String)> = Vec::new();
    for (name, expected) in PROPS_PAIRS {
        let cur = resetprop(&[name]);
        let st = if cur.is_empty() {
            "missing"
        } else if &cur == expected {
            "ok"
        } else {
            "diff"
        };
        rows.push((name.to_string(), st.to_string()));
    }
    for (name, needle, _replacement) in PROPS_RULES {
        let cur = resetprop(&[name]);
        let st = if cur.is_empty() {
            "missing"
        } else if cur.contains(needle) {
            "diff"
        } else {
            "ok"
        };
        rows.push((name.to_string(), st.to_string()));
    }
    let want = PROPS_PAIRS.len();
    let got = rows.len();
    if got < want {
        eprintln!("写入后复核失败（重读退码 0，读到 {}/{} 行），不能报已生效", got, want);
        println!("applied=0");
        println!("mismatch=-1");
        std::process::exit(1);
    }
    let bad = rows.iter().filter(|(_, st)| st == "diff" || st == "missing").count();
    println!("applied=1");
    println!("mismatch={}", bad);
}

/// apply_boot_hash 的非致命版本（失败只在调用方提示）。
fn apply_boot_hash_quiet(p: &Paths) {
    let Ok(text) = std::fs::read_to_string(&p.boot_hash) else { return };
    let h: String = text.chars().filter(|c| !c.is_whitespace()).collect::<String>().to_ascii_lowercase();
    if h.is_empty() || !boot_hash_valid(&h) {
        return;
    }
    let cur = resetprop(&["ro.boot.vbmeta.digest"]);
    if cur != h {
        let _ = resetprop(&["-n", "ro.boot.vbmeta.digest", &h]);
    }
    let alg = resetprop(&["ro.boot.vbmeta.hash_alg"]);
    if alg.is_empty() {
        let want = if h.len() == 128 { "sha512" } else { "sha256" };
        let _ = resetprop(&["-n", "ro.boot.vbmeta.hash_alg", want]);
    }
}

/// cmd_props_switch：props-on / props-off（开关文件即关闭标记）。
pub fn props_switch(want: &str) {
    let root = Root::from_env();
    let p = Paths::new(&root);
    if want != "on" && want != "off" {
        eprintln!("参数只能是 on 或 off");
        std::process::exit(1);
    }
    let ok = if want == "off" {
        let created = std::fs::OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .open(&p.props_off)
            .is_ok();
        if created {
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let _ = std::fs::set_permissions(&p.props_off, std::fs::Permissions::from_mode(0o600));
            }
        }
        created && p.props_off.is_file()
    } else {
        let _ = std::fs::remove_file(&p.props_off);
        !p.props_off.exists()
    };
    if !ok {
        eprintln!("开关文件写入失败：{}", p.props_off.display());
        std::process::exit(1);
    }
    log_line(
        &p,
        if want == "off" {
            "🛠 WebUI 关闭属性伪装（下次开机起不再写入期望值）"
        } else {
            "🛠 WebUI 开启属性伪装（下次开机起恢复写入）"
        },
    );
    println!("props_masking={}", want);
}

/// tricky_patch_set.awk 的 drop 分支：删掉 `[scope]` 段（含段前注释与空行）。
fn tricky_drop_rewrite(text: &str, scope: &str) -> (String, &'static str) {
    let lines: Vec<&str> = {
        let mut v: Vec<&str> = text.split('\n').collect();
        if text.ends_with('\n') {
            v.pop();
        }
        v
    };
    let n = lines.len();
    let is_blank = |s: &str| s.chars().all(|c| c == ' ' || c == '\t');
    let is_comment = |s: &str| s.trim_start_matches([' ', '\t']).starts_with('#');
    let mut secl: Vec<usize> = Vec::new();
    let mut secn: Vec<String> = Vec::new();
    for (i, line) in lines.iter().enumerate() {
        let t = line.trim_matches([' ', '\t']);
        if t.starts_with('[') && t.ends_with(']') && t.len() >= 3 {
            let name = &t[1..t.len() - 1];
            if !name.is_empty()
                && name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'.' || b == b'-')
            {
                secl.push(i + 1);
                secn.push(name.to_string());
            }
        }
    }
    let Some(idx) = secn.iter().position(|s| s == scope) else {
        return (text.to_string(), "missing");
    };
    let lo = secl[idx];
    let mut hi = if idx + 1 < secl.len() { secl[idx + 1] } else { n + 1 };
    while hi >= lo + 1 && hi - 1 >= lo && (is_blank(lines[hi - 2]) || is_comment(lines[hi - 2])) {
        hi -= 1;
    }
    let mut lo2 = lo;
    while lo2 >= 2 && is_comment(lines[lo2 - 2]) {
        lo2 -= 1;
    }
    if lo2 >= 2 && is_blank(lines[lo2 - 2]) {
        lo2 -= 1;
    }
    let mut out = String::new();
    for (i, line) in lines.iter().enumerate() {
        let one = i + 1;
        if one >= lo2 && one < hi {
            continue;
        }
        out.push_str(line);
        out.push('\n');
    }
    (out, "ok")
}

/// cmd_tricky_drop_patch：删掉 security_patch.txt 里的 [scope] 段。
pub fn tricky_drop_patch(scope: &str) {
    let root = Root::from_env();
    let p = Paths::new(&root);
    if backends_conflict(&p) {
        eprintln!("{}", CONFLICT_MSG);
        std::process::exit(1);
    }
    let b = backend::detect(&p);
    if b.id != BackendId::Tricky {
        eprintln!("当前后端不是 Tricky Store");
        std::process::exit(1);
    }
    if scope.is_empty() || scope == "global" {
        eprintln!("只能删按包段（[包名]）；全局段是补丁表的主体，不能删");
        std::process::exit(1);
    }
    if !valid_pkg(scope) {
        eprintln!("scope 必须是合法包名：{}", scope);
        std::process::exit(1);
    }
    let target = p.tstore_dir.join("security_patch.txt");
    if !target.is_file() {
        eprintln!("补丁表不存在：{}", target.display());
        std::process::exit(1);
    }
    let marks: Vec<String> = vec![std::env::var("KL_LOCK_MARK").unwrap_or_else(|_| {
        p.module_prop.parent().and_then(|m| m.file_name()).map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| "keylens".to_string())
    })];
    let lockdir = b.dir.join(".kl_lock");
    if !crate::lock::acquire(&lockdir, 6, &marks) {
        eprintln!("守护进程正在写入，请几秒后再试");
        std::process::exit(1);
    }
    let old = std::fs::read_to_string(&target).unwrap_or_default();
    let (new_text, status) = tricky_drop_rewrite(&old, scope);
    let rc = match status {
        "missing" => {
            crate::lock::release(&lockdir);
            eprintln!("补丁表里没有 [{}] 这一段", scope);
            std::process::exit(1);
        }
        "ok" => {
            if new_text == old {
                0
            } else {
                let bak = b.dir.join("security_patch.txt.bak");
                let _ = std::fs::copy(&target, &bak);
                let tmp = b.dir.join(format!(".kl_restore.{}", std::process::id()));
                let ok = std::fs::write(&tmp, new_text.as_bytes()).is_ok();
                let ok = ok && std::fs::rename(&tmp, &target).is_ok();
                if !ok {
                    let _ = std::fs::remove_file(&tmp);
                    2
                } else {
                    0
                }
            }
        }
        _ => 2,
    };
    crate::lock::release(&lockdir);
    if rc != 0 {
        eprintln!("补丁表删除失败");
        std::process::exit(1);
    }
    log_line(&p, &format!("🧩 WebUI 删除 Tricky 补丁段（scope={}）", scope));
    println!("dropped=1");
    println!("scope={}", scope);
}

/// valid_tricky_patch：与 webui.sh 同义（折小写后判定）。
pub fn valid_tricky_patch(v: &str) -> bool {
    let s = v.to_ascii_lowercase();
    if matches!(s.as_str(), "no" | "device_default" | "prop") {
        return true;
    }
    if matches!(s.as_str(), "yyyy" | "mm" | "dd") {
        return false;
    }
    let digits = |x: &str| !x.is_empty() && x.bytes().all(|b| b.is_ascii_digit());
    if (s.len() == 6 || s.len() == 8) && digits(&s) {
        return true;
    }
    let p: Vec<&str> = s.split('-').collect();
    let year_ok = |y: &str| y == "yyyy" || (y.len() == 4 && digits(y));
    let month_ok = |m: &str| m == "mm" || (m.len() == 2 && digits(m) && matches!(m.parse::<u32>(), Ok(1..=12)));
    let day_ok = |d: &str| {
        d == "dd" || (d.len() == 2 && digits(d) && d.as_bytes()[0].is_ascii_digit() && d.as_bytes()[0] <= b'3')
    };
    match p.len() {
        2 => year_ok(p[0]) && month_ok(p[1]),
        3 => year_ok(p[0]) && month_ok(p[1]) && day_ok(p[2]),
        _ => false,
    }
}

/// tricky_patch_set.awk 的写入分支：改已有键、缺键插到段末、裸值转 `all =`、新段建在文件尾。
fn tricky_patch_set_rewrite(text: &str, scope: &str, pairs: &[(String, String)]) -> (String, &'static str) {
    let mut lines: Vec<String> = {
        let mut v: Vec<String> = text.split('\n').map(|s| s.trim_end_matches('\r').to_string()).collect();
        if text.ends_with('\n') {
            v.pop();
        }
        v
    };
    let nl = lines.len();
    let is_blank = |s: &str| s.chars().all(|c| c == ' ' || c == '\t');
    let mut secl: Vec<usize> = Vec::new();
    let mut secn: Vec<String> = Vec::new();
    for (i, line) in lines.iter().enumerate() {
        let t = line.trim_matches([' ', '\t']);
        if t.starts_with('[') && t.ends_with(']') && t.len() >= 3 {
            let name = &t[1..t.len() - 1];
            if !name.is_empty() && name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'.' || b == b'-') {
                secl.push(i + 1);
                secn.push(name.to_string());
            }
        }
    }
    let want = if scope.is_empty() { "global" } else { scope };
    let (lo, hi, newblk): (usize, usize, Option<String>) = if want == "global" {
        (1, if secl.is_empty() { nl + 1 } else { secl[0] }, None)
    } else if let Some(idx) = secn.iter().position(|s| s == want) {
        (secl[idx] + 1, if idx + 1 < secl.len() { secl[idx + 1] } else { nl + 1 }, None)
    } else {
        (nl + 1, nl + 1, Some(want.to_string()))
    };
    // 段内：键行与裸值行
    let mut keyline: std::collections::HashMap<String, usize> = std::collections::HashMap::new();
    let mut bare: Option<usize> = None;
    let mut i = lo;
    while i < hi {
        let line = &lines[i - 1];
        let body = match line.find('#') { Some(h) => &line[..h], None => line.as_str() };
        let b = body.trim_matches([' ', '\t']).to_string();
        if !b.is_empty() && !b.starts_with('[') {
            match b.find('=') {
                Some(e) => {
                    let k = b[..e].trim_matches([' ', '\t']).to_string();
                    if matches!(k.as_str(), "system" | "vendor" | "boot" | "all") {
                        keyline.insert(k, i);
                    }
                }
                None => bare = Some(i),
            }
        }
        i += 1;
    }
    // 裸值 + 要混写键：先转成 `all = 旧值`，保住其它分量的语义
    if let (Some(bi), true) = (bare, !pairs.is_empty()) {
        let line = lines[bi - 1].clone();
        let (body, tail) = match line.find('#') {
            Some(h) => (line[..h].to_string(), line[h..].to_string()),
            None => (line.clone(), String::new()),
        };
        let old = body.trim_matches([' ', '\t']);
        lines[bi - 1] = format!("all = {}{}", old, if tail.is_empty() { String::new() } else { format!(" {}", tail) });
        keyline.insert("all".to_string(), bi);
    }
    let mut changed = false;
    let mut miss: Vec<&(String, String)> = Vec::new();
    for pair in pairs {
        let k = match pair.0.as_str() {
            "patch_system" => "system",
            "patch_vendor" => "vendor",
            "patch_boot" => "boot",
            "patch_all" => "all",
            _ => continue,
        };
        if let Some(&li) = keyline.get(k) {
            let line = lines[li - 1].clone();
            let (body, tail) = match line.find('#') {
                Some(h) => (line[..h].to_string(), line[h..].to_string()),
                None => (line.clone(), String::new()),
            };
            let ind: String = body.chars().take_while(|c| *c == ' ' || *c == '\t').collect();
            let want_line = format!("{} = {}", k, pair.1);
            if body.trim_matches([' ', '\t']) != want_line {
                lines[li - 1] = format!(
                    "{}{}{}",
                    ind,
                    want_line,
                    if tail.is_empty() { String::new() } else { format!(" {}", tail) }
                );
                changed = true;
            }
        } else {
            miss.push(pair);
        }
    }
    let mut ins = String::new();
    for pair in &miss {
        let k = match pair.0.as_str() {
            "patch_system" => "system",
            "patch_vendor" => "vendor",
            "patch_boot" => "boot",
            "patch_all" => "all",
            _ => continue,
        };
        ins.push_str(&format!("{} = {}\n", k, pair.1));
        changed = true;
    }
    if let Some(nb) = &newblk {
        if !ins.is_empty() {
            ins = format!("[{}]\n{}", nb, ins);
        }
    }
    if ins.is_empty() && !changed && nl > 0 {
        return (text.to_string(), "same");
    }
    let mut out = String::new();
    for (idx, line) in lines.iter().enumerate() {
        if idx + 1 == hi && !ins.is_empty() {
            out.push_str(&ins);
        }
        out.push_str(line);
        out.push('\n');
    }
    if hi == nl + 1 && !ins.is_empty() {
        out.push_str(&ins);
    }
    (out, "ok")
}

/// cmd_tricky_save_patch：改 security_patch.txt 的全局段或 [scope] 段。
pub fn tricky_save_patch(payload: &str) {
    let root = Root::from_env();
    let p = Paths::new(&root);
    if backends_conflict(&p) {
        eprintln!("{}", CONFLICT_MSG);
        std::process::exit(1);
    }
    let b = backend::detect(&p);
    if b.id != BackendId::Tricky {
        eprintln!("当前后端不是 Tricky Store");
        std::process::exit(1);
    }
    let mut fields = match crate::payload::parse(payload) {
        Ok(v) => v,
        Err(msg) => {
            eprintln!("{}", msg);
            std::process::exit(1);
        }
    };
    let mut scope = "global".to_string();
    if let Some(pos) = fields.iter().position(|(k, _)| k == "scope") {
        let (_, v) = fields.remove(pos);
        if !v.is_empty() {
            scope = v;
        }
    }
    if scope != "global" && !valid_pkg(&scope) {
        eprintln!("scope 必须是 global 或一个合法包名：{}", scope);
        std::process::exit(1);
    }
    if fields.is_empty() {
        eprintln!("没有可写字段");
        std::process::exit(1);
    }
    for (k, v) in &fields {
        match k.as_str() {
            "patch_system" | "patch_vendor" | "patch_boot" | "patch_all" => {
                if !valid_tricky_patch(v) {
                    eprintln!(
                        "补丁值不合法：{} = {}（接受 YYYY-MM-DD / YYYYMMDD / YYYYMM / no / device_default / prop / YYYY、MM、DD 占位）",
                        k, v
                    );
                    std::process::exit(1);
                }
            }
            other => {
                eprintln!("未知字段：{}", other);
                std::process::exit(1);
            }
        }
    }
    let target = p.tstore_dir.join("security_patch.txt");
    if !target.is_file() {
        let _ = std::fs::create_dir_all(&p.tstore_dir);
        if std::fs::File::create(&target).is_err() {
            eprintln!("补丁表不存在且无法创建：{}", target.display());
            std::process::exit(1);
        }
    }
    let marks: Vec<String> = vec![std::env::var("KL_LOCK_MARK").unwrap_or_else(|_| {
        p.module_prop.parent().and_then(|m| m.file_name()).map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| "keylens".to_string())
    })];
    let lockdir = b.dir.join(".kl_lock");
    if !crate::lock::acquire(&lockdir, 6, &marks) {
        eprintln!("守护进程正在写入，请几秒后再试");
        std::process::exit(1);
    }
    let old = std::fs::read_to_string(&target).unwrap_or_default();
    let (new_text, status) = tricky_patch_set_rewrite(&old, &scope, &fields);
    let n = fields.len();
    let mut saved = 0;
    match status {
        "ok" => {
            if new_text == old {
                // 内容没变：不写、不备份（与 shell 的 cmp -s 分支一致）
            } else {
                let bak = b.dir.join("security_patch.txt.bak");
                let _ = std::fs::copy(&target, &bak);
                let tmp = b.dir.join(format!(".kl_save.{}", std::process::id()));
                let ok = std::fs::write(&tmp, new_text.as_bytes()).is_ok()
                    && std::fs::rename(&tmp, &target).is_ok();
                if !ok {
                    let _ = std::fs::remove_file(&tmp);
                    crate::lock::release(&lockdir);
                    eprintln!("写入失败：{}", target.display());
                    std::process::exit(1);
                }
                saved = 1;
            }
        }
        "same" => {}
        _ => {
            crate::lock::release(&lockdir);
            eprintln!("补丁表写入失败");
            std::process::exit(1);
        }
    }
    crate::lock::release(&lockdir);
    if saved == 1 {
        log_line(&p, &format!("🧩 WebUI 更新 Tricky 补丁表（scope={}，{} 项）", scope, n));
    }
    println!("saved={}", saved);
    println!("fields={}", n);
    println!("scope={}", scope);
}

/// cmd_set_mode：Tricky 条目模式改写（auto/leaf/generate），输出 changed。
pub fn set_mode(pkg: &str, mode: &str) {
    let root = Root::from_env();
    let p = Paths::new(&root);
    if backends_conflict(&p) {
        eprintln!("{}", CONFLICT_MSG);
        std::process::exit(1);
    }
    let b = backend::detect(&p);
    if b.id != BackendId::Tricky {
        eprintln!("只有 Tricky Store 后端支持条目模式");
        std::process::exit(1);
    }
    if !is_pkg_token(pkg) {
        eprintln!("不是合法的包名：{}", pkg);
        std::process::exit(1);
    }
    if !matches!(mode, "auto" | "leaf" | "generate") {
        eprintln!("模式只能是 auto / leaf / generate");
        std::process::exit(1);
    }
    if !b.target.is_file() {
        eprintln!("写入失败：{}", b.target.display());
        std::process::exit(1);
    }
    let marks: Vec<String> = {
        let mut v = vec![std::env::var("KL_LOCK_MARK").unwrap_or_else(|_| {
            p.module_prop.parent().and_then(|m| m.file_name()).map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| "keylens".to_string())
        })];
        if let Ok(extra) = std::env::var("KL_OUR_MARKS") {
            v.extend(extra.split_whitespace().map(|s| s.to_string()));
        }
        v
    };
    let lockdir = b.dir.join(".kl_lock");
    if !crate::lock::acquire(&lockdir, 6, &marks) {
        eprintln!("守护进程正在写入，请几秒后再试");
        std::process::exit(1);
    }
    let text = std::fs::read_to_string(&b.target).unwrap_or_default();
    let (new_text, status) = tricky_mode_rewrite(&text, pkg, mode);
    let rc = match status {
        "ok" => {
            let tmp = b.dir.join(format!(".kl_mode.{}", std::process::id()));
            let ok = std::fs::write(&tmp, new_text.as_bytes()).is_ok()
                && std::fs::rename(&tmp, &b.target).is_ok();
            if !ok {
                let _ = std::fs::remove_file(&tmp);
                2
            } else {
                0
            }
        }
        _ => 1,
    };
    crate::lock::release(&lockdir);
    match rc {
        0 => {
            log_line(&p, &format!("🧩 WebUI 把 {} 的模式改为 {}", pkg, mode));
            println!("changed=1");
        }
        1 => println!("changed=0"),
        _ => {
            eprintln!("写入失败：{}", b.target.display());
            std::process::exit(1);
        }
    }
}

/// cmd_omk_restart：触发 OMK 重载（restart.<范围>），输出 restarted / trigger。
pub fn omk_restart(which: &str) {
    let root = Root::from_env();
    let p = Paths::new(&root);
    if backends_conflict(&p) {
        eprintln!("{}", CONFLICT_MSG);
        std::process::exit(1);
    }
    let b = backend::detect(&p);
    if b.id != BackendId::Omk {
        eprintln!("当前后端不是 OhMyKeymint");
        std::process::exit(1);
    }
    if !matches!(which, "keymint" | "injector" | "all") {
        eprintln!("只能触发 keymint / injector / all（收到：{}）", which);
        std::process::exit(1);
    }
    if !p.omk_state_dir.is_dir() {
        eprintln!("目录不存在：{}（OMK 没装？）", p.omk_state_dir.display());
        std::process::exit(1);
    }
    let f = p.omk_state_dir.join(format!("restart.{}", which));
    match std::fs::File::create(&f) {
        Ok(_) => {}
        Err(_) => {
            eprintln!("写入失败：{}", f.display());
            std::process::exit(1);
        }
    }
    log_line(&p, &format!("🛠 WebUI 触发 OhMyKeymint 重载：{}", which));
    println!("restarted={}", which);
    println!("trigger={}", f.display());
}

/// cmd_clear_log：删日志缓冲与 .tmp，再写一条「已清空」记录，输出 cleared=1。
pub fn clear_log() {
    let root = Root::from_env();
    let p = Paths::new(&root);
    let _ = std::fs::remove_file(&p.log);
    let _ = std::fs::remove_file(format!("{}.tmp", p.log.display()));
    let ts = std::process::Command::new("date")
        .arg("+%m-%d %H:%M:%S")
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim_end_matches('\n').to_string())
        .unwrap_or_default();
    let line = format!("{} 🧹 WebUI 已清空运行日志缓冲\n", if ts.is_empty() { String::new() } else { format!("{} ", ts) });
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&p.log) {
        let _ = f.write_all(line.as_bytes());
    }
    println!("cleared=1");
}

/// cmd_tee_status：读 Tricky 自己写的 tee_status（present/file + 四个已知键）。
pub fn tee_status() {
    let root = Root::from_env();
    let p = Paths::new(&root);
    let f = p.tstore_dir.join("tee_status");
    if !f.is_file() {
        println!("present=0");
        return;
    }
    println!("present=1");
    println!("file={}", f.display());
    let text = std::fs::read_to_string(&f).unwrap_or_default();
    for line in text.split('\n') {
        let line = line.trim_end_matches('\r');
        if line.is_empty() {
            continue;
        }
        let Some(eq) = line.find('=') else { continue };
        let (k, rest) = (&line[..eq], &line[eq + 1..]);
        let key = match k {
            "status" => "status",
            "category" => "category",
            "serviceErrorCode" => "service_error_code",
            "teeBroken" => "tee_broken",
            _ => continue,
        };
        println!("{}={}", key, rest);
    }
}

/// cmd_target_meta：tok<TAB>base<TAB>kind<TAB>detail（三家的语义在 cmd 里分叉）。
pub fn target_meta() {
    let root = Root::from_env();
    let p = Paths::new(&root);
    let b = backend::detect(&p);
    if !b.target.is_file() {
        eprintln!("目标文件不存在：{}", b.target.display());
        std::process::exit(1);
    }
    let data = std::fs::read(&b.target).unwrap_or_default();
    let tokens: Vec<String> = match b.id {
        BackendId::Tricky => tricky_tokens(&String::from_utf8_lossy(&data)),
        BackendId::Teesim => teesim_apps(&data).unwrap_or_default(),
        BackendId::Omk => omk_scoop(&data).unwrap_or_default(),
    };
    for tok in tokens {
        let (base, kind, detail): (String, &str, String) = match b.id {
            BackendId::Tricky => {
                if let Some(stripped) = tok.strip_suffix('?') {
                    (stripped.to_string(), "leaf", String::new())
                } else if let Some(stripped) = tok.strip_suffix('!') {
                    (stripped.to_string(), "generate", String::new())
                } else {
                    (tok.clone(), "auto", String::new())
                }
            }
            BackendId::Teesim => {
                if let Some(rest) = tok.strip_prefix("uid:") {
                    (String::new(), "uid", rest.to_string())
                } else if let Some(at) = tok.rfind('@') {
                    let detail = &tok[at + 1..];
                    if !detail.is_empty() && detail.bytes().all(|c| c.is_ascii_digit()) {
                        (tok[..at].to_string(), "user", detail.to_string())
                    } else {
                        (tok.clone(), "plain", String::new())
                    }
                } else {
                    (tok.clone(), "plain", String::new())
                }
            }
            BackendId::Omk => (tok.clone(), "plain", String::new()),
        };
        println!("{}\t{}\t{}\t{}", tok, base, kind, detail);
    }
}
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

/// overrides 的六行汇总（可编辑性/来源），供展示与写入前的可编辑性判定共用。
pub fn teesim_overrides_rows(p: &Paths) -> Vec<(String, String, String, String)> {
    let ov = std::fs::read(p.teesim_dir.join("overrides.json")).unwrap_or_default();
    let ha = std::fs::read(p.teesim_dir.join("harvested.json")).unwrap_or_default();
    if ov.is_empty() && ha.is_empty() {
        return Vec::new();
    }
    let hobj = sub_obj(&ha, "overrides");
    let mut rows = Vec::new();
    for f in TEESIM_FIELDS {
        let v = flat(&ov, f);
        let sobj = sub_obj(&hobj, f);
        let mut ed = "1".to_string();
        let mut src = "unset".to_string();
        if !sobj.is_empty() {
            let s2 = flat(&sobj, "source");
            if !s2.is_empty() { src = s2; }
            let e2 = flat(&sobj, "editable");
            if e2 == "false" { ed = "0".to_string(); } else if e2 == "true" { ed = "1".to_string(); } else if src == "required" { ed = "1".to_string(); }
        }
        if (*f == "verifiedBootKey" || *f == "verifiedBootHash") && src != "synthesized" && src != "supplement" {
            ed = "0".to_string();
        }
        rows.push((f.to_string(), if v.is_empty() { "-".to_string() } else { v }, ed, src));
    }
    rows
}

/// cmd_teesim_save_overrides：写 overrides.json 的六个字段（空值=删键）。
pub fn teesim_save_overrides(payload: &str) {
    let root = Root::from_env();
    let p = Paths::new(&root);
    if backends_conflict(&p) {
        eprintln!("{}", CONFLICT_MSG);
        std::process::exit(1);
    }
    let b = backend::detect(&p);
    if b.id != BackendId::Teesim {
        eprintln!("当前后端不是 TEE Simulator");
        std::process::exit(1);
    }
    let fields = match crate::payload::parse(payload) {
        Ok(v) => v,
        Err(msg) => { eprintln!("{}", msg); std::process::exit(1); }
    };
    let ov = p.teesim_dir.join("overrides.json");
    let ha = p.teesim_dir.join("harvested.json");
    for (k, v) in &fields {
        let bad = match k.as_str() {
            "attestationSecurityLevel" | "keymasterSecurityLevel" => {
                if !crate::ov_valid::valid_ov_level(v) {
                    eprintln!("{} 只能是 0(Software) / 1(TrustedEnvironment) / 2(StrongBox)，留空表示删掉这一项；收到的是「{}」", k, v);
                    true
                } else { false }
            }
            "attestationVersion" | "keymasterVersion" => {
                if !crate::ov_valid::valid_ov_version(v) {
                    eprintln!("{} 只能是 1–100000 的整数，留空表示删掉这一项；收到的是「{}」", k, v);
                    true
                } else { false }
            }
            "verifiedBootKey" | "verifiedBootHash" => {
                if !crate::ov_valid::valid_ov_hex(v) {
                    eprintln!("{} 要 64 位十六进制（可带 0x 前缀）、不许全零，留空表示删掉这一项；收到的是「{}」", k, v);
                    true
                } else if !v.is_empty() && ha.is_file() {
                    let ed = teesim_overrides_rows(&p).into_iter()
                        .find(|(name, _, _, _)| name == k)
                        .map(|(_, _, ed, _)| ed)
                        .unwrap_or_default();
                    if !ed.is_empty() && ed != "1" {
                        eprintln!("{} 现在不可改：harvested.json 判它的来源不是合成兜底值（上游规则，不是本模块的限制）", k);
                        true
                    } else { false }
                } else { false }
            }
            _ => {
                eprintln!("overrides.json 里这个字段被上游锁死为 REQUIRED，写进去守护进程会直接丢弃：{}", k);
                true
            }
        };
        if bad { std::process::exit(1); }
    }
    let n = fields.len();
    if n == 0 {
        eprintln!("没有字段要保存");
        std::process::exit(1);
    }
    let src = if ov.is_file() {
        std::fs::read_to_string(&ov).unwrap_or_default()
    } else {
        "{}\n".to_string()
    };
    let marks: Vec<String> = vec![std::env::var("KL_LOCK_MARK").unwrap_or_else(|_| {
        p.module_prop.parent().and_then(|m| m.file_name()).map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| "keylens".to_string())
    })];
    let lockdir = b.dir.join(".kl_lock");
    if !crate::lock::acquire(&lockdir, 6, &marks) {
        eprintln!("守护进程正在写入，请几秒后再试");
        std::process::exit(1);
    }
    let (new_text, status) = crate::json_flat::set(&src, &fields);
    let mut saved = 0;
    match status {
        "ok" => {
            if new_text != src {
                let bak = b.dir.join("overrides.json.bak");
                let _ = std::fs::copy(&ov, &bak);
                let tmp = b.dir.join(format!(".overrides.json.keylens.{}", std::process::id()));
                let ok = std::fs::write(&tmp, new_text.as_bytes()).is_ok()
                    && std::fs::rename(&tmp, &ov).is_ok();
                if !ok {
                    let _ = std::fs::remove_file(&tmp);
                    crate::lock::release(&lockdir);
                    eprintln!("写入失败：{}", ov.display());
                    std::process::exit(1);
                }
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    let _ = std::fs::set_permissions(&ov, std::fs::Permissions::from_mode(0o644));
                }
                saved = 1;
            }
        }
        "same" => {}
        _ => {
            crate::lock::release(&lockdir);
            eprintln!("overrides.json 定位失败（不是可写的扁平对象？）：{}", ov.display());
            std::process::exit(1);
        }
    }
    crate::lock::release(&lockdir);
    if saved == 1 {
        log_line(&p, &format!("🧩 WebUI 更新 TEESim overrides.json（{} 项，热生效无需重启）", n));
    }
    println!("saved={}", saved);
    println!("fields={}", n);
    println!("apply_note={}", if saved == 1 { "已写入，TEESim 监听该文件自行热生效，不需要重启" } else { "内容与现有一致，未写入" });
}

/// 当前后端的 keybox 路径（teesim 以 config 里的 default.keybox 为准）。
fn keybox_path_for(p: &Paths, id: BackendId) -> std::path::PathBuf {
    match id {
        BackendId::Tricky => p.tstore_dir.join("keybox.xml"),
        BackendId::Omk => p.omk_dir.join("keybox.xml"),
        BackendId::Teesim => {
            let cfg = std::fs::read(&p.teesim_config).unwrap_or_default();
            let mut name = String::new();
            if let Some(pp) = find_from(&cfg, 0, b"\"profiles\"") {
                if let Some(colon) = find_from(&cfg, pp + 10, b":") {
                    let mut i = colon + 1;
                    while i < cfg.len() && matches!(cfg[i], b' ' | b'\t' | b'\r' | b'\n') { i += 1; }
                    if i < cfg.len() && cfg[i] == b'{' {
                        if let Some(pend) = match_close(&cfg, i) {
                            let obj = &cfg[i..=pend];
                            if let Some(d) = find_from(obj, 0, b"\"default\"") {
                                let mut m = d + 9;
                                while m < obj.len() && matches!(obj[m], b' ' | b'\t' | b'\r' | b'\n') { m += 1; }
                                if m < obj.len() && obj[m] == b':' {
                                    m += 1;
                                    while m < obj.len() && matches!(obj[m], b' ' | b'\t' | b'\r' | b'\n') { m += 1; }
                                    if m < obj.len() && obj[m] == b'{' {
                                        if let Some(e) = match_close(obj, m) {
                                            name = obj_string(&obj[m..=e], "keybox");
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if name.is_empty() { name = "keybox.xml".to_string(); }
            if name.starts_with('/') { std::path::PathBuf::from(name) } else { p.teesim_dir.join(name) }
        }
    }
}

/// cmd_keybox_save：base64 XML → 结构校验 → 备份 → 落盘（600）。
pub fn keybox_save(payload: &str) {
    let root = Root::from_env();
    let p = Paths::new(&root);
    if backends_conflict(&p) {
        eprintln!("{}", CONFLICT_MSG);
        std::process::exit(1);
    }
    let b = backend::detect(&p);
    if payload.is_empty() {
        eprintln!("keybox 内容为空");
        std::process::exit(1);
    }
    if payload.len() > 180000 {
        eprintln!("keybox 过大（上限约 128KB）");
        std::process::exit(1);
    }
    let data = match crate::b64::decode(payload) {
        Some(v) => v,
        None => { eprintln!("keybox 解码失败"); std::process::exit(1); }
    };
    let bytes = data.len();
    if !(64..=131072).contains(&bytes) {
        eprintln!("keybox 大小不合法");
        std::process::exit(1);
    }
    let bname = match b.id { BackendId::Teesim => "TEE Simulator", BackendId::Omk => "OhMyKeymint", BackendId::Tricky => "Tricky Store" };
    if let Err(msg) = crate::keybox::check(&data, b.id.as_str()) {
        eprintln!("keybox 结构不合格（{}）：{}", bname, msg);
        std::process::exit(1);
    }
    let target = keybox_path_for(&p, b.id);
    let marks: Vec<String> = vec![std::env::var("KL_LOCK_MARK").unwrap_or_else(|_| {
        p.module_prop.parent().and_then(|m| m.file_name()).map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| "keylens".to_string())
    })];
    let lockdir = b.dir.join(".kl_lock");
    if !crate::lock::acquire(&lockdir, 6, &marks) {
        eprintln!("守护进程正在写入，请几秒后再试");
        std::process::exit(1);
    }
    let bak = b.dir.join("keybox.xml.bak");
    if target.is_file() { let _ = std::fs::copy(&target, &bak); }
    let tmp = b.dir.join(format!(".keybox.{}", std::process::id()));
    let ok = std::fs::write(&tmp, &data).is_ok() && std::fs::rename(&tmp, &target).is_ok();
    if ok {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o600));
        }
    } else {
        let _ = std::fs::remove_file(&tmp);
    }
    crate::lock::release(&lockdir);
    if !ok {
        eprintln!("写入失败：{}", target.display());
        std::process::exit(1);
    }
    log_line(&p, &format!("🔑 WebUI 替换 keybox：{}（{} 字节）", target.display(), bytes));
    let sha = std::process::Command::new("sha256sum").arg(&target).output().ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).split_whitespace().next().unwrap_or("").to_string())
        .unwrap_or_default();
    println!("saved=1");
    println!("keybox_file={}", target.display());
    println!("keybox_bytes={}", bytes);
    println!("keybox_sha={}", sha);
}

/// cmd_backup_restore：把 KL_DIR/<name> 还原回它对应的后端文件（保留属主与权限）。
pub fn backup_restore(name: &str) {
    let root = Root::from_env();
    let p = Paths::new(&root);
    if backends_conflict(&p) {
        eprintln!("{}", CONFLICT_MSG);
        std::process::exit(1);
    }
    let b = backend::detect(&p);
    if name.is_empty() || name.contains('/') || name.contains("..") {
        eprintln!("备份名不合法：{}", name);
        std::process::exit(1);
    }
    let src = b.dir.join(name);
    let Some(tgt) = backup_target(&b, &p, name) else {
        eprintln!("当前后端没有这个备份：{}", name);
        std::process::exit(1);
    };
    let Ok(md) = std::fs::metadata(&src) else { eprintln!("备份不存在或为空：{}", src.display()); std::process::exit(1) };
    if md.len() == 0 {
        eprintln!("备份不存在或为空：{}", src.display());
        std::process::exit(1);
    }
    if name == "keybox.xml.bak" {
        let data = std::fs::read(&src).unwrap_or_default();
        if let Err(msg) = crate::keybox::check(&data, b.id.as_str()) {
            eprintln!("这份 keybox 备份结构不合格：{}", msg);
            std::process::exit(1);
        }
    }
    let marks: Vec<String> = vec![std::env::var("KL_LOCK_MARK").unwrap_or_else(|_| {
        p.module_prop.parent().and_then(|m| m.file_name()).map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| "keylens".to_string())
    })];
    let lockdir = b.dir.join(".kl_lock");
    if !crate::lock::acquire(&lockdir, 6, &marks) {
        eprintln!("守护进程正在写入，请几秒后再试");
        std::process::exit(1);
    }
    // 记下目标文件原有的属主/权限，写完还原
    let mut own = String::new();
    let mut mode = None;
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        if let Ok(m) = std::fs::metadata(&tgt) {
            own = format!("{}:{}", m.uid(), m.gid());
            mode = Some(m.permissions().mode() & 0o7777);
        }
    }
    let pre = b.dir.join(format!("{}.pre-restore", name));
    if tgt.is_file() {
        let _ = std::fs::copy(&tgt, &pre);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&pre, std::fs::Permissions::from_mode(0o600));
        }
    }
    let tmp = b.dir.join(format!(".kl_restore.bak.{}", std::process::id()));
    let copied = std::fs::copy(&src, &tmp).is_ok();
    let moved = copied && std::fs::rename(&tmp, &tgt).is_ok();
    if moved {
        if !own.is_empty() {
            let _ = std::process::Command::new("chown").arg(&own).arg(&tgt).output();
        }
        #[cfg(unix)]
        if let Some(m) = mode {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&tgt, std::fs::Permissions::from_mode(m));
        }
    } else {
        let _ = std::fs::remove_file(&tmp);
    }
    crate::lock::release(&lockdir);
    if !moved {
        eprintln!("回滚失败：{} 没被改动", tgt.display());
        std::process::exit(1);
    }
    let base = tgt.file_name().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    log_line(&p, &format!("♻️ WebUI 用备份还原了 {}（来源 {}）", base, name));
    println!("restored=1");
    println!("name={}", name);
}

/// 从对象里删掉一个成员（含逗号与行内残留空白），返回新文本。
fn delete_member(b: &[u8], ob: usize, oc: usize, hit: &crate::json_flat::Hit) -> Vec<u8> {
    let mut rs = hit.kbs;
    let mut re = hit.ke;
    let hws = |c: u8| matches!(c, b' ' | b'\t' | b'\r');
    let ws = |c: u8| matches!(c, b' ' | b'\t' | b'\r' | b'\n');
    let mut p = re + 1;
    while p <= oc && p < b.len() && hws(b[p]) { p += 1; }
    if p < b.len() && b[p] == b',' {
        re = p;
    } else {
        let mut q = rs.saturating_sub(1);
        while q > ob && ws(b[q]) { q -= 1; }
        if b[q] == b',' { rs = q; }
    }
    let mut a = rs.saturating_sub(1);
    while a > ob && hws(b[a]) { a -= 1; }
    let mut bb = re + 1;
    while bb < b.len() && hws(b[bb]) { bb += 1; }
    if b[a] == b'\n' && bb < b.len() && b[bb] == b'\n' { rs = a + 1; re = bb; }
    else if b[a] == b'\n' { rs = a + 1; }
    let mut out = Vec::with_capacity(b.len());
    out.extend_from_slice(&b[..rs]);
    out.extend_from_slice(&b[re + 1..]);
    out
}

/// cmd_teesim_profile_del：删掉 config.json 里 profiles.<name>。
pub fn teesim_profile_del(name: &str) {
    let root = Root::from_env();
    let p = Paths::new(&root);
    if backends_conflict(&p) {
        eprintln!("{}", CONFLICT_MSG);
        std::process::exit(1);
    }
    let b = backend::detect(&p);
    if b.id != BackendId::Teesim {
        eprintln!("当前后端不是 TEE Simulator");
        std::process::exit(1);
    }
    if !p.teesim_config.is_file() {
        eprintln!("配置不存在：{}", p.teesim_config.display());
        std::process::exit(1);
    }
    if name.is_empty() || name == "default" {
        eprintln!("default 是兜底 profile，不能删");
        std::process::exit(1);
    }
    if name.is_empty() || !name.bytes().all(|c| c.is_ascii_alphanumeric() || matches!(c, b'.' | b'_' | b'-')) {
        eprintln!("名字只能用字母、数字、. _ -：{}", name);
        std::process::exit(1);
    }
    let marks: Vec<String> = vec![std::env::var("KL_LOCK_MARK").unwrap_or_else(|_| {
        p.module_prop.parent().and_then(|m| m.file_name()).map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| "keylens".to_string())
    })];
    let lockdir = b.dir.join(".kl_lock");
    if !crate::lock::acquire(&lockdir, 6, &marks) {
        eprintln!("守护进程正在写入，请几秒后再试");
        std::process::exit(1);
    }
    let old = std::fs::read(&p.teesim_config).unwrap_or_default();
    // 定位 profiles 对象
    let found = (|| {
        let pp = find_from(&old, 0, b"\"profiles\"")?;
        let colon = find_from(&old, pp + 10, b":")?;
        let mut i = colon + 1;
        while i < old.len() && matches!(old[i], b' ' | b'\t' | b'\r' | b'\n') { i += 1; }
        if old.get(i) != Some(&b'{') { return None; }
        let end = match_close(&old, i)?;
        Some((i, end))
    })();
    let Some((ob, oc)) = found else {
        crate::lock::release(&lockdir);
        eprintln!("删除 profile 失败");
        std::process::exit(1);
    };
    let Some(hit) = member_span(&old, ob, oc, name) else {
        crate::lock::release(&lockdir);
        eprintln!("没有这个 profile：{}", name);
        std::process::exit(1);
    };
    let new_bytes = delete_member(&old, ob, oc, &hit);
    let bak = b.dir.join("config.json.bak");
    let _ = std::fs::copy(&p.teesim_config, &bak);
    let mode = std::fs::metadata(&p.teesim_config).ok().map(|m| m.permissions());
    let tmp = b.dir.join(format!(".config.json.keylens.{}", std::process::id()));
    let ok = std::fs::write(&tmp, &new_bytes).is_ok() && std::fs::rename(&tmp, &p.teesim_config).is_ok();
    if !ok {
        let _ = std::fs::remove_file(&tmp);
        crate::lock::release(&lockdir);
        eprintln!("写入失败：{}", p.teesim_config.display());
        std::process::exit(1);
    }
    if let Some(m) = mode {
        let _ = std::fs::set_permissions(&p.teesim_config, m);
    }
    crate::lock::release(&lockdir);
    log_line(&p, &format!("🧰 WebUI 删除 TEESim profile（{}）", name));
    println!("removed=1");
    println!("profile={}", name);
}

/// 在对象里找深度 1 的成员（值可能是嵌套对象/数组，用配对跳过）。
fn member_span(b: &[u8], ob: usize, oc: usize, key: &str) -> Option<crate::json_flat::Hit> {
    let mut depth = 0i32;
    let mut i = ob;
    while i <= oc && i < b.len() {
        let c = b[i];
        if c == b'"' {
            let q_end = {
                let mut j = i + 1;
                let mut esc = false;
                while j <= oc && j < b.len() {
                    if esc { esc = false; } else if b[j] == b'\\' { esc = true; } else if b[j] == b'"' { break; }
                    j += 1;
                }
                j + 1
            };
            if depth != 1 { i = q_end; continue; }
            let name = String::from_utf8_lossy(&b[i + 1..q_end.saturating_sub(1)]).into_owned();
            let mut p = q_end;
            while p <= oc && p < b.len() && matches!(b[p], b' ' | b'\t' | b'\r' | b'\n') { p += 1; }
            if p > oc || b.get(p) != Some(&b':') { i = q_end; continue; }
            let hit = name == key;
            p += 1;
            while p <= oc && p < b.len() && matches!(b[p], b' ' | b'\t' | b'\r' | b'\n') { p += 1; }
            let ke;
            if p < b.len() && (b[p] == b'{' || b[p] == b'[') {
                ke = match_close(b, p).unwrap_or(p);
            } else if p < b.len() && b[p] == b'"' {
                let mut j = p + 1;
                let mut esc = false;
                while j <= oc && j < b.len() {
                    if esc { esc = false; } else if b[j] == b'\\' { esc = true; } else if b[j] == b'"' { break; }
                    j += 1;
                }
                ke = j;
            } else {
                let mut e = p;
                while e <= oc && e < b.len() && !matches!(b[e], b',' | b'}' | b'\n') { e += 1; }
                while e > p && matches!(b[e - 1], b' ' | b'\t' | b'\r') { e -= 1; }
                ke = e.saturating_sub(1);
            }
            if hit {
                return Some(crate::json_flat::Hit { ks: p, ke, kbs: i });
            }
            i = ke + 1;
            continue;
        }
        if c == b'{' || c == b'[' { depth += 1; }
        else if c == b'}' || c == b']' { depth -= 1; }
        i += 1;
    }
    None
}
