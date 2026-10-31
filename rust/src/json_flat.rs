//! js_flat：扁平 JSON 对象的定值写入（json_flat_set.awk 的等价）。
//!
//! 原则：只改请求里的键，其余字节原样保留；值一律渲染成带引号的 JSON 字符串
//! （上游守护进程按 Map<String,String> 读，裸数字会造成形状不一致）；
//! 空值 = 删除整条成员（连键名、冒号、逗号与行内残留空白一起删）。

pub struct Hit {
    pub ks: usize,
    pub ke: usize,
    pub kbs: usize,
}

fn match_close(b: &[u8], open: usize) -> Option<usize> {
    let mut depth = 0i32;
    let mut instr = false;
    let mut esc = false;
    for i in open..b.len() {
        let c = b[i];
        if instr {
            if esc { esc = false; } else if c == b'\\' { esc = true; } else if c == b'"' { instr = false; }
            continue;
        }
        if c == b'"' { instr = true; continue; }
        if c == b'{' || c == b'[' { depth += 1; }
        else if c == b'}' || c == b']' { depth -= 1; if depth == 0 { return Some(i); } }
    }
    None
}

fn after_string(b: &[u8], from: usize, end: usize) -> usize {
    let mut q = from + 1;
    let mut esc = false;
    while q <= end && q < b.len() {
        let c = b[q];
        if esc { esc = false; } else if c == b'\\' { esc = true; } else if c == b'"' { return q + 1; }
        q += 1;
    }
    end + 1
}

fn is_ws(c: u8) -> bool { matches!(c, b' ' | b'\t' | b'\r' | b'\n') }
fn is_hws(c: u8) -> bool { matches!(c, b' ' | b'\t' | b'\r') }

/// 在顶层对象内找 key 的值区间（深度 1 才算键）。
pub fn span_of(b: &[u8], ob: usize, oc: usize, key: &str) -> Option<Hit> {
    let mut depth = 0i32;
    let mut i = ob;
    while i <= oc && i < b.len() {
        let c = b[i];
        if c == b'"' {
            if depth != 1 { i = after_string(b, i, oc); continue; }
            let q_end = after_string(b, i, oc);
            let name = String::from_utf8_lossy(&b[i + 1..q_end.saturating_sub(1)]).into_owned();
            let mut p = q_end;
            while p <= oc && p < b.len() && is_ws(b[p]) { p += 1; }
            if p > oc || p >= b.len() || b[p] != b':' { i = q_end; continue; }
            let hit = name == key;
            p += 1;
            while p <= oc && p < b.len() && is_ws(b[p]) { p += 1; }
            let ke;
            if p < b.len() && b[p] == b'"' {
                ke = after_string(b, p, oc) - 1;
            } else {
                let mut e = p;
                while e <= oc && e < b.len() && !matches!(b[e], b',' | b'}' | b'\n') { e += 1; }
                while e > p && is_hws(b[e - 1]) { e -= 1; }
                ke = e.saturating_sub(1);
            }
            if hit {
                return Some(Hit { ks: p, ke, kbs: i });
            }
            i = if ke + 1 > i { ke + 1 } else { i + 1 };
            continue;
        }
        if c == b'{' || c == b'[' { depth += 1; }
        else if c == b'}' || c == b']' { depth -= 1; }
        i += 1;
    }
    None
}

fn jesc(s: &str) -> String {
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

pub fn render(v: &str) -> String { format!("\"{}\"", jesc(v)) }

/// 返回 (新文本, 状态)：ok / same / missing。
pub fn set(text: &str, pairs: &[(String, String)]) -> (String, &'static str) {
    let mut buf: Vec<u8> = text.as_bytes().to_vec();
    let Some(ob) = buf.iter().position(|c| *c == b'{') else { return (text.to_string(), "missing") };
    let Some(oc0) = match_close(&buf, ob) else { return (text.to_string(), "missing") };
    let mut oc = oc0;
    let mut changed = false;

    for (k, v) in pairs {
        let Some(hit) = span_of(&buf, ob, oc, k) else { continue };
        if !v.is_empty() {
            let newv = render(v).into_bytes();
            if buf[hit.ks..=hit.ke] == newv[..] {
                continue;
            }
            let mut out = Vec::with_capacity(buf.len() + newv.len());
            out.extend_from_slice(&buf[..hit.ks]);
            out.extend_from_slice(&newv);
            out.extend_from_slice(&buf[hit.ke + 1..]);
            buf = out;
        } else {
            let mut rs = hit.kbs;
            let mut re = hit.ke;
            let mut p = re + 1;
            while p <= oc && p < buf.len() && is_hws(buf[p]) { p += 1; }
            if p < buf.len() && buf[p] == b',' {
                re = p;
            } else {
                let mut q = rs.saturating_sub(1);
                while q > ob && is_ws(buf[q]) { q -= 1; }
                if buf[q] == b',' { rs = q; }
            }
            let mut a = rs.saturating_sub(1);
            while a > ob && is_hws(buf[a]) { a -= 1; }
            let mut b = re + 1;
            while b < buf.len() && is_hws(buf[b]) { b += 1; }
            if buf[a] == b'\n' && b < buf.len() && buf[b] == b'\n' {
                rs = a + 1;
                re = b;
            } else if buf[a] == b'\n' {
                rs = a + 1;
            }
            let mut out = Vec::with_capacity(buf.len());
            out.extend_from_slice(&buf[..rs]);
            out.extend_from_slice(&buf[re + 1..]);
            buf = out;
        }
        let Some(noc) = match_close(&buf, ob) else { return (text.to_string(), "missing") };
        oc = noc;
        changed = true;
    }

    // 不存在的键：整批插到顶层闭括号之前
    let mut miss: Vec<String> = Vec::new();
    for (k, v) in pairs {
        if v.is_empty() { continue; }
        if span_of(&buf, ob, oc, k).is_some() { continue; }
        miss.push(format!("\"{}\": {}", k, render(v)));
    }
    if !miss.is_empty() {
        let entries = miss.iter().enumerate()
            .map(|(i, m)| format!("{}{}", if i > 0 { ",\n" } else { "" }, format!("    {}", m)))
            .collect::<String>();
        let head = &buf[..oc];
        let tail = &buf[oc..];
        // 抽出 head 尾部的空白
        let mut hlen = head.len();
        while hlen > 0 && is_ws(head[hlen - 1]) { hlen -= 1; }
        let ws = &head[hlen..];
        let head2 = &head[..hlen];
        let mut out: Vec<u8> = Vec::new();
        out.extend_from_slice(head2);
        if head2.last() == Some(&b'{') {
            out.push(b'\n');
            out.extend_from_slice(entries.as_bytes());
            out.push(b'\n');
        } else if head2.last() == Some(&b',') {
            out.extend_from_slice(entries.as_bytes());
            out.extend_from_slice(ws);
        } else {
            out.push(b',');
            out.push(b'\n');
            out.extend_from_slice(entries.as_bytes());
            out.push(b'\n');
        }
        out.extend_from_slice(tail);
        buf = out;
        changed = true;
    }
    (String::from_utf8_lossy(&buf).into_owned(), if changed { "ok" } else { "same" })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(k: &str, v: &str) -> (String, String) { (k.to_string(), v.to_string()) }

    #[test]
    fn replaces_value_in_place() {
        let (out, st) = set("{\"a\": \"1\", \"b\": 2}\n", &[p("b", "3")]);
        assert_eq!(st, "ok");
        assert_eq!(out, "{\"a\": \"1\", \"b\": \"3\"}\n");
    }

    #[test]
    fn deletes_member_with_comma() {
        let (out, st) = set("{\n    \"a\": \"1\",\n    \"b\": \"2\"\n}\n", &[p("a", "")]);
        assert_eq!(st, "ok");
        assert_eq!(out, "{\n    \"b\": \"2\"\n}\n");
    }

    #[test]
    fn deletes_last_member_comma() {
        let (out, st) = set("{\n    \"a\": \"1\",\n    \"b\": \"2\"\n}\n", &[p("b", "")]);
        assert_eq!(st, "ok");
        assert_eq!(out, "{\n    \"a\": \"1\"\n}\n");
    }

    #[test]
    fn inserts_into_empty_object() {
        let (out, st) = set("{}\n", &[p("a", "1")]);
        assert_eq!(st, "ok");
        assert_eq!(out, "{\n    \"a\": \"1\"\n}\n");
    }

    #[test]
    fn inserts_after_trailing_comma() {
        let (out, st) = set("{\"a\": \"1\",}\n", &[p("b", "2")]);
        assert_eq!(st, "ok");
        assert_eq!(out, "{\"a\": \"1\",    \"b\": \"2\"}\n");
    }

    #[test]
    fn inserts_into_normal_object() {
        let (out, st) = set("{\"a\": \"1\"}\n", &[p("b", "2")]);
        assert_eq!(st, "ok");
        assert_eq!(out, "{\"a\": \"1\",\n    \"b\": \"2\"\n}\n");
    }

    #[test]
    fn same_when_nothing_changes() {
        let (_, st) = set("{\"a\": \"1\"}\n", &[p("a", "1")]);
        assert_eq!(st, "same");
    }

    #[test]
    fn missing_without_object() {
        let (_, st) = set("not json", &[p("a", "1")]);
        assert_eq!(st, "missing");
    }

    #[test]
    fn escapes_strings() {
        let (out, _) = set("{}", &[p("k", "a\"b\\c\td")]);
        assert!(out.contains("\"k\": \"a\\\"b\\\\c\\td\""));
    }
}
