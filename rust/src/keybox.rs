//! keybox 结构校验（keybox_check.awk 的等价）：按后端分叉，返回 ok 或 err<TAB>原因。

fn sp(c: u8) -> bool { matches!(c, b' ' | b'\t' | b'\r' | b'\n') }

/// `<name ...>` / `<name/>` 的出现次数（不会把 `<CertificateChain>` 当成 `<Certificate>`）。
pub fn count_tag_open(b: &[u8], name: &str) -> usize {
    let pat = format!("<{}", name);
    let p = pat.as_bytes();
    let mut n = 0;
    let mut i = 0;
    while i + p.len() <= b.len() {
        if &b[i..i + p.len()] == p {
            let mut j = i + p.len();
            let mut ok = false;
            if j < b.len() && (b[j] == b'>' || b[j] == b'/') {
                ok = true;
            } else if j < b.len() && (b[j] == b' ' || b[j] == b'\t') {
                while j < b.len() && b[j] != b'>' && b[j] != b'/' { j += 1; }
                if j < b.len() { ok = true; }
            }
            if ok { n += 1; }
        }
        i += 1;
    }
    n
}

fn has_root_pair(b: &[u8]) -> bool {
    let open = count_tag_open(b, "AndroidAttestation") > 0;
    let close = b.windows(20).any(|w| w == b"</AndroidAttestation");
    open && close
}

/// `<Key ... algorithm="...">`（属性顺序不限）
pub fn count_key_alg(b: &[u8]) -> usize {
    let mut n = 0;
    let mut i = 0;
    while i + 4 <= b.len() {
        if &b[i..i + 4] == b"<Key" && i + 4 < b.len() && sp(b[i + 4]) {
            let mut j = i + 4;
            while j < b.len() && b[j] != b'>' { j += 1; }
            let tag = &b[i + 4..j.min(b.len())];
            if tag_has_alg_attr(tag, false) { n += 1; }
            i = j;
        } else { i += 1; }
    }
    n
}

/// OMK 的严格形态：`<Key` 空白+ `algorithm` 空白* `=` 空白* `"…"` 紧跟 `>`
pub fn count_key_omk(b: &[u8]) -> usize {
    let mut n = 0;
    let mut i = 0;
    while i + 4 <= b.len() {
        if &b[i..i + 4] == b"<Key" && i + 4 < b.len() && sp(b[i + 4]) {
            let mut j = i + 4;
            while j < b.len() && sp(b[j]) { j += 1; }
            if b[j..].starts_with(b"algorithm") {
                let mut k = j + 9;
                while k < b.len() && sp(b[k]) { k += 1; }
                if k < b.len() && b[k] == b'=' {
                    k += 1;
                    while k < b.len() && sp(b[k]) { k += 1; }
                    if k < b.len() && b[k] == b'"' {
                        k += 1;
                        while k < b.len() && b[k] != b'"' { k += 1; }
                        if k + 1 < b.len() && b[k + 1] == b'>' { n += 1; }
                    }
                }
            }
            i += 4;
        } else { i += 1; }
    }
    n
}

fn tag_has_alg_attr(tag: &[u8], _omk: bool) -> bool {
    let mut i = 0;
    while i + 9 <= tag.len() {
        if &tag[i..i + 9] == b"algorithm" {
            let mut k = i + 9;
            while k < tag.len() && sp(tag[k]) { k += 1; }
            if k < tag.len() && tag[k] == b'=' {
                k += 1;
                while k < tag.len() && sp(tag[k]) { k += 1; }
                if k < tag.len() && tag[k] == b'"' { return true; }
            }
        }
        i += 1;
    }
    false
}

pub fn count_pem(b: &[u8]) -> usize {
    let pat = b"-----BEGIN ";
    let mut n = 0;
    let mut i = 0;
    while i + pat.len() <= b.len() {
        if &b[i..i + pat.len()] == pat {
            let mut j = i + pat.len();
            while j < b.len() && (b[j].is_ascii_uppercase() || b[j] == b' ') { j += 1; }
            if b[j..].starts_with(b"-----") { n += 1; }
        }
        i += 1;
    }
    n
}

fn has_alg(b: &[u8], want: &[&str]) -> bool {
    let pat = b"algorithm";
    let mut i = 0;
    while i + pat.len() <= b.len() {
        if &b[i..i + pat.len()] == pat {
            let mut k = i + pat.len();
            while k < b.len() && sp(b[k]) { k += 1; }
            if k < b.len() && b[k] == b'=' {
                k += 1;
                while k < b.len() && sp(b[k]) { k += 1; }
                if k < b.len() && b[k] == b'"' {
                    let start = k + 1;
                    let mut e = start;
                    while e < b.len() && b[e] != b'"' { e += 1; }
                    let v = String::from_utf8_lossy(&b[start..e]).into_owned();
                    if want.contains(&v.as_str()) { return true; }
                }
            }
        }
        i += 1;
    }
    false
}

/// 结果：Ok(()) 或 Err(原因)；原因文案与 awk 无参数部分一致（差异化文案由调用方补）。
pub fn check(text: &[u8], backend: &str) -> Result<(), String> {
    if text.iter().all(|c| sp(*c)) { return Err("keybox 是空文件".to_string()); }
    if !matches!(backend, "tricky" | "teesim" | "omk") {
        return Err(format!("不认识的端：{}", backend));
    }
    let ncert = count_tag_open(text, "Certificate");
    let npriv = count_tag_open(text, "PrivateKey");
    let nchain = count_tag_open(text, "CertificateChain");
    let nkeybox = count_tag_open(text, "Keybox");
    let nkey = count_key_alg(text);
    let nkey_omk = count_key_omk(text);
    let npem = count_pem(text);
    match backend {
        "tricky" => {
            if !has_root_pair(text) { return Err("Tricky 要求根元素是成对的 <AndroidAttestation>，这份没有".to_string()); }
            if nkey == 0 { return Err("没有 <Key algorithm=\"…\"> 块，Tricky 解析不到任何密钥".to_string()); }
            if nkeybox == 0 { return Err("没有 <Keybox> 元素，Tricky 的 depth-2 判据过不去".to_string()); }
            if npriv == 0 { return Err("没有 <PrivateKey>".to_string()); }
            if nchain == 0 { return Err("没有 <CertificateChain>，Tricky 只认带链的写法".to_string()); }
            if ncert == 0 { return Err("链里没有 <Certificate>".to_string()); }
        }
        "teesim" => {
            if !has_root_pair(text) && nkeybox == 0 { return Err("既没有 <AndroidAttestation> 也没有 <Keybox>，不像 keybox（TEESim 自家 WebUI 的判据）".to_string()); }
            if nkey == 0 { return Err("没有 <Key algorithm=\"…\"> 块".to_string()); }
            if npriv == 0 { return Err("没有 <PrivateKey>".to_string()); }
            if ncert < 2 { return Err(format!("TEESim 运行时至少要 2 张 <Certificate>，这份只有 {} 张", ncert)); }
            if !has_alg(text, &["rsa", "ecdsa"]) { return Err("TEESim 只认小写的 algorithm=\"rsa\"/\"ecdsa\"，这份里没有".to_string()); }
        }
        _ => {
            if nkey_omk == 0 { return Err("OMK 用正则 <Key\\s+algorithm=\"X\">…</Key> 整块取密钥，要求 algorithm 属性后面紧跟 >；这份一个都没匹配上".to_string()); }
            if !has_alg(text, &["ec", "ecdsa"]) { return Err("OMK 必须有 EC 密钥，只有 RSA 它直接放弃".to_string()); }
            if npriv == 0 { return Err("没有 <PrivateKey>".to_string()); }
            if npem == 0 { return Err("OMK 走 PEM 解码私钥与证书，这份里没有 -----BEGIN … ----- 块".to_string()); }
            // 逐块核对 NumberOfCertificates
            let mut i = 0usize;
            let mut seen = 0usize;
            while i < text.len() {
                let head = &text[i..];
                let Some(rel) = find_omk_key(head) else { break };
                let body_start = i + rel.0 + rel.1;
                let tail = &text[body_start..];
                let Some(close) = find_after(tail, b"</Key") else { return Err("有一个 <Key> 块没有 </Key> 收尾：OMK 的非贪婪整块正则匹配不到它".to_string()); };
                i = body_start + close.0 + close.1;
                seen += 1;
                let body = &tail[..close.0];
                let Some(nc) = find_after(body, b"<NumberOfCertificates") else {
                    return Err(format!("第 {} 个 <Key> 块里没有 <NumberOfCertificates>", seen));
                };
                let mut after = &body[nc.0 + nc.1..];
                // `<NumberOfCertificates` 之后允许空白，然后必须是 `>`
                let mut g = 0;
                while g < after.len() && sp(after[g]) { g += 1; }
                if g >= after.len() || after[g] != b'>' {
                    return Err(format!("第 {} 个 <Key> 块的 <NumberOfCertificates> 后面没有数字", seen));
                }
                after = &after[g + 1..];
                let mut k = 0;
                while k < after.len() && sp(after[k]) { k += 1; }
                let mut e = k;
                while e < after.len() && after[e].is_ascii_digit() { e += 1; }
                if e == k { return Err(format!("第 {} 个 <Key> 块的 <NumberOfCertificates> 后面没有数字", seen)); }
                let expected: usize = String::from_utf8_lossy(&after[k..e]).parse().unwrap_or(0);
                let got = count_tag_open(body, "Certificate");
                if got != expected {
                    return Err(format!("第 {} 个 <Key> 块声明 {} 张证书，实际数到 {} 张 —— OMK 数完不等就 bail，之后守护进程会把自带模板覆盖回这个文件", seen, expected, got));
                }
            }
        }
    }
    Ok(())
}

fn find_omk_key(b: &[u8]) -> Option<(usize, usize)> {
    let mut i = 0;
    while i + 4 <= b.len() {
        if &b[i..i + 4] == b"<Key" && i + 4 < b.len() && sp(b[i + 4]) {
            let mut j = i + 4;
            while j < b.len() && sp(b[j]) { j += 1; }
            if b[j..].starts_with(b"algorithm") {
                let mut k = j + 9;
                while k < b.len() && sp(b[k]) { k += 1; }
                if k < b.len() && b[k] == b'=' {
                    k += 1;
                    while k < b.len() && sp(b[k]) { k += 1; }
                    if k < b.len() && b[k] == b'"' {
                        k += 1;
                        while k < b.len() && b[k] != b'"' { k += 1; }
                        if k + 1 < b.len() && b[k + 1] == b'>' {
                            return Some((i, k + 2 - i));
                        }
                    }
                }
            }
        }
        i += 1;
    }
    None
}

fn find_after(b: &[u8], pat: &[u8]) -> Option<(usize, usize)> {
    if pat.is_empty() || b.len() < pat.len() { return None; }
    for i in 0..=b.len() - pat.len() {
        if &b[i..i + pat.len()] == pat { return Some((i, pat.len())); }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    const TRICKY_OK: &str = "<AndroidAttestation><Keybox><Key algorithm=\"ec\"><PrivateKey>p</PrivateKey><CertificateChain><Certificate>c</Certificate></CertificateChain></Key></Keybox></AndroidAttestation>";

    #[test]
    fn tricky_accepts_complete_chain() { assert!(check(TRICKY_OK.as_bytes(), "tricky").is_ok()); }

    #[test]
    fn tricky_requires_root() {
        let e = check(b"<Keybox><Key algorithm=\"ec\"></Key></Keybox>", "tricky").unwrap_err();
        assert!(e.contains("AndroidAttestation"));
    }

    #[test]
    fn teesim_needs_two_certs() {
        let x = "<AndroidAttestation><Key algorithm=\"ecdsa\"><PrivateKey>x</PrivateKey><Certificate>c</Certificate></Key></AndroidAttestation>";
        let e = check(x.as_bytes(), "teesim").unwrap_err();
        assert!(e.contains("至少要 2 张"));
    }

    #[test]
    fn omk_cert_count_mismatch() {
        let x = "<Key algorithm=\"ec\"><NumberOfCertificates>2</NumberOfCertificates><PrivateKey>-----BEGIN PRIVATE KEY-----</PrivateKey><Certificate>c</Certificate></Key>";
        let e = check(x.as_bytes(), "omk").unwrap_err();
        assert!(e.contains("声明 2 张证书，实际数到 1 张"), "{}", e);
    }

    #[test]
    fn empty_is_rejected() {
        assert_eq!(check(b"  \n", "tricky").unwrap_err(), "keybox 是空文件");
    }
}
