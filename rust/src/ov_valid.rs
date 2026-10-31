/// overrides.json 字段校验（与 webui.sh 的三个 valid_ov_* 同义，空值一律放行=删除该键）。

pub fn valid_ov_level(v: &str) -> bool {
    if v.is_empty() { return true; }
    if !v.bytes().all(|b| b.is_ascii_digit()) { return false; }
    v.parse::<u64>().map(|n| n <= 2).unwrap_or(false)
}

pub fn valid_ov_version(v: &str) -> bool {
    if v.is_empty() { return true; }
    if v.len() > 6 || !v.bytes().all(|b| b.is_ascii_digit()) { return false; }
    v.parse::<u64>().map(|n| (1..=100000).contains(&n)).unwrap_or(false)
}

pub fn valid_ov_hex(v: &str) -> bool {
    if v.is_empty() { return true; }
    let s = v.strip_prefix("0x").or_else(|| v.strip_prefix("0X")).unwrap_or(v);
    if s.len() != 64 || !s.bytes().all(|b| b.is_ascii_hexdigit()) { return false; }
    !s.bytes().all(|b| b == b'0')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn level_accepts_0_to_2_and_empty() {
        for v in ["", "0", "1", "2", "01", "002"] { assert!(valid_ov_level(v), "{}", v); }
        for v in ["3", "-1", "a", " 1"] { assert!(!valid_ov_level(v), "{}", v); }
    }

    #[test]
    fn version_range_and_digits() {
        assert!(valid_ov_version("1"));
        assert!(valid_ov_version("100000"));
        assert!(!valid_ov_version("0"));
        assert!(!valid_ov_version("100001"));
        assert!(!valid_ov_version("1234567"));
        assert!(!valid_ov_version("1a"));
    }

    #[test]
    fn hex_needs_64_digits_and_not_all_zero() {
        let good = "a".repeat(64);
        assert!(valid_ov_hex(&good));
        assert!(valid_ov_hex(&format!("0x{}", good)));
        assert!(!valid_ov_hex(&"0".repeat(64)));
        assert!(!valid_ov_hex(&"a".repeat(63)));
        assert!(!valid_ov_hex(&"g".repeat(64)));
    }
}
