//! 读命令与写命令实现。

/// 与 shell 版一致：输出被下游关掉（EPIPE / Broken pipe）不算错误。
/// Rust 默认忽略 SIGPIPE，println! 会 panic；统一走这个宏，写失败就放弃。
macro_rules! println_ok {
    ($($arg:tt)*) => {{
        use std::io::Write as _;
        let _ = writeln!(std::io::stdout(), $($arg)*);
    }};
}

/// stderr 版本（上游关掉 stderr 也一样不该崩）。
macro_rules! eprintln_ok {
    ($($arg:tt)*) => {{
        use std::io::Write as _;
        let _ = writeln!(std::io::stderr(), $($arg)*);
    }};
}

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
        println_ok!("{}\t{}\t{}\t{}", name, md.len(), mt, tgt.display());
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
    let kv = |k: &str, v: &str| println_ok!("{}={}", k, v);
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

/// 一次 `cmd package list packages …` → 包名列表（去前缀、去 `[N]` 尾缀、排序去重）。
/// 与 shell 侧 kl_pkg_names 同一条式子：先 `cmd`，空/失败退回 `pm`。
fn pkg_names(extra: &[&str]) -> Vec<String> {
    let spawn = |prog: &str, args: &[&str]| -> Option<Vec<u8>> {
        std::process::Command::new(prog).args(args).output().ok().map(|o| o.stdout)
    };
    let mut cmd_args: Vec<&str> = vec!["package", "list", "packages"];
    cmd_args.extend_from_slice(extra);
    cmd_args.extend_from_slice(&["--user", "all"]);
    let mut pm_args: Vec<&str> = vec!["list", "packages"];
    pm_args.extend_from_slice(extra);

    let out = spawn("cmd", &cmd_args)
        .filter(|o| !o.is_empty())
        .or_else(|| spawn("pm", &pm_args))
        .unwrap_or_default();
    let text = String::from_utf8_lossy(&out);
    let mut names: Vec<String> = Vec::new();
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
            names.push(name.to_string());
        }
    }
    names.sort_unstable();
    names.dedup();
    names
}

/// 有启动器入口的包（MAIN/LAUNCHER）—— 这是平台自己的"这是个应用"判据，
/// 不是我按包名猜的：本机 235 个系统包里只有 17 个有入口，其余是覆盖层/服务/资源包。
/// 这条查询不能带 `--user all`（这台机带上就打空，实测 0 行），与 shell 侧同形。
fn launchable_names() -> Vec<String> {
    let spawn = |prog: &str| -> Option<Vec<u8>> {
        std::process::Command::new(prog)
            .args(["query-activities", "--components",
                   "-a", "android.intent.action.MAIN",
                   "-c", "android.intent.category.LAUNCHER"])
            .output().ok().map(|o| o.stdout)
    };
    let out = spawn("cmd").filter(|o| !o.is_empty())
        .or_else(|| spawn("pm")).unwrap_or_default();
    let mut v: Vec<String> = Vec::new();
    for line in String::from_utf8_lossy(&out).lines() {
        let l = line.trim_end_matches('\r');
        // 只处理 `包名/组件` 这种行（表头那些行没有斜杠）
        if !l.contains('/') { continue; }
        let pkg = l.split('/').next().unwrap_or("").trim();
        if !pkg.is_empty() { v.push(pkg.to_string()); }
    }
    v.sort();
    v.dedup();
    v
}

/// cmd_apps：已装应用。参数：空 = 只第三方（`-3`，同步口径）；system = 系统包；all = 全部；
/// launchable = 有启动器入口的包。
/// 系统包只能"全量减第三方"（这台机的 `cmd package` 不认 `--system`），那是两次 pm 调用，
/// 只在界面点开「系统应用」那一档时才付。语义与 shell 侧 cmd_apps 逐字节一致。
pub fn apps(arg: &str) {
    let names = match arg.trim() {
        "all" => pkg_names(&[]),
        "launchable" => launchable_names(),
        "system" => {
            let third: std::collections::HashSet<String> = pkg_names(&["-3"]).into_iter().collect();
            pkg_names(&[]).into_iter().filter(|n| !third.contains(n)).collect()
        }
        _ => pkg_names(&["-3"]),
    };
    for n in names {
        println_ok!("{}", n);
    }
}

/// 参考清单（包名与分类抄自 Tricky-Addon-Update-Target-List 的 more-exclude.json，
/// Apache-2.0，出处见 THIRD_PARTY_NOTICES.md）：这些应用不会去检测 bootloader，
/// 放进目标名单只是多一张要伪造的证书链。**只给建议、不动文件** —— 移出走的还是 remove-apps。
/// 顺序与 shell 侧 `kl_exclude_table` 逐字同序（对拍按行比）。
const EXCLUDE_HINTS: &[(&str, &str)] = &[
    ("com.topjohnwu.magisk", "root-manager"),
    ("io.github.vvb2060.magisk", "root-manager"),
    ("io.github.huskydg.magisk", "root-manager"),
    ("me.weishu.kernelsu", "root-manager"),
    ("com.rifsxd.ksunext", "root-manager"),
    ("com.sukisu.ultra", "root-manager"),
    ("me.bmax.apatch", "root-manager"),
    ("me.garfieldhan.apatch.next", "root-manager"),
    ("org.lsposed.manager", "root-related"),
    ("com.termux", "root-related"),
    ("bin.mt.plus", "root-related"),
    ("bin.mt.plus.canary", "root-related"),
    ("xzr.konabess", "root-related"),
    ("io.github.a13e300.ksuwebui", "root-related"),
    ("moe.shizuku.privileged.api", "root-related"),
    ("com.dergoogler.mmrl", "root-related"),
    ("com.dergoogler.mmrl.wx", "root-related"),
    ("org.swiftapps.swiftbackup", "general"),
    ("com.google.android.apps.docs.editors.docs", "general"),
    ("com.google.android.apps.docs.editors.sheets", "general"),
    ("com.google.android.apps.docs.editors.slides", "general"),
    ("com.google.android.keep", "general"),
    ("com.google.android.apps.maps", "general"),
    ("com.google.earth", "general"),
    ("com.google.android.apps.translate", "general"),
    ("com.android.chrome", "general"),
    ("com.google.android.youtube", "general"),
    ("com.google.android.apps.youtube.music", "general"),
    ("org.zwanoo.android.speedtest", "general"),
];

/// cmd_exclude_suggest：参考清单 ∩ 已装（**全量**，含系统应用 —— Chrome / Translate
/// 在不少机器上是预装的，按 `-3` 取就漏了）。每行「包名<TAB>类别」。
/// 不输出"在不在名单里"：界面手里就有那份目标文件，两边各算一次迟早分叉。
pub fn exclude_suggest() {
    let installed: std::collections::HashSet<String> = pkg_names(&[]).into_iter().collect();
    for (pkg, cat) in EXCLUDE_HINTS {
        if installed.contains(*pkg) {
            println_ok!("{}\t{}", pkg, cat);
        }
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
    // 「已排除」的宇宙是**全部已装**（不是 -3）：系统应用也能进名单之后，移出的一定要
    // 在这档里找得回来。与 lib/applist.sh 的 excluded_apps 同口径。
    let out = run("cmd", &["package", "list", "packages", "--user", "all"])
        .filter(|o| !o.is_empty())
        .or_else(|| run("pm", &["list", "packages"]))
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
        println_ok!("{}", r);
    }
}

/// boot_hash_valid：长度 64/128 且全是十六进制。
fn boot_hash_valid(s: &str) -> bool {
    matches!(s.len(), 64 | 128) && s.bytes().all(|b| b.is_ascii_hexdigit())
}

/// boot_hash 文件里的原始内容（去空白→小写）。文件不在就是空串。
fn boot_hash_raw(p: &Paths) -> String {
    std::fs::read_to_string(&p.boot_hash)
        .map(|t| t.chars().filter(|c| !c.is_whitespace()).collect::<String>().to_ascii_lowercase())
        .unwrap_or_default()
}

/// 三态：文件不在=auto，合法 hex=manual，"off"=off，别的=invalid。
/// 与 lib/props.sh 的 boot_hash_mode 同语义。
fn boot_hash_mode(p: &Paths) -> &'static str {
    let raw = boot_hash_raw(p);
    if raw.is_empty() {
        "auto"
    } else if boot_hash_valid(&raw) {
        "manual"
    } else if raw == "off" {
        "off"
    } else {
        "invalid"
    }
}

/// 取 TOML 里某个键的值（与 lib/props.sh 那条 sed 同形：行首允许空白、引号可有可无、
/// 取到下一个引号为止）。注释行以 # 开头 ⇒ 天然不匹配。
fn toml_line_value(text: &str, key: &str) -> String {
    for line in text.lines() {
        let t = line.trim_start();
        let Some(rest) = t.strip_prefix(key) else { continue };
        let Some(rest) = rest.trim_start().strip_prefix('=') else { continue };
        let rest = rest.trim_start();
        let rest = rest.strip_prefix('"').unwrap_or(rest);
        return rest.split('"').next().unwrap_or("").trim().to_string();
    }
    String::new()
}

/// 取 JSON 里某个字符串键的值（`"key":"value"`；null 不带引号 ⇒ 取不到，正是要的行为）。
fn json_string_value(text: &str, key: &str) -> String {
    let pat = format!("\"{key}\"");
    let Some(at) = text.rfind(&pat) else { return String::new() };
    let rest = &text[at + pat.len()..];
    let Some(colon) = rest.find(':') else { return String::new() };
    let after = rest[colon + 1..].trim_start();
    let Some(after) = after.strip_prefix('"') else { return String::new() };
    after.split('"').next().unwrap_or("").trim().to_string()
}

/// auto 档的取值：只问**当前启用的那一家后端**自己的配置。
/// 返回 (来源, 值)；值不合法（random / null / 缺文件 / 缺字段）时返回 ("none", "")——
/// 过期值比空着更糟（检测器的 mismatch 与 missing 同为 Danger），所以这里宁可不写。
/// 绝不缓存：每次调用都重读文件。
fn boot_hash_source(p: &Paths) -> (String, String) {
    let mut v = String::new();
    if backend::active(&p.teesim_module) {
        // 与 OMK 不同：TEESim 守护进程每次 push 都把这条 prop 强制成它自己正在证明的值
        // （App.kt:516-523「the value we attest wins unconditionally」），而 overrides.json
        // 里那串 hex 只在它当前那份是合成兜底值时才被采纳（Harvester.kt:183-189、
        // applyUserOverrides 对非 editable 字段直接 continue：399-415）。已有合法值就采用它，
        // 拿 override 去覆盖正好会在上游不采纳时造出"证明与 prop 不符"那一格 Danger。
        let live: String = getprop("ro.boot.vbmeta.digest")
            .chars()
            .filter(|c| !c.is_whitespace())
            .collect::<String>()
            .to_ascii_lowercase();
        if boot_hash_valid(&live) {
            return ("daemon".into(), live);
        }
        let text = std::fs::read_to_string(p.teesim_dir.join("overrides.json")).unwrap_or_default();
        v = json_string_value(&text, "verifiedBootHash");
        if v.is_empty() || !boot_hash_valid(&v) {
            return ("none".into(), String::new());
        }
        return ("teesim".into(), v.to_ascii_lowercase());
    }
    if backend::active(&p.omk_module) {
        let text = std::fs::read_to_string(p.omk_dir.join("config.toml")).unwrap_or_default();
        v = toml_line_value(&text, "vb_hash");
        if v.is_empty() || !boot_hash_valid(&v) {
            return ("none".into(), String::new());
        }
        return ("omk".into(), v.to_ascii_lowercase());
    }
    ("none".into(), String::new())
}

/// 生效值：手动优先；auto 才派生；off / invalid 一个字节都不写。
/// 与 lib/props.sh 的 boot_hash_get 同语义。
fn boot_hash_effective(p: &Paths) -> String {
    match boot_hash_mode(p) {
        "manual" => boot_hash_raw(p),
        "auto" => boot_hash_source(p).1,
        _ => String::new(),
    }
}

/// 体检「启动哈希」那一行。必须按三态取生效值：auto 档配置文件是不存在的，
/// 直接读文件会把「自动档一切正常」报成跳过、把「已设为不写」报成不合格（真机红过一次）。
/// 返回 (状态, 说明, 下一步)。
fn boot_hash_doctor_row(mode: &str, eff: &str, cur: &str) -> (&'static str, String, String) {
    let cur = cur.to_ascii_lowercase();
    if mode == "off" {
        return ("skip", "已设为不写 vbmeta digest".into(), String::new());
    }
    if mode == "invalid" {
        return ("skip", "配置值不是十六进制，这一项没生效".into(),
                "在「属性伪装」页重填，或改回自动".into());
    }
    if eff.is_empty() {
        return ("skip", "自动档但后端没给出值".into(), String::new());
    }
    if cur == eff {
        return if mode == "manual" {
            ("ok", "当前值等于配置值".into(), String::new())
        } else {
            ("ok", "自动取到的值与当前值一致".into(), String::new())
        };
    }
    let next = "点「保存并应用」重写一次；重启后仍不一致说明这台设备的值变了".to_string();
    if mode == "manual" {
        ("warn", "当前值与配置值不一致".into(), next)
    } else {
        ("warn", "自动取到的值与当前值不一致".into(), next)
    }
}

#[cfg(test)]
mod bh_row_tests {
    use super::*;
    const H: &str = "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef";

    #[test]
    fn auto_with_backend_value_is_ok_not_skip() {
        // 真机红过的那一格：auto 档没有配置文件，但生效值取得到 ⇒ 必须是 ok
        let (st, msg, _) = boot_hash_doctor_row("auto", H, H);
        assert_eq!((st, msg.as_str()), ("ok", "自动取到的值与当前值一致"));
    }

    #[test]
    fn off_is_skip_not_bad() {
        let (st, msg, next) = boot_hash_doctor_row("off", "", H);
        assert_eq!((st, msg.as_str(), next.as_str()),
                   ("skip", "已设为不写 vbmeta digest", ""));
    }

    #[test]
    fn manual_matches_and_mismatches() {
        assert_eq!(boot_hash_doctor_row("manual", H, H).0, "ok");
        let (st, msg, next) = boot_hash_doctor_row("manual", H, "aaa");
        assert_eq!((st, msg.as_str()), ("warn", "当前值与配置值不一致"));
        assert!(next.contains("保存并应用"));
    }

    #[test]
    fn auto_without_value_and_invalid_file() {
        let (st, msg, next) = boot_hash_doctor_row("auto", "", H);
        assert_eq!((st, msg.as_str(), next.as_str()), ("skip", "自动档但后端没给出值", ""));
        let (st, msg, next) = boot_hash_doctor_row("invalid", "", H);
        assert_eq!((st, msg.as_str()), ("skip", "配置值不是十六进制，这一项没生效"));
        assert!(next.contains("重填"));
    }

    #[test]
    fn current_is_case_insensitive_and_auto_warns() {
        assert_eq!(boot_hash_doctor_row("manual", H, &H.to_ascii_uppercase()).0, "ok");
        assert_eq!(boot_hash_doctor_row("auto", H, "bbb").0, "warn");
    }
}

/// cmd_boot_hash：mode / configured / source / effective / current / status。
pub fn boot_hash() {
    let root = Root::from_env();
    let p = Paths::new(&root);
    let raw = boot_hash_raw(&p);
    let mode = boot_hash_mode(&p).to_string();
    let (src, _) = boot_hash_source(&p);
    let eff = boot_hash_effective(&p);
    let current = getprop("ro.boot.vbmeta.digest");
    let status = match mode.as_str() {
        "off" => "off",
        "invalid" => "invalid",
        _ if eff.is_empty() => "unset",
        _ if current == eff => "ok",
        _ => "mismatch",
    };
    println_ok!("mode={}", mode);
    println_ok!("configured={}", raw);
    println_ok!("source={}", src);
    println_ok!("effective={}", eff);
    println_ok!("current={}", current);
    println_ok!("status={}", status);
}

/// 期望值表（与 lib/props.sh 的 props_expect_pairs 单点对齐，由对拍守着）。
/// 固定表：缺失也要**凭空补出来**（`missing` 状态），所以往里加键之前要先想清楚
/// "这台机本来没有它"是不是也在说实话。
/// **查证后不往里加的镜像族**（2026-11-03，读了 Duck Detector 的源码，也看了它在自己机器上
/// 打出的那张卡）：`vendor.boot.vbmeta.device_state` / `vendor.boot.verifiedbootstate` /
/// `sys.oem_unlock_allowed` 这三条今天加过又撤了 —— 它们在 Duck 里**不进任何值判定**
/// （`SystemPropertiesCatalog.kt:196-202` 明写 oem_unlock 那一族"不计入完整性结论"，
/// 两条 vendor 镜像只出现在原生取证白名单里），而"属性缺失"在它那儿是**不参与判定**，
/// 不是失败。零收益 + 每次开机多三次 resetprop ⇒ 撤。
///
/// **有意没往里加的**（照抄别人那份表会把猜测写进 prop）：
/// - `ro.boot.vbmeta.size`（别人硬编码 4096）—— 我们量不到这台机真实的 vbmeta 分区大小，
///   写一个猜出来的值比空着更像被动过；
/// - `ro.boot.vbmeta.avb_version` / `invalidate_on_error` —— 同理，版本是设备相关的；
/// - `ro.boot.vbmeta.hash_alg` —— 摘要 64 位十六进制=sha256、128 位=sha512，
///   要按**生效摘要的长度**推，不能当常量；那需要固定表支持"动态期望值"，是下一步；
/// - MIUI `ro.secureboot.lockstate` / Realme `ro.boot.realmebootstate|lockstate` ——
///   这些只在对应厂商机上存在，进固定表等于在 Sony 上凭空造出 realme 的键，
///   是新的 tell。要走"只改已存在"那一类，也还没做。
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

/// 特征替换表：**就地**替换 —— 把值里出现的每一处 needle 换成 replacement，其余原样。
/// 与 lib/props.sh 的 props_expect_rules 同内容同顺序，由对拍守着。
/// 覆盖的是"构建身份"这一族：只改顶层 ro.build.type/tags 会留下
/// `ro.system.build.type=userdebug`、fingerprint 尾巴 `userdebug`、`ro.build.flavor`
/// 带 userdebug 这类自相矛盾 —— 应用逐键读就能看见。
/// 顺序有讲究：同一个属性的多条规则按这里的顺序链式改完、只落一次盘（见 props_write_plan）。
const PROPS_RULES: &[(&str, &str, &str)] = &[
    ("ro.bootloader", "engineering", "release"),
    ("ro.build.flavor", "userdebug", "user"),
    ("ro.build.description", "userdebug", "user"),
    ("ro.build.description", "test-keys", "release-keys"),
    ("ro.bootimage.build.type", "userdebug", "user"),
    ("ro.odm.build.type", "userdebug", "user"),
    ("ro.product.build.type", "userdebug", "user"),
    ("ro.system.build.type", "userdebug", "user"),
    ("ro.system_dlkm.build.type", "userdebug", "user"),
    ("ro.system_ext.build.type", "userdebug", "user"),
    ("ro.vendor.build.type", "userdebug", "user"),
    ("ro.vendor_dlkm.build.type", "userdebug", "user"),
    ("ro.bootimage.build.tags", "test-keys", "release-keys"),
    ("ro.odm.build.tags", "test-keys", "release-keys"),
    ("ro.product.build.tags", "test-keys", "release-keys"),
    ("ro.system.build.tags", "test-keys", "release-keys"),
    ("ro.system_dlkm.build.tags", "test-keys", "release-keys"),
    ("ro.system_ext.build.tags", "test-keys", "release-keys"),
    ("ro.vendor.build.tags", "test-keys", "release-keys"),
    ("ro.vendor_dlkm.build.tags", "test-keys", "release-keys"),
    ("ro.build.fingerprint", "userdebug", "user"),
    ("ro.build.fingerprint", "test-keys", "release-keys"),
    ("ro.bootimage.build.fingerprint", "userdebug", "user"),
    ("ro.bootimage.build.fingerprint", "test-keys", "release-keys"),
    ("ro.odm.build.fingerprint", "userdebug", "user"),
    ("ro.odm.build.fingerprint", "test-keys", "release-keys"),
    ("ro.product.build.fingerprint", "userdebug", "user"),
    ("ro.product.build.fingerprint", "test-keys", "release-keys"),
    ("ro.system.build.fingerprint", "userdebug", "user"),
    ("ro.system.build.fingerprint", "test-keys", "release-keys"),
    ("ro.system_dlkm.build.fingerprint", "userdebug", "user"),
    ("ro.system_dlkm.build.fingerprint", "test-keys", "release-keys"),
    ("ro.system_ext.build.fingerprint", "userdebug", "user"),
    ("ro.system_ext.build.fingerprint", "test-keys", "release-keys"),
    ("ro.vendor.build.fingerprint", "userdebug", "user"),
    ("ro.vendor.build.fingerprint", "test-keys", "release-keys"),
    ("ro.vendor_dlkm.build.fingerprint", "userdebug", "user"),
    ("ro.vendor_dlkm.build.fingerprint", "test-keys", "release-keys"),
];

/// 两张表摊平成一个判定序列（awk 里是 spec 流，这里同构）。
enum SpecRow {
    Pair(&'static str, &'static str),
    Rule(&'static str, &'static str, &'static str),
}

fn props_spec() -> Vec<SpecRow> {
    let mut v = Vec::with_capacity(PROPS_PAIRS.len() + PROPS_RULES.len());
    for (name, expected) in PROPS_PAIRS {
        v.push(SpecRow::Pair(name, expected));
    }
    for (name, needle, replacement) in PROPS_RULES {
        v.push(SpecRow::Rule(name, needle, replacement));
    }
    v
}

/// 展示四列，与 lib/props.sh 的 `props_plan display` 逐字节同形。
/// 状态：固定表用 missing（缺了要凭空补出来），特征表用 absent
/// —— 这台机压根没有那个分区不是缺陷，不能计入「写入并复核」的不符项。
fn props_display_rows(snapshot: &std::collections::HashMap<String, String>) -> Vec<[String; 4]> {
    let cur_of = |name: &str| -> String { snapshot.get(name).cloned().unwrap_or_default() };
    let mut out = Vec::new();
    for row in props_spec() {
        match row {
            SpecRow::Pair(name, expected) => {
                let cur = cur_of(name);
                let st = if cur.is_empty() {
                    "missing"
                } else if cur == expected {
                    "ok"
                } else {
                    "diff"
                };
                out.push([name.to_string(), cur, expected.to_string(), st.to_string()]);
            }
            SpecRow::Rule(name, needle, replacement) => {
                let cur = cur_of(name);
                let st = if cur.is_empty() {
                    "absent"
                } else if cur.contains(needle) {
                    "diff"
                } else {
                    "ok"
                };
                out.push([
                    name.to_string(),
                    cur,
                    format!("不含 {needle}（则改写为 {replacement}）"),
                    st.to_string(),
                ]);
            }
        }
    }
    out
}

/// 写入计划，与 awk 的 `props_plan write` 同语义：固定表缺/不同就写期望值；
/// 特征行命中就就地改写，同一个属性的多条规则按表序链式串完，合起来只出一条。
fn props_write_plan(snapshot: &std::collections::HashMap<String, String>) -> Vec<(String, String)> {
    let mut goal: std::collections::HashMap<String, String> = std::collections::HashMap::new();
    let mut order: Vec<String> = Vec::new();
    for row in props_spec() {
        let (name, is_rule, needle, replacement, expected) = match row {
            SpecRow::Pair(n, e) => (n, false, "", "", Some(e)),
            SpecRow::Rule(n, nd, rp) => (n, true, nd, rp, None),
        };
        let touch = |order: &mut Vec<String>, name: &str| {
            if !order.iter().any(|k| k == name) {
                order.push(name.to_string());
            }
        };
        if !is_rule {
            goal.insert(name.to_string(), expected.unwrap_or_default().to_string());
            touch(&mut order, name);
            continue;
        }
        let cur = snapshot.get(name).cloned().unwrap_or_default();
        if cur.is_empty() || !cur.contains(needle) {
            continue;
        }
        let base = goal.get(name).cloned().unwrap_or_else(|| cur.clone());
        goal.insert(name.to_string(), base.replace(needle, replacement));
        touch(&mut order, name);
    }
    let mut plan = Vec::new();
    for k in order {
        let Some(g) = goal.get(&k) else { continue };
        let c = snapshot.get(&k).cloned().unwrap_or_default();
        if g != &c {
            plan.push((k, g.clone()));
        }
    }
    plan
}

/// cmd_props：name<TAB>当前<TAB>期望<TAB>状态（先固定表，再特征替换表）。
pub fn props() {
    let snap = prop_snapshot();
    for row in props_display_rows(&snap) {
        println_ok!("{}\t{}\t{}\t{}", row[0], row[1], row[2], row[3]);
    }
}

/// 单个属性的读数口径，对齐 `module/webui.sh` 的 `prop_now`（那边也是 getprop）。
/// 报告用的 current= 一律走这里，不走 resetprop：resetprop 不在 PATH 时它会答空，
/// 而属性其实有值 —— 真机上就这么报出过一次假空。写完的复核仍用 resetprop（两边同）。
fn getprop(name: &str) -> String {
    std::process::Command::new("getprop")
        .arg(name)
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim_end_matches('\n').to_string())
        .unwrap_or_default()
}

/// 一次 `getprop` 全量 dump 建快照。
/// 为什么：这台机每次 fork 约 18ms，props 页有 17 行，逐键取实测 294ms；
/// 而全量 dump 实测 45ms（同机、同一次开机）。只给只读的 props 页用 ——
/// props_apply 的"写完读回"仍逐键读，那是复核，不能拿快照糊过去。
fn prop_snapshot() -> std::collections::HashMap<String, String> {
    let mut m = std::collections::HashMap::new();
    if let Ok(o) = std::process::Command::new("getprop").output() {
        for line in String::from_utf8_lossy(&o.stdout).lines() {
            // 形如 `[键]: [值]`；值里可以有 ] 与空格，所以只在第一个 `]: [` 处切
            if let Some(rest) = line.strip_prefix('[') {
                if let Some((k, v)) = rest.split_once("]: [") {
                    m.insert(k.to_string(), v.strip_suffix(']').unwrap_or(v).to_string());
                }
            }
        }
    }
    m
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
    let flush = |cur: &String, order: &mut Vec<String>, a: &HashMap<String, String>, b: &HashMap<String, String>, c: &HashMap<String, String>| {
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
        eprintln_ok!("当前后端不是 TEE Simulator");
        std::process::exit(1);
    }
    if !p.teesim_config.is_file() {
        eprintln_ok!("配置不存在：{}", p.teesim_config.display());
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
    // 注：参照 awk 里也有一个 depth 计数器，加了从来不读（顶层判定靠的是
    // "命中就把整块跳过去"，见 teesim_profiles.awk 的 j = e + 1），所以这里不搬。
    // 夹具里的 profiles.strong.limits.max_apps 诱饵钉住这件事（rust/parity.sh）。
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
        j += 1;
    }
    if entries.is_empty() {
        std::process::exit(1);
    }
    let emit = |name: &str, sub: &[u8]| {
        let kb = obj_string(sub, "keybox");
        let mode = obj_string(sub, "mode");
        let apps = count_array(sub, "apps");
        println_ok!(
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
        eprintln_ok!("当前后端不是 TEE Simulator");
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
        println_ok!("{}\t{}\t{}\t{}", f, if v.is_empty() { "-".to_string() } else { v }, ed, src);
    }
}

/// cmd_tricky_patches：只读解析 security_patch.txt。
pub fn tricky_patches() {
    let root = Root::from_env();
    let p = Paths::new(&root);
    let b = backend::detect(&p);
    if b.id != BackendId::Tricky {
        eprintln_ok!("当前后端不是 Tricky Store");
        std::process::exit(1);
    }
    let f = p.tstore_dir.join("security_patch.txt");
    if !f.is_file() {
        eprintln_ok!("文件不存在：{}", f.display());
        std::process::exit(1);
    }
    let rows = tricky_patches_rows(&std::fs::read_to_string(&f).unwrap_or_default());
    if rows.is_empty() {
        std::process::exit(1);
    }
    for (s, a, b2, c) in rows {
        println_ok!("{}\t{}\t{}\t{}", s, a, b2, c);
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
/// 原子写 boot_hash（600），返回是否落盘成功。
fn write_boot_hash(p: &Paths, content: &str) -> bool {
    let tmp = format!("{}.tmp.{}", p.boot_hash.display(), std::process::id());
    let wrote = std::fs::write(&tmp, format!("{content}\n")).is_ok();
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
    }
    ok
}

/// apply_boot_hash：把 h 写进 digest（不同才写）、hash_alg 为空时按长度补、读回比对。
/// h 为空 = 无需处理，按成功返回（与 lib/props.sh 同一条：没值可写不算失败）。
fn apply_digest(h: &str) -> bool {
    if h.is_empty() {
        return true;
    }
    let cur = resetprop(&["ro.boot.vbmeta.digest"]);
    if cur != h {
        let _ = resetprop(&["-n", "ro.boot.vbmeta.digest", h]);
    }
    let alg = resetprop(&["ro.boot.vbmeta.hash_alg"]);
    if alg.is_empty() {
        let want = if h.len() == 128 { "sha512" } else { "sha256" };
        let _ = resetprop(&["-n", "ro.boot.vbmeta.hash_alg", want]);
    }
    resetprop(&["ro.boot.vbmeta.digest"]) == h
}

/// props-boot-hash：三态写入（hex=手动 / auto·-·空=回到自动 / off=明确不写）。
/// 输出键与顺序必须与 lib/write.sh 的 cmd_set_boot_hash 逐字节相同。
pub fn props_boot_hash(arg: &str) {
    let root = Root::from_env();
    let p = Paths::new(&root);
    if backends_conflict(&p) {
        eprintln_ok!("{}", CONFLICT_MSG);
        std::process::exit(1);
    }
    let v: String = arg.chars().filter(|c| !c.is_whitespace()).collect::<String>().to_ascii_lowercase();

    if v.is_empty() || v == "-" || v == "auto" {
        let _ = std::fs::remove_file(&p.boot_hash);
        if p.boot_hash.exists() {
            eprintln_ok!("清除失败：{}", p.boot_hash.display());
            std::process::exit(1);
        }
        // 删掉文件不等于"不写"：自动档会当场从当前后端的配置派生并应用
        let applied = if apply_digest(&boot_hash_effective(&p)) { 1 } else { 0 };
        log_line(&p, "🔄 WebUI 把 Verified Boot 哈希改回自动档（开机与本次都从当前后端的配置取；取不到就不写）");
        println_ok!("saved=0");
        println_ok!("mode={}", boot_hash_mode(&p));
        println_ok!("applied={applied}");
        println_ok!("current={}", getprop("ro.boot.vbmeta.digest"));
        return;
    }

    if v == "off" {
        if !write_boot_hash(&p, "off") {
            eprintln_ok!("写入失败：{}", p.boot_hash.display());
            std::process::exit(1);
        }
        log_line(&p, "🚫 WebUI 设置 Verified Boot 哈希为「不写 digest」（本次运行已写进去的值要重启才回原值）");
        println_ok!("saved=1");
        println_ok!("mode=off");
        println_ok!("applied=0");
        println_ok!("current={}", getprop("ro.boot.vbmeta.digest"));
        return;
    }

    if !boot_hash_valid(&v) {
        eprintln_ok!("哈希必须是 64 或 128 位十六进制（或 auto / off）");
        std::process::exit(1);
    }
    if !write_boot_hash(&p, &v) {
        eprintln_ok!("写入失败：{}", p.boot_hash.display());
        std::process::exit(1);
    }
    let applied = apply_digest(&v);
    if applied {
        log_line(&p, &format!("🧩 WebUI 设置 Verified Boot 哈希（{} 位）并已应用", v.len()));
    } else {
        log_line(&p, "⚠️ WebUI 保存 Verified Boot 哈希，但写入后读回不一致");
        println_ok!("apply_note=已保存到配置，但立即应用失败（写入后读回不一致）；下次开机仍会再写一次");
    }
    println_ok!("saved=1");
    println_ok!("mode=manual");
    println_ok!("applied={}", if applied { 1 } else { 0 });
    println_ok!("current={}", getprop("ro.boot.vbmeta.digest"));
}

/// cmd_props_apply：按期望表写一次（缺/不符才写），复核后输出 applied / mismatch。
pub fn props_apply() {
    let root = Root::from_env();
    let p = Paths::new(&root);
    if backends_conflict(&p) {
        eprintln_ok!("{}", CONFLICT_MSG);
        std::process::exit(1);
    }
    if std::process::Command::new("resetprop").arg("--version").output().is_err() {
        eprintln_ok!("未找到 resetprop 命令");
        std::process::exit(1);
    }
    if p.props_off.is_file() {
        eprintln_ok!("属性伪装已关闭，请先在界面上重新开启");
        std::process::exit(1);
    }
    // apply_resetprop：一次全量 dump 出计划，再按计划落盘（与 lib/props.sh 同语义）。
    // dump 空了说明 getprop 没跑成，逐键回落 —— 不能把"读不到"当成"属性不存在"，
    // 那会凭空写出一堆 stock 没有的键。
    let pre = prop_snapshot();
    if pre.is_empty() {
        for (name, expected) in PROPS_PAIRS {
            let cur = resetprop(&[name]);
            if cur.is_empty() || cur != *expected {
                let _ = resetprop(&["-n", name, expected]);
            }
        }
        for (name, needle, replacement) in PROPS_RULES {
            let cur = resetprop(&[name]);
            if !cur.is_empty() && cur.contains(needle) {
                // 就地替换每一处命中；同名多条规则会各自重读一次，天然链式
                let v = cur.replace(needle, replacement);
                let _ = resetprop(&["-n", name, &v]);
            }
        }
    } else {
        for (name, value) in props_write_plan(&pre) {
            let _ = resetprop(&["-n", &name, &value]);
        }
    }
    apply_boot_hash_quiet(&p);
    log_line(&p, "🛠 WebUI 触发一次属性伪装（运行期写入；已被应用读取的静态字段不会刷新）");

    // 复核：写完之后**重新取一次**快照，不复用写前那份。shell 侧的复核是新起
    // 一个进程跑 props（同样只用 getprop），所以这里也不给复核留 resetprop 回落：
    // getprop 废掉时两侧都得照实报读不到，宁可红，不能一边靠另一边的工具兜住。
    let post = prop_snapshot();
    let rows = props_display_rows(&post);
    let want = PROPS_PAIRS.len();
    let got = rows.len();
    if got < want {
        eprintln_ok!("写入后复核失败（重读退码 0，读到 {}/{} 行），不能报已生效", got, want);
        println_ok!("applied=0");
        println_ok!("mismatch=-1");
        std::process::exit(1);
    }
    // 只数 diff / missing：特征表那侧的 absent（这台机没那个分区）不是缺陷。
    let bad = rows.iter().filter(|r| r[3] == "diff" || r[3] == "missing").count();
    println_ok!("applied=1");
    println_ok!("mismatch={}", bad);
}

/// apply_boot_hash 的非致命版本（失败只在调用方提示）。
/// 用**生效值**：手动档是文件里的 hex，自动档现读当前后端的配置（不缓存）。
fn apply_boot_hash_quiet(p: &Paths) {
    let _ = apply_digest(&boot_hash_effective(p));
}

/// cmd_props_switch：props-on / props-off（开关文件即关闭标记）。
pub fn props_switch(want: &str) {
    let root = Root::from_env();
    let p = Paths::new(&root);
    if want != "on" && want != "off" {
        eprintln_ok!("参数只能是 on 或 off");
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
        eprintln_ok!("开关文件写入失败：{}", p.props_off.display());
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
    println_ok!("props_masking={}", want);
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
        eprintln_ok!("{}", CONFLICT_MSG);
        std::process::exit(1);
    }
    let b = backend::detect(&p);
    if b.id != BackendId::Tricky {
        eprintln_ok!("当前后端不是 Tricky Store");
        std::process::exit(1);
    }
    if scope.is_empty() || scope == "global" {
        eprintln_ok!("只能删按包段（[包名]）；全局段是补丁表的主体，不能删");
        std::process::exit(1);
    }
    if !valid_pkg(scope) {
        eprintln_ok!("scope 必须是合法包名：{}", scope);
        std::process::exit(1);
    }
    let target = p.tstore_dir.join("security_patch.txt");
    if !target.is_file() {
        eprintln_ok!("补丁表不存在：{}", target.display());
        std::process::exit(1);
    }
    let marks: Vec<String> = vec![std::env::var("KL_LOCK_MARK").unwrap_or_else(|_| {
        p.module_prop.parent().and_then(|m| m.file_name()).map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| "keylens".to_string())
    })];
    let lockdir = b.dir.join(".kl_lock");
    if !crate::lock::acquire(&lockdir, 6, &marks) {
        eprintln_ok!("守护进程正在写入，请几秒后再试");
        std::process::exit(1);
    }
    let old = std::fs::read_to_string(&target).unwrap_or_default();
    let (new_text, status) = tricky_drop_rewrite(&old, scope);
    let rc = match status {
        "missing" => {
            crate::lock::release(&lockdir);
            eprintln_ok!("补丁表里没有 [{}] 这一段", scope);
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
        eprintln_ok!("补丁表删除失败");
        std::process::exit(1);
    }
    log_line(&p, &format!("🧩 WebUI 删除 Tricky 补丁段（scope={}）", scope));
    println_ok!("dropped=1");
    println_ok!("scope={}", scope);
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
    // 注：shell 参照 tricky_patch_set.awk 的第 4/5 步会"回缩跳过段尾空行与注释行"，
    // 这里没有同形代码 —— 夹具补上那个形状后两侧逐字节仍相同（rust/parity.sh 的
    // save-patch 组，含两条防空转断言），所以不需要；别再顺手加一个没人用的 is_blank。
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
        eprintln_ok!("{}", CONFLICT_MSG);
        std::process::exit(1);
    }
    let b = backend::detect(&p);
    if b.id != BackendId::Tricky {
        eprintln_ok!("当前后端不是 Tricky Store");
        std::process::exit(1);
    }
    let mut fields = match crate::payload::parse(payload) {
        Ok(v) => v,
        Err(msg) => {
            eprintln_ok!("{}", msg);
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
        eprintln_ok!("scope 必须是 global 或一个合法包名：{}", scope);
        std::process::exit(1);
    }
    if fields.is_empty() {
        eprintln_ok!("没有可写字段");
        std::process::exit(1);
    }
    for (k, v) in &fields {
        match k.as_str() {
            "patch_system" | "patch_vendor" | "patch_boot" | "patch_all" => {
                if !valid_tricky_patch(v) {
                    eprintln_ok!(
                        "补丁值不合法：{} = {}（接受 YYYY-MM-DD / YYYYMMDD / YYYYMM / no / device_default / prop / YYYY、MM、DD 占位）",
                        k, v
                    );
                    std::process::exit(1);
                }
            }
            other => {
                eprintln_ok!("未知字段：{}", other);
                std::process::exit(1);
            }
        }
    }
    let target = p.tstore_dir.join("security_patch.txt");
    if !target.is_file() {
        let _ = std::fs::create_dir_all(&p.tstore_dir);
        if std::fs::File::create(&target).is_err() {
            eprintln_ok!("补丁表不存在且无法创建：{}", target.display());
            std::process::exit(1);
        }
    }
    let marks: Vec<String> = vec![std::env::var("KL_LOCK_MARK").unwrap_or_else(|_| {
        p.module_prop.parent().and_then(|m| m.file_name()).map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| "keylens".to_string())
    })];
    let lockdir = b.dir.join(".kl_lock");
    if !crate::lock::acquire(&lockdir, 6, &marks) {
        eprintln_ok!("守护进程正在写入，请几秒后再试");
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
                    eprintln_ok!("写入失败：{}", target.display());
                    std::process::exit(1);
                }
                saved = 1;
            }
        }
        "same" => {}
        _ => {
            crate::lock::release(&lockdir);
            eprintln_ok!("补丁表写入失败");
            std::process::exit(1);
        }
    }
    crate::lock::release(&lockdir);
    if saved == 1 {
        log_line(&p, &format!("🧩 WebUI 更新 Tricky 补丁表（scope={}，{} 项）", scope, n));
    }
    println_ok!("saved={}", saved);
    println_ok!("fields={}", n);
    println_ok!("scope={}", scope);
}

/// cmd_set_mode：Tricky 条目模式改写（auto/leaf/generate），输出 changed。
pub fn set_mode(pkg: &str, mode: &str) {
    let root = Root::from_env();
    let p = Paths::new(&root);
    if backends_conflict(&p) {
        eprintln_ok!("{}", CONFLICT_MSG);
        std::process::exit(1);
    }
    let b = backend::detect(&p);
    if b.id != BackendId::Tricky {
        eprintln_ok!("只有 Tricky Store 后端支持条目模式");
        std::process::exit(1);
    }
    if !is_pkg_token(pkg) {
        eprintln_ok!("不是合法的包名：{}", pkg);
        std::process::exit(1);
    }
    if !matches!(mode, "auto" | "leaf" | "generate") {
        eprintln_ok!("模式只能是 auto / leaf / generate");
        std::process::exit(1);
    }
    if !b.target.is_file() {
        eprintln_ok!("写入失败：{}", b.target.display());
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
        eprintln_ok!("守护进程正在写入，请几秒后再试");
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
            println_ok!("changed=1");
        }
        1 => println_ok!("changed=0"),
        _ => {
            eprintln_ok!("写入失败：{}", b.target.display());
            std::process::exit(1);
        }
    }
}

/// cmd_omk_restart：触发 OMK 重载（restart.<范围>），输出 restarted / trigger。
pub fn omk_restart(which: &str) {
    let root = Root::from_env();
    let p = Paths::new(&root);
    if backends_conflict(&p) {
        eprintln_ok!("{}", CONFLICT_MSG);
        std::process::exit(1);
    }
    let b = backend::detect(&p);
    if b.id != BackendId::Omk {
        eprintln_ok!("当前后端不是 OhMyKeymint");
        std::process::exit(1);
    }
    if !matches!(which, "keymint" | "injector" | "all") {
        eprintln_ok!("只能触发 keymint / injector / all（收到：{}）", which);
        std::process::exit(1);
    }
    if !p.omk_state_dir.is_dir() {
        eprintln_ok!("目录不存在：{}（OMK 没装？）", p.omk_state_dir.display());
        std::process::exit(1);
    }
    let f = p.omk_state_dir.join(format!("restart.{}", which));
    match std::fs::File::create(&f) {
        Ok(_) => {}
        Err(_) => {
            eprintln_ok!("写入失败：{}", f.display());
            std::process::exit(1);
        }
    }
    log_line(&p, &format!("🛠 WebUI 触发 OhMyKeymint 重载：{}", which));
    println_ok!("restarted={}", which);
    println_ok!("trigger={}", f.display());
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
    println_ok!("cleared=1");
}

/// cmd_tee_status：读 Tricky 自己写的 tee_status（present/file + 四个已知键）。
pub fn tee_status() {
    let root = Root::from_env();
    let p = Paths::new(&root);
    let f = p.tstore_dir.join("tee_status");
    if !f.is_file() {
        println_ok!("present=0");
        return;
    }
    println_ok!("present=1");
    println_ok!("file={}", f.display());
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
        println_ok!("{}={}", key, rest);
    }
}

/// cmd_target_meta：tok<TAB>base<TAB>kind<TAB>detail（三家的语义在 cmd 里分叉）。
pub fn target_meta() {
    let root = Root::from_env();
    let p = Paths::new(&root);
    let b = backend::detect(&p);
    if !b.target.is_file() {
        eprintln_ok!("目标文件不存在：{}", b.target.display());
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
        println_ok!("{}\t{}\t{}\t{}", tok, base, kind, detail);
    }
}
pub fn targets() {
    let root = Root::from_env();
    let p = Paths::new(&root);
    let b = backend::detect(&p);
    if !b.target.is_file() {
        eprintln_ok!("目标文件不存在：{}", b.target.display());
        std::process::exit(1);
    }
    let data = std::fs::read(&b.target).unwrap_or_default();
    match b.id {
        BackendId::Tricky => {
            let text = String::from_utf8_lossy(&data);
            for t in tricky_tokens(&text) {
                println_ok!("{}", t);
            }
        }
        BackendId::Teesim => match teesim_apps(&data) {
            Some(v) => v.iter().for_each(|s| println_ok!("{}", s)),
            None => std::process::exit(1),
        },
        BackendId::Omk => match omk_scoop(&data) {
            Some(v) => v.iter().for_each(|s| println_ok!("{}", s)),
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
        eprintln_ok!("{}", CONFLICT_MSG);
        std::process::exit(1);
    }
    let b = backend::detect(&p);
    if b.id != BackendId::Teesim {
        eprintln_ok!("当前后端不是 TEE Simulator");
        std::process::exit(1);
    }
    let fields = match crate::payload::parse(payload) {
        Ok(v) => v,
        Err(msg) => { eprintln_ok!("{}", msg); std::process::exit(1); }
    };
    let ov = p.teesim_dir.join("overrides.json");
    let ha = p.teesim_dir.join("harvested.json");
    for (k, v) in &fields {
        let bad = match k.as_str() {
            "attestationSecurityLevel" | "keymasterSecurityLevel" => {
                if !crate::ov_valid::valid_ov_level(v) {
                    eprintln_ok!("{} 只能是 0(Software) / 1(TrustedEnvironment) / 2(StrongBox)，留空表示删掉这一项；收到的是「{}」", k, v);
                    true
                } else { false }
            }
            "attestationVersion" | "keymasterVersion" => {
                if !crate::ov_valid::valid_ov_version(v) {
                    eprintln_ok!("{} 只能是 1–100000 的整数，留空表示删掉这一项；收到的是「{}」", k, v);
                    true
                } else { false }
            }
            "verifiedBootKey" | "verifiedBootHash" => {
                if !crate::ov_valid::valid_ov_hex(v) {
                    eprintln_ok!("{} 要 64 位十六进制（可带 0x 前缀）、不许全零，留空表示删掉这一项；收到的是「{}」", k, v);
                    true
                } else if !v.is_empty() && ha.is_file() {
                    let ed = teesim_overrides_rows(&p).into_iter()
                        .find(|(name, _, _, _)| name == k)
                        .map(|(_, _, ed, _)| ed)
                        .unwrap_or_default();
                    if !ed.is_empty() && ed != "1" {
                        eprintln_ok!("{} 现在不可改：harvested.json 判它的来源不是合成兜底值（上游规则，不是本模块的限制）", k);
                        true
                    } else { false }
                } else { false }
            }
            _ => {
                eprintln_ok!("overrides.json 里这个字段被上游锁死为 REQUIRED，写进去守护进程会直接丢弃：{}", k);
                true
            }
        };
        if bad { std::process::exit(1); }
    }
    let n = fields.len();
    if n == 0 {
        eprintln_ok!("没有字段要保存");
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
        eprintln_ok!("守护进程正在写入，请几秒后再试");
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
                    eprintln_ok!("写入失败：{}", ov.display());
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
            eprintln_ok!("overrides.json 定位失败（不是可写的扁平对象？）：{}", ov.display());
            std::process::exit(1);
        }
    }
    crate::lock::release(&lockdir);
    if saved == 1 {
        log_line(&p, &format!("🧩 WebUI 更新 TEESim overrides.json（{} 项，热生效无需重启）", n));
    }
    println_ok!("saved={}", saved);
    println_ok!("fields={}", n);
    println_ok!("apply_note={}", if saved == 1 { "已写入，TEESim 监听该文件自行热生效，不需要重启" } else { "内容与现有一致，未写入" });
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
        eprintln_ok!("{}", CONFLICT_MSG);
        std::process::exit(1);
    }
    let b = backend::detect(&p);
    if payload.is_empty() {
        eprintln_ok!("keybox 内容为空");
        std::process::exit(1);
    }
    if payload.len() > 180000 {
        eprintln_ok!("keybox 过大（上限约 128KB）");
        std::process::exit(1);
    }
    let data = match crate::b64::decode(payload) {
        Some(v) => v,
        None => { eprintln_ok!("keybox 解码失败"); std::process::exit(1); }
    };
    let bytes = data.len();
    if !(64..=131072).contains(&bytes) {
        eprintln_ok!("keybox 大小不合法");
        std::process::exit(1);
    }
    let bname = match b.id { BackendId::Teesim => "TEE Simulator", BackendId::Omk => "OhMyKeymint", BackendId::Tricky => "Tricky Store" };
    if let Err(msg) = crate::keybox::check(&data, b.id.as_str()) {
        eprintln_ok!("keybox 结构不合格（{}）：{}", bname, msg);
        std::process::exit(1);
    }
    let target = keybox_path_for(&p, b.id);
    let marks: Vec<String> = vec![std::env::var("KL_LOCK_MARK").unwrap_or_else(|_| {
        p.module_prop.parent().and_then(|m| m.file_name()).map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| "keylens".to_string())
    })];
    let lockdir = b.dir.join(".kl_lock");
    if !crate::lock::acquire(&lockdir, 6, &marks) {
        eprintln_ok!("守护进程正在写入，请几秒后再试");
        std::process::exit(1);
    }
    let bak = b.dir.join("keybox.xml.bak");
    let ok = commit_target(&target, &data, Some(&bak));
    if ok {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o600));
        }
    }
    crate::lock::release(&lockdir);
    if !ok {
        eprintln_ok!("写入失败：{}", target.display());
        std::process::exit(1);
    }
    log_line(&p, &format!("🔑 WebUI 替换 keybox：{}（{} 字节）", target.display(), bytes));
    let sha = std::process::Command::new("sha256sum").arg(&target).output().ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).split_whitespace().next().unwrap_or("").to_string())
        .unwrap_or_default();
    println_ok!("saved=1");
    println_ok!("keybox_file={}", target.display());
    println_ok!("keybox_bytes={}", bytes);
    println_ok!("keybox_sha={}", sha);
}

/// cmd_backup_restore：把 KL_DIR/<name> 还原回它对应的后端文件（保留属主与权限）。
pub fn backup_restore(name: &str) {
    let root = Root::from_env();
    let p = Paths::new(&root);
    if backends_conflict(&p) {
        eprintln_ok!("{}", CONFLICT_MSG);
        std::process::exit(1);
    }
    let b = backend::detect(&p);
    if name.is_empty() || name.contains('/') || name.contains("..") {
        eprintln_ok!("备份名不合法：{}", name);
        std::process::exit(1);
    }
    let src = b.dir.join(name);
    let Some(tgt) = backup_target(&b, &p, name) else {
        eprintln_ok!("当前后端没有这个备份：{}", name);
        std::process::exit(1);
    };
    let Ok(md) = std::fs::metadata(&src) else { eprintln_ok!("备份不存在或为空：{}", src.display()); std::process::exit(1) };
    if md.len() == 0 {
        eprintln_ok!("备份不存在或为空：{}", src.display());
        std::process::exit(1);
    }
    if name == "keybox.xml.bak" {
        let data = std::fs::read(&src).unwrap_or_default();
        if let Err(msg) = crate::keybox::check(&data, b.id.as_str()) {
            eprintln_ok!("这份 keybox 备份结构不合格：{}", msg);
            std::process::exit(1);
        }
    }
    let marks: Vec<String> = vec![std::env::var("KL_LOCK_MARK").unwrap_or_else(|_| {
        p.module_prop.parent().and_then(|m| m.file_name()).map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| "keylens".to_string())
    })];
    let lockdir = b.dir.join(".kl_lock");
    if !crate::lock::acquire(&lockdir, 6, &marks) {
        eprintln_ok!("守护进程正在写入，请几秒后再试");
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
        eprintln_ok!("回滚失败：{} 没被改动", tgt.display());
        std::process::exit(1);
    }
    let base = tgt.file_name().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    log_line(&p, &format!("♻️ WebUI 用备份还原了 {}（来源 {}）", base, name));
    println_ok!("restored=1");
    println_ok!("name={}", name);
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
        eprintln_ok!("{}", CONFLICT_MSG);
        std::process::exit(1);
    }
    let b = backend::detect(&p);
    if b.id != BackendId::Teesim {
        eprintln_ok!("当前后端不是 TEE Simulator");
        std::process::exit(1);
    }
    if !p.teesim_config.is_file() {
        eprintln_ok!("配置不存在：{}", p.teesim_config.display());
        std::process::exit(1);
    }
    if name.is_empty() || name == "default" {
        eprintln_ok!("default 是兜底 profile，不能删");
        std::process::exit(1);
    }
    if name.is_empty() || !name.bytes().all(|c| c.is_ascii_alphanumeric() || matches!(c, b'.' | b'_' | b'-')) {
        eprintln_ok!("名字只能用字母、数字、. _ -：{}", name);
        std::process::exit(1);
    }
    let marks: Vec<String> = vec![std::env::var("KL_LOCK_MARK").unwrap_or_else(|_| {
        p.module_prop.parent().and_then(|m| m.file_name()).map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| "keylens".to_string())
    })];
    let lockdir = b.dir.join(".kl_lock");
    if !crate::lock::acquire(&lockdir, 6, &marks) {
        eprintln_ok!("守护进程正在写入，请几秒后再试");
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
        eprintln_ok!("删除 profile 失败");
        std::process::exit(1);
    };
    let Some(hit) = member_span(&old, ob, oc, name) else {
        crate::lock::release(&lockdir);
        eprintln_ok!("没有这个 profile：{}", name);
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
        eprintln_ok!("写入失败：{}", p.teesim_config.display());
        std::process::exit(1);
    }
    if let Some(m) = mode {
        let _ = std::fs::set_permissions(&p.teesim_config, m);
    }
    crate::lock::release(&lockdir);
    log_line(&p, &format!("🧰 WebUI 删除 TEESim profile（{}）", name));
    println_ok!("removed=1");
    println_ok!("profile={}", name);
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

/// cmd_teesim_profile_new：把 profiles.default 整份复制成一份新 profile。
pub fn teesim_profile_new(name: &str) {
    let root = Root::from_env();
    let p = Paths::new(&root);
    if backends_conflict(&p) {
        eprintln_ok!("{}", CONFLICT_MSG);
        std::process::exit(1);
    }
    let b = backend::detect(&p);
    if b.id != BackendId::Teesim {
        eprintln_ok!("当前后端不是 TEE Simulator");
        std::process::exit(1);
    }
    if !p.teesim_config.is_file() {
        eprintln_ok!("配置不存在：{}", p.teesim_config.display());
        std::process::exit(1);
    }
    if name.is_empty() || name == "default" {
        eprintln_ok!("名字不能为空，也不能叫 default");
        std::process::exit(1);
    }
    if !name.bytes().all(|c| c.is_ascii_alphanumeric() || matches!(c, b'.' | b'_' | b'-')) {
        eprintln_ok!("名字只能用字母、数字、. _ -：{}", name);
        std::process::exit(1);
    }
    let marks: Vec<String> = vec![std::env::var("KL_LOCK_MARK").unwrap_or_else(|_| {
        p.module_prop.parent().and_then(|m| m.file_name()).map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| "keylens".to_string())
    })];
    let lockdir = b.dir.join(".kl_lock");
    if !crate::lock::acquire(&lockdir, 6, &marks) {
        eprintln_ok!("守护进程正在写入，请几秒后再试");
        std::process::exit(1);
    }
    let old = std::fs::read(&p.teesim_config).unwrap_or_default();
    // profiles 对象
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
        eprintln_ok!("新建 profile 失败（配置里找不到 profiles.default？）");
        std::process::exit(1);
    };
    if member_span(&old, ob, oc, name).is_some() {
        crate::lock::release(&lockdir);
        eprintln_ok!("profile 已存在：{}", name);
        std::process::exit(1);
    }
    let Some(d) = member_span(&old, ob, oc, "default") else {
        crate::lock::release(&lockdir);
        eprintln_ok!("新建 profile 失败（配置里找不到 profiles.default？）");
        std::process::exit(1);
    };
    let dobj = &old[d.ks..=d.ke];
    // 成员缩进：default 键那一行的行首空白
    let mut line_start = d.kbs;
    while line_start > ob + 1 && old[line_start - 1] != b'\n' { line_start -= 1; }
    let mut memberind = String::new();
    let mut i = line_start;
    while i < d.kbs && matches!(old[i], b' ' | b'\t') { memberind.push(old[i] as char); i += 1; }
    // 收尾花括号的缩进
    let mut closeind = String::new();
    let mut j = oc;
    while j > ob + 1 && matches!(old[j - 1], b' ' | b'\t') { j -= 1; closeind.insert(0, old[j] as char); }
    let mut before = old[ob..oc].to_vec();
    while let Some(&last) = before.last() {
        if matches!(last, b' ' | b'\t' | b'\r' | b'\n') { before.pop(); } else { break; }
    }
    if !matches!(before.last(), Some(&b'{') | Some(&b',')) { before.push(b','); }
    let mut newpobj: Vec<u8> = Vec::new();
    newpobj.extend_from_slice(&before);
    newpobj.push(b'\n');
    newpobj.extend_from_slice(memberind.as_bytes());
    newpobj.extend_from_slice(format!("\"{}\": ", name).as_bytes());
    newpobj.extend_from_slice(dobj);
    newpobj.push(b'\n');
    newpobj.extend_from_slice(closeind.as_bytes());
    newpobj.push(b'}');
    let mut out: Vec<u8> = Vec::new();
    out.extend_from_slice(&old[..ob]);
    out.extend_from_slice(&newpobj);
    out.extend_from_slice(&old[oc + 1..]);
    let bak = b.dir.join("config.json.bak");
    let _ = std::fs::copy(&p.teesim_config, &bak);
    let mode = std::fs::metadata(&p.teesim_config).ok().map(|m| m.permissions());
    let tmp = b.dir.join(format!(".config.json.keylens.{}", std::process::id()));
    let ok = std::fs::write(&tmp, &out).is_ok() && std::fs::rename(&tmp, &p.teesim_config).is_ok();
    if !ok {
        let _ = std::fs::remove_file(&tmp);
        crate::lock::release(&lockdir);
        eprintln_ok!("写入失败：{}", p.teesim_config.display());
        std::process::exit(1);
    }
    if let Some(m) = mode { let _ = std::fs::set_permissions(&p.teesim_config, m); }
    crate::lock::release(&lockdir);
    log_line(&p, &format!("🧰 WebUI 新建 TEESim profile（{}，复制自 default）", name));
    println_ok!("created=1");
    println_ok!("profile={}", name);
}

/// doctor：11 项自检（与 webui.sh 的 cmd_doctor 同序同文案）。
pub fn doctor() {
    let root = Root::from_env();
    let p = Paths::new(&root);
    let b = backend::detect(&p);
    let has_backend = true; // detect 总会给出一个后端；shell 里 KL_BACKEND 为空才算没有
    let mut rows: Vec<(String, String, String, String)> = Vec::new();
    let mut doc = |cat: &str, st: &str, desc: &str, tip: &str| {
        rows.push((cat.to_string(), st.to_string(), desc.to_string(), tip.to_string()));
    };
    // 1. 权限
    if is_root() {
        doc("权限", "ok", "以 root 运行", "");
    } else {
        doc("权限", "bad", "不是 root", "在管理器里给本模块 / WebUI root 权限");
    }
    // 2. 后端
    let bname = match b.id {
        BackendId::Teesim => "TEE Simulator",
        BackendId::Omk => "OhMyKeymint",
        BackendId::Tricky => "Tricky Store",
    };
    doc("后端", "ok", &format!("{} · 配置 {}", bname, b.target.display()), "");

    if has_backend {
        let marks: Vec<String> = {
            // 与 shell 的 KL_OUR_MARKS 完全一致：判定"是不是本模块的进程"只看这几个标记，
            // 不看模块安装路径（换目录/换名字安装时仍能认出自己）。
            let mut v: Vec<String> = vec![
                "keylens".to_string(),
                "ts-auto-add".to_string(),
                "ts_auto".to_string(),
            ];
            if let Ok(extra) = std::env::var("KL_OUR_MARKS") {
                v.extend(extra.split_whitespace().map(|s| s.to_string()));
            }
            v
        };
        // 3. 守护进程
        let mut np = 0;
        if let Ok(text) = std::fs::read_to_string(b.dir.join(".kl_daemon_pids.list")) {
            for pid in text.lines().map(str::trim).filter(|s| !s.is_empty()) {
                if pid_is_ours(pid, &marks) {
                    np += 1;
                }
            }
        }
        if np > 0 {
            doc("守护进程", "ok", &format!("{} 个进程在跑", np), "");
        } else {
            doc("守护进程", "bad", "没有守护进程在跑", "现在装/卸应用不会自动进名单：重启一次，或重新刷入模块");
        }
        // 4. 目标文件
        if b.target.is_file() {
            if writable(&b.target) {
                doc("目标文件", "ok", &format!("{} 存在且可写", b.target.display()), "");
            } else {
                doc("目标文件", "warn", &format!("{} 不可写", b.target.display()), "检查是否被别的模块或后端改成了只读");
            }
        } else {
            doc("目标文件", "bad", &format!("不存在：{}", b.target.display()), "让后端先跑一轮生成默认文件，或在「自动同步」页点「立即同步一次」");
        }
        // 5. 名单 vs 已装（只比数量）
        let nl = if b.target.is_file() {
            let data = std::fs::read(&b.target).unwrap_or_default();
            match b.id {
                BackendId::Tricky => tricky_tokens(&String::from_utf8_lossy(&data)).len(),
                BackendId::Teesim => teesim_apps(&data).map(|v| v.len()).unwrap_or(0),
                BackendId::Omk => omk_scoop(&data).map(|v| v.len()).unwrap_or(0),
            }
        } else {
            0
        };
        let ni = installed_count();
        if ni > 0 {
            if nl < ni {
                doc("名单", "warn", &format!("已装 {} 个 · 名单 {} 条（只比数量，可能只是你手动排除过）", ni, nl), "点「立即同步一次」，或等下一次安装/卸载自动触发");
            } else {
                doc("名单", "ok", &format!("已装 {} 个 · 名单 {} 条", ni, nl), "");
            }
        } else {
            doc("名单", "skip", "读不到已装应用列表", "");
        }
        // 6. keybox
        let kb = keybox_path_for(&p, b.id);
        if !kb.is_file() {
            doc("keybox", "bad", &format!("不存在：{}", kb.display()), "在「密钥箱」页粘贴一份，或让后端生成默认 keybox");
        } else {
            let data = std::fs::read(&kb).unwrap_or_default();
            match crate::keybox::check(&data, b.id.as_str()) {
                Ok(()) => {
                    let base = kb.file_name().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
                    doc("keybox", "ok", &format!("{} 结构通过校验", base), "");
                }
                Err(msg) => {
                    doc("keybox", "bad", &format!("结构不合格：{}", msg), "在「密钥箱」页重新粘贴一份完整的 keybox.xml");
                }
            }
        }
        // 7. 属性伪装
        if p.props_off.is_file() {
            doc("属性伪装", "ok", "开机写入已关闭（开关文件存在）", "");
        } else {
            let mut dif = 0;
            for (name, expected) in PROPS_PAIRS {
                let cur = getprop(name);
                if cur.is_empty() || cur != *expected {
                    dif += 1;
                }
            }
            if dif > 0 {
                doc("属性伪装", "warn", &format!("开机写入已开启，{} 项与期望值不符", dif), "点「立即应用一次」；仍不符就看属性页里那几行的当前值");
            } else {
                doc("属性伪装", "ok", "开机写入已开启，对照项全部一致", "");
            }
        }
        // 8. 启动哈希
        let (bh_st, bh_msg, bh_next) = boot_hash_doctor_row(
            boot_hash_mode(&p), &boot_hash_effective(&p), &getprop("ro.boot.vbmeta.digest"));
        doc("启动哈希", bh_st, &bh_msg, &bh_next);
        // 9. 监听工具
        match find_inotify() {
            Some(mode) => doc("监听工具", "ok", mode, ""),
            None => doc("监听工具", "bad", "没找到 inotify 工具", "模块靠它感知安装/卸载；这期间只能手动同步"),
        }
        // 10. 并发锁
        let lock = b.dir.join(".kl_lock");
        if lock.is_dir() {
            let pid = std::fs::read_to_string(lock.join("pid")).unwrap_or_default().trim().to_string();
            if !pid.is_empty() && pid_is_ours(&pid, &marks) {
                doc("并发锁", "warn", &format!("正在写入（pid {}）", pid), "等几秒再试；长期不释放的会在日志里留一条");
            } else {
                doc("并发锁", "warn", "有残留锁，持有者已不在", "不用管，下一次写入会自动接管");
            }
        } else {
            doc("并发锁", "ok", "空闲", "");
        }
        // 11. 名单共用：同一份 target 文件可能有别的模块也在写（Tricky-Addon 的自动更新、
        // TSupport-A 的自动同步）。两边各写各的，用户只会看见"名单自己变了"。
        let mut others: Vec<&str> = Vec::new();
        if std::fs::metadata("/data/adb/modules/TA_utl").is_ok()
            || std::fs::metadata("/data/adb/modules/.TA_utl").is_ok()
        {
            others.push("Tricky-Addon（更新目标名单）");
        }
        if std::fs::metadata("/data/adb/modules/tsupport-advance").is_ok() {
            others.push("TSupport-A");
        }
        if others.is_empty() && std::fs::metadata("/storage/emulated/0/stop-tspa-auto-target").is_ok() {
            others.push("TSupport-A 留下的停更标记（模块不在了，标记还在）");
        }
        if others.is_empty() {
            doc("名单共用", "ok", "没有别的工具在写这份名单", "");
        } else {
            doc("名单共用", "warn",
                &format!("还有别的东西在写同一份名单：{}", others.join("、")),
                "二选一：卸掉它，或在它自己的界面里关掉自动同步");
        }
        // 12. 日志
        match std::fs::metadata(&p.log) {
            Ok(md) => {
                let base = p.log.file_name().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
                doc("日志", "ok", &format!("{} {} 字节", base, md.len()), "");
            }
            Err(_) => doc("日志", "skip", "还没有日志文件（没发生过同步）", ""),
        }
    }
    let count = |st: &str| rows.iter().filter(|r| r.1 == st).count();
    let (n_ok, n_warn, n_bad, n_skip) = (count("ok"), count("warn"), count("bad"), count("skip"));
    // 与 shell 版一致：checks 计入 skip（skip 也是"检查过的一项"）
    println_ok!("checks={}", n_ok + n_warn + n_bad + n_skip);
    println_ok!("bad={}", n_bad);
    println_ok!("warn={}", n_warn);
    println_ok!("skip={}", n_skip);
    for (cat, st, desc, tip) in rows {
        println_ok!("{}\t{}\t{}\t{}", cat, st, desc, tip);
    }
}

fn is_root() -> bool {
    if let Ok(t) = std::fs::read_to_string("/proc/self/status") {
        for line in t.lines() {
            if let Some(rest) = line.strip_prefix("Uid:") {
                let uid: String = rest.trim().chars().take_while(|c| c.is_ascii_digit()).collect();
                return uid == "0";
            }
        }
    }
    std::process::Command::new("id").arg("-u").output().ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim() == "0")
        .unwrap_or(false)
}

fn pid_is_ours(pid: &str, marks: &[String]) -> bool {
    let dir = std::path::PathBuf::from(format!("/proc/{}", pid));
    if !dir.exists() { return false; }
    match std::fs::read(dir.join("cmdline")) {
        Ok(d) => {
            let text = String::from_utf8_lossy(&d).replace('\0', " ");
            marks.iter().filter(|m| !m.is_empty()).any(|m| text.contains(m.as_str()))
        }
        Err(_) => true,
    }
}

fn installed_count() -> usize {
    let run = |prog: &str, args: &[&str]| -> Option<Vec<u8>> {
        std::process::Command::new(prog).args(args).output().ok().map(|o| o.stdout)
    };
    let out = run("cmd", &["package", "list", "packages", "-3", "--user", "all"])
        .filter(|o| !o.is_empty())
        .or_else(|| run("pm", &["list", "packages", "-3"]))
        .unwrap_or_default();
    String::from_utf8_lossy(&out).lines().filter(|l| !l.trim().is_empty()).count()
}

fn find_inotify() -> Option<&'static str> {
    for name in ["inotifywait", "inotifyd"] {
        if std::process::Command::new(name).arg("--help").output().is_ok() {
            return Some(name);
        }
    }
    None
}

/// 名单去重（add_target_apps 的判重语义）：返回需要追加的新条目。
///
/// 规则（照抄 shell 的 awk）：
/// - 按**基础包名**判重：tricky 去掉 `?`/`!`；teesim 去掉 `@数字`、`uid:` 丢弃；omk 原样；
/// - 已在名单里的**完全相同的 token** 直接跳过；
/// - 基础包名已存在时跳过，**唯一例外**是 teesim 的 `pkg@用户`（独立作用域，可与裸 pkg 并存）。
pub fn new_target_entries(cur: &[String], req: &[String], id: BackendId) -> Vec<String> {
    let base_of = |t: &str| -> String {
        match id {
            BackendId::Tricky => t.trim_end_matches(['?', '!']).to_string(),
            BackendId::Teesim => {
                if t.starts_with("uid:") {
                    String::new()
                } else {
                    match t.rfind('@') {
                        Some(at) if t[at + 1..].bytes().all(|c| c.is_ascii_digit()) => t[..at].to_string(),
                        _ => t.to_string(),
                    }
                }
            }
            BackendId::Omk => t.to_string(),
        }
    };
    let mut exact: std::collections::HashSet<String> = cur.iter().cloned().collect();
    let mut bases: std::collections::HashSet<String> = cur
        .iter()
        .map(|t| base_of(t))
        .filter(|s| !s.is_empty())
        .collect();
    let mut out = Vec::new();
    for t in req {
        if t.is_empty() || exact.contains(t) {
            continue;
        }
        let b = base_of(t);
        let teesim_user = id == BackendId::Teesim
            && t.rfind('@').map(|at| t[at + 1..].bytes().all(|c| c.is_ascii_digit()) && at > 0).unwrap_or(false);
        if !b.is_empty() && bases.contains(&b) && !teesim_user {
            continue;
        }
        out.push(t.clone());
        exact.insert(t.clone());
        if !b.is_empty() {
            bases.insert(b);
        }
    }
    out
}

#[cfg(test)]
mod roster_tests {
    use super::*;

    fn v(xs: &[&str]) -> Vec<String> { xs.iter().map(|s| s.to_string()).collect() }

    #[test]
    fn tricky_dedupes_by_base_and_allows_mode_change() {
        // com.a 已在名单（裸），再加 com.a? → 跳过；com.b 已带 ?，再加 com.b → 跳过
        let out = new_target_entries(&v(&["com.a", "com.b?"]), &v(&["com.a?", "com.b", "com.c"]), BackendId::Tricky);
        assert_eq!(out, v(&["com.c"]));
    }

    #[test]
    fn teesim_allows_user_scope_beside_bare() {
        let out = new_target_entries(&v(&["com.a"]), &v(&["com.a@10", "com.a@10", "com.b@20"]), BackendId::Teesim);
        assert_eq!(out, v(&["com.a@10", "com.b@20"]));
    }

    #[test]
    fn uid_entries_never_match_by_base() {
        let out = new_target_entries(&v(&["com.a"]), &v(&["uid:10123"]), BackendId::Teesim);
        assert_eq!(out, v(&["uid:10123"]));
    }

    #[test]
    fn exact_duplicate_is_skipped() {
        let out = new_target_entries(&v(&["com.a"]), &v(&["com.a"]), BackendId::Omk);
        assert!(out.is_empty());
    }
}

/// omk.awk 的 listfile 模式：把 injector.toml 里 `scoop = [...]` 的数组内容整份换掉。
///
/// 规则（照抄 awk）：
/// - 必须定位到**行首**的裸键 `scoop` `=` `[`（`[scoop.x]` 段没有等号，不会误中）；
/// - 取 `scoop` 那一行的缩进作 `ind`，元素缩进再两格；
/// - 每个条目渲染成 `"转义后的包名",` 一行，整体包在 `[` 与 `]` 之间；
/// - 定位不到就返回 None（调用方据此报 fail，不写文件）。
pub fn omk_scoop_rewrite(text: &[u8], items: &[String]) -> Option<Vec<u8>> {
    // 行首 `scoop = [`
    let mut pos = 0usize;
    let mut ob = None;
    while pos < text.len() {
        let line_start = pos;
        let mut i = pos;
        while i < text.len() && (text[i] == b' ' || text[i] == b'\t') { i += 1; }
        if text[i..].starts_with(b"scoop") {
            let mut k = i + 5;
            while k < text.len() && (text[k] == b' ' || text[k] == b'\t') { k += 1; }
            if k < text.len() && text[k] == b'=' {
                k += 1;
                while k < text.len() && (text[k] == b' ' || text[k] == b'\t') { k += 1; }
                if k < text.len() && text[k] == b'[' { ob = Some(k); break; }
            }
        }
        match text[line_start..].iter().position(|b| *b == b'\n') {
            Some(nl) => pos = line_start + nl + 1,
            None => break,
        }
    }
    let ob = ob?;
    // 配对 ]
    let mut depth = 0i32;
    let mut instr = false;
    let mut esc = false;
    let mut cb = None;
    for i in ob..text.len() {
        let c = text[i];
        if instr {
            if esc { esc = false; } else if c == b'\\' { esc = true; } else if c == b'"' { instr = false; }
            continue;
        }
        if c == b'"' { instr = true; continue; }
        if c == b'{' || c == b'[' { depth += 1; }
        else if c == b'}' || c == b']' { depth -= 1; if depth == 0 { cb = Some(i); break; } }
    }
    let cb = cb?;
    // scoop 行的缩进
    let mut ls = ob;
    while ls > 0 && text[ls - 1] != b'\n' { ls -= 1; }
    let mut ind = String::new();
    let mut i = ls;
    while i < ob {
        let c = text[i];
        if c != b' ' && c != b'\t' { break; }
        ind.push(c as char);
        i += 1;
    }
    let itemind = format!("{}  ", ind);
    let mut body = String::from("\n");
    for it in items {
        let esc = it.replace('\\', "\\\\").replace('"', "\\\"");
        body.push_str(&format!("{}\"{}\",\n", itemind, esc));
    }
    body.push_str(&ind);
    let mut out: Vec<u8> = Vec::with_capacity(text.len() + body.len());
    out.extend_from_slice(&text[..=ob]);
    out.extend_from_slice(body.as_bytes());
    out.extend_from_slice(&text[cb..]);
    Some(out)
}

#[cfg(test)]
mod omk_scoop_tests {
    use super::*;

    fn items(xs: &[&str]) -> Vec<String> { xs.iter().map(|s| s.to_string()).collect() }

    #[test]
    fn rewrites_array_with_indent() {
        let src = "[main]\nlog_level = \"info\"\n\nscoop = [\n  \"old\",\n]\n\n[scoop.com.z]\n";
        let out = omk_scoop_rewrite(src.as_bytes(), &items(&["com.a", "com.b"])).unwrap();
        let got = String::from_utf8(out).unwrap();
        assert_eq!(got, "[main]\nlog_level = \"info\"\n\nscoop = [\n  \"com.a\",\n  \"com.b\",\n]\n\n[scoop.com.z]\n");
    }

    #[test]
    fn escapes_quotes_and_backslashes() {
        let src = "scoop = [\"x\"]\n";
        let out = omk_scoop_rewrite(src.as_bytes(), &items(&["a\"b", "c\\d"])).unwrap();
        let got = String::from_utf8(out).unwrap();
        assert!(got.contains("\"a\\\"b\","));
        assert!(got.contains("\"c\\\\d\","));
    }

    #[test]
    fn missing_key_returns_none() {
        assert!(omk_scoop_rewrite(b"[scoop.com.z]\ndeny = true\n", &items(&["a"])).is_none());
        assert!(omk_scoop_rewrite(b"scoop = [\n", &items(&["a"])).is_none());
    }
}

/// teesim.awk 的 listfile 模式：把 config.json 里 `profiles.default.apps` 整份换成给定列表。
///
/// 与 omk 版的差别（照抄 awk）：条目**不做转义**；数组统一重排成多行，
/// 元素缩进 = `apps` 所在行的缩进 + 两格；最后一项不带逗号。
pub fn teesim_apps_rewrite(text: &[u8], items: &[String]) -> Option<Vec<u8>> {
    let pp = find_from(text, 0, b"\"profiles\"")?;
    let dp = find_from(text, pp, b"\"default\"")?;
    let ob = find_from(text, dp + 9, b"{")?;
    let cb = match_close(text, ob)?;
    let ap = find_from(text, ob, b"\"apps\"")?;
    if ap > cb { return None; }
    let ab = find_from(text, ap + 6, b"[")?;
    if ab > cb { return None; }
    let ae = match_close(text, ab)?;
    if ae > cb { return None; }
    // apps 键所在行的缩进
    let mut ls = ap;
    while ls > 0 && text[ls - 1] != b'\n' { ls -= 1; }
    let mut ind = String::new();
    let mut i = ls;
    while i < ap {
        let c = text[i];
        if c != b' ' && c != b'\t' { break; }
        ind.push(c as char);
        i += 1;
    }
    let mut body = String::new();
    for (idx, it) in items.iter().enumerate() {
        body.push_str(&format!("{}  \"{}\"", ind, it));
        if idx + 1 < items.len() { body.push(','); }
        body.push('\n');
    }
    let mut out: Vec<u8> = Vec::with_capacity(text.len() + body.len() + 8);
    out.extend_from_slice(&text[..ab]);
    out.extend_from_slice(b"[\n");
    out.extend_from_slice(body.as_bytes());
    out.extend_from_slice(ind.as_bytes());
    out.extend_from_slice(b"]");
    out.extend_from_slice(&text[ae + 1..]);
    Some(out)
}

#[cfg(test)]
mod teesim_apps_tests {
    use super::*;

    fn items(xs: &[&str]) -> Vec<String> { xs.iter().map(|s| s.to_string()).collect() }

    #[test]
    fn rewrites_apps_array_multiline() {
        let src = "{\n    \"profiles\": {\n        \"default\": {\n            \"apps\": [\"old\"]\n        }\n    }\n}\n";
        let out = teesim_apps_rewrite(src.as_bytes(), &items(&["com.a", "com.b"])).unwrap();
        let got = String::from_utf8(out).unwrap();
        assert!(got.contains("\"apps\": [\n              \"com.a\",\n              \"com.b\"\n            ]"), "{}", got);
    }

    #[test]
    fn empty_list_keeps_brackets() {
        let src = "{\"profiles\":{\"default\":{\"apps\":[\"x\"]}}}";
        let out = teesim_apps_rewrite(src.as_bytes(), &[]).unwrap();
        assert_eq!(String::from_utf8(out).unwrap(), "{\"profiles\":{\"default\":{\"apps\":[\n]}}}");
    }

    #[test]
    fn missing_default_returns_none() {
        assert!(teesim_apps_rewrite(b"{\"profiles\":{\"work\":{\"apps\":[]}}}", &items(&["a"])).is_none());
        assert!(teesim_apps_rewrite(b"{}", &items(&["a"])).is_none());
    }
}

/// is_target_entry（applist.sh:81）：按后端校验一个目标条目是否合法。
fn is_target_entry(t: &str, id: BackendId) -> bool {
    match id {
        BackendId::Tricky => {
            let base = t.trim_end_matches(['?', '!']);
            valid_pkg(base)
        }
        BackendId::Teesim => {
            if let Some(rest) = t.strip_prefix("uid:") {
                return !rest.is_empty() && rest.bytes().all(|c| c.is_ascii_digit());
            }
            match t.split_once('@') {
                Some((pkg, user)) => {
                    !user.is_empty() && user.bytes().all(|c| c.is_ascii_digit()) && valid_pkg(pkg)
                }
                None => valid_pkg(t),
            }
        }
        BackendId::Omk => valid_pkg(t),
    }
}

/// 目标文件的当前条目（按后端解析）。
fn cur_target_tokens(b: &Backend) -> Vec<String> {
    if !b.target.is_file() {
        return Vec::new();
    }
    let data = std::fs::read(&b.target).unwrap_or_default();
    match b.id {
        BackendId::Tricky => tricky_tokens(&String::from_utf8_lossy(&data)),
        BackendId::Teesim => teesim_apps(&data).unwrap_or_default(),
        BackendId::Omk => omk_scoop(&data).unwrap_or_default(),
    }
}

/// 把一批基础包名并入 ever 名单（`.kl_ever`，600）。
fn ever_add_list(dir: &std::path::Path, bases: &[String]) {
    if bases.is_empty() { return; }
    let path = dir.join(".kl_ever");
    let mut all: Vec<String> = std::fs::read_to_string(&path)
        .map(|t| t.lines().filter(|l| !l.trim().is_empty()).map(|s| s.to_string()).collect())
        .unwrap_or_default();
    all.extend(bases.iter().cloned());
    all.sort();
    all.dedup();
    let text = all.join("\n") + "\n";
    let tmp = dir.join(format!(".kl_ever.new.{}", std::process::id()));
    if std::fs::write(&tmp, text.as_bytes()).is_ok() && std::fs::rename(&tmp, &path).is_ok() {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
        }
    } else {
        let _ = std::fs::remove_file(&tmp);
    }
}

/// add_target_apps（backend.sh:152）：0=加入了 1=本来就在 2=失败。
pub fn add_target_apps(b: &Backend, req: &[String]) -> i32 {
    if !b.target.is_file() { return 2; }
    let cur = cur_target_tokens(b);
    let new = new_target_entries(&cur, req, b.id);
    if new.is_empty() { return 1; }
    let mut combo: Vec<String> = cur.clone();
    combo.extend(new.iter().cloned());
    combo.sort();
    combo.dedup();
    let old = std::fs::read(&b.target).unwrap_or_default();
    let written: Option<(Vec<u8>, u32)> = match b.id {
        BackendId::Tricky => {
            let mut out = old.clone();
            if !out.is_empty() && out.last() != Some(&b'\n') { out.push(b'\n'); }
            for it in &new {
                out.extend_from_slice(it.as_bytes());
                out.push(b'\n');
            }
            Some((out, 0o644))
        }
        BackendId::Teesim => teesim_apps_rewrite(&old, &combo).map(|v| (v, 0o600)),
        BackendId::Omk => omk_scoop_rewrite(&old, &combo).map(|v| (v, 0)),
    };
    let Some((bytes, mode)) = written else { return 2; };
    if bytes == old {
        // 内容没变：omk 的语义是返回 1（不写、不备份）
        return 1;
    }
    // omk 需要保留原文件的属主/权限/SELinux 上下文，并先备份
    if b.id == BackendId::Omk {
        let bak = b.dir.join("injector.toml.bak");
        let _ = std::fs::copy(&b.target, &bak);
    }
    let tmp = b.dir.join(format!(".kl_restore.{}", std::process::id()));
    let ok = std::fs::write(&tmp, &bytes).is_ok() && std::fs::rename(&tmp, &b.target).is_ok();
    if !ok {
        let _ = std::fs::remove_file(&tmp);
        return 2;
    }
    #[cfg(unix)]
    if mode != 0 {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&b.target, std::fs::Permissions::from_mode(mode));
    }
    let bases: Vec<String> = new.iter().map(|t| entry_base(t, b.id)).filter(|s| !s.is_empty()).collect();
    ever_add_list(&b.dir, &bases);
    0
}

/// cmd_restore_app：把一个应用加回目标名单（含 ever 与描述刷新）。
pub fn restore_app(pkg: &str) {
    let root = Root::from_env();
    let p = Paths::new(&root);
    if backends_conflict(&p) {
        eprintln!("{}", CONFLICT_MSG);
        std::process::exit(1);
    }
    let b = backend::detect(&p);
    if !is_target_entry(pkg, b.id) {
        eprintln!("不是合法的目标条目：{}", pkg);
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
    let rc = add_target_apps(&b, &[pkg.to_string()]);
    crate::lock::release(&lockdir);
    match rc {
        0 => {
            // 顺手刷新模块描述里的条数（管理器里不用等下一轮同步）
            let n = cur_target_tokens(&b).len();
            if n > 0 {
                let bname = match b.id {
                    BackendId::Teesim => "TEE Simulator",
                    BackendId::Omk => "OhMyKeymint",
                    BackendId::Tricky => "Tricky Store",
                };
                let hm = std::process::Command::new("date").arg("+%H:%M").output().ok()
                    .map(|o| String::from_utf8_lossy(&o.stdout).trim_end_matches('\n').to_string())
                    .unwrap_or_default();
                set_module_desc(&p.module_prop, &format!("✅ [{} | 应用: {} | 更新: {}]", bname, n, hm));
            }
            log_line(&p, &format!("🧩 WebUI 把 {} 加回目标名单", pkg));
            println_ok!("restored=1");
        }
        1 => println_ok!("restored=0"),
        _ => {
            eprintln!("写入失败：{}", b.target.display());
            std::process::exit(1);
        }
    }
}

/// 只改 module.prop 里的 description 一行，其余原样。
fn set_module_desc(prop: &std::path::Path, desc: &str) {
    let Ok(text) = std::fs::read_to_string(prop) else { return };
    let mut out = String::new();
    let mut done = false;
    for line in text.lines() {
        if line.starts_with("description=") {
            out.push_str(&format!("description={}\n", desc));
            done = true;
        } else {
            out.push_str(line);
            out.push('\n');
        }
    }
    if !done {
        out.push_str(&format!("description={}\n", desc));
    }
    // 改名会把 tmp 的权限带过去（继承调用者的 umask），而 module.prop 的原 mode 是安装脚本定的。
    // 所以**改名之前**把原 mode 记下来，改名之后再补回去 —— 与 lib/backend.sh 的同名函数同一口径
    // （生产机上实测漂过：整棵模块目录里唯一世界可写的文件就是 module.prop）。
    #[cfg(unix)]
    let keep_mode = std::fs::metadata(prop).ok().map(|md| {
        use std::os::unix::fs::PermissionsExt;
        md.permissions().mode() & 0o7777
    });
    #[cfg(not(unix))]
    let keep_mode: Option<u32> = None;
    let tmp = match prop.file_name() {
        Some(n) => prop.with_file_name(format!("{}.tmp.{}", n.to_string_lossy(), std::process::id())),
        None => return,
    };
    if std::fs::write(&tmp, out.as_bytes()).is_err() {
        let _ = std::fs::remove_file(&tmp);
        return;
    }
    if std::fs::rename(&tmp, prop).is_err() {
        let _ = std::fs::remove_file(&tmp);
        return;
    }
    #[cfg(unix)]
    if let Some(m) = keep_mode {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(prop, std::fs::Permissions::from_mode(m));
    }
}

/// cmd_restore_apps：逗号分隔的批量加入（全部校验后只写一次）。
pub fn restore_apps(raw: &str) {
    let root = Root::from_env();
    let p = Paths::new(&root);
    if backends_conflict(&p) {
        eprintln!("{}", CONFLICT_MSG);
        std::process::exit(1);
    }
    if raw.is_empty() {
        eprintln!("参数为空");
        std::process::exit(1);
    }
    let b = backend::detect(&p);
    let mut req: Vec<String> = Vec::new();
    for pkg in raw.split(',') {
        if pkg.is_empty() { continue; }
        if !is_target_entry(pkg, b.id) {
            eprintln!("不是合法的目标条目：{}", pkg);
            std::process::exit(1);
        }
        req.push(pkg.to_string());
    }
    if req.is_empty() {
        eprintln!("没有有效包名");
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
    let rc = add_target_apps(&b, &req);
    crate::lock::release(&lockdir);
    match rc {
        0 => {
            let n = cur_target_tokens(&b).len();
            if n > 0 {
                refresh_desc(&p, &b, n);
            }
            log_line(&p, &format!("🧩 WebUI 批量加入目标名单（{} 个包名）", req.len()));
            println_ok!("restored=1");
        }
        1 => println_ok!("restored=0"),
        _ => {
            eprintln!("写入失败：{}", b.target.display());
            std::process::exit(1);
        }
    }
}

/// 刷新模块描述里的条数（restore-app / restore-apps 共用）。
pub fn refresh_desc(p: &Paths, b: &Backend, n: usize) {
    let bname = match b.id {
        BackendId::Teesim => "TEE Simulator",
        BackendId::Omk => "OhMyKeymint",
        BackendId::Tricky => "Tricky Store",
    };
    let hm = std::process::Command::new("date").arg("+%H:%M").output().ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim_end_matches('\n').to_string())
        .unwrap_or_default();
    set_module_desc(&p.module_prop, &format!("✅ [{} | 应用: {} | 更新: {}]", bname, n, hm));
}

/// remove_target_apps（backend.sh:248）：0=移出了 1=本来都不在 2=失败 3=会清空名单。
/// 返回 (rc, 实际移出的条目（按原顺序去重）)。
pub fn remove_target_apps(b: &Backend, req: &[String]) -> (i32, Vec<String>) {
    if !b.target.is_file() { return (2, Vec::new()); }
    let cur = cur_target_tokens(b);
    let mut req_sorted: Vec<String> = req.to_vec();
    req_sorted.sort();
    req_sorted.dedup();
    let base_of = |t: &str| entry_base(t, b.id);
    let req_exact: std::collections::HashSet<&String> = req_sorted.iter().collect();
    let req_base: std::collections::HashSet<String> = req_sorted
        .iter()
        .map(|t| base_of(t))
        .filter(|s| !s.is_empty())
        .collect();
    let mut removed: Vec<String> = Vec::new();
    let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
    let mut keep: Vec<String> = Vec::new();
    for tok in &cur {
        let base = base_of(tok);
        let hit = req_exact.contains(tok)
            || (b.id == BackendId::Tricky && !base.is_empty() && req_base.contains(&base));
        if hit {
            if seen.insert(tok.clone()) {
                removed.push(tok.clone());
            }
        } else {
            keep.push(tok.clone());
        }
    }
    if removed.is_empty() { return (1, Vec::new()); }
    if keep.is_empty() { return (3, removed); }
    let old = std::fs::read(&b.target).unwrap_or_default();
    let written: Option<(Vec<u8>, u32)> = match b.id {
        BackendId::Omk => omk_scoop_rewrite(&old, &keep).map(|v| (v, 0)),
        BackendId::Teesim => teesim_apps_rewrite(&old, &keep).map(|v| (v, 0o600)),
        BackendId::Tricky => {
            // 逐行：注释与空行原样保留，按基础包名删；行内注释不参与比较
            let mut out: Vec<u8> = Vec::new();
            for raw in old.split_inclusive(|c| *c == b'\n') {
                let text = String::from_utf8_lossy(raw).into_owned();
                let line = text.trim_end_matches('\n');
                let stripped = line.strip_suffix('\r').unwrap_or(line);
                let body = match stripped.find('#') { Some(h) => &stripped[..h], None => stripped };
                let tok = body.trim_matches([' ', '\t']);
                let base = tok.trim_end_matches(['?', '!']).trim_end_matches([' ', '\t']);
                let hit = req_exact.contains(&tok.to_string())
                    || (!base.is_empty() && req_base.contains(base));
                if !hit {
                    out.extend_from_slice(raw);
                }
            }
            Some((out, 0o644))
        }
    };
    let Some((bytes, mode)) = written else { return (2, removed); };
    if b.id == BackendId::Omk && bytes == old {
        // 请求里明明有可移出的条目、writer 却说内容一致：按失败处理
        return (2, removed);
    }
    if b.id == BackendId::Omk {
        let bak = b.dir.join("injector.toml.bak");
        let _ = std::fs::copy(&b.target, &bak);
    }
    let tmp = b.dir.join(format!(".kl_remove.{}", std::process::id()));
    let ok = std::fs::write(&tmp, &bytes).is_ok() && std::fs::rename(&tmp, &b.target).is_ok();
    if !ok {
        let _ = std::fs::remove_file(&tmp);
        return (2, removed);
    }
    #[cfg(unix)]
    if mode != 0 {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&b.target, std::fs::Permissions::from_mode(mode));
    }
    // 移出前把当前名单并入 ever：手工加进文件、还没同步过的包也被记住
    let cur_bases: Vec<String> = cur.iter().map(|t| entry_base(t, b.id)).filter(|s| !s.is_empty()).collect();
    ever_add_list(&b.dir, &cur_bases);
    (0, removed)
}

/// cmd_remove_apps：逗号分隔的批量移出（名单至少保留一条）。
pub fn remove_apps(raw: &str) {
    let root = Root::from_env();
    let p = Paths::new(&root);
    if backends_conflict(&p) {
        eprintln!("{}", CONFLICT_MSG);
        std::process::exit(1);
    }
    if raw.is_empty() {
        eprintln!("参数为空");
        std::process::exit(1);
    }
    let b = backend::detect(&p);
    let mut req: Vec<String> = Vec::new();
    for pkg in raw.split(',') {
        if pkg.is_empty() { continue; }
        if !is_target_entry(pkg, b.id) {
            eprintln!("不是合法的目标条目：{}", pkg);
            std::process::exit(1);
        }
        req.push(pkg.to_string());
    }
    if req.is_empty() {
        eprintln!("没有有效包名");
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
    let (rc, removed) = remove_target_apps(&b, &req);
    let after = cur_target_tokens(&b).len();
    crate::lock::release(&lockdir);
    match rc {
        0 => {
            refresh_desc(&p, &b, after);
            let list = removed.join(",");
            log_line(&p, &format!("🧩 WebUI 从目标名单移出 {} 个应用", removed.len()));
            println_ok!("removed={}", removed.len());
            println_ok!("removed_list={}", list);
        }
        1 => {
            println_ok!("removed=0");
            println_ok!("removed_list=");
        }
        3 => {
            eprintln!("不能移出全部应用：目标名单至少保留一个");
            std::process::exit(1);
        }
        _ => {
            eprintln!("写入失败：{}", b.target.display());
            std::process::exit(1);
        }
    }
}

/// teesim-save 的字段校验（webui.sh 里那几个 valid_* 的等价）。

/// valid_text：不含换行/制表/控制字符，且长度不超过 max。
pub fn valid_text(v: &str, max: usize) -> bool {
    if v.contains('\n') || v.contains('\t') || v.contains('\r') {
        return false;
    }
    if v.chars().count() > max {
        return false;
    }
    // [[:cntrl:]]：ASCII 控制字符（含 0x00-0x1F、0x7F）；换行/制表上面已挡
    !v.chars().any(|c| c.is_control())
}

/// valid_bool：只认 true / false（小写）。
pub fn valid_bool(v: &str) -> bool {
    v == "true" || v == "false"
}

/// valid_keybox_name：字母数字与 . _ -，必须以 .xml 结尾，不许带路径。
pub fn valid_keybox_name(v: &str) -> bool {
    if v.is_empty() || v.contains('/') {
        return false;
    }
    if !v.bytes().all(|c| c.is_ascii_alphanumeric() || matches!(c, b'.' | b'_' | b'-')) {
        return false;
    }
    v.ends_with(".xml")
}

/// valid_os_version：空 / harvested / system_property 放行，否则 1–3 段十进制数字。
pub fn valid_os_version(v: &str) -> bool {
    if v.is_empty() || v == "harvested" || v == "system_property" {
        return true;
    }
    let segs: Vec<&str> = v.split('.').collect();
    (1..=3).contains(&segs.len())
        && segs.iter().all(|s| !s.is_empty() && s.bytes().all(|c| c.is_ascii_digit()))
}

#[cfg(test)]
mod teesim_valid_tests {
    use super::*;

    #[test]
    fn text_rejects_control_and_overlong() {
        assert!(valid_text("XQ-DQ72", 256));
        assert!(!valid_text("a\tb", 256));
        assert!(!valid_text("a\nb", 256));
        assert!(!valid_text(&"x".repeat(257), 256));
    }

    #[test]
    fn bool_is_strict_lowercase() {
        assert!(valid_bool("true"));
        assert!(valid_bool("false"));
        assert!(!valid_bool("TRUE"));
        assert!(!valid_bool("1"));
    }

    #[test]
    fn keybox_name_rules() {
        assert!(valid_keybox_name("keybox.xml"));
        assert!(valid_keybox_name("my-kb_2.xml"));
        assert!(!valid_keybox_name("../keybox.xml"));
        assert!(!valid_keybox_name("keybox.txt"));
        assert!(!valid_keybox_name(""));
    }

    #[test]
    fn os_version_rules() {
        assert!(valid_os_version(""));
        assert!(valid_os_version("harvested"));
        assert!(valid_os_version("15"));
        assert!(valid_os_version("15.1"));
        assert!(valid_os_version("15.1.2"));
        assert!(!valid_os_version("15.1.2.3"));
        assert!(!valid_os_version("15..1"));
        assert!(!valid_os_version("v15"));
    }
}

/// valid_patch 的三种结果（harvested 要单独给文案，不能混进"不合法"）。
#[derive(Debug, PartialEq, Eq)]
pub enum PatchCheck {
    Ok,
    Harvested,
    Invalid,
}

/// valid_patch（webui.sh:228）：TEESim 的补丁值语法。
///
/// - `harvested` 上游根本没实现（写进去等于省略该标签），明确拒绝并提示留空；
/// - 关键字 `""` / `today` / `no`（报告 0，与 Tricky 相反）/ `system_property` 放行；
/// - 裸 `YYYY`/`MM`/`DD` 会被替换成"今天"后过不了上游判据 → 拒绝；
/// - 4/6/8 位纯数字，或 `YYYY-MM[-DD]`（含字面 `YYYY`/`MM`/`DD` 占位）。
pub fn valid_patch(v: &str) -> PatchCheck {
    let low = v.to_ascii_lowercase();
    if low == "harvested" {
        return PatchCheck::Harvested;
    }
    if matches!(low.as_str(), "" | "today" | "no" | "system_property") {
        return PatchCheck::Ok;
    }
    if matches!(v, "YYYY" | "MM" | "DD" | "yyyy" | "mm" | "dd") {
        return PatchCheck::Invalid;
    }
    let digits = |s: &str| s.bytes().all(|c| c.is_ascii_digit());
    if matches!(v.len(), 4 | 6 | 8) && digits(v) {
        return PatchCheck::Ok;
    }
    let parts: Vec<&str> = v.split('-').collect();
    let year_ok = |y: &str| y == "YYYY" || (y.len() == 4 && digits(y));
    let month_ok = |m: &str| {
        m == "MM" || (m.len() == 2 && digits(m) && (1..=12).contains(&m.parse::<u32>().unwrap_or(0)))
    };
    let day_ok = |d: &str| {
        d == "DD" || (d.len() == 2 && digits(d) && (1..=31).contains(&d.parse::<u32>().unwrap_or(0)))
    };
    let ok = match parts.len() {
        2 => year_ok(parts[0]) && month_ok(parts[1]),
        3 => year_ok(parts[0]) && month_ok(parts[1]) && day_ok(parts[2]),
        _ => false,
    };
    if ok { PatchCheck::Ok } else { PatchCheck::Invalid }
}

#[cfg(test)]
mod valid_patch_tests {
    use super::*;

    #[test]
    fn keywords_pass_and_harvested_is_special() {
        for v in ["", "today", "no", "system_property", "TODAY", "No"] {
            assert_eq!(valid_patch(v), PatchCheck::Ok, "{}", v);
        }
        assert_eq!(valid_patch("harvested"), PatchCheck::Harvested);
        assert_eq!(valid_patch("HARVESTED"), PatchCheck::Harvested);
    }

    #[test]
    fn bare_placeholders_are_rejected() {
        for v in ["YYYY", "MM", "DD", "yyyy", "mm", "dd"] {
            assert_eq!(valid_patch(v), PatchCheck::Invalid, "{}", v);
        }
    }

    #[test]
    fn numeric_and_dated_forms_pass() {
        for v in ["2026", "202610", "20261005", "2026-10", "2026-10-05", "YYYY-MM", "YYYY-MM-DD"] {
            assert_eq!(valid_patch(v), PatchCheck::Ok, "{}", v);
        }
        for v in ["2026-13", "2026-00", "2026-10-32", "2026-1", "26-10", "202x10"] {
            assert_eq!(valid_patch(v), PatchCheck::Invalid, "{}", v);
        }
    }
}

/// JSON 字符串字面量（转义规则与 json_flat 一致）。
fn jlit(s: &str) -> String {
    crate::json_flat::render(s)
}

/// 在对象文本里求某个值的区间（用于 replace_scalar）：跳过空白后取字符串/嵌套/裸值。
fn value_span(obj: &[u8], at: usize) -> Option<(usize, usize)> {
    let mut i = at;
    while i < obj.len() && matches!(obj[i], b' ' | b'\t' | b'\r' | b'\n') { i += 1; }
    if i >= obj.len() { return None; }
    if obj[i] == b'"' {
        let mut j = i + 1;
        let mut esc = false;
        while j < obj.len() {
            if esc { esc = false; } else if obj[j] == b'\\' { esc = true; } else if obj[j] == b'"' { return Some((i, j)); }
            j += 1;
        }
        return None;
    }
    if obj[i] == b'{' || obj[i] == b'[' {
        let e = match_close(obj, i)?;
        return Some((i, e));
    }
    let mut e = i;
    while e < obj.len() && !matches!(obj[e], b',' | b'}' | b'\n') { e += 1; }
    while e > i && matches!(obj[e - 1], b' ' | b'\t' | b'\r') { e -= 1; }
    Some((i, e.saturating_sub(1)))
}

/// replace_scalar：命中返回 (新对象, 是否真的变了)；不命中返回 None。
fn replace_scalar(obj: &str, key: &str, lit: &str) -> Option<(String, bool)> {
    let bytes = obj.as_bytes();
    let needle = format!("\"{}\"", key);
    let p = find_from(bytes, 0, needle.as_bytes())?;
    let mut i = p + needle.len();
    while i < bytes.len() && matches!(bytes[i], b' ' | b'\t' | b'\r' | b'\n') { i += 1; }
    if bytes.get(i) != Some(&b':') { return None; }
    let (ks, ke) = value_span(bytes, i + 1)?;
    let changed = &obj[ks..=ke] != lit;
    Some((format!("{}{}{}", &obj[..ks], lit, &obj[ke + 1..]), changed))
}

/// insert_member：在对象末尾 `}` 之前插入 `"key": lit`。
fn insert_member(obj: &str, key: &str, lit: &str) -> String {
    let bytes = obj.as_bytes();
    let mut cend = bytes.len();
    while cend > 1 && bytes[cend - 1] != b'}' { cend -= 1; }
    // 收尾缩进：`}` 前连续空格/制表符；前一个字符不是换行时退化成两空格
    let mut i = cend - 1;
    let mut closeind = String::new();
    while i >= 1 && matches!(bytes[i - 1], b' ' | b'\t') { closeind.insert(0, bytes[i - 1] as char); i -= 1; }
    if i >= 1 && bytes[i - 1] != b'\n' { closeind = "  ".to_string(); }
    let ind = format!("{}  ", closeind);
    let mut before = obj[..cend - 1].to_string();
    while before.ends_with([' ', '\t', '\r', '\n']) { before.pop(); }
    if !(before.ends_with('{') || before.ends_with(',')) { before.push(','); }
    format!("{}\n{}{}: {}\n{}}}{}", before, ind, format!("\"{}\"", key), lit, closeind, &obj[cend..])
}

/// 定位 `profiles.<name>` 的对象区间：名字必须是键（后面是 `:` 再是 `{`），不能是字符串值。
fn find_profile_object(text: &[u8], name: &str) -> Option<(usize, usize)> {
    let pp = find_from(text, 0, b"\"profiles\"")?;
    let pkey = format!("\"{}\"", name);
    let mut from = pp + 10;
    loop {
        let q = find_from(text, from, pkey.as_bytes())?;
        let mut m = q + pkey.len();
        while m < text.len() && matches!(text[m], b' ' | b'\t' | b'\r' | b'\n') { m += 1; }
        if text.get(m) == Some(&b':') {
            let mut o = m + 1;
            while o < text.len() && matches!(text[o], b' ' | b'\t' | b'\r' | b'\n') { o += 1; }
            if text.get(o) == Some(&b'{') {
                let e = match_close(text, o)?;
                return Some((o, e));
            }
        }
        from = q + pkey.len();
    }
}

/// cmd_teesim_save：写 profiles.<profile> 的字段（patchLevel 是嵌套对象）。
pub fn teesim_save(payload: &str) {
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
    let mut fields = match crate::payload::parse(payload) {
        Ok(v) => v,
        Err(msg) => { eprintln!("{}", msg); std::process::exit(1); }
    };
    let mut profile = "default".to_string();
    if let Some(pos) = fields.iter().position(|(k, _)| k == "profile") {
        let (_, v) = fields.remove(pos);
        if !v.is_empty() { profile = v; }
    }
    if !profile.bytes().all(|c| c.is_ascii_alphanumeric() || matches!(c, b'.' | b'_' | b'-')) {
        eprintln!("profile 名字不合法：{}", profile);
        std::process::exit(1);
    }
    if fields.is_empty() {
        eprintln!("没有可写字段");
        std::process::exit(1);
    }
    for (k, v) in &fields {
        match k.as_str() {
            "mode" => {
                if v != "patch" && v != "generation" {
                    eprintln!("模式只能是 patch / generation");
                    std::process::exit(1);
                }
            }
            "keybox" => {
                if !valid_keybox_name(v) || !p.teesim_dir.join(v).is_file() {
                    eprintln!("keybox 文件不存在：{}", v);
                    std::process::exit(1);
                }
            }
            "patch_system" | "patch_vendor" | "patch_boot" => match valid_patch(v) {
                PatchCheck::Ok => {}
                PatchCheck::Harvested => {
                    // 与 shell 版一致：valid_patch 先给专门提示，调用方接着再打一条通用拒绝
                    eprintln!("harvested 这个写法上游守护进程并没有实现（写进去等于省略该标签）；要用采集值请留空");
                    eprintln!("补丁值不合法：{} = {}（留空=用采集值 / today / no=报 0 / system_property / YYYY-MM / YYYY-MM-DD / YYYYMM / YYYYMMDD；关键字不分大小写，日期里的 YYYY、MM、DD 必须大写且不能单独出现）", k, v);
                    std::process::exit(1);
                }
                PatchCheck::Invalid => {
                    eprintln!("补丁值不合法：{} = {}（留空=用采集值 / today / no=报 0 / system_property / YYYY-MM / YYYY-MM-DD / YYYYMM / YYYYMMDD；关键字不分大小写，日期里的 YYYY、MM、DD 必须大写且不能单独出现）", k, v);
                    std::process::exit(1);
                }
            },
            "os_version" => {
                if !valid_os_version(v) {
                    eprintln!("OS 版本不合法");
                    std::process::exit(1);
                }
            }
            "auto_include" => {
                if !valid_bool(v) {
                    eprintln!("auto_include 只能是 true/false");
                    std::process::exit(1);
                }
            }
            "brand" | "device" | "product" | "manufacturer" | "model" | "serial" | "imei" | "meid" | "imei2" => {
                if !valid_text(v, 256) {
                    eprintln!("字段不合法：{}", k);
                    std::process::exit(1);
                }
            }
            _ => {
                eprintln!("未知字段：{}", k);
                std::process::exit(1);
            }
        }
    }
    let n = fields.len();
    let marks: Vec<String> = vec![std::env::var("KL_LOCK_MARK").unwrap_or_else(|_| {
        p.module_prop.parent().and_then(|m| m.file_name()).map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| "keylens".to_string())
    })];
    let lockdir = b.dir.join(".kl_lock");
    if !crate::lock::acquire(&lockdir, 6, &marks) {
        eprintln!("守护进程正在写入，请几秒后再试");
        std::process::exit(1);
    }
    let old = std::fs::read_to_string(&p.teesim_config).unwrap_or_default();
    let found = find_profile_object(old.as_bytes(), &profile);
    let Some((db, dc)) = found else {
        crate::lock::release(&lockdir);
        eprintln!("配置定位失败：{}", p.teesim_config.display());
        std::process::exit(1);
    };
    let mut dobj = old[db..=dc].to_string();
    let mut changed = false;
    // patchLevel
    let ps = fields.iter().find(|(k, _)| k == "patch_system").map(|(_, v)| v.clone());
    let pv = fields.iter().find(|(k, _)| k == "patch_vendor").map(|(_, v)| v.clone());
    let pb = fields.iter().find(|(k, _)| k == "patch_boot").map(|(_, v)| v.clone());
    if ps.is_some() || pv.is_some() || pb.is_some() {
        let lit_for = |s: &Option<String>| jlit(s.as_deref().unwrap_or(""));
        let existing = {
            let bytes = dobj.as_bytes();
            let needle = b"\"patchLevel\"";
            find_from(bytes, 0, needle).and_then(|p| {
                let mut i = p + needle.len();
                while i < bytes.len() && matches!(bytes[i], b' ' | b'\t' | b'\r' | b'\n') { i += 1; }
                if bytes.get(i) != Some(&b':') { return None; }
                i += 1;
                while i < bytes.len() && matches!(bytes[i], b' ' | b'\t' | b'\r' | b'\n') { i += 1; }
                if bytes.get(i) != Some(&b'{') { return None; }
                let e = match_close(bytes, i)?;
                Some((i, e))
            })
        };
        if let Some((ob, oe)) = existing {
            let mut pobj = dobj[ob..=oe].to_string();
            for (key, val) in [("system", &ps), ("vendor", &pv), ("boot", &pb)] {
                let Some(v) = val else { continue };
                let lit = jlit(v);
                match replace_scalar(&pobj, key, &lit) {
                    Some((newobj, ch)) => { pobj = newobj; if ch { changed = true; } }
                    None => { pobj = insert_member(&pobj, key, &lit); changed = true; }
                }
            }
            dobj = format!("{}{}{}", &dobj[..ob], pobj, &dobj[oe + 1..]);
        } else {
            let mut lit = String::from("{");
            let mut sep = "";
            for (key, val) in [("system", &ps), ("vendor", &pv), ("boot", &pb)] {
                let Some(v) = val else { continue };
                lit.push_str(&format!("{}\"{}\": {}", sep, key, jlit(v)));
                sep = ", ";
            }
            lit.push('}');
            let _ = lit_for(&None);
            dobj = insert_member(&dobj, "patchLevel", &lit);
            changed = true;
        }
    }
    // 顶层字段
    for (k, v) in &fields {
        if matches!(k.as_str(), "patch_system" | "patch_vendor" | "patch_boot") { continue; }
        let (jk, lit) = if k == "os_version" {
            ("osVersion".to_string(), jlit(v))
        } else if k == "auto_include" {
            ("autoIncludeNewApps".to_string(), if v == "true" { "true".to_string() } else { "false".to_string() })
        } else {
            (k.clone(), jlit(v))
        };
        match replace_scalar(&dobj, &jk, &lit) {
            Some((newobj, ch)) => { dobj = newobj; if ch { changed = true; } }
            None => { dobj = insert_member(&dobj, &jk, &lit); changed = true; }
        }
    }
    let new_text = format!("{}{}{}", &old[..db], dobj, &old[dc + 1..]);
    let mut saved = 0;
    if changed && new_text != old {
        let bak = b.dir.join("config.json.bak");
        let _ = std::fs::copy(&p.teesim_config, &bak);
        let tmp = b.dir.join(format!(".config.json.keylens.{}", std::process::id()));
        let ok = std::fs::write(&tmp, new_text.as_bytes()).is_ok()
            && std::fs::rename(&tmp, &p.teesim_config).is_ok();
        if !ok {
            let _ = std::fs::remove_file(&tmp);
            crate::lock::release(&lockdir);
            eprintln!("写入失败：{}", p.teesim_config.display());
            std::process::exit(1);
        }
        saved = 1;
    }
    crate::lock::release(&lockdir);
    if saved == 1 {
        log_line(&p, &format!("🧩 WebUI 更新 TEE Simulator 配置（profile={}，{} 项）", profile, n));
    }
    println_ok!("saved={}", saved);
    println_ok!("fields={}", n);
    println_ok!("profile={}", profile);
}

/// valid_inj_log_level：injector 认的日志级别。
pub fn valid_inj_log_level(v: &str) -> bool {
    matches!(v, "off" | "error" | "warn" | "warning" | "info" | "debug" | "trace")
}

/// valid_deny_list：逗号分隔的包名列表；返回归一化后的串（去掉空白与空段），不合法返回 None。
pub fn valid_deny_list(raw: &str) -> Option<String> {
    if raw.contains('\n') || raw.contains('\t') || raw.contains('\r') {
        return None;
    }
    let mut out: Vec<String> = Vec::new();
    for part in raw.split(',') {
        let p: String = part.chars().filter(|c| *c != ' ' && *c != '\t').collect();
        if p.is_empty() {
            continue;
        }
        if !valid_pkg(&p) {
            return None;
        }
        out.push(p);
    }
    Some(out.join(","))
}

#[cfg(test)]
mod injector_valid_tests {
    use super::*;

    #[test]
    fn log_level_whitelist() {
        for v in ["off", "error", "warn", "warning", "info", "debug", "trace"] {
            assert!(valid_inj_log_level(v), "{}", v);
        }
        for v in ["", "INFO", "verbose"] {
            assert!(!valid_inj_log_level(v), "{}", v);
        }
    }

    #[test]
    fn deny_list_normalizes_and_validates() {
        assert_eq!(valid_deny_list("com.a, com.b ,,com.c").as_deref(), Some("com.a,com.b,com.c"));
        assert_eq!(valid_deny_list("").as_deref(), Some(""));
        assert!(valid_deny_list("com.a, bad..pkg").is_none());
        assert!(valid_deny_list("com.a\ncom.b").is_none());
    }
}

/// omk_set.awk 的 TOML 原语（split_comment / tomlesc / fmt）。

/// 把一行拆成「主体」与「注释」：TOML 里引号内的 `#` 不算注释。
pub fn split_comment(s: &str) -> (String, String) {
    let mut body = String::new();
    let mut instr = false;
    let mut esc = false;
    for (idx, c) in s.char_indices() {
        if instr {
            body.push(c);
            if esc {
                esc = false;
            } else if c == '\\' {
                esc = true;
            } else if c == '"' {
                instr = false;
            }
            continue;
        }
        if c == '#' {
            return (body, s[idx..].to_string());
        }
        if c == '"' {
            instr = true;
        }
        body.push(c);
    }
    (body, String::new())
}

/// TOML 字符串转义（与 awk 的 tomlesc 同集合）。
pub fn tomlesc(s: &str) -> String {
    let mut out = String::new();
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\t' => out.push_str("\\t"),
            '\r' => out.push_str("\\r"),
            '\n' => out.push_str("\\n"),
            _ => out.push(c),
        }
    }
    out
}

/// 按类型渲染值：bool 裸写、array 逐项加引号、其余字符串加引号。
pub fn fmt_val(v: &str, ty: &str) -> String {
    if ty == "bool" {
        return if v == "true" { "true".to_string() } else { "false".to_string() };
    }
    if ty == "array" {
        let mut s = String::from("[");
        let mut sep = "";
        for part in v.split(',') {
            let item = part.trim_matches([' ', '\t']);
            if item.is_empty() {
                continue;
            }
            s.push_str(sep);
            s.push('"');
            s.push_str(&tomlesc(item));
            s.push('"');
            sep = ", ";
        }
        s.push(']');
        return s;
    }
    format!("\"{}\"", tomlesc(v))
}

#[cfg(test)]
mod omk_toml_tests {
    use super::*;

    #[test]
    fn split_comment_respects_quotes() {
        assert_eq!(split_comment("key = \"a#b\" # 注释"), ("key = \"a#b\" ".to_string(), "# 注释".to_string()));
        assert_eq!(split_comment("plain = 1"), ("plain = 1".to_string(), String::new()));
        // 转义引号不结束字符串
        assert_eq!(split_comment("k = \"a\\\"#b\"#c"), ("k = \"a\\\"#b\"".to_string(), "#c".to_string()));
    }

    #[test]
    fn fmt_bool_array_and_string() {
        assert_eq!(fmt_val("true", "bool"), "true");
        assert_eq!(fmt_val("false", "bool"), "false");
        assert_eq!(fmt_val("a, b ,,c", "array"), "[\"a\", \"b\", \"c\"]");
        assert_eq!(fmt_val("a\"b", "string"), "\"a\\\"b\"");
    }

    #[test]
    fn escape_set() {
        assert_eq!(tomlesc("a\\b\"c\td"), "a\\\\b\\\"c\\td");
    }
}

/// omk_set.awk 的 inj_key：payload 键 → (段, 键)。空串表示不写。
pub fn inj_key(k: &str) -> Option<(&'static str, &str)> {
    match k {
        "inj_main_enabled" => Some(("main", "enabled")),
        "inj_log_level" => Some(("main", "log_level")),
        "filter_enabled" => Some(("filter", "enabled")),
        "filter_block_android" => Some(("filter", "block_android_package")),
        "filter_allow_unknown" => Some(("filter", "allow_unknown_package")),
        "filter_deny" => Some(("filter", "deny_packages")),
        _ if k.starts_with("intercept_") => Some(("intercept", &k[10..])),
        _ => None,
    }
}

/// omk_set.awk 的 cfg_key：payload 键 → (段, 键)。
pub fn cfg_key(k: &str) -> Option<(&'static str, &str)> {
    match k {
        "cfg_log_level" => Some(("main", "log_level")),
        "cfg_force_skip_biometric" => Some(("main", "force_skip_system_biometric_hat_verification")),
        "cfg_retire_stale_keys" => Some(("main", "retire_stale_keybox_bound_keys")),
        "trust_os_version" => Some(("trust", "os_version")),
        "trust_security_patch" => Some(("trust", "security_patch")),
        "trust_os_patchlevel" => Some(("trust", "os_patchlevel")),
        "trust_vendor_patchlevel" => Some(("trust", "vendor_patchlevel")),
        "trust_boot_patchlevel" => Some(("trust", "boot_patchlevel")),
        "trust_vb_key" => Some(("trust", "vb_key")),
        "trust_vb_hash" => Some(("trust", "vb_hash")),
        "trust_verified_boot" => Some(("trust", "verified_boot_state")),
        "trust_device_locked" => Some(("trust", "device_locked")),
        "dev_override_telephony" => Some(("device", "overrideTelephonyProperties")),
        _ if k.starts_with("dev_") => Some(("device", &k[4..])),
        _ => None,
    }
}

/// omk_set.awk 的 key_type：决定值怎么渲染。
pub fn omk_key_type(k: &str) -> &'static str {
    if matches!(
        k,
        "inj_main_enabled" | "filter_enabled" | "filter_block_android" | "filter_allow_unknown"
    ) || k.starts_with("intercept_")
        || matches!(
            k,
            "cfg_force_skip_biometric"
                | "cfg_retire_stale_keys"
                | "trust_verified_boot"
                | "trust_device_locked"
                | "dev_override_telephony"
        )
    {
        return "bool";
    }
    if k == "filter_deny" {
        return "array";
    }
    "str"
}

#[cfg(test)]
mod omk_keymap_tests {
    use super::*;

    #[test]
    fn injector_mapping() {
        assert_eq!(inj_key("inj_main_enabled"), Some(("main", "enabled")));
        assert_eq!(inj_key("filter_deny"), Some(("filter", "deny_packages")));
        assert_eq!(inj_key("intercept_grant"), Some(("intercept", "grant")));
        assert_eq!(inj_key("intercept_get_number_of_entries"), Some(("intercept", "get_number_of_entries")));
        assert_eq!(inj_key("nope"), None);
    }

    #[test]
    fn config_mapping() {
        assert_eq!(cfg_key("cfg_log_level"), Some(("main", "log_level")));
        assert_eq!(cfg_key("trust_vb_hash"), Some(("trust", "vb_hash")));
        assert_eq!(cfg_key("dev_product"), Some(("device", "product")));
        assert_eq!(cfg_key("dev_override_telephony"), Some(("device", "overrideTelephonyProperties")));
        assert_eq!(cfg_key("inj_main_enabled"), None);
    }

    #[test]
    fn types() {
        assert_eq!(omk_key_type("inj_main_enabled"), "bool");
        assert_eq!(omk_key_type("intercept_grant"), "bool");
        assert_eq!(omk_key_type("trust_device_locked"), "bool");
        assert_eq!(omk_key_type("filter_deny"), "array");
        assert_eq!(omk_key_type("inj_log_level"), "str");
        assert_eq!(omk_key_type("trust_security_patch"), "str");
    }
}

/// omk_set.awk 的等价：按 pairs 在 TOML 文本里定位并改值，返回 (新文本, 状态 ok/same/missing)。
/// `target` 为 "injector" 或 "config"（决定键映射表）。
pub fn omk_set(text: &str, pairs: &[(String, String)], target: &str) -> (String, &'static str) {
    // 待写项：(段, 键, 值, 类型)
    let mut items: Vec<(String, String, String, &'static str)> = Vec::new();
    for (k, v) in pairs {
        let mapped = if target == "injector" { inj_key(k) } else { cfg_key(k) };
        let Some((sec, key)) = mapped else { continue };
        items.push((sec.to_string(), key.to_string(), v.clone(), omk_key_type(k)));
    }
    let lines: Vec<&str> = {
        let mut v: Vec<&str> = text.split('\n').collect();
        if text.ends_with('\n') { v.pop(); }
        v
    };
    if lines.is_empty() {
        return (text.to_string(), "missing");
    }
    let want_type = |sec: &str, key: &str| -> Option<&'static str> {
        items.iter().find(|(s, k, _, _)| s == sec && k == key).map(|(_, _, _, ty)| *ty)
    };
    let wval_for = |sec: &str, key: &str| -> Option<String> {
        items.iter().find(|(s, k, _, _)| s == sec && k == key).map(|(_, _, v, _)| v.clone())
    };
    let mut out = String::new();
    let mut handled: std::collections::HashSet<(String, String)> = std::collections::HashSet::new();
    let mut seen_sec: std::collections::HashSet<String> = std::collections::HashSet::new();
    seen_sec.insert(String::new());
    let mut sec = String::new();
    let flush_missing = |out: &mut String, sec: &str, handled: &mut std::collections::HashSet<(String, String)>| {
        for (s, k, v, ty) in &items {
            if s != sec {
                continue;
            }
            if handled.contains(&(s.clone(), k.clone())) {
                continue;
            }
            out.push_str(&format!("{} = {}\n", k, fmt_val(v, ty)));
            handled.insert((s.clone(), k.clone()));
        }
    };
    let mut i = 0usize;
    while i < lines.len() {
        let line = lines[i];
        let trimmed = line.trim_start_matches([' ', '\t']);
        // 段头
        if trimmed.starts_with('[') {
            flush_missing(&mut out, &sec, &mut handled);
            if let (Some(ob), Some(cb)) = (line.find('['), line.find(']')) {
                if cb > ob {
                    sec = line[ob + 1..cb].to_string();
                    seen_sec.insert(sec.clone());
                }
            }
            out.push_str(line);
            out.push('\n');
            i += 1;
            continue;
        }
        // filter 段的 deny_packages 可能是多行数组
        if sec == "filter" && trimmed.starts_with("deny_packages") && trimmed.contains('[') {
            let indent: String = line.chars().take_while(|c| *c == ' ' || *c == '\t').collect();
            let mut j = i;
            let mut combined = line.to_string();
            while !combined.contains(']') && j + 1 < lines.len() {
                j += 1;
                combined.push(' ');
                combined.push_str(lines[j]);
            }
            if combined.contains(']') {
                if let Some(v) = wval_for(&sec, "deny_packages") {
                    out.push_str(&format!("{}{} = {}\n", indent, "deny_packages", fmt_val(&v, "array")));
                    handled.insert((sec.clone(), "deny_packages".to_string()));
                    i = j + 1;
                    continue;
                }
            }
        }
        // 普通 key = value
        let first = trimmed.chars().next().unwrap_or(' ');
        if (first.is_ascii_alphanumeric() || first == '_') && trimmed.contains('=') {
            let (body, comment) = split_comment(line);
            let key = body.split('=').next().unwrap_or("").trim_matches([' ', '\t']).to_string();
            if want_type(&sec, &key).is_some() && !handled.contains(&(sec.clone(), key.clone())) {
                let indent: String = line.chars().take_while(|c| *c == ' ' || *c == '\t').collect();
                if let Some(v) = wval_for(&sec, &key) {
                    let ty = want_type(&sec, &key).unwrap();
                    out.push_str(&format!(
                        "{}{} = {}{}\n",
                        indent,
                        key,
                        fmt_val(&v, ty),
                        if comment.is_empty() { String::new() } else { format!(" {}", comment) }
                    ));
                    handled.insert((sec.clone(), key.clone()));
                    i += 1;
                    continue;
                }
            }
        }
        out.push_str(line);
        out.push('\n');
        i += 1;
    }
    flush_missing(&mut out, &sec, &mut handled);
    // 文件里没有的段：末尾新建
    for (s, ..) in &items {
        if seen_sec.contains(s) {
            continue;
        }
        seen_sec.insert(s.clone());
        out.push_str(&format!("\n[{}]\n", s));
        for (s2, k2, v2, ty2) in &items {
            if s2 != s || handled.contains(&(s2.clone(), k2.clone())) {
                continue;
            }
            out.push_str(&format!("{} = {}\n", k2, fmt_val(v2, ty2)));
            handled.insert((s2.clone(), k2.clone()));
        }
    }
    let status = if out == text { "same" } else { "ok" };
    (out, status)
}

/// cmd_omk_save_injector：写 injector.toml（布尔开关 / 日志级别 / deny 列表）。
pub fn omk_save_injector(payload: &str) {
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
    if !p.omk_injector.is_file() {
        eprintln!("injector.toml 不存在");
        std::process::exit(1);
    }
    let fields = match crate::payload::parse(payload) {
        Ok(v) => v,
        Err(msg) => { eprintln!("{}", msg); std::process::exit(1); }
    };
    let mut norm: Vec<(String, String)> = Vec::new();
    for (k, v) in &fields {
        match k.as_str() {
            "inj_main_enabled" | "filter_enabled" | "filter_block_android" | "filter_allow_unknown" => {
                if !valid_bool(v) { eprintln!("字段只能是 true/false：{}", k); std::process::exit(1); }
            }
            _ if k.starts_with("intercept_") => {
                if !valid_bool(v) { eprintln!("字段只能是 true/false：{}", k); std::process::exit(1); }
            }
            "inj_log_level" => {
                if !valid_inj_log_level(v) {
                    eprintln!("日志级别不合法（injector 认 off/error/warn/warning/info/debug/trace）");
                    std::process::exit(1);
                }
            }
            "filter_deny" => {
                let Some(list) = valid_deny_list(v) else {
                    eprintln!("拒绝包名列表不合法");
                    std::process::exit(1);
                };
                norm.push((k.clone(), list));
                continue;
            }
            other => { eprintln!("未知字段：{}", other); std::process::exit(1); }
        }
        norm.push((k.clone(), v.clone()));
    }
    let n = norm.len();
    let marks: Vec<String> = vec![std::env::var("KL_LOCK_MARK").unwrap_or_else(|_| {
        p.module_prop.parent().and_then(|m| m.file_name()).map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| "keylens".to_string())
    })];
    let lockdir = b.dir.join(".kl_lock");
    if !crate::lock::acquire(&lockdir, 6, &marks) {
        eprintln!("守护进程正在写入，请几秒后再试");
        std::process::exit(1);
    }
    let old = std::fs::read_to_string(&p.omk_injector).unwrap_or_default();
    let (new_text, status) = omk_set(&old, &norm, "injector");
    let mut saved = 0;
    match status {
        "ok" => {
            if new_text != old {
                let bak = b.dir.join("injector.toml.bak");
                let _ = std::fs::copy(&p.omk_injector, &bak);
                let tmp = b.dir.join(format!(".injector.toml.keylens.{}", std::process::id()));
                let ok = std::fs::write(&tmp, new_text.as_bytes()).is_ok()
                    && std::fs::rename(&tmp, &p.omk_injector).is_ok();
                if !ok {
                    let _ = std::fs::remove_file(&tmp);
                    crate::lock::release(&lockdir);
                    eprintln!("写入失败：{}", p.omk_injector.display());
                    std::process::exit(1);
                }
                saved = 1;
            }
        }
        "same" => {}
        _ => {
            crate::lock::release(&lockdir);
            eprintln!("配置定位失败：{}", p.omk_injector.display());
            std::process::exit(1);
        }
    }
    crate::lock::release(&lockdir);
    if saved == 1 {
        let _ = std::fs::File::create(p.omk_state_dir.join("restart.injector"));
        log_line(&p, &format!("🧩 WebUI 更新 OMK injector.toml（{} 项）", n));
    }
    println_ok!("saved={}", saved);
    println_ok!("fields={}", n);
}

/// config.toml 的日志级别（比 injector 少一个 warning 别名）。
pub fn valid_log_level(v: &str) -> bool {
    matches!(v, "off" | "error" | "warn" | "info" | "debug" | "trace")
}

/// OMK 的日期写法：YYYY-MM-DD（月 01-12、日 01-31）。
pub fn valid_omk_date(v: &str) -> bool {
    let p: Vec<&str> = v.split('-').collect();
    if p.len() != 3 || p[0].len() != 4 || !p[0].bytes().all(|c| c.is_ascii_digit()) { return false; }
    let m_ok = p[1].len() == 2 && p[1].bytes().all(|c| c.is_ascii_digit())
        && (1..=12).contains(&p[1].parse::<u32>().unwrap_or(0));
    let d_ok = p[2].len() == 2 && p[2].bytes().all(|c| c.is_ascii_digit())
        && (1..=31).contains(&p[2].parse::<u32>().unwrap_or(0));
    m_ok && d_ok
}

/// auto / latest / 日期。
pub fn valid_omk_patch(v: &str) -> bool {
    matches!(v, "auto" | "latest") || valid_omk_date(v)
}

/// boot 还接受十进制 u32（最多 10 位）。
pub fn valid_omk_boot(v: &str) -> bool {
    if valid_omk_patch(v) { return true; }
    !v.is_empty() && v.len() <= 10 && v.bytes().all(|c| c.is_ascii_digit())
}

/// auto / random / 64 位十六进制。
pub fn valid_omk_hash(v: &str) -> bool {
    if matches!(v, "auto" | "random") { return true; }
    v.len() == 64 && v.bytes().all(|c| c.is_ascii_hexdigit())
}

/// auto 或 0–99（MMmmss 编码值）。
pub fn valid_omk_os_version(v: &str) -> bool {
    if v == "auto" { return true; }
    !v.is_empty() && v.len() <= 2 && v.bytes().all(|c| c.is_ascii_digit())
        && v.parse::<u32>().map(|n| n <= 99).unwrap_or(false)
}

/// 只动四个补丁字段 → hot，否则 restart。
pub fn omk_apply_scope(keys: &[String]) -> &'static str {
    if keys.is_empty() { return "restart"; }
    let only_patch = keys.iter().all(|k| matches!(
        k.as_str(),
        "trust_security_patch" | "trust_os_patchlevel" | "trust_vendor_patchlevel" | "trust_boot_patchlevel"
    ));
    if only_patch { "hot" } else { "restart" }
}

/// vb_key / vb_hash 由 random 切到 auto → 需要重启整机。
pub fn omk_reboot_needed(ovbk: &str, nvbk: &str, ovbh: &str, nvbh: &str) -> bool {
    (ovbk == "random" && nvbk == "auto") || (ovbh == "random" && nvbh == "auto")
}

/// cmd_omk_save_config：写 config.toml（含 apply_scope / apply_note）。
pub fn omk_save_config(payload: &str) {
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
    let cfg = p.omk_dir.join("config.toml");
    if !cfg.is_file() {
        eprintln!("config.toml 不存在");
        std::process::exit(1);
    }
    let fields = match crate::payload::parse(payload) {
        Ok(v) => v,
        Err(msg) => { eprintln!("{}", msg); std::process::exit(1); }
    };
    let old_text = std::fs::read_to_string(&cfg).unwrap_or_default();
    let read_scalar = |key: &str| -> String {
        for line in old_text.lines() {
            let t = line.trim_start();
            let (body, _) = split_comment(t);
            let Some((k, v)) = body.split_once('=') else { continue };
            if k.trim() == key {
                let val = v.trim().trim_matches('"').to_string();
                return val;
            }
        }
        String::new()
    };
    let old_vbk = read_scalar("vb_key");
    let old_vbh = read_scalar("vb_hash");
    let mut new_vbk = String::new();
    let mut new_vbh = String::new();
    let mut keys: Vec<String> = Vec::new();
    for (k, v) in &fields {
        match k.as_str() {
            "cfg_log_level" => {
                if !valid_log_level(v) { eprintln!("日志级别不合法"); std::process::exit(1); }
            }
            "cfg_force_skip_biometric" | "cfg_retire_stale_keys" | "trust_verified_boot" | "trust_device_locked" | "dev_override_telephony" => {
                if !valid_bool(v) { eprintln!("字段只能是 true/false：{}", k); std::process::exit(1); }
            }
            "trust_os_version" => {
                if !valid_omk_os_version(v) { eprintln!("OS 版本只能是 auto 或 0–99（MMmmss 编码值）"); std::process::exit(1); }
            }
            "trust_security_patch" | "trust_os_patchlevel" | "trust_vendor_patchlevel" => {
                if !valid_omk_patch(v) { eprintln!("{} 只能是 auto / latest / YYYY-MM-DD", k); std::process::exit(1); }
            }
            "trust_boot_patchlevel" => {
                if !valid_omk_boot(v) { eprintln!("trust_boot_patchlevel 只能是 auto / latest / YYYY-MM-DD / 十进制数"); std::process::exit(1); }
            }
            "trust_vb_key" | "trust_vb_hash" => {
                if !valid_omk_hash(v) { eprintln!("{} 只能是 auto / random / 64 位十六进制", k); std::process::exit(1); }
            }
            "dev_brand" | "dev_device" | "dev_product" | "dev_manufacturer" | "dev_model" | "dev_serial" | "dev_imei" | "dev_imei2" | "dev_meid" => {
                if !valid_text(v, 128) { eprintln!("字段不合法：{}", k); std::process::exit(1); }
            }
            other => { eprintln!("未知字段：{}", other); std::process::exit(1); }
        }
        keys.push(k.clone());
        if k == "trust_vb_key" { new_vbk = v.clone(); }
        if k == "trust_vb_hash" { new_vbh = v.clone(); }
    }
    let n = fields.len();
    let marks: Vec<String> = vec![std::env::var("KL_LOCK_MARK").unwrap_or_else(|_| {
        p.module_prop.parent().and_then(|m| m.file_name()).map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| "keylens".to_string())
    })];
    let lockdir = b.dir.join(".kl_lock");
    if !crate::lock::acquire(&lockdir, 6, &marks) {
        eprintln!("守护进程正在写入，请几秒后再试");
        std::process::exit(1);
    }
    let (new_text, status) = omk_set(&old_text, &fields, "config");
    let mut saved = 0;
    match status {
        "ok" => {
            if new_text != old_text {
                let bak = b.dir.join("config.toml.bak");
                let _ = std::fs::copy(&cfg, &bak);
                let tmp = b.dir.join(format!(".config.toml.keylens.{}", std::process::id()));
                let ok = std::fs::write(&tmp, new_text.as_bytes()).is_ok()
                    && std::fs::rename(&tmp, &cfg).is_ok();
                if !ok {
                    let _ = std::fs::remove_file(&tmp);
                    crate::lock::release(&lockdir);
                    eprintln!("写入失败：{}", cfg.display());
                    std::process::exit(1);
                }
                saved = 1;
            }
        }
        "same" => {}
        _ => {
            crate::lock::release(&lockdir);
            eprintln!("配置定位失败：{}", cfg.display());
            std::process::exit(1);
        }
    }
    crate::lock::release(&lockdir);
    let mut scope = "restart";
    let mut note = String::new();
    if saved == 1 {
        scope = omk_apply_scope(&keys);
        if scope == "hot" {
            note = "四个补丁字段整组热生效，没有重启 keymint".to_string();
        } else if preview_child() {
            // 影子根里的子进程：重启请求写进影子、随影子一起删，所以不能对用户说「已请求」。
            // apply_scope 照常报（那是判据，不是副作用），只是不写 note。
            note = String::new();
        } else {
            let _ = std::fs::File::create(p.omk_state_dir.join("restart.keymint"));
            note = "已请求重启 keymint".to_string();
        }
        if omk_reboot_needed(&old_vbk, &new_vbk, &old_vbh, &new_vbh) {
            scope = "reboot";
            note = "vb_key/vb_hash 从 random 切到 auto：要重启【整机】才读得到启动元数据，重启 keymint 不够".to_string();
        }
        log_line(&p, &format!("🧩 WebUI 更新 OMK config.toml（{} 项，生效代价 {}）", n, scope));
    }
    println_ok!("saved={}", saved);
    println_ok!("fields={}", n);
    println_ok!("apply_scope={}", scope);
    if !note.is_empty() {
        println_ok!("apply_note={}", note);
    }
}

/// tricky_info.awk 的等价：security_patch.txt 的摘要行（顺序与 awk 一致）。
///
/// 只读**全局段**（第一个 `[包名]` 之前）：裸值进 `patch_all`，`system`/`vendor`/`boot`/`all`
/// 键各自取值（后出现者覆盖）。`patch_lines` 数的是"去掉注释与空白后仍非空"的行，
/// 段头也算一行；`patch_packages` 数段头。
pub fn tricky_info_lines(text: &str) -> Vec<String> {
    let mut n = 0usize;
    let mut npkg = 0usize;
    let mut cur = String::new();
    let (mut sysval, mut venval, mut bootval, mut allval) = (String::new(), String::new(), String::new(), String::new());
    let is_pkg = |t: &str| {
        t.starts_with('[') && t.ends_with(']') && t.len() >= 3 && {
            let name = &t[1..t.len() - 1];
            !name.is_empty() && name.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b'-'))
        }
    };
    for raw in text.split('\n') {
        let mut line = raw.strip_suffix('\r').unwrap_or(raw).to_string();
        if let Some(h) = line.find('#') {
            line.truncate(h);
        }
        let line = line.trim_matches([' ', '\t']).to_string();
        if line.is_empty() {
            continue;
        }
        n += 1;
        if is_pkg(&line) {
            cur = line[1..line.len() - 1].to_string();
            npkg += 1;
            continue;
        }
        if cur.is_empty() {
            match line.find('=') {
                None => {
                    if allval.is_empty() {
                        allval = line.clone();
                    }
                }
                Some(e) => {
                    let k = line[..e].trim_matches([' ', '\t']).to_ascii_lowercase();
                    let v = line[e + 1..].trim_matches([' ', '\t']).to_string();
                    match k.as_str() {
                        "system" => sysval = v,
                        "vendor" => venval = v,
                        "boot" => bootval = v,
                        "all" => allval = v,
                        _ => {}
                    }
                }
            }
        }
    }
    let mut out = vec![format!("patch_lines={}", n), format!("patch_packages={}", npkg)];
    for (key, val) in [("patch_system", &sysval), ("patch_vendor", &venval), ("patch_boot", &bootval), ("patch_all", &allval)] {
        if !val.is_empty() {
            out.push(format!("{}={}", key, val));
        }
    }
    out
}

#[cfg(test)]
mod tricky_info_tests {
    use super::*;

    #[test]
    fn bare_value_and_sections() {
        let text = "2026-10-05\nsystem=2026-10-01\n[com.a]\nvendor=2026-09-01\n";
        let got = tricky_info_lines(text);
        assert_eq!(got, vec![
            "patch_lines=4".to_string(),
            "patch_packages=1".to_string(),
            "patch_system=2026-10-01".to_string(),
            "patch_all=2026-10-05".to_string(),
        ]);
    }

    #[test]
    fn comments_and_blank_lines_do_not_count() {
        let text = "# 注释\n\n  system = 2026-10-01  # 行尾\n";
        let got = tricky_info_lines(text);
        assert_eq!(got, vec!["patch_lines=1".to_string(), "patch_packages=0".to_string(), "patch_system=2026-10-01".to_string()]);
    }

    #[test]
    fn all_key_wins_over_bare() {
        let text = "2026-01-01\nall=2026-02-02\n";
        assert!(tricky_info_lines(text).contains(&"patch_all=2026-02-02".to_string()));
    }

    #[test]
    fn section_only_after_global_is_ignored() {
        let text = "[com.a]\nsystem=2026-01-01\n";
        let got = tricky_info_lines(text);
        assert_eq!(got, vec!["patch_lines=2".to_string(), "patch_packages=1".to_string()]);
    }
}

/// 写前预览用的行级 diff（等价于 shell 的 kl_capture_diff）：
/// 按行做 LCS 动态规划，回溯产出 "- 旧行" / "+ 新行"，输出为正向顺序。
/// 前缀是 "- " / "+ "（带空格），与 awk 版逐字节一致。
pub fn lcs_diff(old: &str, new: &str) -> Vec<String> {
    // 按 awk 的记录语义切：尾换行不算一行（"a\n" 是一条记录，不是两条）。
    // 早先用 split('\n') 会给旧文多造一条空记录，预览的差异里就凭空多出一行 "- "。
    let a: Vec<&str> = old.lines().collect();
    let b: Vec<&str> = new.lines().collect();
    let n = a.len();
    let m = b.len();
    let mut l = vec![vec![0u32; m + 1]; n + 1];
    for i in 1..=n {
        for j in 1..=m {
            l[i][j] = if a[i - 1] == b[j - 1] {
                l[i - 1][j - 1] + 1
            } else if l[i - 1][j] >= l[i][j - 1] {
                l[i - 1][j]
            } else {
                l[i][j - 1]
            };
        }
    }
    let mut out: Vec<String> = Vec::new();
    let (mut i, mut j) = (n, m);
    while i > 0 && j > 0 {
        if a[i - 1] == b[j - 1] {
            i -= 1;
            j -= 1;
        } else if l[i - 1][j] >= l[i][j - 1] {
            out.push(format!("- {}", a[i - 1]));
            i -= 1;
        } else {
            out.push(format!("+ {}", b[j - 1]));
            j -= 1;
        }
    }
    while i > 0 {
        out.push(format!("- {}", a[i - 1]));
        i -= 1;
    }
    while j > 0 {
        out.push(format!("+ {}", b[j - 1]));
        j -= 1;
    }
    out.reverse();
    out
}

#[cfg(test)]
mod diff_tests {
    use super::*;

    #[test]
    fn unchanged_yields_nothing() {
        assert!(lcs_diff("a\nb\n", "a\nb\n").is_empty());
    }

    #[test]
    fn replaced_line() {
        // awk 版把这个替换输出成 "+ X" 在前、"- b" 在后（回溯后倒序打印），照抄
        assert_eq!(lcs_diff("a\nb\nc\n", "a\nX\nc\n"), vec!["+ X", "- b"]);
    }

    #[test]
    fn appended_line() {
        assert_eq!(lcs_diff("a\n", "a\nb\n"), vec!["+ b"]);
    }

    #[test]
    fn removed_line() {
        assert_eq!(lcs_diff("a\nb\n", "a\n"), vec!["- b"]);
    }

    #[test]
    fn trailing_newline_is_not_a_record() {
        // 夹具里的旧文件带尾换行、payload 出来的新内容不带：awk 两边都是一条记录，
        // 按 split('\n') 切会凭空多出一行 "- "（预览的 changed 就多 1）。
        assert!(lcs_diff("a\n", "a").is_empty());
    }
}

/// 影子根预览的子进程标志（main.rs 起子进程时带上，防止再递归）。
/// 子进程照常写文件（写进影子根），但不能替用户做「请求重启」这类看起来已经发生的动作。
pub fn preview_child() -> bool {
    std::env::var("KL_PREVIEW_CHILD").is_ok()
}

/// 统一写回入口：备份后原子替换。预览不走这里——预览是影子根（main.rs 的 `preview_run`），
/// 子进程在影子里照常真写，父进程事后比对，所以这里没有"预览模式"这条路。
pub fn commit_target(target: &std::path::Path, new: &[u8], bak: Option<&std::path::Path>) -> bool {
    if let Some(b) = bak {
        if target.is_file() {
            let _ = std::fs::copy(target, b);
        }
    }
    let dir = target.parent().unwrap_or_else(|| std::path::Path::new("."));
    let tmp = dir.join(format!(".kl_commit.{}", std::process::id()));
    if std::fs::write(&tmp, new).is_err() || std::fs::rename(&tmp, target).is_err() {
        let _ = std::fs::remove_file(&tmp);
        return false;
    }
    true
}

/// 数一个 JSON 对象里**顶层**成员个数（深度 1 的 `"键"` + `:`）。
fn count_members(obj: &[u8]) -> usize {
    let mut depth = 0i32;
    let mut n = 0usize;
    let mut i = 0usize;
    while i < obj.len() {
        let c = obj[i];
        if c == b'"' {
            if depth != 1 {
                // 跳过字符串
                let mut j = i + 1;
                let mut esc = false;
                while j < obj.len() {
                    if esc { esc = false; } else if obj[j] == b'\\' { esc = true; } else if obj[j] == b'"' { break; }
                    j += 1;
                }
                i = j + 1;
                continue;
            }
            // 深度 1：看后面是不是冒号
            let mut j = i + 1;
            let mut esc = false;
            while j < obj.len() {
                if esc { esc = false; } else if obj[j] == b'\\' { esc = true; } else if obj[j] == b'"' { break; }
                j += 1;
            }
            let mut k = j + 1;
            while k < obj.len() && matches!(obj[k], b' ' | b'\t' | b'\r' | b'\n') { k += 1; }
            if obj.get(k) == Some(&b':') {
                n += 1;
            }
            i = j + 1;
            continue;
        }
        if c == b'{' || c == b'[' { depth += 1; }
        else if c == b'}' || c == b']' { depth -= 1; }
        i += 1;
    }
    n
}

/// teesim_info.awk 的等价：config.json 的摘要行（顺序与 awk 一致）。
pub fn teesim_info_lines(text: &str) -> Vec<String> {
    let b = text.as_bytes();
    let mut out: Vec<String> = Vec::new();
    // 顶层 version
    let ver = flat(b, "version");
    out.push(format!("config_version={}", ver));
    // profiles 对象
    let mut pobj: Vec<u8> = Vec::new();
    if let (Some(pp), Some(colon)) = (find_from(b, 0, b"\"profiles\""), None::<usize>) {
        let _ = pp;
        let _ = colon;
    }
    if let Some(pp) = find_from(b, 0, b"\"profiles\"") {
        if let Some(colon) = find_from(b, pp + 10, b":") {
            let mut i = colon + 1;
            while i < b.len() && matches!(b[i], b' ' | b'\t' | b'\r' | b'\n') { i += 1; }
            if b.get(i) == Some(&b'{') {
                if let Some(e) = match_close(b, i) {
                    pobj = b[i..=e].to_vec();
                }
            }
        }
    }
    out.push(format!("profiles={}", if pobj.is_empty() { 0 } else { count_members(&pobj) }));
    // default 对象
    let mut dobj: Vec<u8> = Vec::new();
    if !pobj.is_empty() {
        if let Some((ob, oc)) = {
            let needle = b"\"default\"";
            find_from(&pobj, 0, needle).and_then(|p| {
                let mut m = p + needle.len();
                while m < pobj.len() && matches!(pobj[m], b' ' | b'\t' | b'\r' | b'\n') { m += 1; }
                if pobj.get(m) != Some(&b':') { return None; }
                m += 1;
                while m < pobj.len() && matches!(pobj[m], b' ' | b'\t' | b'\r' | b'\n') { m += 1; }
                if pobj.get(m) != Some(&b'{') { return None; }
                let e = match_close(&pobj, m)?;
                Some((m, e))
            })
        } {
            dobj = pobj[ob..=oc].to_vec();
        }
    }
    let get = |k: &str| -> String { if dobj.is_empty() { String::new() } else { obj_string(&dobj, k) } };
    out.push(format!("default_mode={}", get("mode")));
    out.push(format!("default_keybox={}", get("keybox")));
    out.push(format!("default_os_version={}", get("osVersion")));
    // auto_include：裸布尔（没有就空）
    let ai = if dobj.is_empty() { String::new() } else { flat(&dobj, "autoIncludeNewApps") };
    out.push(format!("default_auto_include={}", ai));
    for k in ["brand", "device", "product", "manufacturer", "model", "serial", "imei", "meid", "imei2"] {
        out.push(format!("default_{}={}", k, get(k)));
    }
    // patchLevel 嵌套
    if !dobj.is_empty() {
        if let Some((ob, oc)) = {
            let needle = b"\"patchLevel\"";
            find_from(&dobj, 0, needle).and_then(|p| {
                let mut m = p + needle.len();
                while m < dobj.len() && matches!(dobj[m], b' ' | b'\t' | b'\r' | b'\n') { m += 1; }
                if dobj.get(m) != Some(&b':') { return None; }
                m += 1;
                while m < dobj.len() && matches!(dobj[m], b' ' | b'\t' | b'\r' | b'\n') { m += 1; }
                if dobj.get(m) != Some(&b'{') { return None; }
                let e = match_close(&dobj, m)?;
                Some((m, e))
            })
        } {
            let pl = &dobj[ob..=oc];
            for k in ["system", "vendor", "boot"] {
                out.push(format!("default_patch_{}={}", k, obj_string(pl, k)));
            }
        }
    }
    out
}

#[cfg(test)]
mod teesim_info_tests {
    use super::*;

    #[test]
    fn full_summary() {
        let text = r#"{"version":1,"profiles":{"default":{"mode":"patch","keybox":"kb.xml","osVersion":"15","autoIncludeNewApps":true,"brand":"XQ","device":"DQ72","patchLevel":{"system":"2026-10-01"}},"work":{"apps":[]}}}"#;
        let got = teesim_info_lines(text);
        assert_eq!(got[0], "config_version=1");
        assert_eq!(got[1], "profiles=2");
        assert!(got.contains(&"default_mode=patch".to_string()));
        assert!(got.contains(&"default_keybox=kb.xml".to_string()));
        assert!(got.contains(&"default_os_version=15".to_string()));
        assert!(got.contains(&"default_auto_include=true".to_string()));
        assert!(got.contains(&"default_brand=XQ".to_string()));
        assert!(got.contains(&"default_device=DQ72".to_string()));
        assert!(got.contains(&"default_patch_system=2026-10-01".to_string()));
    }

    #[test]
    fn empty_config_yields_zero_profiles() {
        let got = teesim_info_lines("{}");
        assert_eq!(got[0], "config_version=");
        assert_eq!(got[1], "profiles=0");
        assert!(got.contains(&"default_mode=".to_string()));
    }
}

/// omk_info.awk 的等价：injector + config 的摘要行（顺序与 awk 一致）。
pub fn omk_info_lines(injector: &str, config: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let unquote = |s: &str| {
        let t = s.trim_matches([' ', '\t']).trim();
        if t.len() >= 2 && t.starts_with('"') && t.ends_with('"') {
            t[1..t.len() - 1].to_string()
        } else {
            t.to_string()
        }
    };
    // injector
    let mut sec = String::new();
    let mut intercept_true = 0usize;
    for raw in injector.split('\n') {
        let line = raw.trim_end_matches('\r');
        let t = line.trim_matches([' ', '\t']);
        if t.is_empty() || t.starts_with('#') {
            continue;
        }
        if t.starts_with('[') && t.ends_with(']') {
            sec = t[1..t.len() - 1].to_string();
            continue;
        }
        let (body, _) = split_comment(t);
        let Some(e) = body.find('=') else { continue };
        let k = body[..e].trim_matches([' ', '\t']).to_string();
        let v = unquote(&body[e + 1..]);
        match (sec.as_str(), k.as_str()) {
            ("", "version") => out.push(format!("injector_version={}", v)),
            ("main", "enabled") => out.push(format!("injector_main_enabled={}", v)),
            ("main", "log_level") => out.push(format!("injector_log_level={}", v)),
            ("filter", "enabled") => out.push(format!("filter_enabled={}", v)),
            ("filter", "block_android_package") => out.push(format!("filter_block_android={}", v)),
            ("filter", "allow_unknown_package") => out.push(format!("filter_allow_unknown={}", v)),
            ("intercept", _) => {
                out.push(format!("intercept_{}={}", k, v));
                if v == "true" {
                    intercept_true += 1;
                }
            }
            _ => {}
        }
    }
    // config
    let mut sec2 = String::new();
    for raw in config.split('\n') {
        let line = raw.trim_end_matches('\r');
        let t = line.trim_matches([' ', '\t']);
        if t.is_empty() || t.starts_with('#') {
            continue;
        }
        if t.starts_with('[') && t.ends_with(']') {
            sec2 = t[1..t.len() - 1].to_string();
            continue;
        }
        let (body, _) = split_comment(t);
        let Some(e) = body.find('=') else { continue };
        let k = body[..e].trim_matches([' ', '\t']).to_string();
        let v = unquote(&body[e + 1..]);
        match (sec2.as_str(), k.as_str()) {
            ("", "version") => out.push(format!("config_version={}", v)),
            ("main", "backend") => out.push(format!("omk_backend={}", v)),
            ("main", "log_level") => out.push(format!("config_log_level={}", v)),
            ("main", "force_skip_system_biometric_hat_verification") => {
                out.push(format!("cfg_force_skip_biometric={}", v))
            }
            ("main", "retire_stale_keybox_bound_keys") => out.push(format!("cfg_retire_stale_keys={}", v)),
            ("device", "brand") => out.push(format!("dev_brand={}", v)),
            ("device", "device") => out.push(format!("dev_device={}", v)),
            ("device", "product") => out.push(format!("dev_product={}", v)),
            ("device", "manufacturer") => out.push(format!("dev_manufacturer={}", v)),
            ("device", "model") => out.push(format!("dev_model={}", v)),
            ("device", "serial") => out.push(format!("dev_serial={}", v)),
            ("device", "imei") => out.push(format!("dev_imei={}", v)),
            ("device", "imei2") => out.push(format!("dev_imei2={}", v)),
            ("device", "meid") => out.push(format!("dev_meid={}", v)),
            ("device", "overrideTelephonyProperties") => out.push(format!("dev_override_telephony={}", v)),
            ("trust", "os_version") => out.push(format!("trust_os_version={}", v)),
            ("trust", "security_patch") => out.push(format!("trust_security_patch={}", v)),
            ("trust", "os_patchlevel") => out.push(format!("trust_os_patchlevel={}", v)),
            ("trust", "vendor_patchlevel") => out.push(format!("trust_vendor_patchlevel={}", v)),
            ("trust", "boot_patchlevel") => out.push(format!("trust_boot_patchlevel={}", v)),
            ("trust", "vb_key") => out.push(format!("trust_vb_key={}", v)),
            ("trust", "vb_hash") => out.push(format!("trust_vb_hash={}", v)),
            ("trust", "verified_boot_state") => out.push(format!("trust_verified_boot={}", v)),
            ("trust", "device_locked") => out.push(format!("trust_device_locked={}", v)),
            _ => {}
        }
    }
    // deny 列表：从 injector 里定位 deny_packages 数组，按引号取条目
    let mut deny_items: Vec<String> = Vec::new();
    let ib = injector.as_bytes();
    if let Some(p) = find_from(ib, 0, b"deny_packages") {
        if let Some(bracket) = find_from(ib, p, b"[") {
            let mut end = bracket;
            while end < ib.len() && ib[end] != b']' {
                end += 1;
            }
            if end < ib.len() {
                let arr = &ib[bracket..=end];
                let mut i = 0usize;
                while i < arr.len() {
                    if arr[i] == b'"' {
                        let start = i + 1;
                        let mut j = start;
                        while j < arr.len() && arr[j] != b'"' {
                            j += 1;
                        }
                        if j < arr.len() {
                            deny_items.push(String::from_utf8_lossy(&arr[start..j]).into_owned());
                            i = j + 1;
                            continue;
                        }
                        break;
                    }
                    i += 1;
                }
            }
        }
    }
    out.push(format!("intercept_true={}", intercept_true));
    out.push(format!("filter_deny={}", deny_items.len()));
    out.push(format!("filter_deny_list={}", deny_items.join(",")));
    out
}

#[cfg(test)]
mod omk_info_tests {
    use super::*;

    #[test]
    fn injector_and_config_summary() {
        let inj = "[main]\nenabled = true\nlog_level = \"info\"\n\n[filter]\nenabled = false\ndeny_packages = [\n  \"com.x\",\n  \"com.y\",\n]\n\n[intercept]\ngrant = true\nungrant = false\n";
        let cfg = "[main]\nbackend = \"keymint\"\nlog_level = \"warn\"\nretire_stale_keybox_bound_keys = true\n\n[trust]\nsecurity_patch = \"2026-10-01\"\nvb_key = \"random\"\n";
        let got = omk_info_lines(inj, cfg);
        assert!(got.contains(&"injector_main_enabled=true".to_string()));
        assert!(got.contains(&"filter_enabled=false".to_string()));
        assert!(got.contains(&"intercept_grant=true".to_string()));
        assert!(got.contains(&"intercept_ungrant=false".to_string()));
        assert!(got.contains(&"omk_backend=keymint".to_string()));
        assert!(got.contains(&"trust_security_patch=2026-10-01".to_string()));
        assert!(got.contains(&"cfg_retire_stale_keys=true".to_string()));
        assert_eq!(got[got.len() - 3], "intercept_true=1");
        assert_eq!(got[got.len() - 2], "filter_deny=2");
        assert_eq!(got[got.len() - 1], "filter_deny_list=com.x,com.y");
    }

    #[test]
    fn empty_files_yield_counts_only() {
        let got = omk_info_lines("", "");
        assert_eq!(got, vec!["intercept_true=0".to_string(), "filter_deny=0".to_string(), "filter_deny_list=".to_string()]);
    }
}

/// cmd_backend_info：三家后端的配置摘要（输出顺序见 docs/BACKEND-INFO-SPEC.md）。
pub fn backend_info() {
    let root = Root::from_env();
    let p = Paths::new(&root);
    let b = backend::detect(&p);
    let bname = match b.id {
        BackendId::Teesim => "TEE Simulator",
        BackendId::Omk => "OhMyKeymint",
        BackendId::Tricky => "Tricky Store",
    };
    let kv = |k: &str, v: &str| println_ok!("{}={}", k, v);
    let mut info: Vec<String> = Vec::new();
    let mut keybox = String::new();
    let mut mdir = String::new();
    let (teesim_module, omk_module, tricky_module) = (
        root.join("/data/adb/modules/teesim"),
        root.join("/data/adb/modules/oh_my_keymint"),
        root.join("/data/adb/modules/tricky_store"),
    );
    match b.id {
        BackendId::Teesim => {
            mdir = teesim_module.to_string_lossy().into_owned();
            keybox = keybox_path_for(&p, b.id).to_string_lossy().into_owned();
            if p.teesim_config.is_file() {
                let text = std::fs::read_to_string(&p.teesim_config).unwrap_or_default();
                info = teesim_info_lines(&text);
            }
        }
        BackendId::Omk => {
            mdir = omk_module.to_string_lossy().into_owned();
            keybox = p.omk_dir.join("keybox.xml").to_string_lossy().into_owned();
            let inj = if p.omk_injector.is_file() {
                std::fs::read_to_string(&p.omk_injector).unwrap_or_default()
            } else {
                String::new()
            };
            let cfg_path = p.omk_dir.join("config.toml");
            let cfg = if cfg_path.is_file() {
                std::fs::read_to_string(&cfg_path).unwrap_or_default()
            } else {
                String::new()
            };
            if p.omk_injector.is_file() || cfg_path.is_file() {
                info = omk_info_lines(&inj, &cfg);
            }
        }
        BackendId::Tricky => {
            mdir = tricky_module.to_string_lossy().into_owned();
            keybox = p.tstore_dir.join("keybox.xml").to_string_lossy().into_owned();
            let patch = p.tstore_dir.join("security_patch.txt");
            kv("patch_file", &patch.to_string_lossy());
            if patch.is_file() {
                kv("patch_exists", "1");
                let text = std::fs::read_to_string(&patch).unwrap_or_default();
                for line in tricky_info_lines(&text) {
                    println_ok!("{}", line);
                }
            } else {
                kv("patch_exists", "0");
            }
        }
    }
    // omk 的守护/注入（本模块自己看，OMK 不自报）
    if b.id == BackendId::Omk {
        let read_pid = |name: &str| -> String {
            std::fs::read_to_string(p.omk_state_dir.join(name))
                .unwrap_or_default()
                .trim()
                .to_string()
        };
        let cmdline_second = |pid: &str| -> String {
            let Ok(data) = std::fs::read(format!("/proc/{}/cmdline", pid)) else { return String::new() };
            let text = String::from_utf8_lossy(&data).replace('\0', "\n");
            text.lines().nth(1).unwrap_or("").to_string()
        };
        let d1 = read_pid("keymint-daemon.pid");
        let d1_alive = !d1.is_empty()
            && std::path::Path::new(&format!("/proc/{}", d1)).exists()
            && cmdline_second(&d1) == format!("{}/daemon", omk_module.display());
        let d2 = read_pid("injector-daemon.pid");
        let d2_alive = !d2.is_empty()
            && std::path::Path::new(&format!("/proc/{}", d2)).exists()
            && cmdline_second(&d2) == format!("{}/daemon-injector", omk_module.display());
        let ks = std::process::Command::new("pidof")
            .arg("keystore2")
            .output()
            .ok()
            .map(|o| String::from_utf8_lossy(&o.stdout).split_whitespace().next().unwrap_or("").to_string())
            .unwrap_or_default();
        let mut injected = 0;
        if !ks.is_empty() {
            if let Ok(pay) = std::fs::read_to_string(p.omk_state_dir.join("injector.payload")) {
                let mut it = pay.split_whitespace();
                let pid = it.next().unwrap_or("");
                let id = it.next().unwrap_or("");
                if pid == ks && !id.is_empty() {
                    injected = 1;
                }
            }
        }
        kv("omk_keymint_daemon", &d1);
        kv("omk_keymint_alive", if d1_alive { "1" } else { "0" });
        kv("omk_injector_daemon", &d2);
        kv("omk_injector_alive", if d2_alive { "1" } else { "0" });
        kv("omk_keystore_pid", &ks);
        kv("omk_keystore_injected", if injected == 1 { "1" } else { "0" });
    }
    kv("backend", b.id.as_str());
    kv("backend_name", bname);
    kv("module_dir", &mdir);
    let mut ver = String::new();
    if let Ok(text) = std::fs::read_to_string(format!("{}/module.prop", mdir)) {
        for line in text.lines() {
            if let Some(v) = line.strip_prefix("version=") {
                ver = v.to_string();
                break;
            }
        }
    }
    kv("module_version", &ver);
    let n = cur_target_tokens(&b).len();
    kv("target_file", &b.target.to_string_lossy());
    kv("target_entries", &n.to_string());
    let kb = std::path::PathBuf::from(&keybox);
    let mut kb_exists = 0;
    let (mut kb_bytes, mut kb_mtime) = (String::new(), String::new());
    if kb.is_file() {
        kb_exists = 1;
        if let Ok(md) = std::fs::metadata(&kb) {
            kb_bytes = md.len().to_string();
            kb_mtime = md
                .modified()
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_secs().to_string())
                .unwrap_or_default();
        }
    }
    kv("keybox_file", &keybox);
    kv("keybox_exists", if kb_exists == 1 { "1" } else { "0" });
    kv("keybox_bytes", &kb_bytes);
    kv("keybox_mtime", &kb_mtime);
    let mut sha = String::new();
    if kb_exists == 1 {
        if let Ok(o) = std::process::Command::new("sha256sum").arg(&kb).output() {
            if o.status.success() {
                sha = String::from_utf8_lossy(&o.stdout).split_whitespace().next().unwrap_or("").to_string();
                kv("keybox_hash_algo", "sha256");
            }
        } else if let Ok(o) = std::process::Command::new("md5sum").arg(&kb).output() {
            if o.status.success() {
                sha = String::from_utf8_lossy(&o.stdout).split_whitespace().next().unwrap_or("").to_string();
                kv("keybox_hash_algo", "md5");
            }
        }
    }
    kv("keybox_hash", &sha);
    if b.id == BackendId::Teesim {
        let mut list: Vec<String> = Vec::new();
        if let Ok(rd) = std::fs::read_dir(&p.teesim_dir) {
            for e in rd.flatten() {
                let name = e.file_name().to_string_lossy().into_owned();
                if name.ends_with(".xml") {
                    list.push(name);
                }
            }
        }
        list.sort();
        kv("keybox_files", &list.join(","));
    }
    for line in info {
        println_ok!("{}", line);
    }
}

/// `stat -c %Y` 的等价：文件不存在/读不到时返回空串（shell 那边是 `2>/dev/null` 的空输出）。
fn mtime_secs(p: &Path) -> String {
    std::fs::metadata(p).ok()
        .and_then(|md| md.modified().ok())
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs().to_string())
        .unwrap_or_default()
}

/// tools.sh 里写死的那三个 busybox 落点。
const BUSYBOX_CANDIDATES: [&str; 3] =
    ["/data/adb/magisk/busybox", "/data/adb/ksu/bin/busybox", "/data/adb/ap/bin/busybox"];

/// shell 的 `command -v`：带 `/` 的按路径判，否则扫 `$PATH`。**不起进程** ——
/// 探测三个工具是否可用本来不该付 fork 的钱，而这条又是 env 页每次都要算的。
fn cmd_available(prog: &str) -> bool {
    use std::os::unix::fs::PermissionsExt;
    let hit = |p: PathBuf| -> bool {
        std::fs::metadata(&p)
            .map(|md| md.is_file() && md.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
    };
    if prog.contains('/') {
        return hit(PathBuf::from(prog));
    }
    match std::env::var_os("PATH") {
        Some(path) => std::env::split_paths(&path).any(|d| hit(d.join(prog))),
        None => false,
    }
}

struct Probed { ok: bool, out: String, err: String }

/// 跑一条探测命令，拿回退码与两路输出（可给 stdin）。
fn probe_run(prog: &str, args: &[&str], input: Option<&[u8]>) -> Option<Probed> {
    use std::io::Write as _;
    let mut cmd = std::process::Command::new(prog);
    cmd.args(args)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
    let mut child = cmd.spawn().ok()?;
    // 句柄在这个 if 体结束时就关掉，否则被探测的命令会等 stdin 不退出
    if let Some(mut si) = child.stdin.take() {
        let _ = si.write_all(input.unwrap_or(b""));
    }
    let out = child.wait_with_output().ok()?;
    Some(Probed {
        ok: out.status.success(),
        out: String::from_utf8_lossy(&out.stdout).into_owned(),
        err: String::from_utf8_lossy(&out.stderr).into_owned(),
    })
}

/// tools.sh 的 find_awk：必须真跑一次 `awk 'BEGIN{}'`。只看"命令存在"会把
/// applet 没编进去的 busybox 当成可用，于是缓存里存进一条用不了的路。
fn find_awk_cmd() -> Option<String> {
    if cmd_available("awk") { return Some("awk".to_string()); }
    for b in BUSYBOX_CANDIDATES {
        if cmd_available(b) && probe_run(b, &["awk", "BEGIN{}"], None).map(|p| p.ok).unwrap_or(false) {
            return Some(format!("{b} awk"));
        }
    }
    None
}

/// tools.sh 的 find_base64：解一次 `aGk=` 要求得到 hi。
fn find_base64_cmd() -> Option<String> {
    if cmd_available("base64") && decodes("base64", &["-d"]) { return Some("base64".to_string()); }
    for b in BUSYBOX_CANDIDATES {
        if cmd_available(b) && decodes(b, &["base64", "-d"]) { return Some(format!("{b} base64")); }
    }
    None
}
fn decodes(prog: &str, args: &[&str]) -> bool {
    probe_run(prog, args, Some(b"aGk=")).map(|p| p.out.contains("hi")).unwrap_or(false)
}

/// tools.sh 的 find_inotify_cmd：按 inotifywait → inotifyd，且用 `--help` 里的标记验真身。
/// 返回 (模式, 命令)，找不到是 ("none", "")。
fn find_inotify_cmd() -> (String, String) {
    for mode in ["inotifywait", "inotifyd"] {
        let marker = if mode == "inotifywait" { "--monitor" } else { "inotifyd" };
        let mut cands: Vec<String> = vec![mode.to_string()];
        for b in BUSYBOX_CANDIDATES {
            cands.push(format!("{b} {mode}"));
        }
        for cmd in cands {
            let (base, applet) = match cmd.split_once(' ') {
                Some((b, a)) => (b, Some(a)),
                None => (cmd.as_str(), None),
            };
            if !cmd_available(base) { continue; }
            let mut argv: Vec<&str> = Vec::new();
            if let Some(a) = applet { argv.push(a); }
            argv.push("--help");
            // shell 是 `2>&1 | grep`：两路合起来找标记，且不看退码
            match probe_run(base, &argv, None) {
                Some(p) if format!("{}{}", p.out, p.err).contains(marker) => {
                    return (mode.to_string(), cmd);
                }
                _ => {}
            }
        }
    }
    ("none".to_string(), String::new())
}

/// cmd_env：环境能力与设备信息（顺序见 docs/ENV-SPEC.md）。
/// 模块目录：优先 KEYLENS_MODDIR，其次「二进制自己在 bin/ 下」推导，最后回落到默认路径。
/// 这样 env/webui_sh 与 icons/webroot 在非默认安装位置也正确。
fn module_dir(root: &Root) -> String {
    if let Ok(v) = std::env::var("KEYLENS_MODDIR") {
        return v;
    }
    if let Ok(exe) = std::env::current_exe() {
        if let (Some(bin), Some(md)) = (exe.parent(), exe.parent().and_then(|p| p.parent())) {
            if bin.file_name().map(|n| n == "bin").unwrap_or(false) {
                return md.to_string_lossy().into_owned();
            }
        }
    }
    root.join("/data/adb/modules/keylens").to_string_lossy().into_owned()
}
pub fn env_cmd() {
    let root = Root::from_env();
    let moddir = module_dir(&root);
    let cache = std::env::var("KL_ENV_CACHE")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| root.join("/data/adb/keylens.env.cache"));
    let run = |prog: &str, args: &[&str]| -> String {
        std::process::Command::new(prog)
            .args(args)
            .output()
            .ok()
            .map(|o| String::from_utf8_lossy(&o.stdout).to_string())
            .unwrap_or_default()
    };
    // 探针缓存：四个工具要真跑一次才知道可用，六个属性 + 状态栏高度要起 getprop/dumpsys/wm，
    // 但它们只在装机、换工具、系统 OTA 时才变 —— 与 webui.sh 的 cmd_env 共用同一个文件、
    // 同一套键：谁先算谁落盘，另一边直接读（所以这里的探测口径必须和 shell 一致，
    // 否则会把两种答案写进同一份缓存互相污染）。缓存键里带 MODDIR，
    // A/B 树与生产树各用各的缓存，不会互相喂值。
    let ckey = {
        let ver = mod_prop(&Path::new(&moddir).join("module.prop"), "version");
        let bp = mtime_secs(Path::new("/system/build.prop"));
        format!("v1|{}|{}|{}", moddir, if ver.is_empty() { "none" } else { &ver }, bp)
    };
    let mut cached: std::collections::HashMap<String, String> = std::collections::HashMap::new();
    if let Ok(text) = std::fs::read_to_string(&cache) {
        for line in text.lines() {
            if let Some((k, v)) = line.split_once('\t') {
                cached.insert(k.to_string(), v.to_string());
            }
        }
    }
    let cache_hit = cached.get("v1").map(|s| s.as_str()) == Some(ckey.as_str());
    let cg = |k: &str| -> String { cached.get(k).cloned().unwrap_or_default() };
    let mut dirty = false;
    let resetprop_v: String;
    let awk_v: String;
    let mut base64_cmd: String;
    let ino_mode_v: String;
    let ino_cmd_v: String;
    let root_user: String;
    let webui_sh: String;
    let device_v: String;
    let brand_v: String;
    let android_v: String;
    let sdk_v: String;
    let build_v: String;
    let vb_v: String;
    let sb_dp_v: String;
    if cache_hit {
        resetprop_v = cg("resetprop");
        awk_v = cg("awk");
        base64_cmd = cg("base64_cmd");
        ino_mode_v = cg("ino_mode");
        ino_cmd_v = cg("ino_cmd");
        root_user = cg("root_user");
        webui_sh = cg("webui_sh");
        device_v = cg("device");
        brand_v = cg("brand");
        android_v = cg("android");
        sdk_v = cg("sdk");
        build_v = cg("build_type");
        vb_v = cg("vbstate");
        sb_dp_v = cg("statusbar_dp");
    } else {
        // 一次全量 dump 查表：逐键 getprop 每次约 18ms，这一页要 6 个键 + 一个密度兜底。
        let prop_snap = prop_snapshot();
        let prop = |name: &str| -> String { prop_snap.get(name).cloned().unwrap_or_default() };
        resetprop_v = if cmd_available("resetprop") { "1" } else { "0" }.to_string();
        awk_v = if find_awk_cmd().is_some() { "1" } else { "0" }.to_string();
        base64_cmd = find_base64_cmd().unwrap_or_default();
        let ino = find_inotify_cmd();
        ino_mode_v = ino.0;
        ino_cmd_v = ino.1;
        root_user = run("id", &["-u"]).trim().to_string();
        webui_sh = format!("{moddir}/webui.sh");
        device_v = prop("ro.product.model");
        brand_v = prop("ro.product.brand");
        android_v = prop("ro.build.version.release");
        sdk_v = prop("ro.build.version.sdk");
        build_v = prop("ro.build.type");
        vb_v = prop("ro.boot.verifiedbootstate");
        // 状态栏高度：dumpsys window 量像素、wm density 量 dpi，两个都要现算
        let mut sbh = String::new();
        {
            let out = run("dumpsys", &["window", "displays"]);
            for line in out.lines() {
                if let Some(pos) = line.find("type=statusBars frame=[") {
                    let mut nums: Vec<String> = Vec::new();
                    let mut cur = String::new();
                    for c in line[pos..].chars() {
                        if c.is_ascii_digit() { cur.push(c); }
                        else if !cur.is_empty() { nums.push(std::mem::take(&mut cur)); }
                    }
                    if !cur.is_empty() { nums.push(cur); }
                    if nums.len() >= 4 { sbh = nums[3].clone(); break; }
                }
            }
        }
        let mut dens = String::new();
        {
            let out = run("wm", &["density"]);
            for line in out.lines() {
                if let Some(rest) = line.trim().strip_prefix("Physical density:") {
                    dens = rest.trim().chars().take_while(|c| c.is_ascii_digit()).collect();
                    break;
                }
            }
            if dens.is_empty() { dens = prop("ro.sf.lcd_density"); }
        }
        let sbh_n: u64 = sbh.parse().unwrap_or(0);
        let dens_n: u64 = dens.parse().unwrap_or(0);
        sb_dp_v = if sbh_n > 0 && dens_n > 0 {
            ((sbh_n * 160 + dens_n - 1) / dens_n).to_string()
        } else {
            String::new()
        };
        dirty = true;
    }
    let base64_v = if base64_cmd.is_empty() { "0" } else { "1" }.to_string();
    // 每次现取：深浅色
    let uimode = {
        let mut o = run("dumpsys", &["uimode"]);
        if o.is_empty() { o = "".to_string(); }
        o
    };
    let mut dark = String::new();
    let mut dark_src = String::new();
    if uimode.contains("mComputedNightMode=true") {
        dark = "1".to_string();
        dark_src = "mComputedNightMode".to_string();
    } else if uimode.contains("mComputedNightMode=false") {
        dark = "0".to_string();
        dark_src = "mComputedNightMode".to_string();
    } else if let Some(pos) = uimode.find("mCurUiMode=0x") {
        let rest = &uimode[pos + "mCurUiMode=0x".len()..];
        let hex: String = rest.chars().take_while(|c| c.is_ascii_hexdigit()).collect();
        if !hex.is_empty() {
            let v = u32::from_str_radix(&hex, 16).unwrap_or(0);
            dark = if v & 32 != 0 { "1".to_string() } else { "0".to_string() };
            dark_src = "mCurUiMode".to_string();
        } else {
            dark_src = "none".to_string();
        }
    } else {
        dark_src = "none".to_string();
    }
    // FRRO：优先 SystemUI 的 accent，其次 dynamic；按 mtime 取最新。
    // 路径与 mtime 每次现查（换主题必须马上看见），base64 只在二者之一变了时才重编。
    let rc_dir = root.join("/data/resource-cache");
    let pick = |pat_prefix: &str| -> Option<std::path::PathBuf> {
        let rd = std::fs::read_dir(&rc_dir).ok()?;
        let mut best: Option<(std::time::SystemTime, std::path::PathBuf)> = None;
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            if name.starts_with(pat_prefix) && name.ends_with(".frro") {
                if let Ok(md) = e.metadata() {
                    if let Ok(mt) = md.modified() {
                        if best.as_ref().map(|(t, _)| mt > *t).unwrap_or(true) {
                            best = Some((mt, e.path()));
                        }
                    }
                }
            }
        }
        best.map(|(_, p)| p)
    };
    let frro = pick("com.android.systemui-accent-").or_else(|| pick("com.android.systemui-dynamic-"));
    let frro_now = frro.as_ref().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default();
    let frro_mtime_now = frro.as_ref().map(|p| mtime_secs(p.as_path())).unwrap_or_default();
    let mut frro_path_v = cg("frro_path");
    let mut frro_mtime_v = cg("frro_mtime");
    let mut frro_b64_v = cg("frro_b64");
    if frro_now != frro_path_v || frro_mtime_now != frro_mtime_v || frro_b64_v.is_empty() {
        let mut enc = String::new();
        if !frro_now.is_empty() {
            // 与 shell 同一道闸：base64 探不到就不交这张 overlay。Rust 自己能编码，
            // 但缓存是两边共用的 —— 输出一边有一边没有，界面就会看出"按了同一个按钮换了个实现"。
            if base64_cmd.is_empty() { base64_cmd = find_base64_cmd().unwrap_or_default(); }
            if !base64_cmd.is_empty() {
                if let Some(f) = &frro {
                    if let Ok(data) = std::fs::read(f) { enc = crate::b64::encode_bytes(&data); }
                }
            }
        }
        if !enc.is_empty() {
            frro_path_v = frro_now;
            frro_mtime_v = frro_mtime_now;
            frro_b64_v = enc;
            dirty = true;
        } else if frro_now.is_empty() && !frro_path_v.is_empty() {
            frro_path_v = String::new();
            frro_mtime_v = String::new();
            frro_b64_v = String::new();
            dirty = true;
        }
    }
    let seeding = {
        let s = run("settings", &["get", "secure", "theme_custom_color"]);
        let t = s.trim();
        if t.is_empty() || t == "null" || t.starts_with("null") { String::new() } else { t.to_string() }
    };
    let seed_raw;
    let seed_src;
    if !seeding.is_empty() {
        seed_raw = seeding.clone();
        seed_src = "theme_custom_color".to_string();
    } else if !frro_b64_v.is_empty() {
        seed_raw = String::new();
        seed_src = "none".to_string();
    } else {
        let w = run("dumpsys", &["wallpaper"]);
        let mut wc = String::new();
        if let Some(pos) = w.find("colorValue0=") {
            let rest = &w[pos + "colorValue0=".len()..];
            wc = rest.chars().take_while(|c| c.is_ascii_digit() || *c == '-').collect();
        }
        if wc.is_empty() {
            seed_raw = String::new();
            seed_src = "none".to_string();
        } else {
            seed_raw = wc;
            seed_src = "wallpaper_color0".to_string();
        }
    }
    // 输出
    println_ok!("sys_dark={}", dark);
    println_ok!("sys_dark_src={}", dark_src);
    if !frro_b64_v.is_empty() {
        println_ok!("sys_frro={}", frro_b64_v);
        println_ok!("sys_frro_src={}", frro_path_v);
    }
    println_ok!("sys_seed_raw={}", seed_raw);
    println_ok!("sys_seed_src={}", seed_src);
    println_ok!("resetprop={}", resetprop_v);
    println_ok!("awk={}", awk_v);
    println_ok!("base64={}", base64_v);
    println_ok!("inotify_mode={}", ino_mode_v);
    println_ok!("inotify_cmd={}", ino_cmd_v);
    println_ok!("root_user={}", root_user);
    println_ok!("webui_sh={}", webui_sh);
    println_ok!("device={}", device_v);
    println_ok!("brand={}", brand_v);
    println_ok!("android={}", android_v);
    println_ok!("sdk={}", sdk_v);
    println_ok!("build_type={}", build_v);
    println_ok!("vbstate={}", vb_v);
    if !sb_dp_v.is_empty() {
        println_ok!("sys_statusbar_dp={}", sb_dp_v);
    }
    // 落盘：首次 / 缓存键变了 / 换主题时才写。键与顺序必须和 cmd_env 那 19 行一致，
    // 否则 shell 的 `case "$k"` 读不到、下一轮又当空缓存重算一遍。
    if dirty {
        let rows: [(&str, &str); 19] = [
            ("v1", ckey.as_str()),
            ("resetprop", resetprop_v.as_str()),
            ("awk", awk_v.as_str()),
            ("base64", base64_v.as_str()),
            ("base64_cmd", base64_cmd.as_str()),
            ("ino_mode", ino_mode_v.as_str()),
            ("ino_cmd", ino_cmd_v.as_str()),
            ("root_user", root_user.as_str()),
            ("webui_sh", webui_sh.as_str()),
            ("device", device_v.as_str()),
            ("brand", brand_v.as_str()),
            ("android", android_v.as_str()),
            ("sdk", sdk_v.as_str()),
            ("build_type", build_v.as_str()),
            ("vbstate", vb_v.as_str()),
            ("statusbar_dp", sb_dp_v.as_str()),
            ("frro_path", frro_path_v.as_str()),
            ("frro_mtime", frro_mtime_v.as_str()),
            ("frro_b64", frro_b64_v.as_str()),
        ];
        let mut body = String::new();
        for (k, v) in rows {
            body.push_str(k);
            body.push('\t');
            body.push_str(v);
            body.push('\n');
        }
        // 先写临时文件再改名：读的一方永远只会看见完整的 19 行
        let tmp = PathBuf::from(format!("{}.tmp.{}", cache.display(), std::process::id()));
        if std::fs::write(&tmp, body.as_bytes()).is_ok() {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600));
            if std::fs::rename(&tmp, &cache).is_err() {
                let _ = std::fs::remove_file(&tmp);
            }
        }
    }
}

/// 已装第三方应用（排序去重，含去前缀与去 [N] 尾缀）。
/// 就是 `cmd_apps` 的默认档 —— 以前这里是自己抄的一份（多了一步 `\r` 裁剪，与 shell
/// 那条 sed 并不逐字节相同）。同步读的这份必须与命令层同源，否则两侧"已装"会分叉。
fn installed_pkgs() -> Vec<String> {
    pkg_names(&["-3"])
}

fn read_lines(path: &std::path::Path) -> Vec<String> {
    std::fs::read_to_string(path)
        .map(|t| t.lines().map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect())
        .unwrap_or_default()
}

/// build_app_list：返回 (新名单行, KL_COUNT)；None = 读空保护触发（rc 1）。
fn build_app_list(b: &Backend, empty_ok: bool) -> (Option<Vec<String>>, usize) {
    let inst = installed_pkgs();
    let cur = cur_target_tokens(b);
    let st_installed = b.dir.join(".kl_installed_last");
    let st_ever = b.dir.join(".kl_ever");
    let was = read_lines(&st_installed);
    if inst.is_empty() && !was.is_empty() && !empty_ok {
        return (None, 0);
    }
    // 首次安装种子
    let mut seed: Vec<String> = Vec::new();
    if !st_installed.exists() && cur.is_empty() {
        seed = vec![
            "com.android.vending".to_string(),
            "com.google.android.gms".to_string(),
            "com.google.android.gsf".to_string(),
        ];
    }
    // OMK 首次接入沿用现有名单
    let adopt = b.id == BackendId::Omk && !st_installed.exists() && !cur.is_empty();
    let inst_set: std::collections::HashSet<&String> = inst.iter().collect();
    let was_set: std::collections::HashSet<&String> = was.iter().collect();
    let gone: std::collections::HashSet<String> = was
        .iter()
        .filter(|p| !inst_set.contains(p))
        .map(|s| s.clone())
        .collect();
    let base_of = |t: &str| entry_base(t, b.id);
    let mut keep: Vec<String> = Vec::new();
    let mut keepbase: std::collections::HashSet<String> = std::collections::HashSet::new();
    for tok in &cur {
        let base = base_of(tok);
        if !base.is_empty() && gone.contains(&base) {
            continue;
        }
        keep.push(tok.clone());
        if !base.is_empty() {
            keepbase.insert(base);
        }
    }
    if !adopt {
        for p in &inst {
            if !was_set.contains(p) && !keepbase.contains(p) {
                keep.push(p.clone());
                keepbase.insert(p.clone());
            }
        }
    }
    for p in &seed {
        if !keepbase.contains(p) {
            keep.push(p.clone());
            keepbase.insert(p.clone());
        }
    }
    keep.sort();
    keep.dedup();
    let n = keep.len();
    // 状态文件（NEW）先写，等目标文件写成功后再提交
    let installed_new = b.dir.join(".kl_installed_last.new");
    let ever_new = b.dir.join(".kl_ever.new");
    let _ = std::fs::write(&installed_new, inst.join("\n") + "\n");
    let mut ever: Vec<String> = read_lines(&st_ever);
    ever.extend(keep.iter().map(|t| base_of(t)).filter(|s| !s.is_empty()));
    ever.sort();
    ever.dedup();
    let _ = std::fs::write(&ever_new, ever.join("\n") + "\n");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&installed_new, std::fs::Permissions::from_mode(0o600));
        let _ = std::fs::set_permissions(&ever_new, std::fs::Permissions::from_mode(0o600));
    }
    (Some(keep), n)
}

/// 提交状态文件（目标文件写成功后调用）。
fn commit_state(p: &Paths, b: &Backend) {
    let _ = p;
    let inst = b.dir.join(".kl_installed_last");
    let ever = b.dir.join(".kl_ever");
    let _ = std::fs::rename(b.dir.join(".kl_installed_last.new"), &inst);
    let _ = std::fs::rename(b.dir.join(".kl_ever.new"), &ever);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        for f in [&inst, &ever] {
            let _ = std::fs::set_permissions(f, std::fs::Permissions::from_mode(0o600));
        }
    }
    for legacy in [".kl_written_last", ".kl_written.new", ".kl_removed", ".kl_removed.new"] {
        let _ = std::fs::remove_file(b.dir.join(legacy));
    }
}

/// 把新名单写回目标文件：0=写了 1=内容一致 2=失败。
fn write_synced_list(b: &Backend, list: &[String]) -> i32 {
    let old = std::fs::read(&b.target).unwrap_or_default();
    let body = if list.is_empty() { String::new() } else { list.join("\n") + "\n" };
    let new: Option<Vec<u8>> = match b.id {
        BackendId::Tricky => Some(body.into_bytes()),
        BackendId::Teesim => teesim_apps_rewrite(&old, list),
        BackendId::Omk => omk_scoop_rewrite(&old, list),
    };
    let Some(new) = new else { return 2 };
    if new == old {
        return 1;
    }
    let tmp = b.dir.join(format!(".kl_tmp.{}", std::process::id()));
    let ok = std::fs::write(&tmp, &new).is_ok() && std::fs::rename(&tmp, &b.target).is_ok();
    if !ok {
        let _ = std::fs::remove_file(&tmp);
        return 2;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = if b.id == BackendId::Tricky { 0o644 } else { 0o600 };
        let _ = std::fs::set_permissions(&b.target, std::fs::Permissions::from_mode(mode));
    }
    0
}

/// cmd_sync：立即同步一次（用户显式触发，允许把"读到空"当真清空）。
pub fn sync() {
    let root = Root::from_env();
    let p = Paths::new(&root);
    if backends_conflict(&p) {
        eprintln!("{}", CONFLICT_MSG);
        std::process::exit(1);
    }
    let b = backend::detect(&p);
    let marks: Vec<String> = vec![std::env::var("KL_LOCK_MARK").unwrap_or_else(|_| {
        p.module_prop.parent().and_then(|m| m.file_name()).map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| "keylens".to_string())
    })];
    let lockdir = b.dir.join(".kl_lock");
    // KL_LOCK_HELD=1 是"接力条"：shell 侧的 run_sync 是在 webui_lock / acquire_lock 之内被调的，
    // 锁已经在这个进程手上。子进程再取一次等于自己抢自己——锁是按持有者证据判活的，
    // 父 shell 的 cmdline 里就带着模块标记，结果是白等 6 秒然后报「守护进程正在写入」。
    let inherited_lock = std::env::var("KL_LOCK_HELD").as_deref() == Ok("1");
    if !inherited_lock && !crate::lock::acquire(&lockdir, 6, &marks) {
        eprintln!("守护进程正在写入，请几秒后再试");
        std::process::exit(1);
    }
    let (list, count) = build_app_list(&b, true);
    let rc = match list {
        None => {
            // 读空且不允许清空：按失败处理，不提交基线
            let bname = match b.id { BackendId::Teesim => "TEE Simulator", BackendId::Omk => "OhMyKeymint", BackendId::Tricky => "Tricky Store" };
            let hm = std::process::Command::new("date").arg("+%H:%M").output().ok()
                .map(|o| String::from_utf8_lossy(&o.stdout).trim_end_matches('\n').to_string()).unwrap_or_default();
            set_module_desc(&p.module_prop, &format!("⚠️ [{} | 写入失败 | 更新: {}]", bname, hm));
            2
        }
        Some(rows) => {
            if rows.is_empty() {
                2
            } else {
                let rc = write_synced_list(&b, &rows);
                if rc == 0 || rc == 1 {
                    commit_state(&p, &b);
                }
                rc
            }
        }
    };
    if !inherited_lock {
        crate::lock::release(&lockdir);
    }
    if rc != 2 {
        refresh_desc(&p, &b, count);
    }
    println_ok!("rc={}", rc);
    println_ok!("count={}", count);
    // 同步后的新描述：模块详情页与界面共用同一份状态（shell 版也打这一行）
    let desc = std::fs::read_to_string(&p.module_prop)
        .unwrap_or_default()
        .lines()
        .find_map(|l| l.strip_prefix("description=").map(|v| v.to_string()))
        .unwrap_or_default();
    println_ok!("description={}", desc);
}

/// cmd_icons：从桌面图标缓存导出 PNG + 显示名（`包名<TAB>显示名<TAB>相对路径`）。
pub fn icons(arg: &str) {
    if arg.is_empty() {
        return;
    }
    let root = Root::from_env();
    let moddir = module_dir(&root);
    let mut db = String::new();
    for p in [
        "/data/data/com.android.launcher3/databases/app_icons.db",
        "/data/data/com.google.android.apps.nexuslauncher/databases/app_icons.db",
    ] {
        let full = root.join(p);
        if full.is_file() {
            db = full.to_string_lossy().into_owned();
            break;
        }
    }
    if db.is_empty() {
        if let Ok(rd) = std::fs::read_dir(root.join("/data/data")) {
            for e in rd.flatten() {
                let cand = e.path().join("databases/app_icons.db");
                if cand.is_file() {
                    db = cand.to_string_lossy().into_owned();
                    break;
                }
            }
        }
    }
    if db.is_empty() {
        eprintln!("未找到桌面图标缓存 app_icons.db");
        return;
    }
    if std::process::Command::new("sqlite3").arg("-version").output().is_err() {
        eprintln!("未找到 sqlite3，无法读图标缓存");
        return;
    }
    let dir = format!("{}/webroot/icons", moddir);
    if std::fs::create_dir_all(&dir).is_err() {
        eprintln!("无法创建 {}", dir);
        std::process::exit(1);
    }
    // 包名校验后拼 chain
    let mut want: Vec<String> = Vec::new();
    let mut chain = String::new();
    for p in arg.split(',') {
        let ok_first = p.chars().next().map(|c| c.is_ascii_alphabetic()).unwrap_or(false);
        if !ok_first {
            continue;
        }
        if p.contains("..") || p.contains('/')
            || !p.bytes().all(|c| c.is_ascii_alphanumeric() || matches!(c, b'.' | b'_' | b'-'))
        {
            continue;
        }
        want.push(p.to_string());
        chain.push_str(&format!("{}componentName like '{}/%'", if chain.is_empty() { "" } else { " or " }, p));
    }
    if chain.is_empty() {
        return;
    }
    let cache = format!("{}/index.tsv", dir);
    let dbm = std::fs::metadata(&db)
        .ok()
        .and_then(|m| m.modified().ok())
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs().to_string())
        .unwrap_or_default();
    // 快路：缓存命中且 PNG 都在
    if std::path::Path::new(&cache).is_file() && !dbm.is_empty() {
        let dbm_cached = std::fs::read_to_string(format!("{}/.dbmtime", dir)).unwrap_or_default();
        if dbm_cached.trim() == dbm {
            let idx = std::fs::read_to_string(&cache).unwrap_or_default();
            let mut map: std::collections::HashMap<String, String> = std::collections::HashMap::new();
            for line in idx.lines() {
                if let Some((p, _)) = line.split_once('\t') {
                    map.entry(p.to_string()).or_insert_with(|| line.to_string());
                }
            }
            let mut hit: Vec<String> = Vec::new();
            let mut ok = true;
            for p in &want {
                let Some(line) = map.get(p) else { ok = false; break };
                hit.push(line.clone());
                let third = line.splitn(3, '\t').nth(2).unwrap_or("");
                if third.is_empty() {
                    continue;
                }
                if !std::path::Path::new(&format!("{}/{}.png", dir, p)).is_file() {
                    ok = false;
                    break;
                }
            }
            if ok && !hit.is_empty() {
                for l in hit {
                    println_ok!("{}", l);
                }
                return;
            }
        }
    }
    // 冷路：桌面库 SQL（与 shell 同一条语句）
    let sql = format!(
        "select p || char(9) || l || char(9) || 'icons/' || p || '.png' from (select p, min(rank) r, l, writefile('{dir}/' || p || '.png', ic) w from (select substr(componentName, 1, instr(componentName, '/') - 1) p,(case when instr(substr(componentName, instr(componentName, '/') + 1), '.') = 0 then 900000 when substr(componentName, instr(componentName, '/') + 1) like substr(componentName, 1, instr(componentName, '/') - 1) || '.%' then 0 else 100000 end) + length(componentName) rank,replace(replace(label, char(9), ' '), char(10), ' ') l, icon ic from icons where componentName not like '%#%' and ({chain})) group by p ) where w > 0;",
        dir = dir,
        chain = chain
    );
    let rows = std::process::Command::new("sqlite3")
        .arg(&db)
        .arg(&sql)
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim_end_matches('\n').to_string())
        .unwrap_or_default();
    if !rows.is_empty() {
        println_ok!("{}", rows);
    }
    // 补缺：app_process + icondump.dex
    let dex = format!("{}/lib/icondump.dex", moddir);
    let mut res2 = String::new();
    let mut dbm_exists = false;
    if !dbm.is_empty() {
        dbm_exists = true;
    }
    if !want.is_empty() && std::path::Path::new(&dex).is_file() {
        let have: std::collections::HashSet<String> = rows
            .lines()
            .filter_map(|l| l.split('\t').next().map(|s| s.to_string()))
            .collect();
        let mut miss: Vec<String> = Vec::new();
        for p in &want {
            if have.contains(p) {
                continue;
            }
            miss.push(p.clone());
            // 120 = 界面一批要的量 = shell 侧 kl 冷路上限（三个数由 tests/ui-shape.js 钉住）。
            // 原来这里是 60：界面要 120 个，每次有 60 个被静默丢掉，只能永远画首字块 ——
            // 「系统应用」那一档（本机 235 条）把这条踩实了：实测要 120 个只回 65 行。
            if miss.len() >= 120 {
                break;
            }
        }
        if !miss.is_empty() {
            if let Ok(o) = std::process::Command::new("app_process")
                .arg(format!("-Djava.class.path={}", dex))
                .arg("/system/bin")
                .arg("IconDump")
                .arg(miss.join(","))
                .arg(&dir)
                .arg("192")
                .output()
            {
                res2 = String::from_utf8_lossy(&o.stdout).trim_end_matches('\n').to_string();
                if !res2.is_empty() {
                    println_ok!("{}", res2);
                }
            }
        }
    }
    // 落缓存：请求了什么、拿到什么
    if dbm_exists {
        let mut out: Vec<String> = Vec::new();
        let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
        for chunk in [rows.as_str(), res2.as_str()] {
            for line in chunk.lines() {
                if line.split('\t').count() < 2 {
                    continue;
                }
                let first = line.split('\t').next().unwrap_or("").to_string();
                if seen.insert(first) {
                    out.push(line.to_string());
                }
            }
        }
        let mut present: std::collections::HashSet<String> = out
            .iter()
            .map(|l| l.split('\t').next().unwrap_or("").to_string())
            .collect();
        for p in &want {
            if !present.contains(p) {
                out.push(format!("{}\t\t", p));
                present.insert(p.clone());
            }
        }
        let body = if out.is_empty() { String::new() } else { out.join("\n") + "\n" };
        let _ = std::fs::write(&cache, body.as_bytes());
        let _ = std::fs::write(format!("{}/.dbmtime", dir), dbm.as_bytes());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            if let Ok(rd) = std::fs::read_dir(&dir) {
                for e in rd.flatten() {
                    let p = e.path();
                    if p.extension().map(|x| x == "png").unwrap_or(false) {
                        let _ = std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o644));
                    }
                }
            }
            let _ = std::fs::set_permissions(&cache, std::fs::Permissions::from_mode(0o644));
            let _ = std::fs::set_permissions(format!("{}/.dbmtime", dir), std::fs::Permissions::from_mode(0o644));
            let _ = std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o755));
        }
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    /// `set_module_desc` 只换 description 一行，并且必须保住 module.prop 原有的 mode：
    /// 落盘走"写 tmp + 改名"，改名会把 tmp 的权限（继承调用者 umask）带过去，
    /// 不补回去，装机那份 644 就会一路漂（生产机上实测漂成过 666）。
    /// ⚠ "原 mode"不能随手写死：它得和"这个平台 fs::write 造出来的权限"不一样才测得出差别。
    /// 第一版写死 644，而 WSL 的 umask 就是 022（造出来也是 644），把补权限那行删掉测试照样绿。
    #[test]
    fn set_module_desc_keeps_mode_and_other_lines() {
        let dir = std::env::temp_dir().join(format!("kl-desc-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let prop = dir.join("module.prop");

        // 先探一下这里 fs::write 落出来的权限，取一个与它不同的 mode 当"要保住的原权限"
        let probe = dir.join("probe");
        std::fs::write(&probe, "x").unwrap();
        let created = std::fs::metadata(&probe).unwrap().permissions().mode() & 0o7777;
        std::fs::remove_file(&probe).ok();
        let keep: u32 = (created ^ 0o020) & 0o777;

        std::fs::write(&prop, "id=keylens\nname=KeyLens\nversion=v1\ndescription=旧描述\n").unwrap();
        std::fs::set_permissions(&prop, std::fs::Permissions::from_mode(keep)).unwrap();
        let got = std::fs::metadata(&prop).unwrap().permissions().mode() & 0o7777;
        if got != keep {
            // chmod 敌不过这个文件系统（drvfs/MSYS 那类）：明说"没测到"，不许当成通过
            eprintln!("  --  跳过权限断言：{} 上 chmod 不生效（想要 {:o}，实得 {:o}）",
                dir.display(), keep, got);
            std::fs::remove_dir_all(&dir).ok();
            return;
        }

        set_module_desc(&prop, "✅ [OMK | 应用: 12 | 更新: 12:34]");

        let text = std::fs::read_to_string(&prop).unwrap();
        assert_eq!(text, "id=keylens\nname=KeyLens\nversion=v1\ndescription=✅ [OMK | 应用: 12 | 更新: 12:34]\n");
        let after = std::fs::metadata(&prop).unwrap().permissions().mode() & 0o7777;
        assert_eq!(after, keep, "module.prop 的权限被改名带跑了（{:o} → {:o}）", keep, after);
        let leftovers: Vec<String> = std::fs::read_dir(&dir).unwrap().flatten()
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| n != "module.prop")
            .collect();
        assert!(leftovers.is_empty(), "留下了 tmp 文件：{:?}", leftovers);
        std::fs::remove_dir_all(&dir).ok();
    }
}
