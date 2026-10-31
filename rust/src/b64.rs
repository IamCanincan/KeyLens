//! base64 解码：界面把 payload 整体 base64 传进来，写命令逐层解开。
//!
//! 规则与 shell 侧的 `base64 -d` 对齐：忽略 ASCII 空白；遇到非法字符或
//! 长度不是 4 的倍数（允许缺省 padding）时返回 None，调用方按"内容不合法"拒绝。

/// 解码；失败返回 None。
pub fn decode(input: &str) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(input.len() / 4 * 3);
    let mut acc: u32 = 0;
    let mut bits: u8 = 0;
    let mut pad = 0usize;
    for b in input.bytes() {
        let v = match b {
            b'A'..=b'Z' => (b - b'A') as u32,
            b'a'..=b'z' => (b - b'a' + 26) as u32,
            b'0'..=b'9' => (b - b'0' + 52) as u32,
            b'+' => 62,
            b'/' => 63,
            b'=' => {
                pad += 1;
                continue;
            }
            b' ' | b'\t' | b'\r' | b'\n' => continue,
            _ => return None,
        };
        if pad > 0 {
            return None; // padding 之后还有数据
        }
        acc = (acc << 6) | v;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
            acc &= (1 << bits) - 1;
        }
    }
    Some(out)
}

/// 解码成字符串（写命令的 payload 都是文本）。
pub fn decode_text(input: &str) -> Option<String> {
    decode(input).and_then(|v| String::from_utf8(v).ok())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_ascii_with_and_without_padding() {
        assert_eq!(decode_text("aGVsbG8=").as_deref(), Some("hello"));
        assert_eq!(decode_text("aGVsbG8").as_deref(), Some("hello"));
        assert_eq!(decode_text("5Lit5paH").as_deref(), Some("中文"));
    }

    #[test]
    fn ignores_whitespace() {
        assert_eq!(decode_text("aGVs\nbG8=").as_deref(), Some("hello"));
    }

    #[test]
    fn rejects_invalid() {
        assert!(decode("a*b").is_none());
        assert!(decode_text("\u{0}").is_none());
    }
}
