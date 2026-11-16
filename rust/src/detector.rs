use std::sync::LazyLock;

use regex::{Regex, RegexBuilder};

/// The comment text that marks a value as meant to be public.
pub const PLAINTEXT_MARKER: &str = "plaintext";

/// Why a plaintext value looks like it should have been encrypted.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Suspicion {
    /// A sentence saying what looks wrong, such as
    /// `looks like a GitHub token`.
    pub reason: String,
}

fn re(pattern: &str) -> Regex {
    Regex::new(pattern).expect("a valid pattern")
}

fn re_i(pattern: &str) -> Regex {
    RegexBuilder::new(pattern)
        .case_insensitive(true)
        .build()
        .expect("a valid pattern")
}

static SHAPES: LazyLock<Vec<(&'static str, Regex)>> = LazyLock::new(|| {
    vec![
        ("an OpenAI-style API key", re(r"^sk-[A-Za-z0-9_-]{16,}$")),
        (
            "a GitHub token",
            re(r"^(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}$"),
        ),
        (
            "a GitHub fine-grained token",
            re(r"^github_pat_[A-Za-z0-9_]{20,}$"),
        ),
        ("an AWS access key id", re(r"^(AKIA|ASIA)[0-9A-Z]{16}$")),
        ("a Slack token", re(r"^xox[baprs]-[A-Za-z0-9-]{10,}$")),
        (
            "a Stripe key",
            re(r"^(sk|rk)_(live|test)_[A-Za-z0-9]{16,}$"),
        ),
        ("a Google API key", re(r"^AIza[A-Za-z0-9_-]{35}$")),
        (
            "a JWT",
            re(r"^eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$"),
        ),
        (
            "a private key block",
            re(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
        ),
        (
            "a connection string with a password",
            re_i(r"^[a-z][a-z0-9+.-]*://[^/\s:@]+:[^/\s@]+@"),
        ),
    ]
});

static RISKY_NAME: LazyLock<Regex> = LazyLock::new(|| {
    re_i(
        r"(^|[-_.])(key|secret|token|password|passwd|pwd|credential|credentials|auth|apikey|private|cert|signature|salt)([-_.]|$)",
    )
});

static PUBLIC_NAME: LazyLock<Regex> = LazyLock::new(|| {
    re_i(
        r"(^|[-_.])(public[-_.]?key|key[-_.]?name|key[-_.]?id|auth[-_.]?url|auth[-_.]?domain|token[-_.]?url|token[-_.]?name)([-_.]|$)",
    )
});

const PLACEHOLDERS: [&str; 12] = [
    "changeme",
    "change-me",
    "replace",
    "replaceme",
    "replace-me",
    "placeholder",
    "todo",
    "unset",
    "none",
    "null",
    "example",
    "xxxxxxxx",
];

const PLACEHOLDER_PREFIXES: [&str; 4] = ["<", "${", "your-", "my-"];

fn is_placeholder(value: &str) -> bool {
    let squashed: String = value
        .chars()
        .filter(|c| !c.is_whitespace() && *c != '_')
        .flat_map(char::to_lowercase)
        .collect();

    PLACEHOLDERS.contains(&squashed.as_str())
        || PLACEHOLDER_PREFIXES
            .iter()
            .any(|prefix| squashed.starts_with(prefix))
}

/// Whether a string value, left unencrypted, looks like a secret.
///
/// This is the rule behind `pnv verify`, as written in the format spec:
/// the value is flagged when it has the shape of a credential, or when its
/// key is named like a secret and the value is not a placeholder. A
/// `comment` containing `plaintext` (any case) says the value is meant to
/// be public and is never flagged.
///
/// `key_path` is the keys from the top of the file joined with `.`.
///
/// ```
/// let flagged = pnv::suspect_plaintext("db.password", "hunter2hunter2", None);
/// assert!(flagged.is_some());
///
/// let public = pnv::suspect_plaintext("db.password", "hunter2hunter2", Some("plaintext, demo"));
/// assert!(public.is_none());
/// ```
pub fn suspect_plaintext(key_path: &str, value: &str, comment: Option<&str>) -> Option<Suspicion> {
    if comment.is_some_and(|c| c.to_lowercase().contains(PLAINTEXT_MARKER)) {
        return None;
    }

    let value = value.trim();
    if value.is_empty() {
        return None;
    }

    if let Some((shape, _)) = SHAPES.iter().find(|(_, pattern)| pattern.is_match(value)) {
        return Some(Suspicion {
            reason: format!("looks like {shape}"),
        });
    }

    let leaf = key_path.rsplit('.').next().unwrap_or(key_path);

    if RISKY_NAME.is_match(leaf)
        && !PUBLIC_NAME.is_match(leaf)
        && value.chars().count() >= 8
        && !is_placeholder(value)
    {
        return Some(Suspicion {
            reason: format!("the key is named \"{leaf}\" but the value is not encrypted"),
        });
    }

    None
}
