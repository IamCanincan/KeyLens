use crate::b64;

pub fn parse(enc: &str) -> Result<Vec<(String, String)>, String> {
    if enc.is_empty() {
        return Err("参数为空".to_string());
    }
    if enc.len() > 131072 {
        return Err("配置过大".to_string());
    }
    let raw = b64::decode(enc).ok_or_else(|| "payload 解码失败".to_string())?;
    let text = String::from_utf8(raw).map_err(|_| "payload 解码失败".to_string())?;
    let mut out = Vec::new();
    for line in text.split('\n') {
        let line = line.strip_suffix('\r').unwrap_or(line);
        if line.is_empty() { continue; }
        let Some((k, venc)) = line.split_once('=') else {
            return Err("payload 行格式错误".to_string());
        };
        let v = b64::decode_text(venc).ok_or_else(|| format!("字段解码失败：{}", k))?;
        let v = v.strip_suffix('\n').map(|s| s.to_string()).unwrap_or(v);
        if v.contains('\n') || v.contains('\t') || v.contains('\r') {
            return Err(format!("字段含控制字符：{}", k));
        }
        out.push((k.to_string(), v));
    }
    if out.is_empty() {
        return Err("没有字段".to_string());
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::b64::encode;

    #[test]
    fn parses_two_fields_without_trailing_newline() {
        let enc = encode(&format!("a={}\nb={}", encode("1"), encode("2")));
        assert_eq!(parse(&enc).unwrap().len(), 2);
    }

    #[test]
    fn reports_missing_separator() {
        assert_eq!(parse(&encode("noseparator")).unwrap_err(), "payload 行格式错误");
    }

    #[test]
    fn reports_bad_field_base64() {
        assert_eq!(parse(&encode("k=@@@")).unwrap_err(), "字段解码失败：k");
    }

    #[test]
    fn rejects_control_chars() {
        assert_eq!(parse(&encode(&format!("k={}", encode("a\tb")))).unwrap_err(), "字段含控制字符：k");
    }

    #[test]
    fn rejects_empty_payload() {
        assert_eq!(parse("").unwrap_err(), "参数为空");
        assert_eq!(parse(&encode("\n")).unwrap_err(), "没有字段");
    }
}
