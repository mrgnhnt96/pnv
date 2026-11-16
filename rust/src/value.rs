use std::fmt;

/// One value from a YAML file, typed by the YAML 1.2 core schema.
///
/// A secret is already decrypted, so it is a [`Value::String`].
///
/// [`Display`](fmt::Display) gives the value as plain text, the way the Dart
/// tool prints it: a string as is, a float such as `1e3` as `1000.0`, and
/// null as nothing. That is what a build script hands to the compiler.
#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    /// A string, including every quoted or block scalar and every decrypted
    /// secret.
    String(String),
    /// An integer such as `8080`, `-3`, `0x1F` or `0o17`.
    Int(i64),
    /// A float such as `1.5`, `1e3` or `.inf`.
    Float(f64),
    /// `true` or `false`, in any of their core-schema spellings.
    Bool(bool),
    /// `~`, `null`, or nothing after the `:`.
    Null,
}

impl Value {
    /// The string, when this is a [`Value::String`].
    pub fn as_str(&self) -> Option<&str> {
        match self {
            Self::String(value) => Some(value),
            _ => None,
        }
    }

    /// Whether this is [`Value::Null`].
    pub fn is_null(&self) -> bool {
        matches!(self, Self::Null)
    }

    /// The value as it appears after `=` in a `.env` file: a string quoted
    /// and escaped, anything else as plain text.
    pub fn to_env_value(&self) -> String {
        match self {
            Self::String(value) => format!("\"{}\"", escape_env_value(value)),
            other => other.to_string(),
        }
    }

    pub(crate) fn same_key(&self, other: &Self) -> bool {
        match (self, other) {
            (Self::Int(a), Self::Float(b)) | (Self::Float(b), Self::Int(a)) => *a as f64 == *b,
            _ => self == other,
        }
    }
}

impl fmt::Display for Value {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::String(value) => f.write_str(value),
            Self::Int(value) => write!(f, "{value}"),
            Self::Float(value) => f.write_str(&format_float(*value)),
            Self::Bool(value) => write!(f, "{value}"),
            Self::Null => Ok(()),
        }
    }
}

/// Escapes a string for a double-quoted `.env` value: `\`, `"`, carriage
/// return and newline, in that order. Nothing else, so a tab stays a tab.
pub fn escape_env_value(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for c in value.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\r' => out.push_str("\\r"),
            '\n' => out.push_str("\\n"),
            c => out.push(c),
        }
    }
    out
}

/// A float the way Dart's `double.toString` writes it.
fn format_float(value: f64) -> String {
    if value.is_nan() {
        return "NaN".to_owned();
    }
    if value.is_infinite() {
        return if value > 0.0 { "Infinity" } else { "-Infinity" }.to_owned();
    }
    if value == 0.0 {
        return if value.is_sign_negative() {
            "-0.0"
        } else {
            "0.0"
        }
        .to_owned();
    }

    let sign = if value < 0.0 { "-" } else { "" };
    let scientific = format!("{:e}", value.abs());
    let (mantissa, exponent) = scientific
        .split_once('e')
        .expect("`{:e}` always writes an exponent");
    let digits: String = mantissa.chars().filter(|c| *c != '.').collect();
    let exponent: i32 = exponent.parse().expect("`{:e}` writes an integer exponent");

    let k = digits.len() as i32;
    let n = exponent + 1;

    let body = if k <= n && n <= 21 {
        format!("{digits}{}.0", "0".repeat((n - k) as usize))
    } else if 0 < n && n <= 21 {
        let (int, frac) = digits.split_at(n as usize);
        format!("{int}.{frac}")
    } else if -6 < n && n <= 0 {
        format!("0.{}{digits}", "0".repeat((-n) as usize))
    } else {
        let e = n - 1;
        let e_sign = if e < 0 { '-' } else { '+' };
        let (first, rest) = digits.split_at(1);
        if rest.is_empty() {
            format!("{first}e{e_sign}{}", e.abs())
        } else {
            format!("{first}.{rest}e{e_sign}{}", e.abs())
        }
    };

    format!("{sign}{body}")
}

const CORE: &str = "tag:yaml.org,2002:";

/// Resolves a plain (unquoted, untagged) scalar by the YAML 1.2 core schema,
/// exactly as the Dart `yaml` package does.
pub(crate) fn resolve_plain(text: &str) -> Value {
    try_resolve_plain(text).unwrap_or_else(|| Value::String(text.to_owned()))
}

fn try_resolve_plain(text: &str) -> Option<Value> {
    let bytes = text.as_bytes();
    let Some(&first) = bytes.first() else {
        return Some(Value::Null);
    };
    match first {
        b'.' | b'+' | b'-' => parse_number(text, true, true),
        b'n' | b'N' if text.len() == 4 => parse_null(text),
        b't' | b'T' if text.len() == 4 => parse_bool(text),
        b'f' | b'F' if text.len() == 5 => parse_bool(text),
        b'~' if text.len() == 1 => Some(Value::Null),
        b'0'..=b'9' => parse_number(text, true, true),
        _ => None,
    }
}

/// Resolves a scalar with an explicit tag. The error says why the tag is
/// refused: one the core schema does not know, or text that does not fit it.
pub(crate) fn resolve_tagged(text: &str, tag: &str) -> Result<Value, String> {
    let Some(name) = tag.strip_prefix(CORE) else {
        return Err(format!("Undefined tag: {tag}."));
    };
    let parsed = match name {
        "null" => parse_null(text),
        "bool" => parse_bool(text),
        "int" => parse_number(text, true, false),
        "float" => parse_number(text, false, true),
        "str" => return Ok(Value::String(text.to_owned())),
        _ => return Err(format!("Undefined tag: {tag}.")),
    };
    parsed.ok_or_else(|| format!("Invalid {name} scalar."))
}

fn parse_null(text: &str) -> Option<Value> {
    matches!(text, "" | "null" | "Null" | "NULL" | "~").then_some(Value::Null)
}

fn parse_bool(text: &str) -> Option<Value> {
    match text {
        "true" | "True" | "TRUE" => Some(Value::Bool(true)),
        "false" | "False" | "FALSE" => Some(Value::Bool(false)),
        _ => None,
    }
}

fn parse_number(text: &str, allow_int: bool, allow_float: bool) -> Option<Value> {
    let bytes = text.as_bytes();
    let first = *bytes.first()?;

    if allow_int && bytes.len() == 1 {
        return first
            .is_ascii_digit()
            .then(|| Value::Int(i64::from(first - b'0')));
    }

    let second = bytes.get(1).copied().unwrap_or(0);

    if allow_int && first == b'0' {
        if second == b'x' {
            return parse_hex(&text[2..]).map(Value::Int);
        }
        if second == b'o' {
            return parse_radix(&text[2..], 8).map(Value::Int);
        }
    }

    if first.is_ascii_digit() || (matches!(first, b'+' | b'-') && second.is_ascii_digit()) {
        let mut result = None;
        if allow_int {
            result = parse_radix(text, 10).map(Value::Int);
        }
        if allow_float && result.is_none() {
            result = parse_double(text).map(Value::Float);
        }
        return result;
    }

    if !allow_float {
        return None;
    }

    if (first == b'.' && second.is_ascii_digit())
        || (matches!(first, b'+' | b'-') && second == b'.')
    {
        match text {
            "+.inf" | "+.Inf" | "+.INF" => return Some(Value::Float(f64::INFINITY)),
            "-.inf" | "-.Inf" | "-.INF" => return Some(Value::Float(f64::NEG_INFINITY)),
            _ => {}
        }
        return parse_double(text).map(Value::Float);
    }

    match text {
        ".inf" | ".Inf" | ".INF" => Some(Value::Float(f64::INFINITY)),
        ".nan" | ".NaN" | ".NAN" => Some(Value::Float(f64::NAN)),
        _ => None,
    }
}

/// Dart's `int.tryParse(text, radix: radix)`: an optional sign, then digits,
/// in the signed 64-bit range.
fn parse_radix(text: &str, radix: u32) -> Option<i64> {
    let (negative, digits) = split_sign(text);
    if digits.is_empty() || !digits.chars().all(|c| c.is_digit(radix)) {
        return None;
    }
    let magnitude = u64::from_str_radix(digits, radix).ok()?;
    if negative {
        0i64.checked_sub_unsigned(magnitude)
    } else {
        i64::try_from(magnitude).ok()
    }
}

/// Dart's `int.tryParse("0x<digits>")`: hexadecimal digits up to 64 bits,
/// where a value above the signed range wraps around as two's complement.
fn parse_hex(digits: &str) -> Option<i64> {
    if digits.is_empty() || !digits.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    u64::from_str_radix(digits, 16)
        .ok()
        .map(|value| value as i64)
}

/// Dart's `double.tryParse` for the forms YAML hands it: an optional sign,
/// digits with an optional fraction (or a fraction alone), and an optional
/// exponent.
fn parse_double(text: &str) -> Option<f64> {
    let (_, rest) = split_sign(text);
    let bytes = rest.as_bytes();
    let mut i = 0;
    let int_digits = count_digits(&bytes[i..]);
    i += int_digits;
    let mut frac_digits = 0;
    if bytes.get(i) == Some(&b'.') {
        i += 1;
        frac_digits = count_digits(&bytes[i..]);
        i += frac_digits;
    }
    if int_digits == 0 && frac_digits == 0 {
        return None;
    }
    if matches!(bytes.get(i), Some(b'e' | b'E')) {
        i += 1;
        if matches!(bytes.get(i), Some(b'+' | b'-')) {
            i += 1;
        }
        let exp_digits = count_digits(&bytes[i..]);
        if exp_digits == 0 {
            return None;
        }
        i += exp_digits;
    }
    if i != bytes.len() {
        return None;
    }
    text.parse().ok()
}

fn split_sign(text: &str) -> (bool, &str) {
    match text.as_bytes().first() {
        Some(b'-') => (true, &text[1..]),
        Some(b'+') => (false, &text[1..]),
        _ => (false, text),
    }
}

fn count_digits(bytes: &[u8]) -> usize {
    bytes.iter().take_while(|b| b.is_ascii_digit()).count()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn floats_render_like_dart() {
        for (value, expected) in [
            (1.5, "1.5"),
            (1.0, "1.0"),
            (1e3, "1000.0"),
            (1e20, "100000000000000000000.0"),
            (1e21, "1e+21"),
            (1.5e-7, "1.5e-7"),
            (0.000001, "0.000001"),
            (1e-7, "1e-7"),
            (-0.0, "-0.0"),
            (0.0, "0.0"),
            (-2.5, "-2.5"),
            (0.1, "0.1"),
            (123456789.125, "123456789.125"),
            (1.2345e25, "1.2345e+25"),
            (f64::INFINITY, "Infinity"),
            (f64::NEG_INFINITY, "-Infinity"),
            (f64::NAN, "NaN"),
        ] {
            assert_eq!(format_float(value), expected, "{value:e}");
        }
    }

    #[test]
    fn plain_scalars_resolve_like_dart() {
        use Value::*;
        for (text, expected) in [
            ("", Null),
            ("~", Null),
            ("NULL", Null),
            ("nUll", String("nUll".into())),
            ("True", Bool(true)),
            ("yes", String("yes".into())),
            ("0", Int(0)),
            ("-0", Int(0)),
            ("007", Int(7)),
            ("+12", Int(12)),
            ("0x1F", Int(31)),
            ("0xFFFFFFFFFFFFFFFF", Int(-1)),
            ("0x1FFFFFFFFFFFFFFFF", String("0x1FFFFFFFFFFFFFFFF".into())),
            ("0x", String("0x".into())),
            ("0o17", Int(15)),
            ("0o-17", Int(-15)),
            ("0o8", String("0o8".into())),
            ("-0x1F", String("-0x1F".into())),
            ("9223372036854775807", Int(i64::MAX)),
            ("-9223372036854775808", Int(i64::MIN)),
            ("9223372036854775808", Float(9223372036854775808.0)),
            ("1.", Float(1.0)),
            (".5", Float(0.5)),
            ("-.5", Float(-0.5)),
            ("1e3", Float(1000.0)),
            ("1E+3", Float(1000.0)),
            ("1e", String("1e".into())),
            ("+.INF", Float(f64::INFINITY)),
            ("-.nan", String("-.nan".into())),
            ("1_000", String("1_000".into())),
            ("1.2.3", String("1.2.3".into())),
            ("2024-01-01", String("2024-01-01".into())),
            ("-", String("-".into())),
            (".", String(".".into())),
        ] {
            assert_eq!(resolve_plain(text), expected, "{text:?}");
        }
        assert!(matches!(resolve_plain(".NaN"), Float(f) if f.is_nan()));
    }

    #[test]
    fn tags_resolve_like_dart() {
        let tag = |name: &str| format!("{CORE}{name}");
        assert_eq!(
            resolve_tagged("12", &tag("str")),
            Ok(Value::String("12".into()))
        );
        assert_eq!(resolve_tagged("1", &tag("float")), Ok(Value::Float(1.0)));
        assert_eq!(resolve_tagged("1", &tag("int")), Ok(Value::Int(1)));
        assert!(resolve_tagged("1.5", &tag("int")).is_err());
        assert!(resolve_tagged("x", &tag("bool")).is_err());
        assert!(resolve_tagged("x", "!foo").is_err());
        assert!(resolve_tagged("x", &tag("binary")).is_err());
    }

    #[test]
    fn escaping_is_ordered_and_leaves_tabs() {
        assert_eq!(escape_env_value("a\\\"b\r\n\tc"), "a\\\\\\\"b\\r\\n\tc");
    }
}
