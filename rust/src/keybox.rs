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

// ---------------- 证书有效期（keybox 的叶证书什么时候到期） ----------------
// 只为了体检那一行：**不判链、不判签名**（那是 O 段上面写明的边界），只读每张证书的
// notAfter，取最早的那个。为什么要它：2026-11 这台机的 keybox 叶证书只有 12 天寿命，
// 到期后 attestation 会整个失效，而体检只查结构时报的仍是 ok。

fn der_tlv(b: &[u8], at: usize) -> Option<(u8, usize, usize)> {
    if at + 2 > b.len() { return None; }
    let tag = b[at];
    let mut i = at + 1;
    let first = b[i];
    i += 1;
    let len = if first & 0x80 == 0 {
        first as usize
    } else {
        let n = (first & 0x7f) as usize;
        if n == 0 || n > 3 || i + n > b.len() { return None; }
        let mut v = 0usize;
        for _ in 0..n { v = (v << 8) | b[i] as usize; i += 1; }
        v
    };
    if i + len > b.len() { return None; }
    Some((tag, i, i + len))
}

/// X.509 Reference ::= 从 DER 里取 validity 的 notAfter（`YYYY-MM-DD` 与那一天的序号）。
fn cert_not_after(der: &[u8]) -> Option<(String, i64)> {
    let (t, s, _e) = der_tlv(der, 0)?;
    if t != 0x30 { return None; }
    let (t2, s2, _e2) = der_tlv(der, s)?;       // tbsCertificate
    if t2 != 0x30 { return None; }
    let mut p = s2;
    // [0] version（可选）
    if der.get(p) == Some(&0xa0) { let (_, _, e) = der_tlv(der, p)?; p = e; }
    let (_, _, e) = der_tlv(der, p)?; p = e;    // serialNumber
    let (_, _, e) = der_tlv(der, p)?; p = e;    // signature
    let (_, _, e) = der_tlv(der, p)?; p = e;    // issuer
    let (t5, s5, _) = der_tlv(der, p)?;         // validity
    if t5 != 0x30 { return None; }
    let (_, _, e1) = der_tlv(der, s5)?;         // notBefore
    let (tn, sn, en) = der_tlv(der, e1)?;       // notAfter
    let raw = std::str::from_utf8(&der[sn..en]).ok()?;
    let (y, rest) = if tn == 0x17 {
        let yy: i64 = raw.get(0..2)?.parse().ok()?;
        (if yy < 50 { 2000 + yy } else { 1900 + yy }, raw.get(2..)?
            .trim_end_matches('Z'))
    } else if tn == 0x18 { (raw.get(0..4)?.parse().ok()?, raw.get(4..)?.trim_end_matches('Z')) }
    else { return None; };
    let mo: i64 = rest.get(0..2)?.parse().ok()?;
    let da: i64 = rest.get(2..4)?.parse().ok()?;
    Some((format!("{:04}-{:02}-{:02}", y, mo, da), days_from_civil(y, mo, da)))
}

/// Howard Hinnant 的 days_from_civil（公历 → 1970-01-01 起的天数）。
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

/// keybox 里所有证书 notAfter 的最早一张。返回 (日期, 距今还有多少天；负数=已过期)。
pub fn nearest_expiry(data: &[u8]) -> Option<(String, i64)> {
    let text = String::from_utf8_lossy(data);
    let mut best: Option<(String, i64)> = None;
    let mut rest = text.as_ref();
    while let Some(p) = rest.find("-----BEGIN CERTIFICATE-----") {
        let body = &rest[p + 27..];
        let end = match body.find("-----END CERTIFICATE-----") { Some(e) => e, None => break };
        let b64: String = body[..end].chars().filter(|c| !c.is_whitespace()).collect();
        rest = &body[end..];
        let der = match crate::b64::decode(&b64) { Some(d) => d, None => continue };
        if let Some((iso, day)) = cert_not_after(&der) {
            if best.as_ref().map(|b| day < b.1).unwrap_or(true) { best = Some((iso, day)); }
        }
    }
    let today = (std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).ok()?
        .as_secs() / 86400) as i64;
    best.map(|(iso, day)| (iso, day - today))
}
