use base64::Engine;
use base64::engine::general_purpose::{STANDARD, URL_SAFE};

/// Decodes base64 the way every pnv decoder must: either alphabet, even both
/// mixed in one string, padding required, no trailing bits, nothing else.
pub(crate) fn decode(input: &str) -> Option<Vec<u8>> {
    let normalized: String = input
        .chars()
        .map(|c| match c {
            '-' => '+',
            '_' => '/',
            other => other,
        })
        .collect();

    STANDARD.decode(normalized).ok()
}

/// Encodes in the standard alphabet with padding, as tokens are written.
pub(crate) fn encode_standard(bytes: &[u8]) -> String {
    STANDARD.encode(bytes)
}

/// Encodes in the URL-safe alphabet with padding, as keys are written.
pub(crate) fn encode_url_safe(bytes: &[u8]) -> String {
    URL_SAFE.encode(bytes)
}

#[cfg(test)]
mod tests {
    use super::decode;

    #[test]
    fn follows_the_spec_rules() {
        assert_eq!(decode(""), Some(vec![]));
        assert_eq!(decode("YWI="), Some(b"ab".to_vec()));
        assert_eq!(decode("YWI"), None);
        assert_eq!(decode("YWJ="), None);
        assert_eq!(decode("YW I="), None);
        assert_eq!(decode("YWI=\n"), None);
        assert_eq!(decode("Y=I="), None);
        assert_eq!(decode("+-/_"), decode("++//"));
    }
}
